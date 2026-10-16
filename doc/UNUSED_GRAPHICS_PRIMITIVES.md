# Unused graphics primitives — what they are, and what to build with them

**Status:** audit 2026-08-24; `LINE`/CPU-geometry implemented and working
2026-08-25 (see §1); `PIXBLT B,XY` HUD text (§3) and the hit/hurt box overlay
(§5) working 2026-08-25; the VRAM block fill (§2) working 2026-08-26.
**All five are now built.** §4 (`vcount`) runs and is instrumented, but its
effect is **hardware-only** — MAME resolves the palette once per frame, so
the split cannot be seen here. Read §4 before building on it.
**If you are about to draw with the CPU, read §5's
"the colour map applies to CPU writes too" first** — it is the one failure
mode that produces a correct picture in the wrong colour, and it had already
silently mis-coloured both of the other two. §1 also documents the `srl`/`sra`
sign bug that made every CPU-drawn world coordinate wrong on stages with a
negative camera y, and the page guard that now backstops it. **The geometry
bolts were removed 2026-08-26**; the box overlay (§5) is the only producer
left on this path. Companion to
[UNUSED_HARDWARE_EFFECTS.md](UNUSED_HARDWARE_EFFECTS.md), which covers the
**DMA object path** (per-object flags, scale, constant colour, display
registers). This document covers what that audit did not: the **34010's own
graphics instructions** and the **raster counters**.

The distinction matters, because it decides where an effect can live:

| | drawn by | reaches the screen via | costs |
|---|---|---|---|
| UNUSED_HARDWARE_EFFECTS.md | the custom DMA blitter | an object in the display list | zero CPU |
| **this document** | the 34010 CPU itself | direct frame-buffer writes | CPU time in the tick |

Everything here writes the frame buffer directly. That means it is **not**
sorted with the objects, so it lands either behind everything (draw before the
object pass) or in front of everything (draw after). Plan for that first —
it is the single biggest constraint on every idea below.

**Looking for which primitive to use for a given effect?** [GRAPHICS_CAPABILITIES.md](GRAPHICS_CAPABILITIES.md) indexes this document
and [UNUSED_HARDWARE_EFFECTS.md](UNUSED_HARDWARE_EFFECTS.md) together by *what you want on screen*,
and collects the traps that apply to both.

---

## How the audit was done

Two sweeps over `src/*.ASM` with comment lines stripped, so prose mentions do
not count as uses:

```
# every 34010 graphics instruction actually assembled
grep -nEi "^\s*(pixblt|pixt|fill|line|drav|cvxyl|cvdxyl|vlcol)\b" src/*.ASM

# every hardware register equate, and how many times it is referenced
python - <<'EOF'
import re,glob
from collections import Counter
eq=[m.groups() for l in open("src/SYSEQU.ASM",errors="ignore")
    for m in [re.match(r'^(\w+)\s+\.(?:set|equ)\s+0?([0-9a-fA-F]+)h?\b',l.strip())] if m]
blob="\n".join(open(f,errors="ignore").read() for f in glob.glob("src/*.ASM"))
c=Counter(re.findall(r'[A-Za-z_][A-Za-z0-9_]*',blob))
for n,v in eq: print(n, c[n]-1)
EOF
```

Result: of 47 hardware register equates only six are never referenced
(`dmatest`, `refcnt`, `cbit`, `stack_st`, `dudate`, `gnderacol`) and none of
them is a feature. **The register file is fully exploited. The instruction set
is not.**

| instruction | at the audit | now | where |
|---|---:|---:|---|
| `PIXBLT` | 1 | 2 | `DIAGDUTL.ASM` (service-menu font), `MKDISP.ASM` (§3 HUD text) |
| `PIXT` | 6 | 9 | `DIAGDUTL.ASM` x5, `MKDISP.ASM` x2 (§1), `MKINIT.ASM` x2 |
| `FILL` | 4 | 5 | `DIAGDUTL.ASM` x3, `MKINIT.ASM` x2 (`srt_clr` + §2 `srt_band`) |
| `CVXYL` | 2 | 2 | `DIAGDUTL.ASM` |
| `DRAV` | 1 | 1 | `DIAGDUTL.ASM` |
| **`LINE`** | **0** | **0** | — still none: §1 plots with `PIXT` instead, and why |
| `CVDXYL`, `VLCOL` | 0 | 0 | — |

`vcount` is not an instruction and so is not in that table: it was read 0
times at the audit (its only reference is compiled out) and is read by
`vsplit_poll` now. See §4.

At the audit that read: **the game proper never drew a single pixel with the
CPU.** Every CPU-side graphics instruction in the ROM belonged to the service
menu, except the VRAM fill behind the screen clear. That was the headline,
and it is what the rest of this document set out to change — the `now`
column is §1, §2, §3 and §5 arriving.

---

## 1. `LINE` — a hardware line drawer, zero uses

**Cost: low. Novelty: high. Art: none.**

The 34010 draws a Bresenham line in hardware from `DYDX`, with the current
`COLOR1`, honouring the window and the pixel-processing op. MK2 never issues
one. Everything that looks like a line in MK2 today is a **sprite**.

### `LINE` needs more than DADDR/DYDX/COLOR1 — and that is why it looks broken

**Correction to the first draft of this document.** It claimed the setup was
"the same register block `DIAGDUTL.ASM` already programs for `FILL XY`". That
is wrong twice over:

- **`LINE` is not a one-shot "draw from DADDR along DYDX".** It expects the
  Bresenham state — the pixel count, both increment terms and the running
  error — already loaded in the B file, and it consumes **B10–B13** doing it.
  Set only `DADDR`/`DYDX`/`COLOR1` and it assembles, executes, and draws
  **nothing**. No error, no trap. If you also computed `CONVDP` with
  `LMO b3,b10` you have just clobbered one of the registers it needs.
- **`DIAGDUTL.ASM` does not give you a general line routine to copy.** Its
  loop is `DRAV`-based and its own comment says
  `DRAV DX: ASSUME HORIZONTAL LINE` — it only handles axis-aligned segments.

### Working implementation (2026-08-25)

`geo_pass` + `geo_line` in [MKDISP.ASM](../src/MKDISP.ASM), behind
`geoline .set 1`. Verified in game: a jointed bolt tracking both fighters,
19/19 on the battle stability sweep. It plots with **software Bresenham and
`PIXT`** rather than `LINE`, because `PIXT` needs none of the B-file state and
`DIAGDUTL` already proves it works.

What it took, in the order the problems appeared:

1. **A hook.** `dsa9` in the display pass, after every object and the score
   area are queued — the same point Midway hooked `bog_line`. Note
   `draw_bogline` is **not** a CPU-draw precedent: it queues another DMA blit
   (six `dmaregs` writes) and never touches a pixel. There is no in-game
   CPU-draw precedent in this ROM.
2. **A drain wait.** `dmaqwait` does not exist — it is commented out in
   `UTIL.ASM`. The queue-empty condition is `dma_interupt` having cleared its
   own enable bit in `intenb` (it does that when its counter hits zero), then
   `dmactrl` going idle. Interrupts must stay **on** for that spin or the
   queue can never drain.
3. **Opening `CONTROL`.** The game runs with the window field set to `w3`
   (`0c0h`, SYSEQU.ASM) — *inhibit writes outside window*. Every CPU pixel
   outside `WSTART`/`WEND` is dropped silently. Clear the window and PPOP
   fields for the draw, restore `CONTROL` afterwards.
