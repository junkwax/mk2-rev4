#!/usr/bin/env python3
r"""MK1 KANO against MK1: move timing and knockback, side by side.

MK1's side comes from tools/mk1_kano_timing.py --json (a run of
tools/mk1_kano_timing_probe.lua in MAME `mk`); ours from a run of
tools/wolf_kano_timing.lua on the Wolf ROM.  Both runs play the same script
(same moves, same gaps, direction held first).  Our frames are named back to
MK1's lanes through src/MK1KNL.ASM's own frame table (kn_K<lane>_<n> lists the
records it draws), so a row reads K26_4x20 in both games when they agree.

For each move: the frame sequence with ticks per frame, the total, and the
defender's knockback (furthest travel away from the attacker, and at rest).

    python tools/kano_timing_compare.py MK1.json WOLF_RUN_DIR
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def frame_names():
    """'REC+REC+...' -> 'K26_4' out of MK1KNL.ASM's frame lists."""
    out = {}
    for ln in (ROOT / "src" / "MK1KNL.ASM").read_text(encoding="latin-1").splitlines():
        m = re.match(r"kn_(K[0-9A-F]{2}_\d+)\s+\.long\s+(.*)", ln)
        if m:
            recs = [r.strip() for r in m.group(2).split(";")[0].split(",") if r.strip() not in ("", "0")]
            out.setdefault("+".join(recs), m.group(1))
    return out


def ours(run: Path):
    names = frame_names()
    moves, pos = [], {}
    for ln in open(run / "probe.log"):
        m = re.match(r"P (\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+) (\S*)", ln)
        if m:
            f = int(m.group(1))
            pos[f] = ((int(m.group(2)) + int(m.group(3))) / 2, (int(m.group(4)) + int(m.group(5))) / 2,
                      names.get(m.group(6), "?"))
        m = re.match(r"MOVE (\d+) (\S+) gap (-?\d+)", ln)
        if m:
            moves.append((int(m.group(1)), m.group(2), int(m.group(3))))
    res = {}
    for f0, mv, gap in moves:          # a repeated move (the morph reverted mid-way): the last wins
        seq = []
        for f in range(f0 + 8, f0 + 140):
            if f not in pos:
                continue
            nm = pos[f][2]
            if seq and seq[-1][0] == nm:
                seq[-1][1] += 1
            else:
                seq.append([nm, 1])
        defender = 1 if mv.startswith("kano") else 0
        sign = 1 if defender == 1 else -1
        xs = [pos[f][defender] for f in range(f0, f0 + 140) if f in pos]
        far = max((sign * (x - xs[0]) for x in xs), default=0)
        end = sign * (xs[-1] - xs[0]) if xs else 0
        res[mv.replace("jax_", "sonya_")] = dict(frames=seq, knock_max=far, knock_end=end, gap=gap)
    return res


def fmt(seq, n=11):
    return " ".join(f"{a}x{c}" for a, c in seq[:n])


def main():
    mk1 = json.loads(Path(sys.argv[1]).read_text())
    mk1 = {re.sub(r"@-?\d+$", "", k): v for k, v in mk1.items()}
    us = ours(Path(sys.argv[2]))
    for mv, m in mk1.items():
        u = us.get(mv)
        print(f"== {mv}")
        print(f"   MK1   knock {m['knock_max']:4.0f}/{m['knock_end']:4.0f} | {fmt(m['frames'])}")
        if u:
            print(f"   OURS  knock {u['knock_max']:4.0f}/{u['knock_end']:4.0f} | {fmt(u['frames'])}")
        else:
            print("   OURS  (not run)")


if __name__ == "__main__":
    main()
