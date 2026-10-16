# Asset Space Ledger - Current Live Layout

## 2026-10-13: 31 unreferenced palettes removed - 4,270 bytes of PROGRAM ROM

Program ROM is the binding budget on both boards (T-unit 4,860 bytes left;
Wolf 25 KB after Nightwolf and Robot Smoke), and palettes are 143.5 KB of it -
1,098 records.  A census by content and by reference (every `.ASM`/`.TBL`/
`.GLO`/`.HDR` token outside comments and `.globl/.ref` lines) found 31 that
nothing reads, all removed:

| where | palettes | bytes |
|---|---|---:|
| `src/BGNDPAL.ASM` | NMOCK WALLS WATCHER BURN6 SKELTS2 RUBLE BATWALL GRND2 btree_p ntree_p WTRK4 WTRK2 tre3 SHRUB3 DEADBH SHRUB1 | 2,008 |
| `src/MK2PALS.ASM` (generated) | the twelve `M2*BLD_P` - `tools/make_mk2pals.py` no longer emits them: the bloodied Start+HP rows are COSTPAL's `KP_*BLD1_P` (`make_costume_palettes.py` repointed them), so these copies were only ever `.ref`'d | 1,550 |
| `src/MKGUYS.ASM` | noob_froze_p UGBLUD2_P SCRBLD2_P | 390 |
| `src/BGND.ASM` | oh_moflr_p oh_moflr_gray_p (marked UNUSED in the source; moflr2_p is live) | 260 |
| `src/MKZAP.ASM`, `IMGPAL7.ASM`, `MKFX.ASM` | jade_boom_shadow_p silo_p yelfight_p | 62 |

Measured: T-unit headroom 4,860 -> **9,130** bytes.  Proof nothing changed on
screen: the build and Phase D pass, `src/MK2PALS.ASM`'s diff is the twelve
blood palettes and nothing else, and `tools/run_mk2pals_test.ps1` is 12/12 on
the installed set.  That rig had been failing since the 2026-10-11 IMGTOOL
renames (`M2KTBLU_P` is `KTALT1_P` in the library); `mk2pals_expect.py` now
falls back to the linked copy, which `make_mk2pals.py --check` proves equal.

**Not taken: 14.8 KB of byte-identical palettes under different names** (86
groups - e.g. `KP_JCALT1_P` = `M2JCRED_P` = `CAGERED_P`).  Every member is
referenced, and the game keys colour maps by palette ADDRESS, so merging would
make two live objects share one map (and one `death_fade_excludes` entry), and
the generators copy on purpose so a repaint of one never moves another.  If
program ROM runs out, that is the next 14.8 KB - one group at a time, checking
who uses each member.

Also measured and NOT taken: compiling out the five runtime-off prototypes
nothing in the game arms (`palrect`, `cpupatch`, `reflfx`, `vsplit`, `rowrep`)
frees only 1,792 bytes.

## 2026-09-20: FRIENDSHIPS REMOVED - 199,386 bytes, bank 1

The whole friendship feature is gone from the ROM: code, tables and art.
The largest single reclaim this project has made - it beats BIGGORO (139,286)
and nearly doubles the total free video space.

| | before | after |
|---|---:|---:|
| bank 0 free | 11,898 | 11,898 |
| bank 1 free | 14,868 | **214,254** |
| total video free | 26,766 | **226,152** |
| largest single run | 3,936 | **167,940** |

The freed space is two runs, both bank 1, both at the tail of the LOD that
packed the art:

| slot | bank | freed range | bytes |
|---|---|---|---:|
| MK6MIL | 1 | `0x9C4FFC..0x9EE000` | 167,940 |
| MK7MIL | 1 | `0xB7933A..0xB82000` | 36,038 |

**Removed from `data/MK6MIL.LOD`** (the `ASM> MKFRIEND.TBL` block, 179
records): the ten bouncing `FRIENDSHIP_*` letters out of `MKFRIEND.IMG`;
`TMHATRICK1A..8C` + `RABBIT1-4` (HATHED12); `JCFSBONUS*` + `AUTOGRAPH1-8`
(CAGE9); `LKDANCIN*` (KANG9); `UGFSBONUS*` + `UGGIFT1-3` (UGMO8); `KTBAKE*`,
`KTPLANT*`, `MEPLANT1-7`, `KTCAKE1-3` (KAT10); `STFSBONUS*` + `RAINBOW*`
(TSUNG9); `NJFSBONUS1A..4A` (NINJAS12).  Also `BC_HAPPY1-3`, the smile win
medal (MKSCORE.IMG) - it only ever counted friendships.

**Removed from `data/MK7MIL.LOD`** (the `ASM> MKFRND2.TBL` block, 32
records): `NJFSBONUS4B/4C`, `JXFSBONUS*` (NUJAX9), `KIDTHUNDER1..7D` (RAID8).

`AUTOGRAPH7` went with it. It was an authored-but-undrawn frame the
art-reference graph had been keeping as AUTHORED under the "partly-drawn IMG
sequence" rule; with the sequence itself gone there is nothing left to keep
it for.

**The .IMG files are untouched.** Only the LOD entries that packed these
records into the video ROM were removed, so every frame is still in
`MKFRIEND.IMG` / `HATHED12.IMG` / `CAGE9.IMG` / `KANG9.IMG` / `UGMO8.IMG` /
`KAT10.IMG` / `TSUNG9.IMG` / `NINJAS12.IMG` / `NUJAX9.IMG` / `RAID8.IMG`, and
the whole feature can be put back by restoring the two LOD blocks and the
`src/MKFRIEND.*` files from git. `doc/UNUSED_SPRITES.md` and
`doc/IMG_SUBFRAME_AUDIT.md` still list the art for that reason - they audit
the IMGs, not the ROM.

**Program ROM:** `src/MKFRIEND.ASM` (1,084 lines), `src/MKFRIEND.TBL` (179
records) and `src/MKFRND2.TBL` (32 records) deleted; the six `FRIEND*_P`
palettes in `IMGPAL6.ASM` and `SMILE_P` are left in place as dead data,
following the `lggoro_p` precedent (program ROM is not the scarce resource).

Full writeup, including every code hook: `doc/FRIENDSHIP_REMOVAL.md`.

## 2026-09-19: SAHELI2/3 retired for MK1's old-man Shang (MK1ST1-3)

Shang's soul escape now plays MK1's own OLD-MAN art - the shake while the
souls leave him and the collapse after (`data/MK1SHANG.IMG`, cut out of
`C:\MAME\roms\mk.zip` by `tools/make_mk1shang_img.py`, the source of truth).
Eight frames, one composite each, 6bpp (every frame reaches colour 52-63):
**27,496 bytes packed**. Video free space was 39,920 bytes in slot tails, the
largest 3,252, so it needed a retirement.

**Retired: SAHELI2 + SAHELI3** (Baraka's heliport touchdown / dive-tumble
frames, 26,374 bytes). The art-reference graph classed them DEAD and a source
search confirmed it: no `.ASM` referenced any of their eight records, only the
two `.INCLUDE`s in `MKSA.ASM` that defined the labels (the LOD/IMGBUILD
comments about `do_sa_helitest` were stale). Their LODs and tables are in
`_old/saheli_retired/`; the live heli art (`SAHELI.LOD`) is untouched.

| slot | bank | range | bytes | holds | payload |
|---|---|---|---|---|---|
| **MK1ST1** (was SAHELI2) | 1 | `0xBF1FB0..0xBF61D0` | 16,928 | SHK1 SHK2 COL1 COL4 | 14,980 |
| **MK1ST2** (was SAHELI3) | 1 | `0x9FC000..0x9FE800` | 10,240 | SHK3 COL2 COL3 | 9,778 |
| **MK1ST3** | 0 | `0x797500..0x7980F0` | 3,056 | COL5 (lying) | 2,738 |

The two SAHELI slots hold 27,168 - 328 short of the set - so the lying frame
went off the **TOP** of JADMIL1's guard (JADMIL1's slot end pulled back
`0x7980F0 -> 0x797500`; its frozen payload ends `0x79743C`, 196 bytes of
guard left). Bank 1 is safe only because `soul_shang_begin` clears Shang's
shadow bit before the first old-man frame.

**Trap hit while retiring:** `promote_tbls.py` copies every `tmp/load2/*.TBL`
that `src/` lacks as `NEW`, and LOAD2 never clears that directory, so the
first build resurrected `src/SAHELI2.TBL`/`SAHELI3.TBL` from this morning's
snapshot. Retiring a sidecar means deleting its `tmp/load2` table too.

## 2026-09-12: STBURST removed from MK7MIL - 28,140 bytes, bank 1

The [third graphics prototype](graphics_opportunities/STBURST_PROTOTYPE.md)
deletes `STBURST1A..16D` from `data/MK7MIL.LOD`. The audit filed these as a
cross-LOD duplicate to be SHARED; they are not. Shang's burst is played from
`MKST.TBL`'s own 28 records in MK3MIL, and the 23 MK7MIL copies landed in
`MKFATAL.TBL`, which only MKDEATH.ASM includes and which never references them.
Dead art with no consumer.

| Run | Bank | Payload before | Payload after | Free run above it |
| --- | ---: | ---: | ---: | ---: |
| MK7MIL | 1 | 1,637,980 | **1,609,840** | 24,996 -> **53,136** |

**28,140 bytes recovered**, plus 322 bytes of program `.data` from the dead
headers. Bank 1 free total 257,536 -> 285,676. The recovered space is one
contiguous run at `0xb89070..0xb96000` and **nothing has been moved into it**.
Bank 0 - the tight one - is unchanged.

Two things this cost, both now permanent guards:

- 627 records slid down with the payload. `tools/art_identity_snapshot.py`
  decodes and hashes every record's pixels so a reflow can be proved rather
  than assumed: 627 moved, pixels identical, **0 changed**.
- Six hand-written headers in `MKBABY.ASM` and `MKRD.ASM` point at a bit offset
  INSIDE MK7MIL and nothing regenerated them. `tools/sync_inline_sags.py`
  anchors them to a promoted record and hashes the bits underneath; the rewrite
  was verified bit-for-bit against the pre-deletion payload.

## 2026-09-12: NOOBPORT per-block depth, same fixed slot

