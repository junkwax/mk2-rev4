#!/usr/bin/env python3
r"""Write tools/raiden_elec_expect.lua - what tools/raiden_elec_test.lua expects.

THE PAIRINGS BELOW ARE THE SPEC, not a reading of the implementation (the
user's, 2026-09-28).  There are two of them, and they have to agree:

  * the LIGHTNING ITSELF - one electric palette per costume lane
    (raiden_elec_offer, MKGUYS.ASM).
  * the FLASH ON THE MAN IT HITS - the same three colours, on the victim's own
    body (player_shock_pal / shock_elec_tabs, MKGUYS.ASM; src/SHOCKPAL.ASM) -
    and on RAIDEN'S own body for his victory charge-up.

BOTH BODY BEATS ARE NAMED, not just ELEC (the user's, 2026-09-28).  The cycle is
FREZ, ELEC, WHITE, BLACK and the two solid flashes have no body in them, so
there are two palettes per lane to get right: the ELEC beat's <XX>ELEC_P /
ELRED_P / ELPUR_P and the FREZ beat's <XX>FREZ_P / REDEL_P / PURPL_P
(player_shock_frez_pal / shock_frez_tabs).  Naming only ELEC is what let the
FREZ beat stay CYAN under a purple bolt: four distinct palettes is exactly what
the old wiring produced too, so the count is no evidence at all.

The ADDRESSES come out of `src/MK2.MAP`, and the costume symbols are the ones
tools/make_costume_palettes.py writes, so the rig can never be pointed at a
palette this build does not contain or an address that has since moved.

    python tools/raiden_elec_expect.py
"""
from __future__ import annotations

import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "src" / "MK2.MAP"
OUT = Path(__file__).resolve().parent / "raiden_elec_expect.lua"

# (lane index in raiden_elec_offer / costume_offer order, the gesture, the
#  player-1 claim bit in @alt_pal_owner - costume_p1_lanes, MKGUYS.ASM -,
#  the costume he wears, the electric palette his lightning is drawn in,
#  which colour that lane fries the victim in)
LANES = [
    (0, "no button - his default", 0x0000, "KP_RDMAIN_P", "ELEC_P",    0),
    (1, "Start + HIGH PUNCH",      0x0004, "KP_RDALT1_P", "ELECRED_P", 1),
    (2, "Start + LOW PUNCH",       0x0010, "KP_RDALT2_P", "ELECPRL_P", 2),
    (3, "Start + HIGH KICK",       0x0040, "KP_RDALT3_P", "ELECPRL_P", 2),
    (4, "Start + LOW KICK",        0x0100, "KP_RDALT4_P", "ELECPRL_P", 2),
    (5, "Start + BLOCK",           0x0001, "KP_RDMAIN_P", "ELEC_P",    0),
]

# Every electric palette Raiden could be drawn in, so a run can say "and NOT
# that one" rather than only "yes, the right one appeared".
ELEC = ["ELEC_P", "ELECRED_P", "ELECPRL_P"]

# The rig fights JAX, so the victim's flash is the JX row of each of the three
# twenty-row tables.  All three are listed for the same reason as above.
VICTIM = "jax"
VICTIM_FLASH = {0: "JXELEC_P", 1: "JXELRED_P", 2: "JXELPUR_P"}

# ...and the FREZ beat on that same body.  The blue row is the old frozen set
# (ochar_frez_pals, MKGUYS.ASM), the other two SHOCKPAL.ASM's shock_frez_red /
# shock_frez_purple.  A run that still shows JXFREZ_P on a red or purple lane is
# the pre-2026-09-28 wiring, whatever the palette COUNT says.
VICTIM_FREZ = {0: "JXFREZ_P", 1: "JXREDEL_P", 2: "JXPURPL_P"}

# HIS OWN flash, for the victory charge-up: raiden_victory is the one site where
# the man wearing the current IS Raiden, so player_shock_pal indexes the RD row.
# Naming it is what makes the victory verdict mean something - solid white and
# solid black on their own could come from the victory FADE (rvic_fade ->
# raiden_dimmer takes the whole palette to zero), not from the cycle.
SELF_FLASH = {0: "RDELEC_P", 1: "RDELRED_P", 2: "RDELPUR_P"}

