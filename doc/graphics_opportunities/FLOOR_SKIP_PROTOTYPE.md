# Uniform floor-prefix skipping: measured negative

**Status: measured in MAME, 12 September 2026. Negative result.**
This is opportunity 07 in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md)
and the fourth of its
[first prototypes](../GRAPHICS_OPPORTUNITIES.md#82-first-prototypes). Unlike
[BLDXPD](BLDXPD_PROTOTYPE.md), [NOOBPORT](NOOBPORT_PROTOTYPE.md) and
[STBURST](STBURST_PROTOTYPE.md) it is a frame-time opportunity, and it is the
first that could not be settled offline at all. **No ROM change was made.**

## Result

| Stage | curback | Floor band | Rows it may skip |
|---|---:|---|---:|
| **tower** | 3 | 181..255 | **54** — the shipped value, used as the control |
| tomb | 1 | 203..261 | 0 |
| battle | 2 | 210..254 | 0 |
| forest | 4 | 215..253 | 0 |
| armory | 5 | 192..253 | 0 |
| arena | 8 | 212..253 | 0 |
| port | 7 | 212..253 | 0 — settled from the display list alone |

**No additional constant top-row skip was supported on the tested stages.**
This closes the small prototype using the existing `skew_skip` mechanism.
It does not rule out camera-dependent masks, interior-row skipping, partial
width culling, or redesigned stage art; those require different machinery.

## Why the Tower is not just luckier

Six of the entries `dlists_tower` draws after `floor_code` are lists the stage
**builds** — `twr_skybg_lst`, `twr_bsky_lst`, `twr_bwall_lst`, `twr_bmonk_lst`,
`twr_runner_code`, `twr_prefl_lst` — a reflection authored to cover the marble
band. Every other stage draws only ordinary background modules after its floor,
and those are foreground scenery: a parapet strip, pillars, trees. Partial
width by nature, and the measurement agrees — the *first* row of every one of
those five floors is visible.

`port` needs no measurement at all: `dlists_port` draws **nothing** between
`floor_code` and the shadows, so there is no candidate coverage.

## Method: use the mechanism as the instrument

`floor_code` ([MKDISP.ASM](../../src/MKDISP.ASM)) draws the ground one 400x1
blit per texture row; `@skew_skip` is how many rows at the top it omits. So the
probe does not model coverage — it removes the floor and photographs what was
behind it:

1. Force the stage, park the camera at the left, middle and right scroll stops.
2. Run twice: once **observing** whatever the stage sets `@skew_skip` to
   itself, once with it pinned to the whole floor height.
3. Diff the frames. The first screen row that changes, minus the top of the
   floor band, is the answer.

```powershell
python tools/run_floor_skip_probe.py tower     # the control: must be 54
python tools/run_floor_skip_probe.py           # every floor stage
python tools/floor_skip_audit.py               # source-only: who is a candidate
```

The Tower control is included in the default stage sweep. A command naming
only another stage does not run that control; select `tower` explicitly when
rechecking the instrument.

## Three things that were wrong first, and what they teach

**An offline coverage model was tried and abandoned.** Composing the stage from
its BDB and counting opaque columns looked cheap, but
[stage_preview.py](../../tools/stage_preview.py) is calibrated against THE
TOWER, and its own report flags all three ARMORY planes as *"centre off by
-313.5"*: the plane world-x convention does not hold for stages whose mod table
gives `x=0` with a non-zero canvas origin. The likely outcome was a confident
wrong number, so the coverage claim was moved onto the machine. (The static
tool survives, reporting only what source proves — where each floor band is and
what is drawn after it.)

**Full opacity is not the shipped criterion.** The Tower's skipped band has
holes — the mirrored windows — and what shows through them is the hardware
autoerase colour, which `tower_mod` sets to the sky (`1D2CH`). The first probe
run measured **5** instead of 54 for exactly this reason: it forced the
baseline to `skew_skip=0`, so it was diffing against a version of the stage
that does not ship. The baseline has to be the shipped picture. `(57,74,99)`
turning up in the probe's pixels is the true sky, and
[TWRBACK.ASM](../../src/TWRBACK.ASM) had already measured and documented it.

**The fighters had to be hidden.** Two emulation sessions do not land an idle
animation on the same phase, and that showed up as 13-37 column-wide
differences at rows 186-198 — a torso, not a floor row. `m_inviso` on both
player objects leaves background and floor, which is the only question asked.

## What was not established

- **Vertical camera travel was not swept.**
  `floor_code` starts the band at `skew_y + (ceiling_y - worldtly)` and drops
  that many rows off the top, while background planes draw at
  `world y - worldtly` — so a climb moves the floor and everything over it down
  together *and* shortens the floor. A visible first row at a tested resting
  position is enough to reject a positive constant skip for that stage. It
  does not establish coverage for a future camera-dependent optimization.
- The Kombat Tomb's spike-ceiling variant (`dlists_ceiling`, which adds
  `baklst1`) was not probed separately. Its base display list measured 0, so
  there is nothing to protect.
- FBNeo/Fightcade and physical hardware were not tested. No renderer change
  was proposed, but the measurement itself remains MAME-specific evidence.

## Independent review

On 12 September 2026 the runner was corrected to honor `--rom-dir`, accept
an explicit matching `--map`, reject unequal screenshot dimensions, require
all three camera captures in each run, and fail on emulator process errors.
The original defaults selected the intended ROM, so the ignored override
does not by itself invalidate the recorded runs. The broader “only stage”
claim above has been narrowed to the mechanism and cases actually tested.

A fresh run with the corrected runner and the Wasteland shadow prototype ROM
reproduced **Tower 54** (positive control) and **Wasteland 0**, each with all
three camera stops. See [review measurements](floor_skip_review_results.json).
The other stage measurements above were not rerun during this review.

## The guard that remains

The Tower's 54 is only safe while its reflection lists are still drawn *after*
`floor_code`. `tools/floor_skip_audit.py --check` is registered in Phase D and
fails if that ordering goes away, or if a stage other than BGND.ASM and
TWRBACK.ASM starts writing `@skew_skip` without being measured.

## Files and evidence

- [Recorded measurements](floor_skip_results.json).
- [Runtime probe](../../tools/floor_skip_probe.lua) and
  [runner](../../tools/run_floor_skip_probe.py).
- [Source-only audit](../../tools/floor_skip_audit.py) and
  [build registration](../../build.py).
- [`skew_skip` in floor_code](../../src/MKDISP.ASM),
  [the Tower's claim on it](../../src/TWRBACK.ASM).
