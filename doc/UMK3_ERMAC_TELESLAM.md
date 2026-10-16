# Ermac's telekinetic slam — decoded, and the first port corrected

Re-derive everything below with:

```
python tools/umk3_teleslam_extract.py          # the report
python tools/umk3_teleslam_extract.py --old    # + the rows the first port used
python tools/umk3_teleslam_extract.py --render tmp/umk3
```

Two sources, both read rather than remembered:

- **Data** — the grab box and the victim's animation lanes — out of
  `C:\MAME\roms\umk3.zip`, the shipped arcade program ROM.
- **Code** — the order those lanes play in, the velocities, the tick counts and
  the damage — out of the UMK3 source at
  `Workplace/UltimateMortalKombat3`. The tool quotes it verbatim with line
  numbers rather than paraphrasing it.

---

## The correction: the first port was built on the wrong lanes

The earlier version of this document identified the victim sequence as UMK3
`anitab1` rows **`0x44`** ("the hold") and **`0x41`** ("the descent"), found by
pattern-matching for *a lane every character has, that loops, that draws the
body 130px above its anchor*. Every one of those observations was true. None
of them was Ermac.

`MKGUYS.H` names the rows:

| row | what it actually is |
|---|---|
| `0x44` | `ANIM_JADE_SHOOK` — the victim of **Jade's fan lift** |
| `0x41` | `ANIM_AFB_ROBO2` — air-flipped by **Cyrax** |
| `0x43` | `ANIM_ORB_BANGED` — hit by Reptile's orb ← *this* one is Ermac's |

Ermac's slam never touches `0x44` or `0x41`. The four-beat ping-pong, the
±22px "wobble", the "hold that loops until he lets go" — all of it was Jade's
move. The port that came out of it looked like nothing in the arcade because
it was a faithful rendering of a different move.

Two things made the wrong lane look right, and both are worth remembering:

1. **The art is shared.** Row `0x44` frame 2 is the same strips as
   `ANIM_STUMBLE` frame 1, and frame 1 is the same as `ANIM_ORB_BANGED` frame
   1. Decoding the pixels and seeing "a limp arched body" confirmed nothing —
   both moves throw the same body around.
2. **A loop looks like a hold.** `0x44` really does loop, which really is the
   shape of a state that runs until the attacker releases. Jade's fan lift is
   also that shape.

The lesson is the one `reference_shared_move_rig_attribution` already records
in a different form: *a property shared by several moves is not evidence for
any one of them.* The thing that would have settled it in five minutes is the
one used now — the strike record's routine word names its own reaction.

---

## How the real sequence was identified

Three independent confirmations, and they agree.

**1. The strike record names the reaction.** `stat_do_ermac_slam` polls
`strike_check_a0(obj,0x1a)`. Row `0x1a` of the male-ninja strike table (byte
`0x5e6c2`; Scorpion, Reptile and Ermac share one table) carries routine word
`0x7801`. The high byte is the reaction index, and `MKREACT.C`'s table names
entry `0x78` `r_ermac_slam`. That is the victim sequence, by name, from the
data.

**2. The ending is already in MK2, constant for constant.** UMK3 finishes with

```c
flight(pa8, -SCX(0x38000), -SCY(0x80000), SCY(0x6000), 4, ANIM_ORB_BANGED);
```

MK2's `r_orb` (MKREACT.ASM) finishes with

```asm
	movi	-038000h,a0	; a0 = initial x vel
	movi	-080000h,a1	; initial y vel
	movi	06000h,a2	; grav
	movk	4,a3		; a3 = ani speed
	movi	03ah,a9		; a9 = ani offset
	jsrp	flight
	jruc	land_on_my_back
```

`ANIM_ORB_BANGED` is UMK3 row `0x43`; MK2 row `0x3a` is `a_banged`. Same
animation, same four constants, two different engines. The bounce needed no
porting at all — it is a line MK2 already shipped.

**3. A live capture measured the flight before the source turned up.** One PNG
per emulated frame, victim tracked by colour, Ermac vs Nightwolf:

| phase | frames | victim mid-Y | per-frame delta |
|---|---|---|---|
| standing | — | 158 | — |
| lift | 16 | 157 → 124 | ~2px, with a 4-frame wobble |
| launch | 7 | 117 → 24 | −7 −8 −12 −12 −20 −16 −26 |
| **off the top of the screen** | 6 | not visible | — |
| descent | 6 | 33 → 243 | +24 +36 +44 +52 +54 |
| impact / settle | — | ~222 | flat on his back |

Those are exactly `shake2` over `oyvel = -2.0`, then `ograv = -3.0`
(accelerating **upward** by 3px/tick each tick), then `ograv = +8.0`. The
capture and the source agree to the constant, which is why neither is taken on
trust here.

---

## The move

### Attacker — `stat_do_ermac_slam` (MKSTAT.C)

It does almost nothing, and that is the single biggest structural difference
from the first port:

```
init_special_act(ACT_ERMAC_SLAM)
animate2_a9(2, ANIM_ERMAC_SLAM)     play the windup, hold the last pose
ochar_sound(0xf)                    floor rumble
shake_a11(3, 8)
16 ticks:  strike_check_a0(0x1a) once a tick, skipped against a boss
  caught   -> sleep 8
  blocked  -> break out immediately
  nothing  -> p_action = ACT_ER_SLAM_SD, sleep 0x30
backwards_ani2(2, ANIM_ERMAC_SLAM)  the same lane, walked back down
reaction_exit
```

He never touches the victim. He is finished, arm down, ~26 ticks after the
catch, while the victim still has 90 ticks of flight left.

### Victim — `r_ermac_slam` (MKREACT.C, reaction `0x78`)

This is the whole move, running in the victim's own process:

```
slammed_shake_up     pose ANIM_STUMBLE frame 0, group_sound(2)
                     oyvel = -SCY(0x20000)          2.0 px/tick up
                     shake2(±3, ±3, 4 shakes, sleep 2)   -> 16 ticks
slammed_zoom_up(8)   oyvel = -SCY(0x40000)          4.0 px/tick up
                     ograv = -SCY(0x30000)          NEGATIVE - accelerates UP
                     sleep 8      (he leaves the top of the screen)
                     ANIM_KDOWN part 2 frame 1
slammed_slam_down    ograv = +SCY(0x80000)          8.0 px/tick/tick down
                     loop until oypos >= p_ganiy
                     stop_me, ground_player
impact               damage_to_me(9)
                     ANIM_KDOWN part 2 frame 2
                     shake_a11(8, 0xc)
                     dec_my_p_hit, rsnd_ground, group_sound(2)
                     sleep 8
bounce               flight(-0x38000, -0x80000, 0x6000, 4, ANIM_ORB_BANGED)
land_on_my_back
```

### The grab box

| field | arcade | note |
|---|---|---|
| x offset | 206 (`0xce`) | the front edge — his reach |
| y offset | 36 (`0x24`) | |
| x size | 106 (`0x6a`) | so the box spans ~100..206px |
| y size | 90 (`0x5a`) | |
| routine | `0x7801` | hit → `r_ermac_slam`, block → `b_hard` |
| damage | 0 | the reaction applies its own |

**No conversion is needed.** MK2 and UMK3 measure strike boxes identically —
checked on moves both games have: ninja lo kick is x 109 in both, hi punch 77
vs 78, sweep 103,107 vs 96,107, uppercut 77,−19 vs 78,−16.

206px is the second-longest reach in that whole table, and that is the
character of the move: it is a *telekinetic* grab, thrown from most of a
screen away. It also means there is a real dead zone **closer** than ~100px —
standing on top of somebody whiffs. That is arcade behaviour, the same shape
as the point-blank uppercut dead zone MK2 already has.

---

## The MK2 port

| UMK3 | MK2 |
|---|---|
| strike row `0x1a` | `stk_ermac_teleslam` ([src/MKSTK.ASM](../src/MKSTK.ASM)) |
| reaction `0x78` `r_ermac_slam` | `r_ermac_teleslam` ([src/MKREACT.ASM](../src/MKREACT.ASM)), `react_to_ermac` row `0x1c` |
| `stat_do_ermac_slam` | `do_ermac_teleslam` ([src/MKSLAM.ASM](../src/MKSLAM.ASM)) |
| `ANIM_STUMBLE` `0x20` | anitab1 row `0x23` — `a_njstumble` |
| `ANIM_KDOWN` `0x1e` | anitab1 row `0x0f` — `a_njkdown` |
| `ANIM_ORB_BANGED` `0x43` | anitab1 row `0x3a` — `a_banged` |
| `ACT_ER_SLAM_SD` `0x62a` | `act_ermac_tks_sd` `0x61d` ([src/MAINEQU.ASM](../src/MAINEQU.ASM)) |
| every constant | `erm_tks_*` ([src/MAINEQU.ASM](../src/MAINEQU.ASM)) |

Every victim lane the arcade uses already existed in MK2 under a different
number, on every character, so **the port needed no new art and no new tables**
— which is itself a check on the row mapping.

Four things MK2 needed that it did not have:

1. **`backwards_ani2`** ([src/MKUTIL.ASM](../src/MKUTIL.ASM)). MK2 shipped only
   the table-1 half. Three lines, sharing `backwards_ani`'s tail.
2. **A single-part attacker lane.** `a_ermac_teleslam` was two parts with the
   arm-up pose alone in part 2, reached by a hand-counted `addi 128,a9`.
   `animate2_a9` / `backwards_ani2` cannot straddle a part break, and the bit
   offset was one added frame away from pointing into the middle of a record.
   It is one four-frame part now.
3. **`f_noscrolly` for the duration.** MK2's vertical camera (`scrl6`,
   BGND.ASM) chases whichever fighter is above the barrier, so without the
   freeze the view follows the victim off the top and drags Ermac out of frame.
   UMK3's camera does not chase — the capture shows the victim simply gone for
   six frames — so freezing is the faithful behaviour, not a workaround.
4. **`act_ermac_tks_sd` in the drone tables.** A new `06xx` action needs an
   entry in `counter_sitting_duck` *and* `sd_punish_tier` *and* a bumped
   `sd_tier_max`, or the drone reads off the end of a table
   ([src/MKDRONE.ASM](../src/MKDRONE.ASM) says so in a comment, having been
   bitten by exactly that with `act_jade_nitro_sd`). Tier 3 — 48 ticks stood
   still is the longest special recovery Ermac has.

