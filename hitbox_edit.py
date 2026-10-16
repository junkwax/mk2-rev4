#!/usr/bin/env python3
"""
MK2 hitbox/strike table editor.

Parses src/MKSTK.ASM and src/MKSTK.LST to map move names to byte offsets.
Edits stk.bin (MAME saver output) by move name instead of hex offset.
Can also sync changes back to MKSTK.ASM for a permanent rebuild.

Quick start:
    # 1. In MAME debug: saver stk.bin,0x19802,0x11d0,:maincpu
    # 2. Copy stk.bin from MAME folder to this repo root
    python hitbox_edit.py list lk                     # list Liu Kang moves
    python hitbox_edit.py show stk_lkhikick           # show one move
    python hitbox_edit.py set stk_lkhikick x_offset=180
    python hitbox_edit.py patch                       # writes patched stk.bin
    python hitbox_edit.py loadr                       # prints MAME loadr cmd
    # In MAME debug, paste the loadr command to hot-reload the patched tables.
    python hitbox_edit.py sync-asm                    # bake edits into MKSTK.ASM
"""
import argparse
import json
import re
import shutil
import struct
import sys
from pathlib import Path

REPO = Path(__file__).parent.resolve()
ASM_PATH = REPO / "src" / "MKSTK.ASM"
LST_PATH = REPO / "src" / "MKSTK.LST"
MAP_PATH = REPO / "src" / "mk2.map"
STATE_PATH = REPO / "hitbox_edits.json"
STK_BIN = REPO / "stk.bin"

FIELD_ORDER = ["x_offset", "y_offset", "x_size", "y_size",
               "strike_routine", "damage", "score", "sound"]
# sizes per field (in bits from the .asm: w=16, l=32)
FIELD_BITS = {
    "x_offset": 16, "y_offset": 16, "x_size": 16, "y_size": 16,
    "strike_routine": 16, "damage": 16, "score": 32, "sound": 16,
}
# Virtual fields split the damage word into hit (high byte) and block (low byte)
# per JOY.ASM:1435-1436 (sll 16 / srl 24 = extract hi byte for hit damage)
# and  JOY.ASM:1484-1485 (sll 32-8 / srl 32-8 = mask lo byte for block damage).
VIRTUAL_FIELDS = {"damage_hit", "damage_block"}
# byte offset of each field within a record
FIELD_BYTE_OFFSET = {}
_off = 0
for _f in FIELD_ORDER:
    FIELD_BYTE_OFFSET[_f] = _off
    _off += FIELD_BITS[_f] // 8
RECORD_BYTES = _off  # 2+2+2+2+2+2+4+2 = 18

CHARACTER_LABELS = {
    "hh": "Kung Lao (hathead)",
    "lk": "Liu Kang",
    "jc": "Johnny Cage",
    "sa": "Baraka",
    "fn": "Kitana / Mileena",
    "st": "Shang Tsung",
    "rd": "Raiden",
    "nj": "Sub-Zero / Reptile / Scorpion (ninjas)",
    "jx": "Jax",
    "go": "Goro / Kintaro",
    "sk": "Shao Kahn",
}


def parse_asm_literal(s):
    """Parse a GSPA numeric literal: 0x5e, 0ffh, -00ah, 128, etc. Return int or None if symbolic."""
    s = s.strip().rstrip(",")
    sign = 1
    if s.startswith("-"):
        sign = -1
        s = s[1:]
    # Hex with h suffix (GSPA style): 0ffh, 05eh, 00ah
    m = re.fullmatch(r"0([0-9a-fA-F]*)h", s)
    if m:
        return sign * int(m.group(1) or "0", 16)
    # Hex with > prefix - the assembler's OWN syntax, and what the original
    # source uses throughout (>3010, >59). This tree has been reformatted to
    # the h-suffix form, so it turns up only when reading an unmodified
    # checkout - which is exactly what a retail reference is read out of.
    m = re.fullmatch(r">([0-9a-fA-F]+)", s)
    if m:
        return sign * int(m.group(1), 16)
    # Hex with 0x prefix
    if s.lower().startswith("0x"):
        return sign * int(s, 16)
    # Decimal
    if re.fullmatch(r"\d+", s):
        return sign * int(s)
    # Symbolic (e.g. sf_squeeze) — not a number
    return None


def format_asm_hex(val, width_bits):
    """Format int as GSPA hex literal: 0XXh. Negative → two's complement."""
    if width_bits == 32:
        mask = 0xFFFFFFFF
        if isinstance(val, int) and val == 0:
            return "0"
    else:
        mask = 0xFFFF
    ival = val & mask if isinstance(val, int) else val
    if isinstance(ival, int):
        return f"0{ival:0{width_bits // 4}x}h"
    return str(val)


