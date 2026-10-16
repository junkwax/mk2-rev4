# Ermac's telekinetic slam, gated the way UMK3 gates it

`ermtkgate` (MAINEQU.ASM, default 1) — the gate in `ermac_hi_kick`
([src/MOVES.ASM](../src/MOVES.ASM)) and the stamp in `do_ermac_teleslam`
([src/MKSLAM.ASM](../src/MKSLAM.ASM)).
Rig: `tools/run_ermac_chain_probe.ps1 -Mode chain|slamonly|combo|cap`.

## The report

> ermac is able to chain consistantly with his teleport then teleslam, even
> with a four hit push back he can teleport out of that and continue the chain

The loop is real. The four-hit push back is not what escapes it — **that path
never runs at all.**

## What the measurement says

`tools/run_ermac_chain_probe.ps1` drives each move the instant the *game* says
it is legal (P1 idle in `act_stance`, the teleport off `l_decoy`, the slam
inside its own box). That is the upper bound on what a player can do, so it is
the honest reading of the loop rather than an impression of it.

Baseline, ten cycles, Ermac vs an idle 2P Jax, round clock frozen:

| | catches | re-grabs | P2 bar | P2 actionable frames |
|---|---|---|---|---|
| `-Mode chain` (teleport + slam) | 10 | 3 | 161 → **40** | **66** of 985 |
| `-Mode slamonly` (no teleport at all) | 8 | 6 | 161 → 89 | 128 of 743 |

Two things fall straight out of that table.

### The teleport is not the cause

`-Mode slamonly` never throws it, and the victim is still in `act_reacting`
(`0503h`) for the whole run. Measured cadence: **a slam every 50 ticks**, each
one catching a man who is still in the reaction from the one before.

The reason is an asymmetry in the move itself. Ermac's own routine is the
windup, one tick of grab, `erm_tks_hitwait` and the arm coming back down —
**25 ticks** (`act_ermac_tks` at t=24, back to `act_stance` at t=49). The
victim is lifted, hurled off the top of the screen, dropped, bounced and has to
get up — **~140 ticks** from the catch to being able to act. So Ermac is idle
and inside his own grab box again long before the man he threw can do anything,
and `stk_ermac_teleslam`'s 100..206px box simply closes on him again.

What the teleport contributes is **spacing**. The bounce walks the victim in
toward Ermac (measured 204 → 185 → 167 → 161 → …) until he falls inside the
grab's own 100px dead zone and the loop stalls; the teleport resets the gap and
it resumes. That is what "he can teleport out of that and continue" is actually
describing.

### Every hit is an opening hit, and nothing was ever pushing him away

`phitmax = 1` over ten cycles, in both modes. The victim's `p_hit` oscillates
`0 <-> 1` and never climbs, because `r_ermac_teleslam` ends with
`dec_my_p_hit` (the arcade gives the hit back) and the victim then **lands**,
which clears `p_hit` in `back_to_normal`.

So:

- `dmgscale` never scales a single hit of the loop — every slam is 9 and every
  teleport punch 20, at full value.
- `no_unlimited_airhits` fires at `p_hit > 3` and is **never reached**, so
  `repell_attacker` / `attacker_getting_separated` never run. Measured
  `sep = 0`: `p1_xvel` never carried a separation request.

There is no four-hit push back in this loop to escape. That is why it looks
like he escapes it.

## The gate: UMK3's own `q_ermac_slam`, ported whole

**My first answer here was wrong and the user reported it: "the teleport just
doesn't connect".** That version refused the grab on any victim in
`act_reacting` at all. It did break the loop, and it also meant a refused slam
played its windup and ate the 48-tick whiff recovery — so a player whose rhythm
put the second slam inside the first one's reaction got nothing, every time.

UMK3 already has a limiter for this move. It is `q_ermac_slam`
(`MOVES.C:3764`), and it is **two conditions**:

```c
WORD q_ermac_slam(void)
{
	if (get_his_p_hit(current_proc)>4 || get_tsl(l_ermac_slam,current_proc->pa8)<0x80)
		q_no;
	else q_yes;
}
```

- **`get_his_p_hit > 4`** — `erm_tks_maxhit` 5. The slam may be the 1st through
  5th hit of a string and is refused on the 6th. This is the half that says it
  *can* combo.
