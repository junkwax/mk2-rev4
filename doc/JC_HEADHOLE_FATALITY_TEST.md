# Johnny Cage Headhole Fatality Test

Date: 2026-07-11

> **RETIRED (2026-07-13):** the headhole implementation this file tests was
> rebuilt from the ground up. The head is now a multipart piece of the
> victim body's composite `a_headhole_fall` frames; the overlay process,
> KHEART/STAB/SPLAT/SPILL prop lanes, and their pass criteria no longer
> exist, and the Lua harnesses below check retired symbols/addresses.
> Everything below is historical. Current architecture:
> [JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md](JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md).

## Status

Working in the dedicated Lua harness:

```powershell
.\tools\run_jc_headhole_fatality_test.ps1 -TimeoutSeconds 180
```

Latest validated run:

```text
tools/screens/jc_headhole_fatality/run_20260713_074210
P1 Johnny Cage vs P2 Kung Lao on Kombat Tomb
PASS reason=deathblo_then_jc_victory_no_crash fatality_frame=1543 complete=true deathblo10=true victory=true
```

The shared Liu-timing reaction has dedicated Liu and Kung Lao Lua entry points.
The default script remains the Baraka regression:

```powershell
.\tools\run_jc_headhole_fatality_test.ps1 -Stage 1 `
  -ScriptName jc_headhole_liu_no_wobble_test.lua -TimeoutSeconds 110
.\tools\run_jc_headhole_fatality_test.ps1 -Stage 1 `
  -ScriptName jc_headhole_kung_lao_test.lua -TimeoutSeconds 120 -Sound
```

Validated shared-model runs are Baraka `run_20260711_213945`, Kung Lao
`run_20260711_214911`, and the final post-Kung-asset Liu Kang regression
`run_20260711_215735`.

The test boots directly to round 2 Finish Him on the Kombat Tomb stage, triggers Cage's
test-only HP fatality hook, captures the animation, and watches the game state
for crashes or RAM corruption.

The placement/readout variant writes one row per native `DBLO2` source tick by
default:

```powershell
.\tools\run_jc_headhole_anim_readout.ps1 -TimeoutSeconds 180
```

Latest readout artifacts:

```text
tools/jc_headhole_anim_readout/run_20260711_011420/jc_headhole_anim_readout.csv
tools/jc_headhole_anim_readout/run_20260711_011420/jc_headhole_anim_readout.txt
tools/screens/jc_headhole_anim_readout/run_20260711_011420
```

For body/head sync work, run the same harness with one-frame sampling:

```powershell
.\tools\run_jc_headhole_anim_readout.ps1 -Step 1 -TimeoutSeconds 180
```

For transition-frame screenshot checks, pass the fatality-relative frames to
capture:

```powershell
.\tools\run_jc_headhole_anim_readout.ps1 -Step 1 -SnapshotRels "0,6,7,8,18,19,20,21,22,32,33,34,44,45" -TimeoutSeconds 180
```

The Lua harness also draws a compact HUD over the running game:

- `P`: pause
- `Shift+P`: step one frame while paused
- `F12`: screenshot
- `Shift+F7` + slot: save state
- `F7` + slot: load/replay saved state
- `Esc`: quit MAME

Current pass criteria:

- Cage reaches `JC2DEATHBLO10*`,
- victim-owned `SPILL1` starts with victim reaction row 0, holds for 18
  authored rows, and reaches `SPILL13` before victory begins,
- `f_death` clears,
- Cage enters the real `JCVICTORY*` animation after the DeathBlo sequence,
- no lockup or `pf_ram` corruption is detected.

## Current Test Hook

`jc_headhole_hp_test` is enabled in `src/MAINEQU.ASM`, so Cage HP during Finish
Him routes through `do_jc_headhole` from `src/MOVES.ASM`. This is a test path,
not the final player-facing input.

## Debug Finding

The Liu Kang setup was not the source of the glitch. Debug logs showed both
fighters grounded at fatality start (`y=108`), and Liu was already in the real
stunned/Finish Him process. The bad visual state and crash happened later in
the victim reaction path.

The corruption came from `jc_headhole_body_fall` advancing past the decapitated
fall animation terminator. The earlier version manually skipped the knee-wobble
section with raw pointer math, then continued calling `do_next_a9_frame` even
after the animation hit its zero terminator. Around fatality-relative tick 91,
global state started taking garbage values such as `gstate=0xe7e7`.

