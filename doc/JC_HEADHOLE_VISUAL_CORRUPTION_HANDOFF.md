# Johnny Cage Head-Rip Visual Corruption Handoff

> **Superseded timing note (2026-07-13):** The historical capture discussion
> below used a 35-row preview-derived attacker timeline. The active authority
> is one native `CAGE10.IMG` `DBLO2` pass: 12 steps, 44 direct ticks, zero
> per-entry dX/dY, and normal stock lineup/facing. Read
> [JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md](JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md)
> before acting on any timing or placement suggestion in this handoff.

## Scope

This handoff covers the remaining visual defects in Johnny Cage's restored
head-rip fatality, most visibly with Kung Lao as the victim. The fatality
finishes without a process crash and reaches Cage's victory animation, but the
latest frame capture proves that the visual result is not correct.

Do not treat the automated lifecycle `PASS` as a visual pass. The test only
proves that the expected processes and terminal objects survive long enough;
it does not validate sprite pixels, placement, or timing.

## Current Reproduction

The ROM was rebuilt through the complete pipeline before this capture:

```powershell
$env:ALLOW_STOCK_BG_DRIFT='1'
python build.py
python makerom.py
python makevrom.py
python mamerom.py --no-install
```

Run the Kung Lao frame readout from the repository root:

```powershell
$env:JC_HEADHOLE_VICTIM='0'
$rels = @(0..50 | ForEach-Object { $_ * 5 })
.\tools\run_jc_headhole_anim_readout.ps1 `
  -Stage 1 `
  -Step 5 `
  -SnapshotRels ($rels -join ',') `
  -TargetedSnapshotsOnly `
  -TimeoutSeconds 120
```

Latest evidence:

- Screenshots: `tools/screens/jc_headhole_anim_readout/run_20260711_223156/mk2/`
- CSV: `tools/screens/jc_headhole_anim_readout/run_20260711_223156/jc_headhole_anim_readout.csv`
- Text readout: `tools/screens/jc_headhole_anim_readout/run_20260711_223156/jc_headhole_anim_readout.txt`
- MAME log: `tools/jc_headhole_anim_readout_logs/jc_headhole_anim_readout.log`

The latest normal-speed test is also available:

- Screenshots: `tools/screens/jc_headhole_fatality/run_20260711_222639/`
- Log: `tools/jc_headhole_fatality_test_logs/jc_headhole_fatality.log`
- Command:

```powershell
.\tools\run_jc_headhole_fatality_test.ps1 `
  -Stage 1 `
  -ScriptName jc_headhole_kung_lao_test.lua `
  -TimeoutSeconds 50 `
  -Sound
