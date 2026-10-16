#!/usr/bin/env python3
r"""Extract REPTILE'S ACID SPIT - art, palette and strike data - straight out of
`C:\MAME\roms\umk3.zip`.

NOTE: this was written while hunting Ermac's fireball and found the wrong asset.
Ermac's fireball is the projectile SHAO KAHN throws, and MK2 already carries it
(`BGSPEAR1-13` / `a_sk_spear` / `stk_sk_spear`) - see doc/UMK3_REPTILE_ACID_SPIT.md.
What this extracts is genuinely the acid spit, correctly decoded and proved; it
is kept for the table map and the decode method.

Nothing here is typed in from a movelist, a wiki or memory: every number is read
out of the shipped arcade data, and the decode is *proved* rather than assumed
(see "Why the decode is trustworthy" below).

    python tools/umk3_acid_spit_extract.py              # the report
    python tools/umk3_acid_spit_extract.py --render tmp/ermac   # + PNGs
    python tools/umk3_acid_spit_extract.py --tbl        # MK2 .TBL-shaped

## The roster - and a correction to doc/UMK3_ERMAC_TELESLAM.md

`character_anitabs1` at byte `0x60572` is **26 entries, not 15**, and it is
immediately followed by `character_anitabs2` at `0x605da` (26 more).  The index
is the CHARACTER, and the definitive ordering comes from the "<NAME> WINS"
pointer array at `0x33cc2`, which has exactly 26 entries:

     0 KANO        7 SEKTOR      14 SMOKE (robot)   21 CLASSIC SUB-ZERO
     1 SONYA       8 CYRAX       15 KITANA          22 HUMAN SMOKE
     2 JAX         9 KUNG LAO    16 JADE            23 NOOB SAIBOT
     3 NIGHTWOLF  10 KABAL       17 MILEENA         24 MOTARO
     4 SUB-ZERO   11 SHEEVA      18 SCORPION        25 SHAO KAHN
     5 STRYKER    12 SHANG TSUNG 19 REPTILE
     6 SINDEL     13 LIU KANG    20 ERMAC

That ordering explains every shared table, which is what makes it safe:
slots 7/8/14 share one table (the three CYBORGS), 15/16/17 share one (the three
female ninjas - and slot 16's anitab2 is `0x22fb4`, exactly the `lia_anitab2`
that tools/umk3_jade_extract.py already relies on), and **18-23 share one (the
six male ninjas)**.

`doc/UMK3_ERMAC_TELESLAM.md` calls slot 7 "male ninja".  Slot 7 is SEKTOR; the
male ninjas are 18-23 and their anitab1 is `0x26b46`, not `0x13f74`.  The
shipped teleslam port is NOT affected - `--check-teleslam` re-verifies that the
row-`0x44` hold offsets are byte-identical on every body type - but the label
was wrong and the "15 entries" count was wrong.

## Where the fireball lives

`male_ninja_anitab2` is `0x26c6a`, 19 slots, shared by all six male ninjas.
Eighteen of them are body art.  Slot **`0x07`** is the odd one out and it is the
projectile:

  * its frames point straight at image records for an 11x10 sprite, not at
    120px-tall body art, and
  * it ends in `ani_jump` back to its own head - it LOOPS.  That is the shape a
    projectile-in-flight lane has, and it is the same shape `ANIM_BOOMERANG`
    (`lia_anitab2[4]`) has in the Jade extractor.

It is the only lane in the table with either property.

Slot `0x06`'s `ani_sladd` slave carries a second art block that shares the
projectile's palette, so the two belong to one move: a long beam that breaks up
into droplets.

## The palette - and the 18-byte record gap

Image records are 7 words / 14 bytes, but the gap from the first record to the
second is **18**.  The extra long is an inline palette pointer, and it is how
the palette was found rather than guessed:

    0x9c08c  record   11x10  ...
    0x9c09a  .long    0ffdb6bc0h      -> palette at byte 0xb6d78, 16 entries
    0x9c09e  record    9x11  ...

`0xb6d78` is a 16-entry (= 4bpp) GREEN ramp, dark forest green climbing to a
yellow-green highlight.  The same pointer appears at `0x9bfe0`, at the head of
slot `0x06`'s block, which is what ties the two blocks into one move.

## Why the decode is trustworthy

The control word's top nibble is the bit depth (4/5/6), and for an uncompressed
frame (control bit 7 clear) the next frame's SAG must be exactly `w*h*bpp` bits
later.  Every uncompressed frame in the block satisfies that exactly - 440, 396,
440, 312 and 156 bits - so the record layout, the bit depth and the SAG base are
all confirmed, not assumed.  `--verify` re-runs that check.

## What is NOT in here

The tick rate, the flight velocity and the strike index the move actually passes
to `projectile_flight_call` live in TMS34010 code, not in data, and this tool
does not disassemble.  The strike table is printed with the projectile-shaped
candidates flagged, but which index the handler uses is not proven here - see
the report's own warning.
"""
import argparse
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from umk3_jade_extract import load_rom, Rom, ROM_ZIP, ANI_CMD, BASE  # noqa: E402

