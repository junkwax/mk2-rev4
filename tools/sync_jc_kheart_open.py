#!/usr/bin/env python3
"""Keep MKDEATH.ASM's inline KHEART6B_OPEN header aligned with JCMK1BLD.TBL.

Johnny Cage's headhole (brain-rip) fatality shows a re-anchored copy of the
KHEART6B frame - `KHEART6B_OPEN` - for the whole JCHIPUNCH3 punch-through
beat.  Only its anipoint differs from the real record; the SAG, size and
control word are a straight copy of KHEART6B in src/JCMK1BLD.TBL.

LOAD2/promotion updates the TBL when MK1BLOOD art repacks, but nothing
touches the inline copy, so it silently rots: it once kept pointing at
0x03b22236 after KHEART6B moved to 0x039cf236, which blitted a 14x18 window
out of the middle of NOOBAIRKICK2 onto Cage's hand for ~0.9s.
"""
import argparse
import re
import sys
from pathlib import Path


WORD_RE = re.compile(r"^(\s*\.word\s+)(-?\d+\s*,\s*-?\d+)(\s*,\s*-?\d+\s*,\s*-?\d+)(\s*(?:;.*)?)$")
LONG_RE = re.compile(r"^(\s*\.long\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")
CTRL_RE = re.compile(r"^(\s*\.word\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")


def read_record(lines, label):
    """Return (start_index, {'size':(w,h,i), 'sag':(v,i), 'ctrl':(v,i)})."""
    for i, line in enumerate(lines):
        if line.strip() in (f"{label}:", label):
            fields = {}
            for j in range(i + 1, len(lines)):
                s = lines[j].strip()
                if not s or s.startswith(";") or s.startswith("*"):
                    continue
                if s.endswith(":") or (j > i + 1 and "size" not in fields and "sag" in fields):
                    pass
                m = WORD_RE.match(lines[j].rstrip("\r\n"))
                if m and "size" not in fields:
                    w, h = (int(x) for x in m.group(2).split(","))
                    fields["size"] = (w, h, j)
                    continue
                m = LONG_RE.match(lines[j].rstrip("\r\n"))
                if m and "sag" not in fields:
                    fields["sag"] = (int(m.group(2), 16), j, m)
                    continue
                m = CTRL_RE.match(lines[j].rstrip("\r\n"))
                if m and "sag" in fields and "ctrl" not in fields:
                    fields["ctrl"] = (int(m.group(2), 16), j, m)
                    break
                if s.endswith(":"):
                    break
            if "sag" not in fields:
                raise ValueError(f"{label} has no .long SAG after it")
            return i, fields
    raise ValueError(f"{label} not found")


def rewrite_hex(lines, idx, match, value):
    prefix, old_num, suffix, trailing = match.groups()
    newline = "\r\n" if lines[idx].endswith("\r\n") else "\n"
    lines[idx] = f"{prefix}{value:0{len(old_num)}x}{suffix}{trailing}{newline}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if MKDEATH.ASM's KHEART6B_OPEN is stale")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    asm_path = repo / "src" / "MKDEATH.ASM"
    tbl_path = repo / "src" / "JCMK1BLD.TBL"

    asm_lines = asm_path.read_text(encoding="latin-1").splitlines(keepends=True)
    tbl_lines = tbl_path.read_text(encoding="latin-1").splitlines(keepends=True)

    _, want = read_record(tbl_lines, "KHEART6B")
    _, have = read_record(asm_lines, "KHEART6B_OPEN")

    problems = []
    if have["sag"][0] != want["sag"][0]:
        problems.append(("SAG", f"0{have['sag'][0]:07x}H", f"0{want['sag'][0]:07x}H"))
    if have["size"][:2] != want["size"][:2]:
        problems.append(("size", str(have["size"][:2]), str(want["size"][:2])))
    if have["ctrl"][0] != want["ctrl"][0]:
        problems.append(("ctrl", f"0{have['ctrl'][0]:04x}H", f"0{want['ctrl'][0]:04x}H"))

    if not problems:
        print(f"MKDEATH.ASM KHEART6B_OPEN aligned with KHEART6B: "
              f"0{have['sag'][0]:07x}H {have['size'][:2]} 0{have['ctrl'][0]:04x}H")
        return 0

    for field, old, new in problems:
        print(f"MKDEATH.ASM KHEART6B_OPEN {field} stale: {old} -> {new}")
    if args.check:
        return 1

    if have["sag"][0] != want["sag"][0]:
        rewrite_hex(asm_lines, have["sag"][1], have["sag"][2], want["sag"][0])
    if have["ctrl"][0] != want["ctrl"][0]:
        rewrite_hex(asm_lines, have["ctrl"][1], have["ctrl"][2], want["ctrl"][0])
    if have["size"][:2] != want["size"][:2]:
        idx = have["size"][2]
        m = WORD_RE.match(asm_lines[idx].rstrip("\r\n"))
        newline = "\r\n" if asm_lines[idx].endswith("\r\n") else "\n"
        asm_lines[idx] = (f"{m.group(1)}{want['size'][0]},{want['size'][1]}"
                          f"{m.group(3)}{m.group(4)}{newline}")

    asm_path.write_text("".join(asm_lines), encoding="latin-1")
    print("Updated src/MKDEATH.ASM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
