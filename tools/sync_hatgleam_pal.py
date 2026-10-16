#!/usr/bin/env python3
"""sync_hatgleam_pal.py - keep src/IMGPAL7.ASM's HATGBL_P equal to
data/HATHED10.IMG.

HATGBL_P is the blue ramp TMHATGLEAM1-6 are drawn in - Kung Lao's victory hat
gleam, played on its OWN object by hh_victory (MKCANNED.ASM) so it can wear a
palette at all.  The art indexes 1-7 (index 0 is transparent) and is packed at
6bpp, because data/MK2MIL.LOD is `PPP> 6` for the whole Kung Lao section.

IT CANNOT BE REACHED AS A MULTIPART PIECE.  a_hh_victory_hat's rows are
TMVICTORY8A,TMVICTORY8B,TMHATGLEAMn and MKDISP loads an object's palette
translate ONCE, before its multipart loop, so a gleam piece inside those rows
comes out in whichever costume Kung Lao is wearing - his slots 1-7, a
white-to-grey highlight ramp.  That is what the gleam looked like for as long
as it has existed, whatever palette the IMG named.  See hhgleam (MAINEQU.ASM).

NOTHING PROMOTES AN IMG PALETTE INTO THE ROM - IMGPAL*.ASM is hand-maintained -
so a recolour of the gleam in IMGTOOL would ship the old colours with no error
anywhere.  This makes that a build failure.  Same guard, same reason, as
tools/sync_slicehat_pal.py does for SHAT1_P out of HATHED12.IMG.

The record is found by NAME in the IMG's palette table, never by position:
HATHED10.IMG carries seven palettes and the gleam's neighbours are Kung Lao's
three costumes and HATGLOW_P, the 64-colour ramp the hat SWIPE is drawn in.
TGLEAM_P, the white ramp the records named before HATGBL_P was authored, is
still in the library and is NOT what ships.

    python tools/sync_hatgleam_pal.py            # rewrite from the IMG
    python tools/sync_hatgleam_pal.py --check    # Phase D: fail on drift
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "HATHED10.IMG"
ASM = ROOT / "src" / "IMGPAL7.ASM"

NAMES = {
    "HATGBL_P": "TMHATGLEAM1-6 - Kung Lao's victory hat gleam (own object)",
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
            print("%s: not in src/IMGPAL7.ASM - add the block by hand once" % name)
            rc = 1
            continue
        if m.group(0) == want:
            print("%s OK (matches %s)" % (name, IMG.name))
            continue
        if a.check:
            print("%s: src/IMGPAL7.ASM differs from %s - run tools/sync_hatgleam_pal.py"
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
