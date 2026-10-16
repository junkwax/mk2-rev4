#!/usr/bin/env python3
"""Guard the terracotta guards in data/TWRSIDE.BDB.

TWRSIDE is TOWER2 plus the terracotta guards out of CASTLE.IMG, each on its
OWN module/plane (reset from a stock TOWER2.BDB/.BDD base, 2026-09-03): STATUE3
(front, PLANE3, baklst3, 0.8125x) and STATUE4 (back, PLANE1, baklst1, borrows
PLANE4's 0.6875x via dlists_tower - see the baklst1 comment in BGND.ASM's
tower_mod).  Two earlier designs (both statues sharing one module; STATUE4
sharing the pillars' module) each needed real workarounds and both eventually
went wrong enough to warrant starting over from stock rather than patching
further - see project memory for the full history if reviving either.

The art is cut and placed in BDDTool; this script does not generate the
layout, it asserts the rules the layout has to keep, because none of them are
visible on BDDTool's flat canvas and all of them fail silently in the game:

  * A block joins the FIRST module (in BDB file order) whose box fully
    contains it.  Dropped inside the wrong module's box, a guard is silently
    reassigned to whatever that module scrolls at, and the module's origin is
    re-cropped to the guard's edge, which can slide OTHER content in that
    module sideways too.  Each statue must land in ITS OWN intended module,
    not merely in "some" module.
  * Blocks inside a module are found with a BINARY SEARCH on x (`bsrch1stxb`,
    BAKGND.ASM), so the records must be sorted by ascending canvas x WITHIN
    EACH MODULE or the later ones are simply never added to the display list.
  * Draw order inside one baklst is by the z byte: `insobj_v` (MKDISP.ASM)
    keeps the list ASCENDING in z, and the head is queued first, so the
    LOWEST z is furthest back and the HIGHEST z is in front.  A receding row
    needs the near guard to carry the highest z; equal z ties break on y and
    put the nearest guard behind the rest.
  * LOAD2 shrinks a module to the bounding box of its blocks.  PLANE3 places
    at (design centre - width/2); re-cutting STATUE3 changes that width, so
    the offset has to move with it or the row slides sideways.  PLANE4 is
    retail stock content (the pillars) sharing its module with STATUE4 now,
    so its offset instead has to move by exactly the amount its shrunk origin
    moved, to keep every retail pillar pixel exactly where it always was.

Everything is expressed as an invariant over whatever is in the BDB, so
re-cutting or re-spacing the art never breaks this check - only breaking a
rule does.

    python tools/twrside_statue_layout.py            # report + check, exit 0/1
    python tools/twrside_statue_layout.py --check    # same, for build.py

--check also proves TWRSIDE's STOCK half is still TOWER2.  TWRSIDE is not in
mk2-readonly, so tools/check_stock_bg_assets.py cannot reference-compare it; it
compares data/TOWER2.BDB/.BDD instead and this compares TWRSIDE against those.
A BDDTool round-trip that nudges the retail wall then fails here rather than
shipping.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

NL = chr(10)
CRLF = chr(13) + chr(10)
TAB = chr(9)

ROOT = Path(__file__).resolve().parent.parent
BDB = ROOT / "data" / "TWRSIDE.BDB"
BDD = ROOT / "data" / "TWRSIDE.BDD"
STOCK_BDB = ROOT / "data" / "TOWER2.BDB"
STOCK_BDD = ROOT / "data" / "TOWER2.BDD"
BGND_ASM = ROOT / "src" / "BGND.ASM"

# Deliberate authored differences from stock TOWER2, kept as an explicit list so
# that any FURTHER drift still fails.  Format: stock record -> TWRSIDE record.
#
# The two right-hand pillars were raised 3px in BDDTool so the pair lines up with
# the left-hand pair exactly (retail has them 3px lower).  This also takes
# PLANE4BMOD from 393x209 to 393x206; its origin and world offset are unchanged.
ALLOWED_STOCK_EDITS = {
    "4430 879 416 12 2": "4430 879 413 12 2",
    "4400 881 519 12 2": "4400 881 516 12 2",
}

PALETTE = 3                   # R2PALS slot 3 = STATUE (src/BGNDPAL.ASM)

# Which module each statue is authored into.  Data-driven so a future split
# (or un-split) only needs this table changed, not the checks below.  STATUE3
# is the front guard, on its own dedicated plane; STATUE4 is the back guard,
# sharing the pillars' plane per Midway's own "smallest statue #1" comment.
STATUE_MODULE = {"3": "PLANE3", "4": "PLANE1"}

# Design camera: every plane starts at worldtlx 361 and worldtly is -14, so
#   screen x = world x - 361      screen y = world y + 14
# ground_y 229 puts the fighting line at screen y 243.
WORLDTLX0 = 361
SCREEN_W = 400
CENTRE_X = SCREEN_W // 2      # world 561, where the arch and the pillars centre
DESIGN_CENTRE = WORLDTLX0 + CENTRE_X          # world 561

# All three custom/mirrored modules are centred by the DESIGN_CENTRE formula:
# PLANE3 (STATUE3, front guard), PLANE1 (STATUE4, back guard - see the
# baklst1 comment in BGND.ASM's tower_mod for why it needs its own plane
# again after two earlier attempts to share one), and PLANE4 (the pillars).
# PLANE4 is genuine stock content once more as of the 2026-09-03 reset - the
# design-centre formula still validates it correctly (365,-31, exactly
# Midway's own value) because retail centred its own stage on the same arch.
CENTRED_MODULES = ("PLANE3", "PLANE1", "PLANE4")

HFLIP = 0x10                  # M_FLIPH: the mirrored half of each pair


def _bdd_blocks(path: Path):
    """(ordered ids, {id: (w, h, pixels)}, [(pal name, colours)])."""
    d = path.read_bytes()
    pos = d.index(b"\n") + 1
    n = int(d[:pos].split()[0])
    ids, blocks = [], {}
    for _ in range(n):
        j = d.index(b"\n", pos)
        p = d[pos:j].split()
        idx, w, h = int(p[0], 16), int(p[1]), int(p[2])
        pos = j + 1
        blocks[idx] = (w, h, d[pos:pos + w * h])
        ids.append(idx)
        pos += w * h
    pals = []
    while pos < len(d):
        j = d.index(b"\n", pos)
        nm, cnt = d[pos:j].split()
        cnt = int(cnt)
        pos = j + 1
        pals.append((nm.decode(), [struct.unpack_from("<H", d, pos + 2 * k)[0]
                                   for k in range(cnt)]))
        pos += 2 * cnt
    return ids, blocks, pals


def _read_bdb(path: Path = BDB):
    """(header fields, [(module name, (x1,x2,y1,y2))] in BDB order, [block fields])."""
    lines = path.read_text().replace(CRLF, NL).strip().split(NL)
    head = lines[0].split()
    nmods = int(head[4])
    mods = []
    for m in lines[1:1 + nmods]:
        f = m.split()
        mods.append((f[0], (int(f[1]), int(f[2]), int(f[3]), int(f[4]))))
    blocks = [b.split() for b in lines[1 + nmods:] if b.strip()]
    return head, mods, blocks


def _rect(b, sizes):
    w, h = sizes[int(b[3], 16)][:2]
    x, y = int(b[1]), int(b[2])
    return x, y, x + w - 1, y + h - 1


def assign_module(b, mods, sizes):
    """Which module (name) a block resolves to under LOAD2's real rule: the
    FIRST module in file order whose box fully contains it.  None if no
    module claims it (LOAD2 silently drops such a block)."""
    x1, y1, x2, y2 = _rect(b, sizes)
    for name, (mx1, mx2, my1, my2) in mods:
        if x1 >= mx1 and y1 >= my1 and x2 <= mx2 and y2 <= my2:
            return name
    return None


def _live_only_ids():
    """BDD image ids present in TWRSIDE but not in stock TOWER2 - the guards."""
    stock_ids, _sz, _p = _bdd_blocks(STOCK_BDD)
    live_ids, _sz2, _p2 = _bdd_blocks(BDD)
    return [i for i in live_ids if i not in set(stock_ids)]


def _statue_ids():
    """{block image id: statue number string} for every STATUEn image, from
    the BDD sidecar metadata.  Guard torches and other custom PLANE3/PLANE4
    art (the flames) are excluded - they are not part of the receding-row
    checks (depth ramp, mirror pairs, palette)."""
    meta = BDD.with_suffix(".BDD.meta")
    live = set(_live_only_ids())
    out = {}
    if not meta.exists():
        return out
    for line in meta.read_text().split(NL):
        f = line.rstrip().split(TAB)
        if len(f) > 2 and f[0] == "IMG" and f[2]:
            iid = int(f[1], 16)
            if iid in live and f[2].upper().startswith("STATUE"):
                out[iid] = f[2][6]     # "STATUE3_00_01" -> "3"
    return out


def _bgnd_offset(module: str):
    """The .word x,y placement following '.long <module>BMOD' in BGND.ASM."""
    if not BGND_ASM.exists():
        return None
    lines = BGND_ASM.read_text(errors="replace").split(NL)
    for i, line in enumerate(lines):
        code = line.split(";")[0]
        if ".long" not in code or f"{module}BMOD" not in code:
            continue
        for nxt in lines[i + 1:i + 8]:
            code2 = nxt.split(";")[0]
            if ".word" not in code2:
                if not (code2.strip() == "" or code2.lstrip().startswith("*")):
                    break
                continue
            parts = code2.split(".word", 1)[1].strip().split(",")
            try:
                return int(parts[0]), int(parts[1])
            except (ValueError, IndexError):
                return None
    return None


def _module_origin(module: str, mods, blocks, sizes):
    """Shrunk top-left of whatever CURRENTLY resolves into `module`."""
    inb = [b for b in blocks if assign_module(b, mods, sizes) == module]
    if not inb:
        return None
    return (min(_rect(b, sizes)[0] for b in inb),
            min(_rect(b, sizes)[1] for b in inb))


def layout_invariants():
    """Report every way the guard layout breaks a rule the game cares about."""
    problems = []
    _head, mods, blocks = _read_bdb()
    _ids, sizes, _pals = _bdd_blocks(BDD)
    statue_ids = _statue_ids()
    mod_names = [m[0] for m in mods]

    for want_mod in set(STATUE_MODULE.values()):
        if want_mod not in mod_names:
            return [f"module {want_mod} is not declared in data/TWRSIDE.BDB "
                    f"(has {mod_names})"], None

    guard_ids = set(_live_only_ids())
    guard_blocks = [b for b in blocks if int(b[3], 16) in guard_ids]
    if not guard_blocks:
        return ["no guard blocks found in data/TWRSIDE.BDB"], None

    # 1. every statue's blocks resolve to ITS OWN intended module - not
    #    unassigned, and not stolen by an earlier module in file order.
    misassigned = []
    for b in guard_blocks:
        num = statue_ids.get(int(b[3], 16))
        if num is None:
            continue                          # non-statue guard art (torches)
        want = STATUE_MODULE.get(num)
        got = assign_module(b, mods, sizes)
        if got != want:
            misassigned.append(f"{b[1]},{b[2]} hdr {b[3]} (STATUE{num}) -> "
                               f"{got or 'UNASSIGNED'}, expected {want}")
    if misassigned:
        problems.append(f"{len(misassigned)} statue block(s) landed in the wrong "
                        f"module: {misassigned[:6]}")

    # 2. ascending x PER ACTUAL MODULE, or bsrch1stxb never reaches the tail.
    by_module = {}
    for b in blocks:
        m = assign_module(b, mods, sizes)
        if m:
            by_module.setdefault(m, []).append(int(b[1]))
    for name in mod_names:
        xs = by_module.get(name, [])
        inv = [i for i in range(1, len(xs)) if xs[i] < xs[i - 1]]
        if inv:
            problems.append(f"{len(inv)} record(s) in {name} break ascending-x "
                            f"order (first at record {inv[0]}, x {xs[inv[0]]} "
                            f"after {xs[inv[0] - 1]})")

    # 3. the depth ramp: higher z must be the nearer guard, i.e. the one whose
    #    art reaches further down the floor.  Compared ONLY within one module's
    #    own list - insobj_v's ascending-z sort is a WITHIN-LIST rule
    #    (MKDISP.ASM), so z is not comparable across two statues that ended up
    #    in different modules (different baklst lists, drawn as separate,
    #    independently-ordered draw calls). STATUE3 vs STATUE4's relative
    #    depth is enforced by dlists_tower's DRAW ORDER instead once they are
    #    split (PLANE4 always draws before PLANE3), not by z value.
    depth_by_module = {}
    for b in guard_blocks:
        if int(b[3], 16) not in statue_ids:
            continue
        m = assign_module(b, mods, sizes)
        z = int(b[0], 16) >> 8
        depth_by_module.setdefault(m, {}).setdefault(z, []).append(_rect(b, sizes)[3])
    for m, depth in depth_by_module.items():
        ramp = sorted((z, max(v)) for z, v in depth.items())
        for (za, bottom_a), (zb, bottom_b) in zip(ramp, ramp[1:]):
            if bottom_b < bottom_a:
                problems.append(f"{m}: depth ramp inverted: z {zb:02X} sits nearer "
                                f"the camera than z {za:02X} but its art stops "
                                f"higher ({bottom_b} vs {bottom_a})")

    # 4. palette: every statue block shares one palette.
    statues = [b for b in guard_blocks if int(b[3], 16) in statue_ids]
    bad_pal = {b[4] for b in statues} - {str(PALETTE)}
    if bad_pal:
        problems.append(f"statue blocks on unexpected palette(s) {sorted(bad_pal)}, "
                        f"expected {PALETTE}")

    # 5. mirrored pairs, statues only: each depth is an even split of
    #    flipped/unflipped.
    for z in sorted({int(b[0], 16) >> 8 for b in statues}):
        at_z = [b for b in statues if int(b[0], 16) >> 8 == z]
        flipped = sum(1 for b in at_z if int(b[0], 16) & HFLIP)
        if flipped * 2 != len(at_z):
            problems.append(f"z {z:02X} is not a mirrored statue pair: {flipped} "
                            f"flipped of {len(at_z)} block(s)")

    # 6. Every module's placement tracks the design-centre formula.  Reported
    #    info is whichever module comes first, for the summary line.
    info = None
    for module in CENTRED_MODULES:
        origin = _module_origin(module, mods, blocks, sizes)
        offset = _bgnd_offset(module)
        if not (origin and offset):
            continue
        inb = [b for b in blocks if assign_module(b, mods, sizes) == module]
        shrunk_w = max(_rect(b, sizes)[2] for b in inb) - origin[0] + 1
        want_x = DESIGN_CENTRE - shrunk_w // 2
        if abs(offset[0] - want_x) > 1:
            problems.append(f"src/BGND.ASM places {module} at x {offset[0]}, "
                            f"but the {shrunk_w}px module centres on {DESIGN_CENTRE} "
                            f"at x {want_x} - it is {offset[0] - want_x:+d}px "
                            f"off the arch")
        if info is None:
            info = (module, len(inb), shrunk_w, offset)

    return problems, info


def width_alignment():
    """Guard sprites whose width is not a multiple of 4.

    LOAD2 walks the source assuming rows are padded to a 4-byte boundary
    (zcom_analysis: `zero_pad = (4 - xsize) & 3`) while the BDD stores them
    tight, so the compressed row headers and the pixel payload drift a byte
    apart per row and the art shears progressively down the sprite. All 1081
    background images in the 41 shipped stages are 4-aligned, without
    exception - and merely even is not enough, 42 still shears.
    """
    problems = []
    _ids, blocks, _pals = _bdd_blocks(BDD)
    bad = []
    for iid in sorted(_live_only_ids()):
        w, h, _px = blocks[iid]
        if w % 4:
            bad.append("%X (%dx%d)" % (iid, w, h))
    if bad:
        problems.append("%d guard sprite(s) have a width not divisible by 4 and will "
                        "shear in game: %s%s     fix with tools/twrside_even_width.py"
                        % (len(bad), bad, NL))
    return problems


# LOAD2 stores each sprite row as leading/trailing transparent runs, encoded as
# nibble(0..15) * ONE multiplier shared by the whole image. A run set that fits
# no single multiplier gets rounded, the visible span walks sideways row over
# row, and a triangular wedge of art goes missing in game while the editor - and
# every render in this repo - shows the sprite perfectly. It cost a build to
# find on the guards' heads, so it is checked here.
WEDGE_MULTS = (1, 2, 4, 8)
WEDGE_MAXN = 15


def _wedge_encodable(runs):
    if not runs:
        return True
    return any(all(v % m == 0 and v // m <= WEDGE_MAXN for v in runs)
               for m in WEDGE_MULTS)


def packing_report():
    """Guard images LOAD2 cannot zero-encode exactly. Informational only: the
    encoder floors each run and pads with literal transparent pixels
    (doc/load2/zcom.c), so this costs ROM bytes, never art. 39% of the shipped
    sprites are in this state."""
    problems = []
    _ids, blocks, _pals = _bdd_blocks(BDD)
    guard_ids = set(_live_only_ids())
    bad = []
    for iid in sorted(guard_ids):
        w, h, px = blocks[iid]
        lead, trail = [], []
        for y in range(h):
            row = px[y * w:(y + 1) * w]
            vis = [x for x in range(w) if row[x] != 0]
            if not vis:
                continue
            lead.append(vis[0])
            trail.append(w - 1 - vis[-1])
        if not (_wedge_encodable(lead) and _wedge_encodable(trail)):
            bad.append("%X (%dx%d)" % (iid, w, h))
    if bad:
        problems.append("%d guard sprite(s) LOAD2 cannot row-encode, so they will "
                        "lose a triangle wedge in game: %s%s     fix with "
                        "tools/twrside_wedge_recut.py" % (len(bad), bad, NL))
    return problems


def stock_parity():
    """Report every way TWRSIDE's stock half has drifted from TOWER2.

    Compared by what RENDERS, not by raw bytes. BDDTool's palette compactor
    renumbers indices and rewrites pixels losslessly, and it zeroes palette slot
    0 - which LOAD2 forces transparent on every block anyway, so it never draws.
    A byte comparison calls all of that drift; only a colour comparison can tell
    a repack apart from someone nudging the retail wall.

    PLANE4's own RECTANGLE is allowed to differ from stock now - it has grown
    to also claim STATUE4 - so this compares the actual retail BLOCK RECORDS
    (position, size, colour), not module boxes. The rect growing without a
    pixel of pillar art moving is the whole point of the split; the offset
    invariant that keeps it that way lives in layout_invariants().
    """
    problems = []
    guard_hdrs = {f"{i:X}" for i in _live_only_ids()}

    stock_lines = STOCK_BDB.read_text().replace(CRLF, NL).strip().split(NL)
    live_lines = BDB.read_text().replace(CRLF, NL).strip().split(NL)
    s_mods = int(stock_lines[0].split()[4])
    l_mods = int(live_lines[0].split()[4])
    s_blocks = stock_lines[1 + s_mods:]
    l_blocks = [b for b in live_lines[1 + l_mods:]
                if b.split()[3].upper() not in guard_hdrs]

    # Compare as a SET, not as an ordered list, and not the module boxes
    # themselves (PLANE4's is expected to grow). LOAD2 only cares about the
    # relative order of blocks WITHIN one module, and the editor legitimately
    # rewrites the file order every time it saves. Per-module ascending x is
    # checked separately in layout_invariants().
    expected = sorted(ALLOWED_STOCK_EDITS.get(b, b) for b in s_blocks)
    if expected != sorted(l_blocks):
        got = sorted(l_blocks)
        extra = [b for b in got if b not in expected]
        gone = [b for b in expected if b not in got]
        problems.append(f"stock block records changed: {len(gone)} missing, "
                        f"{len(extra)} unexpected{NL}"
                        f"    missing:    {gone[:6]}{NL}    unexpected: {extra[:6]}")

    s_ids, s_bl, s_pals = _bdd_blocks(STOCK_BDD)
    l_ids, l_bl, l_pals = _bdd_blocks(BDD)

    # Stock images keep their ids and their place at the head of the table;
    # guard art is appended after them.
    if l_ids[:len(s_ids)] != s_ids:
        problems.append(f"BDD block ids reordered: TOWER2 {s_ids} vs TWRSIDE {l_ids}")
        return problems
    if [n for n, _c in l_pals[:len(s_pals)]] != [n for n, _c in s_pals]:
        problems.append("BDD stock palettes reordered or renamed "
                        f"(TOWER2 {[p[0] for p in s_pals]} vs "
                        f"TWRSIDE {[p[0] for p in l_pals]})")
        return problems

    # Every stock block still has to paint the same colours. Index 0 is the
    # transparency slot LOAD2 forces on, so it is skipped on both sides.
    def colour(pals, pal_idx, index):
        if index == 0:
            return None
        table = pals[pal_idx][1]
        return table[index] if index < len(table) else ("OOR", index)

    live_by_key = {(b.split()[1], b.split()[2], b.split()[3].upper()): b.split()
                   for b in l_blocks}
    repainted, resized = [], []
    for rec in expected:
        f = rec.split()
        key = (f[1], f[2], f[3].upper())
        tgt = live_by_key.get(key)
        if tgt is None:
            continue
        img = int(f[3], 16)
        sw, sh, spx = s_bl[img]
        lw, lh, lpx = l_bl[img]
        if (sw, sh) != (lw, lh):
            resized.append(f"{img:X}")
            continue
        s_pal, l_pal = int(f[4]), int(tgt[4])
        bad = sum(1 for k in range(sw * sh)
                  if colour(s_pals, s_pal, spx[k]) != colour(l_pals, l_pal, lpx[k]))
        if bad:
            repainted.append(f"{img:X} ({bad}px)")
    if resized:
        problems.append(f"stock art resized: blocks {sorted(set(resized))}")
    if repainted:
        problems.append(f"stock art repainted: blocks {sorted(set(repainted))}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the layout breaks a rule (default anyway)")
    ap.add_argument("--apply", action="store_true",
                    help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.apply:
        print("--apply is gone: the guard layout is authored in BDDTool and this "
              "script only checks it. Re-cut the art there, then re-run this.",
              file=sys.stderr)
        return 2

    problems, info = layout_invariants()
    problems += width_alignment()
    if info:
        name, nblocks, shrunk_w, offset = info
        print(f"{name} box  ({nblocks} blocks, shrinks to {shrunk_w}px wide)")
        if offset:
            print(f"  BGND.ASM baklst3 entry:  .long {name}BMOD / "
                  f".word {offset[0]},{offset[1]}")
            print(f"  module centres on world x {offset[0] + shrunk_w / 2:.1f} "
                  f"(stage design centre is {DESIGN_CENTRE})")

    if problems:
        print(NL + "LAYOUT RULE BROKEN:")
        for line in problems:
            print("  " + line)
    else:
        print("  layout invariants hold: module claiming, ascending x, depth ramp, "
              "mirrored pairs, palette, BGND.ASM placement, 4-pixel widths")

    drift = stock_parity()
    if drift:
        print(NL + "STOCK DRIFT - TWRSIDE no longer carries TOWER2 unchanged:")
        for line in drift:
            print("  " + line)
    else:
        print(f"stock half matches data/TOWER2.BDB/.BDD "
              f"({len(ALLOWED_STOCK_EDITS)} allowed edits)")

    return 1 if (problems or drift) else 0


if __name__ == "__main__":
    sys.exit(main())
