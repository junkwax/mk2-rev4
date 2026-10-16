#!/usr/bin/env python3
r"""MK1 KANO on the Wolf build (ochar 22, Shang Tsung's morph) - the pack and
his animation lanes.

ART.  --rip writes his libraries, data/KANO<n>.IMG, laid out like Liu Kang's
KANG<n>.IMG: every frame under Liu Kang's name, a solid record plus its
subframes (see "HOW HIS ART IS LAID OUT" below).  The pixels are MK1's, out of
mk.zip (tools/make_mk1kano.py).  data/KANOMORPH.IMG (Shang's morph into him,
KANOSHANG1-3) is copied to data/KNMORPH.IMG, because LOAD2 is a DOS program
and cannot open a nine-letter name.  All of it is ONE pack, data/MK1KNO.LOD,
linear 0xEB4000, POF>: every piece is drawn in the palette its object
carries (his costume, or the morph palette).

LANES.  MK1's lanes are not in MK2's TABLE1 order, and MK2's move code
depends on each lane's SHAPE - how many parts, where a part ends, which
frame a strike checks on - not on its art.  So his TABLE1 is LIU KANG's,
copied lane for lane with every part, jump and adjustment intact, and every
Liu Kang frame in it swapped for an MK1 Kano frame: the lane's distinct
frames, in order, are resampled across the MK1 frames ROWS names for that
row (a few rows map frame by frame, FIXED).  Which MK1 lane is which move
was settled by matching data/KANO.IMG's NAMED frames (KOHIKICK, KOUPPERCUT,
KOCANNONBALL...) against his lanes by silhouette, 1.00 IoU for every move
it names, and by eye for the rest (tmp/mk1kano/*.png).

His fatality-victim rows (TEMPLATE_ROWS) are Liu Kang's lanes on LIU
KANG'S OWN FRAMES, recoloured into KANO1_P: MK1 drew no torso, legs or head
of him, so they are placeholders to repaint.

    python tools/make_mk1kano_port.py --rip      # rewrite data/KANO<n>.IMG (overwrites repaints)
    python tools/make_mk1kano_port.py --lod      # data/MK1KNO.LOD + KNMORPH.IMG from the libraries
    python tools/make_mk1kano_port.py --apply    # write src/MK1KNL.ASM
    python tools/make_mk1kano_port.py --check    # Phase D: both are current
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_cage_logo as cl          # noqa: E402
import make_mk1pit as pit            # noqa: E402
from make_umk3sonya_asm import blocks, tokens, rename_line   # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
OUT = SRC / "MK1KNL.ASM"
LOD = DATA / "MK1KNO.LOD"
BASE = 0x55A0000                      # linear 0xEB4000
PARTS = "ABC"
# HIS ART LIBRARIES, laid out the way Midway laid out every MK2 fighter's
# (CAGE1-10.IMG: stance and walks, punches, kicks, ducking, the air, hits,
# falls and throws, specials, victory and finishers).  A piece is named after
# the MK1 lane that draws it FIRST - KN<move><frame><piece> - and lives in
# that lane's library.  These libraries are the SOURCE: repaint them in
# IMGTOOL, then --lod; only --rip rewrites them out of data/MK1KANO.IMG.
LIBS = [
    ("KANO1", {"00": "STANCE", "01": "WALK", "02": "SKIPF", "03": "WALKB", "04": "SKIPB",
               "10": "TURN"}),
    ("KANO2", {"39": "HIPUNCH", "3A": "HIPUNCHB", "3B": "HIPUNCHC", "11": "PUNCHD", "12": "PUNCHE",
               "13": "LOPUNCH", "14": "LOPUNCHB", "15": "LOPUNCHC", "16": "LOPUNCHD", "17": "LOPUNCHE",
               "1D": "ELBOW"}),
    ("KANO3", {"26": "HIKICK", "3D": "LOKICK", "24": "KNEE", "36": "ROUNDH", "0D": "SWEEP"}),
    ("KANO4", {"05": "DUCK", "08": "CROUCH", "0C": "DUCKTURN", "2C": "DUCKBLOCK", "0B": "DUCKPUNCH",
               "37": "DUCKKICK", "2E": "DUCKHIT", "0A": "UPPERCUT", "38": "BLOCK"}),
    ("KANO5", {"06": "JUMP", "07": "JUMPGO", "0E": "FLIPF", "0F": "FLIPB", "1C": "JUMPKICK",
               "28": "FLYKICK", "27": "FLYPUNCH"}),
    ("KANO6", {"33": "HIHIT", "34": "LOHIT", "35": "STUMBLE", "2D": "SHAKE", "2A": "KNOCKDOWN",
               "25": "SWEEPFALL", "20": "GETUP", "31": "GETUPB", "30": "BIGFALL", "3E": "FALL",
               "4E": "FLOWN", "4F": "IMPALE", "44": "DEAD", "45": "DEADB", "50": "DEADC"}),
    ("KANO7", {"1E": "THROW", "41": "STUNNED", "4D": "REEL", "46": "FLIPPED", "47": "FLIPPEDB",
               "48": "FLIPPEDC", "49": "FLIPPEDD", "4A": "FLIPPEDE", "4B": "FLIPPEDF", "4C": "FLIPPEDG"}),
    ("KANO8", {"21": "KNIFETHROW", "22": "KNIFE", "23": "KNIFEHIT", "29": "BALLGO", "2B": "BALL"}),
    ("KANO9", {"40": "VICTORY", "42": "HEARTRIP", "43": "HEART"}),
]
LANE_NAME = {lane: (lib, mv) for lib, m in LIBS for lane, mv in m.items()}


# pieces drawn as objects of their own (the knife, its impact, the heart's
# drips) are PON>, each on the palette MK1 draws it in - every other piece is POF>.
# THOSE PALETTES ARE MK1's OWN, not his costume.  An MK1 image record carries no
# palette field: the palette is the .long after the FIRST record of a group
# (tools/make_fxpal_img.py).  The knife's group starts at K22_1A itself and
# names FFE9A730, 64 colours, a steel blue-white ramp - exactly what MAME's `mk`
# has loaded in the colour map the knife is blitted with (map 4; Kano's body is
# on map 3 - tools/run_mk1_kano_probe.ps1).  Its impact frames (lane 23h) are
# drawn on that same map.  The heart's drips (lane 43h) are a group of their own
# 148 bytes before K43_1A, naming FFEA7C00: 12 blood reds, and the art indexes
# 0-11 of it.  Drawn in KANO1_P, as they were, the blade came out red and orange.
OWN_PALS = {"KNKNIFE_P": ("K22_1A", 0xFFE9A730, ("K22_", "K23_")),
            "KNHEART_P": ("K43_1A", 0xFFEA7C00, ("K43_",))}
# the knife's impact: MK1's lane 23h opens with ADJX -128 (MAME: 64 px back),
# which lands it on the victim's front edge.  Here the IMPACT IS CENTRED ON THE
# VICTIM'S BODY instead, measured each time (kn_knife_centre, MK1KNM.ASM), so
# it always ends in his chest whatever the distance - the user's call.

# MK2 TABLE1 row -> MK1 lane (or lane[slice]) whose frames stand in for
# Liu Kang's.  lane names are MK1's table indices, hex.
ROWS = {
    0x00: ("00",), 0x01: ("01",), 0x02: ("02",), 0x03: ("03",), 0x04: ("04",),
    # 05 duck: MK1's duck is 07h (down 1-2, HOLD 3 - measured), and 08h stands
    # him up; 05h is his JUMP take-off, which the first port had here - he
    # never crouched
    0x05: ("07",), 0x06: ("06",), 0x07: ("0E",), 0x08: ("0F",), 0x09: ("10",),
    # 0b block: MK1's lane 38h is raise 1-2-3 | lower | hit-shake | lower;
    # resampling the WHOLE lane put frame 5 (arms coming down) on the hold -
    # the guard dropped while held.  Only the raise: 1, 2, HOLD 3.
    # 0c duck block: 2Ch is 1-2-1 with 1 the held guard - raise on 2, hold 1.
    0x0A: ("0C",), 0x0B: ("38", 0, 3), 0x0C: ("2C", 1, 3),
    0x0D: ("26", 0, 4),          # hi kick: stance .. full extension (KOHIKICK4)
    0x0E: ("3D", 0, 5),          # lo kick: .. KOLOKICK1
    # 10 hit high / 11 hit low: MK1 plays 34h when he is hit HIGH (punches,
    # high kicks) and 33h when hit LOW (measured, tools/mk1_kano_timing.py) -
    # the first port had them the other way round
    0x0F: ("2A",), 0x10: ("34",), 0x11: ("33",), 0x12: ("20",),
    # WHICH LANE IS WHICH MOVE was measured in MAME `mk` (tools/run_mk1_kano_probe.ps1
    # -TwoPlayer -Moves2 / -Swept: direction held FIRST, or MK1 reads none):
    # Back+LK plays 25h (the SWEEP), Down+LK 0Dh, Down+LP 0Ah (MK1 has no
    # separate crouching jab: it is the uppercut), and being swept plays 30h
    # then the 20h get-up.  The first port guessed these by eye and had 0Dh as
    # the sweep and 25h - his sweep KICK - as his sweep FALL.
    0x13: ("39",), 0x14: ("13",), 0x15: ("25",),
    0x16: ("30", 0, 6),          # swept: down to the floor
    0x17: ("20",),               # swept: get up
    0x18: ("0A",), 0x19: ("0D",), 0x1A: ("0D",), 0x1B: ("2E",),
    # 1f flip punch: 27h is the punch (1-2) and then the flip kick's own
    # frames - only the punch
    0x1C: ("0A",), 0x1D: ("1C",), 0x1E: ("28",), 0x1F: ("27", 0, 3),
    0x20: ("36",), 0x21: ("24",), 0x22: ("1D",), 0x23: ("35",), 0x24: ("1E",),
    0x25: ("30",),               # shredded: the big fall
    0x26: ("21",),               # throwing (the knife)
    0x27: ("22",),               # projectile (the knife, spinning)
    0x28: ("41",), 0x29: ("40",),
    **{r: ("46",) for r in range(0x2A, 0x36)},     # flipped by ...
    0x36: ("34",), 0x37: ("4E",), 0x38: ("41",), 0x39: ("3E",), 0x3A: ("4E",),
    0x3B: ("4F",), 0x3C: ("3E",), 0x3D: ("00", 0, 1), 0x3E: ("46",), 0x3F: ("4E",),
    0x40: ("3E",), 0x41: ("3E",), 0x42: ("13",),
}
# (THE HIT REACTIONS: Liu Kang's lane is 2-3-2-1 on three frames where MK1 plays
# four distinct poses 1-2-3-4 (tools/mk1_kano_timing.py).  The port used to fill
# the lane's slots with MK1's four in order; with Liu Kang's names there are
# three frames, so the lane plays his shape on three of MK1's poses.)
# Liu Kang frame -> (lane, frame) where resampling would pick the wrong pose
FIXED = {
    # the sweep, part for part: 25h kicks out on 1-5 (5 held, the strike) and
    # comes back on 6-8; Liu Kang's lane ends part 1 on its strike frame
    "LKSWEEPKIK1": ("25", 0), "LKSWEEPKIK2": ("25", 1), "LKSWEEPKIK3": ("25", 2),
    "LKSWEEPKIK4": ("25", 3), "LKSWEEPKIK5": ("25", 4),
    "LKSWEEPKIK6": ("25", 5), "LKSWEEPKIK7": ("25", 6),
    # swept: 30h falls on 1-5 and lies FLAT on 6 (MK1 holds 6, with 45h's
    # dead pose); the get-up (20h) starts from there
    "LKSWEEPFALL1": ("30", 0), "LKSWEEPFALL2": ("30", 1), "LKSWEEPFALL3": ("30", 3),
    "LKSWEEPFALL4": ("30", 5),
    # duck block: MK1 raises on 2Ch frame 2 and HOLDS frame 1 (= 3)
    "LKDUCKBLOCK1": ("2C", 1), "LKDUCKBLOCK2": ("2C", 1), "LKDUCKBLOCK3": ("2C", 0),
    # crouching kick - Down + HK AND Down + LK (the user's call: MK1 Kano has
    # no separate low jab kick).  0Dh is out 1-2-3, back 4-5, then 6; part 1
    # (where the strike is checked) must END on 3, the full extension
    "LKDUCKIKHI1": ("0D", 0), "LKDUCKIKHI2": ("0D", 1), "LKDUCKIKHI3": ("0D", 1),
    "LKDUCKIKHI4": ("0D", 2), "LKDUCKIKLO1": ("0D", 1), "LKDUCKIKLO2": ("0D", 2),
    "LKTURN1": ("10", 1), "LKTURN2": ("10", 2),
    "LKJUMP1": ("05", 1), "LKJUMP2": ("06", 1), "LKJUMP3": ("06", 0),
}
# lanes that are MK1's OWN shape rather than Liu Kang's resampled (0 = end of
# a part).  THE THROW (row 24h): Liu Kang's is a roll-back monkey flip that
# ends on his back and jumps to the get-up, so Kano dropped to the floor and
# climbed up out of a throw MK1 does STANDING.  MK1's, measured in MAME `mk`
# (run_mk1_kano_probe.ps1 -Moves2): 1Eh 1,2 grab - 3,4,5,6 lift him overhead
# and hurl him over his back - 5 held while he flies - stance.  The victim is
# thrown BARAKA's way (MKSLAM.ASM body_slam_init: lane "flipped by sword arms"
# + tossed_flight), so the parts are Baraka's shape: 1 grab | 3 throw | rest.
OWN_LANES = {
    "a_lkbodyslam": [("1E", 1), 0,
                     ("1E", 2), ("1E", 3), ("1E", 5), 0,
                     ("1E", 4), ("1E", 4), 0],
}
# his TABLE2 - the specials, MK1's own lanes.  Each entry: (label, [part,
# part...], loop) where a part is a list of (lane, frame) and loop is the
# frame the last part jumps back to (None: it ends 0).
def _f(lane, *ix):
    return [(lane, i) for i in ix]


# THE KNIFE'S LANES are cut the way MK1 PLAYS lane 22h, measured frame by frame
# in MAME `mk`: its first three frames are the knife IN HIS HAND, shown with
# body frames 2-4 of the throw at 3 ticks each (kn_a_knifehand); frame 4 is the
# release, held still 3 ticks with body frame 5; then it flies at 9 px a tick,
# frame 5 for two ticks and 6-13 one tick each, looping back to 6.  The old cut
# looped all 13 - wind-up included - after the throw had ended.  The impact
# (lane 23h) is three frames of 8 ticks, KNIFE_HIT_BACK behind the knife.
TABLE2 = [
    ("kn_a_knifethrow", [_f("21", 0, 1, 2, 3, 4), _f("21", 5)], None),   # 0 - lean, wind up, throw
    ("kn_a_knife", [_f("22", 3, 4, 4, *range(5, 13))], 3),               # 1 - released, then spinning
    ("kn_a_knifehit", [_f("23", 0, 1, 2)], None),                        # 2 - it hits
    # 3 - THE CANNONBALL, as MK1 plays it: ALREADY CURLED (2Bh 1), then 2-8
    # looping at 2 ticks.  The uncurl (29h) comes at the END (row 7); the
    # first port played it first.
    ("kn_a_ball", [_f("2B", *range(8))], 1),
    ("kn_a_heartrip", [_f("42", 0, 1, 2), _f("42", 3, 4, 5, 6, 7)], None),   # 4 - punch in / heart up
    # 5 - THE HEART, an object of its own in his raised hand (lane 43h): torn
    # out dripping, frames 1-5 beside body frames 4-8 at 10 ticks; then it
    # BEATS - 6, 7, 5 on MK1's 42-tick cycle (do_kn_heart, MK1KNM.ASM)
    ("kn_a_heart", [_f("43", 0, 1, 2, 3, 4), _f("43", 5, 6, 4)], 6),
    ("kn_a_knifehand", [_f("22", 0, 1, 2)], None),                       # 6 - the knife in his hand
    ("kn_a_unball", [_f("29", 0)], None),                                # 7 - out of the ball
]
# HIS NORMALS, TIMED THE WAY MK1 PLAYS THEM (MAME `mk`,
# tools/mk1_kano_timing_probe.lua: a hit run at close range and a WHIFF run at
# 110 px, read by tools/mk1_kano_timing.py).  Played by kn_normal (MK1KNM.ASM)
# in place of MK2's do_* routine - his whole move, not Liu Kang's lane at
# Liu Kang's speeds.  Each move: (label, action, kano_strikes index, sound,
# [(lane, frame, whiff ticks, hit ticks, strike-check ticks), ...]).  A frame
# lasts its WHIFF ticks until the move connects, its HIT ticks from then on:
# (each move's LAST frame is a tick short: the way back to his stance
# draws it one more.)  MK1's hit pause is the extension frame held longer (HK 6 -> 20, uppercut
# 7 -> 49) and the sweep's recovery runs slower after a hit (5 -> 8).
#
# The duck kick is ONE kick in MK1 (Down + HK or LK) and carries its whole
# retract: joy_duck_kickh/_kickl (JOY.ASM) send him through kn_duck_kick, which
# skips MK2's own sleep-and-retract tail and goes to post_joy_duck_kick.
def _n(lane, i, w, h=None, c=0):
    return (lane, i, w, w if h is None else h, c)


NORMALS = [
    ("kn_n_hikick", "act_hikick", 0, "kick_sounds",
     [_n("26", 0, 2), _n("26", 1, 2), _n("26", 2, 2), _n("26", 3, 6, 20, 6),
      _n("26", 4, 4), _n("26", 2, 4), _n("26", 1, 4), _n("26", 0, 4)]),
    ("kn_n_lokick", "act_medkick", 1, "kick_sounds",
     [_n("26", 0, 2), _n("26", 1, 2), _n("26", 2, 2), _n("3D", 3, 2), _n("3D", 4, 6, 20, 6),
      _n("3D", 5, 4), _n("3D", 3, 4), _n("26", 2, 4), _n("26", 1, 4), _n("26", 0, 4)]),
    ("kn_n_elbow", "act_elbow", 0x0f, "kick_sounds",
     [_n("1D", 0, 8), _n("1D", 2, 22, 22, 6), _n("1D", 3, 8)]),
    ("kn_n_knee", "act_knee", 0x0e, "kick_sounds",
     [_n("24", 0, 3), _n("24", 1, 3), _n("24", 2, 23, 23, 6), _n("24", 1, 6), _n("24", 0, 6)]),
    ("kn_n_uppercut", "act_uppercut", 8, "kick_sounds",
     [_n("0A", 0, 3), _n("0A", 1, 3), _n("0A", 2, 3), _n("0A", 3, 3), _n("0A", 4, 7, 49, 7),
      _n("0A", 5, 4)]),
    ("kn_n_duckkickh", "act_duck_kickh", 6, "kick_sounds",
     [_n("0D", 0, 3), _n("0D", 1, 3), _n("0D", 2, 16, 19, 5), _n("0D", 1, 4), _n("0D", 0, 4)]),
    ("kn_n_duckkickl", "act_duck_kickl", 7, "kick_sounds",
     [_n("0D", 0, 3), _n("0D", 1, 3), _n("0D", 2, 16, 19, 5), _n("0D", 1, 4), _n("0D", 0, 4)]),
    ("kn_n_sweep", "act_sweep", 4, "sweep_sounds",
     [_n("25", 0, 3), _n("25", 1, 3), _n("25", 2, 3), _n("25", 3, 3), _n("25", 4, 4, 11, 4),
      _n("25", 5, 5, 8), _n("25", 6, 5, 8), _n("25", 7, 5, 8)]),
    ("kn_n_roundh", "act_rhouse", 0x0d, "kick_sounds",
     [_n("36", 0, 3), _n("36", 1, 3), _n("36", 2, 4, 13, 4), _n("36", 3, 5), _n("36", 4, 5),
      _n("36", 5, 5), _n("36", 6, 5)]),
]
# HIS REACTIONS, the same way: played by kn_normal from MK2's own reaction
# code when HE is the one hit (MKREACT.ASM, under .if wunit), with no strike
# (check ticks 0).  STOP is stop_me: his slide ends there, which is what sets
# the distance (MK1: 65 px on a high kick; stopping after 35h 4 gives ~66).
#   kn_r_hikicked  hikicked_entry: MK1's big-hit stagger, lane 35h - 34h's 2
#                  and 3, then 35h's own 3-8, 4 ticks each
#   kn_r_sweep     r_sweep's fall: lane 30h 1-6 at 6 ticks.  Liu Kang's lane
#                  is 4 frames at 5 and STAYS so: Jade's impale and the double
#                  knee pick frames out of row 16h BY POSITION.  The bounce (30h
#                  5) is 2 ticks here and 4 more on kn_a_sweepbounce, r_sweep's
#                  own rate for the rest of the fall - MK1's 6
STOP = ("STOP", 0, 0, 0, 0)
REACTS = [
    ("kn_r_hikicked", "act_reacting", 0, "0",
     [_n("34", 1, 4), _n("34", 2, 4), _n("35", 2, 4), _n("35", 3, 4), _n("35", 4, 4), STOP,
      _n("35", 5, 4), _n("35", 6, 4), _n("35", 7, 4)]),
    ("kn_r_sweep", "act_reacting", 0, "0",
     [_n("30", i, 6) for i in range(6)] + [_n("30", 4, 2)]),
]
SWEEP_BOUNCE = ("30", 4)
# the do_* routine each one replaces, in kn_normal's table order
NORMAL_OF = {"do_hi_kick": "kn_n_hikick", "do_lo_kick": "kn_n_lokick", "do_elbow": "kn_n_elbow",
             "do_knee": "kn_n_knee", "do_uppercut": "kn_n_uppercut", "do_duck_kickh": "kn_n_duckkickh",
             "do_duck_kickl": "kn_n_duckkickl", "do_sweep_kick": "kn_n_sweep",
             "do_roundhouse": "kn_n_roundh"}


# HOW HIS ART IS LAID OUT (the user's call, 2026-10-11): THE WAY MIDWAY LAID OUT
# EVERY MK2 FIGHTER.  Every frame carries LIU KANG'S NAME - MKLK.ASM's frame
# list: LKSTANCE1-7 -> KNSTANCE1-7, LKHIKIK1-6 -> KNHIKIK1-6 - as a SOLID record
# (the whole frame, never packed) plus its SUBFRAMES KNSTANCE1A, B, C..., as
# many as Liu Kang's frame has, cut by IMGTOOL's Auto Split
# (tools/kano_subframes.py auto_split).  Each lives in the library Liu Kang's
# does (KANG<n>.IMG -> KANO<n>.IMG).  A frame is FILLED with the MK1 pose
# ROWS/FIXED map onto it; the first row to name a frame decides its pose.
# His specials (knife, cannonball, heart rip) are moves of their own with names
# of their own (OWN_MOVES, KN<move><n>, every distinct pose of the lane); an MK1
# pose his MK1-timed normals play that no Liu Kang frame shows is re-pointed to
# the nearest pose of that lane that has one.  THE LIBRARIES ARE THE SOURCE once
# --rip has written them: repaint, or re-cut (a frame's pieces are <name>A..Z),
# in IMGTOOL, then --lod.  Only --rip rewrites them.
HEAD = ("KNHEAD1",)
OWN_MOVES = ("21", "22", "23", "29", "2B", "42", "43")

# THE DEFAULTS MK1 NEVER DREW: the TABLE1 rows a fatality plays on its VICTIM -
# nut crunch, drained, torso rip, impaled, decap fall and head, back break,
# head hole, swipe torso.  They were LIU KANG'S OWN ART recoloured into KANO1_P
# (2026-10-11); now (the user's call, the same day) every one of them is BUILT
# OUT OF KANO's MK1 ART by tools/kano_synth.py - another pose of his, MK1's own
# headless body and severed head, poses tilted and cut, guts painted on - and
# placed where Liu Kang's frame of that name sat relative to Liu Kang's stance.
# A frame kano_synth has no recipe for still falls back to Liu Kang's art.  A
# frame such a row shares with an earlier row (his stumble, stunned poses)
# keeps its MK1 pose.
TEMPLATE_ROWS = (0x36, 0x38, 0x39, 0x3B, 0x3C, 0x3D, 0x3F, 0x40, 0x41)
TEMPLATE_SRC = ("KANG*.IMG", "MKSOUL.IMG")       # where Liu Kang's records live

# frame name -> ("mk1", MK1 frame, piece count or None, lib)
#             | ("lk", [Liu Kang pieces], lib) | ("rec", Liu Kang record, lib)
#             | ("syn", kano_synth key, piece count, lib)      (a multipart frame)
#             | ("synrec", kano_synth key, None, lib)          (one record: the rolling head)
CONTENT = {}
_SYN = {}
SYNTH_META = {}       # kano_synth's records / palettes / PON> set / generated palettes

# THE SECOND BATCH (the user's call, 2026-10-13): per-fighter tables outside
# TABLE1 that pointed Kano at WHOLE LIU KANG ANIMATIONS - each copied here
# under its Kano name with every frame his own (kano_synth.Synth.extras), and
# tools/wolf_fighter_rows.py's KANO overrides point his rows at them.
# (Liu Kang's module, his label, Kano's label)
EXTRA = [
    ("MKDEATH.ASM", "a_lk_arm_fly", "kn_a_arm_fly"),          # Jax's arm rip: the arm
    ("MKDEATH.ASM", "lk_superf", "kn_superf"),                # Sub-Zero's deep freeze
    ("MKDEATH.ASM", "lk_frozen_legs", "kn_frozen_legs"),      # ...the legs left standing
    ("MKDEATH.ASM", "a_lk_split", "kn_a_split"),              # Kung Lao's split
    ("MKDIE.ASM", "a_lk_sucked_in", "kn_a_sucked_in"),        # Mileena's suck
    ("MKFALL.ASM", "a_lk_fall", "kn_a_pitfall"),              # the Pit
    ("MKFX.ASM", "a_lkdrained", "kn_a_husk"),                 # Shang's drain: the husk
                                                              # (kn_a_drained is TABLE1's a_drained)
    ("MKLK.ASM", "a_lk_kslammed", "kn_a_kslammed"),           # Shao Kahn's slam
    ("MKLK.ASM", "a_lk_ksoulrip", "kn_a_ksoulrip"),           # Shao Kahn's soul rip
    ("MKNJ.ASM", "a_sz_head_lk", "kn_a_sz_head"),             # Sub-Zero's head rip: the head
    ("MKRDLIF.ASM", "rd_lift_vic_script_lk", "kn_rd_lift_script"),   # Raiden's lift
]
# labels other modules name (wolf_fighter_rows' KANO rows): exported
EXTRA_GLOBALS = ("KNSTUMBLE1", "KNFLIPPED2", "KNBACKBREAK3", "KNKNOCKDOWN7", "KNBABE",
                 "KNDRAIN_P", "SOULGRN_KN")


def piece_base(name):
    """The record-name stem of a frame's pieces.  A lane-local frame label is
    lower case (kn_ERT_TORSO1) and the LOD only collects names that start
    with a capital, so its pieces are KNERTTORSO1A..."""
    return name if not name.startswith("kn_") else "KN" + name[3:].replace("_", "")


def syn_kn(key):
    """kano_synth's name for a frame or piece -> the record/label name here."""
    return "kn_" + key if key.startswith("ERT_") else "KN" + key


