# The perfect block

An advanced blocking technique: raise the guard in the last instant before a
strike arrives and the block is a *better* block. The fighter flashes white,
the chip barely registers, and he comes out of the guard sooner than the
attacker comes out of the move — so strings that are safe against an ordinary
block stop being safe.

Same idea as MK1's just-block, and as Just Defend / Instant Blocking
elsewhere. Nothing about an ordinary block changes, so a player who never
learns it plays retail MK2.

Switch: `jdefend .set 1` in [src/MAINEQU.ASM](../src/MAINEQU.ASM), next to
`chipfloor`. Set it to 0 and every line of this compiles out.

## How to do it

Tap **Block** as the attack is arriving, rather than holding it. The window is
`jdwindow` ticks (4, ~73ms) measured from the moment the guard goes up.

Two things follow from *where* the window is measured, and both are
deliberate:

- **Holding block does not re-arm it.** `block_exit` returns to
  `joy_block_loop`, not to `joy_block`, so the second hit of a blocked string
  is an ordinary block. Earning it again costs a release and a fresh press —
  which is the skill the mechanic is asking for, and the same rule instant
  blocking uses everywhere else.
- **Back-blocking never earns it.** With `backblock` on, holding away guards
  without a button. That is a passive guard that never goes through
  `do_block_hi` at all, so there is nothing to time. The reward is for the
  press.

The CPU does not get it (`jdjoyonly .set 1`). The drone reaches `do_block_hi`
from `drone_block`, which is a *reaction* to seeing an attack start, so its
guard would land inside the window nearly every time it blocked at all — it
would perfect-block by construction rather than by timing.

**The window has a NEAR edge as well as a far one, which is easy to state
wrongly.** `jd_arm` (JOY.ASM) runs at the moment a strike is *blocked* and asks
`get_tsl l_jdguard` how long ago the guard went up, failing on `jrhi jdwindow`.
So the test is "the guard went up within the last 4 ticks", not "the press came
within 4 ticks before the hit" — pressing too EARLY scores an ordinary block
just as pressing too late does. Against a move stamped at t=0 that lands at
t=6, the presses that earn it are t=2..6; a press at t=0 or t=1 does not.

**And the `jdjoyonly` rationale above only covers the slow half of the range.**
It is sound for anything the drone can actually react to, which is most of the
game — but it inverts at the fast end. `drone_react_delay` (MKDRONE.ASM) is 8
ticks at diff 9 with `drnhuman` on, so against a move that lands 6 ticks after
it starts the drone's guard goes up 2 ticks LATE: it does not perfect-block by
construction there, it does not block at all. The exclusion is still the right
call — it is right for the roundhouse and for everything slower — but "inside
the window nearly every time it blocks" is true of slow moves only.

That 6-tick landing is mk2-main-f5's measurement, not reproduced here, and it is
narrower than it sounds: `tools/run_boss_exploit_test.ps1 -Boss kahn -Mode
hikick`, the `startup window` RESULT line, min=avg=max=6 across four runs and
both sides of their A/B — tight, but **one rig measuring ONE fighter's high
kick** (Sub-Zero, ochar 8), with the roster never swept. `-Char <ochar>` is the
knob if it ever matters per character, and a fighter whose high kick lands a
tick or two later would move the near edge with it. See
`doc/BOSS_AIR_AND_PUNISH.md`. The 8 ticks is read straight off
`drone_react_delay`'s `drnhuman` row and is a source fact.

This clause lives here and NOT beside `jdjoyonly` in MAINEQU.ASM on purpose:
MAINEQU is `.include`d by ~70 objects, ~20 lines added to it once aborted
MKDEATH.ASM with GSPA `Out of memory`, and prose belongs in `doc/`.


## What it is worth

Measured on Liu Kang's high kick against a guarding Jax
(`tools/run_jdefend_test.ps1`):