## Fix

For normal victims, `jc_headhole_body_fall` uses the per-character stock
decap-fall tables with the custom victim-lane choreography:

- show the first decap body frame at the `JCHIPUNCH3` beat,
- hold frame 1 for 13 authored rows,
- play frames 2 and 3 once each,
- scan safely to the end of the stock wobble group without displaying it,
- play frames 4 through 7 once each.

The old screen-shake calls and visible knee wobble are omitted for this fatality.
The safe group scan preserves the table layout without advancing through a zero
terminator, which was the original corruption source.

## Visual Lanes

The full visual path is active again:

- Cage plays the native `CAGE10.IMG` `DBLO2` sequence once: 12 unique image
  steps with ticks `6,1,1,10,1,1,1,1,10,1,1,10` (44 total). The attacker
  script contains `JC2DEATHBLO1..10` only once; the timing driver supplies
  the holds.
- `JCHIPUNCH3` begins at relative source tick 8, so the attacker-synchronized
  HEADHOLE, body, STAB, and SPLAT lanes begin there as well. KHEART is a
  separate companion lane and begins after the 44-tick attacker pass.
- Every normal victim starts its own `*DECAP1` plus
  `*HEADHOLE1`/`*DEADHEAD1` on the first `JCHIPUNCH3`. Frame 1 is held for
  13 authored rows, then frames 2..7 advance once each without knee wobble.
- Native `DBLO2` is direct `[frame, tick]` data and has no inline
  `ani_sound,0feh` / Dan Forden "Yeah!" command. Do not reinsert that retired
  preview-derived cue into the attacker stream or require it in a regression.
- `BWHOOSH3` fires before `JC2DEATHBLO3`, `BIGHIT3` on the first
  `JCHIPUNCH3`, and `VPDEATH` immediately after that impact.
- `MUNCH` fires on `KHEART6C`; the sound command is consumed without adding or
  removing an authored image row.
- Cage transitions into his normal victory animation only after `SPILL13`
  appears.
- `jc_headhole_head_proc` is enabled for the victim head overlay.
- Cage owns only the DeathBlo attack lane and KHEART. The victim takeover owns
  the opponent body/head plus STAB, SPLAT, and SPILL so all reaction props use
  the same live victim anchor.
- Cage is placed behind the victim with the stock `me_in_back` helper:
  Cage uses `back_z` (`0x4f`) and the victim uses `front_z` (`0x50`).
- The head overlay keeps its own `oflags2`; copying the victim multipart flags
  onto the single overlay object corrupts display handling.

## Blood/Anipoint Alignment

`data/LIUFALL.asm` defines the shared victim/body anchor and base local offsets.
The runtime substitutes the live opponent object for that anchor and mirrors
the complete victim composition to face Cage.

- `lineup_1pwm` already applies the image anipoint. Resetting the prop back to
  the body anchor discarded that placement, so every blood frame was shifted.
  The runtime helpers now recompute each prop from the live body anchor on
  every tick and apply the image anipoint exactly once.
- Cage is explicitly unmirrored and placed at the exported `(+63,0)` offset
  from the victim anchor. KHEART stays Cage-owned and uses its own per-frame
  local table.
- The base victim effects use STAB `(-13,-27)`, SPLAT `(-9,-29)`, and SPILL
  `(-103,-130)`. These signed local values are applied once after draw mirroring.
- KHEART uses `front_z+4` (`0x54`), in front of the victim body's `front_z`
  (`0x50`).
- SPILL preserves signed `.word` offsets. `SPILL1` appears with victim row 0
  and holds for 18 authored rows; `SPILL2..13` then advance every five sleeps.
  The final spill frame remains held, and Cage's victory starts only after the
  lane reaches `SPILL13`.
- The head overlay uses an explicit horizontal mirror and follows the victim
  body anchor, producing the verified `UGHEADHOLE1..7` progression rather
  than tracking Cage's hand.
- KHEART now uses the hold loop and remains in `KHEART6D`; SPILL uses the
  hold loop and remains in `SPILL13`. Both processes use the persistent head
  class so their terminal effects survive the transition into Cage's victory.
- The dedicated opponent animation slot is used for every normal character
  family, and every `*HEADHOLE7`/`*DEADHEAD7` table entry remains held through
  victory. Bosses use their existing knocked-down fallback because they do not
  have the normal dedicated headhole table.

### Stock SPILL Audit

