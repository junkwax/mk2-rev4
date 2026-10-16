# THE CAVERN (curback 019h)

MK3's cave stage, `MK3CAVE.BDB/.BDD`, from the UMK3 art tree
(`deadlythirdcombat-main`). **It never shipped.** No LOD in MK3, UMK3 or
Trilogy loads it and no code names its modules, so there was no Midway layout
to port. UMK3's playable cave is a different file (`MKCAVE`, Kahn's Kave).
The planes, scroll rates and rows here were chosen for MK2.

**It was in an early MK3 build** - "Extremely Early Mortal Kombat 3 Footage
With Cavern Stage" (YouTube `Jw84UTSXzdU`) shows it - **but that build's layout
is not recoverable from anything here** (searched 2026-10-06). Not one of the
seven cavern palettes, nor a header or module record matching its art, is in
the program ROM of `mk3p40` (the prototype), rev 1.0, 2.0 or 2.1 (all in
`deadlythirdcombat-main/mk3_rev1.zip`), or UMK3 1.2. The search method was
checked on a shipped stage: MKGRAVE's 14 palettes are found in every build.
`mk3-rebuild-main` and the six `Workplace/MK3` tarballs have no cavern label
either (the footage itself is the source - see Layout). What survives is the floor palette: `CAVEFL_P` is in every build and
in `MKBT.ASM`, and **nothing points at it** - an orphan left when the stage
table was cut, before p40. To match the video, measure the footage.

