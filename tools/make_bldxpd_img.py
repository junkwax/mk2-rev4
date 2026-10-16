#!/usr/bin/env python3
r"""Build data/BLDXPD.IMG - UMK3's exploding-body blood burst, 1:1 from the arcade ROM.

The three splats UMK3 throws when a body explodes are `blood_explode`
(MKFX.C / MK3 MKFX.ASM) walking `a_blood_explode`: BLDXPD1-13.  Ermac's
telekinetic slam fatality is one of the fatalities that fires it, and it is
what this ROM's version of that fatality now draws.  Decoded straight out of
the UMK3 graphics ROMs and written into a fresh IMG with the arcade's own
palette, so nothing is redrawn or approximated.

    python tools/make_bldxpd_img.py            # write data/BLDXPD.IMG
    python tools/make_bldxpd_img.py --verify   # rebuild and diff against the ROM
    python tools/make_bldxpd_img.py --check    # Phase D: fail if it has drifted

## Where it is - two independent routes that agree

UMK3 binds this art to each character's RAM heap at runtime (`get_char_ani(
ANIM_TABLE2, ANIM_BLOOD_EXP)` + `gmo_proc(oa8->oheap)` in the C port), so
anitab2 row 34 does NOT point at ROM records and walking it finds nothing.
The records were found by content instead:

  * **Geometry.** MK3's own MKFX2.TBL gives BLDXPD1A as `.word 28,47,28,24`.
    That exact sequence occurs ONCE in the UMK3 program ROM, at byte
    `0xAEEFA`, and the 26 records that follow match MK3's table size-for-size
    and anipoint-for-anipoint - only the SAGs are repacked.  The run ends
    cleanly at `0xAF06A`, where a different 128x58 asset begins.
  * **Palette.** The first record carries an inline palette pointer,
    `0FFDBC8D0h`, which is byte `0xB791A`.  A separate search for MK3's
    IMGPAL9.ASM `BLDXPD_P` words finds them at exactly that byte: 14 entries,
    word-for-word identical.

## 13 frames, each a LEFT and a RIGHT half - composited here

Every BLDXPDn is a two-piece multipart frame in the arcade: `nA` is anchored
at its right edge (anix = width) and `nB` at its left (anix = 0), so the two
meet at a shared anchor on the burst's vertical centreline.  MK2's blood
routines are single-object, so each pair is composited into one image by
placing both pieces at `(-anix, -aniy)` about that shared anchor and painting
A then B - B last, because the arcade's DMA queues the frame's pieces in order
and the last one queued is drawn on top.

That order matters on four frames.  BLDXPD8-11 carry anix `w-1` / `1`, not
`w` / `0`, so their halves OVERLAP by two columns rather than butting; B wins
those columns, as it does in the arcade.  The composite costs exactly the
pixels the two halves did - there is no padding between them.

The composite anchor IS the arcade's shared anchor, and it is kept.  (ERMFIRE
had to be re-anchored because Kahn's anipoints hung the star off his hand;
these hang the burst off its own centre, which is what `blood_explode` places
at `dude + a10`.)

## 4bpp, not 6

The ROM stores these at 6bpp.  Every frame tops out at colour index 13 and
the palette has 14 entries, so the art fits 4bpp with nothing lost - a third
of the video ROM the arcade's depth would cost.  The palette is padded to 16
so it is a clean 4bpp ramp; the padding sits ABOVE index 13 and moves no index
the art uses.  Index 0 is the transparent slot in both formats, so it carries
across untouched even though the arcade stores a colour (0x201F) in it.

## Format notes (both cost real time to find - see make_jdumk3_img.py)

  * IMG pixel rows are PADDED TO A MULTIPLE OF 4 BYTES.  stride = (w+3) & ~3.
  * An IMAGE record's `palnum` is 3-BASED; the header's `palcnt` is the real
    count PLUS 3.
  * The header tail is not free space - `temp` carries 0ABCDh and `bufscr` is
    all-ones in every stock IMG, or midway-imgtool refuses the file.
"""
import argparse
import importlib.util
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "BLDXPD.IMG"

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

PROG_BASE = 0xFF800000
REC0 = 0xAEEFA        # BLDXPD1A, first of 26 records (13 frames x A/B)
NFRAMES = 13
PAL_OFF = 0xB791A     # BLDXPD_P - the inline pointer after REC0 lands here
PAL_NAME = b"BLDXPD_P"
PALNUM = 3            # 3-based: the first (and only) palette record
ROM_BPP = 6           # how the arcade stores it - 5 and 4 fail to decode
OUR_BPP = 4           # how we store it - lossless, see the docstring
PAL_ENTRIES = 16      # 14 real + 2 pad, a clean 4bpp ramp

NAMES = ["BLDXPD%d" % (i + 1) for i in range(NFRAMES)]