# Fields that are ALWAYS a number when the source is behaving.  `score` and
# `sound` are deliberately absent: both carry symbols in retail (`sc_1000`,
# `sf_squeeze`) and every consumer already reads those off `raw_fields`.
# Resolving them here would silently change what a pack emits.
NUMERIC_FIELDS = ("x_offset", "y_offset", "x_size", "y_size",
                  "strike_routine", "damage")

# Where a strike record is allowed to reach for a named constant.  MKSTK's own
# equates first, then the global ones.
EQUATE_SOURCES = ("MKSTK.ASM", "MAINEQU.ASM")

_EQUATE_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)\s+(?:\.set|\.equ|equ)\s+([^;\s]+)",
    re.IGNORECASE)


def parse_equates():
    """name -> int for every `<name> .set <literal>` we are allowed to see.

    A strike record may name a constant instead of writing the number
    (`stk_ermac_teleslam` does: its x_offset is `erm_tks_reach`).  Without
    this the field parses as None, which used to reach hitbox_pack as a
    TypeError deep in `_s16` with nothing naming the record.
    """
    out = {}
    for fname in EQUATE_SOURCES:
        path = ASM_PATH.parent / fname
        if not path.exists():
            continue
        for line in path.read_text(errors="replace").splitlines():
            m = _EQUATE_RE.match(line)
            if not m:
                continue
            val = parse_asm_literal(m.group(2))
            if isinstance(val, int):
                out.setdefault(m.group(1), val)
    return out


def parse_mkstk():
    """Parse MKSTK.ASM → {label: move_record}."""
    if not ASM_PATH.exists():
        sys.exit(f"Error: {ASM_PATH} not found")

    lines = ASM_PATH.read_text(errors="replace").splitlines()
    equates = parse_equates()
    moves = {}
    current = None
    field_idx = 0

    for i, line in enumerate(lines, start=1):
        stripped = line.strip()
        # Detect strike-record start label
        m = re.match(r"^(stk_[A-Za-z0-9_]+)\s*$", line)
        if m:
            current = m.group(1)
            moves[current] = {
                "label": current,
                "line": i,
                "fields": {},
                "raw_fields": {},
                "field_lines": {},
            }
            field_idx = 0
            continue

        if current is None or field_idx >= len(FIELD_ORDER):
            continue

        # Expect .word / .long directive.  CASE-INSENSITIVE: MKSTK.ASM has
        # eleven `.WORD 0280Ah ; damage` lines (every uppercut), and matching
        # only lowercase silently DROPPED them - which did not just misreport
        # damage as 0, it shifted every later field up a slot, so the record's
        # `sound` line pointed at the NEXT record's x_offset and sync-asm would
        # have written through it.
        m = re.match(r"^\s*\.(word|long)\s+([^;]+?)\s*(?:;.*)?$", line,
                     re.IGNORECASE)
        if not m:
            # Blank / comment — don't consume field slot
            continue

        directive, raw_val = m.group(1).lower(), m.group(2).strip()

        # A strike record opens with `.word` (x_offset).  `stk_phase_tab` is a
        # per-character POINTER table that opens with `.long`, and is not a
        # strike record at all - drop it rather than parse 8 pointers as a box.
        if field_idx == 0 and directive == "long":
            current = None
            continue
        field_name = FIELD_ORDER[field_idx]
        value = parse_asm_literal(raw_val)
        if value is None and field_name in NUMERIC_FIELDS:
            # A named constant standing in for the number.  raw_fields keeps
            # the symbol, so sync-asm leaves the source alone unless this
            # exact field is edited.
            value = equates.get(raw_val.strip().rstrip(","))
        moves[current]["fields"][field_name] = value
        moves[current]["raw_fields"][field_name] = raw_val
        moves[current]["field_lines"][field_name] = i
        field_idx += 1

        if field_idx >= len(FIELD_ORDER):
            current = None

    return moves


