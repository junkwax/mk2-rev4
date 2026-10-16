# CPU drone AI — how it works and how to tune it

Everything here lives in [src/MKDRONE.ASM](../src/MKDRONE.ASM) unless noted.

## The rule this AI is held to

**The drone may only use information a human opponent sitting at the other
cabinet could have.** Positions, distances, the animation the other fighter
is visibly in, its own health, and what has already hit it. It must not
look at the player's switches to decide *whether* to act.

Two mechanisms in the original code broke that rule. Both are now gone:

| Mechanism | Where | Status |
|---|---|---|
| `c_uppercut` startup counter — reacted to the uppercut before it came out | `counter_attack_table` | **restored**, gated behind the think timer (see below) |
| `toss_drone_check` throw reversal — fires on the frame the player *presses* punch | [src/JOY.ASM](../src/JOY.ASM) `rt_drone_reverse` | **removed** — table zeroed at every difficulty |

`c_uppercut` was disabled outright for a while, on the theory that the `06xx`
whiff-punish handlers were the fair replacement. They were not: they only
fire once a move has *whiffed*, and an uppercut thrown at a drone walking
chest-first into it does not whiff. The drone had no answer to an uppercut at
all and simply ate them. It now dispatches again, but only after
`drone_react_delay` has elapsed — off the visible startup animation, not the
button — and **both** `react_jump_table` slots are now `drone_block`.

The counter slot used to be `drone_duck_upcut` (duck under it, uppercut
back). That was reported from real play as reading like a cheat, and it is:
the uppercut's strike is live about **two** ticks after the button and
`drone_react_delay` floors at **three**, so a drone that ducks it cleanly is
not reacting to the animation — it is reacting to the input. Nothing is lost
by removing it, because a *whiffed* uppercut is still punished through
`c_upcut_sd`, which reads the long `act_upcut_sd` recovery instead: a window
a person can genuinely see and take.

Reading the *victim's* switches inside a throw gate is fine and stays — that
is the game's own "holding away escapes a throw" rule, applied to the drone
in the same way it already applied to humans.

**The second half of the rule: the drone may only make moves a player could
make, sequenced the way a player could sequence them.** No drone-only jump
speed, arc or timing, and no projectile sooner than a player's own button
handler would allow. When a move is unsafe at some range, the fix is to
choose a *different* human move, never to retune the move for the CPU. Two
cases so far: the half-speed jump-throw was replaced by a straight-up one
(see "The runway"), and every CPU projectile now passes the player's limits
(`drone_zap_legal`, under "Move pacing").

### The throw reversal, and why the cap never shipped

