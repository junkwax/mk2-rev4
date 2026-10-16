# Jade boomerang port — investigation findings (2026-07-20)

Porting Jade's 4-variant boomerang (hi/med/lo/ret) and projectile-protection
"flash counter" from the MK Trilogy N64 source into mk2-main's TMS34010
assembly. Currently wired through Kitana (`ft_fn1`, internal character ID 4)
for testing; destined for Jade (`ft_jade`, ID 16) once verified. All new logic
lives in `src/MKZAP.ASM` (`jade_zap3`, `do_jade_boom_hi/med/lo/ret`,
`get_jade_boom_obj`, `jade_boomerang_proc`); asset data lives in
`src/JADERANG.TBL` / `data/JADERANG.IMG`.

This document covers four bugs found and fixed during bring-up, in the order
they were discovered, plus the test harness built to verify them.

## 1. Missing anipt authoring (JADERANG.TBL / JADERANG.IMG)

`BRANG3`–`BRANG9` and `BRTRAIL1`–`BRTRAIL6` were art-authoring gaps: their
`anix`/`aniy` fields were `0,0` (uninitialized), while `BRANG1`/`BRANG2` had
real authored values. Derived real values by visual bend-point/bbox-center
inspection against the `BRANG1`/`BRANG2` calibration, then patched both the
`.TBL` records and the underlying 50-byte `IMAGE_disk` records in
`JADERANG.IMG` directly (binary patch at the `anix`/`aniy` offsets, +18/+20
within each record). Verified with
`imgtool-cli.exe --verify-load2` (the codex-build variant) after each patch.

