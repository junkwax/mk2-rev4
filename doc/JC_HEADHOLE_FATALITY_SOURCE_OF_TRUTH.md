# Johnny Cage Headhole Fatality — Source of Truth

Read this before changing Johnny Cage's custom fatality.

> **2026-07-13: implementation rebuilt from the ground up.** The previous
> iteration (independent head-overlay process, KHEART/STAB/SPLAT/SPILL prop
> lanes, World View local-anipoint tables, scheduler-phase delay
> compensation, hardcoded TBL palettes) is fully retired. Older headhole
> docs and Lua harnesses describe that retired machinery; treat them as
> history, not as behavior.

## Identity and scope

There is one custom Johnny Cage fatality in this worktree:

- **Headhole fatality** and **brain-rip fatality** are two names for the same
  feature. Do not create a second `do_jc_headrip` / brain-rip route.
- Controller: `do_jc_headhole` in `src/MKDEATH.ASM`.
- Attacker animation: `a_jc_headhole` in `src/MKJC.ASM` (ani2 slot 7).
- Victim animation: `a_headhole_fall` at anitab1 slot `40h` in every normal
  character module.

## Architecture (three pieces, nothing else)

```text
do_jc_headhole (Cage's process)
  init_death_blow -> disable_repell -> me_in_back
  takeover_him(jch_face_wait)     ; victim faces Cage, holds; NO lineup -
                                  ; like fan decap, the punch plays from
                                  ; where the players stand (the transfer
                                  ; gate already enforced range); never
                                  ; match_him_with_me_f (grab helper -
                                  ; teleports the victim onto Cage)
  jc_headhole_pairs x3 pairs      ; DBLO1..3 windup, authored ticks 0..7
  takeover_him(jc_headhole_fall)  ; contact handoff at the JCHIPUNCH3 beat
  jc_headhole_pairs x9 pairs      ; JCHIPUNCH3..DBLO10, authored ticks 8..43
  sleep 30h -> death_blow_complete -> victory_animation

jc_headhole_fall (victim's own process)
  rsnd_death_voice -> face_opponent -> change_to_bloody_pal
  anitab1[40h] a_headhole_fall    ; stock decap_fall cadence:
  first frame, sleep 30h, mframew 6 (knees), shake, me_in_front,
  mframew 10 (wobble), mframew 6 (ground), shake,
  create(pid_head, jc_headhole_spill_proc), wait forever

jc_headhole_spill_proc (persistent worker, pa10 = victim body)
  authored IMGTOOL Slot 7 BLOOD.IMG lane: SPILL1..13 once at 12 FPS
  (x5 game ticks); gso from SPILL1 (header carries BLOOD_P), ani_flag per
  step (never ani0 - it takes the new oflags in a4, and after a sleep
  that's scheduler garbage -> a corrupted blit that can also clobber
  nearby screen state, e.g. the HUD), holds SPILL13 through victory;
  skipped entirely when f_no_blood is set. Positioned at the resting
  head's own screen position: anchor.oxpos/oypos minus the LAST
  multipart piece's stored mp_anix/mp_aniy - the head is queued last in
  every a_headhole_fall table (see the z-order note below), so the code
  walks the 0-terminated multipart array to the end to find it (there's
  no way to seek directly to the last entry). A small flip-aware +20 X
  nudge (toward the victim's own right side, tuning constant not
  exported data) pulls SPILL1 to start right at the headhole. Y gets a
  +15 ground nudge (down onto the floor the head rests on). Then the
  single-object anipoint correction every gso_dmawnz'd prop needs
  (lineup_1pwm's contract: subtract ianioffx/ianioffy once, since a
  freshly created object has no prior frame for ani_flag to delta
  against). The export's own World View (dAX,dAY) offsets are NOT used:
  they are relative to IMGTOOL's internal anchor, not to anything the
  runtime has, since the victim body object's oxpos/oypos never move
  during the fall (the fall is drawn entirely through per-piece
  anipoints) - using them verbatim places the pool a fixed offset from
  the character's standing position instead of from the actual resting
  head.

jc_headhole_kheart_proc (Cage-owned worker, pa10 = Cage's own object)
  authored IMGTOOL Slot 5/6 MK1BLOOD.IMG lane: bootstrap on KHEART1, then
  KHEART2,KHEART3A,KHEART3B,KHEART3C,KHEART4,KHEART6A,KHEART6B,KHEART6C,
  KHEART6D once each at 12 FPS (x5 game ticks), then holds forever on
  KHEART6D - a one-shot sequence, not a pulsing/looping heart. MUNCH
  fires once, on the KHEART6C beat. gso from KHEART1 (every KHEART*
  header carries jtblood_p directly, no bootstrap trick needed),
  positioned via lineup_1pwm re-run every tick against Cage's *current*
  position (his own JC2DEATHBLO4..10 pass can move him while the heart
  plays, and ani_flag's frame-to-frame delta alone only tracks the
  sprite's own anipoint change, not the anchor drifting under it) - all
  exported local offsets for this lane are (0,0), so there is no extra
  term on top of lineup_1pwm's own math.

  Timing is a fixed game-tick schedule, not a live poll of Cage's own
  oshape: KHEART1 holds 50 game ticks (JCHIPUNCH3's own authored 10
  ticks @ 12 FPS x5) before the step loop starts; KHEART2/3A/3B/3C then
  consume the next 20 ticks (5 each) so KHEART4 lands exactly when
  JC2DEATHBLO7 starts, where it holds 50 more ticks (JC2DEATHBLO7's own
  authored 10 ticks x5) to span BLO7's full duration. An earlier version
  of this polled Cage's own object for `oshape == JCHIPUNCH3` in a
  jsrp/prcslp loop; that value never observably changed for the whole
  fatality in testing (osag on the KHEART object stayed frozen at its
  bootstrap value from creation to well past completion) and was
  replaced with the fixed schedule above, which is the same clock
  jc_headhole_pairs (MKDEATH.ASM) already trusts to drive Cage's own
  a_jc_headhole animation - it cannot drift out of sync with him.

a_headhole_fall (per character module)
  the stock a_decapfall group structure (1-2-3 / wobble 4-3 x3 / 4-5-6-7)
  where each frame is the stock decap leg/torso multipart list with the
  character's head-with-hole record appended as the LAST part. The
  per-frame DMA render queue draws in the SAME order pieces are queued
  (traced through MKDISP.ASM's init_dma_regs/dma_interupt: push via
  `mmtm a1,...` and pop via `-*b14` both pre-decrement from the same
  starting top-of-queue address, so the first piece pushed is also the
  first popped and drawn - MMTM decrements Rd before each store, same as
  the pop side's pre-decrement read, so pushing P1 then P2 leaves P1 at
  the higher address range that b14 reaches first) - the FIRST piece
  queued draws FIRST (ends up on the bottom, painted over by everything
  queued after it) and the LAST piece queued draws LAST (ends up on
  top). An earlier version of this got the direction backwards (head
  queued first) and was corrected after visual confirmation the head was
  rendering behind the torso. Queuing the head last is what puts the
  headhole visually above the torso/leg pieces instead of underneath
  them.
```