def parse_char_tables():
    """Parse MKSTK.ASM → ordered list of (char_name, [move_labels]) per character."""
    lines = ASM_PATH.read_text(errors="replace").splitlines()
    char_tables = []
    current = None
    collecting = False

    for line in lines:
        m = re.match(r"^([a-z]{2})_strikes\s*$", line)
        if m:
            current = {"name": m.group(1), "moves": []}
            collecting = True
            continue
        if collecting:
            m = re.match(r"^\s*\.long\s+(stk_[A-Za-z0-9_]+)\s*(?:;.*)?$", line)
            if m:
                current["moves"].append(m.group(1))
                continue
            # A bare `<name>_row` label is a GUARD ANCHOR sitting inside the
            # table, not the end of it - MKSTK.ASM uses three of them
            # (`hh_superk_row`, `nj_superk_row`, `ermac_superk_row`) as the
            # left-hand side of an `.if (anchor-table)/32!=<equate>` check.
            # Ending the table on one silently dropped every row after it, so
            # `stk_super_rep` lost its owner and republished as a `shared/`
            # record under a different public id.  boxlab's own validator is
            # what caught it: "a build does not lose strike records".
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*_row\s*$", line):
                continue
            # End of table when we hit a non-.long non-blank line that isn't a comment
            if line.strip() and not line.strip().startswith(("*", ";", ".")):
                char_tables.append(current)
                current = None
                collecting = False
            elif line.strip().startswith(".") and not re.match(r"^\s*\.long", line):
                char_tables.append(current)
                current = None
                collecting = False

    if current:
        char_tables.append(current)

    return char_tables


def parse_bit_offsets():
    """Parse MKSTK.LST → {label: bit_offset_in_section}."""
    if not LST_PATH.exists():
        sys.exit(f"Error: {LST_PATH} not found. Run 'python build.py' first.")

    offsets = {}
    text = LST_PATH.read_text(errors="replace")
    # Listing lines look like:  "    1992 00007480           stk_lkhikick"
    for m in re.finditer(r"^\s*\d+\s+([0-9a-fA-F]{8})\s+(stk_[A-Za-z0-9_]+)\s*$",
                         text, re.MULTILINE):
        offsets[m.group(2)] = int(m.group(1), 16)
    return offsets


def section_base_offset():
    """Byte offset from get_char_stk (start of stk.bin dump) to the MKSTK section origin.
    stk.bin was saved starting at get_char_stk (offset 0 in the section), so this is 0."""
    return 0


def move_byte_offset(label, bit_offsets):
    """Byte offset of a move record within stk.bin."""
    if label not in bit_offsets:
        sys.exit(f"Error: {label} not in MKSTK.LST (local label not exported?)")
    return bit_offsets[label] // 8


def load_state():
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return {"edits": {}}


def save_state(state):
    STATE_PATH.write_text(json.dumps(state, indent=2))


def effective_value(label, field, moves, state):
    """Current value for (label, field) — edit overrides MKSTK.ASM default."""
    # Virtual fields derived from packed damage word
    if field in VIRTUAL_FIELDS:
        dmg = effective_value(label, "damage", moves, state)
        if not isinstance(dmg, int):
            return None
        if field == "damage_hit":
            return (dmg >> 8) & 0xFF
        if field == "damage_block":
            return dmg & 0xFF
    edit = state["edits"].get(label, {}).get(field)
    if edit is not None:
        return edit
    return moves[label]["fields"].get(field)


def cmd_list(args, moves, char_tables):
    char_filter = args.character.lower() if args.character else None
    for ch in char_tables:
        if char_filter and ch["name"] != char_filter:
            continue
        label = CHARACTER_LABELS.get(ch["name"], ch["name"])
        print(f"\n[{ch['name']}] {label} — {len(ch['moves'])} moves")
        def fmt(v):
            return f"{v:>4}" if isinstance(v, int) else f"{'?':>4}"
        for slot, mv in enumerate(ch["moves"]):
            if mv in moves:
                f = moves[mv]["fields"]
                print(f"  {slot:2d}  {mv:24s}  x_off={fmt(f.get('x_offset'))}"
                      f" y_off={fmt(f.get('y_offset'))}"
                      f"  x_size={fmt(f.get('x_size'))} y_size={fmt(f.get('y_size'))}")


def cmd_show(args, moves, state):
    label = args.move
    if label not in moves:
        sys.exit(f"Error: move '{label}' not found")
    f = moves[label]["fields"]
    print(f"\n{label}  (MKSTK.ASM:{moves[label]['line']})")
    print("-" * 50)
    for field in FIELD_ORDER:
        orig = f.get(field)
        eff = effective_value(label, field, moves, state)
        changed = ""
        if state["edits"].get(label, {}).get(field) is not None and orig != eff:
            changed = f"  <- EDIT (was {orig})"
        val_str = eff if isinstance(eff, str) else (f"{eff} (0x{eff:x})" if isinstance(eff, int) else eff)
        print(f"  {field:16s} = {val_str}{changed}")
        # Show the damage_hit / damage_block decomposition
        if field == "damage" and isinstance(eff, int):
            hit = (eff >> 8) & 0xFF
            blk = eff & 0xFF
            print(f"  {'damage_hit':16s} = {hit}  ({hit} HP dmg on clean hit)")
            print(f"  {'damage_block':16s} = {blk}  ({blk} HP dmg on blocked hit)")


