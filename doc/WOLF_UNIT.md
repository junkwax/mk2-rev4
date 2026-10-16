# MK2 on the Wolf unit (MK3 / UMK3 board)

One source tree, two boards. `src/WUNIT.ASM` holds `wunit .set 0`:

- **0** - T-unit, MK2's own board. The default; the build is byte-identical to
  the tree before the Wolf port (only the COFF timestamp and the `rom_name`
  stamp differ).
- **1** - Wolf unit. Program ROM for the `umk3` donor set (u54/u63).

The port comes from Asure007's kit in
`Workplace/mk2-rebuild-main/mk2-rebuild-main/` (`src/gow.bat`, `W-EQU.ASM`,
`SYSEQUW.ASM`, `MAINEQUW.ASM`, `DIAGPIC.ASM`, `rom/ff8w.*`,
`rom/merge-wunit.cmd`, `soundw/wolf.bat`).

**Do not run `gow.bat` against this tree.** It works by copying
`SYSEQUW.ASM` / `MAINEQUW.ASM` over `SYSEQU.ASM` / `MAINEQU.ASM`. Our MAINEQU
is ~6,000 lines against his ~1,300, so that copy deletes every feature switch
in the project. His Wolf deltas are carried here as `.if wunit` blocks instead.

## Status (2026-10-06)

| step | state |
|---|---|
| 1. Headers + Asure's code blocks, both boards assemble and link | **done** |
| 2. Packaging into the UMK3 donor set, booted in MAME `umk3` | **done** |
| 3. Inputs | **done** - game code reads T-unit-layout mirrors |
| 4. DIPs, picture position, CPU drawing, video ROM reach above 12 MB | **checked** (below) |
| 5. Packing art above 12 MB (makevrom/LOAD2), a real Wolf board | not started |

What has been run (MAME, `tools/run_wolf_boot_probe.ps1`): boots in ~2s to
the title, the dragon logo, the attract demo fights and the coin screen, all
drawn correctly; two coins + 1P Start reach character select and a fight
(gstate 1 -> 4 -> 7 -> 2); sound plays. `-Inputs`: all 13 inputs land on their
T-unit bit (13/13; `-Negative` 0/13) and P1 Low Punch / Low Kick come out in a
fight 2 frames after the press. Nothing has run on real Wolf hardware.

Space on each board: [WOLF_SPACE.md](WOLF_SPACE.md). What the board offers beyond
space, and what other Wolf games did with it: [WOLF_OPPORTUNITIES.md](WOLF_OPPORTUNITIES.md).

## Building it

```
python build.py && python makerom.py && python makevrom.py && python makesound.py   # T-unit, as always
python makewolf.py                                     # -> rom/wolf/umk3.zip
mame umk3 -rompath rom/wolf                            # or tools/run_wolf_boot_probe.ps1 [-Coin] [-Listen] [-Inputs [-Negative]]
```

`makewolf.py` never touches `src/mk2.out`, the `.OBJ`s or any T-unit file:
it copies `src/` into `tmp/wolf/`, sets `wunit .set 1` in that copy (and tags
`rom_name` with " W"), and assembles there. It never writes
`C:/MAME/roms/umk3.zip` either - `rom/wolf/umk3.zip` is the donor
`C:/MAME/roms/umk3.zip` with 18 of its 27 files replaced:

| UMK3 file | ours |
|---|---|
| u54 / u63 | program ROM, even / odd bytes (the uj12 / ug12 split) |
| u133 ... u122 | the 12 video chips, renamed (table below) |
| u2 ... u5 | sound (next section) |
| u64 (PIC), umk-u110..u121 | **the donor's** - never addressed by MK2 |

`--no-asm` reuses `tmp/wolf/src/mk2.out`; `--retail-sound` skips the custom
audio; `--donor` points at another umk3.zip.

## Wolf-only art (above 12 MB)

A Wolf-only pack is a **bank-1 LOD whose `***>` line is `4000000,1` or above**.
That is LOD form - an IRW header records it, and for bank 1 it runs `02000000h`
below the runtime SAG - so the linear offset is `0x800000 + (base - 0x2000000) / 8`:
`4000000,1` is linear 12 MB, runtime SAG `06000000h`. `tools/make_mk1pit.py`'s
`lod_address()` writes exactly this.

