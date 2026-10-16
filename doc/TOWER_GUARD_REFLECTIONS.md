# THE TOWER — reflections in the marble

**Status:** shipped. Six guard reflections 2026-09-09 (3,572 bytes of bank-1
video ROM); two pillar reflections and the whole backdrop - wall, arch,
clouds and monk - 2026-09-10 (**no art at all**). The backdrop lives in its
own object, `src/TWRBACK.ASM`.
`peak_overload` and `qdma_drops` unchanged from the stage's own baseline
(2 and 0) throughout.

Rig: `tools/run_tower_reflection_test.ps1`.
Build guards: `tools/tower3_reflection_align.py`, `tools/tower3_pillar_reflect.py`,
`tools/tower3_backdrop_reflect.py` (all Phase D). Backdrop rig:
`tools/run_tower_backdrop_test.ps1`, then `tools/tower_runner_overlay_check.py`.

---

## What can be reflected on this floor, and what cannot

The whole stage, measured against the marble band. A reflection is only
possible if the thing **stands on visible marble**.

| layer | base, screen y | verdict |
|---|---|---|
| Wall + arch (`PLANE5BMOD`) | 180 | **DONE** — see *The backdrop* below. As a true mirror it is a sliver at the horizon; mapped onto the marble it is the whole floor, down to the carpet |
| Pillars (`PLANE4BMOD`) | 189 | **DONE** — 46 rows of marble ahead |
| Guards (`PLANE3BMOD`) | 217 | **DONE** — 18 rows of marble ahead |
| Big monk (`baklst5`) | floats at 86 | **DONE**, as part of the backdrop. As a true mirror he lands ~276, off screen. Most of his reflection falls on the runner, which is redrawn over it — correctly: carpet does not reflect |
| Torches (`baklst1`) | 0–27 | mirrors land at **407–434**, ~180 rows off screen |
| Clouds (`baklst7/8`) | sky, seen through the arch | **DONE** through the reflected arch: they drift in the floor as they drift in the sky. (`baklst2`'s high clouds scroll at their own rate and are not reflected) |
| Fighters (`objlst`) | 243 | stand on the **red carpet**, not marble |

**Every reflection here is a squash about a base line, not a geometric
mirror, and that is worth saying plainly.** The "impossible" verdicts in this
table were for true mirrors. The guards' STATREF strips, the pillars at a
quarter and the backdrop mapped onto the marble are all foreshortened, which
is what polished stone looks like on a 254-row screen — and it is what brought
the monk and the clouds into reach. Two things stay out: the fighters (they
stand on carpet) and the torches (mirrored about their own guard's base, most
land on the carpet or off it).

**Midway drew floor art for this stage and it confirms the approach.**
CASTLE.IMG's `^`-prefixed frames — `^DWALL1-5`, `^PILLAR`, `^DECOR`,
`^DECO1/2`, `^BKGW1/2`, `^TRIM` — are its wall pieces mirrored for the floor,
on darker palettes, plus a whole 320x200 `REFLEC1_vda` reflection plate. And
**this wall IS that wall**: the tower's blocks match CASTLE frames at the
index level (`DWALL2` 93%, `DWALL3` 91%, `DWALL5` 96%, `UPWIND1` 96%,
`UPWIND2` 92%). Two things came from them: the reflection should be deep (the
`^` frames are full size, a near-true mirror), and it should be **bright** —
SLATE→SHADE is 76%, PILLAR2→PILSHAD 71%, TRIM→STRIM 79%, where the first
attempt used 45%. The `^` pixels themselves are not packed: they are vertical
mirrors of art the stage already has, and `m_flipv` reproduces them for free
and uniformly across all 12 of the wall's block types. (SHADE and PILSHAD
cannot simply be dropped in - they are not index-aligned with SLATE and
PILLAR2 - so their measured brightness is applied instead.)

(Reflecting the fighters is possible in principle — the routine exists, see
[DEADPOOL_ACID_REFLECTIONS.md](DEADPOOL_ACID_REFLECTIONS.md), which walks pixels
by hand because `m_flipv` scatters a multipart body — but on this stage it would
land on carpet.)

---

## Why this art belongs to this stage

THE TOWER already stands on the CASTLE floor and nobody had noticed.
`tower_floor_info` (BGND.ASM) points `FL_TOW` at `CASFLOOR1..6` out of
`MKFLOORS.IMG` on `CASFLR1_p` — six tiles totalling 1200x75, polished marble
flagstones running back from a red carpet.

`CASTLE.IMG` is dev art for a castle stage that was never built, and it carries
a whole reflection vocabulary: mirrored wall pieces paired with dimmed palettes
(`^PILLAR`/`PILSHAD`, `^DWALL2`/`SHADE`, `PILREF`/`REFLX`, `winref`/`WINRFC`),
`reflex1`/`reflex3`/`reflex` — which are **75 rows tall, exactly the floor
height** — and the statue-base strips used here.

The strips fit TOWER3's guards to the pixel, which is how we know:

| CASTLE statue | tower block group | STATREF | ratio |
|---|---|---|---|
| STATUE1 76x218 | 76x217, base slice 59 wide | STATREF1a/b 59x11 | 59/76 = 0.78 |
| STATUE2 68x195 | 68x194, base slice 55 wide | STATREF2a/b 53x21 | 53/68 = 0.78 |
| STATUE3 61x174 | 63x173, base slice 47 wide | STATREF3a/b 47x21 | 47/61 = 0.77 |

Every reflection is 78% of its statue's width — a consistent foreshortening —
and two of the three match their base slice exactly (59/59, 47/47). STATREF4 is
CASTLE's fourth, smallest statue and TOWER3 does not use it, so it stays
unpacked.

## The stage in screen rows

Everything below is measured, not assumed. `worldtly` rests at `ceiling_y` on
this stage, so `screen = plane y + 14`, and `floor_code` uses `skew_y` directly
as a screen row (`b6 = skew_y + ceiling_y - worldtly`, and the two cancel).

