#!/usr/bin/env python3
"""Restore per-module ascending-x block order in a BDB.

The runtime finds a module's blocks with a binary search on x (`bsrch1stxb`,
BAKGND.ASM), so a module whose records are not sorted by ascending x loses every
block past the first inversion - silently, with no build error. All 41 shipped
stages have zero inversions in every module.

BDDTool writes the block list in object order, which is not x order: saving a
stage after grouping work can leave inversions in a module the edit never
touched. That is how the retail PLANE5 wall picked one up while the guards were
being placed.

Sorting is per module. Blocks keep their module, their pixels, their z and their
position - only the order of the records in the file changes, which is what
LOAD2 reads to build each <module>BLKS table.

    python tools/bdb_xsort.py data/TWRSIDE.BDB          # report
    python tools/bdb_xsort.py data/TWRSIDE.BDB --apply  # rewrite
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

NL = chr(10)


def read_bdd_sizes(path):
    d = path.read_bytes()
    pos = d.index(b"\n") + 1
    n = int(d[:pos].split()[0])
    sizes = {}
    for _ in range(n):
        j = d.index(b"\n", pos)
        p = d[pos:j].split()
        idx, w, h = int(p[0], 16), int(p[1]), int(p[2])
        sizes[idx] = (w, h)
        pos = j + 1 + w * h
    return sizes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bdb")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    bdb = Path(args.bdb)
    bdd = bdb.with_suffix(".BDD")
    if not bdd.exists():
        bdd = bdb.with_suffix(".bdd")
    sizes = read_bdd_sizes(bdd)

    lines = [l for l in bdb.read_text().replace(chr(13), "").split(NL) if l.strip()]
    head = lines[0].split()
    nmods = int(head[4])
    mods = [m.split() for m in lines[1:1 + nmods]]
    blocks = [l.split() for l in lines[1 + nmods:1 + nmods + int(head[6])]]

    def module_of(b):
        w, h = sizes[int(b[3], 16)]
        x, y = int(b[1]), int(b[2])
        for mi, m in enumerate(mods):
            if (x >= int(m[1]) and y >= int(m[3]) and
                    x + w - 1 <= int(m[2]) and y + h - 1 <= int(m[4])):
                return mi
        return len(mods)          # unassigned: LOAD2 drops these anyway

    grouped = {}
    for i, b in enumerate(blocks):
        grouped.setdefault(module_of(b), []).append((i, b))

    total = 0
    for mi in sorted(grouped):
        name = mods[mi][0] if mi < len(mods) else "(unassigned)"
        xs = [int(b[1]) for _i, b in grouped[mi]]
        inv = sum(1 for k in range(1, len(xs)) if xs[k] < xs[k - 1])
        total += inv
        print("  %-12s %3d blocks, %d x-inversion(s)" % (name, len(xs), inv))
    if total == 0:
        print("every module is already ascending-x; nothing to do")
        return 0
    if not args.apply:
        print("%s%d inversion(s) total - re-run with --apply to sort" % (NL, total))
        return 1

    # Sort within each module, then emit the modules in the order their first
    # block appeared, so the file stays as close to its previous shape as the
    # invariant allows.
    out = []
    for mi in sorted(grouped, key=lambda m: grouped[m][0][0]):
        rows = sorted(grouped[mi], key=lambda t: (int(t[1][1]), int(t[1][2])))
        out.extend(b for _i, b in rows)

    assert sorted(" ".join(b) for b in out) == sorted(" ".join(b) for b in blocks), \
        "sort changed the block set"
    head[6] = str(len(out))
    bdb.write_text(NL.join([" ".join(head)] + [" ".join(m) for m in mods] +
                           [" ".join(b) for b in out]) + NL, newline="")
    print("%swrote %s: %d block(s) reordered, same set" % (NL, bdb.name, len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
