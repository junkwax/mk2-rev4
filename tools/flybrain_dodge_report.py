#!/usr/bin/env python3
"""
flybrain_dodge_report.py - read tools/flybrain_dodge.lua runs and answer: does the
fly's looming circuit time a dodge better than shuffled circuits or a rule?

1. calibration  - for every (attacker, threat, distance, action), the dodge rate of
   the `fixed` controller at each jump frame, plus the no-reaction hit rate. A
   setup is DODGEABLE if no reaction gets hit most of the time and some fixed
   frame dodges it most of the time; everything else cannot tell controllers apart.
2. controllers  - dodge rate per controller family and parameter on dodgeable
   setups only, and each family's best parameter.
3. real vs shuffled - the real circuit against the three rewirings pooled, both at
   their best gain, with Fisher's exact test.

    python tools/flybrain_dodge_report.py C:/tmp/flybrain/dodge_cal_7 C:/tmp/flybrain/dodge_cal_2 ...
"""
import csv
import math
import sys
from collections import defaultdict


def fisher_two_sided(a, b, c, d):
    """2x2 table [[a, b], [c, d]] -> two-sided exact p."""
    n1, n2, k = a + b, c + d, a + c
    n = n1 + n2

    def logc(x, y):
        return math.lgamma(x + 1) - math.lgamma(y + 1) - math.lgamma(x - y + 1)

    def p_of(x):
        return math.exp(logc(n1, x) + logc(n2, k - x) - logc(n, k))

    p0 = p_of(a)
    lo, hi = max(0, k - n2), min(k, n1)
    return min(1.0, sum(p_of(x) for x in range(lo, hi + 1) if p_of(x) <= p0 * (1 + 1e-9)))


def main():
    rows = []
    for d in sys.argv[1:]:
        with open(d.rstrip("/\\") + "/trials.csv", newline="") as fh:
            rows += [r for r in csv.DictReader(fh) if r["valid"] == "1"]
    if not rows:
        print("no valid trials")
        return
    setup = lambda r: (r["p2"], r["threat"], int(r["dist"]), r["action"])

    print(f"{len(rows)} valid trials\n")
    print("== 1. calibration: dodge rate by fixed jump frame (n per cell), and with no reaction")
    by_setup = defaultdict(list)
    for r in rows:
        by_setup[setup(r)].append(r)
    dodgeable = set()
    for s in sorted(by_setup):
        rs = by_setup[s]
        none = [r for r in rs if r["family"] == "none"]
        none_hit = sum(r["hit"] == "1" for r in none) / len(none) if none else float("nan")
        fixed = defaultdict(list)
        for r in rs:
            if r["family"] == "fixed":
                fixed[int(r["param"])].append(r["hit"] == "0")
        cells = []
        best = 0.0
        for f in sorted(fixed):
            v = fixed[f]
            rate = sum(v) / len(v)
            best = max(best, rate if len(v) >= 2 else 0)
            cells.append(f"{f}:{rate:.0%}({len(v)})")
        ok = (none and none_hit >= 0.7 and best >= 0.5)
        if ok:
            dodgeable.add(s)
        print(f"  {s[0]:8} {s[1]:6} {s[2]:3}px {s[3]:5} no-reaction hit {none_hit:4.0%} ({len(none)})"
              f"  {'DODGEABLE' if ok else 'not usable':10}  " + " ".join(cells))

    print(f"\n{len(dodgeable)} dodgeable setup(s)")
    if not dodgeable:
        print("nothing to compare controllers on")
        return

    print("\n== 2. controllers on dodgeable setups: dodge rate by parameter")
    fam = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if setup(r) in dodgeable and r["family"] not in ("none", "fixed"):
            fam[r["family"]][r["param"]].append(r["hit"] == "0")
    best = {}
    for f in sorted(fam):
        cells = []
        for p in sorted(fam[f], key=lambda x: float(x)):
            v = fam[f][p]
            cells.append(f"{p}:{sum(v) / len(v):.0%}({len(v)})")
        bp = max(fam[f], key=lambda p: (sum(fam[f][p]) / len(fam[f][p]), len(fam[f][p])))
        best[f] = (bp, sum(fam[f][bp]), len(fam[f][bp]))
        allv = [x for p in fam[f] for x in fam[f][p]]
        print(f"  {f:7} all params {sum(allv) / len(allv):4.0%} ({len(allv):3})  |  " + " ".join(cells))

    print("\n== 3. real circuit vs shuffled circuits (each at its best gain, shuffles pooled)")
    if "real" in best:
        rp, rd, rn = best["real"]
        sd = sn = 0
        for f in ("shuf7", "shuf11", "shuf13"):
            if f in best:
                sd += best[f][1]
                sn += best[f][2]
        if sn:
            p = fisher_two_sided(rd, rn - rd, sd, sn - sd)
            print(f"  real (gain {rp}): {rd}/{rn} = {rd / rn:.0%}    shuffled (best gains): {sd}/{sn} = {sd / sn:.0%}"
                  f"    Fisher p = {p:.3g}")
        if "rule" in best:
            bp, bd, bn = best["rule"]
            p = fisher_two_sided(rd, rn - rd, bd, bn - bd)
            print(f"  real (gain {rp}): {rd / rn:.0%}    rule (D={bp}): {bd}/{bn} = {bd / bn:.0%}    Fisher p = {p:.3g}")
    print("\n  (best-parameter picks are made on the same trials they are scored on, so each family's")
    print("   best is optimistic by the same amount - compare families, not absolute rates)")


if __name__ == "__main__":
    main()
