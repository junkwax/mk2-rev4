#!/usr/bin/env python3
"""
MK2 special-move combo input editor.

MK2 stores combo INPUT patterns as `scom_<name>` tables (91 total across
MOVES.ASM, MKBABY.ASM). Each table is 13 words:

    .word  <window>     ; time window in ticks
    .word  <input1>     ; newest input (facing-right pattern, zero-terminated)
    .word  <input2>
    .word  <input3>
    .word  <input4>
    .word  <input5>
    .word  <input6>
    .word  <input1>     ; mirror (facing-left pattern, zero-terminated)
    .word  <input2>
    ...

The TRIGGER button (HP/LP/HK/LK/BLK) is NOT in this table — it's in the
move handler that CALLS combo_look_lr with this combo. Each character has
handlers like jc_hi_punch, jc_lo_kick etc. — those dispatch to specific
scom_ tables based on context. The combo pattern stored here is the
DIRECTIONAL sequence only.

Inputs are stored newest-first (the combo detector scans joystick history
backward in time from "now"). So:
    .word sw_right       ; most recent = Forward
    .word sw_left        ; before that  = Back
means the player did "Back, Forward" (in natural reading order), then
pressed the trigger button.

Commands:
    python combo_edit.py list                         # all 91 combos, with trigger button
    python combo_edit.py show scom_jc_shadow          # decoded inputs
    python combo_edit.py set scom_jc_shadow back back hp  # change inputs
    python combo_edit.py window scom_jc_shadow 0x30   # change timing window
    python combo_edit.py restore                      # revert edits

The `set` command takes tokens:
    fwd/forward/right      → sw_right
    back/left              → sw_left
    up                     → sw_up
    down                   → sw_down
    hp/high_punch          → sw_hi_punch
    lp/low_punch           → sw_lo_punch
    hk/high_kick           → sw_hi_kick
    lk/low_kick            → sw_lo_kick
    block                  → sw_block
    skip                   → sw_skip
    0                      → (terminator / empty slot)

Order is "oldest first" for user-friendly input (natural reading order),
tool reverses to store newest-first in the table.

After editing: python build.py + makerom.py + mamerom.py to bake.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).parent.resolve()
ASM_FILES = [
    REPO / "src" / "MOVES.ASM",
    REPO / "src" / "MKBABY.ASM",
]
BACKUP_SUFFIX = ".ASM.combo.bak"

# Input name → sw_ constant (per MAINEQU.ASM:912-921)
SW_CONSTANTS = {
    "sw_hi_punch": 0, "sw_lo_punch": 1, "sw_block": 2,
    "sw_hi_kick": 3, "sw_lo_kick": 4,
    "sw_up": 5, "sw_down": 6, "sw_left": 7, "sw_right": 8, "sw_skip": 9,
}
SW_INVERSE = {v: k for k, v in SW_CONSTANTS.items()}

# Human-friendly token → sw_ constant
USER_ALIASES = {
    "fwd": "sw_right", "forward": "sw_right", "right": "sw_right", "f": "sw_right",
    "back": "sw_left", "left": "sw_left", "b": "sw_left",
    "up": "sw_up", "u": "sw_up",
    "down": "sw_down", "d": "sw_down",
    "hp": "sw_hi_punch", "high_punch": "sw_hi_punch",
    "lp": "sw_lo_punch", "low_punch": "sw_lo_punch",
    "hk": "sw_hi_kick", "high_kick": "sw_hi_kick",
    "lk": "sw_lo_kick", "low_kick": "sw_lo_kick",
    "block": "sw_block", "blk": "sw_block",
    "skip": "sw_skip",
    "0": "0", "none": "0", "empty": "0",
}

# Friendly name → short label for display
FRIENDLY_DIR = {
    "sw_right": "Forward",
    "sw_left":  "Back",
    "sw_up":    "Up",
    "sw_down":  "Down",
    "sw_hi_punch": "HP",
    "sw_lo_punch": "LP",
    "sw_hi_kick":  "HK",
    "sw_lo_kick":  "LK",
    "sw_block":    "BLK",
    "sw_skip":     "skip",
}


def parse_literal(s):
    s = s.strip().rstrip(",").strip()
    sign = 1
    if s.startswith("-"):
        sign, s = -1, s[1:]
    m = re.fullmatch(r"0([0-9a-fA-F]*)h", s)
    if m:
        return sign * int(m.group(1) or "0", 16)
    if s.lower().startswith("0x"):
        return sign * int(s, 16)
    if re.fullmatch(r"\d+", s):
        return sign * int(s)
    return None


def load_all():
    """Read all ASM files. Return dict: {path: [lines]}."""
    return {p: p.read_text(errors="replace").splitlines() for p in ASM_FILES if p.exists()}


def parse_combos(files):
    """Return {label: {file, line, aliases:[other labels sharing same data], words:[13 raw strings]}}."""
    combos = {}
    for path, lines in files.items():
        i = 0
        while i < len(lines):
            m = re.match(r"^(scom_[A-Za-z0-9_]+)\s*$", lines[i])
            if not m:
                i += 1
                continue
            # Collect stacked labels (multiple scom_ on consecutive lines share one table)
            aliases = [m.group(1)]
            j = i + 1
            while j < len(lines):
                mm = re.match(r"^(scom_[A-Za-z0-9_]+)\s*$", lines[j])
                if not mm:
                    break
                aliases.append(mm.group(1))
                j += 1
            # j now points at first .word
            # Expect 13 .word entries
            words = []
            word_lines = []
            k = j
            while len(words) < 13 and k < len(lines):
                wm = re.match(r"^\s*\.word\s+([^;\n]+?)\s*(?:;.*)?$", lines[k])
                if wm:
                    words.append(wm.group(1).strip())
                    word_lines.append(k + 1)  # 1-based
                elif lines[k].strip() == "":
                    pass  # blank line allowed
                else:
                    break
                k += 1

            if len(words) == 13:
                rec = {
                    "path": path, "first_line": i + 1,
                    "aliases": aliases, "words": words, "word_lines": word_lines,
                }
                for a in aliases:
                    combos[a] = rec
                i = k
            else:
                i += 1
    return combos


def parse_callers(files):
    """Return {scom_label: [(path, line, handler_name)]} showing who dispatches this combo."""
    callers = {}
    re_call = re.compile(r"^\s*movi\s+(scom_[A-Za-z0-9_]+)\s*,\s*a11\b", re.IGNORECASE)

    for path, lines in files.items():
        current_handler = None
        for idx, line in enumerate(lines, start=1):
            # Track the nearest preceding "do_*" or "*_hi_kick"/"*_lo_punch" handler label
            m = re.match(r"^([a-z]{2,3}_(?:hi_punch|lo_punch|hi_kick|lo_kick|block)|do_[a-z_]\w*)\s*(?:;.*)?$", line)
            if m:
                current_handler = m.group(1)
            m = re_call.match(line)
            if m:
                label = m.group(1)
                callers.setdefault(label, []).append((path, idx, current_handler or "?"))
    return callers


def trigger_button_for(handler):
    """Guess the trigger button based on handler suffix."""
    if not handler:
        return ""
    suffix_map = {
        "hi_punch": "HP",
        "lo_punch": "LP",
        "hi_kick": "HK",
        "lo_kick": "LK",
        "block": "BLK",
    }
    for k, v in suffix_map.items():
        if handler.endswith(k):
            return v
    return ""


def decode_word(raw):
    """Return ('number',int) or ('label',str) or ('raw',str)."""
    v = parse_literal(raw)
    if v is not None:
        return ("number", v)
    if raw in SW_CONSTANTS:
        return ("label", raw)
    return ("raw", raw)


def format_input(raw):
    """Turn one .word into a friendly string."""
    kind, val = decode_word(raw)
    if kind == "number":
        if val == 0:
            return "-"
        if val in SW_INVERSE:
            return FRIENDLY_DIR.get(SW_INVERSE[val], SW_INVERSE[val])
        return f"({val})"
    if kind == "label":
        return FRIENDLY_DIR.get(val, val)
    return raw


def format_sequence(words_slice):
    """Words are stored newest-first; produce human string oldest-first (natural reading)."""
    # Take until first '-' (zero terminator)
    inputs = [format_input(w) for w in words_slice]
    # Trim trailing '-'
    while inputs and inputs[-1] == "-":
        inputs.pop()
    # Reverse to oldest-first
    return ", ".join(reversed(inputs)) if inputs else "(empty)"


def user_token_to_asm(tok):
    tok = tok.strip().lower()
    if tok in USER_ALIASES:
        return USER_ALIASES[tok]
    if tok in SW_CONSTANTS:
        return tok
    return None


def cmd_list(args, combos, callers):
    print(f"{'Combo':32s}  {'Triggers':10s}  {'Window':>6s}  Sequence")
    print("-" * 100)
    # Unique records by first_line
    seen = set()
    for label in sorted(combos):
        rec = combos[label]
        key = (str(rec["path"]), rec["first_line"])
        if key in seen:
            continue
        seen.add(key)
        # All labels sharing this record (sibling aliases)
        labels_str = ", ".join(rec["aliases"])
        window = parse_literal(rec["words"][0])
        seq = format_sequence(rec["words"][1:7])

        # Collect trigger buttons from all callers across aliases
        triggers = set()
        for a in rec["aliases"]:
            for _, _, h in callers.get(a, []):
                t = trigger_button_for(h)
                if t:
                    triggers.add(t)
        trig_str = "/".join(sorted(triggers)) if triggers else "?"

        win_str = f"0x{window:x}" if isinstance(window, int) else "?"
        print(f"{labels_str:32s}  {trig_str:10s}  {win_str:>6s}  {seq}")


def cmd_show(args, combos, callers):
    label = args.combo
    if label not in combos:
        sys.exit(f"Error: combo '{label}' not found. Try: python combo_edit.py list")

    rec = combos[label]
    print(f"\n{', '.join(rec['aliases'])}")
    print(f"  defined in {rec['path'].name}:{rec['first_line']}")
    print()

    window = parse_literal(rec["words"][0])
    win_str = f"{window} (0x{window:x})" if isinstance(window, int) else rec["words"][0]
    print(f"  Window: {win_str} ticks")
    print()

    # Facing right
    right = rec["words"][1:7]
    print(f"  Facing Right pattern  (newest-first stored order):")
    for idx, w in enumerate(right):
        print(f"    [{idx}] {w:20s}  {format_input(w)}")
    print(f"  -> Natural input order: {format_sequence(right)}")
    print()

    left = rec["words"][7:13]
    print(f"  Facing Left pattern   (mirror):")
    for idx, w in enumerate(left):
        print(f"    [{idx}] {w:20s}  {format_input(w)}")
    print(f"  -> Natural input order: {format_sequence(left)}")
    print()

    # Callers / trigger buttons
    triggers_seen = []
    for a in rec["aliases"]:
        for path, line, handler in callers.get(a, []):
            t = trigger_button_for(handler)
            triggers_seen.append((path.name, line, handler, t))
    if triggers_seen:
        print(f"  Triggered by (call sites of movi scom_, a11):")
        for pname, line, handler, trig in triggers_seen:
            trig_str = f"  [{trig}]" if trig else ""
            print(f"    {pname}:{line:>5d}  handler: {handler}{trig_str}")
    else:
        print(f"  (no callers found — possibly dead code or macro-called)")


def mirror_direction(sw):
    """Flip left<->right for mirrored pattern."""
    if sw == "sw_right":
        return "sw_left"
    if sw == "sw_left":
        return "sw_right"
    return sw


def cmd_set(args, combos):
    label = args.combo
    if label not in combos:
        sys.exit(f"Error: combo '{label}' not found")
    rec = combos[label]

    # Parse user tokens (oldest-first natural input)
    tokens = [t for t in args.inputs if t]
    if len(tokens) > 6:
        sys.exit(f"Error: max 6 inputs per combo (got {len(tokens)})")

    asm_tokens = []
    for t in tokens:
        asm = user_token_to_asm(t)
        if asm is None:
            sys.exit(f"Error: unknown input token '{t}' — see 'python combo_edit.py --help' for aliases")
        asm_tokens.append(asm)

    # Reverse for newest-first storage, pad to 6 with "0"
    stored = list(reversed(asm_tokens)) + ["0"] * (6 - len(asm_tokens))
    mirrored = [mirror_direction(x) for x in stored]

    # Edit each of the 13 .word lines (index 0 = window, 1-6 = right, 7-12 = left)
    path = rec["path"]
    lines = path.read_text(errors="replace").splitlines(keepends=True)

    # Back up once per file
    backup_path = path.with_suffix(path.suffix + ".combo.bak")
    if not backup_path.exists():
        shutil.copy2(path, backup_path)

    changed = 0
    for i, new_val in enumerate(stored + mirrored):  # 12 word positions (skip window at idx 0)
        word_line_no = rec["word_lines"][i + 1]
        idx = word_line_no - 1
        old_line = lines[idx]
        m = re.match(r"^(\s*\.word\s+)([^;\n]+?)(\s*(?:;.*)?)(\r?\n?)$", old_line)
        if not m:
            continue
        current = m.group(2).strip()
        if current == new_val:
            continue
        new_line = f"{m.group(1)}{new_val}{m.group(3)}{m.group(4) or chr(10)}"
        lines[idx] = new_line
        changed += 1
        print(f"  {path.name}:{word_line_no}  {current} -> {new_val}")

    if changed == 0:
        print("(no changes — values already match)")
        return

    path.write_text("".join(lines))
    print(f"\nPatched {changed} line(s) in {path.name}")
    print(f"Backup: {backup_path.name}")
    print(f"\nRebuild: python build.py && python makerom.py && python mamerom.py 'c:\\Users\\you\\Downloads\\mk2.zip' --source-video")


def cmd_window(args, combos):
    label = args.combo
    if label not in combos:
        sys.exit(f"Error: combo '{label}' not found")
    rec = combos[label]

    new_val = parse_literal(args.window)
    if new_val is None:
        sys.exit(f"Error: can't parse window value '{args.window}'")

    path = rec["path"]
    lines = path.read_text(errors="replace").splitlines(keepends=True)
    backup_path = path.with_suffix(path.suffix + ".combo.bak")
    if not backup_path.exists():
        shutil.copy2(path, backup_path)

    word_line_no = rec["word_lines"][0]
    idx = word_line_no - 1
    old_line = lines[idx]
    m = re.match(r"^(\s*\.word\s+)([^;\n]+?)(\s*(?:;.*)?)(\r?\n?)$", old_line)
    if not m:
        sys.exit(f"Error: can't parse line {word_line_no}")
    current = m.group(2).strip()
    new_asm = f"0{new_val & 0xFFFF:x}h"
    lines[idx] = f"{m.group(1)}{new_asm}{m.group(3)}{m.group(4) or chr(10)}"
    path.write_text("".join(lines))
    print(f"  {path.name}:{word_line_no}  window: {current} -> {new_asm} ({new_val} ticks)")
    print(f"Backup: {backup_path.name}")


def cmd_restore():
    any_restored = False
    for asm in ASM_FILES:
        bak = asm.with_suffix(asm.suffix + ".combo.bak")
        if bak.exists():
            shutil.copy2(bak, asm)
            bak.unlink()
            print(f"Restored {asm.name} from {bak.name}")
            any_restored = True
    if not any_restored:
        print("(no backups to restore)")


def main():
    parser = argparse.ArgumentParser(description="MK2 special-move combo input editor")
    sp = parser.add_subparsers(dest="cmd", required=True)

    sp.add_parser("list", help="list all combos with triggers and sequences")

    p = sp.add_parser("show", help="show one combo in detail")
    p.add_argument("combo", help="combo label (e.g. scom_jc_shadow)")

    p = sp.add_parser("set", help="set inputs for a combo (space-separated, oldest first)")
    p.add_argument("combo", help="combo label")
    p.add_argument("inputs", nargs="+", help="input tokens: back fwd hp lp hk lk up down block skip")

    p = sp.add_parser("window", help="set time window (in ticks)")
    p.add_argument("combo", help="combo label")
    p.add_argument("window", help="new window value (decimal, 0xN, or Nh)")

    sp.add_parser("restore", help="restore edited ASM files from their .combo.bak backups")

    args = parser.parse_args()
    files = load_all()
    combos = parse_combos(files)
    callers = parse_callers(files)

    if args.cmd == "list":
        cmd_list(args, combos, callers)
    elif args.cmd == "show":
        cmd_show(args, combos, callers)
    elif args.cmd == "set":
        cmd_set(args, combos)
    elif args.cmd == "window":
        cmd_window(args, combos)
    elif args.cmd == "restore":
        cmd_restore()


if __name__ == "__main__":
    main()
