#!/usr/bin/env python3
"""sync_slicehat_pal.py - keep src/IMGPAL6.ASM's SHAT1_P equal to
data/HATHED12.IMG.

SHAT1_P is the palette SLICEHAT1-11 are drawn in - Kung Lao's hat rendered at
bank angles, packed by data/SLICEHAT.LOD and picked one frame per angle by
hat_proc (MKZAP.ASM).  It is NOT the palette the hat normally wears: the hat
object lives on TMHATS_P (src/IMGPAL2.ASM), which HATFLY1A names, and hat_proc
swaps to this one with swpal for the flight and back on the hit.  The two share
not one word of 64.

NOTHING PROMOTES AN IMG PALETTE INTO THE ROM - IMGPAL*.ASM is hand-maintained -
so a recolour of the hat in IMGTOOL would ship the old colours with no error
anywhere.  This makes that a build failure.

The record is found by NAME in the IMG's palette table, never by position:
HATHED12.IMG carries four hat palettes (SHAT_P, HATGLOW_P, SHAT3_P, SHAT1_P)
and they are neighbours - SHAT3_P is the one the IMG records' palnum field
names, and it is NOT the one that ships.

    python tools/sync_slicehat_pal.py            # rewrite from the IMG
    python tools/sync_slicehat_pal.py --check    # Phase D: fail on drift
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "HATHED12.IMG"
ASM = ROOT / "src" / "IMGPAL6.ASM"

NAMES = {
    "SHAT1_P": "SLICEHAT1-11 - Kung Lao's hat at bank angle (data/SLICEHAT.LOD)",
}

LIB = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PAL = struct.Struct("<10s BB H I H H B B H")


def img_palettes():
    d = IMG.read_bytes()
    imgcnt, palcnt, oset = LIB.unpack_from(d, 0)[:3]
    base = oset + imgcnt * IMAGE.size
    found = {}
    for i in range(palcnt - 3):             # palcnt over-counts by 3
        r = PAL.unpack_from(d, base + i * PAL.size)
        nm = r[0].split(b"\0")[0].decode("latin-1")
        if nm in NAMES:
            n, off = r[3], r[4]             # off is an absolute file offset
            found[nm] = list(struct.unpack_from("<%dH" % n, d, off))
    missing = [n for n in NAMES if n not in found]
    if missing:
        raise SystemExit("%s: no palette record named %s"
                         % (IMG.name, ", ".join(missing)))
    return found


def block(name, words):
    rows = ["\t.word\t" + ",".join("0%04XH" % w for w in words[i:i + 8])
            for i in range(0, len(words), 8)]
    return "%s:\n\t.word\t %d\n%s\n" % (name, len(words), "\n".join(rows))


def pattern(name):
    return re.compile(r"^" + name + r":\s*\n\s*\.word\s+\d+\s*\n(?:\s*\.word[^\n]*\n)+", re.M)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    pals = img_palettes()
    txt = ASM.read_text(encoding="latin-1")
    rc, wrote = 0, []
    for name in NAMES:
        want = block(name, pals[name])
        m = pattern(name).search(txt)
        if not m:
            print("%s: not in src/IMGPAL6.ASM - add the block by hand once" % name)
            rc = 1
            continue
        if m.group(0) == want:
            print("%s OK (matches %s)" % (name, IMG.name))
            continue
        if a.check:
            print("%s: src/IMGPAL6.ASM differs from %s - run tools/sync_slicehat_pal.py"
                  % (name, IMG.name))
            rc = 1
            continue
        txt = txt[:m.start()] + want + txt[m.end():]
        wrote.append(name)
    if wrote:
        ASM.write_text(txt, encoding="latin-1", newline="")
        print("rewrote %s from %s" % (", ".join(wrote), IMG.name))
    return rc


if __name__ == "__main__":
    sys.exit(main())
