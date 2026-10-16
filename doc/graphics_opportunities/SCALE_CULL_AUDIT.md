# Scale-aware culling audit (opportunity 08)

14 September 2026. **Source audit; no runtime measurement yet, nothing changed.**

## The two on-screen tests

**The draw loop's reject** - `no_multi`, [MKDISP.ASM](../../src/MKDISP.ASM)
lines 578-590, run for every object and every multipart piece on every list:

```
no_multi
	move	a10,a2
	addxy	a9,a2  		; a2 = bottom right (y,x) coordinate
	subxy	a14,a2
	jrylt	boxc3		; off the top / left
	jrxlt	boxc3
	move	a10,a2		; a2 = top left (y,x) coordinate
	subxy	a13,a2
	jrygt	boxc3		; off the bottom / right
	jrxgt	boxc3
```

`a10` is the unscaled top-left (object position, minus the piece's anipoint
for multipart), `a9` the **unscaled** `vsize:hsize` (`osize`, or the piece's
own size from its multipart RAM), `a14`/`a13` the screen corners. `a6` holds
`oscale` at this point and goes straight onto the DMA queue - the test never
looks at it.

**`scrtst`** (MKDISP.ASM ~7595), the gameplay helper, builds the lower-right
the same way from `osize`. Its only caller is MKBLOOD's blood flight, which is
never scaled.

## What scaling does to that test

On this DMA `oscale` is a divisor: drawn size = source x 0100h / step, per
axis, from the same top-left.

- **Shrunk (step > 0100h):** the drawn image is smaller than the tested box. An
  object that is actually off screen can still pass and be queued; the DMA
  clips it. Costs a queue entry and setup, never a wrong picture.
- **Enlarged (step < 0100h):** the drawn image is bigger than the tested box.
  The right/bottom half of the test compares the (unchanged) top-left, so it is
  safe; the **left/top half compares the unscaled bottom-right**, so an object
  whose unscaled box ends just off the left or top edge while its magnified
  image reaches the screen is **culled**. The error is up to
  `size x (0100h/step - 1)` pixels.

## Who scales

All 25 `oscale` writes in `src/`:

| Owner | Step | Effect on the test |
|---|---|---|
| Kahn's hammer smash (`kahn_smash_steps`, MKBOSS.ASM) | 080h on frames 5-15 | **enlarges 2x** - can be wrongly culled off the left/top edge by up to a full piece |
| Hit pop (`HP_SCALE`, MKDISP.ASM) | 0140h:00d0h | x **123%** for 2 ticks - left edge only, a few px |
| Reptile's orb squash (`orb_squash_steps`, MKZAP.ASM) | down to 00c8h on one axis | **128%** on that axis |
| `grow_msg` FIGHT / FINISH HIM (MKFX.ASM), the toasty/ fatality text grow (MKTOAST.ASM) | 0300h -> 0100h | shrink only, centred on screen |
| Combo toasts (`cot_scltab`, MKDISP.ASM) | 0100h-0140h | shrink only |
| Tower reflections (TWRBACK.ASM, BGND.ASM `TWR_PSCALE`) | ystep 0380h-0700h | shrink only |
| Pit-fall background quads (`update_a_quad`, MKFALL.ASM) | growing steps | shrink only |
| Blood fade (MKBLOOD.ASM) | `bf_den/(bf_den-1)` and up | shrink only |
| `getobj` default, copies in MKZAP/MKDISP | 0100h / copied | none |

So the **wrong-cull** case exists for three effects, all of them brief, and the
largest is Kahn at 2x near the left/top of the screen. The **wasted-queue**
case exists for the shrinking effects, which are mostly on screen by design.

## The contradiction, resolved (15 September 2026)

`cot_scltab`'s comment said "an object carrying 00cd00cd is simply not drawn"
and called a step below 0100h a hardware limit. The Kahn smash, the hit pop
and the orb squash all magnify and draw correctly.

**Magnification is not a hardware limit.** `tmp/scale_probe/letter_scale_rig.lua`
(run with `tmp/scale_probe/run.py`) tests the round-end "KITANA WINS" letters.
They are MKTEXT's 1-bpp glyph objects, drawn in constant colour (`oconst`,
flags 9008h): the same kind of object as the combo toasts. The rig forces
`oscale` on them in 14-frame windows and takes one capture per window, on the
build before the `no_multi` fix and on the one after it:

