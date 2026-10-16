# MK2 input spec

Status: **DRAFT**. Companion to [FGC_FRAME_BOX_SPEC.md](FGC_FRAME_BOX_SPEC.md).

This doc covers how player intent becomes a command. Boxes, frame data and
collision live in the companion.

Every item is one of:

* **RESOLVED** - the build already answers this. The answer and where it lives
  are given. Nothing to decide; there may still be something to *change*.
* **OPEN** - a real decision, with a recommendation.

The measured numbers come from [INPUT_MODEL.md](INPUT_MODEL.md), which names
the rig that produced each one. Nothing here is estimated.

---

## 0. Scope and principles

1. **Determinism is free here.** The parser is TMS34010 assembly running under
   an emulator that snapshots the whole machine. There is no separate savestate
   to keep in sync and no floating point anywhere on the part - the 34010 has
   no FPU. Every determinism clause a from-scratch engine needs is satisfied by
   construction. See section 7.
2. **Leniency is a feature, ambiguity is a bug.** Every accepted shortcut is
   enumerated; anything not enumerated is rejected.
3. **Don't change what the move does - change whether the player can express
   it.** Balance work belongs in the companion doc.

---

## 1. Timebase - RESOLVED

| Item | Value |
|---|---|
| Logical tick | **18.28 ms** |
| Refresh | **54.7068 Hz** |
| Samples per tick | see section 7 - the port is read live, not once |

54.7068 Hz is measured from the driver we ship against
(`refresh_attoseconds` = 18,279,250,000,000,000), not taken from a spec sheet.
**Published figures of 53.20 Hz and 60 Hz are both wrong for this build** and
will drift about 3% and about 9% respectively over a long sequence.

We run native. There is no resampling question - the ROM *is* the timebase.

All counts below are in ticks.

---

## 2. Input model

### 2.1 Physical inputs - RESOLVED

8-way joystick to 4 directional bits, plus 5 buttons (HP, LP, HK, LK, BLK).
Read from `p_joyport` as one 16-bit switch word, **active low**.

### 2.2 Facing - RESOLVED, and it is neither option the draft offered

The draft asked whether motions store facing-relative or absolute directions.
The build does a third thing:

* the queue stores the **raw switch word** - absolute, physical left/right;
* every combo record carries **two patterns**, a face-right copy and a
  face-left copy, 6 entries apart (`addi 16*6,a11` in `combo_look_lr`,
  MOVES.ASM);
* facing is resolved **once, at match time**, by a single `is_he_right` test,
  and the chosen pattern is compared against the whole motion.

So a mid-motion facing flip does not corrupt the queue, but it does
re-interpret every earlier entry in the new facing - which breaks the motion,
because those entries were made in the old one. That is the crossup drop.

**The fix is per-entry facing.** A queue entry is `[switch:16, time:16]`; the
switch half has spare bits. Stamping the facing at write time and resolving
each entry against its own stamp is the smallest change that makes a crossup
motion survive, and it is what section 4.1 already assumes.

**UNBLOCKED.** "Which tick does facing flip on" has an answer, and it is that
the question contains a false premise - there are two facings, and only one of
them flips on a tick:

* the **logical** facing used here is not stored at all. `is_he_right` is a
  live `oxval` compare, so it flips on the exact tick the fighters cross, and
  at equal x it resolves to face-LEFT (`jrgt` is strict);
* the **character's** facing is the `m_fliph` bit in `oflags`, changed only by
  `turn_around` - an ~8 tick animation that disables buttons, and one that is
  only ever attempted from the stance loop, walking, or blocking. Airborne or
  mid-move, it is not attempted at all.

So per-entry facing is well defined: **stamp the physical verdict at write
time.** That is what "toward" meant to the player when the entry was made, it
needs no new state beyond the spare bits in the switch half, and it does not
depend on the character-facing clock at all - which is just as well, because
that clock is stopped for the entire duration of a crossup jump.

