# What's new in this MK2 — moves, finishers and secrets

For **REVISION 4.0-BETA**. Everything below was read out of the source in this
tree, not out of a wiki, so it describes what the ROM actually does. Anything
the arcade already did is only listed here when we *changed* it.

**Notation.** `F` = toward your opponent, `B` = away from them, `U`/`D` =
up/down. `HP` `LP` `HK` `LK` `BL` are the six buttons. `F,B + HP` means do the
stick motion, then press the button. Distances are in pixels; a sweep lands at
roughly 90-100, so "≤96" is about sweep range.

---

## 1. Hidden fighters

| Fighter | How to get them |
|---|---|
| **Jade** | Put your cursor on **Mileena** and press **Low Kick 5 times**. The screen confirms as Mileena — Jade is swapped in on the VS screen. |
| **Ermac** | Put your cursor on **Reptile** and press **Block 5 times**. The first four are swallowed; the fifth confirms Reptile and Ermac is swapped in. |

**Smoke and Noob Saibot are no longer selectable.** Their Block-x5 unlocks were
turned off (`smoke_select_enable` / `noob_select_enable` in `src/MAINEQU.ASM`,
both `0`), so Block on Scorpion or Sub-Zero is an ordinary confirm and picks
that fighter. They still exist as fighters — Smoke's classic Pit appearance and
the CPU ladder are unaffected — you just cannot choose them.

Block on any other fighter is still an ordinary confirm, so nothing about
normal selection changed.

**Fight Shao Kahn right now:** in a **one-player game only**, press **Start 5
times** on the character-select screen. Your next opponent is the final boss.
(Two players on the select screen disables it.)

### What the secret fighters actually get

They borrow their normals from the character they share a strike table with —
Smoke and Noob use the ninja tables, Jade uses the female-ninja tables — so
their punches, kicks and reach are identical to those characters.

- **Noob Saibot** has six specials of his own (below) — still there when the
  CPU plays him.
- **Jade** has six specials of her own. She does **not** get any of Kitana's or
  Mileena's moves.
- **Smoke** has **no specials at all**. He is a pure normals character.
- **None of the three have a fatality, babality or stage fatality.** That is
  deliberate, not an oversight.
- **Ermac is the exception.** He is a full fighter, not a palette: his own
  specials (fireball, teleport punch, telekinetic slam), the ninja pit
  fatality, and as of this build a fatality **and a babality** of his own —
  see §5.

Two things that used to be free are now gated (see §7): a **human** playing
Smoke/Noob/Jade takes normal damage and walks at normal speed. The **CPU**
playing them keeps the boss-tier 3/4 damage and the fast walk, because a secret
opponent is supposed to be hard.

---

## 2. Alternate costumes

On the character-select screen, **hold Start plus one other button** while you
confirm. Each gives a different palette, and each player can claim one.

| Hold | Costume set |
|---|---|
| Start + **Low Punch** | palette 2 (the classic "player 2" colours) |
| Start + **Block** | palette 3 — includes **black Sub-Zero**, purple Kung Lao, alt Baraka |
| Start + **High Punch** | palette 4 — black Kung Lao, movie-Shang, alt Raiden |
| Start + **High Kick** | palette 5 — green Kung Lao, **grey Scorpion**, alt Kitana |
| Start + **Low Kick** | palette 6 — **Kitana in Jade green**, MK1-original Scorpion |
| Start + **Coin** | palette 7 — **dark Raiden**, alt Reptile/Scorpion/Baraka/Mileena |

Only one manual alternate per player at a time; the mirror-match auto-recolour
still happens on top of this as normal.

---

## 3. Stage select, new arenas, and Pong

### You now pick the arena

After the character select, the **VS screen lets you choose the stage**. Push
**left/right** to cycle; **any button** confirms. You have about **two
seconds** — if nobody picks, whatever arena is showing is the one you get.

Thirteen arenas are in the cycle:

The Dead Pool · Kombat Tomb · Wasteland · The Tower · Living Forest ·
The Armory · The Pit II · The Portal · Kahn's Arena · Goro's Lair ·
**The Pit Bottom** · **Outer Haven** · **Yoteigai Tor**

