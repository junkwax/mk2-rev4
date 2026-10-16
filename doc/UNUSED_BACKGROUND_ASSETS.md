# Unused Background Asset Inventory

This is a focused pass over BLIMP background modules that exist in the data tables but are not installed by the live `src/BGND.ASM` stage setup.

Method:

- Parse each `.BDB` module list.
- Compare module labels (`<module>BMOD`) against active, non-commented references in `src/BGND.ASM`.
- Check whether the `.BDD` contains image records that are not referenced by the `.BDB`.
- Render suspicious BMODs for visual identification.

## Dead Pool / NUPOOL

Source files:

- `data/DEDPOOL.BDB`
- `data/DEDPOOL.BDD`
- `data/NUPOOL.BDB`
- `data/NUPOOL.BDD`

Current live stage:

- `src/BGND.ASM` `dedpool_mod`
- Active BMODs: `DPUL5BMOD`, `DPUL2BMOD`, `DPUL3BMOD`, `DPUL4BMOD`, `DPUL6BMOD`
- Inactive BMODs: `DPUL1BMOD`

### `DPUL6BMOD`

Status: restored in `src/BGND.ASM` as `baklst6`.

Evidence:

- Exported in `src/BGNDTBL.GLO`
- Defined in `src/BGNDTBL.ASM`
- Referenced by `src/BGND.ASM` `dedpool_mod`
- Preview: `tmp/dpul6bmod.png`

Rendered preview shows vertical backing panels. This is very likely the sky/glow art that should sit behind the Dead Pool wall vents.

Generated BMOD dimensions:

```text
DPUL6BMOD: 802 x 181, 12 blocks
```

Restore path used:

- Added `DPUL6BMOD` after the existing Dead Pool planes so it occupies `baklst6`.
- Centered it alongside `DPUL5BMOD` via the `center_x` list.
- Gave it the same scroll rate as the wall plane.
- Drew `baklst6` before `baklst1` in `dlists_dedpool`, so the panels sit behind the wall/vents.
- Shifted it down 16 pixels (`-058h` to `-048h`) to better align with the vent openings.
- Repointed the Dead Pool `OLPALS` sky slots to `DPOOLSKY2_P` / `DPOOLSKY3_P` / `DPOOLSKY1_P`, brighter light-blue remaps of the original `DUSK*_P` palettes. This keeps the same pixel-index ordering so the restored vent backing does not turn into scrambled-looking colors.

### `DPUL1BMOD`

Status: compiled/exported and partially wired in comments.

Evidence in `dedpool_mod`:

```asm
	.long	skip_bakmod			; baklst2 = skip
;	.long	DPUL1BMOD
;	.word	-610,000h
```

The display list also has the matching layer commented:

```asm
;	.long	baklst2,worldtlx2+16
```

Generated BMOD dimensions:

```text
DPUL1BMOD: 2364 x 460, 14 blocks
```

Preview: `tmp/dpul1bmod.png`

This looks like sparse chain/foreground line art rather than the orange vent backing.

### Dead Pool Pixel Usage

`DEDPOOL.BDD` has no unreferenced image records:

```text
DEDPOOL images: 49
Referenced by BDB: 49
Unreferenced: 0
```

So the Dead Pool unused content is not loose unused pixels inside the BDD. It is full compiled BMOD planes that the runtime stage setup skips.

## Wasteland / BATTLE

Source files:

- `data/BATTLE.BDB`
- `data/BATTLE.BDD`
- `data/BATTLE.IMG`

Current live stage:

- `src/BGND.ASM` `battle_mod`
- Active BMODs: `BAT7BMOD`, `BAT6BMOD`, `BAT5BMOD`, `BAT4BMOD`, `BAT2BMOD`, `BAT1BMOD`

Findings:

```text
BATTLE images: 19
Referenced by BDB: 19
Unreferenced: 0
```

All six BATTLE modules are active in `battle_mod`, and all BDD image records are referenced by the BDB. The full render shows extra foreground statues/rocks, but in the current source they are not a skipped BMOD; they are already part of the active Wasteland module stack.

If those elements are not visible in-game, the next thing to inspect is runtime viewport/scroll positioning, not missing LOAD2 content.

Preview:

```text
tmp/battle_full.png
```

