# Graphics and resource opportunities on MK2's T-unit

> The Wolf-unit companion is [WOLF_OPPORTUNITIES.md](WOLF_OPPORTUNITIES.md):
> the blitter is the same, so everything below carries over; what Wolf adds is memory.

> **Prototype update, 2026-09-12:** the three storage prototypes are done.
> [BLDXPD per-frame depth](graphics_opportunities/BLDXPD_PROTOTYPE.md)
> (opportunity 02) saved **17,054 payload bytes**,
> [NOOBPORT per-block depth](graphics_opportunities/NOOBPORT_PROTOTYPE.md)
> (opportunity 03) saved **7,774**, and
> [STBURST](graphics_opportunities/STBURST_PROTOTYPE.md) (opportunity 05)
> saved **28,140** - **52,968 bytes of video ROM** between them, each verified
> offline, with sampled MAME checks documented in each receipt. No slot moved and no recovered run has
> been reallocated. Opportunity 05 also turned out to be misfiled: it is dead
> art, not a sharing problem, and cleaning it up needed two new guards -
> [art_identity_snapshot.py](../tools/art_identity_snapshot.py) and
> [sync_inline_sags.py](../tools/sync_inline_sags.py). The research snapshot
> below retains its original measurements; the prototype notes record the
> results and their limits.
>
> The first frame-time prototype is also done, and it is a **negative**:
> [opaque floor skipping](graphics_opportunities/FLOOR_SKIP_PROTOTYPE.md)
> (opportunity 07) found **no additional constant top-row skip on the tested
> stages**; THE TOWER already takes its 54. This closes that specific
> prototype, not camera-dependent or partial-row culling.
>
> **Verified continuation:** [independent review](graphics_opportunities/PROTOTYPE_REVIEW.md)
> confirms the storage checks and repairs verification gaps. Further Noob
> work remains deferred. [Wasteland fast shadows](graphics_opportunities/WASTELAND_SHADOW_PROTOTYPE.md)
> now use the fast path for compressed pieces: **51.5% fewer total DMA starts**
> on average across six fighter pairings, with **162 identical paired captures**
> and no new late frames in MAME. This measures submission cost, not DMA completion.
> [Kombat Tomb](graphics_opportunities/TOMB_SHADOW_PROTOTYPE.md) also passed:
> **43.6% fewer DMA starts**, 162 matching captures across all twelve standard
> fighters. Its receipt identifies the frozen build before the later visual
> prototype commits.

This source and asset audit, with primary hardware/emulator cross-checks,
examines opportunities beyond the
existing graphics experiments. It covers appearance, CPU time, blitter time,
video/program ROM, palettes, objects, processes, and development cost.
It does not propose changing the hardware or removing existing gameplay.

## Findings that change the plan

There is useful headroom left. The best immediate work is **extending the
fast shadow renderer already used by the Tower**, **packing individual effect
frames at their actual required bit depth**, and **sharing duplicate pixel
payloads across independent LOD runs**. The first targets frame time; the
other two target video-ROM space. These are different budgets and should be
measured separately.

The most interesting less-explored visual mechanisms are **localized palette
map edits**, **CPU drawing between display-list layers**, **a reusable strip
renderer for layer-specific distortion**, and **palette-driven lighting**.
They could support effects without adding a full animation's worth of art.
They require small engine additions; they are not ready-made effects switches.

Several old conclusions need narrowing. CPU drawing is not inherently confined
to the very front of the scene. The palette allocator has 80 slots, not 16.
LOAD2's duplicate detection does not remove every duplicate across separate
runs. Lower-bit-depth packing need not always require reindexing or changing
a shared palette. Conversely, decompressing normal sprites into RAM does
**not** make them readable by the custom DMA blitter. The findings below
supersede conflicting advice in the older graphics audits for this snapshot.

New effects and savings below are proposals, except where explicitly
identified as existing implementation or an offline measurement. They have
not been validated in a new ROM. Historical performance results are credited
to their original test notes.

## 1. Scope, evidence, and reproducibility

The snapshot date is **12 September 2026**. Evidence includes the active paths
in `MKDISP`, `BGND`, `PALL`, `UTIL`, `MKUTIL`, the scheduler and initialization
code, the video packer, LOAD2's preserved C source, and current LOD/TBL/IRW
files. Existing graphics and compression documents describe prior experiments;
current source takes precedence. MAME, FBNeo's actual T-unit CPU integration,
and TI's original manuals establish hardware mechanisms and compatibility.
References are collected at the end; individual sections link their main
evidence.[^1]

Evidence labels used here:

- **Existing:** an implementation exists; this does not by itself mean its
  compile switch is enabled or every stage uses it.
- **Measured offline:** decoded or counted from the snapshot, without running
  the game.
- **Proposed:** a mechanism is supported by source, but the effect or extension
  has not been implemented and validated in this review.
- **Conditional:** correctness depends on a physical-board test, emulator
  behavior, or an unresolved engine contract.

The accompanying [snapshot](graphics_opportunities/snapshot.json) records
input hashes and [frame CSV](graphics_opportunities/sprite_screening.csv)
contains 9,942 decoded sprite records. The
[reproduction script](graphics_opportunities/audit_snapshot.py) reads the
active packer's 46 IRWs in packing order, rejects overlapping payloads,
preserves bit-addressed SAGs, groups aliases, and excludes conflicting
headers. It also compares both highlighted sidecars against their authored
IMG indices. Run it from any directory with:

```powershell
python C:\Users\you\Workplace\mk2-main\doc\graphics_opportunities\audit_snapshot.py
```

This regenerates research JSON/CSV only. It imports the existing table parser;
it is not a complete parser for every manual or BLIMP structure. Of 10,065
unique parsed SAGs, 9,942 decoded, 85 were rejected during decoding, 33 had
conflicting header interpretations, and 5 fell outside active payloads. Those
exclusions are uncertainty, not proof of unused or corrupt assets.

The workspace was being edited and built during research. The initial source
HEAD was `b46b1297bc23e980b9ffaf001817e2d540430551`; the input hashes, rather
than a claim that every file belongs to that commit, identify the measured
artifact set. Re-run the inventory after asset changes before allocating space.

## 2. The budgets that actually constrain this machine

The target is **Midway T-unit MKII**, with a 50 MHz TMS34010 input clock,
custom image-ROM DMA blitter, indexed video, and separate DCS sound. The
visible picture is 400 × 254 at approximately 54.7068 Hz: about **18.28 ms per
refresh**. The CPU's input clock should not be read as 50 million instructions
per second. The FBNeo integration uses a divide-by-eight CPU cycle budget,
about 114,245 such cycles per refresh. CPU instructions and custom DMA are
separate drawing paths.[^2]

| Resource | Current finding | Consequence |
|---|---|---|
| DMA queue | 500 entries; six 32-bit words per entry | Queue occupancy and drawing time are separate limits. |
| Objects | `nobj = 358` | A low-pixel effect can still exhaust objects. |
| Processes | `nproc = 168` | One process per tiny particle is an avoidable cost. |
| Dynamic palettes | 80: 35 foreground, 45 background | Fixed/pinned users and ownership reduce practical availability. |
| Palette transfer queue | 32 cells, one empty ring cell: at most 31 outstanding | Many tiny updates can overflow before palette RAM is full. |
| CPU geometry list | `GEO_MAX = 192` segments | An old 320-segment figure is stale. |
| Multipart storage / shadow traversal | General buffers allow 13 pieces; current shadow walk caps at 11 | A general multipart limit is not a guarantee that every renderer handles it. |
| Unfilled packed video bytes | 298,756: bank 0 = 82,346; bank 1 = 216,410 | Includes reserved growth room; **not allocatable free space**. |
| Program headroom at sampled map | 150,736 bytes before the current reserved REVX pool | Useful for code/tables only under current layout rules; not a sprite-source pool. |

Definitions and ownership are in [DISPEQU](../src/DISPEQU.ASM),
[MAINEQU](../src/MAINEQU.ASM), [MKDISP](../src/MKDISP.ASM),
[PALL](../src/PALL.ASM), and the [space-report tool](../tools/rom_space_report.py).
The [asset ledger](ASSET_SPACE_LEDGER.md) and
[custom-content rules](CUSTOM_CONTENT.md) remain the allocation authority.[^3]
For example, the largest physical gap begins within a reserved wrapper's
remaining capacity. Treating the whole run as a new asset slot would violate
ownership even though the bytes are currently unfilled.

MAME/FBNeo's DMA timing model charges approximately **41 ns per programmed
output pixel**. This gives the following *model estimates*, before CPU setup,
queue gaps, contention, or other scene work:

| Programmed output | Nominal modeled DMA time |
|---|---:|
| 100 × 100 | 0.410 ms |
| 400 × 54 | 0.886 ms |
| 400 × 254 | 4.166 ms |
| 54 separate 400 × 1 floor rows | 0.886 ms plus 54 setups |

