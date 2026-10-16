#!/usr/bin/env python3
"""KANO -> SHANG TSUNG morph, built into data/KANOMORPH.IMG the way Midway
built Shang's morphs in data/MKMORPH1.IMG.

How MKMORPH1 does it (read off the file, `tools/dump_imgtool_seqscr.py`):
  * three in-between frames per target - SHANGZERO1-3, SHANGCAGE1-3, ... -
    each a whole standing figure, frame 1 nearest the source;
  * all three share ONE merged palette holding both fighters' colours
    (SHZERO_P, SHCAGE_P, ...), 6bpp, so the costume can change patch by patch;
  * the silhouette walks from one stance to the other across the three;
  * a sequence record plays it: source stance held 5, in-betweens 1 each,
    target stance held 5, then the in-betweens back down (8 entries).

What this writes, on top of the two sprites already in KANOMORPH.IMG:
  * KANO (MK1's stance frame K00_5, matched 97.9% against data/MK1KANO.IMG)
    and STSTANCE1 get anipoints, FEET-ALIGNED: STSTANCE1 keeps MK2's own
    (25,-12); KANO's x 26 is MK1's anchor, its y is set so his feet land on
    Shang's (MK1's own y, -14, stands him 5px lower);
  * KANOSHANG1-3 on KNSHANG_P: both stances thin-plate-spline warped onto a
    shared keypoint skeleton at t=.25/.5/.75 and CROSS-DISSOLVED in RGB -
    Midway's in-betweens are a real blend (MKMORPH1's RAIDBOY_vda, a capture
    of the morph render, shows Raiden's hat as a ghost over Shang's hair) -
    then quantised to one merged palette;
  * the sequence "KANO TO SHANG", Midway's 5/1/1/1/5/1/1/1 shape.

KANOMORPH.IMG is in no LOD: a workbench, not in Phase D.  Re-running replaces
the generated records and leaves KANO / STSTANCE1 pixels alone.

    python tools/make_kanomorph.py            # write data/KANOMORPH.IMG
    python tools/make_kanomorph.py --png DIR  # also preview sheet + GIF
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

import numpy as np
from scipy.interpolate import RBFInterpolator
from scipy.ndimage import label, map_coordinates

ROOT = Path(__file__).resolve().parents[1]
IMG = ROOT / "data" / "KANOMORPH.IMG"

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26
NUMDEFPAL = 3

SRC, DST = "KANO", "STSTANCE1"
ANCHOR = {SRC: (26, -9), DST: (25, -12)}              # image coords, feet on one line
TWEEN = "KANOSHANG%d"
TWEEN_PAL = "KNSHANG_P"
TS = (0.25, 0.50, 0.75)
SEQ_NAME = "KANO TO SHANG"

# matched body points, IMAGE coords (x, y) of each sprite
KEYS = [  # name,             KANO,      STSTANCE1
    ("head top",          (32, 1),   (23, 1)),
    ("eye",               (37, 10),  (31, 14)),
    ("chin",              (34, 18),  (29, 20)),
    ("back shoulder",     (12, 24),  (7, 25)),
    ("front shoulder",    (36, 22),  (33, 24)),
    ("back elbow",        (7, 38),   (3, 38)),
    ("back arm low",      (7, 45),   (3, 50)),
    ("rear fist",         (17, 40),  (18, 46)),
    ("front elbow",       (45, 36),  (40, 38)),
    ("front fist",        (61, 26),  (43, 50)),
    ("belt left",         (12, 50),  (15, 53)),
    ("belt right",        (37, 50),  (35, 53)),
    ("back hip",          (12, 55),  (10, 58)),
    ("front hip",         (42, 67),  (38, 67)),
    ("crotch",            (27, 80),  (26, 78)),
    ("back knee",         (8, 100),  (7, 97)),
    ("front knee",        (45, 97),  (38, 93)),
    ("back toe",          (2, 130),  (2, 127)),
    ("back heel",         (8, 128),  (7, 127)),
    ("front heel",        (44, 127), (45, 121)),
    ("front toe",         (60, 124), (57, 122)),
]


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def read(path):
    data = path.read_bytes()
    hdr = LIB.unpack_from(data, 0)
    imgcnt, palcnt, oset = hdr[:3]
    imgs, pals = [], []
    for i in range(imgcnt):
        r = list(IMAGE.unpack_from(data, oset + i * IMAGE.size))
        w, h, off = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        px = np.array([list(data[off + y * stride:off + y * stride + w]) for y in range(h)], dtype=np.uint8)
        imgs.append(dict(name=r[0].split(b"\0")[0].decode(), rec=r, px=px))
    p0 = oset + imgcnt * IMAGE.size
    for i in range(palcnt - NUMDEFPAL):
        r = list(PALETTE.unpack_from(data, p0 + i * PALETTE.size))
        words = list(struct.unpack_from("<%dH" % r[3], data, r[4]))
        pals.append(dict(name=r[0].split(b"\0")[0].decode(), rec=r, words=words))
    return hdr, imgs, pals


def rgb(words):
    a = np.array(words, dtype=np.int32)
    return np.stack([(a >> 10) & 31, (a >> 5) & 31, a & 31], axis=1)


def warp_rgba(px, rgbtab, anchor, pts_t, pts_src, xs, ys):
    """the sprite as premultiplied RGBA, sampled bilinearly at TPS(pts_t -> pts_src)"""
    tps = RBFInterpolator(pts_t, pts_src, kernel="thin_plate_spline", smoothing=0.5)
    q = np.stack([xs.ravel(), ys.ravel()], axis=1).astype(float)
    s = tps(q)
    coords = [s[:, 1] + anchor[1], s[:, 0] + anchor[0]]
    alpha = (px > 0).astype(float)
    col = rgbtab[px].astype(float) * alpha[..., None]
    out = [map_coordinates(alpha, coords, order=1, cval=0.0)]
    out += [map_coordinates(col[..., c], coords, order=1, cval=0.0) for c in range(3)]
    return np.stack(out, axis=1).reshape(xs.shape + (4,))


def build(imgs, pals):
    by = {i["name"]: i for i in imgs}
    palof = {NUMDEFPAL + k: p for k, p in enumerate(pals)}
    src, dst = by[SRC], by[DST]
    rgb_s = rgb(palof[src["rec"][6]]["words"])
    rgb_d = rgb(palof[dst["rec"][6]]["words"])

    # anchor space: point - anchor
    ks = np.array([k[1] for k in KEYS], float) - ANCHOR[SRC]
    kd = np.array([k[2] for k in KEYS], float) - ANCHOR[DST]
    x0 = min(-ANCHOR[SRC][0], -ANCHOR[DST][0]) - 6
    y0 = min(-ANCHOR[SRC][1], -ANCHOR[DST][1]) - 4
    x1 = max(src["px"].shape[1] - ANCHOR[SRC][0], dst["px"].shape[1] - ANCHOR[DST][0]) + 6
    y1 = max(src["px"].shape[0] - ANCHOR[SRC][1], dst["px"].shape[0] - ANCHOR[DST][1]) + 2
    ys, xs = np.mgrid[y0:y1, x0:x1]
    # pin the canvas corners so the spline does not swing the empty margin about
    corners = np.array([[x0, y0], [x1, y0], [x0, y1], [x1, y1]], float)
    ks_all, kd_all = np.vstack([ks, corners]), np.vstack([kd, corners])

    frames = []
    for t in TS:
        pt = (1 - t) * ks_all + t * kd_all
        a = warp_rgba(src["px"], rgb_s, ANCHOR[SRC], pt, ks_all, xs, ys)
        b = warp_rgba(dst["px"], rgb_d, ANCHOR[DST], pt, kd_all, xs, ys)
        m = (1 - t) * a + t * b                             # the cross-dissolve
        mask = m[..., 0] >= 0.5
        col = np.zeros(xs.shape + (3,))
        col[mask] = m[mask, 1:] / m[mask, 0:1]              # un-premultiply
        lab, n = label(mask)                                # drop specks off the body
        sizes = np.bincount(lab.ravel())
        mask &= sizes[lab] >= 6
        frames.append((mask, col))

    # one merged palette for all three, like SHZERO_P
    allc = np.vstack([c[m] for m, c in frames]).astype(float)
    pal = kmeans_palette(allc, 63)
    words = [0] + [(int(r) << 10) | (int(g) << 5) | int(b) for r, g, b in pal]
    out = []
    for n, (mask, col) in enumerate(frames, 1):
        idx = np.zeros(mask.shape, np.uint8)
        c = col[mask].astype(float)
        d = ((c[:, None, :] - pal[None, :, :]) ** 2).sum(2)
        idx[mask] = d.argmin(1) + 1
        rows, cols = np.where(mask)
        r0, r1, c0, c1 = rows.min(), rows.max(), cols.min(), cols.max()
        crop = idx[r0:r1 + 1, c0:c1 + 1]
        ax, ay = -(x0 + c0), -(y0 + r0)
        out.append(dict(name=TWEEN % n, px=crop, ax=ax, ay=ay))
    return out, words


def kmeans_palette(c, k):
    """weighted k-means in 5-bit RGB, deterministic, colours rounded to 5 bits"""
    uniq, cnt = np.unique(c.astype(int), axis=0, return_counts=True)
    order = np.argsort(-cnt)
    cen = uniq[order[:k]].astype(float)
    if len(cen) < k:
        return np.clip(np.rint(cen), 0, 31)
    w = cnt.astype(float)
    for _ in range(40):
        d = ((uniq[:, None, :] - cen[None, :, :]) ** 2).sum(2)
        lab = d.argmin(1)
        for j in range(k):
            m = lab == j
            if m.any():
                cen[j] = (uniq[m] * w[m, None]).sum(0) / w[m].sum()
    return np.clip(np.rint(cen), 0, 31)


def seq_record(name, entries):
    """FSEQSCR (98 bytes) + FENTRY x n (18 bytes), entries in PLAY order -
    written newest-first as IMGTOOL stores them"""
    rec = bytearray(98)
    rec[0:16] = name.encode()[:15].ljust(16, b"\0")
    struct.pack_into("<HH", rec, 16, 0x40, len(entries))
    struct.pack_into("<HH", rec, 84, 0x0a, 0x0a)
    rec[88:94] = b"\xff" * 6
    for idx, ticks in reversed(entries):
        e = bytearray(18)
        struct.pack_into("<HB", e, 4, idx, ticks)
        rec += e
    return bytes(rec)


def write(path, hdr, imgs, pals, seqs):
    blob = bytearray()
    for p in pals:
        p["off"] = LIB.size + len(blob)
        blob += struct.pack("<%dH" % len(p["words"]), *p["words"])
    for i in imgs:
        i["off"] = LIB.size + len(blob)
        w = i["px"].shape[1]
        stride = (w + 3) & ~3
        for row in i["px"]:
            blob += bytes(row.tolist()) + b"\0" * (stride - w)
    oset = LIB.size + len(blob)
    h = list(hdr)
    h[0], h[1], h[2], h[4], h[5] = len(imgs), len(pals) + NUMDEFPAL, oset, len(seqs), 0
    out = bytearray(LIB.pack(*h)) + blob
    for i in imgs:
        r = list(i["rec"])
        r[0] = i["name"].encode().ljust(16, b"\0")
        r[2], r[3] = i["ax"] & 0xFFFF, i["ay"] & 0xFFFF
        r[4], r[5] = i["px"].shape[1], i["px"].shape[0]
        r[7] = i["off"]
        out += IMAGE.pack(*r)
    for p in pals:
        r = list(p["rec"])
        r[0] = p["name"].encode().ljust(10, b"\0")
        r[3], r[4] = len(p["words"]), p["off"]
        out += PALETTE.pack(*r)
    for s in seqs:
        out += s
    path.write_bytes(bytes(out))


def preview(imgs, pals, outdir, seq):
    from PIL import Image
    outdir.mkdir(parents=True, exist_ok=True)
    palof = {NUMDEFPAL + k: p["words"] for k, p in enumerate(pals)}
    S, W, H = 3, 110, 160

    def cell(i):
        im = Image.new("RGB", (W, H), (36, 36, 56))
        c = rgb(palof[i["rec"][6]]) * 255 // 31
        ox, oy = 40 - i["ax"], 4 - i["ay"]
        for y, row in enumerate(i["px"]):
            for x, v in enumerate(row):
                if v:
                    im.putpixel((ox + x, oy + y), tuple(int(k) for k in c[v]))
        return im.resize((W * S, H * S), Image.NEAREST)

    cells = [cell(imgs[k]) for k, _ in seq[:5]]
    sheet = Image.new("RGB", (W * S * len(cells), H * S))
    for n, c in enumerate(cells):
        sheet.paste(c, (n * W * S, 0))
    sheet.save(outdir / "kanomorph_sheet.png")
    frames = [cell(imgs[k]) for k, _ in seq]
    # one preview tick = 4 game ticks at 54.7 Hz (CLAUDE.md, IMGTOOL lanes)
    frames[0].save(outdir / "kanomorph.gif", save_all=True, append_images=frames[1:],
                   duration=[int(t * 4 * 18.28) for _, t in seq], loop=0)
    print("preview:", outdir / "kanomorph_sheet.png", outdir / "kanomorph.gif")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--img", type=Path, default=IMG)
    ap.add_argument("--png", type=Path, help="write a preview sheet and GIF here")
    args = ap.parse_args()

    hdr, imgs, pals = read(args.img)
    gen = {TWEEN % (n + 1) for n in range(len(TS))}
    imgs = [i for i in imgs if i["name"] not in gen]
    pals = [p for p in pals if p["name"] != TWEEN_PAL]
    names = [i["name"] for i in imgs]
    for need in (SRC, DST):
        if need not in names:
            sys.exit("%s has no %s record" % (args.img, need))
    for i in imgs:
        i["ax"], i["ay"] = ANCHOR.get(i["name"], (s16(i["rec"][2]), s16(i["rec"][3])))

    tweens, words = build(imgs, pals)
    pals.append(dict(name=TWEEN_PAL, words=words, rec=[b"", 0, 6, 64, 0, 0, 0, 0, 0, 0]))
    tpal = NUMDEFPAL + len(pals) - 1
    template = list(next(i for i in imgs if i["name"] == DST)["rec"])
    for t in tweens:
        r = list(template)
        r[6] = tpal
        t["rec"] = r
        imgs.append(t)

    ix = {i["name"]: n for n, i in enumerate(imgs)}
    t1, t2, t3 = (ix[TWEEN % n] for n in (1, 2, 3))
    play = [(ix[SRC], 5), (t1, 1), (t2, 1), (t3, 1), (ix[DST], 5), (t3, 1), (t2, 1), (t1, 1)]
    write(args.img, hdr, imgs, pals, [seq_record(SEQ_NAME, play)])
    for t in tweens:
        print("%-12s %3dx%-3d ani %d,%d  on %s" % (t["name"], t["px"].shape[1], t["px"].shape[0],
                                                  t["ax"], t["ay"], TWEEN_PAL))
    print("wrote", args.img)
    if args.png:
        preview(imgs, pals, args.png, play)


if __name__ == "__main__":
    main()
