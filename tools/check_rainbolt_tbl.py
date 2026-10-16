#!/usr/bin/env python3
r"""src/RAINBOLT.TBL against LOAD2's own tmp/load2/RAINBOLT.TBL.

RAINBOLT is a POF> sidecar whose sprite headers are HAND-CARRIED: nothing in
build.py's Phase B promotes them, unlike the per-character .TBLs.  So the file
goes stale the moment data/RAINBOLT.IMG changes size, geometry or its record
set, and NOTHING else notices - the build stays green and the bolt ships with
the wrong anipoints (drawn in the wrong place) or the wrong width (the DMA
walks the wrong bytes per row and the frame shears, which reads as SAG drift
when the SAGs are fine).

It has gone stale twice: 2026-09-26, when the subframe cut left four uncut
parents and the old N64 geometry behind, and 2026-09-27, when the anchor moved.

Comments are ignored - only the .DATA body has to match.

    python tools/check_rainbolt_tbl.py --check   # Phase D
    python tools/check_rainbolt_tbl.py --sync    # copy the snapshot in
"""
import argparse, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "RAINBOLT.TBL"
SNAP = ROOT / "tmp" / "load2" / "RAINBOLT.TBL"


def bodies():
    src = SRC.read_text(encoding="latin-1")
    i = src.index("\t.DATA")
    return src, i, SNAP.read_text(encoding="latin-1").lstrip("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--sync", action="store_true")
    a = ap.parse_args()

    if not SNAP.exists():
        # No LOAD2 snapshot in this tree yet - nothing to compare against.
        print("RAINBOLT.TBL: no tmp/load2 snapshot, skipped")
        return
    if not SRC.exists():
        sys.exit("src/RAINBOLT.TBL is missing")

    src, i, snap = bodies()
    if a.sync:
        SRC.write_text(src[:i] + snap, encoding="latin-1")
        print("synced src/RAINBOLT.TBL from tmp/load2/RAINBOLT.TBL")
        return

    if src[i:] != snap:
        sys.exit("src/RAINBOLT.TBL does not match tmp/load2/RAINBOLT.TBL - the\n"
                 "hand-carried headers are stale.  Run a full build.py so LOAD2\n"
                 "regenerates the snapshot, then:\n"
                 "    python tools/check_rainbolt_tbl.py --sync\n"
                 "    python build.py --asm-only")
    print("RAINBOLT.TBL OK (matches the LOAD2 snapshot)")


if __name__ == "__main__":
    main()
