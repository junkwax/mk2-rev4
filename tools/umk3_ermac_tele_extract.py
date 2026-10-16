#!/usr/bin/env python3
r"""Read ERMAC'S TELEPORT PUNCH out of the UMK3 arcade ROM.

Everything the MK2 port needs to mimic the arcade move: the strike box and the
damage, read straight out of `C:\MAME\roms\umk3.zip`.

    python tools/umk3_ermac_tele_extract.py            # the report
    python tools/umk3_ermac_tele_extract.py --all      # every row of the table

## Where the numbers come from, and which ones the ROM actually holds

The UMK3 C source (Workplace/UltimateMortalKombat3) names the move and its
index; the ROM supplies the record those names point at.  Both halves matter -
the source alone would be a decompilation taken on trust, and the ROM alone
would be an unlabelled table.

    void prop_do_ermac_tele(void)                       // PROP_ERMAC_TELE 0x1b
    {
        if (am_i_airborn(obj)==SYSTEM_CARRY_CLR)
            create_fx(FX_INVISO_POOF);                  // GROUND ONLY
        set_inviso(obj);                                // no decoy - he VANISHES
        stack_jump(prop_do_scorp_tele);
    }

    void prop_do_scorp_tele(void)
    {
        ...
        flight_call(obj,SCX(0xa0000),-SCY(0x30000),SCY(0x5000),3,
                    (0x0001<<16)|ANIM_SCORP_TELE);
    }

## The high word of that last argument is the TABLE, not the part

`(0x0001<<16)` used to be read here as "start at part 1".  It is not.  MK2's
own `flight_call` (MOVES.ASM, label `flgt6`) is the routine UMK3 inherited,
and it decodes the argument like this:

        flgt6   move    a9,a9
                jrn     flgt5           ; negative = animation already set up
                movi    get_char_ani,a0
                move    a9,a1
                zext    a9,w            ; low word  = the ROW
                srl     16,a1           ; high word = which TABLE
                jreq    flgt4           ;   0 -> TABLE1
                movi    get_char_ani2,a0 ;  else -> TABLE2

So the teleport plays **TABLE2 row 8** - `ANIM_SCORP_TELE` sits in MKGUYS.H's
"male ninjas" block alongside `ANIM_REP_SLIDE` and `ANIM_ERMAC_SLAM`, which
are TABLE2 specials - and there is exactly one part to it.

Read out of the ROM (male_ninja_anitab2 is at byte 0x26c6a, row 8 -> 0x27a7a),
that lane is a near-clone of `ANIM_FLIPPUNCH` (anitab1 row 0x18, at 0x27a12):

    ANIM_SCORP_TELE   f0  56x92 069b8d44                      <- same
                      f1  20x84 069bd080 | 57x100 069be6fa    <- same
                      f2  47x22 069d29e2 | 62x87 069d354e | 38x53 069d7c3a
    ANIM_FLIPPUNCH    f0  56x92 069b8d44
                      f1  20x84 069bd080 | 57x100 069be6fa
                      f2  40x45 069c27d6 | 45x95 069c3856 | 40x50 069c79e8
                      part 1: f1, f0 (the flip punch comes back; the teleport
                              has no part 1 because it never does)

The first two frames are shared art; the THIRD is not.  The arcade teleport
holds a **purpose-drawn extended pose** for the whole flight, and that is the
frame the player actually sees, because the lane finishes (3 frames at anirate
3 = 9 ticks) well before the warp and the animator parks on the last frame.

MK2 has no equivalent of that third frame.  do_decoy hands flight_call
`movi 01fh,a9` - TABLE1 row 1fh, `a_njflippunch` - so Ermac holds the FLIP
PUNCH's own last frame (NJFLIPUNCH3, 67x52 + 45x86 + 36x31) instead.  Measured
in the running ROM (tools/ermac_tele_anim_probe.lua): NJFLIPUNCH1 at ticks
1-3, 2 at 4-6, 3 from tick 7 onward - and he is invisible until tick 11, so
every animated frame is spent hidden and the only pose ever seen is the held
one.  On an AIR teleport that hold runs 48 ticks (0.88 s).

    void sctele_scalla_2(void)
    {
        if (strike_check_a0(obj,0x17)==SYSTEM_CARRY_CLR) return;   // <-- 0x17
        ...
    }

So the FLIGHT constants are code immediates (recoverable from the source, and
listed below for the port), and the ATTACK is strike row **0x17** of the
caster's own table - which is data, and is what this script reads.

`strike_tables` is at byte `0x05E490`, the anchor `tools/umk3_jade_extract.py`
established and used to pull Kitana/Jade/Mileena's records.  Entries are 4
bytes (`get_char_stk` does `sll 5` on the index - 32 BITS), indexed by ochar,
and `FT_ERMAC` is 20 (MKGAME.H).

Cross-check built in: Scorpion (18), Ermac (20) and Human Smoke (22) all run
`prop_do_scorp_tele`, so if row 0x17 is really the teleport punch they should
carry the same or near-identical record.  The script prints all three.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from umk3_jade_extract import load_rom, Rom, ROM_ZIP, BASE  # noqa: E402

STRIKE_TABLES = 0x05E490      # master strike_tables array (umk3_jade_extract)
STK_ROW_TELE = 0x17           # sctele_scalla_2: strike_check_a0(obj,0x17)

CHARS = [
    (18, "FT_SCORPION"), (20, "FT_ERMAC"), (22, "FT_OLDSMOKE (human smoke)"),
    (19, "FT_REPTILE"),  # not a teleporter - a control, row 0x17 should differ
]

# The flight/timing immediates, straight out of prop_do_scorp_tele.  Not in the
# ROM as data - they are MOVI operands in the compiled routine - so they are
# quoted from the source rather than read here, and labelled as such.
FLIGHT = [
    ("x velocity",   "SCX(0xa0000)",  "10.0 px/tick away from the opponent"),
    ("y velocity",   "-SCY(0x30000)", "3.0 px/tick upward at launch"),
    ("gravity",      "SCY(0x5000)",   "0.3125 px/tick/tick"),
    ("anirate (a3)", "3",             "3 ticks per animation frame"),
    ("lane",         "TABLE2 row ANIM_SCORP_TELE (8)",
                     "(0x0001<<16) selects TABLE2 - it is NOT a part number"),
    ("sound",        "ochar_sound(0xc)", "ST_ERMAC_TELE = $375 for Ermac"),
    ("poof sound",   "FX_INVISO_POOF",   "ST_ERMAC_POOF = $2f3"),
]

# sctele_scalla_2, after the strike connects.
ON_HIT = [
    ("victim grounded", "process_sleep(6);  flight(obj,0,SCY(0x10000),SCY(0x8000),30,-1)"),
    ("victim airborne", "process_sleep(4);  flight(obj,0,SCY(0x10000),SCY(0xc000),30,-1)"),
    ("blocked",         "scorpion_tele_blocked(obj) before the flight"),
]


def read_table(rom, ochar):
    slot = STRIKE_TABLES + 4 * ochar
    tbl_bit = rom.u32(slot)
    tbl = rom.off(tbl_bit)
    return slot, tbl_bit, tbl


def read_row(rom, tbl, row):
    rec_bit = rom.u32(tbl + 4 * row)
    off = rom.off(rec_bit)
    return rec_bit, (rom.strike(off) if off is not None else None)


def show(rom, ochar, name, rows):
    slot, tbl_bit, tbl = read_table(rom, ochar)
    print(f"\n{name}  (ochar {ochar})")
    print(f"  strike_tables[{ochar}] @ {slot:#07x} -> bit {tbl_bit:#010x} "
          f"-> table @ {tbl if tbl is None else format(tbl, '#07x')}")
    if tbl is None:
        print("  table pointer is not in program ROM - anchor or index is wrong")
        return
    for row in rows:
        rec_bit, s = read_row(rom, tbl, row)
        if s is None:
            print(f"  row {row:#04x}: bit {rec_bit:#010x} (not in program ROM)")
            continue
        hit, blk = s["damage"] >> 8, s["damage"] & 0xFF
        # BOTH bases, deliberately.  The box fields are decimal here and the
        # MK2 .word that receives them is hex, and three of these four happen
        # to look the same either way (17/0x11, 54/0x36, 42/0x2a) while the
        # x offset does not (76 vs 0x76 = 118).  Printing only decimal is how
        # you write 076h into MKSTK.ASM and give the move 42 extra pixels of
        # reach without noticing.
        print(f"  row {row:#04x} @ {s['off']:#07x}: box"
              f"  x {s['xoff']:>4} ({s['xoff'] & 0xffff:#06x})"
              f"  y {s['yoff']:>4} ({s['yoff'] & 0xffff:#06x})"
              f"  w {s['xsize']:>4} ({s['xsize'] & 0xffff:#06x})"
              f"  h {s['ysize']:>4} ({s['ysize'] & 0xffff:#06x})"
              f"   routine {s['routine']:#06x}"
              f"   damage {s['damage']:#06x} = {hit} hit / {blk} block"
              f"   sound {s['sound']:#06x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--all", action="store_true",
                    help="dump every row of Ermac's strike table, not just 0x17")
    args = ap.parse_args()

    if not args.zip.exists():
        sys.exit(f"UMK3 ROM not found: {args.zip}")
    rom = Rom(load_rom(args.zip))
    print(f"UMK3 program ROM: {len(rom.d)} bytes, base bit {BASE:#010x}")
    print(f"strike_tables @ {STRIKE_TABLES:#07x};  teleport punch = row {STK_ROW_TELE:#04x}")

    rows = list(range(0x20)) if args.all else [STK_ROW_TELE]
    for ochar, name in CHARS:
        show(rom, ochar, name, rows)

    print("\nFlight constants - prop_do_scorp_tele (CODE immediates, not ROM data):")
    for k, v, note in FLIGHT:
        print(f"  {k:<14} {v:<16} {note}")
    print("\nAfter the strike connects - sctele_scalla_2:")
    for k, v in ON_HIT:
        print(f"  {k:<18} {v}")


if __name__ == "__main__":
    main()
