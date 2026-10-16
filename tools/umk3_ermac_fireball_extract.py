#!/usr/bin/env python3
r"""Extract ERMAC'S FIREBALL - the green starburst - out of the UMK3 arcade ROM.

Ermac's fireball is the projectile SHAO KAHN throws in UMK3, so this reads it
off Kahn (character 25).  Nothing here is typed in from a movelist, a wiki or
memory; every number comes out of `C:\MAME\roms\umk3.zip`.

    python tools/umk3_ermac_fireball_extract.py                 # the report
    python tools/umk3_ermac_fireball_extract.py --render tmp/ermac
    python tools/umk3_ermac_fireball_extract.py --raw tmp/ermac/raw
    python tools/umk3_ermac_fireball_extract.py --tbl           # MK2 .TBL shape

## How it was found

`character_anitabs2` is at byte `0x605da` (see doc/UMK3_REPTILE_ACID_SPIT.md for
how the 26-entry character indexing was established).  Shao Kahn is character
**25**, and his anitab1 and anitab2 are the same table at `0x22118`.

Slot **`0x17`** is the fireball, on three counts:

  1. it **loops** - `ani_jump` back to its own head, which is the shape a
     projectile-in-flight lane has and almost nothing else does;
  2. its eleven frames are all roughly SQUARE and small (51-69 x 46-59), where
     every other Kahn lane is 150px-tall boss body art; and
  3. decoded, it is a spiky green star with a white-hot core - which is exactly
     what the move looks like on screen.

Kahn's frames point at PIECE LISTS, not straight at image records the way the
ninja projectile does, and his art lives at SAG `0x055xxxxx-0x058xxxxx` rather
than the `0x06xxxxxx` the ninja art sits in.  A scan tuned to the ninja
projectile finds nothing here, which is why the first pass through this ROM
missed it.

## Bit depth - do not trust the control word's top nibble here

For the 4bpp ninja projectile the control word's top nibble WAS the bit depth,
and the SAG arithmetic proved it.  These frames are all compressed (control bit
7 set), so that check cannot run - and the answer is different anyway.  The
frames decode as **6bpp**; at 5bpp they come out as horizontal noise.  Render
both and look before believing either: `--render` writes a sheet per depth when
`--both-depths` is passed.

The palette is **31 entries**, not 64, so the art only uses low indices out of a
6bpp space - which is normal here and is why counting palette entries is not a
way to work out the depth.

## The palette

An inline palette pointer sits between the FIRST and SECOND image records, the
same trick the ninja projectile uses:

    0x95f04  record   66x58 ...
    0x95f12  .long    <pal>       -> 0xb1c26, 31 entries
    0x95f16  record   67x54 ...

`0xb1c26` runs white-yellow at the core out to deep green at the spikes.

## Damage - Kahn's number is a BOSS number

Kahn's strike table (`0x5e880`) has six entries.  Nothing in the data says which
one the projectile passes, but the only box shaped like the art is index `0x04`
(52x49), and it carries **35 on hit / 6 on block**.  That is boss-grade, the
same way his MK2 spear is 40/8, and it is not what a playable Ermac should
throw.  Our own `stk_ermac_zap` uses 20/3.

## What is NOT in the data

The tick rate and the flight velocity are set by the caller in code, not stored
in the lane - the same limit doc/UMK3_ERMAC_TELESLAM.md hit, for the same
reason.
"""
import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from umk3_jade_extract import load_rom, Rom, ROM_ZIP, ANI_CMD  # noqa: E402

ANITABS1 = 0x60572
ANITABS2 = ANITABS1 + 26 * 4
STRIKE_TABLES = 0x5E490
KAHN = 25
SLOT_FIREBALL = 0x17
LANE = 0x22DBC
PALETTE = 0xB1C26          # 31 entries, inline at 0x95f12
BPP = 6                    # measured by eye; 5 decodes as noise - see docstring

# name, byte offset of the image record
NAMES = ["ERMFIRE%d" % (i + 1) for i in range(11)]


def walk(rom, lane, limit=40):
    """Kahn's frames point at PIECE LISTS; return the first piece of each."""
    out, i = [], 0
    while i < limit:
        v = rom.u32(lane + 4 * i)
        if v == 0:
            break
        if v in ANI_CMD:
            if ANI_CMD[v] == "ani_jump":
                out.append(("loop", rom.off(rom.u32(lane + 4 * (i + 1)))))
                break
            i += 2
            continue
        fo = rom.off(v)
        if fo is None:
            break
        po = rom.off(rom.u32(fo))
        if po is None:
            break
        out.append(("frame", po))
        i += 1
    return out


