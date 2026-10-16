# Kombat Tomb fast-shadow prototype

Continuation of [Wasteland fast shadows](WASTELAND_SHADOW_PROTOTYPE.md),
12 September 2026. **Enabled in source; final Tomb build passed in MAME.**
The frozen build predates the subsequent hitlight, palette-map and strip
commits; its results are not a claim of testing every later renderer change.

## Implementation

`calla_tomb` selects `shad_fast=2` after setting up its floor. This uses the
existing two-blit path for compressed pieces and retains the original row
loop for raw pieces. The renderer itself gains no new branch or allocation:
only the stage's mode selection changes. The compatibility mode's scale and
height restoration remains shared with Wasteland.

The normal Tomb display list places shadows after the wall and fence and
before fighters. Its floor has 59 rows beginning at screen y=203 in the
resting-camera case. Unlike Tower it has no reflection pass or special
shadow clipping window. The ceiling-fatality display list also has a shadow
marker, but that fatality is outside this prototype's runtime coverage.

## Validation contract

Six pairings cover the twelve standard fighters: 0/3, 2/9, 4/10, 5/11, 6/7
and 8/1. Each comparison runs the same private ROM twice, selecting legacy
mode 0 and compatibility mode 2 with identical scripted inputs. Measured
refreshes 120–900 give 781 trace rows and 27 full-screen captures per mode.
The script exercises idle, walking both ways, jumping, crouching and basic
attacks. It replenishes health and keeps both players under human input.

Acceptance requires exact RGB equality at every paired capture, matching
fighter position/frame/flag and camera traces, and no increase in the late
counter. DMA starts include the whole scene. Last-start timing measures
submission progress, not completion time, display frame rate or board speed.

The [final receipt](tomb_shadow_results.json) records the tested ROM and map
hashes. Early feasibility runs used the prior Wasteland build; final
acceptance uses the rebuilt ROM with the Tomb stage setting present.

All six pairings pass: **162 identical paired captures**, **4,686 matching
fighter/camera trace rows per mode**, and no increase in the late counter.
Total DMA starts average **256.80 → 144.80 per refresh**, a **43.6% reduction**.
Mean last-start position moves from approximately 58–59% of the refresh to
47–48%. The boot-inclusive `lost_max=143` is not a count of losses during
these measured fights.

Native-mode checks do not write `shad_fast`: the runner now requires an
explicit `--expected-native-mode` and logs actual versus expected. The checks
cover Tomb=2, Wasteland=2, Tower=1 and Living Forest=0. These are separate
boots, not a stage-transition test. All four passed without new late frames.

## Reproduce

```powershell
python build.py --asm-only
python makerom.py
python makevrom.py
python mamerom.py --no-install --output tmp/tomb_build/rom/mk2.zip
Copy-Item src/mk2.map tmp/tomb_build/mk2.map
python tools/run_wasteland_shadow.py --rom-dir tmp/tomb_build/rom --map tmp/tomb_build/mk2.map --stage 1 --p1 4 --p2 10
python tools/run_wasteland_shadow.py --rom-dir tmp/tomb_build/rom --map tmp/tomb_build/mk2.map --stage 1 --native --expected-native-mode 2
```

Repeat the paired command for each numeric pairing above. Each invocation
freezes both inputs and uses private emulator state and screenshot folders.
Use the explicit copied map if another session is rebuilding the checkout.

Assembly, project guards, program/video generation and private packaging
passed. The build retained the existing Boxlab export-freshness warning.
No ROM was installed into the shared MAME directory.

Hidden fighters, bosses, all move variants, fatalities, round transitions,
FBNeo/netplay and physical hardware remain untested. Noob remains deferred.
This change saves drawing work; it does not reclaim video-ROM storage.
