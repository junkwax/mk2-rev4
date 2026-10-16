# Kintaro's face smash (FACE SMASH) — a grab and punch

Kintaro reaches out, **catches** the opponent, and punches him in the face
twice, then throws him. It is the `FACE SMASH` sequence authored in
`data/TIGER4.IMG`, whose art has been in the video ROM since the leak with
nothing referencing it.

It is `do_noogy`'s shape — Jax's gotcha grab — and it deliberately borrows that
move's victim animation.

Companion to [KINTARO_GETUP_KICK.md](KINTARO_GETUP_KICK.md), which explains the
seqscr record format and why the frame list reads newest-first, and
[KINTARO_BACKHAND.md](KINTARO_BACKHAND.md).

## What was already there, and what wasn't

| | state before |
|---|---|
| `TIGERFACE1..8` + 32 strip frames | in `data/TIGER4.IMG` |
| strip records with real video-ROM SAGs | `src/MKGORO2.TBL` |
| loaded into the video ROM | `data/MK5MIL.LOD` |
| composite `TIGERFACEn` records | **absent** |
| animation table | **absent** |
| `go_anitab1` slot | **absent** |
| strike record | **absent** |
| handler, AI | **absent** |

Unlike the get-up kick — where the lane existed and the AI just could not reach
it — this move had no code at all. The pixels were being burned into every
video ROM and never drawn.

## The sequence, and what the frames are

Decoded from the seqscr at `0x118A56` (entries newest-first, `u16 index, u8
hold, u8 junk`):

```
FACE1[01] FACE2[01] FACE3[02] FACE4[01] FACE5[01] FACE7[01]
FACE6[01] FACE5[01] FACE7[02] FACE8[01]
```

- **`FACE3` is the catch.** Both arms out, 184px wide with `anix` 76 — the
  widest frame in the set. It is the frame that either connects or gets
  blocked, the same job `stk_noogy` does on Jax's reach-out.
- **`FACE7` is the fist arriving on the victim's face.** It appears twice.
- `FACE5` is the rear-up before each punch; `FACE8` is the release.

The two `[02]` holds are on `FACE3` (the catch, held while the box is live) and
the second `FACE7` (the punch that throws him).

## The lane, in four parts

```
a_goro_facesmash            ; go_anitab1 slot 018h, src/MKGORO.ASM
  FACE1 2 3 3  |  FACE4 5 7 7  |  FACE6 5 7 7  |  FACE8
  \_ ONE: grab /  \_ TWO: punch/  \_THREE: punch/  \ FOUR: let go
```

**Parts TWO and THREE are four rows each on purpose.** `double_mframew` ends on
the **victim's** terminator, not the attacker's, and every hit-high lane in the
game (`anitab1` `010h`, and `013h` for a boss) is exactly four rows — checked
across all 17 fighters with `tools/survey_victim_anis.py --slot 10 / --slot 13`.
Part TWO was authored three rows long; run against a four-row victim it walked
Kintaro's lane one row past its own terminator every punch, and the second
punch then animated off the end of the table into the `TIGERFACEn` composite
records below it. **That crashed the game 14 ticks after the catch** — `gstate`
came back as 32334. The repeated `TIGERFACE7` is the fourth row, and it reads as
the fist resting on his face for a beat.

## The punches do not test a box

A held man is not a strikable target. `strike_check_a0` against someone parked
in a `takeover_him` hold whiffs every time — that is the bug `kbigp_payoff`
carries a long comment about in the same file. The catch passed a box; after
that the damage goes in with `damage_to_him` (21 a punch, so 42 for the move —
the same total it did as a free swing) and he is released with `xfer_otherguy`,
still playing a victim animation. No lineup-then-release, no set-down: he is hit
where he hangs.

## The victim

