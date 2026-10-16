#!/usr/bin/env python3
"""THE CAVE - MK3's unshipped cave stage (data/MK3CAVE.BDB/.BDD), made playable.

SOURCE.  MK3CAVE.BDB/.BDD come from the UMK3 art tree
(deadlythirdcombat-main).  Nothing in MK3, UMK3 or Trilogy ever loads them -
no LOD names them, no code references a module - so there is no Midway layout
to port: the planes, scroll rates and vertical placement below are ours.  The
floor is UMK3's FL_CAVE.BIN (Kahn's Kave, 1200x42 raw 6bpp) on MK3's own
CAVEFL_P palette (mk3-rebuild REV21 MKBT.ASM), copied verbatim.

The BDD holds four modules, all kept as authored:

    mk3cave4  718x100   the far chamber - columns, stalactites, a waterline
    mk3cave3  959x222   the cavern: a wall + skull pile (palettes 1/2) and a
                        rock outcrop with steps (3/4), authored 94px apart
    mk3cave2  461x186   three stone columns standing on rocks
    mk3cave1 1201x46    stalagmite silhouettes on flrtop_p - the floor's edge

WHY IT IS SPLIT INTO PACKS.  The art packs to ~201KB and no free video-ROM
run is bigger than 86KB, so one BBB> sidecar cannot hold it.  But a module's
header table is just [w,h,SAG,ctrl] per image with ABSOLUTE SAGs, so the
blocks of one module do not have to live in one LOAD2 run.  This tool:

  --parts   deals the 60 images first-fit-decreasing into PACKS (one fixed
            bank-1 slot each) and writes data/MK3CVn.BDB/.BDD - one dummy
            module per pack, every image laid out once, all seven palettes in
            the original order.  LOAD2 packs each into its slot
            (data/MK3CVn.LOD); IMGBUILD.BAT snapshots each BGNDTBL.ASM as
            tmp/load2/BGNDTBL.CVn.
  --apply   reads those snapshots back, maps every header to its original
            image, and writes src/MK3CAVBG.ASM: ONE merged CAVHDRS in the
            original BDD order, CAVPALS + the seven palettes, the four
            modules' BLKS/BMOD, the floor SAG and palette, and the layout
            equates src/MK3CAVE.ASM builds the stage from.
  --check   both of the above, compared instead of written (Phase D).  Also
            fails if a snapshot's sizes disagree with the BDD (a stale or
            mis-mapped header draws garbage), if a SAG falls outside its
            pack's slot, or if a pack overruns its slot.
  --dump    writes VIEWABLE PNGs of the raw art to tmp/mk3cave/dump/:
            FL_CAVE.png (the floor, flat, on CAVEFL_P, plus a 3x copy),
            mk3caveN.png (each module whole, as authored) and MK3CVn.png
            (each pack's images, each on the palette the stage draws it
            with).  The pack files themselves look like junk in BDDTool on
            purpose - every block is on palette 0 in one throwaway row -
            and FL_CAVE.BIN is raw 6bpp with no header or palette at all.
  --preview renders the 400x254 screen at the left/mid/right camera from
            the SAME constants, so a layout change can be looked at before a
            LOAD2 build: tmp/mk3cave/preview.png

LAYOUT is authored here, in world coordinates, not in BDDTool: the module
origins, the rates and the floor line all feed both the preview and the
generated equates, so the two cannot disagree.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "MK3CAVBG.ASM"

SCREEN_W, SCREEN_H = 400, 254
FLOOR_W = 1200                      # MKDISP floor_x

# --------------------------------------------------------------------------
# Packs: fixed bank-1 slots, physical video-ROM addresses (end exclusive).
# Mirrored in makevrom.py CUSTOM_VIDEO_SLOTS and the data/*.LOD ***> lines.
# LOD address = 0x2000000 + (phys - 0x800000) * 8 for bank 1.
# --------------------------------------------------------------------------
PACKS = [
    # name     start      end
    ("MK3CV1", 0xBA10F0, 0xBB60F0),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK3CV2", 0xB82000, 0xB96000),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK3CV3", 0xBC4820, 0xBCAE20),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK3CV4", 0xBD5ED0, 0xBDA4D0),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
]
FLOOR_PACK = ("CAVEFLR", 0x9EE000, 0x9F7C00)   # MK6MIL tail .. MKSOUL1 base
PACK_MARGIN = 0.96      # fill each slot to 96% of its estimated capacity

# --------------------------------------------------------------------------
# Runtime layout.  x/y are the module's top-left in its plane's world
# coordinates.  Rates are the scroll table's (020000h = the fighters' plane).
# --------------------------------------------------------------------------
GROUND_Y = 225                                # fighters' feet line (world)
WORLD_Y = GROUND_Y - 0xE0 - 8                 # initial worldtly / ceiling_y
# 5-bit RGB behind everything.  PURE BLACK, because it is what fills the gap
# between the cavern's wall and outcrop below the far chamber, and the art
# either side of that gap is black: 792 of the 1,272 pixels within 6px of it
# are exactly (0,0,0).  At (1,1,1) the fill showed as a lighter rectangle.
AUTOERASE = (0, 0, 0)

# ==========================================================================
# THE LAYOUT IS MEASURED OFF MIDWAY'S OWN BUILD.  No ROM or source carries the
# cavern's stage table (doc/MK3_CAVE_STAGE.md), but "Extremely Early Mortal
# Kombat 3 Footage With Cavern Stage" (YouTube Jw84UTSXzdU) opens on 16s of
# the empty stage scrolling, shot off a CRT.  tools/cavern_video/*.py template-
# matched this art against its frames (columns 0.74, cavern 0.76, outcrop 0.73,
# far chamber 0.74 normalised correlation; 2.3 x 2.45 video px per game px):
#
#   speeds, columns = 1:  cavern 0.69   far chamber 0.33   strip 1.23
#                         floor rows ~9/16/24: 1.27 / 1.33 / 1.40
#     = Midway's round rates  far 08000h  cavern 10000h  columns 18000h, the
#       floor's far edge 1C000h (MK3's Graveyard floor follows its 1C000h
#       plane the same way) and the strip at about floor row 5's speed.
#   heights against the floor's lit edge: far chamber top at screen row 0,
#     cavern top at -7, column module top at 22.
#   camera: the pan stops 405px left of the round-start camera and the fight
#     reaches 400px right of it - limits 0..800, start 400: the fighters'
#     world is 1200 wide, THE LENGTH OF THE FLOOR.
#   x at the round start (timer = screen centre): START_X below.
# Accuracy is about +-2 rows and +-8 columns (the tube is curved and the
# camera is off-axis), which is why the rates are snapped to round values.
# ==========================================================================
# The floor is drawn one row down and one row short: at the camera limits the
# rows under the feet line slide more than the 400 spare columns either side
# and run on into the NEXT row's pixels (the texture is one linear strip), and
# the last row would run off the end of the art.  Row 41 is never drawn, so
# every row that runs on has a real row to run into.
FLOOR = dict(skew_y=213, rows=41, rate_plane=2)   # screen row of floor row 0

# THE SHADOW ROW.  The floor's rows shear: row k slides (1 + (k-K)/128) times
# as far as plane 2 (mk3cave_skew_calla adds K * scroll/128 to skew_oc so that
# row K, not row 0, tracks plane 2).  The stalagmites ride plane 2, so K is
# the row whose shadows stay exactly under their spikes at every camera.  The
# footage puts the strip at floor row 4-6's speed; 6 is the highest of those,
# nearest the shadow heads (rows 8-11, shadow_row()).  K must be the sum of
# two distinct powers of two >= 2 - the ASM multiplies by a shift-and-add.
SHADOW_ROW = 6
FLOOR_EDGE_RATE = 0x1C000     # floor row 0; plane 2 runs at row K's speed
RATES = {1: 0x20000, 2: round(FLOOR_EDGE_RATE * 128 / (128 - SHADOW_ROW)),
         3: 0x10000, 4: 0x08000, 5: 0x18000}

CAMERA = dict(left=0, right=FLOOR_W - SCREEN_W, start=(FLOOR_W - SCREEN_W) // 2)
# The scroller can carry the camera a couple of pixels PAST a limit (measured
# in MAME: 808 against a right limit of 806); --check allows for it.
CAM_MARGIN = 4

# module -> (plane, world x, world y).  x = start + START_X (None = derived).
START_X = {"mk3cave4": -156, "mk3cave3": -277, "mk3cave2": -27}
PLACE = {
    "mk3cave4": (4, None, -7),
    "mk3cave3": (3, None, -14),
    "mk3cave2": (5, None, 15),
    # THE STALAGMITES AND THE FLOOR ARE ONE DRAWING: both 1200 wide, and the
    # shadows painted on the floor correlate best with the spikes at column
    # offset 0 (--align).  At the start camera every floor row shows column c
    # at c - FLOOR_W/3 and the strip's column c sits at x + c - start, so
    # x = start - FLOOR_W/3 puts every spike over its own shadow; SHADOW_ROW
    # keeps it there as the camera moves.  y: SPIKE_BASE below.
    "mk3cave1": (2, CAMERA["start"] - FLOOR_W // 3, None),
}
# The strip's bottom row lands on this floor row (0 = the floor's far edge).
SPIKE_BASE = 3
# Per-module block moves applied before the module box is recomputed:
# (predicate on the ORIGINAL canvas x, dx, dy).  None: the cavern's outcrop
# keeps the 94px gap Midway drew between it and the wall - the far chamber
# shows through it.
MOVES = {}

PAL_LABELS = ["MK3C_WAYBACK", "MK3C_CAVEWAL", "MK3C_SKULL", "MK3C_MIDROCK",
              "MK3C_WATER", "MK3C_COLUMN", "MK3C_FLRTOP"]

# --------------------------------------------------------------------------
# The water ripple - mk3cave_water (src/MK3CAVE.ASM).
#
# The cavern's water band is redrawn ONE ROW PER BLIT over the plain blocks,
# each line at its own x (dx) and reading a neighbouring row (dv), straight
# out of the blocks' own video-ROM data: no texture, no new art.  Every block
# on a water palette that crosses rows TOP..BOTTOM is a "span"; a span row is
# [bits from the header SAG to that row, left skip].  The offsets are WALKED
# out of the packs' IRWs, row header by row header, and the walk has to
# reproduce the BDD's pixels, so a compressed block can start at any row.
#
# The plain blocks stay underneath, so a line that is not redrawn - still
# water, a full queue, a palette not loaded - shows exactly what the stage
# showed before.  The ripple can only ever ADD.
#
# The skull pile sits on the same palette as the water on its left.  A row's
# left skip starts its blit right of the pile - the rightmost bone pixel of
# that row and of the DV_MAX rows either side (the row a line reads may be a
# neighbour), plus DX_MAX + 1 - so no bone ever moves.
# --------------------------------------------------------------------------
WATER = dict(
    module="mk3cave3",
    pals=(2, 4),            # skull_p (the water under the pile), water_p
    top=154, bottom=199,    # module rows redrawn; below 199 it is black
    dx_max=2, dv_max=1,
    bone_pal=2, bone_lum=24, bone_x=150,   # the pile: bright skull_p, left of x 150
    phases=64,              # wave table period, in steps
    tick_shift=1,           # one step every 2 ticks: a 128-tick (2.3s) loop
    reserve=250,            # queue cells left for everything after the water
    # the look - perspective water, far bank at the top of the band
    horizon=60,             # lines from the band's top row up to the horizon
    swell=(1.0, 13.0, 1),   # (weight, wavelength in lines at the near edge, cycles/loop)
    chop=(0.35, 5.0, -3),   #   a faster, finer ripple crossing it
    amp=(0.55, 1.85),       # dx amplitude, px: far edge, near edge
    vamp=(0.15, 0.75),      # dv amplitude, rows: far edge, near edge
)

# CAVEFL_P, mk3-rebuild REV21 MKBT.ASM - FL_CAVE.BIN's palette.
CAVEFL_P = [
    0x7C00, 0x0842, 0x0C42, 0x0C62, 0x0C63, 0x1063, 0x1083, 0x1084,
    0x1483, 0x1484, 0x14A4, 0x14A5, 0x1883, 0x18A4, 0x18A5, 0x18C5,
    0x18C6, 0x1CC5, 0x1CC6, 0x1CE6, 0x20C6, 0x20E6, 0x20E7, 0x2107,
    0x24E6, 0x24E7, 0x2507, 0x2508, 0x2907, 0x2908, 0x2928, 0x2929,
    0x2D28, 0x2D29, 0x2D48, 0x2D49, 0x2D4A, 0x3149, 0x3169, 0x316A,
    0x356A, 0x356B, 0x358B, 0x398B, 0x39AC, 0x3DAC, 0x3DCC,
]


# ------------------------------------------------------------------ BDD/BDB

def load_bdd(path: Path):
    d = path.read_bytes()
    pos = d.index(b"\n") + 1
    n = int(d[:pos].split()[0])
    imgs, order = {}, []
    for _ in range(n):
        j = d.index(b"\n", pos)
        p = d[pos:j].split()
        idx, w, h, big = int(p[0], 16), int(p[1]), int(p[2]), int(p[3])
        pos = j + 1
        imgs[idx] = dict(idx=idx, w=w, h=h, big=big, px=d[pos:pos + w * h])
        order.append(idx)
        pos += w * h
    pals = []
    while pos < len(d):
        j = d.index(b"\n", pos)
        nm, cnt = d[pos:j].split()
        cnt = int(cnt)
        pos = j + 1
        pals.append((nm.decode(), list(struct.unpack_from("<%dH" % cnt, d, pos))))
        pos += 2 * cnt
    return imgs, order, pals


def load_bdb(path: Path):
    lines = [l.split() for l in path.read_text().splitlines() if l.strip()]
    nmods, nblocks = int(lines[0][4]), int(lines[0][6])
    mods = [dict(name=t[0], x1=int(t[1]), x2=int(t[2]), y1=int(t[3]), y2=int(t[4]))
            for t in lines[1:1 + nmods]]
    blks = [dict(z=int(t[0], 16), x=int(t[1]), y=int(t[2]), hdr=int(t[3], 16), pal=int(t[4]))
            for t in lines[1 + nmods:1 + nmods + nblocks]]
    return mods, blks


def assign_modules(mods, blks, imgs):
    """ldbgnd2.c: crop each module to the blocks inside it, then give each
    block to the FIRST module whose box contains it, in BDB order."""
    for b in blks:
        b["x2"] = b["x"] + imgs[b["hdr"]]["w"] - 1
        b["y2"] = b["y"] + imgs[b["hdr"]]["h"] - 1
        b["put"] = False

    def inside(b, m):
        return b["x"] >= m["x1"] and b["y"] >= m["y1"] and b["x2"] <= m["x2"] and b["y2"] <= m["y2"]

    for m in mods:
        got = [b for b in blks if inside(b, m)]
        if got:
            m["x1"] = min(b["x"] for b in got)
            m["y1"] = min(b["y"] for b in got)
            m["x2"] = max(b["x2"] for b in got)
            m["y2"] = max(b["y2"] for b in got)
    for m in mods:
        m["blocks"] = []
        for b in blks:
            if not b["put"] and inside(b, m):
                b["put"] = True
                m["blocks"].append(dict(b))
    stray = [b for b in blks if not b["put"]]
    if stray:
        raise SystemExit(f"MK3CAVE.BDB: {len(stray)} blocks outside every module")
    return mods


def runtime_modules():
    """The four modules as the game gets them: MOVES applied, box re-cropped,
    blocks relative to the new origin and sorted by x (bsrch1stxb needs it)."""
    imgs, order, pals = load_bdd(DATA / "MK3CAVE.BDD")
    mods, blks = load_bdb(DATA / "MK3CAVE.BDB")
    mods = assign_modules(mods, blks, imgs)
    out = []
    for m in mods:
        bl = []
        for b in m["blocks"]:
            dx = dy = 0
            for pred, mx, my in MOVES.get(m["name"], []):
                if pred(b["x"]):
                    dx, dy = mx, my
            w, h = imgs[b["hdr"]]["w"], imgs[b["hdr"]]["h"]
            bl.append(dict(b, x=b["x"] + dx, y=b["y"] + dy, w=w, h=h))
        x1 = min(b["x"] for b in bl)
        y1 = min(b["y"] for b in bl)
        x2 = max(b["x"] + b["w"] - 1 for b in bl)
        y2 = max(b["y"] + b["h"] - 1 for b in bl)
        for b in bl:
            b["rx"], b["ry"] = b["x"] - x1, b["y"] - y1
        bl.sort(key=lambda b: (b["rx"], b["ry"]))
        out.append(dict(name=m["name"], w=x2 - x1 + 1, h=y2 - y1 + 1, blocks=bl))
    for name, rel in START_X.items():
        plane, _x, y = PLACE[name]
        PLACE[name] = (plane, CAMERA["start"] + rel, y)
    spikes = next(m for m in out if m["name"] == "mk3cave1")
    plane, x, _ = PLACE["mk3cave1"]
    PLACE["mk3cave1"] = (plane, x, FLOOR["skew_y"] + SPIKE_BASE + WORLD_Y - (spikes["h"] - 1))
    return imgs, order, pals, out


def shadow_row():
    """The floor row whose painted shadows are strongest: per row, how much
    darker its darkest tenth of columns is than the row's median."""
    raw = (DATA / "FL_CAVE.BIN").read_bytes()
    bits = int.from_bytes(raw, "little")

    def lum(c):
        return ((c >> 10) & 31) + ((c >> 5) & 31) + (c & 31)
    best, row = -1, 0
    for k in range(FLOOR_H):
        r = sorted(lum(CAVEFL_P[(bits >> (6 * (k * FLOOR_W + c))) & 63]) for c in range(FLOOR_W))
        med = r[FLOOR_W // 2]
        dark = sum(med - v for v in r[:FLOOR_W // 10])
        if dark > best:
            best, row = dark, k
    return row


def spike_shadow_offset(imgs, mods):
    """Column offset (strip - floor) at which the floor's painted shadows best
    line up with the spikes standing on it: Pearson correlation of each
    floor column's shadow darkness (rows 6-31) against each strip column's
    spike height.  0 means the two were drawn as one picture."""
    import statistics
    raw = (DATA / "FL_CAVE.BIN").read_bytes()
    bits = int.from_bytes(raw, "little")

    def lum(c):
        return ((c >> 10) & 31) + ((c >> 5) & 31) + (c & 31)
    fl = [[lum(CAVEFL_P[(bits >> (6 * (r * FLOOR_W + c))) & 63]) for c in range(FLOOR_W)]
          for r in range(FLOOR_H)]
    band = sorted(v for r in fl[8:30] for v in r)
    mid = band[len(band) // 2]
    shad = [sum(max(0, mid - fl[r][c]) for r in range(6, 32)) for c in range(FLOOR_W)]
    m = next(mm for mm in mods if mm["name"] == "mk3cave1")
    top = [m["h"]] * m["w"]
    for b in m["blocks"]:
        im = imgs[b["hdr"]]
        for y in range(im["h"]):
            for x in range(im["w"]):
                if im["px"][y * im["w"] + x]:
                    top[b["rx"] + x] = min(top[b["rx"] + x], b["ry"] + y)
    height = [m["h"] - t for t in top]

    def corr(a, b):
        ma, mb = statistics.mean(a), statistics.mean(b)
        num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
        return num / ((sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b)) ** .5)
    best = max(range(-100, 101), key=lambda off: corr(
        [shad[c] for c in range(FLOOR_W) if 0 <= c + off < m["w"]],
        [height[c + off] for c in range(FLOOR_W) if 0 <= c + off < m["w"]]))
    return best


# ------------------------------------------------------------------ packing

def _bpp(mx):
    for t, b in ((128, 8), (64, 7), (32, 6), (16, 5), (8, 4), (4, 3), (2, 2)):
        if mx >= t:
            return b
    return 1


def packed_bits(im):
    """LOAD2's size for one background block: auto bpp (PPP> 0) plus lead /
    trail zero compression (zcom.c).  Measured against MK1CAVE's real HDRS
    it is within 0.7%."""
    w, h, px = im["w"], im["h"], im["px"]
    b = _bpp(max(px))
    flat = w * h * b
    if w <= 10:
        return flat
    rows = []
    for y in range(h):
        r = px[y * w:(y + 1) * w]
        zl = 0
        while zl < w and zl < 120 and r[zl] == 0:
            zl += 1
        zt = 0
        if zl < w:
            for x in range(w):
                if x > w - 120:
                    zt = zt + 1 if r[x] == 0 else 0
        rows.append((zl, zt))

    def left(k, i):
        f = 1 << k
        return sum(r[i] - min(r[i] // f, 15) * f for r in rows)

    lm = min(range(4), key=lambda k: (left(k, 0), k))
    tm = min(range(4), key=lambda k: (left(k, 1), k))
    L, T = 1 << lm, 1 << tm
    tot = h * 8
    for zl, zt in rows:
        zlc = 15 if zl > L * 15 else zl // L
        ztc = 15 if zt > T * 15 else zt // T
        tot += (w - ztc * T - zlc * L) * b
    return min(tot, flat)


def deal_packs(imgs, order):
    """First-fit decreasing, deterministic.  Returns [ [idx...] per pack ]."""
    cap = [int((end - start) * 8 * PACK_MARGIN) for _, start, end in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(order, key=lambda i: (-packed_bits(imgs[i]), i)):
        bits = packed_bits(imgs[idx])
        for k in range(len(PACKS)):
            if used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    return [sorted(g, key=order.index) for g in got], used


def part_files(imgs, order, pals):
    """{filename: bytes} for every data/MK3CVn.BDB/.BDD."""
    groups, _ = deal_packs(imgs, order)
    files = {}
    for (name, _s, _e), group in zip(PACKS, groups):
        bdd = bytearray(b"%d\n" % len(group))
        for idx in group:
            im = imgs[idx]
            bdd += b"%x %d %d %d\n" % (idx, im["w"], im["h"], im["big"])
            bdd += im["px"]
        for nm, words in pals:
            bdd += b"%s %d\n" % (nm.encode(), len(words))
            bdd += struct.pack("<%dH" % len(words), *words)
        # one row of images left to right, 4px apart - only so LOAD2 has a
        # block per header inside one module; the layout is never drawn
        x, lines = 0, []
        for idx in group:
            lines.append("4000 %d 0 %X 0" % (x, idx))
            x += imgs[idx]["w"] + 4
        hmax = max(imgs[i]["h"] for i in group)
        bdb = [f"{name} {max(x, 1)} {hmax} 255 1 {len(pals)} {len(group)}",
               f"{name} 0 {max(x - 5, 0)} 0 {hmax - 1}"] + lines
        files[f"{name}.BDD"] = bytes(bdd)
        files[f"{name}.BDB"] = ("\n".join(bdb) + "\n").encode()
    return files


# ------------------------------------------------------------------ snapshots

def read_hdrs(snapshot: Path):
    """Every [w,h,addr,ctrl] from the one *HDRS table in a LOAD2 BGNDTBL."""
    text = snapshot.read_text(encoding="latin-1", errors="replace")
    m = re.search(r"^\w+HDRS:\s*$", text, re.M)
    if not m:
        raise SystemExit(f"{snapshot}: no HDRS table")
    vals = []
    for line in text[m.end():].splitlines():
        s = line.split(";")[0].strip()
        if not s:
            continue
        if not s.lower().startswith((".word", ".long")):
            break
        vals += [v.strip() for v in s.split(None, 1)[1].split(",")]
    def num(v):
        return int(v[:-1], 16) if v[-1] in "hH" else int(v)
    vals = [num(v) for v in vals]
    return [tuple(vals[i:i + 4]) for i in range(0, len(vals) - len(vals) % 4, 4)]


def read_floor_sag():
    tbl = LOAD2 / "CAVEFLR.TBL"
    if not tbl.exists():
        raise SystemExit(f"{tbl} missing - run python build.py")
    m = re.search(r"^FL_CAVE\s+\.set\s+0?([0-9A-Fa-f]+)[hH]", tbl.read_text(), re.M)
    if not m:
        raise SystemExit(f"{tbl}: no FL_CAVE")
    return int(m.group(1), 16)


def sag_phys(addr):
    """Runtime SAG -> physical video-ROM byte.  LOAD2 /E writes HDRS SAGs in
    runtime form: bank 0 = phys*8, bank 1 = 04000000h + (phys-800000h)*8
    (FLAPHDRS: 03DE0000H for phys 7BC000)."""
    if addr >= 0x4000000:
        return 0x800000 + (addr - 0x4000000) // 8
    return addr // 8


def set_phys(value):
    """A FRM> `.set` is in LOD form, 02000000h lower than runtime for bank 1
    (FL_ARENA 0323B4A0h sits in MK7MIL at phys A47694);
    setup_floor_info adds the 02000000h back."""
    return sag_phys(value + 0x2000000)


def merged_headers(imgs, order):
    groups, _ = deal_packs(imgs, order)
    by_idx = {}
    for (name, start, end), group in zip(PACKS, groups):
        snap = LOAD2 / f"BGNDTBL.{name[-3:]}"
        if not snap.exists():
            raise SystemExit(f"{snap} missing - run python build.py")
        hdrs = read_hdrs(snap)
        if len(hdrs) != len(group):
            raise SystemExit(f"{snap}: {len(hdrs)} headers, pack has {len(group)} images")
        hi = 0
        for idx, (w, h, addr, ctrl) in zip(group, hdrs):
            im = imgs[idx]
            if (w, h) != (im["w"], im["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}, BDD says {im['w']}x{im['h']}")
            p = sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: header {idx:X} SAG {addr:08X} (phys {p:X}) outside {start:X}..{end:X}")
            hi = max(hi, p + (packed_bits(im) + 7) // 8)
            by_idx[idx] = (w, h, addr, ctrl)
        if hi > end:
            raise SystemExit(f"{name}: payload runs to {hi:X}, slot ends {end:X}")
    return [by_idx[i] for i in order]


# ------------------------------------------------------------------ water

def _irw_payloads():
    """[(LOD base bit, payload bytes)] for the four packs, via makevrom's parser."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("makevrom", ROOT / "makevrom.py")
    mv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mv)
    out = []
    for name, _s, _e in PACKS:
        p = DATA / f"{name}.IRW"
        if not p.exists():
            raise SystemExit(f"{p} missing - run python build.py")
        base, _bank, payload = mv.parse_irw(p)
        out.append((base, payload))
    return out


def walk_rows(im, addr, ctrl, payloads):
    """Bit offset of every row from the header SAG, walked the way the DMA
    reads it: a compressed row is an 8-bit [trail:4 | lead:4] header, then the
    pixels between.  Returns (offsets, total bits, rows whose stored pixels
    differ from the BDD).  A wrong offset cannot survive the pixel compare."""
    lod = addr - 0x2000000                  # runtime SAG -> the IRW's LOD form
    for base, payload in payloads:
        if base <= lod < base + len(payload) * 8:
            break
    else:
        raise SystemExit(f"SAG {addr:08X} is in no MK3CV pack IRW")
    bits = int.from_bytes(payload, "little")
    bpp = (ctrl >> 12) & 7 or 8
    comp = bool(ctrl & 0x80)
    lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    w, h, px = im["w"], im["h"], im["px"]
    pos = lod - base
    offs, bad = [], []
    for y in range(h):
        offs.append(pos - (lod - base))
        lead = trail = 0
        if comp:
            hdr = (bits >> pos) & 0xFF
            pos += 8
            lead, trail = (hdr & 15) << lm, (hdr >> 4) << tm
            if lead + trail > w:
                raise SystemExit(f"SAG {addr:08X} row {y}: header {hdr:02X} does not decode")
        row = px[y * w:(y + 1) * w]
        got = [0] * w
        for x in range(lead, w - trail):
            got[x] = (bits >> pos) & ((1 << bpp) - 1)
            pos += bpp
        if got != [v & ((1 << bpp) - 1) for v in row]:
            bad.append(y)
    return offs, pos - (lod - base), bad


def water_spans(imgs, order, pals, mods, hdrs):
    """Every span of the ripple: its header, placement, palette and per-row
    [offset, skip] - exactly what mk3cave_water reads."""
    W = WATER
    mod = next(m for m in mods if m["name"] == W["module"])
    top, bot = W["top"], W["bottom"]
    # the skull pile's right edge, per module row
    bone = {}
    for b in mod["blocks"]:
        if b["pal"] != W["bone_pal"]:
            continue
        im, pal = imgs[b["hdr"]], pals[b["pal"]][1]
        for y in range(im["h"]):
            for x in range(im["w"]):
                v = im["px"][y * im["w"] + x]
                c = pal[v] if v else 0
                lum = ((c >> 10) & 31) + ((c >> 5) & 31) + (c & 31)
                mx = b["rx"] + x
                if v and lum >= W["bone_lum"] and mx < W["bone_x"]:
                    ry = b["ry"] + y
                    bone[ry] = max(bone.get(ry, -1), mx)
    payloads = _irw_payloads()
    by_idx = dict(zip(order, hdrs))
    spans = []
    for b in sorted(mod["blocks"], key=lambda b: (b["rx"], b["ry"])):
        if b["pal"] not in W["pals"] or b["z"] & 0x30:
            continue
        lo, hi = max(top, b["ry"]), min(bot, b["ry"] + b["h"] - 1)
        if lo > hi:
            continue
        im = imgs[b["hdr"]]
        hw, hh, addr, ctrl = by_idx[b["hdr"]]
        offs, total, bad = walk_rows(im, addr, ctrl, payloads)
        used = [r for r in range(lo - b["ry"], hi - b["ry"] + 1)]
        if any(r in bad for r in used):
            raise SystemExit(f"water block {b['hdr']:02X}: stored rows {[r for r in used if r in bad]} "
                             "differ from MK3CAVE.BDD - the IRW is not this art")
        rows = []
        for ry in range(lo, hi + 1):
            edge = max(bone.get(ry + k, -1) for k in range(-W["dv_max"], W["dv_max"] + 1))
            skip = 0 if edge < 0 else max(0, edge + W["dx_max"] + 2 - b["rx"])
            skip = min(skip, im["w"])           # == width: all pile, never redrawn
            rows.append((offs[ry - b["ry"]], skip))
        if total >= 0x10000:
            raise SystemExit(f"water block {b['hdr']:02X} is {total} bits - offsets need 16")
        spans.append(dict(hdr=b["hdr"], hidx=order.index(b["hdr"]), rx=b["rx"], ry=b["ry"],
                          pal=b["pal"], first=lo - top, rows=rows, w=im["w"], ctrl=ctrl))
    return spans


def water_wave():
    """[line][phase] -> (dx, dv).  Perspective water: the band's top row is the
    far bank, so waves bunch up and shrink toward it; a slow swell rolls
    toward the viewer and a finer chop crosses it the other way."""
    import math
    W = WATER
    n = W["bottom"] - W["top"] + 1
    P, h0 = W["phases"], W["horizon"]
    near = n - 1 + h0

    def dist(i):                    # ground distance of line i, in near-edge lines
        return near * near / (i + h0)

    tab = []
    for i in range(n):
        d = i / (n - 1)
        a = W["amp"][0] + (W["amp"][1] - W["amp"][0]) * d
        va = W["vamp"][0] + (W["vamp"][1] - W["vamp"][0]) * d
        row = []
        for p in range(P):
            t = p / P
            s = 0.0
            for wt, lam, cyc in (W["swell"], W["chop"]):
                s += wt * math.sin(2 * math.pi * (dist(i) / lam + cyc * t))
            s /= W["swell"][0] + W["chop"][0]
            dx = max(-W["dx_max"], min(W["dx_max"], round(a * s)))
            v = math.cos(2 * math.pi * (dist(i) / W["swell"][1] + W["swell"][2] * t))
            dv = max(-W["dv_max"], min(W["dv_max"], round(va * v)))
            row.append((dx, dv))
        tab.append(row)
    return tab


def water_asm(spans, wave):
    W = WATER
    n = W["bottom"] - W["top"] + 1
    L = []
    w = L.append
    w("")
    w("; ---- the water ripple, mk3cave_water (edit WATER in the tool) ----")
    w(f"mk3c_wat_y0\t.set\t{W['top']}\t\t; module row of line 0")
    w(f"mk3c_wat_lines\t.set\t{n}")
    w(f"mk3c_wat_nspan\t.set\t{len(spans)}")
    if W["phases"] & (W["phases"] - 1):
        raise SystemExit("WATER phases must be a power of two")
    w(f"mk3c_wat_phmask\t.set\t{W['phases'] - 1}\t\t; wave steps, less one")
    w(f"mk3c_wat_rowbits\t.set\t{W['phases'] * 8}\t\t; bits per line of MK3C_WATWAVE")
    w(f"mk3c_wat_tsh\t.set\t{W['tick_shift']}\t\t; ticks per phase, as a shift")
    w(f"mk3c_wat_dxmax\t.set\t{W['dx_max']}")
    w(f"mk3c_wat_resv\t.set\t{W['reserve']}\t\t; queue cells kept for later lists")
    w("")
    w("MK3C_WATSPANS:\t\t; hdr, rows, palette, block x, first line, rows, 0")
    for s in spans:
        w(f"\t.long\tCAVHDRS+{s['hidx'] * 80},MK3C_WATR{s['hdr']:02X},{PAL_LABELS[s['pal']]}")
        w(f"\t.word\t{s['rx']},{s['first']},{len(s['rows'])},0\t; {s['hdr']:02X} {s['w']} wide, ctrl {s['ctrl']:04X}")
    w("")
    for s in spans:
        w(f"MK3C_WATR{s['hdr']:02X}:\t\t; [bits from the sag, left skip] per row")
        for i in range(0, len(s["rows"]), 6):
            w("\t.word\t" + ",".join(f"{o},{asm_hex(k)}" for o, k in s["rows"][i:i + 6]))
    w("")
    w("MK3C_WATWAVE:\t\t; [line][phase] = dv << 5 | dx & 1Fh")
    for i, row in enumerate(wave):
        bs = [((dv << 5) | (dx & 0x1F)) & 0xFF for dx, dv in row]
        for j in range(0, len(bs), 16):
            w("\t.byte\t" + ",".join("%d" % b for b in bs[j:j + 16]) + ("\t; line %d" % i if j == 0 else ""))
    pad = (-(n * W["phases"])) % 4
    if pad:
        w("\t.byte\t" + ",".join("0" * pad))
    return L


# ------------------------------------------------------------------ ASM

def asm_hex(v, digits=4):
    return "0%0*XH" % (digits, v)


def build_asm(imgs, order, pals, mods, hdrs, floor_sag, water=None):
    L = []
    w = L.append
    w("; THE CAVE - GENERATED by tools/make_mk3cave.py --apply.  Do not hand-edit.")
    w("; Source art data/MK3CAVE.BDB/.BDD (MK3, never shipped); headers merged from")
    w("; the MK3CV1-4 LOAD2 snapshots, so one module's blocks span several packs.")
    w("")
    w("; ---- layout (edit LAYOUT in the tool, not here) ----")
    w(f"mk3c_left\t.set\t{CAMERA['left']}")
    w(f"mk3c_right\t.set\t{CAMERA['right']}")
    w(f"mk3c_start\t.set\t{CAMERA['start']}")
    w(f"mk3c_ground\t.set\t{GROUND_Y}")
    w(f"mk3c_worldy\t.set\t{WORLD_Y}")
    r, g, b = AUTOERASE
    w(f"mk3c_erase\t.set\t{r * 1024 + g * 32 + b}")
    w(f"mk3c_skew_y\t.set\t{FLOOR['skew_y']}")
    w(f"mk3c_skew_h\t.set\t{FLOOR['rows']}")
    kbits = [b for b in range(16) if SHADOW_ROW >> b & 1]
    if len(kbits) != 2 or kbits[0] < 1:
        raise SystemExit(f"SHADOW_ROW {SHADOW_ROW} is not 2^a + 2^b with a > b >= 1")
    w(f"mk3c_kanc\t.set\t{SHADOW_ROW}\t\t; floor row that tracks plane 2")
    w(f"mk3c_kanc_s1\t.set\t{kbits[1]}\t\t; mk3c_kanc = 1<<s1 + 1<<s2")
    w(f"mk3c_kanc_s2\t.set\t{kbits[0]}")
    for n in range(1, 9):
        w(f"mk3c_rate{n}\t.set\t{asm_hex(RATES.get(n, 0), 6)}")
    for m in mods:
        plane, x, y = PLACE[m["name"]]
        tag = m["name"][-1]
        w(f"mk3c_m{tag}_x\t.set\t{x}")
        w(f"mk3c_m{tag}_y\t.set\t{y}")
    w(f"FL_CAVE\t.set\t{asm_hex(floor_sag, 8)}")
    w("")
    w("\t.data")
    w("")
    w("CAVHDRS:")
    for idx, (hw, hh, addr, ctrl) in zip(order, hdrs):
        w(f"\t.word\t{hw},{hh}\t\t; {idx:02X}")
        w(f"\t.long\t{asm_hex(addr, 8)}")
        w(f"\t.word\t{asm_hex(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(order)}
    for m in mods:
        lab = m["name"].upper()
        w(f"{lab}BLKS:")
        for bl in m["blocks"]:
            flags = (bl["z"] & 0xFFF0) | (bl["pal"] & 0xF) | 0x40
            hw = hidx[bl["hdr"]] + ((bl["pal"] >> 4) << 12)
            w(f"\t.word\t{asm_hex(flags)},{bl['rx']},{bl['ry']},{asm_hex(hw)}")
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{m['w']},{m['h']},{len(m['blocks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, CAVHDRS, CAVPALS")
        w("")
    w("CAVPALS:")
    for lab in PAL_LABELS:
        w(f"\t.long\t{lab}")
    w("")
    for lab, (nm, words) in zip(PAL_LABELS, pals):
        w(f"{lab}:\t\t; BDD {nm}")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(asm_hex(v) for v in words[i:i + 8]))
    w("")
    w("MK3C_FLOOR_P:\t\t; CAVEFL_P, MK3 REV21 MKBT.ASM")
    w(f"\t.word\t{len(CAVEFL_P)}")
    for i in range(0, len(CAVEFL_P), 8):
        w("\t.word\t" + ",".join(asm_hex(v) for v in CAVEFL_P[i:i + 8]))
    if water is not None:
        L.extend(water_asm(*water))
    w("")
    w("\t.text")
    return "\n".join(L) + "\n"


FLOOR_H = (DATA / "FL_CAVE.BIN").stat().st_size * 8 // 6 // FLOOR_W if (DATA / "FL_CAVE.BIN").exists() else 42


# ------------------------------------------------------------------ preview

def rgb(c):
    return (((c >> 10) & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31, (c & 31) * 255 // 31)


def plane_x(plane, cam):
    s = CAMERA["start"]
    return s + (cam - s) * RATES[plane] // 0x20000


def render(cam, imgs, pals, mods, water=None, guides=True, wy=None):
    from PIL import Image, ImageDraw
    wy = WORLD_Y if wy is None else wy
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), rgb(AUTOERASE[0] * 1024 + AUTOERASE[1] * 32 + AUTOERASE[2]))
    tiles = {}

    def tile(idx, pal):
        key = (idx, pal)
        if key not in tiles:
            im = imgs[idx]
            p = pals[pal][1]
            t = Image.new("RGBA", (im["w"], im["h"]))
            t.putdata([(0, 0, 0, 0) if v == 0 else rgb(p[v]) + (255,) for v in im["px"]])
            tiles[key] = t
        return tiles[key]

    def draw_mod(name):
        m = next(mm for mm in mods if mm["name"] == name)
        plane, mx, my = PLACE[name]
        px = plane_x(plane, cam)
        for bl in m["blocks"]:
            t = tile(bl["hdr"], bl["pal"])
            if bl["z"] & 0x10:
                t = t.transpose(Image.FLIP_LEFT_RIGHT)
            scr.paste(t, (mx + bl["rx"] - px, my + bl["ry"] - wy), t)

    def draw_floor():
        raw = (DATA / "FL_CAVE.BIN").read_bytes()
        bits = int.from_bytes(raw, "little")
        # unrounded: the game carries skew_oc / skew_dx in 16.16
        s2 = (cam - CAMERA["start"]) * RATES[FLOOR["rate_plane"]] / 0x20000
        for k in range(FLOOR["rows"]):
            y = FLOOR["skew_y"] + k
            if y >= SCREEN_H:
                break
            start = FLOOR_W // 3 + round(s2 * (1 + (k - SHADOW_ROW) / 128))
            for x in range(SCREEN_W):
                col = start + x
                row = k
                while col < 0:
                    col += FLOOR_W
                    row -= 1
                while col >= FLOOR_W:
                    col -= FLOOR_W
                    row += 1
                v = (bits >> (6 * (row * FLOOR_W + col))) & 63 if 0 <= row < FLOOR_H else 0
                scr.putpixel((x, y), rgb(CAVEFL_P[v]))

    def draw_water():
        """mk3cave_water, line for line: the same spans, rows, skips and
        wave step the ROM reads."""
        spans, wave, phase, fixed = water
        _plane, mx, my = PLACE[WATER["module"]]
        x0 = mx - plane_x(_plane, cam)
        mod = next(mm for mm in mods if mm["name"] == WATER["module"])
        blk = {b["hdr"]: b for b in mod["blocks"]}
        for i in range(len(wave)):
            y = my + WATER["top"] + i - wy
            if not 0 <= y < SCREEN_H:
                continue
            dx, dv = wave[i][phase] if fixed is None else (fixed(i, y), 0)
            if fixed is None and dx == 0 and dv == 0:
                continue
            for s in spans:
                r = i - s["first"]
                if not 0 <= r < len(s["rows"]):
                    continue
                k = min(max(r + dv, 0), len(s["rows"]) - 1)
                skip = s["rows"][k][1]
                if skip >= im["w"]:
                    continue
                b = blk[s["hdr"]]
                im, p = imgs[b["hdr"]], pals[b["pal"]][1]
                src = WATER["top"] + s["first"] + k - b["ry"]
                row = im["px"][src * im["w"]:(src + 1) * im["w"]]
                for x in range(skip, im["w"]):
                    sx = x0 + s["rx"] + x + dx
                    if row[x] and 0 <= sx < SCREEN_W:
                        scr.putpixel((sx, y), rgb(p[row[x]]))

    for layer in DRAW_ORDER:
        draw_floor() if layer == "floor" else draw_mod(layer)
        if layer == WATER["module"] and water is not None:
            draw_water()
    if not guides:
        return scr
    d = ImageDraw.Draw(scr)
    feet = GROUND_Y - wy
    d.line([(0, feet), (SCREEN_W, feet)], fill=(255, 255, 0))
    d.rectangle([0, 0, SCREEN_W - 1, 39], outline=(255, 0, 255))   # HUD band
    return scr


DRAW_ORDER = ["mk3cave4", "mk3cave3", "mk3cave2", "floor", "mk3cave1"]


# ------------------------------------------------------------------ main

def dump_pngs(imgs, order, pals, mods):
    """--dump: every piece of cave art as something an image viewer can open."""
    from PIL import Image
    out = ROOT / "tmp" / "mk3cave" / "dump"
    out.mkdir(parents=True, exist_ok=True)
    bg = (40, 40, 48, 255)             # index 0 is transparent: show it as slate

    # the floor: 1200 x 42, 6 bits a pixel, little-endian bit order, no header
    raw = (DATA / "FL_CAVE.BIN").read_bytes()
    bits = int.from_bytes(raw, "little")
    fl = Image.new("RGB", (FLOOR_W, FLOOR_H))
    fl.putdata([rgb(CAVEFL_P[(bits >> (6 * i)) & 63]) for i in range(FLOOR_W * FLOOR_H)])
    fl.save(out / "FL_CAVE.png")
    fl.resize((FLOOR_W * 3, FLOOR_H * 3), Image.NEAREST).save(out / "FL_CAVE_3x.png")

    # the palette each image is actually drawn with - the first block using it
    img_pal = {}
    for m in mods:
        for b in m["blocks"]:
            img_pal.setdefault(b["hdr"], b["pal"])

    def tile(idx, pal):
        im = imgs[idx]
        p = pals[pal][1]
        t = Image.new("RGBA", (im["w"], im["h"]))
        t.putdata([(0, 0, 0, 0) if v == 0 else rgb(p[v]) + (255,) for v in im["px"]])
        return t

    # each module whole, as the stage lays it out
    for m in mods:
        sheet = Image.new("RGBA", (m["w"], m["h"]), bg)
        for b in m["blocks"]:
            t = tile(b["hdr"], b["pal"])
            if b["z"] & 0x10:
                t = t.transpose(Image.FLIP_LEFT_RIGHT)
            sheet.paste(t, (b["rx"], b["ry"]), t)
        sheet.save(out / f"{m['name']}.png")

    # each pack: its images in a row, 4px apart, on their REAL palettes
    groups, _ = deal_packs(imgs, order)
    for (name, _s, _e), group in zip(PACKS, groups):
        w = sum(imgs[i]["w"] + 4 for i in group)
        h = max(imgs[i]["h"] for i in group)
        sheet = Image.new("RGBA", (w, h), bg)
        x = 0
        for idx in group:
            t = tile(idx, img_pal.get(idx, 0))
            sheet.paste(t, (x, 0), t)
            x += imgs[idx]["w"] + 4
        sheet.save(out / f"{name}.png")
    print(f"wrote {out}: FL_CAVE.png (+3x), "
          + ", ".join(m["name"] + ".png" for m in mods) + ", "
          + ", ".join(n + ".png" for n, _s, _e in PACKS))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--parts", action="store_true", help="write data/MK3CVn.BDB/.BDD")
    ap.add_argument("--apply", action="store_true", help="write src/MK3CAVBG.ASM from LOAD2 snapshots")
    ap.add_argument("--check", action="store_true", help="fail if parts or ASM are stale")
    ap.add_argument("--preview", nargs="*", type=int, metavar="CAMX",
                    help="render screens (default left/mid/right) to tmp/mk3cave/preview.png")
    ap.add_argument("--report", action="store_true", help="print the pack deal")
    ap.add_argument("--align", action="store_true",
                    help="measure where the floor's shadows line up with the stalagmites")
    ap.add_argument("--dump", action="store_true",
                    help="write viewable PNGs of the floor, modules and packs to tmp/mk3cave/dump/")
    ap.add_argument("--water-gif", nargs="?", const=CAMERA["start"], type=int, metavar="CAMX",
                    help="animate the water ripple at one camera: tmp/mk3cave/water.gif")
    a = ap.parse_args()

    imgs, order, pals, mods = runtime_modules()
    if len(pals) != len(PAL_LABELS):
        raise SystemExit(f"MK3CAVE.BDD has {len(pals)} palettes, expected {len(PAL_LABELS)}")

    if a.dump:
        dump_pngs(imgs, order, pals, mods)

    if a.report or not any((a.parts, a.apply, a.check, a.dump, a.align,
                            a.preview is not None, a.water_gif is not None)):
        groups, used = deal_packs(imgs, order)
        for (name, s, e), g, u in zip(PACKS, groups, used):
            print(f"{name}  {s:06X}..{e:06X}  {len(g):2d} images  ~{u // 8:6d} of {e - s:6d} bytes")
        for m in mods:
            print(f"{m['name']}  {m['w']}x{m['h']}  {len(m['blocks'])} blocks  plane {PLACE[m['name']][0]}")

    rc = 0
    parts = part_files(imgs, order, pals)
    if a.parts:
        for fn, data in parts.items():
            p = DATA / fn
            if not p.exists() or p.read_bytes() != data:
                p.write_bytes(data)
                print(f"wrote data/{fn}")
    if a.align or a.check:
        off = spike_shadow_offset(imgs, mods)
        print(f"spikes vs floor shadows: best column offset {off}")
        print(f"strongest shadow row {shadow_row()} (SHADOW_ROW {SHADOW_ROW})")
        # No drawn floor row may read outside the art.  A row that slides past
        # the 400 spare columns runs into the row above / below it, so row 0
        # must never run left and the last DRAWN row needs a row under it.
        for cam in (CAMERA["left"] - CAM_MARGIN, CAMERA["right"] + CAM_MARGIN):
            s2 = (cam - CAMERA["start"]) * RATES[FLOOR["rate_plane"]] / 0x20000
            for k in range(FLOOR["rows"]):
                c0 = FLOOR_W // 3 + round(s2 * (1 + (k - SHADOW_ROW) / 128))
                first = k * FLOOR_W + c0
                last = first + SCREEN_W - 1
                if first < 0 or last >= FLOOR_W * FLOOR_H:
                    print(f"MK3CAVE: camera {cam} floor row {k} reads outside FL_CAVE")
                    rc = 1
                    break
        # ...and no camera may show an empty column above the floor
        cols = {}
        for mm in mods:
            if mm["name"] == "mk3cave1":
                continue
            plane, mx, my = PLACE[mm["name"]]
            got = set()
            for bl in mm["blocks"]:
                top, bot = my + bl["ry"] - WORLD_Y, my + bl["ry"] + bl["h"] - 1 - WORLD_Y
                if bot >= 40 and top < FLOOR["skew_y"]:
                    got.update(range(mx + bl["rx"], mx + bl["rx"] + bl["w"]))
            cols[plane] = got
        for cam in range(CAMERA["left"], CAMERA["right"] + 1, 2):
            px = {pl: plane_x(pl, cam) for pl in cols}
            if any(not any(sx + px[pl] in cols[pl] for pl in cols) for sx in range(SCREEN_W)):
                print(f"MK3CAVE: camera {cam} shows a column with no background")
                rc = 1
                break
    if a.check:
        stale = [fn for fn, data in parts.items()
                 if not (DATA / fn).exists() or (DATA / fn).read_bytes() != data]
        if stale:
            print("MK3CAVE parts stale (run tools/make_mk3cave.py --parts, then python build.py): " + ", ".join(stale))
            rc = 1

    if a.apply or a.check:
        hdrs = merged_headers(imgs, order)
        floor_sag = read_floor_sag()
        fp = set_phys(floor_sag)
        if not (FLOOR_PACK[1] <= fp and fp + FLOOR_W * FLOOR_H * 6 // 8 <= FLOOR_PACK[2]):
            raise SystemExit(f"FL_CAVE {floor_sag:08X} (phys {fp:X}) outside {FLOOR_PACK}")
        water = (water_spans(imgs, order, pals, mods, hdrs), water_wave())
        text = build_asm(imgs, order, pals, mods, hdrs, floor_sag, water)
        old = OUT_ASM.read_text(encoding="latin-1") if OUT_ASM.exists() else ""
        if a.apply and old != text:
            OUT_ASM.write_text(text, encoding="latin-1")
            for stale in ("MK3CAVE.OBJ", "mk2.out"):
                (SRC / stale).unlink(missing_ok=True)
            print("wrote src/MK3CAVBG.ASM")
        elif a.check:
            if old != text:
                print("src/MK3CAVBG.ASM is stale (run tools/make_mk3cave.py --apply)")
                rc = 1
            else:
                print("THE CAVE parts + tables are current")

    if a.water_gif is not None:
        from PIL import Image
        spans = water_spans(imgs, order, pals, mods, merged_headers(imgs, order))
        wave = water_wave()
        frames = [render(a.water_gif, imgs, pals, mods, (spans, wave, ph, None), guides=False)
                  for ph in range(WATER["phases"])]
        frames = [f.resize((SCREEN_W * 2, SCREEN_H * 2), Image.NEAREST) for f in frames]
        out = ROOT / "tmp" / "mk3cave" / "water.gif"
        out.parent.mkdir(parents=True, exist_ok=True)
        ms = round(1000 * (1 << WATER["tick_shift"]) / 54.7068)
        frames[0].save(out, save_all=True, append_images=frames[1:], duration=ms, loop=0)
        print(f"wrote {out.relative_to(ROOT)}  camera {a.water_gif}, {len(frames)} steps at {ms} ms")

    if a.preview is not None:
        from PIL import Image
        cams = a.preview or [CAMERA["left"], CAMERA["start"], CAMERA["right"]]
        shots = [render(c, imgs, pals, mods) for c in cams]
        sheet = Image.new("RGB", (SCREEN_W, (SCREEN_H + 4) * len(shots)), (0, 255, 0))
        for i, s in enumerate(shots):
            sheet.paste(s, (0, i * (SCREEN_H + 4)))
        out = ROOT / "tmp" / "mk3cave" / "preview.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(out)
        print(f"wrote {out.relative_to(ROOT)}  cameras {cams}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
