#!/usr/bin/env python3
"""Survey the per-character VICTIM reaction animations into a reference table.

Every fighter's anitab1 (character_anitabs1, MKGUYS.ASM) has a fixed slot
layout.  Slots 0x23..0x42 are mostly things done TO you - throws, fatality
victim poses, decapitation falls - and each fatality reaches them with
`get_his_char_ani` on the slot number.  This walks the ASM to answer, per
slot per character: which table is bound, what frames it plays, whether it
wobbles (ani_adjustxy), and where its anipoints sit.

    python tools/survey_victim_anis.py            # markdown to stdout
    python tools/survey_victim_anis.py --slot 38  # one slot, all characters
"""
import argparse
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"

# ochar -> (anitab1 label, owning ASM file).  From character_anitabs1 in
# MKGUYS.ASM; several fighters share one module (the ninjas, the female
# ninjas), which is itself part of the answer - shared art means a slot you
# "fix" for one of them moves all of them.
CHARS = [
    (0,  "hat_anitab1", "MKHH.ASM",  "Kung Lao"),
    (1,  "lk_anitab1",  "MKLK.ASM",  "Liu Kang"),
    (2,  "jc_anitab1",  "MKJC.ASM",  "Johnny Cage"),
    (3,  "sa_anitab1",  "MKSA.ASM",  "Baraka"),
    (4,  "fn1_anitab1", "MKFN.ASM",  "Kitana"),
    (5,  "fn2_anitab1", "MKFN.ASM",  "Mileena"),
    (6,  "st_anitab1",  "MKST.ASM",  "Shang Tsung"),
    (7,  "rd_anitab1",  "MKRD.ASM",  "Raiden"),
    (8,  "sz_anitab1",  "MKNJ.ASM",  "Sub-Zero"),
    (9,  "rp_anitab1",  "MKNJ.ASM",  "Reptile"),
    (10, "sc_anitab1",  "MKNJ.ASM",  "Scorpion"),
    (11, "jx_anitab1",  "MKJX.ASM",  "Jax"),
    (12, "go_anitab1",  "MKGORO.ASM","Kintaro"),
    (13, "sk_anitab1",  "MKSK.ASM",  "Shao Kahn"),
    (14, "sm_anitab1",  "MKNJ.ASM",  "Smoke"),
    (15, "sm_anitab1",  "MKNJ.ASM",  "Noob"),
    (16, "fn3_anitab1", "MKFN.ASM",  "Jade"),
]

ANI_CMDS = {
    1: "ani_jump", 2: "ani_flip", 3: "ani_adjustx", 4: "ani_adjustxy",
    5: "ani_nosleep", 6: "ani_calla", 7: "ani_sound", 8: "ani_ochar_jump",
    9: "ani_flip_v",
}
ANI_CMD_NAMES = set(ANI_CMDS.values()) | {"ani_flip_vert", "ani_end"}
# operands each command eats after itself: (.word lines, .long entries)
ANI_OPERANDS = {
    "ani_adjustx": (1, 0), "ani_adjustxy": (1, 0),
    "ani_jump": (0, 1), "ani_calla": (0, 1), "ani_sound": (0, 1),
    "ani_ochar_jump": (1, 1),
}

LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\b")
LONG_RE = re.compile(r"^\s*\.long\s+(.+?)\s*(?:;.*)?$", re.I)
WORD_RE = re.compile(r"^\s*\.word\s+(.+?)\s*(?:;.*)?$", re.I)


def load_lines(name):
    p = SRC / name
    if not p.exists():
        return []
    return p.read_text(encoding="latin-1", errors="replace").splitlines()


FILES = {}


def file_lines(name):
    if name not in FILES:
        FILES[name] = load_lines(name)
    return FILES[name]


def find_label(name, lines):
    """Line index where `name:` / `name` starts a definition (column 0)."""
    for i, ln in enumerate(lines):
        if not ln or ln[0] in " \t;*":
            continue
        m = LABEL_RE.match(ln)
        if m and m.group(1) == name:
            return i
    return None


def anitab_slots(label, fname):
    """Return {slot_index: table_label} for one character's anitab1."""
    lines = file_lines(fname)
    i = find_label(label, lines)
    if i is None:
        return {}
    slots, idx = {}, 0
    for ln in lines[i + 1:]:
        s = ln.strip()
        if not s or s.startswith(";") or s.startswith("*"):
            continue
        m = LONG_RE.match(ln)
        if not m:
            # Bare column-0 labels stacked directly on the anchor are ALIASES
            # sharing one table body - fn1/fn2/fn3_anitab1 (Kitana, Mileena,
            # Jade) and sz/rp/sc/sm_anitab1 (Sub-Zero, Reptile, Scorpion,
            # Smoke/Noob) are all written that way.  Only a label that turns
            # up after real data ends the table.
            if ln[0] not in " \t":
                if not slots and LABEL_RE.match(s):
                    continue
                break
            continue
        for item in (x.strip() for x in m.group(1).split(",")):
            if not item:
                continue
            slots[idx] = item
            idx += 1
    return slots


