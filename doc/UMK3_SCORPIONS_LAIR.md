# SCORPION'S LAIR (UMK3) - Wolf only, curback 1Fh

UMK3's hell stage (`BKGD_HADES_MOD` 0Ch) with its stage fatality, built for the
Wolf board (doc/WOLF_CONTENT_PLAN.md step E). In the normal stage rotation.

| piece | where |
|---|---|
| importer | `tools/make_umk3lair.py` (`--parts`, `--apply` = Phase B2d8, `--check` in Phase D, `--report`, `--preview`) |
| UMK3 ROM reader | `tools/umk3rom.py` - program ROM at FF800000h, image ROM laid out as MAME's `umk3` driver loads it (byte = SAG >> 3) |
| stage module | `src/UMK3LAIR.ASM` (body under `.if wunit`), generated data `src/UMK3LRB.ASM` |
| art | `data/LAIR1` (22 block images, 103,668 B at linear `0xC50000`), sprite pack `data/LAIRM` (`data/UMK3LRMK.IMG`: HELLFLAME1-6, HELLHIT1-8, 7,574 B at `0xC74000`), floor `data/LAIRFL` (`data/FL_HELL.BIN`, 41,400 B at `0xC7C000`) |
| fatality hooks | `check_dtp` (MOVES.ASM) and the entry of `r_fall_down_mk1pit` (MK1PTOP.ASM), both `.if wunit` |
| rig | `tools/run_wolf_boot_probe.ps1 -Script wolf_lair_check.lua -Env WL_MAP=tmp/wolf/src/MK2.MAP,WL_TBL=src/UMK3LRM.TBL` |

## Where it comes from

**The ROM, not the leak.** deadlythirdcombat's `MKHELL.BDB/.BDD` is UMK3's art
library, but its HADES2 module is 14 blocks / 1333 wide where the shipped ROM's
is 15 / 1332. Everything is read out of `umk3.zip`; the decoded blocks match
the BDD's pixels exactly, and `FL_HELL` matches `BINFILES/FL_HELL.BIN` byte for
byte. Found by searching UMK3's program ROM for the module records the BDB's
sizes predict (`FFCED690`..`FFCED8D0`), then for the module list that names
them. Read with MAME's disassembler (`umk3`):

- **Record `FF952560`** (MK3's layout - erase, world y, ground, start, limits;
  calla, scroll, dlists; bak1mods; modules): erase 0 (black), ground FBh, start
  x 190h, limits 0..321h. HADES1..5 on baklst 1, 2, (3 skipped), 4, 5, 6, then
  `center_x` for HADES2..5 - MK2's `init_bakmods` handles that word exactly as
  MK3's does - then the floor.
- **The floor**: `FL_HELL` 1200x46 6bpp, its palette, height 2Eh, scroll
  variable `0105D990` = UMK3's scrollx1 (MK3's RAM order puts scrollx8..1,
  scrollx before worldtlx8..1) = MK2's `scrollx`, and `skew_7` (FF9622E0: dx -=
  scroll >> 7, THE TOWER's `tower_skew_calla`). **MK3's `setup_floor_info`
  adds 02000000h to the record's SAG and computes the floor's y itself**
  (worldtly + 254 - height = 208) - MK2's floor record carries the y, so the
  generator writes it.
- **The display list** (FF952A90): baklst6, 5, 4; **baklst3 on PLANE 2's
  camera** (the flames - plane 3 carries no module); baklst2; the floor;
  baklst1; baklst7 (the falling body) on plane 1's; shadows; objects.
- **The calla** (FF952D70) is `create_dumb_animators` on FF952DC0: two flames,
  HELLFLAME01..06 (FFCEA4D0, 33x36, palette FFDBC9C0), 4 ticks a frame, at world
  (84h,5Eh) and (27Dh,5Eh) on baklst3.

## The stage fatality

