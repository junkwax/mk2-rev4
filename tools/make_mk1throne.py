#!/usr/bin/env python3
r"""THE THRONE ROOM - MK1's court of Shang Tsung, as an MK2 stage (curback 01Ch).

Red lacquer walls hung with landscape scrolls, blue jade medallions, gilt
dragons either side of the throne alcove, spiral gold columns, a grey stone
ledge and the red-and-gold runner the fighters stand on.  Code is
src/MK1THRN.ASM; everything it is built from is generated into
src/MK1THRNB.ASM by this tool.

EVERYTHING HERE IS READ, NOT REMEMBERED - AND FROM ONE SOURCE ONLY:

  C:\\MAME\\roms\\mk.zip    MK1 rev 5.0 (T-unit).  Stage table FFCA7E30, entry
                         4 = FFCB8080 is THE THRONE ROOM.

UNLIKE THE PIT AND THE WARRIOR SHRINE, THERE IS NO .BDB/.BDD FOR IT.  Those
two are in the leak (KUNGFU5, KUNGFU1) and their tools prove the leak file
against the ROM.  Nothing in data/ carries one pixel of this stage - checked
by content, not by name: every BDD in the tree and every data/*.IMG was
searched for its images, by pixels and by size, and none holds any of them.
So THE ART ITSELF is decoded out of MK1's video ROM here, which makes mk.zip
the only thing --check has to compare against.

WHICH ENTRY.  The stage-name table at FFDCC390 runs index for index with the
stage table (ten .longs): 0 THE COURTYARD, 1 PALACE GATES, 2 WARRIOR SHRINE,
3 THE PIT, 4 THRONE ROOM, 5/6/8 GORO'S LAIR, 7 THRONE ROOM.  The four already
ported corroborate it - 2 is KUNGFU1 and 3 is KUNGFU5 to the pixel.  Entries 4
and 7 are the same stage; 4 has ONE MORE COLUMN and TWO MORE dragon blocks
(207 blocks against 201), so 4 is what this imports.  Both are asserted.

**THE MODULE LIST HAS A SKIP IN IT, AND A SKIP IS ONLY 32 BITS.**  MK2's
init_bakmods (BGND.ASM, ibak3) walks `.long bmod / .word x,y` at 64 bits an
entry BUT advances only 32 for a `.long skip_bakmod` - and skip_bakmod is 1
(MAINEQU.ASM).  MK1's walker is the same code, and THE THRONE ROOM is the one
MK1 stage that uses it: three modules, then `.long 1`, then four more.  Read
as a uniform 64-bit list it looks like a 3-module stage that ends early - a
teal-and-gold colonnade with nothing behind it - which is exactly what the
first cut of this import produced, and it built and rendered without error.
So the planes are 1, 2, 3, (4 skipped), 5, 6, 7, 8:

    plane 1  1380x8    the skirt below the runner        020000h (fighters')
    plane 2  1344x37   the runner                        020000h
    plane 3  1317x230  the near columns, capitals, ledge 01A000h
    plane 4  --        skipped
    plane 5  1272x160  the scroll paintings and medallions 015000h
    plane 6  1243x8    the ledge behind them             014000h
    plane 7  1222x192  the back wall, dragons and alcove 014000h
    plane 8   396x67   the throne itself                 0 - never scrolls

MK1's plane mapping is proved the way THE WARRIOR SHRINE proves it (one
definition, make_mk1shrine.SCROLL_CODE / PLANE_TABLE): the record's bakmods
.long names plane-table entry 1, entry e's worldtlx is 0104F890h - 32e, and
MK1's scroller adds scroll-table .long 8-e to it.  Confirmed against a real
MAME run of MK1 (tools/run_mk1_throne_capture.ps1), which logs all nine
worldtlx: at the left limit 30/30/119/194/194/209/209 and 507 on plane 8.

THE ART.  45 header entries, but MK1 gives FIVE PAIRS of them the same SAG -
the same drawing on two different palettes - so only 40 payloads are packed
and both entries of a pair get the one SAG back.  ~62KB, dealt across four
free runs (no free run holds it).

THE CALLA.  MK1's is FFCB8600 and it is four instructions: create one process,
pid 2000h, routine FFD6E660, which builds SHANG TSUNG SEATED ON THE THRONE - a
four-frame, five-piece object.  He is NOT a background module and this import
does not carry him; see doc/MK1_THRONE_ROOM.md "Shang Tsung on the throne" for
what he costs.  MK2's calla only sets the shadow mode and clip.

WHAT GOES WHERE

  --parts   the 40 unique images are dealt first-fit decreasing into PACKS,
            data/MK1TRn.BDB/.BDD + .LOD, one fixed slot each
            (make_mk3cave.py's technique).
  --apply   src/MK1THRNB.ASM: layout equates, MK1TRHDRS merged from the
            tmp/load2/BGNDTBL.TRn snapshots, the seven modules' BLKS/BMOD and
            the eleven palettes.  Every record is decoded back out of its IRW
            and compared with MK1's own pixels first.
  --check   all of the above compared instead of written (Phase D).
  --report  MK1's numbers, the deal and each pack's size against its slot.
  --preview renders the 400x254 screen from the same constants:
            tmp/mk1throne/preview.png (any camera x as arguments).
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave      # noqa: E402  (LOAD2 size model, header snapshots)
import make_mk1pit as pit        # noqa: E402  (MK1 ROM reader, IRW decode, LOD helpers)
import make_mk1shrine as shrine  # noqa: E402  (MK1 plane/scroll proof, irw_holding)

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "MK1THRNB.ASM"
SCREEN_W, SCREEN_H = 400, 254

# --------------------------------------------------------------------------
# Video ROM.  Physical addresses, end exclusive.  Mirrored in makevrom.py
# CUSTOM_VIDEO_SLOTS (and FILE_BANK) and each LOD's ***> line, which this tool
# writes.  Four free runs, because no single one holds ~62KB:
#
#   MK1TR1  bank 0  the 23KB the retired JADMIL1 slot left (makevrom.py) -
#                   free space between IRWs, not a guard, so nothing is
#                   pulled back.
#   MK1TR2  bank 1  between MK1PT4's payload and MK1PSK1's base.
#   MK1TR3  bank 1  inside SCLAP's guard, under MK1PT4 - the run THE PIT's
#                   own packs already sit in the rest of.
#   MK1TR4  bank 0  above SHAOSIT's payload.
#
# (A fifth run - 0x9FD000..0x9FE800, between SKGLOW's declared slot end and
# MK1PSK3's base - is free and would hold 6KB more if the art ever grows.)
#
# Background blocks only: never a shadow source (shadow_p1p2's CPU read has no
# bank select) and never a movie frame, so either bank is safe for all of it.
# Each pack is anchored at the BOTTOM of its hole, rounded up past the payload
# below it (doc/KINTARO_STOMP_ART.md).
# --------------------------------------------------------------------------
# MK1TR1's and MK1TR2's ends are pulled back in makevrom.py (2026-10-05) for
# the empty throne's strips (tools/make_thrnchair.py); NOT here, because deal()
# fills to 90% of these numbers and a smaller one would re-deal the stage.
# makevrom's overlap check is what stops a pack growing into a strip.
PACKS = [
    # name      start       end         bank
    ("MK1TR1", 0x791A00, 0x797400, 0),   # 23,040 B - retired JADMIL1 run
    ("MK1TR2", 0xBF7400, 0xBFC200, 1),   # 19,968 B - MK1PT4 .. MK1PSK1
    ("MK1TR3", 0xBF2000, 0xBF61D0, 1),   # 16,848 B - SCLAP's guard under MK1PT4
    ("MK1TR4", 0x751A00, 0x754000, 0),   # 9,728 B - above SHAOSIT; top 0x754000.. given to XRAY5 (2026-10-04)
]
PACK_PPP = 0
# 0.90, not the shrine's 0.96: the size model is good (~0.7% against MK1CAVE's
# real HDRS) but ZON> row headers can make an image with no transparent margins
# slightly BIGGER than flat, so every pack keeps a tenth of its slot spare.
# merged_headers refuses an overrun outright, and --report prints what LOAD2
# really wrote once there is a snapshot.
PACK_MARGIN = 0.90

# --------------------------------------------------------------------------
# MK1 anchors (C:\\MAME\\roms\\mk.zip, rev 5.0).  Each is checked when read.
# --------------------------------------------------------------------------
THRONE_ENTRY = 4
THRONE_MOD = 0xFFCB8080
THRONE_ALT = 0xFFCB8340         # entry 7, the same stage a column short
THRONE_CALLA = 0xFFCB8600
# the calla, word for word: MOVI 2000h,A1 / MOVI FFD6E660h,A7 /
# CALLA FFCE2810h / RETS - one process (the seated Shang Tsung), nothing else
CALLA_CODE = [0x09C1, 0x2000, 0x09E7, 0xE660, 0xFFD6, 0x0D5F, 0x2810, 0xFFCE, 0x0960]
NAME_TABLE = 0xFFDCC390         # .long per stage, index for index with FFCA7E30
NAME_STR = b"THRONE ROOM\0"
SKIP_BAKMOD = 1                 # MAINEQU.ASM skip_bakmod - 32 bits, not 64

# MK2's fighters stand lower on their anchor than MK1's - THE PIT measured
# ~7 rows and moved its ground from MK1's 264 to 258; THE WARRIOR SHRINE used
# the same -6.  Same nudge here, so the boots land on the runner row MK1's do.
GROUND_NUDGE = -6
SHADOW_FAST = 2                 # every fightable stage: compressed pieces via shadf

PAL_PREFIX = "MK1TR_P"
# what each plane is, for the generated comments and --report
PLANE_NOTE = {
    1: "the skirt below the runner",
    2: "the runner the fighters stand on",
    3: "the near columns, their capitals and the ledge",
    5: "the scroll paintings and jade medallions",
    6: "the ledge behind them",
    7: "the back wall, the gilt dragons and the throne alcove",
    8: "the throne - rate 0, it never scrolls",
}

# --------------------------------------------------------------------------
# SHANG TSUNG SEATED ON THE THRONE - data/MK1TRSH.IMG (--shang).
#
# He is the ONE process MK1's calla creates (FFCB8600 -> FFD6E660), not a
# background module, which is why the imported stage's throne is empty.  The
# process, instruction for instruction:
#
#   MOVI FFD6F300h,A5 / CALLA FFC831C0   build the object from a piece list
#   CALLA FFC89360
#   MOVI 2BDh,A0 / CALLA FFC87120        world x = 701
#   MOVI 36h,A0  / CALLA FFC870D0        world y = 54
#   MOVI 00010000h,A0 / CALLA FFC87710
#   MOVI FFD6ED40h,A9 / CALLA FFC86550   animate off the frame list
#   ...
#
# 701 centres him at 705 in the throne module's world x, and that module spans
# 507..902 - centre 705.  Plane 8 never scrolls, so his screen x is fixed.
#
# EIGHT PIECE LISTS, SIXTEEN RECORDS.  FFD6F300 is the pose the object is
# BUILT in - arms open - and FFD6EDC0 + six more at 0C0h intervals are the
# animation, all sharing three arm/collar pieces.  FFF93200, the seated robe
# and the throne front, is in all eight.
#
# The records are one MK1 group, so only the FIRST carries a palette: the
# .long after FFF92DC0's three (an MK1 image record is .word W,H,anix,aniy /
# .long SAG, and a group's first record has one more .long for the palette).
# --------------------------------------------------------------------------
SHANG_IMG = DATA / "MK1TRSH.IMG"
SHANG_PAL = 0xFFEA6DC0          # the .long after FFF92DC0, the group's first record
SHANG_XY = (0x2BD, 0x36)        # MOVI 2BDh / MOVI 36h in the process - world x, y
SHANG_PROC = 0xFFD6E660
# the process's opening, word for word, so a ROM whose object moved fails here
SHANG_CODE = [0x09E5, 0xF300, 0xFFD6, 0x0D5F, 0x31C0, 0xFFC8, 0x0D5F, 0x9360, 0xFFC8,
              0x09C0, 0x02BD, 0x0D5F, 0x7120, 0xFFC8, 0x09C0, 0x0036, 0x0D5F, 0x70D0,
              0xFFC8, 0x09E0, 0x0000, 0x0001, 0x0D5F, 0x7710, 0xFFC8, 0x09E9, 0xED40,
              0xFFD6]
# --------------------------------------------------------------------------
# HIS POSES.  Every one is a piece list ending in the same seated robe, and
# every one MK1 ever draws has three or four pieces in front of it.
#
#   FFD6EDC0 + 0C0h x k   the seven CAMERA-TRACKING poses (head, two arms, a
#                         collar), which differ only in the head record
#   FFD6F300              the arms-open pose the object is BUILT in.  It is not
#                         in either lane - MK1 replaces it eight ticks later
#   FFD6F3E0/F480/F540    the three CLAP poses
# --------------------------------------------------------------------------
SHANG_TRACK = [0xFFD6EDC0 + 0xC0 * k for k in range(7)]
SHANG_BUILD = 0xFFD6F300
SHANG_CLAP_POSES = {0xFFD6F3E0: "CLAP2", 0xFFD6F480: "CLAP3", 0xFFD6F540: "CLAP4"}
SHANG_LAP = 0xFFF93200          # the seated robe and throne front - in every pose
SHANG_HEADS = [0xFFF92E40 + 0x60 * k for k in range(7)]   # THRSHHEAD1..7
SHANG_PAL_NAME = "THRSH_P"
SHANG_SLOTS = 4                 # upper-body pieces, the widest pose - plus the lap

# record address -> the name it is written under.  Which piece is which was
# MEASURED by drawing each one in its own colour at its own anipoint, not
# guessed: L and R are the VIEWER's left and right.
SHANG_NAMES = {
    SHANG_LAP: ("THRSHLAP", "the seated robe and the throne front - in EVERY pose"),
    0xFFF930E0: ("THRSHARML", "arm, viewer's left - in all seven tracking poses"),
    0xFFF93140: ("THRSHARMR", "arm, viewer's right - in all seven tracking poses"),
    0xFFF931A0: ("THRSHCOLR", "the collar between the arms - in all seven"),
    0xFFF92DC0: ("THRSHUPHEAD", "arms-open build pose: the head"),
    0xFFF93260: ("THRSHUPARML", "arms-open build pose: raised arm, viewer's left"),
    0xFFF932C0: ("THRSHUPBODY", "arms-open build pose: torso and beard"),
    0xFFF93320: ("THRSHUPARMR", "arms-open build pose: forearm, viewer's right"),
    0xFFF93380: ("THRSHUPHANDR", "arms-open build pose: raised hand, viewer's right"),
}

# --------------------------------------------------------------------------
# THE CLAP.  MK1's round-end hook table sits at FFCACF50, ten .longs indexed by
# curback exactly as the stage table is.  Every entry is FFCAD280, a bare RETS,
# EXCEPT entries 4 and 7 - the two THRONE ROOM records - which point at
# FFCAD090: kill the camera-tracking process (pid 2000h) and start FFD6EB40,
# which runs the lane at FFD6EC20 at MOVK 5h a frame.
#
# The lane is four entries and then a loop back to its own start, so it never
# ends on its own; MK1's round teardown stops it.  MEASURED in a real MK1 win
# (tools/run_mk1_throne_win_probe.ps1): the clap begins 14 ticks after the
# round is decided, holds every frame 5 ticks, and runs 36-37 frames (~180
# ticks) before stopping on whatever frame it is on - then the tracker is back
# for the next round.
# --------------------------------------------------------------------------
SHANG_HOOKS = 0xFFCACF50        # ten .longs, one per stage, indexed by curback
SHANG_HOOK_CLAP = 0xFFCAD090    # the throne room's - entries 4 and 7 only
SHANG_HOOK_NONE = 0xFFCAD280    # most stages': a bare RETS
SHANG_HOOK_CRTYD = 0xFFCAD160   # THE COURTYARD's own - the tail of FFCAD090
SHANG_LANE = 0xFFD6EC20         # the clap lane MK1 hands the animator
SHANG_LANE_N = 4                # entries before it loops back to itself
SHANG_CLAP_RATE = 5             # MOVK 5h in FFD6EB40
SHANG_CLAP_FRAMES = 36          # measured: 36-37 frames before it stops
SHANG_CLAP_DELAY = 14           # measured: ticks from the round being decided

SHANG_PACKS = [
    # name       start     end       bank
    # (MK1TRS2's real slot ends at 0x9E7700 in makevrom.py - see PACKS above)
    ("MK1TRSH", 0x9FC400, 0x9FE800, 1),   # 9,216 B - top of SKGLOW's guard
    ("MK1TRS2", 0x9E6400, 0x9E8000, 1),   # 7,168 B - top of JDROD's guard
]
SHANG_PPP = 6                                     # 64-entry palette
SHANG_BUCKETS = 0xFFD6ECE0
SHANG_NBUCKET = 7
# MK1's own constants, from the tracking process (MAME's disassembler):
#   MOVE @104F880h,A3,0   A3 = plane 1's camera x, the integer half
#   CMPI D4h,A3 / JRLS    camera <= 212 -> the neutral head, whatever the sum says
#   MOVI 2E1h,A5 / SUB / ABS / MOVI 4Bh,A1 / DIVS   bucket = |737 - camera| / 75
#   CMPI 6h,A5 / JRLS / MOVK 6h,A5                  ...clamped to 6
#   MOVI 8h,A0 / CALLA sleep                        re-picked every 8 ticks
SHANG_MID, SHANG_STEP, SHANG_MAXB, SHANG_FLAT, SHANG_RATE = 737, 75, 6, 212, 8

TAB = chr(9)
LOD_TEMPLATE = "***> {addr}\nIHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L\n;**************************************************************\n;\n;  THE THRONE ROOM (MK1) - SHANG TSUNG SEATED ON THE THRONE\n;  (bank {bank}, phys 0x{start:06X}..0x{end:06X})\n;\n;  data/{img} is GENERATED by tools/make_mk1throne.py --shang out of\n;  C:\\MAME\\roms\\mk.zip - MK1's own records, pixels,\n;  anipoints and palette.  Phase D checks it still matches.\n;\n;  ONLY THE ELEVEN RECORDS THE GAME DRAWS are packed.  MK1 builds the\n;  object on its arms-open list (THRSHUP*) and its first loop pass, eight\n;  ticks later, replaces the frame from the camera bucket - so that pose\n;  is never seen.  MK2 builds straight on a bucket frame, and those five\n;  records stay in the IMG rather than becoming dead art in the ROM.\n;\n;  PON>: the stage builds these with gso_dmawnz -> object_setup, which\n;  reads the palette off the record.  {pal} is carried in\n;  src/MK1THRNB.ASM (generated too).\n;\n;  PPP> {ppp}: {pal} has 64 entries and the art indexes 63.\n;\n;**************************************************************\nPON>\nZON>\nPPP> {ppp}\nASM> {name}.TBL\n{img}\n---> {recs}\n"


# --------------------------------------------------------------------------
# MK1
# --------------------------------------------------------------------------
def _okp(rom, a):
    return 0xFF800000 <= a < 0xFF800000 + (len(rom.p) - 64) * 8


def _blocks(rom, mod):
    """[(flags, x, y, hdrword)] of one MK1 module, from its 0FFFFh-ended list."""
    out, q = [], rom.l(mod + 48)
    while _okp(rom, q) and rom.w(q) != 0xFFFF:
        out.append(tuple(rom.w(q + 16 * k) for k in range(4)))
        q += 64
    return out


def _placements(rom, rec):
    """The module list of one stage record, as init_bakmods walks it: 64 bits
    per module, 32 for a skip_bakmod, 0FFFFFFFFh ends it.  Returns the modules
    with the plane each one lands on."""
    mods, a, plane = [], rec + 192, 1
    while _okp(rom, a):
        v = rom.l(a)
        if v == 0xFFFFFFFF:
            return mods
        if v == SKIP_BAKMOD:
            plane += 1
            a += 32
            continue
        if not _okp(rom, v):
            raise SystemExit(f"MK1 module list at {a:08X}: {v:08X} is neither a module, "
                             "a skip nor the terminator")
        mods.append(dict(addr=v, w=rom.w(v), h=rom.w(v + 16), n=rom.w(v + 32),
                         blks=_blocks(rom, v), hdrs=rom.l(v + 80), pals=rom.l(v + 112),
                         x=rom.sw(a + 32), y=rom.sw(a + 48), plane=plane))
        plane += 1
        a += 64
    raise SystemExit("MK1 module list ran off the ROM")


def read_mk1(rom):
    """THE THRONE ROOM's stage record, plane mapping, modules and calla, every
    anchor checked."""
    if rom.l(pit.MK1_STAGES + THRONE_ENTRY * 32) != THRONE_MOD:
        raise SystemExit(f"MK1 stage table entry {THRONE_ENTRY} is not "
                         f"{THRONE_MOD:08X} - wrong ROM revision?")
    nm = rom.l(NAME_TABLE + THRONE_ENTRY * 32)
    o = (nm - pit.BASE) // 8
    if bytes(rom.p[o:o + len(NAME_STR)]) != NAME_STR:
        raise SystemExit(f"MK1 stage {THRONE_ENTRY} is not named {NAME_STR!r} "
                         "- the name table no longer runs with the stage table")

    rec = dict(erase=rom.w(THRONE_MOD), ground=rom.w(THRONE_MOD + 16),
               worldy=rom.sw(THRONE_MOD + 32), start=rom.w(THRONE_MOD + 48),
               left=rom.w(THRONE_MOD + 64), right=rom.w(THRONE_MOD + 80),
               calla=rom.l(THRONE_MOD + 96), scroll=rom.l(THRONE_MOD + 128),
               bakmods=rom.l(THRONE_MOD + 160))
    if rec["calla"] != THRONE_CALLA:
        raise SystemExit(f"the throne room's calla is {rec['calla']:08X}, not {THRONE_CALLA:08X}")
    if [rom.w(THRONE_CALLA + 16 * i) for i in range(len(CALLA_CODE))] != CALLA_CODE:
        raise SystemExit(f"{THRONE_CALLA:08X} is no longer MK1's one-process throne-room "
                         "calla - it may draw something this import would miss")
    for at, words in shrine.SCROLL_CODE.items():
        if [rom.w(at + 16 * i) for i in range(len(words))] != words:
            raise SystemExit(f"MK1 scroller at {at:08X} moved - the plane/rate mapping is unproven")

    planes = []
    for e in range(9):
        base = shrine.PLANE_TABLE + 160 * e
        if rom.l(base + 64) != shrine.PLANE_WORLDTLX0 - 32 * e:
            raise SystemExit(f"MK1 plane table entry {e}: worldtlx {rom.l(base + 64):08X}")
        planes.append(rom.l(base + 96))
    first = planes.index(rec["bakmods"])
    if first != 1:
        raise SystemExit(f"the throne room starts on MK1's plane {first}, not 1")

    mods = _placements(rom, THRONE_MOD)
    for m in mods:
        m["rate"] = rom.l(rec["scroll"] + 32 * (8 - m["plane"]))
        if len(m["blks"]) != m["n"]:
            raise SystemExit(f"MK1 module {m['addr']:08X}: {len(m['blks'])} blocks, "
                             f"record says {m['n']}")
    if [m["plane"] for m in mods] != [1, 2, 3, 5, 6, 7, 8]:
        raise SystemExit(f"the throne room's planes are {[m['plane'] for m in mods]}, "
                         "not 1,2,3,5,6,7,8 - the skip moved")
    if len({(m["hdrs"], m["pals"]) for m in mods}) != 1:
        raise SystemExit("the throne room's modules no longer share one header table "
                         "and palette list")

    check_alt(rom, mods)
    return rec, mods


def check_alt(rom, mods):
    """Entry 7 is the same stage a column short - assert it, so a ROM whose two
    records have drifted apart cannot be imported silently.

    THE TWO RECORDS HAVE THEIR OWN HEADER TABLES (FFE547E0 and FFE5CAC0), so
    the same drawing has a different INDEX in each and comparing block words
    reports every block as different.  Compare by what a block RESOLVES to:
    its flags, its position and the pixels the header points at."""
    if rom.l(pit.MK1_STAGES + 7 * 32) != THRONE_ALT:
        raise SystemExit(f"MK1 stage table entry 7 is not {THRONE_ALT:08X}")
    alt = _placements(rom, THRONE_ALT)
    if [(a["w"], a["h"], a["x"], a["y"], a["plane"]) for a in alt] != \
       [(m["w"], m["h"], m["x"], m["y"], m["plane"]) for m in mods]:
        raise SystemExit("MK1 stage 7 is no longer the same modules on the same planes as stage 4")

    cache = {}

    def resolved(hdrs, blk):
        f, bx, by, hw = blk
        key = (hdrs, hw & 0xFFF)
        if key not in cache:
            a = hdrs + 80 * (hw & 0xFFF)
            w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
            rows, _b = pit.decode_record(rom.g, sag - pit.IROM, w, h, ctrl)
            cache[key] = (w, h, bytes(b for r in rows for b in r))
        return (f, bx, by, pal_of(blk), cache[key])

    extra = 0
    for a, m in zip(alt, mods):
        want = [resolved(m["hdrs"], b) for b in m["blks"]]
        for b in a["blks"]:
            r = resolved(a["hdrs"], b)
            if r not in want:
                raise SystemExit(f"MK1 stage 7 module {a['addr']:08X} draws a block stage 4 "
                                 f"does not (flags {b[0]:04X} at {b[1]},{b[2]})")
            want.remove(r)
        extra += len(want)
    if extra != 6:
        raise SystemExit(f"MK1 stage 4 has {extra} blocks stage 7 lacks, not the 6 "
                         "(one column, two throne pieces) it shipped with")


def pal_of(blk):
    """MK1 splits a block's palette index across two words: the low nibble is
    word 0's, the high nibble is word 3's top nibble (make_mk1shrine's
    check_source proves this shape against KUNGFU1's BDB)."""
    return (blk[0] & 0xF) | (((blk[3] >> 12) & 0xF) << 4)


def art(rom, mods):
    """The images and palettes the stage draws, decoded out of MK1's video ROM.

    Returns (imgs by MK1 header index, order, [(label, words, mk1 index)],
    MK1 pal -> generated index, share: header index -> the index whose payload
    it reuses).  MK1 gives five PAIRS of headers the same SAG - one drawing on
    two palettes - and that sharing is reproduced, not unpacked."""
    hd, pl = mods[0]["hdrs"], mods[0]["pals"]
    order = sorted({b[3] & 0xFFF for m in mods for b in m["blks"]})
    imgs = {}
    for i in order:
        a = hd + 80 * i
        w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
        if not (0 < w <= 1024 and 0 < h <= 1024):
            raise SystemExit(f"MK1 header {i} is {w}x{h} - not an image record")
        rows, _bpp = pit.decode_record(rom.g, sag - pit.IROM, w, h, ctrl)
        imgs[i] = dict(idx=i, w=w, h=h, big=0, px=bytes(b for r in rows for b in r),
                       mk1_sag=sag, mk1_ctrl=ctrl)

    share, first_of = {}, {}
    for i in order:
        key = imgs[i]["mk1_sag"]
        if key in first_of:
            j = first_of[key]
            if (imgs[i]["w"], imgs[i]["h"], imgs[i]["px"]) != (imgs[j]["w"], imgs[j]["h"], imgs[j]["px"]):
                raise SystemExit(f"MK1 headers {j:02X} and {i:02X} share SAG {key:08X} "
                                 "but decode differently")
            share[i] = j
        else:
            first_of[key] = i
    uniq = [i for i in order if i not in share]

    used = sorted({pal_of(b) for m in mods for b in m["blks"]})
    remap = {p: k for k, p in enumerate(used)}
    pals = [(f"{PAL_PREFIX}{k:02d}", rom.palette(rom.l(pl + 32 * p)), p)
            for k, p in enumerate(used)]
    for i in order:
        im = imgs[i]
        for m in mods:
            for b in m["blks"]:
                if (b[3] & 0xFFF) != i:
                    continue
                words = pals[remap[pal_of(b)]][1]
                if max(im["px"]) >= len(words):
                    raise SystemExit(f"MK1 image {i:02X} indexes {max(im['px'])} but "
                                     f"MK1 palette {pal_of(b)} has {len(words)} entries")
    return imgs, order, uniq, pals, remap, share


def layout():
    rom = pit.MK1()
    rec, mods = read_mk1(rom)
    imgs, order, uniq, pals, remap, share = art(rom, mods)
    return dict(rom=rom, rec=rec, mods=mods, imgs=imgs, order=order, uniq=uniq,
                pals=pals, remap=remap, share=share)


def ground_y(L):
    return L["rec"]["ground"] + GROUND_NUDGE


# --------------------------------------------------------------------------
# Shang Tsung seated on the throne
# --------------------------------------------------------------------------
def shang(rom):
    """MK1's seated Shang Tsung: every piece list he is ever drawn in, the
    records they name, his palette and where the process puts him.  Every
    anchor is checked, so a different ROM fails here instead of producing a
    plausible wrong figure."""
    got = [rom.w(SHANG_PROC + 16 * i) for i in range(len(SHANG_CODE))]
    if got != SHANG_CODE:
        raise SystemExit(f"{SHANG_PROC:08X} is no longer MK1's seated-Shang process "
                         "- the piece list, the placement or the animation has moved")

    def piece_list(head):
        out, p = [], head
        while (v := rom.l(p)) != 0:
            if not _okp(rom, v):
                raise SystemExit(f"piece list {head:08X}: {v:08X} is not a record")
            out.append(v)
            p += 32
            if len(out) > 12:
                raise SystemExit(f"piece list {head:08X} has no terminator")
        return out

    poses = [("build", SHANG_BUILD, piece_list(SHANG_BUILD))]
    for k, h in enumerate(SHANG_TRACK):
        poses.append((f"t{k + 1}", h, piece_list(h)))
    for h, nm in SHANG_CLAP_POSES.items():
        poses.append((nm.lower(), h, piece_list(h)))
    if any(p[2][-1] != SHANG_LAP for p in poses):
        raise SystemExit(f"the seated robe {SHANG_LAP:08X} is no longer the last piece "
                         "of every pose")
    if [p[2][0] for p in poses[1:8]] != SHANG_HEADS:
        raise SystemExit("the seven tracking poses no longer lead with THRSHHEAD1..7")
    # the arms-open BUILD pose is wider than the rest and is never drawn, so
    # it does not constrain the slot count
    wide = max(len(p[2]) for p in poses if p[0] != "build") - 1
    if wide > SHANG_SLOTS:
        raise SystemExit(f"a pose has {wide} pieces in front of the lap, more than the "
                         f"{SHANG_SLOTS} slots the stage builds")

    # the round-end hook table, read and checked
    hooks = [rom.l(SHANG_HOOKS + 32 * e) for e in range(10)]
    clap_on = [e for e, v in enumerate(hooks) if v == SHANG_HOOK_CLAP]
    if clap_on != [THRONE_ENTRY, 7]:
        raise SystemExit(f"MK1's round-end hooks clap on stages {clap_on}, not "
                         f"[{THRONE_ENTRY}, 7] - the throne room's two records")
    # THE COURTYARD has one of its own (FFCAD160, which is also where the
    # throne room's routine falls through to); every other stage RETS.
    other = {v for e, v in enumerate(hooks) if e not in clap_on}
    if not other <= {SHANG_HOOK_NONE, SHANG_HOOK_CRTYD}:
        raise SystemExit("a stage other than THE THRONE ROOM and THE COURTYARD "
                         "now has a round-end hook")
    lane = [rom.l(SHANG_LANE + 32 * k) for k in range(SHANG_LANE_N)]
    if any(v not in SHANG_CLAP_POSES for v in lane):
        raise SystemExit("MK1's clap lane names something that is not a clap pose")
    if rom.l(SHANG_LANE + 32 * SHANG_LANE_N + 32) != SHANG_LANE:
        raise SystemExit("MK1's clap lane no longer loops back to its own start")

    recs = {}
    for _tag, _h, lst in poses:
        for a in lst:
            if a not in recs:
                recs[a] = rom.image(a)
    words = rom.palette(SHANG_PAL)
    hi = max(max(im["px"]) for im in recs.values())
    if hi >= len(words):
        raise SystemExit(f"a piece indexes {hi} but {SHANG_PAL:08X} has {len(words)} "
                         "entries - that is not this group's palette")
    return dict(poses=poses, recs=recs, pal=words, xy=SHANG_XY, depth=cave._bpp(hi),
                lane=lane, names=shang_names(poses))


def shang_names(poses):
    """record -> the name it is written under.  The named ones are named; the
    clap's own pieces are <POSE><letter> in MK1's piece order, because what each
    one is differs pose by pose and an anatomical guess would be wrong."""
    out = {}
    for a, (nm, _note) in SHANG_NAMES.items():
        out[a] = nm
    for k, a in enumerate(SHANG_HEADS):
        out[a] = f"THRSHHEAD{k + 1}"
    for tag, h, lst in poses:
        pose = SHANG_CLAP_POSES.get(h)
        if not pose:
            continue
        for i, a in enumerate(lst[:-1]):
            out.setdefault(a, f"THRS{pose}{chr(65 + i)}")
    return out


def shang_entries(S):
    """[(name, anix, aniy, w, h, px, palindex)] in a fixed order."""
    seen, out = set(), []
    order = SHANG_HEADS + [a for a in SHANG_NAMES if a not in SHANG_HEADS]
    for _tag, h, lst in S["poses"]:
        if h in SHANG_CLAP_POSES:
            order += [a for a in lst if a not in order]
    for a in order:
        if a in seen:
            continue
        seen.add(a)
        im = S["recs"][a]
        out.append((S["names"][a], im["ax"], im["ay"], im["w"], im["h"], im["px"], 0))
    return out


def shang_drawn(S):
    """The records the GAME draws - every tracking pose and every clap pose.
    The arms-open build pose is left out: MK1 builds on it and replaces it eight
    ticks later, and MK2 builds straight on a tracking pose, so packing it would
    put dead art in the ROM."""
    keep, out = set(), []
    for tag, h, lst in S["poses"]:
        if tag == "build":
            continue
        for a in lst:
            if a not in keep:
                keep.add(a)
                out.append(S["names"][a])
    return out


def shang_deal(S):
    """First-fit decreasing over SHANG_PACKS, deterministic."""
    names = shang_drawn(S)
    by = {S["names"][a]: im for a, im in S["recs"].items()}
    cap = [int((e - s) * 8 * PACK_MARGIN) for _n, s, e, _b in SHANG_PACKS]
    used = [0] * len(SHANG_PACKS)
    got = [[] for _ in SHANG_PACKS]
    for nm in sorted(names, key=lambda n: (-cave.packed_bits(by[n]), n)):
        bits = cave.packed_bits(by[nm])
        for k in range(len(SHANG_PACKS)):
            if used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(nm)
                break
        else:
            raise SystemExit(f"Shang record {nm} ({bits // 8} bytes) fits no pack")
    return [sorted(g, key=names.index) for g in got], used


def shang_img(S):
    return pit.build_img(shang_entries(S), [(SHANG_PAL_NAME, S["depth"], S["pal"])])


def shang_png(L, S, out_dir):
    """Every pose as MK1 assembles it, and the two lanes on the stage at the
    world x/y the process sets - the placement check, drawn rather than
    asserted."""
    from PIL import Image, ImageDraw
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    recs = S["recs"]
    allp = [recs[a] for _t, _h, lst in S["poses"] for a in lst]
    x0 = min(-im["ax"] for im in allp)
    y0 = min(-im["ay"] for im in allp)
    W = max(-im["ax"] + im["w"] for im in allp) - x0
    H = max(-im["ay"] + im["h"] for im in allp) - y0

    def draw(lst, scr, ax, ay):
        px = scr.load()
        for a in reversed(lst):          # the list runs front to back
            im = recs[a]
            ox, oy = ax - im["ax"], ay - im["ay"]
            for y in range(im["h"]):
                for x in range(im["w"]):
                    v = im["px"][y * im["w"] + x]
                    if not v:
                        continue
                    tx, ty = ox + x, oy + y
                    if 0 <= tx < scr.width and 0 <= ty < scr.height:
                        px[tx, ty] = rgb(S["pal"][v])

    sheet = Image.new("RGB", (W * len(S["poses"]), H + 12), (18, 18, 22))
    dr = ImageDraw.Draw(sheet)
    for k, (tag, _h, lst) in enumerate(S["poses"]):
        cell = Image.new("RGB", (W, H), (30, 10, 40))
        draw(lst, cell, -x0, -y0)
        sheet.paste(cell, (k * W, 0))
        dr.text((k * W + 2, H + 1), tag, fill=(255, 255, 0))
    sheet.save(out / "poses.png")

    cam = L["rec"]["start"]
    ax = S["xy"][0] - plane_x(L, cam)[4]        # plane 4 - measured, see the doc
    ay = S["xy"][1] - L["rec"]["worldy"]
    lane = [("clap%d" % (k + 1), h) for k, h in enumerate(S["lane"])]
    for tag, h in [("track1", SHANG_TRACK[0])] + lane:
        lst = next(p[2] for p in S["poses"] if p[1] == h)
        scr = render(L, cam, show_ground=False)
        draw(lst, scr, ax, ay)
        scr.save(out / f"on_throne_{tag}.png")
    print(f"wrote {out / 'poses.png'} and on_throne_*.png "
          f"(anchor screen {ax},{ay} at the start camera)")


def deal(L):
    """First-fit decreasing over the UNIQUE payloads, deterministic."""
    imgs = L["imgs"]
    cap = [int((e - s) * 8 * PACK_MARGIN) for _n, s, e, _b in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(L["uniq"], key=lambda i: (-cave.packed_bits(imgs[i]), i)):
        bits = cave.packed_bits(imgs[idx])
        for k in range(len(PACKS)):
            if used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    return [sorted(g) for g in got], used


def part_files(L):
    """{filename: bytes} for every data/MK1TRn.BDB/.BDD - one throwaway module
    per pack, every image laid out once, all palettes in the generated order."""
    imgs = L["imgs"]
    groups, _ = deal(L)
    files = {}
    for (name, _s, _e, _b), group in zip(PACKS, groups):
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
    return files


def pack_lod(name, start, end, bank):
    return f"""***> {pit.lod_address(start)}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE THRONE ROOM (MK1) - image pack {name[-1]} (bank {bank},
;  phys 0x{start:06X}..0x{end:06X})
;
;  data/{name}.BDB/.BDD are GENERATED by tools/make_mk1throne.py --parts
;  straight out of C:\\MAME\\roms\\mk.zip - MK1's stage record FFCB8080.
;  There is no .BDB/.BDD for this stage in the leak, so the ROM is the
;  only source.  --apply merges the header tables back into the stage's
;  seven modules (src/MK1THRNB.ASM).  Do not edit the pack by hand.
;
;  PPP> {PACK_PPP}: per-block auto depth, as every BBB> in MK7MIL.  DMA-drawn
;  background, never walked by shadow_p1p2's bank-less CPU read.
;
;**************************************************************
ZON>
POF>
PPP> {PACK_PPP}
GLO> BGNDTBL.GLO
BBB> {name}
"""


def lod_files(L):
    groups, _ = deal(L)
    out = {f"{name}.LOD": pack_lod(name, st, e, bank).encode()
           for (name, st, e, bank), g in zip(PACKS, groups) if g}
    S = shang(L["rom"])
    for pack, g in zip(SHANG_PACKS, shang_deal(S)[0]):
        if g:
            out[pack[0] + ".LOD"] = shang_lod(pack, g).encode()
    return out


# --------------------------------------------------------------------------
# --apply
# --------------------------------------------------------------------------
def merged_headers(L):
    """[(w, h, sag, ctrl, where)] per MK1 header index, in MK1's order.  The
    five shared-SAG pairs take their partner's row, as MK1 does."""
    imgs = L["imgs"]
    groups, _ = deal(L)
    by = {}
    for (name, start, end, _b), group in zip(PACKS, groups):
        if not group:
            continue
        snap = LOAD2 / f"BGNDTBL.{name[-3:]}"
        if not snap.exists():
            raise SystemExit(f"{snap} missing - run python build.py")
        hdrs = cave.read_hdrs(snap)
        if len(hdrs) != len(group):
            raise SystemExit(f"{snap}: {len(hdrs)} headers, pack has {len(group)} images")
        hi = 0
        for idx, (w, h, addr, ctrl) in zip(group, hdrs):
            im = imgs[idx]
            if (w, h) != (im["w"], im["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}, MK1 says {im['w']}x{im['h']}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} (phys {p:X}) "
                                 f"outside {start:X}..{end:X}")
            hi = max(hi, p + (cave.packed_bits(im) + 7) // 8)
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
        if hi > end:
            raise SystemExit(f"{name}: payload runs to {hi:X}, slot ends {end:X}")
    for i, j in L["share"].items():
        w, h, addr, ctrl, src = by[j]
        by[i] = (w, h, addr, ctrl, f"{src} (MK1 shares one SAG with {j:02X})")
    missing = [i for i in L["order"] if i not in by]
    if missing:
        raise SystemExit("no header for MK1 image(s) " + ", ".join(f"{i:02X}" for i in missing))
    return [by[i] for i in L["order"]]


def verify_rom(L, hdrs):
    """Decode every record the stage draws back out of the IRW that holds it
    and compare it with MK1's own pixels - LOAD2 has more than one way of
    writing a record that is not what it was given, and a wrong one draws as
    garbage no table check would see."""
    bad = []
    for idx, (w, h, addr, ctrl, src) in zip(L["order"], hdrs):
        name, start, payload = shrine.irw_holding(cave.sag_phys(addr))
        try:
            rows, _bpp = pit.decode_record(payload, pit.runtime_bit(addr) - start * 8, w, h, ctrl)
        except IndexError:
            bad.append(f"{name}: MK1 {idx:02X} runs off the IRW")
            continue
        px = L["imgs"][idx]["px"]
        n = sum(1 for y in range(h) for x in range(w) if rows[y][x] != px[y * w + x])
        if n:
            bad.append(f"{name}: MK1 {idx:02X} ({w}x{h}, {src}) - {n} pixels differ from mk.zip")
    return bad


def h4(v, d=4):
    return "0%0*XH" % (d, v & ((1 << (4 * d)) - 1))


# THE THRONE DOES NOT SLIDE IN ITS ALCOVE.  MK1 scrolls planes 4 and 5 (Shang
# Tsung, and the throne he sits on) at 15000h against the back wall's 14000h,
# so over the whole camera range the throne and the man on it drift ~15 px
# across the alcove behind them.  It reads as the chair coming loose from the
# wall, not as depth (the user's call, 2026-10-08), so the SHIPPED rate of
# both is the wall's.  Every plane is laid out at the start camera, where the
# drift is zero, so nothing else moves.  rec_scroll itself stays MK1's - the
# proofs against MK1 captures use it.
WALL_LOCK = {4: 7, 5: 7}


def rec_scroll(L, plane):
    """MK1's scroll-table entry for a plane: the table's .long 8-e."""
    return L["rom"].l(L["rec"]["scroll"] + 32 * (8 - plane))


def mod_label(m):
    return "MK1TR%d" % m["plane"]



def build_asm(L, hdrs):
    rec, mods = L["rec"], L["mods"]
    o = []
    w = o.append
    w("; THE THRONE ROOM (MK1) - GENERATED by tools/make_mk1throne.py --apply.  Do not hand-edit.")
    w("; Art and layout: MK1's stage record FFCB8080 (C:\\MAME\\roms\\mk.zip), read by the tool.")
    w("; There is no .BDB/.BDD for this stage in the leak - the ROM is the only source.")
    w("")
    w("; ---- layout ----")
    w(f"mk1t_erase\t.set\t{h4(rec['erase'])}\t\t; MK1's autoerase")
    w(f"mk1t_ground\t.set\t{ground_y(L)}\t\t; MK1's {rec['ground']} {GROUND_NUDGE:+d} "
      "(MK2 fighters stand lower on the anchor)")
    w(f"mk1t_worldy\t.set\t{rec['worldy']}")
    w(f"mk1t_start\t.set\t{rec['start']}")
    w(f"mk1t_left\t.set\t{rec['left']}")
    w(f"mk1t_right\t.set\t{rec['right']}")
    w(f"mk1t_shad_fast\t.set\t{SHADOW_FAST}")
    w("")
    w("; MK1's scroll table, all nine.  Plane 4 carries no module - the")
    w("; stage's module list skips it - but its worldtlx still scrolls, and")
    w("; that is the one Shang Tsung on the throne is drawn against.")
    for e in range(9):
        note = PLANE_NOTE.get(e, "no module of its own")
        src = WALL_LOCK.get(e, e)
        if src != e:
            note += f" - MK1 has {h4(rec_scroll(L, e), 6)}; locked to plane {src}"
        w(f"mk1t_rate{e}	.set	{h4(rec_scroll(L, src), 6)}		; plane {e} - {note}")
    w("")
    for m in mods:
        n = m["plane"]
        w(f"mk1t_m{n}_x\t.set\t{m['x']}\t\t; plane {n} - {PLANE_NOTE[n]}")
        w(f"mk1t_m{n}_y\t.set\t{m['y']}")
    w("")
    w("\t.data")
    w("")
    w("MK1TRHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["order"]):
        w(f"\t.word\t{hw},{hh}\t\t; MK1 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["order"])}
    for m in mods:
        lab = mod_label(m)
        w(f"{lab}BLKS:\t\t\t\t; {PLANE_NOTE[m['plane']]}")
        for blk in m["blks"]:
            f, bx, by, hw = blk
            np = L["remap"][pal_of(blk)]
            w("\t.word\t%s,%d,%d,%s" % (h4((f & 0xFFF0) | (np & 0xF)), bx, by,
                                        h4(hidx[hw & 0xFFF] + ((np >> 4) << 12))))
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{m['w']},{m['h']},{len(m['blks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, MK1TRHDRS, MK1TRPALS")
        w("")
    w("MK1TRPALS:")
    for label, _words, p in L["pals"]:
        wear = sorted({i for i in L["order"] for m in mods for b in m["blks"]
                       if (b[3] & 0xFFF) == i and pal_of(b) == p})
        w(f"\t.long\t{label}\t\t; MK1 palette {p:2d} - images "
          + ",".join(f"{i:02X}" for i in wear[:8]) + ("..." if len(wear) > 8 else ""))
    w("")
    for label, words, _p in L["pals"]:
        w(f"{label}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    o.extend(shang_asm(L))
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


def shang_lod(pack, group):
    """One sprite pack's LOD.  PON> so object_setup can read the palette off a
    record; ASM> so LOAD2 writes the SAG table promote_tbls copies into src/."""
    name, start, end, bank = pack
    return LOD_TEMPLATE.format(addr=pit.lod_address(start), name=name, bank=bank,
                               start=start, end=end, img=SHANG_IMG.name,
                               ppp=SHANG_PPP, pal=SHANG_PAL_NAME,
                               recs=",".join(group))


def shang_asm(L):
    """His palette, the pose tables both lanes index, and MK1's own constants -
    all read off the ROM."""
    S = shang(L["rom"])
    names = S["names"]
    o = []
    w = o.append
    w("")
    w("; ---- Shang Tsung on the throne (data/MK1TRSH.LOD, MK1TRS2.LOD) ----")
    w("; His records point at this palette through the LODs' PON>.")
    w(SHANG_PAL_NAME + ":")
    w(TAB + ".word" + TAB + str(len(S["pal"])))
    for i in range(0, len(S["pal"]), 8):
        w(TAB + ".word" + TAB + ",".join(h4(v) for v in S["pal"][i:i + 8]))
    w("")
    w("; MK1's numbers, off the tracking process at FFD6E660 and the round-end")
    w("; hook at FFCAD090, with MAME's disassembler - not by eye:")
    w(";   MOVE @104F880h,A3,0  A3 = plane 1's camera x, the integer half")
    w(";   CMPI D4h,A3 / JRLS   at or left of 212, the neutral head whatever the sum says")
    w(";   MOVI 2E1h,A5 / SUB / ABS / MOVI 4Bh,A1 / DIVS   bucket = |737-camera| / 75")
    w(";   CMPI 6h,A5 / MOVK 6h,A5                         ...clamped to 6")
    w(";   MOVI 8h,A0 / CALLA <sleep>                      re-picked every 8 ticks")
    w(";   MOVK 5h,A0  (FFD6EB40)                          and 5 ticks a clap frame")
    for nm, val, note in (("x", S["xy"][0], "MOVI 2BDh - world x, on plane 4's camera"),
                          ("y", S["xy"][1], "MOVI 36h  - world y"),
                          ("rate", SHANG_RATE, "MOVI 8h   - ticks between re-picks"),
                          ("mid", SHANG_MID, "MOVI 2E1h - the camera he faces squarely"),
                          ("step", SHANG_STEP, "MOVI 4Bh  - camera pixels per head step"),
                          ("maxb", SHANG_MAXB, "CMPI 6h   - the last bucket"),
                          ("flat", SHANG_FLAT, "CMPI D4h  - at or left of this, bucket 3"),
                          ("slots", SHANG_SLOTS, "upper-body pieces - the widest pose"),
                          ("crate", SHANG_CLAP_RATE, "MOVK 5h   - ticks a clap frame"),
                          ("cn", SHANG_LANE_N, "entries in MK1's clap lane"),
                          ("cframes", SHANG_CLAP_FRAMES, "measured: frames before it stops"),
                          ("cwait", SHANG_CLAP_DELAY, "measured: ticks after the round is decided")):
        w("mk1t_sh_" + nm + TAB + ".set" + TAB + str(val) + TAB + TAB + "; " + note)
    w("")
    w("; The seated robe, behind every pose and never swapped.")
    w("mk1t_sh_lap" + TAB + ".set" + TAB + "0" + TAB + TAB + "; (placeholder - see mk1t_sh_lapr)")
    w("mk1t_sh_lapr:")
    w(TAB + ".long" + TAB + names[SHANG_LAP])
    w("")
    w("; EVERY POSE AS " + str(SHANG_SLOTS) + " UPPER-BODY SLOTS, FRONT TO BACK.  A pose with")
    w("; fewer real pieces repeats its last one - drawing a piece twice in the same")
    w("; place costs one blit and needs no blank record and no inviso flag, which")
    w("; on a single-part object there is no safe way to set.")

    def pose_row(h):
        lst = next(p[2] for p in S["poses"] if p[1] == h)
        front = [names[a] for a in lst[:-1]]
        while len(front) < SHANG_SLOTS:
            front.append(front[-1])
        return front

    w("mk1t_sh_track:" + TAB + TAB + "; the seven the camera bucket picks between")
    for k in range(SHANG_NBUCKET):
        h = L["rom"].l(SHANG_BUCKETS + 32 * k)
        lo = SHANG_MID - SHANG_STEP * (k + 1) + 1
        hi = SHANG_MID - SHANG_STEP * k
        rlo = SHANG_MID + SHANG_STEP * k
        w(TAB + ".long" + TAB + ",".join(pose_row(h)) + TAB + "; bucket " + str(k) +
          ": camera " + str(lo) + ".." + str(hi) + " or " + str(rlo) + ".." +
          str(rlo + SHANG_STEP - 1))
    w("")
    w("; MK1's clap lane at FFD6EC20, in its own order.  It loops back to its own")
    w("; start, so nothing in the data ends it - the round teardown does.")
    w("mk1t_sh_clap:")
    for k, h in enumerate(S["lane"]):
        w(TAB + ".long" + TAB + ",".join(pose_row(h)) + TAB + "; step " + str(k) +
          " - " + SHANG_CLAP_POSES[h].lower())
    return o


def rgb(c):
    """MAME's pal5bit, so a preview can be diffed against a real snapshot."""
    return tuple(((c >> s) & 31) << 3 | ((c >> s) & 31) >> 2 for s in (10, 5, 0))


def plane_x(L, cam):
    """Every plane's worldtlx at a plane-1 camera of `cam`.  Both games seed all
    nine planes from the record's start x and add the rate-scaled delta.

    THE SCALED DELTA IS FLOORED, NOT ROUNDED - `//`, which floors for a negative
    delta too.  round() agrees at every camera LEFT of the start and is one
    pixel out on planes 3, 6 and 7 to the RIGHT of it, which is invisible in a
    preview and drops a pixel diff against a real frame from 87% to 46%.
    Floor reproduces all 21 plane values MK1 and MK2 were measured at
    (tools/run_mk1_throne_capture.ps1 and the -Stage 1c stage probe, which log
    every plane)."""
    s = L["rec"]["start"]
    # ALL NINE, not just the planes with modules: plane 4 carries none and is
    # the one Shang Tsung is drawn against.
    return {e: s + (cam - s) * rec_scroll(L, e) // 0x20000 for e in range(9)}


def render(L, cam, cam_y=None, show_ground=True):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cam_y = rec["worldy"] if cam_y is None else cam_y
    px_x = plane_x(L, cam)
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), rgb(rec["erase"]))
    px = scr.load()
    for m in sorted(L["mods"], key=lambda m: -m["plane"]):
        camx = px_x[m["plane"]]
        for blk in sorted(m["blks"], key=lambda b: -(b[0] & 0xFFF0)):
            f, bx, by, hw = blk
            im = L["imgs"][hw & 0xFFF]
            pal = L["pals"][L["remap"][pal_of(blk)]][1]
            flip = bool(f & 0x10)
            for y in range(im["h"]):
                ty = m["y"] + by + y - cam_y
                if not 0 <= ty < SCREEN_H:
                    continue
                row = im["px"][y * im["w"]:(y + 1) * im["w"]]
                for x in range(im["w"]):
                    tx = m["x"] + bx + x - camx
                    if not 0 <= tx < SCREEN_W:
                        continue
                    v = row[im["w"] - 1 - x] if flip else row[x]
                    if v:
                        px[tx, ty] = rgb(pal[v])
    if show_ground:
        gy = ground_y(L) - cam_y
        if 0 <= gy < SCREEN_H:
            ImageDraw.Draw(scr).line([(0, gy), (SCREEN_W - 1, gy)], fill=(255, 0, 0))
    return scr


def preview(L, cams):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cams = cams or [rec["left"], rec["start"], rec["right"]]
    shots = [(c, render(L, c)) for c in cams]
    sheet = Image.new("RGB", (SCREEN_W, (SCREEN_H + 12) * len(shots)), (16, 16, 20))
    dr = ImageDraw.Draw(sheet)
    for k, (c, im) in enumerate(shots):
        sheet.paste(im, (0, k * (SCREEN_H + 12)))
        dr.text((4, k * (SCREEN_H + 12) + 2), "camera %d" % c, fill=(255, 255, 0))
    out = ROOT / "tmp" / "mk1throne"
    out.mkdir(parents=True, exist_ok=True)
    sheet.save(out / "preview.png")
    print(f"wrote {out / 'preview.png'}  ({', '.join(str(c) for c in cams)})")


# --------------------------------------------------------------------------
def report(L):
    rec = L["rec"]
    print(f"THE THRONE ROOM (MK1) - stage record {THRONE_MOD:08X}, table entry {THRONE_ENTRY}")
    print(f"  erase {rec['erase']:04X}  ground {rec['ground']} (MK2 {ground_y(L)})  "
          f"camera y {rec['worldy']}  start x {rec['start']}  limits {rec['left']}..{rec['right']}")
    print(f"  shadow: fast {SHADOW_FAST}, NO clip - init_bakmods' 255/255 stands "
          "(nothing here for a shadow to fall off)")
    print("  planes:")
    for m in L["mods"]:
        print(f"    {m['plane']}  {mod_label(m):8s} {m['w']:5d}x{m['h']:<4d} at ({m['x']:4d},{m['y']:4d})  "
              f"rate {m['rate']:06X}  {len(m['blks']):3d} blocks   {PLANE_NOTE[m['plane']]}")
    print(f"  art: {len(L['order'])} header entries, {len(L['uniq'])} payloads "
          f"({len(L['share'])} share a SAG with another, as MK1 does), {len(L['pals'])} palettes")
    for i, j in sorted(L["share"].items()):
        im = L["imgs"][i]
        print(f"    {i:02X} reuses {j:02X}  ({im['w']}x{im['h']}, "
              f"~{cave.packed_bits(im) // 8:,d} B saved)")
    groups, used = deal(L)
    for (name, s, e, bank), g, u in zip(PACKS, groups, used):
        print(f"  {name} bank {bank} {s:06X}..{e:06X} ({e - s:,} B): "
              f"{len(g):2d} images, ~{u // 8:,} B estimated ({100 * u / 8 / (e - s):.0f}%)")
        snap = LOAD2 / f"BGNDTBL.{name[-3:]}"
        if snap.exists():
            hdrs = cave.read_hdrs(snap)
            if len(hdrs) == len(g):
                real = max(cave.sag_phys(a) + (cave.packed_bits(L["imgs"][i]) + 7) // 8
                           for i, (_w, _h, a, _c) in zip(g, hdrs)) - s
                print(f"    LOAD2 wrote up to +{real:,} B ({100 * real / (e - s):.0f}% of the slot)")
    print(f"  total ~{sum(used) // 8:,} B of video ROM")
    try:
        S = shang(L["rom"])
    except SystemExit as e:
        print(f"  Shang Tsung on the throne: {e}")
        return
    entries = shang_entries(S)
    drawn = set(shang_drawn(S))
    by = {S["names"][x]: im for x, im in S["recs"].items()}
    tot = sum(cave.packed_bits(by[n]) for n in drawn)
    print(f"  Shang Tsung on the throne (data/{SHANG_IMG.name}, --shang): "
          f"{len(entries)} records in the IMG, {len(drawn)} packed, {S['depth']}bpp on "
          f"{SHANG_PAL_NAME} ({len(S['pal'])} entries), ~{tot // 8:,} B")
    print(f"    world ({S['xy'][0]},{S['xy'][1]}) drawn against PLANE 4 - screen "
          f"({S['xy'][0] - plane_x(L, L['rec']['start'])[4]},"
          f"{S['xy'][1] - L['rec']['worldy']}) at the start camera")
    print(f"    tracking: every {SHANG_RATE} ticks, bucket = min(|{SHANG_MID}-camera|/"
          f"{SHANG_STEP}, {SHANG_MAXB}); camera <= {SHANG_FLAT} takes bucket 3")
    print(f"    clap: MK1's round-end hook table {SHANG_HOOKS:08X} claps on stages "
          f"{THRONE_ENTRY} and 7 only; lane {SHANG_LANE:08X}, "
          f"{SHANG_CLAP_RATE} ticks a frame, ~{SHANG_CLAP_FRAMES} frames, "
          f"{SHANG_CLAP_DELAY} ticks after the round is decided")
    for nm, ax, ay, w, h, _px, _pi in entries:
        note = "packed" if nm in drawn else "IMG only - MK1's build pose, never drawn"
        print(f"    {nm:13s} {w:3d}x{h:<3d} ani({ax:4d},{ay:4d})  {note}")
    print("    poses (each list runs front to back; the last is always the lap):")
    for tag, h, lst in S["poses"]:
        print(f"      {tag:6s} {h:08X}  " + " ".join(S["names"][x] for x in lst))
    groups, used = shang_deal(S)
    for (name, s0, e0, bank), g, u in zip(SHANG_PACKS, groups, used):
        print(f"    {name} bank {bank} {s0:06X}..{e0:06X} ({e0 - s0:,} B): {len(g):2d} records, "
              f"~{u // 8:,} B ({100 * u / 8 / (e0 - s0):.0f}%)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parts", action="store_true", help="write the pack BDB/BDDs and LODs")
    ap.add_argument("--apply", action="store_true", help="write src/MK1THRNB.ASM")
    ap.add_argument("--check", action="store_true", help="Phase D: compare instead of write")
    ap.add_argument("--report", action="store_true", help="MK1's numbers, the deal and pack sizes")
    ap.add_argument("--preview", nargs="*", type=int, metavar="CAMX",
                    help="render tmp/mk1throne/preview.png")
    ap.add_argument("--shang", action="store_true",
                    help="write data/MK1TRSH.IMG - MK1's seated Shang Tsung")
    ap.add_argument("--shang-png", nargs="?", const="tmp/mk1throne/shang", metavar="DIR",
                    help="render his eight poses and two stage composites")
    a = ap.parse_args()
    if not any((a.parts, a.apply, a.check, a.report, a.shang,
                a.shang_png, a.preview is not None)):
        ap.error("one of --parts / --apply / --check / --report / --preview / "
                 "--shang / --shang-png")

    L = layout()
    if a.report:
        report(L)
    if a.preview is not None:
        preview(L, a.preview)

    if a.shang or a.shang_png:
        S = shang(L["rom"])
        if a.shang:
            SHANG_IMG.write_bytes(shang_img(S))
            print(f"wrote data/{SHANG_IMG.name}  ({SHANG_IMG.stat().st_size:,} bytes, "
                  f"{len(S['recs'])} records + {SHANG_PAL_NAME})")
        if a.shang_png:
            shang_png(L, S, ROOT / a.shang_png if not Path(a.shang_png).is_absolute()
                      else Path(a.shang_png))

    files = {}
    if a.parts or a.check:
        files.update(part_files(L))
        files.update(lod_files(L))
    if a.parts:
        for nm, data in files.items():
            (DATA / nm).write_bytes(data)
            print(f"wrote data/{nm}  ({len(data):,} bytes)")

    asm = None
    if a.apply or a.check:
        hdrs = merged_headers(L)
        bad = verify_rom(L, hdrs)
        if bad:
            raise SystemExit("THE THRONE ROOM's art is not MK1's:\n  " + "\n  ".join(bad))
        asm = build_asm(L, hdrs)
        if a.apply:
            OUT_ASM.write_text(asm, encoding="latin-1")
            print(f"wrote {OUT_ASM.relative_to(ROOT)}  ({len(asm.splitlines())} lines)")

    if a.check:
        drift = []
        for nm, data in files.items():
            p = DATA / nm
            if not p.exists():
                drift.append(f"data/{nm} missing - run tools/make_mk1throne.py --parts")
            elif p.read_bytes() != data:
                drift.append(f"data/{nm} is not the tool's - rerun --parts")
        # data/MK1TRSH.IMG is a pure decode of MK1's ROM, so it is checked like
        # the rest.  If it is ever opened in IMGTOOL and repainted on purpose,
        # drop these four lines - that is what keeps data/KATPAL.IMG and
        # data/FXPALS.IMG out of Phase D.
        want_img = shang_img(shang(L["rom"]))
        if not SHANG_IMG.exists():
            drift.append(f"data/{SHANG_IMG.name} missing - run --shang")
        elif SHANG_IMG.read_bytes() != want_img:
            drift.append(f"data/{SHANG_IMG.name} has drifted from mk.zip - rerun --shang")
        if not OUT_ASM.exists():
            drift.append(f"{OUT_ASM.relative_to(ROOT)} missing - run --apply")
        elif OUT_ASM.read_text(encoding="latin-1") != asm:
            drift.append(f"{OUT_ASM.relative_to(ROOT)} has drifted from the tool - rerun --apply")
        if drift:
            raise SystemExit("THE THRONE ROOM (MK1) check FAILED:\n  " + "\n  ".join(drift))
        print("THE THRONE ROOM (MK1): packs, LODs, tables and packed pixels all match mk.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