`toss_drone_check` ([JOY.ASM:1371](../src/JOY.ASM#L1371)) lives inside the
**player's** `toss_check`, so it runs on the frame you press the grab, before
your throw exists. On a hit it pops your return address twice, force-transfers
the drone's process to `drone_reverse_toss` (`do_body_slam`) via
`react_xfer_him`, sleeps 4, and your throw exits as "too l8". A human has no
equivalent — MK2 has no throw break.

It was nerfed 900 → 400 → 200 and none of it took effect above diff 4,
because the read had Midway's stride bug (verbatim in the leak):

```asm
	move	@diff,a0,w
	sll	5,a0			; 32-bit stride...
	addi	rt_drone_reverse,a0
	move	*a0,a0,w		; ...against a .word (16-bit) table
```

Every other per-difficulty `.word` table in the codebase uses `sll 4`
([MKDRONE.ASM:127](../src/MKDRONE.ASM#L127), [9001](../src/MKDRONE.ASM#L9001),
[9815](../src/MKDRONE.ASM#L9815)). `sll 5` reads entry `2*diff`, and the table
has 10 entries — so **from diff 5 up the read ran past the end into
`knee_check`'s opcodes**. From the listing (table at `0x62b0`, `knee_check` at
`0x6350`):

| diff | reads | value | chance |
|---|---|---|---|
| 0–4 | entries 0, 2, 4, 6, 8 | 0, 50, 100, 150, 200 | 0–20% |
| 5 | `callr get_x_dist` | 0x0d3f = 3391 | **100%** |
| 6 | `cmpi 040h,a3` | 0x0b43 = 2883 | **100%** |
| 7 | `jrhi local_rets` | 0xc3c4 = 50116 | **100%** |
| 8 | address word | 0x9ee0 = 40672 | **100%** |
| 9 | `jrc local_rets` | 0xc8c0 = 51392 | **100%** |

`randper` is `a0/1000`, so anything ≥ 1000 always passes. On the late ladder —
Shang, Kintaro, Kahn — **every** throw the player attempted was reversed. That
is the retail "throw override" everyone remembers, and it is why the reversal
read as a rule rather than a roll.

The stride is now `sll 4` and the table is zero at every difficulty, with an
early-out on 0 so `randper` is not even rolled. The drone still throws, through
`drone_body_slam`, off the visible action catagory and with the same
hold-away / hold-block escape a human throw obeys.

One thing this does **not** cover: nothing sets `b_noflip` during a morph
(`set_noflip` has exactly one caller, in MKPROP.ASM), so a Shang mid-morph is
fully throwable by either side. That is stock MK2 behaviour and is left alone.

## Decision flow

```
generic_drone_start
  ├─ health < 028h  → 20% roll → drone_special_start      (desperation)
  └─ rt_drone_start → stalk | flip kick | zap | special

drone_stalk                       ; walk toward a random close/med/far band
  ├─ every tick: drone_beware     ; react to what he is visibly doing
  ├─ corner_escape_check          ; pinned at a wall → front-flip out
  └─ in range → cmf_close / cmf_med / cmf_far
```

`drone_beware` is the reaction engine. It fires only when the opponent's
`p_action` **changes** (`p_otheract` dedupes), waits `drone_react_delay`
ticks (6 at diff 0 → 3 at diff 9; never below 3, ~48 ms, so it is never
literally instant), then dispatches through:

```
catagory_table[action >> 8] → counter_*_table[action & 0ffh] → c_* handler
```

A `.long 0` in one of those tables means **the drone does not react to that
move at all** — it is the single most common bug class in this file, and it
now has its own audit (below).

### The reaction-table audit

`python tools/audit_drone_tables.py [--check]` cross-checks every live `act_*`
equate in MAINEQU against the counter tables and reports two failures:

| | |
|---|---|
| **HOLE** | the id lands inside the table but the entry is `.long 0` — the drone skips the move |
| **OOB** | the id lands **past the end** of the table — the lookup reads whatever `.long` follows it in the source and jumps there |

Every OOB found so far has been harmless purely by luck, because the next
table happened to start with a `0`.

Run against the tree as it stood before this pass, the audit independently
finds all nine bugs that were fixed by hand:

```
OUT OF BOUNDS (2)
  act_noob_tele      0x211  past end of counter_propell (len 17)
  act_jade_nitro_sd  0x61c  past end of counter_sitting_duck (len 28)
HOLES (7)
  act_jade_boom 0x112   act_jade_flash 0x115   act_noob_shadow 0x116
  act_sa_leggrab 0x124  act_getup 0x30a        act_upcutted 0x606
  act_shock_sd 0x613
```

The pattern is worth naming: **every piece of content added to this game
since the leak arrived with a reaction-table hole**, because nothing forced
the author to add the entry. Jade's boomerang and Noob's shadow moves — two
of the most-used custom moves — were invisible to the drone entirely.

Seventeen actions are deliberately unanswered, and each one now carries its
reason in `EXPECTED_SILENT` in that script (neutral states like `act_stance`,
states where we are already grabbed like `act_backbreak`, and fatality
sequences like `act_super_froze`). "The drone ignores this" is now a decision
on record rather than something nobody noticed.

### The think timer must never be a sleep

`drone_beware` is called once per tick from **inside** the callers' animation
loops — `drone_stalk`, `drone_approach`/`drone_retreat`, `drone_getup`,
`drone_land`, `drone_turnaround`, `stance_wait_*`, `drone_beware_mframew`.
Every one of them is `sleep 1 / next_anirate / drone_beware`.

So `drone_beware` may not sleep. The delay was originally implemented as a
`prcslp` right before the dispatch, which suspended the **caller** mid-loop:
`next_anirate` stopped being called, the fighter held one sprite frame, and
the x velocity `drone_walk?_setup` had already stamped kept dragging him
across the floor. It stretched every get-up, landing and turnaround animation
by 3–6 ticks, and it was *worst at diff 0* because that is where the delay is
longest — exactly backwards, and an animation rate that depends on difficulty
is wrong on its own terms.

It is now **armed, not slept**: the first sighting stores the delay in
`p_react_wait` and returns, the caller keeps animating, and each following
tick lands in `bew_pending`, which ages the timer by one and dispatches when
it runs out. Same reaction time, no stall. Measured A/B with
`tools\run_drone_walk_fluidity_test.ps1`:

| | worst walk hold | holds over the authored walk rate |
|---|---|---|
| sleeping delay | 10 ticks | 7 |
| armed timer | 4 ticks | **0** |

`p_react_wait` is process data and is **not** cleared when a process block is
recycled, so `bew_pending` treats any value above the largest table entry as
"not armed" instead of trusting it.

## The opponent model — learning and prediction

The drone builds a read on the player from **committed animations only**. It
never looks at a switch to decide anything. A person at the other cabinet has
exactly this information and builds exactly this kind of read from it.

The stock mechanism was the six-entry hit queue (`count_q_repeats`), and it
only ever recorded moves that **connected**. So the drone learned nothing from
a move it blocked or one the player whiffed — which is most of what a player
shows you.

### What it stores

Sampled in `drone_beware` at the moment the opponent's `p_action` changes —
the signal that was already there. Per watched player (RAM.ASM):

| | |
|---|---|
| `p?_hab[class][band]` | "what does he do at this range" — 8 classes × 3 range bands |
| `p?_bigram[last][class]` | "what does he do *after* doing that" — this is the predictor |
| `p?_lastcls`, `p?_predcls` | the last class seen, and what we expect next |

The eight classes (`dc_*`, `.set` at the top of MKDRONE.ASM) are deliberately
coarse: projectile, air, low, high, uppercut, special, turtle, neutral. Raw
action ids are useless for learning, because a player who "always jumps in"
does it with four different ids and the model would count four rare events
instead of one habit. Uppercut gets its own class — it is *the* punish.

`drone_class_of` returns `dc_none` for anything that was not a choice he made
(being hit, frozen, speared, sitting in a recovery). Learning from those would
just teach the drone its own habits.

### Reinforce and fade

On each sighting the earned cell gets `+4` and **every other cell in that row
fades by 1**. That second half matters more than it looks. The first version
only halved a row once a single cell got heavy, and measured against a
scripted opponent it took ~70 sightings for a real pattern to outvote thirty
seconds of earlier noise — the drone was still fighting the player you were
two minutes ago. Fading gets there in about fifteen, for one eight-word loop:

| | halve-on-cap | reinforce-and-fade |
|---|---|---|
| row after learning "jump → sweep" | `low=137` against 117 of leftover noise | `low=240` of 240 |
| predicted correctly | 48% | 93% (100% once learned) |
| confidently wrong | 0 | 0 |

A player who genuinely mixes two answers keeps both cells alive, no majority
forms, and the model correctly reports that it does not know.

### What a correct read buys — and nothing more

`drone_predict` needs **both** a diff-scaled minimum of evidence
(`drone_pred_floor`, unreachable at diff 0 — the easiest drone never reads you)
**and** an outright majority in the row. Then:

- `drone_beware` shaves **one tick per confirmed step** off the think timer,
  floored at 2
- `react_jump_table` scales the counter roll by the same streak
  (`pred_counter_bonus`: +200 / +300 / +400)
- `drone_stalk` picks the range band the profile argues for (`drone_pick_band`)

It never acts before the move it is answering has started. The band choice is
the most human and least visible part: the player never sees a reaction he did
not earn, the CPU is just already standing somewhere annoying.

### Every step subtracts reaction time (`p?_predrun`)

`p_predhit` is **not a flag** — it carries the streak: how many predictions in
a row have now come true, capped at `predrun_max` (3). One correct guess is a
coincidence and is worth almost nothing. A string the drone has watched you run
three times is a string it is entitled to answer on the second step rather than
the fourth, and that is exactly how a person gets faster at a pattern.

```
delay = drone_react_delay[@diff] - predrun      ; floored at 2 ticks (~32ms)
```

**A single miss pays the whole thing back.** `drone_learn` clears the streak the
moment a prediction is wrong, so one deliberate mixup puts the CPU back to
reading you no faster than it did at the start of the round. A prediction that
was never made (`dc_none`) is silence, not a miss, and leaves the streak alone.

The floor is what keeps this honest. However well the drone has read you it
still waits for the animation to start and still needs ~32ms to act on it —
the streak shortens the notice period, it never removes it.

Measured (`tools/run_drone_model_test.ps1`): after 45 s of *random* input the
model formed an opinion **0 times out of 14** — the confidence gate holds. On
a repeating pattern it reached **100%** correct and was **never once
confidently wrong**. Being silent and being wrong are completely different
failures, and the harness scores them separately.

### Memory span

The read carries across the three rounds of a match and is **halved at the
start of each new match** (`drone_model_newmatch`, called from `round_init`
when `round_num` comes up 1 — `end_of_match_chores` clears it, so that test
means "new opponent"). Round 1 is a clean fight; by round 3 the CPU has your
number; a new tower opponent starts near-blind.

### Adapting when the man changes (`drone_morph_watch`)

Everything above is keyed by **player**, not by character — which is wrong for
exactly one fighter. Shang Tsung's whole character is that he stops being the
man you were reading. `ochar` lives on his object and changes the moment a
morph completes, so `drone_learn` compares it against `p?_lastchar` on every
sighting; a mismatch means the profile describes somebody who is no longer
there.

The read is **quartered, not wiped** (`drone_model_fade`). A player's own
habits survive a morph — a man who jumps at you jumps at you whoever he is
wearing — so the shape is kept and the confidence is not. Two morphs with no
new evidence and there is effectively nothing left, which is correct. The
sequence state (`lastcls`/`predcls`/`predrun`) is dropped outright: it
described a moveset that no longer exists.

This covers the round boundary for free. Shang reverts to himself at the start
of a round, so the first thing watched in round 2 disagrees with what round 1
ended on and the stale form's read is dropped there too.

`p?_lastchar` initialises to `0ffffh` in `drone_model_newmatch` — "not looked
at him yet". Any real `ochar` there would make the first sighting of a new
match read as a morph and fade a model that had only just been halved.

## The punish matrix (pass 13)

> "The AI should anticipate the matrix of moves they are able to be punished,
> like in chess."

Every whiffed or blocked move in MK2 drops the actor into a `06xx` "sitting
duck" action. That action *is* the punish window, so how a window should be
answered is a property of the window — which means it belongs in a table next
to the action ids, not in whichever handler happens to be wired up.

Before this pass all of the shared `06xx` handlers funnelled into one routine:
roll the dice, uppercut if it reaches, otherwise sweep. That treats a **whiffed
uppercut** — the longest recovery in the game, and the reason "don't throw
uppercuts at nothing" is the first thing anybody learns — exactly like a
**knee**, which is over almost before you have seen it.

### `sd_punish_tier` — one row per `06xx` action

| tier | window | answer |
|---|---|---|
| 1 | short | a jab, and **only** from a range already stood in. Never travels — a sweep is 20-odd ticks of commitment and throwing one at a knee recovery gets you counter-hit. |
| 2 | ordinary | what the drone always did: uppercut if it reaches, else sweep, else the character's own travelling punish (`punish_from_range`). |
| 3 | long | worth crossing ground for. Uppercut preferred close **because it launches**, so the juggle engine turns one read into a combo. Out of range: the character's travelling punish, then a rolled walk-in (`rpt_heavy_walkin`) and an uppercut. |

`0` means "no row routed here" and reads as tier 2 — the historical answer — so
the table is safe to extend one entry at a time.

Tiers are **authored from what the move is, not measured frame by frame.** The
picker degrades gracefully on purpose: every tier ends in the same
`does_stk_reach` test and the same fallbacks, so a mis-tiered entry costs at
worst the answer the flat version would have given.

`tools/audit_drone_tables.py` now checks that `sd_punish_tier` has exactly as
many rows as `counter_sitting_duck`, that `sd_tier_max` matches the last index,
and that every value is 0-3. All three would fail silently otherwise, and this
codebase has a long history of short tables reading off their own end. The
check was validated by breaking a copy of the tree: it caught both the short
table and the stale `sd_tier_max`.

### Pointing the same matrix inwards (`drone_risk_ok`)

The other half of chess is not "what can I take" but **"if this does not work,
what does he do to me"**. A special is the most expensive thing the drone can
throw — blocked or whiffed it lands in the same `06xx` states the drone itself
hunts on the other side — so throwing one inside the range of a man who has
been answering with an uppercut is handing him a turn.

`drone_special_start` now prices that first, using the read it already has: his
*demonstrated* close-range habit, never his inputs.

**Carry clear routes to `drone_stalk`, not to a guard.** That distinction was
paid for in Kahn's overhaul, where replacing swings with blocks cost the first
matches ever lost — a guard is a turn nobody takes. Walking to a range where
the special *is* safe is the move a person makes, and it keeps the initiative.
`rpt_risk_hold` is deliberately low and zero below diff 3: a CPU that never
gives you a whiffed special to punish is not more fun, it is just quieter.

### Matchup sense before any habits exist (`ochar_threat_band`)

The habit model is empty at the start of every match and thin for the first
twenty seconds — exactly the stretch where a person is *not* thinking from a
blank slate. He already knows he does not want to stand at sweep range against
Baraka, and that Liu Kang's two fireball heights beat standing still.

`drone_pick_band` now falls back to a per-`ochar` band prior when the learned
read has nothing to say. That is knowledge about the fighter on the other side,
not about the man holding the stick, and reading it off his `ochar` is as
honest as reading his health bar. It sits on its own much lower roll
(`rpt_matchup_band`) — a prior is a lean, not a rule, and a CPU that opens every
Kitana match by marching to the same spot is one more pattern to learn. Real
habits are checked first and always outrank it. Bosses and the secret fighters
carry `3` = no opinion.

## Shang Tsung adapts with every morph

Three separate mechanisms, because "Shang adapts" means three different things
depending on which side of the screen he is on.

**1 — Facing him:** `drone_morph_watch`, above. The read follows the fighter.

**2 — Choosing the morph:** `do_random_morph` (MOVES.ASM) already picked by
matchup, sampling `matchup_odds` best-of-N by difficulty. That answers "who
beats the character he selected" and stops there. The other half of what a
Shang player is choosing between is **"who beats what he is doing"** — a Kitana
who never stops throwing fans and a Kitana who never stops jumping want
different answers out of the same chart column.

`drone_set_morph_hint` (MKDRONE) reads the dominant habit — far band first,
since the morph is rolled from far out and zoning is the habit a morph most
directly answers — and publishes it in `drone_morph_hint`. `morph_answers` then
adds a few points of matchup per candidate:

| he… | wants |
|---|---|
| zones | teleports and floor-travelling gap closers — Scorpion is *the* answer to a fireball |
| lives in the air | anti-air — Kung Lao's spin, Sub-Zero's freeze |
| works the floor / pokes | reach and an overhead — Baraka's blades, Kitana's spin chop |
| mashes uppercut | stop walking into it: a zoning game |
| throws specials | long recoveries to punish, so: the best punishers |
| turtles | chip and mixup — Jax's pound, Mileena's roll/teleport split |

The scale is small next to the chart (which spans 2..18), so the read **tilts**
the choice and never makes it: a 6 moves a fighter up a tier but cannot turn a
9-1 loss into a pick. `dc_none` leaves the chart to decide alone, exactly as
before.

The hint travels through a global rather than a register because the dispatch
runs through `local_drone_do_a0` / `do_a0_tbl`, and because a new cross-OBJ
call into MOVES.ASM is precisely the shape that trips the GSPA quirk MKDRONE
already routes around.

**2b — Being himself is an answer too.** `drone_unmorph` (MAINEQU.ASM).

Candidate 6 — Shang's own form — used to be remapped to Mileena inside
`drm_sample`, because before the Block+Up+HK gesture there was no way back
into his own form except the 0200h-tick timer: "become Shang" was not a move
he had. It is one now, and `shang_morph` routes it to `back_to_shang_form`,
the same routine the player's gesture and the timer already use.

`matchup_odds`' shang ROW was always real and always unused. What his own form
answers is the **fireball war** — three skulls per throw against anybody
else's one — which is why Cage and Reptile read 14 in it, and why `zones` and
`uppercut`, the two `morph_answers` rows that want a zoning game, are the ones
that got the high values in the new `sha` column. He answers a jumper worst of
anyone on the board: no anti-air special at all, only the uppercut everybody
has.

`tools/morph_pick_odds.py` computes the resulting distribution exactly (12^4
draws enumerated, not sampled). At diff 9 with no habit read he picks himself
**1.8%–14.2%** depending on the opponent — most against Raiden, least against
Jax, against a parity of 8.3% for twelve forms. A real answer, never a
dominant one; `--check` fails the build if that ever drifts above 30%.

Two things the rig found while measuring this
(`tools/run_drone_morph_choice_test.ps1`):

- **The 0200h auto-revert usually gets there first.** Over 19k frames at diff
  9 the drone took 8 morph decisions and the timer reverted him 10 times, so
  7 of those 8 decisions were taken while he was *already* Shang. He wears a
  form for ~9 seconds and is himself the rest of the time. The rig's
  `-HoldForm` suppresses the timer to make the choice observable; it changes
  no decision logic.
- **He was morphing into what he already was.** The draw scores candidates
  without reference to the form he is wearing, so a Mileena whose chart still
  said Mileena rolled Mileena and `shang_morph` spent a full helpless lane at
  far range becoming himself — 2 of 5 decisions in one run. `drm_done` now
  declines that. It is drone-only: a human arrives at `shang_morph` with a9
  already chosen, and what his input does is his own business.

A/B on the same seed: baseline and new build take their decisions at the same
frames (2342, 6231) and diverge at the second one, where the baseline became
Mileena and the new build reverted to Shang.

**3 — Noticing the form is losing:** `drone_morph_panic`. The one thing Shang
has that nobody else does is that a losing matchup is one animation away from a
different one, and a player who is being beaten uses it instead of sitting out
his own comfortable rhythm. Down by `morph_panic_lead` (035h, about a third of
a bar) the re-morph cooldown is halved. It reads the two life bars and nothing
else.

## Pass 13b — four things reported from real play

All four came from one live session and all four were real. Three were bugs,
not tuning.

### 1. Attacks continued after the round was already over

`duck_poke` chains three kicks with `sleep 3` between them and had **no
round-end test anywhere**, so a kick that took the last of a life bar was
followed by the rest of the string — the CPU standing over a dead man, still
poking at the floor while the announcer talks. `drone_rfp`, the shared jab
string, had the identical hole in both of its repeat arms.

New `drone_round_over` (carry set once `winner_status` is non-zero) between
the links of both. `winner_status` is the same word `drone_beware` already
refuses to react on, so this is not new knowledge — just knowledge the attack
loops never asked for.

**Any repeated-attack loop added here needs this test.** The routine is three
instructions; the bug it prevents looks like the game is broken.

### 2. Uppercuts "out of the blue" — two separate causes

**`djp_he_moved`** was the psychic one. `djp_gap_check` runs once a tick from
inside `stance_wait_yes`, so an uppercut fired straight off it is a *zero-frame*
answer to a one-frame event: you begin to stand out of a crouch block and are
already being hit. It was the only reaction in the file that skipped
`drone_react_delay`, while every other one waits it out in `drone_beware`.

Now it takes the same notice time as everything else (`stance_delay`, which
spends it standing in stance and animating, so the player *sees* the CPU
register the moment before it acts) and rolls `rpt_djp_punish` rather than
answering every time. A gap that is punished 100% of the time is not a bait —
it is a trap with one exit, and the correct play becomes "never move".

**`sdwp_heavy`** was the unprovoked one. The tier-3 walk-in committed to the
uppercut *before* the approach started, so the swing landed on whoever was
standing there on arrival — usually a player who had long since recovered.
From his side there was no provocation at all, because the thing being
punished happened a moment ago and across the screen. It now re-checks
`is_he_done_sd` and `does_stk_reach` after the walk: recover in time and you
beat the punish, which is what makes walking one in a gamble instead of a
guarantee.

### 3. The rest period (`drone_rest`)

A human does not flow from one committed sequence straight into the next. The
drone had no such beat: every offensive string ended in `reaction_exit`, which
drops it back into the decision tables on the very next tick. Strung together
that reads as a machine that never stops, which is what makes losing feel
unfair rather than hard.

`drone_rest` is a diff-scaled floor (`drone_rest_floor`, ~0.5s at diff 0 down
to ~0.13s at diff 9) plus 0–7 ticks of jitter, so the beat never lands twice
in the same place. Called at the end of `duck_poke`, `drone_jab_pressure` and
the rapid strings.

**It is not a blind pause.** `drone_stance_pause` runs `drone_beware` every
tick, so the drone is resting, not sleeping — it still blocks, still counters,
still answers a jump-in. A rest that made it deaf would be a free turn, and
free turns are what the Kahn overhaul measured as costing matches.

### 4. The jab string was a metronome with a hole in it

`drone_rapid_lo`/`_hi` were hard-coded to **seven punches at a flat 2-tick
spacing**, for every character at every difficulty. Both halves were wrong:

- **The gap.** Each link costs `mframew(3)` plus the spacing, and at 2 that
  total is wide enough to stand up and uppercut out of — so jab pressure meant
  to set up a throw instead handed the turn back, at a spot the player can
  learn. `drone_jab_rate` tightens it to 1 at the harder settings. The jab
  animation is untouched; only the pause between repeats moved.
- **The count.** A fixed 7 is a long metronome. `drone_jab_string` now rolls
  3–6, the same reason `drone_jab_pressure` picks 1 or 2 fresh every cycle.

Never 0 spacing: back-to-back with no gap is not a string a person could
throw, and it would make the low jab an unbreakable lock rather than pressure.

### `dsj` never sees zero

Both `drone_stance_pause` and `stance_delay` end in `dsj a10`, which
**decrements first** — so `a10 = 0` wraps to −1 and spins for four billion
ticks. That is a frozen fighter, not a short pause, and it looks nothing like
a tuning mistake. Both new call sites clamp `a10` to a floor *and* clamp
`@diff` to 9 before indexing (the direct `sll 4` table reads here do not go
through `ask_mr_diff`, which is where that clamp normally lives).

## Pressuring a crouch-blocker (`drone_jab_pressure`)

What a strong player does against someone crouch-blocking is one or two low
jabs and then *step in behind them*, over and over. The drone already threw
jabs here (`drone_rapid_lo`) but threw them standing still — and every blocked
jab shoves the victim back, so after the first exchange it was swinging at air
until the stalk loop dragged it back in. That reads as the CPU giving up on
offence the moment you crouch, and it is what made turtling work.

`close_he_is_ducking` now rolls `rpt_jab_pressure` into `drone_jab_pressure`:
up to three cycles of **two** jabs (not a seven-punch flurry — a string you can
punish if you stand up) followed by `drone_approach` back to `048h` if the
blocked jabs pushed him away. It bails early the moment he stops blocking,
because the normal close game has better answers than more jabs.

Fair in both directions: `drone_approach` bewares every tick, so poking back
out of the block still beats it, and the jab is the shortest and most
punishable thing in the game.

The cycle counter lives on the **process stack**, not a register — `a11` is
`drone_approach`'s argument and both callees run animation loops, so nothing in
`a0`-`a11` survives across them.

## A jab that keeps missing becomes a sweep (`drone_jab_whiff`)

Reported from play: *"the CPU isn't connecting on a low punch and keeps
whiffing."* It is exactly what the code did. `drone_rfp` bails out of a jab
string on the first strike that does not land, and nothing ever asked **why**
it did not land — so a drone parked a few pixels outside its own jab range
threw the same whiffed jab every time it re-decided, indefinitely. The low
punch is the shortest attack in the game, so the range that produces this is
narrow and easy for a player to sit in.

A person misses one poke, reads the range off it, and takes the legs instead.
That is what `drone_rapid_lo` does now:

* `combo_mark` before the string, `combo_connected` after it. **Own mark, not
  `drone_entry`'s** — this routine is also reached from the block punish and
  from `close_rapid_pick`, and the question has to be "did *this* string land",
  not "has he lost life at any point in this reaction".
* A whiffed string bumps `c_drone_jabwhiff` (p1:p2 words, RAM.ASM, cleared
  every round in `round_init_longs`). One miss is a mistake anyone makes and
  the jab is cheap enough to try again. **Two in a row is a range read**, and
  that is when `drone_jab_sweep` goes out.
* The count is zeroed *before* the sweep, so the drone goes back to jabbing
  afterwards. A CPU that only sweeps once it starts is as readable as one that
  only jabs.

**A block counts as landing.** Every character's low punch does 2 HP of chip
on block, so his bar moves and `combo_connected` says yes. Only a swing that
touched nothing at all feeds the counter — which is the only case a sweep is
the answer to. A *blocked* jab already has its own answer, one section up in
`drone_jab_pressure`.

`drone_jab_sweep` takes the sweep immediately if `does_stk_reach` already
covers him, otherwise walks in for at most `020h` ticks — `drone_beware` live
every tick — and gives up to `drone_reaction_exit` if he simply runs. It hands
off to `drone_sweep`, which re-tests the reach and holds guard rather than
swinging at a player who backed out to bait it.

### Measuring it: `tools/run_drone_jab_whiff_test.ps1`

Both fighters are pinned at a series of fixed gaps and each gap is watched for
~1200 frames.

**A drone jab is invisible from the outside.** `drone_rfp` calls
`init_special`, not `init_special_act`, so `p_action` never becomes
`act_lopunch` and nothing in the object or process says "that was a jab" — the
first version of the rig counted **0 jabs across five gaps** while the drone
was plainly throwing them all run. So the string's *outcome* is read from
`c_drone_jabwhiff` and the *response* from `p_action == act_sweep`.

Attribution is the whole point, per the shared-move rule: the drone already had
several ways to sweep, and the first rig counted 2 and 4 sweeps at gaps where
this feature cannot have fired. A sweep only counts if it starts inside the
45-frame window that opens when the counter resets — the only moment
`drone_jab_whiff` can have branched.

The rig must **not** top the bars up every frame: the drone judges its own
string by the opponent's life bar, so a per-frame refill erases the evidence,
every landed jab reads as a whiff, and the test passes for entirely the wrong
reason.

Measured (Liu Kang drone, diff 9): 10 whiffed strings across the run, sweeps
fired off the whiff at the two gaps where the drone engaged at all; 25/25 clean
on `run_battle_stability_sweep.ps1`.

**If this rig reports INVALID ("only N whiffed jab strings"), suspect the rig
before the jab.** On 2026-09-12 it went INVALID with every recent AI change
compiled out, and the jab code had not moved. The cause was the wrapped
`callr check_block_bit` (see the TRAP 30 section): at gap 60 - throw range - the
drone tried a throw, ran off into stray code, and did nothing for the rest of
the run (`whiffs=0 connects=0` at every later gap, 5 refills). A/B on one rig:
pre-fix INVALID with 2 whiffed strings; with `calla`, **PASS - 10 whiffed
strings, 5 sweeps, 2 off a whiff, 85 refills**, matching the shipped numbers.
`whiffs=0 connects=0` for a whole phase means the drone is stuck, not choosing.

## Held-button moves must cost the drone what they cost a person

A drone has no buttons, so any move a human has to *hold* is a place where the
AI can quietly get the payoff for free. `fan_check_hp_held` (MKZAP.ASM) did
exactly that — it read:

> drone thrower has no button to hold: give the AI its boomerang at diff 3+

so from diff 3 up **every** AI fan came back, forever, with no commitment and
no release point, while a human has to hold HP and is stuck in that decision.

The rule is now: the drone **commits instead of holding**. `get_fan_obj` rolls
`rpt_boom_hold` at the moment of the throw and stamps a duration from
`drone_boom_hold_ticks` into the fan's `p_store3`; `fan_check_hp_held` just
spends it down. Rolling zero means it tapped the button and the fan flies
straight past, exactly like anyone else's.

Audited the other held-button moves while here:

| Move | Hold mechanism | Status |
|---|---|---|
| Kitana fan boomerang | `fan_check_hp_held` | **fixed** — drone now commits up front |
| Sub-Zero ice tornado | `button_bit_check` on the real port | already honest (and not in AI offence) |
| Baraka spin (`do_spin`) | `am_i_joy` skips `spin_continue_check` | drone-unreachable — only `sa_slow_block` (a human 4-tap-block path) calls it. Latent infinite loop if it ever *is* wired to the AI; note it before doing so. |

## Throw discipline (`drone_body_slam`)

A drone throw is allowed only against a **neutral** opponent. The gate tests
the action *category* (high byte), so it covers every move in the game
including ones added later — the previous hand-written list of eight action
ids missed projectiles, all specials, every back+HP punch and the spin chop:

| Category | Meaning | Result |
|---|---|---|
| `00xx` (non-zero) | mid projectile throw | **guard** |
| `01xx` | any attack | **guard** |
| `02xx` | any body-propell special | **guard** |
| `06xx` | any sitting-duck recovery | **jab** |
| `07xx` | blocking | **jab** |
| `act_postattack`, `act_land` | recovery / landing (MK2 protects landings) | **jab** |
| airborne, `diff`=0 | — | jab |
| victim holds away or block | `is_stick_away` / `check_block_bit` | jab |

"guard" = `drone_block` (he is swinging, so put a block up instead of
mashing into it). "jab" = `drone_rapid_lo`, keeping pressure on.

**Frequency**: `drone_slam_frequency` was dead — `l_drone_slam` is cleared at
round start (`round_init_longs`, MAIN.ASM) and nothing ever stamped it, so
`get_tsl` answered "30 seconds ago" forever. It is now stamped on every
*attempt*, including ones the player escapes. That matters more than the
table values: without it the drone stands on top of you re-rolling the grab
every tick until your stick leaves "back" for a single frame — which is
exactly what a fireball motion does.

The same state rules are duplicated at `do_body_slam` in
[src/MKSLAM.ASM](../src/MKSLAM.ASM) so the paths that never went through
`drone_body_slam` (Smoke's speed-dash grab, throw reversals) obey them too.

## Move pacing (the `l_*` timers)

`get_tsl` / `update_tsl` (MKUTIL.ASM) implement "how long since this player
last did X". **The address they take is a PAIR of 16-bit words — p1 at +0,
p2 at +16 bits** (`addk 16,a0` inside both). So the RAM declaration must be
`.bss name,32,1`, and the variable belongs in `round_init_longs`.

Five timers were declared `,16,1` and left unused for thirty years:
`l_gslam`, `l_gpounce`, `l_gorofire`, `l_drone_fk`, `l_drone_zap`. Wiring one
up as-declared makes **every P2 drone — the CPU in every one-player game —
read and write the next variable in RAM.ASM instead of its own slot.** The
visible symptom is a CPU that stutter-walks: its cooldown never reads as
expired, so it takes the "on cooldown, do something else" branch forever.
All five are now 32 bits wide and round-initialised as longs.

What is paced, and what the drone does instead when a move is on cooldown:

| Move | Timer | Diff 0 → 9 | On cooldown |
|---|---|---|---|
| any AI projectile (`drone_zap_jsrp`) | `l_drone_zap` | 224 → 64 ticks | bounded 24-tick advance, then re-decide |
| flip kick (`drone_flip_kick`) | `l_drone_fk` | 240 → 96 ticks | `drone_block` |
| Kintaro body slam | `l_gslam` | 240 → 96 ticks | falls through to its normal close game |
| Kintaro pounce | `l_gpounce` | 320 → 144 ticks | falls through |
| throw (`drone_body_slam`) | `l_drone_slam` | 240 → 64 ticks | jab or guard |

`l_gorofire` is deliberately left unused: Kintaro's fireball funnels through
`drone_zap_jump` → `drone_zap_jsrp` and is already covered by `l_drone_zap`.

### A cooldown must never be visible

The player should not be able to tell a *denied* move from a move the drone
simply did not pick. So the denied path may not `stop_me`, hold a stance, put
up a block, or run its own walk-then-halt — all of those read on screen as the
sprite hitching. Both denied paths (`dzap_cool`, `dfk_too_soon`) do exactly
one thing: `reset_proc_stack`, set up the walk, and enter the stalk loop at
`dstk2` with **the close band forced**.

Forcing the band matters for two reasons. The drone then has to walk a real
distance before it next decides, so a run of denials cannot spin the decision
loop and restart the walk animation every tick — that is the pass-4
frozen-walk failure mode. And "I couldn't throw it, so I'm coming in" is the
read a person would give it anyway.

Things that looked reasonable and were wrong:

- `drone_approach` as the fallback — it loops until it reaches its target, so
  against a retreating player the drone commits to one long walk and never
  re-decides. One fireball and it stops zoning for the rest of the round.
- A hand-rolled bounded walk ending in `drone_reaction_exit` — `reaction_exit`
  calls `stop_me`, so it walked, stopped, walked, stopped.
- `drone_block` as the flip-kick fallback — defensible AI, but it holds a
  static guard for up to 35 ticks, which from a neutral decision reads as the
  CPU freezing.

### No projectile sooner than a player could throw it (`drone_zap_legal`)

`l_drone_zap` is the CPU's *own* pace. It was never the player's. A player's
projectile limits live in the MOVES.ASM **button handlers**, above `do_zap`,
and every CPU throw calls `do_zap` directly, so none of them applied. At diff
7–9 `drone_zap_frequency` is `060h`/`050h`/`040h`, while a player's Kitana fan
and Mileena sai are held to `080h`: the CPU out-threw anyone playing the same
character.

`drone_zap_legal` (MKDRONE.ASM) repeats each handler's test, keyed on the
`do_zap` index:

| zap | projectile | a player's limit | handler |
|---|---|---|---|
| `06h` | fan (Kitana, Khameleon) | `l_throw_fan` ≥ `080h` | `fn1lp3`, `kham_fan_test` |
| `07h` | sai | `l_sai` ≥ `saicool` | `fn2_hp_open` |
| `0ah` | fan lift | not on a helpless victim | `fn1hp4`, `khamhp_fanlift` |
| `0bh` | forceball (Reptile, Ermac) | one on screen | Reptile's LP handler |
| `0ch` | spear | `l_spear` ≥ `066h` | `sc_lo_punch` |
| `0dh` / `16h` | ice, standing / jumping | no ice out; airborne victim `l_freeze` ≥ `freeze_cooldown`, else `l_freeze_any` ≥ `freeze_ground_cool` | `sz_lo_punch` |
| `0eh` | floor ice | one out, victim not frozen, `l_pud` ≥ `0c0h`, `060h` from both edges | `sz_lo_kick` |
| `22h` | Jade's flash | `l_jade_flash` ≥ `080h` | Jade's flash handler |

Every other projectile has no handler limit for a player either. Limits that
live *inside* the MKZAP routine (Jade's boomerang, Reptile's air spit, the
timers the routines stamp themselves) already bind both sides. The one timer a
handler stamps, `l_sai`, is written for the CPU by `drone_zap_commit`.
`freeze_cooldown` / `freeze_ground_cool` moved from MOVES.ASM to MAINEQU.ASM
so both sides read one number.

**A refusal looks like the cooldown**, for the reason above: `drone_zap_jsrp`
leaves through `dzap_cool`. The direct callers (`drone_pee`, `drone_wave`,
`drone_orb`, `drone_reverse_zap_jump`) leave the way a fighter with no
projectile does. The jump-throw asks twice, at takeoff (`daz_spend`, before
it spends anything) and at the release (`daz_legal`), and a refusal in the air
rides the jump out. `bfat_call` has to ask **before** its
`pull`/`pull`/`reset_proc_stack`, because nothing after the reset can refuse.

Measured 2026-09-13, `tools/run_drone_airzap_test.ps1 -Char
kitana,mileena,scorpion,subzero,reptile`, diff 9, idle human. `HUMAN FLOOR`
is the shortest gap between two throws of that one projectile, ground or air:

| char | throws | shortest gap | a player's limit |
|---|---|---|---|
| Kitana (fan) | 7 | 213 | 128 |
| Mileena (sai) | 7 | 171 | 128 |
| Scorpion (spear) | 7 | 168 | 102 |
| Sub-Zero | 9 (8 air, 7 connected) | — | state-based |
| Reptile | 9 (5 air, all connected) | — | state-based |

No throw beat a player's limit, and none of them stopped throwing. This run
has no pre-change baseline, so it shows the limit holds, not how often the
gate refuses. If that matters, a refusal counter in `drone_zap_legal` (like
`debug1`'s jump-throw census) is the way to see it.

**Keep it in step.** A new limit in a MOVES.ASM projectile handler needs a
line here too, or the CPU skips it. Shao Kahn and Kintaro (MKBOSS) are not
covered: no player controls them.

## Air projectiles, and stringing a jump into what follows (pass 10)

Two things were missing, and they turn out to be the same missing thing.

### The drone could not throw from a jump

`drone_zap_jsrp` is the **only** route to a CPU projectile in the game, and
the table it reads — `zap_offsets` — is entirely ground zaps. So Jax's air
lightwave, Kitana's air fan, Mileena's air sai, Reptile's air spit,
Sub-Zero's air ice and Liu Kang's air fireball were player-only moves, and
the drone's whole zoning game was one standing throw you learn to jump in
about ten seconds.

`drone_air_zap_try` adds the jump route, off a new 17-wide
`air_zap_offsets`. It is **not a new allowance**: it spends the same
`l_drone_zap` cooldown as the ground throw, so the number of things thrown
per round is unchanged — what changes is that some of them now come out of a
jump, which is a different problem for the player. A standing fireball is
ducked or jumped; an air fireball has to be blocked or beaten in the air,
and it arrives with the drone's body right behind it.

Three flavours, picked by range, all ordinary human habits and all at the
joystick's own jump speed:

| Range | What it does |
|---|---|
| at or inside `air_zap_close` (`058h`) | back flip and throw — the escape-and-zone every Kitana player does when you get in her face |
| between the two | jump **straight up** and throw (`daz_jumpup` → the joystick's `do_jump_up`) |
| at or beyond `air_zap_runway` (`0b8h`) | forward flip at `-040000h` and throw, then keep walking in behind it |

**Rule: the drone only uses moves a player can make, sequenced the way a
player could.** Everything below that says "half speed" is history: from
2026-09-08 to 2026-09-13 the forward jump-throw flew at `air_zap_xvel`
(`020000h`), half of every other jump in the game, to shorten its travel. It
read as a slow, floaty flip nothing else does, and it was removed in favour of
choosing the straight-up jump inside the runway.

### The runway: it measured the gap it was leaving, not the gap it would arrive at

The first version of this had one threshold, `air_zap_close`, and it was the
wrong measurement. `air_throw_drop` **clears the x velocity at the release**,
so the drone stops dead where it throws and comes down there — the gap it
lands on is the gap it took off with *minus the whole forward travel up to
the release*, which is most of the jump.

Measured on the rig (`tools/drone_airzap_geo_subzero.log`, Sub-Zero air ice,
diff 9, an idle human):

```
jump taken at gap 094h  ->  released at 03ch  ->  landed at 03fh
```

`03fh` is inside a standing uppercut — `stk_lkuppercut` is `x_off 04bh` /
`x_size 035h`, so it covers an x gap of `016h..04bh` and reaches `040h`
straight up, and every character's is close to it. So the drone threw the ice
while standing on the player's head and then landed there holding nothing.
Reported as "the CPU does horrible air freezes right where I can uppercut
it", and correctly: it is a **range** bug, not a timing one.

**Shrink the travel, not the band.** At the stock jump speed (`-040000h`, the
flip kick's) the travel is `068h`, so a runway wide enough to survive it comes
out at `0b8h` — wider than the drone ever gets. Measured with that number in:
**`AIRZAP=0`**, the jump-throw simply stopped happening. So the approach now
goes in at half speed (`air_zap_xvel`, `020000h`). The arc is untouched — same
y velocity, same gravity, so it lasts the same time and releases at the same
height — it just does not cross the screen on the way, which is what floating
in behind your own fireball looks like anyway.

Then two guards, a prediction and a measurement:

* **`air_zap_runway`** — the takeoff prediction. It was `084h` (`air_zap_reach`
  plus `034h` of travel at half speed) and refused the band below it. **Now
  `0b8h`** (`air_zap_reach` plus `068h` at the flip's real speed), and it
  refuses nothing: below it the drone jumps straight up instead.
* **`air_zap_reach` (`050h`)** — the release gate, in `daz_scan`. The runway
  is a prediction; this is what he actually has when he lets go, and it
  catches what the prediction cannot see (he walked in, a corner cut the jump
  short). Skipped while the opponent is **airborne** — he cannot uppercut from
  up there.

**The juggle conversion is exempt, and needs its own scan to be.** Gating the
release on the gap deleted `drone_air_zap_juggle` outright (`CONVERT=0`): by
the time the drone reaches release height the victim he flip-kicked has often
touched down again, so `is_he_airborn` says no and the reach test refuses a
throw that was point-blank *on purpose*. The window test is now factored into
`daz_window`, and the juggle entry rides `daz_scan_juggle`, which checks the
window and nothing else.

**Census.** A jump-throw is rare enough that a 2-minute rig sees one or two,
so `AIRZAP=0` cannot distinguish "not rolled" from "gated off" — which is
exactly the trap the `0b8h` runway fell into. `drone_air_zap_try` now counts
into `debug1`: low byte = decisions that reached the range test, high byte =
the ones the runway refused. The rig prints it as `AIRZAP DECISIONS`.

### Measured, jump-up version (2026-09-13, diff 9, 260s, idle human)

`tools/run_drone_airzap_test.ps1 -Char subzero,kitana,jax,liukang,raiden`.
A straight-up throw shows as takeoff = release = land.

| char | zoning throws | connected | jump_up / reached | release / land gap |
|---|---|---|---|---|
| Sub-Zero | 5/5 safe (+2 juggle) | 7/7 | 5 / 5 | 152–161 |
| Kitana | 4/4 safe (+1 juggle) | 5/5 | 4 / 4 | 147–160 |
| Jax | 4/4 safe (+1 juggle) | 5/5 | 4 / 4 | 157–162 |
| Liu Kang | 3/3 safe | 3/3 | 2 / 3 | 92–157 |
| Raiden (control) | 0 | — | 0 / 0 | — |

Liu Kang's one forward flip (`takeoff=180 release=92`) is the full-speed
band: 88px of travel, released outside `air_zap_reach`. The rig samples the
gap a few ticks after the decision, so 180 there is the `>= 0b8h` decision.

### Measured, half-speed version (2026-09-08, superseded)

```
GEO #1  takeoff=60   release=0    land=9     juggle (exempt)
GEO #2  takeoff=154  release=110  land=110   ok
GEO #3  takeoff=151  release=107  land=107   ok
GEO #4  takeoff=107  release=31   land=49    juggle (exempt)
GEO #5  takeoff=154  release=110  land=110   ok
GEO #6  takeoff=148  release=104  land=104   ok
AIRZAP DECISIONS: reached=4  refused_no_runway=0  (taken=6)
```

Every zoning jump-throw now releases and lands at a gap of `104`-`110`,
outside the uppercut, where the same decisions used to release at `60` and
`0`. `refused_no_runway=0` says the takeoff gate is not paying for that with
refusals — the halved approach speed is doing the work.

Across the table, `tools/run_drone_airzap_test.ps1` at diff 9, 200s each:

| char | zoning throws | release / land gap | runway refusals |
|---|---|---|---|
| Sub-Zero | 4/4 safe | 104–110 | 0 |
| Kitana | 3/3 safe | 109–113 | 0 |
| Jax | 5/5 safe | 100–112 | 0 |
| Liu Kang | 3/3 safe (+1 juggle) | 105–139 | 0 |
| Raiden (control, no air zap) | 0 | — | 0 |

The old **upper** limit (refuse beyond `d_far`) is gone. It was reasoning
about a jump-in *kick* — "just a jump he can watch and walk under" — which is
exactly backwards for a jump-in *throw*, whose whole job is to cover that
distance. Between the two bounds the forward variant had no legal range left
at all: it only ever fired inside `0c0h`, which is the band it cannot
survive. `cmf_far` is entered above `090h`, so the live forward band is now
`0b8h` and out, and `090h..0b8h` falls through to `far8`'s jump-in kick or
the ground throw.

`daz_backjump` is reachable from projectile avoidance, where the gap can be
anything; from `cmf_far` it is not, since that branch is above `090h` already.

Kitana and Mileena are deliberately listed with their *ground* zap index
(6 / 7): `do_throw_fans` and `do_throw_sai` test `am_i_airborn` themselves
and branch to their own `_air` variant, so this stays correct if either move
is ever retimed. The other four name the air routine outright.

It is rolled at two decision points rather than added to the tables as its
own branch: at the top of `drone_flip_kick` (a jump-in does not have to be a
kick — mixing the payload is what makes the jump a question instead of a
tell) and in `cmf_far`'s zoning branch. A character with no air projectile,
or one whose projectile is on cooldown, falls straight through to what it
always did.

**Liu Kang is the one special case.** `do_lk_zapair` ends in a plain `retp`
and leaves the *caller* to finish the arc, exactly as the joystick path does
in `lk_zapair`. Every other air zap ends in MKZAP's `air_throw_drop`, which
lands the fighter itself and never returns. So `daz_scan` carries a
flight-and-land tail after the `jsrp do_zap` that only Liu Kang ever reaches.

### An air move cannot return to its caller — and one place had been written as if it could

`drone_ajump_call` carried this, right after `jsrp do_flip_kick`:

```asm
	move	@diff,a0,w	; kick connected ? convert it like a
	cmpi	4,a0		; human: fireball while he's falling
	...
	jsrp	drone_zap_jsrp
```

**It never ran once.** `do_flip_kick` ends in `jauc do_land_animation`,
whose first act is `calla am_i_joy / janc drone_land` — for a drone that is
a *jump* into the landing loop, which ends at `drone_reaction_exit`. Nothing
ever came back. It is the shape of bug that leaves no trace: the code reads
correctly, assembles, and is simply never reached.

**This one was ours, not Boon's.** Stock `drone_ajump_call` (mk2-readonly) is
just `jsrp do_flip_kick / jruc drone_reaction_exit` — no conversion at all.
The block above was added by commit 885d406, in a shape that could never run,
and every pass since has read it as working AI. That is the same pattern this
file already names for reaction-table holes: **everything added to this game
since the leak arrived broken in a way nothing forced anyone to notice.** The
lesson generalises past this feature — if a new drone behaviour cannot be
pointed at in a harness log, assume it is not running.

The fix is the same mechanism the juggle scripts already needed for the same
reason: **arm the follow-up before the jump, collect it on the frame you
land.**

```
dln_zap    010h   he is still reeling: projectile on the way down
dln_press  011h   convert or keep walking in behind what I threw
```

`drone_land` now ends at `drone_land_next`, which shares `p_juggle_step`
with the juggle scripts — the same "resume when I land" idea at a smaller
scale. The two never collide because the ranges are disjoint:
`1..juggle_max_step` is a combo step, `dln_first` and up is a follow-up.
`drone_entry` clears the field at the top of every reaction, so a follow-up
armed for a jump that got interrupted is gone before the next one, and
`drone_land_next` consumes it exactly once regardless.

**Every follow-up re-checks the situation for itself** rather than trusting
the arm. `dlf_zap` throws only if `is_he_reacting` — if the kick whiffed he
is standing there free to punish a throw animation. `dlf_press` sweeps if
the projectile connected and it is in range, and otherwise just keeps
walking in. What was true when the drone left the ground often is not true
when it lands, and a drone that swings at where you *were* is worse than one
that does nothing.

`dln_count` must match the length of `drone_land_followups` — same trap as
`random_do`'s count, one short and the last entry is unreachable, one long
and the dispatch reads past the table.

### The drone barely jumped at you at all

Falling out of the above: **`rt_drone_start` is rolled once per round, at
round start.** `drone_1_proc`/`drone_2_proc` run `ochar_drone_start` exactly
once, and every reaction afterwards re-enters at `drone_entry` →
`drone_stalk`. So `drone_flip_kick` in that table is a round *opener*, and
every other flip kick in the game comes from the projectile-avoidance
reaction (`standard_proj` / `ochar_avoid_pro`).

Against a player who does not throw projectiles, the CPU therefore has **no
jump-in at all** after the opener. It walks the whole round and is beaten by
standing still and anti-airing the one jump it makes. Measured against a
completely idle opponent at diff 9, a Raiden drone jumped in **0 times in
6000 frames**.

`rpt_far_jumpin` puts one back where a person would use it — the far/zoning
branch of `cmf_far`, alongside the projectile decision it competes with. No
new pacing was needed: `l_drone_fk` already limits it, and a denied one
lands in `dfk_too_soon`, which keeps walking rather than showing the player
a cooldown. It is deliberately never the majority answer even at diff 9: a
drone that jumps every time you back off is exactly as readable as one that
never jumps, and much easier to uppercut.

Same rig, after: **7 jump-ins, 4 of them converted** into a projectile on
landing.

Both rows below are the same rig (`run_drone_airzap_test.ps1`, zone mode,
diff 9, 6000 frames against an idle opponent), before and after
`rpt_far_jumpin` only:

| | before | after |
|---|---|---|
| Raiden (no air zap — isolates the jump-in) | **0** flip kicks, 6 projectiles | **7** flip kicks (4 converted), 8 projectiles |
| Kitana | 0 flip kicks, 8 air fans + 11 ground | 1 flip kick, 5 air fans + 2 ground |

Kitana's throw count moving around between those two runs is the RNG stream,
not a trend — the jump-in roll spends a far-range decision the projectile
would otherwise have taken, and one run is one sample. See the RNG section
below before reading anything into a single number here.

### Measuring it

`tools/run_drone_airzap_test.ps1` runs in two modes:

- **zone** — an idle human; counts projectile actions split by the drone's
  *height off the floor*, not by action id. Jax's air lightwave stamps the
  same `act_jax_zap` as his ground wave, so the action alone cannot tell
  them apart. Raiden/Scorpion are the honesty control: no air zap, so any
  "air" event there means the height test is wrong.
- **convert** — the human throws Liu Kang fireballs so the drone actually
  flip kicks. This is the only way to see one: **`rt_drone_start` is rolled
  once at round start and never again**, so every flip kick after that comes
  from the projectile-avoidance reaction (`standard_proj` /
  `ochar_avoid_pro`). An idle opponent produces exactly zero, which is why
  the pacing harness scores the flip kick `need=0` — that is a property of
  the rig, not of the drone.

Both modes also watch the arm slot itself, so "did it arm" and "did the
follow-up then find a legal move" fail separately.

Results, all measured on the **shipping build** (2026-08-06), zone mode, diff
9, 6000 frames against an idle opponent. `arm` columns are the follow-up slot
actually being written and consumed:

| Drone | air | ground | jump-ins | converted | arm zap / press |
|---|---|---|---|---|---|
| Liu Kang (`act_lkzap_air`, the `retp` tail path) | 10 | 4 | 1 | 0 | 1 / 10 |
| Sub-Zero (`act_air_ice`) | 6 | 4 | 0 | 0 | 0 / 6 |
| Kitana (`act_air_fans`) | 5 | 2 | 1 | 1 | 1 / 5 |
| Jax (`act_jax_zap` at height 50) | 4 | 4 | 1 | 0 | 1 / 4 |
| Mileena (`act_air_tsai`) | 3 | 5 | 2 | 2 | 2 / 3 |
| Reptile (`act_air_spit`) | 3 | 1 | 1 | 0 | 1 / 3 |
| **Raiden (control)** | **0** | 8 | 7 | 4 | 7 / 0 |
| **Scorpion (control)** | **0** | 5 | 6 | 1 | 6 / 0 |

Convert mode (Scorpion, the human throwing Liu Kang fireballs): **6 flip
kicks, 6 armed, 4 converted** 23-25 frames after landing. The two that did
not convert are the honesty gate doing its job — `dlf_zap` requires
`is_he_reacting` on the landing frame, so a kick that did not leave him
reeling does not get the free throw.

Note the two control characters score the *highest* jump-in counts. That is
`rpt_air_zap` falling through for them: a fighter with no air projectile
spends every jump decision on the kick, while Kitana or Liu Kang spends about
half of them on a throw instead. Both are jumping in the same amount; only
the payload differs, which is the point.

Individual counts move around run to run — one run is one sample of a
reshuffled RNG stream. What the harness asserts is categorical (did it ever
throw from a jump; did the control never), not the count.

## Anti-air: punishing the jump-in (pass 11)

Jumping in is the most common thing a player does, and the drone's entire
answer to it was to stand still with a guard up (`stalk_airborn_med`/`far`)
or throw a high kick that trades at best (`rt_airborn_close`). **The uppercut
is in neither list.** In MK2 the uppercut *is* the anti-air — strike table
`008h` reaches high, `upcut_striker` is live about two ticks after the
button, and it takes a quarter of a life bar. A person punishes a mindless
jump with it every single time; the drone never once did.

`drone_antiair_try` adds it, and reads nothing a player could not see: he
must be visibly airborne, visibly **coming down** (see the descent gate
below), `get_his_dog` must say he has fallen to within `antiair_height`
(`058h` — not at the top of his arc, where `008h` passes underneath), and
`does_stk_reach` must say the uppercut's own box actually covers him. If he never enters range **it does not swing.** A whiffed
uppercut is the most punishable thing in the game, so an anti-air that swings
at nothing is strictly worse than no anti-air at all.

**No cooldown timer**, deliberately, unlike the zap and the flip kick. An
anti-air can only happen when the *player* chooses to jump, so he is already
pacing it; a cooldown would mean the second jump in a row is free, which is
precisely the habit this exists to punish. `rpt_antiair` (0 → 600) is the
whole limiter.

### Where it had to go, and the measurement that got it there

It was first hooked into `stalk_airborn_check`, which only runs once the
stalk loop has closed to its chosen band. But `drone_beware` samples the
opponent's action *every tick from inside that same loop*, so a jump
dispatches `c_angle_jump` → `angle_towards_me` long before the band check is
reached. The hook was very nearly dead code. It now sits at the top of
`angle_towards_me` — where jump-ins actually arrive — rolled ahead of the old
answers, so a losing roll still gets `drone_quick_jupk` or the character's own
air reaction. The `stalk_airborn_*` hooks stay as well, for the case where
`drone_beware` did not dispatch.

Measured with `tools/run_drone_antiair_test.ps1` (a scripted jump-in every
170 frames, Raiden drone, nothing else happening):

| | diff 9 | diff 0 (control) |
|---|---|---|
| jump-ins | 44 | 20 |
| met with an uppercut | **15 (34%)** | **0** |
| connected | 11, 40 damage each | — |
| swung at nothing | **0** | 0 |

34% against a 60% roll is the honest gap: a roll that wins can still find no
range before its patience runs out, and that case correctly produces no
swing. Diff 0 scoring zero is the difficulty gate proving it is real.

40 damage is a quarter of the 161-point bar, so a punished jump-in costs
real money — but four in ten still get through, and jumping stays a genuine
option that is merely no longer free.

> **Those numbers are the pre-descent-gate build.** Roughly four in ten of
> the swings they count were illegitimate — see below.

### The ascent hole: why it "felt like cheating"

Reported from play: *"the computer feels like it's cheating on anti-air
uppercuts."* It was not reading inputs — `drone_antiair_try` only ever
touched position and height. It was answering the **launch animation**.

`antiair_height` was written to exclude the *top* of the arc, but
`get_his_dog` is small on the way **up** as well, so the gate passed on the
launch frames. And `drone_beware` samples the **action id**, which flips on
the first frame of the jump's crouch — several ticks before the body clears
the floor. So the drone could commit before the player was airborne at all.

Measured, Raiden diff 9, ticks from jump-start to swing:

```
1  1  2  6  9  9  14  25  25  25  25  25  42  42
```

Three swings at **1–2 ticks — 18ms to 37ms**, at `h1=27` and `h1=35`: still
rising. Six of the fourteen were ascent swings. Nothing a person does happens
in 18ms, and no difficulty setting makes that defensible.

The fix is two instructions in each of the three reach tests: `oyvel`
negative means still rising, so refuse. `drone_ajump_call` and the air zap
already did exactly this, for exactly this reason — the anti-air never got it.

| | before | after (4 runs, 2 seeds) |
|---|---|---|
| min latency | **1 tick (18ms)** | **25 ticks (457ms)** |
| ascent swings | 6 of 14 | **0** |
| met rate, raiden | 45% | 16% / 27% |
| met rate, scorpion | 25% | 22% / 17% |
| swung at nothing | 0 | **0 in 147 jump-ins** |

The rate roughly halving is the fix working, not a regression: Raiden's
*legitimate* baseline was 8 of 31 (26%), and he now runs 16–27%. The rig's
PASS floor moved 20% → 12% for the same reason — the old floor was calibrated
against a build whose count included the cheating swings, so it sat on the
post-fix mean and failed half of all runs by construction.

### A reaction pad was tried here and removed

The first attempt also put a reaction pad (4 ticks + `randu` 1..4) in front of
each style, reasoning that the styles poll every tick and so have *zero*
execution latency once `drone_beware` has noticed. The reasoning is sound and
the pad still did nothing, because **the swing tick is set by the arc, not by
when polling starts** — the style waits up to `030h` ticks regardless, so a
pad that expires early is invisible:

```
raiden    25 25 25 25 25 25        spread 0
scorpion  28 28 28 28 28 28 28     spread 0
```

Not one tick of the jitter reached the swing. It only shortened the polling
window (scorpion 25% → 18%) and perturbed `@rand` for every other drone
measurement in the build. If the frame-perfect repeatability is ever worth
attacking, jitter the **gates** — a few pixels on `antiair_height`, so the arc
crosses them on a different tick — not a poll that was going to wait anyway.

### Open: Shao Kahn has the same hole

`kahn_uppercuttable` (MKBOSS.ASM) was modelled on `is_he_uppercuttable` and
inherited the bug. It gates on a height *band* — `kahn_antiair_floor` `030h`
to `kahn_antiair_height` `070h` — and a rising jump passes straight through
that band, so it can commit on the ascent exactly as the drone did.
`kahn_knee_worth_it` has the same shape (`dog > 030h`, no descent test).

Narrower than the drone's hole was, because `kahn_antiair_min` `04eh` rejects
the near edge, but present. **Not fixed here on purpose:** Kahn's AI is
separately tuned to 12/12 at diff 9 and has its own rig
(`tools/run_kahn_jump_fly_test.ps1`, `kahn_jumpin_test.lua`); the two
instructions are trivial, re-validating the boss is not.

### It is not always the uppercut (`ochar_antiair`)

The pass above is written as though the uppercut is *the* anti-air for
everyone. For most of the roster it is. For four characters it is the wrong
move, and the move sheet says so in the same breath both times: **"Uppercut:
Weak / Roundhouse: Awesome"** for Sub-Zero, Reptile and Scorpion (*"his
roundhouse makes him almost impossible to jump at"*), and for Kung Lao,
*"standing HK can always knock someone out of the air, like the ninjas'
roundhouse."* A Scorpion drone answering jump-ins with his weakest button was
the roster's most repetitive tell. See [COMBO_SHEET_AUDIT.md](COMBO_SHEET_AUDIT.md) C2.

`ochar_antiair` is a 17-entry `.long` table read with `get_char_long`, and
**`0` means the uppercut** — so every unlisted row is not a gap, it is the old
behaviour byte for byte. Only four rows are non-zero. The three custom
fighters are deliberately `0`: Smoke, Noob and Jade postdate every source the
assignments come from, and a guess there would be indistinguishable from a bug.

Each row names a *style* routine, not a move, and the styles never return —
`drone_antiair_try` has already dropped its return address, exactly as it did
when the uppercut was hard-coded:

| style | move | strike table | height gate | distance gate |
|---|---|---|---|---|
| `aa_uppercut` | `do_uppercut` | `008h` | `antiair_height` `058h` | — |
| `aa_roundhouse` | `do_roundhouse` | `00dh` | `aa_kick_height` `048h` | `aa_kick_reach` `028h` |
| `aa_hikick` | `do_hi_kick` | `000h` | `aa_kick_height` `048h` | `aa_kick_reach` `028h` |

**Three things in that table are load-bearing.**

*The strike index is the move's own.* `does_stk_reach` is asked whether *this
particular attack's* box covers him, so the index has to be the one the move
stamps into `p_stk` (`do_roundhouse` → `00dh`, `do_hi_kick` → `000h`). Pairing
a reach test with the wrong strike table gives a drone that swings at nothing —
the one outcome the whole routine exists to avoid. That is why the test and the
move live together inside one style routine instead of in two parallel tables
that can drift apart.

*A standing kick is not an uppercut.* `008h` rises through the swing, so it
can take a man who is still well off the floor. A roundhouse and a high kick
are fixed at head height and travel up not at all, so reusing `058h` would
have them swinging while he is still above the boot. Hence `aa_kick_height`.

`048h` was the first value and it was letting through the top lip of its own
band. Counting only clean 30-damage hits, Scorpion at diff 9:

| | `h1` values |
|---|---|
| connected | 68, 68, 68 |
| did not | 72, 72, 72, 68, 68, 37 |

Every hit at 68; three failures sitting exactly on the 72 ceiling. `044h`
keeps the band and drops the lip — the test is `jrhi`, so 68 still passes.
Re-measured after the change: **8 met, 6 connected, 0 whiffs**, conversion
33% → 75%. One of the two misses was a `gap=78 h1=92` roundhouse outside both
gates and therefore not this routine's; excluding it, **6 of 7 = 86%**, the
same conversion as Raiden's uppercut.

### `does_stk_reach` is not `does_it_hit`

The finding that cost the most to get, and it generalises past anti-air.

First measurement of the roundhouse rows, Scorpion at diff 9: **11 anti-airs,
4 connected.** The rig reported zero whiffs, because it scores a whiff as
"fired with nobody within `0x70`" — and all eleven were inside that. The split
was in the log detail and it was total:

| | gaps |
|---|---|
| connected | 27, 27, 34, 39 |
| missed | 52, 67, 76, 83, 84, 85, 88, 111 |

No overlap. `does_stk_reach` had said yes to all eleven.

It is optimistic **by construction**, in two ways. It squeezes the victim to
**5/8** of his width (`dsr6`), while the collision that actually decides the
hit squeezes to a **quarter** in `sq_punch` — see
[the victim-box note](HITBOX_MODEL.md). And it tests **X only**, so a kick
pinned at head height gets full credit for horizontal overlap with an airborne
man's outstretched leg.

The uppercut hides all of this because its box rises through the swing and has
margin to spare. A kick has none, so the whole gap between "reaches" and "hits"
is downside: a roundhouse thrown at gap 83 misses and hands over a free punish,
which is precisely what `drone_antiair_try` exists to prevent.

Hence `aa_kick_reach` = `028h`. **Read the next section before trusting any
"it missed" number from this rig** — the first two attempts at this constant
were argued from a connect-metric that turned out to be broken in both
directions. What the value actually rests on:

- **Ground truth.** `stk_njroundh` is `x_offset=96, x_size=68`, so the box
  spans `oxpos+28` to `oxpos+96`, and `damage_hit=30`, `damage_block=8`.
  Those two damage numbers are the only unambiguous signal in the logs.
- Filtering four runs to drops of **30** (a clean roundhouse), true
  connections span **gap 8 – 39**.
- In the ungated run, roughly seven swings landed at gap 52 or beyond and
  **not one** produced a 30.

`028h` clears the furthest true connection and excludes everything never seen
to connect.

**A floor is missing and is a known gap.** The box's near edge is `oxpos+28`,
so standing on top of someone is a dead zone — the same shape as the
documented uppercut point-blank hole. Swings at gap 2 and gap 5 produced drops
of **8**, which is `damage_block`, not a clean hit. `aa_kick_reach` is a
ceiling only; nothing stops the drone swinging from inside the near edge.

**Do not "fix" `does_stk_reach` to match `sq_punch`.** It is also what decides
the sweep, `punish_from_range`, and the uppercut anti-air, all of which are
tuned around its current optimism. Gate the caller, not the primitive.

### The rig had to change too, and the change is the point

Watching `act_rhouse` instead of `act_uppercut` broke an assumption the rig had
never had to state: **the uppercut is essentially only ever thrown as an
anti-air, and the roundhouse is not.** The drone throws roundhouses from
reaction handlers and close-range mixups all match long.

The whiff branch had never consulted `live` (was the man actually jumping in),
which was harmless for the uppercut and badly wrong for a shared move — it
blamed `drone_antiair_try` for a roundhouse at `gap=116 h1=87`, outside *both*
of `is_he_rhouseable`'s gates and so provably not its work. Swings outside a
jump-in window are now counted separately as `other=` and reported, not scored.

The general lesson for any rig here: **when the thing you watch is also used
for something else, "it fired" stops being evidence.** You need a window, and
the window has to be in the failure branch as well as the success one.

#### The connect metric was wrong in both directions

Worth spelling out, because it cost three runs and produced two different
confident-looking wrong answers on the same ROM and seed.

`hp_at_uc` — "did the swing take health off him" — closed its window when the
action left `AA_ACT`/`AA_SD`. For the uppercut that is fine: `act_upcut_sd` is
a real state and holds the window open. For a kick there is no such state, so
`AA_SD` collapsed to `AA_ACT` and the window could shut in a frame, while
`do_roundhouse` does `sleep 10` then `retract_strike` *after* a hit.

| window | Scorpion, same ROM, same seed |
|---|---|
| tied to the action | **3 / 9 connected** |
| 40 frames | **9 / 9 connected** |
| 12 frames | what the rig does now |

Neither extreme was true. The 40-frame version counted damage from unrelated
attacks — it reported a connection of **40** on a move whose `damage_hit` is
**30**, and connections of **8**, which is `damage_block`.

**The amount is the discriminator, not the count.** `stk_njroundh` is 30 on
hit and 8 on block, so `connected for N` tells you which you measured — and a
value that is neither is a different attack leaking into the window. Always
read the amounts. A pass/fail on `connected` alone is not evidence for a move
that does not launch and is not exclusive to the path under test.

`ochar_antiair` is registered in `tools/audit_char_tables.py`, which enforces
the 17-row minimum — this is the `ochar=16` short-table crash class, and the
audit is the only thing standing between a 12-row table and a jump to garbage.
(`ochar_punish` was found unregistered while adding it, and is now covered too.)

### The blind swings next door (`airswing`)

Reported from real play: *"on a blocked Kung Lao dive kick the computer often
whiffs the punishment with a missed roundhouse kick."*

**The punish itself is fine.** Kung Lao's dive kick is `do_reptile_superk`
(MKPROP.ASM). Blocked, `super_rep_blocked` stamps `act_hh_sd` (`061ah`) and
flies him UP and slightly back, rolled in a ball, for the best part of forty
ticks. `c_hh_sd` answers that with `drone_approach` + `drone_uppercut_jump`
and it works — over eight seeds at Scorpion diff 9 the uppercut went **15 for
15**, connecting for 40 at `dog 56-57` every time.

The roundhouse is a *second*, unrelated swing, and **two** separate branches
throw one at an airborne man without ever asking how high he is. Every move
behind both of them is pinned at head height and none of them travels up.

**1. `rt_airborn_close`** — the stalk loop's answer to "he is in the air and
he is close", sitting immediately next to `drone_antiair_try`:

```asm
stalk_airborn_close
	callr	drone_antiair_try	; gated, 60% at diff 9, never returns
	movi	rt_airborn_close,a0	; ...and when the roll says no:
	jruc	random_do		;   high kick / ROUNDHOUSE / jab string
```

Pick one of three and throw it, with **no test of any kind**. Measured on the
first run of the new rig: a high kick out of this table at `gap=6 dog1=108` —
108 pixels off the floor, more than twice `aa_kick_height` — missed
completely and left the drone in `act_ret_kick` for Kung Lao to punish.

The blocked dive is what makes it common rather than rare: the branch fires
whenever the opponent is airborne and inside `d_close` (`050h`), and the ball
roll parks him airborne at `gap 0-8` for about 37 ticks. That is this
branch's entry condition, every time, for a third of a second.

**2. `air_rhouse_check`** — the wait behind `rh_ooa` and `hk_ooa` in
`med_out_of_air`, which between them are the *whole roster's* fallback answer
to a jump-in (`rh_ooa`: Raiden, the three ninjas, Jax, Smoke, Noob, Ermac and
both bosses; `hk_ooa`: Kung Lao, Shang, Jade, Khameleon). It tested his
**closest point** and nothing else — a jump-in's outstretched leg is inside
`040h` while the man is a hundred pixels up — and it swung when its own
patience ran out as readily as when the test passed.

This one also closes a loose end from pass 11: the anti-air rig had logged a
roundhouse at `gap=116 h1=87`, "outside *both* of `is_he_rhouseable`'s gates
and so provably not its work", and scored it as `other=`. This is whose work
it was.

#### The fix, and why it is subtractive in three different ways

`is_he_airswingable` is `get_his_dog <= aa_kick_height` **and**
`get_x_dist <= aa_kick_reach` — the two constants the anti-air styles already
carry, reused rather than re-derived, because they were measured onto exactly
this problem. `air_rhouse_check` gains the height half of the same test.

- **`rt_airborn_close` is tested once, not waited out.** Waiting for him to
  *become* swingable would turn a miss into a hit and make the branch a
  better anti-air than retail's at every difficulty — including 0, where
  `rpt_antiair` deliberately gives the player his jump-ins for free, and where
  this branch has no difficulty roll of its own. Tested once, the swing is
  either taken on the tick it was always taken or not taken at all.
- **A "no" there is `is_he_grounded` + `stance_wait_yes`**, word for word what
  `stalk_airborn_med` does with the same airborne man one band further out.
  An immediate `drone_reaction_exit` would re-enter `drone_entry` — and so
  `stance_setup` — once a tick for as long as he is in the air, which is the
  frozen-stance-frame shape `run_drone_walk_fluidity_test.ps1` and
  `ai_anim_debug.lua` exist to catch.
- **`rh_ooa`/`hk_ooa` now respect their own patience.** Both ignored the carry
  out of `stance_wait_yes_nb` and swung on the timeout. A narrower predicate
  cannot end that wait sooner than the old one did, so the pair of changes can
  only remove swings. (Difficulty is already handled upstream here:
  `c_angle_jump` bails at `diff <= 1` and rolls `rpt_angle_counter`.)

No new constants, no new tables, and `airswing 0` (MAINEQU.ASM) restores
retail — which is not optional decoration. **The thing being measured is a
MISS, and a miss is invisible unless you can turn the gate off and watch it
come back.**

#### Measured

`tools/run_divep_ab.ps1 -Airswing 0|1` does one side each: set the switch,
rebuild, package, sweep eight seeds, print totals. Scorpion diff 9, P1 Kung
Lao diving, `tools/divep_summary.py` for the adding up.

**The `act_hh_sd` window — what the report is about:**

| | `airswing 0` | `airswing 1` |
|---|---|---|
| blocked dives | 16 | 94 |
| swings taken | 17 | 93 |
| hit | 16 | **93** |
| **WHIFF** | **1** | **0** |

**Every swing at an airborne man, whatever put him up there** — a much bigger
sample, because neither branch cares why he is in the air:

| per move | `airswing 0` | `airswing 1` |
|---|---|---|
| roundhouse | 2 swings, **0 hit**, 2 whiff | 7 swings, **6 hit**, 1 whiff |
| uppercut | 15 swings, 15 hit, 0 whiff | 90 swings, 90 hit, 0 whiff |
| sweep | 8 swings, 4 hit, 4 whiff | 73 swings, 21 hit, **52 whiff** |

Read the roundhouse row against the uppercut row: **0 of 2 versus 15 of 15 in
the same runs.** That contrast is the whole finding, and it is not about
timing — the uppercut's box *rises through the swing* and the roundhouse's
does not, so one of them has margin at height and the other has none. After
the gate the roundhouse is 6 of 7.

Two honest caveats on those numbers. The sample sizes are lopsided (515 dives
versus 77) because the `airswing 0` runs all ended early on a rig wedge and
the `airswing 1` runs mostly did not — 2 of 8 stalled instead of 8 of 8 — so
compare the per-move rates, not the counts. And **52 of the 54 remaining
airborne whiffs were sweeps** — the third place, fixed next; see below.

#### The sweep: the third place, and height alone was the wrong test

With both kick gates in, **52 of the 54 airborne swings the drone still
missed were sweeps**. A sweep is a low attack, and `drone_sweep` — which every
sweep reaches, from `sweep_if_u_can`, `drone_jab_sweep`, the random tables and
the fatality fallback — only ever asked `does_stk_reach`, which tests X.

The obvious fix is a height ceiling, and **the data says it is wrong.** Logged
with the victim's height *and* vertical velocity at the sweep's first tick,
four seeds, Scorpion diff 9:

| outcome | count | `oyvel` (+ = falling) | `dog` |
|---|---|---|---|
| HIT | 13 | **+4.00 .. +5.00** | 48 .. 66 |
| WHIFF | 23 | −8.50 (rising) | 27 |
| WHIFF | 1 | 0 (top of the arc) | 43 |
| WHIFF | 9 | +3.25 .. +3.75 | 70 .. 78 |

The misses sat **lower** than the hits: 23 of them at `dog 27`, which is Kung
Lao's pop off a blocked dive on its way *up*. A ceiling low enough to refuse
those would also have refused all 13 hits. What actually separates them is
direction plus height: a sweep lands on a man it meets **on the way down**,
low enough to be on the floor by the time the box is out.

So `drone_sweep` now lets a man on the floor (`dog < 3`, `is_he_grounded`'s own
threshold) through untouched — that is the ordinary sweep — and asks an
airborne man to be falling (`oyvel > 0`) and no higher than `aa_kick_height`.
68 falls exactly in the 66/70 gap, so no new constant was needed. On the
measured rows that rule keeps all 13 hits and refuses all 33 whiffs. A no
takes the existing `dsw_hold` — guard for 8 ticks — which is what
`drone_sweep` already did for a man out of reach.

**Measured on the final build** (`airswing 1`, `airsweep 1`, 8 seeds, Scorpion
diff 9, `tools/divep_final`): **3 airborne sweeps, 3 hit, 0 whiff** — every one
of them falling at `dog 48` / `66` — and 9 of 9 in the blocked-dive window. It
is a small sample, because the runs end early on the rig's `act_bodyslam`
wedge (all 8 stalls classified WEDGE, none CRASH); the rule itself was set
against the 46-sweep distribution above, where it keeps all 13 hits and refuses
all 33 whiffs. `airsweep 0` (MAINEQU.ASM) takes the sweep half out on its own,
so it can be A/B'd without the kick gates.

#### A crash found on the way - root-caused and fixed

Chasing why the sweep-gate runs all stalled turned up a real **TRAP 30** -
the CPU parked in `illegal_opcode`'s `recovery: jauc $` (MKBUG.ASM), Dead Pool,
Scorpion drone, seed 31337. It was **pre-existing and intermittent**, and it was
not the hanger code, even though the faulting PC pointed there.

**Cause: a cross-object `callr` whose displacement wrapped.** When the drone
tries to throw a human who is not holding back, `drone_body_slam` swaps a13/a8
to the victim and asks `check_block_bit` - which lives in **JOY.ASM**. A `callr`
carries a 16-bit signed displacement in words (about +/-64KB). As the code grew
this one needed **-32838 words**; GSPLNK kept the low 16 bits without an error
and linked **+32698**, so the call landed at `ff9427d0` - 64KB forward,
mid-instruction in MKHANG's code, one instruction before the recorded faulting
PC `ff9427f0`. Every odd detail follows from that:

- the PC "in hanger code" is where the wrapped displacement points;
- `A13` naming the *victim's* process is the swap just before the call;
- "intermittent" is "only a throw attempt on a player not holding back";
- the saved return, reported as `drone_turnaround+0x134`, is really the local
  `drone_body_slam` 308 bytes further on - found with a real MKDRONE listing
  (assembled from a copy of `src/`), not estimated.

**Fix:** `calla check_block_bit`. Seed 31337 crashed on its first trial before
the fix and ran **8/8 clean after**, every run a full fight (78 dives) with no
wedges (`tools/run_bewguard_trials.py`).

**The `act_bodyslam` "wedge" is very likely the same bug.** On a build where the
wrapped call happens to land on valid instructions, the drone runs stray hanger
code mid-throw and hangs instead of trapping - which is exactly a CPU stuck in
`act_bodyslam`. Not yet proven on every rig that showed it.

**Guard:** `tools/check_pcrel_range.py --check` runs in Phase D. It reads every
16-bit PC-relative relocation (COFF type 25) out of every linked `.OBJ`,
recomputes the displacement against `mk2.map`, and fails on any overflow - it
flags exactly this call on the pre-fix image. Type 24 relocations look similar
and are *not* branches (complemented `cmpi` immediates); counting them gave 27
false hits. A bounds check was also added to `beware_lookup`, whose two table
reads feed a `jump a1` unchecked; it refused nothing while the crash still
reproduced, so it was not the cause, but it closes a real unbounded jump and
counts any refusal in `c_beware_oob` / `l_beware_oob`.

#### Adjacent, and NOT fixed

- **A floor.** `aa_kick_reach` is a ceiling only. The roundhouse box's near
  edge is `oxpos+28`, so standing on top of someone is still a dead zone —
  the same shape as the documented uppercut point-blank hole.

#### The rig, and four ways it lied first

`tools/run_drone_divepunish_test.ps1` drives Kung Lao's dive kick into a
blocking drone and counts every attack the drone starts while he is in
`act_hh_sd`, scored HIT or WHIFF on whether `p1_bar` actually moved. Getting
it to the point where its numbers meant anything took four corrections, and
every one of them produced confident nonsense first:

- **An A/B that never switched.** `run_divep_ab.ps1` flipped the equate with a
  double-quoted .NET replacement string, `"airswing`${1}.set`${2}$Airswing"`,
  where the group references and the parameter fought over the `$`; and it
  wrote with `Set-Content -NoNewline`, which failed outright in this host ("A
  parameter cannot be found that matches parameter name 'NoNewline'"). So the
  file was never written, **both halves of the A/B built `airswing 0`, and the
  two sides came out byte-identical** — dives, blocks, hits, whiffs, every
  number. Read as evidence, that says the branch under test never fires. It
  said nothing at all. The script now reads the line back and refuses to
  build if it does not say what was asked.
- **Do not stir `@rand` every frame.** `drone_antiair_test.lua` does and gets
  away with it; this rig did not. Walking the RNG through fourteen thousand
  arbitrary phases lands on the ones in
  [the attract-mode phase crash](#the-rng-trap-again--now-with-a-named-cause):
  one seed took MAME down with an ACCESS VIOLATION inside
  `midtunit_video_device::dma_draw`, and several wedged the fight outright —
  both fighters parked in `act_stance`, full bars, `winner_status` 0, `gstate`
  still FIGHTING and the positions frozen while MAME kept emulating. That
  reads exactly like a drone that has stopped reacting. One stir at the top of
  the fight gives the per-seed stream shift and nothing else.
- **`oxpos` is a WORLD x, not a screen x.** The player-spacing nudge was
  copied in with a `40 < x < 360` clamp; measured values on the Dead Pool run
  **620-870**, so the clamp rejected every nudge and the pair stayed welded
  together. An earlier version *snapped* the player to a fixed launch distance
  and that clamp put him hundreds of pixels the wrong side of the camera,
  which wedged the game inside 700 ticks on every seed and looked like a hang
  in the ROM. Bound a positioning write by the GAP, never by a screen
  coordinate — and never move a man the drone is currently **holding** (a
  victim in a throw reads `dog -1`, passes a "grounded" test, and nudging him
  parked the pair in `act_bodyslam` for the rest of the run).
- **Idle is `act_stance`, not zero.** Gating the input state machine on
  "action == 0" produced a run with ZERO dives.

## Duck-and-uppercut: the exploit that beat the whole game (pass 12)

Reported plainly: *"I can literally just duck and uppercut the whole way
through the game."* Measured with `tools/run_drone_pressure_test.ps1
-Style duckupper` — a player who crouches and uppercuts whatever walks in,
doing nothing else:

```
drone TOOK  1920 (11.92 life bars)   by third: 760 / 520 / 640
drone DEALT  470 ( 2.91 life bars)
VERDICT: EXPLOIT CONFIRMED - crouching and waiting beats the drone
```

### It cannot be reacted to, and must not be

`do_uppercut`'s strike goes live about **two ticks** after the button.
`drone_react_delay` floors at **three**. By the time `c_uppercut` dispatches,
the hit has landed. Any "fix" that shortens the think timer is reading the
player's switches with extra steps, so the reaction path is left alone.

### The geometry does the work instead

Every character's sweep out-reaches every character's uppercut:

| | front edge |
|---|---|
| sweep (`stk` 004h) | 085h (Kung Lao) … 109 (Kitana) |
| uppercut (`stk` 008h) | 075h (Liu Kang) … 90 (Jax) |

`duck_sweep_try` walks in only until the drone's **own** sweep box covers him
— 6 to 31 px short of where his uppercut covers the drone — and sweeps.
`does_stk_reach` is pure geometry against a box that is on screen for both
players; no switch is read.

**What made it reachable** was one line in `cmf_med`: the instant the
opponent crouched it threw the range band away and forced close mode,
walking the drone chest-first into the punish — discarding, among other
things, `drone_pick_band`'s explicit "he mashes uppercut → stay at medium"
that the opponent model had just worked out. The intelligence was there and
the plumbing defeated it.

### Then stay down

Standing back up hands a croucher the neutral he wanted. After the sweep the
drone crouches and pokes: two ducking low kicks, then the ducking high kick
to knock him away and reset. The ducking kicks are the right tools because
they out-range his uppercut (092h and 088h against 078h) *and* keep the drone
itself low, under anything thrown high.

**Every path that ducks must end in `drone_backup`.** `reaction_exit` does
not undo a crouch, so a drone left in `act_duck` cannot walk. Measured
without it: the drone parked at a fixed 79 px and stopped fighting for two
thirds of the run — and damage taken *halved*, which read like a win. It is
why this harness scores what the drone **dealt** alongside what it took. A
number that falls because the drone stopped playing is not an improvement.

### Two different questions, and conflating them cost a run

`ochar_duck_special` (what beats a crouching, *ready* opponent) and
`ochar_punish` (what punishes a *recovering* one) look like the same table
and are not:

- A horizontal special flying into a waiting crouch is a **free uppercut for
  the player** — Jax players are taught to ground-pound Raiden's torpedo out
  of the air for exactly this reason. So torpedo, shadow kick and square wave
  are **not** in `ochar_duck_special`, only floor-travelling or
  height-ignoring moves: low fireball, slide, roll, ground pound.
- Against a recovery that cannot uppercut anything, the horizontal moves are
  correct, and the torpedo lives in `ochar_punish` instead.

Getting this wrong put uppercut bait in the crouch table and cost 840 points
of damage taken (1240 → 400 once corrected).

### Result

| build | took | dealt | |
|---|---|---|---|
| baseline | 1920 | 470 | losing 4:1 |
| sweep spacing only | 960 | 2106 | 2.2:1 for |
| + specials, wrong table | 480 | 390 | **wedged — invalid** |
| + `drone_backup` | 1240 | 1414 | roughly even |
| + crouch-safe specials | **400** | **2320** | **5.8:1 for** |

Damage taken down 79 % from baseline, consistent across thirds.

## Punishing from range (pass 12)

Every recovery reaction punished the same way — uppercut if `008h` reaches,
else sweep, else shrug — and since the uppercut only covers ~078h, "shrug"
was what the drone did with most of the openings a player hands it.

A strong player does not think "punish with an uppercut"; they think in
character-specific guaranteed windows. A Jax player's notes list ten
situations where the ground pound is free, and most are ranges an uppercut
cannot touch: a landing opponent, a thrown projectile, a whiffed special.
The ground pound reaches all of them because it travels along the floor —
and so do Sub-Zero's and Reptile's slide, Cage's shadow kick, Raiden's
torpedo and Mileena's roll.

`ochar_punish` + `punish_from_range` wire that in at the two windows those
notes name first: whiffed-special recovery (`c_upcut_sd` and its aliases)
and a landing opponent (`c_land`, which previously gave up past 060h).

## Juggle combos (pass 13) — un-parked and shipping

A per-character combo script engine lives in the juggle section of
MKDRONE.ASM: `drone_juggle_try` gates an opening, `drone_juggle_run` walks
`ochar_juggle_scripts` (17 wide), and each step is one real move. It is now
`juggle_enable .set 1`.

### It had no hook on the jump-in path (fixed)

Reported from play: *"I'd like to see the computer do anti-air hi punches,
that can set up combos."* It already does — `drone_juggle_try`'s airborne
check calls itself *"the aa in aaHP"*, and `juggle_aa_punch` throws up to two
standing high punches (stk `#2`) before the script continues. The player had
simply never seen it, because it was reachable from exactly **two** call
sites — `c_kano_sd` and `flip_towards_land_close` — and neither is a jump-in.
The drone's answer to a jump was the uppercut, every time.

That is the pass-11 mistake a second time, in the same file: a good feature
hung off traffic that barely exists. `drone_juggle_try` is now also called
from the top of `angle_towards_me`, where jump-ins actually arrive.

**Ahead of `drone_antiair_try`, deliberately.** The uppercut rolls 60% at diff
9 and never returns when it wins, so anything behind it sees a jump-in only
four times in ten. Going first does not make the combo dominant, because its
own gates are much tighter than the uppercut's:

| gate | value | effect |
|---|---|---|
| `ochar_juggle_scripts` | 17 rows, bosses `0` | every non-boss fighter has one |
| `juggle_reach` | `050h` | must already be close; it never chases |
| `rpt_juggle` | 0 below diff 4, 600 at diff 9 | no combos on the easy CPU at all |
| `drone_juggle_frequency` | `0c0h` at diff 9 | ~3.5s between attempts |

So a close jump-in landing on a ready cooldown becomes a combo; everything
else falls through to the uppercut exactly as before. It does not reintroduce
the ascent hole either — `is_juggle_punchable` already calls
`q_he_heading_down`.

The other two hooks stay: they are different openings, not duplicates.

| | script | measured at diff 9 |
|---|---|---|
| Kung Lao | aaHP,HP → jump punch → **hat** | 10/10 openings taken, **62 damage (38% of a bar)** |
| Mileena | aaLP → roll → **sai** | 8/10 openings taken, **52 damage (32%)** |
| everyone else (14) | aaHP,HP → **their own projectile** | see "the whole roster" below |
| any of them, diff 0 | — | **0/10** — `rpt_juggle` is zero below diff 4 |

### The whole roster, not two demos

Two of seventeen fighters having a combo is not a feature, it is a demo: the
player learns that Kung Lao and Mileena punish a jump-in and nobody else does,
which teaches the wrong thing about the game. `generic_juggle_script` gives
every other fighter the floor version — **anti-air punch, then throw your own
projectile after him** — and the two bespoke scripts stay bespoke, because the
flip punch and the roll are combos people genuinely run with those characters.

It can be generic because the game is. **Strike index 2 is the high punch in
all eleven strike tables** (checked against hh/lk/jc/sa/fn/rd/nj/jx/st, and
stock `drone_rapid_hi` already dispatches stk 2 + ani `013h` for every
character without asking who it is), and `zap_offsets` gives every fighter a
projectile. Nothing in the script is character-specific, so nothing in it can
be character-specifically wrong.

**The bosses are deliberately excluded** (`ochar_juggle_scripts` slots `0ch`
and `0dh` stay `0`). Kintaro and Shao Kahn run their own offence out of
MKBOSS/MKSK against their own strike tables, which need not follow the
eleven-fighter convention this leans on — a generic launcher aimed at "index 2"
there is a whiff at best — and they have the most bespoke reaction code in the
game and the least to gain.

### The finisher's timing is per character, because projectile speed is

A single constant cannot serve the whole roster, and finding that out is the
useful part. The weapon has to **arrive** while he is at chest height, so a
fast one must be thrown late and a slow one early:

| | lead `038h` | lead `018h` | |
|---|---|---|---|
| Raiden | 11 | **33** | fast bolt — at `038h` it goes out under a man 50 px up and 118 away, ten throws, no hits |
| Sub-Zero | **32** | 22 | slow ice — wants to leave *earlier*, not later |
| Kung Lao | 62 | 62 | insensitive: the flip punch puts the victim so high the wait dominates |
| Mileena | 52 | 52 | insensitive |
| Jax | 22 | 22 | insensitive **and still missing** — his window is on the far side of `038h`; see below |

So it is a table, `drone_juggle_throw_lead`, read per character by
`is_he_throwable`. Four entries are measured; the rest are the `038h` default —
the value three of the four measured characters wanted, which makes it an
honest default rather than a guess dressed up as data. **A wrong entry costs
the finisher and nothing else**: the launcher still lands, and the projectile
is still a legal move thrown at a legal moment.

Sampled on the generic script, diff 9 — three deliberately different
projectiles, because "it works for Raiden" is not evidence that it works:

| | started | converted | |
|---|---|---|---|
| Raiden (fast bolt) | 10/10 | 9, **33 dmg (20%)** | |
| Sub-Zero (slow ice) | 8/10 | 8, **32 dmg (19%)** | |
| Jax (ground wave) | 8/10 | 8, **40 dmg (24%)** | needed its own lead — below |
| all three, diff 0 | **0/10** | — | control holds |

### Jax, and the knob that looked right and wasn't

Jax read as a hard failure at first: both punches land and the wave never
does. His high punch has the longest reach in the game (88) and pops hardest,
so by the time the wave leaves he is **185–213 px** away and falling — and he
was *insensitive to the lead in both directions*, 22 damage at `038h` and 22
at `018h`, which is normally the signature of "timing is not the problem".

The obvious reading was that two punches shove him too far, so the launcher
count briefly became a per-character table. Measured, that was the wrong knob:

| | | |
|---|---|---|
| 2 punches, lead `038h` | 22 | both punches land, wave misses |
| 1 punch, lead `038h` | 29 | wave lands — but one punch is only worth 11 |
| **2 punches, lead `060h`** | **40** | both land: he simply had to throw *earlier* |

He was insensitive between `038h` and `018h` because **his window is on the
other side of both of them**: by the time he has fallen to `038h` the pushback
has already carried him out of range, so every value below it measures the
same miss. Testing two points on the same side of a threshold and concluding
"not sensitive" is the trap, and the fix was one more table entry, not a
second mechanism.

The launcher-count table is **deleted** rather than left in place with every
row equal — a uniform table implies a per-character difference that does not
exist, and the next person to read it would go looking for one.

### One cause, wearing two costumes

Every dropped link in every build this feature has ever had came down to a
single mistaken assumption: **a link that connects moves the fighters**, and
the rest of the script was written as though it did not. It showed up
differently for each character, which is why it read as two separate problems:

| | what the script assumed | what was measured |
|---|---|---|
| Kung Lao | the flip punch leaves him in front of me | it hurls him **202 px** away — a second flip-in and a dive kick had nothing to reach |
| Mileena | the roll leaves him above me | the roll passes **through** him and comes out **113 px the far side** — her straight-up jump kick was aimed behind her |

So links 3 and 4 were not mistimed, they were aimed at a place the victim had
already left. That is also why forcing the odds to 100% never fixed it and why
the earlier note ("the victim lands before the drone can re-jump") only
described the symptom.

Both scripts now finish with `juggle_throw_finish` — the character's own
projectile, thrown after him. He is airborne, reeling, and a long way off,
which is precisely the situation a person throws something in. It funnels
through `drone_zap_jsrp`, so `l_drone_zap` gates it: a combo finisher is spent
out of the same projectile budget the drone's zoning comes from, never a free
extra shot, and a denied one just ends the combo invisibly.

### Three places a hand-picked constant stood in for a real box

The other half of the fix, and the part that generalises furthest. Each of
these was a number somebody chose that a strike table already knew:

1. **The launcher swung on a timer.** `juggle_air_max` was `050h`, i.e. "only
   start once he has already fallen to within a standing punch" — by which
   time `drone_rfp`'s three animation frames put the strike on a man standing
   on the floor. 8 of 10 combos started and *every one* died at link 1. The
   launcher now holds its stance and waits for him to fall into the punch
   (`is_hh_juggle_punchable` / `is_fn2_juggle_punchable`, the same shape as
   `drone_antiair_try`), swinging at `juggle_punch_lead` — **above** the
   punch's reach, because the strike is ~6 ticks out and he falls ~10 px a
   tick, so aiming at where he *is* aims about 60 px low.
2. **Air links fired on a distance constant.** `juggle_air_reach` was `070h`
   (112 px) while `stk_hhflipp` reaches 80. `juggle_air_hit` asks the move's
   own strike table via `does_stk_reach`, plus `juggle_air_lead` pixels of
   grace because a strike is not instant. Same class as the `c_hikick`
   ignore-window bug this file already names.
3. **The finisher was thrown at a man 116 px overhead.** A projectile flies at
   chest height. Thrown on the landing frame it sailed underneath him on all
   ten trials — a decorative zero on the end of a 38-damage combo. It now
   waits (`is_he_throwable`, bounded) for him to fall to `juggle_throw_height`
   first: **38 → 62 damage**, and it costs Mileena nothing because her roll
   already leaves him low.

`juggle_chase` went `0c0h` → `0100h` at the same time, and that is safe only
*because* of (2): the chase limit used to be the one thing standing between
the script and a whiffed link, so it had to be tight. Now every link asks its
own box, and `juggle_chase` only answers "is he still my problem" — which
`0c0h` was answering *no* to for a man visibly still in the air and dead
centre of Kung Lao's hat.

### What was deleted

`hhj_jumpkick`, `hhj_scan_kick`, `hhj_dive`, `hhj_scan_dive`,
`fn2j_jumpkick`, `fn2j_scan_kick`, `fn2j_airsai`, `fn2j_scan_sai`, and the
constants `juggle_air_reach`, `juggle_dive_height`, `juggle_sai_height` — all
of it code for links the geometry cannot deliver. It is deleted rather than
left parked because unreachable code in this file is a hazard in its own
right; see the `chd_pressure` fall-through that hung the game on three stages.

The harness's expected-link lists were updated to match, and its damage window
widened from 20 to 45 frames after the last link — 20 closed on the frame the
hat was *thrown*, which scores a connecting projectile as a miss.

### It does not stack with the anti-air

Both features answer a jump-in, so it is worth being explicit that a single
jump cannot eat both. They sit on different dispatch paths — `drone_antiair_try`
hangs off `angle_towards_me`, the juggle off `flip_towards_land_close` and
`c_kano_sd` — and `drone_antiair_try` already refuses outright when
`is_he_reacting`, i.e. when the man is airborne because the drone hit him.
That refusal was written for this: *"juggling is a separate feature with its
own rules."* On top of that the combo is paced by `drone_juggle_frequency`
(~3.2 s at diff 9), so the worst case is one combo per opening per three
seconds, at diff 4 and above only.

That is a hard punish for jumping in, and deliberately so — it is the single
habit this drone most needs to tax. Four in ten jump-ins still get through.

`juggle_debug` ships at 0. The juggle harness scores "how deep did the script
run" out of `@debug3`/`@debug4`, so it needs a build with that flag on; every
other harness below was run on the shipping build.

Three things in there generalise beyond this feature:

- **An air link cannot return to its caller.** Every air move ends in
  `do_land_animation`, which for a drone is `drone_land`, which ends the
  reaction. A script therefore leaves its next step in `p_juggle_step` and
  resumes in `drone_juggle_land` on the frame it touches down — consumed
  exactly once, or an ordinary jump lands mid-combo.
- **Judge "did that link connect" from the life bar**, not `pb_reacting`.
  The flag clears while the attacker is still in its own recovery, so any
  multi-frame launcher outlasts it. `get_his_strength` against `p_juggle_hp`
  is both correct and honest — the bar is on screen for both players.
- **`pdata` is now full** (`p_end` = `psdata`). Another process field needs
  one freed, not appended.

### The RNG trap, again — now with a named cause

`@rand` is re-seeded at **every round start** (MAIN.ASM, "Reseed RNGs at
round start") from `battle_num` and the win counters — all constant in a
scripted rig. A harness whose rounds restart therefore replays the *same*
stream, and one probability roll decides every trial identically. A 60% gate
scored **0/14** and read exactly like a broken gate. Harnesses that measure a
probability gate must stir `@rand` themselves every frame.

## Difficulty

`@diff` is 0–9. Two things scale with it:

- **Probability**, via `ask_mr_diff` against a 10-entry `.word` table.
- **Reaction speed**, via `drone_react_delay`.

Between rounds, `MAIN.ASM` adjusts it: `diff_advance_tbl` on a player win,
`diff_earier_drop` on a player loss (that table existed but was unused — the
drop was hard-coded to −1 at every cabinet setting, so the hardest DIP shed
difficulty as fast as the easiest one). `diff_min_tables` floors it per
tower position; bosses and secret fighters have their own minimums in
`boss_minumum_diff`.

## Probability tables added/changed in this pass

| Table | Diff 0 → 9 | Governs |
|---|---|---|
| `rpt_land_punish` | 0 → 500 (50%) | `c_land` — punish a jump landing we already stand next to |
| `rpt_okizeme` | 0 → 750 (75%) | `c_hitfall_sd` — walk a knocked-down player down |
| `rpt_proj_advance` | 0 → 800 (80%) | close the gap after ducking a projectile |
| `rt_drone_reverse` (JOY.ASM) | **0 at every diff** | throw-reversal roll — retired |
| `rpt_air_zap` (pass 10) | 0 → 500 (50%) | spend a jump on the air projectile instead of the kick |
| `rpt_far_jumpin` (pass 10) | 0 → 450 (45%) | turn a zoning decision into a jump-in |
| `rpt_antiair` (pass 11) | 0 → 600 (60%) | meet a jump-in with an uppercut instead of a block |
| `rpt_juggle` (pass 13) | 0 → 600 (60%) | convert an airborne opening into the whole combo; zero below diff 4 |

## Gotchas

- **This file has silent fall-throughs — never insert a routine between a
  conditional branch and the label after it.** `chd_pressure` ends
  `jrc drone_jab_pressure` and *falls through* to `charge_slam_check`. A block
  dropped in that gap meant a missed roll fell into the middle of the new
  routine and hit its `clrc / rets` tail, which popped the **scheduler's**
  frame, returned out of the process into `mainlp`, and tripped
  `system_lockup` — a hard hang on 3 of 17 stages at a constant frame.
  Disabling every `callr` into that routine did **not** help, because nothing
  was calling it: execution was falling into its body. Put new blocks after a
  `jruc`/`retp`, or make the fall-through explicit first. Same class as the
  MOVES.ASM `jj_right`/`charjmp` trap.
- **A new dispatch to a `drone_*` special must push a return frame.**
  `drone_kano`, `drone_slide`, `drone_square_wave` and `drone_lk_zaplo` funnel
  through `drone_do_a0`, and those routines end in `retp` because their human
  callers pushed one — `do_a0_tbl`'s own comment says so. Stock dispatches the
  same list from `avoid_proj_pro`, which does `movi reaction_exit,a0 / pushp a0`
  first ("setup for retp"). A bare `jump` there pops garbage and jumps into the
  void: it crashed the game on Mileena's roll, reported from real play, while
  the whole 17-battle sweep stayed green **because no battle used Mileena as
  the drone**. Both facts matter — push the frame, and add a battle.
- **A "distance to ignore this" window must cover the move's real reach.**
  `c_hikick` judged an ~088h-reach kick with an 040h window, so between 64 and
  88 pixels the drone decided the kick was irrelevant and kept walking into
  it — which is the wall a player builds by holding HK at range.
  `return_if_reach` only runs `dont_walk_into_it` when the distance is INSIDE
  that window. Same fix applied to `c_lokick`, `c_sweep`, `c_roundhouse`;
  punch handlers stay at 040h because widening everything makes the drone
  passive.
- **Every table index in this file is a bit offset.** `.word` → `sll 4`,
  `.long` → `sll 5`. A `sll 1` here once slept the drone for thousands of
  ticks and froze every walk animation in the game.
- **A drone-dispatched move must end in `reaction_exit`, not `retp`.**
  `drone_do_a0` reaches move routines with a bare `jump`, so nothing pushed
  a return frame. Wrap any `retp`-ending routine (`do_a0_tbl` slots 10-15).
- **`random_do` picks `0..n-1`** — a count that does not match the number of
  `.long`s silently makes the last entry unreachable.
- `act_walkb` / `act_walkf` are declared in MAINEQU but the game only ever
  *compares* against them; nothing stores `act_walkb`. A retreating human's
  action is plain `0`. Do not gate on it.
- `drone_walkf_setup` does **not** touch `p_action` either (only
  `walk_wait_yes` sets `act_walkf`), so there is no "the drone is walking"
  action to watch for — a harness has to measure distance instead, against
  a control, because plain stalking also walks forward.
- `body_slam_init` calls `takeover_him_sr` *before* stamping
  `act_bodyslam`, so the victim's action is already 0 by the time a throw
  is observable. Judge "what was he doing when thrown" from an action
  history, not the value at that instant.
- **New cross-OBJ `jsrp`/`jauc` to a just-added MOVES.ASM symbol can fail to
  assemble** (GSPA quirk). Route through `do_a0_tbl` / `drone_do_a0`.
- **`movk 0` loads 32 on the TMS34010.** `dc_proj` is class 0, so it has to be
  built with `clr`, never `movk`.
- **An air move ends the reaction, so nothing after `jsrp <air move>` runs.**
  `do_land_animation` does `janc drone_land` — a *jump* — and `drone_land`
  ends at `drone_reaction_exit`. Anything that should happen after a jump has
  to be armed with `drone_arm_land` before it and collected in
  `drone_land_next`. Written the other way round it assembles, reads
  correctly, and is silently never reached (see the flip-kick conversion,
  above).
- **`rt_drone_start` is rolled once per round, at round start** — the
  `drone_1_proc`/`drone_2_proc` entry only runs `ochar_drone_start` once, and
  everything after that re-enters at `drone_entry` → `drone_stalk`. So
  `drone_flip_kick` in that table is a round *opener*; every other flip kick
  comes from `standard_proj`/`ochar_avoid_pro`, i.e. only when a projectile
  is thrown at it. A harness with an idle opponent will never see one.
- **Anything that consumes a random number reshuffles the whole game.**
  `randu`/`randper` share one `@rand` stream, so adding a single roll anywhere
  changes every later drone decision. This is the single biggest source of
  false regressions in these harnesses — see below.

## Reading these harnesses: a stray background job will lie to you too

Both `run_mame_small.ps1` and `run_battle_stability_sweep.ps1` spawn a
**background key-poker** that posts OK/space/enter at whatever MAME window it
finds, to get past the ROM-warning screen. **The job outlives the harness that
started it.** A poker left alive then types into the *next* harness's MAME,
landing stray input in the running game.

The symptom is `NO-VERDICT` with an **empty anomaly section**: the lua writes
its `=== BATTLE ===` header at script load and nothing after it, because
`force_matchup` never runs. By inspection that is identical to a real hang.

What it cost on 2026-08-14 (pass 13):

| run | environment | result |
|---|---|---|
| pass 13 | stray poker alive | 9 / 19 |
| baseline | jobs killed first | 19 / 19 |
| pass 13, unchanged | jobs killed first | **19 / 19** |

Read as a conclusive regression, it bought a six-step bisect across all five
change groups. Every group came back clean, and the final step — everything
re-enabled, the file verified content-identical to the original — passed 3/3 on
the exact `-Only deadpool` oracle that had failed 3/3 an hour earlier.

Three rules came out of it:

1. **`NO-VERDICT` + empty anomaly detail ⇒ suspect the environment first.** A
   genuine crash leaves anomaly detail; no detail means emulation never got far
   enough to check anything.
2. **Never change the harness between halves of an A/B.** The poker's iteration
   bound was edited between the two sweeps above, adding a second confound to an
   already-bad comparison.
3. **Re-run the oracle on the unchanged build before bisecting.** Four
   consecutive failures still were not determinism.

`run_battle_stability_sweep.ps1` now kills `Get-Process mame` *and* `Get-Job`
unconditionally at entry — it was the only harness with no guard at all.

### `run_drone_model_test.ps1` cannot currently finish — read its partial log

As of 2026-08-14 this harness does not reach its `RESULT` block. Five
consecutive attempts, MAME exiting **255** at a *different* point each time
(header only ×4; header + fight-start once; deepest run reached pattern-phase
`rel=3600` of the 4200 it needs). **No Lua error is printed in any of them**,
and it fails identically with the unmodified `drone_model_test.lua` checked
out of git — so it is neither the instrumentation nor the ROM. Fight-start
frame varies run to run (611 vs 1657), i.e. the boot itself is
nondeterministic here.

**Do not read a missing `RESULT` line as a failing model.** The periodic
`.. phase rel=N` lines are logged every 600 frames and carry the actual
evidence. The deepest run above showed exactly what the model is supposed to
do:

```
noise   rel=2400  lastcls=proj  predcls=none  predhit=3   <- quiet on random input
phase -> PATTERN (jump-in then sweep, repeatedly)
pattern rel=3600  lastcls=air   predcls=low   predhit=9   <- learned "air -> low"
```

`predcls=none` throughout the noise phase is the confidence gate holding;
`predcls=low` after `air` in the pattern phase is the bigram predictor
working; a climbing `predhit` is the read reaching the drone's own decision
state. That is the whole claim of the model, visible without the summary.

Worth fixing properly if this harness is needed as a gate rather than as a
probe — but its partial output is diagnostic on its own, which is why it is
worth keeping in this shape rather than deleting.

## Reading these harnesses: the RNG stream will lie to you

Adding one `randper` call reshuffles every subsequent drone decision. So a
harness that scores a **single worst case** is really scoring the stream, and
a new build that merely burns one extra roll can fail a test it did not break.

This was worked through properly rather than assumed, twice in one pass:

**Walk fluidity.** The pass-8 build reported a single 8-tick walk hold at diff
0 where baseline reported 4. Bisected it: not `drone_learn` (disabling it
changed nothing), not the `.bss` layout shift (baseline plus 2,880 bits of
inert padding scored byte-identically to baseline), not the new table entries.
It was `drone_pick_band`, which at diff 0 is *behaviourally inert* — its
probability entry is 0, so all it can do is burn one roll. Then the decisive
run: **every line of pass-8 logic active, stream shifted by one extra roll →
worst hold 4, PASS.** Five baseline-ish streams all score 4; one scores 8. It
is a rare pre-existing hitch, not a stall.

The harness now judges the **95th-percentile** hold, which keeps every bit of
its power against the bug it exists for — the sleeping think timer moved the
whole distribution (worst 10, 7 overruns at diff 0 vs 3 at diff 9) — while an
isolated outlier is reported with its frame number instead of failing the run.

**Throw gate.** Same shape. One "thrown while holding back" at `rel=2` — two
frames into the back phase. The drone had committed to the throw before the
harness started holding away, and `body_slam_init` runs `takeover_him_sr`
before the action is even observable. Shifting the stream by one roll moved it
away entirely with the gate untouched. The harness now attributes a throw in
the first 30 frames of a phase to the previous phase, and says so in the log.

The rule: **before believing a single-event regression in any of these, shift
the RNG stream and re-run.** If it moves, it was the dice.

Pass 13 hit this a third time and turned the rule into a switch:
`run_drone_antiair_test.ps1 -Seed <n>` shifts the stream, because a rig that
is deterministic given a build will reproduce its own unlucky run forever and
look like evidence. Four seeds spread 17–33 % on an unchanged feature. Any new
harness measuring a probability gate should be born with that parameter.

## Harnesses

| Script | Proves |
|---|---|
| `tools/run_drone_throw_gate_test.ps1` | throws refused while holding back and during a projectile, still land on a neutral player |
| `tools/run_drone_pacing_test.ps1` | `l_*` timers stamp the drone's OWN p1:p2 slot, cooldowns hold, paced moves still get used |
| `tools/run_drone_newreact_test.ps1` | the new `c_land` / `c_hitfall_sd` table entries actually dispatch |
| `tools/run_drone_opener_gate_test.ps1` | short-range specials are not used as round openers |
| `tools/run_backhp_standing_test.ps1` | back+HP specials fire standing only; down-back+HP uppercuts (all 6 characters) |
| `tools/run_battle_stability_sweep.ps1` | no crashes / camera loss across every stage |
| `tools/run_ai_anim_debug.ps1` | fluidity: no sprite moving with a frozen image, no process stuck on one action |
| `tools/run_drone_walk_fluidity_test.ps1` | the walk cycle never holds a frame past the authored rate, at diff 0 or diff 9 |
| `tools/ai_anim_debug.lua` | frozen animations, stuck processes, sky-launches |
| `tools/run_drone_model_test.ps1` | the opponent model learns a pattern, stays silent on random input, and the read reaches the drone |
| `python tools/audit_drone_tables.py --check` | no live action is missing a reaction handler or reading past a table |
| `tools/run_jade_nitro_crouch_test.ps1` | a plain crouch (no block) ducks Jade's nitro kick, and a standing opponent still eats it |
| `tools/run_sz_juggle_freeze_test.ps1` | the standing ice blast still freezes, and the `l_freeze` cooldown refuses a second one |
| `tools/run_drone_airzap_test.ps1` | the drone throws from a jump (6 characters), never for one without an air zap, and converts a connected flip kick into a projectile |
| `tools/run_drone_antiair_test.ps1` | jump-ins get met with an uppercut at a real rate, never swinging at nothing; `-Diff 0` must score zero |
| `tools/run_drone_pressure_test.ps1` | `-Style duckupper` the crouch-and-uppercut exploit; `-Style turtle` a patient blocker; `-Style mash` sanity only. Scores damage BOTH ways, so a drone that stops fighting cannot look like a win |
| `tools/run_drone_juggle_test.ps1` | the combo scripts chain AND convert (scored separately); `-Diff 0` must produce no combo at all. Needs a `juggle_debug 1` build |
| `tools/run_drone_jab_whiff_test.ps1` | a jab string that touches nothing is answered with a sweep; attributed through the counter's reset window, so the drone's other sweeps cannot be credited to it |
| `tools/run_drone_divepunish_test.ps1` | what the drone throws into Kung Lao's BLOCKED dive-kick recovery, scored HIT/WHIFF on the bar actually moving; plus every swing it starts at an airborne man, broken out per move |
| `tools/run_divep_ab.ps1 -Airswing 0\|1` | one side each of the `airswing` A/B: sets the equate, rebuilds, packages, sweeps 8 seeds. Reads the equate back and refuses to build if it did not change |
| `python tools/divep_summary.py <dir>` | adds up a directory of divepunish logs - one run is a handful of blocked dives and proves very little |

## Sub-Zero freeze: juggles, and why the ground blast still can't reach one

`ice_proc` gated **every** strike check on `is_he_helpless` — which is
`is_he_airborn` **and** `pb_reacting`, i.e. airborne *because you just hit
him*. A plain jumping opponent was never blocked by it; the only case it ever
suppressed was the juggle. That gate is original Boon code and existed to stop
freeze-juggle infinites. It has been removed deliberately, and
`air_ice_proc` — which never had it — now gets the same treatment in reverse.

Two limiters replace it, because "no juggle ever" and "unlimited juggle" are
both wrong:

| Limiter | Where | Effect |
|---|---|---|
| `l_freeze` cooldown, `060h` ticks | gate in `sz_lo_punch` (MOVES.ASM), stamped in `do_throw_ice` / `do_sz_airice` | one gate covers **both** freezes, since `sz_lo_punch` is the single trigger that branches to each |
| one freeze per airborne state | `freeze_juggle_ok` (MKZAP), flag set in `r_ice`, cleared lazily | he can be frozen out of the air, but not *again* until he has touched the ground |

The flag is cleared inside `freeze_juggle_ok` on any check where the victim is
seen grounded, so no landing path anywhere else has to know it exists.
`get_tsl`/`update_tsl` key off `a8(oid)`, not `a13`, which is why the cooldown
gate is correct even though `sz_lo_punch` runs in the combo-detector process.

### The startup window — measured, and it changes the conclusion

Removing the gate was necessary but is **not sufficient** for
"flip kick in, then ground freeze". Measured on
`tools/run_sz_juggle_freeze_test.ps1`:

```
r=49  flip kick connects
r=57  victim enters hit-stun
r=75  Sub-Zero lands        victim 59 px up   <- window opens
r=81  Sub-Zero free         victim 42 px up
r=87  ...victim lands                          <- window closes
r=93  the ice finally exists
```

`do_throw_ice` needs **~13 ticks** of throw animation before the projectile
spawns, but the victim is only airborne for **~9 ticks** after Sub-Zero
recovers. The ground blast is 4-6 ticks too slow to reach a flip-kicked
opponent no matter what the gates say. Closing that would mean trimming the
move's startup, which buffs Sub-Zero's neutral game everywhere — deliberately
**not** done. The uppercut route is worse still: it leaves him in
`act_upcut_sd` from r=47 to r=104, by which point the victim has long landed.

So the helpless-gate removal earns its place for setups with a wider window
and for the air freeze, not for the flip-kick combo specifically.

**Verified:** grounded freeze still works; a second freeze inside the cooldown
is refused (1 cast, not 2). The one-freeze-per-airborne-state flag is
implemented and builds clean but is **not** behaviourally verified — no
scripted setup yet produces a landed airborne freeze to chain off.

`is_he_airborn` / `am_i_airborn` clobber **a0-a3**, not just a0/a1, so
`freeze_juggle_ok` and the `r_ice` flag-set both save all four. In `ice_proc`
that was already safe (the `is_he_helpless` it replaced clobbered identically
at those exact points), but the two new call sites had no such cover.

## Hitbox notes from this pass

Two hitboxes were wrong in the vertical axis. Both were measured, not guessed
— the harnesses print the actual box against the actual victim bounds.

**Jade nitro kick (`stk_fn_nitro`)** — had to be duckable *without* blocking.
Measured: Jade `oypos` 83, box `129..145`; a standing victim's box starts at
93 and a crouching one at **144**. So a crouch cleared it by minus one pixel
and ate the full 19 damage, identical to standing. `y_offset 02eh -> 028h`
moves the box to `123..139`: five pixels of clearance under a crouch, still
buried in a standing torso. Raising the offset rather than shrinking `y_size`
keeps the box its authored thickness.

**Sub-Zero ground freeze (`stk_floor_ice`)** — the earlier fix on this move was
purely *horizontal* (it had lost 29px of front reach). This is the other axis
and a separate bug. The box was a sixteen-pixel slab on the floor
(`y_offset 080h`, `y_size 010h`), and `strike_check` has no airborne test
anywhere, so a victim whose feet were off the ground was simply above it — the
ice drew underneath him, touching nothing. `080h/010h -> 060h/030h` keeps the
bottom exactly where it was and lifts the top from +128 to +96, catching feet
up to 32px up. A full jump peaks near 95px and still sails over, so jumping the
puddle remains the answer. **The X pair (`09dh`/`060h`) is shipped L3.1 and must
not be touched.**

### Two rig lessons, both of which produced confident nonsense first

- **Never pin `oyval`/`oypos` to stage a height.** The first airborne rig held
  the victim at fixed heights and returned a non-monotonic sweep (16 and 32
  froze; 0, 8 and 24 did not) *and* broke its own grounded control. Pinning y
  fights the game's ground/airborne bookkeeping, so it measures the rig. Let
  him really jump and pin x only. **A sweep whose control fails is not data.**
- **`r_floor_ice` calls `ground_player`,** so by the time `act_slipping` is
  observable the victim has already been slammed to the floor and his height
  reads 0 no matter how high he was on contact. The height has to come from a
  few frames of history, not from the frame the reaction appears on.

`run_ai_anim_debug.ps1` and `run_drone_walk_fluidity_test.ps1` do not
overlap. The former only reports a sprite that slides with a frozen image for
a **full second**, so it catches a wedged process; the sleeping think timer
was a 3-6 tick hitch and sailed straight past it. The latter measures the
run-length distribution of held frames and compares diff 0 against diff 9.

Last verified 2026-08-05 (pass 8), all on the shipping build:

| Harness | Result |
|---|---|
| table audit | PASS — 132 live actions, 0 holes, 0 OOB, 17 documented-silent |
| opponent model | PASS — 0/14 predictions on random input, 100% on a pattern, 0 confidently wrong |
| throw gate | PASS — 0 throws in 2200 frames of held-away inside slam range, 0 during fireballs, neutral still thrown |
| pacing | PASS — shortest zap gap 197 ticks vs a 64 floor |
| new reactions | PASS — `c_land` 9/16 (was 6/16); `c_hitfall_sd` 6/15 vs 4/15 control, still INCONCLUSIVE by design |
| opener gate | PASS — 4/4 characters |
| walk fluidity | PASS — p95 hold 4 at both diff 0 and diff 9 |
| stability sweep | PASS — 17/17 stages |

Pass 9 (2026-08-05), same build:

| Harness | Result |
|---|---|
| `run_jade_nitro_crouch_test.ps1` | PASS — 19 damage standing, **0 crouching** without blocking |
| `run_sz_floorice_range_test.ps1` | PASS — horizontal reach still 176 px |
| `run_sz_juggle_freeze_test.ps1` | PASS — standing freeze works; a second freeze inside the `l_freeze` cooldown is refused (1 cast, not 2) |
| stability sweep | PASS — 17/17 stages |

Pass 10 (2026-08-06), air projectiles + attack strings:

| Harness | Result |
|---|---|
| `run_drone_airzap_test.ps1` zone | PASS — all six air characters throw from a jump; Raiden/Scorpion control 0 |
| `run_drone_airzap_test.ps1` convert | PASS — flip kicks armed and converted 23–26 frames after landing |
| pacing | PASS — shortest zap gap 135 ticks vs a 64 floor, flip 2792 vs 96 |
| walk fluidity | PASS — p95 hold 4 at both diff 0 and diff 9 |
| opener gate | PASS — 4/4 characters |
| throw gate | PASS — back/projectile immune, neutral still throwable |
| table audits | PASS — `audit_drone_tables --check`, `audit_char_tables` 0 short |
| stability sweep | PASS — 17/17 stages |

Pass 11 (2026-08-06), anti-air:

| Harness | Result |
|---|---|
| `run_drone_antiair_test.ps1` diff 9 | PASS — 15/44 jump-ins met (34%), 11 connected, **0** swings at nothing |
| `run_drone_antiair_test.ps1` diff 0 | PASS — 0/20, the easy CPU ate every jump-in |
| pacing | PASS — shortest zap gap 135 ticks vs a 64 floor |
| walk fluidity | PASS — p95 hold 4 at both diff 0 and diff 9 |
| table audits | PASS — `audit_drone_tables --check`, `audit_char_tables` 0 short |
| stability sweep | PASS — 17/17 stages |

Pass 13 (2026-08-10), juggle combos un-parked:

| Harness | Result |
|---|---|
| `run_drone_juggle_test.ps1 -Diff 9` | PASS 5/5 — Kung Lao **62 dmg (38%)**, Mileena **52 (32%)**, Jax **40 (24%)**, Raiden **33 (20%)**, Sub-Zero **32 (19%)** |
| `run_drone_juggle_test.ps1 -Diff 0` | PASS 5/5 — **0/10** combos each, the difficulty gate proving it is real |
| walk fluidity | PASS — p95 hold 4 at diff 0 and diff 9, 0 overruns |
| pacing | PASS — shortest zap gap 150 ticks vs a 64 floor, flip 952 vs 96 |
| table audits | PASS — `audit_drone_tables --check`, `audit_char_tables` 0 short |
| stability sweep | PASS — **19/19** battles, re-run after the roster-wide scripts went in (that change alters drone behaviour for 14 characters, not 2, so the earlier sweep did not cover it) |
| anti-air (pass 11 regression) | PASS — see below; 4 seeds, 17/28/30/33 %, **0 whiffs on all four** |

### The anti-air "regression" that was the dice, again

The first anti-air re-run scored **17 %** against its 20 % floor and failed.
That is the fourth time this file has had to work through the same thing, so
the drill is now written down as a switch rather than a memory: the rig is
otherwise fully deterministic, so `run_drone_antiair_test.ps1` gained a
**`-Seed`** parameter that shifts the `@rand` stream, and four seeds give
**17 %, 28 %, 30 %, 33 %** — median 29 %, against pass 11's 34 %.

Two things make that conclusive rather than convenient:

- **`whiffs=0` on all four.** The rate wanders; the property the feature
  actually promises — never swing at nothing — did not move at all. Those are
  different failures and the harness scores them separately, which is exactly
  why the wandering one could be dismissed and the fixed one could not.
- **Raiden has no juggle script.** `ochar_juggle_scripts[7]` is `0`, so
  `drone_juggle_try` returns at its second instruction without touching
  `@rand`. For this harness `juggle_enable` 0 and 1 are provably identical
  code paths, so the juggle pass *cannot* be what moved the number.

The honest residue: a 20 % floor sits close to this rig's own spread, so a
green run is weaker evidence than it looks. Judge it on several seeds.

The juggle rows are measured on a `juggle_debug 1` build (that harness reads
`@debug3`/`@debug4`); every other row is the shipping build, and the shipping
ROM was byte-compared against the one the sweep actually ran to confirm the
final source is the source that was swept.

### `.text` sizes must come from a clean build, and did not

Pass 13 was reported mid-flight at 407,234 → 407,362 bytes. Both figures were
wrong. A **full rebuild** (`rm src/*.OBJ`, then `build.py --asm-only`) gives
**401,730** — deterministic, reproduced twice, and *smaller* than the 404,674
this pass started from, which is what deleting eight routines should look like.

The incremental builds were linking ~5.6 KB of code this pass had deleted.
Behaviour was never affected — a clean rebuild reproduced all five juggle
results byte for byte (40 / 33 / 32 / 62 / 52) — because what lingered was
precisely the *unreferenced* routines. That is why it was invisible: dead code
is exactly the code that can go stale without changing anything you can see.

The lesson is narrow and worth keeping: **`build.py --asm-only` is fine for
behaviour and unreliable for size.** Any `.text` figure quoted in this file
should come from a clean rebuild, and a size that moves the wrong way is a
signal to do one. (Related but not the same as the mtime trap in
`reference_build_stale_obj_mtime`: nothing here failed to *rebuild*, the old
objects were still being *linked*.)

`.text` 404,674 → **401,730 bytes** over pass 13 — a net saving, because the
eight dead air-link routines it deleted outweigh the generic script and the
two new tables.

The floor-puddle Y experiment described in an earlier revision of this doc was
**rolled back**: "ground freeze" meant Sub-Zero's standing ice blast (D,F+LP),
not the D,B+LK puddle. `stk_floor_ice` is byte-identical to shipped L3.1 again.

Program ROM `.text` grew 401,282 → 402,498 bytes over passes 8-9,
402,498 → 404,290 over pass 10, and 404,290 → 404,674 over pass 11;
~23 KB still free between `.data` and REVX.

Harness lessons worth keeping:

- **Never hardcode an `act_*` id in a harness — parse MAINEQU.ASM.** Action
  ids are `.set` equates, so unlike RAM symbols they are *not* in MK2.MAP and
  `sym()` cannot catch a mistake. The anti-air harness was written with
  `act_uppercut = 0x0103` (it is `0x0107`) and `act_upcut_sd = 0x0606` (it is
  `0x0603`), and reported a perfectly plausible **0/39** for two builds in a
  row. A wrong constant is indistinguishable from a broken feature, and it
  cost a hook being relocated on evidence that did not exist. The lua now
  reads the equates out of MAINEQU at startup and logs FATAL if one is
  missing.
- **A pass condition of "it happened at least once" is not a test.** The same
  harness scored 1/36 and went green, because the bar was `met > 0`. Anything
  measuring a probability gate needs a *rate floor* set below the configured
  odds but far above noise.
- Judge an "in range" violation by **distance**, not elapsed frames.
- **Nudge** the drone rather than pinning it every frame — pinning overrides
  its walk so it never enters `cmf_close` and everything reads as
  unreachable.
- A behavioural claim about the drone needs a **control run**: "did it walk
  toward me" scored 19/20 on a do-nothing control until the stalk band was
  pinned to far (`p_dronevar1` = 2) and the start distance moved past it.
- `switch` (JAMMA i/o, `01600000h`) is an equate in SYSEQU.ASM, so it is not
  in MK2.MAP and `sym("switch")` silently returns 0.
- **MAME's red ROM-warning box is what "the run never started" actually is.**
  No log file at all, process alive at ~0 % CPU: MAME is sitting at the
  warning waiting for a keypress, and the lua never gets a frame. It is
  intermittent, so a harness without a dismissal will pass for weeks and then
  report NO LOG — which reads exactly like a broken feature.
  `run_battle_stability_sweep.ps1` has always poked past it (`PostMessage`
  o/k/space/enter to `MainWindowHandle`, retried until the log says the fight
  started); `run_drone_antiair_test.ps1` now does the same. `rawinput` ignores
  synthetic keys, which is why every one of these passes
  `-keyboardprovider win32`. Copy that block into any new harness.
- **Never run two of these harnesses at once.** Every one of them opens with
  `Get-Process mame | Stop-Process -Force`, so starting a second harness
  kills the first one's MAME mid-run. Doing this to a backgrounded stability
  sweep produced three `NO-VERDICT` battles with an *empty* anomaly section —
  which reads exactly like a crash regression and is not one. If a sweep
  reports NO-VERDICT, check whether anything else touched MAME before
  believing it.
