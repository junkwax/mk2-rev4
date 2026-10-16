# Dead Pool acid reflections — built, worked, removed

> **2026-09-15: redone as a general routine.** `reflect_p1p2` (MKDISP.ASM,
> `reflfx`) follows this note's advice. It is gated on `b_shadow` and
> `gs_fighting`, so it leaked 0 px onto the attract and select screens in
> MAME. The stage opts in through a record (`dedpool_refl`, BGND.ASM), and
> each piece is one scaled blit per phase instead of a line-by-line walk. It
> is compiled in but off at run time (`@f_reflect`). See
> [REFLECT_CONTRACT.md](graphics_opportunities/REFLECT_CONTRACT.md). The
> density problem below is still real: two phases add only 15%.

**Status:** implemented and verified working 2026-08-20, then **removed the same
day because it leaked onto other stages**. This note exists so it can be redone
properly rather than rediscovered from scratch. The code is recoverable from git
(`git diff HEAD -- src/MKDISP.ASM` at the time of removal; it was a self
contained ~265-line block in `MKDISP.ASM` plus a 4-line hook).

---

## Why it was removed

The routine was gated on the stage:

```asm
	callr	shadow_p1p2
	move	@curback,a0,w		; acid reflections are Dead Pool only
	jrne	refl_skip
	callr	reflect_p1p2
refl_skip
```

**`curback == 0` is not Dead-Pool-exclusive.** It is also the *default and reset*
value:

- `DIAGMENU.ASM:306` — `move a0,@curback,w  ; current background = 0`
- `MAIN.ASM:2305-2308` — `; first match starts at Dead Pool`, writes 0
- `MAIN.ASM:119` — `barge3`, clears it on the way out of MK1

So every screen that leaves `curback` at 0 — attract, character select, VS,
buy-in, endings, diagnostics — passed the gate, and green reflections of
whatever `p1_obj` / `p2_obj` happened to point at were drawn into those screens.
That is the leak.

### How to gate it properly next time

`curback` alone is not enough. Any of these is sufficient and cheap:

1. **Gate on stage AND state** — `curback == 0` *and* `gstate == gs_fighting`.
   Simplest fix, kills every menu/attract case.
2. **Gate on a flag the stage sets** — have `calla_dedpool` set an `f_reflect`
   word and clear it in every other stage's `calla_*`. This is the pattern the
   engine already uses (`f_shadows`), and it cannot be fooled by a default
   value. Needs a clear-on-every-other-stage sweep or it becomes a stale-flag
   bug of its own.
3. **Gate off the dlist marker**, the way shadows already are: shadows only run
   because `dlists_dedpool` contains `-2`. A `-3` reflection marker would be
   self-gating — a stage that does not ask for it never gets it. Most work, most
   correct, and it generalises to any future water stage.

Option 3 is the right one if this becomes permanent.

---

## Measured stage geometry (the part worth keeping)

Taken from a real standing fight, not from the tables. Screen is 400x254,
`worldtly` = -8 so `world = screen - 8`.

| screen y | rows | what |
|---------:|-----:|------|
| 196-207 | 12 | **ACID**, behind the walkway |
| 208-234 | 27 | walkway — the fighters stand here |
| 235-245 | 11 | walkway front face |
| 246-253 | 8 | **ACID**, in front / screen edge |

`ground_y` = 216 world → screen 224.

**The Dead Pool is a stone catwalk over acid, not a pool you stand beside.** The
acid is only visible in two thin strips. A full mirrored reflection does not
fit; anything done here is a stylised shimmer in a 12-row band. This is the
single most important thing to know before designing the effect again.

Cross-check: `MKHANG.ASM`'s `acid_fx_y` is `0b8h` = world 184, and the acid band
measures world 188-199. Those agree, so the splash surface and the reflection
band are the same water line.

---

## What was built, and how

`reflect_p1p2` in `MKDISP.ASM` — a modified copy of `shadow_p1p2`, called from
`dmaq10` right after it, inside the same `f_shadows` gate. Four differences:

1. `dmaconst` acid green instead of `bpal_black`
2. 16 source lines per output row instead of the shadow's 4
3. base is the waterline (`ground - refl_drop`) rather than the ground line
4. a slow x wobble off `@tick`

Tuning constants, all one-word edits: `refl_const`, `refl_squash`, `refl_drop`,
`refl_wobble`, plus `refl_hconst` for a separate hanger shade.

### Why it kept the line-by-line walk instead of using the hardware

The obvious implementation is one blit per piece with `dmavfl` (vertical flip)
and `dmayscl` (squash). It was deliberately **not** done that way:

- The art is zero-compressed (control word `6580h`, bit 7), so there is no fixed
  stride from one source line to the next. `shad7` decodes each line's
  run-length header to advance, and the reflection reuses that verbatim.
- Writing output rows one at a time gives exact control of squash and row order
  without ever assuming the blitter's flip and scaler agree with compression.

It is also *cheaper* than the shadow: 8 output rows per piece versus ~32.

### Verified results

- Fighters: 8 rows of `boonpal` idx 6 at screen rows 200-207, tracking both
  players, inside the acid band.
- Ed (hanger 0): 55 px at x 129-170, rows 199-205, in `boonpal` idx 7.
- Shadows unaffected; removing the routine left 1720 black shadow pixels intact.

---

## Findings that outlived the code

**Hangers deliberately have `m_shadow` cleared** (`MKHANG.ASM:1196`) so they cast
no ground shadow. Reflecting them needs an entry point *below* the shadow gate.
The one that was used (`refl0a`) still refused anything without `b_multipart`,
because `oimg` is only a multipart-RAM pointer when that bit is set — walking it
otherwise streams garbage SAGs straight into the blitter.

**Hangers share the fighters' frame of reference.** `doc/DEADPOOL_HANGING_BODIES.md`
says the parallax layer uses `worldtlx4`, but the code reads `@worldtlx+16` and
inserts via `insobja8` into the main `objlst`. No parallax correction was needed.

**A minimum-row clamp is not what limits density.** The hanging bodies are built
from ~10-row strips (`EDHANG1A` is 13x10), so a ÷16 squash floors every strip to
zero rows. Adding a 1-row minimum looked like the obvious fix and changed the
output by **exactly zero pixels** — the theory was wrong. Density is limited by
strip *width*, not row rounding.

**Density was the open visual problem.** About 19% fill across the footprint, so
it read as a speckle rather than a shape. Untried knobs: `refl_squash` 4→3
(doubles rows but overflows the 12-row band), drawing each sampled row twice
(denser without changing the span), or a brighter `refl_const`.

**No bank select.** Like `shadow_p1p2`, the routine has none, so it is only
correct for bank-0 art. Every stock fighter qualifies; a bank-1 sidecar frame
would shear exactly as its shadow already does.

---

## If this is picked up again

1. Gate it off a dlist marker (option 3 above), not `curback`.
2. Fix density before anything else — it is the difference between "atmospheric"
   and "why are there green dots".
3. The reflection band and `MKHANG`'s acid surface agree, so a body falling into
   the acid and its reflection rising to meet it at the water line is a real
   possibility, and cheap: both already key off the same y.