| | |
|---|---|
| pose | `anitab1` `010h` + 3 longwords = hit-high frame 1; `013h` if the victim is a boss — exactly what `noogy_hit` picks |
| proc | `goro_grab_held` — `noogy_suspended`'s shape, spelled out locally because that label is not `.global` |
| sync | `double_mframew`, four rows against four; his lane is **re-resolved from the top on every punch**, because `double_mframew` leaves `a11` on his terminator and a second punch driven from there walks his table off the end |
| position | `gfs_lineup` — `match_him_with_me_f` then `adjust_him_a0` |
| z order | **`me_in_back`**, so the victim draws in FRONT |
| release | `r_last_noogy` — the gotcha grab's own last-hit reaction, which falls through to `r_roundh`: flight at `060000h` out and `-080000h` up |

Two things about that table are easy to get wrong and both were:

**`adjust_him_a0` is `[Y : X]`, not `[X : Y]`.** It `zext`s the LOW word into
`a0` (x) and shifts the HIGH word down into `a1` (y). Written the other way
round the victim is held 144px out to the SIDE instead of in front — which the
rig read as a catch at `gap=144` on every single use.

**`-048h`, not Jax's `-060h`.** Jax is the same size as the man he is holding,
so 96px puts the victim on the end of his arms. On Kintaro the same number
leaves the victim standing a body-width clear with nothing touching him.
`TIGERFACE7` reaches 79px past the anchor (128 wide, `anix` 49), so the head has
to be inside that.

**`me_in_back`, not `me_in_front`.** `do_noogy` puts Jax in front because he is
the same size as his victim; Kintaro is half a screen of four-armed tiger and
would swallow the victim whole.

## Strike record

`stk_goro_facesmash`, `go_strikes` slot 7 (`src/MKSTK.ASM`):

```
x offset 06eh   y offset 010h   x size 050h   y size 040h
routine  00020h   damage 00000h   sf_squeeze
```

Zero damage: this is the CATCH box, and `stk_noogy` and `stk_sk_grab` both carry
0 for the same reason. Taller and higher than his kick's (`y` `010h`/`040h`
against `020h`/`030h`) because he catches with both arms out.
`doc/balance.lock` was regenerated — Phase D fails the build otherwise, which is
how each edit to this record got caught.

## The trigger

`goro4` in `goro_stalk` — his close-range decision, which he takes every time he
closes to `060h`. On the ground only: **the uppercut keeps the air case
outright**, because it is his anti-air. On the ground it is
`ask_mr_diff diff_facesmash` (`0,0,0,150,200,250,300,350,400,450`) against the
uppercut.

`stop_abusive_attackers` also offers it (a block earns a turn, and that branch
used to be slam-or-20%-zap-or-nothing). **That is not the branch that fires.**
It needs `boss_wait_nonattack` to time out, which a jab never causes; wired
there alone, the move did not run once in a 5400-frame trial — the same
unreachable-trigger trap `rt_goro_close` is for the kick.

## Breadcrumbs

| value | meaning |
|-------|---------|
| `7110` | reaching out |
| `7111` | CAUGHT him — held from here |
| `7112` | first punch landed |
| `7113` | the grab closed on nothing |
| `7114` | second punch landed |
| `7115` | the catch was blocked |

`7110` twice running is invisible to a change-poller, so a start that does not
catch is undercounted — which is why the rig's damage window opens on the
**catch**, not on the start. Opened on the start it was hundreds of frames
stale and Kintaro's uppercut (40) got scored as grab damage, six times.

## Rig

```
tools\run_kintaro_facesmash_test.ps1              # counts only
tools\run_kintaro_facesmash_test.ps1 -Dodge       # + snapshot the whole grab
```

`-Dodge` shoots the hold every 4 ticks for the first two catches, because
whether the victim actually hangs in his hands at the right height is not
something a counter can answer.

The rig must **not pin the players during the hold**: `gfs_lineup` places the
victim with `adjust_him_a0` and a pin fighting that rips him straight back out,
after which the rig is measuring its own interference.

Result at diff 9 (2026-09-09):

```
started=9 caught=8 punch1=8 punch2=8 whiffed=0 blocked=0 p1_damage=336 over 16 hits
knockback peak xvel=229376 (THROWN) x8
PASS: grabbed 8 times, 8 + 8 punches, 336 damage (21 per punch), thrown 8
```

`tools\run_battle_stability_sweep.ps1`: 25/25 PASS, including
`kintaro_p2_arena` and `kahnboss_p2_arena`.
