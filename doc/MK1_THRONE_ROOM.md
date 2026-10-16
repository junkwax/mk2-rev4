# THE THRONE ROOM (MK1), curback 01Ch

MK1's court of Shang Tsung: red lacquer walls hung with landscape scrolls,
blue jade medallions, gilt dragons either side of the throne alcove, spiral
gold columns on a grey stone ledge, and the red-and-gold runner the fighters
stand on. The art and layout are MK1's own. There is no stage fatality,
because MK1 had none here.

| | |
|---|---|
| Stage id | `curback 01Ch`, `table_o_mods` in `src/BGND.ASM` |
| Code | `src/MK1THRN.ASM`: stage record, scroll table, display lists, calla |
| Generated | `src/MK1THRNB.ASM`, written by `tools/make_mk1throne.py --apply` (build Phase B2d5) |
| Name | `txt_bg29` "THRONE ROOM", `src/MKSEL.ASM` |
| Selection | `vs_stage_cycle` and `match_stage_cycle`, straight after THE WARRIOR SHRINE, so MK1's four stages run together. It is four LEFT taps from Dead Pool (`19,18,16,1c`) |
| Music | THE TOWER's set (`00Dh..010h`), `src/MAIN.ASM`. MK2 has no MK1 tracks |
| Video ROM | ~62KB of new art in four packs, two in each bank. `data/MK1TRSH.IMG` (the seated Shang Tsung) is extracted but in NO LOD - it costs nothing yet |
| MK1 reference rig | `pwsh tools/run_mk1_throne_capture.ps1` (MAME `mk`) |

## Source: the ROM, and only the ROM

**There is no `.BDB`/`.BDD` for this stage anywhere.** THE PIT and THE WARRIOR
SHRINE each have one in the leak (`KUNGFU5`, `KUNGFU1`) and their tools prove
the leak file against `mk.zip` every build. This one has nothing: every `.BDD`
in the tree and every `data/*.IMG` was searched for its images, **by pixels and
by size, not by name**, and none holds any of them. (`data/CASTLE.IMG` has a
palette called `THRONE`, but that library is THE TOWER's workbench - the
terracotta guards, the wall reflections, the clouds - and the palette is a
two-entry stub.)

So `tools/make_mk1throne.py` decodes the art itself out of MK1's video ROM,
which makes `C:\MAME\roms\mk.zip` (MK1 rev 5.0, T-unit) the one thing `--check`
has to compare against - the packed bytes in our ROM are decoded back and
compared with MK1's, pixel for pixel, on every build.

### Which entry

The stage-name table at `FFDCC390` runs index for index with the stage table at
`FFCA7E30` (ten `.long`s each):

| entry | name | record | art |
|---|---|---|---|
| 0 | THE COURTYARD | `FFCBB410` | `data/KUNGFU2` |
| 1 | PALACE GATES | `FFCB9ED0` | `data/KUNGFU4` |
| 2 | WARRIOR SHRINE | `FFCB7160` | `data/KUNGFU1` |
| 3 | THE PIT | `FFCB8690` | `data/KUNGFU5` |
| **4** | **THRONE ROOM** | **`FFCB8080`** | **nothing - decoded here** |
| 5, 6, 8 | GORO'S LAIR | `FFCB7300` | `data/MK1CAVE` |
| 7 | THRONE ROOM | `FFCB8340` | as entry 4, a column short |
| 9 | (THE PIT BOTTOM) | `FFCB87F0` | `data/KUNGFU5`, camera far down |

The four already ported corroborate the mapping - 2 is KUNGFU1 and 3 is KUNGFU5
to the pixel. Entries 4 and 7 are the same stage; **4 has one more column and
two more throne blocks** (207 against 201), so 4 is what this imports. The
relationship is asserted every build, and asserted *by what each block
resolves to* - the two records have their own header tables (`FFE547E0` and
`FFE5CAC0`), so the same drawing has a different index in each and a word-level
comparison calls every block different.

## The module list has a skip in it, and a skip is only 32 bits

`init_bakmods` (`src/BGND.ASM`, `ibak3`) walks `.long bmod / .word x,y` at 64
bits an entry **but advances only 32 for a `.long skip_bakmod`** - and
`skip_bakmod` is `1` (`src/MAINEQU.ASM`). MK1's walker is the same code, and
THE THRONE ROOM is the one MK1 stage that uses one: three modules, then
`.long 1`, then four more.

