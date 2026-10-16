#!/usr/bin/env python3
"""Build data/JDUMK3.IMG - Jade's boomerang art taken 1:1 from the UMK3 arcade ROM.

Nineteen frames, decoded straight out of the UMK3 graphics ROMs and written
into a fresh IMG with the arcade's own palette, so nothing here is
reconstructed, re-anchored or merged from another source:

    UBWISP              the boomerang materialising (part 2 entry 0 of
                        ANIM_BOOMERANG, and the throw lane's first slave frame)
    UBREL1..UBREL4      the release path
    UBSPIN1..UBSPIN8    the spin (the lane uses 1-6; 7 and 8 are unused in the
                        arcade too, and are carried for completeness)
    UBTRAIL1..UBTRAIL6  the motion echoes (also unused by the arcade lane)

Every record keeps the ARCADE's own W/H and anipoint.  Indices keep the
ARCADE's palette order and the file carries that palette, so no remapping
happens anywhere - see PALETTE below.

    python tools/make_jdumk3_img.py            # write data/JDUMK3.IMG
    python tools/make_jdumk3_img.py --verify   # rebuild and diff against the ROM

Format notes that matter (both cost real time to find):
  * IMG pixel rows are PADDED TO A MULTIPLE OF 4 BYTES.  stride = (w+3) & ~3.
  * An IMAGE record's `palnum` is 3-BASED: palnum 3 is the first palette
    record, and the header's `palcnt` is the real count PLUS 3.
"""
import argparse
import importlib.util
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "JDUMK3.IMG"

LIB = struct.Struct("<HHIHHHHH 4s HHH")          # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

# Jade's boomerang image records in the UMK3 program ROM.  The 18 in the main
# block are consecutive from 0x097f4e; the wisp sits just above them.
IMG_BLOCK = 0x097F4E
WISP = 0x097E6A
NAMES = ["UBREL1", "UBREL2", "UBREL3", "UBREL4",
         "UBSPIN1", "UBSPIN2", "UBSPIN3", "UBSPIN4",
         "UBSPIN5", "UBSPIN6", "UBSPIN7", "UBSPIN8",
         "UBTRAIL1", "UBTRAIL2", "UBTRAIL3", "UBTRAIL4",
         "UBTRAIL5", "UBTRAIL6"]

# The arcade's own boomerang palette (program ROM 0FFDB5C70h), in ITS order.
PAL_NAME = b"UBOOM_P"
PAL_BPP = 4
PALNUM = 3            # 3-based: this is the first (and only) palette record


def load_prog(zf):
    import zipfile
    with zipfile.ZipFile(zf) as z:
        even = z.read("l1.2_mortal_kombat_3_u54_ultimate.u54")
        odd = z.read("l1.2_mortal_kombat_3_u63_ultimate.u63")
    flat = bytearray(len(even) * 2)
    flat[0::2] = even
    flat[1::2] = odd
    return bytes(flat)