## Tower / TOWER2 / CASTLE

Source files:

- `data/TOWER2.BDB`
- `data/TOWER2.BDD`
- `data/CASTLE.IMG`

Current live stage:

- `src/BGND.ASM` `tower_mod`
- Active BMODs: `PLANE4BMOD`, `PLANE5BMOD`

Findings:

```text
TOWER2 images: 13
Referenced by BDB: 13
Unreferenced: 0
```

`src/BGND.ASM` still contains a commented hook for a missing statue layer:

```asm
;	.long	PLANE3BMOD			; baklst3 = statues
;	.word	(1120-705)/2,00eh
```

But the current asset set does not contain that module:

- No `PLANE3BMOD` export in `src/BGNDTBL.GLO`.
- No `PLANE3BMOD` definition in `src/BGNDTBL.ASM`.
- `data/TOWER2.BDB` only declares `PLANE4` and `PLANE5`.
- `mk2-src.zip` only contains the same `TOWER2.BDB` / `TOWER2.BDD`; no older `TOWER.BDB` asset was found in the archive.

Correction: the missing `PLANE3BMOD` background module is not present in
`TOWER2.BDB` / `TOWER2.BDD`, but the statue/pillar source art does exist in
`data/CASTLE.IMG`. That file is currently completely unused by the LOD build:

```text
CASTLE.IMG: 85 total records, 0 exported, 85 unused
```

Relevant records seen in `CASTLE.IMG`:

- `STATUE1`, `STATUE2`, `STATUE3`, `STATUE4`
- `mock1`
- `STATREF1a`, `STATREF1b`
- `STATREF2a`, `STATREF2b`
- `STATREF3a`, `STATREF3b`
- `STATREF4a`, `STATREF4b`
- `stref1`, `stref2`, `stref3`, `stref4`
- `PILLAR`, `PILREF`, `pillref`
- `FlameA1` through `FlameD4`
- `BKGW1`, `BKGW2`, `DECO1`, `DECO2`, `DWALL1` through `DWALL5`

Direct record-table parse shows the useful Tower statue block:

```text
idx  name       size      anix  aniy  pal  data
02   STWALL_vda 133x175      0     0   17  0x012db0
03   STATUE1     76x218     76     0    4  0x018aa8
04   STATUE2     68x195     68     0    4  0x01cb60
05   STATUE3     61x174     61     0    4  0x01ff2c
06   STATUE4     53x153     53     0    4  0x022aac
07   LKSTANCE4   70x132     29    -9    5  0x024c24
08   mock1      221x252    221     0    7  0x027144
```

`mock1` appears to be the setup/reference composite for the statue group. Use it
as the visual guide for where `STATUE1` through `STATUE4` belong on the Tower
stage. `LKSTANCE4` sitting next to it is probably a scale/reference sprite.

So the Tower "four statues/pillars" content is present, but not as a ready-made
BLIMP module. The old runtime hook expects a `PLANE3BMOD`, while the recoverable
art is WIMP/IMG-style chunk data. There are two possible restore paths:

1. Reconstruct a BLIMP/BDB plane from the CASTLE pieces, compile it with `BBB>`,
   and wire it into the old `PLANE3BMOD` slot.
2. Compile only the needed CASTLE records with `ASM>` and spawn the statues as
   background animation objects in `calla_tower`, similar to how Dead Pool
   hangers are spawned from `MKHANG.IMG`.

Path 2 is probably faster and safer for first proof, because it avoids inventing
a new BDB module and only needs table headers plus Tower placement code.

Preview:

```text
tmp/tower2_full.png
```

### DONE 2026-09-01 — path 1, as `TOWER2_SEL`

THE TOWER's background is `data/TWRSIDE.BDB` / `.BDD` now, not `TOWER2`:
stock TOWER2 with `STATUE1`-`STATUE4` appended and a third module,
`TOWER2_SEL0`, carrying all four mirrored into a receding row on each side of
the arch. LOAD2 truncates module labels to 10 chars (`headct`, `ldbgnd2.c`), so
that emits `TOWER2_SELBLKS` / `TOWER2_SELBMOD` — the names the leaked
`src/BGNDTBL.GLO` already exported, which is what the module was called before
it was cut.

