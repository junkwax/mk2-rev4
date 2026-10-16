#!/usr/bin/env python3
"""hh_gleam_pixels.py - prove the gleam was DRAWN in HATGBL_P, not merely
pointed at it.

run_hh_gleam_test.ps1's main assertion is a pointer one: it reads `opal`, looks
the map up in `palram` and checks the id is HATGBL_P.  That is the right thing
to assert and it is not sufficient - the Jade victory rig's own note says a
matching SAG proves a row advanced, not that any pixel was written behind it,
and a sidecar hole passed that harness for months.

So this reads the snapshots the rig took and counts pixels that are EXACTLY
HATGBL_P's colours as MAME renders them (pal5bit: (v<<3)|(v>>2)).  The costume
ramp the gleam used to come out in is pure grey in every slot it touches
(R==G==B, 0x739C down to 0x4210), so a single saturated-blue pixel from this
palette cannot come from the old behaviour - and a frame full of grey where the
blues should be is the regression this exists to catch.

Index 0 is transparent and is deliberately not counted: it is black, and the
screen is full of black.

    python tools/hh_gleam_pixels.py <snapshot dir>      # one run's shots
    python tools/hh_gleam_pixels.py <dir> --min 20      # required blue pixels
"""
import argparse
import sys
from pathlib import Path

# HATGBL_P, src/IMGPAL7.ASM - kept in step with data/HATHED10.IMG by
# tools/sync_hatgleam_pal.py, so read it from the ASM rather than retyping it.
ROOT = Path(__file__).resolve().parent.parent
ASM = ROOT / "src" / "IMGPAL7.ASM"


def hatgbl_words():
    txt = ASM.read_text(encoding="latin-1").splitlines()
    for i, line in enumerate(txt):
        if line.strip().startswith("HATGBL_P:"):
            words = []
            for row in txt[i + 2:]:
                row = row.strip()
                if not row.startswith(".word"):
                    break
                for tok in row[5:].split(","):
                    tok = tok.strip()
                    if tok.upper().endswith("H"):
                        words.append(int(tok[:-1], 16))
            return words
    raise SystemExit("HATGBL_P not found in %s" % ASM)


def pal5(v):
    return (v << 3) | (v >> 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("snapdir")
    ap.add_argument("--min", type=int, default=20,
                    help="pixels of HATGBL_P needed in the best frame")
    a = ap.parse_args()

    try:
        from PIL import Image
    except ImportError:
        print("Pillow not installed - skipping the pixel check (NOT a pass)")
        return 2

    words = hatgbl_words()
    # Index 0 is transparent; every other entry is a colour only this palette
    # can put on screen here.
    wanted = {}
    for idx, w in enumerate(words):
        if idx == 0:
            continue
        rgb = (pal5((w >> 10) & 31), pal5((w >> 5) & 31), pal5(w & 31))
        wanted.setdefault(rgb, []).append(idx)

    shots = sorted(Path(a.snapdir).rglob("*.png"))
    if not shots:
        print("no snapshots under %s - NO VERDICT" % a.snapdir)
        return 2

    best, best_shot, grey_only = 0, None, 0
    for shot in shots:
        im = Image.open(shot).convert("RGB")
        hits = sum(n for n, px in (im.getcolors(1 << 24) or [])
                   if px in wanted)
        if hits > best:
            best, best_shot = hits, shot
        if hits == 0:
            grey_only += 1
        print("  %-28s HATGBL_P pixels: %d" % (shot.name, hits))

    print("best frame %s with %d HATGBL_P pixels (need %d); %d of %d frames had none"
          % (best_shot.name if best_shot else "-", best, a.min, grey_only, len(shots)))
    if best < a.min:
        print("FAIL: the gleam was not DRAWN in HATGBL_P - the object may point at "
              "it while something else paints the pixels")
        return 1
    print("OK: the gleam is drawn in HATGBL_P")
    return 0


if __name__ == "__main__":
    sys.exit(main())
