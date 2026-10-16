#!/usr/bin/env python3
"""
ab_build.py - flip the source between the BEFORE and AFTER of the 2026-08-26
collision work, so the two can be measured and photographed side by side.

Three edits, and nothing else, so a diff of the two builds is a diff of these:

  1. src/MKSA.ASM   a_swipe    - which frame is HELD during the strike window
  2. src/MOVES.ASM  do_swipe   - how the 14 post-strike ticks are split
  3. src/MAINEQU.ASM anchorcol - hit column on the anipoint, or on the bbox

LINE ENDINGS ARE MIXED IN THIS TREE. MOVES.ASM is CRLF and MKSA.ASM is LF, so
anchors are matched as lines joined by `\\r?\\n` and rewritten with whatever
ending the file already uses. A byte-literal anchor silently matched nothing
and reported "unknown", which is how this was found.

Edits are verified both ways and the script refuses rather than half-applying:
a build that is neither state is worse than either.

  python tools/ab_build.py before     # revert to retail behaviour
  python tools/ab_build.py after      # our current behaviour
  python tools/ab_build.py status
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (path, before-lines, after-lines, label)
EDITS = [
    (
        "src/MKSA.ASM",
        ["\t.long\tani_nosleep", "\t.long\tUGSWIPE4", "\t.long\t0",
         "\t.long\tUGHIPUNCH1", "\t.long\t0"],
        ["\t.long\tani_nosleep", "\t.long\tUGSWIPE3", "\t.long\t0",
         "\t.long\tUGSWIPE4", "\t.long\tUGHIPUNCH1", "\t.long\t0"],
        "a_swipe held frame",
    ),
    (
        "src/MOVES.ASM",
        ["\tsleep\t10", "", "\tmovk\t4,a0", "\tjsrp\tretract_strike"],
        ["\tsleep\t4", "", "\tmovk\t5,a0", "\tjsrp\tretract_strike"],
        "do_swipe post-strike split",
    ),
    (
        "src/MAINEQU.ASM",
        ["anchorcol\t.set\t0"],
        ["anchorcol\t.set\t1"],
        "anchorcol hit column",
    ),
]


def pattern(lines):
    return re.compile(r"\r?\n".join(re.escape(l) for l in lines))


def render(lines, eol):
    return eol.join(lines)


def eol_of(text):
    return "\r\n" if "\r\n" in text else "\n"


def load(path):
    # newline="" is load-bearing: without it Python translates CRLF to LF on
    # read, and writing back with newline="" then rewrites the WHOLE FILE as
    # LF.  Every file here is CRLF, so the first version of this script turned
    # a three-line edit into a 2481-line diff.
    return open(os.path.join(ROOT, path), encoding="latin-1", newline="").read()


def state_of(text, before, after):
    nb = len(pattern(before).findall(text))
    na = len(pattern(after).findall(text))
    if nb == 1 and na == 0:
        return "before"
    if na == 1 and nb == 0:
        return "after"
    if na and nb:
        return "ambiguous"
    return "unknown"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "status"
    if mode not in ("before", "after", "status"):
        sys.exit(__doc__)

    texts = {p: load(p) for p, _, _, _ in EDITS}
    states = [(p, state_of(texts[p], b, a), lbl) for p, b, a, lbl in EDITS]

    if mode == "status":
        for p, st, lbl in states:
            print("%-18s %-10s %s" % (p, st, lbl))
        distinct = {st for _, st, _ in states}
        print("\noverall:", distinct.pop() if len(distinct) == 1 else "MIXED")
        return

    bad = [(p, st) for p, st, _ in states if st in ("unknown", "ambiguous")]
    if bad:
        for p, st in bad:
            print("REFUSING: %s is %s - the anchor text does not match" % (p, st))
        sys.exit(1)

    changed = 0
    for (path, before, after, lbl), (_, st, _) in zip(EDITS, states):
        if st == mode:
            continue
        text = texts[path]
        eol = eol_of(text)
        src, dst = (after, before) if mode == "before" else (before, after)
        new, n = pattern(src).subn(render(dst, eol).replace("\\", "\\\\"), text, 1)
        assert n == 1, "%s: expected exactly one match" % path
        with open(os.path.join(ROOT, path), "w", encoding="latin-1",
                  newline="") as fh:
            fh.write(new)
        print("%-18s -> %-8s (%s)" % (path, mode, lbl))
        changed += 1
    print("%d file(s) changed; now in %s state" % (changed, mode))
    print("rebuild:  python build.py --asm-only && python makerom.py "
          "&& python mamerom.py --source-video")


if __name__ == "__main__":
    main()
