# Mortal Kombat II v4.0 - Public Changelog

This is a player-friendly changelog for the current build, summarized from the
readonly source baseline, repo history, and the latest verified build.

Fatality details are intentionally kept light. There has been a lot of fatality
restoration and stability work, but the fun is finding those in-game.

## Quick Highlights

- Netplay-focused build: faster input feel, deterministic random behavior,
  free play online (coin-op on a cabinet), and quick rematches.
- New and restored non-fatality specials for several characters.
- Expanded hidden palette support with multiple Start-button palette chords.
- VS-screen stage select added, with stage art/palette fixes.
- Refreshed Forest2/Living Forest 2 background assets in the latest build.
- New custom art pipeline for restored sprites, move art, stage art, and palette
  work.
- Many crash fixes around projectiles, morphs, stage cleanup, palettes, and
  round transitions.

## Quick New Move List By Character

Spoiler note: this list is non-fatality moves and move behavior only.

- Liu Kang: Back + HP backfist path restored with custom move art.
- Kung Lao: Back + HP backfist path restored; spin and jump-kick behavior tuned.
- Johnny Cage: Down, Forward + LP low green ball is aimable; Down, Down, Up + HP
  ceiling uppercut; Back + HP power punch; Back, Back + HP shadow uppercut
  shortcut; ballbreaker now works on female fighters.
- Reptile: Air acid spit with Down, Forward + HP while airborne; fast forceball
  variant; forceball can be aimed up/down.
- Sub-Zero: Air freeze with Down, Forward + LP while airborne; restored tornado
  with Down, Down + HP.
- Shang Tsung: Expanded morph behavior, including old Shang style morph work and
  safer morph cleanup.
- Kitana: Fan boomerang recall when HP is held after a whiffed fan.
- Mileena: No new non-fatality special in this build; benefits from female-ninja
  reaction and palette fixes.
- Jax: No new non-fatality special in this build; benefits from shared system,
  palette, and stability fixes.
- Baraka/Sword Arms: Up, Up + HP helicopter blade special; Down + Block + LP + LK
  sword-kick/leg-grab style move; spark projectile can be aimed up/down.
- Scorpion: Spear can be aimed up/down; decoy/teleport punch travels farther;
  scissor takedown recovery improved.
- Raiden: Lightning is faster and aimable up/down; Superman dive connects better
  on ducking opponents; shocker reach improved.

## New And Restored Non-Fatality Moves

These are the fun gameplay additions that are not fatalities.

- Sub-Zero now has an air freeze special: Down, Forward + LP while airborne.
- Sub-Zero's cut tornado move is fully restored: Down, Down + HP. It uses the
  original tornado art and `SUBNADO_P` palette, loops while HP is held, hits
  with a tall freeze box, and returns Sub-Zero safely to normal palette/state.
- Reptile now has an air acid spit: Down, Forward + HP while airborne. It uses
  recovered air-spit droplet art instead of reusing the ground spit setup.
- Reptile has a faster forceball variant and aimable forceball behavior.
- Kitana's fan can boomerang back if HP is held after a whiff. The return tracks
  her current position and can still hit on the way back.
- Johnny Cage's low green ball uses the simpler Down, Forward + LP input and is
  aimable up/down in flight.
- Johnny Cage has a restored ceiling uppercut route on the current build:
  Down, Down, Up + HP.
- Johnny Cage's power punch is wired on Back + HP.
- Johnny Cage's shadow uppercut input was simplified from the old awkward input
  to Back, Back + HP.
- Johnny Cage's ballbreaker now works on female fighters, with dedicated reaction
  handling so it no longer hangs their animation.
- Baraka/Sword Arms has a helicopter blade special on Up, Up + HP. It rises,
  drops in with blade collision, shreds on clean hit, and flips out punishably
  only when blocked.
- Baraka/Sword Arms has a Sonya-style sword-kick/leg-grab style move with a
  moving hitbox through the active leg frames. On connect, the victim is held,
  flipped, slammed, and knocked down.
- Baraka's spark projectile is aimable up/down.
- Raiden's lightning is faster and aimable up/down.
- Raiden's Superman dive hitbox reaches ducking opponents more reliably.
- Raiden's shocker range was extended.
- Kung Lao's spin has improved hit registration during startup/windup.
- Kung Lao's straight jump-kick has more reach.
- Scorpion's spear is aimable up/down.
- Scorpion's decoy/teleport punch travels farther and behaves better around
  stage corners.
- Scorpion's scissor takedown recovery was improved so he is not freely punished
  after connecting.
- Shang Tsung morph behavior has been expanded and hardened, including old Shang
  style morph work and safer cleanup when morphing into other characters.
- Liu Kang and Kung Lao restored backfist/move-art work is present in the move
  art pool.

## Gameplay And Balance Tuning

- Input debounce reduced from 2 frames to 1 frame, saving about one frame of
  input latency in emulation/netplay.
- Combo input windows are widened centrally for netplay comfort.
- Ducking low punch speed was restored closer to retail timing so LP into
  uppercut chains behave correctly again.
- AI throw/slam cheating was reduced. The CPU is less likely to "read" your
  recovery and throw you unfairly.
- Random select has better variety and remains deterministic for rollback.
- Same-character palette handling is improved.
- Several projectile routines were guarded so stale thrower pointers do not
  crash the game during round transitions.
- Baraka helicopter, Baraka sword-kick, Raiden backhand/hold-back HP behavior,
  Cage projectile animation paths, and Reptile projectile paths have all had
  stability/timing passes.

## Palettes And Alternate Colors

- Hidden palette selection has been expanded beyond the original simple P1/P2
  palette split.
