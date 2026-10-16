#!/usr/bin/env python3
"""Count sky-blue pixels inside THE THRONE ROOM's throne box in the snapshots
tools/run_mk1throne_chair_test.ps1 -Mode shang takes while the camera sweeps.

The log line `[chair] SNAP n p4=X` gives plane 4's camera for snapshot n; the
throne's box is CHAIR_XY (tools/make_thrnchair.py) minus that.  The stage's
erase colour is the sky, so any erase-coloured pixel in the box is a leak -
the fault a start-camera-only patch had.  Exit 1 on any leak, 2 if there was
nothing to judge."""
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import make_thrnchair as tc  # noqa: E402

SKY = (115, 181, 206)        # thr.rgb of the record's erase colour
TOP_SCREEN = 33              # CHAIR_XY y minus the stage's world y (20)


def main():
    log = ROOT / "tools" / "mk1throne_chair_test_shang.log"
    shots = sorted((ROOT / "tools" / "screens" / "mk1throne_chair" / "shang" / "mk2").glob("*.png"))
    snaps = [int(m.group(1)) for m in re.finditer(r"SNAP \d+ p4=(-?\d+)", log.read_text())]
    shots = shots[-len(snaps):] if snaps else []
    judged = bad = 0
    for p4, path in zip(snaps, shots):
        im = Image.open(path).convert("RGB")
        if im.size != (400, 254):
            im = im.resize((400, 254), Image.NEAREST)
        sx = tc.CHAIR_XY[0] - p4
        px = im.load()
        n = sum(1 for y in range(TOP_SCREEN, TOP_SCREEN + 152) for x in range(max(0, sx), min(400, sx + 107))
                if px[x, y] == SKY)
        if sx + 107 <= 0 or sx >= 400:
            continue
        judged += 1
        bad += n > 0
        print(f"{path.name} p4={p4} throne x={sx}: {n} sky pixel(s) in the box")
    if not judged:
        print("NO VERDICT: no snapshot had the throne on screen")
        return 2
    print(f"{'PASS' if not bad else 'FAIL'}: {judged} frames, {bad} with sky in the throne box")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
