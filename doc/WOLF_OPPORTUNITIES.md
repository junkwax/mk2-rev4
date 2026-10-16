# Wolf-unit opportunities - graphics, CPU and board resources

The Wolf-unit companion to [GRAPHICS_OPPORTUNITIES.md](GRAPHICS_OPPORTUNITIES.md)
(the T-unit audit). It asks what MK2 can take advantage of on the MK3 / UMK3
board that is unused, underused or undocumented, and what the other Wolf games
did with the same hardware. Snapshot **2026-10-11**. The port itself is in
[WOLF_UNIT.md](WOLF_UNIT.md); ROM space per board in [WOLF_SPACE.md](WOLF_SPACE.md).

## Status (2026-10-11, same day)

Five of the map's rows are built, proven and installed:

| ID | What | Proof |
|---|---|---|
| W01 | `mapplane` (MKDISP.ASM): bit 11 on Wolf, `objpalet` on the T-unit | `run_palrect_test.py --game umk3`: identity table 0 px changed over 140 armed passes; swap 243/262 px changed, every one "same index, other palette". The T-unit instruction is unchanged |
| W02 | `mk2wolf.exe` loads the 12 empty video sockets; `makewolf.py` writes them (`mk2wolf_video_rom_uNNN`), `makevrom.py WOLF_EXTRA_BLOCKS` accepts packs there | `make_wolf_video_pattern.py --extra` + `wolf_video_hi_check.lua`: mk2wolf.exe 12,288/12,288, stock MAME 52/12,288 (the control) |
| W03 | `cpumeter` (MPROC.ASM): lines per process pass; `run_runtime_budget.py` reports it | three fights: **4.0 / 6.2 / 10.3 %** of the frame, worst pass 76 / 196 / 102 lines |
| W04 | `stckst` `0117FFF0h` -> `013F72F0h` | `check_stack_clearance.py`: `.bss` headroom **355,306 bytes** (was ~31 KB); T-unit boots and fights, `illop_count` 0 |
| W05 | The 12 character endings on Wolf: `data/ENDWOLF.LOD` (image bank 2, CPU `04400000h`), `zipped_pics` 16h-2Dh, retail's `show_a0_ending` + text under `.if wunit`, `MKSTORY1/2` in `WSTORY.LOD`; TEST MENU -> UTILITIES -> CHARACTER ENDINGS | Kung Lao and Jax (first and last rows) played end to end in mk2wolf.exe: both frames, both backgrounds, all captions, then the cast; `illop_count` 0 |

**W03 corrects this document's own estimate.** Finding 6 and section 4.3
guessed a fight's process pass at about three quarters of the frame, from the
idle poll's raster range. The meter says 4-10%. The poll's range includes the
DISPLAY INTERRUPT (object lists, DMA feeding), which runs before the pass is
released and is most of the frame. So game logic has a lot of CPU to spare;
display work does not, and `dmaq_late`/`peak_overload` remain the measures of
that.

**And the display interrupt is now measured too** (2026-10-12; dirq, the
shadow block and the blitter's drain point - [PERFORMANCE.md](PERFORMANCE.md)
section 3b).  Display interrupt 48-93 lines of 289 in the three test fights,
shadows 6-7, logic 12-30; the blitter's queue empties at 54-73% of the frame
on average, 83% at the Tower's worst.  **The blitter is the tight budget, and
the CPU is idle for well over half of every fight frame.**  The same meters
read in the same range on the Wolf build.

**Every stage measured, both boards** ([PERFORMANCE.md](PERFORMANCE.md) 3c):
all have 54+ lines of blitter headroom except KAHN'S ARENA (17-23), and that
is its heat haze - ~90 lines of CPU and ~100 of blitter a frame, by A/B.

Space after this: Wolf program ROM **81,856** bytes free (the ending text and
code took ~10 KB); u113..u110 holds DSRT and the endings (512 KB used); the
endings slot is reserved at linear `1480000h-1500000h`.

Evidence labels, as in the T-unit audit:

- **Measured** - counted from this tree's build outputs or run in MAME.
- **Source** - read from code (ours, MAME's, or another Midway game's), not run.
- **Proposed** - a mechanism the sources support, not built.
- **Conditional** - depends on a real Wolf board; MAME does not model it.

## Findings that change the plan

1. **The Wolf blitter IS the T-unit blitter.** In MAME, `midwunit_video_device`
   subclasses `midtunit_video_device` and uses the same `dma_w` and the same
   templated `dma_draw`. It charges the same 41 ns per programmed pixel, has
   the same 32,768-entry palette and the same VRAM. The display timing is the
   same too: htotal 506, vtotal 289, 54.7068 Hz. There is no Wolf-only
   blitter feature to find. Every frame-time verdict in the T-unit audit
   carries over unchanged. That includes the closed ones: partition merging
   never pays (row 06), nothing is CPU-bound (row 12), and retained-page
   rendering has no target (row 26). **Source.**
2. **What Wolf adds is memory, not mechanism.** More video ROM; a CPU window
   that reaches all of image ROM in four 8 MB banks; program ROM freed of the
   REVX pool; three times the CMOS. Also a write-to-ROM interrupt, a serial
   PIC, and connectors for extra controls. **Source + measured.**
3. **Video ROM is already the first Wolf budget to tighten.** The u118-u121
   block, the one most Wolf content went into, has **754,472 bytes** left
   (largest run 268,246). Everything stock MAME loads now has **4.79 MB**
   free, down from the 8.05 MB in WOLF_SPACE.md on 2026-10-06. Wolf program
   ROM is down from 210,546 to **92,288 bytes**. **Measured.**
4. **A latent Wolf bug: the colour-map plane is SYSCTRL bit 11 there, not bit
   5.** `pal_rect` and `cpu_patch` (MKDISP.ASM) select the map plane with
   `andni objpalet` (bit 5). On Wolf the game runs SYSCTRL at `1880h`, where
   bit 5 is already clear, so the mask does nothing. Their "selector" writes
   would land in the PIXEL plane, overwriting colour indices. Nothing arms
   either effect today, so nothing is broken yet. WOLF_UNIT.md lists this as
   "untested on Wolf"; it is now answered from source (section 4.1).
   **Source, two independent.**
5. **The other Wolf games use less of the hardware than this tree does.** MK3
   and WWF WrestleMania (the two Wolf games with source on this machine)
   reference vertical flip, constant colour, scaling, the clip window,
   `PIXBLT` and `LINE` less often than our MK2 (table in section 3). They add
   *techniques*, not mechanisms: WWF's random-block screen dissolve and box
   wipes, its write-to-ROM bug trap, and MK3's image-ROM movies (already
   ported for the VS portraits). **Source.**
6. **On both boards, ~320 KB of main RAM is never used.** RAM is 512 KB
   (`1000000h-13FFFFFh`, tested at power-up). `.bss` ends at 157 KB and the
   stack top is fixed at `0117FFF0h`, so `.bss` has only ~31 KB of headroom
   under `check_stack_clearance.py`'s 8 KB guard. **Measured.**

## 1. Scope and sources

What was read:

