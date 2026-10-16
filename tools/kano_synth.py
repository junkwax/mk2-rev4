#!/usr/bin/env python3
r"""MK1 KANO's fatality-victim frames, BUILT OUT OF HIS OWN MK1 ART.

MK1 drew no torso, legs or held pose of Kano for MK2's finishers, so
tools/make_mk1kano_port.py used to fill those TABLE1 rows (TEMPLATE_ROWS: nut
crunch, drained, torso rip, impaled, decap fall, head, back break, head hole,
swipe torso) with LIU KANG's art recoloured into KANO1_P.  This builds each of
those frames from Kano's MK1 frames instead (the user's call, 2026-10-11):

  * a DIFFERENT POSE of his that reads as the same beat (doubled over for the
    nut crunch, slumped for the impale, head thrown back for the drain);
  * MK1's OWN headless body: lane 4Fh's frames 1-7 (a bloody neck stump,
    knees, face down) are Kano's decap fall, and MK1 also has his SEVERED HEAD
    rolling in four drawings (records FFF04C40-FFF04D60, a one-image lane
    MK2 never played) - the decap, the head hole and the rolling head use them;
  * POSES TILTED AND CUT: the back break is him lying flat, then BENT at the
    waist over the knee (each half rotated about the waist); the torso rip is
    his upper half cut at the belt, tumbling and then lying;
  * GUTS where a body is cut or run through - a ragged blood band on the cut
    and entrails hanging off it, belly wounds on the impale, a hole through
    the head for Cage's brain punch - painted in KANO1_P's own blood ramp
    (58/59/62) with its flesh browns (30/33) and pinks (47/48).

WHERE A FRAME GOES: each is placed where Liu Kang's frame of the same name sits
RELATIVE TO LIU KANG'S STANCE, translated to Kano's stance (stance bbox centre
x and feet).  Every finisher's offsets (Jax's knee, Baraka's blades, the
attackers' lineups) were tuned on Liu Kang's art, so the new frame lands in
the same place the placeholder did.  `ALIGN` picks which edges are matched.

THE DECAP FAMILY SHARES ITS PIXELS, the way Liu Kang's does: DECAPn is
DEADLEGn (legs) + ERT_TORSOn (headless torso), cut from one 4Fh frame along a
hand-authored waist line, and HOLEn is DECAPn + HOLEHEADn.  The torso rip's
legs (DEADLEG) and Ermac's head rip (ERT_TORSO + DEADLEG as two objects) both
depend on the two halves lining up into one body.

    python tools/kano_synth.py --preview DIR     # Liu Kang's frame | Kano's, every frame
"""
from __future__ import annotations

import argparse
import math
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

# KANO1_P: the blood ramp and the flesh it shades into
DARK, BLOOD, BRIGHT = 58, 59, 62
FLESH = (30, 33)
PINK = (47, 48)
# MK1's severed head, four drawings of it rolling (an orphan one-image lane)
HEADS = (0xFFF04C40, 0xFFF04CA0, 0xFFF04D00, 0xFFF04D60)


# --------------------------------------------------------------------------
# a LAYER is (array, x, y): the array's top-left at world (x, y)
def bbox(a):
    nz = np.argwhere(a)
    (y0, x0), (y1, x1) = nz.min(0), nz.max(0)
    return int(x0), int(y0), int(x1), int(y1)


def trimmed(layer):
    a, x, y = layer
    x0, y0, x1, y1 = bbox(a)
    return a[y0:y1 + 1, x0:x1 + 1].copy(), x + x0, y + y0


def rotate(layer, deg, piv):
    """Nearest-neighbour rotation about world point piv; +deg is clockwise on
    screen.  Inverse-mapped, so it leaves no holes."""
    a, ox, oy = layer
    h, w = a.shape
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    px, py = piv
    cs = [(ox + dx, oy + dy) for dx in (0, w) for dy in (0, h)]
    rx = [px + (X - px) * c - (Y - py) * s for X, Y in cs]
    ry = [py + (X - px) * s + (Y - py) * c for X, Y in cs]
    X0, Y0 = math.floor(min(rx)), math.floor(min(ry))
    W, H = math.ceil(max(rx)) - X0 + 1, math.ceil(max(ry)) - Y0 + 1
    yy, xx = np.mgrid[0:H, 0:W]
    dx, dy = xx + X0 + 0.5 - px, yy + Y0 + 0.5 - py
    sx = np.floor(px + dx * c + dy * s - ox).astype(int)
    sy = np.floor(py - dx * s + dy * c - oy).astype(int)
    ok = (sx >= 0) & (sx < w) & (sy >= 0) & (sy < h)
    out = np.zeros((H, W), np.uint8)
    out[ok] = a[sy[ok], sx[ok]]
    return trimmed((out, X0, Y0))


def flip(layer):
    a, x, y = layer
    return a[:, ::-1].copy(), x, y


def side(layer, p0, p1):
    """Boolean mask: pixels LEFT of the directed line p0->p1 (in the layer's
    own coordinates; on screen, with y down, 'left' of a downward line is +x)."""
    a, _x, _y = layer
    h, w = a.shape
    yy, xx = np.mgrid[0:h, 0:w]
    (x0, y0), (x1, y1) = p0, p1
    return ((x1 - x0) * (yy + 0.5 - y0) - (y1 - y0) * (xx + 0.5 - x0)) > 0


def keep(layer, mask):
    a, x, y = layer
    return trimmed((np.where(mask, a, 0).astype(np.uint8), x, y))