# kano_synth's key -> the label of the Liu Kang frame it stands in for, where
# that is not "LK" + the key (the second batch lives all over src/)
LK_ALIAS = {"superf": "lk_superf", "szhlk": "f_szhlk", "szh": "f_szhlk",
            **{f"SUCK{n}": f"SUCK_LIUKANG{n}" for n in range(1, 8)}}
_ANY = {}


def any_records():
    """Every IMG record in data/ whose geometry matches the linked src/*.TBL
    (or that no TBL carries): name -> (record, palette words)."""
    if not _ANY:
        tbl = {}
        for f in SRC.glob("*.TBL"):
            for n, w, h, ax, ay in re.findall(r"^(\w+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)",
                                              f.read_text(encoding="latin-1"), re.M):
                tbl.setdefault(n, (int(w), int(h), int(ax), int(ay)))
        for f in sorted(DATA.glob("*.IMG")):
            try:
                recs, pals = cl.parse_img(f.read_bytes())
            except Exception:
                continue
            for n, r in recs.items():
                g = tbl.get(n)
                if n not in _ANY and (g is None or g == (r["w"], r["h"], r["ax"], r["ay"])):
                    _ANY[n] = (r, pals[r["palnum"]]["words"] if r["palnum"] in pals else None)
    return _ANY


