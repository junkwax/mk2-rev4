# BDD / Stage Loading Constraints

Reference for what MK2's background system can and cannot do. Sources: `doc/load2/`, `src/BGNDEQU.H`, `src/PAL.H`, `src/DISPEQU.ASM`, `src/SYSEQU.ASM`, `src/BGND.ASM`.

---

## LOAD2 Hard Limits (enforced with fatal errors)

These are compile-time caps inside LOAD2 (`doc/load2/ldbgnd2.c`, `load2.h`). Exceeding any of them aborts the build.

| Limit | Value | Meaning |
|-------|-------|---------|
| `MAXPALS` | 256 | Palettes per single LOD/BDB file |
| `TOTPALS` | 512 | Total palettes across all files in one LOAD2 run |
| `MAXDATA` | 65,500 bytes | Pixel data per block (`maxdata` in load2.h) |
| `MAXMODS` | 100 | Module entries per file |
| `MAXBLOCKS` | 2,500 | Total blocks across all modules |
| `MAXHDRS` | 400 | Header entries per file |
| `MAXBLKTBLS` | 500 | Block-table entries |
| `MAXHDRTBLS` | 50 | Header-table entries |
| `MAXSAG` | (system) | SAG table size — overflow causes linker errors, not LOAD2 errors |

**Practical ceiling**: a single BDB/BDD pair should stay under ~200 palettes and ~2,000 blocks to leave headroom for other LODs in the same LOAD2 run.

---

## Pixel Format

| Property | Value |
|----------|-------|
| Color format | 5R 5G 5B packed into a 16-bit word (bit 15 unused) |
| BPP range | 1–8 bpp (LOAD2 auto-selects; no manual override) |
| Transparency | Palette index 0 = transparent (standard convention) |
| Palette size | 2^bpp entries × 16-bit words |

The BPP is determined per-block by LOAD2 based on the actual color count. You cannot force a specific BPP; reduce the unique color count to get a lower BPP.

---

## Display System Constraints (runtime)

From `src/DISPEQU.ASM` and `src/SYSEQU.ASM`:

| Property | Value | Source |
|----------|-------|--------|
| Screen resolution | 400 × 254 pixels | `DISPEQU.ASM` |
| Refresh rate | 54.7068 Hz | T-Unit hardware (18.28ms per tick) |
| Color depth | 8-bit indexed (256 colors on screen) | CRAM layout |
| Background planes | 8 | `BGND.ASM` `num_bgplanes` |
| Max live objects | 358 (`nobj`) | `DISPEQU.ASM` |
| Display list size | Fixed — shared pool | `DISPEQU.ASM` |

The 358-object pool is **shared** between background tiles, characters, effects, and UI. A busy fight scene with blood effects and special moves can exhaust this budget. Keep stage tile object counts low.

---

## Palette System (runtime)

From `src/PAL.H` and `src/BGND.ASM`:

| Property | Value | Source |
|----------|-------|--------|
| Simultaneous palettes | 16 (`NUM_PALETTES`) | `PAL.H` |
| Palette queue slots | 32 (`PALQ_MAX_ENTRY`) | `PAL.H` |
| CRAM base | `0x01800000` | `SYSEQU.ASM` |
| Palette entry size | 256 × 16-bit words = 512 bytes | |

Only 16 palettes can be active in CRAM at once. The queue allows up to 32 pending load requests, but they serialize through CRAM. A stage that uses more than ~12 distinct palettes risks crowding out character palettes during a fight.

**Character palette budget**: each fighter typically uses 2–4 palettes (normal, hit-flash, shadow, alternate). With 2 players + effects, plan for at least 10 slots reserved at all times, leaving ~6 for the stage.

---

## DMA / Block Constraints

| Property | Value | Notes |
|----------|-------|-------|
| Zero-run compression | Min 10 pixels | Shorter runs not compressed — `MAXDATA` still applies |
| Block alignment | Word-aligned (16-bit boundary) | DMA requirement |
| Max block pixel data | 65,500 bytes | `MAXDATA` in LOAD2 |
| Block dimensions | No explicit max | Practical limit: `MAXDATA` bytes at chosen BPP |