- **MAME 0.287** (`Workplace/mame-src`): `midway/midtunit_v.cpp/.h` (both
  boards' video), `midwunit.cpp`, `midwunit_m.cpp`, `midtunit.cpp`,
  `midway/midwayic.cpp` (PIC), `shared/dcs.cpp`.
- **MK3 rev 2.1 arcade source** (`Workplace/mk3-rebuild-main/.../REV21`, 233
  files): Midway's own Wolf build of the engine MK2 grew into.
- **WWF WrestleMania arcade source** (`Workplace/wwf-wrestlemania`, 388 ASM
  files): a different Midway team's Wolf game. Its `SYS.EQU` documents the
  Wolf SYSCTRL bits by name.
- **This tree**: `src/`, `makevrom.py`, `makewolf.py`, `tmp/wolf/src/mk2.map`
  (the Wolf link of 2026-10-11 17:59), and the existing audits.

The other Wolf games in MAME are NHL Open Ice, NBA Hangtime and Maximum
Hangtime, and Rampage World Tour. None has source here, so what this
document says about them comes only from MAME's driver notes.

The Saturn/console UMK3 C tree (`Workplace/UltimateMortalKombat3`) is not
arcade code and was not used.

## 2. The two boards side by side

| | T-unit (MK2) | Wolf (MK3/UMK3) | evidence |
|---|---|---|---|
| CPU | TMS34010, 50 MHz | same | MAME both |
| 34010 pixel clock | 4 MHz (screen 8 MHz) | 8 MHz | MAME; affects only CRTC register units, the picture is identical (WOLF_UNIT.md) |
| Blitter | DMA2 | **same code path** | `midwunit_video_device : midtunit_video_device` |
| DMA cost model | 41 ns x programmed w x h | same | `midtunit_v.cpp` `dma_w` |
| Palette | 32,768 x xRGB555 | same, at `01880000h` | MAME both |
| VRAM | 512 x 512 x (8-bit index + 8-bit map) | same | MAME both |
| Main RAM | 512 KB | 512 KB | MAME maps; `ramcheck` `1000000h-13FFFF0h` |
| Video ROM | 12 MB | 20 MB in MAME, 32 MB of sockets | WOLF_SPACE.md |
| CPU reads image ROM | `02000000h-07FFFFFFh`, two 4 MB halves, bit 7 moves the low half by 8 MB | `02000000h-06FFFFFFh`, bank = SYSCTRL bits 8-9 x 8 MB | `midtunit_gfxrom_r` / `midwunit_gfxrom_r` |
| Program ROM | 1 MB, ~200 KB of it the REVX pool | 1 MB, no REVX pool | WOLF_SPACE.md |
| CMOS window | `0x2000` words | **`0x6000` words** | MAME maps |
| DMA registers | `01A80000h` | `01A00000h` (MAME mirrors `01A80000h`) | MAME |
| Map-plane select | SYSCTRL bit 5 (`objpalet`), clear = map plane | **SYSCTRL bit 11 (`PALENB`)**, clear = map plane | section 4.1 |
| Write-to-ROM trap | none | interrupt on EXT2, SYSCTRL bits 12-13 | WWF `SYS.EQU`, `MAIN.ASM` |
| Security | none | serial PIC: serial number + date code; optional RTC wiring | `midwayic.cpp` |
| Sound | DCS 2K, 6 x 512 KB | DCS 8K (8K words external SRAM), 8 x 1 MB sockets | `dcs.cpp`, WOLF_SPACE.md |
| Extra controls | - | P9-P12 connectors (4-player games use them) | MAME board notes |

**Wolf SYSCTRL, from WWF's `SYS.EQU` (`.if WWFUNIT`) and MAME's
`midwunit_control_w`:**

| bit | name | use |
|---|---|---|
| 4 | `AUTOERAS` | auto-erase enable (0) |
| 6-7 | - | CMOS page |
| 8-9 | `IROMPG0-3` | image ROM bank the CPU window shows |
| 10 | `LEDON` | board LED |
| 11 | `PALENB` | 1 = pixel plane (normal), 0 = colour-map plane |
| 12 | `WROMINTDIS` | 1 = write-to-ROM interrupt off |
| 13 | `WROMINTCLR` | toggle to clear a pending write-to-ROM interrupt |

Ours (and MK3's) `syscinit` on Wolf is `1880h`: bits 7, 11 and 12. That is
the pixel plane, with the ROM trap disabled.

## 3. What the other Wolf games use, against us

Non-comment references per source tree. These count lines, not uses, so treat
them as order-of-magnitude:

| feature | MK2 (ours) | MK3 | WWF |
|---|---:|---:|---:|
| DMA vertical flip | 44 | 13 | 17 |
| DMA constant colour (`dmacz/cnz/cal`, `dmaconst`) | 57 | 39 | 25 |
| DMA / object scale | 76 | 25 | 16 |
| DMA clip window | 24 | 10 | 6 |
| `dpytap` | 19 | 0 | 0 |
| `PIXBLT` | 15 | 2 | 1 |
| `FILL` | 39 | 12 | 9 |
| `LINE` | 202 | 33 | 39 |
| `PIXT` | 14 | 6 | 7 |
| `MPYS/MPYU` | 90 | 48 | 163 |

This tree has explored the 34010 and the blitter further than Midway did on
either game: [UNUSED_GRAPHICS_PRIMITIVES.md](UNUSED_GRAPHICS_PRIMITIVES.md) and
[UNUSED_HARDWARE_EFFECTS.md](UNUSED_HARDWARE_EFFECTS.md) built most of them. So
the other games are a source of techniques and of board facts, not of new
instructions. What they have that we do not:

- **WWF's screen transitions** (`SCREEN.ASM`, Jake Simpson): `BLOW_0_TO_1`, a
  random-block dissolve from the hidden page to the shown one, and
  `OPEN/CLOSE_SCREEN_BOX`. Section 4.6.
- **WWF's write-to-ROM interrupt handler** (`MAIN.ASM wrom_int`): locks up
  in a debug build and audits the error in a shipping one. Section 4.9.
- **WWF writes the DMA window per frame** (`DISPLAY.ASM`): the window is
  `[253,0]` or `[509,256]` by page. MK2 sets it once in `init_dma_window`
  and builds per-band clipping on top (`strip_layer`), so there is nothing
  to adopt.
- **MK3's image-ROM movies** (`UNZIP.ASM`, `sysctrl` bank around the
  unpack): already ported, as the Wolf VS portraits.
- **Two DMA behaviours seen in the sports games**, from MAME's notes only.
  NBA Hangtime / Open Ice run the left/right skip register with command bit
  6 clear: one 16-bit skip instead of two 8-bit ones. Open Ice and Rampage
  read DMA register 0 for status. Neither does anything for MK2. Section 4.11.
- **The animated crowd and the ropes** (WWF `CROWD.ASM`, `ROPES.ASM`):
  scripted background-object animation and segmented rope objects.
  MK2's stages already animate background objects (THE THRONE ROOM's Shang,
  the Courtyard monks), so neither is new mechanism.

