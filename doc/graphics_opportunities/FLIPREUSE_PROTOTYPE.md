# Reusing art with flips - THE TOWER's clouds

**Status: implemented and validated in MAME, 12 September 2026.** This is
opportunity 17 (reuse art with scale and flips) in
[the graphics audit](../GRAPHICS_OPPORTUNITIES.md), P1. Two cloud images that
were exact mirrors of the other two are gone from the video ROM, and THE
TOWER draws their originals h-flipped. That frees **10,869 bytes of MK6MIL**,
and all 76 compared frames are pixel-identical, floor reflections included.
FBNeo and physical hardware have not been run.

![THE TOWER, flip ROM: the cloud row behind the monk. Two of the four clouds are now cloud1a/cloud1b drawn mirrored, and the frame is identical to the stock ROM.](flipreuse_tower.png)

## The scan: what flips and scales could save

`tools/flip_scale_scan.py` decodes all 9,940 distinct payloads out of the
packed video ROM (art_identity_snapshot's decoder and layout). It groups
payloads that are the same picture in some orientation (as stored, H, V,
H+V), and looks for exact 2× copies.

| Kind | Classes | Reclaimable |
|---|---|---|
| Flip classes | 27 | **19,281 bytes** |
| Exact duplicates (opportunity 05's) | 29 | 4,676 bytes |
| Exact 2× copies | 0 | 0 |

The largest flip classes:

| Pair | Bytes | Owner |
|---|---|---|
| `cloud1d` = H(`cloud1a`) | 6,385 | THE TOWER cloud row, MK6MIL |
| `cloud1c` = H(`cloud1b`) | 4,483 | THE TOWER cloud row, MK6MIL |
| `BGBIGFIST1C` = H(`BGBIGFIST1B`) | 1,729 | Shao Kahn, MK5MIL |
| Kitana `KT2VARMLEFTn` / `KT2VARMRIGHTn`, 8 pairs | ~3,900 | MK3MIL |
| `ROTATE5A-D` / `E-H` (both halves unreferenced) | ~1,830 | MK7MIL - dead art, not reuse |
| Raiden `RNHEAD2/3` → `6/7` (H+V) | 764 | MK4MIL |

"Reclaimable" counts payload bytes, not a plan. Each pair still needs its
consumer to draw the kept image flipped, with the anchor and clip handled.
The clouds show that the clip is the hard part.

## The cloud change

| | |
|---|---|
| Art | `cloud1c`, `cloud1d` removed from [MK6MIL.LOD](../../data/MK6MIL.LOD), their records from [MKBGANI.TBL](../../src/MKBGANI.TBL) (src-only, so `promote_tbls` would have kept them) and `.GLO` |
| Code | `cloud_row` names `cloud1a`/`cloud1b`, and `cloud_mirror` marks entries 0-1 h-flipped; `get_a8_to_a11` sets `m_fliph` before `ani_flag`; `cloud_mirror_off` / `cloud_mirror_on` bracket `clip_a_row` ([BGND.ASM](../../src/BGND.ASM)) |

**The part that is not free: clipping.** `clip_a_row` clips the cloud row to
the arch window itself. It writes `oxpos` as the clipped left edge, and the
low and high bytes of `ofset` as the left and right skips, all in unmirrored
terms, and the row positions itself by reading its neighbours' `oxpos`. A
flipped image cannot be drawn from those values. The DMA counts skips in
source order and puts the first drawn source pixel at the destination, which
on a flipped image is the right-hand end. So a mirrored cloud needs:

- **its two skip bytes swapped**, and
- **its x pulled left by the left skip plus the right skip.**

That is the rule Midway's own flip-aware clipper applied (`dclipl`'s
commented `lclp`/`rclp` block, MKDISP.ASM: `subxy a2,a10` on both sides). To
keep the stock logic untouched, `cloud_mirror_off` undoes it at the top of
`clip_a_row` and `cloud_mirror_on` reapplies it at the end. The pull is
stored in the cloud's `ozval`, which nothing reads for these hand-linked
objects. `backdrop_follow` (TWRBACK.ASM) copies `oxval`, `ofset` and `oflags`
into the floor reflection every tick, so the reflections inherit all of it.

## Result

Stock ROM against the flip ROM on THE TOWER, with the fighters hidden. Both
cloud rows drift and wrap for 900 frames, with a snapshot every 12 frames.
Both boots start in the same state: logical cloud positions, camera and
object pool.

| Gate | Result |
|---|---|
| Frames pixel-identical, sky and reflection band | **76 of 76** |
| Mirrored clouds on the flip ROM | 4 (two per row) |
| Snapshots with a mirrored cloud edge-clipped | **76 of 76**, so the corrected clip was drawn every time |
| Art identity (decoded pixels, whole ROM) | 2 records removed (`cloud1c`/`cloud1d`), 972 moved with identical pixels, 1 changed (below) |
| MK6MIL | 0x153A8 bits = **10,869 bytes** freed; everything after the clouds moved down by exactly that |

## What the A/B caught first

1. **The swap alone was wrong.** The first version swapped the skip bytes but
   left x alone, which is what the DMA source-order analysis suggested. All 76
   frames differed (786–4,067 px) exactly where mirrored clouds were clipped.
   Midway's commented clipper supplied the missing x pull.
2. **The rig's own start check.** With the pull in place, the mirrored
   clouds' `oxpos` legitimately differs from stock. The start check now
   compares logical x (`oxpos − ozval` on a mirrored cloud) and matched on the
   first boot.

## Mileena's victory arms: mirrored pieces inside a multipart frame

The eight `KT2VARMLEFTnA` arms were exact mirrors of `KT2VARMRIGHTnA`. They
exist only as pieces in `KT2VIC11-18` (`a_fn2victory`), and a frame list
carries only image pointers, so the flip has to be carried by the header.

| | |
|---|---|
| Art | the eight left arms removed from [MK3MIL.LOD](../../data/MK3MIL.LOD) and [MKFN.TBL](../../src/MKFN.TBL): **3,934 bytes** of MK3MIL (0x7AF6 bits) |
| Aliases | `KT2VARMLEFTnA` re-defined in [MKFN.ASM](../../src/MKFN.ASM) as headers onto the matching right arm's SAG, with that arm's control word plus `dmahfl`, and the **old left record's anipoint** (the anchor of the image as drawn) |
| Guard | all eight anchored to their right arm and hash-checked by `tools/sync_inline_sags.py` (Phase D) |

Two engine changes make a mirrored piece header mean something. Both are
exactly the old behaviour for all 10,299 current headers, none of which
carries a flip bit.

1. **`ani2` (MKUTIL.ASM)** used to clear a header's flip bits and OR in the
   object's. It now XORs them. A piece's flip is object flip XOR header flip,
   so an alias draws mirrored and flips back when the fighter turns. `dx`
   still mirrors from the object's flip alone, which is why the alias keeps
   the left record's own anipoint.
2. **`dclipl` (MKDISP.ASM)** kept the object's flip bits while walking
   multipart pieces and ORed in each piece's control word. It now takes the
   flip only from the piece; the object's DMA write-mode bits (`dmacnz` for
   ghosts and flashes) are still kept. The first A/B found this: facing
   right was identical, but facing left 16 frames differed (up to 717 px),
   because the object's flip was ORed back over the alias's XORed one and the
   arm was drawn mirrored twice.

