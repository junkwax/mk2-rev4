#!/usr/bin/env python3
"""Keep src/MKSK.TBL's Shao Kahn records aligned with MK5MIL.IRW packing.

Two LODs emit a table called MKSK.TBL:

  * data/MK5MIL.LOD  - every Kahn record (BOSS1..BOSS7.IMG): stance, slam,
                       sonic-clap body, portal punch, talk, taunt, laugh,
                       nupower glow, hit/knockdown/getup, turn-to-stone.
  * data/SCLAP.LOD   - the eleven SONICLAP* wave frames only, duplicated into
                       a fixed bank-1 sidecar at 0x05F88000.

SCLAP runs LAST in IMGBUILD.BAT, so it overwrites C:\\TMP\\LOAD2\\MKSK.TBL and
the MK5MIL version survives only as LOAD2's `.~BL` backup.  tools/promote_tbls.py
therefore only ever sees the eleven SONICLAP records; every other Kahn record
falls into its "label in src/ but not regen -> preserve" rule and is never
refreshed.  Any MK5MIL.LOD/BOSS*.IMG change silently strands them.

That is exactly what happened when BGBIGFIST1C/1D were added to MK5MIL.LOD:
BOSS4's own records were updated, but everything from BOSS5.IMG onward
(BGTALK/BGTAWNT/BGLAFF/BGNUPOWER/BGHIT/BGKNOCKDOWN/BGGETUP/BGSTONECRACK/...)
kept pointing 27034 bits too early - the two new frames' combined size.

IMGBUILD.BAT now snapshots the MK5MIL table to C:\\TMP\\LOAD2\\MKSK.MK5 right
after the MK5MIL run (same trick as BGNDTBL.MK7).  This script patches
src/MKSK.TBL's SAG and control words from that snapshot.  SONICLAP* is skipped
on purpose - those eleven records belong to the SCLAP sidecar and are owned by
promote_tbls.py.

The snapshot deliberately does NOT use a .TBL extension so neither
promote_tbls.py nor sync_load2_tables.py picks it up and fights over the
SONICLAP labels.

Only SAG + control words are rewritten, matching promote_tbls.py's policy.
Size/anipoint words are reported but left alone (hand-tuned anchors live
there - see doc "Blood anipoint drift").
"""
import argparse
import re
import sys
from pathlib import Path

LABEL_RE = re.compile(r"^([A-Za-z_][\w]*):\s*$")
SAG_RE = re.compile(r"^(\s*\.long\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")
CTRL_RE = re.compile(r"^(\s*\.word\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")
SIZE_RE = re.compile(r"^\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)\s*(?:;.*)?$")

# Owned by data/SCLAP.LOD's sidecar copy, promoted by tools/promote_tbls.py.
SKIP_PREFIXES = ("SONICLAP",)


def parse_records(lines):
    """label -> dict(sag=(idx,val), ctrl=(idx,val), size=(idx,tuple))."""
    records = {}
    label = None
    cur = None
    for i, raw in enumerate(lines):
        line = raw.rstrip("\r\n")
        m = LABEL_RE.match(line)
        if m:
            label = m.group(1)
            cur = records.setdefault(label, {})
            continue
        if label is None:
            continue
        m = SIZE_RE.match(line)
        if m and "size" not in cur:
            cur["size"] = (i, tuple(int(g) for g in m.groups()))
            continue
        m = SAG_RE.match(line)
        if m and "sag" not in cur:
            cur["sag"] = (i, int(m.group(2), 16))
            continue
        m = CTRL_RE.match(line)
        if m and "sag" in cur and "ctrl" not in cur:
            cur["ctrl"] = (i, int(m.group(2), 16))
    return records


