#!/usr/bin/env python3
r"""THE COSTUME PALETTES, OUT OF `data/MK2PALS.IMG` AND ONTO THE SEVEN LANES.

`data/MK2PALS.IMG` is the hand-authored palette workbench (see
[[reference_mk2pals_img_is_a_workbench]]).  It now carries a COMPLETE costume
set under one naming scheme, and this tool is what makes that scheme reach the
ROM: it reads the library, writes every wired palette into `src/COSTPAL.ASM`,
and repoints the costume and blood tables in `src/MKGUYS.ASM` to them.

THE SCHEME.  Per fighter, a two-letter code, then the slot:

    <XX>MAIN_P  <XX>BLD_P      the default costume and its bloodied twin
    <XX>ALT1_P  <XX>BLD1_P     START + HIGH PUNCH
    <XX>ALT2_P  <XX>BLD2_P     START + LOW PUNCH
    <XX>ALT3_P  <XX>BLD3_P     START + HIGH KICK
    <XX>ALT4_P  <XX>BLD4_P     START + LOW KICK
    <XX>ALT5_P  <XX>BLD5_P     START + BLOCK

Those six lanes already exist in MKGUYS.ASM as `character_palettes_N` /
`bloody_character_palettes_N`, so the mapping is 1:1 and no table moves:

    lane          costume table            blood table
    default       character_palettes_1     bloody_palettes  (column 0)
    START+HP      character_palettes_4     bloody_character_palettes_4
    START+LP      character_palettes_2     bloody_character_palettes_2
    START+HK      character_palettes_5     bloody_character_palettes_5
    START+LK      character_palettes_6     bloody_character_palettes_6
    START+BLOCK   character_palettes_3     bloody_character_palettes_3

`character_palettes_7` (START+COIN) follows `costcoin` (MAINEQU.ASM): at 1 it
is the seventh lane, fed by `ALT6_P` / `BLD6_P` (no record = the default, as
on every lane - Kitana's BIV hue cycle was retired 2026-10-06); at 0 both rows are
flattened to the default and `ALT6`/`BLD6` records are reported as unwired.

**THE GENERATED SYMBOLS ARE PREFIXED `KP_`, AND THAT IS NOT COSMETIC.**  Six of
the IMG's names ALREADY EXIST in `src/` as DIFFERENT palettes - the library's
`LKALT3_P` differs from the linked symbol of that name by 56 entries of 64 -
and two more collide only by CASE with the ninja blood palettes (`RPBLD1_P`
against `RPBLD1_p`).  Emitting the IMG names verbatim would either fail the
link or, worse, quietly resolve a costume row to the wrong palette.  So every
record is emitted as `KP_<record name>` and the generated file names the record
each one came from, the way IMGPAL6.ASM does for Khameleon's carry.

FALLBACKS, and they are the user's rule:

  * a BLOOD slot with no record falls back to that fighter's `<XX>BLD_P`; if he
    has no `BLD_P` either, the row is LEFT ALONE.
  * a COSTUME slot with no record LEAVES THAT ROW ALONE.  Nothing is invented
    and no lane loses the palette it has today - the report is the worklist.

WHO IS NOT IN IT, and why each is a deliberate hole:

  * Kintaro (12) and Shao Kahn (13) - CPU bosses, no costume management.
  * Smoke (14) - CPU only in this build (his select cheat is compiled out).
  * Khameleon (18) - every one of her seven lanes has to resolve to the SAME
    palette id, because `kham_disguise_pal_proc` rewrites the contents of
    whatever map `KHMAIN_P` allocated.  A Start+button alternate would defeat
    the disguise cycle, so her `KHALT1-4_P` are payloads, not costumes.
  * `RB*` - not a fighter (a prop/effect set), per the user 2026-09-26.
  * `SB*` - superseded by the complete `SZ*` set; `SBALT4_P` and `SZALT4_P`
    both claimed START+LK and SZ won.
  * `M2*` - owned by tools/make_mk2pals.py, which has its own Phase D check.

DEATH FADE.  Every costume palette a fighter can WEAR has to be in
`death_fade_excludes` or he dims while the stage fades (the 2026-09-08 Ermac
defect; `tools/audit_fade_excludes.py` is the gate).  Costume palettes are
therefore always added.  BLOOD palettes are added for the fighters in
`BLOOD_STAYS_LIT` only, which keeps today's behaviour: the ninja-bodied ones
stay lit while cut up and the stock ones still dim, as retail does.  That set
is AUTHORED, not computed - see its comment; deriving it from "was the palette
this row replaced excluded?" reads state this tool then destroys, and a second
`--apply` would drop the exclusions again.

    python tools/make_costume_palettes.py            # report, write nothing
    python tools/make_costume_palettes.py --matrix   # + the per-fighter grid
    python tools/make_costume_palettes.py --apply    # write COSTPAL.ASM + MKGUYS
    python tools/make_costume_palettes.py --check    # Phase D: fail on drift
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                            # noqa: E402

REPO = Path(__file__).resolve().parent.parent
IMG = REPO / "data" / "MK2PALS.IMG"
ASM_OUT = REPO / "src" / "COSTPAL.ASM"
MKGUYS = REPO / "src" / "MKGUYS.ASM"

SYM = "KP_"                     # see the docstring - collisions are real
NL = "\n"                       # src/ is LF; see write_same_endings()
ROWS = 20                       # every char-indexed table is 20 rows (ft_rain=19)

# ochar -> (code, fighter).  Holes are deliberate; see the docstring.
ROSTER = {
    0:  ("KL", "kung lao"),
    1:  ("LK", "liu kang"),
    2:  ("JC", "johnny cage"),
    3:  ("UG", "baraka"),
    4:  ("KT", "kitana"),
    5:  ("ML", "mileena"),
    6:  ("ST", "shang tsung"),
    7:  ("RD", "raiden"),
    8:  ("SZ", "sub-zero"),
    9:  ("RP", "reptile"),
    10: ("SC", "scorpion"),
    11: ("JX", "jax"),
    15: ("NS", "noob saibot"),
    16: ("JD", "jade"),
    17: ("ER", "ermac"),
    19: ("RN", "rain"),
}

SKIPPED_OCHAR = {
    12: "kintaro - CPU boss, no costume management",
    13: "shao kahn - CPU boss, no costume management",
    14: "smoke - CPU only in this build",
    18: "khameleon - all seven lanes must be the one KHMAIN_P id (disguise cycle)",
}

SKIPPED_PREFIX = {
    "RB": "not a fighter - a prop/effect set (user, 2026-09-26)",
    "SB": "superseded by the complete SZ set (SZALT4_P won START+LK)",
    "M2": "owned by tools/make_mk2pals.py",
}

# codes whose fighter is in SKIPPED_OCHAR: they are real records for a real
# fighter, just one this tool does not wire.  Reported with the fighter's
# reason, not as an unknown code.
SKIPPED_CODE = {"SM": 14, "KH": 18}

# WHOSE BLOOD PALETTES STAY LIT THROUGH THE FADE.  This is authored data, and
# it has to be: the honest test is "was the palette this row REPLACED in
# death_fade_excludes", and that palette is GONE after the first --apply, so
# computing it makes the tool non-idempotent - a second --apply would quietly
# drop the exclusions and start dimming fighters who do not dim today.
#
# These four are the fighters whose blood rows are excluded RIGHT NOW, so
# listing them preserves exactly today's behaviour:
#
#   4  kitana    - bloody_character_palettes_2 held KATSILV_P, a CLEAN costume
#                  ("no bloodied KATSILV exists"), which is excluded, so she
#                  stayed lit while cut up in that lane
#   8  sub-zero  - the same for SBUMK2_P, plus SZBLD1_p in bloody_palettes
#   9  reptile   - RPUMK2_P / RPBLD1_p
#   10 scorpion  - SCUMK2_P / SCBLD1_p
#
# Ermac (17) and Rain (19) belong here too the day their BLD_P is authored -
# their rows still hold the excluded RNBLD1_p / ERBLD1_p and are untouched
# until then.  The report warns when a fighter outside this set is about to
# lose an exclusion, so the choice is surfaced rather than taken silently.
#
# Empty this set to make all eighteen behave like retail's twelve, which dim
# while bloodied (MKGUYS.ASM says as much beside the five ninja entries).
BLOOD_STAYS_LIT = {4, 8, 9, 10}

# lane order is the order a costume is offered in: default, then ALT1..ALT5.
# (slot, costume table, blood slot, blood table, what the player presses)
LANES = [
    ("MAIN", "character_palettes_1", "BLD",  "bloody_palettes",             "default"),
    ("ALT1", "character_palettes_4", "BLD1", "bloody_character_palettes_4", "START+HP"),
    ("ALT2", "character_palettes_2", "BLD2", "bloody_character_palettes_2", "START+LP"),
    ("ALT3", "character_palettes_5", "BLD3", "bloody_character_palettes_5", "START+HK"),
    ("ALT4", "character_palettes_6", "BLD4", "bloody_character_palettes_6", "START+LK"),
    ("ALT5", "character_palettes_3", "BLD5", "bloody_character_palettes_3", "START+BLOCK"),
]

# START+COIN IS DISABLED (user, 2026-09-27).  It is in no ALTn slot and is not
# a costume lane any more: `costcoin .set 0` (MAINEQU.ASM) stops the select
# screen claiming it at all, and these two rows are flattened to the fighter's
# DEFAULT so nothing can come out of them even from a stale claim.
#
# Flattening the data is NOT enough on its own and that is worth knowing: with
# the claim still live, inserting a coin would claim a lane whose palette
# equals the player's default, the no-duplicate rule would find player 1
# already wearing it, and the coin would SHIFT player 2 onto ALT1 - a disabled
# button that changes your costume.  The switch is what actually disables it.
#
COIN = ("character_palettes_7", "bloody_character_palettes_7", "START+COIN")

# `costcoin .set 1` (MAINEQU.ASM) makes START+COIN a lane again, and then the
# library's SIXTH slot feeds it: ALT6 -> character_palettes_7, BLD6 -> its
# blood twin, by the same rule as the other six (no record = his default).
# The tool reads the switch, so the build and the tables cannot disagree.
MAINEQU = Path(__file__).resolve().parent.parent / "src" / "MAINEQU.ASM"
_cc = re.search(r"^costcoin\s+\.set\s+(\d+)", MAINEQU.read_text(encoding="latin-1"), re.M)
if not _cc:
    raise SystemExit("costcoin .set not found in src/MAINEQU.ASM")
COSTCOIN = int(_cc.group(1))
if COSTCOIN:
    LANES.append(("ALT6", COIN[0], "BLD6", COIN[1], COIN[2]))

# A coin lane with no ALT6 record of its own keeps THESE instead of the default.
# Empty since 2026-10-06: Kitana's BIV1_P hue-cycle anchor was retired with
# `kitana_biv_pal_proc`, so her coin lane takes her default like anybody's.
COIN_KEEP = {}

# PALETTES CARRIED BY NAME, not by the lane scheme.  A move's palette is not a
# costume - it has no lane, no blood twin and no table row - but it has the same
# problem the costume set has: data/MK2PALS.IMG is in NO LOD, so a repaint in
# IMGTOOL reaches nothing until a tool carries it, and a hand-carried copy in
# IMGPAL*.ASM silently ships last week's colours.  Naming one here puts it in
# src/COSTPAL.ASM and under Phase D's --check with everything else.
#
# These get NO table row and NO death_fade_excludes entry: whoever uses the
# palette decides that, and the palette being replaced here was not excluded
# either (matching it rather than changing fade behaviour unasked).
CARRY = {
    "JDKIK_P": "Jade's Blazing Nitro Kick - do_fn1_nitro, MOVES.ASM",
    "JCSHAD_P": "Cage's shadow trail on START+BLOCK (JCALT5_P) - trail_proc, MKFX.ASM",
}

RECORD = re.compile(r"^([A-Z]{2})(MAIN|ALT([1-9])|BLD|BLD([1-9]))_P$")

REF_BEGIN = "*  >>> GENERATED by tools/make_costume_palettes.py - costume palette refs"
REF_END   = "*  <<< END GENERATED costume palette refs"
FADE_BEGIN = "*  >>> GENERATED by tools/make_costume_palettes.py - costume fade excludes"
FADE_END   = "*  <<< END GENERATED costume fade excludes"


# ---------------------------------------------------------------------------
# the library
# ---------------------------------------------------------------------------
def read_img():
    """-> (claims, orphans, dup_names).

    claims: (ochar, slot) -> (img record name, words)
    LOAD2 resolves a duplicate name to the LAST match, so this does too.
    """
    recs = ip.palettes(IMG)
    seen: dict[str, list] = {}
    for name, words in recs:
        seen.setdefault(name, []).append(words)
    dup_names = sorted(n for n, v in seen.items() if len(v) > 1)

    by_code = {code: och for och, (code, _) in ROSTER.items()}
    claims: dict[tuple, tuple] = {}
    orphans: list[tuple[str, str]] = []
    clash: list[str] = []

    for name in dict.fromkeys(n for n, _ in recs):        # file order, once each
        words = seen[name][-1]                            # last wins
        if name in CARRY:
            continue                    # carried by name - see CARRY
        m = RECORD.match(name)
        if not m:
            orphans.append((name, "not in the <XX>MAIN/ALTn/BLDn_P scheme"))
            continue
        code, slot = m.group(1), m.group(2)
        if code in SKIPPED_PREFIX:
            orphans.append((name, SKIPPED_PREFIX[code]))
            continue
        if code in SKIPPED_CODE:
            orphans.append((name, SKIPPED_OCHAR[SKIPPED_CODE[code]]))
            continue
        if code not in by_code:
            orphans.append((name, "unknown fighter code %r" % code))
            continue
        och = by_code[code]
        if slot not in {s for lane in LANES for s in (lane[0], lane[2])}:
            orphans.append((name, "no lane uses slot %s" % slot))
            continue
        key = (och, slot)
        if key in claims and claims[key][0] != name:
            clash.append("%s and %s both claim %s %s"
                         % (claims[key][0], name, code, slot))
            continue
        claims[key] = (name, words)

    if clash:
        raise SystemExit("MK2PALS.IMG: two records claim one lane:\n  "
                         + "\n  ".join(clash))
    by_name = {n: seen[n][-1] for n in seen}
    return claims, orphans, dup_names, by_name


# ---------------------------------------------------------------------------
# MKGUYS.ASM: reading the tables, and rewriting the rows we own
# ---------------------------------------------------------------------------
LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*$")


def table_row_lines(lines: list[str], label: str) -> list[int]:
    """Line indices of the ROWS.length `.long` rows under `label`, in order.

    Stops at the next column-0 label, so a short table is an error rather than
    a silent read into the table below it.
    """
    start = None
    for i, ln in enumerate(lines):
        m = LABEL.match(ln)
        if m and m.group(1) == label:
            start = i + 1
            break
    if start is None:
        raise SystemExit("%s: no such table in %s" % (label, MKGUYS.name))
    rows = []
    for i in range(start, len(lines)):
        ln = lines[i]
        if LABEL.match(ln) and not ln.lstrip().startswith((";", "*")):
            break
        if ln.lstrip().startswith(".long"):
            rows.append(i)
            if len(rows) == ROWS:
                break
    if len(rows) != ROWS:
        raise SystemExit("%s: found %d rows, expected %d"
                         % (label, len(rows), ROWS))
    return rows


def row_symbols(lines: list[str], label: str) -> list[list[str]]:
    """The symbols each row of `label` currently holds."""
    out = []
    for i in table_row_lines(lines, label):
        body = lines[i].split(".long", 1)[1]
        body = body.split(";")[0]
        out.append([c.strip() for c in body.split(",") if c.strip()])
    return out


def resolve(claims: dict, live_default: dict, live_default_blood: dict,
            claims_by_name: dict) -> tuple[dict, list, list, list]:
    """-> (plan, gaps, used)

    plan: (table label, ochar) -> (new symbol, provenance, comment tail)
    gaps: the lanes with no record of their own, and what they fell back to
    used: [(generated symbol, img record, words)] in a stable order

    A LANE WITH NO RECORD OF ITS OWN TAKES THE FIGHTER'S DEFAULT, costume and
    blood alike - his own `<XX>MAIN_P` / `<XX>BLD_P` when the library carries
    one, otherwise whatever `character_palettes_1` / `bloody_palettes` column 0
    already point at (`live_default`, `live_default_blood`).

    NEVER the palette that lane happens to hold, and that is the whole point.
    Five fighters had a CLEAN COSTUME sitting in a blood row - Rain's
    Start+HK/LK/Block were all SUBALT4_P and Ermac's Start+LP was ERUMK2_P - so
    being cut up on those lanes left them looking untouched, the same defect
    the NINJAS11 blood palettes were authored to fix.  The costume side had the
    same shape of problem: a lane left alone kept a palette that has nothing to
    do with the fighter's current set.

    A button that falls back to the default LOOKS like it does nothing, which
    is correct - and if the other player is already wearing that default, the
    no-duplicate rule (costume_pal_a0, MKGUYS.ASM) rolls player 2 forward to
    the next open lane, so he still gets a costume of his own.
    """
    plan: dict[tuple, tuple] = {}
    gaps: list[str] = []
    used: dict[str, tuple] = {}

    def take(slot, och):
        """the library's palette for one slot, registering it for COSTPAL.ASM"""
        got = claims.get((och, slot))
        if not got:
            return None
        sym = SYM + got[0]
        used[sym] = (got[0], got[1])
        return sym, got[0]

    for och in sorted(ROSTER):
        code, who = ROSTER[och]
        # his default pair, resolved once
        cd = take("MAIN", och)
        bd = take("BLD", och)
        dflt_cos = cd[0] if cd else live_default.get(och)
        dflt_bld = bd[0] if bd else live_default_blood.get(och)

        for slot, ctab, bslot, btab, press in LANES:
            tail = "%-2d %-12s%-12s" % (och, who, press)
            got = take(slot, och)
            keep = COIN_KEEP.get(och) if ctab == COIN[0] else None
            if not got and keep:
                plan[(ctab, och)] = (keep[0], "no %s%s_P - kept (COIN_KEEP)"
                                     % (code, slot), tail)
            elif got:
                plan[(ctab, och)] = (got[0], got[1], tail)
            elif dflt_cos:
                plan[(ctab, och)] = (dflt_cos, "no %s%s_P - his default"
                                     % (code, slot), tail)
                gaps.append("%-12s %-11s %-5s costume  - his default"
                            % (who, press, slot))
            else:
                gaps.append("%-12s %-11s %-5s costume  - NO DEFAULT EITHER"
                            % (who, press, slot))

            bgot = take(bslot, och)
            if not bgot and keep:
                plan[(btab, och)] = (keep[1], "no %s%s_P - kept (COIN_KEEP)"
                                     % (code, bslot), tail)
            elif bgot:
                plan[(btab, och)] = (bgot[0], bgot[1], tail)
            elif dflt_bld:
                plan[(btab, och)] = (dflt_bld, "no %s%s_P - his default blood"
                                     % (code, bslot), tail)
            else:
                gaps.append("%-12s %-11s %-5s blood    - NO DEFAULT EITHER"
                            % (who, press, bslot))

        if COSTCOIN:
            continue                    # START+COIN is a lane - done above
        # START+COIN is disabled - both of its rows are the default
        ctab, btab, press = COIN
        tail = "%-2d %-12s%-12s" % (och, who, press)
        if dflt_cos:
            plan[(ctab, och)] = (dflt_cos, "DISABLED - his default", tail)
        if dflt_bld:
            plan[(btab, och)] = (dflt_bld, "DISABLED - his default blood", tail)

    order = [(s, *used[s]) for s in sorted(used)]
    carried = []
    for rec, why in sorted(CARRY.items()):
        got = claims_by_name.get(rec)
        if got is None:
            gaps.append("%-12s %-11s %-5s CARRY    - %s is not in the library"
                        % ("(carried)", "-", "-", rec))
            continue
        carried.append((SYM + rec, rec, got, why))
    return plan, gaps, order, carried


