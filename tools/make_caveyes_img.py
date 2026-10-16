#!/usr/bin/env python3
r"""Build data/CAVEYES.IMG - the glowing eyes in GORO'S LAIR's dark passages.

MK2 does not have these.  MK1 does: `mk1_mod`'s stage `calla` slot, which MK2
leaves as a bare `.long return` (src/BGND.ASM), points at a real routine in
MK1's program ROM, and that routine is the eyes.  Everything below was read
back out of `C:\MAME\roms\mk.zip` (the T-unit MK1 set, same interleave and
same 0x02000000 SAG base as MK2), not remembered:

    FFCB75E0  the stage calla - creates pid 2025h at FFCB7670
    FFCB7BB0  six eye positions, .word x,y, 0-terminated
    FFCB7D00  a 28-entry blink script, one `prcslp 8` per entry
    randu(1Ch) gives each pair its own start phase, so they do not blink
              in unison
    FFEAA470  the palette: four entries, black plus three olive-yellows

The ART is six frames, each ONE PIXEL TALL - a horizontal sliver with a
transparent gap in the middle, which is what makes it read as a PAIR of eyes
rather than one dot.  They differ in WIDTH (3, 5, 8, 10, 10, 10) and in which
of the three yellows they use, so opening/closing is a width animation and the
"glow" is a brightness animation on top of it.  MK1's anipoints are
ceil(W/2),0 - the sliver grows and shrinks around its own centre, which is why
a blink does not walk sideways.  Those anipoints are kept verbatim.

The MK1 SAG deltas confirm the decode: 18, 30, 48, 60, 60 bits for 3x1, 5x1,
8x1, 10x1, 10x1 at 6bpp, exact with no padding.  We repack at PPP> 2 because
the palette really is four entries - MK1 spent six bits only because its whole
dungeon LOD was 6bpp.

Usage:
    python tools/make_caveyes_img.py            # write data/CAVEYES.IMG
    python tools/make_caveyes_img.py --check    # fail if the file has drifted
    python tools/make_caveyes_img.py --dump     # print the frames as art
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IMG_PATH = REPO / "data" / "CAVEYES.IMG"

LIB_HDR = struct.Struct("<HHIHHHHH4sHHH")
IMAGE = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")
assert (LIB_HDR.size, IMAGE.size, PALETTE.size) == (28, 50, 26)

NUMDEFPAL = 3           # palcnt on disk counts three palettes that are not in the file
IMG_VERSION = 0x062E    # what CASTLE.IMG / ACID1.IMG / RAIN.IMG carry
PAL_NAME = "CAVEYE_P"
PAL_BITSPIX = 2

# MK1's own palette, word for word, from FFEAA470 in the T-unit MK1 program
# ROM.  5R5G5B, entry 0 transparent.  Dull olive-yellows, not gold - they read
# as "glowing" only because everything around them in the archway is pure
# black, and a brighter ramp turns them into lamps.
CAVEYE_P = (0x0000, 0x39A0, 0x2920, 0x1CC0)

# name, anix, aniy, rows.  '.' is index 0 (transparent - the gap BETWEEN the
# two eyes), digits are palette entries.  1 is the brightest of the three.
FRAMES = [
    ("CAVEYE1", 2, 0, """
        2.1
    """),
    ("CAVEYE2", 3, 0, """
        13.12
    """),
    ("CAVEYE3", 4, 0, """
        312..122
    """),
    ("CAVEYE4", 5, 0, """
        3212..2123
    """),
    ("CAVEYE5", 5, 0, """
        3323..3233
    """),
    ("CAVEYE6", 5, 0, """
        3333..3333
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
            if not 0 <= v < len(CAVEYE_P):
                raise ValueError(f"pixel {ch!r} is outside the {len(CAVEYE_P)}-entry palette")
            px.append(v)
    return w, len(rows), px


def build() -> bytes:
    frames = [(name, ax, ay) + parse_frame(art) for name, ax, ay, art in FRAMES]

    out = bytearray(LIB_HDR.size)

    # Palette pixel data, then image pixel data - the order SaveImgFile writes.
    pal_data_oset = len(out)
    for c in CAVEYE_P:
        out += struct.pack("<H", c)

    img_data_osets = []
    for _name, _ax, _ay, w, h, px in frames:
        img_data_osets.append(len(out))
        stride = (w + 3) & ~3          # 8bpp on disk; LOAD2 packs it to PPP> 2
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
        len(CAVEYE_P),
        pal_data_oset,
        0, 0, 0, 0, 0,                  # data, lib, colind, cmap, spare
    )

    LIB_HDR.pack_into(
        out, 0,
        len(frames),
        1 + NUMDEFPAL,
        oset,
        IMG_VERSION,
        0, 0, 0,                        # seqcnt, scrcnt, damcnt
        0xABCD,
        b"\0\0\0\0",                    # bufscr
        0, 0, 0,                        # spare1/2/3
    )
    return bytes(out)


def dump() -> None:
    glyph = " #+."
    for name, ax, ay, art in FRAMES:
        w, h, px = parse_frame(art)
        span = sum(1 for p in px if p)
        print(f"--- {name} {w}x{h} anipoint({ax},{ay})  "
              f"{span}/{w*h} lit  {w*h*PAL_BITSPIX/8:.1f} bytes packed")
        for y in range(h):
            print("   |" + "".join(glyph[p] for p in px[y * w:(y + 1) * w]) + "|")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if data/CAVEYES.IMG differs from this source")
    ap.add_argument("--dump", action="store_true", help="print the frames and exit")
    args = ap.parse_args()

    if args.dump:
        dump()
        return 0

    data = build()

    if args.check:
        if not IMG_PATH.exists():
            print(f"FAIL: {IMG_PATH} is missing - run tools/make_caveyes_img.py")
            return 1
        on_disk = IMG_PATH.read_bytes()
        if on_disk != data:
            print(f"FAIL: {IMG_PATH} does not match tools/make_caveyes_img.py "
                  f"({len(on_disk)} bytes on disk, {len(data)} generated)")
            return 1
        print(f"OK: {IMG_PATH.name} matches its generator ({len(data)} bytes)")
        return 0

    IMG_PATH.write_bytes(data)
    total = sum(len(parse_frame(a)[2]) for _, _, _, a in FRAMES)
    print(f"wrote {IMG_PATH} - {len(FRAMES)} frames, {len(CAVEYE_P)}-entry {PAL_NAME}, "
          f"{len(data)} bytes ({total * PAL_BITSPIX / 8:.1f} bytes once LOAD2 packs it)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