## 4. Opportunity map

**P1** = a focused first step. **P2** = needs a content or engine decision.
**P3** = conditional, real-board-only, or likely not worth it.

| ID | Opportunity | Budget | Board | Priority |
|---|---|---|---|---|
| W01 | Per-board map-plane bit, so `pal_rect` / `cpu_patch` work on Wolf | correctness | Wolf | **done** |
| W02 | Load u114-u117 and u102-u109 in `mk2wolf.exe`: +12 MB testable | video ROM | Wolf | **done** |
| W03 | Measure CPU idle per frame | CPU (visibility) | both | **done** |
| W04 | Move `stckst` up: ~31 KB -> ~350 KB of `.bss` headroom | RAM | both | **done** |
| W05 | Retired endings back as image-ROM movies | video ROM | Wolf | **done** |
| W06 | WWF-style dissolve and box-wipe transitions | CPU in transitions | both (needs W01 on Wolf) | P2 |
| W07 | Image ROM as a CPU data store (tables, text, LUTs) | program ROM | Wolf | **measured: ~20-25 KB at best, not built** (4.7) |
| W08 | CPU effects that read a sprite's own pixels | CPU | Wolf (T-unit conditional) | P3 |
| W09 | Write-to-ROM interrupt as a debug trap | debugging | Wolf, real board | P3 |
| W10 | Persistent data in the larger CMOS | CMOS | Wolf | P3 |
| W11 | 16-bit skip mode / DMA status read | DMA | both | closed |
| W12 | DMA config high byte ("zero detect", "extra page", "destination size") | DMA | real board | closed (conditional) |
| W13 | Spend ROM to save frame time | DMA | both | closed - measured |

### 4.1 W01 - the map-plane bit on Wolf

**Two independent sources agree, and our code disagrees with both:**

- WWF's `SYS.EQU` names Wolf SYSCTRL bit 11 `PALENB ; Enable Color Palette`.
  `COPY_ARRAY` (`SCREEN.ASM`) clears it to READ a VRAM word's colour-map
  byte into `DMACMAP`, then sets it again to copy the pixel. That is exactly
  `cpu_patch`'s "read the selector from the map plane and hand it back
  through `dmacmap`" trick, done on Wolf with bit 11.
