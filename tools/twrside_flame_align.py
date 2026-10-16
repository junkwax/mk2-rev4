#!/usr/bin/env python3
"""Aim the guard torches at the statues' poles.

STATUE3 (front) and STATUE4 (back) each carry a torch, but by two different
mechanisms now that they live in different modules (see the tower_flames and
PLANE4BMOD comments in src/BGND.ASM for why):

  * STATUE3's torch is an ANIMATED runtime object on baklst1, positioned by an
    absolute PLANE3-space coordinate baked into tower_flames in BGND.ASM.
  * STATUE4's torch is a STATIC single-frame background block, positioned by
    an ordinary x,y record in data/TWRSIDE.BDB, claimed by PLANE4's module
    alongside the rest of STATUE4 and the pillars.

Both coordinates are absolute PLANE-space positions, not module-relative, so
neither rides the module the way the statue blocks do. Anything that moves a
statue moves its torch out from under it:

  * moving a statue block in BDDTool,
  * re-spacing the row, which changes a module's shrunk width and therefore
    its centring offset,
  * nudging a plane's own .word x,y placement.

This has happened repeatedly, and each time the flames had to be re-measured
by hand. This re-derives both from the data instead.

A pole is found as a narrow local spike in the statue's silhouette: a run of
at most POLE_MAX_W columns whose top edge stands at least POLE_PROMINENCE
pixels above the columns on both sides of it. The head is taller but far
wider, so the width test is what separates them.

The flame is then hung centred on the pole with its base POLE_OVERLAP pixels
into the tip, so it burns on the pole rather than floating over it.

    python tools/twrside_flame_align.py            # report the drift
    python tools/twrside_flame_align.py --apply    # rewrite tower_flames AND
                                                     # reposition the static
                                                     # STATUE4 flame block(s)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BDB = ROOT / "data" / "TWRSIDE.BDB"
BDD = ROOT / "data" / "TWRSIDE.BDD"
META = ROOT / "data" / "TWRSIDE.BDD.meta"
BGND = ROOT / "src" / "BGND.ASM"

DESIGN_CENTRE = 561
HFLIP = 0x10
NL = chr(10)
TAB = chr(9)

POLE_MAX_W = 6          # a pole is narrow; the head is not
POLE_PROMINENCE = 12    # how far it must stand above its neighbours
POLE_OVERLAP = 2        # how far the flame's base sinks into the tip

# STATUEn -> (its module, how its torch is realised, the flame letter/frame).
STATUE_INFO = {
    "3": ("PLANE3", "runtime", "C"),
    "4": ("PLANE4", "static", "D"),
}
FLAME_SIZE = {"A": (10, 29), "B": (10, 26), "C": (8, 15), "D": (6, 18)}


def read_bdd(path):
    d = path.read_bytes()
    pos = d.index(b"\n") + 1
    n = int(d[:pos].split()[0])
    imgs = {}
    for _ in range(n):
        j = d.index(b"\n", pos)
        p = d[pos:j].split()
        idx, w, h = int(p[0], 16), int(p[1]), int(p[2])
        pos = j + 1
        imgs[idx] = (w, h, d[pos:pos + w * h])
        pos += w * h
    return imgs


def read_meta():
    names = {}
    if not META.exists():
        return names
    for line in META.read_text().split(NL):
        f = line.rstrip().split(TAB)
        if len(f) > 2 and f[0] == "IMG" and f[2]:
            names[int(f[1], 16)] = f[2]
    return names


def read_bdb():
    lines = [l for l in BDB.read_text().replace(chr(13), "").split(NL) if l.strip()]
    head = lines[0].split()
    nmods = int(head[4])
    mods = []
    for m in lines[1:1 + nmods]:
        f = m.split()
        mods.append((f[0], (int(f[1]), int(f[2]), int(f[3]), int(f[4]))))
    blocks = [l.split() for l in lines[1 + nmods:1 + nmods + int(head[6])]]
    return head, mods, blocks


def assign_module(b, mods, imgs):
    w, h = imgs[int(b[3], 16)][:2]
    x1, y1 = int(b[1]), int(b[2])
    x2, y2 = x1 + w - 1, y1 + h - 1
    for name, (mx1, mx2, my1, my2) in mods:
        if x1 >= mx1 and y1 >= my1 and x2 <= mx2 and y2 <= my2:
            return name
    return None


def module_origin(module, mods, blocks, imgs):
    inb = [b for b in blocks if assign_module(b, mods, imgs) == module]
    if not inb:
        return None
    return (min(int(b[1]) for b in inb), min(int(b[2]) for b in inb))


def bgnd_offset(module):
    """The .word x,y placement following '.long <module>BMOD' in BGND.ASM."""
    lines = BGND.read_text(errors="replace").split(NL)
    for i, line in enumerate(lines):
        if ".long" not in line.split(";")[0] or module + "BMOD" not in line.split(";")[0]:
            continue
        for nxt in lines[i + 1:i + 8]:
            code = nxt.split(";")[0]
            if ".word" not in code:
                if not (code.strip() == "" or code.lstrip().startswith("*")):
                    break
                continue
            parts = code.split(".word", 1)[1].strip().split(",")
            try:
                return int(parts[0]), int(parts[1])
            except (ValueError, IndexError):
                return None
    return None


def find_pole(points):
    """Leftmost narrow local spike in a silhouette: (x1, x2, top)."""
    cols = {}
    for (x, y) in points:
        cols[x] = min(cols.get(x, 1 << 30), y)
    xs = sorted(cols)
    groups = []
    run = [xs[0]]
    for x in xs[1:]:
        if x - run[-1] == 1 and cols[x] == cols[run[-1]]:
            run.append(x)
        else:
            groups.append(run)
            run = [x]
    groups.append(run)

    best = None
    for g in groups:
        if len(g) > POLE_MAX_W:
            continue
        top = cols[g[0]]
        left = cols.get(g[0] - 1)
        right = cols.get(g[-1] + 1)
        if left is None or right is None:
            continue
        prom = min(left - top, right - top)
        if prom < POLE_PROMINENCE:
            continue
        if best is None or prom > best[0]:
            best = (prom, g[0], g[-1], top)
    return None if best is None else (best[1], best[2], best[3])


def statue_poles(num, mods, blocks, imgs, names):
    """{'left'/'right': (x1, x2, top)} for one statue's absolute-BDB-space
    silhouette (both mirrored halves)."""
    out = {}
    for flip, side in ((0, "left"), (HFLIP, "right")):
        pts = set()
        for b in blocks:
            nm = names.get(int(b[3], 16), "")
            if not nm.startswith("STATUE" + num):
                continue
            if (int(b[0], 16) & HFLIP) != flip:
                continue
            w, h, px = imgs[int(b[3], 16)]
            bx, by = int(b[1]), int(b[2])
            for y in range(h):
                for x in range(w):
                    if px[y * w + x]:
                        pts.add((bx + (w - 1 - x) if flip else bx + x, by + y))
        if pts:
            pole = find_pole(pts)
            if pole:
                out[side] = pole
    return out


def flame_anchor(pole, letter):
    px1, px2, ptop = pole
    fw, fh = FLAME_SIZE[letter]
    wx = (px1 + px2 + 1) // 2 - fw // 2
    wy = ptop - fh + POLE_OVERLAP
    return wx, wy


def check_runtime(num, mods, blocks, imgs, names):
    """STATUE3-style: absolute PLANE-space coordinate baked into
    tower_flames. Returns (problems, [(side, packed_hex)])."""
    module, _kind, letter = STATUE_INFO[num]
    offset = bgnd_offset(module)
    origin = module_origin(module, mods, blocks, imgs)
    if offset is None or origin is None:
        return [f"STATUE{num}: no {module}BMOD placement/origin found"], []
    offx, offy = offset
    ox, oy = origin
    poles = statue_poles(num, mods, blocks, imgs, names)
    rows = []
    for side, pole in sorted(poles.items()):
        wx, wy = flame_anchor(pole, letter)
        plx, ply = offx + wx - ox, offy + wy - oy
        packed = ((ply & 0xFFFF) << 16) | (plx & 0xFFFF)
        print(f"  STATUE{num} {side:<5} pole x{pole[0]}..{pole[1]} top y{pole[2]} -> "
              f"Flame{letter}1 at plane ({plx},{ply})  0{packed:08X}h")
        rows.append((side, packed))
    return [], rows


def check_static(num, mods, blocks, imgs, names):
    """STATUE4-style: an ordinary background block in the BDB. Reports drift;
    --apply rewrites the block's x,y in place (same image, same flags)."""
    module, _kind, letter = STATUE_INFO[num]
    frame_id = next((i for i, n in names.items()
                     if n.upper() == ("FLAME%s1" % letter).upper()), None)
    if frame_id is None:
        return [f"STATUE{num}: no Flame{letter}1 image in the BDD - "
                f"re-add it (see tools/bdd_strip_unused.py history) before "
                f"a static block can reference it"], []
    fw, fh = imgs[frame_id][:2]
    poles = statue_poles(num, mods, blocks, imgs, names)
    existing = [b for b in blocks if int(b[3], 16) == frame_id]
    problems = []
    fixes = []           # (old_block, new_x, new_y)
    seen_sides = set()
    for b in existing:
        flip = bool(int(b[0], 16) & HFLIP)
        side = "right" if flip else "left"
        pole = poles.get(side)
        if pole is None:
            problems.append(f"STATUE{num} {side}: no pole found for the "
                            f"existing static flame block at {b[1]},{b[2]}")
            continue
        wx, wy = flame_anchor(pole, letter)
        seen_sides.add(side)
        cur = (int(b[1]), int(b[2]))
        if cur != (wx, wy):
            problems.append(f"STATUE{num} {side} static flame block is at "
                            f"{cur}, pole wants {(wx, wy)}")
            fixes.append((b, wx, wy))
        print(f"  STATUE{num} {side:<5} pole x{pole[0]}..{pole[1]} top y{pole[2]} -> "
              f"static Flame{letter}1 block at ({wx},{wy})"
              f"{'  (matches)' if cur == (wx, wy) else '  (DRIFTED)'}")
    for side in ("left", "right"):
        if side in poles and side not in seen_sides:
            problems.append(f"STATUE{num} {side}: pole exists but there is no "
                            f"static Flame{letter}1 block for it yet")
    return problems, fixes


