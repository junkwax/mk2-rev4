#!/usr/bin/env python3
"""THE CAVE's floor, FL_CAVE.BIN <-> FL_CAVE.IMG, so it can be edited in IMGTOOL.

data/FL_CAVE.BIN is what the build packs (data/CAVEFLR.LOD, `FRM> FL_CAVE`):
UMK3's Kahn's Kave floor, 1200x42, raw 6bpp, little-endian bit order, NO
header and NO palette - which is why no viewer can open it.  Its palette is
MK3's CAVEFL_P, carried in tools/make_mk3cave.py (the build's copy).

    python tools/fl_cave_img.py             # BIN -> data/FL_CAVE.IMG
    python tools/fl_cave_img.py --to-bin    # edited IMG -> data/FL_CAVE.BIN
    python tools/fl_cave_img.py --check     # IMG and BIN hold the same pixels

The IMG is the EDITING copy; the BIN is still what ships.  After --to-bin run
`python build.py` - CAVEFLR.LOD repacks it.  Rules for an edit:

  - keep it 1200x42.  MKDISP's floor_code draws exactly floor_x (1200) wide
    rows and the SAG/slot math in make_mk3cave.py assumes 42 rows.
  - stay on the one palette, indices 0..63 (6bpp).  Changing a COLOUR means
    editing CAVEFL_P in tools/make_mk3cave.py, not the IMG's palette -
    --to-bin warns if the IMG's palette differs from it.
  - index 0 is NOT transparent here: a floor is drawn raw (ZOF>), every pixel.

The IMG layout is the one tools/make_rain_img.py writes and IMGTOOL/LOAD2 read:
a 28-byte library header, palette data, 8bpp pixel rows padded to 4, then the
50-byte image records and 26-byte palette records at `oset`.
"""
from __future__ import annotations

import argparse
import importlib.util
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN_PATH = REPO / "data" / "FL_CAVE.BIN"
IMG_PATH = REPO / "data" / "FL_CAVE.IMG"

LIB_HDR = struct.Struct("<HHIHHHHH4sHHH")
IMAGE = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")
assert (LIB_HDR.size, IMAGE.size, PALETTE.size) == (28, 50, 26)

NUMDEFPAL = 3           # palcnt on disk counts three palettes not in the file
IMG_VERSION = 0x062E
W, H, BPP = 1200, 42, 6
IMG_NAME = "FL_CAVE"
PAL_NAME = "CAVEFL_P"