- MAME's `midwunit_control_w` sets `m_videobank_select = (control >> 11) &
  1`. The T-unit's uses bit 5. `midtunit_vram_r/_w` switch planes on it,
  with the same polarity on both boards: clear = map plane.

`src/MKDISP.ASM` masks `objpalet` (`20h`) at `pal_rect` (`andni
objpalet,a1`) and `cpu_patch` (`andni objpalet,a9`). The Wolf `syscinit` is
`1880h`, so bit 5 is already 0 and the "map plane" value equals the pixel-plane
value. Every selector write would land on the colour indices instead.

**Fix (proposed):** a per-board equate in SYSEQU.ASM beside `syscinit`, e.g.
`mapplane .equ 0800h` under `.if wunit`, `20h` otherwise, and use it at
those sites. Retarget the WOLF_UNIT.md open item at a rig: run `pal_rect`'s
identity table on Wolf and require 0 changed pixels. That is the same test
PALRECT_PROTOTYPE.md used on the T-unit.

### 4.2 W02 - the rest of the video sockets

Measured today, from `makevrom.py`'s `wolf_irw_files` and `WOLF_RESERVED`:

| block | sockets | MAME `umk3` loads | used | free | largest run |
|---|---|---|---:|---:|---:|
| `0xC00000-0xFFFFFF` | u121-u118 | yes | 3,439,832 | **754,472** | 268,246 |
| `0x1000000-0x13FFFFF` | u117-u114 | **no** | 0 | 4,194,304 | 4,194,304 |
| `0x1400000-0x17FFFFF` | u113-u110 | yes | 150,366 | **4,043,938** | 3,960,796 |
| `0x1800000-0x1FFFFFF` | u109-u102 | **no** | 0 | 8,388,608 | 8,388,608 |

`tools/mame_wolf/umk3_u6u9.patch` already widens `umk3`'s SOUND region for
the spare sound sockets. The same patch can add `ROM_LOAD32_BYTE` lines for
the eight missing video chips, giving **+12 MB** testable in `mk2wolf.exe`,
which testers already need for the audio. The DMA reaches those addresses
(`run_wolf_vrom_reach_test.ps1` passed at +16 MB and +23 MB), so this is
packaging only. Two traps already known: LOAD2 refuses load addresses
`>= 8000000h`, so anything at linear `0x1400000` and up needs `WOLF_RELOCATE`
as JADE'S DESERT did; and an IMG past ~2 MB hangs LOAD2.

### 4.3 W03 - measure the CPU budget

Nothing measures CPU idle time per frame. The only figures are an overrun meter
(`peak_overload`: 2 = the pass fit) and the note in MPROC.ASM that the idle
poll only ever sees raster lines 203-273. That puts a fight's process pass at
roughly three quarters of the frame, **an estimate, not a measurement**.
A write-only counter incremented in `prcwtsrt`'s wait loop and latched per
tick would give a real figure, in the same shape as `peak_overload` and
`deep_dmaq`. W06 and W08 spend CPU and should not be built without it.

### 4.4 W04 - the unused RAM (both boards)

- RAM: `1000000h-13FFFFFh`, 512 KB. `ramcheck` tests all of it at power-up
  on both boards (DIAGDTST.ASM `sramchips`).
- `.bss`: `1000000h` to `end` = `011322C0h` on the Wolf link (156,760
  bytes) and `01131330h` on the T-unit's (156,262).
- Stack top: `stckst .set 0117FFF0h` (SYSEQU.ASM), growing down.
- Nothing addresses `01180000h-013FFFFFh`: a search for constants in that
  range in `src/` finds only DIAGDTST's RAM-test bounds.

`.bss` headroom under the 8 KB stack guard is ~31 KB, and every pool lives
in `.bss` (objects 358, processes 168, the 500-cell DMA queue). Moving
`stckst` to `013FFFF0h` gives `.bss` ~350 KB, at the cost of re-checking
three places:
- `check_stack_clearance.py`;
- the power-up clear `clscrach`, which clears through `end`, not the stack;
- `stckst`'s comment.

It also makes room for W06's page-copy tables (WWF keeps its dissolve's
randomised block lists in `.bss`: `ARRAYS`, 256 x 16 x 80 bits = 40 KB) and for
CPU-side buffers.

### 4.5 W05 - the retired endings, as image-ROM movies

All 12 character endings were retired on 2026-08-11 to buy ROM (the asset
ledger's largest reclaim): 166,876 bytes of video ROM plus 195,330 of REVX
program ROM. On Wolf the second half no longer has to be program ROM. The VS
portraits already prove the path: REVX frames placed in image ROM and read
by the CPU through a bank (`movie_run` / `vs_base`). The ~362 KB fits easily
in u113-u110. Needed: the frames, `movie_run`'s bank test widened to the new
slot (WOLF_SPACE.md), and the ending code back under `.if wunit`. This is a
content decision, not a technical one.

### 4.6 W06 - WWF's screen transitions

`BLOW_0_TO_1` (WWF `SCREEN.ASM`) works like this:
1. Turn page flipping off and draw the new screen into the hidden page.
2. Copy it onto the shown page in 2-pixel blocks, in a shuffled order, over
   about 60 ticks.
3. For each block, copy the colour-map byte (with `PALENB` clear) as well as
   the pixel, so every block keeps its palette.

The box open/close wipes in the same file are simpler.

MK2 already double-buffers the same way: page 1 at line 256,
`dpystrt0`/`dpystrt1` in MKINIT.ASM. It already has the word-level map-plane
copy, as `cpu_patch`. Cost estimate from `cpu_patch`'s measured ~0.011 lines
per word: a full 400x254 screen is ~50,800 words, about 560 lines, or two
frames of CPU spread across the transition. That is acceptable between
screens, where nothing else runs (T-unit audit row 12: every overrun the game
has is already a transition). On Wolf it needs W01 first.

### 4.7 W07 - image ROM as a CPU data store

The Wolf CPU can read every byte of image ROM: an 8 MB window, banked by
SYSCTRL bits 8-9 (WOLF_SPACE.md measured banks 0-2). Program ROM is the
tighter Wolf budget now: 92 KB, against megabytes of image ROM. Large
read-only data could live in image ROM and be read with the bank selected:
- text;
- lookup tables;
- animation tables, perhaps;
- a Wolf-only fighter's strike or frame tables.

Two rules carry over from `movie_run`:
- Select the bank, read, then put bank 0 back.
- Never do it from an interrupt that can land mid-read. The display
  interrupt reads image ROM through the DMA, not the CPU window, so this is
  about other CPU readers.

**Executing code from image ROM** works in MAME, since instruction fetch goes
through the same read handler. It is **untested on a board** and has no
precedent in either Wolf source. Leave it alone unless program ROM runs out.

**W07 measured (2026-10-12): mostly blocked by the engine, ~20-25 KB at best.**
Two designs were checked against the code, and neither gives the multi-fighter
gain estimated above.

- *Change the default image bank, put the data there.*  `tools/wolf_irom_tap.lua`
  (rides `wolf_boot_probe.lua`; a MAME read tap over 02000000h-06FFFFFFh,
  logging each reading PC and bank) found exactly two kinds of CPU reader of
  image ROM through attract, select, VS and a fight: `movie_run` (which picks
  its bank itself) and the shadow code at FF8016E0, which walks compressed
  sprite rows of **bank-0** fighter art in every fight.  A different default
  bank breaks every stock fighter's shadow.
- *Copy the data to RAM at power-up and run it there.*  Blocked by how the
  engine TYPES pointers by address.  `frame_a9` (MKUTIL) treats a NEGATIVE
  script entry as a frame and a positive one as a command - program ROM
  (FF8xxxxx) is negative, RAM and the image window are positive - and `ani`
  rejects an image header below `rom` (`badani`); the box overlay calls any
  `oimg` in 01000000h-013FFFFFh multipart RAM; the dispatcher drops a process
  whose resume PC is below ROM.  So frame lists and sprite headers MUST stay in
  program ROM; only code and lane scripts could move.  In the Wolf fighters'
  lane modules the scripts and frame lists share one `.text` (Sonya ~10 KB,
  Sindel ~8 KB, Kano ~5 KB) and the move modules are ~3-4 KB of code each, so
  the movable total is ~20-25 KB - about one more fighter - for running
  fighter code from RAM, a dispatcher change and three generator changes.
  **Not built.**

Side check, closed: Wolf-only fighters' art is in DMA bank 1 above 12 MB, which
the CPU window in bank 0 does not reach, so a CPU walk of THEIR rows would read
the wrong bytes.  The same tap with Sonya, Sindel and Kano as player 1: the CPU
never reads their art (their shadows take the path where the DMA walks the
rows); the only fight-time reads are 85-170 of one bank-0 record.

### 4.8 W08 - effects that read a sprite's own pixels

With the art readable by the CPU, an effect can be built from a sprite's own
pixels instead of new art. Examples:
- a dissolve or burn-away that writes a shrinking subset of a fighter's
  pixels;
- a shatter that copies blocks of it to moving positions.

Cost is CPU per pixel, the same order as `cpu_patch`, so only small
regions per frame (UNUSED_GRAPHICS_PRIMITIVES.md, the CPU patch notes).
MAME's T-unit driver also maps a CPU window onto image ROM (bit 7,
`set_gfx_rom_large(true)` for `mk2`), but no T-unit code here uses it and it
is unconfirmed on a real T-unit board (section 6). Hence Wolf-first.

### 4.9 W09 - the write-to-ROM trap (real board only)

Wolf raises an interrupt (EXT2, `TRAP 2`) when anything writes to code or
image ROM. WWF wires it: debug builds `LOCKUP`, shipping builds clear it
(toggle bit 13) and log `CALLERR 9`. Their startup clears a pending one left
by the debugger. A stray pointer write is exactly the class of bug this tree
keeps meeting, from the `.bss`-in-the-stack bug to the `ermac` hangs.

MAME does not emulate the trap: nothing in `midwunit*` reads bits 12-13.
So it is only useful on real hardware, and only as a debug-build option
(`syscinit` with bit 12 clear, plus a handler in the vector table).

### 4.10 W10 - the larger CMOS

The Wolf CMOS window in MAME is three times the T-unit's (`0x6000` words
against `0x2000`). MK2's CMOS layout is the T-unit's; Wolf-only persistent data
could use the rest: per-fighter win records, more audits, the earned-fighter
mask's neighbours. Two things to check first: the layout of a REAL Wolf
board's CMOS chip (MAME's window size is not proof of the part), and the
page bits (SYSCTRL 6-7) the code already uses.

The serial PIC returns a board serial number and a date code
(`midwayic.cpp`); the RTC is "optional" wiring, so not something to rely on.

### 4.11 W11 / W12 - DMA modes and config bits: closed

- **The 16-bit skip** (command bit 6 clear: one 16-bit skip instead of a
  start byte and an end byte) is how NBA Hangtime / Open Ice drive the left/right skip
  register. MK2 always uses the byte pair. The pair already covers MK2's
  widest clip (Smoke's rope, `ofset` against a 317-px record) and nothing
  needs more. Closed.
- **Status from register 0** (Open Ice, Rampage) is MAME mapping reg 0 to
  reg 1. Nothing to use.
- **DMA config bits beyond bit 5.** MAME's register notes name a "zero
  detect byte" (bits 8-15), "extra page" (8) and "destination size" (4).
  MK3 calls bit 4 a "timing parameter" (`dmacf4`). **MAME implements only
  bit 5** (the clip-register select). Both MK3 and MK2 set
  `dmaywin|dmacf4`, and WWF writes `30h` with the comment `check
  this!!!!!!!!!!`. No Midway Wolf source sets the high byte. A non-zero
  transparent index or a faster timing mode might exist on the board, but
  none of it can be tested in MAME. Closed unless someone has a board.

### 4.12 W13 - spend ROM to save frame time: closed, measured

With ROM cheap, it is tempting to pre-render instead of compute, e.g.
merging multipart frames into single blits. The T-unit audit already
measured this on the cost model the Wolf shares. PARTITION_SCAN.md covers
2,468 multipart frames at 41 ns per programmed pixel plus ~280 px per blit:
**merging never pays**, and merging everything would cost +1.39 MB of ROM.
Frame time is not the constraint in any case: the pass fits its tick on 99.2%
of frames and the DMA queue peaks at 224/500 in fights (T-unit audit rows
10 and 12). Wolf ROM buys **content**, not speed.

## 5. What does not change on Wolf

Everything in the T-unit audit's opportunity map that is about frame time,
pools or the blitter applies as written, including the closed rows (06, 07, 09,
11, 12, 25, 26, 27). The storage rows (02-05, 17, 30, 31) saved T-unit bytes.
On Wolf they do no harm, and nothing is gained by undoing them. The prototype
effects (`strip_layer`, `span_pass`, `reflect_p1p2`, `geo_layer`, ghost
trails) use only shared hardware and run on Wolf as they do on the T-unit. The
exceptions are `pal_rect` and `cpu_patch`, which need W01.

## 6. Corrections to carry forward

- **WOLF_SPACE.md "video free now 8.05 MB" and "program headroom 210,546"**
  are 2026-10-06 numbers. Today: 4.79 MB in the blocks MAME loads, and
  92,288 bytes of program ROM (`tmp/wolf/src/mk2.map`: `.data` ends at flat
  `0xE94EC` against `burnfix.PAD_START*2` = `0xFFD6C`).
- **WOLF_UNIT.md "`sysctrl` bit 5 (`objpalet`) ... untested on Wolf"** -
  it is not bit 5 on Wolf at all (W01).
- **WOLF_SPACE.md says the T-unit VS portraits had to sit in program ROM
  "where the T-unit CPU can read them"**. MAME's `mk2` driver gives the
  T-unit CPU a read window onto image ROM (`midtunit_gfxrom_r`, bit 7 bank,
  `set_gfx_rom_large(true)`). Whether a real T-unit board decodes it is open;
  Midway's choice suggests not, or not usefully. Do not build on it without a
  board.
- **GRAPHICS_OPPORTUNITIES.md row 27 "144 KB headroom"** is stale for the
  T-unit (8,416 bytes now).

## Sources

- `Workplace/mame-src/src/mame/midway/midtunit_v.cpp`: `dma_w` (register
  notes, `register_map`, 41 ns timer), `midtunit_control_w` (bits 5, 7),
  `midwunit_control_w` (bits 8-9, 11), both `gfxrom_r` windows.
- `.../midwunit.cpp`: memory map, board layout notes (sockets, P9-P12, 54.5 Hz
  measured), `GAME` list. `.../midwunit_m.cpp`: `io_r/io_w`, PIC, CMOS.
  `.../midwayic.cpp`: serial PIC date code, optional RTC. `.../shared/dcs.cpp`:
  DCS 8K memory map.
- `Workplace/wwf-wrestlemania/SYS.EQU` (Wolf SYSCTRL bits), `SCREEN.ASM`
  (`BLOW_0_TO_1`, `COPY_ARRAY`, box wipes), `MAIN.ASM` (`DIRQ` page flip,
  `wrom_int`), `DISPLAY.ASM` (per-frame DMA window).
- `Workplace/mk3-rebuild-main/mk3-rebuild-main/REV21/SYSEQU.ASM` (Wolf DMA
  register map, `dmacf4`, `syscinit 1880h` and the "thanks wwf guys" note),
  `MKINIT.ASM` (`init_dma_window`).
- This tree: `src/MKDISP.ASM` (`pal_rect`, `cpu_patch`), `src/SYSEQU.ASM`
  (`syscinit`, `stckst`), `src/MPROC.ASM` (idle poll note), `src/DIAGDTST.ASM`
  (`sramchips`), `makevrom.py` (`wolf_irw_files`, `WOLF_RESERVED`,
  `WOLF_RELOCATE`), `makewolf.py`, `tmp/wolf/src/mk2.map`,
  `doc/ASSET_SPACE_LEDGER.md` (endings), `doc/graphics_opportunities/PARTITION_SCAN.md`,
  `BUDGET_AUDIT.md`.