def apply_runtime(num, rows):
    module, _kind, letter = STATUE_INFO[num]
    if not rows:
        return False
    src = BGND.read_text(errors="replace")
    start = src.index("tower_flames" + NL + TAB + "movi")
    end = src.index(TAB + "rets" + NL, start) + len(TAB + "rets" + NL)
    phase = {0: "", 1: "+64"}
    body = ["tower_flames", TAB + "movi" + TAB + "Flame%s1,a5" % letter]
    for k, (side, packed) in enumerate(rows):
        tbl = "a_flame_%s%s" % (letter.lower(), phase[k % 2])
        body.append(TAB + "movi" + TAB + "%s,a6" % tbl)
        body.append(TAB + "movi" + TAB + "0%08Xh,a4" % packed + TAB + TAB +
                    "; STATUE%s %s pole" % (num, side))
        body.append(TAB + "callr" + TAB + "make_flame")
    body.append(TAB + "rets")
    new = NL.join(body) + NL
    if src[start:end] == new:
        return False
    BGND.write_text(src[:start] + new + src[end:], newline="")
    return True


def apply_static(fixes):
    if not fixes:
        return False
    lines = [l for l in BDB.read_text().replace(chr(13), "").split(NL) if l.strip()]
    head = lines[0].split()
    nmods = int(head[4])
    body_start = 1 + nmods
    blocks = lines[body_start:body_start + int(head[6])]
    fix_by_key = {(b[1], b[2], b[3], b[4]): (nx, ny) for b, nx, ny in fixes}
    changed = False
    for i, line in enumerate(blocks):
        f = line.split()
        key = (f[1], f[2], f[3], f[4])
        if key in fix_by_key:
            nx, ny = fix_by_key[key]
            blocks[i] = " ".join([f[0], str(nx), str(ny), f[3], f[4]])
            changed = True
    if not changed:
        return False
    lines[body_start:body_start + int(head[6])] = blocks
    BDB.write_text(NL.join(lines) + NL, newline="")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="report drift and exit 1 (the default; build.py passes it)")
    args = ap.parse_args()

    imgs = read_bdd(BDD)
    names = read_meta()
    _head, mods, blocks = read_bdb()

    # No torches at all is a valid, deliberate state (2026-09-03: taken out
    # entirely rather than build a third plane-sharing workaround for them -
    # see project memory).  Only run the real checks once flame art actually
    # exists in the BDD again.
    if not any(n.upper().startswith("FLAME") for n in names.values()):
        print("no torch art in the BDD; nothing to check (torches are "
              "deliberately absent from this build)")
        return 0

    all_problems = []
    runtime_rows = {}
    static_fixes = {}
    for num, (module, kind, letter) in sorted(STATUE_INFO.items()):
        if kind == "runtime":
            probs, rows = check_runtime(num, mods, blocks, imgs, names)
            runtime_rows[num] = rows
        else:
            probs, fixes = check_static(num, mods, blocks, imgs, names)
            static_fixes[num] = fixes
        all_problems += probs

    if all_problems:
        print(NL + "DRIFT:")
        for p in all_problems:
            print("  " + p)

    if not args.apply:
        if all_problems:
            print(NL + "re-run with --apply to fix")
            return 1
        print(NL + "torches already match the poles.")
        return 0

    changed = False
    for num, rows in runtime_rows.items():
        if apply_runtime(num, rows):
            changed = True
            print("rewrote tower_flames for STATUE%s" % num)
    for num, fixes in static_fixes.items():
        if apply_static(fixes):
            changed = True
            print("repositioned the static STATUE%s flame block(s) in data/TWRSIDE.BDB"
                  % num)
    if not changed:
        print("nothing to apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