1. Write the LOD with `***> 4000000,1` (or higher - `lod_address(phys)`) and add it to
   `data/IMGBUILD.BAT` like any other pack (`/E`).
2. List its IRW in `wolf_irw_files` in `makevrom.py` - NOT `irw_files`. It
   must sit wholly inside a block MAME's `umk3` loads: `0xC00000-0xFFFFFF`
   (u121..u118) or `0x1400000-0x17FFFFF` (u113..u110); makevrom refuses
   anything else, and anything straddling 12 MB.
3. Include its `.TBL` only under `.if wunit`, so the T-unit never references it.

`makevrom.py` keeps those packs out of the 12 T-unit chips and writes
`rom/wolf_video_hi.bin` (deleted when there are none); `makewolf.py`
interleaves each non-empty 4 MB block into its four chips and keeps the
donor's chips for an empty one. Proven: a known pattern written there reads
back from MAME's video region at 8,192 sample offsets across both blocks,
8,192 / 8,192 (`tools/wolf_video_hi_check.lua`); without it, 28 / 8,192.

## The character endings are back on Wolf (2026-10-11)

The T-unit retired all 12 endings for ROM (doc/ASSET_SPACE_LEDGER.md,
2026-08-11).  On Wolf they play again, retail's routine and text:

- the 24 movie frames (`data/END_*.BIN`, kept on disk) are packed by
  `data/ENDWOLF.LOD` at Wolf CPU `04400000h` - IMAGE BANK 2, linear
  `1480000h` in u113..u110 - and placed by `makewolf.py`, which also refuses a
  bank-0/1 movie inside that CPU range.  `movie_run` (UNZIP.ASM) selects bank 2
  for `[wolf_end_cpu, wolf_end_end)`;
- `zipped_pics` rows `16h-2Dh` (after Sindel's portrait - a new Wolf VS
  portrait goes at `2Eh`); `show_a0_ending` and `end_text_1/2` are under
  `.if wunit`, and a hidden or Wolf-only winner (ochar 12+) skips straight to
  the cast as the T-unit does;
- the two backgrounds (`MKSTORY1`, `MKSTORY2` - `end_h_mod` / `end_v_mod`)
  are in `data/WSTORY.LOD`, which moved down to linear `0xF48000` to take
  them (and up to `0xF60000` on 2026-10-13, when MK1 Kano's pack grew past
  `0xF48000`); `MKSTORY2`'s own palettes are Midway's dev ones, so retail's
  `ORY2PALS` is used (`make_wolf_story.py RETAIL_PALS_WIN`);
- TEST MENU -> UTILITIES -> CHARACTER ENDINGS plays any of them (Midway's own
  viewer, `go_endings`, which nothing linked to).  It ends with the cast, the
  design team and a reset, as the viewer always did.

Proven in mk2wolf.exe on Kung Lao and Jax (`run_wolf_boot_probe.ps1 -Press`
through the menu - see doc/WOLF_OPPORTUNITIES.md W05).

## Program ROM on Wolf: the VS portraits move to image ROM

`makewolf.py` leaves the T-unit's REVX pool (the VS portraits, `MK8MIL.IRW`)
out of program ROM and places the same bytes at video `0FC0000h`; `UNZIP.ASM`
reads them at CPU `05E00000h` with image bank 1 (`vs_base` / `vs_dest`, and a
`movie_run` wrapper that selects the bank and restores bank 0). Wolf program
headroom: 6,270 -> **210,546 bytes**. `makevrom.py` reserves the slot
(`WOLF_RESERVED`). Details and measurements: [WOLF_SPACE.md](WOLF_SPACE.md).

## Sound

The two boards have different DCS sound boards: MK2's is "DCS Audio 2K" (six
512K chips), Wolf's "DCS Audio 8K" (four 1M chips), so the T-unit chips cannot
be copied over. `sound/wolf/U2-U5.ROM` is Asure's PLBUILD of MK2's own sound
for the 8K board - the same MK2.DEF, so the command numbers the game sends are
unchanged. `makewolf.py` patches `sound/stlaugh_patch.txt` (the custom audio)
onto it with DCSEncoder, exactly as `makesound.py` does for the T-unit.

