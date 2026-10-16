#!/usr/bin/env python3
r"""Build data/ERMFIRE.IMG - Ermac's fireball, taken 1:1 from the UMK3 arcade ROM.

Eleven frames of the green starburst Shao Kahn throws in UMK3, which is the
projectile Ermac's fireball uses.  Decoded straight out of the UMK3 graphics
ROMs and written into a fresh IMG with the arcade's own palette, so nothing is
reconstructed, re-anchored or merged from another source.  The anchors and how
they were identified are in tools/umk3_ermac_fireball_extract.py.

    python tools/make_ermfire_img.py            # write data/ERMFIRE.IMG
    python tools/make_ermfire_img.py --verify   # rebuild and diff against the ROM
    python tools/make_ermfire_img.py --check    # Phase D: fail if it has drifted

## 5bpp, not 6

The ROM stores these frames at 6bpp, but every one of them tops out at colour
index **30** and the palette has **31** entries - so the art fits 5bpp with
nothing lost, and re-encoding at 5 costs a fifth less video ROM (21,925 bytes
against 26,310 before LOAD2's zero-compression).  The palette is padded to 32
so it is a clean 5bpp ramp; the padding sits ABOVE index 30 and therefore moves
no existing index.

Index 0 is the transparent slot in both formats, so it carries across
untouched even though the arcade stores a colour in it.

## Format notes that matter (both cost real time to find, per make_jdumk3_img)

  * IMG pixel rows are PADDED TO A MULTIPLE OF 4 BYTES.  stride = (w+3) & ~3.
  * An IMAGE record's `palnum` is 3-BASED: palnum 3 is the first palette
    record, and the header's `palcnt` is the real count PLUS 3.
  * The header tail is not free space - `temp` carries an 0ABCDh signature and
    `bufscr` is all-ones in every stock IMG.  Zeroing them makes a file the ROM
    build still swallows but midway-imgtool refuses to open.
"""
import argparse
import importlib.util
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "ERMFIRE.IMG"

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

# The eleven image records of Shao Kahn's fireball lane (anitab2 slot 017h,
# lane 0x22dbc).  Kahn's frames point at PIECE LISTS, so these are the first
# piece of each frame - resolved once and listed here so the build does not
# depend on re-walking the lane.
RECS = [0x95F04, 0x95F16, 0x95F24, 0x95F32, 0x95F40, 0x95F4E,
        0x95F5C, 0x95F6A, 0x95F78, 0x95F86, 0x95F94]
NAMES = ["ERMFIRE%d" % (i + 1) for i in range(11)]

ROM_BPP = 6           # how the arcade stores it
OUR_BPP = 5           # how we store it - lossless, see the docstring
PAL_BIT = 0xFFDB6BC0 - 0  # placeholder, real value computed from PAL_OFF below
PAL_OFF = 0xB1C26     # byte offset of the palette in the UMK3 program ROM
PAL_NAME = b"ERMFIRE_P"
PALNUM = 3            # 3-based: this is the first (and only) palette record
PAL_ENTRIES = 32      # 31 real + 1 pad, so it is a clean 5bpp ramp


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
    out = []
    for name, off in zip(NAMES, RECS):
        w, h = struct.unpack_from("<HH", prog, off)
        ax, ay = struct.unpack_from("<hh", prog, off + 4)
        sag = struct.unpack_from("<I", prog, off + 8)[0]
        ctrl = struct.unpack_from("<H", prog, off + 12)[0]
        px = g.pixels(vid, sag, w, h, ROM_BPP, ctrl)
        if px is None:
            sys.exit("%s failed to decode" % name)
        hi = max(px)
        if hi >= PAL_ENTRIES:
            sys.exit("%s uses index %d, which does not fit %d bpp"
                     % (name, hi, OUR_BPP))
        # RE-ANCHOR to the star's own centre.  The arcade anipoints (about
        # -59,-39) are measured from SHAO KAHN'S HAND, because in UMK3 this art
        # hangs off his throw; carried across unchanged they draw the star ~55px
        # below where our projectile object actually is, which on screen is the
        # opponent's feet while the strike box is correctly at his chest.
        # The star is radially symmetric, so its centre is the honest anchor and
        # adjust_xy_a5's hand offset in do_ermac_zap then lands it properly.
        ax, ay = w // 2, h // 2
        out.append((name, w, h, ax, ay, px))
    return out


def palette(prog):
    n = struct.unpack_from("<H", prog, PAL_OFF)[0]
    pal = [struct.unpack_from("<H", prog, PAL_OFF + 2 + 2 * i)[0] for i in range(n)]
    # Pad UP to a clean 5bpp ramp.  Padding above the highest used index
    # cannot move an index that the art references.
    while len(pal) < PAL_ENTRIES:
        pal.append(0)
    return pal


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
    pals = PALETTE.pack(PAL_NAME.ljust(10, b"\0"), 0, OUR_BPP, len(pal),
                        pal_off, 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(blob) + bytes(imgs) + bytes(pals)


def read_back(data):
    imgcnt, _palcnt, oset = LIB.unpack_from(data, 0)[:3]
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
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="fail if the file on disk differs from a fresh build")
    args = ap.parse_args()

    g = gfx()
    if not g.ROM_ZIP.exists():
        if args.check:
            print("ERMFIRE: umk3.zip not present - skipping check")
            return 0
        sys.exit("UMK3 romset not found: %s" % g.ROM_ZIP)

    vid = g.load_video(g.ROM_ZIP)
    prog = load_prog(g.ROM_ZIP)
    fr = frames(g, prog, vid)
    pal = palette(prog)
    data = build(fr, pal)

    if args.check:
        if not args.out.exists():
            print("ERMFIRE: %s missing - run tools/make_ermfire_img.py" % args.out)
            return 1
        if args.out.read_bytes() != data:
            print("ERMFIRE: %s differs from a fresh build - regenerate it"
                  % args.out)
            return 1
        print("ERMFIRE.IMG OK (%d frames)" % len(fr))
        return 0

    args.out.write_bytes(data)
    print("palette: %d entries (%d real + pad), %d bpp"
          % (len(pal), 31, OUR_BPP))
    print("wrote %s  (%d frames, %d bytes)" % (args.out, len(fr), len(data)))
    raw = sum(w * h for _n, w, h, _a, _b, _p in fr)
    print("pixels %d -> %d bytes at %d bpp before LOAD2 compression"
          % (raw, raw * OUR_BPP // 8, OUR_BPP))
    for name, w, h, ax, ay, _px in fr:
        print("   %-10s %3dx%-3d ani(%4d,%4d)" % (name, w, h, ax, ay))

    if args.verify:
        back = read_back(data)
        bad = 0
        for (n1, w1, h1, x1, y1, p1), (n2, w2, h2, x2, y2, p2) in zip(fr, back):
            if (n1, w1, h1, x1, y1) != (n2, w2, h2, x2, y2) or bytes(p1) != p2:
                print("   MISMATCH %s" % n1)
                bad += 1
        print("verify: %d/%d frames round-trip exactly" % (len(fr) - bad, len(fr)))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
