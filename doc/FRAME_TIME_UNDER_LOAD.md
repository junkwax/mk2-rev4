# Frame time under load

Measured 2026-08-26 with `tools/sweep_addon_stress.lua` (rename to
`sweep_addon.lua` to run) across the whole battle-stability sweep.

The earlier perf probe measured two fighters trading punches and reported
`overload = 2` on essentially every frame. That is a real result, but it is the
easy case. "We cannot lose any ticks or frames" has to be tested where ticks
would actually be lost.

## What is being read

| | |
|---|---|
| `overload` | `prcdsp` smooths `(overload + 2*timer)/2`. **2** means the process pass finished inside its tick. Any sample above 2 is a lost tick, so the histogram matters more than the mean. |
| `peak_overload` | the ROM's own high-water mark, zeroed at fight start so each battle reports itself and not the boot |
| `qdma_drops` | sprites **silently discarded** because the DMA queue was full. Non-zero is dropped picture, not just dropped time, and nothing on screen says it happened. |
| object count | how close the object list gets to its limit |

## How the load is generated

P1 spams Liu Kang's high fireball (`scom_lk_zaphi`, Forward Forward + HP) on a
46-frame cycle and throws a high kick between shots, while the P2 drone fights
back and both bars are refilled every frame so the round never ends and the
pressure never lets up. Projectiles, their impacts, the blood they cause and
the drone's answers all stack on top of whatever the stage costs.

The addon reports how many frames the object count sat above its idle baseline,
and says so when the generator barely fired — a battle that reports "clean" on
a load that never happened is worse than no measurement.

## Result: 21 battles, every stage, nothing lost

`overload` was **2 on 100.0% of 856 samples in every one of 21 battles**:
0 lost ticks, 0 `qdma_drops`, on all 14 stages including Outer Haven, Pit
Bottom, FLAPJACK and Kahn's Arena, and with Jade, Raiden, Kintaro and Shao Kahn
in the matchups.

Peak object count was **22** (raiden\_jax\_deadpool) against a DMA queue of 500
cells. Idle baselines run 2–13 depending on the stage.

One battle is marked weak and should not be counted: `kahnboss_p2_arena` only
got 19 frames above baseline, because Kahn is P2 and the fireball spam is P1's.

## Is the meter capable of reporting a failure?

A clean result is worth nothing unless the instrument can go red. So the same
rig was run twice more on the four Dead Pool battles, with the overlay's
per-piece layer as a deliberate load:

| `f_colbox` | what it adds | worst | lost ticks |
|---|---|---|---|
| 0 | nothing — the game | 2 | **0 / 856 (0.00%)** on all 21 battles |
| 5 | hitbox + hurtbox outlines (the useful mask) | 2 | **0 / 856 (0.00%)** on all four |
| 18 | silhouette + **every multipart piece boxed separately** | 33 / 121 / 11 | **37.5% / 66.8% / 87.0%** |

So the meter registers failure loudly when the load is genuinely raised, and it
reports zero for both the game and the shipped overlay mask. That is the result
worth having: **`f_colbox=5` is free, and bit 4 is not** — which is exactly what
[UNUSED_GRAPHICS_PRIMITIVES.md](UNUSED_GRAPHICS_PRIMITIVES.md) §5 says about
never measuring or sweeping with it on.

(`jade_p2_deadpool` stayed at 2 even at mask 18 — Jade is P2, the drone, and
that battle generated the least piece traffic of the four.)

## What this does NOT establish

Peak load here was 22 objects. Nothing in this sweep approaches a fatality's
explosion volume, a full blood cascade, or Shang's three simultaneous skulls,
and the DMA queue was never close to full. The honest claim is:

> under sustained projectile + melee pressure on every stage, on this build,
> the process pass never overran its tick and no sprite was ever dropped

not "the game cannot drop a frame". Finding the actual ceiling needs a load
generator that can reach a few hundred objects, and the per-piece result above
shows what the report would look like if it were ever reached.
