# Changelog

Modifications to the leaked Mortal Kombat 2 source code, which builds
as revision 3.0 (development codename "SUDDEN_RECLINE"). Our builds are
numbered `X.Y-rN` starting with r0. The running game shows the
current revision in the test menu under the ROM name string.

## 3.0-r18 — 2026-05-01

### Sub-Zero tornado move: full enablement

The tornado move (D,D,HP) is now fully functional. Midway left the
art assets (`tornadostart`–`tornado8` in `MKXTRAS.IMG`) and palette
(`SUBNADO_p`, 45-color ice-blue whirlwind) in the source data but cut
the move before wiring it to any joystick input.

- **Combo trigger**: `scom_sz_tornado` (D,D) wired to `sz_hi_punch` →
  `do_sz_tornado` in [MOVES.ASM](src/MOVES.ASM).
- **Action equate**: `act_sz_tornado` (`0210h`) added to
  [MAINEQU.ASM](src/MAINEQU.ASM). Previously missing — the build
  would abort with "undefined symbol act_sz_tornado."
- **Animation**: `a_sz_tornado` in [MKNJ.ASM](src/MKNJ.ASM) plays
  `NJINVISO1/2` vanish poofs followed by all 8 `sz_tornadostart`
  through `sz_tornado8` multipart wrappers, moving toward the
  opponent at `040000h` x‑velocity.
- **Palette**: `player_swpal(SUBNADO_p)` called before the tornado
  frames, `player_normpal` after. `SUBNADO_p` defined in
  [IMGPAL6.ASM](src/IMGPAL6.ASM) and exported in
  [IMGTBL.GLO](src/IMGTBL.GLO).
- **Hit detection**: per‑frame `strike_check_a0` loop over all 8
  tornado frames using ninja strike table index `1bh`
  (`stk_tornado`: tall `0c0h×090h` box, freeze routine `01313h`,
  zero damage, `sf_squeeze` flag).
- **Sound**: teleport (`086h`) on vanish.
- **Build fix**: GSPA 6.10 does not always propagate `.globl`
  directives from included `.GLO` files to the defining `.OBJ`.
  Added `.globl SUBNADO_p` directly in `IMGPAL6.ASM` before the
  label — without this `mk2.out` fails to link with
  `undefined symbol SUBNADO_p`.

### Files changed

| File | Change |
|------|--------|
| `src/MAINEQU.ASM` | Added `act_sz_tornado` equate (`0210h`) |
| `src/MOVES.ASM` | `do_sz_tornado`: palette swap, hit loop, `towards_x_vel` |
| `src/MKNJ.ASM` | `sz_tornadostart`–`sz_tornado8` wrappers, `a_sz_tornado` sequence |
| `src/MKSTK.ASM` | `stk_tornado` strike entry (index `1bh`) |
| `src/IMGPAL6.ASM` | `SUBNADO_p` palette (45c) + `.globl` directive |
| `src/IMGTBL.GLO` | `.globl SUBNADO_p`, `.globl tornadostart`–`tornado8` |
| `data/MK4MIL.LOD` | Tornado frames under `PON>` for palette-carrying TBL headers |
| `AGENTS.md` | Updated version, tornado docs, `.globl` linker trap |

## 3.0-r17 — 2026-04-22

### Netplay hardening

- **Disabled diag-menu entry** in [MKINIT.ASM](src/MKINIT.ASM) at both
  boot (`ckdiag` result ignored) and mid-game (dipswitch probe skipped).
  Mismatched dip states between netplay clients could push one side
  into diag → instant desync.

### Kitana fan: anti-crash guard

[MKZAP.ASM fan_proc](src/MKZAP.ASM) now stamps the thrower's `procid`
into `p_store4` at spawn and runs `validate_thrower` before every
deref of `p_store2`. Previously, if Kitana got hit / rounds cycled
mid-flight, the thrower proc could be reallocated and the fan would
deref a recycled proc's `pa8` (garbage object pointer) → strike_check
on wild memory → crash. Symptom was "throw 3+ fans, another
projectile enters the mix, game crashes." Now fans cleanly self-destruct
when thrower state is gone.

### Random-select: better distribution

[MKSEL.ASM auto_player_select](src/MKSEL.ASM) seed now mixes:
- `battle_num << 8` (upper byte)
- `@tick` (current frame)
- `@rand` full 32-bit (split into two 16-bit halves)
- `@p1_char`, `@p2_char`
- `@p1_wiar`, `@p2_wiar`
- per-player salt (0x9e17 P1, 0x3c5d P2)