def rewrite(line, regex, value):
    m = regex.match(line.rstrip("\r\n"))
    prefix, old, suffix, trailing = m.groups()
    newline = "\r\n" if line.endswith("\r\n") else ("\n" if line.endswith("\n") else "")
    # Keep LOAD2's leading-zero width (e.g. 036beaf2H, 06580H).
    width = len(old)
    return f"{prefix}{value:0{width}x}{suffix}{trailing}{newline}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if src/MKSK.TBL is stale, change nothing")
    parser.add_argument("--verbose", action="store_true",
                        help="list every record that differs")
    parser.add_argument("--snapshot", type=Path, default=None,
                        help="override the MK5MIL snapshot path")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    src_path = repo / "src" / "MKSK.TBL"
    snap_path = args.snapshot or (repo / "tmp" / "load2" / "MKSK.MK5")

    if not snap_path.exists():
        # No Phase A run yet (--asm-only on a clean tree). Nothing to compare
        # against; stay quiet rather than failing the build.
        print(f"sync_mksk_mk5: no snapshot at {snap_path} - skipped")
        return 0

    src_lines = src_path.read_text(encoding="latin-1").splitlines(keepends=True)
    snap_lines = snap_path.read_text(encoding="latin-1").splitlines(keepends=True)

    src_recs = parse_records(src_lines)
    snap_recs = parse_records(snap_lines)

    sag_fixes, ctrl_fixes, size_warn, missing = [], [], [], []

    for label, snap in snap_recs.items():
        if label.startswith(SKIP_PREFIXES):
            continue
        src = src_recs.get(label)
        if src is None:
            missing.append(label)
            continue
        if "sag" in snap and "sag" in src and snap["sag"][1] != src["sag"][1]:
            sag_fixes.append((label, src["sag"][0], src["sag"][1], snap["sag"][1]))
        if "ctrl" in snap and "ctrl" in src and snap["ctrl"][1] != src["ctrl"][1]:
            ctrl_fixes.append((label, src["ctrl"][0], src["ctrl"][1], snap["ctrl"][1]))
        if "size" in snap and "size" in src and snap["size"][1] != src["size"][1]:
            size_warn.append((label, src["size"][1], snap["size"][1]))

    if not sag_fixes and not ctrl_fixes:
        print(f"src/MKSK.TBL aligned with {snap_path.name} "
              f"({len(snap_recs)} MK5MIL records checked)")
    else:
        deltas = sorted({new - old for _, _, old, new in sag_fixes})
        print(f"src/MKSK.TBL stale: {len(sag_fixes)} SAG, {len(ctrl_fixes)} control "
              f"words differ from {snap_path.name}")
        if deltas:
            print("  SAG deltas (bits): " +
                  ", ".join(f"{d:+d}" for d in deltas[:8]) +
                  (" ..." if len(deltas) > 8 else ""))
        if args.verbose:
            for label, _, old, new in sag_fixes:
                print(f"    {label:<16} SAG 0{old:07x}H -> 0{new:07x}H")
            for label, _, old, new in ctrl_fixes:
                print(f"    {label:<16} CTL 0{old:04x}H -> 0{new:04x}H")

    if size_warn:
        print(f"  note: {len(size_warn)} record(s) differ in size/anipoint words "
              f"(left alone - hand-tuned anchors):")
        for label, old, new in size_warn[:10]:
            print(f"    {label:<16} {old} -> {new}")

    if missing and args.verbose:
        print(f"  note: {len(missing)} MK5MIL label(s) absent from src/MKSK.TBL")

    if not sag_fixes and not ctrl_fixes:
        return 0

    if args.check:
        return 1

    for _, idx, _, new in sag_fixes:
        src_lines[idx] = rewrite(src_lines[idx], SAG_RE, new)
    for _, idx, _, new in ctrl_fixes:
        src_lines[idx] = rewrite(src_lines[idx], CTRL_RE, new)

    backup = src_path.with_suffix(".TBL.mk5sync.bak")
    backup.write_text("".join(
        src_path.read_text(encoding="latin-1")), encoding="latin-1")
    src_path.write_text("".join(src_lines), encoding="latin-1")
    print(f"Updated src/MKSK.TBL (backup: {backup.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