def cavefl_p() -> list[int]:
    spec = importlib.util.spec_from_file_location("make_mk3cave", REPO / "tools" / "make_mk3cave.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return list(mod.CAVEFL_P)


def bin_to_pixels(raw: bytes) -> list[int]:
    if len(raw) * 8 != W * H * BPP:
        raise SystemExit(f"{BIN_PATH.name}: {len(raw)} bytes, expected {W * H * BPP // 8} "
                         f"for {W}x{H} at {BPP}bpp")
    bits = int.from_bytes(raw, "little")
    return [(bits >> (BPP * i)) & 63 for i in range(W * H)]


def pixels_to_bin(px: list[int]) -> bytes:
    bits = 0
    for i, v in enumerate(px):
        if v > 63:
            raise SystemExit(f"pixel {i % W},{i // W} is index {v} - past 63, not 6bpp")
        bits |= v << (BPP * i)
    return bits.to_bytes(W * H * BPP // 8, "little")


def build_img(px: list[int], pal: list[int]) -> bytes:
    out = bytearray(LIB_HDR.size)
    pal_oset = len(out)
    for c in pal:
        out += struct.pack("<H", c)
    data_oset = len(out)
    stride = (W + 3) & ~3
    for y in range(H):
        out += bytes(px[y * W:(y + 1) * W]) + bytes(stride - W)
    oset = len(out)
    out += IMAGE.pack(IMG_NAME.encode("ascii"), 0, 0, 0, W, H, 0 + NUMDEFPAL,
                      data_oset, 0, 0, 0, 0, 0xFFFF, 0, 0xFFFF, 0xFFFF)
    out += PALETTE.pack(PAL_NAME.encode("ascii"), 0, BPP, len(pal), pal_oset,
                        0, 0, 0, 0, 0)
    LIB_HDR.pack_into(out, 0, 1, 1 + NUMDEFPAL, oset, IMG_VERSION,
                      0, 0, 0, 0xABCD, b"\0\0\0\0", 0, 0, 0)
    return bytes(out)


def read_img(path: Path) -> tuple[list[int], list[int]]:
    d = path.read_bytes()
    imgcnt, palcnt, oset, *_ = LIB_HDR.unpack_from(d, 0)
    found = None
    for i in range(imgcnt):
        f = IMAGE.unpack_from(d, oset + i * IMAGE.size)
        name = f[0].split(b"\0")[0].decode("ascii", "replace")
        if name.upper() == IMG_NAME:
            found = f
            break
    if found is None:
        raise SystemExit(f"{path.name}: no image named {IMG_NAME}")
    _n, _fl, _ax, _ay, w, h, palnum, data_oset = found[:8]
    if (w, h) != (W, H):
        raise SystemExit(f"{path.name}: {IMG_NAME} is {w}x{h}, must stay {W}x{H}")
    stride = (w + 3) & ~3
    px = []
    for y in range(h):
        px.extend(d[data_oset + y * stride:data_oset + y * stride + w])
    pal = []
    pi = palnum - NUMDEFPAL
    poff = oset + imgcnt * IMAGE.size + pi * PALETTE.size
    if 0 <= pi < palcnt - NUMDEFPAL:
        _pn, _pf, _bits, numc, pdata = PALETTE.unpack_from(d, poff)[:5]
        pal = list(struct.unpack_from(f"<{numc}H", d, pdata))
    return px, pal


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--to-bin", action="store_true", help="write data/FL_CAVE.BIN from data/FL_CAVE.IMG")
    ap.add_argument("--check", action="store_true", help="fail if the IMG and BIN pixels differ")
    a = ap.parse_args()
    pal = cavefl_p()

    if a.check:
        px_img, _ = read_img(IMG_PATH)
        same = px_img == bin_to_pixels(BIN_PATH.read_bytes())
        print("FL_CAVE.IMG matches FL_CAVE.BIN" if same else
              "FL_CAVE.IMG and FL_CAVE.BIN differ - run --to-bin (IMG edited) or with no flag (BIN edited)")
        return 0 if same else 1

    if a.to_bin:
        px, img_pal = read_img(IMG_PATH)
        if img_pal and img_pal[:len(pal)] != pal:
            print("WARNING: the IMG's palette differs from CAVEFL_P (tools/make_mk3cave.py). "
                  "Only the INDICES go into FL_CAVE.BIN; the game keeps drawing CAVEFL_P.")
        raw = pixels_to_bin(px)
        if BIN_PATH.exists() and BIN_PATH.read_bytes() == raw:
            print("FL_CAVE.BIN already matches the IMG - nothing to write")
            return 0
        BIN_PATH.write_bytes(raw)
        print(f"wrote {BIN_PATH} ({len(raw)} bytes) - now run python build.py")
        return 0

    px = bin_to_pixels(BIN_PATH.read_bytes())
    img = build_img(px, pal)
    # prove the round trip before handing it over
    back, back_pal = read_img_bytes(img)
    if back != px or pixels_to_bin(back) != BIN_PATH.read_bytes() or back_pal != pal:
        raise SystemExit("round trip failed - FL_CAVE.IMG would not convert back to the same BIN")
    IMG_PATH.write_bytes(img)
    print(f"wrote {IMG_PATH} ({len(img)} bytes): {IMG_NAME} {W}x{H}, palette {PAL_NAME} "
          f"({len(pal)} colours, {BPP}bpp); round trip back to FL_CAVE.BIN verified byte-identical")
    return 0


def read_img_bytes(data: bytes):
    tmp = IMG_PATH.with_suffix(".IMG.tmp")
    tmp.write_bytes(data)
    try:
        return read_img(tmp)
    finally:
        tmp.unlink()


if __name__ == "__main__":
    sys.exit(main())