The [second graphics prototype](graphics_opportunities/NOOBPORT_PROTOTYPE.md)
gives `data/NOOBPORT.LOD` a `PPP>` per block instead of one for the file. The
vortex (`NOOBPORTAL1-12`, NBPORTL_P, indices reach 31) and the blast
(`NOOBAIRGUNK3-8`, NOOBGUK_P, indices reach 30) pack at 5bpp; Noob's own cast
strips (`NSPORTALSHOT1-3` A/B) are held at 6 by an explicit `PPP> 6` because
they are FIGHTER art in an effect-named sidecar and the CPU shadow reader's
ownership of a fighter record is not established. All authored indices,
anchors, palette references and animation tables are preserved. MAME passed
the move rig and a new packing observer together.

| Slot | Bank | Fixed range | Payload | Remaining reserved capacity |
| --- | ---: | --- | ---: | ---: |
| NOOBPORT | 0 | `0x796000..0x7A6000` | **50,778** | **14,758** |

**7,774 bytes recovered inside this slot** (58,552 -> 50,778); its boundaries
and neighboring owners do not change and nothing has been moved into the
recovered run. The complete IRW file is 50,846 bytes, down from 58,620.

The six body strips would screen as a further 3,320 bytes at 4bpp and are
deliberately NOT taken - see the prototype note. FBNeo/Fightcade and
physical-board validation remain outstanding.

## 2026-09-12: BLDXPD per-frame depth, same fixed slot

The [first graphics prototype](graphics_opportunities/BLDXPD_PROTOTYPE.md)
changes BLDXPD from uniform 4bpp to 4/3/2/1bpp through LOAD2's `PPP> 0`
max-index packing. All authored indices, anchors, palette references and
runtime frame durations are preserved. MAME passed both orientations.

| Slot | Bank | Fixed range | Payload | Remaining reserved capacity |
| --- | ---: | --- | ---: | ---: |
| BLDXPD | 1 | `0xBCD600..0xBDD600` | **46,142** | **19,394** |

The payload ends at `0xBD8A3E`. **17,054 bytes recovered inside this slot**;
its boundaries and neighboring owners do not change. The earlier 63,264-byte
figure below was the complete IRW file: the original payload was 63,196
bytes after removing the 68-byte header. The new complete IRW is 46,210 bytes.

FBNeo/Fightcade and physical-board validation remain outstanding.

## 2026-09-10: BLDXPD - UMK3's exploding-body blood burst, bank 1

`BLDXPD1-13`: the blood UMK3 throws when a body explodes (`stand_blood_explode`
-> `cbx3`, MKFX.C), three of which Ermac's telekinetic slam fatality now fires.
Decoded 1:1 out of `C:/MAME/roms/umk3.zip` into `data/BLDXPD.IMG` by
`tools/make_bldxpd_img.py`, which Phase D re-runs with `--check`. It replaced
`MKSPLASH1-4`, a drawn stand-in that briefly held a 12,288-byte `BLDSPLSH` slot
at `0xBDA600` - that slot and its LOD are gone. See
`doc/UMK3_ERMAC_TELESLAM.md` "The three splats".

**Sized off a measured pack, not off the pixels.** The 13 frames are the
arcade's left/right multipart pairs composited into one image each: 230,258
pixels, 115,129 bytes at 4bpp. LOAD2's zero-compression takes that to a
**63,264-byte IRW** - blood bursts are mostly transparent and the late frames
are sparse specks. A first pack in a provisional 128KB slot is what measured
it; the slot was then cut to 64KB and the other 64KB handed back.

**4bpp, not the arcade's 6.** Every frame tops out at colour index 13 of a
14-entry palette, so `PPP> 4` is lossless and a third cheaper than the ROM's
own depth. `PPP>` is the depth LOAD2 packs at - `MOVEART2`'s `PPP> 6` is why
the stand-in packed at 6.

Taken hard **UNDER** `ROBOFIRE`'s `0xBDD600` base, at the top of what is left
of the post-MK7MIL run - the rule `ERMFIRE` and `HICLOUD` follow - so MK7MIL
keeps the rest to grow into and no existing sidecar moves. **Bank 1 is correct
here**: only BODY frames need bank 0, because `shadow_p1p2` walks them with a
CPU read that has no video-ROM bank select. Blood casts no shadow.

**A palette came with it.** `BLDXPD_P`, the arcade's 14 colours padded to 16,
hand-added to `src/IMGPAL6.ASM` - nothing in the build promotes an IMG
palette. It replaced the stand-in's `BLSPLSH_P`. The LOD is `PON>` because
these are standalone `gso_dmawnz` objects, which need a palette-bearing record
to bootstrap from.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **BLDXPD** | 1 | `0xBCD600..0xBDD600` | 65,536 | **63,264** |

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **post-MK7MIL run** | 1 | `0xB953E6..0xBCD600` | **229,914** (295,450 before this) |

## 2026-09-07: CAVEYES - 12 bytes off SAHELI3's tail

`CAVEYE1-6` out of `data/CAVEYES.IMG`: the six one-pixel-tall slivers MK1
blinks in GORO'S LAIR's dark archways, which MK2 shipped without. The art is in
**neither** leak - it is MK1's, read back out of `C:\MAME\roms\mk.zip` by
`tools/make_caveyes_img.py`, which is now the source of truth for the frames
and the palette. See `doc/GOROS_LAIR_EYES.md`.

Taken off the **TOP** of SAHELI3's slot, the same rule BOSSHAM, RNVIC7,
NOOBPORT, MTOPFLR, TIMEFLR and RAIN all used, so the dive tumble below keeps
its `0x02FE0000` base and nothing else moves.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **SAHELI3** | 1 | `0x9FC000..0x9FFE00` | 15,872 | 9,456 |
| **CAVEYES** | 1 | `0x9FFE00..0xA00000` | 512 | **12** |

Twelve bytes is not a typo. The whole animation is 46 pixels at `PPP> 2` -
`CAVEYE_P` is four entries and the art indexes all four, so two bits is exact
rather than a trim (MK1 spent six only because its whole dungeon LOD was 6bpp).
The payload is **frozen**: these are MK1's records transcribed, not art that is
going to grow. Its own sidecar rather than records added to `SAHELI3.LOD`
(`PPP> 6`) because a mixed-depth LOD is what garbled SONICCLAP.

Bank 1 with the rest of the stage - MK1CAVE's own wall blocks live in MK7MIL.
Safe because nothing walks this art with the CPU: DMA-drawn off its own
background list, casts no shadow, never a movie frame.

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **SAHELI3** | 1 | `0x9FE4F0..0x9FFE00` | **6,416** (was 6,928) |

**Costs ten permanent display objects** on a new list, `cave_eyes_lst`, drawn
immediately after `baklst6` in `dlists_cave`. Measured in MAME against the
built ROM: `peak_overload` stays at 2 and `qdma_drops` at 0 across the stage -
ten 10x1 blits are free.

## 2026-09-01: HICLOUD - THE TOWER's high clouds, 7,038 bytes in bank 1

`CLOUD2` (209x38) and `CLOUD3` (96x15) out of `data/CASTLE.IMG`: the two flat
sky shapes that sit above the stock drifting cloud row. Midway drew them and
packed them nowhere - neither label is defined by any `.TBL` in the tree, so
`tower_mod`'s sky has only `cloud1a-d`.

**No palette was added.** CASTLE.IMG's `CLOUD` palette is byte-identical to
`newcld_p` (all 63 entries), which `cloud1a` already binds and which is already
in the program ROM. The LOD is `POF>`, and `tower_high_cloud_proc` creates each
object from `cloud1a` and swaps the image with `ani_flag` - the same thing
`get_a8_to_a11` does for `cloud1b-d`.

Its own sidecar rather than records added to `MK6MIL.LOD` next to `cloud1a-d`,
where they belong by subject: MK6MIL's payload ends at `0x9F6AA0` and MKSOUL1
is based at `0x9F7000`, so that slot has 1,376 bytes of headroom against the
7,038 these pack to. Adding them there overlapped MKSOUL1 by 5,730 bytes and
`makevrom.py` refused the write. This is the bank-1 run above MK7MIL's tail.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **HICLOUD** | 1 | `0xBD0000..0xBD2000` | 8,192 | **7,038** |

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **post-MK7MIL run** | 1 | `0xBD2000..0xBF1000` | **126,976** (was 138,646) |

**Costs two permanent display objects**, both on `baklst2`, which `tower_mod`
previously skipped. `dlists_tower` draws `baklst2` first so they stay behind
the wall and the stock cloud rows; `tower_scroll` row 2 is `010000h`, slower
than the `014000h` the stock rows use, so they read as further away.

Verified in MAME against the built ROM: `baklst2` holds exactly two objects,
`209x38 @ y=12` and `96x15 @ y=31`, `pal=0404` (the same palette register the
stock clouds report), drifting 158px and 70px over the same interval - a 2.26
ratio against the 2.25 the two velocities set. Clearing `baklst2` mid-fight
removes a flat cloud band from the rendered frame.

## 2026-09-01: RAIN - 276 bytes off MTOPFLR's tail

`DROP1-4` and `DROPHIT1-2` out of `data/RAIN.IMG`: MK3's six MKRAIN.TBL
records, rebuilt from pixels read back out of a UMK3 ROM set by
`tools/make_rain_img.py`. The art is in **neither** leak - MK3's own LOD names
`c:\video\supermk3\img\RAIN.IMG`, which is not in the archive, and MK3's rain
code is commented out. See `doc/CUSTOM_CONTENT.md`.

Taken off the **TOP** of MTOPFLR's slot, the same rule BOSSHAM, RNVIC7,
NOOBPORT, MTOPFLR and TIMEFLR all used on the staged UMK3FIRE run, so the floor
below keeps its `0x05C88000` base and nothing else moves.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **MTOPFLR** | 0 | `0x791000..0x79B800` | 42,496 | 36,176 |
| **RAIN** | 0 | `0x79B800..0x79C000` | 2,048 | **276** |

The payload is **frozen**: these are MK3's frames transcribed, not art that is
going to grow. `PPP> 3` - `DROPS` is eight entries and the art indexes all
eight, so three bits is exact rather than a trim. Its own sidecar rather than
records added to `MTOPFLR.LOD` (`PPP> 6`) because a mixed-depth LOD is what
garbled SONICCLAP.

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **MTOPFLR** | 0 | `0x799D50..0x79B800` | **6,832** (was 8,880) |

**What it really costs is objects, not bytes.** 24 permanent display objects on
top of the 84 the floor already holds. `objs_free_min` is **228** with the
storm running, against the 252 `doc`'s 2026-08-19 entry recorded for the floor
alone. `peak_overload` **2** and `qdma_drops` **0** across a whole round, so it
is free in frame time - but the pool is the budget on this stage, and
`object_setup` calls `ermac 5` (a hang) when `getobj` comes back empty.
`peak_rain` takes all 24 at once behind `objs_available` for that reason.

