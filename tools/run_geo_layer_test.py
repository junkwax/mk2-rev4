#!/usr/bin/env python3
"""Prove geo_layer draws CPU geometry BETWEEN display lists.

    python tools/run_geo_layer_test.py --rom-dir tmp/geolayer/rom --map tmp/geolayer/mk2.map

Three boots of tools/geo_layer_test.lua against one frozen ROM - none, front
(geo_pass at dsa9) and layer (geo_layer inside THE WASTELAND's display list) -
with the fighters hidden and the camera parked, then per snapshot:

  line rows      front changes pixels there; the pixels layer leaves alone
                 are the ones a LATER list covers.  The sky row must have none
                 of those; the foreground row must have some, and every such
                 pixel must be exactly the baseline (the foreground art, intact).
  every other    all three boots identical: nothing leaked, CONTROL / dmacmap /
  row            convdp restored, the rest of the frame drew normally.

Private cfg/NVRAM/snapshot directories under mame_mk2test.exe; never kills or
joins another emulator.
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
ROWS = (40, 175)     # the HUD row and a floor row.  More lines cost enough frame time
                     # to shift animation phase between boots (26 rows: 64k off-line diffs)


def boot(mame, frozen, mode, pen, run, seconds):
    d = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), GL_MODE=mode, GL_PEN=str(pen),
               GL_ROWS=",".join(map(str, ROWS)), GL_LOG=str(d / "gl.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option, sub in (("cfg", "cfg"), ("nvram", "nvram"), ("snapshot", "snap"),
                        ("state", "state"), ("input", "input")):
        cmd += ["-" + option + "_directory", str(d / sub)]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/geo_layer_test.lua"),
            "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)
    text = (d / "gl.log").read_text(errors="replace")
    shots = sorted((d / "snap").rglob("*.png"))
    return text, shots


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--pen", type=int, required=True, help="boonpal pen byte")
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--output", type=Path, default=ROOT / "tmp/geolayer/tests")
    args = ap.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    shutil.copy2(args.map, frozen / "src/mk2.map")
    shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")

    modes = ("none", "front", "layer")
    with ThreadPoolExecutor(3) as pool:
        out = dict(zip(modes, pool.map(lambda m: boot(args.mame, frozen, m, args.pen, run, args.seconds), modes)))
    for m in modes:
        res = re.search(r"RESULT (.*)", out[m][0])
        print("%-6s snaps=%d  %s" % (m, len(out[m][1]), res.group(1) if res else "NO RESULT"))
    counts = {len(out[m][1]) for m in modes}
    if counts != {3}:
        print("FAIL: expected 3 snapshots per boot, got %s" % sorted(counts))
        return 1

    report, ok = [], True
    for i in range(3):
        img = {m: Image.open(out[m][1][i]).convert("RGB") for m in modes}
        if len({im.size for im in img.values()}) != 1:
            print("FAIL: snapshot sizes differ"); return 1
        w, h = img["none"].size
        px = {m: img[m].load() for m in modes}
        rec = dict(snapshot=i)
        off_rows = sum(1 for y in range(h) if y not in ROWS for x in range(w)
                       if not (px["none"][x, y] == px["front"][x, y] == px["layer"][x, y]))
        rec["off_line_differences"] = off_rows
        for y in ROWS:
            drawn = [x for x in range(w) if px["front"][x, y] != px["none"][x, y]]
            layer_drawn = [x for x in range(w) if px["layer"][x, y] != px["none"][x, y]]
            covered = [x for x in drawn if px["layer"][x, y] == px["none"][x, y]]
            leaked = [x for x in layer_drawn if px["layer"][x, y] != px["front"][x, y]]
            rec["row%d" % y] = dict(front_drawn=len(drawn), layer_drawn=len(layer_drawn),
                                    covered_by_later_lists=len(covered),
                                    layer_not_matching_front=len(leaked))
        report.append(rec)
        rows = [(y, rec["row%d" % y]) for y in ROWS]
        # over the EARLIER lists: rows the layer line drew in full
        over_earlier = [y for y, r in rows if r["front_drawn"] == 400 and r["layer_drawn"] == 400]
        # under a LATER list: row 40 runs through the life bars (objlst, drawn after it).
        # Coverage by the fighters is tools/run_geo_layer_fighters.py's job.
        under_later = [y for y, r in rows if r["covered_by_later_lists"] > 0]
        mismatched = sum(r["layer_not_matching_front"] for _, r in rows)
        this_ok = off_rows == 0 and mismatched == 0 and over_earlier and under_later
        ok &= bool(this_ok)
        rec.update(over_earlier_rows=over_earlier, under_later_list_rows=under_later)
        print("snap %d: off-line diffs=%d  layer-not-front=%d  fully over earlier lists: %d rows  "
              "covered by later lists: %s  -> %s"
              % (i, off_rows, mismatched, len(over_earlier),
                 ", ".join("%d(%d)" % (y, dict(rows)[y]["covered_by_later_lists"]) for y in under_later) or "none",
                 "ok" if this_ok else "FAIL"))
    (run / "result.json").write_text(json.dumps(dict(passed=ok, snapshots=report), indent=2) + "\n",
                                     encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
