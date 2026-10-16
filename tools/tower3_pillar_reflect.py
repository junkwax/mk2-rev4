#!/usr/bin/env python3
"""Keep THE TOWER's two pillar reflections under their pillars, and on marble.

`tower_pillar_reflections` (src/BGND.ASM) draws each column a second time,
upside down and quarter height, using nothing but m_flipv and a non-square
oscale on the pillar's OWN tile - no art at all. That leaves three things that
live in different files from each other and drift apart silently:

  1. the two base positions, derived like the torches are:
         a4 = block position - PLANE4's shrunk origin + PLANE4's BGND offset
     and stale the moment the pillars are re-spaced or the module is dragged
     in BDDTool's Runtime view;

  2. TWR_PHDR, the R2HDRS index the routine reads the tile out of. PLANE4BLKS
     names it per block. If the block table is re-cut and the pillar lands on a
     different header, the routine happily reflects some OTHER piece of the
     stage and nothing says so;

  3. where the reflection lands. The drawn height is ceil(ysize/4) - the
     DMA ceils a reduction, measured - and, because
     m_flipv makes clip6 add ysize-1 to the destination, the strip occupies
         base .. base + ceil(ysize/4) - 1
     If the tile is ever re-cut taller, that grows DOWNWARD off the marble and
     onto the red carpet in the floor's near half - aligned perfectly and still
     wrong.

    python tools/tower3_pillar_reflect.py            # report + check, exit 0/1
    python tools/tower3_pillar_reflect.py --check    # same, for build.py
    python tools/tower3_pillar_reflect.py --apply    # rewrite the constants
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tower3_statue_layout as T          # noqa: E402  (shared BDB/BDD readers)
import tower3_reflection_align as R       # noqa: E402  (shared floor band)

NL = T.NL
MODULE = "PLANE4"
ROOT = Path(__file__).resolve().parent.parent
BGNDTBL = ROOT / "src" / "BGNDTBL.ASM"

WORLDTLY = -14
HDR_BITS = 80          # one R2HDRS entry: xsize, ysize, sag, ctrl

# (label, which pillar) - left is the unflipped pair, right is M_FLIPH
ANCHORS = [("twr_pillar_left", False), ("twr_pillar_right", True)]

LONG_CONST = re.compile(r"^(\s*\.long\s+)(0[0-9A-Fa-f]{8})(h)(.*)$")


def r2hdrs():
    """[(xsize, ysize, sag, ctrl)] from src/BGNDTBL.ASM."""
    t = BGNDTBL.read_text(errors="replace")
    blk = t[t.index("R2HDRS:"):]
    vals = []
    for kind, rest in re.findall(r"\.(word|long)\s+([^;\n]+)", blk):
        for v in rest.split(","):
            v = v.strip()
            if not v:
                continue
            try:
                vals.append(int(v[:-1], 16) if v.lower().endswith("h") else int(v))
            except ValueError:
                return vals_to_entries(vals)
    return vals_to_entries(vals)


def vals_to_entries(vals):
    out = []
    for i in range(0, len(vals) - 3, 4):
        out.append(tuple(vals[i:i + 4]))
    return out


def plane4_header_index():
    """The header index PLANE4BLKS gives its blocks, if they all agree."""
    t = BGNDTBL.read_text(errors="replace")
    blk = t[t.index("PLANE4BLKS:"):]
    blk = blk[:blk.index("0FFFFH")]
    idx = set()
    for line in blk.splitlines():
        code = line.split(";")[0]
        if ".word" not in code:
            continue
        parts = [p.strip() for p in code.split(".word", 1)[1].split(",")]
        if len(parts) == 4:                      # flags, x, y, hdr
            v = parts[3]
            idx.add(int(v[:-1], 16) if v.lower().endswith("h") else int(v))
    # the leading record carries its header in a .word of its own
    m = re.search(r"\.word\s+([0-9A-Fa-fh]+)\s*;pal5,pal4,hdr13-0", blk)
    if m:
        v = m.group(1)
        idx.add(int(v[:-1], 16) if v.lower().endswith("h") else int(v))
    return idx


def asm_const(name: str):
    """(line number, value) of the .long following `name` in BGND.ASM."""
    lines = T.BGND_ASM.read_text(errors="replace").split(NL)
    for i, line in enumerate(lines):
        if line.split(";")[0].strip() == name:
            for j in range(i + 1, min(i + 4, len(lines))):
                m = LONG_CONST.match(lines[j])
                if m:
                    return j, int(m.group(2), 16)
    return None, None


def scale_from_asm():
    """TWR_PSCALE's ystep, so the drawn height is checked against the real one."""
    t = T.BGND_ASM.read_text(errors="replace")
    m = re.search(r"TWR_PSCALE\s+\.set\s+(0[0-9A-Fa-f]+)h", t)
    if not m:
        return None
    v = int(m.group(1), 16)
    return (v >> 16) & 0xFFFF


