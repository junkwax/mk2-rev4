#!/usr/bin/env python3
r"""Decode Ermac's TELEKINETIC SLAM out of the UMK3 arcade material.

Two halves, from two places, and both are read rather than remembered:

  * the DATA - the strike box he grabs with, and the victim's animation lanes
    - comes out of `C:\MAME\roms\umk3.zip`, the shipped arcade program ROM.
  * the CODE - the order the lanes are played in, the velocities, the tick
    counts and the damage - is quoted verbatim, with line numbers, out of the
    UMK3 source at `Workplace/UltimateMortalKombat3` (set UMK3_SRC to move it).

    python tools/umk3_teleslam_extract.py              # the report
    python tools/umk3_teleslam_extract.py --old        # + the superseded rows
    python tools/umk3_teleslam_extract.py --render DIR # + decoded PNGs

## What this supersedes

The first port of this move was built on UMK3 anitab1 rows 044h and 041h,
picked out by pattern-matching for "a lane every character has, that loops,
that draws the body 130px above its anchor".  All of that was true of row
044h and none of it was Ermac: **044h is ANIM_JADE_SHOOK** (the victim of
Jade's fan lift) and **041h is ANIM_AFB_ROBO2** (air-flipped by Cyrax).
MKGUYS.H names both.  Ermac's slam touches neither, which is why the move
looked like nothing in the arcade looks like.  --old prints them next to the
real ones so the mistake stays visible.

## The real sequence

stat_do_ermac_slam (MKSTAT.C) is the attacker and does almost nothing: play
his own lane, rumble the floor, poll strike row 01ah for 16 ticks, and get out
of the way.  Everything anybody watches is r_ermac_slam (MKREACT.C reaction
078h) running in the VICTIM's process:

    slammed_shake_up     pose ANIM_STUMBLE frame 0, oyvel = -2.0/tick,
                         shake2(+-3,+-3) four times at 2 ticks -> 16 ticks
    slammed_zoom_up(8)   oyvel = -4.0, ograv = -3.0 (NEGATIVE: he accelerates
                         UPWARD), 8 ticks, then ANIM_KDOWN part 2 frame 1.
                         He leaves the top of the screen.
    slammed_slam_down    ograv = +8.0, fall until oypos >= p_ganiy
    impact               damage_to_me(9), ANIM_KDOWN part 2 frame 2,
                         shake_a11(8,0ch), dec_my_p_hit, rsnd_ground, sleep 8
    bounce               flight(-3.5, -8.0, +0.375, 4, ANIM_ORB_BANGED)
    land_on_my_back

## Three things that independently confirm it

1. **The reaction number matches the strike record.**  Strike row 01ah of the
   male-ninja table carries routine word 07801h.  Its high byte, 078h, is the
   reaction index, and MKREACT.C's table names entry 078h r_ermac_slam.
2. **The ending is already in MK2.**  UMK3 finishes with
   flight(-SCX(0x38000), -SCY(0x80000), SCY(0x6000), 4, ANIM_ORB_BANGED).
   MK2's r_orb finishes with -038000h / -080000h / 06000h / 4 / 03ah, and
   03ah is a_banged - the same animation under MK2's own name.  Two engines,
   four identical constants, same art.
3. **A live capture measured the flight before the source was found.**  One
   PNG per emulated frame, victim tracked by colour: 16 frames of ~2px rise
   with a 4-frame wobble, then 7 frames accelerating by ~3px/frame each tick,
   then gone for 6 frames, then back down accelerating by ~8.  That is
   shake2 + ograv = -3.0 + ograv = +8.0, to the constant.
"""
import argparse
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from umk3_jade_extract import load_rom, Rom, ROM_ZIP, ANI_CMD  # noqa: E402

ANITABS1 = 0x60572          # 26 entries, indexed by CHARACTER
STRIKE_TABLES = 0x05E490    # master strike_tables array
ERMAC = 20                  # FT_ERMAC (MKGAME.H).  18-23 are the male ninjas
                            # and share one anitab1 and one strike table.
STK_ROW = 0x1A              # stat_do_ermac_slam: strike_check_a0(obj,0x1a)

