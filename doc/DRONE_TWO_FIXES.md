# Two proposed drone fixes, both user-reported and confirmed in source

Written 2026-09-28. Neither is built or installed — another session holds the toolchain.
Both are small, targeted, and verifiable with rigs that already exist.

Background: a night of measurement found **no exploitable weakness** in the drone's defence
(seven probe methods, all negative — see the CPU exploit-map memory). Both fixes below came
instead from the user playing the game and saying something felt wrong, then checking the
specific claim in source. That is worth noting as a method: the measurements found nothing and
the player found two things.

---

## FIX 1 — the drone grabs you out of a projectile ("even in an attack Jax backbreaker gets you")

### What happens
`scan_quick_flipp` (MKDRONE.ASM) gates Jax's back breaker on the player not attacking:

```
	calla	is_he_attacking
	jrc	sqf5			; he's attacking ---> no backbreak
```

The intent is clear from the comment: do not grab a man who is committed to an attack.
But `is_he_attacking` masks the action to its HIGH BYTE and accepts only two categories:

```
is_he_attacking
	callr	drone_get_his_action
	srl	8,a1
	sll	8,a1			; category only
	cmpi	act_attacks,a1		; 0100h  - normal attacks
	jreq	ihay
	cmpi	act_body_propell,a1	; 0200h  - flying kicks
	jreq	ihay
	clrc				; anything else = NOT attacking
```

**Every projectile in the game has an action below 0100h**, so all of them mask to category 0
and read as "not attacking". Verified: category 0 holds exactly 25 actions, `001h..019h`,
contiguous, and every one is a projectile — `throw_hat`, Liu Kang's three zaps, `jcsnot_lo/hi`,
`spark`, fans, sais, the three skulls, `throw_bolt`, `throw_ice`, `spear`, `spit`, `slow_orb`,
`jax_zap`, the air variants, `ermac_zap`, `rain_bolt`, `rain_zap`. No `act_*` is 0 (0 = no
action), so category 0 contains nothing else.

So: throw a fireball at Jax inside 96px and he back-breakers you out of it. It beats block, it
cannot be reacted to (`act_backbreak`'s zero counter row is deliberate and correct — by then
`takeover_him_sr` has already taken the victim), and the trigger reaches **96px where an
ordinary throw reaches 64px** (`movi 040h,a7`, JOY.ASM) and, unlike an ordinary throw, has no
airborne requirement (`is_he_airborn -> toss_no` guards the normal one; nothing guards this).

### Proposed change — NARROW, at the gate only

```
	calla	is_he_attacking
	jrc	sqf5			; he's attacking ---> no backbreak
	callr	is_he_projecting	; ...and a projectile is a commitment too
	jrc	sqf5
```

with a new helper beside `is_he_attacking`:

```
*
*  is_he_projecting - carry set if he is throwing a projectile right now.
*
*  is_he_attacking cannot answer this: it masks the action to its high byte and
*  tests only 0100h and 0200h, and EVERY projectile action is below 0100h, so all
*  25 of them read as "not attacking".  Category 0 is exactly those 25 (001h..019h,
*  contiguous) plus "no action" at 0, so a non-zero action with a zero category IS
*  a projectile - no list to keep in step as fighters are added.
*
is_he_projecting
	callr	drone_get_his_action	; a1 = his action
	move	a1,a1
	jreq	ihp_no			; 0 = no action
	srl	8,a1
	jrne	ihp_no			; category != 0 = not a projectile
	setc
	rets
ihp_no	clrc
	rets
```

### Why narrow rather than widening `is_he_attacking`
It has **ten callers**, and they are not all the same question:

* **"wait while he is busy"** — `drone_wait_nonattack`, `drone_wait_non`,
  `is_he_done_attacking`, `drone_guard_hold`. These currently stop waiting the moment the
  player throws, so the drone counters INTO the projectile. Widening would improve them, but
  that is a separate behaviour change deserving its own measurement.
* **"is it safe to commit"** — `scan_quick_flipp` (this fix) and `quick_flip_attack`.
* **BOSSES** — MKBOSS.ASM:2290 and :7741. Shao Kahn and Kintaro already win **98.2%** and
  **96.9%** of rounds (72,055 and 26,441 logged). They are the last two characters that should
  be handed a behavioural buff by a definition change made for Jax.

### How to verify
`act_backbreak` is 0109h and the drone's decisions are logged by
`tools/drone_decision_log.lua` with distance and outcome. Before: the backbreaker fires while
the player's action is in 001h..019h. After: it does not. The same log answers whether the
drone simply does something else instead, which is the thing to watch — a fix that only
converts a grab into a free hit is not a fix.

**Sample size caution:** only 3 backbreaker attempts appeared in 2,500 logged decisions, all
at 10px. The tool that would force Jax as the opponent, `FB_FORCE_OPP`, kills MAME after one
round (3/3 tried). Either fix that first or accept a long run.

---

## FIX 2 — the drone keeps attacking after the match is over

### What happens
The helper exists and says so itself:

```
* drone_round_over - carry set once the round has been decided.
* Cheap enough to put between the hits of any string.  winner_status is the
* same word drone_beware refuses to react on, so this is not new knowledge,
* just knowledge the attack loops never asked for.
```

**Six call sites against 161 drone routines.** Measured with `winner_status` logged beside
each decision: **4 of 46 decisions (8.7%) were taken after the match was decided** — three
uppercuts (0107h) and one row carrying `673a`, which is not a valid action code at all.

### Why it may be more than cosmetic
There is a documented OPEN bug: the game parks in **gstate 5** after a round ends and never
starts the next round, roughly 1 in 300-400 rounds, seen in 7 fly-training segments and never
chased because the crash ring records fight frames only. A drone still committed to a move
when the round-end flow tries to take its process over is a plausible cause, and the junk
action code above is the kind of state that would go with it. **Not proven — stated as a
hypothesis with a way to test it:** the decision log now carries `gstate`, so a park captured
during a logged run will have the drone's actions leading into it.

### Proposed change
Add `drone_round_over` checks to the attack loops that lack them, starting with the ones that
actually fired post-match in the measurement (the uppercut path first). This is not a
one-liner across 155 routines — it is a targeted pass, ordered by what the log shows firing.

### How to verify
Re-run the same measurement and require zero decisions with `winner ~= 0`. The rig is
`tools/drone_decision_log.lua` as FB_ADDON; it already logs `winner` and `gstate` per decision.

---

## What is NOT proposed

* Widening `is_he_attacking` globally — see the boss blast radius above.
* Anything about Liu Kang's back-flip air fireball. That is deliberate and documented:
  `drone_air_zap_try` has three range branches and the point-blank one back-flips because a
  forward flip has no runway. It is a tuning/feel question (`air_zap_close` and its cooldown),
  not a defect.
* Touching the backbreaker's 96px reach or its missing airborne test. Both are odd next to an
  ordinary throw's 64px grounded-only rule, but observed usage is point-blank and the evidence
  is 3 samples. Fix the projectile gate first and re-measure.