def gfx():
    spec = importlib.util.spec_from_file_location("g", HERE / "umk3_gfx_extract.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def frames(g, prog, vid):
    """(name, w, h, anix, aniy, pixels) for every frame, straight from the ROM"""
    def rec(off):
        w, h = struct.unpack_from("<HH", prog, off)
        ax, ay = struct.unpack_from("<hh", prog, off + 4)
        sag = struct.unpack_from("<I", prog, off + 8)[0]
        ctrl = struct.unpack_from("<H", prog, off + 12)[0]
        return w, h, ax, ay, sag, ctrl

    out = []
    w, h, ax, ay, sag, ctrl = rec(WISP)
    px = g.pixels(vid, sag, w, h, 6, ctrl)
    if px is None:
        sys.exit("UBWISP failed to decode")
    out.append(("UBWISP", w, h, ax, ay, px))
    for i, name in enumerate(NAMES):
        w, h, ax, ay, sag, ctrl = rec(IMG_BLOCK + 14 * i)
        px = g.pixels(vid, sag, w, h, 6, ctrl)
        if px is None:
            sys.exit("%s failed to decode" % name)
        out.append((name, w, h, ax, ay, px))
    return out


def palette(prog, bit=0xFFDB5C70):
    off = (bit - 0xFF800000) // 8
    n = struct.unpack_from("<H", prog, off)[0]
    return [struct.unpack_from("<H", prog, off + 2 + 2 * i)[0] for i in range(n)]


def build(fr, pal):
    blob = bytearray()
    # palette colours first, then the pixel blocks; both are referenced by
    # absolute file offset, so the header has to be accounted for up front.
    pal_off = LIB.size
    blob += struct.pack("<%dH" % len(pal), *pal)
    offsets = []
    for _n, w, h, _ax, _ay, px in fr:
        offsets.append(LIB.size + len(blob))
        stride = (w + 3) & ~3
        for y in range(h):
            row = bytes(px[y * w:(y + 1) * w])
            blob += row + b"\0" * (stride - w)

    oset = LIB.size + len(blob)
    # The header tail is NOT free space.  `temp` carries an 0ABCDh signature
    # and `bufscr` is all-ones in every stock IMG.  Zeroing them produces a
    # file the ROM build still swallows but midway-imgtool refuses to open,
    # which is a nasty way to find out.  Values copied from JADERANG.IMG.
    hdr = LIB.pack(len(fr), len(pal) and 1 + 3, oset, 0x0634, 0, 0, 0,
                   0xABCD, b"\xff\xff\xff\xff", 0, 0, 0)
    imgs = bytearray()
    for (name, w, h, ax, ay, _px), off in zip(fr, offsets):
        # ptbl/opals are 0FFFFh meaning "none", not 0 - same reason.
        imgs += IMAGE.pack(name.encode().ljust(16, b"\0"), 0,
                           ax & 0xFFFF, ay & 0xFFFF, w, h, PALNUM,
                           off, 0, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF)
    pals = PALETTE.pack(PAL_NAME.ljust(10, b"\0"), 0, PAL_BPP, len(pal),
                        pal_off, 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(blob) + bytes(imgs) + bytes(pals)


def read_back(data):
    imgcnt, palcnt, oset = LIB.unpack_from(data, 0)[:3]
    out = []
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        name = r[0].split(b"\0")[0].decode()
        ax = r[2] - 0x10000 if r[2] & 0x8000 else r[2]
        ay = r[3] - 0x10000 if r[3] & 0x8000 else r[3]
        w, h, off = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        px = b"".join(data[off + y * stride: off + y * stride + w] for y in range(h))
        out.append((name, w, h, ax, ay, px))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    g = gfx()
    vid = g.load_video(g.ROM_ZIP)
    prog = load_prog(g.ROM_ZIP)
    fr = frames(g, prog, vid)
    pal = palette(prog)
    print("palette: %d entries, arcade order, first 6 = %s"
          % (len(pal), " ".join("%04X" % c for c in pal[:6])))

    data = build(fr, pal)
    args.out.write_bytes(data)
    print("wrote %s  (%d frames, %d bytes)" % (args.out, len(fr), len(data)))
    for name, w, h, ax, ay, px in fr:
        print("   %-9s %3dx%-3d @%4d,%-4d  ink %d" %
              (name, w, h, ax, ay, sum(1 for v in px if v)))

    if args.verify:
        back = read_back(args.out.read_bytes())
        bad = 0
        for (n1, w1, h1, x1, y1, p1), (n2, w2, h2, x2, y2, p2) in zip(fr, back):
            if (n1, w1, h1, x1, y1) != (n2, w2, h2, x2, y2) or p1 != p2:
                print("   MISMATCH %s" % n1)
                bad += 1
        print("\nverify: %d/%d frames round-trip identical to the ROM decode"
              % (len(fr) - bad, len(fr)))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