| | screen rows | |
|---|---|---|
| Wall base (PLANE5BMOD) | 181 | meets the floor's top row exactly — the design horizon |
| **Floor: marble** | **181–232** | 52 rows of polished stone |
| Pillar bases (PLANE4BMOD) | 196 | reflection 196..221 |
| STATUE3 feet | 197 | reflection 198..219 |
| STATUE2 feet | 206 | reflection 207..228 |
| STATUE1 feet | 220 | reflection 221..232 |
| **Floor: red carpet** | **233–254** | |
| `ground_y` 235 → fighters' feet | 249 | on the carpet — 6 rows below Midway's 229/243, see below |

The three guards' feet at 220 / 206 / 197 are the stage's depth ramp, and each
reflection starts exactly where its statue stops.  All of them sit seven rows
below Midway's placement - see the `.word` under `PLANE3BMOD` for why -8 is the
floor of that knob and not a taste call.

**This is also why the torches are not reflected.** They sit at screen rows
0–27, roughly 200px above the floor, so a mirror image of one lands at 407–434 —
about 180 rows below the bottom of the screen. A flame reflection here is not
expensive, it is geometrically impossible. Firelight *pooling* on the marble is
a different effect and would need different art.

Reflecting the **fighters** is possible but wrong on this stage: they stand at
249, on carpet. (The routine to do it exists — see
[DEADPOOL_ACID_REFLECTIONS.md](DEADPOOL_ACID_REFLECTIONS.md), which walks pixels
by hand because `m_flipv` scatters a multipart body.)

## The fighting line, and how far the camera chases a jump

Two numbers changed once the floor became a mirror. Neither is a fix for a bug:
everything was already moving together, measured from the game's own `oypos`
values on the same block. They are taste, and both are stage-local.

**`ground_y` 0e5h → 0ebh.** Six rows lower, so the fighters stand *on* the
marble rather than appearing to hover a little above it — an impression the
reflection creates because a mirrored floor gives the eye a horizon to measure
feet against, and a plain floor does not. `shad0` draws the shadow at
`ground_y + shadow_adjustments[char]`, so the shadow moves with them and the
feet-to-shadow gap is unchanged (0, the same as every other stage — the gap is
per-character and global, and nothing here touches it).

The **initial world y** stays on the original `0e5h-wy_offset-19`, deliberately.
`init_bakmods` copies that word into `ceiling_y`, and the floor, the skew and
every reflection are measured from `ceiling_y` — so leaving it alone moves the
fighters without moving the room.

**The vertical chase is per-stage now: `climb_limit`.** `scrl7` hard-coded
`subi 010h,a5`, capping the climb at `ceiling_y - 16` on every stage in the
game. It is a RAM word instead, defaulted to that same `010h` by `init_bakmods`
beside the `shad_hi`/`shad_lo` defaults, so no other stage changes by a bit;
`calla_tower` lowers it to **6**.

Why only here: on an ordinary stage a jump climbs the view and the backdrop
slides. On this one the floor is a mirror, so the pillars, the guards, the wall,
the arch, the clouds *and all of their reflections* ride up together. That is
correct — they are one scene, and the reflections re-derive their rows from
`worldtly` every tick — but it is far more of the screen in motion than
anywhere else, and it reads as the room jumping with you. Six rows keeps the
motion; there is simply less of it.

It moves the fighters **and** their shadows, by the same amount - `shad0`
anchors the shadow on `ground_y` too - so it can never change how the two line
up against each other. `shad_bias` is the knob for that, and it is already
where it wants to be: measured with `f_shadows` toggled off to separate the
shadow from the boots (they are both flat black), the deepest foot and the
deepest shadow row coincide. What is left breathes by 2-3 rows through the
idle stance, because the feet bob and the shadow follows at a quarter of it.

Measured, `tools/run_tower_backdrop_test.ps1`:

```
mid    worldtly=-14 (camera climbed 0)  ground_y=233 -> screen 247  shadow 249
climb  worldtly=-20 (camera climbed 6)  ground_y=233 -> screen 253  shadow 255
```

Before the cap the same climb stop settled at `worldtly=-31`, seventeen rows.

## How a translucent blit is faked

The DMA has no alpha. A see-through reflection is a **50% checkerboard against
index 0** — the marble shows through the gaps. `STATREF1a` and `STATREF1b` are
the same strip with that checker **inverted**: 94% of their pixels differ.

### The phases are dealt out, not cycled

This is a walk-back worth recording, because the pair *looks* like an animation.

The first version alternated them at 5, 7 and 6 ticks on the theory that a
static statue could throw a moving reflection. **It buzzed.** Inverting a 50%
checkerboard changes very nearly every pixel in the strip, and there is no third
frame to pass through, so the strip can only cut hard from one full field to the
other — 9–11 whole-field inversions a second. Slowing it down does not change
the shape of the problem; it just spaces the blinks out, and a lone blink with
no motion around it draws more attention than the buzz did.

So each strip **holds** one phase, and the six are dealt `a`/`b` down the left
group and `b`/`a` down the right, so no two adjacent reflections share a dither
grid. That is what the pair actually buys here: two interleaves, so the row does
not moiré against itself.

Each descriptor still carries a table pointer and a tick count, so putting a
shimmer back is one line per strip — point `tr_table` at a two-entry table and
drop `tr_ticks`. `tr_hold` (300 ticks) is an idle redraw of a frame that never
changes.

## Where they live

`baklst1`, the same plane as the torches, for the same two reasons:

- the plane carries **no module**, so `bgnd_ud1`'s `disp_del` never culls a
  hand-placed object off it (see the note in `tower_flames`);
- `dlists_tower` draws it at **`worldtlx3`**, PLANE3's scroll rate, so every
  reflection stays under its own guard through the whole camera pan.

Z-order in `dlists_tower` puts `baklst1` **after `floor_code`** (the marble is
already down) and **before `baklst3`** (the statue paints over its own
reflection if the two ever overlap).

## The pillars — a reflection with no art

`tower_pillar_reflections` draws each column a second time, upside down and a
quarter height, out of the pillar's **own tile**. No LOD, no TBL, no video ROM:
`m_flipv` plus a non-square `oscale`.

Three things made it safe to do this way, and each was checked rather than
assumed:

- **`oscale` reaches background objects.** The display loop's
  `mmfm a3,a12,a11,a9,a8,a7,a6` loads `oflags…oscale` per object for every
  list, and queues `a6` to the DMA. Proven live by `tools/tower_scale_probe.lua`,
  which pokes a real pillar and draws it at 1/3 height.
- **`m_flipv` works on this exact art.** `PLANE4BLKS` **already sets it** on the
  upper of each pillar's two tiles — the 206px column is one 48×103 tile plus a
  vertically flipped copy of itself. The stage has been flipping this art since
  1993.
- **Solid beats dithered here.** The guards' STATREF strips are a 50%
  checkerboard because that is the only way to fake a see-through blit, but they
  are flat bases with nothing inside to lose. Mocked over a real frame grab, a
  dither over the pillar destroys its structure — the gold spiral stops reading.
  Solid on a dimmed palette (`PILREF_P`, 80% of `PILLAR2`) won; 100% read as a
  second pillar lying on the floor and 65% read as a shadow.

### The flip moves the anchor, and scaling changes by how much

`clip6` (MKDISP.ASM) adds `ysize-1` to the destination y when `m_flipv` is set,
so the hardware draws **upward** from there. The art ends up at

```
    y + ysize - drawn_height  ..  y + ysize - 1
```

The **bottom stays put** where the unflipped tile's bottom was, and the top
rises as the scale shrinks it. So the y handed to the engine has to be pulled
back by `ysize - drawn_height`, which `make_pillar_reflection` computes rather
than bakes in — hardcode it and it goes wrong the moment either the tile or the
scale changes.

`TWR_PSCALE`'s ystep is `0400h` for a reason beyond taste: it makes the drawn
height `(ysize+3)>>2`, a shift, so that correction needs no divide. 103 → 26
rows, screen 189–214.

**The DMA ceils a reduction.** Measured by `tools/tower_scale_rounding_probe.lua`
against a bare-wall frame: 103 rows draw 52 / 35 / 21 / 18 / 15 at steps
200 / 300 / 4F0 / 600 / 700 — `ceil(h·256/step)` every time. The first
version assumed floor and put every pillar reflection one row high, over its
own pillar's last row.

### Where the art comes from

`R2HDRS` (BGNDTBL.ASM) is the tower's block header table — five words per entry,
`.word xsize,ysize / .long sag / .word ctrl`. `PLANE4BLKS` gives its pillar
blocks header index 6, so entry 6 **is** the pillar tile, and the routine reads
its size and sag out of the table at runtime instead of copying them. A
hand-copied sprite record in an `.ASM` is never promoted and rots the next time
the art is re-cut; read this way the reflection follows a re-cut for free.
Conveniently an entry's first `.long` is already `[ysize:xsize]` — exactly
`osize`'s layout.

### A display list of its own

The reflections must scroll at PLANE4's rate or they slide off their pillars,
and `baklst1` is already spoken for at `worldtlx3` by the torches and the guard
reflections. A `dlists` entry is just `<list head>,<worldtl address>` and
nothing requires the head to be one of the eight, so this run gets
`twr_prefl_lst` at `worldtlx4`, drawn immediately after `floor_code` — behind
every other reflection on the floor, which is right, because the pillars stand
behind the guards. Nothing culls it: `bgnd_ud1` only walks planes carrying a
module.

## The backdrop — wall, arch, clouds and monk

The marble mirrors the stage behind it, from the floor's top row **down to the
carpet's edge** (screen 181–234): the wall with its great arch, the clouds
drifting through it and the floating monk, on palettes at 76%. No art — every
object is the stage's own art drawn again with `m_flipv` and a reduced `oscale`.

### Depth: a map, not a ratio

The wall's full height maps onto the rows of marble measured between the floor's
top row and the carpet:

```
    dmap(D) = floor(D * TWR_BKR / TWR_BKDMAX)     200 rows of wall -> 54 of marble
```

Both ends are measured, not chosen: `floor_band` finds the carpet in the floor's
own art, and the wall's depth is its module height. The first version used a flat
1/6, which stopped ~20 rows short and left a hard edge of bare flagstone across
the middle of the floor.

### The wall: 73 blocks, 73 steps, zero seams

The DMA is a nearest-neighbour scaler that sizes every blit from its own source
height, and a reduction **ceils** — measured with
`tools/tower_scale_rounding_probe.lua` against a bare-wall frame: 103 rows draw
52 / 35 / 21 / 18 / 15 at steps 200 / 300 / 4F0 / 600 / 700. At one shared step
the wall's blocks, stacked 4–5 high, would round independently and open 1-row
marble cracks across the reflection. So every block gets its own:

```
    rows = dmap(B - y0) - dmap(B - y0 - h)          (half-open, so they tile)
    step = ceil(h * 256 / rows)     so  ceil(h * 256 / step) == rows exactly
```

`B` is the wall's base line (plane y 167 = the floor's top row). The wall is
static, so `tools/tower3_backdrop_reflect.py` does all of it at build time into
`src/TWRBKREF.ASM` and proves the tiling column by column; the SAG, size and
control word are still read out of `R2HDRS` at runtime, so a re-cut moves the art
without anyone retyping it. Records carry `ozval = z·256 + rank`, so the
reflected blocks keep the wall's own draw order (`insobj_v` sorts on z, then y).

### The sky moves: a follower

