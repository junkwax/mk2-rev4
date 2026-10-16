#!/usr/bin/env python3
"""Sync Baraka's Start+button alternate palettes from data/UGMO1.IMG.

LOAD2 never emits these records - they are selected at runtime by
alt_pal_owner, not referenced by any image record - so they are hand-carried
into src/ the same way UGALT5_P was.  This keeps that carry honest.

    python tools/sync_baraka_alt_pals.py           # report drift
    python tools/sync_baraka_alt_pals.py --check   # non-zero exit on drift
    python tools/sync_baraka_alt_pals.py --apply   # rewrite the .word blocks
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "UGMO1.IMG"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# symbol -> (IMG record, owning source file, what selects it)
RECORDS = [
    ("UGALTBL_P", "UGALTBL_P", "IMGPAL2.ASM", "character_palettes_3 - Start+Block"),
    ("UGALTHP_P", "UGALTHP_P", "IMGPAL2.ASM", "character_palettes_4 - Start+High Punch"),
    ("UGALTHK_P", "UGALTHK_P", "IMGPAL2.ASM", "character_palettes_5 - Start+High Kick"),
    ("UGALTLK_P", "UGALTLK_P", "MKGUYS.ASM", "character_palettes_6 - Start+Low Kick"),
    ("UGALTCN_P", "UGALTCN_P", "IMGPAL2.ASM", "character_palettes_7 - Start+Coin"),
    # Start+Low Punch reuses UGBLUE_P, which is also the P2 mirror-match
    # palette.  UGMO1.IMG's UGALTLP_P is byte-identical to it, so the slot is
    # left pointing at UGBLUE_P rather than duplicating the data.
    ("UGBLUE_P", "UGALTLP_P", "MKGUYS.ASM", "character_palettes_2 - Start+Low Punch / P2 mirror"),
]


def img_palettes() -> dict[str, list[int]]:
    data = IMG.read_bytes()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    pal_start = oset + imgcnt * IMAGE.size
    out = {}
    # palcnt over-counts by 3 (see reference-img-format-quirks)
    for i in range(palcnt - 3):
        name, _f1, _f2, ncol, off = PALETTE.unpack_from(data, pal_start + i * PALETTE.size)[:5]
        out[name.split(b"\x00")[0].decode("latin-1")] = list(
            struct.unpack_from("<%dH" % ncol, data, off))
    return out


BLOCK = r"(?m)^(?P<head>%s:[ \t]*\n)(?P<body>(?:[ \t]*\.word[^\n]*\n)+)"


def parse_block(text: str, sym: str):
    m = re.search(BLOCK % re.escape(sym), text)
    if not m:
        return None
    nums = re.findall(r"(?<![\w.])([0-9][0-9A-Fa-f]*[Hh]|\d+)(?![\w.])", m.group("body"))
    vals = [int(n[:-1], 16) if n[-1] in "Hh" else int(n) for n in nums]
    return m, vals[0], vals[1:]


def render(ncol: int, words: list[int]) -> str:
    lines = ["\t.word\t %d\n" % ncol]
    for i in range(0, len(words), 8):
        lines.append("\t.word\t" + ",".join("%05xh" % w for w in words[i:i + 8]) + "\n")
    return "".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    pals = img_palettes()
    drift = 0
    for sym, rec, fname, why in RECORDS:
        path = ROOT / "src" / fname
        text = path.read_text(errors="surrogateescape")
        parsed = parse_block(text, sym)
        if parsed is None:
            print(f"!! {sym}: no definition in src/{fname}")
            drift += 1
            continue
        m, ncol, cur = parsed
        want = pals.get(rec)
        if want is None:
            print(f"!! {rec}: not in {IMG.name}")
            drift += 1
            continue
        if len(want) != ncol:
            print(f"!! {sym}: src has {ncol} colors, IMG record has {len(want)}")
            drift += 1
            continue
        bad = [i for i, (a, b) in enumerate(zip(cur, want)) if a != b]
        if not bad:
            print(f"   {sym:<10} <- {rec:<10} ok  ({why})")
            continue
        drift += 1
        print(f" ~ {sym:<10} <- {rec:<10} {len(bad)} of {ncol} words differ  ({why})")
        if args.apply:
            text = text[:m.start("body")] + render(ncol, want) + text[m.end("body"):]
            path.write_text(text, errors="surrogateescape")

    if drift and args.check:
        print(f"\nBaraka alt palettes: {drift} record(s) out of sync with {IMG.name}")
        return 1
    if args.apply:
        print("\napplied - rebuild so the new .word data reaches the ROM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
