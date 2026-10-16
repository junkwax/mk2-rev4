# Fast shadows on five more stages

Continuation of [Wasteland](WASTELAND_SHADOW_PROTOTYPE.md) and
[Kombat Tomb](TOMB_SHADOW_PROTOTYPE.md), 13 September 2026. Opportunity 01.
**Enabled in source; paired measurements and native checks passed in MAME.**

## Native check on the rebuilt ROM

`build.py --asm-only` (all Phase D guards pass; the existing boxlab freshness
warning only), packaged privately to `tmp/shadow_stages/build/rom/mk2.zip`,
not installed. `tmp/shadow_stages/native.py` boots each stage with no override
and asserts the mode the stage picked for itself, with no new late frames:
Dead Pool 2, Forest 2, Armory 2, Portal 2, Arena 2, Tomb 2, Wasteland 2,
Tower 1, Bridge 0 - **9/9 pass**. After the second batch was added and the
ROM rebuilt again, the same check over Goro's Lair, Pit Bottom, Outer Haven,
FLAPJACK and Yoteigai Tor (all 2) plus the nine above: **14/14 pass**. These
are separate boots, not a stage-transition test.

## Change

THE DEAD POOL, LIVING FOREST, THE ARMORY, THE PORTAL and KAHN'S ARENA now select
`shad_fast=2` in their stage setup routines (`calla_dedpool`, `calla_forest`,
`calla_armory`, `port_calla`, `arena_calla` in [BGND.ASM](../../src/BGND.ASM)),
exactly as Tomb and Wasteland do. Compressed pieces take the two-blit `shadf`
path; raw pieces keep the row loop. `init_bakmods` still resets the mode to 0
for every stage, so a stage that does not ask keeps stock shadows.

THE DEAD POOL clips its shadow to the walkway (`shad_hi` 16 / `shad_lo` 21).
`shadf` honours that band through the DMA's Y window (`shad_ytop..shad_ybot`),
and the captures confirm it: no acid pixel differs.

**THE BRIDGE (6) is left alone.** Its display list has no shadow marker
(`-2`), so no shadow is drawn there in either mode: 69.12 starts per refresh
in both, identical captures. There is nothing to take.

## Measurement

`tools/run_wasteland_shadow.py`, unchanged in method: one frozen ROM run twice
per trial, legacy mode 0 against mode 2 forced at runtime, identical scripted
inputs (walk both ways, jump, crouch, attacks), refreshes 120-900, 781 trace
rows and 27 full-screen captures per mode. Six pairings cover the twelve
standard fighters: 4/10, 0/3, 2/9, 5/11, 6/7, 8/1. The ROM was the Dead Pool
palette-cycle test build (`tmp/acidcycle/rom/mk2.zip`, removed since): its only
difference from source is one extra NESS_P cycle process on stage 0, present in
both halves of every pair. The runner now starts MAME windowed under `-debug`
like the other private rigs.

| Stage | Pairings | Mode 0 starts/refresh | Mode 2 | Change | Captures identical | Trace mismatches | New late frames |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0 THE DEAD POOL | 6 | 163.04 | 98.36 | -39.7% | 162/162 | 0 | 0 |
| 4 LIVING FOREST | 6 | 245.13 | 133.13 | -45.7% | 162/162 | 0 | 0 |
| 5 THE ARMORY | 6 | 249.55 | 137.55 | -44.9% | 162/162 | 0 | 0 |
| 7 THE PORTAL | 6 | 216.85 | 104.85 | -51.6% | 162/162 | 0 | 0 |
| 8 KAHN'S ARENA | 6 | 259.66 | 147.66 | -43.1% | 162/162 | 0 | 0 |
| 9 GORO'S LAIR | 6 | 252.26 | 140.26 | -44.4% | 162/162 | 0 | 0 |
| 0Ah PIT BOTTOM | 6 | 217.22 | 105.22 | -51.6% | 162/162 | 0 | 0 |
| 16h OUTER HAVEN | 6 | 224.89 | 112.89 | -49.8% | 162/162 | 0 | 0 |
| 17h FLAPJACK | 6 | 197.80 | 85.80 | -56.6% | 162/162 | 0 | 0 |
| 18h YOTEIGAI TOR | 6 | 200.60 | 88.60 | -55.8% | 162/162 | 0 | 0 |
| 6 THE BRIDGE | 1 | 69.12 | 69.12 | 0 | 27/27 | 0 | 0 |

The second batch (stages 9, 0Ah, 16h, 17h, 18h) was measured on the first
batch's rebuilt ROM (`tmp/shadow_stages/build`), which differs only in the
first five stages' default mode - the runner forces the mode either way.
Their setters are in `cave_calla`, `mk1pit_calla`, `outer_haven_calla`,
`flapjack_calla` (`fjf9`) and `peak_calla` (`pkr9`). YOTEIGAI TOR's
stage-fatality fall (`dlists_peak_fall`) also draws shadows and was not
exercised. **All ten stages: 1,620/1,620 identical captures.**

