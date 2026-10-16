#!/usr/bin/env python3
"""Extract Raiden's ambient bolt STROKE PATHS from the actual sprite art.

The first version of the geometry bolts scribbled a random zigzag inside each
measured box.  That is wrong: the real bolt is a DETERMINISTIC shape and the
six styles are smooth animations, not electrical noise.  To reproduce them 1:1
the stroke itself has to come out of the art.

This decodes every RN*BOLT frame out of the built video ROM, finds the lit
pixels, and traces a centreline polyline through them - plus the stroke
thickness, so the drawn line has the same weight as the painted one.
"""
import os, re, sys, glob, importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
spec = importlib.util.spec_from_file_location("_audit", os.path.join(REPO, "tools", "audit_sprite_bpp.py"))
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)

rom, covered = audit.build_video_rom(os.path.join(REPO, "data"))

# every RN*BOLT record: label -> (w,h,anix,aniy,sag,ctrl)
recs = {}
pat = re.compile(r'^([A-Z0-9_]+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)\s*\n'
                 r'\s*\.long\s+0?([0-9a-fA-F]+)[Hh]\s*\n\s*\.word\s+0?([0-9A-Fa-f]+)[Hh]', re.M)
txt = open(os.path.join(REPO, "src", "MKBOLTS.TBL"), errors="ignore").read()
for m in pat.finditer(txt):
    if m.group(1).startswith("RN") and "BOLT" in m.group(1):
        recs[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)),
                            int(m.group(5)), int(m.group(6), 16), int(m.group(7), 16))

def pixels(label):
    """Return a w*h grid of palette indices, 0 = transparent."""
    w, h, ax, ay, sag, ctrl = recs[label]
    bpp = (ctrl >> 12) & 7 or 8
    comp = bool(ctrl & 0x80)
    ldx, trx = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    br = audit.BitReader(rom, sag)
    grid = []
    for _ in range(h):
        row = [0] * w
        if comp:
            hdr = br.read(8)
            if hdr is None: return None
            lead = (hdr & 0x0F) << ldx
            trail = (hdr >> 4) << trx
            n = w - lead - trail
            if n < 0: return None
            for i in range(n):
                v = br.read(bpp)
                if v is None: return None
                if lead + i < w: row[lead + i] = v
        else:
            for i in range(w):
                v = br.read(bpp)
                if v is None: return None
                row[i] = v
        grid.append(row)
    return grid

def strands(grid):
    """Split the lit pixels into connected components.

    A single centreline is only right for a single stroke.  The attack bolts
    (RNFLYBOLT, RNSHORTBOLT) are frequently FORKED, and a median-per-slice
    trace through a fork wanders through empty space between the branches -
    measured coverage drops to 0.20 on the worst frames.  Tracing each strand
    on its own fixes that and also cleans up the handful of ambient frames
    that branch.
    """
    h = len(grid); w = len(grid[0])
    seen = [[False] * w for _ in range(h)]
    out = []
    for sy in range(h):
        for sx in range(w):
            if not grid[sy][sx] or seen[sy][sx]:
                continue
            stack, cells = [(sx, sy)], []
            seen[sy][sx] = True
            while stack:
                x, y = stack.pop()
                cells.append((x, y))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < w and 0 <= ny < h and grid[ny][nx] and not seen[ny][nx]:
                            seen[ny][nx] = True
                            stack.append((nx, ny))
            if len(cells) >= 6:          # ignore specks
                out.append(cells)
    out.sort(key=len, reverse=True)
    return out


def trace_cells(cells):
    """Centreline + mean thickness for one connected strand."""
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
    vertical = (max(ys) - min(ys)) > (max(xs) - min(xs))
    slices = {}
    for x, y in cells:
        key, val = (y, x) if vertical else (x, y)
        slices.setdefault(key, []).append(val)
    pts, thick = [], []
    for key in sorted(slices):
        lit = sorted(slices[key])
        mid = lit[len(lit) // 2]
        thick.append(len(lit))
        pts.append((mid, key) if vertical else (key, mid))
    return pts, (sum(thick) / len(thick))


def trace(grid):
    """Centreline through the lit pixels, plus mean stroke thickness.

    Walks whichever axis the piece is longer on and takes the median lit
    pixel per slice, so a near-vertical bolt traces down rather than across.
    """
    h = len(grid); w = len(grid[0])
    cols, rows = [], []
    for x in range(w):
        lit = [y for y in range(h) if grid[y][x]]
        if lit: cols.append((x, lit))
    for y in range(h):
        lit = [x for x in range(w) if grid[y][x]]
        if lit: rows.append((y, lit))
    if not cols: return [], 0
    vertical = len(rows) > len(cols)
    slices = rows if vertical else cols
    pts, thick = [], []
    for pos, lit in slices:
        mid = lit[len(lit) // 2]
        thick.append(len(lit))
        pts.append((mid, pos) if vertical else (pos, mid))
    return pts, (sum(thick) / len(thick))

def simplify(pts, tol=1.2):
    """Ramer-Douglas-Peucker, so a 40-point trace becomes a handful of joints."""
    if len(pts) < 3: return pts
    a, b = pts[0], pts[-1]
    dx, dy = b[0] - a[0], b[1] - a[1]
    den = (dx * dx + dy * dy) ** 0.5 or 1
    worst, wi = 0, 0
    for i in range(1, len(pts) - 1):
        p = pts[i]
        d = abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / den
        if d > worst: worst, wi = d, i
    if worst <= tol: return [a, b]
    return simplify(pts[:wi + 1], tol)[:-1] + simplify(pts[wi:], tol)

if __name__ == "__main__":
    ok = bad = 0
    for lbl in sorted(recs):
        g = pixels(lbl)
        if g is None:
            bad += 1; continue
        pts, th = trace(g)
        s = simplify(pts)
        ok += 1
        if len(sys.argv) > 1 and lbl.startswith(sys.argv[1]):
            w, h = recs[lbl][0], recs[lbl][1]
            print("%-14s %2dx%-2d  lit_slices=%-3d joints=%-2d thickness=%.1f  %s"
                  % (lbl, w, h, len(pts), len(s), th,
                     " ".join("(%d,%d)" % p for p in s[:8])))
    print("\ndecoded %d frames, %d failed" % (ok, bad))