- **`get_tsl(l_ermac_slam) < 0x80`** — `erm_tks_cool` 128 ticks, and
  `stat_do_ermac_slam` stamps `l_ermac_slam` **the tick the grab connects**
  (`MKSTAT.C:134`, above the `if (f_block) break`, so a *blocked* catch starts it
  too). A whiff stamps nothing. This is the half that stops the re-grab.

`q_*` is a **qualifier** in UMK3 — the secret-move table's gate field — so a
refusal means the move never starts. In MK2's grammar that is `death`: the input
becomes an ordinary high kick, exactly as `ermac_hi_punch` three handlers up
falls through when `l_decoy` refuses the teleport. **And that is the difference
the player feels** — measured in the chain log, a refused slam now comes out as
a high kick that connects for 24–32 instead of a punishable whiff.

`l_ermac_slam` is UMK3's own name and UMK3's own RAM (`MKGAME.H:821`). The
earlier claim here that "MK2 has no such timer and no drone gate that would read
it, so adding a dead timer would be adding a thing to keep in sync for no
behaviour" was simply a miss: the arcade stamps it in the shared move body and
`q_ermac_slam` is its one reader.

### Why the cooldown works where I argued it would not

The note this replaces said a cooldown "would only slow it down". That was
reasoning about a timer stamped at the **attempt**. Stamped at the **connect**,
128 ticks outlasts both the ~50-tick re-grab cadence and the ~105-tick
teleport+slam alternation, and a whiff costs nothing — which is what makes it a
limiter rather than a tax on using the move.

### The hit-count cap is inert in MK2, and that is measured

The grab box opens ~24 ticks after the input, and P1's own recovery from any
lead-in adds more. Measured lag from the lead-in's hit to the grab taking hold,
and the victim's state when it did:

| lead-in | lag to the catch | victim still reacting? |
|---|---|---|
| teleport punch (the user's chain) | 48 ticks | no |
| plain high kick | 72 | no |
| uppercut | 91 | no |
| another slam | gated by the 128 | — its reaction lasts only **91** |

So the victim's `p_hit` is **0 at every real connect**, and `erm_tks_maxhit` is
reachable only by seeding the counter (`-Mode cap`). It is ported because it is
UMK3's rule and because it is what would bite if the startup or the stun ever
changed — not because it fires today. Same shape as the throw payloads in
[doc/THROW_DAMAGE_SCALING.md](THROW_DAMAGE_SCALING.md): wired, correct, and
currently unreachable.

That last row is also the correction to this document's own earlier arithmetic:
the victim is helpless for ~140 ticks *to being actionable*, but he leaves
`act_reacting` after **91**, so 128 sits above it rather than under it.

## After

Ten cycles of the re-grab loop, against the ungated control:

| | gaps between connects | min | victim actionable | verdict |
|---|---|---|---|---|
| ungated (base) | `50 50 50 50 50 191 50` | **50** | 128 frames | FAIL |
| `ermtkgate` | `138 189 137` | **137** | 214 frames | PASS |

The verdict is the **minimum gap between two connects**, against `erm_tks_cool`
read out of MAINEQU.ASM rather than written into the rig. It is deliberately not
the re-grab count any more: a slam taking hold of a man already in a reaction is
the move being *used*, which the earlier gate forbade and this one permits, so
that number is reported and no longer asserted. `catches >= 2` is required too —
one connect has no gap, so a run that landed once would pass vacuously.

`-Mode cap -Seed N` seeds the victim's `p_hit` and asks only whether the **move
started** (`act_ermac_tks`), since a qualifier refusal means it never does:

| seed | gated | ungated control |
|---|---|---|
| 0 | fires | fires |
| 4 | fires | fires |
| 5 | **refused** | fires → FAIL |
| 6 | **refused** | fires → FAIL |

### Prevented entirely, not fired-and-whiffed

Asked directly: *does UMK3 prevent the move entirely after a certain amount,
rather than the move firing and just not animating the victim?* It does, and
because `q_*` is a qualifier that is structural rather than a tuning choice —
`act_ermac_tks` is never stamped at all. The gaps between connects cannot tell a
refusal from a whiff, so `-Mode cool` asserts it on the action code: land one
slam, keep offering the input, and watch for the move to START again.

| | first tick the move starts again | input offered |
|---|---|---|
| `ermtkgate` | **+128** — exactly `erm_tks_cool` | 3 presses refused |
| ungated control | +40 | 2 presses |

`presses >= 2` is required, or a run that offered the input once and happened to
be late would be indistinguishable from the gate holding it off. The arming has
to wait for Ermac's *own* slam to end first: `act_ermac_tks` is still set at the
catch (it runs t=24..49 and the catch lands ~t=34), so watching from the catch
onward re-detects the slam that set the timer.

**The one case left where the move does come out and the victim is not animated
is a BOSS.** `is_he_a_boss` is still tested *inside* the active window — UMK3's
own placement (`MKSTAT.C`, inside the do-loop), so the window runs its full length
and Ermac reaches at a man who can never be grabbed. Against Kintaro or Shao Kahn
that is exactly the "fires but does not animate the victim" shape, and it is
reachable in normal play. Moving it up to `ermac_hi_kick` beside the other two
conditions would make the input an ordinary high kick instead; that is a
deviation from the arcade, so it is not done here.

`-Mode combo` drives the user's own chain — teleport punch, then the slam — and
passes on it connecting, reporting the 48-tick lag that explains the `incombo=0`.

### Three rig faults this cost, all worth keeping

**`st_t` started at 0 while `frame` was already ~700 at the fight**, so the combo
mode's lead-in phase timed out on its own first tick and reported "the High Kick
never connected" at the start distance, before it had walked anywhere. The other
modes open on `approach`, which has no timeout, which is why nothing caught it
earlier. The phase clock is re-stamped on the first fighting frame now.

**The `want` expression hit Lua's and/or trap** — the one CLAUDE.md already
documents for the slicehat rig, written a second time here:
`(MAXHIT ~= nil) and (SEED < MAXHIT) or nil` collapses to `false or nil` = `nil`
whenever the seed is *above* the cap, so every refused seed — the half of the cap
worth testing — came back as "no expectation" and failed. It is an `if` now.

**And the lead-in has to wait for P1's own recovery.** Driven straight off the
hit, the B,D,B+HK motion is discarded: MK2 ignores input for the whole of the
kick's ~38-tick recovery (`0x0103` then `0x060c`), so the slam never came out at
all and the mode read as the gate refusing it.

---

# And the slam is scaled like any other hit

`ermtkscale` (MAINEQU.ASM, default 1; requires `dmgscale`) — `erm_tks_scale`
([src/MKREACT.ASM](../src/MKREACT.ASM)) and the shared `dmgscale_a10`
([src/JOY.ASM](../src/JOY.ASM)).
Rig: `tools/run_ermac_chain_probe.ps1 -Mode scale -Seed 0..3`.

## It never came through `dmgscale` at all

`stk_ermac_teleslam` carries `00h` hit damage on purpose — *"the reaction
applies its own"* — and `r_ermac_teleslam` applies it with `damage_to_me`, which
**jumps straight to `bar_reducer`**. `dmgscale` lives one branch earlier, in
`strike_check`'s clean-hit path, and it lives there for a reason its own comment
gives: that is the only place `a13` is certainly the *attacker*, so indexing the
counter off `p_otherproc` is correct. `damage_to_me` is the one caller of
`bar_reducer` where `a13` is the fighter being hurt.

So a slam landing fourth in a string was worth the same 9 as one landing first.
Measured — the ungated, unscaled build reads **9 at every string depth**.

## One curve, two callers

The curve is now `dmgscale_a10` in JOY.ASM, below `bar_reducer`, `.globl`'d
there and `.ref`'d in MKREACT. Full, 3/4, 1/2, then 1/4, floor of 1; no
multiply, because `MPYU` writes a 64-bit result across `a10:a11` and `a11` is
live at the `strike_check` call site. It preserves `a0` and `a1` and touches
only `a10`.

**The index stays with each caller**, because the two reach the counter from
opposite ends:

| caller | `a13` is | the count is on | the opening hit reads |
|---|---|---|---|
| `strike_check` | the attacker | `p_otherproc` | `p_hit` 0 |
| `erm_tks_scale` | the **victim** | `a13` itself | `p_hit` **1** |

That last row is the whole of the new code. `reaction_start` has *already*
counted the catch by the time the impact applies the damage ~70 ticks later, so
`erm_tks_scale` takes **one off** the index — otherwise an opening slam would
scale as the second hit of a string and land for 7.

`p_scalebias` is subtracted exactly as `strike_check` subtracts it, for the
reason it exists: a man dragged in by Scorpion's spear, frozen, or slipped on
the floor ice was not beaten twice, so the slam that follows one of those is
still an opening hit.

The export does **not** go through a `.global` in MAINEQU.ASM. MAINEQU is
`.include`d by ~70 objects, so a name in one of its lists lands in all 70 symbol
tables and MKDEATH is already the module closest to GSPA's ceiling; one `.globl`
beside the definition plus one `.ref` in the module that needs it costs two.

## `dec_my_p_hit` goes with it

`r_ermac_teleslam` ended by handing the hit back — *"one telekinetic slam should
not cost the victim a step of juggle scaling on top of the damage"*. That is
sound while the slam is unscaled, and it is exactly what the slam now pays, so
the hit stays counted (under `ermtkscale`; `0` restores it).

**Neither half is right on its own.** Handing the hit back while the damage is
unscaled is how the slam came to be worth full value however deep into a string
it landed. Scaling it while still handing the hit back would leave whatever
*follows* it unscaled instead, and the bounce and the get-up are ~56 ticks of
juggle window.

It only ever mattered for that window: his feet are already down (`stop_me` /
`ground_player` run before the damage), and the bounce ends in `gravani`, which
clears `p_hit` on landing — so the hit given back was never visible past the
get-up.

It also removes a contradiction in the code, though this half is not measured on
screen: `cmb_lifted` holds the combo window open across the whole flight
*precisely* so that a hit which follows him down continues the string rather
than opening a new one — and `hud_combo_hit` decides "new string" by reading the
victim's `p_hit`, which `dec_my_p_hit` had just put back to 0.

## Measured

`-Mode scale -Seed N` seeds the victim's `p_hit` so the slam lands as the
(N+1)th hit of a string, and reads what the impact takes off his bar. Seeded
rather than driven, for the reason `run_rain_halfdmg_probe.ps1` seeds `rh_cdmg`:
building a real three-hit juggle into the slam is a second thing to get right,
and the counter *is* the input `dmgscale` reads.

| string depth | before | after |
|---|---|---|
| opening hit | 9 | 9 |
| 2nd (3/4) | 9 | **7** |
| 3rd (1/2) | 9 | **4** |
| 4th+ (1/4) | 9 | **2** |

The unscaled build is the control and fails three of the four; **seed 0 passes
on both**, which is the positive control that the rig is not simply failing
everything.

The re-grab gate is unaffected — `-Mode chain` and `-Mode slamonly` still read
`regrabs=0` with the same bars (161→96 and 161→116). The chain loop's own damage
does not move, and that is correct: the rig's cadence lets the victim land and
reset between slams, so every one of them is still an opening hit. The scaling
only bites when the slam is genuinely part of a string.

### The seed has to stop at the catch

`-Mode scale` holds the seed every tick *until* the grab takes hold and then
lets go, because `back_to_normal` clears `p_hit` whenever the victim settles but
the index is read at the **impact**, which must carry the catch's own
`inc_p_hit` on top of the seed.

This is also why `run_ermac_teleslam_test.ps1` still reports `damage=9` on the
scaled build rather than 7, despite seeding a string for its combo-clock test:
its poke is gated on `not caught`, and `caught` needs 20px of lift, so it keeps
writing `p_hit = 1` for ~10 ticks *past* the catch and overwrites the
`inc_p_hit`. The index then resolves to 0 and the slam is an opening hit. That
is the rig's poke window, not the scaling failing — and it is an independent
confirmation of where the index comes from.

## Not changed

The other `damage_to_me` sites have the same hole and are left alone: they are
the **throws** (`slammed_by_jx` 18, `slammed_by_st` 24, `slammed_by_cage` 34,
the flip-damage table) and chip. Scaling MK2's throws is a far wider balance
change than this one and nobody has asked for it.

---

The same hole exists in every THROW in the game, and Jax's multi-slam is the
worst case of it — 58 damage off one input. That is
[doc/THROW_DAMAGE_SCALING.md](THROW_DAMAGE_SCALING.md), which shares this one's
`dmgscale_a10`.
