#!/usr/bin/env python3
"""drone_decisions_report.py - what the CPU chooses, and what each choice costs it.

Reads the CSV written by tools/drone_decision_log.lua (FB_ADDON on any fly rig run) and
reports, per range band and per chosen action: how often the drone lands something in the
next 60 frames, how often it gets hit instead, and the net.

This is the DECISION half of the CPU picture. The rest of the tooling measures reactions -
whether the drone punishes a recovery or guards a projectile. This measures what it picks
when nothing is being done to it: drone_stalk picks a band (d_close 050h, d_med 070h,
d_far 0c0h) and close_rapid_pick and its siblings pick a move.

It is deliberately free of the inference that made the whiff screen misfire. There, intent
was inferred from an absence ("the fly dealt no damage") and that bundled together attacks
that hit, attacks that were blocked, and moments the drone could not act at all. Here the
drone's own p_action says what it chose and the bars say what it cost.

Action names are PARSED from src/MAINEQU.ASM, never hardcoded: a table of `act_*` values
copied into a script goes stale the first time somebody adds a move, and a decision logged
against the wrong name is worse than one logged against a number.

    python tools/drone_decisions_report.py C:/tmp/flybrain/dronedec
    python tools/drone_decisions_report.py DIR --min 40
"""
import argparse
import collections
import csv
import glob
import math
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def action_names():
    """act_* -> name, parsed from MAINEQU.ASM.

    Two values carry more than one name (0200 body_propell/flykick, 0700 blocks/blockhi), so
    every name is kept and joined. Taking the first would have labelled the drone's BLOCK rows
    "blocks", which reads like a move rather than a guard - a row nobody would question and
    everybody would misread.
    """
    names = collections.defaultdict(list)
    path = os.path.join(ROOT, "src", "MAINEQU.ASM")
    with open(path, encoding="latin-1") as fh:
        for line in fh:
            m = re.match(r"^(act_\w+)\s+\.set\s+0?([0-9a-fA-F]+)h", line)
            if m:
                names[int(m.group(2), 16)].append(m.group(1)[4:])
    return {k: "/".join(v) for k, v in names.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--min", type=int, default=25, help="decisions a cell needs before it is ranked")
    a = ap.parse_args()
    names = action_names()
    rows = []
    for d in a.dirs:
        for f in (glob.glob(os.path.join(d, "**", "drone_decisions.csv"), recursive=True)
                  if os.path.isdir(d) else [d]):
            with open(f, newline="") as fh:
                rows += list(csv.DictReader(fh))
    if not rows:
        print("no decisions logged - is drone_decision_log.lua set as FB_ADDON?")
        return
    agg = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
    for r in rows:
        try:
            act, dealt, taken = int(r["act"], 16), int(r["dealt"]), int(r["taken"])
        except (ValueError, TypeError, KeyError):
            continue
        if r.get("band") == "out":
            continue
        e = agg[(r["band"], act, r.get("fly_busy", "?"))]
        e[0] += 1; e[1] += dealt > 0; e[2] += taken > 0; e[3] += dealt; e[4] += taken

    print("%d decisions. fly_busy=1 means the choice was made into something the fly was already"
          % len(rows))
    print("doing, =0 into open space - a choice that only loses when the fly is busy is a timing")
    print("problem, one that loses in open space is the choice itself.\n")
    print("  %-6s %-20s %-4s %5s  %6s %8s  %7s" %
          ("band", "chose", "busy", "n", "lands", "gets hit", "net hp"))
    out = []
    for (band, act, busy), (n, dh, th, d, t) in agg.items():
        if n < a.min:
            continue
        net = (d - t) / n
        out.append((net, band, names.get(act, "%04x" % act), busy, n, 100 * dh / n, 100 * th / n))
    for net, band, name, busy, n, dh, th in sorted(out):
        flag = "  <- LOSES" if net < 0 else ("  <- thin" if net < 2 else "")
        print("  %-6s %-20s %-4s %5d  %5.0f%% %7.0f%%  %+7.1f%s" % (band, name, busy, n, dh, th, net, flag))


if __name__ == "__main__":
    main()
