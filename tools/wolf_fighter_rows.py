#!/usr/bin/env python3
r"""WOLF-ONLY FIGHTERS: give every ochar-indexed table a row for each fighter
that exists only on the Wolf build (MK3 Sonya first, ochar 20), without one
byte changing on the T-unit.

Every table tools/audit_char_tables.py knows about is read row by row - its
`.if` / `.else` blocks EVALUATED for the Wolf build (wunit 1) the way GSPA
would, from the switches defined across src/ - so the tool knows which
physical lines make up rows 0..19 on that board.  Straight after the table's
last line it keeps one generated block:

        .if     wunit           ; WOLF FIGHTERS - tools/wolf_fighter_rows.py
        .long   <row>           ; 20 - sonya (as kitana)
        .endif                  ; WOLF FIGHTERS

A row is the PROXY fighter's row copied as its source text (Sonya's proxy is
Kitana, 4 - the female-ninja body MK2 already handles everywhere) unless
OVERRIDES names something of her own.  Copying the proxy keeps every table
the engine might read for her well formed from day one; the overrides are
where she stops being Kitana, and they grow as her moves are ported.

    python tools/wolf_fighter_rows.py            # report (rows per table)
    python tools/wolf_fighter_rows.py --apply    # write the blocks
    python tools/wolf_fighter_rows.py --check    # Phase D: the blocks are current

The T-unit build never sees a row: everything is inside `.if wunit`.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
TAG = "WOLF FIGHTERS"

FIGHTERS = [
    # ochar, name, proxy ochar
    (20, "sonya", 4),
    (21, "sindel", 4),
    (22, "kano", 1),
    (23, "nightwolf", 1),
    (24, "rsmoke", 14),
]

# table -> {ochar: row text}.  A row text is what follows the directive
# (`.long`/`.word` is the table's own).
OVERRIDES: dict[str, dict[int, str]] = {
    # her own animation (src/UMK3SNYL.ASM, tools/make_umk3sonya_asm.py)
    "character_anitabs1": {20: "sonya_anitab1"},
    "character_anitabs2": {20: "sonya_anitab2"},
    # her costumes: SBGREEN_P, and SBLTBLU_P on Start+LP and the mirror lane
    # (Start+HP); MK3 drew her no bloodied palette, so blood rows are the same
    **{f"character_palettes_{n}": {20: "SBLTBLU_P" if n in (2, 4) else "SBGREEN_P"} for n in range(1, 8)},
    **{f"bloody_character_palettes_{n}": {20: "SBLTBLU_P" if n in (2, 4) else "SBGREEN_P"} for n in range(2, 8)},
    "bloody_palettes": {20: "SBGREEN_P,SBLTBLU_P"},
    # no specials until hers are ported: Kitana's handlers would play fan
    # lanes out of HER table 2
    **{t: {20: "sucide"} for t in ("char_hi_punch", "char_lo_punch", "char_block", "char_hi_kick",
                                    "char_lo_kick", "char_joyup", "char_joydown", "char_joyright",
                                    "char_hip_open", "char_hik_open", "char_lop_open", "char_lok_open")},
    # her own handlers (src/UMK3SNYM.ASM) - after the sucide default above
    "char_hi_punch": {20: "sny_hi_punch"},
    "char_lo_punch": {20: "sny_lo_punch"},
    "char_block": {20: "sny_block"},
    "char_hi_kick": {20: "sny_hi_kick"},
    "char_joydown": {20: "sny_down"},
    # her strike table: MK3's boxes on Kitana's layout (src/UMK3SNYL.ASM)
    "strike_tables": {20: "sonya_strikes"},
    "ochar_power_punches": {20: "0"},
    "ochar_baby_combos": {20: "0"},
}
# UMK3 SINDEL (ochar 21): her own lanes, costume, strikes, name plate, win
# line and ladder mug; no specials until hers are ported (as Sonya began)
SINDEL = {
    "character_anitabs1": "sindel_anitab1",
    "character_anitabs2": "sindel_anitab2",
    # her costumes are authored in data/MK2PALS.IMG (tools/make_sindel_palettes.py):
    # the alternate on Start+LP and Start+HP - the lane a mirror match hands
    # player 2 - and the default everywhere else.  With ONE palette on every
    # lane a Sindel mirror had nothing to give player 2.
    **{f"character_palettes_{n}": "SDP_SDALT1_P" if n in (2, 4) else "SDP_SDMAIN_P" for n in range(1, 8)},
    **{f"bloody_character_palettes_{n}": "SDP_SDBLD1_P" if n in (2, 4) else "SDP_SDBLD_P"
       for n in range(2, 8)},
    "bloody_palettes": "SDP_SDBLD_P,SDP_SDBLD1_P",
    **{t: "sucide" for t in ("char_hi_punch", "char_lo_punch", "char_block", "char_hi_kick",
                             "char_lo_kick", "char_joyup", "char_joydown", "char_joyright",
                             "char_hip_open", "char_hik_open", "char_lop_open", "char_lok_open")},
    # her own handlers (src/UMK3SDM.ASM) - after the sucide default above
    "char_hi_punch": "sd_hi_punch",
    "char_lo_punch": "sd_lo_punch",
    "char_lo_kick": "sd_lo_kick",
    "char_hi_kick": "sd_hi_kick",
    "char_block": "sd_block",
    "victory_jumps": "sd_victory",                     # she rises and hangs in the air
    "body_slam_jumps": "sd_slam",                      # MK3's lia_slam (her hair)
    "strike_tables": "sindel_strikes",
    "ochar_power_punches": "0",
    "ochar_baby_combos": "scom_fn_baby",               # Down,Down,Down + LK (sd_lo_kick)
    "p1_powerbar_names": "BAR_SINDEL,0001e001dh",      # 49x10, data/WOLFHUD.LOD
    "p2_powerbar_names": "BAR_SINDEL,0001e0141h",      # 370-49 = 321
    "winner_text": "pf_sd_win",                        # MAIN.ASM
    "winner_speech": "086h",                           # wsnd_sindel_wins (WOLFSNDE.ASM, checked below)
    "mini_mug_table": "smsnbox",                       # data/SNBOX.LOD (MOUNTAIN.IMG)
}
if not re.search(r"^wsnd_sindel_wins\s+\.set\s+086h", (SRC / "WOLFSNDE.ASM").read_text(), re.M):
    raise SystemExit("wsnd_sindel_wins is no longer 086h - update SINDEL['winner_speech']")
for _t, _v in SINDEL.items():
    OVERRIDES.setdefault(_t, {})[21] = _v

# MK1 KANO (ochar 22, Shang Tsung's morph): his own lanes and costumes and
# his three MK1 specials and his strike boxes (src/MK1KNM.ASM); everything
# else is LIU KANG's, whose lanes his were cut on
# (tools/make_mk1kano_port.py) - throw, victory - so those rows stay the proxy's
KANO = {
    "character_anitabs1": "kano_anitab1",
    "character_anitabs2": "kano_anitab2",
    **{f"character_palettes_{n}": "KANO2_P" if n in (2, 4) else "KANO1_P" for n in range(1, 8)},
    **{f"bloody_character_palettes_{n}": "KANO2_P" if n in (2, 4) else "KANO1_P" for n in range(2, 8)},
    "bloody_palettes": "KANO1_P,KANO2_P",
    **{t: "sucide" for t in ("char_hi_punch", "char_lo_punch", "char_block", "char_hi_kick",
                             "char_lo_kick", "char_joyup", "char_joydown",
                             "char_hip_open", "char_hik_open", "char_lop_open", "char_lok_open")},
    "char_joyright": "kn_lr",          # hold Block, Back, Forward: the knife
    "char_joyup": "kn_up",             # hold Block, F, D, B, U: the cannonball
    "char_lo_punch": "kn_lo_punch",    # B, D, F + LP in FINISH HIM: the heart rip
    # MK1's throw is an overhead toss, done standing: not Liu Kang's flip
    # (kang_slam is his throw SPEECH too).  The victim side is Baraka's
    # (body_slam_init, MKSLAM.ASM); his own lane is make_mk1kano_port OWN_LANES
    "body_slam_jumps": "normal_slam",
    "ochar_power_punches": "0",
    "ochar_baby_combos": "0",
    # Liu Kang's boxes, stretched to MK1 Kano's measured reach (MK1KNM.ASM)
    "strike_tables": "kano_strikes",
    # THE SECOND BATCH: the finishers' own animations, on HIS art
    # (make_mk1kano_port EXTRA, built by tools/kano_synth.py - not Liu Kang's)
    "ochar_flyin_arms": "kn_a_arm_fly",          # Jax's arm rip
    "super_frozen_poses": "kn_superf",           # Sub-Zero's deep freeze
    "frozen_legs": "kn_frozen_legs",
    "split_in_2_tab": "kn_a_split",              # Kung Lao's split
    "sucked_in_anis": "kn_a_sucked_in",          # Mileena's suck / Kahn's soul
    "ochar_pit_falls": "kn_a_pitfall",           # the Pit
    "drain_table": "kn_a_husk",                  # Shang's drain: the husk...
    "alternate_suck_pals": "KNDRAIN_P",          # ...and its palette
    "kslam_victim_poses": "kn_a_kslammed",       # Shao Kahn's slam
    "ksr_victim_poses": "kn_a_ksoulrip",         # Shao Kahn's soul rip...
    "ksr_soul_pals": "SOULGRN_KN",               # ...the soul in green
    "sz_head_ani_table": "kn_a_sz_head",         # Sub-Zero's head rip
    "sz_head_pal_table": "KANO1_P",
    "baby_images": "KNBABE",                     # the babality
    "rd_lift_vic_scripts": "kn_rd_lift_script",  # Raiden's lift
    "rd_lift_stumble1_tbl": "KNSTUMBLE1",
    "rd_lift_flipped2_tbl": "KNFLIPPED2",
    "rd_lift_bb3_tbl": "KNBACKBREAK3",
    "rd_lift_kd7_tbl": "KNKNOCKDOWN7",
}
KANO_EXTERNAL = {"kn_a_arm_fly", "kn_superf", "kn_frozen_legs", "kn_a_split", "kn_a_sucked_in",
                 "kn_a_pitfall", "kn_a_husk", "KNDRAIN_P", "kn_a_kslammed", "kn_a_ksoulrip",
                 "SOULGRN_KN", "kn_a_sz_head", "KNBABE", "kn_rd_lift_script", "KNSTUMBLE1",
                 "KNFLIPPED2", "KNBACKBREAK3", "KNKNOCKDOWN7"}
for _t, _v in KANO.items():
    OVERRIDES.setdefault(_t, {})[22] = _v


def _kano_jch(rows):
    """Cage's brain punch (jch_place, MKDEATH.ASM): Liu Kang's row moved by
    where Kano's head sits in HOLE1 against Liu Kang's - his headhole frames
    are built on Liu Kang's lane by tools/kano_synth.py.  Worked out in
    cage_brain_wax_import.kano_row; here so both tools write the same line."""
    import cage_brain_wax_import as cb
    k = cb.kano_row(-int(rows[1][0]), int(rows[1][1]))
    return f"{-k[0]},{k[1]}" if k else ",".join(rows[1])


OVERRIDES.setdefault("jch_place", {})[22] = _kano_jch


def _kano_stdc(_rows):
    """Shang's blade decap (stdc_place, MKDEATH.ASM): measured on Kano's own
    decap frame, the way st_decap_lineup measures every fighter's."""
    import st_decap_lineup
    return str(st_decap_lineup.kano_d())


