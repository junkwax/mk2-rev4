# The corner roundhouse, measured

The one known balance defect carried in this project's notes since 2026-08-05:
*"opponent in the corner jumps, and can be roundhouse-kicked over and over
until dead."* It was root-caused then but never re-verified, and the collision
work in this build touched the hurt column (`anchorcol`), so it was worth
measuring rather than assuming.

Measured 2026-08-26 with `tools/sweep_addon_corner.lua` (rename to
`sweep_addon.lua` to run) on Liu Kang vs Jax, Dead Pool, both players human.

## How it was measured

The victim is pinned in X at the right-hand wall
(`right_edge + scrrgt - right_padding`, the same clamp `gravity_n_bounds`
applies) and nothing else about him is touched — the vertical half of every
juggle is entirely the engine's. The attacker is **not** pinned: he has to walk
back in himself after every shove, or the rig would be defeating the very brake
it is testing. He swings the instant he is idle and in range, which is the
fastest a player can legally repeat the move.

P2 has to be a **human**, not the drone — a drone will not jump on cue, and a
jumping victim is the whole reported bug. `p2_state` decides this, and
`MKGUYS.ASM` latches it once when it builds the fighters, so it cannot be set
from an addon: the sweep harness rewrites that word every frame of character
select and wins the race. Hence `run_battle_stability_sweep.ps1 -P2Human`.

Three victims, because "he died without acting" means nothing until you know
what happens when he defends instead:

| `CORNER_MODE` | what the victim does |
|---|---|
| `jump` | keeps jumping — the reported scenario |
| `block` | holds block — the answer a competitive player gives |
| `idle` | stands still — the floor for how fast the loop kills |

## Results

| | jump | block | idle |
|---|---|---|---|
| roundhouses thrown | 21 | 21 | 22 |
| hits landed | 12 | 21 (all blocked) | 11 |
| HP taken | 322 (2 rounds) | 161 (chip) | 321 (2 rounds) |
| victim died at | frame 368 (6.7 s) | frame 882 (16 s) | frame 436 (8.0 s) |
| hits landed airborne | 9 | 0 | 0 |
| peak `p_hit` | **1** | **1** | **1** |
| victim's free frames between hits | min 0, avg 15.5 | min 39, avg 41.1 | min 53, avg 59.0 |
| attacker not swinging, between kicks | min 20, avg 25.9 | min 20, avg 22.1 | min 20, avg 25.8 |
| attacks the victim got out | 0 | 0 | 0 |

## What that says

**It is not an infinite, and it is not the mechanism in the old note.**
`p_hit` never exceeded **1** in any of the three modes. `no_unlimited_airhits`
(MKREACT.ASM:3767) triggers at `p_hit > 3`, so it never fires;
`attacker_getting_separated` is never invoked, and `p1_xvel` never once carried
a separation request (`separation requested on 0 frames`).

The 2026-08-05 analysis — `away_x_vel` asks for 7 px/frame, `repell_now`
substitutes a fixed 3 px/frame and discards it — describes real code, but that
code path is never reached here. Each roundhouse is a *fresh single hit*: the
victim is knocked down, gets up, and is hit again. There is no juggle string
for the anti-infinite to count.

**What is real is the loop's period.** The attacker is out of `act_rhouse` for
a minimum of **20 frames (366 ms)** between kicks, every time, in all three
modes. That is an enormous window by fighting-game standards, and it is why a
blocking victim gets 39–44 actionable frames per cycle. The move is heavily
negative on block and a player who blocks and then punishes beats the loop
outright.

**Two things are still true and still ugly:**

1. **If you jump in the corner, you die.** The jumping victim got `min 0` free
   frames — jump, hitstun, and getup swallow the whole gap — and lost 322 HP
   across two rounds without landing a single attack. The corner roundhouse is
   a free, repeatable anti-air.
2. **Blocking alone loses the round.** `stk_lkroundh` is 32 on hit and **8 on
   block**; 21 blocked roundhouses chipped out a full 161-point life bar in 16
   seconds. These are the retail values, unchanged — chip death is authentic
   MK2, not something introduced here.

So the correct description is *a very strong corner loop against a passive
opponent*, not an infinite. It is escapable, and the escape is to block and
punish rather than to block and wait — or simply not to jump.

## If it is ever "fixed"

Do not reach for `no_unlimited_airhits`: it is not in this path. The knob that
would actually change the outcome is the 20-frame gap (roundhouse recovery,
`frame_edit.py` on `do_roundhouse`) or the 8-point block damage
(`hitbox_edit.py set stk_lkroundh damage_block=…`). Both are retail values, so
changing either is a deliberate departure from L3.1 and should be decided as
one, not slipped in as a bug fix.
