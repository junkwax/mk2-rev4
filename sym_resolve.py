#!/usr/bin/env python3
"""
sym_resolve.py — Resolve TMS34010 addresses to mk2 source symbols.

Usage:
    python sym_resolve.py <addr> [<addr> ...]   # resolve one or more addresses
    python sym_resolve.py --stack <w0> [<w1>...]# walk a stack dump
    python sym_resolve.py --dump                # list all symbols

Addresses are TMS34010 BIT-addresses as shown in the MAME debugger (PC,
registers, wpset/bpset).  If you have a BYTE offset (from saver/loadr/w@),
prefix it with 'b:' e.g.  b:19802

Map file:  src/mk2.map  (relative to this script, or set MAP_FILE env var)
"""

import re, sys, os, bisect

MAP_FILE = os.environ.get(
    "MAP_FILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "src", "mk2.map"),
)

# ── parser ────────────────────────────────────────────────────────────────────

def load_symbols(path):
    syms = {}
    in_global = False
    with open(path) as f:
        for line in f:
            if "GLOBAL SYMBOLS" in line:
                in_global = True
                continue
            if not in_global:
                continue
            for m in re.finditer(r'([0-9a-fA-F]{8})\s+([A-Za-z_]\S*)', line):
                addr, name = int(m.group(1), 16), m.group(2)
                syms[name] = addr
    return syms

def build_index(syms):
    pairs = sorted((a, n) for n, a in syms.items())
    addrs = [a for a, _ in pairs]
    return pairs, addrs

# ── address normalisation ─────────────────────────────────────────────────────

ROM_BIT_BASE  = 0xff800000          # ROM starts at bit addr ff800000
ROM_BYTE_BASE = ROM_BIT_BASE >> 3   # = 0x1ff00000  (byte addr of ROM start)

def parse_addr(tok):
    """
    Accept:
      ff8012a0          plain hex (bit addr — MAME registers / wpset)
      0xff8012a0        with 0x prefix
      b:19802           byte offset into :maincpu block (saver/loadr range)
      b:0x19802         same with prefix
    Returns (bit_addr, label) where label annotates the display.
    """
    tok = tok.strip()
    if tok.lower().startswith("b:"):
        byte_val = int(tok[2:], 16)
        # :maincpu byte offsets map to bit addrs: bit = (base + byte) * 8
        bit = (ROM_BIT_BASE >> 3 + byte_val) * 8  # wrong — let's be explicit
        # saver byte offset is relative to the 1MB ROM block whose first byte
        # is ROM_BIT_BASE/8.  bit_addr = (ROM_BIT_BASE/8 + byte_offset) * 8
        bit = ROM_BIT_BASE + byte_val * 8
        return bit, f"b:{byte_val:#x}"
    else:
        bit = int(tok, 16)
        # Heuristic: if value fits in 20 bits it looks like a raw byte offset
        # into the ROM block (saver/loadr style) rather than a full bit addr.
        # Surface this as a warning but don't auto-convert — caller should use b:.
        return bit, f"{bit:08x}"

# ── resolver ──────────────────────────────────────────────────────────────────

def resolve(pairs, addrs, bit_addr):
    """Return (sym_name, sym_bit_addr, offset_bits) or None."""
    i = bisect.bisect_right(addrs, bit_addr) - 1
    if i < 0:
        return None
    sym_addr, sym_name = pairs[i]
    offset_bits = bit_addr - sym_addr
    next_entry = pairs[i + 1] if i + 1 < len(pairs) else None
    return sym_name, sym_addr, offset_bits, next_entry

def fmt_result(bit_addr, label, pairs, addrs):
    r = resolve(pairs, addrs, bit_addr)
    if r is None:
        return f"  {label}  ->  (below all known symbols)"
    sym_name, sym_addr, off_bits, nxt = r
    off_bytes = off_bits >> 3
    size_str = ""
    if nxt:
        fn_size_bytes = (nxt[0] - sym_addr) >> 3
        size_str = f"  [{fn_size_bytes}B fn]"
    lines = [
        f"  {label}  ->  {sym_name} + {off_bytes:#x}B  ({off_bits:#x} bits){size_str}",
        f"             sym={sym_addr:08x}  query={bit_addr:08x}",
    ]
    if nxt:
        lines.append(f"             next: {nxt[1]} @ {nxt[0]:08x}")
    return "\n".join(lines)

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]

    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return

    if not os.path.exists(MAP_FILE):
        sys.exit(f"ERROR: map file not found: {MAP_FILE}\nRun from repo root or set MAP_FILE.")

    syms = load_symbols(MAP_FILE)
    pairs, addrs = build_index(syms)

    if args[0] == "--dump":
        for a, n in pairs:
            print(f"  {a:08x}  {n}")
        return

    if args[0] == "--stack":
        words = args[1:]
        print(f"Stack walk ({len(words)} words):")
        for i, tok in enumerate(words):
            try:
                bit_addr, label = parse_addr(tok)
            except ValueError:
                print(f"  [{i:2d}]  {tok}  ->  (parse error)")
                continue
            r = resolve(pairs, addrs, bit_addr)
            if r:
                sym_name, sym_addr, off_bits, _ = r
                print(f"  [{i:2d}]  {label}  ->  {sym_name} + {off_bits >> 3:#x}B")
            else:
                print(f"  [{i:2d}]  {label}  ->  (unknown)")
        return

    # Default: resolve each address argument
    for tok in args:
        try:
            bit_addr, label = parse_addr(tok)
        except ValueError:
            print(f"  {tok}  ->  (parse error — expected hex)")
            continue
        print(fmt_result(bit_addr, label, pairs, addrs))

if __name__ == "__main__":
    main()