Mode 2's riskiest path - a raw (uncompressed) piece after a fast one, where
the DMA scale and height must be restored before the row loop - was
exercised: the traces count raw fighter pieces per frame, and 352 of every
stage's 4,686 measured frames per mode (7.5%) carried one, on every stage.

Per-trial hashes and numbers: [stage_shadow_sweep_results.json](stage_shadow_sweep_results.json).
Starts are the whole scene's DMA starts, not shadow commands alone, and they
measure submission, not completion time.

## Bosses

**Shao Kahn passes.** Kitana (4) against a select-forced Kahn (13) on KAHN'S
ARENA, same paired method on the second rebuilt ROM: 27/27 identical
captures, 0 trace mismatches, 0 new late frames, 165.16 -> 134.73 DMA starts
per refresh (-18.4%, well below the standard pairings; not investigated -
the scripted inputs do not drive a boss the way they drive a second human).

**Kintaro is not measured.** Forcing `ft_goro` (12) at select never reaches
a fight in this rig ("never reached fight" after 6,000 frames, like the
secret fighters), so GORO'S LAIR has only the twelve standard fighters. That
is a harness limit, not a shadow result.

## Finishers, bosses and round ends (15 September 2026)

`tools/run_fatality_shadow_ab.py` reuses the finisher rigs from
`tools/run_fatality_budget.py`. Each rig runs twice on one frozen ROM (the
reflection build, `tmp/reflect_fx/build`):

- **fast:** the stage's own `@shad_fast`. The wrapper logs what the stage
  asked for, and every scenario's stage asked for 2.
- **legacy:** `@shad_fast` forced to 0 every frame, the stock row loop.

Every snapshot the rig takes is then compared pixel for pixel. Each rig runs
through its round end.

| Finisher | Stage (mode) | Snapshots identical | Rig verdict, both boots |
|---|---|---:|---|
| Scorpion toasty | THE ARMORY (2) | **6 / 6** | PASS |
| Kung Lao split, on Kitana | THE DEAD POOL (2) | **8 / 8** | PASS |
| Kahn's fatality on P1 | KAHN'S ARENA (2) | **101 / 101** | probe mode, no verdict line; the round ended normally |
| Shang soul escape + Kintaro's drop | KAHN'S ARENA (2) | **104 / 104** | PASS |
| Raiden lift (body explosion) | THE ARMORY (2) | **92 / 93** | PASS |

**The one differing Raiden capture is timing, not shadows.** It reproduces
exactly on reruns: capture 2, frame 1488, the lift's first frame. In that
capture only the floor band differs (rows 192-253). The mask follows the
floor's tile pattern, while the fighters' legs and the shadows around them
are identical.

A per-frame trace of both boots (`FB_TRACE` in
`tools/fatality_budget_wrap.lua`, `tmp/fatality_shadow_ab/trace_diff.py`)
narrows it down:

- **Not the camera or the DMA queue.** Every camera, floor-skew and scroll
  word is identical on all 41 frames from 1470 to 1510. So are
  `peak_overload` and the late-frame count. Nothing was abandoned there.
- **The processes a fatality starts run one pass apart.** At frame 1489 they
  resume at different addresses: `skydown` / `fadeout` (the background
  darkening), `make_db_tone` (the death-blow sting), `flash_pmsg2`, and
  Raiden's `lightning`, which is live in one boot a pass before the other.
  The stock loop keeps the DMA interrupt busy about 2 ms longer, and that
  moves where a newly created process first runs relative to the display.
- **So the darkening fade is one step apart on that frame.** A fade changes
  particular colour indices, and the floor's tile lines use them.

The other 92 captures are identical, and both boots finish the lift in the
same 172 frames with the same verdict. This is the same class as rig boots
drifting under load: any change to the interrupt's duration can move a new
process by a pass. It is not a difference in what the shadow path draws.

**Finishers: 311 of 312 captures identical across five finishers, two
bosses' arenas and five round ends. The one exception is explained, and no
shadow pixel differs anywhere.**

## Not covered

Hidden fighters, Kintaro as a fighter (his drop in the soul escape is
covered above), the Dead Pool stage fatality, FBNeo/netplay and physical
hardware. Noob remains deferred.

## Reproduce

```powershell
python tmp/shadow_stages/sweep.py --stages 0,4,5,7,8 --p1 4 --p2 10
python tools/run_wasteland_shadow.py --rom-dir <rebuilt rom dir> --map <its map> --stage 0 --native --expected-native-mode 2
```
