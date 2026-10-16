# How MK2 decides a hit — and where the model is weak

Written 2026-08-25, after building the outline overlay
([UNUSED_GRAPHICS_PRIMITIVES.md §5](UNUSED_GRAPHICS_PRIMITIVES.md)). Every
number here is either read off the source or **measured on screen with the
overlay**, and it is flagged which.

Turn it on with `f_colbox = 3` (or `15` for anchors too) and read along.

---

## The pipeline

One routine does all of it: `strike_check` in [JOY.ASM](../src/JOY.ASM). It is
called once per tick, from `attk4` in `striker`, for `a10` ticks.

```
striker:  jsrp act_mframew      <- play the windup animation
attk4:    strike_check_a0       <- a10 ticks of "did that land?"
          sleep 1
          dsj a10,attk4
```

**1. The strike box** comes from the character's strike table
([MKSTK.ASM](../src/MKSTK.ASM)), eight words per move, indexed by the `a11`
offset the move handler passes in:

```
x_offset  y_offset  x_size  y_size        <- the rectangle
strike_routine                             <- high byte = hit reaction,
                                              low byte  = block reaction
damage    (hit<<8 | block)
score
flags     (sf_squeeze, sf_duck)
```

It is placed relative to the attacker's **anipoint** (`oxpos`/`oypos`), mirrored
by `b_fliph`, and it is **one rectangle held for the whole active window** —
`a11` never changes inside the `attk4` loop.

**2. The hurt box** is not authored anywhere. It is computed, every check, as
the **bounding box of the victim's multipart sprite**:

```
calla highest_mpart      ; a0 = top
calla lowest_mpart       ; a1 = bottom
calla leftmost_mpart     ; a2 = left
calla rightmost_mpart    ; a3 = right
```

Four separate walks of the same chain, in [MKUTIL.ASM](../src/MKUTIL.ASM).

**3. The squeeze.** For any move flagged `sf_squeeze`, `sq_punch` narrows that
box horizontally before the compare.

**4. The compare** is a plain AABB overlap, four `cmpxy` branches. No
per-piece test, no circles, no priority.

---

## The multipart record — the layout everything here indexes

Written by `ani2` ([MKUTIL.ASM](../src/MKUTIL.ASM)) one record per piece,
terminated by a zero sag. Five fields, 112 bits, and every routine in this
document indexes it by hand — so here it is once:

| offset | bits | field |
|---|---|---|
| 0 | 32 | **sag** — sprite address. Zero terminates the chain. |
| 32 | 16 | **x size** |
| 48 | 16 | **y size** |
| 64 | 16 | **control word** — the image's `icontrol` with the object's flip bits merged in |
| 80 | 16 | **dx** — animation-point offset x (already flip-corrected) |
| 96 | 16 | **dy** — animation-point offset y (already flip-corrected) |

**13 pieces is the hard ceiling.** A `gmo_proc` object's shape RAM is one
process block (`pdata..prcsiz` = 1520 bits) at 112 bits a piece; the fighters'
own `p1_ram`/`p2_ram` are `32*40` = 1280 bits, so 11. The longest shape list in
the shipped game is 8. Every bounded walk here caps at **13** — it cannot
truncate a legal chain, and unlike a looser cap it cannot read past the end of
the buffer either.

A piece's world position is `object oxpos - dx`, `object oypos - dy`; its far
edges are those plus x/y size. `dx`/`dy` are **already corrected for flip** by
`ani2`, which is why none of the collision code re-mirrors them.

