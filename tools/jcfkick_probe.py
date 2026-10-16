#!/usr/bin/env python3
r"""Re-find the three Johnny Cage flip-kick probe addresses in the built ROM
and rewrite tools/jcfkick_probe.ds.

Every relink moves them, so nothing here is hardcoded: the combo is found by
its DATA (Back,Back with a 020h window, referenced by a 033h button mask),
and the routine by walking the propel dispatch the way the CPU does.

    python tools/jcfkick_probe.py          # print + rewrite the .ds
    python tools/jcfkick_probe.py --print  # just print
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLAT = ROOT / "rom" / "mk2_flat.bin"
DS = ROOT / "tools" / "jcfkick_probe.ds"
BASE = 0xFF800000

SW_LEFT, SW_RIGHT = 7, 8
WINDOW = 0x20
MASK_A0 = 0x0033                # f1b0|f1b1|f1b2|f1b4 - the HK button mask
PROPEL_IDX = 0x13               # do_jc_flipkick's propel entry


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--print", dest="only_print", action="store_true")
    a = ap.parse_args()

    if not FLAT.exists():
        sys.exit("%s missing - run makerom.py" % FLAT)
    d = FLAT.read_bytes()

    def L(bit):
        return struct.unpack_from("<I", d, (bit - BASE) // 8)[0]

    # --- the combo, by its data ------------------------------------------
    pat = struct.pack("<13H", WINDOW, SW_LEFT, SW_LEFT, 0, 0, 0, 0,
                      SW_RIGHT, SW_RIGHT, 0, 0, 0, 0)
    combos, i = [], 0
    while True:
        i = d.find(pat, i)
        if i < 0:
            break
        combos.append(BASE + i * 8)
        i += 2
    if not combos:
        sys.exit("no Back,Back/%02Xh combo in the ROM - is the build current?" % WINDOW)

    # --- the test site: movi 33h,a0 / movi _,a1 / movi <combo>,a11 -------
    site = None
    for c in combos:
        needle = struct.pack("<HH", 0x09C0, MASK_A0)
        j = 0
        while True:
            j = d.find(needle, j)
            if j < 0:
                break
            if struct.unpack_from("<H", d, j + 8)[0] == 0x09EB and \
               struct.unpack_from("<I", d, j + 10)[0] == c:
                site = BASE + j * 8
                combo = c
                break
            j += 2
        if site:
            break
    if site is None:
        sys.exit("found %d Back,Back combo(s) but no 033h-mask test referencing one"
                 % len(combos))

    handler = site - 0x30         # one calla (bb_check) ahead of it
    matched = site + 0xA0         # movi/movi/movi/callr/jrnc -> the match arm

    # --- the routine: walk the propel dispatch ---------------------------
    disp = d.find(struct.pack("<HHH", 0x0B60, 0xFFEB, 0xFFFF))   # cmpi 14h,a0
    if disp < 0:
        sys.exit("propel dispatcher (cmpi 14h,a0) not found - table size changed?")
    # ... jrhi(2w) ... sll 5,a0(1w) ... addi <table>,a0(3w)
    table = struct.unpack_from("<I", d, disp + 6 + 4 + 2 + 2)[0]
    routine = L(table + 32 * PROPEL_IDX)

    print("scom_jc_flipkick   %08x" % combo)
    print("jc_hi_kick         %08x   [1] HK handler" % handler)
    print("combo matched      %08x   [2] -> restricted_xfer" % matched)
    print("propell_table      %08x   entry %02Xh" % (table, PROPEL_IDX))
    print("do_jc_flipkick     %08x   [3] routine entered" % routine)

    if a.only_print:
        return 0

    txt = DS.read_text(encoding="utf-8")
    # split on the first line that STARTS with bpset - the header prose
    # mentions the word, and splitting on it ate the comments once already.
    lines = txt.splitlines(keepends=True)
    cut = next((i for i, l in enumerate(lines) if l.startswith("bpset")), len(lines))
    head = "".join(lines[:cut])
    DS.write_text(head +
                  "bpset %08x,1,{printf \"[1] HK handler (jc_hi_kick)\\n\"; g}\n" % handler +
                  "bpset %08x,1,{printf \"[2] COMBO MATCHED -> restricted_xfer\\n\"; g}\n" % matched +
                  "bpset %08x,1,{printf \"[3] ROUTINE ENTERED (do_jc_flipkick)\\n\"; g}\n" % routine +
                  "g\n", encoding="utf-8")
    print("\nrewrote %s" % DS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