def derive():
    """[(label, packed, plane x, plane y, art w, art h)] for both pillars."""
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
    offx, offy = offset

    out = []
    for (label, flip) in ANCHORS:
        half = [b for b in inb if bool(int(b[0], 16) & T.HFLIP) == flip]
        if not half:
            raise LookupError(f"{label}: no {'flipped' if flip else 'plain'} "
                              f"blocks in {MODULE}")
        rs = [T._rect(b, sizes) for b in half]
        x1 = min(r[0] for r in rs)
        # _rect is INCLUSIVE (x + w - 1), so the first row BELOW the column -
        # where its reflection starts - is y2 + 1, not y2.
        y2 = max(r[3] for r in rs) + 1           # the row below the column
        w = max(r[2] for r in rs) - x1
        px, py = x1 - ox + offx, y2 - oy + offy
        packed = ((py & 0xFFFF) << 16) | (px & 0xFFFF)
        out.append((label, packed, px, py, w, y2 - min(r[1] for r in rs)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    problems = []
    try:
        want = derive()
    except LookupError as exc:
        print(f"{NL}PILLAR REFLECTION ALIGNMENT BROKEN:{NL}  {exc}")
        return 1

    floor_top, carpet_top = R.floor_band()
    hdrs = r2hdrs()
    idxs = plane4_header_index()
    t = T.BGND_ASM.read_text(errors="replace")
    m = re.search(r"TWR_PHDR\s+\.set\s+(\d+)", t)
    phdr = int(m.group(1)) if m else None
    ystep = scale_from_asm()

    print(f"{MODULE}: 2 pillar reflections, own display list at worldtlx4")
    print(f"floor marble band: screen y {floor_top}..{carpet_top - 1} "
          f"(carpet starts {carpet_top})")

    if phdr is None or ystep is None:
        problems.append("TWR_PHDR / TWR_PSCALE not found in src/BGND.ASM")
    elif idxs and idxs != {phdr}:
        problems.append(f"PLANE4BLKS uses header index(es) {sorted(idxs)}, "
                        f"but TWR_PHDR is {phdr} - the routine would reflect "
                        f"the wrong piece of art")
    if phdr is not None and phdr < len(hdrs):
        xs, ys, sag, ctrl = hdrs[phdr]
        # the DMA CEILS a reduction - measured by
        # tools/tower_scale_rounding_probe.lua (103 rows: 52/35/21/18/15 at
        # 200/300/4F0/600/700). floor put the reflection a row high.
        drawn = -(-(ys * 0x100) // ystep) if ystep else 0
        print(f"R2HDRS[{phdr}] = {xs}x{ys} sag=0x{sag:08X} ctrl={ctrl:04X}h"
              f"  -> drawn {xs}x{drawn} at ystep 0x{ystep:X}")
    else:
        xs = ys = drawn = 0
        problems.append(f"R2HDRS has no entry {phdr}")

    for (label, packed, px, py, w, tall), (_lbl2, _f) in zip(want, ANCHORS):
        lineno, cur = asm_const(label)
        top = py + 14
        bot = top + drawn
        flag = "" if cur == packed else f"   <-- STALE, is 0{cur:08X}h"
        print(f"  {label:18s} column {w}x{tall}  plane({px:4d},{py:4d})"
              f"  0{packed:08X}h  screen y {top}..{bot - 1}{flag}")
        if cur is None:
            problems.append(f"{label} not found in src/BGND.ASM")
        elif cur != packed:
            problems.append(f"{label}: BGND.ASM has 0{cur:08X}h, data says "
                            f"0{packed:08X}h")
        if top < floor_top:
            problems.append(f"{label}: starts at screen y {top}, above the "
                            f"floor's top row {floor_top}")
        if bot > carpet_top:
            problems.append(f"{label}: reaches screen y {bot}, onto the red "
                            f"carpet (starts {carpet_top})")

    if args.apply:
        lines = T.BGND_ASM.read_text(errors="replace").split(NL)
        changed = 0
        for (label, packed, *_r) in want:
            lineno, cur = asm_const(label)
            if lineno is None or cur == packed:
                continue
            mm = LONG_CONST.match(lines[lineno])
            lines[lineno] = f"{mm.group(1)}0{packed:08X}{mm.group(3)}{mm.group(4)}"
            changed += 1
        if changed:
            T.BGND_ASM.write_text(NL.join(lines), newline="")
            print(f"{NL}rewrote {changed} constant(s) in {T.BGND_ASM.name}")
        else:
            print(f"{NL}nothing to rewrite; already aligned")
        return 0

    if problems:
        print(NL + "PILLAR REFLECTION ALIGNMENT BROKEN:")
        for p in problems:
            print("  " + p)
        print("  re-run with --apply to fix the positions")
        return 1

    print("  pillar reflections aligned: both under their column and on marble")
    return 0


if __name__ == "__main__":
    sys.exit(main())
