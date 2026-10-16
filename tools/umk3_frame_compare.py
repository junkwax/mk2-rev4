#!/usr/bin/env python3
"""Render UMK3's boomerang frames next to ours, as PNGs, to compare by eye.

Top strip  = the arcade, decoded straight out of the UMK3 graphics ROMs with
             its own palette (tools/umk3_gfx_extract.py does the decoding).
Bottom strip = the same frames out of our data/JADERANG.IMG with BOOMRNG_P.

Frames are drawn on their own anipoint: each cell has a crosshair at the
anchor and every frame is placed at [cell anchor - anipoint], which is exactly
what the display does. That makes anchor drift visible rather than hiding it
behind per-frame centring.

    python tools/umk3_frame_compare.py --out tmp/boom_compare.png
"""
import argparse
import importlib.util
import re
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# UMK3 flight lane, in lane order, plus the trail frame it stamps.
# (label, sag, w, h, anix, aniy, control)
UMK3_FRAMES = [
    ("REL4",  0x0651DE8C, 51, 18, 25,  5, 0x6880),
    ("SPIN1", 0x0651ECA2, 48, 29, 27, 12, 0x6580),
    ("SPIN2", 0x0651F666, 18, 50, 13, 23, 0x6080),
    ("SPIN3", 0x065203AE, 29, 47, 16, 25, 0x6580),
    ("SPIN4", 0x06521258, 50, 18, 26, 12, 0x6280),
    ("SPIN5", 0x06522062, 47, 29, 21, 16, 0x6580),
    ("SPIN6", 0x06522A20, 19, 49,  5, 26, 0x6080),
    ("trail", 0x064FD214, 39, 38, 71, -8, 0x6480),
]
# Our equivalents.  ANIPOINTS COME FROM src/JADERANG.TBL, NOT THE IMG - the
# TBL is what the game links, and for these frames it deliberately carries
# different values (the IMG holds a one-way authoring path whose anipoints
# sweep the art 105px across the lane).  Reading the IMG here draws every
# frame off its own cell and tells you nothing.
# (name in the TBL, name of the record whose PIXELS to use)
OURS = [("BRANG3F", "BRANG3"), ("BRANG4", "BRANG4"), ("BRANG5", "BRANG5"),
        ("BRANG6", "BRANG6"), ("BRANG7", "BRANG7"), ("BRANG8", "BRANG8"),
        ("BRANG9", "BRANG9"), ("BOOMGHOST", "BOOMGHOST")]

UMK3_PAL = [0x0000, 0x7FFF, 0x7ADF, 0x6E5D, 0x61FC, 0x599A, 0x4916, 0x3CB3,
            0x3892, 0x3491, 0x3070, 0x282D, 0x240C, 0x200A, 0x1407, 0x1006]
OUR_PAL = [0x0000, 0x1006, 0x3cb3, 0x4916, 0x61fc, 0x6e5d, 0x7fff, 0x3892,
           0x282d, 0x240c, 0x200a, 0x599a, 0x7adf, 0x3070, 0x1407, 0x3491]

CELL_W, CELL_H = 96, 96
ANCHOR = (48, 48)
BG = (26, 26, 32)


def rgb(c):
    """5:5:5 -> 8:8:8"""
    r, g, b = (c >> 10) & 31, (c >> 5) & 31, c & 31
    return (r * 255 // 31, g * 255 // 31, b * 255 // 31)


def load_gfx():
    spec = importlib.util.spec_from_file_location("g", HERE / "umk3_gfx_extract.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    return g


def img_records():
    """every record in our JADERANG.IMG, by name"""
    data = (ROOT / "data" / "JADERANG.IMG").read_bytes()
    LIB = struct.Struct("<HHIHHHHH 4s HHH")
    IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
    imgcnt, palcnt, oset = LIB.unpack_from(data, 0)[:3]
    out = {}
    for i in range(imgcnt):
        rec = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        name = rec[0].split(b"\0")[0].decode("latin-1")
        anix = rec[2] - 0x10000 if rec[2] & 0x8000 else rec[2]
        aniy = rec[3] - 0x10000 if rec[3] & 0x8000 else rec[3]
        w, h, off = rec[4], rec[5], rec[7]
        # rows are padded to a multiple of 4 bytes - see umk3_gfx_extract.py
        stride = (w + 3) & ~3
        px = b"".join(data[off + y * stride: off + y * stride + w] for y in range(h))
        out[name] = (w, h, anix, aniy, px)
    return out


def tbl_anipoints():
    """name -> (w, h, anix, aniy) out of src/JADERANG.TBL"""
    txt = (ROOT / "src" / "JADERANG.TBL").read_text(errors="replace")
    out, label = {}, None
    for line in txt.splitlines():
        m = re.match(r"^(\w+):\s*$", line)
        if m:
            label = m.group(1)
            continue
        m = re.match(r"^\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)", line)
        if m and label:
            out[label] = tuple(int(v) for v in m.groups())
            label = None
    return out


def cell(px, w, h, anix, aniy, pal, label, sub):
    im = Image.new("RGB", (CELL_W, CELL_H), BG)
    d = ImageDraw.Draw(im)
    ax, ay = ANCHOR
    # the anchor crosshair, drawn under the art
    d.line([(ax - 6, ay), (ax + 6, ay)], fill=(70, 70, 90))
    d.line([(ax, ay - 6), (ax, ay + 6)], fill=(70, 70, 90))
    ox, oy = ax - anix, ay - aniy
    for y in range(h):
        for x in range(w):
            v = px[y * w + x]
            if not v:
                continue
            px_x, px_y = ox + x, oy + y
            if 0 <= px_x < CELL_W and 0 <= px_y < CELL_H:
                im.putpixel((px_x, px_y), rgb(pal[v & 15]))
    d.text((2, 2), label, fill=(200, 200, 210))
    d.text((2, CELL_H - 10), sub, fill=(130, 130, 145))
    return im


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=ROOT / "tmp" / "boom_compare.png")
    ap.add_argument("--scale", type=int, default=2)
    args = ap.parse_args()

    g = load_gfx()
    vid = g.load_video(g.ROM_ZIP)
    ours = img_records()

    n = len(UMK3_FRAMES)
    sheet = Image.new("RGB", (CELL_W * n, CELL_H * 2), BG)
    for i, (label, sag, w, h, anix, aniy, ctrl) in enumerate(UMK3_FRAMES):
        px = g.pixels(vid, sag, w, h, 6, ctrl)
        if px is None:
            sys.exit("could not decode %s" % label)
        sheet.paste(cell(px, w, h, anix, aniy, UMK3_PAL, label,
                         "%dx%d @%d,%d" % (w, h, anix, aniy)), (CELL_W * i, 0))
    tbl = tbl_anipoints()
    for i, (tname, pixname) in enumerate(OURS):
        rec = ours.get(pixname)
        if rec is None or tname not in tbl:
            continue
        w, h, _ix, _iy, px = rec
        tw, th, anix, aniy = tbl[tname]
        sheet.paste(cell(px, w, h, anix, aniy, OUR_PAL, tname,
                         "%dx%d @%d,%d" % (tw, th, anix, aniy)), (CELL_W * i, CELL_H))

    if args.scale > 1:
        sheet = sheet.resize((sheet.width * args.scale, sheet.height * args.scale),
                             Image.NEAREST)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print("wrote %s  (top = UMK3 arcade, bottom = ours)" % args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