`backdrop_follow` waits for `cloud_proc` and `monk_proc` to build their objects,
pairs one reflection with each (row 8's clouds, row 7's, the monk's two pieces)
and every tick copies sag, size, clip offset, flags and x, then works out the
mirrored y through two tables — `twr_dmap` and `twr_drawn` — so it never divides.
Pairing is by list position; nothing relinks those lists after they are built.

**`clip_a_row` parks a cloud by adding `4000h` to its y** (`left_edge_clip`,
`cld7`) when it leaves the arch's window. The first follower read that as "below
the floor line", pinned it there, and drew a reflection of a cloud the game had
hidden. A parked source now parks its reflection.

### The carpet runner

The hardware cannot skip pixels, so the reflection lands on the red runner — and
the runner is **locked under the arch**, because `floor_code` scrolls on
`scrollx6`, the wall's own rate. `twr_runner_code`, a `.long -1` display-list
entry like `floor_code`, redraws exactly the runner's span on each line of the
band, over the reflection, with `floor_code`'s own per-line skew:

```
    screen y of texture row L = skew_y + (ceiling_y - worldtly) + L
    screen x of column c      = c - 400 + int(skew_oc + L * skew_dx)
    source                    = skew_sag - 400*6 + L*1200*6 + c*6
```

The span per row is measured off `CASFLOOR1-6` and carried down as an envelope —
the runner is a trapezoid, so no row is narrower than the one above; the raw scan
stopped a pixel short where the trim's anti-aliasing reads as marble.

### Where it sits, and where the objects sit

Three private lists, all at `worldtlx6` — planes 5–8 share one scroll rate and
origin — drawn straight after the floor in the real order: sky, wall over it,
then the monk; then the runner pass; then the pillar reflections.

The guards and the pillars **drop 4px** (PLANE3 `-15` → `-11`, PLANE4 `-31` →
`-27`). Standing on the floor's top row they read as if they were behind the
reflection rather than on it. Only the x placement is policed by
`tower3_statue_layout.py` (the design-centre formula), so y is free; the torches
and all three sets of reflections re-derive from it.

### Measured

- 73 wall objects, drawn rows **181–234** at rest and **198–251** with the camera
  climbed 17 rows — the band moves with the floor — none outside the marble.
- Every cloud and monk reflection tracks its source, 0 mismatches at all five
  stops; a parked cloud's reflection is parked.
- Runner: clean on every on-screen line at all three stops where the camera is
  genuinely still, including hard off-centre (skew 187px) and straddling x=0.
- No reflection on the carpet at any stop: zero foreign pixels in the interior of
  the runner's span, everywhere.
- 1800 frames of released combat: overload 2 on **100%** of frames, peak_overload
  2, `qdma_drops` 0. The stock stages under `pool_stress` peak at 4.
- Objects: 183–197 of 358 free (268 before the backdrop).

## The sky in the mirrored windows

The wall is not a solid slab. **18.8% of PLANE5 is index 0** — measured off
`TOWER3.BDD`, block by block — and every one of those pixels is somewhere the
autoerase colour shows through: the big central arch, the row of small window
panels along the top of the wall, and the tall slits either side of it.

The reflection is built out of the wall's own blocks, so all of that came out
as bare flagstone. The mirrored windows had the *floor* behind them and the
reflected clouds drifted across stone.

**The autoerase colour already is the sky.** Every pixel nothing draws in a
frame comes out as `irqskye`, which is `tower_mod`'s first word, `1D2CH` —
the sky's own blue. So once `skew_skip` (below) stopped `floor_code` drawing
marble under the band, the holes in the reflected wall show sky with no help.

`make_sky_backing` (TWRBACK.ASM) puts a *dimmed* sky behind it all the same:
flat quads over the whole reflected band on `twr_skybg_lst`, drawn first by
`dlists_tower`, reading the floor's own texture through `dmacal` (`800Ch`,
constant on zero AND non-zero data) and wearing `NEWCLD_R`, so the constant
comes out as the sky the reflected clouds are drawn against.

**It was switched off for a week, and that was a mistake worth recording.**
The skip made it look redundant — the holes show sky either way — and it cost
**1.1–1.7 ms** of the 18.28 ms frame on a stage that was dropping its life
bar, so it went. What that missed is that the autoerase sky is the **undimmed**
one:

- With the backing, the holes are the dimmed sky; without it they are the true
  sky. Measured on one frame: exactly **1,380** pixels change, (41,57,74) to
  (57,74,99).
- 1,380 pixels is not only the arch window. The arch's curve is drawn with
  single transparent pixels along its edge, and each one became a **bright
  speck** on the floor — scattered dots that read as a glitch rather than as a
  reflection. Players reported them; nobody had seen them before, because for
  the whole life of the effect they had been the dimmed sky.
- **Covering the whole band is safe** for a reason worth stating: every pixel
  of the module is either transparent — where the sky belongs — or opaque, and
  every opaque pixel's reflection is drawn on top of this. `check_tiling`
  already proves the per-block reflections tile every column exactly, so no
  opaque source row loses its reflected row.

So it is called again, and the two-blit shadow path (*Two blits a shadow
piece*) is what pays for it.

### Lighter: tinted to the marble, not dimmed further

The first version scaled every channel of the wall's palettes by `REFL_K`
(0.76). That reads as a **hard mirror** — players called it dizzying — and two
measurements say why.

**Midway's own floor reflections are not dimmed copies of the wall.**
CASTLE.IMG carries `reflex1-3` (three solid 75-row floor textures on a palette
called `shine`) and `PILREF` (on `reflx`). Measured here, 5-bit channels over
the non-zero entries:

| palette | mean | max | sd |
|---|---|---|---|
| `slate` — the wall | 12.9 9.3 9.0 | 25 21 22 | 4.0 3.7 3.8 |
| `shine` — their floor | 10.5 8.5 9.4 | 18 20 23 | 3.7 3.9 6.7 |
| `reflx` — their pillar | 10.7 8.1 8.1 | **16 13 13** | **2.9 2.4 2.6** |

They keep the wall's mean and squash its **highlights**, leaving the darks
alone (`slate`'s min of 2 is `reflx`'s min of 2). A plain scale keeps contrast
proportional and cannot do that, so `dim()` now compresses toward each
palette's own mean — downward only, `REFL_FLAT`.

**But flattening was not the fix, and the reason is the useful part.** The
mirror does not read as a window because it is too sharp. It reads as a window
because it is **blue against a brown floor** — the reflected sky is the wall's
own sky, and no amount of dimming changes its hue. Midway never had this
problem: `reflex1-3` reflect the castle wall, so `shine` had no blue in it to
lose. THE TOWER's wall has an open arch.

So `REFL_TINT` (0.60) pulls every reflected colour toward the floor's own tint
— `CASFLR1_p`'s mean, normalised, applied at the colour's **own luminance**, so
the mirror keeps its light and shade and loses only its foreign colour. The
floor palette is read, not typed: repaint the marble and the reflection follows
it.

