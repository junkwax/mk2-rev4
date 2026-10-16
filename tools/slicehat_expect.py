#!/usr/bin/env python3
"""Regenerate tools/slicehat_expect.lua from the LINKED sprite table and MAINEQU.

KUNG LAO'S HAT AT BANK ANGLE.  Two things the rig must not hard-code:

  * the ten SAGs, out of src/SLICEHAT.TBL.  Every SAG in a pack moves when
    anything ahead of it is re-cut, so a rig carrying literals would keep
    passing against whatever art happened to land at the old address.
  * the bucket edges and the ceiling, out of src/MAINEQU.ASM.  The rig's whole
    assertion is "the frame drawn is the one this oyvel calls for", and it can
    only ask that against the SAME numbers hat_proc uses.

The angles are the measured principal axis of each frame's opaque mask - they
are what makes the set an angle table - and are carried through for the log.

This refuses rather than guesses: a missing record, a duplicate label or a
missing equate is an error, not a default.

    python tools/slicehat_expect.py [--out tools/slicehat_expect.lua]
    python tools/slicehat_expect.py --check      # Phase D: placement continuity

--check is a guard on the ART, not on the tables.  The hat holds one frame per
bank and the stick walks it up and down the ramp, so if two neighbouring frames
disagree about where the hat sits relative to the anchor, the hat JUMPS as the
bucket changes - and nothing else in the build would notice, because every
frame is individually valid.

It happened: SLICEHAT16 shipped with aniy -19 where its neighbours run 14-23,
putting its centre 36px out of line and making the hat leap 40px the moment a
left-thrown throw reached the steepest climb.  Its rightward twin SLICEHAT5 is
the same 48x34 at the same bank and has aniy 20, which is what pins the value.

data/HATHED12.IMG is hand-edited in IMGTOOL, so a re-save silently reverts any
fix made here - this turns that into a build failure with the number to type.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "src" / "SLICEHAT.TBL"
EQU = ROOT / "src" / "MAINEQU.ASM"
ZAP = ROOT / "src" / "MKZAP.ASM"     # slhatdark lives there, not in MAINEQU

# index -> (record, measured angle in degrees).  The ORDER is the contract with
# slicehat_pics (MKHH.ASM): index 0 is the steepest climb, 9 the steepest dive.
# (on-screen angle, rightward record, leftward record)
#
# THE ART IS DIRECTIONAL.  Every frame carries a motion trail and which side it
# lies on says which way the hat was drawn flying: SLICEHAT1-6 trail LEFT
# (rightward), 7-16 trail RIGHT (leftward).  The artist mirrored them BY HAND
# rather than letting the DMA flip them, so each throw draws the set authored
# for the way it is going.
#
# The DIVE half is the same records both ways - there are no rightward dive
# frames at all - H-flipped for a rightward throw and as authored for a
# leftward one.  Bucket 0 has no leftward twin (the leftward climb stops at
# +30.7), so it falls back to the rightward record mirrored.
#
# WHICH BUCKETS FLIP is not listed here: it is slhat_flip_r / slhat_flip_l in
# MAINEQU.ASM, one bit per bucket, read below - so the rig and the ROM cannot
# disagree about it.
ORDER = [
    (-38.8, "SLICEHAT6",  "SLICEHAT6"),
    (-30.7, "SLICEHAT5",  "SLICEHAT16"),
    (-21.4, "SLICEHAT4",  "SLICEHAT15"),
    (-12.7, "SLICEHAT3",  "SLICEHAT14"),
    ( -4.9, "SLICEHAT2",  "SLICEHAT13"),
    (  0.9, "SLICEHAT1",  "SLICEHAT12"),
    (  6.0, "SLICEHAT11", "SLICEHAT11"),
    ( 13.7, "SLICEHAT10", "SLICEHAT10"),
    ( 22.4, "SLICEHAT9",  "SLICEHAT9"),
    ( 30.9, "SLICEHAT8",  "SLICEHAT8"),
    ( 38.5, "SLICEHAT7",  "SLICEHAT7"),
]
LEVEL = 5                                   # index of the flat frame

EQUATES = ["slhat_b1", "slhat_b2", "slhat_b3", "slhat_b4", "slhat_b5",
           "slhat_ymax", "slicehat", "slhatcap", "slhat_flipfrom_r",
           "slhat_flipfrom_l"]


def records():
    txt = TBL.read_text(encoding="latin-1")
    out = {}
    for m in re.finditer(r"^(\w+):\s*\n\s*\.word\s+([\d,\s-]+)\n\s*\.long\s+0?([0-9a-fA-F]+)H",
                         txt, re.M):
        name, geom, sag = m.group(1), m.group(2), m.group(3)
        if name in out:
            sys.exit("%s: duplicate record %s" % (TBL.name, name))
        w, h, ax, ay = [int(v) for v in geom.replace(" ", "").split(",")[:4]]
        out[name] = dict(sag=int(sag, 16), w=w, h=h, ax=ax, ay=ay)
    return out


def equates():
    txt = EQU.read_text(encoding="latin-1")
    out = {}
    for name in EQUATES:
        m = re.search(r"^%s\s+\.set\s+(\S+)\s*$" % re.escape(name), txt, re.M)
        if not m:
            sys.exit("%s: no equate '%s'" % (EQU.name, name))
        v = m.group(1)
        out[name] = int(v[:-1], 16) if v.lower().endswith("h") else int(v, 0)
    m = re.search(r"^slhatdark\s+\.set\s+(\d+)\s*$", ZAP.read_text(encoding="latin-1"), re.M)
    if not m:
        sys.exit("%s: no equate 'slhatdark'" % ZAP.name)
    out["slhatdark"] = int(m.group(1)) * (1 if equ_boom(txt) else 0)
    return out


def equ_boom(txt):
    m = re.search(r"^slhatboom\s+\.set\s+(\d+)\s*$", txt, re.M)
    if not m:
        sys.exit("%s: no equate 'slhatboom'" % EQU.name)
    return int(m.group(1))


# How far apart two NEIGHBOURING buckets may place the hat, in pixels, before
# the step reads as a jump rather than as the sprite growing.
#
# Y steps by 2.5px at most, so 3 gates it tightly - that is the axis the 40px
# SLICEHAT16 fault was on.
#
# X is looser at 5.5 because two steps are AUTHORING VARIANCE, not regressions,
# and cannot be fixed from here without editing the artist's anipoints:
#   thrown RIGHT, SLICEHAT1 -> SLICEHAT11, -5.0.  The level frame is rightward
#     art anchored on its centre; the dive frames are leftward art whose
#     anchors sit ~5px off that.  The dive frames serve BOTH facings, so
#     nudging them to suit the right would unsmooth the left.
#   thrown LEFT, SLICEHAT6 -> SLICEHAT16, -4.0.  The bucket 0/1 boundary, where
#     engine-mirrored rightward art meets as-authored leftward art because no
#     leftward -38 frame exists to bridge it.
# The leftward family is consistently 2-4px off the mirror of the rightward
# one (12 by 4, 13-16 by 2); matching them in IMGTOOL would close both.
MAX_STEP_Y = 3.0
MAX_STEP_X = 5.5


def placement(recs, order, flip_from):
    """Where each bucket puts the hat CENTRE relative to the object anchor.

    ani2 mirrors the X anipoint for a flipped piece (neg, then add the width)
    and leaves Y alone, so the flip has to be applied here the same way or the
    check reads the wrong anchor for half the ramp.
    """
    out = []
    for i, name in enumerate(order):
        r = recs[name]
        eff_ax = (r["w"] - r["ax"]) if i >= flip_from else r["ax"]
        out.append((name, r["h"] / 2.0 - r["ay"], r["w"] / 2.0 - eff_ax))
    return out


def check_continuity(recs, eq):
    order_r = [o[1] for o in ORDER]
    order_l = [o[2] for o in ORDER]
    bad = 0
    for tag, order, frm in (("thrown RIGHT", order_r, eq["slhat_flipfrom_r"]),
                            ("thrown LEFT", order_l, eq["slhat_flipfrom_l"])):
        rows = placement(recs, order, frm)
        for i in range(1, len(rows)):
            (pn, py, px), (n, y, x) = rows[i - 1], rows[i]
            dy, dx = y - py, x - px
            if abs(dy) > MAX_STEP_Y or abs(dx) > MAX_STEP_X:
                print("%s: %s -> %s steps dY %+.1f dX %+.1f - the hat JUMPS here"
                      % (tag, pn, n, dy, dx))
                bad += 1
    if bad:
        print("  the ramp must step smoothly: check the aniy of the named frames in")
        print("  IMGTOOL against their twin at the same bank in the other direction")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "tools" / "slicehat_expect.lua"))
    ap.add_argument("--check", action="store_true",
                    help="verify placement continuity only; write nothing")
    a = ap.parse_args()

    recs, eq = records(), equates()
    missing = sorted({n for r in ORDER for n in (r[1], r[2])} - set(recs))
    if missing:
        sys.exit("%s: missing %s - did data/SLICEHAT.LOD change?"
                 % (TBL.name, ", ".join(missing)))

    # geometry comes from the TBL, which LOAD2 wrote from the IMG, so this
    # checks what actually shipped rather than what the IMG says today
    if a.check:
        bad = check_continuity(recs, eq)
        if bad:
            return 1
        print("slicehat placement OK (%d buckets, both facings, no jumps)" % len(ORDER))
        return 0

    L = ["-- GENERATED by tools/slicehat_expect.py - do not edit.",
         "-- SAGs out of src/SLICEHAT.TBL, thresholds out of src/MAINEQU.ASM.",
         "return {",
         "  slicehat = %d, slhatcap = %d," % (eq["slicehat"], eq["slhatcap"]),
         "  ymax = 0x%x," % eq["slhat_ymax"],
         "  level = %d," % (LEVEL + 1),                 # lua is 1-based
         "  flipfrom_r = %d, flipfrom_l = %d," % (eq["slhat_flipfrom_r"], eq["slhat_flipfrom_l"]),
         "  dark = %d,  -- slhatdark: outward leg = leftward set, home leg = rightward set, either facing"
         % eq["slhatdark"],
         "  edges = { 0x%x, 0x%x, 0x%x, 0x%x, 0x%x }," % tuple(
             eq["slhat_b%d" % i] for i in range(1, 6)),
         "  frames = {"]
    for i, (ang, rn, ln) in enumerate(ORDER):
        r, l = recs[rn], recs[ln]
        L.append("    { idx = %d, angle = %6.1f, rname = %-12s rsag = 0x%08x, "
                 "lname = %-12s lsag = 0x%08x },"
                 % (i, ang, '"%s",' % rn, r["sag"], '"%s",' % ln, l["sag"]))
    L += ["  },", "  -- any SAG the hat may legally wear, either facing", "  any = {"]
    for n in sorted({n for r in ORDER for n in (r[1], r[2])}):
        L.append("    [0x%08x] = true," % recs[n]["sag"])
    L += ["  },", "}"]

    Path(a.out).write_text("\n".join(L) + "\n", encoding="utf-8")
    print("wrote %s: %d frames, ymax=0x%x, cap=%s"
          % (a.out, len(ORDER), eq["slhat_ymax"], bool(eq["slhatcap"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
