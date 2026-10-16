#!/usr/bin/env python3
"""Build data/RBLOOD.IMG - the blood lane from UMK3 Sektor's CRUSH fatality.

The move is `fat_robo_crush` (UMK3 PS1 source, MKFATAL.C): Sektor's chest opens,
two clamp arms come out, close on the victim, and the body bursts.  The burst is
its own animation - `ANIM_ROBO_CRUSH_BLOOD` (0x10 in the robots' ANIM_TABLE2,
MKGUYS.H) - a 19-row MULTIPART lane of 71 pieces, `a_crush_blood` in MK3's
MKROBO.ASM.  This tool pulls those 71 pieces out of the arcade ROM and writes
them into a fresh IMG with the arcade's own anipoints, palette and timing.

    python tools/make_rbblood_img.py              # write data/RBLOOD.IMG
    python tools/make_rbblood_img.py --verify     # rebuild, then read it back
    python tools/make_rbblood_img.py --lane       # print the lane, MK2 TBL shape
    python tools/make_rbblood_img.py --dump 5     # ASCII-render row 5's pieces

Nothing here is redrawn, re-anchored or re-indexed:

  * The 71 image records sit consecutively in the UMK3 program ROM from
    0x088FAA.  Every W/H/anipoint is checked against MK3's own MKROBO.TBL
    before anything is decoded, so a wrong anchor fails loudly instead of
    writing garbage (the two games carry identical values for this art).
  * The FIRST record is 18 bytes, not 14 - it ends `.long RBLOOD_P`, the
    palette the whole lane shares.  The other 70 are 14.  The builder follows
    that as it walks, and reads the palette from the pointer it finds there
    (0FFD85E00h: 29 colours, the same values as MK3's IMGPAL4.ASM).
  * Pixels are unpacked at the bit depth the record's own control word names
    (bits 12-14, SYSEQU.ASM `dmabpp`) - 6 bpp for every piece here.

SEQSCR: a MULTIPART row cannot be one sequence entry, and a sequence holds at
most 16 entries (`SEQSCR.entry[16]`; the biggest in stock MK2 art is exactly
16).  So the lane is stored the way it animates - one sequence per PIECE SLOT,
split where a slot runs past 16 rows - plus two scripts that chain the halves
back together:

    BLOODA1/BLOODA2   slot A, rows 1-10 / 11-19   script BLOODA
    BLOODB1/BLOODB2   slot B, rows 3-11 / 12-19   script BLOODB
    BLOODC            slot C, rows 5-19
    BLOODD            slot D, rows 5-13, 15-19    (row 14 has no D)
    BLOODE            slot E, rows 5,6,8,9,12
    BLOODF            slot F, row 8 only

Ticks are the arcade's, read off `fat_robo_crush`: row 1 is held 10 (a
`crush_sleep_5` of 4 plus `process_sleep(6)`), row 2 is held 4 (one more
`crush_sleep_5`), and rows 3-19 come from `mframew(5)` - 5 ticks each.  99
ticks, 1.81 s at 54.7068 Hz.

Sequence ENTRY arrays are stored BACK-TO-FRONT (Midway's convention; imgtool's
`WorldDecodeSeqScrRecord` reads them `num-1-i`).  Script arrays run forward.
Writing a sequence in display order silently reverses it.
"""
import argparse
import importlib.util
import struct
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "RBLOOD.IMG"

PROG_BASE = 0xFF800000
EVEN = "l1.2_mortal_kombat_3_u54_ultimate.u54"
ODD = "l1.2_mortal_kombat_3_u63_ultimate.u63"

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

IMG_VERSION = 0x063C        # what stock MK2 art carries; >= 0x634 = far model
SEQSCR_SIZE = 98
ENTRY_SIZE = 18
SEQFLG = 0x0040
MAX_SEQ_ENTRIES = 16

# First image record of the lane in the UMK3 program ROM (byte offset).
IMG_BLOCK = 0x088FAA

