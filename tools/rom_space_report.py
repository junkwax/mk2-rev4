#!/usr/bin/env python3
"""Report how much ROM space is actually left, derived from the live build.

There are FOUR separate budgets in this machine and they are not
interchangeable.  Every one of them has been quoted wrong in a doc at some
point, which is the reason this script exists:

  video ROM bank 0   12MB flat image, 0x000000..0x800000  - sprite pixel data
  video ROM bank 1                    0x800000..0xC00000  - sprite pixel data
  program ROM .text/.data             the 1MB uj12/ug12 pair, code + tables
  program ROM REVX                    the CPU-read movie pool inside it

A sprite cannot go in the program ROM (T-Unit PIXBLT cannot source from it) and
code cannot go in the video ROM, so "we have N bytes left" is only ever a
statement about one of these.

Video-ROM figures are computed from the REAL payload sizes in data/*.IRW plus
makevrom.py's slot declarations, not from any written-down number - the art is
edited between builds and every hardcoded figure in doc/ goes stale.  Run
`python build.py` first if the IRWs may be behind the IMGs.

    python tools/rom_space_report.py
    python tools/rom_space_report.py --gaps      # every hole, not just the big ones
"""
import argparse
import importlib.util
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BANK_SPAN = {0: (0x000000, 0x800000), 1: (0x800000, 0xC00000)}
MIN_INTERESTING = 1024          # holes smaller than this are packing slack


def load_makevrom():
    spec = importlib.util.spec_from_file_location("makevrom", ROOT / "makevrom.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["makevrom"] = mod
    spec.loader.exec_module(mod)
    return mod


def video_payloads(mv):
    """[(name, flat_start, flat_end)] for everything actually written to ROM."""
    # makevrom's irw_files list lives inside main(); mirror the same rule it
    # uses - a payload ships if the IRW exists AND is not the staged UMK3FIRE.
    shipped = []
    data_dir = ROOT / "data"
    for name, bank in mv.FILE_BANK.items():
        if name == "UMK3FIRE.IRW":
            continue                      # staged, deliberately not in the ROM
        path = data_dir / name
        if not path.exists():
            continue
        base_addr, hdr_bank, pixels = mv.parse_irw(path)
        off = mv.image_byte_offset(base_addr, bank)
        flat = mv.BANK_OFFSETS[bank] + off
        shipped.append((name, flat, flat + len(pixels), bank))
    return sorted(shipped, key=lambda r: r[1])


def gaps_for_bank(payloads, bank):
    lo, hi = BANK_SPAN[bank]
    spans = [(s, e, n) for n, s, e, b in payloads if b == bank]
    spans.sort()
    out, cursor, prev = [], lo, "start of bank"
    for s, e, n in spans:
        if s > cursor:
            out.append((cursor, s, prev))
        cursor = max(cursor, e)
        prev = n
    if cursor < hi:
        out.append((cursor, hi, prev))
    return out


def program_rom():
    """(.text/.data used, chip capacity, REVX free) straight out of the COFF."""
    out = ROOT / "src" / "mk2.out"
    if not out.exists():
        return None
    spec = importlib.util.spec_from_file_location("makerom", ROOT / "makerom.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["makerom"] = mod
    spec.loader.exec_module(mod)
    sections = mod.read_coff(out)
    return sections, mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gaps", action="store_true",
                    help="list every hole, including sub-1KB packing slack")
    args = ap.parse_args()

    mv = load_makevrom()
    payloads = video_payloads(mv)

    print("=" * 72)
    print("VIDEO ROM - sprite pixel data only.  Code cannot live here.")
    print("=" * 72)
    grand = {}
    for bank in (0, 1):
        holes = gaps_for_bank(payloads, bank)
        shown = [h for h in holes if (h[1] - h[0]) >= (0 if args.gaps else MIN_INTERESTING)]
        total = sum(e - s for s, e, _ in holes)
        grand[bank] = total
        lo, hi = BANK_SPAN[bank]
        print(f"\nbank {bank}  ({lo:#08x}..{hi:#08x}, {hi-lo:,} bytes)")
        print(f"  {'range':<26}{'bytes':>10}   after")
        for s, e, prev in sorted(shown, key=lambda h: h[0] - h[1]):
            print(f"  {s:#08x}..{e:#08x}   {e-s:>8,}   {prev}")
        if len(shown) < len(holes):
            print(f"  (+{len(holes)-len(shown)} holes under {MIN_INTERESTING} bytes, "
                  f"{sum(e-s for s,e,_ in holes if e-s < MIN_INTERESTING):,} bytes of packing slack)")
        print(f"  bank {bank} free: {total:,} bytes")

    biggest = max((e - s, s, e, b)
                  for b in (0, 1) for s, e, _ in gaps_for_bank(payloads, b))
    print(f"\n  TOTAL VIDEO FREE: {grand[0]+grand[1]:,} bytes "
          f"(bank 0 {grand[0]:,} / bank 1 {grand[1]:,})")
    print(f"  LARGEST SINGLE RUN: {biggest[0]:,} bytes at {biggest[1]:#08x} (bank {biggest[3]})")
    print("  NOTE: a movie frame must be bank 0 - movie_run has no bank select.")

    pr = program_rom()
    if pr:
        sections, mk = pr
        print()
        print("=" * 72)
        print("PROGRAM ROM - code and tables.  Sprites cannot live here.")
        print("=" * 72)
        # read_coff already returns BYTES - do not divide by 8 again.
        by_name = {sec["name"]: sec for sec in sections}
        linked = sum(by_name[n]["size"] for n in
                     (".text", ".data", "FLOORORG", "SHADORG", "VECTORS")
                     if n in by_name)
        print(f"  linked code+tables: {linked:,} bytes")

        # The number that actually constrains adding moves is the gap between
        # the end of .data and the base of the REVX movie pool.  .data grows
        # UP into it, and overrunning it silently corrupts every VS portrait
        # (it has happened - see the MK8MIL rebase note in makerom.py).
        data = by_name.get(".data")
        if data and mk.REVX_PAYLOADS:
            data_end = data["vaddr"] + data["size"]
            revx_base = min(addr for addr, _f, _l in mk.REVX_PAYLOADS) // 8
            headroom = revx_base - data_end
            print(f"  .data ends {data_end*8:#010x}, REVX pool starts {revx_base*8:#010x}")
            print(f"  HEADROOM FOR MORE CODE/TABLES: {headroom:,} bytes")
            print("    ^ this is the one that runs out when you add moves.")
        print("  The REVX pool itself holds CPU-read movie frames only - not")
        print("  code and not sprites.  `python makerom.py` prints its free tail.")
    print()
    print("Video figures are computed from data/*.IRW payload sizes, so they are")
    print("only as fresh as the last `python build.py`.")


if __name__ == "__main__":
    main()