- Start-button palette chords now support more variants, including Start,
  Start+LP, Start+HP, Start+HK, Start+LK, and character-specific Start+Block
  handling where wired.
- Ninja/Sub-Zero palette work includes `SUBALT2_P`.
- Kung Lao/Hathead palette work includes updated `TMGREEN_P`, `TMPURP_P`,
  `TMALT1_P`, and `TMALT2_P`.
- Liu Kang palette work includes updated `LIUALT2_P`, plus `LKALT3_P` and
  `LKALT_P` wiring for hidden select variants.
- Raiden bolt/electric effects now better follow Raiden's active selected
  palette instead of falling back to a mismatched effect color.
- Fatality/decap palette handling was corrected so victims keep the palette the
  player selected instead of randomly reverting during finish sequences.
- Kano heart-rip heart palette support was imported as `HEART_P` for shared
  heart art usage.
- VS-screen `KOMBATZN.IMG` / over-select art now uses the intended `OVERSEL_P`
  palette instead of rendering multicolored.
- VS-screen over-select art was aligned to close the center gap.

## Stages And Presentation

- VS-screen stage select is now wired in.
- Current normal VS/stage cycle skips Outer Haven while it remains WIP.
- The latest build includes the refreshed Forest2/Living Forest 2 background
  graphics.
- Pit Bottom/Kung Fu pit proof stage work is wired into the custom stage path.
- Dead Pool hanging-body work is present, with acid/skeleton animation work in
  progress. Risky child pool effects are disabled for stability in this build.
- Dead Pool/Raiden/Shang crash cases received targeted cleanup.
- VS-screen stage-name panel art and restore chunks were fixed and re-aligned.
- Background table promotion and SAG sync tooling now keep stage art pointers
  current after LOAD2 rebuilds.

## Fatalities, Spoiler-Light

- Multiple cut or unfinished fatality assets were researched, restored, wired,
  or partially staged.
- Several fatality animation alignment, mirror, palette, and victim-position
  bugs were fixed.
- Shang morph edge cases during fatalities were hardened, especially around
  Raiden and Dead Pool cases.
- Scorpion's flame/toasty fatality mask-off sound is forced so it should play
  consistently.
- Cage's WIP brain/head-rip path is disabled in this build while it is refined.
- Fatality victim palettes should now preserve the selected character palette
  instead of switching to a random/default palette.

No fatality inputs or full choreography are listed here on purpose.

## Netplay And Quality Of Life

- Free play is forced.
- Startup skips directly toward character select for netplay-style sessions.
- The diagnostic menu is disabled at boot and mid-game to avoid desyncs.
- Buy-in/game-over friction is removed for rematch flow.
- Match flow preserves the session scoreboard across rematches.
- Random select is deterministic and rollback-safe.
- The game no longer uses the hardware scanline counter in gameplay RNG.
- Blood RNG was split away from gameplay RNG so blood effects do not desync the
  match state.
- RNG is reseeded from synchronized match state at round start.
- A `netplay_sync` checksum value is exported for wrapper-side desync detection.
- FBNeo/Fightcade CRC spoofing is integrated into ROM packaging.

## Technical / Build Pipeline Changes

- `build.py` now runs the full source/art pipeline with stronger checks:
  LOAD2 log validation, source table promotion, background SAG sync, and ROM
  name auto-stamping.
- `makerom.py` checks program ROM sections and REVX payloads for overlap before
  writing final UJ12/UG12 program ROMs.
- `makevrom.py` packages fixed custom video-ROM wrapper regions and fails if a
  custom payload drifts or overflows its assigned slot.
- `mamerom.py` can merge retail sound with source-built program/video ROMs and
  then CRC-spoof the output zip.
- Custom move/stage art is now kept in fixed wrapper pools such as `MOVEART1`,
  `MOVEART2`, `RDMOVE`, `KFPITPL`, and `ORNGBL` instead of casually appending
  to near-full stock LODs.
- The old REVX/MK3 ad space was repurposed for modern build needs and movie
  payload handling.
- LOAD2 table promotion preserves hand-added palette fields and custom labels
  while updating SAG addresses from rebuilt art.
- Background work now has stock-drift checks, render/proof tools, and stage
  constraints documented for safer BLIMP/BDD edits.
- `hitbox_edit.py`, `frame_edit.py`, and `combo_edit.py` support label-based
  gameplay tuning.
- `imgdump.py`, symbol tools, BG proof scripts, MAME load/debug helpers, and
  asset ledgers were added or expanded to make future sprite/stage work safer.

## Stability Fixes Worth Calling Out

- Kitana fan crash fixed when several fans/projectiles were active and the
  thrower process changed.
- Scorpion left-edge warp fixed for spear/teleport behavior.
- Reptile air-spit and blood palette paths hardened.
- Raiden victory/Dead Pool crash cases cleaned up.
- Shang morph cleanup improved so morphed characters return through safer state
  paths.
- Character and projectile processes now guard more stale object/proc pointers.
- Fatality mirror/placement issues were cleaned up across several characters.
- Stage select now validates stage IDs and skips retired/WIP stage entries.

## Current Build Notes

- Latest playable build was packaged to `C:\MAME\roms\mk2.zip`.
- The final package was verified with MAME: `romset mk2 is good`.
- The build uses source-built program/video ROMs with retail sound merged from
  the local baseline zip.
- Forest2 required stripping three unresolvable preview/missing block references
  from the new BDB export before LOAD2 could compile it.
- Outer Haven remains present in the source/art pipeline but is intentionally
  skipped from normal VS select and rotation for now.
- Cage's WIP brain/head-rip fatality path is intentionally disabled for polish.