_ASMSRC = []


def any_pieces(label):
    """A frame label's piece list, from whichever src/*.ASM defines it (the list
    may start on the label's line or the next, and run over several), or
    [label] when it is a record."""
    if not _ASMSRC:
        _ASMSRC.append("\n".join(f.read_text(encoding="latin-1") for f in sorted(SRC.glob("*.ASM"))))
    m = re.search(r"^" + re.escape(label) + r"\b[ \t]*(?:;[^\n]*)?\n?((?:[ \t]*\.long[^\n]*\n?)+)"
                  r"|^" + re.escape(label) + r"[ \t]+(\.long[^\n]*)", _ASMSRC[0], re.M | re.I)
    if not m:
        return [label]
    body = m.group(1) or m.group(2)
    ps = []
    for ln in body.splitlines():
        for t in re.findall(r"\w+", re.sub(r"\.long", "", ln.split(";")[0], flags=re.I)):
            if t == "0":
                return ps
            ps.append(t)
    return ps


def lk_label(name):
    return LK_ALIAS.get(name, name if name.startswith("ERT_") else "LK" + name)


def lk_ref(name):
    """Liu Kang's frame `name` (no LK prefix), composited: (canvas, ax, ay)."""
    import kano_subframes as ks
    import numpy as np
    bl, index = lk_source()
    f = lk_label(name)
    if f in lk_records() and f not in index:
        ps = [f]
    elif f in index:
        ps = lk_pieces(bl, index, f)
    else:
        ps = any_pieces(f)
    rs = []
    for p in ps:
        r = lk_records()[p][0] if p in lk_records() else any_records()[p][0]
        rs.append(dict(w=r["w"], h=r["h"], ax=r["ax"], ay=r["ay"],
                       px=bytes(v for row in r["px"] for v in row)))
    cv, ax, ay = ks.composite(rs)
    return np.asarray(cv), ax, ay


