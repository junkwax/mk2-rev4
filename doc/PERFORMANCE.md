# Performance — what the limits actually are, and how to measure them

**Status:** measured 2026-08-24. Two ROM-side counters added; no optimisation
work done, because nothing is close to a limit.

**TL;DR** — the engine finished every process pass inside its tick in
everything measured, never dropped a sprite, and runs its object and process
pools at a quarter of capacity. There is nothing to optimise. What was missing
was not speed, it was *visibility*, so the ROM now latches two numbers.

---

## 1. There are three separate limits, and only one of them is "slowdown"

### a. Process-pass overrun — `overload`

`prcdsp` ([MPROC.ASM](../src/MPROC.ASM)) busy-waits for the display interrupt
to bump `timer`, then folds it into a smoothed counter:

```asm
sll   1,a0          ; a0 = timer * 2
move  @overload,a1
add   a0,a1
srl   1,a1          ; overload = (overload + 2*timer) / 2
```

The fixed point for `timer == 1` (no missed frames) is **2**. Every extra tick
the pass overruns pushes it up. Jarvis wrote this and then never read it —
nothing in the game branches on `overload`, which is exactly why it is safe to
sample.

### b. Dropped sprites — the DMA queue

`qdma` ([MKDISP.ASM](../src/MKDISP.ASM)) checks `dmaqcur` against the bottom of
`dmaq` and, if the queue is full, **silently discards the sprite**. Retail
gives no indication this ever happened. The queue is `nobj` = 358 cells of
`bqcell` = 0xA0 bits, growing downward from `dmaq+qsize`.

**Fixed on that path 2026-08-24.** Retail leaves `qdmaflg` *set* when it drops
a sprite - the success path a few lines up clears it, the drop path falls
straight through to `qdmax` - so the consumer at `dma_is_busy` then blows off
the whole misc queue on the next pass. One lost sprite silently became a lost
queue. Verified identical in `mk2-readonly`, so it was Midway's, not ours.
`qdma_drop` now clears the flag as well as counting the event. Because
`qdma_drops` measures 0 across every scene below, this is inert today rather
than a behaviour change - it only matters the first time the queue does fill.

### c. Z-order glitches — `yzsort`

`sort_list` ([MKDISP.ASM](../src/MKDISP.ASM)) is a **single bubble pass** per
call, and `prcdsp` calls it repeatedly inside the wait loop. Spare cycles get
spent re-sorting; when there are none, the list is merely *less sorted*.

**This is the key architectural point: MK2 under load shows transient z-order
errors, not slowdown.** If you are hunting a performance problem, that is the
symptom to look for — not a frame rate.

---

## 2. The two counters the ROM now keeps

Added 2026-08-24, both in MPROC's `.bss` (so MKDISP's `.bss` layout, which
other tooling derives addresses from, did not move):

| symbol | what |
|---|---|
| `peak_overload` | high-water mark of `overload`. 2 = every pass finished inside its tick |
| `qdma_drops` | count of sprites discarded by `qdma` on a full queue |

Both are **write-only in game code** — nothing branches on them, so they cannot
change behaviour. Cost is two words of RAM and four instructions on a path that
already ran once per tick, plus three on a path that only runs when a sprite is
being thrown away.

They are `.globl` (via `MAINEQU.ASM`) and exported to
`tmp/freeplay_addresses.json` as `PEAK_OVERLOAD_ADDR` / `QDMA_DROPS_ADDR`, so
any harness can read them without hardcoding an address.

**On the cabinet they show on GAME AUDITS page 3** as `PEAK FRAME LOAD` and
`SPRITES DROPPED` (`DIAGMENU.ASM`, `game_aud3`). They ride there because
`amac`'s `rout` form already supports "call a routine for the value", which is
what a RAM read needs - but note they are **not** audits: they live in RAM, not
CMOS, so they reset at power-on and the audit-clear does not touch them. That
is the right behaviour for a load meter. Expect to see 4-5 rather than 2 after
walking the service menu, because entering the menu is itself a heavy screen
transition; what matters is the value after a session of *play*.

Being latched **in the ROM** matters: a Lua sampler running once per frame can
miss a spike between samples. These cannot.

