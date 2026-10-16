# Raiden's ambient body bolts as computed geometry

**Status 2026-08-26: SHELVED. The Raiden bolts are removed.** `MKBOLTG.OBJ`
is out of `src/MAKEFILE` and `src/mk2.cmd`, the `.if bolt_geo` branch is gone
from `lightning` in [MKGUYS.ASM](../src/MKGUYS.ASM), and the sprite path is
back to stock. `src/MKBOLTG.ASM` and `tools/extract_bolt_paths.py` stay on
disk unlinked - the measured table and the sprite tracer are the expensive
part and cost nothing while they are not built.

**The CPU geometry pass itself is NOT removed and must not be.** `geoline`
stays `.set 1` in MKDISP because `box_rect` (the hitbox overlay) and `hudtext`
both emit through `geo_list`/`geo_count`. Compiling it out fails the build with
five undefined symbols - which is the only reason that mistake got caught.

### Why it was shelved

It worked, and it still was not the right host for the technique:

- **Colour.** The bolts render white and cannot be fixed by changing a
  constant - see the palette section below. A CPU pixel bypasses palette
  selection entirely.
- **Fit.** The technique wants thin single strokes. Raiden's ambient bolts are
  only marginally that, and the attack version is not remotely
  (4.9 strands/frame, 866 segments against a 256 budget - see the viability
  table below).

Both problems point the same way: the good hosts for CPU geometry are effects
that are **thin, straight and colour-agnostic**. The `box_rect` hitbox overlay
someone else built on this primitive is exactly that - four straight lines
with no palette requirement - and it is a much better fit than lightning was.
A background effect would be the next candidate to consider.

Everything below is kept because it is all still true and all of it was
expensive to establish.

---

## The model: deterministic paths, not noise

**This is the single most important thing about this feature.** The first
working version scribbled a *random* zigzag inside each measured bounding box.
It drew fine and it was wrong: MK2's ambient bolts are **smooth deterministic
animations**. Each style is a shape that travels a defined path across Raiden's
body over 7-12 frames. Re-randomising every tick reads as static, not as a bolt.

The joints in `src/MKBOLTG.ASM` **are** the shape the art draws. There is no
`random` call anywhere in the draw path. Do not put one back.

```
RN1BOLT4A   27x6   joints=4   (0,4) (12,3) (14,1) (26,3)
RN4BOLT4C   23x32  joints=8   (13,0) (18,1) (16,3) (2,9) (2,17) (4,21) (3,25) (13,31)
RN2BOLT2B   21x41  joints=6   (5,0) (4,6) (8,19) (7,21) (3,22) (18,40)
```

## Where the data came from

Two independent extractions, both reproducible, because neither source alone is
enough:

| what | how | why not the obvious way |
|---|---|---|
| box offset from Raiden's anchor | runtime capture walking the live multipart RAM | `MKBOLTS.TBL` anipoints are *sprite*-relative; the multipart delta is what actually places the art |
| stroke centreline + thickness | `tools/extract_bolt_paths.py` decodes the sprite pixels and traces them | the table gives a box, not a shape |

`tools/extract_bolt_paths.py` decodes **291/291** bolt frames with zero
failures, traces the median lit pixel per slice (walking whichever axis the
piece is longer on, so a vertical bolt traces downward), and simplifies with
Ramer-Douglas-Peucker.

**Measured stroke weight is 2.3-6.2 px.** The first version drew 1 px lines and
looked far too thin; each segment is now stroked `thick` times, with the offsets
running *across* the segment rather than always in y — RN4's pieces are 11x36,
and offsetting a vertical bolt vertically still draws one pixel wide.

## Pipeline

```
lightning (MKGUYS.ASM)        every 16-47 ticks, picks a style, walks its
                              frames, holds each for 3 ticks
  -> bolt_geo_emit (MKBOLTG)  strokes that frame's joints into geo_list
       -> geo_pass (MKDISP)   drains the DMA, opens CONTROL, plots with PIXT
```

