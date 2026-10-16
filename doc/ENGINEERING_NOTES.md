# Mortal Kombat 2 - Arcade Source Code

Mortal Kombat 2 (1993) by Midway Manufacturing. Lead programmer: Ed Boon.
Written entirely in TMS34010 assembly for the Williams/Midway T-Unit arcade board.

## Architecture

- **CPU**: TMS34010 graphics processor at 50 MHz (160ns cycle)
- **Display**: 400x254 pixels, 8-bit color, **54.7068 Hz** refresh (T-Unit;
  measured from MAME's driver, `refresh_attoseconds` = 18,279,250,000,000,000)
- **Memory map**: ROM at 0xFF800000, Image ROM at 0x02000000, CMOS at 0x01400000, Screen at 0x00000000
- **Sound**: Separate sound board, communicated via IRQ and port writes
- **Input**: JAMMA standard ? joystick + 6 buttons per player

## Build System

**Status: full source rebuild works.** Program + video + sound ROMs all built from source, running in MAME. Verified against retail L3.1.

Tools are 16-bit DOS executables in `tools/` ? DOSBox Staging runs them (DOSBox 0.74 also works; DOSBox-X does not).

### Full pipeline (from repo root)

```
python build.py && python makerom.py && python makevrom.py && python makesound.py && python mamerom.py --source-video
```

Step by step:
```
python build.py       # Step 1: Phases A?D ? LOAD2 + table promoters + assemble + sanity check
python makerom.py     # Step 2: mk2.out + MK8MIL.IRW ? rom/mk2_uj12.bin + mk2_ug12.bin
python makevrom.py    # Step 3: MK2MIL-MK7MIL.IRW ? 12 video ROM chips (rom/*.ug14..uj22)
python makesound.py   # Step 4: sound/stlaugh_patch.txt + clips ? sound/mk2_stlaugh.zip (custom audio)
python mamerom.py --source-video   # Step 5: merge sound ? C:\MAME\roms\mk2.zip
```

**Custom audio note:** the custom sound *streams* (STLAUGH, Jade Flash/protect,
boomerang whoosh, nitro kick, etc.) live in `sound/mk2_stlaugh.zip`, built by
`makesound.py` (DCSEncoder) from `sound/stlaugh_patch.txt`. The custom sound
*triggers* are ASM in `src/` and compile with `build.py` automatically. Steps
1-3 do NOT regenerate the sound zip, so **after editing `stlaugh_patch.txt` or
any source clip, re-run `makesound.py`** (or the full pipeline). `mamerom.py`
prints a loud WARNING if the zip is older than the patch inputs, and
`makesound.py --check` exits non-zero if it's stale - so a forgotten re-encode
is caught, not shipped silently. `makesound.py` also refuses a build that
spills into a phantom U8 chip (reclaim more dead audio if that happens).

**IMPORTANT: never pass an explicit zip path (e.g. `"mk2.zip"`) as `mamerom.py`'s
positional sound-source argument unless you deliberately want retail sound.**
Omit it - `mamerom.py` with no positional argument automatically prefers
`sound/mk2_stlaugh.zip` (the patched set with all custom audio: STLAUGH, Jade
Flash, etc.) when present, falling back to retail only if it doesn't exist.
An explicit path used to silently win over the patched set (this exact
recipe used to say `mamerom.py "mk2.zip" --source-video`, which reverted
every custom sound patch on every run) - `mamerom.py` now ignores an explicit
retail-looking zip in favor of the patched set unless
`--allow-retail-sound` is also passed, but the safest habit is to just never
pass a zip path here at all.

### Step 1: Code build (build.py)
`build.py` orchestrates four phases. `--asm-only` skips A+B (image rebuild) and runs C+D only.

- **Phase A0b** ? `tools/check_img_names.py --check`: duplicate record/palette NAMES in the IMG libraries, against `doc/img_names.lock`. Runs BEFORE LOAD2, because a duplicate name silently repacks a record and ships a sprite in the wrong palette's colours with a green build
- **Phase A** ? `dosbox_load2.conf`: LOAD2 ? `data/*.IRW` raw image data + `tmp/load2/*.TBL` snapshots
- **Phase B** ? Python table promoters (run sequentially):
  - B1 `promote_tbls.py` ? per-character TBLs from LOAD2 snapshot ? `src/`
  - B2 `promote_bgndtbl_stock_records.py` ? BGNDTBL BLKS/BMOD placement records
  - B2a `promote_bgndtbl_stock_sags.py` ? labeled BGNDTBL SAG headers (28)
  - B2b `sync_bgndtbl_sags.py` ? anonymous inline SAG values (~500+)
  - B2c `refresh_kfpitbg.py` - MK1PIT/KFPITPL background table from BGNDTBL.KFP
  - B2d `refresh_kfpitbg.py` ? KFPit background from `BGNDTBL.KFP` snapshot
- **Phase C1** - `tools/gspa_stage.py`: every out-of-date module is assembled in a STAGE (`tmp/asmstage`) with its own MAINEQU pruned to the `.global`s it (and its includes) names. GSPA pays for every global it is handed and its PASS 2 "Out of memory" is NOT monotonic near the edge (two new lines in MOVES failed where sixteen copies of them passed); pruning took MOVES' measured headroom from ~100-250 extra labels to 512+, for EVERY module, and defuses MAINEQU's own cliff (a new global costs only the modules that name it). `gspa_stage.py --verify` rebuilds all 107 modules staged and requires `mk2.out` byte-identical but for the COFF timestamp (it is). A module that fails pruned for any non-memory reason is retried with the full MAINEQU; one that still fails is left to GMAKE, unpruned. `makewolf.py` uses it too. `MK2_GSPA_STAGE=0` turns it off. **An aborted GSPA leaves `src/MCY*`/`MCZ*` temp macro libraries that break the NEXT assembly** ("unable to open temp macro library" on an unrelated file) - the stage deletes them
- **Phase C** ? `dosbox_asm.conf`: `gmake -m` in `src/` ? `src/mk2.out` (COFF) - links, and assembles whatever Phase C1 did not
  - GMAKE rule: `GSPA $* -H -v10` per file; GSPLNK links via `src/mk2.cmd`; entry point `POWERUP`
  - Assembler flags: `-H` (hex prefix), `-v10` (v6.10 mode). **No `-L`: the build writes no listings**, and
    any `src/*.LST` lying around is stale. `mk2.out` is stripped and objects keep only globals, so the only
    complete label->address table is a listing - `tools/art_ref_graph.py --assemble` makes one in a scratch
    tree and proves it byte-identical to the build
- **Phase D** ? sanity check: re-runs all promoters in `--check` mode; fails build if anything drifted

Output logs: `build.log` (assembler + linker), `data/IMGBUILD.LOG` (LOAD2 verbose).

### Step 1b: Image build (IMGBUILD.BAT)
LOAD2 processes 7 LOD files to produce IRW raw image data. Per Asure's exact recipe:

```batch
load2 MK2MIL /Di /Fi /T=C:\TMP\LOAD2 /X /V
```

- `/Di` ? LOD file uses IMGDIR env var
- `/Fi` ? raw IRW file output to IMGDIR
- `/T=path` ? table files to throwaway dir (we keep the restored originals in src/)
- `/X` ? don't download to GSP hardware
- `/V` ? verbose
- `/E` ? dual-bank. **Used by every video-ROM LOD**: 97 of the 100 `load2` lines in
  `data/IMGBUILD.BAT` pass it, `MK2MIL` included, and it has been that way for a long while
  (96 of 99 at the 2026-09-27 HEAD). This line used to say **DO NOT USE** `/E`
  ("dual-bank ? wrong sprite layout!") and that was stale enough to mislead: a new sidecar
  step looks like a bug against it when it is in fact consistent with the whole file.
  The one LIVE exception is `MK8MIL`, which is deliberate ? it is the REVX advertisement
  payload that `makerom.py` embeds in the **program** ROM at 0xA0000, not a video-ROM LOD,
  so "fixing" it for consistency would change the REVX layout. (The other two without `/E`,
  `STCUT` and `HKBFIST`, are commented out.) Rule as practised: **`/E` on every video-ROM
  LOD; the one program-ROM payload does not take it.**
- **DO NOT USE**: `/A` (append ? breaks per-LOD runs), `/B`

Each LOD runs standalone (no `/A`). LOD files have `c:\video\kombat2\img\` prefixes stripped so `/Di` resolves IMG names via IMGDIR. Run `python _strip_lod_paths.py` once to prepare LOD files (idempotent).

### Step 2: Program ROM (makerom.py)
Converts `src/mk2.out` COFF to interleaved program ROM. Reads sections from the COFF (.text, .data, FLOORORG, SHADORG, VECTORS), embeds `data/MK8MIL.IRW` (REVX advertisement) at offset 0xA0000, byte-interleaves into 2 lanes:
- `rom/mk2_uj12.bin` ? 512KB, even bytes
- `rom/mk2_ug12.bin` ? 512KB, odd bytes
- `rom/mk2_flat.bin` ? 1MB flat ROM for analysis

TMS34010 uses **bit addresses** ? all sizes/vaddrs in COFF are in bits (divide by 8 for byte offsets).

### Step 3: Video ROMs (makevrom.py)
Reads 6 IRW files, embeds their pixel data in a 12MB buffer at offsets derived from each IRW's base address. 4-way byte-interleaves into 12 ROM chips (ug14/uj14/ug19/uj19 ? 3 groups).

Bank placement (MK2-MK5 first 8MB, MK6-MK7 last 4MB) uses filename-based fallback since LOAD2 without `/E` writes `bank=0xFFFF` (undefined).

```
python makevrom.py              # 12 MAME-named chips to rom/
python makevrom.py --debug-bin  # + per-IRW raw .bin + flat 12MB ROM for MAME loadr
```

MAME debug `loadr` example (test sprite changes without repackaging):
```
loadr rom/debug/mk2mil.bin,0,200000,:gfxrom;loadr rom/debug/mk3mil.bin,200000,200000,:gfxrom;g
```

Region name may be `:gfxrom`, `:gfx1`, or `:video` depending on MAME version ? check `help loadr`.

### Step 4: MAME packaging (mamerom.py)
```
python mamerom.py                                      # our program+video ROMs + sound/mk2_stlaugh.zip
                                                        # (patched: STLAUGH/Jade Flash/etc.) if it exists,
                                                        # else rom/mk2_retail.zip, else full source-built sound
python mamerom.py --source-video                       # same, explicit about using our video ROMs
python mamerom.py --output rom/custom.zip              # write to specific path
python mamerom.py --no-install                         # build zip, don't copy to MAME
python mamerom.py path/to/some.zip --allow-retail-sound # deliberately force a specific/retail sound source
```

**Never pass a zip path here unless you deliberately want to override the sound
source** - see the warning above. Recommended: no arguments (implies
`--source-video` automatically whenever a sound zip is selected) ? our LOAD2
build matches retail video ROMs byte-for-byte (0 CRC warnings on 12 video
chips). Installs to `C:\MAME\roms\mk2.zip` unless `--no-install`. MAME warns
about program ROM CRC mismatches (expected ? built from source). Listen for
the **single "bong"** at boot ? that's the internal checksum passing.

### Step 5 (hardware only): burn set (burnfix.py)
For EPROMs going into a real T-unit. **There is no security check left to
bypass** - `secbust_proc` (MAIN.ASM:3409) is a bare `die` stub because the
security process was never in the leak, and `sec_random_trash` /
`post_sec_trash` (DIAGMENU.ASM:6085/6138) have no callers. The only boot gate
is the power-on ROM self test, `romcheck` (DIAGDTST.ASM:1852), which sums every
byte of a chip and compares the low 16 bits against constants linked into the
program ROM: `cksum1`/`cksum2` (DIAGDTST.ASM:4014) for uj12/ug12 and the
`iromchips` records (DIAGDTST.ASM:4078) for the 12 video chips. Those constants
are a dev-snapshot leftover and our art has diverged from retail, so **all 14
chips report BAD** unless they are resynced.

```
python burnfix.py                 # self-guiding: sync table, or finalise + verify
python burnfix.py sync-video      # real video sums -> src/DIAGDTST.ASM iromchips
python burnfix.py fix-program     # force uj12/ug12 sums, emit rom/burn/
python burnfix.py verify          # check all 14 chips against the linked constants
```

Full flow (the table lives in the program ROM, so it needs one extra pass):
```
python build.py && python makerom.py && python makevrom.py
python burnfix.py                            # patches DIAGDTST.ASM, asks for a rebuild
python build.py --asm-only && python makerom.py
python burnfix.py                            # emits rom/burn/ + MANIFEST.txt, verifies
```

`fix-program` lands each program lane on its target sum by trimming filler in
the dead 0xFF tail at per-lane `0x7FEB6-0x7FFB8` (below `crc_spoof`'s window at
`0x7FFBC`); it aborts if the program ROM ever grows into that region.

**Burn `rom/burn/*.bin`, never the ROMs inside `mk2.zip`** - `mamerom.py` runs
`crc_spoof.spoof_zip()`, which rewrites 4 bytes of each program chip's tail
padding for FBNeo's CRC table and invalidates the internal checksum.

Two DIP switches decide whether any of this is exercised (MAME's names). They
look like they disagree with `DIPEQU.ASM` and do not: **there are two bit
orders**. `read_dip` (DIAGDTST.ASM:2669) swaps the two bytes, inverts, then
reverses the bits within each byte, so a raw mask `1 << n` becomes
`1 << (15-n)` in `DIPEQU.ASM`'s equates. Code that reads `@dipswitch` directly
(`romcheck`, `get_irom_mode`, the mid-game TEST-switch probe) uses MAME's raw
masks; everything that goes through `read_dip` uses the DIPEQU ones. Both are
correct - check which read you are looking at before "fixing" either:
- **Powerup Test** (mask 0x0200, default Off) - Off takes the bypass at
  DIAGDTST.ASM:783 and skips the self test entirely (boot is ~10s faster). On
  runs it, and that is when these checksums matter.
- **Circuit Boards** (mask 0x0100, default 1) - picks `iromchips` (12 masked
  ROMs, one board) via `get_irom_mode`; the other setting checks
  `iromchipsnew`, a daughterboard layout that isn't there.

### Key files
| File | Purpose |
|------|---------|
| `build.py` | Full build (Phases A-D); `--asm-only` skips Phase A LOAD2, then runs table promotion/sync before assembly |
| `build_all.py` | Dual-ROM build ? `rom/mk2_test.zip` + `rom/mk2_retail.zip` in one command |
| `makerom.py` | COFF ? program ROMs (step 2) |
| `makevrom.py` | IRW ? video ROMs (step 3); `--debug-bin` adds flat bins for MAME `loadr` |
| `mamerom.py` | Package ? mk2.zip (step 4); `--source-video`, `--output`, `--no-install` |
| `burnfix.py` | Real-hardware burn set (step 5) ? resync power-on ROM checksums, emit `rom/burn/` |
| `mk2_test.lua` | MAME Lua helper ? hotkeys to kill P2 HP, snap distance, dump state, replay inputs |
| `tools/make_rain_img.py` | Build `data/RAIN.IMG` from the six MK3 rain frames it carries as ASCII art; `--check` in Phase D, `--dump` to view |
| `tools/run_floor_skip_probe.py` | Measure how many floor rows a stage could stop drawing, by pinning `@skew_skip` to the whole band on the real machine and diffing the frames. THE TOWER (54) is the built-in control. `tools/floor_skip_audit.py --check` is the source-only Phase D guard that its coverage basis still exists |
| `tools/art_identity_snapshot.py` | Decode + hash every sprite record's PIXELS out of the packed video ROM, so a repack or deletion can be proved: `--write` a baseline, rebuild, `--compare`. A SAG moving is not evidence - it is the thing that moved |
| `tools/art_ref_graph.py` | Which packed sprite records the game can actually draw - the mechanical replacement for hand dead-art audits. Works from the BUILT ROM: `--assemble` makes listings in a scratch tree (`.include`->`.copy`), proves every section byte-identical to the build, and rebuilds the label table the stripped `mk2.out` lacks. Pointers are relocated fields only (a constant never has a relocation), reachability flows from code through data lists that stop at `0` / `ani_jump`, and hand-carried headers read their anchored windows. Classes: LIVE, WINDOW (pixels read by another header - `ROTATE10B/C`), AUTHORED (undrawn frame of a partly-drawn IMG sequence - `KHEART1`), DEAD. `--dead`, `--explain LABEL`, `--root DIR` for any build; the summary's `integrity` line must say 0 relocated fields outside a label or DEAD is unsafe. `--census DIR` fails if anything it rules out was drawn at runtime. See `doc/graphics_opportunities/ART_REF_GRAPH.md` |
| `tools/make_arnsky_bin.py` | KAHN'S ARENA's sky (`arena6BMOD`, 15 blocks, two palettes) composited into `data/ARNSKY.BIN`, a raw 6bpp texture, plus `src/ARNSKYEQ.ASM`, for `sky_rows` (MKDISP.ASM) to draw one scanline at a time - the per-line heat haze that moves only the sky. Honours the block H-flip bit (z `0x10`) and the runtime list order; `--check` in Phase D. `tools/arena_haze_test.lua` proves lines at offset 0 equal the plain blocks to the pixel. See `doc/graphics_opportunities/ARENA_HAZE.md` |
| `tools/sag_census.lua` | Every SAG the DMA was told to draw, by write-tapping `dmasagl`/`dmasagh` and committing on `dmactrl` - so backgrounds, floors and HUD count, not just objects. Rides along with any driver rig (`SC_TARGET`, `SC_ROOT`, `SC_OUT`); the runtime check for `art_ref_graph.py --census` |
| `tools/check_img_names.py` | Duplicate record / palette NAMES inside the IMG libraries the build reads. LOAD2 resolves a LOD's `---> NAME` by NAME and takes the **LAST** match, so a second record with the same name silently repacks the first - and `promote_tbls` patches a record's SAG and control word but KEEPS its `.long <palette>` line, so the sprite ships in another palette's colours with a green build. `PPP> 0` can pick the same depth for both (identical control word) and every index can still be in range, so nothing draws out of bounds either: it is a correct-looking picture in the wrong colours. Five times in `data/MKBOXES.IMG` alone, the last one (Scorpion's select box, 2026-09-23) found by a player. The tree carries 103 collisions in Midway's own art, so this BASELINES them into `doc/img_names.lock` and fails on drift: `--check` is Phase A0b (**before** LOAD2 runs), `--write` re-baselines, `--img <stem>` narrows. Accepting a new duplicate is a deliberate `--write` |
| `tools/fix_load2_bit_bleed.py` | LOAD2 ORs stray bits into the last rows of some compressed records, and which pixels it hits depends on where the record lands, so a record can change every time art before it grows or shrinks (`JXSPLIT9A` has been 1, 2 and 4 px wrong). For each record in its `REPAIRS` list this decodes the stored pixels from the IRW, compares them with the authored IMG and rewrites only the differing pixel values - refusing on a size mismatch, a bad row header, another record inside the range, or more than 16 differences. Phase B2e2 `--apply`, Phase D `--check` |
| `tools/make_stonecrk_img.py` | Shao Kahn's stone-crack frames 1, 2 and 4-7 as the plain statue plus crack-only overlay patches: writes `data/STONECRK.IMG` from `data/BOSS7.IMG`, proving each base+patch composite equals the original piece before it writes (`--check` in Phase D). `STONEBASEA` must stay the first piece of frame 1, because `make_kahn_obj` (MKFX.ASM) takes the palette off it. MKSK records are added and removed by hand, because `sync_mksk_mk5.py` only rewrites records that already exist. See `doc/graphics_opportunities/MULTIPART_SHARE_SCAN.md` |
| `tools/restore_tigerjump.py` | Kintaro's stomp art, back at the size Midway drew it. `a_goro_stomp` draws the A-D STRIPS of `TIGERJUMP1-6`, and the strips of frames 1-4 had been SHRUNK in this tree (0.8 on 1-3, 0.64 on 4) when the small arena prop `SMTIGERJUMP1-4` was authored into the same `TIGER3.IMG`; `src/MKGORO.TBL` was then re-cut to match the shrunken art, so every piece of metadata agreed with every other and he simply dropped on Shang Tsung two thirds his fight size. This restores the 15 strips - pixels AND geometry - from the read-only tree, appending the retail pixels and repointing the records so nothing else in the IMG moves (`SMTIGERJUMP` included). `--check` in Phase D. Restored they no longer fit MK4MIL, so six live in `data/TIGJMP1-6.LOD`; **anchor a pack at the BOTTOM of its hole and round the base UP past the payload below**, and size a tight slot off a real LOAD2 run - estimating the packed size from the IMG runs 3-14% low. It is also a gameplay change: the hurt box is computed from the sprite, so `doc/hurtbox.lock` was regenerated. See [doc/KINTARO_STOMP_ART.md](doc/KINTARO_STOMP_ART.md) |
| `tools/run_kahn_stone_capture.py` | Plays a one-player game into a forced CPU Shao Kahn, wins 2-0, and captures his turn-to-stone ending frame by frame on two ROMs (`--old`/`--new`), comparing captures by animation frame. It arms on `dlists_bogus` (the ending's black background), never on a game state: `gs_gameover` is 0Bh, and 6 is the pre-fight setup |
| `tools/flip_scale_scan.py` | Find video-ROM art that is an exact mirror (H/V/H+V) or exact 2× copy of another record. The DMA flips and scales for free, so those bytes are reclaimable if the consumer draws the kept image flipped. See `doc/graphics_opportunities/FLIPREUSE_PROTOTYPE.md`: a flipped object's edge clip needs its skip bytes swapped AND its x pulled left by both skips |
| `tools/sync_hatgleam_pal.py` | `HATGBL_P` out of `data/HATHED10.IMG` into `src/IMGPAL7.ASM` - the blue ramp KUNG LAO'S VICTORY HAT GLEAM (`TMHATGLEAM1-6`) is drawn in. Nothing promotes an IMG palette into the ROM, so a repaint in IMGTOOL would ship the old colours silently; `--check` in Phase D. Companion `tools/hh_gleam_pixels.py` counts the palette's exact colours in a rig snapshot, so a PASS means the gleam was DRAWN in it and not merely pointing at it |
| `tools/sync_inline_sags.py` | Sprite headers hand-written inside `.ASM` that no promoter touches: MKBABY babality art, MKRD `KLUDGE_*` bolts, and the mirrored aliases (Mileena's arms, `BGBIGFIST1C_MIRROR`, `RNHEAD2/3_MIRROR`, `KAHNBIG1`/`LIL1`). Anchors each to a promoted record plus a bit offset, hash-checked. `--check` runs in Phase D, and also fails if the linked `src/mk2.out` does not carry each header with its anchored SAG - the case where a rewrite left a stale `.OBJ` that DOSBox's clock skew stopped gmake reassembling |
| `tools/check_stack_clearance.py` | The system stack top `stckst` (SYSEQU.ASM) is a fixed address the linker knows nothing about; `.bss` is packed upward past it as it grows. Fails if any module's `.bss` sits in the 8KB under the stack top (`--check` in Phase D). It did on 2026-09-12: MKHANG's variables were in the live stack. Also fails if the power-up clear (`clscrach`, MKINIT.ASM) stops covering `.bss`: it cleared a fixed 01000000..01100000 while `.bss` ran to 0111fb00, leaving 38 variables as garbage on a real board. It now clears through the linker's `end`. `tools/run_clear_test.py` proves that in MAME by seeding RAM and soft-resetting, because MAME zero-fills RAM and a cold boot can't show it |
| `tools/audit_piece_sizes.py` | The measurement behind `ani2`'s guards (`mp_max`/`mp_maxx`/`mp_maxy`, DISPEQU.ASM). Every piece record and every multipart piece list in the build, against the limits `ani2` enforces: widest 330 (MK2MORPH1A), tallest 226 (LKDRAGON10B), longest list 11 (`oh_stair_v6`), a fighter's 8 - it was 26 (Shao Kahn's FPULP5/6/7) until the pulp burst was retired on 2026-09-29, so `mp_max` 32 is now slack rather than measured. `--check` in Phase D, so art that grows past a limit fails the build instead of going silently missing from a frame. It tells piece LISTS from animation SCRIPTS by the `<stem><letter>` naming - GOOBER1..14 is a script and never reaches `ani2` |
| `tools/run_ani2_guard_test.ps1` | Proves the guards turn a lost list terminator from a cabinet reboot into a missing sprite. Waiting for the real thing takes hours, so it INJECTS one: a debugger command points `ani2`'s list pointer at a long run of non-zero `.text` and removes itself. `-Mode inject` PASSes if the game plays on and `@ani2_clip` moved (a pre-fix ROM wedges in `gstate 6` instead); `-Mode clean` PASSes if `@ani2_clip` never moves. Refuses a `rom/mk2.zip` older than `src/mk2.out` - a zip paired with another build's map reads every symbol at the wrong address and reports nothing wrong |
| `tools/char_baseline.py` | THE ART A NEW FIGHTER NEEDS, measured off the nine shipped body families (KANG, CAGE, HATHED, KAT, NINJAS, NUJAX, RAID, TSUNG, UGMO): every sequence (`<XX><SEQ><n>[A-Z]`), its frame count, subframes per frame, the library number it lives in, and how many fighters carry it. Spellings are normalised (`HIKIK`->`HIKICK`, `HITHI`->`HIHIT`, KAT/NINJAS' `1STANCE` variants), and **a sequence is matched by the shared TABLE1 row (00-41h) that draws it**, parsed out of each module: row 22h is the elbow, drawn as `ELBO` by four fighters and as `PALMSTRIKE`/`HEDSWIPE`/`SHORTCUT`/`HEADBOP` by the rest, so name-matching alone left the elbow out. A row is named by plurality (3+ fighters); a stem 5+ fighters carry is never renamed, and nothing overwrites a sequence the fighter already has. Each line shows its TABLE1 row. No args = the baseline (`--share N`, default 5 of 9); `--fighter KANG` one family's own inventory; `--emit KABAL --prefix KB [--template KANG]` writes placeholder `KABAL1-n.IMG` (template size + anipoint, blank, one dot top-right, `KBMAIN_P`) plus `BASELINE.md/.csv` into `tmp/char_baseline/KABAL/`. Not read by the build. Does not tag which are VICTIM poses (HEADHOLE, RIPTORSO...) |
| `tools/rom_space_report.py` | How much ROM space is left, computed from the live build (video banks 0/1 + program-ROM headroom); `--gaps` lists every hole |
| `tools/build_report.py` | One post-build report (`tmp/build_report/report.md`): freshness, whether `rom/mk2.zip` and `C:\MAME\roms\mk2.zip` really hold the current `rom/` chips (ignoring crc_spoof's tail patch), space, the Phase D-style guards, stale `tmp/load2` tables. `--baseline <art json>` adds a decoded-pixel diff; `--write-baseline` saves one. Read-only - run it before installing over another session's build |
| `tools/run_runtime_budget.py` | Runtime pool peaks for that report: `perf_stress.lua` on three pinned busy fights (private windowed MAME), recording objects/processes/blood, the object DMA queue high-water, overflow/late/lost frames, and qdma/palette-queue drops, into `tmp/build_report/runtime.json`. Overload and the late/lost counters are latched from power-on, so transitions are included |
| `tools/run_fatality_budget.py` | Pool peaks DURING finishers, which the fight rig above never sees. Runs existing finisher rigs (toasty, Raiden lift, Kung Lao split, Kahn, the souls) under `tools/fatality_budget_wrap.lua`, which samples every frame: objects/processes in use from the free lists, blood, palette slots, and the ROM high-waters re-latched at the finisher's first frame. The wrapper redirects the rigs' hard-coded repo paths into a frozen copy of `src/` + `tools/`, so they read the map that matches the ROM. See `doc/graphics_opportunities/BUDGET_AUDIT.md` "Fatality peaks". `tools/run_fatality_shadow_ab.py` reuses the same rigs to compare the fast shadow path against the stock loop (`FB_SHADFAST=0`) capture by capture; `FB_TRACE=first-last` adds a per-frame camera/DMA/process trace for chasing a differing frame |
| `tools/stage_preview.py` | Render a BDB/BDD stage the way the GAME composes it — per-plane modules, parallax, `dlists_` order, z sort. BDDTool only shows one flat canvas; this shows the screen |
| `tools/make_mk3cave.py` | THE CAVE (curback 019h, `src/MK3CAVE.ASM`) - MK3's unshipped `MK3CAVE.BDB/.BDD`. The art is too big for any free run, so `--parts` deals its 60 images into four bank-1 packs (`data/MK3CV1-4`), and `--apply` (Phase B2d2) merges the packs' header snapshots back into the four modules in `src/MK3CAVBG.ASM` (header SAGs are absolute, so one module's blocks can live in several slots). The layout lives HERE, not in the ASM; `--preview [camx...]` renders it from the same constants. `--check` in Phase D. Rig: `tools/run_cave_stage_probe.ps1` selects it with a real LEFT tap on the VS screen. See [doc/MK3_CAVE_STAGE.md](doc/MK3_CAVE_STAGE.md) |
| `tools/make_mk1pit.py` | THE PIT (curback 01Ah, `src/MK1PTOP.ASM`) - MK1's whole Pit: bridge, shaft and night sky, with the uppercut fall ridden down the shaft onto the Pit Bottom's spikes (a pan, as MK1 does - no cut). **The fall camera pans SIDEWAYS with the body too** (`mk1p_fall_scroll`, pit_scroll's own x half: centre, 6px deadzone, stop on the scroll limits); `mk1p_hold_on_screen` leans the body back inside screen x 100..300 ONLY when worldtlx is already on a limit. Written from YOTEIGAI TOR's fall, it inherited that one's `stop_scrolling` - right for a stage fatality aimed at a fixed target, wrong here: with the view nailed down, a mid-bridge uppercut threw the body to the edge of the band on its own throw velocity and the hook hauled it back, which reads as the body bouncing off the side of the frame. Move the VIEW before the BODY. Bridge/shaft art is `data/KUNGFU5` minus what MK1PIT already carries, dealt into bank-0/1 packs (`data/MK1PT1-4`); the sky (moon, clouds, rocks, silhouettes) is decoded out of `mk.zip` into `data/MK1PSKY.IMG`/`MK1PFLY.IMG` and dealt into `MK1PSK1-5`/`MK1PFLY`. `--apply` (Phase B2d3) merges the headers into `src/MK1PTOPB.ASM`; `--check` in Phase D; `--preview X,Y...` renders it. Rigs: `tools/run_mk1pit_stage_fatality_test.ps1 -VictimX N`, MK1 reference `tools/run_mk1_pit_capture.ps1`. See [doc/MK1_PIT_STAGE.md](doc/MK1_PIT_STAGE.md) |
| `tools/make_mk1shrine.py` | THE WARRIOR SHRINE (curback 01Bh, `src/MK1WSHR.ASM`) - MK1's statue gallery, `data/KUNGFU1` (NOT KUNGFU4, a daytime Palace Gates). `--check` proves against `mk.zip` that its 242 blocks, 93 images and 12 palettes are MK1's shipped stage, and every layout number (planes, rates, limits, placements) is read off MK1's record `FFCB7160`. Art dealt into bank-0 packs `data/MK1WS1-3` (FLAPJACK's and HANGJOHD's guards); three images reuse THE PIT's SAGs and the moon is THE PIT's `mk1p_moon`. `--apply` is Phase B2d4 (after B2d3 - it reads `src/MK1PTOPB.ASM`). **LOAD2's `PPP> 0` depth ignores a block's LAST pixel** and spills it into the next record - such images go to `MK1WS3` at `PPP> 6` (`wide_tail`). **Parallax (`wshrpar`, MK1WSHR.ASM, on; 0 = MK1's flat stage):** statue row on plane 4 at 7/8 speed, gates on plane 1, floor flat (MK1's) on plane 5. A spreading MK2-style floor (`wshr_floor`, bands redrawn from the floor's own blocks) is built but OFF: `FLOOR_BANDS` in the tool -> `mk1w_fbands`. Every camera is scanned for floor holes in `--check`. DMA time is its budget: a frame that starts with blits pending drops them (`dmaq_late`, HUD first); measure with `tools/run_runtime_budget.py --scenario 1,3,27` and the stage probe's `-Watch wf_lines,wf_short,dmaq_late`. MK1 reference rig `tools/run_mk1_shrine_capture.ps1`. See [doc/MK1_WARRIOR_SHRINE.md](doc/MK1_WARRIOR_SHRINE.md) |
| `tools/make_mk1throne.py` | THE THRONE ROOM (curback 01Ch, `src/MK1THRN.ASM`) - MK1's court of Shang Tsung. **The one MK1 stage with NO .BDB/.BDD anywhere** (THE PIT has KUNGFU5, THE WARRIOR SHRINE KUNGFU1; every BDD in the tree and every `data/*.IMG` was searched BY PIXELS and holds none of it - `data/CASTLE.IMG`'s `THRONE` palette is a 2-entry stub in THE TOWER's workbench), so the tool decodes all 45 images out of `mk.zip` itself and `--check` proves the packed bytes back against them, 45 of 45. Layout is read off MK1's record `FFCB8080` (entry 4; the name table `FFDCC390` runs index for index with the stage table, and entry 7 is the same stage ONE COLUMN short - asserted by what each block RESOLVES to, because the two records have their own header tables so a word-level diff calls every block different). **THE MODULE LIST HAS A `skip_bakmod` IN IT AND A SKIP IS ONLY 32 BITS** (`init_bakmods`, BGND.ASM `ibak3`: 64 bits per module, `addi 32` for a skip; `skip_bakmod .set 1`). THE THRONE ROOM is the only MK1 stage that uses one - 3 modules, `.long 1`, 4 more - so the planes are 1,2,3,(4 skipped),5,6,7,8. Read as a uniform list it looks like a 3-module teal colonnade against a flat sky, and THAT CUT DECODED, PACKED AND RENDERED WITH NO ERROR; what caught it was a MAME capture of MK1 (`tools/run_mk1_throne_capture.ps1`, which logs all nine `worldtlx`). MK1 gives FIVE PAIRS of headers one SAG - one drawing on two palettes - so 40 payloads carry 45 entries. ~62KB dealt over four runs no IRW had claimed (two per bank), so no donor guard was spent. `PACK_MARGIN` 0.90 not 0.96: `ZON>` row headers can make a marginless image bigger than flat. **The scaled scroll delta is FLOORED, not rounded** - `round()` is 1px out on planes 3/6/7 right of the start x and drops a frame diff from 87% to 46%. **SHANG TSUNG SITS ON THE THRONE, WATCHES THE FIGHT AND APPLAUDS WHEN A ROUND IS WON - ONLY A PLAIN WIN: a DRAW leaves `winner_status` 0 and a round that goes to FINISH HIM (3) is never clapped, not even when `play4` writes 1/2 back after the finisher (`mk1t_sh_noclap`; rig `-Finish`). The crowd applauds with him: MK1's own clap clip, `triple_sndtab2` $68 -> track $0118-$011A (stlaugh_patch.txt note (56)), sent once as the clap starts and asserted on the latch by the rig. **It goes out on CHANNEL 3 at `sp_applause` (69h) through `triple_sound2_ch3` (MKSOUND.ASM)**: at `sp_effect` on channel 1/2 the KO sounds refused it or the win line / flawless tone took its channel within 25 ticks, so in play it was never heard - `triple_sound` steals channel 1 first and 3 last, so a long sound that must outlive its neighbours belongs on 3. `-Listen` records the mix and logs every code sent after the decision** (`mk1t_shang`, MK1THRN.ASM; art `data/MK1TRSH.IMG` + MK1TRSH/MK1TRS2 LODs, `--shang`). **WATCHING: HE IS NOT ANIMATING - HE IS LOOKING AT THE CAMERA.** No lane, no timer: every 8 ticks MK1 reads plane 1's camera and picks one of seven poses by `min(|737-camera|/75, 6)`, with `camera <= 212` taking bucket 3 outright. THE PROBE LOG LOOKS LIKE SOMETHING ELSE - holds of 170/184/80/344 ticks arriving f1,f2,f3,f4,f1 read exactly like a random-delay idle, and a fixed lane would have looked right in every screenshot; what settled it was MAME's disassembler plus a STATIONARY-camera probe (a scrolling frame is 1-2px off the worldtlx logged beside it, useless for deciding a plane). **CLAPPING: MK1 keeps a TEN-ENTRY ROUND-END HOOK TABLE at `FFCACF50`, indexed by curback exactly as the stage table is** - `FFCAB280` reads curback and calls the entry; every one is a bare RETS except entries 4 and 7 (the two THRONE ROOM records), which kill the watching process and run the lane at `FFD6EC20` - clap4, clap3, clap2, clap3, looping - at `MOVK 5h` a frame. Measured in a real MK1 win: starts 14 ticks after the round is decided, 5 ticks a frame, ~36 frames, then the watching resumes. **WRITING A HEALTH BAR TO 0 DOES NOT END A ROUND** in either game - a KO is decided when damage is applied; pin the loser at 1 and land a real hit. **I NEARLY SHIPPED WITHOUT THE CLAP**: the first cut stopped walking the data at the piece list the object is BUILT on and missed the three clap poses right after it - the list did not end where I stopped reading. **He is drawn against PLANE 4** - the plane the module list SKIPS, which carries no module but whose worldtlx MK1 still scrolls - so the generator emits all nine rates. Measured: his head template-matches at 1.00 in six parked MK1 frames and plane 4 is the only camera that puts him at world 701 in all six; compositing at each candidate, 4 wins every shot (+5-6 points) and plane 8, the throne's own and the obvious guess, is worse everywhere. **EVERY POSE IS 4 UPPER-BODY SLOTS PLUS THE LAP, NOT A MULTIPART**: the clap changes the whole upper body, so four objects are built once and each one's art swapped with `ani_flag`; a 3-piece pose repeats its last piece (one blit, no blank record, and there is no safe inviso on a single-part object), and EVERY SLOT IS RE-PLACED on a change because only the watching poses share an anipoint per slot. 21 of the 26 records are packed - the arms-open BUILD pose is never seen. Rig `tools/run_mk1throne_shang_test.ps1` (511 samples/0 mismatches/4 buckets/72 clap changes over all 4 steps; `-Negative` 511 of 511 mismatched) recomputes the bucket in Lua and compares the table ROW against `mk1t_sh_shown`, samples ONLY while the camera has been still, and scopes the clap check to the lane's own window. **NO SHADOW CLIP**: `init_bakmods` gives every stage 255/255 and an earlier cut narrowed it to the runner's own 19/25 rows, which CHOPPED the shadow flat against the carpet - measuring a band is only right when there is an edge to fall off. See [doc/MK1_THRONE_ROOM.md](doc/MK1_THRONE_ROOM.md) |
| `tools/make_thrnchair.py` | THE THRONE ROOM's EMPTY THRONE: when either player (human or CPU) is Shang Tsung, `mk1thrn_calla` builds `mk1t_chair` instead of the seated Shang. Packs only the PATCH of `data/MKBGANI.IMG`'s `thrnchair` that he covers, plus MK1's own plane-7 sky holes at the top of the back - decided against ALL 626 on-screen camera views, because plane 5 is the only plane that moves with it (plane 7 drifts ~15px, plane 8 never scrolls; a start-camera-only cut leaked the sky and the base) (3 strips, `data/THRCHP1-3`, in the tails of MK1TRS2/MK1TR1/MK1TR2 - the whole chair is ~9.9KB and no free run holds it). Position is template-matched, not typed; `--check` in Phase D; rig `tools/run_mk1throne_chair_test.ps1 -Mode shang|control`. See [doc/MK1_THRONE_ROOM.md](doc/MK1_THRONE_ROOM.md) "The empty throne" |
| `tools/make_mk1court.py` | THE COURTYARD (curback 01Dh, **Wolf only**, `src/MK1CRT.ASM` under `.if wunit`) - MK1's stage record `FFCBB410` decoded out of `mk.zip` (the leak's KUNGFU2 is a PRE-RELEASE Courtyard). Art goes to the Wolf region (`data/MK1CY1`, monk sprite pack `data/MK1CYM`, linear `0xC00000`+, makevrom `wolf_irw_files`), never the T-unit chips. **The two monk rows are objects, not modules**: MK1's process `FFCBB780` steps them through six frames every 8 ticks, so modules 3/4 are `skip_bakmod` and `mk1c_monks` builds 15 objects on baklst3/4 at the blocks' top-lefts; the rows use DIFFERENT MK1 palettes (far row claims `MK1CYMK4_P`). `--apply` Phase B2d6, `--check` Phase D. **BGND.ASM is at GSPA's ceiling on the Wolf pass**: Wolf stage entries go in ONE `.if wunit` block inside `table_o_mods` (`.globl` + `.long` together; two blocks aborted). **Shang Tsung on his throne is an object too** (MK1's module-6 block 25h, taken out of the module; `mk1c_throne` on `mk1c_th_lst`, plane 6's camera) so the throne is EMPTY when either fighter, human or CPU, is Shang - `MK1CYTHRN` / `MK1CYTHRNE`, both in the monk pack. MK1 has no empty Courtyard throne: `empty_throne()` in the tool PAINTS it from the chair's own posts, arms and reds - this project's art, edit it there. Rig `tools/run_wolf_court_throne.ps1` (3/3, `-Negative` fails). Rig `tools/run_wolf_boot_probe.ps1 -Script wolf_court_check.lua`. See [doc/MK1_COURTYARD_GATES.md](doc/MK1_COURTYARD_GATES.md) |
| `tools/make_mk1gates.py` | PALACE GATES (curback 01Eh, **Wolf only**, `src/MK1GATE.ASM`) - MK1's record `FFCB9ED0` out of `mk.zip`; its module list starts on MK1's PLANE 0, so baklst N carries MK1 plane N-1. MK1 animates any BLOCK whose ID (flag high byte) is 2/3/4 - here the TORCH FLAMES - and MK2's streamer (`disp_del`) deletes anything on a module's baklst that leaves the window, so those blocks and their ID-1 cups come out of the modules onto per-plane lists of their own; every flame frame's position is precomputed from MK1's anchor rule (`FFC80D10`: anix, or w-1-anix flipped). Clouds: ten pieces on plane 8 at half a pixel a tick, wrapped past screen x 399. Higher block z draws IN FRONT (the spear guard 4153h over the wall). `--apply` B2d7, `--check` Phase D, `--expect` for `tools/wolf_gates_check.lua`. See [doc/MK1_COURTYARD_GATES.md](doc/MK1_COURTYARD_GATES.md) |
| `tools/make_umk3lair.py` | SCORPION'S LAIR (curback 01Fh, **Wolf only**, `src/UMK3LAIR.ASM`) - UMK3's hell stage read out of `umk3.zip` with `tools/umk3rom.py` (program ROM at FF800000h; image ROM as MAME's `umk3` lays it out, byte = SAG >> 3). Record `FF952560`, MK3 layout; `center_x` and the skew floor (`FL_HELL`, `skew_7`) carried over - **MK3's `setup_floor_info` adds 02000000h to the floor SAG and works out the floor's y itself**, MK2's record stores it. **The stage fatality rides THE PIT (MK1)'s path**: `check_dtp` takes 1Fh with every fighter's own pit code and `r_fall_down_mk1pit` turns off to `lair_fall_in_lava` (UMK3's `fall_in_lava`, FFAE3220: up off the screen, back SHRUNK at oscale 1C0h with the multipart deltas re-laid, into the lava, HELLHIT1-8). **2026-10-11, made like UMK3's**: he rises until he is OFF the screen (MK2's `distance_from_ground` measures from his top, so UMK3's 100h left his legs hanging in view - "floats there"); the scroller is KILLED for the fatality (`stop_scrolling` only zeroes one tick, and a noscroll body read as a world x dragged the camera to the limit and shook it); the ceiling comes down - UMK3's `subway_rox` (create_fx 29h, FFB400C0): BOOM (MK2's 0A4h - UMK3's two explode streams are 27 KB the Wolf set lacks), shake (A,10h) and 10/8/4 cave rocks from `ground_y - 100h`, each bouncing once and crumbling (pack `data/LAIRRX.LOD`, 5bpp, linear 0xE44000; every number pinned by a `CODE_CHECKS` word); the splash plays UMK3's lava hiss `wsnd_lair_hiss` (tsound 5Fh, appended to `make_wolf_audio.py`'s `UMK3_TAIL`); and the splash is DELETED at the end, not `set_inviso`'d (single-part objects ignore it - it froze on HELLHIT8). The CPU does not take it (MKDRONE is at GSPA's ceiling). `--apply` B2d8, `--check` Phase D; rig `tools/wolf_lair_check.lua`. See [doc/UMK3_SCORPIONS_LAIR.md](doc/UMK3_SCORPIONS_LAIR.md) |
| `tools/make_umk3desert.py` | JADE'S DESERT (curback 020h, **Wolf only**, `src/UMK3DSRT.ASM` under `.if wunit`) - UMK3's desert read out of `umk3.zip`: record `FF9516F0` (stage 0Eh), four modules, a skew_7 floor (`FL_DSRT`, byte-identical to deadlythirdcombat's `FL_DESER.BIN`) and Cyrax buried in the sand (`CYRXSAND1-4`, 7 ticks a frame, `dsrt_cyrax_proc`). **MK2's planes are UMK3's plus one**: MK2's `worldtlx` is the fighters' camera AND plane 1's, and UMK3's plane 1 scrolls at 3/4 of the fighters, so baklst1 is `skip_bakmod` and UMK3 plane n is baklst n+1 (Cyrax: baklst6 on `worldtlx3`). **MK3 runs the stage calla BEFORE the module list and center_x**, so an animator's world x is table x + the record's start x (SCORPION'S LAIR measured the same rule). First art in the **u110-u113 block** (`data/DSRT1`/`DSRTM`/`DSRTFL`, linear 0x1400000-0x143C000). **LOAD2 REFUSES A LOAD ADDRESS OF 8000000 AND UP** ("Illegal load address" in IMGBUILD.LOG, a 68-byte IRW, and the next BGNDTBL snapshot silently holds the PREVIOUS pack's table) - and 8000000 is exactly where that block starts - so the LODs are based 4 MB lower, inside the u114-u117 hole MAME never loads, `makevrom.py` `WOLF_RELOCATE` moves the payload up, and the tool adds 2000000h to every SAG it emits (Cyrax's four headers are generated into `src/UMK3DSB.ASM`; LOAD2's `UMK3DSM.TBL` is never included). Snapshot `BGNDTBL.RT1`. `--apply` Phase B2d8b, `--check` Phase D, `--preview` renders it. No stage fatality (UMK3 has none); music is the Wasteland's set. In both stage cycles after SCORPION'S LAIR. |
| `tools/make_umk3stages.py` | THE SOUL CHAMBER (curback 021h, `src/UMK3SOUL.ASM`), THE PIT III (022h, `src/UMK3PIT3.ASM`) and NOOB'S DORFEN (023h, `src/UMK3NWAL.ASM`), **Wolf only**, both read out of `umk3.zip` the way JADE'S DESERT is (records `FF954E00` / `FF9542C0`, stage table entries 06h / 0Ah) into `src/UMK3SCB.ASM` / `src/UMK3P3B.ASM`. Soul: planes move up one (UMK3's plane 1 runs at 7/8), UMK3 skips plane 3 for the SOULNADO (`USCNADO1-12`, 4 ticks, raw top-left via `set_xy_coordinates`), so baklst4 is its object list; skew_7 floor `FL_USC`. Pit 3: planes map 1:1 and have no floor, and **UMK3 centres its plane-1 camera 123 px ahead of the fighters' - MK2's plane 1 IS the fighters' camera, so the tool moves the module by that lead instead of centring `worldtlx`** (centring it would drag the fight's start camera). Plane 1 is 1445x2676, bridge AND shaft, all packed so the stage fatality can come later without a repack - not wired yet. Packs `USC1`/`USCM`/`USCFL` at linear 0x1440000-0x1478000 and `UP31` at 0x1500000, loaded 4 MB lower (`WOLF_RELOCATE`). **A 4-character pack name makes LOAD2 write a bare `HDRS:`** (it drops the first four characters), which `make_mk3cave.read_hdrs` will not match - the tool renames it on the way in. Both list all eight planes (`skip_bakmod` for the unused) so nothing inherits the previous stage's module. Music: Soul = the Tower set, Pit 3 = the Pit II set. `--apply` B2d8c, `--check` Phase D, `--preview`/`--report [--stage soul|pit3]`. **NOOB'S DORFEN is UMK3 background 18h, record `FF95AE00`** (UMK3 calls it NOOB SAIBOT DORFEN) - UMK3's round-intro string, loaded with `MOVI 18h,A11` at `FF9A4100`; the PSX port's `BKGD_NOWALL_MOD` 17h is ONE OFF (UMK3's 17h is a static 400x256 screen). It is MK3's `nowall_mod`: THE BALCONY with the front walls skipped, so baklst1 AND baklst2 are `skip_bakmod` and plane 1's camera is centred on a module nobody draws (`undrawn_centre` in the tool). Packs `UNW1`/`UNWFL` at linear 0x1590000-0x15BA000 (~92 KB), snapshot `BGNDTBL.NW1`. Music is THE SOUL CHAMBER's set: UMK3 plays its hidden set (tunes 25h-27h) there, not carried on Wolf. In both stage cycles; nothing forces Noob onto it. **THE GREEN LANTERN over the well is this project's**: THE PIT III's big lantern (dome `LANTRN01-06` spinning over cage `LANTRNA`+`LANTRNB`) at FULL size, HOVERING WITH WEIGHT (`unw_lt_bob`, one entry a tick, 168 ticks: a slow 96-tick lift, a 48-tick gravity drop, a 24-tick catch that sags 1 px past rest - 7 px of travel), on THE PIT III's packed art (`.globl` in UMK3PIT3.ASM) - so retiring Pit III's lanterns breaks it. It rides baklst2 (the skipped front walls: a module-less list is never culled by `disp_del`) with that list's camera given the WELL's rate and centring (`unw_lant_proc`, UMK3NWAL.ASM). Rig `tools/wolf_dorfen_lantern_check.lua` (`WS_MAP`, `WB_LOG`; launch MAME with `-seconds_to_run`, which skips the warning box): period 168, 7 px, <= 1 px a frame, cage locked 30 px under the dome, the dome turning - PASS. Rig: `run_wolf_boot_probe.ps1 -Script wolf_stage_view.lua -Env WS_MAP=...,WV_STAGE=21` (or 22, 23) |
| `tools/make_pit3kahn.py` | SHAO KAHN ON HIS THRONE in THE PIT III (curback 022h, **Wolf only**; the stage's name is "THE PIT III", `txt_bg35`). `data/NEWSHAO.IMG` carries a SEATED Kahn that no MK3/UMK3 code ever draws (nothing in MK3SRC, the UMK3 C port or this tree names them; the IMG's own `SHANSIT`/`SHANSIT_1` sequences only group them, every hold 1): torso poses `SHATAUNT1-4`, `SHACKNE1-11`, `SHAFISTS1-7` and ONE shin, `SHASITLEG`, on one anchor. Drawn FLIPPED on the throne at the right end of the bridge (plane 1, the fighters' plane): torso on the seat, the shin moved off the shared anchor (`LEG_DX`/`LEG_DY`) to stand squarely in front of the gargoyle armrest post, knee at its head and boot at its foot - this throne has no panel to hide the thigh the art assumes. **The fighters stand mid-deck**: UMK3's ground_y 216 is the deck's front lip, so `up3_lift` (8) raises it and the shadow band is written off the same lift (`up3_fight_ground`, UMK3PIT3.ASM). **`flip_single` mirrors a single-part object IN PLACE (oxpos does not move), so the tool writes the FLIPPED top-left**; the first cut wrote the unflipped one expecting a pivot, and in game the shin hung behind his back while `--preview` looked right. The anchor (`KAHN_X`/`KAHN_Y`, world 1130,40) was chosen against the stage render and `--preview` redraws that proof. **The fighters stop short of the throne**: `right_edge` (up3_wall **984**, 2026-10-14 - was 1035, pulled in so a fighter cannot touch STANDING Kahn's pointing arm either, Jax's roundhouse the widest back swing; measured by `tools/wolf_pit3_touch_check.lua` against `tools/pit3_kahn_profile.py`'s per-row opaque edge) is the fighters' wall and the camera keeps UMK3's 801 through `cam_rmax` (BGND.ASM scroller, 0 = every other stage), panning on when someone reaches the wall; `cos_right_cam` (MKPROP) makes a teleport warp at that wall, not the screen edge, when the view is past it. Shadows clipped to the deck (17/1). **THE GREEN LANTERNS share the pack**: `MKBGANI2.IMG` (deadlythirdcombat) carries a lantern set on Pit III's own `GRNLIT_P` that no MK3/UMK3 stage or code ever used; `--parts` writes a trimmed `data/UP3LANT.IMG` and the LOD reads it as a second library. The spinning dome `LANTRN01-06` replaces UMK3's two small lanterns - plane 3 carried nothing else, so baklst3 is `skip_bakmod` and `up3l_proc` builds two domes there, three frames out of step, **drawn at a quarter size (`oscale` 04000400h - 36 px, the small lantern's own width)** on UMK3's plane-3 camera. **`ani_flag` re-anchors with the UNSCALED anipoints**, a 13 px wobble on a scaled sprite, so `up3l_spin` carries each frame's scaled x and `up3l_frame` puts `oxpos` back (its `center_x` entry stays, reading only the module's width). **Each dome sits on a cage**: the big lantern's body (`LANTRNA`+`LANTRNB`, its two halves) hangs under each dome at the same quarter size (`CUP_DY` 8 = 30/4), z 0 against the dome's z 1, so each is one whole ~36x37 lantern in the old one's footprint, the cage 2 px right of centre (`CUP_DX`) so the spike's tip lands under the dome (2026-10-13, the user's call; an earlier cut hung it full size on its own, and it floated). **A `skip_bakmod` is ONE long** - leaving the `.word x,y` after it shifted every later module and blanked the stage. **Kahn's Pit commentary**: an uppercut on Pit III draws UMK3's `comment_table_pit` (superb x2, well done, laugh 1-3, no crowd) out of MK2's own Kahn clips (`upcut_comment`, MKREACT.ASM, Wolf), and a laugh makes the seated Kahn throw his arm out (`up3k_cue`); with Kahn fighting it is MK2's ordinary comment. **And he talks from the chair**: the arm-sweep (palm down, "kneel") made on his own says MK2's "I'm Shao Kahn - bow to me" (triple_sndtab2 42h) half the time, and a decided round gets one of UMK3's four winning-Kahn lines (`rsnd_skb`: that was pathetic / you will never win / you're still trying to win? / don't make me laugh) - UMK3's own streams added to `make_wolf_audio.py`'s `UMK3_TAIL` (`wsnd_sk_*`; two by tsound row, two by TRACK because they live only in Kahn's `st_sk`). Rig `tools/wolf_pit3_voice_check.lua` (latch only - stock MAME cannot play u6-u9). Rigs `tools/wolf_pit3_wall_check.lua` (wall, camera, lanterns), `tools/wolf_pit3_comment_check.lua` (`P3C_STAGE=0` = Dead Pool control). `data/UP3KN.LOD` packs them straight out of NEWSHAO.IMG (PON>, `BGPAL1_P` = Kahn's own palette) at linear 0x1568000 (~100 KB with the lanterns and the rise/point; the Pit 3 growth slot 0x1568000-0x1600000), loaded 4 MB low and moved by `WOLF_RELOCATE`; `--apply` (Phase B2d8c2) writes `src/UP3KAHNB.ASM` (relocated headers, placement, gesture lanes), `--check` in Phase D decodes every packed record back to the IMG. `up3k_proc` (UMK3PIT3.ASM, `pid_bani`) builds torso + shin on `up3_kahn_lst` (RAM.ASM's protected block), drawn after baklst1 - over the throne, under the fighters - rests on SHATAUNT1 and every 90-240 ticks taunts, sweeps the arm or raises both fists (`@blood_rand`); **AT FINISH HIM HE STANDS UP AND SAYS IT** (2026-10-14): a seated gesture is cut short, `SHAGETUP1-4` raise him out of the throne **off the kneeling shin** (the rise and the point are drawn `RISE_DX/RISE_DY` = -15,-7 off the seated anchor so SHAGETUP1's own shin lands on SHASITLEG's - `--check` re-measures it by template match) (the shin object is parked at y -400 meanwhile - SHAGETUP draws the seated leg itself), then MK2's own point `BGTALK1-5` over `BGTALKLEG1` (data/BOSS5.IMG, same `BGPAL1_P` word for word - packed as whole PON> records labelled `UP3BGTALK*`, since MKSK owns `BGTALKn`), and **`grow_msg` (MKFX.ASM) hands FINISH HIM/HER ($14/$15) to `up3k_voice_take`** so the line goes out the tick the arm lands on BGTALK5, not at the banner. He stays standing; a decided round gets a winning line and the point again. Rig `tools/wolf_pit3_finish_check.lua` (G1-4,T1-5 in order, shin parked, line once at/after BGTALK5). A decided round otherwise raises the fists. The throne is EMPTY when Shao Kahn is a fighter. **No authored timing exists** - the holds are this project's (GESTURES in the tool). **The slot is 0x1568000-0x1590000** (widened for these; the pack ends ~0x15811DA). **After a LOD change run `makevrom.py` before `makewolf.py`** - makewolf takes the Wolf-only art from `rom/wolf_video_hi.bin`, and skipping it ships the OLD pack: the new frames draw as garbage while `--check` passes. Rig: `run_wolf_boot_probe.ps1 -Script wolf_stage_view.lua -Env WS_MAP=<abs path>,WV_STAGE=22,WV_STOPS=1042,...,WV_DX=143` (`WV_DX` spreads the pair so the camera reaches the limit with the seat clear; `WS_MAP` must be ABSOLUTE - MAME runs in C:\MAME) |
| `tools/make_wolf_story.py` | WOLF ATTRACT: Midway's four STORY SCREENS (Shang Tsung + Goro, Liu Kang, the execution, Shao Kahn - `the_story`) and a CHARACTER PROFILE before each demo fight (`show_next_bio`; `amode_demo_game` already makes that fighter player 1), back in the Wolf attract loop under `.if wunit` (MKAMODE.ASM). The T-unit retired their backgrounds (ATRAX1-4, STORY1) out of MK7MIL.LOD, so their `src/BGNDTBL.ASM` headers point at other art; `data/WSTORY.LOD` re-packs them at Wolf linear 0xF80000 (67.6 KB; moved up from 0xF50000 2026-10-11 to give MK1 KANO's subframe pack room), IMGBUILD.BAT snapshots `BGNDTBL.WST`/`BGNDPAL.WST`, and `--apply` (Phase B2d9d) writes `src/WSTORY.ASM`: W* copies of the five records + five Wolf modules, which `one_story_screen` takes through `wstory_mods`. Palettes are NOT copied - `--check` (Phase D) fails if LOAD2's ever stop matching `src/BGNDPAL.ASM`. **`mk2_intro` leaves its logo objects on the display list**, so the Wolf loop runs `amode_fade_retp` before the story (retail's followed MIDWAY PRESENTS, which ends in that fade) or the logo draws over the first picture. **The four story layouts leave screen x 393-399 black above the text row** (Midway's right stone column ends at x 392): the tool emits an edge-only module per screen (`wstory_edges`, four 52x50 stone tiles at x 415) and `wstory_edge_pass` (MKAMODE.ASM) draws it in a SECOND pass after the screen is done, the way `try_another_line` adds text. **Never put those tiles in the stage module**: appended there they pushed story screen 3 over the frame's DMA budget (`dmaq_late` 0 -> 4 on the last four frames), the display abandons the TAIL of the queue - the text panel, z 40h - and screen 1's text showed through screen 3's. Cage's bio uses his own portrait (retail's `028h` "old picture" slot was retired). Rig: `tools/wolf_attract_story_check.lua` (`WS_SNAPS` frames to snap, `WS_POKE_BIO=N@F` forces the next profile) |
| `tools/make_mk1kano.py` | MK1 KANO (Wolf, Shang morph) out of `mk.zip` into `data/MK1KANO.IMG` - all 71 lanes of fighter table `FFCE4B90` entry 1, 1,310 pieces, `KANO1_P`/`KANO2_P`; `tmp/mk1kano/lanes.txt` + sheets. Reference library, no LOD. `--check` |
| `tools/make_umk3sonya.py` | MK3 SONYA (Wolf, Shang morph only, ochar 20) out of `umk3.zip`: all 498 records of UMK3's header table `FFBCF230..FFBDCCF0`, which is MK3's `MKSONYA.TBL`+`MKSONYA2.TBL` record for record (run frames left out, 483 kept) -> `data/UMK3SNYA.IMG` + `data/UMK3SNY.LOD` (Wolf linear `0xC88000`, 634 KB). Body `POF>` (costume palette), effects `PON>`; `MKSONYA2.TBL` INTERLEAVES its palette groups, so effects take their palette by family. Her fatality art (MK3's shared SBFIRE/SKELFIRE skeleton burn, 36 records) is a SECOND library and pack, `data/UMK3SNFA.IMG` + `data/UMK3SNF.LOD` (linear `0xD30000`): **LOAD2 garbles record names and hangs on a prompt in the DOSBox window once an IMG passes ~2 MB** (2.26 MB failed, 1.94 MB is fine; record count was not the cause). `--check` (Phase D) proves both IMGs, both LODs and every packed record. See [doc/WOLF_SONYA.md](doc/WOLF_SONYA.md) |
| `tools/make_umk3sonya_asm.py` | `src/UMK3SNYL.ASM` (Phase B2d9a, `--check` Phase D): her MK3 lanes from MK3's own `MKSONYA.ASM` (labels `sn_`, MK3 `>` hex converted), `sonya_anitab1` in MK2's TABLE1 layout, her palettes; rows MK3 lacks are KITANA's MK2 lanes copied in (thrown rows re-framed with Sonya's frames, gore rows still Kitana's art, their MKFN-local headers copied). Carries a hash of UMK3SNY.TBL + MKFN.TBL so a repack changes the .ASM (gmake only watches the .ASM) |
| `src/UMK3SNYM.ASM` | MK3 SONYA's moves (Wolf only, hand-written): her HP/LP/Block/HK handlers and the four specials on MK3's own inputs - energy rings (MK3 `do_sonya_zap` on Jax's wave plumbing), square wave (MK3's routine, NOT Kitana's MK2 one; height `snysq_height` 01ch set with the `f_colbox` overlay - MK3's 060h flew her over a standing man because MK2's `distance_off_ground` measures sprite tops), leg grab (Baraka's MK2 port of MK3's routine; `react_to_fn` row 1ah = `r_sa_leggrab`, Wolf only), bicycle kick (MK3's rising bike). Rig `tools/wolf_sonya_specials.lua` (12/12). See [doc/WOLF_SONYA.md](doc/WOLF_SONYA.md) |
| `tools/make_nightwolf.py` | MK3 NIGHTWOLF (Wolf only, ochar 23, a START tap on Liu Kang's square): the 1,045 records MK3's own `MKIND*.TBL` name, minus the run, taken BY NAME out of deadlythirdcombat's `INDIAN1-12.IMG` into `data/NWOLFA-C.IMG/.LOD` (linear 0x1600000+, the u110-u113 block, loaded 4 MB low and moved up by `WOLF_RELOCATE`), plus `data/NWSEL` (the LKBOX->Nightwolf box wipe, ladder mug, and `BAR_NIGHTWOLF` cut from MK2's own plate letters). `--apply` writes them; `--tables` (Phase B2d8d) merges LOAD2's tables, SAGs relocated, into `src/NWOLF.TBL`; `--check` in Phase D. `tools/make_nightwolf_asm.py` writes `src/NWOLFL.ASM` (MK3's MKIND lanes + Liu Kang's thrown/victim lanes on his frames, `nightwolf_strikes`, palettes; Phase B2d9n). Moves: `src/NWOLFM.ASM` (arrow D,B+LP; hatchet uppercut D,F+HP; reflector B,B,B+HK on Kahn's `kahn_deflect_proj`; shoulder charge F,F+LK). NWOLFL/NWOLFM are LAST in `mk2.cmd` (40 KB mid-link overflowed DIAGMENU's callrs). Rig `tools/wolf_nightwolf_check.lua` (`NW_NOTAP=1` control, `NW_TRACE=1`). See [doc/WOLF_NIGHTWOLF.md](doc/WOLF_NIGHTWOLF.md) |
| `tools/make_robosmoke.py` | MK3 ROBOT SMOKE (Wolf only, ochar 24, a START tap on Reptile's square): MK3 keeps Sektor, Cyrax and Smoke in ONE module, so his art is not "everything the tables name" but **everything his lanes draw** - `lanes()` walks MKROBO.ASM taking each `ani_ochar_jump` as MK3 does for `ft_smoke` (his branch an `ani_jump`, the others dropped) and never follows an `ani_calla` into code. 341 records out of deadlythirdcombat's `ROBO1-13.IMG` into `data/RSMOKA/B` (linear 0x16E2000-0x1780000, right above Nightwolf) + `data/RSSEL` (RPBOX->HDSMOKE wipe, ladder mug); 0x178A000-0x1800000 is reserved for his fatality art. His spear is NOT packed: it is ninja Smoke's COMEHERE rope (`a_sm_rope_ani`, MKNJ exports it). `--tables` Phase B2d9r -> `src/RSMOKE.TBL`, `--check` Phase D. `tools/make_robosmoke_asm.py` writes `src/RSMOKEL.ASM`: his lanes, TABLE2 laid out for the MK2 routines his specials reuse (0 spear throw\|pull, 1 rope, 2 telepunch, 3 inviso, 4 air slam), the male ninjas' thrown/victim lanes on his frames, and a strike table on the **ninja** layout (spear_proc fires 11h = `stk_njspear`) - which is why his proxy is ninja Smoke (14), not Liu Kang. Moves `src/RSMOKEM.ASM`: spear B,B+LP (MK2's `do_spear`), teleport uppercut F,F+LK (MK3 `do_robo_tele`), invisibility hold Block,U,U+HP (no Run button), air throw Block in the air (MK2's `do_air_body_slam` on his MK3 art); his MK3 RUN (hold Run + forward, 7 px/tick - the camera has no 8 row - on MK3's 48-tick turbo meter - NOT drawn, `rsturbobar .set 0` in RSMOKEM, since he is to be CPU-only; 1 draws it as score entries 21/22). His ground THROW is MK3 Smoke's own (RBAIRSLAM, as MK3's `smoke_slam`), not Sektor's RBSHOLDER (whose arm is a separate RBMECARM object); his JUMP row has a landing part (MK2's `do_land_animation` plays row 6 part 2 - without it he vanished on every landing); his spear leaves his CHEST (`do_throw_spear` / `lineup_rope_with_him`, MKZAP, ochar 24, as MK3's -120h,+28h), and his MK3 COMBOS (`process_combo_table` ported: elbow HP,LK,HK,LP / knee HK,LP), his alone. **THE WOLF'S RUN BUTTON IS A SECOND BLOCK BUTTON** (gsw2 bits 2/6 = swtab 42h/46h, "doubled for sf2 kit") for every other fighter; `p1/p2_runbutton` (MKINIT) drop it for ochar 24 only. `body_slam_init` gives 24 Scorpion's "flipped by" row. Rig `tools/wolf_rsmoke_check.lua` (`RS_NOTAP=1` control). See [doc/WOLF_ROBOT_SMOKE.md](doc/WOLF_ROBOT_SMOKE.md) |
| `tools/make_umk3sindel.py` | UMK3 SINDEL (Wolf only, ochar 21, a START tap on Mileena's select square - moved off Shang Tsung's 2026-10-10, box wipe FN2BOX1-9 in data/SNBOX.LOD): the 494 pieces her UMK3 lanes draw, out of `umk3.zip` into `data/UMK3SDA` + `data/UMK3SDB` (two IMGs/LODs - LOAD2's ~2 MB ceiling; linear 0xD6A000 / 0xDC8000). LANE-driven, not table-driven: 449 take MK3's names positionally, 45 are UMK3-only (`SNHAIR*`, `SNFIREB*`). `--check` Phase D. `tools/make_umk3sindel_asm.py` DECOMPILES her lanes into `src/UMK3SDL.ASM` (MK3's `MKLIA.ASM` is not what UMK3 ships - 287 records differ); `tools/sindel_lane_proof.py` proves the built Wolf ROM's lanes against UMK3 step for step (51/51). Her moves are `src/UMK3SDM.ASM` (hand-written): fireball F,F+LP, air fireball D,F+LK, scream F,F,F+HP, levitate B,B,F+HK, fatalities B,B,F+Block (scream) and D,D,B+Block (hair spin), babality D,D,D+LK, stage fatality on Block; Pit II cannot be done TO her (`do_down_the_pit`, no fall art yet). **MK2's `set_inviso` takes the object in a0, MK3's a8.** Rigs `tools/wolf_sindel_select.lua` (+`SS_NOTAP=1` control), `wolf_sindel_view.lua`, `wolf_sindel_specials.lua` (8/8), `wolf_sindel_fatal.lua` (`WF_FATAL=RIP|HAIR|BABY|PIT|PIT2`). See [doc/WOLF_CONTENT_PLAN.md](doc/WOLF_CONTENT_PLAN.md) |
| `tools/wolf_fighter_rows.py` | WOLF-ONLY FIGHTERS: one `.if wunit` row per Wolf fighter (Sonya, ochar 20) in all 132 ochar tables `audit_char_tables.py` lists, so the T-unit is byte-identical. Evaluates each table's own `.if` blocks for the Wolf build to find rows 0..19; copies the PROXY's row (Kitana) unless `OVERRIDES` names her own; tables already longer than 20 are left alone. Generators of char tables (`cage_brain_wax_import`, `make_soulrip_pals`, `subspine_wax_import`) call `block()` so their output carries the same rows. Phase B2d9 `--apply`, Phase D `--check`. MKDRONE took its 24 blocks without the GSPA abort |
| `tools/make_mk1_music.py` | MK1'S STAGE MUSIC on Wolf. **Since 2026-10-10 five stages take `MK1NEWAUD/`'s three-file sets** (the user's mapping): Temple Gate -> THE COURTYARD, The Bridge -> THE PIT, Throne Room -> the PIT BOTTOM too (curback 0Ah, `wmus_pitbot*` are aliases of `wmus_throne*` since 2026-10-11 - the Shang Tsung set is no longer encoded; `PITBOT_OWN` in the tool restores it), The Cavern -> THE WARRIOR SHRINE, Throne Room -> THE THRONE ROOM, Palace Gates -> PALACE GATES. **That IS how MK1 plays them**: three consecutive sound commands per stage (`tools/run_mk1_music_cmd_probe.ps1` logs MK1's port 01D01020 through a real match: tune at every round start, `- Loop` once at FINISH HIM, `- End` at the killing blow - no separate victory sting) - and the switch is a HARD CUT, never a crossfade (`-Ym` logs the YM2151: every channel keyed off and re-voiced within 1-8 frames, no TL ramp on the outgoing cue), which channel-0 DCS tracks already do. Here the tune is the round tune, `- Loop` the finish tune played as cut, and `- End` the winner tune. **After a fatality MK2's own "death blow over" 035h plays** (2026-10-11, the user's call after playtest: the End sting there read as the wrong tune) - `wolf_dbc_tune` (MAIN.ASM) is now a pass-through kept so `death_blow_complete` is unchanged. Temple Gate / Throne Room / Shang Tsung loop sample for sample (0.96-0.97); **The Bridge, The Cavern and The Palace Gates repeat nowhere** (one pass into a fade), so `find_body_loop` loops their whole body with a 0.5 s crossfade - a longer rip without the fade would fix that. **The MK1 streams are 112 kbit/s, not 128**: at 128 the set needs a ninth 1 MB sound socket; at 112 it ends in u9 with ~40 KB free. Before that: MKWarehouse's arcade recordings in `MK1_audio/` (MK1 music is live YM2151 FM - not in any sample ROM), each cut to intro + the loop it repeats, both MEASURED (spectral period, refined to the sample, earliest seam within 3% of the best), loop resampled to whole 7.68 ms DCS frames, levelled to MK2's -15 dBFS RMS. Writes `sound/wolf/mk1/*.wav`, `sound/wolf_mk1music.txt` (tracks $0700+, makewolf appends it) and `src/WOLFMUSE.ASM` (`wmus_*`, MAIN.ASM's four tune tables for curback 1Ah-1Eh under `.if wunit`). ~1.8 MB, so it lives in the Wolf board's SPARE SOUND SOCKETS u6-u9 - **stock MAME cannot load those** (8 MB region, byte-wide chips on 2 MB strides; u6 wraps onto u2 silently), so it is heard only in `tools/mame_wolf` (patched single-driver MAME `mk2wolf.exe`). Rig `tools/wolf_mk1music_check.lua` + `tools/mk1_music_listen.py` (Courtyard PASS in mk2wolf, FAIL in stock MAME). See doc/WOLF_SPACE.md "Sound" |
| `tools/make_wolf_audio.py` | WOLF SOUND OVERLAY: UMK3 Sonya/Sindel voice + move sounds. Track numbers from MK3 `MKSOUND.ASM`; streams exported RAW from `umk3.zip` into `sound/wolf/umk3/`. Writes `sound/wolf_patch.txt` (tracks $0600+; `makewolf.py` appends it), `src/WOLFSND.ASM` (`triple_sndtab2` 69h+), `src/WOLFSNDE.ASM` (`wsnd_*`). These are TABLE-2 rows, so send them with `triple_sound2`. `--check` runs in Phase D. See [doc/WOLF_SONYA.md](doc/WOLF_SONYA.md) |
| `tools/deadpool_acid_band.py` | Where THE DEAD POOL's acid actually is, in world x, measured off `DEDPOOL.BDB` — the band `r_fall_in_slime`'s stage fatality aims at (`--check` in Phase D) |
| `tools/run_deadpool_slime_fall_test.ps1` | One Dead Pool stage-fatality trial: pin the victim at `-VictimX`, fire the uppercut, report where the body/splash/skeleton landed. See [doc/DEADPOOL_STAGE_FATALITY.md](doc/DEADPOOL_STAGE_FATALITY.md) |
| `tools/run_deadpool_boon_drop_test.ps1` | One THE DEAD POOL acid-drop trial. The live hangers (`hp_live_now`, MKHANG.ASM: THREE of the nine, picked per match, and only 1-2 fall per ROUND - see `run_deadpool_rotation_probe.ps1`) go in once per match - **nobody for the first 15s of a match** (`first_drop_ticks` 821, fighting ticks only), then only while wholly on screen, at least 15s apart, in whatever order the camera finds them - and stay in as skeletons for rounds 2-3; the rig watches one (`-Hanger N`, default the newest) and PINS him via `hp_lineup_force`, so he hangs alone and no neighbour's drop leaks into his window; `-ClockJump` skips the waits between drops, `-NextRound` checks round 2. The bodies hang across the whole pool per the order photo, so the rig parks the idle fighters beside him to bring the camera over (`-NoPinCam` to skip). A new body needs its pieces packed in a sidecar of its own (MK7MIL and MOVEART1 are full - see `data/HANGTONY.LOD`; bank-0 room came from `noob_extras`/`vs_noob_smoke_pics` = 0, MAINEQU) and its chain stack in the per-hanger tables. Segments the sequence into trigger / fall / submerge / splash / simmer / skeleton rise / park and reports each beat against budgets read out of `MKHANG.ASM`. See [doc/DEADPOOL_BOON_ACID_DROP.md](doc/DEADPOOL_BOON_ACID_DROP.md) |
| `tools/run_deadpool_rotation_probe.ps1` | THE DEAD POOL hangs THREE of its nine bodies a match and picks a different three next match (`hp_pick_lineup`, MKHANG.ASM; `hanger_rotate .equ 0` = all nine). ONE PER ZONE - left corner / the view the round opens on (world 373..772) / right corner - so they are spread, not clumped, and the zone a body is in is MEASURED off `hanger_coords`, so the layout editor moves him between zones. Which three is a per-zone BAG (`hp_zone_bag`/`hp_zone_last`), refilled whole when empty with the last body barred from the pick that follows - hold him out of the BAG instead and a zone of three deals 3,2,2,2 and shows one body 4 times in 8. **AND ONLY ONE OR TWO FALL PER ROUND** (`hp_round_cap`, rolled every round out of `drops_per_round_min`..`max`; `hp_round_drops` counts, the trigger refuses at the cap) - the same three hang all match and a body that goes in stays in, so all three going in round 1 would leave nothing to watch. The cap sits AFTER the in-view test so `hp_next_drop_ticks` still counts down in a capped round, which is why a body can go in on the next round's very first fighting frame. Chooser is `hp_pick_stir`, a private xorshift seeded off the VALUE of `@rand` (read, never advanced): not `randu` (the game's stream, re-seeded per round) and **not `@tick`, which is a CONSTANT here** - `tick` is in `round_init_words`, so the first cut's picks were a perfectly regular round-robin. Probe: `-Picks N` reads `hp_live_now` every pick (12/12 PASS, holding `round_num` at **0** between rounds since `round_init` increments and `create_hangers` picks at 1); `-Mode drops` plays real matches and checks the cap, the same-three rule, once-in-stays-in, and that round 1's first fall waits `first_drop_ticks` (2/2 PASS; measured +820, was +127 - `hp_drop_count` spends the last tick on the frame the drop begins, the same 821-counts-820 accounting the inter-drop pause has). Only ROUND 1 can assert the opening wait: the countdown carries across rounds, so a round that ends with 3s left on it is followed by one whose first body goes in 3s after the bell. The cap is proven by A/B, not by one run: at cap 2 Jeff follows Mark at frame 2562, at cap 1 he waits two rounds. Rig traps: open the round in the round INTRO (a drop can land on the first fighting frame); read `hp_dropped` only for the three in the lineup (the other six are marked dropped and never spawned); and PIN the losing bar every frame, not once - written once, round_init's reset can land on top of it, the round ties, and a tie is sudden death / GAME OVER, which gives short rounds in which nothing has time to fall. `hp_lineup_force` is the rig hook: a non-zero mask IS the lineup. See [doc/DEADPOOL_BOON_ACID_DROP.md](doc/DEADPOOL_BOON_ACID_DROP.md) "Three bodies a match" |
| `tools/run_deadpool_hanger_layout.ps1` | THE DEAD POOL hanger LAYOUT EDITOR: boots onto the stage at real speed, holds off every drop, hides the fighters, and lets you pick a body (1-9 / `[` `]`), move it (arrows), pan (PgUp/PgDn, End, Home) and save (Enter) to `tools/hanger_layout.txt`, which is then copied into `hanger_initab` (MKHANG.ASM). Draws the FIGHT-view box (captured in the round intro), each body's drawn extent (red = off the acid or feet below 186) and a whole-acid minimap. Works because `hanger_coords` is re-read every tick |
| `tools/deadpool_boon_gif.py` | Stitch the acid-drop rig's `-SnapEvery` filmstrip into a GIF at a chosen speed. `--slow 3` is three times slower than the game; `--range A:B` picks one beat (shot index = ticks-since-trigger / `--every`, and the log's BEATS line converts any beat into an index) |
| `tools/peak_sea_band.py` | Where YOTEIGAI TOR's sea is, measured off `MOUNTAIN.BDB` — the waterline, its extent in PLANE 3's world x, and the camera floor that keeps the module from running out of blocks (`--check` in Phase D) |
| `tools/run_peak_stage_fatality_test.ps1` | One YOTEIGAI TOR stage-fatality trial: pin the victim at `-VictimX`, drive Liu Kang's B,F,F+LK, ride the camera down and report trigger / camera / aim / payoff separately. See [doc/YOTEIGAI_TOR_STAGE_FATALITY.md](doc/YOTEIGAI_TOR_STAGE_FATALITY.md) |
| `tools/make_rainn64_img.py` | Every piece of RAIN's own art in MK Trilogy's N64 tree (`SEG/CHARDATA/MNINJA`) - the storm cloud, its burst, the raindrops, the bolt, plus his body palettes - decoded 1:1 into `data/RAINN64.IMG` with the decompressors transcribed from `SEG/GAMECODE/U64MAIN.C`. The reference copy, anipoints untouched; `--png` previews. `make_raincld_img.py` builds the game's `data/RAINCLD.IMG` on top of it |
| `tools/import_trilogy_rain_kamel.py` | RAIN's and KHAMELEON's colours out of the N64 Trilogy tree into `data/KATPAL.IMG` - 24 palettes and six ninja stances. Neither fighter is in ANY arcade ROM, so `umk3.zip` - the source of KATPAL's 64-entry palettes - has not one word of either. **Two groups, and the difference is the whole point.** The 19 FIGHTING palettes (`GAMECODE/IMGPAL.S`) are 32-entry/5bpp and that is the ONLY version Midway made of either fighter: `CHARDATA/{MNINJA,FNINJA}/MK*.PAL` keep the arcade 64-colour originals (MKNJ flat 15-bit, MKFN in the N64 alpha form, both UMK3's words to within ~4 slots) but the two were authored Apr-Jun 1996, AFTER that Feb 1996 reduction. **The reduction cannot be undone** - it re-quantised rather than selected, so Trilogy's `KIT1_P` and UMK3's share 7 of 32 colours and no index correspondence; a slot map fitted on 8 male + 6 female control costumes cross-validates at ~7 units/channel and 3-4 of 64 slots exact, so lifting 32->64 is synthesis, not data. The 5 VS-PORTRAIT palettes (`ATTRACT/VS/VSMNINJA.MAS`, `VSFNINJA.MAS`) ARE 64-entry - the portrait is a separate drawing that stayed at 64 colours, and both fighters have their own pieces in it (`VRAINGREEN1A-E`, `VKAMGREEN1A-F`). That art is a texture blob (`.ATZ`, offset-addressed) this does NOT decode. Because the two groups are different depths, each fighting costume carries Trilogy's OWN stance - the stance is READ, not chosen: neither `ft_rain` nor `ft_kamel` has an `ani_ochar_jump` row in `a_stance`, so both take the default (`SCSTANCE1`/`KTSTANCE1`). Six proofs before any write, all negative-tested: `character_palettes_1/2[FT_RAIN|FT_KAMEL]` naming the four costumes at `MKGAME.H`'s indices; 13 artist-`.RGB` twins (`KAMEL1_P` is `KAMMYNU.RGB`, the "kammy NEW" one, not `kammy1`); the stance record still naming its body's palette; each costume's share of the SHARED BODY RAMP (17 male / 21 female) pinned to its exact count, which is what makes a swapped palette fail where a recoloured one would not; the VS piece lists still carrying each fighter's own pieces under the imported palette; and every VS palette being 64 entries. Only the six worn STANDING get a sprite. **Not in Phase D on purpose**: KATPAL.IMG is in no LOD and is hand-edited in IMGTOOL, so a `--check` gate would fail the build on a colour tweak |
| `tools/make_fxpal_img.py` | TWO BORROWED EFFECT PALETTES, out of two other games' arcade ROMs into `data/FXPALS.IMG`. **`JDBRITE_P`** is UMK3's `jade_bright_p`, the full-body flash Jade wears for the whole of her SHADOW KICK (`prop_do_jade_prop`, MKPROP.C, opens `player_swpal(current_proc,jade_bright_p,obj)`) - index for index a bright GREEN re-hue of `JADE1_P`, her flesh ramp, her white-to-black grey ramp and her costume ramp all becoming one green ramp, mean luminance 9.7 -> 16.1. **It is in NO IMG**: a lower-case symbol in `MKGUYS.H` is a CODE palette, and all 1,635 palettes across `deadlythirdcombat`'s 266 libraries were scanned to prove it - only `umk3.zip` has the words. Found by CONTENT (greenness plus per-slot luminance against JADE1_P), confirmed by CODE: the label `FFA510E0` has EXACTLY ONE 32-bit reference in the megabyte and the routine around it is `prop_do_jade_prop` instruction for instruction - `MOVI 0217h` (ACT_JADE_PROP), the palette into player_swpal, `MOVK 6` (ST_JADE_PROP), `MOVI 0030h` (FX_JADE_SMOKE), `MOVI 0012h` (ANIM_LOKICK) - and all three immediates are asserted. **`MK1LTNG_P`** is MK1 RAIDEN'S LIGHTNING out of `mk.zip`, a 62-step violet-to-white ramp: his branching bolts are drawn in three of its slots (14 violet, 35 lilac, 62 white) and his glow art sweeps the whole thing. **An MK1 image record carries no palette field** - the palette is the `.long` that follows the FIRST record of a group (4 longs, then 3 per record after it) - so the glow group at `FFF2A700` names it at `FFF2A760`, and the bolt object header at `FFD34000` names it again. **What makes it RAIDEN'S rather than a shared "electric" palette is the SIBLINGS**: only three MK1 fighters have a glow lane, and each one's own art names a ramp of its own - Cage's is GREEN (`FFE99F10`), Sonya's MAGENTA (`FFE9F460`), Raiden's the violet one; the check fails if any two are the same words or the wrong hue. A palette on its own cannot be judged, so each ships a frame the game really draws in it: `JDBRITE1` her extended low kick (`KTLOKICK6`+`6A` - `ANIM_LOKICK` IS the shadow kick's pose, the move has no art of its own), 60 of 64 slots; `MK1LTNG1` one branching bolt, 3 slots, which is the whole of a bolt; and `MK1LTNG2` Raiden's own glow silhouette (`raiden_anitab[24]` frame 0), 57 of 64 - the frame to judge the RAMP against, which the bolt cannot. `data/FXPALS.IMG` is in NO LOD - LOAD2 never reads it and no pixel reaches a ROM, the role `data/KATPAL.IMG` plays for the MK1 fighter palettes - and **`--check` is NOT in Phase D on purpose**: the library exists to be opened and recoloured in IMGTOOL, so a build gate would fail the build on a colour tweak. `--apply` writes it, `--png DIR` renders the frames |
| `tools/make_costume_palettes.py` | EVERY COSTUME A PLAYABLE FIGHTER WEARS, out of `data/MK2PALS.IMG`. The library names a palette `<XX>MAIN_P` / `<XX>ALT1-5_P` and `<XX>BLD_P` / `<XX>BLD1-5_P` per fighter, and **n IS the lane**, so the seven tables MKGUYS.ASM already had take it 1:1: MAIN->`_1`, ALT1->`_4` (Start+HP), ALT2->`_2` (Start+LP), ALT3->`_5` (HK), ALT4->`_6` (LK), ALT5->`_3` (Block). Writes `src/COSTPAL.ASM` (a new linked object) and repoints the rows in place; `--matrix` prints the per-fighter grid, `--check` is Phase D. A LANE WITH NO RECORD OF ITS OWN TAKES THE FIGHTER'S DEFAULT, costume and blood alike - his `<XX>MAIN_P`/`<XX>BLD_P`, else whatever `character_palettes_1` / `bloody_palettes` column 0 hold - NEVER the palette that lane happened to hold: Rain's Start+HK/LK/Block blood rows were `SUBALT4_P` and Ermac's Start+LP was `ERUMK2_P`, both CLEAN COSTUMES, so being cut up on those lanes left them looking untouched. A button that falls back to the default LOOKS like it does nothing, which is right, and the no-duplicate rule still rolls player 2 forward if player 1 is wearing that default. **The `KP_` prefix on every generated symbol is load-bearing**: six of the library's record names already exist in `src/` as DIFFERENT palettes (its `LKALT3_P` differs from the linked one by 56 of 64) and `RPBLD1_P` / `SCBLD1_P` collide with `RPBLD1_p` / `SCBLD1_p` by CASE alone. **START+COIN IS DISABLED** (`costcoin .set 0`): `psel_repalt5_preview` and `claim_repalt5_pal` (MKSEL.ASM) claim nothing, `_7`'s rows are flattened to each fighter's default, and the lane is dropped from the no-duplicate walk (`costume_lanes .set 6+costcoin`). Flattening the rows ALONE would not have disabled it - a coin would have claimed a lane equal to the player's default, the no-duplicate rule would have found player 1 in it, and the coin would have SHIFTED player 2 onto Start+HP. It costs Kitana's BIV ramp, which was reachable on that lane and nowhere else; `costcoin .set 1` restores both. Kintaro, Kahn, Smoke and **Khameleon** are never generated - all seven of her lanes must resolve to the one `KHMAIN_P` id or the disguise cycle snaps. `BLOOD_STAYS_LIT` is AUTHORED, not computed: the honest test reads state the tool then destroys, so a second `--apply` silently dropped the fade exclusions. See [doc/COSTUME_PALETTES.md](doc/COSTUME_PALETTES.md) |
| `tools/sync_raiden_elec_palettes.py` | RAIDEN'S LIGHTNING IS COLOURED BY HIS COSTUME, so the two are authored side by side in `data/MK2PALS.IMG`: `ELEC_P` for `RDMAIN_P`, `ELECRED_P` for `RDALT1_P`, `ELECPRL_P` for `RDALT2-4_P`. Carries the three into `src/IMGPAL4.ASM` and fails if one leaves `death_fade_excludes` (which would dim the bolts while the fighters stay lit). **`ELECPRL_P` exists ONLY in that library** - `data/RAID8.IMG`'s `ELECPUR_P` is a DIFFERENT purple, 51 entries of 53 apart - and `IMGPAL*.ASM` is hand-maintained, so a recolour in IMGTOOL would ship the old colours silently. `--check` in Phase D. See [doc/RAIDEN_ELECTRIC_PALETTES.md](doc/RAIDEN_ELECTRIC_PALETTES.md) |
| `tools/make_raiden_crackle_palettes.py` | THE THIRD PLACE HIS CURRENT SHOWS: the ambient `RN*BOLT` crackle over his own body, which is painted against the COSTUME layout (`ELEC_P` has 53 entries, the art indexes 63) and so wears a COSTUME palette. **It decodes all 102 pieces out of the built video ROM and MEASURES which slot is the colour** - slot 63, 60% of the lit pixels; 24 is the white arc core, 48-57 a grey fringe, 62 is never drawn. MK2PALS.IMG gave all five Raiden costumes the same crackle blue, so it writes `src/RDCRACK.ASM`: a COPY of each non-blue lane's costume with that one slot set to Midway's own crackle colour (`RADRED_P`'s (31,3,1), `RADALT4_P`'s (18,5,31)) - lifted, not invented, since those palettes are still linked and differ in exactly that slot. **Honour a compressed record's per-row lead/trail skip bytes** or the histogram is garbage that still looks plausible (the first cut picked slot 15). `--check` in Phase D, which also proves `raiden_crackle_offer` still parallels `costume_offer` |
| `tools/make_shock_palettes.py` | THE SAME PAIRING ON THE VICTIM: the electrocution flash is his OWN body repainted, so `<XX>` is the man being fried and there is a twenty-row table per colour. **Midway drew all three sets in `data/ALLDUDES.IMG` and wired only the blue one** - this carries the other 19 records into `src/SHOCKPAL.ASM` (a new linked object) and generates `shock_pal_red` / `shock_pal_purple`. Two names look like typos and are not: Liu Kang's purple is `LKELPUP_P`, and **there is no `BGELRED_P`**, so the boss body's red row falls back to `BGELEC_P`. It also proves `ochar_elec_pals` (MKGUYS.ASM) still matches its roster, because red and purple are generated from that same roster - so the three tables cannot quietly disagree about who is drawn on whose body. **TWO FAMILIES since 2026-09-28**: the ELEC beat AND the FREZ beat in front of it, which Midway also drew in three colours and also wired only one of - the 18 `<XX>PURPL_P` / `<XX>REDEL_P` records become `shock_frez_red` / `shock_frez_purple`. That beat has its OWN roster (`RN` for Raiden, `gorof_p` for Kintaro, no red or purple for either boss body) and four of its blue symbols are carried under a name the library does not have (`LKFREZ_P` is the library's `LKFREZ1_P`), so `FREZ_SOURCE` matches them by WORDS. It requires each PURPL/REDEL record to be the same DRAWING as the FREZ record it replaces - identical brightest channel in all 64 slots, 18 of 18 - which proves the pairing by content instead of by the name; the ELEC reds are only 45/64 and 47/64 for TM and LK (redrawn, not re-hued), so that test is reported there and required for FREZ. `--check` in Phase D |
| `tools/run_raiden_elec_test.ps1` | Runtime proof of both pairings, per costume lane. `-Mode costume` teleports him and requires the decoy's palette to be the paired one with NEITHER other electric palette on screen; `-Mode cycle` zaps the other man and requires four distinct palettes - the solid white and black flashes among them - with the ELEC beat his own body's copy of Raiden's colour; `-Mode victory` wins the match and requires the same of RAIDEN's own body by name (`RDELEC_P`/`RDELRED_P`/`RDELPUR_P`) AND that he ENDS in his costume - twelve beats end on BLACK, so a victory loop that forgets to dress him again leaves a solid black silhouette and nothing else in the tree would catch it. 6/6, 6/6 and 6/6; `-Negative` crosses the expectation with the ROM untouched and every trial must FAIL, 3 of 3 do. **Solid white and black are not proof on their own** - `rvic_fade` calls `raiden_dimmer` and a full dim takes the palette to zero, so the victory verdict turns on the NAMED palette, which only `player_shock_pal` produces. Two more rig traps: **pinning the victim's bar to 1 EVERY frame stops the round ever ending** (`bar_reducer` empties it and the next frame puts it back - write it only while it is ABOVE 1; measured 1800 frames, one palette, "he never won the match"), and **a sampler nested under `gs == GS_FIGHT` cannot watch a victory** - a round win leaves GS_FIGHT for the banner and the next intro, so the sampler stops for hundreds of frames and its deadline never fires. Identity comes from `palram`, the allocator's own table (`opal` names a MAP, `palram[map]` holds that palette's ROM address), believed only while `palcnt` is non-zero - `freepal` leaves the id behind, so a stale row reads as an electric palette no longer on screen. **It identifies the costume BEFORE judging the bolt**: the lane is claimed by writing `@alt_pal_owner`, and a claim that did not land leaves him on his DEFAULT, whose partner is `ELEC_P` - so a rig that only watched the bolt would report green for four lanes it never reached. That disagreement is NO VERDICT, not a pass. Two move traps: **`rd_hp_open` is not a plain High Punch** (it hangs off `switch_open_jumps`, so the electrocute grab needs an opponent already OPEN), and **`do_short_lightning` is a SHORT zap** a man at round-start distance never feels - the victim is pinned inside range EVERY frame, because repell parts them the moment they overlap |
| `tools/make_mk2pals.py` | RETAIL'S MIRROR-MATCH COSTUMES, ON START+HP (`character_palettes_4` rows 0-11). Reads retail's `character_palettes_2` and the UGLY column of `bloody_palettes` out of **mk2-readonly**'s `src/MKGUYS.ASM` - the rows are PARSED, not typed, so a wrong tree fails instead of producing a plausible wrong set - and writes `data/MK2PALS.IMG` (24 palettes + a stance and a torso-rip frame to judge each against, pixels copied verbatim from the read-only gore libraries) and `src/MK2PALS.ASM` (what links). **The words come from the read-only tree because two have DRIFTED here**: `KATBLU3_P` by 28 of 64 and `RADRED_P` by 2 - retail's `KATBLU3_P` is `KAT11.IMG`'s, while this tree's symbol of that name is `KAT1.IMG:KATBLU2_P`, so provenance is matched BY CONTENT and printed. They are COPIES under new `M2*_P` names, not the shipped symbols: slot 4 as an alias of slot 2 would move the mirror match on every repaint. `--check` in Phase D. See [doc/MK2PALS_START_HP.md](doc/MK2PALS_START_HP.md); rig is `tools/run_mk2pals_test.ps1` (12/12, `-Negative` 12/12 inverted) |
| `tools/twrside_statue_layout.py` | THE TOWER's terracotta guards: lay them into `data/TWRSIDE.BDB` and check TWRSIDE still carries stock TOWER2 unchanged (`--check` in Phase D) |
| `tools/kahn_soulrip_wax_import.py` | SHAO KAHN'S SOUL RIP (`src/MKSOULRP.ASM`) - writes `ksr_script` from `data/SHAOSOULSUCK.WAX` (Kahn slot, victim slot, soul slot, picked by what their frames are). The soul's leading run of repeated first frames is a timing buffer: hidden except its LAST tick. Rerun after every WAX save; `--check` in Phase D |
| `tools/fan_swipe_seq_import.py` | KITANA'S FAN DECAPITATION swinging out AND BACK. `FANSWIPESQ` (`data/KAT9.IMG`) is a full back and forth - `KTFANSWIPE1..6` then `5..1` - but the lane the game plays (`a_fan_swipe`, MKFN.ASM) stops at the top of the swing, so retail's blade crosses him ONCE. This generates the return half as **two more PARTS** on that lane, plus `do_fan_decap`'s timing equates in MKDEATH.ASM. Parts 1 and 2 are NOT rewritten: her Back+HP power punch plays exactly those two through `striker_2` + `retract_strike`, so re-cutting them from the sequence would silently change a live move's startup and recovery - instead `--check` fails if the outward half of the sequence stops naming the frames that lane plays. Hold bytes are PREVIEW ticks x4 (13.7 fps), the same trap as the double knee; retail's own `sleep 030h` corroborates it to within a frame. **The seqscr record layout is not the same in every IMG** - KANG3 puts the frame list at name+0x64 on an 18-byte stride, KAT9 at name+0x3a on 16 - so the reader solves for (base, stride) and fails on ambiguity rather than guessing. `--check` in Phase D. See [doc/KITANA_FAN_DECAP.md](doc/KITANA_FAN_DECAP.md) |
| `tools/jade_impale_wax_import.py` | JADE'S STAFF IMPALE (`do_jade_impale`, MKDEATH.ASM) - writes her body lane (`a_jade_impale`, `fn3_anitab2` 0ch: `ani_flip` + `ani_adjustxy` off the WAX's mirror flags and ANIPOINT offsets), the staff lane (`a_jade_rod`, 0dh), `JDROD_P` and `jade_impale_geom` (hold, the staff TIP measured off the last `RODIMPALE` frame's pixels, the staff's start offset) from `data/JDIMPALE2.WAX` into MKFN.ASM. Rerun after every WAX save; `--check` in Phase D. Rig: `tools/run_jade_impale_test.ps1 [-Victim all] [-Side both]`. See [doc/JADE_STAFF_IMPALE.md](doc/JADE_STAFF_IMPALE.md) |
| `tools/cage_brain_wax_import.py` | JOHNNY CAGE'S BRAIN PUNCH: `jch_place` (MKDEATH.ASM), where each victim body stands so the fist is in his head, from `data/CAGEBRAIN.WAX` (each body's `HEADHOLE1` posed on `JCHIPUNCH3`; the head is the last piece, so the offset moves the whole body). `--check` in Phase D. The punch plays the uppercut smack and then the crowd "ooo"; at the punch `jc_brain_chunks` (blood_procs 01eh) throws Jax's clap chunks plus the stock GUSHER out of the back of the head (behind him, on `get_tg_blood`'s BLOOD_P) and MK1's BIGGERBLUD out of the front (on `get_jt_blood`'s jtblood_p) with the kiss of death's BLDSPLASH over it (`jcb_entry_splash`) - the MKBLOOD.TBL splash records carry no palette, so each is built on the record its art's palette belongs to; the victim is moved onto the fist on the PUNCH frame (`jch_lineup`), shakes there, and jumps back to his own floor in one frame as he drops to his knees. Rig `tools/run_cage_brain_test.ps1 -Victim all` (12/12). See [doc/JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md](doc/JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md) |
| `tools/st_decap_lineup.py` | SHANG TSUNG'S BLADE DECAPITATION LINE-UP (`do_st_decap` / `stdc_lineup` / `stdc_place`, MKDEATH.ASM). The cut is ONE PICTURE - Shang holding `STLAUGHFAT13` while the victim stands on the first frame of his own `a_decapfall` - so both are measured off the art: the BLADE as the run of thin columns at the right-hand end of the frame (a centre line off Shang's anchor), each body's WOUND as the top rows of its headless frame, the two anchors related through `ochar_ground_offsets` (read from MKGUYS, never typed). **The blade is angled, and that is why nobody is lifted**: it climbs ~16px over 36, every stump height falls in or just above that span, so a purely HORIZONTAL spacing picks the point along the blade at his neck height - short necks stand in (Shang 53), tall ones out at the tip (Jax 81). Baraka, Raiden and Jax are taller than the tip reaches and sit 4.5-6.5px under the top of the wound; `MAX_RESID` fails the build past 8. Writes `stdc_place` (one word per victim ochar, Wolf rows through `wolf_fighter_rows.block`) and `tools/st_decap_lineup_expect.lua`; `--check` in Phase D, `--png DIR` renders all nine bodies at their spacing. `stdc_lineup` runs AT THE CUT - the tick `STLAUGHFAT13` is first drawn, no yield between it and that frame's `mframew` - so the victim stays where he stood, SWAYING in `dizzy_dude`'s own stagger (`st_decap_victim_wait` runs anitab1 `028h` at rate 3; it used to freeze on one frame), until the blade arrives (the user's call, 2026-10-10). x only, as relative adds to `oxval`, and holds the victim to `gravity_n_bounds`' own limits - past the wall the engine would take the spot back and the spacing with it, so Shang gives up the remainder. Rig `tools/run_st_decap_lineup_test.ps1 [-Package] [-Victim all] [-Side both] [-Wall] [-Negative]`: the real B,B,F,U+LP, then asserts off the LIVE objects that the spacing is exactly `d` on every tick to past the cut, that they face each other, that the cut is the measured pair of frames, and that the blade sits where the art predicted using the game's real `oypos` (which is what proves the ground-offset arithmetic). It COUNTS TICKS: the victim must not move on any windup tick, must move on exactly the tick Shang's `STLAUGHFAT13` first appears (168 for every body), and must show >= 2 dizzy poses before it. **A multipart object's `osag` is a constant `02000000h`** - read the pose as the first piece's SAG through `oimg`, or a swaying man reads as frozen. Kintaro and Shao Kahn have no decap art and take a fixed 72 |
| `tools/szhr_align_expect.py` | WHERE SUB-ZERO'S HEAD-RIP PROPS MUST BE DRAWN, generated from the art, so "the hand is over the head" is a number rather than a screenshot. Both props hang off HIS anchor and take HIS facing (`match_ani_points` flips them, `multi_adjust_xy` negates the lane's dx, `ganiof` mirrors about the anipoint), so the expectation is in **facing space** - x from his anchor, negated when he faces left - and the SAME numbers must come back whichever way he is turned. That is what "the mirror is toward him" means and it is what `run_sz_headrip_test.ps1` asserts every frame (`ALIGN`, 211 samples, `dx=+0 dy=+0` on all four beats, left / right / `-CrossUp` alike). **The 1-2px between facings is irreducible** - flipped `ganiof` uses `sizex - anix` where unflipped uses `anix`, plus `(w-1)//2` truncation - where a real mirror fault is ~30px at the hold and ~190 at the rip. **The FIST boxes are AUTHORED, not computed** ("which pixels are his hand" is a judgement about a drawing), so `--check` fails the build if any strip of the four poses moves rather than measuring against a hand that is no longer there. `--check` in Phase D. `-CrossUp` stands him on the WRONG side through FINISH HIM and puts him across 15 frames before the press - nothing in the rig touches his facing, which is the point - and a run that did not cross AND turn is a FAILURE, not a pass. `-Negative` mirrors the head prop off his facing and both checks must go BAD |
| `tools/make_soulrip_pals.py` | Generates `src/SKSOULP.ASM`, the green ramps the soul rip draws each victim's own `SUCK_*` strips in. `SOULGRN_JC` is `MKSUCK.IMG`'s `CAGE1_P` verbatim; the others are the fitted recipe (G = luma*27/255, B = G/4, R = 0). `--check` in Phase D |
| `tools/run_lk_dubknee_test.ps1` | LIU KANG'S DOUBLE KNEE (`lkdknee`, MAINEQU; `src/MKLKDK.ASM`). 5 trials: `dubk` - second HK pre-dialled, so the knee STUNS (rose 0) and the double knee kicks him down through his sweep fall and he bounces >= 20 px with <= 3 px x drift, ending facing Liu Kang (31 over 2 hits); `jugl` - the same plus a crouching HK into the bounce: a THIRD hit whose own reaction carries him >= 15 px (the sweep get-up never moves him sideways); and the negatives `knee` / `late` / `cool` - retail's LAUNCH (rose >= 30), 20. `-Victim <ochar>` (11 Jax default), `-Package` builds a private zip + map from the current link and refuses if `src/mk2.out` moves under it; private nvram/cfg, `mame_lkdktest.exe`, kills nothing by name. **It parks the PAIR mid-screen** every trial. `-Snap` films it into `tmp/lk_dubknee/`. See [doc/LK_DOUBLE_KNEE.md](doc/LK_DOUBLE_KNEE.md) |
| `tools/run_stelbow_chain_test.ps1` | SHANG TSUNG'S ELBOW CHAIN, judged on the FRAMES (`st_elbow`/`st_elbow_2`, MKSTEL.ASM). `STELBO1-5` are **TWO elbows**: 1 is the wind-up and 2 the contact of the FIRST, 3/4/5 the turn, cock and contact of the SECOND, and the `ELBO` sequence in `data/TSUNG2.IMG` plays all five straight through. **Retail opened `a_stelbow` on STELBO3**, so the elbow MK2 ships is the second of the pair and the first was drawn by nothing - which is why nobody noticed that `data/MK3MIL.LOD` packs **`STELBO1A` twice and `STELBO1B` never** and `src/MKST.ASM` matched the typo with a one-piece `STELBO1`. Both are Midway's own and both are fixed (`data/STELBO1.LOD`, a bank-0 sidecar - MK3MIL has 960 bytes left and the record needs ~1,700). **Damage is the wrong thing to measure here**: the chain already did the right damage while drawing the wrong frames, both elbows being STELBO3,4,5. The rig reads the SAG and size of every piece the DMA was handed and asserts the ORDER - `elbo` 1,2 and never 3/4/5; `dual` 1,2,3,4,5; `cool` refused inside `st_chain_cool`. It also **counts the pieces**, because with STELBO1B unpacked the frame is one node and Shang draws as a man sliced down the middle, which a frame-order check cannot see - the first piece is STELBO1A either way. `st_elbow_2` BURNS part 2 (the first elbow's retract, which `retract_strike_act` needs sitting behind part 1) with no sleep between the calls, so the rig fails a chain that reads 1,2,**1**,3,4,5. **The second elbow could not connect in open space**: `r_saelbow` throws the victim 6 px a tick and the contact frame found him 118 px off against a 57 px reach - 24 over one hit, completing only in a corner. `stk_stelbow` now hands him `r_st_chainstun` (Liu Kang's `r_lk_chainstun` trade, and the same cost: his UNLINKED elbow no longer throws a man away) - **except elbow on elbow**: `st_elbow_spam` (MKSTEL.ASM) hands retail's `stk_stelbow_end` (r_saelbow, thrown clear) to an elbow landing on a man whose `p_hit` is still up and whose `p_hitby` is `act_elbow`, so a mashed close HP no longer loops (`spam` trial: second elbow push 117, was 6). **Test `p_hit`, not `act_reacting`** - `reaction_start_abc` never writes it. Liu Kang's "pre-dialled" rule does NOT fit here: the elbow connects on its first active tick, 4 ticks after the press. The rig runs on private nvram now. 4/4, `-Negative` 3/3 inverted - and that control crosses the EXPECTATION only: flipping the inputs with it runs a different trial and passes trivially. **An `.if` inside a strike record breaks every positional parser of MKSTK.ASM** - `balance_lock.py` DROPPED `stk_stelbow` from the lock and `hitbox_edit.py` read the `.else` word as damage, so the routine word is unconditional like `stk_lkknee`'s |
| `tools/run_smoke_spear_test.ps1` | SMOKE'S HARPOON (`smrope`, MAINEQU) - he always threw the spear (`zap_offsets` row 14 = `00ch`) but `sm_anitab2` was a bare ALIAS label stacked on `sc_anitab2`, so row 1 paid out SCORPION's rope. Now `a_sm_rope_ani`: `COMEHERE1/2` in flight, `COMEHERE3` stuck - Midway's second rope (a coiled spring with a TRIDENT head), drawn in `data/NEWROPE.IMG` beside Scorpion's and never packed by retail or by this tree. Measures **the SAG the DMA was handed**, off the one-piece multipart RAM, finding the rope by walking `objlst`/2/3 rather than `p_slave` (re-pointed and cleared by `delete_slave`). Expectations are REGENERATED from `src/SMROPE.TBL` + `src/MKNJ.TBL` every run by `tools/smoke_spear_expect.py`, because a rebuild moves every SAG in a pack. Second half is the clip as an identity on the live object - `ofset + dist == mp_sizex` - true for both ropes only because `lineup_rope_with_him` now READS the taut frame's width instead of Midway's hard-coded `304` (SPEARHIT's; COMEHERE3 is 317), so `-Who scorpion` is a real control. **`ZOF>` is load-bearing**: `ofset` makes the DMA skip source COLUMNS and there is no indexing into a zero-run record - Midway's own NEWROPE section is `ZOF>` for exactly the rope records. **Rig trap: ATTRACT MODE runs both the select screen AND a demo fight at the same gstates**, so latching on the first sighting of each catches the attract loop, `pressed()` then stops driving the coin, no game ever starts, the drone reads as inert in `act_stance` for the whole run and the DEMO's Scorpion spear gets scored against Smoke.  **KNOWN LIMITATION: the rig cannot make a DRONE act** - it reaches the fight and measures correctly, but the CPU fighter sits in `act_stance` for every frame. Not about Smoke: an ordinary fighter's drone (`MK2_SPEAR_FT=1`) is inert the same way, 1,602 frames of 0x0303. Ruled out: the RNG stir, the `p_state` writes, `f_freeze_timer`. A run ending `HARNESS: drone never acted` is reporting the rig, not the art - so Smoke's half is STATICALLY proved (`art_ref_graph --explain COMEHERE1/2/3` = LIVE, and the packed pixels decode byte-identical to the IMG) while the clip half is proved at runtime, 25 samples of 25, on Scorpion. See [doc/SMOKE_SPEAR.md](doc/SMOKE_SPEAR.md) |

| `tools/run_ermac_chain_probe.ps1` | ERMAC'S TELEPORT -> TELESLAM CHAIN, as a re-grab count rather than an impression. `-Mode scale -Seed 0..3` is the other half: it SEEDS the victim's `p_hit` so the slam lands as the (N+1)th hit of a string and reads what the impact takes off the bar - **9/7/4/2** gated, **9/9/9/9** before. Seeded rather than driven, as `run_rain_halfdmg_probe.ps1` seeds `rh_cdmg`. **The seed must STOP at the catch**: the index is read at the IMPACT ~70 ticks later and has to carry the catch's own `inc_p_hit` on top of the seed - keep poking and the index resolves to 0 and every slam reads full (which is why `run_ermac_teleslam_test.ps1` still reports `damage=9`: its poke is gated on `not caught`, and `caught` needs 20px of lift). Seed 0 passes on BOTH builds and is the positive control. Drives each move the instant the GAME says it is legal (P1 idle, teleport off `l_decoy`, slam inside its box), which is the upper bound on what a player can do. **The teleport is not the cause**: `-Mode slamonly` never throws it and still locks - a slam every 50 ticks, each catching a man still in `act_reacting` from the last, because Ermac's own routine is 25 ticks and the victim's is ~140. **And the four-hit push back never runs**: `r_ermac_teleslam`'s `dec_my_p_hit` plus the victim LANDING (which clears `p_hit`) leaves the counter oscillating 0<->1, so `phitmax` is 1, `dmgscale` scales nothing and `no_unlimited_airhits` (`p_hit > 3`) is never reached - measured `sep=0`, `p1_xvel` never carried a separation request. What the teleport contributes is SPACING: the bounce walks the victim into the grab's own 100px dead zone and the teleport resets the gap. **Verdict is the MIN GAP between two CONNECTS** against `erm_tks_cool`, read out of MAINEQU.ASM rather than written into the rig - ungated `50 50 50 50 50 191 50`, gated `138 189 137`. NOT the re-grab count: a slam taking hold of a man already in a reaction is the move being USED, so that is reported and not asserted, and `catches >= 2` is required because one connect has no gap to measure. `-Mode cap -Seed N` is the hit cap (fires at 0/4, refused at 5/6; the ungated control fires at all four) and `-Mode combo` drives the teleport->slam chain, passing on it connecting and reporting the 48-tick lag that explains `incombo=0`. **Three rig faults worth keeping**: `st_t` starts at 0 while `frame` is already ~700 at the fight, so any phase with a TIMEOUT expires on its own first tick (combo's lead-in reported "never connected" at the start distance) - re-stamp the phase clock on the first fighting frame; `(MAXHIT ~= nil) and (SEED < MAXHIT) or nil` is Lua's and/or trap AGAIN (CLAUDE.md documents it for slicehat) and collapses to nil for every REFUSED seed, failing the half of the cap worth testing; and a lead-in hit must wait for P1's OWN ~38-tick recovery before the motion, or MK2 discards it and the slam never comes out. Two detector traps: a re-grab never transitions INTO `act_reacting` (he is already in it) so there is no action-code edge, and the victim's `oyvel` is NOT the signal - the bounce decelerates from -8.0 by 0.375 and `0x80000-16*0x6000` is exactly `0x20000`, so it passes back through the catch's own -2.0 and scores two catches per slam. See [doc/ERMAC_TELESLAM_REGRAB.md](doc/ERMAC_TELESLAM_REGRAB.md) |
| `tools/run_jax_multislam_probe.ps1` | JAX'S MULTI-SLAM THROW, slam by slam - every bar drop with the tick it landed on, so the curve is read as a sequence and not inferred from a total. `super_wham` is 10 and he gets it `jax_extra_slams+1` times for tapping High Punch, on top of `slammed_by_jx`'s 18: **58 off one input** against Kintaro's 40. `-Char kang|cage|shang|raiden|kitana` exercises the other payload sites (all seven call `throw_damage_a10` now, and a Jax-only run would not notice one paying nothing); `-SeedHit N` seeds the victim's string depth; `-Jab` lands a real High Punch first instead. **THE TAPS ARE SEEDED, NOT PRESSED** - `l_hp` is stamped in `bj_hi_punch`, the button dispatch, while the thrower is inside `act_bodyslam` with his buttons disabled, so whether a scripted press reaches it is a question about input gating and not about the damage curve under test. **Three rig traps, all of which read as "never threw"**: `repell` will not let a walking pair closer than **63px** and `toss_check` wants <= 040h, so any approach threshold tighter than 64 is unreachable; **an idle fighter reads `p_action` 0, not `act_stance`** (`act_mframew_z` clears it - JOY.ASM's own simultaneous-throw guard documents the same trap); and in `-Jab` the jab must be SEQUENCED before the grab, or whichever handler the switch scan reaches first wins and the throw goes in at `p_hit` 0. Also re-baseline the bar AT the throw in `-Jab`, or the jab's own damage is counted as the throw's first slam. See [doc/THROW_DAMAGE_SCALING.md](doc/THROW_DAMAGE_SCALING.md) |
| `tools/run_drone_flipp_test.ps1` | THE CPU'S JUMP-IN PUNCH (`drnflipp`). Human Liu Kang throws high fireballs on a fixed period at a CPU opponent, because **an idle opponent produces no jump-ins** (`rt_drone_start` is rolled once; after that the CPU's flips come from avoiding projectiles). Each jump-in is logged as kick or punch, whether it connected and FOR HOW MUCH (a bar drop while the move is live - 16 punch, 26 kick), and what was dealt in the 100 frames after landing with the action that dealt it. `-Negative` zeroes `rpt_flip_punch` in memory: no punch may come out. **Thin by nature** - at most 3 jump-ins in 20,000 frames, never a kick - so it proves existence, not superiority. **Default 9,000 frames, on purpose**: an unrelated machine reboot arrives near fight+10,000 (see the `drnflipp` entry). `DFP_GAPRESET=1` re-enables the teleport that keeps the CPU at range; it is OFF by default because it reset the machine (CPU Cage, 16 frames in). `DFP_NOLKZ=1` NOPs `lkzapair` in memory and `DFP_NOSTIR=1` leaves `@rand` alone - the bisect switches. On a state change it dumps the game's own bars / `winner_status` / PC / guard counters from the last six fight frames. **Launches the house way** (`Start-Process` + `mame_dismiss_warning.ps1` as its own process + a 63s no-log kill of ITS OWN pid): its first cut copied `run_jax_multislam_probe.ps1`, which has no poker, and parked on the red ROM-warning box in front of the user |
| `tools/run_jax_wave_slot_test.ps1` | A P2 JAX'S WAVE IN P2'S PROJECTILE SLOT (`jaxzappid`). 2P Jade vs Jax, no drone. **A (the verdict)**: on the tick the wave exists, walk `active` and read its `procid` - fixed `0800h`, retail `0700h` - then run `get_his_proj_proc`'s own masked compare for a P1 scanner. **B (the consequence)**: P1 Jade throws Back,Forward+LP while the wave flies; fixed she gets `act_jade_boom`, retail her `jz3b1` guard refuses. A B trial counts only if the wave is still ALIVE when her Low Punch lands, else NO VERDICT - so her motion starts the tick Jax's action is stamped and the LP lands on the spawn. `-Package` builds a PRIVATE zip from the current link (`mamerom.py --output`, never installs) with `src\mk2.map` copied beside it, and refuses if `src\mk2.out` changes while it packages. **`-Negative` patches the `:maincpu` region, not a second build**: one immediate in `jax_zap_spawn`, located by its instruction bytes (TMS34010 short `movi` is `09C0|reg` + the word, `calla` is `0D5F` + a 32-bit bit address - which is how MKDRONE's three "his projectile" sites, immediates the other way round, were confirmed to be the only near misses). "UI Select" is OPTIONAL - it is not a game port in every MAME build. `-Air` jumps Jax straight up and throws in the air, `-Delay N` moves the release down the arc; an air trial is classified by Jax's height when the SPECIAL STARTED, not by a release cut-off (a 20px threshold discarded the genuine low air throws, which are the only ones that land). FLIGHT follows the wave's OWN object every tick and reports a hit only when Jade's bar drops WHILE the wave lives, with the amount. **A NEW PROCESS'S `pa8` IS ITS CREATOR'S `a8` UNTIL IT HAS RUN AND SLEPT** - read on the spawn tick it hands back Jax's object, and the first cut reported his head as the wave; ignore `pa8` while it names either fighter. `mame_jwsrig.exe`, private nvram/cfg, kills nothing by name |
| `tools/run_blockloss_test.ps1` | A HELD GUARD IS AN IDLE LOOP AND HAS TO POLL THE ROUND. `joy_block_loop` (JOY.ASM) never called `check_winner_status` - `joy_stance_loop` (joye5), the duck loop (joyd5) and the duck-block loop (jdblk5) all do, and the STANDING block loop did not (Midway's own omission, still there in mk2-readonly) - so a player HOLDING Block when the round was decided stayed in his guard pose: no dizzy sway through FINISH HIM, no collapse while the other man celebrated. Two beats per run, off one match: a round-1 loss (`winner_status` 1/2 -> `collapse_on_ground`) and a round-2 loss (`winner_status` 3 -> `dizzy_dude`). **Not judged on `p_action` alone** - `collapse_on_ground` never writes it, so the round-1 beat reads `act_blockhi` either way; it is judged on the DRAWN SAG moving off the guard pose plus `m_shadow` cleared in `oflags2`, which is `clear_shadow_bit`, the LAST thing that routine does. **Every sample is gated on `winner_status` being non-zero** - `round_init` clears it and `setup_players` rebuilds both fighters, so a window that runs past the teardown sees the SAG move for the next round's reasons and scored the beat PASS on the UNFIXED ROM. **And the rig must not release the button**: gated on `gs == GS_FIGHTING`, it let go within 2 ticks of a round-1 decision, the guard came down through `do_unblock_hi` -> `joy_entry` -> joye5 on its own, and the unfixed ROM passed again - a player does not release Block because the round ended. `-Mode control` (never presses Block) is the POSITIVE control and must pass on both ROMs. Measured A/B: unfixed 2 of 2 beats FAIL with Block held (SAG frozen 240 ticks, `p_action` 0700 throughout), fixed 2 of 2 PASS on the control's own schedule (sag move +2, shadow clear +31, stunned +2). Runs as `mame_blktest.exe` with a private nvram/cfg and `-Rom <dir>` holding the zip AND its own `mk2.map`; kills nothing by process name |
| `tools/run_boss_exploit_test.ps1` | THE TWO PATTERNS THE BOSSES GET BEATEN WITH, as connect rates rather than arguments: a wall of standing HIGH KICKS / ROUNDHOUSES at the edge of their range, and FLIP KICKS in (`-Boss goro|kahn`, `-Mode hikick|rhouse|flipkick`, `-All`). **Chip is not a connect** - a blocked flying kick still takes 4 off the bar, and counting it scored Shao Kahn at 75% vulnerable while he was guarding 9 of those 12 hits correctly; it classifies on what the boss was DOING when the damage landed (`act_0700` = `act_blockhi`). **It never pins the attacker** - a rig that teleports P1 to a fixed gap also cancels the knockback a block earns and the pull of Kintaro's grab, so the boss is measured against a man the engine cannot move; P1 walks to the range with the stick. `-RomDir` names a dir holding the zip AND its own `mk2.map`. It also measures the STARTUP WINDOW - ticks from the move being stamped to the hit landing - which is what proved the standing high kick unanswerable (6 ticks against `drone_react_delay`'s 8). Runs under `mame_mk2test.exe` with a private nvram/cfg and kills only that name. See [doc/BOSS_AIR_AND_PUNISH.md](doc/BOSS_AIR_AND_PUNISH.md) |
| `tools/run_kahn_coward_test.ps1` | SHAO KAHN'S "RUN, COWARD" (`kahn_coward_talk` / `kahn_coward_note`, MKBOSS.ASM): one raise of the hand (`a_sk_talkup` part 1) held for the line (`kct_speech` 83 ticks), then down. `-Mode flee` (P1 walks away, Kahn ahead by 41), `zone` (one fireball; only the remembered-throw path may fire), `behind` (CONTROL - Kahn losing, nothing may fire). Judged on Kahn's own `l_kahn_coward` stamp, the latch ($0402/$0403/$0404 - **`triple_sound2` ROTATES the triple**) and the BGTALK SAGs read from `src/MKSK.TBL`; the hold must be unbroken on BGTALK5. `-Watch` = real speed with sound. **It found three things**: the line was only checked at the brain top, where a chasing Kahn has already closed under 090h, so it is checked in `kahn_stalk_a11`'s walk loop too (with `reset_proc_stack`); `drone_beware` answers the throw's WIND-UP (action category 0) before the projectile process exists, so "nothing live" let him point into a fireball ~9 ticks from spawning - a man mid-throw now refuses it; and `kahn_dummy_talk`'s lead test was `jrls` on a NEGATIVE difference, so his other taunt fired precisely while he was LOSING (now `jrle`). Trials Kahn answers by another branch never arm the note and are re-run as NOT EXERCISED |
| `tools/kahn_soulrip_test.lua` | Soul-rip rig on top of `kahn_boss_moves_test.lua` (`KAHN_NORMAL_MATCH=1 KAHN_ALLOW_P1_DAMAGE=1 KAHN_P1_CHAR=<ochar>`): gives Kahn round one, empties P1's bar, films every frame as `sr_NNNN.png`. `SR_DEEP=1` dumps Kahn's shape, `SR_TAP=1` (+`SR_TAP_WHO=vic`) write-taps a fighter's position and prints the PC |
| `tools/raiden_dive_force_probe.lua` | Which yell Raiden's torpedo actually plays. 2P game, P1 Raiden vs an idle Jax, bars pinned; each trial pins the pair and drives `scom_rd_dive` - Up, then Back, Back, Forward - and taps the sound latch, stopping once BOTH takes have been seen. **The latch carries the resolved DCS TRACK, not the `triple_sndtab` index the source sends**: the dive's `$79`/`$7B` reach the port as `$02AE`/`$02B4`, and a run watching the index logs hundreds of sends without a hit. Two traps in the input: the gesture is STICK ONLY (`rd_left_right` masks `f1b2`/`f2b2`, i.e. it refuses Block and takes no attack button), and all of it has to land inside the jump. `RDF_TRIALS`, `RDF_GAP`, `RDF_STAGE` |
| `tools/raiden_dive_snd_probe.lua` | The passive half: rides `battle_stability_sweep.lua` and prints every sound code with its frame, flagging `RDS_WATCH` (track numbers). Use it to see what a real fight sends; it will NOT settle the torpedo, because the drone does not choose it - 12,000 frames of a CPU Raiden sent 647 codes and never dived. `KAHN_SNDTRACE=1` does the same over the Kahn rig (that rig's own `snd_log` stays empty in `KAHN_NORMAL_MATCH`, which only fills while a move is being tracked) |
| `tools/run_shang_soul_escape_test.ps1` | Shang defeated -> the souls escape (`src/MKSOULS.ASM`): plays a real 1P game to a CPU Shang and records it. `-Mode control` proves a non-Shang CPU still gets FINISH HIM. See [doc/MK2_SHANG_SOUL_ESCAPE.md](doc/MK2_SHANG_SOUL_ESCAPE.md) |
| `tools/make_soul_blend_pals.py` | Generates `src/SOULPAL.ASM` - blend palettes for the five souls with no morph art (Smoke/Noob/Ermac/Jade/Khameleon); `--check` in Phase D |
| `tools/mk1_shang_souls_extract.py` | MK1's "Shang defeated - the souls escape" straight out of `mk.zip`: every frame (PNG/strip/GIF), lane, palette and timing -> `tmp/mk1_shang_souls/`. See [doc/MK1_SHANG_SOUL_ESCAPE.md](doc/MK1_SHANG_SOUL_ESCAPE.md) |
| `tools/run_mk1_shang_defeat_capture.ps1` | Automatic MAME `mk` run to Shang's defeat (forces the ladder, wins both rounds): per-frame snapshots, every blit, colour RAM; then the extractor + `capture.gif` |
| `tools/tower_stage_probe.lua` | Force a match onto THE TOWER (`curback = 3`), park the camera at each scroll limit, dump every plane's `worldtlx` + background objects, snapshot. `tools/run_tower_stage_probe.ps1 -Tag <name>` |
| `tools/extract_dev_comments.py` | WHAT MIDWAY'S PROGRAMMERS SAID ABOUT THEIR OWN CODE, out of the read-only tree into `doc/ORIGINAL_SOURCE_COMMENTS.md` (readable) + `doc/original_source_comments.csv` (all 12,186, greppable). A flat dump is useless - 8,290 of the 26,893 comment-bearing lines are one of ~200 field labels - so **repetition is the filter**: a body appearing more than 3 times tree-wide is mechanism by construction, whatever its wording, and that one rule needs no vocabulary of its own. The **disabled-code detector harvests its 188 mnemonics from the live code in the tree it is scanning**, so it cannot rot against a hardcoded list, and a `;`-ed instruction carrying its OWN trailing comment is unwrapped rather than dropped (`;jreq fadeprcx ; allow negative entries (ejb)`). **A BOXED HEADER DOCUMENTS WHAT IS BELOW IT, NOT ABOVE** - attributing backwards misfiles every documented routine in the tree by one, which is what the first cut did; a box naming no routine is a section divider and is filed with the notes. It reports the 15 headers whose box names a DIFFERENT routine than the label under it - Midway's own misfiling at multi-entry routines like `get_proj_obj` / `get_proj_obj_m` - and the register/repetition rules are suspended inside a header, because `input: a1 = ...` IS the documentation. `--grep kano` is the useful mode (MK1's Kano is all over MK2: Baraka is "sword arms (kano II)", Mileena's roll is the "kano ball"). **THERE IS NO SCHEDULE-PRESSURE VOCABULARY IN THE TREE** - zero real hits for `no time`, `if we have time`, `would be nice`, `todo`, `unfinished`, `someday`, `take out`; the only `no time` is the round clock. What was cut is recorded in the SHIPPED TEXT instead: `clue_table` (MKEND.ASM) is the eleven ending lines, four scrambled, and two are flat denials (`CEAMR ODSE NTO EXITS` = ERMAC DOES NOT EXIST, `THREE RAE ON STNIIIAAMEL` = THERE ARE NO ANIMALITIES). The dated comments are the tree's LINEAGE - `background modification for football (4/3/90)`, `Modified: Shawn Liptak, 8/13/92 - Basketball`, `snagged from nba jam to work on the t-unit (ejb - 2/5/93)` - and the newest, GNP 11/15/93 and 1/13/94, are POST-RELEASE edits to coin/audit plumbing, not the game (`gnp` = George Petro, `mdp` = Mark Penacho, both decoded from MKEND's own credit strings). The `WORKAROUNDS` list carries the named bugs and **every citation is verified against the tree each run - a comment that stops matching aborts the tool** rather than printing a stale quote; `clear "phit not getting zeroed" bug` (MKREACT) is Midway's own label on the counter the juggle system reads. `audit_airborne` answers who actually separates an airborne victim, and **COUNTING DIRECT CALLERS OF `no_unlimited_airhits` / `repell_on_a1_hit` IS THE WRONG MEASUREMENT** - it gives "5 sites in the whole game" and reads like a rule nobody wired. `reaction_start_abc` raises a flag and `rst5` `jump`s an airborne victim to the handler in `a5`, the reaction's own script never running, so the rule lives at that FUNNEL: 43 of our 44 airborne-checked reactions separate. **`separates()` must FOLLOW FALL-THROUGH** or it reports the busiest handler in the game as uncovered - `generic_airborn_hit` is two instructions and drops into `airborn_hit_no_sound`, which is where the call is. The one real gap is RETAIL's: `r_lkzap` -> `ar_lkzap`, `generic_airborn_hit`'s body minus the separator call. Run it on our tree with `--src src`. NOT in Phase D on purpose: the input tree never changes, so a gate would only fire on a hand-edited doc |
| `tools/gspa_stage.py` | Phase C1's staged assembler (above): per-module pruned MAINEQU; `--verify` proves the link byte-identical |
| `tools/make_wolf_bundle.py` | **The Wolf build for anyone**: `dist/mk2wolf_bundle.zip` = stripped `mk2wolf.exe` (MAME 0.287 + `tools/mame_wolf/umk3_u6u9.patch`, only Windows system DLLs) + `roms/umk3.zip` + `PLAY.bat` + README + the patch (GPL source note). The Wolf audio fills all eight sound sockets; STOCK MAME loads four and plays the rest as garbage with no error, MK2's own sounds included - so the set must ship with this exe. Refuses a stale or u2-u5-only set. Proven: `wolf_mk1music_check.lua -Listen -MameExe dist\mk2wolf_bundle\mk2wolf.exe` + `mk1_music_listen.py` PASS |
| `tools/make_fightcade_set.py` | The T-unit build as a SUBMITTABLE FBNeo/Fightcade set: a `mk2` CLONE under its own name (`mk2rev4`) with REAL CRCs (rom/mk2.zip is crc-spoofed to retail and answers to `mk2`, so it can never be submitted), the FBNeo `d_tunit.cpp` driver block + diff, a Logiqx .dat, reviewer README, into `dist/fightcade/<set>/`. **The program ROM is a FIGHTCADE CUT**: src/ copied to `tmp/fightcade/`, `hidearn 0` set there, assembled + linked + laid out as makerom does (" FC" on the version string when it fits) - because **FBNeo never loads NVRAM in netplay**, so earned fighters could never be picked online. src/ and rom/ are untouched (the arcade build still earns them); `--as-played` packages rom/'s program instead. Video + sound chips must equal the installed rom/mk2.zip bar crc_spoof's 4 bytes. `--release` refuses PLAYTEST and a dirty tree. Proof: `ermac_start_toggle_test.lua` with `MK2_ROOT=tmp/fightcade` on a private nvram See [doc/FIGHTCADE_SUBMISSION.md](doc/FIGHTCADE_SUBMISSION.md) |
| `sym_resolve.py` | Resolve TMS34010 bit-addresses to source symbols; `--dump` lists all |
| `gen_debugscript.py` | Generate MAME `-debugscript` to watch functions / detect crashes |
| `hitbox_edit.py` | Edit strike-table hitboxes and damage in MKSTK.ASM |
| `frame_edit.py` | Edit move frame timing (movk/sleep immediates) in MOVES/MKPROP/MKZAP/MKSLAM |
| `combo_edit.py` | Edit special-move input patterns in MOVES/MKBABY |
| `hitbox_info.py` | Print MAME debug commands for live hitbox editing after rebuild |
| `imgdump.py` | Dump IMG file header / palette / frame info |
| `img_anipoint.py` | List/shift/set IMG animation points; `sync-tbl` mirrors them into a hand-maintained .TBL (`--check` in Phase D) |
| `bump.py` | Bump MK2 version string and changelog |
| `move_lab.py` | Generate move-lab HTML viewer (`tmp/move_lab.html`) |
| `_strip_lod_paths.py` | Strip `c:\video\kombat2\img\` prefixes from LOD files (run once) |
| `dosbox_load2.conf` | DOSBox config for Phase A ? runs IMGBUILD.BAT (LOAD2) |
| `dosbox_asm.conf` | DOSBox config for Phase C ? runs `gmake -m` in `src/` |
| `data/IMGBUILD.BAT` | LOAD2 invocation per LOD file |
| `src/MAKEFILE` + `src/MAKE.INI` | GMAKE rules: `GSPA $* -H -v10` (no listings) |
| `src/mk2.cmd` | GSPLNK linker command file; entry point `POWERUP` |
| `src/FPADDR.ASM` | Generated (`tools/export_freeplay_addresses.py`, build Phase E) - `fp_addr_manifest`, the ROM's own table of the RAM the freeplay-gametalk client reads and pokes (Lab, trainer, `f_netplay`): magic `F4E5 A9D1 5046 4441`, version, count, then (FNV-1a 32 of the name, bit address) pairs the LINKER fills in. The client reads it out of the player's `mk2.zip` (uj12/ug12), so Lab works on any build that carries it however it was zipped - no re-export into the client after a rebuild. The file only changes when `SYMBOL_ADDRS` does, and Phase E fails loudly if it did (the ROM just linked does not carry it yet - rebuild). Adding an entry is safe for old clients (they match by hash) but a new client needs it in its `mk2_addrs.rs` too, so re-export `--rust-out` into the client as well |
| `src/SHOCKPAL.ASM` | Generated - the electrocution flash in red and purple, BOTH body beats (ELEC and FREZ), 37 palettes + 4 tables (`tools/make_shock_palettes.py`) |
| `src/RDCRACK.ASM` | Generated - the ambient crackle over Raiden's body per costume lane; a copy of each costume with the crackle's own slot 63 recoloured (`tools/make_raiden_crackle_palettes.py`) |
| `src/mk2.out` | Linked COFF executable (~647 KB) |
| `src/mk2.map` | Linker map ? all symbol bit-addresses (input to sym_resolve.py) |
| `data/ART.OUT` / `OART.OUT` | Pre-built art object tables (linked into program ROM) |
| `data/*.IRW` | LOAD2 raw image data (input to makevrom.py / makerom.py) |
| `data/_orig_lod/` | Backup of original unmodified LOD files |
| `sound/U2-U7.ROM` | Pre-built DCS sound ROMs (PLBUILD-generated ? CRCs won't match retail) |
| `mk2.zip` | Retail ROM in repo root ? used as sound source for mamerom.py merge mode |
| `rom/mk2.zip` | Last-installed MAME ROM set |
| `rom/mk2_test.zip` | Test build (test_mode=1); output of build_all.py |
| `rom/mk2_retail.zip` | Retail build (test_mode=0); output of build_all.py |
| `rom/debug/*.bin` | Header-stripped IRW raw bins for MAME `loadr` (via `--debug-bin`) |
| `tmp/load2/` | Throwaway dir for LOAD2 table files (must exist; contents ignored) |
| `mk2-src.zip` | Original leaked source archive ? restore if src/data files get mangled |
| `_old/` | Archive of obsolete files (safe to delete) |

### Memory layout (mk2.cmd)
```
SCRATCH  : org = 0x01000000  (RAM ? BSS, process stacks, image buffers)
CRAM     : org = 0x01800000  (color RAM)
ROM      : org = 0xFF800000  (code + data ? FLOORORG first, then .text)
TRAP31   : org = 0xFFFFFC00  (interrupt vectors)
IROM     : org = 0x02000000  (image ROM ? sprite pixel data)
```

Program ROM contents in order:
- `0x00000` FLOORORG (display list floor/shadow area)
- `0x00200` .text (code ? ~357 KB)
- `0x59604` .data (image tables, palettes, strings ? ~213 KB)
- `0xA0000` REVX (reserved movie/CPU-read payload; not allocatable for normal sprites)
- `0xFFF80` VECTORS (interrupt vector table)

### Source gaps patched (not in the original leak)
The leaked source was incomplete. These were fixed to make it build:
- **MACROS.HDR, STRINGH.ASM, DIAGSEQU.ASM, DIAGDTST.ASM, DIAGMENU.ASM**: `$end` ? `$ENDM` (GSPA 6.10 macro terminator syntax)
- **DIAGCMOS.ASM**: All 12 CMOS I/O primitives (`rc_byte`, `wc_byte`, `set_page`, `duxpal`, etc.) ? ported from roadkill/APCMOS.ASM
- **MKDEATH.ASM**: Missing `initdb5` label (branch target)
- **MKHSTD.ASM**: Missing `on_hstd` BSS variable (16-bit flag)
- **DIAGAUDN.ASM**: Missing `aud_secbad` (equ 45) and `aud_sec_powerup` (equ 46) audit offsets
- **DIAGCOIN.ASM**: Missing `counter_on` / `counter_off` ? coin counter solenoid driver (`coin_counters equ 1d01020h`)
- **DIAGMENU.ASM**: Missing `txt_octo` (alias for `mes_octo`), `post_sec_trash` stub
- **MAIN.ASM**: Missing `secbust_proc` stub (security process), removed dead `.ref seccall2`
- **MKAMODE.ASM**: Missing `mk2_court` stub (attract mode sequence)
- **MKREVX.TBL**: Missing `DCS` label (added as alias for `REVX` placeholder)
- **JOY.ASM**: `callr get_his_action` ? `calla` (cross-OBJ PC-relative overflow)
- **MKBOSS.ASM**: 3 `jrne/jrhi return_to_beware` ? `boss_return_to_beware` (cross-OBJ overflow)

## Modding cheatsheet

All editing tools take moves by label. Every edit is backed up automatically (`.bak` / `.combo.bak` / `.frame.bak`). Use `restore` to revert a tool's last edits.

### Damage / hitbox tuning ? `hitbox_edit.py`
Edits strike-table records in [src/MKSTK.ASM](src/MKSTK.ASM). 206 moves ? 8 fields each.
```
python hitbox_edit.py list                           # all 11 characters, all moves
python hitbox_edit.py list lk                        # Liu Kang only (hh/lk/jc/sa/fn/st/rd/nj/jx/go/sk)
python hitbox_edit.py show stk_lkhikick              # current values of one move
python hitbox_edit.py set stk_lkhikick damage_hit=50 damage_block=12
python hitbox_edit.py set stk_lkhikick x_offset=180 x_size=60
python hitbox_edit.py patch                          # write stk.bin for MAME loadr
python hitbox_edit.py loadr                          # print MAME loadr command
python hitbox_edit.py sync-asm                       # bake edits into MKSTK.ASM
python hitbox_edit.py reset                          # discard pending edits
```
**Fields** per move:
- `x_offset` ? front edge of hitbox (distance from sprite origin, bigger = farther reach)
- `y_offset`, `x_size`, `y_size` ? hitbox rectangle (x_size extends back toward sprite)
- `strike_routine` ? reaction/flags (advanced; leave alone unless you know what you're doing)
- `damage` ? packed word: `0x<hit_byte><block_byte>`
- `damage_hit` ? virtual field: HP damage on clean hit (high byte of `damage`)
- `damage_block` ? virtual field: chip damage on block (low byte of `damage`)
- `score` ? score value added to attacker on hit
- `sound` ? sound effect label (usually `sf_*`)

### Frame timing / recovery ? `frame_edit.py`
Edits machine-code immediates (movk/movi/sleep) in MOVES.ASM, MKPROP.ASM, MKZAP.ASM, MKSLAM.ASM.
```
python frame_edit.py list                            # all 58 do_* move routines
python frame_edit.py show do_hi_kick                 # source block with annotated immediates
python frame_edit.py tables do_roundhouse            # per-character speed tables
python frame_edit.py set MOVES.ASM:2739=2            # change MOVES.ASM:2739 to value 2
python frame_edit.py set MKPROP.ASM:814=4            # reduce post-hit hangtime
python frame_edit.py restore                         # revert all edits
```
**What to look for in `show` output** (annotations are auto-flagged):
- `movk N,a0` = ticks per frame (lower = faster)
- `movk N,a10` = number of active frames before/after strike check
- `sleep N` = explicit pause in ticks (1 tick = 18.28ms; see the timing note below)
- `movi <table>,a0` = per-character speed table (drill in with `tables`)

### Animation timing ? the tick, and what the game actually uses

**One game tick = one display refresh = 18.28ms.** The T-Unit runs at
**54.7068 Hz**, not 60 - measured straight from MAME's driver
(`refresh_attoseconds` = 18,279,250,000,000,000). Confirmed behaviourally:
a lane at `sleep 4` holds each row for exactly 4 MAME frames. Anything that
says 16ms or 60Hz is wrong and will drift ~9% over a long sequence.

An animation's speed is its **sleep** (ticks per row), so `fps = 54.7 / sleep`:

| sleep | fps | what the game uses it for |
|-------|------|---------------------------|
| 1 | 54.7 | `jade_boomerang_proc`, `fanp_ani_ready`, `do_smoke_speed` |
| 2 | 27.4 | **spins** (`do_spin`, `do_hh_spin`), projectiles, `explode_piece` |
| 3 | 18.2 | strikes, blocks, most reactions |
| 4 | 13.7 | strikes, reactions, drone walking ? **the most common value** |
| 5 | 10.9 | `r_sweep`, heavier reactions |
| 6 | 9.1 | victories (`sa_victory`, `generic_victory_ani`) |
| 8?10 | ?6.8 | fatality beats and holds |

Sleep 3?4 is 58% of all `mframew` sites and 73% of `animate_a9` sites.

**MK2 changes rate WITHIN a move** - it does not run a long lane at one speed.
`do_wheel_kick` is 4 then 3, `do_kintaro_fatal` 3 then 10, `jc_headhole_fall`
6 then 10. `mframew_a0` takes `a0 = [sleep,rows]` and leaves `a9` on the next
row, so segments chain; `sahp_walk_rate` (MOVES.ASM) walks a
`.word sleep,rows` table that way.

```
python tools/anim_timing_survey.py     # re-derive the table above from source
```

Three ways the hold reaches the animator:
`animate_a9`/`animate2_a9` take `a9 = [sleep:16 | ani_index:16]`;
`mframew` takes `a0 = sleep`; `init_anirate` + `next_anirate` take
`a0 = ticks per frame`.

**IMGTOOL lanes**: a `.wvp` row is one *preview* tick, not a game tick. The
sleep is `round(54.7 / state.fps)`; `tools/wvp_to_lane.py` derives it and warns
when the ratio isn't a whole number. Authoring at 13.675 or 27.35 fps makes the
preview match the game exactly.

### Move inputs ? `combo_edit.py`
Edits special-move input patterns (`scom_*`) in MOVES.ASM / MKBABY.ASM. 83 combos
(friendships were removed 2026-09-20 - see `doc/FRIENDSHIP_REMOVAL.md`).
```
python combo_edit.py list                            # all combos with trigger button + sequence
python combo_edit.py show scom_jc_shoruken           # decoded pattern, facing-right + facing-left
python combo_edit.py set scom_jc_shoruken back back  # change inputs (oldest-first, tool reverses)
python combo_edit.py window scom_jc_shoruken 0x30    # change time window (ticks, 0x10=256ms)
python combo_edit.py restore                         # revert all edits
```
**Input tokens** (case-insensitive): `fwd`/`forward`/`f`/`right`, `back`/`b`/`left`, `up`/`u`, `down`/`d`, `hp`, `lp`, `hk`, `lk`, `block`, `skip`.

Trigger BUTTON (HP/LP/HK/LK/BLK) is not in the combo table ? it's in the handler that calls the combo (e.g., `jc_hi_punch` ? HP). Changing which button fires a move means editing MOVES.ASM move handlers, not combo_edit.

### Rebuild + test cycle after editing
```
python build.py && python makerom.py && python makevrom.py && python makesound.py && python mamerom.py --source-video
.\mame.exe mk2                         # test (use -debug for live patching)
```
(`makesound.py` only matters after sound edits, but it's cheap and safe to
always include - it no-ops via DCSEncoder if nothing changed.)
`"mk2.zip"` is the retail ROM in the repo root (merge mode: our program+video ROMs + retail sound).

### Dual-ROM build ? test vs retail (build_all.py)
Produces two separate ZIPs from one command:
- `rom/mk2_test.zip` ? `test_mode=1`: boots straight into a fight, skips attract/select
- `rom/mk2_retail.zip` ? `test_mode=0`: normal game

```
python build_all.py "mk2.zip"                       # build both, install retail to MAME
python build_all.py "mk2.zip" --install-test        # build both, install test build
python build_all.py "mk2.zip" --no-install          # build both, don't touch MAME
python build_all.py "mk2.zip" --test-only           # test ROM only
python build_all.py "mk2.zip" --retail-only         # retail ROM only
```

**How it works**: full Phase A+B+C build for test, then `build.py --asm-only` for retail. The second pass skips LOAD2, re-promotes/syncs the existing `tmp/load2` snapshot, then GMAKE reassembles affected objects and relinks. MKAMODE.ASM is restored to its original `test_mode` value when done.

Quick swap after both are built:
```
copy rom\mk2_test.zip   C:\MAME\roms\mk2.zip   # switch MAME to test build
copy rom\mk2_retail.zip C:\MAME\roms\mk2.zip   # switch MAME to retail build
```

**Test ROM config** (top of `src/MKAMODE.ASM`):
```asm
test_mode       .set    1       ; 0=normal  1=skip attract, boot straight into fight
test_p1_char    .set    ft_reptile  ; P1 character (ft_* equates in MAINEQU.ASM)
test_p2_char    .set    ft_reptile  ; P2 character
test_p2_human   .set    0       ; 0=P2 is AI drone  1=P2 is human
test_stage      .set    0       ; stage index (0=Dead Pool)
```
Character equates: `ft_hathead=0 ft_kang=1 ft_cage=2 ft_sa=3 ft_fn1=4 ft_fn2=5 ft_st=6 ft_raiden=7 ft_subzero=8 ft_reptile=9 ft_scorpion=10 ft_jax=11 ft_goro=12 ft_final_boss=13 ft_smoke=14 ft_noob=15 ft_jade=16`

### MAME Lua test helper (mk2_test.lua)
Automates fight setup without manual menu navigation. Load alongside any ROM variant:
```
mame.exe mk2 -lua mk2_test.lua
mame.exe mk2 -lua mk2_test.lua -debug -debugscript mame_watch.ds
```

Hotkeys (while MAME window is active):

| Key | Action |
|-----|--------|
| `Ins` | Kill P2 to 1 HP (FINISH HIM fires immediately) |
| `Home` | Snap P1 to close fatality range (60px) |
| `End` | Snap P1 to far/sweep range (110px) |
| `PgUp` | Dump full game state to console + `mk2_test_log.txt` |
| `PgDn` | Toggle auto-drain ? keeps P2 at 1 HP every frame |
| `Del` | Run queued input sequence (if configured) |

On first run, `mk2_test_log.txt` lists every MAME input port and field name. Set `CFG.p1_port_tag` and `CFG.sequence` in the script to enable automatic fatality input replay.

Address table in `mk2_test.lua` uses TMS34010 bit addresses from `mk2.map`. After any rebuild that shifts RAM layout, update with:
```
python sym_resolve.py --dump | grep <symbol>   # get new bit address
# MAME byte addr = bit_addr // 8
```

### Crash debugging ? `sym_resolve.py` + `gen_debugscript.py`
`sym_resolve.py` translates raw TMS34010 bit-addresses (from MAME registers, crash dumps) to source symbols:
```
python sym_resolve.py ff9c0eb0           # resolve a PC or register value
python sym_resolve.py b:19802            # resolve a saver/loadr byte offset
python sym_resolve.py --stack w0 w1 w2  # walk a stack dump
python sym_resolve.py --dump            # list all symbols (raw map/BIT addresses)
```

`gen_debugscript.py` writes a MAME `-debugscript` that sets breakpoints on named functions:
```
python gen_debugscript.py r_head_pop decapped_head --crash   # watch + crash traps
python gen_debugscript.py --all-fatalities                    # every do_* entry point
python gen_debugscript.py --wp 0x225550 2                     # add a memory watchpoint
mame.exe mk2 -debug -debugscript mame_watch.ds
```
`--crash` adds watchpoints on TRAP0 (illegal instruction), TRAP4 (divide by zero), null writes, and low-stack conditions. Output file is `mame_watch.ds` by default (`--out <file>` to override).

### Live patching without rebuild (for hitbox tuning)
```
# In MAME debug (press ~ or use -debug flag):
saver stk.bin,0x19802,0x11d0,:maincpu           # dump current strike tables
# edit, then:
loadr stk.bin,0x19802,0x11d0,:maincpu           # reload, takes effect next hit
w@<f_colbox>=3                                  # hit/hurt box overlay on (see below)
```
`hitbox_info.py` recomputes these addresses after any rebuild - run it if the build changes.

### Hit / hurt box overlay - `f_colbox`
CPU-drawn **outlines**, plotted straight into the frame buffer by `geo_pass`
after the DMA drains, so the boxes sit on top of the fighters without hiding
them. Built on the geometry pass from
[doc/UNUSED_GRAPHICS_PRIMITIVES.md](doc/UNUSED_GRAPHICS_PRIMITIVES.md) S5;
the model it draws is documented in [doc/HITBOX_MODEL.md](doc/HITBOX_MODEL.md).

`f_colbox` is a **bitmask**, and bit 0 keeps its original meaning, so anything
that already pokes `f_colbox=1` is unaffected. The hitbox and the hurtbox are
deliberately different colours - reading one against the other is the point:

| bit | value | shows | colour |
|-----|-------|-------|--------|
| 0 | 1 | **hitbox** - attacker's strike box, on its active frames | red |
| 1 | 2 | `cb_body` - the sprite SILHOUETTE. **Not** what decides a hit | green |
| 2 | 4 | **hurtbox** - the box the compare actually tested against | white |
| 3 | 8 | anipoint crosses + `ground_y` / repell threshold | blue / purple |
| 4 | 16 | **every multipart piece boxed separately** (evaluation layer) | yellow |

**`f_colbox=5` is the one you usually want**: hitbox + the box that decides
the hit, with the green silhouette off so it is not drowning them. The green
box is the biggest thing on screen and the least meaningful - it is the
bounding box collision *starts* from and then narrows to the white column.

`f_colbox=5` is hitbox + hurtbox (the useful one); `7` adds the silhouette so
the squeeze is visible as the gap between white and green; `15` is everything
cheap; `18` is silhouette + per-piece.

**Bit 4 costs frame time** - it takes `peak_overload` from 4 to 35 and can
change how a fight plays out (`kang_jax_deadpool`: 3/3 PASS at mask 3, 0/3 at
mask 18). Use it to look, never while measuring or during a sweep. The gap between the green box and the white
one is `sq_punch`'s squeeze - it cuts the victim to a **quarter** of his width
on 205 of the 223 strike records.

**Look the address up - it moves.** `f_colbox` is `.bss`, so it shifts
whenever anything ahead of it in RAM changes size. Never hardcode it:

```
python sym_resolve.py --dump | grep f_colbox     # e.g. bit 0x010f87f0
```

Lua `space:read/write` take that **raw map address**; the MAME debugger's `w@`
takes it **divided by 8** (`0x010f87f0 >> 3 = 0x21f0fe` at time of writing):

```
w@0x21f0fe=3                                     # debugger: hitbox + hurtbox
mame.exe mk2 -autoboot_script tools/hitbox_overlay_test.lua   # rig: fight + overlay + shots
HITBOX_MASK=7 mame.exe mk2 -autoboot_script tools/hitbox_overlay_test.lua
```

Compile it out entirely with `hitbox .set 0` in `src/MAINEQU.ASM` (needs
`geoline .set 1` in `src/MKDISP.ASM`). Full details, including why a rig must
capture on the frames a strike box is *parked* rather than on a fixed offset,
are in [doc/UNUSED_GRAPHICS_PRIMITIVES.md](doc/UNUSED_GRAPHICS_PRIMITIVES.md)
S5 "Turning it on".

**Drawing with the CPU?** Read S5's *"the colour map applies to CPU writes
too"* first. A CPU pixel is OR-ed with the DMA colour-map latch (`dmacmap`) on
its way to VRAM, so it comes out of whichever palette the last sprite of the
frame used - a correct picture in the wrong colour. `geo_list` records carry
the map in bits 16-31 of the colour long; 0 = `boonpal`.

### MAME debugger address spaces ? TMS34010 is mixed
Confirmed through experimentation:
- **`saver` / `loadr`** use BYTE offsets into `:maincpu` region (the 1 MB ROM block): e.g. `0x19802`
- **`w@<addr>=val` memory-write** uses BYTE addresses: `w@<bit_addr/8>=1` hits f_colbox
  (the literal number moves every time .bss shifts - resolve it, never copy it)
- **`wpset` / `bpset` / `print w@addr` in CPU context** use the TMS34010 native BIT addresses and BIT lengths: `wpset 112aa70,10,w` watches p2_bar (bit addr, 16 bits)

Practical rule: if you're using `saver`/`loadr`/`w@addr=`, use byte addresses (mk2.map bit addr / 8). If you're using `wpset`/`bpset`, use the raw bit address from mk2.map with length in bits.

### Watch live damage per player
```
# P1 loses HP:
wpset 1129ea0,10,w,1,{printf "P1 hit: -%d", w@1129ea0 - wpdata; g}
# P2 loses HP:
wpset 112aa70,10,w,1,{printf "P2 hit: -%d", w@112aa70 - wpdata; g}
# Clear when done:
wpclear
```
Addresses from `mk2.map` ? `p1_bar` / `p2_bar`. Max HP = `0xA1` (161, not 100).

### Other modding notes
- **Custom gfx**: any sprite change forces a full rebuild (video ROM addresses shift, program ROM tables change). No quick-swap possible.
- **Extra gfx space**: REVX/program-ROM space is reserved and off limits for
  normal PIXBLT sprites. Use the fixed image-ROM wrappers documented in
  `doc/CUSTOM_CONTENT.md` and `doc/ASSET_SPACE_LEDGER.md`.
- **Wolf-unit port** (`wunit`, `src/WUNIT.ASM`, 0 = T-unit): Asure007's Wolf deltas carried as `.if wunit` blocks - **never run his `gow.bat` here**, it copies whole headers over ours. Both boards assemble and link; T-unit output is byte-identical. GSPA cannot re-`.set` a symbol to a new value in one file, so a Wolf value goes in an `.if/.else`, never an override. **GAME CODE READS INPUTS FROM `@gsw` / `@gsw2`, NEVER `@switch` / `@switch2`**: Wolf swaps the high halves of the two input longs, so on Wolf `gsw`/`gsw2` are RAM copies rebuilt into the T-unit layout every frame (`wolf_inputs`, MKINIT.ASM); on the T-unit they are aliases. A new `@switch` read is a Wolf-only bug the T-unit build cannot show. Diagnostics (interrupts off) keep the real ports. `python makewolf.py` (after the T-unit pipeline) builds `rom/wolf/umk3.zip` in a private `tmp/wolf/` copy - never touching `src/mk2.out` or `C:/MAME/roms/umk3.zip` - and it boots, takes coins and plays sound in MAME (`mame umk3 -rompath rom/wolf`; rig `tools/run_wolf_boot_probe.ps1`). Custom audio is patched onto `sound/wolf/` and all 1,124 tracks decode identical to the T-unit set. Inputs proven by `tools/run_wolf_boot_probe.ps1 -Inputs` (13/13, `-Negative` 0/13); the power-up self test passes end to end (`makewolf.py` lands u54/u63 on cksum1/cksum2 and syncs the video sums in its own copy). **Any MAME launch in a rig needs `-keyboardprovider win32 -video gdi`** or the red ROM box waits for the user. Space per board: [doc/WOLF_SPACE.md](doc/WOLF_SPACE.md). **On Wolf the VS portraits are read from IMAGE ROM** (video `0FC0000h`, CPU `05E00000h`, image bank 1 via `sysctrl` bits 8-9 - `UNZIP.ASM` `vs_base`/`vs_dest` + the `movie_run` wrapper), which frees the 204 KB REVX pool: Wolf program headroom is ~210 KB against the T-unit's 8 KB. Wolf-only art goes in `makevrom.py`'s `wolf_irw_files` (bank-1 LODs whose `***>` line is `4000000,1`+, LOD form); content plan in [doc/WOLF_CONTENT_PLAN.md](doc/WOLF_CONTENT_PLAN.md). See [doc/WOLF_UNIT.md](doc/WOLF_UNIT.md).
- **Wolf: what the board adds, and what is used** ([doc/WOLF_OPPORTUNITIES.md](doc/WOLF_OPPORTUNITIES.md)). The Wolf blitter is the T-unit's (MAME: same `dma_w`/`dma_draw`, 41 ns a pixel) - Wolf adds MEMORY. **The 12 character endings play on Wolf** (`data/ENDWOLF.LOD`, image BANK 2 at CPU `04400000h`, `zipped_pics` 16h-2Dh, `movie_run` picks bank 2 for `wolf_end_cpu..wolf_end_end`; backgrounds MKSTORY1/2 in `WSTORY.LOD`; TEST MENU -> UTILITIES -> CHARACTER ENDINGS). **The colour-map plane is SYSCTRL bit 11 on Wolf, not 5** - `mapplane` (MKDISP.ASM); `run_palrect_test.py --game umk3` proves it. **`mk2wolf.exe` loads the 12 empty UMK3 video sockets** (u117-u114, u109-u102 as `mk2wolf_video_rom_uNNN`; `makevrom.py WOLF_EXTRA_BLOCKS`; `tools/make_wolf_video_pattern.py --extra` + `wolf_video_hi_check.lua`, stock MAME is the control). **Both boards:** `stckst` is `013F72F0h` (`.bss` has ~355 KB under the guard, was ~31 KB), and `cpumeter` (MPROC.ASM) gives lines per process pass, and the display meter (`dqi_*` dirq, `dqs_*` shadow block, `dqd_*` blitter drain point; MKINIT/MKDISP) splits the rest - `run_runtime_budget.py` reports all four. Fights: logic **4-10%**, display interrupt 48-93 lines of 289, and the blitter busy until 54-73% of the frame (83% at the Tower's worst): **the blitter is the tight budget, the CPU is mostly idle** ([doc/PERFORMANCE.md](doc/PERFORMANCE.md) 3b). Every stage on both boards (3c): 54+ lines of headroom except **KAHN'S ARENA, 17-23 - its heat haze costs ~90 CPU + ~100 blitter lines a frame** (A/B `--poke f_skyrows_off=1`); `sky_rows` now keeps its per-frame constants in b0-b5 (NOT b6/b7 - the nested shadow code uses them bare) and reads a 16-row haze table, pixel-identical, headroom 17 -> 34. Merging still sky lines into one blit was tried and measured WORSE (the 40-px overhang per row costs more than a queued blit's overhead) - not shipped.
- **MAME CRC mismatches**: expected. Source-built ROMs differ from retail dumps. Listen for the **single "bong"** at boot ? that's the game's internal checksum passing, which means the ROMs are actually good despite MAME's external CRC complaints.
- **Debug damage watching**: in MAME debugger, `wpset <health_addr>,2,w,{printf "%d",<val>; g}` prints damage each hit. Beats building an in-game overlay.

## Known behaviors
- **MK1 KANO (Wolf, Shang's morph, ochar 22) MOVES, IS HIT AND IS KNOCKED
  BACK THE WAY MK1 DOES IT** - all measured in MAME `mk`
  (`tools/mk1_kano_timing_probe.lua`, `MK1T_WHO=kano|sonya|whiff|range|reach|duck`,
  read with `tools/mk1_kano_timing.py`) and compared tick for tick against the
  Wolf ROM (`tools/wolf_kano_timing.lua` `KT_WHO=kano|jax`,
  `tools/kano_timing_compare.py`). Everything is `.if wunit`.
  **HIS ART IS LAID OUT THE WAY MIDWAY LAID OUT EVERY MK2 FIGHTER** (2026-10-11,
  the user's call; `tools/make_mk1kano_port.py --rip`): every frame carries
  **LIU KANG'S NAME** from MKLK.ASM's frame list (`LKSTANCE1-7` ->
  `KNSTANCE1-7`, `LKHIKIK1-6` -> `KNHIKIK1-6`...), as a **SOLID record** (the
  whole frame, never packed) **plus its SUBFRAMES** `KNSTANCE1A/B/C` - exactly
  as many as Liu Kang's frame has, cut by IMGTOOL's Auto Split
  (`kano_subframes.auto_split`: one cheapest vertical-or-horizontal cut,
  repeated) - in the library Liu Kang's is in (`KANG<n>` -> `KANO<n>`). Solids
  first, then pieces, as CAGE1-10 are. A frame is filled with the MK1 pose
  ROWS/FIXED map onto it. **Specials are moves of their own**
  (`KNKNIFETHROW1-5`, `KNKNIFE1-13`, `KNKNIFEHIT1-3`, `KNBALL1-8`, `KNBALLGO1`,
  `KNHEARTRIP1-8`, `KNHEART1-7`; `OWN_MOVES`), cut freely; an MK1 pose his
  MK1-timed normals play with no Liu Kang frame is re-pointed to the nearest
  pose of that lane that has one. **The fatality-victim rows MK1 never drew**
  (TABLE1 36h, 38h, 39h, 3Bh-3Dh, 3Fh-41h) are **BUILT OUT OF HIS MK1 ART**
  by `tools/kano_synth.py` (was Liu Kang's art recoloured): other poses of his
  (nut crunch 2Eh, impale 41h + belly wounds, drain 4Dh), **MK1's own headless
  body** (lane 4Fh 1-7, cut at a hand-authored waist into DEADLEG/ERT_TORSO;
  only the LEGS carry the stump, capped outward so the joined DECAP is clean,
  as Liu Kang's is) and **MK1's severed head** (four rolling drawings at
  FFF04C40-D60, in no fighter lane) for the rolling head and the head hole;
  the back break BENT at the waist, the torso rip his upper half cut at the
  belt with entrails, then tilted. Each is placed where Liu Kang's frame sat
  relative to LIU KANG'S STANCE, moved onto Kano's stance - every finisher's
  offsets were tuned on that art. `--preview DIR` sheets Liu Kang's | Kano's.
  Recipes are in the tool; a frame with none falls back to Liu Kang's art.
  **THE SECOND BATCH (2026-10-13): the finishers' own animations** - per-fighter
  tables OUTSIDE TABLE1 had pointed Kano at whole Liu Kang animations (Jax's
  flying arm, Sub-Zero's deep freeze + legs and head rip, Kung Lao's split,
  Mileena's suck, the Pit fall, Shang's drained husk, Kahn's slam / soul rip,
  Raiden's lift, the babality). `EXTRA` in the port copies each Liu Kang lane
  into MK1KNL.ASM under a `kn_` name on Kano frames that `Synth.extras` builds
  (ANCHOR-to-anchor placement - these are objects the code lines up on an
  anchor), and `wolf_fighter_rows`' KANO dict points his rows at them. The
  frozen body is his frontal stance re-indexed into `FREEZE_P` by brightness,
  **only into the ice entries Liu Kang's art uses** (FREEZE_P carries a magenta
  at 55); the split's seam is his head's centre column because the game MIRRORS
  the left half about the anchor for the right; the drained husk and Kahn's
  soul get generated palettes (`KNDRAIN_P`, `SOULGRN_KN`). **Sub-Zero's deep
  freeze clamped every ochar past Rain to JAX's frozen body** (and then drew the
  proxy's legs) - `r_super_freeze` now takes the five Wolf rows
  (`ft_rain+5*wunit`). Still Liu Kang's: the two X-ray skeleton steps of
  Raiden's lift (`LUBUZZ2W`).
  **Two per-victim tables are measured off HIS art, not copied from Liu
  Kang** (wolf_fighter_rows takes a CALLABLE override for them, so the
  generator and its own --check write the same line): Cage's brain punch
  `jch_place` (Liu Kang's row moved by where Kano's head sits in HOLE1,
  `cage_brain_wax_import.kano_row`: -70,6 vs -71,2) and Shang's blade
  `stdc_place` (`st_decap_lineup.kano_d`, his own wound: 70 vs 61). The
  impale frames line up on his BELT (Baraka parks the victim anchor to
  anchor), wounds in the stomach.
  **Every MK1 picture of him the port does not show as-is** - unused lane
  frames, the whole 4Fh drawings, the heads, and an unreferenced 7-piece crouch
  (FFEF3520-3760) - is in `data/MK1KNRES.IMG` (`tools/make_mk1kano_res.py`,
  no LOD, not in Phase D). His art is found by PIXEL address (three SAG runs),
  never by header address - every fighter's headers interleave.
  The hit reactions lost MK1's 4th pose (Liu Kang's lane has 3 names). **One
  pose under two names costs nothing: LOAD2 FOLDS identical records onto one
  SAG** (73 of 568), so a rig mapping SAG -> name must keep every name
  (`wolf_kano_moves_check.lua` `SAGNAMES`). **The libraries are the source**:
  repaint or re-cut (pieces are `<name>A..Z`) in IMGTOOL, then `--lod` + full
  build; only `--rip` rewrites them. Pack 569 KB in 0xEB4000-0xF80000 (266 KB
  free; WSTORY/UPPROF moved up to make room).
  **His normals are SCRIPTS, not Liu Kang's lanes at Liu Kang's speeds**: every
  MK2 normal opens `callr init_special`, whose tail on Wolf is `kn_isp_tail`
  (MK1KNM.ASM); for Kano it reads the return address on the system stack, and
  if that is just past the `callr` at the top of a `do_*` that `kn_normals`
  lists (high/low kick, elbow, knee, uppercut, both duck kicks, sweep,
  roundhouse) the `do_*` never resumes - `kn_normal` plays MK1's frames and
  `retp`s to whoever jsrp'd it, human or CPU alike. A frame holds its WHIFF ticks
  until the move connects and its HIT ticks from then on (MK1's hit pause:
  HK 6 -> 20, uppercut 7 -> 49). The scripts, and his reaction scripts, are
  generated by `tools/make_mk1kano_port.py` (`NORMALS`, `REACTS`) - edit there.
  Duck kicks go through `kn_duck_kick` (JOY.ASM), which skips MK2's own
  sleep-and-retract tail. Punches stay Liu Kang's lanes (they already matched).
  **His boxes are `kano_strikes`** (MK1KNM.ASM; strike-table row 22 via
  `wolf_fighter_rows.py`): Liu Kang's records with the FRONT moved out to MK1's
  measured reach (largest connecting gap; a gap of N px is ~N+79 between
  anchors, minus the ~8 px squeeze column). His close range is 05ah, not 040h
  (`kn_close_reach`, JOY.ASM), and HOLDING AWAY is never close - MK1 sweeps
  point blank.
  **Knockback**: `kn_knock_scale` at the top of `away_x_vel` (MOVES.ASM) gives
  a REACTING fighter's process 5/8 when he is Kano or his attacker is, and 7/16
  for an uppercut ON Kano (`p_hitby`). Jumps and flips are not reactions and
  are untouched (`kn_mk1_jump` sets those). **A ROUNDHOUSE, either way, is
  MK2's knockdown at MK2's full distance** (the user's call, 2026-10-10: MK1
  staggers Kano instead, 55 px, and that was built and reverted) - `p_hitby` =
  `act_rhouse` skips the scale. **A high kick on Kano plays MK1's big-hit
  stagger** (`kn_hikicked`, from `hikicked_entry`), stopping his slide
  with a `stop_me` command in the script; **a sweep plays MK1's six-frame fall**
  from `r_sweep`. Row 16h's lane is NOT changed for that - Jade's impale and
  the double knee pick frames out of it by position. Measured against MK1:
  every one of his attacks frame-exact; HK dealt 54/52, LK 30/32, uppercut
  92/86, duck kick 30/30; received HK 67/65, LK 34/36, uppercut 66/60.
  **HIS THROW IS MK1's OVERHEAD TOSS, DONE STANDING** (2026-10-10): lane 1Eh
  grab 2 | 3,4,6 | 5 held (`OWN_LANES` in `make_mk1kano_port.py`), the victim
  on BARAKA's "flipped by" lane + `tossed_flight` (`body_slam_init`, MKSLAM.ASM,
  ochar 22 -> `ft_sa`), generic grab/throw voices (`body_slam_jumps` row 22 =
  `normal_slam` via `wolf_fighter_rows.py`). It used to be Liu Kang's monkey
  flip, which ends on his back and jumps to the get-up - Kano dropped to the
  floor - with the victim on Kitana's lane. Rig `tools/wolf_kano_throw_capture.lua`.
  **THE HEART RIP IS SWITCHED OFF** (`knheart .set 0`, MK1KNM.ASM, 2026-10-10,
  the user's call): `kn_lo_punch` goes straight to `kn_none`, so Back, Down,
  Forward + LP in FINISH HIM does nothing. The code, art and sounds are kept;
  `knheart .set 1` brings it back, and `wolf_kano_heart_check.lua` will fail
  until then. What it does when on: (`do_kn_heart` / `kn_heart_victim`): the victim is held on
  STUMBLE2 (anitab1 023h, second frame), lined up by `kn_heart_line` so the
  fist ends `kn_heart_in` (15) px inside his near edge - measured off both
  drawings with `mpart_bounds`, MK1's is 11-15 - and given the standard
  held-victim shake (2 px diagonal, 3 ticks a half, 8 times, as Sub-Zero's
  head rip). He keeps his OWN palette: `change_to_bloody_pal` on a standing
  pose is the wrong colours in the wrong places. The heart sheds a
  `spawn_drip` glob on every lub and dub (`kn_heart_drip`; `spawn_drip` is
  `.globl` in MKBLOOD for it). Rig `tools/wolf_kano_heart_check.lua` asserts
  the depth, the palette, the drips and the beats.
  **HIS FLIP IS 4.0 PX A TICK ACROSS, NOT MK1's 4.15**: the camera's speed is
  the first `right_scrolls` row >= the fastest fighter, 4.15 has no row, so it
  took the 6 px one, outran him and stopped, over and over - the screen shook
  on every flip. Any new x velocity has to be a row of that table.
  **The cannonball sounds as MK1's does**: 8Ah (curl whirr) and 8Bh (launch)
  and NO voice - the DCh "yell" the first port played was not MK1's. Held,
  the curl TIMES OUT 128 ticks after 8Ah (`kn_ball_hold`; measured with
  `run_mk1_kano_probe.ps1 -TwoPlayer -BallTest -BallHold 900`). The whirr is
  stretched to exactly 128 ticks (`MK1_HOLD_TICKS`, make_wolf_audio.py) and
  goes out on a KNOWN channel (`triple_sound2_onch`, MKSOUND.ASM, Wolf only),
  and 8Bh is sent to that channel so the launch cuts it. Rig
  `tools/wolf_kano_ball_sound_check.lua` (tap / hold60 / hold200 PASS; `NEG=1`
  FAILS). **The sweep has no knockback to scale** - `r_sweep` gives no
  x velocity; a 9-vs-18 reading is the falling POSE's drawn middle. **MK1's
  Down+HK and Down+LK knock back the same** (20-38 px with spacing); an early
  "6" was an outlier. Regression rigs: `wolf_kano_moves_check.lua`,
  `wolf_kano_mk1_check.lua`, `wolf_kano_heart_check.lua`.
- **BACK-BLOCK IS A DIPSWITCH: MAME's "Comic Book Offer"** (raw mask 0x0800,
  `dip_backblock` 0010h in DIPEQU.ASM's read_dip order). The comic offer is
  never shown - every `advertise_comic` call in MKAMODE is commented out - so
  its switch was free. **On (MAME's default) = holding away blocks; Off =
  button only (retail).** MAME's DIP menu still says "Comic Book Offer" (the
  name lives in MAME's driver); the service menu's DIP page reads BACK BLOCK
  ON/OFF. `dipinit` (MKINIT) caches it into `f_no_bkblk`, so a change takes
  hold on reset or on leaving the service menu, and `is_he_blocking` (JOY)
  reads the word on each hit. `backblock .set 0` (MAINEQU) still compiles the
  whole feature out, switch or no switch. Netplay: both peers must have the
  same setting or they desync. Rig: `tools/run_backblock_dip_test.ps1`
  (private cfg/nvram; on and off both PASS - away is chipped 9/9 vs hit 9/9,
  with Block-held and no-input controls unchanged).
- **WHICH HIDDEN FIGHTERS ARE PLAYABLE IS AN OPERATOR SETTING**: TEST MENU ->
  GAME ADJUSTMENT -> HIDDEN FIGHTERS (`do_hidlock`, DIAGADJ.ASM; cmos slot
  `adj_hidlock` 24, DIAGAUDN.ASM). There is no separate "debug menu" in this
  ROM; this is the operator menu. Eight values, every combination of Jade /
  Ermac / Rain down to NONE. **Stored as a LOCK mask** (bit 0 Jade, 1 Ermac,
  2 Rain), so the untouched-cmos 0 is the default, all three, and
  `hidlock_msglist` is in mask order. `dipinit` (MKINIT.ASM) clears the
  matching `f_jade_unlocked` / `f_ermac_unlocked` / `f_rain_unlocked`
  (MOVES.ASM; Rain's is new, `.globl` beside it, not in MAINEQU) AFTER
  warmset's `hidden_unlock_init` has set the build's ceiling, so it can only
  take a fighter away. Those flags already gate the select screen's START tap
  (`mst_up` -> `hidden_unlocked`) and Shang's morphs; Rain's chord morph now
  asks too. Leaving the service menu is a warmset, so a change takes hold
  without a power cycle. Netplay: both peers need the same setting, as with
  BACK BLOCK. Rig: `tools/hidden_fighters_adj_test.lua` (`HF_STEPS` Up
  presses = the mask; run on a PRIVATE `-nvram_directory`, then boot
  `tools/ermac_start_toggle_test.lua` on the saved cmos to prove the select
  screen - Rain locked: `-Mode inert -Target rain` PASSes and fails on a
  factory cmos). **MAME re-runs an autoboot script on `soft_reset`** - the rig
  guards with `_G.HF_LOADED`, or the second copy truncates its log.
- **JADE, ERMAC AND RAIN ARE EARNED, AND STAY EARNED** (`hidearn`,
  MAINEQU.ASM, 2026-10-05). A HUMAN winning a match against the CPU: **Jade
  -> Jade, Shao Kahn -> Ermac, Smoke -> Rain**. `results_of_round` (MAIN.ASM)
  calls `hidden_earn_check` (MKINIT.ASM) on the match-winning round with the
  loser's ochar; it requires the winner on the sticks and the loser NOT (so
  attract mode and 2P earn nothing) and `hidden_earn` sets the bit in RAM
  (`hid_earned`, MOVES.ASM, `.globl`) AND in cmos slot `adj_hidearn` 25. A
  fighter is pickable / morphable only if the operator allows him (HIDDEN
  FIGHTERS, above) AND he is earned, **or `f_netplay` is set** - online, all
  three are earned so two cabinets' cmos can never disagree about a START
  tap. Read at USE time, because the host writes `f_netplay` after boot.
  **`hidden_unlocked` (MOVES.ASM) is the ONLY reader** - the three Shang
  morph sites used to read the flags directly and now call it; never read
  `f_*_unlocked` alone again. GAME ADJUSTMENT -> FIGHTERS EARNED
  (`do_hidearn`) shows / grants / clears the mask (an ALLOW mask, 0 = none;
  its names are `hidlock_msglist` read backwards). A factory restore clears
  it - and **so does every new build**: `powercmos` runs on every warmset and
  a changed `rom_name` fails `check_name_and_rev` -> `fac_set`. If the
  adjustment checksum is already bad, `hidden_earn` writes RAM only rather
  than re-checksum garbage. **Trap that cost a run: `form_adc` RETURNS THE
  CHECKSUM IN a1** - load the value after it, or `put_adj` stores the
  checksum (the first cut saved 0xFE0B). `f_adc_s` leaves the adjustment
  page selected; `def_page` after it. Rig: `tools/run_hidden_earn_test.py
  --rom <dir> --map <mk2.map>` - five cases on fresh private nvram, each
  wins a real match and requires the mask after the match AND after a
  `soft_reset` (which clears .bss, so the second read is cmos): jade 1, kahn
  2, smoke 4, controls jax 0 and lose 0. **`run_ermac_start_toggle_test.ps1`
  DELETES `C:\MAME\nvram\mk2`** - with unlocks in cmos that is the user's
  progress; drive `ermac_start_toggle_test.lua` on a private nvram instead.
  `st_hidden_morph_test.lua` now grants the mask (7 unlocked, 4 locked).
  **ON for the T-unit since 2026-10-13** (`hidearn .set 1-wunit`, the PLAYTEST build, `rom_name` "REV 4.0 - PLAYTEST"); Wolf keeps all three from power-on. `hidearn .set 0` = all three from power-on.
- **ERMAC'S TELEKINETIC SLAM IS GATED THE WAY UMK3 GATES IT** (`ermtkgate`,
  MAINEQU.ASM; the gate in `ermac_hi_kick`, MOVES.ASM, and the stamp in
  `do_ermac_teleslam`, MKSLAM.ASM). Reported by a player: "ermac is able to chain
  consistantly with his teleport then teleslam, even with a four hit push back he
  can teleport out of that and continue the chain" - and then, of my first fix,
  **"the teleport just doesnt connect, it should connect in a combo maybe once or
  twice, what does umk3 do"**.
  **THE LOOP WAS REAL AND THE FOUR-HIT PUSH BACK NEVER RAN.** The attacker spends
  25 ticks and the victim ~140 (`act_ermac_tks` at t=24, `act_stance` at t=49), so
  the grab box closed on a man still reacting **every 50 ticks** with no teleport
  in it at all (`-Mode slamonly`, gaps `50 50 50 50 50 191 50`). And
  `r_ermac_teleslam`'s `dec_my_p_hit` plus the victim LANDING (which clears
  `p_hit`) left the counter oscillating 0<->1, so `phitmax` was 1,
  `no_unlimited_airhits` (`p_hit > 3`) was never reached and `sep` was 0 - nothing
  was ever pushing him away, which is why it read as escaping it. The teleport only
  reset the SPACING: the bounce walks the victim into the grab's own 100px dead
  zone and the teleport restores the gap.
  **MY FIRST GATE WAS TOO BLUNT** (`ermtkfree`, retired): it refused the grab on
  any victim in `act_reacting`, which broke the loop and also made a refused slam
  play its windup and eat the 48-tick whiff recovery.
  **UMK3 ALREADY HAS THE LIMITER - `q_ermac_slam` (MOVES.C:3764), two conditions:**
  `get_his_p_hit > 4` (`erm_tks_maxhit` 5 - so it may be the 1st through 5th hit
  of a string) **OR** `get_tsl(l_ermac_slam) < 0x80` (`erm_tks_cool` 128), and
  `stat_do_ermac_slam` stamps `l_ermac_slam` **THE TICK THE GRAB CONNECTS**
  (MKSTAT.C:134, ABOVE the `if (f_block) break`, so a BLOCKED catch starts it too)
  - a whiff stamps nothing. `l_ermac_slam` is UMK3's own RAM (MKGAME.H:821); the
  earlier claim that "MK2 has no such timer, so adding one would be a dead thing
  to keep in sync" was a miss.
  **`q_*` IS A QUALIFIER, so a refusal means the move never starts** - in MK2 that
  is `death`, i.e. an ordinary high kick, exactly as `ermac_hi_punch` falls through
  when `l_decoy` refuses the teleport. **That is the difference the player feels**:
  a refused slam is a high kick that CONNECTS for 24-32, not a punishable whiff.
  **A COOLDOWN WORKS HERE ONLY BECAUSE IT IS STAMPED ON THE CONNECT.** The earlier
  note that one "would only slow it down" was reasoning about a timer stamped at
  the ATTEMPT; 128 from a connect outlasts both the 50-tick re-grab cadence and the
  ~105-tick teleport+slam alternation, and costs a miss nothing.
  **THE HIT CAP IS INERT IN MK2, AND THAT IS MEASURED.** The grab box opens ~24
  ticks after the input and P1's own recovery adds more, so the victim has always
  left `act_reacting` by then: **48** ticks after a teleport punch, **72** after a
  high kick, **91** after an uppercut - and slam->slam is gated by the 128 against
  a reaction that lasts only **91**. So his `p_hit` is 0 at every real connect and
  the cap is reachable only by seeding (`-Mode cap`). Ported because it is UMK3's
  rule and would bite if the startup or the stun changed, not because it fires -
  the same shape as the throw payloads. **It also corrects an arithmetic claim of
  mine**: he is helpless ~140 ticks to being ACTIONABLE but leaves `act_reacting`
  after 91, so 128 sits ABOVE that, not under it.
  **IT IS PREVENTED ENTIRELY, NOT FIRED-AND-WHIFFED, and that is asserted on the
  ACTION CODE** (`-Mode cool`): after a connect the move does not START again for
  exactly **128** ticks (3 presses offered and refused) where the ungated control
  restarts at **40**. Gaps between connects cannot tell a refusal from a whiff,
  which is why that mode exists. Arm it only once Ermac's OWN slam has ended -
  `act_ermac_tks` is still set at the catch (t=24..49, catch ~t=34), so watching
  from the catch re-detects the slam that set the timer - and require
  `presses >= 2` or a late single press reads as the gate holding it off.
  **THE ONE CASE LEFT WHERE IT FIRES AND THE VICTIM IS NOT ANIMATED IS A BOSS**:
  `is_he_a_boss` is still tested INSIDE the active window, UMK3's own placement,
  so against Kintaro or Shao Kahn he reaches at a man who can never be grabbed.
  Moving it up beside the other two conditions would make the input a plain high
  kick; that is a deviation from the arcade and is NOT done.
  Measured: re-grab gaps 50 -> **137** min, victim actionable 128 -> **214**
  frames; cap fires at seed 0 and 4, refused at 5 and 6, where the ungated control
  fires at all four. `ermtkgate .set 0` is that control and both modes must FAIL on
  it. The move itself is unchanged (`run_ermac_teleslam_test.ps1`: `caught=true
  lift=208px damage=9 attempts=1 clock=63 held=true`) and the FATALITY never runs
  this path (`do_ermac_fatal_slam` reaches the victim through `takeover_him`). See
  [doc/ERMAC_TELESLAM_REGRAB.md](doc/ERMAC_TELESLAM_REGRAB.md).
  **AND IT IS SCALED LIKE ANY OTHER HIT** (`ermtkscale`, MAINEQU.ASM, needs
  `dmgscale`; `erm_tks_scale`, MKREACT.ASM). **IT NEVER CAME THROUGH `dmgscale`
  AT ALL**: `stk_ermac_teleslam` carries 00h hit damage on purpose ("the
  reaction applies its own") and `r_ermac_teleslam` applies it with
  `damage_to_me`, which jumps straight to `bar_reducer` - while `dmgscale` lives
  one branch earlier, in `strike_check`'s clean-hit path, because that is the
  only place `a13` is certainly the ATTACKER. So a slam landing fourth in a
  string was worth the same 9 as one landing first; measured, the old build reads
  **9 at every depth**.
  The curve is now **`dmgscale_a10`** (JOY.ASM, below `bar_reducer`): one copy,
  two callers, `a0`/`a1` preserved and `a10` the only register it touches. **The
  INDEX stays with each caller** because they reach the counter from opposite
  ends - `strike_check` has `a13` = the attacker and reads `p_otherproc`, where
  an opening hit is `p_hit` 0; `erm_tks_scale` has `a13` = the VICTIM, his own
  field, where **an opening hit reads 1** because `reaction_start` already
  counted the catch ~70 ticks before the impact applies the damage. **Take one
  off or an opening slam scales as the second hit** and lands for 7.
  `p_scalebias` is subtracted exactly as `strike_check` subtracts it.
  **`.globl` beside the definition in JOY.ASM + `.ref` in MKREACT, NOT a
  `.global` in MAINEQU** - ~70 objects include MAINEQU and MKDEATH is closest to
  GSPA's ceiling, so that would cost 70 symbol tables instead of 2.
  **`dec_my_p_hit` GOES WITH IT, and neither half is right alone.** Handing the
  hit back is sound while the slam is unscaled and is exactly what it now pays;
  scaling it while still handing the hit back would leave whatever FOLLOWS it
  unscaled instead, and the bounce and get-up are ~56 ticks of juggle window. It
  only ever mattered for that window - his feet are already down before the
  damage and `gravani` clears `p_hit` on the bounce's landing. It also resolves a
  contradiction (not measured on screen): `cmb_lifted` holds the combo window
  open across the flight precisely so a hit that follows him down CONTINUES the
  string, and `hud_combo_hit` decides "new string" off the `p_hit` that
  `dec_my_p_hit` had just put back to 0.
  Measured by depth (`-Mode scale -Seed 0..3`): **9 / 7 / 4 / 2** against 9 / 9 /
  9 / 9. The control fails three of four and **seed 0 passes on both**, which is
  what says the rig is not just failing everything. The re-grab modes are
  unchanged (`regrabs=0`, same bars) - correctly, since the rig's cadence makes
  every slam in that loop an opening hit.
  **Two rig traps**: the seed must STOP at the catch (the index is read at the
  IMPACT and must carry the catch's own `inc_p_hit` on top of the seed), which is
  also why `run_ermac_teleslam_test.ps1` still reports `damage=9` on the scaled
  build - its poke is gated on `not caught`, `caught` needs 20px of lift, so it
  overwrites the `inc_p_hit` for ~10 ticks past the catch. That is the rig's poke
  window, not the scaling failing. The other `damage_to_me` sites have the same
  hole and are deliberately left alone: they are the THROWS (`slammed_by_jx` 18,
  `_st` 24, `_cage` 34, the flip-damage table) and chip.
- **THE SPEAR'S FREE HIT KEEPS THE STRING'S DEPTH** (2026-10-06; `r_spear`,
  MKREACT.ASM). Reported: flip kick, teleport, spear, uppercut = 52%. The
  stun exemption wrote the victim's WHOLE `p_hit` into `p_scalebias`, which
  discounted the drag's ~15 phantom hits AND every real hit before the spear,
  so the uppercut - fourth hit - landed whole: 26 + 15 + 4 + **40** = 85. Now
  `r_spear` takes his effective depth on entry (`p_hit - p_scalebias`, in a10)
  and re-writes the bias as `p_hit - a10` after every pass of its loop, so the
  hit after the spear scales exactly as the spear did: 26 + 15 + 4 + **20** =
  65, 40%. A spear that OPENS a string is unchanged (free hit full). The two
  whole-count writes in MKZAP (`do_rope_pull`, `tugged_in_by_spear`) are gone;
  MAINEQU's `dmgscale` comment still says "whole p_hit" for the spear and is
  stale (MAINEQU is a GSPA cliff - not touched for a comment). **Sub-Zero's
  ice ball and floor ice still write the whole count** (`r_ice`,
  `r_floor_ice`) - the same hole, left as the documented ruling until asked.
  Rig: `tools/run_spear_dmgscale_test.ps1 -Seed N` (seed 0/2/3 PASS: free hit
  11/5/2 of an 11 jab; the pre-fix ROM FAILS seed 2 with 11). The rig now runs
  on PRIVATE nvram and kills nothing by name - **it used to delete
  `C:\MAME\nvram\mk2`**. Its third-hit check scales by the depth that hit
  SAW, because under `cmbrules` a jab hands its hit back.
- **A JAB LINKED INTO A NON-JAB COUNTS AS HIT 2** (2026-10-06; `jlk_out` in
  `strike_check`, JOY.ASM, under `cmbrules`). Reported: Kung Lao's quick HP
  into Back+HP "doesn't combo to 2". `cmbrules` hands a jab's hit back, so the
  backfist found `p_hit` 0 and opened its own string. Now a clean hit whose
  attacker is NOT in `act_hipunch`/`act_lopunch`, landing on `p_hit` 0 with the
  victim's `p_pblock` > 0 (still in a jab's stun), writes `p_hit` 1 BEFORE
  dmgscale and `hud_combo_hit` read it: "2 HITS" and 3/4 damage, no change to
  either reader. Jab into jab is untouched. **It is a balance change**: jab +
  link was full damage under cmbrules and is 3/4 again. Rig:
  `tools/run_jablink_test.ps1` - backfist alone 32; HP then Back+HP 8 frames
  later = kounter 2, backfist 24; at 11+ frames he has recovered (`p_pblock`
  0), it is not a link and does 32 (the in-run control). **The link window is
  ~3 ticks** - that is the jab's own stun, not this change.
- **EVERY THROW GOES THROUGH `dmgscale` NOW, AND JAX'S MULTI-SLAM DIMINISHES**
  (`throwscale`, MAINEQU.ASM, needs `dmgscale`; `super_wham` in MKSLAM.ASM and
  `throw_damage_a10` in MKREACT.ASM, both on JOY.ASM's shared `dmgscale_a10`).
  Every throw applies its damage with `damage_to_me`, which jumps straight to
  `bar_reducer` - the same hole Ermac's slam had.
  **JAX'S THROW WAS THE MOST DAMAGING INPUT IN THE GAME.** `super_wham` is 10
  and he gets it `jax_extra_slams+1` times for tapping High Punch
  (`super_slam_proc` keeps them coming while `get_tsl(l_hp) < 10`), on top of
  `slammed_by_jx`'s 18 - measured **`[10 10 10 10 18]` = 58**, against Kintaro's
  40, the hidden fighters' 45 and a 32-34 field. Now **`[10 8 5 2 18]` = 43**.
  **The first slam and the 18 are deliberately NOT scaled**: his basic throw is
  10 + 18 = 28, already the weakest in the game, and it is not what anybody
  complained about - what diminishes is the reward for mashing. Measured
  unchanged at `[10 18]` = 28.
  The wham's index is derived from the loop's own constant (`jax_extra_slams+1`
  minus `p_anicount`, which counts down), so changing the number of extra slams
  cannot leave the curve mis-indexed; `p_anicount` survives `double_mframew`, as
  the `dsj` already relied on. `super_wham` pushes `a1` across `calla_for_him`
  and `shake_n_sound` and works the damage out LAST, where the original did.
  **NO MINUS ONE on the payloads**, the one difference from `erm_tks_scale`: a
  throw is not a strike, nothing in the path runs `reaction_start`, and
  `flipped_pause` - what `takeover_him` parks the victim on - is a bare sleep
  loop into `reaction_exit`. **That is also WHY Jax's whams need their own
  index**: a throw does not advance the string, so all four would otherwise land
  at one depth. The switch is INSIDE `throw_damage_a10`, so all seven payload
  sites call it unconditionally and `throwscale 0` leaves them the bare
  `damage_to_me` - one `.if`, not seven. Verified full value at depth 0 for Jax
  18 / Kang 32 / Cage 34 / Shang 24 / Raiden 20 / Kitana 30, and Cage 17 at depth
  2; `slammed_by_goro` is Kintaro's and unreachable as a player throw, so it is
  covered by inspection only.
  **HONEST LIMIT: the payload half changes nothing today.** A throw CAN legally
  follow a hit - `toss_check` refuses only an airborne victim, `act_land` and
  `b_noflip`, and `b_noflip` has exactly ONE setter in the tree
  (MKPROP.ASM:2960) - but `-Jab` measures the attacker's own jab recovery
  outlasting the victim's hitstun by **48 ticks**, and `back_to_normal` has
  cleared `p_hit` before the grab goes in (`p_hit@throw=0`, Cage and Jax alike).
  So it is a guard for a throw that does land in a live string, not a nerf to
  anybody's throw. What bites is Jax's multi-slam, whose index is the slam number
  and needs no string at all. See
  [doc/THROW_DAMAGE_SCALING.md](doc/THROW_DAMAGE_SCALING.md).
- **A SEPARATED ATTACKER IS HELD UNTIL THE VICTIM LANDS** (`sepland`, local
  to MKREACT.ASM; `attacker_getting_separated`'s ground branch). More than 3
  hits into a string, the anti-juggle rule takes the attacker over and slides
  him away - but retail let go of him (`wait_for_his_dog 050h`) while the
  victim was still up to 80px off the floor, `reaction_exit` handed the
  buttons back, and Ermac or Scorpion teleported straight out of the sentence
  and resumed the juggle (reported by a player). Now it waits for
  `is_he_airborn` to clear, with `sep_land_max` (0c0h ticks) as a backstop
  because that test answers yes on any `oyvel`. The airborne branch already
  held him until HE landed. `sepland .set 0` = retail. Assembled and
  installed 2026-10-04; NOT yet proven by a rig.
- **OFF (`dpul1 .set 0`, 2026-10-04, the user's call): THE DEAD POOL IS RETAIL - no big chains anywhere.** What `dpul1 .set 1` brings back: **THE DEAD POOL HAS MIDWAY'S CORNER CHAINS - AND ONLY THOSE** (`dpul1`,
  BGND.ASM; `dpdeckBMOD`, BGNDTBL.ASM). `DPUL1BMOD` is Midway's nearest Dead
  Pool layer, in `DEDPOOL.BDB` and PACKED in the video ROM but never wired:
  two fat chains the full height of the screen plus a swag in each far
  corner, 2364px wide. (It is NOT the orange sky - that is `DPUL6BMOD`.)
  **Only the corner swags ship**: in front of the fighters the middle chains
  hid them, and behind them they read at the wrong depth (both tried
  2026-10-04; the user's call). `dpdeckBLKS` is a SOURCE-ONLY copy of
  `DPUL1BLKS` holding just the four corner blocks, the Outer Haven
  `ohspiral2BLKS` pattern - the stock-record promoter preserves it and its
  `.globl` is hand-added to `BGNDTBL.GLO`; it keeps DPUL1's 2364x460 so
  `center_x` places it identically. Midway's commented `-610` predates
  `center_x` and leaves the left swag unreachable, so it is centred and
  scrolled at `054800h` (2.64x), the rate at which each swag sits in its
  corner at that end's scroll limit, and drawn in front of the fighters after
  the close chains. ASM only - no repack. `dpul1 .set 0` = retail. Rig
  `tools/run_stage_park_probe.ps1 -Package` (any stage via
  `-Stage`/`-Stops`; parks the camera, snaps, logs every plane's worldtlx and
  baklst contents): baklst2 holds the two swag blocks at each end and nothing
  in the middle, `peak_overload` 2 throughout.
- **LIU KANG'S FIREBALL OBEYS THE ANTI-JUGGLE RULE** (`lkzapair`,
  MAINEQU.ASM; `ar_lkzap`, MKREACT.ASM). The rule lives at
  `reaction_start_abc`'s funnel: an airborne victim is jumped to his
  reaction's airborne handler, and 43 of 44 of those call
  `no_unlimited_airhits` - more than 3 hits into a string, the ATTACKER is
  transferred to `attacker_getting_separated` and slides away. Retail's
  `ar_lkzap` is `generic_airborn_hit`'s body minus that call, so a fireball
  could keep a man in the air for free. Counting DIRECT callers of the
  separator (5 in the game) is the wrong measurement and reads as a rule
  nobody wired. Rig `tools/run_lkzapair_test.ps1 -Package`: Reptile jumps into
  the high fireball at five offsets, fresh and with `p_hit` seeded to 4 -
  opening hits 3/3 leave Liu Kang where he stands, deep hits 3/3 slide him
  84px away; `-Negative` NOPs the call in memory (found by the `07000h`
  gravity behind it, which `attacker_getting_separated` and
  `generic_airborn_hit` do not have) and the deep trials fail 3/3.
- **THE SPEAR WOUND BURSTS: MK1's GUTS, FLUNG OFF HIS BACK** (`spearguts`,
  MAINEQU.ASM; `speared_blood` / `spatter_blood_fly`, MKBLOOD.ASM). Midway's
  commented tail on the spear's blood routine, restored AS WRITTEN: its `jruc`
  is a tail call that stood in place of the `die`, so it runs AFTER the 8
  drips (+16 ticks, clear of the hit's own spray), and its registers are
  `spawn_drip`'s argument layout - lane `a_guts` (a9), speed 5 (a5), wound
  point `[y,x] 020h,1` (a4, the drips' own). **GUTS1-7 is not guts**: it is
  MK1's burst (Kano's heart rip), drawn to be THROWN - played in place (the
  first cut, on `guts_proc`) it froze with its chunks in mid-air and vanished.
  `spatter_blood_fly` is the routine that throws it, and it was never
  finished: it saved those arguments and hard-coded `a_bigger` at 6 and its
  own lineup. It now reads a9/a5/a4 (speed parked in a10 - `lineup_1pwm` and
  `set_proj_vel` use a4/a5) and keeps its own random throw, back 3-5 px a
  tick; a0-a3 are still ignored (the tail's zeros were the unwired
  arguments). No gravity - the leak's routine has none. It has no other
  caller. `get_jt_blood` takes facing AND colour off `a11` (the victim), so
  Reptile's are green and Noob's black. **Every spear connect shows it -
  Scorpion's and Smoke's.** Rig `tools/run_scorpion_spear_guts_test.ps1`
  (3/3: 7 of 7 GUTS frames, starts +16 after the pull, flies ~170 px); found
  by the image address the DMA is drawing (read out of `MKBLOOD.TBL` each
  run). `-Negative` cuts the tail's lane to GUTS7 in memory and fails 3/3 -
  NOPing the `jruc` would prove nothing, `spatter_blood_fly` is the next
  instruction. Cosmetic, not in the balance lock.
- **KITANA'S KISS OF DEATH BURSTS IN ITS OWN BLOOD SPLASH** (`kissblood`,
  MAINEQU.ASM; `r_kissed`, MKDIE.ASM; `kiss_splash_blood`, blood slot `1fh`,
  MKBLOOD.ASM). `BLDSPLASH1-5` (`data/MKMORPH2.IMG`) is a five-frame blood
  burst drawn in the kiss's OWN library, beside the inflate (`FAT*`), the pop
  poses (`POP*`) and the chunks `kiss_explode` throws (`CHUNK1-6`). **Retail
  packed ONE frame** - `BLDSPLASH1`, in `MK6MIL.LOD` on CHUNK1A's line - and
  used it as a STILL splat on the Pit floor (MKFALL `splat_spots`); frames 2-5
  were in no ROM and the burst never played. They are `data/BLDSPLSH.LOD`,
  bank 1 at `0x9C5C00` (4,930 bytes, top of the run after MK6MIL, hard under
  NOOBPRJ; MK6MIL keeps 1,758 bytes of growth). Frame 1 stays where retail put
  it because MKFALL still draws it.
  One splash, created once on the pop, its centred anipoint `048h` below the
  body's anchor - where `kiss_explode` throws the chunks from - at 4 ticks a
  frame; `oid_blood` so `delete_offscreen` leaves it alone. Reptile and Noob
  take `BLOODYG_P` / `BLOODYNB_P` (IMGPAL6.ASM), the recolours MKFALL already
  uses on this art - BLDXPD's are a different ramp in a different order.
  **This replaced the first cut**, which revived Midway's commented-out loop
  (three uppercut bursts down the body, which they placed by MOVING THE
  VICTIM'S OWN OBJECT `020h` at a time beside `kiss_explode`'s off-screen
  delete); the commented loop is still in MKDIE. Retail's kiss has NO blood
  at the pop at all. Cosmetic, not in the balance lock.
  Rig `tools/run_kitana_kiss_blood_test.ps1 -Victim <name>`: walks `objlst`
  for an object drawing a BLDSPLASH SAG (read from `src/MKFAT2.TBL` +
  `src/BLDSPLSH.TBL` every run) and requires all five frames in order, centred
  within 12px of the chest, gone by pop+60, the victim object unmoved.
  Sub-Zero, Reptile and Jax: frames at pop+0/5/9/13/17, centre within 1px,
  gone at +21. `-Negative` NOPs the `calla` after `movk 01fh,a0` in memory and
  FAILS (0 of 5). **Rig trap: pressing Low Kick to start the charge THROWS A
  LOW KICK** (act `0104h`), and against a wide body it connects from fatality
  range - `winner_status` goes 3 -> 1 and FINISH HIM is over, which reads as
  "the kiss never started". It charges `090h` apart and steps in, as a player
  does. **The pop is `m_inviso` = `020h` in `oflags2`, taken on the 0 -> 1
  edge** - testing bit 1 "popped" on the fatality's first frame.
- **THE HIDDEN CPUs USE THEIR OWN MOVES AND FATALITIES** (2026-10-06; all in
  MKDRNEW.ASM, MKDRONE took only data rows and net-zero lines - scratch-assembled
  first). `drone_finish_him` sent every ochar from 12 up to the uppercut (the
  db1/db2 tables are twelve rows); after the same 1-in-10 `aud_drone_fatal`
  audit it now `jsrp`s `drone_hidden_finish`, which walks to the human's own
  range and jumps to `do_jade_impale` (<= `jdi_maxdist`), `do_ermac_fatal_slam`
  (the `erm_tksf_min/maxdist` BAND) or `do_rain_fatal` (<= `rnf_maxdist`), and
  `retp`s for everybody else. CPU Jade can never reach it in 1P - her fight is the
  secret encounter and `finish_him_sequence` gives it no FINISH HIM (nor Noob or
  Smoke, on either side). `ochar_punish`: Ermac's teleport punch
  (`drone_er_decoy`, the handler's 060h `l_decoy` cooldown), Rain's bolt and
  Smoke's spear (`drone_zap_jsrp`, which carries `drone_zap_legal` + pacing).
  `drone_ajump_call`'s dive gate asks `drone_dives` (Reptile, and Noob under
  `noobdive`). Rig: the fly with `FB_ADDON=tools/fly_cpu_moves_probe.lua`
  (per-CPU action starts + every fatality), read with
  `tools/fly_cpu_moves_report.py`.
- **THE FLY'S MOVE CATALOGUE READS THE BUILD, NOT THE TEXT** (2026-10-06,
  `tools/make_fly_moves.py`). It now drops code inside a false `.if <switch>`
  (it offered Noob's four compiled-out shadow moves and Kitana's spin chop) and
  comment lines (`*`-commented `scom_jc_zaphi`), and carries BUTTON SEQUENCES
  (`bcom_*`, `seq = {...}`, idx `0xFFFC`: Kitana's fan decap, Jax's Block x4 +
  LP, Jade's impale, Shang's Block x3 morph) which the rig presses rather than
  invokes. Adding a `bcom_` move or flipping a move's switch changes
  `FLYMOVES.ASM`'s table, so it needs a rebuild and a new frozen pair with its
  own `flybrain_moves.lua`.
- **THE CPU'S JUMP-IN CAN BE A PUNCH - MIDWAY'S SHELVED `drone_flip_punch`**
  (`drnflipp`, MAINEQU.ASM; `drone_fp_try`, MKDRNEW.ASM). The leak carries a
  `drone_flip_punch` in MKDRONE.ASM, commented out and called by NOTHING - not
  even a commented table row. It is a line-for-line twin of `drone_flip_kick`
  with `do_flip_punch` at the end, so retail's CPU only ever jumps in with a
  kick. **Why it was shelved is in the numbers**: a flip punch is 16 where the
  kick is 26 (`stk_??flipp` / `stk_??flipk`, strike `0ch` / `0bh` for every
  playable fighter), and a jump punch is only worth throwing for what FOLLOWS
  it - retail's drone had no way to follow anything, because an air move ends
  in `do_land_animation` and never returns to its caller. This build does
  (`drone_land_next`), so the punch arms `dln_press`: land, and if it connected
  take the sweep. Two things are this tree's, not Midway's, both already
  proven on the kick: never swing while rising, and ask the real strike box
  (`does_stk_reach`) instead of their `080h` = 128px against a ~80px reach.
  `drone_fp_try` is called from `drone_flip_kick` after its own gates and
  before the takeoff; it RETURNS for a kick and never returns for a punch
  (`pull a0` first). The juggle entries (`drone_flip_kick_now`) never reach
  it. Kintaro and Shao Kahn are excluded - Kahn's `0ch` is the hammer and
  Kintaro's table has 9 rows. Odds `rpt_flip_punch`, 0 at the two easiest
  levels up to 45%.
  **IT LIVES IN MKDRNEW BECAUSE MKDRONE IS AT GSPA's CEILING**: MKDRONE's
  whole share is ONE `calla` and two names appended to an existing `.global`
  line (`does_stk_reach` had to be exported), and the pair was TEST-ASSEMBLED
  IN A SCRATCH COPY FIRST - a failed assembly deletes `mk2.out` for every
  session linking in the tree. The scratch harness is a copy of `src/*` text
  sources plus `tools/GSPA.EXE` and the repo's own `dosbox_asm.conf` with the
  autoexec swapped for `gspa MOD -H -v10`; assemble the UNPATCHED pair first
  as the control. `fp_floor` / `fp_press` are local copies of MKDRONE's
  `flipk_floor` / `dln_press` because a `.set` does not cross objects - if
  either moves in MKDRONE, move them here.
  **MEASURED, AND THE MEASUREMENT IS THIN**: `tools/run_drone_flipp_test.ps1`.
  Across the runs, 5 punches thrown, 4 connected and EVERY one for exactly 16;
  the sweep follow-up seen twice (16 + 20); the control (odds zeroed in
  memory) throws none. That proves it exists, connects for the right amount
  and is followed up. **It does NOT show it beats the kick**: jump-ins are
  rare in that rig (at most 3 in 20,000 frames) and not one flip KICK came out
  in any run, so there is no baseline.
  **THE REBOOT THAT RIG FOUND IS FIXED, AND IT WAS ALSO WHY NO CPU EVER
  FLIP-KICKED.** `drone_kl_escape` (Kung Lao's escape dive for the CPU) had
  been inserted straight after the `dajc_nosk` label in `drone_ajump_call`,
  so every OTHER fighter's jump-in FELL INTO it every tick (the fall-through
  trap in Assembler gotchas). Roll failed: `dkle_no rets` returned out of the
  whole jump-in, so the kick code below never ran - the CPU's flip kick was
  dead for everyone but Kung Lao and Reptile. Roll hit: it popped THREE
  return addresses believing it had been `callr`ed, the third being the
  DISPATCHER's own, so the next end-of-list `RETS` (prclsp) jumped to 0 ->
  TRAP 30 -> `illop_recover` cold-started the board. It now sits behind
  `jruc dajc_kick`; a move, no new directive (MKDRONE is at GSPA's ceiling -
  test-assembled in a scratch copy first). Measured: Baraka 20,000 frames with
  no fault (was fight+9,931 every run) and 5 flip kicks where every earlier run
  had 0; Scorpion 9 kicks, Kung Lao still fine. **How it was found**: a write
  tap on `illop_count` dumps the CPU (A7 there is just the last `sloop`'s
  wake address, a red herring; `A13 = 0` says the dispatcher), then
  `-TraceAt N` traces with `SP` per instruction - the end-of-list `RETS` ran
  at 0117FFF0 instead of 0117FFD0, and the first rise past the dispatcher's
  frame was three `MMFM SP,A0` in `drone_zap_jump`+0x4bc. **Every "reboot" in
  this build is `illop_recover`**; tap `illop_count`, never guess.
  **Three rig lessons**: a 20-byte table found by its bytes existed TWICE
  (MKDRONE has an identical odds table) - the control would have zeroed the
  wrong one half the time, so it is keyed on the `rets` (`60 09`) in front of
  ours; pinning the human every frame left him stuck in Scorpion's rope pull
  for the whole run; and "reset the gap while the CPU is in its stance" fires
  constantly, because a WALKING drone keeps `act_stance`.
- **A CPU KUNG LAO WHOSE AIR PUNCH CONNECTS DIVES STRAIGHT ON** (`klpdive`,
  MKDRNEW.ASM; `drone_kl_pdive`, called from `fly_punch_hit`, MOVES.ASM).
  After the hit pause of a connected flip punch he goes into his dive kick
  (`do_body_propell 3` = `do_reptile_superk`, the drone's own path to it) on
  the harder levels: `rpt_kl_pdive` is 0 below difficulty 5, then
  40/60/80/90/100%. **It is the human's input, not a drone-only chain**: the
  HK press reaches `hh_hi_kick` mid-punch (the button table runs first) and
  `airborn_xfer` refuses only a man reacting, mid-special or a sitting duck -
  so the gate copied is `hh_hi_kick`'s own, 0a0h off the floor. Clears
  `p_juggle_step` (the punch's landing follow-up) before it goes. Measured
  (`run_drone_flipp_test.ps1 -Char kunglao -Diff 9`): 3 of 3 connected
  punches dived, every dive hit for 20 (16 + 20 off the jump-in); missed
  punches never dive. `rpt_kl_pdive` sits AFTER `rpt_flip_punch` because the
  flip rig finds that table by the `rets` in front of it. MOVES got one
  `.ref` and one `calla` (near GSPA's ceiling - scratch-assembled first).
  **If a relink does not happen**, delete the edited module's `.OBJ`: DOSBox's
  clock skew left `mk2.out` stale after an MKDRNEW edit here.
- **THE "MAY BE ELIMINATED (FOR KANO)" SCROLL ROW IS GONE, AND IT WAS LIVE
  HERE BY ACCIDENT** (BGND.ASM, `right_scrolls` / `left_scrolls`). Boon's
  flagged row was `080000h,ss_80000` - an 8px-a-tick camera scroll, planes x4,
  for MK1 Kano's roll - sitting AFTER `0a0000h`. `scr_choose` takes the first
  row >= the fastest fighter, so in retail it could never be chosen: dead, as
  he suspected. But `scroll_clamp` (this project's fix for retail's
  `scroll_error` = `ermac 12` freeze on anything faster than the table)
  answers such a man with "the last pair's routine, 64 bits back", and the
  last pair WAS the Kano row - so Baraka's blade charge or a boss launch got
  the camera at 8 (x4) where the clamp's own comment promised the fastest, 10
  (x5). Both rows and `ss_80000` / `ss_80000_neg` / `ss_80` are deleted, as
  Boon asked: retail-neutral for every speed <= 10, and the clamp now lands on
  `ss_a0000`. Proven in the linked ROM (both tables end on the `0a0000h` row
  and `*(T-32)` is that row's routine). **THE LAST ROW MUST BE THE FASTEST** -
  never append a row to those tables without keeping them ascending.
  **Method note, the user's catch: judge the leak BY THE LEAK.** The
  disabled-code sweep read mk2-readonly but its "still exists?" checks ran on
  our `src/`, and two conclusions about Midway came out wrong.
- **OFF (`iceooo .set 0`, 2026-10-05, the user's call): no crowd "ooo" on an air freeze.** What `iceooo .set 1` brings back:
  **THE CROWD GOES "OOO" WHEN SOMEBODY IS FROZEN IN MID-AIR** (`iceooo`,
  MAINEQU.ASM; `r_ice`, MKREACT.ASM). Midway's own hook, commented out because
  it could never build: it spawned `crowd_ooo_proc` under `pid_comment` and
  NEITHER name exists in the leak. The sound always did - `triple_sndtab2`
  34h "crowd ooo", track `024bh`, one of the five random comments an uppercut
  plays (`randu 5` -> 30h..34h; Kahn's Arena plays `0b3h` instead) - so the
  hook now calls `triple_sound2` directly. **`triple_sound2`, not
  `triple_sound`: 34h in the FIRST table is a wasted-voice grunt.** Kept
  before `stop_me`, where his jump velocity still reads as airborne. Sound
  only, not in the balance lock. Rig `tools/run_iceooo_test.ps1 -Package`:
  Sub-Zero's standing ice meets a Reptile who jumps straight up at six
  offsets from the throw, plus a grounded control - 3 freezes in the air
  (56-62px up) each with `024bh`/`024dh` on the latch one tick before the
  freeze registers, the grounded one without. `-Negative` NOPs the call in
  memory (found by the `calla am_i_airborn` in front of it - a second
  `movi 034h` + `calla triple_sound2` exists elsewhere) and fails 3/3.
- **SUB-ZERO'S GROUND FREEZE WORKS IN THE CORNER** (`szicecorner`,
  MAINEQU.ASM). Retail refused it within `060h` of a stage limit
  (`sz_lo_kick`, and the CPU's `dzl_puddle`); UMK3 kept the rule; nothing
  says why. The reason is `r_floor_ice`: each slip leg sets the velocity ONCE
  and runs until the victim is 5px from that puddle end, and in a corner the
  end is behind `gravity_n_bounds`' wall, which zeroes his velocity - so he
  stood still in the slip pose for the rest of it (measured 49 ticks). The
  puddle ends are now clamped to the wall before the slip, and the edge tests
  compare against `060h*(1-szicecorner)` (arithmetic, not `.if` - MKDRONE is
  at the GSPA ceiling). Retail's gate only roughly covered the bug: 50px off
  the wall is outside it and stuck for 29 ticks with the clamp NOPped. Rig
  `tools/run_sz_floorice_corner_test.ps1 [-Package] [-Negative]` (8/8; the
  negative sticks on all four near-wall trials). **A victim pinned AT the
  wall cannot show it** - his first leg goes away from the wall. See
  [doc/SZ_FLOOR_ICE_CORNER.md](doc/SZ_FLOOR_ICE_CORNER.md).
- **"FROSTY!" - UMK3's Dan Forden line when a nearly dead man is frozen**
  (`frosty`, MAINEQU.ASM; `r_ice`, MKREACT.ASM; `frosty_peek`, BGND.ASM).
  UMK3's `r_freeze` (MKREACT.C, "low on strength = frosty !!") and MK3's asm
  both do it: when the frozen man has **8 or less** on his bar, Forden peeks in
  and says FROSTY. No dice roll, so it fires every time. MK2's ice does 10, and
  that damage lands BEFORE `r_ice` reads the bar (measured), so Frosty fires when
  the bar is 18 or less going into the hit. A freeze that KOs him gets one too.
  `frosty_peek` is `forden_peek`'s Toasty peeker with the FROSTY clip
  (`triple_sndtab` 102h, track $0373 - the same clip Fly Pong uses). It does
  **not** stamp `@toasty`, so it never opens Smoke's Down+Start window. Same
  `curback 9` exclusion as Toasty. Sound/visual only, not in the balance lock.
  Rig: `tools/run_frosty_test.ps1 [-Package]` - bar 151 and 9 after the hit: no
  Forden; 8, 2 and 0 (KO): Forden plus FROSTY on the latch 5 ticks after the
  freeze, and `@toasty` untouched. `-Negative` disables the guard in `:maincpu`
  and must FAIL (it does: Forden on every freeze).
- **A PLAYER-2 JAX'S ENERGY WAVE GOES IN PLAYER 2'S PROJECTILE SLOT**
  (`jaxzappid`, MAINEQU.ASM; `jax_zap_spawn`, MKZAP.ASM). Retail spawned the
  wave - ground AND air - with `create pid_proj1,jax_zap_proc` whoever threw
  it, so a P2 Jax's wave was a PLAYER-1 projectile. Every other projectile
  takes its pid per player through `spawn_proj_proc` + `p1p2_proj_pids`
  (all 20 rows `07xx`/`08xx`), and two things key off the class:
  `get_his_proj_proc` masks `procid & 0ff00h`, so **a P1 CPU never saw a P2
  Jax's wave** (`wait_proj_spawn` timed out at 32 ticks and stood up into
  it); and Jade's boomerang (`jz3b1`) and Noob's shadow and portal
  (`nbsh_pid`, `nbpt_pid`) refuse while their OWN exact slot is live, so
  **a P2 wave in flight locked a P1 Jade or Noob out of their projectile -
  human against human too**, the netplay case. Reptile's air spit is not
  affected (his row is `pid_orb1/2`, `0702h`). Found mining the leak's
  comments: retail's note "when adding more proc's for projectiles make sure
  you update wait_for_prj routine" names a routine that exists in neither
  tree - the masked scans replaced it and these two spawns never moved
  onto the per-player table. **Not `spawn_proj_proc` itself**: it rewrites
  `p_store1` with the thrower's OBJECT and `jax_zap_proc` reads it as his
  PROC, so only the pid changes (`p1p2_pick` off his `oid`). Rig:
  `tools/run_jax_wave_slot_test.ps1` - **4/4 on both halves, and `-Negative`
  0/4 on both**. The control patches the one `0800h` immediate inside
  `jax_zap_spawn` back to `0700h` IN MEMORY rather than building a second
  ROM in a tree other sessions are linking in, and keeps the same
  expectations, so it must FAIL. The rig also REQUIRES that instruction
  sequence (`movi 0700h,a0 / movi 0800h,a1 / calla p1p2_pick`) to be in the
  loaded ROM exactly once with its `calla` resolving to `p1p2_pick`, so a
  ROM without the fix is refused before play rather than measured.
  **The AIR wave (`do_jax_airzap`, this project's move) shares the spawn and
  is proven too**: `-Air` 4/4 both halves, `-Air -Negative` 0/3 both.
  **AND IT ONLY HITS A STANDING MAN FROM THE LAST ~20PX OF A JUMP.**
  `jax_zap_proc` flies the wave DEAD FLAT at its release height
  (`set_proj_vel` sets x only; measured `yvel 0.00` and one y for the whole
  flight), and Jax does not fall during the throw, so the wave leaves at the
  height he pressed it. Measured on a neutral jump against a standing Jade
  (`-Air -Delay N`): released 94/81/62/43/35/27px up - all MISS, sailing
  16-100px over her head; 19 and 10px - HIT for 18, `stk_jxzap`'s exact
  clean damage. That is a ~2-tick window at the bottom of the jump, where it
  is all but a ground wave. Liu Kang's air fireball is built the same way
  (flat, spawned 32px higher), so this is MK2's air-projectile model, not a
  port bug - but a flat wave from mid-jump is an AIR-TO-AIR tool, not a
  zoning one. **Angling it down (UMK3 does) was proposed and DECLINED,
  2026-10-04, the user's call: it stays flat.** Do not re-propose it.
  **`tools/drone_airzap_test.lua`'s "AIR PROJECTILE CONNECTED" IS NOT A
  PROJECTILE HIT**: it credits any bar drop within 120 frames, and every
  character's connect in its logs is exactly **8** (Jax, Kitana, Liu Kang,
  Mileena, Reptile, Sub-Zero alike) where Jax's wave is 18 clean / 5 block.
  `AI_DRONE.md`'s "Jax 5/5" safe zoning throws are measured RELEASE GAPS and
  stand; whether those throws land was never measured.
- **JAX'S GOTCHA GRAB AND MULTI-SLAM COUNT ON THE KOMBO KOUNTER, AND THE
  PUNCHES SCALE** (`holdhits`, MAINEQU.ASM; `held_hit_to_him`, JOY.ASM). Both
  moves used `damage_to_him`, which bypasses `strike_check`, the only producer
  of the kounter and of `dmgscale`. The hold also never runs
  `reaction_start`, so the victim's `p_hit` sat at 0 and every hit read as a
  new string. The helper scales, feeds `hud_combo_hit`, then bumps `p_hit`.
  Noogy punches 45 -> **9 9 7 4 2 = 31** (`a1 = -2`: the curve starts on the
  third punch). Each slam is also credited to
  `p_scalebias`, so the closing 18 and the basic 28-damage throw are
  unchanged; `jx_slam_kounter` adds the 18 to the readout once the throw is a
  combo. **Any other move that hits a held man through `damage_to_him` has the
  same hole.** Rig: `tools/run_jax_multislam_probe.ps1 -Move noogy|throw`.
  See [doc/THROW_DAMAGE_SCALING.md](doc/THROW_DAMAGE_SCALING.md).
- **A BEATEN PLAYER WHO IS HOLDING BLOCK LETS GO OF IT** (JOY.ASM,
  `joy_block_loop`). Reported by a player: "if I hold block and have lost, I
  appear in block formation after the match." `joy_block_loop` never called
  `check_winner_status`. Every other idle loop in the file does -
  `joy_stance_loop` (joye5), the duck loop (joyd5), the duck-block loop
  (jdblk5), even the walk loop (joyr6) - and the STANDING block loop did not.
  Midway's own omission, still there in mk2-readonly.
  So a man holding the button when the round was decided never reached
  `collapse_on_ground` or `dizzy_dude`: he stood in his guard pose through the
  winner's celebration and through FINISH HIM, where `dizzy_dude` would have
  made him a sitting duck (it calls `set_no_block` - losing the guard is the
  game's own intent). **It self-healed the moment the button came up**, through
  `do_unblock_hi` -> `joy_entry` -> joye5, which is why it only ever showed
  while the button was HELD - and why a rig that lets go when `gstate` leaves
  `GS_FIGHTING` cannot see it at all.
  `check_block_bit` reads `@switch` directly, so `disable_all_buttons` does not
  end that loop: the button does, or nothing does. One `calla` fixes it, and
  `calla` is right because the routine never comes back when there is an
  outcome - `finish_him` and `plwins` both drop the return address with a
  `pull`.
  Rig: `tools/run_blockloss_test.ps1` (fixed 2/2 beats in both modes; the
  unfixed ROM fails 2/2 with Block held and still passes `-Mode control`).
- **CURRENTLY OFF (`soulesc .set 0`, 2026-09-21): beating Shang is stock** -
  FINISH HIM (so his fatalities work), his ordinary stage rotation, the
  win banner, then the mountain and Kintaro, as retail. Everything below
  is compiled out but kept; `soulesc .set 1` brings it all back.
  **Beating Shang Tsung ends in MK1's soul escape, not FINISH HIM.** In a
  ONE-PLAYER game the CPU Shang is fought in KAHN'S ARENA (`boss_minumum_diff`
  sets `curback 8`, next to the Kintaro/Kahn override), first of the three that
  close the tower. When he loses the deciding round `finish_him_sequence` asks
  `soul_escape_due` and jumps to `soul_escape_sequence` (`src/MKSOULS.ASM`)
  instead. The killing blow throws the winner clear (`f_soul_knock` ->
  `r_quake` in his own process), then Shang turns back into himself inside
  retail's poof and shakes on the lane authored in `data/TSHANGEND.WAX` -
  his own MK2 stumble and low-hit poses, 4 ticks a frame, imported by
  `tools/shang_end_wax_import.py` (Phase D `--check`; edit the project, not
  the generated block) - while the arena's PURPLE BACK WALL flashes - `baklst6`
  alone, because baklst2-4 are the parapet and the distant floors and read as
  foreground. The eleven other main fighters' souls peel off him one every 27
  ticks - a Shang copy, his own morph lane, that fighter's stumble and
  knockdown, burnt away by the MK1 flame - then he goes down on his own
  `a_stkdown`. **He stops shaking when the LAST SOUL IS ASH**, not on a
  timer: each soul counts itself out of `soul_alive` and the spawner waits
  for zero (`soul_tail` is only the ceiling now), because the old fixed tail
  over-ran and left him flapping at an empty screen. MK1's own OLD-MAN art
  for this ending was built and then reverted on 2026-09-20 - see
  `_old/mk1_oldshang/` and the ledger entry.
  **Then Kintaro finishes it - the real move, three times.** The arena prop
  in the stands crouches and springs on `SMTIGERJUMP1-4` (`data/SMTIGER.LOD`,
  bank 1) and rises clean off the TOP of the screen in its four frames
  (`arena_goro_leap_dy`, ARENAKIN.ASM) - the two Kintaros must never share a
  frame. The fight-size one then plays **`goro_psycho_stomp`**
  (MKBOSS.ASM) - the teleport-and-drop he does in a fight - three times,
  picked up at the point the player can actually SEE it: `087h` and the long
  roar `0b1h`, he is gone from the floor, and he comes back down over the
  body on `TIGERJUMP5` (part two's pounce, held the whole way because the
  move's `flight_call` passes `never_ani`) at its own `040000h` under
  `010000h`, landing on `goro_psycho_land_frame`'s pose - ani `00ah` row 0 -
  with `shake_a11 0000a000fh` and `0b2h`. Then he pounces away
  (`soul_kin_bail`), the object is deleted, and the next match opens on the
  stage's own marks with him walking in normally.
  **Do not draw the climb.** The move sets `ograv` NEGATIVE and drives him
  under power to `0110h` off the ground - 272 px, off the top of a 254-line
  screen - so on screen it already IS a disappearance. Rendering it as an
  arc instead was tried twice (powered to 144 px, then ballistic off
  `goro_stupid_jump`'s `-0a0000h`/`0c000h`) and both read as Kintaro jumping
  absurdly high. Only the drop is played.
  **`flight` cannot be used** - it lives in `*a13(p_ganiy)`, `p_store4`,
  `get_char_ani` and `ground_player`, and this is a bare object whose a13 is
  Shang's - but what it relies on is there: the display walker adds `oyvel`
  to `oyval` for every object (`dclipl`, MKDISP.ASM). Nothing adds `ograv` to
  `oyvel` for a bare one, so the drop loop does that itself.
  **The winner feels the FIRST landing** and comes out of his victory pose
  for it: Kintaro hitting the floor is Jax's ground pound as far as he is
  concerned, so he takes the pound's own reaction (`do_quake` hands its victim
  `r_quake`, and so does `soul_kintaro_knock`). No range test - `do_quake` has
  none either, and the one this had never fired at the 120-odd px the two of
  them finish apart. Only the first, because `f_soul_knock` is a one-shot the
  idle loop clears on its way into `r_quake`.
  The third stomp bursts him on **Ermac's** blood explosion rather than Shao
  Kahn's fist pulp: `soul_stomp_blood` (MKBLOOD.ASM, `blood_procs` slot
  `01bh`) is `ermac_splash_blood`'s three `BLDXPD` splats with the 24 px step
  moved out of the `[Y:X]` high half into the low one and widened to 40,
  because the body it is bursting is lying down. **Where it goes is
  measured**: a fighter face down still carries the STANDING origin, ~80 px in
  the air, so lining the splats up on his anchor the way Ermac's do put the
  burst over Kintaro's chest. `soul_kintaro_finish` takes the body's real
  bottom off `mpart_bounds` and hands the point in as `a9`
  (`kahn_knee_blood`'s contract); a9's low half is zero, so
  `010000h-ssb_dx` borrows nothing out of Y.
  **And he does not vanish under it.** `soul_shang_parts` puts three of his
  own gore records on the stone a little apart and then `set_inviso`s the
  body: `STHEAD1` (a_head's first frame), `STDECAPTORSO7` and `STDECAPLEG7A`
  (`NJDECAP7`, the last frame of his decapitation fall - already flat on the
  floor and already cut at the waist). No new art. They are single-part
  objects (`gso_dmawnz`), and a single-part object's `oxpos`/`oypos` ARE its
  top-left corner, which is also how `mpart_bounds` reports one - so they are
  placed OUTRIGHT off the body's measured bottom and left edges.
  `lineup_1pwm` + `multi_adjust_xy`, `decapped_head`'s contract, is the wrong
  tool: it works off the STANDING anipoint of a body that is lying down and
  left the head in mid air. `soul_part_lift` is the fudge - `mpart_bounds`
  measures the RECORDS and the prone strips run ~24 px past his last drawn
  row. z stacks it: pieces `front_z`, burst `front_z+1`, Kintaro `front_z-1`.
  **Then the match ends
  silently and runs straight into the next one** - `f_soul_silent` takes
  `bonus_count` (MAIN.ASM) out at the top, so there is no "X WINS" line, no
  ending tune, no speech, no FLAWLESS and no bonus count, and
  `victory_animation` (MKCANNED.ASM) holds the winner on his guard instead of
  celebrating. Kintaro turns to face him (`soul_kin_face` - `face_opponent` is
  no use, he is a bare object) and stands over the splat until the round tears
  down. **Clear `f_soul_silent` in `end_of_match_chores`, never in
  `bonus_count`**: that runs in the master process and the winner is a tick
  behind in `soul_escape_status`, so clearing it there wins the race and the
  victory plays anyway. The two objects are `oid_soul`, not `oid_fx`, because
  `bonus_count` opens with `dallobj oid_fx` and would sweep them mid-shot.
  The winner holds his VICTORY pose (ani `029h`, which every `anitab1`
  carries) from the souls all the way to the Kintaro match, where the new
  round starts him on his stance - `va_soul_stand` (MKCANNED.ASM) holds
  whatever pose he is in rather than replaying or standing him up. **Take it
  only when `f_soul_knock` is clear**: he is thrown down twice (the killing
  blow and Kintaro's landing) and re-enters that branch after each, so
  taking the pose on arrival meant he celebrated, was knocked out of it, and
  stood in his fighting stance for the rest of it. `f_soul_noladder` skips
  the mountain for that one hand-off, so the stomp runs into ROUND 1.
  The one blank frame at the hand-off is MK2's own between-round rebuild
  (`do_a11_background` -> `bakclr` empties `baklst1-8`), not this sequence;
  skipping the rebuild does NOT keep the arena up, because the display
  re-init has already cleared it by then - it leaves a dead stage. Kintaro is
  placed by MEASUREMENT, not constants - `soul_align_x` uses `mpart_bounds` on
  both the body and the object and centres one on the other, in `oxval`, the
  field `skf_drop` placed him with; writing `oxpos` instead does not error, it
  silently teleports him off screen. **Everything that sleeps here is a
  PROCESS routine** - `soul_kin_part`, `_fall`, `_land`, `_hop` and `_bail`
  are all `jsrp`/`retp`, because a `callr`'s return address lives on the
  shared system stack and does not survive the dispatcher (the prop's own
  leap was parked in the stands by exactly that). `soul_kin_frame` is a plain
  `callr` and hands back everything but a0, because the drop loop carries its
  floor in a11 across it.
  It runs on
  `winner_status = 4`, which `check_stay_down` (MKREACT) and `strike_check`
  (JOY) both had to learn, or the fighters never get up and a strike in flight
  hijacks Shang mid-sequence. A human Shang and 2-player matches are
  untouched. `soulesc .set 0` (MAINEQU.ASM) compiles it out.
  See [doc/MK2_SHANG_SOUL_ESCAPE.md](doc/MK2_SHANG_SOUL_ESCAPE.md); rig is
  `tools/run_shang_soul_escape_test.ps1` (11/11 souls, `-DumpAt <rel>` for a
  per-piece shape-RAM dump, `-Mode control` for the negative).
  **Three traps, all in the same family - the drop is a bare object, not a
  player.** `gmo_proc` cannot build it: `object_setup` reads a palette off the
  frame record (`*a5(icmap)`), which only the `PON>` background records carry
  (`gorostd1a` ends `.long GOROBRE_p`), so handing it a 112-bit PLAYER record
  lays every piece at the wrong stride. It is built like MKZAP's
  `kahn_fist_pulp_start` instead - `getobj`, its own `.bss` mpram, the palette
  named outright - and animated with `ani2` walks, never `do_next_a9_frame` /
  `mframew` / `get_char_ani`. `a9` is re-read from `go_anitab1` before the
  landing because `ground_ochar` and `shake_a11` sit between the two parts and
  a `calla` owes nothing to `a9`. And `arena_goro_leap` sleeps, so it is
  `jsrp`/`retp` - as a plain `callr` it played one frame and parked in the
  stands forever.
- **Kitana's fan decapitation SWINGS THE FAN BACK, and cuts TWICE**
  (`fandecap2`, MAINEQU.ASM; `do_fan_decap`, MKDEATH.ASM). `FANSWIPESQ`, the
  sequence Midway embedded in `data/KAT9.IMG` beside the fatality art, is a
  full back and forth - `KTFANSWIPE1,2,3,4,5,6[15],5,4,3,2,1` - and the lane
  the game plays stops at the top of the swing, so retail's blade crosses him
  once and the return half of the animation has never been drawn. Now the
  first pass CUTS him (`r_first_swipe`, Scorpion's own first-of-two blade
  reaction: slice sound, wasted voice, blood, a stumble that holds), the fan
  hangs out there for its authored 60 ticks, and the SECOND pass takes the
  head. Input, range and dispatch are unchanged - Block, Block, Block + HK in
  FINISH HIM inside `048h`.
  **The return half is two extra PARTS, not a re-cut lane**: `a_fan_swipe` is
  SHARED with her Back+HP power punch (`do_fan_swipe`, MOVES.ASM), which plays
  parts 1 and 2 and stops, so rewriting them from the sequence would silently
  change a live move's startup and recovery. Parts 3-4 and the `fdc_` timing
  equates are generated by `tools/fan_swipe_seq_import.py` (Phase D
  `--check`); edit the sequence in IMGTOOL and re-run the tool, never the
  block.
  **Hold bytes are PREVIEW ticks x4** (13.7 fps), the same trap as Liu Kang's
  double knee. Frame 6's authored 15 = 60 game ticks, and retail's own two
  lane frames plus `sleep 030h` is 56 - independent corroboration of the unit.
  **Part 1 ends `ani_nosleep` + FANSWIPE5**, so `mframew` draws the contact
  frame and returns in the same tick: right for the power punch, where
  `striker_2`'s window then holds the pose, but it meant the FATALITY never
  drew the fan at full reach (`1,2,3,4` and straight to `6`). A `sleep
  fdc_rate` after the first slice gives it the authored beat without touching
  part 1. And `takeover_him_sr`'s brake is only `040h` ticks against a ~135
  tick sequence, so repell would come back on between the slices and shove her
  off the body - `disable_repell`'s `040h*40` is INLINED (that routine is
  6,900 lines down MKDEATH and a `callr` that far is out of PC-relative
  range).
  Rig: `tools/run_kitana_fan_decap_test.ps1 [-Victim all]`. It identifies her
  drawn frame off the SHAPE RAM (`*obj(oimg)` 112-bit nodes), not `osize` - a
  fighter is multipart and the player object's own size fields are 0 - and
  finds the detached head by walking `active` for `procid == pid_head`.
  **Not by ochar**: `decapped_head` copies the victim's ochar and never writes
  an oid, which works for eleven victims and matches a stray object for KUNG
  LAO, who is ochar 0 like every block `getobj` just zeroed.
  `fandecap2 .set 0` is retail's single slice and the rig must FAIL on it
  (measured: `LANE 1,2,3,4,6`, head off on the way out). See [doc/KITANA_FAN_DECAP.md](doc/KITANA_FAN_DECAP.md).
- **Liu Kang's knee chains HK (close) -> HK into a DOUBLE KNEE that KICKS
  him DOWN into the floor** (`lkdknee`, MAINEQU.ASM; `src/MKLKDK.ASM`;
  2026-10-05, authored in `data/KANGDBLKNEE2.WAX`). `DUBLKNEESQ`, the sequence
  Midway embedded in `data/KANG3.IMG` and never coded, is the carry-on. On its
  contact frame (`LKDUBLKNEE3`) the victim takes `r_lk_spiked` (`react_to_lk`
  row `lk_rct_spike` 1ah; the body is `lk_spike` in MKLKDK because
  `reaction_start_abc` is local to MKREACT): his OWN SWEEP FALL (anitab1 016h:
  part 1 row 0, part 1 row 3, part 2's last/flat frame = Liu Kang's FALL1/4/5,
  4 ticks each), placed at the WAX's offsets off Liu Kang's anchor in x and
  off HIS OWN floor (`p_ganiy`) in y - the two anchors differ by a few px, and
  placing off Liu Kang's left him hovering 6 px and dropping on landing. On
  the flat frame the ground rumbles, then he BOUNCES IN PLACE through `flight`
  (salg_slammed's -060000h/08000h, no x: 37 px, 0 drift) - a real y velocity,
  so a FOLLOW-UP CAN JUGGLE HIM and its own reaction takes over (measured: a
  crouching HK catches him at +62 and carries him off 60-84 px; an uppercut
  does not reach the ~74 px he lies at, and a standing HK passes over him).
  With no follow-up he lands with a thud and `lk_spike_up` (MKREACT) turns him
  to Liu Kang and gives him the SWEEP get-up (`sweepup_local_reaction_exit`,
  which keeps a beaten man down). **20 + 11 = 31 over 2 hits.** The offsets
  are generated by `tools/lk_dknee_wax_import.py` (Phase D `--check`, which
  also fails if the WAX's Liu Kang lane stops matching DUBLKNEESQ). An earlier
  cut the same day (`data/KANGDBLKNEE.WAX`, now unused) drew him on KD6/KD7
  upside down; KNEE2 replaced it. Bosses take the chain stun instead.
  **THE FIRST KNEE IS RETAIL'S LAUNCH UNLESS THE LINK IS PRE-DIALLED.** Its
  reaction has to be chosen at CONTACT - a launched man is ~110 px off and
  airborne when the carry-on comes out - so `lk_knee` tests `stk_lkknee_link`
  (`lk_stk_kneelink`, the chain's standing stun `r_lk_chainstun`) only when
  the second HIGH KICK is already in, else `stk_lkknee` (retail's `0e0eh`,
  `r_hhknee`) and no link window. So: a quick double tap spikes; one press,
  a late second press, or one inside `lk_dknee_cool` launches for 20. The
  HP -> backfist third link is GONE (LKBACKFIST1 is his recovery). No
  direction on either press - MK2's own grammar (`do_knee`'s `bt_2nd_knee`).
  The press that STARTED the knee is excluded, and a drone never links it.
  **THE HOLDS ARE THE AUTHORED ONES, AND GETTING THAT WRONG IS SILENT.** A
  seqscr hold byte counts PREVIEW ticks; one preview tick is
  `round(54.7/fps)` game ticks, and DUBLKNEESQ is authored at IMGTOOL's
  13.7 fps = **4**. Read as game ticks the whole move is 11 ticks - a
  flicker - so the first cut dismissed the authored timing and invented
  per-part speeds that ran the carry-on at ~TWICE its rate, with the build
  and the rig both green. `a_lkdubknee` is now GENERATED by
  `tools/lk_dubknee_seq_import.py` (Phase D `--check`) as frame,hold pairs:
  4, 8 | 4 | 4 | 4 = **24 ticks**. Edit the sequence in IMGTOOL, re-run the
  tool, never hand-edit the block.
  **THE STANDING STUN IS STILL NEEDED FOR THE LINKED KNEE** (`r_lk_chainstun`,
  `lk_rct_chainstun` 19h: `r_lopunched`'s body, no pushback, held at 6 a
  frame): MK2's standing stun is shorter than the chain's spacing, and at
  rate 3 the victim reached neutral and took the second knee as an OPENING
  hit (34, unscaled). Only the pre-dialled knee uses it now.
  **THE ART CAME BACK.** `LKDUBLKNEE1A-3C`, ten strips, 8,571 bytes, were
  dropped from `data/MOVEART2.LOD` on 2026-09-20 as dead art - correctly,
  nothing named them. Bank 0 has since moved on and has **no hole bigger
  than 4,832**, so they are dealt across three: a new section at the END of
  `MOVEART2.LOD` (a restore into the `LKDUBLKN.TBL` block would push
  JDIMPALE6 up the file and LOAD2 bit-bleeds a record whose neighbours
  move), plus `data/LKDKNEE2-3.LOD` in JADMIL1's and RNVIC7's tails. Sizes
  came from the **pre-removal SAG deltas in git**, not estimated off the
  IMG, and every one reproduced to the byte. **Bank 0 is full after this**:
  free 18,822 -> 10,248, largest run 1,260.
  **It needed its own OBJECT** - adding it to MOVES.ASM aborts GSPA with
  `Out of memory`. `do_knee` reaches `lk_knee` with `jrne` + `jauc`, never
  `jreq`: a conditional branch is PC-relative and GSPLNK wraps an overflow
  silently. `jauc` and `jsrp` are absolute and cross objects fine.
  **AND A TRAP THAT COST A BUILD CYCLE: `reaction_start_abc` SKIPS AN
  AIRBORNE VICTIM ENTIRELY** - it sets the "check if I am airborn" flag and
  `rst5` then does `pull a0 / jump a5`, never coming back, so every
  instruction after the `callr` is skipped in favour of
  `generic_airborn_hit`. Damage, hit count and the combo readout were all
  CORRECT while none of a custom reaction ran; the giveaway was the victim
  rising at exactly 6 px/tick, that routine's own `-060000h` literal.
  See [doc/LK_DOUBLE_KNEE.md](doc/LK_DOUBLE_KNEE.md); rig is
  `tools/run_lk_dubknee_test.ps1 -Package [-Victim N]` (5/5 on Jax, Kitana,
  Baraka, Sub-Zero and Shang).
- **Shao Kahn takes the loser's soul when he wins the match** (`ksoulrip`,
  MAINEQU.ASM; `src/MKSOULRP.ASM`). One-player, CPU Kahn wins by ordinary
  means (the Portal Punch / hammer take precedence via `f_death`):
  `finish_him_sequence` -> `kahn_soulrip_due` -> `winner_status 5`. Kahn walks
  to the body (stopping at step 0's own offset), takes the victim over and
  drives Kahn, victim and soul off `ksr_script` = `data/SHAOSOULSUCK.WAX`.
  From the tick the soul appears the victim plays Shang's `do_drain` half in
  his own process (`ksr_victim_wither`: drained palette, MKSOUL DRAIN frames,
  CORPSE husk) with Shang's soul sounds (0c1h pull, 0c2h into the hand) -
  and the husk is NOT dropped: Kahn keeps holding it, and skips his victory
  (no `check_winner_status`) so he never lets go. The round says FATALITY,
  but Kahn's "I WIN" and the announcer's "FATALITY" are skipped (`f_ksr_quiet`, one-shot, MAIN.ASM pwt1/win7; the word still drips on screen).
  Beats: laugh SOUND on the kill ($49/$4a, no animation), walk to 64 px short
  of the body, EAT SHIT AND DIE (`$63`) over `a_sk_talkdown` pointed twice,
  pause, walk in, reach (SHASOULRIP1-3 at `REACH_HOLD` 4), then dim + sting and a
  `ksr_jingle_hold` while bent over him, then the lift at `LIFT_HOLD` 6 and
  the soul at `SOUL_HOLD` 4 = Mileena's `r_body_suck` rate (importer knobs
  over the WAX's 1-tick entries). The sting waits `ksr_line_len` after the
  taunt line (make_db_tone's sound-kill cut it off). Before the soul: her
  suck ($c9), his `rsnd_death_voice`, Shang's soul ($c1), then the soul. Art: `SHASOULRIP1-9` as
  20 strips in FIVE bank-0 packs (`data/SKSOUL1-5.LOD`) at the tops of the
  MK2/3/4/5MIL gaps and FLAPJACK's tail (MTNSKUL moved up to 0x7EF700) -
  **bank 0 is full after this; the MIL files have ~0.8-1KB of growth each**.
  The soul is the victim's own `a_??_sucked_in` lane in green. Two traps it
  hit: `repell` shoves Kahn while the victim overlaps him (set `f_norepell`),
  and `match_ani_points` clobbers a1-a3 (hold row pointers across it).
  Rig: `tools/kahn_soulrip_test.lua`.
- **RAIDEN'S ELECTRICITY IS COLOURED BY THE COSTUME HE IS WEARING**, and so is
  the FLASH ON THE MAN IT HITS (2026-09-28, the user's pairing):

  | his costume | lane | his lightning | ELEC beat | FREZ beat |
  |---|---|---|---|---|
  | `RDMAIN_P` | default, Start+BLOCK, Start+COIN | `ELEC_P` | `<XX>ELEC_P` blue | `<XX>FREZ_P` cyan |
  | `RDALT1_P` | Start+HP, and the mirror | `ELECRED_P` | `<XX>ELRED_P` red | `<XX>REDEL_P` red |
  | `RDALT2_P` | Start+LP | `ELECPRL_P` | `<XX>ELPUR_P` purple | `<XX>PURPL_P` purple |
  | `RDALT3_P` | Start+HK | `ELECPRL_P` | `<XX>ELPUR_P` | `<XX>PURPL_P` |
  | `RDALT4_P` | Start+LK | `ELECPRL_P` | `<XX>ELPUR_P` | `<XX>PURPL_P` |

  **BOTH BODY BEATS TAKE THE COLOUR** (2026-09-28, the user's): the cycle is
  FREZ, ELEC, WHITE, BLACK and only the two solid flashes have no body in them,
  so `player_shock_frez_pal` indexes `shock_frez_tabs` off the same
  `shock_elec_colour` that `player_shock_pal` uses. The FREZ beat used to be the
  cyan frozen set whatever colour the bolt was, so a purple electrocution
  alternated purple and CYAN and read as two effects at once. **Midway drew that
  beat in three colours too and wired only the cyan one** - the 18
  `<XX>PURPL_P` / `<XX>REDEL_P` records were already in `data/ALLDUDES.IMG`,
  named by nothing in retail or in this tree.
  **THE FREZ BEAT IS A DIFFERENT ROSTER FROM THE ELEC ONE**: Raiden fries as
  `RD` and freezes as `RN` (`RNFREZ_P`/`RNREDEL_P`/`RNPURPL_P`), Kintaro's is
  `gorof_p` with no `<XX>` at all, and neither boss body was drawn in red or
  purple for this beat so Kintaro and Shao Kahn keep `gorof_p` / `BGFREZ_P` -
  the same shape as the ELEC red table's `BGELEC_P` fallback. Four of the blue
  FREZ symbols are carried in MKGUYS under a name the library does not have
  (its `LKFREZ_P` is `ALLDUDES.IMG`'s `LKFREZ1_P`, same for ST/NJ/JX; Kitana's was renamed to `KTFREZ_P` in the library 2026-10-11), so
  `FREZ_SOURCE` in the tool matches them BY WORDS; the whole blue set is now
  `.globl` because SHOCKPAL names the fallbacks and the rig's expectation reads
  the beat out of `src/MK2.MAP`.
  **THE PAIRING IS PROVED BY CONTENT**: `--check` requires each PURPL/REDEL
  record to be the same DRAWING as the FREZ record it stands in for - identical
  brightest channel in all 64 slots - and its hue to point the right way. 18 of
  18 records, 64 of 64 slots. The same test on the ELEC family is 45/64 and
  47/64 for `TMELRED_P`/`LKELRED_P`, which were redrawn rather than re-hued, so
  it is reported there and required for FREZ.
  **THE PALETTE COUNT IS NOT EVIDENCE about the FREZ beat** - the old cyan
  wiring also gave four distinct palettes, both solid flashes and the right ELEC
  beat, so the rig asserts it BY NAME (`-Mode cycle`/`victory`, 6/6 and 6/6).
  **AND SO DOES THE CRACKLE OVER HIS OWN BODY** (`raiden_crackle_pal` /
  `raiden_crackle_offer`, MKGUYS.ASM; `src/RDCRACK.ASM`, generated by
  `tools/make_raiden_crackle_palettes.py`, Phase D). The ambient `RN*BOLT` flash
  is painted against the COSTUME layout - `ELEC_P` has 53 entries and the art
  indexes 63 - so it wears a COSTUME palette and its hue is ONE SLOT of it:
  **slot 63, 60% of the lit pixels, measured off the art every run** (24 is the
  white arc core, 48-57 a grey fringe, and 62 is not drawn at all despite the
  old comment). `data/MK2PALS.IMG` gave all five Raiden costumes the SAME
  crackle blue, so a red Raiden threw red lightning, fried the man red and
  crackled BLUE. **The two new colours are LIFTED, not invented**: every palette
  `raiden_costume_pal` used to name outright differs in exactly that slot -
  `RADRED_P` (31,3,1) red, `RADALT4_P` (18,5,31) purple, `RADBLU_P` (6,25,31)
  blue - so the crackle colour was always per-costume and was lost when the
  costumes moved to MK2PALS.IMG. The BLUE rows name the costume palette itself
  (a repaint in IMGTOOL still moves them); only the four that must differ are
  generated, each a COPY of its own costume with that slot replaced, so the
  white core and that costume's fringe are untouched. **A compressed record's
  per-row lead/trail skip bytes are load-bearing in the measurement** - decoding
  without them is garbage that still looks like a histogram, and the first cut
  picked slot 15. Rig: `-Mode crackle` (6/6, both crossed
  controls FAIL), which judges the BLUE lanes two ways - no `RDCRK_*` allocated
  AND the costume palette's refcount rising, the flash object's own `getfpal` -
  because otherwise a lane where nothing fired passes for free. **That refcount
  also tells a FAILURE from an UNMEASURED run**: a coloured lane with no
  `RDCRK_*` is the old behaviour if the costume palette's refcount rose (the
  flash fired and drew in it) and NO VERDICT if it did not, and without that
  split the crossed blue lane returns NO VERDICT and cannot catch the very
  regression it exists for.

  `<XX>` is the VICTIM, not Raiden - the flash is his own sprite repainted - so
  there is a twenty-row table per colour. The three bolt palettes are authored
  in `data/MK2PALS.IMG` beside the costumes themselves; the victim ones are
  `data/ALLDUDES.IMG`'s, where **Midway drew all three sets and wired only the
  blue one**. Carried by `tools/sync_raiden_elec_palettes.py` and
  `tools/make_shock_palettes.py`, both `--check` in Phase D. A repaint is: edit
  in IMGTOOL, re-run the tool, rebuild.
  **THE LANE IS RESOLVED, NOT READ OFF `oflags2`.** Those bits hold the lane he
  CLAIMED, and `costnodup` can roll player 2 forward off them, so a man wearing
  the next costume along would have thrown the PREVIOUS costume's lightning -
  `blood_pal_a0` carries the identical fix for gore, for the identical reason.
  `raiden_pal_lane` (MKGUYS.ASM) therefore ends in `costume_lane_shift`, and
  THREE tables hang off its one index, all parallel to `costume_offer` (same
  lanes, same order, `.if costcoin` on the same row): `costume_offer` itself,
  `raiden_elec_offer` for the bolt, `shock_elec_colours` for the flash.
  `shock_elec_colour` runs on the VICTIM, so **finding Raiden is its whole
  job**: he is either the man himself (`raiden_victory` flashes Raiden with his
  own shock palette) or the man opposite, since every electrocution takes the
  victim over from Raiden's process. Anybody ELSE electrocuting keeps the blue
  set - Rain's lightning fatality runs the same beats, and reading a lane off
  RAIN's `oflags2` would have coloured his victim by Rain's costume, a pairing
  nobody authored.
  **`raiden_costume_pal` WAS READING PALETTES RAIDEN DOES NOT WEAR.** The
  ambient `RN*BOLT` crackle is drawn against the COSTUME layout (`[62]` its
  inner electric colour, `[63]` its outer), and that routine still named
  `RADBLU_P` / `RADALT_P` / `RADALT2_P` / `RADALT4_P` / `RADWHI_P` / `RADRED_P`
  / `DRKRAID_P` outright after `make_costume_palettes.py` repointed
  `character_palettes_1..7` at MK2PALS.IMG. On his DEFAULT costume exactly 2 of
  64 entries had drifted - **and both were `[62]` and `[63]`, the only two the
  crackle draws in**; Start+LK was 45 of 64 out. It resolves the lane now.
  **EVERY ELECTROCUTION RUNS THE SAME FOUR BEATS** - FREZ, ELEC, WHITE, BLACK
  (`shockcyc`, MAINEQU.ASM) - off ONE table and ONE stepper,
  `shock_cycle_pals` / `shock_next_beat` (MKGUYS.ASM). Five sites:
  `shocker_shaker` (MOVES.ASM - the grab, and `do_raiden_fry` through it),
  `lightning_stumble` (MKREACT.ASM - the bolt's victim),
  `raiden_bolt_shock_victim` and `rd_lifted_victim` (MKDEATH.ASM - both
  fatalities' held victims) and `rnf_victim` (MKRAINF.ASM - RAIN's fatality).
  **Four of those flickered ELEC against the man's own colours**, so the same
  current read as two different effects depending on how it was delivered, and
  MKRAINF carried a SECOND copy of the table. `shock_next_beat` hands back the
  ROUTINE rather than calling it, because the two kinds of caller reach the
  victim differently: his own process calls it outright, while Raiden's process
  goes through `zappal_change` (MOVES.ASM), which swaps a8/a13 for the call.
  The phase is GLOBAL, not per-process, so a sequence that hands the man from
  one routine to another keeps stepping instead of restarting on FREZ each time
  - which is what `do_raiden_fry`'s one-pass `shocker_shaker` calls have always
  relied on; only one man is ever being electrocuted. `shockcyc 0` is retail's
  two-beat flicker and **the mask and the table are all that change**, so no
  call site has to know which it is.
  **`rvic6` (MKCANNED.ASM) IS ON THE CYCLE TOO** - Raiden flashing HIMSELF in
  his victory pose. It is the one site where the man wearing the current IS
  Raiden, which is why `shock_elec_colour` reads the object's own ochar before
  it looks at `p_otherguy`: a red Raiden crackles red, in his own `RDELRED_P`.
  The twelve beats and the 96 ticks are exactly what that loop always ran, so
  only what they PAINT changed. **And he has to be dressed again afterwards**:
  the old loop ENDED on `player_normpal`, and twelve beats of a four-beat cycle
  end on BLACK - which would hold him as a solid black silhouette in his
  victory pose for the rest of the match. `local_wait_forever` is the only way
  out of `raiden_victory`, so one `calla player_normpal` after the `dsj` covers
  it, and `-Mode victory` in the rig is there to keep it covered.
  Rig: `tools/run_raiden_elec_test.ps1` (6/6 costume, 6/6 cycle, 6/6 victory;
  `-Negative` must FAIL, 3 of 3 do). See
  [doc/RAIDEN_ELECTRIC_PALETTES.md](doc/RAIDEN_ELECTRIC_PALETTES.md).
- **EVERY COSTUME IS AUTHORED IN `data/MK2PALS.IMG` NOW** - `<XX>MAIN_P`,
  `<XX>ALT1-5_P` and their `<XX>BLD*_P` twins, carried onto the lanes by
  `tools/make_costume_palettes.py` (Phase D `--check`). The slot number IS the
  lane, so no table moved. A repaint is: edit in IMGTOOL, re-run the tool.
  Costumes used to live wherever they were authored - NINJAS3.IMG, KAT104.IMG,
  RADBOLT1.IMG, the read-only tree, thirty-odd hand carries in `IMGPAL*.ASM` -
  and finding which library owned one was the job.
  **A lane with no record of its own wears the fighter's DEFAULT**, costume and
  blood alike, so an unauthored button looks like it does nothing rather than
  showing a palette from the tree's history - and the no-duplicate rule still
  rolls player 2 forward if player 1 is on that default.
  **START+COIN IS A COSTUME LANE AGAIN** (`costcoin .set 1`, 2026-10-05, the
  user's call): the generator reads the switch and feeds it the library's
  `<XX>ALT6_P` / `<XX>BLD6_P` (Liu Kang, Cage, Mileena, Shang, Sub-Zero,
  Reptile, Rain today; the rest take their default - Kitana included: her
  BIV hue-cycling outfit was RETIRED 2026-10-06, the user's call). It was OFF from 2026-09-27: at `costcoin .set 0`
  the claim is gated in MKSEL, the rows are flattened to the default, and the
  lane is out of the no-duplicate walk. Disabling it in the DATA alone would
  have made a coin insert shift player 2 onto Start+HP, which is the opposite
  of disabled.
- **IN A ONE-PLAYER GAME THE CPU WEARS A RANDOM COSTUME** (`dronecos`,
  MAINEQU.ASM; `drone_costume_pick`, MKGUYS.ASM). Rolled ONCE PER OPPONENT
  (`setup_players` runs once per ROUND, so `@dcos_for` - the ochar+1 it was
  rolled for - is what stops the CPU repainting between rounds; stored raw, a
  first opponent of Kung Lao would read as "already rolled"). Written as player
  2's claim in `@alt_pal_owner`, so every existing path resolves it and
  `costnodup` still keeps him out of the player's colours. It rolls among
  DISTINCT palettes, not lanes, because every unauthored lane falls back to the
  default. **Noob, Smoke and Khameleon are included** - it reads the live tables,
  not the generator's roster - but Smoke and Khameleon have ONE distinct palette
  each today so their roll is inert, which for Khameleon is the safe outcome
  (a different id would break `kham_disguise_pal_proc`). No `modu` (it appears
  nowhere in this tree): mask to a power of two and reject, bounded at 8 tries.
  Private xorshift off `@rand`'s VALUE, so netplay is untouched; attract mode
  excluded. **Hooking `pnorm2` alone did NOT work** - `pnorm_check_temp_alt`
  refuses to repaint unless the CALLING process has `pb_alt_pal`, and
  `make_player_obj` clears `p_flags` just before it, so the INITIAL costume
  never went through the rule and both fighters came out of a mirror in one
  palette. `make_player_obj`'s own direct palette read goes through
  `costume_pal_a0` too, and sets `oid` there, because
  `make_player_1_obj`/`_2_obj` set `oid` only AFTER it returns. Rig:
  `tools/run_costume_test.ps1 -Mode drone -Char noob -Rolls 5` (5/5, all four
  lanes; `-Mode nodup` 1/1 on Liu Kang and Scorpion). **Three rig traps**: force
  `p2_state = 0` as well as `p2_char` or the game calls P2 a human and the pick
  is correctly refused; pin the pair until the fight RUNS (`setup_players` reads
  `@p2_char` in the round intro); and a scripted rig boots deterministically, so
  `@rand` - the seed - is identical every run and every roll comes out the same
  (`CT_JITTER`). See [doc/COSTUME_PALETTES.md](doc/COSTUME_PALETTES.md).
- **THE MIRROR MATCH HANDS PLAYER 2 START+HP, NOT START+LP** (2026-10-05, the
  user's call; retail and this tree until then used `character_palettes_2`).
  `check_same_character_pal` (make_player_obj), `player_ugly_pal` and the P2
  select preview (MKSEL) mark him EXACTLY as a Start+HP pick -
  `m_start_alt_pal|m_repalt2_pal`, `character_palettes_4` - so every lane
  reader (Raiden's bolt/flash/crackle, the blood palette, costnodup) agrees
  with what he wears. Entries below that say "Start+LP / the mirror" or
  `_2` = the mirror predate this. **The bit is not OWNED**, so
  `player_normpal` tells a pick from the mirror's by `@alt_pal_owner` (bit 4/8):
  an unowned Start+HP bit jumps straight to the mirror test. Routing it through
  `pnorm_rep_owner_test` instead CLEARS it and `pnorm_check_temp_alt` returns
  without a repaint - right colours, lane bits gone after the first knockdown
  (measured). `player_nice_pal` clears the mirror's bits too, which is what
  takes them off a Shang reverting out of a morph mirror. Liu Kang's red dragon
  is on Start+LP (`lk_block`), so it is never handed out by a mirror. Rig:
  `tools/mirror_costume_test.lua` (`MC_CHAR`, `MC_NEG=1` must FAIL): identifies
  both palettes by `palram` against the ROM's lane tables, at fight start and
  after three uppercut knockdowns - Liu Kang, Raiden, Sub-Zero PASS, control
  FAILS. `run_rain_palette_test.ps1` and `run_mk2pals_test.ps1` still expect
  the old mirror lane.
- **TWO PLAYERS NEVER WEAR THE SAME COSTUME** (`costnodup`, MAINEQU.ASM;
  `costume_pal_a0`, MKGUYS.ASM). A costume the other player has is refused and
  the button rolls forward: default, Start+HP, LP, HK, LK, Block, Coin,
  wrapping. Retail only stopped two players claiming the same BUTTON, never the
  same COLOURS. **Only player 2 yields** - a symmetric rule makes the two CHASE
  each other and the select screen oscillates while both buttons are held; MK2
  already picked P2 as the one who gives way. **It resolves from GLOBAL STATE
  only** (`alt_pal_owner`, `p1_char`), so the preview and the fight agree with
  nothing passed between them - `player_normpal` re-resolves on every
  knockdown, morph and Raiden dim, so a remembered answer would come undone on
  the first repalette of the round. `costume_pal_a0` is a drop-in for
  `get_char_long`, which is why one hook at `pnorm2` covers the whole fight.
  **The blood palette moves with the costume** (`blood_pal_a0`): a shifted P2
  still has his CLAIMED lane in `oflags2`, so resolving gore off those bits
  dressed him in the cut-up palette of the costume he did not get and his body
  changed colour the first time he was cut. TWELVE refusals came out of
  MKSEL.ASM, in two families - the `ps*` previews and the `cs*` select
  processes; the `cs*` ones WRITE the claim, so leaving those in would have let
  P2 see one costume and fight in his default. See
  [doc/COSTUME_PALETTES.md](doc/COSTUME_PALETTES.md).
- **START+HP IS RETAIL'S MIRROR-MATCH COSTUME** for all twelve of Midway's
  fighters (`character_palettes_4` / `bloody_character_palettes_4` rows 0-11,
  MKGUYS.ASM). `character_palettes_2` is the costume a fighter wore on
  Start+LP and the one player 2 was handed in a mirror; this tree had moved
  several of them, so the shipped alternate was no longer reachable on the slot
  it shipped on. The twelve, plus the twelve BLOODIED palettes the cut-up art
  is drawn in, are lifted out of **mk2-readonly** by
  `tools/make_mk2pals.py` into `data/MK2PALS.IMG` + `src/MK2PALS.ASM`.
  **They are COPIES under new `M2*_P` names.** Pointing slot 4 at `tmgold_p`
  would make it an ALIAS of slot 2 - a repaint in IMGTOOL would move the mirror
  match with it. 3,302 bytes of program ROM.
  **The words come from the read-only tree because two DRIFTED here**:
  `KATBLU3_P` by 28 entries of 64 and `RADRED_P` by 2. Retail's `KATBLU3_P` is
  `KAT11.IMG:KATBLU3_P`; this tree's symbol of the same name is
  `KAT1.IMG:KATBLU2_P`. Same name, two palettes - so the generator matches
  provenance BY CONTENT and prints the record.
  `data/MK2PALS.IMG` is in NO LOD: LOAD2 never reads it and no pixel reaches a
  ROM, so a repaint that was never re-imported changes nothing and errors
  nowhere - hence Phase D's `--check`. It carries a stance frame and a torso-rip
  frame per fighter because a palette on its own cannot be judged; the ninjas
  and the two female ninjas share a body, so those records hold identical pixels
  and differ only in `palnum` (which is offset by THREE).
  **This displaced ten costumes off the select wheel** - `TMBLACK_P`,
  `LIUALT2_P`, `JCALT1_P`, `UGALTHP_P`, `KITALT2_P`, `MILALT2_P`, `TMOVIE_P`,
  `RADALT_P`, `REP_P`, `SCORP_P` (`SUB_P` survives as Start+Coin) - and makes
  Start+HP a duplicate of Start+LK for the three ninjas and of Start+LP for the
  eight fighters whose `character_palettes_2` was never changed here.
  Rows 12+ are untouched: Kintaro, Kahn, Smoke, Noob, Jade, Ermac, Khameleon
  and Rain have no retail alternate.
  Rig: `tools/run_mk2pals_test.ps1` (12/12 PASS; `-Negative` must FAIL 12/12).
  It drives the REAL GESTURE - 1P Start held across P1 High Punch at the select
  screen, which is what `psr_p1_masks` (MKSEL.ASM) claims the lane on - rather
  than poking `@alt_pal_owner`, which would prove the table is wired and nothing
  about whether a player can reach it. **It checks the LANE before the colours**:
  a colour mismatch when the gesture missed is a rig problem, not a wiring
  problem, and the two look identical in a bare diff. The naive control
  (compare against Start+LP) CANNOT discriminate for eight of the twelve now
  that those rows are the same palette, so the control is the palette slot 4
  held BEFORE the change, and the rig refuses a trial whose two expectations
  are identical instead of passing it.
  See [doc/MK2PALS_START_HP.md](doc/MK2PALS_START_HP.md).
- **The five ninja-bodied fighters wear their UMK costumes BY DEFAULT**
  (2026-09-24). Sub-Zero, Reptile, Scorpion, Ermac and Rain each got an
  authored pair in `data/NINJAS3.IMG`, and the pair is now what they wear with
  no button combo at all. The costume each one displaced moved down into the
  Start+HP slot the new default vacated:

  | ochar | default (`_1`) | Start+LP / mirror (`_2`) | Start+HP (`_4`) |
  |---|---|---|---|
  | Sub-Zero (8) | `SUBUMK3_P` | `SBUMK2_P` | `M2SZBLU_P` (was `SUB_P`) |
  | Reptile (9) | `REPUMK3_P` | `RPUMK2_P` | `M2RPGRN_P` (was `REP_P`) |
  | Scorpion (10) | `SCUMK3_P` | `SCUMK2_P` | `M2SCYEL_P` (was `SCORP_P`) |
  | Ermac (17) | `ERUMK3_P` | `ERUMK2_P` | `ERMAC_P` |
  | Rain (19) | `RNUMK3_P` | `RNUMK2_P` | `RNUMK1_P` |

  **Three of those Start+HP slots have since been taken** by retail's
  mirror-match costumes (see the Start+HP entry above): Sub-Zero, Reptile and
  Scorpion now wear `SUB2_P`/`REP3_P`/`SCORP2_P` there, as `M2*` copies, which
  is the same colours as their Start+LK. `SUB_P` is still reachable on
  Start+Coin; `REP_P` and `SCORP_P` are on no lane any more. Ermac's and
  Rain's rows (17, 19) are outside that change and still hold their originals.

  `character_palettes_2` is the **secondary** default: it is both Start+LP and
  the costume player 2 is handed automatically in a mirror match, so promoting
  the pair changed both at once. **Repointing a costume row is four edits, not
  one** - the costume table, its blood counterpart, `death_fade_excludes` and
  the `.ref`/`.globl`. The default's blood is the FIRST long of its
  `bloody_palettes` row (the only one `change_to_bloody_pal` reads); the
  alternates' live in `bloody_character_palettes_N`, lane for lane. No UMK
  costume has a bloodied variant, so each sits in its own blood row and stays
  clean when it bleeds - Rain's row has always done exactly that. Slot 4 wears
  real old costumes again, so it took their real blood palettes back
  (`SUBBLD_P`, `REPBLD_P`, `SCRBLD_P`, `BBQBLD_P`).
  **KITANA is not in this** - her silver (`KATSILV_P`, `data/KAT104.IMG`) is
  Start+LP only; she has no new Start+HP costume and her default is still
  Midway's `KATBLU_P`.
  This also changes what a morphed Shang wears, since `pnorm_morph_default`
  resolves the TARGET's default. Rig: `tools/run_rain_palette_test.ps1` (a Rain
  mirror is the only fight that exercises `_1` and `_2` at once).
- **RAIN is a hidden fighter: Scorpion + Block x5** (`ft_rain` = 19, so
  every char-indexed table is **20 rows** - `tools/audit_char_tables.py` gates
  it). A ninja body on the shared TABLE1: REPTILE's stance run BACKWARDS (`j_rprv`, 1,7,6..2 - the lane Reptile himself used until 2026-09-25, when he went back to plain `j_rpst`) at Reptile's own 6 ticks a frame (`stance_speeds` row 19), Sub-Zero's victory (`j_szvic`), REPTILE's walk and skip (`a_rp*`) - each is his own `ani_ochar_jump` in MKNJ's shared lanes - in his own
  `RNUMK3_P`, and `RNUMK2_P` when player 2 mirrors him or picks Start+LP.
  Both are authored in `data/NINJAS3.IMG` and carried by
  `tools/sync_alt_costume_palettes.py`; `RNUMK1_P` (`data/NINJAS10.IMG`,
  `tools/sync_rain_palette.py`) was his default until 2026-09-24 and is now his
  Start+HP costume (both Phase D `--check`; nothing promotes an IMG palette into
  the ROM, so a recolour would otherwise ship the old colours silently).
  **Both libraries carry a palette called `RNUMK2_P` and their words DIFFER** -
  the NINJAS3 one is the one that ships, and one tool owns the symbol. The
  remaining three Start+button alternates (Block, HK, LK) are still
  `SUBALT4_P`, the borrowed purple Sub-Zero; there is no bloodied variant of
  any of his own costumes, so he stays clean, and all three are in
  `death_fade_excludes`.
  (Until 2026-09-23 his default was `RNMAIN_P` out of NINJAS3.IMG - RNUMK1_P
  is NOT a rename of it.) Rig: `tools/run_rain_palette_test.ps1` forces a
  RAIN vs RAIN mirror - the only fight that exercises both slots at once -
  and compares the COLOUR RAM each object is pointing at against the IMG's
  own words, regenerated into `tools/rain_palette_expect.lua` on every run
  so it cannot pass against a stale number. `-Negative` crosses the two
  expectations and must FAIL - swapping slots 1 and 2 is the likely
  regression, so that is the control worth having. His
  own `BAR_RAIN` plate (MKSCORE.IMG, 32x10, via MK6MIL.LOD), "RAIN WINS" with its
  announcer line (winner_speech 065h, track $0364), "Rain" called when he is
  picked (php_rain -> triple_sndtab2 $66 -> track $0578, the name alone - it
  reuses the RAINNAME stream, note (48b)), Scorpion's VS portrait, and the hidden-fighter 3/4 damage +
  walk rules. Unlock is `rain_select_enable` (MAINEQU) in the pattern Smoke's
  compiled-out cheat used; `check_hidden_blk_cheat` tests Rain FIRST. **His
  LIGHTNING BOLT, Back,Back + HP** (`rain_hi_punch` -> `do_rain_bolt`/
  `rain_bolt_proc`, MKZAP; `r_rain_bolt`, react_to_nj 1dh) is MK Trilogy's
  N64 move call for call (plus smoke: the victim puffs `smoke_a_1` via
  `rain_bolt_smoke`, `rain_bolt_smokes`), he poses on Ermac's slam lane (`rain_anitab2`
  row 9 - Trilogy borrows ANIM_ERMAC_SLAM too) and the bolt falls where the
  victim STOOD at the cast, so stepping away dodges it. The art is the N64's
  own `RAINLT1-6` + `RAINLT_P`, decoded out of the Trilogy tree's text
  listings by `tools/trilogy_rain_bolt_extract.py` - type 0x10 is
  `uncompress_16`, recovered from the MIPS object, and rows are stored padded
  to 4 px - written by `tools/make_rainbolt_img.py` (Phase D `--check`, which
  also guards the hand-carried `RAINLT_P` in IMGPAL6) re-anchored on the
  strike point, and packed in bank-1 `data/RAINBOLT.LOD` (0x9E8000, top of the
  MK6MIL free run). 9/3, straight up on TABLE1 `03ah` (orb-banged), refused on
  a boss / a man 3 hits into a string / inside `rain_bolt_cool`; the drone
  guards it like Noob's portal (`c_rain_bolt`, act 018h). **The bolt is
  Trilogy's own SPRITE shaft again** (`rainbolt_geo .set 0`, 2026-09-21, the
  user's call - RAINLT1-6 on `a_rain_fork` / `a_rain_strike` / `a_rain_after`).
  The CPU-drawn shaft below is shelved, not deleted: `rainbolt_geo .set 1`
  brings it back, and its block in MKZAP assembles on `rainbolt_geo+rainfatal`
  because the lightning fatality draws with the same `rgeo_seg`/`rgeo_xs`/
  `rgeo_jit`. What `rainbolt_geo 1` does: `rain_geo_bolt` (MKZAP) queues ~40 `geo_seg` lines a tick - white
  core + blue glow + deeper-blue side forks, re-rolled every 2 ticks - in the
  bolt object's OWN colour map (`opal` in the segment's high half), which is
  why they come out in RAINLT_P's blues and not the stage's (the problem that
  shelved Raiden's geometry bolts). One seed from `@rand` per bolt, then a
  private xorshift, so netplay's gameplay RNG stream is untouched. The forks,
  ring and scorch stay sprites (`a_rain_strike_g`, rain_anitab2 0bh); the
  forks telegraph is CPU-drawn too (object `m_inviso` for it - cleared by
  hand, NOT clear_inviso, which turns m_shadow on for bank-1 art), so no
  painted lightning is drawn at all.
  **His WATER MOVE, Down, Forward + HP** (`rainzap`, MAINEQU; `rain_hi_punch`
  tests it before the bolt -> `do_rain_zap` / `rain_zap_proc` / `rain_hold`,
  MKZAP; `r_rain_zap`, react_to_nj 1eh) is Trilogy's `do_proj_rain_zap` /
  `r_rain_zap` / `rain_movement` (N64 MKZAP.C): a storm cloud off MK2's ninja
  ice throw (TABLE1 026h) that catches while it FORMS (three hand-placed boxes,
  `stk_rain_zp1-3`, nj_strikes 24h-26h) or in flight (`stk_rain_zap`, 23h, 20/3),
  bursts in RNZAP splash with 16 RNDROP raindrops (`rain_drop_proc`, bare
  gso_dmawnz objects, `@blood_rand`, pid/oid_fx), and HOLDS the man
  (`act_rain_storm` 050eh) for Trilogy's 64 ticks while `rain_zap_proc`
  fastxfer's Rain into `rain_hold` (`act_rain_hold` 030ch): Rain stands in his
  stance and STEERS him with the stick, 15/14 px a step every 4 ticks, Jade
  Flash (0358h) every 14. Then he drops (`flight`, never_ani, 0a000h) and gets
  up. A killing hit skips the hold; refused on a boss, 4 hits into a string,
  or a man already in a cloud; the drone treats it as a straight fireball
  (`c_rain_zap`, act 019h). **Trilogy's own 1-shake bug is kept**: its
  `if (rain_shake(..)); break;` runs the second shake once, and that 64 is the
  shipped timing. Art: Trilogy's RAPROFORM/RAPROLOOP/RNZAP/RNDROP out of the N64
  tree by `tools/make_raincld_img.py` (on `tools/make_rainn64_img.py`'s
  decoders, transcribed from U64MAIN.C: types 0x0F/0x10/0x16-0x18) into bank-1
  `data/RAINCLD.LOD` (0x9DC000, hard under JDROD). Anipoints are scaled N64 ->
  arcade (x/0.80, (y+9)/0.85 - the +9 is `adj_rain_proj`), pixels stay N64-size
  like the bolt's. RNZAP packs at 3bpp off an 8-entry IMG-only `RNZAP_P`
  because an explicit PPP> 3 is silently raised to the palette's depth.
  Rig: `tools/run_rain_zap_test.ps1 [-Snap]` (far/close/still/nomo/kill).
  **THE CLOUD KEEPS THE COMBO UP WHILE IT HOLDS HIM** (2026-10-01, reported:
  "Rain's projectile move doesn't hold a combo when the opponent is still in
  the air"). The catch and the hold were always fine - what broke was the
  KOMBO KOUNTER's clock underneath. `cmb_tick` is `hudcmb_hold` = 40h = **64
  ticks** and only a HIT re-arms it, and `r_rain_zap`'s hold is 6 half-shakes
  at 3 ticks plus 2 at 7 = **exactly 64**, so the window closed with the man
  still hanging in the cloud and the next hit opened a fresh string.
  `cmb_holding` / `cmb_holds` (MKDISP.ASM) already exists to pause the clock
  for precisely this - Sub-Zero's freeze, Scorpion's spear, the floor ice,
  Jax's elbow - and `act_rain_storm` was simply not in the list, the cloud
  being one move newer than the table. **A NEW HOLD HAS TO BE ADDED THERE BY
  HAND**: nothing derives the list, and a hold longer than 64 ticks silently
  loses the readout it was holding.
  **AND IT ONLY SHOWS IN THE AIR** - which is why it went unreported for so
  long. `hudcmb_min` is 2, so a cloud thrown at a man on his feet is the
  OPENING hit of its string and puts no readout on screen to lose; the only
  way it lands as hit 2 or later is to catch somebody already juggled. A rig
  that threw it from neutral would have measured nothing wrong.
  Rig: `tools/run_rain_zap_combo_test.ps1` (2/2; `-Negative` patches
  `act_rain_storm` back out of `cmb_holds` in the BUILT ROM - one word, via
  `tools/rain_zap_combo_negrom.py`, no second build - and the trial must FAIL,
  measured losing 41 of the 64 ticks). Its control `pinnedair` is what makes
  the pause specific: the same victim pinned airborne in plain `act_reacting`
  must still run the clock to 0, or "frozen" would only mean the clock never
  runs for a man off the ground. **Three rig traps, all of which read as the
  bug**: at the cloud's own throwing range a setup Low Kick does not reach, so
  the cloud opens its own string; **below `hudcmb_min` `cmb_fly` is never
  created and `cmb_fly` is what DECREMENTS `cmb_tick`**, so a 1-hit string
  leaves the clock parked at 64 and a probe reads that as a perfect pause; and
  `p_hit` returns to 0 the moment the victim recovers, which `hud_combo_hit`
  calls a NEW string whatever the clock says - so the setup hit only chains
  while he is still in a reaction, which is what pinning him off the floor is
  for (`reaction_exit` sends an airborne man to `fall_on_my_back`, and he
  cannot land to end the string).
  **The cloud is STEERABLE up and down in flight** (`rzapaim`, MAINEQU;
  `rzap_aim`, MKZAP) - Trilogy throws it flat, ours takes the same joystick
  nudge the forceball and Kitana's returning fan already take, and the same
  `030000h` ceiling both of those settled on (3 px/tick against the cloud's
  own 10 forward, so ~17 degrees). Uncapped, a held stick STACKS speed for
  the whole flight and it rockets past the target - the reason
  `orb_aim_ymax` exists. Not steerable once Kahn has clapped it back
  (`proj_is_deflected`), and `proj_is_deflected` must be asked BEFORE a13 is
  swapped to the thrower - it reads the PROJECTILE's `p_flags`. Both helpers
  are `calla`: `proj_is_deflected` is ~8,500 lines down MKZAP and
  `joystick_in_a0` is in JOY.ASM, neither inside `callr`'s 32KB.
  **The water FLOWS - a palette cycle** (`rzapcyc`, `rzap_cycle`, MKZAP),
  which is what MK2 itself uses for water (`battle_cycle` cycles the
  Wasteland's WATER 21h, `dedpool_cycle` the acid). The shape never moves;
  only the colours do. **It works only because the ART WAS RE-INDEXED**:
  Trilogy's RNCLOUD_P is in no order (highlights at 1-5, darks and mid-tones
  interleaved after), so rotating entries swapped unrelated colours and read
  as a corrupt palette - the failure `project_palette_cycle_scan` documents.
  `reindex_cloud` (`tools/make_raincld_img.py`) sorts the shades into one
  contiguous LUMINANCE ramp and remaps every pixel with them. **Slots 0-4 are
  frozen**: the burst (RNZAP) draws from indices 0-4 and `RNZAP_P` IS this
  palette's first 8 entries, so a colour sliding past slot 7 would fall
  outside its 3bpp window - the tool asserts it. The art had to be smoothly
  shaded for this to read as flow, and it is: median neighbour step 1.0 luma
  of a possible 31, 67% of adjacent pixels within 2. The window is chosen on
  COVERAGE - slots 5-20 are the dark-to-mid body, ~66% of the cloud's pixels
  - and the brightest shades are left out so highlights stay put. Rotation is
  two `palset` transfers straight out of the ROM palette at an offset (no
  scratch buffer, and no cycle PROCESS to keep alive alongside the
  projectile); `opal` already holds the palette in bits 8-15, which is
  exactly `palset`'s `a1`. `rzap_cyc_count` **must stay a power of two** -
  the code masks with `count-1` rather than use `modu`, which nothing else
  in this tree uses. A `p_store6` flag gates it: a failed `getfpal` leaves
  the object on map 0, which is `boonpal`, and rotating that would recolour
  the HUD. **Changing the art means a FULL `build.py`** (Phase A/LOAD2 +
  `makevrom.py`), not `--asm-only`.
  **The SLOSH is compiled out** (`rzapslosh .set 0`, 2026-09-23, the user's
  call: "the water feels schizophrenic throwing as is versus clean how it
  was"). Two causes were found and fixed before it was switched off, and the
  fixed version is what `rzapslosh .set 1` now gives: it stepped every TICK
  while the art animates every THREE (so the shape changed three times per
  drawn frame and read as jitter - it now steps once per drawn frame), and
  it opened at 28%, which is forceball territory (now 14%, settling to a 4%
  ripple). Kept because the mechanism is sound and documented:
  **the hardware
  counterpart of Reptile's forceball throb, same free DMA field (`oscale`,
  no art/object/palette) and the OPPOSITE law: the forceball pulses
  symmetrically and ENDLESSLY because it is driven, while a body of water
  takes ONE big displacement when it is flung (flat and wide along its
  travel) and then a DAMPED oscillation that settles to a small residual
  ripple. `rzap_slosh_steps` is the table; pairs are near reciprocals so the
  mass keeps its volume. The multipart re-lay that stops the scale
  COMPOUNDING is now shared: `orb_scale_apply`, split out of
  `orb_squash_pulse`, called `callr` by the forceball (adjacent) and `calla`
  by the slosh (5,200 lines away - a shared routine is exactly where a
  silently-wrapped `callr` bites). The phase is initialised before the
  flight because `getprc` clears only `p_action`/`p_flags`, so a stale
  `p_store3` would drop the opening fling. Rig:
  `tools/run_rain_zap_aim_probe.ps1` - measures oyvel/oypos/oscale off the
  cloud OBJECT. **Find the cloud by walking `objlst`/2/3 for the only
  non-fighter moving at its speed**: `p_slave` looks like the handle and is
  useless, because `back_to_normal` calls `delete_slave` long before the
  cloud lands. Measured: capped at exactly 3.00 px/tick both ways, climbs 59
  px / dives 46 px over a flight, and the slosh's deviation decays 56 -> 24.
  **Launches this high float shadows**: a shadow CLIMBS a quarter of its
  height off the ground (shadow_p1p2), and a stage on init_bakmods' 255/255
  default never clips it - a man thrown 234 px up casts a black silhouette
  ~58 px up in the scenery. Clipped to the measured floor on the Dead Pool
  (16/21), the Wasteland (`calla_battle` 33/12), THE TOWER (`calla_tower`
  68/6) and the Warrior Shrine (`mk1wshr_calla` 58/19); every other stage is
  still 255/255 and would need its floor measured the same way. **A routine that sleeps must be jsrp'd** - the first `rbp_live` was
  callr'd and reset the board. **And - MK Trilogy's SUPER ROUNDHOUSE, as a KNEE LINK** (Baraka's
  double-knee shape; `rain_knee`, MOVES.ASM): throw the ordinary knee (HK/LK
  close), then Back + HK in UMK3's combo window (`process_combo_table`: ticks
  4-9 after the knee lands, `RKN_WIN_SKIP`/`RKN_WIN`; an earlier press is
  remembered and fires on tick 4, so the super starts on a fixed beat) - and
  the knee carries on, at one speed (`RSK_SPEED` 2, `RSK_ACTIVE` 3,
  `RSK_RECOVER` 3 - the WAX's holds are stepped over; see
  [doc/RAIN_KNEE_SUPER_COMBO.md](doc/RAIN_KNEE_SUPER_COMBO.md)), along `data/RAINSUPROUND.WAX`
  (`a_rain_suprh`, rain_anitab2 0ch: NJKNEE4-6, then NJROUNDKIK7..1), striking
  on NJROUNDKIK5 with `stk_rain_roundh` (nj_strikes 21h, 14/8). No link, a
  late one, one without Back, or one inside `rain_rh_cool` (80 ticks): the
  stock knee, 16. **And his ORDINARY ROUNDHOUSE - Back + HK - IS the super**
  (2026-09-22, the user's call: Trilogy's `stat_do_roundhouse` `ft_rain`
  branch, and only that input - `do_roundhouse` tests `ochar` and jumps to
  `rain_roundhouse`). The roundhouse swing with `stk_rain_roundh` - 14 as a
  fresh hit, Trilogy's shorter holds (5 on a hit, retract 3) - and he wraps.
  No second button: the old Back+HK+LK pair (`rain_rh_pair`) and its hook in
  JOY's `joy_sweep_kick` are gone, so HK+LK on one tick is whichever handler
  won the scan, exactly as retail. It works against a man in the AIR too.
  **The one gate is Trilogy's own anti-spam** (`rain_rh_due`, MOVES.ASM =
  MKSTAT.C:1206): the super is refused only when the kick is inside
  `rain_rh_cool` (80 ticks = Trilogy's `0x50`) of his LAST super AND the
  other man's `p_hitby` is still `act_rhouse` - so a roundhouse LOOP gives
  the stock MK2 kick (30, speed 3, 10-tick hold, retract 4, strike `00dh`,
  no wrap), while a super off any other hit, or 80 ticks later, still comes
  out. Nothing new records it: `p_hitby` is stamped on every hit in JOY.ASM,
  where Trilogy's MKJOY stamps it. `l_roundh` feeds that gate and the knee
  link both - a knee linked inside `rain_rh_cool` of a roundhouse stays the
  stock knee. Measured by `tools/run_rain_chain_probe.ps1`: a second kick
  landing 23 and 40 ticks after the first is the stock one, at 88+ it is the
  super. **Judge that rig on DAMAGE, never the wrap** - `rain_rh_scan` only
  teleports a victim who reaches a screen EDGE, so the wrap measures where
  he stood, not which kick came out, and a run judged on it called 3 of 6
  trials wrong. Each kick has TWO legal numbers, fresh and `dmgscale`'d 3/4:
  stock 30 or 23, super 14 or 11.
  **And Trilogy's SECOND limiter is ported too** (`rhhalf`, MAINEQU.ASM):
  `r_rain_roundhouse` (MKREACT.C:2782) flags the victim once the STRING has
  taken more than 30% of a bar, and everything after it does HALF, floor of
  1, until he returns to neutral. MK2 had neither half of that - no
  `p_damage`, no `M_HALF_DAMAGE` - so both are built: `rh_cdmg` (damage taken
  this string) and `rh_half` (the flag), p1:p2 pairs in RAM.ASM indexed the
  way `get_tsl` indexes `l_roundh`. `bar_reducer` (JOY.ASM) halves and then
  accumulates what was ACTUALLY applied - after `ochar_xlate_damage`, which
  is where Trilogy accumulates too - so every damage source is cut, not just
  the move that armed it; `r_rain_roundh` arms it; `back_to_normal`
  (MKUTIL.ASM) clears both with `p_hit`, and `round_init_longs` (MAIN.ASM)
  clears them per round. Threshold `rh_half_dmg` = `full_strength*30/100` =
  48, so 49 arms it - **exactly 48 does not**, because Trilogy needs
  strictly more than 30%. **This is not `dmgscale`**: that cuts by a hit's
  POSITION in the string, this by how much LIFE has gone, and they compose.
  **`rh_half_dmg` must be defined below `full_strength`** - GSPA resolves a
  `.set` expression single-pass, so a forward reference aborts the whole
  assembly with "AN IDENTIFIER IN THE EXPRESSION IS INVALID". Both new sites
  test `pid_p1` AND `pid_p2` rather than defaulting to p2, because
  `react_xfer_him` is reached for projectile victims and `back_to_normal`
  takes non-fighter callers. Rig: `tools/run_rain_halfdmg_probe.ps1` (seeds
  `rh_cdmg` rather than driving a 49-damage combo, and measures the halving
  as an A/B of the same second kick armed vs unarmed: 11 against 23). The lane is GENERATED by
  `tools/rain_suprh_wax_import.py` (Phase D `--check`; edit the WAX, never
  the block) as frame,hold PAIRS off the WAX's per-frame `frame_delays` -
  only `rain_super_knee` walks it (never mframew), and the contact frame's
  hold IS its active ticks. The lead-in's holds are ignored: NJKNEE1-3 stay
  the stock knee's speed so an unlinked knee is unchanged. The knee runs a tick at a time instead of through `striker`
  and reads the button-close queue, because buttons are off for the whole
  knee; an early link is LATCHED so the knee still strikes on NJKNEE3.
  **The pin**: `stumble_back` slides the victim 3 px/tick for the whole
  continuation (with all-4 holds the contact was 24 ticks on and whiffed), so after a CLEAN knee
  `rsk_pin` holds him - through `set_x_vel` AND `oxvel`, because repell
  rewrites oxvel from the request every tick (his p_action stays 0303, so
  do not key it on act_reacting). Knee + super = 16 + 11 (dmgscale 3/4) =
  27, early link or hold-window link alike - contact is ~10 ticks after the
  knee connects on the current holds. `r_rain_roundh`
  (react_to_nj 1ch) flies him on Trilogy's literals and `rain_rh_scan`
  (MKPROP) wraps him back in from the far edge with `cos_edge` - NOT
  `f_noedge_obj`, which a mid-flight juggle could leave set. A victim kicked
  from the CORNER never gets x velocity (the clamp zeroes it), so the scan
  also runs at zero velocity when he is in the screen half away from Rain. Every button
  special row is `sucide`; `char_block` enters at `check_nj_dtp` (pit/stage
  fatality only - `sc_block` would give him the air throw). Adding him found
  five 19-row tables the audit never listed (`rd_lift_vic_scripts` and three
  Raiden-lift pose tables, `soul_blend_tab`) - now audited. Rigs:
  `tools/run_hidden_cheat_test.ps1 -Name rain [-WatchTrack 0578]` (the
  latch carries the TRACK, and any of the triple's three) and
  **And his FATALITY: Down, Down, Back, Forward + HK in FINISH HIM**
  (`rainfatal`, MAINEQU.ASM; `src/MKRAINF.ASM`) - MK Trilogy's own input for
  his second fatality (`sm_rain_hkc` -> `rain_bolt_strikes`). **Since
  2026-09-22 it is Trilogy's own SPRITE fatality** (`rnf_geo .set 0`,
  `rnf_salvo` in MKRAINF): arms up, the stage goes dark, one N64 RAINLT bolt
  strikes him and 13 more fall on him ever faster (Trilogy's
  `randu(3*ta10)+6`, each at his middle, mirrored at random, over everybody at
  `front_z+50`). **THE VICTIM IS HELD, NOT ANIMATED** (`rnf_victim`,
  2026-09-25): the first strike stands him on STUMBLE1 (his own TABLE1 row
  `023h`, first frame) where he stood and he keeps that one pose for the whole
  salvo - never a second frame, never turned round - while the ELECTROCUTION
  palette cycle (FREZ/ELEC/WHITE/BLACK, a beat every 3 ticks) runs
  CONTINUOUSLY to the split, he BUZZES 1 px each side of where he stood every
  tick (`rv_jitter`, measured from `p_store1` so it cannot drift), and he
  SMOKES (`rnf_body_smoke`: a `smoke_a_1` puff every 5 ticks, guarded on
  `p1_obj`/`p2_obj` and stopped by `rnf_split`, exactly as `rain_bolt_smoke`
  is - `smoke_a_1` walks its subject's multipart chain and `r_shocker_pop`
  bursts the body out from under it). Walking the stumble lane and
  `flip_multi`-ing him on every strike, which is what it did before, read as
  flailing rather than frying. The rig's per-tick line is the proof: the
  victim's sag and `oflags` never change and x alternates base-1/base+1.
  The 1st strike starts his jolt, the 3rd (`RNF_S_SPLIT`) is
  the return stroke and **BLOWS HIM APART** (`rnf_explode .set 1`): Trilogy's
  man explodes on Stryker's bomb art, which MK2 lacks, so `rv_split` jumps
  into MK2's own body pop `r_shocker_pop` (MKDIE - Raiden's electrocution
  ending, as Ermac's fatal slam also does) after putting the jolt's shift and
  palette back. `rnf_explode .set 0` = he splits on RAINSPLIT.WAX instead.
  Every other strike flares the stage (`rnf_lt_flash`). Rig checks all 14
  strike (`rnf_bolts`), death_blow_complete runs, and the ending: EXPLODED
  (victim inviso + >=10 oid_bones chunks) or SPLIT (a legs object). **What follows is the SHELVED CPU-drawn version**
  (`rnf_geo .set 1` brings it back; the whole leader section of MKRAINF and
  MKZAP's `rgeo_*` block are compiled out while it is 0): he raises his
  arms, the stage fades dark and ONE bolt builds the way high-speed footage
  of real lightning shows it (Saba et al. 2022, GRL,
  doi:10.1029/2022GL101482): a stepped leader comes down in short jagged
  steps with pauses, branching, a streamer brush at every tip; upward
  positive leaders rise off his head, off RAIN's head and off the floor;
  only his connects, the rest abort, and the return stroke lights the
  channel and splits him. All CPU-drawn (`geo_seg` in the bolt object's own
  colour map). ~50 px of sky above a man's head, so the build-up is in the
  pauses and a long SLANT, not in height. **The stage lights up** by
  re-fading the BACKGROUND palettes (`fadeproc` over `bpalram`) with
  multipliers ABOVE 128, back down to the storm's own darkness (1/8 - the
  stock fatality fade is only a dim). **Two budgets, both measured:**
  `geo_list` is 192 segments and SHARED with the HUD text (`geo_full`,
  MKDISP, counts drops; the rig fails if it moves), and pixels cost frame
  time - an overrun frame has no bolt, a residual ~1-in-5 blink in the last
  half-second. **The
  split is `data/RAINSPLIT.WAX`** (legs + torso), authored on the ninja and
  played on EVERY victim in his own art: the generated templates hold
  placeholders (`0100h+n` = his DECAPLEGn out of row 039h, `0200h+n` = his
  RIPTORSOn out of row 041h) that `rnf_build` swaps at the split, and
  `tools/rain_split_wax_import.py --check` (Phase D) fails the build if any
  fighter's rows stop carrying them. See
  [doc/RAIN_LIGHTNING_FATALITY.md](doc/RAIN_LIGHTNING_FATALITY.md); rig is
  `tools/run_rain_fatality_test.ps1 [-Victim all]`. Back+HK supers a JUMPING
  opponent too (`knee_check` steps aside when he is airborne): proven by
  `tools/run_rain_air_super_test.ps1` (2P, Jax jumps: 14 and he is knocked
  out of the air). Rigs:
  `tools/run_rain_roundhouse_test.ps1 [-Snap]` (knee link 27 + wrap, hold
  link 27 + wrap from the corner; plain knee / no Back / late / cooldown all
  the stock 16; Back+HK on its own 14 + wrap; the bolt does 9
  and lifts 234 px, is refused inside its cooldown, and misses a man who steps
  away after the cast). **The bolt's launch is Trilogy's own** - 0c4000h a
  tick under 05000h, measured at 230 px and ~80 ticks - and stays that way
  (`rain_bolt_trilogy`, MAINEQU.ASM). Nothing can juggle a man that high: a
  ground normal's box reaches ~35 px over a standing man, so a follow-up has
  to wait for him to land. `rain_bolt_trilogy .set 0` is the measured
  MK2-scale alternative (~54 px, ~48 ticks - long enough to walk in from the
  cast's own range and still connect); `tools/run_rain_juggle_probe.ps1`
  (`-RJ_WALK`) is what measured both.
- **Jade has a fatality: the STAFF IMPALE** (`jadeimpale`, MAINEQU.ASM; `do_jade_impale`,
  MKDEATH.ASM). FINISH HIM, close (`jdi_maxdist` 050h): **Block, Block, Block,
  Forward, Block** (`jade_block`, MOVES.ASM). The motion spans BOTH input queues:
  `bcom_jade_impale` matches the four Blocks via `button_look_lr`, then
  `jdi_forward_between` requires the newest stick entry to be a Forward stamped
  between the third Block and the last (`-Negative noforward` is the rig's control).
  She ducks and uppercuts him 416 px up off the screen; while he hangs
  there she plays `data/JDIMPALE2.WAX` - her Kitana-body frames (last pose JDIMPALE6,
  KAT49.IMG, in MOVEART2.LOD) plus UMK3's staff (`RODIMPALE1-7`, KITANA11.IMG, bank-1
  `data/JDROD.LOD` 0x9E4000, its own object on `JDROD_P`). **His fall is authored in the
  same WAX** (victim lane, template = Kitana's KTSWEEPFALL5): anchor positions per tick
  on the lane's clock - through the staff, land, slow 10px slide. EVERY victim is drawn
  on his own SWEEPFALL5 (5th frame of TABLE1 016h across the part break), moved so his
  `mpart_bounds` middle is on the staff and his top matches the template's (tip 16px
  out of everyone); the stab frame fires UMK3's pit blood (`jade_staff_blood`, 01ch).
  **AND HE STOPS ABOVE HER HAND** (`jdi_hand_gap`, MAINEQU; `jdi_floor_y`, MKDEATH).
  MATCHING TOPS IS ONLY AS GOOD AS THE TEMPLATE, and KTSWEEPFALL5 is a flat 31px pose:
  a landing frame that throws a limb UP (Jax's trailing leg, Raiden's arm, both 63px)
  has its drawn top nowhere near the back the staff goes through, so the SAME
  correction walks the rest of the body on down the staff - measured, Jax 16px and
  Raiden 15px BELOW JADE'S OWN FIST, reported as the two of them sliding too far down
  the pole. The importer now measures her GRIP as well as the tip (`grip_of`: the
  topmost opaque row of her last pose inside the staff's own three columns - the only
  part of her that touches it is her fingers) into `jade_impale_geom[6]`, and the
  lineup refuses to put his lowest pixel past it. **It lifts the whole LANE, not the
  rest** - the excess comes off the y correction every authored frame is placed
  through, where clamping the last frame alone would snap him back up out of a fall he
  had already made. Four of the nine poses are untouched; the cost is that the tip is
  no longer 16px out of a clamped victim's BOX (Jax -4, Raiden -3), which is the
  thrown-up limb and not his back. `mpart_bounds` answers bottom=0 for an object above the world top -
  measure him parked at a positive y. `f_noscrolly` holds the vertical camera. **Edit the WAX, then
  run `tools/jade_impale_wax_import.py`**, never the generated block. See
  [doc/JADE_STAFF_IMPALE.md](doc/JADE_STAFF_IMPALE.md).
- **Johnny Cage's OTOMIX logo only shows facing right** (`cagelogo`,
  MAINEQU.ASM). The logo is this project's repaint - retail MK2 has none on
  these frames, and `data/CAGE1-10.IMG` are git **skip-worktree**, so HEAD
  still holds Midway's art. `tools/make_cage_logo.py` cuts the lettering off
  174 pieces into `<PIECE>L` logo pieces (`data/JCLOGO.IMG`/`.LOD`, bank-0
  slot 0x728000..0x730000), puts the pieces back to retail pixels, and lists
  each logo piece straight after its piece; it proves piece + logo == the
  painted art before writing (Phase D `--check`). `clip41` (MKDISP.ASM) skips
  a piece whose SAG is in the slot and whose own control word is flipped, so
  facing left he is retail. His victory faces the camera, so
  `jc_face_front` (MKCANNED.ASM) turns a mirrored Cage round in place first:
  whichever side he wins from, they play as painted with the logo showing.
  **Edit the logo art with `--restore`, edit
  CAGE*.IMG, then `--apply`** - never JCLOGO.IMG by hand. `CL_SAG_LO/HI` must
  move with the LOD. Rig: `tools/cage_logo_test.lua` (`CL_ENABLE=0` is the
  control, `CL_WINNER=2` wins facing left and checks the victory; it also
  requires round 2 to start). See
  [doc/CAGE_OTOMIX_LOGO.md](doc/CAGE_OTOMIX_LOGO.md), which also measures the
  PALETTE alternative (slots + a colour-map twin instead of a second subframe:
  24.6 KB of bank 0 back, at a 1-2 step recolour of ~2% of his other pixels) -
  `tools/cage_logo_pal_preview.py` renders both into `tmp/cage_logo_pal/`.
- **Mileena's sai fatality cuts him in half** (`saisplit`, MAINEQU.ASM;
  F,B,F+LP close). The victim is no longer lifted on the sais
  (`r_stabbed_by_fn2`, MKCANNED.ASM); once the stabbing ends, `r_sai_split`
  (MKDEATH.ASM) leaves his legs standing where he stood as their own object,
  which buckle to the knees, wobble, then go over onto the floor with a thud
  in `sai_legs_proc` (decap_fall's three beats), while his own object becomes
  the stock torso-rip lane (`041h`) and hops off the BACK of them to land
  behind the knees. (A MIRRORED torso was tried and reverted: one
  `xori m_fliph` on the object before the lane is laid does it, frames and
  anipoints untouched, because `ani2` re-reads that bit every frame.) The cut sprays Baraka's Back+HP blade blood
  (`swipe_blood`, tick for tick) off the waist - blood slot `019h`,
  `sai_waist_blood` (MKBLOOD.ASM), aimed `058h` above `ground_y` rather than
  off `oypos` (the head, which varies by fighter), and SCATTERED around that
  point (`SAI_SPRAY_DX/DY`, `blood_srand`) - every drop on the one pixel reads
  as a machine firing them. Both lanes go through `sai_spray_xy` with the
  height in a2 and the scatter in a3/a4 (all survive `blood_srand` - it and
  `blood_random` touch only a0/a1): the stomach splashes are a tight cluster
  on the wound (`SAI_SPRAY_DX/DY` 8/6) and the arc starts looser
  (`SAI_ARC_DX/DY` 12/10) off the same `058h` line, which reads as the neck
  once it is climbing. All of it starts `SAI_SPRAY_FWD` (12px) IN from his
  anchor towards her - the sais go in at his front edge, not his middle - and
  that shift is taken off his own flip, since `face_opponent` has him facing
  her.
  The high arc (`swb_drip`) is thrown FORWARDS, out
  of the front of him the way the sais went in, but its art is MIRRORED
  (`xori m_fliph`) because `get_jt_blood` copies the victim's flip onto every
  droplet and he is facing the attacker, so the streaks came out backwards
  along the throw. **The XOR must come after `set_proj_vel`**, which reads that
  same flip to pick the throw direction - flipping first reverses the spurt
  instead of the art. The rig asserts both flips are live at once
  (`BLOODFLIP` line). The same spray also runs as
  a stream for the whole stabbing - slot `01ah`, `sai_stab_blood`, a pair every
  3 ticks until `f_death` goes negative - and it REPLACES the stock stab
  stream (`fn2_db_blood`, slot `0bh`): both at once sat on `MAX_BLOOD` (64) and
  `getprc` refused the burst at the cut. The rig logs the peak (`BLOOD` line:
  49 stabbing / 62 at the cut). The legs lane is three
  parts appended to every
  module's `a_torso_ripped` (`039h`) after the standing legz: each fighter's
  own `a_decapfall` knee frames with the torso pieces left out (Cage's keep
  their `L` logo pieces). **z is what puts the torso behind**: `yzsort` orders
  by z then y, and the landed torso's anchor is lower than the legs', so the
  legs are `front_z+1` (also over Mileena, who would hide the knees at 64px)
  and the torso `back_z-1`. `saisplit .set 0` is the retail lift-and-fling.
  Rig: `tools/run_mileena_sai_split_test.ps1 -Victim all` (12/12 PASS; frames
  land in `tmp/mileena_sai_split/<victim>/`).
- **Mirror matches idle out of step** (`mirrorst`, MAINEQU.ASM). When both
  fighters are on the same ochar, player 2 runs a ONE-WAY stance loop
  backwards (1,7,6..2): `stance_setup` -> `stance_mirror_swap` (MKGUYS.ASM)
  swaps a9 for the `stance_mirror` row (20 rows, char-indexed). New `_rv`
  lanes for Kung Lao, Liu Kang, Cage, Kitana/Khameleon, Shang, Jax and Kahn;
  Reptile/Rain/Smoke and Ermac swap onto each other's existing lanes
  (Reptile and Smoke both idle on `j_rpst` and mirror onto `j_rprv`; Rain
  idles on `j_rprv` and mirrors onto `j_rpst`). Ping-pong
  stances (Baraka, Mileena, Raiden, Sub-Zero, Noob, Jade, Kintaro) are
  left alone, and so is SCORPION: `scorpion_firehand` keys its overlay to
  `j_scst`'s frame addresses.
- **Perfect block** (`jdefend`, MAINEQU.ASM). Tapping Block in the last 4
  ticks before a strike lands gives a white flash, a quarter of the chip, and
  4 ticks less block stun. Holding block does not re-arm it and back-blocking
  never earns it - the window is measured from `do_block_hi` /
  `do_duck_block`, not from the button. The CPU is excluded (`jdjoyonly`)
  because its guard goes up as a reaction and would qualify by construction.
  See [doc/PERFECT_BLOCK.md](doc/PERFECT_BLOCK.md); rig is
  `tools/run_jdefend_test.ps1`.
- **The first tie of a match DRAWS; the next one is SUDDEN DEATH**
  (`suddeath` / `sudden_draws`, MAINEQU.ASM; `suddeath 0` = retail, every tie
  a DRAW). Equal bars at round end (a double KO, or a timeout at equal
  health) bump `@tie_count`, which `round_init` clears at round 1 the way it
  clears `f_sudden`. The first `sudden_draws` (1) of a match's ties are
  retail's DRAW - the banner, full bars, nobody awarded the round. **A DRAW
  STILL ADVANCES THE ROUND NUMBER** (`round_init` increments `round_num`
  unconditionally), so a tie in round 2 is followed by ROUND 3, not by round 2
  again - what the draw costs is the match win, not the round. The tie after
  that raises `f_sudden` instead, and that round is announced SUDDEN DEATH in
  place of ROUND N.
  **The two banners are the same event one tie apart, so they are drawn the
  same way** (2026-09-28, the user's call): both sit at y `058h` (`pf_tie` moved
  off the winner banner's `038h` to join `pf_sudden` there), both flash
  `bpal_flash1` under the words, and they differ only in the words and the
  colour - SUDDEN DEATH in FINISH HIM's red/white (`fl_finish`), DRAW in the
  winner banner's own white/blue (`fl_winner`), which is what says the round
  is not being decided - the fight goes on into the next one. `sudden_banner`
  / `draw_banner` share one
  `tie_banner_flash` tail; **the flash table is loaded AFTER `lm_printf`, never
  passed in by the caller** - `lm_printf` is a `jsrp` and owes `a11` nothing, so
  a table put there first comes back as whatever the printer left. Both come
  down through `tie_banner_off`, and DRAW ends `jruc tie_banner_off` rather
  than a bare `retp`: the flash is a PROCESS, so returning without killing it
  by id leaves it running into the next round. SUDDEN DEATH also stands in for
  ROUND N at the next round's intro, which is where the `058h` came from.
  All three helpers are **outside** `.if suddeath`, so at `suddeath 0` - where
  every tie is a DRAW - the banner still flashes and still comes down.
  **It is the MATCH's ties that are counted, not a run of them**: draw,
  decided round, second tie is still sudden death - `results_retp` clears
  `f_sudden` on a decided round and deliberately leaves the count alone.
  `its_a_tie` has already run by the time `bonus_count_draw` picks a banner
  (`results_of_round` is `play3`, `bonus_count` is `play7`), so `f_sudden` IS
  the answer to "was that the last tie" and no second flag is needed.
  `sudden_draws .set 0` is the old behaviour, every tie sudden death.
  In a sudden-death round `bar_reducer` (JOY.ASM) empties the bar on any
  reduction that carried damage - tested after the boss scaling, so a halved
  1 still kills. Blocks cost nothing, so a guard holds: chip is zeroed at
  BOTH chip sites, `strike_blocked` and `b_spin` (MKREACT.ASM). A zero-damage
  hit (freeze) does not count. A tie IN a sudden-death round is past the
  allowance and stays sudden death.
  `weed_out_cheaters`' round-5 GAME OVER fires on a tie only (a
  decided round 5 used to end the game for both). **Both bars full at round
  end is still GAME OVER - and "full" is the ROUND'S OWN charge target.**
  `fx_charge_bars` opens a sudden-death round on `sudden_strength`, so two
  untouched bars there sum to `sudden_strength*2` (32), not `full_strength*2`
  (322) - and the test was a literal `cmpi full_strength*2`, so it never
  matched. The one round in the game that exists to punish stalling was the
  one round stalling worked in: two players who stood still ran the clock out
  and got another round. `weed_out_cheaters` now picks the target exactly the
  way `fx_charge_bars` picks it. **The general trap: a constant that means
  "a full bar" stops meaning it the moment a round charges to something else.**
  So a DRAW round nobody touched, and a sudden-death round that times out with
  no hit, both end the game, as retail does for an untouched round. That is
  what caps a stalling pair, and it is why the draw costs no extra round in
  practice.
  The round opens on **10% bars** (`sudden_strength`, MAINEQU.ASM): the charge
  target in `fx_charge_bars` (MKFX.ASM), not a write after the fact, so the
  intro animation grows to the tenth and stops. The banner sits at ROUND N's y
  (058h), not the winner banner's 038h, because it stands in for ROUND N at
  the next round's intro - and DRAW now sits there too. Announcer lines, both
  from `bonus_count_draw` at the tie only: `triple_sndtab2` $64 -> track 02fdh
  "SUDDEN DEATH", $67 -> track 021eh "DRAW".
  Rig: `tools/run_suddeath_test.ps1` - four rounds: a forced tie that must
  read DRAW with `f_sudden` still 0 and NO announcer line (the control for
  the whole rule), an ordinary round 2 that must charge to 161 and not 16,
  tied again into SUDDEN DEATH, then the sudden-death round (3 blocked kicks
  with no chip -> one clean kick 16 -> 0) and an ordinary round 4.
  `-Mode stall` is the other half: the same two ties, then NOBODY presses
  anything for the sudden-death round's whole 99-second clock, and it must end
  in GAME OVER (`gstate 0bh`) with `round_num` still 3 - never round 4. Both
  modes PASS.
  **The rig dismisses MAME's ROM-warning box with `tools/mame_dismiss_warning.ps1`
  (PostMessage), never `AppActivate` + `SendKeys`.** SendKeys needs the
  FOREGROUND and the rig starts MAME with redirected stdout/stderr, so it never
  owns it: with no other MAME window up the focus steal happens to work, and the
  moment the user or another rig has one open the keys land in THEIR window.
  Measured 2026-09-28 - 600s of backstop burnt, empty log, MAME alive and
  "Responding", which reads exactly like a broken ROM. It now also kills its own
  run after 63s with no lua log instead of waiting the backstop out.
  `-Listen` adds sound:
  it taps the sound latch and `tools/suddeath_wav_check.py` proves the line is
  in the recorded mix. **Two traps that both read as "the ROM is silent"**: a
  write tap whose handle is not kept is collected and never fires again, and
  the latch's two byte-writes must be paired ROLLING - one odd write puts a
  strict pairing permanently out of phase and 02fd straddles the boundary.
  Judge the audio on the speech-band SPECTROGRAM, never the amplitude
  envelope: a -19dBFS line under the music scores 0.41 against 0.34 controls
  by envelope (no verdict) and 0.66 against 0.33 by spectrogram.
- **SHAO KAHN TURNS TO STONE FROM THE FEET UP** (`kstonecreep`, MKFX.ASM;
  `kahn_stone_creep`, and `kahn_turn_stages` in MKSK.ASM). Retail's ending
  cuts to black, puts the flesh Kahn up (`make_kahn_obj` = the 4th frame of
  his laugh, `BGLAFF4`, the pose he shook in) and swaps him to the statue
  palette ON THE NEXT LINE - he is simply stone. Midway drew the turn in
  between: `BGTURNSTONE1-8` (`data/BOSS7.IMG`), eight `BGSTONE_P` patches
  laid out on that exact frame - shins, knees, belt, chest, arms, head -
  packed in retail's MK5MIL and drawn by nothing. They go on one stage every
  6 ticks, the last held 8, and `dallobj oid_fx` takes them off on the tick
  the body turns (only Kahn survives `murder_myoinit_score`, so oid_fx is
  safe there). **The pieces are built by hand, not with `gso_dmawnz`**: the
  records are `POF>`, so `object_setup` would hand `getfpal` whatever lies
  past the end of the record (the Kung Lao gleam's trap). Each piece claims
  `BGSTONE_P` itself - `getfpal` refcounts a loaded palette and `kill_ocp`
  frees one per object - palette FIRST, object second, `freepal` if the
  object fails. The code is in MKFX because MKSK includes only MAINEQU (no
  SYSEQU/DISPEQU field names); MKSK exports one table. ASM only, no repack.
  Seen in MAME via `tools/run_kahn_stone_capture.py`'s `boot()` with
  `KSC_EVERY=3` (new: snapshots every N frames for 100 after the black cut):
  the stone climbs over ~50 frames, then the stock crack and explosion run
  to the end (9 animation frames, as before). `kstonecreep .set 0` = retail.
- **Shao Kahn's hammer smash CRACKS THE SCREEN** (`glasscrk`, MAINEQU.ASM;
  `src/MKGLASS.ASM`). The fatality drives the beaten man face-first into the
  front of the screen at 2x; the frame he arrives on (`PITFALL6`) now breaks
  the glass where he landed - an impact chip, 11 radial cracks, and two
  irregular webs of concentric cracks joining the radials AT THEIR KINKS, which
  is what makes the web ragged for free. Spreads over six frames, then held
  still for the rest of the finisher, and gone by the next round.
  **CPU line work** (`geo_seg`/`geo_pass`, needs `geoline .set 1`): no art, no
  video-ROM space - bank 0 has none - no palette. Drawn at `dsa9`, so it is in
  FRONT of everything including the HUD and the FATALITY word, which is what a
  cracked screen should be.
  **A PROCESS DOES NOT POST OFTEN ENOUGH, and this is the reusable lesson.**
  `geo_pass` consumes `geo_list` every frame, so a producer re-arms or it
  vanishes - and a producer on its own process at `sleep 1` lands on only EVERY
  OTHER DRAWN FRAME. Measured: 70 captured frames alternating hard between the
  whole web (~2,650 near-white px) and none of it (~1,590 = the victim's own
  highlights). **That is not what a cost problem looks like** - an overrunning
  frame loses the pass at RANDOM (Raiden's bolts blinked ~1 in 5); a clean
  2-frame square wave is a scheduling mismatch. The fix is `box_pass`'s shape:
  produce from INSIDE the display pass. `glass_crack_pass` is called from
  `dsa9` beside it and MUST precede `geo_pass`, which is what consumes the
  list. After: 63 frames, zero missing.
  **It costs nothing measurable.** `tools/run_fatality_budget.py --only
  kahn_fatality`, same 220-frame window: control 220 ticks / 220 frames;
  crack present but posting NOTHING 215; crack fully drawn 215 - identical, so
  the 59 segments are free at this resolution. No `qdma_drops`/`dmaq_over`/
  `dmaq_lost`. **`peak_overload` reads back `gc_life` (600, or 241 at 240) and
  that is an ARTIFACT** - one frame at the expiry decaying 600/301/151/76
  through prcdsp's smoothing filter, every other frame at 4 like the control.
  `gc_tick` and `peak_overload` are at different addresses; judge it on the
  tick-against-frame table, not that counter.
  Two geometry traps: a segment leaving the page is dropped WHOLE, not clipped
  (`geo_onpage`), so `gcb_fit` shortens a ray until its TIP fits rather than
  clamping its points - clamping bends the crack along the border and reads as
  a frame, not as glass; and every random number is `@blood_rand`'s, never the
  gameplay stream. The impact point is MEASURED off `mpart_bounds` - at 2x in a
  PITFALL pose his anchor is nowhere near the part of him touching the glass.
  See [doc/KAHN_HAMMER_GLASS.md](doc/KAHN_HAMMER_GLASS.md); rig is the existing
  `tools/run_kahn_boss_moves_test.ps1 -Move hammer -PortalFatality -PuppetHold`.
- **Shao Kahn's Portal Punch fatality EXPLODES the body, and the blood is on
  HIS KNUCKLES** (`kfistpulp .set 0`, MAINEQU.ASM; `r_kahn_fist_burst`,
  MKZAP.ASM). The hand comes down, the man ducks under it (`anitab1[5]`, every
  character's own crouch), and then `r_burst_pop` - MK2's own body pop: BOOM,
  inflate, white flash, `kiss_explode` and the `exp_burst` chunks.
  **What it adds to the stock pop is the three splats.**
  `ermac_splash_blood` (blood_procs 017h) walks its three `BLDXPD` bursts down
  the VICTIM's torso, which is right for a man exploding where he stands;
  here the thing that burst him is a five-foot fist, so `kahn_knuckle_blood`
  (01dh, MKBLOOD.ASM) lays the same three on **the knuckle row** -
  `erm_tksf_splashdy`'s 24px step centred on it, one above, one on, one over
  the claws. **They are VERTICAL because the hand comes straight down**: the
  four red plates (`BGBIGFIST1D0`) stack one above another on screen.
  **The point is MEASURED off the art, not tuned by eye.** Every fist piece is
  placed at `@ground_y - bigfist_height` across, `kbf_xoff` over - so
  `kahn_fist_knuckle_point` runs the same arithmetic and adds `kbf_knuckle`
  (140), the plate's own centre off that anchor (the record hangs at
  +121..+160). None of the six pieces can be asked where it is: each sits at
  anchor MINUS its own anipoint, so no piece's `oxpos` IS the anchor.
  Measured in MAME: the cloud's centre is x 127.5 on every row and the plates'
  is 128.
  **`front_z+2`, and that is load-bearing** - the hand's own pieces are at
  `front_z+1`, and at equal z `yzsort` falls back to y, which the splat loses
  as its frames grow. `kahn_knuckle_splat_one` is a second entry into
  `ermac_splat_one` that differs in nothing but the z it puts in a9.
  **Between 2026-08-10 and 2026-09-28 the body was CRUSHED instead** - it went
  inviso and `FISTPULP1-15` (SHAOFIST.IMG) squirted out from under the hand.
  The DRIVER is still here under `kfistpulp 1`, but **the ART WAS RECLAIMED
  2026-09-29 and this is no longer a one-line flip.** `a_sk_fistpulp` sat in
  `sk_anitab2` row c whatever the switch said, which kept all 233 records
  packed and reading as LIVE at a cost of **20,236 bytes of bank 1** - not the
  26,664 this entry used to claim, which predates the 2026-09-15 re-cut to
  `PPP> 5`. With `kfistpulp 0` not one of those pixels could be drawn, so
  `data/SHAOFIST.LOD`, the `makevrom.py` entries, the `SHAOFIST.TBL` include,
  the lane, `FISTPULP4W_MIRROR`, `FISTPULP_P` and its `death_fade_excludes`
  row all came out; row c takes `kahn_dummy`. `MAINEQU.ASM` has an `.emsg`, so
  `kfistpulp 1` now FAILS the build until the art is re-packed - restoring it
  is a full Phase A run, and `data/SHAOFIST.IMG` was kept for that. See
  [doc/ASSET_SPACE_LEDGER.md](doc/ASSET_SPACE_LEDGER.md).
  The hand's screen time did not change: `kportal_burst` is still
  `fistpulp_frames*fistpulp_rate` = 90 ticks, deliberately.
  Rig: `tools/run_kahn_boss_moves_test.ps1 -Move portal -PortalFatality
  -PuppetHold` (snaps every 3rd frame while `debug4 == 0x5020`).
- **CURRENTLY OFF (`ktspin .set 0`, 2026-10-04, the user's call): KITANA HAS NO
  OVERHEAD SPIN CHOP.** Hold Block + Forward, Forward was this project's own
  move (`KTSPINCHOP1-6` out of `data/KITSPIN.IMG`, `stk_fnspinchop` =
  `fn_strikes` 018h, 32 damage); `ktspin .set 1` brings it back and both states
  are proven. `fn1_lr` (MOVES.ASM) takes `jruc death` instead of its body, so
  the gesture is a blocked walk again, and `do_fn1_spinchop` is not assembled.
  **THE DRONE IS GATED BY DATA, NOT BY DIRECTIVES**: `rpt_fnspinchop`
  (MKDRONE.ASM) becomes ten zeros, written `60*ktspin,90*ktspin,...`. Both
  drone callers - `fn1_start`, her opener, and the Kitana branch of
  `close_he_is_ducking` - reach the move only through `ask_mr_diff` on that one
  table, and `randper`'s compare cannot borrow against 0. **MKDRONE.ASM
  assembles at GSPA's ceiling and ONE `.if`/`.else`/`.endif` in it aborts the
  build** (`>> Out of memory` on PASS 2, measured against a clean pristine
  run); an arithmetic operand costs no directive. MAINEQU is the other half of
  that cliff - ~70 objects include it - and the first draft's comment block
  there was on its own enough to push MKDRONE over, which is why the prose
  lives in the doc.
  **Four things are deliberately LEFT**, all positional: `stk_fnspinchop`
  (`doc/balance.lock` reads it), the `c_fnspinchop`/`ct_fnspinchop` counter
  rows (`counter_tab` is indexed BY action code), `scom_fn1_spin` (FLYMOVES.ASM
  names it at index 8 and the fly's learned weights are indexed by that table),
  and `char_joyleft`/`char_joyright` rows 4 and 18 - `tools/make_fly_moves.py`
  walks their `.long` lines to attribute each `scom_` to a fighter, so an
  `.if`/`.else` there reorders `tools/flybrain_moves.lua` for RAIDEN'S TORPEDO
  too. That is why the refusal went inside the handler. `fn1_anitab2` row 0ah
  still names the lane, so **the ~19KB of bank 0 stays packed** and
  `art_ref_graph` still calls it LIVE; reclaiming it is not a follow-up
  one-liner, because `data/MK1SKULL.LOD` rides in KITSPIN's tail at 45,194
  bytes against a 45,568-byte slot.
  Rig: `tools/run_kitana_spinchop_test.ps1`, now a TWO-SIDED control - it reads
  `ktspin` out of MAINEQU and inverts its own expectation, so it guards the
  disable instead of going permanently red (ktspin 1: `move_fired=true
  sag_frames=120 p2bar 161 -> 129`; ktspin 0: `move_fired=false sag_frames=0`,
  with `act=0x0700` in the log proving Block really was held and `act=0x0111`
  appearing nowhere). **It had rotted three ways since 2026-07-30 and every one
  of them read as the move failing**: no warning-screen poker (so the game
  never booted - `gs=0 p1objchar=65535` for the whole backstop), hardcoded
  `.bss` addresses (a dead `GSTATE` reads a constant 0), and a hardcoded
  `KITSPIN_SAG` window that no longer contained the repacked sidecar, which
  reported `sag_frames=0` WHILE THE MOVE WAS FIRING. The window is read out of
  `src/KITSPIN.TBL` every run now, and a run that never reaches a fight is NO
  VERDICT (exit 2), not FAIL. See [doc/KITANA_SPIN_CHOP.md](doc/KITANA_SPIN_CHOP.md).
- **KUNG LAO'S VICTORY HAT GLEAM IS BLUE, AND IT IS ITS OWN OBJECT TO BE SO**
  (`hhgleam`, MAINEQU.ASM; `hh_victory`, MKCANNED.ASM; `a_hh_vicgleam`,
  MKHH.ASM). `TMHATGLEAM1-6` (`data/HATHED10.IMG`) ran round the brim in GREY
  and **no edit to the IMG could change that**, for three independent reasons
  - which is what makes this worth an entry rather than a commit.
  **A MULTIPART HAS ONE PALETTE.** `a_hh_victory_hat`'s rows are
  `TMVICTORY8A,TMVICTORY8B,TMHATGLEAMn` - the gleam was a PIECE of Kung Lao's
  own object, and MKDISP loads the palette translate ONCE, before the
  multipart loop. **`PPP> 6`** (`data/MK2MIL.LOD`) packs the whole Kung Lao
  section at 6bpp whatever the palette record's own depth says, and **`POF>`**
  means the records carry no palette field at all - so the binding between the
  record and the IMG palette DOES NOT EXIST IN THE ROM. The art's seven
  indices therefore landed on his costume's slots 1-7, a white-to-grey
  highlight ramp, in every costume.
  **AN IMG PALETTE EDIT HERE IS INERT AND LOOKS LIKE A BUILD PROBLEM**: a full
  `build.py` after one leaves `src/MKHH.TBL` BYTE-IDENTICAL, because the pixels
  did not move and the depth is forced. Only the IMGTOOL preview changes.
  So the gleam rides a SEPARATE object - `a_hh_vicgleam` (`hat_anitab2` row 8)
  is the same six records with the body pieces removed, no new art and no
  repack - and `hh_victory` follows `jade_victory`'s shape: `gmo_proc`,
  `match_ani_points`, `getfpal HATGBL_P`, his z + 1, `mframew 4`, `set_inviso`.
  **The general rule is the reusable part: a visual that needs its own palette
  needs its own object**, which is also why Jade's victory staff and Baraka's
  blade sparks are objects.
  **His costume index goes into `opal` FIRST and `HATGBL_P` over the top.**
  These records are `POF>`, so `get_multi_obj`'s `*a5(icmap)` read runs off the
  end of the record and the object's `opal` is garbage; seeding it with
  something safe to draw in makes a `getfpal` failure degrade to retail's grey
  instead of to boonpal's yellows. `getfpal`, never `swpal` - `swpal` opens
  with an unconditional `delpal` on that garbage index, which is how
  `freepal`'s count underflows into its lockup. And no cleanup: `set_inviso`
  stops the draw and the round teardown owns the object, because hand-deleting
  a `gmo` object here is the exact move that wedged Kahn's glow.
  **`set_inviso` writes `oflags2` (0x160), NOT `oflags` (0x0f0)** - the rig
  watched the wrong field first and reported a gleam that never hid, which is a
  rig fault wearing a regression's clothes.
  Costs one foreground colour map (`nmfpal` 35) for the gleam's 24 ticks, plus
  18 bytes of program ROM. `HATGBL_P` is hand-carried into `src/IMGPAL7.ASM` by
  `tools/sync_hatgleam_pal.py` (Phase D `--check`), because nothing promotes an
  IMG palette into the ROM.
  Rig: `tools/run_hh_gleam_test.ps1` (6 stages, cadence 4, `palram` map 8 ->
  `HATGBL_P`, z in front, hidden, released into round 2, `fpal_fail` 0;
  `-Negative` crosses the expectation onto his costume and MUST fail, and does).
  **The pointer check is not enough on its own** - a matching `opal` with
  nothing painted behind it is how the Jade sidecar hole passed for months - so
  `tools/hh_gleam_pixels.py` counts HATGBL_P's exact colours in the snapshots
  (74 in the best frame). The costume ramp it used to wear is pure grey in
  every slot it touches, so one saturated-blue pixel cannot come from the old
  behaviour. `hhgleam .set 0` is retail. See
  [doc/KUNG_LAO_VICTORY_GLEAM.md](doc/KUNG_LAO_VICTORY_GLEAM.md).
- **KUNG LAO'S HAT BANKS INTO THE ANGLE IT IS FLYING AT** (`slicehat`,
  MAINEQU.ASM; `hat_proc`, MKZAP.ASM; `slicehat_pics`, MKHH.ASM).
  **Retail already steers the hat** - `hat_proc` reads the thrower's stick
  every tick and adds `+-0a000h` to `oyvel` for Up/Down, Midway's code - but
  the flight loops `HATFLY4`<->`HATFLY5`, two flat 20px blurs, whatever angle
  it is travelling at, so a hat steered hard up looked exactly like one thrown
  flat. `SLICEHAT1-16` (`data/HATHED12.IMG`) are the missing half: **in NO
  retail IMG** (mk2-readonly's HATHED12 has no record of that name) and
  referenced by nothing in `src/` or any LOD, so not a pixel had reached a ROM.
  **THE ART IS DIRECTIONAL - EVERY FRAME CARRIES A MOTION TRAIL**, a pale smear
  off ONE side, and which side is MEASURED (split the opaque pixels by
  luminance; the trail's centroid sits 0.6-5.3px to one side of the body's):
  **1-6 trail LEFT, drawn for a hat flying RIGHT; 7-16 trail RIGHT, flying
  LEFT.** So the sixteen are **SIX BANKS DRAWN TWICE, once per travel
  direction** (1-6 against 12-7 are mirror pairs at the same bank, silhouette
  IoU 0.98 at level, hand-redrawn rather than flipped so the LIT RIM stays on
  the same side of the screen), plus four extra banks that exist leftward only
  (13-16). The principal axis of each mask gives the banks: -38.8 through 0 to
  +30.7 deg in ~8 deg steps.
  **ALL SIXTEEN ARE PACKED** (13,112 bytes, bank-1 `data/SLICEHAT.LOD` at
  0x9E0000 under JDROD; RAINCLD gave up the top half of its slot and keeps ~7KB
  of growth) and **hat_proc PICKS THE SET BY FACING**, so each throw draws the
  art authored for the way it is going: thrown RIGHT the climb+level buckets are
  `SLICEHAT6,5,4,3,2,1`, thrown LEFT they are `SLICEHAT6,16,15,14,13,12`, and
  the DIVE buckets are `SLICEHAT11,10,9,8,7` BOTH ways - H-flipped for a
  rightward throw, as authored for a leftward one, because **there are no
  rightward dive frames at all**. A flip mirrors the trail AND negates the bank
  together, which is what turns a leftward dive into a rightward one with the
  trail still behind. Result: symmetric -38.8 through 0 to +38.5 either way.
  **THE FACING IS TESTED AND MUST BE**: the artist mirrored the frames BY HAND
  rather than letting the DMA do it, which is what keeps the lit rim on the same
  side of the screen both ways, so using one set for both would mirror the
  lighting on every left throw - the whole reason twelve of the sixteen exist.
  **ONE GAP**: the leftward climb tops out at +30.7 (`SLICEHAT16`), so bucket 0
  (steepest climb) has no leftward frame and falls back to `SLICEHAT6` mirrored
  - the only sprite whose lighting mirrors. Which buckets flip is
  `slhat_flipfrom_r` (6) / `slhat_flipfrom_l` (1), a THRESHOLD not a bit mask:
  the mask version tested its bit with a REGISTER shift and silently never
  fired, so the extra flip was applied on neither side.
  **AND IT DOES NOT SPIN, which is the art's doing.** Two frames at one bank
  with the trail on the SAME side exist only for level and the shallow climbs,
  never for the steep climb and never for any dive, so retail's 13.7fps
  `HATFLY4/5` spin is the price of the bank. **An earlier cut read the 1-6 /
  7-12 split as two SPIN PHASES and alternated them every 4 ticks** - it
  measured as a clean spin at retail's rate and put `SLICEHAT13-16` on a
  rightward dive with the trail LEADING. A frame set that mirrors cleanly is
  not evidence of a spin; measure the asymmetry.
  `oxvel` is a constant `0c0000h`, so the angle is a function of `oyvel` ALONE
  and the bucket edges (`slhat_b1..b5`) are precomputed `tan(angle)*12.0`, no
  divide. **The art is on its own palette**: `SHAT1_P` (IMGPAL6.ASM), not
  `TMHATS_P` which the hat is already alive on by the time the flight starts,
  and a frame change never re-reads `icmap` - so `hat_proc` `swpal`s in and
  back out at `hatp8`, and **a failed swap falls back to retail's HATFLY loop**
  rather than drawing the new art in the old palette. The LOD is `POF>`: the
  IMG's records name `SHAT3_P` in their `palnum` and that is NOT what ships.
  **It costs +1 foreground colour map for the duration of every throw** -
  retail's flying hat and the reappearing one in Kung Lao's hands were both on
  `TMHATS_P`, so one map served both (`fpal_fail`, PALL.ASM, measures the pool).
  **`SLICEHAT16`'s `aniy` IS A SIGN SLIP AND IT COMES BACK.** It ships at -19
  where its neighbours run 14-23, putting its centre 36px out of line (all the
  others sit between 0 and -8) so the hat LEAPS 40px the moment a left throw
  reaches the steepest climb - and back down again, which is why it reads as a
  jump in both stick directions. Its rightward twin `SLICEHAT5` is the same
  48x34 at the same bank with `aniy` 20, which pins the value. HATHED12.IMG is
  hand-edited in IMGTOOL so a re-save undoes the fix - it has reverted once
  already - and **`tools/slicehat_expect.py --check` is in Phase D for exactly
  that**: it recomputes where every bucket places the hat in BOTH facings and
  fails the build if two neighbours step more than 3px in Y or 5.5px in X. X is
  looser because two steps are AUTHORING VARIANCE, not faults: the leftward
  family is 2-4px off the mirror of the rightward one (12 by 4, 13-16 by 2),
  leaving 5px at level->dive thrown right and 4px at the bucket 0/1 boundary
  thrown left. Matching the two families in IMGTOOL would close both.
  **AND THE BLOOD COMES OUT WHERE IT CAUGHT HIM** (`hitpoint`, MAINEQU.ASM).
  Once the hat crosses at whatever height it is flying at, a spray anchored to
  the middle of his chest is visibly wrong - a hat steered over his head and one
  steered through his knees burst in the same place. `strike_check` (JOY.ASM)
  now stamps the contact point the moment a collision is PROVEN: the centre of
  the rectangle the strike box and the victim box SHARE, into `hit_pt` (a p1:p2
  pair of longs, RAM.ASM), as a packed `[y,x]` off the victim's own origin with
  x in FACING space - the form `adjust_blood_a0` already takes, so a consumer
  ADDS it. **It is MEASURED, not chosen**: the overlap is what the compare
  tested. It sits after the last `jruc no_collision`, so an attack that is live
  and touching nobody costs nothing, and it is taken there because `a5` becomes
  the strike flags two instructions later. **Shao Kahn's flying knee already
  needed exactly this** - `kahn_knee_contact` (MKREACT.ASM) exists because the
  knee "can catch a man anywhere from the hip to the head"; what is new is that
  the point is no longer hand-computed per move. **Only `hat_blood` reads it**
  (blood_procs `013h` - the hat and Jade's boomerang, out and back): the burst
  lands on the wound and the drips keep their `030h` below it, because that
  separation is the authored shape of the spray. The anchored sprays are left
  alone deliberately - several are aimed at something real (`sai_waist_blood` at
  the cut, `kahn_knuckle_blood` at the knuckle row) rather than merely
  defaulted. **`hit_point_a9` takes the man in a11, NOT a8**: every caller has
  already run `get_jt_blood`, which leaves a8 holding the droplet it just made
  and pushes a11 across `gso_dmawnz` precisely so it survives. **`hit_pt` adds
  64 bits to `.bss`, so every RAM address after it MOVES** - a rig holding a
  cached address from an older map reads the wrong thing, and that is the only
  part of this with a blast radius beyond the spray. Proved by A/B, never by
  one hit: a single hit passes on any constant that lands on his chest, so the
  rig takes the same hit at three SEEDED heights (the steer accumulates only a
  few pixels over a 12-tick flight) and requires climbing < level < diving -
  measured 34 < 49 < 58. Those trials stand 300px apart, not 150, because at
  150 the hat is two ticks from him when the rig first sees it.
  **A HAT THAT CONNECTS KEEPS THE BANK IT HIT WITH.** `hatp8` used to hand the
  palette back on contact, which dropped the sprite to retail's flat HATFLY
  blur on the frame it landed - the hat appeared to become a different object
  as it struck. The restore now lives in `hat_blocked` ALONE, which is the path
  that needs it (only the blocked spin re-points a9 to hatfly8-11, and that IS
  TMHATS_P art); `hatpc` keeps calling `slhat_frame` while the palette is still
  ours.
  **AND IT COMES BACK IF HE KEEPS HOLDING LOW PUNCH** (`slhatboom`,
  MAINEQU.ASM; `slhat_boom` / `slhat_lp_held`, MKZAP.ASM) - LP because that is
  the button it was THROWN with (`scom_hh_throw` is Back, Forward + LP), so the
  gesture is "keep holding what you threw with". **LOW PUNCH IS ON `switch2`,
  NOT `switch`**: `p1b1`/`p2b1` are marked "switch 2" because `switch` is
  01600000h and `switch2` is 01600020h, and the masks OVERLAP - `p2b1` and
  `p1b0` are both 010h, so swapping the constant alone while still reading
  `@switch` would have tested PLAYER ONE'S HIGH PUNCH for player two's low
  punch. It cannot share Kitana's `fan_check_hp_held`, which spends a drone's
  hold out of `p_store3` - the am_i_joy flag in this process. **THE TURN HAPPENS OFF SCREEN AND THAT IS THE WHOLE
  MANOEUVRE**: the hat leaves one side and comes back already travelling the
  other way, so the change of art reads as FLUSH rather than as a pivot the
  player watched. This is where it differs from Kitana - her fan curls 96px
  INSIDE the edge in full view because the curl IS her signature; the hat's is
  not. Trigger is `proj_onscreen_test`, not a turn line, and the rotation is 2
  ticks so it fits in the gap. **IT COASTS FIRST** (`slhat_turn_delay`, 2
  ticks): proj_onscreen_test goes false at ONE PIXEL of clearance, which is not
  a margin - measured, a turn begun on that tick left the hat off screen by a
  single pixel and any camera drift would have shown the pivot. It is a
  ROTATION of the velocity vector (`slhat_curl_step`, Kitana's own velocity-
  Verlet - half a shear, a whole one, half again, which holds the speed to 0.4%
  where the two-line form swings it 22%), not a sign flip; her `fan_curl_step`
  cannot be called directly because it takes the throw direction out of
  `p_store6`, which in hat_proc is the SLICEHAT palette flag. `fan_face_travel`
  IS reused as-is, and re-derives the facing from the x velocity every tick
  because x changes sign part way through - SET from the sign, never toggled. **THE RETURN LEG DRAWS THE OPPOSITE FRAME, NEVER A
  MIRRORED ONE**: `slhat_reverse` negates oxvel AND OYVEL - a boomerang that
  went out rising comes back falling - and because `slicehat_pics` is ordered
  by angle with level in the middle, that sign change turns bucket N into
  bucket 10-N, which lands on exactly the hand-drawn twin (1<->12, 2<->11,
  3<->10, 4<->9, 5<->8, 6<->7). Those pairs carry DIFFERENT GLIMMERS, which is
  why the twin and not a flip: a mirror puts the lit edge on the wrong side.
  Nothing indexes the pairing by hand - it falls out of the sign change and the
  ordering. NOT `flip_multi`, which XORs the flag and re-runs ani2 on the frame
  already showing (i.e. mirrors it) for one tick before the table catches up;
  `slhat_reverse` sets the facing and calls `slhat_frame` outright. The facing
  change turns the strike box round too, which is right. **THE TURN MUST NOT FALL THROUGH TO THE ONSCREEN TEST**: reversing
  oxvel does not move the hat, so it is still outside the window that tick and
  the test would delete it on the spot - it would flip its velocity and die in
  the same tick. Jade's blade carries the identical hazard and note
  (`jbp_return_arm`). **AND IT RECENTRES ON THE WAY HOME** (`slhat_recenter`,
  `slhat_recenter_a1`): out of the turn the hat is banked at the mirror of what
  it went out on, and holding that all the way back is what made it ARCH OFF
  THE SCREEN instead of crossing it - it left, turned, and flew out of the top
  still diving. **It now steers back onto THE HEIGHT IT WAS THROWN AT**
  (2026-10-06, the user's call): `hat_proc` stamps `oypos` into
  `slhat_home_y` (p_store6+16) and `slhat_recenter_a1` wants an `oyvel` of
  (px off the line) << 14, capped at `slhat_ymax`, reached `2*slhat_recenter`
  a tick - simulated first, it lands level on the line in 10-30 ticks. Settling
  to plain LEVEL brought it home flat on whatever line the curl and the outward
  steer left it. The drone's hat homes the same way. It is held off for the
  one tick it leaves the curl, so that tick still draws the snapped twin. The
  rig asserts it (`THROW LINE stamp/home`, within 3px). **ONLY WHEN HE IS NOT STEERING** - a held direction wins outright, so it
  hangs off the steer's own "no up or down" case and the two cannot disagree -
  and the last step LANDS EXACTLY ON ZERO rather than hunting either side,
  which at this size is a visible twitch for the rest of the flight.
  Legs live in `p_store7` (0 outward, 4 coasting clear, 3
  rotating, 1 homeward out of bounds, 2 homeward visible) with `p_store8`'s LOW
  half the countdown - **a WORD, because its high half is `slhat_vturn`**, the
  outbound bank in 8.8 (Kitana's `fan_vturn` trick). Left as a long it read the
  stored bank back as part of the count and a 2-tick turn ran for 96. Both
  SEEDED at the top of hat_proc because `getprc` does not zero `pdata`, and
  **`slhat_vturn` is defined beside the p_store block, not with the other
  slhat_ equates**: GSPA resolves a `.set` in ONE pass and rejects a forward
  reference to p_store8 outright, the same trap rh_half_dmg hit against
  full_strength. BOTH AXES ARE SNAPPED coming out of the rotation - it is far
  short of a half turn at 2 ticks, so neither exit velocity is trusted; Kitana
  snaps her x, the hat snaps y as well because the twin pairing IS the sign of
  oyvel. A
  hat that CONNECTED does not come back, and **THE DRONE COMMITS UP FRONT** the way Jade's does:
  `slhat_drone_hold` rolls a hold at the throw (Jade's own `rpt_boom_hold`
  odds; the roll can come up "tapped") and `slhat_hp_held` spends it down. It
  CANNOT share Kitana's `fan_check_hp_held` - hers spends the budget out of
  `p_store3`, which in THIS process is hat_proc's own am_i_joy flag, so calling
  it would decrement the flag that decides whether the hat steers at all. The
  hat keeps its budget in `p_store5`.
  **`slhatcap` is a separate switch because it IS a gameplay change**: retail's
  steer is uncapped (~20 px/tick, near 60 deg over a crossing) where the art
  stops at 38.8, so `slhatcap 1` caps `|oyvel|` at `slhat_ymax` and costs about
  half the maximum deflection, `slhatcap 0` keeps retail's path and lets the
  frame index SATURATE. **Trap: a plain hit does not re-point `a9`** - only
  `hat_blocked` does - so a hat that connects carries on drawing `hatfly3/4/5`
  with no steer, which looks EXACTLY like this table failing (HATFLY art,
  frozen `oyvel`); the tell is `p_action = act_proj_dead`. And
  `proj_strike_check` does NOT eat process scratch here - markers in
  `p_store4/5/6/7/8` all survive a flight; the clear that looked like a clobber
  was `hat_proc`'s own at `hatp8`.
  **RIG TRAP: THE ROUND CLOCK OUTLASTS THE RIG.** Twelve trials at 320 frames
  is 72 seconds of fight against a 99-second round, which is not margin - the
  round was ending under the last two trials, `gstate` went to 1, the fighter
  objects were torn down and every phase froze behind the rig's own
  `p1_obj`/`p2_obj` guard. It reads as two trials that "never found the hat",
  which is a NO VERDICT wearing a failure's clothes. `f_freeze_timer` (MAIN.ASM,
  training mode's own switch) stops the clock; both bars are pinned every frame
  as well, because three trials land a real hit and the victim pin only covered
  their own fly phase.
  Rig: `tools/run_slicehat_test.ps1` (12/12; asserts every tick of the
  rotation was OUT OF SIGHT, which is what the manoeuvre exists for;
  measures the SAG the DMA was handed against `oyvel`, runs BOTH facings and
  the boomerang, its TWIN pairing, the drone's budget and a deliberate HIT
  (every other trial parks the victim clear, so none of them exercised the
  contact path) -
  checking one only would never draw `SLICEHAT12-16` at all - asserts the flip
  against the piece's own control word, since checking the frame ALONE would
  pass on a hat flying trail-first, reads `fpal_fail` so an exhausted pool is a
  CAUSE and not a bare "never found the hat", regenerates expectations from the
  build every run, and FAILS an empty run). **Traps**: `oflags` is at **0f0h**,
  not 0x20; **Lua's `and`/`or` is not a conditional** - the expected flip
  written `xflip and (not objflip) or objflip` collapses to `objflip` whenever
  the middle term is false, so it agreed with a build that never flipped, and a
  boolean XOR is what was meant; there is NO sag->bucket map and cannot be (one
  record serves two buckets across the facings), and indexing with the
  resulting nil threw on every flipped tick, killed the handler and reported a
  spin failure while the code was fine - the tell was `[LUA ERROR]` in MAME's
  own stdout.
  See [doc/KUNG_LAO_HAT_ANGLE.md](doc/KUNG_LAO_HAT_ANGLE.md).
- **NOOB SAIBOT'S MOVE LIST IS FIVE MOVES, AND THE DIVE KICK IS REPTILE'S**
  (`noobdive`, MAINEQU.ASM; `noob_hi_kick`, MOVES.ASM). Trimmed to exactly this
  on 2026-10-04, by request: **ghost ball** D,F+LP, **teleport slam** D,U,
  **shadow throw** F,F+HP, **Sub-Zero's slide** Away+LP+BL+LK, and **Reptile's
  DIVE KICK** U,D+HK in the air. The first four were already all he had -
  `noob_extras` is 0, so the shadow slide / kick / dive / portal / teleport are
  compiled out and the slam has Down,Up to itself - so the only build change was
  the dive.
  **IT IS REPTILE'S MOVE, NOT A COPY OF IT**: `noob_hi_kick` is `rphk_dive` word
  for word - the same `scom_super_rep`, the same `0a0h` `distance_from_ground`
  gate, the same `do_reptile_superk` - and `airborn_xfer` rather than
  `restricted_xfer`, because the move is only legal off the ground. It needed no
  art, hitbox or reaction, and that is not luck: `super_reptile_scan` (MKPROP.ASM)
  already picks the strike record by ochar, and Noob reads `nj_strikes` so he gets
  `stk_rp_superk` exactly as Reptile does. **That is the half that fails
  silently** - index `012h` is `stk_super_rep` in `hh_strikes` but **`stk_slide`
  in `nj_strikes`**, a shin-high box parked at y 125 - which is why the rig
  asserts the LAUNCH HEIGHT and not the hit. `flight_call` resolves `a9 = 01eh`
  through `get_char_ani`, and anitab1 row `01eh` is `a_njflipkick`, which he has
  on `sm_anitab1`.
  **AND HE LEAVES THE AFTERIMAGE, Reptile's own** - `superk_afterimage`
  (MKPROP.ASM) takes `ft_noob` beside `ft_reptile`, so the dive leaves one gmo
  object in his colours parked at the launch point, flashing out. Kung Lao and
  Ermac still get none. Nothing in that routine was Reptile-specific but the
  compare: the pose is anitab1 `01eh` either way (`NJFLIPKICK` for both) and the
  copy wears the diver's own palette off `*a11(opal)`. Measured identical to
  Reptile's: `NJFLIPKICK1A`, 33 ticks, drift 0, 61px behind him.
  **THE TELEPORT SLAM'S GHOST TRAIL IS BUILT AND SWITCHED OFF** (`noobdive_ghost`,
  MAINEQU.ASM, `0`; tried at the user's request, then reverted to match Reptile).
  `1` arms `ghost_arm_n` (MKDISP.ASM) on the slam's own pens and palette instead
  and `superk_afterimage` skips him (`noobdive_copy`), so he gets one shadow or
  the other, never both - his pose blitted in ONE pen out of a `.bss` ring, no
  object, no process, no palette. **Keep `RSK_GHOST_GAP` with it: THE GAP IS THE
  WHOLE DIFFERENCE BETWEEN A TRAIL AND TWO SMUDGES.** `ghost_arm_n` always writes
  `GHA_GAP`, 3 ticks between snapshots, right for the SLAM's thirty-odd-tick
  climb - but **the dive is over in six to eight** (measured: it connects at
  `since=6..8` at EVERY spacing the rig parks him at), so at 3 the ring never
  held more than two and the oldest was barely clear of him. That build read as
  "it doesn't trail behind the kick well" and the rig agreed in numbers:
  `ghosts_snapped 1` over a 5-tick armed window. At 2 it is 7 armed ticks and 3
  snapshots. Arming re-writes `GHA_GAP` every time, so the tightened gap cannot
  leak into the slam. Disarmed after `flight_call` returns and in
  `super_rep_hit`; neither is on every path (it unwinds the stack and jumps
  away), so `gh_life` is the backstop.
  **The rig READS `noobdive_ghost` instead of hardcoding which shadow to expect**
  - hardcoding either makes it fail honestly on a correct build the day the
  switch moves - and the two are EXCLUSIVE for every character, which catches a
  gate widened to everybody AND a build that armed both. The trail half reads the
  ring (`gh_src`/`gh_n`/`gh_snaps`): armed for THIS fighter all flight, and
  `gh_snaps` ADVANCING, the half a leftover setup cannot fake.
  **What he does NOT get is the CPU throwing it**
  - `drone_ajump_call`'s dive gate (MKDRONE.ASM, `drnsuperk`) tests ochar
  for `ft_reptile`/`ft_hathead`, and **MKDRONE SITS ON THE GSPA OUT-OF-MEMORY
  CLIFF**: a `cmpi ft_noob` plus its `jreq` is four lines with the `.if` and
  aborts the assembly with `>> Out of memory`, measured with the comment stripped
  to nothing. Giving it to the CPU means moving the `drnsuperk` block into
  MKDRNEW.ASM first, and that routine hand-unwinds its caller's process stack.
  `noobcpu`'s rule is unaffected - the CPU may only use moves a player has, not
  all of them.
  Rig: `tools/run_reptile_divekick_test.ps1 -Char noob`, the existing dive rig
  with a third character. **A select forced to `ft_noob` never confirms**, so it
  confirms SCORPION on the grid and swaps the slot during post-select, the way
  `noob_divekick_test.lua` does. Measured: `act_reptile_fly`, `NJFLIPKICK3A`,
  accelerating down, lands, 26 damage, victim **60px straight up**. `-Char
  reptile` and `-Char kunglao` PASS unchanged; the `noobdive 0` control reaches
  the fight as Noob and reports `dive_never_fired` on all four spacings. See
  [doc/NOOB_TRILOGY_MOVES.md](doc/NOOB_TRILOGY_MOVES.md).
- **SCORPION'S MK3 FIRE-SKULL FATALITY, WOLF ONLY: Down, Down, Up, Up, Up +
  HP in FINISH HIM, HOLDING BLOCK** (`scom_sc_mk3` / `sc_hi_punch`, MOVES.ASM;
  `p_store6` 4). It is UMK3's `scorpion_fire`: the stock MK2 mask-off and
  flame halves (`do_scortch` -> `sc_mk2_burn`), then the victim is handed to
  `sc_mk3_skel_burn` (UMK3SNYM.ASM, `.globl`) instead of `flaming_skeleton` -
  MK3's shared `sb_skeleton_burn`, which is also the end of MK3 Liu Kang's
  fire fatality. **It runs in the VICTIM'S OWN PROCESS, not Sonya's
  `sny_skel_fire` (a `pid_fx` process)**: `bonus_count` (MAIN.ASM) opens
  with `dallprc pid_fx` the instant `death_blow_complete` sets `f_death`
  -1, which for the scortch is mid-burn - the first cut froze on SKELFIRE18
  and never collapsed. Any effect that must outlive the death blow cannot be
  `pid_fx`. Sounds are Scorpion's burns': the burn scream
  (`ochar_sound 08585b8b7h`) and ScorpFall `$00B2` on the collapse, not
  `rsnd_death_voice` / MK3's priority-29 `fx_bones`. Its art is Sonya's `UMK3SNF` pack (SBFIRE/SKELFIRE, 109 KB);
  **the T-unit has 44 KB free in total, so everything is `.if wunit`**.
  Tested BEFORE `scom_sc_toasty`, because `joyskip` lets D,D,U,U step over
  the third Up and the shorter pattern would win. **Block must be held**:
  `joy_stance_loop` tests it before the stick, so Up does not jump; the
  mask `f1b1|f1b3|f1b4` permits it, and that is true of D,D,U,U+HP too.
  `tools/make_fly_moves.py` now reads WUNIT.ASM, so a `.if wunit` scom no
  longer lands in the T-unit fly table (where it would be undefined). Rig:
  `tools/wolf_scorpion_mk3burn.lua` via `run_wolf_boot_probe.ps1 -Script ...
  -Env WS_MAP=tmp\wolf\src\MK2.MAP,SC_TBL=tmp\wolf\src\UMK3SNF.TBL` - taps
  the blitter's SAG registers: `SC_MODE=mk3` PASS (all 38 SKELFIRE records
  drawn through SKELFIRE24, burn scream `027C`, ScorpFall `00B2` on the
  collapse), `SC_MODE=toasty` control PASS (same fatality slot, 0 drawn).
  **Liu Kang's red dragon ends in the same burn on Wolf** (2026-10-14):
  `lk_dragon_fire` (MKFX.ASM, `.if wunit`) hands the victim to
  `sc_mk3_skel_burn` the moment ROBOFIRE arrives (no MK1FIRE column / MK1
  skull) and holds the dragon 040h more so the bones fall before he morphs
  back. Same rig, `SC_WHO=lk` (fatality 12): PASS, all 38 records.
- **DAN FORDEN SAYS "CRISPY!" INSTEAD OF "TOASTY!" ABOUT ONE TIME IN THREE**
  (both boards; `crispy_roll` / `fx_crispy`, MAIN.ASM; `crispy_odds` 333 per
  1000). The uppercut peek (`forden_peek`, BGND.ASM) and Scorpion's fatality
  pop-up (`fx_toasty`, which then prints CRISPY !!) both roll it; the MK3
  fire-skull burn always gets `fx_crispy`, as D,D,U,U+HP always gets TOASTY.
  The roll is on `@blood_rand`, never `@rand`. The clip is UMK3's own
  (`sound/DFCRISPY_UMK3.dcs`, verbatim: track `$1077`, stream `$04FFFE`) in
  MILESPIT's old slot `$00B5-$00B7` = `triple_sndtab` CAh (`tsound 0cah`),
  stlaugh_patch.txt note (58). A Crispy peek still stamps `@toasty`, so it
  opens Smoke's Down+Start window exactly as a Toasty does. Rig:
  `wolf_scorpion_mk3burn.lua` `SC_MODE=toasty|peek SC_FORCE=crispy|toasty`
  (pins the seeds every frame; on the T-unit add `-Game mk2` and
  `SC_SNDLATCH=01d01030`) - all four PASS.
- **SCORPION HAS A SECOND TELEPORT, AND IT GOES FORWARD** (`scfwdtele`,
  MAINEQU.ASM; `do_fwd_decoy`, MKPROP.ASM). **Down, Forward + LOW PUNCH.**
  Retail's teleport is Down,Back + HP: he leaps AWAY, warps at the edge he is
  flying toward and lands BEHIND the man. This is the same flight mirrored -
  he leaps AT him, warps, and lands IN FRONT - so the pair is a mix-up rather
  than one move twice: the strike box is live from tick one (retail's
  "sticks" on a close opponent for the same reason) so a man standing there is
  punched on the way past, and from far out he crosses the screen and comes
  down on the side he started, a jump-in that READS as a crossover and is not
  one.
  **IT IS TWO INSTRUCTIONS.** `do_fwd_decoy` sets one flag and falls into
  `do_decoy`, exactly as `do_ermac_decoy` does; the launch kick, gravity, the
  anirate of 6, the afterimage, `decoy_scroll`'s camera freeze, the every-tick
  `stk_decoy` check, the warp and the landing are all shared and unbranched.
  The two that differ: **no `flip_multi`** (retail turns him to face the way he
  is flying, away, and the warp then lands him facing the man - flying TOWARDS
  him he already faces the right way, so the flip would put his back to the
  fight for BOTH halves of the flight), and **`towards_x_vel`** instead of
  `away_x_vel` at the same `0c0000h`. **`cos_edge` needed nothing**: it picks
  the edge off the SIGN of `oxvel`, not the facing flag - the note there says
  why - so it already warps either direction, corner clamp included.
  **The forward one is refused out of a flip kick/punch that hit a man on the GROUND** (2026-10-12, the user's call: no flip kick -> forward teleport juggle). `r_flipk` LAUNCHES a grounded victim, so "is he airborne" at the press is always yes - `fk_contact` (MOVES.ASM, at the flip kick's and flip punch's contact) records in `fk_ground_by` whether he was on the ground WHEN HIT, and `sc_hp_fwdtele` refuses while Scorpion is still in `act_flykick`/`act_flypunch`/`act_fk_sd` off such a hit. Any other air use, and the backward teleport, are unchanged. Rig trials `fkfwd` (refused), `fkback` and `airfwd` (allowed). **Both teleports share `l_decoy`** at `060h`, deliberately: two that each
  reset only their own timer would let him ALTERNATE them with no cooldown.
  `scom_sc_fwdtele` is its OWN record, not an alias on `scom_ice_ball` (the
  same Down,Forward at the same `010h` window) - an alias shares the WINDOW as
  well as the pattern, which is how `scom_spark` once ended up on Back,Back.
  `sc_lo_punch` tests the spear first and falls through, so Back,Back + LP is
  untouched. **The flag is ONE word for both fighters** because there is no
  sleep between the write and the two reads at `dec_takeoff` (`f_noedge_obj` is
  one object for the same reason), it is exported with `.globl` in RAM.ASM and
  `.ref`'d in MKPROP rather than `.global`'d from MAINEQU (the GSPA cliff), and
  `do_decoy` clears it on the way in so Ermac's fall-through and the drone's
  propell #4 cannot inherit it. **The CPU throws it as its long-range punish**
  (`drone_sc_fwdtele`, `ochar_punish` row 10), under the same `l_decoy` cooldown. `scfwdtele .set 0` compiles it all out.
  Rig: `tools/run_scorpion_fwdtele_test.ps1` - `fwd` / `back` / `fwdleft` /
  `cool` / `coolback`. It reads **`f_fwdtele`, not just the direction** (a
  hard-coded sign gives the right velocity on one side of the screen, which is
  why `fwdleft` fights from the other side) and asserts the **facing
  separately**, since a rig watching `oxvel` alone would miss `flip_multi` - the
  half of the change that decides whether he lands facing the fight.
  `coolback` is what proves the SHARED cooldown: the BACKWARD teleport refused
  by a timer only a forward cast could have set - and both cooldown trials WRITE
  `l_decoy` (a p1/p2 word pair; `get_tsl` is just `tick - l_decoy[p]`) instead
  of racing the last trial's landing, as `run_rain_halfdmg_probe.ps1` seeds
  `rh_cdmg`. **It teleports the victim out of the flight path on the takeoff
  frame**, AFTER reading the velocity: the strike box is live from tick one, so
  a forward teleport aimed at a man standing there CONNECTS and `decoy_hit`
  freezes the flight with no warp left to measure. `-Negative` crosses the two
  directions and every crossed trial must FAIL. Every constant is read out of
  the build and an unreadable one is **FATAL, never defaulted** - the launch
  speed is anchored on `dec_takeoff` because MKPROP has an EARLIER
  `away_x_vel` (Reptile's dive) and the new `.if` block puts `.endif` on the
  line before the call, two ways to get a plausible wrong number. A missing
  `src/mk2.map` is a named refusal, not a verdict, and an empty run is a
  FAILURE. See
  [doc/SCORPION_FORWARD_TELEPORT.md](doc/SCORPION_FORWARD_TELEPORT.md).
- **SMOKE THROWS THE SPEAR ON HIS OWN ROPE** (`smrope`, MAINEQU.ASM;
  `a_sm_rope_ani`, MKNJ.ASM).  He always threw it - `zap_offsets` row 14
  (MKDRONE.ASM) is `00ch`, the same `do_throw_spear` Scorpion uses - and the
  drone is his ONLY path: he is CPU-only (`toasty_check`, MKTOAST.ASM - Down +
  Start on THE PORTAL while "Toasty!" is up) and `char_lo_punch` row 14 is
  `sucide`, so a human Smoke cannot throw it at all.  What he did not have was
  art: **`sm_anitab2` was a bare ALIAS label stacked on `sc_anitab2`** - Midway's
  own arrangement, identical in mk2-readonly - so row 1 paid out SCORPION's
  `BIGRP1`/`BIGRP2` in flight and `SPEARHIT` once it stuck.
  **The rope was already drawn and nobody ever packed it.**  `COMEHERE1/2/3`
  sit in `data/NEWROPE.IMG` beside Scorpion's records: a coiled SPRING with a
  TRIDENT head, on a 27-step grey ramp of its own (`CUM_P`), built to the same
  three-frame shape - two of flight, one pulled straight.  Retail references
  them nowhere either.  They are packed now in `data/SMROPE.LOD` (bank 1,
  `0xB7E000`, top of the MK7MIL free run) and `sm_anitab2` is a real table, its
  other six rows copied verbatim.  **Part 3 (the pull wiggle) stays on
  Scorpion's `ROPEPULL` strips on purpose** - nothing reaches it, because
  `do_rope_pull` takes `find_part2` exactly once.
  **THE ANIPOINTS CARRY THE ALIGNMENT AND NO CODE KNOWS ABOUT IT.**  All three
  of Scorpion's rope records put the shaft's centre line on anchor **+31.5**,
  and his flight frames put the TIP at +135 (the taut one at +127).
  `COMEHERE1/2/3` shipped at `anix=aniy=0` and were anchored to land on those
  same three numbers (191/-23, 191/-23, 189/-25), so `stk_njspear` - the box
  both ninjas' ropes are tested with - needs no change and the trident arrives
  where the spear did.  The rope is a one-piece MULTIPART object, so frame
  changes go through `ani2` and never migrate it: the 8px settle between flight
  and taut is retail's, reproduced.
  **`ZOF>` IS LOAD-BEARING.**  `set_rope_clip` sets `dmaclp` and
  `lineup_rope_with_him` writes a column count into `ofset`, which makes the
  DMA SKIP THAT MANY SOURCE COLUMNS - and there is no indexing part way into a
  zero-run record.  Midway's own NEWROPE section in `data/MK4MIL.LOD` is `ZOF>`
  for exactly the five rope records and `ZON>` again straight after, which is
  the evidence.  With `ZOF>` + `PPP> 5` the payload is exactly `W*H*5` bits a
  record: 10,132 bytes, which is what LOAD2 wrote.
  **AND THE TAUT FRAME'S WIDTH WAS A HARD-CODED 304** - SPEARHIT's, Midway's
  own (identical in mk2-readonly), true while Scorpion was the only man on a
  rope.  `COMEHERE3` is 317 wide, so a rope measured with the other one's
  number draws 13px past him.  `lineup_rope_with_him` now reads `mp_sizex` off
  the frame it is drawing; both ropes measure themselves and neither has a
  number in the code.
  Rig: `tools/run_smoke_spear_test.ps1 -Who both` - it measures the SAG the DMA
  was handed, and checks the clip as an identity on the live object
  (`ofset + dist == mp_sizex`), which only holds for both ropes because of that
  change.  See [doc/SMOKE_SPEAR.md](doc/SMOKE_SPEAR.md).
- **KINTARO CATCHES YOU OUT OF THE AIR AND SLAMS YOU, and both bosses take
  the turn a block earns** (`gorograb` / `goropun` / `kahnkick`, MAINEQU.ASM).
  Measured, 16 cycles at diff 9: a FLIP KICK in connected cleanly **75% of the
  time against Kintaro and he answered 19%**; now it is **19% and he answers
  81%**, catching the man out of the air 13 times in 16 (`debug4` 7130h). The
  damage swings 162/205 to 45/612.
  **The air grab is the body slam with its order of operations changed** - no
  new art, no new lane, no new reaction. `goro_slam` matches the victim to
  Kintaro AFTER the full 24-tick grab animation, which is right for a man
  standing in front of him because he does not move in the meantime; a man in
  the AIR does, since `takeover_him` zeroes his velocity, so he HUNG where he
  was for the whole reach and the slam then teleported him down. Matching FIRST
  means the hands close where he is and he comes down with them. Everything
  after the reach is shared at `goro_slam_hold`.
  **ASK THE BUDGET LAST**: `goro_slam_ready` STAMPS `l_gslam` when it says yes,
  so a caller that asks and then declines has spent the slam's turn on nothing.
  **He could not see a man in the air at all.** `goro_catagory_jumps` entry 3
  was a literal **0** - every bare jump-in, landing and get-up invisible;
  `goro_counter_flipkp` named the GUARD in both `react_jump_table` slots, so
  the roll the table exists to make decided nothing; and `goro_stalk` fell
  through to `goro_air_wait` and STOOD THERE.
  **AND THE BLOCK WAS READ THE WRONG WAY ROUND.** `boss_wait_nonattack`
  returns a10 NON-ZERO when the guard WORKED (its own comment says so, and
  `kahn_block` reads it that way) and Kintaro's only punish hung off the ZERO
  case - the timeout. So kick, blocked, kick, blocked earned him nothing.
  `goro_take_the_turn` is the clean-block half, and it fills category 6 too,
  where `goro_counter_sd`'s whole answer was "guard a projectile, else go back
  to sleep".
  **Shao Kahn: kicks went through `react_jump_table` at TIER 1 while every
  PUNCH was guarded outright** - one kick in five ignored at diff 9. They go to
  `kahn_avoid_stationary` now (not `kahn_block` directly: it steps out of a
  swing that cannot reach, and guarding one that was never going to touch him
  cost two ladder matches). Measured on the ROUNDHOUSE: 56% -> 38% clean, punish
  50% -> 69%, damage dealt 456 -> 688. His flying kick moves tier 2 -> 3 (875
  -> 950, and one landed kick forces the guard instead of two): 19% -> 6%,
  punish 19% -> 38%.
  **THE STANDING HIGH KICK CANNOT BE BLOCKED BY ANY CPU IN THIS BUILD, and
  that is the reaction model working as designed.** It lands **6 ticks** after
  `act_hikick` is stamped (min = avg = max over every hit of every run) and
  `drone_react_delay` is **8** at diff 9 under `drnhuman` - so the think timer
  has not expired when the kick lands and the boss never makes a decision:
  blocked is 0% whatever the routing says, which is why two ROMs differing in
  exactly that routing played out frame for frame identically. A boss-only
  anticipation clause (hit queue says it landed twice -> drop to `drnhuman`'s
  own 5-tick floor) was built, assembled, and REMOVED: a `debug1` counter
  showed it firing ONCE in 12 cycles, because `p_predhit` is usually already
  non-zero on a repeated move and 5 ticks still loses to a hit at 6 once the
  dispatch and the guard pose are paid. The bosses already WIN that trade
  heavily - Kintaro takes 224 and deals 1,034; Kahn takes 192 and deals 687.
  **The rig's own control is the pair of trials my change cannot touch**
  (Kintaro's roundhouse, Kahn's high kick): both came out BYTE-IDENTICAL across
  the two ROMs, which is what says the four rows that moved moved because of
  the code and not the dice. At n=16 Kintaro's high kick read 38 -> 50 and that
  was sampling: at n=34 it is 13/34 against 14/34.
  See [doc/BOSS_AIR_AND_PUNISH.md](doc/BOSS_AIR_AND_PUNISH.md); rig is
  `tools/run_boss_exploit_test.ps1 -All`.
- **Kintaro has a face smash - it is a GRAB AND PUNCH.** He catches you on
  `TIGERFACE3`, punches you in the face twice on `TIGERFACE7`, then throws
  you: the `FACE SMASH` seqscr in `data/TIGER4.IMG`, built in `do_noogy`'s
  shape. The victim wears Jax's gotcha-grab pose (`anitab1` `010h`, `013h` for
  a boss), is walked by `double_mframew`, drawn IN FRONT (`me_in_back`), and
  released with `r_last_noogy` so the second punch throws him. **The punches
  do not test a box** - a held man is not a strikable target; damage is
  `damage_to_him`. Two traps: `double_mframew` ends on the VICTIM's
  terminator, so both punch parts must be FOUR rows to match every hit-high
  lane in the game, or Kintaro's lane runs off the table and crashes; and
  `adjust_him_a0` is `[Y:X]`, not `[X:Y]`.
  See [doc/KINTARO_FACE_SMASH.md](doc/KINTARO_FACE_SMASH.md); rig is
  `tools/run_kintaro_facesmash_test.ps1`.
- **Kintaro has a spinning backhand.** `TIGERBACK1-6`, the `BACKHAND` seqscr
  in `data/TIGER4.IMG`. The art is a rotation, so the move IS a turn with a
  strike box on the way past - it is wired to `drone_turnaround`, and he can
  pivot THROUGH a cross-up instead of just pivoting. `TIGERBACK3` is the
  contact frame (reaches 108px past the anchor, the furthest in the lane);
  48 damage. See [doc/KINTARO_BACKHAND.md](doc/KINTARO_BACKHAND.md); rig is
  `tools/run_kintaro_backhand_test.ps1`.
- **Kintaro has a get-up kick.** He rises off the floor straight into a kick
  instead of just standing up - the `GETUPKIK` sequence authored in
  `data/TIGER3.IMG` and never coded. It needs no new animation table:
  `a_goro_getup` (ani `00bh`) chained into `a_goro_kick` (ani `004h`) IS the
  authored sequence, and `a_goro_kick`'s `TIGERKICK1..4` had been effectively
  dead art - `goro_stalk` re-tests the same distance at `goro4` that sent it
  to `goro_uppercut`, so `rt_goro_close` is only reachable via a 5%
  `goro_mean_check` after an air wait. **The hook that fires is
  `goro_fall_on_back` (MKREACT.ASM), not `boss_getup`** - `fall_on_my_back`
  branches every boss to the inline get-up and `drone_getup` is never entered
  for an uppercut knockdown. Gated on `ft_goro`, `winner_status == 0`, range
  `<= 060h` and `ask_mr_diff`; 27 ticks of startup (5 get-up rows + 4 kick
  rows, both at sleep 3 - `GETUPKIK` holds every row the same and only the
  extended pose double), so it can be ducked or walked away from.
  See [doc/KINTARO_GETUP_KICK.md](doc/KINTARO_GETUP_KICK.md);
  rig is `tools/run_kintaro_getup_kick_test.ps1` (7/7 connected at diff 9).
- **A morphed Shang wears the TARGET's DEFAULT costume** (`stmorph_defpal`,
  MAINEQU.ASM; `pnorm_morphed_shang` / `pnorm_morph_default`, MKGUYS.ASM).
  `player_normpal` resolves a palette by COSTUME LANE - the six select-screen
  alternates (Start + LP/Block/HP/HK/LK/Coin) each have their own
  `character_palettes_N` table, and the lane is remembered per player in
  `@alt_pal_owner`. Shang kept his lane across a morph, so he landed on the
  target's entry in SHANG's lane: a costume of a character the lane was never
  chosen for. Rain is the clearest case - his default is `RNUMK3_P`, his
  Start+LP is `RNUMK2_P` and his Start+HP `RNUMK1_P`, and the other three
  alternates are all `SUBALT4_P`, so any Shang on one of those turned into
  a Sub-Zero-coloured Rain. **Clearing the object's costume bits is not enough
  on its own**: `player_normpal` RECOVERS the lane from `@alt_pal_owner`
  whenever the object has lost it (the `pnorm_*_owner` branches), so the next
  repalette puts it straight back - and a morph is far from the only
  repalette, since Raiden's lightning, every knockdown and `back_to_normal`
  all call it again. So it is a FRONT DOOR: `player_normpal` asks "am I a
  morphed Shang?" first and takes a branch that never looks at a lane. The
  bits are cleared as well as ignored, so `oflags2` tells the truth - the
  other player's mirror test and `change_to_bloody_pal` both read them.
  **The morph MIRROR is unchanged and moved here**: become the man in front of
  you while he is on HIS default and you still take the alternate so the two
  can be told apart. It works now for a Shang in a manual costume, which it
  never did in `shang_morph` - that copy OR-ed in `m_ugly_pal` and
  `player_normpal` tests every `repaltN` bit BEFORE it, so six of Shang's
  seven costumes ignored the distinguisher entirely. Reverting is untouched:
  `back_to_shang_form` restores `ochar` first, the front door stops matching,
  and the owner recovery gives him his own costume back. Rig:
  `tools/run_st_hidden_morph_test.ps1 -Costume default|block|lp|hp|hk|lk|coin`
  (7/7 on all seven; at `stmorph_defpal .set 0` the `hk` run fails 6 of 7).
- **Shang Tsung morphs into RAIN: hold Down + Block, tap Low Kick**
  (`stmorph_rain`, MAINEQU.ASM; `stlk2` / `st_rain_holding`, MOVES.ASM).
  A CHORD, not a stick motion, because his low kick already carries two
  fatalities and two morphs - and because BLOCK is what makes it free:
  `button_mask` rejects every combo special while block is held, so it
  collides with nothing he can throw. That is also why it cannot go through
  `combo_look_lr`, which bails outright on a held block: the block bit is
  read straight off `@switch` (`st_rain_holding`, a copy of `sunm_holding`
  rather than a `callr` 3,400 lines up the file). Tested at `stlk2`, AFTER
  the FINISH HIM branches, so no fatality input changes, and releasing block
  before the kick still gives BARAKA's Down,Down+LK.
  **No unlock flag**, unlike Jade and Ermac: Rain is a START tap on Sub-Zero
  at the select screen (`morph_table`, MKSEL.ASM) and is always pickable.
  The lane is `a_st_2_rain` (MKST.ASM) - Sub-Zero's own retail morph frames
  `STSUBZERO1-3` under `SHRAIN_P`, record 31 of `data/MKMORPH1.IMG`, hand
  carried into IMGPAL3.ASM and policed by `tools/sync_jade_pal.py --check`
  in Phase D. He stands up in `NJ1STANCE1` because Rain's stance is
  Sub-Zero's. **No new art.** His `st_anitab2` row is **16h**, not his ochar
  (19 = 13h, the retired old-Shang morph), so `shang_morph` and
  `back_to_shang_form` both reach it through `st_hidden_morph_row` - which
  is why `stmorph_rain` REQUIRES `stmorph_hidden` and has an `.emsg` that
  proves it. Block+Up+HK reverts him like any other form. Rig:
  `tools/run_st_hidden_morph_test.ps1 -Mode unlocked|locked` (7/7 both; the
  `locked` run is the assertion that he is ungated).
- **A MORPHED SHANG WHO LOSES TURNS BACK INTO HIMSELF BEFORE HE SWAYS** (`dizzy_dude`, MKCANNED.ASM, 2026-10-11 playtest: "he stays in Kano"). `am_i_shang` (the PICK, true through a morph) and `ochar != ft_st` -> `back_to_shang_form`, the revert `st_victory` already runs for a winner, then `pm_special` (init_special_act's) is cleared so he is a plain sitting duck. Rig `tools/wolf_shang_dizzy_unmorph.lua` (Wolf, Kano): Kano at FINISH HIM, Shang +22, stunned - PASS.
- **Shang Tsung can drop a morph: Block + Up + High Kick.** One gesture out
  of all eleven forms, checked in the switch dispatch by
  `shang_unmorph_check` (MOVES.ASM) from `bj_block` / `bj_hi_kick` / `jj_up`,
  ahead of the host character's own handler. It hands the player's proc to
  retail's `back_to_shang_form` (MKCANNED.ASM) through `restricted_xfer`.
  Block is load-bearing twice over: it stops Up from becoming a jump (an
  airborne caller is refused by `restricted_xfer`), and no combo special can
  be live while it is held (`button_mask` rejects every one of them), so the
  gesture collides with nothing - including during FINISH HIM. `shang_unmorph`
  (MAINEQU.ASM) compiles it out. **The `callr` never returns on a match, so it
  drops its own return address with `pull a14` first** - `prcdsp` does not
  reload SP per process, so a proc that dies one word deep leaks that word
  permanently. Rig: `tools/run_st_unmorph_test.ps1` (11/11 forms, plus a
  negative control that the gesture is inert when he is already Shang).
- **The CPU Shang can pick his own form too: `drone_unmorph` (MAINEQU.ASM).**
  `drm_sample` used to remap candidate 6 to Mileena; it no longer does, and
  `shang_morph` routes an `a9 = ft_st` pick to `back_to_shang_form`. Also
  `drm_done`: the drone declines a roll that picks the form it is already
  wearing, which was costing a full helpless lane at far range (2 of 5
  decisions measured). Drone-only - the human reaches `shang_morph` with a9
  already chosen. `tools/morph_pick_odds.py --check` enumerates the exact pick
  distribution from the tables (1.8-14.2% for his own form at diff 9) and
  fails if it ever drifts above 30%. Rig:
  `tools/run_drone_morph_choice_test.ps1`; pass `-HoldForm` to suppress the
  0200h auto-revert, **which otherwise reverts him before he ever gets to
  choose** - 7 of 8 decisions in a 19k-frame run were taken while he was
  already Shang.
- **Coin op by default; free play only online.** `forcefree` (SYSEQU.ASM) is
  `0`, so the ROM behaves like a stock board: pricing from the coinage
  dipswitch / CMOS, `CREDITS: n` on the attract title, START refused at zero
  credits, and the TEST switch opens the operator menu. Free play is granted at
  RUN time by `f_netplay` - a single test at the top of `get_adj`
  (DIAGCMOS.ASM), which every free-play question in the game funnels through
  (`checkfree`, `cr_both`, `cr_strtp`, `cr_contp`, `get_cstr`, `plotcoinage`).
  The host wrapper writes `f_netplay` (Workplace/freeplay-gametalk
  does, from `netcore::set_netplay_flag`); the ROM never does. See
  [doc/NETPLAY.md](doc/NETPLAY.md) "Free play is now runtime".
  Regression test: `tools/run_coin_freeplay_probe.ps1 -Mode coin|netplay`.
- **Hashing a ROM inside `mk2.zip` against `rom/*.bin` is NOT a staleness check.** `mamerom.py` finishes by calling `crc_spoof.spoof_zip()`, which patches a 4-byte window in each ROM's tail padding so CRC32 matches FBNeo's hardcoded table. Program chips are patched at `0x07FFBC` (0xFF padding before VECTORS), so the zip **always** differs from `rom/mk2_uj12.bin` / `mk2_ug12.bin` by 4 bytes per chip, and differs again on every repackage. To actually check for a stale install, byte-diff and confirm the only differences are inside that padding window.
  **This applies to the SOUND chips too** (`crc_spoof.py` `PATCH_OFFSETS`): u2-u7 are patched at `0x07FFFC`, so every one of them differs from `sound/mk2_stlaugh.zip`'s copy by 4 bytes, forever. Hash-comparing u2-u7 therefore reports "the custom audio was dropped" on a perfectly good set - a false swap, every single time. Byte-diff instead and confirm the differences sit in that 4-byte window: 4 per chip, all inside `0x7FFFC-0x7FFFF`, nothing outside, means the patched streams (STLAUGH, Jade Flash, the Rain name, ...) carried through intact. Note the offset is not guaranteed fixed - `find_tail_padding_offset` walks backwards for real padding if the preferred offset isn't `FF`/`00`, so read the window out of the diff rather than asserting the constant.
- LOAD2 without `/E` writes `bank=0xFFFF` in IRW headers ? `makevrom.py` uses filename-based bank fallback
- BGNDTEST.LOD is MK1 development leftovers ? not needed for MK2 build (MK7MIL.LOD has the backgrounds)
- Sound ROMs (U2-U7) in `sound/` are PLBUILD-regenerated with `%DATE%` embedded ? CRCs won't match retail. Use `python mamerom.py --source-video` (no zip argument - see the packaging warning above) to merge sound; it prefers the patched set automatically.
- The leaked TBL files in `src/` are 1:1 with retail per Asure ? keep them, don't replace with LOAD2 regenerated versions. If you ever overwrite them by accident, restore from `mk2-src.zip`.
- Our source-built video ROMs (via makevrom.py with Asure's LOAD2 flags) match retail L3.1 byte-for-byte ? 0 CRC warnings for 12 video ROMs
- `mk2.map` stores TMS34010 BIT addresses. The DEBUGGER is split: `wpset`/`bpset` take raw bit addresses, while `w@`, `saver` and `loadr` take byte addresses (bit_addr / 8).
- **Lua `space:read_u16`/`read_u32`/`write_u16` take the RAW bit address**, not bit_addr/8 - this line used to say byte addresses and it was wrong, which cost a wrong correction to another session on 2026-09-17. `tools/flybrain_play.lua` and `tools/battle_stability_sweep.lua` both feed map values straight in, and a pointer read out of RAM is offset by BIT field offsets (`r16(q + 0x1f0)` for `p_action`). `mk2_test.lua`'s `v // 8` is stale - do not copy it. `read_u16` does align DOWN to a 16-bit boundary, so byte-granular walks need an `rd8` helper; `.bss` symbols are unaffected.

## Project Structure

```
src/           Main game source (ASM, TBL, GLO, HDR, H files)
data/          Game assets ? background images (.BDB/.BDD), sprites (.IMG),
               generated .IRW files, LOD files, IMGBUILD.BAT
  _orig_lod/   Backup of original LOD files (before strip)
sound/         Sound system ? compressed audio (.CMP), build tools, U2-U7.ROM banks
doc/           Documentation ? background format (blimp/), image tools (it/), loader (load2/)
tools/         Curated DOS toolchain used by build (GSPA, GSPLNK, GMAKE, LOAD2, BIGSREC)
ti/            Full TI TMS34010 toolchain (reference/fallback ? larger superset of tools/)
SYS/           Alternate NDSP/system source (reference ? not used by our build)
rom/           Built ROM output (.bin, .ug*, .uj*, mk2.zip)
  debug/       Header-stripped raw IRW bins for MAME `loadr` (via makevrom.py --debug-bin)
tmp/load2/     LOAD2's throwaway table-file output dir (must exist for build)
_old/          Archive of obsolete files (safe to delete if not needed)
```

## Source File Types

| Extension | Purpose |
|-----------|---------|
| `.ASM`    | Assembly source ? game logic, rendering, characters |
| `.TBL`    | Animation/data tables ? frame sequences, move definitions |
| `.GLO`    | Global symbol exports ? link character modules together |
| `.HDR`    | Macro definitions (MACROS.HDR) |
| `.H`      | Equate/constant headers (BGNDEQU.H, PAL.H) |
| `.EQU`    | Equate files (MENU.EQU) |
| `.TVS`    | Toolsmith Viewer Script ? debugger configuration |

## Key Source Files

### Core Engine
- **MAIN.ASM** ? Entry point (`SETUP`), game state machine, main loop
- **MPROC.ASM** ? Process scheduler (cooperative multitasking, 18.28ms ticks)
- **RAM.ASM** ? All RAM variable declarations and memory layout
- **MKSTRUCT.ASM** ? Data structure definitions (process, object, palette)
- **UTIL.ASM** ? General utilities (random number generator, math)

### System Headers (include order matters)
- **DISPEQU.ASM** ? Display system equates, object block layout, rendering flags
- **SYSEQU.ASM** ? Hardware equates, memory map, DMA config, interrupt vectors
- **MACROS.HDR** ? Assembly macros (memory ops, process control, stack ops)
- **MAINEQU.ASM** ? Game-specific equates and global function exports
- **DIPEQU.ASM** ? DIP switch flags (violence, blood, coinage, country)

### Game Systems
- **MOVES.ASM** (95 KB) ? Combat engine, move execution
- **MKREACT.ASM** (80 KB) ? Hit detection and damage reactions
- **MKDRONE.ASM** (96 KB) ? Opponent AI
- **BGND.ASM** (74 KB) ? Background rendering with parallax scrolling
- **MKDISP.ASM** (54 KB) ? Display management pipeline
- **MKSEL.ASM** (58 KB) ? Character selection screen
- **MKSOUND.ASM** (41 KB) ? Sound effect triggering
- **MKINIT.ASM** (36 KB) ? Game initialization and mode setup
- **MKAMODE.ASM** (29 KB) ? Attract mode / demo play

### Per-Character Modules
Each character has an ASM file (moves/logic), TBL file (animation tables), and GLO file (exports):
- MKLK (Liu Kang), MKJC (Johnny Cage), MKRD (Raiden), MKNJ (Ninja/Scorpion/Sub-Zero)
- MKST (Shang Tsung), MKSA (Baraka, "Sword Arms"), MKFN (Kitana/Mileena, "Female Ninjas"), MKJX (Jax)
- MKMILEE (Mileena helpers), MKHH (Kung Lao, "hathead"), MKBOSS (Shao Kahn), MKSK (Shao Kahn helpers), MKGORO (Kintaro)

### Effects & Sequences
- **MKBLOOD.ASM** ? Blood and gore effects
- **MKFX.ASM** ? Particle effects
- **MKDEATH.ASM** ? Fatality execution
- **MKDIE.ASM** ? Death animations
- **MKFALL.ASM** ? Fall/knockdown animations
- **MKSLAM.ASM** ? Throw/slam animations

### Diagnostics (DIAG*.ASM)
24 files for arcade hardware self-test: display tests, audio diagnostics, CMOS, coin counters.

## TMS34010 Assembly Conventions

### Register Usage
```
A0-A14   General purpose working registers
A13      Current process pointer (critical ? do not clobber in process code)
A12      Process stack pointer
A7       Return address / program counter
SP       System stack pointer
```

### Common Macros (from MACROS.HDR)
```
addrm    reg, addr       ; Add register to memory
subrm    reg, addr       ; Subtract register from memory
incm     addr            ; Increment memory word
decm     addr            ; Decrement memory word
bset     bit, addr       ; Set bit in memory
bclr     bit, addr       ; Clear bit in memory
sleep    n               ; Suspend process for n ticks (18.28ms each)
create   pid, addr       ; Spawn new process
kill     reg             ; Terminate process
push     reg             ; Push to system stack
pull     reg             ; Pull from system stack
pushp    reg             ; Push to process stack (A12)
pullp    reg             ; Pull from process stack (A12)
```

### Process System
- Game uses cooperative multitasking ? each character, effect, and UI element is a process
- Processes yield via `sleep` and get dispatched by `prcdsp` in MPROC.ASM
- Process ticks are 18.28ms, one per display refresh (54.7068 Hz)
- New processes created with `create` macro, self-terminate with `sucide` (sic)

### Naming Conventions
- Labels: lowercase with underscores (`p1_start_button`, `clrworld`)
- Constants/equates: UPPERCASE (`WORLDTLX`, `DMACTRL`)
- Character prefixes: `mk` prefix for game modules, `diag` for diagnostics
- Player-specific vars: `p1_` / `p2_` prefix in RAM.ASM

### Assembler Directives
```
.file    'name.asm'      ; Source file declaration
.width   132             ; Listing width
.option  b,d,l,t         ; Assembler options
.mnolist                 ; Suppress macro expansion in listing
.include file.asm        ; Include source file
.global  symbol          ; Export symbol
.text                    ; Code section
.bss                     ; Uninitialized data section
.word                    ; 16-bit data
.long                    ; 32-bit data
```

## Assembler gotchas
- Macro names are **case-sensitive** in GSPA 6.10 ? `push` macro ? `PUSH` native instruction. Multi-register push/pull must use `mmtm`/`mmfm` directly.
- `callr` (PC-relative call) has a ?32KB range. Cross-OBJ calls to distant functions must use `calla` (absolute). **GSPLNK wraps an overflow silently** - MKDRONE's `callr check_block_bit` landed 64KB away in MKHANG and was the intermittent Dead Pool TRAP 30. `tools/check_pcrel_range.py --check` (Phase D) recomputes every cross-object relative branch.
- TMS34010 uses **bit addresses** ? all COFF vaddrs/sizes are in bits. Divide by 8 for byte offsets.
- **THE BUTTON PORTS OVERLAP, AND A SINGLE-PLAYER TEST CANNOT SEE IT.** There
  are TWO switch words - `switch` (01600000h) and `switch2` (01600020h,
  SYSEQU.ASM) - and the per-player masks in MAINEQU are only unique WITHIN a
  word. `p1b0` (P1 High Punch, on `switch`) and `p2b1` (P2 Low Punch, on
  `switch2`) are BOTH 010h; `p1b2` and `p2b4` are both 020h. The equates that
  live on the second port carry a `; switch 2` comment and that comment is the
  only thing distinguishing them. So moving a button test from one button to
  another by swapping the mask, while still reading `@switch`, silently tests
  **player one's High Punch** for player two's Low Punch - and every 1P rig in
  the tree passes, because P1's own bits happen to be right. Read the port the
  button actually lives on: JOY.ASM's `fa_t_free` is the correct shape
  (`move @switch2,a2,l` then `p1b1`/`p2b1`). Found moving Kung Lao's boomerang
  from HP to LP (`slhat_lp_held`, MKZAP.ASM). Same family as the bit-address
  line above: it answers confidently and wrongly rather than failing.
- `DIAGDICT.ASM` is a pure-equates include file ? not assembled separately, not in MAKEFILE.
- `ejbbug equ 0` (SYSEQU.ASM) ? disables debug branches; all `.if ejbbug` blocks are dead code.
- `sucide` (sic) is canonical ? do not "fix" to `suicide`.
- **`ermac` is NOT an error report - it is `jauc $`** (MACROS.HDR), an infinite
  loop. The scheduler is cooperative, so a process spinning there never yields:
  the whole board is hung with the screen still refreshing off the interrupt,
  which reads as a soft lock on a drawn stage, not as a crash. Twelve sites.
  The palette ones fire when the FOREGROUND POOL runs dry - `nmfpal .set 35`
  (MAINEQU.ASM), shared by both costumes, every effect object, blood, smoke,
  projectiles and the four beats of an electrocution. **`fpal_fail` (PALL.ASM,
  `.globl`) counts every `getfpal` failure since power-up** - read it in a rig
  or the debugger before blaming the pool for a stuck palette or an object
  drawn in boonpal's yellows. Three sites reachable from play were softened
  2026-09-29 (Raiden's ambient crackle, Kahn's NUPOWER glow, `initobj`); all
  three had `delpal` BEFORE `getfpal`, which widens the window and leaves
  nothing to fall back on. **Claim the new map first, keep the old one on
  failure** - `freepal` saves a0/a1, so the new map crosses `delpal` in a1.
  `delpal` does not zero `opal`, so an explicit `delpal` then `delobjp` double
  frees.
- **A FALL-THROUGH IS A BRANCH TARGET WITH NO NAME.** `pnorm_check_temp_alt`
  (MKGUYS.ASM) ended its mirror test on `jreq player_ugly_pal` and fell through
  for the other answer, which reached `player_nice_pal` - the next label in the
  file. A later `.if stmorph_defpal` block was inserted between the two, so the
  drop landed on `pnorm_morphed_shang`'s bare `rets`: `player_normpal` returned
  having repainted nothing and never cleared `pm_alt_pal`, so the man stayed in
  whatever TEMPORARY palette he last had - permanently, through knockdowns and
  round resets. Needs a mirror match plus the other man on a manual costume,
  which is why it hid. Neither GSPA nor Phase D can see this; before inserting
  a `.if` block, an `.include` or a routine inside an existing one, check what
  runs off the end above it and give that path an explicit `jruc` first.

## Other files
- `src/MAKE.BAT` assembles all 70 ASM files (GSPA only, no linking). `python build.py` does the full build pipeline.
- `TEMP.BAT` uses `ljbook` (Midway listing/printing tool) ? not needed for compilation.
- `MAIN.TVS` is a Toolsmith debugger script ? for live debugging on original dev hardware.
- Animation tables in `.TBL` files are data-driven ? character behavior can be modified via tables without touching logic code.
