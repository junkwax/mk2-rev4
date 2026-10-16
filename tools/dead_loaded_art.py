#!/usr/bin/env python3
"""
Find art the build DOES pack into video ROM and nothing ever draws.

This is the reclaim question, and it is the opposite of
tools/img_subframe_audit.py: that one lists records sitting in the IMG
libraries that no LOD loads (they cost nothing and are candidates for
ADDING).  This one starts from the names a live LOD does load - every one
of those is packed pixels in an .IRW, i.e. real video ROM - and asks
whether any code draws the label.

Method
------
1.  Loaded names come from the live LODs (data/IMGBUILD.BAT), via
    img_subframe_audit.  A name in a `---> ` list is packed art.
2.  Packed size is measured from the SAGs, not from w*h: LOAD2 packs in
    LOD order, so sorting every SAG in the tree and taking the gap to the
    next one gives what the frame actually cost after zero compression.
    The gap is clamped to the uncompressed w*h*ppp/8, which removes the
    one bogus jump at each region boundary (packed is never bigger).
3.  A label is REFERENCED if the identifier appears anywhere in src/
    other than its own record definition in the .TBL and its `.globl` in
    a .GLO.  A `.globl` is not a draw.
4.  Unreferenced labels are grouped into CONTIGUOUS RUNS in .TBL file
    order, and a run is only reported if the label immediately before it
    is ALSO unreferenced.  Animation lanes advance forward into the next
    record, so a run hanging off a referenced frame is reachable even
    though nothing names it.  This is the filter that made the previous
    sweep defensible and it is deliberately conservative.

Anything this prints is a CANDIDATE, not a verdict.  Read
[[reference_inline_asm_sprite_records]] and doc/ASSET_SPACE_LEDGER.md
before deleting a `---> ` name.

Usage:
    python tools/dead_loaded_art.py                  # runs, largest first
    python tools/dead_loaded_art.py --min-bytes 4096
    python tools/dead_loaded_art.py --all            # every unreferenced label
    python tools/dead_loaded_art.py --tbl MKHH       # one table
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import img_subframe_audit as audit  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(;.*)?$")
_LONG = re.compile(r"^\s*\.long\s+0?([0-9a-fA-F]+)[Hh]\s*(;.*)?$")
_WORD4 = re.compile(r"^\s*\.word\s+(-?\d+)\s*,\s*(-?\d+)\s*,")


def read_tbls():
    """-> {TBL stem: [ {name, sag, w, h, line} ]} in file order."""
    out = {}
    for p in sorted(glob.glob(str(SRC / "*.TBL"))):
        stem = Path(p).stem.upper()
        lines = open(p, encoding="latin-1").read().splitlines()
        recs = []
        for i, raw in enumerate(lines):
            m = _LABEL.match(raw.rstrip())
            if not m:
                continue
            name = m.group(1)
            w = h = sag = None
            for j in range(i + 1, min(i + 6, len(lines))):
                mw = _WORD4.match(lines[j])
                if mw and w is None:
                    w, h = int(mw.group(1)), int(mw.group(2))
                ml = _LONG.match(lines[j])
                if ml and sag is None:
                    sag = int(ml.group(1), 16)
                if _LABEL.match(lines[j].rstrip()):
                    break
            if sag is not None:
                recs.append({"name": name, "sag": sag, "w": w or 0,
                             "h": h or 0, "line": i + 1})
        if recs:
            out[stem] = recs
    return out


def reference_counts():
    """Identifier -> number of appearances across src/, minus .GLO lines."""
    counts = defaultdict(int)
    ident = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
    for p in sorted(glob.glob(str(SRC / "*"))):
        ext = Path(p).suffix.upper()
        if ext not in (".ASM", ".TBL", ".HDR", ".H", ".EQU"):
            continue
        for raw in open(p, encoding="latin-1", errors="replace"):
            line = raw.split(";", 1)[0]
            if not line.strip():
                continue
            for t in ident.findall(line):
                counts[t] += 1
    return counts


def packed_sizes(tbls, ppp_of):
    """SAG -> packed bytes, from the gap to the next SAG in the whole tree."""
    sag_rec = {}
    for stem, recs in tbls.items():
        for r in recs:
            sag_rec.setdefault(r["sag"], r)
    order = sorted(sag_rec)
    size = {}
    for i, s in enumerate(order):
        r = sag_rec[s]
        gap = (order[i + 1] - s) // 8 if i + 1 < len(order) else 0
        bpp = ppp_of.get(r["name"].upper(), 6) or 6
        cap = (r["w"] * r["h"] * bpp + 7) // 8
        if gap <= 0:
            gap = cap
        size[s] = min(gap, cap) if cap else max(gap, 0)
    return size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-bytes", type=int, default=1024)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--tbl")
    a = ap.parse_args()

    lods = audit.live_lods()
    used, origin, ppp = audit.collect(lods)

    loaded = set()
    ppp_of = {}
    for img, names in used.items():
        d = ppp.get(img, 6)
        for n in names:
            loaded.add(n)
            ppp_of[n] = d

    tbls = read_tbls()
    counts = reference_counts()
    size = packed_sizes(tbls, ppp_of)

    # A record definition contributes 1 (its own label line).  Anything
    # above that is a real mention somewhere in src/.
    def referenced(name):
        return counts.get(name, 0) > 1

    # Runs are grouped over EVERY record in the table, not just the loaded
    # ones - "the frame immediately before" means the previous record in the
    # file, and a record the LOD does not load must not split a run.  Only
    # loaded records carry bytes; an unloaded one costs no video ROM.
    runs = []
    total_unref = 0
    for stem, recs in sorted(tbls.items()):
        if a.tbl and stem != a.tbl.upper():
            continue
        cur = []
        prev_ref = True   # nothing before the first record - treat as reachable
        run_prev = True
        for r in recs:
            nm = r["name"]
            is_loaded = nm.upper() in loaded
            nbytes = size.get(r["sag"], 0) if is_loaded else 0
            if is_loaded and not referenced(nm):
                total_unref += nbytes
            if not referenced(nm):
                if not cur:
                    run_prev = prev_ref
                cur.append(dict(r, bytes=nbytes, loaded=is_loaded))
            else:
                if cur:
                    runs.append({"tbl": stem, "recs": cur, "after_ref": run_prev})
                    cur = []
            prev_ref = referenced(nm)
        if cur:
            runs.append({"tbl": stem, "recs": cur, "after_ref": run_prev})

    keep = [r for r in runs
            if a.all or (not r["after_ref"] and len(r["recs"]) >= 2)]
    for r in keep:
        r["bytes"] = sum(x["bytes"] for x in r["recs"])
    keep = [r for r in keep if a.all or r["bytes"] >= a.min_bytes]
    keep.sort(key=lambda x: -x["bytes"])

    print("# Loaded-but-unreferenced art\n")
    print("loaded labels (packed pixels) : %s" % format(len(loaded), ","))
    print("of those, nothing in src/ names: %s"
          % format(sum(1 for n in loaded if not referenced(n)), ","))
    print("  their packed bytes           : ~%s" % format(total_unref, ","))
    print("after the run filter           : %d runs, ~%s bytes"
          % (len(keep), format(sum(r["bytes"] for r in keep), ",")))
    print()
    print("The run filter drops any run that follows a REFERENCED frame - an")
    print("animation lane advances into the next record, so those are live.")
    print()

    for r in keep:
        names = [x["name"] for x in r["recs"]]
        print("## %s.TBL  line %d  -  %d frames, ~%s bytes"
              % (r["tbl"], r["recs"][0]["line"], len(r["recs"]),
                 format(r["bytes"], ",")))
        for x in r["recs"]:
            print("    %-22s %4dx%-4d ~%8sb"
                  % (x["name"], x["w"], x["h"], format(x["bytes"], ",")))
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