### Two things that are deliberately not UMK3's

- **`reaction_exit`, not `do_backup`.** `do_backup` plays the DUCK lane
  backwards — it is the exit for a move that *ends crouched*. This one ends
  standing, and exiting through `do_backup` made Ermac drop into a crouch and
  climb back out of it, on camera, every time. UMK3 ends in `reaction_exit`
  and so does this now.
- **No `update_tsl(l_ermac_slam)`.** MK2 has no such timer and no drone gate
  that would read it, because the drone never throws this move. Adding a dead
  timer would be adding a thing to keep in sync for no behaviour.

### The combo window is paused for the whole flight

Not UMK3's, and not a deviation from it either — UMK3 has no combo readout to
keep. MK2 does, and the slam is the one move in the game long enough to
outlive it in a way the player can see.

The catch is an ordinary clean hit of damage 0, so `hud_combo_hit` arms
`cmb_tick` to `hudcmb_hold` (`0x40`, 64 ticks) the tick the grab connects.
The victim is then **35 ticks** getting lifted, hurled off the top of the
screen and dropped back onto the floor, and a further ~56 in the bounce and
the get-up before he can act again. Left alone, the window spends more than
half of itself on a man who is not on screen and closes while he is still
bouncing — so whatever follows him down opens a fresh string instead of
continuing the one that put him up there.

`r_ermac_teleslam` raises `cmb_lifted` (MKDISP.ASM) alongside `f_noscrolly`
and drops it in the same place — the tick `ground_player` puts his feet back
down, deliberately *before* the impact, because everything after that can be
pre-empted by a round-over and a flag that never comes down would freeze the
readout's clock for the rest of the match. `cmb_holding` reads it first,
ahead of its action-code table.

It has to be a flag and not an action code: the four holds `cmb_holding`
already knew about (`act_frozen`, `act_speared_sd`, `act_slipping`,
`act_jax_dizzy`) each have a code of their own, but the slam's victim is in
plain `act_reacting` (`0x503`) from the catch to the get-up — the same code
every reaction in the game runs under, including a jab.

**Paused, not re-armed.** He lands with what the catch left on the clock and
it runs from there, so a slam that *ends* a string still times out on its own.
The rig reads 63 of 64 at the moment his feet touch down — the single tick
spent on the frame the flag came back down.

### Damage: 9, and the earlier measurement agrees

`r_ermac_slam` calls `damage_to_me(9)`. UMK3's `FULL_STRENGTH` is `0xa6` (166)
and MK2's is `0xa1` (161), so the two scales are within 3% and 9 ports across
as 9 — no conversion.

This *supersedes* `erm_tks_damage = 0x10` (16), which came from reading the
victim's health bar in the capture: 95px → 86px on the landing, called "9.5% of
the bar" and scaled onto 161. The capture was right and the arithmetic was
wrong — UMK3 draws that bar one pixel per HP, so a 9px drain is **9 HP**, not
9.5%. Measurement and source agree exactly once the units do.

---

## Verified on screen

`tools/run_ermac_teleslam_test.ps1` (rig: `tools/ermac_teleslam_test.lua`).
It measures the victim, not the attacker — since the rewrite Ermac's own
routine finishes at t=50 while the victim has only reached the top of the
shake-up, so an attacker-keyed rig stops the trace 30px in and scores a
working move as a hover.

```
PASS ermac_teleslam: fired=true caught=true lift=208px damage=9 attempts=1 clock=63@t70 held=true
```

`clock=63@t70 held=true` is the combo window: 63 of `hudcmb_hold`'s 64 ticks
still on it at t=70, the tick his feet touch down, and `cmb_lifted` seen
raised for the flight. The rig pokes the victim's `p_hit` and P1's
`cmb_hits`/`cmb_tick` before the attempt so the slam lands as the *second*
hit of a string (`TKS_CLOCK=0` turns that off) — `cmb_fly`, the process that
counts the clock down, is not created below `hudcmb_min` (2 hits), so against
a lone slam the clock simply parks at whatever it was armed to and a rig
watching it learns nothing. The threshold is `>= 0x38`, not `> 0`: an
unpaused clock still has ~29 ticks left when he lands, so "non-zero" would
pass with the hold removed.

The victim's height trace, one line per tick, against what the arcade capture
measured:

| phase | ticks | what the trace shows |
|---|---|---|
| shake-up | 46–51 | dy 22 → 32, visibly jittering (22, 21, 23, 28, 30, 32) |
| zoom | 52–59 | +7 +10 +13 +16 +19 +22 +25 +28 — accelerating by 3/tick |
| off-screen peak | 60–62 | y reaches −131, i.e. off the top of a 254px screen |
| slam down | 63–70 | −4 −12 −20 −28 −36 −44 −52 — accelerating by 8/tick |
| impact + hold | 70–78 | ground shake, damage 9 |
| bounce | 79–120 | a 42-tick arc through `a_banged`, exactly `r_orb`'s |

Other paths, same rig:

