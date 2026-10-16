# Runtime pool budgets (opportunity 10)

14 September 2026. **Audited from source and existing measurements.** The
pools have large measured headroom in fights. What was missing was not more
quota machinery but four specific failure paths (now fixed in source, below)
and a measurement of a fatality ([measured 15 September](#fatality-peaks-measured-15-september-2026):
objects at most 165/358; only the blood cap fills).

## Measured peaks

From `tools/run_runtime_budget.py` (three busy fights, 2,400 frames each), the
earlier `tools/palette_pool_probe.lua` log (Dead Pool, Pit Bottom, Tomb, Kahn's
Arena), and the palette-queue profile in [PALCOAL_PROTOTYPE.md](PALCOAL_PROTOTYPE.md):

| Pool | Capacity | Peak measured | Counter / probe |
|---|---:|---:|---|
| Objects | 358 | 45 | `perf_stress.lua` free-list walk |
| Processes | 168 | 27 | `perf_stress.lua`; `palette_pool_probe` low-water 142 free |
| Blood processes | 64 (`MAX_BLOOD`) | 11 | `blood_count` |
| Foreground palette slots | 35 | 12 (Kahn's Arena) | `palette_pool_probe` |
| Background palette slots | 45 | 13 (Pit Bottom) | `palette_pool_probe` |
| DMA queue | 500 cells | 224 | `deep_dmaq`, `dmaq_over` 0, `qdma_drops` 0 |
| Palette transfer queue | 31 | 15 | `palq_drops` 0 |

All of these are fights without a fatality. The palette probe's object column
predates the free-list terminator fix and reads "unmeasured".

**Re-measured 15 September 2026, on the installed build** (hit light on by
default, ghost trails on the bicycle kick / Raiden's dive / the slide, and
`ghost_lst` in all 13 fight dlists). `tools/run_runtime_budget.py`, same three
fights, 2,400 frames each:

| Scenario | Objects | Processes | Blood | Overload | DMA queue | Drops |
|---|---:|---:|---:|---:|---:|---|
| Sub-Zero vs Scorpion, Dead Pool | 46/358 (was 40) | 35/168 (was 27) | 16/64 (was 11) | 5 | 213 | 0 |
| Kitana vs Jax, Tower | 26/358 | 27/168 (was 26) | 8/64 | 5 | 224 | 0 |
| Liu Kang vs Baraka, Armory | 45/358 | 21/168 (was 20) | 10/64 | 5 | 213 | 0 |

Every scenario clean: no overflow, no qdma or palette-queue drops, the DMA
queue unchanged. A live hit light costs one process (two at most, one per
fighter); the ghost trails cost no object, process or palette at all. The
larger Dead Pool figures are mostly a different AI fight playing out - more
blood and more objects - not a fixed overhead.

## What each pool does when it runs out

| Pool | Allocator | On exhaustion |
|---|---|---|
| Processes | `getprc` (MPROC) | **soft** - returns `a0 = 0`; blood above `MAX_BLOOD` and a corrupt free list are refused the same way |
| Palette slots, normal objects | `getfpal` in `object_setup`, `swpal` (MKUTIL) | **soft** - object keeps no/old palette (wrong colours) |
| Palette transfer queue | `palset` (PALL) | **soft** - dropped, counted in `palq_drops` |
| DMA queue | `qdma` (MKDISP) | **soft** - dropped, counted in `qdma_drops` |
| Objects | `getobj` in `object_setup` (MKUTIL) | **HANG** - `ermac 5` = `jauc $` |
| Objects / palettes via `initobj` | `initobj` (MKUTIL) | **HANG** - `ermac 6` / `ermac 7`. Callers: player objects at round start (MKGUYS `pobj_init`), the debug collision box (JOY), and **every text letter and its shadow** (MKTEXT `initobj_3`) - the round-end messages |
| Colour cyclers | `findpal` (MKUTIL) | **HANG** - `ermac 9/10/11`, but only if the palette was never loaded (a code bug, not exhaustion) |

Existing quotas/reserves: `MAX_BLOOD` (64 blood processes) and
`objs_available` (keep 32 objects back), used by only four bulk spawners:
Scorpion's toasty bones (`bone_explode3`, `bone_flight`), Yoteigai Tor's rain
(24 at once) and Goro's Lair eyes.

## Fix status (14 September 2026)

Gaps 1, 3 and 4 below are **fixed in source** and built (`build.py --asm-only`,
Phase D incl. balance.lock 468 / hurtbox.lock 361 clean; private package
`tmp/budget_fix/build`, not installed):

- **1** - `explode_piece` (MKDIE) calls `objs_available` with a 32-object
  reserve before `init_anirate`/`gso_dmawnz` and `die`s when the pool is too
  tight (`.ref objs_available`). Smoke-tested only: another session's Raiden
  lift fatality runs, which go through `r_shocker_pop` -> `explode`, passed on a
  build carrying it. The empty-pool branch itself has not been exercised.
- **3** - `create_blood_proc` (MKBLOOD) allocates blood slot 0dh
  (`fatality_drip`) as `pid_fatal` = 0203h, and `fatality_drip` creates
  `fatal_reveal` as `pid_fatal`. `getprc`'s cap and the `sucide`/`kilall`
  counters test exactly 0201h, so the word is off `MAX_BLOOD`; `murder`'s
  08000h mask still sweeps it. 0203h is not a process id anywhere else.
  **Proven in MAME** with `tmp/budget_fix/fatal_word_rig.lua` (Kitana vs
  Scorpion on THE ARMORY, P2 KO'd each round, `f_death = -1` / `f_death2 = 0`
  written at FINISH HIM so `bonus_count` runs the real `win7` path; the word is
  detected as the `objlst2` object with oid 0201h that only `fatal_reveal`
  creates), all three runs identical up to FINISH HIM at frame 2042:

  | Run | Blood cap | Peak `blood_count` | FATALITY word |
  |---|---|---:|---|
  | fixed ROM, control | normal | 7 | shown, 281 frames after FINISH HIM |
  | fixed ROM | pinned at 64 | 64 | shown, 281 frames after FINISH HIM |
  | pre-fix ROM (`tmp/bleed_scan/build`) | pinned at 64 | 64 | **never shown** |

  Checked by eye on a rerun of the fixed, pinned case: 120 frames after the
  reveal object appears the red FATALITY word is fully drawn under
  "KITANA WINS" with `blood_count` held at 64
  (`tmp/budget_fix/new_pinned-v6l4b3s6/snap/mk2/0002.png`); at +240 the game
  has moved on to the continue screen normally.

  (An earlier attempt with the Scorpion scortch rig proved nothing: that rig
  forces the victory announcement and never reaches `win7`.)
- **4** - `spawnd3` (MKBLOOD) tests `a6` after `getprc` and skips the seven
  `p_store` writes when the droplet was refused. Assembled; not exercised.

- **2** - `print_loop` (MKTEXT) now asks `objs_available` for the letter (and
  its shadow when `b1` is set) **plus a 32-object reserve** - the same reserve
  the toasty bones and body explosions keep, so text can never take the last
  objects and push the hang into the next gameplay `object_setup` - and when
  the pool is that tight it drops the letter, advancing x by its width so the
  rest of the line stays put (`.ref objs_available`). Palettes cannot fail on
  this path: `newlet_init` is `boonpal`, colour map 0. Regression A/B with the
  FATALITY-word rig on the builds before and after
  (`tmp/text_fix/text_ab.py`): identical rig logs from fight start to the word,
  and all 5 snapshot pairs - "KITANA WINS", "DOUBLE FLAWLESS", FATALITY -
  pixel-identical. The skip path itself is not exercised: emptying the object
  pool in MAME would hang both ROMs through other allocations first.

All four gaps are now fixed in source (built; private packages
`tmp/budget_fix/build`, `tmp/cull_fix/build`, `tmp/text_fix/build`; not installed).

## Gaps (as found)

1. **`explode_piece` (MKDIE) takes its 25 objects unguarded.** Safe alone (45 +
   25 of 358); a hang only if it coincides with another bulk grab. Fix: the
   `objs_available` pattern.
2. **Round-end text can hang on an empty object pool.** MKTEXT builds each
   letter and shadow through `initobj`, which `ermac`s instead of skipping, and
   it runs right after fatalities, when objects peak.
3. **The FATALITY word counts against the blood cap.** `win7` -> 
   `create_blood_proc` 0dh -> `fatality_drip` -> `create pid_blood,fatal_reveal`;
   a saturated cap drops it silently. Fix: exempt the reveal, not raise the cap.
4. **`spawn_drip` writes through a refused process.** `spawnd3` (MKBLOOD) calls
   `getprc` and stores seven `p_store` longs at `*a6(...)` without testing for
   `a0 = 0`. `p_store1-7` are bit offsets 230h-2F0h, so a refused droplet
   writes into address space 0 - the top-left of screen memory, a transient
   speck the next autoerase clears, not a crash. Fix: `jreq` on `a0` before
   the stores.

## Fatality peaks (measured 15 September 2026)

`tools/run_fatality_budget.py` runs five existing finisher rigs under
`tools/fatality_budget_wrap.lua`. The wrapper drives nothing itself; it
samples **every frame**:

- objects and processes in use (pool minus free-list length);
- `blood_count`;
- palette slots with a non-zero reference count.

It also re-zeroes the ROM's latched `peak_overload` and `deep_dmaq` on the
finisher's first frame (`f_death` ≠ 0, or `winner_status` 4 for the souls)
and reports the drop and late counters as deltas from there. The FIN window
runs from that frame to the end of the rig, so it **includes the round end**:
the win text and the FATALITY word. Each rig reads a frozen copy of the map;
the wrapper redirects the rigs' hard-coded repo paths. The build is the
current source with all four gap fixes (`tmp/cpu_patch/build`). One windowed
`-debug` boot per finisher.

| Finisher | Rig verdict | In use at start (obj / proc) | Peak objects | Peak processes | Blood | fg / bg palettes | DMA queue cells | overload | drops / late |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Scorpion toasty (bones) | PASS | 64 / 21 | **155** (+227) | **85** (+184) | 0 | 9 / 8 | 198 | 3 | 0 / 0 |
| Raiden lift (body explosion, `explode`) | PASS | 64 / 21 | 139 (+323) | 36 | 7 | 11 / 8 | 170 | 2 | 0 / 0 |
| Kung Lao split, on Kitana | PASS | 80 / 27 | **165** (+670, round end) | 68 (+93) | 50 | 10 / **22** | 166 | 3 | 0 / 0 |
| Kahn's fatality on P1 (`f_death` 7) | probe mode, no verdict line; the round ended normally, Kahn winning | 82 / 27 | 150 (+758) | 76 (+60) | **64 = the cap, within 60 frames** | 12 / 7 | 173 | 2 | 0 / 1 late |
| Shang soul escape | PASS | 90 / 17 | 100 | 30 | 8 | **18** / 7 | 162 | 2 | 0 / 0 |

"In use" is pool use, including stage objects. That is a different measure
from the display-list count in the fight table above (45); on this measure a
live fight rests at 64-90 objects in use.

What it shows:

- **Objects peak at 165 of 358 (46%).** The worst finisher still leaves 193
  free, six times the 32-object reserve that `explode_piece`, the toasty bones
  and the text letters keep back. No single finisher gets near the `ermac`
  hang; the guards matter only if effects stack.
- **Processes peak at 85 of 168**, from the toasty's bones.
- **Blood is the only pool that fills.** Kahn's fatality takes `blood_count` to
  64 within 60 frames, and Kung Lao's split reaches 50. At the cap `getprc`
  refuses further blood silently: fewer droplets, no hang. This is the
  situation gap 3 guards against. The FATALITY word now runs as `pid_fatal`,
  off the cap. Before the fix, a finisher that saturated blood as `win7` ran
  would have lost the word.
- **Palettes:** at most 18/35 foreground (the souls) and 22/45 background
  (Kung Lao's round end), with 0 palette-queue drops.
- **Frame and queues:** at most 198 of 500 DMA queue cells, `peak_overload` at
  most 3, 0 `qdma_drops`, and one late queue frame in Kahn's fatality.

Not run: Kitana's kiss and Sub-Zero's shatter (the other `explode` callers;
the Raiden lift covers `explode`), the pit throw, and several finishers
stacked in one scene. Results:
[fatality_budget_results.json](fatality_budget_results.json).
