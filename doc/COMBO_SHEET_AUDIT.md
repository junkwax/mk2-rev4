# The SuperCombo move sheet, checked against this build

A player-facing move/combo/glitch sheet (SuperCombo wiki: MK2 *System*,
*Controls and Notation*, and the character pages) read against the actual
source in this tree. The point is not to copy it in — it is a **model of the
game held by people who play it**, which makes it good for exactly two things:

1. an inventory of exploits, so keep-or-kill is a decision on record rather
   than something nobody looked at;
2. a list of behaviours humans have and [the drone](AI_DRONE.md) does not.

## Trust the sheet this far and no further

- **It is half MK1.** The *System* page says so out loud in places ("there is
  no pushback for this scenario in MK1", "there are no crossover JKs in MK1",
  "Explained in Sub-Zero's Guide since he is the only one that has real glitch
  cancel in MK1"). Those paragraphs are not statements about MK2 and several
  are contradicted by our code (see A5). Do not port them as fact.
- **Every percentage is retail.** Our strike tables have moved; damage lives
  in `MKSTK.ASM` and is audited in [BALANCE_AUDIT.md](BALANCE_AUDIT.md). A
  "100% combo" on the sheet is a claim about L3.1, not about `rev4.0`.
- **It predates every custom character.** Jade, Smoke and Noob are absent, and
  Jade appears only as a thing that other characters' projectiles pass through.

## A. Mechanics claims, checked

| # | Sheet claims | What the code actually does | Verdict |
|---|---|---|---|
| A1 | **Death Punch** — a jab landing on its later active frames hits several times in one frame; 4+ amplifications shove the attacker full screen | `punch_sleep` ([src/JOY.ASM:1356](../src/JOY.ASM#L1356)) does `sleep 1` then calls `strike_check_a0` **every tick** for up to 5 ticks. The one-hit latch (`clr a11 / not a11`) is only armed by the *pre-loop* check at [JOY.ASM:899](../src/JOY.ASM#L899)/[1054](../src/JOY.ASM#L1054). A jab that misses on the first check and connects later inside the loop keeps connecting, once per tick — there is no per-attack latch anywhere in `strike_check`. The full-screen tail is real too: `blkp3` and `no_unlimited_airhits` ([MKREACT.ASM:3767](../src/MKREACT.ASM#L3767)) both fire `attacker_getting_separated` at `p_hit > 3` | **Real here.** Mechanism identified exactly |
| A2 | Hold Back (or U/B, D/B, D/B+BL) and you cannot be thrown | `is_stick_away` in the throw gate ([JOY.ASM:1244](../src/JOY.ASM#L1244)) | **Real, and symmetric** — the drone is held to the same rule in `drone_body_slam`; the `toss_drone_check` reversal that used to override it is retired |
| A3 | A special done immediately after a throw/uppercut is **unblockable** | Not a glitch — it is the hit contract. `strike_check` calls `disable_his_buttons` on every collision ([JOY.ASM:1636](../src/JOY.ASM#L1636)), and several reactions additionally `set_no_block` (e.g. `act_speared_sd`, [MKREACT.ASM:2398](../src/MKREACT.ASM#L2398)) | **Real and intended.** Leave it |
| A4 | Corner `RH, RH, RH…` is an infinite (listed for Sub-Zero, Scorpion, Reptile, Raiden) | Measured — [CORNER_ROUNDHOUSE.md](CORNER_ROUNDHOUSE.md). `p_hit` never exceeds **1**: each kick is a fresh single hit, so no juggle counter is involved. It is a repeatable free anti-air with a 20-frame (366 ms) gap, and blocking it still chips out a full bar in 16 s at the retail `stk_lkroundh` 32/8 | **Not an infinite.** Two real problems, both already written up |
| A5 | Corner jab pressure has **no pushback**, so jabs chip the blocker to death in place | False for MK2. Every blocked jab runs `away_x_vel`, and `blkp3` separates at `p_hit > 3` ([MKREACT.ASM:4353](../src/MKREACT.ASM#L4353)). This is one of the MK1 paragraphs | **MK1 only. Do not import** |
| A6 | The corner "iceskate" pushback can be cancelled with any special | Consistent with `repell_one_of_us` / `attacker_getting_separated` acting on the attacker's velocity while the attacker stays actionable | Plausible, **unverified** — see D |
| A7 | Juggles cap out; loops that route through a block or a reset "re-arm" | Exactly the shape of the code: `no_unlimited_airhits` counts `p_hit > 3`, and `block_exit` **zeroes `p_hit`** ([MKREACT.ASM:4587](../src/MKREACT.ASM#L4587)) | **Real, and it explains the sheet's whole "corner infinite" family** |
| A8 | Spear → free hit; `Spear, D+LP, Spear…` is an infinite **vs bosses** | `act_speared_sd` + `set_no_block` gives the free hit against everyone. The vs-boss version additionally needs a victim who is never knocked down, which is what a boss is | Free hit **real**; boss loop **needs a rig** |
| A9 | Glitch Jabs — pressing block during a jab's startup recovers early | `punch_sleep` exits early (`psl7`) whenever the last button changes, which is the right shape, but block's specific path is not confirmed | **Unverified** — see D |

## B. Glitch ledger — keep or kill

This project's bias is retail-faithful, so the default is **keep**. The bar for
killing something is that it breaks *our* content or makes the AI look broken —
not that a competitive player would call it unfair.

| Exploit | Cost to kill | Recommendation |
|---|---|---|
| **Death Punch** (A1) | ~2 instructions: latch `a11` negative inside `punch_sleep` when its own `strike_check_a0` returns carry | **Decide deliberately.** It is a signature MK2 quirk and killing it moves a lot of damage; it is also the one exploit here the *drone* eats repeatedly, since it walks chest-first into jabs. Middle option: latch only when the amplification would cross the `p_hit > 3` separation threshold |
| **Unblockable-after-hit** (A3) | High — it is the hit contract | **Keep** |
| **Corner roundhouse loop** (A4) | Not a code bug; it is spacing plus the 20-frame gap | **Keep the move, fix the AI side** — the drone should not be the one jumping into it (C2) |
| **Chip death from blocked RH** (A4) | `stk_*` block bytes | **Keep** — retail values, and [BALANCE_AUDIT.md](BALANCE_AUDIT.md) owns that axis |
| **Spear → free hit** (A8) | `set_no_block` | **Keep** |
| **Boss spear loop** (A8) | Unknown until measured | **Measure first** |
| **Cage nut punch on a morphing Shang → infinite** | `do_noogy` caps on `p_anicount` ([MOVES.ASM:3183](../src/MOVES.ASM#L3183)); a victim mid-morph plausibly never decrements it | **Measure first.** If it reproduces, this is the one on the sheet worth killing outright — a true lock, not a hard combo |
| **Kung Lao whiff-divekick loop, Mileena roll loop, Kitana fan-lift loop, Reptile forceball loop** | Each is a juggle string, so each is bounded by A7 — *unless* it routes through a block or a reset | **Measure**, then treat as one class, not four bugs |

## C. Drone backlog the sheet actually justifies

Most of the sheet's AI-facing advice is **already in**: the punish matrix
(`counter_sitting_duck`), anti-air gating, throw escape, corner escape, jab
pressure with a real gap, and the opponent model all exist and are documented
in [AI_DRONE.md](AI_DRONE.md). What follows is what it does *not* have.

### C1. `act_noob_portal` (0x117) has no reaction — found this pass

`python tools/audit_drone_tables.py` fails on it today:

```
HOLES (1) -- live action with no reaction handler:
  act_noob_portal      0x117  counter_attack_table[23] is .long 0
```

The action is live — stamped at [MKZAP.ASM:7900](../src/MKZAP.ASM#L7900),
equate at [MAINEQU.ASM:1076](../src/MAINEQU.ASM#L1076). This is the exact
pattern AI_DRONE.md names ("every piece of content added to this game since
the leak arrived with a reaction-table hole") repeating on the newest move.
**Needs a design call before it can be fixed:** what *should* the drone do
against a portal cast — block, close the distance, or punish the recovery?

### C2. Anti-air is uppercut-only — **DONE**

`drone_antiair_try` always ended in `do_uppercut`, testing reach with strike
table `008h` for every character. The sheet is emphatic and consistent that
the correct anti-air is **per character**, and names the replacement in the
same breath as the weakness.

Now `ochar_antiair`, a 17-row `.long` table where `0` = the uppercut, so
unlisted rows keep the old behaviour exactly. Four rows are non-zero, and each
is a character the sheet rates "Uppercut: Weak" or gives explicit anti-air
prose: Kung Lao → standing HK, Sub-Zero / Reptile / Scorpion → roundhouse.
Each row selects a *style* routine carrying its own reach test, strike index
and height gate together, so the test can never drift away from the move.
Smoke, Noob and Jade are deliberately left at the default. Full write-up in
[AI_DRONE.md](AI_DRONE.md#it-is-not-always-the-uppercut-ochar_antiair).

Measured (Scorpion, diff 9): **8 jump-ins met, 6 connected, 0 swings at
nothing** — 86% conversion once a stray shared-move roundhouse outside both
gates is excluded, matching the uppercut's. Raiden, unchanged by the table,
reproduces its pre-change baseline exactly (20% met, 6 of 7 connected), which
is the no-regression check for the twelve characters still on the uppercut.
Kung Lao's high-kick row is wired and audited but **not yet measured**.

The sheet also wants `aaHP` for Shang Tsung, Kitana and Mileena. Not taken:
it rates all three "Uppercut: Good" or "Awesome" anyway, and an HP anti-air
launches into the juggle engine, which is a separate system with its own
rules. Revisit only with a measurement.

### C3. Duck the high projectile instead of blocking it

The sheet's most-repeated piece of real tech: Sub-Zero's iceball ducks under
Scorpion's spear; Raiden's torpedo goes under every high projectile; Baraka's
and Mileena's sparks fly high enough to be ducked. Our `c_*zap` handlers block
or jump. A "this character's crouch clears this projectile" option would read
as competence rather than as reaction speed.

### C4. Jab pressure has no ender

`drone_jab_pressure` ([MKDRONE.ASM:2405](../src/MKDRONE.ASM#L2405)) throws 1–2
jabs per cycle for three cycles, then stops. The human pattern on the sheet is
jabs **into a knee or a containment special**. Also worth stealing: *"hold back
while you do the corner jabs so that they can't counter throw"* — the drone
holding away through its own string makes it throw-proof for free, through the
`is_stick_away` gate it already respects (A2).

### C5. No wake-up option

The sheet devotes a section to wake-up 50/50s. `drone_getup` gets up; it never
wakes up *with* anything. Even a low-probability, diff-gated wake-up special
would change how the corner feels.

### C6. The land-on-top throw

*"At jump distance, do an early jumpkick so you land directly on top of the
victim without hitting them, then LP."* The drone has a throw gate but no
setup that produces this position on purpose.

## D. Needs a rig before it is actionable

The corner harness already exists (`tools/sweep_addon_corner.lua` +
`run_battle_stability_sweep.ps1 -P2Human`, `CORNER_MODE`) and is the right
instrument for all of these:

- A6 — can a special actually cancel the separation shove?
- A9 — does block during jab startup shorten recovery?
- B — Cage nut punch vs a morphing Shang; the boss spear loop; and the four
  juggle loops, in one pass.

Score them on `p_hit` and on the victim's free frames per cycle, not on whether
they "look infinite" — A4 is the standing proof that the eye is wrong about
this.

## E. Explicitly not importing

- Every MK1-flavoured paragraph in the *System* page (A5 is the clearest).
- All damage percentages.
- Matchup numbers (the Liu Kang page's "Scorpion 9-1"), which describe retail
  frame data and a roster we have changed.
