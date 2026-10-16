#!/usr/bin/env python3
"""
MK2 frame-data editor for move timings in src/MOVES.ASM.

MK2 move routines (do_hi_kick, do_roundhouse, etc.) are generic across all
characters. Frame timing is encoded as immediate values in TMS34010 instructions:
    movk  N,a0       ; ticks per frame (startup/recovery)
    movk  N,a10      ; number of active frames
    movi  Nh,a9      ; anim index (don't change unless remapping)
    movi  Nh,a11     ; strike table index
    sleep N          ; hit pause / stun
Some moves use per-character speed tables (e.g., round_speeds) referenced via
`movi <table>,a0 / calla get_char_word`.

Commands:
    python frame_edit.py list                    # all 58 do_* routines
    python frame_edit.py show do_hi_kick         # source block + flagged immediates
    python frame_edit.py tables do_roundhouse    # per-character speed tables
    python frame_edit.py set <line>=<new>        # patch MOVES.ASM:line (backup auto)

After editing: python build.py + makerom.py + mamerom.py to bake.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).parent.resolve()
# Move routines live in several .ASM files — scan them all.
ASM_FILES = [
    REPO / "src" / "MOVES.ASM",
    REPO / "src" / "MKPROP.ASM",    # do_jc_shoruken real body, do_shadow_kick, etc.
    REPO / "src" / "MKZAP.ASM",     # projectiles
    REPO / "src" / "MKSLAM.ASM",    # throws
]
ASM_FILES = [p for p in ASM_FILES if p.exists()]

IMMED_REGS_TIMING = {"a0", "a10"}   # registers carrying timing values into striker calls
IMMED_REGS_INDEX = {"a9", "a11"}    # anim/strike indexes — edit with care

# Instruction patterns we care about
RE_LABEL = re.compile(r"^([A-Za-z_][\w]*)\s*(?:;.*)?$")
RE_DOLABEL = re.compile(r"^(do_[a-z_]\w*)\s*(?:;.*)?$")
_PREFIX = r"^(?:[a-z_]\w*)?\s+"  # optional label in col-0, then whitespace
RE_MOVK = re.compile(_PREFIX + r"movk\s+([^,]+),\s*(a\w+)\s*(?:;(.*))?$", re.IGNORECASE)
RE_MOVI = re.compile(_PREFIX + r"movi\s+([^,]+),\s*(a\w+)\s*(?:;(.*))?$", re.IGNORECASE)
RE_SLEEP = re.compile(_PREFIX + r"sleep\s+([^\s;]+)\s*(?:;(.*))?$", re.IGNORECASE)
RE_TABLE_REF = re.compile(_PREFIX + r"movi\s+([a-z_]\w*),\s*a0\b", re.IGNORECASE)
RE_DOLABEL = re.compile(r"^(do_[a-z_]\w*)\s*(?:;.*)?$")


def parse_literal(s):
    """Parse a GSPA numeric literal. Return int or None if symbolic."""
    s = s.strip().rstrip(",").strip()
    sign = 1
    if s.startswith("-"):
        sign = -1
        s = s[1:]
    m = re.fullmatch(r"0([0-9a-fA-F]*)h", s)
    if m:
        return sign * int(m.group(1) or "0", 16)
    if s.lower().startswith("0x"):
        return sign * int(s, 16)
    if re.fullmatch(r"\d+", s):
        return sign * int(s)
    return None


def load_all_asm():
    """Return {path: [lines]} for every scanned ASM file."""
    return {p: p.read_text(errors="replace").splitlines() for p in ASM_FILES}


def find_routines(files):
    """Return ordered list of (routine_name, path, start_line, end_line_exclusive)."""
    routines = []
    for path, lines in files.items():
        starts = []
        for i, line in enumerate(lines, start=1):
            m = RE_DOLABEL.match(line.rstrip())
            if m:
                starts.append((m.group(1), i))
        ends = [s[1] for s in starts[1:]] + [len(lines) + 1]
        for (name, start), end in zip(starts, ends):
            routines.append((name, path, start, end))
    return routines


def find_routine(routines, name):
    for rec in routines:
        if rec[0] == name:
            return rec
    return None


def classify_line(line):
    """Return a dict describing any timing-relevant immediate on this line, else None."""
    # movk N,reg
    m = RE_MOVK.match(line)
    if m:
        val = parse_literal(m.group(1))
        reg = m.group(2).lower()
        if val is not None:
            return {"kind": "movk", "value": val, "reg": reg, "raw": m.group(1).strip()}
    # movi N,reg (only if N is a number, not a label)
    m = RE_MOVI.match(line)
    if m:
        val = parse_literal(m.group(1))
        reg = m.group(2).lower()
        if val is not None:
            return {"kind": "movi", "value": val, "reg": reg, "raw": m.group(1).strip()}
        else:
            return {"kind": "movi_ref", "label": m.group(1).strip(), "reg": reg}
    # sleep N
    m = RE_SLEEP.match(line)
    if m:
        val = parse_literal(m.group(1))
        if val is not None:
            return {"kind": "sleep", "value": val, "raw": m.group(1).strip()}
    return None


def extract_timing(lines, start, end):
    """Walk a routine body, return list of (line_no, annotation_dict, raw_line)."""
    hits = []
    for i in range(start, end):
        line = lines[i - 1]
        info = classify_line(line)
        if info:
            hits.append((i, info, line.rstrip()))
    return hits


def filename_short(path):
    return Path(path).name


def fmt_ann(info):
    if info["kind"] == "movk":
        reg = info["reg"]
        hint = ""
        if reg == "a0":
            hint = " [ticks/frame]"
        elif reg == "a10":
            hint = " [# frames]"
        elif reg == "a9":
            hint = " [anim idx]"
        elif reg == "a11":
            hint = " [strike idx]"
        return f"movk {info['value']} -> {reg}{hint}"
    if info["kind"] == "movi":
        reg = info["reg"]
        return f"movi {info['value']} (0x{info['value']:x}) -> {reg}"
    if info["kind"] == "movi_ref":
        return f"movi {info['label']} -> {info['reg']} [per-char table?]"
    if info["kind"] == "sleep":
        return f"sleep {info['value']} (0x{info['value']:x}) [pause ticks]"
    return ""


def cmd_list(args, routines, files):
    print(f"{'Routine':26s} {'File':14s} {'Lines':>11s}   Key timings")
    print("-" * 100)
    for name, path, start, end in routines:
        lines = files[path]
        hits = extract_timing(lines, start, end)
        summary_parts = []
        for _, info, _ in hits:
            if info["kind"] == "movk" and info["reg"] in IMMED_REGS_TIMING:
                summary_parts.append(f"{info['reg'][-2:]}={info['value']}")
            elif info["kind"] == "sleep":
                summary_parts.append(f"slp={info['value']}")
            if len(summary_parts) >= 5:
                break
        summary = " ".join(summary_parts) or "(no standard timings)"
        print(f"{name:26s} {filename_short(path):14s} {start:5d}-{end - 1:<5d}   {summary}")


def cmd_show(args, routines, files):
    target = args.routine
    matches = [r for r in routines if r[0] == target]
    if not matches:
        sys.exit(f"Error: routine '{target}' not found. Try: python frame_edit.py list")
    if len(matches) > 1:
        print(f"Note: {len(matches)} definitions of '{target}' found — showing all.\n")

    for name, path, start, end in matches:
        lines = files[path]
        print(f"{name} ({filename_short(path)}:{start}..{end - 1})")
        print("=" * 90)
        for i in range(start, end):
            line = lines[i - 1].rstrip()
            info = classify_line(line)
            ann = f"  <- {fmt_ann(info)}" if info else ""
            print(f"  {i:5d}: {line}{ann}")
        print()


def cmd_tables(args, routines, files):
    """Show any per-character speed tables referenced by a routine."""
    target = args.routine
    matches = [r for r in routines if r[0] == target]
    if not matches:
        sys.exit(f"Error: routine '{target}' not found")

    for name, path, start, end in matches:
        lines = files[path]
        refs = set()
        for i in range(start, end):
            m = RE_TABLE_REF.match(lines[i - 1])
            if m:
                refs.add(m.group(1))
        if not refs:
            continue
        for table in refs:
            # Find table def in the same file
            table_start = None
            for i, line in enumerate(lines, start=1):
                if re.match(rf"^{re.escape(table)}\s*$", line):
                    table_start = i
                    break
            if table_start is None:
                continue
            print(f"\n{table} ({filename_short(path)}:{table_start})")
            print("-" * 70)
            for i in range(table_start, min(table_start + 20, len(lines))):
                line = lines[i - 1].rstrip()
                if line and not line.startswith((" ", "\t", ";", "*")) and i > table_start:
                    break
                print(f"  {i:5d}: {line}")


def cmd_set(args):
    """Edit a specific line's numeric immediate.
    Format: '<FILENAME>:<line>=<new>' or just '<line>=<new>' (defaults to MOVES.ASM)."""
    spec = args.spec
    if "=" not in spec:
        sys.exit("Usage: python frame_edit.py set [<FILENAME>:]<line>=<new_value>")
    loc, new_val_str = spec.split("=", 1)

    # Determine target file
    target_path = ASM_FILES[0]  # MOVES.ASM default
    if ":" in loc:
        fname, loc = loc.split(":", 1)
        fname = fname.strip()
        matches = [p for p in ASM_FILES if p.name.lower() == fname.lower()]
        if not matches:
            sys.exit(f"Error: file '{fname}' not in scan set. Known: "
                     + ", ".join(p.name for p in ASM_FILES))
        target_path = matches[0]

    try:
        line_no = int(loc)
    except ValueError:
        sys.exit(f"Error: invalid line number '{loc}'")

    new_val = parse_literal(new_val_str.strip())
    if new_val is None:
        sys.exit(f"Error: can't parse new value '{new_val_str}'")

    lines = target_path.read_text(errors="replace").splitlines()
    if line_no < 1 or line_no > len(lines):
        sys.exit(f"Error: {target_path.name} line {line_no} out of range")

    old_line = lines[line_no - 1]
    info = classify_line(old_line)
    if not info or info["kind"] not in ("movk", "movi", "sleep"):
        sys.exit(f"Error: {target_path.name}:{line_no} has no editable numeric immediate:\n  {old_line}")
    if info["kind"] == "movi_ref":
        sys.exit(f"Error: {target_path.name}:{line_no} is a label reference, not a number")

    raw = info["raw"]
    # Preserve the original literal's width — if it was 32-bit (e.g. 000040012h),
    # format the new value with the same number of hex digits. Default to 16-bit.
    hex_digits = 4  # 16-bit default
    m_orig_hex = re.fullmatch(r"0?([0-9a-fA-F]*)h", raw)
    if m_orig_hex:
        hex_digits = max(4, len(m_orig_hex.group(1)))
    if re.fullmatch(r"0?[0-9a-fA-F]*h", raw):
        mask = (1 << (hex_digits * 4)) - 1
        new_lit = f"0{new_val & mask:0{hex_digits}x}h"
    elif raw.lower().startswith("0x"):
        new_lit = f"0x{new_val & 0xFFFFFFFF:x}"
    else:
        new_lit = str(new_val)

    new_line = re.sub(
        rf"(?P<pre>(?:movk|movi|sleep)\s+){re.escape(raw)}",
        lambda m: f"{m.group('pre')}{new_lit}",
        old_line, count=1, flags=re.IGNORECASE)
    if new_line == old_line:
        sys.exit(f"Error: couldn't substitute in {target_path.name}:{line_no}:\n  {old_line}")

    backup = target_path.with_suffix(target_path.suffix + ".frame.bak")
    if not backup.exists():
        shutil.copy2(target_path, backup)
        print(f"Backup: {backup.name}")

    lines[line_no - 1] = new_line
    target_path.write_text("\n".join(lines) + ("\n" if lines and not lines[-1].endswith("\n") else ""))

    print(f"\n{target_path.name}:{line_no}")
    print(f"  - {old_line.rstrip()}")
    print(f"  + {new_line.rstrip()}")
    print(f"\nRebuild: python build.py && python makerom.py && python mamerom.py 'c:\\Users\\you\\Downloads\\mk2.zip' --source-video")


def cmd_restore():
    any_restored = False
    for asm in ASM_FILES:
        bak = asm.with_suffix(asm.suffix + ".frame.bak")
        if bak.exists():
            shutil.copy2(bak, asm)
            bak.unlink()
            print(f"Restored {asm.name} from {bak.name}")
            any_restored = True
    if not any_restored:
        print("(no .frame.bak backups to restore)")


def main():
    parser = argparse.ArgumentParser(description="MK2 frame-data editor (move timings)")
    sp = parser.add_subparsers(dest="cmd", required=True)

    sp.add_parser("list", help="list all do_* move routines with timing summary")

    p = sp.add_parser("show", help="show one routine's source with annotated immediates")
    p.add_argument("routine", help="routine name (e.g. do_hi_kick)")

    p = sp.add_parser("tables", help="show per-character speed tables used by a routine")
    p.add_argument("routine", help="routine name")

    p = sp.add_parser("set", help="edit a specific line's numeric immediate")
    p.add_argument("spec", help="[<FILENAME>:]<line>=<value>  (e.g. MKPROP.ASM:814=4)")

    sp.add_parser("restore", help="restore all ASM files from their .frame.bak backups")

    args = parser.parse_args()
    files = load_all_asm()
    routines = find_routines(files)

    if args.cmd == "list":
        cmd_list(args, routines, files)
    elif args.cmd == "show":
        cmd_show(args, routines, files)
    elif args.cmd == "tables":
        cmd_tables(args, routines, files)
    elif args.cmd == "set":
        cmd_set(args)
    elif args.cmd == "restore":
        cmd_restore()


if __name__ == "__main__":
    main()