def walk_ani(label, fname, depth=0):
    """Parse one animation table into (frames, commands, holds, raw_entries)."""
    lines = file_lines(fname)
    i = find_label(label, lines)
    if i is None:
        return None
    frames, cmds, entries = [], [], []
    j = i + 1
    pending_words = 0
    pending_longs = 0
    while j < len(lines):
        ln = lines[j]
        s = ln.strip()
        if not s or s.startswith(";") or s.startswith("*"):
            j += 1
            continue
        # another column-0 label ends this table (unless it is an alias
        # sitting directly on top of the same body)
        if ln[0] not in " \t":
            if not entries and LABEL_RE.match(ln):
                j += 1
                continue
            break
        if pending_words:
            if WORD_RE.match(ln):
                pending_words -= 1
                j += 1
                continue
        m = LONG_RE.match(ln)
        if m:
            for item in (x.strip() for x in m.group(1).split(",")):
                if not item:
                    continue
                if pending_longs:
                    # operand of the command just seen (jump target, calla
                    # routine, sound id) - not a frame
                    pending_longs -= 1
                    entries.append(("operand", item))
                    continue
                if item == "0":
                    entries.append(("term", "0"))
                    continue
                if item in ANI_CMD_NAMES:
                    cmds.append(item)
                    entries.append(("cmd", item))
                    w, l = ANI_OPERANDS.get(item, (0, 0))
                    pending_words += w
                    pending_longs += l
                    continue
                frames.append(item)
                entries.append(("frame", item))
        j += 1
    return frames, cmds, entries


_TBL_INDEX = None


def tbl_index():
    """{record name: (TBL file, [w,h,anix,aniy])} across every src/*.TBL."""
    global _TBL_INDEX
    if _TBL_INDEX is not None:
        return _TBL_INDEX
    _TBL_INDEX = {}
    for tbl in sorted(SRC.glob("*.TBL")):
        lines = tbl.read_text(encoding="latin-1", errors="replace").splitlines()
        for i, ln in enumerate(lines):
            if not ln or ln[0] in " \t" or ":" not in ln:
                continue
            name = ln.split(":", 1)[0].strip()
            if not name:
                continue
            for nxt in lines[i + 1:i + 3]:
                m = WORD_RE.match(nxt)
                if m:
                    parts = [p.strip() for p in m.group(1).split(",")]
                    if len(parts) >= 4:
                        _TBL_INDEX.setdefault(name, (tbl.name, parts[:4]))
                    break
    return _TBL_INDEX


_WRAP_INDEX = None


def wrapper_index():
    """{wrapper label: [piece names]} for every `LBL .long A,B,C,0` in src.

    Wrappers are not necessarily in the character's own module - the whole
    *DRAIN0 family lives in MKFX.ASM next to drain_table, for instance - so
    this indexes all of src/*.ASM once.
    """
    global _WRAP_INDEX
    if _WRAP_INDEX is not None:
        return _WRAP_INDEX
    _WRAP_INDEX = {}
    inline = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s+\.long\s+(.+?)\s*(?:;.*)?$", re.I)
    bare = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*$")
    for asm in sorted(SRC.glob("*.ASM")):
        lines = asm.read_text(encoding="latin-1", errors="replace").splitlines()
        for i, ln in enumerate(lines):
            if not ln or ln[0] in " \t;*":
                continue
            m = inline.match(ln)
            body = None
            if m:
                name, body = m.group(1), m.group(2)
            else:
                # Wrappers are written both ways: `LBL .long A,B,0` on one
                # line, and `LBL` alone with the .long beneath it (every
                # *STUMBLE*, most per-character reaction wrappers).
                mb = bare.match(ln)
                if mb and i + 1 < len(lines):
                    nxt = LONG_RE.match(lines[i + 1])
                    if nxt:
                        name, body = mb.group(1), nxt.group(1)
            if body is None:
                continue
            pieces = [x.strip() for x in body.split(",")]
            pieces = [p for p in pieces if p and p != "0"]
            # a table of ani entries is not a piece list; piece lists are the
            # ones whose members are real IMG records
            if pieces:
                _WRAP_INDEX.setdefault(name, pieces)
    return _WRAP_INDEX


def resolve_pieces(label, fname=None, _depth=0):
    """An ani entry is usually a multipart WRAPPER - `LBL .long A,B,C,0` -
    and the real IMG records are the pieces.  Return the piece names, or
    [label] when the entry is already a record.

    Recurses: a slot can point at a per-character table (a_hhstunned) whose
    entries are themselves wrappers (TMSTUNNED1 -> TMSTUNNED1A/1B).
    """
    if label in tbl_index():
        return [label]
    if _depth >= 4:
        return [label]
    pieces = wrapper_index().get(label)
    if not pieces:
        return [label]
    out = []
    for p in pieces:
        if p in ANI_CMD_NAMES:
            continue
        out.extend(resolve_pieces(p, fname, _depth + 1))
    return out or [label]


