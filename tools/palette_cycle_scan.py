"""Find background palette ramps worth cycling, and measure what they'd move.

Row 14 of doc/GRAPHICS_OPPORTUNITIES.md: `cycle_forward` rotates a run of a
palette in place, so apparent motion costs no art, no object and no process
beyond the one `pid_cycle`.  The question is not whether the helper works -
three stages already use it - but whether any UNCYCLED authored ramp covers
enough of a screen, in a coherent enough shape, for a rotation to read as
motion instead of noise.

Two passes:

  --ramps     smooth triangle ramps in src/BGNDPAL.ASM (a run whose luminance
              rises then falls, i.e. something authored to be rotated)
  --coverage  for a given stage/palette/run, how many pixels of the composed
              stage actually draw from it (uses tools/stage_preview.py)

    python tools/palette_cycle_scan.py --ramps
    python tools/palette_cycle_scan.py --coverage forest FOREST SHRUB1 04 6

The coverage number is the one that decides it.  A 20-step luminance span on a
ramp nothing draws from is worth nothing.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Runs the ROM already rotates: dedpool_cycle, battle_cycle, armory_cycle
# (src/BGND.ASM).  A hit on one of these is a control, not a candidate.
CYCLED = {("NESS_P", 0x01), ("WATER", 0x21), ("VAT", 0x2d)}


def palettes():
    txt = (ROOT / "src/BGNDPAL.ASM").read_text(errors="replace")
    out = {}
    for label in re.findall(r"^([A-Za-z_]\w*):", txt, re.M):
        m = re.search(r"^%s:[^\n]*\n((?:\s*\.word[^\n]*\n)+)" % re.escape(label), txt, re.M)
        if not m:
            continue
        vals = []
        for ln in m.group(1).splitlines():
            for v in re.findall(r"[0-9A-Fa-f]+H|\d+", ln.split(";")[0].replace(".word", "")):
                vals.append(int(v[:-1], 16) if v.upper().endswith("H") else int(v))
        if vals and vals[0] < 257:
            out.setdefault(label, vals[1:1 + vals[0]])
    return out


def rgb(c):
    return ((c >> 10) & 31, (c >> 5) & 31, c & 31)


def lum(c):
    return sum(rgb(c))


def step(a, b):
    return max(abs(x - y) for x, y in zip(rgb(a), rgb(b)))


def ramps(min_len=6, max_step=4, min_span=9):
    """A run that climbs strictly to a peak and falls back, in even-ish steps.

    Strict on purpose: a rotation only reads as motion if the run is smooth
    (no step bigger than `max_step` per gun), roughly symmetric about its peak,
    and spans enough luminance to see.  Loosening any of these floods the list
    with runs that are just neighbouring colours.
    """
    hits = []
    for label, p in palettes().items():
        if len(p) < 8:
            continue
        n, s = len(p), 1
        while s < n - (min_len - 1):
            best = None
            for L in range(min(24, n - s), min_len - 1, -1):
                run = p[s:s + L]
                ls = [lum(c) for c in run]
                k = ls.index(max(ls))
                if not 1 <= k <= L - 2:
                    continue
                if not all(ls[i] < ls[i + 1] for i in range(k)):
                    continue
                if not all(ls[i] > ls[i + 1] for i in range(k, L - 1)):
                    continue
                if any(step(run[i], run[i + 1]) > max_step for i in range(L - 1)):
                    continue
                if max(ls) - min(ls) < min_span:
                    continue
                if abs(k - (L - 1 - k)) > 2:          # roughly symmetric
                    continue
                best = (max(ls) - min(ls), label, s, L, run)
                break
            if best:
                hits.append(best)
                s += best[3]
            else:
                s += 1
    return sorted(hits, reverse=True)


def coverage(stage, bdb, pal, start, count):
    """Pixels of the composed stage drawn from pal[start .. start+count)."""
    sys.path.insert(0, str(ROOT / "tools"))
    prev = ROOT / "tools/palcycle_preview.py"
    r = subprocess.run([sys.executable, str(prev), stage, bdb, pal, start, str(count)],
                       capture_output=True, text=True, cwd=str(ROOT))
    m = re.search(r"pixels using \S+: (\d+)", r.stdout)
    if not m:
        raise SystemExit(r.stdout + r.stderr)
    return int(m.group(1))


ap = argparse.ArgumentParser()
ap.add_argument("--ramps", action="store_true")
ap.add_argument("--coverage", nargs=5, metavar=("STAGE", "BDB", "PAL", "START_HEX", "COUNT"))
args = ap.parse_args()

if args.coverage:
    stage, bdb, pal, start, count = args.coverage
    px = coverage(stage, bdb, pal, start, int(count))
    print(f"{pal}[{start}..+{count}] on {stage}: {px} px ({px / (400 * 254) * 100:.2f}% of the screen)")
elif args.ramps:
    hits = ramps()
    for span, label, s, L, run in hits:
        mark = " CYCLED" if (label, s) in CYCLED else ""
        print(f"{label:14s} {s:02x}+{L - 1}  lum-span {span:3d}{mark}")
    print(f"{len(hits)} triangle ramps")
else:
    ap.print_help()