| | chip | block stun | guard age at contact |
|---|---|---|---|
| ordinary block | 8 | 14 frames | 7–10 ticks |
| **perfect block** | **2** | **10 frames** | 0–4 ticks |

Chip is cut by `jdchipsh` (2 → a quarter). Chip in this game runs 2–10 with a
median of 5, so a quarter turns the median blocked hit into 1 point and the
cheap ones into 0.

The 4 frames come off `block_shake`, which plays `a10` two-frame shakes at
`a11` ticks each; all but a handful of the blocked reactions ask for 3 at
sleep 2, which is 12 ticks. `jdshake` caps the repetitions at 2 on a perfect
block, so one whole shake — 4 ticks, roughly the startup of a jab — comes
back. `jdshake 1` is the aggressive setting and hands back 8.

The sleep (`a11`) is deliberately left alone: shortening the individual frames
would speed the *animation* up and read as a glitch, where dropping a
repetition just ends it sooner.

## Where the code is

| what | where |
|---|---|
| the knobs | `MAINEQU.ASM`, after `chipfloor` |
| guard-raise stamp | `do_block_hi` (MOVES.ASM), `do_duck_block` (JOY.ASM) → `l_jdguard` |
| the decision, chip cut, flash | `jd_arm` (JOY.ASM), called from `strike_blocked` |
| the white flash | `jd_flash_proc` + `jd_white_p` (JOY.ASM) |
| the stun cut | `jd_shake_cap` (MKREACT.ASM), called from `block_shake` |
| round clear | `round_init_longs` (MAIN.ASM) |
| RAM | `l_jdguard`, `f_jdefend` (RAM.ASM) — p1:p2 word pairs |

`f_jdefend` is written on **every** blocked strike, 1 or 0. That is what keeps
it self-clearing: there is no path where a stale 1 survives into the next
block, so nothing downstream has to remember to clear it. It is also what the
test rig classifies samples with, so the rig never has to trust its own
timing.

### Two things that bit during the build

**The flash has to wait one tick.** Every blocked reaction opens with
`blocked_start` → `reaction_start_chores`, which calls `player_normpal`. Swap
to white before that runs and the reaction wipes the flash out in the same
tick it appeared — as invisible as not doing it at all, and it looks like the
palette code failing. `jd_flash_proc` sleeps 1 first.

**The chip cut has to happen before the strength subtraction.** For the same
reason `chipfloor` is written up the way it is: a lethal blocked hit never
reaches `bar_reducer`, it is routed to `block_is_useless` instead. A discount
applied further down would be applied to a value nobody reads.

### What does not get the stun cut

A handful of blocked reactions never call `block_shake` — `b_shred` runs its
own loop, `separate_us` goes straight to `block_exit`. Those still get the
chip discount and the flash; only the stun half is missing. They are the
exception, not the rule (`b_standard` and the 30-odd reactions around it all
go through `block_shake_n_exit`).

## Testing

```
python build.py --asm-only && python makerom.py && python makevrom.py && python mamerom.py
tools\run_jdefend_test.ps1             # the numbers above
tools\run_jdefend_test.ps1 -Shots      # + snapshots of the white flash
```

The rig drives P1's high kick on a fixed period and walks P2's block offset
across that period, so the guard goes up everywhere from 20 ticks early to on
the contact frame. Samples are bucketed by the ROM's own `f_jdefend` word.

P2 must be a human (`SWEEP_P2_HUMAN=1`) — with `jdjoyonly` on, a drone cannot
earn a perfect block and every sample would land in the ordinary bucket.

**A drop in HP is not classified on the frame it happens.** The reaction
transfer has not run yet, so `p_action` still reads `act_blockhi` for a clean
hit too — and since `f_jdefend` is only rewritten by a *blocked* strike, a
clean hit landing after a perfect block inherits its flag. That is not a small
effect: it put clean 24s in the perfect bucket and reported "perfect blocks
take MORE chip". The rig waits two frames and asks again.
