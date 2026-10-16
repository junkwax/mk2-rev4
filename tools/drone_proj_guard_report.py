#!/usr/bin/env python3
"""Does the drone's guard survive a projectile?  The A/B behind f6448e95.

Reads drone_proj_guard.csv from one or two arms and answers ONE question:

    of the projectiles thrown while the drone was holding its guard,
    how many did it BLOCK rather than eat CLEAN?

f6448e95 taught drone_guard_hold / drone_wait_nonattack / drone_wait_non to ask
is_he_busy instead of is_he_attacking.  is_he_attacking masks to the high byte and
accepts only 0100h/0200h, and all 25 projectile actions are category 0 - so before the
fix those loops read a fireball as "he is free", fell through to their counter, and the
drone dropped its guard and walked into it.

The rows with guard_at_throw=0 are the CONTROL: the drone was not guarding, so the fix
cannot reach them and they must NOT move.  An arm where both groups shift is measuring
something else - a build difference, a seed difference, or the rig.
"""
import argparse, collections, csv, os, sys


def load(path):
    if not os.path.exists(path):
        sys.exit("no such file: %s" % path)
    with open(path, newline="") as fh:
        return [r for r in csv.DictReader(fh)]


def summarise(rows):
    """Split into guarding / not-guarding, and count outcomes in each."""
    out = {}
    for guard in (1, 0):
        sub = [r for r in rows if int(r["guard_at_throw"]) == guard]
        c = collections.Counter(r["outcome"] for r in sub)
        contact = c["BLOCKED"] + c["HIT"]
        out[guard] = {
            "throws": len(sub), "blocked": c["BLOCKED"], "hit": c["HIT"],
            "nocontact": c["NOCONTACT"], "contact": contact,
            "block_pct": (100.0 * c["BLOCKED"] / contact) if contact else None,
            "hold": ([int(r["hold"]) for r in sub if int(r["hold"]) >= 0] or [0]),
            "dmg": ([int(r["dmg"]) for r in sub if r["outcome"] in ("BLOCKED", "HIT")] or [0]),
        }
    return out


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def show(label, s):
    print("  %s" % label)
    for guard, name in ((1, "guard UP at the throw  (the fix reaches these)"),
                        (0, "guard DOWN at the throw (control - must not move)")):
        g = s[guard]
        pct = "  n/a" if g["block_pct"] is None else "%5.1f%%" % g["block_pct"]
        print("    %-42s throws=%-5d contact=%-5d blocked=%-5d hit=%-5d  block rate %s"
              % (name, g["throws"], g["contact"], g["blocked"], g["hit"], pct))
        print("      %-40s mean guard held %.1f frames, mean damage %.1f"
              % ("", mean(g["hold"]), mean(g["dmg"])))


ACTNAME = {0x0700: "block-hi", 0x0701: "block-lo", 0x0302: "duck"}


def by_action(rows):
    """Split the guard-UP rows by WHICH waiting state, so block and duck are visible
    separately - drone_guard_hold is entered blocking, drone_wait_nonattack is also
    entered ducking from drone_duck_upcut, and they need not move together."""
    out = collections.OrderedDict()
    for r in rows:
        if int(r["guard_at_throw"]) != 1:
            continue
        a = int(r["d_act_throw"], 16)
        k = ACTNAME.get(a, "%04x" % a)
        d = out.setdefault(k, collections.Counter())
        d[r["outcome"]] += 1
    return out


def show_actions(label, rows):
    t = by_action(rows)
    if not t:
        return
    print("    %s - guard-UP rows by waiting state:" % label)
    for k, c in t.items():
        contact = c["BLOCKED"] + c["HIT"]
        pct = "  n/a" if not contact else "%5.1f%%" % (100.0 * c["BLOCKED"] / contact)
        print("      %-10s contact=%-5d blocked=%-5d hit=%-5d  block rate %s"
              % (k, contact, c["BLOCKED"], c["HIT"], pct))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("after", help="drone_proj_guard.csv from the AFTER arm")
    ap.add_argument("--before", help="the same file from the BEFORE arm")
    a = ap.parse_args()

    rows_after = load(a.after)
    arms = [("AFTER  (f6448e95, is_he_busy)", summarise(rows_after), rows_after)]
    if a.before:
        rb = load(a.before)
        arms.insert(0, ("BEFORE (is_he_attacking)", summarise(rb), rb))

    print("PROJECTILE vs THE DRONE'S GUARD")
    print("=" * 78)
    for label, s, raw in arms:
        show(label, s)
        show_actions(label, raw)
        print()

    if len(arms) == 2:
        b, f = arms[0][1], arms[1][1]
        print("VERDICT")
        print("-" * 78)
        for guard, name in ((1, "guard UP  (the fix's target)"),
                            (0, "guard DOWN (control)")):
            bb, ff = b[guard], f[guard]
            if bb["contact"] < 20 or ff["contact"] < 20:
                print("  %-28s NO VERDICT - only %d/%d contacts, too few to call"
                      % (name, bb["contact"], ff["contact"]))
                continue
            d = ff["block_pct"] - bb["block_pct"]
            print("  %-28s block rate %5.1f%% -> %5.1f%%   (%+.1f pts)"
                  % (name, bb["block_pct"], ff["block_pct"], d))
        print()
        print("  Read it as a FIX only if the guard-UP rate rises AND the control")
        print("  stays put.  Both moving means the arms differ by more than the fix.")


if __name__ == "__main__":
    main()
