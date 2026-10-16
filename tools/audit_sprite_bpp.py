#!/usr/bin/env python3
"""
Audit every sprite frame in src/*.TBL for bits-per-pixel headroom.

The T-unit blitter reads bits-per-pixel out of each frame's control word
(SYSEQU.ASM `dmabpp`, bits 12-14) and MK2's baseline is 6 bpp = 64 colors.
A frame whose art only uses <=16 colors can be repacked at 4 bpp for a
straight 33% saving, <=32 colors at 5 bpp for 17%, with zero runtime cost:
the hardware does the unpacking.

This tool decodes the *packed* pixel data straight out of the built video
ROM (data/*.IRW), counts the distinct colour indices each frame actually
uses, and reports what it would cost repacked at the minimum legal bpp.

Line format (confirmed against the shadow renderer, MKDISP.ASM:1925-1942,
and the encoder, doc/load2/zcom.c):
  if the control word has bit 7 (`dmacmp`) set, every scanline begins with
  one byte -- low nibble = leading transparent run, high nibble = trailing
  transparent run, each shifted left by the frame's leading/trailing
  multiplier (control bits 8-9 / 10-11, giving 1x/2x/4x/8x). The remaining
  (xsize - lead - trail) pixels follow at `bpp` bits each. With bit 7 clear
  there is no per-line header and all xsize pixels are stored.

ADDRESSING -- this is what the first version of this tool got wrong, and it
is subtle enough to be worth spelling out.  Three separate facts:

  1. A .TBL `.long` SAG is an IROM-RELATIVE bit address: LOAD2 writes
     `address - 0x02000000`.  Because bank 1's relative base (0x04000000
     bits) is exactly bank 0's size (8 MB = 0x04000000 bits), the SAG *is*
     the bit offset into the flat 12 MB video ROM, for either bank, with no
     arithmetic at all.  The old code subtracted 0x02000000 from it (a 4 MB
     error) and discarded every SAG below that.
  2. An IRW *header* base is ABSOLUTE (0x02000000-relative, bank in a
     separate field), so it needs makevrom's `image_byte_offset` +
     `BANK_OFFSETS`.  The old code ran both quantities through the same
     function, so the reassembled ROM was shifted too.
  3. Frames are NOT byte-aligned -- LOAD2 only word-aligns when `do_align`
     is set, and this build does not set it.  The low 3 bits of the SAG are
     a real bit offset.  Reading from `sag // 8` desynchronises the whole
     frame; the per-line header decodes as garbage and `lead + trail`
     promptly exceeds xsize.

With all three fixed, 9,760 of 10,089 frames end EXACTLY at the next
frame's SAG (96.7%).  `--verify` reports that round-trip.

Two headroom figures are reported, because they are not the same change:
  * "no remap"  -- the frame's indices are already below 2^bpp, so only the
    palette's `bits_pr_pxl` has to change (LOAD2 packs at the palette's bpp
    and overrides `PPP>`, so this is still an imgtool edit, not a build flag).
  * "with remap" -- the frame uses few enough colours but they are spread
    across the palette, so the art has to be re-indexed as well.

Frames drawn with a shadow are locked at 6 bpp: MKDISP.ASM:1941 hardcodes
the 6 bpp stride when advancing the shadow SAG.  `--no-locked` drops the
character/fatality tables on that basis.

Usage:
    python tools/audit_sprite_bpp.py                 # ranked summary
    python tools/audit_sprite_bpp.py --verify        # decoder round-trip only
    python tools/audit_sprite_bpp.py --no-locked     # skip shadow-locked art
    python tools/audit_sprite_bpp.py --csv out.csv   # full per-frame dump
    python tools/audit_sprite_bpp.py --min-bytes 512 # only worthwhile frames
"""
import argparse
import csv
import glob
import importlib.util
import os
import re
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

