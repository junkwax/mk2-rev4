#!/usr/bin/env python3
r"""SCORPION'S LAIR - UMK3's hell stage, as a WOLF-ONLY MK2 stage (curback 01Fh),
with its stage fatality: an uppercut that sends the loser into the lava.

Code is src/UMK3LAIR.ASM; everything it is built from is generated into
src/UMK3LRB.ASM by this tool, out of one source:

  C:\\MAME\\roms\\umk3.zip    UMK3 (MAME `umk3`), read by tools/umk3rom.py.
                           The stage record is FF952560 (BKGD_HADES_MOD 0Ch).

The leak's deadlythirdcombat MKHELL.BDB/.BDD is UMK3's art library, but its
HADES2 module is 14 blocks / 1333 wide where the ROM's is 15 / 1332, so the
ROM is what is imported (its decoded blocks match the BDD's pixels exactly).
Every number below was read with MAME's disassembler (`umk3` driver):

  RECORD  FF952560: erase 0 (black), world y 0, ground FBh, start x 190h,
          limits 0..321h; calla FF952D70, scroll FF952970, dlists FF952A90;
          HADES1..5 on baklst 1, 2, (3 skipped), 4, 5, 6; then center_x for
          HADES2..5; then the floor: FL_HELL (1200x46, 6bpp), its palette,
          height 2Eh, skew_7 (FF9622E0: dx -= scroll >> 7).
  DLISTS  baklst6, 5, 4; baklst3 ON PLANE 2's CAMERA (the flames); baklst2;
          the floor; baklst1; baklst7 (the falling body) on plane 1's; the
          shadows; the objects.
  CALLA   create_dumb_animators: two flames, FFCEA4D0 (HELLFLAME01..06, 33x36,
          4 ticks a frame, list FF952EF0) at world (84h,5Eh) and (27Dh,5Eh) on
          baklst3.
  LAVA    FFAE3220 (fall_in_lava): the shared FFAE46D0 throws him off the top
          (-100000h, until 100h off the ground), rocks, 50h ticks; a new body
          on baklst7 with no scroll, at the other man's screen x +80h (or -80h
          right of C7h, never left of 80h), y 0, falling at 20000h under 6000h
          until y B2h; shake 4,6, sound 5Fh, HELLHIT1..8 (FFA81C70) at 5 ticks a
          frame on its own palette; death_blow_complete.  UMK3 draws the
          falling body from per-character tumble art MK2's fighters do not
          have, so - as UMK3's own PSX port does (BKGDCAVE.C fall_in_lava) -
          it is the fighter's own knockdown frame, shrunk (oscale 1C0h).

WOLF ONLY - art above the T-unit's 12 MB, module under `.if wunit`.
  --parts / --apply / --check / --report / --preview
"""
from __future__ import annotations

import argparse
import shutil
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave      # noqa: E402
import make_mk1pit as pit        # noqa: E402
import make_mk1throne as thr     # noqa: E402
import make_mk1court as court    # noqa: E402
import umk3rom                   # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "UMK3LRB.ASM"
SPR_IMG = DATA / "UMK3LRMK.IMG"
SPR_TBL = SRC / "UMK3LRM.TBL"
FLOOR_BIN = DATA / "FL_HELL.BIN"
FLOOR_SRC = Path("C:/Users/you/Workplace/deadlythirdcombat-main/deadlythirdcombat-main/BINFILES/FL_HELL.BIN")
SCREEN_W, SCREEN_H = 400, 254
FLOOR_W = 1200                    # MKDISP floor_x

# Wolf video ROM, linear, after PALACE GATES' (which ends at 0xC50000)
PACKS = [("LAIR1", 0xC50000, 0xC70000, 0),    # 128 KB - the stage blocks
         ("LAIR2", 0xC70000, 0xC74000, 8)]    # deeper last pixel (wide_tail)
