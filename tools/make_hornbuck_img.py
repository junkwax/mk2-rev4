#!/usr/bin/env python3
r"""Build data/HORNBUCK.IMG - Sektor's flame fatality, taken 1:1 from the arcade.

Forty-five frames: the flamethrower jet, the victim burning down to a
skeleton, and the skeleton's collapse.  Every one of them is decoded straight
out of the UMK3 graphics ROMs and written into a fresh IMG carrying the
arcade's own palette, so nothing here is redrawn, re-anchored or merged.

    ROBOFIRE1..ROBOFIRE7    the flame jet leaving Sektor's chest, widening
    SKELFIRE1..SKELFIRE6    the fireball swallowing the victim (one part each)
    SKELFIRE7..SKELFIRE15   the burn - two parts, A is the near half, B the far
    SKELFIRE16..SKELFIRE18   the standing skeleton once the flesh is gone
    SKELFIRE19..SKELFIRE24  the collapse
    SBFIRE1, SBFIRE2        the two-frame burn used for the sub-boss victims
                            (`sb_skeleton_burn`, the lane Sheeva/Motaro take)

    python tools/make_hornbuck_img.py            # write data/HORNBUCK.IMG
    python tools/make_hornbuck_img.py --verify   # rebuild and diff the round-trip
    python tools/make_hornbuck_img.py --dump SKELFIRE16A   # look at a frame
    python tools/make_hornbuck_img.py --check    # Phase D: fail if it drifted

## Where the numbers come from

MK3's leaked source has the TABLE but not the art: mk3-rebuild REV21's
MKFATAL.TBL carries all 45 records (`.word W,H,anix,aniy` / `.long SAG` /
`.word control`), MKFATAL.ASM walks them in `robo_skeleton_burn` /
`skel_fire_proc`, and IMGPAL8.ASM carries the palette - but the IMG that
packed the pixels is not in the leak and MK3's own graphics ROMs are not on
this machine.

UMK3's are.  Sektor's fatality survived into UMK3 unchanged, so the same 45
records sit in UMK3's program ROM at byte 0x0A8292, contiguous, in MK3's
table order.  All 45 agree with the leaked source on W, H, anipoint AND
control word - only the SAGs are relocated, which is what makes it safe to
say these are MK3's frames and not a UMK3 redraw.  GEOMETRY below is the
leaked table verbatim and the build asserts against it.

The palette pointer in the first record (0FFDCC1D0h) resolves to a 32-entry
palette that is word-for-word IMGPAL8.ASM's SKELFIR_P.

## Format notes that matter (all three cost real time to find)

  * IMG pixel rows are PADDED TO A MULTIPLE OF 4 BYTES.  stride = (w+3) & ~3.
  * An IMAGE record's `palnum` is 3-BASED: palnum 3 is the first palette
    record, and the header's `palcnt` is the real count PLUS 3.
  * The header tail is not free space - `temp` carries an 0ABCDh signature
    and `bufscr` is all-ones in every stock IMG.  Zeroing them makes a file
    the ROM build still swallows but midway-imgtool refuses to open.

## 5bpp

The palette has 32 entries, so the set is 5bpp.  The arcade agrees for 42 of
the 45 frames; SKELFIRE16A, 17A and 18A it stores at 4bpp (control 04x80h)
because those three top out at index 15.  Indices are not remapped either
way - a 4bpp frame's index n is entry n of the same SKELFIR_P - so writing
the whole set at 5 is lossless and costs those three frames a fifth more
video ROM than the arcade spent.  Index 0 is the transparent slot in both
formats, so the colour the arcade stores there carries across unused.
"""
import argparse
import importlib.util
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "HORNBUCK.IMG"

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

PROG_BASE = 0xFF800000      # TMS34010 bit address of program ROM byte 0
BLOCK = 0x0A8292            # first record (SBFIRE1) in the UMK3 program ROM
OUR_BPP = 5
PAL_NAME = b"SKELFIR_P"
PALNUM = 3                  # 3-based: the first (and only) palette record
PAL_ENTRIES = 32

