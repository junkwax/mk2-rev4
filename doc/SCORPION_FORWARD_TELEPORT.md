# Scorpion's forward teleport punch — Down, Forward + Low Punch

`scfwdtele` (MAINEQU.ASM) · `do_fwd_decoy` (MKPROP.ASM) · `sc_lp_fwdtele` (MOVES.ASM)

Retail Scorpion has one teleport: **Down, Back + High Punch** (`do_decoy`).
He leaps **away** from the man, warps at the screen edge he is flying toward,
and comes down on the far side — a crossover.

This adds the same move with the direction mirrored, on a button and a motion
that were both free for him:

| input | move | direction |
|---|---|---|
| Down, Back + **HP** | `do_decoy` (retail) | away, warps, lands **behind** him |
| Down, Forward + **LP** | `do_fwd_decoy` (new) | **at** him, warps, lands **in front** |

Both share `l_decoy`, so the cooldown is one cooldown — see "Cooldown" below.

## It is two instructions, not a second teleport

`do_fwd_decoy` sets one flag and falls into `do_decoy`, exactly the way
`do_ermac_decoy` does. Everything that moves him is shared and unbranched: the
launch kick (`-030000h`), gravity (`05000h`), the anirate of 6, the afterimage,
`decoy_scroll`'s camera freeze, the every-tick strike check on `stk_decoy`, the
screen-edge warp, the landing. Two instructions read the flag:

**No `flip_multi`.** Retail turns him round so he faces the way he is flying —
away — and the warp then lands him facing the man from the far side. Flying
*towards* him he is already facing the right way (`air_init_special` calls
`face_opponent`), and the warp lands him facing the man from the near side. The
flip would put his back to the fight for **both** halves of the flight.

**`towards_x_vel` instead of `away_x_vel`**, same `0c0000h` magnitude. That
routine already sits two lines below `away_x_vel` in MOVES.ASM; nothing new
was written to move him.

**`cos_edge` needed no change at all.** It picks which edge to warp at off the
**sign of `oxvel`**, not off the facing flag — read the comment there, it was
written for a desync between the two — so it already handles a flight in
either direction, including the corner cases where the edge clamp zeroes the
velocity.

## What it plays like

The strike box is live from tick one (retail's teleport "sticks" on a close
opponent for the same reason), so a man standing in front of Scorpion is
punched on the way past. From far out nobody is in the way: he crosses the
screen the other way and comes down on the side he started from — a jump-in
that reads as a crossover and is not one.

So the pair is a genuine mix-up rather than one move twice: D,B+HP takes the
far side, D,F+LP threatens the near one.

## Where it sits in the input

`sc_lo_punch` tests the spear (Back, Back) first, then falls to
`sc_lp_fwdtele`. The two motions cannot both match and a failed
`combo_look_lr` scan has no side effects, so the order only decides which gets
the queue first — the spear keeps it, so retail's move is untouched.

Button masks are `sc_lo_punch`'s own, copied verbatim. `airborn_xfer`, like
the backward teleport, so it works out of a jump too.

`scom_sc_fwdtele` is its **own** combo record, not an alias on
`scom_ice_ball` — which is the same Down,Forward at the same `010h` window. An
alias shares the *window* as well as the pattern, and a tuning change to the
ninja ice ball would silently move this with it. (`scom_spark`/`scom_decoy`
being stacked on `scom_rain_bolt` is the failure this avoids.)

## Cooldown

`l_decoy`, gated at `060h` — `schp3`'s own number, shared deliberately. Two
teleports that each reset only their own timer would let him **alternate** them
with no cooldown at all.

## The flag

One `.bss` word, `f_fwdtele` (RAM.ASM), for both fighters. That is safe because
there is **no sleep** between the write in `do_fwd_decoy` and the two reads at
`dec_takeoff`: `air_init_special`, `gmo_proc`, `do_first_a9_frame`,
`match_ani_points`, `exprc_er` and `fastxfer` are all plain calls, so no second
process can get a turn inside the window. `f_noedge_obj`, three lines below it
in RAM.ASM, is one object for the same reason — only one fighter can be
teleporting.

`do_decoy` **clears** it on the way in, so `do_ermac_decoy`'s fall-through and
the drone's propell #4 both get the backward flight even if a 1 ever leaked.
It is not in `round_init_words` on purpose: nothing can observe it stale.

It is exported with `.globl` beside its `.bss` line in RAM.ASM and `.ref`'d in
MKPROP.ASM, **not** `.global`'d from MAINEQU — MAINEQU is included by ~70
objects and is the GSPA cliff.

## The CPU uses it as its long-range punish