def new_row(sym: str, rec: str, tail: str, old: list[str], two_col: bool) -> str:
    """One replacement `.long` line.  `bloody_palettes` rows carry a second
    long that no code reads (change_to_bloody_pal takes column 0); it is kept
    byte for byte rather than dropped."""
    cell = sym if not two_col else "%s,%s" % (sym, old[1])
    # `rec` is an IMG record name, or a sentence when the row is a fallback
    sep = "<-" if rec.endswith("_P") and " " not in rec else "  "
    return "\t.long\t%-20s ; %s %s %s" % (cell, tail, sep, rec)


def apply_tables(text: str, plan: dict, order: list, fade_add: list) -> str:
    lines = text.split("\n")

    # 1. the rows
    for label in dict.fromkeys(t for t, _ in plan):
        two_col = (label == "bloody_palettes")
        idx = table_row_lines(lines, label)
        cur = row_symbols(lines, label)
        for och in range(ROWS):
            key = (label, och)
            if key not in plan:
                continue
            sym, rec, tail = plan[key]
            lines[idx[och]] = new_row(sym, rec, tail, cur[och], two_col)

    text = "\n".join(lines)

    # 2. the .ref block
    refs = ["*",
            "*  The costume palettes, generated into src/COSTPAL.ASM out of",
            "*  data/MK2PALS.IMG.  Prefixed KP_ because six of the library's",
            "*  names already exist in src/ as DIFFERENT palettes - see the",
            "*  tool's docstring.  Re-run the tool after every repaint.",
            "*"]
    for sym, rec, _ in order:
        refs.append("\t.ref\t%-16s; MK2PALS.IMG record %s" % (sym, rec))
    text = replace_block(text, REF_BEGIN, REF_END, refs, anchor="\t.text\n")

    # 3. the fade excludes
    fade = ["*",
            "*  COSTUME PALETTES FROM data/MK2PALS.IMG.  A palette a fighter can",
            "*  WEAR has to be here or he dims while the stage fades.  A BLOOD",
            "*  palette is here only when the one it replaced was, so the five",
            "*  ninja-bodied fighters behave as they did and the twelve stock",
            "*  ones still dim while cut up, as retail does.",
            "*"]
    for sym, why in fade_add:
        fade.append("\t.long\t%-16s; %s" % (sym, why))
    return replace_block(text, FADE_BEGIN, FADE_END, fade,
                         anchor="\t.long\t0\n")


