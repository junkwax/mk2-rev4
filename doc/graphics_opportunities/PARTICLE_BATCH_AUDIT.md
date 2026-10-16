# Particle batching audit (opportunity 09)

14 September 2026. **Audited from source and existing measurements; nothing
changed.** Verdict: batching particle updates is not worth building. It saves
processes and scheduler work, and processes are neither scarce nor dangerous
here. Two unrelated robustness gaps turned up instead.

## The pools, measured

`tools/run_runtime_budget.py` (three pinned busy fights, 2,400 frames each,
`tmp/build_report/runtime.json`):

| Scenario | Processes | Objects | Blood |
|---|---:|---:|---:|
| Sub-Zero vs Scorpion, Dead Pool | 27 / 168 | 40 / 358 | 11 / 64 |
| Kitana vs Jax, Tower | 26 / 168 | 26 / 358 | 8 / 64 |
| Liu Kang vs Baraka, Armory | 20 / 168 | 45 / 358 | 10 / 64 |

Attract play peaks at 9 blood processes (`blood_count_probe.lua`, from the
blood-cap leak fix).

## Worst case, bounded from source

A body explosion (`explode`, MKDIE.ASM, driven by `exp_burst`/`exp_kiss`)
spawns one `pid_bones` process per piece: 8 + 3 + 8 + 4 + 2 = **25**. With the
busiest measured fight (27), the explosion's own helpers (`kiss_explode`,
`delete_offscreen`, the flash - about 5) and blood at its hard cap (64), the
total is about **121 of 168**. Only two explosions overlapping would approach
the pool.

And exhaustion is soft: `getprc` (MPROC.ASM) returns `a0 = 0` when the free
list is empty, blood above `MAX_BLOOD` is refused the same way, and a corrupt
free-list pointer is also reported as empty. Callers skip the effect.

## Why batching misses the real hazard

Rain already runs 24 persistent objects from one process. Doing the same for
bones, drips and sparks would cut processes and dispatch overhead, but every
particle is still an object and still a blit. **Objects are the pool that
hangs:** `getobj` running dry makes `object_setup` hit `ermac` = `jauc $`.
Batching does not change that count.

## Two gaps found on the way (candidate fixes, not built)

1. **Body-explosion pieces take objects unguarded.** `explode_piece`
   (MKDIE.ASM) calls `gso_dmawnz` for each of the 25 pieces with no
   `objs_available` check (the MKFX guard that let Scorpion's ~72-piece toasty
   burn go back to retail). Fights use at most 45 of 358 objects, so an
   explosion alone is safe; it matters only if it coincides with another bulk
   object grab. The fix is the existing pattern: skip a piece when fewer than
   the reserve would remain.
2. **The FATALITY word still competes with blood.** `win7` (MAIN.ASM) starts
   it through `create_blood_proc` slot 0dh (`fatality_drip`), which then does
   `create pid_blood,fatal_reveal`. Both count against `MAX_BLOOD`, and the
   word is requested at round end when gore is heaviest, so a saturated cap
   drops it silently - the case the blood-cap fix warned about. The fix is to
   exempt the reveal from the droplet cap, not to raise `MAX_BLOOD`.

Neither has been reproduced in a run; both are read from source.