**The trap, which cost a build.** A palette's mean is not its middle. On
`newcld_p` — the clouds — the mean IS the bright end, so pulling channels
toward it *lifted* the darkest pen in the palette, and the darkest pen in that
palette is the sky: the colour `make_sky_backing` draws in. The backing came
out **brighter** than the undimmed autoerase sky it exists to sit behind, which
would have made every speck worse rather than better. `dim()` therefore
compresses toward the mean only where that darkens (`min(flat, plain)`), which
is also exactly the shape `reflx` has.

### One object 1120 wide draws nothing at all

The band is the wall's full 1120px width and the obvious build is one
rectangle. It is invisible, and not for any reason the code can see.

**The DMA's destination x-size field is narrower than the 16 bits the object
carries.** 1120 arrives as `1120 & 511 = 96`, and 96 pixels at the band's left
edge are off the left of the screen at every camera position this stage allows.
So the failure presents exactly like an object that was never queued: the rig
found it alive on its list, `xy=(0,167) size=1120x54 flags=e00c const=0101
pal=0404`, with not one pixel of it on screen, `qdma_drops` 0.

`SKY_TILE` (256) in the generator splits the band into five objects, of which
at most two are ever on screen. Nothing else in the game blits anything like
this wide — the floor is 400 and the widest background block is 104 — so the
limit had never been hit.

## The floor joints, back over the reflection

The marble carries a perspective grid — a fan of joint lines radiating toward
the vanishing point above the carpet, plus horizontal courses — and it is what
makes the floor read as a floor. The reflection covered it.

`data/TWRJNT.BIN` puts it back. `tools/make_twrjnt_bin.py` derives it, nothing
authored: the pixels are `FL_TOW.BIN`'s own (raw 6bpp, 1200x75); the 21
radial lines are *found*, by a thin-line response and a Hough vote over
`x = a + s*y`; the courses are rows whose dark response covers a quarter of
the marble; and the carpet is exactly `twr_runner_tbl`'s spans. Everything
else is index 0.

`twr_runner_code` blits the **whole 400-pixel row** from TWRJNT for every
band row, 0..`TWR_BKR`-1, with `floor_code`'s own arithmetic and its control
word `0E002h` (write non-zero), so index 0 leaves the reflection showing and
one pass draws joints *and* carpet. The joints parallax for free: every row is
sheared by `skew_oc + L*skew_dx` exactly as the floor under it is.

Cost: 54 blits and 21,600 pixels, **about 0.9 ms of pixels plus ~0.4 ms of
per-blit overhead** — against the old carpet-only pass, which was already 49
blits of narrower spans. Phase D checks the BIN against its sources.

## What it costs, and the one queue nobody was watching

Every background block, every sprite and the whole HUD go on one queue: 500
cells at `dma_q`. **Whatever has not drained when the next frame starts is
thrown away** — `init_dma_regs` resets the pointer and the count with no regard
for what is pending — and the score area is queued **last**, at `disp5`, after
every display list. So an over-budget stage does not tear or drop sprites. It
drops the life bar, in and out, with nothing else visibly wrong.

Nothing in the game reported this. `peak_overload` times the CPU process pass;
`qdma_drops` counts a *different* queue (the misc one `qdma`/`qdman` push to).
Both read clean the whole time. There are four counters now — `deep_dmaq`,
`dmaq_over`, `dmaq_late`, `dmaq_lost` — and two of them are on the GAME AUDITS
page as **DMA QUEUE PEAK** and **BLITS ABANDONED**.

Measured on the same rig and the same sweep:

| stage | peak queue | frames abandoning blits |
|---|---|---|
| DEAD POOL | 111 of 500 (22%) | 0 |
| curback 1 | 135 (27%) | 30 |
| THE TOWER, before | **439 (87%)** | 587, worst 86 entries |
| THE TOWER, floor skip | 385 (77%) | steady stops **0** |
| THE TOWER, today (no backing, `shad_fast`) | 213 (43%) | **0** in a fight |

(The first three rows are an older sweep, and its combat window ran on past
the end of the match — see *The game-over screen drew freed objects*. Only
frames spent actually fighting on this stage count now.)

### `skew_skip` — do not draw what the reflection covers

The reflection covers the whole marble band: wall blocks where the wall is
solid, and where it is not the marble would only be in the way of the sky
(the autoerase colour — see the sky section). So `floor_code` was drawing 54
scanlines of marble and having every one of them completely repainted — 54 of
the 500 queue cells and ~21,600 pixels a frame, on the stage with the least of
both to spare.

`skew_skip` (RAM.ASM) is texture rows `floor_code` may skip at the *back* of
the floor. `setup_floor_info` clears it for every stage, so no stock floor
changes by a pixel; `tower_backdrop_reflections` sets it to `TWR_BKR`. It is
set **there** and not in `calla_tower` on purpose: that is the routine whose
coverage makes the skip safe, and if the reflection ever stops covering the
full band this has to go with it or the bare autoerase colour shows through
the floor.

It walks `floor_code`'s own loop state forward rather than moving `@skew_y` or
`@skew_sag` — those two *are* the texture's row 0 as far as `twr_runner_code`
is concerned, and it re-derives the carpet from them every frame.

**Verified invisible, not assumed.** One ROM, two runs, `@skew_skip` held at 0
from Lua in the second (`MK2_BK_NOSKIP=1`): **0 differing pixels inside rows
181–234 at all five camera stops**, and the runner check clean on every line.

### The frame, measured

Counting queue cells turned out to be the wrong unit. Two things were
measured instead, and the second is what the stage is budgeted by now.

**What the emulators bill.** FBNeo's `midtunit_dma.h` (ported from MAME)
times every blit at **41 ns a pixel** of the *programmed* blit: an unscaled
one pays its whole `w*h` — transparent pixels, `ofset`/LRSKIP-clipped pixels
and off-screen overhang included; a scaled one pays its drawn size,
`((w<<8)/xstep) * ((h<<8)/ystep)`. A 54.7 Hz frame is ~445,800 of them. The
rig bills every cell (`dma_bill` in `tower_backdrop_test.lua`): about
**11.7 ms** on this stage, 64–68% of the frame — which says there is plenty of
room, and there was not.

