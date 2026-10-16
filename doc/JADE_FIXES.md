# Jade — implementation notes & lessons learned

How Jade (ft_jade = 16) was finished, what was coded wrong before, and the
reusable patterns. Written as a reference before starting Noob Saibot
(ft_noob = 15), which shares almost all of the same plumbing.

## What Jade ended up with

Jade is a real playable character with her **own** move set. She uses
Kitana's female-ninja animation/strike/reaction tables as a base (she has no
unique art for most actions) but **none** of Kitana's or Mileena's specials.

| Move | Input | Entry point |
|------|-------|-------------|
| Razor-rang (boomerang) | Back, Forward + HP | `jade_hi_punch` → `do_jade_boomerang` (MOVES) → `jade_zap3`/`jade_boomerang_proc` (MKZAP) |
| Projectile-invuln Flash | Forward, Back + HK | `jade_hi_kick` → `do_jade_flash_trigger` → `do_jade_flash_test` (MKZAP) |
| Blazing Nitro Kick | Down, Forward + LK | `jade_lo_kick` → `do_fn1_nitro` (MOVES) |

The boomerang **auto-aims** at the opponent, hits for 24 (Kung Lao hat
parity) with hat blood + a knockback that recovers, and there is only **one**
of it. The Flash lets Jade keep moving while active. The drone knows all
three.

## Things that were coded wrong before (and the fix)

These are the concrete bugs found while finishing Jade. Several are whole
*classes* of bug that will bite again on Noob.

### 1. Projectile hit routed through the wrong reaction → "victim slides away forever"
The boomerang's strike record (`stk_jade_boom`, MKSTK.ASM) had reaction byte
`0x10`, whose **high byte indexes the ATTACKER's reaction table**
(`reaction_tables[ochar]` in JOY.ASM `block_is_useless`). For a female-ninja
attacker, table slot `0x10` is `r_fan` — a 12-iteration stumble that shoves
the victim backwards ~190 ticks. That is the "they keep moving backwards"
bug. **Fix:** point it at a hat-style reaction. Added `react_to_fn` slot
`0x18` = `r_jade_boom` (sets `p_hitby` then `jruc hat33`, the exact code Kung
Lao's hat uses), and set the strike word to `0x1810` / damage `0x1806`.
- **Lesson:** the strike record's reaction byte is an index into the
  *attacker's* per-character reaction table, and the low nibble of the other
  byte indexes `block_xfers`, NOT the reaction table. Always trace
  `hit_routine → reaction_tables[my_ochar][routine] → r_*` before trusting a
  copied value. A "damage looks right but the animation is wrong" symptom is
  almost always a wrong reaction index.

### 2. Manual joystick steering vs. auto-aim
The first boomerang used `hat_proc`'s human-steer model (hold up/down in
flight). The design is auto-aim. **Fix:** `jade_boomerang_proc` now computes
a one-time launch `oyvel = (dy*12 << 16) / dx` toward the opponent's chest
(head-anchored oypos + 0x30), clamped to ±8 px/tick, using `divu` (TMS34010
unsigned divide, dividend in the even/odd reg pair). The old per-tick
joystick-steer block and its `p_store3` joy flag were deleted.
- **Lesson:** fighter `oypos` is **head-anchored** (floor ≈ 197); aim at
  torso with `+0x30`. `divu` needs the 32-bit dividend in `aN` (hi) with the
  low half cleared, quotient lands in `aN`.

### 3. "Always dodges projectiles" was TWO separate mechanisms
- **Player/defender side:** `proj_strike_check` (MKZAP) let any projectile
  pass through when the defender was `ft_jade`. This is now gated by the
  **Flash** flag only (`jade_flash_active`), not by being Jade.
- **Drone side:** `drone_beware` (MKDRONE) had `cmpi ft_jade,a3 / jreq bew8`
  in the projectile branch = "Jade ignores projectiles". Removed; the Jade
  drone now reacts, and specifically Flash-counters (see below).
- **Lesson:** a character "trait" can be enforced in multiple unrelated
  places. Grep **every** `ft_<char>` reference (MAIN, MKREACT, MKDRONE,
  MKSOUND, MKSLAM, MKCANNED, MKBABY, MOVES) before assuming you found it.

### 4. Flash froze the player
The blink loop (`10× swpal/normpal, 3 ticks each`) ran **inside the player's
own process**, so `p_action` stayed busy ~1s. **Fix:** stamp the protection,
spawn a **detached** `jade_flash_blink_proc` (its own `pid_jflash`, inherits
the fighter object in `a8`), sleep 4 ticks, clear `p_action`, `retp`. Jade is
free almost immediately while the blink + protection continue.
- **Lesson:** anything that should not lock the player (visual overlays,
  timed buffs) belongs in a spawned process, never inline in the move
  handler. A foreign process may use `swpal`/`player_normpal` on the fighter
  object safely; the historical palette-lock crash came from borrowing the
  *player's* `a13` in that foreign process — don't.

### 5. Boolean flag that could strand a permanent buff
`f_jade_flash` was a 0/1 flag. If the blink process got purged (round
transition, mass process kill) with the flag set, Jade stayed
projectile-immune forever. **Fix:** the flag is now a `@tick` **expiry
stamp**; `jade_flash_active` does wrap-safe `(expiry - now) mod 2^16 <=
JFLASH_TICKS` and scrubs stale stamps. Self-expiring.
- **Lesson:** for any "active until X" state that a separate process is
  responsible for clearing, store an expiry deadline, not a boolean — so a
  lost clear can't strand it.