| Window | Step | Pre-fix (`tmp/budget_fix`) vs post-fix (`tmp/reflect_fx`) | What is on screen |
|---|---|---|---|
| w0, w5 | 01000100h | 0 px | the line at 1:1 |
| w1 | 00cd00cdh | 0 px | drawn, 1.25× both ways |
| w2 | 00800080h | 0 px | drawn, 2× |
| w3, w4 | 00cd0100h, 010000cdh | 0 px | drawn, one axis at 1.25× |
| w6 | P1 (6-bpp multipart) at 00cd00cdh | 0 px | drawn |
| w7 | 2×, the line moved so its unscaled box ends at screen x = -1 | **204 px** (x 0-8, rows 56-87) | the pre-fix build culls it; the fixed build draws the visible sliver of the magnified letter |
| w8 | the same position at 1:1 | 0 px | nothing, in either build |

So a step below 0100h draws on this DMA, constant-colour masks included, and
identically in both builds while the object is on screen.

What made a toast disappear was the scale-blind left/top reject in
`no_multi`. The callouts fly in from off the **left** edge (P1's start is
minus the word's width). A magnified glyph whose unscaled box was still off
that edge was rejected, even though its enlarged image reached the screen.
That is the case fixed above.

`cot_scltab`'s comment (MKDISP.ASM) is corrected in source. The table is
unchanged: the pop still runs from full size down to four fifths, as
designed, but a magnifying pop would now draw.

## Measured and fixed (14 September 2026)

**The wrong cull is real, and the fix is in `src/MKDISP.ASM` `no_multi`** (built
clean, Phase D incl. balance/hurtbox locks; private package
`tmp/cull_fix/build`, not installed).

**Geometry.** `tmp/budget_fix/smash_geom_probe.lua` rides
`tools/kahn_boss_moves_test.lua` (hammer, code 16, puppet hold, round 3) and logs
the victim's multipart pieces on every frame his `oscale` is not 1:1 - 936
frames at 0080:0080 (2x). `tmp/budget_fix/smash_geom_model.py` replays
`no_multi` on them: with the victim anchored at screen x <= 60 a whole piece is
culled on ~a quarter of the magnified frames (up to 2 at once). No flipped
pieces in this fatality, so no right-edge case here.

**A/B.** Same capture with the victim held at world x 70 (screen x ~59, the arena's
left scroll limit), on the build before the fix and the build with it
(`tmp/cull_fix/smash_cull_ab.py`): both runs take the same 338 snapshots on the
same frames and log **identical victim geometry on all 936 frames**; **145
snapshot pairs differ, every one by exactly 832 px inside x 0-42, y 42-93**, and
nothing differs in the right half. That box is the model's culled piece
exactly - a 31x45 piece whose corner is x -47, drawn 90 wide at 2x - so the old
test dropped a body piece the DMA would have drawn 43 px onto the screen, and
the fix draws it.

**The fix.** 1:1 objects (`oscale` = 01000100h) and shrink-only objects take the
original test untouched - one compare on the common path. When any axis step
is below 0100h the box grows by one extra `vsize:hsize` (k <= 2), or three if a
step is below 080h (k <= 4), on both sides: the left/top test uses corner +
size + growth, the right/bottom test corner - growth, so a flipped axis drawing
back from corner+size is covered too. It never wrongly culls; at worst a few
extra queue entries the DMA clips. Every A register is live in the walker, so
`a11` (the sag) is parked in `b2` while it holds the growth - GSPA rejects
`addxy`/`subxy` across the A and B files ("REGISTERS IN OPPOSITE FILES").

Not covered: the hit pop and orb squash were not captured (both magnify one
axis, under 2x, and take the same path); `scrtst` is unchanged (its only caller,
blood flight, never scales). `cot_scltab`'s "step < 0100h is not drawn"
comment is explained below: it was this cull, not the DMA.

## Candidate fix (as first proposed)

In `no_multi`, before the left/top test, branch only when `a6 != 001000100h`
and widen `a9` to the drawn size (`a9 * 0100h / step`, per axis) - one compare
on the common path, a divide on the rare one. It runs in the display
interrupt with interrupts off for every piece, so it must be measured on a
Kahn fight first: DMA starts, `dmaq_late`, and a capture of Kahn's smash with
him at the left edge showing the pieces the current test drops.

Nothing in the ownership half of 08 is new: `delete_offscreen` (MKDIE) still
culls untagged `objlst` objects by their unscaled top-left and relies on oid
tags to spare live effects - see its memory/receipt.
