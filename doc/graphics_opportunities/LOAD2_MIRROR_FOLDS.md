# LOAD2 folds mirrored images as duplicates

Found 15 September 2026 while repacking the fist pulp at 5 bpp
([opportunity 04](../GRAPHICS_OPPORTUNITIES.md)). **Four drawn sprites show the
wrong picture in the shipped ROM**: LOAD2 stored them as duplicates of images
that are their mirror, or, in one case, a different image.

## What LOAD2 does

When two records in one LOD pack to the same bytes, LOAD2 stores the pixels
once and gives both table records the same SAG. Its log reports this as
"Skipped N duplicate bytes in M foreground checksum matches". The match is a
checksum, and it evidently also matches a horizontally or vertically mirrored
image. The second record's control word carries no flip bit, so the game draws
the first image's pixels for it: a mirror of what was authored.

The raw LOAD2 output confirms this is LOAD2 itself, not the table promoter.
In `tmp/load2/SHAOFIST.TBL`, `FISTPULP4W` already has `FISTPULP4V`'s SAG
`05fd0d32`.

## Why nothing caught it

[BLEED_SCAN](BLEED_SCAN.md) compares packed pixels with the authored IMG, but
it first deduplicates records by SAG, size and control word, so the second
label of a fold is never decoded. Art identity hashes each record's stored
pixels, which are the same before and after, so it cannot see it either.

## The scan

`tmp/fold_scan/fold_scan.py` maps every table label to its authored IMG by
walking the LODs `data/IMGBUILD.BAT` builds: 53 LODs, 9,913 labels. It then
groups the promoted records by SAG, size and control word, and compares every
label's authored pixels within a group.

| Result | Pairs |
|---|---:|
| Folded pairs whose authored pixels are identical (correct) | 223 |
| Horizontal mirror | 1 |
| Horizontal + vertical mirror | 2 |
| Different image | 1 |

| Label drawn wrong | Stored pixels are | Relation | Size | Drawn by |
|---|---|---|---|---|
| `SHAOFIST.TBL:FISTPULP4W` | `FISTPULP4V` | H mirror | 9×6 | Kahn's portal-punch pulp, frame 4 shape list (`ani2`) |
| `MKSK.TBL:LILSTONE5` | `LILSTONE1` | H+V mirror | 9×11 | Kahn's stone explosion chunk, `a_lilstone` (`explode_piece` → `next_anirate` → `ani`) |
| `MKFX.TBL:smfirebone6` | `smfirebone3` | H+V mirror | 9×14 | Toasty fire bones, `a_lil_bone` (`blood_fall` → `next_anirate` → `ani`) |
| `TIMEFLR.TBL:timefloor4A` (the scan first blamed `timefloor2D`; see below) | `timefloor2D`, padded to 3 wide | different: `[0,5,6 / 8,8,8]` drawn as `[6,5,0 / 8,8,0]` | 3×2 | Outer Haven staircase view 4 (`ani2`) |

The three mirror folds all draw through `ani` or `ani2`, which XOR a header's
own flip bits with the object's facing ([Raiden head
roll](FLIPREUSE_PROTOTYPE.md)). A mirrored alias header on the stored pixels
therefore draws each authored image exactly. `timefloor2D` is not a flip: its
table geometry is stale as well, so it needs its own record.

## Fixes

**15 September 2026: three of the four are fixed; built, not installed
(`tmp/folds`).** Each wrong label now draws a hand-written alias header. It
points at the stored pixels, sets the mirror in its own control word, and is
anchored in `tools/sync_inline_sags.py` with a pixel hash. The promoted table
records are untouched, so a LOAD2 re-run cannot undo the fix.

| Alias | Header | Anchor | Why that anchor |
|---|---|---|---|
| `FISTPULP4W_MIRROR` (MKSK.ASM, frame 4 of the pulp) | 9×6, `FISTPULP4V`'s SAG, `05010h` (5 bpp, H flip) | (67, −201), 4W's own | `ani2` places a multipart piece by the anchor of the image as drawn |
| `LILSTONE5_MIRROR` (MKSK.ASM, `a_lilstone` frame 5) | 9×11, `LILSTONE1`'s SAG, `06030h` (H+V) | (4, 5) | single-object `ganiof` mirrors an anchor to (w−1−x, h−1−y); (4, 5) is its own mirror in 9×11 |
| `smfirebone6_mirror` (MKFX.ASM, `a_lil_bone` frame 6) | 9×14, `smfirebone3`'s SAG, `06030h` (H+V) | (4, 6) | the same mirror of the authored (4, 7) in 9×14 |