## 2026-08-24: BIGGORO retired - 139,286 bytes, the largest run in the build

`biggoro1a..biggoro5e` + `goroyell1/2` (17 frames, 138,991 bytes at 8 bpp) is
the MK1-style looming-Kintaro intro art out of `BIGGORO.IMG`. It was loaded
into bank 1 by `data/MK7MIL.LOD` on every build and **never drawn**. Three
independent confirmations before removal:

1. The labels appear in exactly two places in the tree - their own definitions
   in `src/MKHUGE.TBL` and the `--->` export list in `MK7MIL.LOD`. No ASM
   reference of any kind.
2. **No `.ASM` file includes `MKHUGE.TBL` at all**, so the records were never
   even linked into the program ROM. Nothing *could* reference them.
3. `lggoro_p` (`IMGPAL7.ASM`) is used only by that table, i.e. it is already
   dead program-ROM data too. Left in place - stock file, program ROM is not
   scarce.

Removed the whole block from `MK7MIL.LOD` (lines 161-173) and deleted
`src/MKHUGE.TBL`. The `BBB> MKHUGE` background on line 333 is a **different**
asset and was left alone.

| | before | after |
| --- | ---: | ---: |
| bank 1 free | 29,088 | **168,080** |
| total video free | 100,968 | **239,960** |
| largest single run | 15,766 | **139,286** (bank 1, `0xbcefea`) |

### Everything after it shifted 138,991 bytes down, and the pipeline absorbed it

This is the reassuring part. Removing art from the middle of a LOD moves every
subsequent LOAD2 address, and an audit before the change found **815 inline
`.long` SAGs** inside the affected window, in four files. Every one of them has
an existing Phase B syncer:

| file | inline SAGs | syncer |
| --- | ---: | --- |
| `BGNDTBL.ASM` | 760 | Phase B2 / B2a / B2b |
| `MK1PITBG.ASM` | 52 | Phase B2c (`refresh_kfpitbg.py`) |
| `MKSEL.ASM` | 2 | Phase B2f |
| `MKFX.ASM` | 1 | Phase B1a |

All four were patched on the rebuild (`MKFX.OBJ`, `MKSEL.OBJ` and friends fell
out of Phase C0 as stale), and Phase D's re-check passed. The per-frame tables
(`MK7MIL`, `MKCHUNKS`, `MKMK3`, `MKROCKS`, `MKTC`, `MKBOLTS`, ...) are all
merge-promoted from the LOAD2 snapshot, so they self-heal. `MKFLOORS.TBL` is
the one hand-maintained table in this LOD and it sits at line 12, *above* the
removed block, so it did not move.

**Run that audit before removing anything mid-LOD.** Compute the affected SAG
window and grep `src/*.ASM` for numeric `.long` values inside it; if a file
turns up without a syncer, write one first.

Also regenerate `doc/RETIRED_RANGES.md` afterwards
(`python tools/map_retired_ranges.py --md`) - every address in it moved.

## 2026-08-19: the railings split onto two palettes

`TEEFBAC_p` (CASTLE.IMG) joins `DEATHZN_p` and `parallaxP` in
`src/IMGPAL7.ASM`. **No video ROM cost at all** - it is the same 19 strips
drawn twice, and every packed strip binds `TEEFBAC_p` through its own `PAL:L`.
The far railing keeps it; the near railing `swpal`s to `DEATHZN_p`. Program
ROM cost is one 64-word colour map, 130 bytes.

Costs one CRAM colour map, not 39: `getfpal` refcounts by palette id. The
stage now holds three of the sixteen - `0202` far, `0303` deck, `0404` near -
against a budget that wants ~10 kept free for fighters and effects.

## 2026-08-19 (later): the bridge re-cut gives 25,600 bytes back

YOTEIGAI TOR'S floor was rebuilt to reuse its art mirrored instead of packing
more of it, and to take the soulteeth subframes. **59,436 -> 36,176 bytes**,
and the slot shrank with it (`0x78A000..0x79C000` -> `0x791000..0x79C000`), so
**25,600 bytes went back to the staged UMK3FIRE run**, which is now 62,464.

| | before | after | why |
| --- | ---: | ---: | --- |
| stone deck | 37,800 (parallax1-6) | 18,900 (parallax1-3) | right half is the same three with `m_fliph` |
| railings | 21,636 (5 composites) | 15,336 (19 A..E strips) | each strip is cropped to its own tooth |
| | **59,436** | **34,236** | |

**A mirrored tile's right edge is its own left edge**, which is why halving the
deck is seamless and not a compromise: `parallax1,2,3` then `3,2,1` flipped
meets perfectly at x=600. The probe measures the deck at exactly `0..1200`
with no gap or overlap, from the live objects.

Mirroring an anipoint is `anix' = xsize-anix` - the rule `MKUTIL`'s `an2`
applies on the ani path. `peak_calla` does it by hand because these are
single-part objects. The draw side needs nothing: `clip5` (MKDISP) already
adds `xsize-1` to a flipped object's coordinate, so `oxpos` stays the LEFT
edge whether the piece is mirrored or not.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **MTOPFLR** | 0 | `0x791000..0x79C000` | 45,056 | 36,176 |
| **UMK3FIRE** (staged) | 0 | `0x781C00..0x791000` | 62,464 | - |

**What it costs instead: objects.** Strips mean 39 pieces per railing rather
than 10, and this stage hand-inserts every piece into a background list where
it is never culled - stock stages get their tiles from a BMOD plane, and
`disp_mod` only inserts blocks that are actually on screen. The floor is now
**84 permanent objects** out of a 358 pool. Measured with the probe's new
`objs_free_min`: 320 free before the re-cut, **252 after**, in a quiet scene.
That is comfortable but it is no longer free, and `object_setup` calls
`ermac 5` when `getobj` comes back empty.

`teethflip1` (CASTLE.IMG) is packed by nothing and should stay that way. It is
`soulteeth2` mirrored pixel for pixel; the only thing it carries that no other
record does is `aniy -75` against the soulteeth' `-113`. That 38px is the lift
of the far railing and cannot be derived from the near one - `peak_calla`
mirrors the real strips and drops the anchor by it.

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **JADERANG** | 0 | `0x78626A..0x791000` | **44,438** (was 15,766) |
| **MTOPFLR** | 0 | `0x799D50..0x79C000` | **8,880** |

- **Total unclaimed: 155,740 bytes** (bank 0: 100,278 / bank 1: 55,462).
- **Largest contiguous: 44,438**, then the bank-1 SCLAP tail at 25,692, then
  MKSOUL1's 20,412, then JADVIC's 12,014.

## 2026-08-19: MTOPFLR replaces BATPIT, and UMK3FIRE pays for it

YOTEIGAI TOR'S floor was rebuilt from one 237x51 ledge tile into two strips,
and the sidecar was renamed with it (`battlepit` is no longer shipped):

| | |
| --- | ---: |
| `parallax1-6` (MKFLOORS.IMG) - six 200x42 slices of one 1200-wide stone plane | 37,800 |
| `soulteeth1-5` (CASTLE.IMG) - the bone teeth in front of it | 21,636 |
| | **59,436** |

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **MTOPFLR** | 0 | `0x78A000..0x79C000` | 73,728 | 59,436 |
| **UMK3FIRE** (staged) | 0 | `0x781C00..0x78A000` | 34,304 | - |

**This is the raid that actually hurts.** It is the fifth time the staged
UMK3FIRE run has been carved from the top (BOSSHAM 64KB, RNVIC7 8KB, NOOBPORT
56KB, BATPIT 16KB), and as always the space came off the high end so
UMK3FIRE's `0x05C0E000` base never moved. But it is now down to **34,304 bytes
against the 140,160 its art packs to** - it was already short at 91,136; it is
now short by a factor of four. Shipping Scorpion's UMK3 flame fatality needs
either the multipart re-cut that was always the plan (the same re-cut took
SHAOFIST from 56,240 to 26,664) or a different home entirely.

It was still the only choice. A 58KB payload does not fit anywhere else in
either bank: the next largest runs were the bank-1 SCLAP tail at 25,692 and
the MKSOUL1 tail at 20,412, and splitting a stage floor across two banks to
chase them would be worse than the trade.

**One LOD for two IMG files**, which is only safe because both palettes were
already 6bpp - `parallaxP` is 58 entries and `DEATHZN_p` 62. A mixed-depth
sidecar is what garbled SONICCLAP.

The six `parallax` slices do not compress at all (control word `06000h`): each
one fills its own 200x42 bounding box completely, so there are no leading or
trailing transparent runs for `ZON>` to skip. Budget art like that as
`w * h * bpp / 8` flat. The teeth do compress - they are mostly empty above
their own ground line - and come in at 21,636 against a 25,300 raw figure.

`MKFLOORS.IMG` also holds `parallax`, the same art as a single 1200x42 record.
Not packed: at 6bpp that is one 37,800-byte block against LOAD2's 65,500
`MAXDATA`, so it would fit, but it buys nothing and the six slices are what
carry the positional anipoints.

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **JADERANG** | 0 | `0x78626A..0x78A000` | **15,766** (was 73,110) |
| **MTOPFLR** | 0 | `0x79882C..0x79C000` | **14,292** |

- **Total unclaimed: 130,140 bytes** (bank 0: 74,678 / bank 1: 55,462).
- **Largest contiguous: 25,692** (bank 1, the SCLAP tail), then 20,412
  (bank-1 MKSOUL1), then 15,766, then 14,292, then 12,014.
- Bank 0 no longer has a single run over 16KB. The next sizeable asset needs
  either bank 1, a re-pack, or a reclaim.

## 2026-08-18: BATPIT takes 16KB off the staged UMK3FIRE run

MOUNTAIN TOP's floor tile - `battlepit` out of `MKFLOORS.IMG`, the
237x51 spiked stone ledge `peak_calla` (BGND.ASM) lays seven times across the
stage - needed **8,958 bytes**. Carved off the **TOP** of the staged UMK3FIRE
run, the fourth time that run has been used this way (BOSSHAM 64KB, RNVIC7
8KB, NOOBPORT 56KB), so UMK3FIRE keeps its `0x05C0E000` base untouched.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **BATPIT** | 0 | `0x798000..0x79C000` | 16,384 | 8,958 |
| **UMK3FIRE** (staged) | 0 | `0x781C00..0x798000` | 91,136 | - |