Every other writer of a piece control word already carries the flip in the
piece: `ani2`, MKZAP's piece-flip toggle, the spear's `stuff_rope_flags` and
the ghost copies.

**Result.** Stock (cloud build) against the alias build, Mileena winning a
round on each side against Cage:

| Gate | Facing right | Facing left |
|---|---|---|
| Snapshots pixel-identical (whole screen, Cage included) | **267 / 267** | **267 / 267** |
| Snapshots on an arm frame (`KT2VIC1n`) | 16 | 16 |
| Inline SAG guard | 14 records anchored, 8 new hashes | |

**Did the `dclipl` change alter anything else?** Stock drew a piece with
`object flip | piece flip`; the new rule draws the piece's flip alone. They
differ only where an object has a flip bit its pieces lack, for example after
code flips an object and draws before `ani2` re-lays the pieces.
`tools/run_piece_flip_audit.py` checks exactly that condition, piece by
piece, on the old and new ROMs:

| Walk | Kitana fight | Attract loop | Verdict |
|---|---|---|---|
| `objlst`/`objlst2`, every frame | 0 mismatches / 5,375 frames | 0 / 9,940 | clean |
| every list head `baklst8..last_objlst`, every 4th frame | 0 | 735 (276 "visible"), **identical on both ROMs** | not drawn - see below |
| the lists the live `@dlists` table names (what the walker draws), every 2nd frame | **0** / 2,687 samples | **0** / 4,970 samples | **pass** |

The all-lists mismatches were all on `twr_bwall_lst`, THE TOWER's private
reflection list. A stage zeroes its own private heads only when it builds, so
outside THE TOWER that head is stale, and its chain runs through freed and
reused objects. The audit found the live Sub-Zero player "on" it. Nothing
reached through a stale head is drawn, which is why the drawn-lists walk is
the gate.

