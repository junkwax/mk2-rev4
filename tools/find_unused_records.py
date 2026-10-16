#!/usr/bin/env python3
"""
Find IMG records (by file + index) that no .LOD claims for export.

This complements find_unused_sprites.py: where that tool reads IMG-internal
names, this one walks the .LOD files to figure out which RECORDS each LOD
exports under what name. Records the LODs ignore are candidates for
scrapped content.

A LOD section looks like:

    KANG1.IMG
    PON>
    ---> LKSTANCE1A
    POF>
    ---> LKSTANCE1B,LKSTANCE1C,LKSTANCE2A,LKSTANCE2B,LKSTANCE2C
    ---> LKSTANCE3A,...

LOAD2 reads the IMG's records sequentially, pulling one name per record
from the `--->` lists. PON>/POF> toggle palette emission. We replicate
that walk to map (img_file, record_index) -> exported_name.

For each IMG file we then look at total records (from imgdump) vs.
exported-record count. The gap is the unused candidate set.

Usage:
    python tools/find_unused_records.py              # summary by IMG
    python tools/find_unused_records.py --verbose    # per-IMG ranges
    python tools/find_unused_records.py --md         # Markdown report
"""
import argparse
import re
import struct
import sys
from collections import defaultdict
from pathlib import Path


LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")


def count_img_records(path: Path) -> int:
    """Return imgcnt (number of IMAGE records) from the IMG header."""
    try:
        data = path.read_bytes()[:LIB_HDR.size]
    except OSError:
        return 0
    if len(data) < LIB_HDR.size:
        return 0
    try:
        imgcnt = LIB_HDR.unpack(data)[0]
    except struct.error:
        return 0
    return imgcnt


# LOD-line patterns
IMG_LINE_RE = re.compile(r"^\s*([A-Za-z0-9_]+\.IMG)\s*$")
EXPORT_LINE_RE = re.compile(r"^\s*--->\s*(.+?)\s*$")
DIRECTIVE_RE = re.compile(r"^\s*([A-Z]+)>\s*")


def parse_lod(path: Path):
    """Walk a single .LOD file and yield (img_filename, exported_name_list)
    pairs as encountered.

    LOAD2 maintains a per-LOD record index per IMG. Multiple `--->` lines
    accumulate names that consume successive records of the most-recently-
    named IMG. New `IMG_NAME.IMG` lines reset the index. Directives like
    `PON>`/`POF>`/`ZON>` are control toggles and don't consume records.

    Returns a list of (img_filename, ordered_export_names) groupings; if
    an IMG appears more than once in a LOD, each occurrence is a separate
    grouping (LOAD2 starts the index from 0 again, AFAICT — but if you
    see the same IMG twice, double-check by hand).
    """
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return []
    groupings = []
    current_img = None
    current_names = []
    for raw in text.splitlines():
        # Strip comments (start with ; in LOD syntax)
        line = raw.split(";", 1)[0].rstrip()
        if not line.strip():
            continue
        m = IMG_LINE_RE.match(line)
        if m:
            if current_img is not None:
                groupings.append((current_img, current_names))
            current_img = m.group(1)
            current_names = []
            continue
        m = EXPORT_LINE_RE.match(line)
        if m:
            payload = m.group(1)
            names = [n.strip() for n in payload.split(",") if n.strip()]
            if current_img is not None:
                current_names.extend(names)
            continue
        # Other directives (PON>, POF>, BBB>, ASM>, ***>, ZON>, etc.) don't
        # consume IMG records, but BBB> uses a different system (BLIMP
        # backgrounds, not IMG sprites) so they fall through harmlessly.
    if current_img is not None:
        groupings.append((current_img, current_names))
    return groupings


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--verbose", action="store_true",
                        help="show every IMG's used/unused record indices")
    parser.add_argument("--md", action="store_true",
                        help="emit Markdown report")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    data_dir = repo / "data"

    # Walk every LOD, accumulate (img, ordered_exports).
    img_uses = defaultdict(list)  # filename -> list of (lod_name, [names])
    for lod in sorted(data_dir.glob("*.LOD")):
        for img, names in parse_lod(lod):
            if names:  # ignore IMGs that appear but export nothing
                img_uses[img].append((lod.name, names))

    # For each IMG, compute total records and which indices are used.
    rows = []  # (img, total, used_count, unused_count, used_names_sample)
    detail = {}  # img -> list of (idx, name_or_None)
    for img_name in sorted(set(list(img_uses)) | {p.name for p in data_dir.glob("*.IMG")}):
        path = data_dir / img_name
        if not path.exists():
            continue
        total = count_img_records(path)
        all_names_in_order = []
        for lod_name, names in img_uses.get(img_name, []):
            all_names_in_order.extend(names)
        used = len(all_names_in_order)
        unused = max(0, total - used)
        rows.append((img_name, total, used, unused, all_names_in_order))
        detail[img_name] = all_names_in_order

    if args.md:
        print("# IMG record usage report\n")
        print("Total record count vs how many records each LOD claims via `--->` exports. "
              "Records beyond the exported count are unused — candidates for scrapped "
              "content (or LOD padding that LOAD2 skips).\n")
        print("| IMG | Total | Exported | Unused | Coverage |")
        print("|---|---:|---:|---:|---:|")
        for img, total, used, unused, _ in sorted(rows, key=lambda r: -r[3]):
            if total == 0:
                continue
            pct = 100.0 * used / total
            print(f"| `{img}` | {total} | {used} | {unused} | {pct:.0f}% |")
        return 0

    if args.verbose:
        for img, total, used, unused, names in rows:
            if total == 0:
                continue
            print(f"=== {img}  total={total}, exported={used}, unused={unused} ===")
            if unused > 0 and unused < 60:
                # Show the index range that's unused
                print(f"  unused indices: {used}..{total - 1}")
            elif unused > 0:
                print(f"  unused indices: {used}..{total - 1} ({unused} records)")
            if names and len(names) <= 12:
                print(f"  exported: {', '.join(names)}")
            elif names:
                print(f"  first exports: {', '.join(names[:6])} ...")
            print()
        return 0

    # Default: terse summary
    total_records = sum(r[1] for r in rows)
    total_used = sum(r[2] for r in rows)
    total_unused = sum(r[3] for r in rows)
    print(f"Total IMG records across {len(rows)} files: {total_records:,d}")
    print(f"Exported by some LOD:                       {total_used:,d}")
    print(f"Unused (record index >= exported count):    {total_unused:,d}")
    print()
    print("Top 20 IMGs by unused-record count:")
    print(f"  {'IMG':<24} {'Total':>6} {'Used':>6} {'Unused':>6}  Coverage")
    for img, total, used, unused, _ in sorted(rows, key=lambda r: -r[3])[:20]:
        if total == 0:
            continue
        pct = 100.0 * used / total
        print(f"  {img:<24} {total:>6} {used:>6} {unused:>6}  {pct:5.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
