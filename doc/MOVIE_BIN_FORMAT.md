# Movie / VS-portrait `.BIN` format

The VS portraits, character endings and attract-mode story backgrounds are not
sprites. They are *movie frames*: compressed full-screen images listed in
`zipped_pics` (`src/UNZIP.ASM`) and decompressed straight into the display page
by `movie_run`. This document records the file format, because until 2026-07-31
it was unreadable and no new frame could be produced.

**The format is now fully understood and there is a working codec:
`tools/implode.py`.**

## Pipeline

Original Midway authoring chain:

```
.vda  (TGA-adjacent raster)
  |  split
  +--> .HDR   image size, bpp, palette
  +--> .FRM   raw 8bpp pixel data
         |  PKZIP 1.1 (03-15-90) - the release that introduced Imploding
         v
       .zip
         |  zip2bin
         v
       .BIN   <- what LOAD2's FRM> directive embeds
```

The `.BIN` is then packed into a ROM by a `FRM>` line in a LOD file, and LOAD2
emits a label for it into a `*ZIP.TBL`.

**`LOAD2`'s `FRM>` does not compress anything.** It embeds a pre-built `.BIN`.
If the `.BIN` is missing, LOAD2 prints `Can't open C:\DATA\<name>.bin for
reading` and silently packs nothing - it is not treated as an error.

## `.BIN` layout

```
.BIN  =  .HDR verbatim  +  raw PKZIP method-6 (Implode) stream
```

`zip2bin` strips the ZIP container and nothing else. There is no `PK`
signature anywhere in a `.BIN`.

Verified by exact round-trip: take `VS_SC.BIN`, drop the first 494 bytes (the
length of `VS_SC.HDR`), wrap the remainder in a synthetic ZIP local file header
with method `6` and general-purpose flags `0`, and `unzip -p` reproduces
`VS_SC.FRM` byte-for-byte (CRC `0x9945ea85` both sides).

Flags `0` means a 4K sliding window and two Shannon-Fano trees (no literal
tree) - exactly the assumptions written at the top of `UNZIP.ASM`'s
decompressor.

### `.HDR`

16-bit little-endian words:

| offset | field |
| ---: | --- |
| 0 | width |
| 2 | height |
| 4 | number of frames (always 1 here) |
| 6 | `ncol` - number of palette colours |
| 8 | 0 |
| 10.. | `ncol - 1` palette entries, 1555 |

Palette entries start at **index 1** - index 0 is skipped. Confirmed 242/242
against the `SCORPVS1` palette in the source IMG. `movie_parsehdr` in
`UNZIP.ASM` reads the first four words in this order.

Note movie frames are **8bpp with their own palette** (up to ~255 colours).
The 64-colour / 6bpp ceiling that applies to ordinary sprites does not apply
here - see `doc/SPRITE_BPP_MISMATCH.md`.

### A movie frame's WIDTH must be EVEN

`blowline` (`UNZIP.ASM`), the inner loop `movie_run` blits a row with, copies
**two pixels per `move`**:

```asm
    move  b9,a5       ; X size
    srl   2,a5        ; X/4 = loop counter
    jrnc  by4
    move  *a1+,*a2+,1 ; copy 2 pixels  <- the remainder-of-2 case, and the only one
```

`X/4` plus one optional 2-pixel copy handles widths that are `0 mod 4` and
`2 mod 4`. **There is no path for an odd width.** At an odd `X` the loop copies
`X-1` pixels and leaves one source byte unconsumed, so the source runs a pixel
further behind the destination on every row - the frame comes out as a diagonal
smear, worse further down, and `verify_movies.py` still PASSES because the
payload in the ROM is byte-perfect. It is a BLIT bug, not a data bug.

Seen 2026-09-29: a re-cut `ERMACVS_vda` came back 139x159 and sheared on the VS
screen while `RAINVS_vda`, re-cut the same day at 138x158, was perfect.
`vda_export.py` prints `!! previous .FRM was N bytes - dimensions changed`,
which is the warning to stop on.

All fifteen shipped portraits are **138x158**. Keep new art at that size; if a
crop has to change, keep the width even.

### `.FRM` rows are stored BOTTOM-UP

`.FRM` is `width * height` bytes with no row padding, but the rows run
**bottom to top**, TGA-style - which fits, since `.vda` is a Targa relative.
`movie_run` does this before blitting:

```asm
    move    b3,a14          ; height
    subk    1,a14
    movi    scrn_ptch,a1
    mpys    a14,a1
    add     a1,a10          ; * to bottom left
```

