#!/usr/bin/env python3
"""Drop images and palettes no block references from a BDB/BDD pair.

LOAD2 emits one <NAME>HDRS record per BDD image and one <NAME>PALS pointer per
palette whether or not anything draws them, so an orphan costs image ROM, a
header slot out of MAXHDRS, and a palette slot out of MAXPALS. Placeholder art
that has since been replaced by a runtime animator is the usual source.

Blocks address images by the BDD's own id (the "oldh" field), not by position,
so removing an image never renumbers the others. Palettes ARE addressed by
position, so dropping one renumbers every palette after it and every block that
used them is rewritten to match.

Verified before anything is written: the set of painted pixels, with the colour
each one resolves to through its palette, must be identical afterwards.

    python tools/bdd_strip_unused.py data/TWRSIDE.BDB          # report
    python tools/bdd_strip_unused.py data/TWRSIDE.BDB --apply
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

NL = chr(10)
HFLIP = 0x10


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
        pals.append([nm.decode(), d[pos:pos + 2 * cnt]])
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


def paint(blocks, imgs, pals):
    """Painted pixels keyed by screen position, valued by RESOLVED colour, so a
    palette renumber that preserves the picture compares equal."""
    size = dict((i[0], (i[1], i[2])) for i in imgs)
    pix = dict((i[0], i[4]) for i in imgs)
    canvas = {}
    for b in blocks:
        iid = int(b[3], 16)
        w, h = size[iid]
        px = pix[iid]
        pal = pals[int(b[4])][1]
        flipped = int(b[0], 16) & HFLIP
        bx, by = int(b[1]), int(b[2])
        for y in range(h):
            base = y * w
            for x in range(w):
                v = px[base + x]
                if v == 0:
                    continue
                sx = bx + (w - 1 - x) if flipped else bx + x
                rgb = struct.unpack_from("<H", pal, 2 * v)[0] if 2 * v < len(pal) else ("OOR", v)
                canvas[(sx, by + y)] = rgb
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bdb")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    bdb = Path(args.bdb)
    bdd = bdb.with_suffix(".BDD")
    if not bdd.exists():
        bdd = bdb.with_suffix(".bdd")
    imgs, pals = read_bdd(bdd)
    head, mods, blocks = read_bdb(bdb)

    used_i = set(int(b[3], 16) for b in blocks)
    used_p = set(int(b[4]) for b in blocks)
    dead_i = [i[0] for i in imgs if i[0] not in used_i]
    dead_p = [k for k in range(len(pals)) if k not in used_p]

    if not dead_i and not dead_p:
        print("nothing unreferenced; leaving %s alone" % bdb.name)
        return 0
    bytes_freed = sum(i[1] * i[2] for i in imgs if i[0] in dead_i)
    print("unreferenced images   : %s" % ([("%02X" % i) for i in dead_i] or "none"))
    print("unreferenced palettes : %s" % ([pals[k][0] for k in dead_p] or "none"))
    print("raw pixel bytes freed : %d" % bytes_freed)
    if not args.apply:
        print("%sre-run with --apply to strip" % NL)
        return 1

    keep_imgs = [i for i in imgs if i[0] in used_i]
    keep_pals = [p for k, p in enumerate(pals) if k in used_p]
    remap = {}
    n = 0
    for k in range(len(pals)):
        if k in used_p:
            remap[k] = n
            n += 1
    new_blocks = [[b[0], b[1], b[2], b[3], str(remap[int(b[4])])] for b in blocks]

    before = paint(blocks, imgs, pals)
    after = paint(new_blocks, keep_imgs, keep_pals)
    if before != after:
        print("ABORT: stripping changed the picture (%d differing pixels)"
              % len(set(before.items()) ^ set(after.items())), file=sys.stderr)
        return 1
    print("  verified pixel-exact: %d painted pixels unchanged" % len(before))

    head[5] = str(len(keep_pals))
    head[6] = str(len(new_blocks))
    bdb.write_text(NL.join([" ".join(head)] + mods +
                           [" ".join(b) for b in new_blocks]) + NL, newline="")
    write_bdd(bdd, keep_imgs, keep_pals)

    meta = Path(str(bdd) + ".meta")
    if meta.exists():
        out = []
        for line in meta.read_text().split(NL):
            f = line.rstrip().split(chr(9))
            if len(f) > 1 and f[0] == "IMG" and int(f[1], 16) in dead_i:
                continue
            if line.strip():
                out.append(line)
        meta.write_text(NL.join(out) + NL, newline="")

    print("%swrote %s: %d -> %d images, %d -> %d palettes"
          % (NL, bdb.name, len(imgs), len(keep_imgs), len(pals), len(keep_pals)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