Transparency and a clipping window do not automatically reduce this modeled
area charge. Reducing submitted width/height or rejecting a draw does. These
are emulator budgeting estimates, not fresh physical-board measurements.
Historical Tower measurements also found substantial per-blit CPU overhead:
roughly 5–8 microseconds queued versus 16–18 microseconds manually polled.
Many tiny blits can therefore cost more than a somewhat larger draw.
[DMA implementations](#hardware-and-emulator-sources),
[Tower measurements](TOWER_GUARD_REFLECTIONS.md).[^4]

Instrument `last_dmaq`/`deep_dmaq` as **words**, dividing by six to obtain
entries. Track `dmaq_late` and `dmaq_lost`, the final DMA completion position,
CPU work, object/process peaks and palette transfers. A clean `qdma_drops`
counter alone does not prove the frame finishes on time. Instrumentation must
also survive overload; a HUD drawn at the end can itself be lost.
[`dsa9` and `init_dma_regs`](../src/MKDISP.ASM).

## 3. Opportunity map

Priority means the order in which to establish value, not authorization to
ship an untested change. **P1** is a focused first prototype, **P2** needs a
broader engine/art contract, and **P3** is conditional or likely niche.

| ID | Opportunity | Current coverage / missing work | Main budget | Priority |
|---|---|---|---|---|
| 01 | Generalize `shad_fast` | Tower mode 1; mode 2 on Wasteland, Tomb and now [ten more stages](graphics_opportunities/STAGE_SHADOW_SWEEP.md) - Dead Pool, Forest, Armory, Portal, Kahn's Arena, Goro's Lair, Pit Bottom, Outer Haven, FLAPJACK, Yoteigai Tor: 60 pairings, 1,620/1,620 identical captures, 0 trace mismatches, 0 new late frames, 39.7-56.6% fewer DMA starts. The Bridge draws no shadows. Every fightable stage with shadows now takes the fast path. **Finishers checked** (`tools/run_fatality_shadow_ab.py`, fast vs the stock loop forced at runtime, every rig capture compared): toasty, Kung Lao's split, Kahn's fatality and the soul escape with Kintaro's drop are 219/219 identical, and Raiden's lift is 92/93. That one frame differs only in the floor, because the fatality's `skydown` fade starts a pass later when the interrupt runs 2 ms longer; camera, skew and DMA counters are identical and no shadow pixel differs | CPU, DMA entries | P1 |
| 02 | Per-frame blood bit depth | **Done** - 4/3/2/1 per frame; 17,054 bytes | Video ROM | P1 |
| 03 | Portal-effect bit depth | **Done** - 5 bpp vortex/blast, body held at 6; 7,774 bytes | Video ROM | P1 |
| 04 | Family-wide palette reindexing | **Done - 5,274 B; nothing left** (2026-09-15). The four reorder candidates (MKBOLTS, JCFKICK, HHHEADHO, HHSWIPE) all draw on a fighter's own 64-colour costume palette. Raiden's bolts use costume entries 62/63 on purpose, so no reorder exists ([closure](graphics_opportunities/PALETTE_REINDEX_SCAN.md)). **Measured** ([scan](graphics_opportunities/PALETTE_REINDEX_SCAN.md)): across each palette-sharing family the union of used indices is what counts, and every main fighter table uses all 64. Family-wide total **14.4 KB** (per-frame ceiling 268.6 KB is unrealisable). **A max-index re-scan (2026-09-15) splits it.** Some families need NO reindex, only a lower `PPP>`: SHAOFIST (max index 28, 6→5 bpp), NOOBPORT's body strips (max 8, 6→4), VSART (max 14), JCMK1BLD (max 11), FIREHAND (max 7), about 6.9 KB lossless. MKBOLTS, JCFKICK, HHHEADHO and HHSWIPE use indices up to 46-63, so those still need a real palette reorder with ownership checks. **SHAOFIST done:** `PPP> 5`, **3,750 B freed** in its 96%-full sidecar, art identity 232 moved identical / 0 changed. `tools/check_lod_packing.py` (Phase D) decodes all 233 records back against SHAOFIST.IMG, and it caught the first attempt, which had edited only the comment. MAME: Kahn's portal fatality 321/321 and clap 72/72 identical to 6 bpp. **VSART, JCMK1BLD, FIREHAND done (2026-09-15):** `PPP> 4`, `4`, `3` per block in MOVEART1/MOVEART2, **1,524 B freed** (MOVEART1 −724, MOVEART2 −800); check_lod_packing covers all four sets, art identity 38 moved identical / 0 changed. MAME: VS stage plate 3/3 identical; Scorpion's start+coin hand fire 51/51 identical, with an object witness showing the new build drawing the 3 bpp headers. **The heart is now verified in a running game too (2026-09-16).** Its rig could never have worked on a shipped ROM: `tools/jc_headhole_fatality_test.lua` drove the fatality through `jc_headhole_hp_test`, which is `.set 0` in MAINEQU.ASM and marked retired. The rig now plays the retail input instead - Forward, Back, Back + HP (`scom_jc_headhole`) - and reaches the fatality on the installed ROM on the first attempt, with a per-frame KHEART witness. The lane draws **9 of 9 records with SAGs exactly matching `JCMK1BLD.TBL` and every control word at bpp 4** (KHEART2, 3A, 3B, 3C, 4, 6A, 6B, 6C, 6D), the fatality completes to Cage's victory with no crash, and the heart renders cleanly in his fist. `KHEART1` is not drawn - `KHEART6B_OPEN` replaced it as the opening frame - but it is frame 1 of MK1BLOOD.IMG's authored `HEART1` sequence, so it stays by the same policy as `AUTOGRAPH7`; the third dead-art pass already recorded that (`tools/art_ref_graph.py` classifies it AUTHORED). NOOBPORT's body stays at 6 because its palette record declares 64 colours, so LOAD2 would override the depth. Found on the way: [LOAD2 folds mirrored images as duplicates](graphics_opportunities/LOAD2_MIRROR_FOLDS.md) - 4 sprites drew wrong, all 4 now fixed. Three got alias headers. The fourth was `timefloor4A`, not `timefloor2D`: LOAD2 pads 2D to 3 wide and its checksum folded 4A onto that. It is fixed with `COF>` in TIMEFLR.LOD and verified in MAME, where 2 of 18 staircase captures change in exactly that 3×2 box | Video ROM, palettes | P2 |
| 05 | Cross-LOD exact pixel sharing | **Done** - STBURST was dead art (28,140 bytes); then [24 more unused copies](graphics_opportunities/DUP_ART_PRUNE.md) (JCSPILL's unlinked SPILL1-13, MK2MIL HATSWIPE1A-4B, FlameD1-4). What remains is staged SAHELI2 art and ~400 B of live cross-bank flame pairs, not worth alias headers | Video ROM | ~~P1~~ |
| 06 | Optimize crop and multipart partition | **Crop closed - measured** ([scan](graphics_opportunities/CROP_SCAN.md)): 326 of 9,832 records keep any transparent border, worth ~487 B re-encoded (at most 11,567 B for any encoder) and 0.06% of drawn area - LOAD2 already crops. **Partition measured** ([scan](graphics_opportunities/PARTITION_SCAN.md)): over 2,468 multipart frames, costed as the DMA bills them (41 ns per programmed pixel, transparent included, plus ~280 px per blit), merging never pays (+1.39 MB of ROM to merge everything). One cropped split per piece would save 17% of the fighter-art pixel bill, but that is ~51 µs per fighter frame (~0.56% of a frame for two) and 355 µs at most (`LKDRAGON15`). That is emulator timing; real hardware may skip compressed margins. It would mean re-authoring art, collision is unchanged (`perpiece` 0), and it is not worth doing unless a scene becomes DMA-bound | ROM, DMA, CPU | P2 |
| 07 | Generalize opaque floor/layer skipping | **Closed - measured, 0 rows anywhere but the Tower** | DMA time/entries | ~~P1~~ |
| 08 | Scale-aware culling and draw rejection | **Source-audited** ([audit](graphics_opportunities/SCALE_CULL_AUDIT.md)): the draw loop's reject (`no_multi`) and `scrtst` both use the UNSCALED size. Shrinking effects (grow_msg, toasts, reflections, pit quads) only waste a queue entry; the three magnifiers - Kahn's 2x hammer smash, the 123%-wide hit pop, Reptile's 128% orb squash - can be culled off the left/top edge while still visible. **Measured and fixed in source**, **installed 2026-09-15** (`C:/MAME/roms/mk2.zip` matches the current `rom/` chips per `tools/build_report.py`): Kahn's hammer smash with the victim in the left corner - the old test dropped a whole 2x body piece; A/B changes exactly that piece (145 snapshots, 832 px each inside x 0-42) and nothing else, victim geometry identical on all 936 frames. `no_multi` now grows the box only for magnified objects (one compare on the 1:1 path). `cot_scltab`'s "step < 0100h is not drawn" is **resolved**: magnified 1-bpp constant-colour glyphs draw at 1.25× and 2× on both builds (0 px apart). The toasts vanished because this cull dropped a magnified glyph sliding in from off the left edge (pre-fix culls 204 px there, post-fix draws them). The comment is corrected | DMA, CPU | ~~P2~~ |
| 09 | Batch eligible particle updates | **Audited - not worth building** ([audit](graphics_opportunities/PARTICLE_BATCH_AUDIT.md)): busy fights use 20-27 of 168 processes; a body explosion adds 25 and even blood at its cap bounds the total near 121; `getprc` fails soft. Batching saves processes, not objects or blits, and objects are the pool that hangs (`ermac`). Found instead: `explode_piece` grabs its 25 objects without the `objs_available` guard, and the FATALITY word still counts against the blood cap | Processes, CPU | ~~P2~~ |
| 10 | Deterministic visual budgets | **Audited** ([budgets](graphics_opportunities/BUDGET_AUDIT.md)): measured fight peaks are far under every pool (objects 45/358, processes 27/168, blood 11/64, palettes 12/35 fg + 13/45 bg, DMA queue 224/500, palette queue 15/31). Processes, palettes and both queues fail soft; objects hang (`ermac`), including via `initobj` for every round-end text letter. Four concrete gaps instead of new quota machinery; three now **fixed in source**, **installed 2026-09-15** (`C:/MAME/roms/mk2.zip` matches the current `rom/` chips per `tools/build_report.py`): `explode_piece` object guard (smoke-tested via the Raiden lift fatality), the FATALITY word on its own `pid_fatal` off the blood cap (**MAME A/B: with the cap pinned full the pre-fix ROM never shows the word, the fixed ROM shows it on the same frame as a normal round**), `spawn_drip` skipping a refused process (assembled, not exercised), and round-end text letters dropping a letter instead of hanging when fewer than 33 objects are free (normal round end pixel-identical before/after). All four gaps closed. **Fatality peaks measured** (`tools/run_fatality_budget.py`, five finishers, every frame): objects at most 165/358 in use, processes 85/168, palettes 18/35 fg and 22/45 bg, DMA queue 198/500, 0 drops. Only blood fills: Kahn's fatality hits the 64 cap within 60 frames, which is the case the `pid_fatal` fix covers | All runtime pools | P2 |
| 11 | Palette update coalescing and dirty ranges | **Closed - measured, nothing to take** ([profile + coalescer](graphics_opportunities/PALCOAL_PROTOTYPE.md)): 7 foldable transfers from power-up to a fight and 0 during it; the queue peaks at 15 of 31 with 0 drops. The coalescer works but is compiled out; the `palq_drops` counter is kept | CPU, transfer queue | ~~P1~~ |
| 12 | Profile hot paths and table-driven math | **Closed - no measured target.** [PERFORMANCE.md](PERFORMANCE.md): `overload` (the process-pass overrun meter) sits at 2 - every pass inside its tick - for 99.2% of frames, and every excursion is a screen transition, never a fight (peak 4 after play; `run_runtime_budget.py`'s 5 is latched from power-on). The real symptom under load is `sort_list`'s one bubble pass leaving transient z-order errors, not CPU overrun. Revisit only with a gameplay-correlated `peak_overload` | CPU, program ROM | ~~P2~~ |
| 13 | Palette-driven localized lighting | **Shipped on by default (2026-09-15)** - the owned-palette hit light. POWERUP sets `f_hitlight`. `tools/hitlight_watch.lua` checked it across real game flow (buy-in/continue, round and match ends, 27 sweep battles): 30/30 runs, lights in every run, 0 stuck lights, leaked palettes or stray processes ([details](graphics_opportunities/HITLIGHT_PROTOTYPE.md)) | Art avoidance | P1 |
| 14 | Palette cycling as apparent motion | Helpers exist; more suitable stage/effect ramps can use them. **THE DEAD POOL's acid ripple is not a candidate - stock already does it**: `dedpool_cycle`'s `movi 0010F0600h,a11` is `cycle_forward`'s [start **01h**, 15 colours, sleep 6] (the top byte is the start), i.e. NESS_P's authored `WCYCL_P` ramp, not 10h-1Eh. Measured in colour RAM on stage 0: NESS_P (slot 35) entries 01h-0Fh change 50 times in 300 frames, nothing else in NESS_P/DPOOL_P/DUSK1-3_P changes. A 01h+13 prototype overlapped it and gave 49/49 identical frames; removed. The acid band (rows 177-207) draws ~85% of its pixels from NESS_P 10h+ (not cycled) and ~15% from 01h-0Fh **Closed for stage backgrounds - measured (2026-09-15)** ([scan](graphics_opportunities/PALETTE_CYCLE_SCAN.md)): `tools/palette_cycle_scan.py` finds **44** strict triangle ramps in `BGNDPAL.ASM` (the 3 runs the ROM already cycles among them, which is the control), then measures how much of each composed stage actually draws from them. Four of the highest-span ramps draw **0 px**; only three clear 3% of the screen, and those go the wrong way: THE DEAD POOL's `DPOOL_P` 05h (7.11%) is grime speckle over the whole back wall and KAHN'S ARENA's `chair_p` 05h (3.17%) is the static bone pile - rotating scattered texture reads as a corrupt palette, not motion. The one coherent candidate, THE FOREST's undergrowth (`SHRUB1` 04h, 3.83%), is the dimmest at a mean 3.9/255. The helper stays cheap for anything **authored** as a ramp, which is how the acid was done; no existing background art was. | Animation ROM | ~~P1~~ |
| 15 | Edit a region's palette selectors | **Prototyped** ([palrect](graphics_opportunities/PALRECT_PROTOTYPE.md)): `pal_rect` clears `objpalet` and rewrites the palette-map SELECTOR bytes of a rectangle through a 256-word table, last thing each frame; exact (identity table = baseline, 0 px outside the rect). Cost ~0.054 scanlines per word, so small effects only (80x64 overran the frame); aligned 16-bit accesses only for FBNeo | New spatial tint effects | P2 |
| 16 | Silhouettes, echo trails, charge ghosts | **Shipped on three moves (2026-09-15): Liu Kang's bicycle kick, Raiden's torpedo dive, and the slide (Sub-Zero/Kitana/Mileena/Jax/Noob).** 18/18 trials arm, draw and disarm; 0 non-ghost pixels; pools equal to trail-off; sweep 27/27. Arm where the new pose is DRAWN - arming at the move's start snapshots the previous pose. - [ghost_rec](graphics_opportunities/GHOSTS_PROTOTYPE.md): constant-colour ghosts for any fighter, with no object, process or palette per ghost (the stock `trail_proc` spends all three and only Cage/Kahn have palettes). `ghost_arm`/`ghost_disarm` plus a self-ending lifetime; `ghost_lst` in every fight stage. MAME, 8 stages × whiff/hit/block: 24/24 arm and disarm, 0 non-ghost pixels, pools equal to trail-off; stability sweep 27/27 | Art avoidance | P1 |
| 17 | Reuse art with scale and flips | **Prototyped** ([flip reuse](graphics_opportunities/FLIPREUSE_PROTOTYPE.md)): the scan finds 19,281 B in 27 exact-mirror classes and no exact 2× copies. THE TOWER's `cloud1c/d` are now h-flipped `cloud1b/a`, freeing 10,869 B of MK6MIL, with 76/76 frames identical. A flipped object's edge clip needs swapped skips plus an x pull. Mileena's 8 left victory arms are now mirrored alias headers (3,934 B of MK3MIL; 267/267 frames identical facing each way) after `ani2` XORs the piece flip and `dclipl` takes the flip from the piece. **14,803 B freed in all.** Kahn's fist: the mirrored alias and the single-object mirror restore are in, and the **runtime A/B passes** (2026-09-15). Portal attack and portal fatality from both sides: 99/99 and 137/137 snapshots identical, piece traces equal, witness 0 failures. **`BGBIGFIST1C` pruned with sign-off: 1,728 B freed**, 1 record removed and 253 moved with identical pixels, `KAHNBIG1`/`KAHNLIL1` re-anchored. **Raiden's head roll draws `RNHEAD2/3` as H+V aliases of `RNHEAD6/7`** (2026-09-15; installed). **`RNHEAD2/3` pruned with sign-off: 764 B freed**; 2 records removed and 1,903 moved with identical pixels. The shift also required re-pointing Ermac's five lift-windup clone headers (`tools/sync_ermac_lane.py --apply`). After the prune: neck decap on Raiden 132/132 and lift on Raiden and Liu Kang 67/67, against the pre-prune build. A stale `MKRD.OBJ` nearly shipped wrong alias SAGs past Phase D, so `sync_inline_sags.py --check` now verifies the linked `mk2.out`. Two engine changes made that possible, and neither changes anything for a LOAD2 header, since none carry flip bits. Single-object `ani` now XORs a header's own flip with the facing and takes the old header's flip back out. `gsagof` no longer ORs header flips: that forced both flips on an alias frame and left a 1 px `oxval` drift. Alias anchors are (15,11) and (12,15), and their SAGs are anchored in `sync_inline_sags.py`. **MAME, against the pre-change build:** Kung Lao's neck decap on Raiden is 132/132 captures identical; its head witness has 233 samples identical and 28 alias frames at the same position with the flips toggled. Raiden's lift fatality is 67/67 identical on Liu Kang and 66/67 on Raiden. The one difference is an `explode_piece` bone chunk's arc (each build repeats itself exactly; excluding debris, all 91 traced frames match, head included; the cause of the arc change is not pinned). Kahn's portal fatality (321/321) and Sonic Clap (72/72), the `ani0` users, are identical | Video ROM | P1 |
| 18 | Span-based artless shapes | **Prototyped** ([spans](graphics_opportunities/SPAN_SHAPES_PROTOTYPE.md)): `span_pass` (MKDISP, `spanfx`, runtime-off) draws a filled ring as one `dmacal` constant-colour DMA rectangle per scanline span - no art, object or palette. Built in process time into a double buffer and blitted by `sp_drain` after the lists (queueing into the misc queue tore big rings; locking it made them vanish). MAME: 1818/1818 ring pixels exact, 0 of 408 edge pixels; a ring growing to radius 94 is whole every frame, overload unchanged, 0 drops; idle build pixel-identical to the build without it (5/5). Cap 320 spans (~radius 85). Front-most only; no gameplay producer yet | Art avoidance | P2 |
| 19 | Layer-specific strip distortion | **Prototyped** ([strips](graphics_opportunities/STRIPS_PROTOTYPE.md)): `strip_layer` draws one background list in bands through the DMA top/bottom clip (THE WASTELAND's distant mountains); 0-px seams, later layers untouched, peak_overload 2. The cost is a queue drain per band (~78 lines for 8), not pixels. **Measured as a producer (2026-09-16): too costly to make thin.** On KAHN'S ARENA's sky each band stalled ~14 scanlines; 15 bands dropped the fighters and HUD off late frames and 8 read as blocky. The arena's haze uses **`sky_rows`** instead - the sky drawn one single-row blit per scanline from a raw texture, like floor_code - exact to the pixel and costing no late frames ([arena haze](graphics_opportunities/ARENA_HAZE.md)). Built, not installed | New effects | P2 |
| 20 | CPU drawing between layers | **Prototyped** ([palrect/geo](graphics_opportunities/PALRECT_PROTOTYPE.md)): `geo_layer` in a stage dlist draws the geometry list at that depth at no extra cost (clip7 kicks the DMA per object, so a mid-list drain finishes only earlier lists). FBNeo byte-write behaviour of PIXT lines unverified | New compositing | P2 |
| 21 | Extend reflected-scene reuse | **Prototyped** ([contract](graphics_opportunities/REFLECT_CONTRACT.md)): `reflect_p1p2` (MKDISP, `reflfx`, runtime-off `@f_reflect`) is one fighter-reflection routine for any stage. The stage points `@refl_parm` at a record (base, squash, flip, phases, band, tint), and each piece is one scaled blit per phase clipped to the band, the way `shad_fast` draws shadows. It is gated on `b_shadow` + `gs_fighting`, the gate the 2026-08-20 version lacked. MAME on THE DEAD POOL: attract/select 0 px leaked, every changed pixel on the band and the pen colour, 0 px when off, cost unmeasurable, idle build 5/5 identical. Only a shimmer there, because the acid strips are 12 and 8 rows; a deeper water band could show a figure | Art avoidance | P2 |
| 22 | Dithered masks / stippled coverage | **Prototyped** ([cpu patch](graphics_opportunities/CPU_PATCH_PROTOTYPE.md)): `cpu_patch` stipple (MKDISP, `cpupatch`, runtime-off) lays a 50% checkerboard pen over a rectangle of the finished picture using aligned word writes only. The untouched pixel of each word keeps its palette because its selector is read from the map plane and handed back through `dmacmap` (low byte = even pixel). MAME 32×32: 512/512 pen pixels, 0/512 other pixels changed across 54 colours, 0 px outside. 30 lines at 32×32 and 59 at 64×32 (linear, ~0.057 lines/word), so it is capped at 2,048 px; a 64×64 request is refused whole. Screen door, not alpha; no producer yet | New effects | P2 |
| 23 | Small CPU pixel operations | **Prototyped** ([cpu patch](graphics_opportunities/CPU_PATCH_PROTOTYPE.md)): `cpu_patch` mosaic fills each block of a rectangle with its top-left pixel, index and selector, so each block keeps the right palette. MAME 32×32 block 4: 0 wrong pixels, 0 outside. 14 lines at 32×32 and 31 at 64×64 in 8 px blocks (~0.14 lines/block + ~0.011/word). Same drain/sysctrl contract as `pal_rect`; no producer yet | New effects | P2 |
| 24 | Display row repetition / vertical effects | **Prototyped** ([row repetition](graphics_opportunities/ROWREP_PROTOTYPE.md)): MAME and FBNeo both implement the 34010 line counter (DPYSTRT's low 2 bits repeat each VRAM row n+1 times before DPYADR steps by DUDATE), and both T-Unit renderers pick each scanline's row from `DPYADR`. The page flip in `dirq` rewrites DPYSTRT every frame, so that is the only place to drive it. It now ORs in `@f_rowrep & 3` (`rowrep`, MAINEQU; off at run time). MAME: DPYSTRT reads `effd`/`effe`/`efff` at 1/2/3, and in 6 static windows the x2/x3/x4 pictures equal the normal one with each row repeated, **254/254 rows, 0 mismatches**. Off, Kahn's portal fatality and clap are 321/321 and 72/72 identical. Whole-screen (HUD included) and top-anchored, so it suits transitions, not an in-fight zoom. FBNeo and real hardware not run; no producer | Whole-screen effects | P3 |
| 25 | Raster displacement variants | **Closed: both raster mechanisms are measured, and the layer-safe variant is row 19.** The `dpytap` band (`vshim`, polled from `vcount`, which reaches lines 37..273) worked in MAME: a ±2 px wave contained to its band, `peak_overload` 2. It was switched off because a display register moves every plane on its scanline; on Kahn's Arena no band holds only background ([why](GRAPHICS_CAPABILITIES.md)). The `vsplit` palette split fires on the right line, but MAME resolves colour once a frame, so no emulator can show it. Displacing ONE layer is what `strip_layer` does through the DMA clip, already prototyped with 0 px seams | New effects | ~~P3~~ |
| 26 | Retained-page / dirty-region rendering | **Closed: no measured target.** It saves DMA work on static scenes, and nothing is DMA- or CPU-bound: the process pass finishes inside its tick on 99.2% of frames and never overruns in a fight (row 12), and the DMA queue peaks at 224/500 in fights and 198/500 in fatalities (row 10). Against that, disabling auto-erase needs every page, overlapping object and palette change tracked on both flip pages, or trails become corruption. Revisit only if a scene measures DMA-bound; a single static menu would be the place to start | DMA for static scenes | ~~P3~~ |
| 27 | CPU font/geometry presentation | **Closed: measured, no ROM case** ([scan](graphics_opportunities/FONT_ROM_SCAN.md)). The three art fonts (15-pt `MK2FONT`, 11-pt `vfont`, 7-pt `FONT7`) are already 1 bpp with one colour index; the colour comes from the palette. They take 1,869 B of video ROM, against 463 KB free, and a 1-bpp CPU copy would cost the same bytes of program ROM (144 KB headroom). CPU text pays for presentation instead (no objects, drawn per frame), and `hud_pass` + `sysfont` already does that pixel-exact | Video ROM | ~~P2~~ |
| 28 | Reachability and palette identity audit | **ROTATE preservation repaired** - [review](graphics_opportunities/ROTATE_ART_AUDIT.md): ROTATE10B/C restored for live baby windows; original hashes match, 45 records remain removed and approximately 17,010 bytes saved. Inline-window auditing catches the dependency. Also [nine more pruned runs](graphics_opportunities/DEAD_ART_PRUNE.md), 53,416 bytes across MK2/3/6/7MIL and SHAOSIT. **Third pass (2026-09-15, with sign-off): 28 more records, ~23 KB.** These are the unused SHAOSIT2/3 composites, halves and bits retail never drew, and orphans. Each one was checked against the retail source, the frame lists, inline decode windows and every authored IMG sequence. `AUTOGRAPH7` was kept because it is an authored frame the retail code skips. Found on the way and fixed: the ninja's decap and headhole falls drew torso 5 in frame 6 (a Midway slip), and now draw their own torso 6. **Reference graph built (2026-09-16)** ([graph](graphics_opportunities/ART_REF_GRAPH.md)): `tools/art_ref_graph.py` classifies every packed record LIVE / WINDOW / AUTHORED / DEAD from the built ROM - listings made in a scratch tree and proved byte-identical to the build, pointers taken only from relocated fields, pixel windows from the hand-carried anchors. Validated three ways: every known case matches the hand audits (`ROTATE10B/C` WINDOW, `KHEART1` AUTHORED); on the pre-prune build all 28 signed-off removals are DEAD and the only class change since is the ninja torso fix; and a runtime DMA census over 32 scenes (78,891 SAGs drawn) saw nothing it rules out. It finds **42 DEAD records, 59,551 B - of which 57.2 KB is staged/copyright art kept by policy**; only **2,341 B across 16 records is new** (not removed; needs sign-off). **Built vs authored pixels** ([scan](graphics_opportunities/BLEED_SCAN.md)): of 9,593 records only 13 differ from their IMG; the two LOAD2 bleed cases (`JXSPLIT9A`, `STNUTCRUNCH1B`) are repaired at build time; `pitblood1a/1b` are wrong in ROM but never drawn (1a is only an `ani_flag` seed, 1b is unreferenced); the rest are stale UMK3FIRE tables | ROM, palette slots | P2 |
| 29 | Build-time allocation and regression reports | **Done** - `tools/build_report.py` puts freshness, whether the installed zips really hold the current `rom/` chips (crc_spoof-aware), video/program space, seven Phase D-style guards, stale LOAD2 tables and an optional decoded-pixel diff in one report (`tmp/build_report/`). `tools/run_runtime_budget.py` adds pool peaks from three pinned busy fights: first run objects 26-45/358, processes 20-27/168, blood 8-11/64, DMA queue 213-224/500 cells, 0 overflows/drops. The ROM latches overload and the late-queue counters from power-on, so their peaks (5, 3 late frames, 149 pending) include boot and screen transitions | Engineering cost | ~~P1~~ |
| 30 | Shared static multipart components | **Measured** ([scan](graphics_opportunities/MULTIPART_SHARE_SCAN.md)): identical 8+-row runs between same-size frames of one family, as shared horizontal pieces, are worth ~10.9 KB (lower bound) - 8.3 KB of it Kahn's stone-crack frames (same statue, only the cracks change); fighter tables share almost nothing. **Stone frames built** (2026-09-15, with sign-off): frames 1, 2 and 4-7 are now the shared statue plus crack-only patches (`data/STONECRK.IMG`, generated by `tools/make_stonecrk_img.py`, which proves every piece pixel-exact and runs in Phase D). **14,552 B of video ROM freed.** MAME: the real turn-to-stone ending, all 8 frames pixel-identical to the pre-repack ROM. Also fixed on the way: `KAHNBIG1`/`KAHNLIL1`, the stone chunks' first frame, pointed at the wrong art and are now anchored in `sync_inline_sags.py`. **installed 2026-09-15** (`C:/MAME/roms/mk2.zip` matches the current `rom/` chips per `tools/build_report.py`) | Video ROM | P2 |
| 31 | Per-asset compression policy | **Measured** ([scan](graphics_opportunities/COMP_POLICY.md)): a port of LOAD2's `zcom.c` reproduces 9,732 of 9,832 records exactly; **0** compressed records could be smaller. The only gain is 29 records under authored `ZOF>` (18,921 B); **Prototyped:** the three safe groups (ladder boxes, Tower high clouds, attract title) now `ZON>` - **8,874 B of video ROM freed**, attract 443/443, ladder 368/368 and Tower 27/27 captures identical to the previous build; `JXSPLIT9A`'s LOAD2 bit bleed is now repaired at build time (`tools/fix_load2_bit_bleed.py`, Phase B2e2/D: 0 px vs authored, 1 px better than stock); **installed 2026-09-15** (`C:/MAME/roms/mk2.zip` matches the current `rom/` chips per `tools/build_report.py`). Scorpion's rope (5.9 KB) and the Tower row clouds are `ofset`-clipped and mirrored; grown messages are scaled - all excluded. **Rope and row clouds closed (2026-09-15):** they are the only `ofset` (DMA skip) users in the source, and Midway authored exactly those two groups `ZOF>`. No stock board ever drew compressed art with a skip, and MAME cannot stand in for the DMA2 on that ([details](graphics_opportunities/COMP_POLICY.md)) | Video ROM | P2 |

## 4. Storage findings: opportunities the old compression report misses

### 4.1 Blood fading becomes cheaper without changing its palette

All 13 decoded `BLDXPD` frames exactly match their authored IMG pixel indices.
Their current 4-bpp packing is valid, but unnecessarily wide in the last six
frames. Keeping every index and the shared palette unchanged yields:

| Frames | Highest existing index | Sufficient bpp | Screening saving, bytes |
|---|---|---:|---:|
| 1–7 | 9–13 | 4 | 0 |
| 8–9 | 5 | 3 | 3,156 |
| 10 | 4 | 3 | 2,046 |
| 11–12 | 3 | 2 | 8,459 |
| 13 | 1 | 1 | 3,393 |
| Total | | | **17,054** |

These figures hold existing stored-pixel counts constant and floor fractional
bytes per frame. A rebuilt encoder can change run choices, padding and final
size, so this is a screening estimate, not 17,054 newly available bytes.
[Current LOD](../data/BLDXPD.LOD), [headers](../src/BLDXPD.TBL),
[measured records](graphics_opportunities/snapshot.json).[^5]

There is a useful loader route that the old audit overlooks. The preserved
LOAD2 source defaults `do_superbpp` on; with no start-color shift and
`packbits == 0`, it scans the highest pixel index and chooses a smaller depth.
That is the source-level behavior behind trying `PPP> 0` for an isolated
effect lane. `/B` **disables** that behavior in this source; it is not the flag
to add for automatic lowering. The shipped executable has not been validated
against this source in this review. First confirm it with a tiny fixture or
the isolated sidecar, and inspect the generated control words.
[LOAD2 defaults/options and packing](load2/load2.c).[^6]

Changing depth per frame requires the animation code to **replace** old
compression/depth bits. `ani`/`ani_flag` prepare the appropriate mask;
`ani0` bypasses that preparation and reaches a merge that can retain old
bits. The sonic-wave implementation already contains an explicit correction
for this problem. A valid packed frame is not enough if the live object's
control word is wrong. Do not switch global LOD policy to variable depth.
[`ani`, `ani0`, `gsagof`](../src/MKDISP.ASM),
[`kahn_sonic_proc`](../src/MKZAP.ASM).[^7]

### 4.2 Noob's effect art has a separate, smaller opportunity

**Implemented; see [the prototype note](graphics_opportunities/NOOBPORT_PROTOTYPE.md).**
All 23 `NOOBPORT` records also match the authored indices. The vortex and
opening-blast art can go from 6 to 5 bpp without palette remapping, for a
screened **7,766 bytes**; the real repack returned **7,774**. The whole
table's 11,086-byte figure includes `NSPORTALSHOT` casting-body pieces. Those
are fighter art, despite living in an effect-named file, so they were excluded
and pinned at 6 bpp until shadow ownership is resolved. This is an important
failure mode in table-name-only audits.

Two things the prototype established that this screening pass could not. A
`PPP>` directive applies to the `--->` lines that follow it, so one LOD can
carry several depths without being split - which is what let the body lane be
held back while the two effect lanes dropped. And mixed depth was safe here
for a specific reason rather than by luck: both effect objects are multipart,
and `ani2` rewrites each piece's control word from the record every frame, so
the stale-depth merge that garbled SONICCLAP (an `ani0` path) cannot occur.
[LOD and its body/effect distinction](../data/NOOBPORT.LOD),
[runtime portal code](../src/MKZAP.ASM), [`ani2`](../src/MKUTIL.ASM).

### 4.3 Broader reindexing is a palette-family problem

The raw heuristic scan reports **52,232 bytes without reindexing**, or
**162,274 bytes with independent per-frame reindexing**. These are alternative
screening totals, not additive savings. Neither is a production budget:
the legacy shadow exclusion list misses newer body tables such as `JCFKICK`
and the mixed Noob table; palette unions and actual active references are
not established. The CSV exposes the heuristic flag so candidates can be
reviewed rather than silently treated as safe.

The largest reindexing leads are `MKBOLTS` (~48 KB), `MKFX` (~35 KB), and
`MKBGANI` (~14 KB), followed by blood/chunks and smaller stage sets. A frame
using 12 distinct values spread up to index 57 needs 6 bpp until the values
are remapped. A 4-bpp rewrite must produce the same visible colors, preserve
transparent zero, and remain consistent with every frame that shares its
live palette. It may need one union mapping for the whole animation, which
can erase the apparent per-frame saving.

Also account for multipart objects sharing one `opal`, player animation not
automatically adopting a header's palette pointer, palette cycling ranges,
and constant-color users referring to specific indices. A separate palette
per frame can increase palette allocations, queue traffic and cleanup work.
Lower bpp saves ROM; it does not guarantee lower modeled DMA time.
[Palette lifecycle](../src/PALL.ASM), [animation path](../src/MKDISP.ASM),
[screening methodology](graphics_opportunities/README.md).

### 4.4 Exact duplicates survive across LOD boundaries

Decoded width, height and complete indexed-pixel equality identify **52
groups with 58 extra copies**. Their redundant encoded extents total about
**32,801 bytes** under the report's bit-length accounting. This is neither
RGB-only similarity nor counting multiple labels for one SAG: the scan
groups same-SAG aliases before comparing separate payloads.

The strongest example is **23 matching `STBURST` pieces** loaded by both
`MK3MIL` and `MK7MIL`, with headers in `MKST.TBL` and `MKFATAL.TBL`.
LOAD2's `CON>` sharing operates within its run; independent runs cannot
reuse each other's in-memory duplicate table. There is therefore a real
gap in the earlier claim that duplicate removal is exhausted.

**Corrected by the prototype: those 23 are not a sharing problem at all.**
Only `MKST.ASM` references `STBURST`, and it includes `MKST.TBL`, whose records
point into MK3MIL. The MK7MIL copies landed in `MKFATAL.TBL`, which only
`MKDEATH.ASM` includes, and MKDEATH.ASM never mentions them; neither set is
`.global`, so each object resolved its own copy and the MK7MIL one had no
consumer. It is dead art and was deleted - 28,140 bytes, 86% of the whole
duplicate figure. An exact-pixel duplicate scan cannot tell "two consumers
share art" from "the art was staged twice and only one copy was wired up";
ownership has to be resolved per group before any of the remaining 4,668
bytes is treated as a sharing opportunity. See
[the prototype note](graphics_opportunities/STBURST_PROTOTYPE.md).
[MK3MIL LOD](../data/MK3MIL.LOD), [MK7MIL LOD](../data/MK7MIL.LOD),
[LOAD2 implementation](load2/load2.c).[^8]

Keep each consumer's header, anchor and palette semantics while sharing a
single compatible payload/control interpretation. Retain bank-0 storage
where a CPU shadow reader requires it. For example, a duplicate fighter
piece in bank 1 does not justify moving its bank-0 counterpart. Repointing
a header alone saves **zero packed bytes**: the duplicate must be omitted
and the authorized containing payload compacted, with downstream pointers
regenerated or patched and checked. Physical slot endpoints and wrapper
ownership stay authoritative. The duplicate extent total and bpp totals
overlap and must not be added.

### 4.5 Optimize the whole encoded object, not just one statistic

Cropping empty borders, splitting sparse shapes, and sharing static
multipart pieces can reduce both stored pixels and programmed draw area.
But one piece split into ten adds nine setups, metadata and traversal work.
A practical optimizer should report **encoded bits, destination area,
piece count, program metadata and CPU-shadow compatibility** together.
Preserve animation anchors, strike/point tables, and multipart limits.

LOAD2 already searches leading/trailing compression shifts and already
handles duplicate detection and multipart cropping. Narrow images and
minimum stored-run rules can make a zero-compressed result worse than an
uncompressed result. Compare complete encoded outputs for each candidate;
do not promise a large win from merely searching the same shift choices
again. Its temporary `do_zcom` changes are restored per image, so a narrow
frame is not evidence that compression remains accidentally off for all
later frames. Its pre-generated quarter-size-image policy also does not
prove that the hardware cannot scale compressed art.
[LOAD2 packing](load2/load2.c), [zero compressor](load2/zcom.c).

Reachability work is another possibility, but assembler includes, pointer
tables, computed indices, diagnostics, fatality dispatch, CPU image readers
and externally linked art tables all matter. Absence from one `.globl` list
or a text search is not evidence that an image can be deleted. Produce a
reference graph and a reviewed candidate list before treating dead-asset
removal as a savings plan.

## 5. Frame-time savings with the strongest implementation basis

### 5.1 Expand the faster shadow path carefully

`shad_fast` is an existing optimization selected for the Tower. Its DMA
scaled-silhouette path avoids the old per-row CPU read/draw sequence.
The Tower's earlier tests reported roughly **329 → 194 blits**, with average
last-blit start position improving from **86% → 73%** of the frame and worst
position from **90% → 77%**. These are historical scene results, not expected
global savings or measurements repeated here.
[Shadow source](../src/MKDISP.ASM),
[stage opt-in/reset](../src/BGND.ASM),
[original comparison and caveats](TOWER_GUARD_REFLECTIONS.md).

The main opportunity is to validate this path stage by stage. Include both
facings, both players, invisible states, large bosses, multipart extremes,
uncompressed pieces, scaling, jumps, custom body art and fatality transitions.
Some old/new shadow differences were a correction to the old uncompressed
case, so a visual baseline must distinguish intentional fixes from regressions.

A second-order opportunity is important: the old reader's bank-0 and
6-bpp assumptions are software constraints. The fast path uses the DMA
header's depth and avoids that pixel-reading loop. **If every relevant
shadow consumer can move to that path**, more body packing and placement
choices become technically possible. Do not unlock body art merely because
one stage uses the new path, and do not bypass the allocation ledger.

### 5.2 Stop drawing what opaque layers will cover

**No additional constant top-row skip on the tested stages: see
[the prototype note](graphics_opportunities/FLOOR_SKIP_PROTOTYPE.md).** THE
TOWER already skips its 54 rows. The other measured floor stages expose
their first row in the sampled camera positions, ruling out a positive
constant top-row skip there, not every possible floor-culling technique.
The reason is structural: six of the layers the Tower draws after `floor_code`
are lists the stage BUILDS - a reflection authored to cover the marble band -
while every other stage draws only ordinary foreground scenery there, which is
partial width by nature. `port` draws nothing after its floor at all.

Two corrections that outlive the result. An offline coverage model was tried
and abandoned: the plane world-x convention in `stage_preview.py` is calibrated
against the Tower and its own report flags the Armory's planes as "centre off
by -313.5", so the likely outcome was a confident wrong number. And **full
opacity is not the criterion the shipped game uses** - the Tower's skipped band
has holes, the mirrored windows, and what shows through them is the autoerase
colour, deliberately set to the sky.

Tower already skips 54 floor rows underneath the opaque runner, avoiding
54 blits and 21,600 programmed pixels before setup overhead. Generalize
this only where the later layer is provably opaque over the full skipped
region for every scroll position. Transparency, openings, stage transitions
and moving foreground objects invalidate simplistic bounding-box coverage.
[`skew_skip` / `floor_code`](../src/MKDISP.ASM),
[Tower coverage](TOWER_GUARD_REFLECTIONS.md).

Likewise reject fully offscreen decorative objects before enqueueing, and
avoid redrawing unchanged invisible effects. Existing bounds checks use raw
dimensions in paths that also support scaling; audit enlarged/reduced
sprites and rounding before generalizing them. `b_inviso` is not handled
identically by all single/multipart paths. Preserve list ownership and
cleanup; moving an object far away is not a general substitute for safely
removing its draw. [`dclipl` / `no_multi`](../src/MKDISP.ASM).

Clipping registers are global DMA state, absent from each normal six-long
queue entry. Drain outstanding work before changing a window, issue the
bounded pass, and restore normal page/window state. A clip window can make
a reflection correct without making its DMA timer cheaper; crop submitted
dimensions where the source format permits it. The current floor has
1200-pixel source rows and per-row skew, so merging adjacent rows into one
rectangle requires solving source pitch and changing X offsets first.

### 5.3 Pool work where the semantics permit it

Rain already uses one process managing 24 persistent objects, with dedicated
state and a weather RNG. That is an existing model to extend to purely
decorative embers, dust and sparks, not a missing rain optimization.
Batch updates can save scheduler overhead and processes; it does not remove
the particles' individual blits. Preserve ground/contact behavior and ensure
any shared pool has a deterministic overflow rule.
[`rain_proc` and rain data](../src/BGND.ASM),
[scheduler](../src/MPROC.ASM).

Separate essential fighters/projectiles/HUD from optional decoration using
explicit quotas and lifetime bounds. Do not use host speed, `hcount`,
measured frame lateness or emulator timing to change shared allocation or
gameplay decisions in netplay. Even cosmetic code can affect the match if it
consumes common objects, processes or random state. Reuse isolated visual
RNG streams, and make any reduction a deterministic function of agreed game
state. Lowering an animator to one update every two ticks saves animation
work; the unchanged sprite still blits every displayed frame.
[Initialization/random state](../src/MKINIT.ASM),
[object and process ownership](../src/MKDISP.ASM).

### 5.4 Reduce palette and CPU work before increasing limits

Coalesce duplicate palette writes and submit only changed ranges. Existing
cycle helpers already demonstrate partial-range transfers. Crucially,
`palset` queues a pointer to source memory for later use: overwriting one
scratch palette for several pending transfers can make them all read the
last contents. Use buffers whose lifetimes extend through the transfer,
respect the 31-outstanding limit, and preserve queue ownership.
[`palset` / `paltrans`](../src/PALL.ASM),
[`cycle_forward` / `cycle_backward`](../src/MKUTIL.ASM).[^9]

Lookup tables can trade some program space for repeated tint, sine, scale,
envelope or coordinate work. Profile first: the source already has tables
and deliberate hot-code alignment, and the CPU has a small instruction
cache. Moving arbitrary code to RAM or unrolling everything can make the
hot working set worse. Do not raise object/process/geometry limits merely
to hide overload; extra capacity can defer failure into frame lateness.
[Geometry and DMA loops](../src/MKDISP.ASM),
[TI CPU documentation](#hardware-and-emulator-sources).

## 6. Visual opportunities without a large new art set

### 6.1 Lighting, cycling, silhouettes and reused art

Palette transformations are especially productive on this hardware. Existing
`fadeproc`/`fadepal` scale 5-bit channels and saturate; palette swap and cycle
helpers provide the other ingredients. Build reusable recipes for a short
ice-blue hit light, hot/cold material ramps, a charge pulse, lightning-lit
background materials, poison shimmer, or a spotlight impression using
separately paletted stage pieces. These affect all pixels sharing the
selected palette; clone/own a palette when only one object should change.
[`fadeproc` / `fadepal`](../src/UTIL.ASM), [PALL](../src/PALL.ASM).

Index-designed palette cycles can animate flowing liquid, electrical travel,
fire bands, a rotating portal or sign illumination using fewer pixel frames.
They work best when the art's indices describe the intended motion. Cycling
an arbitrary photographic sprite usually produces color flicker. Combining
a short geometry animation with a slow palette cycle can still replace a
much larger pre-rendered sequence. [`cycle_forward`](../src/MKUTIL.ASM).

Constant-color substitution produces silhouettes, charge ghosts and bounded
afterimages from existing art. Record a few previous positions, draw behind
the fighter, and use a small number of owned brightness/color variants.
It costs additional blits and object/palette bookkeeping, even with no new
pixel payload. Horizontal/vertical flips and independent X/Y scaling can
similarly reuse sparks, debris, squash frames or floor shadows. Multipart
reflection needs piece offsets recomputed around a common baseline; flipping
each piece does not mirror the assembled character correctly.
[DMA display path](../src/MKDISP.ASM),
[Dead Pool reflection work](DEADPOOL_ACID_REFLECTIONS.md).

There is no true alpha or destination-RGB blend in the sprite DMA path.
Use a limited-color ramp, stipple/checker mask, spatially sparse particles,
or an explicit opaque glow silhouette as an approximation. Temporal
alternation at this refresh rate can flicker and should be judged visually,
not presented as equivalent to transparency. Constant-on-zero mode can
affect stored interior zeros in compressed art; it cannot fill the edge
runs omitted by compression. The old blanket assertion that it does
nothing on compressed sprites is too broad.
[`dmacz`, `dmacal`, mode definitions](../src/SYSEQU.ASM),
[DMA zero/nonzero handling](#hardware-and-emulator-sources).

**Ghosts prototyped: see [ghost_rec](graphics_opportunities/GHOSTS_PROTOTYPE.md).**
Pose snapshots in `.bss` are drawn in `dmacnz` from `boonpal` off a display
list of their own. All 87,649 changed pixels are ghost pens, and the free
object and process counts are unchanged at every snapshot. The DMA queue
grows by 16 cells.

**Prototyped: see [the hit light](graphics_opportunities/HITLIGHT_PROTOTYPE.md).**
A private copy of the struck fighter's palette (a RAM address, so its own colour
map), tinted per refresh and handed back exactly. Measured in MAME: 0 sharer
changes, queue depth 2 of 31, 52/52 restores, 208/208 exact colours. Two rules
it established that any palette recipe here needs: a palette source must lie
below `stckst` or `palset` drops it silently, and a detached process that swaps
a fighter's palette must raise `pm_alt_pal` on the FIGHTER's process, or
`player_normpal` will never give his colours back.

### 6.2 Region recoloring through the palette-map plane

**Prototyped, 12 September 2026: works, but only for small regions.** See
[PALRECT_PROTOTYPE.md](graphics_opportunities/PALRECT_PROTOTYPE.md) (`pal_rect`,
MKDISP.ASM). Indices and everything outside the rectangle are preserved
exactly. Cost is linear at ~0.054 scanlines per two pixels. The text below is
the original proposal.

**Proposed and worth a small prototype.** CPU VRAM access has pixel-data and
palette-map modes selected through `sysctrl`'s `objpalet` bit. Diagnostics
exercise the map plane. Editing it changes which palette a visible pixel
uses while retaining that pixel's color index. This is a different mechanism
from changing the colors inside one palette.
[`objpalet` / `syscinit`](../src/SYSEQU.ASM),
[`pal_select` / CPU RAM tests](../src/DIAGDTST.ASM).[^10]

A bounded rectangular pass could remap existing palette selectors through
a table to tinted counterparts: for example, an electrical-field tint or
underwater color zone. Each original material needs an index-compatible
tinted palette, with enough allocator capacity. Optionally preserve selected
palette identities, such as HUD colors. If fighter and background share a
selector, that test cannot distinguish them. This operates on the already
composited visible pixels; it cannot recover hidden layers or provide alpha.

The prototype must drain drawing, target the correct page, save/restore
`sysctrl` and its software mirror, and account for interrupt code that writes
the mirror back. Use ordinary masked word operations rather than relying on
CPU PMASK. Begin with a small rectangle and two known palettes; confirm
pixel indices are unchanged and no map write leaks to the next frame.
Both emulator T-unit implementations expose the data/map distinction, but
this specific game effect has not been tested here.
[Initialization register writes](../src/MKINIT.ASM),
[T-unit VRAM handlers](#hardware-and-emulator-sources).

### 6.3 Insert CPU drawing at useful depths

**Prototyped, 12 September 2026: works.** `geo_layer` (MKDISP.ASM) is placed
in THE WASTELAND's display list. It covers the earlier lists and is covered
by `baklst1/2`, the fighters and the HUD, at no measurable cost. See
[PALRECT_PROTOTYPE.md](graphics_opportunities/PALRECT_PROTOTYPE.md) Part 1.

The display list recognizes a `-1` entry followed by a callback. The existing
`flash_layer` uses layer-aware placement. Therefore CPU drawing is not a
hardware-imposed frontmost-only operation: a callback can drain earlier
DMA, draw CPU content, then allow later lists to cover it.
[`display`, `disp2`, `flash_layer`](../src/MKDISP.ASM).[^11]

The missing work is a small, explicit insertion contract: preserved registers,
page/draw state, bounded CPU cost, and permitted positions in the stage's
list order. It is not a generic per-object Z sorter. This could place an
electric arc behind fighters but in front of the far background, or add a
beam between foreground props. The retired portal arc's depth problem is
an engine integration issue that this approach could address if that visual
is wanted again. Keep the synchronization cost in the measurement.

### 6.4 Strip and span rendering

**Textured strips prototyped, 12 September 2026: works.** `strip_layer`
(MKDISP.ASM) draws one background list in up to 8 bands. Each band has its
own x, set through the software window and the DMA's top/bottom clip. Seams
are exact and later layers are untouched; the price is a queue drain per
band. See [STRIPS_PROTOTYPE.md](graphics_opportunities/STRIPS_PROTOTYPE.md).
**Solid spans prototyped, 14 September 2026: works** - `span_pass` draws a
filled ring as one `dmacal` blit per span, built in process time into a double
buffer (queueing into the misc queue tore big rings). See
[SPAN_SHAPES_PROTOTYPE.md](graphics_opportunities/SPAN_SHAPES_PROTOTYPE.md).

For **solid shapes**, `dmacal` already supplies constant-color rectangles,
as used by bars. A small span generator could draw beams, expanding
rectangular waves, diamonds, coarse rings or filled polygons with no new art.
Use a few meaningful spans; a curved outline made of hundreds of tiny blits
can lose badly to one sprite or a bounded CPU line. Follow the stock valid
source/register setup rather than assuming arbitrary invalid SAGs are safe.
[Bars and geometry](../src/MKDISP.ASM), [DMA modes](../src/SYSEQU.ASM).

For **textured effects**, divide an existing layer/image into a modest number
of horizontal strips and vary X position, scale or source offset. Candidates
include a heat haze behind fighters, watery reflections, rippling portals,
wind in a banner, a perspective floor pulse, and a shattered-picture wipe.
The existing floor renderer proves the row-strip approach, but a reusable
renderer must understand compressed row addressing, source pitch, global
clips, anchors and per-strip cost. Precomputed row-start tables can help at
the cost of program metadata. Preserve the underlying positions instead of
adding displacement cumulatively.
[`floor_code` and shadow row handling](../src/MKDISP.ASM).

Prefer manipulating an isolated background layer when the intent is
background-only distortion. `dpytap` shifts the final displayed rows, including
fighters and HUD in those rows. The existing Arena fire layer, for example,
offers stage-object groups that could be displaced with stable anchors,
avoiding that compositing limitation. Validate seams between tiles before
calling the result a wave effect. [Stage lists](../src/BGND.ASM).

Reflections are already thoroughly explored on Tower and Dead Pool. The
remaining generalization is a material/coverage contract: baseline,
foreshortening, tint, which lists contribute, which opaque objects cover the
result, and a bounded number of draws. Reusing source art avoids reflection
ROM; it does not make reflected clouds, walls and animated props free to
draw. [Tower](TOWER_GUARD_REFLECTIONS.md),
[Dead Pool](DEADPOOL_ACID_REFLECTIONS.md).

**The fighter half of that contract is prototyped, 15 September 2026:
works.** `reflect_p1p2` takes the base line, squash, flip, phases, band and
tint as a record the stage points at, draws each piece as one scaled blit,
and is gated so it cannot draw off the fight. See
[REFLECT_CONTRACT.md](graphics_opportunities/REFLECT_CONTRACT.md).

### 6.5 CPU pixel effects and presentation reuse

**Mosaic and stipple prototyped, 14 September 2026: work.** `cpu_patch`
(MKDISP.ASM) is a post-process after `pal_rect`: a block mosaic, or a 50%
checkerboard stipple that leaves the other half of the pixels exactly as
drawn. A pixel-plane word write takes both pixels' selectors from `dmacmap`
(low byte = even pixel). So a word can change one pixel and keep the other's
palette, with no byte writes. See
[CPU_PATCH_PROTOTYPE.md](graphics_opportunities/CPU_PATCH_PROTOTYPE.md).
The CPU font/menu half is measured too. The art fonts are 1,869 B of 1-bpp
art, so there is no video-ROM case for replacing them. CPU text is for new,
object-free presentation, which `hud_pass` already provides
([FONT_ROM_SCAN.md](graphics_opportunities/FONT_ROM_SCAN.md)).

The TMS34010 can copy, fill and operate on CPU-readable pixels, including
art in RAM. A small patch could support a magnified inset, simple pixelation,
an indexed mask/composite, or a diagnostic preview. Estimate the patch's
read/modify/write cost and preserve both data and palette selectors where
needed. A full-screen software blend being too expensive does not establish
that a 16 × 16 patch is too expensive. Conversely, Boolean/arithmetic pixel
operations act on index values, not automatically on visible RGB colors.
[TI user/library manuals](#hardware-and-emulator-sources).

The CPU text and geometry infrastructure could also support compact menus,
training readouts or diagnostic charts with little video-ROM growth. Reuse
the production font/style only where it fits; replacing all art fonts is not
automatically a visual or performance improvement. Debug paths have their
own bounds and interrupt-off costs. [HUD and geometry](../src/MKDISP.ASM).

CPU **PMASK is a compatibility blocker** for a cross-emulator implementation:
MAME reports plane masking unsupported, and the active FBNeo `tms34` core
retains unsupported plane-mask handling. The alternate `tms34010` directory
is not the core to inspect for this T-unit integration. Use explicit software
masks for a proposed effect until both exact target emulators prove the
required operation. [CPU implementations](#hardware-and-emulator-sources).[^12]

## 7. Conditional display tricks and low-return directions

**Vertical display repetition** is a less-explored register feature. The
display start/address low bits support row repetition, while DUDATE controls
display-address advance. TI specifies DUDATE as zero or one selected bit,
not an arbitrary stride bitfield. This suggests whole-picture vertical
stretch, stepped reveal, or mosaic-like transitions. Integrate with page
flips and restore all display state; do not change sync timing merely to
obtain an effect. It affects complete displayed rows, not an isolated sprite.
[TI display-address control](https://raw.githubusercontent.com/birdybro/TMS34010_docs/master/t34010_user_guide.pdf#page=110).[^13]

**Raster changes** remain conditional. `vsplit` machinery is compiled but
inactive with a zero runtime line; `vshim` and its probe are off. Palette
splits face the existing indexed-frame renderer limitation, whereas address
changes may be represented per line. Current capabilities should not be
inferred from an old experiment being described as built. Prefer a small
number of bounded raster events and test the exact emulator/board; polling
coverage and frame restoration are part of correctness.
[Current switches](../src/MAINEQU.ASM),
[raster investigation](UNUSED_GRAPHICS_PRIMITIVES.md).

**Retained VRAM and dirty rectangles** are plausible for a static menu or
one controlled transition. They are a major change for gameplay because
autoerase, page flipping, overlapping moving objects and changing palettes
all affect what must be restored on both pages. Disable autoerase without
an invalidation/restoration plan and trails become accidental corruption.
Offscreen VRAM is not automatically unowned scratch. Explicit sprite echoes
are a much smaller starting point for a trail effect.
[Display/erase paths](../src/MKDISP.ASM),
[initialization](../src/MKINIT.ASM).

**Modern compressed sprite caches** are not an available DMA optimization.
The custom blitter reads image ROM. CPU-readable RAM or program ROM does
not become a DMA source because the processor can access it. CPU-side movie
decoding in `UNZIP` is evidence for a separate CPU rendering route, not for a
RAM-backed sprite cache. A new codec would need a CPU renderer and its own
budget, or different hardware. No normal sprite allocation should use REVX
or program padding. [Movie path](../src/UNZIP.ASM),
[allocation contract](CUSTOM_CONTENT.md),
[DMA source implementation](#hardware-and-emulator-sources).

**True rotation, perspective mapping, destination alpha/additive blend and
programmable per-pixel shaders** are not direct capabilities of this blitter.
Pre-rendered art, strips, palettes, stipple and small CPU passes can approximate
selected results. Choose an effect whose approximation looks intentional.
Do not describe palette addition or index XOR as RGB lighting.

One dimension trap also deserves correction: a test where width 1120 becomes
96 does not prove a nine-bit width register, because both `1120 & 511` and
`1120 & 1023` equal 96. The inspected emulator DMA paths mask width/height
with `0x3ff`. Probe 512, 1023 and 1024 to distinguish interpretations before
using oversized rectangles on physical hardware; normal screen-width strips
avoid this edge case. [DMA implementations](#hardware-and-emulator-sources).

## 8. Engineering cost and prototype gates

### 8.1 Make budgets visible in each asset change

The build already has sidecar placement checks and specialized content
guards. The opportunity is to consolidate their results into a compact
before/after report: slot payload and remaining reserved capacity, linked
SAG coverage, palette/depth transitions, multipart count, and predicted
draw-area/setup changes. Keep source-table versus generated-table differences
explicit. The same report can flag a sidecar that contains both body and
effect art, avoiding the table-name heuristic's false confidence.
[Active packer](../makevrom.py), [build pipeline](../build.py).[^14]

For runtime work, attach a representative scene's queue, completion and
resource peaks to the change. A small reproducible workload is more useful
than repeatedly increasing limits after a visual failure. Asset previews
should exercise the actual palette and control-word transition sequence,
including interruption and cleanup; an isolated PNG cannot reveal a stale
`opal` or `ani0` merge. These checks reduce investigation cost without
rebuilding or instrumenting unrelated gameplay for every documentation edit.

### 8.2 First prototypes

These experiments are intentionally small enough to establish an answer
before changing global rendering or allocation policy.

| Order | Prototype | Required evidence before expansion |
|---|---|---|
| 1 | ~~Repack BLDXPD alone with per-frame depth~~ **done** | Every decoded index equals the authored source; runtime control words follow 4→3→2→1 correctly; no palette/lifetime regression; actual slot payload shrinks. |
| 2 | ~~Repack only Noob vortex/blast pieces at 5 bpp~~ **done** | Body pieces keep their existing contract; portal alignment, palette and both facings match; table pointers and slot guard pass. |
| 3 | ~~Enable fast shadows on one additional busy stage~~ **done: Wasteland and Tomb** | Twelve standard fighters per stage; exact sampled captures and matching fighter/camera traces; fewer DMA starts and no new late frames. *Both now closed by row 01: **every fightable stage with shadows takes the fast path** - 60 pairings, 1,620/1,620 identical captures, 0 trace mismatches, 0 new late frames, 39.7-56.6% fewer DMA starts. Finishers compared capture by capture: 219/219 identical, and Raiden's lift 92/93 (the one frame differs only in the floor fade).* |
| 4 | ~~Share one cross-LOD STBURST pair~~ **done (as a deletion)** | Both users retain anchors, control and palette; source coverage resolves correctly; physical bytes are removed inside approved layout. |
| 5 | ~~One stage-specific opaque floor skip~~ **done - nothing to take** | Coverage remains opaque through camera travel and transitions; programmed draws/time actually fall. |
| 6 | ~~One owned palette lighting/cycle recipe~~ **done** ([hit light](graphics_opportunities/HITLIGHT_PROTOTYPE.md)) | No unintended sharer changes; bounded transfer queue; normal/interrupted cleanup, between-round teardown and freeze takeover with/without replacement lights tested. *Transitions now closed by row 13: the hit light is **on by default** and `tools/hitlight_watch.lua` rode real game flow - buy-in/continue, round and match ends, 27 sweep battles - for 30/30 runs with 0 stuck lights, 0 leaked palettes and 0 stray processes.* |
| 7 | ~~Small palette-map rectangle and one interlayer line~~ **done in MAME** ([palrect + geo_layer](graphics_opportunities/PALRECT_PROTOTYPE.md)) | Pixel/map isolation, page and register restoration, correct depth, bounded cost, MAME and FBNeo agreement. *Every gate met in MAME; the interlayer line costs nothing new. The map pass costs ~0.054 lines per 2 px (32×32 ≈ 10% of a frame; 80×64 overran). FBNeo agreement is established from source only.* |
| 8 | ~~One 4–8-strip background distortion~~ **done in MAME** ([strip_layer](graphics_opportunities/STRIPS_PROTOTYPE.md)) | Stable anchors and seams, bounded queue/time, foreground behavior matches intent. *Every gate met: 0-px seams, each band exact, later layers untouched, +7 queue cells, peak_overload unchanged. The cost is ~78 lines of DMA-drain stall for 8 bands.* |

The [ROTATE art audit](graphics_opportunities/ROTATE_ART_AUDIT.md) now records
the other agent's 47-record removal and the follow-up dependency review.
The ninja-baby protected windows changed during removal; restoring ROTATE10B/C
repairs their original hashes at a 742-byte cost. The remainder of the prune
is retained.

For asset changes, use the current build sequence and table reconciliation
rules. **Correction verified during prototype work:** current `build.py`
runs LOAD2 in Phase A, promotes tables in Phase B, and assembles in Phase C;
the assemble-before-LOAD2 warning describes the older pipeline. Its
`--asm-only` option still promotes existing temporary tables, so those inputs
must be current. Never replace all restored source TBLs wholesale. Preserve
authorized wrapper bases, capacity guards, bank rules and palette exports.
[Pipeline constraints](CUSTOM_CONTENT.md), [ledger](ASSET_SPACE_LEDGER.md).

For runtime changes, use deterministic replays/captures of both ordinary and
peak-load scenes, including cleanup and round transitions. Test the intended
MAME and FBNeo/Fightcade versions. Hardware-dependent effects additionally
need physical-board evidence. Track visual correctness separately from
average/worst frame cost and peak resource ownership. A faster effect that
occasionally leaves a palette or object behind has not passed.

## 9. Documentation corrections to carry forward

| Older claim or implication | Current correction |
|---|---|
| DMA objects cost zero CPU | Pixel transfer is offloaded; setup, traversal, queues and synchronization cost CPU. |
| CPU drawing cannot appear between layers | Display-list callbacks can provide insertion points with a drain/state contract. |
| Palette changes are whole-screen, approximately one write | They affect users of selected palettes; RGB transformations and queued transfers have real cost. |
| 16 palette slots | Current dynamic allocator is 80; transfers and pinned ownership impose additional limits. |
| All documented examples are enabled | `fxdemo=0`; `peakflash=1`; `vshim=0`; compiled `vsplit` is runtime-disabled by default. |
| Duplicate elimination is exhausted | Independent LOD runs retain exact duplicate payloads. |
| Every bpp reduction requires editing palette depth | Preserved LOAD2 has a max-index auto-depth path; executable and animation control must be verified. |
| Effect-named tables are safe to repack | NOOBPORT also contains fighter body frames; ownership matters more than filenames. |
| One LOD means one packing depth | `PPP>` is read as the LOD is walked, so it applies per block; NOOBPORT now ships two depths in one file. |
| Opaque-layer skipping generalizes past the Tower | Tested stages expose their first floor row at sampled camera stops; no additional constant top-row skip was found. Adaptive/interior/partial-width culling remains untested. |
| A skipped band has to be fully opaque | The Tower's is not. Its mirrored windows are holes, and the autoerase colour behind them is chosen to be the sky. |
| Exact pixel duplicates across LODs are sharing opportunities | Some are art staged into two runs with only one copy ever referenced. STBURST was 23 such records, and the fix was deletion. |
| The promoters keep every header correct through a reflow | They keep every *promoted* header correct. Six hand-written headers in MKBABY.ASM/MKRD.ASM point into the middle of MK7MIL and nothing regenerated them until `sync_inline_sags.py`. |
| Mixed depth in one sidecar garbles art | That was an `ani0` merge keeping stale bits. `ani2` rewrites each multipart piece's control word from the record, so multipart lanes are safe. |
| All compressed-sprite zeros are absent | Edge runs are omitted; stored interior zeros still have DMA mode semantics. |
| Fighter bank/depth constraints are intrinsic hardware limits | They come from CPU shadow paths; only a complete renderer migration can relax them safely. |
| RAM-decompressed sprites can use normal DMA | RAM supports a CPU drawing path, not the image-ROM blitter source path. |
| Largest physical gap is available allocation space | It may include reserved wrapper capacity; consult the ledger. |
| 1120→96 proves a 9-bit width | It also matches a 10-bit mask; the test is inconclusive. |

## Sources and research data

### Repository evidence

- [Graphics capability index](GRAPHICS_CAPABILITIES.md),
  [CPU/raster experiments](UNUSED_GRAPHICS_PRIMITIVES.md),
  [hardware effects](UNUSED_HARDWARE_EFFECTS.md),
  [older compression audit](SPRITE_COMPRESSION.md),
  [performance notes](PERFORMANCE.md): prior findings and experiment history.
- [MKDISP.ASM](../src/MKDISP.ASM): display-list dispatch, DMA queue, CPU
  passes, animation control merge, shadows, floor and clip state.
- [BGND.ASM](../src/BGND.ASM), [MAINEQU.ASM](../src/MAINEQU.ASM),
  [DISPEQU.ASM](../src/DISPEQU.ASM): stage selection, rain, switches and limits.
- [PALL.ASM](../src/PALL.ASM), [UTIL.ASM](../src/UTIL.ASM),
  [MKUTIL.ASM](../src/MKUTIL.ASM): palette lifetime, transfers, fades and cycles.
- [SYSEQU.ASM](../src/SYSEQU.ASM), [DIAGDTST.ASM](../src/DIAGDTST.ASM),
  [MKINIT.ASM](../src/MKINIT.ASM): register definitions, map-plane tests,
  initialization and interrupt restoration.
- [LOAD2 C source](load2/load2.c), [zero encoder](load2/zcom.c),
  [video packer](../makevrom.py): bit depth, deduplication, packing and banks.
- [Asset ledger](ASSET_SPACE_LEDGER.md), [custom content](CUSTOM_CONTENT.md):
  allocation and integration authority, including reserved REVX restrictions.
- [Snapshot JSON](graphics_opportunities/snapshot.json),
  [frame CSV](graphics_opportunities/sprite_screening.csv),
  [audit script](graphics_opportunities/audit_snapshot.py),
  [method/limits](graphics_opportunities/README.md): original offline results.

### Hardware and emulator sources

Accessed 12 September 2026. These are primary implementations or original TI
publications; emulator source confirms emulator behavior, not perfect board
timing. The online branches can change; downloaded source fingerprints are
in the [external-source manifest](graphics_opportunities/external_sources.json).

- [MAME T-unit video](https://raw.githubusercontent.com/mamedev/mame/master/src/mame/williams/midtunit_v.cpp):
  DMA register masks, timing, image-ROM reads, palette/data VRAM handlers.
- [MAME DMA pixel loops](https://raw.githubusercontent.com/mamedev/mame/master/src/mame/williams/midtunit_v.ipp):
  zero/nonzero modes, compressed row handling and scaling.
- [MAME T-unit machine driver](https://raw.githubusercontent.com/mamedev/mame/master/src/mame/williams/midtunit.cpp):
  MKII machine configuration, memory map, video and DCS integration.
- [FBNeo T-unit integration](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/burn/drv/midway/midtunit.cpp):
  clock budgeting, CPU interface, framebuffer and palette-map access.
- [FBNeo DMA implementation](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/burn/drv/midway/midtunit_dma.h):
  draw dispatch, dimensions, timing and image-ROM source behavior.
- [MAME TMS34010 CPU](https://raw.githubusercontent.com/mamedev/mame/master/src/devices/cpu/tms34010/tms34010.cpp)
  and [graphics instructions](https://raw.githubusercontent.com/mamedev/mame/master/src/devices/cpu/tms34010/34010gfx.hxx):
  CPU graphics path, display addressing, and unsupported plane masking.
- [FBNeo active CPU interface](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/cpu/tms34_intf.cpp),
  [active tms34 core](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/cpu/tms34/tms34010.cpp),
  [active graphics implementation](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/cpu/tms34/34010gfx.c):
  compatibility check against the core actually used by this driver.
- [TI TMS34010 User's Guide, original manual mirror](https://raw.githubusercontent.com/birdybro/TMS34010_docs/master/t34010_user_guide.pdf):
  CPU graphics, instruction cache, display-address update and row repetition;
  display-control discussion includes printed page 6-18 / PDF page 110.
- [TI TMS340 Graphics Library User's Guide, SPVU027](https://www.ti.com/lit/ug/spvu027/spvu027.pdf):
  CPU bitmap, primitive and graphics-library concepts. This is a capability
  reference, not a recommendation to link an incompatible library into MKII.

### Numbered source notes

[^1]: Repository source and allocation documents listed above, snapshot 12 September 2026; input fingerprints in [snapshot.json](graphics_opportunities/snapshot.json).
[^2]: MAME, [T-unit machine driver](https://raw.githubusercontent.com/mamedev/mame/master/src/mame/williams/midtunit.cpp); FBNeo, [T-unit integration](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/burn/drv/midway/midtunit.cpp), accessed 12 September 2026.
[^3]: Repository, [DISPEQU](../src/DISPEQU.ASM), [MAINEQU](../src/MAINEQU.ASM), [PALL](../src/PALL.ASM), [asset ledger](ASSET_SPACE_LEDGER.md); current resource declarations and ownership rules, 12 September 2026.
[^4]: MAME, [T-unit DMA timing](https://raw.githubusercontent.com/mamedev/mame/master/src/mame/williams/midtunit_v.cpp); FBNeo, [DMA implementation](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/burn/drv/midway/midtunit_dma.h), accessed 12 September 2026. Repository, [Tower measurements](TOWER_GUARD_REFLECTIONS.md), section “Two blits a shadow piece”.
[^5]: Original decoded-asset inventory, [frame CSV](graphics_opportunities/sprite_screening.csv) and [authored comparisons](graphics_opportunities/snapshot.json), 12 September 2026; source [BLDXPD.TBL](../src/BLDXPD.TBL).
[^6]: Midway, preserved [LOAD2 C source](load2/load2.c), `do_superbpp` default, `/B` option and `packbits == 0` branch; inspected 12 September 2026. Source behavior is not proof of executable parity.
[^7]: Repository, [MKDISP](../src/MKDISP.ASM), `ani`, `ani_flag`, `ani0`, `gsagof`; [MKZAP](../src/MKZAP.ASM), sonic-wave control-bit preparation, 12 September 2026.
[^8]: Original [duplicate groups](graphics_opportunities/snapshot.json); [MK3MIL.LOD](../data/MK3MIL.LOD), [MK7MIL.LOD](../data/MK7MIL.LOD) and LOAD2 duplicate handling, 12 September 2026.
[^9]: Repository, [PALL](../src/PALL.ASM), `palset`/`paltrans`; [MKUTIL](../src/MKUTIL.ASM), palette-cycle helpers; 12 September 2026.
[^10]: Repository, [SYSEQU](../src/SYSEQU.ASM), `objpalet`; [DIAGDTST](../src/DIAGDTST.ASM), palette-map CPU tests; MAME/FBNeo T-unit VRAM handlers, accessed 12 September 2026.
[^11]: Repository, [MKDISP](../src/MKDISP.ASM), `disp2` callback dispatch and `flash_layer`; 12 September 2026. General-purpose interlayer geometry remains proposed.
[^12]: MAME, [TMS34010 CPU](https://raw.githubusercontent.com/mamedev/mame/master/src/devices/cpu/tms34010/tms34010.cpp); FBNeo, [active tms34 CPU](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/cpu/tms34/tms34010.cpp) and [interface](https://raw.githubusercontent.com/finalburnneo/FBNeo/master/src/cpu/tms34_intf.cpp), PMASK handling, accessed 12 September 2026.
[^13]: Texas Instruments, [TMS34010 User's Guide](https://raw.githubusercontent.com/birdybro/TMS34010_docs/master/t34010_user_guide.pdf#page=110), original manual via mirror, display-control chapter including printed page 6-18; accessed 12 September 2026.
[^14]: Repository, [makevrom.py](../makevrom.py) and [build.py](../build.py), active packing and build-order logic; inspected 12 September 2026.