# The 71 pieces, in lane order, with the W/H/anipoint MK3's MKROBO.TBL gives
# them.  Used as a guard on the ROM walk - the values themselves come from the
# ROM.
EXPECT = [
    ("ROBOBLOOD1A", 94, 23, -75, -38), ("ROBOBLOOD2A", 118, 27, -61, -41),
    ("ROBOBLOOD3A", 39, 13, -138, -63), ("ROBOBLOOD3B", 176, 41, -44, -41),
    ("ROBOBLOOD4A", 9, 6, -176, -84), ("ROBOBLOOD4B", 211, 54, -28, -45),
    ("ROBOBLOOD5A", 105, 5, -69, -48), ("ROBOBLOOD5B", 103, 64, -18, -52),
    ("ROBOBLOOD5C", 9, 7, -182, -99), ("ROBOBLOOD5D", 24, 22, -229, -62),
    ("ROBOBLOOD5E", 111, 46, -121, -47), ("ROBOBLOOD6A", 105, 16, -68, -48),
    ("ROBOBLOOD6B", 16, 35, -249, -80), ("ROBOBLOOD6C", 10, 7, -185, -114),
    ("ROBOBLOOD6D", 121, 74, -13, -60), ("ROBOBLOOD6E", 91, 50, -136, -61),
    ("ROBOBLOOD7A", 105, 25, -68, -48), ("ROBOBLOOD7B", 53, 64, -216, -69),
    ("ROBOBLOOD7C", 86, 64, -8, -86), ("ROBOBLOOD7D", 109, 39, -99, -96),
    ("ROBOBLOOD8A", 102, 31, -71, -48), ("ROBOBLOOD8B", 67, 44, -32, -108),
    ("ROBOBLOOD8C", 11, 7, -143, -134), ("ROBOBLOOD8D", 30, 26, -183, -123),
    ("ROBOBLOOD8E", 4, 13, -235, -92), ("ROBOBLOOD8F", 30, 23, -252, -117),
    ("ROBOBLOOD9A", 97, 40, -73, -48), ("ROBOBLOOD9B", 82, 30, -21, -123),
    ("ROBOBLOOD9C", 9, 7, -146, -132), ("ROBOBLOOD9D", 48, 16, -172, -134),
    ("ROBOBLOOD9E", 57, 31, -236, -109), ("ROBOBLOOD10A", 91, 27, -13, -127),
    ("ROBOBLOOD10B", 78, 9, -147, -138), ("ROBOBLOOD10C", 65, 21, -236, -120),
    ("ROBOBLOOD10D", 92, 55, -75, -48), ("ROBOBLOOD11A", 87, 24, -12, -129),
    ("ROBOBLOOD11B", 154, 23, -147, -125), ("ROBOBLOOD11C", 37, 71, -75, -48),
    ("ROBOBLOOD11D", 55, 73, -112, -48), ("ROBOBLOOD12A", 73, 12, -228, -129),
    ("ROBOBLOOD12B", 56, 8, -164, -139), ("ROBOBLOOD12C", 38, 1, -99, -48),
    ("ROBOBLOOD12D", 45, 70, -122, -70), ("ROBOBLOOD12E", 87, 55, -13, -98),
    ("ROBOBLOOD13A", 73, 10, -228, -131), ("ROBOBLOOD13B", 70, 17, -14, -129),
    ("ROBOBLOOD13C", 34, 8, -184, -139), ("ROBOBLOOD13D", 76, 62, -92, -86),
    ("ROBOBLOOD14A", 73, 10, -228, -131), ("ROBOBLOOD14B", 109, 30, -24, -117),
    ("ROBOBLOOD14C", 3, 12, -164, -101), ("ROBOBLOOD15A", 24, 7, -24, -129),
    ("ROBOBLOOD15B", 70, 22, -66, -129), ("ROBOBLOOD15C", 3, 12, -164, -115),
    ("ROBOBLOOD15D", 73, 10, -228, -131), ("ROBOBLOOD16A", 24, 7, -24, -129),
    ("ROBOBLOOD16B", 70, 18, -66, -133), ("ROBOBLOOD16C", 3, 12, -164, -128),
    ("ROBOBLOOD16D", 73, 10, -228, -131), ("ROBOBLOOD17A", 24, 7, -24, -129),
    ("ROBOBLOOD17B", 70, 16, -66, -135), ("ROBOBLOOD17C", 15, 11, -158, -131),
    ("ROBOBLOOD17D", 73, 10, -228, -131), ("ROBOBLOOD18A", 24, 7, -24, -129),
    ("ROBOBLOOD18B", 70, 16, -66, -135), ("ROBOBLOOD18C", 21, 7, -155, -135),
    ("ROBOBLOOD18D", 73, 10, -228, -131), ("ROBOBLOOD19A", 24, 7, -24, -129),
    ("ROBOBLOOD19B", 70, 16, -66, -135), ("ROBOBLOOD19C", 24, 9, -155, -137),
    ("ROBOBLOOD19D", 73, 10, -228, -131),
]

