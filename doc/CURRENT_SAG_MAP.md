# Current build SAG map

Snapshot of where the three SAG sources of truth agree and disagree. Run this after `python build.py` to spot SAG drift that causes in-MAME background/sprite artifacts.

Sources:
- **src** = `src/BGNDTBL.ASM` (compiled into mk2.out ? runtime reads these)
- **gen** = `tmp/load2/BGNDTBL.ASM` (overwritten by each LOD's LOAD2 run; only reflects the LAST LOD's output)
- **IRW** = `data/*.IRW` header base addresses + payload sizes

## IRW physical placement

How each IRW maps into the 12 MB flat video ROM (per makevrom.py math).

| IRW | Bank | SAG base | Payload bytes | Flat start | Flat end |
|---|---:|---:|---:|---:|---:|
| `FLAPJACK.IRW` | 0 | `0x05de0000` | 111,424 | `0x7bc000` | `0x7d7340` |
| `GOROWALK.IRW` | 0 | `0x05d80000` | 36,430 | `0x7b0000` | `0x7b8e4e` |
| `MK2MIL.IRW` | 0 | `0x02000000` | 2,096,960 | `0x000000` | `0x1fff40` |
| `MK3MIL.IRW` | 0 | `0x03000000` | 2,112,564 | `0x200000` | `0x403c34` |
| `MK4MIL.IRW` | 0 | `0x04020000` | 2,102,974 | `0x404000` | `0x6056be` |
| `MK5MIL.IRW` | 0 | `0x05030000` | 1,422,072 | `0x606000` | `0x7612f8` |
| `MK6MIL.IRW` | 1 | `0x02000000` | 2,096,532 | `0x800000` | `0x9ffd94` |
| `MK7MIL.IRW` | 1 | `0x03000000` | 2,050,810 | `0xa00000` | `0xbf4afa` |
| `MK8MIL.IRW` | program-ROM | `0xffd29500` | 361,154 | ? | ? |
| `MOVEART1.IRW` | 0 | `0x05b40000` | 88,886 | `0x768000` | `0x77db36` |
| `MOVEART2.IRW` | 0 | `0x05b1c000` | 14,374 | `0x763800` | `0x767026` |

## SAG drift: src vs LOAD2 regen

- Labels aligned: **0**
- Labels drifted: **1**
- src-only (e.g., retired payloads, hand-added): **30**
- gen-only (just-emitted by latest LOAD2 run): **0**

### Expected intentional SAG differences

Armory no longer has an intentional SAG difference: `ry1HDRS` remains at its
normal generated MK7 location. `OFHDRS` remains a raw-versus-runtime bank
decode case.

### Labels only in src/ (retired payloads + cross-LOD content)

These survive in src/BGNDTBL.ASM but the current `tmp/load2/` snapshot doesn't know about them ? either retired BBBs (callers disabled but address stability preserved per the postmortem) or content that comes from an earlier LOD whose `tmp/load2/` output was overwritten.

Count: **30**. (Listing skipped to keep this file actionable; use `--print` to see them.)

## Conclusion

Build is consistent for live BGND-table purposes: every unexpected shared-label drift is clear, and the most recent LOAD2 run emitted nothing not already promoted. If you're still seeing artifacts, the source is **not** BGND-table SAG drift ? look elsewhere:

- Per-character TBLs (MKLK.TBL, MKNJ.TBL, etc.) ? run `python tools/promote_tbls.py --check`.
- IRW physical packing ? diff against retail with `python mamerom.py path/to/retail.zip --source-video`.
- Custom slot collision ? compare fixed-slot ranges above against the live table.
- Palette / DMA-control bits in HDRS records ? these aren't tracked by this tool; check `src/BGNDPAL.ASM` and the BMOD flags word.
