# Shared sub-pieces at any offset (follow-up to opportunity 30)

19 September 2026. **Measured offline; nothing changed.**

## Question

[MULTIPART_SHARE_SCAN.md](MULTIPART_SHARE_SCAN.md) counted rows that are
identical at the *same position* in *same-size* frames, and called itself a
lower bound: "pieces that move between frames, vertical splits and arbitrary
rectangles are not considered." This scan covers those cases. Could the
existing multipart pieces be cut into better sub-pieces, so that art common to
two frames is stored once?

## Method

[`tmp/subframe_share/subframe_share_scan.py`](../../tmp/subframe_share/subframe_share_scan.py)

- **Scope:** every record that appears in a multipart frame list (5,939 labels,
  6.40 MB stored). Records are deduplicated by SAG, so LOAD2's own folds are
  not counted twice. Pairs are only formed within one family: a TBL name with
  trailing digits stripped, so MKSA and MKSA2 are one family. This keeps the
  pair on one palette.
- **Finding candidates:** the scan hashes 8x4 pixel windows and samples them by
  content, so the sampling is the same wherever a window sits in its piece.
  Matching hashes vote for a translation (dx, dy) between two pieces.
- **Exact split:** for each candidate, the common pixels
  C = {A(p) == B(p+d) != 0} become a shared piece S, and A and B keep their
  residuals with C zeroed. The result is exact: the pieces are disjoint and
  nothing has to erase.
- **Cost:** LOAD2's row encoding at the best lead/trail multipliers, plus 14 B
  for each extra piece. The stone-crack build came in at 74% of the same kind
  of estimate, so expect roughly that.
- **Totals:** each piece is used in at most one pair, chosen greedily. This is
  conservative. A star layout, with one base and many patches, can beat it; the
  stone crack was built that way.

## Result

| window sampling | pairs | greedy saving |
|---|---:|---:|
| 1/8, >= 4 votes | 90 | 28.6 KB |
| 1/4, >= 2 votes | 279 | 42.5 KB |
| 1/2, >= 2 votes | 378 | **49.8 KB** (converging) |

The saving is concentrated in a few pairs:

| pair saving | pairs | bytes |
|---|---:|---:|
| >= 400 B | 21 | **18.6 KB** |
| 200-399 B | 38 | 9.6 KB |
| < 200 B | 319 | 21.6 KB |

Most of the long tail is scattered: the frames share a limb or part of the legs
while pixels in between differ. LOAD2 stores each row as a single span from the
first non-zero pixel to the last, so pulling out the middle of a row saves
almost nothing. For these pairs, a new piece and a MAME proof cost more than
the ~100 B each one saves.

### The worthwhile ones

- **Flip kick / flip punch, frames 1 and 2, every fighter** (26 pairs,
  15.5 KB). `a_??flipkick` (ani 1eh) and `a_??flippunch` (ani 1fh) are the
  angled jump attacks, `do_flip_kick`/`do_flip_punch` in MOVES.ASM. Their
  wind-up frames 1 and 2 share a 60-90 x 45-56 body block, usually at d=(0,0).
  Biggest pairs: `TMFLIPKICK1A/2A` 1,475 B, `NJFLIPKICK1A/2A` 1,432,
  `LKFLIPKICK1A/2A` 1,353, `NJFLIPUNCH1B/2B` 1,204, `KTFLIPKICK1A/2A` 1,147,
  `JXFLIPUNCH1C/2B` 1,095, `TMFLIPUNCH1B/2B` 1,029, `JXFLIPKICK1A/2A` 915. Each
  frame gains 1 piece, and none goes above 5 (fighter limit 8).
- **Kahn's stone-crack frame 3** (2 pairs, 2.7 KB). `BGSTONECRACK3A/B` against
  `STONEBASEA/B`. It was left out of the 15 Sep repack because its A/B split
  sits one column over. The scan finds it at d=(-1,0), so `make_stonecrk_img.py`
  could take it as one more patch.
- Smaller ones: `JCSTANCE3A`/`JCWALKTORSO1A` 744 B, `tornado2B/8B` 603 B,
  `KTHIPUNCH3A`/`KTLOPUNCH2A` 474 B, `RNBEAMUP5A/6A` 406 B.

## Verdict

Of an upper figure of ~50 KB, about **18.6 KB is in pairs worth cutting**, and
about 14 KB of that would likely survive LOAD2's real encoding. Nearly all of
it is the flip kick/punch wind-ups and one more stone frame. That is
significant at the time of writing: video free space is 39,920 B, and the
largest single run is 3,936 B.

Each saving appears as a larger tail gap in the IRW that holds the art
(MK2-MK5MIL), not as one contiguous block.

**Per-pair cost:**

- New IMG pieces, cut and proven in the way `make_stonecrk_img.py` does it.
- LOD and TBL edits, and a frame-list edit in each fighter's ASM.
- One more blit, plus its shadow, per affected frame.
- Collision is unchanged while `perpiece` = 0.

Fighter art otherwise has no large shared blocks left to find.
