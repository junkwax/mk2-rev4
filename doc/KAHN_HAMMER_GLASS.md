# The screen cracks — Shao Kahn's hammer smash

`glasscrk` (MAINEQU.ASM), `src/MKGLASS.ASM`. Set to `0` for the finisher with
the glass intact.

Shao Kahn's hammer-smash fatality ends with the beaten man driven face-first
into the front of the screen: he grows to 2x on the way at the camera,
`PITFALL6` is the frame he arrives on, and he holds there before peeling off
and sliding down. That impact frame now **breaks the glass** — a chip where he
landed, radial cracks running out of it, and two irregular webs of concentric
cracks joining the radials where they kink. It spreads over six frames and is
then held, still, for the rest of the finisher.

It is hooked in `r_kahn_hammer_smash` (MKBOSS.ASM) on the same frame as the wet
impact and `shake_a11`, right after the last `kahn_smash_scale` — the impact
point is measured once and the camera is already frozen (`stop_scrolling` +
`f_noscrolly`), so it has to be measured when he is where he is going to stay.

## Why it is CPU line work and not art

`geo_seg` / `geo_pass` (MKDISP.ASM) is the pass the hit-box overlay draws
through. A crack is what it is good at: no art, **no video-ROM space** — bank 0
has none left — no palette, and the shape can be rolled fresh every time.
Requires `geoline .set 1`; with it off `geo_seg` is not `.global` and the link
fails on it, loudly.

It draws **in front of everything**, and that is the point rather than a
limitation. `geo_pass` runs at `dsa9`, after every object and the score area
are queued, so the crack sits over the body, over Kahn, over the HUD and over
SHAO KAHN WINS / FATALITY. The glass is in front of the whole picture.
`geo_layer` would put it under the HUD instead, at the cost of a
`.long -1,geo_layer` in every display list it could happen on, and `GEO_LMAX`
is 32 segments — not enough for this.

## A PROCESS DOES NOT POST OFTEN ENOUGH

This is the thing worth carrying to the next CPU-drawn effect.

`geo_pass` consumes `geo_list` and zeroes its count every frame, so a producer
that stops posting vanishes — the contract is "re-arm every frame". The first
cut of this obeyed that contract from its own process on `sleep 1`, which is
one post per game tick, and **the crack came out on every other frame.**

Measured, not guessed — 70 captured frames of the finisher, counting near-white
pixels in the play area:

```
tick 100  2762      tick 103  1652      tick 106  2651      tick 109  1579
```