Read as a uniform 64-bit list it looks like a three-module stage whose list
ends early - a teal-and-gold colonnade against a flat sky, with nothing behind
it. **That is what the first cut of this import produced, and it decoded,
packed and rendered without a single error.** What caught it was a MAME
capture of MK1 itself.

| plane | module | what it is | rate |
|---|---|---|---|
| 1 | 1380x8 at (16,266) | the skirt below the runner | `020000h` (the fighters') |
| 2 | 1344x37 at (34,229) | the runner the fighters stand on | `020000h` |
| 3 | 1317x230 at (47,-1) | the near columns, their capitals and the ledge | `01A000h` |
| 4 | — | **skipped** | — |
| 5 | 1272x160 at (88,54) | the scroll paintings and jade medallions | `015000h` |
| 6 | 1243x8 at (102,188) | the ledge behind them | `014000h` |
| 7 | 1222x192 at (90,-3) | the back wall, the gilt dragons, the throne alcove | `014000h` |
| 8 | 396x67 at (507,107) | the throne | `0` - it never scrolls sideways |

MK1's plane mapping is proved the way THE WARRIOR SHRINE proves it, and from
the same place (`make_mk1shrine.SCROLL_CODE` / `PLANE_TABLE` - one definition,
not two): the record's `bakmods` `.long` names plane-table entry 1, entry e's
`worldtlx` is `0104F890h - 32e`, and MK1's scroller adds scroll-table `.long`
`8-e` to it.

`tools/run_mk1_throne_capture.ps1` logs **all nine** `worldtlx` live, which is
what settles the skip. At the left limit MK1 reads
`30 / 30 / 119 / 194 / 194 / 209 / 209` on planes 1-7 and `507` on plane 8;
with the skip, the seven modules land on the planes above and our model matches
MAME's frame at every camera. Without it they land one plane lower and the
model disagrees.

## Art

45 header entries, but **MK1 gives five pairs of them the same SAG** - one
drawing worn on two different palettes - so only 40 payloads are packed and
both entries of a pair get the one SAG back, as MK1 has it. 11 palettes, all
64 entries. ~62KB.

No image is a `WIDE_TAIL` case (LOAD2's auto depth ignores a block's last
pixel - see `make_mk1shrine.py`), so every pack is `PPP> 0`.

### ROM space

No free run holds 62KB, so the images are dealt first-fit decreasing across
four. **Every one is space no IRW had claimed, so no donor slot was pulled
back and nobody's growth room was spent:**

| pack | bank | slot (phys) | bytes | where it is |
|---|---|---|---|---|
| MK1TR1 | 0 | `0x791A00..0x797400` | 23,040 | the run the retired JADMIL1 slot left |
| MK1TR2 | 1 | `0xBF7400..0xBFC200` | 19,968 | between MK1PT4's payload and MK1PSK1's base |
| MK1TR3 | 1 | `0xBF2000..0xBF61D0` | 16,848 | inside SCLAP's guard under MK1PT4, where THE PIT's packs already sit |
| MK1TR4 | 0 | `0x751A00..0x755600` | 15,360 | above SHAOSIT's payload |

Either bank is safe for all of it: a background block is DMA-drawn and never
walked by `shadow_p1p2`'s bank-less CPU read, and none of it is a movie frame.

`PACK_MARGIN` is **0.90**, not the shrine's 0.96: the size model is good (~0.7%
against MK1CAVE's real HDRS) but `ZON>` row headers can make an image with no
transparent margins slightly *bigger* than flat, so every pack keeps a tenth of
its slot spare. `merged_headers` refuses an overrun outright rather than
letting a record spill into the next pack, and `--report` prints what LOAD2
really wrote once there is a snapshot.

A fifth run - `0x9FD000..0x9FE800`, between SKGLOW's declared slot end and
MK1PSK3's base - is free and would hold 6KB more if the art ever grows.

The slots are declared in two places that must agree: `PACKS` in the tool and
`CUSTOM_VIDEO_SLOTS` (plus `FILE_BANK`) in `makevrom.py`. The tool writes each
LOD's `***>` line.

## Ground and shadows

MK1's ground is 254; ours is 248. MK2's fighters hang about 6 rows lower under
their anchor than MK1's, which is the same nudge THE PIT and THE WARRIOR SHRINE
measured.

Shadows use `shad_fast` 2, like every fightable stage, and **no clip**.
`init_bakmods` (`src/BGND.ASM`) hands every stage `shad_hi`/`shad_lo` 255,
wider than the screen is tall, so nothing is clipped; a stage only narrows them
when it stands on something the shadow must not spill off, the way THE PIT's
deck and THE WARRIOR SHRINE's walkway do.

**An earlier cut narrowed them here and it was wrong.** It measured the runner
- 19 rows above the ground line and 25 below - which is a real measurement of a
real band, but a fighter's shadow is taller than that band, so it came out
chopped flat against the carpet instead of spreading. There is nothing here for
a shadow to fall off: the runner reaches the bottom of the screen and the wall
behind it is a flat backdrop, not a ledge. Measuring a band is only right when
there is an edge.

## Shang Tsung on the throne

MK1's calla (`FFCB8600`) is four instructions: create one process, pid `2000h`,
routine `FFD6E660`. That process is **Shang Tsung seated on the throne**. He is
in, and he behaves the way MK1's does.

### He is not animating - he is looking at the camera

While the round is being fought there is no lane and no timer. MK1's process,
read with MAME's own disassembler:

```
    MOVI FFD6F300h,A5 / CALLA ...   build the object from a piece list
    MOVI 2BDh,A0 / CALLA ...        world x = 701
    MOVI 36h,A0  / CALLA ...        world y = 54
    MOVI FFD6ED40h,A9 / CALLA ...   set a frame
loop:
    MOVI 8h,A0 / CALLA <sleep>      every 8 ticks:
    MOVE @104F880h,A3,0               A3 = plane 1's camera x
    CMPI D4h,A3 / JRLS  neutral       <= 212: bucket 3, whatever the sum says
    MOVI 2E1h,A5 / SUB A3,A5 / ABS    |737 - camera|
    MOVI 4Bh,A1 / DIVS A1,A5          ... / 75
    CMPI 6h,A5 / JRLS / MOVK 6h,A5    ... clamped to 6
    SLL 5h,A5 / ADDI FFD6ECE0h,A5     -> the bucket table
```

So he turns his head to follow the fight, holds it while the fight holds still,
and snaps a step when the camera crosses a boundary. The seven piece lists the
table points at differ **only in the head record**.

| bucket | camera (plane 1) | head |
|---|---|---|
| 0 | 663..811 | `THRSHHEAD7` |
| 1 | 588..662 or 812..886 | `THRSHHEAD6` |
| 2 | 513..587 or 887..961 | `THRSHHEAD5` |
| 3 | 438..512 or 962+, **and anything <= 212** | `THRSHHEAD1` |
| 4 | 363..437 | `THRSHHEAD2` |
| 5 | 288..362 | `THRSHHEAD3` |
| 6 | 213..287 | `THRSHHEAD4` |

**This had to be measured, because the log looks like something else.** The
first read of the probe - holds of 170, 184, 80 and 344 ticks, frames arriving
f1, f2, f3, f4, f1 - looks exactly like a random-delay idle lane, and a fixed
lane would have looked right in every screenshot. What settled it was the
disassembly plus a stationary-camera probe: six parked cameras, six buckets
predicted correctly.

### And he applauds when a round is won

MK1 keeps a **ten-entry round-end hook table at `FFCACF50`**, indexed by
`curback` exactly as the stage table is. `FFCAB280` reads `curback`, indexes it
and calls the entry. Every entry is `FFCAD280`, a bare `RETS`, except:

- entries **4 and 7** - the two THRONE ROOM records - point at `FFCAD090`,
  which kills the watching process (pid `2000h`) and starts `FFD6EB40`
- entry 0 (THE COURTYARD) has one of its own, `FFCAD160`, which is also where
  the throne room's routine falls through to

`FFD6EB40` runs the lane at `FFD6EC20` at `MOVK 5h` a frame. The lane is four
entries - **clap4, clap3, clap2, clap3** - and then a loop back to its own
start, so nothing in the data ends it; MK1's round teardown does.

**Measured in a real MK1 win** (`tools/run_mk1_throne_win_probe.ps1`, which
plays a round, wins it and logs the piece list on every frame): the clap begins
**14 ticks** after the round is decided, holds every frame **5 ticks**, and
runs **36-37 frames (~180 ticks)** before stopping where it is - then the
watching resumes for the next round. Two rounds in one run, same shape both
times.

> Writing a health bar to 0 does not end a round in either game - a KO is
> decided when damage is applied, not by watching the number. The probe pins
> the loser at 1 and lands a real hit.

**I nearly shipped without this.** The first cut of the import stopped walking
the data at the piece list the object is *built* on, wrote the arms-open pose
off as a never-shown build pose, and missed the three clap poses sitting right
after it - along with the whole hook table. The tell was in plain sight: the
list did not end where I stopped reading.

### How it is built

**Every pose is four upper-body slots plus the lap**, because the clap changes
the whole upper body and not just the head, and the poses have three or four
pieces in front of the same seated robe. So the stage builds `mk1t_sh_slots`
upper-body objects once and swaps each one's art with `ani_flag`; a pose with
only three repeats its last piece, which draws it twice in the same place for
one blit and needs no blank record and no inviso flag - there is no safe way to
set one on a single-part object.

**Every slot is re-placed on a pose change.** The seven watching poses share
one anipoint per slot, so the head-only swap the first cut did was enough for
them; the clap's pieces do not, and a swap without a re-place puts them in the
wrong spot.

They ride `mk1p_sky_lst` - THE PIT's list block, borrowed the way THE WARRIOR
SHRINE borrows it, since only one stage owns it at a time and every stage's
calla zeroes it first - paired in `dlists_mk1thrn` with `worldtlx4`, between
the scroll paintings and the near columns. z rises toward the front
(`insobj_v` keeps a list sorted on `ozpos`), so the slot order is MK1's
front-to-back piece list reversed.

### Which plane he is drawn against

**Plane 4** - the one the stage's module list skips. It carries no module, but
MK1 still scrolls its `worldtlx`, and that is the camera he is drawn against;
`mk1t_rate4` is `015000h`, so the generator now emits all nine of MK1's scroll
rates rather than only the ones with modules.

This was measured, not assumed. His head was template-matched (score 1.00) in
six stationary MK1 frames, and plane 4 is the only camera that puts him at
world `mk1t_sh_x` in all six. Compositing him into the model at each candidate
plane and scoring against MK1 agrees: plane 4 wins every shot and improves the
whole-frame match by 5-6 points, while plane 8 - the throne's own plane, which
looked obvious - makes it worse everywhere.

### How he is built

**Five single-part objects, not a multipart.** Only the head ever changes, and
MK1's seven heads are all 25x42 at one anipoint, so the other four are built
once and never touched and the head is swapped with `ani_flag`. No multipart
RAM, no `ani2`, no lane. They ride `mk1p_sky_lst` - THE PIT's list block,
borrowed the way THE WARRIOR SHRINE borrows it, since only one stage owns it at
a time and every stage's calla zeroes it first - paired in `dlists_mk1thrn`
with `worldtlx4`, between the scroll paintings and the near columns.

Each piece is laid from the one anchor minus its **own** anipoint, which is how
MK1 lays them. z rises toward the front (`insobj_v` keeps a list sorted on
`ozpos`), so the list is MK1's front-to-back piece list reversed.

### The art

`python tools/make_mk1throne.py --shang` writes `data/MK1TRSH.IMG` - 16 records
and his palette, decoded out of `mk.zip`.

| record | size | anipoint | what it is |
|---|---|---|---|
| `THRSHHEAD1`..`7` | 25x42 | (12,-15) | head, hair and beard - the seven the bucket picks between |
| `THRSHLAP` | 47x60 | (20,-71) | seated robe + throne front - **in all eight poses** |
| `THRSHARML` / `THRSHARMR` | 16x34 / 18x35 | | the two arms, in all seven |
| `THRSHCOLR` | 25x14 | (12,-57) | the collar between them |
| `THRSCLAP2A`..`C`, `3A`..`D`, `4A`..`C` | | | the three clap poses' own pieces |
| `THRSHUPHEAD/ARML/BODY/ARMR/HANDR` | | | the arms-open build pose's own five (IMG only) |

`THRSH_P`, 64 entries at 6bpp. Anipoints are MK1's own, unchanged - MK1 places
a piece at anchor *minus* its anipoint, same rule as MK2.

**Which piece is which was measured, not guessed** - each drawn in its own
colour at its own anipoint. The two poses are cut differently: the animation's
head record carries the beard, the arms-open pose's *torso* does. Sizes alone
would have mislabelled them.

**Only the twenty-one records the game draws are packed** (13,013 B across two
slots: `MK1TRSH` at bank 1 `0x9FC400..0x9FE800`, the top of SKGLOW's guard, and
`MK1TRS2` at `0x9E6400..0x9E8000`, the top of JDROD's - SKGLOW keeps 718 bytes
and JDROD 3,634, both finished art). The five arms-open records stay in the IMG
and are NOT packed: MK1 *builds* the object on that pose and its first loop
pass, eight ticks later, replaces it, so it is never seen, and MK2 builds
straight on a watching pose.

### Rig

```
pwsh tools/run_mk1throne_shang_test.ps1 -Tag base        # must PASS
pwsh tools/run_mk1throne_shang_test.ps1 -Tag neg -Negative   # must PASS (negative)
```

It reaches 01Ch with real input, sweeps P1 across the stage in steps, and at
every settled camera recomputes the bucket in Lua from the constants in
`src/MK1THRNB.ASM`, looks the expected record up in `mk1t_sh_heads` **in ROM**,
and compares it with the record the live object is drawing. The ASM's
repeated-subtraction divide, its clamp and its flat branch are all independent
of that arithmetic, so a wrong one shows.

**It only samples while the camera has been still** for a full re-pick plus
slack: the stage re-picks every 8 ticks, so a moving camera is legally one
bucket behind and comparing there would fail a correct build. `-Negative`
crosses the expectation by one bucket and every sample must then disagree.

It also forces a round win at the end of the sweep and watches the clap: every
pose shown *while the lane is running* must come from `mk1t_sh_clap`, and all
four of its steps must appear. A watching pose before the first clap frame or
after the lane's `mk1t_sh_cframes` is legal and reported, not failed - the
process only looks at `winner_status` after its own sleep, and by the time the
lane has run the round has torn down and the stage has built him again.

Measured 2026-09-30: **511 samples, 0 mismatches, 4 distinct buckets, 72 clap
pose changes over all 4 steps (18 each)**; negative **511 of 511 mismatched**.

## The empty throne - when Shang Tsung is fighting

If either player, human or CPU, is Shang Tsung (`p1_char`/`p2_char` ==
`ft_st`), he cannot also be up on the throne. So `mk1thrn_calla` creates
`mk1t_chair` instead of `mk1t_shang`, by the same rule `sitting_kahn` uses to
empty Kahn's chair.

**The art is `thrnchair` in `data/MKBGANI.IMG`**: the whole throne repainted
empty, 107x152 on `THRNCHR_p` (127 colours, so 7bpp). The whole record does
not fit: packed it is ~9.9KB and the largest free video-ROM run is under 3KB.
It does not need to fit either. The throne's back and arms are already plane
5's background, and Shang only ever covers the middle of it. So
`tools/make_thrnchair.py` packs a **patch**, in three strips (`THRCHP1-3`).
They sit in the free tails of this stage's own packs: MK1TRS2, MK1TR1 and
MK1TR2. `makevrom.py` pulls those slot ends back. `make_mk1throne.py`'s
`PACKS` are deliberately left alone, because its deal fills to 90% of them.

**The patch is decided against every camera the throne is on screen at, not
one.** Only plane 5 moves with the patch (it scrolls at plane 4's rate). The
wall and the gong are plane 7, which drifts up to ~15px against it. MK1's
throne base is plane 8, which never scrolls at all. The first cut decided
against the start camera alone. Every pixel it left transparent because it
"matched" plane 7 or 8 then showed something else as soon as the camera moved:
a missing pixel on the seat, and a gap under it. The rule now:

| where | chair pixel | patch |
|---|---|---|
| under Shang (every packed record of his, at his anchor) | opaque | drawn, unless plane 5 is that exact colour |
| under Shang | clear | left alone if plane 5 is there, or only the wall/gong (planes 6-7) ever shows - the room's own parallax. `WALL_RED` (6b0000) if MK1's base (plane 8) or the sky can show |
| anywhere else in the chair's box, only where the **sky** can show | opaque | drawn |
| same | clear | the colour planes 6-8 show there most often, nearest in the chair's palette |

**The sky holes are MK1's own.** The stage's erase colour is the sky blue
(115,181,206). MK1's plane-7 wall has holes at the top of the throne back,
between the dragon ornaments, which leak with Shang seated too (9 pixels at the
start camera, up to 17 elsewhere). 30 patch pixels plug them.

**A flat `WALL_RED` over the wall beside the throne back was tried and cut a
notch into the gong** at cameras 604-700, because plane 7 slides there. So
red goes only where plane 8 or the sky could show: the gap under the seat.
`WALL_RED` is appended as the palette's 128th entry, the one slot 7bpp had
spare.

- **Where it goes is measured.** `thrnchair` template-matches the stage at the
  start camera at world (649, 53) on plane 5 (3,930 of 10,641 pixels
  identical). Each strip's anipoint is Shang's anchor minus its top-left, so
  his own `mk1t_sh_piece` lays them on his list.
- **The cost, chosen 2026-10-05:** the parts of `thrnchair` outside his
  silhouette are not drawn unless they plug a sky hole, so its gold feet and
  repainted base stay MK1's.
- **The proof.** The tool re-simulates all 626 distinct camera views with the
  patch in place. It fails if the sky shows anywhere in the chair's box, or
  MK1's base shows under Shang. Its world-space plane renderer was checked
  against the preview renderer: 0 pixels different on planes 5-8 at three
  cameras.

Edit the chair in IMGTOOL, run `python tools/make_thrnchair.py`, and rebuild
in full (it is new LOAD2 art). `--png DIR` renders the patch and the stage
with it. Phase D runs `--check`, which also decodes every strip back out of
its IRW.

Rig: `pwsh tools/run_mk1throne_chair_test.ps1 -Mode shang|control` walks
`mk1p_sky_lst` and sorts each object by the SAG its record points at, read
out of the TBLs each run. In `shang` mode P1 then walks the camera across the
throne, snapping every 20 frames and logging plane 4's camera, and
`python tools/mk1throne_chair_sky.py` counts sky-blue pixels inside the
throne's box in each real frame. The detector is calibrated by the same
colour appearing 2,000-3,800 times elsewhere in each frame (the windows).
Measured 2026-10-05 on the camera-sweep build: `shang` gave 3 strips and 0
Shang pieces, and 33 frames at plane-4 cameras 507-667 (your screenshot
was ~604) had 0 sky pixels in the box; `control` gave 5 Shang pieces and 0
strips. Both PASS. The sweep did not get the camera back LEFT of the start,
so that half rests on the tool's 626-view proof only.

## Editing

```
python tools/make_mk1throne.py --report          # MK1's numbers, the deal, pack sizes
python tools/make_mk1throne.py --preview         # tmp/mk1throne/preview.png
python tools/make_mk1throne.py --preview 32 600  # any camera x
python tools/make_mk1throne.py --parts           # after changing PACKS
python build.py                                  # full: new packs need LOAD2
```

Never hand-edit `src/MK1THRNB.ASM` or the `data/MK1TR*` files; Phase D's
`--check` fails if they drift from the tool. `--check` needs `mk.zip`, as THE
PIT's and THE WARRIOR SHRINE's do.

The preview renders with MAME's own `pal5bit`, so a preview PNG can be diffed
straight against a snapshot from either game.

**The scaled scroll delta is floored, not rounded.** `round()` agrees at every
camera left of the start x and is one pixel out on planes 3, 6 and 7 to the
right of it - invisible to the eye, and it drops a pixel diff against a real
frame from 87% to 46%. `plane_x` uses `//`, which reproduces all 21 plane
values the two games were measured at.

## Verified (2026-09-29)

- **Stage select with real input**: `pwsh tools/run_cave_stage_probe.ps1 -Tag
  mk1throne -Stage 1c` reached 01Ch via `19,18,16,1c` - four LEFT taps on the
  VS screen - and the VS plate reads THRONE ROOM.
- **Against the model, at three cameras**: MK2's frames are 86.8% / 85.7% /
  86.8% pixel-exact against `--preview` at the left limit, the middle and the
  right limit; the remainder is the two fighters and their shadows, which the
  model does not draw. Every plane camera MK2 reported matches the model
  exactly: at the left limit `32/32/121/-/195/210/210/507`, at the right
  `977/977/888/-/815/800/800/507`. `baklst4` holds 0 blocks at every camera,
  which is the skip; `baklst8` holds the throne's 10.
- **Against MK1**: `pwsh tools/run_mk1_throne_capture.ps1` (MAME `mk`) logs all
  nine `worldtlx` and snapshots the stage. With the fighters masked out the
  model is 94.4% pixel-exact against MK1's own frame at the left limit; the
  one-plane-lower reading of the module list scores 87.5% on the same test,
  which is how the skip was settled.
- **Frame load**: `peak_overload` 2 and `qdma_drops` 0 at every camera - a
  stock stage's figures.
- **Every packed record decodes back to MK1's pixels**: `--check`, 45 of 45.