`SPILL1..13` is not called by any stock fatality or blood routine. In both
`mk2-readonly` and the active source, the labels exist only in `MKBLOOD.TBL`
and the corresponding LOD asset list. The closest used stock effects follow a
different contract: `a_face_blood` plays `SPLAT1..7` under `pid_blood` and then
jumps to `blood_death`, which calls `delobjp`; the decap blob similarly plays
both halves and then terminates. There is therefore no stock terminal-SPILL
hold routine to reuse. Cage's `pid_head` plus explicit `SPILL13` hold is the
intentional persistence implementation.

The final readout keeps `UGDECAP7` and `UGHEADHOLE7` in `objlst` at the late
victory snapshots, so Baraka's head no longer disappears when victory begins.

The dedicated Liu Kang run `run_20260711_215735` verifies the no-wobble,
fully mirrored reaction. At relative tick 110 the live scene contains
`SPILL2` and `LKDEADHEAD7`. At tick 300, `SPILL13`, `LKDEADHEAD7`, and
`KHEART6D` remain linked with live palettes. The Lua test completed without a
crash or RAM-corruption error.

## Headhole Object Tracking

The victim headhole is a separate single-sprite object controlled by
`jc_headhole_head_proc`. It is anchored to the victim body object via `pa10`
and an explicit mirrored anipoint lineup, so it follows the decap body fall,
not Cage's hand.

The terminal `HEADHOLE7` hold continues to run that lineup once per game tick.
This matters when Cage's victory setup nudges the defeated body from `x=711`
to `x=704`; a static terminal object remained at the pre-victory coordinate
and appeared detached or missing.

Historical verification: `run_20260711_092209` passed the then-current
DeathBlo/DFYeah check, Cage victory, and no-crash checks. The DFYeah condition
was retired with the preview-derived table. Before and after the victory nudge, the HUD reports the
same head-to-body delta, `(-119,+123)`. The late `0011.png` capture retains
`UGHEADHOLE7` and the red terminal ground SPILL through the completed victory
pose.

The 2026-07-10 one-frame readout below documents the retired stock-wobble
prototype. It is retained only as transition-history reference:

- `pa8` = headhole object (`LKDEADHEAD*`)
- `pa10` = Liu Kang body anchor
- rel 40: `LKDECAP1` / `LKDEADHEAD1`
- rel 86: `LKDECAP2` / `LKDEADHEAD2`
- rel 92: `LKDECAP3` / `LKDEADHEAD3`
- rel 98, 118, 138, 158: `LKDECAP4` / `LKDEADHEAD4`
- rel 108, 128, 148: `LKDECAP3` / `LKDEADHEAD3`
- rel 164: `LKDECAP5` / `LKDEADHEAD5`
- rel 170: `LKDECAP6` / `LKDEADHEAD6`
- rel 176: `LKDECAP7` / `LKDEADHEAD7`

That historical transition table confirmed the deadhead overlay changed with
the body throughout the stock drop. The shared no-wobble sequence supersedes
those transition ticks for every normal victim.

## Liu Kang Deadhead Seam

Liu Kang uses different source naming from several other victims. The image
records in `KANG10.IMG` are `LKDEADHEAD1..7`; there are no
`LKDEADHOLE*` or `LKHEADHOLE*` image records. In active code, animation-table
slot `0x40` selects `a_headhole`. Its ASM-only wrappers
`LKHEADHOLE1..7` each point to the corresponding `LKDEADHEAD1..7` image.
The readonly source left Liu's slot `0x40` as `DUMMY`, so this wrapper wiring
is part of the restoration rather than a stock runtime path. Baraka continues
to use the separate `UGHEADHOLE1..7` family.

The first transition-frame screenshots showed the deadhead stepping in sync but
visually floating slightly above the decap body during the fall. This was not a
tick-order problem.

`src/LKHEADHO.TBL` uses Liu Kang's bloody palette (`LKBLUD1_P`) for
`LKDEADHEAD1..7`, matching the decap body palette instead of the copied
`CAGE_P` value. The earlier sidecar also added a uniform four-pixel downward
correction, but the resulting overlay did not track the authored fall cleanly.
The correction has been removed and the table now uses the exact anipoints
stored in both the active and readonly `KANG10.IMG` files:

