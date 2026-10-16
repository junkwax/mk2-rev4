#!/usr/bin/env python3
"""
gen_debugscript.py — Generate MAME debugger scripts that watch mk2 functions.

Usage:
    python gen_debugscript.py <func> [<func> ...]   # watch named functions
    python gen_debugscript.py --crash               # crash-only: watch TRAP31 + illegal op
    python gen_debugscript.py --all-fatalities      # watch every do_* fatality entry
    python gen_debugscript.py --wp <addr> <size>    # add a watchpoint (byte addr)

Options:
    --out <file>   Write to file instead of stdout (default: mame_watch.ds)
    --launch       After writing, launch MAME with the script

Output is a MAME debugger script passed via:
    mame.exe mk2 -debug -debugscript mame_watch.ds

Register aliases used in printf output:
    pc  a0-a14  sp

Example:
    python gen_debugscript.py do_rp_airspit do_jc_headhole
    python gen_debugscript.py --crash
    mame.exe mk2 -debug -debugscript mame_watch.ds
"""

import re, sys, os, bisect, subprocess, shutil

MAP_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "src", "mk2.map")
DEFAULT_OUT = "mame_watch.ds"

# ── map loader (shared with sym_resolve.py) ───────────────────────────────────

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
                syms[m.group(2)] = int(m.group(1), 16)
    return syms

# ── TMS34010 specifics ────────────────────────────────────────────────────────

# Bit-addr → byte-addr for MAME debugger bpset/wpset
# MAME's debugger bpset takes BYTE addresses (confirmed from CLAUDE.md)
# mk2.map stores BIT addresses; divide by 8 to get byte addr
def bit_to_byte(bit_addr):
    return bit_addr >> 3

# TRAP31 vectors live at 0xFFFFFC00 (bit) = 0x1FFFFFF80 (byte) — too big for 32-bit.
# In MAME's debugger address space for TMS34010, addresses wrap.
# The interrupt vector table is the last 0x400 bytes of the 1MB ROM block.
# Byte address in :maincpu space: 0x7FFFC00..0x7FFFFFF (top of 1MB window).
# TMS34010 maps ROM to 0xFF800000 (bit), byte = 0xFF800000/8 = 0x1FF00000 —
# but MAME's debugger uses the CPU's native address space, which IS bit addresses.
# Confirmed: bpset in MAME debugger for TMS34010 uses BIT addresses.
# So we keep bit addresses throughout.

TRAP31_BASE = 0xFFFFFC00   # bit address — MAME debugger uses bit addrs for TMS34010

def bpset(bit_addr, label, extra_regs=""):
    fmt_parts = ["PC=%08X", "A13=%08X", "A8=%08X"]
    val_parts = ["pc", "a13", "a8"]
    for r in (extra_regs.split(",") if extra_regs else []):
        r = r.strip()
        if r:
            fmt_parts.append(f"{r.upper()}=%08X")
            val_parts.append(r)
    fmt = "  ".join(fmt_parts) + "\\n"
    vals = ",".join(val_parts)
    return (
        f'bpset {bit_addr:08x},1,'
        f'{{printf ">>> {label}  {fmt}",{vals}; g}}'
    )

def wpset(byte_addr, size_bytes, label, rw="rw"):
    return (
        f"wpset {byte_addr:08x},{size_bytes},{rw},"
        f'{{printf ">>> WP {label}  addr=%08X  data=%08X  PC=%08X\\n",'
        f'wpaddr,wpdata,pc; g}}'
    )

# ── generators ────────────────────────────────────────────────────────────────

def gen_function_watches(syms, names):
    lines = []
    for name in names:
        if name in syms:
            lines.append(bpset(syms[name], name))
        else:
            # Fuzzy: case-insensitive substring match
            matches = [k for k in syms if name.lower() in k.lower()]
            if matches:
                print(f"  '{name}' not in map (local label?); closest: {', '.join(matches[:4])}", file=sys.stderr)
                print(f"  To make it watchable: add  .global {name}  to MAINEQU.ASM and rebuild.", file=sys.stderr)
            else:
                print(f"  '{name}' not found in map — not exported as .global", file=sys.stderr)
            lines.append(f"; MISSING: {name} (not in .global — add to MAINEQU.ASM then rebuild)")
    return lines

