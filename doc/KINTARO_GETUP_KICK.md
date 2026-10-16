# Kintaro's get-up kick (GETUPKIK)

Kintaro rises off the floor straight into a kick instead of just standing up.
It is the `GETUPKIK` sequence the artist authored in `data/TIGER3.IMG` and that
never got any code.

## Where it came from

`TIGER3.IMG` carries IMGTOOL sequence-editor records after the image table.
Fourteen of them survive; one is named `GETUPKIK`, at file offset `0xEED64`.
Each record is a 16-byte name, a second string, `40 00`, a 16-bit frame count,
15 dwords of dead editor pointers, a `0a00 0a00 ffffffffffff` trailer, and then
the frame list at an 18-byte stride starting at `count+0x52`.

Each frame entry is `u16 image index, u8 hold, u8 junk`. The hold is `01`
almost everywhere; the junk byte is uninitialised editor state and must not be
read as timing — it is `07` on every row of both TURN records but
`2d,08,19,00,21,06,…` on STOMP. (Reading it as the hold is the mistake that
first put "TIGERKICK4 held 0x30" in this file.)

`GETUPKIK` has 11 entries. **The list is stored newest-first, so it plays in
reverse file order** — `a_goro_stomp` in `src/MKGORO.ASM` is `TIGERJUMP1,2,3,4`
ascending, and only the reversed reading of the `STOMP` record produces that;
the same reading turns the `TURNT` record into `TIGERTURN1..4`. Read that way,
`GETUPKIK` is:

```
TIGERGETUP1[01] TIGERGETUP2[01] TIGERGETUP3[01] TIGERGETUP4[01]   <- rise
TIGERKICK1[01]  TIGERKICK2[01]  TIGERKICK3[01]  TIGERKICK4[02]
TIGERKICK3[01]  TIGERKICK2[01]  TIGERKICK1[01]                    <- retract
```

**One cadence across both halves**, with only the extended pose held double —
the same shape as `PUNCH`'s `TIGERPUNCH3[02]` and `DIE`'s `TIGERDIE6[0a]`. The
absolute numbers are editor preview ticks, not game ticks (11 rows in 12 ticks
would be the whole move in 0.22s); what carries over is the ratio.

Those two halves are already in the ROM as separate animation tables:
`a_goro_getup` (ani `00bh`) and `a_goro_kick` (ani `004h`), and `a_goro_kick`'s
part one is exactly `TIGERKICK1..4` with the retract after the terminator —
which is the shape `striker` wants. So the move needs **no new animation
table**: it chains the two lanes the artist chained.

Both of the authored "doubles" survive that chaining for free. `a_goro_getup`
already lists `TIGERGETUP4` twice, so it is 5 rows and ends on a held standing
pose; and `striker`'s `a10` holds `TIGERKICK4` for 4 ticks against its
neighbours' 3. Running **both halves at sleep 3** is what makes the cadence
uniform the way `GETUPKIK` has it — and 3 is also exactly what `boss_getup`
already plays `a_goro_getup` at.

## The art was loaded but effectively never drawn

`a_goro_kick`'s only other caller is `rt_goro_close` (`src/MKBOSS.ASM`), and
`goro_stalk` can barely reach it:

- `goro1` loops while the gap is `> 060h`, so it only falls out when the gap is
  `<= 060h`.
- `goro4` then re-tests **the same distance** and takes `goro_uppercut` on
  `<= 060h`. Nothing between the two tests sleeps, so the distance has not
  changed and the uppercut is taken every time.
- The one live route is `goro_air_wait` -> `stance_wait_yes` (which does sleep)
  -> a 5% `goro_mean_check` -> the opponent having drifted back outside `060h`
  in the meantime -> a 50/50 against `goro_punch`.

**This has not been changed.** Re-banding `goro4` would swap uppercuts (40
damage) for kicks (53) in his normal offense, which is a balance change nobody
asked for. It is a one-line knob if that is ever wanted.

## Implementation

| Piece | Where |
|-------|-------|
| `goro_getup_kick` | `src/MKBOSS.ASM` — the move |
| `goro_getup_kick_check` | `src/MKBOSS.ASM` — the gate; `.global` in `src/MAINEQU.ASM` |
| `diff_getup_kick` | `src/MKBOSS.ASM` — per-difficulty chance |
| hook (the one that fires) | `src/MKREACT.ASM`, `goro_fall_on_back` |
| hook (the other get-up site) | `src/MKDRONE.ASM`, `boss_getup` |