The last three are new. Yoteigai Tor (the mountain top) has weather — it does
**not** always rain, and when it does the storm and the drops run on their own
random rolls, so no two visits look the same.

A fourteenth arena, **Waffle House**, is built and playable but no longer
appears in the cycle — see below.

### Waffle House (secret arena)

Waffle House is off the cycle and off the one-player ladder; the only way onto
it is a code. On the VS screen, leave the arena on **The Dead Pool** (where it
starts) and let the two-second timer run out with **both players holding
Down**. The panel repaints as WAFFLE HOUSE and the match is fought there.

It lasts for that match only — when the match ends, the stage rotation picks
up again at The Dead Pool.

### Pong

Two ways in:

1. **The old way** — reach battle 250. The VS screen calls it "BACK IN TIME".
2. **The new secret** — on the VS screen, cycle to **Outer Haven**, then let
   the two-second timer run out with **both players holding Up**. Pong starts
   immediately, and you drop back into Outer Haven afterwards.

### Stage fatalities

Unchanged from the arcade: **The Pit II** (uppercut down the pit) and **Kombat
Tomb** (up onto the spikes) only. The new stages have none.

---

## 4. New and changed special moves

### Moves that changed input

| Character | Move | Was | **Now** |
|---|---|---|---|
| Baraka | Blade spin / heliport | U,U + HP | **U,U + LK** |
| Shang Tsung | Soul drain fatality | F,D,F + LK | **U,D,U + LK** (F,D,F + LK is now the backflip decap) |
| Scorpion | MK1 scortch fatality | U,U + HP inside a narrow range band | **bare HP** during Finish Him |
| Shang Tsung | Inner-explosion fatality | hold HK about 1 second and release | **hold HK 3 seconds** and release, 80px or farther |
| Johnny Cage | Green force ball | a low ball and a separate high ball | **one ball** - the low ball, steered up or down on the stick while it flies |

Cage's **high force ball is gone**. It only existed because the ball flew a
fixed arc: one version for jumpers, one for the ground. The ball now takes
the stick in flight - hold Up or Down while it travels and it climbs or dips
- so the high arc was a second input for something the one ball already does.
The CPU throws the same one ball you do - it just cannot steer it, because it
has no stick. Aiming the ball is a player's edge now.

### Shang Tsung can drop a morph on purpose

**Block + Up + High Kick**, held together, turns Shang back into himself from
any of his eleven forms, at any moment.

Retail gave you no way out. Once you morphed you wore that fighter until the
9-second timer expired or the round ended, so a morph you picked for one
exchange cost you the next three — and a read that went wrong was simply a
read you had to live with. The morph is a commitment now, not a sentence: take
Kung Lao's spin for the anti-air, drop it, take Scorpion's spear for the
knockdown.

Block is part of the input for a reason: holding it stops Up from becoming a
jump, so the gesture works from a standing guard and cannot come out by
accident during a motion. It works during **FINISH HIM** too — reverting to
Shang there is how you reach Shang's own fatalities out of a morph, if you
have the time for it.

### Back + High Punch specials

Six characters gained a distinct **hold Back + HP** attack. All six require you
to be **standing** — crouching still gives you the uppercut, and down + HP
always gives the uppercut.

| Character | Back + HP |
|---|---|
| Kung Lao | Backfist |
| Liu Kang | Backfist |
| Johnny Cage | Power punch - a shadow move now: the shadow-kick sound and a five-image green afterimage (`B,B + HP` is still the shadow uppercut) |
| Jax | Power punch |
| Shang Tsung | Round punch |
| Raiden | Short-range lightning |

Baraka's and Kitana's existing Back+HP moves are unchanged, and now follow the
same standing-only rule.

### Air versions of ground specials

Four projectiles can now be thrown **while jumping**, with a proper airborne
pose instead of being yanked down to the floor:

