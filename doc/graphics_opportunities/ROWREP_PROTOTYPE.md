# Row repetition (graphics audit row 24)

The TMS34010 can show each video-RAM row more than once, stretching the whole
picture vertically for free: no DMA blits, no art, no objects. This page
records how the emulators implement it, where MK2 can drive it, and the
prototype that proves it.

## How the display address advances

Both emulators the game runs on implement the same rule. FBNeo's TMS34010 core
is the same logic as MAME's.

- **Once per frame, at the vertical sync blank line (`vsblnk`):** `DPYADR`
  (display address) is reloaded from `DPYSTRT` (display start).
- **On every visible line**, the two low bits of `DPYADR` are a line counter.
  If they are 0, `DPYADR` steps by the DUDATE field of `DPYCTL`
  (`DPYCTL & 0x3fc`) and the counter reloads from `DPYSTRT`'s low two bits
  (LNCTR). Otherwise the counter just decrements:

  ```c
  if ((dpyadr & 3) == 0)
      dpyadr = ((dpyadr & 0xfffc) - (IOREG(REG_DPYCTL) & 0x03fc)) | (IOREG(REG_DPYSTRT) & 0x0003);
  else
      dpyadr = (dpyadr & 0xfffc) | ((dpyadr - 1) & 3);
  ```

- **The T-Unit renderers** in MAME (`midtunit_v.cpp`) and FBNeo (`midtunit.cpp`)
  pick each scanline's VRAM row from the CPU's display parameters:
  `rowaddr = DPYADR >> 4`, then `videoram[(rowaddr << 9) & 0x3fe00]`.

So LNCTR = n shows every row n + 1 times: a ×2, ×3 or ×4 vertical stretch
from the top of the displayed page. MK2 programs `DPYCTL = 0f010h`, whose
DUDATE field advances one row per step, and its page-start values `dpystrt0`
(`0fffch`) and `dpystrt1` (`0effch`) have LNCTR = 0. No stock code ever sets
it.

TI's own register description (TMS34010 User's Guide, display-control
chapter) was not re-read for this page: the mirrored PDF is over WebFetch's
10 MB limit. The semantics above come from the two emulator sources, which
agree with each other. Real-board behaviour has not been tested.

## Where MK2 can drive it

The display interrupt `dirq` (MKINIT.ASM) flips pages. Every frame it writes
the page's start value to both `DPYADR` and `DPYSTRT` (`stuffd`). A value
written from anywhere else, such as a Lua poke or a game process, is
overwritten on the next flip. `tools/hw_effects_demo.lua` measured exactly
that. The flip is therefore the one place the line counter can go.

## The prototype

- `rowrep .set 1` (MAINEQU.ASM) compiles it in; `0` leaves the flip stock.
- `@f_rowrep` (RAM.ASM, one word, 0 at power-up) is the runtime control.
- At `stuffd`, `dirq` ORs `@f_rowrep & 3` into the start value before both
  writes. `a1` is free there: it is cleared before the flip and not read again
  until it is reloaded from `@timer`.

With `@f_rowrep` at 0 the value written is exactly the stock one.

## The proof

`tools/run_rowrep_test.py` runs `tools/rowrep_test.lua` in one boot, in a
private windowed MAME under `-debug`. In each of several short windows it
captures `@f_rowrep` = 0, then 1, 2 and 3, then 0 again, 4 frames apart, and
logs `DPYSTRT`/`DPYADR` at each capture.

A window is judged only if its two 0-captures are identical, which proves the
scene was static. Each stretched capture must then equal the 0-capture with
every row shown n + 1 times. Every starting phase of the counter is tried,
because the visible area can begin mid-count. Because every comparison is
inside one boot, cross-boot nondeterminism
([rig boot nondeterminism](../../tools/run_ghost_test.py)) cannot affect it.

```powershell
python tools/run_rowrep_test.py --rompath tmp/rowrep/rom --root tmp/rowrep/frozen
```

## Results

**15 September 2026, MAME, private package `tmp/rowrep` (built, not installed).**

- **The register takes it.** The flip writes the bits every frame. At each
  capture `DPYSTRT` reads `effc`, `effd`, `effe`, `efff` for `@f_rowrep`
  0/1/2/3 (page 1), and returns to `effc` at 0.
- **The picture stretches exactly.** Two runs had 14 capture windows. The 6
  whose before and after 0-captures were identical, all on the static attract
  title, were judged; the other 8 caught the attract loop animating and were
  refused rather than scored. In all 6, the ×2, ×3 and ×4 captures match the
  0-capture with every row shown 2, 3 or 4 times: **254 of 254 rows**, 0
  mismatches, phase 0. The repeat starts cleanly at the first visible line.
  Results: [first run](rowrep_results_run1.json) (5 windows, 1 judged) and
  [second run](rowrep_results.json) (9 windows starting at frames 1300-1700,
  5 judged).
- **Off costs nothing visible.** With `@f_rowrep` at 0, Kahn's portal
  fatality and Sonic Clap are 321/321 and 72/72 captures pixel-identical to
  the build before the change.

| `@f_rowrep` | `DPYSTRT` (page 1) | Picture |
|---:|---|---|
| 0 | `effc` | stock |
| 1 | `effd` | top 127 rows, each shown twice |
| 2 | `effe` | top 85 rows, each shown three times |
| 3 | `efff` | top 64 rows, each shown four times |

The attract title at ×2, ×3 and ×4 is the Mortal Kombat II logo stretched
downward from the top of the screen, as expected.

## Limits and what it is for

- **It stretches from the page top only.** The visible window starts at row 0
  of the page, so ×n shows the top 254/n rows. Zooming on another band means
  also moving the start address, which the same flip writes (see
  `hw_effects_demo.lua` on `dpystrt`).
- **It is whole-screen, including the HUD.** The display repeats rows, it
  does not know about layers. So it suits a transition, a stepped reveal or a
  deliberate effect, not an in-fight zoom.
- **Nothing else changes.** Drawing, the DMA, the page write windows and every
  interrupt keyed to the physical line count are untouched. Row repetition is
  a display-side mapping only.
- **Untested:** FBNeo (its core has the identical code path, but it was not
  run here), a real T-Unit board, and interlaced timing. A `DUDATE` change
  (skipping rows instead of repeating them) was not tried.

No gameplay producer uses it. It is compiled in and off at run time.