**This is the cheapest a stage floor has ever been, and the reason is worth
keeping.** Every other entry in `MKFLOORS.IMG` is one sixth of a 1200-wide
skew strip - the six `BATGRND*`/`CASFLOOR*`/`FORFLOR*`/... sets each sum to
exactly 1200 - which `floor_code` DMAs line by line out of a `FL_*.BIN` raw.
Built that way this floor would have been `1200 * 51 * 6/8` = **45,900 bytes**,
five times what it cost as an ordinary tiled image.

Two things made the image form the right call rather than just the cheap one:

- **`battlepit` has real transparency.** Rows 0..7 are open sky with four
  spike tips through them. `floor_code` has no transparency at all - it would
  have painted those rows solid palette-0, a black bar across the screen above
  the ledge.
- **It is a single tile, not a strip.** Nothing about it wants the skew
  renderer's perspective; a mountaintop ledge is flat. Pit Bottom
  (`mk1pit_mod`) already ships with no skew floor, so the precedent was there.

`PPP> 6` is lossless here only because `BATTPIT_p` was folded from 65 entries
to 64 first. It was the only 7bpp palette record in the file; entry 64 was
RGB(11,14,16) against entry 63's RGB(10,13,15) - squared distance 3 - and
covered 78 pixels. `data/MKFLOORS.IMG.prebatpit` is the pre-fold copy.

`PON>`, unlike the `POF>` sidecars around it. `object_setup` (MKUTIL.ASM) does
a `getfpal` on `*a5(icmap)` at bit offset 70h, and a `POF>` record leaves that
field reading whatever follows it in the link. The MKZAP/NOOBFX sidecars get
away with it because they fix `opal` up afterwards and because a multi-record
table at least reads its own neighbour; a **one-record** table has no next
record at all, so the binding has to be real. `BATTPIT_p` is `.global` in
`src/IMGPAL7.ASM` - spelled `_p`, not `_P`, because LOAD2 copies a palette
label verbatim out of the IMG's palette record.

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **JADERANG** | 0 | `0x78626A..0x798000` | **73,110** (was 89,494) |
| **BATPIT** | 0 | `0x79A2FE..0x79C000` | **7,426** |

- **Total unclaimed: 188,108 bytes** (bank 0: 132,646 / bank 1: 55,462).
- **Largest contiguous: 73,110**, then the bank-1 SCLAP tail at 25,692, then
  the bank-1 MKSOUL1 tail at 20,412, then the JADVIC tail at 12,014.

## 2026-08-18: NOOBPORT takes 56KB off the staged UMK3FIRE run

Noob Saibot's shadow portal (`NOOBPORTAL1-12` from `NOOB.IMG`, the vortex that
opens under the opponent on D,D+LK, plus `NSPORTALSHOT1-3` as A/B strips,
which is Noob's own body casting it) needed **48,882 bytes** and there was
nowhere else to put it. Carved off the **TOP** of the staged UMK3FIRE run, the
third time that run has been used this way (BOSSHAM took 64KB, RNVIC7 8KB), so
UMK3FIRE keeps its `0x05C0E000` base untouched.

| Slot | Bank | Range | Bytes | Used |
| --- | ---: | --- | ---: | ---: |
| **NOOBPORT** | 0 | `0x79C000..0x7AA000` | 57,344 | 48,882 |
| **UMK3FIRE** (staged) | 0 | `0x781C00..0x79C000` | 107,520 | - |

**This one costs the staged reserve real ground, unlike the other two.**
UMK3FIRE's art currently packs to 140,160 and it now has 107,520 (the slot was
grown once, `0x7A0000` -> `0x79C000`, to take the cast frames as well). That is a
deliberate trade, not an oversight:

- NOOBPORT fits in **no other free run in either bank**. The next largest holes
  are the bank-1 MKSOUL1 tail at 20,412 and the JADVIC tail at 12,014.