**When the last blit actually starts.** `display` runs from the display
interrupt straight after `@tick` is bumped, and `init_dma_regs` discards
whatever has not *started* by the next one. Two MAME write taps — `@tick`,
and `dmactrl` with bit 15 (a blit starting) — give the real timeline. Before
`shad_fast`:

- the CPU had finished queuing at **27%** of the frame, and the last blit (the
  HUD) did not start until **86% on average, 90% at worst** — the DMA was the
  bottleneck, ~15.7 ms busy against an 11.7 ms pixel bill;
- the missing ~4 ms is **per-blit overhead**: gap between starts minus the
  previous blit's pixel time averages **11.4 us**, about 280 pixels' worth.
  It is two populations: ~4–8 us for a queued cell (the interrupt and the
  six-long copy) and **~16–18 us for ~135 blits a frame** that are not in the
  queue at all.

Those 135 are the shadows.

### Two blits a shadow piece — `shad_fast`

`shadow_p1p2` draws each fighter's shadow **one scanline per blit**, polling
the DMA idle between every one, from inside the DMA interrupt. It has to walk
the rows itself because fighter art is zero-compressed — a header byte per
row, so rows are not a fixed length — and it wants every 4th one. That is
~2.3 ms of the frame, more than any layer of the stage.

The DMA walks compressed rows itself when it scales, so `shadf` (MKDISP.ASM,
in SHADORG) draws each piece in two blits:

- **A**: height `4(n-1)+1` at ystep 4.0 — FBNeo emits a row while
  `iy < height<<8` and samples source rows 0,4,8.., so this is *exactly* the
  loop's n rows (n = sizey/4);
- **B**: the loop's last `GO` repeats the last row one line down "to fill in
  holes". Height `4(n-1)+1` at ystep `4(n-1)` is two rows, sources 0 and
  4(n-1), placed so the second lands on `y+n`; the DMA's **Y window**
  (`dmatplft`, left on top/bottom by MKINIT) keeps only that line, so it is
  billed as one row. n=1, and n>64 (4(n-1) would overflow 8.8), use A's shape
  one line down instead.

The window is the stage's `shad_ytop..shad_ybot` band — the loop's per-row
gate — intersected with the page, and goes back to `[top+253:top]` after,
which is what `dirq` sets every frame. Every window write waits for the DMA
idle first: the chip may read its clip registers for the whole blit.

Measured, one ROM, `@shad_fast` flipped from Lua (`MK2_BK_SHADFAST=0|1`):

| | stock loop | `shad_fast` |
|---|---|---|
| blits started a frame | 329 | 194 |
| last blit starts (avg / worst) | 86% / 90% | **73% / 77%** |
| stock DEAD POOL, for scale | 74% / 76% | — |

**Pixel-identical where the stock loop is right, and right where it is not.**
36 snapshot pairs across a fight: 26 identical, 10 differing by 3–11 pixels in
one small piece. A per-frame check walks every live piece's rows both ways:
all 40 compressed pieces agree exactly; the 2 that differ are **uncompressed**
(control bit 7 clear), and the stock loop reads a header byte they do not
have and samples the wrong rows. The DMA's walk is the sprite's own.

`shad_fast` is per stage — `init_bakmods` clears it and `calla_tower` sets
mode 1. At the time of this Tower experiment other stages kept mode 0.
The [September 2026 Wasteland prototype](graphics_opportunities/WASTELAND_SHADOW_PROTOTYPE.md)
adds mode 2 in `calla_battle`: fast compressed pieces, legacy uncompressed
pieces. Tower retains its full fast path and its existing raw-piece correction.
The [Kombat Tomb continuation](graphics_opportunities/TOMB_SHADOW_PROTOTYPE.md)
also selects mode 2; its independent stage checks retain Tower mode 1.

### The game-over screen drew freed objects

The rig's combat figure kept reporting ~780 dropped frames, and none of them
were the fight. Its idle P1 loses the match at about c850 and the game goes to
`gs_gameover`, where **`grab_screen`** (MKUTIL.ASM) freezes the picture: it
zeroes every list head from `baklst8` to `last_objlst` in RAM.ASM and rebuilds
the object free list — and leaves `dlists` alone, so `display` keeps walking
the stage's own table over the frozen screen. Stock stages keep every list in
that block and are safe.

THE TOWER's private list heads were declared beside their code, outside the
block. They survived, still chained through objects that were now free and
being handed out again, and the display drew ~300 of them a frame: a jumble of
wall blocks, a guard and pieces of the HUD, and the GAME OVER sequence never
got its own screen up. **All eight private heads in the game** — the tower's
five, FLAPJACK's floor, YOTEIGAI TOR's rain, the cave eyes — now live *inside*
the block (RAM.ASM, just above `last_objlst`), and the freeze clears them with
everything else. A new private display list goes there.

What is left after the fix is ~30 frames of the freeze in which the floor and
joint passes queue 75 rows over the frozen picture and the DMA is not
draining. They are discarded unseen; the picture holds, fades and moves on.

Two of the obvious next levers were tried and are **dead ends**, both measured
rather than reasoned:

- **Merging the runner pass's per-row blits.** 49 rows are only 22 distinct
  spans, so 27 of its blits look redundant. The T-unit DMA has no source
  STRIDE — a multi-row blit advances by `xsize` and nothing else, which works
  for sprites only because their rows are contiguous. These rows are
  `TWR_FLOORX` apart. `ofset` is not a stride either: it is per-row
  leading/trailing clip, the thing `clip_a_row` uses to cut the clouds to the
  arch window. Built it anyway — every merged group drew nothing, the carpet
  vanished from the whole band, and the queue check found 22 of 22 groups bad.
- **Fitting the sky backing to the window shapes.** Covering the arch, the
  window row and the slits takes **456 rectangles** — ~47,000 pixels traded for
  ~450 blits at ~5–8 us of overhead each. Moot now: the backing is gone
  and the autoerase supplies the sky.