**The fan hook turned out to be redundant.** The Kitana fan hook re-lays its
pieces with `ani2` on the tick it turns (MKZAP `fpt_facing`). The fan is
animated at `init_anirate 1`, so `next_anirate` already re-lays it on every
tick, and `fanp_turn` writes the flip after its sleep and before the next
`next_anirate`. The display never sees the pieces a tick behind.
`tools/run_fan_flip_ab.py` scripts the throw (Forward, Forward, HP held, then
LP) and A/Bs the turn:

| Throw | Turn | Piece flip mismatches (old / new) | Turn window, 9 pairs |
|---|---|---|---|
| right | rel 205, flip 0->1 | 0 / 0 | **0 px differ** in every pair |
| left, old ROM | **never turns** - see below | 0 / - | not paired |
| left, fixed ROM | rel 188, flip 1->0 (74 fan frames, was 25) | - / 0 | not paired |

The hook costs one extra `ani2` on the turn tick and changes nothing visible.

**Scripting the left throw found a real bug.** A fan thrown LEFT never
turned. `fan_at_turn_line` loaded oxvel "for the direction test" and then did
two more register moves before `jrn fatl_left`. Each move re-sets N, so the
branch read the sign of `worldtlx`, which is always positive. A left-bound fan
got the right-edge test, never reached it, and flew off screen. The trace:
x 374 -> 190 at vx -8 with the turn line at 243. The fix is `move a0,a0`
right before the `jrn`. It is verified by `run_fan_flip_ab.py --side left`
against the rebuilt ROM: the blade turns at rel 188 and comes home. The right
throw still turns at rel 205 and stays pixel-identical to the old ROM. This is the same trap that once made `fanp_turn` flip
every tick: a `move` into a register sets N, so a branch has to sit next to
the move that set its flags.

The scenarios also cover only a fight and the attract loop, not every stage or
move.

`--debug` runs the four emulators windowed under MAME's debugger, with a
one-line `go` script so it does not halt at the first instruction, instead of
full screen.

Art identity flagged `MKST.TBL:STNUTCRUNCH1B` as changed. It is the LOAD2 bit
bleed again (below): against the authored `TSUNG9.IMG` the old ROM had 7 wrong
pixels and the new one has 5.

