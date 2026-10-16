#!/usr/bin/env python3
"""The system stack must not share RAM with .bss.

`stckst` (SYSEQU.ASM) is the top of the TMS34010 system stack, which grows
DOWN, and `movi stckst,sp` (MKINIT/DIAGDTST) plants it at a fixed address.
The linker knows nothing about that: it packs every module's .bss upward from
the end of the SCRATCH group, in link order.  Once .bss grows past the stack
top, whichever module's variables land just below `stckst` share their RAM
with the live stack - every call and push anywhere in the game writes over
them, and every write to them corrupts a stacked return address.

That is exactly what happened on 2026-09-12.  .bss had reached 0111A230 while
the stack top was still the leak's 010FFFF0, so MKHANG.OBJ's .bss straddled
it.  A write tap on Ed's multipart piece list caught ~40,000 writes a run from
core engine code, and the acid drop drew his body as a solid magenta block
every ~20 ticks.  Nothing failed to build.  This check is what fails now.
(The same day's intermittent Dead Pool TRAP 30 was a different bug - a
wrapped cross-object callr, guarded by tools/check_pcrel_range.py.)

    python tools/check_stack_clearance.py           # report
    python tools/check_stack_clearance.py --check   # Phase D: exit 1 on overlap

Reads the LINKED src/mk2.map, so it describes the last link.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Stack depth no .bss may occupy below stckst, in BITS (map units).  The deepest
# call chains here are a few hundred bytes; 8KB is a margin, not a measurement.
RESERVE_BITS = 0x10000

SCRATCH_ORG, SCRATCH_LEN = 0x01000000, 0x3F7300   # src/mk2.cmd MEMORY


def main():
    check = "--check" in sys.argv
    equ = (ROOT / "src" / "SYSEQU.ASM").read_text(encoding="latin-1")
    m = re.search(r"^stckst\s+\.set\s+0?([0-9a-fA-F]+)h", equ, re.M)
    if not m:
        print("check_stack_clearance: stckst not found in SYSEQU.ASM")
        return 1
    stckst = int(m.group(1), 16)

    mapf = ROOT / "src" / "mk2.map"
    text = mapf.read_text(encoding="latin-1")
    mods = [(int(a, 16), int(n, 16), name)
            for a, n, name in re.findall(
                r"^\s+([0-9a-f]{8})\s+([0-9a-f]{8})\s+(\S+)\s+\(\.bss\)", text, re.M)]
    if not mods:
        print("check_stack_clearance: no (.bss) lines in %s" % mapf)
        return 1
    bss_lo = min(a for a, n, _ in mods)
    bss_hi = max(a + n for a, n, _ in mods)

    zone_lo, zone_hi = stckst - RESERVE_BITS, stckst
    clash = [(a, n, name) for a, n, name in mods if a < zone_hi and a + n > zone_lo]
    problems = []
    for a, n, name in clash:
        problems.append("%s .bss %08x..%08x lies in the stack zone %08x..%08x"
                        % (name, a, a + n, zone_lo, zone_hi))
    if stckst > SCRATCH_ORG + SCRATCH_LEN:
        problems.append("stckst %08x is past the end of SCRATCH %08x"
                        % (stckst, SCRATCH_ORG + SCRATCH_LEN))

    # The power-up clear must reach the top of .bss.  clscrach (MKINIT.ASM) used
    # to clear a fixed 08000h longs - 01000000..01100000 - and .bss outgrew it:
    # 38 variables started as garbage on a real board, invisibly in MAME.  It
    # now clears through the linker's `end`; if it ever goes back to a fixed
    # count, that count has to cover .bss.
    init = (ROOT / "src" / "MKINIT.ASM").read_text(encoding="latin-1")
    body = re.search(r"^clscrach\b(.*?)^\s+jump\s+a3", init, re.M | re.S)
    if not body:
        problems.append("clscrach not found in MKINIT.ASM")
    elif re.search(r"^\s+movi\s+end\s*,", body.group(1), re.M):
        # clears through the linker's `end` - which must itself cover .bss
        e = re.search(r"([0-9a-f]{8})\s+end\s*$", text, re.M)
        if not e:
            problems.append("clscrach clears through `end` but the map has no `end` symbol")
        elif int(e.group(1), 16) < bss_hi:
            problems.append("clscrach clears through `end` (%08x) but .bss ends at %08x"
                            % (int(e.group(1), 16), bss_hi))
    else:
        cnt = re.search(r"^\s+movi\s+0?([0-9a-fA-F]+)h\s*,\s*a2", body.group(1), re.M)
        cleared_hi = SCRATCH_ORG + int(cnt.group(1), 16) * 32 if cnt else SCRATCH_ORG
        if cleared_hi < bss_hi:
            problems.append("clscrach clears only %08x..%08x but .bss ends at %08x - everything "
                            "above starts as garbage on a real board (MAME zero-fills, so no run "
                            "shows it); clear through `end`" % (SCRATCH_ORG, cleared_hi, bss_hi))

    print("stack top %08x, .bss %08x..%08x, headroom below the stack zone %d bytes"
          % (stckst, bss_lo, bss_hi, max(0, zone_lo - bss_hi) // 8))
    if problems:
        print("check_stack_clearance FAILED:")
        for p in problems:
            print("  " + p)
        if clash:
            print("  Raise stckst (SYSEQU.ASM) above the end of .bss; see this file's docstring.")
        return 1 if check else 0
    print("check_stack_clearance OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
