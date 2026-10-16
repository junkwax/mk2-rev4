#!/usr/bin/env python3
r"""Build data/RAINPSX/RAINPSX.IMG - RAIN's fighter art from the MK Trilogy PC/PSX build.

Source is the PC DOS build (MKTRIL.EXE + CHARS1/NINJA.DAT), which ships the SAME
.DAT files as the PSX disc.  Rain has no art of his own: he wears the shared
male-ninja body, so this library carries all 721 NINJA.DAT frames with his
palette attached.

Container + codecs were reverse-engineered from MKTRIL.EXE's Watcom debug
symbols; the pixels come out of POVBQDecode_ (obj1:0x1A52), a block-quantised
codec: a 6-bit sub-table selector, then per 4 x t0 block either a two-stage
prefix code indexing a shared codebook, or an escape giving a run of empty
blocks.  Validated: 721/721 frames decode to exactly their declared size with
zero pixels outside their palette.

PALETTE CAVEAT - read before trusting the colours.  Rain's palette index is
inferred, not confirmed.  NINJA.DAT palette 7 (costume hue 305 deg) and 9
(295 deg) are the only pair in the whole 37-entry character_palettes table
where BOTH slots are purple, which is Rain's signature and no one else's.
That conflicts with the select-screen position, which points at ochar 27 /
palette 0 (orange, and identical in both slots, which looks like an unassigned
default).  If the colours are wrong, change DEFAULT_PAL / ALT_PAL below;
nothing else in the pipeline moves.

    python tools/make_rainpsx_img.py            # write data/RAINPSX/RAINPSX.IMG
    python tools/make_rainpsx_img.py --check    # fail if it has drifted
"""
import argparse, struct, sys, hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = Path(r"C:/Users/you/AppData/Local/Temp/claude/c--Users-you-Workplace-mk2-main"
               r"/9e8c48f3-2acb-44fc-91d2-e51f3ab0ed61/scratchpad")
NINJA = SCRATCH / "disc" / "CHARS1" / "NINJA.DAT"
OUTDIR = ROOT / "data" / "RAINPSX"
OUT = OUTDIR / "RAINPSX.IMG"
TEMPLATE = ROOT / "data" / "RAINN64.IMG"      # for the record struct templates

DEFAULT_PAL, ALT_PAL = 7, 9                   # NINJA.DAT palette indices
PAL_NAMES = ["RNPSX_P", "RNPSXALT"]           # <= 9 chars

sys.path.insert(0, str(SCRATCH))
sys.path.insert(0, str(ROOT / "tools"))
from mkt import Dat                                    # noqa: E402
import bq                                              # noqa: E402
from make_mk1_raiden_pal import read_img, write_img    # noqa: E402


def psx_to_midway(w):
    """PSX BGR555 (R low) -> Midway word order (R high).  Swap R and B."""
    r, g, b = w & 31, (w >> 5) & 31, (w >> 10) & 31
    return (r << 10) | (g << 5) | b


def build():
    D = Dat(str(NINJA))
    tbl = D.d[D.tableend:D.palbase]
    t0 = bq.u16(tbl, 0)
    timgs, tpals = read_img(TEMPLATE)
    img_raw, pal_raw = timgs[0]["raw"], tpals[0]["raw"]

    # every palette a frame actually references, plus Rain's two costumes
    used = sorted({r["pal"] for r in D.recs} | {DEFAULT_PAL, ALT_PAL})
    slot = {pi: i for i, pi in enumerate(used)}
    pals = []
    for pi in used:
        if pi == DEFAULT_PAL:   nm = PAL_NAMES[0]
        elif pi == ALT_PAL:     nm = PAL_NAMES[1]
        else:                   nm = "NJP%02d" % pi
        words = [0] + [psx_to_midway(c) for c in D.pals[pi]]   # idx0 transparent
        pals.append(dict(name=nm, palnum=3 + slot[pi], bpp=6, words=words, raw=pal_raw))

    imgs = []
    for r in D.recs:
        pw = (r["w"] + 3) & 0xFC
        hh = r["h"] // t0 * t0
        out, _u, _b, _i = bq.decode(
            tbl, D.d[r["off"]:r["off"] + r["size"] + 2048], pw, hh, 4)
        if len(out) != pw * hh:
            sys.exit("frame %d: %d bytes, expected %d" % (r["i"], len(out), pw * hh))
        rows = [list(out[y * pw:y * pw + r["w"]]) for y in range(hh)]
        imgs.append(dict(name="RNPSX%03d" % r["i"], w=r["w"], h=hh,
                         palnum=3 + slot[r["pal"]], ax=r["ax"], ay=r["ay"],
                         px=rows, raw=img_raw))
    return imgs, pals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    OUTDIR.mkdir(parents=True, exist_ok=True)
    imgs, pals = build()
    if a.check:
        if not OUT.exists():
            sys.exit("missing " + str(OUT))
        import tempfile
        t = Path(tempfile.mkdtemp()) / "x.img"
        write_img(t, imgs, pals)
        if hashlib.sha1(t.read_bytes()).hexdigest() != hashlib.sha1(OUT.read_bytes()).hexdigest():
            sys.exit("RAINPSX.IMG has drifted - re-run without --check")
        print("RAINPSX.IMG ok (%d frames, %d palettes)" % (len(imgs), len(pals)))
        return
    n = write_img(OUT, imgs, pals)
    print("wrote %s: %d bytes, %d frames, %d palettes" % (OUT, n, len(imgs), len(pals)))
    print("  default palette = NINJA.DAT #%d, alternate = #%d" % (DEFAULT_PAL, ALT_PAL))


if __name__ == "__main__":
    main()
