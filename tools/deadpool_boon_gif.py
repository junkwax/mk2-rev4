#!/usr/bin/env python3
"""Assemble a Dead Pool acid-drop filmstrip into a GIF you can scrub.

The rig's -SnapEvery mode drops a PNG every N ticks from the trigger to the
parked skeleton.  This stitches them up.

Two things it does that a plain "encode every frame" would not:

  * DEDUPE, which in practice almost never fires and says so.  The simmer is
    a 300-tick hold for the BODY, but the round clock is counting and the
    stage's own acid bubbles keep animating, so no two frames are ever byte
    identical.  --range is the real answer to dead air: the filmstrip starts at
    the trigger, so shot index = ticks-since-trigger / --every, and the log's
    BEATS line converts any beat into an index.

  * A real time base.  One captured frame is N game ticks and a tick is
    18.28 ms, so the true duration of a captured frame is N * 18.28 ms.
    --slow multiplies that, which is what "watch it slower" actually means -
    the GIF stays honest about the pacing instead of guessing a frame rate.

    python tools/deadpool_boon_gif.py <run_dir> --every 3 --slow 2
"""
import argparse
import pathlib
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit("needs Pillow:  python -m pip install Pillow")

# T-unit refresh straight from MAME's driver: refresh_attoseconds =
# 18,279,250,000,000,000.  ATTOseconds -> ms is /1e15, not /1e12.
TICK_MS = 18279250000000000 / 1e15  # 18.279 ms


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", help="tools/screens/deadpool_boon_drop/run_...")
    ap.add_argument("--every", type=int, default=3,
                    help="game ticks between captured PNGs (the rig's -SnapEvery)")
    ap.add_argument("--slow", type=float, default=2.0,
                    help="playback multiplier; 2 = half speed")
    ap.add_argument("--max-hold", type=int, default=700,
                    help="ms cap on any one held frame (the simmer)")
    ap.add_argument("--pick", type=int, default=1,
                    help="use every Nth captured shot (thins the GIF, same span)")
    ap.add_argument("--range", default=None, metavar="A:B",
                    help="shot index range, e.g. 0:74 for the sink alone")
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--colors", type=int, default=64,
                    help="palette size; GIF is paletted anyway, so this is free size")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    run = pathlib.Path(a.run_dir)
    shots = sorted((run / "mk2").glob("*.png")) or sorted(run.glob("*.png"))
    if not shots:
        return print(f"no PNGs under {run}") or 1

    if a.range:
        lo, _, hi = a.range.partition(":")
        shots = shots[int(lo or 0):int(hi) if hi else None]
    if a.pick > 1:
        shots = shots[::a.pick]
    if not shots:
        return print("range/pick selected no shots") or 1

    per_frame_ms = a.every * a.pick * TICK_MS * a.slow

    frames: list[Image.Image] = []
    holds: list[float] = []
    for path in shots:
        im = Image.open(path).convert("RGB")
        if a.scale != 1:
            im = im.resize((im.width * a.scale, im.height * a.scale), Image.NEAREST)
        im = im.quantize(colors=a.colors, method=Image.MEDIANCUT).convert("RGB")
        if frames and ImageChops.difference(im, frames[-1]).getbbox() is None:
            holds[-1] += per_frame_ms          # identical: extend the hold
        else:
            frames.append(im)
            holds.append(per_frame_ms)

    holds = [min(h, a.max_hold) for h in holds]
    out = pathlib.Path(a.out) if a.out else run / "acid_drop.gif"
    frames[0].save(out, save_all=True, append_images=frames[1:],
                   duration=[int(round(h)) for h in holds], loop=0, optimize=True)

    total = sum(holds) / 1000.0
    real = len(shots) * a.every * a.pick * TICK_MS / 1000.0
    print(f"{out}")
    print(f"  {len(shots)} shots -> {len(frames)} frames after dedupe "
          f"({len(shots) - len(frames)} were held stills)")
    print(f"  {real:.1f}s of game time played back over {total:.1f}s "
          f"({a.slow:g}x slower, capped holds)")
    print(f"  {out.stat().st_size / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