OVERRIDES.setdefault("stdc_place", {})[22] = _kano_stdc

# MK3 NIGHTWOLF (ochar 23, a START tap on Liu Kang's square): his own MK3
# lanes, costumes and strike boxes (src/NWOLFL.ASM, tools/make_nightwolf_asm.py);
# everything else is LIU KANG's - the male body his thrown / victim lanes are
# copied from
NIGHTWOLF = {
    "character_anitabs1": "nightwolf_anitab1",
    "character_anitabs2": "nightwolf_anitab2",
    # MK3's own costumes (MKGUYS character_palettes_1/2): INBLU_P, and INYEL_P
    # on Start+LP and Start+HP (the mirror lane).  MK3 drew him no bloodied
    # palette, so the blood rows are the same
    **{f"character_palettes_{n}": "INYEL_P" if n in (2, 4) else "INBLU_P" for n in range(1, 8)},
    **{f"bloody_character_palettes_{n}": "INYEL_P" if n in (2, 4) else "INBLU_P" for n in range(2, 8)},
    "bloody_palettes": "INBLU_P,INYEL_P",
    **{t: "sucide" for t in ("char_hi_punch", "char_lo_punch", "char_block", "char_hi_kick",
                             "char_lo_kick", "char_joyup", "char_joydown", "char_joyright",
                             "char_hip_open", "char_hik_open", "char_lop_open", "char_lok_open")},
    # his four MK3 specials (src/NWOLFM.ASM) - after the sucide default above
    "char_hi_punch": "nw_hi_punch",      # Down, Forward: hatchet uppercut
    "char_lo_punch": "nw_lo_punch",      # Down, Back: arrow
    "char_hi_kick": "nw_hi_kick",        # Back, Back, Back: reflector
    "char_lo_kick": "nw_lo_kick",        # Forward, Forward: shoulder charge
    # ...and the same four while his own loop is "open" (switch_open_jumps):
    # with sucide there, nothing came out while the other man's projectile
    # was in the air - which is exactly when the reflector is thrown
    "char_hip_open": "nw_hi_punch",
    "char_lop_open": "nw_lo_punch",
    "char_hik_open": "nw_hi_kick",
    "char_lok_open": "nw_lo_kick",
    "strike_tables": "nightwolf_strikes",
    "ochar_power_punches": "0",
    "ochar_baby_combos": "0",
    # select / HUD art (tools/make_nightwolf.py, data/NWSEL.LOD): his plate
    # is MK2's own letters, 82x10 (370-82 = 288 = 120h for player 2)
    "p1_powerbar_names": "BAR_NIGHTWOLF,0001e001dh",
    "p2_powerbar_names": "BAR_NIGHTWOLF,0001e0120h",
    "winner_text": "pf_nw_win",                          # MAIN.ASM
    "winner_speech": "0b2h",                             # wsnd_nw_wins (WOLFSNDE.ASM, checked below)
    "mini_mug_table": "smnwbox",
}
if not re.search(r"^wsnd_nw_wins\s+\.set\s+0b2h", (SRC / "WOLFSNDE.ASM").read_text(), re.M):
    raise SystemExit("wsnd_nw_wins is no longer 0b2h - update NIGHTWOLF['winner_speech']")
