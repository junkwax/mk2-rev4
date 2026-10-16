# THE WARRIOR SHRINE (MK1), curback 01Bh

MK1's statue gallery: Sub-Zero, Cage, Kano, Goro, Liu Kang, Raiden and Sonya
on their plinths between the pillars, a line of trees and a mountain behind,
and the moon. The art and layout are MK1's own. By default the statue row
moves slower than the fighters (`wshrpar`), sliding behind the side gates;
the floor is MK1's, flat. `wshrpar 0` gives MK1's stage exactly. There is no stage fatality,
because MK1 had none here.

| | |
|---|---|
| Stage id | `curback 01Bh`, `table_o_mods` in `src/BGND.ASM` |
| Code | `src/MK1WSHR.ASM`: stage record, scroll table, display lists, calla, and `wshr_floor` (the optional spreading floor, off) |
| Generated | `src/MK1WSHRB.ASM`, written by `tools/make_mk1shrine.py --apply` (build Phase B2d4) |
| Name | `txt_bg28` "WARRIOR SHRINE", `src/MKSEL.ASM` |
| Selection | `vs_stage_cycle` and `match_stage_cycle`, straight after THE PIT BOTTOM, so MK1's three stages run together. It is four LEFT taps from Dead Pool |
| Music | THE TOWER's set (`00Dh..010h`), `src/MAIN.ASM`. MK2 has no MK1 tracks |
| Video ROM | ~82KB of new art in three bank-0 packs. Three more images reuse THE PIT's SAGs, and the moon is THE PIT's own record |
| Rigs | `pwsh tools/run_cave_stage_probe.ps1 -Tag <t> -Stage 1b` (real stage select, both scroll limits), `pwsh tools/run_mk1pit_rounds_probe.ps1 -Stage 1b -SkyExpect 1` (three rounds) |
| MK1 reference rig | `pwsh tools/run_mk1_shrine_capture.ps1` (MAME `mk`) |

## Sources

The tool reads the stage from two sources and checks them against each other
on every build:

- **`data/KUNGFU1.BDB/.BDD`**: MK1's own background file, from the leak. It
  has three modules: `WOKWAY1` (the shrine), `WOKWAY2` (the trees) and
  `WOKWAY3` (the mountain). `KUNGFU4` is a daytime Palace Gates variant, not
  this stage.
- **`C:\MAME\roms\mk.zip`** (MK1 rev 5.0, T-unit). Entry 2 of the stage table
  at `FFCA7E30` is `FFCB7160`, THE WARRIOR SHRINE:
  - erase colour `0006h`, ground 265, camera y 25, start x 444, limits 87..820
  - WOKWAY1 at (0,-47), WOKWAY2 at (45,75), WOKWAY3 at (444,121)
  - the calla `FFCB8E40`, which is the moon and nothing else

`--check` proves that KUNGFU1 is what MK1 shipped:

- all 242 blocks equal MK1's three module block lists (flags, x, y, header,
  palette)
- all 93 images decode to the same pixels out of MK1's video ROM
- all 12 palettes are the same words

The layout numbers are read off the record, not typed.

## Planes and scroll rates

MK1 has nine planes, like MK2. The stage record's third `.long` names the
first `bak?mods` slot it fills: `01095550h`, which is entry 1 of MK1's plane
table (`FFCB61A0`, five `.long`s per entry). Two pieces of MK1 code settle
which rate each entry gets:

- `FFCBFCA0` stores the scroll table's nine values from `0104F670h` upward.
- `FFC79E00` adds `0104F670h+32k` into `0104F790h+32k`.

Entry e's `worldtlx` is `0104F890h - 32e`, so it gets table `.long` 8-e:

| entry | module | rate | MK2 |
|---|---|---|---|
| 1 | WOKWAY1, the shrine | 020000h | baklst1, the fighters' plane |
| 2 | WOKWAY2, the trees | 010000h | baklst2 |
| 3 | WOKWAY3, the mountain | 0 | baklst3. It never scrolls sideways |