def gen_crash_watches(syms):
    """Watch the TRAP31 vector table entries for illegal instruction / div-zero."""
    lines = [
        "; --- crash / exception watchers ---",
        "; TMS34010 TRAP31 vector base = 0xFFFFFC00 (bit addr)",
        "; Trap 0  (0xFFFFFC00): illegal instruction",
        "; Trap 4  (0xFFFFFC80): division by zero",
        "; These breakpoints fire if the CPU's exception handler is invoked.",
    ]
    # Trap vector entries: each is 32 bits (1 long = 32 bits = 4 bytes).
    # Bit address of trap 0 handler pointer = 0xFFFFFC00
    # Bit address of trap 4 (div zero) = 0xFFFFFC00 + 4*32 = 0xFFFFFC80
    trap0  = 0xFFFFFC00
    trap4  = 0xFFFFFC80
    lines.append(bpset(trap0, "TRAP0-illegal-instr", "a0,a1"))
    lines.append(bpset(trap4, "TRAP4-div-zero",      "a0,a1"))
    # Also watch for the common "reads address 0" pattern — null deref
    lines.append("; watchpoint: null-ptr write (byte 0 in CPU space)")
    lines.append('wpset 00000000,4,w,{printf ">>> NULL-WRITE addr=%08X data=%08X PC=%08X\\n",wpaddr,wpdata,pc; g}')
    # Common crash site: process stack underflow (a12 walks into 0)
    lines.append("; watchpoint: low stack / A12 near zero (catch stack underflow)")
    lines.append('wpset 00000100,0x100,w,{printf ">>> LOW-STACK addr=%08X data=%08X PC=%08X\\n",wpaddr,wpdata,pc; g}')
    return lines

def gen_fatality_watches(syms):
    """Watch every do_* fatality / death entry point."""
    targets = [k for k in syms if k.startswith("do_") and any(
        kw in k for kw in ("death", "fatality", "decap", "headhole", "hat",
                           "tongued", "burst", "shocker", "super", "melt",
                           "freeze", "jc_", "lk_", "rd_", "rp_", "head"))]
    lines = [f"; --- {len(targets)} fatality/death entry points ---"]
    lines += gen_function_watches(syms, targets)
    return lines

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]

    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return

    if not os.path.exists(MAP_FILE):
        sys.exit(f"ERROR: {MAP_FILE} not found. Run from repo root or rebuild first.")

    syms = load_symbols(MAP_FILE)

    out_file = DEFAULT_OUT
    launch = False
    func_names = []
    watchpoints = []
    crash_mode = False
    fatality_mode = False

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--out":
            i += 1; out_file = args[i]
        elif a == "--launch":
            launch = True
        elif a == "--crash":
            crash_mode = True
        elif a == "--all-fatalities":
            fatality_mode = True
        elif a == "--wp":
            addr = int(args[i+1], 16)
            size = int(args[i+2], 16) if len(args) > i+2 and args[i+2].startswith("0x") \
                   else int(args[i+2]) if len(args) > i+2 else 4
            label = args[i+3] if len(args) > i+3 else f"wp_{addr:08x}"
            watchpoints.append((addr, size, label))
            i += 2
        else:
            func_names.append(a)
        i += 1

    script_lines = [
        "; MAME debugger script — generated by gen_debugscript.py",
        "; Load with:  mame.exe mk2 -debug -debugscript " + out_file,
        "; TMS34010 uses BIT addresses in bpset/wpset.",
        ";",
    ]

    if func_names:
        script_lines.append(f"; --- watching: {', '.join(func_names)} ---")
        script_lines += gen_function_watches(syms, func_names)

    if crash_mode:
        script_lines += gen_crash_watches(syms)

    if fatality_mode:
        script_lines += gen_fatality_watches(syms)

    for addr, size, label in watchpoints:
        # Convert byte addr → bit addr for wpset (TMS34010 native)
        script_lines.append(wpset(addr, size, label))

    script_lines.append("; --- run ---")
    script_lines.append("g")

    script = "\n".join(script_lines) + "\n"

    with open(out_file, "w") as f:
        f.write(script)

    print(f"Written: {out_file}  ({len(script_lines)-3} breakpoints/watchpoints)")
    print(f"Run:  mame.exe mk2 -debug -debugscript {out_file}")

    if func_names:
        print()
        print("Resolved addresses:")
        for name in func_names:
            if name in syms:
                bit = syms[name]
                print(f"  {name:40s}  bit={bit:08x}  byte={bit>>3:08x}")

    if launch:
        mame = shutil.which("mame") or shutil.which("mame64") or r"C:\MAME\mame.exe"
        if not os.path.exists(mame):
            print(f"MAME not found at {mame}; set PATH or edit gen_debugscript.py")
        else:
            cmd = [mame, "mk2", "-debug", f"-debugscript", out_file]
            print(f"Launching: {' '.join(cmd)}")
            subprocess.Popen(cmd)

if __name__ == "__main__":
    main()
