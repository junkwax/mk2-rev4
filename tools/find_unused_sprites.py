#!/usr/bin/env python3
"""
Inventory NAMED sprites in data/*.IMG and report which ones are not
referenced anywhere in src/ or data/*.LOD.

KNOWN LIMIT: Most MK2 character IMGs (KANG*, CAGE*, ALLENDS, etc.) store
empty 16-byte name fields. LOAD2 packs these by record INDEX with the
name coming from the LOD's `--->` list. This tool only sees the small
subset of IMGs where internal names are populated (NINJAS*, BOSS*,
parts of CHUNKS/FX). For a full "unused sprite" audit, the IMG record
indices need to be cross-referenced against each LOD's `--->` ordering
— see TODO at bottom of this file. This tool is still useful for:

- Spotting unused sprites in NAMED IMGs (NINJAS10 / ACID / etc.)
- Finding orphan content like BIGGORO oro*, MKSOUL etc.
- Identifying which IMG sources are LOAD2-renamed vs self-naming

Unreferenced sprites are candidates for scrapped/cut content that can
be re-added to the build.

Usage:
    python tools/find_unused_sprites.py             # group by character/family
    python tools/find_unused_sprites.py --per-img   # group by IMG file
    python tools/find_unused_sprites.py --csv       # CSV output
    python tools/find_unused_sprites.py --md        # Markdown table
"""
import argparse
import re
import struct
import sys
from pathlib import Path


LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")


def cstr(b: bytes) -> str:
    return b.split(b"\0", 1)[0].decode("latin-1", errors="replace")


def _s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def is_real_name(s: str) -> bool:
    """A real sprite name: at least 3 chars, starts with a letter, all
    chars alphanumeric or underscore. Padding/empty records show up as
    single digits or zero-width strings and are filtered out."""
    if len(s) < 3:
        return False
    if not (s[0].isalpha() or s[0] == "_"):
        return False
    for c in s:
        if not (c.isalnum() or c in "_-"):
            return False
    return True


def extract_img_sprites(path: Path):
    """Yield (idx, name, w, h, anix, aniy) for every named entry in the
    IMG. Skips entries with empty/junk names."""
    try:
        data = path.read_bytes()
    except OSError:
        return
    if len(data) < LIB_HDR.size:
        return
    try:
        (imgcnt, palcnt, oset, version, seqcnt, scrcnt, damcnt, temp,
         bufscr, sp1, sp2, sp3) = LIB_HDR.unpack_from(data, 0)
    except struct.error:
        return
    pal_start = oset
    img_start = pal_start + palcnt * PALETTE.size

    for i in range(imgcnt):
        off = img_start + i * IMAGE.size
        if off + IMAGE.size > len(data):
            return
        try:
            (n_s, flags, anix, aniy, w, h, palnum,
             o, d, lib, ax2, ay2, az2, frm, ptbl,
             opals) = IMAGE.unpack_from(data, off)
        except struct.error:
            continue
        name = cstr(n_s).strip()
        if is_real_name(name):
            yield i, name, w, h, _s16(anix), _s16(aniy)


def collect_referenced_labels(repo: Path):
    """Scan src/*.ASM, src/*.TBL, data/*.LOD for identifier tokens."""
    referenced = set()
    ident = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]+\b")
    for d, exts in [
        (repo / "src", (".ASM", ".TBL", ".GLO", ".H", ".HDR", ".EQU")),
        (repo / "data", (".LOD",)),
    ]:
        if not d.exists():
            continue
        for f in d.iterdir():
            if not f.is_file():
                continue
            if not any(f.name.upper().endswith(e) for e in exts):
                continue
            try:
                text = f.read_text(errors="replace")
            except OSError:
                continue
            for m in ident.finditer(text):
                referenced.add(m.group(0))
    return referenced


def family_prefix(name: str) -> str:
    """Heuristic family prefix for grouping (NJSTANCE1A -> NJ, JCKICK -> JC,
    RNFLY3B -> RN, etc.). Falls back to first 2 chars."""
    m = re.match(r"^([A-Z][A-Z]+?)(?=\d|[A-Z]?\d|$)", name)
    if m:
        # Take a 2-4 char alpha prefix
        prefix = m.group(1)
        return prefix[:4] if len(prefix) > 4 else prefix
    return name[:2].upper()


