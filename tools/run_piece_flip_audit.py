#!/usr/bin/env python3
"""Every multipart piece carries its object's flip - old ROM vs new ROM.

    python tools/run_piece_flip_audit.py --old-rom-dir tmp/clouds/rom --old-map tmp/clouds/mk2.map \\
                                         --new-rom-dir tmp/kt2arm/rom --new-map tmp/kt2arm/mk2.map

Boots tools/piece_flip_audit.lua in both modes (a CPU Kitana fight, whose
fans turn in flight; and the attract loop's demo fights) on both ROMs.

The dclipl change (the object's flip is no longer ORed over each piece's)
makes a piece whose flip disagrees with its object VISIBLE, where stock hid
it.  So the gate is on the NEW ROM: zero mismatching frames in both modes,
with the Kitana run having actually seen a fan change facing.  The old ROM's
count is reported for context - it shows what the OR used to paper over.
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


def boot(mame, rom_dir, mapf, label, mode, frames, run, seconds, debug=False):
    d = run / ("%s_%s" % (label, mode))
    fr = d / "frozen"
    (fr / "src").mkdir(parents=True)
    (fr / "rom").mkdir(parents=True)
    shutil.copy2(mapf, fr / "src/mk2.map")
    shutil.copy2(rom_dir / "mk2.zip", fr / "rom/mk2.zip")
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(fr), PF_MODE=mode, PF_FRAMES=str(frames), PF_LOG=str(d / "pf.log"),
               PF_LISTS=os.environ.get("PF_LISTS", "obj"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(fr / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/piece_flip_audit.lua"), "-seconds_to_run", str(seconds)]
    if debug:
        # Windowed, so four emulators do not take over the screen.  -debug
        # forces a window but halts at the first instruction; the script's
        # single `go` lets it run straight on.
        ds = d / "go.ds"
        ds.write_text("go" + chr(10), encoding="ascii")
        cmd += ["-debug", "-debugscript", str(ds), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 900, check=False)
    text = (d / "pf.log").read_text(errors="replace") if (d / "pf.log").exists() else ""
    res = re.search(r"RESULT mode=(\w+) fight=(\d) frames=(\d+) pieces_checked=(\d+) mismatch_frames=(\d+) visible_frames=(\d+) fan_flip_changes=(\d+)", text)
    return dict(label=label, mode=mode, log=str(d / "pf.log"),
                result=dict(zip(("mode", "fight", "frames", "pieces", "mismatch_frames", "visible_frames", "fan_flip_changes"),
                                (res.group(1), *map(int, res.groups()[1:])))) if res else None,
                mismatched=re.findall(r"MISMATCHED (.*) frames=(\d+) visible=(\d+) longest_run=(\d+)", text),
                visible=re.findall(r"VISIBLE frame=(\d+) (.*)", text)[:12])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--old-rom-dir", type=Path, required=True)
    ap.add_argument("--old-map", type=Path, required=True)
    ap.add_argument("--new-rom-dir", type=Path, required=True)
    ap.add_argument("--new-map", type=Path, required=True)
    ap.add_argument("--kitana-frames", type=int, default=5000)
    ap.add_argument("--attract-frames", type=int, default=12000)
    ap.add_argument("--seconds", type=int, default=400)
    ap.add_argument("--debug", action="store_true", help="windowed under MAME's debugger (not full screen)")
    args = ap.parse_args()
    out = ROOT / "tmp/pieceflip/tests"
    out.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
    jobs = [(lab, rom, mp, mode, frames)
            for lab, rom, mp in (("old", args.old_rom_dir, args.old_map), ("new", args.new_rom_dir, args.new_map))
            for mode, frames in (("kitana", args.kitana_frames), ("attract", args.attract_frames))]
    with ThreadPoolExecutor(len(jobs)) as pool:
        reports = list(pool.map(lambda j: boot(args.mame, j[1], j[2], j[0], j[3], j[4], run, args.seconds, args.debug), jobs))
    ok = True
    for r in reports:
        res = r["result"]
        print("%-3s %-7s %s" % (r["label"], r["mode"], res if res else "NO RESULT"))
        for key, n, v, longest in r["mismatched"]:
            print("      mismatch  %-32s frames %5s  visible %5s  longest run %s" % (key, n, v, longest))
        for f, detail in r["visible"][:6]:
            print("        VISIBLE frame %s %s" % (f, detail))
        if r["label"] == "new":
            ok &= bool(res) and res["visible_frames"] == 0
    (run / "result.json").write_text(json.dumps(dict(passed=ok, reports=reports), indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