MK2's table runs the same way (first `.long` plane 8, last plane 0), so entry
e is MK2's `baklst` e. The tool checks both pieces of MK1 code word for word.

`tools/run_mk1_shrine_capture.ps1` measured the planes live in MK1: at the
left limit x1 86, x2 265, x3 444; at the right limit x1 820, x2 632, x3 444.
MK2's stage probe reads the same values at the same cameras.

## The moon

The shrine's calla, `FFCB8E40`, is THE PIT's moon subroutine: THE PIT's own
calla CALLRs it. It builds one m_noscroll object (flags `3001h`), the
`PITMOON` record at (90,20), filed on plane 3's list. MK2 already ships that
record, so `mk1wshr_calla` creates `mk1p_moon` (MK1PTOP.ASM), which puts it
on `mk1p_sky_lst`. Only one stage owns that list at a time, and each calla
zeroes it before building. The tool checks the subroutine's 13 words, so a
different moon would fail the build.

## Ground

MK1's ground is 265; MK2's is 259. MK2's fighters hang about 6 rows lower
under their anchor than MK1's (THE PIT found the same). Measured at the start
camera, MK1's Kano ends on screen row ~239 and MK2's Liu Kang on ~240, on
the same floor band. The nudge is `GROUND_NUDGE` in the tool. Shadows use
`shad_fast` 2, like every fightable stage, with no clip. The floor is the
whole bottom of WOKWAY1.

## ROM space

| pack | slot (phys) | donor | payload | PPP |
|---|---|---|---|---|
| MK1WS1 | 0x7D4200..0x7E5C00 | FLAPJACK (the WAFFLE HOUSE hole) | 69,396 B | 0 |
| MK1WS2 | 0x75BE00..0x75F400 | HANGJOHD | 12,816 | 0 |
| MK1WS3 | 0x7E5C00..0x7E6000 | FLAPJACK | 552 | 6 |

FLAPJACK keeps 1,938 B of guard and HANGJOHD 1,098 B. Free video ROM went
from 153,004 to 70,240 bytes, and **the largest free run is now 10,040 bytes**:
the WAFFLE HOUSE hole is spent. Program ROM cost ~4.7KB.

The slots are declared in two places that must agree: `PACKS` in the tool and
`CUSTOM_VIDEO_SLOTS` in `makevrom.py`. The tool writes each LOD's `***>`
line.

Three images (KUNGFU1 2A, 54, 5A) are pixel-identical to KUNGFU5 images
already in THE PIT's packs. Their headers are read out of
`src/MK1PTOPB.ASM`, which is why Phase B2d4 runs after THE PIT's B2d3.

### LOAD2 ignores a block's last pixel

LOAD2's automatic depth (`PPP> 0`) sizes a block by every pixel **except the
last**. It then writes the last pixel at that pixel's own width, and the
overflow lands in the next record's first rows. KUNGFU1 DE and E4 end on
STONEBD_P 34, while nothing else in them is above 22. LOAD2 stored them at
5bpp, and the first build shredded E7 (318 of 560 pixels wrong) with no error
anywhere.

34 is a real colour in that 54-entry palette, MK1 draws it, and no index
below 32 has the same colour. So instead of repainting a pixel, the tool
deals any such image (`wide_tail`) into MK1WS3, a pack forced to `PPP> 6`.
THE PIT's KUNGFU5 images have the same trailing pixels, out of range there,
which is what `mask6` in `make_mk1pit.py` handles.

`--apply` and `--check` decode all 93 records back out of whichever IRW
holds them and compare them with KUNGFU1, **unmasked**: a record stored too
narrow fails the build. That lookup goes by written payload, not by declared
slot, because slots nest (SCLAP's still spans THE PIT's bank-1 packs).

## Editing