`JDTHROWBLADE2`/`3`/`4` (Kitana's throw-pose frames) were re-authored by the
user directly in `JADERANG.IMG` via the imgtool GUI, sourced from the actual
frames the sprites came from; their final values were synced into
`JADERANG.TBL` without altering the user's IMG edits.

## 2. TABLE1 vs TABLE2 mismatch hid the throw animation

**Symptom**: "im not seeing kitana do that animation when trying to throw the
boomerang."

**Root cause**: `do_first_a9_frame` resolves animation via `get_char_ani`
(TABLE1 / `fn1_anitab1`), but `a_fn1_boom_throw` was added to `fn1_anitab2`
(TABLE2). `jade_zap3` was calling the TABLE1 path, so it silently fetched
whatever Kitana's own real slot 6 already resolved to in TABLE1, instead of
the new throw frames.

**Fix**: replaced the TABLE1 call with `calla get_char_ani2` +
`calla do_next_a9_frame` — the same two calls `do_first_a9_frame` makes
internally, just through the TABLE2 resolver. See `src/MKZAP.ASM:3323`
(`jade_zap3`).

## 3. Palette-underflow crash on the second throw

**Symptom**: an illegal-opcode CPU lockup a few seconds into back-to-back
throws, landing in `system_lockup` (a shared subroutine, confirmed via
`MK2.MAP` nearest-symbol lookups — this is what all the "illegal opcode"
crash PCs actually resolved to).

**Root cause chain**:
- `get_jade_boom_obj` originally called `swpal` to assign the boomerang's
  custom palette (`jade_boom_p`). `swpal` (`src/PALL.ASM`) starts with an
  **unconditional `delpal`** on the object's *current* `opal` field.
- The projectile object is drawn from a recycled pool. A freshly-recycled
  object's `opal` field still holds whatever palette index the *previous*
  occupant had — which was already correctly freed when that previous
  object died.
- Freeing it a second time underflows `freepal`'s `palcnt` (per-slot
  reference count), and `freepal` calls `lockup` ("negative palette count,
  oh shit!!") when the count goes negative.
- A detour: after reading Mileena's real `sai_proc` (`mk2-readonly`), which
  never calls `swpal`/`getfpal` at all, removing Jade's custom palette
  assignment entirely was tried — this reintroduced the exact same crash.
  The reason `sai_proc` doesn't need one: real MK2 image records include a
  valid `icmap` field (`src/SYSEQU.ASM`: `isize=0, ianioffx/y=0x20/0x30,
  isag=0x40, icontrol=0x60, icmap=0x70`, all bit offsets — i.e. byte offsets
  0,4,6,8,12,14) that `get_multi_obj` reads automatically to assign a
  working palette. `JADERANG.TBL`'s simplified records
  (`w,h,anix,aniy / sag / ctrl`, exactly 14 bytes) have **no `icmap`
  field** — `get_multi_obj`'s automatic `*a5(icmap)` read runs straight off
  the end of the record into the next frame's own header. This is a
  permanent, structural gap between `JADERANG.TBL` and real MK2 asset data,
  not something to paper over.

**Fix**: bypass `swpal` specifically; call `getfpal(jade_boom_p)` directly
and assign the returned index to `*a10(opal)` only on success. `getfpal`
never touches anyone else's allocation, unlike `swpal`'s internal `delpal`.
See `src/MKZAP.ASM:3410` (`get_jade_boom_obj`).

Also fixed in the same area: `jade_boomerang_proc` originally deleted its
object through the thrower's own `p_slave` field, which belongs to the
thrower setup process, not the flight process — leaking the real object and
corrupting later throws. Fixed by using the standard
`delete_proj_and_die` cleanup path (kills the gmo data process, deletes the
exact flight object; already calls `delpal` internally — do not add a second
one).

## 4. The `a14` register-clobbering arc bug

**Symptom**: "i saw it draw it just curves upward really high when it should
go straight across" — true for **every** variant (hi/med/lo/ret), not just
the ones with a large arc constant.

Two tuning attempts were tried first and both failed to change the observed
behavior, which was the tell that the real bug was elsewhere:
1. Lowered the Y-velocity clamp in `jade_boomerang_proc`'s `jbp_loop` from
   ±0x180000 (24 px/tick) to ±0x60000 (6 px/tick) — insufficient alone,
   since the accumulation *rate* was unchanged and still reached the new
   clamp within ~8 ticks.
2. Cut the raw Trilogy arc constants 8× (e.g. `-0xC000` → `-0x1800` for the
   hi variant) — rebuilt, retested, and the observed trajectory was
   **identical**, immediate -6px/tick from the first sample. Since changing
   the constant had zero effect, the constant clearly wasn't the value
   actually being read.

**Root cause**: `do_jade_boom_hi` (etc.) stashed the arc constant in `a14`
before falling into `jade_zap3` ("because it survives the calls below" — it
does not). `jade_zap3` calls `get_char_ani2` almost immediately afterward
(for the throw-animation lookup), and `get_char_ani2`
(`src/MKGUYS.ASM`) begins with `movi character_anitabs2,a14` —
unconditionally clobbering `a14`. `get_jade_boom_obj` later reads `a14`
back to stash the arc amount on the spawned flight process's `p_store8` —
but by then it no longer holds the arc constant at all; it holds
`character_anitabs2`'s own ROM address, a huge value that (read as signed
32-bit) instantly saturates whatever Y-velocity clamp is in place on the
very first tick, regardless of which variant was thrown. This is why both
tuning attempts had no visible effect — the tuned value was never actually
being transmitted.

**Fix**: stash the arc constant in the thrower's own persistent process
memory (`*a13(p_store7)`) instead of a register — immune to being clobbered
by any callee, no matter how many animation-resolving calls run in between.
`get_jade_boom_obj` reads it back from there instead of `a14`. Confirmed via
grep that `p_store7` is unused elsewhere during Jade's boomerang action
window (its other uses — sonic-clap-wave, `MOVES.ASM`'s toasty flag,
`MKGUYS.ASM`'s character-select stance tracking — don't overlap this
window).

**General lesson**: any code that stashes a value in a register "because it
survives calls" must verify none of those calls include `get_char_ani` /
`get_char_ani2` — both clobber `a14` unconditionally at entry.

## 5. Hit behavior: stop-in-place → fly-through (hat_proc model)

**Symptom** (first report): "the main thing the boomerang just keeps going
straight if it hits the opponent" — `jbp_hit` never zeroed velocity, so the
object kept drifting at its last velocity through its entire hit-reaction
hold (blood spawn + 32-tick sleep).

**First fix**: modeled on `mk2-readonly`'s `sai_hit` (Mileena's real sai
throw) — `callr dead_projectile` then `calla stop_a8` unconditionally before
anything else, freezing the object in place for the hit-reaction hold.
Confirmed fixed via position dumps (froze solid exactly at the hit point).

