# BLDXPD per-frame depth prototype

**Status: implemented; offline checks and MAME tests pass, 12 September 2026.**
This is opportunity 02 in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md).
FBNeo/Fightcade and physical hardware have not been tested for this change.

## Result

`data/BLDXPD.LOD` now uses `PPP> 0`. The installed LOAD2 executable selects
4 bpp for frames 1–7, 3 bpp for 8–10, 2 bpp for 11–12 and 1 bpp for 13.
Pixel indices, dimensions, anchors, palette entries and animation timing are
unchanged. Updated SAG/control words are in `src/BLDXPD.TBL`.

| Measurement | Before | After |
|---|---:|---:|
| Packed image payload | 63,196 bytes | 46,142 bytes |
| IRW file including 68-byte header | 63,264 bytes | 46,210 bytes |
| Capacity remaining in the 65,536-byte slot | 2,340 bytes | 19,394 bytes |

**17,054 bytes saved: approximately 27.0% of the previous payload.**
The slot stays at bank 1, `0xBCD600..0xBDD600`; the new payload ends at
`0xBD8A3E`. Nothing moves into the recovered capacity. The older ledger's
63,264-byte “used” number included the IRW file header, which is not stored
in video ROM.

No runtime renderer modification was needed. `ermac_splat_one` uses
`framew -> frame_a9 -> ani`; `ani` masks out the prior depth/compression
bits before applying the next header. This result does not establish that
an unprepared `ani0` lane is safe for mixed-depth art. It also does not
establish a frame-time saving: this prototype saves ROM capacity.

## Validation

- The real LOAD2 binary (`DMA 2`, version `03/14/95`) produced the expected
  depth sequence in a private fixture. `/B` was not used.
- Both the original fixed-depth payload and the new payload decoded exactly
  to all 13 authored IMG images, including transparent indices. Every anchor,
  dimension and palette reference matched. Frame boundaries and final
  payload padding were checked.
- The private fixture ran without dual-bank mode; its generated SAGs were
  normalized by `+0x02000000` to the existing bank-1 flat offsets. Production
  IRW bank identity was preserved. The default checker requires the actual
  fixed runtime SAG, so fixture addressing cannot silently become production
  addressing.
- `build.py --asm-only` promoted the prepared table, assembled/linked, and
  passed its mandatory checks. `makerom.py`, `makevrom.py`, and packaging
  completed. The test zip is under `tmp/bldproto/rom`, not installed over the
  normal arcade ROM. The build reports the pre-existing Boxlab export
  freshness warning; that separate export was not regenerated.
- Two isolated MAME runs, with Ermac to the left and right of the victim,
  passed the existing fatal-slam real-input/completion test and the new
  observer. Each run observed **three splats, all 13 ordered frames, five
  refreshes per frame, 65 refreshes per splat, stable palette ownership,
  correct live control words, correct linked headers, object deletion and
  zero remaining palette references**. No gameplay code was changed.

The observer composes with the existing input rig; it does not force the
frame controls or artificially delete the splats. It derives palette RAM
addresses from the current linker map. The runner creates private cfg,
NVRAM, input, state and snapshot directories and checks both explicit verdicts.
It neither stops other emulator sessions nor clears their state.

## Reproduce

Read-only packed-art check, also registered in build Phase D:

```powershell
python tools/check_bldxpd_packing.py --check
```

After rebuilding and packaging a ROM with the current table and image
payload, run the two orientations:

```powershell
python tools/run_bldxpd_prototype.py --rom-dir tmp/bldproto/rom
```

Use `--mame` to select another compatible MAME executable. Logs and an input
hash manifest go into a fresh directory beneath `tmp/bldproto/tests`.
The runner fails on a missing verdict, timeout, wrong control/timing,
palette leak or input-file change during the run. No full LOAD2 sweep was
required for this isolated prototype; the committed LOD is the recipe for
subsequent normal image builds.

## Files and evidence

- [LOD](../../data/BLDXPD.LOD) and [source table](../../src/BLDXPD.TBL).
- [Offline guard](../../tools/check_bldxpd_packing.py) and
  [build registration](../../build.py).
- [Runtime observer](../../tools/bldxpd_runtime_test.lua) and
  [isolated runner](../../tools/run_bldxpd_prototype.py).
- [Recorded packing and test results](bldxpd_prototype_results.json).

The next small storage prototype is opportunity 03: pack Noob's vortex and
opening-blast effects at 5 bpp while keeping the casting-body pieces at their
current depth and shadow contract.
