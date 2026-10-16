# Liu Kang's double knee — an MK3-style chain

> **2026-10-05 - the double knee now KICKS HIM DOWN, and the HP backfist link
> is gone.** Authored in `data/KANGDBLKNEE2.WAX`. The sections below describe
> the chain as it was before; what changed:
>
> - **The second knee drives him into the floor.** On `LKDUBLKNEE3` the victim
>   takes `r_lk_spiked` (MKREACT, `lk_rct_spike` 1ah) -> `lk_spike` (MKLKDK):
>   his own SWEEP FALL - anitab1 016h part 1 row 0, part 1 row 3, part 2's flat
>   frame (= Liu Kang's FALL1/4/5), 4 ticks each, at the WAX's x off Liu Kang's
>   anchor and the WAX's y off his OWN floor. The ground rumbles on the flat
>   frame, then he bounces in place through `flight` (-060000h, 08000h: 37 px,
>   0 px drift). A real y velocity, so a follow-up can JUGGLE him - a
>   crouching HK catches him at +62 and its own reaction carries him off; an
>   uppercut does not reach the ~74 px he lies at. With no follow-up he lands
>   with a thud and takes the SWEEP get-up facing Liu Kang (`lk_spike_up`).
> - **The first knee is retail's launch again** (`stk_lkknee` `0e0eh`,
>   `r_hhknee`) - unless the second High Kick is already in when it lands,
>   in which case it tests `stk_lkknee_link` (the chain's standing stun). A
>   launched man is ~110 px off by the time the carry-on comes out, so the
>   choice has to be made at contact: a quick double tap spikes, a single,
>   late or cooled-down press launches.
> - **LKBACKFIST1 is his recovery**, not a chain window. 20 + 11 = **31 over
>   2 hits**.
> - An earlier cut the same day (`data/KANGDBLKNEE.WAX`, unused now) drew him
>   on KD6/KD7 upside down with a face-down bounce; KNEE2 replaced it.
> - Rig: `tools/run_lk_dubknee_test.ps1 -Package [-Victim N]` - `dubk`, `jugl`
>   and the `knee` / `late` / `cool` launches; 5/5 on Jax, Kitana, Baraka,
>   Sub-Zero, Shang.

Liu Kang's close knee chains into a **double knee** and then into his
**backfist**. The art is `DUBLKNEESQ`, a sequence Midway embedded in
`data/KANG3.IMG` in 1993 and never coded; its sprites were deleted from the
ROM in 2026 as dead art and are back. The links are timed the way UMK3 and
MK Trilogy time a combo link (`process_combo_table`), the same machinery
[RAIN_KNEE_SUPER_COMBO.md](RAIN_KNEE_SUPER_COMBO.md) describes.

Built 2026-09-23. `lkdknee .set 0` (MAINEQU.ASM) compiles the chain out.

## What the player does

A dial-a-combo in the MK3 sense — **HK (close) → HK → HP**, each press
dialled in, each link landing on a fixed beat:

1. Throw the ordinary knee: **HK or LK, close** (`knee_check`, within 64 px).
2. Press **High Kick** again, any time from the knee starting to 9 ticks
   after it lands → the double knee.
3. Press **High Punch** any time during the carry-on → the backfist.

**20 + 11 + 16 = 47**, three hits. Stop after step 2 and it is 31; don't link
at all and it is the stock knee, 20.

Step 3 works because of where the authored sequence stops. `DUBLKNEESQ` ends
on `LKBACKFIST1`, which is the first frame of `a_lkbackfist` — the artist left
the handoff into the backfist sitting in the art, and the chain takes it.

No direction is held. That is MK2's own grammar for a second knee, the one
`do_knee` already gives Baraka (`bt_2nd_knee` / `do_2nd_knee`).

## The authored sequence, and the tick conversion

`python tools/lk_dubknee_seq_import.py --dump` reads it out of the IMG:

| # | frame | preview hold | game ticks |
|---|---|---|---|
| 1 | LKKNEE1 | 1 | 4 |
| 2 | LKKNEE2 | 1 | 4 |
| 3 | LKKNEE3 | 3 | 12 |
| 4 | LKDUBLKNEE1 | 1 | 4 |
| 5 | LKDUBLKNEE2 | 2 | 8 |
| 6 | LKDUBLKNEE3 | 1 | 4 |
| 7 | LKDUBLKNEE4 | 1 | 4 |
| 8 | LKBACKFIST1 | 1 | 4 |

The first three frames **are** `a_lkknee`, which is why the move is the
ordinary knee plus a carry-on rather than a special of its own. The generator
skips them; `lk_knee` plays them at retail's own speed so an unlinked knee is
unchanged. The carry-on is the other five: **24 ticks**.

**A seqscr hold byte counts PREVIEW ticks**, and one preview tick is
`round(54.7 / fps)` game ticks — see
[IMGTOOL_LANE_CONVERSION.md](IMGTOOL_LANE_CONVERSION.md) and the note in
CLAUDE.md that "authoring at 13.675 or 27.35 fps makes the preview match the
game exactly". DUBLKNEESQ is authored at IMGTOOL's **13.7 fps**, so one
preview tick is **4 game ticks**.

**The first cut of this move got that wrong**, and the failure was silent.
The hold bytes were read as game ticks, which made the whole sequence 11
ticks — a flicker at 54.7 Hz — so the authored timing was dismissed as
impossible and replaced with invented per-part speeds (a 13-tick carry-on).
That ran the move at roughly **twice** its intended rate, and nothing in the
build or the rig said a word: the damage was right and the animation played.
The sequence was correct all along.

So `a_lkdubknee` is **generated**, as frame/hold pairs, by
`tools/lk_dubknee_seq_import.py`, with a Phase D `--check`. Edit the sequence
in IMGTOOL and re-run the tool; never hand-edit the block.

| part | frames | authored ticks |
|---|---|---|
| 1 wind-up | LKDUBLKNEE1, LKDUBLKNEE2 | 4, 8 |
| 2 contact | LKDUBLKNEE3 | 4 (its hold **is** its active ticks) |
| 3 drop | LKDUBLKNEE4 | 4 |
| 4 chain window | LKBACKFIST1 | 4 |

`LKDUBLKNEE3` is the contact frame because it is the extended one — 96 px
wide against 74 / 72 / 54 for the rest. Never hand a pair lane to `mframew`:
the hold longs would be read as frame pointers.

## The knee does not knock down any more

This is the change that makes it an MK3 chain, and it is a deliberate
departure from retail.

`stk_lkknee`'s hit reaction was `0eh` = `r_hhknee` — a **knockdown into
flight**, 3 px/tick away and 8 px/tick up. With the authored 12-tick wind-up,
the second knee comes out at a victim who is by then **~110 px away and
airborne**. Measured: every linked trial whiffed in open space, and the only
ones passing were those where an earlier knockdown had left the victim in a
**corner**, where the edge clamp stops him sliding. Making Liu Kang run after
him closed the gap but just turned the whiff into a slide.

Both chain hits now hand the victim **`r_lk_chainstun`** (`react_to_lk` row
`lk_rct_chainstun` = 19h): `r_lopunched`'s body — a standing chest hit with
**no pushback at all** — held at 6 ticks a frame where `r_lopunched` uses 3.

Both halves were measured:

- **No pushback**, so the chain stays in range. With it, `dist` is frozen at
  64 px for the whole three-hit chain and neither fighter moves.
- **Held longer**, because MK2's standing stun is shorter than this combo's
  authored spacing. The second knee lands 16 ticks after the first, and at
  `r_lopunched`'s rate the victim was back to neutral before it arrived — so
  he took it as an *opening* hit, `dmgscale` never scaled it (34 damage
  instead of 31), and he was free to walk or block out of a combo that is
  meant to hold him. MK3 authors its chain reactions to cover its chain
  spacing; this is the same thing.

**The cost:** his ordinary unlinked knee no longer knocks down. In MK3 a knee
is a combo starter rather than a knockdown, so it is the same trade that game
makes. Damage is untouched at 20/6.

The **backfist** keeps its own `stk_lkhikick` routine word (`00000h` →
`r_hikicked`), so the last hit of the chain is the one that knocks the victim
away — which is how an MK3 chain ends.

## The timing, measured

From `tools/run_lk_dubknee_test.ps1`, ticks from the HK that starts the knee:

```
+0   HK pressed
+11  the knee connects        (stk_lkknee,    20)
+15  the window's first legal tick - the link fires here
+27  the double knee connects (stk_lkdubknee, 14 -> 11 at dmgscale 3/4)
       = +15, then the authored 4 + 8 of wind-up
+44  the backfist connects    (stk_lkhikick,  32 -> 16 at dmgscale 1/2)
```

| Phase | Ticks | Constant |
|---|---|---|
| Knee wind-up, LKKNEE1-2 | 3 a frame | `do_knee`'s speed (retail) |
| Knee active, LKKNEE3 | 2 | `stk_lkknee` (00eh) |
| Window: can't fire | ticks 1-3 after contact | `lkdk_win_skip` = 3 |
| Window: fires on the first tick with an HK press | ticks 4-9 | `lkdk_win` = 9 |
| No link: the rest of the stock hold, then retract | `knee_hit_sleeps`, retract 6 | unchanged |
| Carry-on wind-up | 4 then 8 | authored |
| Contact frame, live | 4 | authored; `stk_lkdubknee` |
| Hit hold | 5 | |
| Drop, then the chain window | 4, 4 | authored |
| Chain: the backfist | `do_lk_backfist`'s own | `stk_lkhikick` |

Rules worth knowing:

- **Presses are counted from the tick the move started**, and the press that
  started it is excluded (the queue scan stops at the first entry as old as
  the knee). One HK can never link to itself, but an HK made during the
  wind-up is remembered and fires on the window's first legal tick. The
  chaining HP works the same way — `lk_bfist_ask` scans back to the tick the
  carry-on started, so an early HP fires on LKBACKFIST1 rather than being
  taken early or lost.
- **The window sits inside the stock 20-tick hold**, so an unlinked knee has
  exactly the stock recovery.
- **A whiffed knee** has no hold to put a window in. It links only if an HK is
  already in when its active ticks end. A blocked knee gets the window.
- **A CPU Liu Kang never links or chains it**: the drone presses nothing, so
  the button-close queue has no HK or HP for it to find.
- **With no direction in the gesture, the cooldown is the limiter.** The
  carry-on is refused inside `lk_dknee_cool` (64 ticks) of the last one —
  `l_lkdknee`, a p1:p2 pair in RAM.ASM cleared by `round_init_longs`.

## `stk_lkdubknee`

| | x offset | x size | y offset | y size |
|---|---|---|---|---|
| `stk_lkknee` | 60 | 30 | 47 | 45 |
| `stk_lkdubknee` | 56 | 60 | 0 | 80 |

56..116 and 0..80, aimed at a man standing in front of him at a measured
64 px. It was briefly 66..142 and aimed *upward* (`y_offset -20`) back when
the victim was being launched; both are wrong now that he stays on his feet,
and an over-wide box left in would have been a balance change disguised as a
bug fix. `sf_squeeze` is kept, as 205 of 223 records keep it.

## `reaction_start_abc` skips an airborne victim entirely

Worth knowing whatever this move does, because it decides what the victim
plays.

```asm
	move	a7,a7			; check for airborn hit ?
	jreq	rst2			; no
	calla	am_i_airborn
	jrnc	rst2
	pull	a0			; no return
	jump	a5
```

`reaction_start_abc` sets that flag; `reaction_start` does not. For an
airborne victim the `_abc` form **never comes back** — it jumps to whatever
the caller left in `a5`, which is `generic_airborn_hit` in every stock
reaction, and every instruction after the `callr` is skipped.

This cost a build cycle while a floor-slam ender was being tried: none of its
beats ran, yet the damage was right, the combo readout said 2 HITS, and the
arc looked plausible. What gave it away was a **number** — the victim rising
at exactly 6 px/tick, which is `generic_airborn_hit`'s own `-060000h` literal
and not one of ours.

## Enders that were built and dropped

Recorded because the reasoning is reusable, not because they are coming back.
All three assumed the victim was airborne, which he no longer is:

- **`r_roundh`** — the roundhouse knockdown, thrown clear across the floor.
  Dropped: the art is a man kneeing *downward*, so a throw read wrong.
- **A bespoke floor slam** — spike him into the ground, `do_quake`'s
  earthquake on impact, then a pop back up with zero x velocity, a deliberate
  juggle setup (floor +26, apex 45 px at +38, an uppercut out of it for 51).
  Dropped on the call that the move should not create a juggle.
- **`r_hikicked` on the double knee** — the plain high-kick reaction. Dropped
  when the chain replaced the juggle: its `away_x_vel 048000h` shove
  separated the fighters and the backfist whiffed. The high-kick reaction is
  still the chain's *ender*, on the backfist, where the shove belongs.

## Where the art lives — and why it is in three packs

`LKDUBLKNEE1A-3C`, ten strips, **8,571 bytes**, dropped from
`data/MOVEART2.LOD` on 2026-09-20 as dead art — correctly, nothing named
them. Putting them back is not a revert: bank 0 has 18,822 bytes free and
**no single hole bigger than 4,832**, so they are dealt across three, the way
`SKSOUL1-5`, `TIGJMP1-6` and `MK1PT1-4` are dealt:

| pack | where | records | bytes | hole |
|---|---|---|---|---|
| 1 | a new section at the END of `data/MOVEART2.LOD` | 1B, 3B, 2A, 2C | 4,572 | 4,832 |
| 2 | `data/LKDKNEE2.LOD` — JADMIL1's tail | 3A, 1A, 2B, 2D | 3,082 | 3,248 |
| 3 | `data/LKDKNEE3.LOD` — RNVIC7's tail, to the top of bank 0 | 3C, 1C | 917 | 1,152 |

Sizes are the **exact pre-removal SAG deltas** from the old
`src/LKDUBLKN.TBL` in git, not estimates off the IMG (which run 3-14% low).
Every one reproduced to the byte.

- **Pack 1 is a new section, not a restore into the `LKDUBLKN.TBL` block.**
  Putting them back where they were would push `JDIMPALE6` 4,572 bytes up the
  file, and LOAD2 ORs stray bits into the last rows of a record when what
  sits in front of it moves (`tools/fix_load2_bit_bleed.py`). Appended at the
  end, nothing already packed in MOVEART2 moves — `JDIMPAL6.TBL` came out of
  the rebuild unchanged.
- **`LKDUBLKNEE4A` was never deleted** — kept in 2026 because
  `art_ref_graph.py` classed it WINDOW rather than DEAD. It is now genuinely
  live: `a_lkdubknee` names it.

**Bank 0 is full after this** — free dropped 18,822 → 10,248 bytes, largest
remaining run 1,260. `MOVEART2`, `JADMIL1` and `RNVIC7` have no growth room
left; their slot ends in `makevrom.py` were brought in so an overgrown
payload errors instead of colliding.

## Its own object

`lk_knee`, `lk_double_knee`, `ldk_hold`, `lk_knee_ask` and `lk_bfist_ask` are
in **`src/MKLKDK.ASM`**, not MOVES.ASM. Adding them to MOVES.ASM aborts GSPA
with `Out of memory` — the same ceiling BGND.ASM hit twice. The ceiling tracks
symbols and content, not line count, so trimming prose buys nothing.

- `do_knee` reaches `lk_knee` with **`jrne` + `jauc`**, not `jreq`. A
  conditional branch is PC-relative and GSPLNK wraps an overflow **silently**.
  `jauc` is absolute and crosses objects fine — so is `jsrp`, which is `jauc`
  under the macro, and that is how the chain reaches `do_lk_backfist`.
- `.set` equates do not cross objects, so `lkdknee`, `lk_dknee_cool`,
  `lkdk_win_skip`, `lkdk_win`, `lk_stk_dubknee` and `lk_rct_chainstun` live
  in MAINEQU.ASM.

`lk_stk_dubknee` is `017h+stkphase`, because the row is appended after
`lk_strikes`' `stkphase`-conditional row. MKSTK.ASM and MKREACT.ASM carry the
`.emsg` guards that prove it and `lk_rct_chainstun` still match their rows —
`get_char_stk` is a plain index with no bounds check, so a row that silently
moves reads the wrong record rather than failing.

## Code map

| What | Where |
|---|---|
| Knee, combo window, link test | `lk_knee`, `lk_knee_ask` in [src/MKLKDK.ASM](../src/MKLKDK.ASM) |
| Carry-on, strike, chain window | `lk_double_knee`, `ldk_hold`, `lk_bfist_ask`, same file |
| Dispatch | `do_knee`'s `ft_kang` branch, [src/MOVES.ASM](../src/MOVES.ASM) |
| The frame lane (generated) | `a_lkdubknee`, `lk_anitab2` row 7, [src/MKLK.ASM](../src/MKLK.ASM) |
| Lane generator | `tools/lk_dubknee_seq_import.py` (Phase D `--check`) |
| Multipart records | `LKDUBLKNEE1-4`, MKLK.ASM |
| Strike records | `stk_lkknee`, `stk_lkdubknee`, [src/MKSTK.ASM](../src/MKSTK.ASM) |
| The chain's hitstun | `r_lk_chainstun`, `react_to_lk` row `lk_rct_chainstun`, [src/MKREACT.ASM](../src/MKREACT.ASM) |
| The ender | `do_lk_backfist` (MOVES.ASM), his own Back+HP backfist |
| Cooldown | `l_lkdknee` (RAM.ASM), `round_init_longs` (MAIN.ASM) |
| Art | `data/LKDKNEE2-3.LOD` + the tail of `data/MOVEART2.LOD`; tables `src/LKDKNEE1-3.TBL` |
| Switch | `lkdknee` (MAINEQU.ASM) |

## Testing

```
.\tools\run_lk_dubknee_test.ps1          # 7 trials, PASS/FAIL per trial
.\tools\run_lk_dubknee_test.ps1 -Snap    # + frames into tmp/lk_dubknee/
```

Every trial parks the **pair** mid-screen and taps HK at d=0..3.

| Trial | Input | Expected |
|---|---|---|
| dubk | link at 8 (before contact: remembered) | 2 hits, 31 |
| hold | link at 14 (inside the window) | 2 hits, 31 |
| bfst | link at 8, then HP at 14 | **3 hits, 47**, ending in `act_lkbackfist` |
| nohp | link at 8, no HP | 2 hits, 31 — the chain is dialled, not automatic |
| knee | none | 1 hit, stock knee, 20 |
| late | link at 22 (past the window) | 1 hit, stock knee, 20 |
| cool | link at 8, `l_lkdknee` stamped first | 1 hit, stock knee, 20 |

The negatives are what prove the links have teeth. A rig that only checked
"the double knee came out" would pass on a build where every knee became one.
Each trial also pins the **hit count**, and `bfst` requires `act_lkbackfist`
specifically, so a third hit from anything else would not count.

**Park the PAIR, not just P1.** Parking only P1 lets each trial inherit the
previous one's drift, and after a few knockdowns the victim is in a corner —
where the edge clamp stops him sliding and the carry-on connects on a victim
it would *miss* in open space. That difference passed `nohp` and failed
`dubk` on identical inputs until the pair was pinned.

The rig logs distance and the victim's height every tick (reported, not
asserted). Through the working chain, `dist` stays **64** and `up` stays
**0** — nobody slides, nobody leaves the ground. Those two columns are what
every wrong version of this move showed up in first.

Result on the build it was written against: **7/7 PASS**.
