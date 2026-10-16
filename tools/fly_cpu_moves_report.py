#!/usr/bin/env python3
"""fly_cpu_moves_report.py - name what tools/fly_cpu_moves_probe.lua saw the CPU do.

  python tools/fly_cpu_moves_report.py C:/tmp/flybrain/prep_B/cpu_moves.txt [--char 15]

Action codes are named out of src/MAINEQU.ASM (`act_* .set NNNNh`); several names can share a
code, all are printed.  Fatalities are listed as the probe logged them.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHAR = {0: "KungLao", 1: "LiuKang", 2: "Cage", 3: "Baraka", 4: "Kitana", 5: "Mileena", 6: "Shang",
        7: "Raiden", 8: "SubZero", 9: "Reptile", 10: "Scorpion", 11: "Jax", 12: "Kintaro", 13: "ShaoKahn",
        14: "Smoke", 15: "Noob", 16: "Jade", 17: "Ermac", 18: "Khameleon", 19: "Rain"}


def act_names():
    names = {}
    with open(os.path.join(ROOT, "src", "MAINEQU.ASM"), errors="replace") as fh:
        for line in fh:
            m = re.match(r"^(act_\w+)\s+\.set\s+0*([0-9a-fA-F]+)h\b", line)
            if m:
                names.setdefault(int(m.group(2), 16), []).append(m.group(1))
    return names


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    only = int(sys.argv[sys.argv.index("--char") + 1]) if "--char" in sys.argv else None
    names = act_names()
    for line in open(sys.argv[1]):
        line = line.strip()
        if line.startswith("FATALITY"):
            if "f_death ffff" in line:
                continue          # an older probe logged round ends (f_death -1 = complete) too
            m = re.search(r"p1 (\d+) bar (\d+)  p2 (\d+) bar (\d+)", line)
            who = ""
            if m:
                p1, b1, p2, b2 = map(int, m.groups())
                who = "  -> %s on %s" % ((CHAR[p2], CHAR[p1]) if b2 > b1 else (CHAR[p1], CHAR[p2]))
            print(line + who)
        elif line.startswith("CPU"):
            parts = line.split()
            c = int(parts[1])
            if only is not None and c != only:
                continue
            print("\n== CPU %s (%d)" % (CHAR.get(c, "?"), c))
            rows = []
            for p in parts[2:]:
                a, n = p.split(":")
                rows.append((int(n), int(a, 16)))
            for n, a in sorted(rows, reverse=True):
                print("  %5d  %04x  %s" % (n, a, ", ".join(names.get(a, ["?"]))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