i.e. it starts at the bottom-left of the destination and walks upward, which
un-flips the frame. Feed it top-down rows and the portrait renders perfectly -
just upside down. IMG libraries store their pixels top-down, so **reverse the
row order when converting IMG art into a `.FRM`**.

Quick check before burning a build: render the `.FRM` with its own `.HDR`
palette and reverse the rows. If it looks right that way up, the file is
correct. Doing the same to a shipped frame like `VS_SC.FRM` shows Scorpion
upside down as stored, right way up reversed.

### Implode stream

Two Shannon-Fano trees, then the token stream.

Tree definition: one byte giving `count - 1` of following definition bytes,
then that many bytes, each `((run - 1) << 4) | (bitlength - 1)`, assigning
lengths to consecutive symbols. Length tree and distance tree are 64 symbols
each and both are complete (Kraft sum exactly 1.0).

Codes are **complemented** canonical codes - `code ^ ((1 << len) - 1)` - built
in `(length, symbol)` order and emitted MSB-first into an LSB-first bit stream.

Tokens:

- `1` -> literal: 8 raw bits (there is no literal tree in this mode).
- `0` -> match:
  - 6 low distance bits, read directly (4K window),
  - distance-tree symbol supplies the high bits,
  - `distance = ((high << 6) | low) + 1`,
  - length-tree symbol, `length = symbol + 2`,
  - if the length symbol is `63`, read 8 more bits and add them.

**The 4K window starts zero-filled.** A match may legally reach back past the
start of the output and copy zeros. Frames whose art opens with a run of 0
pixels begin with exactly such a token. Half the library fails to decode if
this is not handled, and the failure looks file-specific rather than
structural - `VS_SC` starts `01 01 02 03` (a literal) and decodes fine either
way, which makes the bug easy to misdiagnose.

## Updating a frame from the IMG

`tools/vda_export.py` pulls a record out of an IMG library into a `.FRM` +
`.HDR` pair, applying the conversion rules above (3-based `palnum`, zeroed
palette `size` field, 4-byte-aligned source stride, bottom-up output rows):

```
python tools/vda_export.py TMPLOAD.IMG END_MLH1_vda END_MLH --png
python tools/implode.py pack END_MLH
python build.py && python makerom.py && python makevrom.py && python mamerom.py --source-video
```

`--png` writes a preview rendered the way the game will show it - worth a look
before rebuilding, since an orientation or palette mistake is obvious there and
costs a full build cycle to find in MAME.

Note the IMG record name and the `.FRM`/`.HDR` stem differ: the library holds
`END_MLH1_vda` with palette `END_MLH1`, while the pipeline files are
`END_MLH.FRM` / `.HDR` / `.BIN` and the ROM label is `END_MLH`.

## `tools/implode.py`

```
python tools/implode.py pack VS_NB       # data/VS_NB.FRM + .HDR -> data/VS_NB.BIN
python tools/implode.py verify VS_NB     # explode an existing .BIN, compare to .FRM
python tools/implode.py verify-all       # check every .FRM/.BIN pair in data/
```

`pack` refuses to write unless the stream survives both its own round-trip and,
when `unzip` is on PATH, an independent explode. A bad `.BIN` cannot reach a
ROM through this tool.

### Validation

- The decoder reproduces **42/42** shipped `.FRM` files byte-exactly.
- Every stream the encoder produces is accepted by info-zip `unzip`'s explode,
  also **42/42**. Encoder and decoder therefore cannot be sharing a bug.
- Output is **3.2% smaller** than PKZIP 1.1 achieved across the whole set:
  578,221 bytes vs 597,085.

### Every frame was re-compressed 2026-07-31

All 42 frames with a `.FRM`/`.HDR` pair were repacked with this codec, saving
**18,864 bytes** (3.16%) — 42 of 42 smaller, none larger, between 0.7% and
5.8% each. The originals are preserved in `data/_orig_bin/`; `data/*.BIN` is
regenerated and will not reproduce them byte-for-byte.

That shrink fixed a live bug. `END_MLV`, the last entry in `MK8MIL.LOD`,
overflowed the REVX window by **87 bytes** at its original size and was being
dropped — the payload ended at its start address and `makerom.py` reported the
hole as free space. At 10,331 bytes it now fits. Mileena's ending reaches it
via `zipped_pics` index `0x1a`.

Video-ROM side: `MK5MIL` dropped 8,280 bytes, widening the MK5-to-MOVEART2 gap
from 9,480 to 17,760.

No PKZIP binary is required. Modern 7-Zip and zlib cannot *create* imploded
zips, which is why this had to be written rather than shelled out to.

## Verifying

`tools/verify_movies.py` decodes every frame **out of the built ROMs** and
compares it to its `.FRM`:

