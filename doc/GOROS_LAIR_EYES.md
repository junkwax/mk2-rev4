# GORO'S LAIR - the glowing eyes

Pairs of dull yellow eyes that sit in the stage's dark archways and blink.
They are MK1's. MK2 shipped the stage without them, and this build ports them
back.

## What MK2 was missing, and how we know

Three independent facts, all read rather than assumed:

1. **The stage's `calla` slot was empty.** Every background module record in
   `table_o_mods` carries a routine the stage runs at load. `mk1_mod`'s
   (`src/BGND.ASM`) was `.long return` - a bare no-op - and the leaked
   dev-snapshot source has the same bare `return`.
2. **The art was not in the data.** Nothing in any `.IMG` in `data/` is eye
   shaped: the whole tree has no frame narrower than 15px and shorter than 4px
   that belongs to this stage. No `.BDD` carries one either.
3. **The archways are genuinely empty.** Sampling `MK1CAVE.BDD` composed
   through its `.BDB` shows the openings are palette index 0 - transparent -
   all the way through, so what you see inside them is the stage's black
   background colour and nothing else.

Our video ROMs match retail L3.1 byte for byte, so (2) is a statement about
the arcade ROM and not just about our build: **retail MK2 does not have this
art.**

MK2 reuses MK1's dungeon wall, which is why screenshots of the two stages look
nearly identical and why an MK1 shot is easy to mistake for an MK2 one. Seven
of MK2's eight `dun*BMOD` planes are byte-identical in size and block count to
MK1's; only `dun4` was re-cut (1288x325 / 101 blocks against MK1's 1145x235 /
62).

## Where it came from

`C:\MAME\roms\mk.zip` - the T-unit MK1 set, which uses the same 4-way chip
interleave and the same `0x02000000` SAG base as MK2, so the same decoders
work on it unchanged.

MK1's copy of the same stage record points at a real routine. Addresses are
TMS34010 bit addresses in MK1's program ROM:

| MK1 address | What it is |
| --- | --- |
| `FFCB75E0` | the stage `calla` - creates `pid 2025h` at `FFCB7670` |
| `FFCB7670` | the process: build six objects, then loop the script |
| `FFCB7BB0` | six positions, `.word x,y`, zero-terminated |
| `FFCB7D00`..`FFCB8080` | the blink script, 28 `.long` image pointers |
| `FFEAA470` | the palette - four entries |
| `randu(1Ch)` | each pair's start phase |
| `prcslp 8` | one step of the script |

How the tables were found, in case any of it needs redoing: MK1's image
**header** records are `.word W,H` / `.long SAG` / `.word ctrl`, ten bytes, and
uncompressed art packs with no padding - so a run of records where
`SAG[i+1] - SAG[i] == W*H*bpp` exactly is a header table and nothing else is.
Scanning the de-interleaved program ROM for that relation finds 33 of them.
The dungeon's is at file offset `0x0CB1D6`, identified by its first record
being `52x10 ctrl 6000h` - the same first record as MK2's own `fu7HDRS`.
Searching for pointers to it gives the eight `dun*BMOD` records, searching for
pointers to those gives the stage record, and its `calla` field is the routine
above.

MK1's mod record is 24 bytes where MK2's is 28: six words then **three**
longs (`calla`, scroll table, `bak1mods`). MK2 added the `dlists` pointer.

## The art

Six frames, each **one pixel tall**, with a transparent gap in the middle. The
gap is the whole trick - it is what makes a ten-pixel sliver read as a *pair*
of eyes instead of a dash. `.` is index 0:

```
CAVEYE1  3x1   +.#          anipoint 2,0
CAVEYE2  5x1   #. #+        anipoint 3,0
CAVEYE3  8x1   .#+  #++     anipoint 4,0
CAVEYE4 10x1   .+#+  +#+.   anipoint 5,0
CAVEYE5 10x1   ..+.  .+..   anipoint 5,0
CAVEYE6 10x1   ....  ....   anipoint 5,0
```

Opening and closing is a **width** animation - 3, 5, 8, 10 - and the glow is a
**brightness** animation on top of it: CAVEYE4/5/6 are the same shape on three
different rungs of the ramp.

The anipoints are `ceil(W/2),0`, MK1's own, and they matter: `cve_place`
re-derives the position off `*a5(ianioff)` after **every** swap rather than
writing `oxpos` once, so the sliver grows and shrinks around its own centre. A
blink anchored on its left edge would walk the pair sideways every time it
shut.

