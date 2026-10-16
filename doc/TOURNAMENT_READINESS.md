# Tournament readiness — the requirements that are still missing

Written 2026-08-27, by reading the source rather than the changelog. The
question this answers is *"what have we not done yet"*, on three axes the
project has been working on piecemeal — **balance**, **skill expression**,
**hitbox accuracy** — plus four more that a competitive scene will hit
immediately and that nothing in `doc/` currently owns.

**Everything here is a gap, not a complaint.** A lot of ground is already
covered and is deliberately not repeated:

| already owned by | axis |
|---|---|
| [HITBOX_MODEL.md](HITBOX_MODEL.md) | how a hit is decided, and six named weaknesses (four fixed) |
| [BOX_ALIGNMENT.md](BOX_ALIGNMENT.md) | is the box live on the frame it was drawn for |
| [FRAME_DATA.md](FRAME_DATA.md) | strike geometry, damage, active windows |
| [MOVE_MATRIX.md](MOVE_MATRIX.md) | predicted connect bands per character |
| [BALANCE_AUDIT.md](BALANCE_AUDIT.md) | strike-table outlier screening |
| [COMBO_SHEET_AUDIT.md](COMBO_SHEET_AUDIT.md) | the SuperCombo model checked against this build |
| [CORNER_ROUNDHOUSE.md](CORNER_ROUNDHOUSE.md) | one loop, measured properly |
| [AI_DRONE.md](AI_DRONE.md) | thirteen passes of drone work |
| **[DEVIATIONS.md](DEVIATIONS.md)** | **every departure from the arcade, and the evidence for it** |
| [INPUT_MODEL.md](INPUT_MODEL.md) | latency, buffering, the switch queue, every combo window |
| [NETPLAY.md](NETPLAY.md) | determinism for rollback |
| [PERFORMANCE.md](PERFORMANCE.md), [FRAME_TIME_UNDER_LOAD.md](FRAME_TIME_UNDER_LOAD.md) | frame budget |

**A note on the word "retail" in this document.** It means the pristine
read-only copy of the leaked source at `Workplace/mk2-readonly/mk2-main`,
NOT "our tree with its switches at 0". Those `.else` branches are *intended*
to be retail, which is not the same as verified. Every retail claim added on
2026-08-29 was checked by diffing the routine against that tree:
`two_button_check`, `knee_check`, `button_mask` and `sq_punch` all confirmed.
**It does not build as-is** — attempted 2026-08-29 and got 12 of 70 objects
before stopping; see `project_retail_build_attempt` in memory and the working
tree at `C:	mp\mk2-retail`. Two large patch classes turned up that are NOT in
the list below: retail uses TI's `>14` hex prefix throughout (8,000 constants
across 56 files, and neither setting of GSPA's `-H` accepts it), and its
directive strings are single-quoted (`.file 'x'` reads as a character
constant). Both convert mechanically. It then stops on branch-range errors
(`jrge` to a label that moves between passes) which have to be fixed per site.
The structure is friendlier than the syntax: the link list is **70 of 71
compatible**, only `MKHANG.OBJ` being ours.

That matters for the "measured only on our build" caveat 5.3 carries. The leak is incomplete in exactly the ways
CLAUDE.md lists: `MACROS.HDR` still has 50 `$end` where GSPA 6.10 needs
`$ENDM`, DIAGCMOS has none of its twelve I/O primitives, `secbust_proc`
and `mk2_court` are missing, and there is no build tooling in the tree at
all. A retail ROM and `mk2.map` are reachable - copy it out, re-apply the
build patches, build with our scripts - and worth noting that every one of
those patches is macro syntax, diagnostics or a cross-OBJ branch fix, so
the result would be gameplay-identical to retail even though it is not
byte-pristine. Nobody has done it; until someone does, "retail" here means
verified by READING that source, not by running it.

### Verified against the retail source, 2026-08-29

Every structural fact the nine open rulings rest on, checked by reading
`mk2-readonly/mk2-main` rather than inferred from our switches. **All of it
is Boon's** - none of these behaviours were introduced here, which is what
makes them safe to rule on.

| fact | ruling it supports | retail |
|---|---|---|
| `jrn`/`jreq block_is_useless` - *"block or no ---> he's screwed!"* | #6 chip never kills | confirmed |
| `block_exit` does `clr p_hit` - *"you gotta start the count over"* | #7 the corner-infinite enabler | confirmed |
| `its_a_tie` is a bare `retp` | #9 unbounded match loop | confirmed |
| `stk_sauppercut` box is `+27..+78` (`>4e` offset, `>33` size) | the point-blank dead zone | confirmed |
| `reaction_tables` -> `react_to_hh`, `react_to_lk` | on-hit varies by ATTACKER | confirmed |
| `sq_punch` insets 3W/8 a side, wrong comment included | #5 `perpiece` | confirmed |
| `button_mask` includes BLOCK | holding block kills specials | confirmed |
| `two_button_check` window is 2 ticks | the two-button change | confirmed |
| `knee_check` 64 px + airborne exemption | the high-kick report | confirmed |

The one thing this cannot settle by reading is anything measured in motion -
5.3's throw and trade results still say "measured only on our build", because
their rigs need symbol addresses and the retail tree does not build (see
above).

## Priority

Ordered by *how much a tournament player would notice*, not by effort.

