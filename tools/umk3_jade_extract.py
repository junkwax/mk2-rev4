#!/usr/bin/env python3
"""Extract Jade's boomerang (Razor-Rang) data straight out of the UMK3 arcade ROM.

Everything this prints about art, lanes and damage is read from `umk3.zip`'s
program ROM - no values are hardcoded from a movelist or a wiki.  The
behavioural half (trajectory constants, tick counts, block bounce) comes from
the UMK3 PS1 C source, which writes the *arcade* values as literals and scales
them at compile time (SYSTEM.H: SCX/SCY are SCF_X=80% / SCF_Y=85% of arcade),
so the literal in that source IS the arcade number.

    python tools/umk3_jade_extract.py                 # full report
    python tools/umk3_jade_extract.py --tbl           # JADERANG.TBL-shaped output

How the anchors were found (all three agree, which is what makes this safe):

  1. The image records are 7 words - .word W,H,anix,aniy / .long SAG /
     .word control - exactly MK2's layout (compare src/*.TBL).  Scanning the
     whole 1MB ROM for a run whose W/H match our own BRANG4-9 finds exactly
     ONE hit.
  2. lia_anitab2[2] (ANIM_JADE_ZAP) and [4] (ANIM_BOOMERANG) sit 2 slots
     apart in that table, matching MKGUYS.H's 0x02 / 0x04.
  3. Strike index 0x14 - the one `projectile_flight_call(obj,0x14)` uses - has
     strike routine 0x6800, and MKREACT.C lists `r_boomerang` at reaction 0x68.
"""
import argparse
import struct
import sys
import zipfile
from pathlib import Path

ROM_ZIP = Path(r"C:\MAME\roms\umk3.zip")
EVEN = "l1.2_mortal_kombat_3_u54_ultimate.u54"
ODD = "l1.2_mortal_kombat_3_u63_ultimate.u63"
BASE = 0xFF800000          # TMS34010 bit address of program ROM byte 0

# --- anchors, derived by the scans documented in the module docstring --------
IMG_BLOCK = 0x097F4E       # first boomerang image record (REL1)
LANE_THROW = 0x0254A4      # lia_anitab2[2]  ANIM_JADE_ZAP
LANE_SPIN = 0x025516       # lia_anitab2[4]  ANIM_BOOMERANG
ANITAB2 = 0x022FB4         # lia_anitab2 base (slot 0)
STRIKE_TABLES = 0x05E490   # master strike_tables array
STK_LIA = 0x05E6D0         # strike_tables[15/16/17] - Kitana/Jade/Mileena

# our JADERANG.TBL names, in UMK3 image-table order
IMG_NAMES = [
    ("REL1", "BRANG1"), ("REL2", "BRANG2"), ("REL3", None),
    ("REL4", "BRANG3"), ("SPIN1", "BRANG4"), ("SPIN2", "BRANG5"),
    ("SPIN3", "BRANG6"), ("SPIN4", "BRANG7"), ("SPIN5", "BRANG8"),
    ("SPIN6", "BRANG9"), ("SPIN7", None), ("SPIN8", None),
    ("TRAIL1", "BRTRAIL1"), ("TRAIL2", "BRTRAIL2"), ("TRAIL3", "BRTRAIL3"),
    ("TRAIL4", "BRTRAIL4"), ("TRAIL5", "BRTRAIL5"), ("TRAIL6", "BRTRAIL6"),
]

ANI_CMD = {1: "ani_jump", 2: "ani_flip", 3: "ani_adjustx", 4: "ani_adjustxy",
           5: "ani_nosleep", 6: "ani_calla", 7: "ani_sound", 8: "ani_ochar_jump",
           9: "ani_flip_v", 10: "ani_offset_xy", 11: "ani_sladd", 12: "ani_slani",
           13: "ani_swpal", 14: "ani_slani_sleep", 15: "ani_ochar_sound"}

# The two strike records worth pulling, and the reaction each routine word
# points at.  Both were identified the same three-way way: the C source names
# the index, the routine word's high byte is the reaction, and MKREACT.C's
# table says which reaction that is.
STRIKES = [
    (0x14, "projectile_flight_call(obj,0x14) - the boomerang", "r_boomerang"),
    (0x10, "strike_check_a0(obj,0x10) - the shadow kick", "r_jade_prop"),
]

