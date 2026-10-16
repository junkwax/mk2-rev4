#!/usr/bin/env python3
r"""Optimised subframes for MK1 KANO's frames (the Wolf build's Shang morph).

MK1 drew every frame as ~8 thin horizontal STRIPS (data/MK1KANO.IMG: 1,310
pieces for 199 frames).  MK2's own fighters are cut into two or three bands
(CAGE1-10.IMG: JCSTANCE1A/B).  This composites each MK1 frame and cuts it
the way midway-imgtool's Auto Split does (platform/ui_autochop.cpp): every
band is trimmed to its opaque box and costed with LOAD2's zero-compression
estimate (EstimateZcomBitsForRect, ported word for word), and the cheapest
cut wins - here over 1, 2 or 3 horizontal bands, with PIECE_BITS added per
piece because every piece is another DMA blit and another header.

    from kano_subframes import frames, best_cut
"""
from __future__ import annotations

import numpy as np

BPP = 6
PIECE_BITS = 800           # a piece's header + blit setup, in the size budget
MIN_BAND = 8               # no band thinner than this


def zcom_bits(px: np.ndarray, bpp: int = BPP) -> int:
    """ui_autochop.cpp's EstimateZcomBitsForRect over a whole (trimmed) piece."""
    rh, rw = px.shape
    if rw <= 0 or rh <= 0:
        return 0
    unc = rw * rh * bpp
    if rw <= 10:
        return unc
    nz = px != 0
    anyr = nz.any(axis=1)
    first = np.where(anyr, nz.argmax(axis=1), rw)
    last = np.where(anyr, rw - 1 - nz[:, ::-1].argmax(axis=1), 0)
    lead = first
    trail = np.where(anyr, rw - 1 - last, 0)
    ll, tl = [], []
    for k in range(4):
        f = 1 << k
        ll.append(int((lead - np.minimum(lead // f, 15) * f).sum()))
        tl.append(int((trail - np.minimum(trail // f, 15) * f).sum()))
    lm = 1 << min(range(4), key=lambda k: (ll[k], k))
    tm = 1 << min(range(4), key=lambda k: (tl[k], k))
    vis = rw - np.minimum(lead // lm, 15) * lm - np.minimum(trail // tm, 15) * tm
    bits = rh * 8 + int(np.maximum(vis, 0).sum()) * bpp
    return min(bits, unc)


def trim(px: np.ndarray, y0: int, y1: int):
    """Rows y0..y1-1 trimmed to their opaque box: (x, y, sub) or None."""
    band = px[y0:y1]
    nz = band != 0
    if not nz.any():
        return None
    ys = np.where(nz.any(axis=1))[0]
    xs = np.where(nz.any(axis=0))[0]
    sub = band[ys[0]:ys[-1] + 1, xs[0]:xs[-1] + 1]
    return int(xs[0]), int(y0 + ys[0]), sub


def best_cut(px: np.ndarray):
    """The cheapest cut of a composited frame into 1-3 horizontal bands:
    [(x, y, pixels)] top to bottom."""
    h = px.shape[0]
    cache = {}

    def band(y0, y1):
        key = (y0, y1)
        if key not in cache:
            t = trim(px, y0, y1)
            cache[key] = (0, None) if t is None else (zcom_bits(t[2]) + PIECE_BITS, t)
        return cache[key]

    best = (band(0, h)[0], [(0, h)])
    for y1 in range(MIN_BAND, h - MIN_BAND + 1):
        c = band(0, y1)[0] + band(y1, h)[0]
        if c < best[0]:
            best = (c, [(0, y1), (y1, h)])
    for y1 in range(MIN_BAND, h - 2 * MIN_BAND + 1):
        a = band(0, y1)[0]
        if a >= best[0]:
            continue
        for y2 in range(y1 + MIN_BAND, h - MIN_BAND + 1):
            c = a + band(y1, y2)[0] + band(y2, h)[0]
            if c < best[0]:
                best = (c, [(0, y1), (y1, y2), (y2, h)])
    return best[0], [band(a, b)[1] for a, b in best[1] if band(a, b)[1] is not None]


def composite(pieces):
    """pieces: [dict(w, h, ax, ay, px bytes)] sharing one anchor -> (canvas, anchor x, anchor y)."""
    x0 = min(-p["ax"] for p in pieces)
    y0 = min(-p["ay"] for p in pieces)
    x1 = max(p["w"] - p["ax"] for p in pieces)
    y1 = max(p["h"] - p["ay"] for p in pieces)
    cv = np.zeros((y1 - y0, x1 - x0), np.uint8)
    for p in pieces:
        a = np.frombuffer(p["px"], np.uint8).reshape(p["h"], p["w"])
        ox, oy = -p["ax"] - x0, -p["ay"] - y0
        reg = cv[oy:oy + p["h"], ox:ox + p["w"]]
        np.copyto(reg, a, where=a != 0)
    return cv, -x0, -y0


# ---------------------------------------------------------------------------
# IMGTOOL's AUTO SPLIT (midway-imgtool platform/ui_autochop.cpp,
# BuildBestAutoSplitPreviewForImage): ONE cut, vertical or horizontal, at the
# position that gives the fewest zcom bits for the two trimmed halves (ties to
# the middle), each half at least MIN_SIDE+1 wide.  A frame with more pieces is
# that split applied again - always to the piece whose split saves the most -
# which is what an artist gets pressing Auto Split on a piece in IMGTOOL.
MIN_SIDE = 5                 # k_auto_split_min_side


def _best_split(px):
    """(bits, [(x, y, sub), (x, y, sub)]) for a piece's cheapest single cut, or None."""
    h, w = px.shape
    best = None
    for vertical, dim in ((True, w), (False, h)):
        for s in range(MIN_SIDE + 1, dim - MIN_SIDE):
            a = trim(px[:, :s], 0, h) if vertical else trim(px, 0, s)
            if vertical:
                b = trim(px[:, s:], 0, h)
                if b is not None:
                    b = (b[0] + s, b[1], b[2])
            else:
                b = trim(px, s, h)
            if a is None or b is None:
                continue
            bits = zcom_bits(a[2]) + zcom_bits(b[2])
            key = (bits, abs(s - dim // 2))
            if best is None or key < best[0]:
                best = (key, [a, b])
    return None if best is None else (best[0][0], best[1])


def auto_split(px: np.ndarray, n: int):
    """A composited frame cut into n pieces by repeated Auto Split:
    [(x, y, sub)], left to right.  Fewer when nothing more can be split."""
    t = trim(px, 0, px.shape[0])
    if t is None:
        return []
    pieces = [t]
    while len(pieces) < n:
        cand = []
        for k, (x, y, sub) in enumerate(pieces):
            r = _best_split(sub)
            if r is not None:
                cand.append((zcom_bits(sub) - r[0], k, [(x + a, y + b, s) for a, b, s in r[1]]))
        if not cand:
            break
        _save, k, two = max(cand, key=lambda c: (c[0], -c[1]))
        pieces[k:k + 1] = two
    return sorted(pieces, key=lambda p: (p[0], p[1]))


def auto_split_free(px: np.ndarray, most: int = 3):
    """Auto Split for a frame with no Liu Kang twin: split while a split saves
    more than a piece costs (PIECE_BITS), at most `most` pieces."""
    t = trim(px, 0, px.shape[0])
    if t is None:
        return []
    pieces = [t]
    while len(pieces) < most:
        cand = []
        for k, (x, y, sub) in enumerate(pieces):
            r = _best_split(sub)
            if r is not None:
                cand.append((zcom_bits(sub) - r[0], k, [(x + a, y + b, s) for a, b, s in r[1]]))
        if not cand:
            break
        save, k, two = max(cand, key=lambda c: (c[0], -c[1]))
        if save <= PIECE_BITS:
            break
        pieces[k:k + 1] = two
    return sorted(pieces, key=lambda p: (p[0], p[1]))