| Character | Move | Input |
|---|---|---|
| Sub-Zero | Air ice ball | D,F + LP in the air |
| Jax | Air lightwave | F,D,B + HK in the air |
| Reptile | Air acid spit | F,F + HP in the air |
| Reptile | Dive kick | Down + HK in the air, above ~160px |
| Noob Saibot | Shadow dive kick | D,B + LK in the air, above ~160px |

Sub-Zero's freeze has a real rule now: **one freeze per airborne state**. Once
you freeze someone in the air you cannot freeze them again until they land —
landing resets it instantly. On the ground there is a short (~1.6s) cooldown
between freezes.

### Brand new moves

| Character | Move | Input | What it does |
|---|---|---|---|
| **Sub-Zero** | Ice tornado | **D,B + LP** | A cut Midway move, finished. An ice whirlwind travels toward the opponent and freezes on contact. ~2.3s cooldown. |
| **Johnny Cage** | Ceiling uppercut | **F,F,B + HP** | Rockets off the top of the screen at 65°, comes back down next to the opponent rising with an uppercut. Whiffing it is punishable. |
| **Baraka** | Scissor leg grab | **hold D + LP + BL** | Sonya's MK3 leg throw, rebuilt on Baraka's unused sword-kick art. He plants a blade in the floor, handstands on it, and scissors his legs shut. It is a **grab**, not a kick — it takes the victim over rather than trading with him. |
| **Kitana** | Overhead spin chop | **hold BL, then F,F** | One rotation with the chop swinging above her head. The hitbox is high and live only on the frame the chop lands. |
| **Reptile** | Fast forceball | **F,F + HP+LP** | Same forceball, much faster. The two punches must land within 4 ticks of each other. Still only one orb on screen at a time. |
| **Reptile** | Dive kick | **Down + HK in the air** | A cut Midway move, restored. The engine routine is called `do_reptile_superk` and the strike record Kung Lao's dive uses is called `stk_super_rep` - it was Reptile's, and the shipped game only ever gave it to Kung Lao. Same arc as Kung Lao's: shallow at first, then steepening. Needs about 160px of height, so it comes out near the apex of a jump; below that you just get a normal air kick. **He leaves an afterimage behind** - a copy of him frozen in the kick's opening pose, parked where he launched, flashing out as he lands. Scorpion's teleport decoy, aimed at the dive. It does not appear while he is invisible. Kung Lao's dive does not get one. |
| **Kung Lao / Liu Kang** | Backfist | **B + HP** | See above. |

### Noob Saibot's move list

The rule for all of them: **Noob never moves.** He casts, and a detached shadow
does the travelling.

| Move | Input | Notes |
|---|---|---|
| Shadow slide | **D,B + LK** | The shadow skims the floor forward while Noob holds a pose. It strikes **once**, then keeps going past the victim off the screen. Pops the victim straight up with no knockback. |
| Shadow dive kick | **D,B + LK in the air** | Noob hangs where he cast it; the shadow dives. Needs about 160px of height or you just get a normal air kick. |
| Shadow kick | **D,B + HK** | Launches at 45°, climbs, then vanishes. A short hop, not a full-screen shot. Catches airborne victims exactly like a jump kick. |
| Shadow portal | **D,D + LK** | A vortex opens in the floor **under and behind** the opponent; he falls in and drops out of the air behind Noob. It is a projectile — it can be **blocked**, and **jumping over it** beats it outright. Refused while another shadow is still alive. |
| Shadow teleport | **D,U** (no button) | Comes out in uppercut range. |
| Slide | **hold Away + LP + BL + LK** | Sub-Zero's real slide, on Sub-Zero's real input. |

### Jade's move list

| Move | Input | Notes |
|---|---|---|
| Boomerang, straight | **B,F + LP** | |
| Boomerang, upward arc | **B,F + HP** | Leaves her hand level and climbs. |
| Boomerang, downward arc | **B,F + LK** | |
| Returning boomerang | **B,B,F + LP** | Comes back at her if it misses; a hit consumes it. Tested before the straight throw, so the longer motion always wins its own press. |
| Jade Flash | **B,F + HK** | Projectile immunity with **free movement** — you keep walking. ~2.3s recharge. |
| Blazing Nitro Kick | **D,F + LK** | UMK3 timing with heavy ninja smoke on the windup. Crouch-duckable. |