for _t, _v in NIGHTWOLF.items():
    OVERRIDES.setdefault(_t, {})[23] = _v

# MK3 ROBOT SMOKE (ochar 24, a START tap on Reptile's square): his own MK3 lanes,
# costumes and strike boxes (src/RSMOKEL.ASM, tools/make_robosmoke_asm.py) and
# his four specials (src/RSMOKEM.ASM).  Everything else is NINJA SMOKE's (14):
# the male-ninja body his thrown / victim lanes are copied from, the same spear
# (projectile pids and oids, zap rows), his "SMOKE WINS", announcer line and
# BAR_SMOKE plate.  What ninja Smoke has as a HIDDEN fighter is overridden back
# to an ordinary one's: secret damage scaling, the fast boss walk, the flip
# damage, and a shadow on his victory.
RSMOKE = {
    "character_anitabs1": "rsmoke_anitab1",
    "character_anitabs2": "rsmoke_anitab2",
    # MK3's own costumes (MKGUYS character_palettes_1/2): SMOKE1_P, and SMOKE2_P
    # on Start+LP and Start+HP (the mirror lane).  MK3 drew him no bloodied
    # palette, so the blood rows are the same
    **{f"character_palettes_{n}": "SMOKE2_P" if n in (2, 4) else "SMOKE1_P" for n in range(1, 8)},
    **{f"bloody_character_palettes_{n}": "SMOKE2_P" if n in (2, 4) else "SMOKE1_P" for n in range(2, 8)},
    "bloody_palettes": "SMOKE1_P,SMOKE2_P",
    **{t: "sucide" for t in ("char_hi_punch", "char_lo_punch", "char_block", "char_hi_kick",
                             "char_lo_kick", "char_joyup", "char_joydown", "char_joyright",
                             "char_hip_open", "char_hik_open", "char_lop_open", "char_lok_open")},
    # his MK3 specials (src/RSMOKEM.ASM) - after the sucide default above
    "char_hi_punch": "rs_hi_punch",      # hold Block, Up, Up: invisibility
    "char_lo_punch": "rs_lo_punch",      # Back, Back: the spear
    "char_lo_kick": "rs_lo_kick",        # Forward, Forward: teleport uppercut
    "char_block": "rs_block",            # in the air: the air throw (else the pit)
    "char_hip_open": "rs_hi_punch",
    "char_lop_open": "rs_lo_punch",
    "char_lok_open": "rs_lo_kick",
    "strike_tables": "rsmoke_strikes",   # the ninjas' layout: 11h is stk_njspear
    "ochar_power_punches": "0",
    "ochar_baby_combos": "0",
    "ochar_damage_table": "0",           # not xlate_secret: he is a pick, not a boss
    "walk_forward_info": "5,02800h",     # an ordinary ninja's walk (Reptile's row)
    "walk_backward_info": "6,02000h",
    "flip_damage_table": "34",
    "victory_jumps": "generic_victory",  # smoke_victory drops the shadow
    "mini_mug_table": "smrsbox",
}
for _t, _v in RSMOKE.items():
    OVERRIDES.setdefault(_t, {})[24] = _v

