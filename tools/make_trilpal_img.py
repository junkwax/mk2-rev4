#!/usr/bin/env python3
r"""Build data/RAINPSX/TRILPAL.IMG - JOHNNY CAGE'S and RAIN'S PALETTES out of the
MK Trilogy PC/PSX build, each with a sprite to judge it against.

A palette on its own cannot be judged, so every palette here carries a STANCE
FRAME drawn in it - the same convention data/MK2PALS.IMG uses.  The six image
records are only TWO distinct pictures: Cage's stance repeated under his four
palettes and the male-ninja stance under Rain's two.  They differ in `palnum`
and nothing else, which is what makes a swapped palette visible at a glance.

Source is the same PC DOS tree data/RAINPSX/README.md describes, which ships the
PSX disc's .DAT files byte for byte.  Container and codecs are that file's;
nothing new is reverse-engineered here.

WHERE THE PIXELS COME FROM, and why Cage comes out of CHARS2.
Cage ships twice: CHARS1/CAGE.DAT carries 296 frames RLE-packed (codec class 1)
at their true geometry, CHARS2/CAGEBQ.DAT the same 296 under the block-quantised
codec (class 2) with every width rounded UP to a multiple of 4 and the anipoint
moved by half the padding - rec 0 is 108x44 ani (34,-60) in one and 112x44 ani
(36,-60) in the other, so the padding is symmetric and the art does not move.
Only the BQ path is proven: all 296 decode to exactly their declared size.  The
RLE path is NOT used, because RLEDecode_'s two bit widths are not in the file -
CAGE.DAT's data begins at the record table's last byte, so there is no table
region to hold them - and fitting them from the data alone gets 6 bits per pixel
(the palettes are 64 colours and no frame ever exceeds index 63) but no run
width that decodes all 296 frames.  Until that is read out of MKTRIL.EXE the BQ
copy is the honest source: the same art, plus 0..3 px of transparent padding.

THE NINJA BODY IS SHARED, so Rain's frame is the shared male-ninja stance - he
has no art of his own, exactly as data/RAINPSX/README.md records.

WHICH PALETTES THESE ARE - measured, not assumed.

Cage's file carries 13.  Four are 63-colour (64 with the implicit transparent
index 0) and only ONE of them is referenced by any frame:

    pal1  248 of 296 frames   his default costume
    pal3  no frames           47 of 63 entries identical to pal1; the 16 that
                              differ are the costume accent, BLUE in pal1 and
                              RED here.  That is an alternate costume, and the
                              "same ramp, recoloured accent" shape is what
                              proves it is one rather than another effect.
    pal0  no frames           a flat GREEN luminance ramp, 1 of 63 entries
                              shared with pal1 - a monochrome treatment, not a
                              costume
    pal2  no frames           a flat BLUE-GREY ramp, 0 of 63 shared

A palette no frame references is normal: the game picks the costume at runtime,
so every frame in the file is stamped with the default.

Rain's are NINJA.DAT's.  Fifteen of its palettes are 39-colour ninja palettes
and they share entries 0..23 - the flesh and black ramp every ninja wears -
differing ONLY at entries 24..38, a 15-colour costume block.  Taking the mean
hue of that block alone separates them cleanly:

    pal7  306 deg   pal9  294 deg     the only two purple ones
    pal5  199       pal6  212         blue
    pal10  46                         yellow
    pal16 (the file's own default, 304 frames) is GREEN

PAL7/PAL9 REMAIN AN INFERENCE.  Purple is Rain's and no other fighter's, and
these are the only purple pair - the same argument make_rainpsx_img.py makes,
now on the costume block alone instead of all 39 entries, which is the sharper
measurement because the shared body ramp cannot dilute it.  It is still not a
table lookup.  data/RAINPSX/README.md records the conflict with the
select-screen position; nothing here resolves it.  These two palettes are
byte-identical to RAINPSX.IMG's RNPSX_P / RNPSXALT and carry different names on
purpose - a duplicate record name is silently wrong in this tree, and both
libraries may sit open in IMGTOOL at once.

THIS FILE IS IN NO LOD.  Nothing it holds reaches a ROM; it is a bench to look
at the colours on, the way data/MK2PALS.IMG is.  Moving a palette onto a lane
means putting a record into MK2PALS.IMG under the <XX>MAIN_P / <XX>ALT1-5_P
scheme and letting tools/make_costume_palettes.py wire it.

    python tools/make_trilpal_img.py            # write the library
    python tools/make_trilpal_img.py --report   # the measurements above
    python tools/make_trilpal_img.py --check    # fail if it has drifted
"""
import argparse, colorsys, hashlib, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# the PC/PSX tree, unpacked by the session that wrote data/RAINPSX/README.md
DISC = Path(r"C:/Users/you/AppData/Local/Temp/claude/c--Users-you-Workplace-mk2-main"
            r"/9e8c48f3-2acb-44fc-91d2-e51f3ab0ed61/scratchpad")
CAGE = DISC / "disc" / "CHARS2" / "CAGEBQ.DAT"     # BQ copy - see the note above
NINJA = DISC / "disc" / "CHARS1" / "NINJA.DAT"
OUT = ROOT / "data" / "RAINPSX" / "TRILPAL.IMG"
TEMPLATE = ROOT / "data" / "RAINN64.IMG"           # record-struct templates only

CAGE_STANCE = 1                                    # CAGEBQ rec 1, 52x114
NINJA_STANCE = 9                                   # NINJA  rec 9, 40x124
NINJA_COSTUME = slice(24, 39)                      # the 15 entries that are the costume

