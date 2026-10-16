#!/usr/bin/env python3
"""Which stages are even CANDIDATES for skipping floor rows, from the source.

`floor_code` (MKDISP.ASM) draws the skewing ground one 400x1 blit per texture
row.  `@skew_skip` is how many rows at the TOP of that band - the BACK of the
room - a stage guarantees something else repaints opaquely, so it can stop
drawing them.  THE TOWER sets 54 and saves 54 of the object queue's 500 cells
and ~21,600 programmed pixels a frame.  Every other stage sets 0.

This reports only what the source proves, which is the shape of the question,
not its answer:

  * where each stage's floor band sits, from its <stage>_floor_info table;
  * what its dlists_ table draws AFTER floor_code, because nothing drawn
    before it can cover it;
  * whether those layers are background modules or lists the stage BUILDS.

A stage with nothing after floor_code is settled here - there is no candidate
coverage at all.  For every other stage the answer is a coverage question that
source cannot settle, and guessing at it from module bounding boxes is how you
get a confident wrong number: the Tower's own skipped band is not 100% opaque,
because the mirrored windows are holes and what shows through them is the
autoerase colour, chosen to be the sky.

    python tools/floor_skip_audit.py
    python tools/floor_skip_audit.py --check     # Phase D

**Measure it with tools/run_floor_skip_probe.py**, which pins @skew_skip to the
whole floor height on the real machine and photographs the difference.  As of
2026-09-12 it measures THE TOWER at 54 (its shipped value, the control) and
every other floor stage at 0.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# curback index -> stage, for the stages whose dlists_ contains floor_code.
CURBACK = {"tomb": 1, "battle": 2, "tower": 3, "forest": 4, "armory": 5,
           "port": 7, "arena": 8}

# Measured by tools/run_floor_skip_probe.py on 2026-09-12.  A stage is listed
# here only once it has been photographed, not once it has been argued about.
MEASURED = {"tower": 54, "tomb": 0, "battle": 0, "forest": 0, "armory": 0,
            "arena": 0, "port": 0}


def floor_bands(asm):
    out = {}
    for m in re.finditer(r"^(\w+)_floor_info\s*$(.*?)(?=^\w|\Z)", asm, re.M | re.S):
        nums = re.findall(r"\.word\s+(0?[0-9a-fA-F]+h|\d+)", m.group(2))
        if len(nums) >= 2:
            def val(t):
                return int(t[:-1], 16) if t.lower().endswith("h") else int(t)
            out[m.group(1)] = (val(nums[0]), val(nums[1]))
    return out


def after_floor(asm):
    """Per stage, the dlist entries drawn between floor_code and the shadows."""
    out = {}
    for m in re.finditer(r"^dlists_(\w+)\s*$(.*?)(?=^\w|\Z)", asm, re.M | re.S):
        entries = []
        for line in m.group(2).splitlines():
            line = line.split(";")[0].strip()
            mm = re.match(r"^\.long\s+([^,]+?)\s*(?:,\s*(\S+))?$", line)
            if mm:
                entries.append((mm.group(1).strip(), mm.group(2)))
        i = next((j for j, (h, t) in enumerate(entries)
                  if h == "-1" and t == "floor_code"), None)
        if i is None:
            continue
        layers = []
        for h, t in entries[i + 1:]:
            if h == "-2" or h.startswith("objlst"):
                break
            layers.append(h if t is None else "%s(%s)" % (h, t))
        out[m.group(1)] = layers
    return out


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="fail if a stage's coverage basis changed")
    args = ap.parse_args()

    asm = (ROOT / "src" / "BGND.ASM").read_text(errors="replace")
    bands, layers = floor_bands(asm), after_floor(asm)
    # Who sets skew_skip at all, anywhere in the tree.
    setters = set()
    for path in sorted((ROOT / "src").glob("*.ASM")):
        text = path.read_text(errors="replace")
        if re.search(r"move\s+\w+,@skew_skip", text):
            setters.add(path.name)

    rc = 0
    for stage in sorted(layers):
        band = bands.get(stage)
        after = layers[stage]
        built = [l for l in after if not l.startswith("baklst")]
        measured = MEASURED.get(stage)
        where = ("rows %d..%d" % (band[0], band[0] + band[1] - 1)) if band else "band ?"
        print("%-8s curback %-4s %-16s after floor_code: %s"
              % (stage, CURBACK.get(stage, "?"), where,
                 ", ".join(after) if after else "NOTHING - settled, 0 rows"))
        if built:
            print("         %d of those are lists the stage BUILDS, not background "
                  "modules: %s" % (len(built), ", ".join(built)))
        if measured is not None:
            print("         measured skippable: %d row(s)" % measured)
        if args.check:
            if not after and measured:
                print("         ! nothing covers this floor but %d rows are claimed"
                      % measured)
                rc = 1
            if stage == "tower" and not built:
                print("         ! THE TOWER's reflection lists are no longer drawn "
                      "after floor_code - its skew_skip of 54 is unbacked")
                rc = 1
    print("skew_skip is written by: %s" % ", ".join(sorted(setters)))
    if args.check and setters != {"BGND.ASM", "TWRBACK.ASM"}:
        print("! a new stage sets skew_skip - measure it with "
              "tools/run_floor_skip_probe.py before trusting it")
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
