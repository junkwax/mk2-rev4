# Kintaro's backhand (BACKHAND)

Kintaro spins and takes all four arms round with him. It is the `BACKHAND`
sequence authored in `data/TIGER4.IMG`, whose `TIGERBACK1..6` art has been in
the video ROM since the leak with nothing referencing it.

Third of the three unbuilt Kintaro sequences — see
[KINTARO_GETUP_KICK.md](KINTARO_GETUP_KICK.md) for the seqscr record format and
why the frame list reads newest-first, and
[KINTARO_FACE_SMASH.md](KINTARO_FACE_SMASH.md).

## The sequence

```
TIGERBACK1[01] TIGERBACK2[02] TIGERBACK3[01] TIGERBACK4[01] TIGERBACK5[02] TIGERBACK6[01]
```

Rendered, it is a **rotation**: BACK1-2 are his ordinary right profile winding
up, BACK3 is front-on with all four arms flung wide, and BACK4-6 carry the spin
round to his back. That is the same shape as `a_gturn`, which is
`TIGERTURN1-5` into front-on and then `ani_flip` — except here the whole
rotation is drawn out.

**`TIGERBACK3` is the contact frame, and that is measured rather than guessed:**
it reaches 108px past the anchor (184 wide, `anix` 76), further forward than any
other row in the lane, and it is the pose the arms are actually extended in.

The two `[02]` holds are real rows in the lane rather than `striker`'s `a10`,
because neither is on the contact frame — BACK2 is the wind-up beat and BACK5 is
the follow-through beat. `a_goro_getup` doubles `TIGERGETUP4` the same way.

## The trigger — the turnaround

The art is a rotation, so the move **is** a turn with a strike box on the way
past. It is wired to `drone_turnaround` (`src/MKDRONE.ASM`) rather than to his
stalk: on a cross-up, instead of pivoting and eating whatever comes next,
Kintaro can pivot *through* you.

That is also a trigger that actually fires. Jumping over a boss is the standard
way to fight one, so `drone_turnaround` is reached constantly — unlike the two
dead branches the get-up kick and the face smash each found the hard way
(`rt_goro_close`, `stop_abusive_attackers`).

`goro_backhand_check` answers for `ft_goro` only — `drone_turnaround` is shared
by every drone in the game — and declines when `winner_status` is set or the
gap is past `070h`. A cross-up ends with the player right on top of him, which
is where this wants to be; if they kept running he turns around as before.

```
diff_backhand   .word 0,0,0,150,200,250,300,350,400,450
```

Never better than a coin flip: it is a committed move and turning around is
still the safe answer most of the time.

## Strike record

`stk_goro_backhand`, `go_strikes` slot 8 (`src/MKSTK.ASM`):

```
x offset 078h   y offset 020h   x size 060h   y size 030h
routine  00020h   damage 03010h (48 hit / 16 block)   sf_squeeze
```

The widest, longest-reaching box he has — it covers the ground between rather
than poking at the end of it. 48 damage: less than the kick (53) because the
spin leaves him turned around, more than the punch (40) because it is
committed.

## Breadcrumbs

| value | meaning |
|-------|---------|
| `7120` | the move started |
| `7121` | whiffed |
| `7122` | CONNECTED |
| `7123` | refused — too far to reach |
| `7124` | in range, `ask_mr_diff` said no |

## Rig

```
tools\run_kintaro_backhand_test.ps1
tools\run_kintaro_backhand_test.ps1 -Shots     # + snapshot the whole spin
```

The rig has to **cross him up**, which it does by teleporting P1 to his other
side on a timer — that is what makes `am_i_facing_him` fail and sends him to
the turnaround. It stops flipping sides while the move is running, or he gets
yanked out of reach mid-spin and every use reads as a whiff.

Result at diff 9 (2026-09-09):

```
gate_ran=15 started=9 connected=7 whiffed=2 too_far=0 roll_declined=6
damage=336 over 7 hits
PASS: backhand fired 9 times, connected 7, 336 damage
```

48 a hit, and contact lands at `rel=12` — 4 rows at sleep 3, as designed.
`tools\run_battle_stability_sweep.ps1`: 25/25 PASS.