The Kahn fist pair (`BGBIGFIST1B/1C`) is not done. It is also drawn as a
single object (MKZAP's `kahn_big_fist_piece_start`), where the anchor mirrors
from `oflags`. The [offline fist prototype](KAHN_FIST_REUSE_PROTOTYPE.md)
now identifies a scoped correction: keep the original C anchor and restore
the header mirror after the single-object positioning calls. Runtime A/B
validation and storage removal remain pending.

## A finding outside the prototype: LOAD2 bit bleed

Art identity flagged one CHANGED record, `MKSPLIT.TBL:JXSPLIT9A` (a Jax
fatality piece, 108×37 at 6bpp). Its header is unchanged and only its SAG
moved. The rebuilt old ROM (decoded from the previous package's chips,
validated against the baseline hash of its neighbour) and the new ROM were
both compared with the **authored** `NUJAX10.IMG`:

| Pixel | Authored | Old ROM | New ROM |
|---|---|---|---|
| (76,33) | 9 | 9 | **11** |
| (82,36) | 0 | **1** | **3** |

The 16 other differences are the expected 255 → 63 six-bit mask, identical
in both. So LOAD2 corrupts a stray bit or two in some records depending on
their bit alignment. Stock already had one wrong pixel here; moving the
record changed which pixels are hit. That is a pre-existing packing defect,
not this change. How widespread it is would take a whole-ROM decode against
the authored IMGs, which has not been done.

## Next candidates

### Scanner follow-up — 13 September 2026

The reuse scanner now distinguishes headers by SAG, dimensions and decode
control. Previously, the first header at an address supplied the decoded
image for every later header at that address, even if its layout differed.
Flip-only aliases still share one stored-pixel view.

The scan includes literal inline ASM headers, screens out headers neither
currently emitted nor referenced, and excludes overlapping decode views from
savings estimates. An undecodable header protects a conservative maximum
read window instead of disappearing from dependency analysis. This catches
all three ninja baby aliases overlapping the restored `ROTATE10B/C` payloads.

The current run decodes **9,693 views**, excludes **243 overlapping views**,
and reports **196 stale/unreferenced headers**, **42 undecodable headers**
and **5 outside/invalid headers**. The candidate totals remain **2,701 bytes
of mirrored art**, **2,890 bytes of exact duplicates**, and no exact 2x
copies. These categories are alternatives and must not be added together.
Fifteen verification regression tests pass, including distinct decode views,
interior overlaps, failed-decode dependencies and ROM-end reads.

[Recorded scan and input digest](flip_scan_review_results.json). This is
candidate screening, not a deletion approval or a runtime comparison.
Computed headers, layouts outside the parsers, stale generated output and
consumer-specific anchoring still require review. No art or ROM was changed
in this follow-up.

Shao Kahn's `BGBIGFIST1B/1C` (1,729 B) remains a reuse candidate, with the
single-object/multipart handling described above. Its offline packed-pixel
prototype passes 168 placement/clipping comparisons; this is not a runtime
pass. Mileena's eight
arm pairs are already implemented; they are not a pending candidate.

### Raiden's head roll — 15 September 2026: built, runtime A/B passes

Raiden's `RNHEAD2/3` are exact H+V mirrors of `RNHEAD6/7` (766 B, MK4MIL).
Their sole consumer is `a_head` (MKRD.ASM), the decapitated-head roll: a
single object stepping through whole `RNHEAD1-8` frames with `ani_jump`.
Every head consumer (`decapped_head`, `ermtkf_head_drop`, `rd_lift_head`, the
MKDIE pop) steps the lane with `next_anirate` → `frame_a9` → `ani`, so the
flip rule had to change in `ani` itself rather than at one call site.

**Two engine changes (MKDISP.ASM).**

- `ani` used to OR a header's flip bits into `oflags`, and its keep-mask then
  held them. One alias frame would have left frames 7, 8 and 1 flipped too. It
  now takes the old header's flip back out and XORs the new header's in, the
  rule `ani2` already applies per piece.
- `gsagof`, which `ani` and `ani0` both call, ORed the header's whole control
  word into the flags again, flips included. The first build therefore drew
  alias frames with both flips forced. The wrong flags skewed `ganiof`'s anchor
  delta, and `oxval` kept the error: the head sat 1 px left from its first alias
  frame onward (256 of 261 witness samples). `gsagof` now merges the control
  word without its flip bits.

No LOAD2 header carries flip bits; only the eight Mileena arms,
`BGBIGFIST1C_MIRROR` and the two new aliases do. So for every other lane both
changes produce exactly the old result. Two rules follow. Step a mirrored alias
with `ani` or `ani2`, never `ani0`. And keep aliases out of lanes that use
`frame_a9`'s `newflag` command, which sets flips absolutely.

**Aliases.** `RNHEAD2_MIRROR` and `RNHEAD3_MIRROR` in MKRD.ASM, both control
word `060B0h`. `ganiof` mirrors an anchor to (w−1−anix, h−1−aniy), so their
anipoints are (15,11) and (12,15), not the kept frames' own. Their SAGs are
anchored on `RNHEAD6`/`RNHEAD7` in `tools/sync_inline_sags.py`, with pixel
hashes.

**Runtime A/B** against the pre-change build (`tmp/flip_head`, frozen maps,
private windowed MAME):

| Scene | Captures identical | Notes |
|---|---:|---|
| Kung Lao's neck decap on Raiden (`hat_split_fatality_test.lua`, `HSF_VICTIM=raiden HSF_DOWN=-2 HSF_SNAP_EVERY=2`) | **132 / 132** | Head witness: 233 samples identical; 28 on the alias frames at the same position and size, with the flips toggled (`e092` → `e0a2`) |
| Raiden's lift fatality on Liu Kang (`RDLF_VICTIM=1`) | **67 / 67** | Bolts, smoke puffs and a non-Raiden head roll |
| Raiden's lift fatality on Raiden (`RDLF_VICTIM=7`) | 66 / 67 | See below |
| Kahn's portal fatality | **321 / 321** | `ani0` users: the iris flutter |
| Kahn's Sonic Clap | **72 / 72** | `ani0` users: the wave |

The one lift capture that differs is a 7×10 px sliver at the top-right edge.
A per-object trace of both builds names it: an `explode_piece` bone chunk
(`oid 010ch`) whose arc differs slightly, so it crosses the corner a frame
earlier. With the debris excluded, all 91 traced frames match object for
object, and the head matches in all 91 samples. Each build repeats itself
exactly. The chunks take their velocities from `@rand`, which the lift's own
smoke and the FINISH HIM wait also draw from, so a small timing difference
before the pop moves every arc.

**Pruned, 15 September 2026 (with sign-off).** `RNHEAD2` and `RNHEAD3` were
removed from MK4MIL.LOD and from MKRD2.TBL, and rebuilt with LOAD2.

- **Phase D** first stopped on two things. The aliases' SAGs were stale, and
  `sync_inline_sags.py` rewrote them to `02038c78`/`02039884` after its pixel
  hashes matched. Ermac's lift-windup clones (`ERELBO2A/B`, `ERHIPUNCH7A-C` in
  MKNJ.TBL) point at stock ninja art later in MK4MIL; they drifted, and
  `tools/sync_ermac_lane.py --apply` re-pointed them. **Any MK4MIL removal
  needs both syncs.** After them every guard passes, and
  `raiden_lift_wax_import.py --check` reports up to date.
