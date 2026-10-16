# Release Space Audit - 2026-06-24

This audit was run after the expanded FLAPJACK promotion and the FLAPJACK
fighter baseline tweak.

## Build And Slot Baseline

Program ROM:

| Area | Address / range | Bytes | Notes |
| --- | ---: | ---: | --- |
| Flat program ROM | `0x000000..0x0FFFFF` | 1,048,576 | Full T-Unit program image; `makerom.py` passes capacity |
| `MK8MIL.IRW` REVX payload | `0xFFD29500` | 361,154 | Locked VS/ending movie pool |
| REVX free after MK8 | `0xFFFEAB10..0xFFFFFBC0` | 10,774 | Keep for CPU-read/movie data only |

Active video ROM payloads:

| IRW | Flat start | Flat end | Payload bytes |
| --- | ---: | ---: | ---: |
| `MK2MIL.IRW` | `0x000000` | `0x1FFF40` | 2,096,960 |
| `MK3MIL.IRW` | `0x200000` | `0x403C34` | 2,112,564 |
| `MK4MIL.IRW` | `0x404000` | `0x605706` | 2,103,046 |
| `MK5MIL.IRW` | `0x606000` | `0x7612F8` | 1,422,072 |
| `MOVEART2.IRW` | `0x763800` | `0x767026` | 14,374 |
| `MOVEART1.IRW` | `0x768000` | `0x77D198` | 86,424 |
| `GOROWALK.IRW` | `0x7B0000` | `0x7B8E4E` | 36,430 |
| `FLAPJACK.IRW` | `0x7BC000` | `0x7FDFCE` | 270,286 |
| `MK6MIL.IRW` | `0x800000` | `0x9FFD94` | 2,096,532 |
| `MK7MIL.IRW` | `0xA00000` | `0xBF417E` | 2,048,382 |

Current bank-0 custom/free space after `MK5MIL` totals `0x3B52E` / 242,990
bytes. The most useful contiguous buckets are:

| Bucket | Range | Free bytes |
| --- | ---: | ---: |
| MK5-to-MOVEART2 gap | `0x7612F8..0x7637FF` | 9,480 |
| `MOVEART2` slack | `0x767026..0x767FFF` | 4,058 |
| `MOVEART1` slack | `0x77D198..0x7AAFFF` | 188,008 |
| MOVEART1-to-GOROWALK gap | `0x7AB000..0x7AFFFF` | 20,480 |
| `GOROWALK` slack | `0x7B8E4E..0x7BBFFF` | 12,722 |
| `FLAPJACK` slack | `0x7FDFCE..0x7FFFFF` | 8,242 |

There are no loose `data/*.IRW` payloads outside the active pack list right now.

## Retired Background Overlay Space

`tools/map_retired_ranges.py --csv` reports two useful retired bank-1 overlay
regions. Do not add these row sizes together by label, because many of the
retired labels overlap the same physical bytes.

| Union range | Bytes | Contents |
| --- | ---: | --- |
| `0xB9BA89..0xBC73B2` | 178,474 | Disabled story/attract/team/high-score background ranges |
| `0xBC7D05..0xBE9730` | 137,772 | Disabled `COMESOON` range |
| Total retired-overlay union | 316,246 | Overlay candidates, not normal free space |

These are good deliberate-overlay targets for future video payloads, but they
need the same guardrails as FLAPJACK/GOROWALK: fixed slot policy, LOAD2 address
comments, `makevrom.py` checks, and source table validation.

## Highest-Confidence Reclaim Candidates

### 1. FLAPJACK BDD Purge

`FLAPJACK.BDB` now references 42 of 49 images. The `.BDD` still carries 7
unreferenced images, which explains why `FLAPJACK.IRW` did not shrink when the
large road object was removed.

Unused FLAPJACK images:

| ID | Name | Size | Raw indexed pixels |
| ---: | --- | ---: | ---: |
| `0x4C` | `ROFLWAFL` | 140x40 | 5,600 |
| `0x4F` | `RBGGRASS` | 78x27 | 2,106 |
| `0x50` | `ROFLWAFL` | 400x147 | 58,800 |
| `0x51` | `PLOAT` | 400x53 | 21,200 |
| `0x52` | `ROFLWAFL` | 140x40 | 5,600 |
| `0x53` | `ROFLWAFL` | 400x147 | 58,800 |
| `0x54` | `ROFLWAFL resize` | 250x92 | 23,000 |

Total unused FLAPJACK source pixels: 175,106 of 364,320. Actual IRW savings
will depend on LOAD2 packing/compression, but this is the best immediate
FLAPJACK space win.

Unused FLAPJACK palette slots:

| Slot | Name |
| ---: | --- |
| 13 | `ROFLWAFLP` |
| 16 | `FGRASS_P` |
| 17 | `ROFLWAFLP` |
| 18 | `PLOAT` |
| 19 | `ROFLWAFLP` |

Duplicate FLAPJACK palette names:

| Name | Slots | Notes |
| --- | --- | --- |
| `BULLETGRP` | 11, 14 | Both are referenced, verify whether they are true color duplicates before merging |
| `ROFLWAFLP` | 13, 17, 19 | All currently unused after road removal |

### 2. Active Loaded-But-Skipped Animation Frames

These likely cost packed video space because they are emitted by active LODs,
but the active animation code skips them. Verify in MAME before removing or
restoring.

