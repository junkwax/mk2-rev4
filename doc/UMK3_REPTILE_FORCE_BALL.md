# Reptile's force ball — UMK3's velocity, our timing

**What shipped from UMK3: the two flight velocities. That is all.** The
timing half of this port was built, measured, and then *deliberately backed
out* — see "The 24-tick recovery, and why it is not here". No art, no damage,
no strike box, no input changed either. What is different from before this
work is one number: the fast ball's velocity.

| | UMK3 | ours |
|---|---|---|
| windup (input → ball leaves) | 15 | **16** — unchanged, always was |
| post-release recovery | 24 | **14** — ours, UMK3's 24 rejected |
| slow velocity | `0x30000` | **`0x30000`** — already matched |
| fast velocity | `0x70000` | **`0x70000`** — this is the change |

The rest of this document is the derivation, kept because the extraction is
sound and the structural map of UMK3's tables in it is reusable.

## Where the numbers came from

`C:\Users\you\Workplace\UltimateMortalKombat3\...\src\MKZAP.C` — the UMK3
source, same tree the Jade boomerang port used. That source writes the
**arcade** literals and scales them at compile time (`SYSTEM.H`: `SCX`/`SCY`),
so a bare tick count in it *is* the arcade tick count.

The lane structure was read independently out of `C:\MAME\roms\umk3.zip` so
the row counts are not taken on trust:

```
male_ninja_anitab2[0x05]   = ANIM_REP_RORB   (MKGUYS.H: #define ANIM_REP_RORB 0x05)
  -> byte 0x287dc, shared by all six male ninjas

  part 1   5 rows   windup; ani_sladd/ani_slani slave grows the ball in his
                    hands  (7x8 -> 25x56 -> 41x89 -> 69x111)
  part 2   4 rows   the windup retraced backwards to stance
  part 3   4 rows   flight loop, ends in ani_jump back to its own head
  part 4   7 rows   ani_swpal + the dissipation
```

## What UMK3 actually does

```c
void do_proj_reptile_orb     (void) { ...; orb3(SCX(0x30000)); }   // slow
void do_proj_reptile_orb_fast(void) { ...; orb3(SCX(0x70000)); }   // fast

void orb3(long pa11)
{
    animate2_a9(3,ANIM_REP_RORB);               // part 1, 5 rows @ 3 = 15
    (long)(create_proj_proc(orb_proc)->a10)=pa11;   // <- the ball leaves
    process_sleep(8);                           //            8
    mframew(4);                                 // part 2, 4 rows @ 4 = 16
    reaction_exit(current_proc->pa8);
}
```

**The fast ball and the slow ball are the same routine.** They differ in one
argument — the velocity — and in nothing else. Not one tick separates them.
Ours is built the same way (both inputs land on `do_slow_proj`; only
`f_fast_force` moves), so a change to the one routine reaches both, which is
exactly the relationship UMK3 has. That is why the velocity bump needed no
per-variant work.

## The 24-tick recovery, and why it is not here

UMK3 spends 24 ticks after the ball leaves: `process_sleep(8)` on the extended
pose, then part 2 unwinding the windup over 4 rows at `mframew(4)`. Ours spends
14 (`sleep 00ch` + a settle pose + `sleep 2`).

The 24 **was built and it worked** — `sleep 008h`, then `backwards_ani2` over
`a_slow_proj` part 1 at their 4-tick rate, then 8 ticks on the settled pose to
cover the two rows our lane does not have. It measured 6/6 at exactly 24 and
exited cleanly to `act_stance`. It was then reverted on purpose: 24 ticks of
lockout on a projectile this cheap makes it a different move, and 14 is the
number this ROM plays at.

**So a 24 in `do_slow_proj` is a regression now, not a fidelity fix.** The rig
asserts 14 for that reason.

Two things worth keeping from the attempt, if the unwind is ever wanted for
its own sake rather than for fidelity:

1. **Release lands at 16, not 15, and that is not tunable.** Their windup is 5
   rows, ours is 8 (`double_mframew` runs the body's part 2 against the orb's
   part 3 in lockstep — our equivalent of their `ani_slani` slave). 8 rows
   cannot make 15 ticks at a uniform rate. The windup was never touched by
   this work; 16 is what it has always been.

2. **`backwards_ani2` is the right primitive for an unwind.** Our
   `a_slow_proj` part 1 is `NJREPTHROW1, NJREPTHROW2`, and walking it backwards
   is structurally their part 2 — that primitive's own comment already notes
   UMK3 uses it "to un-wind a special move's own windup". It handles multipart
   composites (`ani2` walks the piece list), which these frames are.

## Velocity — the one thing that shipped

`orb3`'s one and only argument. UMK3:

| | UMK3 | ours, before | ours, now |
|---|---|---|---|
| slow | `SCX(0x30000)` = 3 px/tick | `0x30000` | `0x30000` (already matched) |
| fast | `SCX(0x70000)` = 7 px/tick | `0x60000` = 6 | `0x70000` = 7 |

The old comment called the fast ball "2x velocity". It never was UMK3's
number, and at `0x70000` it is 2.33x the slow one, so the comment went too.

The one thing worth checking before raising it: `slow_proj_proc` does not
strike-check while the ball flies, it explodes on *proximity* — `cmpi 030h,a1`,
a 48px window tested once a tick. At 7 px/tick the ball cannot step over that
window, so there is no tunnelling risk (it would take >48 px/tick, i.e.
`0x300000`, to break).

## What was NOT changed, and why

* **Flight rate.** Already identical: UMK3 `set_proj_vel(...,3)`, ours
  `movk 3,a0 / init_anirate`. Their flight loop is 4 rows to our 2, so a
  revolution differs, but a revolution is art.
* **`l_orb_slow`.** UMK3 stamps `l_orb_fast` from *both* variants and never
  stamps `l_orb_slow`, so `q_reptile_orb_slow`'s gate reads a timer nothing
  writes. That is a UMK3 bug in its own drone gate, not player timing.

## Where the 14 ticks came from

Worth knowing, since 14 is now the deliberate target: it was not authored at
14 either. It was `010h` + `4` = 20, and commit `2c84c74` ("Tune Sub-Zero
tornado and fan projectile behavior") took it to `00ch` + `2` = 14 in passing,
with the comment `shorter post-release recovery` and no force-ball rationale
anywhere in the commit. 14 is therefore an accident that was kept on its
merits, not a designed number — if the recovery is ever revisited, 20 is the
other value with a claim on it, and it is a smaller step than UMK3's 24.

## Proving it

```
tools\run_reptile_orb_timing_test.ps1
```

`do_slow_proj` marks its own boundaries — `p_action` is `act_slow_orb` for the
windup and `act_orb_sd` from the release to the end — so the rig counts
`p_action` dwell rather than eyeballing frames. It drives the real inputs
(Back,Back+HP+LP and Forward,Forward+HP+LP), not a forced call.

Velocity is read off the ball itself — the rig walks the active process list
for `pid_orb1`/`pid_orb2` and diffs that process's object `oxpos` every tick.
It is deliberately *not* inferred from "when did P2's health drop": an earlier
cut of this rig did exactly that and reported impossible flight times, because
a health drop dates the *hit*, and anything else that touches the bar looks
identical to it.

```
 variant | windup | recovery | px/tick | consistency
  slow   |     16 |       14 |       3 | 33 of 33 ticks
  fast   |     16 |       14 |       7 |  9 of  9 ticks
RESULT 6/6 windups = 16, 6/6 recoveries = 14, 6/6 velocities on target
```

Every tick of every flight was the same step — no ramp, no damping. Both
variants exit to `act_stance` (`0303`).