Since 2026-09-30 (`drone_sc_fwdtele`, MKDRONE.ASM) the CPU Scorpion throws it
from `ochar_punish` row 10 - the move each fighter uses on an opening it cannot
reach with a normal attack. It flies AT the man with its strike box live from
the first tick, which is exactly what that slot wants, and the slot was empty.
It is refused inside the shared `l_decoy` cooldown (`060h`), the number
`sc_lp_fwdtele` refuses it on, so the CPU cannot alternate the two teleports
any faster than a player can. Everything else is unchanged: the spear, and the
backward teleport through propell #4. Measured at diff 8 with
`tools/drone_move_census.lua` (`CENSUS_FLAG=f_fwdtele` splits the two, which
share `act_decoy`): 8 of 33 teleports in 75k fighting frames were the forward one.

## Turning it off

`scfwdtele .set 0` (MAINEQU.ASM) removes the propell slot, the combo record,
the MOVES thunk and both forks; `sc_lo_punch` goes back to falling straight to
`death` on a failed spear. `f_fwdtele` stays declared and `do_decoy` still
clears it — two instructions, so no `.if` is needed around the clear.

## Rig

`tools/run_scorpion_fwdtele_test.ps1` (+ `tools/scorpion_fwdtele_test.lua`).
A 2-player game, P1 Scorpion, P2 an idle Jax, both bars pinned every frame.

| trial | input | must show |
|---|---|---|
| `fwd` | P1 left of P2, D,F+LP | flag 1, `oxvel` **positive**, facing **kept**, warp at the **right** edge |
| `back` | same spot, D,B+HP | flag 0, `oxvel` **negative**, facing **flipped**, warp at the **left** edge |
| `fwdleft` | P1 **right** of P2, D,F+LP | flag 1, `oxvel` **negative**, facing kept, warp at the **left** edge |
| `cool` | D,F+LP, `l_decoy` stamped now | refused — no `act_decoy` |
| `coolback` | D,B+HP, `l_decoy` stamped now | refused |

**It reads `f_fwdtele`, not just the direction.** A hard-coded sign gives the
right velocity on one side of the screen and a stale facing bit looks like a
kept one, so the flag is what separates a working fork from a coincidence —
and `fwdleft` is there because that hard-coded sign would pass `fwd` and fail
on the other side. **The facing is asserted separately from the direction**: a
rig watching `oxvel` alone would miss `flip_multi`, which is the half of the
change that decides whether he lands facing the fight.

**`coolback` is what proves the two teleports share the cooldown** — the
*backward* teleport refused by a timer only a forward cast could have set.
Both cooldown trials write `l_decoy` directly (it is a p1/p2 pair of words and
`get_tsl` just returns `tick - l_decoy[p]`) rather than racing the previous
trial's landing, the way `run_rain_halfdmg_probe.ps1` seeds `rh_cdmg`.

**The victim is teleported out of the flight path on the takeoff frame.**
`crossover_scan` strike-checks from tick one and the box reaches `076h`, so a
forward teleport aimed at a man standing there *connects* — `decoy_hit` freezes
the flight and there is no warp left to measure. That is the move working, so
the rig moves him opposite the travel, **after** reading the launch velocity —
which is already written by then, because `do_decoy` runs entry → velocity in
one process turn with no sleep.

`-Negative` crosses the forward and backward expectations and every crossed
trial must FAIL; swapping the two directions is the likely regression, so that
is the control worth having.

**Every constant is read out of the build** — `scrrgt`, `m_fliph`, the object
field offsets, `act_decoy`, `p_action`, `scfwdtele`, the `060h` cooldown out of
`sc_lp_fwdtele` itself and the `0c0000h` launch speed out of `dec_takeoff` — and
a constant it cannot read is **fatal**, never defaulted. The launch-speed reader
is anchored on `dec_takeoff` for two reasons that both fail silently: MKPROP has
an earlier `calla away_x_vel` (Reptile's dive), and the new `.if scfwdtele` block
sits between the `movi` and the call, so "the line before `away_x_vel`" is
`.endif`.

A missing `src/mk2.map` is reported as a refusal naming the cause — several
sessions build in this tree and a failed assembly deletes the map — and an empty
run is a FAILURE, not a pass.

## Files

| file | change |
|---|---|
| `src/MAINEQU.ASM` | `scfwdtele .set 1` |
| `src/MKPROP.ASM` | `do_fwd_decoy`, propell slot `16h`, the two forks in `do_decoy`, the `.ref` |
| `src/MOVES.ASM` | `do_fwd_decoy` thunk, `scom_sc_fwdtele`, the `sc_lp_fwdtele` hook |
| `src/RAM.ASM` | `f_fwdtele` + `.globl` |

Verified: full `gmake -m` assemble **and** link, no errors
(`+64` bytes of program ROM); `tools/check_pcrel_range.py --check` and
`tools/check_stack_clearance.py --check` both pass.