- `TKS_BLOCK=1` — 13 attempts, victim in `act_blockhi` (`0x700`) throughout,
  never caught, Ermac's routine exits at t=42 on the blocked branch. A blocked
  telekinetic slam does not grab.
- `TKS_RANGE=270 TKS_MIN=225` — 13 attempts from outside the box, `p1_action`
  ends on `0x61d` (`act_ermac_tks_sd`). The whiff recovery runs and does not
  wedge.
- `tools/run_battle_stability_sweep.ps1` — 25/25 PASS after the change.

---

# The fatality: `ermac_super_slam`

Shipped 2026-09-08. **Down, Up, Down, Down, Down + BLOCK**, at sweep range or
further.

The fatality is the special above with its ending taken off and its middle
repeated, which is not a convenience — it is literally how UMK3 builds it.
`ermac_super_slam` (MKFATAL.C, `ochar_fatalities1`) is four lines long:

```c
void ermac_super_slam(void)
{
	fatality_start_pause();
	animate2_a9(2,ANIM_SCORP_SUMMON);
	takeover_him(r_ermac_fatal_slam);
	process_sleep(0xa0);
	backwards_ani2(2,ANIM_SCORP_SUMMON);
	process_sleep(10);
	death_blow_complete();
	local_victory_animation;
}
```

Everything an audience would call the fatality happens in the VICTIM's
process, in `r_ermac_fatal_slam` (MKREACT.C) — which is `r_ermac_slam` with
the damage and the bounce replaced by three more hurls and a pop:

| `r_ermac_slam` (special) | `r_ermac_fatal_slam` (fatality) |
|---|---|
| — | `center_around_me` |
| `slammed_shake_up` | `slammed_shake_up` |
| `slammed_zoom_up(8)` | 4 × { `slammed_zoom_up(8)` |
| `slammed_slam_down` | `slammed_slam_down` |
| `damage_to_me(9)`, `shake_a11`, bounce | `death_slam_pause` } |
| `land_on_my_back` | `set_inviso` + `create_fx(FX_SWAT_BEXP)` |

So every velocity, gravity and tick count it runs on is the `erm_tks_*` block
in MAINEQU.ASM — already measured, already shipping in the special. Only the
beat and the ending are new, and those are `erm_tksf_*`.

## What is deliberately not UMK3's

**The explosion.** UMK3 ends on `FX_SWAT_BEXP` — Stryker's bomb burst, which
has no counterpart in MK2. MK2 already owns the body-pops-into-chunks
sequence, and it is a REACTION running in the victim's own process, which is
exactly where our reaction already is, so the last line of the victim's half
is a jump into it:

```asm
	jauc	r_shocker_pop		; MKDIE.ASM
```

`r_shocker_pop` rather than `r_burst_pop`: they are the same routine, and
`r_burst_pop` only adds an `inflate_pose` + palette swap + 3-tick hold on the
front of it. That swell belongs to Raiden's electrocution, where the body is
being pumped up. A body that has just been driven into the floor four times
does not puff up first — it comes apart.

## The head

Added 2026-09-08 by request: the burst throws the opponent's head clear, it
**falls in from above the top of the frame**, hits the floor and bounces
twice.

```asm
	create	pid_head,ermtkf_head_drop
	move	a8,*a0(pa10),l		; the head copies its ochar from the body
	jauc	r_shocker_pop
```

`ermtkf_head_drop` (MKREACT.ASM) is `decapped_head` (MKCANNED.ASM) re-aimed:
same `03dh` head-roll lane, same `gso_dmawnz`/`insobja8` build, same `01fh`
ground sound, same bounce shape. Only the start changes. `decapped_head` lines
the head up on the body's **neck** and throws it **upward**, which is what a
decapitation looks like; this body has just come apart in mid-air, so the head
arrives from above instead, already falling. (The first working version did
use `decapped_head` unchanged, and it read as a decap rather than as debris.)

It is created **before** the jump because `r_shocker_pop` never returns, and it
reads `a8` — the body — for the x to fall onto, which is still valid because
the pop only makes that object inviso; it does not delete or move it.

### Two traps in placing and moving it

**Place it in `oxval`/`oyval`, not `oxpos`/`oypos`.** `oxval` is the master
16.16 position with the integer in the high word, and the display derives
`oxpos` from it every pass, so an `oxpos` write is thrown away before the next
draw ([[reference_mk2_oxval_vs_oxpos]]). Writing the base *absolutely* is
correct here and only here: the object is brand new and no anipoint delta has
been applied to it yet.

**`gravity_ani` does not move this object, so the fall is integrated by
hand.** `gravity_ani` only *accumulates* `oyvel`; something else is supposed to
add `oyvel` into `oyval` once a frame, and that something is `dclipl`
(MKDISP.ASM), which does it only when its `b0` says to. Measured on this head:

| tick | `oyvel` | `oyval` |
|---|---|---|
| 128 | 327680 | −68 |
| 144 | 851968 | −68 |
| 168 | 1638400 | −68 |

— velocity climbing exactly as asked, position never moving, the head hanging
above the frame jittering on its own anipoint deltas. `decapped_head`'s head
*does* get moved, from the same list and the same `gso_dmawnz`, so whatever
gates `dclipl` is not something this routine can see or set.