def replace_block(text: str, begin: str, end: str, body: list[str],
                  anchor: str) -> str:
    """Replace the begin..end block, or insert it before `anchor` the first
    time.  `anchor` is matched ONCE and must be unique."""
    block = "\n".join([begin] + body + [end]) + "\n"
    if begin in text:
        head, rest = text.split(begin, 1)
        _, tail = rest.split(end, 1)
        return head + block.rstrip("\n") + tail
    if text.count(anchor) != 1:
        raise SystemExit("anchor %r appears %d times in %s - cannot insert %s"
                         % (anchor, text.count(anchor), MKGUYS.name, begin))
    head, tail = text.split(anchor, 1)
    return head + block + anchor + tail


# ---------------------------------------------------------------------------
# src/COSTPAL.ASM
# ---------------------------------------------------------------------------
def build_asm(order: list, carried: list) -> str:
    out = [
        "; GENERATED by tools/make_costume_palettes.py - do not edit by hand.",
        "; The costume palettes out of data/MK2PALS.IMG, on the six lanes",
        "; MKGUYS.ASM offers: default and START + HP / LP / HK / LK / BLOCK.",
        ";",
        "; Every symbol is the IMG record name prefixed KP_.  The prefix is",
        "; load-bearing: LKALT3_P, LKALT4_P, JCALT1_P, JCALT2_P, JCALT3_P and",
        "; KHMAIN_P already exist in src/ as DIFFERENT palettes, and RPBLD1_P /",
        "; SCBLD1_P collide with RPBLD1_p / SCBLD1_p by case alone.",
        "\t.FILE \"costpal.asm\"",
        "\t.OPTION B,D,L,T",
        "",
    ]
    for sym, rec, _ in order:
        out.append("\t.globl\t%s" % sym)
    for sym, rec, _, _ in carried:
        out.append("\t.globl\t%s" % sym)
    out += ["\t.DATA", "\t.even", ""]
    if carried:
        out += [
            "; ---- carried by NAME, not by the lane scheme ----",
            "; A move's palette: no lane, no blood twin, no table row.  It is",
            "; here for the same reason the costumes are - data/MK2PALS.IMG is",
            "; in no LOD, so a repaint reaches nothing unless a tool carries it.",
            "",
        ]
        for sym, rec, words, why in carried:
            out.append("; <- MK2PALS.IMG record %s   (%s)" % (rec, why))
            out.append(ip.as_asm(sym, words))
            out.append("")
    for sym, rec, words in order:
        out.append("; <- MK2PALS.IMG record %s" % rec)
        out.append(ip.as_asm(sym, words))
        out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------------------