- `LKDEADHEAD1`: `(5,-9)`
- `LKDEADHEAD2`: `(1,-17)`
- `LKDEADHEAD3`: `(0,0)`
- `LKDEADHEAD4`: `(-2,-40)`
- `LKDEADHEAD5`: `(-38,-40)`
- `LKDEADHEAD6`: `(-78,-76)`
- `LKDEADHEAD7`: `(-90,-111)`

The rebuilt Liu Kang regression `run_20260711_203223` passed the complete
fatality, victory, and persistence checks with these readonly points. Runtime
sampling confirms the expected four-pixel correction relative to the removed
sidecar offsets: `LKDEADHEAD3` is at Y108 during the knee sequence and the
held `LKDEADHEAD7` is at Y219 after the ground fall. The latter remains live
alongside `SPILL13` and `KHEART6D` through relative tick 300.

### Shared No-Wobble Reaction

`data/LIUFALL.asm` is custom victim-side reaction data. Its historical preview
material is not attacker authority: native `CAGE10.IMG` `DBLO2` remains the
source for Cage's frame order and ticks. The runtime substitutes the live
victim object for the shared anchor and uses these lanes:

- body: `LKDECAP1` held for 13 rows, then `LKDECAP2..7` once each;
- deadhead: `LKDEADHEAD1` held for 13 rows, then `LKDEADHEAD2..7` once each;
- STAB: `STAB1..9` at local `(-13,-27)`;
- SPLAT: `SPLAT1..7` at local `(-9,-29)`;
- SPILL: `SPILL1` held for 18 rows, then `SPILL2..13` once each at
  local `(-103,-130)`.

The export is authored mirror-off, but Cage is left of the opponent in the test
match. The runtime mirrors the whole composition around the victim anchor:
multipart body, deadhead, STAB, SPLAT, and SPILL. Mirroring is draw-only; each
signed local X/Y offset is consumed once. Every normal victim uses this timing
with its own character-specific decap and headhole frames.

Run `run_20260711_215735` passed with Liu facing Cage. The captures retain the
mirrored `LKDEADHEAD7`, `SPILL13`, and `KHEART6D` through Cage's victory pose.

### Kung Lao Reaction

The Kung Lao custom reaction data provides character-specific blood placement
and the additional `SMGUSH` lane. It must not replace the native Cage attacker
sequence or its ticks:

- STAB: 13 preview rows at local `(0,-22)`;
- SPLAT: `SPLAT1..7` followed by `SMGUSH1` at local `(3,-22)`;
- gush: `SMGUSH2..14`, first at `(-5,-33)` and the rest at `(6,-31)`;
- SPILL: `SPILL1` held for 18 rows, then `SPILL2..13` at `(-126,-138)`.

`SMGUSH1..14` were appended to `MOVEART1.LOD` under a new `KGBLOOD.TBL` output.
Appending them left every pre-existing MOVEART1 SAG unchanged. The payload grew
by 11,008 bytes and remains inside its fixed slot. Run `run_20260711_214911`
passed the full fatality and victory checks; inspected standing, fall, and
terminal frames show no garbled Kung Lao or blood art.

The final Kung Lao verification is `run_20260711_221639` on Kombat Tomb with
audio enabled. At the victory and pass checkpoints, `TMDEADHEAD7`, `SPILL13`,
and `KHEART6D` remain live and linked in `objlst`. The prior yellow/garbled
blood was a stale video-ROM package: `build.py` had regenerated the IMG-derived
IRWs, but `makevrom.py` had not regenerated the video chips. Rebuilding the
video ROMs and repackaging removed the mismatch. After any `.IMG`, `.LOD`, or
sprite-table change, all four build stages below are required.

Lua/debugging gotcha: multipart/player objects report useful SAGs from their
multipart RAM at `oimg`, but the headhole overlay is a single object. Its
runtime SAG must be read from `osag`; reading `oimg+0` just returns the image
size word and makes the head object look missing.

## Timing and Screenshot Capture

The native `CAGE10.IMG` `DBLO2` attacker pass is 44 scheduler ticks. Capture
it with `Step 1`; a five-tick sample is only a coarse companion-art view and
will miss one-tick source transitions. The native attacker boundaries are
relative ticks `0,6,7,8,18,19,20,21,22,32,33,34`, followed by completion at
tick `44`. `-TargetedSnapshotsOnly` suppresses automatic start/mid/victory
snapshots.

Use this command to capture every native attacker boundary and its immediate
post-pass KHEART start:

```powershell
$rels = 0,6,7,8,18,19,20,21,22,32,33,34,44,45
.\tools\run_jc_headhole_anim_readout.ps1 -Step 1 `
  -SnapshotRels ($rels -join ',') -TargetedSnapshotsOnly -TimeoutSeconds 120
```

The verified run `run_20260711_055904` produced exactly 51 composite scene
screenshots, `0000.png` through `0050.png`, for relative ticks `0,5,...,250`.
They are stored under
`tools/screens/jc_headhole_anim_readout/run_20260711_055904/mk2/`.
The `SNAPMAP` entries in the run log map every PNG to its relative tick and
active effect labels. The on-screen `FX` line also reports the live KHEART,
SPILL, body, and headhole frames.

Useful landmarks in that run:

- `0003.png`, rel 15: `JCSPLAT2` and `JCSTAB2`
- `0009.png`, rel 45: `KHEART1`
- `0031.png`, rel 155: `SPILL1`, `UGHEADHOLE7`, and `KHEART6D`
- `0032.png` through `0043.png`, rel 160-215: `SPILL2..SPILL13`
- `0050.png`, rel 250: held `SPILL13`, `UGHEADHOLE7`, and `KHEART6D`

That historical run passed the then-current DeathBlo, DFYeah, victory, and
no-crash checks. The DFYeah check is retired; current validation uses the
native 12-pair DBLO2 pass, terminal DBLO10, completion, and victory.
Instrumented object dumps through rel 250 confirm that all three persistent
effect processes remain alive, their objects remain linked in `objlst`, and
their allocated color-RAM palettes remain nonblack with stable checksums.
Therefore the late HEADHOLE/SPILL visibility issue is not caused by process
termination, object deletion, or palette loss.

The focused alignment run `run_20260711_052156` and its `KHEART6D xy=722,242`
and `SPILL13 xy=553,233` captures predate the Cage-only unmirrored export. They
remain useful regression history but are not coordinate targets for the new
plain-placement pass.

## Interactive KHEART Placement

`tools/run_jc_kheart_placement.ps1` launches a dedicated interactive Lua and
pauses before the fatality starts. Controls are also shown in the MAME HUD:

- `Space`: start the fatality from the pre-fatality pause; afterward commit
  the current coarse KHEART sample and advance five runtime ticks.
- Arrow keys: move the active KHEART object one world pixel per input sample.
- `A`: commit the current placement and restore the previous scene frame.
- `S`: commit and advance one scene frame, equivalent to `Space` after start.
- `Esc`: exit MAME and leave the latest placement data on disk.

Manual samples have no timeout and never auto-advance. The HUD says
`PAUSED - NOT CRASHED`; the editor remains on that composite scene until a
forward/back key is pressed. Forward advancement uses five explicit MAME frame
steps, avoiding an uncontrolled unpause window between coarse samples.

Each run writes `jc_kheart_placement.csv` and `jc_kheart_placement.txt` under
`tools/jc_kheart_placement/run_<timestamp>/`. Every row records the complete
scene index, fatality-relative tick, scene and KHEART labels, natural world
position, final world position, and X/Y delta. Scene history uses per-run MAME
state files rather than retaining 15 MB in-memory buffers for every frame.

Run it with:

```powershell
.\tools\run_jc_kheart_placement.ps1
```

## Harness Positioning

The Lua test now preserves each character's own baseline Y anchor while moving
them into fatality range. Cage remains at his natural stance anchor
(`y=101`) and Liu Kang remains at his (`y=108`), instead of forcing Cage down to
Liu's object Y and making the pre-fatality matchup read wrong.

## Build Commands Used

```powershell
$env:ALLOW_STOCK_BG_DRIFT='1'; python build.py
python makerom.py
python makevrom.py
python mamerom.py --no-install
.\tools\run_jc_headhole_fatality_test.ps1 -TimeoutSeconds 180
.\tools\run_jc_headhole_fatality_test.ps1 -Stage 1 -ScriptName jc_headhole_liu_no_wobble_test.lua -TimeoutSeconds 110
.\tools\run_jc_headhole_fatality_test.ps1 -Stage 1 -ScriptName jc_headhole_kung_lao_test.lua -TimeoutSeconds 50 -Sound
.\tools\run_jc_headhole_anim_readout.ps1 -TimeoutSeconds 180
.\tools\run_jc_headhole_anim_readout.ps1 -Step 1 -TimeoutSeconds 180
```