---

## 3. What was measured

```
python sym_resolve.py --dump | grep -E "peak_overload|qdma_drops"
tools/perf_probe.lua     # overload distribution, attract mode
tools/pool_probe.lua     # object / process / dma-queue occupancy
tools/perf_stress.lua    # drives P1 through continuous attacks in a real fight
```

`perf_stress.lua` layers on `battle_stability_sweep.lua` because the sweep on
its own **leaves both fighters idle** — its log shows `objs=2 p1hp=161
p2hp=161` for the whole window, so it never measured a busy scene. The stress
harness drives a randomised attack pattern and tops both health bars up every
30 frames so the round never ends.

### Results

| | measured | cap | |
|---|---:|---:|---|
| `peak_overload` | **4** | 2 = clean | spikes only on background loads |
| `qdma_drops` | **0** | — | no sprite has ever been dropped |
| display objects | 90 | 358 | 25% |
| processes | 32 | 168 | 19% (peak was the Kahn boss fight) |
| blood droplets | 14 | 64 (`MAX_BLOOD`) | 22% |

`overload` sat at 2 for **99.2%** of frames in attract play. Every logged
excursion above 2 had `p1_bar == p2_bar == 0` — i.e. a screen transition or
background load, never a fight. That is invisible to a player, since the screen
is changing anyway.

The 90-object peak is the **character-select screen**, not combat — 4x the
object count of a two-fighter scene, and still no overrun.

---

## 3b. Where the frame goes - the CPU and display meters (2026-10-12)

`overload` only says whether the process pass FIT its tick.  Four write-only
meters now say how the 289 lines of a frame are spent (both boards):

| meter | where | measures |
|---|---|---|
| `cpu_*` | MPROC.ASM `cpumeter` | lines per PROCESS PASS (game logic), timer release to the next `prcdsp` |
| `dqi_*` | MKINIT.ASM `dirq` | lines the DISPLAY INTERRUPT ran: page flip, palettes, switches and the display-list walk that queues the frame's blits |
| `dqs_*` | MKDISP.ASM `dmaq10..dmaq11` | lines in the SHADOW BLOCK: the DMA interrupt waiting for the blitter to go idle, then drawing shadows/reflections itself |
| `dqd_*` | MKDISP `dma_interupt` + dirq | lines from dirq's start until the object queue last ran EMPTY - when the blitter was handed the frame's last queued blit |

Each keeps `_last`, `_peak`, `_sum`, `_n`; `tools/run_runtime_budget.py`
reports fight-only means and peaks.  Measured, mean / peak lines:

| fight | dirq | shadows | logic | queue empty at |
|---|---|---|---|---|
| Sub-Zero vs Scorpion, Dead Pool | 57.6 / 67 | 5.7 / 8 | 10.3% (~30) | 190.9 / 214 |
| Kitana vs Jax, Tower | 92.8 / 109 | 7.3 / 11 | 6.2% (~18) | 210.1 / 239 |
| Liu Kang vs Baraka, Armory | 48.0 / 58 | 6.3 / 12 | 4.0% (~12) | 155.9 / 173 |

**The blitter is the tight budget, not the CPU.**  CPU work - dirq, the
shadow block and the logic pass together - is roughly 25-40% of a fight frame.
The blitter is still working through the frame's queue at 54-73% of the frame
on average and 83% at the Tower's worst (239 of 289).  So:

- work that trades CPU for blitter time is the kind that pays (culling,
  `shad_fast`, CPU-drawn geometry instead of sprites); work that trades the
  other way does not;
- game logic has a lot of room: more AI per decision, more processes and
  process-time effects cost almost nothing a frame can feel;
- the Tower is closest to the edge, and it is the stage with the most
  background layers - the first place a new background effect should be
  measured.

`dqd` counts only frames whose queue drained; a frame that was still blitting
when the next one reset the queue is `dmaq_late` instead.  The drain point is
when the LAST QUEUED blit was handed over, so the blitter runs for that blit
on top of it.  The display interrupt re-enables interrupts, so the blitter's
own completion interrupts are inside `dqi`.

