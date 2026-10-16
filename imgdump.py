#!/usr/bin/env python3
"""Dump the frame table of a Midway MK2-era IMG file.

Struct layout derived from doc/it/wmpstruc.inc (IMG tool v6.x).

File layout:
    LIB_HDR (28 bytes)
    palette data + image pixel data  (until OSET)
    IMAGE and PALETTE records beginning at OSET

Some libraries write IMAGE records first, then PALETTE records. Others write
the reverse. We autodetect the order by looking for plausible image names.

Usage:
    python imgdump.py data/NINJAS10.IMG
    python imgdump.py data/NINJAS10.IMG --name NJJUMPSPIT
    python imgdump.py data/NINJAS10.IMG --asm   # ASM-style output
"""
import struct
import sys
from pathlib import Path


LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
assert LIB_HDR.size == 28

PALETTE = struct.Struct("<10s BB H I H H B B H")
assert PALETTE.size == 26

IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
assert IMAGE.size == 50


def cstr(b: bytes) -> str:
    return b.split(b"\0", 1)[0].decode("latin-1", errors="replace")


def _s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def _plausible_name(raw: bytes) -> bool:
    name = raw.split(b"\0", 1)[0]
    if not name:
        return False
    return all(32 <= ch < 127 for ch in name)


def detect_record_layout(data: bytes, oset: int, imgcnt: int, palcnt: int) -> tuple[str, int, int]:
    layouts = (
        ("image-first", oset, oset + imgcnt * IMAGE.size),
        ("palette-first", oset + palcnt * PALETTE.size, oset),
    )
    scored: list[tuple[int, str, int, int]] = []
    for name, img_start, pal_start in layouts:
        score = 0
        for i in range(imgcnt):
            off = img_start + i * IMAGE.size
            if off + IMAGE.size > len(data):
                break
            if _plausible_name(data[off:off + 16]):
                score += 1
        scored.append((score, name, img_start, pal_start))
    score, name, img_start, pal_start = max(scored)
    if score == 0:
        raise ValueError("could not locate IMG record table")
    return name, img_start, pal_start


def parse(path: Path, filter_name: str | None = None, asm: bool = False) -> None:
    data = path.read_bytes()

    (imgcnt, palcnt, oset, version, seqcnt, scrcnt, damcnt, temp,
     bufscr, sp1, sp2, sp3) = LIB_HDR.unpack_from(data, 0)

    layout_name, img_start, pal_start = detect_record_layout(data, oset, imgcnt, palcnt)

    if not asm:
        print(f"=== {path.name} ===")
        print(f"  images:   {imgcnt}")
        print(f"  palettes: {palcnt}")
        print(f"  version:  {version:#06x}")
        print(f"  OSET:     {oset:#010x}  ({layout_name})")
        print(f"  PAL tbl:  {pal_start:#x} .. {pal_start + palcnt*PALETTE.size:#x}")
        print(f"  IMG tbl:  {img_start:#x} .. {img_start + imgcnt*IMAGE.size:#x}")
        print()

        print(f"{'idx':>4} {'name':<16} {'W':>4} {'H':>4} {'anix':>5} {'aniy':>5} "
              f"{'pal':>4} {'img.OSET':>12} {'flags':>6}")
        print("-" * 80)

    for i in range(imgcnt):
        off = img_start + i * IMAGE.size
        if off + IMAGE.size > len(data):
            print(f"!! record {i} past EOF ({off:#x})")
            break
        (n_s, flags, anix, aniy, w, h, palnum,
         o, d, lib, ax2, ay2, az2, frm, ptbl, opals) = IMAGE.unpack_from(data, off)

        name = cstr(n_s)

        if filter_name and filter_name.upper() not in name.upper():
            continue

        if asm:
            # MK2 TBL chunks use BIT addresses for ROM position. We dump the
            # file-local byte offset; mapping to a ROM bit address is separate
            # (it lands at LOD-load time). But if we match existing chunks by
            # name, we can compute the delta.
            print(f"{name}:")
            print(f"\t.word   {w},{h},{_s16(anix)},{_s16(aniy)}")
            print(f"\t.long   {o:#010x}H")
            print(f"\t.word   {flags*0+0x6080:#06x}H\t; fallback flags - tune")
        else:
            print(f"{i:>4} {name:<16} {w:>4} {h:>4} "
                  f"{_s16(anix):>5} {_s16(aniy):>5} {palnum:>4} "
                  f"{o:>#12x} {flags:>#6x}")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = Path(sys.argv[1])
    args = set(sys.argv[2:])
    name_filter = None
    if "--name" in args:
        idx = sys.argv.index("--name")
        name_filter = sys.argv[idx + 1]
    asm = "--asm" in args
    parse(path, name_filter, asm=asm)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
