# Kitana's overhead spin chop — `ktspin`

Hold **Block** and tap **Forward, Forward** as Kitana and she brings an
overhead chop down on the other fighter. This project's own move, not
Midway's: six multipart frames (`KTSPINCHOP1-6`, A/B pieces) out of
`data/KITSPIN.IMG`, a high strike box (`stk_fnspinchop`, `fn_strikes` 018h),
32 damage on a clean hit.

**It is compiled out as of 2026-10-04** at the user's request.
`ktspin .set 0` in `src/MAINEQU.ASM`; `ktspin .set 1` brings it back, and
both states are proven by the rig below.

## What the switch takes out

| path | how it is gated |
|---|---|
| the player's input | `fn1_lr` (MOVES.ASM) takes `jruc death` instead of its body, so Forward, Forward under a held Block is just a blocked walk again |
| the move itself | `do_fn1_spinchop` (MOVES.ASM) is not assembled |
| the drone | `rpt_fnspinchop` (MKDRONE.ASM) becomes ten zeros |
| the drone's wrapper | `drone_wrap_fn1_spinchop` keeps its label and becomes a bare `jruc reaction_exit` |

### The drone is gated by DATA, and that is deliberate

Both drone callers — `fn1_start`, her round opener, and the Kitana branch of
`close_he_is_ducking`, her answer to a crouch-blocker — reach the chop only
through `ask_mr_diff` on `rpt_fnspinchop`, and `randper`'s compare cannot
borrow against 0, so the carry they branch on is never set. The code is left
standing and simply unreachable.

It is written as `60*ktspin,90*ktspin,...` rather than wrapped in
`.if`/`.else`/`.endif` because **MKDRONE.ASM assembles at GSPA's ceiling and
has no room for directives.** Measured: the pristine file assembles clean,
and ONE `.if`/`.else`/`.endif` in it aborts with `>> Out of memory` on
`PASS 2` (it already needs PASS 1.1-1.3 ON SECTION .text). Trimming the
comment around it did not help — see
`doc/` notes on the same ceiling in BGND.ASM, MOVES.ASM and MKDEATH.ASM.
An arithmetic operand costs no directive and reads the same `.set`.

MAINEQU.ASM is the other half of that cliff: it is `.include`d by ~70
objects, so prose there is assembled 70 times. The first draft of this
feature's comment lived in MAINEQU and was enough on its own to push
MKDRONE over. The detail is in this file for that reason.

## What it deliberately leaves alone

- **`stk_fnspinchop`** (MKSTK.ASM) — that table is positional and
  `doc/balance.lock` reads it.
- **`act_fnspinchop`** (0111h) and the **`c_fnspinchop` / `ct_fnspinchop`**
  counter rows — `counter_tab` is indexed BY action code, so row 111 has to
  stay a `.long` whether or not anything can ever set it.
- **`scom_fn1_spin`** — `src/FLYMOVES.ASM` names it at **index 8**, that
  table is positional, and the fly brain's learned weights are indexed by
  it. Compiling the record out would shift 89 later entries. The fly may
  still offer the pattern; `fn1_lr` throws it away.
- **`char_joyleft` / `char_joyright` rows 4 and 18** (Kitana, Khameleon) —
  also positional, and `tools/make_fly_moves.py` walks their `.long` lines
  to attribute each `scom_` to a fighter. An `.if`/`.else` there reordered
  `tools/flybrain_moves.lua` for **Raiden's torpedo** as well as for this
  move, which is why the refusal moved inside the handler instead.
- **`fn1_anitab2` / `fn4_anitab2` row 0ah**, which still names
  `a_fn1_spinchop`. A slot that is harmless if it is read is worth more than
  one proven unread — the same call `fn4_anitab2` already makes for
  `a_death_kiss1`.

## The art is still packed

`data/KITSPIN.LOD` keeps its ~19KB of bank 0, and reclaiming it is **not** a
one-line follow-up: `data/MK1SKULL.LOD` rides in KITSPIN's tail at 45,194
bytes against a 45,568-byte slot, so that payload is frozen against this
one's size (see the comment in `data/IMGBUILD.BAT`). Freeing the space means
re-laying MK1SKULL first.

Because the lane is still named by `fn1_anitab2`, `tools/art_ref_graph.py`
will keep calling these records LIVE. That is accurate about the ROM — the
pixels are there — and says nothing about whether a player can reach them.

## Proof

`tools/run_kitana_spinchop_test.ps1` is a **two-sided control**: it reads
`ktspin` out of `src/MAINEQU.ASM` and inverts its own expectation, so it
guards the disable instead of going permanently red.

```
ktspin 1 -> PASS  move_fired=true  sag_frames=120  p2bar 161 -> 129
ktspin 0 -> PASS  move_fired=false sag_frames=0    hit=false
```

The `ktspin 0` run is the one that matters, and it is only worth anything
because the log shows Kitana really did make the gesture: P1 is `objchar=4`,
`act=0x0700` (`act_blockhi`) appears throughout, so Block was held, and
`act=0x0111` appears **nowhere** in the run.

Three ways that rig had rotted since 2026-07-30, all of which reported as
the move failing:

1. **MAME's red ROM-warning screen.** Source-built ROMs always trip it and
   this build cannot switch it off, so without `tools/mame_dismiss_warning.ps1`
   the game never booted: `gs=0 p1objchar=65535` for the whole backstop.
2. **Hardcoded `.bss` addresses.** `.bss` shifts on every build that changes
   the size of anything ahead of it, and a dead `GSTATE` reads a constant 0 —
   indistinguishable from "nothing started". They are refreshed, and the
   comment says how to re-resolve them.
3. **A hardcoded `KITSPIN_SAG` window.** The sidecar's SAGs move whenever it
   is repacked; the old window (`0x03d00000..0x03d80000`) no longer contained
   them, so `sag_frames` was 0 **while the move was firing perfectly**. The
   window is now read out of `src/KITSPIN.TBL` on every run. A frame check
   that can only ever say "no" is worse than none, because it reads as the
   art being missing.

The rig now reports **NO VERDICT (exit 2)** when it never reaches a fight,
rather than FAIL — those are different answers and only one of them is about
the move.
