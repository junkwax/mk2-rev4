#!/usr/bin/env python3
"""Where YOTEIGAI TOR's sea actually is, straight from the art.

The stage fatality (`r_fall_off_mountain`, BGND.ASM) uppercuts the victim off
the bridge and rides the camera 756 rows down `mount1BMOD` to the blood-red
sea at the mountain's foot.  Three numbers decide whether he lands in it:

    peak_sea_y          the waterline, world y
    peak_sea_lft/rgt    how far the sea runs, in PLANE 3's world x
    peak_fall_cam_y     the camera's floor - mount1's LAST row on the
                        screen's last row, so the module never runs out of
                        blocks and shows the autoerase colour

All three are art-derived: re-cutting MOUNTAIN.BDD moves the sea without
touching a line of source, exactly the failure tools/deadpool_acid_band.py
exists to catch on THE DEAD POOL.  This measures the sea the way the game
composes the module and, with `--check`, fails the build if BGND.ASM's
equates have drifted off it.

    python tools/peak_sea_band.py             # report
    python tools/peak_sea_band.py --check     # Phase D
    python tools/peak_sea_band.py --dump tmp/mount1.png

A note on coordinate spaces, because they are NOT the fighting plane's.
mount1BMOD is on baklst3 at a scroll rate of 08000h - a quarter of the deck's
020000h - so a fighter's `oxpos` and a block in this module only agree at one
camera position.  The x figures here are plane 3's own, which is what
`r_fall_off_mountain` converts live off `@worldtlx3`.  The Y figures ARE directly
comparable: every plane shares one `worldtly` (plane_info_table, BGND.ASM), so
there is no vertical parallax anywhere in the game.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# mount1BMOD's placement, out of peak_mod.  Module row = world y - this.
MODULE_WORLD_X = 304
MODULE_WORLD_Y = 82

# A column counts as sea when it holds a run of the crimson the base is painted
# in.  The rock above it is a desaturated mauve and the night sky behind is
# near-black, so a hard "red dominates" test separates them cleanly.
MIN_SEA_ROWS = 6                 # of the ~22 the sea is deep
MIN_RUN = 64                     # ignore red speckle in the rock face


def _load_stage_preview():
    """stage_preview.py carries the BDB/BDD readers; reuse them rather than
    keeping a second copy of ldbgnd2.c's module-assignment rules."""
    path = ROOT / "tools" / "stage_preview.py"
    spec = importlib.util.spec_from_file_location("stage_preview", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _is_sea(c):
    r, g, b = c[:3]
    return r > 55 and r > 2 * g + 15 and r > 2 * b + 15


def measure(dump: Path | None = None):
    sp = _load_stage_preview()
    from PIL import Image

    imgs, order, pals = sp.load_bdd(ROOT / "data" / "MOUNTAIN.BDD")
    _name, _world, _npals, mods, blks = sp.load_bdb(ROOT / "data" / "MOUNTAIN.BDB")
    sp.assign_modules(mods, blks, imgs, order)

    mod = next((m for m in mods if m["name"] == "mount1"), None)
    if mod is None:
        raise SystemExit("MOUNTAIN.BDB has no mount1 module - the mountain is gone")

    w = mod["x2"] - mod["x1"] + 1
    h = mod["y2"] - mod["y1"] + 1
    im = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    px = im.load()

    screen = sp.SCREEN_W, sp.SCREEN_H
    sp.SCREEN_W, sp.SCREEN_H = w, h
    try:
        for b in sorted(mod["blocks"], key=lambda b: ((b["z"] >> 8) & 0xFF, b["y"])):
            sp.blit(px, imgs[b["hdr"]], pals[b["pal"]][1],
                    b["x"] - mod["x1"], b["y"] - mod["y1"], bool(b["z"] & 0x10))
    finally:
        sp.SCREEN_W, sp.SCREEN_H = screen

    if dump:
        dump.parent.mkdir(parents=True, exist_ok=True)
        im.convert("RGB").save(dump)

    # Per column: the topmost sea row (the shoreline) and how deep it runs.
    tops, hits = {}, []
    for x in range(w):
        col = [y for y in range(h) if _is_sea(px[x, y])]
        hits.append(len(col))
        if col:
            tops[x] = min(col)

    runs, start = [], None
    for x, n in enumerate(hits + [0]):
        if n >= MIN_SEA_ROWS and start is None:
            start = x
        elif n < MIN_SEA_ROWS and start is not None:
            if x - start >= MIN_RUN:
                runs.append((start, x - 1))
            start = None
    if not runs:
        raise SystemExit("no sea found at the foot of mount1 - has MOUNTAIN.BDD moved?")

    lft, rgt = runs[0][0], runs[-1][1]
    surface = sorted(tops[x] for x in range(lft, rgt + 1) if x in tops)
    # Median, not min: a few columns of spray sit a row or two proud of the
    # waterline and one of them should not define where the splash goes.
    waterline = surface[len(surface) // 2]

    # The last row any block actually PAINTS over the water - the module's own
    # last row is 2 below it, and a camera parked on that one shows 2 rows of
    # sky along the bottom of the screen.
    painted = max(y for x in range(lft, rgt + 1) for y in range(h)
                  if px[x, y][:3] != (0, 0, 0))

    return dict(
        painted=painted + MODULE_WORLD_Y,
        lft=lft + MODULE_WORLD_X,
        rgt=rgt + MODULE_WORLD_X,
        waterline=waterline + MODULE_WORLD_Y,
        bottom=h - 1 + MODULE_WORLD_Y,
        spread=surface[-1] - surface[0],
    )


def _equates():
    """peak_* out of the files that hold them.  A mix of .set and .equ, and
    several are expressions over the others, so evaluate rather than
    pattern-match.

    The fatality's equates moved to PEAKFAT.ASM on 2026-09-22 when it was split
    out of BGND.ASM, and peak_ground_y went to MAINEQU.ASM because both objects
    need it and .set equates do not cross an object boundary.  All three are
    read, so this keeps working wherever a given equate ends up living.

    Order matters: the expressions are resolved against equates already seen,
    so MAINEQU.ASM is read FIRST - peak_fall_drop and peak_behind_y are written
    in terms of peak_ground_y, and reading PEAKFAT.ASM first silently skipped
    both of them."""
    src = ""
    for _f in ("MAINEQU.ASM", "PEAKFAT.ASM", "BGND.ASM"):
        _p = ROOT / "src" / _f
        if _p.exists():
            src += _p.read_text(encoding="latin-1", errors="replace") + "\n"
    env = {"scrbot": 253}
    pat = r"^(peak_\w+)\s+\.(?:equ|set)\s+([^;\r\n]+)"
    for name, expr in re.findall(pat, src, re.M | re.I):
        expr = expr.strip()
        if not re.fullmatch(r"[-+*/() \w]+", expr):
            continue                       # labels and table pointers
        try:
            for k in sorted(env, key=len, reverse=True):
                expr = re.sub(rf"\b{k}\b", str(env[k]), expr)
            env[name] = int(eval(expr, {"__builtins__": {}}, {}))
        except Exception:
            continue
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if BGND.ASM's equates have drifted off the art")
    ap.add_argument("--dump", metavar="PNG",
                    help="also write the composed mount1 plane here")
    args = ap.parse_args()

    sea = measure(Path(args.dump) if args.dump else None)
    env = _equates()

    print(f"mount1 sea, plane-3 world x {sea['lft']}..{sea['rgt']}"
          f"  ({sea['rgt'] - sea['lft'] + 1}px of water)")
    print(f"  waterline world y {sea['waterline']}  "
          f"(shoreline varies by {sea['spread']} rows across the span)")
    print(f"  mount1's last row  world y {sea['bottom']}")
    print(f"  peak_sea_lft/rgt = {env.get('peak_sea_lft')}.."
          f"{env.get('peak_sea_rgt')}, peak_sea_cx = {env.get('peak_sea_cx')}")
    print(f"  peak_sea_y       = {env.get('peak_sea_y')}")
    print(f"  peak_fall_cam_y  = {env.get('peak_fall_cam_y')}"
          f"  (art bottom - {253})")
    print(f"  peak_fall_drop   = {env.get('peak_fall_drop')}"
          f"  (feet from the deck line into the water)")

    if not args.check:
        return 0

    bad = []
    tol = 6                       # the shoreline is not ruler-straight
    if abs((env.get("peak_sea_y") or 0) - sea["waterline"]) > tol:
        bad.append(f"waterline is world y {sea['waterline']}, "
                   f"peak_sea_y says {env.get('peak_sea_y')}")
    if (env.get("peak_sea_lft"), env.get("peak_sea_rgt")) != (sea["lft"], sea["rgt"]):
        bad.append(f"sea runs plane-3 x {sea['lft']}..{sea['rgt']}, "
                   f"BGND.ASM says {env.get('peak_sea_lft')}..{env.get('peak_sea_rgt')}")
    cx = env.get("peak_sea_cx")
    if cx is not None and not sea["lft"] <= cx <= sea["rgt"]:
        bad.append(f"peak_sea_cx {cx} is outside the water")
    # The camera must stop with the module's last row on the screen's last row.
    # Lower and the autoerase colour shows as a black band under the sea.
    if env.get("peak_sea_bot") != sea["bottom"]:
        bad.append(f"mount1's last row is world y {sea['bottom']}, "
                   f"peak_sea_bot says {env.get('peak_sea_bot')}")
    if env.get("peak_art_bot") != sea["painted"]:
        bad.append(f"mount1's last PAINTED row is world y {sea['painted']}, "
                   f"peak_art_bot says {env.get('peak_art_bot')}")
    want_cam = sea["painted"] - 253
    if env.get("peak_fall_cam_y") != want_cam:
        bad.append(f"peak_fall_cam_y should be {want_cam} "
                   f"(mount1's art ends at world y {sea['painted']}), "
                   f"PEAKFAT.ASM says {env.get('peak_fall_cam_y')}")
    # And he has to end up IN the water, not above or under the art.
    drop = env.get("peak_fall_drop")
    gnd = env.get("peak_ground_y")
    if drop is not None and gnd is not None:
        feet = gnd + drop
        if not sea["waterline"] <= feet <= sea["bottom"]:
            bad.append(f"peak_fall_drop lands the feet at world y {feet}, "
                       f"outside the water ({sea['waterline']}..{sea['bottom']})")

    if bad:
        for b in bad:
            print(f"FAIL: {b}")
        print("  YOTEIGAI TOR's stage fatality aims at these numbers "
              "(r_fall_off_mountain, BGND.ASM)")
        return 1
    print("OK: Yoteigai Tor sea band matches BGND.ASM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