The head is **not** a separate object — it is a multipart piece of the
victim body, so it inherits the body's position, mirroring, and palette
on every frame by construction; only its DMA queue position (last, see
above) is special-cased for z-order. The only worker processes are the
blood spill, the impact stab/splat, and the heart prop above; there are
no other prop lanes, no local-anipoint tables, and no scheduler-phase
compensation.

## Authoritative attacker data

The attacker comes from `data/CAGE10.IMG`, sequence **`DBLO2`** (letter `O`).
Its runtime order is one pass only:

| Step | Runtime label | DBLO2 tick |
|---:|---|---:|
| 1 | `JC2DEATHBLO1` | 6 |
| 2 | `JC2DEATHBLO2` | 1 |
| 3 | `JC2DEATHBLO3` | 1 |
| 4 | `JCHIPUNCH3` | 10 |
| 5 | `JCHIPUNCH2` | 1 |
| 6 | `JC2DEATHBLO4` | 1 |
| 7 | `JC2DEATHBLO5` | 1 |
| 8 | `JC2DEATHBLO6` | 1 |
| 9 | `JC2DEATHBLO7` | 10 |
| 10 | `JC2DEATHBLO8` | 1 |
| 11 | `JC2DEATHBLO9` | 1 |
| 12 | `JC2DEATHBLO10` | 10 |

