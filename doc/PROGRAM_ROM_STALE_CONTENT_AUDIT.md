# Program ROM Space and Stale Content Audit

Date: 2026-07-16

Status: Findings only. No source records, palettes, tables, payloads, or ROM files were removed as part of this audit.

## Executive Summary

The MK2 program ROM is two 512 KiB chips with a combined capacity of 1,048,576 bytes. It contains executable code, initialized data, palettes, background and animation tables, system data, vectors, and the special CPU-read `MK8MIL` movie payload.

The current build has 26,568 bytes of safely usable program-ROM headroom:

| Headroom region | Bytes | Intended use |
|---|---:|---|
| Linker gap before `MK8MIL` | 15,794 | Normal code and initialized-data growth |
| Tail after `MK8MIL` | 10,774 | CPU-read or movie payload growth |
| **Total safe program headroom** | **26,568** | Two separate regions; not one contiguous allocation |

The strongest stale-content lead is the retired COMESOON background metadata, estimated at 2,822 program-ROM bytes. A second current-only checker/test family may also be stale, but its runtime reachability and current compiled size are not yet proven.

No complete linked object was proven dead. Several large apparent candidates were resolved as active through character or background dispatch references.

## What Program ROM Contains

Program ROM stores more than executable instructions:

| Content | Current measured bytes | Notes |
|---|---:|---|
| Executable `.text` | 413,100 | Game engine, fighters, AI, fatalities, menus, diagnostics, and stage logic |
| Initialized `.data` | 247,106 | Palettes, BMOD/block metadata, animation sequences, dispatch tables, text, and configuration |
| `MK8MIL` payload | 361,154 | CPU-read compressed VS/ending movie data |
| Fixed render data and vectors | 596 | Floor/shadow records plus interrupt/reset vectors |
| **Known occupied total** | **1,021,956** | Excludes fill and guarded gaps |
| Raw unoccupied bytes | 26,620 | Includes 44 alignment bytes and 8 CRC-reserved bytes |
| **Safely usable bytes** | **26,568** | Excludes structural/reserved bytes |

Normal sprites and backgrounds use both ROM domains:

- Video ROM stores compressed pixel data.
- Program ROM stores palettes, dimensions, animation sequences, block tables, and video-ROM pointers/SAGs.
- Removing pixels from video ROM does not automatically remove their program-ROM metadata.
- Replacing stale words with zero does not free bytes. Declarations or complete records must be removed so the linked section becomes smaller.

The T-Unit blitter cannot directly use ordinary sprite pixels from program ROM. `MK8MIL` works because the CPU reads and decompresses its movie data into working/video memory through a special path.

## Comparison With `mk2-readonly`

`mk2-readonly` does not contain a program `MK2.MAP`, `mk2.out`, or built `MK8MIL.IRW`. The byte-exact retail L3.1 UJ12/UG12 program chips were therefore used as the compiled stock baseline.

| Measurement | Current build | Stock L3.1 baseline |
|---|---:|---:|
| Program-ROM capacity | 1,048,576 | 1,048,576 |
| Safely usable contiguous regions | 26,568 | 1,488 |
| Difference from stock | +25,080 | Baseline |
| High-ROM MK8/REVX packed data | 361,154 | Approximately 391,592 |

The current linked code/data footprint extends 5,358 bytes into the original stock REVX region. The repacked `MK8MIL` payload is 30,438 bytes smaller than the packed stock high-ROM region, leaving a net 25,080-byte headroom improvement.

## Candidate PR-01: Retired COMESOON Metadata

Confidence: High-value candidate, pending confirmation against the latest `BGNDPAL.OBJ` and `BGNDTBL.OBJ` symbol tables.

The COMESOON video range and its attract-mode caller were retired, but the background export history still contains:

- `comesoonBMOD`
- `soonPALS`
- `BACKPL_P`
- `WWFlogo_P`
- `WWFLOGO3`
- `WWFLOGOP`
- `REG_P`

The prior compiled object boundaries give this estimated program-ROM cost:

| Component | TMS section span | Program-ROM bytes |
|---|---|---:|
| COMESOON image palettes and palette list | `0x21A30..0x256C0` | 1,938 |
| COMESOON BMOD/block metadata | `0x39EF0..0x3BA90` | 884 |
| **Estimated recovery** | | **2,822** |

These are TMS bit-addressed section offsets, so each span is divided by eight to obtain physical program-ROM bytes.

Why this is not yet marked confirmed removable:

- `src/BGNDTBL.GLO` was written before the latest `BGNDTBL.ASM` and `BGNDTBL.OBJ`.
- The latest object must be checked directly to prove these labels are still emitted.
- Relocation and pointer-table references must be checked, not only textual callers.

If confirmed, removing only this metadata would increase safe program headroom from 26,568 to approximately 29,390 bytes.

## Candidate PR-02: Checker/BGNDTEST Tables

Confidence: Medium.

The current-only export family includes:

- `KERHDRS`
- `KERPALS`
- `CHECKPAL`
- `CHKMODBLKS`
- `CHKMODBMOD`

These names align with the leftover `data/BGNDTEST.LOD` scaffold. `BGNDTEST.LOD` is not part of the current active LOAD2 roster, which makes previously promoted checker metadata a plausible stale-table source.

This family must not be removed based on naming alone. It may still be reachable through an indirect background dispatch table or a diagnostic/proof path. Required proof:

1. Find the exact current symbol addresses and byte spans.
2. Check every current object relocation for references to the family.
3. Check local pointer tables inside `BGNDTBL.OBJ` and `BGND.OBJ`.
4. Verify that no diagnostic or background-proof mode selects it.

## Candidate PR-03: Retired REVX/DCS Stubs

Confidence: High, low byte value.

