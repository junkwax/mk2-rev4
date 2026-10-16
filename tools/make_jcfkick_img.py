#!/usr/bin/env python3
r"""Build data/JCFKICK.IMG - Johnny Cage's UNUSED MK1 FLIP KICK, VDFKICK1-4.

The move is named in `data/VANDAN.ASM` (the decompiled MK1 Cage tables) with
its frame lists commented out:

    * VDFKICK1-4 - unused FLIP-KICK frames (seated -> rotate -> inverted),
    * palette GRIMM_P
    *VDFKICK1 .long VDFKICK1A..1G,0   ; tiles @ FFEE56A0

Nothing in the MK1 ROM points at those four frame records - they were deleted -
so only the 29 IMAGE records survive.  `data/VANDAN.TBL` carries all 29 with
their width, height, anipoint and rev 5.0 SAG, and the pixels are decoded
straight out of `C:\MAME\roms\mk.zip`.  Nothing here is redrawn.

    python tools/make_jcfkick_img.py            # write data/JCFKICK.IMG
    python tools/make_jcfkick_img.py --verify   # rebuild and diff vs the ROM
    python tools/make_jcfkick_img.py --check    # fail if the file is stale

Records come out named `JCFKICK1A`..`JCFKICK4G`, matching MK2's own
`JC<MOVE><n><part>` convention, so `data/JCFKICK.LOD` can load them as strips
the way `JCAIRKIK.LOD` loads Cage's air-shadow-kick poses.

**Indices are remapped from MK1's GRIMM_P into MK2's CAGE_P** (nearest colour
in 5:5:5), so the frames wear the palette the player object is already on and
the LOD needs no palette binding (`POF>`, like JCAIRKIK/KITSPIN).  Both
palettes are 64 entries, so `PPP> 6` matches the rest of Cage - a mixed-depth
LOD is what garbled SONICCLAP.  The remap is a colour approximation of a
1992 shoot; it is meant to be repainted.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "JCFKICK.IMG"
VANDAN = ROOT / "data" / "VANDAN.TBL"
CAGE_IMG = ROOT / "data" / "CAGE5.IMG"
MK1_ZIP = Path(r"C:\MAME\roms\mk.zip")

LIB = struct.Struct("<HHIHHHHH 4s HHH")              # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")  # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")     # 26

PAL_NAME = b"CAGE_P"
PAL_BPP = 6
PALNUM = 3                      # 3-based: the first palette record

CHIP = 0x80000
IROM = 0x02000000
GRIMM_P = 0xFFE99B00            # MK1 rev 5.0, Cage's palette
T_GROUPS = [("ug14", "uj14", "ug19", "uj19"),
            ("ug16", "uj16", "ug20", "uj20"),
            ("ug17", "uj17", "ug22", "uj22")]

FRAMES = [("JCFKICK1", ["VDFKICK1" + c for c in "ABCDEFG"]),
          ("JCFKICK2", ["VDFKICK2" + c for c in "ABCDEFG"]),
          ("JCFKICK3", ["VDFKICK3" + c for c in "ABCDEFGH"]),
          ("JCFKICK4", ["VDFKICK4" + c for c in "ABCDEFG"])]

REC_RE = re.compile(
    r"^(\w+)\s*\n\s*\.word\s+(\d+),(\d+)\s*\n\s*\.word\s+(-?\d+),(-?\d+)"
    r"\s*\n\s*\.long\s+0([0-9A-Fa-f]+)h", re.M)


# --------------------------------------------------------------------- MK1
def load_mk1():
    with zipfile.ZipFile(MK1_ZIP) as z:
        ev, od = z.read("mkt-uj12.bin"), z.read("mkt-ug12.bin")
        prog = bytearray(len(ev) * 2)
        prog[0::2], prog[1::2] = ev, od
        gfx = bytearray(CHIP * 4 * len(T_GROUPS))
        for gi, grp in enumerate(T_GROUPS):
            b = gi * CHIP * 4
            for lane, nm in enumerate(grp):
                gfx[b + lane:b + CHIP * 4:4] = z.read("mkt-%s.bin" % nm)
    return bytes(prog), bytes(gfx)


def mk1_palette(prog, bit=GRIMM_P):
    off = (bit - 0xFF800000) // 8
    n = struct.unpack_from("<H", prog, off)[0]
    return [struct.unpack_from("<H", prog, off + 2 + 2 * i)[0] for i in range(n)]


def mk1_pixels(gfx, w, h, sag):
    """T-unit: 6 bits per pixel, LSB first, rows back to back, no padding"""
    b0, n = sag - IROM, w * h * 6
    if b0 < 0 or b0 + n > len(gfx) * 8:
        return None
    out = bytearray(w * h)
    for i in range(w * h):
        p = b0 + i * 6
        v = 0
        for b in range(6):
            q = p + b
            v |= ((gfx[q >> 3] >> (q & 7)) & 1) << b
        out[i] = v
    return bytes(out)


def read_vandan():
    txt = VANDAN.read_text(encoding="latin-1")
    out = {}
    for m in REC_RE.finditer(txt):
        if m.group(1).startswith("VDFKICK"):
            out[m.group(1)] = (int(m.group(2)), int(m.group(3)),
                               int(m.group(4)), int(m.group(5)),
                               int(m.group(6), 16))
    return out


# --------------------------------------------------------------------- MK2
def cage_p():
    """MK2's CAGE_P, read out of CAGE5.IMG"""
    img = CAGE_IMG.read_bytes()
    imgcnt, palcnt, oset = LIB.unpack_from(img, 0)[:3]
    pal_start = oset + imgcnt * IMAGE.size
    for i in range(palcnt):
        p = PALETTE.unpack_from(img, pal_start + i * PALETTE.size)
        if p[0].split(b"\0", 1)[0] == b"CAGE_P":
            return list(struct.unpack_from("<%dH" % p[3], img, p[4])), p[2]
    sys.exit("CAGE_P not found in CAGE5.IMG")


