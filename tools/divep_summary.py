#!/usr/bin/env python3
"""divep_summary.py - add up a run of drone_divepunish logs.

One run of tools/run_drone_divepunish_test.ps1 is a handful of blocked dives,
so a single log proves very little: the whiff being measured is one third of a
random that only fires when drone_antiair_try's roll declines. Totals across
seeds are the unit of evidence, and this prints them.

    python tools/divep_summary.py tools/divep_before
    python tools/divep_summary.py tools/divep_after tools/divep_before

Two numbers matter and they answer different questions:

  act_hh_sd window   what the report is about - swings taken while Kung Lao is
                     in the blocked-dive recovery
  airborne swings     every swing the drone starts at a man off the floor,
                     whatever put him there. Much bigger sample, and the gate
                     under test (rt_airborn_close) does not care why he is up
                     there either. NOTE it also catches swings this fix does
                     not touch - a sweep out of c_land, say - so read the
                     per-move breakdown, not just the total.
"""
import glob
import os
import re
import sys


def summarise(directory):
    tot = dict(dives=0, blocked=0, w_sw=0, w_hit=0, w_wh=0,
               a_sw=0, a_hit=0, a_wh=0, runs=0, stalls=0)
    moves, wmoves = {}, {}
    for path in sorted(glob.glob(os.path.join(directory, "*.log"))):
        text = open(path, errors="replace").read()
        m = re.search(r"dives=(\d+) blocked=(\d+)", text)
        if not m:
            continue
        tot["runs"] += 1
        tot["dives"] += int(m.group(1))
        tot["blocked"] += int(m.group(2))
        # "STALL no dive" only - the rig also writes STALL-VERDICT / STALL-STACK /
        # STALL-REGS diagnostics for the same stall, which a bare "STALL" prefix
        # counted four times over (8 real stalls reported as 32).
        tot["stalls"] += len(re.findall(r"^\[divep\] STALL no dive", text, re.M))
        tot["crashes"] = tot.get("crashes", 0) + len(re.findall(r"STALL-VERDICT CRASH", text))
        m = re.search(r"act_hh_sd window: (\d+)  hit=(\d+)  WHIFF=(\d+)", text)
        if m:
            tot["w_sw"] += int(m.group(1))
            tot["w_hit"] += int(m.group(2))
            tot["w_wh"] += int(m.group(3))
        m = re.search(r"AIRBORNE opponent: (\d+)  hit=(\d+)  WHIFF=(\d+)", text)
        if m:
            tot["a_sw"] += int(m.group(1))
            tot["a_hit"] += int(m.group(2))
            tot["a_wh"] += int(m.group(3))
        # per-move: the window lines have no "air " prefix, the airborne ones do
        for name, sw, hit, wh in re.findall(
                r"^\[divep\]    air (\S+)\s+swings=(\d+) hit=(\d+) whiff=(\d+)",
                text, re.M):
            e = moves.setdefault(name, [0, 0, 0])
            e[0] += int(sw); e[1] += int(hit); e[2] += int(wh)
        for name, sw, hit, wh in re.findall(
                r"^\[divep\]    (?!air )(\S+)\s+swings=(\d+) hit=(\d+) whiff=(\d+)",
                text, re.M):
            e = wmoves.setdefault(name, [0, 0, 0])
            e[0] += int(sw); e[1] += int(hit); e[2] += int(wh)
    return tot, moves, wmoves


def report(directory):
    tot, moves, wmoves = summarise(directory)
    print(f"=== {directory}  ({tot['runs']} run(s), {tot['stalls']} stalled, "
          f"{tot.get('crashes', 0)} of them CRASH)")
    if not tot["runs"]:
        print("    no logs with a RESULT line - nothing to add up")
        return
    print(f"    dives={tot['dives']}  blocked={tot['blocked']}")
    print(f"    act_hh_sd window: swings={tot['w_sw']} hit={tot['w_hit']} "
          f"WHIFF={tot['w_wh']}")
    for name, e in sorted(wmoves.items()):
        print(f"        {name:12s} swings={e[0]} hit={e[1]} whiff={e[2]}")
    print(f"    airborne swings:  swings={tot['a_sw']} hit={tot['a_hit']} "
          f"WHIFF={tot['a_wh']}")
    for name, e in sorted(moves.items()):
        print(f"        {name:12s} swings={e[0]} hit={e[1]} whiff={e[2]}")


if __name__ == "__main__":
    dirs = sys.argv[1:] or ["tools/divep_before", "tools/divep_after"]
    for d in dirs:
        report(d)
