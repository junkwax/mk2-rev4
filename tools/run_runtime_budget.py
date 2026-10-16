#!/usr/bin/env python3
"""Runtime budgets for the build report: how full the pools get in a busy fight.

Graphics audit opportunity 29, runtime half.  Boots tools/perf_stress.lua (the
battle stability sweep plus a P1 who attacks continuously with both health bars
pinned) on a few fixed matchups and records the high-water marks:

  obj / proc / blood        sampled peaks against their pools (358 / 168 / 64)
  peak_overload             ROM-latched frame load; 2 = every pass fit its tick
  cpu / cpu_peak            MPROC's cpumeter: % of the frame the process pass
                            used in the fight, and its worst pass in lines
  dirq / shadows / drain     display meter (MKINIT dirq, MKDISP dmaq10): lines the display
                            interrupt ran, lines in the shadow block, and lines from dirq's
                            start until the object queue ran empty - mean/peak, fight only
  qdma_drops                misc DMA queue sprites dropped (ROM-latched)
  deep_dmaq                 object DMA queue high-water, in words (/6 = cells of 500)
  dmaq_over/late/lost       object queue overflow frames and drain failures
  palq_drops                palette transfer queue drops

Runs in private MAME dirs, windowed under the debugger, against rom/mk2.zip +
src/mk2.map (the current build) unless --rom-zip/--map say otherwise.  Writes
tmp/build_report/runtime.json, which tools/build_report.py shows.

    python tools/run_runtime_budget.py
    python tools/run_runtime_budget.py --observe 1200 --scenario 8,10,0
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAME = Path("C:/MAME/mame_mk2test.exe")
OUT = ROOT / "tmp" / "build_report"
# (label, P1, P2, curback stage): busy, varied scenes
SCENARIOS = [
    ("subzero_vs_scorpion_deadpool", 8, 10, 0),
    ("kitana_vs_jax_tower", 4, 11, 3),
    ("liukang_vs_baraka_armory", 1, 3, 5),
]
LINE = re.compile(r"obj=\s*(\d+)/(\d+) proc=\s*(\d+)/(\d+) blood=\s*(\d+)/64\s+ROM: peak_overload=(\d+) qdma_drops=(\d+)"
                  r"(?: deep_dmaq=(\w+) dmaq_over=(\w+) dmaq_late=(\w+) dmaq_lost=(\w+) palq_drops=(\w+))?"
                  r"(?: cpu=([\d.]+)% cpu_peak=(\d+))?"
                  r"(?: dqi=([\d.]+)/(\d+) dqs=([\d.]+)/(\d+) dqd=([\d.]+)/(\d+))?"
                  r"(?: blits=([\d.]+)/(\d+))?")


def num(v):
    return int(v) if v and v.isdigit() else None


def boot(scn, zipf, mapf, run, observe, game="mk2", mame=MAME, video="bgfx"):
    label, p1, p2, stage = scn
    d = run / label
    fr = d / "frozen"
    for sub in ("src", "rom", "tools"):
        (fr / sub).mkdir(parents=True)
    shutil.copy2(mapf, fr / "src/mk2.map")
    shutil.copy2(zipf, fr / f"rom/{game}.zip")
    for name in ("battle_stability_sweep.lua", "perf_stress.lua"):
        shutil.copy2(ROOT / "tools" / name, fr / "tools" / name)
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "go.ds").write_text("go" + chr(10), encoding="ascii")
    env = os.environ.copy()
    env.update(MK2_ROOT=str(fr), SWEEP_P1=str(p1), SWEEP_P2=str(p2), SWEEP_STAGE=str(stage),
               SWEEP_OBSERVE=str(observe), SWEEP_LABEL=label, SWEEP_LOG=str(d / "sweep.log"),
               PERF_LOG=str(d / "perf.log"), PERF_POKE=os.environ.get("PERF_POKE", ""))
    cmd = [str(mame), game, "-rompath", str(fr / "rom"), "-inipath", str(d / "ini"),
           "-cfg_directory", str(d / "cfg"), "-nvram_directory", str(d / "nvram"),
           "-snapshot_directory", str(d / "snap"), "-state_directory", str(d / "state"),
           "-input_directory", str(d / "input"), "-video", video, "-sound", "none",
           "-nothrottle", "-skip_gameinfo", "-autoboot_script", str(fr / "tools/perf_stress.lua"),
           "-seconds_to_run", str(int(observe / 50) + 240), "-debug", "-debugscript", str(d / "go.ds"),
           "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       timeout=observe / 50 + 900, check=False)
    sweep = (d / "sweep.log").read_text(errors="replace") if (d / "sweep.log").exists() else ""
    perf = (d / "perf.log").read_text(errors="replace").splitlines() if (d / "perf.log").exists() else []
    verdict = re.findall(r"(PASS|FAIL) %s[^\n]*" % re.escape(label), sweep)
    verdict_line = next((l for l in reversed(sweep.splitlines()) if re.search(r"\b(PASS|FAIL) %s" % re.escape(label), l)), "")
    m = LINE.search(perf[-1]) if perf else None
    res = dict(label=label, p1=p1, p2=p2, stage=stage, sweep=verdict_line.split("] ", 1)[-1] or "no verdict",
               perf_lines=len(perf), dir=str(d))
    if m:
        res.update(obj=num(m[1]), obj_pool=num(m[2]), proc=num(m[3]), proc_pool=num(m[4]), blood=num(m[5]),
                   peak_overload=num(m[6]), qdma_drops=num(m[7]), deep_dmaq_words=num(m[8]),
                   deep_dmaq_cells=(num(m[8]) + 5) // 6 if num(m[8]) is not None else None,
                   dmaq_over=num(m[9]), dmaq_late=num(m[10]), dmaq_lost=num(m[11]), palq_drops=num(m[12]),
                   cpu_pct=float(m[13]) if m[13] else None, cpu_peak_lines=num(m[14]),
                   dqi_mean=float(m[15]) if m[15] else None, dqi_peak=num(m[16]),
                   dqs_mean=float(m[17]) if m[17] else None, dqs_peak=num(m[18]),
                   dqd_mean=float(m[19]) if m[19] else None, dqd_peak=num(m[20]),
                   blits_mean=float(m[21]) if m[21] else None, blits_peak=num(m[22]))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rom-zip", type=Path, default=ROOT / "rom/mk2.zip")
    ap.add_argument("--map", type=Path, default=ROOT / "src/mk2.map")
    ap.add_argument("--observe", type=int, default=2400, help="fighting frames per scenario (54.7/s)")
    ap.add_argument("--scenario", action="append", help="P1,P2,STAGE (repeatable); default: three busy matchups")
    ap.add_argument("--game", choices=("mk2", "umk3"), default="mk2",
                    help="umk3 = the Wolf set: pass --rom-zip rom/wolf/umk3.zip --map tmp/wolf/src/MK2.MAP --mame mk2wolf.exe")
    ap.add_argument("--mame", type=Path, default=MAME)
    ap.add_argument("--jobs", type=int, default=2, help="MAME instances at once")
    ap.add_argument("--poke", default="", help="sym=value,... written every frame (perf_stress PERF_POKE) - an A/B on one ROM")
    ap.add_argument("--video", default="bgfx", help="MAME -video (gdi when the desktop is locked: bgfx/d3d cannot open a window)")
    ap.add_argument("--out", type=Path, default=None, help="json path (default tmp/build_report/runtime.json)")
    args = ap.parse_args()
    if args.poke:
        os.environ["PERF_POKE"] = args.poke
    scns = SCENARIOS
    if args.scenario:
        scns = [("p%s_vs_p%s_stage%s" % tuple(s.split(",")),) + tuple(int(x) for x in s.split(",")) for s in args.scenario]
    OUT.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="runtime-", dir=OUT))
    with ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(lambda s: boot(s, args.rom_zip, args.map, run, args.observe, args.game, args.mame, args.video), scns))
    rep = dict(generated=dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), rom_zip=str(args.rom_zip),
               map=str(args.map), observe_frames=args.observe, run=str(run), scenarios=results)
    outp = args.out or (OUT / "runtime.json")
    outp.parent.mkdir(parents=True, exist_ok=True)
    outp.write_text(json.dumps(rep, indent=2) + "\n", encoding="utf-8")
    for r in results:
        print("%-30s %s | obj %s/%s proc %s/%s blood %s/64 | overload %s | dmaq %s cells, over %s late %s lost %s | qdma %s palq %s | cpu %s%% peak %s/289 lines | dirq %s/%s shadows %s/%s drain %s/%s (mean/peak lines) | blits %s/%s"
              % (r["label"], r["sweep"], r.get("obj"), r.get("obj_pool"), r.get("proc"), r.get("proc_pool"), r.get("blood"),
                 r.get("peak_overload"), r.get("deep_dmaq_cells"), r.get("dmaq_over"), r.get("dmaq_late"), r.get("dmaq_lost"),
                 r.get("qdma_drops"), r.get("palq_drops"), r.get("cpu_pct"), r.get("cpu_peak_lines"),
                 r.get("dqi_mean"), r.get("dqi_peak"), r.get("dqs_mean"), r.get("dqs_peak"),
                 r.get("dqd_mean"), r.get("dqd_peak"), r.get("blits_mean"), r.get("blits_peak")))
    print("wrote %s" % outp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