44 authored ticks total. **The tick unit is the sequence's authored 12 FPS**
(the IMGTOOL sequence rate), not scheduler ticks. The scheduler ticks at
the 54.7 Hz display rate, so one authored tick = 4.56 game ticks;
`jc_headhole_pairs` applies the nearest integer (x5, 10.9 FPS effective —
the alternative x4 would run 13.7 FPS) at playback, so the full pass runs
220 game ticks (~4.0 s). The table itself stores only the native values.
`jc_headhole_pairs` is the readonly
`mframe_a0` contract plus a pair count so the controller can hand the
victim off at the authored contact boundary (after the first 3 pairs =
authored tick 8 = game tick 40) without splitting the table. Do not
duplicate image labels to fake holds, do not bake scaled values into the
table, and do not resample the sequence from a `.WVP` preview.

Every native `DBLO2` entry has `dX=0`/`dY=0`: keep the stock
`match_him_with_me_f` lineup and normal facing; no preview-derived offsets.

## Authoritative victim data

Each normal victim family supplies seven head-with-hole records, packed via
`data/MOVEART1.LOD` from unused stock art:

| Module | Head records | IMG source |
|---|---|---|
| MKHH | `TMDEADHEAD1..7` | `HATHED11.IMG` |
| MKLK | `LKDEADHEAD1..7` | `KANG10.IMG` |
| MKJC | `JCDEADHEAD1..7` | `CAGE10.IMG` |
| MKSA | `UGHEADHOLE1..7` | `UGMO10.IMG` |
| MKFN | `KTHEADHOLE1..7` | `KAT11.IMG` |
| MKNJ | `NJHEADHOLE1..7` | `NINJAS11.IMG` |
| MKST | `STHEADHOLE1..7` | `TSUNG10.IMG` |
| MKRD | `RNHEADHOLE1..7` | `RAID9.IMG` |
| MKJX | `JXHEADHOLE1..7` | `NUJAX10.IMG` |

Placement is the record's own **art anipoint from the IMG** — head N was
authored against decap body pose N. The `*HEADHO.TBL` files carry no palette
pointers (`POF>` records); like all victim body art, the head takes the
object palette, which `change_to_bloody_pal` sets to the victim's own blood
palette per character and per costume (`bloody_palettes` in `MKGUYS.ASM`).
Never hardcode `CAGE_P` or any other palette into these records: the same
`NJHEADHOLE` art serves Scorpion, Sub-Zero, Reptile, Smoke, and Noob with
different blood palettes; `KTHEADHOLE` serves Kitana, Mileena, and Jade.

Bosses (Kintaro, Shao Kahn) have no decap art or slot `40h`; they take a
bloody knocked-down reaction (`jc_headhole_boss_fall`).

### Where the victim stands: `data/CAGEBRAIN.WAX` (2026-10-04)

The fixed lineup (56 across, 7 down, measured off Liu Kang alone) is gone.
`data/CAGEBRAIN.WAX` holds Cage on `JCHIPUNCH3` (CAGE2.IMG, unmirrored, offset
0) and, one slot per body, that body's `HEADHOLE1`/`DEADHEAD1` mirrored and
moved until the head is on the fist. The head is the LAST piece of `*HOLE1`
and every piece hangs off the one anchor, so the WAX offset IS the victim's
anchor offset: the whole body moves, and no anipoint in any IMG changes.