UMK3 (`q_pit_fatal`, MOVES.C 3426) gates it like MK2's pit fatalities: each
fighter's own stage code, at close range, then the uppercut - so it rides MK2's
existing path. `check_dtp` takes curback 1Fh and hands it to
`do_down_the_mk1pit` (THE PIT (MK1)'s winner side); the victim's
`r_fall_down_mk1pit` turns off to `lair_fall_in_lava` on this stage. So every
fighter's MK2 pit code works here, and nothing in MKREACT or MAINEQU changed.

`lair_fall_in_lava` is UMK3's `fall_in_lava` (FFAE3220, with the shared
FFAE46D0), step for step:

1. thrown off the top: -100000h a tick on his uppercut lane until 100h off the
   ground, then 50h ticks;
2. back on screen, **shrunk to oscale 1C0h** - the arcade draws the falling body
   from per-character tumble art (the table at FFA285E0) that MK2's fighters do
   not have, so this is what UMK3's own PSX port does (`BKGDCAVE.C`): the
   fighter's own knockdown frame, scaled. The multipart deltas are re-laid at the
   same step (`orb_scale_apply`'s method), so he does not come apart;
3. at the other man's screen x +80h (-80h right of C7h, never left of 80h), no
   scroll, falling at 20000h under 6000h until his FEET reach the lava surface,
   screen y 200 (`lair_lava_surf`). UMK3 stops on his TOP at B2h, which suits its
   small tumble sprites; on a full-size MK2 body that put the feet, and so the
   splash, at y 265, off the bottom of the screen on the floor rock (fixed
   2026-10-13). The bright sea is rows ~198-212 at camera 400, the floor ~213 on;
4. shake (4,6), the lava takes him: HELLHIT1..8 (FFA81C70, 4bpp, palette
   FFDBAC00) at 5 ticks a frame at his feet, body gone; `death_blow_complete`.

Sounds are MK2's own (the monster hit, the scream, THE PIT (MK1)'s landing thud)
- UMK3's sound 5Fh has no MK2 equivalent until the Wolf sound overlay (step B).

## Verified

T-unit byte-identical. Wolf, `wolf_lair_check.lua` - a 2-player Liu Kang v Jax
on curback 1Fh: the flames step HELLFLAME1..6 in order, 49 steps of exactly 4
ticks; FINISH HIM forced with Jax dizzy, Liu Kang's Back, Forward, Forward + LK
takes (`act_mk1pit_fall`), Jax leaves the top of the screen, comes back at
oscale 1C0h, falls to the lava, the splash plays HELLHIT1..8 in order and
`f_death` goes to -1 - **PASS**. Snapshots in `tmp/wolf_lair/snap/`.

## Checked against retail UMK3 (2026-10-07)

`tools/umk3_stage_sweep.lua` drives RETAIL UMK3 onto any stage, with no RAM
map of its game state. It holds UMK3's stage index at RAM `01062260h`, read off
the code at FF9B95B0 that indexes the stage table FF9501F0 (Hell is entry 12),
then walks both fighters to each end while snapshotting. It logs `worldtlx`
and `worldtlx1..8` (RAM `0105D9D0h` onward; zero in the first 2-player match,
good in the next). `tools/wolf_stage_view.lua` parks our build's camera the
same way.

- **Plane positions:** at camera 400, UMK3 has plane 2 at 467, plane 4 at
  233, plane 5 at 54 and plane 6 at 1. Ours are identical. The layout read
  was right.
- **THE FLAMES WERE 400 PX OFF.** The animator table's x is relative to the
  STARTING camera, so the world x is table x + start x (190h). They burn at
  plane-2 x 532 and 1037, template-matched in UMK3's frames at error 0-9:
  inside the holes in the skeleton columns. Read raw (132 and 637), one hung
  as a stray boxed piece in empty air at the left edge, and the holes stood
  empty: "gap in the skeletons".
- **No right-hand skull entryway, in UMK3 either.** Plane 1 carries it (blocks
  at x 537h-5B1h of 1521), but the camera stops at 801 and never reaches it.
  Both games end on a skeleton column.
- **Fighters 8 px higher** (`GROUND_LIFT`): MK2 stands feet ON ground_y, and
  UMK3 stands them ~8 px above its record's FBh. UMK3's boots end at y ~243;
  ours ran to ~251-253.

## The heat haze

