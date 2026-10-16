#!/usr/bin/env python3
"""Build data/RAIN.IMG - the six MK3 rain frames, recovered from ROM.

MK3's src carries MKRAIN.TBL (six sprite records: four falling drops and two
splash frames) but NOT the art. The LOD that packed it,
mk3-rebuild/REV21/img/MKDMIL.LOD, names `c:\\video\\supermk3\\img\\RAIN.IMG`,
and that file is not in the leak - REV21/img has eight IMGs and RAIN is not
one of them. MK3's rain CODE is dead too: the whole `rain !!` block in its
MKDISP.ASM is commented out, `rain_ram` in its RAM.ASM with it, and what that
block plotted was a different asset (`drop_1`, an [offset,pixel] list) that
exists nowhere either. So there was nothing to port except six table records
pointing into an image ROM we do not have.

The PIXELS below were read back out of a UMK3 ROM set. UMK3's program ROM
still carries the same six records - the dead include survived into it - at
byte 0x9d6ec of the u54/u63 interleave, with SAGs 0x0bd58aab.. and control
word 0x3000 (3bpp). Decoding those SAGs against the assembled gfx ROMs gives
the art verbatim; the frames are transcribed here so this file, not a ROM on
somebody's disk, is the source of truth.

Four DROPs, one splash mask, two brightnesses - they are NOT an animation.
DROP2/3/4 share an identical pixel mask and differ only in which palette
entries they use, and DROP1 is the same streak drawn one row longer. Sorted
by mean luminance of the DROPS entries each one indexes:

    DROP1  entries 3,4,6   - white/light   BRIGHTEST -> nearest
    DROP2  entries 1,3,6,7 - mixed
    DROP3  entries 1,7     - medium/dark
    DROP4  entries 2,5     - dark          DIMMEST   -> furthest

peak_rain (BGND.ASM) picks the tier and the fall speed together, which is
what turns four brightness variants into depth.

The LOD is ZOF>: with 6px-wide art there is no transparent run long enough
for LOAD2's zero compression (minimum 10 pixels) to skip, so every record
packs to exactly w*h*3 bits. That is also how the UMK3 SAGs were confirmed -
their deltas are exactly 288, 288, 288, 432 bits.

Usage:
    python tools/make_rain_img.py            # write data/RAIN.IMG
    python tools/make_rain_img.py --check    # fail if the file has drifted
    python tools/make_rain_img.py --dump     # print the frames as art
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IMG_PATH = REPO / "data" / "RAIN.IMG"

LIB_HDR = struct.Struct("<HHIHHHHH4sHHH")
IMAGE = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")
assert (LIB_HDR.size, IMAGE.size, PALETTE.size) == (28, 50, 26)

NUMDEFPAL = 3           # palcnt on disk counts three palettes that are not in the file
IMG_VERSION = 0x062E    # what CASTLE.IMG / ACID1.IMG carry
PAL_NAME = "DROPS"
PAL_BITSPIX = 3

# DROPS, from mk3-rebuild REV21/IMGPAL8.ASM. 5R5G5B, entry 0 transparent.
# Cold greys with a blue lean - 1 is the only entry with any real colour in it.
DROPS = (0x0000, 0x4A54, 0x294E, 0x7BDE, 0x6B5C, 0x39D0, 0x5AD6, 0x318E)

# name, anix, aniy, rows.  '.' is index 0 (transparent), digits are palette
# entries.  Geometry and anipoints are MK3's own, unchanged.
FRAMES = [
    ("DROP1", -1, 16, """
        .....3
        ......
        ......
        ....3.
        ...66.
        ...6..
        ...3..
        ..66..
        ..6...
        ..3...
        .44...
        .3....
        .3....
        33....
        3.....
        3.....
    """),
    ("DROP2", -1, 17, """
        .....7
        ......
        ....7.
        ....7.
        ...77.
        ...7..
        ...7..
        ..77..
        ..1...
        ..6...
        .66...
        .6....
        .3....
        33....
        3.....
        3.....
    """),
    ("DROP3", -1, 16, """
        .....7
        ......
        ....7.
        ....7.
        ...77.
        ...7..
        ...7..
        ..77..
        ..1...
        ..1...
        .11...
        .1....
        .1....
        11....
        1.....
        1.....
    """),
    ("DROP4", -1, 16, """
        .....2
        ......
        ....2.
        ....2.
        ...22.
        ...2..
        ...2..
        ..22..
        ..2...
        ..5...
        .55...
        .5....
        .5....
        55....
        5.....
        5.....
    """),
    ("DROPHIT1", 5, 11, """
        ..1.........
        ............
        ............
        ...4........
        ...1........
        ...1......4.
        ...24.3..1..
        ....1.3.1...
        4...1331...1
        ..4.131..1..
        ..2113112...
        ....112.....
    """),
    ("DROPHIT2", 6, 13, """
        ....3...........
        ....1...........
        ................
        ................
        ................
        ......3........3
        ......1.........
        ......1......4..
        3...........1...
        .1.........1...3
        ...4......1...3.
        ............1...
        ...........2....
    """),
]


def parse_frame(art: str) -> tuple[int, int, list[int]]:
    rows = [ln.strip() for ln in art.strip("\n").splitlines()]
    rows = [r for r in rows if r]
    w = len(rows[0])
    for i, r in enumerate(rows):
        if len(r) != w:
            raise ValueError(f"row {i} is {len(r)} wide, expected {w}")
    px = []
    for r in rows:
        for ch in r:
            v = 0 if ch == "." else int(ch)
            if not 0 <= v < len(DROPS):
                raise ValueError(f"pixel {ch!r} is outside the {len(DROPS)}-entry palette")
            px.append(v)
    return w, len(rows), px


def build() -> bytes:
    frames = [(name, ax, ay) + parse_frame(art) for name, ax, ay, art in FRAMES]

    out = bytearray(LIB_HDR.size)

    # Palette pixel data, then image pixel data - the order SaveImgFile writes.
    pal_data_oset = len(out)
    for c in DROPS:
        out += struct.pack("<H", c)

    img_data_osets = []
    for _name, _ax, _ay, w, h, px in frames:
        img_data_osets.append(len(out))
        stride = (w + 3) & ~3          # 8bpp on disk; LOAD2 packs it to PPP> 3
        for y in range(h):
            row = px[y * w:(y + 1) * w]
            out += bytes(row) + bytes(stride - w)

    oset = len(out)

    for (name, ax, ay, w, h, _px), data_oset in zip(frames, img_data_osets):
        out += IMAGE.pack(
            name.encode("ascii"),
            0,                          # flags - 0x10 is DOWN, a runtime bit
            ax & 0xFFFF, ay & 0xFFFF,
            w, h,
            0 + NUMDEFPAL,              # palnum is 3-based on disk
            data_oset,
            0,                          # data - unused in file
            0,                          # lib
            0, 0, 0xFFFF,               # anix2/aniy2/aniz2, as CASTLE.IMG writes them
            0,                          # frm
            0xFFFF,                     # opals - no alternate palette table
            0xFFFF,                     # pttblnum - no point table
        )

    out += PALETTE.pack(
        PAL_NAME.encode("ascii"),
        0,                              # flags
        PAL_BITSPIX,
        len(DROPS),
        pal_data_oset,
        0, 0, 0, 0, 0,                  # data, lib, colind, cmap, spare
    )

    LIB_HDR.pack_into(
        out, 0,
        len(frames),
        len([DROPS]) + NUMDEFPAL,
        oset,
        IMG_VERSION,
        0, 0, 0,                        # seqcnt, scrcnt, damcnt
        0xABCD,
        b"\0\0\0\0",                    # bufscr
        0, 0, 0,                        # spare1/2/3
    )
    return bytes(out)


def dump() -> None:
    glyph = " .:-=+*#"
    for name, ax, ay, art in FRAMES:
        w, h, px = parse_frame(art)
        span = sum(1 for p in px if p)
        print(f"--- {name} {w}x{h} anipoint({ax},{ay})  "
              f"{span}/{w*h} lit  {w*h*PAL_BITSPIX//8} bytes packed")
        for y in range(h):
            print("   |" + "".join(glyph[p] for p in px[y * w:(y + 1) * w]) + "|")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if data/RAIN.IMG differs from this source")
    ap.add_argument("--dump", action="store_true", help="print the frames and exit")
    args = ap.parse_args()

    if args.dump:
        dump()
        return 0

    data = build()

    if args.check:
        if not IMG_PATH.exists():
            print(f"FAIL: {IMG_PATH} is missing - run tools/make_rain_img.py")
            return 1
        on_disk = IMG_PATH.read_bytes()
        if on_disk != data:
            print(f"FAIL: {IMG_PATH} does not match tools/make_rain_img.py "
                  f"({len(on_disk)} bytes on disk, {len(data)} generated)")
            return 1
        print(f"OK: {IMG_PATH.name} matches its generator ({len(data)} bytes)")
        return 0

    IMG_PATH.write_bytes(data)
    total = sum(len(parse_frame(a)[2]) for _, _, _, a in FRAMES)
    print(f"wrote {IMG_PATH} - {len(FRAMES)} frames, {len(DROPS)}-entry {PAL_NAME}, "
          f"{len(data)} bytes ({total * PAL_BITSPIX // 8} bytes once LOAD2 packs it)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