`MKAMODE` still imports `show_dcs_logo`, while current `UNZIP.ASM` implements the retired DCS path as an immediate return. The REVX advertisement route is likewise retired.

Potential residue includes:

- Stub entry points.
- Calls to stubs.
- Disabled attract-mode branches.
- Constants or flags retained only for those branches.

Expected recovery is probably tens of bytes rather than kilobytes. This is cleanup work, not a primary capacity win.

## Candidate PR-04: Retired Ranking/Comic Attract Routines

Confidence: Medium-low until a current local-symbol reachability pass is available.

The older assembler listing shows the ranking assignment and `advertise_comic` call commented out when the retired COMESOON area was repurposed. The disabled calls themselves consume no ROM, but complete routine bodies or tables may still be emitted elsewhere in `MKAMODE.OBJ`.

A local-symbol call graph is required because these routines may not be exported globals.

## Candidate PR-05: `MK8MIL` Record-Level Audit

Confidence: Audit target only; no stale record has been proven.

`MK8MIL.IRW` is the largest individual program-ROM payload at 361,154 bytes. LOAD2 reports two records in this payload and identifies `END_MLV` as one movie family.

A record-level audit should:

1. Enumerate every LOD record and compressed byte span.
2. Map each record to runtime movie callers and table entries.
3. Compare the record list with `mk2-readonly` and the retail binary.
4. Distinguish active VS/ending movies from retired advertisement material.
5. Avoid treating normal sprite art as a valid program-ROM payload candidate.

No `MK8MIL` record should be removed without runtime caller proof.

## Cleared False Positives

### `MKGORO.OBJ`

`MKGORO.OBJ` occupies 7,634 program-ROM bytes and initially appeared to have no incoming references. The character dispatcher imports `go_anitab1` and `go_anitab2`, proving that the module supplies active Kintaro animation data.

Disposition: Keep.

### `MKHANG.OBJ`

`BGND.OBJ` imports `create_hangers`, proving the Dead Pool hanging-developer module is wired into active background code. Its object is newer than its source.

Disposition: Keep.

### FLAPJACK Tables

`BGND.OBJ` imports all eight FLAP BMODs.

Disposition: Keep unless the entire FLAPJACK stage is intentionally retired.

### MK1 Pit Tables

`BGND.OBJ` imports the MK1 Pit background, foreground, floor-saw, and gore BMODs.

Disposition: Keep.

### Retired JC Head-Rip Comments

The inspected JC head-rip and disabled Baraka-path lines are comments or disabled instructions. Commented source consumes no program-ROM bytes.

Disposition: No ROM-space action.

### Old Background-Proof Suite

The June refactor artifacts contained a large `PROOF*`, `RPROOF*`, `TST*`, and ORNGBL test family. These exports are absent from the newer current export set.

Disposition: Already retired from the current program data; do not count it as new recoverable space.

## Build-Artifact Integrity Findings

A timestamp audit found 71 paired ASM/OBJ modules and no ASM source newer than its object. There is no simple stale-object problem in the current linked input.

Two logs are stale and can mislead audits, but they do not consume ROM:

- `src/BUILD.LOG` is an old failed April build and is not evidence for the current ROM.
- `data/IMGBUILD.LOG` predates the repaired `IMGBUILD.BAT` and still reports the retired ARMORYCS load.

`data/BGNDTEST.LOD` remains on disk. A LOD file on disk consumes no ROM unless the active LOAD2/build path packs it or promoted tables from it remain compiled.

## Proof Standard Before Removing Program Data

A candidate should satisfy all of the following:

1. The exact bytes are present in the latest linked object or payload.
2. No direct relocation references the candidate.
3. No local pointer, dispatch, animation, stage-select, or diagnostic table references it.
4. The feature is absent from the intended runtime behavior.
5. The candidate has a measured start/end span and expected byte recovery.
6. A scratch removal build reduces `.text`, `.data`, or `MK8MIL` by the expected amount.
7. Runtime testing covers gameplay, attract mode, endings, service diagnostics, and hidden paths affected by the candidate.

Static text searches alone are insufficient because MK2 uses many indirect animation and stage tables.

## Recommended Next Audit Pass

The next proof-oriented pass should produce a generated report without removing anything:

1. Parse every current COFF object symbol and relocation table.
2. Build a cross-object and intra-object reference graph.
3. Seed roots from vectors, exported runtime entry points, character tables, stage tables, diagnostics, and movie callers.
4. Compare current labels with `mk2-readonly` labels.
5. Estimate function and table sizes from consecutive symbols in each section.
6. Report unreachable candidates by confidence level.
7. Add optional MAME execution coverage only after the static report is stable.

Priority order:

1. Confirm or reject COMESOON metadata in the latest objects.
2. Resolve `CHKMOD`/BGNDTEST reachability and size.
3. Audit local retired routines in `MKAMODE` and `UNZIP`.
4. Audit both `MK8MIL` records against runtime movie callers.
5. Expand into animation and palette tables only after preserving index contracts.

## Evidence Files

- `makerom.py`: program-ROM capacities, REVX placement, overlap checks, and guarded tail.
- `src/MK2.MAP`: current linked section and object allocation.
- `src/mk2.cmd`: linked objects and memory layout.
- `src/MAKEFILE`: active assembler/link object roster.
- `src/BGNDTBL.GLO`: background export inventory; timestamp caveat applies.
- `src/UNZIP.ASM`: retired REVX and DCS stubs.
- `data/IMGBUILD.LOG`: LOAD2 payload sizes; log is older than the latest build script.
- `data/BGNDTEST.LOD`: leftover checker/test LOD candidate.
- `rom/mk2_retail.zip`: compiled retail L3.1 baseline.
- `../mk2-readonly/mk2-main`: original source baseline.