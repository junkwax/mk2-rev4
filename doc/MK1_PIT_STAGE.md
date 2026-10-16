# THE PIT (MK1), curback 01Ah

MK1's Pit as a whole stage: the bridge, the spiked pillars all the way down,
the pit floor, and the night sky. An uppercut in FINISH HIM throws the loser
off the bridge. The camera then follows him about 700 rows down the shaft onto
the spikes, as MK1 does.

The Pit Bottom (curback 00Ah) is unchanged and still a stage of its own. This
stage reuses its three modules as the floor of the shaft.

| | |
|---|---|
| Stage id | `curback 01Ah`, `table_o_mods` in `src/BGND.ASM` |
| Code | `src/MK1PTOP.ASM`: stage record, sky processes, the victim's fall |
| Generated | `src/MK1PTOPB.ASM`, written by `tools/make_mk1pit.py --apply` (build Phase B2d3) |
| Name | `txt_bg27` "THE PIT", `src/MKSEL.ASM` |
| Selection | `vs_stage_cycle` and `match_stage_cycle`, straight after GORO'S LAIR and before THE PIT BOTTOM, so the two pits run in order |
| Music | the Pit II set (`001h..004h`), `src/MAIN.ASM` |
| Fatality | MK1's rule: ANY clean uppercut in FINISH HIM (`do_uppercut`'s `ucut_mk1pit`, MOVES), human or CPU; also `check_dtp` / `st_down` (MOVES), `do_down_the_mk1pit` + `wk_stage_arm` (MKDEATH), `r_upcutted` / `r_lk_dbuc` (MKREACT), `uppercut_finish` (MKDRONE), action `act_mk1pit_fall` 050Dh |
| Video ROM | ~72KB: 4 bridge packs + 6 sky packs, all in the tops of frozen slots' guards |
| Rig | `pwsh tools/run_mk1pit_stage_fatality_test.ps1 -VictimX N -Side left\|right` |
| MK1 reference rig | `pwsh tools/run_mk1_pit_capture.ps1` (MAME `mk`) |

## Sources

Everything was read from the sources below.

- **`data/KUNGFU5.BDB/.BDD`**: MK1's own Pit background, from the leak.
  `bridge1` is one 1143x915 module holding the bridge, pillars and pit floor
  in a single canvas, which is why MK1 needed no cut. `MK1PIT.BDB` (the Pit
  Bottom) is a crop of the same canvas.
- **`C:\MAME\roms\mk.zip`** (MK1 rev 5.0, T-unit):
  - The stage table is at `FFCA7E30`. Entry 3, `FFCB8690`, is THE PIT:
    ground 264, camera y 45, x 264, scroll limits 18..744, and every module
    at rate 020000h. Its record has no `dlists` field.
  - The calla `FFCB8950` builds the sky:
    - `FFCB9C90`: ten clouds in three rows. They drift right at 0.5, 0.375
      and 0.25 px/tick; a cloud past x 18Fh moves back 23Fh.
    - `FFCB8CE0`: a six-piece rock outcrop anchored at screen (0,187).
    - `FFCB8E40`: the moon at (90,20).
    - `FFCB8F10`: after 20h ticks, one of eight silhouettes crosses the moon
      at 2 px/tick. It goes again after a 120h-tick rest, then stops.
  - All of the sky is m_noscroll, so the shaft wall slides up over it during
    the fall.

`tools/run_mk1_pit_capture.ps1` plays MK1 on the Pit and uppercuts in FINISH
HIM. That run confirmed the fall is a pan, not a cut: worldtly goes 45 -> 760
over about 40 frames and settles at 752. MK2's pan settles at 749.

## Coordinates

World coordinates are MK1's: world = KUNGFU5 canvas - (221, 907). That puts
`bridge1` at (0,112), exactly where `FFCB8690` places it.

The Pit Bottom modules are placed by pixels. `fit_bottom` takes the most common
offset between a `MK1PITBG` block and a KUNGFU5 block with identical pixels, and
it lands at (1,664). `MK1PITFS` and `MK1PITGORE` then get the Pit Bottom's own
nudge of (+15,-6).

