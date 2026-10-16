# Shared static multipart components (opportunity 30)

14 September 2026. **Measured offline; nothing changed.** Worth about
**10.9 KB** of video ROM as a lower bound, three quarters of it in one effect:
Shao Kahn's stone-crack frames.

## Question

A multipart frame is already a list of pieces, so a part of the picture that is
identical across several frames of an animation - an unchanged torso under
moving arms, a statue under spreading cracks - could be stored once as a shared
piece. How much of the art is like that?

## Method

[`tmp/multipart_share/row_share_scan.py`](../../tmp/multipart_share/row_share_scan.py)
measures the decomposition MK2's renderer supports with no new code: a
**horizontal split**. It decodes every record (deduplicated by SAG, size, control
word) through `tools/art_identity_snapshot.py`, groups records by
(table, IRW, width, height), and for each record counts the rows that are
pixel-identical to the same row of an earlier record in its group. Only runs of
at least **8 rows** count, and each run is charged **14 bytes** for the extra
piece (record header and setup). The saving per run is the stored bytes of
those rows - the span between each row's first and last non-zero pixel, at the
record's depth.

It is a **lower bound**: pieces that move between frames, vertical splits and
arbitrary rectangles are not considered.

## Result

697 groups have two or more same-size frames. Estimated saving: **10,949 bytes**.

| Table | IRW | Bytes | What it is |
|---|---|---:|---|
| MKSK | MK5MIL | **8,322** | Kahn's statue: `STONEBODA/B`, `BGSTONECRACK2A/B`, `4A/B` - the same 44-45x150 body with only the cracks changing (up to 1,965 B per frame) |
| SCORAREA | MK6MIL | 718 | the 17x30 battle-number digits |
| MKBGANI | MK6MIL | 487 | background animation frames (e.g. `timemonk5`) |
| MKHH | MK2MIL | 431 | Kung Lao (e.g. `TMSTANCE5B`) |
| TIMEFLR | TIMEFLR | 290 | Outer Haven stair tiles |
| MTNSKUL | MTNSKUL | 171 | Yoteigai Tor's skull splash |
| MKLK, MKST, MKJX, MKFRIEND, MKSA, MKTEXT | | 530 together | fighter and text frames |

Fighter tables share almost nothing: consecutive poses differ on nearly every
row. This agrees with the other storage scans - the compressed art is already
at LOAD2's optimum ([COMP_POLICY.md](COMP_POLICY.md)), every fighter family uses
its whole palette ([PALETTE_REINDEX_SCAN.md](PALETTE_REINDEX_SCAN.md)), and LOAD2
already crops ([CROP_SCAN.md](CROP_SCAN.md)).

## The one real candidate, measured (15 September 2026)

`tmp/stone_share/stone_scan.py`, plus a crack-only pass, overlaid every
stone-crack frame on the plain statue. The statue is `STONEBOD` (MKSK.ASM),
two pieces of 44×149 and 45×150, with the same geometry as the crack frames
(`a_stone_crack`, entry 16 of Kahn's animation table, played from art in
BOSS7.IMG).

- **The cracks are recolouring.** Almost every changed pixel goes from opaque
  to opaque with a different colour index. An overlay piece, which writes
  only non-zero pixels, draws that exactly.
- **The exceptions are all on the statue's outline.** Two positions in
  piece B are opaque on the statue and transparent in frames 4-7: (34,37) in
  4B-7B and (5,5) in 5B and 6B. A few outline pixels are added, which an
  overlay also handles. An overlay cannot erase, so an exact version uses a
  shared base without those two pixels and a 2-pixel restore patch where
  they are wanted.
- **Frames 5, 6 and 7 are not duplicates.** Their pixels differ; only the
  count of changed pixels is the same.
- **Frame 3's A/B split sits one column over** (43 and 46 wide), so it does
  not line up with the statue's pieces. It is left out of the estimate.

**Bytes.** For frames 1, 2 and 4-7, both pieces: 32,472 B now becomes
12,754 B as crack-only patches over the statue. Each patch is cropped to its
changed pixels, uses the best compressed encoding, and is charged 14 B for its
record. That is **19,718 B** of MK5MIL, more than twice the row-share lower
bound above.

