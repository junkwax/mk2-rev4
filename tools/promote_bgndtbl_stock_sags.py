#!/usr/bin/env python3
"""
Sync the stock-background SAGs in src/BGNDTBL.ASM with the current MK7MIL
LOAD2 output captured in tmp/load2/BGNDTBL.MK7.

Background: src/BGNDTBL.ASM has two regions:
  1. STOCK section ? every stage shipped in MK7MIL.LOD (NUPOOL, TOMB,
     TOWER2, BATTLE, FOREST2, ARMORY1, BRIDGE1, SPIRAL, ARENA, MKHUGE,
     MOUNTAIN, MKSELECT, MKWINNER, MKVERSUS, ATRAX1-4, MKSTORY1-3,
     MK1CAVE, MKTEAM, HISCORE1, NUENT1-2, COMESOON, STORY1, etc.). These
     SAGs only change when MK7MIL.LOD's packing order/sizes change.
  2. CUSTOM/generated tail - appended records emitted by active background tooling.

The bddtool flow only refreshes the custom tail. The stock section is
assumed stable. But any edit that shifts MK7MIL.IRW packing (re-enabling
a BBB, adding a new image, etc.) silently invalidates the stock SAGs ?
every label that comes AFTER the change gets the wrong byte address.

The artifact you see is "stage X looks garbled" because src/BGNDTBL.ASM
points the runtime DMA at the wrong byte offset in the new IRW.

This script:
  - Reads tmp/load2/BGNDTBL.MK7 (preserved by IMGBUILD.BAT after MK7MIL).
  - Matches each label there against src/BGNDTBL.ASM.
  - Patches every first-SAG line in src/ to match the MK7 snapshot.
  - Leaves the custom tail (labels not in the MK7 snapshot) untouched.

Run after `python build.py` (which produces the snapshot via IMGBUILD).

Usage:
    python tools/promote_bgndtbl_stock_sags.py            # report
    python tools/promote_bgndtbl_stock_sags.py --apply    # patch
    python tools/promote_bgndtbl_stock_sags.py --check    # exit 1 if drifted
"""
import argparse
import re
import sys
from pathlib import Path


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$")
SAG_LINE_RE = re.compile(r"^(\s*\.long\s+)0([0-9a-fA-F]+)([Hh])(\s*(?:;.*)?)$")
SIDECAR_OWNED_LABELS = {
    "ry1HDRS",
    "ARM3BLKS",
    "ARM2BLKS",
    "ARM1BLKS",
    "ARM3BMOD",
    "ARM2BMOD",
    "ARM1BMOD",
}


def parse_records(path: Path):
    """Walk a TBL/ASM and return (header_lines, records, footer_lines)
    where records is [(label, body_lines), ...]. A body_line is every line
    from the label line up to (but not including) the next label or a
    `.TEXT`/`.END` directive."""
    text = path.read_text(errors="replace")
    raw = text.split("\n")
    header, records, footer = [], [], []
    current_label = None
    current_body = []
    in_footer = False
    for line in raw:
        if in_footer:
            footer.append(line)
            continue
        if re.match(r"^\s*\.(?:TEXT|END)\b", line, re.IGNORECASE):
            if current_label is not None:
                records.append((current_label, current_body))
                current_label, current_body = None, []
            footer.append(line)
            in_footer = True
            continue
        m = LABEL_RE.match(line)
        if m:
            if current_label is not None:
                records.append((current_label, current_body))
            current_label = m.group(1)
            current_body = [line]
        elif current_label is None:
            header.append(line)
        else:
            current_body.append(line)
    if current_label is not None:
        records.append((current_label, current_body))
    return header, records, footer


def first_sag_with_index(body):
    """Find the first `.long XXXXh` line in a record. Returns (line_index,
    sag_int, match_object) or None."""
    for i, line in enumerate(body):
        m = SAG_LINE_RE.match(line)
        if m:
            return i, int(m.group(2), 16), m
    return None