```
python tools/verify_movies.py
```

It proves each frame sits at the address its `*ZIP.TBL` label claims, that its
`.HDR` survived packing, and that the imploded stream decodes to exactly the
source pixels - i.e. that every ending, attract screen and VS portrait will
render, without visiting them in MAME. Run it after anything that repacks or
moves movie payloads. Needs `makerom.py` + `makevrom.py` to have run first.

Current state: **43/43 verified** (26 REVX, 15 video-ROM, plus `VS_NB` and
`VS_JD`). `VS_JC` is skipped: retiring its `FRM>` line left the label behind
aliasing `VS_JCN`'s address, so it is listed in the tool's `RETIRED` set rather
than compared against bytes that are not its own.

## Where movie frames live

There are two pools, and a frame can go in either.

| Pool | Table | Address space | Contents |
| --- | --- | --- | --- |
| `MK8MIL.LOD` | `MK8ZIP.TBL` | program ROM (REVX window, `0xFFDxxxxx`+) | 27 entries: the 13 VS portraits + 14 endings |
| `MK5MIL.LOD` | `MKZIP.TBL` | video ROM (`0x59xxxxx`/`0x5axxxxx`) | 15 entries: 10 endings, `KINT`, `ABACKA-D` |
| `VSNBMOV.LOD` | `VSNBZIP.TBL` | video ROM (`0x5CDA000`) | `VS_NB` - Noob's VS portrait |
| `VSSMMOV.LOD` | `VSSMZIP.TBL` | video ROM (`0x4004000`) | `VS_SM` - Smoke's VS portrait |
| `MK8MIL.LOD` (again) | `MK8ZIP.TBL` | program ROM | `VS_EM` - Ermac's VS portrait |
| `MK8MIL.LOD` (again) | `MK8ZIP.TBL` | program ROM | `VS_JD` Jade, `VS_RN` Rain |

### Program ROM is the other pool, and bank 0 runs out first

`MK8MIL.LOD` packs into the program-ROM REVX window, where there is no banking
at all, and it already holds the twelve stock portraits. Two of the four hidden
fighters' portraits now live there too:

- **Ermac** (`VS_EM`, 2026-09-02) went there because the largest free bank-0
  run at the time was 8,132 bytes and his frame needed ~12 KB.
- **Rain** (`VS_RN`, 2026-09-26) went there by choice rather than necessity:
  Jade's just-vacated bank-0 slot would have fitted his 15,943 bytes with
  ~115 bytes of guard, but every portrait in this tree has been re-cut larger
  at least once (Ermac 12,298 -> 13,903 -> 14,982), and program ROM absorbs
  that by moving one base instead of repacking a chain.
- **Jade** (`VS_JD`, 2026-09-25) followed when her re-cut art grew to 16,056
  bytes against the 16,048-byte slot `VSJDMOV.LOD` held. Every neighbour in
  that packed bank-0 chain had 2-10 bytes of guard, so there was no local room.
  The sidecar was retired outright, handing 16,048 bytes back to bank 0.

**The REVX pool grows DOWNWARD.** Only ~2 KB sits above the payload; the free
space is *below* the base, where `.data` grows up toward it. Adding a frame
means lowering `MK8MIL.LOD`'s `***>` base, which spends `.text`/`.data`
headroom - so it is not free, it is just a different budget. Watch that
headroom: `.data` was 265 KB on 2026-08-06 and 290 KB on 2026-09-25.

**Three places must agree** or every portrait silently misaddresses:
`REVX_PAYLOADS` in `makerom.py`, `data/MK8MIL.LOD`'s `***>` line, and
`src/MK8ZIP.TBL`'s equates. The last is promoted automatically by build.py
Phase B; the first two are hand-edited, and `makerom.py` says so in a comment.

Retiring a video-ROM sidecar means unwiring it in seven places: its `.LOD`, its
`*ZIP.TBL` (delete it - a stale one left on disk still assembles, with the old
address, and hangs `gstate 0dh`), the `.include` in `UNZIP.ASM`,
`CUSTOM_VIDEO_SLOTS`/`FILE_BANK`/`irw_files` in `makevrom.py`, the `load2` line
in `IMGBUILD.BAT`, `REQUIRED_LODS` in `check_load2_log.py`, `TABLES` in
`verify_movies.py`, and `SET_EQUATE_TABLES` in `promote_tbls.py`. Also delete
the stale `tmp/load2/<name>ZIP.TBL`, or the next build can resurrect it.

### A video-ROM movie frame MUST be in bank 0

