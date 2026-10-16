#!/usr/bin/env python3
r"""MK1 KANO's move timings and knockbacks, out of a tools/mk1_kano_timing_probe.lua
run (kano.log: MOVE/P lines; blits.log).

For every MOVE: the frames Kano was drawn on, in order, each with the ticks it
was shown (startup / active / recovery), and how far the DEFENDER was knocked:
his drawn middle's furthest travel away from the attacker within 140 ticks,
and where he ended.  Kano attacking -> Sonya knocked; Sonya attacking -> Kano.

    python tools/mk1_kano_timing.py tmp/mk1kano_timing [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk1kano as rip      # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--json")
    a = ap.parse_args()
    run = Path(a.run)
    rom = rip.mk1.TRom(rip.mk1.ROMS / "mk.zip")
    L, names, frames, recs, pals = rip.read(rom)
    fid = {}
    for k, _a, fr, _s in L:
        for fi, (f, _dx, _dy) in enumerate(fr):
            key = tuple(sorted(rom.image(p)["sag"] for p in rom.pieces(f)))
            fid.setdefault(key, f"K{k:02X}_{fi + 1}")
    kano = {}
    for ln in open(run / "blits.log"):
        t = ln.split()
        if t[8] == "0303":
            kano.setdefault(int(t[0]), set()).add(int(t[2], 16))
    pos, moves = {}, []
    for ln in open(run / "kano.log"):
        m = re.match(r"P (\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+)", ln)
        if m:
            f, k0, k1, s0, s1 = map(int, m.groups())
            pos[f] = ((k0 + k1) / 2, (s0 + s1) / 2)
        m = re.match(r"MOVE (\d+) (\S+)(?: gap (-?\d+))?", ln)
        if m:
            moves.append((int(m.group(1)), m.group(2) + (f"@{m.group(3)}" if m.group(3) else "")))
    out = {}
    for f0, mv in moves:
        f1 = f0 + 140
        seq = []
        for f in range(f0 + 8, f1):
            if f not in kano:
                continue
            nm = fid.get(tuple(sorted(kano[f])), "?")
            if seq and seq[-1][0] == nm:
                seq[-1][1] += 1
            else:
                seq.append([nm, 1])
        defender = 1 if mv.startswith("kano") else 0
        sign = 1 if defender == 1 else -1          # Sonya is knocked right, Kano left
        xs = [(f, pos[f][defender]) for f in range(f0, f1) if f in pos]
        base = xs[0][1] if xs else 0
        far = max((sign * (x - base) for _f, x in xs), default=0)
        end = sign * (xs[-1][1] - base) if xs else 0
        out[mv] = dict(frames=seq, knock_max=far, knock_end=end)
        if mv.startswith("kano"):
            print(f"{mv:18s} knocked {far:5.0f} max, {end:5.0f} at rest | " + " ".join(f"{n}x{c}" for n, c in seq[:12]))
        else:
            print(f"{mv:18s} KANO knocked {far:5.0f} max, {end:5.0f} at rest | his frames " + " ".join(f"{n}x{c}" for n, c in seq[:12]))
    if a.json:
        Path(a.json).write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
