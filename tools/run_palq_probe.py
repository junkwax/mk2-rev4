#!/usr/bin/env python3
"""What the palette transfer queue carries - audit opportunity 11.

    python tools/run_palq_probe.py --rom-dir tmp/ghosts/rom --map tmp/ghosts/mk2.map

Boots tools/palq_probe.lua once per stage (default THE WASTELAND and THE DEAD
POOL, in parallel) from power-up to 900 frames into a two-player fight, and
summarises the queue per phase (before the fight / the fight):

  transfers and colours per frame (mean, max), frames that queued anything,
  duplicate transfers (same destination and count twice in one frame - the
  first is wasted), redundant colours (equal to what the previous transfer
  to that entry wrote), the largest single transfer, and the deepest queue.

A frame that enqueues 31 or more transfers can drop some (palset refuses when
the ring is full, silently); those frames are counted separately.  Nothing
here is a pass/fail gate - it is the profile the audit asks for before any
coalescing is written.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STAGES = {"wasteland": 2, "deadpool": 0}
F_RE = re.compile(r"F frame=(\d+) gs=(\d+) rel=(-?\d+) n=(\d+) cols=(\d+) dup=(\d+) red=(\d+) first=(\d+) big=(\d+) depth=(\d+)(?: reset=\d)? ?(.*)")


def boot(mame, frozen, name, stage, run, seconds):
    d = run / name
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), PQ_STAGE=str(stage), PQ_LOG=str(d / "pq.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/palq_probe.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def summarise(rows, frames):
    if frames <= 0:
        return {}
    n = [r["n"] for r in rows]
    cols = [r["cols"] for r in rows]
    tot_n, tot_cols = sum(n), sum(cols)
    red, first, dup = sum(r["red"] for r in rows), sum(r["first"] for r in rows), sum(r["dup"] for r in rows)
    return dict(frames=frames, frames_with_transfers=len([x for x in n if x]),
                transfers=tot_n, transfers_per_frame=round(tot_n / frames, 3), transfers_max=max(n, default=0),
                colours=tot_cols, colours_per_frame=round(tot_cols / frames, 2), colours_max=max(cols, default=0),
                duplicate_transfers=dup, redundant_colours=red, first_time_colours=first,
                redundant_pct=round(100.0 * red / tot_cols, 1) if tot_cols else 0.0,
                largest_transfer=max((r["big"] for r in rows), default=0),
                deepest_queue_seen=max((r["depth"] for r in rows), default=0),
                frames_at_risk_of_drop=len([x for x in n if x >= 31]))


def analyse(run, names):
    report = {}
    for name in names:
        text = (run / name / "pq.log").read_text(errors="replace")
        res = re.search(r"RESULT frames=(\d+) badptr=(\d+)", text)
        if not res:
            print("%s: NO RESULT" % name)
            report[name] = None
            continue
        total, badptr = int(res.group(1)), int(res.group(2))
        fight_start = next((int(m.group(1)) for m in re.finditer(r"GSTATE frame=(\d+) -?\d+ -> 2", text)), None)
        rows = []
        dests = {}
        for m in F_RE.finditer(text):
            r = dict(frame=int(m.group(1)), gs=int(m.group(2)), rel=int(m.group(3)), n=int(m.group(4)),
                     cols=int(m.group(5)), dup=int(m.group(6)), red=int(m.group(7)), first=int(m.group(8)),
                     big=int(m.group(9)), depth=int(m.group(10)))
            rows.append(r)
            if r["rel"] >= 0:
                for part in m.group(11).split(","):
                    if part:
                        dests[part] = dests.get(part, 0) + 1
        pre = [r for r in rows if r["rel"] < 0]
        fight = [r for r in rows if r["rel"] >= 0]
        rep = dict(frames_total=total, badptr=badptr, fight_start_frame=fight_start,
                   before_fight=summarise(pre, (fight_start or total) - 1),
                   fight=summarise(fight, total - (fight_start or total) + 1),
                   top_fight_transfers=sorted(dests.items(), key=lambda kv: -kv[1])[:10])
        report[name] = rep
        print("== %s (badptr %d)" % (name, badptr))
        for phase in ("before_fight", "fight"):
            s = rep[phase]
            if not s:
                continue
            print("  %-12s frames %5d  queued-in %5d  transfers %5d (%.3f/frame, max %d)  colours %6d (%.1f/frame, max %d)"
                  % (phase, s["frames"], s["frames_with_transfers"], s["transfers"], s["transfers_per_frame"],
                     s["transfers_max"], s["colours"], s["colours_per_frame"], s["colours_max"]))
            print("  %-12s duplicates %d  redundant colours %d (%.1f%%)  first-time %d  largest %d  deepest %d  drop-risk frames %d"
                  % ("", s["duplicate_transfers"], s["redundant_colours"], s["redundant_pct"], s["first_time_colours"],
                     s["largest_transfer"], s["deepest_queue_seen"], s["frames_at_risk_of_drop"]))
        print("  busiest fight transfers [dest:count x frames]:", ", ".join("%s x%d" % kv for kv in rep["top_fight_transfers"][:6]))
    (run / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("summary: %s" % (run / "summary.json"))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--stages", default=",".join(STAGES), help="comma list of %s" % ",".join(STAGES))
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--reanalyse", type=Path)
    args = ap.parse_args()
    names = [s for s in args.stages.split(",") if s]
    if args.reanalyse:
        return analyse(args.reanalyse, names)
    out_dir = ROOT / "tmp/palq/tests"
    out_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=out_dir))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    shutil.copy2(args.map, frozen / "src/mk2.map")
    shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")
    with ThreadPoolExecutor(len(names)) as pool:
        list(pool.map(lambda n: boot(args.mame, frozen, n, STAGES[n], run, args.seconds), names))
    return analyse(run, names)


if __name__ == "__main__":
    raise SystemExit(main())