VIDEO_SIZE = 0xC00000          # flat video ROM, bytes (bank0 8 MB + bank1 4 MB)
VIDEO_BITS = VIDEO_SIZE * 8

# Tables whose art is drawn with a shadow, so its bpp is pinned at 6 by
# MKDISP.ASM:1941.  Fighters, their fatalities, and anything that reuses a
# fighter's shadow path.
SHADOW_LOCKED = {
    "MKLK", "MKLK2", "MKLK3", "MKJC", "MKRD", "MKRD2", "MKNJ", "MKST",
    "MKSA", "MKSA2", "MKSK", "MKJX", "MKHH", "MKGORO", "MKGORO2", "MKFN",
    "MKFN2", "MKGUYS", "MKSPLIT", "MKFALL", "MKSEL", "MKSUCK", "MKDIE",
    "MKFAT1", "MKFAT2", "MKFATAL", "MKBABY",
    "MKARMS", "HKBFIST", "LKBFIST", "LKDUBLKN", "KITSPIN", "JADVIC",
    "JADERANG", "SHAOSIT", "GOROWALK", "MKRDWALK", "JXAIRPRO",
    "STCUT", "STDECAP", "SAHELI", "MK1ST1", "MK1ST2", "FLAPJACK",
}

# A frame record in a .TBL is:
#     LABEL:
#         .word  xsize, ysize, anix, aniy
#         .long  <sag>H
#         .word  <control>H
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$")
SIZE_RE = re.compile(r"^\s*\.word\s+(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)")
SAG_RE = re.compile(r"^\s*\.long\s+0([0-9a-fA-F]+)[Hh]")
CTRL_RE = re.compile(r"^\s*\.word\s+0([0-9a-fA-F]+)[Hh]")


