# Future Character Effect Notes

This note is for adding Raiden-style companion effects to other fighters without
touching Raiden's actual lightning art, animation tables, or runtime routine.

## Core Rule

Use Raiden's lightning code as a lifecycle model only:

- Spawn a small companion process when the fighter is initialized.
- Let the process watch round state and fighter state.
- Create a temporary effect object only when the fighter is in an allowed pose.
- Align that effect object to the fighter with `match_ani_points`.
- Apply local frame offsets to the effect object.
- Insert and update the effect object while the fighter remains in an allowed
  pose, then delete it when the pose/round state no longer qualifies.
- On process exit, always clean up `p_slave`.

Do not wire another character directly into `lightning`, `a_victory_bolts`, or
Raiden's `rd_anitab` slots. Raiden should stay Raiden.

## Three Layers

### Art/Table Layer

Use character-specific or generic effect art.

For Scorpion fire, the intended direction is `FIREHAND.IMG` with palette
`HNDFIRE_P`, not Raiden bolt art and not stage-local art such as `CASTLE.IMG`.
Stage art can create level-loading and palette coupling problems when reused as
a fighter effect.

If new art is added, make sure the `.IMG` records are packed through the correct
LOD wrapper and that the source `src/*.TBL` file used by the program has the
same frame headers and SAGs as the generated LOAD2 output.

### Animation Layer

Define a small effect animation table or frame table that points only to the
effect frames.

The fighter stance frames are a condition source, not part of the effect object.
For example, Scorpion's stance frame can decide which hand-fire frame to show,
but the process should only create/draw the fire object.

If each effect frame needs a different local offset, keep an explicit table:

```asm
	.long	HANDFLAME1
	.word	15,-16
	.long	HANDFLAME2
	.word	15,-21
```

Those offsets are local effect offsets after `match_ani_points`; they are not a
replacement for the fighter's own animation points.

### Runtime Layer

Add a dedicated process for the character effect, for example
`pid_scorpfire,scorpion_firehand`.

The process should:

- Save the owning fighter object in `p_otherguy`.
- Wait while the round is active.
- Check that the fighter is visible, alive, on the ground, and in an allowed
  stance or idle frame.
- Create an effect object from the effect frame, or reuse its current `p_slave`.
- Set z order and palette on the effect object only.
- Align to the fighter with `match_ani_points`.
- Apply frame-local offsets with `multi_adjust_xy`.
- Insert/update the effect object, sleep for the frame, and delete it when the
  fighter leaves the allowed pose.
- Call `delete_slave` before `sucide`.

This mirrors the safe parts of Raiden's ambient lightning process without
sharing Raiden's art or altering his behavior.

## Things To Avoid

- Do not alter Raiden's `lightning` routine to support another fighter.
- Do not export `a_victory_bolts` just so another file can use Raiden art.
- Do not pass single-image headers such as `HANDFLAME1` directly to `mframew`.
  `mframew` calls `ani2`, which expects multipart wrapper labels, not raw image
  headers. Use `gso_dmawnz` plus `ani` for single-object effect frames.
- Do not apply `swpal` or palette changes to the fighter object when only the
  effect should change.
- Do not use background/stage art for fighter effects unless that stage art is
  intentionally promoted into a generic always-available art package.
- Do not rely on `tmp/load2/*.TBL` alone. Patch the linked `src/*.TBL` and rebuild.
- Do not leave `p_slave` pointing at a deleted object.

The previous broken Scorpion fire attempt made HUD/lifebar rendering disappear
because the effect path was too invasive and fragile. Future character effects
should be temporary companion objects with tight ownership and cleanup.

## Scorpion Fire Target

Current intended Scorpion fire assets:

- Art: `FIREHAND.IMG`
- Palette: `HNDFIRE_P`
- Frames: `HANDFLAME1`, `HANDFLAME2`, `HANDFLAME3`, `HANDFLAME5`,
  `HANDFLAME6`, `HANDFLAME7`, `HANDFLAME9`

Current implementation gates the effect behind the start+coin Scorpion owner bit
(`m_repalt5_pal` / `b_repalt5_pal`). If the design changes to "all Scorpion
skins," remove that gate deliberately rather than by accident.

Suggested frame offsets from IMGTOOL:

```asm
	.long	HANDFLAME1
	.word	15,-16
	.long	HANDFLAME2
	.word	15,-21
	.long	HANDFLAME3
	.word	18,-24
	.long	HANDFLAME5
	.word	14,-29
	.long	HANDFLAME6
	.word	12,-26
	.long	HANDFLAME7
	.word	14,-23
	.long	HANDFLAME9
	.word	12,-14
	.long	0
```

These values may need tuning in IMGTOOL because the fighter stance can be split
into subframes. If the hand does not track correctly in-game, update this doc
with the corrected offsets before wiring other characters.

Current visual note: the runtime test proves the `HNDFIRE_P` object is alive and
uses palette slot 13, but the screenshot reads more like a tiny pink hand glow
than the orange/yellow IMGTOOL preview. If the art should be hotter/brighter,
compare IMGTOOL's `HNDFIRE_P` export against `src/IMGPAL4.ASM::HNDFIRE_P`.

## Build/Test Checklist

- Confirm the effect palette is defined in the right `IMGPAL*.ASM` file and has
  a local `.globl` in that file if the linker needs it.
- Confirm all effect frame labels are exported where the calling source expects
  them.
- Run the current wrapper after LOD, table, palette, program, or video changes:
  `python build_all.py --retail-only --no-install --skip-verify`.
- Test on at least two stages, including one with busy background animation.
- Test jumping, blocking, getting hit, round-over, fatality pause, and character
  select/rematch transitions.
- Verify HUD/lifebars remain visible while the effect is active.