# Name, then the leaked MK3 geometry (W, H, anix, aniy) and control word from
# mk3-rebuild-main/REV21/MKFATAL.TBL.  The build fails if the ROM disagrees.
GEOMETRY = [
    ("SBFIRE1",      40,  54,   33,  -25, 0x5180),
    ("SBFIRE2",      53,  77,   41,  -15, 0x5580),
    ("ROBOFIRE1",    38,  11,  -51,  -41, 0x5280),
    ("ROBOFIRE7",   117,  77, -134,   -3, 0x5780),
    ("SKELFIRE1A",   88, 109,   44,   -6, 0x5980),
    ("SKELFIRE2A",   96, 127,   40,   -2, 0x5A80),
    ("SKELFIRE3A",  116, 149,   46,    5, 0x5A80),
    ("SKELFIRE4A",  130, 157,   52,    6, 0x5A80),
    ("SKELFIRE5A",  137, 161,   54,    9, 0x5B80),
    ("SKELFIRE6A",  146, 169,   55,   15, 0x5E80),
    ("SKELFIRE7A",   35, 178,   38,   34, 0x5580),
    ("SKELFIRE7B",   46, 178,    3,   34, 0x5480),
    ("SKELFIRE8A",   34, 177,   38,   33, 0x5580),
    ("SKELFIRE8B",   51, 177,    4,   33, 0x5A80),
    ("SKELFIRE9A",   35, 167,   38,   23, 0x5580),
    ("SKELFIRE9B",   54, 170,    3,   26, 0x5880),
    ("SKELFIRE10A",  33, 172,   38,   28, 0x5580),
    ("SKELFIRE10B",  59, 175,    5,   31, 0x5880),
    ("SKELFIRE11A",  38, 163,   38,   19, 0x5580),
    ("SKELFIRE11B",  55, 176,    0,   32, 0x5880),
    ("SKELFIRE12A",  36, 168,   38,   24, 0x5580),
    ("SKELFIRE12B",  57, 178,    2,   34, 0x5880),
    ("SKELFIRE13A",  36, 176,   38,   32, 0x5580),
    ("SKELFIRE13B",  56, 174,    2,   30, 0x5880),
    ("SKELFIRE14A",  35, 162,   38,   18, 0x5580),
    ("SKELFIRE14B",  51, 167,    3,   23, 0x5980),
    ("SKELFIRE15A",  36, 170,   38,   26, 0x5680),
    ("SKELFIRE15B",  50, 169,    2,   25, 0x5A80),
    ("SKELFIRE16A",  35, 113,   38,  -31, 0x4580),
    ("SKELFIRE16B",  44, 131,    3,  -13, 0x5480),
    ("SKELFIRE17A",  36, 104,   38,  -40, 0x4580),
    ("SKELFIRE17B",  43, 121,    2,  -22, 0x5480),
    ("SKELFIRE18A",  34,  75,   37,  -69, 0x4180),
    ("SKELFIRE18B",  45,  92,    3,  -51, 0x5880),
    ("SKELFIRE19A",  81,  68,   39,  -82, 0x5A80),
    ("SKELFIRE20A",  95,  57,   41,  -99, 0x5A80),
    ("SKELFIRE21A", 121,  49,   50, -111, 0x5A80),
    ("SKELFIRE22A", 133,  53,   54, -109, 0x5B80),
    ("SKELFIRE23A", 133,  57,   51, -109, 0x5E80),
    ("SKELFIRE24A", 130,  55,   48, -111, 0x5E80),
    ("ROBOFIRE2",    55,  14,  -51,  -38, 0x5280),
    ("ROBOFIRE3",    80,  18,  -51,  -35, 0x5680),
    ("ROBOFIRE4",   109,  21,  -51,  -32, 0x5380),
    ("ROBOFIRE5",   173,  28,  -51,  -25, 0x5780),
    ("ROBOFIRE6",   153,  54,  -81,  -14, 0x5380),
]

# IMGPAL8.ASM SKELFIR_P, kept here so a bad palette read cannot pass silently.
SKELFIR_P = (
    0x28C7, 0x4DC9, 0x45A8, 0x4166, 0x3925, 0x3504, 0x2CC2, 0x2481,
    0x2060, 0x1400, 0x1000, 0x2800, 0x3400, 0x3C00, 0x4400, 0x4C00,
    0x5400, 0x5800, 0x6000, 0x6800, 0x7000, 0x7D00, 0x7D40, 0x7D80,
    0x7E00, 0x7E40, 0x7EA0, 0x7F00, 0x7FC0, 0x7FCF, 0x7FD4, 0x7FFF,
)


