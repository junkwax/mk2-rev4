# Artless span shapes (opportunity 18)

14 September 2026. **Prototyped and validated in MAME; compiled in, runtime-off;
built privately, not installed.**

## Mechanism

The DMA's `dmacal` write mode ("write constant on both zero and non-zero data",
SYSEQU.ASM) paints its constant colour over every pixel of the destination
rectangle, whatever the source holds. The game already uses it for solid
rectangles - `blnkarea` (UTIL.ASM), the high-score boxes (`drawbox`,
MKHSTD.ASM), the Tower sky band. So a filled shape can be drawn as **one 1-row
constant-colour rectangle per scanline span**: no art, no object, no palette of
its own (the colour is an index into colour map 0, `boonpal`, which is pinned).

## Implementation

`spanfx .set 1` (MAINEQU.ASM) compiles in `span_pass`, `sp_drain` and their
helpers in [MKDISP.ASM](../../src/MKDISP.ASM). Nothing draws unless a producer
writes `sp_ticks`.

- **Inputs** (all `.global`): `sp_cx`, `sp_cy` (screen), `sp_r` (outer radius),
  `sp_thick` (thickness; >= radius gives a disc), `sp_grow` (added to the
  radius each tick), `sp_col` (`[colour : map]`, e.g. `0E0E0000h` =
  `bpal_white` in map 0) and then `sp_ticks` (ticks to draw). `sp_spans` counts
  the spans in the last ring built.
- **Ring.** For dy = 0..R the outer and inner half-widths are kept
  incrementally with `d = x^2 + dy^2 - R^2` and `(x-1)^2 = x^2 - 2x + 1`: no
  multiply, no square root. Each row pair (+dy, -dy) gets two spans around the
  hole while dy is inside the inner radius, else one.
- **Build in process time, into a back buffer.** `span_pass` is called once a
  tick from MPROC's `prcdsp` (right after `timeint`). It clips each span to
  400x254 and writes `[1 : width]` + `[y : x0]` into whichever of `sp_buf0` /
  `sp_buf1` the display is *not* drawing, then publishes it with one long write
  to `sp_pub`. `SP_MAX` = 320 spans per ring.
- **Draw from the published buffer.** `sp_drain`, at `dma_score_area` (after
  every display list), programs the DMA straight from `sp_pub` the way `dql0`
  drains the misc queue: scale 1:1, sag `02000000h`, control `dmacal`. The ring
  draws in front of the scene, like the HUD. The misc queue is not touched.

### Why it is built that way (three failed versions)

| Version | Where the ring was built | What went wrong |
|---|---|---|
| 1 | top of `display` (display interrupt) | The HUD broke and the picture doubled - the interrupt is the wrong place for a long pass |
| 2 | process time, appended to the misc queue span by span | A big ring takes long enough that the display interrupt lands mid-pass: it drained half a ring, so the ring tore across two frames. The shared queue also capped it at 240 spans |
| 3 | process time, holding the misc-queue lock (`qdmaflg`) for the whole pass | The display found the queue locked nearly every frame and skipped it - big rings vanished |
| **4** | process time, into a private back buffer, published by one write | The display always draws the last **complete** ring |

## Validation (`tmp/span_fx/span_ring_check.py`, `span_ring_rig.lua`)

Kitana vs Scorpion on THE ARMORY. A static white ring is armed mid-fight at
(200,127), radius 40, thickness 8, and the checker replays the same algorithm.
Then a fresh ring starts at radius 4 and grows by 3 a tick.

| Check | Result |
|---|---|
| Expected spans, static ring | 144 (81 rows, 63 split by the hole) |
| Ring colour on the expected pixels, both static snapshots | **1818 / 1818** |
| That colour on the 408 pixels bordering the ring | **0** |
| Growing ring: `sp_spans` | follows the model up to the 320 cap (reached at radius 88) |
| Growing ring snapshots at radius ~70 / 82 / 91 | whole rings, no tearing, none missing, HUD intact |
| `overload` / `qdma_drops` | 2 (latched from power-on, unchanged) / 0 |
| Normal round end, span code idle vs the build without it | logs identical, 5/5 snapshots pixel-identical |

### Idle regression

`tmp/text_fix/text_ab.py --old tmp/text_fix/build --new tmp/span_fx/build`
(log `tmp/span_fx/idle_ab4.log`): a full two-round fight to FINISH HIM and the
FATALITY word, span code compiled in but never armed, against the build without
it. **Rig logs identical; 5/5 snapshots pixel-identical.**

## Limits and next steps

- Front-most only. Drawing at a depth would need `sp_drain` called at a display
  list marker, the way `geo_layer` inserts geometry.
- One shape at a time. A producer list (several rings, beams as per-row x
  ranges of a thick line, polygons as per-row edge pairs) is the obvious
  extension - every shape reduces to spans.
- Cost: about 4 spans per pixel of radius (2 x 2568 bytes of `.bss` for the
  buffers). Past radius ~85 the 320-span cap drops the outermost rows (the top
  and bottom of the ring); raise `SP_MAX` if a producer needs bigger rings.
- A span is one DMA setup, so a 320-span ring is 320 blits in the display's
  time. It stayed inside the frame here (`overload` unchanged), but two large
  shapes in a busy fight have not been measured.
- No gameplay producer yet: nothing in the game arms it. A natural first use is
  a shockwave on a heavy impact (Kahn's hammer, Jax's ground pound).
