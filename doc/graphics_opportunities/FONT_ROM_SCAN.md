# Art fonts vs CPU text (opportunity 27)

15 September 2026. **Closed: measured, no ROM case.** Offline only; nothing
was changed.

## What the art fonts cost

MKTEXT prints with three fonts, all DMA sprite art in video ROM:

| Font table | Used by | Glyph records | Stored | Depth | Colours in the art | Glyph sizes |
|---|---|---:|---:|---|---:|---|
| `rd15font` = `MK2FONT*` | `p15_*`: round-end and win messages | 58 | 1,054 B | 1 bpp | 1 | 3-19 × 2-16 |
| `rd11font` = `vfont*` (Vogel's) | `p11_*` | 57 | 461 B | 1 bpp | 1 | 3-10 × 2-12 |
| `rd7font` = `FONT7*` | `p7_3s` | 59 | 354 B | 1 (a few 6) bpp | 1 | 3-11 × 2-10 |
| **All three** | | 174 | **1,869 B** | | | |

Measured with [`tmp/font_scan/font_rom_scan.py`](../../tmp/font_scan/font_rom_scan.py),
which decodes every glyph out of the packed video ROM. Each glyph uses a
single colour index; the letter's colour comes from the palette the print
call names (`a11`), not from the art.

## Why a CPU font does not pay

- **There is almost nothing to save.** 1,869 bytes is 0.4% of the
  **463,216 bytes** still free in video ROM (bank 0 107,760, bank 1 355,456;
  `tools/rom_space_report.py`).
- **The CPU cannot read these glyphs as they are.** `PIXBLT B` reads a linear
  1-bpp bitmap, and these are zero-compressed DMA records. A CPU copy would be
  about the same 1.9 KB again, taken from the 144,840 bytes of program-ROM
  headroom, the budget that runs out when moves are added. So a swap is a
  wash.
- **`sysfont` is not a drop-in replacement.** The CPU-path font (DIAGFONT.ASM)
  is the service menu's proportional 1-bpp font, up to 8×8, with much of its
  punctuation mapped to a blank. It would change how the 15-point messages
  look.

## Where CPU text does pay

Presentation, not ROM. Every art-font letter is an object, plus a shadow
object for the shadowed calls, created through `initobj`. That is why a long
round-end line was a hang risk until MKTEXT learned to drop a letter (row 10,
gap 2). CPU text uses no objects, processes or palettes. It is redrawn every
frame after the DMA, with interrupts off while it draws. That already exists
and is proven pixel-exact: `hud_pass` / `hud_string` / `hud_num` with
`sysfont` (`hudtext`, MKDISP.ASM; `tools/hud_pixblt_test.lua`). It suits new
menus, training readouts and diagnostic charts, where a 1-bpp 8×8 face is
fine. No new infrastructure is needed.