## 3c. Every stage, both boards (2026-10-12)

One matchup (Sub-Zero vs Scorpion, 2,400 fight frames) on every fight stage:
17 on the T-unit, the same 17 plus the four Wolf-only ones on the Wolf set
(`tools/run_runtime_budget.py --scenario 8,10,<stage>`, `--game umk3` for Wolf;
table by `tools/stage_budget_table.py`).  All 38 runs clean.  Worst headroom
first - headroom is 289 minus the drain PEAK, the lines left before a frame's
tail (the HUD, queued last) would be abandoned:

| stage | board | drain mean / peak | headroom | dirq | shadows | logic | blits mean / peak |
|---|---|---|---:|---|---|---:|---|
| KAHN'S ARENA (08h) | T-unit | 244 / 272 | 17 | 133 / 144 | 8 / 16 | 3.9% | 243 / 263 |
| KAHN'S ARENA (08h) | Wolf | 246 / 266 | 23 | 134 / 154 | 8 / 16 | 4.0% | 245 / 291 |
| THE TOWER (03h) | T-unit | 215 / 235 | 54 | 92 / 105 | 7 / 11 | 6.0% | 180 / 202 |
| THE TOWER (03h) | Wolf | 215 / 235 | 54 | 92 / 105 | 7 / 11 | 6.0% | 180 / 202 |
| SCORPION'S LAIR (UMK3) (1Fh) | Wolf | 186 / 219 | 70 | 136 / 156 | 6 / 9 | 5.6% | 227 / 260 |
| THE DEAD POOL (00h) | Wolf | 192 / 216 | 73 | 58 / 67 | 6 / 8 | 10.2% | 105 / 124 |
| THE DEAD POOL (00h) | T-unit | 191 / 214 | 75 | 58 / 67 | 6 / 8 | 10.3% | 105 / 124 |
| PIT BOTTOM (0Ah) | Wolf | 171 / 198 | 91 | 52 / 63 | 6 / 8 | 4.5% | 97 / 122 |
| PIT BOTTOM (0Ah) | T-unit | 171 / 197 | 92 | 52 / 63 | 6 / 9 | 4.5% | 97 / 122 |
| THE CAVE (MK3) (19h) | T-unit | 179 / 195 | 94 | 114 / 150 | 6 / 9 | 5.3% | 223 / 278 |
| THE CAVE (MK3) (19h) | Wolf | 179 / 195 | 94 | 114 / 150 | 6 / 9 | 5.3% | 223 / 278 |
| LIVING FOREST (04h) | T-unit | 166 / 190 | 99 | 62 / 79 | 10 / 13 | 4.3% | 136 / 176 |
| LIVING FOREST (04h) | Wolf | 164 / 190 | 99 | 61 / 80 | 10 / 12 | 4.1% | 134 / 178 |
| THE ARMORY (05h) | Wolf | 161 / 182 | 107 | 48 / 58 | 7 / 11 | 3.7% | 131 / 155 |
| THE ARMORY (05h) | T-unit | 161 / 181 | 108 | 48 / 58 | 7 / 11 | 3.7% | 131 / 155 |
| GORO'S LAIR (09h) | T-unit | 154 / 181 | 108 | 68 / 81 | 6 / 9 | 4.4% | 112 / 138 |
| GORO'S LAIR (09h) | Wolf | 154 / 180 | 109 | 68 / 81 | 6 / 9 | 4.5% | 112 / 138 |
| THE WASTELAND (02h) | T-unit | 164 / 178 | 111 | 36 / 46 | 7 / 10 | 3.3% | 98 / 123 |
| THE WASTELAND (02h) | Wolf | 164 / 178 | 111 | 36 / 46 | 7 / 10 | 3.3% | 98 / 123 |
| THRONE ROOM (MK1) (1Ch) | T-unit | 162 / 177 | 112 | 59 / 68 | 6 / 10 | 4.3% | 110 / 133 |
| THRONE ROOM (MK1) (1Ch) | Wolf | 162 / 177 | 112 | 59 / 68 | 6 / 10 | 4.2% | 110 / 133 |
| COURTYARD (MK1) (1Dh) | Wolf | 161 / 175 | 114 | 56 / 65 | 8 / 11 | 4.3% | 102 / 125 |
| YOTEIGAI TOR (18h) | T-unit | 151 / 162 | 127 | 59 / 72 | 11 / 14 | 7.9% | 89 / 120 |
| YOTEIGAI TOR (18h) | Wolf | 150 / 162 | 127 | 58 / 72 | 11 / 14 | 7.7% | 86 / 123 |
| KOMBAT TOMB (01h) | T-unit | 138 / 158 | 131 | 57 / 69 | 8 / 10 | 3.8% | 133 / 160 |
| KOMBAT TOMB (01h) | Wolf | 138 / 158 | 131 | 57 / 69 | 8 / 10 | 3.8% | 133 / 160 |
| PALACE GATES (MK1) (1Eh) | Wolf | 140 / 158 | 131 | 55 / 67 | 8 / 15 | 4.6% | 98 / 122 |
| WARRIOR SHRINE (MK1) (1Bh) | Wolf | 137 / 151 | 138 | 64 / 76 | 6 / 11 | 4.6% | 118 / 140 |
| WARRIOR SHRINE (MK1) (1Bh) | T-unit | 137 / 150 | 139 | 64 / 76 | 6 / 10 | 4.6% | 118 / 140 |
| JADE'S DESERT (UMK3) (20h) | Wolf | 137 / 148 | 141 | 26 / 46 | 6 / 9 | 3.1% | 75 / 105 |
| OUTER HAVEN (16h) | T-unit | 126 / 147 | 142 | 39 / 68 | 6 / 9 | 5.2% | 109 / 167 |
| OUTER HAVEN (16h) | Wolf | 126 / 147 | 142 | 40 / 68 | 6 / 9 | 5.2% | 109 / 167 |
| THE PIT II (bridge) (06h) | T-unit | 120 / 137 | 152 | 36 / 46 | 0 / 0 | 3.6% | 68 / 94 |
| THE PIT II (bridge) (06h) | Wolf | 120 / 137 | 152 | 36 / 46 | 0 / 0 | 3.7% | 68 / 94 |
| THE PORTAL (07h) | T-unit | 120 / 135 | 154 | 35 / 59 | 6 / 9 | 3.8% | 96 / 147 |
| THE PORTAL (07h) | Wolf | 121 / 135 | 154 | 35 / 59 | 6 / 9 | 3.8% | 96 / 147 |
| THE PIT (MK1) (1Ah) | T-unit | 95 / 117 | 172 | 44 / 54 | 9 / 12 | 4.1% | 72 / 93 |
| THE PIT (MK1) (1Ah) | Wolf | 95 / 117 | 172 | 44 / 54 | 9 / 12 | 4.1% | 72 / 93 |