### 6. Character dispatch tables were only 12 entries wide
`char_hi_punch`/`char_lo_kick`/`char_joyup`/`char_*_open` etc. (MOVES.ASM,
indexed by `ochar` in `charjmp`) only had 12 rows. Jade is `ochar 16`, so a
Jade button read ran off the end into whatever `.long` followed. **Fix:**
padded all of them to 17 rows (12=kintaro, 13=kahn, 14=smoke, 15=noob,
16=jade) with `sucide` where there's no special, and Jade's real handlers at
16.
- **Lesson:** ANY per-`ochar` jump table (`charjmp`, `ochar_jump`,
  `ochar_call`, reaction/strike/anitab tables) must cover indices 0..16.
  `ochar_jump`/`get_char_long` do **no bounds check** — an under-length table
  is a silent wild jump. `reaction_tables`, `character_anitabs1/2`, and the
  `*_strikes` tables were already 17-wide (that's why the boomerang worked as
  a test on Kitana); the button tables were not.

### 7. `character_anitabs2[16]` aliased Kitana's table1
Jade's TABLE2 slot pointed at `fn3_anitab1` (a table1). Any TABLE2 anim
(boomerang throw/spin, nitro) resolved into the wrong table. **Fix:** built a
real `fn3_anitab2` (MKFN.ASM) with only the boomerang lanes (6,7) and the
nitro lane (9) real, everything else padded to `a_fn1stance`/`dummy`. Pointed
`character_anitabs2[16]` at it.
- **Lesson:** `get_char_ani` uses `character_anitabs1`, `get_char_ani2` uses
  `character_anitabs2` — a move that calls `get_char_ani2` needs its lane in
  **table2**, and a character sharing another's art still needs its own
  table2 row or it silently reads a neighbour's slots.

### 8. Crossed drone dispatch indices (latent, pre-existing)
`do_a0_tbl` (MOVES) has `14 = drone_wrap_fn1_nitro`, `15 =
drone_wrap_fn1_spinchop`, but `drone_do_fnspinchop` loaded index **14** and
`drone_do_fnnitro` loaded index **15** — swapped. Kitana's drone was doing
the nitro when it "rolled spinchop" and vice-versa. Found while splitting the
moves; fixed the indices so spinchop→Kitana and nitro→Jade line up.
- **Lesson:** when a `movk N,a0 / jruc local_drone_do_a0` feeds an index
  table, verify N against the table by name, not position — the label of the
  `drone_do_*` wrapper is not proof of the index it loads.

## Drone AI wiring (how the CPU uses the moves)

- **Boomerang:** `zap_offsets[16] = 01fh` (MKDRONE). The drone's generic zap
  paths (`drone_zap_jsrp`, `drone_stalk` far range, `ochar_propells`) throw
  it; it auto-aims like the player's.
- **Nitro:** `ochar_drone_start[16] = jade_start`, which rolls `rpt_fnnitro`
  via `ask_mr_diff` and opens with the nitro, else `generic_drone_start`.
- **Flash counter:** in `drone_beware`, after the goro/kahn special cases and
  before the generic reaction, a `ft_jade` branch: if the incoming action is
  a projectile (`p_otheract` high byte 0) and the Flash has recharged
  (`get_tsl l_jade_flash >= 0x80`), `jsrp do_zap` (index 022h = the flash)
  instead of the normal dodge.

## Testing lessons (harness)

`tools/jade_boomerang_test.lua` + `run_jade_boomerang_test.ps1`, three modes
(`JADE_MODE=jade|kitana|dronejade`):

- **Selecting Jade:** the select screen won't take char 16 directly. Pick
  Kitana during `GS_PSEL`, then overwrite `p?_char = FT_JADE` during
  `GS_POST`; the fight creates Jade. Verify `p?_char` right after
  `GS_FIGHTING` and fail fast if the overwrite didn't take.
- **Player moves test deterministically** and are the real proof: `jade`
  mode asserts the boomerang (auto-aim + 24 damage + recovery), Flash
  (free-move + cooldown gate + reuse), and nitro; `kitana` mode asserts the
  same inputs are now **dead** on Kitana and her spin chop still works.
- **Drone emergent behavior is RNG-dominated and NOT reliably reproducible**
  in this harness: MK2's RNG advances with menu-navigation frame timing,
  which jitters slightly each boot, so whether the drone engages vs. spaces
  away varies run-to-run. The drone's boomerang/Flash/nitro were each
  **observed firing** (boomerang r=1884, Flash r=695 & r=922, nitro r=262)
  but a given run may show none. The `dronejade` mode therefore **requires**
  only the deterministic fact (drone never falls back on Kitana's fans) and
  logs the emergent behaviors as observations. Don't gate CI on emergent AI
  timing.
- Idle `p_action` reads `0x303`/`0x000`, **not** 0 — a "recovered to idle"
  check must use position-stability + "not `act_reacting` (0x503)", not
  `== 0`.
- Reptile bleeds **green** by stock rule (`reptile_blood_pal`/`BLOODG_P`) —
  green blood in a Reptile-victim screenshot is not a palette bug.

## For Noob Saibot (ft_noob = 15) — checklist

Noob shares the ninja base, so most of the above applies directly:
1. Add Noob's handlers to **all** `char_*` / `char_*_open` / `char_joy*`
   tables at index 15 (they're already padded — replace the `sucide`).
2. Give Noob a real `*_anitab2` row (index 15) if any move uses
   `get_char_ani2`; don't alias another character's table.
3. Strike records: reaction byte high-nibble = slot in **Noob's**
   `react_to_nj` (currently index 15 in `reaction_tables`) — add reaction
   handlers there, don't reuse a wrong slot.
4. Drone: `zap_offsets[15]`, `ochar_drone_start[15]` (currently
   `drone_entry`), and any `drone_beware` special-case.
5. Grep every `ft_noob` before assuming a trait lives in one place.
6. Test the player moves deterministically; treat drone emergent behavior as
   observation.