At 8 bpp (1 byte/pixel), `MAXDATA` = 65,500 pixel bytes → max ~255×256 block. At 4 bpp, max ~510×256. For large panoramic tiles, split across multiple blocks.

---

## BDB / BDD File Structure

| Term | Meaning |
|------|---------|
| `.BDD` | The block PIXEL data: a count line, then per block a `<hex id> <w> <h> …` header line followed by `w*h` raw bytes |
| `.BDB` | The LAYOUT: a stage header line, one line per module (`<name> <x1> <x2> <y1> <y2>`), then one placement record per block (`<z><flags> <x> <y> <hex block id> <palette>`) |
| Block | One rectangular region of pixel data with a single palette |
| Header (OLHDR) | References one or more blocks; placed by the stage layout |
| Module | Named group of blocks (one sprite/tile set) |

The two are joined by the block id, and the BDD is the one that costs ROM:
LOAD2 emits every block it holds, placed or not. A block whose BDB record has
been deleted is an orphan that still ships — see "Splitting a floor out of the
.BDD into sprites" below.

The `.bak` and `.autobak` variants in `data/` are BDDTool auto-save files — they are not loaded by LOAD2.

---

## Stage Background Layout

From `src/BGNDEQU.H` and `src/BGND.ASM`:

- Backgrounds are built from OLHDR records stacked across 8 planes.
- Plane 0 is farthest back (sky/distant); plane 7 is closest (floor, foreground objects).
- Scrolling parallax: each plane has an independent X scroll speed multiplier.
- The `curback` RAM variable (16-bit) selects the active stage (0-indexed, matches BGNDTBL.ASM order).

### Stage-select index (curback)
Read straight off `table_o_mods` (BGND.ASM) and `txt_bg*` (MKSEL.ASM), which
are the two halves of the same index. **This list used to be wrong** — it was
in select-screen order, not `table_o_mods` order, which sends anything forcing
`curback` to the wrong stage (THE TOWER is 3, not 5).

```
 0 (00h) = THE DEAD POOL    dedpool_mod
 1 (01h) = KOMBAT TOMB      tomb_mod
 2 (02h) = WASTELAND        battle_mod
 3 (03h) = THE TOWER        tower_mod
 4 (04h) = LIVING FOREST    forest_mod
 5 (05h) = THE ARMORY       armory_mod
 6 (06h) = THE PIT II       bridge_mod
 7 (07h) = THE PORTAL       port_mod
 8 (08h) = KAHN'S ARENA     arena_mod
 9 (09h) = GORO'S LAIR      mk1_mod
10 (0ah) = THE PIT BOTTOM   mk1pit_mod   (custom)
22 (16h) = Outer Haven      outer_haven_mod (custom)
23 (17h) = Waffle House     flapjack_mod (custom)
24 (18h) = Yoteigai Tor     peak_mod     (custom)
```
Indices are into `table_o_mods` (BGND.ASM), which is the authority; 11..21 are
non-fight modules (team photos, VS, the ladder map, attract, bio, high scores).
A stage is only reachable once it is ALSO in `match_stage_cycle` (MAIN.ASM) and
`vs_stage_cycle` (MKSEL.ASM), and it needs a row in all four curback-indexed
tune tables (`round_1_tunes`, `round_23_tunes`, `finish_tunes`, `winner_tunes`,
MAIN.ASM) plus a name in `background_names`/`txt_bg*` (MKSEL.ASM). Those five
tables are INDEXED, not compared — a stage past the last row reads whatever
follows the table.

---

## Modding Checklist

Before adding a new or modified stage:

- [ ] Palette count ≤ ~6 unique palettes (leave 10 for characters/effects)
- [ ] Each block's pixel data ≤ 65,500 bytes (split large tiles if needed)
- [ ] Total palettes across all LODs in one LOAD2 run ≤ 512 (`TOTPALS`)
- [ ] Palettes per file ≤ 256 (`MAXPALS`)
- [ ] Object count per frame budgeted — test with effects active
- [ ] BPP verified: use BDDTool color count display to confirm auto-selected BPP matches expectation
- [ ] SAGs promoted to `src/BGNDTBL.ASM` after any pixel/palette change (run `python build.py` — Phase B handles this)
- [ ] No `/E` flag in LOAD2 invocation (dual-bank layout breaks sprite SAGs)

---

## Splitting a floor out of the .BDD into sprites

WAFFLE HOUSE's ground plane was nineteen 40-wide BDD blocks; it is six
MKFLOORS.IMG sprites now (`WAFFLEFLOOR1-6`, the `WAFFLR.TBL` section of
`data/FLAPJACK.LOD`), placed by `flapjack_calla` in BGND.ASM. The reason to do
this at all is that a BDD floor is part of a module, so it can only ever have
that module's plane, rate and z; as sprites all three are settable, which is
what makes an independent parallax rate possible.

Three things bite, in the order you hit them:

**1. Deleting the .BDB records frees no ROM.** LOAD2 emits every block in the
.BDD whether or not a .BDB record places it — FLAPJACK's `FLAPHDRS` had 104
entries for 104 blocks with only 85 placed, and the 19 orphans were still
costing 24,412 bytes of the video slot. The .BDD has to lose them too. Block
ids in the BDD's per-block header lines are explicit hex and the BDB
references those ids, so orphans can be deleted without renumbering: LOAD2
regenerates BLKS and HDRS together from what is left.

**2. Hand-placed objects cannot share a plane with a module.** `bgnd_ud1` runs
`disp_del` over every `baklst` that has a module and unlinks anything off the
padded window; `disp_mod` only puts *module blocks* back, so a culled sprite
is gone for the round. MOUNTAIN TOP gets away with it because `peak_calla`'s
lanes are `skip_bakmod`. When all eight planes are spoken for, give the run a
display list of its own — a `dlists` entry is just
`<list head>,<worldtl>` and nothing requires the head to be one of the eight:

```asm
	.bss	flap_floor_lst,32,1
	.global	flap_floor_lst		; a local .bss does NOT reach mk2.map
...
dlists_flapjack
	.long	flap_floor_lst,worldtlx6+16	; drawn first = under everything
```

Zero the head at the top of the `_calla`; the object pool is rebuilt between
stages and a stale head is a list of freed objects.

**3. Cut the art with positional anipoints.** `0, -120, -240, …` with a
constant aniy, the `parallax1-3` convention, so every strip takes the SAME
anchor and `anchor - anipoint` lays the run out. That makes the table the
single source of truth for the layout, so its `.TBL` must be in
`promote_tbls.py` as a COPIED table — a re-cut that moves an anipoint against
a stale table tiles the floor into a staircase.

**4. The stage canvas is taller than the camera ever shows.** FLAPJACK's BDD
is 291 rows; `worldtly` rests at `ceiling_y` (10) and the vertical chase only
ever scrolls UP from there, so the window is world y 10..263 at its lowest.
Art anchored to the bottom of the canvas is partly invisible: the floor first
went in at 238..282 (matching the blocks it replaced) and nineteen of its
forty-five rows were below the screen, which also left a dark gap between the
kerb and the lot. 219..263 puts the art's last row on the screen's last row.
Anchor a floor to the bottom of the WINDOW, not the bottom of the canvas, and
let the excess tuck up behind the scenery — it is drawn first, so anything
above it is covered for free.

Check the result with `python tools/rom_space_report.py` and
`tools/run_waffle_floor_test.ps1`, which drives the camera to both scroll
limits and fails on a gap, a short run, a culled strip, or bare ground beside
OR below the floor. The middle of a stage always looks correct; a short floor
only shows at a limit. `tools/run_waffle_floor_height_preview.ps1` compares
candidate heights in ONE run — `dclipl` draws a background object from
`oyval`, and nothing culls or re-places objects on a private list, so writing
`oyval` moves the floor for real without a rebuild per candidate.
