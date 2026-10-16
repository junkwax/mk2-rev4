# The Dead Pool stage fatality — landing in the acid

The uppercut-into-the-acid finisher on THE DEAD POOL used to be able to drop
the body onto the stone ledge at either end of the arena: the splash, the
bubbles and the rising skeleton all played out against the wall, on dry rock.
This is what fixed it, and how the numbers were measured.

---

## How the fatality fires

There is no `do_*` handler for it and it is not in `check_dtp` with the Pit and
the Tomb. It lives inside the ordinary uppercut.

`do_uppercut` (MOVES.ASM, the `ucut2` branch) takes it on a **clean hit**, when
all of:

| condition | where |
|---|---|
| `curback == 0` (Dead Pool) | `move @curback,a0,w / jrne ucut3` |
| `winner_status == 3` (FINISH HIM) | `cmpi 3,a0 / jrne ucut3` |
| attacker is a drone, **or** a human holding **LP + LK** | `am_i_joy`, then `switch2` bits 0/1 (`p1b1`, `p1b4`) masked with `andi 3` |

It then hands the victim `act_pit_fall`'s sibling, `act_slime_fall` (050ah),
and `strike_reaction` (MKREACT.ASM) dispatches that to **`r_fall_in_slime`**
(BGND.ASM), which flies him into the pool *behind* the walkway and spawns
`acidsplash1a`/`a_green_splash`, then `acidskel1`/`a_slime_skel`.

## Where the acid actually is

`DPUL5BMOD` is the Dead Pool's back plane — `baklst1`, scroll rate `020000h`,
which is the same **1.0x** `objlst` runs at. So a block in that module and a
fighter's `oxpos` share one coordinate space with no parallax between them, and
the pool can be stated in the same world x a fighter stands on.