# MK2 puts a fighter's feet ON ground_y; UMK3 stands them ~8 px ABOVE its
# record's ground (FBh).  Measured off retail UMK3 (tools/umk3_stage_sweep.lua)
# against this build at the same camera: UMK3's boots end at y ~243, ours ran
# to ~251-253 - off the bottom of the screen.  So the MK2 ground is lifted.
GROUND_LIFT = 8
# THE TWO EDGES (2026-10-10, the user's report: "a gap on the far left, a
# black line on the right").
# - MK2's center_x (BGND.ASM ibak7) seeds a plane at w/2 - scrrgt/2, and
#   scrrgt is 399, so the 400-wide arches (plane 6, rate 0) sat at worldtlx6
#   1: drawn a pixel left, column 399 empty wherever no tower stands in front
#   of it - a black line down the lava rows.  The module moves right by what
#   center_x takes off it, so it lands on column 0.
# - At the left limit the skull's outermost block (block 0, H-flipped, 64x252)
#   has a wholly transparent outer column - UMK3's own art, decoded exactly -
#   so the lava showed through screen column 0 as a stripe.  The plane-1
#   module moves LEFT_GUARD px left.  Not the scroll limit: scr_left stops
#   on worldtlx <= left_edge, so the camera overshoots the limit by up to a
#   scroll step (measured: limit 1 parked it at 0), and the guard covers that.
CENTER_SLOP = SCREEN_W // 2 - 399 // 2      # 1: what center_x leaves over
LEFT_GUARD = 3
EDGE_SHIFT = {6: CENTER_SLOP, 1: -LEFT_GUARD}   # plane -> module x added
# THE HEAT HAZE at the foot of every skull tower.  The lava sea used to carry
# it (the arches, plane 6, drawn whole by sky_rows); the user's call on
# 2026-10-08 was to take it off the lava and put it where the towers stand in
# it.  The towers are ordinary blocks on planes 2, 4 and 5, each on its own
# camera, so each plane's LAST BASE_ROWS rows - the fire at its foot - are
# composited into a raw 6bpp band and sky_rows_over (MKDISP.ASM) draws the
# band's lines OVER the plane, each at its own x.  One palette a band, so one
# layer.  The three bands sit one after another in data/LAIRWALL.BIN (the
# pack keeps its name: every build step already knows it), each on a 32-bit
# boundary.  Wolf linear 0xE28000, past UMK3 SINDEL's second pack.
# 2026-10-08, the user's second call: the towers' wave SUBTLER and TALLER - a
# mirage off a road, not a flame - and the haze back on the very background
# as well (the arches, plane 6; the lava glow under them stays still).
# BASE_ROWS is as tall as plane 2's foot blocks allow (49 rows; the tower
# above them is on another palette and a line carries one).  A tier is a mask
# of the two waves, so "subtle" is the fine +-1 wave alone, thinned to every
# other row at the top so it fades in, with both waves only on the last rows
# where the towers meet the lava.
#
# THE BUDGET IS THE DMA QUEUE, AND IT IS MEASURED: 500 cells, of which
# sky_rows keeps 300 for the lists after it and checks a band's whole row
# count before it queues one line.  The arches drawn whole (133 lines) plus
# three 48-row bands left the last two bands failing that check EVERY frame
# (skr_plain rising as fast as skr_ran) - still towers, no error.  So the
# arches are a band too (sky_rows_over, only the rows that move), an overlay
# skips its still rows outright, and four bands of ~40 rows fit.
BASE_ROWS = 44
BASE_THIN = 16                  # top rows: the fine wave on every other row
BASE_BOTH = 6                   # last rows: both waves
WALL_STILL_FROM = 163           # world y the lava glow starts at: still from here
WALL_ROWS = 40                  # rows of the arches above it that move
WALL_THIN = 16                  # top rows of those: every other row
BASE_PLANES = (5, 4, 2)         # back first
WALL_PACK = ("LAIRWALL", 0xE28000, 0xE58000)
LOD_WALL = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  SCORPION'S LAIR: the foot of every skull tower (planes 5, 4 and 2) as
;  three raw 6bpp bands for the heat haze - GENERATED by
;  tools/make_umk3lair.py --parts.  sky_rows_over (MKDISP.ASM) draws them a
;  line at a time over the towers; the format of data/ARNSKY.LOD, for its
;  reason: a single-row blit must start mid-image, which only raw art allows.
;  POF> (sky_rows findpals each band's palette), ZOF>, PPP> 6.
;  Wolf linear 0x{start:06X}.
;
;**************************************************************
POF>
ZOF>
PPP> 6
ASM> LAIRWALL.TBL
FRM> LAIRWALL
"""
SPR_PACK = ("LAIRM", 0xC74000, 0xC7C000)      # 32 KB - flames + lava splash
# THE CEILING COMING DOWN: fall_in_lava's create_fx(29h) = subway_rox (FFB400C0)
# as he leaves the top - two "explode through floor" sounds, shake (A,10h) and
# 10 small / 8 medium / 4 large cave rocks dropped from where he broke through
# (MK3 MKFX.ASM subway_rox / do_rox / subway_rock_fall / land_subway_rock,
# the arcade's own numbers).  Their own pack: 5bpp, and the LAIRM slot is
# 32 KB with the flames and the splash already in it.
ROX_PACK = ("LAIRRX", 0xE44000, 0xE50000)     # 48 KB - rocks + crumble, 5bpp
ROX_TBL = SRC / "LAIRRX.TBL"
ROX_PPP = 5
ROX_FX = 0xFFB400C0
# (name prefix, UMK3 list, count dropped) - the crumble is played by every rock
ROX_GROUPS = [("LRKS", 0xFFB512D0, 10), ("LRKM", 0xFFB51490, 8), ("LRKL", 0xFFB51650, 4)]
ROX_CRUMBLE = ("LRKC", 0xFFB51810)
ROX_SHAKE = 0x000A0010            # shake_a11's [y:x], MOVI A0010h,A11
ROX_GRAV, ROX_XVEL, ROX_BOUNCE = 0x4000, 0x20000, 0x20000
# the fall's spin: subway_rock_fall never sets an anirate (the arcade runs
# next_anirate on whatever the recycled process slot held); 4 is the A10 it
# loads right before the gravity loop.  The bounce (2) and crumble (3) are set.
ROX_FALL_RATE, ROX_BOUNCE_RATE, ROX_CRUMBLE_RATE = 4, 2, 3
ROX_DELAY, ROX_GND_MIN, ROX_GND_RANGE, ROX_GND_UP = 8, 5, 5, 0x10
FLOOR_PACK = ("LAIRFL", 0xC7C000, 0xC88000)   # 48 KB - FL_HELL, 41,400 B raw
SPR_PPP = 6
PACK_MARGIN = 0.90

REC = 0xFF952560
CALLA, SCROLL, DLISTS = 0xFF952D70, 0xFF952970, 0xFF952A90
ANIM_TAB = 0xFF952DC0             # create_dumb_animators' table
FLAME_LIST = 0xFF952EF0
HIT_LIST = 0xFFA81C70
LAVA = 0xFFAE3220
# (address, words) - what the import was read from; a different ROM fails here
CODE_CHECKS = {
    CALLA: [0x09E6, 0x2DC0, 0xFF95],                      # MOVI FF952DC0h,A6
    0xFF9622E0: [0x07AB, 0xF370, 0x0105, 0x2B29, 0x452B],  # skew_7
    0xFFAE33F0: [0x05A1, 0xDAE0, 0x0105, 0x4420, 0x09C5, 0x0080],   # x = other - camera, 80h
    0xFFAE3450: [0x0B40, 0xFF38],                         # CMPI C7h
    0xFFAE3550: [0x09E0, 0x0000, 0x0002],                 # MOVI 20000h - yvel
    0xFFAE35A0: [0x09C0, 0x6000],                         # MOVI 6000h - grav
    0xFFAE3650: [0x0B40, 0xFF4D],                         # CMPI B2h  - the lava
    0xFFAE3680: [0x09EB, 0x0006, 0x0004],                 # MOVI 40006h,A11 - shake
    0xFFAE36E0: [0x09C0, 0x005F],                         # sound 5Fh
    0xFFAE3760: [0x09E9, 0x1C70, 0xFFA8],                 # MOVI FFA81C70h,A9
    0xFFAE37F0: [0x18A0],                                 # MOVK 5h,A0 - framew 5
    0xFFAE47E0: [0x09E0, 0x0000, 0xFFF0],                 # MOVI FFF00000h - up
    0xFFAE4970: [0x0B40, 0xFEFF],                         # CMPI 100h - off ground
    0xFFAE4A50: [0x09C0, 0x0050],                         # sleep 50h
    0xFFAE4A00: [0x09C0, 0x0029],                         # create_fx(29h) - subway_rox
    0xFFB3B6D0: [0x0B20, 0xB760, 0xFFB3],                 # create_fx's table FFB3B760
    0xFFB400D0: [0x09C0, 0x0000],                         # tsound 0 - explode thru floor
    0xFFB40120: [0x09C0, 0x0001],                         # tsound 1 - explode thru floor
    0xFFB40170: [0x09EB, 0x0010, 0x000A],                 # MOVI A0010h,A11 - shake
    0xFFB401D0: [0x1940],                                 # MOVK Ah - 10 small
    0xFFB401F0: [0x09EB, 0x12D0, 0xFFB5],                 # a_small_rock
    0xFFB40240: [0x1900],                                 # MOVK 8h - 8 medium
    0xFFB40260: [0x09EB, 0x1490, 0xFFB5],                 # a_med_rock
    0xFFB402B0: [0x1880],                                 # MOVK 4h - 4 large
    0xFFB402D0: [0x09EB, 0x1650, 0xFFB5],                 # a_large_rock
    0xFFB40540: [0x09C0, 0x0008],                         # randu 8 - start delay
    0xFFB405F0: [0x18A0],                                 # randu_minimum 5,5
    0xFFB40650: [0x0BE5, 0xFFEF],                         # SUBI 10h - the landing line
    0xFFB40690: [0x09E0, 0x0000, 0x0002],                 # srand 20000h - x vel
    0xFFB40710: [0x09CB, 0x4000],                         # gravity 4000h
    0xFFB40730: [0x188A],                                 # MOVK 4h,A10 - the fall's rate
    0xFFB50510: [0x09E0, 0x0000, 0x0002, 0x09E1, 0x0000, 0x0002],   # bounce 20000h,20000h
    0xFFB50B30: [0x09C2, 0x4000, 0x1843],                 # bounce grav 4000h, ani speed 2
    0xFFB50610: [0x09E9, 0x1810, 0xFFB5, 0x1860],         # a_crumple, framew 3
}
LAVA_X, LAVA_XMIN, LAVA_MID = 0x80, 0x80, 0xC7
LAVA_YVEL, LAVA_GRAV, LAVA_Y = 0x20000, 0x6000, 0xB2
LAVA_UP, LAVA_UPH, LAVA_WAIT = 0x100000, 0x100, 0x50
LAVA_SHAKE, LAVA_SND, HIT_RATE, FLAME_RATE = (4, 6), 0x5F, 5, 4
LAVA_SCALE = 0x1C0                # the PSX port's shrunk body (oscale 1C0h)
# WHERE HIS FEET STOP - the lava SURFACE, measured off the stage at camera 400:
# the bright sea is rows ~198-212 and the floor rock starts at ~213. UMK3
# stops the fall on the body's TOP at B2h, which is right for its small tumble
# sprites; a full-size MK2 fighter, even at 1C0h, put his feet (and so the
# splash's base) at y 265, off the bottom of the screen on the floor rock
# (playtest 2026-10-13: "way off base"). So the fall stops on his BOTTOM here.
LAVA_SURF = 200

SHADOW_FAST = 2
PAL_PREFIX = "LAIR_P"
FLAME_PAL, HIT_PAL = "LAIRFLM_P", "LAIRHIT_P"
PLANE_NOTE = {                    # each plane rendered alone (tmp/umk3lair/planes.png)
    1: "the great skull and the nearest bone pillars",
    2: "the bone pillars",
    4: "the bone pillars further off",
    5: "the burning pillars far off",
    6: "the arches over the lava sea - rate 0",
}


class R(umk3rom.UMK3):
    pass


# --------------------------------------------------------------------------
def blocks(rom, mod):
    out, q = [], rom.l(mod + 48)
    while rom.w(q) != 0xFFFF:
        out.append(tuple(rom.w(q + 16 * k) for k in range(4)))
        q += 64
    return out


def read_umk3(rom):
    for at, words in CODE_CHECKS.items():
        if [rom.w(at + 16 * i) for i in range(len(words))] != words:
            raise SystemExit(f"UMK3 code at {at:08X} is not what this import was read from")
    rec = dict(erase=rom.w(REC), worldy=rom.sw(REC + 16), ground=rom.w(REC + 32),
               start=rom.w(REC + 48), left=rom.w(REC + 64), right=rom.w(REC + 80),
               calla=rom.l(REC + 96), scroll=rom.l(REC + 128), dlists=rom.l(REC + 160))
    if (rec["calla"], rec["scroll"], rec["dlists"]) != (CALLA, SCROLL, DLISTS):
        raise SystemExit("UMK3 hell record's pointers moved")
    mods, a, plane = [], REC + 224, 1
    while True:
        v = rom.l(a)
        if v == 1:                                   # skip_bakmod
            plane += 1
            a += 32
            continue
        if v in (0xFFFFFFFE, 0xFFFFFFFF):
            break
        mods.append(dict(addr=v, w=rom.w(v), h=rom.w(v + 16), n=rom.w(v + 32),
                         hdrs=rom.l(v + 80), pals=rom.l(v + 112), blks=blocks(rom, v),
                         x=rom.sw(a + 32), y=rom.sw(a + 48), plane=plane))
        plane += 1
        a += 64
    if [m["plane"] for m in mods] != [1, 2, 4, 5, 6]:
        raise SystemExit(f"hell's planes are {[m['plane'] for m in mods]}, not 1,2,4,5,6")
    centred = []
    if rom.l(a) == 0xFFFFFFFE:
        a += 32
        while (m := rom.l(a)) != 0:
            centred.append(next(md["plane"] for md in mods if md["addr"] == m))
            a += 64
        a += 32
    rec["centred"] = centred
    rec["floor"] = dict(sag=rom.l(a), pal=rom.l(a + 32), height=rom.w(a + 64))
    for md in mods:
        md["rate"] = rom.l(SCROLL + 32 * (8 - md["plane"]))
        if len(md["blks"]) != md["n"]:
            raise SystemExit(f"UMK3 module {md['addr']:08X}: block count disagrees")
    return rec, mods


def art(rom, mods):
    hd, pl = mods[0]["hdrs"], mods[0]["pals"]
    if any((m["hdrs"], m["pals"]) != (hd, pl) for m in mods):
        raise SystemExit("hell's modules no longer share one header table")
    order = sorted({b[3] & 0xFFF for m in mods for b in m["blks"]})
    imgs = {}
    for i in order:
        a = hd + 80 * i
        w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
        rows, _ = pit.decode_record(rom.g, sag, w, h, ctrl)
        imgs[i] = dict(idx=i, w=w, h=h, big=0, px=bytes(v for r in rows for v in r), mk_sag=sag)
    share, first = {}, {}
    for i in order:
        k = imgs[i]["mk_sag"]
        if k in first:
            share[i] = first[k]
        else:
            first[k] = i
    uniq = [i for i in order if i not in share]
    used = sorted({thr.pal_of(b) for m in mods for b in m["blks"]})
    remap = {p: k for k, p in enumerate(used)}
    pals = [(f"{PAL_PREFIX}{k:02d}", rom.palette(rom.l(pl + 32 * p)), p) for k, p in enumerate(used)]
    return imgs, order, uniq, pals, remap, share


def rec_image(rom, a, pal=None):
    w, h, ax, ay, sag, ctrl = (rom.w(a), rom.w(a + 16), rom.sw(a + 32), rom.sw(a + 48),
                               rom.l(a + 64), rom.w(a + 96))
    rows, _ = pit.decode_record(rom.g, sag, w, h, ctrl)
    return dict(w=w, h=h, ax=ax, ay=ay, px=bytes(v for r in rows for v in r))


def anim_list(rom, lst):
    out, k = [], 0
    while (v := rom.l(lst + 32 * k)) != 0:
        out.append(v)
        k += 1
    return out


def sprites(rom):
    """The flames (create_dumb_animators' table) and the lava splash."""
    flames, t = [], ANIM_TAB
    while (rate := rom.w(t)) != 0:
        first, x, y, lst, blst = rom.l(t + 16), rom.w(t + 48), rom.w(t + 64), rom.l(t + 80), rom.l(t + 112)
        if lst != FLAME_LIST or rate != FLAME_RATE or anim_list(rom, lst)[0] != first:
            raise SystemExit("the hell flames' animator table changed")
        # The table's x is NOT the plane-2 world x: MK3's create_dumb_animators
        # places the object relative to the STARTING camera, i.e. table x +
        # the record's start x (190h).  MEASURED in retail UMK3
        # (tools/umk3_stage_sweep.lua, HELLFLAME template-matched at error 0-9):
        # the two flames burn at plane-2 x 532 and 1037, in the holes in the
        # skeleton columns - not 132 and 637, where the raw table x hung one in
        # empty air at the left edge and left the holes empty.
        flames.append((x + rom.w(REC + 48), y))
        t += 144
    frecs = anim_list(rom, FLAME_LIST)
    hrecs = anim_list(rom, HIT_LIST)
    fpal = rom.palette(rom.l(frecs[0] + 112))
    hpal = rom.palette(rom.l(hrecs[0] + 112))
    recs = {}
    for k, a in enumerate(frecs):
        recs[f"HELLFLAME{k + 1}"] = (rec_image(rom, a), FLAME_PAL)
    for k, a in enumerate(hrecs):
        recs[f"HELLHIT{k + 1}"] = (rec_image(rom, a), HIT_PAL)
    spals = {FLAME_PAL: fpal, HIT_PAL: hpal}
    if rom.l(0xFFB3B760 + 32 * 0x29) != ROX_FX:
        raise SystemExit("create_fx 29h is not subway_rox (FFB400C0)")
    rox = {}
    for pre, lst in [(g[0], g[1]) for g in ROX_GROUPS] + [ROX_CRUMBLE]:
        frames, k = [], 0
        while (v := rom.l(lst + 32 * k)) not in (0, 1):     # 1 = ani_jump (the rocks loop)
            frames.append(v)
            k += 1
        if len(frames) != 12:
            raise SystemExit(f"UMK3 list {lst:08X} has {len(frames)} frames, not 12")
        pa = rom.l(frames[0] + 112)
        if pa not in (0xFFDD7C00, 0xFFDD7E00):
            raise SystemExit(f"UMK3 list {lst:08X}: palette {pa:08X} is not one of the rocks' two")
        pname = f"LAIRRK{'1' if pa == 0xFFDD7C00 else '2'}_P"
        spals[pname] = rom.palette(pa)
        rox[pre] = []
        for i, a in enumerate(frames):
            nm = f"{pre}{i + 1:02d}"
            recs[nm] = (rec_image(rom, a), pname)
            rox[pre].append(nm)
    for nm, (im, p) in recs.items():
        n = len(spals[p])
        if max(im["px"]) >= n:
            raise SystemExit(f"{nm} indexes {max(im['px'])}, {p} has {n}")
    return flames, recs, spals, len(frecs), len(hrecs), rox


def layout():
    rom = R()
    rec, mods = read_umk3(rom)
    imgs, order, uniq, pals, remap, share = art(rom, mods)
    flames, recs, spals, nfl, nhit, rox = sprites(rom)
    fl = rec["floor"]
    # MK3's setup_floor_info adds 02000000h to the record's SAG (MKBT.ASM)
    fb = (fl["sag"] + 0x2000000) >> 3
    floor = bytes(rom.g[fb:fb + FLOOR_W * fl["height"] * 6 // 8])
    return dict(rom=rom, rec=rec, mods=mods, imgs=imgs, order=order, uniq=uniq, pals=pals,
                remap=remap, share=share, flames=flames, sprites=recs, spals=spals,
                nflame=nfl, nhit=nhit, rox=rox, floor=floor, floorpal=rom.palette(fl["pal"]))


def rec_scroll(L, plane):
    return L["rom"].l(SCROLL + 32 * (8 - plane)) if 0 <= plane <= 8 else 0


# --------------------------------------------------------------------------
def deal(L):
    imgs = L["imgs"]
    cap = [int((e - s) * 8 * PACK_MARGIN) for _n, s, e, _p in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(L["uniq"], key=lambda i: (-cave.packed_bits(imgs[i]), i)):
        im = imgs[idx]
        want = 8 if court.wide_tail(im) else 0
        bits = im["w"] * im["h"] * 8 if want else cave.packed_bits(im)
        for k, (_n, _s, _e, ppp) in enumerate(PACKS):
            if ppp == want and used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    return [sorted(g) for g in got], used


def rox_order(L):
    return [nm for pre in [g[0] for g in ROX_GROUPS] + [ROX_CRUMBLE[0]] for nm in L["rox"][pre]]


def spr_order(L):
    return [f"HELLFLAME{k + 1}" for k in range(L["nflame"])] + \
           [f"HELLHIT{k + 1}" for k in range(L["nhit"])]


LOD_SPR = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  SCORPION'S LAIR (UMK3), WOLF ONLY - the lava flames and the lava
;  splash (linear 0x{start:06X}..0x{end:06X})
;
;  data/UMK3LRMK.IMG is GENERATED by tools/make_umk3lair.py --parts
;  out of umk3.zip: HELLFLAME1-6 (FF952EF0) and HELLHIT1-8 (FFA81C70),
;  with their anipoints and their own palettes (src/UMK3LRB.ASM).
;  PON>: built with gso_dmawnz, which reads the palette off the record.
;
;**************************************************************
PON>
ZON>
PPP> {ppp}
ASM> UMK3LRM.TBL
UMK3LRMK.IMG
{recs}
"""

LOD_ROX = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  SCORPION'S LAIR (UMK3), WOLF ONLY - the ceiling coming down: the
;  cave rocks and their crumble (linear 0x{start:06X}..0x{end:06X})
;
;  data/UMK3LRMK.IMG is GENERATED by tools/make_umk3lair.py --parts
;  out of umk3.zip: subway_rox's three rock lanes (FFB512D0, FFB51490,
;  FFB51650) and land_subway_rock's crumble (FFB51810), 12 frames
;  each, on their own two palettes (src/UMK3LRB.ASM).  PON>: built
;  with gso_dmawnz, which reads the palette off the record.  5bpp -
;  both palettes have 31-32 entries.
;
;**************************************************************
PON>
ZON>
PPP> {ppp}
ASM> LAIRRX.TBL
UMK3LRMK.IMG
{recs}
"""

LOD_FLOOR = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  SCORPION'S LAIR (UMK3), WOLF ONLY - skew floor (linear
;  0x{start:06X}..0x{end:06X})
;
;  FL_HELL.BIN is UMK3's own floor, copied out of
;  deadlythirdcombat-main/BINFILES and proven byte-identical to what
;  umk3.zip carries at its SAG: 1200x46 raw 6bpp, the shape MKDISP's
;  floor_code draws.  ZOF> - floor_code reads raw rows (THE CAVE's
;  data/CAVEFLR.LOD is the same shape).
;
;**************************************************************
ZOF>
POF>
PPP> 6
ASM> LAIRFL.TBL
FRM> FL_HELL
"""


def part_files(L):
    imgs = L["imgs"]
    groups, _ = deal(L)
    files = {}
    lod = court.LOD_BBB.replace("THE COURTYARD (MK1)", "SCORPION'S LAIR (UMK3)") \
        .replace("make_mk1court.py", "make_umk3lair.py") \
        .replace("C:\\\\MAME\\\\roms\\\\mk.zip - MK1's stage record FFCBB410.", "umk3.zip - UMK3's stage record FF952560.") \
        .replace(";  The leak's KUNGFU2 is a pre-release Courtyard, not this one.\n", "") \
        .replace("(src/MK1CRTB.ASM)", "(src/UMK3LRB.ASM)")
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
               "LOAD2's auto depth ignores a block's LAST pixel; these need more bits there")
        files[f"{name}.LOD"] = lod.format(addr=court.lod_addr(s), n=name[-1], start=s, end=e,
                                          name=name, ppp=ppp, why=why).encode()
    names = spr_order(L)
    rnames = rox_order(L)
    pnames = list(L["spals"])
    entries = [(nm, L["sprites"][nm][0]["ax"], L["sprites"][nm][0]["ay"], L["sprites"][nm][0]["w"],
                L["sprites"][nm][0]["h"], L["sprites"][nm][0]["px"], pnames.index(L["sprites"][nm][1]))
               for nm in names + rnames]
    pl = [(p, cave._bpp(len(L["spals"][p]) - 1), L["spals"][p]) for p in pnames]
    files[SPR_IMG.name] = pit.build_img(entries, pl)
    name, s, e = SPR_PACK
    files[f"{name}.LOD"] = LOD_SPR.format(
        addr=court.lod_addr(s), start=s, end=e, ppp=SPR_PPP,
        recs=chr(10).join("---> " + ",".join(names[i:i + 8]) for i in range(0, len(names), 8))).encode()
    name, s, e = ROX_PACK
    files[f"{name}.LOD"] = LOD_ROX.format(
        addr=court.lod_addr(s), start=s, end=e, ppp=ROX_PPP,
        recs=chr(10).join("---> " + ",".join(rnames[i:i + 8]) for i in range(0, len(rnames), 8))).encode()
    name, s, e = FLOOR_PACK
    files[f"{name}.LOD"] = LOD_FLOOR.format(addr=court.lod_addr(s), start=s, end=e).encode()
    # ONE GUARD ROW after the last: the skew floor starts each line further
    # into its row as the camera goes right, so the far end of a line reads
    # on into the NEXT row - and after the last row that was whatever the ROM
    # held next, a yellow dash along the bottom-right of the screen at the
    # right scroll limit (reported 2026-10-08).  The last row again is what
    # the eye expects there.
    row = FLOOR_W * 6 // 8
    files[FLOOR_BIN.name] = L["floor"] + L["floor"][-row:]
    files["LAIRWALL.BIN"] = wall_bin(L) + base_bin(base_bands(L))
    name, s, e = WALL_PACK
    if s + len(files["LAIRWALL.BIN"]) > e:
        raise SystemExit("the tower-foot bands overrun their slot")
    files[f"{name}.LOD"] = LOD_WALL.format(addr=court.lod_addr(s), start=s).encode()
    return files


def plane_texture(L, plane):
    """A plane composited the way the game draws it: z (flip bit masked), then
    y, ties in REVERSE file order - the runtime order make_arnsky_bin.py
    measured for the arena - later blocks over earlier.  Block bit 10h is an
    h-flip.  Returns (rows of indices, rows of palette index, module)."""
    md = next(m for m in L["mods"] if m["plane"] == plane)
    tex = [[0] * md["w"] for _ in range(md["h"])]
    pal = [[-1] * md["w"] for _ in range(md["h"])]
    order = sorted(range(len(md["blks"])),
                   key=lambda i: (md["blks"][i][0] & ~0x10, md["blks"][i][2], -i))
    for i in order:
        f, x, y, hd = md["blks"][i]
        im = L["imgs"][hd & 0xFFF]
        np = L["remap"][thr.pal_of(md["blks"][i])]
        for r in range(im["h"]):
            ty = y + r
            if not 0 <= ty < md["h"]:
                continue
            for c in range(im["w"]):
                v = im["px"][r * im["w"] + (im["w"] - 1 - c if f & 0x10 else c)]
                tx = x + c
                if v and 0 <= tx < md["w"]:
                    tex[ty][tx] = v
                    pal[ty][tx] = np
    return tex, pal, md


def base_bands(L):
    """The foot of each tower plane: [(plane, module, first row, rows of
    indices, palette label)], back first.  A band must be one palette and fit
    6 bits - a line is one blit and a blit carries one colour map."""
    out = []
    for plane in BASE_PLANES:
        tex, pal, md = plane_texture(L, plane)
        last = max(r for r in range(md["h"]) if any(tex[r]))
        first = last - BASE_ROWS + 1
        rows = tex[first:last + 1]
        used = {p for r in pal[first:last + 1] for p in r if p >= 0}
        if len(used) != 1:
            raise SystemExit(f"plane {plane}: the foot band is on palettes {sorted(used)} - one layer needs one")
        if max(max(r) for r in rows) >= 64:
            raise SystemExit(f"plane {plane}: the foot band needs more than 6bpp")
        out.append((plane, md, first, rows, L["pals"][used.pop()][0]))
    return out


def wall_band(L):
    """The arches (plane 6): the WALL_ROWS rows above the lava glow.
    (rows of indices, palette label, module, world y of the first row)"""
    tex, pal, md = plane_texture(L, 6)
    y0 = md["y"] + L["rec"]["worldy"]
    last = min(len(tex), WALL_STILL_FROM - y0)
    first = last - WALL_ROWS
    rows = tex[first:last]
    used = {p for r in pal[first:last] for p in r if p >= 0}
    if len(used) != 1 or max(max(r) for r in rows) >= 64:
        raise SystemExit("the arches band needs one palette and 6bpp")
    return rows, L["pals"][used.pop()][0], md, y0 + first


def wall_bin(L):
    """First in data/LAIRWALL.BIN, padded to a 32-bit boundary; the tower
    bands follow it."""
    import make_arnsky_bin as arn
    out = arn.pack(wall_band(L)[0])
    return out + bytes(-len(out) % 4)


def tiers_for(rows, thin, both):
    """Fine wave only; every other row for the first `thin`, both waves on the
    last `both`."""
    t = [2 if (k >= thin or k % 2) else 0 for k in range(rows)]
    for k in range(rows - both, rows):
        t[k] = 3
    return t


def base_bin(bands):
    """The bands one after another, each starting on a 32-bit boundary."""
    import make_arnsky_bin as arn
    out = bytearray()
    for _p, _md, _f, rows, _pal in bands:
        out += arn.pack(rows)
        out += bytes(-len(out) % 4)
    return bytes(out)


# --------------------------------------------------------------------------
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
            if (w, h) != (imgs[idx]["w"], imgs[idx]["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} outside {start:X}..{end:X}")
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
    for i, j in L["share"].items():
        w, h, addr, ctrl, src = by[j]
        by[i] = (w, h, addr, ctrl, f"{src} (UMK3 shares one SAG with {j:02X})")
    return [by[i] for i in L["order"]]


def tbl_sets(path, pat):
    import re
    if not path.exists():
        raise SystemExit(f"{path} missing - run python build.py")
    return path.read_text(encoding="latin-1"), re


def spr_tbl():
    out = {}
    for path in (SPR_TBL, ROX_TBL):
        out.update(_spr_tbl(path))
    return out


def _spr_tbl(path):
    text, _re = tbl_sets(path, None)
    out, lines = {}, text.splitlines()
    for i, ln in enumerate(lines):
        t = ln.strip()
        if t.endswith(":") and (t.startswith("HELL") or t.startswith("LRK")):
            w, h, _ax, _ay = (int(v, 0) for v in lines[i + 1].split(None, 1)[1].split(","))
            out[t[:-1]] = (w, h, int(lines[i + 2].split()[1].rstrip("Hh"), 16),
                           int(lines[i + 3].split()[1].rstrip("Hh"), 16))
    return out


def floor_sag():
    text, re = tbl_sets(LOAD2 / "LAIRFL.TBL", None)
    m = re.search(r"^FL_HELL\s+\.set\s+0?([0-9A-Fa-f]+)[hH]", text, re.M)
    if not m:
        raise SystemExit("tmp/load2/LAIRFL.TBL: no FL_HELL")
    return int(m.group(1), 16)


def decode_at(addr, w, h, ctrl):
    p = cave.sag_phys(addr)
    for name, *_r in PACKS + [SPR_PACK, ROX_PACK, FLOOR_PACK]:
        if not (DATA / f"{name}.IRW").exists():
            continue
        start, payload = court.wolf_irw(name)
        if start <= p < start + len(payload):
            rows, _b = pit.decode_record(payload, pit.runtime_bit(addr) - start * 8, w, h, ctrl)
            return name, bytes(v for r in rows for v in r)
    raise SystemExit(f"SAG {addr:08X} (linear {p:X}) is in no written Wolf pack")


def verify_rom(L, hdrs):
    bad = []
    for idx, (w, h, addr, ctrl, src) in zip(L["order"], hdrs):
        try:
            name, px = decode_at(addr, w, h, ctrl)
        except IndexError:
            bad.append(f"UMK3 {idx:02X} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, L["imgs"][idx]["px"]) if a != b)
        if n:
            bad.append(f"{name}: UMK3 {idx:02X} ({src}) - {n} pixels differ from umk3.zip")
    tbl = spr_tbl()
    for nm, (im, _p) in L["sprites"].items():
        if nm not in tbl:
            bad.append(f"{nm} is not in {SPR_TBL.name}")
            continue
        w, h, sag, ctrl = tbl[nm]
        try:
            name, px = decode_at(sag, w, h, ctrl)
        except IndexError:
            bad.append(f"{nm} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, im["px"]) if a != b)
        if (w, h) != (im["w"], im["h"]) or n:
            bad.append(f"{name}: {nm} - {n} pixels differ from umk3.zip")
    fs = floor_sag()
    start, payload = court.wolf_irw(FLOOR_PACK[0])
    o = cave.set_phys(fs) - start          # a FRM> .set is LOD form (02000000h low)
    if payload[o:o + len(L["floor"])] != L["floor"]:
        bad.append("FL_HELL in the pack is not umk3.zip's floor")
    return bad, fs


def build_asm(L, hdrs, fsag):
    rec, mods = L["rec"], L["mods"]
    h4 = court.h4
    o = []
    w = o.append
    w("; SCORPION'S LAIR (UMK3) - GENERATED by tools/make_umk3lair.py --apply.  Do not hand-edit.")
    w("; Art and layout: UMK3's stage record FF952560 (C:\\MAME\\roms\\umk3.zip), read by the tool.")
    w("; Included only under .if wunit (src/UMK3LAIR.ASM) - Wolf-only art.")
    w("")
    for k, v, note in (("erase", h4(rec["erase"]), ""), ("ground", rec["ground"] - GROUND_LIFT, ""),
                       ("worldy", rec["worldy"], ""), ("start", rec["start"], ""),
                       ("left", rec["left"], ""), ("right", rec["right"], ""),
                       ("shad_fast", SHADOW_FAST, "")):
        w(f"lair_{k}\t.set\t{v}")
    for e in range(9):
        w(f"lair_rate{e}\t.set\t{h4(rec_scroll(L, e), 6)}\t\t; plane {e}"
          + (f" - {PLANE_NOTE[e]}" if e in PLANE_NOTE else ""))
    for md in mods:
        n = md["plane"]
        w(f"lair_m{n}_x\t.set\t{md['x'] + EDGE_SHIFT.get(n, 0)}\t\t; plane {n} - {PLANE_NOTE[n]}")
        w(f"lair_m{n}_y\t.set\t{md['y']}")
    fl = rec["floor"]
    w(f"FL_HELL\t\t.set\t{h4(fsag, 8)}\t; tmp/load2/LAIRFL.TBL")
    w(f"lair_fl_h\t.set\t{fl['height']}")
    w(f"lair_fl_y\t.set\t{254 + rec['worldy'] - fl['height']}\t\t; MK3's setup_floor_info: "
      "worldy + 254 - height")
    w(f"lair_flm_rate\t.set\t{FLAME_RATE}")
    w(f"lair_flm_n\t.set\t{L['nflame']}")
    for k, (x, y) in enumerate(L["flames"]):
        w(f"lair_flm{k}_x\t.set\t{h4(x)}")
        w(f"lair_flm{k}_y\t.set\t{h4(y)}")
    for k, v in (("lava_x", h4(LAVA_X)), ("lava_xmin", h4(LAVA_XMIN)), ("lava_mid", h4(LAVA_MID)),
                 ("lava_yvel", h4(LAVA_YVEL, 6)), ("lava_grav", h4(LAVA_GRAV)),
                 ("lava_y", h4(LAVA_Y)), ("lava_up", h4(LAVA_UP, 6)), ("lava_uph", h4(LAVA_UPH)),
                 ("lava_wait", h4(LAVA_WAIT)), ("lava_shk", h4((LAVA_SHAKE[0] << 16) | LAVA_SHAKE[1], 8)),
                 ("lava_snd", h4(LAVA_SND)), ("lava_hrate", HIT_RATE), ("lava_hn", L["nhit"]),
                 ("lava_scale", h4(LAVA_SCALE)), ("lava_surf", LAVA_SURF)):
        w(f"lair_{k}\t.set\t{v}")
    w("; the ceiling coming down - subway_rox (FFB400C0), MK3 MKFX.ASM's numbers")
    for k, v in (("rox_shk", h4(ROX_SHAKE, 8)), ("rox_grav", h4(ROX_GRAV)),
                 ("rox_xvel", h4(ROX_XVEL, 6)), ("rox_bounce", h4(ROX_BOUNCE, 6)),
                 ("rox_frate", ROX_FALL_RATE), ("rox_brate", ROX_BOUNCE_RATE),
                 ("rox_crate", ROX_CRUMBLE_RATE), ("rox_delay", ROX_DELAY),
                 ("rox_gmin", ROX_GND_MIN), ("rox_grange", ROX_GND_RANGE), ("rox_gup", h4(ROX_GND_UP)),
                 ("rox_ns", ROX_GROUPS[0][2]), ("rox_nm", ROX_GROUPS[1][2]), ("rox_nl", ROX_GROUPS[2][2])):
        w(f"lair_{k}\t.set\t{v}")
    w("")
    w("\t.data")
    w("")
    w("LAIRHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["order"]):
        w(f"\t.word\t{hw},{hh}\t\t; UMK3 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["order"])}
    for md in mods:
        lab = "LAIR%d" % md["plane"]
        w(f"{lab}BLKS:\t\t\t\t; {PLANE_NOTE[md['plane']]}")
        for blk in md["blks"]:
            f, bx, by, hw = blk
            np = L["remap"][thr.pal_of(blk)]
            w("\t.word\t%s,%d,%d,%s" % (h4((f & 0xFFF0) | (np & 0xF)), bx, by,
                                        h4(hidx[hw & 0xFFF] + ((np >> 4) << 12))))
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{md['w']},{md['h']},{len(md['blks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, LAIRHDRS, LAIRPALS")
        w("")
    w("LAIRPALS:")
    for label, _words, p in L["pals"]:
        w(f"\t.long\t{label}\t\t; UMK3 palette {p}")
    w("")
    allp = [(lb, wd) for lb, wd, _p in L["pals"]] + list(L["spals"].items()) + [("LAIRFL_P", L["floorpal"])]
    for label, words in allp:
        w(f"{label}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    w("")
    w("lair_flames:\t\t\t; FF952EF0, in order")
    for k in range(L["nflame"]):
        w(f"\t.long\tHELLFLAME{k + 1}")
    w("\t.long\t0")
    for (pre, lst, _n), lab in zip(ROX_GROUPS, ("lair_rox_s", "lair_rox_m", "lair_rox_l")):
        w(f"{lab}:\t\t\t; {lst:08X} - spins until it lands")
        for nm in L["rox"][pre]:
            w(f"\t.long\t{nm}")
        w(f"\t.long\tani_jump,{lab}")
    w(f"lair_rox_c:\t\t\t; {ROX_CRUMBLE[1]:08X} - the crumble, then the rock is gone")
    for nm in L["rox"][ROX_CRUMBLE[0]]:
        w(f"\t.long\t{nm}")
    w("\t.long\t0")
    w("lair_hits:\t\t\t; FFA81C70, in order")
    for k in range(L["nhit"]):
        w(f"\t.long\tHELLHIT{k + 1}")
    w("\t.long\t0")
    w("")
    w("; THE HEAT HAZE: the arches (plane 6, sky_rows draws the plane) and the")
    w("; foot of each tower plane (sky_rows_over draws a band over the plane),")
    w("; all out of data/LAIRWALL.BIN.  Subtle: the fine wave alone, thinned at")
    w("; the top; the lava glow under the arches is still.")
    import make_arnsky_bin as arn
    wrows, wpl, wmd, wy0 = wall_band(L)
    w("lair_wall_rows:\t\t\t; plane 6 - the arches, the very background")
    w("\t.long\tLAIRWALL+02000000h\t; bank 1: SAG = LOD base + 2000000h")
    w(f"\t.word\t{wmd['w']},{wmd['x'] + EDGE_SHIFT.get(6, 0)}\t\t; width, world x of column 0")
    w("\t.long\tlair_wall_haze")
    w("\t.word\t1")
    w(f"\t.long\t{wpl}")
    w("\t.long\t0")
    w(f"\t.word\t{len(wrows)},{wy0}\t\t; rows, world y of the first")
    w("lair_wall_haze:")
    w(f"\t.word\t{wy0},{len(wrows)}")
    w("\t.word\t" + ",".join(str(t) for t in tiers_for(len(wrows), WALL_THIN, 0)))
    off = len(wall_bin(L))
    for plane, md, first, rows, pal in base_bands(L):
        y0 = md["y"] + rec["worldy"] + first
        w(f"lair_base{plane}_rows:\t\t\t; plane {plane} - {PLANE_NOTE[plane]}")
        w("\t.long\tLAIRWALL+02000000h\t; bank 1: SAG = LOD base + 2000000h")
        w(f"\t.word\t{md['w']},{md['x']}\t\t; width, world x of column 0")
        w(f"\t.long\tlair_base{plane}_haze")
        w("\t.word\t1")
        w(f"\t.long\t{pal}")
        w(f"\t.long\t{off * 8}\t\t; bits to this band's first row")
        w(f"\t.word\t{len(rows)},{y0}\t\t; rows, world y of the first")
        w(f"lair_base{plane}_haze:")
        w(f"\t.word\t{y0},{len(rows)}")
        tiers = tiers_for(len(rows), BASE_THIN, BASE_BOTH)
        w("\t.word\t" + ",".join(str(t) for t in tiers))
        n = len(arn.pack(rows))
        off += n + (-n % 4)
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------
def plane_x(L, cam):
    """Every plane's worldtlx at a plane-1 camera of `cam`: init_bakmods
    seeds the start x, then center_x puts each listed plane on (w/2 - 200)."""
    s = L["rec"]["start"]
    out = {}
    for e in range(9):
        base = s
        md = next((m for m in L["mods"] if m["plane"] == e), None)
        if md and e in L["rec"]["centred"]:
            base = md["w"] // 2 - 399 // 2      # center_x: scrrgt/2, not 200
        out[e] = base + (cam - s) * rec_scroll(L, e) // 0x20000
    return out


def render(L, cam, planes=None):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    px_x = plane_x(L, cam)
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), court.rgb(rec["erase"]))
    px = scr.load()

    def put(im, ox, oy, pal, flip=False):
        w, h = im["w"], im["h"]
        for y in range(h):
            ty = oy + y
            if not 0 <= ty < SCREEN_H:
                continue
            row = im["px"][y * w:(y + 1) * w]
            for x in range(w):
                tx = ox + x
                if 0 <= tx < SCREEN_W:
                    v = row[w - 1 - x] if flip else row[x]
                    if v:
                        px[tx, ty] = court.rgb(pal[v])

    show = planes or set(range(1, 9)) | {"floor", "flames"}

    def plane(p):
        if p not in show:
            return
        md = next((m for m in L["mods"] if m["plane"] == p), None)
        if md is None:
            return
        for blk in sorted(md["blks"], key=lambda b: b[0] & 0xFFF0):
            f, bx, by, hw = blk
            put(L["imgs"][hw & 0xFFF], md["x"] + EDGE_SHIFT.get(p, 0) + bx - px_x[p], md["y"] + by - rec["worldy"],
                L["pals"][L["remap"][thr.pal_of(blk)]][1], bool(f & 0x10))

    for p in (6, 5, 4):
        plane(p)
    if "flames" in show:
        im, _ = L["sprites"]["HELLFLAME1"]
        for x, y in L["flames"]:
            put(im, x - im["ax"] - px_x[2], y - im["ay"] - rec["worldy"], L["spals"][FLAME_PAL])
    plane(2)
    if "floor" in show:
        fl, h = L["floor"], rec["floor"]["height"]
        y0 = 254 + rec["worldy"] - h - rec["worldy"]
        bits = int.from_bytes(fl, "little")
        cx = px_x[1] - rec["start"] + (FLOOR_W - SCREEN_W) // 2
        for r in range(h):
            for x in range(SCREEN_W):
                c = (x + cx) % FLOOR_W
                v = (bits >> (6 * (r * FLOOR_W + c))) & 63
                if v and 0 <= y0 + r < SCREEN_H:
                    px[x, y0 + r] = court.rgb(L["floorpal"][v])
    plane(1)
    if planes is None:
        gy = rec["ground"] - rec["worldy"]
        ImageDraw.Draw(scr).line([(0, gy), (SCREEN_W - 1, gy)], fill=(255, 0, 0))
    return scr


def preview(L, cams):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cams = cams or [rec["left"], rec["start"], rec["right"]]
    out = ROOT / "tmp" / "umk3lair"
    out.mkdir(parents=True, exist_ok=True)
    shots = [(c, render(L, c)) for c in cams]
    sheet = Image.new("RGB", (SCREEN_W, (SCREEN_H + 12) * len(shots)), (16, 16, 20))
    dr = ImageDraw.Draw(sheet)
    for k, (c, im) in enumerate(shots):
        sheet.paste(im, (0, k * (SCREEN_H + 12)))
        dr.text((4, k * (SCREEN_H + 12) + 2), "camera %d" % c, fill=(255, 255, 0))
    sheet.save(out / "preview.png")
    pl = Image.new("RGB", (SCREEN_W * 3, SCREEN_H * 2))
    for k, p in enumerate([1, 2, 4, 5, 6, "floor"]):
        pl.paste(render(L, rec["start"], planes={p}), ((k % 3) * SCREEN_W, (k // 3) * SCREEN_H))
    pl.save(out / "planes.png")
    print(f"wrote {out / 'preview.png'} and planes.png")


def report(L):
    rec = L["rec"]
    print(f"SCORPION'S LAIR (UMK3) - record {REC:08X}  (Wolf only)")
    print(f"  erase {rec['erase']:04X} ground {rec['ground']} world y {rec['worldy']} start "
          f"{rec['start']} limits {rec['left']}..{rec['right']}  centred planes {rec['centred']}")
    for md in L["mods"]:
        print(f"    plane {md['plane']}  {md['w']:5d}x{md['h']:<4d} at ({md['x']:4d},{md['y']:4d})  "
              f"rate {md['rate']:06X}  {len(md['blks'])} blocks")
    print(f"  art: {len(L['order'])} headers, {len(L['uniq'])} payloads, {len(L['pals'])} palettes")
    groups, used = deal(L)
    for (name, s, e, ppp), g, u in zip(PACKS, groups, used):
        print(f"  {name} PPP>{ppp} {s:06X}..{e:06X}: {len(g)} images ~{u // 8:,} B")
    print(f"  floor {rec['floor']['sag']:08X} h {rec['floor']['height']}, "
          f"{len(L['floor']):,} B, == BINFILES: {FLOOR_SRC.exists() and FLOOR_SRC.read_bytes() == L['floor']}")
    print(f"  flames {L['flames']} x {L['nflame']} frames; splash {L['nhit']} frames")


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
    if a.parts:
        for nm, data in files.items():
            (DATA / nm).write_bytes(data)
            print(f"wrote data/{nm}  ({len(data):,} bytes)")
    asm = None
    if a.apply or a.check:
        hdrs = merged_headers(L)
        bad, fs = verify_rom(L, hdrs)
        if bad:
            raise SystemExit("SCORPION'S LAIR's art is not UMK3's:\n  " + "\n  ".join(bad))
        asm = build_asm(L, hdrs, fs)
        if a.apply:
            OUT_ASM.write_text(asm, encoding="latin-1")
            print(f"wrote {OUT_ASM.relative_to(ROOT)}  ({len(asm.splitlines())} lines)")
    if a.check:
        drift = [f"data/{nm} is not the tool's - rerun --parts" for nm, data in files.items()
                 if not (DATA / nm).exists() or (DATA / nm).read_bytes() != data]
        if not OUT_ASM.exists() or OUT_ASM.read_text(encoding="latin-1") != asm:
            drift.append(f"{OUT_ASM.relative_to(ROOT)} has drifted - rerun --apply")
        if drift:
            raise SystemExit("SCORPION'S LAIR (UMK3) check FAILED:\n  " + "\n  ".join(drift))
        print("SCORPION'S LAIR (UMK3): packs, floor, tables and packed pixels all match umk3.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
