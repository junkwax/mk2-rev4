#!/usr/bin/env python3
"""Run the owned-palette hit light rig: lit mirror match, then the control.

    python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map

Freezes the selected ROM, its matching linker map and the Lua rig into the run directory,
runs tools/hitlight_test.lua twice (HL_ENABLE=1, then 0) under
mame_mk2test.exe with private cfg/NVRAM/snapshot directories, and requires an
explicit PASS from each. A missing verdict is a failure, never a pass.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_once(mame, frozen, enable, char, outdir, seconds, block=False, interrupt="none", side=1):
    outdir.mkdir(parents=True, exist_ok=True)
    for name in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (outdir / name).mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), HL_ENABLE=str(enable), HL_CHAR=str(char), HL_BLOCK=str(int(block)),
               HL_LOG=str(outdir / "hitlight.log"), HL_INTERRUPT=interrupt, HL_SIDE=str(side))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"),
           "-inipath", str(outdir / "ini")]
    for option, sub in (("cfg", "cfg"), ("nvram", "nvram"), ("snapshot", "snap"),
                        ("state", "state"), ("input", "input")):
        cmd += ["-" + option + "_directory", str(outdir / sub)]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(frozen / "tools/hitlight_test.lua"),
            "-seconds_to_run", str(seconds)]
    with (outdir / "mame.log").open("w") as log:
        proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=log,
                              stderr=subprocess.STDOUT,
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                              timeout=seconds + 240)
    text = (outdir / "hitlight.log").read_text(errors="replace") \
        if (outdir / "hitlight.log").exists() else ""
    result = re.search(r"^\[hl\] RESULT (.*)$", text, re.M)
    verdict = re.search(r"^\[hl\] (PASS|FAIL) reason=(\S+)", text, re.M)
    guard = re.search(r"^\[hl\] GUARD (.*)$", text, re.M)
    interruption = re.search(r"^\[hl\] INTERRUPT (.*)$", text, re.M)
    refs = re.search(r"^\[hl\] REFERENCES (.*)$", text, re.M)
    owner = re.search(r"^\[hl\] OWNER (.*)$", text, re.M)
    round_maps = re.search(r"^\[hl\] ROUND_MAPS (.*)$", text, re.M)
    return dict(enable=enable, block=block, side=side, exit=proc.returncode,
                owner=owner.group(1) if owner else None,
                round_maps=round_maps.group(1) if round_maps else None,
                interruption=interruption.group(1) if interruption else None,
                references=refs.group(1) if refs else None,
                guard=guard.group(1) if guard else None,
                result=result.group(1) if result else None,
                verdict=verdict.group(1) if verdict else "NO-VERDICT",
                reason=verdict.group(2) if verdict else None,
                log=str(outdir / "hitlight.log"))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path, default=ROOT / "rom")
    ap.add_argument("--map", type=Path, default=ROOT / "src/mk2.map")
    ap.add_argument("--char", type=int, default=1, help="victim ft_* index; both sides except freeze modes, whose attacker is Sub-Zero")
    ap.add_argument("--side", type=int, choices=[1, 2], default=1, help="player receiving hits (default: P1)")
    ap.add_argument("--block", action="store_true", help="hold the receiving player's block against high kicks; require chip contacts and no hit lights")
    ap.add_argument("--interrupt", choices=["none","terminate","disable","death","state","round","freeze","freeze-replace"], default="none", help="interrupt each light; round/freeze hold a sleeper through teardown/palette takeover")
    ap.add_argument("--output", type=Path, default=ROOT / "tmp/hitlight/tests")
    ap.add_argument("--seconds", type=int, default=240)
    args = ap.parse_args()
    if args.block and args.interrupt != "none":
        ap.error("--block cannot be combined with --interrupt: blocked contacts create no light to interrupt")
    if args.interrupt in ("freeze", "freeze-replace") and args.char not in (1, 4, 8):
        ap.error("freeze modes currently support victim --char 1, 4 or 8")

    args.output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    (frozen / "tools").mkdir(parents=True)
    shutil.copy2(ROOT / "tools/hitlight_test.lua", frozen / "tools/hitlight_test.lua")
    shutil.copy2(args.map, frozen / "src/mk2.map")
    shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")

    results = [run_once(args.mame, frozen, 1, args.char, run / "lit", args.seconds, args.block, args.interrupt, args.side),
               run_once(args.mame, frozen, 0, args.char, run / "control", args.seconds, args.block, args.interrupt, args.side)]
    ok = True
    for r in results:
        print("enable=%d exit=%s %s %s" % (r["enable"], r["exit"], r["verdict"], r["reason"]))
        print("    %s" % r["result"])
        ok &= r["verdict"] == "PASS" and r["exit"] == 0
    if args.interrupt == "round":
        same_maps = bool(results[0]["round_maps"]) and results[0]["round_maps"] == results[1]["round_maps"]
        print("post-round occupied palette IDs/counts match: %s" % same_maps)
        ok &= same_maps
        for r in results:
            r["paired_round_maps_match"] = same_maps
            if not same_maps:
                r["verdict"] = "FAIL"
                r["reason"] = "post_round_palette_allocation_mismatch"
    (run / "result.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
