# The drone's beware frame is one slot deep

A hard lockup was reported from live play on 2026-09-09: Reptile (1P) against
the Noob drone on The Portal, mid round 1, the game frozen with the PC parked
on a self-jump.

## What the freeze was

The PC sat at `recovery` in [MKBUG.ASM](../src/MKBUG.ASM) — `jauc $`, the tail
of `illegal_opcode`. That is TRAP 30: the CPU had been handed an address that
was not code. The registers named the instruction that handed it over.

| register | value | what it is |
|---|---|---|
| A7 | `drone_retreat` | the instruction *after* `drone_approach`'s `retp` |
| A3 | `048h` | `drone_approach`'s target distance, `a11` |
| A1 | `p2_xvel` | `stop_me`, one instruction before that `retp` |

`retp` is `mmfm a12,a7` then `exgpc a7`, so after it runs a7 holds the *old*
PC — the instruction following the `retp` itself. `drone_retreat` is the label
immediately after `drone_approach`'s `retp`. So the drone finished a walk-in
to 72 pixels and its `retp` pulled a return address that was not code.

## Why the stack was empty

The process stack lives inside the process block. `reset_proc_stack` sets
`a12 = a13 + prcsiz` and pushes grow *down*. Blocks are contiguous at that
stride, confirmed by the probe: block `010ab020` ends exactly where block
`010ab710` begins. So popping one more than was pushed reads the next block's
`plink` — a RAM pointer — and `retp` jumps into RAM.

The frames drain through `p_beware_return`. It, `p_beware_a10` and
`p_beware_a11` are **one slot each**, but `drone_beware` is re-entrant: every
animation loop in MKDRONE calls it once a tick, including the loops a reaction
handler runs. `sdwp_heavy` — the whiff-punish walk-in — was the one handler
that both ran such a loop and then exited through `return_to_beware`:

1. The player's move ends. `bew_fire` stores `p_beware_return` = the stalk
   loop, and dispatches `sdwp_heavy`.
2. `jsrp drone_approach` pushes one frame. The drone starts walking in.
3. The player starts another move during the walk. `drone_approach`'s own
   `drone_beware` fires a second reaction, and `bew_fire` **overwrites all
   three slots** with the walk loop's own resume address.
4. That second handler exits through `return_to_beware`, resumes the walk, and
   the walk finishes. Its `retp` pops correctly and returns to `sdwp_heavy`.
5. `sdwp_heavy` then takes one of its own `return_to_beware` exits — and jumps
   to the *inner* loop, whose frame is already gone.
6. That loop runs to its `retp` again and takes a frame belonging to somebody
   else. Repeat until the stack is empty; the next `retp` reads the next
   process block's link word.

Step 3 is not rare — the probe sees it several times in a 3000-frame fight,
which is the game working normally. What was rare is step 5, because
`sdwp_heavy` was the only handler shaped that way.

## The fix

`save_beware_frame` / `restore_beware_frame` ([MKDRONE.ASM](../src/MKDRONE.ASM),
beside `return_to_beware`) push the trio onto the process stack, under the
nested call's own return frame, and pop it back. `sdwp_heavy` brackets its
`jsrp drone_approach` with them. A nested reaction that never comes back —
anything ending in `drone_reaction_exit` — discards the three longs with
`reset_proc_stack`, so the unbalanced case costs nothing.

`tools/audit_beware_reentry.py` finds every handler that runs a bewaring loop
and then reaches `return_to_beware` without the bracket. It runs with
`--check` in the build's Phase D, and it was verified to fail when the bracket
is removed rather than only passing when it is present.

## Tools

- `tools/sweep_addon_fuzz.lua` — random P1 input from a seeded PRNG, plus
  three live checks: process-stack bounds, `DOOMED` (a fighter parked in a
  `retp` loop with an empty stack — fatal on the next pop), and `NESTED` (a
  second `bew_fire` while the stack is deeper than the first one's, which is
  the precondition above). Rename to `sweep_addon.lua` to arm it. The ROM's
  `@rand` reseeds identically every round, so varying `FUZZ_SEED` is the only
  way to get a different fight out of the same matchup.
- `tools/run_noob_crash_hunt.ps1` — the same battles across a range of seeds.
- Two battles added to `tools/run_battle_stability_sweep.ps1`:
  `reptile_noob_portal` and `reptile_noob_deadpool`. Noob is a secret fighter,
  so like Smoke he can only be forced onto P2.

The stock sweep passed this matchup before the fix and still does — it presses
nothing, so the drone's reaction tree is barely entered. That is why the fuzz
addon exists.

## Still open

With fuzz input and `-NoHpPin`, `reptile_noob_portal` reports
`level_out_of_scope: worldtlx=0 bounds=[128,816]` at rel 2671. It reproduces
identically on the build *before* this fix, at the same frame on the same
seed, so it is not related. It is a camera/round-transition question and has
not been chased.

## The other anomaly: `level_out_of_scope` was the rig, not the game

Chased 2026-09-10. Under `-NoHpPin` with fuzz input, `reptile_noob_portal`
reported `level_out_of_scope: worldtlx=0 bounds=[128,816]`. Logging the whole
window said what the one line could not:

| rel | gstate | what |
|---|---|---|
| 810 | 5 `gs_bonus` | P1 lost the round |
| 996 | 6 → 7 | ladder advanced, `curback` 7 → 22, next match |
| 2002 | 3 `gs_buyin` | continue screen |
| 2184 | 11 `gs_gameover` | bounds now `[-80,4095]` |
| 2687 | 1 `gs_amode` | attract mode, bounds `[128,816]` |

The excursion ran rel 2671..3439, 769 frames, entirely outside a fight. Both
fighter objects were null and the anomaly snapshot is a black screen: the
stage had been torn down. `left_edge` / `right_edge` were whatever the last
thing to set them had left behind.

The cause is in the harness. `fighting_frame` is set once when gstate first
reaches `GS_FIGHTING` and is never cleared, so with the HP pin off the checker
follows the game through bonus, the next match, the continue screen, game over
and attract mode, comparing an attract-mode camera to a dead fight's scroll
limits. `check_scope` and `check_players` are now gated on `gs==GS_FIGHTING`;
`check_crash` deliberately is not, because a lockup in attract mode is still a
lockup and a long `-NoHpPin` run is a good way to find one.

Verified in both directions: the gated check still reports a real in-fight
excursion (`tools/sweep_addon_scopeprobe.lua` shoves `worldtlx` to 62000 px at
rel 300 and the harness says `level_out_of_scope`, as it should), and the
fuzzed `-NoHpPin` battles now pass. Full sweep 27/27.

**Anything a `-NoHpPin` run reports after the first round ends is suspect** for
the same reason: the rig thinks it is still watching the battle it set up, and
it is not — it is watching whatever the ladder did next.