def chunk_parent(name: str) -> str | None:
    """If name looks like a chunk part (FOO1A, FOO1B, FOO12C), return the
    parent frame name (FOO1, FOO12). Otherwise return None.

    Convention: chunk parts end in a single uppercase letter (A-Z) after
    a digit. Skip if the suffix letter is part of a longer word (e.g.,
    'ARENA' shouldn't strip to 'AREN')."""
    m = re.match(r"^(.+?\d+)([A-E])$", name)
    if m:
        return m.group(1)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--per-img", action="store_true",
                        help="group unused names by source IMG file")
    parser.add_argument("--csv", action="store_true",
                        help="emit CSV (img,idx,name,w,h,anix,aniy) lines")
    parser.add_argument("--md", action="store_true",
                        help="emit Markdown grouped by character family")
    parser.add_argument("--include-orphan-chunks", action="store_true",
                        help="include chunks (FOO1A) whose parent (FOO1) "
                             "IS referenced; default hides those")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    data_dir = repo / "data"

    referenced = collect_referenced_labels(repo)
    print(f"# Referenced identifiers in src/ + data/*.LOD: "
          f"{len(referenced):,d}", file=sys.stderr)

    img_files = sorted(data_dir.glob("*.IMG"))
    unused = []  # (img_name, idx, name, w, h, anix, aniy)
    total_named = 0

    for img in img_files:
        for idx, name, w, h, ax, ay in extract_img_sprites(img):
            total_named += 1
            if name in referenced:
                continue
            if not args.include_orphan_chunks:
                parent = chunk_parent(name)
                if parent and parent in referenced:
                    # Chunk of a referenced frame — the parent is wired
                    # up via the multipart record. Not actually unused.
                    continue
            unused.append((img.name, idx, name, w, h, ax, ay))

    print(f"# Total named sprites scanned: {total_named:,d}", file=sys.stderr)
    print(f"# Total unreferenced:          {len(unused):,d}", file=sys.stderr)
    print(file=sys.stderr)

    if args.csv:
        print("img,idx,name,w,h,anix,aniy")
        for row in unused:
            print(",".join(str(x) for x in row))
        return 0

    if args.md:
        from collections import defaultdict
        by_family = defaultdict(list)
        for img_name, idx, name, w, h, ax, ay in unused:
            key = family_prefix(name)
            by_family[key].append((img_name, idx, name, w, h, ax, ay))
        print("# Unused MK2 sprites — candidates for re-addition\n")
        for fam in sorted(by_family):
            entries = sorted(by_family[fam], key=lambda r: (r[0], r[2]))
            print(f"## {fam} — {len(entries)} sprite{'s' if len(entries)!=1 else ''}\n")
            print("| Name | IMG | Size | Anchor |")
            print("|---|---|---:|---:|")
            for img_name, idx, name, w, h, ax, ay in entries:
                print(f"| `{name}` | {img_name} | {w}×{h} | {ax},{ay} |")
            print()
        return 0

    if args.per_img:
        from collections import defaultdict
        by_img = defaultdict(list)
        for img_name, idx, name, w, h, ax, ay in unused:
            by_img[img_name].append((idx, name, w, h, ax, ay))
        for img_name in sorted(by_img):
            entries = by_img[img_name]
            print(f"=== {img_name} ({len(entries)} unused) ===")
            for idx, name, w, h, ax, ay in entries:
                print(f"  #{idx:>3}  {name:<24}  {w:>3}x{h:<3}  @{ax:>4},{ay:<4}")
            print()
    else:
        from collections import defaultdict
        by_family = defaultdict(list)
        for img_name, idx, name, w, h, ax, ay in unused:
            key = family_prefix(name)
            by_family[key].append((img_name, name, w, h))
        for fam in sorted(by_family):
            entries = sorted(by_family[fam], key=lambda r: (r[0], r[1]))
            print(f"{fam}: {len(entries)} unused")
            for img_name, name, w, h in entries[:8]:
                print(f"  {name:<24}  {w:>3}x{h:<3}  [{img_name}]")
            if len(entries) > 8:
                print(f"  ... and {len(entries) - 8} more")
            print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
