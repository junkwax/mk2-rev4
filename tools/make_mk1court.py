#!/usr/bin/env python3
r"""THE COURTYARD - MK1's opening stage, as a WOLF-ONLY MK2 stage (curback 01Dh).

Shang Tsung's courtyard: his throne under the pavilion roof, the bronze
dragons on the wall, two spear guards on the ledge and two rows of shaven
monks who watch every fight.  Code is src/MK1CRT.ASM; everything
it is built from is generated into src/MK1CRTB.ASM by this tool.  Like THE
THRONE ROOM (tools/make_mk1throne.py, whose readers this borrows), everything is
READ, from one source:

  C:\\MAME\\roms\\mk.zip    MK1 rev 5.0.  Stage table FFCA7E30, entry 0 =
                         FFCBB410 is THE COURTYARD.

THE LEAK'S KUNGFU2 IS NOT THIS STAGE.  Matched module by module only ARENA3 and
ARENA4 agree; three modules differ in size and the BDB has a block outside every
module (doc/MK1_COURTYARD_GATES.md).  It is a pre-release Courtyard, so the art
is decoded out of MK1's video ROM and --check proves every packed record back
against it.

THE MONKS ARE NOT BACKGROUND.  MK1's calla (FFCBB6F0) creates one process,
FFCBB780, which every 8 ticks walks the object lists of MK1's planes 3 and 4 -
the two monk rows, modules 3 and 4, 8 and 7 blocks of the same 108x43 image -
and points every object at the next of six 105x43 frames (table FFCBBB30).  In
MK1 a background block IS an object on its plane's list; in MK2 a BDB block
never animates.  So those two modules are SKIPPED in the MK2 module list
(skip_bakmod, 32 bits) and their 15 blocks become runtime objects on baklst3 /
baklst4 - the lists of the planes MK1 draws them on - at each block's own
top-left (MK1's frame swap does not move an object; measured in
tools/mk1_court_objs.lua, x stays on the block's x through every frame), with
the frames packed at anipoint 0 so the anchor IS that top-left.

SHANG TSUNG AND HIS THRONE ARE AN OBJECT TOO, so the throne can be EMPTY when
he is in the fight.  In MK1 they are one 48x55 block of module 6 (header 25h,
palette 7, at 201,71) - he is painted into the chair.  That block is taken out
of the module and packed as a sprite record beside the monks (MK1CYTHRN), with
a second record, MK1CYTHRNE, the same chair with nobody in it; mk1c_throne
(MK1CRT.ASM) builds one or the other at the block's world top-left on a list of
its own, drawn with plane 6's camera straight after plane 6.  MK1 HAS NO EMPTY
COURTYARD THRONE - Shang Tsung is fought in the Throne Room - so MK1CYTHRNE is
PAINTED here (empty_throne): posts and arms are MK1's own pixels, mirrored from
the half he does not cover, and the back, seat and front are filled in the
chair's own reds.  It is this project's art, not Midway's.

WOLF ONLY.  The art goes into the Wolf video ROM above the T-unit's 12 MB (LOD
`***> 4000000,1` and up, makevrom.py wolf_irw_files); the module and its tables
assemble under `.if wunit`, so a T-unit build is byte-identical without it.

  --parts   data/MK1CY1.BDB/.BDD + .LOD (the stage), data/MK1CRTMK.IMG and
            data/MK1CYM.LOD (the monk frames, a sprite pack)
  --apply   src/MK1CRTB.ASM from tmp/load2/BGNDTBL.CY1 and src/MK1CYM.TBL,
            every packed record decoded back out of its IRW first
  --check   compare instead of write (Phase D)
  --report  MK1's numbers and the pack sizes
  --preview tmp/mk1court/preview.png, monks included (camera x arguments)
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave      # noqa: E402  (LOAD2 size model, header snapshots)
import make_mk1pit as pit        # noqa: E402  (MK1 ROM reader, IRW decode, LOD helpers)
import make_mk1shrine as shrine  # noqa: E402  (MK1 plane/scroll proof)
import make_mk1throne as thr     # noqa: E402  (module-list reader, art decode)

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "MK1CRTB.ASM"
MONK_IMG = DATA / "MK1CRTMK.IMG"
SCREEN_W, SCREEN_H = 400, 254

# --------------------------------------------------------------------------
# Wolf video ROM, physical (linear) bytes, end exclusive.  makevrom.py places
# a Wolf pack from its LOD-form base: 0x800000 + (base - 0x2000000) / 8, so
# linear 0xC00000 is `***> 4000000,1`.  The region is ours alone - the 12 MB
# below it is the T-unit's and the top 256 KB of 16 MB is the Wolf VS
# portraits (makevrom.py WOLF_RESERVED).
# --------------------------------------------------------------------------
PACKS = [
    # name      start       end         ppp
    ("MK1CY1", 0xC00000, 0xC10000, 0),   # 64 KB - the stage blocks, auto depth
    ("MK1CY2", 0xC10000, 0xC14000, 8),   # 16 KB - blocks whose LAST pixel is deeper
]                                        #         than the rest (shrine's wide_tail)
MONK_PACK = ("MK1CYM", 0xC14000, 0xC1C000)   # 32 KB - the six monk frames
MONK_PPP = 6
THRONE_HDR = 0x25                # module 6's block: Shang Tsung on his throne
THRONE_AT = (6, 201, 71, 7)      # plane, block x, y, MK1 palette - checked
THRONE_PAL = "MK1CYTH_P"
THRONE_RECS = ("MK1CYTHRN", "MK1CYTHRNE")   # seated / empty
PACK_MARGIN = 0.90

# --------------------------------------------------------------------------
# MK1 anchors - each checked when read
# --------------------------------------------------------------------------
COURT_ENTRY = 0
COURT_MOD = 0xFFCBB410
COURT_CALLA = 0xFFCBB6F0
# MOVI 2000h,A1 / MOVI FFCBB780h,A7 / CALLA FFCE2810h / RETS - one process
CALLA_CODE = [0x09C1, 0x2000, 0x09E7, 0xB780, 0xFFCB, 0x0D5F, 0x2810, 0xFFCE, 0x0960]
NAME_STR = b"THE COURTYARD\0"
MONK_PROC = 0xFFCBB780
MONK_TAB = 0xFFCBBB30            # six .longs: the idle frames, in order
MONK_FRAMES = [0xFFE976C0 + 0x60 * k for k in range(6)]
BOW_TAB = 0xFFCBBBF0             # the hands-together frames - loaded, never shown
BOW_FRAMES = [0xFFE97900 + 0x60 * k for k in range(3)]
MONK_RATE = 8                    # MOVI 8,A0 / JA sleep - ticks a frame
MONK_PLANES = (3, 4)             # the two rows: modules 3 (8 blocks) and 4 (7)

GROUND_NUDGE = -6                # THE PIT / WARRIOR SHRINE / THRONE ROOM's
SHADOW_FAST = 2
PAL_PREFIX = "MK1CY_P"
MONK_PALS = {3: "MK1CYMK3_P", 4: "MK1CYMK4_P"}   # one MK1 palette per row
MONK_PAL = MONK_PALS[3]          # the records carry row 3's; row 4 swaps at build
PLANE_NOTE = {                   # each plane rendered alone (tmp/mk1court/planes.png)
    1: "the stone floor the fighters stand on",
    2: "the ledge and the two spear guards",
    3: "the near row of monks - runtime objects, not a module",
    4: "the far row of monks - runtime objects, not a module",
    5: "the stone wall, the bronze dragons and the yin-yang dais",
    6: "the pavilion roof and pillars, Shang Tsung on his throne",
    7: "the red lattice screen",
    8: "the mountains - rate 0, they never scroll",
}

LOD_BBB = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE COURTYARD (MK1), WOLF ONLY - image pack {n} (linear
;  0x{start:06X}..0x{end:06X}, above the T-unit's 12 MB)
;
;  data/{name}.BDB/.BDD are GENERATED by tools/make_mk1court.py --parts
;  straight out of C:\\MAME\\roms\\mk.zip - MK1's stage record FFCBB410.
;  The leak's KUNGFU2 is a pre-release Courtyard, not this one.
;  --apply merges the header table back into the stage's modules
;  (src/MK1CRTB.ASM).  Do not edit by hand.
;
;  PPP> {ppp}: {why}
;
;**************************************************************
ZON>
POF>
PPP> {ppp}
GLO> BGNDTBL.GLO
BBB> {name}
"""