The four boomerang trajectories are rebuilt on the arcade UMK3 data (9px per
tick, 7-frame spin loop, UMK3 hitbox and damage), and the blade drags a fading
shadow trail behind it.

---

## 5. New fatalities

All of these fire during **FINISH HIM/HER**, and every one has a distance gate.

| Character | Fatality | Input | Range |
|---|---|---|---|
| **Sub-Zero** | MK1 head rip | **F,D,F + LP** | ≤128px. Tested before the ice ball, because `D,F` is the tail of this motion. The head that comes off matches the victim. |
| **Johnny Cage** | Head hole / brain rip | **F,B,B + HP** | ≤96px |
| **Shang Tsung** | Old Shang decapitation | **B,B,F,U + LP** | ≤96px. He morphs into the old man, laughs, and takes the head. |
| **Shang Tsung** | Stationary backflip decap | **F,D,F + LK** | ≤80px. This replaced the soul drain on that input. |
| **Shang Tsung** | Soul drain + corpse drop | **U,D,U + LK** | ≤82px |
| **Scorpion** | MK1 scortch | **bare HP** | Any HP press during Finish Him that is not `D,B` (teleport punch) or `D,D,U,U` (the stock burn). **No range window at all** — this is the fix for how awkward the old one was to land. |
| **Ermac** | Telekinetic slam | **D,U,D,D,D + BLOCK** | 96–192px — a **band**, not a ceiling. Point blank does not work either, which is the arcade's own gate (UMK3 `q_fatal_dist(0x60,0xc0)`). He never touches you: you are lifted, thrown off the top of the screen four times, and what lands the fourth time explodes in three splats of blood. The head comes back down out of the sky a moment later, bounces off the floor and rolls to a stop. |

**Ermac also has a babality: Down, Back, Back + Low Kick.** It is the same
input Sub-Zero, Reptile and Scorpion use — only the button differs, and it
already differs between them (Sub-Zero and Scorpion answer on High Kick,
Reptile on Low Kick). The usual babality rule applies to him as it does to
everyone: **no High Punch or Low Punch anywhere in the final round**, or it is
refused. He is the first fighter outside the original twelve to get one; Smoke,
Noob, Jade and Khameleon still have none, and a CPU-controlled Ermac finishes
with an uppercut rather than a babality.

**Raiden's two added fatalities are off.** The bolt torso split (`U,U,F + HP`)
and the lift-and-electrocute (`F,F,F + LK`) are disabled
(`raiden_bolt_decap_enable` / `raiden_lift_fatal_enable` in `src/MAINEQU.ASM`,
both `0`); those inputs do his ordinary high punch and low kick again. Raiden
keeps his two stock MK2 fatalities.

Scorpion's other two burns are untouched and still win their own inputs:
`D,D,U,U + HP` is the stock MK2 burn with the guaranteed **TOASTY**, and
`D,B + HP` is still the teleport punch.

Shang's Kintaro morph is unchanged: **hold LP for 15+ seconds**, release during
Finish Him between 80 and 120px.

**Not in this build:** Scorpion's third burn (the UMK3 flame column,
`D,U,U,U + HK`) is fully written but its input is switched off — the art does
not fit in the video ROM yet.

### Shao Kahn's finishers

Shao Kahn has no FINISH HIM window of his own, so his two finishers are
ordinary hits that land mid-fight:

- **Portal Punch** — round 3 only, far range only. A giant arm falls out of the
  top of the screen band by band and pulps you. Blocking squeezes you out of it.
- **Hammer smash** — round 2 or later, and only if that swing takes you to
  zero, so **chip damage can finish the job**. He then replays your own pit-fall
  animation in place.

He also picked up a real move set as an opponent: a sonic clap that **deflects
projectiles back at you**, a UMK3-accurate flying knee and overhead hammer, and
a grab that now needs an actual strike to connect. He is a much harder fight.

---

## 6. Recovered and rebuilt content

Things that were cut, broken or missing from the leak and now work:

- **Sub-Zero's ice tornado** — art and palette were in the data, never wired.
- **Shang Tsung's backflip and round punch** — cut sprites, restored.
- **Baraka's sword-kick art** — repurposed into the leg grab.
- **Kung Lao's and Liu Kang's backfists.**
- **The Pit Bottom** — MK1's arena, including fighter shadows and the spike row.
- **Blood stopped working** after about a minute of play in the leak's code.
  Fixed; the effects run all match now.
- **Kahn's power-up glow, his sonic-clap trail, and his stand-up on FINISH HIM.**
- **Raiden's victory pose** no longer flickers with stray dots and specks.
- Projectiles still in the air when a round ends no longer stun **the winner**
  out of their victory animation.
- Specials no longer soft-lock the game during FINISH HIM.
- **Dead Pool's corner skeletons** are shown from the start of the round.
- A palette-pool bug that could turn *any* sprite on *any* stage into magenta
  and green static — most often during FINISH HIM, when blood and effects were
  competing for slots.

---

## 7. How the game plays differently

Every one of these is a deliberate call, with the reasoning written up in
[DEVIATIONS.md](DEVIATIONS.md).

**Two-button moves are easier.** Kitana's fan throw and Reptile's forceball need
two buttons "at once". The arcade gave you 2 ticks (37 ms) and demanded the
partner press be the *immediately* previous input. That window is now 4 ticks
(73 ms) and tolerates a stray input in between. Measured: 0-2 ticks of
separation worked before, 0-4 works now.

**The hit column is anchored properly.** Whether a move connected used to depend
partly on which frame the *victim* happened to be showing, because the collision
column travelled with his own arms. It is anchored to his position now, so
spacing is stable.

**...and it is the right width again.** Anchoring the column also shrank it, by
1-5 px depending on the pose - 87% of poses were affected and none got wider.
That was never intended and it made everyone slightly harder to hit. Corrected,
so the column is the width it was always documented as being.

**Damage scales in a combo.** The first hit of a string does full damage, then
3/4, then 1/2, then 1/4 for the fourth and beyond. A real hit never scales to
nothing. Arcade MK2 had no scaling at all, which is why a five-hit string could
take 62% of a life bar; the same string now takes 34%. It resets when you land
or block, so it is a juggle limiter rather than a round-long tax.

**Holding away blocks.** The block button still works exactly as it did, and now
holding the stick away from your opponent guards as well. Away-and-down guards
low. It is *proximity* block - you keep walking backwards until something
actually reaches you, and then you guard it - so retreating is unchanged.

**Sloppy motions come out.** The arcade demanded that every step of a special
move be the very next stick input, with nothing in between. A diagonal makes two
inputs rather than one, so a slightly rolled quarter-circle produced a spare
input and the move simply died - measured, tapping Down between the two forwards
of a Forward,Forward killed it 4 times out of 4. Motions may now step over a
couple of stray inputs. Same measurement afterwards: 4 out of 4 come out.

Shang Tsung's skulls were re-ordered as part of this, so asking for three skulls
gives you three and not one.

**Air projectiles cost something.** One per jump - Mileena's air sai in
particular had no limit of any kind and could be thrown as fast as the button
could be tapped - and you come down from one heavily, landing slower than
normal and not free until you have finished doing it. Thrown from range they are
as safe as they ever were; thrown in someone's face they are now punishable.

**Impossible stick directions are resolved.** Left and Right together give
neutral, Up and Down together give Up. This only matters on a leverless
controller, where both are physically possible; on a stick nothing changes. It
is resolved inside the game rather than in the driver, so it applies online too.
Note that this currently governs the *held* stick - walking, ducking, blocking -
and not yet the individual inputs of a special-move motion.

**Secret-fighter boss scaling follows the controller, not the character.** A
human Jade/Smoke/Noob takes normal damage and walks at normal speed; the CPU
versions keep the boss numbers.

**Back + HP requires standing.** The added Back+HP specials used to fire out of
a crouch and eat your uppercut. They do not any more.

**Baraka's blade swipe** (`B + HP`) had its strike box live on the
follow-through frame instead of the blade frame — an arcade bug. Fixed, with no
change to its damage or reach.

