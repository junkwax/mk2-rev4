#!/usr/bin/env python3
"""Keep TOWER3's six guard torches pinned to their poles.

Each terracotta guard in data/TOWER3.BDB holds a torch. The flames are NOT
blocks - a BDB block never animates - they are runtime pid_bani objects created
by `tower_flames` in src/BGND.ASM, drawn on baklst1 at PLANE3's scroll rate.
See the comment block above tower_flames for why that plane and that rate.

That makes each flame's position a DERIVED value living in a different file
from the art it belongs to:

    a4 = block position - PLANE3's LOAD2-shrunk origin + PLANE3's BGND offset

so it goes stale the moment anything moves:

  * re-spacing the guard row moves the module's shrunk origin,
  * dragging the module in BDDTool's Runtime view rewrites PLANE3's .word,
  * re-cutting a guard changes the module width, which moves the .word too.

None of those touch the flame constants, and nothing in the editor renders a
runtime object, so a stale flame is invisible until the game runs - it hangs in
mid-air where the old maths put it while the statue walks out from under it.
That bit the TWRSIDE version of this three times in one session, which is why
this check exists and why build.py runs it.

The ANCHORS below are the authored truth: the raw BDB positions of the six
flame placeholder blocks the stage author placed in BDDTool, one on each pole.
The placeholder blocks themselves were stripped from the BDB (they would have
painted a second, static flame under every animated one) and their art was
stripped from the BDD (the runtime draws MKBGANI.TBL's FlameA1-C4 instead, which
cost no image ROM). Everything else is re-derived from live data.

    python tools/tower3_flame_align.py            # report + check, exit 0/1
    python tools/tower3_flame_align.py --check    # same, for build.py
    python tools/tower3_flame_align.py --apply    # rewrite the constants

To MOVE a torch: re-place its placeholder block in BDDTool, read the new raw
x,y off it, update ANCHORS here, run --apply, then strip the placeholder again
(tools/bdd_strip_unused.py) so it does not double-draw.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tower3_statue_layout as T          # noqa: E402  (shared BDB/BDD readers)

NL = T.NL
MODULE = "PLANE3"

# (label, flame letter, animation-table expression, parent image id, parent
#  flipped?, dx, dy)
#
# Each torch is anchored RELATIVE to the statue block it hangs on - the head/pole
# band - not to an absolute BDB position. The author places the flames on the
# poles in BDDTool; storing where they landed as raw x,y meant every later move
# of the row silently stranded them (which is exactly what happened the first
# time the guards were spread wider). Keyed this way they follow their statue
# automatically, and only a re-CUT of the art can invalidate them.
#
# The parent is identified by (image id, M_FLIPH), which is unique for statue
# art because each mirrored pair is one image used twice, once flipped. dx/dy
# are measured from the parent block's top-left, so the left and right halves of
# a pair carry DIFFERENT dx: the block's top-left is the same corner either way,
# but the art inside is mirrored, putting the pole on the opposite side.
#
# The table expression carries the phase: each .long is 32 bits, so +32 is one
# frame of the four-frame loop. Staggering stops six flames strobing in unison.
ANCHORS = [
    ("STATUE1 left pole",  "A", "a_flame_a",    "2A", False,  -4, -27),
    ("STATUE1 right pole", "A", "a_flame_a+64", "2A", True,   60, -28),
    ("STATUE2 left pole",  "B", "a_flame_b+32", "32", False,  -4, -27),
    ("STATUE2 right pole", "B", "a_flame_b+96", "32", True,   53, -25),
    ("STATUE3 left pole",  "C", "a_flame_c+64", "3A", False,  -3, -14),
    ("STATUE3 right pole", "C", "a_flame_c",    "3A", True,   46, -13),
]

# The order the constants appear inside tower_flames, which is how --apply and
# --check line them up. Keep this identical to the routine's own order.
EMIT_ORDER = list(range(len(ANCHORS)))

MOVI_A4 = re.compile(r"^(\s*movi\s+)(0[0-9A-Fa-f]{8}h)(\s*,\s*a4\b)(.*)$")


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


def module_box():
    """PLANE3's authored rectangle, to sanity-check the anchors still sit in it."""
    _head, mods, _blocks = T._read_bdb()
    for name, rect in mods:
        if name == MODULE:
            return rect
    return None