`MK1PTOPBMOD` holds every KUNGFU5 block that starts above the fall camera
(world 749), except blocks the Pit Bottom already draws at the same place with
the same pixels. Cutting at the Pit Bottom's crop line (canvas 1571) is not
enough. Its tuning moved its top spike row down to the floor, which left a
~50-row band of shaft wall with no art in either module. All 22 blocks that
cross 749 are pixel-identical to Pit Bottom blocks, so the seam is invisible.

Draw order, back to front:

1. `mk1p_sky_lst`: the sky, sorted by `ozpos` (moon, silhouette, clouds, rocks)
2. `baklst1`: bridge and shaft
3. `baklst4`: pit walls and floor
4. shadows and fighters
5. `baklst2`/`baklst3`: the front spike row and its gore, in front of the body

## ROM space

The top module draws 46 images. 22 of them reuse `TPLHDRS` SAGs because their
pixels already exist in the Pit Bottom. The other 24, plus MK1's sky, are dealt
first-fit-decreasing into packs. Each pack sits in the top of an existing slot's guard, and that
slot's end was pulled back in `makevrom.py`.

| pack | slot (phys) | donor | payload |
|---|---|---|---|
| MK1PT1 | 0x756800..0x75AC00 | SHAOSIT | 16,638 B |
| MK1PT2 | 0x7A2A00..0x7A6000 | NOOBPORT | 13,146 |
| MK1PT3 | 0xBEB400..0xBEE000 | ERMFIRE | 10,798 |
| MK1PT4 | 0xBF6600..0xBF8400 | SAHELI2 | 4,530 |
| MK1PSK1 | 0xBFD600..0xC00000 | SHAOFIST | 10,218 |
| MK1PSK2 | 0x736600..0x738000 | JCAIRKIK | 6,362 |
| MK1PSK3 | 0x9FE800..0x9FFE00 | SAHELI3 | 5,352 |
| MK1PSK4 | 0xBE7000..0xBE8000 | STATREF | 3,864 |
| MK1PSK5 | 0xBE5400..0xBE6000 | HAMGLOW | 1,340 |
| MK1PFLY | 0x733A00..0x734000 | JCFKICK | 942 |

Each donor keeps its base and about 300-1,000 B of guard. The slots are
declared in three places that must agree: `PACKS`/`SKY_PACKS`/`FLY_PACK` in
the tool, `CUSTOM_VIDEO_SLOTS` in `makevrom.py`, and each LOD's `***>` line.
The tool writes the LODs, so in practice only the first two can drift.

JCLOGO's guard is not used. `clip41` treats any flipped piece with a SAG in
0x728000..0x730000 as a Cage logo piece.

### Every record is decoded back out of the ROM

`--apply` and `--check` both run `verify_rom`. It decodes all 58 packed records
(24 bridge images and 34 sky records) out of their IRWs and compares them with
the source pixels. Any difference fails the build.

This is not paranoia. Four KUNGFU5 images (48h, ABh, and the two shared 96h and
F9h) end in one out-of-range pixel: 79, 107 or 153 in a 64-colour palette, a
BDDTool artifact. LOAD2 writes that last pixel wider than the record's 6 bits,
and the overflow lands in the next record's first rows. In the first build it
shredded the lion statue's torso (4Bh, straight after 48h in MK1PT4): 784 of
920 pixels were wrong, with no error anywhere. `mask6` now clears those bits
before LOAD2 sees them. `v & 63` is exactly what MK1 drew, because MK1 stored
this art at 6bpp.

## Editing

```
python tools/make_mk1pit.py --report                 # deal, sizes, layout numbers
python tools/make_mk1pit.py --preview                # tmp/mk1pit/preview.png
python tools/make_mk1pit.py --preview 264,45 264,600  # any camera x,y
python tools/make_mk1pit.py --sky --parts            # after changing slots or source art
python build.py                                      # full: new packs need LOAD2
```

Never hand-edit `src/MK1PTOPB.ASM`, the `data/MK1PT*`/`MK1PSK*`/`MK1PFLY` files,
or `data/MK1PSKY.IMG`/`MK1PFLY.IMG`. Phase D's `--check` fails the build if any
of them drift from the tool. `--sky` and `--check` need `mk.zip`.

