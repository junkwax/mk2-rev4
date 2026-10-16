# Johnny Cage's OTOMIX logo

The logo painted down the leg of Cage's pants reads **backwards** whenever he is
drawn mirrored, which is half the time - a sprite is one drawing, flipped by the
DMA. This is how it is hidden facing left, what it cost, and what a palette-only
version would cost instead.

Shipping method: **the logo is its own subframe**, and the display walker does
not queue that subframe while he is mirrored. Facing right he is exactly as
painted; facing left he is Midway's own pixels.

---

## 1. The logo is this project's repaint, not Midway's

Decoded straight out of the arcade ROM (`mk2.zip`, 12 video chips
un-interleaved, records decoded at the SAGs in the read-only tree's
`src/MKJC.TBL`): **retail MK2 has no OTOMIX on the stance, the walk, or any of
the frames this covers.** `mk2-readonly` agrees, byte for byte.

The lettering was painted into `data/CAGE1-10.IMG` in this project. Those ten
files are **git skip-worktree**, so HEAD still holds Midway's art and the
repaint has never been committed - which is exactly what makes the cut below
possible, and what a `git checkout` of them would silently undo.

Midway did paint it on a few frames of their own - `JC2DEATHBLO4A-10A` and a
handful of others carry it, already backwards. Those are left alone: retail
stays retail.

## 2. What ships

`tools/make_cage_logo.py` cuts the lettering off every piece that carries it:

| | |
|---|---|
| base `<PIECE>` | the piece with its logo pixels put back to Midway's, written into its own IMG - same size, same anipoint, same label, so nothing that names the piece changes |
| logo `<PIECE>L` | the lettering alone, cropped, anipoint moved by the crop. All 174 live in `data/JCLOGO.IMG`, packed by `data/JCLOGO.LOD` into bank-0 slot `0x728000..0x730000` (24,628 bytes of a 32,768-byte slot) |

Every frame list draws `<PIECE>L` straight after `<PIECE>`, so it lands on top.
**Facing right, base + logo is the painted art pixel for pixel** - the tool
proves that for all 174 pieces before it writes anything, and again in Phase D.

What the logo is, exactly: the pixels that differ from retail within 2 px of a
changed grey (`LOGO_REACH`). Not every difference - the same pieces carry other
repairs (a blood stump, split-leg shading) which stay in the base and so show
both ways. Two pieces added in this project (`JCSHADOWKICK1A/2A`) have no retail
record at all; their lettering is found by the classifier in
`tools/cage_logo_scan.py` and filled from the pants around it.

**Runtime** (`cagelogo`, MAINEQU.ASM; `clip41`, MKDISP.ASM): the walker skips a
piece whose SAG is inside JCLOGO's slot and whose own control word is flipped.
Six instructions, per piece, on every display pass - nothing a game process does
can put the logo back. `CL_SAG_LO/HI` in MKDISP must move with the LOD;
`make_cage_logo.py --check` fails the build if they drift apart.

**The victory faces the camera**, so it is never mirrored:
`jc_face_front` (MKCANNED.ASM) turns a mirrored Cage round in place first, and
they play as painted with the logo showing whichever side he won from.

### Editing the art

```
python tools/make_cage_logo.py --restore    # logo composed back into CAGE*.IMG
  ...edit the art...
python tools/make_cage_logo.py --apply      # cut again; lists and JCLOGO.GLO follow
python build.py && python makerom.py && python makevrom.py && python mamerom.py
```

Never hand-edit `data/JCLOGO.IMG`; it is generated. A full `build.py` is
required after any art change (LOAD2 has to repack), not `--asm-only`.

### Files

| file | what |
|---|---|
| `tools/make_cage_logo.py` | the cut: IMGs, `data/JCLOGO.IMG`, `src/JCLOGO.GLO`, the frame lists. `--apply` / `--check` (Phase D) / `--restore` / `--sheets` |
| `tools/cage_logo_scan.py` | the classifier, for pieces with no retail record |
| `data/JCLOGO.LOD` + `src/JCLOGO.TBL` | the packed logo pieces |
| `src/MKDISP.ASM` | `CL_SAG_LO/HI`, `f_cagelogo`, the skip in `clip41` |
| `src/MKCANNED.ASM` | `jc_face_front` |
| `src/MKJC/MKDEATH/MKDIE.ASM` | `.include jclogo.glo`, and `<PIECE>L` in the frame lists (MKFRIEND is gone - friendships were removed 2026-09-20) |
| `tools/cage_logo_test.lua` | the rig |

### Proof

`tools/cage_logo_test.lua` reads the DMA object queue from a write tap on
`last_dmaq` - dsa9 writes it once per display pass, right after the last object
is queued, so inside the tap the queue is complete and no game process has run
since the objects were walked. Both fighters are Cage; the scenes pin them, swap
sides so both turn round, and end the round so the next one must start (growing a
fighter's piece lists wedged round teardown once before - Baraka's victory gleam).

