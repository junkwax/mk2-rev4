# Palette-map rectangle and interlayer line

**Status: implemented and validated in MAME, 12 September 2026.** This is
[first prototype](../GRAPHICS_OPPORTUNITIES.md#82-first-prototypes) #7,
"small palette-map rectangle and one interlayer line". It covers §6.2 (region
recolouring through the palette-map plane) and §6.3 (CPU drawing at useful
depths) of [the graphics audit](../GRAPHICS_OPPORTUNITIES.md). Both halves are
**compiled in but off at run time**: nothing is drawn or recoloured unless a
producer arms the list for that frame. FBNeo/Fightcade and physical hardware
have not been run (see [Emulator agreement](#emulator-agreement)).

**Verdict:** both mechanisms work exactly as intended. The interlayer line
costs nothing new. The palette-map pass is correct but expensive: about
**0.054 scanlines per two pixels**. A 32×32 region costs about 10% of a frame,
and 80×64 overran the frame badly enough to change the game. It suits small
local effects (a spark, a hand, a thin band). It cannot tint a large region
or the whole screen.

**Review follow-up:** `pal_rect` now rejects an area above **1,024 pixels**
before draining DMA or entering the map plane. The 32×32 boundary still
passes; both 27×38 (1,026 pixels) and the original 64×80 overrun case are
refused whole with all captures identical to the unarmed baseline. The
runner defaults to the bounded 32×32 case and accepts `--expect-refused`
for negative tests. This bounds the map walk, not the total frame workload;
a producer must still budget the effect for its scene.

![32×32 rectangle over Liu Kang's head: left baseline, right the same pixels re-pointed at Cage's palette. Index unchanged, palette changed. The background inside the rectangle is untouched.](palrect_strip.png)

## Part 1 - the interlayer line (`geo_layer`)

The `geo_pass` geometry path draws at dsa9, on top of everything. `geo_layer`
draws the same records from a second list, `geo_llist`/`geo_lcount`, at any
point in a stage's display list. It is dispatched as `.long -1,geo_layer` by
`disp4`, exactly like `floor_code` and `flash_layer`.

| | |
|---|---|
| Code | `geo_layer` / shared `geo_body` ([MKDISP.ASM](../../src/MKDISP.ASM)) |
| Placement (prototype) | THE WASTELAND, `dlists_battle` ([BGND.ASM](../../src/BGND.ASM)): after `-1,floor_code`, before `baklst2`, `baklst1` and the `-2` shadow marker |
| List | `geo_llist`, 32 records of `[colour, xy, dydx]`, consumed every frame |
| Switch | `geoline` (MKDISP.ASM); the `.else` arm leaves a `rets` stub so a display list may still name it |

**Why a mid-list drain is valid** (read from the source): `clip7` queues each
object *and* kicks the DMA immediately. When `geo_layer` runs, the queue holds
only the earlier lists' blits, and `geo_body`'s drain finishes exactly those.
No later list has queued anything yet.

### Result

| Gate | Evidence | Result |
|---|---|---|
| Above earlier lists | Front and layer both draw all 400 px at row 175 (floor and far planes) | **pass** |
| Under later lists | Row 40: the life bars cover 336 of 400 px. Row 150: every gap is inside a fighter. Row 190: fighters plus 64 px of the rock ridge (`baklst1/2`), at the same x in all three snapshots | **pass** |
| Front-most line never covered | 0 gaps on every row, every snapshot | **pass** |
| Registers, CONTROL, dmacmap, page restored | Two-line boots: **0** pixel differences off the line rows, 3 of 3 snapshots vs the no-geometry boot | **pass** |
| Cost | `peak_overload` 2 in all three boots, the same as no geometry | **pass** |

One trap: 26 full-width lines (10,400 PIXTs with interrupts off) changed the
frame timing enough that the boots drifted apart. There were about 64k
off-line pixel differences, none caused by the line code. So a cross-boot
diff only proves anything with a light load. The fighters rig judges each
boot by itself for that reason.

**Rerun on the newer build** (the strips ROM, which carries `geo_layer`
unchanged). The fighter-depth rig passes with the same numbers: at row 150
every gap is inside a fighter (73–81 px); at row 190 the gaps are the
fighters plus the 64 px rock ridge, with 0 unexplained. The front-most line
has 0 gaps. See `geo_layer_fighters_rerun` in
[the results](palrect_results.json).

## Part 2 - the palette-map rectangle (`pal_rect`)

Every VRAM pixel is 16 bits: the colour **index** in the low byte and the
colour-map **selector** in the high byte. The selector is whichever 256-entry
block of colour RAM `dmacmap` named at blit time. `sysctrl` bit 5
(`objpalet`) chooses which byte a CPU access sees:

- **Set** (`syscinit`, `007ch`): the pixel plane the game always runs in.
- **Clear** (`pal_select`, `005ch`, borrowed from DIAGDTST's palette-RAM
  test): the map plane. A word read returns the two pixels' selectors, and a
  word write replaces only the selectors.

`pal_rect` walks a rectangle in the map plane and passes every selector
through a 256-word selector-to-selector table. It re-points pixels that are
already drawn at a different palette without knowing what was drawn.

| | |
|---|---|
| Code | `pal_rect` ([MKDISP.ASM](../../src/MKDISP.ASM)), called **last** at dsa9, after `flash_pass`: a post-process on the finished picture |
| Inputs | `pr_count` (armed this frame, consumed), `pr_xy` origin `y:x`, `pr_hw` size `h:w`, `pr_map[256]` |
| Sentinels | `pr_ran`, `pr_refused`, `pr_v0`/`pr_v1` (vcount at start and end) |
| Switch | `palrect .set 1` ([MAINEQU.ASM](../../src/MAINEQU.ASM)) |

The rules it follows, each one from the audit's list:

- **Drain first.** It uses the same `intenb`/`dmactrl` drain as `geo_body`.
- **The page.** Addresses come from `pageaddr` exactly as every other
  destination's do. `scrn_ptch` is 2^12 bits, so the address is two shifts.
- **`sysctrl` and its mirror.** `sysctrl` is write-only and `syscopy` is its
  RAM mirror; interrupt code (MKINIT's LED blink) writes the mirror back to the
  latch. So interrupts are **off** for the whole map-plane window, the mirror
  is never changed, and the latch is restored *from* the mirror.
- **No PMASK.** PMASK, PPOP and the window field are pixel-operation state,
  and a `MOVE` ignores them. CONTROL is not touched.
- **Word accesses only, x and w even.** This is the part that decides
  emulator agreement (below). A rectangle that breaks the rule or leaves the
  screen is refused whole.

### Result

THE WASTELAND, Liu Kang (P1) against Johnny Cage (P2), both visible and
parked, with the camera still. Three boots on one frozen ROM:

- `none`: nothing armed.
- `ident`: the rectangle with the identity table.
- `swap`: P1's selector mapped to P2's.

The pass was armed for 140 frames. Snapshots at rel 400 and 430 are armed;
rel 460 is 20 frames after disarming.

| Gate | 24×24 | 32×32 |
|---|---|---|
| **Pixel/map isolation**: identity table vs baseline, whole screen, 3 snapshots | **0** px differ | **0** px differ |
| **Outside the rectangle** (swap) | **0** px differ | **0** px differ |
| Inside: pixels changed | 156 / 182 | 243 / 262 |
| Inside: changed pixels **not** explained as "same index, P2's palette" | **0** | **0** |
| Inside: pixels not in P1's palette that changed (background) | **0** | **0** |
| **No leak into the next frame**: disarmed snapshot vs baseline | **0** px differ | **0** px differ |
| Refused rectangles | 0 | 0 |
| **Cost** (vcount lines of 288) | **15.8** | **27.8** |
| `peak_overload` (baseline 2) | 2 | 2 |

"Explained" is strict. The runner reads both palettes out of colour RAM
(`PAL` lines in the log) and requires each changed pixel's baseline colour to
be `P1pal[i]` and its new colour to be `P2pal[i]` for the **same** `i`.
Colours are converted with MAME's 5-to-8-bit expansion.

### Cost, and why it limits the idea

| Rectangle | Words | Lines | Share of a frame | `peak_overload` |
|---|---|---|---|---|
| 24×24 | 288 | 15.8 | 5.5% | 2 |
| 32×32 | 512 | 27.8 | 9.7% | 2 |
| 80×64 | 2,560 | **130** | **45%** | **135** |

The cost is linear at about 0.054 lines, or 3.4 µs, per word: one VRAM read,
two table reads and one VRAM write, about 21 machine cycles. At 80×64 the
frame overran, the boots diverged (the swap boot's snapshot shows a different
moment of the round), and the comparison failed for that reason alone. The
whole 400×254 screen would take about 2,700 lines, or 9 frames. Faster loops
would help only at the margins. A compare-and-skip path for words with no
remapped selector saves the table reads and the write, but not the VRAM
read, so expect well under 2×. The practical envelope is **about 32×32 per
frame, or a thin band**.

## Emulator agreement

Both T-unit implementations select the plane with bit 5 of the control
register and give it the same word semantics. MAME has
`midtunit_control_w`/`midtunit_vram_r/w`. FBNeo has `TUnitCtrlWrite`,
`TUnitVramRead` and `TUnitVramWrite` in
[midtunit.cpp](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/burn/drv/midway/midtunit.cpp).
They differ in one place. **MAME's VRAM handler honours the byte mask. FBNeo's
takes no mask**, and its CPU interface passes a byte write straight to the
16-bit handler
([tms34_intf.cpp](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/cpu/tms34_intf.cpp)).
`pal_rect` uses only aligned 16-bit reads and writes, the one form both handle
identically. That agreement is established from source; this pass has not
been run in FBNeo.

**Open question for the geometry path, not for `pal_rect`:** `geo_line` plots
with `PIXT` at 8 bits per pixel, which is a byte write. Whether FBNeo's core
turns that into a whole-word handler call depends on its field-write path. If
it does, the neighbouring pixel of every line pixel would take the line's
colour map, and possibly index 0, in FBNeo only. That would affect
`geo_pass`, `geo_layer` and the shipped hitbox overlay alike. Settle it with
an FBNeo run before relying on CPU lines under Fightcade. Only
`fbneo_libretro.dll` exists on this machine, with no front end to drive it.

## Reproduce

```powershell
python build.py --asm-only; python makerom.py
python mamerom.py --no-install --output tmp/palrect/rom/mk2.zip
Copy-Item src/mk2.map tmp/palrect/mk2.map
python tools/run_palrect_test.py --rom-dir tmp/palrect/rom --map tmp/palrect/mk2.map --rect 100,96,32,32
python tools/run_palrect_test.py --rom-dir tmp/palrect/rom --map tmp/palrect/mk2.map --rect 96,80,64,80 --expect-refused
python tools/run_geo_layer_test.py --rom-dir tmp/palrect/rom --map tmp/palrect/mk2.map --pen 7
python tools/run_geo_layer_fighters.py --rom-dir tmp/palrect/rom --map tmp/palrect/mk2.map --pen 7
```

Pen 7 is `bpal_hot_green` (00707h). `--rejudge <run dir>` re-scores an
existing run without booting. Verify the package by content, not by
timestamps (DOSBox clock skew).

## Files and evidence

- [Recorded results](palrect_results.json), including the failed 80×64
  overrun run, kept deliberately. Also [the palette strip](palrect_strip.png)
  and [the interlayer crop](geo_layer_fighters.png): rows 150 and 190, with
  the line under the fighters and the rock ridge.
- Rigs: [palrect_test.lua](../../tools/palrect_test.lua) with
  [run_palrect_test.py](../../tools/run_palrect_test.py), and
  [geo_layer_test.lua](../../tools/geo_layer_test.lua) with
  [run_geo_layer_test.py](../../tools/run_geo_layer_test.py) (three-boot
  leak check) and
  [run_geo_layer_fighters.py](../../tools/run_geo_layer_fighters.py)
  (per-boot depth against the fighters).
