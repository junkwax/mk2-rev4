# Boss AI: Kintaro catches you out of the air, and the bosses take their turn

Reported: *"boss battles are way too easy and susceptible to high kicks and
flip kicks in. Kintaro should be grabbing you from the air and slamming you
and Shao Kahn should block and punish."*

Three switches in `src/MAINEQU.ASM`, all 1:

| switch | what it does |
|---|---|
| `gorograb` | Kintaro catches a man out of the air and slams him; he can also see a bare jump-in, a landing and a get-up at all |
| `goropun` | Kintaro takes the turn a clean block or a whiff hands him |
| `kahnkick` | Shao Kahn answers KICKS the way he answers punches, and a flying kick at the heavy tier |

Rig: `tools/run_boss_exploit_test.ps1` (`-Boss goro|kahn`,
`-Mode flipkick|hikick|rhouse`, `-All`). Frozen A/B pair used below:
`C:\tmp\bossai\off3` and `C:\tmp\bossai\on3`, each holding `mk2.zip` **and the
`mk2.map` that belongs to it**.

## What was measured, before and after

16 cycles per trial, difficulty 9, Sub-Zero against the boss. "clean" excludes
chip: a blocked flying kick still takes 4 off the bar, and counting that as a
connect is what first made Shao Kahn look 75% vulnerable when he was guarding
9 of those 12 hits correctly.

| trial | clean connect | | punished | | damage he takes / deals | |
|---|---|---|---|---|---|---|
| | **off** | **on** | **off** | **on** | **off** | **on** |
| Kintaro, flip kick | 75% | **19%** | 19% | **81%** | 162 / 205 | **45 / 612** |
| Shao Kahn, flip kick | 19% | **6%** | 19% | **38%** | 93 / 104 | **51 / 292** |
| Shao Kahn, roundhouse | 56% | **38%** | 50% | **69%** | 198 / 456 | **132 / 688** |
| Kintaro, high kick | 38% | 41% | 68% | 74% | 212 / 1000 | 224 / 1034 |
| Shao Kahn, high kick | 50% | 50% | 75% | 75% | 192 / 687 | 192 / 687 |
| Kintaro, roundhouse | 31% | 31% | 75% | 75% | 75 / 536 | 75 / 536 |

Kintaro took the man out of the air **13 times in 16** flip-kick attempts
(`debug4` = 7130h, a breadcrumb only `gorograb` can write).

The high-kick rows are over 34 cycles; at 16 the Kintaro figure read 38 -> 50,
which is one and a half standard errors on n=16 and was sampling, not a
regression.

**The last two rows are the control, and they are worth as much as the rest.**
Neither trial touches code any of the three switches changes, and both came out
**byte-identical** across the two ROMs - same connect count, same damage totals,
same per-cycle log. So the rig is deterministic, and the four rows that did move
moved because of the change rather than because of a different dice roll.

## Why the standing high kick is not in the win column

Shao Kahn's high-kick row is identical in both builds, and the rig says exactly
why: **a standing high kick lands SIX ticks after `act_hikick` is stamped**
(min = avg = max = 6 across every landed hit of every run), and
`drone_react_delay` is **EIGHT** at difficulty 9 under `drnhuman`. The think
timer has not expired when the kick lands, so the boss never gets to make a
decision at all - his blocked rate is 0% whatever `kahn_counter_stationary`
says, which is why two ROMs differing in precisely that routing produced the
same fight frame for frame.

That is not a routing bug. It is the reaction model working as designed: the
`drnhuman` block in MAINEQU argues at length that a CPU answering something no
person could have seen reads as controller-reading and teaches nothing, and
sets the floor at ~146 ms. A 6-tick move is 110 ms. Blocking it on reaction
means going superhuman.

An anticipation clause was built and then **removed**: for the two bosses only,
a move the hit queue said had already landed twice dropped the think time to
`drnhuman`'s own 5-tick floor (the same argument `p_predhit` already makes for a
multi-move string, applied to one move repeated). It assembled, it was correct,
and a counter in `debug1` showed it firing **once in 12 cycles** - `p_predhit`
is usually already non-zero on this pattern, so the existing path had the case
and the floor of 5 still loses to a hit at 6 once the dispatch and the guard
pose are paid for. Forty-five lines in the most-included file in the build that
look load-bearing and are not are worse than nothing, so they came out and the
measurement lives here instead.

What the numbers say about the pattern itself: the bosses already **win** the
high-kick trade heavily - Kintaro takes 224 and deals 1,034, Shao Kahn takes 192
and deals 687. A wall of high kicks is a losing exchange for the player before
any of this. The roundhouse, which has an 8-tick startup, is the kick the boss
*can* see, and that is the row where `kahnkick` shows up.

## Kintaro

### `goro_air_slam` - the catch

The body slam with its order of operations changed, and that is the whole move:
no new art, no new animation lane, no new reaction. `goro_slam` matches the
victim to Kintaro **after** the full 24-tick grab animation, which is right for
a man standing in front of him because he does not move in the meantime. A man
in the AIR does: `takeover_him` zeroes his velocity, so he would hang where he
was for the whole reach and the slam would then teleport him down. Matching
**first** means the hands close where he actually is and he comes down with
them. Everything after the reach is shared with the ground slam at
`goro_slam_hold`, so the held pose, the roar, the shake and `slammed_by_goro`'s
40 damage are one copy. The reach itself runs a tick a frame faster - it is a
snatch, not a heave off the floor.