A hard two-frame square wave between the whole web (~2,650) and none of it
(~1,590, which is just the victim's own highlights). **That is not what a cost
problem looks like** — a frame that runs out of time loses the pass at random,
the way Raiden's geometry bolts used to blink about one frame in five. A clean
square wave is a scheduling mismatch.

The fix is the shape `box_pass` already has: the hit-box overlay is the other
thing in this game that holds still for many frames, and it produces from
**inside the display pass**. `glass_crack_pass` is called from `dsa9` right
beside it, which makes "every frame" true by construction instead of by
scheduling luck — and costs a process and a pid less than the version that did
not work. It **must come before `geo_pass`**: it appends at `geo_count`, and
`geo_pass` is what consumes and clears the list. Same contract as `box_pass`,
and the comment there says so.

After the change, 63 sampled frames: minimum 2,348 against a mean of 3,391, and
**zero frames missing the crack.**

## What it costs: nothing measurable

`tools/run_fatality_budget.py --build <dir> --only kahn_fatality`, three builds,
same 220-frame window of the finisher, game ticks against MAME frames:

| build | frames | ticks | dropped |
|---|---|---|---|
| control, `glasscrk 0` | 220 | 220 | 0 |
| crack code present, posting **nothing** | 220 | 215 | 5 |
| crack **drawn**, all 59 segments | 220 | 215 | 5 |

Drawing the whole web is free to the resolution of this measurement — posting
nothing and posting everything drop the identical five ticks, evenly spaced one
per ~40 frames. No queue drops of any kind: `qdma_drops`, `dmaq_over` and
`dmaq_lost` are all `+0`.

**`peak_overload` reads `gc_life`, and that is an artifact — do not chase it.**
The budget run reports `peak_overload` 600 with `gc_life 600`, and 241 with
`gc_life 240`; it is a single frame at the moment the crack expires, decaying
600 → 301 → 151 → 76 through `prcdsp`'s own smoothing filter
(`overload = (overload + 2*timer)/2`, MPROC.ASM), with every other frame of the
finisher at 4 or below, the same as the control. `gc_tick` and `peak_overload`
are at different addresses (010b18c0 against 010b4220) — checked, because the
value tracking the constant that exactly is worth ruling out. Judge this effect
on the tick-against-frame table above, not on that counter.

## The shape

All of it is equates at the top of `src/MKGLASS.ASM`.

- `GC_RAYS` (11) radial cracks, **odd on purpose** — an even count reads as a
  wheel, not a break. Directions come from `gc_dirs`, a hand-authored ring of
  unit vectors at 256, at deliberately **uneven** angles: glass breaks where it
  is weakest, not every 32 degrees, and an even spread is the one thing that
  makes this read as a drawn star instead of a break.
- Each ray is three segments through two kinks (`GC_F1`, `GC_F2` of its length)
  with `GC_KINK` of perpendicular wander, and a length rolled per ray between
  `GC_RMIN` and `GC_RMAX`.
- The two webs join **adjacent rays at their kinks**, which is what makes them
  irregular for free — every ray is a different length, so the slot sits at a
  different radius on each one. A web drawn at a fixed radius is a polygon and
  reads as one.
- `gc_core` is the impact chip: four short segments at four of the ray angles
  and uneven radii. It walks `gc_dirs` in **threes**, which is why 11 and 3
  being coprime matters — it picks four different angles.

Where the impact lands is **measured, not a constant**: at 2x and lying in a
PITFALL pose the victim's anchor is nowhere near the part of him that is
touching the glass, so `gc_point` takes `mpart_bounds` and uses the middle of
his drawn extent across, a bit under a third of the way down it — his face.

## Two traps in the geometry

**A segment that leaves the page is dropped WHOLE, not clipped** (`geo_onpage`,
MKDISP.ASM — a whole-segment accept/reject, because a clip needs
Cohen-Sutherland and this runs in the display interrupt with interrupts off).
So a ray that ran off the top would not be shortened, the whole ray would go
missing. `gcb_fit` shortens each ray by a quarter at a time until its **tip** is
inside the margin box, which keeps the ray straight and just stops it at the
edge. Clamping the points instead bends the crack along the border, which reads
as a frame, not as glass. `GC_EDGE` holds the impact point far enough in that a
ray can never reach `gcb_fit`'s floor and still be off page.

**Everything random comes from `@blood_rand`** (`blood_randu` / `blood_srand`,
UTIL.ASM), the cosmetic stream — netplay's gameplay RNG must not move because a
crack was drawn. Same rule the blood and the forceball follow.

## Lifetime

`gc_live` is raised at the impact and the **gstate test is the real bound**: the
moment the game is neither fighting nor counting the bonus — the next match, the
continue screen, attract — the glass is whole again. `gc_life` (600 frames) is
only a backstop. Verified in the capture: the crack is up through the hold, the
slide and the announcements, and gone by the ROUND 3 intro.

## Rig

No new rig. The existing one exercises it:

```
tools\run_kahn_boss_moves_test.ps1 -Move hammer -PortalFatality -PuppetHold [-RomPath <dir>]
```

Its `pulp_*` capture window already covers the whole finisher. The check that
matters is the one above — count near-white pixels in the play area across the
captured frames and confirm none of them is missing the web, because **the
failure mode this effect has is a flicker, not an absence.**