The two boards agree to a line or two on every shared stage, as the shared
blitter says they must.

**KAHN'S ARENA is the one stage near the edge: 17-23 lines of headroom, every
other stage 54 or more.  And it is the heat haze.**  Same ROM, same fight,
`--poke f_skyrows_off=1` (the plain sky blocks): the display interrupt falls
143 -> **54** lines and the drain 255 / 282 -> **151 / 178**.  The haze
(`sky_rows`, MKDISP.ASM; doc/graphics_opportunities/ARENA_HAZE.md) costs
~90 lines of CPU and ~100 of the blitter every frame.  It is not the blits: a
sky line is ~44 us of CPU in the line loop, 127 times.  And it cannot be
narrowed - the envelope (`arena_sky_haze`, BGND.ASM) deliberately moves the
whole plane, rows 22-106, because a still band between moving ones read as a
dead strip in play.  Its safety net already exists: `sky_rows` sheds the haze
for a frame when `@timer` says a tick was missed.  If the Arena ever needs the
room, the lever is the line loop's CPU (it reloads ~10 `.bss` words a line,
and the clock steps every other tick, so half the frames recompute what the
last one did) - measure it with this rig before and after.

**Done (2026-10-12): the line loop's CPU, half-way.**  Two changes in
`sky_rows`, both pixel-identical: the eight per-frame constants the loop
re-read from `.bss` on every line (camera y, wave centre, envelope, clock,
clamp, x0, width) now sit in b0-b5 for the frame (b0-b5 only - the shadow code
that nests in this interrupt uses b6/b7 bare; b0-b5 are saved and given back);
and since both waves repeat every 16 world rows, the haze is worked out 16
times per tier (`skr_dxt`) instead of 127, so a line is one table read.  Proof:
`arena_haze_test.lua`'s five gates ALL PASS, `arena_haze_band_check.py` passes,
and 48 live-haze frames are pixel-identical to the per-line version.  Measured
on the same fight against the original loop (the sweep above):

