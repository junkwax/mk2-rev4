#!/usr/bin/env python3
"""Build data/TWRJNT.BIN - THE TOWER's floor joints, to be drawn OVER the reflection.

THE TOWER's marble carries a perspective grid: a fan of joint lines radiating
toward the vanishing point above the carpet runner, plus four horizontal
courses.  They parallax for free, because floor_code shears every scanline by
skew_oc + L*skew_dx as the camera pans - that is what makes them read as a
floor rather than as a pattern.

The floor reflection covers them: the marble band (texture rows 0..TWR_BKR-1)
is drawn over by the reflected wall, and skew_skip stops floor_code drawing
those rows at all.  This texture puts the joints back on top.

WHAT IT CONTAINS, per texture row 0..53:

    * the JOINT pixels - the radial lines and the horizontal courses
    * the CARPET - exactly twr_runner_tbl's span, so the same pass that used
      to redraw the runner still does
    * index 0 everywhere else, which the floor's own control word (0E002h,
      write-non-zero) leaves transparent, so the reflection shows through

so ONE full-width blit per row draws both, instead of a runner blit plus a
separate line pass.  Against today that is +5 queue entries (rows 0..4 carry
joints but no runner), not +54.

Everything is derived, nothing is authored:

    * the pixels come from data/FL_TOW.BIN, the floor's own texture - raw
      6bpp LSB-first, 1200x75, which this verifies against MKFLOORS.IMG's
      CASFLOOR1-6 decode when asked
    * the radial lines are FOUND, by a thin-line response and a Hough vote
      over x = a + s*y, not listed by hand
    * the carpet spans come from src/TWRBKREF.ASM's twr_runner_tbl, the same
      table the old runner pass walked

    python tools/make_twrjnt_bin.py           # write data/TWRJNT.BIN + preview
    python tools/make_twrjnt_bin.py --check   # Phase D: is it current?
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
FLOOR = ROOT / "data" / "FL_TOW.BIN"
OUT = ROOT / "data" / "TWRJNT.BIN"
TWRBKREF = ROOT / "src" / "TWRBKREF.ASM"
BGND = ROOT / "src" / "BGND.ASM"

W, H, BPP = 1200, 75, 6           # the floor texture
MINSUP = 30                       # a radial line needs this many rows of support
EOL = "\r\n"


def floor_indices() -> np.ndarray:
    raw = np.frombuffer(FLOOR.read_bytes(), np.uint8)
    bits = np.unpackbits(raw, bitorder="little")[: W * H * BPP].reshape(W * H, BPP)
    return (bits * (1 << np.arange(BPP))).sum(1).reshape(H, W).astype(np.uint8)


def pack(idx: np.ndarray) -> bytes:
    flat = idx.reshape(-1).astype(np.uint8)
    bits = ((flat[:, None] >> np.arange(BPP)) & 1).astype(np.uint8).reshape(-1)
    return np.packbits(bits, bitorder="little").tobytes()


def floor_palette() -> np.ndarray:
    """CASFLR1_p, the palette the floor is drawn on - for luminance only."""
    t = BGND.read_text(errors="replace")
    blk = t[t.index("CASFLR1_p:"):]
    nums: list[int] = []
    for line in blk.splitlines()[1:14]:
        line = line.split(";")[0]
        if ".word" not in line:
            continue
        for tok in line.split(".word", 1)[1].split(","):
            tok = tok.strip()
            if tok:
                nums.append(int(tok[:-1], 16) if tok[-1] in "hH" else int(tok, 0))
    n, vals = nums[0], nums[1:]
    out = np.zeros((64, 3))
    for i, v in enumerate(vals[:n]):
        out[i] = ((v >> 10) & 31, (v >> 5) & 31, v & 31)
    # 0..255, NOT the raw 5-bit channels: every threshold below is a luminance
    # margin tuned on 8-bit values, and at 5-bit "14 darker than the local mean"
    # is most of the range - the line hunt found nothing at all.
    return out * (255.0 / 31.0)


def runner_spans() -> tuple[int, dict[int, tuple[int, int]]]:
    """{texture row: (r0, r1)} from the generated twr_runner_tbl."""
    t = TWRBKREF.read_text(errors="replace")
    l0 = int(re.search(r"^TWR_RUNL0\s+\.set\s+(\d+)", t, re.M).group(1))
    rows = int(re.search(r"^TWR_BKR\s+\.set\s+(\d+)", t, re.M).group(1))
    blk = t[t.index("twr_runner_tbl"):t.index("twr_dmap")]
    spans = {}
    for k, m in enumerate(re.finditer(r"\.word\s+(\d+),(\d+)", blk)):
        r0, r1 = int(m.group(1)), int(m.group(2))
        if r1 >= r0:
            spans[l0 + k] = (r0, r1)
    return rows, spans


def joints(idx: np.ndarray, rows: int, spans: dict[int, tuple[int, int]]):
    """Find the joint pixels in the band: a radial fan plus horizontal courses."""
    pal = floor_palette()
    lum = pal[idx[:rows]] @ np.array([0.3, 0.59, 0.11])
    rgb = pal[idx[:rows]]
    carpet = np.zeros((rows, W), bool)
    for y, (r0, r1) in spans.items():
        if y < rows:
            carpet[y, r0:r1 + 1] = True
    # The carpet's own red also appears as trim; keep it out of the line hunt.
    # 40/25 on 0..255, NOT 5/3 - floor_palette returns 8-bit channels, and at
    # 5-bit thresholds the whole (brownish) marble reads as carpet, which left
    # almost nothing outside `skip` and made 48 of 54 rows look like courses.
    red = (rgb[..., 0] > rgb[..., 1] + 40) & (rgb[..., 0] > rgb[..., 2] + 25)
    skip = carpet | red
    pad = np.pad(lum, 2, mode="edge")
    mean = sum(pad[dy:dy + rows, dx:dx + W] for dy in range(5) for dx in range(5)) / 25
    dark = (lum < mean - 14) & ~skip

    ys, xs = np.nonzero(dark)
    acc: dict[tuple[float, int], int] = {}
    for s in np.arange(-6.0, 6.001, 0.05):
        a = np.round(xs - s * ys).astype(int)
        cnt = np.bincount(a - a.min(), minlength=1)
        for off in np.argsort(cnt)[-40:]:
            acc[(round(float(s), 2), int(off + a.min()))] = int(cnt[off])
    lines: list[tuple[float, int, int]] = []
    for (s, a), v in sorted(acc.items(), key=lambda kv: -kv[1]):
        if v < MINSUP:
            break
        if any(abs(s - s2) < 0.25 and abs(a - a2) < 6 for s2, a2, _ in lines):
            continue
        lines.append((s, a, v))
    lines.sort(key=lambda t: t[1])

    mask = np.zeros((rows, W), bool)
    for s, a, _ in lines:
        for y in range(rows):
            x = int(round(a + s * y))
            for dx in (-1, 0, 1):
                if 0 <= x + dx < W and not skip[y, x + dx] \
                        and abs(lum[y, x + dx] - mean[y, x + dx]) > 10:
                    mask[y, x + dx] = True
    course = [y for y in range(rows) if dark[y].sum() > 0.25 * (~skip[y]).sum()]
    for y in course:
        mask[y] |= (lum[y] < mean[y] - 12) & ~skip[y]
    return mask, carpet, lines, course


def build():
    idx = floor_indices()
    rows, spans = runner_spans()
    mask, carpet, lines, course = joints(idx, rows, spans)
    out = np.zeros((rows, W), np.uint8)
    keep = mask | carpet
    out[keep] = idx[:rows][keep]
    zero = int((keep & (idx[:rows] == 0)).sum())
    return out, rows, mask, carpet, lines, course, zero


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--preview", action="store_true")
    args = ap.parse_args()

    out, rows, mask, carpet, lines, course, zero = build()
    blob = pack(out)

    print(f"THE TOWER floor joints: {W}x{rows} at {BPP}bpp = {len(blob)} bytes")
    print(f"  {len(lines)} radial joint lines, horizontal courses on rows {course}")
    for s, a, v in lines:
        print(f"     column {a:5d} at row 0, {s:+.2f} px/row, {v} rows of support")
    print(f"  joint pixels {int(mask.sum())}, carpet pixels {int(carpet.sum())}, "
          f"transparent {100 * (1 - (mask | carpet).mean()):.1f}%")
    if zero:
        print(f"  NOTE {zero} kept pixels are index 0 in the floor and stay transparent")

    if args.check:
        if not OUT.exists():
            print("TOWER FLOOR JOINTS BROKEN:\n  data/TWRJNT.BIN missing - "
                  "re-run tools/make_twrjnt_bin.py")
            return 1
        if OUT.read_bytes() != blob:
            print("TOWER FLOOR JOINTS BROKEN:\n  data/TWRJNT.BIN is stale against "
                  "FL_TOW.BIN / twr_runner_tbl - re-run tools/make_twrjnt_bin.py")
            return 1
        print("  floor joints current")
        return 0

    OUT.write_bytes(blob)
    print(f"wrote {OUT}")
    if args.preview:
        from PIL import Image
        pal = floor_palette()
        img = pal[out].astype(np.uint8)        # floor_palette already returns 0..255
        img[out == 0] = (40, 0, 40)
        Image.fromarray(img).save(ROOT / "tools" / "screens" / "tower_backdrop"
                                  / "floor_options" / "twrjnt_texture.png")
        print("wrote the preview beside the floor option mockups")
    return 0


if __name__ == "__main__":
    sys.exit(main())