See the companion spec's open item 8 for the measurement behind this.

### 2.3 Diagonals - FIXED (`joyskip`, anchored first step)

**An earlier draft of this section was wrong, and wrong in an instructive
way.** It read this loop -

```asm
combo5  move    *a11+,a8,w       ; expected switch word from the table
        callr   previous_q_entry ; a0 = previous [switch,time]
        sll     16,a8
        cmpxy   a8,a0            ; match ?
        jryeq   combo5
```

- saw an exact 16-bit equality, assumed both operands were **bitmask** switch
words, and concluded that a diagonal fails because `D/F` is a different word
from `F`. The recommended fix was to make the compare a subset test.

There is nothing to subset. `sw_up`/`sw_down`/`sw_left`/`sw_right` are
**indices 5-8**, not masks, and the queue is **event based**: `p1_jcq` gets one
entry per switch *closure*, carrying an identity and a tick (MKINIT.ASM,
`p1_joyright` etc). Buttons go to a different queue entirely (`p1_bcq`), which
is also why the "protect the button half" warning that used to be here was
unnecessary.

**So a diagonal does not produce a diagonal.** Pressing down-forward produces
**two entries**, `sw_down` *and* `sw_right`. The pattern's `F` step matches
`sw_right` perfectly well. What kills the motion is the *spare* entry, because
the walk demands that the very next entry back be the one the pattern wants and
has no way to step over anything.

That is the whole explanation of the measured asymmetry, which had never been
accounted for:

| | |
|---|---|
| **holding** Down across a Forward,Forward | **4/4** |
| **tapping** Down between the two forwards | **0/4** |

A held direction never makes a second entry. A tapped one always does.

**Diagonal leniency and "irrelevant directions are ignored" (rule 3) are
therefore the same fix, not two.** `joyskip` (MAINEQU.ASM, **2**) lets each
pattern step walk over up to N non-matching entries before giving up:

```asm
        movk    joyskip+1,a1     ; tries: the entry, plus N skips
combo5s callr   previous_q_entry
        cmpxy   a8,a0
        jryeq   combo5y          ; matched
        dsj     a1,combo5s       ; no - step over it and look again
```

Bounded by a **count**, not by time, and deliberately: `combo7` already tests
the oldest matched entry against the motion window, so skipping can never reach
further back in time than retail could. The count exists to stop the walk
lapping the 20-entry ring, which wraps forever and would otherwise match stale
entries from the previous motion.

