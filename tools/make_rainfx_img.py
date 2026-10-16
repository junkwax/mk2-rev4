#!/usr/bin/env python3
r"""Build data/RAINPSX/RAINFX.IMG - just RAIN's EFFECT art from the PC/PSX build.

A working library for subframe cutting: the lightning bolt and the whole water
move, pulled out of the 721-frame ninja set so they can be opened and chopped
in IMGTOOL without wading through the body frames.

Source is CHARS1/NINJA.DAT from the PC DOS build (byte-identical to the PSX
disc), decoded by POVBQDecode_ - see data/RAINPSX/README.md for the container
and codec.  Pixels are the port's own; nothing is redrawn or rescaled.

Contents (42 frames, 3 palettes):

  RAINLT1-6    pal 45  the bolt as the game draws it.  RAINLT3A/4A merge the
                       shaft with its ground splash, which the N64 kept as
                       separate slave pieces - these are the frames that most
                       want cutting into subframes.
  RNLTX1-4     pal 45  four more frames on the bolt's palette that are NOT the
                       bolt: they anchor at x -108, the water cloud's travel
                       plateau, so they belong to the water move's discharge.
  RNCLD01-12   pal 43  the cloud forming and looping
  RNZAP1-6     pal 43  the burst
  RNDROP01-14  pal 43  the raindrops

ANIPOINTS ARE THE PORT'S RAW VALUES, not re-anchored.  make_rainbolt_img.py
applies the strike-point shift (PX,PY = 53,82) when it builds the shipping
RAINBOLT.IMG; keeping them raw here means what you see is what the port
stored, and the shift stays in one place.

    python tools/make_rainfx_img.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = Path(r"C:/Users/you/AppData/Local/Temp/claude/c--Users-you-Workplace-mk2-main"
               r"/9e8c48f3-2acb-44fc-91d2-e51f3ab0ed61/scratchpad")
NINJA = SCRATCH / "disc" / "CHARS1" / "NINJA.DAT"
OUT = ROOT / "data" / "RAINPSX" / "RAINFX.IMG"
TEMPLATE = ROOT / "data" / "RAINN64.IMG"

sys.path.insert(0, str(SCRATCH))
sys.path.insert(0, str(ROOT / "tools"))
from mkt import Dat                                    # noqa: E402
import bq                                              # noqa: E402
from make_mk1_raiden_pal import read_img, write_img    # noqa: E402

# frame index -> (record name, palette group)
GROUPS = (
    [(560, "RAINLT1"), (561, "RAINLT2"), (562, "RAINLT3A"), (563, "RAINLT4A"),
     (564, "RAINLT5"), (565, "RAINLT6")] +
    [(566 + k, "RNLTX%d" % (k + 1)) for k in range(4)] +
    [(506 + k, "RNCLD%02d" % (k + 1)) for k in range(12)] +
    [(518 + k, "RNZAP%d" % (k + 1)) for k in range(6)] +
    [(546 + k, "RNDROP%02d" % (k + 1)) for k in range(14)]
)
PAL_NAMES = {45: "RNBOLT_P", 43: "RNWATER_P"}


def psx_to_midway(w):
    """PSX BGR555 (red LOW) -> Midway IMG 0RRRRRGGGGGBBBBB (red HIGH)."""
    r, g, b = w & 31, (w >> 5) & 31, (w >> 10) & 31
    return (r << 10) | (g << 5) | b


def main():
    D = Dat(str(NINJA))
    tbl = D.d[D.tableend:D.palbase]
    t0 = bq.u16(tbl, 0)
    timgs, tpals = read_img(TEMPLATE)
    img_raw, pal_raw = timgs[0]["raw"], tpals[0]["raw"]
    byi = {r["i"]: r for r in D.recs}

    used = []
    for idx, _nm in GROUPS:
        p = byi[idx]["pal"]
        if p not in used:
            used.append(p)
    slot = {p: i for i, p in enumerate(used)}
    pals = [dict(name=PAL_NAMES.get(p, "NJP%02d" % p), palnum=3 + slot[p], bpp=6,
                 words=[0] + [psx_to_midway(c) for c in D.pals[p]], raw=pal_raw)
            for p in used]

    imgs = []
    for idx, nm in GROUPS:
        r = byi[idx]
        pw = (r["w"] + 3) & 0xFC
        hh = r["h"] // t0 * t0
        out, _u, _b, _i = bq.decode(
            tbl, D.d[r["off"]:r["off"] + r["size"] + 2048], pw, hh, 4)
        if len(out) != pw * hh:
            sys.exit("%s: decoded %d bytes, expected %d" % (nm, len(out), pw * hh))
        imgs.append(dict(name=nm, w=r["w"], h=hh, palnum=3 + slot[r["pal"]],
                         ax=r["ax"], ay=r["ay"],
                         px=[list(out[y * pw:y * pw + r["w"]]) for y in range(hh)],
                         raw=img_raw))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    n = write_img(OUT, imgs, pals)
    print("wrote %s: %d bytes, %d frames, %d palettes" % (OUT, n, len(imgs), len(pals)))
    for p in pals:
        print("   palette %-10s palnum %d  %d colours" % (p["name"], p["palnum"], len(p["words"])))
    for r in imgs:
        print("   %-11s %4dx%-4d ani=(%5d,%5d) pal=%d" %
              (r["name"], r["w"], r["h"], r["ax"], r["ay"], r["palnum"]))


if __name__ == "__main__":
    main()
