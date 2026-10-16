# Background strip distortion (`strip_layer`)

**Status: implemented and validated in MAME, 12 September 2026.** This is
[first prototype](../GRAPHICS_OPPORTUNITIES.md#82-first-prototypes) #8,
"one 4–8-strip background distortion". It covers §6.4 ("Strip and span
rendering") and opportunity 19 in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md).
It is **compiled in but off at run time**: with `f_strip` 0 the entry is
exactly the ordinary display-list entry. FBNeo and physical hardware have not
been run.

**Verdict:** it works. Any single background list can be drawn as up to 8
horizontal bands, each at its own x, over a stable anchor. There are no
seams, and every later layer, fighters and HUD included, is untouched. The
cost is synchronisation, not pixels. Each band change has to wait for the DMA
queue to drain, and 8 bands spent about 78 of 288 scanlines stalled. In this
scene that fitted inside the frame: `peak_overload` stayed at 2 and no blit
was abandoned.

![THE WASTELAND, top to bottom: baseline; 8 bands at ±6 px alternating; the built-in wave (±3 px). Only the distant mountain range (baklst6) moves; the statues, castle, pagoda and HUD in front of it do not.](strips_strip.png)

## How it works

| | |
|---|---|
| Code | `strip_layer`, `stl_one`, `stl_drain`, `stl_wave` ([MKDISP.ASM](../../src/MKDISP.ASM)) |
| Dlist entry | `.long -1,strip_layer,baklst6,worldtlx6+16` in `dlists_battle` ([BGND.ASM](../../src/BGND.ASM)); it replaces `.long baklst6,worldtlx6+16` |
| Inputs | `f_strip` (0 off, 1 table, 2 built-in wave), `strip_n` (1–8), `strip_top`, `strip_h`, `strip_off[8]` (signed px) |
| Sentinels | `strip_ran`, `strip_refused`, `strip_v0`/`strip_v1` (vcount) |
| Switch | `strips .set 1` ([MAINEQU.ASM](../../src/MAINEQU.ASM)) |

- **Inline parameters.** The list and its worldtlx word sit after the routine
  in the dlist, and the callback advances the walker's `a3` past them. So the
  entry reads like the one it replaces, and turned off it *is* that entry: a
  single `dispnext` call with the same `a4` and the same window.
- **One pass per band.** Each pass narrows two windows to the band's rows:
  - the **software** window (`a14`/`a13`), so objects wholly outside the band
    are never queued;
  - the **DMA** top/bottom clip (`dmatplft`, in absolute VRAM rows with
    `pageaddr`'s y added), so objects straddling the band draw only its rows.
- **Stable anchor.** Band x is the plane's real `worldtlx` minus that band's
  offset, recomputed every frame. Nothing accumulates, so scrolling and the
  distortion cannot drift apart.
- **Above and below the bands.** Two extra passes at offset 0 draw those
  rows. Without them the plane would vanish outside the bands.
- **Velocities once.** `dispnext` adds object velocities whenever `b0` is
  clear. Only the first pass gets the caller's `b0`; later passes skip it.
- **Drains.** The DMA clip is global and is latched when each blit starts
  (MAME `midtunit_v.cpp` and FBNeo `midtunit_dma.h` agree). So every window
  change drains the queue first, using the same drain `geo_layer` relies on
  mid-list ([PALRECT_PROTOTYPE.md](PALRECT_PROTOTYPE.md) Part 1).

## Result

THE WASTELAND, fighters hidden and parked, camera still, one frozen ROM,
six boots. The bands cover rows 40–135 (8 × 12), with offsets ±6 px.

| Gate (audit #8) | Evidence | Result |
|---|---|---|
| **Seams**: no gap, doubled row or lost row | 8 bands at offset 0 vs the ordinary entry: **0** px differ, 3 of 3 snapshots | **pass** |
| **Stable anchors** | Band *k*'s rows in the ±6 alternating boot equal the whole-plane +6 boot (even *k*) or −6 boot (odd *k*) exactly: **0** wrong | **pass** |
| **Foreground behaviour** | Every row outside the bands equals the baseline (**0** wrong). Inside the bands, every later layer (castle, statues, floor, near planes, HUD) is identical to the shifted single draws, which move only baklst6 | **pass** |
| The banded list is really on screen | +6 vs baseline: 1,706 px moved | **pass** |
| **Bounded queue** | `deep_dmaq` 534 → 576 words (+7 cells of 500); `dmaq_late` **0** | **pass** |
| **Bounded time** | `peak_overload` 2 in every mode (baseline 2) | **pass** |

### Where the time goes

| Mode | Passes | Lines inside `strip_layer` |
|---|---|---|
| 1 band, whole screen | 1 | 39 |
| 8 bands | 10 | 78 |

The first drain waits for every earlier list's blits (the sky and baklst8/7)
to finish. That alone is about 39 lines, time the CPU would otherwise have
spent queueing later lists while the blitter worked. Each band after that
waits only for its own blits. The pixel work is small (a band re-queues just
the blocks that cross it). The cost is the CPU and the blitter no longer
overlapping. A stage whose frame is already tight (THE TOWER with
reflections, 86–90% to the last blit) would feel that stall; THE WASTELAND
does not.

## The bug the rig caught

The first run failed on **row 253 only**: all 400 px were a flat colour in
every banded mode. The restore wrote `init_dma_window`'s power-up clip,
`[508:0]`. But during play `dirq` ([MKINIT.ASM](../../src/MKINIT.ASM)) sets a
per-page window, `[page y + 253 : page y]`, on every flip. The wider window
let every later list draw past the page's last row. The fix restores the
`dirq` value, as `shadow_p1p2`'s fill already did. So **anything that moves
`dmatplft` must restore it from `pageaddr`, never from a constant.**

## Motion follow-up

The [review](PROTOTYPE_REVIEW.md) noted that the still-image run proves
nothing about moving fighters, scrolling or moving background objects.
`--motion` covers all three. The fighters are visible and walk right, then
left, so the camera scrolls from x 442 to 632 and back to 489 and the
fighters cross the band rows. There are fifteen snapshots across five boots
on the same frozen ROM, and every boot saw the identical camera at every
snapshot.

| Case | Result, 15 snapshots |
|---|---|
| Zero-offset bands vs ordinary entry, while scrolling | **0** px differ at every snapshot |
| Alternating bands vs shifted single draws, fighters in front | **0** wrong band rows, **0** wrong other rows |
| With `ST_VEL=1`: baklst6's first object moving 1 px/refresh | still **0** / **0** / **0**. The moving object changes the picture (the `plus` moved-pixel counts differ from the static run at every snapshot), so the velocity-once rule was exercised: a second velocity add would have broken zero == base |
| Cost | Same as the still run: 78 lines for 8 bands, `peak_overload` 2, `dmaq_late` 0 |

Stock THE WASTELAND has no moving object on baklst6 (4 objects, none with a
velocity), so the velocity case had to be constructed.

![Motion run, rel 460: baseline (left) and alternating bands (right). The distant range shears; both fighters, the statues and the HUD are identical.](strips_motion.png)

```powershell
python tools/run_strips_test.py --rom-dir tmp/strips/rom --map tmp/strips/mk2.map --motion
$env:ST_VEL = "1"; python tools/run_strips_test.py --rom-dir tmp/strips/rom --map tmp/strips/mk2.map --motion
```

## Known limitations

- One list per entry. Distorting two planes means two entries, and two sets
  of drains.
- Bands are horizontal. Vertical displacement per band would also need the
  band's source rows moved, which the clip window cannot express.
- The effect is a hard shear at band edges. With 8 bands of 12 rows it reads
  as heat haze over distant art. It does not read well on near, detailed art,
  so pick the plane accordingly.
- `f_strip 2`'s wave is a demo producer (±3 px, 16 steps). A real effect
  should own `strip_off` and turn it on and off with a stage event.

## Reproduce

```powershell
python build.py --asm-only; python makerom.py
python mamerom.py --no-install --output tmp/strips/rom/mk2.zip
Copy-Item src/mk2.map tmp/strips/mk2.map
python tools/run_strips_test.py --rom-dir tmp/strips/rom --map tmp/strips/mk2.map
```

`--top/--h/--n/--d` change the bands, and `--rejudge <run dir>` re-scores a
run without booting. If `makerom` reports that `mk2.out` is missing, the link
was still finishing; wait for it and run it again.

## Files and evidence

- [Recorded results](strips_results.json), including the failed run from
  before the window fix, and [the strip](strips_strip.png).
- [Rig](../../tools/strips_test.lua), [runner](../../tools/run_strips_test.py).
