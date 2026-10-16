#!/usr/bin/env python3
"""Measure the floor rows each stage could stop drawing, by photographing them.

Runs tools/floor_skip_probe.lua twice per stage - once observing whatever the
stage sets `@skew_skip` to itself, once with it pinned to the whole floor
height - and diffs the snapshots.
Every screen row that changes was a row the player could see; the rows above the
first change were being drawn and thrown away, and are what `@skew_skip` may
legally skip.

    python tools/run_floor_skip_probe.py               # every floor stage
    python tools/run_floor_skip_probe.py tower         # the control: must be 54
    python tools/run_floor_skip_probe.py tomb armory

Runs under mame_mk2test.exe with private cfg/NVRAM/snapshot directories, so a
rig running in another session is neither killed nor joined.
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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# curback index, and the stage's skew_y / skew_height read back from the probe.
STAGES = {"tomb": 1, "battle": 2, "tower": 3, "forest": 4, "armory": 5,
          "arena": 8}
# THE TOWER is the control. If this comes back as anything else the measurement
# is wrong, not the stage.
CONTROL = {"tower": 54}
# Proved from the display list alone - dlists_port draws NOTHING between
# floor_code and the shadows, so there is nothing that could cover the floor.
NO_LAYERS = {"port"}


def freeze(run, romdir=None, map_path=None):
    """Copy the ROM and the linker map the probe resolves symbols from.

    The probe reads src/mk2.map to turn symbol names into addresses, and a
    build running in another session deletes and rewrites that file mid-link -
    one sweep here died with "mk2.map: No such file or directory" halfway
    through. Worse than dying would be surviving: a map from a NEWER build than
    the ROM under test resolves @skew_skip to an address that has moved, and
    the probe would quietly pin the wrong word. So take both once, together,
    and point the runs at the copies.
    """
    stage = run / "frozen"
    (stage / "src").mkdir(parents=True, exist_ok=True)
    (stage / "rom").mkdir(parents=True, exist_ok=True)
    shutil.copy2(map_path or ROOT / "src/mk2.map", stage / "src/mk2.map")
    shutil.copy2((romdir or ROOT / "rom") / "mk2.zip", stage / "rom/mk2.zip")
    return stage


def run_once(mame, rom, stage_id, skip, outdir, seconds, mk2_root=ROOT):
    outdir.mkdir(parents=True, exist_ok=True)
    for name in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (outdir / name).mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(mk2_root), FSP_STAGE=str(stage_id), FSP_SKIP=str(skip),
               FSP_TAG=("shipped" if skip < 0 else "skip%d" % skip),
               FSP_LOG=str(outdir / "probe.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(rom),
           "-inipath", str(outdir / "ini")]
    for option, sub in (("cfg", "cfg"), ("nvram", "nvram"), ("snapshot", "snap"),
                        ("state", "state"), ("input", "input")):
        cmd += ["-" + option + "_directory", str(outdir / sub)]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/floor_skip_probe.lua"),
            "-seconds_to_run", str(seconds)]
    with (outdir / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, check=True,
                       stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 180)
    return (outdir / "probe.log").read_text(errors="replace")


def band_from_log(text):
    m = re.search(r"floor band: skew_y=(-?\d+) height=(-?\d+)", text)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def first_differing_row(a_png, b_png):
    """Lowest screen y where the two frames differ, or None."""
    from PIL import Image
    a = Image.open(a_png).convert("RGB")
    b = Image.open(b_png).convert("RGB")
    if a.size != b.size:
        raise ValueError(f"Snapshot dimensions differ: {a.size} != {b.size}")
    pa, pb = a.load(), b.load()
    w, h = a.size
    for y in range(h):
        for x in range(w):
            if pa[x, y] != pb[x, y]:
                return y
    return None


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stages", nargs="*")
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path, default=ROOT / "rom")
    ap.add_argument("--map", type=Path, default=ROOT / "src/mk2.map",
                    help="linker map matching the selected ROM")
    ap.add_argument("--output", type=Path, default=ROOT / "tmp/floorskip")
    ap.add_argument("--seconds", type=int, default=120)
    args = ap.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    frozen = freeze(run, args.rom_dir, args.map)
    romdir = frozen / "rom"
    results, rc = {}, 0
    for name in (args.stages or list(STAGES)):
        if name in NO_LAYERS:
            print("%-8s 0 rows - dlists_%s draws nothing after floor_code"
                  % (name, name))
            results[name] = dict(safe_rows=0, reason="no layers after floor_code")
            continue
        if name not in STAGES:
            print("%-8s unknown stage" % name)
            rc = 1
            continue
        # -1 = observe: the baseline must be the SHIPPED picture, including a
        # stage that already sets skew_skip for itself.
        base = run_once(args.mame, romdir, STAGES[name], -1,
                        run / name / "base", args.seconds, frozen)
        top, height = band_from_log(base)
        if top is None:
            print("%-8s probe never reached the fight - see %s"
                  % (name, run / name / "base" / "probe.log"))
            rc = 1
            continue
        probe = run_once(args.mame, romdir, STAGES[name], height,
                         run / name / "probe", args.seconds, frozen)
        shots = {}
        for tag in ("base", "probe"):
            d = run / name / tag / "snap"
            shots[tag] = sorted(d.rglob("*.png"))
        if len(shots["base"]) != 3 or len(shots["probe"]) != 3:
            print("%-8s snapshot count mismatch (%d vs %d)"
                  % (name, len(shots["base"]), len(shots["probe"])))
            rc = 1
            continue
        rows = []
        for a, b in zip(shots["base"], shots["probe"]):
            rows.append(first_differing_row(a, b))
        visible = [r for r in rows if r is not None and r >= 0]
        safe = (min(visible) - top) if visible else height
        safe = max(0, safe)
        want = CONTROL.get(name)
        note = ""
        if want is not None:
            note = "  control: expected %d" % want
            if safe != want:
                note += "  <-- MEASUREMENT IS WRONG"
                rc = 1
        print("%-8s band %d..%d (%d rows)  first visible change at screen y %s"
              "  -> %d row(s) skippable%s"
              % (name, top, top + height - 1, height,
                 min(visible) if visible else "none", safe, note))
        results[name] = dict(skew_y=top, height=height, safe_rows=safe,
                             first_change=(min(visible) if visible else None),
                             stops=len(rows))
    (run / "result.json").write_text(json.dumps(results, indent=2) + "\n",
                                     encoding="utf-8")
    print("Results: %s" % (run / "result.json"))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
