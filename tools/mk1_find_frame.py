#!/usr/bin/env python3
r"""Find a ripped MK1 sprite back in the ROM: "which frame is this?"

Give it a PNG (a forum rip, a screenshot crop, anything with the figure on a
flat or transparent background) and it ranks every candidate in `mkla1.zip`
(MK1 rev 1.0) and `mk.zip` (rev 5.0) by SHAPE, so it does not care about
scale, palette or how the background was cut.

    python tools/mk1_find_frame.py target.png
    python tools/mk1_find_frame.py target.png --top 24
    python tools/mk1_find_frame.py target.png --pieces    # also single records
    python tools/mk1_find_frame.py target.png --char 0    # restrict to a fighter

Two candidate sets:
  * composed FRAMES - every frame reachable from any fighter's animation
    table, plus every frame nothing points at (MK1 draws a fighter as several
    pieces on one anchor, so a rip is nearly always a composed frame).
  * individual image RECORDS, with --pieces, in case the rip is one piece.

Scoring: both silhouettes are cropped to their bounding box, scaled to a
64x64 grid and compared by intersection-over-union, with the mirrored target
tried as well (rips are often flipped).  Writes a ranked contact sheet so the
answer can be eyeballed, and prints addresses.
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
_spec = importlib.util.spec_from_file_location("mk1y", HERE / "mk1_yunit_extract.py")
mk1 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mk1)

GRID = 64


def norm(mask: np.ndarray) -> np.ndarray | None:
    """crop a boolean silhouette to its bbox and scale to GRID x GRID"""
    ys, xs = np.nonzero(mask)
    if not len(xs):
        return None
    m = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    im = Image.fromarray((m * 255).astype(np.uint8), "L").resize((GRID, GRID), Image.BILINEAR)
    return np.asarray(im) > 127


def iou(a: np.ndarray, b: np.ndarray) -> float:
    u = (a | b).sum()
    return float((a & b).sum()) / u if u else 0.0


def target_mask(path: Path) -> np.ndarray:
    """figure vs background, however the rip was cut"""
    im = Image.open(path).convert("RGBA")
    a = np.asarray(im)
    alpha = a[..., 3]
    if (alpha < 255).mean() > 0.02:          # it has real transparency
        return alpha > 40
    rgb = a[..., :3].astype(int)
    # otherwise treat the most common border colour as the background
    border = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    bg = np.median(border, axis=0)
    return (np.abs(rgb - bg).sum(-1) > 60)


def candidates(rom, tag, want_char, with_pieces):
    """(label, mask) for every composed frame, and optionally every record"""
    recs = rom.records()
    out = []
    seen = set()
    for c in range(9):
        if want_char is not None and c != want_char:
            continue
        for k in range(0x60):
            a = rom.ani(c, k)
            if not rom.inside(a):
                continue
            for f, _, _ in rom.lane(a, parts=3, limit=32):
                if f in seen:
                    continue
                seen.add(f)
                im, _ = mk1.draw_frame(rom, f, None)
                if im is None:
                    continue
                out.append(("%s frame %08x  %s %02Xh" % (tag, f, mk1.CHARS[c], k),
                            np.asarray(im)[..., 3] > 0))
    if want_char is None:
        ptr = rom.pointer_census()
        for f, n in rom.frames(recs):
            if f in seen or ptr[f]:
                continue
            seen.add(f)
            im, _ = mk1.draw_frame(rom, f, None)
            if im is not None:
                out.append(("%s frame %08x  (unreferenced)" % (tag, f),
                            np.asarray(im)[..., 3] > 0))
    if with_pieces:
        for sag, (p, w, h, ax, ay) in rom.coherent(recs).items():
            a = rom.pixels(w, h, sag)
            if a is not None and w > 8 and h > 8:
                out.append(("%s record %08x  %dx%d" % (tag, mk1.BASE + p * 8, w, h), a != 0))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--roms", default=r"C:\MAME\roms")
    ap.add_argument("--out", default=str(ROOT / "tmp" / "mk1_yunit" / "find"))
    ap.add_argument("--top", type=int, default=16)
    ap.add_argument("--pieces", action="store_true", help="also match single records")
    ap.add_argument("--char", type=int, help="restrict to one fighter (0-8)")
    ap.add_argument("--rev5-only", action="store_true")
    a = ap.parse_args()

    tgt = norm(target_mask(Path(a.image)))
    if tgt is None:
        sys.exit("no figure found in %s" % a.image)
    flip = tgt[:, ::-1]

    roms = Path(a.roms)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    todo = []
    y = mk1.YRom(roms / "mkla1.zip")
    t = mk1.TRom(roms / "mk.zip")
    y.anitab_list = mk1.find_anitab_list(y)
    t.anitab_list = mk1.find_anitab_list(t)
    pals = mk1.find_palettes(y, t)
    if not a.rev5_only:
        todo.append((y, "rev1.0"))
    todo.append((t, "rev5.0"))

    scored = []
    for rom, tag in todo:
        cands = candidates(rom, tag, a.char, a.pieces)
        print("%s: %d candidates" % (tag, len(cands)))
        for label, mask in cands:
            n = norm(mask)
            if n is None:
                continue
            s = max(iou(tgt, n), iou(flip, n))
            scored.append((s, label, rom, mask))
    scored.sort(key=lambda r: -r[0])

    print("\ntop %d by silhouette overlap:" % a.top)
    cells = []
    for s, label, rom, mask in scored[:a.top]:
        print("  %.3f  %s" % (s, label))
        cells.append((s, label, mask))

    cell = 200
    cols = 8
    rows = (len(cells) + cols - 1) // cols
    cv = Image.new("RGB", (cols * cell, max(1, rows) * cell), (16, 16, 24))
    dr = ImageDraw.Draw(cv)
    for i, (s, label, mask) in enumerate(cells):
        im = Image.fromarray((mask * 255).astype(np.uint8), "L").convert("RGB")
        im.thumbnail((cell - 8, cell - 30))
        X, Y = (i % cols) * cell + 4, (i // cols) * cell + 26
        cv.paste(im, (X, Y))
        dr.text((X, (i // cols) * cell + 3), "%.3f\n%s" % (s, label.replace("  ", "\n")),
                fill=(200, 220, 255))
    cv.save(out / "matches.png")
    tim = Image.fromarray((tgt * 255).astype(np.uint8), "L")
    tim.save(out / "target_mask.png")
    print("\n-> %s" % (out / "matches.png"))


if __name__ == "__main__":
    main()