**Online play gets extra motion slack.** Special-move windows are widened by 6
ticks when the game is running over the net, and **only** then. On a cabinet or
in local two-player the timing is arcade-exact.

**The one-player ladder is drawn fresh every game.** The matchup chart against
the character you actually picked sorts the eleven into difficulty bands, and
then the order *inside* each band is a draw. So the climb still ramps -- the
fighters who beat your pick are waiting near the top -- but which of the three
that are equally rough for you turns up on battle 7 changes from game to game.
Shang, Kintaro and Kahn are still the tail.

The machine's difficulty setting decides how hard the bands hold. On easy they
leak: an opponent regularly shows up one band out of place. On the hardest
setting they almost never do. Nothing can move a fighter more than one band,
whatever the dice say.

**The CPU is much better.** Thirteen passes of work: it punishes by what you
actually recovered from, models your habits and predicts your next move, has
per-character anti-air instead of always uppercutting, escapes corners, respects
throw escapes, and runs real juggle combos on all fourteen non-boss characters.
Shang re-reads you on every morph.

**Character endings are gone.** All twelve were removed to buy ROM space for new
content. The buy-in / continue screen is back and working.

**Free play** is off by default — the ROM behaves like a stock board, with the
coinage dipswitch and a credit count. Free play is granted at run time only by
the online wrapper.

---

## 8. Quick reference — everything new on one screen

```
SELECT SCREEN
  Mileena   + Low Kick x5 ...... Jade
  Reptile   + Block x5 ......... Ermac
  (Smoke and Noob are no longer selectable)
  Start x5 (1P only) ........... next opponent is Shao Kahn
  Start + LP/HP/HK/LK/BL/Coin .. alternate costume

VS SCREEN
  Left / Right ................. pick the arena (2 seconds)
  Outer Haven + both hold Up ... PONG
  Dead Pool + both hold Down ... WAFFLE HOUSE (secret arena)

NEW SPECIALS
  Sub-Zero   D,B + LP .......... ice tornado
             D,F + LP in air ... air ice ball
  Cage       F,F,B + HP ........ ceiling uppercut
             B + HP ............ power punch
  Baraka     U,U + LK .......... blade spin  (moved off HP)
             hold D+LP+BL ...... scissor leg grab
  Kitana     hold BL, F,F ...... overhead spin chop
  Reptile    F,F + HP+LP ....... fast forceball
             F,F + HP in air ... air spit
             Down + HK in air .. dive kick
  Jax        F,D,B + HK in air . air lightwave
             B + HP ............ power punch
  Kung Lao   B + HP ............ backfist
  Liu Kang   B + HP ............ backfist
  Shang      B + HP ............ round punch
             BL+UP+HK .......... drop the morph, back to Shang
  Raiden     B + HP ............ short lightning
  Noob       D,B + LK .......... shadow slide
             D,B + LK in air ... shadow dive kick
             D,B + HK .......... shadow kick
             D,D + LK .......... shadow portal
             D,U ............... shadow teleport
             Away+LP+BL+LK ..... slide
  Ermac      D,B + LP .......... fireball
             D,B + HP .......... teleport punch
             B,D,B + HK ........ telekinetic slam
  Jade       B,F + LP/HP/LK .... boomerang: straight / up / down
             B,B,F + LP ........ returning boomerang
             B,F + HK .......... Jade Flash (projectile immunity)
             D,F + LK .......... nitro kick

NEW FATALITIES  (during FINISH HIM)
  Sub-Zero   F,D,F + LP   <=128 .. MK1 head rip
  Cage       F,B,B + HP   <=96 ... head hole / brain rip
  Shang      B,B,F,U + LP <=96 ... Old Shang decapitation
             F,D,F + LK   <=80 ... backflip decap
             U,D,U + LK   <=82 ... soul drain + corpse drop
  Scorpion   bare HP ............ MK1 scortch (no range window)
  Ermac      D,U,D,D,D + BL  96..192 .. telekinetic slam (band: not point blank)
             D,B,B + LK ........ BABALITY (no HP/LP that round)
```
