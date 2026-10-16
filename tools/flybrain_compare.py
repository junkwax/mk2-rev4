#!/usr/bin/env python3
"""
flybrain_compare.py - the three-way comparison for the fly-brain player.

Reads each arm's rounds.csv / finishers.csv (tools/flybrain_play.lua output) and
reports, side by side:
  * learning curve: round win rate in consecutive blocks of rounds
  * win rate by CPU difficulty (the ladder raises it one step per battle, so a
    raw win rate rewards an arm for being stuck low - compare within a diff)
  * matches won / lost, highest battle reached
  * finishers attempted / landed, and by kind
Arms default to C:/tmp/flybrain/train/{full,nolearn,shuffled}.

    python tools/flybrain_compare.py
    python tools/flybrain_compare.py --block 40 --arm full=C:/tmp/flybrain/train/full
"""
import argparse
import csv
import os
from collections import defaultdict


def load(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="C:/tmp/flybrain/train")
    ap.add_argument("--arm", action="append", help="name=dir (repeatable); default full, nolearn, shuffled")
    ap.add_argument("--block", type=int, default=30, help="rounds per learning-curve block")
    args = ap.parse_args()
    arms = [a.split("=", 1) for a in args.arm] if args.arm else \
        [(n, os.path.join(args.root, n)) for n in ("full", "nolearn", "shuffled")]

    data = {}
    for name, d in arms:
        # run_flybrain_train.ps1 writes <arm>/seg01, seg02, ...; a plain run writes <arm>/rounds.csv
        segs = sorted((p for p in (os.path.join(d, x) for x in os.listdir(d)) if os.path.isdir(p)
                       and os.path.basename(p).startswith("seg")),
                      key=lambda p: int("".join(ch for ch in os.path.basename(p) if ch.isdigit()) or 0)) \
            if os.path.isdir(d) else []
        dirs = segs or [d]
        rounds, fins, offset = [], [], 0
        for sd in dirs:
            rr = [r for r in load(os.path.join(sd, "rounds.csv")) if r.get("winner") in ("FLY", "CPU", "DRAW")]
            for r in rr:  # frames restart per segment: make them cumulative
                r["frame"] = str(int(r["frame"]) + offset)
                r["game"] = f"{os.path.basename(sd)}:{r['game']}"
            if rr:
                offset = int(rr[-1]["frame"])
            rounds += rr
            fins += load(os.path.join(sd, "finishers.csv"))
        data[name] = (rounds, fins)

    print("== totals")
    print(f"{'arm':10} {'rounds':>6} {'won':>5} {'rate':>6} {'matches W-L':>12} {'top battle':>10} {'emu min':>8}")
    for name, (rounds, _) in data.items():
        won = sum(r["winner"] == "FLY" for r in rounds)
        matches = defaultdict(lambda: [0, 0])
        for r in rounds:
            k = (r["game"], r["battle"], r["cpu_char"], r["fly_char"])
            matches[k][0 if r["winner"] == "FLY" else 1] += 1
        mw = sum(1 for f, c in matches.values() if f >= 2)
        ml = sum(1 for f, c in matches.values() if c >= 2)
        top = max((int(r["battle"]) for r in rounds), default=0)
        mins = int(rounds[-1]["frame"]) / 54.7 / 60 if rounds else 0
        rate = won / len(rounds) if rounds else 0
        print(f"{name:10} {len(rounds):6} {won:5} {rate:6.1%} {mw:5}-{ml:<6} {top:10} {mins:8.0f}")

    print(f"\n== learning curve: round win rate per {args.block} rounds")
    width = max(len(r) for r, _ in data.values()) // args.block + 1 if data else 0
    print(f"{'block':>6} " + " ".join(f"{n:>9}" for n in data))
    for b in range(width):
        cells = []
        for name, (rounds, _) in data.items():
            chunk = rounds[b * args.block:(b + 1) * args.block]
            if len(chunk) < args.block // 2:
                cells.append(f"{'':>9}")
            else:
                w = sum(r["winner"] == "FLY" for r in chunk)
                d = sum(int(r["diff"]) for r in chunk) / len(chunk)
                cells.append(f"{w / len(chunk):5.0%} d{d:<3.1f}")
        if all(not c.strip() for c in cells):
            break
        print(f"{b + 1:6} " + " ".join(cells))

    print("\n== round win rate by CPU difficulty (rounds)")
    diffs = sorted({int(r["diff"]) for rounds, _ in data.values() for r in rounds})
    print(f"{'diff':>4} " + " ".join(f"{n:>14}" for n in data))
    for dv in diffs:
        cells = []
        for name, (rounds, _) in data.items():
            rr = [r for r in rounds if int(r["diff"]) == dv]
            w = sum(r["winner"] == "FLY" for r in rr)
            cells.append(f"{(w / len(rr)) if rr else 0:6.0%} ({len(rr):3})" if rr else f"{'-':>14}")
        print(f"{dv:4} " + " ".join(cells))

    print("\n== second half vs first half (is it getting better?)")
    for name, (rounds, _) in data.items():
        h = len(rounds) // 2
        if h < 10:
            continue
        def rate_at(rr, dv):
            x = [r for r in rr if int(r["diff"]) == dv]
            return (sum(r["winner"] == "FLY" for r in x) / len(x), len(x)) if x else (None, 0)
        parts = []
        for dv in diffs:
            a, na = rate_at(rounds[:h], dv)
            b, nb = rate_at(rounds[h:], dv)
            if a is not None and b is not None and na >= 5 and nb >= 5:
                parts.append(f"d{dv}: {a:.0%}->{b:.0%}")
        print(f"  {name:10} " + ("  ".join(parts) if parts else "(not enough rounds per difficulty yet)"))

    print("\n== finishers (FINISH HIM windows the fly won)")
    for name, (_, fins) in data.items():
        att = defaultdict(int)
        ok = defaultdict(int)
        for f in fins:
            kind = f["option"]
            att[kind] += 1
            ok[kind] += f["success"] == "1"
        landed = sum(ok.values())
        s = ", ".join(f"{k} {ok[k]}/{att[k]}" for k in sorted(att, key=lambda k: -ok[k]) if ok[k]) or "none landed"
        print(f"  {name:10} attempts {sum(att.values()):4}  landed {landed:3}  | {s}")


if __name__ == "__main__":
    main()
