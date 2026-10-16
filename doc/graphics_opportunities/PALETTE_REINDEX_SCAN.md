# Family-wide palette reindexing scan (opportunity 04)

14 September 2026. **Measured offline; nothing changed.** Family-wide
reindexing is worth about **14.4 KB** of video ROM in total, and most of that
sits in three families whose palettes are shared or index-sensitive.

## Question

The per-record screening in [sprite_screening.csv](sprite_screening.csv)
already showed that if every frame could be remapped to its own compact
palette, depths would drop by a lot. But the frames of an animation share one
palette. The real opportunity is a **family**: take the union of colour
indices used across every frame that shares a palette; if that union fits in
fewer bits than the family is stored at, reorder the palette once and pack
the whole family at the smaller depth.

## Method

Every record in `src/*.TBL` (deduplicated by SAG, size, control word) is
decoded out of the packed video ROM with `tools/art_identity_snapshot.py`'s
decoder and grouped by (table file, IRW) - roughly one character or effect
family. For each family:

- **union** - distinct indices used across all its frames, 0 included;
- **need** - bits to hold that many indices once reordered (0 stays transparent);
- **family saving** - per record, stored pixels x (its depth - need) / 8, where
  a compressed record's stored pixels are each row's span between its first
  and last non-zero pixel;
- **per-frame ceiling** - the same with each record's own union, i.e. what a
  per-frame remap could take if palettes were not shared.

Tables that mix palettes (MKFX, MKBGANI) are grouped as one family here, which
makes their unions pessimistic; see caveats.

## Result

| Family (table / IRW) | Frames | Depths now | Union | Need | Family saving | Per-frame ceiling |
|---|---:|---|---:|---:|---:|---:|
| MKBOLTS / MK7MIL (Raiden's bolts) | 291 | 3, 5, 6 | 28 | 5 | **6,067** | 33,248 |
| SHAOFIST / SHAOFIST (Kahn's fist) | 227 | 6 | 28 | 5 | **3,155** | 7,151 |
| JCFKICK / JCFKICK (Cage flying kick) | 29 | 6 | 30 | 5 | **1,563** | 1,677 |
| NOOBPORT / NOOBPORT | 23 | 5, 6 | 32 | 5 | **1,411** | 5,646 |
| VSART, HHHEADHO, FIREHAND, HHSWIPE, JCMK1BLD | 29 | 6 | 8-32 | 3-5 | 2,223 | 2,408 |
| Every other family | - | - | - | - | 0 | - |
| **All families** | | | | | **14,419** | **268,648** |

The main fighter tables all use their whole 64-entry palette across their
frames, so they gain nothing family-wide however much a single frame could:

| Table | Union | Family saving | Per-frame ceiling |
|---|---:|---:|---:|
| MKJC (Cage) | 64 | 0 | 12,265 |
| MKLK (Liu Kang) | 64 | 0 | 11,471 |
| MKNJ (ninjas) | 64 | 0 | 16,632 |
| MKST (Shang) | 64 | 0 | 5,614 |
| MKFX | 64 | 0 | 32,134 |
| MKBGANI | 64 | 0 | 12,370 |
| MKBLOOD | 64 | 0 | 7,092 |

So the large per-frame figures are unrealisable: they would need a palette per
frame, not per family.

## Caveats before any of the four real candidates

- **MKBOLTS**: the ambient victory bolts draw with Raiden's costume palette at
  fixed indices (the July 2026 handoff notes art indices 24/52/63 and `ELEC_P`'s
  53 colours). Reordering would have to keep those indices or retarget every
  palette the bolts are shown with.
- **SHAOFIST, JCFKICK**: sidecars with their own palettes; check every
  `swpal`/`player_swpal` target and alternate costume palette the frames are
  drawn with - all of them need the same reorder.
- **NOOBPORT**: already partly repacked at 5 bpp
  ([NOOBPORT_PROTOTYPE.md](NOOBPORT_PROTOTYPE.md)); it also carries body frames
  on Noob's own palette.
- Mixed-palette tables are pessimistic here: a split by palette could find
  small families inside MKFX/MKBGANI. That split needs each record's palette
  owner, which the TBLs do not always carry.

Each candidate is a palette reorder, a LOD/IMG remap and repack, and a
decoded-pixel plus MAME proof per palette it is drawn with.

## Lower depth without a reindex (15 September 2026)

The union above counts distinct indices. What decides whether a family needs a
reorder is its **highest** index. Where that fits fewer bits, a lower `PPP>` on
that LOD block is lossless and the palette is untouched. LOAD2 overrides a
block's `PPP>` whenever the palette record declares more colours than the
depth holds, so the palette's colour count has to fit as well.

| Family | Palette (colours) | Max index | Depth | Freed | MAME |
|---|---|---:|---|---:|---|
| SHAOFIST (Kahn's pulp) | blood5P (29) | 28 | 6 → 5 | 3,750 B | portal fatality 321/321, clap 72/72 identical |
| VSART `overselect` (VS stage plate) | OVERSEL_P (15) | 14 | 6 → 4 | 724 B (MOVEART1) | VS capture 3/3 identical |
| JCMK1BLD KHEART* (Cage's heart) | jtblood_p (12) | 11 | 6 → 4 | 800 B with FIREHAND (MOVEART2) | none: `jc_headhole_fatality_test.lua` never reaches the fatality on either build |
| FIREHAND HANDFLAME* (Scorpion's hand fire) | HNDFIRE_P (8) | 7 | 6 → 3 | (in the 800 B above) | 51/51 identical; the new build draws the 3000H headers |
| NOOBPORT body strips | NOOBDEF_P (64) | 8 | stays 6 | 0 | blocked: the 64-colour palette record makes LOAD2 override the depth |

Checks on all four sets:
- `tools/check_lod_packing.py` (Phase D) decodes every record from the shipped
  IRW at the depth its control word claims, requires the expected depth, and
  compares the pixels with the authored IMG.
- Art identity: the MOVEART build moved 38 records, all with identical pixels,
  and changed none.
- Every consumer draws through `qdma` with the header's control word, or through
  `ani`, never `ani0`. Each lane is a single depth, so no object carries the
  control bits of a deeper frame.
- `KHEART6B_OPEN`, the inline copy in MKDEATH.ASM, gets the new control word
  from `sync_jc_kheart_open.py`.

## The reorder candidates are closed (15 September 2026)

MKBOLTS, JCFKICK, HHHEADHO and HHSWIPE use indices above 31, so only a palette
reorder could shrink them. All four draw on a fighter's own 64-colour costume
palette. The fighter tables use all 64 entries (table above), so no reorder
exists short of re-indexing the whole fighter and every alternate costume.

| Family | Highest index | Drawn with |
|---|---:|---|
| MKBOLTS (Raiden's ambient bolts) | 63 | Raiden's **active costume** palette: `lgt_get_raiden_pal` (MKGUYS) deliberately avoids `ELEC_P`, because the art uses costume entries 62/63 and `ELEC_P` has 53 colours |
| JCFKICK (Cage's MK1 flip kick) | 63 | Cage's own lane `a_jcmk1fkick` (MKJC), on his player object |
| HHHEADHO (`TMDEADHEAD1-7`) | 48 | a piece in `HHHOLE1-7`, Kung Lao's headhole body, which "shares the body's bloody palette" |
| HHSWIPE (`HATSWIPE1-4`) | 46 | Kung Lao's own lane `a_hh_hat_swipe` (MKHH) |

Opportunity 04 is finished: 5,274 B from lossless lower depths
(SHAOFIST, VSART, JCMK1BLD, FIREHAND), and nothing is left that a reorder could
take.