**Proven: all 1,124 tracks decode byte-identical** between
`sound/mk2_stlaugh.zip` (T-unit) and the Wolf set (DCSExplorer
`--extract-tracks` on both, compared sample for sample). Edit
`stlaugh_patch.txt` once; both boards follow.

Two things had to be solved, and both fail SILENTLY:

- **The 3-digit year.** PLBUILD (1994) stamped Asure's U3-U5 headers
  "U3 08/29/125". DCSDecoder's zip loader identifies U3-U9 by a `dd/dd/dd`
  header, so it loaded U2 alone, the encoder wrote a catalog for U2 alone, and
  the board played **nothing** - while reporting "ROM creation succeeded".
  `makewolf.py` rewrites the year in its prototype copy (same length) and
  balances the change in the chip's FF tail, so the DCS checksum (even-byte
  sum | odd-byte sum, each & FF) still matches U2's index.
- **Eight retail streams named by address.** The patch script plays eight
  retail streams as `stream $addr`, and PLBUILD lays them out differently on
  1M chips. They are found in the Wolf set BY CONTENT (48+ byte signature,
  exactly one hit required) and translated in a generated copy of the
  script. A DCS address is `chip<<20 | offset`, offset masked by the chip size,
  so on a 512K chip bit 19 is a MIRROR (`$1B7C1E` is U3+`37C1E`).

The encoder repacks the set into U2-U4 with ~50KB spare; U5 ships empty (FF).

## What changed, and where

| file | change |
|---|---|
| `src/WUNIT.ASM` | new - the switch. Included by SYSEQU **and** MAINEQU, because the fighter modules include only MAINEQU |
| `src/SYSEQU.ASM` | `gsw` / `gsw2` (below). Wolf addresses: colour RAM `01880000h`, `cmapsel`, the I/O ports, sound / sound IRQ, watchdog, coin counters, `secchip`, `vmux`, `b_sirq` 11, `b_sdav` 10, `b_wdog` 8, `syscinit` `1880h`, the DMA registers at `01a00000h` |
| `src/MAINEQU.ASM` | includes `wunit.asm`; nothing else - the button masks are the T-unit's on both boards |
| `src/RAM.ASM` | the two mirror longs `gsw` / `gsw2` (Wolf only) |
| `src/MKINIT.ASM` | Wolf power-up (sec chip, sound reset via coin_counters, watchdog audit, `InitPIC`), Wolf video timings in `initdata`, and `wolf_inputs` (below) |
| 15 game files | every direct input read is `@gsw` / `@gsw2` instead of `@switch` / `@switch2` (75 reads; MKSEL alone is 40) |
| `src/DIAGPIC.ASM` | new, from Asure - PIC init + hardware info screen. Body is `.if wunit`, so on a T-unit build the object is empty and the link is unchanged. In MAKEFILE and mk2.cmd |
| `src/DIAGMENU.ASM` | exports `force_main`, `top_box` for DIAGPIC (Wolf only) |
| `src/DIAGDTST.ASM` | Asure's 25 blocks: PIC/sound power-up checks (`psndtest`, `piccheck`, `sndcheck` restored - this tree had deleted them as dead T-unit code), Wolf board picture, VRAM/chip tables, switch test |

`DIAGDTST.ASM` was spliced by script: Asure's T-unit side had to match ours
line for line between the same neighbours, or the block was placed by hand.
Four were by hand (`cpud2`, `piccheck`/`sndcheck`, `romcheck`, `iromchips`).

### ROM checksums: one table for both boards

`romcheck` on Wolf differs only in the image-bank bits of `sysctrl`: T-unit
bank 1 is bit 7 (`080h`); Wolf banks are bits 8-9 (`rom_map << 8`). The
`iromchips` table is NOT duplicated. The Wolf board picture names its twelve
used sockets with the T-unit labels, so the one table - and `burnfix.py`,
which rewrites it - serves both:

| T-unit | ug14 | uj14 | ug19 | uj19 | ug16 | uj16 | ug20 | uj20 | ug17 | uj17 | ug22 | uj22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Wolf | u133 | u132 | u131 | u130 | u129 | u128 | u127 | u126 | u125 | u124 | u123 | u122 |

This is Asure's own mapping (same checksums, same order), and it is the
video-ROM rename step 2 needs. `get_irom_mode` returns 0 on Wolf, so the
"Circuit Boards" DIP is ignored and `iromchipsnew` / `sramchipsnew` are empty
stand-ins.

## Inputs - one rebuild per frame, no per-site code

The two long input reads swap their HIGH halves between the boards:

| long read | T-unit | Wolf |
|---|---|---|
| `@switch` | sticks + HP/Block/HK \| **coins/start** | sticks + HP/Block/HK \| **LP/LK/run** |
| `@switch2` | **LP/LK** \| DIP switches | DIP switches \| **coins/start** |

But each half keeps its T-unit bit layout: Wolf's coins/start word is the
T-unit's bit for bit (start 18/21, coins 16/17/23/24 once in the high half),
and Wolf's LP/LK word is the T-unit's LP/LK word. So nothing needs Wolf masks
- only the halves need putting back:

- `gsw` / `gsw2` (SYSEQU.ASM) are what **game code** reads. On the T-unit they
  are aliases of `switch` / `switch2`, so that build does not change.
- On Wolf they are two longs in RAM (RAM.ASM), rebuilt every frame by
  `wolf_inputs` (MKINIT.ASM) as `gsw = IN0 | IN2<<16`, `gsw2 = IN1 | DSW<<16`.
  `swscan` calls it first thing in the display interrupt, before anything reads
  them, and it runs once more straight after the power-up RAM clear (which
  would otherwise leave every button reading as held).
- The T-unit switch table and every T-unit mask then work on both boards.
  Asure's Wolf switch table and Wolf mask set (and a first cut of this port's
  `WOLFBTN.ASM`) are not used.
- **Diagnostics read the real ports**, except where they run with interrupts
  on. DIAGDTST's power-up tests poll with interrupts off (`dint`), when the
  mirrors are not refreshed, so those keep `@switch` / `@switch2`. The test
  menu's SWITCH TEST and the volume screen run with the display interrupt
  live, so they read `@gsw` / `@gsw2` like the game.

**New code reads `@gsw` / `@gsw2`.** A new `@switch` read in game code is a
Wolf bug that the T-unit build cannot show.

Rig: `tools/run_wolf_boot_probe.ps1 -Inputs` presses each button in attract
mode and requires exactly its T-unit bit to clear in the mirrors (13/13), then
in a fight requires P1 Low Punch / Low Kick to set `p_action` 0102 / 0104.
`-Negative` swaps the two mirror addresses and must fail (0/13).

## Checked and closed

- **DIP switches - no change needed.** MAME's `mk2` and `umk3` DSW ports are
  the same layout bit for bit, so `read_dip` decodes every switch UMK3 has.
  UMK3 does not declare three of MK2's: `0x0100` Circuit Boards (ignored on
  Wolf), `0x0800` "Comic Book Offer" = our **back-block**, `0x2000` Low Blows.
  Measured, the Wolf DIP word reads `FD7D`: the undeclared bits read 1, which
  is MK2's default for all three (back-block on, low blows on), and the game's
  own flags agree (`f_no_bkblk` 0, `f_no_lb` 0). On a real board they are
  spare UMK3 switch positions, so an operator can still set them.
- **`dpytap` - no Wolf value needed.** The same scripted run on both boards
  (`run_wolf_boot_probe.ps1 -Game umk3|mk2 -Coin`) gives pixel-identical frames
  from select through the VS screen - same position, no horizontal offset. The
  early attract frames differ only because Wolf boots ~111 frames later (PIC
  init and the sound-board reset wait), so the two show different moments.
- **Long run: stable.** 30,000 frames on each board, same script
  (`run_wolf_boot_probe.ps1 -Coin -Frames 30000 -Peek illop_count`): both go
  select -> fight -> next round -> fight -> continue -> game over -> attract
  and cycle attract to the end; `illop_count` stays 0 on both.