| # | Gap | Axis | Size |
|---|---|---|---|
| 1 | BUILT — startup, recovery, on-block and on-hit ([FRAME_ADVANTAGE.md](FRAME_ADVANTAGE.md)). Coverage 79/177 -> **189/262**; the remaining 'no handler' bucket is now split four ways, and 69 of it is projectile boxes that have no handler by construction | skill | large, mostly extraction |
| 2 | DONE — gated on `f_netplay`. **Input path measured**: accept 3 ticks (55 ms), impact 9–12; and there is **NO buffer** — an input while busy is discarded, so a punish must be timed | skill | one line + a decision |
| 3 | Blockstun MEASURED: 4/8/12/16 ticks, per reaction not per move — policy call still open | balance | measurement, then a policy |
| 4 | TESTED: ducking clears high attacks 5/5 vs 0/5 — high/low DOES work. Downgraded from build to verification | hitbox | large |
| 5 | `perpiece` is FREE in frame time and **closes a measured 27 px band where a kick visibly passes through the opponent and cannot hit** (victim's hittable column is 18 px of a 62 px sprite). It is not extra reach, it is the reach you can see — ruling now well-posed | hitbox | decision |
| 6 | CORRECTED: chip never kills — the BLOCK is discarded when it would, and you eat the clean hit. Switch built (`chipfloor`), default retail | balance | decision, small code |
| 7 | Juggle audit — string lengths MEASURED (avg 2.1–3.4, cap 5); **damage ceiling computed**: whole non-boss cast inside a 10% band, Kahn's 3-hit ceiling is 117% of a bar. Real routes still open | balance | rig time |
| 13 | Damage scaling BUILT behind `dmgscale`, default OFF and measured (5-hit strings -45%) - a curve to play, not a decision made | balance | decision + ~12 instructions |
| 8 | OUT OF SCOPE — owned by the freeplay-gametalk frontend, not this ROM | skill | medium build |
| 9 | TESTED: an equal-bar timeout awards NOBODY and the match loop is unbounded — 2 rounds, 0 wins. Ruling still needed | rules | small |
| 10 | P1/P2 symmetry MEASURED on all three: trades **P2 8-0**, throws **P2 88-0**, round start **clean** (both move at rel=3). Side-swap controlled; ruling still needed | rules | rig, small |
| 11 | DONE — three locks: `balance.lock` (394) + `hurtbox.lock` (361) fail Phase D; `behaviour.lock` (10 canonical interactions) runs beside the sweep | process | small |
| 12 | DONE — [MOBILITY.md](MOBILITY.md): walk spans 80% across the cast, jump is IDENTICAL for everyone. Now locked | balance | extraction |

---

# 1. Frame data stops at the active window

## 1.1 Startup is missing on purpose, and that is now the blocker

[FRAME_DATA.md](FRAME_DATA.md) says it out loud: *"Startup is not in this
table."* The windup is `act_mframew` playing rows out of a per-character
`.TBL` ani table indexed by `a9`, and that parse was left rather than guessed.

Fine as an interim. But **startup is the number a competitive player asks for
first.** Without it:

- "what beats what" is unanswerable — [MOVE_MATRIX.md](MOVE_MATRIX.md) ranks
  moves by *reach*, which is only half of it;
- the anti-air work in [AI_DRONE.md](AI_DRONE.md) (pass 11) is tuned against
  measured behaviour rather than against a known startup;
- nobody can say whether a punish is guaranteed, only that it landed once.

**BUILT 2026-08-27** — `tools/frame_advantage.py` -> [FRAME_ADVANTAGE.md](FRAME_ADVANTAGE.md).
Exactly the parse this section predicted: the same lane walk, with a counter.

    startup = (SLEEPING rows in part one) x a0

The word *sleeping* is load-bearing. An `ani_nosleep` row is displayed and
passed straight through, so it costs nothing — Baraka's swipe is 9 ticks from
three sleeping rows at 3 ticks each, not 12 from four rows.

**Validated against a live tick-by-tick capture** of that move
(`tools/sweep_addon_swipe.lua` measured 9 startup / 4 active / 14 recovery):
the extractor returns **9 / 4 / 14**.

Coverage: **179 moves with startup** of 262 with a resolved handler, up from
79 of 177 on 2026-08-28.

**The single biggest cause was one regex, and it had hidden five characters
entirely.** Ani tables are ALIASED the same way strike records are — the ninja
table is four labels stacked over one body:

```
sz_anitab1
rp_anitab1
sc_anitab1
sm_anitab1
        .long   a_njstance
```

`parse_anitabs` required a `.long` on the line after the label, so only the
**last** alias matched. Smoke came out with all 67 lanes while Sub-Zero,
Reptile and Scorpion had **zero**, and the same shape hid Kitana and Mileena
behind `fn3`. Five characters had no animation lanes at all, so their uppercut,
both ducking attacks and both jump attacks reported "no ani lane" and were
silently absent from every audit built on this parse. Allowing stacked labels:

| | before | after |
|---|---|---|
| moves with a resolved handler | 177 | **262** |
| with startup | 119 | **179** |
| with recovery | 82 | **122** |
| complete (startup + active + recovery) | 50 | **75** |
| with an ON-BLOCK number | 70 | **105** |
| "no ani lane" gap | 96 | **11** |

A second-order effect worth noting, because it cuts the other way: making
those characters visible also made them eligible for rows they cannot reach.
BOX_ALIGNMENT.md's "no overlap at all" list jumped to 17 — a parser fix
presenting as sixteen new hitbox defects. Chasing that down improved the audit
itself, in three steps, each one structural rather than a keyword filter:

1. **The giveaway is now applied, not just described.** An `assumed` row whose
   contact pose is idle art (stance, walk, die) means the character does not
   have the move. Those are listed separately with their reason.
2. **The bosses do not use the standard ani layout at all.** Kintaro has 24
   entries and Shao Kahn 26 against the cast's 67, so `ani1[21]` is a sweep
   for everybody else and `a_shredded` for them: an index lookup against a
   normal-cast handler is meaningless, not merely unreachable. Detected by
   table shape, so it keeps working if the tables move.
3. **A handler that names its owner is not an `assumed` row.** `do_jc_split`
   is Cage's, and the audit had no name-prefix fallback, so it was applying
   Cage's split to four ninjas. `move_matrix` already had that map;
   it now lives in `box_align_audit` — the lowest of the three modules — and
   `move_matrix` re-exports it so the two cannot drift.

**A third instance of the same class, found while building 3.5.** A frame's
strip list can span several lines, and `parse_frames` required it on one:

```
LKWALK1 .long   LKWALKLEG1A
        .long   LKWALKTORSO1A,LKWALKTORSO1B,0
```

Kung Lao's whole list sits on one line; Liu Kang's does not. So `LKWALK1` was
not a known frame at all — and a lane containing an unknown frame is abandoned
wholesale by every consumer. Following the continuation lines takes the frame
table from **3,303 to 4,321** entries (+31%), and startup coverage from 179 to
**189**, complete rows from 75 to **83**.

That is now three separate parsers bitten by the same shape: aliased labels
(`parse_records`, `parse_anitabs`) and multi-line continuation
(`parse_frames`). When a fourth turns up, this is the pattern to check first.

Result: **zero** boxes with no overlap, and the "reaches 24 px or more past
the art" list drops from 25 rows to **3**, each of them a character that
genuinely has the move — Kung Lao's backfist (+36), Baraka's elbow (+27),
Shang's jumping kick (+25) — against a documented median of +1 px. Those three
are worth a look; the other 22 never were.

The extractor now says *where* the missing ones are lost rather than only how
many, and the gap table is ranked by handler — a handler is shared by the whole
cast, so one unparsed routine costs up to 17 rows, and that is the difference
between "88 missing" and "four routines". The +40 came from exactly that:
`air_strike` takes a **different register contract** to `striker` — `a1` =
strike-check frames, `a2` = animation rate — so every jump and flip attack in
the cast reported no tick rate while the numbers sat in registers nobody read.
Symbolic immediates now resolve through the equates too (`movk psleep,a0` is a
tick rate exactly like `movk 3,a0`), scoped to the slots that take a rate and
range-guarded, because `act_*` are equates as well and a blanket resolve would
turn `movi act_juppunch,a0` into a fabricated rate.

The **standing punches are the one thing built and then withdrawn.** They are a
sixth dispatch shape worth 24 rows — the most-used moves in the game — and the
parse predicted 9 + 6 = 15 ticks for Liu Kang's HP. Measured on the machine
with the stick forced neutral: **18 ticks, n=5, zero variance**, which is not
`rows x 3 + 5` for any whole number of rows. The parser is kept, its output is
not merged, and the reasoning is in FRAME_ADVANTAGE.md. Two traps are recorded
with it, both of which produced a *plausible* wrong answer first: the sweep
walks P1 all fight, so back+HP was measuring Liu Kang's backfist, and at
point-blank `elbow_check` converts HP into an elbow.

The rest are moves whose handler does not resolve at all — and "129 rows have
no handler" turned out to be **four different problems**, which is why it never
moved. FRAME_ADVANTAGE.md now splits it:

| | rows | what it is |
|---|---|---|
| contested | 2 | two handlers claim the index, so the picker refuses |
| this character's routine sets it | 1 | attributable, but not by the handler model |
| a routine sets it, owner unresolvable | 57 | the setter is under an inner label like `dive3` |
| nothing anywhere sets it | 69 | reached another way, or dead |

The **contested** two are worth naming because they are ours: `stk_hhhikick`
is claimed by `do_hi_kick` *and* `do_hh_backfist`, and `stk_lkhikick` by
`do_hi_kick` and `do_lk_backfist`. The backfists were added deliberately
reusing strike offset 0 rather than spending a new record. The refusal is
correct, and now the report names both claimants instead of silently dropping
the row.

Two traps on the way there, both caught before they shipped:

* the first attribution mapped **index → setter globally**, and a strike index
  is per character — it credited `stk_fnspinchop` to `do_sa_leggrab` and
  `stk_ice1` to `do_fan_swipe`, Kitana's moves to Baraka's routines. Every
  attribution is now owner-checked;
* the setter scan looked only for `mov[ki] N,a0` and missed `clr a0`, so every
  character's **high kick** — index 0 — was reported as a record nothing
  selects.

The 69 that nothing selects are listed by name. Most are projectile boxes,
which by construction have no handler: the flying object carries its own
record. Any that are *not* projectiles are dead weight in the strike table.

**Why that population was invisible, found 2026-08-28.** Every ninja special
and projectile enters through the same two lines — `movi <index>,a0` then
`jruc local_zap` — which lands in `do_zap` and jumps through
`projectile_jumps` (MKZAP.ASM) to the real routine, *in another file*. The
handler parse indexed labels per file, so it walked off the end of the stub
into the next `do_` label and gave up: **29 handlers, the entire projectile
population, resolved to nothing.** Following that table takes `parse_handlers`
from **33 handlers to 61**, and FRAME_DATA.md's handler table from 29 rows to
61, with a `via` column naming the routine each stub really runs.

Three traps sit in that one indirection, and all three produce a confident
wrong answer rather than an error:

* a stub and its target **share a name** — `do_noob_slide` exists in
  MOVES.ASM (two lines) *and* in MKZAP.ASM (the move) — so resolving against
  the current file lands back on the stub;
* the scan breaks on any `do_` label, including **the one it just jumped to**;
* `movi 023h,a0` is the *table index*, and leaving it in the rate slot reports
  Noob's slide as running at 35 ticks a row.

Inside a zap handler `a0` carries **projectile velocity**, so the generic scan
is not allowed to continue there at all — the first attempt reported
`do_jc_zaphi` at speed −655360 and `do_jx_airzap` at 524288, which are 16.16
velocities read as ticks per row. What a launcher can honestly give is the
**windup rate on its `mframew`**, anchored at that call and range-guarded:
10 of 28 yield one, all in the 2–4 range projectiles actually use. The row
count in FRAME_ADVANTAGE.md is unchanged by this, because that tool resolves
*which* handler owns a strike index by a separate path.

**And wiring those together turned out to be impossible, for a structural
reason rather than a parsing one.** A projectile launcher **never sets
`p_stk`**: `do_throw_spear` is `clr a9 / get_char_ani2 / movk 2,a0 /
jsrp mframew`, and then it builds an object and hands *that* its own strike
record. There is no (character, strike index) slot to file a launcher under —
the projectile owns the box, the launcher owns only the windup. So they get
their own table in FRAME_ADVANTAGE.md, "Projectile launchers — windup to
release", which is the number a player asks for first: button to fireball.

Getting five trustworthy rows out of it took discarding two plausible-looking
versions:

* **Owner by assumption.** Neither the `ochar` tables nor the handler name
  resolves a character for `do_spear` or `do_throw_ice`, and treating
  "unrestricted" as "all 17" produced `do_floor_ice / baraka / a_sa_spin` —
  Sub-Zero's move credited to Baraka with his SPIN as the windup. The owner is
  at the **dispatch site**: `movi do_spear,a7` sits inside `sc_lo_punch`, so
  the enclosing routine's prefix names the character. All ten launchers then
  resolve, each matching independent expectation.
* **Following jumps to find the windup.** That raised the count from 7 to 10,
  and all three additions were wrong. `do_spit` has no `mframew` windup at all
  (it uses `find_part2` / `face_sleep`), so the scan left the routine, found
  someone else's `mframew`, and paired it with a stale `a9` — Reptile's spit
  came out as 24 ticks off lane `a_acid_fly`, three times any other launcher
  and named after the projectile's *flight*. The scan is now confined to the
  target routine, and a launcher whose windup is not in its own body is left
  out.

The five that survive corroborate themselves: each lane name matches its move
(`a_throw_spear`, `a_spinfan`, `a_fnthrow_sai`, `a_ice_down`, `a_sz_airice`),
which is not something a mis-resolved index produces.

## 1.2 Recovery is missing, and it is per-handler

`striker` ([JOY.ASM:2285](../src/JOY.ASM#L2285)) returns to its caller the
moment the active window ends:

```
attk2   jsrp  act_mframew        <- part one: startup
attk4   strike_check_a0          <- a10 ticks of active
        sleep 1
        dsj   a10,attk4
attk9   retp                     <- recovery is WHATEVER THE CALLER DOES NEXT
```

So recovery is not a property of the strike record at all — it is the tail of
each `do_*` handler, and `frame_edit.py` already knows how to find and edit
those immediates. It has never been *tabulated*.

**BUILT 2026-08-27**, same tool. Recovery = every sleep in the tail plus
`retract_strike` playing the later lane parts at its own rate. **82 moves have
a recovery number, 50 are complete** (startup + active + recovery).

Two traps this hit, both worth knowing before extending it:

* `retract_strike` does **not** match `retract_strike_act` — the underscore
  is a word character — and `kick2`, the shared tail for the high kick, low
  kick and sweep, ends `jruc retract_strike_act`. Every one of those moves
  silently had no recovery.
* The tail scan must follow `jruc` like `parse_handlers` does. `do_lo_kick`
  falls into `kick2` while `do_hi_kick` jumps to it, so a linear scan gave the
  two halves of ONE shared tail different answers — which is impossible, and
  was the tell that the parse was wrong.

Where a handler branches between the strike loop and the retract the row is
marked `~` and the number is the **longest** path: for the kick family that is
the on-hit hangtime (`jrnc` past `sleep 012h`), and the whiff path is 18 ticks
shorter. Splitting hit from whiff is the next refinement.

## 1.3 Frame advantage is computable today and has never been computed

Both halves are already in the source as constants.

**Blockstun** is `block_shake` ([MKREACT.ASM:4693](../src/MKREACT.ASM#L4693)):

```
blk2    do_next_a9_frame
        prcslp a11
        do_next_a9_frame
        prcslp a11
        dsj    a10,blk2          -> 2 * a10 * a11 ticks
```

**Hitstun** is `animate_a9` with a packed `[sleep:16 | index:16]` — e.g.
`r_hipunched` ([MKREACT.ASM:3041](../src/MKREACT.ASM#L3041)) uses
`000030010h`, sleep 3 on slot `0x10`. The row count comes out of **the
victim's** anitab.

That second fact is the interesting one:

> **Hitstun length is per-victim-character data.** The same move produces a
> different advantage depending on who you hit, because the reaction lane
> lives in the victim's animation table. Nobody has measured the spread.

**HALF BUILT 2026-08-27** — `tools/frame_advantage.py` -> [FRAME_ADVANTAGE.md](FRAME_ADVANTAGE.md).

**On block is done.** `block_xfers` is indexed by the LOW byte of the
strike-routine word, and each reaction's `block_shake` gives `2 x a10 x a11` —
confirming this section's guess that it is a ladder, and pinning it at four
values: **4, 8, 12 and 16 ticks**, chosen per REACTION rather than per move.

    on block = blockstun - ((active - 1) + recovery_on_block)

**70 moves have an on-block number. Median -5, range -17 to +7, with 14 moves
plus on block and 56 minus.** Baraka's swipe is -5, the roundhouse -6, the high
and low kicks -13, the knee +7.

One thing had to be got right for the column to mean anything: the `recovery`
column is the LONGEST path, but the on-block number uses only the sleeps BEFORE
the first branch. The kick family's tail is `jrnc kik3 / sleep 012h` — on-hit
hangtime that does not happen on block. Counting it made every kick read 18
ticks worse than it is; excluding those rows entirely left **two** moves in the
whole game with a number. Splitting at the branch gives 70.

**On hit is now built too — and this section's premise needed one correction.**

Hitstun is not simply per-victim. BOTH fighters decide it:

* the reaction ROUTINE comes from `reaction_tables[**ATTACKER** ochar]`, indexed
  by the HIGH byte of the strike-routine word. `strike_check` reads
  `*a8(ochar)` and **a8 is the attacker** at that point (a10 is the victim) —
  and the tables are named for it: `react_to_hh`, `react_to_lk`, "react TO liu
  kang";
* that routine supplies the `animate_a9` pair `[sleep:16 | index:16]`;
* only the row COUNT comes from the **victim's** anitab, because `animate_a9`
  calls `get_char_ani` inside the victim's process.

**The spread is large and nobody had measured it.** Being swept:

| victim | hitstun |
|---|---|
| Kintaro | 15 ticks |
| most of the cast | 20–30 |
| Shao Kahn | **35 ticks** |

so one sweep is **−3 on hit against one character and +17 against another** —
a 20-tick, 366 ms swing from the victim alone. `r_hipunched` is 12 for almost
everyone and 21 for Shao Kahn; `r_hikicked` is 15 or 18; `r_lokicked` is flat
20 for all.

**57 moves have an on-hit range, 37 of them vary by victim.** That is a real
balance fact for a scene to know: whiff-punish confirms that work on one
character do not on another, and it is not a property of the move.

## 1.4 There is no trade model

Two boxes live on the same tick — who wins? `strike_check` is called from each
fighter's own process, so the answer is *whichever process the scheduler ran
first*, which is fixed process order, not a game rule. Nothing documents it and
nothing tests it. See also 5.3.

---

# 2. Execution and inputs

## 2.1 Every special in the game is 96 ms more lenient than retail

Two sites, both unconditional:

- [MOVES.ASM:7318](../src/MOVES.ASM#L7318) — `button_look_lr`
- [MOVES.ASM:7328](../src/MOVES.ASM#L7328) — `combo_look_lr`

```asm
        move  *a11+,a9,w      ; a9 = time frame allowed (from the combo table)
        addi  6,a9            ; netplay: widen window 6 ticks (96ms) to cover input delay
```

The comment says netplay. The code says **always**. A cabinet, a local 2P
match and an offline practice session all get the widened window, and
`f_netplay` — which exists, at [RAM.ASM:432](../src/RAM.ASM#L432) — is not
consulted.

This is the single largest undeclared change to execution difficulty in the
build. Six ticks is a lot against windows that `combo_edit.py window` prints in
the 0x10–0x30 range.

**DECIDED AND BUILT 2026-08-27 — option 1.** The code now does what its own
comment always claimed: `combo_slack` is gated on `f_netplay`, so **offline is
retail-exact and only an online session is compensated.** `f_netplay` is
host-written and zero on a cold boot, so the cabinet path is the default.

Both magic `addi 6,a9` sites are gone; the value is one declared equate in
[MAINEQU.ASM](../src/MAINEQU.ASM):

```asm
combo_slack             .set    6       ; ticks of netplay slack
combo_slack_online      .set    1       ; 1 = only online, 0 = always (old behaviour)
```

So option 2 remains one line away — set `combo_slack_online` to 0 and publish
the build as deliberately lenient. Option 3 (a CMOS/DIP value) is not built.

**The measurement that made the case.** +6 is not uniform across the 90 combo
records — it helps most exactly where execution was meant to be hard:

| window | combos | +6 is |
|---|---|---|
| 0x10 (16 ticks) | 7 | **38% wider** |
| 0x18 (24) | 10 | 25% wider |
| 0x24 (36) | 10 | 17% wider |
| 0x38 (56) | 42 | 11% wider |

**Verified**: clean build, sweep 22/22 PASS, and Liu Kang's F,F+HP fireball
fires identically often offline with the tight window (222 frames of raised
object count, the same figure as the widened build). Note the limit of that
evidence — the rig inputs comfortably inside the window, so it proves specials
still match, not that the boundary is exactly retail; the boundary follows from
the `addi` simply being skipped.

**Unrelated pre-existing failures found while checking this**, and confirmed
pre-existing by A/B against the old behaviour — identical failures both ways:
`run_jade_boomerang_test.ps1` reports `jade_flash_free` and
`jade_flash_cooldown_reuse` never reaching action 0x115, and
`kitana_spinchop_works` never reaching 0x111. Two Block+direction specials are
failing their own test and it is nothing to do with input leniency.

The effective per-move window (table value, **+6 only online**) belongs in the
player-facing move list (6.3).

## 2.2 The input model is undocumented, and it has sharp edges

Three behaviours a tournament player will hit within an hour, none written
down:

- **The port is read live, not latched.** `joystick_in_a0`
  ([JOY.ASM:704](../src/JOY.ASM#L704)) does `move *a0,a0,l` straight off
  `p_joyport` every time it is called. Different processes in the same frame
  can see different stick states.
- **Any extra button held kills the match.** `combo_look_lr` opens with
  `button_mask` then `jrne combono` — *"other buttons pressed ---> NO !!!"*.
  Hold block, or ride a second button, and the motion silently does not
  register.
- **Matching is exact-state, entry by entry**, walking `p?_jcq` backwards
  through `[switch,time]` pairs. There is no partial credit and no cleanup of
  a stray diagonal.

- **Two buttons "at once" is the hardest input in the game.**
  `two_button_check` ([MOVES.ASM](../src/MOVES.ASM)) wants the partner button
  to be the entry *immediately* before this one AND within **2 ticks — 37 ms**.
  Kitana's fan throw and Reptile's forceball both go through it.

**MEASURED and WIDENED 2026-08-29.** `tools/sweep_addon_twobtn.lua` sweeps the
separation between the two presses and asks whether the move actually came out,
at 150 px where only a projectile can reach — so damage is unambiguous evidence
and no stray poke can score as a success.

| separation | retail | with `twobtn_slack 2` |
|---|---|---|
| 0, 1, 2 ticks | 3/3 | 3/3 |
| 3, 4 ticks | **0/3** | **3/3** |
| 5+ ticks | 0/3 | 0/3 |

**The tolerance goes from 55 ms to 91 ms.** Two switches, both in MAINEQU.ASM
and both locked: `twobtn_slack` (extra ticks) and `twobtn_depth` (how many
queue entries back the partner may sit, so one stray entry between the presses
no longer kills it). `twobtn_slack 0` restores retail exactly.

The trade is real and worth stating: a wider window means an LP→HP string
thrown while holding forward is likelier to come out as a fan. 2 ticks of slack
was chosen as roughly double the retail window rather than the largest number
that felt good, and it is one equate to dial back.

One measurement trap: the first baseline read 2/3, 1/3, 2/3 at separations that
plainly work. The fan has its **own two-second cooldown** (`l_throw_fan`,
`cmpi 040h*2`), and the 120-tick trial was 2.19 s — so some trials were being
refused by the cooldown, not the button window. At 160 ticks the baseline is a
clean 3/3 / 0/3 split.

**BUILT 2026-08-29** — `tools/input_model.py` -> [INPUT_MODEL.md](INPUT_MODEL.md).
A generator rather than a page, so the structural half is read from the source
each time and cannot drift; the measured half names the rig that produced it,
because nothing in the source states it. It carries the queue behaviour above,
the latency and no-buffer results from 2.3/2.4, every special-move window with
`combo_slack` applied, and the two-button numbers.

It also settles a scare of my own making. The window spread looked alarming —
42 of 90 records get 56 ticks while the tightest seven get 16 — so I went to
widen them, and measured first. **The spread tracks the difficulty of the
motion, not its length:** every 16-tick record is a *roll* (two different
directions, one hand movement), and a *double tap* of one direction never gets
less than 24, because the stick has to return to neutral in between.

Measured with `tools/sweep_addon_combogap.lua`, sweeping the gap between the
two inputs: the roll accepts **1–10 ticks** (up to 183 ms) and the tap
**4–16** (293 ms). Neither is demanding. The tap fails at a gap of 2 for the
opposite reason to the one expected — the stick has not been *released* yet,
so the second tap never becomes a second queue entry. Release between taps;
speed is not the problem.

So the `combo_floor` switch I was about to build would have loosened windows
that are already loose. **The only genuinely tight input in the game is the
two-button one**, which is the one thing that was asked for and is now fixed.

**DROP RATE MEASURED 2026-08-29** — `tools/sweep_addon_droprate.lua`.
Attributing a failure in the wild is impossible from outside, since nothing
reports which check rejected, so each hazard is introduced **on purpose**
against a motion already measured as reliable (Reptile's spit at an 8-tick
gap), four tries each:

| what the player is doing | move comes out |
|---|---|
| nothing extra (control) | **4/4** |
| holding **Block** | **0/4** |
| riding a second attack button | **0/4** |
| **tapping** Down between the two forwards | **0/4** |
| **holding** Down across the whole motion | **4/4** |

**You cannot hold Block and throw a special** — not harder, it does not come
out at all, and any second button does the same. That is the edge most likely
to be blamed on the player, and it is the machine.

The last two rows are the non-obvious pair and they answer the section's own
question about "a stray diagonal": **holding a direction is free, tapping one
is fatal.** Riding Down through the whole motion costs nothing because a held
direction creates no new queue entry; a Down *tapped* mid-motion creates one,
and a mismatched entry is never cleaned up. A sloppy roll through down-forward
is harmless; a deliberate extra input is not.

All of it is in [INPUT_MODEL.md](INPUT_MODEL.md).

## 2.3 Nobody has measured end-to-end input latency

[NETPLAY.md](NETPLAY.md) records that debounce went from 2 frames to 1 — and
that change is global, so offline play got it too. What was never measured is
the whole path: button edge to the tick the move's first active frame lands on.

**MEASURED 2026-08-29** — `tools/sweep_addon_latency.lua`, Baraka against a
standing dummy, eight trials a case, **zero variance on every row**:

| move | accept | impact | implied startup | extractor says |
|---|---|---|---|---|
| high punch | 3 | 12 | 9 | — (`joy_hi_punch`, withdrawn) |
| low kick | 3 | 9 | **6** | **6** ✓ |
| swipe (back+HP) | 3 | 12 | **9** | **9** ✓ |
| uppercut (down+HP) | 5 | 9 | 4 | 8 ✗ |

*accept* is ticks from the button going down to P1's action changing;
*impact* is ticks to the dummy's health dropping. **Acceptance is 3 ticks —
55 ms — and a hit lands 9 to 12 ticks (165–219 ms) after the press.** The
uppercut accepts two ticks later than everything else because the duck has to
resolve first.

The interesting part is the cross-check. `impact − accept` is the move's
startup measured a completely different way from the source extraction, and
for the low kick and the swipe **the two agree exactly**. They disagree only on
the uppercut — which is the one move `box_align_audit` already excludes for
being structurally different (`upcut_striker` holds no single contact pose).
So the latency rig independently confirms FRAME_ADVANTAGE's startup column for
the `striker` family and isolates the exception to a case already known to be
special.

Two rig errors were caught on the way, both of which produced confident
numbers:

* acceptance was first measured as "P1 left stance" — but the uppercut holds
  *down* and the swipe holds *back*, so both had already left stance before the
  button and scored **accept = 0**. It is now baselined against the action at
  the moment of the press.
* the uppercut knocks the dummy over, so a trial starting while he was still
  on the floor scored an impact from the previous hit. Trials now require the
  dummy standing and at full health when the button goes down, and the rig
  **reports how many it rejected** — 4 of 8 — rather than quietly averaging
  them in.

## 2.4 No buffering during recovery

Whether an input entered during hitstun/blockstun/recovery survives to the
first actionable frame is not documented and, from the queue design, probably
depends entirely on the window arithmetic in 1.3 lining up.

**MEASURED 2026-08-29 — there is NO buffer.** `tools/sweep_addon_buffer.lua`:
P1 throws a high punch, then a low kick is pressed K ticks later, and the kick
is identified by its *action* (`act_medkick`) rather than by damage — at this
range the punch also connects, and "health dropped twice" cannot tell a
buffered kick from a second hit.

| K | low kick comes out |
|---|---|
| 4, 8, 12, 15, 16, 17, **18** | **never** |
| **19** | at 22 |
| 20 | at 23 |
| 21 | at 24 |
| 22, 24, 28, 32 | at K+3 |

**An input pressed while the fighter is busy is discarded, not queued.** The
first tick a new input is accepted is **K=19**; anything at 18 or earlier is
gone. From 19 onward the kick lands at exactly `K+3`, which is the same 3-tick
acceptance latency 2.3 measured from neutral — so once actionable there is no
extra cost, and before actionable there is no credit.

The practical consequence, and it is the answer to "why did nothing come out":
**a punish has to be timed, not held early.** Pressing during the recovery of
your own move does nothing at all — the input is not stored and replayed. At
18.28 ms a tick the window is real, and any practice advice built on
buffering (mash it out early, it will come out on the first frame) is wrong
for this game.

Worth noting for 7.3 as well: with no buffer, an input a netplay session drops
is simply lost — there is no queue for it to survive in.

---

# 3. Hitbox accuracy

## 3.1 High/low — the hurt box has no vertical squeeze, but ducking works anyway

[HITBOX_MODEL.md](HITBOX_MODEL.md) section 5 names it: *"No vertical squeeze,
and nothing distinguishes body parts."* The hurt box is the bounding box of the
victim's multipart sprite, horizontally squeezed to a quarter and **not
squeezed vertically at all**.

The consequence is bigger than it sounds. Ducking under a high attack works
only where the *bounding box top* drops below the strike box — not where the
head goes. A crouch that visually clears a high kick can still be hit, and a
`sf_duck`-flagged move is the only thing that formally knows about stance.
High/low is the spine of a fighting game's neutral, and here it is an emergent
property of sprite extents.

**TESTED 2026-08-28, and the consequence claimed above does not happen.**
`tools/sweep_addon_highlow.lua`, mirror match, victim standing vs holding Down,
same attack at five distances well inside its measured band:

| attack | standing | ducking |
|---|---|---|
| roundhouse | **5/5 connect** | **0/5 connect** |
| high kick | connects | 0 of the 3 trials that fired |

`0 never fired` on the roundhouse run and the victim spent 503 frames in
`act_duck`, so this is not a rig that missed. **Ducking clears both high
attacks completely.**

(The high kick shows two `?` trials at 40 and 50 px: `knee_check` converts a
close-range high kick into a KNEE, which is real game behaviour and not a
misfire. The trials that did fire behaved like the roundhouse.)

The MECHANISM in this section is right — there is no vertical squeeze, and what
decides it is whether the bounding-box top falls below the strike box. What is
wrong is the inference that it therefore does not work: the victim's anipoint
is head-anchored, so crouching drops his whole box, and it drops far enough.
The game also has a formal low-attack flag after all — **`sf_duck`, on 11
distinct records** (every character's sweep, plus two low duck kicks).

**Scope of the test, honestly:** one character, two attacks, five distances.
It disproves "high/low is not real"; it does not prove every high attack on
every character clears every crouch. A move with an unusually low `y_offset`,
or a character with a tall crouch, could still behave the way this section
feared, and the cheap way to find out is this rig run across the ~70 moves that
have a measured band.

So this is **no longer the largest genuine hitbox item left** — it is a
verification job, not a build. The vertical-squeeze interim proposed here
should not be built without a move that demonstrably needs it.

## 3.2 The two best hitbox mechanisms in the tree are switched off

> **MEASURED 2026-08-29, from a play report.** A screenshot of Baraka's high
> kick passing through a standing opponent's head with no hit. It is not a
> bug — it is `sq_punch`'s squeeze, and it is now quantified.
>
> The victim's sprite is **62 px wide**; `sq_punch` insets 3W/8 from each side,
> leaving a hittable column of **18 px — 29% of him**. The other 71%, head
> included, is scenery.
>
> Measured with `tools/sweep_addon_hikick.lua`, sweeping distance and recording
> both damage and which action actually came out (a high kick inside 64 px is
> silently a knee, so damage alone cannot tell a whiff from a conversion):
>
> | | connects out to | art still overlaps to |
> |---|---|---|
> | retail (`perpiece 0`) | **88 px** | 115 px |
> | `perpiece 1` | **112 px** | 115 px |
>
> So retail leaves a **27 px band where the kick visibly passes through the
> opponent and cannot touch him**, and `perpiece` closes it to 3. The
> arithmetic predicted the visual limit at 115 before the run; per-piece
> stopped at 112.
>
> **That reframes the decision.** `perpiece` is not "more reach" — it is *the
> reach you can already see*. Combined with the frame-time measurement
> (0 of 18,832 — free), the case against it is now only that it lengthens every
> move's effective range to its visual range, which changes spacing across the
> whole cast. That is still a ruling, but it is no longer a vague one.
>
> Two hypotheses died on the way, both of which sounded right: that
> `knee_check`'s airborne exemption opened a point-blank hole (airborne
> connects at *every* distance from 15 px, so no), and that the box was drawn
> shorter than the leg (box +23..+83 against art -25..+82 — they agree). The
> victim's column was the one that moved.
>
> **And it is Boon's.** Checked against the read-only retail source
> (`mk2-readonly/mk2-main`) rather than inferred from our switches being 0:
> retail's `sq_punch` is the same 3W/8-per-side inset, *including* its own
> wrong comment `4/8 + 1/8 = 5/8`. The phantom band is original MK2. That
> makes `perpiece` a deliberate **deviation from retail** — which is an
> argument for taking the decision seriously, not for assuming it is a fix.


[MAINEQU.ASM:65,67](../src/MAINEQU.ASM#L65):

```asm
stkphase  .set  0     ; let a move's hitbox CHANGE across its active window
perpiece  .set  0     ; how strike_check decides what the strike box hit
```

Both are built, both are documented, both default to off. That is the right
call for shipping and the wrong place to leave a tournament build. `stkphase`
in particular removes the one-rectangle-for-the-whole-swing approximation that
makes long reaching moves feel wrong on their first and last active frames.

**These two are not the same kind of decision, and the section above conflates
them.** `perpiece` is a switch. `stkphase` is not:

```asm
stk_phase_tab
    .long   0            ;  0 - hathead
    .long   lk_phases    ;  1 - liu kang     <- the ONLY entry
    .long   0            ;  2 - cage
    ... fourteen more zeros
```

One character has phase data, and within Liu Kang only the low kick has any, so
`stkphase .set 1` would change **one move in the whole game**. It is a
data-authoring project with a worked example in it, not a switch. Sizing it
from [FRAME_ADVANTAGE.md](FRAME_ADVANTAGE.md): of 109 moves with a known active
window, **76 have a window longer than one tick** (69 distinct records) and so
could carry a phase; 33 are single-tick and cannot. Windows run 1-6 ticks, with
22 moves at 6 and 21 at 5 - which is exactly where the
one-rectangle-for-the-whole-swing approximation hurts. `hitbox_edit.py` support
is the sane way to author that, because the strike-list indices are hex and
have already caused one wrong-move bug.

**`perpiece` COST, MEASURED 2026-08-27** — `tools/run_perpiece_cost.ps1`, both
passes in one run, overlay off in both so the switch is the only difference:

| | lost ticks | worst overload | peak objects |
|---|---|---|---|
| `perpiece 0` | **0 / 18,832** | 2 | 22 |
| `perpiece 1` | **0 / 18,832** | 2 | 23 |

22/22 PASS both ways. **Per-piece collision costs nothing measurable.**

The overlay's 4 -> 35 figure does not transfer, and the reason is structural:
`piece_overlap` walks up to `PO_MAX` = 13 rectangles per strike check, and
strike checks only run during a move's ACTIVE window, whereas the bit-4 overlay
draws 13 boxes for both fighters on EVERY frame. The meter is the same one that
registered 37-87% lost ticks under that overlay, so it is capable of showing a
cost; there is not one to show.

**`perpiece` BEHAVIOUR, MEASURED 2026-08-27** — `tools/run_perpiece_behaviour.ps1`,
the two range-map rigs with a known-good baseline on this build. Every trial
verified its move fired.

| move | `perpiece 0` | `perpiece 1` | change |
|---|---|---|---|
| Baraka swipe (Back+HP) | connects 20..108 px | connects **20..140 px** | **+32 px reach** |
| Baraka uppercut | connects -60..52 px | connects -60..52 px | none |

So it is emphatically not free in balance terms even though it is free in frame
time, and the effect is **per move**, not a uniform shift.

The mechanism explains both rows. `sq_punch` squeezes the victim to a
quarter-width column centred on his anipoint; `piece_overlap` throws that away
and tests the attacker's box against **each of the victim's actual pieces**,
including limbs that trail well behind the anipoint. A move whose box reaches
far - the swipe's front edge is `oxpos+104` - now catches a trailing piece at a
distance where the narrow column had already ended. The uppercut's box is short
(`+27..+78`) and the victim's near pieces are inside the column already, so
nothing changes for it.

That is the trade, stated plainly: per-piece is what the picture says should
happen, and it lengthens far-reaching moves by roughly the width of a limb.
**Two moves is not the cast.** Deciding this properly wants the band diff across
the ~70 moves that have one, which is rig time on a rig that already exists.

## 3.3 BOX_ALIGNMENT has open rows, and some cannot be closed as-is

**CLOSED 2026-08-28 — the no-overlap list is empty.** It read eight, then
briefly seventeen when the aliased-anitab fix (1.1) made five hidden
characters eligible for rows they cannot reach. Every one of those was an
attribution error rather than a box error, and fixing attribution properly —
apply the idle-pose giveaway; treat the bosses' bespoke 24/26-entry tables as
non-indexable; resolve a handler that names its owner, so Cage's split stops
landing on four ninjas — takes it to **zero**.

The section's own target was "`ochar table`-resolved or hand-checked". Rows
resolved by handler name now say `handler name` rather than `assumed`, which
is the same standard of evidence: the move's name states whose it is.

What is left is the softer list — boxes that **do** overlap but reach well
past the art. That drops from 25 rows to **3**: Kung Lao's backfist (+36),
Baraka's elbow (+27), Shang's jumping kick (+25), against a median of +1 px
across the cast. Those three are a real question for a tournament build; the
other 22 were never about boxes at all.

## 3.4 Projectiles: one aligned, nine to go

**"Nine to go" was a guess, and counting says otherwise.**
`tools/projectile_contact_audit.py` -> [PROJECTILE_CONTACT.md](PROJECTILE_CONTACT.md).

`match_me_with_him` snaps the burst onto the victim's anchor and discards the
height the projectile was flying at. On a level shot that changes nothing —
the projectile is spawned on the thrower's anipoint, so its Y *is* the
victim's anchor Y. It only shows on a **steerable** shot, which is why Baraka's
spark was the one that looked wrong: aimed at the shins it hit low while the
burst still bloomed at chest height.

**13 snap sites: 7 preserve the contact height, 6 discard it — and none of the
six is this defect.**

| site | why it discards |
|---|---|
| `hat_blocked` | deliberate ricochet: +48 px into `multi_adjust_xy` and a velocity written into the burst |
| `jbp_blocked` | the same bounce, modelled on it |
| `lightning_hit` | deliberately **rides the victim's velocity** after the snap — decoupling it would break that |
| `fntele5` | female-ninja teleport lineup, not a projectile hit |
| `jcc_up` | Cage reposition; the source says outright "need to override Y below" |
| `tnt4` | melt/decoy reposition next to the opponent |

Six of the seven that preserve it are **retail** — `fireball_hit` carries its
own comment, *"dont mess with y coordinate"*. So the real state is: Boon
handled this everywhere it mattered, our spark fix restored the one case that
had been missed, and the remaining sites are placing their effects on purpose.

The audit is a tool rather than a paragraph so it cannot go stale: it reports
the *signals* that decide defect-versus-decision — a y offset fed into
`multi_adjust_xy`, a velocity written into the burst, a loop copying the
victim's velocity — and leaves the reading here. One thing it caught on its own
first pass: matching any `movi X,a1` reported the blocked hat's `050000h`
bounce velocity as a **327,680 pixel** offset, so the signal is now anchored on
the `multi_adjust_xy` call itself.

What remains true from the original note: projectile boxes ride the projectile
object, so their front edge is not `oxpos`. That is a reading hazard for anyone
auditing reach, not an alignment bug.

## 3.5 Nothing guards the hurt box against art edits

The hurt box is *computed from the sprite*. So any animation change — a new
frame, a shifted anipoint, a re-cut composite — silently changes what that
fighter can be hit by, on every move in the game, with no diff anywhere.

**BUILT 2026-08-28** — `tools/hurtbox_lock.py` -> `doc/hurtbox.lock`, wired
into Phase D beside `balance.lock`. **361 locked values**: every character's
defensive lanes — stance, both walks, both skips, duck, the three jumps, turn,
hit high / hit low / hit while ducking, the getups, sweep fall, stumble — each
row recording the lane, its frame count, and the **union** of every pose's
extent in x and y. The union is the point: the hurt box comes from whichever
pose is showing, so the extremes across the lane are what a player can
actually be caught by.

Attack lanes are deliberately excluded. This project adds and re-times moves
constantly, and a lock that failed every time somebody drew a new punch would
be switched off inside a week. The defensive frames are the ones a fighter
wears while making no choice at all.

**Proven to fail, not just to pass.** Shifting one stance strip's anipoint by
4 px is caught, and the diff names the character, the slot, the lane and the
change:

```
-liu kang    00h a_lkstance    7    -29..  +42     +6.. +141
+liu kang    00h a_lkstance    7    -33..  +42     +6.. +141
```

The first attempt at that test *widened a strip by 4 px and was not caught* —
correctly, because `LKSTANCE1A` spans −29..+1 and the lane's right edge is +42
from a different pose, so the union genuinely did not move. Worth recording:
a guard over unions needs a perturbation that moves an extreme, or the test
proves nothing.

Ten pairs stay unresolved and are listed in the lock: Kintaro and Shao Kahn,
whose bespoke 24 and 26-entry tables simply have no slot for a duck-hit or a
stumble.

---

# 4. Balance decisions that are screened but never *made*

## 4.1 The outlier list needs a verdict column

[BALANCE_AUDIT.md](BALANCE_AUDIT.md) is explicitly *"a screening tool... It
finds things worth looking at, not things that are wrong."* Twenty-seven
non-boss outliers sit there un-adjudicated. Jax reaching 1.27x the family
median on `duckkickh` is either his identity or a typo, and the difference
matters.

**What to build**: a `verdict` column with three values — `trait` (keep, here
is why), `defect` (fix, here is the value), `undecided` — and once nothing is
`undecided`, freeze the file as the balance baseline (8.1).

## 4.2 Chip damage does NOT kill — the block is discarded instead

[CORNER_ROUNDHOUSE.md](CORNER_ROUNDHOUSE.md) measured it: block mode, 21
blocked roundhouses, **161 HP taken, victim dead at 16 s**. Blocked damage
runs the same `bar_reducer` ([JOY.ASM:1815](../src/JOY.ASM#L1815)) which
clamps at zero and returns "round over".

**THE PREMISE ABOVE IS WRONG, and the truth is more interesting. Corrected
2026-08-28.**

Chip damage **never** takes the last point of health in MK2. `strike_blocked`
([JOY.ASM](../src/JOY.ASM)) checks first, and when the chip *would* be lethal
it does not clamp it — **it throws the block away** and jumps to
`block_is_useless`, the clean-hit path, so the blocker eats the move's FULL
damage instead. Boon's own comment says it out loud:

```asm
        sub  a10,a0                    ; subtract block damage
        jrn  block_is_useless          ; block or no ---> he's screwed!
        jreq block_is_useless          ; block or no ---> he's screwed!
```

Byte-identical in `mk2-src.zip`, comment included, so this is retail.

So the blocking victim in [CORNER_ROUNDHOUSE.md](CORNER_ROUNDHOUSE.md) did not
chip to death — **he was killed by a clean roundhouse while holding block**,
because at low health blocking simply stops working. That is a harsher rule
than chip death, not a softer one: it converts a 8-point chip into a 34-point
hit precisely when the victim can least afford it.

**BUILT AS A SWITCH, DEFAULT RETAIL** — `chipfloor` in
[MAINEQU.ASM](../src/MAINEQU.ASM). 0 = retail (block is discarded when the chip
would be lethal), 1 = the chip is trimmed to leave the blocker on 1 and the
block is honoured. Measured directly, victim held on 6 HP and blocking:

| | minimum HP reached | frames on zero |
|---|---|---|
| `chipfloor 0` | **0** | 3 |
| `chipfloor 1` | **1** | 0 |

Sweep 22/22 PASS with it off.

**Two things this cost, both worth writing down.** First, the obvious place to
clamp — blocked damage at `bar_reducer` — does *nothing*, because a lethal
blocked hit never reaches it; two full A/B runs came back byte-identical before
the early exit turned up. Second, the switch was originally `chipkill .set 1`
tested with `.if chipkill = 0`, which assembled to nothing in **both** states.
There is no `.if <x> = 0` anywhere else in this tree — every conditional is a
truthy test — and the A/B being identical twice for two different reasons is
what made it look like the feature simply did not work.

Measured scale of the ruling either way: chip is a quarter of a move's hit
damage (median 5, range 2-10 across 360 non-boss records).

## 4.3 The juggle audit covers one move on one stage

The cap is `p_hit > 3` in `no_unlimited_airhits`
([MKREACT.ASM:3767](../src/MKREACT.ASM#L3767)) leading to `repell_attacker`,
and `block_exit` ([MKREACT.ASM:4585](../src/MKREACT.ASM#L4585)) **zeroes
`p_hit`**. That structure — a counter that any block resets — is exactly what
makes MK2's long-standing "corner infinite" family possible, and
[COMBO_SHEET_AUDIT.md](COMBO_SHEET_AUDIT.md) A7 says so.

One loop has been measured properly. What is missing is the systematic version:
**max damage from one opening, per character, per corner state**, driven by the
same harness. The deliverable is a table of "best known combo" per character —
which is both a balance instrument and the thing players will build anyway.

**CEILING COMPUTED 2026-08-29** — `tools/juggle_ceiling.py` ->
[JUGGLE_CEILING.md](JUGGLE_CEILING.md). Deliberately **not** a rig: this
section's own warning is that driving inputs to find the routes measures the
harness's cadence, so instead the ceiling is computed from each character's
highest-damage records and bounded by the string lengths already measured.
It is an **upper bound, not a combo** — nothing checks that those moves can
follow one another in the air.

The comparison is the point, and it is flat:

| | 3-hit ceiling | % of a 161 bar |
|---|---|---|
| **Shao Kahn** | 188 | **117%** |
| **Kintaro** | 133 | 83% |
| Baraka (highest non-boss) | 114 | 71% |
| everyone else | 104–109 | 65–68% |

**The entire non-boss cast sits inside a 10% band**, and every one of them
tops out on a 40-damage uppercut. That is the same conclusion the reach work
reached from the other direction: MK2 differentiates by reach and access, not
by damage. A balance pass that hunts for a character with more damage
potential will not find one.

Two things it does surface:

* **Shao Kahn's three best moves exceed a full health bar** (117%). Whatever
  4.7 rules about boss legality, that is the number the ruling is about.
* Baraka's edge is `stk_shred` at 40 — a second 40-damage move where everyone
  else has one, which is a small, specific, checkable difference rather than a
  vague "Baraka hits hard".

Each ceiling lists **the moves that make it up**, because a ceiling built from
three copies of one uppercut would not be a juggle at all. They are distinct
moves in every row, which is what makes the numbers worth comparing.

Still open: the real routes. That needs either a human with a controller or a
scripted-input rig this section already warns against.

**STRING LENGTHS MEASURED 2026-08-28** — `tools/sweep_addon_phit.lua` across
all 22 sweep battles, purely observational (the drone plays; driving inputs
here would measure the rig's cadence, which has cost this project several
afternoons).

| | |
|---|---|
| strings per battle | 5–10 |
| average length | **2.1 – 3.4 hits** |
| longest | **5, in 20 of 22 battles** |
| Kahn's arena | caps at 2 |
| Kintaro's arena | caps at 1 |

The longest being *exactly 5 nearly everywhere* is the anti-infinite working:
`no_unlimited_airhits` fires at `p_hit > 3`, so a string dies around five. The
cap is real and it holds. What it does not do is make a five-hit string cheap.

## 4.8 There is no damage scaling, and a five-hit string is 62% of a bar

Raised 2026-08-28. MK2 applies **full damage to every hit of a juggle** — there
is no combo scaling anywhere in the tree. Against the measured string lengths
above, and a median non-boss hit of **20** damage across 354 records:

| hits | unscaled | of a 161 HP bar | with 100/75/50/25 scaling |
|---|---|---|---|
| 1 | 20 | 12% | 20 (12%) |
| 3 | 60 | 37% | 45 (28%) |
| 5 | **100** | **62%** | 55 (34%) |

So two openings is a round. Whether that is wrong is a **design call, not a
bug** — MK2 is a high-damage game on purpose and this is retail behaviour.

**The insertion point already exists**, which is why this is worth raising
rather than filing under "big rewrite":

* `bar_reducer` ([JOY.ASM:1815](../src/JOY.ASM#L1815)) receives the damage in
  `a10` and already calls `ochar_xlate_damage`, a per-victim hook table that
  Goro (half damage) and the secret fighters (3/4) use today;
* the victim's process is `*a13(p_otherproc)` at that point, and its `p_hit`
  is the count **before** this hit — exactly the index a scaling table wants;
* `inc_p_hit` runs in `reaction_start_chores`, i.e. *after* `bar_reducer`, so
  the ordering is already correct with no change needed;
* scaling by 1, 3/4, 1/2, 1/4 needs no multiply — `a10 - (a10>>2)`, `a10>>1`,
  `a10>>2` — so there is no `mpyu` register hazard (`MPYU` writes a 64-bit
  result across `a10:a11` and `a11` is live).

Estimated cost: one equate (`dmgscale`), a four-entry table, and about a dozen
instructions in `bar_reducer`. It would default OFF like `anchorcol`,
`perpiece` and `combo_slack`, so the A/B is a rebuild rather than an argument.

**BUILT AND MEASURED 2026-08-28, DEFAULT OFF** — `dmgscale` in
[MAINEQU.ASM](../src/MAINEQU.ASM), scaling applied in
[JOY.ASM](../src/JOY.ASM) at the clean-hit call to `bar_reducer`. It exists so
the curve can be *played* rather than argued about; it is not on.

Measured A/B over four Dead Pool battles, average HP a string cost the victim:

| string | `dmgscale 0` | `dmgscale 1` |
|---|---|---|
| **1 hit** | 32 / 22 / 25 / 20 | **32 / 22 / 26 / 20** |
| 3 hit | 24 / 22 / 24 | **18 / 18 / 18** |
| 4 hit | 32 / 32 | **20 / 20** |
| 5 hit | 36 / 40 / 40 / 40 | **22 / 22 / 22 / 22** |

The **1-hit row being identical is the control**: the opening hit is never
scaled, which is what the design says and what the ordering has to produce.
Five-hit strings fall about 45%, four-hit 38%, three-hit 22%. Sweep 22/22 PASS
with the switch off, and the switch assembles clean both ways.

Three things had to be right and are worth keeping written down:

* **Scaling belongs at the call site, not inside `bar_reducer`.** That routine
  has three callers and one is `damage_to_me`, where `a13` is the fighter
  hurting HIMSELF - `p_otherproc` there is the opponent, so scaling inside
  would have indexed the wrong fighter's counter.
* **No multiply.** `MPYU` writes a 64-bit result across `a10:a11` and `a11` is
  live; every step is a shift and a subtract instead.
* **The ordering is already correct by accident of the original design.**
  `inc_p_hit` runs in `reaction_start_chores`, i.e. after the damage is
  applied, so `p_hit` is genuinely "hits already taken" at scaling time.

To try it: set `dmgscale` to 1, rebuild, play. The curve (full, 3/4, 1/2, 1/4)
is four shifts in one block and is meant to be edited.

## 4.4 Throws

- One range for the whole cast: `movi 040h,a7` (64 px) at
  [JOY.ASM:1031](../src/JOY.ASM#L1031), the only call site of `toss_check`.
- Escape is *hold away only* (`is_stick_away`) — **there is no throw break**,
  as the drone code itself notes.
- Wall proximity blocks throws for everyone **except Kung Lao**
  ([JOY.ASM:1236](../src/JOY.ASM#L1236), an explicit `ft_hathead` exemption).
- `f_sans_throws` ([RAM.ASM:452](../src/RAM.ASM#L452)) already exists as an
  off switch.

Throws are usually a top-tier tool, and this one has a character-specific
carve-out nobody has ruled on. Needs: throw damage and post-throw positioning
tabulated per character, plus a decision on the Kung Lao exemption.

## 4.5 Death Punch is a live exploit with a known fix and no decision

`punch_sleep` ([JOY.ASM:1359](../src/JOY.ASM#L1359)) re-checks the strike box
every tick for up to five ticks with **no per-attack latch**, so a jab that
misses early and connects late keeps connecting.
[COMBO_SHEET_AUDIT.md](COMBO_SHEET_AUDIT.md) A1 identifies the mechanism
exactly and its glitch ledger costs the fix at *"~2 instructions"*, then leaves
it as *"decide deliberately"*. It is still undecided. For a tournament build
that is not a neutral position — it is a decision to keep it.

## 4.6 Mobility — tabulated 2026-08-28

`tools/mobility.py` -> [MOBILITY.md](MOBILITY.md) + `doc/mobility.csv`, and the
values are now in `balance.lock` too, closing the gap 8.1 named.

**Walk is where the cast differs — and the spread is 80%.**
`get_walk_info_f`/`_b` (MKGUYS.ASM) index a `.word rate,vel` per character, and
`decode_walk_table` does `sll 4,a1`, so the stored word is the 16.16 velocity
shifted right four.

| | forward | |
|---|---|---|
| Smoke, Jade | **4.500 px/tick** | 246 px/s |
| Noob | 4.000 | 219 |
| Shao Kahn | 3.500 | 191 |
| Kitana, Mileena | 3.125 | 171 |
| Kung Lao, Baraka, Kintaro | 3.000 | 164 |
| everyone else (8 characters) | **2.500** | 137 |

**Jump is identical for the entire cast.** `up_vel` (-10.0 px/tick), `up_grav`
(0.5 px/tick²) and the angle-jump x velocity (4.0 px/tick) are single equates,
so every fighter gets the same **20 ticks to apex, 40 ticks airborne, 100 px
high, 160 px far**. Nobody has a better jump — every mobility difference in MK2
is on the ground. Worth knowing before a matchup is argued on jump arcs.

**A finding that belonged with 4.7, now fixed.** Smoke, Noob and Jade walked
60-80% faster than most of the cast *and* already take 3/4 damage via
`ochar_damage_table`. That pairing is boss scaling — built to make a secret
OPPONENT hard — and in a two-player match it simply handed one player both a
mobility and a durability edge, for free: Smoke and Noob share `nj_strikes`
**byte for byte** with the ninjas (all 32 records) and Jade shares `fn_strikes`
with the female ninjas (all 26). Identical moves, strictly better movement.

`secretwalk` (MAINEQU.ASM, default **1**) closes it the same way the damage
half was closed. See 4.7.

Sweep travel and dash are still not extracted (MK2 has no dash; sweep travel is
a property of the move's own handler, not a table).

## 4.7 Boss and secret-fighter tiering

`ochar_damage_table` ([JOY.ASM:1857](../src/JOY.ASM#L1857)): Goro takes half
damage, Shao Kahn has his own scale, and the secret trio take 3/4 — correctly
scoped now to *CPU-controlled only*, so a human Jade is normal. That fix is
done and good.

The **movement** half is now scoped the same way. `secretwalk` (MAINEQU.ASM,
default 1) gates `decode_walk_table` (MKGUYS.ASM) on the identical `ps_active`
test `xlate_secret` uses: a human Smoke or Noob borrows `ft_subzero`'s walk row
and a human Jade borrows `ft_fn1`'s — the walk of the character whose strike
table they already share byte for byte — while a CPU-controlled secret fighter
keeps the boss speed that is the whole point of a secret opponent. Set
`secretwalk .set 0` for retail behaviour. Both halves of the scaling now answer
to *who is holding the sticks*, not to which character was picked.

One caveat on evidence: this is verified **statically**, not in game. A human
secret fighter cannot be produced by any rig — character-select forcing and
`test_mode` both fail to start the fight, and only the select cheat reaches
them — so what is confirmed is that the gate uses `get_char_long`'s exact
indexing, mirrors a shipped and working state test, assembles clean, is in
`balance.lock`, and does not disturb a CPU Smoke (the `smoke_walk` battle
passes the sweep). The human branch wants one manual look.

What is still not decided is whether bosses are legal at all, and if so under
what handicap; the scaling exists and would apply.

---

# 5. Round and match rules

## 5.1 A tie awards nobody a round

`its_a_tie` ([MAIN.ASM:812](../src/MAIN.ASM#L812)) is a bare `retp` — no match
win to either side. A double-KO or an equal-health timeout therefore burns a
round and advances nothing, and `play1` loops for another. In a best-of-3 that
is a stall with no defined bound.

Timeout resolves sensibly — `clock_ran_out`
([MAIN.ASM:815](../src/MAIN.ASM#L815)) falls through into `round_is_over`, so
the higher bar wins — but the equal-bar case lands right back on the tie path.

**TESTED 2026-08-28** — `tools/sweep_addon_tie.lua`, mirror match, both bars
held dead level while the clock ran out. State transitions, verbatim:

```
f=1435  gs=2 r=1 w=0 m=0:0 hp=161:161     round 1 starts
f=4782  gs=5 r=1 w=0 m=0:0 hp=80:80       round over - equal bars
f=4878  gs=6 r=2 w=0 m=0:0                round TWO, match wins still 0:0
f=4975  gs=2 r=2 w=0 m=0:0                round 2 starts
```

**Two rounds played, zero match wins awarded.** The source reading was right:
a tie burns a round, advances nothing, and `jrne play1` only ever exits on two
match wins — `round_num` climbs but is never compared against anything.

(The timeout at f=4782 was the *natural* 99-count expiry ~61 s in, not the
clock forcing at rel 90-132; the game reset the digits under that. The result
is the same and the forcing is unnecessary, but the log should not be read as
proving the forcing worked.)

**Still needs a ruling — and there is no retail default to fall back on**,
because retail simply loops. The options, with what each costs:

| ruling | shape |
|---|---|
| **Round cap** — after N rounds the match ends, higher match wins takes it (or higher combined health if still level) | a counter test at `play3`; a bracket safety valve rather than a balance change |
| **Sudden death** — a tied round is replayed with reduced starting health | more code; changes how a tie *feels* rather than just bounding it |
| **Both credited** — a tie awards a round to each | one `inc` per side in `its_a_tie`; ends a best-of-3 fastest, and can end it 2-2 |

I have not built any of them: unlike `dmgscale` and `chipfloor` there is no
"retail" setting to default to, so picking one is a ruleset decision rather
than a switch with a safe default.

## 5.2 The clock is not seconds, and that should be on the record

`movk 11,a9` ([MAIN.ASM:689](../src/MAIN.ASM#L689)) with `sleep 3` in the inner
loop = **33 ticks per clock unit = 603 ms**. A 99 count is ~59.7 real seconds.
Correct arcade behaviour, and worth stating plainly next to `f_freeze_timer`
([RAM.ASM:97](../src/RAM.ASM#L97)) — which already exists as the training-mode
clock freeze and is host-poked, not ROM-driven.

## 5.3 P1/P2 symmetry has never been measured

Processes run in a fixed order. Identical simultaneous inputs may not produce
identical outcomes — trades (1.4), throw priority when both players input a
throw on the same tick, and round-start actionability all plausibly favour one
side.

**MEASURED 2026-08-27 — the trade case only.** `tools/sweep_addon_trade.lua`:
both ports human, pinned at an exact symmetric distance, same button on the
same frame, 56–96 px, outcome read from `p_hit` (not HP — the sweep harness
pins `p1_bar` to full every frame, which silently scored the first run 0–0).
Every trial verifies BOTH moves fired; a trial where one did not come out is
discarded, so a dropped input cannot read as a side advantage.

| run | P2 | P1 | trades |
|---|---|---|---|
| Baraka vs Scorpion, P1 left | 5 | 0 | 0 |
| **mirror** Baraka vs Baraka, P1 left | 5 | 0 | 0 |
| **mirror**, P1 moved to the RIGHT | 3 | 0 | 0 |
| **mirror**, on the retail collision build | 5 | 0 | 0 |

**Player TWO wins, and nothing ever trades** — the opposite of the usual
assumption. Three confounds ruled out in order: the first run had Baraka (high
kick reach 83) against Scorpion (100), so the mirror match rules out the
character; moving P1 to the right changes nothing, so it is the player *number*
and not the screen side; and the retail collision build gives the identical
result, so `anchorcol` and the swipe work neither created nor removed it. It is
Boon's.

Likely mechanism, **not confirmed**: a fighter who is hit is transferred to a
reaction routine, so whoever's `strike_check` runs first that tick wins and the
loser never gets his own check — which also explains why nothing trades. That
points at process dispatch order, but nothing writes `@active` except `pinit`
and I did not find where a process joins the list.

Scope of the claim: 8 scored exchanges, one move, one spacing band. `mirror_baraka`
(p1=3, p2=3) added to the sweep battle list, because holding the character
constant is a prerequisite for any side comparison.

**MEASURED 2026-08-28 — the throw case.** `tools/sweep_addon_throw.lua`, mirror
Baraka, both fighters pinned 40 px apart, toward+LP on the same frame:

| run | P2 | P1 | both |
|---|---|---|---|
| trial cadence 90 | 28 | 0 | 0 |
| trial cadence 77 | 32 | 0 | 0 |
| **P1 moved to the RIGHT** | 28 | 0 | 0 |

**88 trials, zero P1 throws, and never a double.** Same answer as the trade
case, and the swap control says it is the player *number* again, not the screen
side.

**The mechanism is confirmed retail by reading the source** (2026-08-29) —
which is what the abandoned retail build was chasing, and it turned out to cost
two greps instead of an assembler:

* retail `getprc` links a new process **after its creator**, with the identical
  code *and* comment: `move *a13,*a0,l ;link into active list after current
  process`;
* retail `setup_players` creates **player 1 first, player 2 second**.

So P2 lands ahead of P1 in the active list and resolves first, in the original
game, for exactly the same reason — observed here at list positions 3 and 4.
The numbers above are still measured on our build, since a running retail ROM
would be needed for that, but the code path producing them is identical, so the
attribution is now direct rather than inferred.

**Both are fixed** — see `firstactive` in [DEVIATIONS.md](DEVIATIONS.md).

Two wrong answers came first, and both looked clean:

* **The throw is LOW punch.** `joy_lo_punch` sets `movi 040h,a7` and calls
  `toss_check`, so the range limit is 64 px. Pressing HP measured 19 trials of
  "P1 wins 10-9" that contained **no throws at all** — at that range
  `joy_hi_punch` runs `elbow_check` and both players elbow. Damage is not
  evidence of a throw; the tally is now gated on `act_bodyslam`.
* **The harness was holding P1 away.** Driving only the toward direction left
  the sweep's camera-stress walk owning P1's other direction for the back half
  of each run — and holding away is exactly what `toss_check` reads to
  *refuse* a throw. That produced a beautifully clean "P2 wins the first half,
  P1 wins the second", switching at `OBSERVE*0.45`, reproducible at two
  cadences. Both directions for both players are now driven explicitly.

**MEASURED 2026-08-28 — round start is fair.** `tools/sweep_addon_roundstart.lua`
holds both sticks toward the opponent from the first fight frame and records
when each fighter's `oxpos` actually moves — movement, not `p_action`, because
a fighter can change action while still parked. Four matchups including a
mirror: **P1 and P2 both move at rel=3, delta 0, every time.** No side gets an
earlier first frame.

So of the three cases this section opened with, two now show the same P2
advantage and one is clean. 4.4's throw discussion should be read with the
throw result above.

## 5.4 Enumerate every gameplay read of `rand`

`@rand` is reseeded identically each round, and blood was correctly split onto
`blood_rand` (`xori 0f00dcafeh` in MAIN.ASM). Good for determinism. But
"deterministic" and "fair" are different claims: if anything a player interacts
with reads `rand`, it is now perfectly *predictable*, which is exploitable.

**What to build**: a grep-level audit of every `@rand` read reachable during a
round, each classified as cosmetic or gameplay. Small job, closes the question.

---

# 6. What players get — OUT OF SCOPE for this ROM

**Owned by the frontend, not the build (confirmed 2026-08-28).** Practice mode,
input display, the player-facing move list and the damage/combo counter are all
handled by the `freeplay-gametalk` emulator frontend. Nothing in 6.1-6.4 is
work for this ROM, and building any of it here would duplicate what already
exists somewhere better suited to it.

Kept below for reference only — the ROM-side facts each one would need are
still accurate, and the move list in particular can be generated from
[MOVE_MATRIX.md](MOVE_MATRIX.md) and [FRAME_ADVANTAGE.md](FRAME_ADVANTAGE.md)
by whoever owns the frontend.

## Original section: practice, not debugging

Everything the project built for itself is a developer tool poked from a Lua
host. There is nothing for the person holding the stick.

## 6.1 There is no practice mode

The pieces exist and are already host-poked: `f_freeze_timer`
([RAM.ASM:97](../src/RAM.ASM#L97)), `f_colbox`, `f_sans_throws`. What is
missing is a **menu that turns them on from the cabinet**, plus:

- health lock / refill (retail already has `recharge_bars`);
- a dummy with stand / crouch / block / jump / after-first-hit behaviour;
- input recording and playback — the drone already replays sequences, and
  `mk2_test.lua` already replays inputs from the host side;
- reset to round start on a button.

## 6.2 There is no input display — and it is nearly free

`p?_jcq` already stores `[switch, time]` pairs. HUD text out of program ROM
already works (the PIXBLT HUD text work: sysfont 1bpp, zero art cost). An input
history strip is the single highest-value practice feature in any fighting game
and this build is two pieces short of it.

## 6.3 There is no player-facing move list generated from the ROM being played

`doc/` has extractors for everything. What it does not have is the artifact a
scene actually uses: a one-page move/frame/damage sheet **generated from the
build**, so it cannot drift from what is running. This build has custom
characters (Jade, Smoke, Noob) and custom moves that no external sheet covers —
[COMBO_SHEET_AUDIT.md](COMBO_SHEET_AUDIT.md) opens by saying the SuperCombo
sheet predates all of them.

## 6.4 No damage / combo counter

Needed for the 4.3 juggle work anyway, and a practice-mode staple.

---

# 7. Build identity

## 7.1 A tournament build should be its own target, and identifiable on screen

`build_all.py` produces `mk2_test` and `mk2_retail`. A third target —
tournament — with its ruleset flags baked (2.1, 4.2, 3.2) and a **version
string visible in-game** lets a bracket verify every station is running the
same code.

**PARTLY DONE 2026-08-29, and one half deliberately not done.**

*Not done, on purpose:* a third build target would be **byte-identical to the
one that already ships**. The default build already carries the tournament
ruleset — `firstactive`, `twobtn_slack`, `secretwalk` on; `perpiece`,
`chipfloor`, `dmgscale`, `blockspecial` at arcade behaviour. Adding a
`tournament` target today produces the same ROM under a second name, which is
worse than nothing: it implies a distinction that does not exist. It becomes
worth building the moment the default and the tournament ruleset diverge.

*Done:* the identity problem is solved by 7.2 instead. `rom_name` already
carries the git short hash and shows in the diagnostics menu, which is how an
operator checks a cabinet — but it has a gap that matters here: **two builds
from the same commit with different switches look identical on screen.** The
manifest closes that, because it records the ruleset alongside the hashes.

## 7.2 Publish a checksum manifest

`burnfix.py` already emits `rom/burn/MANIFEST.txt` for hardware. The same idea
for the distributed zip — with the caveat that zip contents never match
`rom/*.bin` because of the 4-byte `crc_spoof` padding rewrite, so the manifest
must hash the *right* thing.

**BUILT 2026-08-29** — `tools/release_manifest.py` -> `rom/MANIFEST.txt`,
written automatically by `mamerom.py` on every package. It hashes the files
**as distributed**, from inside the zip and *after* `crc_spoof`, which is the
only state a player ever runs.

It records three things, and the ordering is the point:

1. **the ruleset** — all 13 switches by value, pointing at DEVIATIONS.md;
2. **the lock digests** — balance, hurtbox, behaviour;
3. **a SET FINGERPRINT** over every file in the zip.

A cabinet matches if the fingerprint matches. If it does not, the ruleset block
says whether the difference *matters* — two builds can differ in art or sound
and play identically, and a bracket needs to tell those apart rather than
rejecting a station over a sound ROM. It also flags uncommitted changes, so a
manifest cut from a dirty tree says so.

Verified both ways: it passes against the zip it was cut from and fails against
a different one, naming both fingerprints.

## 7.3 Netplay gaps that are not in NETPLAY.md

- **Desync detection** — ~~a periodic state hash~~ **DONE, and improved
  2026-08-28.** `netplay_sync` existed already but was a flat XOR of five
  values: blind to two of them swapping, and covering neither height, action
  nor the juggle counter. Now a rotate-and-fold over eleven values. See
  [NETPLAY.md](NETPLAY.md) — including the fold that nearly shipped missing and
  would have masked 53% of single-bit divergences.
- **Input delay presets** and where the 2.1 leniency fits once it is gated.
- **Rollback cost under load** — [FRAME_TIME_UNDER_LOAD.md](FRAME_TIME_UNDER_LOAD.md)
  measures the ROM's frame budget, not the wrapper's save/restore budget on the
  same busy frames.

---

# 8. Process — nothing currently *fails* on a balance change

## 8.1 A balance lock file

Phase D already re-runs every promoter in `--check` mode and fails the build on
drift. Balance has no equivalent: a strike box, a damage byte, a blockstun
constant or a combo window can change and the build is green.

**BUILT 2026-08-28** — `tools/balance_lock.py` -> `doc/balance.lock`, wired
into Phase D of `build.py` alongside the promoters.

**373 locked values**: every strike record (reach, box, y offset, routine word,
hit, chip, flags), every block reaction's blockstun, every special-move input
window, and all eight ruleset switches — `anchorcol`, `stkphase`, `perpiece`,
`hitbox`, `combo_slack`, `combo_slack_online`, `dmgscale`, `chipfloor`.

Readable rather than an opaque hash, deliberately: when the check fails you
want to see *which move* changed and by how much, in the diff, without
re-running anything. There is a `sha256` at the end for a build stamp or a
checksum manifest (7.2).

Proven both ways rather than assumed:

```
$ python build.py --asm-only          # after widening one strike box 104 -> 112
BALANCE CHANGED - 4 differing lines:
  -stk_swipe    104   70x24   20   4647   32   8 sf_squeeze
  +stk_swipe    112   70x24   20   4647   32   8 sf_squeeze
Error: balance lock check failed (returncode 1)
build exit code: 1
```

and the same for a switch flip (`dmgscale 0 -> 1`). Restored, the build is
green again. **Mobility is now in the lock too** (added with 4.6): per-character walk rate
and velocity, plus the shared jump constants. **393 locked values.**

## 8.2 The stability sweep does not cover balance regressions

`run_battle_stability_sweep.ps1` catches crashes and camera scope. It does not
catch "this move now whiffs at point blank".

**BUILT 2026-08-28** — `tools/sweep_addon_assert.lua` measures ten canonical
interactions against a standing dummy; `tools/behaviour_lock.py` freezes them
into `doc/behaviour.lock`; `tools/run_behaviour_check.ps1` does the run and the
compare in one. This is the **third lock**, and it guards the thing the other
two cannot: `balance.lock` holds the numbers a human typed and `hurtbox.lock`
the ones the art decides, but a move's behaviour is those combined with its
handler, and nothing was watching the combination.

It records what the game **does**, not what it should — nine rulings in
sections 4 and 5 are still open, and a lock that encoded an opinion would be
wrong the moment one of them is made.

| case | dist | dmg | attacker action |
|---|---|---|---|
| elbow_close | 40 | 24 | `act_elbow` — `elbow_check` converts a close HP |
| hipunch_mid | 70 | 11 | `act_hipunch` |
| **hipunch_far** | 130 | **0** | fires and whiffs |
| swipe_back_hp | 90 | 32 | Baraka's back+HP |
| throw_close | 40 | 34 | `act_bodyslam` |
| **throw_far** | 90 | 8 | *not a throw* — past the 64 px limit it is a low punch |
| **uppercut_point** | 12 | **0** | the documented point-blank dead zone |
| uppercut_mid | 50 | 40 | connects |
| sweep_back_lk | 90 | 20 | back+LK |
| lowkick_mid | 70 | 26 | standing LK |

The four bolded rows are the ones with teeth: two moves that must *not*
connect, one that must degrade to something else, and the dead zone. A change
that quietly gives the uppercut point-blank reach, or extends throw range,
fails this and nothing else in the build.

**Deterministic, and proven to fail.** Two consecutive runs are byte-identical,
so a diff is a real change rather than noise; and dropping `uppercut_mid` from
40 damage to 36 is caught with the case named. The measurement needs MAME and
about a minute, so unlike the other two locks it is not in Phase D — it belongs
beside the sweep.

Still worth adding later: a multi-hit string and a corner sequence. Both need
input scripting this rig does not have yet, and a case that cannot be measured
reliably is worse than a missing one.

## 8.3 Two known-flaky things must not be counted as evidence

Carried forward so a tournament-validation pass does not trip on them:

- **Drone-vs-drone wedges on an unmodified baseline** — never score it as a
  regression.
- **The Kung Lao ladder flake is pre-existing** — it hangs roughly 3 runs in 4,
  and retrying inflated a past "12/12".

---

# Appendix — numbers established while writing this

Read straight out of the source on 2026-08-27. None of these are currently
stated anywhere in `doc/`.

| Quantity | Value | Source |
|---|---|---|
| Blockstun | `2 * a10 * a11` ticks | `block_shake`, [MKREACT.ASM:4693](../src/MKREACT.ASM#L4693) |
| Blockstun values actually used | `a11` is **always 2**; `a10` in {1,2,3,4}, giving **4 / 8 / 12 / 16 ticks** (73 / 146 / 219 / 293 ms) | every `block_shake_n_exit` call site |
| Hitstun | `sleep` x rows, from `animate_a9` `[sleep:16 \| index:16]` — rows come from **the victim's** anitab | `r_hipunched` = `000030010h`, [MKREACT.ASM:3041](../src/MKREACT.ASM#L3041) |
| Combo window | table value **+6 ticks (96 ms)**, unconditionally | [MOVES.ASM:7318](../src/MOVES.ASM#L7318), [7328](../src/MOVES.ASM#L7328) |
| Throw range | 64 px (`040h`), one value for the cast | [JOY.ASM:1031](../src/JOY.ASM#L1031) |
| Throw escape | hold away only; no throw break | `is_stick_away`, [JOY.ASM:1247](../src/JOY.ASM#L1247) |
| Wall throw ban | applies to everyone except Kung Lao | [JOY.ASM:1236](../src/JOY.ASM#L1236) |
| Juggle cap | `p_hit > 3` then `repell_attacker`; **`block_exit` zeroes `p_hit`** | [MKREACT.ASM:3767](../src/MKREACT.ASM#L3767), [4585](../src/MKREACT.ASM#L4585) |
| Boss block cap | `p_hit >= 7` then `stop_abusive_attackers` (Goro path) | [MKREACT.ASM:579](../src/MKREACT.ASM#L579) |
| Clock unit | 11 x `sleep 3` = 33 ticks = **603 ms**; 99 count is ~59.7 s | [MAIN.ASM:689](../src/MAIN.ASM#L689) |
| Round outcomes | 0 = P1, 1 = P2, 2 = tie (**no round awarded**), 3 = timeout (resolves to higher bar) | `round_results_tab`, [MAIN.ASM:812](../src/MAIN.ASM#L812) |
| Max HP | 161 (`0A1h`) | `pbar_table` / CLAUDE.md |
| Damage scaling | Goro 1/2; Kahn own scale; secret trio 3/4 **CPU-only** | `ochar_damage_table`, [JOY.ASM:1857](../src/JOY.ASM#L1857) |
| Hitbox flags | `stkphase 0`, `perpiece 0`, `hitbox 1` | [MAINEQU.ASM:65-69](../src/MAINEQU.ASM#L65) |
| Stick read | live off the port, not a per-frame latch | `joystick_in_a0`, [JOY.ASM:704](../src/JOY.ASM#L704) |
| Extra button held | kills the combo match outright | `button_mask` then `combono`, [MOVES.ASM:7322](../src/MOVES.ASM#L7322) |