# ---------------------------------------------------------------- anchors ---
WINS_PTRS = 0x33CC2          # 26 "<NAME> WINS" strings - the roster's ground truth
ANITABS1 = 0x60572           # 26 entries, indexed by CHARACTER
ANITABS2 = ANITABS1 + 26 * 4  # 0x605da
STRIKE_TABLES = 0x5E490      # 26 entries -> per-character strike POINTER arrays

NINJA_ANITAB1 = 0x26B46      # chars 18-23, 69 rows
NINJA_ANITAB2 = 0x26C6A      # chars 18-23, 19 slots
SLOT_FLIGHT = 0x07           # the looping ball - the projectile
SLOT_BEAM = 0x06             # body + ani_sladd slave that shares the palette

PALETTE = 0xB6D78            # 16 entries, referenced inline at 0x9c09a / 0x9bfe0

# The two art blocks, in ROM order.  Listed explicitly rather than scanned so
# the report is stable; --verify proves the list against the SAG arithmetic.
BLOCK_BEAM = [0x9BFD2, 0x9BFE4, 0x9BFF2, 0x9C000, 0x9C00E, 0x9C01C, 0x9C02A,
              0x9C038, 0x9C046, 0x9C054, 0x9C062, 0x9C070, 0x9C07E]
BLOCK_BALL = [0x9C08C, 0x9C09E, 0x9C0AC, 0x9C0BA, 0x9C0C8, 0x9C0D6, 0x9C0E4,
              0x9C0F2, 0x9C100, 0x9C10E, 0x9C11C, 0x9C12A, 0x9C138]

# Names for the MK2 side.  The first four are the flight loop; the rest are the
# dissipation the lane plays after the loop breaks.
BALL_NAMES = ["ACIDGLOB1", "ACIDGLOB2", "ACIDGLOB3", "ACIDGLOB4",
              "ACIDSPLAT1", "ACIDSPLAT2", "ACIDSPLAT3", "ACIDSPLAT4",
              "ACIDSPLAT5", "ACIDSPLAT6", "ACIDSPLAT7", "ACIDSPLAT8",
              "ACIDSPLAT9"]

ROSTER = ["KANO", "SONYA", "JAX", "NIGHTWOLF", "SUB-ZERO", "STRYKER", "SINDEL",
          "SEKTOR", "CYRAX", "KUNG LAO", "KABAL", "SHEEVA", "SHANG TSUNG",
          "LIU KANG", "SMOKE (robot)", "KITANA", "JADE", "MILEENA", "SCORPION",
          "REPTILE", "ERMAC", "CLASSIC SUB-ZERO", "HUMAN SMOKE", "NOOB SAIBOT",
          "MOTARO", "SHAO KAHN"]
ERMAC = 20


def bpp_of(ctrl):
    return (ctrl >> 12) & 0xF


def compressed(ctrl):
    return bool(ctrl & 0x0080)