# symbols an override names that live in another object: the block .ref's them
EXTERNAL = {"rs_hi_punch", "rs_lo_punch", "rs_lo_kick", "rs_block", "rsmoke_anitab1", "rsmoke_anitab2",
            "rsmoke_strikes", "SMOKE1_P", "SMOKE2_P", "smrsbox",
            "nw_hi_punch", "nw_lo_punch", "nw_hi_kick", "nw_lo_kick", "BAR_NIGHTWOLF", "smnwbox", "nightwolf_anitab1", "nightwolf_anitab2", "nightwolf_strikes", "INBLU_P", "INYEL_P","kano_anitab1", "kano_anitab2", "kano_strikes", "KANO1_P", "KANO2_P", "kn_lr", "kn_up", "kn_lo_punch",
            "sindel_anitab1", "sindel_anitab2", "LPRP_P", "SDP_SDMAIN_P", "SDP_SDALT1_P", "SDP_SDBLD_P", "SDP_SDBLD1_P", "sindel_strikes",
            "sd_hi_punch", "sd_lo_punch", "sd_lo_kick", "sd_hi_kick", "sd_block", "sd_victory", "sd_slam",
            "sonya_anitab1", "sonya_anitab2", "SBGREEN_P", "SBLTBLU_P", "sonya_strikes",
            "sny_hi_punch", "sny_lo_punch", "sny_block",
            "sny_hi_kick", "sny_down"}