`geo_pass` **consumes** `geo_count` — it zeroes it after drawing, so a producer
must re-arm **every tick**, not once per animation frame. That is why the
`lightning` loop holds each frame with an inner 3-tick loop rather than a single
`sleep 3`.

`GEO_MAX` is 192 (raised from 64 when the strokes gained real weight, since
thickness multiplies segment count). Measured cost: `peak_overload` stays at
**4**, unchanged from baseline, so this is free in practice.

---

## Which bolts are worth converting, and which are not

Measured 2026-08-25 by tracing every group and costing the worst single frame.
Segment cost is `(joints-1) x thickness x 2 colour passes`, summed over every
strand in the frame. `GEO_MAX` is 256.

| group | what it is | strands/frame | worst frame | verdict |
|---|---|---:|---:|---|
| `RN1BOLT`..`RN6BOLT` | ambient body crackle | 1.0-1.5 | 196 | **converted** |
| `RNSHORTBOLT` | short bolt attack | 1.6 | 102 | **viable, not done** |
| `RNVICBOLT` | victory pose bolts | 1.4 | 248 | borderline |
| `RN2DETHBOLT` | fatality | 1.9 | 422 | too expensive |
| `RN1DETHBOLT` | fatality | 2.0 | 804 | too expensive |
| `RNFLYBOLT` | **the flying lightning attack** | **4.9** | **866** | **not viable** |

**The flying attack bolt is the wrong target and should not be converted.** It
is 4.5x over budget, and the reason is intrinsic rather than a tuning problem:
it averages 4.9 separate strands per frame at 6-9 px thickness with up to 26
joints. It is a dense, branching, painted effect - the opposite of the thin
single strokes that made the ambient bolts a good fit. Reproducing it as line
geometry would cost more and look worse than the sprite it replaces.

`RNSHORTBOLT` at 102 segments is the one attack that would fit comfortably.

### Forked art needs per-strand tracing

A single centreline is only correct for a single stroke. Through a fork it
wanders through the empty space between branches - coverage of the long axis
fell to 0.20 on the worst frames. `tools/extract_bolt_paths.py` does connected
component labelling and traces each strand separately, which took `RNFLYBOLT`
from 0.84 to 0.95 mean coverage and fixed the handful of ambient frames that
branch.

In the table, **each strand is just another entry with the same `dx,dy`**, so
the emitter needs no special case for it.

---

## OPEN: the palette — and why it is not a constant fix

**The bolts render white. Attempted 2026-08-25 and NOT solved.** Accepted as
is. The important thing recorded here is *why*, because the obvious fix does
not work and costs a lot of time to disprove.

### The obvious fix, and why it fails

Raiden's bolt colours are the last two entries of his loaded costume palette:
`RADBLU_P[62]` = `7FFFh` (white core) and `[63]` = `1B3Fh` = `#30C8F8` (blue
border). Both confirmed in the palette data. So writing pixel bytes 62 and 63
looks like it should work.

It does not. It renders **orange** — in the Dead Pool stage, indices 62/63 are
`#B57318` / `#AD6B10`.

### There is no byte value that works

A full 256-value colour chart was drawn through `geo_list` and read back off
the screen. Findings:

- bytes **0-63** map to the *stage* palette (yellows, greys, reds)
- bytes **128+** repeat every 8 columns -
  `#000000 #FF0000 #00FF00 #FFFF00 #0000FF #FF00FF #00FFFF #FFFFFF`, identical
  for byte `128+n` and `192+n`. Only the low 3 bits are significant there.
- **no byte anywhere produces `#30C8F8`**

### The structural reason

**The DMA applies a sprite's palette during the blit, through the `const:pal`
register.** A sprite bolt is blue because the blitter was handed Raiden's
costume palette (`lgt_get_raiden_pal` retints the object for exactly this
reason). `geo_pass` writes the frame buffer directly with `PIXT`, which
bypasses palette selection entirely, so its bytes land in whatever the global
scan-out mapping happens to be. A CPU pixel cannot be told which palette to
use. This is a property of the draw method, not a wrong constant.

### The route worth trying next

