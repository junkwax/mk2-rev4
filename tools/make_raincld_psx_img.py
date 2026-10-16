#!/usr/bin/env python3
r"""Build Rain's WATER MOVE art from the MK Trilogy PC/PSX build.

Writes data/RAINPSX/RAINCLD.IMG by default - a STAGING copy for inspection in
IMGTOOL.  Pass --ship to write data/RAINCLD.IMG instead, which is only correct
once RAINCLD.LOD and MKNJ.ASM have been updated to match (frame counts change).

Source: CHARS1/NINJA.DAT palette 43, decoded by POVBQDecode_.  One palette
carries all three families on the PSX, where the N64 split them:

    cloud forming   RNPSX506-512  -> RAPROFORM1-7   (N64 had 5)
    cloud looping   RNPSX513-517  -> RAPROLOOP1-5   (N64 had 3)
    burst           RNPSX518-523  -> RNZAP11-16     (N64 had 5)
    raindrops       RNPSX546-559  -> RNDROP01-13    (N64 had 14 - unchanged)

## The palette cycle

rzap_cycle (MKZAP.ASM) rotates a window of this palette so the water FLOWS.
That needs the shades in one contiguous LUMINANCE ramp - rotating Trilogy's
authored order just swaps unrelated colours and reads as corruption.  So
slots 1..31 are sorted ascending by luma and every pixel is remapped.

MEASURED on this art: median adjacent-pixel step 1.0 of a possible 31, 63%
of adjacent pairs within 2 (the N64 art scored 1.0 / 67%), so it carries a
ramp cycle as well as the N64 did.  Sorted ascending, slots 1-16 hold 75% of
non-transparent pixels, so that is the window - and because it is the DARK
end, the bright highlights at 17-31 stay put, which is what the N64 version
achieved by freezing slots 0-4.

## RNZAP_P IS RETIRED, and the frozen slots with it

On the N64 the burst was separate 3bpp art whose palette was literally
RNCLOUD_P's first 8 entries, which is why slots 0-4 were frozen.  The PSX art
has no such split: the burst uses indices 5..31, overlapping the cloud on 26
of them.  There is no arrangement where the cloud cycles and the burst does
not, so THE BURST NOW FLOWS TOO.  Defensible - it is water, and the freeze was
an artifact of the N64's separate art - but it is a visible change.
rzapcyc (MAINEQU.ASM) still compiles the whole cycle out.

## Anipoints

DERIVED, not inherited.  Comparing raw anipoints frame by frame, the PSX
values sit at a near-constant offset from the N64's: y consistently +8 (+/-1),
x about -2.5.  The N64 tool's ADJ_Y=9 (adj_rain_proj) therefore becomes
ADJ_Y=1 here, with ADJ_X=2 on the other axis; SCF_X/SCF_Y are unchanged.
Reusing ADJ_Y=9 would sit every cloud frame ~9 px low.  The y offset is tight
and trustworthy; the x nudge is the weaker number, because the PSX has 12
forming/loop frames against the N64's 8 so the frame pairing behind it is
approximate.
"""
import argparse, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = Path(r"C:/Users/you/AppData/Local/Temp/claude/c--Users-you-Workplace-mk2-main"
               r"/9e8c48f3-2acb-44fc-91d2-e51f3ab0ed61/scratchpad")
NINJA = SCRATCH / "disc" / "CHARS1" / "NINJA.DAT"
TEMPLATE = ROOT / "data" / "RAINN64.IMG"
PSX_PAL = 43
SCF_X, SCF_Y = 0.80, 0.85
ADJ_X, ADJ_Y = 2, 1
CYC_START, CYC_COUNT = 1, 16

NAMES = ([(506 + k, "RAPROFORM%d" % (k + 1)) for k in range(7)] +
         [(513 + k, "RAPROLOOP%d" % (k + 1)) for k in range(5)] +
         [(518 + k, "RNZAP1%d" % (k + 1)) for k in range(6)] +
         [(546 + k, "RNDROP%02d" % (k + 1)) for k in range(5)] +
         [(551, "RNDROP5B")] +
         [(552 + k, "RNDROP%02d" % (k + 6)) for k in range(8)])