def lk_pal(name):
    """The palette words Liu Kang's frame `name` is drawn in (its first piece's)."""
    f = lk_label(name)
    p = (any_pieces(f) or [f])[0]
    return lk_records()[p][1] if p in lk_records() else any_records().get(p, (None, None))[1]


def asm_pal(label):
    """A palette's words out of src/*.ASM: `label` [:] then .word count, words."""
    for f in sorted(SRC.glob("*.ASM")):
        t = f.read_text(encoding="latin-1")
        m = re.search(r"^" + re.escape(label) + r":?[ \t]*\n((?:[ \t]*\.word[^\n]*\n)+)", t, re.M)
        if m:
            ws = []
            for ln in m.group(1).splitlines():
                for v in ln.split(";")[0].split(".word", 1)[1].split(","):
                    v = v.strip()
                    ws.append(int(v[:-1], 16) if v[-1:] in "hH" else int(v))
            return ws[1:1 + ws[0]]
    raise SystemExit(f"no palette {label} in src/")


def synth():
    """kano_synth's frames, built once: key -> (canvas, ax, ay, parts | None)."""
    if not _SYN:
        import kano_subframes as ks
        import kano_synth
        import mk1_yunit_extract as mk1x
        P = mk1()
        rom, frames, recs, lanes = P["rom"], P["frames"], P["recs"], P["lanes"]
        byhdr = {mk1x.BASE + v[0] * 8: (s,) + v[1:] for s, v in rom.records().items()}

        def mk1frame(lane, step):
            return ks.composite([recs[a] for a in frames[lanes[lane][step]]])

        def mk1record(addr):
            s, w, h, ax, ay = byhdr[addr]
            return rom.pixels(w, h, s).astype("uint8"), ax, ay
        sy = kano_synth.Synth(mk1frame, mk1record, lk_ref, lk_pal, asm_pal, P["pals"]["KANO1_P"])
        _SYN.update(sy.build())
        SYNTH_META.update(records=sy.records, pal=sy.pal, ownpal=sy.ownpal, palwords=sy.palwords)
    return _SYN


def synth_preview(s, out, only=()):
    """Liu Kang's placeholder beside Kano's built frame, anchors marked, for
    every frame kano_synth makes - out/kano_synth.png."""
    import numpy as np
    from PIL import Image, ImageDraw
    out.mkdir(parents=True, exist_ok=True)
    kp = [(((w >> 10) & 31) * 8, ((w >> 5) & 31) * 8, (w & 31) * 8) for w in mk1()["pals"]["KANO1_P"]]

    def img(cv, ax, ay, pal):
        h, w = cv.shape
        a = np.array([pal[v] if v else (24, 24, 36) for v in cv.flat], np.uint8).reshape(h, w, 3)
        im = Image.fromarray(a).resize((w * 2, h * 2), Image.NEAREST)
        d = ImageDraw.Draw(im)
        d.line((ax * 2 - 5, ay * 2, ax * 2 + 5, ay * 2), fill=(255, 0, 0))
        d.line((ax * 2, ay * 2 - 5, ax * 2, ay * 2 + 5), fill=(255, 0, 0))
        return im
    tiles = []
    for key in sorted(s, key=natural):
        cv, ax, ay, _p = s[key]
        if key.startswith("HOLEHEAD") or key in ("szh",) or re.fullmatch(r"DRAIN\dA", key)                 or (only and not key.startswith(only)):
            continue
        lc, lax, lay = lk_ref(key)
        lp = None
        lw = lk_pal(key) or [0x7fff] * 64
        lpal = [(((w >> 10) & 31) * 8, ((w >> 5) & 31) * 8, (w & 31) * 8) for w in lw] + [(255, 0, 255)] * 256
        pk = SYNTH_META.get("pal", {}).get(key) or next(
            (SYNTH_META["pal"][q] for q in (s[key][3] or []) if q in SYNTH_META.get("pal", {})), "")
        kw = SYNTH_META.get("palwords", {}).get(pk)
        kpal = ([(((w >> 10) & 31) * 8, ((w >> 5) & 31) * 8, (w & 31) * 8) for w in kw] if kw else kp)
        # both on one canvas sharing the anchor, so the placement is visible
        x0, y0 = min(-lax, -ax), min(-lay, -ay)
        x1 = max(lc.shape[1] - lax, cv.shape[1] - ax)
        y1 = max(lc.shape[0] - lay, cv.shape[0] - ay)
        W, H = x1 - x0, y1 - y0
        t = Image.new("RGB", (W * 4 + 12, H * 2 + 14), (0, 0, 0))
        t.paste(img(lc, lax, lay, lpal), ((-lax - x0) * 2, 14 + (-lay - y0) * 2))
        t.paste(img(cv, ax, ay, kpal + [(255, 0, 255)] * 256), (W * 2 + 12 + (-ax - x0) * 2, 14 + (-ay - y0) * 2))
        ImageDraw.Draw(t).text((0, 0), key, fill=(255, 255, 0))
        tiles.append(t)
        del lp
    rows = [tiles[i:i + 4] for i in range(0, len(tiles), 4)]
    W = max(sum(t.width for t in r) for r in rows)
    H = sum(max(t.height for t in r) for r in rows)
    sheet = Image.new("RGB", (W, H), (10, 10, 10))
    y = 0
    for r in rows:
        x = 0
        for t in r:
            sheet.paste(t, (x, y))
            x += t.width
        y += max(t.height for t in r)
    sheet.save(out / "kano_synth.png")
    print(f"wrote {out / 'kano_synth.png'} ({len(tiles)} frames)")
