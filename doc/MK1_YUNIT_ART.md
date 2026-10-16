# MK1 rev 1.0 (Y-unit) art — decoding `mkla1.zip`, and what is actually in it

`mkla1` is **Mortal Kombat (rev 1.0 08/09/92)** on the Midway **Y-unit** — the
earliest released MK1, seven months older than the T-unit rev 5.0 in `mk.zip`
that `tools/mk1_shang_souls_extract.py` already reads. This note records the
Y-unit image format (it is not the T-unit's), and the answer to "is there
scrapped content in there".

Tool: `python tools/mk1_yunit_extract.py` → `tmp/mk1_yunit/`.

```
python tools/mk1_yunit_extract.py              # flip + orphans + Cage lanes + diff
python tools/mk1_yunit_extract.py --flip       # the cut flip frame only
python tools/mk1_yunit_extract.py --char 4     # one fighter's lanes, as strips
python tools/mk1_yunit_extract.py --diff       # rev 1.0 vs rev 5.0 art
python tools/mk1_yunit_extract.py --orphans    # frames nothing points at
python tools/mk1_yunit_extract.py --flipkick   # the unused FLIP KICK, VDFKICK1-4
python tools/mk1_find_frame.py shot.png --pieces  # "which sprite is this?"
```

## The Y-unit image format

Everything above the pixels is the same as the T-unit: an image record is
`.word W,H,anix,aniy / .long SAG` (96 bits), a frame is a 0-terminated list of
image pointers, a lane is a list of frame pointers with the commands
`0` end / `1` jump / `2` flip / `3` adjust x / `4` adjust x,y / `5` no-sleep /
`6` calla, and `ANITAB_LIST` is nine `.long` per-fighter tables (Scorpion and
Sub-Zero share one). **Four things below that are different**, and all four
have to be right before a single sprite decodes:

| | Y-unit (`mkla1`) | T-unit (`mk` rev 5.0) |
|---|---|---|
| pixel storage | **planar** — 2 bits each from three 2MB chunks of MAME's 8MB `gfx` region (`0x000000`/`0x200000`/`0x400000`); `pixel[i] = d0 \| d1<<2 \| d2<<4`, `dk = (base[k*0x200000 + i//4] >> (2*(i%4))) & 3` | packed 6bpp bit stream, LSB first |
| SAG | `0x02000000 + pixel*8` (the DMA offset is bits at **8 bits per pixel**; MAME does `offset >> 3`) | `0x02000000 + pixel*6` |
| row stride | **padded to a multiple of 4 pixels**: `stride = (w+3) & ~3` | exactly `w`, rows back to back |
| ROM layout | twelve 512K chips loaded **flat** at 0x000000 | four-way byte interleave within three groups |

The row padding is why a byte-level diff of the two gfx sets finds almost
nothing even though the art is the same — a needle that crosses a row boundary
never matches. Decode per image and 99% of it lines up.

`ANITAB_LIST` is found by shape rather than hardcoded (nine ROM pointers,
entries 4 and 5 equal, every target a table of pointers whose entry 0 walks as
a multi-piece stance lane). It lands on **`FFCE0600`** in rev 1.0 and
**`FFCE4B90`** in rev 5.0 — the latter being the address
`mk1_shang_souls_extract.py` already uses, which is the check that the search
is right. Palettes are 64 entries of 5:5:5 and are byte-identical between the
two revisions, so rev 1.0's are located by matching rev 5.0's content
(Johnny Cage's is at `FFE90810` in rev 1.0, `FFE99B00` in rev 5.0).

## rev 1.0 vs rev 5.0: the art is the same

| | mkla1 (rev 1.0) | mk (rev 5.0) |
|---|---|---|
| sprite images that decode | 10,272 | 10,259 |
| **pixel-identical in both** | **10,200** | |
| in that revision only (by silhouette) | 53 | 66 |

The 53 rev-1.0-only images are small single pieces — recrops, not animations.
**There is no body of art that rev 1.0 has and rev 5.0 dropped.** Johnny
Cage's animation table is structurally identical across the two: the same 86
entries, the same lane addresses in the same order, the same frame counts, the
same blank slots. Whatever is unused in one is unused in the other.

## The scrapped Johnny Cage content

### The flip is missing a frame — `ffd00330`

Cage's flip is two lanes: **anim `0Eh`** (forward) and **anim `0Fh`** (the same
frames in reverse). Both play eight frames and `JUMP` back to the start:

```
anim 0Eh  lane ffcfffd0        anim 0Fh  lane ffd00110
  FRAME ffd00290  4 pieces       FRAME ffd00290  4 pieces
  FRAME ffd003f0  3               FRAME ffd00710  2
  FRAME ffd00470  3               FRAME ffd00690  3
  FRAME ffd004f0  2               FRAME ffd005f0  4
  FRAME ffd00550  4               FRAME ffd00550  4
  FRAME ffd005f0  4               FRAME ffd004f0  2
  FRAME ffd00690  3               FRAME ffd00470  3
  FRAME ffd00710  2               FRAME ffd003f0  3
  JUMP                            JUMP
```

**`ffd00330` — five pieces, `ffec3a00`…`ffec3b80` — is played by neither.**
No 32-bit word anywhere in the program ROM points at it. It is not stray data:
its five image records sit *contiguously in the record table* between frame
`ffd00290`'s pieces and frame `ffd003f0`'s, and its pixels sit contiguously in
the image ROM in the same place (`sag 020cfde0`…`020d63a0`, between
`020cba60` and `020d8d40`). It was authored as the flip's **second frame** —
the tuck — and cut from the lane, leaving the shipped animation to snap from an
upright crouch straight into a full tuck-and-spin.

The same frame is present and equally unreferenced in rev 5.0 (`ffd04dc0`,
five pieces, skipped by lanes `ffd04a60`/`ffd04ba0`). **The cut is original, not
something rev 5.0 did.**

`tmp/mk1_yunit/cage_flip/` has `flip_shipped.png` / `flip_restored.png`,
matching GIFs, one PNG per frame (the cut one tagged `_UNUSED`), and
`flip.txt` — the lane source, every piece record, and the rev 5.0 comparison.

The per-frame hold is **not** in the lane: MK1 lanes carry only frames and
adjust commands, and the tick rate comes from the routine that drives the lane
(the MK2 equivalent is `mframew`'s `a0`). Restoring the frame is a one-word
insert at `ffcffff0` (and at `ffd001f0` for the reversed lane).

### THE unused flip kick — `VDFKICK1-4`

This is the one TCRF hosts as `MK1JohnnyCageFlip.gif`. It is **not** in any
animation table and it is not one of the loose orphan frames below — it is a
whole four-frame move whose *frame records were deleted*, leaving only the 29
image records behind. `data/VANDAN.ASM` (the decompiled MK1 Cage tables) has
the frame lists commented out and names it outright:

```
* VDFKICK1-4 - unused FLIP-KICK frames (seated -> rotate -> inverted), palette GRIMM_P
*VDFKICK1 .long VDFKICK1A..1G,0   ; tiles @ FFEE56A0
*VDFKICK2 .long VDFKICK2A..2G,0   ; tiles @ FFEE5940
*VDFKICK3 .long VDFKICK3A..3H,0   ; tiles @ FFEE5BE0
*VDFKICK4 .long VDFKICK4A..4G,0   ; tiles @ FFEE5EE0
```

Those four addresses chain at exactly 96 bits per record
(`FFEE56A0 + 7×0x60 = FFEE5940`), and **nothing in rev 5.0 points at any of
them**. The 29 records are in `data/VANDAN.TBL` with their sizes, anipoints
and rev 5.0 SAGs, and the pixels decode straight out of `mk.zip`:

| frame | pcs | composite | anipoint |
|---|---|---|---|
| `VDFKICK1` | 7 | 61×121 | (14, −7) — seated, fists up |
| `VDFKICK2` | 7 | 88×113 | (38, −2) — rotating back, leg driving up |
| `VDFKICK3` | 8 | 123×81 | (53, −7) — horizontal, fully extended |
| `VDFKICK4` | 7 | 58×109 | (40, −1) — head down, legs over |

All 29 pieces are **byte-identical in all four builds** — `mkprot4`,
`mkprot8`, `mkla1` and `mk` rev 5.0 — so this was cut before the earliest
surviving dump. In rev 1.0 the records are contiguous at
`ffedc740`…`ffedd1c0`, SAGs `05974d40`…`05998ce0`.

```
python tools/mk1_yunit_extract.py --flipkick
```
→ `tmp/mk1_yunit/cage_flipkick/`: each piece as an indexed PNG in Cage's
arcade palette (`GRIMM_P`, `FFE99B00` in rev 5.0), each frame composited on
its anipoint, `flipkick.json` with every field and the rev 1.0 / prototype
addresses, plus a strip and a GIF.

**Why the ROM scans did not find it on their own**: with the frame records
gone there is no piece list, so a frame-level search has nothing to find, and
the 29 records read as one 29-piece run — in
`tmp/mk1_yunit/orphan_art/frameless_runs.png` they appear as a single
unreadable tangle (`29 pcs rec ffedc740`) because all four frames get composed
onto one anchor. `VANDAN.ASM` is what splits them 7/7/8/7.

### Johnny Cage's other cut poses

Besides the flip kick, four poses sit in Cage's own art block (`0x02000000`–`0x0260_0000`) that **no
animation table in any of the four builds plays** — `mkprot4` (rev 4.0),
`mkprot8` (rev 8.0 07/21/92), `mkla1` (rev 1.0 08/09/92) and `mk` (rev 5.0
03/19/93). Every piece of all four is byte-identical in all four builds, so
this was cut before the earliest surviving dump and never came back.

| art (SAG) | pcs | frame record | sits between | what it is |
|---|---|---|---|---|
| `020cfde0` | 5 | `ffd00330` (orphan) | `ffd00290` → `ffd003f0` of **jump flip `0Eh`/`0Fh`** | the tuck |
| `0234de80` | 5 | **none at all** | `ffd038f0` → `ffd039b0` of the **knocked-back fall `2Ah`** | inverted, mid-backflip |
| `0254ad80` | 7 | `ffd092f0` (orphan) | `ffd09210` → (next animation) of the **forward tumble `3Eh`/`46h`-`48h`** | fully inverted, legs over |
| `0205e2c0` | 15 | `ffcff7b0`, `ffcff8b0` (orphan) | stance `00h` → hit-high `10h` | two standing poses |

`0234de80` is the deepest cut of the four: five image records with **no frame
record anywhere in the ROM**, so nothing but the pixels survives — there is
not even a piece list left to say they belonged together. They compose on
their shared anchor into Cage inverted in mid-air, and they drop exactly into
the gap between two frames the fall animation does play. It is a genuine cut frame, but it is
**not** the flip kick — that is `VDFKICK1-4` above.

`tmp/mk1_yunit/cage_unused_art/cage_cut_in_context.png` shows all three
in-sequence cuts between the frames the game plays either side.

### Unreferenced frames overall

132 frames in rev 1.0 (130 in rev 5.0) have no pointer to them anywhere in the
program ROM. Sixteen are in Johnny Cage's block: the flip tuck above, one more
whole-body pose mid-flip in the death lanes (`ffd092f0`, fully inverted), two
loose standing poses, eight legs-only partial frames, and two blobs. The rest
are logo lettering, background props, and stray body parts belonging to other
fighters. See `tmp/mk1_yunit/orphan_frames/`.

### Found: every fighter's flying kick, reachable only as Liu Kang (slot `28h`)

This is the "strange animation, probably Flip Kick" the MK Secrets thread
([MK1 Arcade Unused Sprites](https://www.mksecrets.net/forums/eng/viewtopic.php?f=47&t=5745))
describes as in the ROM but not accessible. It is **not dead art** — every
frame has a pointer, and every fighter's table has the lane — it is a lane the
code only ever asks for on behalf of one fighter.

Animation slots are generic in MK1: all seven fighters' tables carry the same
indices (`tmp/mk1_yunit/slots/`). Slot `28h` holds a three-frame airborne kick
for every one of them. It is requested from exactly **one** call site in the
program, `MOVI 28h,A9 / CALLA get_char_ani` at `FFDA1700`, inside the routine
at **`FFDA1390`** — and that routine is reached from only two places, both
indexed by fighter:

* the player dispatch table at `FFD8F420` — one of nine per-button tables
  (`FFD8EEE0`…`FFD8F5E0`, seven `.long` each, indexed by `ochar`) chosen by
  the jump table at `FFD8EB30`. Liu Kang's entry is `FFD90ED0`: joystick
  pattern `FFD93A70` (`0002,0002` facing right, `0004,0004` mirrored — two
  taps of a horizontal direction, i.e. F,F) → `FFDA1390`. The other six
  entries are the no-op `FFCDDEB0`. Which button this table serves was not
  traced; F,F + High Kick is Liu Kang's documented input, and matches.
* the CPU's per-fighter special table at `FFD74AD0`, looked up by
  `FFD74A00`: Cage `FFDA2410`, Kano `FFD78170`, Raiden `FFDA8AB0`,
  **Liu Kang `FFDA1390`**, Scorpion/Sub-Zero/Sonya `0`.

So slot `28h` is Liu Kang's F,F flying kick, and Cage's, Kano's, Raiden's,
Scorpion's, Sub-Zero's and Sonya's flying kicks sit in the ROM, complete, with
no path to them. rev 5.0 is the same: one slot-`28h` site (`FFDAC050`, routine
`FFDABCC0`), reached only through entry 3 of its dispatch table `FFD99C90`.

**Johnny Cage's** — lane `ffd072d0`, all 19 pieces byte-identical in rev 5.0:

```
FRAME ffd073b0   4 pieces   57x86    tucked, fists up
FRAME ffd07450   8 pieces   99x91    near knee up, far leg driving out
FRAME ffd07570   7 pieces  113x95    full extension, open hand forward
END                                  (holds the last frame)
```

How the game plays slot `28h` (from `FFDA1390`; MK2 names mapped by shape —
`do_hh_spin` makes the identical `get_char_ani` / `movk n,a0` / `init_anirate`
sequence):

1. sound `37h` (`3Ah` on a flag), `p_action = 110h`, face the opponent.
2. flight length `A11 = max(1, (distance - 10) / 10)` ticks; x velocity
   `200000h / A11`, capped at `40000h`, toward the opponent.
3. `get_char_ani(28h)`, `init_anirate(1)` — one tick per frame, so the three
   frames play on the first three ticks and the lane's `END` holds frame 3.
4. every tick for `A11` ticks: `sleep 1`, `next_anirate`, and from the ninth
   tick on, `strike_check` against stk table `12h`.
5. hit: `p_action = 306h`, hang 20 ticks (`sleep 14h`), land, lane `29h`
   (one crouch frame, `ffd00290`) at anirate 3, stance.
   miss: land, lane `29h` at anirate 3, stance.

Export: `python tools/mk1_yunit_extract.py --lane 0:28` →
`tmp/mk1_yunit/lane_JohnnyCage_28/` — each piece as an indexed PNG carrying
Cage's arcade palette, each frame composited on its anchor, `lane.json` with
every size/anipoint/SAG and the rev 5.0 comparison, a strip and a GIF.
`--lane 0:29` does the landing frame.

### Not found: a pre-match wave, and an air shadow kick

All 77 of Johnny Cage's populated lanes were rendered out of rev 1.0
(`tmp/mk1_yunit/lanes_00_JohnnyCage/`). There is **no waving animation** — the
closest thing is his victory lane `40h`, where he raises an arm, puts on the
sunglasses and folds his arms. Nor is there a wave among the unreferenced
frames, in his block or anyone else's, and since rev 1.0's art is 99% identical
to rev 5.0's there is no room for one to be hiding in the pixels.

The **air shadow kick is not an art question** — it would use the same
`21h`/`22h`/`23h` shadow-kick frames, streak and bolt that the grounded version
uses. Whether rev 1.0 lets Cage throw it while airborne is a *code* difference
and has to be answered by running the ROM, not by reading the sprites. Nothing
here confirms or rules it out.
