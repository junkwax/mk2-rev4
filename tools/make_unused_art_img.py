#!/usr/bin/env python3
"""Retail art that never reached the MK2 L3.1 ROM, gathered into data/UNUSED.IMG.

The retail video ROM matches the stock LOAD2 build byte-for-byte (all 12 MB),
so nothing hides in the ROM outside the libraries - what is unused is art in
the libraries that no LOD ever packed.  This collects what has been found:

  FOREST.BDD  the first Living Forest.  MK7MIL.LOD packs FOREST2 only (the
              FOREST line in BGNDTEST.LOD is commented out), so the 21 images
              FOREST.BDD carries with no pixel-identical twin in FOREST2.BDD
              never shipped - among them the mossy fallen log, a vine-wrapped
              stump and three tree faces (one screaming, one fanged).  Several
              trunks may be earlier cuts of shipped ones; they are kept so the
              set is complete.  Each keeps the BDD palette its BDB draws it in.
  SCREAM.IMG  STUMP - a trunk's root flare.  No retail LOD reads SCREAM.IMG.
  MKBGANI.IMG STUMPa/STUMPb - the same stump in two halves; MK6MIL.LOD packs
              TREEANI1-7 out of this library and leaves these out.
  MKMORPH2.IMG BLDSPLASH2-5 - the growing frames of the blood splash.  Only
              BLDSPLASH1 is packed (MK6MIL.LOD) and drawn (MKFALL.ASM).

Every source is read from the READ-ONLY tree.  The IMG records are COPIES:
the originals stay where they are, and UNUSED.IMG is in no LOD.

    python tools/make_unused_art_img.py           # write data/UNUSED.IMG
    python tools/make_unused_art_img.py --png DIR # also render every record
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RO = REPO.parent / "mk2-readonly" / "mk2-main" / "data"
OUT = REPO / "data" / "UNUSED.IMG"
sys.path.insert(0, str(REPO / "tools"))

import check_img_names as cin           # noqa: E402  (IMG library reader)
import render_bdd_background as bdd     # noqa: E402  (BDD/BDB reader)

LIB_HDR = struct.Struct("<HHIHHHHH4sHHH")
IMAGE = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")
assert (LIB_HDR.size, IMAGE.size, PALETTE.size) == (28, 50, 26)
NUMDEFPAL = 3
IMG_VERSION = 0x062E

# FOREST.BDD image index -> record name.  Names describe the picture.
FOREST_NAMES = {
    0x36: "FOLOG", 0x21: "FOVINESTUMP", 0x57: "FOSCREAMTREE", 0x12: "FOFANGTREE",
    0x24: "FOFACETREE1", 0x4b: "FOFACETREE2", 0x4e: "FOFACETREE3", 0x54: "FOTREEBASE",
    0x15: "FOFARROW", 0x27: "FOFARTREE1", 0x48: "FOFARTREE2", 0x51: "FOFARTREE3",
    0x0c: "FOTRUNK1", 0x1b: "FOTRUNK2", 0x2a: "FOTRUNK3", 0x3c: "FOTRUNK4",
    0x00: "FOGRASS1", 0x03: "FOGRASS2", 0x45: "FOGRASS3", 0x5a: "FOBUSH1", 0x5d: "FOBUSH2",
}
IMG_COPIES = {
    "SCREAM.IMG": ["STUMP"],
    "MKBGANI.IMG": ["STUMPa", "STUMPb"],
    "MKMORPH2.IMG": ["BLDSPLASH2", "BLDSPLASH3", "BLDSPLASH4", "BLDSPLASH5"],
}


def rgba_to_word(c) -> int:
    return ((c[0] >> 3) << 10) | ((c[1] >> 3) << 5) | (c[2] >> 3)


def forest_images():
    """-> [(name, w, h, ax, ay, pixels, palname, palwords)]"""
    a, apal = bdd.load_bdd(RO / "FOREST.BDD")
    b, _ = bdd.load_bdd(RO / "FOREST2.BDD")
    shipped = {v["pixels"] for v in b.values()}
    objs = bdd.load_bdb(RO / "FOREST.BDB")[3]
    unused = [k for k, v in a.items() if v["pixels"] not in shipped]
    if sorted(unused) != sorted(FOREST_NAMES):
        raise SystemExit(f"FOREST-only images changed: {sorted(map(hex, unused))}")
    out = []
    for k in sorted(unused, key=lambda k: FOREST_NAMES[k]):
        v = a[k]
        pals = {o["palette"] for o in objs if o["idx"] == k}
        if len(pals) != 1:
            raise SystemExit(f"FOREST image {k:#x} is drawn in {len(pals)} palettes")
        pname, cols = apal[pals.pop()]
        if max(v["pixels"]) >= len(cols):
            raise SystemExit(f"FOREST image {k:#x} indexes past its palette")
        out.append((FOREST_NAMES[k], v["width"], v["height"], 0, 0, bytes(v["pixels"]),
                    pname.upper(), [rgba_to_word(c) for c in cols]))
    return out


def img_copies():
    out = []
    for lib, names in IMG_COPIES.items():
        recs, _pals, data, stride = cin.read_library(RO / lib)
        imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
        # find the image table the reader settled on, then the palette table
        best = (-1, None)
        for start in (oset, oset + palcnt * cin.PALETTE.size):
            s = cin.audit._score(data, start, stride, imgcnt)
            if s > best[0]:
                best = (s, start)
        img_start = best[1]
        pal_start = img_start + imgcnt * stride if img_start == oset else oset
        for want in names:
            rec = next((r for r in recs if r["name"] == want), None)
            if rec is None:
                raise SystemExit(f"{lib}: no record {want}")
            f = IMAGE.unpack_from(data, img_start + rec["idx"] * stride)
            ax = f[2] - 0x10000 if f[2] & 0x8000 else f[2]
            ay = f[3] - 0x10000 if f[3] & 0x8000 else f[3]
            w, h, palnum, poff = f[4], f[5], f[6], f[7]
            st = (w + 3) & ~3
            px = b"".join(data[poff + y * st:poff + y * st + w] for y in range(h))
            pn, _f, _b, numc, pdata = PALETTE.unpack_from(data, pal_start + (palnum - NUMDEFPAL) * PALETTE.size)[:5]
            words = list(struct.unpack_from(f"<{numc}H", data, pdata))
            pname = pn.split(b"\0")[0].decode("ascii")
            if max(px) >= numc:
                raise SystemExit(f"{lib}:{want} indexes past {pname}")
            out.append((want, w, h, ax, ay, px, pname.upper(), words))
    return out


def build(images) -> bytes:
    pal_order, pal_words = [], {}
    for *_, pn, words in images:
        if pn in pal_words:
            if pal_words[pn] != words:
                raise SystemExit(f"two different palettes named {pn}")
        else:
            pal_order.append(pn)
            pal_words[pn] = words
    out = bytearray(LIB_HDR.size)
    pal_off = {}
    for pn in pal_order:
        pal_off[pn] = len(out)
        out += struct.pack(f"<{len(pal_words[pn])}H", *pal_words[pn])
    pix_off = []
    for _n, w, h, _ax, _ay, px, *_ in images:
        pix_off.append(len(out))
        st = (w + 3) & ~3
        for y in range(h):
            out += px[y * w:(y + 1) * w] + bytes(st - w)
    oset = len(out)
    for (name, w, h, ax, ay, _px, pn, _w), off in zip(images, pix_off):
        out += IMAGE.pack(name.encode("ascii"), 0, ax & 0xFFFF, ay & 0xFFFF, w, h,
                          pal_order.index(pn) + NUMDEFPAL, off, 0, 0, 0, 0, 0xFFFF, 0, 0xFFFF, 0xFFFF)
    for pn in pal_order:
        n = len(pal_words[pn])
        out += PALETTE.pack(pn.encode("ascii"), 0, max(1, (n - 1).bit_length()), n, pal_off[pn], 0, 0, 0, 0, 0)
    LIB_HDR.pack_into(out, 0, len(images), len(pal_order) + NUMDEFPAL, oset, IMG_VERSION,
                      0, 0, 0, 0xABCD, b"\0\0\0\0", 0, 0, 0)
    return bytes(out)


def read_back(data: bytes):
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    p0 = oset + imgcnt * IMAGE.size
    out = []
    for i in range(imgcnt):
        f = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        w, h, palnum, off = f[4], f[5], f[6], f[7]
        st = (w + 3) & ~3
        px = b"".join(data[off + y * st:off + y * st + w] for y in range(h))
        pn, _f, _b, numc, pdata = PALETTE.unpack_from(data, p0 + (palnum - NUMDEFPAL) * PALETTE.size)[:5]
        out.append((f[0].split(b"\0")[0].decode(), w, h,
                    f[2] - 0x10000 if f[2] & 0x8000 else f[2],
                    f[3] - 0x10000 if f[3] & 0x8000 else f[3], px,
                    pn.split(b"\0")[0].decode(), list(struct.unpack_from(f"<{numc}H", data, pdata))))
    return out


def write_pngs(images, outdir: Path):
    from PIL import Image
    outdir.mkdir(parents=True, exist_ok=True)
    for name, w, h, _ax, _ay, px, _pn, words in images:
        cols = [(((v >> 10) & 31) * 255 // 31, ((v >> 5) & 31) * 255 // 31, (v & 31) * 255 // 31, 255)
                for v in words]
        im = Image.new("RGBA", (w, h))
        im.putdata([(0, 0, 0, 0) if p == 0 else cols[p] for p in px])
        im.resize((w * 3, h * 3), Image.NEAREST).save(outdir / f"{name}.png")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--png", type=Path, help="also render every record (3x) into this directory")
    a = ap.parse_args()
    images = forest_images() + img_copies()
    data = build(images)
    if read_back(data) != images:
        raise SystemExit("round trip failed - UNUSED.IMG would not read back as written")
    OUT.write_bytes(data)
    print(f"wrote {OUT} ({len(data):,} bytes): {len(images)} images, "
          f"{len({i[6] for i in images})} palettes")
    for name, w, h, ax, ay, _px, pn, _w in images:
        print(f"  {name:14s} {w:4d}x{h:<4d} ani {ax:4d},{ay:<4d} {pn}")
    if a.png:
        write_pngs(images, a.png)
        print(f"rendered into {a.png}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