- UMK3FIRE is staged, not shipped (`umk3_burn_enable` is 0 and its IRW is not
  in `makevrom.py`'s `irw_files`), and its frames were already being re-cut.
- Re-cutting composites as multipart strips is what was always going to close
  that gap - the same re-cut took SHAOFIST from 56,240 bytes to 26,664, a 53%
  saving. 140,160 -> under 124,928 is a 11% saving by comparison.

The portal art itself cannot be shrunk the easy way: it is `PPP> 6` because
`NBPORTL_P` is a 32-entry ramp the art uses in full, and the vortex fills its
own bounding box on nearly every row, so zero compression saves almost nothing
(38,604 actual against a 38,201-byte span-pixel prediction on the first cut).
Budget art like this as `span pixels * bpp / 8`, not as a fraction of it.
The frames were re-cropped twice after that and the payload walked down to
37,902 - `python makevrom.py` prints the live figure, do not trust this one
after any IMG edit.

Revised free map, changed rows only:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **GOROWALK** | 0 | `0x781A4E..0x79C000` | **108,466** (was 173,490) |
| **NOOBPORT** | 0 | `0x7A7EF2..0x7AA000` | **8,462** |

- **Total unclaimed: 189,654 bytes** (bank 0: 157,350 / bank 1: 32,304).
- **Largest contiguous: 108,466**, then the bank-1 MKSOUL1 tail at 20,412,
  then the JADVIC tail at 12,014, then BOSSHAM's 10,488, then this 8,462.


## 2026-08-13: BGHAMMERTOP joins BOSSHAM (over-the-top hammer)

Shao Kahn's second hammer swing - `BGHAMMERTOP1-6` from the same
`BOSS8.IMG`, twelve A/B strips, the fighting move that leaves the victim
dizzy (`kahn_hammer_top`, MKBOSS.ASM) - went into the **existing BOSSHAM
sidecar** rather than taking a slot of its own. Same IMG, same A/B cut,
same `BGPAL1_P`, and the slot had the room.

`BOSSHAM.IRW` **25,574 -> 55,048 bytes** in its unchanged 65,536-byte slot
at `0x7AC000..0x7BC000`. No base moved and no other payload was touched.

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **GOROWALK** | 0 | `0x781A4E..0x7AC000` | **173,490** (unchanged) |
| **BOSSHAM** | 0 | `0x7B9748..0x7BC000` | **10,488** (was 39,962) |

- **Total unclaimed: 246,236 bytes** (bank 0: 213,932 / bank 1: 32,304).
- **Largest contiguous: 173,490**, then the bank-1 MKSOUL1 tail at 20,412,
  then this 10,488.
- The BOSSHAM tail is now small enough that a third animation there needs
  measuring first: `dosbox_bossham.conf` runs LOAD2 over that one LOD and
  the resulting `data/BOSSHAM.IRW` size is the answer, without a full
  Phase A. `FLAPJACK`'s fixed `0x7BC000` base is the hard ceiling.

## 2026-08-12: BOSSHAM takes the top of the big run

Shao Kahn's hammer-smash fatality (`data/BOSSHAM.LOD` -> `src/BOSSHAM.TBL`)
holds BGFATHAM1-7 as fourteen A/B strips plus the four single-image
BGHAMSWIPE blur frames, all from `BOSS8.IMG`. **25,574 bytes** in a
65,536-byte slot at `0x7AC000..0x7BC000`.

It was deliberately placed at the **top** of the packed region's free run,
not the bottom. The staged `UMK3FIRE` slot starts that run at `0x781C00`,
and taking the space off the high end means its `0x05C0E000` base did not
have to move - it keeps `0x781C00..0x7AC000` = 172,032 bytes against the
140,160 its art currently packs to.

As strips rather than composites: the seven composite frames are 99,103 raw
pixels, the fourteen strips are 63,269. The hammer sweeps a wide arc, so a
composite bounding box spans a lot of transparent gap that zero compression
still has to cover. Body is lane A, hammer is lane B.

No palette work was needed for the body. `BOSS8.IMG`'s `BGPAL1_P` is
byte-identical to the one in `BOSS1.IMG`/`BOSS4.IMG` that Kahn's live object
already carries, so the swing draws in his normal colours. Only the blur
overlay swaps a palette (`BGHAMSWIP_P`, IMGPAL5.ASM, 12 colours), and it is
kept at PPP> 6 with the body rather than dropped to 4bpp - a mixed-depth
sidecar is what garbled SONICCLAP, and 4bpp would have saved ~600 bytes.

Revised free map:

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **GOROWALK** | 0 | `0x781A4E..0x7AC000` | **173,490** |
| **BOSSHAM** | 0 | `0x7B23E6..0x7BC000` | **39,962** |

- **Total unclaimed: 275,710 bytes** (bank 0: 243,406 / bank 1: 32,304).
- **Largest contiguous: 173,490** (was 239,026), then 39,962, then the
  bank-1 MKSOUL1 tail at 20,412.

Every other row in the table below is unchanged.

## Verified free map (2026-08-11, after the ENDING REMOVAL + bank-0 re-pack)

Regenerated directly from a fresh `python makevrom.py` run. **Trust this
section over the older tables below.** Each row is the hole between one
payload's real end and whatever is based next; "after" names the payload
below the hole.

| Gap (after) | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| MK2MIL | 0 | `0x1FFF40..0x200000` | 192 |
| MK3MIL | 0 | `0x400690..0x400800` | 368 |
| VSSMMOV | 0 | `0x403C18..0x404000` | 1,000 |
| MK4MIL | 0 | `0x6056BE..0x606000` | 2,370 |
| MK5MIL | 0 | `0x736F80..0x738000` | 4,224 |
| SZSPINE | 0 | `0x7391F2..0x739200` | 14 |
| MOVEART2 | 0 | `0x73CC90..0x73CE00` | 368 |
| MOVEART1 | 0 | `0x7525C8..0x752600` | 56 |
| SHAOSIT | 0 | `0x75ABAE..0x75AC00` | 82 |
| VSJDMOV | 0 | `0x75EAAA..0x75EC00` | 342 |
| JXAIRPRO | 0 | `0x762516..0x762600` | 234 |
| NOOBFX | 0 | `0x7656E2..0x765800` | 286 |
| VSNBMOV | 0 | `0x768AA6..0x768C00` | 346 |
| KITSPIN | 0 | `0x76D93C..0x76DA00` | 196 |
| MK1SKULL | 0 | `0x778A8A..0x778C00` | 374 |
| **GOROWALK** | 0 | `0x781A4E..0x7BC000` | **239,026** |
| FLAPJACK | 0 | `0x7EE2C0..0x7F0000` | 7,488 |
| JADVIC | 0 | `0x7FD112..0x800000` | 12,014 |
| MK6MIL | 1 | `0x9F6AA0..0x9F7000` | 1,376 |
| **MKSOUL1** | 1 | `0x9FB044..0xA00000` | **20,412** |
| MK7MIL | 1 | `0xBF0EDA..0xBF1000` | 294 |
| SCLAP | 1 | `0xBF2D80..0xBF4000` | 4,736 |
| JADERANG | 1 | `0xBF826A..0xBF8400` | 406 |
| SHAOFIST | 1 | `0xBFEC28..0xC00000` | 5,080 |

- **Total unclaimed: 301,284 bytes** (bank 0: 268,980 / bank 1: 32,304).
- **Largest contiguous: 239,026 bytes** (bank 0, the packed region's tail),
  then 20,412 (bank 1, MKSOUL1 tail), 12,014 (JADVIC tail),
  7,488 (FLAPJACK tail), 5,080 (bank-1 SHAOFIST tail).
- Top three holes hold **271,452** bytes.

### All 12 character endings retired (2026-08-11)

Every character's ending was two movie frames (V then H), played by
`show_a0_ending` at `zipped_pics` `2*ochar+10h`. All 24 are gone, along with
~580 lines of ending story text. This is the single biggest reclaim in the
project's history:

| | | |
| --- | ---: | --- |
| video ROM | **166,876** | 10 frames that sat at MK5MIL's tail |
| program ROM (REVX) | **195,330** | 14 frames; the pool went 348,528 -> 153,198 |
| program ROM (`.text`) | **7,424** | `end_text_1`/`end_text_2` + `pf_*_end_*` |
| | **369,630** | |

The H/V split across the two ROMs was historical accident, not design - only
Reptile, Scorpion, Shang Tsung and Sub-Zero had both frames in video ROM, and
six characters were entirely in program ROM. That is why the cut had to be all
or nothing per character.

What changed, and the one thing that can bite:

- `show_a0_ending` (UNZIP.ASM) is a **stub `retp`**, exactly like `show_rev_x`
  and `show_dcs_logo` above it. Both callers - `congrats` (MKEND.ASM) and the
  service-menu viewer (DIAGMENU.ASM) - now fall straight through to the cast of
  characters. Tower completion is otherwise unchanged.
- The `10h..27h` ending block is gone from `zipped_pics`, so **the three
  appended VS portraits moved down 24 slots**: `vs_pic_noob` / `vs_pic_jade` /
  `vs_pic_smoke` in MKSEL.ASM went `28h/29h/2ah` -> `10h/11h/12h`. Nothing
  checks that those equates match the table, and a wrong slot does not draw a
  wrong picture - it hangs gstate 0dh. All three were snapshot-verified.
- `promote_tbls.py` **preserves src-only labels**, so the 24 dead `END_* .set`
  equates survived in `src/MKZIP.TBL` / `src/MK8ZIP.TBL` aliasing their
  neighbours' addresses even though LOAD2 had stopped emitting them. Deleted by
  hand. `verify_movies.py` is what caught it.
- `KINT` and `ABACKA-D` stay: they are the Kintaro frame and the attract-mode
  backgrounds, not endings.

`data/END_*.BIN` remain on disk, so this is reversible.

**2026-10-11: back on the WOLF build only** - `data/ENDWOLF.LOD`, image bank 2
(linear `1480000h`, 362,206 bytes), with the text under `.if wunit`.  The
T-unit is unchanged: still retired, nothing reclaimed comes back.  See
doc/WOLF_UNIT.md "The character endings are back on Wolf".

### The bank-0 sidecar pack (2026-08-10, re-run 2026-08-11)

Packing creates no space - it moves the same free bytes somewhere spendable.
Before the pack the largest run was 26,346 bytes, so a 40KB asset fit nowhere
despite there being room for four of them. After it, 75,186. After the ending
removal let the whole pack slide down into MK5MIL's vacated tail, **239,026**.

The region start is **derived, not hardcoded**: `pack_bank0_sidecars.py` reads
MK5MIL's real payload end and begins 4KB above it, so the next payload change
below needs no edit there.

Eleven sidecars (`SZSPINE`, `MOVEART2`, `MOVEART1`, `SHAOSIT`, `VSJDMOV`,
`JXAIRPRO`, `NOOBFX`, `VSNBMOV`, `KITSPIN`, `MK1SKULL`, `GOROWALK`) sit tight
on 512-byte boundaries just above their neighbour's real payload end, from
`0x738000` up. Guards run 14-434 bytes; anything that needs to grow re-packs
rather than eating a neighbour. No art changed, only base addresses.

`FLAPJACK` (205,504 bytes at a fixed `0x7BC000`) and `JADVIC` above it are left
alone deliberately: moving the stage background would fold its 7,488-byte tail
and JADVIC's 12,014 into the run, but costs a re-verify of a whole stage.

Re-run with `python tools/pack_bank0_sidecars.py` (`--apply` rewrites the LOD
`***>` lines and prints the matching `CUSTOM_VIDEO_SLOTS` entries), then LOAD2
+ `promote_tbls` + `makevrom`.

**Two traps this pass exposed, both now guarded:**

- `promote_tbls.py` never promoted `.set`-only tables, because it matches
  records by a label with a trailing colon. `VSNBZIP.TBL` / `VSJDZIP.TBL` /
  `VSSMZIP.TBL` - each one line, holding a **movie frame's** address - had
  therefore reported "ok" no matter how stale they were, and rebasing a VS
  portrait would have silently pointed it at whatever moved in underneath.
  A wrong movie address does not draw a wrong picture; it hangs gstate 0dh.
  All three are in `SET_EQUATE_TABLES` now.
- Nothing checked promoted tables *against* the payloads they address.
  `tools/check_sag_coverage.py` does, and `build.py` Phase D runs it: every
  exported SAG must land inside its own sidecar's payload (8,974 of them
  today). It caught `data/UMK3FIRE.LOD` still sitting on a base the pack had
  since handed to `MK1SKULL`.

Verified after the 2026-08-11 re-pack: full build + both ROM capacity checks,
`check_sag_coverage` (~9,000 SAGs), `verify_movies.py` (all 20 surviving frames
byte-exact), and in MAME all three hidden fighters' VS portraits at their new
`10h/11h/12h` slots, Noob's shadow moves, and the MK1 scortch fatality
(`mk1_fire1_6_skel1_8_handoff_zorder`, zorder 9/0).

### Strips beat composites, by a lot (SHAOFIST, 2026-08-10)

> **2026-09-28: the burst is no longer drawn.** `kfistpulp .set 0`
> (MAINEQU.ASM) put Shao Kahn's Portal Punch fatality back on `r_burst_pop`
> - the body explodes - with Ermac's three `BLDXPD` splats aimed at his
> knuckles instead.
>
> **2026-09-29: RECLAIMED, 20,236 bytes of bank 1.** The prediction in this
> box said 26,664 and that was stale by two weeks - the 2026-09-15 re-cut to
> `PPP> 5` had already taken it to **20,236**, measured off `python
> makevrom.py`, not estimated. Removed: `data/SHAOFIST.LOD` and its
> `data/IMGBUILD.BAT` step, the bank/slot/`irw_files` entries in
> `makevrom.py`, `src/SHAOFIST.TBL` (and its `promote_tbls`,
> `check_lod_packing`, `audit_sprite_bpp` and Phase D anipoint-check
> registrations), the `a_sk_fistpulp` lane and `FISTPULP4W_MIRROR` in
> MKSK.ASM (+ its `sync_inline_sags` anchor), `FISTPULP_P` in IMGPAL5.ASM,
> its `.globl` in IMGTBL.GLO and its `death_fade_excludes` row in MKGUYS.ASM.
> `sk_anitab2[c]` takes `kahn_dummy`, the same filler the retired SPEAR row
> uses. The `kfistpulp 1` DRIVER in MKZAP.ASM is untouched and there is now an
> `.emsg` on the switch, so turning it back on fails the build instead of
> assembling against records that are not there. `data/SHAOFIST.IMG` is KEPT -
> it costs no ROM and it is the restore path, which is now a full Phase A run.
>
> It gave back a clean **20,250-byte hole at `0xBF73C6..0xBFC2E0`** (MK1PSK1
> kept its `0xBFC2E0` base - nothing was relocated), which is the largest
> single run in bank 1. The measurement below is kept because it is the
> general lesson, not because the art is live.

`FISTPULP1-10` - the blood burst that replaced `r_burst_pop` at the end of
Shao Kahn's Portal Punch fatality - shipped first as **ten composite frames,
116,722 raw pixels, 56,240 bytes packed at PPP> 6**. That was bigger than any
free run in the ROM, so it went out split across three tails as `SHAOFIST` +
`SHAOFIS2` + `SHAOFIS3`, and it took the ROM's largest contiguous run down to
14,796 bytes.

Re-cut as **149 multipart strips the same art is 48,097 raw pixels and 26,664
bytes** - 53% smaller. It now fits the 31,232-byte JADERANG tail on its own;
`SHAOFIS2` and `SHAOFIS3` are retired and the JXAIRPRO and MKSOUL1 tails went
back to their owners. Rendering is unchanged: a frame-by-frame MAME diff of
the two builds is pixel-identical except at animation-frame boundaries.

**Why strips win here and did not for MK1SKULL.** Zero compression collapses
runs of transparent pixels but cannot reclaim a gap the bounding box still
has to cover, and this burst is mostly gap - falling arcs with air between
them. `MK1SKULL`'s flame/skeleton art is solid, so trimming gained less than
the extra 68-byte record headers cost (14 composites 44,340 bytes vs 28
strips 44,774). Judge it per asset: **the test is how much of the bounding
box is empty**, not whether strips are "better".

**The cost is a piece-count ceiling.** A multipart object's shape RAM is one
process block (`pdata`..`prcsiz` = 1520 bits, 112 bits a piece), so **13
pieces is the hard maximum** and the longest shape list in the whole shipped
game is 8. These frames run 3,7,11,17,22,24,22,16,14,13, so seven of ten
would overrun into the next process block. `MKZAP.ASM` therefore points the
burst overlay's `oimg` at `fistpulp_mpram`, a dedicated `.bss` buffer, and
does not call `gmo_proc`. Any future strip-cut asset has to either stay under
13 pieces a frame or do the same.

### Historical: the map this section replaced (2026-07-31)

The rows below predate `VSJDMOV`/`JXAIRPRO`/`SHAOFIS*` claiming their slots
and are kept only to explain the older prose in this file. Do not allocate
against them.

| Gap | Bank | Range | Bytes |
| --- | ---: | --- | ---: |
| **SHAOSIT tail + retired JADVIC1 slot** | 0 | `0x7885AE..0x790000` | **31,314** |
| **Reclaimed STGORO slot** (Goro reveal removed 2026-08-05) | 0 | `0x790000..0x797000` | **28,672** |
| VSNBMOV tail | 0 | `0x79B466..0x7A0000` | 19,354 |
| MKSOUL1 tail | 1 | `0x9FB3E2..0xA00000` | 19,486 |
| JADERANG tail | 1 | `0xBF826A..0xC00000` | 32,150 |

- Total unclaimed then: 187,064 bytes (bank 0: 128,982 / bank 1: 58,082).
  Down 17,378 on 2026-08-03: `MKSOUL1` (`0x9F7000`, slot to `0xA00000`) took the
  head of the bank-1 MK6-to-MK7 gap for `CORPSEDROP1-8`, the drained husk
  collapsing at the end of Shang Tsung's soul suck. Bank 1 was chosen so the
  drop sits beside the rest of that fatality's art (every `*SOULSUCK*` pose and
  the `CORPSE1A` husk are MKSOUL.IMG records inside MK6MIL). 6bpp, zero
  compression on; the 8 composites are 39,412 raw pixels but pack to 17,378.
  Down a further 12,514 on 2026-08-01: `NOOBFX` took the retired VSNOOB slot for
  Noob's shadow slide/kick/teleport frames (see below).
  Down 4,368 from the 2026-07-31 figure: the reworked Jade victory art grew
  `JADVIC` from 51,456 to 55,824 bytes, then back to 53,522 once the staff
  moved to A/B strips (see below). Only the JADVIC row was
  re-measured for that edit — note that a fresh `makevrom.py` also reports
  `MK5MIL.IRW` at 1,416,028 rather than the 1,422,072 recorded below, which
  predates this change and has not been chased down here.
  The old single 36,906-byte STGORO tail is now split by `VSNBMOV` (Noob's VS
  portrait, 12,966 bytes at `0x79B400`): 17,408 free before it, 19,354 after.