`movie_run` in `UNZIP.ASM` has **no video-ROM bank select**. It decompresses
straight from the address handed to it in `zipped_pics`, so a bank-1 label
reads whatever bank 0 happens to hold at the same window, feeds garbage to the
Implode decoder, and **hangs the game on the VS screen** (`gstate` stays `0dh`
forever, with the grabbed select screen still on display).

This is easy to walk into, because bank 1 is where the space is. `VS_SM` was
first built into the bank-1 `SHAOFIS3` tail at `0x2FE4000` - the largest free
run in the ROM - and hung exactly like that. `tools/verify_movies.py` catches
it as `.HDR in ROM does not match` and now prints the bank hint alongside.

Sidecars carrying *sprites* have no such restriction - `JADERANG`, `MKSOUL1`,
`SCLAP` and the `SHAOFIST` pulp parts are all bank 1 - because sprite DMA takes
a bank per object. The rule is specific to movie frames.

**Adding a movie frame does not require REVX space.** The video-ROM route is
already in use and is usually the better choice - REVX has only ~10.5 KB free
after `END_MLV`, while video-ROM sidecar slots are comparatively roomy. A new
sidecar LOD with its own `ASM> <name>ZIP.TBL` works the same way.

`zipped_pics` has 20 entries. Index assignment is not a plain per-character
table:

| index | contents |
| --- | --- |
| `0x00-0x0b` | VS portraits, indexed by fighter id |
| `0x0c-0x0f` | attract story backgrounds `ABACKA-D` |
| `0x10` | `VS_NB` - Noob Saibot (added 2026-07-31) |
| `0x11` | `VS_JD` - Jade (added 2026-08-04; moved to **program ROM** 2026-09-25) |
| `0x12` | `VS_SM` - Smoke (added 2026-08-06) |
| `0x13` | `VS_EM` - Ermac (added 2026-09-02, in **program ROM**) |
| `0x14` | `VS_RN` - Rain (added 2026-09-26, in **program ROM**; stem is `VS_RN`, not `VS_RD` = Raiden) |

`0x10-0x27` used to be the 24 ending frames, reached as `2 * char + 0x10/0x11`.
They were retired on 2026-08-11, which shifted the appended VS portraits down
by 24 slots: `0x28/0x29/0x2a` became `0x10/0x11/0x12`. The `vs_pic_*` equates in
`MKSEL.ASM` and these rows must agree — **nothing checks it**, and the failure
mode is a portrait decoding a wrong address, which hangs `gstate 0dh` rather
than drawing anything visibly wrong.

Because of that layout a hidden fighter must never index `zipped_pics` raw:
`ft_noob` (15), `ft_jade` (16), `ft_smoke` (14) and `ft_ermac` (17) all fall
outside the `0x00-0x0b` portrait range. `vs_sanitize_char_a8` in `MKSEL.ASM`
maps all four to their appended slots and clamps anything else `>= 0x0c` to 0
for exactly this reason. No fighter borrows another's portrait any more.

### `VS_JC` (retired)

`VS_JC` was a second, unreachable Cage portrait ("1st cage picture"),
superseded by `VS_JCN` at index 2. It was retired on 2026-08-01, reclaiming
13,016 bytes of REVX; its `FRM>` line is gone from `data/MK8MIL.LOD` and the
label no longer appears in `src/MK8ZIP.TBL`. `data/VS_JC.BIN` remains on disk.

## Adding a new movie frame

1. Produce `data/<NAME>.FRM` (raw 8bpp pixels, `width * height`, no row
   padding) and `data/<NAME>.HDR` in the layout above.
2. `python tools/implode.py pack <NAME>` -> `data/<NAME>.BIN`.
3. Add `FRM> <NAME>` to a LOD that has an `ASM> <something>ZIP.TBL` line, or
   make a new sidecar LOD with its own table and slot.
4. Register the slot in `makevrom.py` (`CUSTOM_VIDEO_SLOTS`, `FILE_BANK`,
   `irw_files`) and add the LOD to `data/IMGBUILD.BAT` and the required list in
   `tools/check_load2_log.py`.
5. Append a `.long <NAME>` entry to `zipped_pics` in `UNZIP.ASM`.
6. Point whatever selects the picture at the new index.
7. Full rebuild - the `*ZIP.TBL` is regenerated by LOAD2 and must be promoted
   into `src/` like any other sidecar table.

## Credit

The decisive clue - that `.vda` files split into `.HDR`/`.FRM`, that the `.FRM`
was compressed with PKZIP **version 1.1 (03-15-90)** specifically, and that a
`zip2bin` step followed - came from the user, sourced from notes on the NBA Jam
asset dumps. Knowing the exact PKZIP version is what identified the method as
Imploding rather than Shrink/Reduce/Deflate.