Levers still unused, largest first: the clouds behind the wall are drawn
full size (29–58k pixels, up to 2.4 ms) though only the arch window shows
them, and LRSKIP clipping is still billed at full `w*h` — cropping them means
changing the blit's own sag and width; and the joints pass (~1.3 ms all in).

## Traps this hit, or dodged

- **`oflags` is `0f0h`, not `160h`.** `160h` is `oflags2`, the *game* flags, and
  is legitimately 0 on a background object. Reading it hid the `m_fliph` bit and
  made a working mirror look broken. `e082` vs `e092` is the tell.
- **`ani0` ORs the frame's control word into `oflags`** rather than replacing
  it, so `m_fliph` is set **once** after creation and survives every
  `frame_a9` — the property that made the sonic clap's trail stick.
- **`anig1` never touches `opal`**, so a palette set by hand after creation
  holds for the life of the object. That is what makes POF> art workable.
- **POF> and the table-name collision.** LOAD2 would have emitted CASTLE's own
  palette name, `PILLAR`, and this stage already carries `PILLAR2`. An `ASM>`
  table-name collision is silent — last writer wins, the earlier table strands
  as `.~BL` — so the LOD embeds no palette and `reflect_proc` applies
  `STATREF_P` (BGNDPAL.ASM) by hand, the way `kahn_hamswipe_start` applies
  `PURPHAM_P`.
- **Don't verify the palette by sampling the screen.** `STATREF_P` is CASTLE's
  `PILLAR` ramp and the floor is CASTLE's floor; the two overlap so heavily that
  "these pixels are STATREF_P colours" matches most of the marble as well. The
  rig reads `opal` instead. (Also: MAME expands 5-bit channels as
  `(v<<3)|(v>>2)`, not `v<<3` — an exact-match test against `v<<3` finds
  nothing.)
- **`oscale`'s ystep is the HIGH half of the word.** `000040100h` is ystep 4 —
  a 64× **magnify** — not a quarter. The pillar became a black bar the height of
  the screen. It is `004000100h`.
- **`_rect` (tower3_statue_layout.py) is INCLUSIVE** — `x + w - 1`. The row
  below a block is `y2 + 1`, not `y2`. Both align tools had this wrong and every
  strip sat one row high, overlapping its own parent's last row. Invisible, but
  a guard that encodes an off-by-one teaches it to whoever reads it next.
- **`_bgnd_offset` only parsed decimal.** PLANE5's placement is written
  `.word 0,-021h`, so the parser returned `None` for that module and every check
  keyed off it *silently stopped checking*. Fixed with a GSPA literal parser.
- **Don't `rets` out of a routine that has already `mmtm`'d.** The
  pool-exhausted path did, which walks the return off whatever was under the
  saved registers.
- **A reduction ceils.** See the wall section. Floor put the pillar reflections
  one row high; it would have cracked the wall.
- **GSPA runs out of memory.** BGND.ASM reached 8,673 lines and the 16-bit DOS
  assembler aborted with `Out of memory` at PASS 2. The backdrop moved into
  `src/TWRBACK.ASM`, its own linked object (MAKEFILE + mk2.cmd), and BGND.ASM
  went back to 8,295. `callr` cannot cross an object boundary, so the entry is
  `calla` and the six shared symbols are `.globl`.
- **Siblings run newest-first.** `getprc` links a new process straight after its
  creator, so of the processes `calla_tower` creates, the last runs first.
  `backdrop_follow`, created after `cloud_proc`, copied `clip_a_row`'s pins and
  wraps a tick late — reflections sat 3, 6 and 211px off their clouds at the
  arch's left edge. It is created first now, so it runs last. (The same mechanism
  dispatches P2 before P1.)
- **A pinned camera never comes to rest.** With the fighters parked the scroller
  hunts between two positions, ±1px a frame, and MAME's snapshot is a frame away
  from the state a Lua rig reads. A checker that trusts the logged skew to the
  pixel reports phantom failures at the runner's edge; it now tries ±1px and
  fails only on interior pixels, which no camera jitter can produce.
- **Slice a routine by its LABEL line.** The generator reads `floor_x` and the
  floor's line width out of `floor_code`. `index("floor_code")` hit a comment
  2,700 lines earlier and `index("floor_exit")` a `jrn floor_exit` branch that
  comes before the immediate — the slice missed the very line it wanted.
