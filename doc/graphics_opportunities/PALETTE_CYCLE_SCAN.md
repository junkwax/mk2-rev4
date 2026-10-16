# Palette cycling as apparent motion - what is left to cycle

Row 14 of [GRAPHICS_OPPORTUNITIES.md](../GRAPHICS_OPPORTUNITIES.md).

`cycle_forward` (BGND.ASM) rotates a run of a background palette in place, so
the motion costs **no art, no object, and no process beyond the one
`pid_cycle`** the stage already creates. The helper is not in question - three
stages use it today:

| Stage | Call site | Run | Rate |
|---|---|---|---|
| THE DEAD POOL | `dedpool_cycle` | `NESS_P` 01h, 15 colours | sleep 6 |
| THE WASTELAND | `battle_cycle` | `WATER` 21h, 8 colours | sleep 8 |
| THE ARMORY | `armory_cycle` | `VAT` 2dh | - |

The open question was whether any **uncycled** authored ramp is worth turning
on. It is answered by two numbers, not by looking at palettes: how smooth the
ramp is, and **how much of the screen actually draws from it**.

```
python tools/palette_cycle_scan.py --ramps
python tools/palette_cycle_scan.py --coverage forest FOREST SHRUB1 04 6
```

## Pass 1 - the ramps exist

44 runs in `src/BGNDPAL.ASM` are strict triangle ramps: luminance climbs to a
peak and falls back, no step larger than 4 per gun, roughly symmetric, spanning
at least 9 levels. That is what an artist authors when they mean a run to be
rotated. Three of the 44 are the runs already cycled above, which is the
control: the test finds what Midway cycled.

## Pass 2 - almost none of them are on screen

Coverage is measured by composing the stage the way the game does
(`tools/stage_preview.py`) and counting the pixels drawn from the run, at the
mid camera:

| Stage | Ramp | Pixels | Share of screen | What those pixels are |
|---|---|---|---|---|
| THE DEAD POOL | `DPOOL_P` 05h+6 | 7,222 | 7.11% | grime and rust speckle over the whole back wall |
| THE FOREST | `SHRUB1` 04h+6 | 3,887 | 3.83% | highlights in the undergrowth along the floor |
| KAHN'S ARENA | `chair_p` 05h+6 | 3,216 | 3.17% | the bone pile heaped at the foot of the throne |
| THE FOREST | `tre3` 08h+6 | 1,706 | 1.68% | trunk highlights |
| THE DEAD POOL | `GRID_P` 0ah+6 | 902 | 0.89% | the grate |
| THE DEAD POOL | `DUSK2_P` 31h+7 | 607 | 0.60% | sky band |
| THE TOWER | `DECORA` 02h+6 | 249 | 0.25% | trim |
| THE WASTELAND | `BURN` 0ah+6 | 168 | 0.17% | - |
| THE ARMORY | `deco2` 26h+6 | 168 | 0.17% | - |
| THE WASTELAND | `WATCHER` 32h+7 | 81 | 0.08% | - |
| THE BRIDGE | `OUTER` 01h+6 | 0 | 0.00% | not drawn at this camera |
| THE BRIDGE | `MNT_p` 2ch+7 | 0 | 0.00% | not drawn at this camera |
| KAHN'S ARENA | `lock_p` 04h+6 | 0 | 0.00% | not drawn at this camera |
| KAHN'S ARENA | `orstand_p` 01h+7 | 0 | 0.00% | not drawn at this camera |

Four of the highest-span ramps draw **zero** pixels: a beautiful ramp on a
palette the composed stage never reaches is worth nothing, which is exactly why
the span-only scan is not the test.

## Pass 3 - and the three that are on screen barely move

Rotating each of the top three through a full loop, and diffing the half-phase
against phase 0 in the preview:

| Stage | Ramp | Mean pixel delta | Max delta |
|---|---|---|---|
| THE DEAD POOL | `DPOOL_P` | 9.7 / 255 | 37 |
| KAHN'S ARENA | `chair_p` | 11.9 / 255 | 48 |
| THE FOREST | `SHRUB1` | 3.9 / 255 | 49 |

(Preview deltas, GIF-quantised; coverage counts above are exact.)

**Shape decides the rest, and it goes the wrong way.** The two with the largest
deltas are the two that would read worst: the Dead Pool's pixels are scattered
speckle across the entire back wall, and the Arena's are a static bone pile.
Rotating scattered texture does not read as motion - it reads as the wall
crawling, which is what a corrupt palette looks like. The one coherent,
plausible candidate is the Forest undergrowth, a horizontal band where a cycle
could pass as wind, and it is the *dimmest* of the three at 3.9/255.

## Verdict

**Closed.** The three runs Midway cycles are the three worth cycling. Of the 41
remaining authored ramps, none combines enough coverage with a coherent enough
shape to be worth a `pid_cycle`: the best coherent candidate moves under 4% of
the screen by 4 levels of 255.

This closes the *stage background* case only. The helper stays available, and
cycling remains cheap for anything **authored for it** - a new effect whose
palette is built as a ramp from the start, which is how the Dead Pool's acid
was done. The finding is that no existing background art was.
