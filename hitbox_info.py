#!/usr/bin/env python3
"""
Print MAME debug commands for hitbox editing workflow (Asure's method).

Reads mk2.map, finds get_char_stk / stk_super_rep / f_colbox addresses,
converts TMS34010 bit addresses to :maincpu byte offsets, prints the
saver/loadr/w@ commands for live hitbox hex editing in MAME.

Usage:
    python hitbox_info.py           # print commands
    python hitbox_info.py --strike  # just print the strike table range
"""
import re
import sys
from pathlib import Path

ROM_BASE_BIT = 0xFF800000


def find_symbol(map_text, name):
    """Find a symbol's bit address in the linker map."""
    m = re.search(rf"([0-9a-f]{{8}})\s+{re.escape(name)}\b", map_text, re.IGNORECASE)
    if not m:
        print(f"Error: {name} not found in mk2.map (add '.def {name}' to its .ASM file and rebuild)")
        sys.exit(1)
    return int(m.group(1), 16)


def main():
    map_path = Path(__file__).parent / "src" / "mk2.map"
    if not map_path.exists():
        print(f"Error: {map_path} not found — run 'python build.py' first")
        sys.exit(1)
    text = map_path.read_text(errors="replace")

    start = find_symbol(text, "get_char_stk")
    end = find_symbol(text, "stk_super_rep")
    colbox = find_symbol(text, "f_colbox")

    byte_start = (start - ROM_BASE_BIT) // 8
    byte_end = (end - ROM_BASE_BIT) // 8
    byte_len = byte_end - byte_start
    colbox_byte = colbox // 8

    if "--strike" in sys.argv:
        print(f"0x{byte_start:x} 0x{byte_len:x}")
        return

    print("=" * 66)
    print(" MK2 Hitbox Live-Edit Workflow (Asure's method)")
    print("=" * 66)
    print()
    print("Strike tables section in program ROM:")
    print(f"  get_char_stk  (start) = bit 0x{start:08x} = :maincpu byte 0x{byte_start:x}")
    print(f"  stk_super_rep (end)   = bit 0x{end:08x} = :maincpu byte 0x{byte_end:x}")
    print(f"  length                = 0x{byte_len:x} bytes ({byte_len:,d} bytes)")
    print()
    print(f"Collision-box visualisation flag:")
    print(f"  f_colbox (RAM) = bit 0x{colbox:08x} = byte 0x{colbox_byte:x}")
    print()
    print("-" * 66)
    print(" MAME Debug Commands (press ~ in running MAME to open debugger)")
    print("-" * 66)
    print()
    print("1. Save current strike tables to hex-edit:")
    print(f"   saver stk.bin,0x{byte_start:x},0x{byte_len:x},:maincpu")
    print()
    print("2. Enable green collision box overlay:")
    print(f"   w@0x{colbox_byte:x}=1")
    print()
    print("3. Hex-edit stk.bin. Each move is 8 words (16 bytes):")
    print("   +00 (w): x offset of collision box")
    print("   +02 (w): y offset")
    print("   +04 (w): x size")
    print("   +06 (w): y size")
    print("   +08 (w): strike routine / flags")
    print("   +0a (w): damage (hi byte + lo byte)")
    print("   +0c (l): score value (long)")
    print("   +10 (w): sound flag")
    print()
    print("4. Load edited data back (changes are immediate, no rebuild):")
    print(f"   loadr stk.bin,0x{byte_start:x},0x{byte_len:x},:maincpu")
    print()
    print("To make changes permanent, mirror them into src/MKSTK.ASM and rebuild.")


if __name__ == "__main__":
    main()