4. **Cross-file loads.** `move *a4+,b9,l` is `REGISTERS IN OPPOSITE FILES`.
   Memory operands cannot target the B file; load A-file first, then
   `move a0,b9`, which *is* a legal cross-file move.
5. **Register discipline.** `geo_line` works in a0–a8, so the caller's list
   pointer, page origin and loop counter live in a9–a11. Keeping the counter
   in a4 let the callee trash it and the loop never terminated —
   `ran` froze, `drew=0`, hung machine.
6. **A length guard.** `geo_list` is *data*, and the plot loop runs with
   interrupts off, so a garbage delta is a hang rather than a glitch. Segments
   longer than `GEO_MAXLEN` (512) are dropped. This is not theoretical: Outer
   Haven and Flapjack scroll vertically, an out-of-range screen-y produced a
   huge delta, and the sweep died mid-fight on six battles before the guard
   went in.

**Debugging note that paid for itself:** the sentinels (`geo_ran`,
`geo_drew`, `geo_lastxy`, all `.global`) are what made this tractable.
`ran=1575 drew=199` with a correct on-screen `lastxy` and a blank screen
isolates the fault to the draw instruction itself, which no amount of staring
at the setup code would have done.

### In-game uses

- **Raiden's lightning, as real geometry.** Started 2026-08-25 — the measured
  paths and the emitter are done, the wiring into `lightning` is not. See
  [RAIDEN_BOLT_GEOMETRY.md](RAIDEN_BOLT_GEOMETRY.md) before touching this.
  Today `MKBOLTS.TBL` is 291 frames
  of pre-drawn bolt art, and it is also the single biggest bpp-reduction
  target in the build (48 KB, see SPRITE_COMPRESSION.md A1). A bolt drawn as
  4-6 jointed `LINE` segments with a per-frame random jitter is *more* varied
  than the canned art, costs no video ROM at all, and can terminate exactly on
  the victim instead of at a fixed offset. Keep the impact flash as a sprite.
- **Outer Haven's portal arc. BUILT 2026-08-27** (`oh_warp_arc`, BGND.ASM,
  behind `fxdemo`). It replaces `warplite_animator`'s six-frame spark on that
  stage — the Portal keeps the sprite, which is what makes the two comparable.
  Same cadence and same sound; five points and four segments, re-jittered every
  tick, so a burst is 36 different bolts against the sprite's six, with no
  video ROM at all. Three things it got WRONG first, all worth keeping:
  - **The hole does not move, and the plane list will not tell you that.**
    The archway is `ohspiral4BMOD`, the "sky" module on baklst6, and
    `port_scroll` gives plane 6 a rate of **zero** — so it is nailed to the
    screen for the whole stage, and `warplite_animator`'s screen pinning at
    194 is correct by design. The arc was first anchored to `worldtlx3` on the
    theory that the archway was the "house" module; it drifted up to **175px**
    out of the hole and crackled across the stonework. Worse, the rig that
    "verified" it computed the hole's position exactly the way the ASM did and
    then asserted the bolt landed there — which proves the two agree with each
    other and **nothing at all** about where the hole is.
    [tools/hole_locate.lua](../tools/hole_locate.lua) does it honestly: find
    the hole in the frame buffer at eight camera stops, then report which
    plane's `worldtlx` keeps `hole_screen_x + worldtlxN` constant. Measure the
    art. Do not infer it from the module list, and never let the check share
    the model it is checking.
  - **The hole is an OVAL.** Endpoints at the corners of its bounding box put
    16 pixels of bolt on the top step — counted, not eyeballed, by comparing
    an arc frame against an arc-free frame at the same camera and asking which
    arc pixels are over something that is not the void. The diagonals now
    reach less far than the axes.
  - **Depth is the one thing it cannot have, and standing down is not a
    substitute.** `geo_pass` runs at `dsa9`, so its pixels land in front of
    everything, where the sprite sits behind all six planes and is visible
    only because the hole is transparent. The arc stands down when a fighter
    is within 28px of the hole — but a fighter's sprite is twice that wide, so
    what you actually see is the bolt snapping off and on as somebody walks
    past, and clipping his shoulder at the threshold. **This is the open
    defect on this effect.** The fix is a CPU pass at the `-2` display-list
    marker, where `dmaq10` already runs `shadow_p1p2` — after the background
    planes, before `objlst` — which is the depth the sprite had. Nothing else
    on the geometry path can put a line behind a fighter.
- **Kano's eye laser / Kung Lao's hat trail.** A beam that must connect two
  moving points is exactly what a sprite cannot do without a scaling stretch;
  `LINE` connects them by construction.
- **Shang Tsung's soul streams**, the Portal's electrical arcs, Sub-Zero's
  freeze crackle — anything where the shape depends on where both endpoints
  happen to be this frame.
- **Debug overlays for free:** hitbox rectangles are four `LINE`s. **Built
  2026-08-25 — see §5.** The retail `f_colbox` overlay is a solid blit that
  hides the sprite it is explaining; outlines do not.

### Watch out for

- It writes the frame buffer directly, so it draws over everything queued
  before it. Issue it after the object pass for a foreground beam.
