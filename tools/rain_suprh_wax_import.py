#!/usr/bin/env python3
"""Generate RAIN's knee -> super roundhouse lane from data/RAINSUPROUND.WAX.

    python tools/rain_suprh_wax_import.py           rewrite the generated block
    python tools/rain_suprh_wax_import.py --check   exit 1 if it is stale

The IMGTOOL project is the source of truth for the move.  Its slot on
data/NINJAS4.IMG that carries NJROUNDKIK frames is the whole sequence the
player sees: the knee (NJKNEE1-3), then - only when Back+HK came in by
NJKNEE3 - the rest of it.  The knee part is the stock ninja knee and is
played by the code (`a_njknee`, do_knee's speed and active ticks, so a Rain
who does not link it throws exactly the ordinary knee); this writes the REST
as `a_rain_suprh` (rain_anitab2 row 0ch), frame by frame with its holds, between the WAX
markers in src/MKNJ.ASM.

PER-FRAME HOLDS.  Every row is a PAIR - `.long FRAME` then `.long hold` -
and only rain_super_knee (MOVES.ASM) walks it: it lets do_next_a9_frame show
the frame, then takes the hold off the next long itself.  So this is NOT an
ordinary animation lane; never hand it to mframew/animate.  Layout:

    frames before STRIKE_FRAME (pairs), 0
    STRIKE_FRAME, its hold          - the hold IS its active ticks
    the recovery (pairs), 0

STRIKE_FRAME is the roundhouse's own contact frame - a_njroundh strikes on
NJROUNDKIK5 too.  The lead-in's holds (NJKNEE1-3) are NOT used: that part is
the stock knee, played at do_knee's own speed so an unlinked knee is exactly
the ordinary one.  local_dx/dy must be zero: nothing applies them.
"""
import argparse
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "RAINSUPROUND.WAX")
ASM = os.path.join(ROOT, "src", "MKNJ.ASM")
IMG_NAME = "NINJAS4.IMG"

BEGIN = ";>>>WAX BEGIN rain_suprh"
END = ";<<<WAX END rain_suprh"

LEAD_IN = ["NJKNEE1", "NJKNEE2", "NJKNEE3"]     # what a_njknee part 1 plays
STRIKE_FRAME = "NJROUNDKIK5"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")


def img_names(path):
    b = open(path, "rb").read()
    imgcnt, _, oset = LIB_HDR.unpack_from(b, 0)[:3]
    return [IMAGE.unpack_from(b, oset + i * IMAGE.size)[0].split(b"\0", 1)[0].decode("latin-1")
            for i in range(imgcnt)]


def parse_wax(path):
    kv = {}
    for line in open(path, "r", errors="replace"):
        line = line.rstrip("\r\n")
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def ints(kv, key):
    v = kv.get(key, "")
    return [int(x) for x in v.split(",") if x.strip() != ""] if v else []


def the_slot(kv, names):
    """the one NINJAS4 slot whose frames include a roundhouse"""
    hits = []
    for n in range(int(kv.get("slot.count", "0"))):
        doc = int(kv.get(f"slot.{n}.doc_idx", "-1"))
        if os.path.basename(kv.get(f"doc.{doc}.path", "")).upper() != IMG_NAME:
            continue
        seq = ints(kv, f"slot.{n}.sequence_frames")
        if any(0 <= f < len(names) and names[f].startswith("NJROUNDKIK") for f in seq):
            hits.append(n)
    if len(hits) != 1:
        sys.exit(f"RAINSUPROUND.WAX: {len(hits)} {IMG_NAME} slots carry NJROUNDKIK frames "
                 f"({hits}), expected exactly 1")
    return hits[0]