def write_same_endings(path: Path, text: str, default: str = NL) -> None:
    """Write `text` with the line endings the file already had.

    `Path.write_text` writes the PLATFORM default, so on Windows it turns every
    "\\n" into "\\r\\n" whatever the file was.  It happens to be harmless in
    this checkout - `core.autocrlf` is true, so the working tree is CRLF and
    git normalises to LF on the way in - but that is a property of one clone's
    config, not of the tree, and a checkout without it would get a whole-file
    diff for a hundred-row change.  So match the file instead of the platform;
    a file being created gets LF, which is what src/ holds in git.
    """
    nl = default
    if path.exists():
        raw = path.read_bytes()
        nl = "\r\n" if raw.count(b"\r\n") > raw.count(b"\n") // 2 else "\n"
    with open(path, "w", encoding="latin-1", newline=nl) as fh:
        fh.write(text)


def excluded_today(lines: list[str]) -> set:
    """The palettes `death_fade_excludes` holds right now - the label down to
    its `.long 0` terminator, and NOTHING else in the file.  Reading every
    `.long` in MKGUYS.ASM instead makes every costume table look like an
    exclude, which silently turns the "was it excluded before?" test into
    "yes, always"."""
    out, inside, our_block = set(), False, False
    for ln in lines:
        if LABEL.match(ln) and ln.strip() == "death_fade_excludes":
            inside = True
            continue
        if not inside:
            continue
        if ln.startswith(FADE_BEGIN):
            our_block = True
        elif ln.startswith(FADE_END):
            our_block = False
        elif ln.lstrip().startswith(".long"):
            cells = [c.strip() for c in
                     ln.split(".long", 1)[1].split(";")[0].split(",")]
            if cells == ["0"]:
                break                       # terminator - the list ends here
            if not our_block:
                out.update(cells)
    return out


