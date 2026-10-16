# ROM space: T-unit vs Wolf unit

How much room the Wolf unit (the MK3 / UMK3 board) gives MK2 over the T-unit,
per ROM type. Measured on this tree on 2026-10-06 (`tools/rom_space_report.py`,
`makerom.py`, DCSEncoder's chip report, `makewolf.py`). See
[WOLF_UNIT.md](WOLF_UNIT.md) for the port itself.

Three different numbers matter, and they are not the same:

- **Free now** - what is left in this build.
- **In MAME** - what the `umk3` driver will actually load. It only loads the
  chips it declares, so this is the ceiling for anything you test in MAME.
- **On the board** - socket count on real Wolf hardware. Taken from Williams'
  own Wolf board diagram in `DIAGDTST.ASM` (Asure's port), **not yet confirmed
  on a real board**.

## Update 2026-10-11 - the table below is the 2026-10-06 snapshot

Since then the Wolf content (Sonya, Sindel, Kano, the MK1/UMK3 stages, the
character endings) has spent most of it.  Measured on the 2026-10-11 build:

| | T-unit | Wolf in stock MAME | Wolf in `mk2wolf.exe` / on a board |
|---|---|---|---|
| program headroom | 8,810 bytes | 81,856 bytes | 81,856 bytes |
| video free | (unchanged) | **4.49 MB** (u121..u118 804,474; u113..u110 3,681,732) | **17.07 MB** - the patched driver now loads the twelve empty sockets too (u117..u114, u109..u102) |
| `.bss` headroom under the stack | 355,306 bytes | about the same | about the same |

The character endings take 362,206 bytes at linear `1480000h` (image bank 2,
`makevrom.py WOLF_RESERVED`).  The `.bss` figure is new: `stckst` moved from
`0117FFF0h` to `013F72F0h`, using RAM that was never touched on either board.
See [WOLF_OPPORTUNITIES.md](WOLF_OPPORTUNITIES.md) "Status".

## Summary

| | T-unit (MK2 as shipped) | Wolf in MAME (`umk3`) | Wolf board (sockets) |
|---|---|---|---|
| **Program ROM** | 1 MB | 1 MB | 1 MB |
| program headroom now | 8,416 bytes | **210,546 bytes** | **210,546 bytes** |
| **Video ROM** | 12 MB (12 x 1MB) | 20 MB (20 x 1MB) | 32 MB (32 x 1MB) |
| video free now | 47,310 bytes | **8.05 MB** (DMA reach proven) | **20.05 MB** (DMA reach proven) |
| **Sound ROM** | 3 MB (6 x 512KB) | 4 MB (4 x 1MB) | 8 MB (8 x 1MB) |
| sound free now | 48,888 bytes | **1.05 MB** | **5.05 MB** |

## Program ROM - ~200 KB more, by moving the VS portraits

Both boards map program ROM at `FF800000-FFFFFFFF`: 1 MB, the CPU's ROM
window, whatever chips are fitted. The T-unit spends ~200 KB of it on the
REVX pool - the VS-screen portraits, which `UNZIP.ASM` unpacks with the CPU and
which must sit where the T-unit CPU can read them.

The Wolf CPU reads image ROM through an 8 MB window at `02000000h-05FFFFFFh`,
banked by `sysctrl` bits 8-9 (bank *b* = video bytes `b*8MB + offset`; banks
0-2 measured exact, `tools/wolf_cpu_irom_window_check.lua`). So on Wolf the
portraits live in image ROM - linear `0FC0000h`, CPU `05E00000h` in bank 1 -
`movie_run` selects that bank around the unpack (MK3's own method) and puts
bank 0 back, and `makewolf.py` leaves the REVX pool out of program ROM.

- T-unit: code ends at `0xffe5f900`, REVX pool at `0xffe70000` ->
  **8,416 bytes** of headroom (unchanged).
- Wolf: **210,546 bytes** from the end of `.data` to the checksum tail window.

Proven: the two-player VS screen (Liu Kang vs Reptile portraits) is
pixel-identical on both boards. A NEW portrait must fit the 256 KB Wolf slot
(`0FC0000h-0FFFFFFh`, 199,508 bytes used) or `movie_run`'s bank test must be
widened to wherever it goes.

## Video ROM - the real gain

| region offset | T-unit sockets | Wolf sockets | MAME `umk3` loads? |
|---|---|---|---|
| 0x000000-0xBFFFFF | ug14..uj22 (12) - all used by MK2 | u133..u122 (12) - MK2's art, renamed | yes |
| 0xC00000-0xFFFFFF | - | u121..u118 (4) | **yes** (umk-u118..u121) |
| 0x1000000-0x13FFFFF | - | u117..u114 (4) | no - UMK3 leaves them empty |
| 0x1400000-0x17FFFFF | - | u113..u110 (4) | **yes** (umk-u110..u113) |
| 0x1800000-0x1FFFFFF | - | u109..u102 (8) | no |

- **In MAME: +8 MB.** The donor zip's `umk-u110..u113` and `umk-u118..u121`
  are slots MAME already loads; we currently ship them as UMK3's art, which MK2
  never addresses. Replace them and MAME draws them.
- **On the board: +20 MB** if all 32 sockets are populated. Using
  u114-u117 or u102-u109 needs either real hardware or a local MAME driver
  change, since `umk3` will not load undeclared chips.

**The DMA reaches all of it - proven.** `tools/run_wolf_vrom_reach_test.ps1`
moves one live title-screen sprite (`thunder1`, MKFX.TBL) up the video
region at runtime - pixels copied, header repointed - and requires the frame
to come out pixel-identical to an untouched run, with a repointed-but-not-
copied run as the control that must differ. PASS at +12 MB (u118-u121),
+16 MB (u114-u117), +20 MB (u110-u113) and +23 MB; the DMA was handed the
moved SAG (`0A725AF8` .. `0FF25AF8`) 56 times in each, the original never.
MAME's video region is 32 MB, so that is the whole board's address space.

**How MK2 addresses it - two banks.** A SAG is a BIT address from
`02000000h`, and the DMA control word in each image header picks a bank;
bank 1 sits 4 MB higher (`makevrom.py image_byte_offset`):

    byte offset = ((SAG - 02000000h) >> 3) + bank * 400000h

The Wolf DMA honours that bank bit exactly as the T-unit does (MK2's bank-1
fighter art draws correctly, and the test above relies on it). Above 12 MB a
plain larger SAG does the job: `0FF25AF8` in bank 1 is byte `17E4B5F`.

**What is still to do before art can live there** - pipeline, not hardware:

1. `makevrom.py` / the LOD layout know bank 0 (8 MB) and bank 1 (4 MB). A new
   region needs pack ranges and a LOAD2 base address above 12 MB, and
   `makewolf.py` must carry those chips instead of the donor's.
2. Art placed there exists only on Wolf. The T-unit build has nowhere to put it,
   so anything Wolf-only must be optional in the code (`.if wunit`).
3. For MAME testing, only u118-u121 and u110-u113 are loaded from the zip;
   u114-u117 and u102-u109 need real hardware (or a local driver change).
4. CPU reads of image ROM are banked by `sysctrl` bits 8-9, which only
   `romcheck` uses today.

## Sound ROM - u6-u9 in use (MK1's stage music)

| | T-unit | Wolf (`umk3`) |
|---|---|---|
| sound board | DCS Audio 2K | DCS Audio 8K |
| chips | u2-u7, 512KB each | u2-u5, 1MB each |
| our audio occupies | 3,096,840 bytes | the same audio, repacked into u2-u4 |
| free now | **48,888 bytes** (U7 tail) | **48,846** (U4 tail) **+ 1,048,576** (U5 empty) |

The two sets carry identical audio (all 1,124 tracks decode the same), so the
Wolf gain is pure headroom: **~1.05 MB in MAME**. That is about 21 times what the
T-unit has left - room for a lot more custom audio before anything has to be
reclaimed.

On the board, Williams' Wolf diagram shows eight sound sockets (u2-u9).
DCS addresses a chip as `chip << 20`, i.e. 1 MB per socket and up to 8 sockets,
so a fully populated Wolf sound section would hold **8 MB, ~5 MB free**. Stock
MAME's `umk3` loads only u2-u5, into an 8 MB region where each byte-wide chip
fills 2 MB of 16-bit words. An address in u6 wraps back onto u2 with no error.

**WE USE u6-u9 NOW** (2026-10-07). `makewolf.py` lets the encoder spill past u5
and always writes all eight chips (unused ones FF). MK1's stage music
(`tools/make_mk1_music.py`, ~1.8 MB) is what fills them: u6 full, u7 767 KB,
leaving 282 KB in u7 plus u8-u9 empty. To hear them, use
`tools/mame_wolf/` (a patched single-driver MAME, `mk2wolf.exe`). Stock MAME
still boots the set, ignores the extra chips, and plays everything else.

| | before | now |
|---|---|---|
| sockets written | u2-u5 | u2-u9 |
| free | ~1.05 MB (u5) | **282 KB (u7 tail) + 2 MB (u8-u9)** |

### MK1's stage music

MK1's music is FM synthesis played live by a YM2151, so it is not in MK1's
sample ROMs. The source is MKWarehouse's arcade recordings in `MK1_audio/`
(the 16 `NN - <name> - Dan Forden, Matt Furniss.flac` files; the rest of that
folder is Mega CD / movie / MK2 material and is not used).

**Snip at the loop:** each tune is cut to intro + the loop it repeats, both
measured, not typed (`make_mk1_music.py`):

| stage (curback) | MK1 tune | intro | loop | seam ncc |
|---|---|---|---|---|
| THE PIT (1Ah) | The Pit | 15.5 s | 38.40 s (5000 frames) | 0.97 |
| WARRIOR SHRINE (1Bh) | Warrior's Shrine | 14.1 s | 57.60 s (7500) | 0.96 |
| THRONE ROOM (1Ch) | Hall | 3.6 s | 43.20 s (5625) | 0.98 |
| COURTYARD (1Dh) | Courtyard | 10.4 s | 46.08 s (6000) | 0.98 |
| PALACE GATES (1Eh) | Entrance | 3.1 s | 12.80 s (1667) | 0.96 |

- **Each round tune** is a channel-0 track built like MK2's own: play the
  intro, then loop the main stream, timed with `Wait(n)` in 7.68 ms frames. A
  loop that is not a whole number of frames drifts, so each loop is resampled
  to one. The worst stretch is +0.02%.
- **Each stage's winner tune** is MK1's own victory sting.
- **FINISH HIM** is MK1's "Test Your Might / Fatality" cue for every stage.
  None of MKWarehouse's FM cues is labelled as the FINISH HIM music, so this
  is a stand-in.
- **Levels:** MK2's stage music measures -14..-16 dBFS RMS with peaks around
  -6, so every tune is set to -15 dBFS RMS, peaks at or below -3.
- **Wolf only:** MAIN.ASM's four tune tables point 1Ah-1Eh at `wmus_*`
  (`src/WOLFMUSE.ASM`). On the T-unit, 1Ah-1Ch keep MK2's music.

**Proof:** `tools/wolf_mk1music_check.lua` forces a 2P fight onto the stage,
and run with `-Listen -MameExe ...mk2wolf.exe` it records the round.
`tools/mk1_music_listen.py` then finds the intro in the recording and requires
the loop to start where the intro ends and to come round again. On COURTYARD:
intro 0.99, the whole 46 s loop 1.00, the wrap 1.00, PASS. Stock MAME with the
same ROM: 0.00, FAIL. That is the control showing the pass needs u6-u9.

`tmp/mk1_music_preview/<stage>.wav` (intro + loop x2) is for judging the
seams by ear.

**Shipping it: `python tools/make_wolf_bundle.py`** writes `dist/mk2wolf_bundle.zip` - the set with `mk2wolf.exe` beside it, which is the only way a tester hears it right.

**STOCK MAME CANNOT PLAY THIS SET PROPERLY ANY MORE.** The encoder repacks
the whole set, puts the big new streams low, and pushes ~380 of MK2's own
streams into u6/u7. Stock MAME cannot see those, so MK2's own sounds and music
break there too, not just MK1's. A stuck tone was measured in place of the
attract audio. Play and test the Wolf build in `tools/mame_wolf`'s
`mk2wolf.exe` only.

**Two traps that both read as "u6-u9 do not work":**

- **The encoder names an overflow chip after the prototype's LAST chip's
  extension:** `mk2wolf_sound_rom_u6.u5`. `chips_from_zip` keyed on the
  extension, read u6 and u7 BOTH as u5, and shipped a set with MK2's real u5
  overwritten and u6 blank. The Tower music played slow and ticking, which
  looks exactly like a DCS program that cannot address past 4 MB. It now
  reads the socket from the `_uN` stem and dies if two members claim one
  socket. With that fixed, the attract audio matches the u2-u5 set sample for
  sample (ncc 1.00) in mk2wolf.exe. So the board's DCS program DOES address
  u6-u9; MAME's bank register is 11 bits, enough for all eight.
- **Correlation ignores volume.** The first music pass PASSED at ~9 dB under
  MK2's music. MK1's FM recordings have ~15 dB of crest against MK2's ~9, and
  DCSEncoder stores a stream ~6.4 dB under its WAV. The tool now MASTERS each
  tune (compression, gain to `TUNE_RMS_DB` = -15 + 6.4, a -0.3 dBFS limiter,
  on the whole tune before cutting so the seam shares one envelope). In a
  recorded round the Courtyard plays at -40..-43 dB against the Tower's -40.

## What this means in practice

- **Code:** ~200 KB more on Wolf, once the VS portraits moved to image ROM;
  the T-unit stays at 8 KB.
- **Art:** the big win. MK2 is 47KB from full on T-unit; Wolf adds 8 MB you
  can test in MAME today. The DMA side is proven; what is left is teaching
  makevrom/LOAD2 the new region, and keeping Wolf-only art optional in code.
- **Audio:** usable now. `makewolf.py` already ships U5 empty, and DCSEncoder
  will spill into it as soon as the Wolf sound set needs it - with the caveat
  that `stlaugh_patch.txt` is shared, so anything that only fits on Wolf would
  overflow the T-unit set.

## Music added 2026-10-08 (Wolf only)

| stage | curback | music | tracks | how |
|---|---|---|---|---|
| Outer Haven | 16h | GENESIS MK2 "The Tomb - Special Portal", "~ Critical" (FINISH HIM), "~ Over" (win) | $070B-$070D | `tools/make_mk1_music.py` `GEN_TUNES`, from `genesis mk2 audio/` - intro + one measured loop (32.65 s, 15.37 s) |
| THE CAVE | 19h | MK3 GRAVEYARD (UMK3 tracks $2D / $2E / $2F / $30) | $06F0-$06F3 | `tools/make_wolf_audio.py` `MUSIC` - programs and streams copied byte for byte, no re-encode |
| Pit Bottom | 0Ah | THE PIT's MK1 set (as curback 1Ah) | $0700 / $0701 / $070A | MAIN.ASM rows only |

MAIN.ASM's four tune tables carry them under `.if wunit`; the T-unit rows are
untouched. Checked with `tools/wolf_mk1music_check.lua` + `WM_TAP=1`, which
logs the track code sent at the round's start (070B, 06F0, 0700). The sound
set now runs through socket U8 (about 370 KB free there, U9 empty), so these
are heard only in `mk2wolf.exe`, like the MK1 music.

### MK1's per-stage FINISH HIM themes (2026-10-08)

Each MK1 stage plays its own finish theme now instead of the one stand-in cue
(`wmus_finish`): `tools/make_mk1_music.py` `FIN_TUNES`, tracks $070E-$0712
(`wmus_pit_fin`, `_shrine_fin`, `_throne_fin`, `_courtyard_fin`, `_gates_fin`;
Pit Bottom takes The Pit's), from `MK1_audio/NN. <stage> Finish Theme.flac`.

- No intro: one loop from the opening seconds (11.7-19.0 s).
- **These recordings do not repeat sample for sample** - their own best seam
  is 0.65-0.78 where the stage tunes reach 0.96 - so the earliest-good-seam
  search put the loop point 20-95 s in. `find_loop_near_start` takes the
  best seam in the first 24 s and `crossfade_loop` blends 33 ms across it.
  The period has to be refined to the SAMPLE first: the spectral estimate is
  only good to one hop (23 ms), which read as a seam of 0.25 / -0.05.
- The sound set now ends in socket U9 with about 475 KB free.

### MK1NEWAUD: the stage sets as MK1 cuts them (2026-10-10)

Five stages now take the three-file sets in `MK1NEWAUD/`: the tune, `- Loop`
and `- End`. The user's mapping:

| stage (curback) | set | tune loop | FINISH HIM | End |
|---|---|---|---|---|
| THE COURTYARD (1Dh) | The Temple Gate | intro 33.3 s + 15.69 s, seam 0.97 | Loop, 16.3 s | 3.1 s |
| THE PIT (1Ah) | The Bridge | intro 3.7 s + 48.27 s **body loop** | Loop, 13.9 s | 5.3 s |
| the PIT BOTTOM (0Ah) | Shang Tsung | intro 2.9 s + 37.62 s, seam 0.97 | Loop, 20.1 s | 3.9 s |
| THE WARRIOR SHRINE (1Bh) | The Cavern | intro 8.0 s + 45.30 s **body loop** | Loop, 28.2 s | 2.5 s |
| THE THRONE ROOM (1Ch) | The Throne Room | intro 19.3 s + 42.89 s, seam 0.96 | Loop, 18.0 s | 5.3 s |
| PALACE GATES (1Eh) | The Palace Gates | intro 3.9 s + 47.45 s **body loop** | Loop, 30.7 s | 2.9 s |

**This is how MK1 itself sequences them.** `tools/run_mk1_music_cmd_probe.ps1`
taps MK1's sound port (`01D01020`; `mk` rev 5.0 is a T-unit, so it is NOT the
Y-unit's 01E00000) through a real 1P match. Each stage owns three consecutive
commands (03/04/05 for one stage, 07/08/09 for the next):

- the tune is sent at EVERY round start, so it restarts from its intro;
- the loop is sent once at FINISH HIM, and the board loops it;
- the End is sent at the killing blow, whether that wins the round or ends the
  finish.

MK1 has no separate victory sting. So the End is the winner tune, and after a
fatality it replaces MK2's "death blow over" tune 035h (`wolf_dbc_tune`,
MAIN.ASM). That swap applies to 0Ah and 1Ah-1Eh. The babality tune is left
alone.

**MK1 switches cues with a HARD CUT, never a crossfade.** Run with `-Ym`, the
probe logs every YM2151 register write on the sound board (`:adpcm:cpu`,
2400h). At each music command the driver keys off all eight channels and
loads the new cue's voices one channel per frame. The new cue is fully in
within 1-8 frames (18-150 ms), and the old notes stop with only their own
short release. There is no TL ramp on the outgoing music. (The TL steps after
FINISH and after the End belong to those cues: a swell, and the End's own
fade.) A DCS track on channel 0 replaces whatever is playing, so this needs
nothing extra.

**The Bridge, The Cavern and The Palace Gates do not repeat anywhere.** Each is one pass into a
fade. The sample-level seam is under 0.1 at every lag, and spectral
self-similarity is 0.5-0.6 everywhere. So `find_body_loop` loops the whole
body from 2-8 s to just before the fade, with the end chosen to match what
precedes the start, and a 0.5 s crossfade. A longer rip without the fade
would let them loop exactly, the way the other three do.

Palace Gates' only repeat (23.43 s, from 39 s) runs into its fade.

None of these arrangements is MK1_audio's (spectral match 0.41-0.59), so no
old loop point carries over. Total MK1 audio is 516 s (was 451 s). At the
encoder's default 128 kbit/s that needed a ninth 1 MB socket, so the MK1
streams are 112 kbit/s. The set then ends in u9 with ~40 KB free.