- Largest contiguous then: 32,150 bytes (bank 1, JADERANG tail), then the
  31,314-byte SHAOSIT/JADVIC1 region, the 19,486-byte MKSOUL1 tail (bank 1),
  the 19,354-byte VSNBMOV tail and the 12,722-byte GOROWALK tail.
  The 38,240-byte MK6-to-MK7 gap that used to top this list is gone: MKSOUL1
  took its head on 2026-08-03 and split the remainder in two.

### The 94,208-byte JADVIC hole (fixed 2026-07-31)

`JADVIC1` (`0x789000..0x790000`, 28,672) and `JADVIC2` (`0x7F0000..0x800000`,
65,536) both built to a **68-byte header with no payload**: their LODs asked
for `JDVICTORY1A`/`1B`-style multipart strips, and `JADERANG.IMG` only ever
carried the 15 composites. LOAD2 logged `Couldn't find image [JDVICTORY1A]`
for all 30 names, skipped them and still "completed" with a byte summary, so
nothing failed the build. `MKFN.ASM` went on pointing `JDVIC1..15` at those
labels, so **Jade's victory drew unwritten ROM** while 94,208 bytes of bank-0
slot sat reserved for art that was not there.

Fixed by consolidating both slots into a single `data/JADVIC.LOD` that loads
the composites. Measured payload: **51,456 bytes**, so all 15 frames fit the
`0x7F0000` slot with 14,080 to spare and the entire `JADVIC1` range is
released. `MKFN.ASM` now plays them as single-record ani2 rows
(`JDVIC1 .long JDVICTORY1,0`). Verified in MAME via
`tools/run_jade_victory_test.ps1` — all 15 stages in order at the 6-tick
cadence, and the snapshots show Jade, not garbage.

**How it happened:** the strips were real once. Both
`data/JADERANG.IMG.bak_preanipt` (2026-07-20 11:48) and
`.bak_preanix2fix` (2026-07-20 21:10) still contain all 30 `JDVICTORY*A/*B`
records. The anipoint/anix passes that produced the current `JADERANG.IMG`
rewrote the library without them, which silently emptied both sidecars — the
LODs and `MKFN.ASM` were never touched, so nothing looked broken. Any imgtool
regeneration can drop records this way; that is what the new LOAD2 log check
is for.

Two things this cost us, worth remembering:

- `tools/check_load2_log.py` did not treat an unresolved record name or an
  empty payload as a failure. It does now, with an explicit allowlist for the
  four pre-existing holes (`UGSWORDKICK*C`, `BAR_QUAN`, the six unexported
  Dead Pool hanger bodies, `FLAPJACK/ENDMARKER`).
- `tools/jade_victory_test.lua` reported **PASS** against the broken build for
  months, because it only checks that the animation advances through the
  expected SAG addresses — which exist whether or not pixels were written
  behind them. A pointer-level harness cannot prove art; look at the snapshots.

### Possible follow-up: compacting bank 0 for one big block

**DONE, 2026-08-10.** This section proposed packing a handful of bank-0
sidecars to coalesce their tails; it was carried out across all eleven in
`0x760000..0x7BC000` and produced a single **75,186-byte** run. See "The
bank-0 sidecar pack" at the top of this file, and
`tools/pack_bank0_sidecars.py`.

What is left of the same lever, if more is ever needed:

- `FLAPJACK` (205,504 bytes, fixed `0x7BC000`) and `JADVIC` above it were
  left in place. Moving `FLAPJACK` down against the packed region would fold
  its own 7,488-byte tail and `JADVIC`'s 12,014 into the big run, taking it
  to roughly 94KB - at the cost of re-verifying a whole stage background and
  Jade's victory. Not done; the stage background is the single riskiest
  payload in the ROM to move.
- Bank 1 has never been packed: `MKSOUL1` (20,412 tail), `SCLAP` (4,736),
  `JADERANG` (406) and `SHAOFIST` (5,080) sit between the two MIL payloads
  and at the chip edge. Packing them would coalesce ~10KB of the smaller
  tails but cannot merge with `MKSOUL1`'s, which is bounded by MK7MIL's
  fixed base. Low value.

### MK1SKULL slot note

`MK1SKULL` (`0x7A4E00..0x7B0000`, 45,194 of 45,568 used) holds the MK1
scortch fatality art. It carries the **MK1FIRE composites plus the MK1SKEL
A/B strips** — mixing the two forms is deliberate, see `data/MK1SKULL.LOD`.
Note that the A/B strips did **not** save space: trimming gains were more
than cancelled by doubling the record count (14 composites packed to 44,340
bytes; 28 strips packed to 44,774). Both `KITSPIN` and `MK1SKULL` are frozen
— their few hundred spare bytes are guard rails, not budget.


Generated/verified from current `python makevrom.py` and `python makerom.py`
output after the FLAPJACK shrink, Armory MK7 in-place repair, and the
KGBLOOD-to-SHAOSIT slot handover (2026-07-14: KGBLOOD's SMGUSH pool was
unreferenced and retired; its `0x780000` slot now holds the Shao Kahn
throne stand-up frames — see `data/SHAOSIT.LOD`). Also reflects the
2026-07-14 `bosssit1/2/3` reclaim from `MK6MIL.LOD`/`MKBGANI.TBL` — those
frames were fully superseded by `SHAOSIT.LOD` and had no remaining
references, freeing ~37.5KB against the MK6/MK7 bank-1 boundary
(`0x9F6B3E` payload end vs the `0xA00000` MK7MIL start).

## Active Program-ROM Payload

| IRW | Address | Payload bytes | Notes |
| --- | ---: | ---: | --- |
| `MK8MIL.IRW` | `0xFFED0000` | 153,198 | REVX movie pool - the 12 remaining VS portraits. Rebased from `0xFFD39000` on 2026-08-24; `makerom.py` now reports **2,314 bytes free** after it, because the 210,698 that used to sit above the payload went to `.text`/`.data` instead |

The pool held 348,528 bytes until 2026-08-11, when the 14 program-ROM ending
frames were retired. What is left is VS portraits only.

**Historical - `END_MLV` was silently missing from the ROM until 2026-07-31.**
Mileena's vertical ending frame was the last entry in `MK8MIL.LOD`, and at its
original PKZIP size (10,861 bytes) it overflowed the REVX window by **87
bytes**. LOAD2 dropped it and the payload simply stopped at its start address,
so `makerom.py` reported the resulting hole — 10,774 bytes — as *free space*.
It was never free; it was where `END_MLV` belonged. Re-compressing every frame
with `tools/implode.py` shrank it to 10,331 bytes so it fitted. `zipped_pics`
index `0x1a` was reached by Mileena's ending (`2 * ft_fn2 + 0x10`), so that
screen had been drawing whatever happened to be at that address. Worth keeping
in mind as the shape of failure when a movie payload silently does not fit;
the frame itself went out with the rest of the endings.

The movie/`.BIN` format is documented in `doc/MOVIE_BIN_FORMAT.md` and there is
a working codec (`tools/implode.py`), so new movie frames *can* now be
authored. They do **not** have to go here: `MK5MIL.LOD` already packs 15 of
them into video ROM via `MKZIP.TBL`, which is usually the better slot given
REVX has only 2,468 bytes left after the active payload. That doc also records `zipped_pics` index
`0x28` (`VS_JC`) as unreachable dead weight — 13,016 bytes of REVX reclaimable
if it is ever needed.

## Active Video-ROM Payloads

`Flat end` is exclusive. Fixed-slot ranges below are inclusive.

All rows below re-measured from a fresh `python makevrom.py` run after the
2026-08-11 ending removal and bank-0 re-pack.  `UMK3FIRE.IRW` is built but
not written, so it is absent here on purpose.