SLOT = {}         # MK1 frame -> the Liu Kang-named frame that shows it
OWN = {}          # MK1 frame -> (own-move name, lib)
_MK1 = {}


def natural(n):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", n)]


# ---------------------------------------------------------------------------
def mk1():
    """mk.zip read through tools/make_mk1kano.py (cached): every lane's frames
    over ALL its parts, each frame's strips, the strip records, the palettes."""
    if not _MK1:
        import make_mk1kano as rip
        rom = rip.mk1.TRom(rip.mk1.ROMS / "mk.zip")
        L, _names, frames, recs, pals = rip.read(rom)
        _MK1.update(rom=rom, frames=frames, recs=recs, pals=pals,
                    lanes={f"{k:02X}": [f for f, _dx, _dy in fr] for k, _a, fr, _s in L})
    return _MK1


def kn_name(lk):
    return "KN" + lk[2:] if lk.startswith("LK") else "kn_" + lk


def own_names():
    """MK1 frame -> (KN<move><n>, lib) for every distinct pose of the OWN_MOVES lanes."""
    if not OWN:
        lanes = mk1()["lanes"]
        for lane in OWN_MOVES:
            for k, f in enumerate(dict.fromkeys(lanes[lane])):
                OWN.setdefault(f, ("KN" + LANE_NAME[lane][1] + str(k + 1), LANE_NAME[lane][0]))
    return OWN


def kn_frame(lane, i):
    """The frame an MK1 (lane, step) is drawn with: the Liu Kang-named frame
    that shows that pose, its own-move frame, or the nearest pose of the lane
    that has a Liu Kang name."""
    lanes = mk1()["lanes"]
    f = lanes[lane][i]
    if lane in OWN_MOVES:      # a special draws its OWN frames, even where MK1 shares
        name, lib = own_names()[f]          # a pose with another lane (the ball's curl is the flip's)
        CONTENT.setdefault(name, ("mk1", f, None, lib))
        return name
    if f in SLOT:
        return SLOT[f]
    near = sorted((abs(j - i), j) for j, g in enumerate(lanes[lane]) if g in SLOT)
    if not near:
        raise SystemExit(f"MK1 lane {lane} has no pose a Liu Kang frame shows")
    return SLOT[lanes[lane][near[0][1]]]


def touch_all():
    """Resolve every frame the generated file names, so CONTENT is complete."""
    for _l, parts, _x in TABLE2:
        for part in parts:
            for f in part:
                if not f[0].startswith("ani_"):
                    kn_frame(*f)
    for _l, _a, _s, _snd, ents in NORMALS + REACTS:
        for e in ents:
            if e[0] != "STOP":
                kn_frame(e[0], e[1])
    kn_frame(*SWEEP_BOUNCE)
    kn_frame("00", 0)
    for f, (name, lib) in own_names().items():      # every pose of a special: the move's count
        CONTENT.setdefault(name, ("mk1", f, None, lib))


# ---------------------------------------------------------------------------
def rip_libs():
    """KANO<n>.IMG - only on --rip.  Every frame CONTENT names: its solid
    record and its subframes; Liu Kang's own art for the TEMPLATE_ROWS."""
    import kano_subframes as ks
    P = mk1()
    rom, frames, recs, pals = P["rom"], P["frames"], P["recs"], P["pals"]
    build()
    touch_all()
    base = [(nm, 6, words) for nm, words in pals.items()]
    ownp, ownw = {}, {}                  # K-name prefix -> palette name; name -> words
    for nm, (head, want, prefixes) in OWN_PALS.items():
        ownw[nm] = own_palette(rom, recs, head, want)
        for pre in prefixes:
            ownp[pre] = nm
    libs = {}

    def lib(n):
        return libs.setdefault(n, {"solid": [], "piece": [], "pals": list(base)})

    def pal_ix(L, nm):
        names = [p[0] for p in L["pals"]]
        if nm not in names:
            L["pals"].append((nm, 6, ownw[nm]))
            names.append(nm)
        return names.index(nm)

    kano = next(w for n, _b, w in base if n == "KANO1_P")

    def rgb(w):
        return ((w >> 10) & 31, (w >> 5) & 31, w & 31)
    kr = [rgb(w) for w in kano]
    nearc = {}

    def near(w):
        if w not in nearc:
            c = rgb(w)
            nearc[w] = 1 + min(range(len(kr) - 1), key=lambda i: sum((a - b) ** 2 for a, b in zip(c, kr[i + 1])))
        return nearc[w]
    copied = set()

    def copy_lk(p, kind):
        if p in copied:
            return
        copied.add(p)
        r, words, src = lk_records()[p]
        lut = [0] + [near(w) for w in words[1:]] + [0] * 256
        lib(src)[kind].append((kn_name(p), r["ax"], r["ay"], r["w"], r["h"],
                               bytes(lut[v] for row in r["px"] for v in row), 0))

    for name, spec in sorted(CONTENT.items(), key=lambda kv: natural(kv[0])):
        if spec[0] == "mk1":
            _k, f, n, ln = spec
            cv, axo, ayo = ks.composite([recs[a] for a in frames[f]])
            pnm = {ownp.get(recs[a]["name"][:4], "KANO1_P") for a in frames[f]}
            if len(pnm) != 1:
                raise SystemExit(f"{name}'s MK1 strips are drawn in {len(pnm)} palettes")
            L = lib(ln)
            pi = pal_ix(L, pnm.pop())
            L["solid"].append((name, axo, ayo, cv.shape[1], cv.shape[0], cv.astype("uint8").tobytes(), pi))
            parts = ks.auto_split(cv, n) if n else ks.auto_split_free(cv)
            for k, (x, y, sub) in enumerate(parts):
                L["piece"].append((name + chr(65 + k), axo - x, ayo - y, sub.shape[1], sub.shape[0],
                                   sub.astype("uint8").tobytes(), pi))
        elif spec[0] in ("syn", "synrec"):
            # built out of his MK1 art (kano_synth) - drawn in KANO1_P's indices
            cv, ax, ay, parts = synth()[spec[1]]
            L = lib(spec[3])
            pnm = SYNTH_META["pal"].get(spec[1], "KANO1_P")
            ownw.update(SYNTH_META["palwords"])
            pi = pal_ix(L, pnm) if pnm != "KANO1_P" else [p[0] for p in L["pals"]].index("KANO1_P")
            L["solid"].append((name, ax, ay, cv.shape[1], cv.shape[0], cv.astype("uint8").tobytes(), pi))
            if spec[0] == "synrec":
                continue
            if parts:                  # a composed frame: its pieces belong to its parts...
                for p in parts:        # ...except a part that is a single record of its own
                    if (p.startswith("HOLEHEAD") or p in SYNTH_META["records"]) and p not in copied:
                        copied.add(p)
                        hc, hax, hay, _q = synth()[p]
                        qn = SYNTH_META["pal"].get(p, "KANO1_P")
                        qi = pal_ix(L, qn) if qn != "KANO1_P" else pi
                        L["piece"].append((syn_kn(p), hax, hay, hc.shape[1], hc.shape[0],
                                           hc.astype("uint8").tobytes(), qi))
                continue
            for k, (x, y, sub) in enumerate(ks.auto_split(cv, spec[2]) if spec[2] else ks.auto_split_free(cv)):
                L["piece"].append((piece_base(name) + chr(65 + k), ax - x, ay - y, sub.shape[1], sub.shape[0],
                                   sub.astype("uint8").tobytes(), pi))
        elif spec[0] == "lk":
            for p in spec[1]:
                s = re.sub(r"[A-Z]$", "", p)
                if s != p and s in lk_records():
                    copy_lk(s, "solid")
                copy_lk(p, "piece")
        else:
            copy_lk(spec[1], "solid")
    seen = {}
    for ln, L in libs.items():
        for e in L["solid"] + L["piece"]:
            if e[0] in seen:
                raise SystemExit(f"{e[0]} is in both {seen[e[0]]} and {ln}")
            seen[e[0]] = ln
    out = {}
    for ln, L in sorted(libs.items()):
        ents = sorted(L["solid"], key=lambda e: natural(e[0])) + sorted(L["piece"], key=lambda e: natural(e[0]))
        out[f"{ln}.IMG"] = pit.build_img(ents, L["pals"])
    return out


def kano_libs():
    """name -> (lib, record, palette name), over every KANO<n>.IMG."""
    out = {}
    for f in sorted(DATA.glob("KANO*.IMG"), key=lambda p: natural(p.stem)):
        if not re.fullmatch(r"KANO\d+", f.stem):
            continue
        recs, pals = cl.parse_img(f.read_bytes())
        for n, r in recs.items():
            out[n] = (f.stem, r, pals[r["palnum"]]["name"] if r["palnum"] in pals else "")
    return out


