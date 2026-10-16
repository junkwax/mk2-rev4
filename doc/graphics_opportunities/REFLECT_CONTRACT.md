# One reflection routine for any stage (opportunity 21)

15 September 2026. **Prototyped and validated in MAME; compiled in, runtime-off;
built privately (`tmp/reflect_fx/build`), not installed.**

![THE DEAD POOL at rows 150-253, top to bottom: the baseline; the stage's record (two phases); the same record with one phase; a mirror hung from the front acid strip. Green is the reflection.](reflect_strip.png)

## What was missing

The Tower and the Dead Pool each had their own reflection code with the rules
built in. THE TOWER's is complete: it reflects every object that stands on
visible marble. The Dead Pool's fighter reflection was built on 2026-08-20
and removed the same day, because it drew on the attract and select screens
([DEADPOOL_ACID_REFLECTIONS.md](../DEADPOOL_ACID_REFLECTIONS.md)). The audit
asked for a contract instead: one routine, with the baseline, squash, tint,
band and gating as data.

## The contract

`reflect_p1p2` ([MKDISP.ASM](../../src/MKDISP.ASM), `reflfx`) runs right after
`shadow_p1p2` in `dmaq10`. A stage opts in from its `calla_` routine by
pointing `@refl_parm` at a record. `init_bakmods` clears that pointer for
every stage, the way it clears `@shad_fast`.

```
dedpool_refl                    ; BGND.ASM, THE DEAD POOL
    .word   20          ; base   rows above ground_y the figure's feet land on (W)
    .word   4           ; shift  squash 2^shift (ystep 2^shift.0): 1/16
    .word   0           ; flip   0 upright, 1 hung upside down from W
    .word   1           ; plog   2^plog phases, OR-ed: sample rows 0 and 8 of every 16
    .word   -28,-17     ; band   rows from ground_y it may draw on
    .long   006060000h  ; colour [constant : colour map], drawn dmacnz
```

Each fighter piece is **one scaled blit per phase**, the way `shadf` draws a
shadow:

- The DMA walks zero-compressed rows itself when it scales, and its Y window
  (`dmatplft`) keeps the band.
- A phase's first source row is found by walking the row headers on the CPU
  (`rfl_skip`, as `shad7` does), for any depth.
- Upright, row `y0 = W - (ground - T) >> shift` (T is the piece's top row).
  Flipped, the blit is given `2W - y0`, because a `dmavfl` blit draws upward
  from the row it is given.

**Gating, the thing the first version got wrong.** It draws only objects with
`b_shadow` set, and only in `gs_fighting`. The 2026-08-20 version skipped that
bit to reach the hangers, so it drew whatever `p1_obj` / `p2_obj` pointed at
on every screen that left `curback` at 0. On top of the gate, `@f_reflect`
(0 at power-up) keeps the prototype off at run time. `refl_ram` is a RAM
record a rig or a debugger can point `@refl_parm` at, to tune without a
rebuild.

## Validation (`tools/run_reflect_test.py`, `tools/reflect_test.lua`)

THE DEAD POOL, a two-human idle fight with the clock frozen. There are four
sequential boots on one frozen ROM, each windowed under `-debug`, and every
armed mode has `f_reflect` set **from power-up**:

| Gate | stage (2 phases) | phase1 | flip (front strip) |
|---|---|---|---|
| Attract and select captures vs the baseline (the leak) | **0 / 0 px** | 0 / 0 | 0 / 0 |
| Changed pixels, rel 400 / 430 | 313 / 313 | 272 / 281 | 523 / 525 |
| On the band's rows | rows 197-205 of 196-207, **0 outside** | 0 outside | rows 246-253 of 246-253, 0 outside |
| Not the pen's colour | **0** | 0 | 0 |
| `f_reflect` cleared (rel 460) vs the baseline | **0 px** | 0 | 0 |
| `peak_overload` / DMA queue cells / `qdma_drops` | 2 / 213 / 0 | same | same |

The baseline boot has the same 2 / 213 / 0. All four boots logged the same
`PREARM` line, and 2 late DMA frames show up in every mode, the baseline
included, so they come from boot and screen transitions.

**Idle regression:** `tmp/text_fix/text_ab.py` ran a full fight to FINISH HIM
and the FATALITY word on this build and on the build before it. The rig logs
are identical and 5/5 snapshots are pixel-identical.

**Cost:** one blit per piece per phase. Two fighters of about three pieces
each, at two phases, is about 12 blits of about 8 rows a frame, which is not
measurable in `peak_overload` or the queue.

## What it looks like, and why

On THE DEAD POOL it reads as a **green shimmer under each fighter**, not as a
figure. That comes from the stage's geometry, not the mechanism. Its acid
shows only in a 12-row strip behind the walkway and an 8-row strip at the
screen edge, and a 130-row fighter at 1/16 is 8 rows. At that squash the
second phase samples nearly the same silhouette: two phases draw only
**1.15×** the pixels of one.

A stage with a deeper band could use the shadow's 1/4 squash and show a real
figure. YOTEIGAI TOR's sea is measured by `tools/peak_sea_band.py`. That
stage would need only a record and one line in its `calla_` routine.

## Turning it on

- **Try it:** write `@f_reflect = 1` (resolve the address from `mk2.map`).
  Point `@refl_parm` at `refl_ram` to try other numbers live.
- **Ship it on THE DEAD POOL:** set `@f_reflect` in `calla_dedpool` (or drop
  the switch). That is a look-and-feel decision, and it has not been made.
- **Another stage:** add a record and point `@refl_parm` at it in the
  stage's `calla_` routine.
- **Compile it out:** `reflfx .set 0` (MAINEQU.ASM).

## Limits

- It reflects the fighters only: objects with `b_shadow` set. The Dead Pool's
  hangers have that bit clear on purpose, so they cast no shadow; reflecting
  them would need an explicit opt-in list, not a bypass of the gate.
- It draws one flat colour through `dmacnz`, with no shading.
- Like `shadow_p1p2`, it only suits bank-0 art: the CPU row walk has no bank
  select.
- FBNeo has not been run. The blits are the same scaled forms `shad_fast`
  already uses there.

Results: [reflect_results.json](reflect_results.json).
