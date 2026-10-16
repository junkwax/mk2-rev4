#!/usr/bin/env python3
"""Decode a sprite frame out of the UMK3 arcade GRAPHICS ROMs.

The program ROM gives you an image record - `.word W,H,anix,aniy` /
`.long SAG` / `.word control` (tools/umk3_jade_extract.py finds them).  The SAG
is a **bit offset into the flat video region**, and frames are packed
continuously at the art's bit depth with no row padding and no byte alignment
([[video-rom-sag-addressing]] is the MK2 equivalent and behaves identically).

The video region is five groups of four 1 MB chips, each group 4-way
byte-interleaved, laid out per MAME's own `-listxml umk3`:

    0x0000000  u133 u132 u131 u130
    0x0400000  u129 u128 u127 u126
    0x0800000  u125 u124 u123 u122
    0x0c00000  u121 u120 u119 u118
    0x1400000  u113 u112 u111 u110      <- note the 4 MB hole at 0x1000000

Usage:
    python tools/umk3_gfx_extract.py --selftest
    python tools/umk3_gfx_extract.py --sag 0651eca2 --size 48x29 --ctrl 6580

THE ONE WE ACTUALLY WANT - the blade ghost UMK3 stamps as the boomerang's
motion trail (part 2 entry 0 of ANIM_BOOMERANG; see doc/UMK3_JADE_BOOMERANG.md):

    python tools/umk3_gfx_extract.py --sag 064fd214 --size 39x38 --ctrl 6480
        --pal ffdb5c70 --raw boomghost.bin

Its anipoint is 71,-8 - far outside its own 39x38 box, because the same frame
is also the blade hanging off Jade's hand during the throw (ani_sladd).

NOTE ON THE SELF-TEST: it will not reach 100%, and should not be expected to.
Our data/JADERANG.IMG is a re-indexed rip, not a bit copy - BRTRAIL4 decodes
here as UMK3 indexes {8,9,10} where our IMG carries only {7,13}, i.e. one shade
was merged on the way in. The bar is "renders as coherent art", not "identical".
"""
import argparse
import struct
import sys
import zipfile
from pathlib import Path

ROM_ZIP = Path(r"C:\MAME\roms\umk3.zip")
PROG_BASE = 0xFF800000

# (region offset, [chip names in byte-lane order 0,1,2,3])
GROUPS = [
    (0x0000000, ["l1_mortal_kombat_3_u133_game_rom.u133",
                 "l1_mortal_kombat_3_u132_game_rom.u132",
                 "l1_mortal_kombat_3_u131_game_rom.u131",
                 "l1_mortal_kombat_3_u130_game_rom.u130"]),
    (0x0400000, ["l1_mortal_kombat_3_u129_game_rom.u129",
                 "l1_mortal_kombat_3_u128_game_rom.u128",
                 "l1_mortal_kombat_3_u127_game_rom.u127",
                 "l1_mortal_kombat_3_u126_game_rom.u126"]),
    (0x0800000, ["l1_mortal_kombat_3_u125_game_rom.u125",
                 "l1_mortal_kombat_3_u124_game_rom.u124",
                 "l1_mortal_kombat_3_u123_game_rom.u123",
                 "l1_mortal_kombat_3_u122_game_rom.u122"]),
    (0x0c00000, ["umk-u121.bin", "umk-u120.bin",
                 "umk-u119.bin", "umk-u118.bin"]),
    (0x1400000, ["umk-u113.bin", "umk-u112.bin",
                 "umk-u111.bin", "umk-u110.bin"]),
]
VIDEO_SIZE = 0x1800000

# Frames we already carry in data/JADERANG.IMG, used to prove the decoder.
# (name, UMK3 sag, W, H)
KNOWN = [
    ("BRTRAIL4", 0x06526C00,  9, 29, 0x6000),   # uncompressed - the calibrator
    ("BRTRAIL1", 0x0652521E, 24, 36, 0x6580),
    ("BRANG4",   0x0651ECA2, 48, 29, 0x6580),
    ("BRANG7",   0x06521258, 50, 18, 0x6280),
]


def load_video(zip_path):
    vid = bytearray(b"\xff" * VIDEO_SIZE)
    with zipfile.ZipFile(zip_path) as z:
        have = set(z.namelist())
        for base, chips in GROUPS:
            for lane, chip in enumerate(chips):
                if chip not in have:
                    sys.exit("missing graphics chip in %s: %s" % (zip_path, chip))
                data = z.read(chip)
                vid[base + lane: base + lane + 4 * len(data): 4] = data
    return bytes(vid)


def _rd(vid, bit, bpp):
    byte = bit >> 3
    if byte + 4 > len(vid):
        return None
    # LSB-first within the stream, the order the DMA reads it
    return (int.from_bytes(vid[byte:byte + 4], "little") >> (bit & 7)) & ((1 << bpp) - 1)


def pixels(vid, sag, w, h, bpp, ctrl=0):
    """Unpack a frame starting at bit offset `sag`.

    `ctrl` bit 7 (`dmacmp`, SYSEQU.ASM) selects ZERO COMPRESSION.  Compressed
    rows are one 8-bit header - low nibble = leading transparent pixels, high
    nibble = trailing - followed only by the pixels in between.  Each nibble is
    scaled by a shift taken from the control word.  This is exactly what
    MKDISP.ASM's `shad7` walks:

        lead  = (hdr & 0x0f) << ((ctrl >> 8)  & 3)
        trail = (hdr >> 4)   << ((ctrl >> 10) & 3)
        stored pixels this row = w - lead - trail

    An uncompressed frame (bit 7 clear, e.g. control 06000h) is simply
    w*h*bpp bits flat.
    """
    out = bytearray(w * h)
    bit = sag
    if not (ctrl & 0x0080):
        for i in range(w * h):
            v = _rd(vid, bit, bpp)
            if v is None:
                return None
            out[i] = v
            bit += bpp
        return out
    lead_sh, trail_sh = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    for y in range(h):
        hdr = _rd(vid, bit, 8)
        if hdr is None:
            return None
        bit += 8
        lead = (hdr & 0x0F) << lead_sh
        trail = (hdr >> 4) << trail_sh
        n = w - lead - trail
        if n < 0 or lead > w:
            return None
        for x in range(n):
            v = _rd(vid, bit, bpp)
            if v is None:
                return None
            out[y * w + lead + x] = v
            bit += bpp
    return out