def fade_additions(text: str, plan: dict, order: list) -> tuple[list, list]:
    """-> (what death_fade_excludes gains, warnings)

    A COSTUME palette is always excluded - a fighter who is not in this list
    dims inside his own costume while the stage fades (the 2026-09-08 Ermac
    defect).  A BLOOD palette is excluded when its fighter is in
    BLOOD_STAYS_LIT, which is authored rather than computed; the docstring
    there says why, and it is the difference between this tool being idempotent
    and it silently undoing itself on the second run.
    """
    lines = text.split("\n")
    cur = excluded_today(lines)
    costume_tabs = {lane[1] for lane in LANES}
    old = {t: row_symbols(lines, t) for t in dict.fromkeys(t for t, _ in plan)}

    why, warn = {}, []
    for (table, och), (sym, rec, _) in sorted(plan.items()):
        if table in costume_tabs:
            why.setdefault(sym, "%s costume" % ROSTER[och][1])
        elif not sym.startswith(SYM):
            # a fallback row pointing at a palette that was already linked -
            # its fade status is whatever it already is, and not ours to change
            continue
        elif och in BLOOD_STAYS_LIT:
            why.setdefault(sym, "%s blood - stays lit, as it does today"
                           % ROSTER[och][1])
        elif old[table][och][0] in cur:
            # only visible before the first --apply, which is the only time it
            # can be: the palette being asked about is gone afterwards
            warn.append("%s's blood row in %s replaces %s, which IS excluded "
                        "today - he will start dimming while cut up.  Add %d "
                        "to BLOOD_STAYS_LIT to keep today's behaviour."
                        % (ROSTER[och][1], table, old[table][och][0], och))

    add = [(sym, why[sym]) for sym, _, _ in order
           if sym in why and sym not in cur]
    return add, sorted(set(warn))


