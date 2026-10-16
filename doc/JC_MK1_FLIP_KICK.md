# Johnny Cage's MK1 flip kick — `VDFKICK1-4`

MK1 shot this move and cut it. Four frames of Johnny Cage doing a backflip
kick — *seated → rotate → inverted* — survive in every MK1 ROM, but nothing
plays them, and nothing ever did in any surviving build. This is the import
of that art into MK2 as a working special.

Provenance and the ROM archaeology are in
[MK1_YUNIT_ART.md](MK1_YUNIT_ART.md); this note is the MK2 side.

## What MK1 left, and what it didn't

`data/VANDAN.ASM` — the decompiled MK1 Johnny Cage tables — names the move
with its frame lists **commented out**:

```
* VDFKICK1-4 - unused FLIP-KICK frames (seated -> rotate -> inverted), palette GRIMM_P
*VDFKICK1 .long VDFKICK1A..1G,0   ; tiles @ FFEE56A0
*VDFKICK2 .long VDFKICK2A..2G,0   ; tiles @ FFEE5940
*VDFKICK3 .long VDFKICK3A..3H,0   ; tiles @ FFEE5BE0
*VDFKICK4 .long VDFKICK4A..4G,0   ; tiles @ FFEE5EE0
```

Those four addresses chain at exactly 96 bits per record, and **no 32-bit word
anywhere in MK1's program ROM points at any of them**. The FRAME records were
deleted; the 29 IMAGE records were not. That is why no scan of the MK1 ROM
finds this move — with no piece list there is nothing for a frame-level search
to match, and the 29 records read as a single undifferentiated run.
`VANDAN.TBL` is what splits them 7 / 7 / 8 / 7.

So MK1 left the **art and the frame order** and nothing else: no lane, no
timing, no strike box, no input, no code. Everything below that isn't a
pixel or an anipoint is ours.

## The art

`tools/make_jcfkick_img.py` builds `data/JCFKICK.IMG` from the 29 records in
`data/VANDAN.TBL`, decoding pixels straight out of `C:\MAME\roms\mk.zip`.
Nothing is redrawn. `--verify` re-reads the file and diffs every record;
`--check` fails if the file on disk is stale.

Indices are remapped **GRIMM_P → CAGE_P** (nearest colour in 5:5:5) so the
frames wear the palette the player object is already on and the LOD needs no
palette binding. Both palettes are 64 entries, so `PPP> 6` matches the rest
of Cage — a mixed-depth LOD is what garbled SONICCLAP. The remap is a colour
approximation of a 1992 shoot and **is meant to be repainted**.

| frame | pcs | composite | anipoint |
|---|---|---|---|
| `JCFKICK1` | 7 | 61×121 | (14, −7) — seated chamber, fists up |
| `JCFKICK2` | 7 | 88×113 | (38, −2) — rotating back, leg driving up |
| `JCFKICK3` | 8 | 123×81 | (53, −7) — horizontal, full extension |
| `JCFKICK4` | 7 | 58×109 | (40, −1) — head down, legs over |

MK1's own anipoints are kept untouched, so the four poses line up with each
other the way they were shot.

`data/JCFKICK.LOD` loads them as strips into **bank 0, `0x730000..0x734000`**
(16,384 bytes against a ~12,300-byte payload), directly under `JCAIRKIK` off
the same free run above MK5MIL's payload, which keeps MK5MIL its base and
27,914 bytes of growth room. **Bank 0 is required, not preferred**: this is a
fighter's own body art, so `shadow_p1p2`'s CPU read walks it every frame he is
on screen and that read has no video-ROM bank select — bank-1 frames shred.

## The move

| | |
|---|---|
| input | **Back, Back + HK** (`scom_jc_flipkick`, `jc_hi_kick` in MOVES.ASM) |
| lane | `a_jcmk1fkick`, `jc_anitab2` slot **9** (MKJC.ASM) |
| routine | `do_jc_flipkick`, propel entry **`013h`** (MKPROP.ASM) |
| strike row | `stk_jcflipkick`, Cage row **`018h`** (MKSTK.ASM) |

Shaped like `do_jc_air_shadow` and for the same reason: **the rise is in the
art, not in a jump.** He stays a grounded special the whole way —
`init_special` plants him, `restricted_xfer` refuses an airborne caller, and
no `oyvel`/`ograv` is touched, so nothing can drop him through the floor while
he is inverted.

`a11` counts DOWN from `JC_FKICK_TICKS`, so row *r* is on screen while `a11`
is in (TICKS−4r .. TICKS−4r−3):

```
row 0  JCFKICK1  16..13  seated chamber        - no box
row 1  JCFKICK2  12..9   rotating, leg out     -> stk_jcflipkick (018h)
row 2  JCFKICK3   8..5   horizontal, extended  -> stk_jcflipkick (018h)
row 3  JCFKICK4   4..1   head down, recovery   - no box
```

`a10` latches on the connect — one hit per kick, or a two-row active window
double-hits. That is the same guard the air shadow kick uses.

### Everything here is a first pass

