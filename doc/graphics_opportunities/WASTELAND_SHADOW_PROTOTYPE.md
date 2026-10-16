# Wasteland fast-shadow prototype

Status: **enabled in source and validated in MAME**, 12 September 2026.
Opportunity 01 from [the graphics audit](../GRAPHICS_OPPORTUNITIES.md).
Further Noob work remains deferred.

## Change and reason

`calla_battle` selects `shad_fast=2`. Compressed sprite pieces use the existing
two-blit scaled shadow path; uncompressed pieces retain the legacy row loop.
Mode 0 remains the default set by `init_bakmods`; Tower retains mode 1, its
full fast path. No asset placement, palette allocation or RAM layout changes
are needed.

An initial full-fast trial matched fighter/camera traces across all twelve
standard fighters but changed 3–23 pixels in some captures around their feet.
The legacy uncompressed-piece loop reads a compressed header that raw pieces
do not have. Tower already accepts the correction made by the full fast path.
For Wasteland, mode 2 preserves the existing appearance instead of bundling
that visual correction into a performance change.

The mixed path waits for DMA before restoring both unit X/Y scale and a
one-row height before a raw piece. Otherwise a preceding fast piece can leave
the legacy loop using its scale or height. Source changes are in
[BGND.ASM](../../src/BGND.ASM), [MKDISP.ASM](../../src/MKDISP.ASM) and
[RAM.ASM](../../src/RAM.ASM).

## Paired measurements

All trials use the same frozen ROM and matching linker map; their SHA-256
hashes and per-capture results are in the
[machine-readable receipt](wasteland_shadow_results.json).

| Fighters (indices) | Legacy DMA starts/refresh | Mode 2 starts/refresh |
|---|---:|---:|
| Kung Lao / Baraka (0 / 3) | 211.69 | 103.75 |
| Johnny Cage / Reptile (2 / 9) | 215.87 | 105.23 |
| Kitana / Scorpion (4 / 10) | 219.44 | 105.98 |
| Mileena / Jax (5 / 11) | 226.73 | 106.96 |
| Shang Tsung / Raiden (6 / 7) | 219.25 | 106.31 |
| Sub-Zero / Liu Kang (8 / 1) | 211.66 | 104.43 |

The six equally sized comparisons average **217.44 → 105.44 DMA starts per
refresh, a 51.5% reduction**. These are total starts, including backgrounds
and fighters, not just shadow commands. Each mode has 781 measured refreshes
per pairing: **4,686 per mode**. Walking both ways, jumping, crouching and
basic attacks exercise moving multipart art without changing the input script.

- All **162 paired 400×254 RGB captures** match exactly (27 per pairing).
- No differences in sampled fighter position, frame pointer, flags or camera
  position across all 4,686 corresponding trace rows.
- No increase in the late-frame counter during any measured comparison.
- Mean last DMA **start** moves from 66.4–67.9% of the refresh period to
  56.1–56.6%. This is earlier submission, not a completion-time measurement
  or a claim that frame rate increased.
- Separate native runs, with the override disabled, assert Wasteland mode 2,
  Kombat Tomb mode 0 and Tower mode 1. All complete without new late frames.
  These are independent stage boots, not a stage-transition test.

The recorded `lost_max=143` includes the boot history; it is not 143 dropped
frames in these fights. Snapshot equality is sampled every 30 refreshes;
the trace comparison does not prove equality of all game RAM.

## Reproduce

With current source tables, build and package to a private path:

```powershell
python build.py --asm-only
python makerom.py
python makevrom.py
python mamerom.py --no-install --output tmp/shadow_build/rom/mk2.zip
python tools/run_wasteland_shadow.py --rom-dir tmp/shadow_build/rom --map src/mk2.map --p1 4 --p2 10
python tools/run_wasteland_shadow.py --rom-dir tmp/shadow_build/rom --map src/mk2.map --native --expected-native-mode 2
```

The runner freezes its inputs and gives each MAME run private config, NVRAM,
state, input and snapshot directories. It rejects missing captures, trace
mismatches, differing pixels or new late frames. `--fast-mode 1` can reproduce
the exploratory full-fast comparison; differences are failures, not silently
accepted fixes. Repeat with the other numeric pairs above. Native checks use
`--stage 1` for Kombat Tomb and `--stage 3` for Tower, with an explicit
`--expected-native-mode`. The historical Tomb run in this receipt expected 0;
the [subsequent Tomb prototype](TOMB_SHADOW_PROTOTYPE.md) changes its default to 2.
Tower still expects 1.

The assembly build, ROM generation and private packaging succeeded. The build
reported the existing Boxlab export-freshness warning. Nothing was installed
into the shared MAME ROM directory.

This test does not cover every move, fatality, hidden fighter, boss, stage
transition, FBNeo/netplay or physical T-unit board. Those remain validation
work before generalizing the mode to more stages.
