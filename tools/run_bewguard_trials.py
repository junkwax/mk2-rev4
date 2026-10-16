#!/usr/bin/env python3
"""Repeat the Dead Pool divepunish crash rig against one ROM, in parallel.

    python tools/run_bewguard_trials.py --rom-dir tmp/bewguard/rom --map tmp/bewguard/mk2.map --trials 8

Tallies how each run ended - CRASH (TRAP 30), WEDGE (rig stall, game alive)
or clean - and how many drone lookups the beware_lookup guard refused, with
the action ids it refused.  The crash is intermittent (2 of 5 on one build),
so single runs attribute nothing; compare tallies.

Unlike run_divep_crash_trials.ps1 this never edits source, never kills another
emulator, and needs no window focus: private cfg/NVRAM/snapshot directories
under mame_mk2test.exe, ROM and map frozen into the run directory.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def trial(mame, frozen, n, args, run):
    d = run / ("trial%02d" % n)
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), DIVEP_LOG=str(d / "divep.log"),
               DIVEP_CHAR=args.char, DIVEP_DIFF=str(args.diff),
               DIVEP_SEED=str(args.seed), BEW_LOG=str(d / "bew.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"),
           "-inipath", str(d / "ini")]
    for option, sub in (("cfg", "cfg"), ("nvram", "nvram"), ("snapshot", "snap"),
                        ("state", "state"), ("input", "input")):
        cmd += ["-" + option + "_directory", str(d / sub)]
    cmd += ["-video", "none", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/bewguard_observer.lua"),
            "-seconds_to_run", str(args.seconds)]
    try:
        with (d / "mame.log").open("w") as log:
            subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                           timeout=args.seconds + 300)
    except subprocess.TimeoutExpired:
        pass
    divep = (d / "divep.log").read_text(errors="replace") if (d / "divep.log").exists() else ""
    bew = (d / "bew.log").read_text(errors="replace") if (d / "bew.log").exists() else ""
    verdict = re.search(r"STALL-VERDICT (\w+)", divep)
    if verdict:
        ended = verdict.group(1)
    elif re.search(r"ERROR never reached", divep):
        ended = "NO-FIGHT"
    elif divep.strip():
        ended = "CLEAN"
    else:
        ended = "NO-LOG"
    g = re.search(r"BEWGUARD frames=(\d+) refused=(\d+) actions=(\S+)", bew)
    return dict(trial=n, ended=ended,
                refused=int(g.group(2)) if g else None,
                actions=g.group(3) if g else None, dir=str(d))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--trials", type=int, default=8)
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--seed", type=int, default=31337)
    ap.add_argument("--char", default="scorpion")
    ap.add_argument("--diff", type=int, default=9)
    ap.add_argument("--seconds", type=int, default=900)
    ap.add_argument("--output", type=Path, default=ROOT / "tmp/bewguard/trials")
    args = ap.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    shutil.copy2(args.map, frozen / "src/mk2.map")
    shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")
    # the rig and the observer live in the checkout; the map they read is frozen
    (frozen / "tools").mkdir()
    for name in ("drone_divepunish_test.lua",):
        shutil.copy2(ROOT / "tools" / name, frozen / "tools" / name)

    with cf.ThreadPoolExecutor(max_workers=args.parallel) as pool:
        results = list(pool.map(lambda n: trial(args.mame, frozen, n, args, run),
                                range(1, args.trials + 1)))
    tally = {}
    for r in results:
        tally[r["ended"]] = tally.get(r["ended"], 0) + 1
        print("trial%02d %-8s refused=%s actions=%s" % (r["trial"], r["ended"], r["refused"], r["actions"]))
    print("TALLY", " ".join("%s=%d" % kv for kv in sorted(tally.items())))
    (run / "result.json").write_text(json.dumps(dict(args={k: str(v) for k, v in vars(args).items()},
                                                     tally=tally, results=results), indent=2) + "\n",
                                     encoding="utf-8")
    print(run)


if __name__ == "__main__":
    raise SystemExit(main())