# Slots that are reactions to something done TO this character.
VICTIM_SLOTS = {
    0x0f: "knocked down",
    0x10: "hit high",
    0x11: "hit low",
    0x16: "sweep fall",
    0x1b: "hit while ducking",
    0x23: "stumble back",
    0x25: "shredded",
    0x28: "stunned / Finish Him dizzy",
    0x36: "nutcrunched",
    0x37: "bicycle kicked",
    0x38: "DRAINED by Shang Tsung (soul suck)",
    0x39: "torso ripped",
    0x3a: "banged by slow projectile",
    0x3b: "impaled",
    0x3c: "decapitated body fall",
    0x3d: "decapitated head",
    0x3e: "flipped by Kintaro",
    0x3f: "back broken",
    0x40: "headhole fall (Cage)",
    0x41: "torso swiped (Scorpion)",
}
THROW_SLOTS = {s: f"thrown by ochar {s - 0x2a}" for s in range(0x2a, 0x36)}


def describe(entries):
    """Compact per-beat description: frames, holds, wobble."""
    beats, cur = [], []
    for kind, val in entries:
        if kind == "term":
            beats.append(cur)
            cur = []
        else:
            cur.append((kind, val))
    if cur:
        beats.append(cur)
    out = []
    for b in beats:
        if not b:
            continue
        fr = [v for k, v in b if k == "frame"]
        cm = [v for k, v in b if k == "cmd"]
        if not fr and not cm:
            continue
        # collapse repeats into xN holds
        parts, run, last = [], 0, None
        for f in fr:
            if f == last:
                run += 1
            else:
                if last is not None:
                    parts.append(last + (f" x{run}" if run > 1 else ""))
                last, run = f, 1
        if last is not None:
            parts.append(last + (f" x{run}" if run > 1 else ""))
        tag = ""
        if "ani_adjustxy" in cm or "ani_adjustx" in cm:
            tag = " *(wobble: ani_adjustxy)*"
        elif cm:
            tag = f" *({', '.join(sorted(set(cm)))})*"
        out.append(", ".join(parts) + tag)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slot", type=lambda s: int(s, 16),
                    help="hex slot number, e.g. 38")
    ap.add_argument("--anipoints", action="store_true",
                    help="resolve anipoints for every frame (slow)")
    args = ap.parse_args()

    tabs = {ochar: anitab_slots(lbl, f) for ochar, lbl, f, _ in CHARS}

    slots = dict(VICTIM_SLOTS)
    slots.update(THROW_SLOTS)
    wanted = [args.slot] if args.slot is not None else sorted(slots)

    for slot in wanted:
        print(f"\n### `0x{slot:02X}` - {slots.get(slot, '?')}\n")
        print("| ochar | fighter | table | beats |")
        print("| --- | --- | --- | --- |")
        for ochar, lbl, fname, nice in CHARS:
            tbl_label = tabs.get(ochar, {}).get(slot)
            if not tbl_label:
                print(f"| {ochar} | {nice} | - | *(no slot)* |")
                continue
            walked = walk_ani(tbl_label, fname)
            if walked is None:
                print(f"| {ochar} | {nice} | `{tbl_label}` | *(not found in {fname})* |")
                continue
            frames, cmds, entries = walked
            beats = describe(entries)
            body = "<br>".join(f"{n+1}. {b}" for n, b in enumerate(beats)) or "*(empty)*"
            print(f"| {ochar} | {nice} | `{tbl_label}` | {body} |")

        if args.anipoints:
            seen = set()
            rows = []
            for ochar, lbl, fname, nice in CHARS:
                t = tabs.get(ochar, {}).get(slot)
                if not t:
                    continue
                w = walk_ani(t, fname)
                if not w:
                    continue
                for f in w[0]:
                    if f in seen:
                        continue
                    seen.add(f)
                    for piece in resolve_pieces(f, fname):
                        hit = tbl_index().get(piece)
                        if hit:
                            tn, v = hit
                            rows.append((f, piece, tn, v))
                        else:
                            rows.append((f, piece, "?", None))
            if rows:
                print("\n<details><summary>anipoints (entry -> pieces)</summary>\n")
                print("| entry | piece | TBL | w | h | anix | aniy | floor (h-aniy) |")
                print("| --- | --- | --- | --: | --: | --: | --: | --: |")
                for f, piece, tn, v in rows:
                    if v:
                        try:
                            floor = int(v[1]) - int(v[3])
                        except ValueError:
                            floor = ""
                        print(f"| `{f}` | `{piece}` | {tn} | {v[0]} | {v[1]} | {v[2]} | {v[3]} | {floor} |")
                    else:
                        print(f"| `{f}` | `{piece}` | *(not in any TBL)* | | | | | |")
                print("\n</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
