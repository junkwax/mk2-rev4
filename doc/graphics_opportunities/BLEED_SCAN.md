# Built art vs authored art: LOAD2 stray-bit scan

14 September 2026. Follows the `JXSPLIT9A` repair in
[COMP_POLICY.md](COMP_POLICY.md). **Two records repaired at build time; two
pit-blood decals left open.**

## Question

LOAD2 sometimes ORs stray bits into the last rows of a compressed record, and
which pixels depends on where the record lands, so it moves whenever the art
before it grows or shrinks. `JXSPLIT9A` was the only known case. How many
shipped records are affected?

## Method

[`tmp/bleed_scan/bleed_scan.py`](../../tmp/bleed_scan/bleed_scan.py) maps each
`src/*.TBL` label to its IMG by walking the LODs `data/IMGBUILD.BAT` runs (an
`X.IMG` line, then `--->` label lists). It decodes each record (deduplicated by
SAG, size, control word) out of the packed video ROM, reads the same image
out of the authored IMG, masks the authored indices to the record's bits per
pixel, and counts differing pixels. It also notes whether a record's
differences only ADD bits (`rom & ~authored`) and whether they sit in its
last six rows - the shape of the known bleed.

| | |
|---|---:|
| Records compared | 9,593 |
| No LOD `--->` label | 239 |
| Label found but no same-size image in its IMG | 79 |
| Outside the shipped ROM / undecodable | 4 / 15 |
| **Records whose pixels differ from the authored IMG** | **13** |

## What differs

| Record | Pixels | Shape | Verdict |
|---|---:|---|---|
| `MKSPLIT.TBL:JXSPLIT9A` (MK6MIL) | 4 | added bits, last rows | **bleed - repaired** |
| `MKST.TBL:STNUTCRUNCH1B` (MK3MIL) | 6 | all 3 -> 0, rows 116-120 of 121 | **bleed - repaired** |
| `MKBGANI.TBL:pitblood1b` (MK6MIL) | 3 | authored 4 -> stored 15, column 2, rows 33-35 of 43 | open - not the bleed shape; not repaired |
| `MKBGANI.TBL:pitblood1a` (MK6MIL) | 159 | rows 25-32 of 33 only, values swapped both ways (4<->0, 4<->11, 14<->4 ...) | open - a garbled tail, a different fault; both decals are drawn by the Pit fatality (`MKFALL.ASM`) |
| `UMK3FIRE.TBL:UMK3SKEL*` (10 records) | 3,895-12,274 each | decode into unrelated IRWs | not a defect - UMK3FIRE is built but not shipped (`makevrom` skips it), so its table SAGs are stale |

So the bleed proper is **rare**: two records in the whole ROM.

## Repair

[`tools/fix_load2_bit_bleed.py`](../../tools/fix_load2_bit_bleed.py) now lists
`JXSPLIT9A` and `STNUTCRUNCH1B`. It runs as Phase B2e2 (`--apply`) and in
Phase D (`--check`), rewrites only the differing pixel values from the
authored IMG inside each record's own bits, and refuses on a size mismatch, a
bad row header, another record inside the range, or more than 16 differences.
`pitblood1b` is deliberately **not** listed: its sibling shows MKBGANI's
authored pixels are not proven to be the intended ones.

Applied to the current IRWs, then `makevrom.py` and a private package
(`tmp/bleed_scan/build/rom/mk2.zip`, not installed). Rescan afterwards: 12
records differ, **0 bleed-like** - only the pit-blood pair and the stale
UMK3FIRE tables remain. Both repaired records are 0 px from their authored art.
Not checked in MAME; the evidence is the decoded ROM pixels.

## The pit-blood pair: wrong in ROM, never drawn

Rendered side by side (`tmp/bleed_scan/pitblood1*_authored_rom_diff.png`):

- **`pitblood1a`: the packed record is wrong, MKBGANI.IMG is right.** The IMG
  has a clean splatter; the ROM's last eight rows are a visibly scrambled block.
  A LOAD2 packing fault bigger than the one-bit bleed.
- **`pitblood1b`**: the 3 differing pixels are one short column inside the
  splatter (index 4 authored, 15 stored); both versions read the same.

**Neither is ever on screen.** The Pit fatality (`fall5`, MKFALL.ASM) creates
each decal object with `movi pitblood1a,a5 / gso_dmawnz` only as a seed, then
`ani_flag` swaps it to the image named in `blood_spots` - which lists only
`pitblood2a` and `pitblood2b` - before `insobja8` puts it on a display list.
`pitblood2a/2b` decode pixel-exact. `pitblood1b` has no reference at all
beyond its `.global` in MAINEQU.ASM and its TBL record.

So no repair: the only defective pixels in the scan that are not repaired
cannot be seen. `pitblood1b` is an unused-art candidate (31x43 at 4 bpp,
compressed); removing it would go through the usual dead-art approval.

Per-record output: `tmp/bleed_scan/bleed_scan.csv`, summary `tmp/bleed_scan/summary.json`.
