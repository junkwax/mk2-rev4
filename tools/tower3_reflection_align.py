#!/usr/bin/env python3
"""Keep THE TOWER's six guard reflections under their guards, and on marble.

Each terracotta guard in data/TOWER3.BDB is mirrored in the polished floor by
a STATREF strip out of data/STATREF.LOD. The strips are NOT blocks - the whole
point of them is that they animate, and a BDB block never does - they are
runtime pid_bani objects created by `tower_reflections` in src/BGND.ASM, drawn
on baklst1 at PLANE3's scroll rate. See the comment block above
tower_reflections for why that plane and that rate.

That makes every reflection's position a DERIVED value living in a different
file from the art it belongs to, exactly like the torches next door:

    a4 = block position - PLANE3's LOAD2-shrunk origin + PLANE3's BGND offset

so it goes stale the moment anything moves - re-spacing the guard row, dragging
the module in BDDTool's Runtime view, or re-cutting a guard all move the
origin or the module width without touching these constants. Nothing in the
editor renders a runtime object, so a stale reflection is invisible until the
game runs.

This checks three things, and the third is the one the flame tool cannot:

  1. every strip is still centred under its guard's BASE block,
  2. src/BGND.ASM's constants still match what the data says,
  3. every strip lands inside the MARBLE, and not on the red carpet.

(3) matters because the effect only reads on stone. The tower floor is
`floor_code`'s skew strip - FL_TOW, which is CASFLOOR1-6 out of MKFLOORS.IMG -
and its near half is a red carpet. A reflection that slides onto the carpet is
not subtly wrong, it is a checkerboard sitting on a rug. Both edges of that
band are read from live data here rather than hardcoded: the floor's top row
comes from tower_floor_info's skew y in BGND.ASM, and the carpet's first row is
measured off the art.

    python tools/tower3_reflection_align.py            # report + check, exit 0/1
    python tools/tower3_reflection_align.py --check    # same, for build.py
    python tools/tower3_reflection_align.py --apply    # rewrite the constants

To MOVE a reflection: it follows its guard automatically. If you want it off
its guard's centre, change the ANCHORS entry here, not src/BGND.ASM.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tower3_statue_layout as T          # noqa: E402  (shared BDB/BDD readers)

NL = T.NL
MODULE = "PLANE3"
ROOT = Path(__file__).resolve().parent.parent
MKFLOORS = ROOT / "data" / "MKFLOORS.IMG"
STATREF_TBL = ROOT / "src" / "STATREF.TBL"

# screen y = plane y - worldtly, and worldtly rests at ceiling_y for this stage
WORLDTLY = -14

# (label, first-frame label, parent BASE block image id, parent flipped?)
#
# Each reflection is anchored to the BOTTOM block of the statue it mirrors -
# the base slice - and centred on it, so it follows its guard automatically and
# only a re-CUT of the art can invalidate it. The parent is identified by
# (image id, M_FLIPH), which is unique for statue art because each mirrored
# pair is one image used twice, once flipped.
#
# The strip's own width comes from src/STATREF.TBL, so a re-cut that changes
# the art width re-centres the strip instead of stranding it.
ANCHORS = [
    ("STATUE1 left",  "STATREF1a", "30", False),
    ("STATUE1 right", "STATREF1a", "30", True),
    ("STATUE2 left",  "STATREF2a", "38", False),
    ("STATUE2 right", "STATREF2a", "38", True),
    ("STATUE3 left",  "STATREF3a", "40", False),
    ("STATUE3 right", "STATREF3a", "40", True),
]

# The order the constants appear inside tower_reflections, which is how --apply
# and --check line them up. Keep this identical to the routine's own order.
EMIT_ORDER = list(range(len(ANCHORS)))

MOVI_A4 = re.compile(r"^(\s*movi\s+)(0[0-9A-Fa-f]{8}h)(\s*,\s*a4\b)(.*)$")
SKEW_Y = re.compile(r"tower_floor_info\b.*?\.word\s+([0-9a-fA-Fh]+)\s*;\s*skew y",
                    re.S)


def art_sizes():
    """{label: (w, h)} from src/STATREF.TBL, or None before the first Phase A."""
    if not STATREF_TBL.exists():
        return None
    out = {}
    text = STATREF_TBL.read_text(errors="replace")
    for m in re.finditer(r"^(\w+):\s*\n\s*\.word\s+(\d+)\s*,\s*(\d+)",
                         text, re.M):
        out[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return out or None


def floor_band():
    """(first floor row, first carpet row) in SCREEN y, both from live data."""
    text = T.BGND_ASM.read_text(errors="replace")
    m = SKEW_Y.search(text)
    if not m:
        raise SystemExit("tower_floor_info's skew y not found in BGND.ASM")
    raw = m.group(1)
    top = int(raw[:-1], 16) if raw.lower().endswith("h") else int(raw)

    # The carpet's first row, measured off CASFLOOR1-6 rather than assumed.
    sys.path.insert(0, str(ROOT))
    from imgdump import detect_record_layout, cstr, IMAGE, PALETTE  # noqa: E402
    data = MKFLOORS.read_bytes()
    imgcnt, palcnt, oset = struct.unpack_from("<HHI", data, 0)[:3]
    _, img_start, pal_start = detect_record_layout(data, oset, imgcnt, palcnt)
    recs = {}
    for i in range(imgcnt):
        f = IMAGE.unpack_from(data, img_start + i * IMAGE.size)
        recs[cstr(f[0])] = f
    f = recs["CASFLOOR1"]
    w, h, palnum, off = f[4], f[5], f[6], f[7]
    pr = PALETTE.unpack_from(data, pal_start + (palnum - 3) * PALETTE.size)
    ncol, poff = pr[3], pr[4]
    pal = struct.unpack_from("<%dH" % ncol, data, poff)
    stride = (w + 3) & ~3
    carpet = h
    for y in range(h):
        red = 0
        for x in range(w):
            v = pal[data[off + y * stride + x]]
            r, g, b = (v >> 10) & 31, (v >> 5) & 31, v & 31
            if r > g + 6 and r > b + 3:
                red += 1
        if red * 10 >= w * 9:              # a row that is essentially all carpet
            carpet = y
            break
    return top, top + carpet


def module_origin_and_offset():
    """(origin x, origin y, BGND .word x, y) for PLANE3, from live data."""
    _head, mods, blocks = T._read_bdb()
    _ids, sizes, _pals = T._bdd_blocks(T.BDD)
    inb = [b for b in blocks if T.assign_module(b, mods, sizes) == MODULE]
    if not inb:
        raise SystemExit(f"no blocks resolve to {MODULE} in {T.BDB.name}")
    ox = min(T._rect(b, sizes)[0] for b in inb)
    oy = min(T._rect(b, sizes)[1] for b in inb)
    offset = T._bgnd_offset(MODULE)
    if offset is None:
        raise SystemExit(f"no .word placement found for {MODULE}BMOD in BGND.ASM")
    return ox, oy, offset[0], offset[1]


def resolve_anchor(blocks, sizes, parent_id, parent_flip, art_w):
    """Raw BDB position of a reflection, centred under its guard's base block."""
    matches = [b for b in blocks
               if b[3].upper() == parent_id.upper()
               and bool(int(b[0], 16) & T.HFLIP) == parent_flip]
    if len(matches) != 1:
        raise LookupError(
            f"parent base block image {parent_id} flip={int(parent_flip)} "
            f"matched {len(matches)} block(s), expected exactly 1")
    x1, y1, x2, y2 = T._rect(matches[0], sizes)
    # _rect is INCLUSIVE (x + w - 1), so the block's true width is x2-x1+1 and
    # the first row BELOW it - where the reflection starts - is y2+1. Using y2
    # put every strip one row high, overlapping the guard's own last row: an
    # invisible pixel, but a guard that encodes an off-by-one teaches it on.
    return x1 + (x2 - x1 + 1 - art_w) // 2, y2 + 1, (x2 - x1 + 1)