Then an 8-round xorshift16 "whitening" pass amplifies small input
differences into completely different walk paths. All inputs remain
GGPO-deterministic (no `@hcount`, no per-side timing). Previous version
tended to produce the same characters because entropy inputs didn't
vary enough between boot-and-first-press.

### Female-ninja ballbreaker reaction

[MKFN.ASM a_nutcrunched](src/MKFN.ASM) now uses `KTHITHI3` + shaking
`FNDRAIN0` (the doubled-over soul-drain frames) instead of the
generic `KTSTUMBLE` backward-stumble. Reads better as "hit in a
sensitive area, buckling" for female ninjas who have no dedicated
crotch-grab art.

## 3.0-r16 — 2026-04-21

### AI: expanded slam cheat neuter

[MKDRONE.ASM drone_body_slam](src/MKDRONE.ASM) previously aborted
only when the human was in one of 6 active-attack actions. The
classic "AI throws you while you try to sweep them" cheat still
worked because `drone_charge_slam` walks toward the player for up
to 0x30 ticks, and during that time the player's sweep transitions
from `act_sweep` into `act_sweep_sd` (sitting duck recovery) --- the
slam fired once the recovery state replaced the attack state.

Now the abort list covers:
- all 6 original active attacks + `act_knee` + `act_elbow`
- every sitting-duck recovery state (0x0600..0x061b mask check --
  post-sweep, post-kick, post-punch, retract-kick, etc.)
- `act_postattack` (general "just finished attacking" transition)

All 7 call sites of `drone_charge_slam` funnel through
`drone_body_slam`, so the fix is centralized.

### Input latency: 1-frame debounce

[MKINIT.ASM scan_port](src/MKINIT.ASM) previously required the last
2 port states to be "open" before accepting a "closed" transition
as a real press. Emulated / netplay inputs don't bounce, so the
extra frame of filtering was pure latency. Dropped to 1-frame
debounce (only immediately-previous state must be open); saves
~16.7ms of input lag on every button.

### Duck low-punch speed

[MOVES.ASM do_duck_punch](src/MOVES.ASM) animation speed 3->2 for
both the strike and retract phases. Matches retail L3.1 timing so
duck LP -> HP uppercut chains reliably again (our source build had
the move ~33% slower than retail, which prevented the chain).

### Match flow: preserve single-player mode through rematches

[MAIN.ASM play9](src/MAIN.ASM) now snapshots `p1_state` and
`p2_state` BEFORE `end_of_match_chores`, and only promotes each
player to `ps_psel` if they were `ps_active` during the match.
Previously we force-set both to `ps_psel` which dragged a drone P2
into the next char select as a human; now if P2 was a drone,
p2_state stays 0 and the game correctly continues ladder mode.

### Random-select: broader entropy, still GGPO-safe