# prop_do_jade_prop (MKPROP.C) - what we call the Blazing Nitro Kick.
BEHAVIOUR_PROP = [
    "reached by do_body_propell(PROP_JADE_PROP = 0x18)",
    "",
    "launch  init_special_act(ACT_JADE_PROP = 0x217)",
    "        player_swpal(jade_bright_p)     full-body flash to bright green",
    "        ochar_sound(6) = ST_JADE_PROP",
    "        create_fx(FX_JADE_SMOKE = 0x30)",
    "        get_char_ani(ANIM_TABLE1, ANIM_LOKICK = 0x12)",
    "                                        NO unique art - it is the",
    "                                        universal low kick at dash speed",
    "        init_anirate(1); towards_x_vel(0080000h)      8 px/tick",
    "windup  5 ticks, next_anirate each, NO strike check",
    "        then 1 more tick and the first strike_check_a0(0x10)",
    "active  7 ticks: damping + a strike check every tick",
    "recover p_action = ACT_ICHARGE_SD (0x605); 8 ticks damping only",
    "        stop_me; process_sleep(020h); reaction_exit",
    "damping oxvel -= oxvel>>3  per tick (exponential)",
    "on hit  jade_prop_hit: ANIM_LOKICK's last frame, stop_me,",
    "        sleep 020h blocked / 010h on a clean hit, reaction_exit",
    "react   r_jade_prop: shake_a11(6,6), group_sound(2), rsnd_big_smack,",
    "        flight(060000h, -040000h, 06000h, 5, ANIM_KDOWN),",
    "        land_on_my_back   -> a knockdown",
    "drone   q_jade_prop refuses if his action is FK_SD / PUNCHED / SWEEP_SD,",
    "        or his p_hit >= 2, or l_block_fk is younger than 020h",
]

BEHAVIOUR = [
    "do_proj_jade_zap_med  jzap3(0)              straight",
    "do_proj_jade_zap_hi   jzap3(-SCY(0xc000))   oyvel -= 0c000h per tick (rises)",
    "do_proj_jade_zap_lo   jzap3(SCY(0x5000))    oyvel += 05000h per tick (dips)",
    "do_proj_jade_zap_ret  jzap3(1)              sentinel: flip oxvel once off screen",
    "",
    "throw   sleep 6, mframew 4, spawn, sleep 020h, mframew 3 (part 2)",
    "flight  set_proj_vel(0090000h, anirate 2)   9 px/tick, 2 ticks/frame",
    "blocked init_anirate(2); oyvel = -030000h; oxvel = -oxvel",
    "trail   spawn every 2 ticks (p_store2), each lives framew(3) = 3 ticks",
    "hit     r_boomerang: shake_a11(4,6), BLOOD_BOOMER x7, stumble back 040000h",
]


def load_rom(path):
    with zipfile.ZipFile(path) as z:
        even, odd = z.read(EVEN), z.read(ODD)
    if len(even) != len(odd):
        sys.exit("program ROM halves differ in size")
    flat = bytearray(len(even) * 2)
    flat[0::2] = even
    flat[1::2] = odd
    return bytes(flat)