So `ermtkf_head_fall` integrates `oyval`/`oxval` itself, and **zeroes `oyvel`
and `oxvel`** so that if `dclipl` ever does service this object it adds zero
rather than doubling everything. The velocities live in `p_store5`/`p_store6`
— process storage survives a sleep unconditionally, where only `a7`-`a12` do
among registers. The loop exits on HEIGHT (`oypos + osizey >= p_ganiy`, what
`hit_ground_yet` tests), not on a tick count, so retuning any constant cannot
leave the head hanging or sunk through the floor.

### What was tried first, and why it is not used

There is a third pop entry, `r_raiden_superp`, which is `r_shocker_pop` with
`p_downcount` set to 1; the shared tail reads that flag and is supposed to drop
the victim's head in `0a0h` ticks. It is the obvious answer and it does not
work from here. **Measured, not assumed:**

| what was checked | result |
|---|---|
| `p_downcount` on the victim's process | 1, and stays 1 |
| does the victim's process take the head branch? | yes — its wake sits inside `head_grav` for the rest of the round |
| is a head object ever created? | **no** — a walk of `objlst`/`objlst2`/`objlst3` shows 27 objects before the pop and 27 after: 25 chunks and two fighters, nothing carrying the victim's `ochar`, nothing at the head's z |
| is it arriving after something culls it? | no — shortening that `0a0h` sleep to `010h` changes nothing |

So the `head_grav` loop is driving an object that was never inserted. What
breaks between `gso_dmawnz` and `insobja8` in that tail is a retail-code
question worth answering on its own — it presumably makes `do_raiden_punch`'s
superpunch fatality, the only other caller, headless too — but it is not this
fatality's to solve, and `decapped_head` reaches the same place through the
path this build actually exercises.

### Verified

The rig's `head=` field is two separate checks, because they fail apart: an
object carrying the victim's `ochar` (no `exp_burst` chunk does — only the
head copies it from the body), and that object's `y` actually changing. A head
that is built and then never driven looks identical to a working one in a
single sample, and that is exactly the failure both earlier attempts had.

Measured on Jax, ticks from `f_death` reaching 2:

| t | head y | |
|---|---|---|
| 122 | −72 | spawns above the top of the frame |
| 128 | −51 | |
| 136 | −3 | accelerating |
| 144 | 68 | |
| 152 | 165 | |
| 160 | 187 | lands |
| 168 | 175 | **bounces** |
| 176 | 188 | |
| 184 | 205 | second bounce |
| settle 0–300 | 205 | at rest, unmoving for the whole settle window |

Confirmed by screenshot mid-fall, among the chunks.

**The windup art.** UMK3 raises `ANIM_SCORP_SUMMON`. Ours raises
`a_ermac_teleslam` — `ermac_anitab2` row 9, the ERTELESLAM1-3 poses the
special already uses, at the special's own rate. Ermac's own arm, not a
borrowed one, and **no new art of any kind**: no LOD, no IMG, no TBL, no
video-ROM slot. The victim's half runs on his own `anitab1` knockdown and
stumble rows, which every character has.

**The impact shake count.** UMK3 passes `shake_a11(8,5)`. An odd count leaves
the camera permanently displaced (`shake_a11`, MKFX.ASM), and this move fires
four of them back to back under a `scroll_center` that never re-clamps y, so
it is rounded up to 6.

