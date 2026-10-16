#!/usr/bin/env python3
"""Every ani2 lookup in the SAI routines must go through kham_sai_ani2.

Khameleon (ft_kham = 18) is the union of the three female ninjas, and her
TABLE2 (`fn4_anitab2`, MKFN.ASM) keeps Kitana's and Jade's lanes at their
original indices - every one of those is read with a hardcoded `movk`, so
they could not move.  Mileena's sai therefore had to: her 5/6/7 collide with
Kitana's square-wave punch and Jade's boomerang throw/spin.  The sai lanes
live at 0ch-0eh in her table, and `kham_sai_ani2` (MKZAP.ASM) adds
`kham_sai_bias` to the index when the wearer is Khameleon.

THE FAILURE MODE THIS EXISTS FOR.  A sai site that still calls
`get_char_ani2` directly does not crash and does not error at build time.
It quietly renders index 6 of HER table - which is `a_fn1_boom_spin`, the
boomerang - so a few frames of Jade's boomerang appear in the middle of the
sai.  That is exactly what shipped once: `saih4`, the shared hit/blocked
impact path, was missed in the first pass and drew boomerang frames at the
moment of contact.

Five of the six sites are obvious (the throw, the air throw, the flight
loop).  The sixth is not, because it reads the flight lane and then takes
`find_part2` of it - the impact frames are part two of the SAME lane, so it
needs the bias for a reason that is not visible at the call site.

Run with no arguments (or --check) - exits non-zero if any raw site is left.
"""
import os
import re
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
MKZAP = os.path.join(SRC, "MKZAP.ASM")

# The routines that make up the sai, by label.  A new one has to be added
# here as well as biased - that is deliberate: this list is the statement of
# which code is sai code, and it should not be guessed from a substring
# ("Saibot" and "sz_airice" both contain 'sai'/'ai' and are not).
SAI_ROUTINES = {
    "do_throw_sai",          # ground throw: pose + the projectile object
    "do_throw_sai_air",      # air throw:    pose + the projectile object
    "sai_proc",              # the flight loop
    "sai_hit",               # contact
    "saih4",                 # hit AND blocked share this impact tail
    "saip4",                 # flight scan loop-back
}

RAW = re.compile(r"^\s+calla\s+get_char_ani2\b")
BIASED = re.compile(r"^\s+callr\s+kham_sai_ani2\b")
LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)")


def main() -> int:
    with open(MKZAP, encoding="latin-1") as fh:
        lines = fh.read().replace("\r\n", "\n").splitlines()

    # label -> [start, end) spans, in file order
    spans = []
    for i, line in enumerate(lines):
        m = LABEL.match(line)
        if m and not line.startswith((" ", "\t")):
            spans.append((i, m.group(1)))
    spans.append((len(lines), "<eof>"))

    raw, ok, seen = [], [], set()
    for k in range(len(spans) - 1):
        start, name = spans[k]
        end = spans[k + 1][0]
        if name not in SAI_ROUTINES:
            continue
        seen.add(name)
        for n, line in enumerate(lines[start:end]):
            if RAW.match(line):
                raw.append((name, start + n + 1, line.strip()))
            elif BIASED.match(line):
                ok.append((name, start + n + 1))

    missing = SAI_ROUTINES - seen
    if missing:
        print("audit_kham_sai_lanes: these labels are no longer in MKZAP.ASM: "
              + ", ".join(sorted(missing)))
        print("  Either they were renamed - update SAI_ROUTINES - or the sai "
              "was restructured, in which case re-derive the bias sites.")
        return 2

    for name, line in ok:
        print(f"  ok   {name}:{line}")
    if not raw:
        print(f"audit_kham_sai_lanes: {len(ok)} sai ani2 site(s), all biased")
        return 0

    print()
    for name, line, text in raw:
        print(f"  *** RAW  {name}:{line}  {text}")
    print()
    print("audit_kham_sai_lanes: a sai animation lookup is NOT going through "
          "kham_sai_ani2.")
    print("  For Khameleon this silently draws fn4_anitab2 index 5/6/7 - the "
          "square wave and the")
    print("  boomerang - instead of the sai.  No crash, no build error, just "
          "the wrong art.")
    print("  Change `calla get_char_ani2` to `callr kham_sai_ani2` at the "
          "site(s) above.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
