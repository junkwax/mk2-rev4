#!/usr/bin/env python3
"""Reproduce an IMGTOOL World View preview offline, from the export's own
draw equation, and print where each pose actually lands.

    left = anchor_x - anieff(anix - dAX, sizex, fliph)
    top  = anchor_y - anieff(aniy - dAY, sizey, flipv)
    anieff(a, size, flip) = (size - a) if flip else a      # MKUTIL ani2

Answers the only question that matters when a lane looks wrong in game:
what did the author actually see, and therefore where does the runtime have
to put the object.  Geometry comes from the linked .TBLs, so it is the same
art the ROM draws.  Multipart poses are unioned across their strips.
"""
import io, os, re, sys

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'src')

def load_records():
    rec = {}
    for f in os.listdir(SRC):
        if not f.endswith('.TBL'):
            continue
        t = io.open(os.path.join(SRC, f), encoding='latin-1', errors='replace').read()
        for m in re.finditer(r'^(\w+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)', t, re.M):
            rec.setdefault(m.group(1), tuple(int(x) for x in m.groups()[1:]))
    return rec

def load_wrappers():
    wr = {}
    for f in os.listdir(SRC):
        if not f.endswith('.ASM'):
            continue
        t = io.open(os.path.join(SRC, f), encoding='latin-1', errors='replace').read()
        for m in re.finditer(r'^(\w+)\s+\.long\s+([A-Z0-9_]+(?:\s*,\s*[A-Z0-9_]+)*)\s*,\s*0\s*$',
                             t, re.M):
            wr.setdefault(m.group(1), [p.strip() for p in m.group(2).split(',')])
        # multi-line form: LABEL on its own line, strips on the next
        for m in re.finditer(r'^(\w+)\n\s*\.long\s+([A-Z0-9_]+(?:\s*,\s*[A-Z0-9_]+)*)\s*,\s*0\s*$',
                             t, re.M):
            wr.setdefault(m.group(1), [p.strip() for p in m.group(2).split(',')])
    return wr

REC, WRAP = load_records(), load_wrappers()

def parts(name):
    if name in WRAP:
        return [p for p in WRAP[name] if p in REC]
    return [name] if name in REC else []

def anieff(a, size, flip):
    return (size - a) if flip else a

def box(name, dax, day, fliph, flipv, ax, ay):
    """Union box of a pose drawn at the given anchor + offset."""
    ps = parts(name)
    if not ps:
        return None
    xs, ys = [], []
    for p in ps:
        w, h, anix, aniy = REC[p]
        left = ax - anieff(anix - dax, w, fliph)
        top  = ay - anieff(aniy - day, h, flipv)
        xs += [left, left + w]
        ys += [top, top + h]
    return min(xs), min(ys), max(xs), max(ys)