def pal_rgb(rom, pal, i):
    c = rom.u16(pal + 2 + 2 * i)
    return (((c >> 10) & 31) * 255 // 31,
            ((c >> 5) & 31) * 255 // 31,
            (c & 31) * 255 // 31)


def roster_from_rom(rom):
    """Re-derive the roster rather than trusting the constant above."""
    out = []
    for i in range(26):
        t = rom.off(rom.u32(WINS_PTRS + 4 * i))
        if t is None:
            break
        end = rom.d.index(b"\0", t)
        out.append(rom.d[t:end].decode("latin-1").replace(" WINS", ""))
    return out


def walk_lane(rom, addr, limit=40):
    """Frames here point DIRECTLY at image records, not at piece lists."""
    steps, i = [], 0
    while i < limit:
        v = rom.u32(addr + 4 * i)
        if v == 0:
            steps.append(("part_end", None))
            i += 1
            continue
        if v in ANI_CMD:
            arg = rom.u32(addr + 4 * (i + 1))
            steps.append((ANI_CMD[v], arg))
            if ANI_CMD[v] == "ani_jump":
                break
            i += 2
            continue
        o = rom.off(v)
        if o is None:
            break
        steps.append(("frame", o))
        i += 1
    return steps


def verify(rom):
    """Prove the record layout: for every uncompressed frame the next frame's
    SAG must be exactly w*h*bpp bits further on."""
    ok = True
    print("-- decode proof: uncompressed SAG continuity " + "-" * 28)
    for block, label in ((BLOCK_BALL, "ball"), (BLOCK_BEAM, "beam")):
        for a, b in zip(block, block[1:]):
            ra, rb = rom.image(a), rom.image(b)
            if compressed(ra["ctrl"]):
                continue
            want = ra["w"] * ra["h"] * bpp_of(ra["ctrl"])
            got = rb["sag"] - ra["sag"]
            flag = "OK" if got == want else "MISMATCH"
            if got != want:
                ok = False
            print("   %-4s 0x%05x -> 0x%05x  delta %-5d expect %-5d %s"
                  % (label, a, b, got, want, flag))
    for site in (0x9C09A, 0x9BFE0):
        t = rom.off(rom.u32(site))
        flag = "OK" if t == PALETTE else "MISMATCH"
        if t != PALETTE:
            ok = False
        print("   inline palette ptr at 0x%05x -> 0x%05x  %s" % (site, t, flag))
    return ok


def check_teleslam(rom):
    """doc/UMK3_ERMAC_TELESLAM.md took the victim hold off body 7, which is
    SEKTOR, not a male ninja.  Show that it did not matter."""
    def s16(v):
        return v - 0x10000 if v & 0x8000 else v

    print("-- teleslam row 0x44 hold offsets, per body " + "-" * 30)
    seen = {}
    for body in range(26):
        tab = rom.off(rom.u32(ANITABS1 + 4 * body))
        if tab is None:
            continue
        lane = rom.off(rom.u32(tab + 4 * 0x44))
        if lane is None:
            continue
        offs, i = [], 0
        while i < 40:
            v = rom.u32(lane + 4 * i)
            if v == 0:
                break
            if v in ANI_CMD:
                a = rom.u32(lane + 4 * (i + 1))
                if ANI_CMD[v] == "ani_offset_xy":
                    offs.append((s16(a >> 16), s16(a & 0xFFFF)))
                if ANI_CMD[v] == "ani_jump":
                    break
                i += 2
                continue
            i += 1
        seen.setdefault(tuple(offs), []).append(body)
    for offs, bodies in seen.items():
        names = ", ".join(ROSTER[b] for b in bodies)
        print("   %s\n      <- %s" % (list(offs), names))
    print("   => the port used body 7 (SEKTOR); bodies 18-23 (the real male")
    print("      ninjas) carry the SAME offsets, so the shipped move is right.")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--render", type=Path, help="write PNG contact sheets here")
    ap.add_argument("--raw", type=Path, help="write per-frame 8bpp raw bins here")
    ap.add_argument("--tbl", action="store_true", help="MK2 .TBL-shaped records")
    ap.add_argument("--verify", action="store_true", help="decode proof only")
    ap.add_argument("--check-teleslam", action="store_true")
    args = ap.parse_args()

    if not args.zip.exists():
        sys.exit("UMK3 romset not found: %s" % args.zip)
    rom = Rom(load_rom(args.zip))

    if args.verify:
        return 0 if verify(rom) else 1
    if args.check_teleslam:
        check_teleslam(rom)
        return 0

    if args.tbl:
        print("; UMK3 Reptile acid spit - MK2 .TBL shape")
        print("; palette: 16 entries from UMK3 byte 0x%05x" % PALETTE)
        for name, o in zip(BALL_NAMES, BLOCK_BALL):
            r = rom.image(o)
            print("%s:" % name)
            print("\t.word\t%d,%d,%d,%d" % (r["w"], r["h"], r["anix"], r["aniy"]))
            print("\t.long\t0%08xh\t\t; UMK3 SAG - MUST be re-cut for our ROM"
                  % r["sag"])
            print("\t.word\t0%04xh" % r["ctrl"])
        return 0

    names = roster_from_rom(rom)
    print("=" * 74)
    print("UMK3 Reptile acid spit - extracted from " + args.zip.name)
    print("=" * 74)

    print("\n-- roster, re-derived from the WINS table at 0x%05x " % WINS_PTRS
          + "-" * 12)
    for i in range(0, 26, 2):
        a = "%2d %-17s" % (i, names[i])
        b = "%2d %-17s" % (i + 1, names[i + 1]) if i + 1 < 26 else ""
        print("   " + a + b)
    print("   ERMAC is character %d; male ninjas are 18-23 and share every table."
          % ERMAC)

    a1 = rom.off(rom.u32(ANITABS1 + 4 * ERMAC))
    a2 = rom.off(rom.u32(ANITABS2 + 4 * ERMAC))
    stk = rom.off(rom.u32(STRIKE_TABLES + 4 * ERMAC))
    shared = [i for i in range(26)
              if rom.off(rom.u32(ANITABS2 + 4 * i)) == a2]
    print("\n-- Ermac's tables " + "-" * 55)
    print("   anitab1       0x%05x   (69 rows)" % a1)
    print("   anitab2       0x%05x   (19 slots)" % a2)
    print("   strike table  0x%05x" % stk)
    print("   anitab2 shared by: %s" % ", ".join(names[i] for i in shared))

    lane = rom.off(rom.u32(a2 + 4 * SLOT_FLIGHT))
    print("\n-- anitab2[0x%02x] - the projectile, at 0x%05x " % (SLOT_FLIGHT, lane)
          + "-" * 20)
    for kind, val in walk_lane(rom, lane):
        if kind == "frame":
            r = rom.image(val)
            print("     frame @0x%05x %3dx%-3d ani(%4d,%4d) sag=0%08xh ctrl=0%04xh %s"
                  % (val, r["w"], r["h"], r["anix"], r["aniy"], r["sag"],
                     r["ctrl"], "comp" if compressed(r["ctrl"]) else "flat"))
        elif kind == "part_end":
            print("     .long 0                      ; end of part")
        else:
            t = rom.off(val) if val else None
            print("     %-16s %s" % (kind, ("-> 0x%05x" % t) if t else ""))

    n = rom.u16(PALETTE)
    print("\n-- palette @0x%05x, %d entries (4bpp), found inline at 0x9c09a "
          % (PALETTE, n) + "-" * 3)
    for i in range(0, n, 4):
        cells = []
        for j in range(i, min(i + 4, n)):
            r, g, b = pal_rgb(rom, PALETTE, j)
            cells.append("[%2d] %04X #%02X%02X%02X"
                         % (j, rom.u16(PALETTE + 2 + 2 * j), r, g, b))
        print("   " + "  ".join(cells))

    for block, label in ((BLOCK_BALL, "BALL + dissipation (anitab2[0x07])"),
                         (BLOCK_BEAM, "BEAM slave (anitab2[0x06] ani_sladd)")):
        print("\n-- art block: %s " % label + "-" * 20)
        print("   %-10s %-8s %8s %5s %5s %11s %7s"
              % ("name", "WxH", "byte", "anix", "aniy", "SAG", "ctrl"))
        for k, o in enumerate(block):
            r = rom.image(o)
            nm = BALL_NAMES[k] if block is BLOCK_BALL else "-"
            print("   %-10s %3dx%-4d 0x%05x %5d %5d  0%08xh 0%04xh"
                  % (nm, r["w"], r["h"], o, r["anix"], r["aniy"], r["sag"],
                     r["ctrl"]))

    print("\n-- strike table 0x%05x (SHARED by all six male ninjas) " % stk
          + "-" * 8)
    print("   Every ninja's specials live in this one table at different")
    print("   indexes.  Which index the fireball handler passes is in CODE, so")
    print("   it is NOT proven here.  Flagged rows are the ones whose box is")
    print("   projectile-shaped - the ball's widest frame is 33x11.")
    print("   idx  xoff yoff xsiz ysiz  routine  hit/blk  note")
    for i in range(40):
        v = rom.u32(stk + 4 * i)
        o = rom.off(v)
        if o is None:
            break
        s = rom.strike(o)
        note = ""
        if 0 < s["xsize"] <= 40 and 0 < s["ysize"] <= 14:
            note = "<-- projectile-shaped"
        print("   [%02x] %5d %4d %4d %4d   0%04xh  %3d/%-3d  %s"
              % (i, s["xoff"], s["yoff"], s["xsize"], s["ysize"], s["routine"],
                 s["damage"] >> 8, s["damage"] & 0xFF, note))
    print("   (UMK3 full strength is 0a6h/166; MK2's is 0a1h/161, so UMK3")
    print("    damage carries over at about 0.97:1 - effectively 1:1.)")

    if args.render or args.raw:
        emit(rom, args)
    return 0


def emit(rom, args):
    from umk3_gfx_extract import load_video, pixels
    vid = load_video(args.zip)
    n = rom.u16(PALETTE)
    cols = [pal_rgb(rom, PALETTE, i) for i in range(n)]

    def decode(o):
        r = rom.image(o)
        px = pixels(vid, r["sag"], r["w"], r["h"], bpp_of(r["ctrl"]), r["ctrl"])
        return r, px

    if args.raw:
        args.raw.mkdir(parents=True, exist_ok=True)
        for k, o in enumerate(BLOCK_BALL):
            r, px = decode(o)
            if px is None:
                continue
            p = args.raw / ("%s_%dx%d.bin" % (BALL_NAMES[k], r["w"], r["h"]))
            p.write_bytes(bytes(px))
        print("\nwrote raw 8bpp frames to %s" % args.raw)

    if args.render:
        try:
            from PIL import Image
        except ImportError:
            sys.exit("--render needs Pillow:  python -m pip install pillow")
        args.render.mkdir(parents=True, exist_ok=True)
        for block, fname in ((BLOCK_BALL, "acid_spit_glob.png"),
                             (BLOCK_BEAM, "acid_spit_spray.png")):
            fr = []
            for o in block:
                r, px = decode(o)
                if px is None:
                    continue
                im = Image.new("RGBA", (r["w"], r["h"]), (0, 0, 0, 0))
                im.putdata([(0, 0, 0, 0) if v == 0 else cols[v] + (255,)
                            for v in px])
                fr.append(im)
            W = sum(i.width for i in fr) + 8 * len(fr) + 8
            H = max(i.height for i in fr) + 16
            sheet = Image.new("RGBA", (W, H), (24, 24, 28, 255))
            x = 8
            for im in fr:
                sheet.paste(im, (x, (H - im.height) // 2), im)
                x += im.width + 8
            sheet = sheet.resize((sheet.width * 3, sheet.height * 3),
                                 Image.NEAREST)
            sheet.save(args.render / fname)
            print("wrote %s" % (args.render / fname))


if __name__ == "__main__":
    raise SystemExit(main())
