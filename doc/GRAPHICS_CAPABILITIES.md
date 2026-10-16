# Graphics capabilities — every way MK2 can put a pixel on screen

> **Current follow-up, 2026-09-12:** see
> [Graphics and resource opportunities](GRAPHICS_OPPORTUNITIES.md) for the
> source-checked status, 31 ranked opportunities, fresh asset measurements,
> and corrections to the historical conclusions below. In particular, CPU
> layer insertion, palette scope/capacity, enabled examples and DMA setup
> cost need the qualifications in that report.

**What this is:** one index over the two audits and the work that came out of
them. [UNUSED_GRAPHICS_PRIMITIVES.md](UNUSED_GRAPHICS_PRIMITIVES.md) covers the
34010's own instructions and the raster counters; all five of its sections are
now built. [UNUSED_HARDWARE_EFFECTS.md](UNUSED_HARDWARE_EFFECTS.md) covers the
DMA object path and the display registers; one of its nine items is now built
(#5, `dpytap`, as a banded effect). Neither tells you
which one to reach for when you want a *specific thing on screen*, and the
traps that bite you are spread across both. That is what this is for.

**What this is not:** a replacement for either. Details, measurements and the
reasoning live there; this points at them. If the two disagree with this file,
they win — they sit next to the code.

Status as of 2026-08-26.

---

## The five ways, and how to choose

Everything reduces to *who writes the pixel*, and that decides more than any
other property:

| | drawn by | z-order | costs | can it be seen in MAME |
|---|---|---|---|---|
| **DMA object path** | the blitter | sorted with everything else | zero CPU | yes |
| **CPU geometry / text / fill** | the 34010 | *not* sorted — lands in front of everything | CPU time in the tick | yes |
| **Display registers** | the video hardware | whole screen at once | ~one write | yes |
| **Palette (CRAM)** | the video hardware | whole screen at once | ~one write | yes |
| **Raster split** (palette) | the video hardware, mid-frame | above/below a scanline | a poll | **no — hardware only** |
| **Raster band** (`dpytap`) | the video hardware, mid-frame | above/below a scanline | a poll | yes — `coladdr` is read per line |

The z-order row is the single biggest constraint. A CPU draw is not part of the
display list, so it lands either behind everything (issue it before the object
pass) or in front of everything (issue it after, and drain first). If your
effect has to appear *between* two sprites, none of the CPU paths can do it and
you want a DMA object.

---

## What exists now

### Built and verified

| what | where | switch | notes |
|---|---|---|---|
| CPU geometry (lines) | `geo_pass` / `geo_line`, MKDISP.ASM | `geoline` (MKDISP) | software Bresenham + `PIXT`, **not** the `LINE` instruction — §1 explains why |
| VRAM block fill | `srt_band` / `srt_stamp2` / `srt_fill`, MKINIT.ASM; `flash_pass`, MKDISP.ASM | `srtflash` (MAINEQU) | band LIST now - up to 6 bands a frame, each two-coloured; `white_flash` arms the one-band form |
| Lightning flash - Yoteigai Tor | `peak_flash`, BGND.ASM | `fxdemo` (MAINEQU) | worked example: the big bolt whites out rows 46-253 for two ticks, HUD untouched |
| Portal arc - Outer Haven | `oh_warp_arc`, BGND.ASM | `fxdemo` (MAINEQU) | worked example of CPU geometry: replaces the 6-frame `warplite` spark with a jointed bolt re-jittered every tick. **Open defect: no depth** - see §1 |
| Hit pop | `hit_pop_arm` / `hit_pop_pass`, MKDISP.ASM | `fxdemo` (MAINEQU) | worked example of HW#3: squash-and-stretch on every clean hit. The HW#2 white flash that shared it was removed 2026-08-27 |
| Vertical flip | `warplite_animator`, BGND.ASM | `fxdemo` (MAINEQU) | worked example of HW#1: half of the Portal's sparks are drawn upside down |
| CPU text | `hud_pass` / `hud_string` / `hud_num`, MKDISP.ASM | `hudtext` (MKDISP) | `PIXBLT B,XY` over `sysfont`, 1bpp, **zero art** |
| Hit / hurt box overlay | `box_pass`, MKDISP.ASM | `hitbox` (MAINEQU) | needs `geoline`; runtime mask is `f_colbox` |
| Raster split (palette) | `vsplit_poll` / `vsplit_reset`, MKDISP.ASM | `vsplit` (MAINEQU) | runs, costs nothing, **effect invisible in MAME** |
| Raster band (`dpytap`) | `vsplit_poll`, MKDISP.ASM; `arena_heat_proc`, BGND.ASM | `vshim` (MAINEQU) | built, then **switched OFF** — it moves the foreground too. See "Why the raster band was removed" |

Every one of these is off-by-default at runtime or gated by a `.set`, and the
whole set measures `peak_overload` **2** — the floor, meaning every process
pass finished inside its tick — with `qdma_drops` 0 and 21/21 on the battle
stability sweep. That included the Dead Pool acid glow, which armed five bands
on every single frame of a fight and still measured `peak_overload` **2**,
`qdma_drops` **0** over 900 fight frames — it was removed for taste, not for
cost.

The `dpytap` band is the one that was built and then retired — `vshim` and
`vsprobe` are both `.set 0`, so none of it links (0 symbols in `mk2.map`) and
`prcd1a` is back to the instruction it always was. While it was running it
cost nothing measurable: `peak_overload` **2** in-fight (the floor),
`qdma_drops` 0, 21/21 on the sweep. Cost was never the problem — see below.

### Audited, not built

The nine items in [UNUSED_HARDWARE_EFFECTS.md](UNUSED_HARDWARE_EFFECTS.md).
Three of them cost no engine work and no art, which makes them the cheapest
things left on the table anywhere:

- **item 1** vertical flip (`m_flipv`) — wired to hardware, an ani opcode
  already exists for it, **0** uses in retail
- **item 3** non-square `oscale` (X≠Y) — every blit already carries it; retail
  only ever uses square scales
That document's own recommended order is constant colour (item 2), then
vertical flip (1), then `dpystrt` shake (4). Item 8 (PPOP/PMASK) it says to
skip. Item 5 (`dpytap`) has since been built — see the band row above.

---

## Use cases — indexed by what you want, not by primitive

| you want | reach for | why that one |
|---|---|---|
| a beam / arc / tether **between two moving points** | CPU geometry, §1 | a sprite cannot connect two points that both move without a scaling stretch; a line connects them by construction, and costs no video ROM. Worked example: `oh_warp_arc`, Outer Haven's portal |
| a **flat colour band** — flash, wipe, sky wash, acid glow | VRAM block fill, §2 | `rows/2` memory cycles no matter how wide; the CPU never touches a pixel. Two worked examples: `dp_acid_glow` and `peak_flash` |
| a **colour the palette has not got** | the block fill's two-line strip, §2 | one transfer moves a ROW PAIR out of a two-line source, so the two lines can hold different colours and the band comes out dithered a row at a time — five levels out of boonpal's three greens |
| a **full-screen flash that spares the HUD** | VRAM block fill, §2 | the existing `white_flash` only sets `irqskye` (the colour *behind* everything) and `long_white_flash` blanks the display, life bars included |
| **damage numbers, a combo counter, any new HUD text** | CPU text, §3 | 1 bit per pixel against the 6bpp baseline, and `sysfont` is already in the program ROM — no new art at all |
| the **same shape in two colours** | CPU text (§3) or constant colour (HW#2) | §3's colours are *registers*, so one master draws in any pair; HW#2 does it on the DMA path but still pays 6bpp for the source |
| **different colour above/below a waterline** | raster split, §4 | placeable now, but the COLOUR half is still hardware-only — read the constraints below |
| **heat shimmer / water ripple** over part of the screen | *nothing that works* | `vshim` does it per scanline, so it distorts the FOREGROUND on those rows too — built, then switched off. A per-layer version has to move objects, not registers |
| **screen shake** | `dpystrt` (HW#4) | sidesteps the camera-shake-vs-scrolling conflict entirely — see UNUSED_HARDWARE_EFFECTS.md item 4 |
| a **mirrored** sprite (vertically) | `m_flipv` (HW#1) | free; built on half of the Portal's sparks. Single-part objects only - a multipart body needs `ani_flip_vert` |
| a **stretched or squashed** sprite | non-square `oscale` (HW#3) | free; every blit already carries the field. Built: the hit pop's squash, measured 1.29x wide off the shadow |
| **silhouettes, ghosts, afterimages, freeze tint** | constant colour (HW#2) | one word write per object, no new art. Proven as a hit flash and then removed - the idiom, and the `opal` trap that goes with it, is written up in HW#2 |
| **to see what the collision system sees** | `f_colbox`, §5 | outlines, not a solid blit, so the fighters stay visible underneath |
| **video ROM back** | low-bpp art (HW#9) | 1-2bpp is 4-8x cheaper than 6bpp for flat shapes; pairs with constant colour |
| **a filled shape that is not a rectangle or a line** | *nothing yet* | the block fill is a band tool; geometry draws outlines. A polygon filler would be new work |

---

## Why the raster band was removed

Worth reading before reaching for a raster effect again, because the
mechanism works perfectly and is still the wrong tool.

`vshim` did exactly what it was built to do: a travelling ±2 px wave over
`vcount` 64..98, verified per-row and per-frame, contained inside the band,
free. It was switched off anyway, because **a raster effect cannot be aimed
at a layer**. `dpytap` is a display register; the video hardware re-taps the
shift register per scanline and every plane on that row moves together. On
Kahn's Arena rows 44–78 hold Kahn's staff and orb, both dragon medallions and
the pagoda roofs, and all of them shear along with the fire. Narrowing the
band does not help — there is no run of rows on that stage that contains only
background.

The z-order table at the top of this document already said this; it just did
not say it loudly enough. **Display registers and the palette are
whole-screen or whole-scanline. Only the DMA object path can be aimed at one
layer.**

If a per-layer shimmer is wanted, the lever is object positions, not
registers, and it was measured to work: a background plane's blocks are
ordinary display objects, `bgnd_ud1` only adds and deletes them rather than
repositioning them, so an offset written into a block's `oxval` sticks (0 of
15 overwritten over 36 ticks). On Kahn's Arena the backmost plane `baklst7`
is **the fire glow and nothing else** — shoving it 60 px moves the flames and
leaves the medallions, the staff, the pagodas, the throne, the fighters and
the HUD untouched. The trade is granularity: 15 blocks at 7 distinct y
values, so roughly 6 steps rather than one per scanline, though at 1 px
instead of `dpytap`'s 2 px minimum.

### Two traps found while measuring this

- **`b_inviso` does not work on background blocks.** `dclipl` tests
  `btst b_inviso,a7` *inside* the `b_multipart` branch, so a single-part
  object never looks at it. Hiding a plane to see what it draws silently
  does nothing. Displace it instead.
- **Do not identify a layer by diffing screenshots.** `sitting_kahn` idles,
  the camera scrolls, and the dragon logo is an animated flaming sprite.
  Consecutive frames already differ by ~2800 px, which is *more* than a 24 px
  displacement of a whole plane changes, and a 24-frame animation mask
  swallows the sky entirely. Three separate measurements were wrong this way.
  What works: displace by a large amount (60 px) and **hold it**, then look.
  Animation cannot fake a static 60 px offset.

---

## Traps that bite regardless of which path you pick

These cost real time to find. They are collected here because each one is
documented under whichever section happened to hit it first, which is not where
you will be looking.

### The colour map applies to CPU writes too

**The worst one, because the picture is right.** A pixel written by the CPU is
not the pen index on its own — the video hardware ORs in `dmacmap`, the same
latch the blitter uses. So a CPU pixel comes out of *whatever palette the last
sprite of the frame used*. Force `dmacmap` to 0 (= `boonpal`, pinned for the
life of the machine) before any CPU pixel write, including writes that only
*prepare* something, like stamping a colour strip for the block fill. It had
silently mis-coloured three separate things before it was found.

### The other four silent CPU-draw failures

1. **`CONTROL`'s window field** is `w3` — *inhibit writes outside window*.
   Every CPU pixel outside `WSTART`/`WEND` is dropped with no error and no
   trap. Clear the window and PPOP fields, restore after.
2. **No drain.** Objects at `dsa9` are QUEUED, not drawn. `dmaqwait` does not
   exist. Queue-empty is `dma_interupt` having cleared its own enable bit in
   `intenb`, then `dmactrl` idle — and interrupts must stay **on** for that
   spin or it can never finish.
3. **Cross-file loads.** Memory operands cannot target the B file with
   register-indirect addressing. Go A-file, then `move a0,b9`. (Absolute
   addressing to a B register *is* legal — `move @dpyctl,b10,w` is fine.)
4. **Callee register stomp.** Keep caller loop state above whatever the callee
   works in. A counter in the wrong register hangs the machine rather than
   glitching, because these loops run with interrupts off.

### `b13` is the DMA queue counter

Anything that drains the queue and then wants the B file must save it **after**
the drain, not on entry. `dma_interupt` owns b8/b10/b11/b13/b14 and
legitimately changes them while the drain spin runs with interrupts on — b13
*is* the counter it decrements to zero, which is the drain condition itself.
Save on entry and restore on exit and you wind it back to a stale value.

### Never clear `env` mid-frame

`srt_clr` drops screen refresh *and* video enable (`andni sre+env`). `sre` has
to go — screen refresh uses the same shift-register cycles a block transfer
needs. `env` does not, and dropping it blanks the beam: a **black scanline
straight across the fill**, at a fixed y, every frame. `srt_clr` gets away with
it because it runs at boot with the display already dark.

### GSPA: `,L` is not `,l`

`L` is valid as `ADDI`'s long-immediate suffix and **invalid** as `MOVE`'s
field selector. `move *a5,a5,L` fails with `AN IDENTIFIER IN THE EXPRESSION IS
INVALID` and "The following symbols are undefined: L".

---

## Verifying any of this

### MAME will lie to you in two specific ways

**`read_u16` aligns down.** The TMS34010 program space is bit-addressed but the
accessor is not bit-granular: a read at a byte-but-not-word-aligned address
silently returns the byte *below* it. A font row table comes back with every
row duplicated in pairs; a frame-buffer scan comes back at half horizontal
resolution with every odd pixel a copy of its neighbour. Both look exactly like
a rendering bug in the code under test. Read bytes through an `rd8` helper.

**The palette is resolved once per frame.** MAME's midtunit builds an indexed
bitmap and applies the palette at screen-update time, so a mid-frame CRAM write
recolours the **entire** displayed frame. Raster splits are real on hardware
and invisible here. To tell "the split works" apart from "the palette is
resolved per frame", sweep the split line across several values in one run and
watch whether the boundary moves — a uniform screen at one line proves nothing.

### Do not verify a draw by counting pixels of its colour

The life bar, the name plates and the WINS counter are all drawn from `boonpal`
too, so they contain the same indices, and the count moves when the bar length
moves. A colour-count check passes on coincidence — one reported a
healthy-looking 88/27/96 while the digits it was "measuring" sat invisibly
under the life bar's metal frame.

Verify against something derived from the ROM instead. `hud_pixblt_test.lua`
reads the glyph bitmaps out of the running ROM, computes where every set bit
must land, and requires the frame buffer to hold the requested index at *every
one of them* — position, spacing, bit order, colour and transparency in one
assertion.

### Rigs that already exist

| rig | checks |
|---|---|
| `tools/hud_pixblt_test.lua` | §3, exact glyph match; `_testmode` variant for a `test_mode` ROM |
| `tools/srt_flash_test.lua` | §2, play band filled **and HUD band unchanged**; runs on Kombat Tomb, where nothing else drives the band |
| `tools/flatband_demo.lua` | §2's two examples - `-Stage deadpool` / `-Stage peak`; row uniformity and the gradient invariant, never a colour count |
| `tools/warparc_demo.lua` | §1's portal arc - `-Mode observe` watches the stock sprite, `-Mode arc` the geometry, `-Mode portal` the flipped spark (HW#1); asserts the bolt tracks the hole and stands down when a fighter is in front of it |
| `tools/hitpop_demo.lua` | HW#3 - `oscale` during and after the pop, plus a shadow-width A/B (45px vs 35px = 1.29x) for the squash itself |
| `tools/vsplit_test.lua` | §4, sweeps the split line; reads rendered pixels, not the frame buffer |
| `tools/hud_perf_probe.lua` | `peak_overload` / `qdma_drops` over a fight |
| `tools/hud_stall_probe.lua` | locates a hang and resolves the PC to a symbol |
| `tools/battle_stability_sweep.lua` | 21 battles; the regression gate for all of this |
| `tools/hitbox_color_probe.lua` | the `dmacmap` measurement |
| `tools/shimmer_band_test.lua` | `vshim` — raster coverage, plus a wave that must vary across rows AND frames |
| `tools/shimmer_probe.lua` | host-side `dpytap` control; also proves Lua fires once a frame |

Watch `peak_overload` (audit page 3, **PEAK FRAME LOAD**) before and after
anything that spends CPU in the tick. 2 is the floor. CLAUDE.md records the
per-piece box layer taking it from 4 to 35 — that is the scale of "too much".

---

## Switch reference

| switch | file | default | effect |
|---|---|---|---|
| `geoline` | MKDISP.ASM | 1 | CPU geometry pass; required by `hitbox` |
| `geoguard` | MKDISP.ASM | 1 | refuse geometry whose endpoints leave the page |
| `hudtext` | MKDISP.ASM | 1 | CPU text pass |
| `hudtest` | MKDISP.ASM | 0 | demo producer — draws both players' HP |
| `bog_line` | MKDISP.ASM | 0 | Midway's built-in DMA raster-time meter |
| `hitbox` | MAINEQU.ASM | 1 | hit/hurt box overlay |
| `srtflash` | MAINEQU.ASM | 1 | VRAM block-fill flash |
| `vsplit` | MAINEQU.ASM | 1 | raster split machinery (runtime switch is `vsplit_line`) |
| `vshim` | MAINEQU.ASM | **0** | `dpytap` raster band + travelling wave. Off: it moves the foreground. Set to 1 to have it back |
| `vsprobe` | MAINEQU.ASM | **0** | raster coverage histogram — measurement only; needs `vshim` |

Runtime, not compile time:

- `f_colbox` — overlay bitmask: `cb_strike` 1, `cb_body` 2, `cb_hurt` 4,
  `cb_anchor` 8, `cb_piece` 16. `3` is the useful default; **16 costs real
  frame time**, so look with it, never measure with it. Resolve the address,
  never hardcode it — it is `.bss` and moves. (CLAUDE.md's table is numerically
  right but uses the older names: what it calls the hurtbox is `cb_body`, and
  what it calls the squeezed compare box is `cb_hurt`.)
- `flash_ticks` / `flash_col` — arm the block-fill flash, in frames.
- `vsplit_line` / `vsplit_cram` / `vsplit_top` / `vsplit_bot` — arm the raster
  split. **Write `vsplit_line` last to arm and first to disarm**; 0 disables.
- `vshim_lo` / `vshim_hi` / `vshim_wave` / `vshim_shift` / `vshim_step` /
  `vshim_ttl` — arm the `dpytap` band. **RAW VCOUNT, not screen rows**:
  `veblnk` is 014h, so screen row R is `vcount` R+20. `vshim_lo` last to arm,
  0 disables. `vshim_wave` holds absolute `dpytap` values, not offsets.
  `vshim_ttl` is a heartbeat the owner must refresh every tick — let it lapse
  and the band disarms itself, which is how the effect gets torn down without
  anything having to remember to do it.
- `vshist_org` / `vshist_shift` — retarget the coverage histogram
  (`vsplit_hist`, 18 buckets) onto any window of the frame.

---

## Known limits, stated plainly

- **A raster band can reach everywhere except `vcount` 112–151** (screen rows
  92–131) and the vblank tail. This corrects an earlier claim of "the bottom
  fifth only", which was a property of the single poll site in `prcdsp`'s
  idle wait, not of the machine; a second poll at `prcd1a` (MPROC.ASM) takes
  the reachable range to `vcount` 37–273. The remaining gap is one long
  process. **A band edge placed inside the gap does not land where you asked**
  — it lands wherever the poll next fires, ~40 lines lower.
- **The PALETTE raster split still cannot be seen in MAME.** A **`dpytap`
  band can** — the register feeds `coladdr`, which the scanline callback
  reads per line, whereas colour is resolved once per frame. Split colour
  needs hardware; split geometry does not.
- **A raster band moves everything on its scanlines**, not just the layer you
  aimed at — a fighter jumping into the band is sheared with it.
- **No filled non-rectangular shapes.** Block fill is a band tool; geometry
  draws outlines.
- **CPU draws cannot be z-sorted** into the display list. In front of
  everything or behind everything, nothing between.
- **Sprite pixels still cannot come from program ROM on the DMA path.** The
  blitter sources from the image ROM bus only. This does *not* apply to the
  CPU: `PIXBLT` reads the CPU bus, which is exactly why §3's font works from
  the program ROM. Different bus, different answer — see
  `CUSTOM_CONTENT.md` and `ASSET_SPACE_LEDGER.md` for the DMA-side rules.