- `PMASK` is initialised to 0 and never touched (UNUSED_HARDWARE_EFFECTS #8);
  leave it that way or the line writes nothing.
- Geometry drawn at `dsa9` still ends up **behind** anything the DMA lands
  after the drain — in practice the fighters and the FIGHT overlay draw on top
  of it. If you need it strictly in front, that is a separate problem from
  getting it to draw at all.
- Budget it. A 200-pixel line is 200 pixel writes; that is fine, a hundred of
  them per frame is not. See [PERFORMANCE.md](PERFORMANCE.md) for the meter
  (`peak_overload`) that tells you when you have gone too far.
- **Nothing clips.** `geo_line` bounds a segment's LENGTH, never its POSITION,
  and the window field is off while it plots. Clip in your producer — see the
  open defect below.

### FIXED: `srl` on `worldtly` threw the sign away

**Found and fixed 2026-08-25.** This is the one that mattered, and it was
hiding behind a retracted measurement — see the correction at the end.

`worldtlx` / `worldtly` are **signed** 32-bit fixed point, and `worldtly` is
negative on stages that sit above the world origin — Dead Pool runs at **-8**.
Every world-to-screen conversion in the CPU-draw path did:

```asm
    move    @worldtly,a3,l
    srl     16,a3            ; LOGICAL shift - the sign is gone
    sub     a3,a2
```

`srl` turns -8 into **65528**, so every screen y came out at about -65445.
Two different symptoms, one cause:

- The **box overlay** clips its own segments, so it correctly threw *every*
  edge away. The overlay drew nothing at all, while its sentinels showed
  `box_ran=420` (the pass ran), `box_emit=3414` (rectangles were computed) and
  `box_seg=0` (not one segment survived the clip). That triple is what
  identified it — no single counter would have.
- The **bolt producer** does not clip, so the same bad coordinate went
  straight to `PIXT`.

Fixed with `sra` in `box_hline`, `box_vline`, `box_anchors` (MKDISP.ASM) and
`lgt_geo_now` (MKGUYS.ASM). Verified: the overlay draws, and Raiden runs 6/6
clean on the battle sweep.

**If you write a world-to-screen conversion here, use `sra`.** `srl` looks
right and works everywhere `worldtly >= 0`, which is most stages.

### FIXED: nothing bounded a segment's POSITION — `geoguard`, and what it cost

`geo_line` bounds a segment's **length** (`GEO_MAXLEN`, 512) but nothing
bounded its **position**, and `geo_pass` has cleared CONTROL's window field by
the time it plots — the only way a CPU pixel lands at all. So an out-of-page
destination was a real write.

`geo_onpage` now refuses any segment with an endpoint outside
`0..scrrgt` x `0..scrbot`, behind `geoguard .set 1`. It uses **one unsigned
compare per coordinate** — a sign-extended negative is a huge unsigned, so
"below zero" and "past the edge" are the same test — and computes the end
point only after the start passes.

**Measured on the Raiden battle** (the only one that runs the bolt producer),
overlay off, 480 frames:

| | `overload`=2 | tail | refused |
|---|---|---|---|
| guard off | 467 (97.1%) | 14 at 3 | — (writes happened) |
| guard on | 454 (94.4%) | 26 at 3, 1 at 4 | 900 |
| **sprite bolts, guard on** | **481 (100%)** | none | 0 |

Three things follow, and they are easy to get the wrong way round:

- **`MKBOLTG` really does emit off-page segments — about two a frame.** An
  earlier note here claimed zero after the `srl`→`sra` fix; that was measured
  by sampling `geo_lastxy`, i.e. *one segment per frame*, and simply missed
  them. Both of this document's earlier off-page figures were wrong, in
  opposite directions.
- **What it refuses is marginal, not wild.** A sampled rejection was
  `x=-1, y=3` — one pixel off the left edge, which with `xpadding` would have
  landed in padding anyway. So the guard is **insurance against a producer
  bug**, not a fix for live corruption. Its value is that the `srl`/`sra` bug
  earlier that day produced coordinates around 65000, and `geo_list` is data.
- **The CPU bolts are the whole cost.** They are the only reason `geo_pass`
  is expensive; with sprite bolts every frame is clean. The guard's 2.5% is
  paid *only* on Raiden, and only because the bolts emit up to `GEO_LIMIT`
  segments a frame to catch two bad ones.

**Resolved 2026-08-26 by removing the bolts.** `MKGUYS.ASM` is back on the
sprite path and `MKBOLTG` is out of `MAKEFILE` and `mk2.cmd` — 3,552 bytes of
program ROM reclaimed, headroom now 207,154.

That settles all three of the above at once. The box overlay is the only
producer left on this path, it clips its own segments, and on the Raiden
battle — the one that could not stay clean — the result is now:

```
overlay ON (mask 3):  geo_drew +480/480   box_seg +3860   dropped +0
LOAD overload:        2 on 481/481 frames  (100.0%)
```

So `geoguard` is free in practice: it refuses nothing, and it checks about
eight segments a frame instead of 248. It stays on as the backstop it was
meant to be — the thing that makes a future `srl`/`sra`-class producer bug a
dropped segment rather than a write into memory.

**If the geometry bolts ever come back**, the fix is to clamp in
`bolt_geo_emit` at the **joint** level (~10 joints) rather than letting 248
expanded segments each pay for a check.

**Correction (retracted measurement).** An earlier version of this section
claimed the bolt producer wrote off the page 533 times a fight, measured with
`tools/raiden_geo_range_probe.lua`. **That number was an artifact of the
probe**, not a defect: it compared `geo_lastxy` (written by the *last*
`geo_pass`) against `pageaddr` read later from Lua, and the page flips every
frame with the two origins exactly 256 apart in y. Comparing against the wrong
one reports a perfectly good write as off-page. The artifact rate measured
~27% of frames, which matches the "533 per fight" figure almost exactly. With
a detector that accepts a destination inside *either* page, the count is
**0**. The lesson is worth more than the retracted number: on a double-buffered
machine, never validate a coordinate against a page origin you sampled at a
different time.

---

## 2. VRAM shift-register block fill — the boot-time screen clear, aimed

**Cost: very low. Novelty: moderate. Art: none. Status: implemented and
verified 2026-08-26.**

[MKINIT.ASM:1387](../src/MKINIT.ASM#L1387) `srt_clr` does this:

```asm
	movi	255*02000h,b2
	pixt	*b2,b2			;load vram shift registers
	...
	movi	(1*x)+(((scrbot+1-scrtop)/2)*y),b7
	fill	xy			; 127 sr-to-memory transfers
```

That is **VRAM block-write mode**: load the shift register once, then blast
whole rows into memory without the CPU touching a single pixel. Cost is
`rows/2` memory cycles regardless of how wide the band is — the pitch is
doubled (`convdp` = 012h), so one transfer moves a row *pair*.

**Correction to the first draft of this document**, which said it "clears the
frame buffer at power-on and is never used again". It runs whenever
`f_auto_erase` is set — character select, attract, buy-in, high scores — from
the display interrupt, right after the page flip. What it has never done is
clear anything *other* than the whole page.

The colour is not a register. `srt_clr` loads the shift register from **lines
510–511**, a two-line strip past both pages that
[MKDISP.ASM:2560](../src/MKDISP.ASM#L2560) stamps with `erasecol` at init.
Whatever is in that strip is what the screen clears to.

### Working implementation

`srt_band` in [MKINIT.ASM](../src/MKINIT.ASM), behind `srtflash .set 1` in
`MAINEQU.ASM`, is `srt_clr` aimed at an arbitrary band:

```
	a0 = top scanline of the band, page-relative
	a1 = scanline count (rounded down to even — one transfer is a row pair)
	a2 = pixel value (a bpal_* pair such as 0e0eh works; the low byte is used)
```

`flash_pass` in [MKDISP.ASM](../src/MKDISP.ASM) drives it from `dsa9`,
alongside the other two CPU passes and for the same reason: **a flash has to
land on top of the fighters**, so it cannot go where `srt_clr` goes. The
display interrupt runs *before* the frame is drawn; anything filled there is
immediately painted over. Objects are queued at `dsa9`, not drawn, so drain
first — see §1.

Any process arms it by writing `flash_col` and `flash_ticks` (frames).
`white_flash` (MKFX.ASM) now does, so every shatter, burn, Toasty and fatality
beat that already called it gets a play-area pop for its 2 ticks.

**A driver that wants something other than the whole play area in one flat
colour arms a band list instead**: up to `FLASH_MAXB` records of

```
	.word	top, rows, even-row colour pair, odd-row colour pair
```

filled in with `arm_flash_band` (a0 top, a1 rows, a2 [odd:even], a3 record),
and the count written to `flash_bands` **last** — that ordering is what stops
`flash_pass` picking up a half-built list. `srt_band` is now three pieces so
the list can be filled cheaply: `srt_stamp2` loads the two-line source strip,
`srt_fill` does one band, `srt_unstamp` puts `erasecol` back. `flash_pass`
stamps only when the colour actually changes between bands and unstamps once
at the end, so five bands in three colours cost four stamps, not ten.

**The list is per-FRAME.** `flash_pass` zeroes `flash_bands` as it reads it,
so a driver holds an effect by re-arming every tick — and a stage that stops
driving cannot leave a band behind on the next one. That is the Dead Pool
acid reflection's leak (`doc/DEADPOOL_ACID_REFLECTIONS.md`) designed out
instead of gated around: there is no state left to leak.

### Two things that are not obvious

**The colour strip has to be borrowed and put back.** There is no spare line
to claim: the layout comment on `page0adr` accounts for all 512 (`(1 dead, 254
playfield)*2, 2 autoerase`). So `srt_band` stamps lines 510–511 with the flash
colour, fills, and stamps `erasecol` back before returning — and the caller
holds interrupts off across the whole thing, or the display interrupt can
catch the strip mid-swap and auto-erase the screen to white. The stamp is 512
word writes twice, about 0.5% of a tick.

Those stamp writes are **CPU pixel writes**, so `dmacmap` has to be forced to
0 first or the strip, and therefore the fill, comes out in whichever palette
the last sprite used. See §5. The `fill` itself is immune — it is a VRAM row
transfer and never goes through the pixel path.

**Two lines of source strip is a free dither.** One transfer moves a ROW
PAIR out of lines 510–511, so stamping the two lines *differently* alternates
them a row at a time down the whole band, for the same single stamp. That is
the only way this primitive can show a colour the palette has not got: `boonpal`
has three greens and no midpoints, and 6/6, 6/8, 8/8, 8/7, 7/7 is five levels
out of three colours. The phase is absolute screen parity — the band's top row
takes line 510 — so a band starting on an odd row swaps the two.

**Do not clear `env` mid-frame.** `srt_clr` drops screen refresh *and* video
enable (`andni sre+env`). `sre` genuinely has to go, because screen refresh
uses the same shift-register cycles the transfer needs. `env` does not, and
dropping it blanks the beam: it cost a **black scanline straight across the
flash**, at a fixed y, on every frame filled. `srt_clr` gets away with it
because it runs at boot with the display already dark. Clearing only `sre`
removed the line and changed nothing else — measured both ways.

### What it costs

Nothing measurable. `peak_overload` stays at **2** — the floor — with the
flash running, and `qdma_drops` at 0. 21/21 on the battle stability sweep.

### Verified

[tools/srt_flash_test.lua](../tools/srt_flash_test.lua) checks the three
claims separately, because "it looks white" would pass on a full-screen
blank:

```
baseline:     play band 2.2% ink 0e
during flash: play band 100.0% ink, HUD band 0.0% changed
after flash:  play band 2.1% ink, flash_ticks=0
white_flash wiring: flash_did 12 -> 14 over a forced death
```

It runs on **Kombat Tomb**, not the Dead Pool as it used to: `dp_acid_glow`
re-arms the band list on that stage every frame, so `flash_ticks` there is
never 0 and "it stops on time" cannot be asserted. That is the per-frame
design working, not a regression — but a test of the bare primitive has to
stand somewhere nothing else is driving it.

[tools/flatband_demo.lua](../tools/flatband_demo.lua) covers the two examples
(`-Stage deadpool` / `-Stage peak`). It never counts pixels of a colour — the
life bars and name plates are drawn out of `boonpal` too, so a count passes on
coincidence. What only a block fill can do is make a row **uniform across all
400 px** and make consecutive rows alternate between exactly two values, so it
asserts both on every sampled row, plus a control row just above the band that
must NOT be uniform, plus the invariant that the five courses never invert.

The **HUD band 0.0% changed** line is the one that matters — that is the whole
difference from `long_white_flash`, which blanks the display and takes the
life bars with it. The last line drives a death routine through `p_wake` (the
technique the fatality rigs use) because a plain KO never calls `white_flash`;
`flash_did` moving by exactly 2 matches the 2 ticks `white_flash` arms.

### Two worked examples, both behind `fxdemo .set 1` (MAINEQU.ASM)

**`dp_acid_glow` — Dead Pool, the acid breathing. BUILT AND REMOVED
2026-08-27**, at the owner's call: it worked and measured clean, and it was
still a green band across the bottom of somebody else's stage. The findings
are why this entry stays. Five bands of two rows each covering screen
244–253, re-armed every frame, each standing on its own rung of a seven-rung
ladder so the light falls off upwards. What the build cost was:

- *Which strip* is the whole design. The fill is not in the display list, so
  it lands in front of everything. `DEADPOOL_ACID_REFLECTIONS.md` measured
  acid in two places: 196–207 **behind** the walkway, where a band cuts both
  fighters off at the knee and is unusable, and 246–253 **in front**, where
  the feet land on 224 and nothing is ever drawn. Only the second one works.
- *Which colours.* The first attempt used boonpal's greens straight and came
  out a neon bar: they are pure — 6, 8 and 7 are G=17, 25 and 29 with no red
  or blue — and the acid is a dark olive around (16,33,0). **Index 16**
  (`0080h`, G=4) is the one that matches it and nothing else in map 0 is
  close, so the ladder starts there and climbs. Read the art's real colours
  out of a screenshot before picking a fill colour; the palette's names are
  no guide.
- The band top is derived from `worldtly` every frame (SRA, not SRL — §1) and
  clipped, so a vertical camera chase cannot walk it off the screen.

**`peak_flash` (BGND.ASM) — Yoteigai Tor, lightning.** `peak_thunder`'s big
bolt — slot 5, the one that reaches down the sky — creates a process that
fills rows 46–253 white for one tick and white/blue dithered for the next.
This is the "full-screen flash that spares the HUD" case with nothing else to
compare against: `irqskye` is invisible on a stage with a sky panel, a
mountain, a deck and two railings in front of it, and `long_white_flash` takes
the life bars. Measured **HUD band 0.0% changed** under the flash.

Verifying that one needs the seed stirred. The slot comes from `randu` and the
RNG reseeds identically every round, so a scripted rig replays one roll of the
dice for ever: a run that draws no 5 in its first dozen bolts will never draw
one however long it is left. `flatband_demo.lua` writes `rand` every 137
frames, which is what a coin drop does anyway.

### Still on the table

- **Wipes and column/row transitions** between rounds or on a stage change —
  `srt_band` already takes a top and a height, so a wipe is a producer that
  walks them per tick, and the band list can carry a whole comb of them.
- **Faster `clr_scrn`.** The routine at `UTIL.ASM:348` is the general path;
  anything clearing a large rectangle every frame could use this instead.

### Watch out for

- Block-write mode fills at the shift register's granularity, so the fill is
  aligned and rectangular, and the height is rounded down to even. It is a
  band tool, not a shape tool.
- It writes the *frame buffer*, and MK2 double-buffers — fill the page you are
  about to draw into (`@pageaddr`), not the one on screen. `srt_band` does.

---

## 3. `PIXBLT B,XY` — 1-bit source expanded to colour

**Cost: low. Novelty: low. Value: ROM space. Status: implemented and
verified 2026-08-26.**

`DIAGDUTL.ASM:184` uses `PIXBLT B,XY` to draw the service-menu font: a
**binary** source expanded to `COLOR0`/`COLOR1` on the way out. Until now the
game proper never used it — all in-game text is 1bpp *sprites* through the DMA
(`MKTEXT.TBL`, 173 records).

The interesting property is the ratio: a binary source is **1 bit per pixel
against MK2's 6bpp baseline**, so anything genuinely two-colour costs a sixth
of the video ROM. And because the two colours are registers rather than a
palette, one source can be drawn in any colour pair without a second copy.

### Working implementation

`hud_pass` / `hud_string` / `hud_num` in [MKDISP.ASM](../src/MKDISP.ASM),
behind `hudtext .set 1`, hooked at `dsa9` immediately after `geo_pass`. The
demo producer `hud_test` (`hudtest .set 1`) prints both players' live HP under
the life bars, in two different colours off one set of glyphs.

**It costs no art at all.** The glyphs are `sysfont` (DIAGFONT.ASM), already
in the program ROM for the service menu. That is worth stating plainly because
it looks like it violates the rule that sprite pixels may not live in program
ROM — it does not. That rule is about the **DMA blitter**, which can only
source from the image ROM bus. `PIXBLT` is a **CPU** instruction reading the
CPU bus, the same bus `movie_run` decompresses REVX over. Different bus,
different answer.

It is a *second* pass rather than an extension of `geo_pass`, on purpose:
`PIXBLT` consumes most of the B file (B0–B14, per `DIAGDUTL`'s own comment)
where `PIXT` needs almost none of it, so folding the two would mean re-proving
the one that already works. The duplicated prologue costs a drain spin that
exits immediately whenever `geo_pass` has just run.

Everything in §1 about drains, `CONTROL`'s window field and cross-file loads
applies unchanged. Four things are specific to this pass:

1. **Save the B file AFTER the drain, not on entry.** `dma_interupt` owns
   b8/b10/b11/b13/b14 and legitimately changes them while the drain spin runs
   with interrupts ON — **b13 *is* the queue counter** it decrements to zero,
   which is the drain condition itself. Saving on entry and restoring on exit
   winds that counter back to a stale value and leaves the queue permanently
   mis-counted. Once drained and with interrupts off, nothing moves them.
2. **Transparency is not optional.** `PIXBLT B` expands the 0 bits to `COLOR0`
   exactly as it expands the 1 bits to `COLOR1`, so without the `T` bit in
   `CONTROL` every glyph arrives in an opaque box. `COLOR0` = 0 plus `T`
   drops those writes and the picture underneath survives.
3. **`dmacmap` must be forced to 0**, for the reason in §5 — otherwise the
   text renders in whichever palette the last sprite of the frame used. This
   is exactly what made the first demo's `bpal_white` / `bpal_yellow` come out
   as two near-identical greys.
4. `sysfont`'s letters live at the **uppercase** ASCII codes (DIAGFONT's
   comments say "a", but index 33 is `'A'`), and **bit 0 of a source byte is
   the leftmost pixel**. Source pitch is the glyph width rounded up to whole
   bytes.

Assembler trap: `,L` is valid as `ADDI`'s long-immediate suffix but **not** as
`MOVE`'s field selector. `move *a5,a5,L` fails with `AN IDENTIFIER IN THE
EXPRESSION IS INVALID` and "The following symbols are undefined: L". Use
lowercase `,l`.

### How to verify it — and how not to

**Do not verify this by counting pixels of the ink colour in the band.** The
life bar, the name plate and the WINS counter are all drawn from `boonpal`
too, so they contain the same indices, and the count moves when the bar length
moves. A colour-count check passes on coincidence: the first one here reported
a healthy-looking 88/27/96 while the digits were in fact sitting invisibly
under the bar's metal frame.

[tools/hud_pixblt_test.lua](../tools/hud_pixblt_test.lua) instead reads the
glyph bitmaps out of the ROM the game is running, computes where every set bit
must land, and requires the frame buffer to hold the requested palette index
at **every one of them**. That pins position, spacing, bit order, colour and
transparency in a single assertion. Result:

```
P1 161 at (32,46): 80/80 set pixels are ink 0e   P2 7   at (344,46): 24/24 ink 0d
P1 88  ...         72/72                          P2 100 ...          93/93
P1 5   ...         38/38                          P2 161 ...          80/80
```

Sampling the frame buffer from Lua has its own trap: MAME's TMS34010 program
space is bit-addressed but `read_u16` **aligns down** to a 16-bit boundary, so
a byte-granular walk returns every odd pixel and every odd font row as a copy
of its neighbour. That artifact looks exactly like a rendering bug in the code
under test. Read bytes through the `rd8` helper in that script.

[tools/hud_pixblt_testmode.lua](../tools/hud_pixblt_testmode.lua) is the same
check against a `test_mode .set 1` ROM, which boots straight into a fight —
useful whenever the character-select path is broken.

### What it costs

Nothing measurable. With two strings drawn every frame of a fight,
`peak_overload` sits at **2** — the floor, meaning every process pass finished
inside its tick — and `qdma_drops` at **0**
([tools/hud_perf_probe.lua](../tools/hud_perf_probe.lua)). Compare §5's
per-piece box layer, which takes the same meter from 4 to 35. 21/21 on the
battle stability sweep.

### In-game uses

- Damage numbers, combo counters, or any new HUD text, at 1/6 the ROM of a
  sprite font and recolourable per-hit. `hud_num` already renders a decimal
  value; a producer only has to queue `[xy, colour, text]` and re-arm it every
  frame, because `hud_pass` consumes the list once per pass.
- Silhouette/stencil effects — a shadow shape, a "ghost" of a move, a flash
  outline — from a single 1bpp master drawn in whatever colour the moment
  wants. Compare UNUSED_HARDWARE_EFFECTS #2, which achieves recolouring on the
  DMA path but still pays 6bpp for the source.

### Watch out for

- It is CPU-side, so it is subject to the same "draws over the object list"
  rule as everything else here, and it costs real cycles per pixel. Right for
  a HUD element, wrong for a character.
- The record list is **data**, and the plot runs behind a disabled window, so
  an out-of-range record scribbles over other VRAM rather than glitching.
  `hud_string` bounds the start position and stops at the right edge; keep it
  that way, for the same reason §1 has `GEO_MAXLEN`.

---

## 4. `vcount` — raster-position readback, cheaper than the raster interrupt

**Cost: low. Novelty: high. Art: none. Status: both halves built 2026-08-26;
the `dpytap` band was then SWITCHED OFF (`vshim .set 0`) and nothing uses any
of it today.**

The palette split is hardware-only — MAME resolves colour once a frame. The
`dpytap` band *is* visible in MAME, and worked, but a raster effect moves
every plane on its scanlines and so distorts the foreground; see
GRAPHICS_CAPABILITIES.md, "Why the raster band was removed". The coverage
finding below is the part worth keeping.

[UNUSED_HARDWARE_EFFECTS.md](UNUSED_HARDWARE_EFFECTS.md) item 7 costs a
mid-screen raster split as "high", because the display interrupt has to coexist
with the DMA-completion interrupt that drives the object queue. **You do not
need the interrupt.** `vcount` (`0xC00001D0`) is directly readable.

Retail never reads it. The one reference in the tree,
[MKDISP.ASM](../src/MKDISP.ASM), sits inside `.if bog_line` with
`bog_line .set 0`, so it is **not assembled into the ROM at all**. Midway used
it for a debug raster-position bar and then compiled it out.

### Working mechanism

`vsplit_poll` / `vsplit_reset` in [MKDISP.ASM](../src/MKDISP.ASM), behind
`vsplit .set 1` in `MAINEQU.ASM`, polled from **two** sites in
[MPROC.ASM](../src/MPROC.ASM): `prcdsp`'s tick busy-wait, and `prcd1a`, the
process dispatch list walk. The second is what reaches the top of the frame
— see the correction below. Arm the palette split by writing:

```
	vsplit_cram   colour ram address of the entry to rewrite
	              = 01800000h + ((map*64) + index) * 16
	vsplit_top    the colour above the line (5-5-5, as in the palette)
	vsplit_bot    the colour below it
	vsplit_line   the scanline to switch on.  ZERO DISABLES — write it
	              LAST when arming and FIRST when disarming.
```

`vsplit_reset` runs once a tick from `prcdsp` and forces the entry back to the
top colour. Without it the split is only self-correcting while the poll
happens to spin on both sides of the line; spin entirely below it and the
bottom colour sticks for good.

Disarmed it costs two instructions per poll (`move` + `jrz`) — three now,
since `vshim_lo` is checked as well before giving up. Measured on the Kahn's
Arena shimmer, which is the only thing that arms any of this today:
`peak_overload` **2** in-fight (the floor) with the band live at ~6 `dpytap`
writes a frame, `qdma_drops` 0, 21/21 on the battle stability sweep.

Read `peak_overload` carefully — it is a **high-water mark since boot**, and
attract mode plus character select push it to 4 before a fight ever starts.
Zero it at fight start (nothing branches on it; see MPROC.ASM) or you will be
measuring the menus and attributing it to whatever you just built.

### What the measurement said

Two things came out of
[tools/vsplit_test.lua](../tools/vsplit_test.lua). The first was wrong in a
way that closed off the whole top of the screen for a month; the second is
still true, and is why the *colour* half of this section has no picture.

**1. `prcdsp`'s busy-wait only sees `vcount` 203–273.** This document
previously called it "a natural place to spend the wait". It is genuinely
idle, but it is idle *in the wrong part of the frame*: a running min/max of
what the poll observes gives **203..273**, every run. The visible picture is
lines 0–253, so from that hook alone a split can only ever be placed in the
**bottom fifth**. Ask for line 80 or 150 and `vcount` is already past it on
the poll's first look, so the switch happens before the frame is drawn and
the bottom colour covers everything.

**CORRECTED 2026-08-26 — that is a property of the hook, not of the machine,
and a second poll site fixes it.** This section used to say that polling from
the process dispatch loop as well "did not widen the range by a single
scanline", and concluded the top of the frame was unreachable. That is wrong.
A `calla vsplit_poll` at `prcd1a` in [MPROC.ASM](../src/MPROC.ASM) — the list
walk the pass keeps returning to between processes — takes the observed range
to **37..273**, at 200+ polls a frame.

The frame breaks down like this, measured with a bucketed histogram rather
than min/max (`vsplit_hist` / `vshist_org` / `vshist_shift`, behind
`vsprobe`):

| raw `vcount` | screen rows | polls / frame | what is happening |
|---|---|---|---|
| 274–287, 0–31 | — / 0–11 | 0 | `eosint` fires at 274; the tick interrupt's own work |
| 32–111 | 12–91 | ~12 per 16 lines | process dispatch — **densely pollable** |
| 112–151 | 92–131 | **0** | one long process; a 40-line blind spot |
| 152–202 | 132–182 | ~17 per 16 lines | dispatch again |
| 203–273 | 183–253 | ~18 per 16 lines | the idle wait, i.e. the old hook |

So the reachable region is not "the bottom fifth", it is **everything except
`vcount` 112–151 and the vblank tail**. min/max could never have shown this:
37..273 and 203..273 are both single intervals, and only the histogram
separates "swept densely" from "visited twice".

Two consequences worth carrying:

- **A band edge has to land where the poll is dense.** The switch happens on
  the first poll at or past the line you asked for, so an edge inside
  112–151 does not appear at 112 — it appears wherever the poll next fires,
  around 152. Measured: a band asked for as `vcount` 66..128 came out as
  66..~150, dragging a 12 px shift down over the temple wall.
- **min/max is not a coverage measurement.** It is the reason this document
  drew the wrong conclusion and closed the question.

**2. The split is not observable in MAME.** At line 220, inside the polling
window, with `vsplit_hit` confirming the switch fired about once per frame,
the rendered screen is *uniformly the bottom colour* with no boundary
anywhere — and the same at 80 and 150. The boundary does not move when the
line moves. That is the signature of the palette being resolved **once per
frame**: MAME's midtunit builds an indexed bitmap and applies the palette at
screen-update time, so the last CRAM write of a frame wins for the whole
frame. On real hardware colour RAM is read as the beam scans and the split is
real; here it cannot be seen, whatever the hook.

So the palette mechanism is verified as far as it *can* be — it runs, it
fires at the right raster position, it costs nothing, it does not destabilise
anything — and the picture is left to hardware. The test rig deliberately
sweeps the split line across three values rather than checking one: a uniform
screen at a single line is equally consistent with "the split works" and "the
palette is resolved per frame", and only moving the line separates them.

Note the two findings are about **different things**, and conflating them is
what kept this shelved. "Cannot be *placed* where I want" was a property of
the poll site and is now fixed. "Cannot be *seen* here" is a property of what
is being written — true for colour RAM, false for `dpytap`.

### In-game uses

- **Per-band `dpytap`** — built and visible in MAME, then **retired**. It
  cannot be aimed at a layer, so it shears foreground sprites that happen to
  sit on the band's rows. `arena_heat_proc` in [BGND.ASM](../src/BGND.ASM) is
  the working implementation, compiled out behind `vshim`.
- **Split palette above/below a waterline** — the Dead Pool's acid, the
  Portal's horizon — by rewriting a CRAM entry mid-frame. Now *placeable*
  anywhere outside `vcount` 112–151, but still not observable in MAME, so it
  stays a hardware-only item.
- **Split scroll**: a foreground band that scrolls at a different rate from the
  sky, without a second background layer.

### The band that turned out to be visible

The palette half of this section is invisible in MAME because midtunit
resolves colour once per frame. **`dpytap` is not** — it feeds `coladdr`,
which the scanline callback consumes per line, so a mid-frame write moves
only the rows below it and the emulator draws exactly that.

Measured (`tools/shimmer_band_test.lua`): a band asked for as `vcount`
210..250 moved rendered rows 200/215/230 by −12 px and left every other
sampled row alone. That makes the whole family of `dpytap` band effects
developable here rather than on hardware — a different proposition from the
palette split entirely.

What is built on it is `vshim`, a travelling wave rather than a single step.
`vshim_wave` holds `VSHIM_CELLS` **absolute** `dpytap` values — absolute
because a signed offset would depend on `FE1` in the status register for its
sign extension. The cell for a scanline is
`((vcount - vshim_lo) >> vshim_shift) + vshim_phase`, wrapped, and
`vsplit_reset` advances the phase once a tick from an 8.8 accumulator.

`vshim_ttl` is a heartbeat: whatever armed the band tops it up every tick,
and `vsplit_reset` counts it down and disarms when it lapses. Nothing has to
remember to tear the effect down when a stage ends — which matters, because
the failure mode is a stray horizontal shift across an unrelated screen.

**`SRL Rs,Rd` takes the two's complement of the count.** To shift right by
*n*, `Rs` must hold *−n*. The game does this in two other places
([MKHSTD.ASM:543](../src/MKHSTD.ASM#L543) uses `neg`,
[DIAGDTST.ASM:2999](../src/DIAGDTST.ASM#L2999) uses `not` + `addk 1`). Miss
it and the shift is by `32-n`, which is 0 for every input that matters — so
every scanline maps to cell 0 and every poll lands in histogram bucket 0.
Neither symptom produces a wrong-*looking* picture: the band still moves, it
just moves rigidly, which reads as a placement decision rather than an
arithmetic bug. The rig catches it by requiring the shift to vary **across
rows** and **across frames**, not merely to be non-zero.

### Watch out for

- **The PALETTE split cannot be seen in MAME**; a `dpytap` band can. If what
  you are splitting is colour RAM, budget for hardware, or for instrumenting
  *when* the write lands rather than what it looks like. If it is a display
  register the scanline callback reads, you can just look.
- **Everything on those scanlines moves**, not only the background you aimed
  at. A fighter who jumps into the band is sheared by the same amount. At the
  ±1 unit (±2 px) the shimmer uses this reads as haze; at the ±6 units used
  for the visibility test it is obviously wrong.
- CRAM writes during active display can glitch on real hardware; keep the
  mid-frame work to a single register write, which is what `vsplit_poll` does.
- Polling burns the idle time `yzsort` currently uses. Under load that trades a
  raster effect for a less-sorted display list, i.e. **transient z-order
  errors** — see PERFORMANCE.md §1c for why that, not slowdown, is MK2's
  failure mode. Measured at `peak_overload` 2 while disarmed, but an armed
  split that polls tightly would be a different story.

---

## 5. Hit / hurt box overlay — the debug view, built out of §1

**Status: implemented and working 2026-08-25.** `box_pass` in
[MKDISP.ASM](../src/MKDISP.ASM), behind `hitbox .set 1` in
[MAINEQU.ASM](../src/MAINEQU.ASM). Requires `geoline .set 1`.

§1 listed "debug overlays for free: hitbox rectangles are four `LINE`s" as an
idea. This is that idea built, and it turned out to be worth more than a
convenience — it is what caught the colour-map trap below, and what made the
victim-box squeeze measurable instead of folklore.

### What retail had, and why it did not work

`strike_check` ([JOY.ASM](../src/JOY.ASM)) has always had an `f_colbox` debug
flag. When set it built an `oid_cbox` object over the strike rectangle:
`null_image` + `oconst = bpal_hot_green`, inserted on **list #2 — in front of
the fighters**. Three things follow from that, and all three are fatal to its
purpose:

- It is a **solid blit**, so the box hides the thing it is drawn to explain.
  You can see that a box exists and nothing about where it sits on the sprite.
- It ran `kilobj2` on `oid_cbox` first, so **only one box can be on screen**.
  In a trade, you see the second one only.
- It shows the **strike box only**. `victim_box`, the hook for the box being
  tested *against*, is a bare `rets` in the leak with the old body dead behind
  it — so the half of the comparison that decides whether you got hit was
  never drawn at all.

### What it is now

Four `geo_put` segments per box, appended to `geo_list` and stroked by
`geo_pass` after the DMA drains. No object, no palette, no display-list
insert, and it draws **over** the fighters without covering them.

`f_colbox` is now a bitmask, and **bit 0 keeps its exact old meaning**, so
anything that already pokes `f_colbox=1` behaves as before, just in outline.
The layers, the colours and how to switch them on are under
**"Turning it on"** below.

Two producers, because the two halves are known at different times:

- **`box_pass`** (display interrupt, every frame) computes hurt boxes itself
  via `box_bounds`, and draws the anchors.
- **`box_add`** (process time, from `strike_check` and the revived
  `victim_box`) parks a rectangle in `bx_list` for `box_pass` to drain.

`bx_list` slots carry a **tick stamp rather than a shared count**. A count is
written by one side and read by the other, and a torn count is a wild index; a
torn stamp is just a slot skipped or drawn one frame stale. Slots draw while
`(tick - stamp) <= 1`, which is also what makes a strike box that exists for
three ticks readable at all.

### Turning it on

Nothing is on by default. `f_colbox` is zero on a cold boot and `box_pass`
reads it before it saves a single register, so a shipped build pays one load
and one branch a frame for the whole feature.

**The layers are separate colours on purpose** — the hitbox and the hurtbox
are never the same colour, because the entire point is reading one against the
other:

| bit | value | layer | colour | boonpal index |
|---|---|---|---|---|
| 0 | 1 | **hitbox** — the attacker's strike box, on its active frames | **red** | `0dh` `bpal_red` |
| 1 | 2 | `cb_body` — the sprite SILHOUETTE, every frame. **Not** what decides a hit | **green** | `07h` `bpal_hot_green` |
| 2 | 4 | **hurtbox** — the rectangle the compare actually tested against | **white** | `0eh` `bpal_white` |
| 3 | 8 | anipoint crosses + `ground_y` | **blue** | `0bh` `bpal_blue` |
| 3 | 8 | repell threshold uprights | **purple** | `04h` `bpal_hot_purple` |
| 4 | 16 | **every multipart piece boxed separately** | **yellow** | `0ch` `bpal_yellow` |

**Bit 4 costs real frame time.** It draws up to 16 rectangles per fighter
instead of one, and measured on the battle sweep it takes `peak_overload` from
**4 to 35** (2 = the pass finished inside its tick) — enough to overrun the
frame, drop ticks and change how the fight plays out. `kang_jax_deadpool` goes
3/3 PASS at mask 3 and **0/3 at mask 18**, failing on a camera-scope anomaly
because the fighters end up somewhere else. Use it to *look*; never leave it on
while measuring anything timing-sensitive, and never during a stability sweep.
Bits 0-3 are cheap: mask 3 measured `peak_overload=4`, same as the overlay off.

Verified by counting pixels in a capture, not by eye.

**Bit 1 is a silhouette, not a hurtbox, and that distinction is the whole
point.** It draws the sprite's bounding box — the value collision *starts*
from before narrowing it to the quarter-width column. It is the largest thing
on screen and the least meaningful, and it does not change when the model
changes, which reads as "nothing happened" if you are watching the wrong
layer. The layers were originally named the other way round and it caused
exactly that confusion.

Add the bits: **`5` = hitbox + hurtbox** is the one you usually want; `7` adds
the silhouette, so the squeeze is visible as the gap between white and green;
`15` is everything cheap; `18` is silhouette + per-piece — the pair for
evaluating the change in [HITBOX_MODEL.md](HITBOX_MODEL.md), green being the
model the game uses and yellow the one it could have for free.

**The address moves.** `f_colbox` is a `.bss` symbol, so its address shifts
whenever anything ahead of it in RAM changes size. Never hardcode it — read it
out of `src/mk2.map` after the build you are actually running:

```
python sym_resolve.py --dump | grep f_colbox
```

#### From a Lua script (what the rigs do)

`space:read/write` on the TMS34010 take the **raw map address**, no division —
see `reference_mame_lua_bit_addresses`. Hold the value rather than writing it
once; nothing in the ROM clears it, but nothing sets it either:

```lua
local f_colbox = 0x010f87f0            -- LOOK THIS UP, it moves every build
if space:read_u16(f_colbox) ~= 3 then
    space:write_u16(f_colbox, 3)       -- hitbox + hurtbox
end
```

#### From the MAME debugger

`w@` takes a **byte** address, so divide the map's bit address by 8
(`0x010f87f0 >> 3 = 0x21f0fe` for the build this was written against):

```
w@0x21f0fe=3
```

#### From the battle sweep (the reliable path)

The standalone rigs drive character select themselves and stall at
`gs_post_psel` on a fresh CMOS. The battle sweep's sequence is the one that
works, and it has an addon hook for exactly this: rename
`tools/sweep_addon_hitbox.lua.off` to `tools/sweep_addon.lua`, put the mask in
`tools/sweep_addon_mask.txt`, and run

```
tools/run_battle_stability_sweep.ps1 -Only kang_jax_deadpool
```

**Rename it back when you are done.** The sweep loads `sweep_addon.lua` if the
file merely exists, so leaving it there silently changes every future
stability run — at mask 18 it turns a passing battle into a failing one.

#### From the ready-made rig

[tools/hitbox_overlay_test.lua](../tools/hitbox_overlay_test.lua) boots into a
fight, holds the mask on for every frame, and captures on the frames a strike
box is actually parked — which matters, because a strike box exists for about
three ticks and a rig firing on a fixed frame offset simply misses it:

```
mame.exe mk2 -autoboot_script tools/hitbox_overlay_test.lua
HITBOX_MASK=7 HITBOX_RANGE=95 mame.exe mk2 -autoboot_script tools/hitbox_overlay_test.lua
HITBOX_SYNTH=1 ...    # park a control box each frame to split producer from consumer faults
```

#### Compiling it out

`hitbox .set 0` in [MAINEQU.ASM](../src/MAINEQU.ASM) removes every trace: the
pass, the hook at `dsa9`, the `box_add` call sites in `strike_check` and
`victim_box`, and the `.global`. It needs `geoline .set 1` in
[MKDISP.ASM](../src/MKDISP.ASM); with that off it fails to assemble on
`geo_list`, loudly, which is the intended behaviour rather than a silent
no-op.

### The colour map applies to CPU writes too

This is the fifth way a CPU draw goes quietly wrong, and the worst, because
**the picture is right**. The shape lands exactly where it was asked for, in
the wrong colour, so it reads as a palette mistake in your own code.

A pixel written by the CPU is not the pen index on its own. The video hardware
ORs in the **DMA colour-map register** (`dmacmap`, `01a80080h`) — the same
latch the blitter uses to pick which 256-entry block of colour RAM an object
reads. So a CPU pixel comes out of *whatever palette the last sprite of the
frame happened to use*, which changes with the stage, the costumes, and which
effects are on screen.

Measured, not assumed
([tools/hitbox_color_probe.lua](../tools/hitbox_color_probe.lua)): the anchor
cross wrote byte `0bh` (`bpal_blue`) into VRAM, colour RAM entry `0bh` is
`001dh` — pure blue — and it drew **orange**, because `dmacmap` was still
carrying the background's map.

`geo_list` records now carry the map explicitly, in the top half of the colour
long:

```
  bits 0-7    the pen, replicated (only the low PSIZE=8 bits reach VRAM)
  bits 16-31  the colour map, written to dmacmap for that segment
```

Zero means map 0 = `boonpal`, which is pinned for the life of the machine
(PALL.ASM) and is where every `bpal_*` name lives. `hud_pass` sets `dmacmap`
to 0 once per pass for the same reason.

**This was already biting two other things.** The HUD text demo picked
`bpal_white` / `bpal_yellow` and got neither. And `MKBOLTG`'s bolt colours were
`0FFFFFFFFh` / `09C9C9C9Ch` on the theory that the frame buffer holds a raw
6-bit index into whichever costume palette is loaded, so 62/63 would follow the
alternate costumes for free. It does not — the palette a bolt landed in was a
lottery, which is why every bolt came out solid white regardless of the value
there. They are now explicit: map 0, `bpal_white` core, `bpal_blue` border.

### Watch out for

- **Clip everything.** `geo_pass` clears CONTROL's window field for the draw —
  that is the only way a CPU pixel lands at all — and that also removes the
  hardware's inhibit-writes-outside-window protection. A `PIXT` past the end of
  a scan line writes real memory. Every stage scrolls, so an off-screen fighter
  is the normal case, not an exotic one. `box_hline` / `box_vline` are
  axis-aligned precisely so the clip is exact and costs one compare per edge.
- **Bound every chain walk.** `box_bounds` walks the multipart list from the
  display interrupt. `MKUTIL`'s four equivalents loop until the sag word reads
  zero with no cap, so a chain caught mid-rebuild hangs the machine rather than
  glitching. A debug overlay is never allowed to be the thing that wedges a
  cabinet — hence `BX_PARTS` and the SCRATCH-range check on the pointer.
- **`GEO_MAX` is shared.** `MKBOLTG` caps itself at `GEO_LIMIT` 248; `GEO_MAX`
  went to 320 so a Raiden flash can never starve the boxes. If the two are ever
  balanced differently, the frame you were trying to read is the one that goes
  blank.
- **`dmacmap` is a write to the DMA CHIP, not to RAM.** Selecting the colour
  map per segment unconditionally cost Raiden's lightning 248 i/o writes a
  frame inside an interrupts-off loop, and the machine did not crash - it
  **crawled**, badly enough that the battle sweep stopped receiving
  observations and scored `raiden_jax_deadpool` NO-VERDICT about one run in
  three. A control build of the pre-change geo path was 8/8; removing just
  those three instructions was 8/8; that is how it was pinned. `geo_pass` now
  compares against a RAM shadow (`geo_curmap`) seeded to match the chip, so a
  list that is entirely map 0 - everything in the tree today - issues no chip
  writes at all.
- **A slow frame and a hung frame look identical to the sweep.** NO-VERDICT
  means "no observations arrived", which covers a crash, a hang, *and* a
  machine running at a fraction of speed. Do not read it as a crash.
- **Capturing a single-frame draw needs the page flip.** The machine is double
  buffered, and `geo_pass` draws into the BACK page. A hurt box is drawn every
  frame so it exists on both pages and photographs fine; a **strike box exists
  for about three ticks**, gets drawn onto the back page only, and a snapshot
  taken on that frame captures the FRONT page — where it was never drawn. The
  symptom is maddening: `box_seg` proves the segments were plotted, `geo_drew`
  proves the pass ran, `geo_lastxy` lands exactly on the box's corner, and the
  picture has zero red pixels. **Take the shot one frame later.**
- **Trigger the shutter on the DRAW, not on the DATA.** Reading `bx_list` from
  a Lua frame hook tells you a box is parked, not that `box_pass` drew it —
  the two test the same tick stamp at different points in the tick, and they
  disagree about half the time. `box_emit` counts `box_rect` entries and hurt
  boxes are exactly two per pass, so any excess over `2 * box_ran` is a
  deferred box that really reached the screen. Fire on that excess growing.
- **Do not sample `geo_count` from a Lua frame hook** to check the overlay is
  emitting. `geo_pass` consumes and clears it inside the display interrupt, so
  it reads 0 almost always. `geo_drew` is the honest signal: it advances only
  on frames where the list was non-empty.

### What it showed on the first run

The overlay's first real output was a correction to the source's own comments.
`sq_punch` shrinks the victim box for `sf_squeeze` moves, and both its comment
and the `jade_nitro` note in `strike_check` describe that as a **5/8** squeeze.
It is not. `srl 2` is a divide by four, so the inset is `W/8 + W/4 = 3W/8` off
each side and **a quarter of the width survives**.

Measured on screen with bit 1 and bit 2 on together: Jax stands 66 px wide
(green) and the box the compare actually used was 18 px (white) — exactly
`66 - 2*(8+16)`. 205 of the 223 strike records carry `sf_squeeze`, so this is
the rule, not the exception. See [HITBOX_MODEL.md](HITBOX_MODEL.md).

---

## Ranked

| # | Primitive | Effort | Novelty | Where to start |
|---|---|---|---|---|
| 1 | `LINE` | done | high | `geo_pass`/`geo_line`, §1 - now carries the box overlay |
| 3 | `PIXBLT B,XY` | done | low | `hud_pass`, §3 - HUD text at 1/6 the ROM, zero art |
| 2 | VRAM block fill | done | moderate | `srt_band`/`flash_pass`, §2 - flash that spares the HUD |
| 5 | hit/hurt box overlay | done | n/a | `f_colbox=3`, §5 |
| 4 | `vcount` poll | built | high | `vsplit_poll`, §4 - runs, but HARDWARE-ONLY |

**All five have been built.** Four of them you can see; §4 you cannot, and
that is its headline rather than a footnote — MAME resolves the palette once
per frame, so a mid-frame CRAM write colours the whole picture. Anything
built on §4 needs hardware to check, and from the only idle hook in the
frame it can only reach the bottom fifth of the screen. Both of those are
measured, not assumed.

Whatever you build, watch `peak_overload` on audit page 3 (**PEAK FRAME LOAD**)
before and after. Everything in this document spends CPU time in a tick that
currently has slack — the meter tells you when it stops having slack.