- **Test menu: works, and its SWITCH TEST was wrong until fixed.** Menus,
  navigation and the audit pages behave the same on both boards ("W" on the
  version line). The switch test drew a phantom held button at rest and
  missed Start / Low Punch / Low Kick: Asure's Wolf branch read the real
  ports against a button table laid out for the T-unit. It now reads
  `@gsw` / `@gsw2` like the game (the display interrupt keeps them current
  while that loop spins - measured), and lights the same buttons as the
  T-unit. Rig: `-Press "600:Service Mode:10","900:P1 High Punch:6",...`.
  The T-unit shows TEST lit after the menu is entered because MAME's `mk2`
  latches "Service Mode"; UMK3's is momentary, and held it lights TEST too.
- **Power-up self test (DIP "Powerup Test" on): passes end to end.** It
  stopped at RAM CHIPS BAD (u36/u37): the colour-RAM test still pointed at the
  T-unit's `01800000h`, which on Wolf is `vmux`, the security chip. `vramchips`
  and `palchips` now carry MK3's own Wolf tables (colour RAM `01880000h`, u36
  7 bits wide, the Wolf picture's chip numbers). Then the ROM check: u54/u63
  are landed on `cksum1`/`cksum2` by `makewolf.py` (burnfix.py's
  `force_lane`, FF filler in the dead tail), and the twelve video sums are
  written into the WOLF COPY of `iromchips` from the chips being shipped - so
  every Wolf package passes its own test whatever state `src/`'s table is in.
  Measured: all 14 ROMs good, sound section checked, the info screen ("MK2 ON
  WOLF UNIT", sound system version), then the game. Rig:
  `run_wolf_boot_probe.ps1 -Dip "Powerup Test=512" -Shots ...` (sets the DIP
  and soft-resets once). **`src/`'s own `iromchips` is stale against the
  current art** - the T-unit's burn flow (`burnfix.py`) still fixes that one.
- **Game speed: identical.** MAME's `mk2` and `umk3` screens are both
  54.706840 Hz at an 8 MHz pixel clock (htotal 506, vtotal 289), so one tick
  per refresh runs at exactly the T-unit's rate and every timing note holds.
- **CMOS (adjustments, audits, high scores): no change.** Same base
  (`01400000h`), same one-shot unlock (`wp_unlock` `1480000h`) and the same page
  bits (`sysctrl` 6-7) as MK3's own Wolf code.
- **Every fight stage, forced on Wolf, plays.** All 17 - 0-9, 0Ah, 16h
  (Outer Haven), 18h (Yoteigai Tor), 19h-1Ch (THE CAVE, THE PIT, THE WARRIOR
  SHRINE, THE THRONE ROOM) - load into a running fight with `illop_count` 0
  and draw correctly (contact sheet `tmp/wolf_stages/sheet.png`). Rig:
  `run_wolf_boot_probe.ps1 -Coin -Frames 4200 -Poke curback=N -PokeStates 4,7`.
  A 200,000-frame attract soak (about an hour of game time, stages 0-8 in the
  demos) has no illegal-opcode recovery and the tick never stalls.
- **CPU drawing through the colour map works.** The combo readout ("5 HITS",
  "100%") is CPU-drawn by the geometry pass and comes out identical on both.
- **Video ROM above 12 MB is reachable** - see [WOLF_SPACE.md](WOLF_SPACE.md)
  (`tools/run_wolf_vrom_reach_test.ps1`, PASS to +23 MB).

## Not ported / open

- Asure's alternative attract tune (`042h`) and DIAGMENU sound-test list were
  not taken; the game plays MK2's own tunes on both boards.
- The MAP-plane write path of `palrect` / `cpu_patch` (MKDISP) is NOT bit 5
  on Wolf: the colour-map plane is SYSCTRL bit 11 (`PALENB`, WWF's SYS.EQU and
  MAME agree), and `syscinit` `1880h` already has bit 5 clear, so both would
  write the PIXEL plane. Nothing arms either today. See
  [WOLF_OPPORTUNITIES.md](WOLF_OPPORTUNITIES.md) W01.
- `DIAGPIC`'s hardware screen compares the PIC's game number against MK3's
  439; UMK3's PIC reports something else. Display only, not a boot gate.
