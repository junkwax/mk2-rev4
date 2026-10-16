#!/usr/bin/env python3
"""Re-cut the wedge-prone terracotta guard pieces in data/TWRSIDE.BDB/.BDD.

LOAD2 re-compresses every sprite row as a leading and trailing transparent run,
each stored as nibble(0..15) * ONE multiplier (1, 2, 4 or 8) shared by the whole
image. A band whose silhouette moves diagonally has runs that no single
multiplier expresses, so LOAD2 rounds them, the visible span walks sideways row
over row, and a triangular wedge of art goes missing in game - while the editor,
which keeps flat pixels, shows it perfectly.

Tight-trimming does not help these pieces: they are already tight, and the
diagonal is interior to the band. What works is one more horizontal cut placed
where the run actually jumps - STATUE2's staff enters at row 26 and drops the
leading run from 20 to 0 in a single step - then a tight trim of each new band.

Splitting is pixel-exact by construction: each band keeps its own pixels and is
re-anchored so it lands where it did before, mirrored blocks included. The
script proves that before writing anything.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BDB = ROOT / "data" / "TWRSIDE.BDB"
BDD = ROOT / "data" / "TWRSIDE.BDD"
META = ROOT / "data" / "TWRSIDE.BDD.meta"

MULTS = (1, 2, 4, 8)
MAXN = 15
HFLIP = 0x10
NL = chr(10)
TAB = chr(9)


def encodable(runs):
    if not runs:
        return True
    return any(all(v % m == 0 and v // m <= MAXN for v in runs) for m in MULTS)


def read_bdd(path):
    d = path.read_bytes()
    pos = d.index(b"\n") + 1
    n = int(d[:pos].split()[0])
    imgs = []
    for _ in range(n):
        j = d.index(b"\n", pos)
        p = d[pos:j].split()
        idx, w, h, bp = int(p[0], 16), int(p[1]), int(p[2]), p[3].decode()
        pos = j + 1
        imgs.append([idx, w, h, bp, d[pos:pos + w * h]])
        pos += w * h
    pals = []
    while pos < len(d):
        j = d.index(b"\n", pos)
        nm, cnt = d[pos:j].split()
        cnt = int(cnt)
        pos = j + 1
        pals.append((nm.decode(), d[pos:pos + 2 * cnt]))
        pos += 2 * cnt
    return imgs, pals


def write_bdd(path, imgs, pals):
    out = bytearray()
    out += ("%d%s" % (len(imgs), NL)).encode()
    for idx, w, h, bp, px in imgs:
        out += ("%X %d %d %s%s" % (idx, w, h, bp, NL)).encode()
        out += px
    for nm, raw in pals:
        out += ("%s %d%s" % (nm, len(raw) // 2, NL)).encode()
        out += raw
    path.write_bytes(bytes(out))


def read_bdb(path):
    lines = [l for l in path.read_text().replace(chr(13), "").split(NL) if l.strip()]
    head = lines[0].split()
    nmods = int(head[4])
    mods = lines[1:1 + nmods]
    blocks = [l.split() for l in lines[1 + nmods:1 + nmods + int(head[6])]]
    return head, mods, blocks


def row_runs(px, w, h):
    out = []
    for y in range(h):
        r = px[y * w:(y + 1) * w]
        vis = [x for x in range(w) if r[x] != 0]
        out.append(None if not vis else (vis[0], w - 1 - vis[-1]))
    return out


def band_ok(runs):
    v = [r for r in runs if r]
    if not v:
        return True
    lead = [a for a, _ in v]
    trail = [b for _, b in v]
    return (encodable([a - min(lead) for a in lead]) and
            encodable([b - min(trail) for b in trail]))


def plan_cuts(px, w, h):
    """Greedy: grow a band until it stops encoding, then cut there."""
    runs = row_runs(px, w, h)
    cuts, start = [], 0
    for y in range(1, h + 1):
        if not band_ok(runs[start:y]):
            cuts.append(y - 1)
            start = y - 1
    return [0] + cuts + [h]


def carve(px, w, y0, y1):
    """Tight-trim rows y0..y1-1. Returns (trim_left, trim_right, w2, h2, pixels)."""
    rows = [px[y * w:(y + 1) * w] for y in range(y0, y1)]
    vis = [[x for x in range(w) if r[x] != 0] for r in rows]
    live = [v for v in vis if v]
    if not live:
        return 0, 0, w, y1 - y0, b"".join(rows)
    tl = min(v[0] for v in live)
    tr = w - 1 - max(v[-1] for v in live)
    w2 = w - tl - tr
    out = bytearray()
    for r in rows:
        out += r[tl:tl + w2]
    return tl, tr, w2, y1 - y0, bytes(out)


def paint(blocks, sizes, pixels):
    """Every painted pixel keyed by screen position, honouring H-flip."""
    canvas = {}
    for b in blocks:
        iid = int(b[3], 16)
        w, h = sizes[iid]
        px = pixels[iid]
        flipped = int(b[0], 16) & HFLIP
        bx, by = int(b[1]), int(b[2])
        for y in range(h):
            base = y * w
            for x in range(w):
                v = px[base + x]
                if v == 0:
                    continue
                sx = bx + (w - 1 - x) if flipped else bx + x
                canvas[(sx, by + y)] = (v, b[4])
    return canvas


def main():
    imgs, pals = read_bdd(BDD)
    head, mods, blocks = read_bdb(BDB)
    by_id = {i[0]: i for i in imgs}

    # Only guard art is re-cut. The stock TOWER2 blocks are Midway's and stay
    # byte-identical; tools/twrside_statue_layout.py enforces that separately.
    guard_ids = set(int(b[3], 16) for b in blocks if b[4] == "3")
    risky = [i[0] for i in imgs
             if i[0] in guard_ids and not band_ok(row_runs(i[4], i[1], i[2]))]
    if not risky:
        print("no wedge-prone guard pieces; nothing to do")
        return 0

    next_id = max(i[0] for i in imgs) + 1
    new_imgs = []
    replacement = {}
    for idx in risky:
        _i, w, h, bp, px = by_id[idx]
        bands = plan_cuts(px, w, h)
        parts = []
        for k in range(len(bands) - 1):
            y0, y1 = bands[k], bands[k + 1]
            tl, tr, w2, h2, sub = carve(px, w, y0, y1)
            new_imgs.append([next_id, w2, h2, bp, sub])
            parts.append((next_id, tl, tr, w2, h2, y0))
            next_id += 1
        replacement[idx] = parts
        detail = ", ".join("%dx%d@y%d" % (p[3], p[4], p[5]) for p in parts)
        print("  hdr %02X %dx%d -> %d band(s): %s" % (idx, w, h, len(parts), detail))

    out_blocks = []
    for b in blocks:
        img = int(b[3], 16)
        if img not in replacement:
            out_blocks.append(b)
            continue
        flags, bx, by, pal = int(b[0], 16), int(b[1]), int(b[2]), b[4]
        for new_id, tl, tr, _w2, _h2, y0 in replacement[img]:
            # An H-flipped block mirrors within its own footprint, so pixels
            # trimmed off the source LEFT come off the drawn RIGHT. Anchoring by
            # the opposite trim keeps the band exactly where it was.
            nx = bx + (tr if (flags & HFLIP) else tl)
            out_blocks.append(["%04X" % flags, str(nx), str(by + y0),
                               "%X" % new_id, pal])

    final_imgs = [i for i in imgs if i[0] not in replacement] + new_imgs
    sizes = dict((i[0], (i[1], i[2])) for i in final_imgs)

    # Sort ONLY the blocks that were re-cut. The stock TOWER2 records keep their
    # original order byte for byte: they are already ascending-x inside their own
    # modules, and tools/twrside_statue_layout.py compares them as an ordered
    # list, so a global re-sort would read as retail drift even though the set is
    # unchanged. The guard blocks still need ascending x among themselves or
    # bsrch1stxb stops early and loses the tail of the row.
    touched = set(id(b) for b in out_blocks if int(b[3], 16) in
                  set(p[0] for parts in replacement.values() for p in parts))
    guard_pal = set(b[4] for b in blocks if int(b[3], 16) in replacement)
    stock_part = [b for b in out_blocks if b[4] not in guard_pal]
    guard_part = [b for b in out_blocks if b[4] in guard_pal]
    guard_part.sort(key=lambda b: (int(b[1]), int(b[2])))
    out_blocks = stock_part + guard_part

    before = paint(blocks, dict((i[0], (i[1], i[2])) for i in imgs),
                   dict((i[0], i[4]) for i in imgs))
    after = paint(out_blocks, sizes, dict((i[0], i[4]) for i in final_imgs))
    if before != after:
        lost = len(set(before) - set(after))
        gained = len(set(after) - set(before))
        changed = len([k for k in set(before) & set(after) if before[k] != after[k]])
        print("ABORT: re-cut is not pixel-exact (%d lost, %d gained, %d changed)"
              % (lost, gained, changed), file=sys.stderr)
        return 1
    print("  verified pixel-exact: %d painted pixels unchanged" % len(before))

    still = ["%02X" % i[0] for i in new_imgs
             if not band_ok(row_runs(i[4], i[1], i[2]))]
    if still:
        print("ABORT: bands still wedge-prone: %s" % still, file=sys.stderr)
        return 1
    print("  all %d new bands encode cleanly" % len(new_imgs))

    head[6] = str(len(out_blocks))
    BDB.write_text(NL.join([" ".join(head)] + mods +
                           [" ".join(b) for b in out_blocks]) + NL, newline="")
    write_bdd(BDD, final_imgs, pals)

    names = {}
    if META.exists():
        for line in META.read_text().split(NL):
            f = line.rstrip().split(TAB)
            if len(f) > 3 and f[0] == "IMG":
                names[int(f[1], 16)] = (f[2], f[3])
    band_name = {}
    for old, parts in replacement.items():
        base, src = names.get(old, ("", ""))
        for k, p in enumerate(parts):
            band_name[p[0]] = ((base + chr(97 + k)) if base else "", src)
    zeros = TAB.join(["0"] * 11)
    out = ["# bddview image metadata v1"]
    for i in final_imgs:
        nm, src = names.get(i[0], band_name.get(i[0], ("", "")))
        out.append("IMG%s%X%s%s%s%s%s%s" % (TAB, i[0], TAB, nm, TAB, src, TAB, zeros))
    META.write_text(NL.join(out) + NL, newline="")

    print("%swrote %s: %d -> %d blocks, %d -> %d images"
          % (NL, BDB.name, len(blocks), len(out_blocks), len(imgs), len(final_imgs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