def remap(src, dst):
    """MK1 index -> nearest CAGE_P index.  Index 0 stays 0 (transparent)."""
    def rgb(c):
        return ((c >> 10) & 31, (c >> 5) & 31, c & 31)
    out = [0] * len(src)
    for i, c in enumerate(src):
        if i == 0:
            continue
        r, g, b = rgb(c)
        best, bi = None, 1
        for j, d in enumerate(dst):
            if j == 0:
                continue
            dr, dg, db = rgb(d)
            e = (r - dr) ** 2 + (g - dg) ** 2 + (b - db) ** 2
            if best is None or e < best:
                best, bi = e, j
        out[i] = bi
    return out


def build(fr, pal):
    blob = bytearray()
    pal_off = LIB.size
    blob += struct.pack("<%dH" % len(pal), *pal)
    offsets = []
    for _n, w, h, _ax, _ay, px in fr:
        offsets.append(LIB.size + len(blob))
        stride = (w + 3) & ~3
        for y in range(h):
            blob += bytes(px[y * w:(y + 1) * w]) + b"\0" * (stride - w)
    oset = LIB.size + len(blob)
    hdr = LIB.pack(len(fr), 1 + 3, oset, 0x0634, 0, 0, 0,
                   0xABCD, b"\xff\xff\xff\xff", 0, 0, 0)
    imgs = bytearray()
    for (name, w, h, ax, ay, _px), off in zip(fr, offsets):
        imgs += IMAGE.pack(name.encode().ljust(16, b"\0"), 0,
                           ax & 0xFFFF, ay & 0xFFFF, w, h, PALNUM,
                           off, 0, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF)
    pals = PALETTE.pack(PAL_NAME.ljust(10, b"\0"), 0, PAL_BPP, len(pal),
                        pal_off, 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(blob) + bytes(imgs) + bytes(pals)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the file on disk is not what we'd build")
    a = ap.parse_args()

    recs = read_vandan()
    want = [n for _f, names in FRAMES for n in names]
    missing = [n for n in want if n not in recs]
    if missing:
        sys.exit("data/VANDAN.TBL is missing %s" % missing)

    prog, gfx = load_mk1()
    src_pal = mk1_palette(prog)
    dst_pal, dst_bpp = cage_p()
    if dst_bpp != PAL_BPP:
        print("!! CAGE_P is %d bpp, not %d - PPP> in the LOD must match"
              % (dst_bpp, PAL_BPP))
    lut = remap(src_pal, dst_pal)

    fr = []
    for mk2name, names in FRAMES:
        for i, n in enumerate(names):
            w, h, ax, ay, sag = recs[n]
            px = mk1_pixels(gfx, w, h, sag)
            if px is None:
                sys.exit("%s failed to decode (sag %08x)" % (n, sag))
            fr.append(("%s%s" % (mk2name, "ABCDEFGH"[i]), w, h, ax, ay,
                       bytes(lut[v] for v in px)))

    data = build(fr, dst_pal)
    if a.check:
        cur = a.out.read_bytes() if a.out.exists() else b""
        if cur != data:
            sys.exit("STALE: %s does not match a fresh build - "
                     "run tools/make_jcfkick_img.py" % a.out)
        print("%s is current (%d records)" % (a.out, len(fr)))
        return 0

    a.out.write_bytes(data)
    print("wrote %s  (%d records, %d bytes)" % (a.out, len(fr), len(data)))
    print("palette: GRIMM_P(%d) -> CAGE_P(%d), %d distinct indices used"
          % (len(src_pal), len(dst_pal), len({v for _n, _w, _h, _x, _y, p in fr for v in p})))
    for name, w, h, ax, ay, px in fr:
        print("   %-10s %3dx%-3d  ani(%4d,%4d)  ink %d" %
              (name, w, h, ax, ay, sum(1 for v in px if v)))

    if a.verify:
        bad = 0
        for (name, w, h, ax, ay, px), (mk2, names) in zip(
                fr, [(f, n) for f, ns in FRAMES for n in ns]):
            pass
        # round-trip: re-read the file and compare every record
        img = a.out.read_bytes()
        imgcnt, palcnt, oset = LIB.unpack_from(img, 0)[:3]
        for i in range(imgcnt):
            r = IMAGE.unpack_from(img, oset + i * IMAGE.size)
            nm = r[0].split(b"\0")[0].decode()
            w, h, off = r[4], r[5], r[7]
            stride = (w + 3) & ~3
            got = b"".join(img[off + y * stride: off + y * stride + w] for y in range(h))
            exp = next(p for n, _w, _h, _x, _y, p in fr if n == nm)
            if got != exp:
                print("   MISMATCH %s" % nm)
                bad += 1
        print("verify: %d/%d records round-trip identical" % (imgcnt - bad, imgcnt))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