- **Match the tiling check to the tiling rule.** A half-open run drops its last
  partial group (the wall's top 2 source rows); a checker using per-row rounding
  keeps it and "fails" every column on correct data.
- **Don't find the runner by colour.** The first checker took a fighter's red
  trousers for the carpet. It now computes the exact span from `skew_oc`,
  `skew_dx`, `skew_y` and `ceiling_y` logged at each stop.
- **A private display list's head must live in RAM.ASM's list block.**
  `grab_screen` clears `baklst8..last_objlst` and nothing else, then frees
  every object. A head declared anywhere else survives pointing into the free
  pool — see *The game-over screen drew freed objects*.
- **A rig's measurement window can outlive the thing it measures.** 1800
  frames of "combat" were 875 of fight and 925 of game over; `curback` stays 3
  through it. Gate on `gstate == gs_fighting` too.
- **Pixels are not the whole bill.** Per-blit overhead is ~5–8 us a queued
  cell and ~17 us a polled one. Fifty small blits cost as much as a
  100x100 sprite. Measure the timeline, not the cell count or the pixel sum.
- **The build.py link race is real.** `build.py` returned before `mk2.out` was
  written and the chained `makerom.py` packaged the *previous* link — the ROM
  under test still had the fast flicker in it. Compare `src/mk2.out`'s mtime
  against `rom/mk2_uj12.bin`'s before believing a result.

## Space

3,572 bytes at flat `0xBE6000`, LOAD2 address `0x3F30000`. Smaller than the
4,124 the pixels would need uncompressed, because `ZON>` zero-compression is
very effective on art that is half index 0.

**The run was unclaimed.** `0xBE6000` is exactly where HAMGLOW's slot ends and
`0xBE8000` is exactly where ERMFIRE's begins — the one gap in bank 1 that
belonged to nobody, so this took growth room from neither. Do not widen it in
either direction without moving that file's base first.

Bank 1 is correct because these are DMA-drawn background objects with
`m_shadow` clear, so `shadow_p1p2`'s bank-less CPU read never walks them — the
same reasoning as HAMGLOW and ERMFIRE next door. There is no ROM bank-select
logic anywhere in the source; banking only constrains CPU-side pixel readers
(`movie_run`, `shadow_p1p2`).

## Files

| file | what |
|---|---|
| `data/STATREF.LOD` | packs the six strips out of CASTLE.IMG, bank 1 |
| `src/STATREF.TBL` | LOAD2-generated records (promoted, Phase B1) |
| `src/BGND.ASM` | `tower_reflections`, `make_reflection`, `reflect_proc`, `tr_*`, `a_statref*` |
| `src/BGNDPAL.ASM` | `STATREF_P` (CASTLE's `PILLAR` ramp) and `PILREF_P` (80% of `PILLAR2`) — the two dimmer knobs |
| `tools/tower3_reflection_align.py` | derives the six guard constants; Phase D |
| `tools/tower3_pillar_reflect.py` | derives the two pillar constants, checks TWR_PHDR and the drawn height; Phase D |
| `tools/tower_scale_probe.lua` | the experiment that proved m_flipv + oscale on background art |
| `tools/tower_scale_rounding_probe.lua` | measured that a reduction ceils |
| `src/TWRBACK.ASM` | the backdrop's code, its three list heads and the generated data |
| `tools/tower3_backdrop_reflect.py` | generates `src/TWRBKREF.ASM`, proves the wall tiles; Phase D |
| `src/TWRBKREF.ASM` | generated: wall records, runner spans, the depth tables, four dimmed palettes |
| `tools/tower_backdrop_test.lua` + `run_tower_backdrop_test.ps1` | the backdrop rig: five stops, ledge sweep, combat; the DMA bill, the `@tick`/`dmactrl` timeline, the shadow row-walk check |
| `data/TWRJNT.LOD`, `src/TWRJNT.TBL` | the floor joints texture (bank 1, `03cb0000h`) |
| `tools/make_twrjnt_bin.py` | derives `data/TWRJNT.BIN` from `FL_TOW.BIN` + `twr_runner_tbl`; Phase D |
| `src/MKDISP.ASM` `shadf` | the two-blit shadow path, behind `@shad_fast` |
| `tools/tower_runner_overlay_check.py` | the runner, checked at its exact computed span |
| `tools/tower_reflection_test.lua` + `run_tower_reflection_test.ps1` | the rig |

## Tuning

- **Dimmer/brighter:** scale `STATREF_P` in `src/BGNDPAL.ASM`. The strip is a
  checkerboard against index 0, so its brightness is entirely those 62 colours —
  no art rebuild, no SAG change.
- **Move one:** it follows its guard automatically. To take it off centre, edit
  `ANCHORS` in `tools/tower3_reflection_align.py` and `--apply`; never hand-tune
  the constants in BGND.ASM.
- **Bring back a shimmer:** point a descriptor's `tr_table` at a two-entry table
  and lower `tr_ticks`. Read the walk-back above first.
- **Pillar dimmer/brighter:** scale `PILREF_P` in `src/BGNDPAL.ASM`. 80% of
  `PILLAR2` today; 100% reads as a pillar lying on the floor, 65% as a shadow.
- **Pillar longer/shorter:** `TWR_PSCALE`'s ystep. Keep it a power of two or
  `make_pillar_reflection`'s `srl 2` needs to become a divide, and re-run
  `tools/tower3_pillar_reflect.py`, which checks the drawn height still lands on
  marble.
- **Cloud speed:** `TWR_CLD7_V` / `TWR_CLD8_V` (the two cloud rows) and
  `TWR_HCLD2_V` / `TWR_HCLD3_V` (the high clouds), beside `tower_high_cloud_proc`
  in BGND.ASM - 16.16 px per tick. Halved 2026-09-18 (the near row was
  crossing the screen in 2.4 s, and its reflection crossed the floor at the same
  speed); measured on the machine at 1.50 / 0.75 / 0.5625 / 0.25. The
  reflections follow automatically - `backdrop_follow` copies positions.
- **Backdrop brightness / colour:** three constants at the top of
  `tools/tower3_backdrop_reflect.py`, then `--apply`: `REFL_K` (0.80) scales
  every channel, `REFL_TINT` (0.60) pulls each colour toward the marble's own
  hue at its own luminance, and `REFL_FLAT` (1.00 = off) squashes highlights
  toward each palette's mean. `REFL_TINT` is the one that changes how much the
  floor reads as a mirror; `REFL_K` alone barely does. The depth needs no
  constant: it is measured from the floor's own art and the wall's height.
- **Frame budget:** `skew_skip` in `tower_backdrop_reflections` (only ever
  as large as the band the reflection actually covers) and `shad_fast` in
  `calla_tower`. Check it with the rig's timeline — "the last blit started at
  N% of the frame" — not with the queue depth.
- **How steady the camera is under a jump:** `climb_limit`, set in
  `calla_tower` (BGND.ASM). Rows above `ceiling_y` the view may climb; 6
  **0** here, 16 everywhere else: an ordinary jump crosses the chase barrier
  every time, and on a mirrored floor the whole room lurches with it.
  Raising it back to 16 restores stock motion.
- **Where the fighters stand:** `ground_y` in `tower_mod` — 0ebh. The shadow
  follows it; the floor and the reflections do not (they read `ceiling_y`),
  so this moves the fighters alone.
- **The sky in the mirrored windows:** it is the autoerase colour,
  `tower_mod`'s first word, undimmed. To dim it, call `make_sky_backing` again
  (see *The sky in the mirrored windows* for what that costs); the generator
  still re-finds the pen in `newcld_p` from the autoerase word.
- **Where the guards and pillars stand:** the `.word` y in `tower_mod`
  (BGND.ASM). Re-run `tower3_flame_align.py`, `tower3_reflection_align.py` and
  `tower3_pillar_reflect.py` with `--apply` afterwards; all three re-derive.
