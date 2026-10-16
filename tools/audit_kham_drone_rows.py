#!/usr/bin/env python3
r"""Every char-indexed table the DRONE reads, and whether it follows KHAMELEON's
disguise or stays on her own row.

WHY THIS EXISTS.  `kham_fight_as_guise` (MAINEQU.ASM) makes the drone's move
choices follow whichever female ninja Khameleon currently has on, by routing
MKDRONE's table reads through `kd_char_long` / `kd_char_word` / `kd_ochar_jump`
instead of the shared `get_char_long` / `get_char_word` / `ochar_jump`.  That is
a per-character index bias spread over twenty call sites, and **this tree has
already shipped one of those broken**: the first cut of her sai lanes biased
five sites and missed the sixth (`saih4`), so a few frames of Jade's boomerang
drew at the moment of contact - no crash, no build error, no warning.  A
per-character bias is only as good as the audit that enumerates its call sites,
so this enumerates them and fails the build when one is unaccounted for.

WHAT IT CHECKS

  1. Every table read through any of the six helpers is CLASSIFIED below, as
     WORN (follows the disguise) or OWN (stays on her row 18).  A table that is
     in neither list fails - that is the case where somebody adds a new drone
     behaviour table and nobody decides which way it goes.
  2. Every WORN table's sites use a `kd_*` helper, and every OWN table's sites
     use a shared one.  A site that drifted to the wrong helper fails.
  3. `get_char_ani` sites are never routed through a `kd_*` helper - her FRAMES
     are her own union table (`fn4_anitab2`) and `kham_sai_ani2` already biases
     that index by 7 for her.
  4. `kham_worn_ochars` (MKDRONE.ASM) and `kham_disguise_pals` (MKGUYS.ASM) are
     the same length and in the same ORDER, so the costume she is drawn in and
     the fighter she plays as cannot disagree.
  5. Every `zap_offsets` read calls `jade_pick_boom` (which of Jade's four
     boomerangs), and calls it BEFORE `drone_zap_legal`, so legality is tested
     on the index that is actually thrown.

    python tools/audit_kham_drone_rows.py           # report
    python tools/audit_kham_drone_rows.py --check   # Phase D: fail on drift
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "src"

SHARED = ("get_char_long", "get_char_word", "ochar_jump")
WRAPPED = ("kd_char_long", "kd_char_word", "kd_ochar_jump")
ANI = "get_char_ani"

# Tables whose row must follow the DISGUISE - her move choices.
WORN = {
    "rt_special_start":        "which special she throws",
    "ochar_propells":          "projectile behaviour",
    "zap_offsets":             "ground projectile index",
    "air_zap_offsets":         "air projectile index",
    "ochar_antiair":           "anti-air answer",
    "ochar_punish":            "long-range punish",
    "ochar_juggle_scripts":    "juggle combo script",
    "close_out_of_air":        "close out-of-air answer",
    "med_out_of_air":          "mid out-of-air answer",
    "angle_towards_reactions": "how she closes distance",
    "ochar_avoid_pro":         "projectile avoidance / retaliation",
    "ochar_superk_sd":         "super-kick knockdown answer",
    "ochar_duck_special":      "ducking special",
}

# Tables that must stay on HER OWN row 18, each with the reason.  A reason is
# required: "it was like that already" is how the fatality one would slip in.
OWN = {
    "ochar_drone_start":
        "her BRAIN. drone_setup jauc's into it ONCE per round and the routine "
        "loops forever, so following the costume would mean restarting her "
        "drone process every 6-7 seconds. Instead the ONE character-specific "
        "thing jade_start does - opening with Jade's Nitro - is gated on "
        "kham_worn_ochar being ft_jade, so no other costume can throw it",
    # (khamquick, 2026-09-29: the one read of this table THROUGH kd_char_long is in
    # kham_start - see BELL_PICK below. The dispatch into her brain is still row 18.)
    "ochar_fatality_distances":
        "she has NO fatality - blocked four ways, char_block is sucide - so "
        "Jade's or Kitana's range would walk her in to attempt a finisher "
        "with no handler",
    "skull_escape":
        "read through get_char_ani as well as get_char_long, so biasing it "
        "would move an animation lookup with it",
    "ta_speeds":
        "turnaround ANIMATION speed (MOVES.ASM), not a move choice",
    "act_getup": "animation",
    "act_walkf": "animation",
    "l_sai": "a timer pair, not a char table",
    "backflipper_x_dist": "geometry of a move she picks by another table",
    "divesd_x_dist": "geometry, as above",
    "drone_juggle_throw_lead": "geometry, as above",
    "flipk_stk_offsets": "geometry, as above",
    "fntele_heights": "geometry, as above",
    "rh_air_distances": "geometry, as above",
    "superkang_zap_dist": "geometry, as above",
}


# The only places an OWN table may be read through a kd_ wrapper, keyed by
# (table, enclosing label), each with its reason.
BELL_PICK = {
    ("ochar_drone_start", "kham_start"):
        "khamquick: row 18 IS kham_start, so the brain dispatch still stays on "
        "her own row. kham_start then reads the WORN fighter's row exactly once, "
        "at the bell, to pick an OPENER - fn1_start (Kitana), jade_start (Jade) "
        "or generic_drone_start (Mileena) - and every one of those ends in "
        "generic_drone_start, which loops on kd_-wrapped tables for the rest of "
        "the round. Nothing re-dispatches when she changes clothes, which is "
        "what the OWN rule exists to prevent",
}


def enclosing_label(lines, line_no):
    """the nearest column-0 label at or above line_no (1-based)"""
    for i in range(line_no - 1, -1, -1):
        m = re.match(r"^([A-Za-z_]\w*)\s*$", lines[i])
        if m:
            return m.group(1)
    return None


def sites(text: str):
    """[(table, helper, line)] for every char-table read in MKDRONE."""
    lines = text.split("\n")
    helpers = SHARED + WRAPPED + (ANI,)
    out = []
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith(("*", ";")):
            continue
        hit = None
        for h in sorted(helpers, key=len, reverse=True):
            if re.search(r"\b" + h + r"\b", ln):
                hit = h
                break
        if hit is None:
            continue
        tbl = None
        for j in range(i, max(i - 30, 0), -1):
            m = re.search(r"movi\s+([A-Za-z_]\w*)\s*,\s*a0\b", lines[j])
            if m:
                tbl = m.group(1)
                break
        out.append((tbl or "<from caller>", hit, i + 1))
    return out


def order(path: Path, label: str, field: str):
    """the .long/.word rows of one table, in order"""
    t = path.read_text(encoding="latin-1")
    m = re.search(r"^" + label + r"\s*$", t, re.M)
    if not m:
        return None
    rows = []
    for ln in t[m.end():].split("\n")[1:]:
        s = ln.split(";")[0]
        if re.match(r"^\s*\." + field + r"\s", s):
            rows += [x.strip() for x in re.sub(r"^\s*\.\w+\s+", "", s).split(",") if x.strip()]
        elif s.strip() == "" or ln.lstrip().startswith(("*", ";")):
            continue
        else:
            break
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    drone = (SRC / "MKDRONE.ASM").read_text(encoding="latin-1")
    global DRONE_LINES
    DRONE_LINES = drone.splitlines()
    bad = []

    # is the feature even compiled in?
    eq = re.search(r"^kham_fight_as_guise\s+\.set\s+(\d+)",
                   (SRC / "MAINEQU.ASM").read_text(encoding="latin-1"), re.M)
    if not eq:
        print("MAINEQU.ASM: kham_fight_as_guise is gone")
        return 1
    on = eq.group(1) != "0"

    all_sites = sites(drone)
    by_tbl = {}
    for tbl, helper, line in all_sites:
        by_tbl.setdefault(tbl, []).append((helper, line))

    print("kham_fight_as_guise = %s   (%d table(s), %d site(s) in MKDRONE.ASM)"
          % (eq.group(1), len(by_tbl), len(all_sites)))
    print()
    print("%-26s %-6s %-28s %s" % ("TABLE", "SITES", "HELPERS", "CLASS"))
    print("-" * 92)
    for tbl in sorted(by_tbl):
        hs = sorted({h for h, _ in by_tbl[tbl]})
        if tbl == "<from caller>":
            cls = "n/a (table comes from the caller)"
        elif tbl in WORN:
            cls = "WORN - " + WORN[tbl]
        elif tbl in OWN:
            cls = "own  - " + OWN[tbl][:44]
        else:
            cls = "*** UNCLASSIFIED ***"
            bad.append("%s is read by the drone at line(s) %s and is in neither "
                       "WORN nor OWN - decide whether it should follow "
                       "Khameleon's disguise and add it to "
                       "tools/audit_kham_drone_rows.py"
                       % (tbl, ", ".join(str(l) for _, l in by_tbl[tbl])))
        print("%-26s %-6d %-28s %s" % (tbl[:26], len(by_tbl[tbl]), ",".join(hs)[:28], cls))

        for helper, line in by_tbl[tbl]:
            if helper == ANI and tbl in WORN:
                bad.append("%s:%d reads %s through get_char_ani, but it is "
                           "classified WORN - her FRAMES must stay her own"
                           % ("MKDRONE.ASM", line, tbl))
            if tbl in WORN and on and helper in SHARED:
                bad.append("%s:%d reads WORN table %s through the shared %s - "
                           "it should be the kd_ wrapper, or the disguise will "
                           "not reach it (this is the saih4 failure shape)"
                           % ("MKDRONE.ASM", line, tbl, helper))
            if tbl in OWN and helper in WRAPPED and (tbl, enclosing_label(
                    DRONE_LINES, line)) in BELL_PICK:
                continue
            if tbl in OWN and helper in WRAPPED:
                bad.append("%s:%d reads OWN table %s through %s - that table is "
                           "meant to stay on her own row 18 because: %s"
                           % ("MKDRONE.ASM", line, tbl, helper, OWN[tbl]))

    # Every zap_offsets read must be followed by the boomerang picker, for the
    # same reason the table classification above exists: jade_pick_boom is a
    # per-character refinement applied at CALL SITES, and a site that misses it
    # silently gives a CPU Jade her flat arc against a man in the air.
    jbp = re.search(r"^jade_boom_pick\s+\.set\s+(\d+)",
                    (SRC / "MAINEQU.ASM").read_text(encoding="latin-1"), re.M)
    if not jbp:
        bad.append("MAINEQU.ASM: jade_boom_pick is gone")
    elif jbp.group(1) != "0":
        dl = drone.split("\n")
        reads = [i for i, ln in enumerate(dl)
                 if re.search(r"movi\s+zap_offsets\s*,\s*a0\b", ln)
                 and not ln.lstrip().startswith(("*", ";"))]
        print("zap_offsets reads: %d, each must call jade_pick_boom" % len(reads))
        for i in reads:
            window = dl[i:i + 6]
            joined = "\n".join(window)
            if "jade_pick_boom" not in joined:
                bad.append("MKDRONE.ASM:%d reads zap_offsets without calling "
                           "jade_pick_boom - a CPU Jade would throw her flat "
                           "arc at a man in the air from this path" % (i + 1))
                continue
            pick = next(k for k, ln in enumerate(window) if "jade_pick_boom" in ln)
            legal = next((k for k, ln in enumerate(window)
                          if "drone_zap_legal" in ln), None)
            if legal is not None and legal < pick:
                bad.append("MKDRONE.ASM:%d asks drone_zap_legal BEFORE "
                           "jade_pick_boom - legality has to be tested on the "
                           "FINAL index, or she can throw a arc a player could "
                           "not throw right now" % (i + 1))

    # the two orders must agree
    worn = order(SRC / "MKDRONE.ASM", "kham_worn_ochars", "word")
    pals = order(SRC / "MKGUYS.ASM", "kham_disguise_pals", "long")
    print()
    if worn is None or pals is None:
        bad.append("kham_worn_ochars (MKDRONE) or kham_disguise_pals (MKGUYS) is missing")
    else:
        want = {"KHALTJ_P": "ft_jade", "KHALTK_P": "ft_fn1", "KHALTM_P": "ft_fn2"}
        print("disguise order: %s" % " -> ".join(pals))
        print("plays as:       %s" % " -> ".join(worn))
        if len(worn) != len(pals):
            bad.append("kham_worn_ochars has %d entries and kham_disguise_pals %d"
                       % (len(worn), len(pals)))
        else:
            for pal, och in zip(pals, worn):
                if want.get(pal) != och:
                    bad.append("disguise %s plays as %s - expected %s, so the "
                               "costume she is drawn in and the fighter she "
                               "plays as disagree" % (pal, och, want.get(pal)))

    print()
    if bad:
        for b in bad:
            print("FAIL: %s" % b)
        return 1 if a.check else 1
    print("kham drone rows OK - %d WORN, %d own, orders agree"
          % (sum(1 for t in by_tbl if t in WORN), sum(1 for t in by_tbl if t in OWN)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
