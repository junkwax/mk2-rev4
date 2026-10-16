# MK2 frame data and box spec

Status: **DRAFT**. Companion to [FGC_INPUT_SPEC.md](FGC_INPUT_SPEC.md).

Everything from "the game agreed you pressed the button" onward: boxes, frame
data, collision, and the numbers that come out the other side.

Every item is one of:

* **RESOLVED** - the build already answers this, and the answer is given.
* **BUILT** - the mechanism exists, usually behind a switch that is off.
* **OPEN** - a real decision.

The model is documented in [HITBOX_MODEL.md](HITBOX_MODEL.md), which is also
the running log of what has already been changed. Numbers below are measured
off the live `f_colbox` overlay or parsed from source, never estimated.

---

## 0. Principles

1. **Boxes are data where they are boxes at all.** The attacker's strike box is
   authored and editable. The defender's volume is derived from sprite bounds
   at runtime. Read section 2 before proposing anything.
2. **Publish everything.** Frame data that is not visible to players is not
   balance, it is trivia.
3. **Disjoints are a decision, not an accident.**
4. **Capture the original before changing it.** Already done -
   `boxlab/data/retail/boxes.json` is the retail reference, and
   `doc/balance.lock` / `doc/hurtbox.lock` freeze the current state.

---

## 1. Coordinate space - RESOLVED

| Item | Value |
|---|---|
| Origin | The **anipoint**, per object. Boxes are authored relative to it |
| X | `x_offset` is the box's **front edge**; `x_size` extends *backwards* from it, toward the attacker |
| Y | **Positive is down.** 13 of 233 records sit above the anipoint (negative `y_offset`) |
| Units | **Whole pixels, 16-bit signed.** No sub-pixel, no fixed point, no floats |

There is no conversion step and no import assertion to write - the game, the
tables and the exported packs are all in the same units already.

---

## 2. The collision model as it actually is

**Read this before proposing any change.** The build does not test authored box
against authored box.

* The **attacker** contributes one *authored* rectangle - the strike box. Real
  data in [src/MKSTK.ASM](../src/MKSTK.ASM), directly editable.
* The **defender** contributes a *derived* volume: the bounding box of its
  sprite pieces for the current frame, narrowed to **a quarter of its width**.
  Nobody authored this; it is computed at runtime from art.

The squeeze is not an exception applied to a few grabs. **205 of 223 records
set `sf_squeeze`**, so a quarter-width hit column is how the game normally
works.

It is a quarter, not the 5/8 the source's own comment claimed. The overlay
caught it:

```asm
srl 3,a7      ; W/8
srl 2,a4      ; W/4   <- srl 2 is a divide by FOUR, not two
add a7,a4     ; 3W/8  = the inset taken off EACH side
```

`W - 2*(3W/8)` leaves a quarter. Jax standing: full sprite width **66 px**,
box the compare used **18 px**. The comments in the source are corrected.

### 2.1 Box types - RESOLVED

| Type | Reality |
|---|---|
| `hit` | **Authored.** MKSTK.ASM, 233 records |
| `hurt` | **Derived.** Sprite-piece bounding box, quarter-width squeeze |
| `push` | **Neither - a scalar.** `repell_distance .set 040h` (MAINEQU.ASM): 64 px of anipoint separation, enforced by a process (`pid_repell`). One number for the entire cast |
| `throw` | **A scalar distance test.** `distance_from_ground` against a per-move constant (commonly `060h`). Not a box |
| `throw_hurt` | **Does not exist.** A throw is a distance test plus state gates; there is no volume to be thrown by |
| `proj` | **Authored**, in the same table as `hit` |
| `block` | **Does not exist.** MK2 is a block-button game |

Two consequences the draft did not anticipate:

* **`push` being one global scalar** means this doc's entire pushbox and corner
  surface (sections 7 and 11) is currently one constant in one file. That is
  either a gift or a warning depending on how much per-character spacing work
  is wanted.
* **New grabs already break the "throws are scalar" rule.** Shao Kahn's grab
  and Ermac's telekinetic slam use real authored strike boxes
  (`erm_tks_reach` = 206 px, live for `erm_tks_active` = 16 ticks). So the
  machinery for a boxed throw exists and is shipping; it is the *retail* throws
  that are scalar.

### 2.2 What the derived volume costs

Three consequences that decide real matches:

1. **Reach is not range.** A record's `x_offset` is where the box *ends*, not
   where the move lands. Liu Kang's high kick has a front edge of 94 px and
   still connects at 109, because the victim has width. Widening a box by 20 px
   does not buy 20 px of range.
2. **There is a dead zone at point blank.** That same kick connects from 24 px
   out. Closer than that and it passes straight through - the box starts in
   front of the attacker.
3. **Idle animations breathe.** A stance swings several pixels wide across its
   frames, which moves the tested column, and at the edge of a move's range
   that is the hit.

The draft's fourth consequence - *"attacking widens your own hurt column and
shifts it toward the extended limb"* - **was true and is fixed.** The column
anchors on `oxpos`, not the bounding-box centre, as of 2026-08-26. See
HITBOX_MODEL.md item 1.

---

## 3. Hurtbox strategy

The draft offered two routes an order of magnitude apart. There are three, and
the middle one is already built.

### 3.1 Route A - tune the derived model

Keep the derived quarter-width column; change its parameters and let the
attacker's authored rect do the balance work.

| Lever | Where | Status |
|---|---|---|
| **Narrowing factor** | `sq_punch`, two `srl` instructions | Single constant. Quarter to third or half widens every hittable volume at once |
| **Per-state factor** | standing / crouching / airborne | Small change, large surface. Airborne especially |
| **Column anchoring** | on `oxpos` | **Already done** |
| **Column width** | `colwidth`, MAINEQU.ASM | **ON.** See below - anchoring shipped with an unintended narrowing, now corrected |
| **Vertical clipping** | per state | **Measured and rejected** - see below. It buys crouch invulnerability, not a high/low axis |
| **Attacker rect** | MKSTK.ASM | Fully editable today, and where most tuning should happen |

Measured with `tools/box_model_lab.py`, which runs the models against each
other statically - the same comparison `sq_punch` and `piece_overlap` do, with
distance solved for rather than swept, so the whole cast at every distance
takes a second instead of a MAME session. `selfcheck` asserts the fast path
against the brute-force one it replaced.

```
python tools/box_model_lab.py all
python tools/box_model_lab.py flips --models build narrow:3
```

How much each Route A lever actually moves, as a share of all hit/miss
verdicts over every move, every defender, both lanes, 0-260 px:

| change | verdicts changed |
|---|---|
| widen the column to a third | **1.70%** |
| widen it to a half | **4.94%** |
| per-piece (Route A-and-a-half) | **13.66%** - but see 3.2 |

So the narrowing factor is a fine-tuning lever and per-piece is a different
game. Read 3.2 before reading anything into that 13.66%: almost all of it is
per-piece behaving as "no squeeze", not as limb precision. Note also that `narrow:4` and the shipping model agree on 100% of
verdicts, which is the check that the tool's arithmetic is the source's.

#### Vertical clipping buys invulnerability, not a high/low axis

The last untried Route A lever, and it does not work. Section 4.1 showed the
ART gives no vertical room; clipping is the other way at it - shorten the
DERIVED column from the top while crouching, and the room exists whether the
sprite provides it or not.

`python tools/box_model_lab.py clip` sweeps how much:

| clip | moves with a high/low window | median window | **moves fully immune** |
|---|---|---|---|
| 0 (shipping) | 119 / 199 | 3 px | 2 |
| 12 | 119 / 199 | 3 px | **25** |
| 24 | 119 / 199 | 3 px | **63** |
| 32 | 119 / 199 | 7 px | **92** |

Re-measured after `colnarrow` widened the shipping column to a half: the
first and last columns are byte-identical, and the median window moved 2px to
3px. The conclusion does not depend on the column width, which is itself the
point - the axis is decided horizontally.

**The first column never moves.** Clipping adds no move to the set that can
whiff over a crouch - the same 119 have it at every level, because whether a
move has that property is decided horizontally (2.2), not vertically.

What grows is the last column: the number of moves that cannot reach a
crouching opponent **at any distance**. At a clip of 32 that is 92 of 199. A
crouch nothing can touch is not a high/low axis, it is invulnerability, and it
arrives long before the window becomes wide enough to read as a mixup.

