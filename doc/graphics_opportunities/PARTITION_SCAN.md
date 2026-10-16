# Multipart partition scan (opportunity 06, partition half)

15 September 2026. **Measured; low value. Merging never pays; splitting pays
per draw but is small per frame.** Offline only; nothing was changed.

## The cost model

The DMA bills every **programmed** pixel, not just the pixels it writes.
FBNeo's `midtunit_dma.h` sets the busy timer to `41 * pixels`, where
`pixels = width * height`. That count includes the leading and trailing
transparent runs a zero-compressed row skips; the skip changes only the draw
loop's bounds. Every queued blit also costs a fixed 4-8 µs of setup: the
queue cell, the interrupt and the register copy. The measured average is
11.4 µs, about 280 pixels' worth
([object queue budget](../GRAPHICS_OPPORTUNITIES.md)). So one frame drawn once
costs:

    cost = sum(piece w x h) + pieces x OVH        (pixel-equivalents)

The scan was run at OVH = 150 px (6 µs) and OVH = 280 px (11.5 µs).

## Method

[`tmp/partition_scan/partition_scan.py`](../../tmp/partition_scan/partition_scan.py)
takes every zero-terminated `.long A,B,...,0` frame list in `src/*.ASM` whose
entries are all TBL records: the lists `ani2` walks. It places each piece at
`(-anix, -aniy)` and decodes it through `tools/art_identity_snapshot.py`. Then
it scores three changes:

| Change | Saving |
|---|---|
| merge all pieces into the frame's bounding box | `cost - (bbox + OVH)` |
| merge the best two pieces | `a1 + a2 + OVH - bbox12` |
| split each piece once, at its best row or column, both halves cropped to their own pixels | `a - (aA + aB) - OVH` per piece |

For merges it also re-encodes the composited rectangle, with the best
lead/trail shifts, to get the stored-byte change.

## Result

2,468 unique multipart frames (3 undecodable). Pieces per frame: 1 → 380,
2 → 1,136, 3 → 698, 4 → 231, 5 → 13, 6 → 6, 7 → 3, 8 → 1. Programmed area is
16.47 M pixels, of which 7.34 M (45%) are opaque.

| | OVH 150 px | OVH 280 px |
|---|---:|---:|
| Total cost, all frames drawn once | 17.34 M | 18.09 M |
| Best saving per frame, summed | 3.63 M (21%) | 3.10 M (17%) |
| Frames that save ≥ 1 µs / ≥ 5 µs | 2,308 / 2,209 | 2,254 / 2,145 |
| Best change is a split / whole merge / pair merge | 2,254 / 57 / 25 | 2,076 / 121 / 73 |
| Largest single frame | 371.5 µs | 355.5 µs |

**Merging is never worth it.** It wins on only 82-194 frames, and each win
is small. Merging every frame would add **1.39 MB** of video ROM, because a
merged piece stores the gaps between pieces.

**Splitting** wins on nearly every frame, because a posed limb leaves a
large transparent rectangle. The spot check: Jax's `JXLOPUNCH4B` is 72×138
(9,936 px) with 2,695 opaque pixels, a thin extended arm across the top of a
body on the left. Cut at column 26 into two cropped halves, it saves 5,562 px
net of one blit.

Top frames (OVH 280):

| Frame | Pieces | Area | Best | per draw |
|---|---:|---:|---|---:|
| `LKDRAGON15` (MKLK) | 3 | 27,922 | split | 355 µs |
| `NJSCORPTHRO4` (MKNJ) | 2 | 15,092 | split | 330 µs |
| `BGNUPOWER4` (MKSK) | 3 | 15,060 | split | 320 µs |
| `BGSONICLAP5` (MKSK) | 3 | 16,786 | split | 308 µs |
| `JXLOPUNCH4` (MKJX) | 2 | 15,060 | split | 303 µs |
| `JXLOKICK6` (MKJX) | 2 | 17,136 | split | 297 µs |
| `LKDRAGON14` (MKLK) | 3 | 24,075 | split | 296 µs |
| `TMKNOCKDOWN2` (MKHH) | 2 | 18,964 | split | 290 µs |
| `JCLOPUNCH1` (MKJC) | 2 | 13,733 | split | 283 µs |
| `FATNINJA2` (MKDIE) | 2 | 17,480 | split | 277 µs |

Per-frame output is `tmp/partition_scan/frames.json`, and the summary is
[partition_scan_summary.json](partition_scan_summary.json).

## What it is worth

Averaged over all frames, the best change saves 1,256 px ≈ **51 µs per
fighter frame**. Two fighters come to about 100 µs, or **0.56%** of the
18.28 ms frame. The worst poses save 240-355 µs each, 1.3-1.9% of a frame,
and only while that pose is on screen. Stages normally finish their DMA with
about 25% of the frame to spare: stock THE DEAD POOL's last blit starts at
74-76%. THE TOWER was the tight one, at 86-90%, before its fixes.

## Why it is not being done

- **The cost model is the emulators'.** FBNeo's formula is confirmed from
  source. MAME's was not re-read here (its T-unit video file has moved), but
  the earlier MAME timeline measurement on THE TOWER agreed with billing the
  programmed area. Real hardware may skip zero-compressed margins faster
  than 41 ns a pixel; if it does, most of this saving disappears.
- **Shadows.** On every fightable stage (`shad_fast`, row 01), a piece's
  shadow costs 2 blits. So a split adds 3 blits in all (body plus 2 shadow)
  and saves about 1.25× its body area, because the shadow is the body at a
  quarter of the height. A 5,000 px split still nets about +5,400 px, but
  small splits go negative.
- **Collision is unchanged,** because `perpiece` is 0. The shipped hit test
  uses `mpart_bounds`' union of the pieces (JOY.ASM `stck`), and cropped
  halves cover exactly the original piece's pixels. With `perpiece` on, the
  per-piece test (`piece_overlap`) would get tighter.
- **The work is art work.** It means re-authoring pieces in the IMG and LOD
  files, adding frame-list entries, setting each half's anipoint, and proving
  the pixels are identical. The fighters' shape RAM holds 11 pieces
  (`p1_ram`), so any frame could take a split; the largest has 8 pieces.

If a scene ever becomes DMA-bound, the candidates are the top 50 or so poses
above: extended punches and kicks, Liu Kang's dragon, and Kahn's power-up and
sonic clap. That is where to start.
