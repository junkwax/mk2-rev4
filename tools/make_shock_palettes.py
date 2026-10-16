#!/usr/bin/env python3
r"""THE ELECTROCUTION FLASH, IN THREE COLOURS, OUT OF `data/ALLDUDES.IMG`.

WHAT COLOUR A MAN FRIES IN IS RAIDEN'S COSTUME (the user's, 2026-09-28):

    RDMAIN_P  his default, Start+BLOCK, Start+COIN   ->  blue
    RDALT1_P  Start + HIGH PUNCH                     ->  red
    RDALT2_P  Start + LOW PUNCH                      ->  purple
    RDALT3_P  Start + HIGH KICK                      ->  purple
    RDALT4_P  Start + LOW KICK                       ->  purple

...and `<XX>` is the VICTIM, not Raiden: the flash is his own body repainted,
so every fighter has his own copy of each colour.  Which makes the table a
twenty-row one per colour, exactly like `ochar_elec_pals` (MKGUYS.ASM) already
is for the blue set.

TWO OF THE FOUR BEATS ARE THE MAN'S OWN BODY, AND BOTH TAKE THE COLOUR
(the user's, 2026-09-28).  The cycle is FREZ, ELEC, WHITE, BLACK
(`shockcyc`, MAINEQU.ASM) and the two solid flashes have no body in them:

    ELEC   the authored electrocution   <XX>ELEC_P  <XX>ELRED_P  <XX>ELPUR_P
    FREZ   the beat in front of it      <XX>FREZ_P  <XX>REDEL_P  <XX>PURPL_P

The FREZ beat used to be the CYAN frozen set whatever colour the current was,
so a purple electrocution flickered purple, cyan, purple, cyan and read as two
effects at once.  MIDWAY DREW THAT BEAT IN THREE COLOURS TOO and wired only
the cyan one - the 18 `<XX>PURPL_P` / `<XX>REDEL_P` records are in this same
library, referenced by nothing in retail or in this tree.

THE PAIRING IS PROVED BY CONTENT, NOT BY THE NAME.  `--check` requires each
`PURPL`/`REDEL` record to be the SAME DRAWING as the `FREZ` record it stands
in for - identical brightest channel in all 64 slots, which a re-hue preserves
and an unrelated palette of the same size does not - and requires its hue to
point the right way (red: mean R above both others; purple: mean B above G).
Measured 2026-09-28: 18 of 18 records, 64 of 64 slots.

MIDWAY DREW ALL OF IT AND ONLY EVER WIRED ONE COLOUR OF EACH BEAT.  The ELEC
records and the FREZ ones are all in `data/ALLDUDES.IMG`; this tool carries the
red and purple ones into `src/SHOCKPAL.ASM` and builds the four new tables.
The blue sets stay where they already are - the ELEC blues in
`src/IMGPAL3.ASM`, the FREZ blues hand-carried as words in `src/MKGUYS.ASM` -
and are CHECKED here against the library rather than moved.

FOUR SPELLINGS ARE MIDWAY'S OWN AND ARE NOT TYPOS TO FIX:

  * Liu Kang's ELEC purple is `LKELPUP_P`, not `LKELPUR_P`.  The record in the
    library is spelled that way and the library is the authority.
  * THERE IS NO `BGELRED_P`.  `BG` is the boss body (Kintaro, Shao Kahn) and it
    has a blue and a purple but no red, so the red table falls those two rows
    back to `BGELEC_P`.  A boss is never the victim of Raiden's grab anyway -
    `do_raiden_shocker` has no boss test, but `ask_mr_diff` never puts a player
    in front of one wearing a costume - so the fallback is reachable only
    through a fatality on one, and blue there is the old behaviour.
  * THE FREZ BEAT IS A DIFFERENT ROSTER FROM THE ELEC ONE.  Raiden fries as
    `RD` and freezes as `RN`, and Kintaro's frozen palette is `gorof_p`, a
    symbol with no `<XX>` in it at all.
  * FOUR OF THE FREZ BLUES ARE CARRIED UNDER A NAME THE LIBRARY DOES NOT HAVE:
    MKGUYS' `LKFREZ_P` is ALLDUDES' `LKFREZ1_P`, and the same for KT, ST, NJ
    and JX.  `FREZ_SOURCE` records which record each one really is, so the
    check compares words and not names.  Neither boss body was drawn in red or
    purple for this beat either, so both fall back to their own frozen palette.

THE BLUE TABLES ARE THE ROSTERS, and this tool proves it rather than assuming
it: `ochar_elec_pals` and `ochar_frez_pals` in MKGUYS.ASM already encode which
body each of the twenty fighters wears (Reptile and Scorpion on the ninja's,
Mileena on Kitana's, Rain on the ninja's, ...).  `--check` regenerates both
from the rosters below and fails if either disagrees, so no colour table can
quietly disagree with its blue one about who is who.

    python tools/make_shock_palettes.py            # report, write nothing
    python tools/make_shock_palettes.py --apply    # write src/SHOCKPAL.ASM
    python tools/make_shock_palettes.py --check    # Phase D: fail on drift
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                            # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "ALLDUDES.IMG"
OUT = ROOT / "src" / "SHOCKPAL.ASM"
MKGUYS = ROOT / "src" / "MKGUYS.ASM"
IMGPAL3 = ROOT / "src" / "IMGPAL3.ASM"

NL = "\n"
ROWS = 20                       # every char-indexed table is 20 rows (ft_rain=19)

# =========================================================================
#  THE ELEC BEAT - the authored electrocution.
# =========================================================================
#
# ochar -> the two-letter body code the flash is drawn on.  This IS
# ochar_elec_pals (MKGUYS.ASM), and --check proves it still is.
ROSTER = [
    ("TM", "kung lao"), ("LK", "liu kang"), ("JC", "johnny cage"),
    ("UG", "baraka"),   ("KT", "kitana"),   ("KT", "mileena"),
    ("ST", "shang tsung"), ("RD", "raiden"), ("NJ", "sub-zero"),
    ("NJ", "reptile"),  ("NJ", "scorpion"), ("JX", "jax"),
    ("BG", "kintaro"),  ("BG", "shao kahn"), ("NJ", "smoke"),
    ("NJ", "noob saibot"), ("KT", "jade"), ("NJ", "ermac"),
    ("KT", "khameleon"), ("NJ", "rain"),
]

# colour -> (suffix per body code, table symbol, what wears it)
#
# The per-code overrides are the library's own spellings, not corrections.
BLUE = {code: code + "ELEC_P" for code, _ in ROSTER}
RED = {code: code + "ELRED_P" for code, _ in ROSTER}
RED["BG"] = "BGELEC_P"                  # no BGELRED_P exists - see the docstring
PURPLE = {code: code + "ELPUR_P" for code, _ in ROSTER}
PURPLE["LK"] = "LKELPUP_P"              # Midway's spelling

ELEC_COLOURS = [
    ("blue",   BLUE,   "ochar_elec_pals", "Raiden's default costume", False),
    ("red",    RED,    "shock_pal_red",   "Raiden's Start+HP costume", True),
    ("purple", PURPLE, "shock_pal_purple",
     "Raiden's Start+LP / HK / LK costumes", True),
]

# =========================================================================
#  THE FREZ BEAT - the beat in front of ELEC, and a roster of its own.
# =========================================================================
#
# This IS ochar_frez_pals (MKGUYS.ASM).  It is NOT the ELEC roster: Raiden
# fries as RD and freezes as RN, and Kintaro's is gorof_p, not a <XX> name.
FREZ_ROSTER = [
    ("TM", "kung lao"), ("LK", "liu kang"), ("JC", "johnny cage"),
    ("UG", "baraka"),   ("KT", "kitana"),   ("KT", "mileena"),
    ("ST", "shang tsung"), ("RN", "raiden"), ("NJ", "sub-zero"),
    ("NJ", "reptile"),  ("NJ", "scorpion"), ("JX", "jax"),
    ("GO", "kintaro"),  ("BG", "shao kahn"), ("NJ", "smoke"),
    ("NJ", "noob saibot"), ("KT", "jade"), ("NJ", "ermac"),
    ("KT", "khameleon"), ("NJ", "rain"),
]

FREZ_BLUE = {code: code + "FREZ_P" for code, _ in FREZ_ROSTER}
FREZ_BLUE["GO"] = "gorof_p"             # Kintaro's, and not a library record
FREZ_RED = {code: code + "REDEL_P" for code, _ in FREZ_ROSTER}
FREZ_PURPLE = {code: code + "PURPL_P" for code, _ in FREZ_ROSTER}
# NEITHER BOSS BODY WAS DRAWN IN RED OR PURPLE for this beat, so both fall
# back to their own frozen palette - the same shape as RED["BG"] above.
for _mp in (FREZ_RED, FREZ_PURPLE):
    _mp["GO"] = FREZ_BLUE["GO"]
    _mp["BG"] = FREZ_BLUE["BG"]

FREZ_COLOURS = [
    ("blue",   FREZ_BLUE,   "ochar_frez_pals", "Raiden's default costume", False),
    ("red",    FREZ_RED,    "shock_frez_red",  "Raiden's Start+HP costume", True),
    ("purple", FREZ_PURPLE, "shock_frez_purple",
     "Raiden's Start+LP / HK / LK costumes", True),
]

# Which ALLDUDES record each FREZ blue symbol's WORDS really are.  Four of them
# are carried in MKGUYS under a name the library does not have; gorof_p is in
# no library record at all, so nothing can be checked about it.
FREZ_SOURCE = {
    "TMFREZ_P": "TMFREZ_P",  "LKFREZ_P": "LKFREZ1_P", "JCFREZ_P": "JCFREZ_P",
    "UGFREZ_P": "UGFREZ_P",  "KTFREZ_P": "KTFREZ_P",  "STFREZ_P": "STFREZ1_P",
    "RNFREZ_P": "RNFREZ_P",  "NJFREZ_P": "NJFREZ1_P", "JXFREZ_P": "JXFREZ1_P",
    "BGFREZ_P": "BGFREZ_P",  "gorof_p": None,
}

FAMILIES = [
    dict(beat="ELEC", roster=ROSTER, colours=ELEC_COLOURS,
         home=IMGPAL3, source={n: n for n in BLUE.values()},
         # the ELEC reds are not all pure re-hues - TMELRED_P and LKELRED_P
         # were redrawn (45 and 47 slots of 64 keep the blue's brightest
         # channel) - so the twin test is reported for this family, not
         # required.  It is required for FREZ, where all 18 are exact.
         twins=False),
    dict(beat="FREZ", roster=FREZ_ROSTER, colours=FREZ_COLOURS,
         home=MKGUYS, source=FREZ_SOURCE, twins=True),
]

# every symbol any table names -> the library record it really is (None: not in
# the library, so unprovable and skipped)
SOURCE: dict[str, str | None] = {}
for _f in FAMILIES:
    for _c, _mp, _sym, _why, _new in _f["colours"]:
        for _n in _mp.values():
            SOURCE.setdefault(_n, _f["source"].get(_n, _n))

# where a symbol this file does NOT define is carried
HOME = {n: ("src/IMGPAL3.ASM" if f["home"] is IMGPAL3 else "src/MKGUYS.ASM")
        for f in FAMILIES
        for c, mp, sym, why, new in f["colours"] if not new
        for n in mp.values()}


def img_words() -> dict[str, list[int]]:
    out: dict[str, list[int]] = {}
    for name, words in ip.palettes(IMG):
        out.setdefault(name, list(words))
    return out


def rgb(w: int) -> tuple[int, int, int]:
    return ((w >> 10) & 31, (w >> 5) & 31, w & 31)


def mean_rgb(words: list[int]) -> tuple[float, float, float]:
    s = [rgb(w) for w in words]
    return (sum(x[0] for x in s) / len(s),
            sum(x[1] for x in s) / len(s),
            sum(x[2] for x in s) / len(s))


def block(name: str, words: list[int], note: str) -> str:
    rows = ["\t.word\t" + ",".join("0%04XH" % w for w in words[i:i + 8])
            for i in range(0, len(words), 8)]
    return ("\t.globl\t%s\n%s:\n\t; %s\n\t.word\t %d\n%s\n"
            % (name, name, note, len(words), NL.join(rows)))


def table(symbol: str, mapping: dict[str, str], roster: list[tuple[str, str]],
          beat: str, why: str) -> str:
    out = ["\t.globl\t%s" % symbol,
           "*",
           "*  %s - the %s beat a victim wears while %s" % (symbol, beat, why),
           "*  is doing the electrocuting.  One row per ochar, the body it is",
           "*  drawn on in the comment.",
           "*",
           "%s" % symbol]
    for ochar, (code, who) in enumerate(roster):
        out.append("\t.long\t%-12s ; %2d - %-12s (%s)"
                   % (mapping[code], ochar, who, code))
    return NL.join(out) + NL


def parse_table(text: str, symbol: str) -> list[str] | None:
    m = re.search(r"^" + symbol + r"[ \t]*\n((?:[ \t]*\.long[^\n]*\n)+)", text, re.M)
    if not m:
        return None
    return re.findall(r"\.long\s+([A-Za-z_][A-Za-z0-9_]*)", m.group(1))


def parse_pal(text: str, name: str) -> list[int] | None:
    m = re.search(r"^" + re.escape(name) + r":[ \t]*\n"
                  r"(?:^[ \t]*;[^\n]*\n)*"
                  r"^[ \t]*\.word[ \t]+(\d+)[ \t]*\n"
                  r"((?:^[ \t]*\.word[^\n]*\n)+)", text, re.M)
    if not m:
        return None
    out = []
    for tok in re.findall(r"0?[0-9A-Fa-f]+[Hh]|\b\d+\b", m.group(2)):
        out.append(int(tok[:-1], 16) if tok[-1] in "hH" else int(tok, 10))
    return out


def new_names() -> set[str]:
    return {n for f in FAMILIES
            for c, mp, sym, why, new in f["colours"] if new
            for n in mp.values()}


def generate(pals: dict[str, list[int]]) -> tuple[str, list[str]]:
    used = new_names()
    names = sorted(used - set(HOME))
    head = [
        "; GENERATED by tools/make_shock_palettes.py - do not edit by hand.",
        ";",
        "; THE ELECTROCUTION FLASH IN RED AND PURPLE, out of data/ALLDUDES.IMG.",
        "; What colour a man fries in is the costume RAIDEN is wearing, and",
        "; <XX> is the VICTIM's own body - the flash is his sprite repainted.",
        ";",
        "; TWO of the four beats are that body, and both are here: ELEC, the",
        "; authored electrocution, and FREZ, the beat in front of it.  The blue",
        "; sets are not: the ELEC blues were already linked in src/IMGPAL3.ASM",
        "; and the FREZ blues are hand-carried words in src/MKGUYS.ASM, and this",
        "; tool checks both against the library instead of moving them.",
        ";",
        "; Midway drew every beat in all three colours and wired only the one.",
        "\t.FILE \"shockpal.asm\"",
        "\t.OPTION B,D,L,T",
        "",
    ]
    # names the tables use but this file does not define: the blue fallbacks.
    # Without a .ref GSPA aborts with "AN IDENTIFIER IN THE EXPRESSION IS
    # INVALID" rather than leaving it to the linker.
    external = sorted(used & set(HOME))
    for n in external:
        head.append("\t.ref\t%-12s ; carried in %s" % (n, HOME[n]))
    if external:
        head.append("")

    body = []
    for name in names:
        wearers = [who for f in FAMILIES for code, who in f["roster"]
                   for c, mp, sym, why, new in f["colours"]
                   if new and mp[code] == name]
        note = "ALLDUDES.IMG %s - %s" % (name, ", ".join(dict.fromkeys(wearers)))
        body.append(block(name, pals[name], note))
    for f in FAMILIES:
        for c, mp, sym, why, new in f["colours"]:
            if new:
                body.append(table(sym, mp, f["roster"], f["beat"], why))
    return NL.join(head) + NL + NL.join(body) + NL, names


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    pals = img_words()
    rc = 0

    # every record any table names has to be in the library, under whatever
    # name SOURCE says it really is
    missing = sorted(n for n, src in SOURCE.items() if src and src not in pals)
    if missing:
        print("%s: no palette record for %s" % (IMG.name, ", ".join(missing)))
        return 1

    mk = MKGUYS.read_text(encoding="latin-1")
    homes = {IMGPAL3: IMGPAL3.read_text(encoding="latin-1"), MKGUYS: mk}

    for f in FAMILIES:
        beat, roster = f["beat"], f["roster"]

        # THE BLUE TABLE IS THE ROSTER.  If MKGUYS disagrees, every colour would.
        colour, mp, symbol, why, new = f["colours"][0]
        have = parse_table(mk, symbol)
        want = [mp[code] for code, _ in roster]
        if have is None:
            print("MKGUYS.ASM: no %s table" % symbol)
            rc = 1
        elif have != want:
            print("MKGUYS.ASM %s disagrees with the %s roster in this tool:"
                  % (symbol, beat))
            for i, (h, w) in enumerate(zip(have + [None] * ROWS, want)):
                if h != w:
                    print("  ochar %2d: %s, the roster says %s" % (i, h, w))
            if len(have) != ROWS:
                print("  and it has %d rows, not %d" % (len(have), ROWS))
            rc = 1
        else:
            print("%s matches the %s roster - %d rows" % (symbol, beat, ROWS))

        # the blues, against the library, in the file that carries them
        text = homes[f["home"]]
        checked = 0
        for name in sorted(set(mp.values())):
            src = SOURCE[name]
            if src is None:
                continue                # gorof_p is in no library record
            got = parse_pal(text, name)
            if got is None:
                print("%s: not carried in %s" % (name, f["home"].name))
                rc = 1
            elif got != pals[src]:
                d = sum(1 for x, y in zip(got, pals[src]) if x != y)
                print("%s: %s differs from %s's %s by %d of %d - repaint not carried"
                      % (name, f["home"].name, IMG.name, src, d, len(pals[src])))
                rc = 1
            else:
                checked += 1
        print("  %d blue %s records match %s" % (checked, beat, IMG.name))

        # EVERY RED/PURPLE RECORD IS THE SAME DRAWING AS THE BLUE ONE IT STANDS
        # IN FOR - same brightest channel in every slot, which a re-hue keeps.
        # This is what proves the pairing by content instead of by the name.
        for colour, mp, symbol, why, new in f["colours"][1:]:
            exact = 0
            for code, _who in roster:
                name, blue = mp[code], f["colours"][0][1][code]
                if name == blue:
                    continue            # a fallback row - nothing to pair
                bsrc = SOURCE[blue]
                if bsrc is None:
                    continue
                w, b = pals[name], pals[bsrc]
                if len(w) != len(b):
                    print("%s: %d entries, %s has %d" % (name, len(w), bsrc, len(b)))
                    rc = 1
                    continue
                eq = sum(1 for x, y in zip(b, w) if max(rgb(x)) == max(rgb(y)))
                if eq == len(b):
                    exact += 1
                else:
                    msg = ("%s: only %d of %d slots keep %s's brightest channel"
                           % (name, eq, len(b), bsrc))
                    if f["twins"]:
                        print(msg + " - not a re-hue of it")
                        rc = 1
                    else:
                        print("  note: " + msg)
                # ...and it points the right way.  A purple that came out red
                # would pass the test above.
                r, g, bl = mean_rgb(w)
                ok = (r > g and r > bl) if colour == "red" else (bl > g and bl >= r)
                if not ok:
                    print("%s: mean R%.1f G%.1f B%.1f is not %s"
                          % (name, r, g, bl, colour))
                    rc = 1
            print("  %s %s: %d rows, %d of them an exact re-hue of the blue"
                  % (beat, colour, ROWS, exact))

    # no generated name may collide with a symbol that already exists elsewhere
    text, names = generate(pals)
    for other in sorted(ROOT.joinpath("src").glob("*.ASM")):
        if other.name == OUT.name:
            continue
        t = other.read_text(encoding="latin-1")
        for n in names:
            if re.search(r"^" + n + r":", t, re.M):
                print("%s already defines %s - the generated name would collide"
                      % (other.name, n))
                rc = 1

    tables = sum(1 for f in FAMILIES for c in f["colours"] if c[4])
    cur = OUT.read_text(encoding="latin-1") if OUT.exists() else None
    if cur == text:
        print("src/SHOCKPAL.ASM OK - %d palettes, %d tables" % (len(names), tables))
    elif a.apply:
        OUT.write_text(text, encoding="latin-1", newline="")
        print("wrote src/SHOCKPAL.ASM - %d palettes from %s, %d tables"
              % (len(names), IMG.name, tables))
    else:
        print("src/SHOCKPAL.ASM is %s - run tools/make_shock_palettes.py --apply"
              % ("missing" if cur is None else "stale"))
        rc = 1

    return rc


if __name__ == "__main__":
    sys.exit(main())