`draw_bogline` (MKDISP.ASM) queues a **constant-colour DMA bar** - six
`dmaregs` writes including its own `const:pal`. Drawing each bolt segment that
way instead of with `PIXT` would get correct palette handling for free, paying
in DMA queue entries rather than CPU pixels. That is a different mechanism from
everything in this document and would need its own segment budget.

### Trap: do not trust CRAM reads at 0x01800000

Reads there disagree with what is actually on screen - byte 12 reads `F8F800h`
(bright yellow) from CRAM but renders `#B5ADAD` (grey). Several passes were
spent on conclusions drawn from that address before the discrepancy showed up.
**Read colours off a rendered screenshot, not out of CRAM.**

---

## Bugs found on the way — do not re-chase

All three were mine, all three are fixed:

- **`bge_rndh` returned its value in `a4`, which was `bolt_geo_emit`'s table
  pointer.** After the first piece the walk read from a random address. This
  killed the `lightning` process eight ticks into the first flash and made the
  effect run once per round. `bge_zig` (now `bge_thick`) saves `a4`/`a6`.
  *Found by bisect*: removing `callr lgt_geo_now` from the tick loop gave a
  perfect `flash=44 tick=1311 post=1311`, which proved the loop was fine and
  the fault was inside the emitter.
- **`a12` used to hold a loop variable in `lightning`.** a12 is the *process
  stack pointer*. Armed geometry on 1 frame in 4,154.
- **`a13` used as scratch in the stroke routine before calling `random`.** a13
  is the process pointer and the engine assumes it everywhere.

**Registers that are both sleep-safe and unreserved: a8, a9, a10, a11 only.**
a7 is the return address, a12 the process stack, a13 the process pointer.

## Warnings

- **`geo_list` is DATA and the plot loop runs with interrupts off.** A garbage
  delta is a hang, not a glitch. The `GEO_MAXLEN` (512) guard in `geo_line` is
  load-bearing: Outer Haven and Flapjack scroll vertically, an out-of-range
  screen-y produced a huge delta, and six sweep battles died mid-fight before
  it existed. Never remove it.
- **Geometry at `dsa9` lands behind whatever the DMA blits after the drain.**
  In practice the bolts read as in front of Raiden, which matches the sprite's
  `ozval = 0x10000`, but there is no z control here.
- **Never chain `build.py && makerom.py`** — `makerom` starts before the linker
  has finished writing `mk2.out` and packages the *previous* build. This cost
  several rounds of meaningless testing. Run `makerom.py` as its own command and
  check `rom/mk2_uj12.bin` is *newer* than `src/mk2.out` before trusting a test.

## Instrumentation

All `.global`, all write-only to the game, so reading them from Lua is safe.

| symbol | meaning |
|---|---|
| `bolt_flash` / `bolt_tick` / `bolt_post` | flashes entered / ticks emitted / ticks that survived the sleep |
| `bolt_g1` / `bolt_g2` / `bolt_g3` | `lgt_can_flash` outcomes: passed gstate / rejected airborne / rejected gstate |
| `geo_ran` / `geo_drew` / `geo_lastxy` | draw-path sentinels |
| `peak_overload` | frame-load meter, also on GAME AUDITS page 3 |

Healthy readings for a 2,500-frame Raiden fight:
`flash=43 tick=1220 post=1219 geo_drew=1219 peak_overload=4`.

`bolt_shut` counts **loop iterations, not shutdowns** — the counter landed on
the `jrnc lgt_shutdown` reference rather than the label. Left as-is because it
is useful where it is, but the name lies.

## Files

| file | role |
|---|---|
| `src/MKBOLTG.ASM` | measured path table + `bolt_geo_emit`, `bge_thick`, `bge_put1` |
| `src/MKDISP.ASM` | `geo_pass` / `geo_line`, `GEO_MAX`, `GEO_MAXLEN` guard |
| `src/MKGUYS.ASM` | `bolt_geo` switch, the `.if` branch in `lightning`, `lgt_geo_now` |
| `tools/extract_bolt_paths.py` | decodes the sprites and traces the strokes |
| `tools/run_battle_stability_sweep.ps1` | Raiden battle added; loads `tools/sweep_addon.lua` if present |