## The fatality

`r_fall_down_mk1pit` follows YOTEIGAI TOR's `r_fall_off_mountain`: the same
launch, scroller hand-off, clamp-before-chase and settle. The differences:

- **No target to aim at, but he is kept in shot - by the CAMERA first.**
  The pit floor spans the whole stage on the fighters' own plane, and he is
  thrown 1 px/tick, so all that matters is that he does not land off the
  screen. `mk1p_fall_scroll` pans sideways with him for the length of the
  fall: the Pit II's own `pit_scroll` (BGND.ASM) line for line - centre on
  the body, 6 px deadzone, one table step of scroll a tick, stop dead at the
  stage's scroll limits.
- **`mk1p_hold_on_screen` is the fallback, not the first line of defence**
  (2026-09-29). It leans him back inside screen x 100..300, because a body
  lying flat reaches ~80 px either side of its anipoint, and a one-way
  barrier is not enough: at the right scroll limit a fighter already stands
  at screen x ~336, and the first sweep landed him at 351, half off the
  screen. But it only runs when `worldtlx` is already **on** a scroll limit.
  It used to run everywhere, because this was written from YOTEIGAI TOR's
  fall - which aims the body at one fixed target and *wants* the camera
  still, so it stops the horizontal scroll and never takes it back. Inherit
  that on a stage with 726 px of scroll and the two work against each other:
  from mid-bridge the view is nailed down, the body reaches the edge of the
  band on its own throw velocity, and the hook hauls it back in. On screen
  that is the body bouncing off the side of the frame instead of the stage
  opening out ahead of it. Now the view moves (free) before the body does
  (not free), and the lean is what is left when the stage runs out.
- **The correction happens on the way DOWN, and as an acceleration** (rewritten
  2026-09-22 - see "The shape of the fall" below). While he rises the hook does
  nothing at all: that half of the arc is the uppercut, and it is the only half
  the hit can be read from. Falling, it leans him towards the band at 1/4 px a
  tick per tick, capped at 3 px/tick, and eases back to the throw's own
  1 px/tick once he is inside it. It never assigns a velocity outright, so
  there is no tick on which he changes direction instantly.
- **Repell is off for the fall** (`f_norepell`, the `disable_repell` pattern
  every other fatality already uses). It has three ways of disagreeing with a
  man falling 700 rows past the winner, and all three were firing - see the
  trace below and the comment in `r_fall_down_mk1pit`.
- **`f_shadows` is cleared at the throw.** `p_ganiy` now points 700 rows down,
  and a shadow placed off it floats above the deck. `start_shadows` turns them
  back on next round.
- **The trigger is MK1's.** MK1's upcutted reaction (`FFCD1440`) tests only
  the stage and the finish window, so on THE PIT any clean uppercut in FINISH
  HIM goes down, from a human or the CPU. `do_uppercut` sets
  `act_mk1pit_fall` after contact, the same way the Dead Pool arms its acid
  drop. The stage combos through `check_dtp` still work too.
- **The throw is MK1's** (`FFCD1720`): 1 px/tick sideways, -0C0000h up and
  6000h gravity. Those last two are the same as MK2's plain uppercut.
- **The landing is MK1's:** Pit II's impact sound, MK1's 8000Ch shake, and
  the victim's flat-on-back frame. Then `mk1pit_fountain` (blood slot 18h,
  MKBLOOD.ASM) runs MK1's `FFDE4B40` frame for frame:
  - 14 goober droplets thrown 8-12 px/tick up, animating GOOBER1-14 twice,
    then splatting on DRIP5-7
  - 12 UPSPLAT1-7 puffs
  All of that art was already in ROM (MK6MIL), pixel-identical to MK1's.