def cmd_set(args, moves, state):
    label = args.move
    if label not in moves:
        sys.exit(f"Error: move '{label}' not found")
    edits = state["edits"].setdefault(label, {})
    valid_fields = FIELD_ORDER + sorted(VIRTUAL_FIELDS)
    for assignment in args.assignments:
        if "=" not in assignment:
            sys.exit(f"Error: bad assignment '{assignment}' (expected field=value)")
        field, raw_val = assignment.split("=", 1)
        field = field.strip()
        if field not in valid_fields:
            sys.exit(f"Error: unknown field '{field}' (valid: {', '.join(valid_fields)})")
        val = parse_asm_literal(raw_val) if re.match(r"[0-9\-]", raw_val) else raw_val
        if val is None:
            sys.exit(f"Error: can't parse value '{raw_val}'")

        if field in VIRTUAL_FIELDS:
            # Merge into the packed damage word (preserve the other byte)
            if not isinstance(val, int) or not (0 <= val <= 255):
                sys.exit(f"Error: {field} must be an integer 0..255 (got {val})")
            current = effective_value(label, "damage", moves, state)
            if not isinstance(current, int):
                current = 0
            if field == "damage_hit":
                new_damage = ((val & 0xFF) << 8) | (current & 0xFF)
            else:  # damage_block
                new_damage = (current & 0xFF00) | (val & 0xFF)
            edits["damage"] = new_damage
            print(f"  set {label}.{field} = {val}  (damage now 0x{new_damage:04x} = "
                  f"{(new_damage >> 8) & 0xff} hit / {new_damage & 0xff} block)")
        else:
            edits[field] = val
            print(f"  set {label}.{field} = {val}")

    save_state(state)
    print(f"\nRun 'python hitbox_edit.py patch' to write stk.bin")


def cmd_reset(args, state):
    if args.move:
        state["edits"].pop(args.move, None)
        print(f"Cleared edits for {args.move}")
    else:
        state["edits"] = {}
        print("Cleared all edits")
    save_state(state)


def cmd_diff(moves, state):
    if not state["edits"]:
        print("No pending edits.")
        return
    for label, edits in state["edits"].items():
        print(f"\n{label}:")
        for field, new in edits.items():
            orig = moves[label]["fields"].get(field)
            print(f"  {field}: {orig} -> {new}")


def write_field(buf, record_offset, field, value):
    """Patch one field inside a record. Symbolic/None values are skipped (preserves bytes)."""
    if not isinstance(value, int):
        return False
    bits = FIELD_BITS[field]
    byte_off = record_offset + FIELD_BYTE_OFFSET[field]
    mask = (1 << bits) - 1
    packed_val = value & mask
    if bits == 32:
        buf[byte_off:byte_off + 4] = struct.pack("<I", packed_val)
    else:
        buf[byte_off:byte_off + 2] = struct.pack("<H", packed_val)
    return True


def cmd_patch(moves, state, bit_offsets):
    """Read stk.bin (if exists) else build from MKSTK.ASM, apply edits, write patched stk.bin."""
    if STK_BIN.exists():
        buf = bytearray(STK_BIN.read_bytes())
        source = f"{STK_BIN.name} ({len(buf)} bytes)"
    else:
        sys.exit(f"Error: {STK_BIN} not found.\n"
                 f"Run MAME debug command first: saver stk.bin,0x19802,0x11d0,:maincpu\n"
                 f"Then copy stk.bin from MAME folder to this repo root.")

    print(f"Reading: {source}")

    # For each edited move, patch only the changed fields (preserves other bytes)
    patches = 0
    for label, edits in state["edits"].items():
        if label not in moves:
            print(f"  Warning: skipping unknown move '{label}'")
            continue
        record_offset = move_byte_offset(label, bit_offsets)
        for field, val in edits.items():
            if write_field(buf, record_offset, field, val):
                print(f"  {label}.{field} = {val:>6} @ 0x{record_offset + FIELD_BYTE_OFFSET[field]:x}")
                patches += 1

    STK_BIN.write_bytes(buf)
    print(f"\nWrote patched {STK_BIN} ({len(buf)} bytes, {patches} field(s) across {len(state['edits'])} move(s))")
    print(f"Run 'python hitbox_edit.py loadr' to see the MAME command.")