The move is `init_special`, then `animate_a9` on `[sleep 3 | ani 00bh]` for the
rise, then `striker` with `a0=3, a9=4, a10=4, a11=1` (`stk_goro_kick`), then the
stock `goro_post_strike` tail.

Timing, measured off the rig's own breadcrumbs rather than counted by hand:
**15 ticks of rise** (5 rows x sleep 3, `7102` -> `7103`) then **12 ticks of
swing** (4 rows x sleep 3) before the box opens for `a10` = 4. 27 ticks, just
under half a second at 54.7 Hz. Nothing may sit between `striker` and
`goro_post_strike`: the carry is the hit/miss answer, which is why the "he is
swinging" breadcrumb is written *before* the swing.

### Two get-up sites, and only one of them matters

`boss_getup` (reached through `drone_getup`) looks like the get-up site and is
not the one an uppercut uses. `fall_on_my_back` sends every boss to
`goro_fall_on_back` in `MKREACT.ASM`, which plays ani `00bh` inline and exits at
`local_reaction_exit` — `boss_getup` is never entered. The first version of the
rig hooked only `boss_getup` and read "Kintaro was never knocked down" while he
was being knocked down 20 times a round. Both sites are hooked now;
`c_kahn_rg_n` (bumped by `kahn_reground_check` at the top of `boss_getup`) is
what tells them apart in a log, and it stays at 0 across a whole uppercut round.

`local_reaction_exit` and `drone_reaction_exit` are both `jauc reaction_exit`,
so the move's own tail is a legal exit from either site.

### The gate

```
ft_goro only                      Shao Kahn shares boss_getup and has no such art
winner_status == 0                no wake-up kick during FINISH HIM or a decided round
get_x_dist <= 060h                otherwise he swings at someone who walked away
ask_mr_diff diff_getup_kick       0,0,0,150,200,250,300,350,400,500
```

`check_stay_down` runs *before* the gate at both sites, so a losing Kintaro is
already gone to `wait_forever` and never reaches it.

The box does not open for 27 ticks. That is deliberate: it is a reactable wake-up
attack, not a reversal. Measured outs for the player, both confirmed by the rig:
duck it (a run where P1 held Down took 3 swings and 0 damage), or leave — past
`060h` the gate declines and logs `7100`.

## Breadcrumbs

Every branch writes `@debug4` so a rig can tell the four outcomes apart, and so
that "the kick animation played" is never used as the evidence (`a_goro_kick`
has another caller):

| value | meaning |
|-------|---------|
| `7100` | refused — opponent out of reach |
| `7101` | in range, `ask_mr_diff` said no |
| `7102` | TAKEN — jumping to `goro_getup_kick` |
| `7103` | the kick half is swinging (`striker` armed) |

## Rig

```
tools\run_kintaro_getup_kick_test.ps1            # default: diff 9, 5400 fight frames
tools\run_kintaro_getup_kick_test.ps1 -Diff 4
```

Forces P1 = Liu Kang / P2 = Kintaro, pins P1 on top of him and uppercuts on a
40-frame loop, freezes the round clock, and pins both bars so the round never
ends. When the gate takes the move it stops holding Down for 45 frames so the
kick has something at standing height to hit. It snapshots the swing and again
13 ticks later, on the frame the box is live.

Result at diff 9 (2026-09-09):

```
p1_hits_landed=25 boss_getup_calls=0 gate_ran=11 out_of_range=0
roll_declined=4 taken=7 swings=7 hits=7 damage=371
PASS: get-up kick fired 7 times, connected 7, 371 damage total
```

Every `7102` -> `7103` gap in that log is 15 frames and every hit lands at
`rel=12`, which is the 15 + 12 above confirmed rather than assumed.

53 damage a hit, which is `stk_goro_kick` unmodified — his kick's own record,
untouched. `tools\run_battle_stability_sweep.ps1`: 25/25 PASS, including
`kintaro_p2_arena` and `kahnboss_p2_arena`.
