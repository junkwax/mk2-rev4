#!/usr/bin/env python3
"""Every display-list head a stage's dlists table names must be one that
grab_screen zeroes.

grab_screen (MKUTIL.ASM - GAME OVER, the barge-in and buy-in freezes, the
high-score screens) zeroes the list heads from baklst8 up to last_objlst
(RAM.ASM), rebuilds the object free list, and leaves @dlists alone, so the
display keeps walking the stage's own table over the frozen picture.  A head
declared anywhere else survives pointing at a freed object, and the walk runs
down the whole free pool: every stale block is drawn where it last was.

It has happened twice.  THE TOWER's private lists drew ~300 freed objects a
frame on its game-over screen.  On 2026-10-10 PALACE GATES (Wolf) did it with
its clouds and torches - a round that timed out with both bars full goes
straight to GAME OVER, and the screen filled with old banners and attract
story text; in MAME the machine never left game over.  Nothing fails to
build, and it needs that one path on that one stage to show.

    python tools/check_dlist_heads.py           # report
    python tools/check_dlist_heads.py --check   # Phase D: exit 1 on a stray head

Source-only: a head is any NAME in a `.long NAME,worldtl...+16` pair (the
form every dlists row has), in any src/*.ASM, whatever .if it sits under.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"

# Heads that are safe outside the block, each for a stated reason.
EXEMPT = {
    # MKDISP.ASM: links slots of its own .bss ring, never pool objects, and
    # ghost_render rewrites the head every frame.
    "ghost_lst": "own .bss ring, no pool objects",
}

PAIR = re.compile(r"([A-Za-z_]\w*)\s*,\s*worldtl\w*\s*\+\s*16")
BSS = re.compile(r"^\s*\.bss\s+([A-Za-z_]\w*)\s*,")


def zeroed_block():
    """Names .bss'd in RAM.ASM from baklst8 up to (not including) last_objlst."""
    names, inside = set(), False
    for line in (SRC / "RAM.ASM").read_text(encoding="latin-1").splitlines():
        m = BSS.match(line)
        if not m:
            continue
        if m.group(1) == "baklst8":
            inside = True
        if m.group(1) == "last_objlst":
            if not inside:
                sys.exit("check_dlist_heads: last_objlst before baklst8 in RAM.ASM")
            return names
        if inside:
            names.add(m.group(1))
    sys.exit("check_dlist_heads: baklst8..last_objlst block not found in RAM.ASM")


def heads():
    found = {}
    for path in sorted(SRC.glob("*.ASM")):
        for n, line in enumerate(path.read_text(encoding="latin-1").splitlines(), 1):
            code = line.split(";", 1)[0]
            if code.lstrip().startswith("*") or ".long" not in code:
                continue
            for name in PAIR.findall(code):
                found.setdefault(name, (path.name, n))
    return found


def main():
    check = "--check" in sys.argv
    block = zeroed_block()
    found = heads()
    if len(found) < 12 or "objlst" not in found or "baklst1" not in found:
        sys.exit("check_dlist_heads: found %d heads and not the stock ones - "
                 "the dlists row form changed, fix the parser" % len(found))
    stray = {n: w for n, w in found.items() if n not in block and n not in EXEMPT}
    print("  dlist heads: %d named, %d in RAM.ASM's baklst8..last_objlst block, "
          "%d exempt" % (len(found), sum(n in block for n in found),
                         sum(n in EXEMPT for n in found)))
    for name, (f, n) in sorted(stray.items()):
        print("  STRAY %s (first named at %s:%d) - grab_screen will not zero it. "
              "Declare it in RAM.ASM before last_objlst." % (name, f, n))
    if stray and check:
        sys.exit(1)
    if not stray:
        print("  every head is one grab_screen zeroes")


if __name__ == "__main__":
    main()