class Rom:
    def __init__(self, data):
        self.d = data

    def u16(self, o):
        return struct.unpack_from("<H", self.d, o)[0]

    def s16(self, o):
        return struct.unpack_from("<h", self.d, o)[0]

    def u32(self, o):
        return struct.unpack_from("<I", self.d, o)[0]

    def off(self, bitaddr):
        """bit address -> byte offset, or None if it isn't in program ROM"""
        if not (BASE <= bitaddr <= 0xFFFFFFFF) or (bitaddr - BASE) % 8:
            return None
        b = (bitaddr - BASE) // 8
        return b if 0 <= b < len(self.d) - 14 else None

    def image(self, o):
        return dict(off=o, w=self.u16(o), h=self.u16(o + 2),
                    anix=self.s16(o + 4), aniy=self.s16(o + 6),
                    sag=self.u32(o + 8), ctrl=self.u16(o + 12))

    def strike(self, o):
        return dict(off=o, xoff=self.s16(o), yoff=self.s16(o + 2),
                    xsize=self.s16(o + 4), ysize=self.s16(o + 6),
                    routine=self.u16(o + 8), damage=self.u16(o + 10),
                    sound=self.u16(o + 12))

    def lane(self, o, limit=40):
        """walk an animation lane: frames, embedded commands, part terminator"""
        out = []
        i = 0
        while i < limit:
            v = self.u32(o + 4 * i)
            if v == 0:
                out.append(("part_end", None, None))
                break
            if v in ANI_CMD:
                out.append(("cmd", ANI_CMD[v], self.u32(o + 4 * (i + 1))))
                i += 2
                continue
            out.append(("frame", v, self.off(v)))
            i += 1
        return out

    def pieces(self, o, limit=12):
        """a lane frame points at a piece list: .long img... terminated by 0"""
        out = []
        for i in range(limit):
            v = self.u32(o + 4 * i)
            if v == 0:
                break
            out.append(self.off(v))
        return out


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--tbl", action="store_true",
                    help="emit JADERANG.TBL-shaped anipoint lines")
    args = ap.parse_args()

    if not args.zip.exists():
        sys.exit("UMK3 romset not found: %s" % args.zip)
    rom = Rom(load_rom(args.zip))

    imgs = {}
    for i, (umk, ours) in enumerate(IMG_NAMES):
        imgs[umk] = (rom.image(IMG_BLOCK + 14 * i), ours)

    if args.tbl:
        print("; UMK3 arcade anipoints - src/JADERANG.TBL shape")
        for umk, (r, ours) in imgs.items():
            if not ours:
                continue
            print("%s:\t; UMK3 %s" % (ours, umk))
            print("\t.word   %d,%d,%d,%d" % (r["w"], r["h"], r["anix"], r["aniy"]))
        return 0

    print("=" * 74)
    print("UMK3 Jade Razor-Rang - extracted from " + args.zip.name)
    print("=" * 74)

    print("\n-- image records (bit addr = 0xFF800000 + byteoff*8) " + "-" * 20)
    print("%-8s %-9s %8s  %9s %5s %5s  %10s %6s"
          % ("UMK3", "ours", "byte", "WxH", "anix", "aniy", "SAG", "ctrl"))
    for umk, (r, ours) in imgs.items():
        print("%-8s %-9s 0x%06x  %4dx%-4d %5d %5d  0%07xh 0%04xh"
              % (umk, ours or "-", r["off"], r["w"], r["h"], r["anix"],
                 r["aniy"], r["sag"], r["ctrl"]))

    byoff = {r["off"]: (umk, ours) for umk, (r, ours) in imgs.items()}

    def label(o):
        if o in byoff:
            umk, ours = byoff[o]
            return umk + ((" (=our %s)" % ours) if ours
                          else " [UNUSED by any lane]")
        if o is None:
            return "?"
        r = rom.image(o)
        return "img @0x%06x %dx%d ani %d,%d" % (o, r["w"], r["h"],
                                                r["anix"], r["aniy"])

    lanes = (("ANIM_JADE_ZAP  (lia_anitab2[2]) - the throw", LANE_THROW, 2),
             ("ANIM_BOOMERANG (lia_anitab2[4]) - the flight", LANE_SPIN, 4))
    for name, addr, slot in lanes:
        if rom.u32(ANITAB2 + 4 * slot) != BASE + addr * 8:
            sys.exit("anitab2 slot %d no longer points at 0x%06x" % (slot, addr))
        print("\n-- %s %s" % (name, "-" * max(0, 52 - len(name))))
        print("   lane @0x%06x" % addr)
        for kind, a, b in rom.lane(addr):
            if kind == "part_end":
                print("     .long 0                      ; end of part")
            elif kind == "cmd":
                tgt = rom.off(b)
                extra = ""
                if a == "ani_jump":
                    extra = " -> 0x%06x" % tgt
                    if tgt == addr:
                        extra += " (loop to lane start)"
                elif a == "ani_calla":
                    extra = " -> routine @0x%06x (boomerang_adjust)" % tgt
                elif a in ("ani_sladd", "ani_slani"):
                    extra = " -> slave " + ", ".join(
                        label(p) for p in rom.pieces(tgt))
                print("     .long %-14s%s" % (a, extra))
            else:
                print("     .long frame @0x%06x  = " % b
                      + " + ".join(label(p) for p in rom.pieces(b)))

    print("\n-- strike record " + "-" * 55)
    tbl = rom.off(rom.u32(STRIKE_TABLES + 4 * 16))
    if tbl != STK_LIA:
        sys.exit("strike_tables[16] moved")
    shared = [i for i in range(24)
              if rom.off(rom.u32(STRIKE_TABLES + 4 * i)) == STK_LIA]
    print("   strike_tables[16] (FT_JADE) -> 0x%06x, shared by ochar %s"
          "  (Kitana/Jade/Mileena)" % (tbl, shared))
    for idx, who, reaction in STRIKES:
        s = rom.strike(rom.off(rom.u32(tbl + 4 * idx)))
        print("   entry 0x%02x  %s  @0x%06x:" % (idx, who, s["off"]))
        print("     x offset  0%03xh  (%d)" % (s["xoff"], s["xoff"]))
        print("     y offset  %5d" % s["yoff"])
        print("     x size    0%03xh  (%d)" % (s["xsize"], s["xsize"]))
        print("     y size    0%03xh  (%d)" % (s["ysize"], s["ysize"]))
        print("     routine   0%04xh  hit reaction 0%02xh = %s,"
              " block reaction 0%02xh"
              % (s["routine"], s["routine"] >> 8, reaction,
                 s["routine"] & 0xFF))
        print("     damage    0%04xh  = %d on hit / %d on block"
              "   (UMK3 full_strength = 0a6h/166)"
              % (s["damage"], s["damage"] >> 8, s["damage"] & 0xFF))
        print("     sound     0%04xh" % s["sound"])

    print("\n-- boomerang behaviour (UMK3 PS1 C source; literals are arcade"
          " values) ---")
    for line in BEHAVIOUR:
        print("   " + line)

    print("\n-- shadow kick / \"nitro kick\" behaviour " + "-" * 32)
    for line in BEHAVIOUR_PROP:
        print("   " + line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