EXTERNAL |= KANO_EXTERNAL      # MK1 Kano's second batch (src/MK1KNL.ASM)

# ---------------------------------------------------------------------------
# which tables, and how wide a row is - tools/audit_char_tables.py owns this
# ---------------------------------------------------------------------------
def audit_lists():
    src = (ROOT / "tools" / "audit_char_tables.py").read_text(encoding="utf-8")
    head = src.split("\ndef load(")[0]
    ns = {"__file__": str(ROOT / "tools" / "audit_char_tables.py")}
    exec(head, ns)
    return ns["TABLES"], ns["WORD_TABLES"], ns["PAIR_TABLES"], ns["QUAD_TABLES"]


SKIP = {"char_joyleft",            # second label on char_joyright
        "db1_table", "db2_table"}  # gated to ochar 0-11


# ---------------------------------------------------------------------------
# a small model of GSPA's conditional assembly
# ---------------------------------------------------------------------------
NUM = re.compile(r"(?<![\w>])(>[0-9a-fA-F]+|[0-9][0-9a-fA-F]*[hH]|\d+)(?!\w)")


def to_py(expr: str) -> str:
    def num(m):
        t = m.group(1)
        if t.startswith(">"):
            return str(int(t[1:], 16))
        if t[-1] in "hH":
            return str(int(t[:-1], 16))
        return t
    e = NUM.sub(num, expr)
    e = e.replace("<>", "!=").replace("!", " not ") if "!=" not in e else e
    e = re.sub(r"(?<![=!<>])=(?!=)", "==", e)
    return e


def load_env(wunit: int):
    env = {}
    defs = []
    for p in sorted(SRC.glob("*")):
        if p.suffix.upper() not in (".ASM", ".H", ".EQU", ".HDR"):
            continue
        for ln in p.read_text(encoding="latin-1").splitlines():
            m = re.match(r"^([A-Za-z_]\w*)\s+\.(set|equ)\s+([^;]+)", ln)
            if m:
                defs.append((m.group(1), m.group(3).strip()))
    for _ in range(6):                         # resolve forward references
        for n, e in defs:
            if n in env:
                continue
            try:
                env[n] = int(eval(to_py(e), {"__builtins__": {}}, env))
            except Exception:
                pass
    env["wunit"] = wunit
    return env