#            file palette, palette name, image name, what it is
CAGE_PALS = [(1, "TJCMAIN_P", "TJC_MAIN", "default costume"),
             (3, "TJCALT_P",  "TJC_ALT",  "alternate costume (red accent)"),
             (0, "TJCGRN_P",  "TJC_GRN",  "green monochrome ramp"),
             (2, "TJCBLU_P",  "TJC_BLU",  "blue-grey monochrome ramp")]
RAIN_PALS = [(7, "TRNMAIN_P", "TRN_MAIN", "purple, costume hue 306 deg"),
             (9, "TRNALT_P",  "TRN_ALT",  "purple, costume hue 294 deg")]

sys.path.insert(0, str(DISC))
sys.path.insert(0, str(ROOT / "tools"))
from mkt import Dat                                     # noqa: E402
import bq                                               # noqa: E402
from make_mk1_raiden_pal import read_img, write_img      # noqa: E402


def psx_to_midway(w):
    """PSX BGR555 (red in the LOW bits) -> Midway xRRRRRGGGGGBBBBB.  Swap R and B."""
    r, g, b = w & 31, (w >> 5) & 31, (w >> 10) & 31
    return (r << 10) | (g << 5) | b


def decode_frame(D, idx):
    """One record's pixels, cropped back to its declared width."""
    tbl = D.d[D.tableend:D.palbase]
    t0 = bq.u16(tbl, 0)
    r = D.recs[idx]
    pw, hh = (r["w"] + 3) & 0xFC, r["h"] // t0 * t0
    out, _sp, _bpp, _sub = bq.decode(
        tbl, D.d[r["off"]:r["off"] + r["size"] + 2048], pw, hh, 4)
    if len(out) != pw * hh:
        sys.exit("record %d decoded %d bytes, expected %d" % (idx, len(out), pw * hh))
    return r, [list(out[y * pw:y * pw + r["w"]]) for y in range(hh)], hh


def build():
    timgs, tpals = read_img(TEMPLATE)
    img_raw, pal_raw = timgs[0]["raw"], list(tpals[0]["raw"])
    pal_raw[2] = 6                    # 64 slots; the template palette is 5bpp/32
    pal_raw = tuple(pal_raw)

    imgs, pals = [], []
    for D, frame, table in ((Dat(str(CAGE)), CAGE_STANCE, CAGE_PALS),
                            (Dat(str(NINJA)), NINJA_STANCE, RAIN_PALS)):
        rec, px, h = decode_frame(D, frame)
        for pi, pname, iname, _what in table:
            palnum = 3 + len(pals)    # IMG palette numbering starts at NUMDEFPAL
            # index 0 is transparent and is not stored in the .DAT palette chain
            words = [0] + [psx_to_midway(c) for c in D.pals[pi]]
            pals.append(dict(name=pname, palnum=palnum, bpp=6, words=words, raw=pal_raw))
            imgs.append(dict(name=iname, w=rec["w"], h=h, palnum=palnum,
                             ax=rec["ax"], ay=rec["ay"], px=px, raw=img_raw))
    return imgs, pals


def report():
    def rgb(w):
        return (w & 31) * 8, ((w >> 5) & 31) * 8, ((w >> 10) & 31) * 8

    C = Dat(str(CAGE))
    print("JOHNNY CAGE - %s, %d frames, %d palettes" % (CAGE.name, len(C.recs), len(C.pals)))
    base = C.pals[1]
    for pi, pname, _iname, what in CAGE_PALS:
        p = C.pals[pi]
        used = sum(1 for r in C.recs if r["pal"] == pi)
        same = sum(1 for a, b in zip(base, p) if a == b)
        print("  pal%-2d -> %-10s %2d colours, %3d frames use it, %2d/%d entries "
              "shared with pal1   %s" % (pi, pname, len(p), used, same, len(base), what))

    N = Dat(str(NINJA))
    print("\nRAIN - %s.  Ninja palettes share entries 0..23; the costume is 24..38."
          % NINJA.name)
    for i, p in enumerate(N.pals):
        if len(p) != 39:
            continue
        cols = [rgb(c) for c in p[NINJA_COSTUME]]
        hs = [colorsys.rgb_to_hsv(*[x / 255 for x in c])[0] * 360
              for c in cols if max(c) > 40]
        used = sum(1 for r in N.recs if r["pal"] == i)
        mark = next((nm for pi2, nm, _i, _w in RAIN_PALS if pi2 == i), "")
        print("  pal%-2d costume hue %3.0f deg  %3d frames  %s"
              % (i, sum(hs) / len(hs) if hs else -1, used, mark))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the library has drifted")
    ap.add_argument("--report", action="store_true", help="print the palette measurements")
    a = ap.parse_args()
    if a.report:
        report()
        return
    imgs, pals = build()
    if a.check:
        if not OUT.exists():
            sys.exit("missing " + str(OUT))
        import tempfile
        t = Path(tempfile.mkdtemp()) / "x.img"
        write_img(t, imgs, pals)
        if hashlib.sha1(t.read_bytes()).hexdigest() != \
           hashlib.sha1(OUT.read_bytes()).hexdigest():
            sys.exit("TRILPAL.IMG has drifted - re-run without --check")
        print("TRILPAL.IMG ok (%d frames, %d palettes)" % (len(imgs), len(pals)))
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    n = write_img(OUT, imgs, pals)
    print("wrote %s: %d bytes" % (OUT, n))
    for i, p in zip(imgs, pals):
        print("   %-9s %3dx%-3d ani=(%4d,%4d)  on %-10s %2d colours"
              % (i["name"], i["w"], i["h"], i["ax"], i["ay"], p["name"], len(p["words"])))


if __name__ == "__main__":
    main()