| Candidate | Evidence | Release action |
| --- | --- | --- |
| `NJKNEE4`, `NJKNEE5`, `NJKNEE6` | Loaded in `MK4MIL.LOD`; `a_njknee` uses only 1-3 | Restore into animation or remove from LOD if intentionally dead |
| `JCTHROW3` | Loaded in `MK2MIL.LOD`; commented out of `a_jczap` | Test as projectile windup frame |
| `JCFLYBO1` | Loaded in `MK2MIL.LOD`; commented out of `a_shoruken` | Test or remove |
| `UGELBO4` | Defined in `MKSA.ASM`; active elbow uses 1-3 | Test as Sword Arms elbow extra |
| `STELBO1`, `STELBO2` | Defined in `MKST.ASM`; active elbow starts at 3 | Test as Shang windup frames |
| `BGJUMP1-3` | Loaded in `MK5MIL.LOD`; no active Kahn jump reference found | Boss AI trace needed |
| `BGSLAM1-6` | Loaded in `MK5MIL.LOD`; no active slam reference found | Boss throw/slam trace needed |
| `FATNINJA1`, `FATNINJA5` | Loaded in `MK6MIL.LOD`; commented out of ninja fat sequences | Restore longer fatality or remove |
| `fans2-4` | Defined in `MKFN.ASM`; comment says opening was too slow | Keep cut for timing or remove if space pressure is severe |

`doc/CUT_CONTENT_CANDIDATES.md` has the longer archaeology notes.

### 3. Stage Palette Cleanup

BDD-level palette scans found unused palette slots in several background source
files. These are mostly small wins compared with image/frame cleanup, but they
are useful for release hygiene and palette-pressure debugging.

| Stage BDB | Unused palette slots | Exact duplicate palettes found |
| --- | ---: | --- |
| `FLAPJACK.BDB` | 5 | Duplicate names only; verify colors before merge |
| `ARENA.BDB` | 3 | None found |
| `ARMORY1.BDB` | 1 | None found |
| `BATTLE.BDB` | 1 | None found |
| `NUPOOL.BDB` | 1 | None found |
| `KUNGFU2.BDB` | 11 | Several exact duplicate old/new palette labels |
| `KUNGFU4.BDB` | 11 | Several exact duplicate old/new palette labels |
| `MK1PIT.BDB` | 9 | None found |

Do not blindly delete stock BDD palettes; first confirm LOAD2/BGNDPAL output
and runtime palette ownership.

## Source-Only Clutter

`tools/find_unused_records.py` currently reports:

| Metric | Count |
| --- | ---: |
| IMG records scanned | 16,288 |
| Records exported by some LOD | 9,446 |
| Records beyond LOD export lists | 6,998 |

Top zero-export source `.IMG` files by disk size:

| File | Disk bytes | Records | Notes |
| --- | ---: | ---: | --- |
| `ROFLWAFL.IMG` | 2,500,140 | 24 | Source-only unless used by BDDTool imports |
| `REPHEAD.IMG` | 1,656,628 | 29 | Source-only currently |
| `WAFFLE2.IMG` | 1,272,160 | 32 | Source material for FLAPJACK/waffle work; do not delete blindly |
| `TMPLOAD.IMG` | 1,089,370 | 38 | Source-only currently |
| `WAFHAUS.IMG` | 979,400 | 25 | Waffle source/proof material |
| `OLDSHNG.IMG` | 900,056 | 86 | Source-only unless restored |
| `B8ELEC.IMG` | 791,378 | 153 | Source-only currently |
| `OGTSUNG1.IMG` | 658,494 | 57 | Source-only currently |
| `MK2ENDS.IMG` | 656,218 | 24 | Source-only currently |
| `NINJAS1NOOB.IMG` | 645,766 | 147 | Source-only currently |
| `NINJAS1BESTN.IMG` | 645,766 | 147 | Source-only currently |
| `SONYA.IMG` | 563,836 | 77 | Source-only currently |
| `CASTLE.IMG` | 552,052 | 85 | Contains Tower statue art; keep if that restore remains possible |

These files do not cost ROM bytes unless active LODs export them. They are
release packaging/repo cleanup candidates, not immediate ROM-space wins.

Other repo clutter observed at the root:

| File pattern | Notes |
| --- | --- |
| `tmp_build_*.log` | Old local build logs; safe to archive or remove before release |
| `*.pre_flapjack_stage_*.bak` | Old script backups; source-control history should replace these |
| `mk2.zip.bak` | 13 MB old ROM zip backup; not needed in source release |
| `BGNDTEST.LOD` | Only inactive `.LOD` file present; tiny proof file |

## Release Recommendations

1. Purge FLAPJACK unused images/palettes first. It is the biggest obvious
   active payload win and should also reduce palette confusion in BDD Viewer.
2. Keep REVX locked to `MK8MIL.IRW` movie/CPU-read data. Do not put normal
   PIXBLT sprite art there.
3. Treat `0xB9BA89..0xBC73B2` and `0xBC7D05..0xBE9730` as overlay candidates
   only. Add policy guards before using them.
4. Do not delete `STCUT.TBL`, `HKBFIST.TBL`, `LKBFIST.TBL`, or `JCHRIP.TBL`
   without tracing live references. Some retired wrappers still have table
   records preserved intentionally.
5. Before release packaging, remove local scratch logs/backups from the repo
   or move them under a clearly ignored scratch folder.

Verification commands used:

```powershell
python tools\find_unused_records.py
python tools\find_unused_sprites.py --per-img
python tools\map_retired_ranges.py --csv
python makerom.py
python mamerom.py --no-install
```