def pieces_of(name, have):
    """A frame's pieces: the library's <name>A..Z (a re-cut in IMGTOOL is
    followed), else - a Liu Kang frame built of other frames' pieces (DECAP,
    HOLE) - Liu Kang's list, renamed."""
    own = sorted((n for n in have if re.fullmatch(re.escape(piece_base(name)) + "[A-Z]", n)), key=natural)
    if own:
        return own
    spec = CONTENT.get(name)
    if spec and spec[0] == "syn" and synth()[spec[1]][3]:
        ps = []
        for p in synth()[spec[1]][3]:
            one = p.startswith("HOLEHEAD") or p in SYNTH_META.get("records", ())
            ps += [syn_kn(p)] if one else pieces_of(syn_kn(p), have)
        return ps
    if spec and spec[0] == "lk":
        ps = [kn_name(p) for p in spec[1]]
        miss = [p for p in ps if p not in have]
        if not miss:
            return ps
    raise SystemExit(f"{name} has no pieces in any KANO*.IMG - rerun --rip")


def own_palette(rom, recs, head, want):
    """The palette MK1 draws a group in: the .long after the group's FIRST
    record - found by walking back from `head` (a record of the group) to the
    first record whose trailing long is a palette.  `want` is the address
    expected; anything else, or art that indexes past it, fails."""
    import struct
    import mk1_yunit_extract as mk1
    a = next(k for k, r in recs.items() if r["name"] == head)
    o = (a - mk1.BASE) // 8
    for back in range(0, 2400, 2):
        q = o - back
        w, h = struct.unpack_from("<HH", rom.P, q)
        v = struct.unpack_from("<I", rom.P, q + 12)[0]
        if 1 <= w <= 400 and 1 <= h <= 300 and rom.inside(v):
            try:
                words = rom.palette(v)
            except ValueError:
                continue
            if len(words) >= 8:
                break
    else:
        raise SystemExit(f"no group palette before {head}")
    if v != want:
        raise SystemExit(f"{head}'s group palette is {v:08X}, expected {want:08X} - wrong mk.zip?")
    pre = head[:4]
    top = max(max(r["px"]) for r in recs.values() if r["name"].startswith(pre))
    if top >= len(words):
        raise SystemExit(f"{pre}* indexes {top}, past its {len(words)}-colour palette")
    return words


def lod_and_imgs():
    """MK1KNO.LOD (and KNMORPH.IMG, the 8.3 copy) out of the libraries: every
    record MK1KNL.ASM names - the subframes, and the heads it draws whole.
    The SOLID frames stay in the libraries, unpacked, as Midway's do."""
    files = {}
    text = asm()
    have = kano_libs()
    labels = {n for n, s in CONTENT.items() if s[0] not in ("rec", "synrec")}     # a frame's label is its SOLID's name
    used = (set(re.findall(r"\b[A-Z][A-Z0-9_]*\b", text)) & set(have)) - labels
    lod = ["***> %X,1" % BASE, "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
           ";" + "*" * 62, ";",
           ";  MK1 KANO (Wolf only, Shang Tsung's morph) - GENERATED by",
           ";  tools/make_mk1kano_port.py --lod out of his art libraries,",
           ";  data/KANO<n>.IMG (laid out like KANG<n>.IMG: Liu Kang's frame",
           ";  names, a solid frame + subframes each; MK1's art out of mk.zip)",
           ";  and Shang's morph into him (data/KANOMORPH.IMG, copied to",
           ";  KNMORPH.IMG - an 8.3 name).  Linear 0xEB4000.  POF>: drawn in",
           ";  the palette the object carries; the knife and the heart PON>.", ";",
           ";" + "*" * 62, "POF>", "ZON>", "PPP> 6", "ASM> MK1KNO.TBL"]
    bylib = {}
    for n, (lib, _r, pnm) in have.items():
        if n in used:
            pon = pnm in OWN_PALS or n in {syn_kn(k) for k in SYNTH_META.get("ownpal", ())}
            bylib.setdefault(lib, ([], []))[1 if pon else 0].append(n)
    order = sorted(bylib, key=natural)
    for lib in order:
        body = bylib[lib][0]
        if body:
            lod += [f"{lib}.IMG"] + ["---> " + ",".join(body[k:k + 8]) for k in range(0, len(body), 8)]
    # the knife and the heart are objects of their own, so they carry a palette
    lod.append("PON>")
    for lib in order:
        ns = bylib[lib][1]
        if ns:
            lod += [f"{lib}.IMG"] + ["---> " + ",".join(ns[k:k + 8]) for k in range(0, len(ns), 8)]
    lod.append("POF>")
    morph, _p = cl.parse_img((DATA / "KANOMORPH.IMG").read_bytes())
    mnames = [n for n in morph if n.startswith("KANOSHANG")]
    # the copy carries ONLY the morph frames: KANOMORPH.IMG's reference frames
    # (KANO, STSTANCE1) would clash with the records of those names elsewhere
    mp = next(v for v in _p.values() if v["name"] == "KNSHANG_P")
    files["KNMORPH.IMG"] = pit.build_img(
        [(n, morph[n]["ax"], morph[n]["ay"], morph[n]["w"], morph[n]["h"],
          bytes(v for row in morph[n]["px"] for v in row), 0) for n in mnames],
        [("KNSHANG_P", 6, mp["words"])])
    lod += ["KNMORPH.IMG", "---> " + ",".join(mnames)]
    files["MK1KNO.LOD"] = ("\r\n".join(lod) + "\r\n").encode("latin-1")
    return files


# ---------------------------------------------------------------------------
def lk_source():
    lines = (SRC / "MKLK.ASM").read_text(encoding="latin-1").splitlines()
    bl = blocks(lines)
    index = {lab: i for i, (lab, _b) in enumerate(bl) if lab}
    return bl, index


_LK_RECS = {}


def lk_records():
    """Liu Kang's records: name -> (rec, its palette words, the KANO library it
    goes to - KANG<n> -> KANO<n>), out of TEMPLATE_SRC (first one wins)."""
    if not _LK_RECS:
        for pat in TEMPLATE_SRC:
            for f in sorted(DATA.glob(pat), key=lambda p: natural(p.stem)):
                m = re.fullmatch(r"KANG(\d+)", f.stem)
                lib = f"KANO{m.group(1)}" if m else "KANO10"
                recs, pals = cl.parse_img(f.read_bytes())
                for n, r in recs.items():
                    if n.startswith("LK") and n not in _LK_RECS and r["palnum"] in pals:
                        _LK_RECS[n] = (r, pals[r["palnum"]]["words"], lib)
    return _LK_RECS


def lk_pieces(bl, index, f):
    """A Liu Kang frame's pieces (his record names), out of MKLK.ASM - or
    MKFX.ASM, where LKDRAIN0 lives."""
    if f in index:
        body = bl[index[f]][1]
    else:
        body = None
        for a in sorted(SRC.glob("*.ASM")):
            m = re.search(r"^" + re.escape(f) + r"\s+\.long\s+([^;\n]*)", a.read_text(encoding="latin-1"), re.M)
            if m:
                body = [f"\t.long\t{m.group(1)}"]
                break
        if body is None:
            raise SystemExit(f"Liu Kang frame {f} is defined nowhere")
    ps = []
    for ln in body:                     # .long OR .LONG (LKFB1-6 are upper case)
        m = re.match(r"^\s*(?:[A-Za-z_]\w*\s+)?\.long\s+(.*)$", ln.split(";")[0], re.I)
        if m:
            ps += re.findall(r"[A-Za-z_]\w*", m.group(1))
    if not ps:
        raise SystemExit(f"Liu Kang frame {f} names no piece")
    return ps


def lk_lib(f, ps, lane):
    """The KANO library a frame goes to: the one Liu Kang's solid of that name
    is in, else the one his first piece is in, else (his fireball is drawn on
    DRAGNBALL records) the one the MK1 lane's move is in."""
    for n in (f, ps[0]):
        if n in lk_records():
            return lk_records()[n][2]
    return LANE_NAME[lane][0]


def is_frame(bl, index, lab):
    """A Liu Kang FRAME: a label whose body is one .long list of pieces ending 0."""
    if lab not in index or not re.match(r"^[A-Z]", lab):
        return False
    body = [ln for ln in bl[index[lab]][1][1:] if ln.strip() and not ln.strip().startswith(("*", ";"))]
    first = bl[index[lab]][1][0]
    rest = first[len(lab):]
    code = (rest + "\n" + "\n".join(body)).split(";")[0]
    return bool(re.search(r"\.long", rest + "".join(body)))