- **Art identity** (whole ROM, before vs after): exactly 2 records removed and
  1,903 moved with identical pixels, the Ermac clones among them. The only
  CHANGED records are MKNJ.TBL's `tornado1`-`8` composites. They are retail
  headers for art the LOD no longer loads (it ships `tornado1A`-`8C` strips).
  No table or code uses them, and the tool's `used` flag comes from the
  `.globl` list and a comment in MOVES.ASM.
- **Space:** MK4MIL's free run grew to 15,160 B, **764 B freed** (bank 0 free
  is 124,804 B).
- **A stale object nearly shipped.** The first pruned package passed every
  Phase D guard, yet drew RNHEAD8 and torso art on head frames 2 and 3. The
  hat A/B showed 118/132 captures identical, and the lift on Raiden 63/67.
  `sync_inline_sags.py` rewrote MKRD.ASM's alias SAGs *after* the first full
  build had assembled it. The asm-only rebuilds then skipped MKRD.OBJ, because
  DOSBox had stamped it 13:38:10, ahead of the rewritten source's 13:37:56. The
  linked ROM kept `0x203a462`/`0x203b06e`, the pre-prune addresses, while the
  check read the corrected source. Deleting MKRD.OBJ and rebuilding fixed it:
  `rom/mk2_flat.bin` now carries `0x2038c78`/`0x2039884`. **Guard added:**
  `sync_inline_sags.py --check`, which Phase D runs after the link, now also
  requires every hand-carried header, with its anchored SAG, to be present in
  `src/mk2.out`. Given a copy of that file with the stale SAG put back, it
  fails with "its object was not reassembled".
- **Runtime rerun, corrected pruned build vs pre-prune (`new2`):**

  | Scene | Captures identical | Notes |
  |---|---:|---|
  | Kung Lao's neck decap on Raiden | **132 / 132** | Head witness 261/261: frame timing, flags, position and size identical (only the SAGs moved) |
  | Raiden's lift fatality on Raiden | **67 / 67** | |
  | Raiden's lift fatality on Liu Kang | **67 / 67** | |
  | Kahn's portal fatality | **321 / 321** | Run on the 13:40 package, which differs only in the two Raiden alias headers |
  | Kahn's Sonic Clap | **72 / 72** | Same package |

  The Raiden lift rig's own pass/fail (observe 300) passed victims 7 and 1 on
  the 13:40 package: 0 WAX mismatches, no off-table body or bolt SAG, 7 and 8
  bounces. It checks SAG membership and the head's path, not which art the head
  draws, so it could not see the stale aliases. Its rerun on the corrected
  13:44 build also passes: victims 7 and 1 both have 104/104 WAX frames and
  no off-table body or bolt SAG, with 7 and 8 bounces, and the sampled head
  labels resolve only to RNHEAD1/4/5/6/8. Private package
  `tmp/flip_head/prune2`, not installed.

The [ROTATE family audit](ROTATE_ART_AUDIT.md) records the completed pruning
and subsequent restoration of `ROTATE10B/C` for the ninja baby windows.
Those two records remain dependencies despite having no named consumer.

## Reproduce

```powershell
python tools/flip_scale_scan.py --json tmp/flipscan/flipscan.json
python tools/art_identity_snapshot.py --write tmp/art_before.json   # before the LOD edit
python build.py; python makerom.py; python makevrom.py              # wait out DOSBox clock skew before mamerom
python mamerom.py --no-install --output tmp/clouds/rom/mk2.zip
python tools/art_identity_snapshot.py --compare tmp/art_before.json
python tools/run_tower_clouds_test.py --stock-rom-dir <stock> --stock-map <stock map> --flip-rom-dir tmp/clouds/rom --flip-map tmp/clouds/mk2.map
```

## Files and evidence

- [Recorded results](flipreuse_results.json): the scan classes, both A/B
  runs (the failed first clip and the pass), art identity, and the JXSPLIT9A
  pixels.
- [Scanner](../../tools/flip_scale_scan.py), [rig](../../tools/tower_clouds_test.lua),
  [runner](../../tools/run_tower_clouds_test.py).