def truth(expr: str, env) -> bool:
    try:
        return bool(eval(to_py(expr.split(";")[0].strip()), {"__builtins__": {}}, env))
    except Exception as ex:
        raise SystemExit(f"cannot evaluate .if {expr!r}: {ex}")


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------
DATA = re.compile(r"^\s*\.(long|word)\s+([^;]*?)\s*(;.*)?$")
DIRECTIVE = re.compile(r"^\s*\.(if|else|endif)\b\s*(.*)$", re.I)


def find_def(name, files):
    for p, lines in files.items():
        for i, ln in enumerate(lines):
            if ln and ln[0] not in " \t*;" and re.match(re.escape(name) + r"\b", ln):
                return p, i
    return None, None


def table_extent(lines, i):
    """Physical lines [i+1, end) of the table whose label is on line i - the
    audit's rule: it ends at a new label or an instruction."""
    j = i + 1
    rest = lines[i][len(re.match(r"\w+", lines[i]).group(0)):]
    first_inline = bool(DATA.match(rest))
    while j < len(lines):
        ln = lines[j]
        s = ln.strip()
        if not s or s.startswith(";") or s.startswith("*"):
            j += 1
            continue
        if DATA.match(ln) or DIRECTIVE.match(ln):
            j += 1
            continue
        if re.match(r"^[A-Za-z_]\w*", ln):
            break
        if re.match(r"^\s+[a-z]", ln):
            break
        j += 1
    return first_inline, j


def strip_blocks(lines):
    """The file's lines with every generated block taken out."""
    out, skip = [], False
    for ln in lines:
        d = DIRECTIVE.match(ln)
        if d and TAG in ln and d.group(1).lower() == "if":
            skip = True
            continue
        if skip:
            if d and TAG in ln and d.group(1).lower() == "endif":
                skip = False
            continue
        out.append(ln)
    return out


def items(lines, a, b, env, label_line):
    """Effective (kind, token) items of the table on lines [a, b), its
    conditionals evaluated - and the last physical line the table uses."""
    # `last` is the last DATA line, extended only over the .else/.endif lines
    # that close a block OPENED inside the table - an `.if` that merely
    # follows the table (MKSTK's `.if stkphase`) is not part of it, and a row
    # placed after it lands inside somebody else's conditional
    out, stack, last = [], [], None      # stack of [live, outer_live]
    depth_at_last = 0
    rest = label_line[len(re.match(r"\w+", label_line).group(0)):]
    m = DATA.match(rest)
    if m:
        out += [(m.group(1), t.strip()) for t in m.group(2).split(",") if t.strip()]
    for k in range(a, b):
        ln = lines[k]
        d = DIRECTIVE.match(ln)
        if d:
            kw = d.group(1).lower()
            outer = all(x[0] for x in stack)
            if kw == "if":
                stack.append([outer and truth(d.group(2), env), outer])
            elif kw == "else":
                live, o = stack[-1]
                stack[-1] = [o and not live, o]
                if len(stack) <= depth_at_last:
                    last = k
            else:
                if len(stack) <= depth_at_last:
                    last = k
                    depth_at_last = len(stack) - 1
                stack.pop()
            continue
        m = DATA.match(ln)
        if m:
            if all(x[0] for x in stack):
                out += [(m.group(1), t.strip()) for t in m.group(2).split(",") if t.strip()]
            last = k
            depth_at_last = len(stack)
    return out, last


def rows_of(name, its, lists):
    _t, words, pairs, quads = lists
    kinds = {k for k, _ in its}
    kind = "long" if kinds == {"long"} else "word" if kinds == {"word"} else None
    if kind is None:
        raise SystemExit(f"{name}: mixes .long and .word")
    w = 4 if name in quads else 2 if name in pairs else 1
    if name not in words and name not in pairs and name not in quads and kind == "word":
        w = 2      # the audit's rule: an unlisted .word table is 2 words a row
    toks = [t for _k, t in its]
    if len(toks) % w:
        raise SystemExit(f"{name}: {len(toks)} items is not a whole number of {w}-wide rows")
    return kind, [toks[i:i + w] for i in range(0, len(toks), w)]