LOD_MONK = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE COURTYARD (MK1), WOLF ONLY - THE MONKS (linear
;  0x{start:06X}..0x{end:06X})
;
;  data/MK1CRTMK.IMG is GENERATED by tools/make_mk1court.py --parts:
;  MK1's six idle frames (FFE976C0..), stepped every 8 ticks by the
;  stage's own process, and its three hands-together frames, which
;  MK1 loads and never shows - kept in the IMG, not packed.
;  Anipoints are 0: MK1 swaps a frame without moving the object, so
;  each row's anchor IS its top-left.
;
;  MK1CYTHRN is Shang Tsung on his throne - MK1's module-6 block 25h,
;  an object here so that MK1CYTHRNE, the throne EMPTY (painted by the
;  tool, not Midway's), can stand in when he is one of the fighters.
;
;  PON>: built with gso_dmawnz, which reads the palette off the
;  record.  {pal} and MK1CYTH_P are carried in src/MK1CRTB.ASM.
;
;**************************************************************
PON>
ZON>
PPP> {ppp}
ASM> MK1CYM.TBL
MK1CRTMK.IMG
---> {recs}
"""


def lod_addr(phys):
    """LOD form of a Wolf linear address (bank 1)."""
    if phys < 0xC00000:
        raise SystemExit(f"{phys:X} is in the T-unit's video ROM, not the Wolf region")
    return pit.lod_address(phys)


# --------------------------------------------------------------------------
# MK1
# --------------------------------------------------------------------------
def read_mk1(rom):
    if rom.l(pit.MK1_STAGES + COURT_ENTRY * 32) != COURT_MOD:
        raise SystemExit(f"MK1 stage table entry {COURT_ENTRY} is not {COURT_MOD:08X}")
    nm = rom.l(thr.NAME_TABLE + COURT_ENTRY * 32)
    o = (nm - pit.BASE) // 8
    if bytes(rom.p[o:o + len(NAME_STR)]) != NAME_STR:
        raise SystemExit(f"MK1 stage {COURT_ENTRY} is not named {NAME_STR!r}")
    m = COURT_MOD
    rec = dict(erase=rom.w(m), ground=rom.w(m + 16), worldy=rom.sw(m + 32),
               start=rom.w(m + 48), left=rom.w(m + 64), right=rom.w(m + 80),
               calla=rom.l(m + 96), scroll=rom.l(m + 128), bakmods=rom.l(m + 160))
    if rec["calla"] != COURT_CALLA:
        raise SystemExit(f"the courtyard's calla is {rec['calla']:08X}, not {COURT_CALLA:08X}")
    if [rom.w(COURT_CALLA + 16 * i) for i in range(len(CALLA_CODE))] != CALLA_CODE:
        raise SystemExit(f"{COURT_CALLA:08X} is no longer MK1's one-process courtyard calla")
    for at, words in shrine.SCROLL_CODE.items():
        if [rom.w(at + 16 * i) for i in range(len(words))] != words:
            raise SystemExit(f"MK1 scroller at {at:08X} moved - the plane/rate mapping is unproven")
    planes = []
    for e in range(9):
        base = shrine.PLANE_TABLE + 160 * e
        if rom.l(base + 64) != shrine.PLANE_WORLDTLX0 - 32 * e:
            raise SystemExit(f"MK1 plane table entry {e}: worldtlx {rom.l(base + 64):08X}")
        planes.append(rom.l(base + 96))
    if planes.index(rec["bakmods"]) != 1:
        raise SystemExit("the courtyard does not start on MK1's plane 1")

    mods = thr._placements(rom, COURT_MOD)
    for md in mods:
        md["rate"] = rom.l(rec["scroll"] + 32 * (8 - md["plane"]))
        if len(md["blks"]) != md["n"]:
            raise SystemExit(f"MK1 module {md['addr']:08X}: block count disagrees")
    if [md["plane"] for md in mods] != list(range(1, 9)):
        raise SystemExit(f"the courtyard's planes are {[md['plane'] for md in mods]}, not 1..8")
    if len({(md["hdrs"], md["pals"]) for md in mods}) != 1:
        raise SystemExit("the courtyard's modules no longer share one header table")
    if [rom.l(MONK_TAB + 32 * k) for k in range(6)] != MONK_FRAMES:
        raise SystemExit(f"MK1's monk frame table {MONK_TAB:08X} has moved")
    if [rom.l(BOW_TAB + 32 * k) for k in range(3)] != BOW_FRAMES:
        raise SystemExit(f"MK1's bow frame table {BOW_TAB:08X} has moved")
    return rec, mods


def monks(rom, mods):
    """The two monk rows: every block's world top-left and the palette each row
    is drawn in - MK1 gives the two rows DIFFERENT palettes (11 and 0)."""
    rows, rpal = {}, {}
    for md in mods:
        if md["plane"] not in MONK_PLANES:
            continue
        hw = {b[3] & 0xFFF for b in md["blks"]}
        if len(hw) != 1:
            raise SystemExit(f"monk module {md['addr']:08X} draws more than one image")
        out = []
        for b in md["blks"]:
            f, bx, by, _h = b
            if f & 0x10:
                raise SystemExit(f"monk block at {bx},{by} is flipped - the port draws them unflipped")
            out.append((md["x"] + bx, md["y"] + by))
        ps = {thr.pal_of(b) for b in md["blks"]}
        if len(ps) != 1:
            raise SystemExit(f"monk row on plane {md['plane']} uses palettes {sorted(ps)}")
        rpal[md["plane"]] = ps.pop()
        rows[md["plane"]] = sorted(out)
    frames = [rom.image(a) for a in MONK_FRAMES + BOW_FRAMES]
    hi = max(max(im["px"]) for im in frames)
    pals = {}
    for pl, p in rpal.items():
        pals[pl] = rom.palette(rom.l(mods[0]["pals"] + 32 * p))
        if hi >= len(pals[pl]):
            raise SystemExit(f"a monk frame indexes {hi}; MK1 palette {p} has {len(pals[pl])}")
    return dict(rows=rows, pals=pals, mk1pal=rpal, pal=pals[3], frames=frames,
                depth=cave._bpp(hi))


def empty_throne(px, W, H):
    """The throne with nobody on it, painted from the seated block.  The chair
    is mirror-symmetric about column 22.5 (checked on rows he leaves clear),
    so the left half is built and mirrored: posts (cols 7-10) and arm (cols
    0-11) are MK1's pixels where he does not cover them and a tile of the
    clean rows where he does; the back, seat and front are filled."""
    if (W, H) != (48, 55):
        raise SystemExit(f"the throne block is {W}x{H}, not the 48x55 empty_throne paints")
    g = lambda x, y: px[y * W + x]
    for y in (31, 33, 45, 50):
        if [g(x, y) for x in range(0, 9)] != [g(45 - x, y) for x in range(0, 9)]:
            raise SystemExit(f"the throne's arms are not mirror images on row {y}")
    L = [[0] * 23 for _ in range(H)]
    for y in range(5, 30):                               # the posts
        for x in (7, 8, 9):
            L[y][x] = g(x, y) if y <= 21 else g(x, 10 + (y - 22) % 8)
        L[y][10] = g(10, y) if y <= 17 else g(10, 10 + (y - 18) % 8)
    for y in (6, 7, 8):
        L[y][10] = 0
    for x, v in enumerate([0, 40, 58, 61, 62, 62, 61, 60, 58, 53, 40]):
        L[30][x] = v                                     # the arm's top edge
    for y in range(31, 55):                              # the arm
        for x in range(0, 11):
            L[y][x] = g(x, y)
        L[y][11] = g(11, y) if y <= 36 else (39 if y % 3 else 38)
    L[30][11] = 39
    for x in range(11, 23):                              # the back: gilt rail,
        L[10][x] = 46                                    # then the cushion
    r11 = [42, 43, 43, 43, 45, 54, 54, 45, 54, 54, 45, 54]
    r12 = [54, 55, 55, 54, 45, 45, 54, 45, 45, 43, 45, 45]
    ramp = [45, 43, 43, 42, 42, 38, 39, 39]
    for i, x in enumerate(range(11, 23)):
        L[11][x], L[12][x] = r11[i], r12[i]
        for y in range(13, 30):
            t = (y - 13) * 6 // 17 + (x == 11) + (x >= 19)
            t += ((x * 3 + y * 5) % 7 == 0) - ((x + y * 2) % 9 == 0)
            L[y][x] = ramp[max(0, min(len(ramp) - 1, t))]
    seat = {30: (42, 43), 31: (43, 43), 32: (43, 45), 33: (45, 45), 34: (45, 54),
            35: (54, 57), 36: (57, 54), 37: (42, 38)}
    for y in range(30, 55):                              # the seat and the front
        for x in range(12, 23):
            if y in seat:
                v = seat[y][0] if (x + y) % 3 else seat[y][1]
                if x == 12:
                    v = 42 if y < 37 else 39
            elif y == 38:
                v = 37
            else:
                v = [38, 39, 39, 37, 37][(y - 38) * 4 // 17 + ((x * 5 + y * 3) % 6 == 0)]
            L[y][x] = v
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(23):
            out[y][x] = out[y][45 - x] = L[y][x]
    return bytes(v for r in out for v in r)


def throne(rom, allmods):
    """Take the Shang Tsung block out of module 6: (the modules without it,
    the throne as an object)."""
    plane, bx, by, mk1pal = THRONE_AT
    hits = [(md, b) for md in allmods for b in md["blks"] if (b[3] & 0xFFF) == THRONE_HDR]
    if len(hits) != 1:
        raise SystemExit(f"MK1 header {THRONE_HDR:X} is drawn by {len(hits)} blocks, not 1")
    md, blk = hits[0]
    f, x, y, _h = blk
    if (md["plane"], x, y, thr.pal_of(blk)) != THRONE_AT or f & 0x10:
        raise SystemExit(f"the throne block moved: plane {md['plane']} at {x},{y}, "
                         f"palette {thr.pal_of(blk)}, flags {f:04X}")
    for b in md["blks"]:                                 # it comes out of the z
        if b is blk:                                     # order, so nothing in
            continue                                     # the module may touch it
        a2 = md["hdrs"] + 80 * (b[3] & 0xFFF)
        w2, h2 = rom.w(a2), rom.w(a2 + 16)
        if b[1] < x + 48 and x < b[1] + w2 and b[2] < y + 55 and y < b[2] + h2:
            raise SystemExit(f"module 6's block at {b[1]},{b[2]} overlaps the throne")
    a = md["hdrs"] + 80 * THRONE_HDR
    w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
    rows, _bpp = pit.decode_record(rom.g, sag - pit.IROM, w, h, ctrl)
    px = bytes(v for r in rows for v in r)
    pal = rom.palette(rom.l(md["pals"] + 32 * mk1pal))
    if max(px) >= len(pal) or cave._bpp(max(px)) > MONK_PPP:
        raise SystemExit("the throne indexes past its palette or past the pack's depth")
    cut = dict(md, blks=[b for b in md["blks"] if b is not blk])
    mods = [cut if m is md else m for m in allmods]
    frames = [dict(w=w, h=h, px=px), dict(w=w, h=h, px=empty_throne(px, w, h))]
    return mods, dict(x=md["x"] + x, y=md["y"] + y, plane=plane, pal=pal, frames=frames)


def layout():
    rom = pit.MK1()
    rec, allmods = read_mk1(rom)
    allmods, T = throne(rom, allmods)
    mods = [md for md in allmods if md["plane"] not in MONK_PLANES]
    imgs, order, uniq, pals, remap, share = thr.art(rom, mods)
    pals = [(f"{PAL_PREFIX}{k:02d}", w, p) for k, (_lab, w, p) in enumerate(pals)]
    return dict(rom=rom, rec=rec, mods=mods, allmods=allmods, imgs=imgs, order=order,
                uniq=uniq, pals=pals, remap=remap, share=share, monk=monks(rom, allmods),
                throne=T)


def ground_y(L):
    return L["rec"]["ground"] + GROUND_NUDGE


def rec_scroll(L, plane):
    return L["rom"].l(L["rec"]["scroll"] + 32 * (8 - plane))


# The camera does not stop AT right_edge: scr_right (BGND.ASM) refuses to
# scroll only once worldtlx >= right_edge, and that tick's step is applied
# anyway, so it lands up to one step past the limit. The fastest step is
# right_scrolls' last row, 0a0000h = 10 px a tick, so worldtlx can read
# right_edge+9 (measured: a walking camera stops at limit+2).
SCROLL_OVERSHOOT = 0xA0000 // 0x10000 - 1


def right_limit(L):
    """MK1's right scroll limit, pulled in until no camera the scroller can
    reach from it shows a hole.

    Where the right-hand spear guard's robe meets the floor lip, nothing on
    any plane covers plane-1 world x 1034+, so the erase colour (the sky
    blue) shows through - first at camera 630, 24 pixels at x 390-399 by 634.
    MK1 has the same gap and stops at 634, but its display sits 1-2 px left
    of MK2's for the same worldtlx (measured against a parked MK1 frame), so
    it barely shows it. A hole is an erase pixel anywhere from the top of
    plane 1's module (the floor lip, the nearest solid plane) down."""
    rec = L["rec"]
    md1 = next(md for md in L["mods"] if md["plane"] == 1)
    top = max(0, md1["y"] - rec["worldy"])
    er = rgb(rec["erase"])
    clean = {}

    def ok(cam):
        if cam not in clean:
            px = render(L, cam).load()
            clean[cam] = not any(px[x, y] == er for y in range(top, SCREEN_H) for x in range(SCREEN_W))
        return clean[cam]

    for lim in range(rec["right"], rec["left"], -1):
        if all(ok(c) for c in range(lim + SCROLL_OVERSHOOT, lim - 1, -1)):
            return lim
    raise SystemExit("THE COURTYARD: no hole-free right limit")


# --------------------------------------------------------------------------
# Packs
# --------------------------------------------------------------------------
def wide_tail(im):
    return cave._bpp(im["px"][-1]) > cave._bpp(max(im["px"][:-1], default=0))


def deal(L):
    imgs = L["imgs"]
    cap = [int((e - s) * 8 * PACK_MARGIN) for _n, s, e, _p in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(L["uniq"], key=lambda i: (-cave.packed_bits(imgs[i]), i)):
        im = imgs[idx]
        want = 8 if wide_tail(im) else 0
        bits = im["w"] * im["h"] * 8 if want else cave.packed_bits(im)
        for k, (_n, _s, _e, ppp) in enumerate(PACKS):
            if ppp == want and used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    return [sorted(g) for g in got], used


def part_files(L):
    imgs = L["imgs"]
    groups, _ = deal(L)
    files = {}
    for (name, s, e, ppp), group in zip(PACKS, groups):
        if not group:
            continue
        bdd = bytearray(b"%d\n" % len(group))
        for idx in group:
            im = imgs[idx]
            bdd += b"%x %d %d %d\n" % (idx, im["w"], im["h"], im["big"])
            bdd += im["px"]
        for label, words, _p in L["pals"]:
            bdd += b"%s %d\n" % (label.encode(), len(words))
            bdd += struct.pack("<%dH" % len(words), *words)
        x, lines = 0, []
        for idx in group:
            lines.append("4000 %d 0 %X 0" % (x, idx))
            x += imgs[idx]["w"] + 4
        hmax = max(imgs[i]["h"] for i in group)
        bdb = [f"{name} {max(x, 1)} {hmax} 255 1 {len(L['pals'])} {len(group)}",
               f"{name} 0 {max(x - 5, 0)} 0 {hmax - 1}"] + lines
        files[f"{name}.BDD"] = bytes(bdd)
        files[f"{name}.BDB"] = ("\n".join(bdb) + "\n").encode()
        why = ("per-block auto depth, as every BBB> in MK7MIL" if ppp == 0 else
               "LOAD2's auto depth ignores a block's LAST pixel and spills it into the "
               "next record; these blocks' last pixel needs more bits than the rest")
        files[f"{name}.LOD"] = LOD_BBB.format(addr=lod_addr(s), n=name[-1], start=s, end=e,
                                              name=name, ppp=ppp, why=why).encode()
    return files


def monk_entries(M):
    out = []
    for k, im in enumerate(M["frames"]):
        nm = f"MK1CYMONK{k + 1}" if k < 6 else f"MK1CYBOW{k - 5}"
        out.append((nm, 0, 0, im["w"], im["h"], im["px"], 0))
    return out


def sprite_frames(L):
    """{record name: image} for everything MK1CYM packs, in pack order."""
    out = {f"MK1CYMONK{k + 1}": im for k, im in enumerate(L["monk"]["frames"][:6])}
    out.update(zip(THRONE_RECS, L["throne"]["frames"]))
    return out


def monk_files(L):
    M, T = L["monk"], L["throne"]
    ents = monk_entries(M) + [(nm, 0, 0, im["w"], im["h"], im["px"], 1)
                              for nm, im in zip(THRONE_RECS, T["frames"])]
    img = pit.build_img(ents, [(MONK_PAL, M["depth"], M["pal"]), (THRONE_PAL, MONK_PPP, T["pal"])])
    name, s, e = MONK_PACK
    bits = sum(cave.packed_bits(im) for im in sprite_frames(L).values())
    if bits > (e - s) * 8 * PACK_MARGIN:
        raise SystemExit(f"the monk frames (~{bits // 8} B) do not fit {name}")
    recs = ",".join(sprite_frames(L))
    lod = LOD_MONK.format(addr=lod_addr(s), start=s, end=e, pal=MONK_PAL, ppp=MONK_PPP, recs=recs)
    return {MONK_IMG.name: img, f"{name}.LOD": lod.encode()}


# --------------------------------------------------------------------------
# --apply
# --------------------------------------------------------------------------
def wolf_irw(name):
    """(linear start, payload) of a Wolf pack, placed the way makevrom.py's
    Wolf loop places it - from the LOD-form base, not image_byte_offset."""
    if pit._MV is None:
        pit._irw("MK1PT1")                        # loads makevrom
    path = DATA / f"{name}.IRW"
    if not path.exists():
        raise SystemExit(f"{path} missing - run python build.py")
    base, _bank, payload = pit._MV.parse_irw(path)
    return 0x800000 + (base - 0x2000000) // 8, payload


def merged_headers(L):
    imgs = L["imgs"]
    groups, _ = deal(L)
    by = {}
    for (name, start, end, _p), group in zip(PACKS, groups):
        if not group:
            continue
        snap = LOAD2 / f"BGNDTBL.{name[-3:]}"
        if not snap.exists():
            raise SystemExit(f"{snap} missing - run python build.py")
        hdrs = cave.read_hdrs(snap)
        if len(hdrs) != len(group):
            raise SystemExit(f"{snap}: {len(hdrs)} headers, pack has {len(group)} images")
        for idx, (w, h, addr, ctrl) in zip(group, hdrs):
            im = imgs[idx]
            if (w, h) != (im["w"], im["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}, MK1 says {im['w']}x{im['h']}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} (phys {p:X}) outside {start:X}..{end:X}")
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
    for i, j in L["share"].items():
        w, h, addr, ctrl, src = by[j]
        by[i] = (w, h, addr, ctrl, f"{src} (MK1 shares one SAG with {j:02X})")
    return [by[i] for i in L["order"]]


def monk_tbl():
    """[(name, w, h, sag, ctrl)] out of LOAD2's src/MK1CYM.TBL."""
    p = SRC / "MK1CYM.TBL"
    if not p.exists():
        raise SystemExit(f"{p} missing - run python build.py")
    out, lines = [], p.read_text(encoding="latin-1").splitlines()
    for i, ln in enumerate(lines):
        if ln.strip().endswith(":") and ln.strip()[:-1].startswith("MK1CY"):
            w, h, _ax, _ay = (int(v, 0) for v in lines[i + 1].split(None, 1)[1].split(","))
            sag = int(lines[i + 2].split()[1].rstrip("Hh"), 16)
            ctrl = int(lines[i + 3].split()[1].rstrip("Hh"), 16)
            out.append((ln.strip()[:-1], w, h, sag, ctrl))
    return out


def decode_at(addr, w, h, ctrl):
    p = cave.sag_phys(addr)
    for name, *_r in PACKS + [MONK_PACK]:
        if not (DATA / f"{name}.IRW").exists():
            continue
        start, payload = wolf_irw(name)
        if start <= p < start + len(payload):
            rows, _b = pit.decode_record(payload, pit.runtime_bit(addr) - start * 8, w, h, ctrl)
            return name, bytes(b for r in rows for b in r)
    raise SystemExit(f"SAG {addr:08X} (linear {p:X}) is in no written Wolf pack")


def verify_rom(L, hdrs):
    bad = []
    for idx, (w, h, addr, ctrl, src) in zip(L["order"], hdrs):
        try:
            name, px = decode_at(addr, w, h, ctrl)
        except IndexError:
            bad.append(f"MK1 {idx:02X} runs off its IRW")
            continue
        want = L["imgs"][idx]["px"]
        n = sum(1 for a, b in zip(px, want) if a != b)
        if n:
            bad.append(f"{name}: MK1 {idx:02X} ({w}x{h}, {src}) - {n} pixels differ from mk.zip")
    want = sprite_frames(L)
    tbl = monk_tbl()
    if [t[0] for t in tbl] != list(want):
        bad.append(f"src/MK1CYM.TBL holds {[t[0] for t in tbl]}, not {list(want)}")
        tbl = []
    for nm, w, h, sag, ctrl in tbl:
        im = want[nm]
        if (w, h) != (im["w"], im["h"]):
            bad.append(f"{nm}: {w}x{h}, MK1 frame is {im['w']}x{im['h']}")
            continue
        try:
            name, px = decode_at(sag, w, h, ctrl)
        except IndexError:
            bad.append(f"{nm} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, im["px"]) if a != b)
        if n:
            bad.append(f"{name}: {nm} - {n} pixels differ from "
                       + ("the tool's empty throne" if nm == THRONE_RECS[1] else "mk.zip"))
    return bad


def h4(v, d=4):
    return "0%0*XH" % (d, v & ((1 << (4 * d)) - 1))


def build_asm(L, hdrs):
    rec, mods, M = L["rec"], L["mods"], L["monk"]
    o = []
    w = o.append
    w("; THE COURTYARD (MK1) - GENERATED by tools/make_mk1court.py --apply.  Do not hand-edit.")
    w("; Art and layout: MK1's stage record FFCBB410 (C:\\MAME\\roms\\mk.zip), read by the tool.")
    w("; Included only under .if wunit (src/MK1CRT.ASM) - Wolf-only art.")
    w("")
    w(f"mk1c_erase\t.set\t{h4(rec['erase'])}\t\t; MK1's autoerase")
    w(f"mk1c_ground\t.set\t{ground_y(L)}\t\t; MK1's {rec['ground']} {GROUND_NUDGE:+d}")
    w(f"mk1c_worldy\t.set\t{rec['worldy']}")
    w(f"mk1c_start\t.set\t{rec['start']}")
    w(f"mk1c_left\t.set\t{rec['left']}")
    rl = right_limit(L)
    w(f"mk1c_right\t.set\t{rl}\t\t; MK1's {rec['right']}, pulled in past the guard's floor hole + scroll overshoot"
      if rl != rec["right"] else f"mk1c_right\t.set\t{rl}")
    w(f"mk1c_shad_fast\t.set\t{SHADOW_FAST}")
    for e in range(9):
        w(f"mk1c_rate{e}\t.set\t{h4(rec_scroll(L, e), 6)}\t\t; plane {e}"
          + (f" - {PLANE_NOTE[e]}" if e in PLANE_NOTE else ""))
    for md in mods:
        n = md["plane"]
        w(f"mk1c_m{n}_x\t.set\t{md['x']}\t\t; plane {n} - {PLANE_NOTE[n]}")
        w(f"mk1c_m{n}_y\t.set\t{md['y']}")
    w(f"mk1c_mk_rate\t.set\t{MONK_RATE}\t\t; MK1's MOVI 8,A0 - ticks a monk frame")
    w(f"mk1c_mk_nfr\t.set\t6\t\t; MK1's idle loop, table FFCBBB30")
    for pl in MONK_PLANES:
        w(f"mk1c_mk_n{pl}\t.set\t{len(M['rows'][pl])}\t\t; monks on plane {pl} (MK1 module {pl})")
    T = L["throne"]
    w(f"mk1c_th_x\t.set\t{T['x']}\t\t; the throne: MK1 block {THRONE_HDR:X}h's world top-left,")
    w(f"mk1c_th_y\t.set\t{T['y']}\t\t;   on plane {T['plane']}'s camera")
    w("")
    w("\t.data")
    w("")
    w("MK1CYHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["order"]):
        w(f"\t.word\t{hw},{hh}\t\t; MK1 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["order"])}
    for md in mods:
        lab = "MK1CY%d" % md["plane"]
        w(f"{lab}BLKS:\t\t\t\t; {PLANE_NOTE[md['plane']]}")
        for blk in md["blks"]:
            f, bx, by, hw = blk
            np = L["remap"][thr.pal_of(blk)]
            w("\t.word\t%s,%d,%d,%s" % (h4((f & 0xFFF0) | (np & 0xF)), bx, by,
                                        h4(hidx[hw & 0xFFF] + ((np >> 4) << 12))))
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{md['w']},{md['h']},{len(md['blks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, MK1CYHDRS, MK1CYPALS")
        w("")
    w("MK1CYPALS:")
    for label, _words, p in L["pals"]:
        w(f"\t.long\t{label}\t\t; MK1 palette {p}")
    w("")
    for label, words, _p in (L["pals"] + [(MONK_PALS[pl], M["pals"][pl], M["mk1pal"][pl])
                                          for pl in MONK_PLANES]
                             + [(THRONE_PAL, T["pal"], THRONE_AT[3])]):
        w(f"{label}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    w("")
    w("; THE MONKS - world top-left of every MK1 block in modules 3 and 4.")
    for pl in MONK_PLANES:
        w(f"mk1c_mk_row{pl}:\t\t\t; plane {pl}")
        for x, y in M["rows"][pl]:
            w(f"\t.word\t{x},{y}")
    w("mk1c_mk_frames:\t\t\t; MK1's table FFCBBB30, in order")
    for k in range(6):
        w(f"\t.long\tMK1CYMONK{k + 1}")
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------
def rgb(c):
    return thr.rgb(c)


def plane_x(L, cam):
    s = L["rec"]["start"]
    return {e: s + (cam - s) * rec_scroll(L, e) // 0x20000 for e in range(9)}


def render(L, cam, frame=0, empty=False):
    from PIL import Image, ImageDraw
    rec, M = L["rec"], L["monk"]
    cam_y = rec["worldy"]
    px_x = plane_x(L, cam)
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), rgb(rec["erase"]))
    px = scr.load()

    def put(im_px, w, h, ox, oy, pal, flip=False):
        for y in range(h):
            ty = oy + y
            if not 0 <= ty < SCREEN_H:
                continue
            row = im_px[y * w:(y + 1) * w]
            for x in range(w):
                tx = ox + x
                if 0 <= tx < SCREEN_W:
                    v = row[w - 1 - x] if flip else row[x]
                    if v:
                        px[tx, ty] = rgb(pal[v])

    for plane in range(8, 0, -1):
        camx = px_x[plane]
        if plane in MONK_PLANES:
            im = M["frames"][frame]
            for x, y in M["rows"][plane]:
                put(im["px"], im["w"], im["h"], x - camx, y - cam_y, M["pals"][plane])
            continue
        md = next((m for m in L["mods"] if m["plane"] == plane), None)
        if md is None:
            continue
        # HIGHER z IN FRONT: PALACE GATES' spear guard (4153h) stands in
        # front of the wall (4040h) in MK1 and in MK2 alike
        for blk in sorted(md["blks"], key=lambda b: b[0] & 0xFFF0):
            f, bx, by, hw = blk
            im = L["imgs"][hw & 0xFFF]
            pal = L["pals"][L["remap"][thr.pal_of(blk)]][1]
            put(im["px"], im["w"], im["h"], md["x"] + bx - camx, md["y"] + by - cam_y, pal,
                bool(f & 0x10))
        T = L["throne"]
        if plane == T["plane"]:                          # its own list, after the plane
            im = T["frames"][1 if empty else 0]
            put(im["px"], im["w"], im["h"], T["x"] - camx, T["y"] - cam_y, T["pal"])
    gy = ground_y(L) - cam_y
    if 0 <= gy < SCREEN_H:
        ImageDraw.Draw(scr).line([(0, gy), (SCREEN_W - 1, gy)], fill=(255, 0, 0))
    return scr


def preview(L, cams):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cams = cams or [rec["left"], rec["start"], rec["start"], right_limit(L)]   # odd shots: empty throne
    shots = [(c, render(L, c, empty=k % 2 == 1)) for k, c in enumerate(cams)]
    sheet = Image.new("RGB", (SCREEN_W, (SCREEN_H + 12) * len(shots)), (16, 16, 20))
    dr = ImageDraw.Draw(sheet)
    for k, (c, im) in enumerate(shots):
        sheet.paste(im, (0, k * (SCREEN_H + 12)))
        dr.text((4, k * (SCREEN_H + 12) + 2), "camera %d" % c, fill=(255, 255, 0))
    out = ROOT / "tmp" / "mk1court"
    out.mkdir(parents=True, exist_ok=True)
    sheet.save(out / "preview.png")
    print(f"wrote {out / 'preview.png'}  ({', '.join(str(c) for c in cams)})")


def report(L):
    rec, M = L["rec"], L["monk"]
    print(f"THE COURTYARD (MK1) - record {COURT_MOD:08X}, entry {COURT_ENTRY}  (Wolf only)")
    print(f"  erase {rec['erase']:04X}  ground {rec['ground']} (MK2 {ground_y(L)})  camera y "
          f"{rec['worldy']}  start {rec['start']}  limits {rec['left']}..{rec['right']}")
    for md in L["allmods"]:
        what = "MONKS (objects)" if md["plane"] in MONK_PLANES else f"{len(md['blks'])} blocks"
        print(f"    plane {md['plane']}  {md['w']:5d}x{md['h']:<4d} at ({md['x']:4d},{md['y']:4d})  "
              f"rate {md['rate']:06X}  {what}")
    print(f"  art: {len(L['order'])} headers, {len(L['uniq'])} payloads, {len(L['pals'])} palettes")
    groups, used = deal(L)
    for (name, s, e, ppp), g, u in zip(PACKS, groups, used):
        print(f"  {name} PPP>{ppp} {s:06X}..{e:06X}: {len(g)} images ~{u // 8:,} B "
              f"({100 * u / 8 / (e - s):.0f}%)")
    mb = sum(cave.packed_bits(im) for im in sprite_frames(L).values()) // 8
    print(f"  monks: rows {[len(M['rows'][p]) for p in MONK_PLANES]}, frames "
          f"{M['frames'][0]['w']}x{M['frames'][0]['h']} {M['depth']}bpp, MK1 palettes "
          f"{M['mk1pal']}, ~{mb:,} B in {MONK_PACK[0]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parts", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--preview", nargs="*", type=int, metavar="CAMX")
    a = ap.parse_args()
    if not any((a.parts, a.apply, a.check, a.report, a.preview is not None)):
        ap.error("one of --parts / --apply / --check / --report / --preview")
    L = layout()
    if a.report:
        report(L)
    if a.preview is not None:
        preview(L, a.preview)
    files = {}
    if a.parts or a.check:
        files.update(part_files(L))
        files.update(monk_files(L))
    if a.parts:
        for nm, data in files.items():
            (DATA / nm).write_bytes(data)
            print(f"wrote data/{nm}  ({len(data):,} bytes)")
    asm = None
    if a.apply or a.check:
        hdrs = merged_headers(L)
        bad = verify_rom(L, hdrs)
        if bad:
            raise SystemExit("THE COURTYARD's art is not MK1's:\n  " + "\n  ".join(bad))
        asm = build_asm(L, hdrs)
        if a.apply:
            OUT_ASM.write_text(asm, encoding="latin-1")
            print(f"wrote {OUT_ASM.relative_to(ROOT)}  ({len(asm.splitlines())} lines)")
    if a.check:
        drift = [f"data/{nm} is not the tool's - rerun --parts" for nm, data in files.items()
                 if not (DATA / nm).exists() or (DATA / nm).read_bytes() != data]
        if not OUT_ASM.exists() or OUT_ASM.read_text(encoding="latin-1") != asm:
            drift.append(f"{OUT_ASM.relative_to(ROOT)} has drifted - rerun --apply")
        if drift:
            raise SystemExit("THE COURTYARD (MK1) check FAILED:\n  " + "\n  ".join(drift))
        print("THE COURTYARD (MK1): packs, tables and packed pixels all match mk.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