def gfx():
    spec = importlib.util.spec_from_file_location("g", HERE / "umk3_gfx_extract.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_prog(zf):
    import zipfile
    with zipfile.ZipFile(zf) as z:
        even = z.read("l1.2_mortal_kombat_3_u54_ultimate.u54")
        odd = z.read("l1.2_mortal_kombat_3_u63_ultimate.u63")
    flat = bytearray(len(even) * 2)
    flat[0::2] = even
    flat[1::2] = odd
    return bytes(flat)


def records(prog):
    """Walk the 45 image records, asserting each against the leaked table.

    The records are NOT a fixed-stride array: one carrying a trailing palette
    pointer is 18 bytes, one without is 14.  A pointer is recognisable because
    it lands in the program ROM (0FFxxxxxxh) where a following record's W never
    can.  Five of these records carry one - the four that open the group and
    SKELFIRE1A - and they all name the same palette.
    """
    off = BLOCK
    out, pal_ptr = [], None
    for name, w, h, ax, ay, ctrl in GEOMETRY:
        rw, rh = struct.unpack_from("<HH", prog, off)
        rax, ray = struct.unpack_from("<hh", prog, off + 4)
        sag = struct.unpack_from("<I", prog, off + 8)[0]
        rctrl = struct.unpack_from("<H", prog, off + 12)[0]
        if (rw, rh, rax, ray, rctrl) != (w, h, ax, ay, ctrl):
            sys.exit("%s: ROM record at 0x%06X reads %dx%d ani(%d,%d) ctrl %04X, "
                     "the leaked table says %dx%d ani(%d,%d) ctrl %04X"
                     % (name, off, rw, rh, rax, ray, rctrl, w, h, ax, ay, ctrl))
        nxt = struct.unpack_from("<I", prog, off + 14)[0]
        if (nxt & 0xFF000000) == 0xFF000000:
            if pal_ptr is not None and nxt != pal_ptr:
                sys.exit("%s names palette %08X, the group opened with %08X"
                         % (name, nxt, pal_ptr))
            pal_ptr = nxt
            off += 18
        else:
            off += 14
        out.append((name, w, h, ax, ay, sag, ctrl))
    if pal_ptr is None:
        sys.exit("no palette pointer in the block - wrong anchor?")
    return out, pal_ptr


def palette(prog, pal_ptr):
    off = (pal_ptr - PROG_BASE) // 8
    n = struct.unpack_from("<H", prog, off)[0]
    pal = [struct.unpack_from("<H", prog, off + 2 + 2 * i)[0] for i in range(n)]
    if tuple(pal) != SKELFIR_P:
        sys.exit("palette at %08X (byte 0x%05X) is not IMGPAL8.ASM's SKELFIR_P"
                 % (pal_ptr, off))
    if len(pal) != PAL_ENTRIES:
        sys.exit("expected %d palette entries, got %d" % (PAL_ENTRIES, len(pal)))
    return pal


def frames(g, vid, recs):
    """(name, w, h, anix, aniy, pixels) for every frame, straight from the ROM"""
    out = []
    for name, w, h, ax, ay, sag, ctrl in recs:
        bpp = (ctrl >> 12) & 7          # dmabpp, SYSEQU.ASM bits 12-14
        px = g.pixels(vid, sag, w, h, bpp, ctrl)
        if px is None:
            sys.exit("%s failed to decode at sag 0%08Xh" % (name, sag))
        hi = max(px)
        if hi >= PAL_ENTRIES:
            sys.exit("%s uses index %d, which does not fit %d bpp"
                     % (name, hi, OUR_BPP))
        out.append((name, w, h, ax, ay, bytes(px)))
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
            blob += px[y * w:(y + 1) * w] + b"\0" * (stride - w)

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


def dump(fr, want):
    ramp = " .:-=+*#%@"
    for name, w, h, ax, ay, px in fr:
        if want and name != want:
            continue
        print("--- %s %dx%d ani(%d,%d)" % (name, w, h, ax, ay))
        step = 1 + h // 60
        for y in range(0, h, step):
            row = px[y * w:(y + 1) * w]
            print("  " + "".join(" " if v == 0 else ramp[min(9, 1 + v * 9 // 31)]
                                 for v in row))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="fail if the file on disk differs from a fresh build")
    ap.add_argument("--dump", metavar="NAME", nargs="?", const="",
                    help="render frames as text instead of writing the IMG")
    args = ap.parse_args()

    g = gfx()
    if not g.ROM_ZIP.exists():
        if args.check:
            print("HORNBUCK: umk3.zip not present - skipping check")
            return 0
        sys.exit("UMK3 romset not found: %s" % g.ROM_ZIP)

    prog = load_prog(g.ROM_ZIP)
    recs, pal_ptr = records(prog)
    pal = palette(prog, pal_ptr)
    vid = g.load_video(g.ROM_ZIP)
    fr = frames(g, vid, recs)

    if args.dump is not None:
        dump(fr, args.dump)
        return 0

    data = build(fr, pal)

    if args.check:
        if not args.out.exists():
            print("HORNBUCK: %s missing - run tools/make_hornbuck_img.py" % args.out)
            return 1
        if args.out.read_bytes() != data:
            print("HORNBUCK: %s differs from a fresh build - regenerate it"
                  % args.out)
            return 1
        print("HORNBUCK.IMG OK (%d frames)" % len(fr))
        return 0

    args.out.write_bytes(data)
    print("palette: %s, %d entries, %d bpp (from %08Xh)"
          % (PAL_NAME.decode(), len(pal), OUR_BPP, pal_ptr))
    print("wrote %s  (%d frames, %d bytes)" % (args.out, len(fr), len(data)))
    raw = sum(w * h for _n, w, h, _a, _b, _p in fr)
    print("pixels %d -> %d bytes at %d bpp before LOAD2 compression"
          % (raw, raw * OUR_BPP // 8, OUR_BPP))
    for (name, w, h, ax, ay, px), rec in zip(fr, recs):
        lit = sum(1 for v in px if v)
        print("   %-12s %3dx%-3d ani(%4d,%4d)  %5.1f%% lit  rom %dbpp"
              % (name, w, h, ax, ay, 100.0 * lit / (w * h), (rec[6] >> 12) & 7))

    if args.verify:
        back = read_back(data)
        bad = 0
        for (n1, w1, h1, x1, y1, p1), (n2, w2, h2, x2, y2, p2) in zip(fr, back):
            if (n1, w1, h1, x1, y1) != (n2, w2, h2, x2, y2) or p1 != p2:
                print("   MISMATCH %s" % n1)
                bad += 1
        print("verify: %d/%d frames round-trip exactly" % (len(fr) - bad, len(fr)))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
