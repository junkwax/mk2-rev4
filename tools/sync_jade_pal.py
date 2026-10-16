#!/usr/bin/env python3
"""Sync Jade's default costume palette from data/KAT1.IMG into src/IMGPAL3.ASM.

JDALTHP_P is a KAT1.IMG palette record that nothing in the build promotes:
promote_tbls.py syncs LOAD2 table fields, not IMGPAL colour words, and LOAD2
itself never emits the record because no image record references it - it is
picked at runtime through character_palettes_1[ft_jade] (MKGUYS.ASM).  So the
64 words in IMGPAL3.ASM are a hand carry, and a hand carry rots the moment the
IMG is repainted in IMGTOOL.  This keeps that carry honest.

    python tools/sync_jade_pal.py           # report drift
    python tools/sync_jade_pal.py --check   # non-zero exit on drift (Phase D)
    python tools/sync_jade_pal.py --apply   # rewrite the .word blocks
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# (exported symbol, IMG file, IMG palette record, owning source file, what selects it)
RECORDS = [
    ("JDALTHP_P", "KAT1.IMG", "JDALTHP_P", "IMGPAL3.ASM",
     "character_palettes_1[ft_jade] - Jade's default costume"),
    # Shang's hidden-fighter morphs (stmorph_hidden, MOVES.ASM) draw the
    # retail STPURPLE / STSCORPION frames under these. No image record names
    # either one, so LOAD2 never emits them; morph_swpal_jade/_ermac load
    # them by symbol. The two retail records they were copied from are
    # policed too: a recolour once landed on SHSCOR_P instead of its copy.
    ("SHJADE_P", "MKMORPH1.IMG", "SHJADE_P", "IMGPAL3.ASM",
     "a_st_2_jade - Shang into Jade"),
    ("SHERMAC_P", "MKMORPH1.IMG", "SHERMAC_P", "IMGPAL3.ASM",
     "a_st_2_ermac - Shang into Ermac"),
    ("SHPURPL_P", "MKMORPH1.IMG", "SHPURPL_P", "IMGPAL3.ASM",
     "STPURPLE1A's palette - Shang into Mileena"),
    ("SHSCOR_P", "MKMORPH1.IMG", "SHSCOR_P", "IMGPAL3.ASM",
     "STSCORPION1A's palette - Shang into Scorpion"),
    # Shang into Rain (stmorph_rain) is the same shape one more time: the
    # STSUBZERO1-3 frames under a palette painted for them, and the retail
    # record they were copied from policed alongside it.
    ("SHRAIN_P", "MKMORPH1.IMG", "SHRAIN_P", "IMGPAL3.ASM",
     "a_st_2_rain - Shang into Rain"),
    ("SHZERO_P", "MKMORPH1.IMG", "SHZERO_P", "IMGPAL3.ASM",
     "STSUBZERO1A's palette - Shang into Sub-Zero"),
]


def img_palettes(name: str) -> dict[str, list[int]]:
    data = (ROOT / "data" / name).read_bytes()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    pal_start = oset + imgcnt * IMAGE.size
    out = {}
    # palcnt over-counts by 3 (see reference-img-format-quirks)
    for i in range(palcnt - 3):
        pname, _f1, _f2, ncol, off = PALETTE.unpack_from(
            data, pal_start + i * PALETTE.size)[:5]
        out[pname.split(b"\x00")[0].decode("latin-1")] = list(
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
    """IMGPAL3.ASM house style: every hex constant carries a leading 0."""
    lines = ["\t.word\t %d\n" % ncol]
    for i in range(0, len(words), 8):
        lines.append("\t.word\t" + ",".join("0%XH" % w for w in words[i:i + 8]) + "\n")
    return "".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    cache: dict[str, dict[str, list[int]]] = {}
    drift = 0
    for sym, imgname, rec, fname, why in RECORDS:
        if imgname not in cache:
            cache[imgname] = img_palettes(imgname)
        pals = cache[imgname]
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
            print(f"!! {rec}: not in {imgname}")
            drift += 1
            continue
        if len(want) != ncol:
            print(f"!! {sym}: src has {ncol} colors, {imgname} record has {len(want)}")
            drift += 1
            continue
        bad = [i for i, (a, b) in enumerate(zip(cur, want)) if a != b]
        if not bad:
            print(f"   {sym:<10} <- {imgname}:{rec:<10} ok  ({why})")
            continue
        drift += 1
        print(f" ~ {sym:<10} <- {imgname}:{rec:<10} {len(bad)} of {ncol} words differ"
              f"  ({why})")
        print(f"     indices: {', '.join(str(i) for i in bad)}")
        for i in bad:
            print(f"       [{i:2}] src 0{cur[i]:04X}H -> img 0{want[i]:04X}H")
        if args.apply:
            text = text[:m.start("body")] + render(ncol, want) + text[m.end("body"):]
            path.write_text(text, errors="surrogateescape")

    if drift and args.check:
        print(f"\nJade palette: {drift} record(s) out of sync with the IMG")
        return 1
    if args.apply:
        print("\napplied - rebuild so the new .word data reaches the ROM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