# The lanes the move actually plays, and what each is for.
LANES = [
    (0x20, "ANIM_STUMBLE", "part 1 frame 0 - the pose he is lifted in"),
    (0x1E, "ANIM_KDOWN", "PART 2 - frame 1 at the top, frame 2 on the impact"),
    (0x43, "ANIM_ORB_BANGED", "the bounce off the floor, once he has landed"),
]

# What the first port read instead.  Kept so the correction stays checkable.
OLD_LANES = [
    (0x44, "ANIM_JADE_SHOOK", "Jade's FAN LIFT victim - read as 'the hold'"),
    (0x41, "ANIM_AFB_ROBO2", "air-flipped by Cyrax - read as 'the descent'"),
]

# UMK3 source functions worth printing in full, in play order.
QUOTES = [
    ("MKSTAT.C", "stat_do_ermac_slam", "THE ATTACKER - all of it"),
    ("MKREACT.C", "r_ermac_slam", "THE VICTIM - the sequence itself"),
    ("MKREACT.C", "slammed_shake_up", None),
    ("MKREACT.C", "pose_stumble_frame_1", None),
    ("MKREACT.C", "slammed_zoom_up", None),
    ("MKREACT.C", "slammed_slam_down", None),
]

# Where the MK2 port put each of them.  Printed so the two can be diffed by
# eye; nothing here is read back out of MK2, it is a map, not a check.
PORT = [
    ("strike box 01ah", "src/MKSTK.ASM stk_ermac_teleslam"),
    ("reaction 078h", "src/MKREACT.ASM r_ermac_teleslam (react_to_ermac 01ch)"),
    ("stat_do_ermac_slam", "src/MKSLAM.ASM do_ermac_teleslam"),
    ("ANIM_STUMBLE 020h", "MK2 anitab1 row 023h - a_njstumble"),
    ("ANIM_KDOWN 01eh", "MK2 anitab1 row 00fh - a_njkdown"),
    ("ANIM_ORB_BANGED 043h", "MK2 anitab1 row 03ah - a_banged"),
    ("ACT_ER_SLAM_SD 062ah", "act_ermac_tks_sd 061dh (MAINEQU.ASM)"),
    ("every constant", "erm_tks_* (MAINEQU.ASM)"),
]


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class Lane:
    """One animation lane, split into PARTS.

    A lane is interleaved commands and frame pointers; a zero ends a part, and
    an empty part ends the lane.  Parts matter here - the slam plays
    ANIM_KDOWN's *second* part, which the stop-at-the-first-zero reader this
    file used to have could not even see.
    """

    def __init__(self, rom, addr, stops=(), max_parts=8):
        self.rom, self.addr = rom, addr
        self.parts, self.loops = [], False
        steps, pend, i = [], (0, 0), 0
        while i < 400 and len(self.parts) < max_parts:
            # STOP AT THE NEXT LANE.  A part terminator is a single zero and
            # nothing in the data says which one was the LAST part, so a reader
            # that only watches for zeroes walks straight out of the lane and
            # reports the next row's frames as more parts of this one.  The
            # anitab is the bound: every other row's start address is a wall.
            if i and (addr + 4 * i) in stops:
                break
            v = rom.u32(addr + 4 * i)
            if v == 0:
                if not steps:
                    break                       # empty part = end of the lane
                self.parts.append(steps)
                steps, pend, i = [], (0, 0), i + 1
                continue
            if v in ANI_CMD:
                arg = rom.u32(addr + 4 * (i + 1))
                name = ANI_CMD[v]
                if name == "ani_jump":
                    self.loops = rom.off(arg) == addr
                    break
                if name == "ani_offset_xy":
                    pend = (s16(arg >> 16), s16(arg & 0xFFFF))
                i += 2
                continue
            po = rom.off(v)
            if po is None:
                break
            pieces = []
            for k in range(8):
                pv = rom.u32(po + 4 * k)
                if pv == 0:
                    break
                io_ = rom.off(pv)
                if io_ is None:
                    break
                pieces.append(rom.image(io_))
            if not pieces:
                break
            steps.append((pend[0], pend[1], pieces))
            i += 1
        if steps:
            self.parts.append(steps)

    def signature(self, part):
        seen, out = {}, []
        for _, _, pieces in self.parts[part]:
            key = tuple((p["sag"], p["w"], p["h"]) for p in pieces)
            out.append(seen.setdefault(key, chr(ord("A") + len(seen))))
        return "".join(out)