Note what is *not* there: **nothing marks a piece as body, weapon or effect.**
Per-piece collision therefore cannot filter props from the record alone — if
that turns out to matter, the distinction has to be authored somewhere else.
Observed so far it does not: a fighter's chain during normal play is his own
body, and thrown props (Kung Lao's hat) become separate objects rather than
multipart pieces.

---

## Measured facts

| | value | how |
|---|---|---|
| strike records | 223 (1 is `stk_dummy`) | parsed from MKSTK.ASM |
| carrying `sf_squeeze` | **205 of 223** | parsed |
| carrying `sf_duck` | 11 | parsed |
| `x_offset` | 0 … 197, median 86 | parsed |
| `x_size` | 0 … 144, median 64 | parsed |
| `y_size` | 0 … 148, median 35 | parsed |
| boxes above the anipoint (`y_offset` < 0) | 13 | parsed |
| Jax standing, full sprite width | **66 px** | overlay, green |
| Jax standing, box the compare used | **18 px** | overlay, white |
| Liu Kang mid-roundhouse, full width | **120 px** | overlay, green |

### The squeeze is to a quarter, not to 5/8

`sq_punch`'s own comment says `4/8 + 1/8 = 5/8`, and the `jade_nitro` note in
`strike_check` repeats it. Both were wrong, and the overlay is what caught it:

```asm
srl 3,a7      ; W/8
srl 2,a4      ; W/4   <- srl 2 is a divide by FOUR, not two
add a7,a4     ; 3W/8  = the inset taken off EACH side
```

`W - 2*(3W/8)` leaves **a quarter of the width**. Jax: `66 - 2*(8+16) = 18`,
which is exactly what the white box measures. The comments are corrected in
the source now.

This is not an exception applied to a few grabs. **205 of 223 records set the
flag**, so a quarter-width hit column is how the game normally works.

---

## Where the model is weak

Ranked by how much it actually costs, with what it would take to change it.

### 1. The hit column is centred on the bounding box, so it moves with the victim's own animation — **FIXED 2026-08-26**

This is the real defect, and the codebase already knows about it. Inside
`strike_check` there is a hand-written exception:

> *Jade's Nitro Kick punish pose is deliberately the authored, extended
> KTLOKICK1 frame. Its multipart width includes the forward leg, and the normal
> quarter-width squeeze can shift the victim box away from her torso so an
> uppercut visibly passes through.*

That is a per-move patch for a systemic problem. The centre of
`leftmost_mpart … rightmost_mpart` is the centre of the **silhouette**, limbs
included. Liu Kang measures 66 px standing and 120 px mid-roundhouse — so
extending a leg walks the centre of his hit column roughly **27 px** toward
that leg, off a torso that is only about 40 px wide. Anyone caught in a wide
pose has a hit column sitting partly in empty air.

**Fix:** centre the column on `oxpos` — the anipoint — instead of on the
bounding box. The anipoint is the character's root and does not move when a
limb extends. Two instructions in `sq_punch`, replacing
`add a4,a2` / `sub a4,a3` with a span around `*a8(oxpos)`.

**Done.** `sq_punch` now spans `oxpos ± W/8` instead of insetting the bounding
box by `3W/8` a side. Same quarter width, stable centre.

This **is** a balance change, and the fingerprint proves it: the same battle
runs identically to the old build until rel=330 and then diverges. Damage in a
driven-attack test went from the old model's behaviour to **43 HP** over 480
frames with load unchanged.

The `jade_nitro` exception in `strike_check` is now redundant — it exists
purely to work around the drift this removes — but it is **left in place**,
because deleting it is a second balance change and should be its own decision.

### 2. One rectangle for the whole active window — **MECHANISM BUILT 2026-08-26** (`stkphase`, default 0)

`a11` is constant inside `attk4`, so a move's hitbox does not change across its
active frames. A roundhouse has the same box at the start of the arc as at the
end, and the hurt box it is tested against is whatever the *animation* happens
to be showing — which does change. That mismatch is why so many boxes are
generously sized: they have to cover the whole swing.

**Built, behind `stkphase` in [MAINEQU.ASM](../src/MAINEQU.ASM), default 0.**

A move may name a phase list keyed on `striker`'s countdown `a10` — the value
it already has — so **no new process RAM and no state across a sleep**:

```
    .word  threshold, move_index    use while a10 >= threshold
    ...
    .word  0, move_index            final phase, always matches
```

`get_stk_phases` / `pick_stk_phase` live in [MKSTK.ASM](../src/MKSTK.ASM).
Moves with no phase list behave exactly as before, so it is inert until data is
authored: at `stkphase 0` the build is **byte-for-byte the same size**, and the
whole mechanism plus tables plus one demo record costs **256 bytes** at 1.

**Verified:** sweep PASS, `overload` = 2 on 481/481 frames, no lost ticks. Liu
Kang's low kick is the worked example (`a10` = 6, split 6..4 / 3..1), and with
`stkphase 1` the engine tests with a **reach of 56** where stock tests with
**104** — same move, same range, read straight out of the overlay's `bx_list`.

**The transition is demonstrated.** `phase_pick` counts the decision by
ordinal at the point it is made — `entry0=12 entry1=12` over four kicks, which
is not merely "two phases ran" but the *exact* 3-and-3 split per kick that the
table specifies (`a10` 6,5,4 → early; 3,2,1 → late). Zero damage in that run,
by design, and `overload` 2 on 481/481.

**Two things had to be right before that measurement meant anything:**

- **Do not let the attack connect.** At 90px the kick landed on its first
  active tick, `striker` took `attack_hit`, and the loop exited after ONE
  phase pick. That reads exactly like a broken mechanism. Standing off at
  170px — with the drone pinned so it cannot close — lets the window run all
  six ticks, and both phases have to be exercised.
- **Count the decision, not the drawing.** Inferring phases from the overlay's
  `bx_list` could not settle it: `box_add` rotates through eight slots and
  parks *two* boxes per strike check, so a reader scanning for "a fresh strike
  box" keeps finding whichever slot comes first by index rather than the
  newest. Every sample came back as the early phase.

The instrumentation that settled it (`phase_calls`, `phase_hits`, `phase_char`,
`phase_idx`, `phase_pick`) is write-only, exists only under `stkphase`, and is
worth keeping: `calls=7` in a whole fight was what revealed the test was barely
attacking at all, which no amount of staring at the assembly would have.

### Four ways this went wrong first, all worth knowing

1. **`a7` is not a general register across a `sleep`.** `prcslp` does
   `move *sp+,a7,l` — it loads the WAKEUP PC into a7 and saves that. Caching
   the phase list there had `pick_stk_phase` walking executable code.
   The fix removed the state entirely: re-look up each tick, a few compares.
2. **`jrz` straight after a `calla` tests the callee's `mmfm`/`rets`, not the
   return value.** Add `move a0,a0` first. Taking the phase path with a null
   list walked address zero.
3. **`callr` cannot cross objects.** `pick_stk_phase` is in MKSTK.OBJ and
   `striker` is in JOY.OBJ; the PC-relative call branched into nowhere.
   CLAUDE.md warns about this and it still got written.
4. **The index comments in the strike lists are HEXADECIMAL.** `; 16` is 0x16
   = 22 decimal, so an appended record is 0x17 = 23, not 17. Decimal 17 is
   `stk_lkzap2` — and the overlay caught it instantly, because the rectangle
   it drew was 100 wide when both low-kick records are 67.

Three of those four produced `CRASH_lockup` on the sweep and none of them
would have been obvious from reading the diff.

A fifth cost a build cycle without crashing anything: **a `.word` followed by a
`.long` gets padded**, because GSPA aligns the `.long` to 32 bits. Offset
arithmetic that assumes 16+32 then walks onto the padding, reads it as a
pointer, gets zero, and reports "no phases" — silently and forever. The phase
table is all-`.long` for that reason. If a table mixes widths, either pad it
yourself or do not compute offsets by hand.

### 3. Four chain walks where one would do — **DONE 2026-08-26**

Every single strike check walks the victim's multipart list four times to get
four numbers that one pass produces. `box_bounds` in
[MKDISP.ASM](../src/MKDISP.ASM) is that one pass — it exists now and is proven,
because the overlay needed it anyway.

**Done.** `mpart_bounds` in [MKUTIL.ASM](../src/MKUTIL.ASM) returns the same
four numbers in one pass and `strike_check` now calls it. It is deliberately
bit-identical to the originals, including their **asymmetric sentinels** —
top/left start `0ffffh`, bottom starts `0` (not a negative sentinel), right
starts `-5000`. Those must not be "tidied".

The four originals are left alone: they have **28 callers tree-wide** (MKZAP,
MKFX, MKDRONE, MKDEATH…), and only `strike_check` wanted all four.

Verified: `overload` = 2 on 481/481 fight frames before and after (2 = the pass
finished inside its tick), `qdma_drops` = 0, and a determinism fingerprint of
both fighters' positions and HP every 30 frames is **identical**. The load
meter cannot show the saving because it was already at its floor — the gain is
headroom, not a visible delta.

### 4. The chain walks are unbounded — **DONE 2026-08-26** (in the new routine)

`highest_mpart` and its three siblings loop until the sag word reads zero, with
no iteration cap and no sanity check on the pointer. A multipart chain caught
mid-rebuild does not glitch — it **hangs the machine**. That has not been
observed in play, but it is the kind of thing that shows up once, on hardware,
in an arcade.

**Done for the strike path**: `mpart_bounds` carries an `MPB_MAX` cap set far
beyond any real chain, so behaviour is unchanged but a corrupt list can no
longer wedge the cabinet. The four originals still have no cap — they are
untouched because of those 28 callers, so this remains open for them.

### 5. No vertical squeeze, and nothing distinguishes body parts

The hurt box is full-height: top of the tallest piece (Kung Lao's hat, hair) to
the bottom of the lowest. There is no head/torso/legs distinction anywhere, so
no move can be authored to hit high but not low, except by its own `y_offset`
and `y_size` against a victim whose height only changes when he crouches or
jumps.

**Fix:** genuinely large — it needs authored hurt boxes per character state,
which the leak has no data for. Worth knowing about; not worth starting without
a specific move that needs it.

### 6. Nothing checks that a box is live on the frame it was drawn for — **AUDITED 2026-08-26**

Every weakness above is about the *shape* of the compare. This one is about
*when* it happens, and it is the one that produced a report from actually
playing the game: *"the hitboxes completely miss — the blade completely hits
the ninja's face."*

`striker` / `striker_2` (JOY.ASM) play **part one of the animation first** and
only then hold its final pose for `a10` ticks of `strike_check`. So the contact
pose is the last frame of part one — the `ani_nosleep / <pose> / 0` idiom every
move uses to park its final frame. Nothing verifies that the strike record was
authored against *that* frame.

Baraka's blade swipe was not. Measured live, tick by tick, with
`tools/sweep_addon_swipe.lua`:

| tick | frame | sprite (relative to the anipoint) | box `+34..+104` |
|---|---|---|---|
| 11–13 | UGSWIPE1 | −79..+44 | — |
| 14–16 | UGSWIPE2 | −70..+29 | — |
| 17–19 | UGSWIPE3 | **−54..+106** — blade fully out | no box live |
| 20+ | UGSWIPE4 | −45..+29 — blade already back | **NO OVERLAP** |

`stk_swipe` is `x_offset 068h` / `x_size 046h` = `oxpos+34..+104`, which matches
UGSWIPE3's 76×23 blade strip (`+30..+106`) almost exactly. The record was
authored for the frame *before* the one the window runs on, so the blade swept
through the opponent's face with nothing behind it and the hit registered three
ticks later with the arms down, the box floating 5 to 75 px in front of a
retracted sprite.

**This is retail.** The lane and the record are byte-identical to `mk2-src.zip`
— a 1993 authoring slip, not something introduced here.

**Fixed** in `src/MKSA.ASM` by listing UGSWIPE3 twice: once as a normal 3-tick
frame, then again behind `ani_nosleep` as the pose that is held. Part one stays
9 ticks and the window stays 4, so startup, active frames, recovery, reach and
damage are untouched — the range map connects **20..108 px before and after**.
UGSWIPE4 is dropped rather than moved into part two, because part two runs at
4 ticks a frame and adding a frame there would have lengthened recovery.

**`tools/box_align_audit.py`** now checks this for every move whose handler
names both an animation index and a strike index, and writes
[BOX_ALIGNMENT.md](BOX_ALIGNMENT.md). Across 76 resolved moves a box reaches a
median of **+3 px** past its own art; the swipe was **+75 px with zero
overlap**, and it was the only `ochar table` row in that state. Read that
report's own warning before believing a row: handlers not dispatched through an
`ochar_*` table are applied to all seventeen characters, and a character who
cannot reach the handler produces an alarming row that means nothing — a
resolved pose named `*STANCE*` or `*DIE*` is the giveaway. The tool also
resolves each lane's frames from its **own file first**: `JCSPLIT5` is defined
in both MKJC.ASM and MKDEATH.ASM, and taking the wrong one invented a finding
against Cage's split punch that does not exist.

---

## Per-piece collision — built, behind `perpiece` (MAINEQU.ASM)

`perpiece .set 1` swaps the whole model: instead of collapsing the victim to
one box and narrowing it, `piece_overlap` ([JOY.ASM](../src/JOY.ASM)) walks his
multipart pieces and stops on the first the strike box actually overlaps.
Per-frame, limb-accurate hurt boxes, no authored data, no ROM cost, and no
squeeze at all. The compare senses are copied exactly from the single-box test
so a piece and the old whole-body box are judged by identical rules.

**It is cost-neutral**, which was not obvious before `mpart_bounds` landed. The
old model was four chain walks plus one compare; per-piece is one walk with a
compare per piece and an early-out. Measured with attacks actually running:

| | damage dealt | `overload` = 2 | lost ticks | `qdma_drops` |
|---|---|---|---|---|
| anchored column (`perpiece 0`) | 43 | 481/481 | 0 | 0 |
| per-piece (`perpiece 1`) | 35 | 481/481 | 0 | 0 |

Per-piece lands less, which is the expected direction: limb-accurate boxes are
tighter than a full-height column, so grazes that used to connect now miss.

**Stable across the roster:** 20/20 on the battle sweep with `perpiece 1`,
bosses included — Kahn and Kintaro have the longest multipart chains in the
game and `piece_overlap` walks every piece of them.

**Two concerns I raised earlier turned out not to hold**, and the correction
matters more than the original claim:

- *Piece filtering.* There is nothing in the multipart record to filter **on** —
  the five fields are sag, sizes, control word, dx, dy, and none marks a piece
  as body or prop. It also does not appear to matter: a fighter's chain during
  normal play is his own body, and thrown props (Kung Lao's hat) become
  separate **objects**, not multipart pieces.
- *A per-piece inset.* The worry was that piece rectangles include transparent
  margin, so the boxes would run generous. The measurement says the opposite:
  per-piece dealt **35** damage where the column dealt **43**. It lands fewer
  hits, not more.

So the only real blocker is **balance** — that 43 → 35 shift, and the AI punish
tables tuned against the current reach. Not correctness, and not performance.

**Measure with attacks.** A run where nothing connects reports "overload = 2 on
every frame" while barely executing `strike_check` at all — the load claim
looks strong and means nothing. `tools/sweep_addon_perf.lua.off` snaps P1 into
range and throws punches for exactly this reason.

---

## The per-piece layer is built — go and look first

`f_colbox` bit 4 (value 16) draws **every multipart piece separately**, in
yellow. Turn it on together with bit 1 (`f_colbox=18`) and the green box is the
model the game uses while the yellow boxes are the one it could have for free:
head, torso, arms and legs as separate rectangles, tracking the animation.

That is the cheapest possible evaluation of the change above — no collision
code, no balance risk, just look at whether the boxes are sane.

**It costs frame time.** Bit 4 draws up to 16 rectangles per fighter instead of
one and takes `peak_overload` from 4 to 35, which is enough to drop ticks and
change how a fight plays out (`kang_jax_deadpool`: 3/3 PASS at mask 3, 0/3 at
mask 18). That is fine for looking and useless for measuring. It also says
something about the real change: **testing 16 boxes cannot be free either**, so
a per-piece `strike_check` wants the walk to bail on the first overlap and
probably wants the piece count kept small.

## What to do first

If you want the model to behave better and are willing to re-tune, **#1** is
the change with the most effect per line, and the Jade exception is a ready-made
before/after test case.

If you want a strictly-better build with no balance risk, do **#3 and #4** —
one is faster, the other removes a hang, and neither changes a single frame of
gameplay.

Either way, run [tools/hitbox_overlay_test.lua](../tools/hitbox_overlay_test.lua)
and the battle stability sweep afterwards, and look at the boxes with
`f_colbox=7` before and after. The whole point of building the overlay was that
this stops being a matter of opinion.