# THE AMBIENT CRACKLE OVER HIS OWN BODY, per LANE rather than per colour: the
# RN*BOLT art is painted against the COSTUME layout, so each lane's crackle
# palette is a copy of THAT costume (src/RDCRACK.ASM,
# tools/make_raiden_crackle_palettes.py).  The blue lanes name the costume
# palette itself, which is why they cannot be judged by "did it appear" - his
# body is already wearing it.  See CRACKLE_BLUE below.
CRACKLE = {
    0: "KP_RDMAIN_P",     # default - the costume palette itself
    1: "RDCRK_ALT1_P",    # Start+HP  red
    2: "RDCRK_ALT2_P",    # Start+LP  purple
    3: "RDCRK_ALT3_P",    # Start+HK  purple
    4: "RDCRK_ALT4_P",    # Start+LK  purple
    5: "KP_RDMAIN_P",     # Start+BLOCK - his default
}
# the generated ones: a lane whose crackle should be blue must show NONE of
# these, and a lane whose crackle is coloured must show exactly its own.
CRACKLE_GEN = sorted({v for v in CRACKLE.values() if v.startswith("RDCRK_")})

# HIS OWN FREZ beat - and the body code is RN, not RD.  Raiden fries as RD and
# freezes as RN: ochar_frez_pals and ochar_elec_pals are two different rosters,
# which is exactly the kind of thing a hand-typed expectation gets wrong.
SELF_FREZ = {0: "RNFREZ_P", 1: "RNREDEL_P", 2: "RNPURPL_P"}


def symbols() -> dict[str, int]:
    out: dict[str, int] = {}
    for line in MAP.read_text(errors="replace").splitlines():
        for m in re.finditer(r"\b([0-9a-f]{8})\s+([A-Za-z_][A-Za-z0-9_.]*)", line):
            out.setdefault(m.group(2), int(m.group(1), 16))
    return out


def main() -> int:
    sym = symbols()
    need = sorted({n for _, _, _, c, e, _ in LANES for n in (c, e)}
                  | set(ELEC) | set(VICTIM_FLASH.values())
                  | set(SELF_FLASH.values()) | set(VICTIM_FREZ.values())
                  | set(SELF_FREZ.values()) | set(CRACKLE.values()))
    missing = [n for n in need if n not in sym]
    if missing:
        print("not in %s: %s - is this build current?" % (MAP.name, ", ".join(missing)))
        return 1

    with io.open(OUT, "w", newline="\n") as f:
        f.write("-- GENERATED by tools/raiden_elec_expect.py.  Do not edit: the point\n")
        f.write("-- of this file is that no human chose the addresses.\n")
        f.write("--\n-- The pairings are the spec; the addresses are this build's.\n")
        f.write("return {\n")
        f.write('  victim = "%s",\n' % VICTIM)
        f.write("  lanes = {\n")
        for idx, button, bit, cos, elec, colour in LANES:
            f.write('    { name = "lane%d", ownerbit = 0x%04X,\n' % (idx, bit))
            f.write('      button = "%s",\n' % button)
            f.write('      costume = "%s", elec = "%s",\n' % (cos, elec))
            f.write('      flash = "%s", selfflash = "%s",\n'
                    % (VICTIM_FLASH[colour], SELF_FLASH[colour]))
            f.write('      frez = "%s", selffrez = "%s",\n'
                    % (VICTIM_FREZ[colour], SELF_FREZ[colour]))
            f.write('      crackle = "%s", crackleblue = %s },\n'
                    % (CRACKLE[idx],
                       "false" if CRACKLE[idx].startswith("RDCRK_") else "true"))
        f.write("  },\n")
        f.write("  iselec = {\n")
        for n in ELEC:
            f.write("    %-12s = true,\n" % n)
        f.write("  },\n  isflash = {\n")
        for n in sorted(set(VICTIM_FLASH.values())):
            f.write("    %-12s = true,\n" % n)
        f.write("  },\n  isselfflash = {\n")
        for n in sorted(set(SELF_FLASH.values())):
            f.write("    %-12s = true,\n" % n)
        f.write("  },\n  isfrez = {\n")
        for n in sorted(set(VICTIM_FREZ.values())):
            f.write("    %-12s = true,\n" % n)
        f.write("  },\n  isselffrez = {\n")
        for n in sorted(set(SELF_FREZ.values())):
            f.write("    %-12s = true,\n" % n)
        f.write("  },\n  iscrackle = {\n")
        for n in CRACKLE_GEN:
            f.write("    %-14s = true,\n" % n)
        f.write("  },\n  byaddr = {\n")
        for n in need:
            f.write('    ["%08x"] = "%s",\n' % (sym[n], n))
        f.write("  },\n}\n")

    print("wrote %s" % OUT.relative_to(ROOT))
    for n in need:
        print("  %-14s %08x" % (n, sym[n]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
