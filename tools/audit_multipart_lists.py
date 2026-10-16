#!/usr/bin/env python
"""Audit hand-written multipart piece lists in src/*.ASM.

A frame is drawn as a NUL-terminated list of piece labels:

    TMUPPERCUT3
            .long   TMUPPERCUT3A,TMUPPERCUT3B,TMUPPERCUT3C,0

The pieces themselves live in the matching .TBL as

    TMUPPERCUT3C:
            .word   23,123,-18,-24          W,H,anix,aniy
            .long   01333f8H                SAG
            .word   06080H                  control

Nothing promotes or checks these lists - they are typed by hand in .ASM and
the .TBL is generated - so a slip in one is silent for as long as nobody
looks at that frame.  Kung Lao's uppercut carried

            .long   TMUPPERCUT3A,TMUPPERCUT3B,TMUPPERCUT3B,0

for thirty years: the hat twice and the trailing arm never drawn.

Two findings, in descending confidence:

  DUPLICATE   the same piece label twice in one list.  Pieces carry their own
              dx/dy, so drawing one twice puts it in exactly the same place -
              there is no legitimate reason to do it, and it is always one
              character away from the label that should have been there.

  UNDRAWN     a piece that exists in the .TBL and is referenced by NOTHING in
              any .ASM.  On its own that is weak - plenty of art is genuinely
              cut - so it is reported separately, and only for names whose
              siblings ARE drawn (FOOA and FOOB used, FOOC used nowhere).

A DUPLICATE and an UNDRAWN sibling on the same frame is the Kung Lao bug
exactly, and those are called out together as CONFIRMED.

Usage:
    python tools/audit_multipart_lists.py            # report
    python tools/audit_multipart_lists.py --check    # exit 1 on a CONFIRMED
"""

import argparse
import collections
import pathlib
import re
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "src"

# "LABEL" alone on a line, then a .long list of names ending in 0.
LIST_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)\s*$\r?\n"
    r"^\s+\.long\s+([A-Za-z0-9_,\s]+?),\s*0\s*(?:;.*)?$",
    re.MULTILINE,
)

# "NAME:" in a .TBL followed by a .word geometry line.
TBL_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*):\s*$\r?\n"
    r"^\s+\.word\s+(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)",
    re.MULTILINE,
)

SUFFIX_RE = re.compile(r"^(.*?)([A-Z])$")


def read(path):
    return path.read_text(encoding="latin-1")


def collect_pieces():
    """name -> (file, W, H, anix, aniy) for every piece record in src/*.TBL."""
    pieces = {}
    for tbl in sorted(SRC.glob("*.TBL")):
        for m in TBL_RE.finditer(read(tbl)):
            name = m.group(1)
            pieces[name] = (tbl.name,) + tuple(int(g) for g in m.groups()[1:])
    return pieces


def collect_lists():
    """[(file, line, frame label, [piece names])] for every .ASM piece list."""
    out = []
    for asm in sorted(SRC.glob("*.ASM")):
        text = read(asm)
        for m in LIST_RE.finditer(text):
            names = [n.strip() for n in m.group(2).split(",") if n.strip()]
            line = text.count("\n", 0, m.start()) + 1
            out.append((asm.name, line, m.group(1), names))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if a CONFIRMED finding is present")
    args = ap.parse_args()

    pieces = collect_pieces()
    lists = collect_lists()

    # Every piece name mentioned anywhere in .ASM, list or not.
    referenced = set()
    word_re = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
    for asm in sorted(SRC.glob("*.ASM")):
        referenced.update(word_re.findall(read(asm)))

    duplicates = []
    for fname, line, label, names in lists:
        # Only consider lists that actually name known pieces - the same
        # "label then .long" shape is used for plain data tables too.
        known = [n for n in names if n in pieces]
        if not known:
            continue
        seen = collections.Counter(names)
        for name, count in seen.items():
            if count > 1 and name in pieces:
                duplicates.append((fname, line, label, name, count, names))

    # Undrawn siblings: FOOC exists, is referenced nowhere, and FOOA/FOOB are.
    undrawn = []
    by_stem = collections.defaultdict(list)
    for name in pieces:
        m = SUFFIX_RE.match(name)
        if m:
            by_stem[m.group(1)].append((m.group(2), name))
    for stem, sibs in sorted(by_stem.items()):
        if len(sibs) < 2:
            continue
        used = [n for _, n in sibs if n in referenced]
        unused = [n for _, n in sibs if n not in referenced]
        if used and unused:
            for n in sorted(unused):
                undrawn.append((stem, n, sorted(used), pieces[n]))

    undrawn_names = {n for _, n, _, _ in undrawn}

    # A frame that has BOTH a duplicate and an undrawn sibling is the bug.
    confirmed = []
    for fname, line, label, name, count, names in duplicates:
        m = SUFFIX_RE.match(name)
        stem = m.group(1) if m else None
        hit = [n for n in undrawn_names
               if stem and SUFFIX_RE.match(n) and SUFFIX_RE.match(n).group(1) == stem]
        if hit:
            confirmed.append((fname, line, label, name, sorted(hit), names))

    print(f"{len(pieces)} piece records in src/*.TBL")
    print(f"{len(lists)} multipart piece lists in src/*.ASM")
    print()

    if confirmed:
        print(f"CONFIRMED - duplicate piece AND an undrawn sibling ({len(confirmed)})")
        for fname, line, label, name, hit, names in confirmed:
            print(f"  {fname}:{line}  {label}")
            print(f"      drawn: {','.join(names)}")
            print(f"      {name} appears twice; {', '.join(hit)} is drawn nowhere")
        print()
    else:
        print("CONFIRMED: none")
        print()

    other_dupes = [d for d in duplicates
                   if (d[0], d[1], d[2], d[3]) not in
                   {(c[0], c[1], c[2], c[3]) for c in confirmed}]
    if other_dupes:
        print(f"DUPLICATE - same piece twice, no undrawn sibling ({len(other_dupes)})")
        for fname, line, label, name, count, names in other_dupes:
            print(f"  {fname}:{line}  {label}: {name} x{count}  [{','.join(names)}]")
        print()

    if undrawn:
        print(f"UNDRAWN - piece exists, siblings are drawn, this one is not ({len(undrawn)})")
        for stem, name, used, geo in undrawn:
            f, w, h, ax, ay = geo
            print(f"  {name:<28} {w}x{h} @ ({ax},{ay})  {f}   siblings drawn: {','.join(used)}")
        print()

    if args.check and confirmed:
        print("FAIL: a multipart list draws one piece twice and leaves a sibling undrawn")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