| KAHN'S ARENA | original | now |
|---|---|---|
| dirq mean / peak | 133 / 144 | **116 / 127** |
| drain mean / peak | 244 / 272 | **227 / 255** |
| headroom | 17 | **34** |

The Wolf Arena moves the same 17 lines (drain 246 / 266 -> 229 / 249).
SCORPION'S LAIR (same loop, `sky_rows_over`) loses 17 lines of dirq but its
drain does not move - it is blitter-bound, not CPU-bound.  The wave table alone
was worth only ~3 lines; the `.bss` loads were the cost.  What is left (~60
lines over the plain sky) is each line's clip and queue push and one DMA
interrupt per line.

**Tried and taken out: merging a run of identical sky lines into one blit.**
A line that fits the page whole (the 440-px texture from VRAM x 0 - the
padding's free left clip - to 511) was held and grown into one blit of n rows.
Pixel-exact (all five `arena_haze_test.lua` gates passed) and it cut the sky's
127 blits to 93, but a same-ROM A/B (`--poke skr_norun=1`) put the drain 4
lines LATER: every merged row draws the texture's 40-px overhang, and a queued
cell's overhead (~4-8 us) is no more than that.  The Tower's 11.4 us average
gap per blit (doc/TOWER_GUARD_REFLECTIONS.md) is mostly the UNQUEUED shadow
blits (~16-18 us); a queued blit is cheap.  **Fewer blits only pays when it
does not cost pixels.**

Next tightest, for whoever adds an effect there: THE TOWER (54, the most
background layers of the stock stages), SCORPION'S LAIR on Wolf (70 - its own
line-drawn overlays, 227 blits) and THE DEAD POOL (73).  THE CAVE has the most
blits (223 / 278) and the longest display interrupt after the Arena (114 / 150)
but 94 lines of headroom.

Rig options added for this: `--video gdi` (a locked desktop cannot open a
bgfx/D3D window - every run came back "no verdict"), `--poke sym=value,...`
(an A/B on one ROM), `--jobs`, `--out`; `perf_stress.lua` also reports the
queued blits a frame (`last_dmaq`/6) and, on stages with a line sky, the sky's
lines.

## 4. If you are adding content and want to know if you are close


```
python build.py --asm-only && python makerom.py && python mamerom.py --source-video
powershell -File tools/run_battle_stability_sweep.ps1      # or the stress harness
python sym_resolve.py --dump | grep peak_overload           # get the address
```

Then read `peak_overload` and `qdma_drops` at the end of a session. A
`peak_overload` above 2 that correlates with *gameplay* rather than a
transition, or any non-zero `qdma_drops`, is the first real signal.

Do not reach for optimisation before those move. The pools are 75-81% empty and
SCRATCH has roughly 380 KB free, so the honest opportunity right now is the
opposite one: effects can afford to be **denser**. `MAX_BLOOD = 64` is a
cosmetic cap that measurement never gets within 4x of.

---

## 5. Gotcha: MAME Lua memory addressing

`space:read_u16` / `write_u16` on this build take the **raw TMS bit address**
out of `src/mk2.map`, *not* `bit // 8`. Reading at `addr // 8` returns zeros.
`battle_stability_sweep.lua` gets this right (and re-reads `mk2.map` at runtime
so it never goes stale); `mk2_test.lua`'s `// 8` is wrong and its address table
is stale besides. The `// 8` rule still holds for the debugger's `w@`, `saver`
and `loadr` — it is only the Lua accessors that CLAUDE.md describes wrongly.
