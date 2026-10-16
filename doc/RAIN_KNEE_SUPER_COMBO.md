# Rain's knee → super roundhouse combo

Rain (`ft_rain` = 19) links his close knee into MK Trilogy's super roundhouse
with **Back + High Kick**. The link is timed the way UMK3 and Trilogy time a
combo link (`process_combo_table`). This doc covers how that works, where the
code is, and the UMK3/Trilogy source it copies.

Rewired 2026-09-22 (the user's call). Before that, the link was Back + HK + LK
and could fire at any tick. That version always came out, but the carry-on
started at different times and so felt unevenly paced. The **Why** section
says why.

## What the player does

1. Throw the ordinary knee: HK or LK, close.
2. Hold **Back** and press **High Kick**, at any time from the knee starting
   to 9 ticks after it lands.
3. The knee carries on into the super. A clean link does 16 + 11 = **27**,
   and the victim wraps.

Without the link, you get the stock ninja knee (16), unchanged. You also get
the stock knee if Back isn't held, if the press is too late, or if the super
is still on its cooldown (`rain_rh_cool`).

## The timing

The UMK3/Trilogy model (in `MKCOMBO.C`, `process_combo_table`):

```
knee lands (strike_check hits)
  clear_combo_butn          <- presses made before this are forgotten
  sleep 3                   <- ticks 1-3 never fire (a press is remembered)
  scan every tick to c_time <- fire on the first tick with the input
                               (c_time = 9 in ct_rain_knee5)
  success: stop_him, play the next part at ONE speed (mframew(c_speed)),
           strike check at the end
  too late: sleep 5, retract
```

Ours (`rain_knee`, [src/MOVES.ASM](../src/MOVES.ASM)):

| Phase | Ticks | Constant / source |
|---|---|---|
| Knee wind-up, NJKNEE1-2 | 3 a frame | `do_knee`'s speed |
| Knee active, NJKNEE3 | 2 | `stk_njknee` (00eh) |
| Window: can't fire | ticks 1-3 after contact | `RKN_WIN_SKIP` = 3 |
| Window: fires on first tick with Back + HK | ticks 4-9 | `RKN_WIN` = 9 |
| No link: rest of the stock hold, then retract | `knee_hit_sleeps` (20), retract at 6 | unchanged from stock |
| Carry-on up to the contact frame | 2 a frame | `RSK_SPEED` |
| Contact frame NJROUNDKIK5, live | 3 | `RSK_ACTIVE`, `nj_stk_rainrh` |
| Hit hold | 5 | Trilogy's 5 |
| Recovery NJROUNDKIK4-1 | 3 a frame | `RSK_RECOVER` |

Rules worth knowing:

- **Presses are counted from the tick the knee started.** The press that
  started the knee is excluded. So a Back + HK made during the knee's
  wind-up still links, but it fires on tick 4, not early. This is the one
  place we're more forgiving than UMK3, which forgets presses made before
  contact.
- **Back is tested at the moment the link fires** (Trilogy's `req_stkaway`),
  not when HK was pressed.
- **A whiffed knee** has no hold to put a window in. It links only if
  Back + HK is already in when its active ticks end. A blocked knee gets the
  window like a hit.
- **The window sits inside the stock 20-tick hold**, so an unlinked knee has
  exactly the stock recovery. Frame advantage and balance didn't change.
- **A CPU Rain never links**: the drone presses nothing, so the button queue
  has no High Kick for it to find.

## Why the pacing used to vary

1. **The start tick floated.** The old code fired on whichever tick the input
   arrived, anywhere from the knee's own frames to the end of the 20-tick hit
   hold. So the carry-on could start straight away or after a long pause on
   NJKNEE3.
2. **The holds were uneven.** The carry-on used the WAX's per-frame holds,
   3,2,1,1,1,1 then 3,3,3,4,4. Four 1-tick frames flashed by, then it slowed
   right down.

UMK3 fixes both: a fixed window, and one speed per part.

## Code map

| What | Where |
|---|---|
| Knee, combo window, link test | `rain_knee`, `rain_knee_ask` in [src/MOVES.ASM](../src/MOVES.ASM) |
| Carry-on, strike, recovery | `rain_super_knee` in MOVES.ASM |
| Pinning the victim during the carry-on | `rsk_pin` (MOVES.ASM): only after a CLEAN knee (bit 30 of `a10`) |
| The frame lane | `a_rain_suprh`, `rain_anitab2` row 0ch in [src/MKNJ.ASM](../src/MKNJ.ASM) |
| Lane generator | `tools/rain_suprh_wax_import.py`, from `data/RAINSUPROUND.WAX` (Phase D `--check`) |
| Strike record | `stk_rain_roundh`, nj_strikes 21h |
| Victim's flight and wrap | `r_rain_roundh` (MKREACT, react_to_nj 1ch), `rain_rh_scan` (MKPROP) |
| Cooldown shared with his Back+HK super | `l_roundh` / `rain_rh_cool` |
| Standalone super: Back + HK + LK from roundhouse range (unchanged) | `rain_roundhouse`, `rain_rh_pair`, `rain_rh_due` (MOVES), JOY's `joy_sweep_kick` hook |

`a_rain_suprh` is still frame/hold **pairs**, as the importer generates them.
`rain_super_knee` shows each frame and steps over its hold (`addi 32,a9`);
the `RSK_*` constants set the pace. So **editing hold values in the WAX no
longer changes the timing**, but editing its frames does. Never hand this
lane to `mframew`: the hold longs would be read as frame pointers.

## Traps

- **Buttons are off for the whole knee.** A button table can't see the
  link, so the knee is played a tick at a time instead of through `striker`,
  and the link reads the button-close queue (`get_bcq_next_pointer` /
  `previous_q_entry`). `queue_and_jump` fills that queue for every press,
  whatever the button table says.
- **Only a8-a11 survive a sleep.** `a10` carries the knee's start tick (low
  half) and the clean-hit flag (bit 30). `a11` is the tick counter.
  `rain_knee_ask` saves every register it touches, because it's called from
  inside those loops.
- **ibuf:** the HK that links the super was a refused press, so it can be
  parked in `p1_ibuf`/`p2_ibuf`. `rain_super_knee` clears it; otherwise it
  would come back as a kick when the super ends.
- **Without the pin, the super whiffs.** The knee's reaction,
  `stumble_back`, slides the victim 3 px a tick. `rsk_pin` has to zero
  both `set_x_vel` (the request) and `oxvel`, because repell rewrites
  `oxvel` from the request every tick. It's keyed on `a10` bit 30, not the
  victim's `p_action`, because `stumble_back` never leaves 0303.

## Testing

```
.\tools\run_rain_roundhouse_test.ps1        # 11 tests, PASS/FAIL per test
```

Knee tests park Rain 40 px from Jax and tap HK at d=0..3. The knee lands
around d=9. `link` is when the linking HK comes, with Back held from
link-3 to link+8:

| Test | Link | Expected |
|---|---|---|
| super | 8 (before contact: remembered) | 27, wraps |
| hold | 14 (inside the window) | 27, wraps |
| late | 22 (after the window) | stock knee, 16 |
| nobk | 8, no Back | stock knee, 16 |
| knee | none | stock knee, 16 |
| cool | 8, `l_roundh` stamped first | stock knee, 16 |
| bhk | Back + HK on its own | 14 + wrap - **his roundhouse IS the super** |
| brh | Back + HK + LK | 14 or 20: two kicks on one tick reach one handler |

The negative tests are what prove the link works properly. A rig that only
checked "the super came out" would pass on a build where every knee
became the super.

## UMK3 / Trilogy source reference

These are on disk; see also `reference_umk3_source_tree` in memory.

- `UltimateMortalKombat3/.../src/MKCOMBO.C`: `do_knee`,
  `process_combo_table`, `combo_scan_a11`. UMK3's arcade release has no
  Rain, but its combo engine is identical to Trilogy's.
- `MKTRILOGY_source_N64/MKTRIL~1/SEG/GAMECODE/MKSCOMBO.S`: the tables.
  `ct_rain_knee2..5` chains knee → HK → LK → HK, then `ct_rain_knee5`:
  `9|last_option, cb_jump_address, cb_hikick, retract_hikick, req_stkaway`
  → `do_roundhouse`. Fields: `c_time` (window ticks), `c_attack`
  (`AAPP`: anim row, part; bit 0x80 = TABLE2), `c_speed` (`SS00|button`),
  `c_retr`, `c_stk|c_req`, `c_next`.
- `.../GAMECODE/MKSTAT.C` `stat_do_roundhouse`: for `FT_RAIN`, the super
  is `striker(..., 2, ACT_RHOUSE, ANIM_RHOUSE, 3, 0x1f)`, hold 5,
  `retract_strike(3)`. It is used when `l_roundh` > 0x50, or when the
  opponent wasn't just hit by a roundhouse. Otherwise it's the plain
  roundhouse. In Trilogy, Rain's ordinary Back + HK is usually the super.
- `striker(index, anispeed, act, anim, framecnt, stk)`: `anispeed` = ticks
  a frame, `framecnt` = active ticks.

### Also looked up: the summon's return (Rain's bolt pose)

Rain's bolt cast borrows Ermac's slam pose (`ANIM_ERMAC_SLAM` = ninja
TABLE2 0x0c). UMK3 (`stat_do_ermac_slam`) and Trilogy (`stat_do_rain_bolt`)
go up on `animate2_a9(2, ...)` and come down on `backwards_ani2(2, ...)`.
`bani2` walks **every** frame back to the first, 2 ticks each. It is **not**
a single block frame. The shipped lane in `umk3.zip` (male ninja anitab2
0x0c, byte 0x28e34) has 5 frames: **SCSUMMON5-9** (SCORP9.IMG). SCSUMMON1-4,
a crouched wind-up, is authored but used by no lane. Ours does the same
thing with MK2 art: `a_ermac_teleslam` (NJELBO1, ERELBO2, ERHIPUNCH7,
ERTELESLAM3) up, then backwards, at `rain_bolt_wind` = 2.