def pal_rgb(rom, pal, i):
    c = rom.u16(pal + 2 + 2 * i)
    return (((c >> 10) & 31) * 255 // 31,
            ((c >> 5) & 31) * 255 // 31,
            (c & 31) * 255 // 31)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--render", type=Path)
    ap.add_argument("--raw", type=Path)
    ap.add_argument("--tbl", action="store_true")
    ap.add_argument("--both-depths", action="store_true",
                    help="render at 5bpp as well, to show why 6 is the answer")
    args = ap.parse_args()

    if not args.zip.exists():
        sys.exit("UMK3 romset not found: %s" % args.zip)
    rom = Rom(load_rom(args.zip))

    tab = rom.off(rom.u32(ANITABS2 + 4 * KAHN))
    lane = rom.off(rom.u32(tab + 4 * SLOT_FIREBALL))
    steps = walk(rom, lane)
    recs = [rom.image(o) for kind, o in steps if kind == "frame"]
    loops = any(k == "loop" for k, _ in steps)

    if args.tbl:
        print("; UMK3 Ermac fireball (= Shao Kahn's projectile) - MK2 .TBL shape")
        print("; palette: %d entries from UMK3 byte 0x%05x, art is %dbpp"
              % (rom.u16(PALETTE), PALETTE, BPP))
        for nm, r in zip(NAMES, recs):
            print("%s:" % nm)
            print("\t.word\t%d,%d,%d,%d" % (r["w"], r["h"], r["anix"], r["aniy"]))
            print("\t.long\t0%08xh\t\t; UMK3 SAG - re-cut for our ROM" % r["sag"])
            print("\t.word\t0%04xh" % r["ctrl"])
        return 0

    print("=" * 74)
    print("UMK3 Ermac fireball - the green starburst - from " + args.zip.name)
    print("=" * 74)
    print("\nShao Kahn is character %d; his anitab1 and anitab2 are one table"
          % KAHN)
    print("at 0x%05x.  Slot 0x%02x is the fireball, lane 0x%05x, and it %s."
          % (tab, SLOT_FIREBALL, lane, "LOOPS" if loops else "does NOT loop"))

    print("\n-- the eleven frames " + "-" * 50)
    print("   %-10s %-9s %8s %5s %5s %11s %7s"
          % ("name", "WxH", "byte", "anix", "aniy", "SAG", "ctrl"))
    for nm, r in zip(NAMES, recs):
        print("   %-10s %3dx%-5d 0x%05x %5d %5d  0%08xh 0%04xh"
              % (nm, r["w"], r["h"], r["off"], r["anix"], r["aniy"],
                 r["sag"], r["ctrl"]))
    print("   all compressed (control bit 7), decoded at %dbpp" % BPP)

    n = rom.u16(PALETTE)
    print("\n-- palette @0x%05x, %d entries (inline at 0x95f12) " % (PALETTE, n)
          + "-" * 12)
    for i in range(0, n, 4):
        cells = []
        for j in range(i, min(i + 4, n)):
            r, g, b = pal_rgb(rom, PALETTE, j)
            cells.append("[%2d] #%02X%02X%02X" % (j, r, g, b))
        print("   " + "  ".join(cells))

    stk = rom.off(rom.u32(STRIKE_TABLES + 4 * KAHN))
    print("\n-- Shao Kahn's strike table 0x%05x " % stk + "-" * 34)
    print("   Which index the projectile uses is in CODE, not data.  The only")
    print("   box shaped like the art (51-69 x 46-59) is flagged.")
    print("   idx  xoff yoff xsiz ysiz  routine  hit/blk")
    for i in range(20):
        v = rom.u32(stk + 4 * i)
        o = rom.off(v)
        if o is None:
            break
        s = rom.strike(o)
        note = ("<-- star-sized"
                if 35 <= s["xsize"] <= 80 and 30 <= s["ysize"] <= 70 else "")
        print("   [%02x] %5d %4d %4d %4d   0%04xh  %3d/%-3d %s"
              % (i, s["xoff"], s["yoff"], s["xsize"], s["ysize"], s["routine"],
                 s["damage"] >> 8, s["damage"] & 0xFF, note))
    print("   Boss damage.  Ours (stk_ermac_zap) is 20/3 - see MKSTK.ASM.")

    if args.render or args.raw:
        emit(rom, recs, args)
    return 0


def emit(rom, recs, args):
    from umk3_gfx_extract import load_video, pixels
    vid = load_video(args.zip)
    n = rom.u16(PALETTE)
    cols = [pal_rgb(rom, PALETTE, i) for i in range(n)]

    if args.raw:
        args.raw.mkdir(parents=True, exist_ok=True)
        for nm, r in zip(NAMES, recs):
            px = pixels(vid, r["sag"], r["w"], r["h"], BPP, r["ctrl"])
            if px is None:
                print("  %s: out of range" % nm)
                continue
            (args.raw / ("%s_%dx%d.bin" % (nm, r["w"], r["h"]))).write_bytes(bytes(px))
        print("\nwrote raw 8bpp frames to %s" % args.raw)

    if args.render:
        try:
            from PIL import Image
        except ImportError:
            sys.exit("--render needs Pillow:  python -m pip install pillow")
        args.render.mkdir(parents=True, exist_ok=True)
        depths = [BPP] + ([5] if args.both_depths else [])
        for bpp in depths:
            ims = []
            for r in recs:
                px = pixels(vid, r["sag"], r["w"], r["h"], bpp, r["ctrl"])
                if px is None:
                    continue
                im = Image.new("RGBA", (r["w"], r["h"]), (0, 0, 0, 0))
                im.putdata([(0, 0, 0, 0) if v == 0
                            else (cols[v] + (255,) if v < len(cols)
                                  else (255, 0, 255, 255)) for v in px])
                ims.append(im)
            if not ims:
                continue
            W = sum(i.width for i in ims) + 8 * len(ims) + 8
            H = max(i.height for i in ims) + 16
            sheet = Image.new("RGBA", (W, H), (20, 20, 24, 255))
            x = 8
            for im in ims:
                sheet.paste(im, (x, (H - im.height) // 2), im)
                x += im.width + 8
            sheet = sheet.resize((sheet.width * 2, sheet.height * 2),
                                 Image.NEAREST)
            p = args.render / ("ermac_fireball_star_bpp%d.png" % bpp)
            sheet.save(p)
            print("wrote %s" % p)


if __name__ == "__main__":
    raise SystemExit(main())
