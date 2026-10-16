# MK2 Build Pipeline - Current State (2026-06-13)

The normal rebuild is driven by one top-level wrapper:

```powershell
python build_all.py                 # build test + retail, install retail
python build_all.py --no-install    # build test + retail, do not touch C:\MAME\roms
python build_all.py --install-test  # leave WIP/test at rom/test/mk2.zip, install retail
```

`build.py --asm-only` is the current no-LOAD2 source compile path: it skips the LOAD2 image pass, promotes/syncs the existing `tmp/load2` table snapshot, refreshes generated background includes, then assembles. The full `python build.py` path still runs DOS LOAD2 in Phase A before those same promotion steps.

## build.py Phase Sequence

### Phase A0: Stock Background Asset Guard

`tools/check_stock_bg_assets.py` compares stock MK7 `.BDB/.BDD` background files against `..\mk2-readonly\mk2-main\data` unless deliberate drift is allowed.

### Phase A: Image ROM Build (DOSBox LOAD2)

`dosbox_load2.conf` runs `data/IMGBUILD.BAT` and produces `data/*.IRW` plus `tmp/load2/*.TBL` snapshots.

Active LOAD2 order:

| # | LOD | Flag | Notes |
|---|-----|------|-------|
| 1 | MK2MIL | /E | bank 0 sprites part 1 |
| 2 | MK3MIL | /E | bank 0 sprites part 2 |
| 3 | MK4MIL | /E | bank 0 sprites part 3 |
| 4 | MK5MIL | /E | bank 0 sprites part 4; includes STCUT + HKBFIST sidecar tables; `END_MLV` moved to REVX |
| 5 | MK6MIL | /E | bank 1 text/select/blood |
| 6 | MK7MIL | /E | bank 1 floors/fatalities/backgrounds; `BGNDTBL.MK7` snapshot |
| 7 | MK8MIL | none | REVX/program-ROM movie payload at `0xFFED0000` (rebased from `0xFFD39000` 2026-08-24 - see SPRITE_COMPRESSION.md S10); 12 VS portraits |
| 8 | MOVEART2 | /E | new move/fatality sprites at bank-0 `0x05B1C000` |
| 9 | MOVEART1 | /E | global move-art sprites at bank-0 `0x05B40000` |
| 10 | SCLAP | /E | Sonic Clap sidecar at bank-1 `0x03F88000` |
| 11 | SHAOSIT | /E | Shao Kahn throne sidecar at bank-0 `0x05C00000` |
| 12 | GOROWALK | /E | Kahn Arena Goro walk sidecar at bank-0 `0x05D80000` |
| 13 | FLAPJACK | /E | FLAPJACK stage sidecar at bank-0 `0x05DE0000` |
| 14 | KITSPIN | /E | Kitana overhead spin chop sidecar at bank-0 `0x05D00000` |

### Phase A1: LOAD2 Log Guard

`tools/check_load2_log.py` fails on LOAD2 errors or missing active LOD summaries.

### Phase B1/B2: Promote Generated Tables

- `tools/promote_tbls.py` syncs LOAD2-generated per-character TBL SAG/CTRL values into `src/` while preserving hand-maintained additions.
- `tools/promote_bgndtbl_stock_records.py --apply` copies complete stock background records from `tmp/load2/BGNDTBL.MK7`.
- `tools/promote_bgndtbl_stock_sags.py --apply` syncs labeled stock background SAGs.
- `tools/sync_bgndtbl_sags.py` syncs anonymous stock BGNDTBL SAGs.
- `tools/refresh_mk1pitbg.py` regenerates `src/MK1PITBG.ASM` from the baked MK7 snapshot.
- `tools/promote_flapjack_bg.py --apply` promotes the fixed-slot FLAPJACK sidecar records.
- `tools/fix_armory_mk7_bg.py --apply` restores Armory's normal generated MK7 records and clears `ry1HDRS[0]`'s first compressed control bit directly in `MK7MIL.IRW`. Without that repair, the repeated `108x36` VAT/lava strip renders garbled. See `doc/ARMORY_HDR0_BITFIX.md`.
- `tools/sync_mksel_vs_restore.py` keeps the VS restore chunks aligned.

### Phase C: Assemble + Link

`dosbox_asm.conf` runs `gmake -m` in `src/` and links `src/mk2.out`.

### Phase D/E: Sanity Checks And Manifests

Phase D reruns the table sync tools in `--check` mode. Phase E exports Freeplay RAM address manifests.

## ROM Packing

- `makerom.py` embeds `MK8MIL.IRW` into REVX/program ROM and currently reports 2,468 bytes free after the payload.
- `makevrom.py` packs the active video IRWs. The live custom order is `MOVEART2`, `MOVEART1`, `SHAOSIT`, `SCLAP`, `KITSPIN`, `GOROWALK`, then `FLAPJACK`; Raiden shortzap is in `MK3MIL`, and MK1PIT is in `MK7MIL`.
- `mamerom.py --no-install` packages source-built program/video/sound ROMs into `rom/mk2.zip` without installing it.
- `mamerom.py` refuses to package source video if any active LOAD2 `.IRW` is newer than the video chips. Run `python makevrom.py` after every full `python build.py`, or use `python build_all.py` for the normal one-command build.

## Retired Standalone Payloads

Standalone scratch/proof LODs that are no longer active are removed from the live build path. Keep live sidecar tables that active LODs still reference, such as `STCUT.TBL`, `HKBFIST.TBL`, `LKBFIST.TBL`, and `JCHRIP.TBL`.
