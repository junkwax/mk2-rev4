#!/usr/bin/env python3
"""Pad the terracotta guard sprites to a 4-pixel width in data/TWRSIDE.BDB/.BDD.

Every one of the 1081 background images Midway shipped has a width that is a
MULTIPLE OF 4. Not one exception, across all 41 stages. That is not taste, it is
the background emitter: zcom_analysis walks the source with
`zero_pad = (4 - xsize) & 3`, i.e. it assumes each row is padded out to a
4-byte boundary, while the BDD stores rows tight. And
docs/LOAD2_BACKGROUND_DMA2_QUIRKS.md ("Odd-Width Header Scan Uses Even Stride")
records the same class of fault: LOAD2 decides the compressed row headers on a
padded scan stride while copying the pixel payload from the tight rows, so the
header describes a byte row that drifts further from the payload with every
line and the decoded art shears progressively down the sprite - a triangular
wedge.

A width of 42 is even but still 2 short of a multiple of 4, which is why an
even-only pass fixed some statues and left STATUE2 - 42, 66, 50 and 54 wide -
still shearing.

The fix is lossless: append transparent columns. An unflipped block does not
move, because the new columns are on the right and transparent. An H-flipped
block mirrors within its own footprint, so columns added on the source right
land on the drawn LEFT - such a block is shifted left by the pad width to
compensate. Both are verified pixel-exact before anything is written.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BDB = ROOT / "data" / "TWRSIDE.BDB"
BDD = ROOT / "data" / "TWRSIDE.BDD"
STOCK_BDD = ROOT / "data" / "TOWER2.BDD"

HFLIP = 0x10
NL = chr(10)
WIDTH_ALIGN = 4


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


def paint(blocks, sizes, pixels):
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

    stock_ids = set(i[0] for i in read_bdd(STOCK_BDD)[0])
    guard_ids = set(int(b[3], 16) for b in blocks if int(b[3], 16) not in stock_ids)

    odd = [i[0] for i in imgs if i[0] in guard_ids and i[1] % WIDTH_ALIGN]
    if not odd:
        print("every guard sprite width is already aligned; nothing to do")
        return 0
    print("padding %d guard sprite(s) up to a multiple of %d: %s"
          % (len(odd), WIDTH_ALIGN, ", ".join("%02X" % i for i in odd)))

    new_imgs = []
    for idx, w, h, bp, px in imgs:
        if idx not in odd:
            new_imgs.append([idx, w, h, bp, px])
            continue
        pad = (-w) % WIDTH_ALIGN
        out = bytearray()
        for y in range(h):
            out += px[y * w:(y + 1) * w]
            out += bytes(pad)                  # transparent columns on the right
        new_imgs.append([idx, w + pad, h, bp, bytes(out)])

    old_w = dict((i[0], i[1]) for i in imgs)
    new_blocks = []
    for b in blocks:
        iid = int(b[3], 16)
        if iid not in odd:
            new_blocks.append(b)
            continue
        flags, bx = int(b[0], 16), int(b[1])
        pad = (-old_w[iid]) % WIDTH_ALIGN
        # The pad lands on the drawn LEFT of a mirrored block, so pull it back
        # by the pad width; an unflipped block is unaffected.
        nx = bx - pad if (flags & HFLIP) else bx
        new_blocks.append([b[0], str(nx), b[2], b[3], b[4]])

    old_sizes = dict((i[0], (i[1], i[2])) for i in imgs)
    old_pix = dict((i[0], i[4]) for i in imgs)
    new_sizes = dict((i[0], (i[1], i[2])) for i in new_imgs)
    new_pix = dict((i[0], i[4]) for i in new_imgs)
    before = paint(blocks, old_sizes, old_pix)
    after = paint(new_blocks, new_sizes, new_pix)
    if before != after:
        lost = len(set(before) - set(after))
        gained = len(set(after) - set(before))
        changed = len([k for k in set(before) & set(after) if before[k] != after[k]])
        print("ABORT: padding moved art (%d lost, %d gained, %d changed)"
              % (lost, gained, changed), file=sys.stderr)
        return 1
    print("  verified pixel-exact: %d painted pixels unchanged" % len(before))

    # Flipped blocks shifted a pixel, so re-establish ascending x among the
    # guard blocks only; the stock records keep their original order.
    stock_part = [b for b in new_blocks if int(b[3], 16) in stock_ids]
    guard_part = [b for b in new_blocks if int(b[3], 16) not in stock_ids]
    guard_part.sort(key=lambda b: (int(b[1]), int(b[2])))
    new_blocks = stock_part + guard_part

    still = [i[0] for i in new_imgs if i[0] in guard_ids and i[1] % WIDTH_ALIGN]
    if still:
        print("ABORT: width still unaligned: %s" % still, file=sys.stderr)
        return 1

    head[6] = str(len(new_blocks))
    BDB.write_text(NL.join([" ".join(head)] + mods +
                           [" ".join(b) for b in new_blocks]) + NL, newline="")
    write_bdd(BDD, new_imgs, pals)
    print("%swrote %s: all %d guard sprites now %d-pixel aligned"
          % (NL, BDB.name, len(guard_ids), WIDTH_ALIGN))
    return 0


if __name__ == "__main__":
    sys.exit(main())