```
python tools/make_mk1shrine.py --report          # MK1's numbers, the deal, pack sizes
python tools/make_mk1shrine.py --preview         # tmp/mk1shrine/preview.png
python tools/make_mk1shrine.py --preview 87 600  # any camera x
python tools/make_mk1shrine.py --parts           # after changing PACKS or the art
python build.py                                  # full: new packs need LOAD2
```

Never hand-edit `src/MK1WSHRB.ASM` or the `data/MK1WS*` files; Phase D's
`--check` fails if they drift from the tool. `--check` needs `mk.zip`, as
THE PIT's does.

## Parallax (`wshrpar`, on by default)

`wshrpar .set 1` in `src/MK1WSHR.ASM` splits the shrine into layers. `0` is
MK1's flat shrine, pixel-identical to the first import. Switching needs only
`python build.py --asm-only`.

| layer | where | speed |
|---|---|---|
| moon, mountain, trees | as MK1 | screen-fixed, 0, ½ |
| the floor: walkway and deck, flat | baklst5 | fighters' (MK1's) |
| statue row: statues, columns, balustrade, plinths, obelisks, the two diagonal side walls | baklst4 | `mk1w_back_rate`, 7/8 of the fighters' |
| side gates | baklst1 | fighters' |

At the scroll limits the statue row is up to ~44px behind where MK1 draws it,
so different statues are framed by the gate posts. One 2px balustrade gap MK1
kept behind the left gate is closed with a pad (below). The frame load is the
flat stage's: queue peak 213 cells, `dmaq_late` 3 (the boot latch) on
`run_runtime_budget.py --scenario 8,10,27 --scenario 1,3,27`.

### The spreading floor (built, switched off)

On 2026-09-19 the floor also spread toward the viewer, MK2-style. It was
rolled back to MK1's flat floor at the user's call, and the code stays:
`FLOOR_BANDS = True` in the tool, then `--apply` and
`python build.py --asm-only`. The tool writes the choice into
`src/MK1WSHRB.ASM` as `mk1w_fbands`, which gates `wshr_floor` and its
tables. With it on, the side walls move into the floor, and the flat
floor on baklst5 shrinks to the three end blocks the camera sweep finds
showing through. How it worked, and what it cost:

**The floor.** MK2's own skewed floor (`floor_code`) needs a raw texture:
62-88KB for this floor. Removing the floor from the packs frees only ~14KB,
because MK1 tiles it from 8 images. So `wshr_floor` redraws the floor's own
blocks, using the Cavern water's technique:

- Each floor block is a span, drawn as pieces (runs of its rows), each read
  straight out of the block's ROM data from its first row. `WSFR_??` holds
  the bit offset of every row; the tool walks them out of the IRWs and
  decodes every row back from its offset.
- Each piece belongs to a band. A band is drawn from the fighters' camera
  plus F of the way to the statue row's camera, using both **real**
  `worldtlx` values.
  - F = 1 on the top band, so the plinth bases stay planted on the walkway.
  - F = 0 at the ground row (259), so the fighters' feet stay planted.
  - F is negative below the ground row, so the rows nearest the viewer run
    fastest.
- The deck and the two perspective side walls (`48`/`51`, which run from
  the walkway toward the viewer) are in 3-row pieces.
- The walkway is one featureless dirt tile, so shear inside it cannot be
  seen. It is drawn a whole tile at a time at the statue row's speed.

**No holes: checked, not assumed.** `--apply`/`--check` render every
camera from 87 to 820 and fail if any floor pixel MK1 drew is left open.
Three things were needed to get there:

- **Edge and gap pads.** MK1 cropped the floor to its camera (the walkway
  starts at x 86 with the left limit at 87), and its tiles have gaps hidden
  under the gate posts (9px at x 142..151). A copy of the neighbouring
  fully opaque tile carries each row past its ends and into those gaps.