| IRW | Bank | Flat start | Flat end | Payload bytes |
| --- | ---: | ---: | ---: | ---: |
| `MK2MIL.IRW` | 0 | `0x000000` | `0x1FFF40` | 2,096,960 |
| `MK3MIL.IRW` | 0 | `0x200000` | `0x400690` | 2,098,832 |
| `VSSMMOV.IRW` | 0 | `0x400800` | `0x403C18` | 13,336 |
| `MK4MIL.IRW` | 0 | `0x404000` | `0x6056BE` | 2,102,974 |
| `MK5MIL.IRW` | 0 | `0x606000` | `0x736F80` | 1,249,152 |
| `SZSPINE.IRW` | 0 | `0x738000` | `0x7391F2` | 4,594 |
| `MOVEART2.IRW` | 0 | `0x739200` | `0x73CC90` | 14,992 |
| `MOVEART1.IRW` | 0 | `0x73CE00` | `0x7525C8` | 88,008 |
| `SHAOSIT.IRW` | 0 | `0x752600` | `0x75ABAE` | 34,222 |
| `VSJDMOV.IRW` | 0 | `0x75AC00` | `0x75EAAA` | 16,042 |
| `JXAIRPRO.IRW` | 0 | `0x75EC00` | `0x762516` | 14,614 |
| `NOOBFX.IRW` | 0 | `0x762600` | `0x7656E2` | 12,514 |
| `VSNBMOV.IRW` | 0 | `0x765800` | `0x768AA6` | 12,966 |
| `KITSPIN.IRW` | 0 | `0x768C00` | `0x76D93C` | 19,772 |
| `MK1SKULL.IRW` | 0 | `0x76DA00` | `0x778A8A` | 45,194 |
| `GOROWALK.IRW` | 0 | `0x778C00` | `0x781A4E` | 36,430 |
| `FLAPJACK.IRW` | 0 | `0x7BC000` | `0x7EE2C0` | 205,504 |
| `JADVIC.IRW` | 0 | `0x7F0000` | `0x7FD112` | 53,522 |
| `MK6MIL.IRW` | 1 | `0x800000` | `0x9F6AA0` | 2,058,912 |
| `MKSOUL1.IRW` | 1 | `0x9F7000` | `0x9FB044` | 16,452 |
| `MK7MIL.IRW` | 1 | `0xA00000` | `0xBF0EDA` | 2,035,418 |
| `SCLAP.IRW` | 1 | `0xBF1000` | `0xBF2D80` | 7,552 |
| `JADERANG.IRW` | 1 | `0xBF4000` | `0xBF826A` | 17,002 |
| ~~`SHAOFIST.IRW`~~ | 1 | - | - | **retired 2026-09-29** (was 20,236 at `0xBF73D0`; see the SHAOFIST box above) |

## Fixed Custom Slots

Slot ranges are as declared in `makevrom.py`'s `CUSTOM_VIDEO_SLOTS`; free is
slot end minus real payload end.

Bank-0 rows below are the **packed** layout of 2026-08-10: each slot ends on
the first 512-byte boundary above its real payload end, so "current free" is
a guard rail, not budget. All the slack these slots used to carry is in the
one 75,186-byte run at the bottom of the region.