def cmd_loadr():
    """Print the MAME loadr command using current map addresses."""
    if not MAP_PATH.exists():
        sys.exit(f"Error: {MAP_PATH} not found. Run 'python build.py' first.")
    text = MAP_PATH.read_text(errors="replace")

    def sym_addr(name):
        m = re.search(rf"([0-9a-f]{{8}})\s+{re.escape(name)}\b", text, re.IGNORECASE)
        if not m:
            sys.exit(f"Error: '{name}' not in mk2.map (need '.def {name}' in its .ASM)")
        return int(m.group(1), 16)

    ROM_BASE_BIT = 0xFF800000
    start = sym_addr("get_char_stk")
    end = sym_addr("stk_super_rep")
    byte_start = (start - ROM_BASE_BIT) // 8
    byte_len = (end - start) // 8

    print(f"# Copy stk.bin to MAME folder (C:\\MAME\\), then paste in MAME debug:")
    print()
    print(f"loadr stk.bin,0x{byte_start:x},0x{byte_len:x},:maincpu")
    print()
    print(f"# Enable green collision box overlay:")
    print(f"w@0x{0x0112bb60 // 8:x}=1")


def cmd_sync_asm(moves, state):
    """Apply pending edits to src/MKSTK.ASM (in-place, with backup)."""
    if not state["edits"]:
        print("No pending edits to sync.")
        return

    backup = ASM_PATH.with_suffix(".ASM.bak")
    shutil.copy2(ASM_PATH, backup)
    print(f"Backup: {backup}")

    lines = ASM_PATH.read_text(errors="replace").splitlines(keepends=True)
    count = 0

    for label, edits in state["edits"].items():
        if label not in moves:
            continue
        for field, new_val in edits.items():
            line_no = moves[label]["field_lines"].get(field)
            if not line_no:
                continue
            idx = line_no - 1
            orig_line = lines[idx]
            # Replace the numeric literal, preserve indent and comment
            bits = FIELD_BITS[field]
            new_lit = format_asm_hex(new_val, bits) if isinstance(new_val, int) else str(new_val)
            m = re.match(r"^(\s*\.(?:word|long)\s+)([^;]+?)(\s*(?:;.*)?)$", orig_line)
            if not m:
                print(f"  Skip: can't parse line {line_no} for {label}.{field}")
                continue
            new_line = f"{m.group(1)}{new_lit}{m.group(3)}"
            if not new_line.endswith("\n"):
                new_line += "\n"
            lines[idx] = new_line
            print(f"  MKSTK.ASM:{line_no}  {label}.{field} = {new_val}")
            count += 1

    ASM_PATH.write_text("".join(lines))
    print(f"\nPatched {count} field(s) in {ASM_PATH.name}")
    print("Run 'python build.py' + 'python makerom.py' + 'python mamerom.py ...' to bake into ROMs.")
    print("Edit state preserved — run 'python hitbox_edit.py reset' when happy.")


def main():
    parser = argparse.ArgumentParser(description="MK2 hitbox/strike table editor")
    sp = parser.add_subparsers(dest="cmd", required=True)

    p = sp.add_parser("list", help="list characters and their moves")
    p.add_argument("character", nargs="?", help="char code (lk, jc, rd, ...)")

    p = sp.add_parser("show", help="show a single move's field values")
    p.add_argument("move", help="move label (e.g. stk_lkhikick)")

    p = sp.add_parser("set", help="set field value(s) for a move")
    p.add_argument("move", help="move label")
    p.add_argument("assignments", nargs="+", help="field=value [field=value ...]")

    p = sp.add_parser("reset", help="clear pending edits")
    p.add_argument("move", nargs="?", help="move label (or omit to clear all)")

    sp.add_parser("diff", help="show pending edits vs MKSTK.ASM")
    sp.add_parser("patch", help="write patched stk.bin with pending edits")
    sp.add_parser("loadr", help="print MAME loadr command for current ROM")
    sp.add_parser("sync-asm", help="apply pending edits to src/MKSTK.ASM")

    args = parser.parse_args()
    moves = parse_mkstk()
    char_tables = parse_char_tables()
    state = load_state()

    if args.cmd == "list":
        cmd_list(args, moves, char_tables)
    elif args.cmd == "show":
        cmd_show(args, moves, state)
    elif args.cmd == "set":
        cmd_set(args, moves, state)
    elif args.cmd == "reset":
        cmd_reset(args, state)
    elif args.cmd == "diff":
        cmd_diff(moves, state)
    elif args.cmd == "patch":
        bit_offsets = parse_bit_offsets()
        cmd_patch(moves, state, bit_offsets)
    elif args.cmd == "loadr":
        cmd_loadr()
    elif args.cmd == "sync-asm":
        cmd_sync_asm(moves, state)


if __name__ == "__main__":
    main()