- `data/MK7MIL.LOD` — `BBB> TWRSIDE` in place of `BBB> TOWER2`. The BDB's own
  header line still reads `TOWER2`, so `R2HDRS`/`R2PALS` and
  `PLANE4BMOD`/`PLANE5BMOD` keep their retail names and nothing else moved.
- `src/BGND.ASM` `tower_mod` — `baklst3` was `skip_bakmod` with Midway's hook
  commented out above it; it is `TOWER2_SELBMOD` at world `331,14` now. `14` is
  Midway's own y from that hook. `331` centres the 460-wide module on world
  x 561, where PLANE4's pillars and PLANE5's arch already centre.
- `src/BGNDPAL.ASM` — `R2PALS` grew a fourth slot, `STATUE`. That palette label
  was already in the file at 39 entries (a stale dev-snapshot copy, referenced
  by nothing); the BDD's is 58 and the art uses index 57, so the short one
  would have run off the end. Nothing in the build promotes a BDD palette into
  `BGNDPAL.ASM` — see the note in `data/IMGBUILD.BAT` about the new
  `BGNDPAL.MK7` snapshot, which is what makes the hand-paste checkable.
- `data/HICLOUD.LOD` + `makevrom.py` — the four guards add ~43KB of BDD pixel
  data, MK7MIL's payload ran 25,304 bytes into HICLOUD's slot, so HICLOUD moved
  from the bottom of that free run (`0x3E80000`) to the top of it
  (`0x3F70000`). MK7MIL keeps ~98KB to grow into.
- `src/BGNDTBL.ASM` — dead `TERRA1BLKS`/`TERRA1BMOD` removed. They were an
  earlier two-STATUE1 pass at this same plane, wired to nothing, and their
  `hdr` index 13 ran off the end of the 13-entry `R2HDRS`.

Layout and guards: `python tools/twrside_statue_layout.py` (`--apply` to write
the BDB, `--check` in Phase D). It also diffs TWRSIDE's stock half against
`data/TOWER2.BDB`/`.BDD`, which `check_stock_bg_assets.py` cannot do for a
stage with no `mk2-readonly` counterpart — TOWER2 stays pinned there as the
reference even though it is no longer in the LOD.

Three things BDDTool cannot show, all of which bit this:

1. **A block joins the first module whose box contains it.** The guards were
   first dropped at canvas y 424, inside `PLANE4`'s box, so two of them became
   pillars — and PLANE4's origin, which LOAD2 re-crops to the leftmost member,
   moved from x 536 to 460 and slid all four retail pillars 76px. Everything
   is authored below y 640 now, clear of both stock boxes.
2. **Blocks in a module are found by binary search on x** (`bsrch1stxb`,
   `BAKGND.ASM`), so records must be sorted ascending by canvas x or the later
   ones are never added to the display list.
3. **Draw order inside a baklst is the z byte, and it runs the way you would
   not guess.** `insobj_v` keeps the list ascending in `ozval` and queues the
   head first, so the LOWEST z is at the back. A receding row needs the
   nearest guard on the HIGHEST z. The first build had this backwards and drew
   each smaller guard on top of the bigger one beside it.

`tools/stage_preview.py` renders any stage the way the game composes it —
per-plane modules, per-plane parallax from the scroll table, `dlists_` order,
and the same z sort — so a layout can be checked without a build. It is
verified against `tools/tower_stage_probe.lua`, which forces a match onto THE
TOWER (`curback = 3`), parks the camera at each scroll limit, and dumps every
plane's `worldtlx` plus every background object's position.

## Other Background Modules Worth Revisiting

The same scan found additional unreferenced BLIMP modules outside the three stages above:

- `COMESOON.BDB`: `comesoon`
- `FOREST.BDB`: `wood3`
- `KUNGFU1.BDB`: `WOKWAY1`, `WOKWAY2`, `WOKWAY3`
- `KUNGFU2.BDB`: `ARENA1`, `ARENA7`, `ARENA8`, `CLOUDZ`
- `KUNGFU4.BDB`: `wokway0b` through `wokway6b`
- `MOON.BDB`: `port1` through `port4`
- `MKSTORY3.BDB`: `STORY3`

These need per-stage interpretation before restoring; some are retired attract/story content rather than cut live arena layers.