So Route A has no vertical lever. The horizontal ones - `colnarrow`,
`colwidth`, the attacker's own rect - are the whole of it.

#### The anchoring fix also narrowed every column, and was not meant to

`sq_punch`'s own comment for the anchored branch says it keeps "the same W/4
width" as retail. It does not, and the reason is truncation: retail insets by
`(W>>3) + (W>>2)` a side with each shift rounding down separately, so what
survives is `W - 2*((W>>3)+(W>>2))`, while the anchored branch uses `2*(W>>3)`.

Measured over every pose in the build:

| | |
|---|---|
| poses given a **narrower** column than retail | **757 of 869 (87%)** |
| poses given a wider one | **0** |
| mean loss | **2.52 px**, up to 5 |
| hit/miss verdicts the correction would change | **3.16%** |

So the change that was made to stop the column wandering also made the whole
cast slightly harder to hit - the opposite of its purpose, and a quiet push in
exactly the direction of the complaint this project exists to answer.

`colwidth` (MAINEQU.ASM) is the corrected arithmetic: retail's exact surviving
width, centred on the anipoint. **ON since 2026-09-03** - stability sweep
**25/25**, behaviour lock **10/10**. Every fighter is now 1-5 px easier to hit
than the build that shipped the anchoring, which is what was always intended.

`colwidth 0` restores the narrowed column exactly.

### 3.2 Route A-and-a-half - derived PER-PIECE - MEASURED AND CLOSED

**`f_colbox` bit 4 already draws every multipart piece separately.** Head,
torso, arms and legs as individual rectangles, tracking the animation, with no
authoring at all - the sprite's own multipart decomposition supplies them. A
per-piece `strike_check` is built behind `perpiece` in MAINEQU.ASM.

For a long time this section called it the cheap way to get most of Route B.
**It is not, and the number that looked like the argument for it was the
argument against it.**

#### It is 99% "remove the squeeze"

| comparison | verdicts differing |
|---|---|
| per-piece vs **no-squeeze** (whole silhouette as one box) | **1.02%** |
| per-piece vs the shipping model | 13.66% |

So of everything per-piece changes, **98% of it is simply widening the target
from a quarter-width column to the full silhouette**. The limb precision - the
thing it was wanted for - is the remaining **1%**.

The 13.66% figure is real and was quoted here for weeks as the reason
per-piece was the biggest lever available. It is the biggest, and almost none
of it is the effect anybody wanted.

#### What it would do in play

| move | shipping | per-piece |
|---|---|---|
| `headband/hikick` | 18..101 | **0..133** |
| `swordarms/roundh` | 21..103 | **0..135** |
| `bigarms/hipunch` | 33..95 | **12..127** |

Measured across the cast: **1,487,589 distances gained against 11,173 lost**, a
ratio of 133 to 1. Every move reaches roughly 32 px further, and the
**point-blank dead zone disappears** - 18 px becomes 0.

That dead zone is not an accident, it is one of the three consequences section
2.2 names: standing on top of someone makes your move whiff. Per-piece deletes
it for the whole cast.

Shipping this would mean shrinking all 233 strike records by about 32 px to
compensate, and the dead zone would still be gone. That is a redesign, not a
re-tune, and what it buys is the 1%.

#### Verdict

**`perpiece` stays 0, and is no longer "the big remaining lever".** Reopen it
only with the 1% in mind, and reproduce the comparison first:

```
python tools/box_model_lab.py flips --models nosqueeze perpiece
```

If limbs genuinely need to matter, Route B below is the honest route, and 1%
is the true size of the prize rather than 13.66%.

### 3.3 Route B - authored per-frame hurtboxes - OPEN, probably unnecessary

A new data layer keyed by `(animation, frame)` for every frame of every
character, plus a new collision path, plus the authoring effort across the full
sprite set.

Section 3.2 no longer stands in front of this. Per-piece turned out to be
"remove the squeeze" wearing limb precision as a 1% garnish, so it is not a
cheap way to get most of Route B - it is a different change that happens to be
built.

What Route B offers over the shipping model is genuine per-frame limb
accuracy, and 3.2 is the honest measurement of how much that is worth on this
game's art: **about 1% of hit/miss verdicts**. That is the number to weigh the
authoring effort against.

And section 4.1 has now taken away most of the reason to want them. The thing
labels were wanted for was a high/low axis, and that is blocked by the crouch
animations rather than by the collision model: there is no vertical room for an
overhead to live in, whether the boxes are labelled, derived, or authored one
per frame by hand. Route B would buy per-part *rules* - a head that takes more
damage, a limb that can be struck while invulnerable elsewhere - which are new
mechanics, not a fix to an existing complaint.

### 3.4 Invulnerability - OPEN

Expressible in every route by suppressing the volume. Typed flags
(strike / throw / projectile / full) are only needed for throw-invuln-only
wakeup, which is section 8's decision to make first.

### 3.5 What is still genuinely missing

**No vertical squeeze, and nothing distinguishes body parts** in the shipping
path. The hurt box is full height, top of the tallest piece to the bottom of
the lowest.

The squeeze is horizontal only, and that is the shape of the whole game: MK2's
high/low distinction is about *reach*, not *height*. 119 of 199 moves do have a
"connects standing, misses crouching" window, and every one of those windows is
horizontal - the crouch is shorter in reach, not lower. The vertical axis is
not weakly supported here, it is **absent**, and section 4.1 measures why.

#### Anchoring halved the window, and that is probably honest

`python tools/box_model_lab.py highlow` puts the mean window at **8 px under
retail and 4 px under the shipping model**. The same 119 moves have the
property under both, so nothing gained or lost the axis - the windows are
simply tighter.

It is not the width that did it. A quarter-width column measured out from the
anchor (`narrow:4`) also reports 4 px, so `colnarrow` is not responsible
either; what changed is *where the column is centred*. Retail centres it on
the silhouette, which travels with the limbs, so a stance that breathes moves
the column frame to frame and opens windows that are an artefact of the
animation rather than of the move. The `ranges` report shows the same thing
from the other side: flicker across a stance lane drops from 9 px under retail
to 2-4 px under the anchored column.

So the smaller number is a more *stable* crouch, not a worse one, and it is a
consequence of the anchoring fix rather than of anything chosen for balance.
Recorded because "the high/low game is half what retail had" is a true
sentence that would be easy to reach for as evidence of a regression.

---

## 4. Hitbox model and attack attributes

Per record, the eight authored fields:

| Field | Notes |
|---|---|
| `x_offset` | front edge. 0-197, median 86 |
| `y_offset` | 13 records negative (above the anipoint) |
| `x_size` | extends backwards. 0-144, median 64 |
| `y_size` | 0-148, median 35 |
| `strike_routine` | **packed word: high byte = hit reaction, low byte = block reaction** |
| `damage` | packed: high byte = damage on hit, low byte = chip on block |
| `score` | added to the attacker on hit |
| `sound` | **actually the FLAGS word.** `sf_squeeze` and `sf_duck` live here |

That last row matters and is easy to get wrong: `hitbox_edit` calls the eighth
field `sound`, but `balance.lock`'s own header calls it the flags. The boxlab
exporter recovers it as a neutral `flags` map so the public data can still say
which moves squeeze.

**`guard` (high / mid / low / overhead) does not exist.** MK2 blocks everything
the same way.

### 4.1 A true overhead is not reachable by any box change - measured

This has been relitigated three times, so here is the number that settles it.

An overhead needs a strike box whose bottom edge clears the top of a crouching
silhouette while its top edge is still below the top of a standing one. That
gap is the whole budget, and it is tiny (+y is down, so a bigger number is
lower):

| defender | stance top | crouch top | band |
|---|---|---|---|
| bolt | 9 | 31 | 22 |
| hathead | 15 | 31 | 16 |
| bombshell / knockout / pole | 12 | 27 | 15 |
| bigarms, headband | 11 | 24 | 13 |
| swordarms | 17 | 28 | 11 |
| the ninjas | 6 | 15 | 9 |
| shades | 17 | 24 | 7 |
| morphman | 12 | 16 | 4 |
| final-boss | 14 | 15 | **1** |
| fourarms | 11 | -24 | **-35** |

**Median band: 9 px.** The shortest strike box in the game is 27 px tall at the
first quartile and the *minimum* is above the band; **0 of 199 records are 9 px
or under**, median 34. And Kintaro's band is *negative* - his crouch reaches
higher than his stance, so nothing can ever be an overhead against him.

