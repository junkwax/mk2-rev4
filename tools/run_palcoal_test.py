#!/usr/bin/env python3
"""Palette transfer coalescing (palq_coalesce, PALL.ASM) - A/B per stage.

    python tools/run_palcoal_test.py --rom-dir tmp/palcoal/rom --map tmp/palcoal/mk2.map

Boots tools/palq_probe.lua twice per stage on one frozen ROM - f_palcoal off
and on, identical inputs, power-up to 900 frames into a fight - and checks:

  same run     both boots pass through the same game states on the same
               frames (the attract/select automation is not deterministic
               under load; a pair that diverged is re-booted, not scored).
  equivalent   the colour-RAM hash (all 80 palettes, every 8 frames) is
               identical in both boots up to the first frame the OFF boot
               lost a transfer to a full queue - after that the coalesced
               boot is allowed to be right where the stock one is not.
  cheaper      cells queued, duplicates, colours copied and drops, off vs on.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import run_palq_probe as P  # noqa: E402

STAGES = P.STAGES
H_RE = re.compile(r"H frame=(\d+) gs=(\d+) hash=(\w+) drops=(-?\d+)")


def boot(mame, frozen, name, stage, coal, run, seconds):
    d = run / ("%s_%s" % (name, "on" if coal else "off"))
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), PQ_STAGE=str(stage), PQ_COAL="1" if coal else "0", PQ_LOG=str(d / "pq.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/palq_probe.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def stats(text):
    rows = [dict(n=int(m.group(4)), cols=int(m.group(5)), dup=int(m.group(6)), rel=int(m.group(3)))
            for m in P.F_RE.finditer(text)]
    res = re.search(r"RESULT frames=(\d+) badptr=\d+(?: resets=\d+)? coal=(\d) drops=(-?\d+) merged=(-?\d+) voided=(-?\d+)", text)
    return dict(cells=sum(r["n"] for r in rows), colours=sum(r["cols"] for r in rows),
                duplicates=sum(r["dup"] for r in rows), max_cells_in_a_frame=max((r["n"] for r in rows), default=0),
                fight_cells=sum(r["n"] for r in rows if r["rel"] >= 0),
                drops=int(res.group(3)) if res else None, merged=int(res.group(4)) if res else None,
                voided=int(res.group(5)) if res else None, finished=bool(res))


def compare(run, name):
    off = (run / ("%s_off" % name) / "pq.log").read_text(errors="replace")
    on = (run / ("%s_on" % name) / "pq.log").read_text(errors="replace")
    same_run = re.findall(r"GSTATE frame=\d+ -?\d+ -> \d+", off) == re.findall(r"GSTATE frame=\d+ -?\d+ -> \d+", on)
    h_off, h_on = H_RE.findall(off), H_RE.findall(on)
    first_off_drop = next((int(f) for f, _, _, d in h_off if int(d) > 0), None)
    mismatch_before_drop = [int(a[0]) for a, b in zip(h_off, h_on)
                            if a[2] != b[2] and (first_off_drop is None or int(a[0]) < first_off_drop)]
    mismatch_after = [int(a[0]) for a, b in zip(h_off, h_on) if a[2] != b[2]]
    s_off, s_on = stats(off), stats(on)
    ok = (same_run and s_off["finished"] and s_on["finished"] and len(h_off) == len(h_on) and len(h_off) > 0
          and not mismatch_before_drop and s_on["drops"] == 0)
    return ok, same_run, dict(same_run=same_run, hashes=len(h_off), first_off_drop_frame=first_off_drop,
                              mismatches_before_first_drop=mismatch_before_drop[:10],
                              mismatches_total=len(mismatch_after), off=s_off, on=s_on, passed=ok)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--stages", default=",".join(STAGES))
    ap.add_argument("--attempts", type=int, default=3)
    ap.add_argument("--seconds", type=int, default=150)
    args = ap.parse_args()
    names = [s for s in args.stages.split(",") if s]
    out_dir = ROOT / "tmp/palcoal/tests"
    out_dir.mkdir(parents=True, exist_ok=True)
    report, all_ok = {}, True
    for name in names:
        for attempt in range(1, args.attempts + 1):
            run = Path(tempfile.mkdtemp(prefix="%s-" % name, dir=out_dir))
            frozen = run / "frozen"
            (frozen / "src").mkdir(parents=True)
            (frozen / "rom").mkdir(parents=True)
            shutil.copy2(args.map, frozen / "src/mk2.map")
            shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")
            with ThreadPoolExecutor(2) as pool:
                list(pool.map(lambda c: boot(args.mame, frozen, name, STAGES[name], c, run, args.seconds), (False, True)))
            ok, same_run, rep = compare(run, name)
            if same_run:
                break
            print("%s attempt %d: the two boots took different paths - re-booting" % (name, attempt))
        rep["run"] = str(run)
        report[name] = rep
        all_ok &= ok
        o, n = rep["off"], rep["on"]
        print("== %s  same run %s  hashes %d  first off-drop frame %s  mismatches before it %d (total %d)  -> %s"
              % (name, rep["same_run"], rep["hashes"], rep["first_off_drop_frame"],
                 len(rep["mismatches_before_first_drop"]), rep["mismatches_total"], "PASS" if ok else "FAIL"))
        for k in ("cells", "duplicates", "colours", "max_cells_in_a_frame", "fight_cells", "drops", "merged", "voided"):
            print("   %-22s off %7s   on %7s" % (k, o[k], n[k]))
    (out_dir / "last_summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("%s" % ("PASS" if all_ok else "FAIL"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