**Measured, A/B on the same rig in the same session**
(`sweep_addon_droprate.lua`, Reptile's spit F,F+HP at an 8-tick gap, 4 reps):

| hazard | `joyskip 0` (retail) | `joyskip 2` (ships) |
|---|---|---|
| clean (control) | 3/4 | 3/4 |
| Block held | 0/4 | 0/4 |
| second attack button ridden | 0/4 | 0/4 |
| **Down tapped between the forwards** | **0/4** | **4/4** |
| Down held across the motion | 3/4 | 4/4 |

The control reads 3/4 on **both** sides, so that is rig variance and not a
regression - which is the only reason the rest of the column can be trusted.
Block and the second button are unchanged because they are `button_mask`, a
different gate entirely (section 4.5). `joyskip 8` was also measured and gives
the identical result to `joyskip 2`, so 2 is not a value scraping past: one
skip is what the case needs and there is margin.

### 2.3.1 It broke Shang Tsung's skulls, and what fixed it

The cost was stated as a risk - *"two specials sharing a prefix become easier
to confuse"* - and then quantified, which turned it from a risk into a defect.
`tools/combo_collision_audit.py` finds **8 new collisions at `joyskip 2`**, and
**7 at `joyskip 1`**. There is no safe non-zero value.

The flagship:

| | pattern (newest-first) | tried at |
|---|---|---|
| `scom_st_zap` - 1 skull | `left left` | MOVES.ASM **1878** |
| `scom_st_zap2` - 2 skulls | `right left left` | 1898 |
| `scom_st_zap3` - 3 skulls | `right right left left` | 1907 |

**The shortest is tried first.** At retail that is harmless: `st_zap`'s first
step must match the newest entry, which for a 3-skull input is `right`, so it
fails and the walk falls through to `st_zap3`. With skipping, `st_zap` reaches
past the two forwards and matches - so **you input three skulls and get one**.
Same shape for `st_zap2` swallowing `st_zap3`, for Reptile's forceball, and for
three of the female-ninja teleports.

**The root cause is section 4.4, not section 2.3.** MK2 resolves two matching
commands by *declaration order*, not by longest match. Retail gets away with it
because contiguous matching makes a short pattern fail early on a longer input.
Skipping removes that accident, and the missing rule becomes a live bug.

So the order of work is fixed, and it is the reverse of what this document
originally assumed:

1. **Longest-match, or a per-handler reorder** so the longest pattern is tried
   first. Four handlers carry all eight collisions: `st_hi_punch`,
   `rp_lo_punch`, `lk_block`, `do_noob_teleport`.
2. **Then** `joyskip`, with the audit at zero new collisions as the gate.

**None of the existing gates caught this.** The stability sweep passed 25/25
and the behaviour lock passed 10/10 with the defect in the ROM, because it is
not a crash and not one of the ten locked behaviours - it is the wrong move
coming out. That is what the audit is for, and it is now the acceptance test
for any future change to the matcher.

```
python tools/combo_collision_audit.py            # audits the shipping value
python tools/combo_collision_audit.py --joyskip 4
```

Exit is non-zero when anything is found, so it can gate a build.

#### The two fixes, and why the cheap one does most of the work

**1. The first pattern step is ANCHORED.** It may not skip; the newest queue
entry must be the move's own last direction. That single restriction kills
three of the four collisions, because reaching *past the head* of a longer
pattern is exactly what lets a short one win. And it costs nothing that
`joyskip` was for - the strays it exists to step over are the ones **between**
your inputs, not the one you just made. Measured: `stray_down` is **4/4**
either way.

**2. Shang tests his longest skull first.** The three blocks are structurally
identical, so this is a swap of which record each one tests - `scom_st_zap3`
where `scom_st_zap` was, and back. **Every `jrnc` label stays where it was**,
which is what makes a reorder of dispatch priority safe to do by hand.

Result: **0 new collisions at every value from 1 to 4.**

Reptile's forceball swallowing his own fatality's `D,B,B` was the fourth, and
the anchor alone fixes it - his chain needed no reorder, which is worth knowing
because rewiring it would have meant moving four labels across a fatality path
that nothing here can playtest.

#### What is still true, and is retail's problem rather than ours

MK2 still has **no longest-match rule** (section 4.4). The anchor makes the
absence harmless in every case the audit can see; it does not add the rule. A
new special whose pattern is a suffix of an existing one will collide again,
and the audit is what will say so.


---

## 3. SOCD - DONE (`socdfix`)

Not resolved anywhere today. The raw port state reaches the queue unfiltered,
so Back plus Forward on a leverless produces whatever the encoder sends.

Recommend Back+Forward to **neutral**, Up+Down to **up priority**, resolved
once at sample time in `joystick_in_a0` (JOY.ASM) so nothing downstream ever
sees an unresolved state.

Doing it there rather than in the driver is also what makes it apply online:
the netplay layer transmits the port, so a driver-side fix protects one cabinet
and an in-ROM fix protects the match.

**It is bigger than one routine, because there is nothing to intercept.**
`switch` is `01600000h` (SYSEQU.ASM) - the JAMMA connector itself, not a RAM
shadow. Every reader reads the hardware directly, which is what section 7's
"read live, not latched" means literally. There is no single write to hook.

So SOCD needed a **latch**, and that is what `socdfix` is.

`socd_latch` (JOY.ASM) runs once a tick from the dispatcher, before any process
has read anything. It inverts the port once, works in active-high where the
masks read the way they are named, resolves both players, inverts back, and
stores to `switch_latch` - leaving every other bit exactly as the hardware
presented it. Buttons are untouched; there is no such thing as an impossible
button.

`p_joyport` then points at the shadow instead of the port. It is a **bit
address**, so the shadow has the port's layout exactly - P1 reads from bit 0,
P2 from bit 8 - and `joystick_in_a0` and every one of its callers is unchanged.

Resolved: **Back+Forward to neutral**, **Up+Down to up**.

Validated: 25/25 stability sweep, behaviour lock 10/10. The lock's walk checks
are the ones that matter here - a wrong polarity or a wrong bit offset means
nobody moves, and that is exactly what they measure.

### 3.1 The other half - the motions

**Also done, and it was not the interrupt surgery this section first feared.**

The special-move queue is built from switch *closures*, and those are computed
by the switch scan in MKINIT.ASM, which reads `@switch` **directly** and diffs
it against last tick. That scan runs from the main loop, not from an interrupt.
Resolving the port there covers every closure, and therefore every motion.

```asm
	move	@switch,a0,l	; current switch state
	calla	socd_resolve	; <- resolve BEFORE the diff
	move	@swtemp1,a1,l	; last tick switch state
```

Two deliberate choices in that one call:

* **It resolves for itself rather than reading `switch_latch`.** The latch is
  refreshed by the dispatcher and could be a tick behind the scan, which would
  put a frame of latency on every closure - and that scan's own debounce was
  deliberately cut from two frames to one to save exactly that. Correctness
  must not cost back the latency someone already paid for.
* **Resolving before the diff** means `swtemp1` stores the resolved word, so
  next tick's edges are computed between two *legal* stick states rather than
  between a legal one and an impossible one. Resolving after the diff would
  produce edges that never happened.

So `socdfix` now governs both the held stick and the motions.

---

## 4. Command parsing

### 4.1 Input history - RESOLVED

Per player, a **20-entry** queue of `[switch:16, time:16]` pairs (`sqs`,
MAINEQU.ASM), written as inputs arrive and walked backwards by
`previous_q_entry`.

Two properties worth knowing before changing anything:

* **A held direction makes no new entry.** Holding Down for ten ticks is one
  entry. This is why riding Down through a Forward,Forward is free.
* **A mismatched entry is never cleaned up.** A *tapped* Down between the two
  forwards makes an entry that nothing removes, and the exact-match walk
  (section 2.3) then fails on it. Measured: holding Down across the motion
  **4/4**, tapping Down mid-motion **0/4**.

Adding a facing bit per section 2.2 goes in the spare bits of the switch half.

### 4.2 Motion matching

| Draft rule | Status |
|---|---|
| 1. Step timeout | **Does not exist.** There is no per-step window, only a total (rule 2) |
| 2. Total motion window | **RESOLVED, per move.** The record's first word: 16-56 ticks across 90 records, plus `combo_slack` |
| 3. Irrelevant directions ignored | **TRUE as of 2026-09-03**, up to `joyskip` entries per step. See 2.3 |
| 4. Repeated/held steps collapse | **Already true.** Held directions make no entry |
| 5. Intermediate skips permitted | **Already true**, trivially - the pattern lists only the entries it wants, and there is no per-step timeout to expire |
| 6. Backwards travel | **Mostly true now** - the extra entries a regression makes are skippable, within `joyskip` |
| 7. Button window | **RESOLVED.** The button is the entry that starts the walk; there is no separate window |

**The window spread is not a difficulty spread.** It tracks how hard the motion
is, not how long it should take. Every 16-tick record is a *roll* - two
different directions, which the hand does in one movement. A *double tap* of
one direction never gets less than 24, because the stick has to return to
neutral in between.

Measured gap tolerances: a roll accepts 1-10 ticks between inputs (183 ms), a
tap 4-16 (293 ms). Neither is tight.

A tap fails at a gap of **2** for the opposite reason to the one people assume
- the stick has not been released yet, so the second tap never becomes a second
entry. **Release between taps; speed is not the problem.**

**Live leniency switches, already shipping:**

| switch | value | effect |
|---|---|---|
| `combo_slack` | 6 | ticks added to every special-move window |
| `combo_slack_online` | 1 | 1 = that slack applies online only |

`combo_slack` widens the clock; `joyskip` widens what counts as a match.
Between them rules 2, 3, 4, 5 and 6 are now satisfied.

### 4.3 Charge moves - RESOLVED, not applicable

MK2 has no charge-direction specials. The one hold mechanic is a **button**
hold (Kitana's and Jade's boomerang on HP held). Nothing in the draft's section
4.3 applies; drop the section rather than leave it inviting an implementation.

### 4.4 Command collision - OPEN

Resolution is by **declaration order** today: each character's handler tries
its motions in a fixed sequence, and the first `combo_look_lr` that returns
carry wins. There is no longest-match rule and no per-character priority list.

That is worth writing down before it is changed, because several moves depend
on it - notably Back+HP standing-only, which works only because its test sits
*above* `char_hi_punch` in the dispatch.

Recommend keeping declaration order, but **documenting the order per
character** and adding the debug assertion for two same-length commands sharing
a button. A real longest-match pass is a rewrite of every handler, for a
problem the game does not currently have.

### 4.5 Button input priority - RESOLVED, and better than the draft assumed

`button_mask` is called with **a per-call-site mask** (a0/a1 = the P1/P2
buttons that must not be held), not a global one.

The default mask rejects every other button, which is why **you cannot hold
Block and throw a special** - measured **0/4**, and 0/4 for riding any second
attack button. It reads as the game ignoring the player, and is the edge most
often blamed on the player.

But Kitana's spin chop already passes `f1b0|f1b1|f1b3|f1b4` - every button
*except* block - so block may stay held for that one move.

**So relaxing this is a per-move constant, not new code.** Allowing block to be
held during a motion is one mask edit per handler. This is the cheapest real
"feels bad" fix in the document.

**Two-button commands - RESOLVED.** Kitana's fan and Reptile's forceball go
through `two_button_check` (MOVES.ASM). Retail wants the partner as the
immediately previous entry and within **2 ticks (37 ms)**. This build ships
`twobtn_slack 2` and `twobtn_depth 3`: a **4-tick (73 ms)** window, partner up
to 3 entries back, so one stray entry between the presses no longer kills it.
Measured 3/3 out to a separation of 4, 0/3 at 5. `twobtn_slack 0` restores
retail exactly.

The trade is stated where it was made: a wider window makes an LP-to-HP string
thrown while holding forward likelier to come out as a fan.

---

## 5. Buffers - OPEN, and there is no baseline to widen

**There is no input buffer of any kind.** Measured with
`tools/sweep_addon_buffer.lua` - a high punch, then a low kick K ticks later:

* **K <= 18: the kick never comes out.** The input is discarded, not queued.
* **K >= 19: the kick comes out at exactly K+3**, the same acceptance cost as
  from neutral.

So a punish must be **timed, not held early**; pressing during your own
recovery does nothing at all; and online, a dropped input is simply lost.

All three buffers in the draft are new construction, not tuning:

| Buffer | Recommend | Notes |
|---|---|---|
| Input buffer | 4-8 ticks (73-146 ms) | Fires on the first actionable tick, never retroactively |
| Cancel buffer | see companion section 10 | Must not advance the motion window |
| Negative window | 2-3 ticks | Motion matching only |

**Baseline acceptance cost, to measure any of this against:** button down to
the move starting is **3 ticks (55 ms)**; button down to a hit landing is
**9-12**. The uppercut accepts at 5 rather than 3 because the duck resolves
first.

Remaining decisions are unchanged from the draft: clear-on-stun-entry, wakeup
scope, and whether an illegal buffered move is consumed or ignored (recommend
ignored - consuming produces silent drops).

---

## 6. Block - RESOLVED (mechanism), OPEN (policy)

MK2 is a block-button game. **As of 2026-09-03 it is also a hold-away game** -
`backblock` (MAINEQU.ASM), ON.

**Validated 2026-09-03**: full build, `run_battle_stability_sweep.ps1`
**25/25 PASS** (no crash, wedge or camera fault), `run_behaviour_check.ps1`
**10/10**. That says it does not break the game. It does **not** say it plays
well - nobody has played it.

### 6.1 backblock - holding away guards too

Holding the stick away from the opponent guards, **in addition to** the button.
Away+down guards low, for free, because the duck test the block path already
does reads the stick rather than the button.

**It is PROXIMITY block, and that is the whole design.** The hook is in
`is_he_blocking` - the question the strike path asks at the moment of contact -
and deliberately **not** in `check_block_bit`, which is what the stance loop
polls to decide whether to stand in the block pose. Hooking the latter is the
obvious move and deletes backward walking from the game: holding away would
enter the block animation instead of retreating. Here you walk back until
something actually reaches you, then guard it.

Untouched: `b_noblock` still cannot be guarded, airborne still cannot guard, a
move that demands a low block still whiffs a high one, and the drone path
(`act_blockhi` / `act_blocklo`) is not involved at all. When the button already
said yes the new code does not run, so the button path is byte-identical.

**The part worth arguing about, and it is bigger than it looks.** Holding the
block BUTTON makes every special-move motion fail - `button_mask` rejects it on
77 of 98 call sites (section 4.5). Holding *away* never reaches `button_mask`.

That is not a new question. `blockspecial` (MAINEQU.ASM) is the switch that
lifts the button restriction, and it is **deliberately 0**, with the reasoning
written down: *"a block that cancels straight into a special is strictly better
than the one the game ships with."*

So `backblock 1` grants most of `blockspecial 1`'s effect through a different
input, while `blockspecial` stays at retail. The two switches now disagree
about the same design question, and that should be settled on purpose rather
than left as an artifact:

* **Both off** - retail. Guarding costs you your specials, always.
* **`backblock` only** (what is set now) - two guards with different
  properties. The button is strictly worse. Players will simply stop using it.
* **Both on** - one rule, consistently applied: guarding never costs you a
  special. Honest, and the furthest from L3.1.
* **`backblock` on, and make it respect `button_mask` too** - keeps the
  restriction uniform while still adding the input. Costs a `button_mask` call
  in `ihb_stick_away`, and makes hold-away guarding fail while any attack
  button is down, which is its own surprise.

**Settled 2026-09-04: both on.** `blockspecial 1` - block is dropped from the
button mask, and `block_held` in the drop-rate rig went **0/4 to 3/4**,
matching the control exactly.

The deciding argument is that it grants nothing new. `backblock` already lets a
player guard and throw a special, because holding away never reaches
`button_mask` at all. So the only thing the restriction was still doing was
making the block BUTTON strictly worse than the stick - a trap rather than a
design, and one that would have quietly retired the one input that is
unambiguous about wanting to block.

The restriction was an artifact anyway: `button_mask` exists because
`combo_look_lr` matches queue entries by exact state and a held button disturbs
that. It is the same class of artifact `joyskip` fixes on the direction side.
Nothing ever chose "you may not special while blocking".

One implementation note, because the obvious version is wrong: `is_stick_away`
is the natural call and cannot be used here. It reaches `is_he_right`, which
compares against **a8** - and in that window `a13` has been switched to the
victim while `a8` is still the *attacker's* object, so it compares the attacker
with himself, answers "not to the right" every time, and guards on one stick
direction only. `ihb_stick_away` takes both objects off the victim's own
process and never reads `a8`.

* **Blocking does not affect motion history.** A held button makes no new queue
  entry, so the history is untouched. But see section 4.5: holding block makes
  the *match* fail, which is a different failure with the same symptom.
* **Whether a buffered special may fire out of blockstun** is the single most
  impactful decision in this doc for match pacing, and it is genuinely open -
  there is no buffer today, so there is nothing to grandfather.

---

## 7. Netplay determinism - MOSTLY RESOLVED BY CONSTRUCTION

This is TMS34010 assembly running under MAME / FBNeo, with netplay through the
`freeplay-*` stack ([NETPLAY.md](NETPLAY.md)). Rollback snapshots the entire
machine.

Consequently:

* **There is no float anywhere in this path.** The 34010 has no FPU.
* **Nothing can live "outside the savestate."** The queue, the timers and every
  `l_*` cooldown are in RAM, and RAM is the savestate. The classic failure the
  draft warns about - charge accumulators desyncing silently - is not
  expressible here.
* **Collision iteration order is fixed** by the display-list walk. There are no
  hash maps.

One real finding survives, and it is the draft's own opening line for this
section:

> **The port is read live, not latched.** `joystick_in_a0` (JOY.ASM) does
> `move *a0,a0,l` straight off `p_joyport` every time it is called, so two
> processes in the same frame can see different stick states.

Harmless under emulation, where the port is stable for the frame. Fatal to
section 3's "SOCD resolved once at sample time", which needs a single latch
point to resolve *into*. **Latch the port once per tick before doing SOCD**, or
the resolution happens a different number of times depending on which processes
ran.

---

## 8. Per-character command tables

`combo_edit.py` already holds all 91 records and can print them decoded, both
facings:

```
python combo_edit.py list
python combo_edit.py show scom_jc_shoruken
```

This is the natural second pack after the strike boxes - see
[COMMUNITY_PACKS.md](COMMUNITY_PACKS.md) and [BOXLAB.md](BOXLAB.md). The table
does not need to be hand-maintained here; it needs an exporter.

---

## 9. Measurement and validation

Rigs that already exist, and what each one settles:

| rig | settles |
|---|---|
| `tools/sweep_addon_latency.lua` | acceptance cost, button to move and button to hit |
| `tools/sweep_addon_buffer.lua` | that there is no buffer, and where the cliff is |
| `tools/sweep_addon_droprate.lua` | which hazard rejected a motion - one at a time, caused on purpose |
| `tools/sweep_addon_combogap.lua` | gap tolerance per motion shape |
| `tools/sweep_addon_twobtn.lua` | two-button separation window |

**Attributing a drop in the wild is impossible from outside** - nothing reports
which check rejected a motion. That is why each hazard is caused deliberately
rather than sampled. Any new leniency rule needs the same treatment, or its
success rate cannot be read.

Still to do: end-to-end latency measured rather than estimated, offline and
online, so a latency complaint can be separated from a leniency complaint.

---

## 10. Open decisions

Resolved above and struck from the draft's list: tick rate, facing storage,
charge moves, button priority.

1. ~~Diagonal and stray-entry leniency~~ - **done.** `joyskip 2` with an
   anchored first step, audit at zero. Sections 2.3 and 2.3.1.
3. SOCD: horizontal and vertical, and latching the port to make it stick.
   Sections 3 and 7.
4. Per-entry facing in the queue. Section 2.2 - blocked on companion section 7.
5. Input buffer / cancel buffer / negative window sizes. Section 5.
6. Buffer clear on stun entry.
7. Wakeup buffer scope.
8. Illegal buffered move: consumed or ignored.
9. Special out of blockstun.
10. Which handlers relax `button_mask` to let Block stay held. Section 4.5.
11. Whether `combo_slack` should stay online-only now that it is proven.