def chain_of(bl, index, lab):
    """The block indices a lane runs through: a lane falls into the next block
    when that block is an unlabelled continuation (a part) of it."""
    j = index[lab]
    chain = [j]
    while True:
        body = bl[chain[-1]][1]
        last = [ln for ln in body if tokens(ln) or re.search(r"\.long\s+0\b", ln)]
        nxt = chain[-1] + 1
        if nxt >= len(bl):
            break
        nlab = bl[nxt][0]
        if (last and "ani_jump" in last[-1]) or re.match(r"^(a_|[A-Z])", nlab or "A"):
            break
        if any(re.match(r"^\s+[a-z]\w*\s", ln) and not re.match(r"^\s+\.", ln)
               for ln in bl[nxt][1][1:] if not ln.lstrip().startswith(("*", ";"))):
            break                      # code, not a lane part
        chain.append(nxt)
    return chain


def build():
    """Liu Kang's TABLE1 lanes with every frame renamed KN<his name>, and
    CONTENT/SLOT filled: which MK1 pose (or Liu Kang record) each name shows."""
    lanes = mk1()["lanes"]
    CONTENT.clear()
    SLOT.clear()
    bl, index = lk_source()
    rows = [t for ln in bl[index["lk_anitab1"]][1] for t in tokens(ln)][:0x43]
    if len(rows) != 0x43:
        raise SystemExit("lk_anitab1 is not 43h rows")

    def src_frames(spec):
        """The MK1 lane's DISTINCT frames, in order of first appearance.  A lane
        comes back the way it went (28h, the flip kick, is 1 2 3 | 2 1): spread
        Liu Kang's three frames over all five and they land on 1, 3, 1 - out,
        back, out, the flicker.  The same bug held the block on its lowering
        frame.  Each pose once, then the spread."""
        lane = spec[0]
        fr = list(range(len(lanes[lane])))
        if len(spec) == 3:
            fr = fr[spec[1]:spec[2]]
        out, seen = [], set()
        for i in fr:
            if lanes[lane][i] not in seen:
                seen.add(lanes[lane][i])
                out.append((lane, i))
        return out

    # which row owns each lane (the first row that names it)
    owner = {}
    for r, lab in enumerate(rows):
        owner.setdefault(lab, r)

    copied = {}                         # lane label -> its lines (renamed)
    order = []
    todo = [(lab, owner[lab]) for lab in rows]
    lane_labels = set()
    while todo:
        lab, r = todo.pop(0)
        if lab in copied or lab not in index:
            continue
        ch = chain_of(bl, index, lab)
        body = [ln for k in ch for ln in bl[k][1]]
        # this lane's Liu Kang frames, in order of first appearance
        lkf = []
        for ln in body:
            if ln.lstrip().startswith(("*", ";")):
                continue
            for t in tokens(ln):
                if t not in lkf and (re.match(r"^LK[A-Z0-9]+$", t) or (
                        t in index and re.match(r"^[A-Z]", t)
                        and re.search(r"\.long\s.*,\s*0\b", bl[index[t]][1][0].split(";")[0], re.I))):
                    lkf.append(t)
        kf = src_frames(ROWS[r])
        mp = {}
        for i, f in enumerate(lkf):
            if f in FIXED:
                mp[f] = FIXED[f]
            elif len(lkf) == 1:
                mp[f] = kf[0]
            else:
                mp[f] = kf[round(i * (len(kf) - 1) / (len(lkf) - 1))]
        ren = {}
        for f in lkf:
            name = ren[f] = kn_name(f)
            if name in CONTENT:                # an earlier row named it: one pose per name
                continue
            if r in TEMPLATE_ROWS:             # MK1 never drew it: built out of his MK1 art
                key = f[2:] if f.startswith("LK") else f
                lib0 = (lk_records()[f][2] if f in lk_records() and f not in index
                        else lk_lib(f, lk_pieces(bl, index, f), None))
                if key in synth():
                    if f not in index and f in lk_records():
                        CONTENT[name] = ("synrec", key, None, lib0)
                    else:
                        CONTENT[name] = ("syn", key, len(lk_pieces(bl, index, f)), lib0)
                    continue
                if f not in index and f in lk_records():      # no recipe: Liu Kang's own art
                    CONTENT[name] = ("rec", f, lk_records()[f][2])
                else:
                    ps = lk_pieces(bl, index, f)
                    bad = [p for p in ps if p not in lk_records()]
                    if bad:
                        raise SystemExit(f"{f}: {bad[0]} is in no {'/'.join(TEMPLATE_SRC)}")
                    CONTENT[name] = ("lk", ps, lk_lib(f, ps, None))
                continue
            if not name.startswith("KN"):
                raise SystemExit(f"{f} (row {r:02x}) is not a Liu Kang frame name")
            ps = lk_pieces(bl, index, f)
            g = lanes[mp[f][0]][mp[f][1]]
            CONTENT[name] = ("mk1", g, len(ps), lk_lib(f, ps, mp[f][0]))
            if mp[f][0] not in OWN_MOVES:      # a special's poses keep the special's names
                SLOT.setdefault(g, name)
        out = []
        for ln in body:
            if re.match(r"^\s*\.(end|text|data|bss)\b", ln, re.I):
                continue
            out.append(rename_line(ln.rstrip(), ren))
        copied[lab] = out
        order.append(lab)
        lane_labels.add(lab)
        for ln in body:
            for t in tokens(ln):
                if t.startswith("a_") and t in index and t not in copied:
                    todo.append((t, owner.get(t, r)))
    for lab, fr in OWN_LANES.items():      # MK1's own lane, not Liu Kang's resampled
        if lab in copied:
            copied[lab] = [lab] + ["\t.long\t0" if f == 0 else f"\t.long\t{kn_frame(*f)}" for f in fr]
    EXTRA_TEXT.clear()
    EXTRA_TEXT.extend(extra_lanes())
    # local DATA the lanes name (ERT_GRIPHD / ERT_POOLPT - per-module geometry
    # under the same names in every fighter module): copied, renamed kn_
    datab = []
    for lab in order:
        for ln in copied[lab]:
            for t in tokens(ln):
                if (t in index and not t.startswith(("a_", "LK")) and t not in lane_labels
                        and t not in [d for d, _ in datab]
                        and re.search(r"\.word", bl[index[t]][1][0])):
                    datab.append((t, bl[index[t]][1]))
    # rename lanes kn_
    lmap = {lab: "kn_" + lab for lab in lane_labels}
    lmap.update({d: "kn_" + d for d, _ in datab})
    lane_text = []
    for lab in order:
        lane_text += [rename_line(ln, lmap) for ln in copied[lab]]
        lane_text.append("")
    for d, body in datab:
        lane_text += [rename_line(ln.rstrip(), lmap) for ln in body if ln.strip()] + [""]
    return rows, lmap, lane_text


EXTRA_TEXT = []


def extra_token(t):
    """A token of a copied EXTRA lane -> Kano's, registering the synth frames."""
    if t == "f_szhlk":
        key = "szh"
    elif t.startswith("SUCK_LIUKANG"):
        key = "SUCK" + t[len("SUCK_LIUKANG"):]
    elif re.fullmatch(r"LK[A-Z0-9_]+", t):
        key = t[2:]
    else:
        return t
    kn = "KN" + key if key != "szh" else "kn_f_szh"
    if kn in CONTENT:                       # one of his TABLE1 frames (stumble, flipped...)
        return kn
    syn = synth()
    if key not in syn:
        raise SystemExit(f"EXTRA: {t} has no Kano frame (no kano_synth recipe {key})")
    recs = SYNTH_META["records"]
    CONTENT[kn] = ("synrec", key, None, "KANO10") if key in recs else \
        ("syn", key, len(any_pieces(lk_label(key))), "KANO10")
    return kn


def extra_lanes():
    """Each EXTRA lane, copied out of Liu Kang's module and renamed."""
    out = []
    names = {lk: kn for _m, lk, kn in EXTRA}
    for mod, lk, kn in EXTRA:
        lines = (SRC / mod).read_text(encoding="latin-1").splitlines()
        i = next((k for k, l in enumerate(lines) if re.match(re.escape(lk) + r"(\s|;|$)", l)), None)
        if i is None:
            raise SystemExit(f"EXTRA: no {lk} in {mod}")
        body = [lines[i]]
        for l in lines[i + 1:]:
            if re.match(r"^[A-Za-z_]", l):             # the next label
                break
            body.append(l)
        while body and (not body[-1].strip() or body[-1].lstrip().startswith((";", "*"))):
            body.pop()                                 # the NEXT block's header, not this one's
        out.append(f"; --- {kn}: Liu Kang's {lk} ({mod}), on Kano's own frames ---")
        for l in body:
            code, sep, com = l.partition(";")
            code = re.sub(r"\b[A-Za-z_]\w*\b",
                          lambda m: names.get(m.group(0)) or extra_token(m.group(0)), code)
            out.append((code + sep + com).rstrip())
        out.append("")
    # what only ANOTHER module names (a table row, MKBABY's KNBABE): built too
    for g in EXTRA_GLOBALS:
        if g.startswith("KN") and not g.endswith("_P") and g not in CONTENT:
            extra_token("LK" + g[2:])
    return out