[MKSEL.ASM auto_player_select](src/MKSEL.ASM) seed now mixes:
- `battle_num << 8` (shift into high byte so small battle counts
  don't dominate low bits)
- `@tick` (GGPO-synced round timer at the moment random fires)
- `@p1_char`, `@p2_char` (both cursor positions)
- `@p1_wiar`, `@p2_wiar` (cumulative scoreboard)
- per-player salt XOR (0x9e17 for P1, 0x3c5d for P2)

All inputs are deterministic under GGPO rollback (no @rand, no
@hcount, no per-side timing). Simulation across 30 samples per
player hits all 12 roster slots with reasonable distribution, and
back-to-back matches now see varied picks instead of the same 2-3
characters looping.

### Training mode: clock freeze flag

New `f_freeze_timer` BSS word ([RAM.ASM:94](src/RAM.ASM#L94)) and
[MAIN.ASM clock4](src/MAIN.ASM). Non-zero value skips the clock
decrement each tick so the round timer never runs out. K.O. and
bar-zero round-end checks still fire normally --- only the time
value is frozen. Nothing writes the flag yet; it's a scaffold for
future training-mode UI.

## 3.0-r15 — 2026-04-21

Netplay build. Turns MK2 into a console-style rematch loop with
GGRS-safe determinism.

### Boot: skip to character select

- `forcefree equ 1` ([SYSEQU.ASM:16](src/SYSEQU.ASM#L16)) hard-wires
  free play via the five existing `.if forcefree` short-circuits in
  DIAGCOIN.ASM / DIAGCMOS.ASM. GSPA 6.10 doesn't pick up the sysequ
  value in those files from the include alone (assembler quirk), so
  `forcefree equ 1` is also declared inline in
  [DIAGCOIN.ASM](src/DIAGCOIN.ASM) and
  [DIAGCMOS.ASM](src/DIAGCMOS.ASM) right after the include. Without
  this the `cmpi adjfrepl,a0 / jrnz` path runs and credits are still
  required.
- `netplay_boot_start` process ([MKINIT.ASM](src/MKINIT.ASM)) spawns
  alongside the attract-mode process. It polls `@gstate` until
  amode_init has set it to `gs_amode`, pre-seeds `p2_state = ps_psel`
  so both players enter char select active, then `jauc p1_start_button`
  to drive the gstate dispatch into `amode_game_start` -> `start_a_game`
  -> `gs_psel`. Initial fixed 8-tick sleep was racing amode_init and
  died in `sucide` when gstate was still 0.
- `cmosret` in [DIAGDTST.ASM:446](src/DIAGDTST.ASM#L446) unconditional
  `jruc ctmp0` skips the "press button to continue" splash even when
  CMOS reset / tilt flags force `a13 != 0`.

### Match flow: no buyin, instant rematch, persistent scoreboard

- After a BO3 ends ([MAIN.ASM:play9](src/MAIN.ASM)) the buyin
  countdown + initials entry are gone. Instead we set both
  `p1_state/p2_state = ps_psel`, `gstate = gs_psel`, reclaim
  `pid_master`, and `jsrp player_select` -> `vs_screen` -> `jruc
  game_loop` for the next round of picking + fighting.
- `inc_winners_wiar` is *not* called at play9: it's already triggered
  once per match at MAIN.ASM:357 inside play_1_round when
  `double_compare` confirms 2/3 rounds. An earlier attempt to call it
  at play9 double-incremented wiar, making "WINS IN A ROW" count
  rounds instead of matches.
- `p?_wiar` / `p?_rwon` are preserved across matches so the session
  scoreboard carries over. `end_of_match_chores` zeros `p?_matchw`
  and `p?_perfect` for us.

### Random select: GGRS-deterministic

- [MKSEL.ASM auto_player_select](src/MKSEL.ASM) now uses a local
  xorshift16 on `p_store3` instead of the global `randu` +
  `@rand` + `@hcount` pipeline. GGRS rollbacks can replay input at
  different timings on each side; any `randu` call consumes entropy
  that may desync.
- Seed = `battle_num XOR salt` (P1: 0x9e17, P2: 0x3c5d). First attempt
  used OR which collapsed when `battle_num << 3` bits overlapped the
  salt, producing the same seed across battles (P2 always landed on
  Shang, P1 on same char in every other match). XOR properly mixes;
  simulation confirms distinct picks across battle_num 1..7.
- Never-seed-zero guard falls through to 0xbeef since xorshift dies
  on zero state.

### MKFX / Scorpion toasty fatality

- Disabled the `create pid_bones,flaming_bones` call after white_flash
  in [flaming_skeleton](src/MKFX.ASM). The bones-explosion spawn
  chain was jumping to an illegal opcode mid-sequence (PC landed in
  illegal_opcode at FFA228E0 with a garbage A8=0x16), producing the
  "big white screen" freeze after toasty. Until the bone_init /
  spawn_a6_bones chain is properly traced, the fatality plays up
  through the burning-skeleton + white flash + explosion sound and
  then continues normally (no bone debris flying around).

### Game-over hook (unused but in place)

- [MKAMODE.ASM gover_amode_entry](src/MKAMODE.ASM) spawns a
  netplay_boot_start trampoline on `pid_fx` before jumping to amode.
  Not hit in normal netplay flow (play9 handles the rematch loop
  before game_over fires), but preserves correct behavior if game
  state somehow reaches gover_amode_entry.

### Tools

- `crc_spoof.py` solves a 4-byte patch in 0xFF padding regions of
  modified program ROMs via GF(2) linear algebra so `CRC32(rom)`
  matches FBNeo's hardcoded driver-table CRCs. FBNeo refuses to boot
  a set whose CRC differs; spoofing lets our source-built ROMs load
  into Fightcade / FBNeo netplay without errors.
- `mamerom.py` now calls `crc_spoof.spoof_zip` on the output mk2.zip
  at the end of packaging, so every `python mamerom.py ...` run
  produces an FBNeo-ready set.
- `imgdump.py` revert of the broken "unnamed chunk iteration"
  extension added in mod14. The header-reported image count is the
  right bound; iterating past it produced garbage struct reads of
  pixel data. Restored to the mod13-baseline single-pass behavior.

## 3.0-r14 — 2026-04-20

### Cage — new special: Ceiling Uppercut (F,F,B + HP)

Cage vanishes straight up off-screen top at a ~65° angle (green
shadow trail during ascent), reappears at ground level in front of
the opponent on the side opp is facing, and launches a rising
uppercut using `stk_jcuppercut`. Whiff is punishable: strike-check
only runs during the rise phase, so juggled opponents recovering
under the animation don't eat a phantom hit on Cage's way down.

Implementation:
- New `act_jc_ceiling` (020fh), `scom_jc_ceiling` combo, propell_table
  slot `0fh`, handler in MKPROP.ASM `do_jc_ceiling`.
- Hooked into `jc_hi_punch` before existing shoruken check in
  MOVES.ASM. F,F,B stored newest-first as sw_left, sw_right,
  sw_right (facing-right mirror) / sw_right, sw_left, sw_left
  (facing-left mirror).
- Phase-1 velocity: y=-0e0000h, x=-068000h via away_x_vel (negative
  = toward opponent). Phase-2 plants Cage via match_me_with_him +
  inline xpos offset of 0x28 in opp's facing direction, clobbers
  full oyval (not just oypos) so match's copy of an airborne opp's Y
  can't leak through as fractional drift.
- Phase-3 strictly vertical rise (x-vel zeroed) so a cornered /
  jumping opponent cannot drag the strike rect sideways.

### Cage — Shadow Ball (low) aimable in flight

D,F,LP low green ball now steers up/down via the joystick mid-flight
in the Kung Lao hat / Reptile forceball style. High ball (D,B,HP)
intentionally unchanged — discriminated via an aim flag packed into
`p_store3` on the projectile at spawn. jc_snot_proc reads the thrower
proc from `p_store2` each tick, gates on `gstate == gs_fighting`, and
nudges oyvel ±0x8000 per tick on up/down press.

### Cage — Ballbreaker usable on female opponents

[MOVES.ASM:do_jc_split](src/MOVES.ASM) previously dropped into
`useless_splits` when the target was `ft_fn1`, `ft_fn2`, `ft_jade`,
or any boss — producing no punch animation at all. Gates removed;
everyone now eats the split punch. `a_nutcrunched` for female
ninjas ([MKFN.ASM:1680](src/MKFN.ASM#L1680)) was a bare label that
fell through into `a_bike_kicked` (which ends with
`ani_jump, a_bike_kicked` = infinite loop) — so before this fix any
codepath that reached it locked Kitana/Mileena/Jade in looping
stumble frames. Defined `a_nutcrunched` with explicit KTSTUMBLE1-5
frames split into two parts (mframew + find_ani_part2) with proper
`0` terminators. Visual is reused stumble art, but it now actually
ends.

### Tuning

- **Kung Lao tornado spin** ([MOVES.ASM:do_hh_spin](src/MOVES.ASM))
  now registers hits during the 20-tick free-spin windup. Previously
  the strike-check only started once the "keep tapping" phase began,
  so close-range teleports into spin often whiffed the first beat.
- **Kung Lao straight jump-kick** (`stk_hhjumpupk`) x_size 55 → 72.
  Extra reach to connect after teleport-kick transitions where the
  sprite lands just outside the old range.
- **Scorpion decoy teleport punch** ([MKPROP.ASM:do_decoy](src/MKPROP.ASM))
  x-velocity 0x80000 → 0xC0000 (+50%), flight frames 4 → 6 for
  UMK3-style distance. `f_norepell` now forced to 0x40 at decoy
  start + 0x20 through landing so Scorpion cannot wall-stick when
  teleporting from/into a stage corner.
- **Raiden shocker range** ([MOVES.ASM:do_raiden_shocker](src/MOVES.ASM))
  x-distance gate 0x44 → 0x60 (~68 → 96 px, +40%). Makes the grab
  reach ducking/retreating opponents that used to slip the check.

### Tools

- **imgdump.py** scans actual record count beyond the header-reported
  count, labels unnamed chunks as `UNNAMED_<idx>`, and prints both
  values. Prerequisite for recovering orphaned sprite chunks
  (e.g. Cage's scrapped brain-rip fatality frames in CAGE10.IMG).

## 3.0-r13 — 2026-04-19

- **Kitana fan boomerang on hold.** Throw the fan with D,F+HP as
  usual. If it whiffs the opponent and the player is still holding
  HP when it reaches screen edge, the fan reverses and tracks back
  to Kitana's current position on both X and Y (she can duck, jump,
  or walk during the return). Release HP before turnaround = fan
  dies offscreen as originally. Fan catches itself when within
  36 px X and 48 px Y of her; mid-return hits on opponent still
  register damage.

## 3.0-r12 — 2026-04-19

- **Reptile air acid spit** recovered using the leaked `a_acid_fly`
  animation (13 NJACID droplet frames with ACID_P palette, defined at
  rp_anitab2[3] but never wired to any handler). Input is
  D,F,HP while airborne.
- Implementation is a single-part projectile (unlike the ground
  spit_proc multipart face+body setup) so it sidesteps the state
  coupling that corrupted earlier port attempts. do_rp_airspit
  spawns the projectile, acid_fly_proc animates the growing droplet
  and checks strike collision.

## 3.0-r11 — 2026-04-19

- Custom-chunk ROM pipeline via NINJA2.LOD + REVX space. Per Asure's
  guidance, new sprite chunks can live in program ROM at 0xFFD00000
  (the slot previously occupied by the MK3 "coming soon" REVX ad)
  without touching the packed video ROM.
- data/NINJA2.LOD lists `NJJUMPSPIT1/2/3` (Reptile air-spit body
  frames, previously unreferenced in NINJAS10.IMG); LOAD2 emits
  NINJA2.IRW (14.5 KB) plus tmp/load2/NINJA2.TBL with real ROM
  addresses (0xFFD00000 / 0xFFD07404 / 0xFFD10008).
- src/NINJA2.TBL hand-reformatted from LOAD2's native output to match
  the leaked MKNJ.TBL struct layout the engine expects.
- makerom.py embeds NINJA2.IRW at 0xFFD00000 instead of MK8MIL.IRW
  (drops the "MK3 COMING SOON" attract advertisement).
- data/IMGBUILD.BAT: LOAD2 processes 8 LODs now (was 7).
- Pipeline validated: game builds, runs, Reptile renders normally.
  Wiring NJJUMPSPIT1/2/3 into an actual air-spit animation is a
  separate step.

## 3.0-r10 — 2026-04-18

- Fix Raiden win crash on Dead Pool. Victory sequence calls
  `raiden_dimmer` which invokes the palette fader with an exclude
  list; the 8 hanger sprite palettes (`EHANG_p`..`SVHANG_p`) were
  missing from that list, so fading them during the victory tripped
  display corruption. Added them to `death_fade_excludes`.
- Harden hanger loop in MKHANG.ASM: all writes to the sprite
  (`oxpos`/`oypos`) now additionally gated on `winner_status == 0`,
  so during any round-over sequence the hangers idle completely
  rather than touching potentially freed sprite state.
- Rev string advanced to "SUDDEN_RECLINE 3.0-MOD10" in DIAGMENU.
- CHANGELOG.md added, documenting all 3.0-modN revisions plus
  pre-session modifications carried over from prior work.
- Investigated restoring Ōtomix logo on Cage's pants. Logo pixels
  appear in some unlabeled frames of CAGE10.IMG but the labeled
  gameplay/victory sprites (JCSTANCE*, JCVICTORY*, etc.) do not
  contain the logo in their pixel data. Palette-swap experiment
  confirmed CAGE_P indices 53-61 aren't the hidden-logo colors.
  Restoring the logo would require pixel-level sprite editing in
  IT.EXE plus LOAD2 chunk address regeneration — out of scope for
  this session.

## 3.0-r9 — 2026-04-18

- Disable walk skip-step animation on joystick release. All characters
  now stop abruptly instead of playing the committed step-forward/back
  slide that locked them out of moves during recovery.

## 3.0-r8 — 2026-04-18

- Reptile forceball (slow orb): aimable via joystick up/down while in
  flight. Hat-style ±0x8000 y-velocity adjustment per frame. Guarded by
  `gstate == gs_fighting` for safety during round transitions.

## 3.0-r7 — 2026-04-18

- Baraka spark (sword-arm zap): aimable via joystick up/down. Same
  hat-style pattern as Raiden lightning.

## 3.0-r6 — 2026-04-18

- Raiden lightning: faster (velocity 0xa0000 → 0xe0000) and aimable via
  joystick up/down. Scene-state guard prevents trap during victory
  sequences when stale thrower proc would be dereferenced.

## 3.0-r5 — 2026-04-18

- Raiden superman dive (`stk_dive`): vertical hitbox extended from
  24px to 50px so the dive connects on ducking opponents.

## 3.0-r4 — 2026-04-18

- Cage low green ball: input changed from Back,Down,Forward+LP to
  Down,Forward+LP. Initial y-velocity flattened from -0x60000 to
  -0x40000 (lower arc).

## 3.0-r3 — 2026-04-18

- Kung Lao spin: input changed from Up,Up,LK to Forward,Forward,LK.

## 3.0-r2 — 2026-04-18

- Sub-Zero freeze ball: 10 HP hit / 5 HP chip damage (was 0/0).
  Applies to both ground throw and the new air freeze, which share the
  ice strike records `stk_ice1` and `stk_ice2`. Floor ice unchanged.

## 3.0-r1 — 2026-04-18

- Disabled Reptile air acid spit. Multipart face+body projectile via
  `spit_proc` corrupts display state when thrower is airborne. Kept
  `do_rp_airspit` infrastructure for future rework.

## 3.0-r0 — 2026-04-18 (baseline with gameplay additions)

- Dead Pool hanging developers feature: 7 dev sprites (Ed, Tony, John,
  Geo, Mark, Jeff, Steve) positioned on hooks across the bridge with
  parallax scroll correction to track the chain layer. Random twitches
  every ~24-41s per body (fast x-jitter or slow x/y jitter). Runs
  under `pid_bani` so round transitions don't kill the processes.
- Sub-Zero air freeze: Down,Forward,LP while airborne. Uses the
  `NJAIRICE1/2` animation frames present in the ROM but never wired
  to a move. Juggle-friendly via `air_ice_proc` variant (ignores the
  `is_he_helpless` check so the freeze registers on mid-combo victims).
- Reptile air spit (v1, later disabled): input mirrored ground spit
  while airborne. Used ground spit frames visually — air-pose frames
  `NJJUMPSPIT1/2/3` exist in NINJAS10.IMG but require LOAD2 chunk
  address regeneration to wire up.
- Build tooling: `imgdump.py` parses Midway IMG files per struct
  layout in `doc/it/wmpstruc.inc`.

## Pre-session modifications (carried over from prior work)

These were already in the initial commit baseline, applied before this
changelog started:

### System
- **Random select (MKSEL.ASM)**: boundary-aware random-walk cursor.
  Picks 6..9 steps, each with a random direction, rejecting moves that
  would keep the cursor in the same cell at corner positions.
- **AI anti-cheat (MKDRONE.ASM)**: drone no longer peeks at human
  player input; it stays in "beware" watching state instead of
  cheating by reacting to inputs before they're resolved. Result:
  more uppercuts and throws connect against the CPU.

### Cage
- **Shadow uppercut (shoruken)**: input simplified from B,D,B,HP to
  B,B,HP (`scom_jc_shoruken`).
- **Shadow uppercut recovery**: reduced minus frames on descent
  after the attack.

### Reptile
- **Acid spit**: damage buff.
- **Slide**: damage buff.
- **Fast forceball**: F,F,HP+LP triggers a 2x-velocity variant.
  Implemented via the `f_fast_force` global flag read by
  `slow_proj_proc` — when set, velocity is 0x60000 instead of
  0x30000. Flag auto-consumed after use.

### Sub-Zero
- **Slide**: damage buff.

### Scorpion
- **Scissor takedown recovery**: Scorpion recovers before opponent
  (no free uppercut after the move).
- **Spear**: aimable mid-flight like Kung Lao's hat (joystick
  up/down adjusts y-velocity).
- **Teleport**: damage buff.

## 3.0 — upstream baseline (reference, not an actual build)

- Source as leaked, builds to "SUDDEN_RECLINE REVISION 3.0"
- Matches retail L3.1 video ROMs byte-for-byte (per CLAUDE.md)
- Program ROM CRCs differ from retail (expected for source builds)