`goro_air_grab_ready` is the gate, and every number in it is read off
something: `goro_grab_minheight` 018h (below that he is landing anyway and the
uppercut is the tool), `goro_grab_maxheight` 090h (Kintaro's own height - above
it the hands do not reach), `goro_grab_reach` 070h (his arms, deliberately
shorter than `can_goro_slam`'s 078h, which gates a slam on a grounded man
walked into). `diff_airgrab` is zero below difficulty 2 and tops out at 850, not
1000 - a grab every single time is its own bait: jump once, watch him commit,
and the next one is free.

**Ask the budget last.** `goro_slam_ready` *stamps* `l_gslam` when it says yes,
so a caller that asks and then declines the move has spent the slam's turn on
nothing. The air grab shares that budget on purpose, so the two heavy grabs
cannot both spam.

### Where he can now see a man in the air

Four places, and three of them were holes:

- `goro_catagory_jumps` entry 3 was a literal **0**, so `act_angle_jump`,
  `act_jumpup`, `act_land` and `act_getup` - every bare jump-in, every landing
  and every get-up - were invisible to him. `goro_counter_nonattack` fills it,
  the way `kahn_counter_nonattack` has since the jump-in exploit was closed on
  Shao Kahn.
- `goro_counter_flipkp` named `goro_av_flipkp` - a guard - in **both**
  `react_jump_table` slots, so the roll the table exists to make decided
  nothing at all. The catch goes in the first slot and the guard stays in the
  second, which is the forced one: that slot is taken on a difficulty roll *or*
  whenever `count_q_repeats` says the move has already beaten him too often, so
  it has to hold the reliable answer. Tier also moves 1 -> 3: `drone_rpt_1` is
  800 at difficulty 9, meaning one flying kick in five was simply ignored, and
  `repeat_1` allowed two to land before forcing the guard. Tier 3 is 950 and
  forces it after one.
- `goro_stalk` fell through to `goro_air_wait` and **stood there** - he would
  close the distance, see a man above him, and wait. Both the walk-in
  (`goro2`) and the close decision (`goro4`) now offer the grab first. The
  uppercut keeps the case where the grab will not reach: it is his anti-air and
  the face smash comes down rather than up.

### `goro_take_the_turn` - the block was read the wrong way round

`boss_wait_nonattack` returns a10 **non-zero when the guard worked** - its own
comment says so, and `kahn_block` reads it that way. Kintaro's only punish hung
off the **zero** case, the timeout, where the man is still mid-string. So the
ordinary exchange - kick, blocked, kick, blocked - earned him precisely
nothing, which is most of how a wall of normals beats him: guarding was free
for the attacker. Both halves take a turn now; `stop_abusive_attackers` keeps
the timeout and `goro_take_the_turn` is the clean-block one.

It also fills category 6. `goro_counter_sd`'s entire answer was "guard a
projectile if there is one, otherwise go back to sleep", so every whiffed
uppercut and every blocked sweep in front of him was free - the same hole
`kahn_counter_sd` exists to close. A man flat on the floor, one still rising
off Kintaro's own uppercut, and the deep-freeze fatality state are all declined
by name: nothing of his reaches down there, chasing a juggle does nothing, and
hitting `act_super_froze` steps on a death sequence.

It is a punish and not a radar: a difficulty roll, then the body slam's own
`l_gslam` budget for the heavy answer, and he never walks across the screen to
collect one - what does not reach from where he stands becomes a fireball.

## Shao Kahn

He already had the machinery; two things were leaking.

**Kicks went through `react_jump_table` at tier 1 while every punch reached
`kahn_counter_punch` and was guarded outright.** At difficulty 9 that is one
kick in five ignored before the table's first entry is even read.
`act_hikick`, `act_medkick`, `act_rhouse`, `act_duck_kickh` and
`act_duck_kickl` now go straight to `kahn_avoid_stationary`.

That routine rather than `kahn_block` directly, and deliberately: it guards
when `will_he_reach_me` says the swing lands and steps out of it when it
cannot. Blocking a kick that was never going to touch him spends his turn for
nothing - the note in `kahn_avoid_stationary` records that costing two whole
ladder matches. So what changed is that a kick which *does* reach is guarded
every time instead of four times in five, and the punish on the far side of
`kahn_block` collects it. Measured on the roundhouse: 56% -> 38% clean connect,
punish 50% -> 69%, and the damage he deals over the same sixteen exchanges goes
456 -> 688.

**The flying kick was at tier 2.** `drone_rpt_2` is 875 at difficulty 9 - one
in eight still ignored - and `repeat_2` lets two land before forcing the guard.
Tier 3 is 950 and forces it after one. 19% -> 6% clean connect, punish 19% ->
38%, damage dealt 104 -> 292.

## Rig notes

- **It never pins the attacker's position.** A rig that teleports P1 to a fixed
  gap every frame also cancels the knockback a block earns and the pull of
  Kintaro's grab, so the boss gets measured against a man the engine cannot
  move - the one thing a real player is not. P1 walks to the range with the
  stick.
- **Chip is not a connect.** Classify on what the boss was doing on the frame
  the damage landed; `act_0700` is `act_blockhi` and means he guarded.
- **The startup window only means anything for a grounded normal.** A flying
  kick's action changes on the contact frame itself, so the measurement reads 0
  and says nothing about its startup.
- **`f_freeze_timer` must be pinned every frame.** Pinning the bars stops a KO
  but not a TIME OVER, and a round that ends mid-sample tears the stage down.
- It runs under `mame_mk2test.exe` with a private `nvram`/`cfg` and kills only
  that name, so peers' rigs and the flybrain trainers survive it.