# a_crush_blood (MK3 MKROBO.ASM): the 19 rows, each a piece list in DRAW order
# (first piece is drawn first, i.e. furthest back).
ROWS = [
    ["1A"], ["2A"], ["3A", "3B"], ["4A", "4B"],
    ["5A", "5B", "5C", "5D", "5E"], ["6A", "6B", "6C", "6D", "6E"],
    ["7A", "7B", "7C", "7D"], ["8A", "8B", "8C", "8D", "8E", "8F"],
    ["9A", "9B", "9C", "9D", "9E"], ["10A", "10B", "10C", "10D"],
    ["11A", "11B", "11C", "11D"], ["12A", "12B", "12C", "12D", "12E"],
    ["13A", "13B", "13C", "13D"], ["14A", "14B", "14C"],
    ["15A", "15B", "15C", "15D"], ["16A", "16B", "16C", "16D"],
    ["17A", "17B", "17C", "17D"], ["18A", "18B", "18C", "18D"],
    ["19A", "19B", "19C", "19D"],
]

# Ticks each row is held, read off fat_robo_crush (see the module docstring).
ROW_TICKS = [10, 4] + [5] * 17

PAL_NAME = b"RBLOOD_P"
PALNUM = 3          # palnum is 3-BASED: 3 is the first palette record

# MK3 IMGPAL4.ASM's RBLOOD_P, as a guard on the palette the ROM hands us.
PAL_GUARD = [
    0x001F, 0x6EB0, 0x664D, 0x59C8, 0x4D65, 0x4502, 0x7E52, 0x7D29,
    0x7C00, 0x7400, 0x6C42, 0x6C00, 0x6820, 0x6421, 0x6020, 0x5C20,
    0x5820, 0x5420, 0x5040, 0x4C40, 0x4840, 0x4820, 0x4440, 0x4040,
    0x3C40, 0x3840, 0x3440, 0x2C40, 0x2440,
]


