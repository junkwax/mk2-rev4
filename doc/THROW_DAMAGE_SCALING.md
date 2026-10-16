# Throws go through dmgscale too — Jax's multi-slam above all

`throwscale` (MAINEQU.ASM, default 1; requires `dmgscale`) — `super_wham`
([src/MKSLAM.ASM](../src/MKSLAM.ASM)) and `throw_damage_a10`
([src/MKREACT.ASM](../src/MKREACT.ASM)), both on the same `dmgscale_a10`.
Rig: `tools/run_jax_multislam_probe.ps1`.

Every throw in the game applies its damage with `damage_to_me` — the same hole
Ermac's slam had, for the same reason.

## Jax's throw was the most damaging input in the game

`super_wham` is 10 damage, and he gets it `jax_extra_slams + 1` times for
tapping High Punch (`super_slam_proc` keeps the extra slams coming while
`get_tsl(l_hp) < 10`). On top of `slammed_by_jx`'s 18 that is **58 off one
throw** — against Kintaro's 40, the hidden fighters' 45, and a 32–34 field.

Measured on the pre-change build: `drops=[10 10 10 10 18] total=58`.

**The extra slams now take the curve. The first slam and the 18 do not.** That
is deliberate rather than tidy: his *basic* throw is 10 + 18 = **28**, the
weakest in the game already, and it is not what anybody complained about. What
diminishes is the reward for mashing.

| | before | after |
|---|---|---|
| mashed (4 slams) | `10 10 10 10 18` = **58** | `10 8 5 2 18` = **43** |
| no taps | `10 18` = 28 | `10 18` = **28** |

43 now sits with Kintaro's 40 and under the hidden fighters' 45.

The index is derived from the loop's own constant — `jax_extra_slams + 1`
minus `p_anicount`, which counts down — so changing the number of extra slams
cannot leave the curve mis-indexed. `p_anicount` survives `double_mframew`; the
`dsj` already relied on that.

`super_wham` pushes `a1` across `calla_for_him` and `shake_n_sound`, neither of
which owes it anything, and works the damage out **last**, where the original
worked it out, rather than carrying it in a register across those two calls.

## The payloads

`throw_damage_a10` is `damage_to_me` with the curve in front of it, and all
seven payload sites call it: `slammed_by_jx`, `_fn`, `_st`, `_rd`, `_cage`,
`_goro` and `tossed_flight`. The switch is *inside* the routine, so
`throwscale 0` leaves them with the bare `damage_to_me` they had — one `.if`,
not seven.

**No minus one here**, which is the one difference from `erm_tks_scale`: a throw
is not a strike. Nothing in the path runs `reaction_start`, so nothing has
called `inc_p_hit` and there is no hit of its own sitting in the count —
`flipped_pause`, what `takeover_him` parks the victim on, is a bare sleep loop
into `reaction_exit`. That is also *why* Jax's extra slams need their own index:
a throw does not advance the string, so all four whams would otherwise land at
one depth.

Verified at every reachable site, full value at depth 0 and the curve at depth:

| thrower | reaction | depth 0 | depth 2 |
|---|---|---|---|
| Jax | `slammed_by_jx` | 18 | — |
| Liu Kang | `tossed_flight` | 32 | — |
| Cage | `slammed_by_cage` | 34 | **17** |
| Shang | `slammed_by_st` | 24 | — |
| Raiden | `slammed_by_rd` | 20 | — |
| Kitana | `slammed_by_fn` | 30 | — |

`slammed_by_goro` is Kintaro's and no player can throw with it, so that one site
is covered by inspection only.

### Honest limit: the payload half changes nothing today

A throw *can* legally follow a hit — `toss_check` refuses an airborne victim,
`act_land` and `b_noflip`, and `b_noflip` has exactly **one** setter in the whole
tree (MKPROP.ASM:2960), so an ordinary standing hit reaction does not block a
grab. But reaching it is another matter. `-Jab` lands a real High Punch and then
holds Low Punch from the tick it connects:

```
JAB landed at rel=123  victim p_hit=1 p2act=0x503
THROW at rel=171  dist=48  p2_bar=137  p2_p_hit=0
```

**48 ticks**, because the attacker's own jab recovery outlasts the victim's
hitstun — and `back_to_normal` had cleared `p_hit` by the time the grab went in.
Same with Jax. So the payload scaling is wired and correct, and in the sequences
that can actually be driven a throw still lands at depth 0 for full value. It is
a guard for the case where something slower-recovering or a juggle does put a
throw into a live string; it is not a nerf to anybody's throw today.

