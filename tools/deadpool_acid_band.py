#!/usr/bin/env python3
"""Where the Dead Pool's acid actually is, in world x, straight from the art.

The Dead Pool stage fatality (`r_fall_in_slime`, BGND.ASM) throws the victim
into the pool BEHIND the walkway.  The pool is not the whole stage: outside a
band in the middle, the back plane paints the raised stone ledge under each
doorway instead, and a body that lands there splashes, bubbles and rises as a
skeleton on dry rock.

`dp_acid_raw_lft` / `dp_acid_raw_rgt` in BGND.ASM are that band, and they are
art-derived - re-cutting DEDPOOL.BDD moves the pool without touching a line of
source.  This measures the band the way the game composes it and, with
`--check`, fails the build if the equates have drifted off it.

    python tools/deadpool_acid_band.py            # report
    python tools/deadpool_acid_band.py --check    # Phase D
    python tools/deadpool_acid_band.py --dump tmp/dpul5.png

Why the numbers can be compared directly to a fighter's `oxpos`: DPUL5BMOD is
baklst1, `dedpool_scroll` gives plane 1 a rate of 020000h, and that is the same
1.0x `objlst` runs at - so a block in that module and a fighter share one
coordinate space with no parallax between them.  The acid rows are world y
188..199, the measurement `calla_dedpool`'s shadow clip is already built on.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The acid strip behind the walkway, in WORLD y.  DPUL5BMOD is placed at world
# y -88 and the stage runs worldtly -8, so module row = world y + 88.
ACID_WORLD_Y0, ACID_WORLD_Y1 = 188, 199
MODULE_ROW_BIAS = 88

# A column counts as acid when nearly every row across the strip is a dark
# green.  "Nearly" and not "every": the mossy stone above the pool shares a few
# of those colours, and the pool's own highlights break a row here and there.
MIN_ACID_ROWS = 11               # of the 12 rows in the strip
MIN_RUN = 64                     # ignore mossy speckle on the ledge


def _load_stage_preview():
    """stage_preview.py carries the BDB/BDD readers; reuse them rather than
    keeping a second copy of ldbgnd2.c's module-assignment rules."""
    path = ROOT / "tools" / "stage_preview.py"
    spec = importlib.util.spec_from_file_location("stage_preview", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _is_acid(c):
    r, g, b = c[:3]
    return g >= r and g > b and g <= 120 and r <= 110


def measure(dump: Path | None = None):
    sp = _load_stage_preview()
    from PIL import Image

    imgs, order, pals = sp.load_bdd(ROOT / "data" / "DEDPOOL.BDD")
    _name, _world, _npals, mods, blks = sp.load_bdb(ROOT / "data" / "DEDPOOL.BDB")
    sp.assign_modules(mods, blks, imgs, order)

    mod = next((m for m in mods if m["label"] + "BMOD" == "DPUL5BMOD"), None)
    if mod is None:
        raise SystemExit("DEDPOOL.BDB has no DPUL5BMOD - the back plane is gone")

    w = mod["x2"] - mod["x1"] + 1
    h = mod["y2"] - mod["y1"] + 1
    im = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    px = im.load()

    # blit() clips against stage_preview's screen constants; borrow them for the
    # module's own size so nothing is cropped.
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
        im.save(dump)

    rows = range(ACID_WORLD_Y0 + MODULE_ROW_BIAS, ACID_WORLD_Y1 + MODULE_ROW_BIAS + 1)
    rows = [r for r in rows if 0 <= r < h]
    hits = [sum(1 for r in rows if _is_acid(px[x, r])) for x in range(w)]

    runs, start = [], None
    for x, n in enumerate(hits + [0]):
        if n >= MIN_ACID_ROWS and start is None:
            start = x
        elif n < MIN_ACID_ROWS and start is not None:
            if x - start >= MIN_RUN:
                runs.append((start, x - 1))
            start = None
    if not runs:
        raise SystemExit("no acid found across world y "
                         f"{ACID_WORLD_Y0}..{ACID_WORLD_Y1} - has DEDPOOL.BDD moved?")
    # The pool is one strip; if the art ever cuts it in two, the outer edges are
    # still the only honest answer to "where can a body land".
    return runs[0][0], runs[-1][1], im


def _equates():
    """dp_* out of BGND.ASM.  They are plain .equ lines, and two of them are
    expressions over the others, so evaluate rather than pattern-match."""
    src = (ROOT / "src" / "BGND.ASM").read_text(encoding="latin-1", errors="replace")
    env = {}
    for name, expr in re.findall(r"^(dp_acid_\w+|dp_slime_arc)\s+\.equ\s+([^;\r\n]+)",
                                 src, re.M | re.I):
        expr = expr.strip()
        for k, v in env.items():
            expr = re.sub(rf"\b{k}\b", str(v), expr)
        env[name] = int(eval(expr, {"__builtins__": {}}, {}))
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if BGND.ASM's equates have drifted off the art")
    ap.add_argument("--dump", metavar="PNG",
                    help="also write the composed DPUL5BMOD plane here")
    args = ap.parse_args()

    lft, rgt, _im = measure(Path(args.dump) if args.dump else None)
    env = _equates()
    want_l, want_r = env.get("dp_acid_raw_lft"), env.get("dp_acid_raw_rgt")
    margin = env.get("dp_acid_margin")

    print(f"DEDPOOL acid, world x {lft}..{rgt}  ({rgt - lft + 1}px of pool)")
    print(f"  BGND.ASM dp_acid_raw_lft/rgt = {want_l}..{want_r}")
    if margin is not None:
        print(f"  landing band dp_acid_lft/rgt = {want_l + margin}.."
              f"{want_r - margin}  (margin {margin})")
        print(f"  fighters can reach world x 60..1098 "
              f"(gravity_n_bounds, left_padding/right_padding)")

    if not args.check:
        return 0

    bad = []
    if (want_l, want_r) != (lft, rgt):
        bad.append(f"acid band is {lft}..{rgt}, BGND.ASM says {want_l}..{want_r}")
    # The short arc throws him ~2*dp_slime_arc the other way; if the pool ever
    # gets narrower than that, neither arc can land inside it and the fatality
    # is relying on fis_hold_over_acid alone.
    arc = env.get("dp_slime_arc")
    if arc and margin is not None and (rgt - margin) - (lft + margin) < 2 * arc:
        bad.append(f"landing band is narrower than the short arc "
                   f"({(rgt - margin) - (lft + margin)}px < {2 * arc}px) - "
                   f"r_fall_in_slime can no longer guarantee a landing in it")
    if bad:
        for b in bad:
            print(f"FAIL: {b}")
        print("  the Dead Pool stage fatality aims at these numbers "
              "(r_fall_in_slime, BGND.ASM)")
        return 1
    print("OK: Dead Pool acid band matches BGND.ASM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
