#!/usr/bin/env python3
"""Sync MKSEL.ASM's private VS restore chunks from BGNDTBL.ASM.

The stage-select overlay redraws small pieces of the MKVERSUS background before
printing "KOMBAT ZONE" and the selected arena name.  Those private image headers
must track RSUSHDRS when MK7MIL shifts, or the VS screen restores garbage art
over the text area.
"""
import argparse
import re
import sys
from pathlib import Path


LONG_RE = re.compile(r"^(\s*\.long\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")
WORD2_RE = re.compile(r"^\s*\.word\s+([^,;\s]+)\s*,\s*([^,;\s]+)", re.IGNORECASE)
LABEL_ONLY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*:?\s*(?:;.*)?$")

TARGETS = {
    "vs_stage_strip_img": 2,  # RSUSHDRS hdr 02, lower stone strip
    "vs_stage_panel_img": 9,  # RSUSHDRS hdr 09, name panel
}


def parse_num(token):
    token = token.strip()
    if token.upper().endswith("H"):
        return int(token[:-1], 16)
    return int(token, 10)


def find_label(lines, label):
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == label or stripped == f"{label}:":
            return i
    raise ValueError(f"{label} not found")


def parse_rsushdrs(lines):
    start = find_label(lines, "RSUSHDRS") + 1
    out = []
    i = start
    while i < len(lines):
        if lines[i].strip() == "VSSCREENBLKS:":
            return out
        wm = WORD2_RE.match(lines[i])
        if not wm:
            i += 1
            continue
        if i + 2 >= len(lines):
            break
        lm = LONG_RE.match(lines[i + 1].rstrip("\r\n"))
        if not lm:
            i += 1
            continue
        out.append((parse_num(wm.group(1)), parse_num(wm.group(2)), int(lm.group(2), 16)))
        i += 3
    raise ValueError("VSSCREENBLKS not found after RSUSHDRS")


def find_inline_sag(lines, label):
    start = find_label(lines, label) + 1
    for i in range(start, len(lines)):
        if LABEL_ONLY_RE.match(lines[i].strip()):
            break
        m = LONG_RE.match(lines[i].rstrip("\r\n"))
        if m:
            return int(m.group(2), 16), i, m
    raise ValueError(f"{label} has no .long SAG after it")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if MKSEL.ASM's VS restore SAGs are stale")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    mksel_path = repo / "src" / "MKSEL.ASM"
    bgndtbl_path = repo / "src" / "BGNDTBL.ASM"

    mksel_lines = mksel_path.read_text(encoding="latin-1").splitlines(keepends=True)
    bgnd_lines = bgndtbl_path.read_text(encoding="latin-1").splitlines(keepends=True)
    rsushdrs = parse_rsushdrs(bgnd_lines)

    stale = []
    for label, index in TARGETS.items():
        if index >= len(rsushdrs):
            raise ValueError(f"RSUSHDRS index {index} missing for {label}")
        _w, _h, expected = rsushdrs[index]
        actual, line_idx, match = find_inline_sag(mksel_lines, label)
        if actual != expected:
            stale.append((label, actual, expected, line_idx, match))

    if not stale:
        print("MKSEL.ASM VS restore SAGs aligned")
        return 0

    for label, actual, expected, _line_idx, _match in stale:
        print(f"{label} SAG stale: 0{actual:07x}H -> 0{expected:07x}H")

    if args.check:
        return 1

    for _label, _actual, expected, line_idx, match in stale:
        prefix, old_num, suffix, trailing = match.groups()
        newline = "\r\n" if mksel_lines[line_idx].endswith("\r\n") else "\n"
        mksel_lines[line_idx] = (
            f"{prefix}{expected:0{len(old_num)}x}{suffix}{trailing}{newline}"
        )

    mksel_path.write_text("".join(mksel_lines), encoding="latin-1")
    print("Updated src/MKSEL.ASM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