def resolve_anchor(blocks, parent_id, parent_flip, dx, dy):
    """Raw BDB position of a torch, from its parent statue block.

    Returns (x, y) or raises if the parent is missing or ambiguous - either
    means the art was re-cut and the anchor table needs revisiting, which is
    worth stopping the build for rather than guessing at.
    """
    matches = [b for b in blocks
               if b[3].upper() == parent_id.upper()
               and bool(int(b[0], 16) & T.HFLIP) == parent_flip]
    if len(matches) != 1:
        raise LookupError(
            f"parent block image {parent_id} flip={int(parent_flip)} matched "
            f"{len(matches)} block(s), expected exactly 1")
    p = matches[0]
    return int(p[1]) + dx, int(p[2]) + dy


def derive():
    """[(label, packed value, plane x, plane y, raw x, raw y)] for every anchor."""
    ox, oy, offx, offy = module_origin_and_offset()
    _head, _mods, blocks = T._read_bdb()
    out = []
    for label, _letter, _table, pid, pflip, dx, dy in ANCHORS:
        bx, by = resolve_anchor(blocks, pid, pflip, dx, dy)
        px = bx - ox + offx
        py = by - oy + offy
        packed = ((py & 0xFFFF) << 16) | (px & 0xFFFF)
        out.append((label, packed, px, py, bx, by))
    return out


def read_current(text):
    """The a4 constants inside tower_flames, in file order."""
    lines = text.split(NL)
    try:
        start = next(i for i, l in enumerate(lines)
                     if l.split(";")[0].strip() == "tower_flames")
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
    try:
        want = derive()
    except LookupError as exc:
        print(f"{NL}FLAME ALIGNMENT BROKEN:{NL}  {exc}")
        print("  the statue art was re-cut; update ANCHORS in this file")
        return 1
    box = module_box()

    print(f"{MODULE} shrunk origin ({ox},{oy}), BGND .word {offx},{offy}")
    print(f"{len(ANCHORS)} torch(es), runtime objects on baklst1 at worldtlx3")

    problems = []

    # A torch resolved outside the module it is measured against means the
    # anchor no longer describes the art - worth failing rather than shipping a
    # flame hanging off the end of the row.
    if box:
        bx1, bx2, by1, by2 = box
        for (label, _packed, _px, _py, ax, ay) in want:
            if not (bx1 <= ax <= bx2 and by1 <= ay <= by2):
                problems.append(f"{label} resolves to ({ax},{ay}), outside "
                                f"{MODULE}'s box {bx1},{bx2},{by1},{by2}")

    text = T.BGND_ASM.read_text(errors="replace")
    lines, start, found = read_current(text)
    if lines is None:
        problems.append("tower_flames not found in src/BGND.ASM")
        found = []

    if found is not None and len(found) != len(want):
        problems.append(f"tower_flames holds {len(found)} a4 constant(s), "
                        f"expected {len(want)}")
    else:
        for (label, packed, px, py, bx, by), (lineno, cur) in zip(
                [want[i] for i in EMIT_ORDER], found):
            flag = "" if cur == packed else f"   <-- STALE, is 0{cur:08X}h"
            print(f"  {label:20s} raw({bx:4d},{by:4d})  plane({px:4d},{py:4d})"
                  f"  0{packed:08X}h  screen({px - T.WORLDTLX0:4d},{py + 14:4d}){flag}")
            if cur != packed:
                problems.append(f"{label}: BGND.ASM has 0{cur:08X}h, data says "
                                f"0{packed:08X}h")

    if args.apply and lines is not None and len(found) == len(want):
        changed = 0
        for (label, packed, _px, _py, _bx, _by), (lineno, cur) in zip(
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
        print(NL + "FLAME ALIGNMENT BROKEN:")
        for p in problems:
            print("  " + p)
        print("  re-run with --apply to fix the constants")
        return 1

    print("  flames aligned: every torch matches the row's current placement")
    return 0


if __name__ == "__main__":
    sys.exit(main())