The arches (plane 6, rate 0, one palette) are composited by
`make_umk3lair.py --parts` into `data/LAIRWALL.BIN` (400x133 raw 6bpp,
39,900 B, `data/LAIRWALL.LOD` at Wolf linear 0xD60000). They are drawn a line
at a time by `sky_rows`, KAHN'S ARENA's machinery (ARENA_HAZE.md), via
`lair_wall_rows` in UMK3LAIR.ASM. The envelope `lair_wall_haze` puts both
waves on the glowing lava strip, world rows 163-207, down to the floor, with
an 8-row fine-wave fade-in above it. Only the arches bend. The pillars,
flames, floor, skull entries and fighters are drawn after them and stay still.

Measured in mk2wolf.exe at camera 400:

| check | result |
|---|---|
| plain blocks vs lines at offset 0 | 0 px differ in rows 131-207 |
| what the haze moves | rows 155-207 only |
| rows above the band | 0 px change |
| cost | 133 lines a frame, 0 fallbacks |

## Not done

- **The CPU never takes it.** MKDRONE's `uppercut_finish` would need a 1Fh case
  and MKDRONE sits on GSPA's ceiling; a CPU uppercut in FINISH HIM here is an
  ordinary uppercut.
- UMK3's "uppercut through the ceiling into the cave" (`blast_entry` to
  `cave_module`) is not ported.
- UMK3's own falling-body art (per-character tumble frames MK2's fighters do not have).
- UMK3's two "explode through floor" sounds (tsound 0/1, tracks 140h/145h, 27 KB):
  the rocks' burst plays MK2's BOOM (0A4h) until the Wolf sound set has room.
- The two easter eggs at the end (both players holding a button: "crispy").

## 2026-10-11: as UMK3 plays it

Playtest: "he goes up to the top, floats there, then falls into the lava, but the
screen scrolls the whole time, the lava gets stuck on a later frame, and the screen
flows so far left it shakes violently."  Four fixes, read off the arcade
(`fall_in_lava` FFAE3220, `subway_rox` FFB400C0) and MK3's MKFX.ASM:

1. **He leaves the screen.** MK2's `distance_from_ground` is `ground_y - oypos`,
   his TOP, so UMK3's 100h stopped him with his legs still in view for the 50h
   wait. `lfl_up` now rises until his measured depth under `oypos` (+10h) is above
   the screen top. (`mpart_bounds` cannot be asked in the loop: it reads 0 for an
   object above the world top.)
2. **The camera holds.** The scroller is killed (`dallprc pid_scroll`, as UMK3's
   PSX port and MKDEATH's fatalities do). `stop_scrolling` only zeroed one tick;
   once the body was `set_noscroll` the scroller read his SCREEN x as a world x,
   panned to the left limit and shook against it.
3. **The splash goes.** It was hidden with `set_inviso`, which a single-part
   object ignores, so HELLHIT8 stayed on screen. It is `delobjp`'d.
4. **The ceiling comes down and the lava hisses.** `create_fx(29h)` as he goes
   through: BOOM, shake (A,10h), and 10 small / 8 medium / 4 large cave rocks
   (`LRKS/M/L01-12`, crumble `LRKC01-12`, two palettes, `data/LAIRRX.LOD`) from
   `ground_y - 100h` - where UMK3's body stopped, the top of the screen. Each waits
   1-8 ticks, drifts up to 2 px a tick, falls under 4000h to 21-25 px over the
   ground, bounces once (2.0-4.0 up, spinning at 2), crumbles at 3 and is deleted.
   The fall's own spin rate is not set by the arcade (`subway_rock_fall` runs
   `next_anirate` on whatever the recycled process held); 4 is the A10 it loads
   there. The splash sends UMK3's tsound 5Fh, the lava hiss (`wsnd_lair_hiss`).

Rig: `wolf_lair_check.lua` with `WL_ROX=src\LAIRRX.TBL WL_HISS=067E` - camera
drift 0, top -168 during the wait, all 8 HELLHIT frames, no splash left, 22 rocks
on all four lanes and none left, BOOM +23, hiss at the splash: PASS.
