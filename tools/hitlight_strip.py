#!/usr/bin/env python3
"""Crop the struck fighter out of a hitlight_test run into one side-by-side strip.

    python tools/hitlight_strip.py tmp/hitlight/tests/run-XXXX

Pairs the run's snapshots (lit/snap/mk2/0000.png, 0001.png, ...) with the
rig's SNAP log lines in order, crops a window around P1 (the fighter being
lit) using the screen x the rig logged, scales it up and lays the frames out
left to right with their labels.  Writes <run>/lit/strip.png.

The exact colour check in the rig is the proof; this is the picture of it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HALF_W, TOP, BOTTOM, SCALE = 70, 40, 254, 2


def main():
    run = Path(sys.argv[1])
    log = (run / "lit" / "hitlight.log").read_text(errors="replace")
    snaps = re.findall(r"^\[hl\] SNAP (\S+) frame=\d+ p1x=(-?\d+) p2x=(-?\d+)", log, re.M)
    pngs = sorted((run / "lit" / "snap").rglob("*.png"))
    if not snaps or len(pngs) != len(snaps):
        raise SystemExit("have %d snapshots but %d SNAP lines" % (len(pngs), len(snaps)))
    tiles = []
    for (label, p1x, _p2x), png in zip(snaps, pngs):
        im = Image.open(png).convert("RGB")
        x = int(p1x)
        box = (max(0, x - HALF_W), TOP, min(im.width, x + HALF_W), BOTTOM)
        tile = im.crop(box).resize(((box[2] - box[0]) * SCALE, (box[3] - box[1]) * SCALE),
                                   Image.NEAREST)
        canvas = Image.new("RGB", (tile.width, tile.height + 18), (0, 0, 0))
        canvas.paste(tile, (0, 18))
        ImageDraw.Draw(canvas).text((4, 3), label, fill=(255, 255, 255))
        tiles.append(canvas)
    strip = Image.new("RGB", (sum(t.width for t in tiles) + 4 * (len(tiles) - 1),
                              max(t.height for t in tiles)), (40, 40, 40))
    x = 0
    for t in tiles:
        strip.paste(t, (x, 0))
        x += t.width + 4
    out = run / "lit" / "strip.png"
    strip.save(out)
    print(out)


if __name__ == "__main__":
    main()