sys.path.insert(0, str(SCRATCH)); sys.path.insert(0, str(ROOT / "tools"))
from mkt import Dat                                    # noqa: E402
import bq                                              # noqa: E402
from make_mk1_raiden_pal import read_img, write_img    # noqa: E402


def psx_to_midway(w):
    r, g, b = w & 31, (w >> 5) & 31, (w >> 10) & 31
    return (r << 10) | (g << 5) | b


def luma(w):
    r, g, b = w & 31, (w >> 5) & 31, (w >> 10) & 31
    return (r * 299 + g * 587 + b * 114) / 1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ship", action="store_true")
    a = ap.parse_args()
    out_path = (ROOT / "data" / "RAINCLD.IMG") if a.ship \
        else (ROOT / "data" / "RAINPSX" / "RAINCLD.IMG")

    D = Dat(str(NINJA))
    tbl = D.d[D.tableend:D.palbase]
    t0 = bq.u16(tbl, 0)
    src = D.pals[PSX_PAL]                      # 31 stored, index 0 implicit
    if len(src) + 1 != 32:
        sys.exit("palette %d has %d entries, expected 32" % (PSX_PAL, len(src) + 1))

    # luminance ramp over slots 1..31; slot 0 stays transparent
    order = [0] + sorted(range(1, 32), key=lambda i: luma(src[i - 1]))
    perm = {old: new for new, old in enumerate(order)}
    cols = [0] + [psx_to_midway(src[old - 1]) for old in order[1:]]

    timgs, tpals = read_img(TEMPLATE)
    img_raw, pal_raw = timgs[0]["raw"], tpals[0]["raw"]
    byi = {r["i"]: r for r in D.recs}
    imgs = []
    for idx, nm in NAMES:
        r = byi[idx]
        if r["pal"] != PSX_PAL:
            sys.exit("%s (frame %d) is on palette %d" % (nm, idx, r["pal"]))
        pw = (r["w"] + 3) & 0xFC
        hh = r["h"] // t0 * t0
        dec, _u, _b, _i = bq.decode(tbl, D.d[r["off"]:r["off"] + r["size"] + 2048], pw, hh, 4)
        rows = [[perm[v] for v in dec[y * pw:y * pw + r["w"]]] for y in range(hh)]
        imgs.append(dict(name=nm, w=r["w"], h=hh, palnum=3,
                         ax=round((r["ax"] + ADJ_X) / SCF_X),
                         ay=round((r["ay"] + ADJ_Y) / SCF_Y),
                         px=rows, raw=img_raw))
    pals = [dict(name="RNCLOUD_P", palnum=3, bpp=5, words=cols, raw=pal_raw),
            dict(name="RNDROP_P",  palnum=4, bpp=5, words=cols, raw=pal_raw)]
    for r in imgs:
        if r["name"].startswith("RNDROP"):
            r["palnum"] = 4
    out_path.parent.mkdir(parents=True, exist_ok=True)
    n = write_img(out_path, imgs, pals)
    px = sum(r["w"] * r["h"] for r in imgs)
    print("wrote %s: %d bytes, %d frames, %d palettes" % (out_path, n, len(imgs), len(pals)))
    print("  %d px, %d bytes at 5bpp before LOAD2 (slot 32768)" % (px, px * 5 // 8))
    print("  cycle window slots %d..%d (count %d, power of two)"
          % (CYC_START, CYC_START + CYC_COUNT - 1, CYC_COUNT))
    for r in imgs:
        print("   %-11s %3dx%-3d ani(%5d,%5d) pal=%d" %
              (r["name"], r["w"], r["h"], r["ax"], r["ay"], r["palnum"]))


if __name__ == "__main__":
    main()