def render(px, w, h, step=1):
    ramp = " .:-=+*#%@"
    lines = []
    for y in range(0, h, step):
        row = []
        for x in range(w):
            v = px[y * w + x]
            row.append("." if v == 0 else ramp[min(9, 1 + v * 9 // 63)])
        lines.append("   " + "".join(row))
    return "\n".join(lines)


def img_frame(name):
    """Pull the same frame out of our own data/JADERANG.IMG for comparison."""
    p = Path(__file__).resolve().parent.parent / "data" / "JADERANG.IMG"
    if not p.exists():
        return None
    data = p.read_bytes()
    LIB = struct.Struct("<HHIHHHHH 4s HHH")
    IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
    imgcnt, palcnt, oset = LIB.unpack_from(data, 0)[:3]
    for i in range(imgcnt):
        o = oset + i * IMAGE.size
        rec = IMAGE.unpack_from(data, o)
        nm = rec[0].split(b"\0")[0].decode("latin-1")
        if nm != name:
            continue
        w, h, off = rec[4], rec[5], rec[7]
        # IMG rows are PADDED TO A MULTIPLE OF 4 BYTES.  Reading them at
        # stride w shears every frame whose width is not already a multiple
        # of 4 - which is most of them - and makes a correct decode look
        # like a mismatch.  Derived from the record spacing: 66->68, 18->20,
        # 29->32, 9->12, and so on for all 34 records.
        stride = (w + 3) & ~3
        rows = [data[off + y * stride: off + y * stride + w] for y in range(h)]
        return w, h, b"".join(rows)
    return None


def selftest(vid, bpp):
    print("Decoder self-test: UMK3 graphics ROM vs our own data/JADERANG.IMG")
    print("(our art was ripped from this ROM, so the pixels must agree)\n")
    ok_all = True
    for name, sag, w, h, ctrl in KNOWN:
        rom_px = pixels(vid, sag, w, h, bpp, ctrl)
        ours = img_frame(name)
        if rom_px is None:
            print("  %-9s sag 0%08xh: out of range" % (name, sag))
            ok_all = False
            continue
        if ours is None:
            print("  %-9s not in our IMG - skipped" % name)
            continue
        ow, oh, opx = ours
        if (ow, oh) != (w, h):
            print("  %-9s size mismatch: ROM %dx%d vs IMG %dx%d" % (name, w, h, ow, oh))
            ok_all = False
            continue
        same = sum(1 for a, b in zip(rom_px, opx) if a == b)
        pct = 100.0 * same / (w * h)
        flag = "MATCH" if pct == 100.0 else ("close" if pct > 90 else "MISMATCH")
        print("  %-9s %2dx%-2d  %6.2f%% identical  %s" % (name, w, h, pct, flag))
        if pct != 100.0:
            ok_all = False
    return ok_all


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--bpp", type=int, default=6)
    ap.add_argument("--sag", help="hex bit offset from the image record")
    ap.add_argument("--size", help="WxH")
    ap.add_argument("--ctrl", default="0", help="hex control word (bit 7 = compressed)")
    ap.add_argument("--pal", help="hex bit address of the palette, to dump it")
    ap.add_argument("--raw", type=Path, help="write raw 8bpp W*H bytes here")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if not args.zip.exists():
        sys.exit("UMK3 romset not found: %s" % args.zip)
    vid = load_video(args.zip)
    print("video region assembled: %d bytes\n" % len(vid))

    if args.selftest:
        return 0 if selftest(vid, args.bpp) else 1

    if not (args.sag and args.size):
        ap.error("--sag and --size are required unless --selftest")
    sag = int(args.sag, 16)
    w, h = (int(v) for v in args.size.lower().split("x"))
    px = pixels(vid, sag, w, h, args.bpp, int(args.ctrl, 16))
    if px is None:
        sys.exit("sag 0%08xh runs off the end of the video region" % sag)
    used = sorted(set(px))
    print("frame %dx%d at sag 0%08xh, %d bpp" % (w, h, sag, args.bpp))
    print("colour indexes used: %s\n" % used)
    print(render(px, w, h, step=2))
    if args.pal:
        prog = None
        with zipfile.ZipFile(args.zip) as z:
            even = z.read("l1.2_mortal_kombat_3_u54_ultimate.u54")
            odd = z.read("l1.2_mortal_kombat_3_u63_ultimate.u63")
        prog = bytearray(len(even) * 2)
        prog[0::2] = even
        prog[1::2] = odd
        o = (int(args.pal, 16) - PROG_BASE) // 8
        n = struct.unpack_from("<H", prog, o)[0]
        cols = [struct.unpack_from("<H", prog, o + 2 + 2 * i)[0] for i in range(n)]
        print("\npalette at 0%s: %d entries" % (args.pal, n))
        for i in range(0, n, 8):
            print("   " + " ".join("%04X" % c for c in cols[i:i + 8]))
    if args.raw:
        args.raw.write_bytes(bytes(px))
        print("\nwrote %s (%d bytes, 8bpp %dx%d)" % (args.raw, len(px), w, h))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
