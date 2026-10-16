#!/usr/bin/env python3
"""Turn a freeplay lab-trace CSV of you-vs-CPU into concrete AI findings.

The recorder (freeplay-gametalk, F9) writes one row per frame:

    frame,p1_in,p2_in,p1_act,p2_act,p1_hp,p2_hp,p1_x,p2_x,gap,p1_y,p2_y

That is enough to reconstruct the fight, and the questions worth asking of it
are not "who won" but:

  * WHICH OF YOUR MOVES LAND.  Every drop in the drone's health, attributed to
    whatever you had started.  This is the list of things it fails to answer.
  * WHAT IT WAS DOING WHEN IT GOT HIT.  A drone hit while walking has a
    positioning problem; hit while recovering from its own whiffed move has a
    discipline problem.  Different fixes.
  * WHAT YOU DO THAT IT NEVER PUNISHES.  Your moves that end with no damage to
    you inside the following second: free habits, which is what an exploitable
    CPU feels like from the other side.
  * WHERE, in distance.  A move that only lands at one range points at a gap
    in that range's decision table rather than at the move itself.
  * WHAT YOU REPEAT.  Bigrams of your own actions: if you have a two-move
    habit, a training partner ought to start reading it.

Action ids are read from MAINEQU.ASM, never hardcoded -- they are .set
equates, absent from MK2.MAP, so a typo cannot be caught by a symbol lookup
and would silently mislabel the whole report.

Usage:
    python tools/analyze_lab_session.py <trace.csv> [--top N] [--you 1|2]
"""
from __future__ import annotations

import argparse
import csv
import pathlib
import re
import sys
from collections import Counter, defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAINEQU = ROOT / "src" / "MAINEQU.ASM"

# A hit registers a frame or two after the move starts; a punish that is going
# to happen at all happens well inside a second.
ATTRIBUTE_BACK = 24     # frames to look back from a health drop for its cause
PUNISH_WINDOW = 60      # frames after your move in which a counter-hit counts
# What counts as "not a move". Derived from the source, not hand-listed:
# MAINEQU marks the non-attack block with `act_nonattacks .set 0300h`, so
# everything in 03xx is stance/duck/walk/land/getup. A hand-written set missed
# act_backup and the report counted walking as an attack you threw.
NONATTACK_BASE, NONATTACK_SPAN = 0x0300, 0x0100


def load_actions() -> dict[int, str]:
    """act_* equates -> short names, from the assembler source."""
    if not MAINEQU.exists():
        print(f"warning: {MAINEQU} not found; ids will be shown as hex", file=sys.stderr)
        return {}
    out: dict[int, str] = {}
    pat = re.compile(r"^act_([A-Za-z0-9_]+)\s+\.set\s+([0-9a-fA-F]+)h")
    for line in MAINEQU.read_text(errors="replace").splitlines():
        m = pat.match(line)
        if m:
            out.setdefault(int(m.group(2), 16), m.group(1))
    return out


def is_move(raw: str) -> bool:
    """True if this action is an actual attack rather than a neutral state."""
    raw = (raw or "").strip()
    if not raw or raw == "----":
        return False
    try:
        v = int(raw, 16)
    except ValueError:
        return False
    return not (NONATTACK_BASE <= v < NONATTACK_BASE + NONATTACK_SPAN)


