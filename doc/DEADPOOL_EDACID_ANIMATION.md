# Dead Pool EDACID Animation Reference

This documents the current EDACID bubble test wiring so the final chain/body
sequence can be hooked up later without rediscovering the frame timing.

## Source of Truth

- Authored export: `data/EDACID.ASM`
- Chain test export: `data/EDCHAIN.ASM`
- Runtime hook: `src/MKHANG.ASM`
- Current runtime includes `data/EDACID.ASM` and `data/EDCHAIN.ASM` directly
  from `MKHANG.ASM`.
- The long IMGTOOL `*_local_anipts` labels were shortened to `edac_s*_pts`
  because GSPA truncates long symbols. The frame rows and offset rows were not
  changed.
- `EDCHAIN.ASM` was generated from the Ed/chain paste with the duplicate
  acid/bubble slot removed. Its labels use `edch_s*`.

## Timing

`ed_fx_frame_ticks` in `src/MKHANG.ASM` is the base EDACID tick.

Current value:

```asm
ed_fx_frame_ticks .equ 5
```

At 54.7068 Hz, that makes one EDACID/IMGTOOL row last 5 game frames, or 10.94 fps.
The repeated `.long` rows in `EDACID.ASM` encode the holds. Do not set this to
`1` for this export unless you intentionally want 60 fps playback.

## EDACID Slot Map

| Slot | Label | Point table | Purpose |
| --- | --- | --- | --- |
| 1 | `a_imgtool_slot1_mkskull` | `edac_s1_pts` | Bubble lane: `BUBL1-4`, then `greendrip1-8` tail |
| 2 | `a_imgtool_slot2_acidhang` | `edac_s2_pts` | Hidden `DEDHANG1` timing lane |
| 3 | `a_imgtool_slot3_mkhang` | `edac_s3_pts` | `EDHANG1` body timing lane |
| 4 | `a_imgtool_slot4_mkskull` | `edac_s4_pts` | Drip/ripple lane: `greendrip0`, `aciddrip1-3`, `aciddrip`, `pooldrip1` |
| 5 | `a_imgtool_slot5_mkhang` | `edac_s5_pts` | `TINCHAIN4` helper lane |
| 6 | `a_imgtool_slot6_mkskull` | `edac_s6_pts` | Bubble lane: `BUBL1-4`, then `greendrip1-8` tail |
| 7 | `a_imgtool_slot7_mkskull` | `edac_s7_pts` | Bubble lane: `BUBL1-4`, then `greendrip1-8` tail |
| 8 | `a_imgtool_slot8_mkskull` | `edac_s8_pts` | Bubble lane: `BUBL1-4`, then `greendrip1-8` tail |
| 9 | `a_imgtool_slot9_mkhang` | `edac_s9_pts` | `TINCHAIN4` helper lane |
| 10 | `a_imgtool_slot10_mkskull` | `edac_s10_pts` | Drip/ripple lane: `greendrip0`, `aciddrip1-3`, `aciddrip`, `pooldrip1` |

## Current Side-by-Side Test

With `acid_bubble_preview_only .equ 1`, `create_hangers` starts a whole-round
A/B acid test, plus the Ed chain preview, and skips the stock hanger actors.

Left cluster:

- `acid_bubble_only_x`
- BUBL-only lanes from the shortened local copies:
  `ed_bubl1_proc`, `ed_bubl2_proc`, `ed_bubl3_proc`, `ed_bubl4_proc`
- Intended to compare the simpler "going into acid" surface boil.

Right cluster:

- `acid_bubble_drip_x`
- Full EDACID lanes:
  `ed_fx1_proc`, `ed_fx5_proc`, `ed_fx2_proc`, `ed_fx3_proc`,
  `ed_fx4_proc`, `ed_fx6_proc`
- Includes the `greendrip0/aciddrip/pooldrip1` ripple lanes.
- Intended to compare the "coming out of acid" surface boil.

Ed/chain layer:

- The active visual test now spawns Boon's real `hanger_proc` with hanger index
  0, so the stock body/chain/hook setup drives the drop into the pool.
- The side-by-side EDACID lanes still run for the whole round.
- `ed_chain_preview_proc` / `ed_chain_motion_proc` remain in source as EDCHAIN
  reference wiring, but the preview branch does not spawn that overlay while
  the real `hanger_proc` is active.
- `ed_chain_motion_proc` can play `EDCHAIN.ASM` slot 5 when re-enabled.
- Slot 5 has 560 timed point rows plus a final stop marker; the runtime counts
  560 ticks so hidden `.long 0` rows hide the connector instead of ending the
  test early.
- Placement uses the pasted local point convention:
  `screenX = ed_chain_anchor_x + dAX`,
  `screenY = ed_chain_anchor_y - dAY`.
- The Boon drop uses `ed_boon_drop_wait`, `ed_boon_drop_step`, and
  `ed_boon_drop_end_y` in `src/MKHANG.ASM`; it does not change the EDACID
  bubble/drip playback speed.

## Runtime Process Map

| Process | Runtime frame table | Runtime points | Notes |
| --- | --- | --- | --- |
| `ed_fx1_proc` | `a_imgtool_slot1_mkskull` | `edac_s1_pts` | Full EDACID bubble lane |
| `ed_fx5_proc` | `a_imgtool_slot4_mkskull` | `edac_s4_pts` | Full EDACID drip/ripple lane |
| `ed_fx2_proc` | `a_imgtool_slot6_mkskull` | `edac_s6_pts` | Full EDACID bubble lane |
| `ed_fx3_proc` | `a_imgtool_slot7_mkskull` | `edac_s7_pts` | Full EDACID bubble lane |
| `ed_fx4_proc` | `a_imgtool_slot8_mkskull` | `edac_s8_pts` | Full EDACID bubble lane |
| `ed_fx6_proc` | `a_imgtool_slot10_mkskull` | `edac_s10_pts` | Full EDACID drip/ripple lane |
| `hanger_proc` | `a_edhang1_full` | `hanger_initab[0]` | Active Boon body/chain drop path |
| `ed_chain_preview_proc` | `edch_s2/s3/s4` points | `edch_s2_pts` etc. | Reference EDCHAIN body/connector/hook overlay, currently not spawned |
| `ed_chain_motion_proc` | `edch_s5` | `edch_s5_pts` | Moving/hidden TINCHAIN4 chain test |

All of these feed `ed_fx_keyed_loop`, which applies the matching local anipoint
row each EDACID tick. The process stores its base X in `p_store3` so the left
and right test clusters can sit next to one another.

## Future Character/Subframe Wiring

When this is moved from test mode into the final per-character fatality:

- Keep `EDACID.ASM` as the shared acid surface animation for every character.
- Break each character's body art into the equivalent subframes and wire those
  per character.
- Replace Boon's current `a_edhang1_full` body wrapper with each character's
  final subframe/multipart body once those exports are ready.
- Use the EDCHAIN slot-5 runner as the reference for chain hide/show timing.
- Keep the MKSKULL FX lanes separate from the body/chain lanes so the surface
  can keep bubbling while the body/chain state changes.
- Preserve the 12 fps EDACID tick cadence unless the IMGTOOL export changes.

## Test Notes

For visual checks, run MAME throttled at normal speed. Do not use `-NoThrottle`
when judging the feel of the acid animation.

The current test package is built with:

```powershell
python makerom.py
python mamerom.py --no-install
```

Then run from `rom\test\mk2.zip`.
