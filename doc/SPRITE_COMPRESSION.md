# Sprite / video-ROM compression — what's already there, what's left

> **Follow-up, 2026-09-12:** the
> [new graphics/resource audit](GRAPHICS_OPPORTUNITIES.md) identifies
> cross-LOD duplicates and per-frame bit-depth opportunities, with current
> measurements and ownership limits. Its findings supersede conflicting
> conclusions here. In particular, RAM decompression does not create a
> source for the image-ROM DMA blitter, and REVX remains reserved.

**Status:** investigated 2026-08-05, revised 2026-08-24 after reading the
encoder (`doc/load2/zcom.c`) and fixing the audit decoder. Three of the
original levers turned out to be worth nothing; A1 turned out to be worth
about eight times the provisional figure.

**TL;DR** — MK2 already runs the two big 1990s compression techniques in
hardware: per-scanline transparent-run elision and sub-byte pixel packing.
Measured, they are currently saving **~4.2 MB** of video ROM. LOAD2's encoder
is also already optimal on the parameters it chooses, and already dedups
identical frames. What is genuinely left is **bpp reduction on non-fighter
art** (§4 A1) and **layout compaction** (§4 A5).

**Before using any of this, check whether space is actually the problem.**
On 2026-08-24 the program ROM reported 1,458 bytes of headroom while 210,698
bytes sat idle above a fixed REVX base that was never moved after the endings
were retired. Rebasing it — three lines, no compression — took headroom to
**209,842 bytes**. Video ROM has ~101 KB free on top of that. Compression is
the answer only once cheap layout fixes are exhausted; see §10.

---

## 1. What the hardware already does

