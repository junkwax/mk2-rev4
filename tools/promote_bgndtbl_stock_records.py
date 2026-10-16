#!/usr/bin/env python3
"""
Promote stock background table records from the current MK7MIL LOAD2 output.

`python build.py` rebuilds `data/MK7MIL.IRW` from the live BDB/BDD files and
captures the generated table at `tmp/load2/BGNDTBL.MK7`. The old sync tools
only copied SAG addresses into `src/BGNDTBL.ASM`; that keeps ROM offsets fresh,
but it leaves BLKS/BMOD placement records stale after editing stock maps in
BDDTool.

This script copies the complete common stock records from the MK7 snapshot into
`src/BGNDTBL.ASM` and preserves source-only records, such as custom-stage tails.
"""
import argparse
import re
import sys
from pathlib import Path


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$")
DROP_SRC_ONLY_LABELS = {
    # MK1PIT is regenerated into src/MK1PITBG.ASM and included from
    # BGNDTBL.ASM. Keeping inline Pit/TPL records here creates duplicate
    # table labels at assembly time.
    "TPLHDRS",
    "MK1PITBLKS",
    "MK1PITBMOD",
    "MK1PITBGBLKS",
    "MK1PITBGBMOD",
    "MK1PITFGBLKS",
    "MK1PITFGBMOD",
    "MK1PITFSBLKS",
    "MK1PITFSBMOD",
    "MK1PITGOREBLKS",
    "MK1PITGOREBMOD",
    "bridge0BLKS",
    "bridge1BLKS",
    "bridge0BMOD",
    "bridge1BMOD",
}

# These stock labels are deliberately overridden after the MK7 snapshot by an
# active sidecar. Do not make the stock-record check fight the sidecar promoter.
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

        if current_label is not None and re.match(r"^\s*\.include\b", line, re.IGNORECASE):
            records.append((current_label, current_body))
            current_label, current_body = None, []
            footer.append(line)
            in_footer = True
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


def strip_blank_tail(lines):
    out = list(lines)
    while out and out[-1] == "":
        out.pop()
    return out


def same_body(a, b):
    return strip_blank_tail(a) == strip_blank_tail(b)


def remove_stale_outputs(repo: Path):
    for name in ("BGND.OBJ", "BGND.LST", "BGNDTBL.OBJ", "BGNDTBL.LST",
                 "mk2.out"):
        path = repo / "src" / name
        if path.exists():
            path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true",
                        help="patch src/BGNDTBL.ASM")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 when stock records differ")
    parser.add_argument("--verbose", action="store_true",
                        help="print changed and missing labels")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    src_tbl = repo / "src" / "BGNDTBL.ASM"
    mk7_snap = repo / "tmp" / "load2" / "BGNDTBL.MK7"

    if not src_tbl.exists():
        print(f"error: {src_tbl} not found", file=sys.stderr)
        return 2
    if not mk7_snap.exists():
        print(f"error: {mk7_snap} not found - run `python build.py` first",
              file=sys.stderr)
        return 2

    src_header, src_records, src_footer = parse_records(src_tbl)
    mk7_header, mk7_records_raw, _ = parse_records(mk7_snap)

    # MK1PIT lives in the regenerated MK1PITBG.ASM include now. Do not compare
    # or copy those labels back into BGNDTBL.ASM.
    mk7_records = [
        (label, body)
        for label, body in mk7_records_raw
        if label not in DROP_SRC_ONLY_LABELS and label not in SIDECAR_OWNED_LABELS
    ]

    src_by_label = {label: body for label, body in src_records}
    mk7_by_label = {label: body for label, body in mk7_records}

    changed = []
    added = []
    aligned = 0
    for label, body in mk7_records:
        src_body = src_by_label.get(label)
        if src_body is None:
            added.append(label)
        elif same_body(src_body, body):
            aligned += 1
        else:
            changed.append(label)

    dropped_src_only = [label for label, _body in src_records
                        if label not in mk7_by_label and label in DROP_SRC_ONLY_LABELS]
    preserved = [(label, body) for label, body in src_records
                 if label not in mk7_by_label and label not in DROP_SRC_ONLY_LABELS]

    print(f"Stock records aligned with MK7 snapshot: {aligned}")
    print(f"Stock records changed:                    {len(changed)}")
    print(f"Stock records new in MK7 snapshot:        {len(added)}")
    print(f"src-only records preserved:               {len(preserved)}")
    if dropped_src_only:
        print(f"src-only generated records dropped:       {len(dropped_src_only)}")

    if args.verbose:
        if changed:
            print("\nchanged:")
            for label in changed[:80]:
                print(f"  {label}")
            if len(changed) > 80:
                print(f"  ... and {len(changed) - 80} more")
        if added:
            print("\nnew:")
            for label in added[:80]:
                print(f"  {label}")
            if len(added) > 80:
                print(f"  ... and {len(added) - 80} more")

    drifted = bool(changed or added or dropped_src_only)
    if args.check:
        return 1 if drifted else 0
    if not args.apply:
        if drifted:
            print("\nRun with --apply to patch src/BGNDTBL.ASM.")
        return 0
    if not drifted:
        print("No stock record drift - nothing to patch.")
        return 0

    out_lines = list(src_header if src_header else mk7_header)
    for _, body in mk7_records:
        out_lines.extend(body)
    for _, body in preserved:
        out_lines.extend(body)
    out_lines.extend(src_footer)

    old_text = src_tbl.read_text(errors="replace")
    new_text = "\n".join(out_lines)
    if old_text.endswith("\n") and not new_text.endswith("\n"):
        new_text += "\n"
    src_tbl.write_text(new_text)
    remove_stale_outputs(repo)

    print(f"patched {len(changed)} changed and {len(added)} new stock records")
    print("removed stale BGND/BGNDTBL assembler outputs - rerun build.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
