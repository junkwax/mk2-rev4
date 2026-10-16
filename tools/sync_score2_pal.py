#!/usr/bin/env python3
"""sync_score2_pal.py - keep src/IMGPAL6.ASM's SCORE2_P equal to
data/MKSCORE.IMG.

SCORE2_P is the palette MEDAL5 - the win medals under the life bars - is drawn
in (update_knotches / get_amulet_pal, MKDISP.ASM).  It differs from SCORE_P in
63 of 64 colours, so the medal cannot share the score area's palette.

NOTHING PROMOTES AN IMG PALETTE INTO THE ROM - IMGPAL*.ASM is hand-maintained -
so a recolour in IMGTOOL would ship the old colours with no error anywhere.
This makes that a build failure.  Same shape as tools/sync_hatgleam_pal.py.

    python tools/sync_score2_pal.py            # rewrite from the IMG
    python tools/sync_score2_pal.py --check    # Phase D: fail on drift
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "MKSCORE.IMG"
ASM = ROOT / "src" / "IMGPAL6.ASM"

NAMES = {
    "SCORE2_P": "MEDAL5 - the win medals under the life bars",
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
            print("%s: src/IMGPAL6.ASM differs from %s - run tools/sync_score2_pal.py"
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
