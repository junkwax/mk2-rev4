#!/usr/bin/env python3
"""Did the runner pass put THE TOWER's carpet runner back, exactly where it is?

The backdrop reflection covers the back of the floor and the hardware cannot
skip pixels, so without twr_runner_code the wall's reflection lands on the red
runner that leads to the arch. The pass redraws the runner's span on every
line of the band with floor_code's own per-line skew - which is the part worth
testing, because at the centre of the stage the skew is ~0 and ANY x maths
looks right.

So this does not look for "a red run" (the first version did, and took a
fighter's red trousers for the carpet). It computes where floor_code put each
runner line on THIS frame from the values tools/tower_backdrop_test.lua logs at
each camera stop:

    screen y of texture row L = skew_y + (ceiling_y - worldtly) + L
    x of texture column c     = c - 400 + ((skew_oc + L * skew_dx) >> 16)

and checks that every pixel inside twr_runner_tbl's span there is carpet or
gold trim. Anything else is reflection on the carpet (a leak) or the overlay
drawn somewhere else (wrong skew maths) - both land here. The outermost column
each side is skipped: the trim is anti-aliased into the marble.

    python tools/tower_runner_overlay_check.py --log tools/tower_backdrop_test_<tag>.log \
        --dir tools/screens/tower_backdrop/<tag>/mk2
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "src" / "TWRBKREF.ASM"


def runner_table():
    t = TBL.read_text(errors="replace")
    l0 = int(re.search(r"^TWR_RUNL0\s+\.set\s+(\d+)", t, re.M).group(1))
    floorw = int(re.search(r"^TWR_FLOORW\s+\.set\s+(\d+)", t, re.M).group(1))
    blk = t[t.index("twr_runner_tbl"):]
    blk = blk[:blk.index("twr_dmap")]
    spans = [tuple(int(v) for v in m.groups())
             for m in re.finditer(r"\.word\s+(\d+),(\d+)", blk)]
    return l0, floorw, spans


def stops(log: Path):
    out, name = [], None
    for line in log.read_text(errors="replace").splitlines():
        m = re.search(r"\[bk\] === (\w+) ", line)
        if m:
            name = m.group(1)
        m = re.search(r"\[bk\] skew oc=(-?\d+) dx=(-?\d+) skew_y=(-?\d+) "
                      r"ceiling_y=(-?\d+) worldtly=(-?\d+)", line)
        if m and name:
            out.append((name, *(int(v) for v in m.groups())))
    return out


def carpet(c):
    return c[0] > c[1] + 40 and c[0] > c[2] + 25


def gold(c):
    return c[0] >= 140 and c[1] >= 90 and c[2] <= c[1] - 30


def check(png, oc, dx, skew_y, ceil_y, wtly, l0, floorw, spans):
    """Every pixel inside the runner's span must be carpet or its gold trim.

    +-1px of skew is unavoidable slack: with the fighters pinned the scroller
    hunts between two positions, 1px a frame, and the snapshot is a frame away
    from the state the rig read. So each line is tried at off-1/off/off+1 and
    scored on its best fit. A pixel more than two columns INSIDE the span is
    reflection left on the carpet - camera jitter cannot make one of those, so
    it counts at every offset.
    """
    im = Image.open(png).convert("RGB")
    px = im.load()
    start = skew_y + (ceil_y - wtly)
    checked, bad = 0, []
    for k, (r0, r1) in enumerate(spans):
        if r1 < r0:
            continue
        L = l0 + k
        y = start + L
        if not 0 <= y < im.height:
            continue
        base = (oc + L * dx) >> 16                   # sra: floors, like the ASM
        best = None
        for slip in (0, -1, 1):
            off = base + slip
            x0, x1 = r0 - floorw + off, r1 - floorw + off
            a, b = max(0, x0 + 1), min(im.width - 1, x1 - 1)
            if a > b:
                continue
            foreign = [x for x in range(a, b + 1)
                       if not carpet(px[x, y]) and not gold(px[x, y])]
            interior = [x for x in foreign if min(x - x0, x1 - x) > 2]
            cand = (len(interior), len(foreign), slip, x0, x1, b - a + 1,
                    px[foreign[0], y] if foreign else None)
            if best is None or cand[:2] < best[:2]:
                best = cand
        if best is None:
            continue                                 # runner off screen here
        checked += 1
        ni, n, slip, x0, x1, w, col = best
        if n:
            bad.append((y, L, x0, x1, n, ni, w, col, slip))
    return checked, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--dir", required=True)
    args = ap.parse_args()

    l0, floorw, spans = runner_table()
    st = stops(Path(args.log))
    pngs = sorted(Path(args.dir).glob("*.png"))
    if len(st) != len(pngs):
        print(f"{len(st)} stops logged but {len(pngs)} snapshots - cannot pair them")
        return 1
    failed = 0
    for (name, oc, dx, sy, cy, wy), png in zip(st, pngs):
        checked, bad = check(png, oc, dx, sy, cy, wy, l0, floorw, spans)
        off0 = (oc + l0 * dx) >> 16
        print(f"{name:5s} {png.name}: runner at x {spans[0][0] - floorw + off0}.. "
              f"on its first line, {checked} line(s) on screen checked")
        for y, L, x0, x1, n, ni, w, col, slip in bad[:6]:
            where = f"{ni} in the interior" if ni else "all against the edge"
            print(f"    screen y {y} (texture row {L}): {n}/{w} px inside "
                  f"{x0}..{x1} are not carpet ({where}, first is rgb{col}, "
                  f"best fit at skew {slip:+d})")
        leaks = [b for b in bad if b[5]]
        if leaks:
            failed += 1
            print(f"    RUNNER OVERLAY FAIL: reflection on the carpet, "
                  f"{len(leaks)} line(s)")
        elif bad:
            print(f"    clean, but the span over-covers by a pixel on "
                  f"{len(bad)} line(s) - marble redrawn beside the carpet")
        elif checked == 0:
            print("    (runner entirely off screen at this stop - nothing to check)")
        else:
            print("    clean - the carpet is carpet on every line")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
