#!/usr/bin/env python3
"""Find and measure Ermac's telekinetic slam in a frame-per-tick UMK3 capture.

Feed it the folder tools/run_umk3_observe.ps1 filled (MAME's snap/umk3).  It
does two things:

**Run-length analysis** - the point of the whole exercise.  The capture is one
PNG per emulated frame, so a pose that is held for N ticks appears as N
byte-identical frames in a row.  Counting those runs recovers the tick rate,
which is the one thing Ermac's animation lanes do NOT carry in the ROM (neither
lane has a sleep; the caller sets it - see doc/UMK3_ERMAC_TELESLAM.md).

**Airborne detection** - the slam suspends the victim ~130px up, so frames with
a lot of moving content high on the screen are candidates.  Measured as
difference from a rolling background estimate rather than by colour, because
the stages are busy and every character has a different palette.

    python tools/find_umk3_slam.py                     # scan + report
    python tools/find_umk3_slam.py --sheet 400 460     # contact sheet a range
    python tools/find_umk3_slam.py --runs              # every run, not a summary
"""
import argparse
import hashlib
import sys
from pathlib import Path

SNAP = Path(r"C:\MAME\snap\umk3")

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow:  python -m pip install pillow")


def frames(folder):
    fs = sorted(folder.glob("*.png"))
    if not fs:
        sys.exit("no PNGs in %s - run tools/run_umk3_observe.ps1 first" % folder)
    return fs


def digest(path):
    return hashlib.sha1(path.read_bytes()).hexdigest()


def runs_of(files):
    """[(start_index, count, digest)] over byte-identical consecutive frames."""
    out, prev, start = [], None, 0
    for i, f in enumerate(files):
        d = digest(f)
        if d != prev:
            if prev is not None:
                out.append((start, i - start, prev))
            prev, start = d, i
    out.append((start, len(files) - start, prev))
    return out


def airborne(files, top_frac=0.45, sample=1):
    """Per-frame 'how much content is high on the screen and moving'.

    A rolling median over the whole capture is a decent background estimate:
    the fighters move, the stage mostly does not.  Returns a list of scores
    aligned with `files`.
    """
    import statistics
    ims = []
    for f in files[::sample]:
        im = Image.open(f).convert("L").resize((100, 64))
        ims.append(list(im.getdata()))
    if not ims:
        return []
    bg = [statistics.median(px[i] for px in ims) for i in range(len(ims[0]))]
    w, h = 100, 64
    cut = int(h * top_frac)
    scores = []
    for px in ims:
        s = 0
        for y in range(cut):
            base = y * w
            for x in range(w):
                if abs(px[base + x] - bg[base + x]) > 40:
                    s += 1
        scores.append(s)
    return scores


def sheet(files, a, b, out, cols=10, scale=1):
    sel = files[a:b]
    if not sel:
        sys.exit("empty range")
    ims = [Image.open(f) for f in sel]
    w, h = ims[0].size
    if scale != 1:
        w, h = int(w * scale), int(h * scale)
        ims = [im.resize((w, h)) for im in ims]
    rows = (len(ims) + cols - 1) // cols
    pad = 3
    sh = Image.new("RGB", (cols * w + pad * (cols + 1), rows * h + pad * (rows + 1)),
                   (15, 15, 25))
    for i, im in enumerate(ims):
        r, c = divmod(i, cols)
        sh.paste(im, (pad + c * (w + pad), pad + r * (h + pad)))
    sh.save(out)
    print("wrote %s  (%d frames %d..%d)" % (out, len(sel), a, b - 1))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", type=Path, default=SNAP)
    ap.add_argument("--runs", action="store_true", help="list every run")
    ap.add_argument("--sheet", nargs=2, type=int, metavar=("FROM", "TO"))
    ap.add_argument("--out", type=Path, default=Path("umk3_sheet.png"))
    ap.add_argument("--cols", type=int, default=10)
    ap.add_argument("--scale", type=float, default=1.0)
    args = ap.parse_args()

    files = frames(args.dir)
    print("%d frames in %s" % (len(files), args.dir))

    if args.sheet:
        sheet(files, args.sheet[0], args.sheet[1], args.out, args.cols, args.scale)
        return 0

    rl = runs_of(files)
    held = [r for r in rl if r[1] > 1]
    print("\n%d distinct frames, %d of them held for more than one tick" %
          (len(rl), len(held)))
    if rl:
        import collections
        hist = collections.Counter(c for _, c, _ in rl)
        print("\nrun length -> how often (this IS the tick rate distribution)")
        for n in sorted(hist):
            print("  %2d tick(s)  x%d" % (n, hist[n]))

    if args.runs:
        print("\nevery run:")
        for s, c, _ in rl:
            print("  frame %5d  held %d" % (s, c))

    print("\nlooking for a body high on the screen...")
    sc = airborne(files)
    if sc:
        top = sorted(range(len(sc)), key=lambda i: -sc[i])[:40]
        top.sort()
        # group neighbouring hits into candidate segments
        segs, cur = [], [top[0]]
        for i in top[1:]:
            if i - cur[-1] <= 8:
                cur.append(i)
            else:
                segs.append(cur); cur = [i]
        segs.append(cur)
        segs.sort(key=lambda s: -sum(sc[i] for i in s))
        print("candidate segments, busiest first:")
        for s in segs[:6]:
            print("  frames %5d .. %-5d  peak score %d"
                  % (s[0], s[-1], max(sc[i] for i in s)))
        print("\nsheet one with:")
        print("  python tools/find_umk3_slam.py --sheet %d %d --out slam.png"
              % (max(0, segs[0][0] - 10), segs[0][-1] + 20))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