| run | passes | backwards logo drawn | logo missing facing right | round 2 |
|---|---|---|---|---|
| `CL_ENABLE=1` | 1,861 | 0 | 0 | yes |
| `CL_ENABLE=0` (control) | 1,829 | yes, as expected | 0 | yes |
| `CL_WINNER=2` (wins facing left) | 2,230 | 0 | 0 | victory un-mirrored on all 293 passes |

## 3. The palette alternative - built and proved, not shipped

Instead of a second subframe, paint the logo back INTO each piece on palette
slots nothing else uses, and hide it by writing the pants colour into those
slots. `tools/cage_logo_pal_preview.py` builds both versions of the art offline
and renders them: *painted today | palette-visible | palette-hidden | retail*,
into `tmp/cage_logo_pal/`.

**Why it is even possible**: 99% of the lettering sits on one flat colour -
`0x3f` in the ordinary palettes, `0x32` in the bloodied ones. There is almost no
shading under the logo to lose.

At 8 slots per layout, quantising every logo colour onto them (a halo pixel only
3 steps off the pants still reads as a ghost on near-black cloth, so it needs a
slot too):

| | ordinary | bloodied |
|---|---|---|
| slots freed by merging colour pairs | 8 | 8 |
| his OTHER pixels repainted by those merges | 34,038 of 1,655,276 (2.1%) | 2,496 of 153,685 (1.6%) |
| worst colour error of those merges | 2 steps of 31 | 1 step of 31 |
| visible logo pixels shifted by quantising | 592 (5%), mean 0.14 steps | 11 (1%) |
| hidden logo pixels differing from Midway's | 151 of 13,792, and 105 of those in ONE piece | |

**It wins** 24,628 bytes of bank 0 (which is full), 174 records, 178 frame-list
lines, JCLOGO's LOD/TBL/GLO and its build wiring, and one or two blits a frame.

**It costs** a permanent 1-2 step recolour of ~2% of his other pixels in both
facings, and more runtime than a skip: the hidden Cage needs a colour map of his
own, because a mirror match puts both fighters on one map (the twin-map pass over
colour maps 80-127, which are unallocated - `numpal` is 80 and colour RAM holds
128 - was built and proved in MAME on this branch before being removed in favour
of the cut).

**Where it cannot match the cut**: `JCSPLITLEG3B`, where what the cut calls
lettering is really a repaint of his sock and shoe, over white rather than pants.
A palette can only recolour, never restore Midway's pixels, so hiding it as pants
would punch black holes in the shoe (`tmp/cage_logo_pal/problem.png`). The bake
gives that group a slot of its own that hides as the shoe's own light grey, so
nothing is punched out - but those pixels then stay put in both facings instead
of going back to Midway's blue sock. Checked against the built art in
`tmp/cage_logo_pal/shoe_check.png`.

### Built and proved, 2026-09-25

`tools/make_cage_logo_pal.py --apply` bakes it; `cagepal` (MAINEQU.ASM) compiles
the runtime in; `src/JCPALEQ.ASM` is generated beside the art and is the whole
contract between the two. The plan (which slots, what each hides as, which
colour pairs were merged, and the palette words they replaced) is SAVED in
`tools/cage_logo_pal_plan.json` rather than re-derived - the bake rewrites the
palettes it would plan from, so a second run planned differently and disagreed
with its own output until the plan became an artifact.

Two pieces are left to the cut on purpose: `JCSHADOWKICK1A/2A` were added in
this project and have no retail pixels to hide back to, so they keep their logo
PIECE and the walker's skip. That is why both methods' runtime can be compiled
in at once.

A full build passed Phase D (both locks unmoved), and
`tools/cage_logo_pal_test.lua` checked every display pass:

| run | passes | blits checked | wrong map | flipped Cage drawn on his own map | twin colours wrong |
|---|---|---|---|---|---|
| `CL_ENABLE=1`, shared map | 2,230 | 243,302 | 0 | 0 | 0 |
| `CL_ENABLE=0` (control) | 2,230 | 244,204 | 0 - no twin ever used | - | - |

The enabled run spent 1,367 passes with BOTH fighters on one colour map facing
opposite ways (the rig moves P2 onto P1's map, reference counts kept straight),
which is the case the twin exists for, and round 2 started normally.

### Trying it

`rom/mk2_cagepal.zip` is that build. To play it:

```
copy rom\mk2_cagepal.zip C:\MAME
oms\mk2.zip    ... and back again with
copy rom\mk2.zip         C:\MAME
oms\mk2.zip
```

It is built from the tree as of 2026-09-25 with the palette method ON and the
art baked; the shared tree itself is untouched and still ships the cut. It still
PACKS JCLOGO, so the 24.6 KB is not reclaimed in this build - dropping the LOD
(IMGBUILD.BAT, makevrom's slot, promote_tbls, the MKJC include) is the last
mechanical step if the method is adopted.

### Switching the tree between the two

```
python tools/make_cage_logo.py --apply       # the cut state (what ships)
python tools/make_cage_logo_pal.py --apply   # the palette state
```
and set `cagelogo` / `cagepal` (MAINEQU.ASM) to match, along with build.py's
Phase D entry. Never run both bakes: they are mutually exclusive art states.