MK1 left no numbers, so none of these are restorations — they are guesses
that need tuning against the repainted art:

| equate | value | |
|---|---|---|
| `JC_FKICK_RATE` | 4 | ticks per row |
| `JC_FKICK_TICKS` | 16 | whole lane |
| `JC_FKICK_XVEL` | `018000h` | slight backward drift — it *is* a backflip |
| `JC_FKICK_RECOVER` | 10 | landing sitting-duck ticks |
| damage | 26 hit / 7 chip | |

`stk_jcflipkick`'s geometry is taken off `stk_jcairshadow2`, the overhead rung
of his air shadow kick — the nearest thing he has to an inverted kick. The
real boxes want measuring off `JCFKICK2`/`JCFKICK3` once the art is repainted.

The sound is `tsound 043h`, the shadow kick's, as a placeholder.

## What MK1 does and does not tell us about the sequence

Asked directly, and answered from the ROM rather than inferred:

**The order is solid.** All 28 adjacent piece pairs are *exactly* contiguous
at 6bpp - zero padding anywhere - so the 29 records are one unbroken pixel
run written in that order. The 7/7/8/7 **frame boundaries**, though, exist
only in `VANDAN.ASM`; the ROM alone cannot say where one frame ends.

**There is no roll-out or landing art.** The flip kick's records are the last
in `VANDAN.TBL`, its pixel run ends at `VDFKICK4G` (`sag 044d30fa`), and the
records that follow live in a different record block (`fffa5c20`+) and decode
as the generic blood-splat pool. Ending mid-rotation is simply what MK1 shot.
The `JCJUMPFLIP6/5/4` + `JCJUMP3/2/1` roll-out is an MK2 invention.

**There IS an orphaned input pattern.** MK1 stores joystick motions in the
same 13-word shape MK2 does (window, six entries, six mirrored). rev 5.0's
table is a regular grid of **19 entries** at `ffd9d450`..`ffd9e2f0`, `0xD0`
apart. **Eighteen are referenced** by a `movi <addr>,a11` ahead of the matcher
call. Exactly one is not:

```
ffd9e080   win=40h   2,2 | 4,4      referenced by NOTHING
```

`2` is Forward - verified against Liu Kang's flying kick at `ffd9e2f0`, a
known F,F, which is also `2,2`. So the orphan is **Forward, Forward with a
40h window** - the widest in the table (everything else is 10h-38h). It is
orphaned in all four builds (`ffd9e080` rev5.0, `ffd93800` rev1.0,
`ffd86430` prot8, `ffd82e00` prot4), cut before the earliest dump exactly like
the art.

**It cannot be proved to belong to the flip kick** - nothing links pattern to
move once the dispatch is deleted. But it is the only orphaned input in the
table, and the flip kick is the only cut move we know of. The BUTTON is
unrecoverable: that lived in the per-fighter dispatch table entry, which was
replaced by the no-op handler.

Our `Back, Back + HK` is therefore ours. If you want to match what MK1
probably used, the motion to switch to is **Forward, Forward**.

## Watch out

**MAME loads a set by NAME.** `mamerom.py --no-install --output
rom/mk2_flipkick.zip` writes a zip MAME will never load, because
`-rompath rom` + `mk2` opens `rom/mk2.zip` - the *previously installed*
build. Stage it under the name instead:

```
mkdir rom\fk
copy rom\mk2_flipkick.zip rom\fk\mk2.zip
mame.exe -rompath "<repo>\rom\fk" mk2
```

Symptom: the new move does nothing and the probe prints nothing at all,
because the ROM in memory never had it. Check `rom/mk2.zip`'s mtime against
the link, or search its interleaved program lanes for the move's combo bytes,
before believing any in-game result.

**A MAME debugscript has NO comment syntax.** Every `;` line is parsed as a
command and spams `ambiguous command`. Keep `.ds` files pure commands.
`-debugscript` is also resolved against MAME's OWN working directory, so pass
an absolute path.

## Debugging it

`tools/jcfkick_probe.ds` breaks at the three places the move can die and says
which one it reached; `tools/jcfkick_probe.py` regenerates its addresses after
a relink - nothing is hardcoded, it finds the combo by its data and walks the
propel dispatch.

**`a_jcflipkick` is already taken** — it is Cage's *jump-flip* kick, anitab1
slot `1Eh`. MK1's move is `a_jcmk1fkick`.

**`scom_hh_db2` and `scom_hh_throw` are bare labels aliasing
`scom_jc_shadow`.** Inserting a new combo immediately above `scom_jc_shadow`
silently re-points both Kung Lao combos at it. `scom_jc_flipkick` sits above
`scom_jc_airshadow` instead, which nothing aliases.

## Rebuilding

```
python tools/make_jcfkick_img.py          # data/JCFKICK.IMG from VANDAN.TBL + mk.zip
python build.py                           # LOAD2 packs the sidecar, emits src/JCFKICK.TBL
python makerom.py && python makevrom.py && python makesound.py && python mamerom.py --source-video
```

`tools/make_jcfkick_img.py --check` belongs in a Phase D sweep if the IMG ever
starts tracking edited art.
