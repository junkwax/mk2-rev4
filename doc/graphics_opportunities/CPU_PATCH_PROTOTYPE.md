# CPU patch: mosaic and stipple (opportunities 22 and 23)

14 September 2026. **Prototyped and validated in MAME; compiled in, runtime-off;
built privately, not installed.** Covers row 22 (dithered masks / stippled
coverage) and row 23 (small CPU pixel operations) of
[the graphics audit](../GRAPHICS_OPPORTUNITIES.md), §6.1 and §6.5.

![Liu Kang's head, 32×32: the baseline, a 4-px mosaic, and a white 50% stipple. The stipple leaves every other pixel exactly as drawn, hair, headband and background each in its own palette.](cpu_patch_strip.png)

## What it does

`cpu_patch` ([MKDISP.ASM](../../src/MKDISP.ASM), `cpupatch .set 1` in
MAINEQU.ASM) is a post-process on the finished picture, run last at dsa9
right after `pal_rect`:

- **Mosaic** (`cp_mode` 1): the rectangle is cut into `cp_arg` × `cp_arg`
  blocks, and each block is filled with its top-left pixel: colour index
  **and** colour-map selector, so every block keeps the right palette.
- **Stipple** (`cp_mode` 2): pen `cp_arg` of colour map `cp_map` on the
  (x+y)-odd checkerboard. The other half of the pixels are left exactly as
  drawn. It is a screen-door shade; nothing on this machine blends.

Inputs (all `.global`): `cp_xy` (y:x), `cp_hw` (h:w), `cp_mode`, `cp_arg`,
`cp_map`, then `cp_count` (consumed every frame, so re-arm every frame).
Sentinels are `cp_ran` and `cp_refused`, and `cp_v0`/`cp_v1` time the pass
off vcount. x and w must be even. A mosaic block must be even, 2-16, and
divide both w and h. The area is at most `CP_MAXPX` (4,096), and at most `CP_STIPPX`
(2,048) for a stipple. Any other
request is refused whole.

## The hardware rule that makes the stipple possible

`pal_rect` settled that only **aligned word** VRAM accesses behave the same
in MAME and FBNeo: FBNeo's `TUnitVramWrite` ignores the byte mask. A word
holds two pixels, and a stipple has to change only one of them. The key is
what a pixel-plane word write does to the **selectors**. FBNeo
(`TUnitVramWrite`, [midtunit.cpp](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/burn/drv/midway/midtunit.cpp)):

```c
DrvVRAM16[offset]     = (data & 0xff)        | ((nDMA[DMA_PALETTE] & 0xff) << 8);
DrvVRAM16[offset + 1] = ((data >> 8) & 0xff) | (nDMA[DMA_PALETTE] & 0xff00);
```

The even pixel takes its selector from `dmacmap`'s **low** byte and the odd
pixel from its **high** byte. So each stipple word does this:

1. Read the two selectors in the map plane (`objpalet` clear).
2. Keep the untouched pixel's selector and give the pen pixel `cp_map`.
   Write that pair to `dmacmap`.
3. Read the two indices in the pixel plane, splice the pen in, and write the
   word back.

Both pixels get written, but the untouched one is rewritten exactly as it
was. Nothing needs restoring afterwards, because every blit reloads `dmacmap`
from its queue cell. A mosaic block needs only one `dmacmap` write (the
anchor's selector in both bytes) and then plain word fills.

A corollary for the existing CPU drawing (`geo_pass`, the HUD text): a CPU
word write with a non-zero map needs the map in **both** bytes of
`dmacmap`. Every current producer uses map 0, so nothing is wrong today.

Everything else is `pal_rect`'s contract, unchanged: drain the DMA first,
keep interrupts off while `sysctrl` is flipped, restore the latch from
`syscopy`, and never touch PMASK or CONTROL.

## Validation (`tools/run_cpu_patch_test.py`, `tools/cpu_patch_test.lua`)

THE WASTELAND, Liu Kang vs Cage, parked, clock frozen; the palrect fight.
Three boots on one frozen ROM, one after another, windowed `-debug`:
`none` (baseline), `mosaic`, `stipple`. Each is armed from rel 300 to 439, with
snapshots at rel 400 and 430 (armed) and 460 (disarmed). All three boots
logged the same `PREARM` line (fight frame, both fighters' x, `rand`) before
any pixel was compared.

32×32 at (x 96, y 100), over Liu Kang's head and the far planes; mosaic
block 4, stipple pen 0Eh (`bpal_white`) in map 0:

| Gate | Result |
|---|---|
| Outside the rectangle, both modes, both armed snapshots | **0** px differ |
| Mosaic: pixels changed inside | 658 / 639 |
| Mosaic: pixels not equal to their block's baseline top-left pixel | **0** |
| Stipple: checker pixels in the pen's colour | **512 / 512** |
| Stipple: other pixels inside, vs the baseline | **0 / 512** changed (54 distinct colours, several palettes) |
| Disarmed snapshot vs baseline, whole screen, both modes | **0** px differ |
| Passes / refused | 140 / 0 each |
| `peak_overload` / `qdma_drops` | 2 / 0 (same as the baseline) |

## Cost

| Rectangle | Words | Mosaic lines | Stipple lines |
|---|---|---|---|
| 32×32 (block 4) | 512 | 14.4 (max 15) | 30.4 (max 31) |
| 64×32 (block 8) | 1,024 | 15.4 (max 16) | 58.8 (max 59) |
| 64×64 (block 8) | 2,048 | 30.5 (max 31) | refused whole (over `CP_STIPPX`) |

Lines out of 288 per frame. A stipple word costs 2 VRAM reads, 1 VRAM write,
2 `sysctrl` writes and 1 `dmacmap` write: about **0.059 lines per word**,
roughly `pal_rect`'s 0.054. It is linear: 30.4 lines for 512 words, 58.8 for 1,024.

A mosaic's cost comes mostly from its blocks. The runs fit about **0.14
lines per block** (two plane flips and two VRAM reads) plus about **0.011
lines per word** written. That model predicts 30.9 lines for 64 blocks and
2,048 words; the measurement was 30.5.

So the two modes get different caps:

- `CP_MAXPX` = 4,096 px. A 64×64 mosaic in 8 px blocks is about 31 lines.
- `CP_STIPPX` = 2,048 px for a stipple, which is 59 lines. A 4,096 px stipple
  extrapolates to about 117 lines, the size at which `pal_rect` overran the
  frame and changed the game.

Both boundaries were run. A 2,048 px stipple passes every gate. A 64×64
stipple is refused on all 140 frames, and its boot stays pixel-identical to
the baseline, while the mosaic in the same run passes.

## Limits

- Small patches only, the same envelope as `pal_rect`. It works on the
  finished picture, so it cannot see hidden layers and it does not blend.
- A stipple is a 50% screen door. Other densities (25%, lines) are the same
  loop with a different mask sequence, not built.
- No gameplay producer arms it. Natural uses: a mosaic for a censor or
  "teleport-in" beat, a stipple shade over a fighter held in a portal or a
  freeze.
- FBNeo has not been run. The design uses only the aligned-word form that
  FBNeo's source handles identically.

## Reproduce

```powershell
python build.py --asm-only; python makerom.py; python makevrom.py
python mamerom.py --no-install --output tmp/cpu_patch/build/rom/mk2.zip
Copy-Item src/mk2.map tmp/cpu_patch/build/mk2.map
python tools/run_cpu_patch_test.py --build tmp/cpu_patch/build
python tools/run_cpu_patch_test.py --build tmp/cpu_patch/build --rect 96,80,32,64 --block 8
python tools/run_cpu_patch_test.py --build tmp/cpu_patch/build --rect 80,80,64,64 --block 8 --expect-stipple-refused
```

`--rejudge <run dir>` re-scores an existing run. Results:
[32×32](cpu_patch_results_32x32.json),
[64×32 (the stipple cap)](cpu_patch_results_64x32.json),
[64×64 (stipple refused)](cpu_patch_results_64x64_refused.json).