`tools/cage_brain_wax_import.py` turns it into `jch_place` (MKDEATH.ASM, a
generated block), one `.word -reach,drop` row per VICTIM ochar, read by
`adjust_him_tbl` after `match_him_with_me_f` (`clapped_lineups`' contract).
Bosses keep 56/7. **He is moved on the PUNCH, not before it** (`jch_lineup`,
called at contact, the frame JCHIPUNCH3 and the holed head appear): through
the windup he stands where FINISH HIM left him, only turned to face Cage, and
the punch is what lands him on the fist. How far he jumps on that frame
depends on where he stood (inside the 050h gate). The rig asserts he did not
move during the windup (`WINDUP` line). `--check` is in Phase D; it refuses a missing body, an
unmirrored victim, an offset Cage, and a `*HOLE1` list that no longer ends on
the posed head. **Edit the WAX in IMGTOOL and re-run the tool, never the block.**

| body | reach | drop |
|---|---|---|
| Kung Lao | 77 | 2 |
| Liu Kang | 71 | 2 |
| Cage | 68 | 2 |
| Baraka | 73 | 11 |
| Kitana / Mileena / Jade / Khameleon | 67 | 11 |
| Shang | 76 | 6 |
| Raiden | 65 | 16 |
| the seven ninjas | 78 | 15 |
| Jax | 80 | 11 |

(Cage's fist tip is 84px past his anchor; every WAX pose puts it inside the
head, where at 56 it came out 7-28px past the back of most of them.)

On the first frame of the drop to his knees he JUMPS back to his own floor
(`p_ganiy`) in one frame and falls from there (the user's call, 2026-10-04).
Two earlier cuts were rejected: easing him down a pixel a tick (`jch_settle`)
read as a slide, and leaving him at the fist's height had him lying up to
16px low. Only y was moved for the fist, so only y is put back. The rig's
`FALL` line asserts his final y is his FINISH HIM y AND that no frame between
the fist's height and the floor was drawn (`frames in between=0`).

### He shakes on the fist

The 48-tick stand after contact is a SHAKE now, not a `sleep 030h`: Sub-Zero's
head rip victim shake (`szhr_victim_shake`, UMK3's numbers) - 2px diagonal,
3 ticks a half, 8 shakes = the same 48 ticks, so nothing after it moves
(`jch_shake_px/_rate/_n`). Symmetric, so he ends where `jch_place` put him;
the rig asserts both (x swings exactly 2px, final x = lineup x). The
STAB/SPLAT props and the chunks are placed once at contact and do not follow
the 2px.

### The impact: sound and blood (2026-10-04)

**Sound.** The punch plays the UPPERCUT's impact - `triple_sndtab` 1bh, MK1
uppercut smack #1, track `00c1` (was 19h, "BIG smack #1") - and 16 ticks
later the crowd's "ooo", `triple_sndtab2` 34h, track `024b`, on its own
process (`jch_crowd_ooo`) so Cage's pair clock is not slept on. That is
exactly what an uppercut does (`r_upcutted` + `upcut_comment`, MKREACT),
minus the random pick of comment. **The latch carries track + CHANNEL**
(`triple_sound` adds 0-2 for the channel it lands on), so the "ooo" arrives
as `024b`, `024c` or `024d`; the rig accepts all three.

**Blood.** The JCSTAB/JCSPLAT props on the hole are GONE (the user's call);
`JCBLOOD.TBL` still carries their headers, kept in step by
`tools/sync_jc_blood.py`, but nothing draws them. In their place, both from
`jc_brain_chunks` (blood_procs 01eh) at the punch:

| where | art | lane | built on | placed | z |
|---|---|---|---|---|---|
| BACK of the head - the exit | the stock `GUSHER1-23` | `a_gusher`, 4 ticks | `get_tg_blood` (STAB1, `BLOOD_P`) | anipoint (the base of the fan) on the back edge | `back_z-1`: BEHIND the victim, so it comes out from behind the head |
| FRONT of the head - the entry | MK1's `BIGGERBLUD1-6` | `a_bigger`, 3 ticks | `get_jt_blood` (BIGBLD1, `jtblood_p`) | first frame CENTRED on the front edge (it hangs 25px under its anipoint) | `front_z+2` |
| FRONT of the head - over it | the kiss of death's `BLDSPLASH1-5` | `a_kiss_splash`, 4 ticks | its own `BLDSPLASH1` (`BLOODY_P`); `BLOODYG_P`/`BLOODYNB_P` for Reptile/Noob | anipoint (dead centre on every frame) on the front edge | `front_z+3` |

BLDSPLASH (`jcb_entry_burst`, switch `jcb_entry_splash`) was tried on one rig
and kept on the user's call; it grows to 94x69 and covers both heads and the
punch at its peak, which is the look. GUSHER fans to +x and BIGGERBLUD leads to -x, so both are unflipped when the
back of the head is to the right. **Each is built on the record whose palette
its art was drawn for**, then `ani_flag`'d onto its own first frame: the
MKBLOOD.TBL splash records carry NO palette, so the object takes whatever the
first record had. Bare (`gso_dmawnz`) drew them yellow/magenta/green; the
decap SPRAY on BIGBLD1's MK1 palette came out in odd colours too. GUSHER is
BLOOD.IMG art -> `get_tg_blood` (exactly how the stock gushers are made);
BIGGERBLUD is MK1BLOOD.IMG art -> `get_jt_blood`. Both also take
`char_blood_pal`'s green (Reptile) / black (Noob), and the VICTIM's flip,
which `jcb_place` toggles. The back splash was the decap SPRAY until the user
called it too small; GUSHER is BLOOD.IMG's biggest directional fan.

**The brain on JCHIPUNCH3** (`KHEART6B_OPEN`, anipoint -81,-14) sits on the
front of Cage's knuckles: the fist runs to x 84 past his anchor, rows 20-26, so
the brain's back edge is 4px onto it and its 18 rows are centred on the fist's.
It was -73,-16, which drew it over the whole fist.

### Reptile and Noob bleed in their own colours here too

The pool under the head (SPILL, `jc_headhole_spill_proc`) and the brain in
Cage's hand (KHEART, `jc_headhole_kheart_proc`) used to keep their headers'
red on everyone. Both now go through `jc_victim_blood_pal` (MKBLOOD.ASM,
`.globl`), a thin wrapper on `char_blood_pal`: `BLOODG_P` green on Reptile,
`BLOODNB_P` black on Noob, red for everyone else. The brain belongs to the
VICTIM but runs in Cage's process, so `do_jc_headhole` hands it the victim in
`pa9` at creation, read before the proc first sleeps. The flying BPARTS chunks
are still red, as in Jax's clap.

### The chunks out of the back of the head

At contact `jc_headhole_fall` measures the back edge of the head piece
(`jch_brain_point`: the last multipart node, the side away from Cage) and
starts `blood_procs` 01eh, `jc_brain_chunks` (MKBLOOD.ASM): some of Jax's
clap chunks (`BPARTS`), only AWAY from Cage. 5 on `chunk_grav`'s arc and
bounces, 4 on `chunk_pow`'s straight flight off screen (`jcb_grav_n` /
`jcb_pow_n`). It goes through `create_blood_proc`, so the blood DIP and
MAX_BLOOD apply. The chunks keep BPARTS' own colours (red, Jax's clap does
the same) - they are not recoloured for Reptile/Noob.

Rig: `tools/run_cage_brain_test.ps1 -Victim all` (12/12): the lineup against
the row read out of MKDEATH.ASM, chunks split by x-velocity sign (9 away, 0
toward on every body), all three splashes by record size (GUSHER behind the
BIGGERBLUD and the BLDSPLASH, measured from Cage), the two sounds off the sound
port, and the final y against his FINISH HIM y. It runs a
private zip + map (`tmp/cage_brain_rom`, from `makerom.py` then `mamerom.py
--output ... --no-install`) on `mame_cbrain.exe`. **Rig trap:** a rig that
holds the pair at a distance until it sees `f_death` overwrites the lineup's
x, because `init_death_blow` sleeps and `f_death` shows up after the
lineup. That read 64 (the rig's own spacing) on a correct build. Stop
positioning at the HP press. Stopping at the START of the motion is wrong
the other way: F,B,B walks them out of 050h and the input never fires.

Two IMG-side notes from the 2026-07-13 rebuild:

- `KAT11.IMG` `KTHEADHOLE1..7` had no authored anipoints (0,0 in the
  readonly original); values were authored into the active IMG following the
  progression every other family uses.
- `KANG10.IMG` `LKDEADHEAD3/4` anipoints were smoothed relative to readonly
  (readonly's `(0,0)` on DEADHEAD3 is an unauthored placeholder). The active
  IMG, `tmp/load2` snapshot, and `src/LKHEADHO.TBL` agree with each other.
- `NUJAX10.IMG` was restored byte-for-byte from readonly after an earlier
  iteration recut `JXHEADHOLE1..7` with strip-cumulative junk anipoints.

Note on `SPILL1..13` art: this stock `BLOOD.IMG` sequence is not used by
any other fatality or blood routine in either tree (see the "Stock SPILL
Audit" history in `MK2_READONLY_FATALITY_COMMON_CONTRACT.md`'s prior
drafts), so this is the first time it has ever actually rendered. Once
wired and correctly positioned, its real shape at the larger frames
(SPILL9..13) is an angular red spray/wedge with a darker circular accent,
not a round spreading puddle — that is the genuine 1993 pixel data, not a
rendering bug. Confirmed consistent across two independent frames during
the 2026-07-13 verification; if a rounder puddle look is wanted, that
requires new art, not a wiring change.

## Sounds

`MKSOUND.ASM` triple table: `100h` BWHOOSH3 fires at windup start, `101h`
BIGHIT3 at the contact handoff, and the victim's own `rsnd_death_voice`
supplies the scream. Entries `102h`/`103h` (VPDEATH, MUNCH) remain in the
table but are unused by this fatality.

## Explicitly non-authoritative files

`data/*.WVP` files are custom IMGTOOL/World View preview projects — never
authority for frame order, ticks, placement, palettes, or wiring. For stock
engine semantics use `mk2-readonly`; for the shared fatality controller
contract read `doc/MK2_READONLY_FATALITY_COMMON_CONTRACT.md`.

## Retired BRAIN.IMG lane

`BRAIN.IMG` is not part of this fatality and must remain retired
(`data/BRAIN.IMG`, `src/JCBRAIN.TBL`, `src/BRAINRIP.ASM`, `BRAINRIP*`
labels). The KHEART records in `src/JCMK1BLD.TBL` are also unused by this
fatality; they stay packed for other restoration work.

## Asset/build rule

**REVX is full and off limits.** The active CAGE10 frames and all victim
head sets are normal image-ROM art routed through `data/MOVEART1.LOD`
(`src/JCHRIP.TBL` + the eight `src/*HEADHO.TBL` files). If the LOD or an
IMG changes, run the full pipeline — LOAD2 (Phase A), table promotion,
assemble, then `makerom.py` **and** `makevrom.py` — before packaging;
program and video ROMs must move together. Never hand-edit generated
`data/*.IRW`, `tmp/load2/*`, or `rom/*` as source.
