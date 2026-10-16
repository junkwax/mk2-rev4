#!/usr/bin/env python3
"""Fast shadows (shad_fast, graphics audit row 01) through FINISHERS.

The stage sweep (doc/graphics_opportunities/STAGE_SHADOW_SWEEP.md) proved the
two-blit shadow path identical to the stock row loop in ordinary fights on
every stage, and listed fatalities, bosses and round transitions as not
covered.  This covers them with the finisher rigs tools/run_fatality_budget.py
already drives - Scorpion's toasty, Raiden's lift, Kung Lao's split, Kahn's
fatality, the Shang soul escape with Kintaro's drop - each through its round
end.  Every rig runs twice on one frozen ROM:

  fast    the stage's own @shad_fast (the wrapper logs what the stage asked for)
  legacy  @shad_fast forced to 0 every frame: the stock row-by-row loop

and every snapshot the rig takes is compared pixel for pixel.

    python tools/run_fatality_shadow_ab.py --build tmp/reflect_fx/build
    python tools/run_fatality_shadow_ab.py --build tmp/reflect_fx/build --only kahn_fatality,souls
"""
from __future__ import annotations

import argparse
import json
import re
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

import run_fatality_budget as rfb

ROOT = Path(__file__).resolve().parents[1]
# denser capture than the budget run, which turned these rigs' snapshots off
SNAP_ENV = {"kahn_fatality": dict(KAHN_SNAP_EVERY="10"), "souls": dict(SSE_SNAP_EVERY="10")}


def compare(a_dir: Path, b_dir: Path):
    a = sorted((a_dir / "snap").rglob("*.png"))
    b = sorted((b_dir / "snap").rglob("*.png"))
    same, worst, differing = 0, 0, []
    for i, (x, y) in enumerate(zip(a, b)):
        ia = np.asarray(Image.open(x).convert("RGB"))
        ib = np.asarray(Image.open(y).convert("RGB"))
        if ia.shape != ib.shape:
            differing.append((i, "shape"))
            continue
        d = int(np.any(ia != ib, axis=2).sum())
        if d == 0:
            same += 1
        else:
            differing.append((i, d))
            worst = max(worst, d)
    return dict(fast_snaps=len(a), legacy_snaps=len(b), identical=same, worst_px=worst,
                differing=differing[:20])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", type=Path, required=True)
    ap.add_argument("--only", help="comma list of scenario labels")
    ap.add_argument("--rejudge", type=Path)
    args = ap.parse_args()
    scns = rfb.SCENARIOS
    if args.only:
        want = set(args.only.split(","))
        scns = [s for s in scns if s[0] in want]
    if args.rejudge:
        run = args.rejudge
    else:
        out = ROOT / "tmp/fatality_shadow_ab"
        out.mkdir(parents=True, exist_ok=True)
        run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
        fr = run / "frozen"
        rfb.freeze(args.build, fr)
        for s in scns:
            extra = SNAP_ENV.get(s[0], {})
            rfb.boot(s, fr, run, extra_env=extra, tag="fast")
            rfb.boot(s, fr, run, extra_env=dict(extra, FB_SHADFAST="0"), tag="legacy")
    ok, results = True, []
    for label, _, _, _, vpat in scns:
        fast, legacy = run / (label + "_fast"), run / (label + "_legacy")
        fb = (fast / "fb.log").read_text(errors="replace") if (fast / "fb.log").exists() else ""
        modes = sorted({int(v) for v in re.findall(r"SHADFAST_SET \S+ value=(\d+)", fb)})
        m = re.search(r"FINISHER_START .* shad_fast=(\w+) curback=(\w+)", fb)
        res = dict(label=label, stage_modes_seen=modes, at_finisher=m.groups() if m else None)
        res.update(compare(fast, legacy))
        for tag, d in (("fast", fast), ("legacy", legacy)):
            text = ""
            for name in ("rig.log", "mame.log"):
                if (d / name).exists():
                    text = (d / name).read_text(errors="replace")
                    if re.search(vpat, text):
                        break
            v = re.search(vpat, text)
            res["verdict_" + tag] = v.group(0).strip()[:120] if v else "no verdict"
        good = (res["fast_snaps"] == res["legacy_snaps"] and res["fast_snaps"] > 0
                and res["identical"] == res["fast_snaps"] and m is not None and m.group(1) not in ("0", "na"))
        res["passed"] = good
        ok &= good
        results.append(res)
        print("%-14s modes %s at finisher (shad_fast, curback)=%s | snaps %d/%d identical %d worst %d px | %s"
              % (label, modes, res["at_finisher"], res["fast_snaps"], res["legacy_snaps"], res["identical"],
                 res["worst_px"], "PASS" if good else "FAIL"))
        print("               fast: %s\n               legacy: %s" % (res["verdict_fast"], res["verdict_legacy"]))
    (run / "summary.json").write_text(json.dumps(dict(passed=ok, results=results), indent=2) + "\n")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