`CAVEYE_P` (src/IMGPAL7.ASM) is four entries: transparent, then
`(112,104,0)`, `(80,72,0)`, `(56,48,0)`. Dull olive-yellows, not gold. They
read as a glow only because everything around them inside the archway is pure
black - a brighter ramp turns them into lamps hanging in a doorway.

The SAG deltas confirm the decode was right before anything was built: MK1's
are 18, 30, 48, 60, 60 bits at 6bpp, exact.

## The blink

28 steps, one `sleep 8` each - 224 ticks, a touch over four seconds a cycle at
54.7 Hz. MK1's own sequence, transcribed:

```
step  0  1  2  3  4  5  6 | 7..12 | 13 14 15 | 16..20 | 21 22 23 | 24..27
frame  3  2  1  1  1  2  3 |   4   |  5  6  5 |    4   |  5  6  5 |    4
```

Open for most of the cycle, two brightness flickers, then a shut - 10 to 8 to
5 to 3 and back out the same way.

**The random start phase is not ported.** MK1 rolls `randu(1Ch)` per pair so
they do not blink in unison. Here the phases are stated in `cave_eyes_pos`
instead, for two reasons: `@rand` reseeds identically every round, so a roll
would hand out the *same* phases every round anyway and buy nothing; and
spending ten draws at stage init shifts the round's random stream under
everything else that reads it. A hand-picked spread across 28 steps is the
same picture with neither cost.

## Where they stand

MK2's wall is wider than MK1's - four archways where MK1 has a stretch of
three - so there are **ten** pairs rather than MK1's six; six spread over this
wall leaves an archway dark.

The openings were measured off `data/MK1CAVE.BDB`, not picked by eye: they are
the enclosed index-0 runs inside `dun8BMOD`'s rect, at world x `218..315`,
`392..576`, `652..828` and `930..1065`, all dark from y `102` to y `190`.
Confirmed against a live capture - the black band at screen x 150 runs rows
77..155, and `102 - worldtly(26) = 76`.

The coordinates are in **`dun8BMOD`'s own space** (world `(215,-5)`), the same
numbers the probe reads back out of `baklst6`, so the eyes and the holes they
sit in share one origin and cannot drift apart.

The y spread is deliberately narrow (158..166): these are eyes at roughly one
height back in a corridor, not fireflies.

It sits **below** MK1's own 128..144 band on purpose. MK2's archway is a
taller opening than the stretch MK1 hangs its eyes in, so MK1's absolute
numbers land them in the top third of it and they read as hanging off the
ceiling rather than standing back in the passage. 158..166 is a touch under
the opening's vertical middle (the dark runs 102..190) and leaves about 15px
of black beneath the lowest pair. On screen that is rows 132..140, against
118..126 at MK1's numbers.

## Which plane, and why it has to be that one

`dlists_cave` draws `cave_eyes_lst` at **`worldtlx6`**, immediately after
`baklst6`. Both halves are forced:

- The archways are cut out of `dun8BMOD`, which is `baklst6`. Any other plane
  slides the eyes out of their holes the moment the camera moves - over the
  probe's left-to-mid travel plane 6 moves 40px where plane 4 moves 57.
- Drawing them straight after `baklst6` rather than last leaves `baklst5..1`
  and the fighters free to pass in **front** of them, which is what something
  standing back in a passage should do. `dun4`'s near wall does exactly this
  at some camera positions, and that is correct, not a bug.

## Verifying it

```
tools/run_lair_stage_probe.ps1 -Tag <name>
```

Forces a match onto GORO'S LAIR (`curback = 9`), parks the camera at the left
limit / centre / right limit, snapshots each, and dumps every object on
`baklst4`, `baklst6` and `cave_eyes_lst` with its position, SAG and size. The
probe runs against a ROM without the eyes too - it skips the list if the map
has no `cave_eyes_lst`.

What a good run looks like:

- `cave_eyes_lst total=10` at every stop.
- The reported sizes vary across `0x3`, `0x5`, `0x8`, `0xa` within one dump -
  that is the staggered phases, and all-identical sizes means the spread has
  been lost.
- `oxpos` is the table's centre minus that frame's `anix` (centre 480 reports
  475 on a 10-wide frame and 478 on a 3-wide one). A centre that *moves* with
  the width means `cve_place` is not being called after a swap.
- `peak_overload` 2 and `qdma_drops` 0.

The check worth running on the snapshots is that **every** eye-coloured pixel
has black two rows above and below it. That is what proves the eyes are inside
the archways and not painted on the stone; it passed at all three stops.
