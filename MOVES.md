# Mortal Kombat II v4.0 — Definitive Move List & Strategy Guide

Every move below was checked against the v4.0 build itself (the FBNeo / Fightcade
set `mk2rev4`), with the build's own switches applied. Moves that were tried
during development and switched off before release (Kitana's spin chop, Cage's
flip kick and air shadow kick, Rain's knee-into-super link)
are **not** listed, because they are not in the game.

**NEW** marks something that is not in arcade MK2 (L3.1). Everything else is the
classic move, sometimes with an improvement noted beside it.

---

## How to read this guide

| Symbol | Meaning |
|---|---|
| **F** / **B** | Forward (toward your opponent) / Back (away from them) |
| **U** / **D** | Up / Down |
| **HP LP HK LK BL** | High Punch, Low Punch, High Kick, Low Kick, Block |
| `D, F + LP` | Press the directions in order, then the button |
| **Hold X … release** | Hold the button down, enter the rest, let it go to fire |
| **(air)** | Also works in the middle of a jump |

**Fatality ranges**

| Range | Where to stand |
|---|---|
| **Close** | Right up against him (about a step or less) |
| **Sweep** | Just outside close, where a sweep reaches |
| **Mid** | About a third to half a screen away |
| **Far** | About two-thirds of a screen or more |

Hold times are given in real seconds.

---

## System changes every player should know

- **Hidden fighters.** On the select screen, put the cursor on the fighter and
  **tap START** (nothing else pressed): Scorpion → **Ermac**, Kitana → **Jade**,
  Sub-Zero → **Rain**. Tap again to switch back. In the FBNeo / Fightcade set all
  three are available from power-on. On an arcade board they are earned first:
  in a one-player game, beat **Jade** in her secret fight to unlock Jade, beat
  **Shao Kahn** to unlock Ermac and beat **Smoke** to unlock Rain (see Secret
  opponents). Unlocks are saved, and operators can restrict them in the test
  menu.
- **Back-block** (on by default): holding Back from your opponent blocks, as in
  later MK games. Operators can set it to button-only with the DIP switch MAME
  calls "Comic Book Offer". Both netplay players must use the same setting.
- **Specials straight out of a held block.** Holding BL no longer kills a
  special, so you can cancel a block directly into a special move.
- **Perfect block.** Tap BL in the last instant before a hit lands: white flash,
  only a quarter of the chip damage, and you recover faster. Holding block does
  not count; it has to be a fresh tap.
- **Combo counter and damage scaling.** Hits in a string are counted on screen,
  and each extra hit in a string does less damage. Throws, holds and Ermac's
  telekinetic slam scale too. Jax's extra slams get weaker one by one.
- **Anti-juggle.** More than three hits into a string, the attacker is pushed
  away and held until the victim lands, so a teleport cannot extend the juggle.
- **Draws and Sudden Death.** The first tie of a match is a DRAW. The next tie is
  **SUDDEN DEATH**: both start on 10% health, any damaging hit wins, and chip
  damage is off. If nobody attacks for a whole round the match ends in GAME OVER.
- **Costumes.** Hold **START** and press **HP, LP, HK, LK, BL** or insert a coin
  as you pick your fighter for alternate colours. Two players never wear the same
  colours; player 2 shifts to the next one. Against the CPU, the CPU wears a random
  costume.
- **No Friendships** in this build. Fatalities, Babalities and Stage Fatalities
  are all here.
- **Babalities:** you must not use **any punch (HP or LP)** in the winning round.
- **Stage Fatalities** work on **The Kombat Tomb**, **The Pit II**,
  **Yoteigai Tor** and **The Pit (MK1)**, using your fighter's stage input below.
  On **The Dead Pool**, an uppercut during FINISH HIM knocks him into the acid.

---

## Kung Lao

| Move | Input |
|---|---|
| Hat Throw | `B, F + LP`. Steer it with U / D. **NEW:** keep holding LP and it comes back |
| Teleport | `D, U` |
| Spin | `F, F + LK`. **NEW input** (arcade: U, U) |
| Dive Kick | (air) `D + HK` near the top of a jump |
| Air Escape | **NEW** (air) `F, F + LP` |
| Backfist | **NEW** `B + HP` (standing) |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Hat Slice | `F, F, F + LK` | Sweep |
| Fatality – Hat Decapitation | Hold LP, `B, F`, release LP | Far |
| Babality | `B, B, F, F + HK` | Any |
| Stage Fatality | `F, F, F + HP` | Close |

## Liu Kang

| Move | Input |
|---|---|
| High Fireball | `F, F + HP` (air) |
| Low Fireball | `F, F + LP` |
| Flying Kick | `F, F + HK` |
| Bicycle Kick | Hold LK about 2 seconds, release |
| Backfist | **NEW** `B + HP` (standing) |
| Double Knee | **NEW** close `HK`, then `HK` again **immediately**. The second knee drives him into the floor and he bounces, so you can follow up |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Dragon | `D, F, B, B + HK` | Sweep |
| Fatality – Cartwheel | Hold BL, roll `D, F, U, B, D` | Mid |
| Fatality – Red Dragon Flame | **NEW** in the **Start + LP** (red) costume only: press `BL` | Mid |
| Babality | `D, D, F, B + LK` | Any |
| Stage Fatality | `B, F, F + LK` | Close |

## Johnny Cage

| Move | Input |
|---|---|
| Low Green Bolt | `D, F + LP`. **NEW input** (arcade: B, D, F). **NEW:** steer it with U / D |
| Shadow Kick | `B, F + LK` |
| Shadow Uppercut | `B, B + HP`. **NEW input** (arcade: B, D, B) |
| Ceiling Uppercut | **NEW** `F, F, B + HP` |
| Nut Punch | `BL + LP` together |
| Power Punch | **NEW** `B + HP` (standing) |

The high green bolt is gone from Cage's player move list; the low bolt now aims
anywhere.

| Finisher | Input | Range |
|---|---|---|
| Fatality – Torso Rip | `D, D, F, F + LP` | Close |
| Fatality – Triple Head Pop | `F, F, D, U` (no button) | Close |
| Fatality – Brain Punch | **NEW** `F, B, B + HP` | Close |
| Babality | `B, B, B + HK` | Any |
| Stage Fatality | `D, D, D + HK` | Close |

## Baraka

| Move | Input |
|---|---|
| Blade Sparks | `D, B + HP`. **NEW:** steer with U / D |
| Blade Fury | `B, B, B + LP` |
| Blade Spin | **NEW input** `U, U + LK`, entered right as the jump starts (the arcade block-tap spin is gone) |
| Sword Kick (Scissor Takedown) | **NEW** `D + LP + BL` together. He plants a blade, swings up into a handstand on it and scissors him to the floor with his legs |
| Blade Swipe | `B + HP` (standing) |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Decapitation | `B, B, B, B + HP` | Sweep |
| Fatality – Impale | `B, F, D, F + LP` | Mid |
| Babality | `F, F, F + HK` | Any |
| Stage Fatality | `F, F, D + HK` | Close |

## Kitana

| Move | Input |
|---|---|
| Fan Throw | `F, F + HP + LP` (air). **NEW:** steer with U / D; keep holding HP and it curves back like a boomerang |
| Fan Lift | `B, B, B + HP` |
| Square Wave Punch | `F, D, B + HP` |
| Fan Swipe | `B + HP` (standing) |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Kiss of Death | Hold LK, `F, F, D, F`, release LK | Close |
| Fatality – Fan Decapitation | `BL, BL, BL + HK`. **NEW:** two swings, out and back | Close |
| Babality | `D, D, D + LK` | Any |
| Stage Fatality | `F, D, F + HK` | Close |

## Mileena

| Move | Input |
|---|---|
| Sai Throw | Hold HP about ½ second, release (air) |
| Teleport Kick | `F, F + LK` |
| Ground Roll | `B, B, D + HK` |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Sai Stab | `F, B, F + LP`. **NEW ending:** she cuts him in half | Close |
| Fatality – Body Suck | Hold HK about 2 seconds, release | Close |
| Babality | `D, D, D + HK` | Any |
| Stage Fatality | `F, D, F + LK` | Close |

## Shang Tsung

| Move | Input |
|---|---|
| One Flaming Skull | `B, B + HP` |
| Two Flaming Skulls | `B, B, F + HP` |
| Three Flaming Skulls | `B, B, F, F + HP` |
| Round Punch | **NEW** `B + HP` (standing) |
| Elbow Chain | **NEW** close `HP`, then `HP` again: a second elbow |
| Drop a Morph | **NEW** `BL + U + HK` (back to Shang from any form) |

**Morphs**

| Into | Input |
|---|---|
| Liu Kang | `B, F, F + BL` |
| Kung Lao | `B, D, B + HK` |
| Johnny Cage | `B, B, D + LP` |
| Baraka | `D, D + LK` |
| Kitana | `BL, BL, BL` |
| Mileena | Hold HP about 1 second, release |
| Raiden | `D, B, F + LK` |
| Sub-Zero | `F, D, F + HP` |
| Reptile | Hold BL, `U, D + HP` |
| Scorpion | Hold BL, `U, U` |
| Jax | `D, F, B + HK` |
| **Ermac** | **NEW** hold BL, `D, D, U` |
| **Jade** | **NEW** `F, F, D, D + BL` |
| **Rain** | **NEW** hold `D + BL`, tap LK |

A morphed Shang wears that fighter's default costume and can use that fighter's
moves. He turns back on his own after a while, or straight away with `BL + U + HK`.

| Finisher | Input | Range |
|---|---|---|
| Fatality – Soul Steal | `U, D, U + LK` | Close |
| Fatality – Backflip Decapitation | **NEW** `F, D, F + LK` | Close |
| Fatality – Blade Decapitation | **NEW** `B, B, F, U + LP` | Sweep |
| Fatality – Spike Impale | Hold HK about 3 seconds, release (facing him) | Sweep or farther |
| Fatality – Kintaro | Hold LP about 18 seconds, release | Sweep |
| Babality | `B, F, D + HK` | Any |
| Stage Fatality | `D, D, U, D` (no button) | Close |

## Raiden

| Move | Input |
|---|---|
| Lightning | `D, F + LP`. **NEW:** steer with U / D |
| Teleport | `D, U` |
| Torpedo | `B, B, F` (no button) |
| Electric Grab | Hold HP about 1½ seconds, release (close) |
| Short Lightning | **NEW** `B + HP` (standing) |

Raiden's lightning, and the flash on whoever it hits, match his costume:
blue (default), red (Start + HP) or purple (Start + LP / HK / LK).

| Finisher | Input | Range |
|---|---|---|
| Fatality – Electrocution | Hold LK about 2 seconds, release | Close |
| Fatality – Exploding Uppercut | Hold HP about 7 seconds, release | Close |
| Fatality – Lift | **NEW** hold HK about 3 seconds, release | Close |
| Babality | `D, D, U + HK` | Any |
| Stage Fatality | `U, U + HP` | Close |

## Sub-Zero

| Move | Input |
|---|---|
| Ice Ball | `D, F + LP`. **NEW:** also in the air |
| Ground Freeze | `D, B + LK` (now also works in a corner) |
| Slide | `B + LP + BL + LK` together |
| Tornado | **NEW** `D, B + LP` (Midway's cut move, restored) |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Deep Freeze | `F, F, D + HK` to freeze him, then `F, D, F, F + HP` to shatter | Mid, then close |
| Fatality – Ice Bomb | Hold LP, `B, B, D, F`, release LP | Far |
| Fatality – Head Rip | **NEW** `F, D, F + LP` | Close |
| Babality | `D, B, B + HK` | Any |
| Stage Fatality | `D, F, F + BL` | Close |

## Reptile

| Move | Input |
|---|---|
| Slow Forceball | `B, B + HP + LP`. **NEW:** steer with U / D |
| Fast Forceball | **NEW** `F, F + HP + LP` |
| Acid Spit | `F, F + HP`. **NEW:** also in the air |
| Invisibility | `U, U, D + HP` |
| Slide | `B + LP + BL + LK` together |
| Dive Kick | **NEW** (air) `D + HK` near the top of a jump. Leaves an afterimage |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Tongue | `B, B, D + LP` (while visible) | Mid |
| Fatality – Invisible Slice | Turn invisible, then `F, F, D + HK` | Close |
| Babality | `D, B, B + LK` | Any |
| Stage Fatality | `D, F, F + BL` | Close |

## Scorpion

| Move | Input |
|---|---|
| Spear | `B, B + LP` |
| Teleport Punch | `D, B + HP` (air) |
| Forward Teleport | **NEW** `D, F + HP` (air). Leaps toward him and lands in front: a mix-up with the regular teleport. Shares its cooldown. Cannot follow a flip kick or flip punch that hit a grounded opponent |
| Leg Takedown | `F, D, B + LK` |
| Air Throw | (air) `BL` when close to an airborne opponent |
| Sword Slash | **NEW** `B + HP` (standing) |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Toasty (MK2 burn) | `D, D, U, U + HP` | Any |
| Fatality – MK1 Burn | `U, U + HP`. **NEW:** MK1's flame-and-skeleton finisher | Mid |
| Fatality – Spear Slice | Hold HP, `D, F, F, F`, release HP | Close |
| Babality | `D, B, B + HK` | Any |
| Stage Fatality | `D, F, F + BL` | Close |

## Jax

| Move | Input |
|---|---|
| Energy Wave | `F, D, B + HK`. **NEW:** also in the air (it travels flat at the height you throw it) |
| Gotcha Grab | `F, F + LP`, tap LP for more punches |
| Ground Pound | Hold LK about 2 seconds, release |
| Backbreaker | (air) `BL` when close to an airborne opponent |
| Multi-Slam | Tap HP rapidly during his throw |
| Power Punch | **NEW** `B + HP` (standing) |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Head Clap | Hold LP, `F, F, F`, release LP | Close |
| Fatality – Arm Rip | `BL, BL, BL, BL + LP` | Sweep |
| Babality | `D, U, D, U + LK` | Any |
| Stage Fatality | `U, U, D + LK` | Close |

---

## Hidden fighters (select with a START tap — see the top)

## Jade (tap START on Kitana)

| Move | Input |
|---|---|
| Boomerang – High | `B, F + HP` |
| Boomerang – Straight | `B, F + LP` |
| Boomerang – Low | `B, F + LK` |
| Boomerang – Returning | `B, B, F + LP` |
| Shadow Kick | `D, F + LK` |
| Flash | `B, F + HK`: projectiles pass through her for a moment. Short recharge |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Staff Impale | **NEW** `BL, BL, BL, F, BL` | Close |
| Babality | `D, D, D + LK` | Any |
| Stage Fatality | `F, D, F + HK` | Close |

## Ermac (tap START on Scorpion)

| Move | Input |
|---|---|
| Teleport Punch | `D, B + HP` (air) |
| Fireball | `D, B + LP` |
| Telekinetic Slam | `B, D, B + HK`. Limited as in UMK3: not deeper than the 5th hit of a string, and not again for about 2 seconds after one connects. If refused you get a normal high kick |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Telekinetic Slam | **NEW** `D, U, D, D, D + BL` | Mid |
| Fatality – Telekinetic Head Rip | **NEW** `F, B, F, F + LK` | Far |
| Babality | **NEW** `D, B, B + LK` | Any |
| Stage Fatality | `D, F, F + BL` | Close |

## Rain (tap START on Sub-Zero)

| Move | Input |
|---|---|
| Lightning Bolt | **NEW** `B, B + HP`. Strikes where he was standing when you cast it, so he can step out of it. Short cooldown; refused 3+ hits into a string |
| Storm Cloud | **NEW** `D, F + HP`. Steer it with U / D. On a hit, the cloud holds him and **you move him with the stick**, then drops him |
| Super Roundhouse | **NEW** `B + HK`: knocks him clear across the screen. Spamming it in a loop gives the normal roundhouse instead |

| Finisher | Input | Range |
|---|---|---|
| Fatality – Lightning | **NEW** `D, D, B, F + HK` | Mid |
| Babality | **NEW** `D, B, B + HK` | Any |
| Stage Fatality | `D, F, F + BL` | Close |

---

## Secret opponents (one-player)

| Opponent | How |
|---|---|
| **Jade** | On the match **right before the "?"** on the Battle Plan, win a round using **only Low Kick**: no HP, LP, HK or Block at all. You go straight to a fight with Jade |
| **Smoke** | On **The Portal**, when Dan Forden pops up and says "Toasty!" after an uppercut, quickly press **D + START** |
| **Noob Saibot** | On the **Battle Plan** screen between matches, **hold START** for about 3 seconds without letting go. Your next opponent is Noob Saibot |
| **Khameleon** | On the **Battle Plan** screen, **tap START five times**. Your next opponent is Khameleon |

On an arcade board, beating Jade unlocks Jade and beating Smoke unlocks Rain
(see the top of this guide).

---

## Strategy notes

- **Your first hit counts the most.** Damage scaling means a string's later hits
  are worth less, so start strings with your strongest hit.
- **Use the new backfists and power punches as pokes.** `B + HP` standing is a
  fast, safe-ish tool for most of the cast; crouching `D + HP` is still the
  uppercut.
- **Steer your projectiles.** Most projectiles now take U / D while flying, which
  makes jumping over them much harder.
- **Perfect-block pressure.** Tap BL just before a hit instead of holding it: less
  chip and you recover first, so you can punish.
- **Scorpion's two teleports are a mix-up.** `D, B + HP` comes down behind, while
  `D, F + HP` comes down in front. They share one cooldown.
- **Rain's cloud is a combo tool.** A cloud that catches an airborne opponent keeps
  the combo counter running while he is held.
- **Bosses fight back now.** Kintaro catches jump-ins out of the air and slams
  you; both bosses punish moves they block. Jumping kicks are no longer a free win.