def gfx():
    spec = importlib.util.spec_from_file_location(
        "umk3_gfx", HERE / "umk3_gfx_extract.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_prog(zip_path):
    with zipfile.ZipFile(zip_path) as z:
        even, odd = z.read(EVEN), z.read(ODD)
    flat = bytearray(len(even) * 2)
    flat[0::2] = even
    flat[1::2] = odd
    return bytes(flat)


def find_block(prog):
    """Byte offset of ROBOBLOOD1A's record: the anchor, or a scan for it."""
    name, w, h, ax, ay = EXPECT[0]
    sig = struct.pack("<HHhh", w, h, ax, ay)
    if prog[IMG_BLOCK:IMG_BLOCK + 8] == sig:
        return IMG_BLOCK
    hits = []
    start = 0
    while True:
        i = prog.find(sig, start)
        if i < 0:
            break
        hits.append(i)
        start = i + 1
    if len(hits) != 1:
        sys.exit("cannot locate %s: %d candidate records" % (name, len(hits)))
    print("note: lane moved - found %s at 0x%06x, not the 0x%06x anchor"
          % (name, hits[0], IMG_BLOCK))
    return hits[0]


def walk_records(prog, block):
    """The 71 records, reading W/H/anipoint/SAG/control straight off the ROM.

    A record is 14 bytes, or 18 when it ends `.long <palette>` - which only
    ROBOBLOOD1A does.  The stride is decided by looking ahead to the next
    record's expected W/H/anipoint, so the walk cannot silently slide.
    """
    recs = []
    pal_bit = None
    o = block
    for i, (name, w, h, ax, ay) in enumerate(EXPECT):
        got = struct.unpack_from("<HHhh", prog, o)
        if got != (w, h, ax, ay):
            sys.exit("record %d (%s) at 0x%06x reads %s, expected %s"
                     % (i, name, o, got, (w, h, ax, ay)))
        sag = struct.unpack_from("<I", prog, o + 8)[0]
        ctrl = struct.unpack_from("<H", prog, o + 12)[0]
        recs.append(dict(name=name, w=w, h=h, ax=ax, ay=ay, sag=sag,
                         ctrl=ctrl, off=o))
        o += 14
        if i + 1 < len(EXPECT):
            nxt = struct.pack("<HHhh", *EXPECT[i + 1][1:])
            if prog[o:o + 8] != nxt:
                if prog[o + 4:o + 12] != nxt:
                    sys.exit("record %d (%s) is neither 14 nor 18 bytes"
                             % (i, name))
                pal = struct.unpack_from("<I", prog, o)[0]
                if pal_bit is None:
                    pal_bit = pal
                elif pal_bit != pal:
                    sys.exit("lane uses more than one palette (0%08xh, 0%08xh)"
                             % (pal_bit, pal))
                recs[-1]["pal"] = pal
                o += 4
    if pal_bit is None:
        sys.exit("no palette pointer found in the lane's records")
    return recs, pal_bit


def ctrl_bpp(ctrl):
    """Bits 12-14 of the control word are bits per pixel, 0 meaning 8."""
    v = (ctrl >> 12) & 7
    return v if v else 8


def palette(prog, bit):
    off = (bit - PROG_BASE) // 8
    n = struct.unpack_from("<H", prog, off)[0]
    if not 0 < n <= 256:
        sys.exit("palette at 0%08xh claims %d colours" % (bit, n))
    cols = [struct.unpack_from("<H", prog, off + 2 + 2 * i)[0]
            for i in range(n)]
    if cols != PAL_GUARD:
        sys.exit("palette at 0%08xh is not RBLOOD_P" % bit)
    return cols


def decode(g, vid, recs):
    """(name, w, h, ax, ay, pixels) per record, 8 bits per pixel in memory."""
    out = []
    bpps = set()
    for r in recs:
        bpp = ctrl_bpp(r["ctrl"])
        bpps.add(bpp)
        px = g.pixels(vid, r["sag"], r["w"], r["h"], bpp, r["ctrl"])
        if px is None:
            sys.exit("%s failed to decode at sag 0%08xh" % (r["name"], r["sag"]))
        out.append((r["name"], r["w"], r["h"], r["ax"], r["ay"], px))
    if len(bpps) != 1:
        sys.exit("lane mixes bit depths: %s" % sorted(bpps))
    return out, bpps.pop()


# ---------------------------------------------------------------- sequences


def slot_sequences():
    """(sequence name, [(row index, piece name)]) per piece slot, split at 16."""
    slots = {}
    for row, pieces in enumerate(ROWS):
        for slot, piece in enumerate(pieces):
            slots.setdefault(slot, []).append((row, "ROBOBLOOD" + piece))
    seqs = []
    scripts = []
    for slot in sorted(slots):
        letter = chr(ord("A") + slot)
        rows = slots[slot]
        if len(rows) <= MAX_SEQ_ENTRIES:
            seqs.append(("BLOOD" + letter, rows))
            continue
        half = (len(rows) + 1) // 2
        first = len(seqs)
        seqs.append(("BLOOD%s1" % letter, rows[:half]))
        seqs.append(("BLOOD%s2" % letter, rows[half:]))
        scripts.append(("BLOOD" + letter, [first, first + 1]))
    return seqs, scripts


def seqscr_blob(seqs, scripts, index_of):
    """The SEQSCR + ENTRY blob: sequences first, then scripts."""
    blob = bytearray()

    for name, rows in seqs:
        rec = bytearray(SEQSCR_SIZE)
        rec[0:len(name)] = name.encode()
        struct.pack_into("<HH", rec, 16, SEQFLG, len(rows))
        struct.pack_into("<hh", rec, 84, 10, 10)        # startx, starty
        rec[88:94] = b"\xff" * 6                        # no damage table
        blob += rec
        # Sequences are stored back to front.
        for row, piece in reversed(rows):
            e = bytearray(ENTRY_SIZE)
            struct.pack_into("<h", e, 4, index_of[piece])
            e[6] = ROW_TICKS[row]
            blob += e

    for name, targets in scripts:
        rec = bytearray(SEQSCR_SIZE)
        rec[0:len(name)] = name.encode()
        struct.pack_into("<HH", rec, 16, 0, len(targets))
        struct.pack_into("<hh", rec, 84, 10, 10)
        rec[88:94] = b"\xff" * 6
        blob += rec
        # Scripts run forward, and their entries index SEQUENCES.
        for t in targets:
            e = bytearray(ENTRY_SIZE)
            struct.pack_into("<h", e, 4, t)
            e[6] = 1
            blob += e
    return bytes(blob)


# ------------------------------------------------------------------- writing


def build(frames, pal, bpp, seqs, scripts):
    index_of = {f[0]: i for i, f in enumerate(frames)}
    body = bytearray()
    pal_off = LIB.size
    body += struct.pack("<%dH" % len(pal), *pal)

    offsets = []
    for _n, w, h, _ax, _ay, px in frames:
        offsets.append(LIB.size + len(body))
        stride = (w + 3) & ~3            # IMG rows pad to a multiple of 4
        for y in range(h):
            body += bytes(px[y * w:(y + 1) * w]) + b"\0" * (stride - w)

    oset = LIB.size + len(body)
    hdr = LIB.pack(len(frames), len(pal) and 1 + 3, oset, IMG_VERSION,
                   len(seqs), len(scripts), 0, 0xABCD,
                   b"\xff\xff\xff\xff", 0, 0, 0)

    imgs = bytearray()
    for (name, w, h, ax, ay, _px), off in zip(frames, offsets):
        imgs += IMAGE.pack(name.encode().ljust(16, b"\0"), 0,
                           ax & 0xFFFF, ay & 0xFFFF, w, h, PALNUM,
                           off, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF)
    pals = PALETTE.pack(PAL_NAME.ljust(10, b"\0"), 0, bpp, len(pal),
                        pal_off, 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(body) + bytes(imgs) + bytes(pals) \
        + seqscr_blob(seqs, scripts, index_of)


def read_back(data):
    imgcnt, palcnt, oset, version, seqcnt, scrcnt = LIB.unpack_from(data, 0)[:6]
    frames = []
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        name = r[0].split(b"\0")[0].decode()
        ax = r[2] - 0x10000 if r[2] & 0x8000 else r[2]
        ay = r[3] - 0x10000 if r[3] & 0x8000 else r[3]
        w, h, off = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        px = b"".join(data[off + y * stride: off + y * stride + w]
                      for y in range(h))
        frames.append((name, w, h, ax, ay, px))
    pos = oset + imgcnt * IMAGE.size
    if palcnt > 3:
        pos += (palcnt - 3) * PALETTE.size
    records = []
    for s in range(seqcnt + scrcnt):
        name = data[pos:pos + 16].split(b"\0")[0].decode()
        flags, num = struct.unpack_from("<HH", data, pos + 16)
        entries = []
        for e in range(num):
            eo = pos + SEQSCR_SIZE + e * ENTRY_SIZE
            idx = struct.unpack_from("<h", data, eo + 4)[0]
            entries.append((idx, data[eo + 6]))
        records.append((name, s >= seqcnt, flags, entries))
        pos += SEQSCR_SIZE + num * ENTRY_SIZE
    return frames, records


# ------------------------------------------------------------------ reporting


def write_png(path, frames, pal, cols=4):
    """Composite every row the way the game does and lay them out as a grid.

    A piece's anipoint is the offset from the object's anchor to its top-left
    corner, so a row composites by ADDING it - which is the check that matters
    here: get the sign wrong and the 71 pieces scatter instead of making one
    picture.
    """
    try:
        from PIL import Image
    except ImportError:
        print("note: --png needs Pillow (pip install pillow) - skipped")
        return
    byname = {f[0]: f for f in frames}
    rgb = [(((c >> 10) & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31,
            (c & 31) * 255 // 31) for c in pal]
    boxes = [byname["ROBOBLOOD" + p] for row in ROWS for p in row]
    x0 = min(b[3] for b in boxes)
    x1 = max(b[3] + b[1] for b in boxes)
    y0 = min(b[4] for b in boxes)
    y1 = max(b[4] + b[2] for b in boxes)
    w, h = x1 - x0 + 2, y1 - y0 + 2
    rows = (len(ROWS) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * w, rows * h), (0, 0, 0))
    for i, pieces in enumerate(ROWS):
        cell = Image.new("RGB", (w, h), (18, 18, 26))
        for piece in pieces:
            _n, pw, ph, ax, ay, px = byname["ROBOBLOOD" + piece]
            for y in range(ph):
                for x in range(pw):
                    v = px[y * pw + x]
                    if v:
                        cell.putpixel((ax - x0 + x, ay - y0 + y), rgb[v])
        sheet.paste(cell, ((i % cols) * w, (i // cols) * h))
    sheet.save(path)
    print("wrote %s  (%d rows composited, cell %dx%d)" % (path, len(ROWS), w, h))


def print_lane(recs):
    print("; ANIM_ROBO_CRUSH_BLOOD (robots' ANIM_TABLE2 slot 010h)")
    print("; a_crush_blood - 19 rows, %d pieces, arcade anipoints"
          % len(recs))
    print("a_crush_blood")
    for row, pieces in enumerate(ROWS):
        print("\t.long\t%-46s; %2d ticks"
              % (",".join("ROBOBLOOD" + p for p in pieces), ROW_TICKS[row]))
    print("\t.long\t0")
    print()
    for r in recs:
        print("%s:" % r["name"])
        print("\t.word   %d,%d,%d,%d" % (r["w"], r["h"], r["ax"], r["ay"]))
        print("\t.word   0%04xh\t; control: %d bpp%s"
              % (r["ctrl"], ctrl_bpp(r["ctrl"]),
                 ", zero compressed" if r["ctrl"] & 0x80 else ""))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--verify", action="store_true",
                    help="read the file back and diff it against the ROM")
    ap.add_argument("--lane", action="store_true",
                    help="print the lane and its records, MK2 TBL shape")
    ap.add_argument("--dump", type=int, metavar="ROW",
                    help="ASCII-render one row's pieces (1-19)")
    ap.add_argument("--png", type=Path, metavar="FILE",
                    help="composite the 19 rows into one grid image")
    ap.add_argument("--no-write", action="store_true")
    args = ap.parse_args()

    g = gfx()
    if not g.ROM_ZIP.exists():
        sys.exit("UMK3 romset not found: %s" % g.ROM_ZIP)
    prog = load_prog(g.ROM_ZIP)
    block = find_block(prog)
    recs, pal_bit = walk_records(prog, block)
    pal = palette(prog, pal_bit)
    print("lane at 0x%06x: %d image records, palette RBLOOD_P at 0%08xh"
          " (%d colours)" % (block, len(recs), pal_bit, len(pal)))

    if args.lane:
        print()
        print_lane(recs)
        return 0

    vid = g.load_video(g.ROM_ZIP)
    frames, bpp = decode(g, vid, recs)
    print("decoded %d pieces, all %d bpp" % (len(frames), bpp))

    if args.dump is not None:
        row = args.dump - 1
        if not 0 <= row < len(ROWS):
            sys.exit("row must be 1..%d" % len(ROWS))
        byname = {f[0]: f for f in frames}
        for piece in ROWS[row]:
            name, w, h, ax, ay, px = byname["ROBOBLOOD" + piece]
            print("\n%s  %dx%d  anipoint %d,%d" % (name, w, h, ax, ay))
            print(g.render(px, w, h, step=2))
        return 0

    if args.png:
        write_png(args.png, frames, pal)

    seqs, scripts = slot_sequences()
    data = build(frames, pal, bpp, seqs, scripts)
    if not args.no_write:
        args.out.write_bytes(data)
        print("wrote %s  (%d pieces, %d sequences, %d scripts, %d bytes)"
              % (args.out, len(frames), len(seqs), len(scripts), len(data)))

    total = sum(ROW_TICKS)
    print("\nlane: %d rows, %d ticks (%.2f s at 54.7068 Hz)"
          % (len(ROWS), total, total / 54.7068))
    for row, pieces in enumerate(ROWS):
        print("   row %2d  %2d ticks  %s"
              % (row + 1, ROW_TICKS[row],
                 " ".join("ROBOBLOOD" + p for p in pieces)))
    print()
    for name, rows in seqs:
        print("   seq    %-9s %2d entries  rows %s"
              % (name, len(rows), ",".join(str(r + 1) for r, _ in rows)))
    for name, targets in scripts:
        print("   script %-9s %2d entries  %s"
              % (name, len(targets), " + ".join(seqs[t][0] for t in targets)))

    if args.verify:
        back_frames, back_records = read_back(
            args.out.read_bytes() if not args.no_write else data)
        bad = 0
        for want, got in zip(frames, back_frames):
            if want[:5] != got[:5] or bytes(want[5]) != got[5]:
                print("   MISMATCH %s" % want[0])
                bad += 1
        print("\nverify: %d/%d pieces round-trip identical to the ROM decode"
              % (len(frames), len(frames) - bad))
        index_of = {f[0]: i for i, f in enumerate(frames)}
        for (name, rows), (bname, is_script, flags, entries) in zip(
                seqs, back_records[:len(seqs)]):
            want = [(index_of[p], ROW_TICKS[r]) for r, p in reversed(rows)]
            ok = (name == bname and not is_script and flags == SEQFLG
                  and entries == want)
            print("   seq    %-9s %s" % (bname, "ok" if ok else "BAD"))
            bad += 0 if ok else 1
        for (name, targets), (bname, is_script, flags, entries) in zip(
                scripts, back_records[len(seqs):]):
            ok = (name == bname and is_script and flags == 0
                  and [e[0] for e in entries] == targets)
            print("   script %-9s %s" % (bname, "ok" if ok else "BAD"))
            bad += 0 if ok else 1
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
