#!/usr/bin/env python3
"""Mileena's victory pose: packed left arms vs mirrored aliases - opportunity 17.

    python tools/run_mileena_victory_ab.py --stock-rom-dir <dir> --stock-map <map> \\
                                           --alias-rom-dir tmp/kt2arm/rom --alias-map tmp/kt2arm/mk2.map

Boots tools/mileena_victory_ab.lua on both ROMs for each side (1 = facing
right, 2 = facing LEFT, where her flip XORs with the aliases' own) and
requires, per side:

  same fight    PREARM lines equal (re-boot a pair that is not)
  identical     every snapshot pixel-identical between the ROMs
  exercised     some snapshots show her body on KT2VICTORY1A - the eight frames
                whose left arm is now an alias - in both ROMs
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

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SNAP_RE = re.compile(r"SNAP rel(\d+) arm=(\d) gs=(\d+)")


def boot(mame, rom_dir, mapf, label, side, run, seconds):
    d = run / label
    fr = d / "frozen"
    (fr / "src").mkdir(parents=True)
    (fr / "rom").mkdir(parents=True)
    shutil.copy2(mapf, fr / "src/mk2.map")
    shutil.copy2(rom_dir / "mk2.zip", fr / "rom/mk2.zip")
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    tbl = (ROOT / "src/MKFN.TBL").read_text(errors="replace")
    arms = [m.group(1) for m in re.finditer(r"^KT2VARMRIGHT[1-8]A:\s*\n\s*\.word[^\n]*\n\s*\.long\s+0?([0-9a-fA-F]+)[Hh]", tbl, re.M)]
    env.update(MK2_ROOT=str(fr), MV_SIDE=str(side), MV_LOG=str(d / "mv.log"), MV_ARMSAGS=",".join(arms))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(fr / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/mileena_victory_ab.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def one_side(args, side, out):
    jobs = {"stock": (args.stock_rom_dir, args.stock_map), "alias": (args.alias_rom_dir, args.alias_map)}
    for attempt in range(1, args.attempts + 1):
        run = Path(tempfile.mkdtemp(prefix="side%d-" % side, dir=out))
        with ThreadPoolExecutor(2) as pool:
            list(pool.map(lambda k: boot(args.mame, jobs[k][0], jobs[k][1], k, side, run, args.seconds), jobs))
        text = {k: (run / k / "mv.log").read_text(errors="replace") for k in jobs}
        pre = {k: (re.search(r"PREARM (.*)", t).group(1) if re.search(r"PREARM (.*)", t) else None) for k, t in text.items()}
        if pre["stock"] and pre["stock"] == pre["alias"]:
            break
        print("side %d attempt %d: boots started differently (%s | %s)" % (side, attempt, pre["stock"], pre["alias"]))
    else:
        return dict(side=side, passed=False, reason="no matched pair")
    shots = {k: sorted((run / k / "snap").rglob("*.png")) for k in jobs}
    snaps = {k: SNAP_RE.findall(text[k]) for k in jobs}
    ok = len(shots["stock"]) == len(shots["alias"]) == len(snaps["alias"]) > 0 and snaps["stock"] == snaps["alias"]
    diffs, arm_snaps, first_bad = [], 0, None
    for i in range(min(len(shots["stock"]), len(shots["alias"]))):
        a = Image.open(shots["stock"][i]).convert("RGB")
        b = Image.open(shots["alias"][i]).convert("RGB")
        if a.size != (400, 254) or b.size != (400, 254):
            raise ValueError("Expected complete 400x254 captures")
        pa, pb = a.load(), b.load()
        d = sum(1 for y in range(254) for x in range(400) if pa[x, y] != pb[x, y])
        diffs.append(d)
        if d and first_bad is None:
            first_bad = (i, snaps["alias"][i][0], d)
        if snaps["alias"][i][1] == "1":
            arm_snaps += 1
    ok &= not any(diffs) and arm_snaps > 0
    rep = dict(side=side, passed=ok, run=str(run), prearm=pre["stock"], snapshots=len(diffs),
               differing=len([d for d in diffs if d]), max_diff_px=max(diffs, default=0),
               arm_frame_snapshots=arm_snaps, first_difference=first_bad,
               logs_agree=snaps["stock"] == snaps["alias"])
    print("side %d: snapshots %d  differing %d (max %d px)  arm-frame snapshots %d  logs agree %s  -> %s"
          % (side, rep["snapshots"], rep["differing"], rep["max_diff_px"], arm_snaps, rep["logs_agree"],
             "PASS" if ok else "FAIL"))
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--stock-rom-dir", type=Path, required=True)
    ap.add_argument("--stock-map", type=Path, required=True)
    ap.add_argument("--alias-rom-dir", type=Path, required=True)
    ap.add_argument("--alias-map", type=Path, required=True)
    ap.add_argument("--sides", default="1,2")
    ap.add_argument("--attempts", type=int, default=4)
    ap.add_argument("--seconds", type=int, default=170)
    args = ap.parse_args()
    out = ROOT / "tmp/kt2arm/tests"
    out.mkdir(parents=True, exist_ok=True)
    reports = [one_side(args, int(s), out) for s in args.sides.split(",") if s]
    ok = all(r["passed"] for r in reports)
    (out / "last_result.json").write_text(json.dumps(reports, indent=2) + "\n", encoding="utf-8")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