def derive(sizes_by_label):
    """[(label, packed, px, py, rawx, rawy, art w, art h, blk w)] per anchor."""
    ox, oy, offx, offy = module_origin_and_offset()
    _head, _mods, blocks = T._read_bdb()
    _ids, sizes, _pals = T._bdd_blocks(T.BDD)
    out = []
    for label, frame, pid, pflip in ANCHORS:
        if sizes_by_label is None:
            aw, ah = {"STATREF1a": (59, 11), "STATREF2a": (53, 21),
                      "STATREF3a": (47, 21)}[frame]
        else:
            if frame not in sizes_by_label:
                raise LookupError(f"{frame} missing from src/STATREF.TBL")
            aw, ah = sizes_by_label[frame]
        bx, by, blkw = resolve_anchor(blocks, sizes, pid, pflip, aw)
        px, py = bx - ox + offx, by - oy + offy
        packed = ((py & 0xFFFF) << 16) | (px & 0xFFFF)
        out.append((label, packed, px, py, bx, by, aw, ah, blkw))
    return out


def read_current(text):
    """The a4 constants inside tower_reflections, in file order."""
    lines = text.split(NL)
    try:
        start = next(i for i, l in enumerate(lines)
                     if l.split(";")[0].strip() == "tower_reflections")
    except StopIteration:
        return None, None, None
    end = start
    while end < len(lines) and lines[end].split(";")[0].strip() != "rets":
        end += 1
    found = []
    for i in range(start, min(end + 1, len(lines))):
        m = MOVI_A4.match(lines[i])
        if m:
            found.append((i, int(m.group(2)[:-1], 16)))
    return lines, start, found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if BGND.ASM has drifted (default anyway)")
    ap.add_argument("--apply", action="store_true",
                    help="rewrite the constants in src/BGND.ASM")
    args = ap.parse_args()

    ox, oy, offx, offy = module_origin_and_offset()
    sizes_by_label = art_sizes()
    try:
        want = derive(sizes_by_label)
    except LookupError as exc:
        print(f"{NL}REFLECTION ALIGNMENT BROKEN:{NL}  {exc}")
        print("  the statue art or the STATREF strips were re-cut;")
        print("  update ANCHORS in this file")
        return 1

    floor_top, carpet_top = floor_band()
    print(f"{MODULE} shrunk origin ({ox},{oy}), BGND .word {offx},{offy}")
    print(f"{len(ANCHORS)} reflection(s), runtime objects on baklst1 at worldtlx3")
    print(f"floor marble band: screen y {floor_top}..{carpet_top - 1} "
          f"(carpet starts {carpet_top})")
    if sizes_by_label is None:
        print("  NOTE: src/STATREF.TBL not built yet - using the LOD's authored"
              " sizes")

    problems = []

    text = T.BGND_ASM.read_text(errors="replace")
    lines, start, found = read_current(text)
    if lines is None:
        problems.append("tower_reflections not found in src/BGND.ASM")
        found = []

    if found is not None and len(found) != len(want):
        problems.append(f"tower_reflections holds {len(found)} a4 constant(s), "
                        f"expected {len(want)}")
    else:
        for (label, packed, px, py, bx, by, aw, ah, blkw), (lineno, cur) in zip(
                [want[i] for i in EMIT_ORDER], found):
            top, bot = py + 14, py + 14 + ah
            flag = "" if cur == packed else f"   <-- STALE, is 0{cur:08X}h"
            print(f"  {label:15s} {aw:2d}x{ah:<2d} under a {blkw:2d}px base"
                  f"  plane({px:4d},{py:4d})  0{packed:08X}h"
                  f"  screen y {top:3d}..{bot:3d}{flag}")
            if cur != packed:
                problems.append(f"{label}: BGND.ASM has 0{cur:08X}h, data says "
                                f"0{packed:08X}h")
            # The effect only reads on stone - see the module docstring.
            if top < floor_top:
                problems.append(f"{label}: starts at screen y {top}, above the "
                                f"floor's top row {floor_top}")
            if bot > carpet_top:
                problems.append(f"{label}: reaches screen y {bot}, onto the red "
                                f"carpet (starts {carpet_top})")

    if args.apply and lines is not None and len(found) == len(want):
        changed = 0
        for (label, packed, *_rest), (lineno, cur) in zip(
                [want[i] for i in EMIT_ORDER], found):
            if cur == packed:
                continue
            m = MOVI_A4.match(lines[lineno])
            lines[lineno] = f"{m.group(1)}0{packed:08X}h{m.group(3)}{m.group(4)}"
            changed += 1
        if changed:
            T.BGND_ASM.write_text(NL.join(lines), newline="")
            print(f"{NL}rewrote {changed} constant(s) in {T.BGND_ASM.name}")
        else:
            print(f"{NL}nothing to rewrite; already aligned")
        return 0

    if problems:
        print(NL + "REFLECTION ALIGNMENT BROKEN:")
        for p in problems:
            print("  " + p)
        print("  re-run with --apply to fix the constants")
        return 1

    print("  reflections aligned: every strip is centred under its guard and "
          "lands on marble")
    return 0


if __name__ == "__main__":
    sys.exit(main())
