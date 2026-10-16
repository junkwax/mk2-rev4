#!/usr/bin/env python3
"""Keep MKFX.ASM's inline MKRIGHT1 header aligned with MKMK3.TBL.

MKFX.ASM defines a private MKRIGHT1 record for the intro copyright art from
CRIGHT.IMG.  LOAD2/promotion updates src/MKMK3.TBL, but this inline copy would
otherwise keep a stale SAG and render garbage after MK7MIL packing changes.
"""
import argparse
import re
import sys
from pathlib import Path


LONG_RE = re.compile(r"^(\s*\.long\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")


def find_label_sag(lines, label):
    for i, line in enumerate(lines):
        if line.strip() == f"{label}:":
            for j in range(i + 1, len(lines)):
                if lines[j].strip().endswith(":"):
                    break
                m = LONG_RE.match(lines[j].rstrip("\r\n"))
                if m:
                    return int(m.group(2), 16), j, m
            raise ValueError(f"{label} has no .long SAG after it")
    raise ValueError(f"{label} not found")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if MKFX.ASM's MKRIGHT1 SAG is stale")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    mkfx_path = repo / "src" / "MKFX.ASM"
    tbl_path = repo / "src" / "MKMK3.TBL"

    mkfx_lines = mkfx_path.read_text(encoding="latin-1").splitlines(keepends=True)
    tbl_lines = tbl_path.read_text(encoding="latin-1").splitlines(keepends=True)

    expected, _, _ = find_label_sag(tbl_lines, "MKRIGHT1")
    actual, mkfx_idx, mkfx_match = find_label_sag(mkfx_lines, "MKRIGHT1")

    if actual == expected:
        print(f"MKFX.ASM MKRIGHT1 SAG aligned: 0{actual:07x}H")
        return 0

    print(
        "MKFX.ASM MKRIGHT1 SAG stale: "
        f"0{actual:07x}H -> 0{expected:07x}H"
    )
    if args.check:
        return 1

    prefix, old_num, suffix, trailing = mkfx_match.groups()
    newline = "\r\n" if mkfx_lines[mkfx_idx].endswith("\r\n") else "\n"
    new_num = f"{expected:0{len(old_num)}x}"
    mkfx_lines[mkfx_idx] = f"{prefix}{new_num}{suffix}{trailing}{newline}"
    mkfx_path.write_text("".join(mkfx_lines), encoding="latin-1")
    print("Updated src/MKFX.ASM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