**Side effects.** Each frame becomes 4 pieces (Kahn's shape RAM holds 11).
Collision is unchanged: the patches lie inside the statue's bounds, and
`perpiece` is 0. A patch's shadow draws the same black over the statue's own.

## Built (15 September 2026, with sign-off)

The user approved the pixel-exact version. What changed:

- **`tools/make_stonecrk_img.py` writes `data/STONECRK.IMG`** from BOSS7.IMG:
  - `STONEBASEA` is exactly `STONEBODA`, packed with the palette directive
    (`PON>`) and carrying `BGSTONE_P`. It is the first piece of frame 1,
    because `make_kahn_obj` (MKFX.ASM) takes the palette off that record.
  - `STONEBASEB` is `STONEBODB` with the two outline pixels cleared that some
    crack frame makes transparent, (5,5) and (34,37).
  - `STONEPAT1A`-`7B` are the crack-only patches for frames 1, 2 and 4-7.
- **The generator proves every frame before it writes.** For all 12 crack
  pieces, base plus patch composites exactly to the original piece. It runs
  as a Phase D check in build.py.
- **`data/MK5MIL.LOD`** no longer packs BGSTONECRACK1/2/4-7 A+B or
  STONEBODA/B; STONECRK.IMG is packed in their place. Frames 3 and 8 are
  unchanged.
- **`src/MKSK.ASM`**: frames 1, 2 and 4-7 are the base followed by that
  frame's patches, 4 pieces each. **`src/MKSK.TBL`** gains the 14 new records
  and loses the 14 old ones. The MKSK records are added and removed by hand
  because `sync_mksk_mk5.py` only rewrites records that already exist.

**Proof, whole-ROM decode** (`tools/art_identity_snapshot.py`, before vs
after): 14 records added and 14 removed, as intended, and 82 records moved
with pixel-identical art.

The compare also reported 8 records of `MKRDWALK.TBL` as CHANGED. That is a
false alarm. The table was retired on 2026-09-09 and no ASM includes it (see
the note in MK5MIL.LOD). Its stale SAGs now land on moved art, and the tool
counts it as "used" only because MKRD.ASM defines its own `RNWALK1` frame
lists under the same names. Raiden's walk art is in MK3MIL and is untouched.

**A bug found on the way: the stone explosion's first chunk frame.**
`KAHNBIG1` and `KAHNLIL1` (MKSK.ASM) are hand-written copies of `BIGSTONE1`
and `LILSTONE1` that add `STONE_P`. They are the first frame of each flying
chunk. Their literal SAGs (038010a6h / 03805dc6h) pointed into other stone
art: they decoded to 201/483 and 52/99 opaque pixels, not the chunks, and the
repack would have moved them onto different wrong pixels. They are now
anchored to `BIGSTONE1` / `LILSTONE1` in `tools/sync_inline_sags.py`, with the
pixel hash recorded, and decode identically to those records (346 and 83
opaque pixels). This is a visible fix: the first frame of each chunk now
shows the chunk.

**Space.** From `tools/rom_space_report.py`: MK5MIL's free run in bank 0 grew
from 27,914 to 42,466 bytes, so **14,552 bytes of video ROM were freed**
(bank 0 free went from 107,760 to 122,312). That is less than the 19.7 KB
estimate above: LOAD2's real encoding of the 14 new records costs more than
the estimator charged.

**MAME, the ending itself** (`tools/run_kahn_stone_capture.py`: a one-player
game that beats a CPU Shao Kahn 2-0 and records his turn to stone frame by
frame, on the build before the repack and on this one): **PASS.**

- Both boots reached the ending on the same frame. The rig arms on
  `dlists_bogus`, the black background `boss_die_sequence` switches to just
  before the stone Kahn appears.
- On the new build all 8 animation frames are the stone frames by label:
  frames 1, 2 and 4-7 are `STONEBASEA`, `STONEBASEB` and that frame's
  patches, and frames 3 and 8 are unchanged.
- All 8 captures are **pixel-identical** to the pre-repack ROM, and so are the
  40 explosion captures that follow.

Those 40 explosion captures do not show the chunk fix, because the chunks'
first frame was not among them; that fix rests on the decode proof above.

A first version of the rig armed on the wrong game state: `gs_pfsetup` (6)
instead of `gs_gameover` (0Bh). It recorded round 2 of the fight and "passed"
on that. The runner now fails unless both boots arm on the stone sequence
and the new build's frames are stone art by label.

Build: `build.py` (Phase A LOAD2) plus an asm-only rebuild for the anchor
fix, with all Phase D guards passing. Private package
`tmp/stone_share/build2`, not installed.