The T-unit DMA blitter reads its pixel format out of each frame's control word
([SYSEQU.ASM:271-274](../src/SYSEQU.ASM#L271-L274)):

```
dmacmp  .set 0080h  ; bit 7      zero compression on
dmaldx  .set 0300h  ; bits 8-9   leading zero multiplier (0-3 = 1x,2x,4x,8x)
dmatrx  .set 0c00h  ; bits 10-11 trailing zero multiplier
dmabpp  .set 7000h  ; bits 12-14 bits per pixel (1-7, 0=8)
```

### The compressed line format

Confirmed three ways — from the decoder in the shadow renderer
([MKDISP.ASM:1925-1942](../src/MKDISP.ASM#L1925-L1942)), from the writer in
[doc/load2/load2.c:3144-3146](load2/load2.c), and from the analyser that
actually chooses the parameters, [doc/load2/zcom.c](load2/zcom.c) — which is
a **separate file** and is the authority on everything in §4 A2 and §5:

```c
trail = ((lead >> 4) & 0xf) << tmult;
lead  =  (lead       & 0xf) << lmult;
destbits += 8 + (wid - lead - trail) * bpp;
```

Every scanline is one 8-bit header — **low nibble = leading transparent run,
high nibble = trailing transparent run**, each shifted left by the frame's
leading/trailing multiplier — followed by `(wid - lead - trail)` pixels at
`bpp` bits each. With bit 7 clear there is no header and all `wid` pixels are
stored.

### Measured effect

Frames are packed contiguously in the IRW payload, so the byte gap between
consecutive SAGs *is* the stored size. That gives an exact measurement without
needing to decode anything:

| | frames | raw-equivalent | actually stored |
|---|---:|---:|---:|
| zero-compressed | 5,079 | 11,241,377 B | ~6,913,000 B |
| uncompressed | 456 | 261,911 B | 261,911 B |

- **Compressed frames occupy a median 0.615× of their uncompressed size.**
- **Zero-compression is already saving ~4.23 MB.**
- Validation: uncompressed frames land within 2 bytes of `xsize*ysize*bpp/8`
  in 391 of 455 cases (median ratio 0.999), which is what confirms the gap
  measurement is trustworthy.

### Bits-per-pixel is already reduced

MK2's baseline is **6 bpp, not 8** — a 25% saving already banked — and the
engine ships 4 bpp and 5 bpp art too. Control-word census over all `src/*.TBL`:

| Control word | Meaning | Records |
|---|---|---:|
| `0x6080`/`0x6580`/`0x6480`/`0x6180`/`0x6A80`… | 6 bpp + compression | ~8,900 |
| `0x5080`/`0x5580`… | 5 bpp + compression | ~225 |
| `0x4080`/`0x4580`… | 4 bpp + compression | ~221 |
| `0x6000`/`0x5000`/`0x4000` | compression **off** | ~520 |

So: RLE of transparency — **done**. Sub-byte packing — **done**. Software
codec for stills — **done** (`UNZIP.ASM`, PKZIP Implode, used by the VS
portraits and endings via `movie_run`).

---

## 2. The two categories

Everything below falls into one of two buckets, and the distinction matters
more than any individual technique.

**Category A — build-time, hardware-legal output.** The tool produces bytes the
existing blitter already understands. Runtime cost is *exactly zero*; risk is
confined to the build. **Always prefer this.**

**Category B — runtime software decode.** We decompress into SCRATCH RAM and
DMA from there (the REVX→SCRATCH→DMA path is already proven). Costs CPU, RAM,
and new failure modes. Only worth it for large one-shot assets.

The blitter is fixed silicon. It will never understand a new format. Any
"modern codec" is therefore either an *encoder-side optimizer* for the format
above (A), or a *decompressor we write* whose output is that format (B).

---

## 3. The modern angle: asymmetric optimization

This is the real answer to "are there modern techniques we can use on our
side before it hits hardware."

In 1993 the encoder had to run in tolerable time on a 486. LOAD2 therefore uses
straightforward heuristics. Today we can spend minutes or hours of build time
per asset. Every technique below is *modern in the encoder, unchanged in the
decoder* — which is exactly why they carry no runtime risk:

- **Optimal parsing** (dynamic programming over the token space) instead of
  greedy matching. Standard in zopfli/LZMA; gives 5-15% over a greedy parse at
  **identical decode cost**.
- ~~**Exhaustive parameter search**~~ over the per-frame lead/trail
  multipliers. This looked like the textbook case for the idea and it is not:
  LOAD2's choice is already provably optimal, so brute force returns the same
  answer. See lever A2 — a good reminder that "1993 heuristic" is an
  assumption to check, not a given.
- **ILP / DP for geometry.** Optimal multipart decomposition (lever A3) is a
  rectangle-partition problem that was impractical to solve in 1993 and is
  trivial for a solver now.
- **Dictionary training** (zstd-style) over a character's whole sprite set —
  small frames compress terribly alone and well against a shared dictionary.
  Decoder stays a plain LZ copy loop. Relevant only in category B.
- **Modern quantization** (Wu, k-means, spatial/dithered) to push art under a
  colour threshold so it can drop bpp — see lever A1.

---

## 4. Levers, ranked

### A1 — Drop bpp on art that doesn't need 64 colours
**Value: 29 KB cheap / 132 KB with palette re-indexing. Effort: medium.
Risk: low. This is the only remaining codec-side lever worth real money.**

6→4 bpp is a straight 33% saving with zero runtime cost; the main draw path
honours the per-frame bpp field ([MKDISP.ASM:94-100](../src/MKDISP.ASM#L94-L100),
`or a2,a12 ; set "bits per pixel"`).

Two hard constraints:
- **LOAD2 packs at the assigned palette's `bits_pr_pxl` and overrides `PPP>`.**
  The change must happen in the source `.IMG` (reassign the art to a smaller
  palette in imgtool). This is the same mechanism behind the SONICCLAP garble —
  see [SPRITE_BPP_MISMATCH.md](SPRITE_BPP_MISMATCH.md).
- **Anything with `m_shadow` is locked at 6 bpp**, because
  [MKDISP.ASM:1941](../src/MKDISP.ASM#L1941) hardcodes the 6 bpp stride when
  advancing the shadow SAG (`sll 1` twice = 2x + 4x). Effects, projectiles and
  props are fair game; shadowed fighters are not.

**Measured over the whole set** (2026-08-24, after the §6 decoder fix — 9,792
unique frames decoded, 11.0 MB of packed art). The earlier 17.0 KB figure came
from the 1,320 frames the broken decoder happened to survive and was wrong by
about 8x. Three different numbers, because they are three different changes:

| | bytes | what it costs |
|---|---:|---|
| gross, everything | 323,648 | not achievable — includes shadow-locked art |
| non-locked, no palette re-index | **29,411** | change the palette's `bits_pr_pxl` in imgtool |
| non-locked, with palette re-index | **131,826** | re-index the art as well |

"No re-index" means the frame's pixel indices are *already* below `2^bpp`, so
nothing about the art changes. "With re-index" means it uses few enough
colours but they are scattered across the palette.

Where it lives:

| table | no re-index | with re-index | what it is |
|---|---:|---:|---|
| `MKBOLTS.TBL` | — | 48,438 | Raiden's lightning |
| `MKFX.TBL` | 20,853 | 34,537 | particle effects |
| `MKBGANI.TBL` | — | 12,795 | background animation |
| `MKBLOOD.TBL` | — | 9,298 | blood |
| `NOOBPORT.TBL` | 5,109 | 7,380 | Noob portal |
| `MKCHUNKS.TBL` | — | 3,150 | gore chunks |

That distribution is the real result: **effects art is where the headroom is,
and fighters have none** — which also happens to be exactly the art that is
*not* shadow-locked. MK2's artists did genuinely use their 64-colour budget on
the characters.

Reproduce with:

```
python tools/audit_sprite_bpp.py --no-locked              # 29,411
python tools/audit_sprite_bpp.py --no-locked --remap      # 131,826
```

### A2 — Exhaustive lead/trail multiplier search
**DEAD — value is exactly 0 bytes. LOAD2 already picks the optimum.**

Retracted 2026-08-24 after reading [zcom.c](load2/zcom.c), which the original
pass never opened (it only read `load2.c`).

`zcom_analysis` walks all four multipliers for every line and accumulates
`leftover[k].lead` / `leftover[k].trail` — the zeros that *cannot* be
represented at multiplier `k`, capped exactly the way the encoder later caps
them ([zcom.c:56-70](load2/zcom.c#L56-L70)):

```c
factor1 = zlc / factor0;
if (factor1 > 15) factor1 = 15;
leftover[k].lead += zlc - factor1 * factor0;
```

then takes the minimum ([zcom.c:73-80](load2/zcom.c#L73-L80)). Leftover zeros
are precisely the zeros that end up stored as pixels, so
`sum(leftover) * bpp` **is** the size penalty — and the leading and trailing
terms are separable in that sum. Minimising each independently is therefore
the size-minimising choice, which is what brute force would find. There is
nothing to win.

(The only residue is a 1-pixel edge case: trailing runs are counted over
`x > xsize - 120` ([zcom.c:47](load2/zcom.c#L47)), so a run of exactly 120
trailing zeros is measured as 119 and quantises down one step. Sub-byte.)

### A3 — Optimal multipart decomposition
**Value: potentially large on specific art. Effort: high. Risk: medium.**

The hardware elides only *leading and trailing* zeros. An interior hole costs
the full 6 bits per pixel. A wide stance with a gap between the legs, or any
ring/arc effect, pays for its own emptiness.

Splitting such art into multipart pieces removes that waste for the cost of one
extra DMA per piece. MK2 already uses multipart heavily, but the splits are
hand-authored. Formally: partition the bitmap into *k* axis-aligned rectangles
minimising `sum(8*height + 6*interior_pixels)` subject to a DMA budget — a
rectangle-partition problem a modern solver handles easily.

**Caution:** changing multipart geometry moves anipoints, which moves object
anchoring. Read [reference_mk2_object_anchoring](../CLAUDE.md) territory and
`oxval vs oxpos` before touching this.

### A4 — Frame dedup
**DEAD — LOAD2 already does it, and it is already exhausted.**

Retracted 2026-08-24. `CON>` / `COF>` are the checksum-dedup switches and
**checksums are on by default** ([load2.hlp:88-95](load2/load2.hlp#L88-L95)):
LOAD2 hashes every image, and on a match emits a new header pointing at the
previous data instead of downloading it again. That is where the ~300
shared-SAG records come from — they were not hand-authored.

How much is left is printed by the build itself. From `data/IMGBUILD.LOG`:

```
Skipped 2479 duplicate bytes in 3 foreground checksum matches.
Skipped  190 duplicate bytes in 6 foreground checksum matches.
Skipped    4 duplicate bytes in 1 foreground checksum match.
```

**2,673 bytes across the entire build.** There are essentially no duplicate
frames left to find.

One genuine gap remains, and it is small: LOAD2's checksum state is per-run,
and each LOD runs standalone (no `/A`), so duplicates *across* LODs are not
caught. Cross-LOD referencing is legal — SAGs are absolute — so a post-pass
could hash each frame's packed byte range and repoint the later record. Given
the within-run take is 2.7 KB over 30-odd LODs, do not expect much. The one
place the exclusion is deliberate is the `COF>` around the font block in
[MK6MIL.LOD:11-46](../data/MK6MIL.LOD#L11-L46).

Near-duplicate detection (perceptual hash) could find frames worth *making*
identical, but that's an art change, not a build change.

### A5 — ROM layout compaction
**Value: solves the actual binding constraint. Effort: medium. Risk: medium.**

Per [ASSET_SPACE_LEDGER.md](ASSET_SPACE_LEDGER.md) there are ~187 KB unclaimed
but **the largest contiguous gap is ~32 KB**. Fragmentation, not total bytes,
is what blocks large new assets. Compression scattered across 20 slots does not
produce one big hole.

Since the whole video ROM is rebuilt from source, repacking the LOD base
addresses is available and may be worth more than every codec lever combined.
This is a bin-packing problem. **Guard rails:** `makevrom.py` has three layers
of slot protection (CUSTOM_VIDEO_SLOTS / overlap / LOD base preflight) that
exist precisely because moving bases is dangerous — see
[video ROM slot guards](../CLAUDE.md).

### B1 — Byte-aligned LZ + DMA-from-RAM, for one-shot assets
**Value: ~1.2-1.4× on already-compressed data. Effort: high. Risk: high.**

Implode is the wrong codec for anything but stills: `ReadTree`
([UNZIP.ASM:1654](../src/UNZIP.ASM#L1654)) walks Huffman codes one bit at a
time. An LZSS/LZ4-style byte-aligned LZ77 is almost entirely
`move *a2+,*a9+` copy loops and would run several times faster, and with
optimal parsing + a trained dictionary it can match Implode's ratio anyway.

Budget:
- **RAM: ~370 KB free.** The linker map shows 138,564 of 519,776 SCRATCH bytes
  used (`.bss` top at `0x0110ea20`, region `0x01000000 + 0x3F7300`).
- **Ratio: modest.** Implode manages only 1.36× over 6bpp-packed on the VS
  portraits (138×158, 255 colours, ~12 KB packed). On data already through
  hardware zero-compression, expect less.

Right use: decompress-on-load into a RAM sprite cache at round start, fatality
start or stage load. **Not** per frame.

### Ruled out
- **Per-frame decompression of fighter animation.** The blitter needs a
  contiguous linear frame at a SAG and 16.7 ms does not cover it at any codec
  speed.
- **Inter-frame delta / video-style coding for sprites.** Needs full RAM
  reconstruction, which collapses into B1 with worse random access.
- **Arithmetic coding / rANS / context modelling.** Decode cost is far past
  budget even for load-time use, for a few percent over LZ.
- **Teaching the blitter anything.** Fixed silicon.

---

## 5. Why the "turn compression on everywhere" idea mostly fails

456 frames (261,911 B) are stored uncompressed, and 109 of them are ≥24 px wide
(199,456 B). At the measured 0.615× that looks like **~75 KB** sitting on the
table.

**It is nowhere near 75 KB, and most of the reasoning that produced that number
was wrong.** Corrected 2026-08-24:

- **LOAD2 already falls back on its own.** `zcom_analysis` computes the
  compressed size and, if it is not smaller, returns 0 and the frame ships
  uncompressed ([zcom.c:120-122](load2/zcom.c#L120-L122)):
  ```c
  imgsize += ysize << 3;              // 8 bits of header per line
  if (destbits < imgsize) ctrl_word = 0;
  ```
  So an uncompressed frame is *usually* uncompressed because compression lost,
  not because anyone forgot. Nothing to reclaim there.
- **The width refusal is `xsize <= 10`, not 24** ([load2.c:2449](load2/load2.c)
  against `ZCOMPIXELS` = 10 in `load2.h`). `IMGBUILD.LOG` reports ~670 images
  skipped for this reason across the build — all of them ten pixels wide or
  less, i.e. a rounding error in total.
- **The "no zcom on scaled art" rule is about `do_qrtr`, not `oscale`.** The
  automatic disable at [load2.c:2442-2448](load2/load2.c) is gated on
  `do_qrtr`, which is LOAD2's `IMGNAME*N` multi-size feature (full / half /
  quarter / eighth, [load2.hlp:30-36](load2/load2.hlp#L30-L36)) — pre-shrunk
  *copies* baked at build time. It has nothing to do with the runtime scale
  registers. Hardware `oscale` scaling works fine on `ZON>` 6 bpp art;
  that is verified in game on the PITFALL frames (see
  `reference_mk2_dma_scaling`).

What remains true is that the hand-authored `ZOF>` blocks below are still
deliberate, so this lever is small either way. Checking the `ZOF>` directives
in the LOD files shows the
exclusions are deliberate and correct — **zero-compression is incompatible with
runtime scaling** ([load2.c:2445](load2/load2.c), *"Zero compression turned OFF
for scaling image"*):

| LOD | `ZOF>` covers |
|---|---|
| [MK7MIL.LOD](../data/MK7MIL.LOD) | all `FL_*` floor textures (perspective-scaled) |
| [MK6MIL.LOD](../data/MK6MIL.LOD) | player-select boxes, `boonpic_a`/`cloud1a`, `FIGHT`/`FINISHHIM`/`FINISHHER`, `mortaltxt`/`kombatxt`/`bigthund1` |
| [MK4MIL.LOD](../data/MK4MIL.LOD) | `BIGRP1` |

That accounts for essentially every large candidate — `vogsun` (102×194),
`PITFLOOR` (128×128), `FINISHHIM`/`FINISHHER` (287×40), `kombatxt`,
`mortaltxt`, the clouds. **Net realistic gain here is small.** Any frame
considered for this lever must first be proven never to be scaled.

---

## 6. SOLVED — the compressed line format does round-trip

**Fixed 2026-08-24.** `tools/audit_sprite_bpp.py` now decodes
**9,792 unique frames**, and **9,485 of 9,790 (96.9%) end exactly at the next
frame's SAG**. Before the fix it was 16 of 5,073. Check it any time with:

```
python tools/audit_sprite_bpp.py --verify
```

The line format in §1 was never wrong. The bug was entirely in addressing, and
it was three bugs, not one:

1. **A `.TBL` `.long` SAG is IROM-*relative*.** LOAD2 writes
   `address - 0x02000000`. And because bank 1's relative base (`0x04000000`
   bits) is exactly bank 0's size (8 MB = `0x04000000` bits), **the SAG *is*
   the bit offset into the flat 12 MB video ROM**, for either bank, with no
   arithmetic at all. The old `sag_to_flat` subtracted `0x02000000` from it —
   a 4 MB error — and returned `None` for every SAG below that, which is most
   of bank 0. Verify by hand: `data/KITSPIN.LOD` loads at `5B46000`, and
   `src/KITSPIN.TBL`'s first record reads `03b46000H`.
2. **An IRW *header* base is absolute**, with the bank in a separate field, so
   it needs `makevrom.image_byte_offset` + `BANK_OFFSETS`. The old code ran
   both quantities through the same broken function, so the reassembled ROM
   was shifted as well as the lookups into it.
3. **Frames are not byte-aligned.** LOAD2 only word-aligns when `do_align` is
   set and this build does not set it, so the low 3 bits of the SAG are a real
   bit offset. The original pass ruled out "start-bit offsets of 0/8/16" —
   i.e. only whole bytes, which can never recover a `sag & 7` of 4. Starting
   one bit early desynchronises the entire frame; the per-line header decodes
   as garbage and `lead + trail` promptly exceeds `xsize`, which is exactly
   the reported symptom (4,215 of 5,535).

None of the four leads recorded in the original §6 were the cause. `zcom.c`'s
`zero_array` stride is fine (`load_block` walks it with `ldtr += 4`, matching
the 4-byte `struct zero_thing`, [load2.c:3199-3206](load2/load2.c)); the TBL
control word *is* the authority on `lmult`/`tmult`; and `do_sclpad`/`XON>`
padding is a source-side artefact that never reaches the packed stream.

The 3% that still miss are frames whose next-highest SAG belongs to a
different LOD region, so the gap is not the frame's extent — a measurement
artefact, not a decode failure. 155 records remain undecodable, almost all
non-frame records in hand-maintained tables.

## 7. Note on the Liu Kang red dragon fatality

Earlier space planning treated this as needing ~143 KB of new art. **It does
not** — it is a palette swap plus a modified action on the existing
D,D,F,B+HP dragon fatality. It is not a driver for any work in this document,
and no lever here should be justified by it.

---

## 8. Tooling

| Tool | State |
|---|---|
| `tools/audit_sprite_bpp.py` | **working.** Decodes 9,792 unique frames, 96.9% round-trip. `--verify`, `--no-locked`, `--remap`, `--csv`, `--min-bytes`, `--top`. Imports `makevrom` for IRW placement so it cannot drift from the real ROM. |
| `tools/implode.py` | working — packs/unpacks the movie `.BIN` Implode stream (42/42 exact) |
| `tools/rom_space_report.py` | **read this first.** Live free space in both video banks and the program-ROM headroom that §10 is about. |
| `tools/mame_dma_capture.py` | existing — no longer needed for §6 |
| `makevrom.py` | slot guards; authority on IRW placement |

---

## 9. If this is picked back up

Suggested order:
1. ~~Fix the decoder~~ — **done**, see §6.
2. ~~Re-run the full A1 audit~~ — **done**, see §4 A1. It is worth 29 KB cheap
   / 132 KB with palette re-indexing, concentrated in effects art.
3. ~~A2 (multiplier search)~~ — **dead**, LOAD2 is already optimal.
4. ~~A4 (frame dedup)~~ — **dead**, LOAD2 already does it.
5. **Check §10 first.** If the pressure is program ROM, none of this helps.
6. **A5 (layout compaction)** if and only if a specific asset needs contiguous
   space; it addresses fragmentation, which is the constraint that actually
   bites in video ROM.
7. **A1 on effects art** — start with `MKFX.TBL` (20.8 KB with no art change
   at all) and `MKBOLTS.TBL` (48.4 KB, needs re-indexing).
8. Treat **A3** and **B1** as separate projects with their own harnesses. Both
   can break rendering in ways that are hard to attribute.

Verification for any change here: `makevrom.py` must report 0 CRC warnings on
the 12 video ROMs for untouched art, and the battle-stability sweep
([reference_battle_stability_sweep](../CLAUDE.md)) must stay clean across all
stages.

---

## 10. Check the layout before you reach for a codec

Program ROM and video ROM are separate budgets and are **not**
interchangeable — T-Unit PIXBLT cannot source sprite pixels from program ROM.
Everything in §1-§9 is about video ROM. Nothing in it buys a single byte for
new *code*.

On 2026-08-24 `tools/rom_space_report.py` said:

```
VIDEO ROM free      : 100,968 bytes
PROGRAM ROM headroom:   1,458 bytes    <- runs out when you add moves
```

That 1,458 was not a real limit. The 14 program-ROM ending frames were retired
on 2026-08-11, which cut the REVX movie pool from 348,528 bytes to 153,198 —
but `MK8MIL`'s base stayed at `0xFFD39000`, so all 210,698 reclaimed bytes sat
*above* the payload, where `.data` (which grows upward into that base) can
never reach them. Roughly a fifth of the program ROM was idle.

Rebasing the pool to `0xFFED0000` fixed it:

```
PROGRAM ROM headroom: 209,842 bytes    (144x)
REVX guard after payload: 2,314 bytes  (the 2026-08-01 shift left 2,468)
```

Three places have to agree, and nothing checks them — a disagreement silently
misaddresses every VS portrait and hangs gstate `0dh`:

| file | what |
|---|---|
| [data/MK8MIL.LOD](../data/MK8MIL.LOD) | the `***>` line |
| [makerom.py](../makerom.py) | the `REVX_PAYLOADS` entry |
| `src/MK8ZIP.TBL` | regenerated by Phase A; `promote_tbls` merges it |

Largest legal base for a 153,198-byte payload is `0xFFED4850`
(`REVX_WINDOW_END` is `0xFFFFFBC0`, which already reserves `crc_spoof`'s
8 bytes before `VECTORS`).

**Watch for the stale-alias trap.** `promote_tbls` preserves labels that are
in `src/` but not in LOAD2's regenerated output, because that is how genuine
cross-LOD labels survive. A *dead* label survives too, at its old address:
`VS_JC` (retired 2026-08-01) was still sitting in `src/MK8ZIP.TBL` and after
the rebase pointed into live `.data`. It had no readers so nothing broke, but
audit that file after any rebase and delete what LOAD2 no longer emits.

### If program ROM does get tight again

Compression *is* available there — `UNZIP.ASM` (PKZIP Implode) is already
linked in — but measure before building anything:

| block | bytes | compressed | verdict |
|---|---:|---|---|
| frame header tables (10,251 records x 14 B) | 143,514 | 90,977 bit-packed (27-bit SAG, 9/8/11/9-bit geometry, 7-bit index over 76 distinct control words) | **saves 52.5 KB** but every consumer changes — ani engine, `dclip`, DMA queue, multipart walk — and it costs cycles per frame |
| palettes (`IMGPAL2-7` + `BGNDPAL`) | 69,154 | 49,284 under LZMA (1.40x) | ~20 KB for a decompressor plus RAM. 15-bit colour words are high entropy. Not worth it |
| diagnostics (`DIAG*` + `PONG`, text+data) | 51,246 | — | only runs in service mode, so it *could* be stored compressed and decompressed into SCRATCH on entry. Real technique, but 200 KB is free — do not build this speculatively |

The ranking is the point: **the layout fix was worth 4x the largest codec
lever in program ROM and 1.6x every video-ROM lever combined**, and it was
three lines.