def build():
    kv = parse_wax(WAX)
    names = img_names(os.path.join(ROOT, "data", IMG_NAME))
    n = the_slot(kv, names)
    seq = ints(kv, f"slot.{n}.sequence_frames")
    dly = ints(kv, f"slot.{n}.frame_delays")
    dx = ints(kv, f"slot.{n}.local_dx")
    dy = ints(kv, f"slot.{n}.local_dy")
    mir = ints(kv, f"slot.{n}.frame_mirror")

    for fi in seq:
        if not 0 <= fi < len(names):
            sys.exit(f"slot {n}: frame index {fi} is outside {IMG_NAME}")
    labels = [names[fi] for fi in seq]
    if labels[:len(LEAD_IN)] != LEAD_IN:
        sys.exit(f"slot {n} must open on {LEAD_IN} (the stock knee the code plays), "
                 f"it opens on {labels[:len(LEAD_IN)]}")
    rest = labels[len(LEAD_IN):]
    if rest.count(STRIKE_FRAME) != 1:
        sys.exit(f"slot {n}: the continuation must show {STRIKE_FRAME} exactly once "
                 f"(the contact frame), it shows it {rest.count(STRIKE_FRAME)} times")
    holds = [dly[i] if i < len(dly) else 1 for i in range(len(seq))]
    if any(h < 1 for h in holds):
        sys.exit(f"slot {n}: a frame_delay below 1 tick")
    rest_holds = holds[len(LEAD_IN):]
    if any(v for v in dx + dy):
        sys.exit(f"slot {n} carries local_dx/dy offsets; nothing applies them")
    if any(v for v in mir):
        sys.exit(f"slot {n} mirrors a frame; the lane cannot")

    asm = open(ASM, errors="replace").read()
    for lab in rest:
        if not re.search(r"^" + lab + r"\s", asm, re.M):
            sys.exit(f"{lab}: MKNJ.ASM has no frame list for it")

    cut = rest.index(STRIKE_FRAME)
    out = [BEGIN,
           "* GENERATED from data/RAINSUPROUND.WAX (slot %d) by" % n,
           "* tools/rain_suprh_wax_import.py.  Edit the project, not this block.",
           "* RAIN's super roundhouse: what follows the knee's " + LEAD_IN[-1] + " when",
           "* Back+HK linked it in the combo window (rain_knee, MOVES.ASM).  PAIRS of",
           "* frame and hold - rain_super_knee steps over the hold (RSK_* set the",
           "* pace).  Never walked by mframew.",
           "*",
           "a_rain_suprh"]
    pair = lambda lab, h, note="": out.append(f"	.long	{lab},{h}{note}")
    for lab, h in zip(rest[:cut], rest_holds[:cut]):
        pair(lab, h)
    out.append("	.long	0		; the contact frame next")
    pair(STRIKE_FRAME, rest_holds[cut], "	; its hold = the active ticks (stk_rain_roundh)")
    for lab, h in zip(rest[cut + 1:], rest_holds[cut + 1:]):
        pair(lab, h)
    out.append("	.long	0")
    out.append(END)
    return "\n".join(out) + "\n"


def splice(text, block):
    a = text.index(BEGIN)
    b = text.index(END) + len(END)
    b = text.index("\n", b) + 1
    return text[:a] + block + text[b:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    raw = open(ASM, "rb").read().decode("latin-1")
    crlf = "\r\n" in raw
    text = raw.replace("\r\n", "\n")
    if BEGIN not in text or END not in text:
        sys.exit(f"{os.path.basename(ASM)}: no {BEGIN!r} / {END!r} markers")
    new = splice(text, build())
    if new == text:
        print("a_rain_suprh OK (matches RAINSUPROUND.WAX)")
        return 0
    if args.check:
        print("a_rain_suprh: src/MKNJ.ASM differs from RAINSUPROUND.WAX - run "
              "tools/rain_suprh_wax_import.py")
        return 1
    if crlf:
        new = new.replace("\n", "\r\n")
    open(ASM, "wb").write(new.encode("latin-1"))
    print("rewrote a_rain_suprh from RAINSUPROUND.WAX")
    return 0


if __name__ == "__main__":
    sys.exit(main())