- **The landing closes the fatality with `death_blow_complete`**, as PIT II's
  pit bottom does (`fall7`, MKFALL.ASM) and as MK1 does (`send_code_a3 09Ch`,
  `FFCD1A00`). It raises `f_death` to -1 *and* sends 035h, the death-blow-over
  tune. Writing `f_death` by hand - which THE DEAD POOL and YOTEIGAI TOR both
  do - is only half of it, and here the other half is load bearing: `rfmp3`
  calls `nosounds`, which kills the 034h death-blow tone `make_db_tone`
  started, so without the 035h the fall, the impact and the whole wait for the
  round to tear down played in silence. The Dead Pool gets away with the same
  shortcut only because it never calls `nosounds` at all.
- **The goobers' floor is an ANIPOINT, not an `oypos`.** MK1 states it as
  `ground_y-14` and tests the droplet's anipoint against it (`FFDE84B0` /
  `FFC89170`). `oypos` is not a fixed point on a droplet: `ani` migrates it by
  the anipoint delta on every frame change (`anig1`, MKDISP.ASM), so only
  `oypos+aniy` holds still while the art animates. Taking the floor off
  `oypos` at spawn took it off **BIGBLD1** - the record `get_jt_blood` builds
  every droplet with, and the one frame a goober never shows - whose `aniy` is
  **-27**. That pinned the floor 27 rows too low, and the GOOBER frames the
  droplet actually falls in (`aniy` 0..10) moved it again. Measured on the
  real machine with `MP_BLOODDUMP=1`: the drips came to rest at `oypos`
  989..1010 on a pit floor of 989 - at and below the bottom of a 254-row
  screen - so MK1's splat on the floor was never seen. Stated as an anipoint
  the drips land at 975 (`ground-14`), drawing on screen rows ~216..231, which
  is where MK1's sit (measured 209..232 off `tools/run_mk1_pit_capture.ps1`).