| | |
|---|---|
| Stage id | `curback 019h`, `table_o_mods` in `src/BGND.ASM` |
| Code | `src/MK3CAVE.ASM` (its own object: BGND.ASM is ~250 lines short of GSPA's out-of-memory point) |
| Generated tables | `src/MK3CAVBG.ASM`, from `tools/make_mk3cave.py --apply` |
| Name | `txt_bg26` "THE CAVERN", `src/MKSEL.ASM` (was "THE CAVE"; the code and tools still say cave) |
| Selection | last entry of `vs_stage_cycle` (so it is one LEFT from Dead Pool) and of `match_stage_cycle` |
| Music | the Tomb set (`019h/01ah/01bh/01ch`), `src/MAIN.ASM` |
| Floor | UMK3's `FL_CAVE.BIN` (1200x42 raw 6bpp) on MK3's `CAVEFL_P` |
| Video ROM | ~239KB of bank 1: four image packs plus the floor |
| Rig | `pwsh tools/run_cave_stage_probe.ps1 -Tag <name>` |

## Layout - measured off Midway's early build

No ROM or source has the stage table, but the footage (above) opens on 16s of
the EMPTY stage scrolling, shot off a CRT, then five minutes of fights.
`tools/cavern_video/*.py` (OpenCV; frames extracted with ffmpeg into
`tmp/mk3cave/video/`) template-match this art against the frames - columns
0.74, cavern wall 0.76, outcrop 0.73, far chamber 0.74 normalised correlation,
at 2.3 x 2.45 video px per game px - and track the strip and four floor bands
by band correlation between frames.

| measured (columns = 1) | value | = Midway's round rate |
|---|---|---|
| far chamber | 0.33 | 08000h (0.25) |
| cavern (wall and outcrop agree) | 0.69 | 10000h (0.5) |
| columns | 1 | 18000h (0.75) |
| floor rows ~9 / 16 / 24 | 1.27 / 1.33 / 1.40 | far edge 1C000h, +rate/128 a row (MK3's Graveyard floor follows its 1C000h plane the same way) |
| stalagmite strip | 1.23 | floor row 4-6's speed |

- **Heights**, against the floor's lit edge: far chamber top at screen row 0,
  cavern top at -7, column module top at 22. (Before: 44, 2, 15.)
- **Camera**: the pan stops 405px left of the round-start camera and the
  fights reach 400px right of it (three frames agree) - limits 0..800, start
  400. The fighters' world is 1200 wide: **the stage is the length of the
  floor.**
- **x** at the round start (timer = screen centre): `START_X` in the tool.
- The 94px gap between the cavern's wall and outcrop is in the footage, with
  the far chamber across the top of it and the black block under it.

Accuracy is about +-2 rows and +-8 columns - the tube is curved and the camera
off-axis - which is why the rates are snapped to round values.
`tmp/mk3cave/video/compare.png` is footage against `--preview` at the round
start, mid-pan and both limits.

Back to front:

| list | module | rate | what it is |
|---|---|---|---|
| baklst4 | mk3cave4 (718x100) | 08000h | the far chamber, seen over and through the gap |
| baklst3 | mk3cave3 (959x222) | 10000h | the cavern: wall + skull pile (palettes 1/2), a 94px gap, the outcrop with steps (3/4) |
| baklst5 | mk3cave2 (460x186) | 18000h | three columns standing in the water |
| floor | FL_CAVE, 41 rows | 1C000h far edge | `skew_scroll = scrollx2` anchored on row 6, +rate/128 per row |
| baklst2 | mk3cave1 (1201x46) | 1D608h | stalagmites on `flrtop_p`, on the floor's far edge |

**The background fill is pure black** (`AUTOERASE` (0,0,0), was (1,1,1)). It
is what fills the gap below the far chamber, and the art either side of the
gap is black - 792 of the 1,272 pixels within 6px of it are exactly (0,0,0) -
so the grey-black fill showed as a lighter rectangle.

**The water does not shear.** Measured in a column-free window
(`tools/cavern_video/water2.py`): screen rows 149-168 move at 63-64 video px a
step against the cavern's 63, correlation 0.9+. What slides over it is the
column layer - the rock bases and their reflections are column art, at 18000h
over water at 10000h.

**The stalagmites and the floor are one drawing.** Both are 1200 wide, and the
shadows painted into FL_CAVE line up with the spikes at column offset 0
(`--align`; `--check` fails if the best offset moves), so the strip sits at
x = start - 400. Its bottom row lands on floor row `SPIKE_BASE` (3).

**The floor is anchored on the SHADOW ROW.** Every floor row is rate/128
faster than the one above, so whichever row tracks plane 2 is the one whose
shadows stay exactly under their spikes. `mk3cave_skew_calla` gives
`mk3c_kanc` x scroll/128 back to `skew_oc` (register a10 AND the variable -
the rows are drawn off the register) so row `SHADOW_ROW` does, and plane 2
runs at 1C000h x 128/(128-K). K = 6: the footage puts the strip at row 4-6,
and 6 is nearest the shadow heads (rows 8-11). K = 10 holds the heads dead
still but runs the strip 4% faster than Midway's - measurably not the footage.

**The floor is drawn one row down and one row short** (`skew_y` 213, 41 rows).
At the camera limits the rows under the feet slide more than the 400 spare
columns and run on into the NEXT row's pixels (the art is one linear strip);
the last row would run off the end of the art. Row 41 is never drawn, so every
row that runs on has a real row under it. `--check` proves no drawn row reads
outside FL_CAVE 4px past either limit, and that no camera shows an empty
column above the floor.

All eight `bak?mods` are written, planes 6-8 as `skip_bakmod`. Otherwise a
plane past the end of the list keeps the previous stage's module.

**Edit the layout in `tools/make_mk3cave.py`** (`GROUND_Y`, `FLOOR`, `RATES`,
`PLACE`, `START_X`, `SPIKE_BASE`, `SHADOW_ROW`), never in `MK3CAVBG.ASM`. Those constants feed both the
generated equates and the preview, so the two cannot disagree:

```
python tools/make_mk3cave.py --preview            # left / start / right cameras
python tools/make_mk3cave.py --preview 120 480    # any worldtlx
python tools/make_mk3cave.py --apply              # after a layout change (no LOAD2 needed)
```

In MAME the floor and every plane matched the preview pixel for pixel, at both
scroll limits.

## The water ripples

`mk3cave_water` (`src/MK3CAVE.ASM`) redraws the cavern's water band, module
rows 154-199, **one scanline at a time** over the plain blocks. It sits in
`dlists_mk3cave` right after `baklst3`, so the columns still stand in the
water and everything in front is untouched. It is a relative of KAHN'S
ARENA's heat haze (`sky_rows`), but it needs **no texture and no video ROM**:

- Every block on `skull_p`/`water_p` crossing the band is a *span* (8 of
  them). A line is one single-row blit per span on screen, read straight out
  of that block's own ROM data. `make_mk3cave.py` walks each row's bit offset
  out of the MK3CV pack IRWs, row header by row header, and the walk must
  reproduce the BDD's pixels (`MK3C_WATR??` = `[offset, left skip]`).
- Each line takes a byte of `MK3C_WATWAVE`, `[dv:3 | dx:5]`: drawn `dx`
  pixels across (+-2) and reading the row `dv` away (+-1), so the water sways
  and shimmers. It is perspective water: the band's top is the far bank, where
  waves are smaller and closer together; a slow swell rolls toward the viewer
  and a finer chop crosses it. 64 steps, one every 2 ticks (2.3 s loop).
  Lines are world rows, so the ripple rides with the camera.
- The plain blocks stay underneath. A line with dx = dv = 0 is not redrawn,
  a span whose palette is not loaded is skipped, and when the queue is down to
  `mk3c_wat_resv` (250) cells the rest of the frame is dropped (`cw_short`).
  Every one of those just shows the still water: it can only add.
- The skull pile shares the water's palette. A row's **left skip** starts the
  blit right of the pile (rightmost bone of that row and the rows either side,
  + dx_max + 2), so no bone moves.

Tune the look in `WATER` in the tool, then `--apply` (program ROM only):

```
python tools/make_mk3cave.py --water-gif [camx]   # tmp/mk3cave/water.gif from the same tables
python tools/make_mk3cave.py --apply
```

`f_cwater`: 0 ripple, 1 off, 2 every line at `cw_fixdx`, 3 alternating.

**Two DMA traps, both measured:**

1. `ofset`'s left skip is **ignored unless the control word has `dmaclp`**
   (0040h). Without it the whole row is drawn, which still passes an
   "every line at offset 0 == plain" test, because an unskipped row at 0 lands
   on itself. Only moving it exposed it: bones slid with the water.
2. With `dmaclp`, `[y:x]` is where the **first drawn** pixel lands, so x is
   block x + skip + dx.

And one register trap: the dlist dispatcher keeps the camera's y in the top
half of **a4** for every list after a `-1` routine (`disp3` only replaces x).
Clobbering it drew the columns, stalagmites and fighters 54 px low.

**Verified** (`tools/cave_water_test.lua` + `tools/cave_water_compare.py`,
cameras at the left limit/skull pile, middle and right limit): scene frozen,
every line at 0 == plain **0 px**; +2 / -2 / alternating change nothing outside
the band and >= 95% of changed pixels are the plain pixel shifted (the rest
are the edges of fighters/columns drawn over it); **0 skull-pile pixels**
change in any shifted or real-wave shot. Live, 360 frames: 116-169 blits a
frame, `cw_short` 0, `dmaq_late` +0, overflow 0, overload max 2, queue peak
275 cells vs 265 with the ripple off.

## Why the art is split into packs

The 60 images pack to ~201KB. No free video-ROM run was bigger than 86KB, so
one `BBB>` sidecar could not hold them. A module's header table is only
`[w,h,SAG,ctrl]` per image, and the SAGs are absolute. That means one module's
blocks can live in any slot.

1. `make_mk3cave.py --parts` sorts the images largest first and puts each one
   into the first pack with room (first-fit decreasing). Each pack has a fixed
   bank-1 slot. The tool then writes `data/MK3CV1-4.BDB/.BDD`, one throwaway
   module per pack. Its size estimate copies LOAD2's `PPP> 0` depth choice and
   `zcom.c` zero compression, and it came within 0.7% of the real HDRS for
   MK1CAVE.
2. `data/MK3CV1-4.LOD` pack them. `IMGBUILD.BAT` snapshots each run's table as
   `tmp/load2/BGNDTBL.CV1-4`, because the next LOAD2 run overwrites it.
3. `--apply` (build Phase B2d2) maps every snapshot header back to its source
   image. It then writes one `CAVHDRS` in the original BDD order, the four
   BLKS/BMOD, `CAVPALS` with the seven palettes, the floor SAG and the layout
   equates.
4. `--check` (Phase D) fails if any of these hold:
   - the pack files are no longer the output of `--parts`
   - the ASM is stale
   - a header's size disagrees with the BDD, which means it is mapped to the wrong image
   - a SAG is outside its pack's slot

| pack | slot (physical) | payload |
|---|---|---|
| MK3CV2 | 0xB82000..0xB96000 | above MK7MIL, under TWRJNT |
| MK3CV1 | 0xBA2000..0xBB7000 | TWRJNT's slot end to ARNSKY |
| MK3CV3 | 0xBC7000..0xBCD600 | off the top of SMTIGER's old guard (2,370 left) |
| MK3CV4 | 0xBD9000..0xBDD600 | off the top of BLDXPD's old guard (1,474 left) |
| CAVEFLR | 0x9EE000..0x9F7C00 | MK6MIL tail (6,302 growth left) to MKSOUL1 |

The slots are declared in three places that have to agree: `PACKS` in the
tool, `CUSTOM_VIDEO_SLOTS` in `makevrom.py`, and the `***>` line in each LOD.
The deal is recomputed from the source art on every `--parts` run. If the art
changes, rerun `--parts` and then a full `python build.py`.

## Rig

`tools/cave_stage_probe.lua` coins up a 2-player game, confirms both fighters,
and taps LEFT on the VS stage-select screen until `curback` = 019h. That is
the real selection path, not a memory poke. It then parks both fighters at the
left scroll limit, the middle and the right limit. At each stop it logs every
plane's `worldtlx`, the skew state, the list lengths and `peak_overload`, and
takes a snapshot.

The rig has to press BOTH start buttons. "2 Players Start" is only player 2's
start button. Pressed alone, it starts a one-player game for P2, which has no
VS stage select, and the tower chooses the stage.

First run (tag `first`): 00 -> 19 on the first tap. Planes at the left limit
were x1=0 x2=87 x3=131 x4=218 x5=109, exactly the model's values.
`peak_overload` stayed at 2, `qdma_drops` at 0, and the background lists held
13/14/5/2 objects.