def anitab1(rom, char):
    return rom.off(rom.u32(ANITABS1 + 4 * char))


def lane_starts(rom, char, rows=69):
    """Every lane head in this character's anitab1 - the walls for Lane."""
    t = anitab1(rom, char)
    out = set()
    for r in range(rows):
        a = rom.off(rom.u32(t + 4 * r))
        if a is not None:
            out.add(a)
    return out


def lane_for(rom, char, row):
    return Lane(rom, rom.off(rom.u32(anitab1(rom, char) + 4 * row)),
                stops=lane_starts(rom, char))


def strike(rom, char, row):
    tbl = rom.off(rom.u32(STRIKE_TABLES + 4 * char))
    off = rom.off(rom.u32(tbl + 4 * row))
    return rom.strike(off) if off is not None else None


def show_lanes(rom, char, lanes):
    for row, name, why in lanes:
        lane = lane_for(rom, char, row)
        print("\n  row %#04x  %-16s @%#08x %s"
              % (row, name, lane.addr, "LOOPS" if lane.loops else ""))
        if why:
            print("            %s" % why)
        for pi, steps in enumerate(lane.parts, 1):
            print("      part %d   pattern %s" % (pi, lane.signature(pi - 1)))
            for n, (dx, dy, pieces) in enumerate(steps, 1):
                geom = " + ".join("%dx%d" % (p["w"], p["h"]) for p in pieces)
                off = "" if (dx, dy) == (0, 0) else "  dx=%d dy=%d" % (dx, dy)
                print("        %2d  %s%s" % (n, geom, off))


def find_src():
    """Locate the UMK3 C source tree, or None."""
    cands = []
    env = os.environ.get("UMK3_SRC")
    if env:
        cands.append(Path(env))
    cands.append(Path(r"c:/Users/you/Workplace/UltimateMortalKombat3"))
    for base in cands:
        if not base.exists():
            continue
        if (base / "MKREACT.C").exists():
            return base
        for src in base.glob("**/src"):
            if (src / "MKREACT.C").exists():
                return src
    return None


def quote(src, fname, func):
    """Print a C function verbatim with its real line numbers."""
    path = src / fname
    text = path.read_text(errors="replace").splitlines()
    pat = re.compile(r"^\s*(?:void|WORD|short|long)\s+%s\s*\(" % re.escape(func))
    for i, line in enumerate(text):
        if pat.match(line):
            break
    else:
        print("    %s: %s not found" % (fname, func))
        return
    depth, started, out = 0, False, []
    for j in range(i, min(i + 200, len(text))):
        out.append((j + 1, text[j]))
        depth += text[j].count("{") - text[j].count("}")
        if "{" in text[j]:
            started = True
        if started and depth == 0:
            break
    for n, line in out:
        print("    %-6d %s" % (n, line.rstrip()))