- **Height and shadows.** The ground is 258, not MK1's 264. MK2's fighters
  stand lower on their anchor than MK1's, so at 264 their feet were on the
  deck's dark front face. At 258 the boots end on world 265, on the lit top
  face, with 16 rows of deck behind them (the Dead Pool's walkway has 16).
  - The shadow is clipped to the deck, world rows 249..281, as THE DEAD POOL
    clips its walkway. `deck_band` counts a row as deck at 90% coverage,
    because the top two rows are chipped stone. Requiring 100% left a 2-row
    strip of deck showing above every shadow.
  - `@shad_bias` is +6, measured with `tools/mk1pit_shadow_bias_sweep.lua`,
    which sweeps the bias live and diffs shadows-on against shadows-off
    frames. At +6 the shadow's foot row lands on the boots' last row
    (screen 221 against 220, the same 1-row overlap stock stages have). The
    first try, +24, left it 14 rows under the feet.
- **The whole shaft is covered.** Rendered at both scroll limits and
  mid-bridge, at every depth from the bridge to the floor camera, there is no
  hole. The sky only shows between the side towers in the upper shaft, as in
  MK1. MAME frames from both ends of the bridge agree.

## Rig

`tools/mk1pit_stage_fatality_test.lua` forces the stage, and checks:

- the sky is fully built (`mk1p_sky_objs`) and drifting
- the fatality fires (050Dh)
- the camera ends exactly on `mk1p_fall_cam`
- the body lands on screen
- `f_death` is -1

`MP_BLOODDUMP=1` adds a per-5-tick dump of every object in `objlst` for
140 ticks after the landing - `oypos`, screen row, anipoint (`oypos+aniy`),
height, z and y velocity, all read out of the object and its own image
header, so it needs no table of record names. It is how the fountain's
floor was measured rather than eyeballed off a PNG.

It reads the numbers from `src/MK1PTOPB.ASM`.

The sweep that passed (2026-09-22), as victim x and attacker side, then the
landing screen x:

| victim x | attacker | landed at (2026-09-29) | xturns | 2026-09-22 | 2026-09-16 |
|---|---|---|---|---|---|
| 1080 | left | 244 | 1 | 244 | 299 |
| 900 | left | 260 | 0 | - | - |
| 700 | right | 193 | 0 | 141 | 102 |
| 400 | left | 205 | 0 | 259 | 298 |
| 200 | right | 113 | 1 | - | - |
| 60 | right | 158 | 1 | 158 | 102 |

The camera was on 749 and `f_death` was -1 in every trial, with 46 sky objects,
39 of them drifting.

`xturns` counts how many times the body changed horizontal DIRECTION during
the fall, and it is the whole verdict on which mechanism did the work:

- **0** - the camera carried it. The body never left the line the uppercut
  gave it (`MP_FALLTRACE` shows `oxvel` flat at 1.000 for every tick of the
  fall, `oxpos` 400 -> 505, screen x pinned at 205 by the pan).
- **1** - the camera ran out of stage and the lean finished the job. Thrown
  out, leaned back, once.

Both corners still read 1 and land on exactly the numbers the 2026-09-22
sweep measured, which is the control: the fallback path is unchanged, only
the set of positions that reach it has shrunk to the corners it was written
for. The rig fails above one.

## The shape of the fall

`MP_FALLTRACE=1` logs the victim's screen x and both velocities once per tick
for the whole fall. It is how this was judged, because a 20-tick snapshot
cannot show a one-tick reversal. Traced at victim x 1080, camera on its right
scroll limit, the version before 2026-09-22 read:

| rel | what happened | screen x |
|---|---|---|
| 002 | thrown, 1 px/tick out | 339 |
| 003 | outward speed **zeroed** - 31 ticks of climb with no knockback | 340 |
| 034 | apex: straight to -3 px/tick | 340 |
| 047 | 42 px back - **past where he was thrown from** | 301 |
| 048 | 0 px/tick, dead stop, 8 ticks straight down | 298 |
| 056 | +3 px/tick - `repell_now`, as the body falls past the winner | 298 |
| 063 | -1.5 px/tick - `rep8` halving what the hook asked for | 319 |
| 070 | -3 px/tick, then stop again at 073 | 308 |

Seven changes of direction in one fall, four of them instant, and the winner
slid 35 px along the bridge (atk_x 1025 -> 990) while it happened.

The first line is the one that shows. A cornered man starts OUTSIDE the band,
so the old rising rule took the knockback away on the tick after contact and
the uppercut launched him vertically - which is the one thing an uppercut must
never look like. It bought nothing, either: he is off the top of the screen
from rel ~013 to rel ~057, because the camera holds at `mk1p_worldy` until he
is 060h rows into it. The whole climb and the first third of the fall are
unwatched. So the correction now happens where it is free, and does not happen
at the one moment it is being watched.

The same trace after: 1 px/tick out for the whole climb (336 -> 351, where the
stock edge clamp holds him, exactly as it holds any cornered fighter), then a
continuous ease from +1 through 0 to -3 over eleven ticks, the cap held while
he closes, then an ease back to -1 that he lands on. One turn, no steps, and
the winner does not move.

Two more rigs cover what that one cannot:

- `pwsh tools/run_mk1pit_rounds_probe.ps1` plays three rounds and checks the
  sky is rebuilt exactly once per round. All three rounds showed 46 sky
  objects, 38 cloud pieces and 298 free objects, so no process doubles and
  nothing leaks.
- `pwsh tools/run_mk1pit_drone_finish_probe.ps1` lets the CPU win a one-player
  match and pins `@rand` negative for FINISH HIM, so `uppercut_finish` takes
  the pit branch. It passed: the CPU threw the loser down the pit, the camera
  reached 749 and `f_death` went to -1. Its "human" readout flips between
  rounds and is not trustworthy, but no input is pressed during the fight, so
  only the drone can have thrown it.

Frame load: `tools/run_runtime_budget.py --scenario 1,11,26` ran clean. The
DMA queue high-water was 213/500 cells with no queue overflow and no dropped
sprites, identical to THE CAVE and the saved Dead Pool baseline. Those
counters latch from power-on, so this only shows no regression.

The Pit Bottom's own art (MK7MIL) has the same last-pixel spill. Five of its
images carry an out-of-range index, and the records after two of them are
1 and 2 pixels off (TPLHDRS 41 and 51). That predates this stage and was left
alone.

Stage select with real input:
`pwsh tools/run_cave_stage_probe.ps1 -Tag mk1pit -Stage 1a`. It taps LEFT from
Dead Pool until 1Ah, then parks the camera at both scroll limits for snapshots.