| Slot | Owner | Range | Current free |
| --- | --- | ---: | ---: |
| Sub-Zero head-rip spine + head props | `SZSPINE` | `0x738000..0x7391FF` | 14 |
| second custom move-art pool | `MOVEART2` | `0x739200..0x73CDFF` | 368 |
| frozen custom move-art pool | `MOVEART1` | `0x73CE00..0x7525FF` | 56 |
| Shao Kahn throne stand-up pool (retired KGBLOOD slot) | `SHAOSIT` | `0x752600..0x75ABFF` | 82 |
| Jade VS portrait, zipped movie frame | `VSJDMOV` | `0x75AC00..0x75EBFF` | 342 |
| Jax air lightwave throw frames | `JXAIRPRO` | `0x75EC00..0x7625FF` | 234 |
| Noob shadow move frames (retired VSNOOB slot) | `NOOBFX` | `0x762600..0x7657FF` | 286 |
| Noob VS portrait, zipped movie frame | `VSNBMOV` | `0x765800..0x768BFF` | 346 |
| Kitana overhead spin chop pool | `KITSPIN` | `0x768C00..0x76D9FF` | 196 |
| MK1 scortch fatality frames | `MK1SKULL` | `0x76DA00..0x778BFF` | 374 |
| Kahn Arena Goro walk pool | `GOROWALK` | `0x778C00..0x781BFF` | 434 |
| UMK3 flame fatality frames (the packed region's free run) | **`UMK3FIRE`** | `0x781C00..0x7BBFFF` | **238,592** (the free run - staged, not written) |
| FLAPJACK stage background | `FLAPJACK` | `0x7BC000..0x7FFFFF` | 7,488 (see note) |
| Jade victory body+staff frames (post-FLAPJACK slack) | `JADVIC` | `0x7F0000..0x7FFFFF` | 12,014 |
| Smoke VS portrait, zipped movie frame | `VSSMMOV` | `0x400800..0x403FFF` | 1,000 |
| Shao Kahn Sonic Clap fixed sidecar | `SCLAP` | `0xBF1000..0xBFFFFF` | 4,736 (see note) |
| Jade boomerang sidecar (post-SCLAP bank-1 tail) | `JADERANG` | `0xBF4000..0xBF83FF` | 406 |
| Kahn portal-punch pulp burst (post-JADERANG bank-1 tail) | `SHAOFIST` | `0xBF8400..0xBFFFFF` | 5,080 |
| Shang Tsung soul-suck corpse drop | `MKSOUL1` | `0x9F7000..0x9FFFFF` | 20,412 |

**Two slots are declared wider than they really are.** `FLAPJACK`'s end is
written as `0x800000` and `SCLAP`'s as `0xC00000`, but `JADVIC` sits inside the
first and `JADERANG`/`SHAOFIST` inside the second. makevrom only tests payload
against slot, never slot against slot, so no error is raised - but "slot end
minus payload end" is meaningless for these two and the real figures are the
7,488 and 4,736 above. Same class as the old SHAOSIT note. Take free space from
the verified map at the top of this file, never from a slot end.

**`UMK3FIRE` is declared but not written.** Scorpion's third flame fatality
(D,U,U,U + HK) is fully wired in code and gated off at
`umk3_burn_enable .set 0` (`src/MAINEQU.ASM`); `UMK3FIRE.IRW` is deliberately
absent from `makevrom.py`'s `irw_files`. The art as authored packs to
**140,160 bytes** - more than the whole ROM has free - so the frames are being
re-cut as multipart subframes. `IMGBUILD.BAT` still builds it every run so the
IRW and `src/UMK3FIRE.TBL` track the IMG. To ship: add `UMK3FIRE.IRW` to
`irw_files` and set the equate to 1. Declaring the slot now means the overlap
and bounds guards cover it from the moment it is switched on.

**SHAOSIT slot note:** `makevrom.py` still declares SHAOSIT's slot end as
`0x7A0000` even though STGORO sits at `0x790000` inside that range. No real
overlap occurs (SHAOSIT's payload ends at `0x7885AE`), and the checker only
tests payload-against-slot, but treat SHAOSIT's usable end as `0x790000`.

**STGORO slot RECLAIMED (2026-08-05).** The custom "Goro lives" reveal at the
end of Shang Tsung's dive fatality (`stgoro_roll` -> `stdive_goro`, MKDEATH.ASM)
was removed, freeing its whole `0x790000..0x797000` slot — **28,672 bytes**, the
largest single contiguous hole in bank 0. Its neighbours are both live
(`VSJDMOV` ends at `0x790000`, `NOOBFX` starts at `0x797000`), so it does not
coalesce with anything; it is a clean standalone 28KB slot.

Removed with it: `data/STGORO.LOD`, `src/STGORO.TBL`, the MK2STGO composite and
anim tables in MKDEATH.ASM, `MK2G1_P..MK2G4_P` in IMGPAL6.ASM, and the
IMGBUILD.BAT LOAD2 step. Also freed ~888 bytes of PROGRAM ROM (.text −256,
.data −632).

**Not** removed: the RETAIL Kintaro morph (`do_kintaro_fatal`, the ~15-second
LP hold in `st_lp_open`). It borrows Kintaro's own anitab and never used this
sidecar. `STGORO1_P` in IMGPAL6.ASM was kept with it — note that nothing
currently references that symbol, so it is ~130 bytes of program ROM that could
also be reclaimed if someone confirms the morph really does not want it.

**STGORO slot (2026-07-21, corrected 2026-07-31):** the original note claimed
`JADVIC1`'s "real payload ends at `0x78F150`" and that its slot end was pulled
back to hand STGORO the tail. `JADVIC1` never had a payload at all — see the
JADVIC section above. STGORO's `0x790000..0x79FFFF` range is correct and
unaffected; it holds the `STGORO2`/`STGORO3`/`STGORO4`
morph poses (A/B subframes) used by the Kintaro roll on Shang Tsung's
inner-explosion fatality (`do_kintaro_fatal`). Palette `STGORO1_P` is exported to
`src/IMGPAL6.ASM` and applied at runtime via `player_swpal`, because
`GONGORO1.IMG`'s own palette table is short (header claims 7 records, only 4 are
present) with every `STGORO` frame pointing at out-of-range index 6.

Bank-0 free space is **92,654 bytes** across the gaps listed in the verified
free map at the top of this file (was 139,194 before `SHAOFIS2` took the
JXAIRPRO tail on 2026-08-10). (This line used to claim 387,764 bytes; that
was slot space, not free space — it counted ranges the sidecars had already
been given.)

### Jade victory rework (2026-08-01)

`JADVIC` now sources `JADEVIC.IMG` and carries two 14-frame lanes -
`JDVICTORY1-14` (body, 6bpp/`JADE_P`) and `JDVICSTAFF1-14` (staff, 4bpp/
`JDSTGLO_P`). Payload went 51,456 -> **55,824**, so the slot tail dropped from
14,080 to 9,712. Still a comfortable fit; the raw pixel count barely moved
(174,114 vs 173,740), the record count went 15 -> 28. The lanes ride separate
objects because they need separate palettes - see `doc/CUSTOM_CONTENT.md` and
`jade_victory` in `src/MKCANNED.ASM`.

**COMESOON note (2026-07-19):** a fresh `python makevrom.py` run shows MK7MIL.IRW's
real current payload now extends to `0xBF0EB2` — inside the `0xBC8683..0xBEA0AD`
range this doc used to list as a free "retired COMESOON slot". That range was
not used for JADERANG; verify against a fresh `makevrom.py` run before treating
it as available, rather than trusting the byte count below unchecked. The
genuinely free bank-1 space verified for JADERANG was the tail after SCLAP's
real payload end (`0xBF2D80`) through the `0xC00000` chip boundary.

**Do not treat the retired COMESOON range as free.** An earlier paragraph here
declared it "fully available for a future fixed-slot overlay"; the 2026-07-19
measurement above supersedes that — MK7MIL's live payload now runs through
`0xBF0EB2`, straight across it. The only verified free bank-1 space is what the
map at the top of this file lists.

Armory's first image, `ry1HDRS[0]` (`108x36`, palette index `2` / `VAT`), has a
documented one-bit payload repair in `tools/fix_armory_mk7_bg.py`.
Current LOAD2 output differs from the `mk2-readonly` prebuilt MK7 stream in the
first compressed control bit for that image; leaving it set garbles the repeated
lava/metal strip. See `doc/ARMORY_HDR0_BITFIX.md`.

## Rules

- Keep new player move/fatality art in the move-art wrappers so those payloads stay adjacent.
- Keep MK1PIT baked into MK7MIL as `MK1PIT`; do not restore standalone `KFPITPL`.
- Keep REVX locked to `MK8MIL` movie/CPU-read data only; do not put normal PIXBLT sprites there.
- Armory stays in its normal MK7 range. `tools/fix_armory_mk7_bg.py` restores the generated `ry1HDRS` records and clears the known bad first compression bit in `MK7MIL.IRW` after LOAD2.
- Do not spend fixed-slot guard space without updating `makevrom.py`, this ledger, and any proof reports.
- Run `python makevrom.py --debug-bin` after slot changes; it fails on fixed-slot drift or overflow.

### Noob shadow moves + the REVX shift (2026-08-01)

`NOOBFX` claims the retired VSNOOB slot (`0x797000..0x79B3FF`, 17,408 bytes) for
`NOOBSLIDE1-2`, `NOOBAIRKICK1-2` and `NOOBTELE1-2` out of `NOOB.IMG`. Measured
payload **12,514 bytes**, 4,894 free. It is packed at `PPP> 4`, the only sidecar
here that is not 6 - the art uses pixel values 0..14 only so 4 bits is lossless,
and at 6bpp it is 18,440 bytes and overflows the slot. See
`doc/CUSTOM_CONTENT.md`.

**The program ROM was the real constraint, not video ROM.** Adding the moves
pushed `.data` to `0xFFD29ED0`, 314 bytes past the base `makerom.py` was
embedding the REVX movie pool at. There was no slack at the bottom of that pool
but roughly 10.2 KB at the top, so `MK8MIL`'s base moved `0xFFD2B000` ->
`0xFFD39000`, leaving 2,468 bytes free after the payload and about 7.7 KB of
program-ROM headroom. Program ROM is now the scarce resource for new features -
video ROM still has ~200 KB.

## Program-ROM budget (2026-08-11)

Program ROM is 1,048,576 bytes total. It used to be the scarce resource for new
*behaviour* while video ROM was the one for new *art*; they are not
interchangeable - T-Unit PIXBLT cannot source sprite pixels from program ROM.
**After the ending removal neither is scarce any more.**

| Region | Bytes | vs 2026-08-01 |
| --- | ---: | ---: |
| `.text` | 401,730 | +3,264 |
| `.data` | 258,584 | +4,394 |
| REVX movie pool | 153,198 | **-195,330** |
| vectors / FLOORORG / SHADORG | 596 | - |
| **free** | **~234,000** | **+187,000** |

The REVX pool fell from 348,528 to 153,198 when the 14 program-ROM ending
frames went; `makerom.py` now reports **210,698 bytes free after the payload**,
against 15,368 before. `.text` is up on the 2026-08-01 figure despite the
ending text going out (-7,424) because a lot of gameplay work landed in
between.

**"Free" in that table was not usable, and this is the trap to remember.**
`.data` grows *upward* into the REVX base, so free space that sits *above* the
payload is unreachable no matter how large it is. The base stayed at
`0xFFD39000` after the endings came out, so for two weeks the real headroom
for new code and tables was **1,458 bytes** while ~210 KB was idle. Whenever a
payload above `.data` shrinks, **the base has to move too** - the reclaim is
not complete until it does.

### Program-ROM budget (2026-08-24, after the REVX rebase)

| Region | Bytes |
| --- | ---: |
| `.text` | 419,010 |
| `.data` | 263,564 |
| REVX movie pool @ `0xFFED0000` | 153,198 |
| vectors / FLOORORG / SHADORG | 596 |
| **headroom for code/tables** | **209,842** |
| REVX guard after payload | 2,314 |

Check it with `python tools/rom_space_report.py`, which computes the headroom
from the live build rather than from this table. Rationale, the three files
that must agree, and what to do if program ROM ever gets tight again are in
[SPRITE_COMPRESSION.md](SPRITE_COMPRESSION.md) S10.

Numbers come from `python makerom.py`'s section report; per-object `.text`
sizes are in `src/mk2.map`'s SECTION ALLOCATION MAP (in BITS).

### Reclaimed 2026-09-29 (+27,462 bytes bank 1, +4,026 bytes program ROM)

Two features whose switches were 0 while their art stayed packed. Neither was
reachable at runtime; both were kept packed deliberately, so that flipping the
switch back was a one-line change rather than a Phase A rebuild. That trade was
worth making while bank 1 had room and stopped being worth it once the largest
run in the bank was under 10 KB.

- **`SHAOFIST` / `FISTPULP1-15` retired, 20,236 bytes.** Shao Kahn's Portal
  Punch pulp burst. `kfistpulp .set 0` since 2026-09-28 - the body pops on
  `r_burst_pop` instead - but `a_sk_fistpulp` was still `sk_anitab2` row c, so
  all 233 records read as LIVE and the pixels shipped. Full removal list is in
  the SHAOFIST box earlier in this file. Gave back **20,250 bytes at
  `0xBF73C6..0xBFC2E0`**, now the largest single run in bank 1; MK1PSK1 kept
  its `0xBFC2E0` base, so nothing was relocated to collect it.
- **`RAINBUB` / `RNBUB1` retired, 7,226 bytes.** The water bubble the man
  caught in Rain's storm cloud hung inside. `rainbub .set 0` from the day it
  was authored, and because `rbub_shellon` is `rainbub*rbub_shell` the
  `.INCLUDE RAINBUB.TBL` in MKNJ.ASM never even assembled - **only the packed
  pixels ever cost anything**, which is why it never appeared in any
  program-ROM measurement. Removed its `data/IMGBUILD.BAT` step, its
  `makevrom.py` bank/slot/`irw_files` entries, `src/RAINBUB.TBL` and its
  `promote_tbls` registration, and its Phase B `make_rainbub_img.py` run (LOAD2
  no longer reads the IMG, so regenerating it each build bought nothing).
  It **coalesced** with the 9,622-byte hole above it, restoring the whole
  **16,940-byte run above SCLAP at `0xBF1FA4..0xBF61D0`** - the second largest
  in bank 1.

Bank 1 free went **88,156 -> 115,618** and its largest run **9,934 -> 20,250**.
Program ROM headroom went **37,078 -> 41,104** (`.text` -704, `.data` -3,322)
from the lane, the 233 records, `FISTPULP_P` and its `death_fade_excludes` row.

**Both switches now carry an `.emsg`** (`kfistpulp`, and `rbub_shellon` for the
bubble), so setting either back to 1 fails the build with a message instead of
assembling against records that no longer exist - the failure that would
otherwise happen is a record whose SAG points at whatever art now occupies
those addresses, which draws a plausible wrong picture rather than erroring.
`data/SHAOFIST.IMG`, `data/RAINBUB.IMG` and `tools/make_rainbub_img.py` were
all KEPT: they cost no ROM and they are the restore path, which is now a full
`python build.py` (Phase A), not `--asm-only`.

**Measurement note.** `art_ref_graph.py`'s per-record `bytes` column is a
gap-to-next-record figure, so the last record before a hole absorbs that hole:
`SONICLAP11` reads 22,068 before this change and 42,308 after, having swallowed
the freed run. Its class totals are therefore not a space measurement - use
`tools/rom_space_report.py`, which is what the numbers above come from.

### Reclaimed 2026-08-01 (+36,558 bytes)

- **`OART.OUT` unlinked, 23,658 bytes.** `src/mk2.cmd` linked both
  `data/ART.OUT` and `data/OART.OUT`. They are **byte-for-byte identical**, and
  neither carries a single COFF symbol or any relocation information - so
  nothing could reference either by name and the second copy was pure
  duplication. Both files stay on disk. Verified by rebuild + a full boot,
  character select, VS screen and fight in MAME.
- **`VS_JC` retired, 12,900 bytes.** `zipped_pics` index `28h`, commented "1st
  cage picture". Only `0..0bh` is indexed by character and Cage's real portrait
  is `VS_JCN` at index 2, so nothing could ever select it - the sole reference
  in the whole source was the table entry itself. Removing it moved Noob's
  portrait from `29h` to `28h` (`vs_pic_noob` in MKSEL.ASM); the VS screen was
  snapshot-checked afterwards.

### Still available if more is needed

**Largely moot as of 2026-08-11** - both ROMs have room now (~234 KB program,
301 KB video with a 239 KB contiguous run). Kept for when that stops being
true.

**Move the 12 remaining VS portraits from REVX to video ROM - ~153 KB.**
`MK5MIL.LOD` already carries movie frames as `FRM>` entries addressed through
`src/MKZIP.TBL` at video-ROM addresses, so the mechanism ships and works; the
MK8MIL/MK5MIL split was always historical rather than technical. This trades
program ROM for video ROM at 1:1 and is only worth doing if program ROM becomes
the binding constraint again. Any frame moved this way **must land in bank 0** -
`movie_run` has no bank select.

The nine `DIAG*` objects are 39,940 bytes of `.text` (arcade self-test and
service menu). Cuttable for a non-arcade build, but they own CMOS, coin
handling and the boot self-test. `PONG.OBJ` is 1,324 bytes.

`FLAPJACK` + `JADVIC` could be packed against the region below them for another
~19,500 bytes of contiguous video ROM, at the cost of re-verifying a whole
stage background. Not worth it at current occupancy.

### Jade victory staff moved to A/B strips (2026-08-01)

`JADEVIC.IMG` gained `JDVICSTAFF1A/1B..14A/14B` and corrected anipoints on
every composite. `data/JADVIC.LOD` now loads the strips for the staff lane;
the 14 `JDVICTORY` body frames stay composites because the library carries no
A/B form for them. Payload 55,824 -> **53,522**, tail 9,712 -> 12,014.

This is the case where splitting genuinely pays and MK1SKULL is the case where
it does not - **measure, do not assume**. The staff is a long thin diagonal
whose composite bounding box is mostly empty: 83,930 raw pixels as composites
against 45,706 as strips, a 45% cut. MK1SKULL's frames are body-shaped, so
there the trim gain was more than cancelled by doubling the record count.
