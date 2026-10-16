#!/usr/bin/env python3
"""Audit character costume palettes against death_fade_excludes (MKGUYS.ASM).

`death_fade_excludes` is the null-terminated list of palettes NOT to fade.
Three routines fade through it:

    death_blow_fader   MKDEATH.ASM - EVERY fatality and babality
    raiden_dimmer      UTIL.ASM    - Raiden's lightning dims the stage
    raiden_undimmer    UTIL.ASM

Its whole job is "fade the stage, leave the fighters lit". So a palette a
FIGHTER CAN BE WEARING that is missing from it dims that fighter, on screen,
for the whole finisher - with no build error, no crash, and nothing to see in
any diff. It is only ever found by playing the character and noticing.

That shipped once: Ermac visibly darkened through his own fatality and
babality (reported 2026-09-08) because ERMAC_P - the single palette that
character_palettes_1..7 row 17 AND bloody_palettes row 17 all point at - was
in none of the three paths' list. Auditing the rest of the tables the same way
turned up six more costumes with the identical defect, none of which anyone
had noticed. Every costume added or re-pointed since retail had been missed.

So: every entry of character_palettes_1..7 must appear in death_fade_excludes.

SECOND CLASS, added 2026-09-09: SCORE-AREA art with its own ramp.  Everything
in the score area used to ride SCORE_P, which is excluded, so the whole HUD
stayed lit through a finisher for free.  Art that carries its OWN palette does
not get that, and the win marker under the life bars is exactly that art - it
dimmed through every fatality while the life bar beside it stayed lit.  So the
palette `get_amulet_pal` (MKDISP.ASM) claims is read out of the source and
required here too, which means a future re-skin of the marker cannot fall out
of the list the way this one did.

WHAT THIS DELIBERATELY DOES NOT CHECK - bloody_palettes.  Retail excludes no
bloody variant at all (TMBLOOD_P, LKBLUD1_P, JCBLUD1_P, UGBLUD2_P, KT1BLUD_P,
KT2BLUD_P, TYBLUD_P, RDBLUD1_P, SUBBLD_P, SCRBLD_P, JXBLUD2_P are all absent),
so a bloodied stock fighter dims where a clean one does not.  That is retail's
own behaviour on all twelve originals and changing it is a look decision, not
a bug fix - it is not this tool's call to force.  Ermac is unaffected either
way because his bloody row IS his costume row.

  python tools/audit_fade_excludes.py            # report
  python tools/audit_fade_excludes.py --check    # exit 1 if any are missing
"""
import os
import re
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
GUYS = os.path.join(SRC, "MKGUYS.ASM")
DISP = os.path.join(SRC, "MKDISP.ASM")

# Tables whose every entry is a palette a fighter is drawn in.
COSTUME_TABLES = [f"character_palettes_{i}" for i in range(1, 8)]

# Score-area routines that claim a palette of their own, and must therefore
# appear in the exclude list so the thing they draw stays lit with the rest of
# the HUD.  Read from source rather than hardcoded: the point is to survive a
# re-skin that renames the palette.
HUD_CLAIMERS = ["get_amulet_pal"]


def palette_claimed_by(text, routine):
    """The symbol a `movi <SYM>,a0 / calla getfpal` routine claims, or None."""
    marker = "\n" + routine + "\n"
    if marker not in text:
        return None
    body = text[text.index(marker) + len(marker):]
    pending = None
    for line in body.split("\n")[:20]:
        m = re.match(r"\s+movi\s+([A-Za-z_][\w]*),a0\b", line)
        if m:
            pending = m.group(1)
            continue
        if re.match(r"\s+calla\s+getfpal\b", line):
            return pending
        if re.match(r"\s+(rets|retp)\b", line):
            break
    return None


def read_table(text, name):
    """Return the .long symbols of a label's table, or None if not found."""
    marker = "\n" + name + "\n"
    if marker not in text:
        return None
    body = text[text.index(marker) + len(marker):]
    out = []
    for line in body.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("*") or stripped.startswith(";"):
            continue
        m = re.match(r"\.long\s+([A-Za-z_][\w]*)", stripped)
        if m:
            out.append(m.group(1))
            continue
        # a new label or any instruction ends the table
        if re.match(r"^[A-Za-z_][\w]*", line) and line[0] not in " \t":
            break
        if re.match(r"^\s+(movi|move|calla|callr|jauc|jruc|rets|retp)\b", line):
            break
    return out


def main():
    check = "--check" in sys.argv
    text = open(GUYS, encoding="latin-1").read()

    excludes = read_table(text, "death_fade_excludes")
    if excludes is None:
        print("audit_fade_excludes: death_fade_excludes not found in MKGUYS.ASM")
        return 1
    # The list is case-inconsistent in the original (smoke_p vs SUB_P), and so
    # are the tables, so compare case-folded.
    excl = {p.lower() for p in excludes}

    missing = {}
    for name in COSTUME_TABLES:
        rows = read_table(text, name)
        if rows is None:
            print(f"audit_fade_excludes: {name} not found")
            return 1
        for idx, pal in enumerate(rows):
            if pal.lower() not in excl:
                missing.setdefault(pal, []).append(f"{name}[{idx}]")

    # Score-area art that claims its own palette (see the header note).
    disp = open(DISP, encoding="latin-1").read()
    hud_missing = {}
    for routine in HUD_CLAIMERS:
        pal = palette_claimed_by(disp, routine)
        if pal is None:
            print(f"audit_fade_excludes: {routine} not found in MKDISP.ASM,"
                  " or it no longer claims a palette")
            return 1
        if pal.lower() not in excl:
            hud_missing[pal] = routine

    print(f"death_fade_excludes: {len(excludes)} palettes")
    print(f"costume palettes:    {len({p.lower() for n in COSTUME_TABLES for p in read_table(text, n)})} distinct")
    if hud_missing:
        print("\nSCORE-AREA PALETTES THAT WOULD DIM:")
        for pal, routine in sorted(hud_missing.items()):
            print(f"  {pal:16} claimed by {routine} (MKDISP.ASM)")
        print("\nThis art sits in the score area beside the life bars, which ride")
        print("the excluded SCORE_P and stay lit.  Add it to death_fade_excludes")
        print("(MKGUYS.ASM) next to SCORE_P.")

    if not missing and not hud_missing:
        print("all costume and score-area palettes are excluded from the fade - OK")
        return 0
    if not missing:
        return 1 if check else 0

    print("\nCOSTUME PALETTES THAT WOULD DIM (missing from death_fade_excludes):")
    for pal in sorted(missing):
        print(f"  {pal:16} worn at {', '.join(missing[pal][:6])}")
    print(f"\n{len(missing)} missing.")
    print("Each one dims the fighter wearing it through every fatality, every")
    print("babality and Raiden's lightning.  Add it to death_fade_excludes")
    print("(MKGUYS.ASM) next to the other costume palettes.")
    return 1 if check else 0


if __name__ == "__main__":
    sys.exit(main())
