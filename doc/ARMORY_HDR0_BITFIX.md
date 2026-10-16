# Armory Header-0 Bit Fix

Date: 2026-07-08

## Symptom

The Armory stage loaded after relocation, but the repeated lava/metal strip in
front of the tubs was still garbled. In BDDTool this asset is:

- `ARMORY1.BDD` / `ARMORY1.BDB`
- image `0x00`
- size `108x36`
- palette index `2`
- used repeatedly across the steel-tub layer

In runtime tables this is `ry1HDRS[0]`. It is placed by `ARM2BLKS` and appears
in-game on `baklst4`.

## Root Cause

This was not a `VAT`/`LAVA_P` palette-table corruption. Palette index `2` does
map to `VAT`, but the broken part was the compressed BLIMP bitstream for
`ry1HDRS[0]`.

The comparison that isolated it:

- current generated MK7 Armory stream: `data/MK7MIL.IRW` + `tmp/load2/BGNDTBL.MK7`
- relocated Armory stream: `data/ARMORYCS.IRW` + `src/BGNDTBL.ASM`
- readonly reference stream: `..\mk2-readonly\mk2-main\data\MK7MIL.IRW` +
  `..\mk2-readonly\mk2-main\tmp\load2\BGNDTBL.MK7`

All measured Armory image intervals matched the readonly reference except
`ry1HDRS[0]`. That image differed by exactly one bit: the first compressed
control bit was `1` in the current stream and `0` in the readonly stream. A bad
first control bit corrupts the whole 108x36 image decode, which matches the
visual symptom.

## Fix

As of 2026-07-16, the temporary `ARMORYCS`/COMESOON relocation is retired.
`tools/fix_armory_mk7_bg.py` now:

- restores the normal Armory records from `tmp/load2/BGNDTBL.MK7`;
- keeps `ry1HDRS` in the ordinary MK7 Armory payload range;
- clears the first compressed bit of `ry1HDRS[0]` directly in
  `data/MK7MIL.IRW` after LOAD2;
- supports `--check` so the build fails if either the table records or repaired
  bit drift.

Do not hand-edit `data/MK7MIL.IRW`; rerun the repair tool or the normal
`python build.py` pipeline.

## Verification

Build/test run:

```powershell
$env:ALLOW_STOCK_BG_DRIFT='1'
python build.py
python makerom.py
python makevrom.py --debug-bin
python mamerom.py --no-install
```

Fresh stage-test Lua:

- `tools/armory_header0_bitfix_direct_load_20260708.lua`
- log: `tools/armory_header0_bitfix_direct_load_20260708.log`

Original relocated-sidecar result:

- `final_status=PASS_RELOCATED`
- all 25 Armory headers relocated into the retired `COMESOON` window
- `baklst4` reports five live `hdr0_strip` objects at `osag=0x05E43419`
- snapshots `snap/mk2/0914.png` through `snap/mk2/0917.png` show the strip
  rendering cleanly

The in-place MK7 repair preserves the same corrected bit while returning the
retired COMESOON window to the free-space ledger. A fresh build and live visual
proof should be recorded after this pipeline retirement.