Composing that module out of `DEDPOOL.BDB`/`.BDD` and scanning the acid rows
(world y 188..199 — the same strip `calla_dedpool`'s shadow clip is built on):

```
acid          world x  195 .. 947      (753px)
fighters      world x   60 .. 1098     gravity_n_bounds, left_padding/right_padding
```

Everything outside that band is the raised stone ledge under each doorway.
**~135px at the left end of the arena and ~150px at the right end are off the
pool** — and they are ordinary corner-fight positions, not somewhere exotic.

`tools/deadpool_acid_band.py` re-derives all of this from the art. It runs in
Phase D, so re-cutting `DEDPOOL.BDD` can no longer move the pool out from under
the fatality without failing the build.

```
python tools/deadpool_acid_band.py            # report
python tools/deadpool_acid_band.py --check    # what the build runs
python tools/deadpool_acid_band.py --dump tmp/dpul5.png
```

## What retail did, and why it missed

`r_fall_in_slime` has two arcs:

| arc | floor | x velocity | animation | travel |
|---|---|---|---|---|
| normal | `p_ganiy - 020h` | `+020000h` **away** from the attacker | 00fh | ~126px |
| short | `p_ganiy - 008h` | `-040000h` **toward** the attacker | 03ah | ~252px |

Both are net-zero in y — `flight` snaps `oypos` onto the lowered `p_ganiy`
before the first tick — so each runs `2*0c0000h/06000h - 1 = 63` ticks and the
travel is just `63 * velocity`.

Retail chose between them on raw distance from the edge of the *world*:

```asm
	calla	get_my_dfe
	move	*a8(oflags),a4,w
	btst	b_fliph,a4
	jrne	fis4
	move	a5,a6
fis4	cmpi	0130h,a6		; 304px
	jrhi	fis5			; normal fall
```

That is a real attempt at the problem — 0130h flips him back over the
attacker's head when he is near a wall — but it is measured against the arena
edge, which is 133px further out than the pool on the left and 199px further
out on the right. Working the arithmetic through, the normal arc is taken and
lands on the ledge for:

* victim x **307..322**, attacker on his right (knocked left) — lands 181..196
* victim x **820..842**, attacker on his left (knocked right) — lands 946..968

Two ~15-20px windows. Narrow, but they are exactly the spacing an uppercut
happens at near a corner, which is why it was reachable in play.

## What this build does

Two changes in `r_fall_in_slime`, plus the equates they read.

**1. Predict the landing instead of measuring the wall.** Run the normal arc
forward `dp_slime_arc` (126) pixels in the direction `away_x_vel` will actually
throw him — taken from `is_he_right`, the same test `flight` makes, so the sign
cannot disagree — and take the short arc only if that misses the pool.

**2. `fis_hold_over_acid`, a one-way barrier on the lip.** Passed to
`flight_call` as its every-tick hook. It only ever takes speed *away*, and only
from a body that is already outside the band and still heading further out —
starting outside is normal, that is what the short arc is for, and pulling his
`oxpos` to the lip would teleport him mid-flight, so it never writes a
position.

It has to kill both the object velocity **and** the request:

```asm
	move	a0,*a8(oxvel),l		; the pool has an edge
	calla	set_x_vel		; ...and repell must not hand it back
```

`repell` (MAIN.ASM) copies `@p1_xvel`/`@p2_xvel` onto `*a8(oxvel)` every single
tick, so zeroing `oxvel` on its own is undone before the next one. See
`reference_repell_velocity_plumbing`.

The band the arcs aim at is inset from the raw art by `dp_acid_margin` (30) so
it is the **body** that ends up over the pool and not just its anipoint: `oxpos`
is the character's root, roughly central, and a fighter is around 66px wide.
The same inset covers `acidskel1-11`, which the skeleton rises on at
`oxpos-12..oxpos+19`.

```asm
dp_acid_raw_lft	.equ	195
dp_acid_raw_rgt	.equ	947
dp_acid_margin	.equ	30
dp_acid_lft	.equ	dp_acid_raw_lft+dp_acid_margin	; 225
dp_acid_rgt	.equ	dp_acid_raw_rgt-dp_acid_margin	; 917
dp_slime_arc	.equ	126				; 63 ticks * 2px
```

Nothing else installs the hook, and `ucut2` only reaches `r_fall_in_slime` on
`curback 0`, so the band needs no stage test of its own.

## Rig

`tools/deadpool_slime_fall_test.lua` + `tools/run_deadpool_slime_fall_test.ps1`.
One run is one trial: it direct-selects a Dead Pool match, forces FINISH HIM,
**pins** the victim at `-VictimX` with the attacker `-Gap` away on `-Side`,
drives the uppercut with LP+LK held, releases the pin the instant the victim is
handed `act_slime_fall`, and then reports where the body actually stopped plus
the `oxpos` of the splash and the skeleton.

```
tools\run_deadpool_slime_fall_test.ps1 -VictimX 310 -Side right
tools\run_deadpool_slime_fall_test.ps1 -VictimX 830 -Side left
```

The pin is released before the arc so the flight itself is never touched — the
trial sets the *starting* position and nothing else.

## Measured

Both windows reproduce on a build with the fix backed out — the body comes down
outside the pool and the skeleton rises against the wall:

| victim x | attacker side | pre-fix landing | post-fix landing |
|---|---|---|---|
| 310 | right | **181** on the ledge | 543 |
| 315 | right | (inside the window) | 548 |
| 825 | left | **954** on the ledge | 592 |
| 830 | left | **959** on the ledge | 597 |
| 835 | left | **964** on the ledge | 602 |
| 840 | left | 607 (short arc already) | 607 |

The pre-fix flip to the short arc was bracketed on the right end: 835 still
takes the long arc, 840 takes the short one. That is `0130h` measured from the
arena edge (1146 - 842 = 304) rather than from the pool, which is the bug in one
line. The left end's boundary was not bracketed the same way — only that 310 and
315 land on the ledge.

Sweep on the fixed build, across the whole span a fighter can reach, both
directions — **17/17 land in the acid**, none nearer than 20px to a lip:

| victim x | attacker side | landing |
|---|---|---|
| 60 | right | 294 |
| 115 | left | 245 |
| 150 | right | 383 |
| 310 | right | 543 |
| 315 | right | 548 |
| 320 | right | 553 |
| 400 | left | 529 |
| 500 | right | 371 |
| 700 | left | 829 |
| 825 | left | 592 |
| 830 | left | 597 |
| 835 | left | 602 |
| 840 | left | 607 |
| 900 | right | 771 |
| 1000 | left | 767 |
| 1043 | right | 913 |
| 1090 | left | 857 |

(Acid is 195..947; the inset landing band is 225..917.)