**Revised per direct request**: the user asked to instead mimic
`mk2-readonly`'s `hat_proc` (Kung Lao's real hat throw) — a thrown blade
should cut straight through its target and keep flying off-screen, not stop
dead in it. Reading `hat_proc`'s hit handling confirmed the model:

```asm
hatp8
	callr	dead_projectile
	...
	move	b2,b2			; blocked ?
	jreq	hatpa

hat_blocked
	...				; reverses oxvel, bounces back
	jruc	hatpc

hatpa	tsound	>53			; hat hit sound - nothing else!

hatpc	calla	next_anirate
	sleep	1
	callr	proj_onscreen_test	; onscreen ?
	jrc	hatpc			; yes ---> keep flyin'
	jruc	delete_proj_and_die
```

On an **unblocked hit**, `hatpa` does nothing but play a sound and fall
straight into `hatpc` — the same onscreen-test loop as normal flight, with
**no velocity change of any kind**. Only a **blocked** hit reverses `oxvel`
to bounce back. Neither path re-runs the hit-detection check —
`dead_projectile` already consumed the hit, so this is flight-continuation
only.

`jbp_hit` was rewritten to match: on an unblocked hit, play the hit sound
and spawn blood, then fall into `jbp_fly_through` (a simplified
`next_anirate`/`sleep 1`/`proj_onscreen_test` loop, no arc accumulation, no
repeated strike-check) — the object keeps its existing velocity and rides
that loop until it exits the screen and dies via `delete_proj_and_die`. On a
blocked hit, `oxvel` is reversed (bounce back) before falling into the same
`jbp_fly_through` loop. See `src/MKZAP.ASM:3598` (`jbp_hit`).

**Verified** via the Lua harness (see below) with the boom_hi test's dump
window extended to d=150: the object's `oxpos` climbs continuously past
Reptile's own position (662 vs reptile at 675, then 671/680/689/.../788
with reptile trailing behind) with no freeze or reversal, then the flight
process cleanly disappears from the active list once it exits offscreen —
confirming fly-through-and-die, not stop-in-place.

## Test harness

`tools/jade_boomerang_test.lua` (run via
`tools/run_jade_boomerang_test.ps1`) drives all 4 boomerang variants plus the
3-part flash-counter sequence (fire / gated-repeat / after-cooldown) against
Kitana vs. Reptile in MAME, using button-press automation and process/action
polling. Diagnostics include register/stack dumps, an active-process-list
walk, an object-display-list walk (cycle-detected), an `fpalram` slot dump
(for palette-pool debugging), and `dump_boom_object()` (locates the flight
process by `procid=0x0700`, dereferences its `pa8`, and dumps
position/palette/flags/shape fields plus both fighters' positions for
comparison).

Two real bugs were found in the harness itself during this investigation
(not game bugs): wrong field offsets for `OFLAGS2` (was `0x100`, correct is
`0x160`) and `OZVAL` (was `0x1a0`, which is actually `OIMG`'s offset; correct
`OZVAL` is `0xc0`); and a missing pointer dereference on `A.p1_obj`/
`A.p2_obj` (these are addresses of pointer *variables*, not the objects
themselves).

All 7 cases (`boom_hi`, `boom_med`, `boom_lo`, `boom_ret`, `flash_1`,
`flash_2_gated`, `flash_3_after_cooldown`) currently pass:
`PASS reason=all_5_moves_confirmed`.

## Object struct / field reference (for future work in this area)

Confirmed via `DISPEQU.ASM`/`MAINEQU.ASM`: `oxval=0x80, oxpos=0x90,
oyval=0xa0, oypos=0xb0, ozval=0xc0, oflags=0xf0, oflags2=0x160,
osizex=0x120, osizey=0x130, opal=0x140, oimg=0x1a0, oshape=0x1d0,
oid=0x1c0`; process field `pa8=0xc0`. Palette pool (`PALL.ASM`):
`numpal=80` total, `palram==fpalram` (same base, confirmed via `MK2.MAP`)
holds `nmfpal=35` foreground slots first, then `bpalram` (`fpalram+35*0x40`)
holds `nmbpal=45` background slots.