def rewrite_sag(line: str, new_sag: int) -> str:
    m = SAG_LINE_RE.match(line)
    if not m:
        return line
    prefix, _, suffix_h, trailing = m.group(1, 2, 3, 4)
    return f"{prefix}0{new_sag:x}{suffix_h}{trailing}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true",
                        help="patch src/BGNDTBL.ASM (default is report only)")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if stock SAGs are drifted; no patch")
    parser.add_argument("--verbose", action="store_true",
                        help="list every drifted label, not just a summary")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    src_tbl = repo / "src" / "BGNDTBL.ASM"
    mk7_snap = repo / "tmp" / "load2" / "BGNDTBL.MK7"

    if not src_tbl.exists():
        print(f"error: {src_tbl} not found", file=sys.stderr)
        return 2
    if not mk7_snap.exists():
        print(f"error: {mk7_snap} not found ? run `python build.py` first "
              f"so IMGBUILD.BAT can copy the MK7MIL TBL before the REVX "
              f"and later custom LODs overwrite it.", file=sys.stderr)
        return 2

    src_header, src_records, src_footer = parse_records(src_tbl)
    _, mk7_records, _ = parse_records(mk7_snap)

    mk7_first_sag = {}
    for lbl, body in mk7_records:
        info = first_sag_with_index(body)
        if info is not None:
            mk7_first_sag[lbl] = info[1]

    drifted = []  # (label, src_sag, mk7_sag)
    aligned = 0
    src_only = 0
    new_records = []
    for lbl, body in src_records:
        if lbl in SIDECAR_OWNED_LABELS:
            src_only += 1
            new_records.append((lbl, body))
            continue
        if lbl in mk7_first_sag:
            info = first_sag_with_index(body)
            if info is None:
                # Label exists in both but src has no SAG (alias-only).
                # Nothing to patch.
                new_records.append((lbl, body))
                continue
            line_idx, src_sag, _ = info
            mk7_sag = mk7_first_sag[lbl]
            if src_sag == mk7_sag:
                aligned += 1
                new_records.append((lbl, body))
            else:
                drifted.append((lbl, src_sag, mk7_sag))
                new_body = list(body)
                new_body[line_idx] = rewrite_sag(body[line_idx], mk7_sag)
                new_records.append((lbl, new_body))
        else:
            src_only += 1
            new_records.append((lbl, body))

    print(f"Stock labels aligned with MK7 snapshot: {aligned}")
    print(f"Stock labels drifted:                   {len(drifted)}")
    print(f"src-only labels (custom tail preserved): {src_only}")

    if args.verbose and drifted:
        print()
        print(f"{'label':<24} {'src SAG':>12}  {'mk7 SAG':>12}  delta(bits)")
        for lbl, ssag, msag in drifted[:50]:
            print(f"  {lbl:<22} 0x{ssag:08x}  0x{msag:08x}  {ssag - msag:+,d}")
        if len(drifted) > 50:
            print(f"  ... and {len(drifted) - 50} more")

    if args.check:
        return 1 if drifted else 0

    if not args.apply:
        if drifted:
            print()
            print("Run with --apply to patch src/BGNDTBL.ASM. The custom "
                  "custom/generated tail is preserved.")
        return 0

    if not drifted:
        print("No drift ? nothing to patch.")
        return 0

    # Reassemble src/BGNDTBL.ASM with patched bodies.
    out_lines = list(src_header)
    for _, body in new_records:
        out_lines.extend(body)
    out_lines.extend(src_footer)

    old_text = src_tbl.read_text(errors="replace")
    keep_trailing_nl = old_text.endswith("\n")
    new_text = "\n".join(out_lines)
    if keep_trailing_nl and not new_text.endswith("\n"):
        new_text += "\n"

    # Drop src/BGND.OBJ + src/mk2.out so gmake reassembles. Without this,
    # gmake sees BGND.ASM unchanged and keeps stale objects (the
    # postmortem's "stale assembler artifacts" trap).
    src_tbl.write_text(new_text)
    for kill in ("BGND.OBJ", "BGND.LST", "mk2.out"):
        p = repo / "src" / kill
        if p.exists():
            p.unlink()

    print(f"patched {len(drifted)} SAGs in {src_tbl}")
    print(f"removed src/BGND.OBJ, src/BGND.LST, src/mk2.out ? rerun build.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