def plan():
    lists = audit_lists()
    tables, words, _pairs, _quads = lists
    env = load_env(1)
    files = {p: strip_blocks(p.read_text(encoding="latin-1").splitlines()) for p in sorted(SRC.glob("*.ASM"))}
    out = []
    for name in dict.fromkeys(tables + words):
        if name in SKIP:
            continue
        p, i = find_def(name, files)
        if p is None:
            continue
        lines = files[p]
        _fi, end = table_extent(lines, i)
        its, last = items(lines, i + 1, end, env, lines[i])
        kind, rows = rows_of(name, its, lists)
        out.append(dict(name=name, path=p, label=i, end=end, last=last, kind=kind, rows=rows))
    return out


def block(name, kind, rows):
    """The generated block for one table, given its 20 rows as token lists.
    Tools that GENERATE a char-indexed table (cage_brain_wax_import,
    make_soulrip_pals, subspine_wax_import) call this so their output already
    carries the Wolf rows, exactly as this tool would write them."""
    return block_for(dict(name=name, kind=kind, rows=rows))


def block_for(t):
    # a table already longer than 20 rows carries rows past the last real
    # fighter (copies of row 0, mostly) - those serve, and are left alone
    if len(t["rows"]) != 20:
        return None
    # ONE data line and at most one .ref per table, short comments: MOVES.ASM
    # assembles at GSPA's ceiling on the Wolf pass, and a second fighter's
    # row per table (17 tables, a line each) was enough to abort it with
    # ">> Out of memory" - the same cliff MKDRONE sits on
    nl = []
    nl.append(f"\t.if\twunit\t; {TAG}")
    texts, exts, notes = [], [], []
    for oc, nm, proxy in FIGHTERS:
        ov = OVERRIDES.get(t["name"], {}).get(oc)
        if callable(ov):               # a row worked out from the table's own rows
            ov = ov(t["rows"])
        texts.append(ov if ov is not None else ",".join(t["rows"][proxy]))
        exts += [x for x in re.findall(r"\w+", ov or "") if x in EXTERNAL and x not in exts]
        notes.append(f"{oc} {nm}" + ("" if ov is not None else f"={proxy}"))
    if exts:
        nl.append("\t.ref\t" + ",".join(exts))
    nl.append(f"\t.{t['kind']}\t{','.join(texts)}\t; {', '.join(notes)}")
    nl.append(f"\t.endif\t\t; {TAG}")
    return nl


def apply(ts, write):
    stale = []
    by_file = {}
    for t in ts:
        by_file.setdefault(t["path"], []).append(t)
    for p in sorted(by_file):
        raw = p.read_bytes().decode("latin-1")
        eol = "\r\n" if "\r\n" in raw else "\n"
        lines = strip_blocks(raw.splitlines())
        for t in sorted(by_file[p], key=lambda t: -t["last"]):
            blk = block_for(t)
            if blk is not None:
                lines[t["last"] + 1:t["last"] + 1] = blk
        new = eol.join(lines) + (eol if raw.endswith("\n") else "")
        if new != raw:
            stale.append(p.name)
            if write:
                p.write_text(new, encoding="latin-1", newline="")
    return stale


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every table")
    a = ap.parse_args()
    ts = plan()
    bad = [t for t in ts if len(t["rows"]) < 20 + len(FIGHTERS)  and len(t["rows"]) != 20]
    for t in ts if a.verbose or not (a.apply or a.check) else []:
        flag = "" if len(t["rows"]) == 20 else "   (already longer - left alone)"
        print(f"{t['name']:28} {t['path'].name:14} {t['kind']:4} x{len(t['rows'][0]) if t['rows'] else 0} "
              f"{len(t['rows']):3} rows{flag}")
    print(f"{len(ts)} tables, {len(bad)} too short for the Wolf fighters")
    if a.apply:
        print("wrote:", ", ".join(apply(ts, True)) or "nothing")
    if a.check:
        st = apply(ts, False)
        if st or bad:
            raise SystemExit(f"stale: {st}  not-20: {[t['name'] for t in bad]}")
        print("Wolf fighter rows are current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
