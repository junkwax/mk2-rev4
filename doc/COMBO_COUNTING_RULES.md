# What counts as a combo hit

`cmbrules` (MAINEQU.ASM). Read against UMK3's C source at
`C:\Users\you\Workplace\UltimateMortalKombat3\...\src\`, which writes arcade
literals and scales them at compile time — a bare number there is the arcade
number.

MK2 retail has no combo counter to get wrong: `p_hit` existed only to feed the
jab-separation check. Two things now read it that retail never did — `dmgscale`
(MAINEQU.ASM) and the KOMBO KOUNTER readout (`hudcmb`, MKDISP.ASM) — so what
does and does not count became visible, and MK2's answer was "everything".
UMK3's answer is narrower.

## UMK3's counter

One byte on the **victim**, `pdata.p_hit` (`MKOS.H:73`).

| event | UMK3 | where |
|---|---|---|
| any reaction starts | `p_hit++` | `reaction_start_chores`, MKREACT.C:3234 |
| a hit is **blocked** | `p_hit++`, then `p_hit = 0`, then `p_block++` | `reaction_start` REACT_BLOCK, MKREACT.C:2619 |
| victim reaches neutral | show `N HIT COMBO` if `p_hit >= 2`, then `p_hit = 0` | `back_to_normal`, MKUTIL.C:63 |
| victim lands | `p_hit = 0` | `gravity_ani`, MKUTIL.C:2206 |
| blockstun ends | `p_hit = 0`, `p_block = 0` | `block_exit`, MKREACT.C:3549 |
| FINISH HIM dizzy | `p_hit = 0` | `dizzy_dude`, MKCANNED.C:287 |

So a combo is **two or more hits taken without the victim reaching neutral,
landing, or blocking.** Nothing is a timer.

### The six reactions that hand the hit straight back

`dec_my_p_hit` → `decp3` (MKUTIL.C:167), which **refuses to go below zero**:

| reaction | what it is | line |
|---|---|---|
| `r_hi_punch` | ordinary standing High Punch | MKREACT.C:2027 |
| `r_lo_punch` | ordinary standing Low Punch | MKREACT.C:2059 |
| `r_freeze` | Sub-Zero's ice ball | MKREACT.C:4540 |
| `r_net` | Cyrax's net | MKREACT.C:869 |
| `r_scream` | Sindel's scream — *"scream does not = hit"* | MKREACT.C:1183 |
| `r_ermac_slam` | the second beat of the telekinetic slam | MKREACT.C:291 |

Plus two hand-rolled corrections: the last punch of Jax's gotcha grab
(`dec_his_p_hit`, MKSTAT.C:1233 — the throw that follows counts instead), and
Sonya's scream on contact (MKSTAT.C:1696).

**Everything else counts.** Kicks high and low, duck punch, both duck kicks,
sweeps (`r_sweep`, `r_stick_sweep`), roundhouses, uppercuts, flip kicks,
every special, every `r_combo*` dial-a-combo reaction, and throws — which
bump `p_hit` by hand because they never go through `reaction_start`
(MKSLAM.C:1013/1036/1051, MKPROP.C:3615).

### The punches count somewhere else

They do not merely un-count themselves. `r_hi_punch` and `r_lo_punch` open with
`inc_p_block` (MKREACT.H:271), and the separation check that pulls a jab loop
apart — `ccp3` (MKREACT.C:2364), our `punch_stumble_check` — tests **`p_block`,
not the hit count**:

| move | hits, stick held | hits, stick pulled away |
|---|---|---|
| High Punch | 6 | 4 |
| Low Punch | 5 | 3 |

MK2 already carries those literals. `p_block` is also what blocks feed, and
`back_to_normal` / `block_exit` clear it with `p_hit`, so only a genuinely
*linked* run of jabs accumulates it.

UMK3 keeps two doors onto that check and MK2 should too: `avoid_corner_trap`
reads `p_hit` (generic and boss reactions), `avoid_corner_trap_b` reads
`p_block` (punches and blocks).

### Guardrails that read the hit count

Refuse a special when the man is already N hits deep. `get_his_p_hit`
(MOVES.H:556), all in MOVES.C:

| N | moves |
|---|---|
| `>= 1` | Kitana's fan lift, Sub-Zero's decoy |
| `>= 2` | Smoke's teleport, Sektor's teleport, floor ice, forward ice blast, Jade's staff, Cyrax's bombs, Tusk blur (`> 1`) |
| `>= 3` | Sindel's scream, floor blade, Cyrax's net, Mileena's roll |
| `>= 4` | Reptile's forceball (`qorb3`), Ermac's slam (`> 4`) |
| `>= 5` | Scorpion's teleport, the spear |

MK2 already ports this pattern: `rain_bolt_maxhit` 3, `rain_zap_maxhit` 4.

### Damage, separately

`p_damage` accumulates on the victim (`add_combo_damage`, MKUTIL.C:145), **chip
included** (`bar_reducer` is called for blocked hits too, MKJOY.C:1799), and is
reported as a percentage of `FULL_STRENGTH` beside the hit count.

UMK3's per-hit scaling is **not** a curve on the count — it is two object flags
the attacking move sets on the victim, `M_HALF_DAMAGE` / `M_QUARTER_DAMAGE`
(MKOBJ.H:72), consumed in `bar_reducer` (MKJOY.C:1997) and cleared by
`back_to_normal`. Note both shift by 2, so "half" is a quarter — that is the
shipped behaviour, not a transcription slip. Two moves scale off the count
directly instead: Sonya's leg throw and `r_zoom_flipped` pay full at
`p_hit <= 3` and a quarter above it (MKSTAT.C:943, MKREACT.C:850), and one
combo-table requirement slot arms half damage once `p_hit >= 3`
(`set_his_half_damage`, MKCOMBO.C:531).

MK2's `dmgscale` — full, 3/4, 1/2, 1/4 by position in the string — is this
project's own curve, not UMK3's, and is unchanged here.

## What `cmbrules 1` changes in MK2

New byte counter `p_pblock` (`pdata+288h` — the last free byte in `pdata`,
above `p_scalebias`), UMK3's `p_block`.

| | before | after |
|---|---|---|
| plain HP / LP lands | `p_hit++` | `p_pblock++`, `p_hit` given back |
| jab separation check | reads `p_hit` | reads `p_pblock` (`pblk_stumble_check`) |
| boss hit paths (`kahn_hit_0/1`), Liu Kang's chain | `p_hit` | `p_hit` — unchanged |
| `p_pblock` cleared | — | with `p_hit`: `back_to_normal`, `block_exit`, `gravani`, `dizzy_dude` |

Reactions `02h` and `03h` of every `react_to_*` table are the ones affected —
each fighter's standing High and Low Punch, plus Shao Kahn's spear (`02h`) and
his over-the-top hammer (`03h`). 20 of 236 strike records. Liu Kang's chain is
`19h` (`r_lk_chainstun`), not `03h`, so its 20 + 11 + 16 is untouched.

**It cuts both ways.** A linked jab string stops showing a hit count and stops
paying `dmgscale`'s 3/4 – 1/2 – 1/4, so jab pressure does *more* damage than it
did. What bounds it is the separation check, now fed by a counter only jabs and
blocks touch, so it measures the jab loop exactly instead of whatever mix of
hits happened to reach the victim. `cmbrules .set 0` restores the old
behaviour for an A/B.

## Measured

`tools/run_combo_count_test.ps1` → `tools/combo_count_test.lua`. **5/5 PASS, 0 NO
VERDICT**, on the build of 2026-09-26. Jax is P1 at a gap of **70 px** for every
trial, so one harness produces a jab, a body punch and a kick.

| trial | hits | damage | victim `p_hit` peak | `p_pblock` peak | `cmb_hits` |
|---|---|---|---|---|---|
| `jab1` one High Punch | 1 | 11 | **0** | **1** | 1 |
| `jabs` seven taps, six linked | 6 | 11+11+11+11+11+11 | **0** | **6** | 1 |
| `kick` one High Kick — the control | 1 | 32 | **1** | **0** | 1 |
| `mixed` HP, HP, High Kick | 3 | 11+11+32 | **1** | **2** | 1 |
| `lopun` one Low Punch | 1 | 8 | **0** | **1** | 1 |

Three independent signals, so no one of them can carry a false pass:

- **`p_hit` peak.** A jab's inc and its dec both land before `animate_a9`'s
  first sleep — inside one tick — so a jab can never be caught at 1. A kick
  reads 1 until `back_to_normal`. The `kick` row is the inverse of the `jab1`
  row on the same harness in the same fight, which is what separates "jabs are
  excluded" from "the counter is broken": both would read zero.
- **Damage.** Six linked jabs at **11 each**. Before `cmbrules` the second
  would have been `dmgscale`'s 3/4 = 8 and the third 1/2 = 5, because `p_hit`
  climbed. Six 11s is positive proof `dmgscale` never saw the string — no
  second ROM needed.
- **`cmb_hits`.** A six-jab string holds it at **1**, below `hudcmb_min` 2, so
  no readout appears: each jab opens a *new* string, because `hud_combo_hit`
  reads the victim's `p_hit` and a jab always leaves it zero. The kick moving
  it to 1 is what calibrates the detector — without that, "no readout" would
  pass just as well on a build where the KOMBO KOUNTER was switched off.

`mixed` is the rule in one line: two jabs and a kick land, `p_pblock` is 2, and
`p_hit` is **1** — only the kick counted.

### The separation still fires, and the jab that trips it keeps its hit

The seven-tap string drives `p_pblock` to 6 — `punch_stumble_check`'s
stick-**held** threshold for a High Punch — and the players separate: measured
distance 70 → **150**.

On that one jab `p_hit` ends at 1, and that is correct in both games.
`pblk_stumble_check` does `pull a0 / jruc separate_us`, so the `dec_my_p_hit` on
the next line never runs. UMK3 is identical by construction: `ccp3` is
`reaction_start`'s corner routine, so it runs *before* `r_hi_punch`'s own
`dec_my_p_hit`, and its `stumble_back_vel` → `reaction_exit` never returns
either. The stranded count lives only for that reaction — `back_to_normal`
clears it. Asserting `p_hit == 0` across the whole window instead reported FAIL
on a correct ROM, which is why the rig samples `p_hit` only below the threshold
and reports `p_hit_after_sep` separately.

**Two rig traps worth keeping.** MK2 swaps in CLOSE variants: `elbow_check` and
`knee_check` (JOY.ASM) both bail only when `x_dist > 040h`, so the first cut at
46 px measured Jax's **elbow** (24 damage, reaction `0Fh`) and **knee** (16,
`0Eh`) — reactions `02h`/`03h` never fired and the rig failed a correct ROM.
And `read_u16` aligns *down* to a 16-bit boundary, so it cannot read `p_pblock`
at `0x388`: it would return `p_scalebias`. Use `read_u8`.

## A long HOLD has to be added to `cmb_holds` by hand

`cmb_tick` is `hudcmb_hold` = **64 ticks** and only a HIT re-arms it, so any
move that holds a man longer than that loses the readout it was holding and the
next hit opens a fresh string. `cmb_holding` (MKDISP.ASM) pauses the clock
while the victim is in one of those states, read off his `p_action` against the
`cmb_holds` table — and **nothing derives that table**. Adding a hold to the
game and not to the list is silent: the hold works, the catch works, and only
the counter underneath is wrong.

That is exactly how RAIN's storm cloud shipped. Reported 2026-10-01 as
*"Rain's projectile move doesn't hold a combo when the opponent is still in the
air"*: `r_rain_zap` holds the victim for 6 half-shakes at 3 ticks plus 2 at 7
= **exactly 64**, against a 64-tick window, and `act_rain_storm` (050Eh) was
not in `cmb_holds` because the cloud is one move newer than the table.

**It could only be seen in the air, and that is the general shape of this bug.**
`hudcmb_min` is 2, so a cloud thrown at a man on his feet is the *opening* hit
of its own string and puts no readout on screen to lose. The only way it lands
as hit 2 or later is to catch somebody already juggled — so the symptom needs
both the hold *and* a live string, and a rig that throws the move from neutral
measures nothing wrong.

Rig: `tools/run_rain_zap_combo_test.ps1` (2/2). `-Negative` patches
`act_rain_storm` back out of `cmb_holds` **in the built ROM** — one word, by
content search, via `tools/rain_zap_combo_negrom.py`, so the control needs no
second build — and the trial must FAIL; measured losing 41 of the 64 ticks.
The `pinnedair` control is what makes the pause specific: the same victim
pinned airborne in plain `act_reacting` must still run the clock to 0, or
"frozen" would only mean the clock never runs for a man off the ground.

Three traps in measuring it, each of which reads as the bug itself:

- At the cloud's own throwing range a setup Low Kick does not reach, so the
  cloud opens its own string and there is nothing to break.
- **Below `hudcmb_min`, `cmb_fly` is never created — and `cmb_fly` is what
  DECREMENTS `cmb_tick`.** A 1-hit string therefore leaves the clock parked at
  64 forever, which a probe reads as a perfect pause.
- `p_hit` returns to 0 the moment the victim recovers (`back_to_normal`), and
  `hud_combo_hit` calls `p_hit == 0` a NEW string whatever the clock says. So a
  setup hit only chains while he is still in a reaction — which is what pinning
  him off the floor buys: `reaction_exit` sends an airborne man to
  `fall_on_my_back`, and he cannot land to end the string.

The cloud does **not** also get `p_scalebias`. The three moves that have it are
setups whose next hit is guaranteed; the cloud ends on its own with the victim
dropped and recovering, and `back_to_normal` has already cleared `p_hit` by
then, so the hit after it is an opening hit and lands for full anyway.
## Deliberate divergences

- **The freeze, the spear and the puddle stay on `p_scalebias`.** UMK3
  un-counts a freeze outright; this tree discounts it — and the spear's ~15
  bogus drag hits, and `stk_floor_ice`'s zero-damage hit — so the free hit
  after a hold lands for full while the readout still tells the player what hit
  him. Measured by `tools/run_spear_dmgscale_test.ps1`.
- **`dmgscale` is kept.** UMK3 scales by flags the move sets, not by position
  in the string. Porting that would mean per-move data MK2 has nowhere to put.
- **Kintaro's `goro_block_0..5` still adds its own `inc_p_hit`** on top of
  `blocked_start_chores` (MKREACT.ASM:679), escalating into
  `stop_abusive_attackers` at 7. Retail MK2's own, and no UMK3 counterpart.
