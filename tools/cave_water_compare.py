#!/usr/bin/env python3
"""Check tools/cave_water_test.lua's frozen shots of THE CAVE's water.

    python tools/cave_water_compare.py <snapshot dir> <rig log>

Gates (the scene is frozen, so every difference is the renderer's):
  off_b    == off_a                      the scene is still
  rows_0   == off_a, 0 px                every line redrawn from its own ROM row
                                         lands exactly on the plain block's pixels -
                                         offsets, skips, palettes, control words
  rows_p   differs from off only inside the band; every changed pixel is the
  rows_m     plain frame's pixel SHIFT px across, unless something drawn after
  rows_alt   the water (a column, a stalagmite, a fighter) covers it there - at
             least 95%: the rest are the edges of those, which the plain frame
             cannot predict (measured: all 185 of 4917 on fighter/column edges)
  wave_NN  differs from off only inside the band
"""
import re
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as m  # noqa: E402

SHIFT = 2


def load(d, idx):
    im = Image.open(Path(d) / f"{idx:04d}.png").convert("RGB")
    return im.load(), im.size


def main():
    snapdir, logp = sys.argv[1], sys.argv[2]
    shots = {}
    for line in Path(logp).read_text().splitlines():
        mm = re.search(r"SNAP (\d+) (\S+) camx=(-?\d+) camy=(-?\d+)", line)
        if mm:
            shots[mm.group(2)] = (int(mm.group(1)), int(mm.group(3)), int(mm.group(4)))
    idx, camx, camy = shots["off_a"]
    off, (W, H) = load(snapdir, idx)
    _, _, my = m.PLACE[m.WATER["module"]]
    y0 = my + m.WATER["top"] - camy
    y1 = my + m.WATER["bottom"] - camy
    band = range(max(0, y0), min(H, y1 + 1))
    print(f"camera x3={camx} y={camy}: water band on screen rows {y0}..{y1}")
    fails = 0

    def diff(a, b, rows=None):
        rows = range(H) if rows is None else rows
        return [(x, y) for y in rows for x in range(W) if a[x, y] != b[x, y]]

    def gate(name, ok, msg):
        nonlocal fails
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {msg}")
        fails += 0 if ok else 1

    b, _ = load(snapdir, shots["off_b"][0])
    d = diff(off, b)
    gate("off_b == off_a", not d, f"{len(d)} px")
    r0, _ = load(snapdir, shots["rows_0"][0])
    d = diff(off, r0)
    gate("rows_0 == off", not d, f"{len(d)} px" + (f", rows {sorted({y for _, y in d})[:10]}" if d else ""))

    for name, sh in (("rows_p", lambda y: SHIFT), ("rows_m", lambda y: -SHIFT),
                     ("rows_alt", lambda y: -SHIFT if y & 1 else SHIFT)):
        img, _ = load(snapdir, shots[name][0])
        d = diff(off, img)
        outside = [p for p in d if p[1] not in band]
        shifted = sum(1 for x, y in d if 0 <= x - sh(y) < W and img[x, y] == off[x - sh(y), y])
        gate(name, not outside and shifted >= 0.95 * len(d),
             f"{len(d)} px changed, {len(outside)} outside the band, "
             f"{shifted} ({100 * shifted / max(1, len(d)):.1f}%) are the plain pixel {'+/-' if name == 'rows_alt' else ''}{abs(SHIFT)} px across")
    # the skull pile: every bone pixel the tool keeps still, in screen space
    imgs, order, pals, mods = m.runtime_modules()
    W_ = m.WATER
    mod = next(mm for mm in mods if mm["name"] == W_["module"])
    _, mx, _ = m.PLACE[W_["module"]]
    bones = set()
    for bl in mod["blocks"]:
        if bl["pal"] != W_["bone_pal"]:
            continue
        im, pal = imgs[bl["hdr"]], pals[bl["pal"]][1]
        for yy in range(im["h"]):
            for xx in range(im["w"]):
                v = im["px"][yy * im["w"] + xx]
                c = pal[v] if v else 0
                if v and ((c >> 10) & 31) + ((c >> 5) & 31) + (c & 31) >= W_["bone_lum"] \
                        and bl["rx"] + xx < W_["bone_x"]:
                    sx, sy = mx + bl["rx"] + xx - camx, my + bl["ry"] + yy - camy
                    if 0 <= sx < W and sy in band:
                        bones.add((sx, sy))
    for name in ("rows_p", "rows_m", "rows_alt") + tuple(sorted(k for k in shots if k.startswith("wave_"))):
        img, _ = load(snapdir, shots[name][0])
        moved = [p for p in bones if img[p] != off[p]]
        gate(f"{name} bones", not moved or not bones,
             f"{len(moved)} of {len(bones)} skull-pile pixels changed" + (f", e.g. {moved[:4]}" if moved else ""))
    for name in sorted(k for k in shots if k.startswith("wave_")):
        img, _ = load(snapdir, shots[name][0])
        d = diff(off, img)
        outside = [p for p in d if p[1] not in band]
        gate(name, not outside and d, f"{len(d)} px changed, {len(outside)} outside the band")
    print("RESULT", "PASS" if not fails else f"FAIL ({fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