The thing that *does* bite is Jax's multi-slam, which needs no string at all —
its index is the slam number.

### A rig fault worth keeping

`-Jab` first scored Cage as `[24 34] total=58`: `prev_bar` was taken before the
throw, so **the jab's own 24 was counted as the throw's first slam**. The bar is
re-baselined at the throw now. And the jab has to be *sequenced* before the
grab — pressing both while the victim was still free let whichever handler the
switch scan reached first win, which was the throw, so it went in at `p_hit` 0
and the jab never happened.

Two more, both of which made the rig sit at `dist=63` forever reporting "never
threw": **`repell` will not let a walking pair closer than 63px** and
`toss_check` wants ≤ 64, so an approach threshold tighter than `040h` can never
be reached; and **an idle fighter reads `p_action` 0, not `act_stance`** —
`act_mframew_z` clears it when a move ends, the same trap JOY.ASM's own
simultaneous-throw guard documents.


## Locked

`tools/balance_lock.py`'s `SWITCHES` list now carries `ermtkgate`, `erm_tks_maxhit`, `erm_tks_cool`,
`ermtkscale`, `throwscale`, `jax_extra_slams` and `jax_wham_damage`, so Phase D
fails if any of them moves without `doc/balance.lock` being regenerated on
purpose. That file's own comment is the reason — *"adding a ruleset switch to
MAINEQU.ASM and forgetting it here is a silent hole in this guard: the switch
moves, the lock still matches, and nothing reports that the game plays
differently"*. The two Jax constants are in because together they **are** the
multi-slam's damage.

Regenerating added exactly those five rows and the digest, checked against a copy
taken beforehand — the working-tree lock already carried another session's
`stk_stelbow` score change, and a blind re-baseline would have been
indistinguishable from sweeping it in.

---

The same hole, and the shared curve it now calls, came out of Ermac's
telekinetic slam: [doc/ERMAC_TELESLAM_REGRAB.md](ERMAC_TELESLAM_REGRAB.md).

## Held hits on the kombo kounter (`holdhits`, 2026-10-04)

Reported by a player: "jax gotcha grab and gotcha throw dont show the combo
meter when repeating the lp or hp to continue to combo", and the hits did not
scale.

**Cause.** `do_noogy`'s punches (MOVES.ASM) and `super_wham`'s slams
(MKSLAM.ASM) both applied damage with `damage_to_him`, which goes straight to
`bar_reducer`. `strike_check` is the only producer of `hud_combo_hit` and of
`dmgscale`, so neither move reached either one. The grab also takes the victim over
without running `reaction_start`: `xfer_otherguy` drops `deferhit`'s pending
record. So his `p_hit` stayed 0 for every hit, and each hit read as the opening
hit of a new string.

**Fix.** `held_hit_to_him` (JOY.ASM, beside `dmgscale_a10`) does what
`strike_check` would have done, in the same order: scale, feed
`hud_combo_hit` the pre-hit count, then bump the victim's `p_hit`.

- Gotcha grab: index = his own string depth (`p_hit - p_scalebias`) less one
  (`a1 = -2`), so the first TWO punches land full and the curve starts on the
  third: **45 -> 31** with all five. A plain string-depth index (`a1 = -1`)
  gave 9 7 4 2 2 = 24, which was judged too big a cut.
- Multi-slam: index = the slam number, as before (`10 8 5 2`). Each slam
  is also credited to `p_scalebias`, so `slammed_by_jx`'s closing 18
  (`throw_damage_a10`, which subtracts the bias) still lands at the depth he
  was thrown at. The basic throw stays 10 + 18 = 28.
- `jx_slam_kounter` (MKREACT.ASM) adds that 18 to the kounter only if the
  throw is already a combo (2+ slams), so the readout's total matches the bar.
  A plain throw shows no readout, like every other throw.

An untapped gotcha grab is **two** punches, not one. That is Midway's order:
the next punch lands before the "stopped tapping" flag is tested.

Rig: `tools/run_jax_multislam_probe.ps1 -Move noogy|throw -Taps 0|1`, which
now also asserts the kounter (P1's `cmb_hits`/`cmb_dmg`). Measured:

| trial | drops | kounter |
|---|---|---|
| noogy, tapped | 9 9 7 4 2 = 31 | 5 hits / 31 |
| noogy, untapped | 9 9 = 18 | 2 hits / 18 |
| throw, tapped | 10 8 5 2 18 = 43 | 5 hits / 43 |
| throw, untapped | 10 18 = 28 | no readout |

`holdhits .set 0` (MAINEQU.ASM) restores the old behaviour.
