#!/usr/bin/env python3
"""
sync_bgndtbl_sags.py ? sync ALL SAG values in src/BGNDTBL.ASM from the
LOAD2 snapshot (tmp/load2/BGNDTBL.MK7), matching by label.

promote_bgndtbl_stock_sags.py only handles the first SAG in each labeled
stock-header record.  This script handles every inline SAG inside those stock
records too.  Labels not present in the MK7 snapshot, such as custom
custom/generated tail records, are untouched.

Usage:
  python tools/sync_bgndtbl_sags.py            # apply fixes
  python tools/sync_bgndtbl_sags.py --dry-run  # report only
"""

import re
import sys
from pathlib import Path

LABEL_PAT = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$')
SAG_PAT = re.compile(r'(\.long\s+)(0[4-7][0-9A-Fa-f]{6}H)', re.IGNORECASE)
SRC  = 'src/BGNDTBL.ASM'
SNAP = 'tmp/load2/BGNDTBL.MK7'

dry_run  = '--dry-run' in sys.argv
check    = '--check'   in sys.argv
if check:
    dry_run = True

with open(SRC) as f:
    src_lines = f.readlines()
with open(SNAP) as f:
    snap_lines = f.readlines()


def label_ranges(lines):
    labels = []
    for i, line in enumerate(lines):
        m = LABEL_PAT.match(line)
        if m:
            labels.append((m.group(1), i))
    ranges = {}
    for idx, (label, start) in enumerate(labels):
        end = labels[idx + 1][1] if idx + 1 < len(labels) else len(lines)
        ranges[label] = (start, end)
    return ranges


def sag_values(lines, start, end):
    values = []
    for i in range(start, end):
        m = SAG_PAT.search(lines[i])
        if m:
            values.append(m.group(2))
    return values


updated = 0
new_lines = list(src_lines)
src_ranges = label_ranges(src_lines)
snap_ranges = label_ranges(snap_lines)
matched_labels = 0
src_only = 0

for label, (src_start, src_end) in src_ranges.items():
    snap_range = snap_ranges.get(label)
    if snap_range is None:
        src_only += 1
        continue
    matched_labels += 1
    snap_sags = sag_values(snap_lines, snap_range[0], snap_range[1])
    snap_i = 0
    for i in range(src_start, src_end):
        sm = SAG_PAT.search(src_lines[i])
        if not sm:
            continue
        if snap_i >= len(snap_sags):
            break
        old_sag = sm.group(2)
        new_sag = snap_sags[snap_i]
        snap_i += 1
        if old_sag.upper() != new_sag.upper():
            new_lines[i] = src_lines[i].replace(old_sag, new_sag, 1)
            print(f"{label}:{i+1:5d}: {old_sag} -> {new_sag}")
            updated += 1

print(
    f"\nSAG updates: {updated}  "
    f"(matched stock labels: {matched_labels}, src-only labels preserved: {src_only})"
)

if not dry_run and updated > 0:
    with open(SRC, 'w') as f:
        f.writelines(new_lines)
    print(f"Written: {SRC}")
    for artifact in ("BGND.OBJ", "BGND.LST", "mk2.out"):
        path = Path("src") / artifact
        if path.exists():
            path.unlink()
            print(f"Removed stale assembler artifact: {path}")
elif dry_run and not check:
    print("(dry-run ? no files changed)")

if check and updated > 0:
    print(f"ERROR: {updated} anonymous BGNDTBL SAGs are stale ? run sync_bgndtbl_sags.py")
    sys.exit(1)