Independently: **0 of 199 strike boxes end above even the highest crouch.** Not
one. MK2's crouch removes about 9 px from the top of a roughly 130 px sprite;
it is a narrowing animation, not a ducking one.

So an overhead needs new art - not because authoring boxes is hard, but because
**there is no vertical room to author into.** That is a property of the crouch
animations, and the only fix is a lower crouch, which is a sprite.

`hitstop`, `hitstun`, `blockstun`, `pushback`, `knockdown`, `juggle_cost`,
`cancellable`, `whiff_recovery` are **not authored per move** today. They come
out of the reaction routine the `strike_routine` word selects. Making any of
them per-move is a new field, not a retune.

---

## 5. Frame data schema - RESOLVED, and it already exists

[FRAME_DATA.md](FRAME_DATA.md) is generated from source: 366 records and 29
handlers. [FRAME_ADVANTAGE.md](FRAME_ADVANTAGE.md) and
`doc/frame_advantage.csv` carry advantage. Both publish through
`boxlab/data/frames.json`, 177 moves.

Conventions as they stand:

* **One tick is 18.28 ms.** An animation's speed is its `sleep` value, so
  effective fps is `54.7 / sleep`. Sleep 3-4 is 58% of all `mframew` sites.
* **MK2 changes rate within a move.** It does not run a long lane at one speed.
  `do_wheel_kick` is 4 then 3; `do_kintaro_fatal` is 3 then 10. A single
  "startup / active / recovery" triple is a summary, not the data.
* **Startup is absent for some moves on purpose.** Where a handler could not be
  resolved the row is omitted rather than estimated. A missing row costs
  nothing; a wrong one costs a match.

**Frame timing is read-only to the community.** It lives in code immediates,
not a table, so it publishes but cannot be proposed against. Wrapping
`frame_edit.py` the way `hitbox_pack.py` wraps the strike records is the next
pack after inputs.

---

## 6. Collision resolution

**Order - RESOLVED.** One chain walk per pair, not four (reworked 2026-08-26).
The walk is bounded and index-based; there is nothing non-deterministic in it.

**Trades - RESOLVED, and the answer is uncomfortable.** Both connect, but the
evaluation is **not order-independent**: player two wins simultaneous
exchanges. Measured, mirror-matched, both sides, and **identical on retail** -
so it is the original's behaviour, not something we introduced. Throws are the
extreme case: P2 wins them 88-0, side-swap controlled.

### 6.1 Why P2 wins, exactly

Not a mystery and not ours. `getprc` links a new process **after its creator**,
and `setup_players` (MKGUYS.ASM) makes P1 first, then P2 - so the active list
ends up `[creator, P2, P1]` and **P2's `strike_check` runs first every tick**.
Whoever resolves first calls `react_xfer_him` and transfers the other into a
reaction, so the loser's `strike_check` never runs at all. That is also why
nothing in this game ever trades.

### 6.2 `firstactive` is built, and it is OFF because it is WRONG

A fix exists - "the attack whose active window opened first wins, ties split by
tick parity so neither slot owns them". It was turned on, and beta playtest
found it on 2026-09-01. **Do not simply flip it.** Three faults, any one of
which is disqualifying:

1. **It is not the rule it claims.** The test asks whether the opponent's
   *current* `p_action` is the one carrying his stamp. `p_action` holds an
   attack for startup, active **and recovery**, and is not cleared until
   `back_to_normal` - so what it implements is *"whoever attacked first cannot
   be hit by the other for the entire duration of his move"*. **Whiff punishing
   is silently deleted.** That is the report: uppercuts and kicks passing
   through at point-blank range, connecting only when the opponent happened not
   to be mid-move.
2. **Two writers, two reference points.** `fa_stamp` stamps at move *start*,
   before startup; `strike_check`'s own stamper stamps when the *active window*
   opens. A move dispatched through `striker` therefore always carries an
   earlier number and wins on that alone - which is why the drone's anti-air
   uppercut beat everything.
3. **Repeats never re-stamp.** Both writers bail when the action matches
   `fa_act`, so the second and every later use of a move keeps the tick from
   the *first* one. A stamp that only gets older for the rest of the round.

And it gates throws (`toss_yes`), so the same faults drop those.

**The trap for whoever fixes this.** The obvious repair - stamp when the active
window opens, so the rule matches its name - **has already been tried and
measured failing**, and `fa_stamp`'s own comment records why: P2's process runs
first, so when his check looks at P1 for a same-tick exchange, P1 has not run
yet and has never stamped. The tie is invisible and P2 wins exactly as before,
still 8-0. Stamping at move start is what makes both fighters stamped by the
time any check runs.

So fault 1 and fault 2 pull in opposite directions: the tick has to come from
move *start* (for ordering) while the "is he still live" gate has to come from
the *active window* (for whiff punishing).

### 6.3 Why the obvious repair does not work either - investigated 2026-09-03

The plan above was to add a per-fighter "strike-checked recently" marker,
written every active tick and read with one tick of slack, so that liveness
comes from the active window while the tick still comes from move start.
**That does not work, and the reason is worth writing down so nobody spends
another day on it.**

The liveness marker has the same ordering problem the stamp had. P2's process
resolves first. For the case that is actually being complained about - both
fighters' active windows opening on the *same* tick, which is exactly what the
trade and throw rigs press - P1 has not run yet, so his marker is stale, P2
reads him as "not live", and P2 wins exactly as before. Any signal P1 must
*run* to update is invisible to P2 on the tick that matters.

So the requirement is sharper than it looked: **the signal has to be one the
opponent does not have to execute code to produce.** The candidates were
checked and none survives:

| candidate | why not |
|---|---|
| a stamp at active-window open | the case in question is the first tick of that window - not yet written |
| `p_action` | what fault 1 is: covers startup, active *and* recovery, so it deletes whiff punishing |
| an "age of current action" field | **does not exist.** No `pdata` slot tracks it; `p_anicount` is an intra-frame countdown |
| `p_stk` (the armed strike record) | 30 writers, and it is a table offset, not "my box is live now" |
| `fa_stamp` coverage for everything | 5 stamp sites against **46** `strike_check` call sites across 6 files |

**The conclusion is structural.** Without deferring resolution, the first
runner must decide with incomplete information, and the second runner never
gets to act at all - `react_xfer_him` has already moved it into a reaction
before its own move code runs. No arrangement of stamps fixes that, because
the missing thing is not a stamp.

### 6.4 What would actually work, in cost order

1. **Deferred hit resolution.** The first runner records a pending hit instead
   of transferring the victim; a pass after the process walk applies them all.
   Both fighters' checks run before anything resolves, so a true trade falls
   out and the result is order-independent by construction. This is the
   correct fix and it is an engine change, not a rule change - `react_xfer_him`
   moves a lot of state.
2. **Alternate the dispatch order per round.** `setup_players` runs inside
   `play_1_round` (MAIN.ASM), so the order is chosen fresh every round, and
   `p1_matchw + p2_matchw` is a ready-made alternator. Contained, deterministic,
   netplay-safe. **It cancels the bias over a match rather than removing it** -
   within a round it is still 100/0, just not always the same slot.
   *Caveat:* creation order also drives object insertion, so a naive swap moves
   who draws in front. Only the two `getprc` calls may be reordered, not the
   whole block.
3. **Anything stamp-based.** Ruled out above.

Verification is already built and needs nothing: `sweep_addon_merit.lua` asks
whether the faster move wins, `sweep_addon_trade.lua` and
`sweep_addon_throw.lua` are what measured 8-0 and 88-0, and
`sweep_addon_procorder.lua` reports which process runs first. Any fix is
falsifiable the day it is written.

**`firstactive` stays 0**, and the switch should probably be retired rather
than repaired - what it implements is not what its name says, and 6.4 describes a
different mechanism entirely.

### 6.5 Deferred resolution was BUILT - and the premise did not reproduce

`deferhit` (MAINEQU.ASM) implements 6.4 item 1. `react_xfer_him` records where
the victim is going instead of sending him, and `apply_pending_hits` (JOY.ASM)
runs the transfers from the dispatcher once every process has been walked
(MPROC.ASM, immediately before the next walk). Damage is **not** deferred, only
the transfer, so hit counts, chip and the round-end tests are untouched. Both
fighters' `strike_check` therefore runs before either is moved, and the outcome
cannot depend on list order.

It builds, it is healthy - **25/25 stability sweep, behaviour lock 10/10** -
and it is **OFF**, because the measurement does not support turning it on:

| rig | `deferhit 0`, measured today | `deferhit 1` | what this doc claimed |
|---|---|---|---|
| `sweep_addon_throw` | **P1 wins 8-0** | **P1 wins 8-0** | P2 wins 88-0 |
| `sweep_addon_trade` | 1 trade, *"neither side is favoured"* | nothing measurable | P2 wins 8-0 |

**Two separate problems, and the second one matters more.**

1. **Deferring changes nothing on either rig.** For throws that is explicable:
   a throw takes the victim over through `takeover_him`, not through
   `react_xfer_him`, so nothing in the throw path was ever deferred. The throw
   case needs its own treatment and would not have been fixed by this.

2. **The P2 advantage is not there.** The 8-0 and 88-0 in 6.1 are historical
   numbers from an older build. Today the same rigs, unmodified, report the
   bias on the **other side** for throws and no bias at all for trades.
   Something between those measurements and now already moved this - the
   collision rework of 2026-08-26 is the obvious suspect, since it replaced
   four chain walks with one.

**So the premise has to be re-established before any of this is worth
shipping.** Both rigs are also thin: the trade rig discarded 10 of 11 trials
(it only scores a trial where *both* moves fired, correctly), and the throw rig
produced a throw in 8 of 35. A total bias measured on 8 samples from a rig that
drives P1 and P2 through different code paths is exactly the attribution trap
in `reference_shared_move_rig_attribution` - "P1 always wins" may be the rig,
not the game.

### 6.6 The trade rig cannot currently measure this - 2026-09-04

Widening the rig was the next step and it did not survive contact. The rig
never produced a symmetric exchange, and once it was made to report **what came
out instead of the move it wanted**, the reason was plain.

**First finding - the band was wrong.** The rig swept 56..96 px, and
`knee_check` turns a high kick into a knee at close range, so most of that
range never produced the move being measured. Ten of eleven trials were
correctly discarded. A rig discarding 10 of 11 is not measuring a side
advantage, it is measuring `knee_check`.

**Second finding - the sides were not being driven the same way.** In a
**mirror match**, same character, same distance, same button, same frame, the
two fighters produced *different moves*:

| distance | P1 | P2 |
|---|---|---|
| 64 px | `010fh` knee | `0104h` mid kick |
| 76 px | `0103h` high kick | `0106h` sweep |
| 88 px | `0103h` high kick | `0104h` mid kick |

That cannot happen if both sides are symmetric, and they were not. The sweep
harness exempted only **P2's** fields from being overwritten during a fight:

```lua
if not (P2_HUMAN and fighting_frame>0 and n:sub(1,2)=="P2") then
  f:set_value(pressed(n) and 1 or 0)
end
```

so it kept driving `P1 Left` / `P1 Right` to make battles progress while P2
stood still. A fighter who is walking picks a different move for the same
button than one who is standing. **Every two-player comparison run through
this harness inherited that**, not just this rig.

**Fixed:** `ADDON_OWNS` lets an addon claim P1's fields on the same terms as
P2's, and the trade rig claims both sticks. It is bound through `_G` on both
sides deliberately - MAME runs the harness with its own `_ENV` while the addon
arrives via `dofile`, which resolves against the real globals, so a bare
global assignment is nil on the other side.

**And it is still not symmetric.** With both sticks claimed, P1 attacks only at
88 px and beyond and P2 only at 84 and below - complementary, from two
fighters pinned the same distance apart. Something else in the setup differs
per side and has not been found yet.

**So the honest state is:**

* the historical 8-0 / 88-0 P2 numbers were produced by a rig that drove the
  two sides differently, and **cannot be used as evidence of a game bias**;
* `deferhit` is built, healthy and off, and showed no measurable effect;
* whether MK2 has a side advantage at all is, as of today, **unmeasured** -
  not disproved.

### 6.7 A third attempt, and a recommendation to stop - 2026-09-04

Two more real faults were found in the rig and fixed, and it still cannot
produce a symmetric exchange.

**Fixed: trials started dirty.** They ran back to back, so at close range one
fighter's move connected, the other was still in a reaction when the next
trial's press window opened, and he never acted - which then repeated, because
he was hit again. Self-reinforcing, and it reads exactly like a side advantage.
The rig now waits for both fighters to be back in `act_stance` before pressing,
and reports separately if it ever has to force a start.

**Fixed: stale hit counters.** The outcome is read from `p_hit`, and it was
never cleared between trials - so a count left over from the previous trial
was read as a hit in the next one before either fighter had moved.

Both are genuine corrections and are worth having. Neither made the rig work:

| distance | P1 | P2 |
|---|---|---|
| 56, 84 | nothing | mid kick |
| 60-80 | **nothing** | **nothing** |
| 88-96 | high kick | nothing |

A button press producing no attack at all, from a clean stance, varying with
distance. That is the third distinct fault in this one rig, after the wrong
band (`knee_check`) and the asymmetric harness (`ADDON_OWNS`).

**The recommendation is to stop pulling this thread.** Three sessions of work
on it have produced four fixes to the instrument and zero measurements of the
game. The value already banked is the important part and does not depend on
finishing:

* the historical 8-0 / 88-0 numbers came from an instrument with at least two
  known defects and **cannot be used as evidence**;
* `deferhit` is built, healthy and off, ready if a bias is ever demonstrated;
* whether MK2 has a side advantage remains **unmeasured, not disproved**.

If it is picked up again, the next thing to establish is not a verdict but the
simplest possible positive control: **one fighter, one button, one distance,
does an attack come out** - and only then add the second fighter. Every attempt
so far has started from a two-fighter comparison and inherited a fault it could
not see.

**Multi-box overlap and re-hit protection - OPEN.** Registration is per attack
instance today. Re-hit scope needs stating before multi-hit moves interact with
a juggle counter.

---

## 7. Pushbox and spacing

**There is no pushbox.** `repell_distance` is 64 px of anipoint separation,
pushed apart by a process. One constant, whole cast, ground and air alike.

Consequences:

* Per-character spacing does not exist and would be a new field.
* `f_norepell` exists as an override and is already used by moves that must
  close inside 64 px (Kahn's grab holds it across takeoff).
* **Crossup and facing-flip rule - OPEN, and it blocks input spec 2.2.** This
  is the one hard ordering dependency between the two docs. Decide it here.

Anything requesting velocity has to go through the repell process:
`away_x_vel` and friends write only the `p?_xvel` *request*, and repell can
drop it outright inside the 61 px "super close" band.

---

## 8. Throws - the premise was wrong on both counts

The draft asked for whiff recovery and a tech, on the grounds that MK2's throw
is "instant, unbreakable, no whiff cost". Two of those three are not true, and
the third cannot be fixed the way it is written.

### 8.1 There is no throw INPUT, so there is no whiff

```asm
joy_lo_punch
	movi	040h,a7
	callr	toss_check
	jrc	joy_toss		; close + he is NOT holding away -> THROW
	callr	me_in_front		; otherwise -> ordinary jab
```

**Low Punch inside 64 px becomes a throw. Otherwise it is a jab.** The player
never chooses between them, and a failed attempt is not a failed throw - it is
a jab, which is what the button meant anyway.

So "give a whiffed throw 15 frames of recovery" cannot be implemented as
stated. The only branch to attach a cost to is the one that produces a normal
close-range jab, and penalising it would punish an input the attacker never
made - every jab in throw range, whenever the opponent happened to be holding
back. That is a worse game, not a stricter one.

**Whiff recovery needs the throw to have its own input first.** That is a
design change (a button pair, or a direction plus a button), not a tuning one,
and it is the prerequisite for everything else in this section.

### 8.2 It is already teched, and the tech is holding away

`toss_check` reads the **victim's** stick and refuses the throw if he is
holding away from the attacker. The drone path does the same and also refuses
against a blocking or landing victim. So the throw is not unbreakable: the
defensive option exists, costs nothing, and is invisible - nothing tells the
player it happened, because the attacker just jabs instead.

That is arguably the real complaint hiding behind "throws feel bad". Not that
they cannot be escaped, but that escaping and being thrown look identical from
the outside.

**"So make the escape visible" - investigated 2026-09-04, and it is the wrong
fix.** The obvious version is a sound on the escape branch, which is cheap and
needs no art. It was not built, because of how often that branch runs.

`joy_lo_punch` calls `toss_check` on **every** low punch inside 64 px, and the
escape is reached whenever the defender is holding away - which is what he is
doing anyway, because that is how you walk backwards and it is next to how you
block. So a denied throw is not an event. It is the **default state** of any
close-range exchange against a retreating opponent, and it would fire on nearly
every jab.

That is worth stating plainly, because it is a stronger version of 8.1: the
throw is not merely un-chosen by the attacker, it is **un-denied by the
defender** - he gets the escape for free, continuously, as a side effect of
holding a direction he already wants to hold. There is no read, no timing and
no cost on either side.

So there is nothing meaningful to give feedback about until the throw is
something a player commits to. Feedback follows a distinct input; it cannot
substitute for one.

### 8.3 What is actually still open

* Range is a scalar distance test, not a box (section 2.1) - except the new
  grabs (Kahn's, Ermac's teleslam), which are boxed.
* **A distinct throw input** - built as `throwbtn` (Low Punch + High Kick),
  measured, and turned back OFF the same day. The reasoning is worth keeping
  because it was not obvious going in.

  It was never wanted for its own sake: it is the *prerequisite* for 8.1's
  whiff cost, because without an input there is no whiff to charge for. But
  that cost was never built, so with `throwbtn 1` the build paid the entire
  price - thirty years of muscle memory, and an awkward one-directional
  HK-then-LP input - and collected none of the benefit.

  The case for touching throws at all also got weaker as it was investigated.
  Of the three original complaints - *instant, unbreakable, no whiff cost* -
  **two were false**: the tech always existed (8.2), and the P2 throw
  advantage came from a rig with two known defects (6.6, 6.7). Only the whiff
  cost survived.

  A proximity throw is simple, but it does not *punish good play*, which is
  the line this project drew for what should change and what should not.

  The mechanism stays in the source, off. Turn it on only alongside the whiff
  cost it exists to enable - and if you do, make it reachable from the High
  Kick handler too, or it stays one-directional.

* Whether the escape should be **visible** - a whiff animation, a push, any
  feedback at all that a throw was attempted and denied.
* `f_sans_throws` disables throws globally and is presumably a diagnostic;
  worth knowing it exists before anyone adds a second such flag.
* Simultaneous throws: see 6.5 and 6.6. The measurement that produced "P2 wins
  88-0" cannot be trusted, so this is not a known problem.

---

## 9. Juggles and scaling

**Damage scaling is ON as of 2026-09-03** - `dmgscale` (MAINEQU.ASM).

| hit in the string | worth |
|---|---|
| 1st | full |
| 2nd | 3/4 |
| 3rd | 1/2 |
| 4th and later | 1/4 |

A real hit never scales away to nothing - the floor is 1.

**Validated 2026-09-03** alongside `backblock`: stability sweep **25/25 PASS**,
behaviour lock **10/10**. Both switches went into the same build, so if
something feels wrong in play, flip them one at a time - two ruleset changes in
one build makes attribution impossible.

Measured before turning it on (`tools/sweep_addon_phit.lua`, 22 battles):
strings average 2.1-3.4 hits and reach 5 in twenty of them, and at a median
non-boss hit of 20 damage a five-hit string was **100 HP, 62% of the 161 bar**.
With the curve the same string is **55, or 34%**. Rounds ending to one
interaction was the complaint; this is the answer that needs no new art, no new
state and no per-move data.

The index is the **victim's** `p_hit` - hits he has already taken in this
string. `inc_p_hit` runs in `reaction_start_chores`, i.e. *after* damage is
applied, so the opening hit correctly counts zero. It clears when he lands
(`gravani`) or blocks (`block_exit`), which is what makes it a juggle counter
rather than a lifetime hit counter.

It is applied at `block_is_useless` - the clean-hit path - and not inside
`bar_reducer`, because `bar_reducer` has three callers and one of them is
`damage_to_me`, where `a13` is the fighter hurting *himself* and scaling would
index the wrong fighter's counter.

**A juggle ceiling also exists** - see [JUGGLE_CEILING.md](JUGGLE_CEILING.md)
and the corner anti-infinite work. A general per-move `juggle_cost` still does
not.

Known live issue: the corner anti-infinite fires, but `repell_now` discards the
separation it asks for, so the roundhouse loop survives it. That is a repell
problem (section 7), not a juggle-counter problem, and it will not be fixed by
adding a counter.

**Damage scaling - OPEN.** Recommend a fixed table over a formula, so it is
readable on the published page. Max HP is **161** (`0xA1`), not 100 - every
percentage in a balance discussion has to be converted or it is wrong.

---

## 10. Stun, hitstop, pushback - OPEN

The integration test the draft calls highest-priority is **not needed**:
hitstop cannot advance the motion window, because there is no per-step timeout
to advance (input spec 4.2, rule 1). The only clock is the total window, taken
from `@tick` at match time.

Still open: separate hitstop on hit and on block, and whether the dizzy system
stays.

---

## 11. Corner behaviour - OPEN

Every item here reduces to `repell_distance` plus the scroll limits today.
Worth enumerating explicitly before touching either, because each is a source
of "the hitboxes are broken" reports that are not hitbox reports.

---

## 12. Projectiles

Own entity, own authored strike record, own frame data row. The registry is
`projectile_jumps` (MKZAP.ASM), **42 slots**.

**Projectile versus projectile - OPEN**, and promoted to blocking by 12b.

### 12b. Air projectiles - INVENTORY RESOLVED

The draft left this table empty and blocking. It is smaller than feared:

| Character | Move | Slot | Ground counterpart | Origin |
|---|---|---|---|---|
| Liu Kang | air fireball (`do_lk_zapair`) | 0x01 | 0x02 / 0x03 | retail |
| Kitana | air fan - `do_throw_fans` branches on `am_i_airborn` | 0x06 | same slot | retail |
| Mileena | air sai - `do_throw_sai` branches | 0x07 | same slot | retail |
| Sub-Zero | air ice (`do_sz_airice`) | 0x16 | 0x0D | **added** |
| Reptile | air acid spit (`do_rp_airspit`) | 0x17 | 0x12 | **added** |
| Jax | air lightwave (`do_jax_airzap`) | 0x25 | 0x14 | **added** |
| Noob | shadow dive kick (`do_noob_dive`) | 0x27 | **none** | **added** |

So: **three added air projectiles, plus one air special with no ground
counterpart.** Not a flood. Noob's dive kick is the one that needs balance
attention as a new tool rather than a variant.

**`per_jump_limit` - built, and REVERTED as solving nothing** (`airzap_once`,
now 0). Reported from play: a player could never throw more than one air
projectile per jump anyway, so a per-jump limit had no work to do. The sai is
spammable because of its **input**, not because of anything to do with jumping.

**What replaced it: `saicool`**, a cooldown of `040h*2` ticks - the same one
Kitana's fan has carried all along, twenty lines below it in MOVES.ASM. Her sai
was the only projectile in the game with nothing between throws: `fn2_hp_open`
checks that HP was *held* for `022h` ticks and nothing else, and a hold
requirement is not a rate limit. Hold six tenths of a second, release, repeat.

**What UMK3 did instead, since it is the obvious place to look.** The sequel's
Mileena is much more restrained, and the source says why - and it is not the
frames:

| | UMK3 | this build |
|---|---|---|
| ground recovery | `process_sleep(0x25)` = 37 ticks, `ACT_PROJ_SD` | `020h` = 32 ticks, `act_proj_sd` |
| air recovery | none beyond `drop_down_land()` | none beyond `air_throw_drop` |
| **input** | `secret_move_search(sm_mil_hpo)` - a real motion | hold HP, release |

Recovery is **five ticks apart**. What UMK3 changed is the **input**: the sai
goes through the same pattern-search machinery as every other special, rather
than a bare hold-and-release.

That is the better fix and it was deliberately not taken. Changing the input is
a control change - see 8.3 for how that went - and it would break a family,
because held-HP is also how Kitana's and Jade's boomerangs are thrown here. The
cooldown reaches the same rate limit while touching no animation, no speed and
no recovery.

**(The original `per_jump_limit` note follows, for the mechanism.)**

Mileena's sai was the reason. `fn2_hp_open` (MOVES.ASM) dispatched it through
`airborn_xfer` with a hold-time check and **nothing else** - no cooldown, no
limit - while Kitana's fan twenty lines below has carried an `l_throw_fan`
cooldown all along. So the sai could be thrown as fast as HP could be held and
released, from the air, indefinitely. It was the only air projectile in the
game with no limiter of any kind.

The rule is per **airborne state**, not a clock: throw once, and the slot does
not reopen until the feet touch down. A clock still allows spam from a long
enough jump and punishes a legitimate throw on the next one; landing is the
event that means something. Grounded throws are untouched.

`clear_his_air_locks` (MKUTIL.ASM) already existed for the opposite rule -
Sub-Zero's air freeze and Raiden's torpedo may not *catch* a man twice per
jump - so the landing hook was there. The two are keyed to opposite fighters:
`l_freeze` limits how often a move may catch, so landing clears the lander's
OPPONENT's stamp; `l_airzap` limits how often a man may throw, so landing
clears his OWN.

`air_zap_gate` is the reusable half - carry set means allowed and stamps it -
so the remaining air projectiles are one `callr` plus a `jrnc death` each.

**`landing_recovery` - DONE 2026-09-04** (`airland_recover`, a landing rate of
7 ticks per frame against retail's 3).

**It is a slower landing, not a pause after a normal one**, and the first
version got that wrong. Playing the landing at normal speed and then sleeping
for the recovery left the fighter frozen on the last crouched frame for the
whole of it - which reads as the game having hung, not as a heavy landing. It
was reported from play within one session. Stretching the animation costs the
same time and stays in motion the whole way.

The lesson generalises: **recovery that is not animated is indistinguishable
from a bug.** Anything that takes a fighter's control away for more than a few
ticks needs something on screen for those ticks.

`airzap_once` made air projectiles **rarer**; this is what makes them a
**decision**. The flight is untouched, so thrown from range the move is as safe
as it ever was - and the landing now costs 14 ticks, so thrown up close it is
punishable. That is the shape 12b wanted from the pair.

It lives in `air_throw_drop` (MKZAP.ASM), the tail every air projectile lands
through, so one constant covers all six. `do_land_animation` ends in
`mframew`'s `retp`, so `jsrp` + `sleep` + `retp` is the correct pair; the tail
jump was only there because nothing followed it.

Two things to know before tuning it:

* **It is human-only, and not by choice.** `do_land_animation` opens with
  `calla am_i_joy / janc drone_land`, so a drone leaves and never returns -
  nothing after a `jsrp` of it runs for the CPU. The drone's air projectiles
  are already rate-limited by `l_drone_zap`, so this is a gap rather than a
  bug, but at high difficulty the CPU pays no landing cost.
* **It also catches Noob's dive KICK**, which lands through the same tail. A
  dive kick punishable on landing is normal for the genre, but it is a second
  balance change riding on one constant.

**Still open:** `min_height` and `momentum_on_release` exist as fields nowhere.
`min_height` is the one that kills instant-air versions, and is the remaining
degenerate case. Every air
projectile currently ends in `air_throw_drop`, which finishes the jump arc and
lands - except Liu Kang's, which ends in a plain `retp` and leaves the caller
to finish the arc. Any landing-recovery rule has to handle both shapes.

**Recommendations unchanged from the draft:** set a minimum height, give
12-18 ticks of landing recovery, one per airborne state, and kill horizontal
momentum on release. MK2's jump arc is fixed and uninfluenceable, so a
retained-momentum air projectile is a moving wall.

**The CPU side is already capped.** `air_zap_offsets` routes six characters
through `drone_air_zap_try`, which **shares `l_drone_zap`** - throws per round
are unchanged, only the delivery differs. Most of the draft's "live projectile
cap" worry is already handled for the drone; it is the human side that is
ungoverned.

**T-Unit budget - OPEN.** Worst case is both players firing air and ground
projectiles in a corner with stage objects live. `peak_overload` and
`qdma_drops` are on GAME AUDITS page 3; measure there rather than by eye.

---

## 13. Data format and authoring - RESOLVED

Already built, and better than the draft assumed:

* **Boxes round-trip as JSON.** `tools/hitbox_pack.py` exports and re-imports;
  `boxlab/data/boxes.json` is *the file the build reads back*, so the public
  page and the ROM cannot disagree about the numbers.
  `boxlab_export.py --check` proves it - not `hitbox_pack.py diff`, which
  cannot read a `--public` pack's ids. And "cannot disagree about the numbers"
  was never the same as "cannot disagree": see 13.1.
* **Proposals come back in.** `boxlab_export.py --proposals` resolves a public
  id to a strike record and applies it. See [BOXLAB.md](BOXLAB.md).
* **The debug overlay exists and is not optional.** `f_colbox` is a bitmask:
  1 = hitbox, 2 = silhouette, 4 = the box the compare actually used, 8 =
  anipoints and ground line, 16 = per-piece. **`f_colbox=5` is the one you
  usually want.** Look the address up - it is `.bss` and it moves.
* **The editor exists.** boxlab is a browser frame-stepper with drag-to-edit
  and a pull-request proposal flow. See [BOXLAB.md](BOXLAB.md).

`f_colbox` bit 4 costs frame time and can change how a fight plays out. Use it
to look, never while measuring.

### 13.1 The public viewer models RETAIL, not this build

`sq_punch` has two branches. `anchorcol 1` - what ships - centres the column on
the **anipoint**. `anchorcol 0` insets the **bounding box**, which is retail,
and is kept only for A/B. boxlab's `index.html` hardcodes the second one:

```js
function squeeze(l, r){
  const W = r - l, inset = (W >> 3) + (W >> 2);
  return [l + inset, r - inset];          // this is anchorcol 0
}
```

Measured cost of that (`box_model_lab.py drift`, `width`, `flips`):

| | |
|---|---|
| column drift, retail centre vs the anchor | median **5.5 px**, mean 10.1, worst **60** |
| poses drifting more than 5 px | **445 of 869 (51%)** |
| column *width*, retail vs build | differs on **108 of 125** silhouette widths, by up to 5 px |
| hit/miss verdicts that differ | **2.89%** |

The width difference is its own small trap: `sq_punch`'s comment says the two
branches keep "the same quarter width", and the shifts truncate differently, so
they do not. It also means boxlab's `selftest.mjs`, which asserts an 18 px
tested column for a standing Jax against the `f_colbox` overlay, is asserting a
**retail** measurement - the shipping build makes that column 16.

**This is the drift the whole project exists to prevent, in the one place
nothing checks.** `boxes.json` is generated and verified; the model that
interprets it is hand-written JavaScript, and no gate compares it to anything.

The fix has two halves, and the second matters more than the first:

1. Teach `squeeze()` the anchored branch, and re-derive `selftest.mjs`'s two
   asserted widths. **Written and passing, staged not committed** - it is
   hand-written public code, so it waits for review.

   Both halves read `BOX.model` rather than hardcoding a branch, which is the
   point: the page draws whichever model the pack declares, and a pack with no
   `model` block is old and gets retail. The two selftest assertions do the
   same instead of carrying a literal - and one of them, *"tested column is not
   centred on the anchor"*, was actively asserting retail behaviour long after
   the build stopped doing it. A test can pin the wrong build just as easily as
   a viewer can draw one.
2. **Export which model the build uses**, so the viewer reads it instead of
   hardcoding one. **Done** - `boxes.json` now carries:

   ```json
   "model": { "column": "anchor", "column_divisor": 4,
              "per_piece": false, "phased_boxes": false }
   ```

   Without this, flipping `perpiece` or `colwidth` on would silently make the
   public page wrong again and nothing would say so. With it, the page has no
   excuse - and a reader who is not us can tell which model the numbers belong
   to.

---

## 14. Determinism - RESOLVED BY CONSTRUCTION

See input spec section 7. No floats, no separate savestate, no hash maps.
Nothing to enforce.

---

## 15. Validation - mostly built

| Gate | What it catches |
|---|---|
| `tools/run_battle_stability_sweep.ps1` | crashes, wedges, camera faults |
| `tools/run_behaviour_check.ps1` | the behaviours that must not move |
| `tools/hitbox_overlay_test.lua` (`f_colbox=5`) | the box against the sprite, on the frame it is parked |
| `tools/box_align_audit.py` | a box that no longer overlaps its own art |
| `doc/balance.lock`, `doc/hurtbox.lock` | a strike record or a derived hurt box moving silently |
| `tools/boxlab_export.py --check` | the public data drifting from the build (Phase D, warning) |
| `tools/combo_collision_audit.py` | one special able to fire instead of another (Phase D, **fatal**) |

**Capture on the frames a strike box is parked, not on a fixed offset.** A rig
that snapshots frame N of an animation will photograph the wrong frame as soon
as the timing changes.

The overlay is what to post on a pull request. A hitbox argument settled with a
picture of the hitbox is settled; one settled with two people's memories is not.

Still to do: order-independence testing (section 6 already fails it), and
advantage values derived rather than entered and checked against a training
dummy.

---

## 16. Open decisions

Struck from the draft's list as resolved: units, authored-versus-derived,
column anchoring, data format, determinism, air projectile inventory.

**Closed by measurement** (`tools/box_model_lab.py`), not by decision:

* *"Does per-piece give a high/low axis?"* **No.** Zero moves gained; it widens
  a 2 px window to 8 px. Section 3.2.
* *"Can we build overheads without art by raising strike boxes?"* **No.** The
  band is 9 px median, negative for Kintaro, and no record is under 27 px tall.
  Section 4.1. This one is now closed for good - stop reopening it.
* *"How big is each Route A lever?"* A third = 1.70% of verdicts, a half =
  **4.32%**, per-piece = 13.66%. Section 3.1. (The half was quoted as 4.94%
  until it was re-measured against a baseline without the `colwidth` width
  bug; it is also purely additive - 473,711 hits gained, 0 lost.)

Still open:

1. ~~Route A, A-and-a-half or B~~ - **A-and-a-half is closed** (3.2): it is
   98% "remove the squeeze" and 2% limb precision, it deletes the point-blank
   dead zone across the cast, and it would need all 233 records re-cut to
   compensate. Route A's levers remain; Route B's true prize is ~1%.
2. ~~Narrowing factor~~ - **CLOSED. `colnarrow 2` ships**: the column is a
   half, global, not per-state. 4.32% of verdicts and purely additive
   (473,711 gained, 0 lost) - nothing that connected stops connecting. It
   shrinks the point-blank dead zone without deleting it (the uppercut starts
   at 28px for Jax and Cage where retail needed 41, and at 0 for the female
   ninjas), and leaves the high/low game untouched: the same 119 of 199 moves
   whiff over a crouch, with the same median window.
4. ~~Vertical clipping per state~~ - **CLOSED, measured and rejected.** It
   adds no move to the 119 that can whiff over a crouch, at any clip from 0
   to 32px; what grows instead is the count that cannot reach a crouch at all
   (2 -> 92 of 199). That is invulnerability, not a mixup. With 4.1 and 3.2
   this closes the high/low question for good: all three routes to a vertical
   axis fail, for three different reasons.
5. ~~The viewer draws retail's model~~ - **CLOSED.** `squeeze()` reads the
   pack's `model` block instead of assuming. It then had to learn a THIRD
   width branch when `colnarrow` shipped, because the game has three and
   every tool here assumed two. `boxlab_export.py --check` now cross-checks
   the published rule against `box_model_lab`'s independent reading of the
   source over 260 widths x 4 anchors, so the two cannot drift again.
6. ~~Side bias~~ - **CLOSED. Proved from source, measured as a controlled
   A/B, and FIXED.** `deferhit` ships.

   The mechanism is not a rig question. `getprc` links a new process after
   its creator (`a13` is only dereferenced there, never written, and
   `xferprc0` touches a2/a12 but not a13); `setup_players` creates P1 then
   P2 from that same running process, so the list becomes `[C, P2, P1]` -
   the SECOND player created ends up FIRST - and `prcdsp` walks forward from
   `active`. P2's `strike_check` therefore runs first on every tick, by
   construction, and a connect calls `react_xfer_him` before the other
   fighter's process has run at all. That is also why nothing ever trades.

   Measured, same rig and settings either side, mirror match (Baraka vs
   Baraka, both human, pinned at symmetric distances, both pressing High
   Kick on the same frame):

   | `deferhit` | P1 won | P2 won | traded |
   |---|---|---|---|
   | 0 (retail) | 0 | **4** | 0 |
   | 1 (ships) | 0 | 0 | **4** |

   Complete separation. Sections 6.5-6.7 concluded "unmeasured, not
   disproved" and recommended stopping; that was right about the rigs of the
   day and is superseded. The rig fault was real and is fixed - the harness
   was driving P1's stick during fights (`ADDON_OWNS`), which corrupted
   every two-player comparison.

   The sample is narrow: four distances, one move, one matchup. Read it as
   proof the mechanism works, not as a survey of the cast.

   Three limits worth carrying, and the second is the important one.

   * Deferring cannot fix THROWS - a throw takes the victim through
     `takeover_him`, never through `react_xfer_him`.
   * **It does not fix the KILLING BLOW.** `bar_reducer` (JOY.ASM) opens by
     refusing to apply any damage once EITHER bar is already zero
     (`jreq bred5`, *"zero already ---> mute point"*), and it runs inline -
     `deferhit` defers the transfer, not the damage. So on a lethal
     exchange P2's check reduces P1 to zero first and P1's check is then
     short-circuited. Traced frame by frame at 82px: at 100 HP both bars
     drop 32 on the same tick (100/100 -> 68/68), at 8 HP the identical
     exchange gives 8/8 -> 0/8. **Ordinary exchanges are now even; the one
     that decides the round is not.** Making it even means letting both
     reductions land before testing for zero, which creates real double KOs
     - and `its_a_tie` (MAIN.ASM) is a bare `retp` that sets no
     `winner_status` and awards no round to anybody. That is a chain of
     work, not a switch. Rig: `tools/sweep_addon_dko.lua`.
   * Swapping the creation order would not have fixed anything; it would
     have handed the same advantage to P1.

7. Re-hit protection - **ANSWERED: it is structural, and there is no flag,
   no timer and no scope to choose.** Nothing tracks "recently hit".

   * A `striker`-driven move stops the moment it connects: the active loop
     is `strike_check_a0 / jrc attack_hit`, and `attack_hit` is `setc; retp`.
     The remaining ticks of the window are abandoned, so **one activation can
     land at most one hit** - on hit or on block alike.
   * A projectile does the same by deleting itself: every connect path in
     MKZAP.ASM ends `jruc delete_proj_and_die`.

   So there is nothing to widen or narrow. What follows is that MK2 has no
   protection against a *fresh* activation connecting immediately, which is
   what makes juggles work and is precisely the gap `dmgscale` was built to
   tax. If a re-hit rule is ever wanted it would be a new mechanism, not a
   scope setting on an existing one.
8. ~~Crossup / facing-flip rule~~ - **ANSWERED. There are TWO facings, on
   two different clocks, and nothing keeps them in step.**

   * **Logical facing** is never stored. `is_he_right` (MKUTIL.ASM) is a live
     `cmp` of the two fighters' `oxval` every time it is called, so it flips
     on the exact tick they cross. The test is `jrgt`, strictly greater, so
     at equal x it reports "not to the right" and the face-LEFT pattern is
     used - a tie-break, not a coin flip.
   * **Character facing** is the `m_fliph` bit in the player object's
     `oflags`. It changes only when `turn_around` (MOVES.ASM) runs, and that
     is an ANIMATION: `stop_me`, `disable_all_buttons`, then ani 009h at a
     per-character rate from `ta_speeds`, then a residual `prcslp`. Every
     entry works out at about **8 ticks (~146 ms)** - the table is uneven
     (`4,0` over 2 frames, `2,2` over 3, `2,0` over 4) precisely so the
     durations match.
   * They are reconciled in **three states only**: the stance loop, walking,
     and blocking, each guarded by `am_i_facing_him`, which is the live
     verdict compared against the latched bit. **During a jump or any move,
     no turn is even attempted**, so the two facings can disagree for the
     whole airborne arc.

   That is the crossup drop, exactly: the jumper crosses, `combo_look_lr`
   re-resolves at match time and re-reads the WHOLE queue in the new facing,
   while the fighter on the ground is still 8 button-disabled ticks away from
   turning. The motion was entered in one facing and judged in the other.

   For the per-entry fix in input spec 2.2, the facing to stamp is the
   **physical** one (`is_he_right` at write time): it is what "toward" meant
   to the player at the moment the entry was made.
9. Per-character spacing - **MEASURED, and the case is about one character
   class, not the cast.** `repell_distance` is a single `.set 040h` (64 px)
   in MAINEQU.ASM, compared in three places in MAIN.ASM; there is no
   per-character table anywhere. Widest stance silhouette per character
   against that 64 px:

   | character | stance width | at minimum separation |
   |---|---|---|
   | `fourarms` | 129 px | silhouettes overlap by 65 |
   | `final-boss` | 74 px | overlap by 10 |
   | `headband`, `hathead` | 71 px | overlap by 7 |
   | `bigarms` | 69 px | overlap by 5 |
   | ten others | 58-67 px | overlap by 3 to 6 px apart |

   Silhouette overlap is not itself wrong - the constant governs ANIPOINT
   distance, and limbs are meant to overlap. What it shows is how much the
   constant's *meaning* varies: for sixteen of seventeen it is within about
   10 px of a body width, and for `fourarms` it is half a body. So the honest
   scope is not "per-character spacing" but "does the four-armed class need
   an exception" - and since those are boss-only, the cheapest answer may be
   to leave it. Reproduce from `box_model_lab`'s pose data.
10. Throw whiff recovery and teching - **teching already exists in full;
    whiff recovery is not implementable as asked, and the reason is the same
    one that closed `throwbtn`.**

    `toss_check` (JOY.ASM) ends by loading the OTHER player's process and
    object and running `is_stick_away` on them: **hold away and the throw is
    refused.** That is a tech, it is in retail, and it was always there. The
    same routine already refuses a throw against an airborne victim, against
    Goro and Shao Kahn, against anything flagged `b_noflip`, near the screen
    edge, and while `f_sans_throws` is up - MK2 protects landings through it
    too.

    Whiff recovery has nothing to attach to. There is no throw INPUT: the
    throw comes off LOW PUNCH at close range, so out of range you simply get
    a low punch instead. Nothing whiffs, so nothing can be charged for it.
    That is why `throwbtn` existed - it was the *prerequisite*, not the goal -
    and why turning it on paid the entire price (thirty years of muscle
    memory, an awkward one-directional input) while collecting none of the
    benefit, since the cost it was a prerequisite for was never built.

    **Note the ordering trap in the original wording**: "fixing P2's throw
    advantage first" assumed a demonstrated P2 bias, and item 6 says there is
    none demonstrated. Do not sequence work behind it.

11. Juggle counter and the separation shove - **both halves answered, and
    the second one was overstated.**

    * **The counter exists**: `p_hit`. `no_unlimited_airhits` (MKREACT.ASM)
      fires on `p_hit > 3`, and `dmgscale` reads the same count. The scaling
      table ships - full, 3/4, 1/2, then 1/4 from the fourth, resetting on
      landing or blocking; a measured five-hit string drops from 100 HP of a
      161 bar to 55.
    * **"repell_now discards separation" is not quite right, and the case it
      was written about does not occur.** Measured 2026-08-26: in the corner
      roundhouse `p_hit` never exceeded 1, so `no_unlimited_airhits` is never
      reached there and `attacker_getting_separated` is never invoked. Do not
      "fix" the corner loop here - see doc/CORNER_ROUNDHOUSE.md.

    What the code actually does, for the juggles that DO reach four hits:
    `repell` writes `oxvel` directly every tick via `stuff_velocities`, and
    inside `repell_distance` (64 px) `repell_now` substitutes its own
    `030000h` - 3 px/tick - for whatever was requested. So
    `attacker_getting_separated`'s ground path, which asks for `070000h`
    (7 px/tick) through `away_x_vel`, is delivered at **43% strength until
    the pair clears 64 px**, at which point `stuff_velocities` resumes
    feeding from the request. Throttled, not discarded.

    The escape hatch already exists and is used twice: hold `f_norepell` and
    write `oxvel` on the object directly, the pattern Kahn's Big P and
    Scorpion's point-blank teleport both use. So if the anti-infinite's full
    shove is ever wanted, the fix is that idiom, not a change to `repell`.
    What is still untested is whether 3 px/tick is actually insufficient -
    nobody has measured a real four-hit juggle escaping.

12. Separate hitstop on hit and on block - **the distinction already
    exists, is already carried, and is already used by half the game.**

    `striker` (JOY.ASM) returns a bare carry - set = connected - and a BLOCK
    sets it too, because `strike_blocked` falls through to `yes_collision`,
    the same `setc` a clean hit takes. But the carry is not the only channel:
    `strike_check_a0` documents **`b2` as a blocked flag**, clears it on
    entry ("a block must be proven !!") and sets it in the block path.

    **MKZAP.ASM already reads it**, in about eight places, with the idiom
    `move b2,b2 / jrne` - which is why a fireball can burst differently on a
    guard. The ground-move handlers simply never look. That is why their
    `sleep N` hangtime is identical on hit and on block, and why
    `do_jump_kick`'s `jrnc jk9` sends a BLOCKED jump kick into
    `act_hitfall_sd` exactly as a connected one.

    So this is not a redesign and not even a signature change: it is the
    existing `move b2,b2` idiom in the handlers that want it. One thing to
    confirm first - `b2` is a B-file register and `striker`'s save/restore
    (`mmtm sp,a0,a10,a11`) only covers A registers, so it should survive back
    to the handler; MKZAP reading it after its own call is evidence it
    survives at least that far, but verify before relying on it.

    Whether to keep or drop dizzy is untouched by this and still open.

13. Projectile versus projectile - **ANSWERED: it does not happen, and the
    hook for making it happen is a single routine.** A projectile tests
    against the opposing PLAYER and nothing else: `proj_strike_check`
    (MKZAP.ASM) resolves `p_otherguy` and tails into `strike_check_a0`.
    No projectile is ever tested against another, so two fireballs pass
    through each other.

    The apparent counter-example is not one: Kahn's sonic clap deflects a
    shot, but that is a MOVE whose strike box catches the projectile, not a
    projectile-projectile test.

    The routine already carries three class-wide gates - the round-over
    check, Jade's Flash pass-through, and the hitbox index - and its own
    comment states the property that makes this cheap: *"Every projectile
    collision funnels through this routine, so one gate here covers the
    whole class rather than 28 flight loops."* So projectile-vs-projectile
    is one test in one place, not 28. What it would need first is a
    decision, not code: whether shots trade, cancel, or the stronger
    survives - and MK2 has no notion of projectile strength to rank them by.
14. Air projectiles - **two of the four are closed, `min_height` is BUILT
    and waiting, and only momentum is genuinely absent.**

    * `per_jump_limit` - built as `airzap_once`, measured, reverted: it
      constrained nothing, because a player could never throw more than one
      air projectile per jump anyway. The sai was spammable through its
      INPUT (hold HP, release, repeat), which `saicool` now rate-limits to
      match Kitana's fan.
    * `landing_recovery` - built as `airland_recover`, reverted: it read as
      a bug in play, the fighter appearing to freeze on a crouched frame.
    * `min_height` - **already exists as `airzap_minheight`** (MAINEQU.ASM),
      wired into `air_zap_gate` (MOVES.ASM). It measures height the way the
      rigs do - `p_ganiy` minus `oypos`, +y being down - and refuses the
      throw below the threshold. It is set to 0, and its own note gives the
      reason: `airzap_once` and `airland_recover` had both just landed
      unplayed, and a third unplayed change on the same move would make an
      unwanted result impossible to attribute.

      **That reason has since expired** - both of those were reverted, and
      `saicool` shipped in their place. Turning it on is now one constant
      with nothing else riding on the same move. It reaches only Mileena's
      sai today, and touches no animation, speed or recovery; the cost to
      weigh is that a too-low input fails silently.
    * Momentum on release is the one that exists nowhere.

    Liu Kang's odd tail still stands: every air projectile ends in
    `air_throw_drop`, which finishes the jump arc, except his, which is a
    plain `retp` leaving the caller to finish it. Any landing rule must
    handle both shapes.
15. Live projectile cap - **there is no cap and no counter, and the
    performance case for one was already measured away.** Nothing anywhere
    counts live projectiles. Three unrelated things limit them: a move's own
    recovery, the per-move `l_*` cooldown stamps that SOME projectiles carry
    (`l_throw_fan`, `l_sai`, `l_gorofire`, `l_drone_zap` - most carry none),
    and the fact that every projectile deletes itself on connect or
    offscreen.

    The cap was wanted as a safety valve against frame cost, and that worry
    is settled: the perf instrumentation found no problem, with
    `peak_overload` and `qdma_drops` readable on GAME AUDITS page 3. So a cap
    now would be a gameplay ruling, not a technical necessity - and the
    honest place to enforce a rate is the per-move cooldown that already
    exists for some projectiles and not others, rather than a global ceiling.