**The screaming.** UMK3's `death_slam_pause` screams on every one of the four
impacts. MK2's `rsnd_death_voice` is a long wail, not a grunt, and four
overlap into noise — so it plays once at the top, the way every stock MK2
victim reaction opens, and the beats carry `rsnd_ground` + `rsnd_react_voice`
(which is what UMK3's own `group_sound(2)` is inside `pose_stumble_frame_1`).

## The range band

`q_ermac_fatal` is `q_fatal_dist(0x60,0xc0)` — a BAND, not a ceiling. The
arcade refuses this fatality point blank as well as from across the stage,
which is the flavour of a move that lifts a man without touching him. MK2's
shared `fatality_xfer_close` only enforces the ceiling, so the floor is tested
in `ermac_block` before the jump. `0x60` is MK2's own sweep distance — the
number `do_st_decap` uses — so both engines agree about where "not point
blank" starts.

## Where it lives

| piece | file |
|---|---|
| constants, kill switch (`ermac_fatal_slam_enable`) | `src/MAINEQU.ASM` |
| input: `ermac_block`, `scom_ermac_fatal` | `src/MOVES.ASM` |
| attacker: `do_ermac_fatal_slam` | `src/MKDEATH.ASM` |
| victim: `r_ermac_fatal_slam`, `ermtkf_beat` | `src/MKREACT.ASM` |

`char_block[17]` used to point straight at `check_nj_dtp`. It now points at
`ermac_block`, which checks the slam first and hands every miss to
`check_nj_dtp` — so Ermac keeps the ninja pit fatality (Down, Forward,
Forward + BLOCK) he shares with Scorpion, Reptile and Smoke. Neither pattern
is a prefix or a suffix of the other.

**`ermac_block` sits BELOW `check_nj_dtp`, and that is load-bearing.** The
first version of this put it above, in the gap between `rp_block` and
`check_nj_dtp` — and `check_nj_dtp` is reached by FALL-THROUGH from
`rp_block` (Reptile's block is `slide_check`, then the shared pit fatality).
That put Ermac's fatality check in *Reptile's* path: during Finish Him,
Reptile would have matched `D,U,D,D,D + BLOCK` and run
`do_ermac_fatal_slam`, whose windup is `ermac_anitab2` row 9 — a row
Reptile's own TABLE2 uses for something else. It assembled, it passed every
Ermac test, and neither the pit regression nor the stability sweep would have
caught it, because neither throws that input as Reptile. Nothing falls into
`ermac_block` now; its only exit to the pit route is an explicit jump.

`-Reptile` is the regression that locks this in, and it was **verified to
fail before it was trusted**: the bug was temporarily put back, the ROM
rebuilt, and the rig reported
`FAIL ermac_fatal_slam_not_reptile: REPTILE reached a fatality (f_death=2)
off D,U,D,D,D + BLOCK`. A negative control nobody has seen fail is not
evidence of anything. The button masks leave BLOCK out
(`f1b2` is block — `button_mask`) because block is the trigger and is
necessarily held at the moment the handler runs.

The four beats are UNROLLED, as UMK3 unrolls them, and for a harder reason
here: a beat sleeps, and only `a7`-`a12` survive a sleep. `a8` is the victim,
`a9` the animation cursor, `a10` and `a11` are both clobbered inside the beat
(`find_last_frame`, `shake_a11`), `a12`/`a13` are the process. There is no
register left to count in, and a counter that died mid-loop would walk the
knockdown table past its terminator. The fall itself needs no counter — it
ends on HEIGHT (`oypos >= p_ganiy`), so retuning any constant cannot leave the
victim falling through the floor or stopping short of it.

## Verified on screen

```
tools/run_ermac_fatal_slam_test.ps1 [-Dist n] [-Side left|right] [-Pit]
```

The rig welds two existing ones together: `ermac_teleslam_test.lua`'s select
cheat (Ermac is hidden, and hidden fighters cannot be forced — only the cheat
reaches him) and `st_decap_fatality_test.lua`'s forced Finish Him. The INPUT
is not faked: it goes through the real joystick queue, `ermac_block`,
`combo_look_lr` and `fatality_xfer_close`.

```
PASS ermac_fatal_slam: fired=true slams=4 lift=208px popped=true ended=true settled=true head=true(path=true,fell=true) attempts=1
```

| run | result |
|---|---|
| `-Dist 100` / `130` / `185` (inside the band) | PASS, 4 slams, 208px peak, every time on attempt 1 |
| `-Dist 40` (inside the near edge) | 17 attempts, never fires, `p1act` stays `0x303` — no crash, he just blocks |
| `-Dist 230` (past the far edge) | 17 attempts, never fires |
| `-Side right` (mirrored) | PASS, identical numbers |
| `-Pit` (fall-through regression) | `PASS ermac_block_fallthrough: pit fatality fired (f_death=6)` |
| `-Reptile` (the handler must NOT be in Reptile's path) | `PASS ermac_fatal_slam_not_reptile: 8 attempts, f_death never left 0 (p1_ochar=9)` |
| `tools/run_ermac_teleslam_test.ps1` (the special) | PASS, unchanged — `lift=208px damage=9` |

The measured timeline, ticks from `f_death` reaching 2:

| t | what |
|---|---|
| 0 | `init_death_blow`; windup already played (8 ticks at rate 2) |
| 0–16 | shake-up, dy 0 → ~32 with the ±3 jitter |
| 24–43 | first hurl to dy 144+, then the fall |
| 44, 65, 86, 107 | the four impacts — a 21-tick beat, dead even |
| peak | dy 208px, i.e. off the top of a 254px screen |
| 112 | `m_inviso` set: the body is chunks |
| 186 | `f_death` → −1, `death_blow_complete` ran exactly once |

The 74 ticks between the pop and completion are `erm_tksf_hold` (`0xa0`,
UMK3's own number) outlasting the sequence on purpose: Ermac holds the grip
through the chunk shower and only then lowers his arm, which is the release.
Long is safe here and short is not — `death_blow_complete` must not fire while
the body is still in the air.

---

# Ermac's babality

Shipped 2026-09-08, alongside the fatality. **Down, Back, Back + LOW KICK.**

Nothing about it is a port — it is MK2's own babality, which Ermac was one
table row and one guard away from already having.

## What was actually missing

`baby_images` already carried his row (`RPBABE`, Reptile's baby in `REP_P`)
because that table is indexed by the **victim**, and Ermac has been a legal
babality victim since he shipped. Only the performer side was missing:

| piece | state before | now |
|---|---|---|
| `ochar_baby_combos` (MKBABY.ASM) | 12 rows, 0–11 | 19 rows, 0–18; row 17 = `scom_nj_baby` |
| `bb_check`'s guard | `cmpi 12,ochar / jrhs bbno` | bounded at `ft_kham`, then **a zero row is the refusal** |
| `char_lo_kick[17]` (MOVES.ASM) | `sucide` — LK did nothing | `ermac_lo_kick` |

## Why the guard changed shape

The old `cmpi 12` existed only because the table stopped at row 11 and a
`get_char_long` past the end would have handed `combo_look_lr` a garbage
pointer. Relaxing it to "12..16 no, 17 yes, 18 no" would have meant a second
magic number to keep in step with a third table. Instead the table runs full
length with an explicit `0` in every row that has no babality, and `bb_check`
reads that zero as the refusal — so adding or removing a babality is a table
edit and cannot leave a stale `ochar` number behind in the routine.

`ochar_baby_combos` was in `audit_char_tables.py`'s `GATED_SAFE` exemption
list precisely *because* of that old guard. It has been removed from the list:
the table is now the thing that decides, so it has to be full length like
every other one, and the audit enforces that.

## Why LOW KICK

The **button is not in the combo table** — it is whichever handler calls
`bb_check`. That is why the three ninjas share `scom_nj_baby` while Sub-Zero
and Scorpion answer on HK (`szhk3`, `schk_normal`) and Reptile answers on LK
(`rp_lo_kick`). Ermac answers on LK for two reasons: it was his one free
button (HK is the telekinetic slam, BLOCK carries both his fatalities), and
Reptile — the character he clones — answers there too.

`ermac_lo_kick` is `calla bb_check` / `jruc death` and nothing else. It does
**not** enter at `rp_lo_kick`, which leads with `slide_check`, and the slide is
Reptile's move. It does **not** call `fs_check`: friendship needs
`ochar_friendship_combos` and `friendship_jumps` rows plus a per-character
sequence to jump to, Ermac has none of the three, and `fs_check`'s own
`ochar >= 12` guard would refuse him anyway — calling it would only look like
he had one.

## The CPU still cannot do it

`drone_finish_him` (MKDRONE.ASM) keeps its own `cmpi 12` gate, and it must:
that one test covers four tables, and `db1_table`, `db2_table` and
`friendship_jumps` are all still twelve rows. A CPU Ermac finishes with an
uppercut. The comment there has been corrected — it used to name
`ochar_baby_combos` as one of the twelve-row tables.

## Verified on screen

```
tools/run_ermac_babality_test.ps1 [-As ermac|jade|reptile]
```

```
PASS babality_ermac:   started=true swapped=true ended=true attempts=1
PASS babality_reptile: started=true swapped=true ended=true attempts=1
PASS babality_refused_jade: 8 attempts of D,B,B + LK as ochar 16, f_death never left 0
```

The rig watches the game's own three-stage handshake rather than the picture:
`f_death` → `bb_fatality` (5) means the combo matched and the row was
non-zero; `f_death2` → 1 means `baby_xfer` got through `gso_dmawnz` and the
baby is drawn; `f_death` → −1 means `death_blow_complete` ran. Measured for
Ermac: started 43 ticks after the input begins, swapped and completed at
t=192, which is `delayed_baby_start`'s own `030h + 090h`. Confirmed by
screenshot — baby Jax on the floor, Ermac in his victory pose.

Two of the three modes are controls, and each covers a half of the change the
Ermac run does not:

- **`-As reptile`** — `bb_check` was rewritten for *everyone*, so a fighter
  who has always had a babality must still have one. Reptile is the right one
  to ask: same `scom_nj_baby`, same LK button, and he is who Ermac clones.
- **`-As jade`** — Ermac's row is non-zero, so his pass says nothing about
  whether the **zero** rows still refuse. Jade (16) is the one zero-row
  fighter a player can reach and she calls `bb_check` from `jade_lk_normal`.
  **Verified to fail before it was trusted**: row 16 was temporarily set to
  `scom_nj_baby`, the ROM rebuilt, and the rig reported
  `FAIL babality_refused_jade: ochar 16 reached a finisher (f_death=5)`.

---

# The three splats

Added 2026-09-10 by request: in the UMK3 ROM, when the opponent explodes at
the end of this fatality there are **three blood splats**. They are now
UMK3's own art, imported from the arcade ROM.

## Where the three comes from

UMK3's `ermac_super_slam` ends in `create_fx(FX_SWAT_BEXP)`, which is
`swat_bomb_explode` (MKFX.C), whose last line is `stand_blood_explode`:

```c
void cbx3(void)
{
	CREATE(PID_BLOOD,blood_explode);
	current_proc->a10+=0x00180000;
	CREATE(PID_BLOOD,blood_explode);
	current_proc->a10+=0x00180000;
	CREATE(PID_BLOOD,blood_explode);
	process_suicide();
}
```

Exactly three, stepping `a10` by `0x00180000`. `a10` is `[Y:X]`, which the
arcade applies as `oxpos += a10 & 0xffff` / `oypos += a10 >> 16`, so all three
sit at the victim's own x, **24px apart**. MK2 packs a blood offset the same
way and has the same helper, `lineup_with_a11_offset`, so the constant ports
across untouched instead of being re-measured. 0 / +24 / +48 walks the splats
**down the torso from the head**.

## The art: `BLDXPD1-13`, straight out of the UMK3 ROM

`tools/make_bldxpd_img.py` decodes UMK3's `a_blood_explode` lane and writes
`data/BLDXPD.IMG`. Nothing is redrawn. The tool's header has the full
derivation. In short:

- **Found by content, two ways that agree.** UMK3 binds this art at run time,
  so its animation tables do not point at it. MK3's `MKFX2.TBL` gives
  `BLDXPD1A` as `.word 28,47,28,24`. That sequence occurs once in the UMK3
  program ROM, at `0xAEEFA`, and the 26 records after it match MK3's table
  size for size and anipoint for anipoint. The first record's palette pointer
  resolves to `0xB791A`, where MK3's `BLDXPD_P` words sit, all 14 of them.
- **13 frames, each a left and right half, composited.** The arcade draws
  each frame as two pieces (`nA` anchored at its right edge, `nB` at its
  left). MK2's blood routines are single-object, so each pair is painted A
  then B about the shared anchor. B goes last because it is on top in the
  arcade, which matters where BLDXPD8-11 overlap by two columns. The frames
  bloom from 56x47 to 228x168 and then thin out to specks.
- **4bpp, not 6.** Every frame tops out at colour 13 of a 14-entry palette,
  so the art repacks losslessly at a third of the arcade's depth. The palette
  is padded to 16 above the colours in use.
- `--verify` rebuilds and diffs against the ROM (identical). `--check` runs
  in Phase D.

| piece | where |
|---|---|
| art + palette | `data/BLDXPD.IMG`, generated by `tools/make_bldxpd_img.py` |
| video-ROM slot | `data/BLDXPD.LOD`: bank 1, `0xBCD600..0xBDD600` (IRW 63,264 bytes) |
| palette in ROM | `src/IMGPAL6.ASM` (`BLDXPD_P`, hand-added, 16 words) |
| records | `src/BLDXPD.TBL`, promoted by `promote_tbls.py` |
| lane + routine | `a_blood_splash`, `ermac_splash_blood`, `ermac_splat_one` (MKBLOOD.ASM) |
| trigger | `r_ermac_fatal_slam` (MKREACT.ASM), beside the head create |

The lane plays the arcade's rate, 5 ticks a frame (65 ticks), once, and
`blood_death` deletes the object at the end. The splat is a standalone
`gso_dmawnz` object, so the LOD is `PON>` and `gso_dmawnz` binds `BLDXPD_P`
from the header's `icmap`. There is no `swpal` and no `char_blood_pal`: the
arcade's blood is the arcade's red on every victim. Bank 1 is fine because
only body frames need bank 0 (`shadow_p1p2`'s CPU read has no bank select),
and blood casts no shadow.

The procs go through `create_blood_proc` (slot `017h`), not a bare `create`.
That tests `f_no_blood` and the `MAX_BLOOD` cap. Nothing dereferences the `a0`
that `create` returns: at the cap it is **NULL**. It does not need to, because
`xferprc0` (MPROC.ASM) copies `a7`-`a12` into the child.

(An interim version used `MKSPLASH1-4` from `data/BLOOD.IMG` in a `BLDSPLSH`
sidecar. That sidecar and its table were removed when the arcade art went in.)

## The wedge the arcade art exposed: `delete_offscreen`

With the UMK3 frames in, the fatality locked up at t~171, parked in
`recovery: jauc $` (MKBUG.ASM). The cause is retail code.

`r_shocker_pop` starts `kiss_explode`, and its tail, `delete_offscreen`
(MKDIE.ASM), runs **for the rest of the round**. Every tick it walks all of
`objlst` and `delobjp`s any object whose `oxpos`/`oypos` (the top-left
corner, not the anchor) is off screen. The only exemption was `oid_bones`,
which the chunks give themselves in `explode_piece`. The top splat's 168px
frames lift its corner above the screen top, so `delete_offscreen` freed it
while its process was still animating it. When the lane ended, that
process's own `blood_death` released the palette a second time, and
`freepal` hit its "negative palette count" `lockup`. The smaller MKSPLASH
frames never crossed the top, which is why the same code looked fine before.

**Fix:** the splats tag themselves `oid_blood`, the falling head tags itself
`oid_head` (it starts above the screen, so it was exposed too), and `kexp9`
skips both ids. No retail `objlst` object carries either id, so the retail
fatalities that run `delete_offscreen` are unchanged. `oid_blood`'s only other
user is the FATALITY word, which lives on `objlst2`.

How it was pinned, for next time: `run_ermac_fatal_slam_test.ps1 -Trace` runs
MAME with `-debug` and a generated `-debugscript`. `system_lockup` leaves its
caller in **B14**, which read `freepal`. A write watchpoint on the palette's
`palcnt` word showed the count going 3 -> 2 from a process that was not a
splat's, followed by three splat releases. The history behind the first one
was `delete_offscreen`.

## Verified

The rig counts the **maximum simultaneous** splash objects, found by SAG
window from `src/BLDXPD.TBL`, and requires the fatality to finish
(`f_death` -> -1).

```
PASS ermac_fatal_slam: fired=true slams=4 lift=208px popped=true ended=true settled=true head=true(path=true,fell=true) splash=3 attempts=1
        splashes: max 3 simultaneous, y=53,77,101
ENDED at t=186 (f_death -1: death_blow_complete ran)
```

Three, at **24px spacing**, the arcade's `0x00180000` exactly, arriving at
t=110 with the burst. The head still falls out of the sky, lands at y=187,
bounces to 175 and rests at 205.