def frames_text(text):
    """A label for every frame `text` names: <name> .long <its pieces>,0."""
    have = kano_libs()
    names = {t for t in re.findall(r"\b\w+\b", text) if t in CONTENT and CONTENT[t][0] not in ("rec", "synrec")}
    out = [f"{n}\t.long\t" + ",".join(pieces_of(n, have)) + ",0" for n in sorted(names, key=natural)]
    out.append("kn_head\t.long\t" + ",".join(HEAD) + ",0")
    return out


def asm():
    rows, lmap, lane_text = build()
    tbl = (SRC / "MK1KNO.TBL").read_bytes()
    h = hashlib.sha1(tbl + (SRC / "MKLK.ASM").read_bytes()).hexdigest()[:12]
    morph = re.findall(r"^(KANOSHANG\d):", tbl.decode("latin-1"), re.M)
    o = [";" + "*" * 70,
         f";  tables {h} - MK1KNO.TBL + MKLK.ASM, so a repack changes THIS file",
         ";  MK1 KANO (Wolf only, ochar 22) - his animation lanes.  GENERATED by",
         ";  tools/make_mk1kano_port.py: Liu Kang's lanes (MKLK.ASM) on Kano's",
         ";  frames of the same names (data/KANO<n>.IMG).  Edit the tool, never this file.",
         ";" + "*" * 70,
         '\t.file\t"mk1knl.asm"', "\t.width\t132", "\t.option\tb,d,l,t", "\t.mnolist",
         "\t.include\tdispequ.asm", "\t.include\tsysequ.asm", "\t.include\tmacros.hdr",
         "\t.include\tmainequ.asm",
         "\t.if\twunit",
         "\t.include\tmk1kno.tbl",
         "\t.globl\tkano_anitab1,kano_anitab2,kano_stance1,KANO1_P,KANO2_P,KNSHANG_P,KNKNIFE_P,KNHEART_P",
         "\t.globl\tkn_morph1,kn_morph2,kn_morph3,kn_normals,kn_r_hikicked,kn_r_sweep,kn_a_sweepbounce",
         "\t.globl\t" + ",".join(morph)]
    ref_at = len(o)
    o += ["\t.text", "", "kano_anitab1"]
    for r, lab in enumerate(rows):
        o.append(f"\t.long\t{lmap[lab]}\t; {r:02x} - Liu Kang's {lab}")
    o += ["", "kano_anitab2"]
    for k, (lab, _p, _l) in enumerate(TABLE2):
        o.append(f"\t.long\t{lab}\t; {k}")
    for lab, parts, loop in TABLE2:
        o.append("")
        o.append(lab)
        for pi, part in enumerate(parts):
            for f in part:
                if f[0].startswith("ani_"):          # an animator command
                    o += [f"\t.long\t{f[0]}", f"\t.word\t{f[1]}"]
                    continue
                o.append(f"\t.long\t{kn_frame(*f)}")
            if pi == len(parts) - 1 and loop is not None:
                o.append(f"\t.long\tani_jump,{lab}+{32 * loop}")
            else:
                o.append("\t.long\t0")
    # his normals (kn_normal, MK1KNM.ASM): the do_* each replaces, then
    # each move's script - header: action, lk_strikes index, sound routine;
    # then frame / whiff ticks / hit ticks / strike-check ticks, 0 ends
    o += ["", "kn_normals"]
    for do, lab in NORMAL_OF.items():
        o.append(f"\t.long\t{do},{lab}")
    o.append("\t.long\t0")
    for lab, act, stk, snd, ents in NORMALS + REACTS:
        o += ["", lab, f"\t.word\t{act},0{stk:x}h", f"\t.long\t{snd}"]
        for lane, i, w, h, c in ents:
            if lane == "STOP":
                o += ["\t.long\t1\t\t; stop_me", "\t.word\t0,0,0"]
                continue
            o += [f"\t.long\t{kn_frame(lane, i)}", f"\t.word\t{w},{h},{c}"]
        o.append("\t.long\t0")
    o += ["", "kn_a_sweepbounce", f"\t.long\t{kn_frame(*SWEEP_BOUNCE)}", "\t.long\t0"]
    o += ["", "kano_stance1", "\t.long\t" + ",".join(pieces_of(kn_frame("00", 0), kano_libs())) + ",0", "",
          ""]
    o += ["; --- Liu Kang's lanes, Kano's frames " + "-" * 32] + lane_text
    o += ["; --- the second batch: Liu Kang animations outside TABLE1 (EXTRA) " + "-" * 4] + EXTRA_TEXT
    frames = frames_text("\n".join(o))
    o += ["; --- the frames they draw: Liu Kang's names, Kano's subframes " + "-" * 8] + frames
    # anything the copied lanes name that is defined neither here nor in the TBL
    tbl_names = set(re.findall(r"^(\w+):", tbl.decode("latin-1"), re.M))
    defined = set(lmap.values()) | {ln.split("\t")[0] for ln in frames}
    need = set()
    for ln in lane_text + EXTRA_TEXT:
        for t in tokens(ln):
            if t.startswith(("kn_", "ani_")) or t in ("long", "word") or t in defined or t in tbl_names:
                continue
            need.add(t)
    if need:
        o.insert(ref_at, "\t.ref\t" + ",".join(sorted(need)))
    ex = [kn for _m, _l, kn in EXTRA] + list(EXTRA_GLOBALS)
    for k in range(0, len(ex), 6):          # short lines: GSPA truncates a long one
        o.insert(ref_at, "\t.globl\t" + ",".join(ex[k:k + 6]))
    clash = {kn for _m, _l, kn in EXTRA} & set(lmap.values())
    if clash:
        raise SystemExit(f"EXTRA label(s) {sorted(clash)} already name a TABLE1 lane here")
    # Shang's morph into him (a_st_2_kano, MKST.ASM): data/KANOMORPH.IMG's
    # KANOSHANG3 (most Shang) .. KANOSHANG1 (most Kano), one piece a frame,
    # on that library's own KNSHANG_P
    mrecs, mpals = cl.parse_img((DATA / "KANOMORPH.IMG").read_bytes())
    o += ["", "; --- Shang's morph into him (data/KANOMORPH.IMG) ---"]
    for n in morph:
        o.append(f"kn_morph{n[-1]}\t.long\t{n},0")
    mp = next(v for v in mpals.values() if v["name"] == "KNSHANG_P")
    o += ["KNSHANG_P:", f"\t.word\t{len(mp['words'])}"]
    o += ["\t.word\t" + ",".join(f"0{v:04x}h" for v in mp["words"][i:i + 8]) for i in range(0, len(mp["words"]), 8)]
    recs, pals = cl.parse_img((DATA / "MK1KANO.IMG").read_bytes())
    o += ["", "; --- his palettes (mk.zip): KANO1_P given, KANO2_P a mirror match ---"]
    have = kano_libs()
    for nm in OWN_PALS:                    # the knife's and the heart's, out of their libraries
        lib = next(l for _n, (l, _r, p) in have.items() if p == nm)
        _r, lp = cl.parse_img((DATA / f"{lib}.IMG").read_bytes())
        pals[nm] = next(v for v in lp.values() if v["name"] == nm)
    for _n, pdat in sorted(pals.items(), key=lambda kv: kv[1]["name"]):
        w = pdat["words"]
        o += [f"{pdat['name']}:", f"\t.word\t{len(w)}"]
        o += ["\t.word\t" + ",".join(f"0{v:04x}h" for v in w[i:i + 8]) for i in range(0, len(w), 8)]
    for nm in ("KNDRAIN_P", "SOULGRN_KN"):          # made by kano_synth
        w = SYNTH_META["palwords"][nm]
        o += [f"{nm}:", f"\t.word\t{len(w)}"]
        o += ["\t.word\t" + ",".join(f"0{v:04x}h" for v in w[i:i + 8]) for i in range(0, len(w), 8)]
    o += ["", "\t.endif", "\t.end", ""]
    return "\n".join(o)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rip", action="store_true",
                    help="rewrite data/KANO<n>.IMG: solid frames + Auto Split subframes, Liu Kang's names")
    ap.add_argument("--lod", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.rip:
        libs = rip_libs()
        for f in DATA.glob("KANO*.IMG"):          # the layout may drop a library
            if re.fullmatch(r"KANO\d+", f.stem):
                f.unlink()
        for n, b in libs.items():
            (DATA / n).write_bytes(b)
            print(f"wrote data/{n}")
    if a.lod:
        for n, b in lod_and_imgs().items():
            (DATA / n).write_bytes(b)
            print(f"wrote data/{n}")
    if a.apply:
        OUT.write_text(asm(), newline="\r\n", encoding="latin-1")
        print(f"wrote {OUT.relative_to(ROOT)}")
    if a.check:
        bad = [n for n, b in lod_and_imgs().items() if not (DATA / n).exists() or (DATA / n).read_bytes() != b]
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != asm():
            bad.append(OUT.name)
        if bad:
            print("make_mk1kano_port: STALE " + ", ".join(bad))
            return 1
        print("make_mk1kano_port: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