```

That run reports `deathblo_then_jc_victory_no_crash`, with the fatality at
frame 1543 and live terminal objects `SPILL13`, `TMDEADHEAD7`, and
`KHEART6D`. Again, this is only a lifecycle pass.

## Confirmed Visual Failures

### 1. Kung Lao SMGUSH art is corrupted

Two large yellow/orange pixel clouds are reproducible and identify as Kung
Lao's `SMGUSH` sidecar blood lane:

| Capture | Relative tick | Runtime object | Runtime SAG | Source SAG | Size |
|---|---:|---|---:|---:|---:|
| `0006.png` | 30 | `SMGUSH4` | `0x00beffc6` | `0x03beffc6` | 49x34 |
| `0012.png` | 60 | `SMGUSH10` | `0x00bf991e` | `0x03bf991e` | 75x66 |

This ties the obvious corruption to `src/KGBLOOD.TBL`, not to the generic
`JCSPLAT` or `JCSTAB` lanes. Temporarily disabling only
`jc_headhole_hat_gush_proc` should make a useful confirmation test.

### 2. The head overlay starts one authored scene row late

Observed transitions from the readout:

| Relative tick | Cage frame | Head frame |
|---:|---|---|
| 15 | `JCHIPUNCH3` | none |
| 20-80 | continuing fatality | `TMDEADHEAD1` |
| 85 | continuing fatality | `TMDEADHEAD2` |
| 90 | continuing fatality | `TMDEADHEAD3` |
| 95 | continuing fatality | `TMDEADHEAD4` |
| 100 | continuing fatality | `TMDEADHEAD5` |
| 105 | continuing fatality | `TMDEADHEAD6` |
| 110 onward | continuing/terminal | `TMDEADHEAD7` |

The code comments and intended sequence put the first head frame at
`JCHIPUNCH3`/relative tick 15. `jc_headhole_head_proc` currently begins with
`sleep 012h`, and the capture shows the first overlay only at relative tick
20. This likely explains at least the initial apparent flicker.

### 3. SPILL is alive but timed and positioned incorrectly

The runtime evidence shows:

- `SPILL1` is already live from relative tick 20 through 105.
- The lane advances to `SPILL2` at relative tick 110, alongside
  `TMDEADHEAD7`.
- `SPILL13` appears by relative tick 165 and remains live through victory.
- Victim X is approximately 1030 while `SPILL1` is around X=894, Y=213.
- Terminal `SPILL13` is around X=868, Y=213 after the body nudge.

The initial spill is only 12x6 and is roughly 136-155 world pixels left of the
body, so it appears absent even though the object exists. The Kung Lao spill
table currently uses `(-126,-138)` in `src/MKDEATH.ASM`.

The intended timing is for the spill to begin when the last headhole frame
hits. The implementation currently spawns and displays `SPILL1` much earlier,
then starts advancing it at `TMDEADHEAD7`. Consider spawning the spill object
at `TMDEADHEAD7` and anchoring it from the victim's final body/head position.

### 4. Terminal persistence works

Later captures show `TMDEADHEAD7` and `SPILL13` still live while Cage enters
the victory pose. The remaining problem is therefore visual placement/art and
phase timing, not simply early process destruction.

## Table and Build Audit Already Completed

The obvious stale-table explanation has been checked:

- `src/KGBLOOD.TBL` matches `tmp/load2/KGBLOOD.TBL` for the generated headers.
- `src/HHHEADHO.TBL` SAGs/anipoints match `tmp/load2/HHHEADHO.TBL`.
- `src/MKHH.TBL` `TMDEADLEG`/`TMDEADTORSO` data matches generated output.
- `src/JCBLOOD.TBL` STAB/SPLAT SAGs match the current generated blood table.
- `src/JCSPILL.TBL` SAGs match `tmp/load2/JCSPILL.TBL`.
- The full video-ROM build and package were run before the failing capture.

Relevant generated `SMGUSH` addresses include:

```text
SMGUSH1   03bed9a6
SMGUSH2   03bee8be
SMGUSH3   03bef328
SMGUSH4   03beffc6
SMGUSH10  03bf991e
SMGUSH14  03c01c18
```

`data/MOVEART1.LOD` starts at `***> 5B40000` and appends `KGBLOOD.TBL` from
`BLOOD.IMG` under `PON>`. Its current payload occupies flat offsets roughly
`0x768000..0x780636`, within the fixed slot. Matching source/generated tables
does not prove that these bytes were mapped correctly into the final video
chips.

`src/HHHEADHO.TBL` and `src/JCSPILL.TBL` contain source-only palette fields
that LOAD2's generated versions do not emit. Those differences deserve review,
but they are not yet proven to cause the `SMGUSH` corruption.

## Recommended Investigation Order

1. Verify the `MOVEART1.IRW` bytes at the `SMGUSH4` and `SMGUSH10` offsets
   against the final assembled graphics buffer and output video chips. Check
   whether `0x03BE...` through `0x03C0...` crosses a bank/chip boundary or is
   overwritten by another IRW payload.
2. Build a minimal test that displays one `SMGUSH` frame at a time without the
   fatality. This separates art packing/SAG corruption from runtime lineup and
   object flags.
3. Disable only `jc_headhole_hat_gush_proc` and rerun. The yellow clouds should
   disappear while STAB/SPLAT remain if the identification above is correct.
4. Correct the head process phase so `TMDEADHEAD1` appears on the
   `JCHIPUNCH3` scene row, then recapture all transitions.
5. Spawn SPILL when `TMDEADHEAD7` begins and derive its position from the
   victim's terminal anchor. Recheck both the first and terminal spill frames.
6. Add `SMGUSH1..14` SAG labels to the Lua readout map. The current overlay
   labels these objects as unknown, which makes visual debugging harder than
   necessary.
7. Only after the isolated art test, evaluate whether the source-only palette
   fields in `HHHEADHO.TBL` or `JCSPILL.TBL` should be removed or represented
   differently.

## Relevant Code

- `src/MKDEATH.ASM`
  - `jc_headhole_body_fall` near line 1945
  - Kung blood process spawns near lines 1959-1967
  - blood tables/processes near lines 2074-2310
  - `jch_hat_spill_pts` near line 2310
  - `jchprop_lineup_victim_flip` near line 2460
  - `jc_headhole_head_proc` near line 2572
  - initial `sleep 012h` near line 2573
  - head progression near lines 2593-2620
  - terminal head lineup near lines 2633-2668
- `src/KGBLOOD.TBL`
- `src/HHHEADHO.TBL`
- `src/MKHH.TBL`
- `src/JCBLOOD.TBL`
- `src/JCSPILL.TBL`
- `data/MOVEART1.LOD`
- `tools/jc_headhole_fatality_test.lua`
- `tools/jc_headhole_kung_lao_test.lua`
- `tools/run_jc_headhole_anim_readout.ps1`

## Current Architecture and Intent

- Cage owns the attacker animation lane and KHEART sequence.
- The victim owns the body/head reaction plus STAB, SPLAT, and SPILL.
- Kung Lao has an additional `SMGUSH` sidecar lane.
- Cage's attacker animation uses one native 12-step `DBLO2` pass with direct
  source ticks; repeated preview rows are not runtime frames.
- Current audio cues include BWHOOSH3, BIGHIT3, VPDEATH, and MUNCH.
- Mileena's ball roll uses MILEBALL.
- Liu Kang is intended as the base reaction model for other opponents, with
  character-specific body/head art substituted by victim.

## Worktree Caution

The worktree contains user-authored and generated asset changes. Do not revert
or replace them while investigating. In particular, preserve current edits to
`data/BLOOD.IMG`, `data/HATHED11.IMG`, `data/KANG10.IMG`, `data/TOWER2.BDB`,
`data/imgui.ini`, and the untracked Kung/Liu World View and ASM exports.

The existing `doc/JC_HEADHOLE_FATALITY_TEST.md` currently overstates the
visual result by attributing prior yellow corruption to a stale package. The
fresh full-build capture above disproves that conclusion for the current Kung
Lao `SMGUSH` failure.