- **Back-row pad.** One 2px gap in the balustrade (x 155..157) sits entirely
  behind the left gate. It is closed with a copy centred on it, drawn one z
  step behind. Only gaps that a gate covers in MK1's picture are padded;
  gaps MK1 left in view stay.
- **Minimal underlay.** Three end blocks (`18`, `1E`, `18` flipped) are drawn
  flat under the bands. They are the only blocks the camera sweep ever finds
  showing through: a 23px gap between two deck end pieces with transparent
  diagonals, which MK1 hid under the right gate.

**Palettes.** A background palette is loaded only while one of its blocks is
on a display list, and the floor's blocks are not. `mk1wshr_calla` loads
`WSFPALS` with `getfpal`, as `setup_floor_info` does for a skewed floor.
Without that, the walkway was never drawn, and at the start camera no floor
at all.

**DMA time is the budget.** A frame that starts with blits still pending
throws them away (`init_dma_regs`, `dmaq_late`), and the HUD goes first.
`tools/run_runtime_budget.py --scenario 1,3,27 --scenario 8,10,27`,
2,400 frames each:

| build | queue peak (cells of 500) | `dmaq_late` |
|---|---|---|
| flat (`wshrpar 0`) | 213 | 3 (boot latch, as stock stages) |
| first cut: full underlay, every span in every band | 346-357 | **397 and 1,516** |
| shipped: whole-tile walkway, minimal underlay | 254-260 | 3 |

At the scroll limits the stage probe reads `wf_lines` 112-141,
`wf_short` 0, `dmaq_late` 0 and `peak_overload` 2.

**Cost:** no video ROM; ~5KB of program ROM for the split modules, spans,
pieces and row tables.

Tune in the tool (`BACK_RATE`, `BAND_ROWS`, `WHOLE_PALS`, `SEAM_ROWS`,
`BACK_GAP`), then `--apply`, then `python build.py --asm-only`.
`python tools/make_mk1shrine.py --preview --par` renders the parallax
version.

## Verified (2026-09-19)

Flat-floor parallax (the shipped default): the stage probe's MAME frames
match the model at the start camera, both limits and the middle (the only
differences are the fighters, their shadows and the HUD); `dmaq_late` 0 at
every stop; the budget figures above.

With the spreading floor on (`FLOOR_BANDS`):

- `run_cave_stage_probe.ps1 -Tag mk1wshr_par -Stage 1b -Watch
  wf_lines,wf_short,dmaq_late`: MAME's frames match the model at the start
  camera, both limits and the middle. The only differences are the fighters,
  their shadows and the HUD (plus a few railing pixels the Python model
  z-sorts differently; MAME's flat and parallax frames at the centre camera
  are identical there). The statue row sat at x 131 / 774 at the limits, the
  planes as modelled.
- `run_mk1pit_rounds_probe.ps1 -Stage 1b -SkyExpect 1`: 1 sky object and 253
  free objects in each of three rounds.
- `wshrpar 0` rebuilt and probed: pixel-identical to the first import at all
  four cameras.

Flat import (first build):

- **Stage select with real input**: `run_cave_stage_probe.ps1 -Stage 1b`
  reached 1Bh via 19,18,16,1b. At the start camera, both limits and the
  middle, the plane x values matched the model and MK1:
  - `peak_overload` was 2 and `qdma_drops` 0 throughout
  - baklst1 held 85-100 blocks, baklst2 14-18 and baklst3 6
- **Against MK1**: side by side with `run_mk1_shrine_capture.ps1` at the start
  camera and both limits, the backgrounds are the same picture.
- **Three rounds**: `run_mk1pit_rounds_probe.ps1 -Stage 1b -SkyExpect 1` gave
  1 sky object and 235 free objects in each round, so the moon is rebuilt once
  per round and nothing leaks. THE PIT's run after the change was unchanged:
  46 sky objects, 38 clouds, 298 free.