- **Proof, offline.** Each header was read back out of the linked program ROM
  (`rom/mk2_flat.bin`). Decoding the pixels at its SAG and applying its flips
  gives exactly the authored `FISTPULP4W`, `LILSTONE5` and `SMFIREBONE6`.
- **Guard.** `sync_inline_sags.py --check` (Phase D) passes for all 22
  hand-carried headers. It also requires each alias, with its anchored SAG and
  control word, to be present in the linked `src/mk2.out`.
- **Draw paths.** All three draw through `ani2` or through single-object
  `ani`, both of which XOR a header's flip with the facing. That path was
  proven in MAME on Raiden's head roll ([flip reuse](FLIPREUSE_PROTOTYPE.md)).
- **`timefloor4A`, not `timefloor2D`** (Outer Haven staircase, view 4). LOAD2
  pads any image narrower than `MIN_IMG_WIDTH` (3, `load2.h`) to that width,
  reading the extra column from the IMG's row stride. So the 2×2 `timefloor2D`
  was stored first, as `[6,5,0 / 8,8,0]`, at SAG `05f03c45`. Decoding the IRW
  shows exactly that, and it draws 2D correctly with a transparent third
  column. The 3×2 `timefloor4A` (`[0,5,6 / 8,8,8]`) then checksum-matched it
  and was given the same SAG. Both raw LOAD2 table records say 3×2 at that
  SAG, which is why the scan's "stale 3×2 geometry" reading looked plausible.
  No flip of the stored image equals 4A (its bottom-left 8 is missing), so an
  alias cannot fix it. The fix is `COF>` around `timefloor4A` alone in
  `data/TIMEFLR.LOD`, so LOAD2 stores its own 30 bits.
  `tools/check_lod_packing.py` now models the padding and checks TIMEFLR. On
  the unfixed build it fails on `timefloor4A` and nothing else.
  **Built 15 September 2026 (`tmp/timeflr`, not installed).** After the build:
  - 4A has its own SAG (`05f094d9`), and the rest of view 4 onwards moved by
    exactly 30 bits;
  - check_lod_packing passes all 90 TIMEFLR records;
  - art identity: 1 changed (`timefloor4A`), 60 moved with identical pixels.

  MAME, Outer Haven staircase sweep (`tools/outer_stair_probe.lua` with
  `MK2_STAIR_SNAP_ALL=1`, the previous build against the fixed one): 16 of 18
  captures are identical. The other two differ in one 3×2 box each, one per
  facing (x 251–253 and 154–156, y 157–158), where view 4 draws
  `timefloor4A`. The probe passes on both builds and sees the same views.

`tools/check_lod_packing.py` keeps `FISTPULP4W`'s fold in `KNOWN_FOLDS` as an
exact expectation, because the table record it checks is still folded.

### MAME, fixed build vs the build before it

- **`LILSTONE5`** (Kahn's turn-to-stone ending): pass. The stone capture rig's
  own tail starts after the chunks stop animating, so it can't see frame 5. A
  per-object trace across the explosion (`tmp/folds/run_stone_witness.py`,
  frames 7150-7600) settles it: both builds arm on the same frame, and the
  fixed build draws frame 5 as SAG `037f969c` with both flip bits set 44 times,
  the old build 0 times. All 88 chunk samples match in position and size.
- **`FISTPULP4W`** (the pulp's frame 4): the only captures that differ from the
  pre-fix build before the round end are captures 38-44. Each differs in one
  9×6 box at the speck.
- **`smfirebone6`**: no MAME scene run. The offline decode above is exact, and
  its draw path (`blood_fall` → `next_anirate` → `ani` with the flip XOR) is the
  one already proven in MAME on Raiden's head roll.
- **The portal scene diverged later, but not because of the fix.** Kahn's
  Portal Punch fatality had a pre-existing hang: the iris process died one word
  deep on the stack. Whether the round froze depended on memory contents, so
  adding three data headers flipped it. In `folds` it didn't freeze, but the
  arena drew shifted with purple garbage at frame 1741, the iris ring stayed on
  screen, and the FATALITY letters never appeared. The hang is fixed in
  MKZAP.ASM (see the comment at `kbfdrc_quit`). On the fixed build the round
  completes with the same timing, FATALITY drips in, no garbage or stray ring
  remains, and the scene is identical to `folds` through frame 1741.
