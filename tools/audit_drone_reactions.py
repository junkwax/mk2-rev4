#!/usr/bin/env python
"""Audit the drone's reaction tables for LIVE actions with no handler.

`beware_lookup` (MKDRONE.ASM) turns the opponent's action into a reaction
handler: the action's high byte indexes `catagory_table`, the low byte indexes
the sub-table it names, and **0 means "no handler"** - the drone does nothing
at all about that move.

A 0 is correct for an action nobody ever sets. It is a silent hole for one that
IS set: the drone's threat system simply cannot see the move. That is exactly
what made Cage's ceiling uppercut unbeatable - `counter_propell` row 20f was 0
under a comment claiming `act_jc_ceiling` was never set, while `do_jc_ceiling`
sets it on its third instruction. The row below it carries a note about the
same class of bug being found once before, so this is the third occurrence.

So: find every action the game actually assigns, look up the handler the drone
would find for it, and report the ones that resolve to 0.

    python tools/audit_drone_reactions.py           # report
    python tools/audit_drone_reactions.py --check   # exit 1 if any are found

A finding is not automatically a bug - plenty of actions are things the drone
has no business reacting to (its own states, cosmetic ones). The value is that
the list is SHORT and each entry can be judged, instead of the hole being
invisible.
"""

import argparse
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")


def read(path):
    with open(path, "r", encoding="latin-1") as fh:
        return fh.read()


def num(tok):
    tok = tok.strip()
    m = re.fullmatch(r"0?([0-9A-Fa-f]+)[hH]", tok)
    if m:
        return int(m.group(1), 16)
    if re.fullmatch(r"\d+", tok):
        return int(tok)
    return None


def act_equates():
    """act_* name -> value, from MAINEQU.ASM."""
    out = {}
    for m in re.finditer(r"^(act_\w+)\s+\.set\s+(\S+)", read(os.path.join(SRC, "MAINEQU.ASM")), re.M):
        v = num(m.group(2))
        if v is not None:
            out[m.group(1)] = v
    return out


def actions_that_are_set():
    """act_* names the game actually writes into p_action."""
    live = set()
    # `movi act_x,aN` / `movk act_x,aN` anywhere, then a store to p_action - but
    # the two are often separated, and some paths pass the action in a1 through
    # a helper (init_special_act, reaction_start). Naming the action in a movi
    # at all is the honest signal: the constant has no other use.
    pat = re.compile(r"\bmov[ki]\s+(act_\w+)\s*,\s*a\d+")
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        for m in pat.finditer(read(path)):
            live.add(m.group(1))
    return live


def table_rows(txt, label):
    """The `.long` entries following a label, in order, until the next label."""
    m = re.search(r"^%s\s*$" % re.escape(label), txt, re.M)
    if not m:
        return []
    rows = []
    for line in txt[m.end():].splitlines():
        code = line.split(";")[0].strip()
        if not code:
            continue
        mm = re.match(r"\.long\s+(.+)$", code, re.I)
        if mm:
            for tok in mm.group(1).split(","):
                rows.append(tok.strip())
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*", code):
            break
    return rows


# Rows that ARE 0 and are meant to be. Judged once, with the reason, so the
# report separates "decided against" from "nobody has looked".
DELIBERATE = {
    "act_square": "climbs 224px before travelling - passes over a standing "
                  "opponent (0 connections in 11), and an airborne victim "
                  "cannot block anyway",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    drone = read(os.path.join(SRC, "MKDRONE.ASM"))
    cats = table_rows(drone, "catagory_table")
    if not cats:
        print("could not find catagory_table")
        return 1

    equ = act_equates()
    live = actions_that_are_set()

    # value -> the names that share it (act_* values are not unique)
    by_val = {}
    for name, val in equ.items():
        by_val.setdefault(val, []).append(name)

    holes, declined, checked = [], [], 0
    for name, val in sorted(equ.items(), key=lambda kv: kv[1]):
        if name not in live:
            continue
        cat, low = (val >> 8) & 0xFF, val & 0xFF
        if cat >= len(cats):
            holes.append((name, val, "category %02xh past the end of catagory_table" % cat))
            continue
        sub = cats[cat]
        if sub == "0":
            continue                       # whole category unhandled, by design
        rows = table_rows(drone, sub)
        checked += 1
        if low >= len(rows):
            holes.append((name, val, "row %02xh past the end of %s (%d rows)" % (low, sub, len(rows))))
        elif rows[low] == "0":
            if name in DELIBERATE:
                declined.append((name, val, DELIBERATE[name]))
            else:
                holes.append((name, val, "%s row %02xh is 0 - no handler" % (sub, low)))

    print("%d act_* equates, %d of them assigned somewhere" % (len(equ), len(live)))
    print("%d resolved through catagory_table\n" % checked)

    if not holes:
        print("No live action resolves to a missing handler.")
        return 0

    print("LIVE ACTIONS THE DRONE HAS NO REACTION FOR (%d)\n" % len(holes))
    for name, val, why in holes:
        alias = [n for n in by_val[val] if n != name]
        extra = ("  (= %s)" % ", ".join(sorted(alias))) if alias else ""
        print("  %-22s %04xh  %s%s" % (name, val, why, extra))

    if declined:
        print("")
        print("DECIDED AGAINST, with the reason (%d):" % len(declined))
        for name, val, why in declined:
            print("  %-22s %04xh  %s" % (name, val, why))

    print("\nEach still needs judging - an action the drone should ignore is")
    print("legitimately 0.  What this rules out is not KNOWING.")
    if args.check:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
