# Transparent-border crop scan (opportunity 06, crop half)

13-14 September 2026. **Closed - measured, not worth doing.** Offline only;
nothing was changed.

## Method

[`tmp/crop_scan/crop_scan.py`](../../tmp/crop_scan/crop_scan.py) reuses
`tools/art_identity_snapshot.py`'s packed-ROM layout and decoder. For every
record in `src/*.TBL` (deduplicated by SAG, width, height and control word) it
decodes the pixels, finds fully transparent rows at the top and bottom and
fully transparent columns at the left and right, and reports:

- the drawn area now and after a crop (what the DMA is billed for);
- an estimate of the stored bits after re-encoding the cropped rectangle with
  the record's own rules (same depth, compressed flag, lead/trail shifts);
- an **encoder-independent upper bound**: border pixels x stored depth. No
  encoder can save more than the pixels it stops storing.

## Result

| | |
|---|---:|
| Records decoded | 9,832 (98 undecodable) |
| Records with any transparent border | 326 |
| Records that are entirely transparent | 0 |
| Estimated bytes saved by cropping all 326 | **487** (436 in referenced art) |
| Upper bound, any encoder | **11,567** (10,710 referenced); largest single record 1,115 |
| Drawn area removed | 16,512 of 26,269,342 pixels (0.06%) |

Almost every hit is a single blank column on the right of a compressed
sprite, where the trailing-run shift already skips most of it. LOAD2 crops at
build time; what is left is rounding. Each crop would also be a header edit
(anipoint moves by the left/top amount) plus a repack of its run, with a
decoded-pixel proof - far more work and risk than 487 bytes, and no
measurable DMA time.

## Not covered

The **multipart partition** half of opportunity 06 (splitting sparse shapes
into pieces or merging pieces, trading stored bytes and drawn area against
per-piece setup) is measured separately in
[PARTITION_SCAN.md](PARTITION_SCAN.md). Merging never pays. Splitting saves
DMA time per draw but only ~0.5% of a frame on average, so it is not worth
doing.

Per-record output: `tmp/crop_scan/crop_scan.csv`, summary `tmp/crop_scan/summary.json`.