def _load_makevrom():
    """Import makevrom.py for its IRW parser and bank map (single source of
    truth for where each IRW lands in the flat ROM)."""
    path = os.path.join(REPO, "makevrom.py")
    spec = importlib.util.spec_from_file_location("_makevrom", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_video_rom(data_dir):
    """Reassemble the flat 12 MB video ROM from the built IRW payloads.

    Uses makevrom's own placement so this cannot drift from the real ROM.
    """
    mv = _load_makevrom()
    from pathlib import Path

    rom = bytearray(VIDEO_SIZE)
    covered = bytearray(VIDEO_SIZE)
    for path in sorted(Path(data_dir).glob("*.IRW")):
        base, bank, pixels = mv.parse_irw(path)
        bank = mv.FILE_BANK.get(path.name, bank)
        if bank not in mv.BANK_OFFSETS:
            continue
        off = mv.BANK_OFFSETS[bank] + mv.image_byte_offset(base, bank)
        if off < 0 or off + len(pixels) > VIDEO_SIZE:
            print("  skipping %s: lands outside the flat ROM (0x%X)"
                  % (path.name, off))
            continue
        rom[off:off + len(pixels)] = pixels
        for i in range(off, off + len(pixels)):
            covered[i] = 1
    return rom, covered


class BitReader:
    """LSB-first bit reader over the flat ROM, positioned in BITS.

    LOAD2 builds each output word LSB-first (`load_bits`, load2.c:3160) and
    writes 16-bit little-endian words, which is the same thing as LSB-first
    over the byte stream.
    """

    __slots__ = ("buf", "pos")

    def __init__(self, buf, bit_off):
        self.buf = buf
        self.pos = bit_off

    def read(self, n):
        v = 0
        for i in range(n):
            p = self.pos + i
            if p >= VIDEO_BITS:
                return None
            v |= ((self.buf[p >> 3] >> (p & 7)) & 1) << i
        self.pos += n
        return v


def parse_tbls(src_dir):
    """Yield (file, label, xsize, ysize, sag, control) for every frame record."""
    for path in sorted(glob.glob(os.path.join(src_dir, "*.TBL"))):
        name = os.path.basename(path)
        with open(path, errors="ignore") as source:
            lines = source.read().split("\n")
        for i, line in enumerate(lines):
            m = LABEL_RE.match(line)
            if not m:
                continue
            j, size, sag, ctrl = i + 1, None, None, None
            while j < len(lines) and j < i + 6:
                s = lines[j]
                if size is None:
                    ms = SIZE_RE.match(s)
                    if ms:
                        size = (int(ms.group(1)), int(ms.group(2)))
                        j += 1
                        continue
                if size and sag is None:
                    msag = SAG_RE.match(s)
                    if msag:
                        sag = int(msag.group(1), 16)
                        j += 1
                        continue
                if sag is not None and ctrl is None:
                    mc = CTRL_RE.match(s)
                    if mc:
                        ctrl = int(mc.group(1), 16)
                    break
                break
            if size and sag is not None and ctrl is not None:
                yield name, m.group(1), size[0], size[1], sag, ctrl


def decode_frame(rom, covered, xsize, ysize, sag, ctrl):
    """Decode one packed frame.

    Returns (colours, max_index, packed_bits) or None.  `sag` is used
    directly as a flat bit offset -- see the ADDRESSING note at the top.
    """
    bpp = (ctrl >> 12) & 7
    if bpp == 0:
        bpp = 8
    compressed = bool(ctrl & 0x80)
    ldx = (ctrl >> 8) & 3
    trx = (ctrl >> 10) & 3

    if sag < 0 or sag >= VIDEO_BITS or not covered[sag >> 3]:
        return None
    if xsize <= 0 or ysize <= 0 or xsize > 512 or ysize > 512:
        return None

    br = BitReader(rom, sag)
    colours = set()
    for _ in range(ysize):
        if compressed:
            hdr = br.read(8)
            if hdr is None:
                return None
            lead = (hdr & 0x0F) << ldx
            trail = (hdr >> 4) << trx
            npix = xsize - lead - trail
            if npix < 0:
                return None
        else:
            npix = xsize
        for _ in range(npix):
            v = br.read(bpp)
            if v is None:
                return None
            colours.add(v)
    return colours, (max(colours) if colours else 0), br.pos - sag


def min_bpp_for(nvalues):
    """Smallest legal bpp that can index `nvalues` distinct values."""
    for b in (1, 2, 3, 4, 5, 6, 7, 8):
        if nvalues <= (1 << b):
            return b
    return 8


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", help="write full per-frame results to this file")
    ap.add_argument("--min-bytes", type=int, default=0,
                    help="only list frames saving at least this many bytes")
    ap.add_argument("--top", type=int, default=25, help="rows in the summary")
    ap.add_argument("--verify", action="store_true",
                    help="report the decoder round-trip and stop")
    ap.add_argument("--no-locked", action="store_true",
                    help="skip tables whose art is shadow-locked at 6 bpp")
    ap.add_argument("--remap", action="store_true",
                    help="assume palettes can be re-indexed (colour count "
                         "instead of highest index used)")
    args = ap.parse_args()

    src_dir = os.path.join(REPO, "src")
    data_dir = os.path.join(REPO, "data")

    print("Reassembling video ROM from data/*.IRW ...")
    rom, covered = build_video_rom(data_dir)

    records = list(parse_tbls(src_dir))
    all_sags = sorted({r[4] for r in records})
    next_sag = {s: all_sags[i + 1] for i, s in enumerate(all_sags[:-1])}

    rows = []
    seen_sags = set()
    stats = defaultdict(int)
    for fname, label, xs, ys, sag, ctrl in records:
        stats["records"] += 1
        if sag in seen_sags:
            stats["shared_sag"] += 1
            continue
        seen_sags.add(sag)
        r = decode_frame(rom, covered, xs, ys, sag, ctrl)
        if r is None:
            stats["undecodable"] += 1
            continue
        colours, max_index, packed_bits = r
        stats["decoded"] += 1

        # Round-trip: a frame's stored bytes run up to the next frame's SAG.
        gap = next_sag.get(sag)
        if gap is not None and 0 < gap - sag < 4_000_000:
            stats["extent_tested"] += 1
            if packed_bits == gap - sag:
                stats["extent_exact"] += 1

        stem = fname[:-4].upper()
        locked = stem in SHADOW_LOCKED
        if locked:
            stats["shadow_locked"] += 1
            if args.no_locked:
                continue

        cur_bpp = (ctrl >> 12) & 7 or 8
        if args.remap:
            # index 0 stays transparent, so it always costs a slot
            best = min_bpp_for(len(colours | {0}))
        else:
            best = min_bpp_for(max_index + 1)
        if best >= cur_bpp:
            continue
        header_bits = 8 * ys if (ctrl & 0x80) else 0
        pixels = (packed_bits - header_bits) // cur_bpp
        saved = (pixels * (cur_bpp - best)) // 8
        if saved <= args.min_bytes:
            continue
        rows.append({
            "file": fname, "label": label, "x": xs, "y": ys,
            "colours": len(colours), "max_index": max_index,
            "cur_bpp": cur_bpp, "best_bpp": best,
            "packed": packed_bits // 8, "locked": int(locked), "saved": saved,
        })

    tested = stats["extent_tested"]
    exact = stats["extent_exact"]
    print("\nRecords parsed      : %d" % stats["records"])
    print("Unique SAGs decoded : %d" % stats["decoded"])
    print("Shared SAGs skipped : %d" % stats["shared_sag"])
    print("Undecodable         : %d" % stats["undecodable"])
    print("Round-trip          : %d/%d frames end exactly at the next SAG (%.1f%%)"
          % (exact, tested, 100.0 * exact / max(tested, 1)))
    if args.verify:
        return

    rows.sort(key=lambda r: -r["saved"])
    total = sum(r["saved"] for r in rows)
    mode = "palette re-index allowed" if args.remap else "no palette re-index"
    scope = "shadow-locked art excluded" if args.no_locked else \
            "shadow-locked art INCLUDED (%d frames, not actually reducible)" \
            % stats["shadow_locked"]
    print("\nMode                : %s, %s" % (mode, scope))
    print("Frames that could drop bpp: %d" % len(rows))
    print("TOTAL RECLAIMABLE   : %d bytes (%.1f KB)" % (total, total / 1024))

    by_target = defaultdict(lambda: [0, 0])
    for r in rows:
        e = by_target["%d->%d bpp" % (r["cur_bpp"], r["best_bpp"])]
        e[0] += 1
        e[1] += r["saved"]
    print("\nBy transition:")
    for k in sorted(by_target):
        print("  %-12s %5d frames  %9d bytes" % (k, by_target[k][0], by_target[k][1]))

    by_file = defaultdict(int)
    for r in rows:
        by_file[r["file"]] += r["saved"]
    print("\nTop tables by reclaimable bytes:")
    for k, v in sorted(by_file.items(), key=lambda kv: -kv[1])[:args.top]:
        print("  %-16s %9d bytes" % (k, v))

    print("\nLargest individual frames:")
    print("  %-16s %-22s %7s %7s %5s %9s" %
          ("table", "label", "size", "colours", "bpp", "saved"))
    for r in rows[:args.top]:
        print("  %-16s %-22s %3dx%-3d %7d %d->%d %9d" %
              (r["file"], r["label"], r["x"], r["y"], r["colours"],
               r["cur_bpp"], r["best_bpp"], r["saved"]))

    if args.csv:
        fields = ["file", "label", "x", "y", "colours", "max_index",
                  "cur_bpp", "best_bpp", "packed", "locked", "saved"]
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fields)
            w.writeheader()
            w.writerows(rows)
        print("\nWrote %s (%d rows)" % (args.csv, len(rows)))


if __name__ == "__main__":
    main()