def name_of(acts: dict[int, str], raw: str) -> str:
    raw = (raw or "").strip()
    if not raw or raw == "----":
        return "----"
    try:
        return acts.get(int(raw, 16), f"0x{int(raw, 16):04x}")
    except ValueError:
        return raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--you", choices=["1", "2"], default="1",
                    help="which side you played (default 1)")
    args = ap.parse_args()

    path = pathlib.Path(args.csv_path)
    if not path.exists():
        print(f"no such trace: {path}", file=sys.stderr)
        return 2

    acts = load_actions()
    me, cpu = ("p1", "p2") if args.you == "1" else ("p2", "p1")

    rows = []
    with path.open(newline="") as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append({
                    "frame": int(r["frame"]),
                    "me_raw": (r[f"{me}_act"] or "").strip(),
                    "me_act": name_of(acts, r[f"{me}_act"]),
                    "cpu_act": name_of(acts, r[f"{cpu}_act"]),
                    "me_hp": int(r[f"{me}_hp"] or 0),
                    "cpu_hp": int(r[f"{cpu}_hp"] or 0),
                    "gap": int(r["gap"] or 0),
                })
            except (KeyError, ValueError):
                continue
    if len(rows) < 2:
        print("trace too short to analyse", file=sys.stderr)
        return 2

    # Your moves: each frame where your action changes to a non-idle one.
    my_moves = []          # (frame, action, gap)
    for i in range(1, len(rows)):
        a, prev = rows[i]["me_act"], rows[i - 1]["me_act"]
        if a != prev and is_move(rows[i]["me_raw"]):
            my_moves.append((rows[i]["frame"], a, rows[i]["gap"]))

    f_index = {r["frame"]: i for i, r in enumerate(rows)}

    landed = Counter()         # your move -> times the CPU lost health after it
    dmg_by_move = Counter()    # your move -> total damage dealt
    gap_of_hit = defaultdict(list)
    cpu_state_when_hit = Counter()
    my_damage_taken = Counter()

    for i in range(1, len(rows)):
        # CPU lost health -> attribute to whatever you had most recently started
        drop = rows[i - 1]["cpu_hp"] - rows[i]["cpu_hp"]
        if 0 < drop < 0x60:
            cause = None
            for f, a, g in reversed(my_moves):
                if 0 <= rows[i]["frame"] - f <= ATTRIBUTE_BACK:
                    cause = (a, g)
                    break
            if cause:
                landed[cause[0]] += 1
                dmg_by_move[cause[0]] += drop
                gap_of_hit[cause[0]].append(cause[1])
            cpu_state_when_hit[rows[i - 1]["cpu_act"]] += 1

        # You lost health -> what the CPU had started
        drop_me = rows[i - 1]["me_hp"] - rows[i]["me_hp"]
        if 0 < drop_me < 0x60:
            my_damage_taken[rows[i - 1]["cpu_act"]] += drop_me

    # Which of your moves went unpunished: no damage to you within the window.
    thrown = Counter(a for _, a, _ in my_moves)
    punished = Counter()
    for f, a, _ in my_moves:
        i = f_index.get(f)
        if i is None:
            continue
        j, hp0 = i, rows[i]["me_hp"]
        while j < len(rows) and rows[j]["frame"] - f <= PUNISH_WINDOW:
            if rows[j]["me_hp"] < hp0:
                punished[a] += 1
                break
            j += 1

    # Your two-move habits: what a predictor could learn.
    seq = [a for _, a, _ in my_moves]
    bigrams = Counter(zip(seq, seq[1:]))

    W, N = 26, args.top
    print(f"\n=== lab session: {path.name} ===")
    print(f"{len(rows)} frames, you = P{args.you}, {len(my_moves)} moves thrown\n")

    print("YOUR MOVES THAT LAND ON THE DRONE  (what it fails to answer)")
    print(f"  {'move':<{W}} {'landed':>6} {'thrown':>7} {'hit%':>5} {'dmg':>6} {'median gap':>11}")
    for a, n in dmg_by_move.most_common(N):
        t = thrown[a] or 1
        gaps = sorted(gap_of_hit[a])
        med = gaps[len(gaps) // 2] if gaps else 0
        print(f"  {a:<{W}} {landed[a]:>6} {t:>7} {100*landed[a]//t:>4}% {n:>6} {med:>11}")

    print("\nWHAT THE DRONE WAS DOING WHEN IT GOT HIT")
    print("  (walking = positioning problem; recovering from its own move = discipline)")
    for a, n in cpu_state_when_hit.most_common(N):
        print(f"  {a:<{W}} {n:>6}")

    print("\nYOUR MOVES IT NEVER PUNISHES  (free habits - fix these first)")
    print(f"  {'move':<{W}} {'thrown':>7} {'punished':>9} {'free%':>6}")
    free = []
    for a, t in thrown.most_common():
        if t >= 3:
            p = punished[a]
            free.append((100 * (t - p) // t, a, t, p))
    for pct, a, t, p in sorted(free, reverse=True)[:N]:
        print(f"  {a:<{W}} {t:>7} {p:>9} {pct:>5}%")

    print("\nWHAT HURTS YOU  (the drone's answers that work)")
    for a, n in my_damage_taken.most_common(N):
        print(f"  {a:<{W}} {n:>6}")

    print("\nYOUR REPEATED PAIRS  (a predictor could read these)")
    for (a, b), n in bigrams.most_common(N):
        if n >= 2:
            print(f"  {a} -> {b:<{W}} {n:>4}")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