def render(rom, char, out_dir):
    try:
        from PIL import Image
    except ImportError:
        sys.exit("--render needs Pillow")
    import umk3_gfx_extract as G
    vid = G.load_video(ROM_ZIP)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    tiles = []
    for row, name, _ in LANES:
        lane = lane_for(rom, char, row)
        for pi, steps in enumerate(lane.parts, 1):
            for n, (_, _, pieces) in enumerate(steps, 1):
                for k, p in enumerate(pieces):
                    # bit depth is bits 12-14 of the DMA control word, NOT 4-6
                    bpp = (p["ctrl"] >> 12) & 7
                    px = G.pixels(vid, p["sag"], p["w"], p["h"], bpp, p["ctrl"])
                    if px is None:
                        print("  %s p%d f%d.%d DECODE FAILED" % (name, pi, n, k))
                        continue
                    im = Image.new("RGB", (p["w"], p["h"]))
                    buf, mx = im.load(), max(px) or 1
                    for y in range(p["h"]):
                        for x in range(p["w"]):
                            v = px[y * p["w"] + x]
                            g = 0 if v == 0 else 40 + (v * 215) // mx
                            buf[x, y] = (g, g, g)
                    im.save(out_dir / ("umk3_%s_p%d_f%d_%d.png"
                                       % (name.lower(), pi, n, k)))
                    tiles.append(im)
    if tiles:
        pad = 6
        w = sum(t.width for t in tiles) + pad * (len(tiles) + 1)
        h = max(t.height for t in tiles) + 2 * pad
        sheet = Image.new("RGB", (w, h), (20, 20, 30))
        x = pad
        for t in tiles:
            sheet.paste(t, (x, pad + (h - 2 * pad - t.height) // 2))
            x += t.width + pad
        sheet.save(out_dir / "umk3_teleslam.png")
        print("\ncontact sheet: %s" % (out_dir / "umk3_teleslam.png"))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--char", type=int, default=ERMAC,
                    help="ochar whose tables to read (default %d = Ermac)" % ERMAC)
    ap.add_argument("--old", action="store_true",
                    help="also print rows 044h/041h, the superseded reading")
    ap.add_argument("--render", metavar="DIR", help="decode the frames to PNG")
    args = ap.parse_args()
    if not args.zip.exists():
        sys.exit("UMK3 romset not found: %s" % args.zip)
    rom = Rom(load_rom(args.zip))

    print("=" * 74)
    print("THE GRAB BOX - program ROM, strike_tables[%d] row %#04x"
          % (args.char, STK_ROW))
    print("=" * 74)
    s = strike(rom, args.char, STK_ROW)
    print("  @%#07x   x %d (%#06x)   y %d (%#06x)   w %d (%#06x)   h %d (%#06x)"
          % (s["off"], s["xoff"], s["xoff"] & 0xFFFF,
             s["yoff"], s["yoff"] & 0xFFFF,
             s["xsize"], s["xsize"] & 0xFFFF,
             s["ysize"], s["ysize"] & 0xFFFF))
    print("  routine %#06x  ->  hit reaction %#04x (r_ermac_slam), block %#04x"
          % (s["routine"], s["routine"] >> 8, s["routine"] & 0xFF))
    print("  damage  %#06x  ->  ZERO: the box only says 'caught you'.  The"
          % s["damage"])
    print("                    reaction applies damage_to_me(9) when he lands.")
    print("\n  206px of reach is not a typo and needs no scaling: MK2 and UMK3")
    print("  measure strike boxes the same way.  Ninja lo kick is x 109 in both;")
    print("  hi punch 77 vs 78; uppercut 77,-19 vs 78,-16.")

    print("\n" + "=" * 74)
    print("THE LANES IT PLAYS - anitab1 of character %d" % args.char)
    print("=" * 74)
    show_lanes(rom, args.char, LANES)
    print("\n  Every offset is ZERO in all three.  That is the tell that the")
    print("  CODE drives the position here - which it does, with oyvel/ograv.")

    if args.old:
        print("\n" + "=" * 74)
        print("SUPERSEDED - what the first port read instead")
        print("=" * 74)
        show_lanes(rom, args.char, OLD_LANES)
        print("\n  Row 044h loops and hangs the body 130px up, which is why it")
        print("  looked right.  It is Jade's fan lift.  Note frame 2 is the")
        print("  same art as ANIM_STUMBLE frame 1, and frame 1 the same as")
        print("  ANIM_ORB_BANGED frame 1 - shared art, different move.")

    print("\n" + "=" * 74)
    print("THE CODE - UMK3 source, quoted verbatim")
    print("=" * 74)
    src = find_src()
    if src is None:
        print("  UMK3 source not found - set UMK3_SRC to its src/ directory.")
        print("  (The ROM half above does not need it.)")
    else:
        print("  %s" % src)
        for fname, func, why in QUOTES:
            print("\n  --- %s:%s %s" % (fname, func, ("- " + why) if why else ""))
            quote(src, fname, func)

    print("\n" + "=" * 74)
    print("WHERE EACH PIECE LANDED IN MK2")
    print("=" * 74)
    for a, b in PORT:
        print("  %-22s -> %s" % (a, b))

    if args.render:
        render(rom, args.char, args.render)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
