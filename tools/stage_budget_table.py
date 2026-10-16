#!/usr/bin/env python3
"""
Per-stage frame budget, from run_runtime_budget.py sweeps (one matchup on every
stage).  Turns their JSON into one markdown table, worst blitter headroom first.

    python tools/stage_budget_table.py tmp/stage_sweep/tunit.json [tmp/stage_sweep/wolf.json ...]

Columns (raster lines out of 289 a frame, fight only, mean / peak):
  drain    lines from the display interrupt's start until the object queue ran
           EMPTY - when the blitter was handed the frame's last queued blit.
           289 - peak is the headroom left before a frame's tail (the HUD) is
           abandoned (dmaq_late)
  dirq     the display interrupt itself (list walk + queuing)
  shadows  the shadow block, logic = the process pass (% of the frame)
  blits    queued blits per frame (last_dmaq / 6)
"""
import json
import sys
from pathlib import Path

NAMES = {0: "THE DEAD POOL", 1: "KOMBAT TOMB", 2: "THE WASTELAND", 3: "THE TOWER",
         4: "LIVING FOREST", 5: "THE ARMORY", 6: "THE PIT II (bridge)", 7: "THE PORTAL",
         8: "KAHN'S ARENA", 9: "GORO'S LAIR", 0x0A: "PIT BOTTOM", 0x16: "OUTER HAVEN",
         0x18: "YOTEIGAI TOR", 0x19: "THE CAVE (MK3)", 0x1A: "THE PIT (MK1)",
         0x1B: "WARRIOR SHRINE (MK1)", 0x1C: "THRONE ROOM (MK1)", 0x1D: "COURTYARD (MK1)",
         0x1E: "PALACE GATES (MK1)", 0x1F: "SCORPION'S LAIR (UMK3)", 0x20: "JADE'S DESERT (UMK3)"}


def main():
    rows = []
    for path in sys.argv[1:]:
        rep = json.loads(Path(path).read_text(encoding="utf-8"))
        board = "Wolf" if "umk3" in rep.get("rom_zip", "") else "T-unit"
        for r in rep["scenarios"]:
            if r.get("dqd_peak") is None:
                rows.append((999, board, r["stage"], r, False))
                continue
            rows.append((289 - r["dqd_peak"], board, r["stage"], r, True))
    rows.sort(key=lambda t: (t[0], t[1], t[2]))
    print("| stage | board | drain mean / peak | headroom | dirq | shadows | logic | blits mean / peak |")
    print("|---|---|---|---:|---|---|---:|---|")
    for head, board, st, r, ok in rows:
        name = f"{NAMES.get(st, '?')} ({st:02X}h)"
        if not ok:
            print(f"| {name} | {board} | no reading ({r.get('sweep')}) | | | | | |")
            continue
        print(f"| {name} | {board} | {r['dqd_mean']:.0f} / {r['dqd_peak']} | {head} | "
              f"{r['dqi_mean']:.0f} / {r['dqi_peak']} | {r['dqs_mean']:.0f} / {r['dqs_peak']} | "
              f"{r['cpu_pct']:.1f}% | {r['blits_mean']:.0f} / {r['blits_peak']} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