# MK3 MKFX2.TBL geometry, (w, h) per A/B record.  Asserted against the UMK3
# records so a different romset or a wrong REC0 fails loudly instead of
# importing the wrong art.
EXPECT = [(28, 47), (35, 58), (42, 69), (48, 78), (53, 91), (60, 101),
          (67, 114), (75, 125), (82, 137), (91, 149), (102, 163),
          (114, 168), (98, 176)]


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


def records(prog):
    """The 26 image records.  Only the first carries an inline palette."""
    ptr = struct.unpack_from("<I", prog, REC0 + 14)[0]
    if (ptr - PROG_BASE) // 8 != PAL_OFF:
        sys.exit("BLDXPD1A's palette pointer 0%08xh is not BLDXPD_P at 0x%x"
                 % (ptr, PAL_OFF))
    out, o = [], REC0
    for n in range(2 * NFRAMES):
        w, h, ax, ay = struct.unpack_from("<hhhh", prog, o)
        sag = struct.unpack_from("<I", prog, o + 8)[0]
        ctrl = struct.unpack_from("<H", prog, o + 12)[0]
        if (w, h) != EXPECT[n // 2]:
            sys.exit("record %d at 0x%x is %dx%d, MK3's table says %dx%d"
                     % (n, o, w, h, *EXPECT[n // 2]))
        out.append((w, h, ax, ay, sag, ctrl))
        o += 18 if n == 0 else 14
    return out


def composite(pieces):
    """Paint the A/B halves about their shared anchor, A then B."""
    x0 = min(-ax for (w, h, ax, ay, px) in pieces)
    y0 = min(-ay for (w, h, ax, ay, px) in pieces)
    x1 = max(-ax + w for (w, h, ax, ay, px) in pieces)
    y1 = max(-ay + h for (w, h, ax, ay, px) in pieces)
    W, H = x1 - x0, y1 - y0
    buf = bytearray(W * H)
    for w, h, ax, ay, px in pieces:
        ox, oy = -ax - x0, -ay - y0
        for y in range(h):
            for x in range(w):
                v = px[y * w + x]
                if v:
                    buf[(oy + y) * W + ox + x] = v
    return W, H, -x0, -y0, bytes(buf)


def frames(g, prog, vid):
    """(name, w, h, anix, aniy, pixels) for every composited frame."""
    recs = records(prog)
    out = []
    for f, name in enumerate(NAMES):
        pieces = []
        for w, h, ax, ay, sag, ctrl in recs[2 * f:2 * f + 2]:
            px = g.pixels(vid, sag, w, h, ROM_BPP, ctrl)
            if px is None:
                sys.exit("%s piece failed to decode at %dbpp" % (name, ROM_BPP))
            pieces.append((w, h, ax, ay, px))
        W, H, ax, ay, buf = composite(pieces)
        hi = max(buf)
        if hi >= PAL_ENTRIES:
            sys.exit("%s uses index %d, which does not fit %d bpp"
                     % (name, hi, OUR_BPP))
        out.append((name, W, H, ax, ay, buf))
    return out


def palette(prog):
    n = struct.unpack_from("<H", prog, PAL_OFF)[0]
    pal = [struct.unpack_from("<H", prog, PAL_OFF + 2 + 2 * i)[0] for i in range(n)]
    while len(pal) < PAL_ENTRIES:
        pal.append(0)      # padding above the highest used index
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
            print("BLDXPD: umk3.zip not present - skipping check")
            return 0
        sys.exit("UMK3 romset not found: %s" % g.ROM_ZIP)

    vid = g.load_video(g.ROM_ZIP)
    prog = load_prog(g.ROM_ZIP)
    fr = frames(g, prog, vid)
    pal = palette(prog)
    data = build(fr, pal)

    if args.check:
        if not args.out.exists():
            print("BLDXPD: %s missing - run tools/make_bldxpd_img.py" % args.out)
            return 1
        if args.out.read_bytes() != data:
            print("BLDXPD: %s differs from a fresh build - regenerate it"
                  % args.out)
            return 1
        print("BLDXPD.IMG OK (%d frames)" % len(fr))
        return 0

    if args.verify:
        back = read_back(data)
        bad = [a[0] for a, b in zip(back, fr) if a != b]
        print("verify: %d frames, %s" % (len(fr), "IDENTICAL" if not bad
                                         else "MISMATCH " + ",".join(bad)))
        return 1 if bad else 0

    args.out.write_bytes(data)
    print("palette: %d entries (14 real + pad), %d bpp" % (len(pal), OUR_BPP))
    print("wrote %s  (%d frames, %d bytes)" % (args.out, len(fr), len(data)))
    for name, w, h, ax, ay, _px in fr:
        print("  %-9s %3dx%-3d  anchor (%d,%d)" % (name, w, h, ax, ay))
    raw = sum(w * h for _n, w, h, _a, _b, _p in fr)
    print("pixels %d -> %d bytes at %d bpp before LOAD2 compression"
          % (raw, raw * OUR_BPP // 8, OUR_BPP))
    return 0


if __name__ == "__main__":
    sys.exit(main())