def orphaned_rows(new_text: str, order: list) -> list:
    """Rows still pointing at a KP_ symbol this run does not generate.

    A lane with no record in the library is deliberately LEFT ALONE ("row kept
    as it is"), which is right when the row holds a hand-written palette.  It
    is WRONG when the row holds a KP_ symbol a PREVIOUS run put there and the
    record has since been deleted or renamed in the IMG: the .ref and the
    definition both stop being emitted and the row is left naming a symbol
    that no longer exists, which GSPA rejects as "AN IDENTIFIER IN THE
    EXPRESSION IS INVALID" only once MKGUYS.ASM reaches PASS 2.

    That happened on 2026-09-27: RNALT4_P was dropped from data/MK2PALS.IMG,
    and --apply wrote a MKGUYS.ASM whose rain START+LK row still read
    KP_RNALT4_P.  The tool cannot know what the row SHOULD hold - whatever it
    held before this generator claimed it is only in git - so it says which
    row and stops rather than writing a build that cannot link.
    """
    live = {sym for sym, _, _ in order}
    lines = new_text.split(chr(10))
    bad = []
    for lane in LANES:
        for label in (lane[1], lane[3]):
            try:
                idx = table_row_lines(lines, label)
            except Exception:
                continue
            for och in ROSTER:
                if och >= len(idx):
                    continue
                for sym in re.findall(r"KP_[A-Za-z0-9_]+", lines[idx[och]]):
                    if sym not in live:
                        bad.append("%-22s row %-2d %-11s -> %s (record gone from %s)"
                                   % (label, och, ROSTER[och][1], sym, IMG.name))
    return sorted(set(bad))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--matrix", action="store_true")
    a = ap.parse_args()

    claims, orphans, dup_names, by_name = read_img()
    text = MKGUYS.read_text(encoding="latin-1")
    # Column 0 of bloody_palettes as it stands - the fighter's default blood,
    # already compiled into the build.  Reading it back is idempotent: for a
    # fighter the library covers, this tool has already written his own
    # <XX>BLD_P there, which is the same answer it would choose anyway.
    rows0 = row_symbols(text.split("\n"), "bloody_palettes")
    live_default_blood = {och: rows0[och][0] for och in ROSTER}
    cos0 = row_symbols(text.split("\n"), "character_palettes_1")
    live_default = {och: cos0[och][0] for och in ROSTER}
    plan, gaps, order, carried = resolve(
        claims, live_default, live_default_blood, by_name)
    fade_add, fade_warn = fade_additions(text, plan, order)
    asm = build_asm(order, carried)
    new_mkguys = apply_tables(text, plan, order, fade_add)

    stale = orphaned_rows(new_mkguys, order)
    if stale:
        print("COSTUME PALETTES - DANGLING GENERATED SYMBOL:")
        for s in stale:
            print("  -", s)
        print("  A record this tool had already wired was removed or renamed in")
        print("  %s, so the row below names a symbol nothing defines any more." % IMG.name)
        print("  Either put the record back in the library, or set that row by hand")
        print("  to the palette it should hold (git has what it held before).")
        return 1

    if a.check:
        bad = []
        have = (ASM_OUT.read_text(encoding="latin-1") if ASM_OUT.exists()
                else None)
        if have != asm:
            bad.append("src/COSTPAL.ASM is not what data/MK2PALS.IMG says it "
                       "should be")
        if new_mkguys != text:
            bad.append("src/MKGUYS.ASM costume rows do not match the library")
        if bad:
            print("COSTUME PALETTES - DRIFT:")
            for b in bad:
                print("  -", b)
            print("  run: python tools/make_costume_palettes.py --apply")
            return 1
        print("costume palettes: %d wired, src/COSTPAL.ASM and MKGUYS.ASM "
              "agree with data/MK2PALS.IMG - OK" % len(order))
        return 0

    rows = len(plan)
    print("data/MK2PALS.IMG -> %d palettes on %d table rows (%d bytes of "
          "program ROM)" % (len(order), rows, sum(2 + 2 * len(w) for _, _, w in order)))
    if a.matrix:
        slots = [lane[0] for lane in LANES] + [lane[2] for lane in LANES]
        print("\n%-13s %s" % ("fighter", " ".join("%-5s" % s for s in slots)))
        for och in sorted(ROSTER):
            code, who = ROSTER[och]
            cells = " ".join("%-5s" % ("yes" if (och, s) in claims else "-")
                             for s in slots)
            print("%-2d %-10s %s" % (och, who, cells))
        for och, why in sorted(SKIPPED_OCHAR.items()):
            print("%-2d %-10s SKIPPED - %s" % (och, "", why))
    if gaps:
        print("\nNOT YET AUTHORED - %d lanes fall back to the fighter's "
              "default:" % len(gaps))
        for g in gaps:
            print("  -", g)
    if orphans:
        print("\nIN THE LIBRARY, WIRED TO NOTHING:")
        for n, w in orphans:
            print("  - %-12s %s" % (n, w))
    if dup_names:
        print("\nDUPLICATE RECORD NAMES (the LAST one wins, as LOAD2 does): %s"
              % ", ".join(dup_names))
    if carried:
        print("\nCARRIED BY NAME (no lane, no table row, no fade entry):")
        for sym, rec, words, why in carried:
            print("  - %-14s <- %-12s %s" % (sym, rec, why))
    if fade_add:
        print("\ndeath_fade_excludes gains %d palettes" % len(fade_add))

    if a.apply:
        write_same_endings(ASM_OUT, asm)
        write_same_endings(MKGUYS, new_mkguys)
        print("\nwrote %s and %s" % (ASM_OUT.name, MKGUYS.name))
    else:
        print("\n(report only - nothing written; --apply to write)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