def paste(layers):
    X0 = min(x for _a, x, _y in layers)
    Y0 = min(y for _a, _x, y in layers)
    X1 = max(x + a.shape[1] for a, x, _y in layers)
    Y1 = max(y + a.shape[0] for a, _x, y in layers)
    out = np.zeros((Y1 - Y0, X1 - X0), np.uint8)
    for a, x, y in layers:
        reg = out[y - Y0:y - Y0 + a.shape[0], x - X0:x - X0 + a.shape[1]]
        np.copyto(reg, a, where=a != 0)
    return out, X0, Y0


# --------------------------------------------------------------------------
# GORE.  Everything takes a seed off the frame's name, so a frame rebuilds to
# the same pixels every run (--check compares bytes).
def _rng(tag):
    return random.Random(sum((i + 1) * ord(c) for i, c in enumerate(tag)))


def _put(a, x, y, v):
    if 0 <= y < a.shape[0] and 0 <= x < a.shape[1]:
        a[y, x] = v


def guts(layer, p0, p1, tag, hang=(0.0, 1.0), length=(4, 13), strands=None, inward=True):
    """A cut along the body's edge from p0 to p1 (layer coordinates): the body
    pixels within 2-3 px of the cut go to the blood ramp in a ragged band, and
    entrails hang off it in the direction `hang` (a unit-ish vector pointing
    OUT of the body).  Grows the layer to fit."""
    a, x, y = layer
    pad = max(length) + 4
    big = np.zeros((a.shape[0] + 2 * pad, a.shape[1] + 2 * pad), np.uint8)
    big[pad:pad + a.shape[0], pad:pad + a.shape[1]] = a
    a = big
    r = _rng(tag)
    (x0, y0), (x1, y1) = (p0[0] + pad, p0[1] + pad), (p1[0] + pad, p1[1] + pad)
    n = max(2, int(math.hypot(x1 - x0, y1 - y0)))
    hx, hy = hang
    hl = math.hypot(hx, hy) or 1.0
    hx, hy = hx / hl, hy / hl
    # only where the cut actually crosses the body - the line is authored
    # across the whole frame
    body = a != 0

    def on_body(px, py):
        qx, qy = int(round(px)), int(round(py))
        y0_, x0_ = max(qy - 2, 0), max(qx - 2, 0)
        return bool(body[y0_:qy + 3, x0_:qx + 3].any())
    on = [k for k in range(n + 1) if on_body(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n)]
    if not on:
        return trimmed((a, x - pad, y - pad))
    k0, k1 = min(on), max(on)
    x0, y0, x1, y1 = (x0 + (x1 - x0) * k0 / n, y0 + (y1 - y0) * k0 / n,
                      x0 + (x1 - x0) * k1 / n, y0 + (y1 - y0) * k1 / n)
    n = max(2, k1 - k0)
    # the raw band: walk the cut, and step INTO the body (against `hang`)
    for k in range(n + 1):
        px, py = x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n
        if not on_body(px, py):
            continue
        depth = r.choice((2, 2, 3, 3, 4))
        # inward: the band eats into the body; outward: it caps the cut on the
        # far side, where the OTHER half of the body covers it when joined
        for d in (range(-1, depth) if inward else range(-depth, 0)):
            qx, qy = int(round(px - hx * d)), int(round(py - hy * d))
            if 0 <= qy < a.shape[0] and 0 <= qx < a.shape[1] and (a[qy, qx] or d <= 0):
                a[qy, qx] = BRIGHT if d <= 0 and r.random() < 0.55 else (BLOOD if d < 2 else DARK)
    # entrails: tubes hanging out of the cut
    m = strands if strands is not None else max(2, n // 6)
    for _s in range(m):
        t = r.uniform(0.1, 0.9)
        sx, sy = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
        ln = r.randint(*length)
        wob = r.uniform(-0.6, 0.6)
        thick = r.choice((1, 2, 2, 3))
        for j in range(ln):
            bend = math.sin(j / 3.0 + wob * 5) * wob * 2
            cx = sx + hx * j - hy * bend
            cy = sy + hy * j + hx * bend
            for o in range(-(thick // 2), thick - thick // 2):
                qx, qy = int(round(cx - hy * o)), int(round(cy + hx * o))
                edge = o in (-(thick // 2), thick - thick // 2 - 1) and thick > 1
                v = (DARK if edge else (r.choice(PINK) if j % 4 == 1 else BRIGHT)) if j < ln - 1 else BLOOD
                _put(a, qx, qy, v)
    # drips: single blood pixels below the cut
    for _d in range(n // 4 if inward else 0):
        t = r.uniform(0, 1)
        qx = int(round(x0 + (x1 - x0) * t + hx * r.randint(2, 6)))
        qy = int(round(y0 + (y1 - y0) * t + hy * r.randint(2, 6) + r.randint(0, 3)))
        _put(a, qx, qy, r.choice((BLOOD, DARK, BRIGHT)))
    return trimmed((a, x - pad, y - pad))


def wound(layer, c, rad, tag, drip=10):
    """A stab wound centred on c (layer coordinates): a ragged dark hole with a
    bright rim, and blood running DOWN from it."""
    a, x, y = layer
    a = a.copy()
    r = _rng(tag)
    cx, cy = c
    for dy in range(-rad - 1, rad + 2):
        for dx in range(-rad - 1, rad + 2):
            d = math.hypot(dx, dy * 1.3) + r.uniform(-0.6, 0.6)
            qx, qy = cx + dx, cy + dy
            if not (0 <= qy < a.shape[0] and 0 <= qx < a.shape[1]) or not a[qy, qx]:
                continue
            if d < rad * 0.55:
                a[qy, qx] = DARK
            elif d < rad:
                a[qy, qx] = BLOOD
            elif d < rad + 1:
                a[qy, qx] = BRIGHT
    for _k in range(3):                              # runs down the body
        qx = cx + r.randint(-rad, rad)
        for j in range(r.randint(drip // 2, drip)):
            qy = cy + rad + j
            if 0 <= qy < a.shape[0] and 0 <= qx < a.shape[1] and a[qy, qx]:
                a[qy, qx] = BRIGHT if j % 3 else BLOOD
            if r.random() < 0.15:
                qx += r.choice((-1, 1))
    return a, x, y


def hole(layer, c, rad, tag):
    """Cage's fist through the head: a black hole, its edge torn and bloody."""
    a, x, y = layer
    a = a.copy()
    r = _rng(tag)
    for dy in range(-rad - 2, rad + 3):
        for dx in range(-rad - 2, rad + 3):
            d = math.hypot(dx, dy) + r.uniform(-0.5, 0.5)
            qx, qy = c[0] + dx, c[1] + dy
            if not (0 <= qy < a.shape[0] and 0 <= qx < a.shape[1]) or not a[qy, qx]:
                continue
            if d < rad - 1:
                a[qy, qx] = 1
            elif d < rad:
                a[qy, qx] = DARK
            elif d < rad + 1.5:
                a[qy, qx] = r.choice((BRIGHT, BLOOD, BRIGHT))
    return a, x, y


def centroid(mask):
    nz = np.argwhere(mask)
    return float(nz[:, 1].mean()), float(nz[:, 0].mean())


# --------------------------------------------------------------------------
# THE RECIPES.  Source poses are MK1 (lane, step).  Coordinates are the source
# frame's own pixels (its composited canvas, top-left 0,0).
#
# THE DECAP BODY: lane 4Fh steps 1-7.  CUT is the waist, a directed line whose
# LEFT side (+x for a downward line) is the LEGS... rather than remember that,
# each entry names the side the torso is on by a point inside the torso.
DECAP = {   # n: (4Fh step, waist p0, waist p1, a point in the torso)
    1: (1, (0, 46), (27, 44), (13, 20)),
    2: (2, (0, 44), (49, 42), (20, 20)),
    3: (3, (0, 46), (53, 44), (30, 20)),
    4: (4, (10, 44), (68, 58), (40, 25)),
    5: (5, (36, 10), (66, 79), (70, 30)),
    6: (6, (58, 0), (70, 53), (100, 25)),
    7: (7, (60, 0), (64, 32), (95, 15)),
}
# the TORSO RIP: Kano's upper half, cut at the belt (source, p0, p1, torso
# point), then tilted as it tumbles - Liu Kang's 1 is the torn torso upright,
# 2-3 in the air, 4-6 on the floor
TORSO_UP = ("41", 3, (0, 45), (60, 41), (30, 15))
TORSO_DOWN = ("44", 0, (50, 0), (52, 40), (20, 20))
RIP = {     # n: (base, extra clockwise degrees, flip)
    1: ("up", 0, False),
    2: ("up", -70, False),
    3: ("up", -150, False),
    4: ("down", 18, False),
    5: ("down", 0, False),
    6: ("down", -8, False),
}
# THE BACK BREAK: lying on his back over Jax's knee.  1 is MK1's sweep-fall
# sit-up (30h 4); 2 him flat (44h 0) bent a little; 3 SNAPPED - each half
# rotated about the waist so he folds over the knee.
BACK = {    # n: (lane, step, waist point, head-side bend, feet-side bend)
    1: ("30", 4, None, 0, 0),
    2: ("44", 0, (52, 20), 10, -10),
    3: ("44", 0, (52, 20), 34, -30),
}
# whole poses that stand in for a beat, with gore painted on
POSE = {    # name: (lane, step, [wound (x, y, r)...])
    "NUTCRUNCH1": ("2E", 0, []),
    "NUTCRUNCH2": ("2E", 1, []),
    "DRAIN0": ("4D", 1, []),
}
# THE IMPALE: hung on Baraka's blades, slumped (41h, his stunned sway).  Baraka
# parks the victim's ANCHOR on his own and the lane lifts it, so these are lined
# up anchor to anchor on the WAIST - Kano's belt (the darkest band at waist
# height) where Liu Kang's waistband is (the top row of his red trousers below
# the headband) - and the blades' two wounds go in his stomach just above the
# belt, at the front.  Matching the TOPS, as the first cut did, put his waist
# ~20 px below the blades and the wounds in his thighs.
IMPALE = {  # name: (lane, step, Kano's belt row, Liu Kang's waistband below his anchor)
    "IMPALED1": ("41", 3, 46, 47),
    "IMPALED2": ("41", 2, 41, 45),
    "IMPALED3": ("41", 1, 47, 47),
}
# HOW EACH IS LINED UP WITH LIU KANG'S FRAME OF THE SAME NAME: "foot" = bbox
# bottom + centre x (standing, kneeling, lying), "centre" = bbox centre
# (airborne), "top" = top + centre x (held up).
ALIGN = {"HEAD": "centre", "RIPTORSO2": "centre", "RIPTORSO3": "centre",
         "DRAIN0": "foot"}


def align_of(name):
    for k, v in ALIGN.items():
        if name == k or (name.startswith(k) and name[len(k):].isdigit()):
            return v
    return "foot"


def scale_layer(layer, sx, sy):
    """Nearest-neighbour scale of a layer by (sx, sy), about its top-left."""
    a, x, y = layer
    h, w = a.shape
    W, H = max(1, round(w * sx)), max(1, round(h * sy))
    ys = np.minimum((np.arange(H) / sy).astype(int), h - 1)
    xs = np.minimum((np.arange(W) / sx).astype(int), w - 1)
    return trimmed((a[ys][:, xs].copy(), x, y))


# THE SECOND BATCH's sources (Synth.extras).  Coordinates are the source
# frame's own pixels; 40h is his VICTORY lane, whose 2-4 face the screen.
ARM_SRC = ("40", 3, (70, 20, 115, 55))        # his right arm, arms flung out: x0, y0, x1, y1
FREEZE_SRC = ("40", 4, 72, 39)                # frontal stance; waist row; crotch column
DRAIN_SRC = ("4D", 1)                         # limp, head back (the drain pose)
SPLIT_SRC = ("40", 4, 24)                     # frontal stance; rows that are his head
SPLIT_TOPPLE = (0, 12, 28, 46, 64, 80, 90)    # SPLIT4-10: degrees the half has toppled
PITFALL = {   # n: (lane, step, flipped, degrees) - flailing, falling at the screen
    1: ("40", 2, False, 0), 2: ("40", 3, False, -8), 3: ("30", 0, False, 6),
    4: ("40", 2, True, 8), 5: ("40", 3, True, 0), 6: ("40", 3, False, 0),
}
SUCK_SRC = ("4D", 1)
BABY_SRC = ("40", 4, 26)                      # the head: rows above 26
BABY_BODY = ("37", 0)                         # the body: his crouch
BABY_HEAD = 0.62


class Synth:
    """Every synthesized frame: name (Liu Kang's, without LK) ->
    (canvas, anchor x, anchor y, pieces | None).  pieces, where given, are the
    frame's OWN record names in the order they make it (a composed frame); None
    means the caller cuts it (Auto Split, Liu Kang's piece count)."""

    def __init__(self, mk1frame, mk1record, lkref, lkpal=None, asmpal=None, kanopal=None):
        """mk1frame(lane, step) -> (canvas, ax, ay); mk1record(addr) -> (px, ax, ay);
        lkref(name) -> (canvas, ax, ay) of Liu Kang's frame, and lkref('STANCE1');
        lkpal(name) -> the palette words Liu Kang's frame is drawn in;
        asmpal(label) -> a palette's words out of src/; kanopal = KANO1_P's words."""
        self.frame, self.record, self.lk = mk1frame, mk1record, lkref
        self.lkpal, self.asmpal, self.kanopal = lkpal, asmpal, kanopal
        self.out = {}
        self.parts = {}          # composed piece name -> (array, world x, world y)
        self.records = set()     # keys that are ONE record (a piece or a lane entry), not a frame
        self.pal = {}            # key -> the palette its pixels index, if not KANO1_P
        self.ownpal = set()      # keys packed WITH their palette (PON>): objects of their own
        self.palwords = {}       # palettes this makes: name -> words

    # placement: a layer (world coords, any origin) -> anchor in canvas coords
    def place(self, name, layer, how=None):
        a, x, y = trimmed(layer)
        how = how or align_of(name)
        lc, lax, lay = self.lk(name)
        lx0, ly0, lx1, ly1 = bbox(lc)
        sc, sax, say = self.lk("STANCE1")
        sx0, _sy0, sx1, sy1 = bbox(sc)
        kc, kax, kay = self.frame("00", 0)
        kx0, _ky0, kx1, ky1 = bbox(kc)
        # Liu Kang's frame bbox relative to his stance's (centre x, feet) ...
        rel = lambda v, ref: v - ref
        lcx = rel((lx0 + lx1) / 2 - lax, (sx0 + sx1) / 2 - sax)
        ltop, lbot, lmid = rel(ly0 - lay, sy1 - say), rel(ly1 - lay, sy1 - say), rel((ly0 + ly1) / 2 - lay, sy1 - say)
        # ... put on Kano's stance: target, relative to KANO's anchor
        tcx = lcx + (kx0 + kx1) / 2 - kax
        kfoot = ky1 - kay
        h, w = a.shape
        ax = round(w / 2 - tcx)
        if isinstance(how, tuple):       # ("row", source row, Liu Kang's row below his anchor)
            ay = round(how[1] - y - how[2])
        elif how == "foot":
            ay = round(h - 1 - (lbot + kfoot))
        elif how == "top":
            ay = round(-(ltop + kfoot))
        else:
            ay = round((h - 1) / 2 - (lmid + kfoot))
        return a, int(ax), int(ay), x, y

    def put(self, name, layer, how=None, pieces=None):
        a, ax, ay, _x, _y = self.place(name, layer, how)
        self.out[name] = (a, ax, ay, pieces)
        return ax, ay

    def src(self, lane, step):
        cv, _ax, _ay = self.frame(lane, step)
        return cv, 0, 0

    # ----------------------------------------------------------------------
    def build(self):
        self.decap()
        self.heads()
        self.rip()
        self.back()
        for n, (lane, step, ws) in POSE.items():
            layer = self.src(lane, step)
            for k, (cx, cy, r) in enumerate(ws):
                layer = wound(layer, (cx, cy), r, f"{n}{k}")
            self.put(n, layer)
        for n, (lane, step, belt, lk_belt) in IMPALE.items():
            layer = self.src(lane, step)
            xs = np.nonzero(layer[0][belt - 6])[0]
            front = int(xs.max())                      # he faces right
            layer = wound(layer, (front - 7, belt - 6), 4, f"{n}a")
            layer = wound(layer, (front - 16, belt - 3), 3, f"{n}b")
            self.put(n, layer, how=("row", belt, lk_belt))
        if self.kanopal:
            self.extras()
        return self.out

    # ======================================================================
    # THE SECOND BATCH: the per-fighter tables that pointed Kano at whole Liu
    # Kang animations outside TABLE1 (make_mk1kano_port EXTRA).  Same rules -
    # his MK1 art, cut / tilted / recoloured, placed where Liu Kang's sat - but
    # ANCHOR to ANCHOR ("a*" alignments): every one of these is an object or a
    # lane the code lines up on an anchor, not on the floor.
    def aplace(self, name, layer, how, lkname=None):
        """The layer's bbox (centre / foot / top) where Liu Kang's frame
        `lkname` has its, off his anchor."""
        a, x, y = trimmed(layer)
        lc, lax, lay = self.lk(lkname or name)
        lx0, ly0, lx1, ly1 = bbox(lc)
        h, w = a.shape
        cx = (lx0 + lx1) / 2 - lax
        ax = round((w - 1) / 2 - cx)
        if how == "afoot":
            ay = round(h - 1 - (ly1 - lay))
        elif how == "atop":
            ay = round(-(ly0 - lay))
        else:
            ay = round((h - 1) / 2 - ((ly0 + ly1) / 2 - lay))
        return a, int(ax), int(ay), x, y

    def aput(self, name, layer, how="acentre", lkname=None, parts=None, record=False):
        a, ax, ay, _x, _y = self.aplace(name, layer, how, lkname)
        self.out[name] = (a, ax, ay, parts)
        if record:
            self.records.add(name)
        return ax, ay

    def lk_axis(self, name):
        """Screen angle of a Liu Kang prop's long axis, pointing AWAY from its
        bloody end when it has one (its palette's reds)."""
        lc, _ax, _ay = self.lk(name)
        words = self.lkpal(name) if self.lkpal else None
        nz = np.argwhere(lc)
        cy, cx = nz.mean(0)
        red = None
        if words:
            redix = [i for i, v in enumerate(words)
                     if ((v >> 10) & 31) > 18 and ((v >> 5) & 31) < 9 and (v & 31) < 9]
            m = np.isin(lc, redix)
            if m.sum() >= 3:
                red = centroid(m)
        ev, evec = np.linalg.eigh(np.cov(nz[:, 1], nz[:, 0]))
        vx, vy = evec[:, -1]
        if red is not None and (cx - red[0]) * vx + (cy - red[1]) * vy < 0:
            vx, vy = -vx, -vy
        return math.degrees(math.atan2(vy, vx)), red is not None

    @staticmethod
    def luma(words):
        return [0.299 * ((v >> 10) & 31) + 0.587 * ((v >> 5) & 31) + 0.114 * (v & 31) for v in words]

    def to_ramp(self, layer, ramp_words, scale=1.0, lo=1, allowed=None):
        """Kano's pixels re-indexed into another palette by BRIGHTNESS: each of
        his colours to the entry of `ramp_words` (from `lo` up) whose luma is
        nearest his, scaled."""
        a, x, y = layer
        kl, rl = self.luma(self.kanopal), self.luma(ramp_words)
        kmax, rmax = max(kl[1:]) or 1, max(rl[lo:]) or 1
        lut = np.zeros(256, np.uint8)
        pick = [j for j in range(lo, len(rl)) if allowed is None or j in allowed]
        rmax = max(rl[j] for j in pick) or 1
        for i in range(1, len(kl)):
            t = kl[i] / kmax * scale * rmax
            lut[i] = min(pick, key=lambda j: abs(rl[j] - t))
        return np.where(a != 0, lut[a], 0).astype(np.uint8), x, y

    def extras(self):
        self.arm()
        self.freeze()
        self.spine()
        self.drained()
        self.split()
        self.pitfall()
        self.suck()
        self.baby()
        self.soulgreen()

    # --- Jax's arm rip: the arm that flies (LKRIPARM1-5, single objects) ---
    def arm(self):
        lane, step, (x0, y0, x1, y1) = ARM_SRC
        body = self.src(lane, step)
        m = np.zeros_like(body[0], bool)
        m[y0:y1, x0:x1] = True
        base = keep(body, m)
        ba, bx, by = base
        # the shoulder end bleeds - it is the arm's LEFT end in this drawing
        base = guts(base, (x0 - bx, 0), (x0 - bx, ba.shape[0] - 1), "ARM", hang=(-1, 0),
                    length=(2, 5), strands=2)
        nz = np.argwhere(base[0])
        ev, evec = np.linalg.eigh(np.cov(nz[:, 1], nz[:, 0]))
        vx, vy = evec[:, -1]
        if vx < 0:                       # the shoulder is the LEFT end: point at the hand
            vx, vy = -vx, -vy
        have = math.degrees(math.atan2(vy, vx))
        for n in range(1, 6):
            want, _ok = self.lk_axis(f"RIPARM{n}")
            a = base[0]
            lay = rotate(base, want - have, (base[1] + a.shape[1] / 2, base[2] + a.shape[0] / 2))
            self.aput(f"RIPARM{n}", lay, "acentre", record=True)
            self.ownpal.add(f"RIPARM{n}")

    # --- Sub-Zero's deep freeze: the body in ice, then the legs left standing ---
    def freeze(self):
        ice = self.asmpal("FREEZE_P")
        lane, step, waist, crotch = FREEZE_SRC
        # only the entries Liu Kang's ice art draws in: FREEZE_P carries a
        # magenta at 55 and other odd ones the frozen bodies never touch
        used = {j for j in set(np.unique(self.lk("superf")[0]).tolist()) - {0}
                if (ice[j] & 31) >= (ice[j] >> 10) & 31}       # ice: blue at least as strong as red
        a, x, y = self.to_ramp(self.src(lane, step), ice, allowed=used)
        r = _rng("ICE")
        lum = self.luma(ice)
        bright = max(used, key=lambda j: lum[j])
        # icicles: 2-7 px of the brightest ice off the bottom of some columns,
        # the way Liu Kang's frozen body drips
        h, w = a.shape
        pad = np.zeros((h + 8, w), np.uint8)
        pad[:h] = a
        for xx in range(w):
            if r.random() >= 0.22:
                continue
            col = np.nonzero(a[:, xx])[0]
            ends = [yy for yy in col if yy < h - 12 and not a[yy + 1, xx]]
            if ends:
                yy = ends[0]
                for k in range(r.randint(2, 7)):
                    pad[yy + 1 + k, xx] = bright
        whole = trimmed((pad, x, y))
        A, X, Y = whole
        rows, cols = np.mgrid[0:A.shape[0], 0:A.shape[1]]
        top = keep(whole, rows + Y < waist)
        left = keep(whole, (rows + Y >= waist) & (cols + X < crotch))
        right = keep(whole, (rows + Y >= waist) & (cols + X >= crotch))
        _a, ax, ay, Xw, Yw = self.aplace("superf", whole, "afoot", "superf")
        for k, part in (("FREEZ1A", top), ("FREEZ1B", left), ("FREEZ1C", right)):
            pa, px, py = part
            self.out[k] = (pa, ax - (px - Xw), ay - (py - Yw), None)
            self.records.add(k)
            self.pal[k] = "FREEZE_P"
        self.palwords["FREEZE_P"] = ice

    # --- Sub-Zero's head rip: the head off its neck (LKSPINE1, his palette) ---
    def spine(self):
        px, _ax, _ay = self.record(HEADS[0])
        b = np.isin(px, (DARK, BLOOD, BRIGHT))
        cx, cy = (px.shape[1] - 1) / 2, (px.shape[0] - 1) / 2
        bx, by = centroid(b)
        ang = math.degrees(math.atan2(by - cy, bx - cx))
        lay = rotate((px.copy(), 0, 0), 90 - ang, (px.shape[1] / 2, px.shape[0] / 2))   # neck DOWN
        a = lay[0]
        lay = guts(lay, (0, a.shape[0] - 1), (a.shape[1] - 1, a.shape[0] - 1), "SPINE",
                   hang=(0, 1), length=(3, 9), strands=3)
        ax, ay = self.aput("SPINE1", lay, "acentre", lkname="szhlk", record=True)
        a = self.out["SPINE1"][0]
        self.out["szh"] = (a, ax, ay, ["SPINE1"])      # f_szhlk: the frame holding it

    # --- Shang's soul drain: the husk, withering (SOULSUCKHO1-3) ---
    def drained(self):
        # a withered ramp: dried to a sickly green-brown, 63 steps, 0 clear
        ramp = [0]
        for k in range(1, 64):
            t = k / 63
            ramp.append((min(31, round(20 * t + 2)) << 10) | (min(31, round(22 * t + 3)) << 5)
                        | min(31, round(11 * t + 1)))
        self.palwords["KNDRAIN_P"] = ramp
        body = self.src(*DRAIN_SRC)
        for n, f in ((1, 1.0), (2, 0.82), (3, 0.66)):
            lay = self.to_ramp(body, ramp, scale=f)
            k = f"DRAIN{n}A"
            a, ax, ay, _x, _y = self.aplace(k, lay, "afoot", f"DRAIN{n}")
            self.out[k] = (a, ax, ay, None)
            self.records.add(k)
            self.pal[k] = "KNDRAIN_P"
            self.ownpal.add(k)
            self.out[f"DRAIN{n}"] = (a, ax, ay, [k])

    # --- Kung Lao's split: whole, the seam opens, then a half topples ---
    def split(self):
        lane, step, head_rows = SPLIT_SRC
        body = self.src(lane, step)
        h, w = body[0].shape
        # the seam goes down his MIDDLE: the centre of his head's columns (the
        # game mirrors the left half about it for the right one)
        hx = np.nonzero(body[0][:head_rows].any(axis=0))[0]
        cut = int(round((hx.min() + hx.max()) / 2))
        cols = np.mgrid[0:h, 0:w][1]
        for n, gap in ((1, 0), (2, 2), (3, 4)):
            L, R = keep(body, cols < cut), keep(body, cols >= cut)
            L = (L[0], L[1] - gap // 2, L[2])
            R = (R[0], R[1] + (gap + 1) // 2, R[2])
            hl = max(1, gap)
            L = guts(L, (cut - gap // 2 - L[1] - 1, 0), (cut - gap // 2 - L[1] - 1, L[0].shape[0] - 1),
                     f"SL{n}", hang=(1, 0), length=(1, 2), strands=gap, inward=True)
            R = guts(R, (cut + (gap + 1) // 2 - R[1], 0), (cut + (gap + 1) // 2 - R[1], R[0].shape[0] - 1),
                     f"SR{n}", hang=(-1, 0), length=(1, 2), strands=gap, inward=True)
            self.split_put(f"SPLIT{n}", paste([L, R]), cut)
        # 4-10: the LEFT half, its cut edge bleeding, toppling outward about
        # its foot on the cut.  The game MIRRORS THIS half about the anchor for
        # the other one (r_split_in_2: flip_multi), so the anchor stays on the cut
        half = keep(body, cols < cut)
        ha = half[0]
        half = guts(half, (cut - half[1] - 1, 0), (cut - half[1] - 1, ha.shape[0] - 1), "SHALF",
                    hang=(1, 0), length=(2, 7), strands=5)
        foot = (cut, half[2] + half[0].shape[0] - 1)
        for n, deg in zip(range(4, 11), SPLIT_TOPPLE):
            self.split_put(f"SPLIT{n}", rotate(half, -deg, foot) if deg else half, cut)

    def split_put(self, name, layer, cut):
        a, x, y = trimmed(layer)
        lc, _lax, lay = self.lk(name)
        ly1 = bbox(lc)[3]
        h, _w = a.shape
        self.out[name] = (a, int(cut - x), int(round(h - 1 - (ly1 - lay))), None)

    # --- the Pit: flailing on the way down, then the spikes ---
    def pitfall(self):
        for n, (lane, step, fl, deg) in PITFALL.items():
            lay = self.src(lane, step)
            if fl:
                lay = flip(lay)
            if deg:
                a = lay[0]
                lay = rotate(lay, deg, (a.shape[1] / 2, a.shape[0] / 2))
            self.aput(f"PITFALL{n}", lay, "acentre")

    # --- Mileena's suck: pulled in, stretched along Liu Kang's line, thinned ---
    def suck(self):
        base = self.src(*SUCK_SRC)
        sh, sw = base[0].shape
        for n in range(1, 8):
            lc, _lax, _lay = self.lk(f"SUCK{n}")
            nz = np.argwhere(lc)
            ev, evec = np.linalg.eigh(np.cov(nz[:, 1], nz[:, 0]))
            vx, vy = evec[:, -1]
            t = math.atan2(vy, vx)
            u = nz[:, 1] * math.cos(t) + nz[:, 0] * math.sin(t)
            v = -nz[:, 1] * math.sin(t) + nz[:, 0] * math.cos(t)
            along, across = u.max() - u.min() + 1, v.max() - v.min() + 1
            # him upright is a tall shape: fit his height to Liu Kang's long
            # axis and his width to its thickness, then lay him along it
            sc = scale_layer(base, max(0.12, across / sw), max(0.12, along / sh))
            a = sc[0]
            lay = rotate(sc, math.degrees(t) - 90, (sc[1] + a.shape[1] / 2, sc[2] + a.shape[0] / 2))
            self.aput(f"SUCK{n}", lay, "acentre")

    # --- the babality: big head, small body ---
    def baby(self):
        lane, step, neck = BABY_SRC
        body = self.src(lane, step)
        rows = np.mgrid[0:body[0].shape[0], 0:body[0].shape[1]][0]
        head = keep(body, rows < neck)
        torso = trimmed(self.src(*BABY_BODY))
        lc, _lax, _lay = self.lk("BABE")
        lx0, ly0, lx1, ly1 = bbox(lc)
        H = ly1 - ly0 + 1
        hd = scale_layer(head, BABY_HEAD, BABY_HEAD)
        f = (H - hd[0].shape[0] + 3) / torso[0].shape[0]
        bd = scale_layer(torso, f, f)
        ha, bda = hd[0], bd[0]
        hx = bd[1] + (bda.shape[1] - ha.shape[1]) // 2
        hy = bd[2] - ha.shape[0] + 3
        self.aput("BABE", paste([bd, (ha, hx, hy)]), "afoot", record=True)
        self.ownpal.add("BABE")

    # --- Shao Kahn's soul rip: the soul is his suck strips, in green ---
    def soulgreen(self):
        # tools/make_soulrip_pals.py's recipe: Y 8-bit luma, G = Y*27/255, B = G/4
        g = []
        for v in self.kanopal:
            r_, g_, b_ = (((v >> s) & 31) * 255 / 31 for s in (10, 5, 0))
            gg = min(31, int(round((0.299 * r_ + 0.587 * g_ + 0.114 * b_) * 27 / 255)))
            g.append((gg << 5) | (gg // 4))
        self.palwords["SOULGRN_KN"] = g

    def decap(self):
        for n, (step, p0, p1, tin) in DECAP.items():
            body = self.src("4F", step)
            m = side(body, p0, p1)
            if not m[tin[1], tin[0]]:
                m = ~m
            torso, legs = keep(body, m), keep(body, ~m)
            # hang the guts OUT of each half, perpendicular to the cut
            vx, vy = p1[0] - p0[0], p1[1] - p0[1]
            nx, ny = vy, -vx                  # a normal; point it away from the torso
            if (tin[0] - p0[0]) * nx + (tin[1] - p0[1]) * ny > 0:
                nx, ny = -nx, -ny
            q0 = (p0[0] - legs[1], p0[1] - legs[2])
            q1 = (p1[0] - legs[1], p1[1] - legs[2])
            # ONLY THE LEGS CARRY THE STUMP, capped OUTWARD into the torso's
            # space: in DECAPn the torso is drawn after them and covers it, as
            # Liu Kang's DEADLEG/DEADTORSO do - so the joined body is clean
            legs = guts(legs, q0, q1, f"L{n}", hang=(-nx, -ny), length=(2, 5), strands=2, inward=False)
            whole = paste([legs, torso])
            a, ax, ay, X, Y = self.place(f"DECAP{n}", whole)
            # every part shares the DECAP's anchor: place each by its world offset
            for nm, part in ((f"DEADLEG{n}", legs), (f"ERT_TORSO{n}", torso)):
                pa, px, py = part
                self.out[nm] = (pa, ax - (px - X), ay - (py - Y), None)
            self.out[f"DECAP{n}"] = (a, ax, ay, [f"DEADLEG{n}", f"ERT_TORSO{n}"])
            # the head hole: the head back on the stump, holed
            self.parts[n] = (body, torso, (ax, ay, X, Y))

    def head_layer(self, k, deg):
        px, hax, hay = self.record(HEADS[k % 4])
        return rotate((px, 0, 0), deg + 90 * 0, (px.shape[1] / 2, px.shape[0] / 2))

    def heads(self):
        hs = [self.record(h) for h in HEADS]
        # each drawing's NECK: where its blood is, from its middle
        def neck_angle(px):
            cx, cy = (px.shape[1] - 1) / 2, (px.shape[0] - 1) / 2
            bx, by = centroid(np.isin(px, (DARK, BLOOD, BRIGHT)))
            return math.degrees(math.atan2(by - cy, bx - cx))     # screen angle of the neck
        angs = [neck_angle(p) for p, _x, _y in hs]
        self.neck = angs

        def head_at(want):
            """A head whose neck points along screen angle `want`: the drawing
            closest to it, rotated the rest of the way."""
            k = min(range(4), key=lambda i: abs(((want - angs[i]) + 180) % 360 - 180))
            px = hs[k][0]
            d = ((want - angs[k]) + 180) % 360 - 180
            return rotate((px, 0, 0), d, ((px.shape[1]) / 2, (px.shape[0]) / 2))

        # THE ROLLING HEAD (a_head, 7 frames looping): neck down, then round
        for i in range(7):
            self.put(f"HEAD{i + 1}", head_at(90 + i * 360 / 7), how="centre")
        # THE HEAD HOLE: the head back on DECAPn's stump, along the body's axis
        for n, (body, torso, (ax, ay, X, Y)) in self.parts.items():
            tb = torso[0]
            stump = np.isin(tb, (DARK, BLOOD, BRIGHT))
            # the stump is the blood FARTHEST from the waist cut
            step, p0, p1, tin = DECAP[n]
            wx, wy = (p0[0] + p1[0]) / 2 - torso[1], (p0[1] + p1[1]) / 2 - torso[2]
            ys, xs = np.nonzero(stump)
            dd = (xs - wx) ** 2 + (ys - wy) ** 2
            far = dd >= np.percentile(dd, 85)
            sx, sy = float(xs[far].mean()), float(ys[far].mean())
            up = math.degrees(math.atan2(sy - wy, sx - wx))    # waist -> neck
            hl = head_at(up + 180)                              # its neck points back at the waist
            hp = hl[0]
            nb = np.isin(hp, (DARK, BLOOD, BRIGHT))
            hbx, hby = centroid(nb) if nb.any() else ((hp.shape[1] - 1) / 2, hp.shape[0] - 1)
            # sit the head's neck on the stump, a couple of px into it
            ux, uy = math.cos(math.radians(up)), math.sin(math.radians(up))
            hx = round(torso[1] + sx - hbx + ux * 2)
            hy = round(torso[2] + sy - hby + uy * 2)
            # never below the body it sits on (the face-down frames put the
            # stump at floor level, and the head would go through the floor)
            lw, tw = self.out_world(f"DEADLEG{n}", ax, ay, X, Y), self.out_world(f"ERT_TORSO{n}", ax, ay, X, Y)
            floor = max(lw[2] + lw[0].shape[0], tw[2] + tw[0].shape[0])
            hy = min(hy, floor - hp.shape[0])
            ccx, ccy = (hp.shape[1] - 1) / 2, (hp.shape[0] - 1) / 2
            holed = hole((hp, hx, hy), (round(ccx + ux * 2), round(ccy + uy * 2)), 3, f"H{n}")
            whole = paste([self.out_world(f"DEADLEG{n}", ax, ay, X, Y),
                           self.out_world(f"ERT_TORSO{n}", ax, ay, X, Y), holed])
            # the HOLE frame uses the DECAP's anchor, so the head lines up with
            # the body it was drawn on
            a2, X2, Y2 = whole
            self.out[f"HOLEHEAD{n}"] = (holed[0], ax - (holed[1] - X), ay - (holed[2] - Y), None)
            self.out[f"HOLE{n}"] = (a2, ax - (X2 - X), ay - (Y2 - Y),
                                    [f"DEADLEG{n}", f"ERT_TORSO{n}", f"HOLEHEAD{n}"])

    def out_world(self, nm, ax, ay, X, Y):
        a, pax, pay, _p = self.out[nm]
        return a, X + (ax - pax), Y + (ay - pay)

    def rip(self):
        bases = {}
        for key, (lane, step, p0, p1, tin) in (("up", TORSO_UP), ("down", TORSO_DOWN)):
            body = self.src(lane, step)
            m = side(body, p0, p1)
            if not m[tin[1], tin[0]]:
                m = ~m
            t = keep(body, m)
            vx, vy = p1[0] - p0[0], p1[1] - p0[1]
            nx, ny = vy, -vx
            if (tin[0] - p0[0]) * nx + (tin[1] - p0[1]) * ny > 0:
                nx, ny = -nx, -ny
            q0, q1 = (p0[0] - t[1], p0[1] - t[2]), (p1[0] - t[1], p1[1] - t[2])
            bases[key] = guts(t, q0, q1, f"R{key}", hang=(nx, ny), length=(5, 14), strands=4)
        for n, (b, deg, fl) in RIP.items():
            layer = bases[b]
            if fl:
                layer = flip(layer)
            if deg:
                a = layer[0]
                layer = rotate(layer, deg, (layer[1] + a.shape[1] / 2, layer[2] + a.shape[0] / 2))
            self.put(f"RIPTORSO{n}", layer)

    def back(self):
        for n, (lane, step, waist, bh, bf) in BACK.items():
            body = self.src(lane, step)
            if waist and (bh or bf):
                wx, wy = waist
                m = side(body, (wx, 0), (wx, 1))          # LEFT of a downward line = +x
                feet, head = keep(body, m), keep(body, ~m)
                # the head end (left) tips DOWN, the feet end tips down: a fold
                # over the knee at the waist
                head = rotate(head, -bh, (wx, wy))
                feet = rotate(feet, -bf, (wx, wy))
                body = paste([feet, head])
            self.put(f"BACKBREAK{n}", body)


def main():
    import make_mk1kano_port as P
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--preview", metavar="DIR")
    ap.add_argument("--only", nargs="*", default=(), help="name prefixes to sheet")
    a = ap.parse_args()
    s = P.synth()
    if a.preview:
        P.synth_preview(s, Path(a.preview), tuple(a.only))
    return 0


if __name__ == "__main__":
    sys.exit(main())
