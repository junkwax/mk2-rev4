# Session findings — 2026-05-17 (garbled-sprite audit)

## Root causes found and fixed this session

### 1. MKRIGHT1 copyright text garbled (mk2_intro, attract mode)

**Root cause**: `src/MKFX.ASM` contains an **inline data block** for `MKRIGHT1`
(the MK2 copyright text from `CRIGHT.IMG`) at lines 29-33. This block has a
hardcoded SAG that `promote_tbls.py` never touches (it only handles `.TBL`
files). When `MK7MIL.LOD` was modified (`NINJAS12.IMG` at line 24, palette
additions to `NINJAS1.IMG`, `TSUNG1.IMG`), `CRIGHT.IMG`'s position in the
video ROM shifted by ~103 KB. `promote_tbls.py` correctly updated
`src/MKMK3.TBL` with the new SAG (`057447e2H`), but `MKFX.ASM`'s inline
block retained the old SAG (`0567636cH`).

**Why MKFX.ASM wins**: `mk2_intro` does `movi MKRIGHT1,a5; calla gso_dmawnz`.
The linker resolves `MKRIGHT1` to the **inline MKFX.ASM definition** (same
compilation unit), ignoring the MKMK3.TBL entry entirely.

**Fix**: Updated `src/MKFX.ASM:31` from `0567636cH` → `057447e2H`.

**Checked and OK**: `MKBABY.ASM` (SZBABE/RPBABE/SCBABE all use `054c7254H` =
NJBABE — correct, matches LOAD2), `MKRD.ASM` (KLUDGE_BOLT1A `05492ac6H` =
RNVICBOLT1A — correct, matches LOAD2).

### 2. Dead Pool (and all OLHDRS-based stages) garbled

**Root cause**: `promote_bgndtbl_stock_sags.py` only updates the 28
**labeled** entries in `src/BGNDTBL.ASM` (e.g. `LECTHDRS:`, `OLHDRS:`,
etc.). The OLHDRS array contains hundreds of anonymous inline entries (the
actual per-tile SAG values). When MK7MIL.LOD changed, ALL 581 of those
anonymous SAGs drifted — but the promote script left them stale.

Dead Pool uses `DPUL5BMOD → DPUL5BLKS`, which references OLHDRS indices
1, 2, 3… All of those had stale SAGs pointing to wrong video ROM locations.

**Fix**: Created `tools/sync_bgndtbl_sags.py` — does a line-by-line
comparison of `src/BGNDTBL.ASM` vs `tmp/load2/BGNDTBL.MK7` and replaces
every stale SAG in the stock section (lines 1–5300). Custom KFPITPL/ORNGBL
tail (lines 5301–6256) is untouched. Updated 581 entries.

**Also fixed**: netplay_boot_start was commented out in `src/MKINIT.ASM`
earlier this session so the sprite survey captures attract mode instead of
jumping straight to character select.

---

## Build pipeline — what runs when

```
python build.py          # A: LOAD2 → IRW; B1: promote TBLs; B2: promote
                         #    labeled BGNDTBL SAGs; C: assemble+link; D: sanity
python tools/sync_bgndtbl_sags.py  # ← NEW: sync anonymous BGNDTBL SAGs
                         #    Run AFTER build.py (after Phase A), BEFORE
                         #    the next build.py call re-assembles
python makerom.py        # program ROM
python makevrom.py       # video ROMs
python mamerom.py        # package → C:\MAME\roms\mk2.zip
```

`sync_bgndtbl_sags.py` should become **Phase B2b** — inserted between
the existing Phase B2 and Phase C. Add it to `build.py` after the LOAD2
snapshot promote call.

---

## Next steps

- [ ] Run MAME survey and confirm Dead Pool renders correctly
- [ ] Run full attract mode survey — capture all stages and verify no
      remaining garbled backgrounds (Tomb, Armory, Bridge, etc.)
- [ ] Wire `sync_bgndtbl_sags.py` into `build.py` as Phase B2b so it
      runs automatically every build
- [ ] Verify Reptile air-spit body sprites in actual fight (still needs
      MAME validation per prior session)
- [ ] Verify JC head-rip fatality (still needs MAME validation)
- [ ] Consider whether `netplay_boot_start` should stay disabled or be
      restored (currently commented out in `MKINIT.ASM`)
- [ ] kfpitpl_mod foreground spike z-ordering (fighters appear over spikes
      with dlists_bogus — lower priority)
- [ ] Decide orngbl_mod table_o_mods slot (currently not reachable)

---

# Session findings — 2026-05-15

> **Update (later in same day)**: see "Pass 2" section at the bottom for the
> smart-merge promoter, inventory tools, and remaining work.

# Pass 1 (earlier today)


Notes from the session debugging Reptile air-spit and Johnny Cage head-rip,
which led to a broader fix for how `src/*.TBL` files stay in sync with
LOAD2 output. Written for the next person/agent to resume from.

## Headline

The original problem was "Reptile's acid spit doesn't work." The actual root
cause was several layers deep:

1. **TBL files drift silently.** Every `.long SAG` literal in
   `src/*.TBL` is owned by LOAD2 — change a LOD and LOAD2 emits a fresh
   table to `tmp/load2/*.TBL`, but `src/*.TBL` keeps the old SAGs unless
   someone hand-copies them over. GSPA reads `src/`, so the assembled ROM
   ends up pointing the GSP DMA at stale offsets.
2. **The build ran in the wrong phase order.** `build.py` invoked GSPA
   first and LOAD2 second in one DOSBox session. GSPA would always read
   yesterday's tables.
3. **GMAKE doesn't track .TBL dependencies.** Updating a TBL doesn't dirty
   the ASMs that `.INCLUDE` it, so even a manual promote-then-rebuild was
   a no-op ("`OPUS MAKE: mk2.out is up to date`").
4. **Cage head-rip TBL was never `.INCLUDE`d at all.** `src/MKJC.ASM`
   references `JC2DEATHBLO*` labels that lived in `src/JCHRIP.TBL` but no
   `.INCLUDE` line connected them. The build was succeeding because an
   earlier commit had hand-merged JCHRIP entries into `src/MKJC.TBL`, and
   that merge got blown away by an unrelated LOAD2 regen.

## What got fixed this session

### Build pipeline (committed in this branch)

`build.py` now runs four phases:

```
Phase A:  LOAD2 (image build) → tmp/load2/*.TBL with current SAGs
Phase B:  promote_tbls.py → copy tmp/load2/*.TBL into src/*.TBL,
          delete .OBJ files whose .ASM includes a promoted TBL
Phase C:  GSPA + GSPLNK → src/mk2.out
Phase D:  promote_tbls.py --check → assert nothing drifted post-build
```

New / changed files:

- `tools/promote_tbls.py` — promotes LOAD2 tables, reports SAG shifts,
  invalidates affected .OBJs. `--check` mode is used in Phase D to fail
  the build if any TBL is stale.
- `build.py` — orchestrates the four phases, runs two DOSBox sessions.
- `dosbox_asm.conf` (renamed from `dosbox.conf`) — Phase C autoexec.
  Renamed so DOSBox Staging doesn't auto-load it as the local primary
  config and concatenate its `[autoexec]` with our custom conf.
- `dosbox_load2.conf` — Phase A autoexec.
- `src/MKJC.ASM` — added `.INCLUDE JCHRIP.TBL` after `MKJC.TBL`. This
  was the missing link that made the Cage head-rip fatality assemble.

The `-exit` flag is passed to DOSBox Staging so the autoexec `exit`
actually terminates the session instead of showing the "Preventing an
early 'exit' call from terminating" message.

`HAND_MAINTAINED` in `promote_tbls.py` lists three TBLs that LOAD2 also
emits but are pure equate sources owned by `src/`:

- `MKREVX.TBL` (has a hand-added `DCS` equate)
- `MKFLOORS.TBL`
- `MKZIP.TBL`

### REVX program-ROM layout

`makerom.py` now has a `REVX_PAYLOADS` registry and `embed_revx_payloads()`
function that:

- Embeds each registered IRW into the program-ROM image at its declared
  address.
- Fails loudly on overlap, out-of-window addresses, or window overflow.
- Prints a free-space report so future REVX additions know what's left.

Current REVX state (after Phase A produces IRWs):

| TMS address | Filename     | Bytes  | Label                          |
|-------------|--------------|-------:|--------------------------------|
| `0xFFD00000`| NINJA2.IRW   | 14,590 | Reptile air-spit body chunks   |
| `0xFFD20000`| JCHRIP.IRW   | 70,816 | Cage head-rip fatality frames  |

REVX window: `0xFFD00000 — 0xFFFFFC00` exclusive (vectors live above).
Total: 393,088 bytes. Free after JCHRIP: ~306 KB.

The original "MK3 coming soon" REVX ad (`MK8MIL.IRW`) is no longer
embedded. The runtime caller `show_rev_x` is gated by `revx_ad equ 0`
in `src/MAINEQU.ASM`. `MK8MIL.LOD` was removed from `data/IMGBUILD.BAT`
this session — it was still building a 30 KB IRW that nothing
consumed, and its `***>` directive targeted `0xFFD00000` (same as
NINJA2), which would have been a real hazard if any tool started
embedding it.

### Project state vs the user's other initiatives

Per the Outer Haven postmortem the user shared:

- **Attract mode removal** is done in the current branch (story
  sequences, hi-score, coin-page, demo-fight calls commented out in
  `MKAMODE.ASM`). The `ATRAX1-4`, `COMESOON`, `HISCORE1` payloads are
  still in `data/MK7MIL.LOD` because the postmortem mandates keeping
  load order stable; their address ranges are reuse candidates, not
  delete candidates.
- **Outer Haven (BGPROF)** is the priority custom stage, using `ORNGBL`
  pipeline at `~138 KB`. Must stay high fidelity.
- The user explicitly does **not** want IROM-bank moves of custom
  content (no `NINJA2 → MK4MIL.LOD` etc.). "Keep stock load order
  stable" — overlay retired physical ranges only after mapping them.

## What's still broken

### Reptile air-spit (NINJA2)

`do_rp_airspit` in `src/MKZAP.ASM` references body frames
`NJJUMPSPIT1/2/3` from `NINJAS10.IMG`. Currently `data/NINJA2.LOD`
loads the **single-chunk** versions of those images. The multipart
decode path expects multi-chunk frames (compare stock `NJREPSPIT1` =
`NJREPSPIT1A,NJREPSPIT1B,0`). Single-chunk + multipart path likely
explains the "Reptile entirely garbled" symptom reported during the
session.

Multi-chunk parts exist in `NINJAS10.IMG`: `NJJUMPSPIT1A` /
`NJJUMPSPIT2A,NJJUMPSPIT2B` / `NJJUMPSPIT3A,NJJUMPSPIT3B,NJJUMPSPIT3C`.
A proper fix needs:

1. `data/NINJA2.LOD` updated to load the `A/B/C` parts.
2. `NJJUMPSPITF1/2/3` wrappers in `src/MKNJ.ASM` updated to reference
   the multi-chunk parts (each frame becomes a multi-chunk record).
3. `air_spit_proc` in `src/MKZAP.ASM` should use `a_acid_fly` (stock
   `NJACID*` projectile) instead of `a_jumpspit_head` (was using
   `NJUMPSPITHED1/2` from REVX, which can be dropped from the LOD).

This work was attempted earlier in the session but reverted when the
pipeline issues were prioritized. The reverted edits are still in git
reflog (dangling commit `bd7ad0c`).

### Historical JC head-rip (JCHRIP)

This is an obsolete record of the earlier REVX experiment. It is not the active
Cage implementation and must not be revived. The current single custom
fatality is `do_jc_headhole`; see
[JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md](JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md).

## Current convention for new sprite content (for new agents)

REVX is full and reserved for its existing movie/CPU-read payload. Do **not**
create a REVX LOD, add a `REVX_PAYLOADS` tuple, or place normal PIXBLT sprites
in program ROM. Instead:

1. Choose an approved fixed image-ROM wrapper from `doc/CUSTOM_CONTENT.md` and
   verify capacity in `doc/ASSET_SPACE_LEDGER.md`.
2. Add the LOD/table through that wrapper and follow its table-promotion rules.
3. Run the full image-ROM pipeline (`build.py`, `makerom.py`, `makevrom.py`,
   `mamerom.py`) and validate the resulting ROM in MAME.

## Things worth doing next, in priority order

1. **Fix Reptile air-spit properly** using the multi-chunk parts (see
   "Reptile air-spit" above). Pipeline is now safe to iterate on.
2. **Test JC head-rip in MAME** to confirm the assembly fix produces a
   working fatality, not just a clean link.
3. **Map ATRAX1-4 / COMESOON / HISCORE physical ranges** per the
   postmortem's Step 1, so the freed space can host real new content
   (KUNGFU5 Pit bottom candidate, restored cut animations) without
   shifting unrelated SAGs.
4. **Consider adding `gmake` dependencies for .TBL → .ASM** so the .OBJ
   invalidation in `promote_tbls.py` becomes belt-and-suspenders rather
   than load-bearing. `src/MAKEFILE` doesn't currently track these.
5. **Move `MK8MIL.LOD` itself out of `data/`** (to `_old/`) so it's
   clear that file is dead. Left in place this session because it's
   only ~30 lines and removing it requires touching git history.

## Known traps reproduced this session

- `git stash` does **not** stash untracked files by default. Untracked
  files like `data/REVXGFX.LOD` and `src/JCHRIP.TBL` were lost during
  a `stash`/`stash pop` cycle and had to be recovered via
  `git fsck --lost-found` → `git checkout <dangling-commit> -- <files>`.
- DOSBox Staging auto-loads a `dosbox.conf` from the current directory
  as the local primary config. Custom confs passed via `-conf` are
  appended, not substituted. Rename the local file (or pass
  `-noprimaryconf` if your Staging version supports it) to get a clean
  single-conf run.
- The TMS34010 is bit-addressable. SAG fields in TBLs, `vaddr` in COFF,
  and the `***>` directive in LODs are all **bit addresses**. Byte
  offsets into `rom[]` need `(addr - 0xFF800000) // 8` conversion. Some
  code in this repo mixes the two and you have to be careful.
- The runtime engine appears to ignore the high byte of a chunk SAG —
  `0x02xxxxxx` and `0x04xxxxxx` are treated equivalently for the low
  24 bits. That's why MKSA.TBL can have `0x0d5d48aH` (no bank prefix)
  *and* LOAD2's regen has `0x02d5d48aH` and both work. This is also
  why the SAG-drift detector in `promote_tbls.py` compares low-24-bit
  values only — otherwise every TBL would always look stale.

## File-by-file change log this session

- `build.py` — 4-phase pipeline, `-exit` flag, conf-file split.
- `dosbox_asm.conf` (renamed from `dosbox.conf`).
- `dosbox_load2.conf` (new) — Phase A autoexec.
- `data/IMGBUILD.BAT` — drop MK8MIL, renumber to 9 LOAD2 calls.
- `makerom.py` — `REVX_PAYLOADS` registry + `embed_revx_payloads()`
  preflight; removed two ad-hoc IRW embeds.
- `src/MKJC.ASM` — added `.INCLUDE JCHRIP.TBL`.
- `tools/promote_tbls.py` (new) — TBL promoter + sanity checker.
- `doc/CUSTOM_CONTENT.md` (new earlier in session) — REVX/ORNGBL slot
  conventions.
- `doc/SESSION_FINDINGS.md` (this file).

---

# Pass 3 — bank-1 SAG decode + stock-BGNDTBL guardrail

Hunting reported garbled backgrounds (`MKBIGLOGO`, `MKSELECT`,
Shao Kahn `MOUNTAIN`, `BATTLE`) revealed two non-obvious traps and
turned up a third diagnostic gap that's now patched.

## What the artifact actually was

It wasn't a real source-tree problem. **`C:/MAME/roms/mk2.zip` on the
test path was stale by 12+ hours**, packaged before today's smart-
merge and BGNDTBL work. `src/mk2.out` was current; the artifact was
purely "MAME loading yesterday's ROM". Re-running `makevrom.py` +
`mamerom.py --source-video` against the current build fixed it.

Always check `ls -la C:/MAME/roms/mk2.zip vs src/mk2.out` before
chasing a background-corruption symptom. The mtime mismatch is the
fastest tell.

## What I learned during the hunt (worth keeping)

### Bank-1 SAG decode

Bank-1 BGND SAGs in `src/BGNDTBL.ASM` look like `0x05xxxxxx`, which
is past `0x04000000` and seemed nonsensical given `MK7MIL.LOD`'s
`***> 3000000,1` directive. The decode is:

- Bank-0 cumulative SAG space: `[0x02000000, 0x04000000)`
- Bank-1 cumulative SAG space: `[0x04000000, 0x06000000)`
- LOAD2 with `/E` (dual-bank, **required** for current build) emits
  bank-1 SAGs as `0x02000000 + ***>_value`. So `MK7MIL.LOD`'s
  `***> 3000000,1` packs starting at SAG `0x05000000`.
- Flat byte offset: `flat = bank_base + (sag - bank_sag_base) / 8`
  where `bank_base` is `0x000000` (bank 0) or `0x800000` (bank 1)
  and `bank_sag_base` is `0x02000000` (bank 0) or `0x04000000`
  (bank 1).

Confirmed by `tmp/load2/MK7MIL.TBL` ENDMARKER: `0x05F12057` =
`0x05000000 + 1,975,308 * 8 bits`. The math is in
`tools/map_retired_ranges.py:sag_to_flat_byte`.

`IMGBUILD.BAT` adding the `/E` flag was a deliberate fix (the
comment in the file documents it). Don't remove it.

### bddtool only refreshes the custom tail of BGNDTBL.ASM

Walking `midway-bddtool/tools/promote_portal_stage_to_mk2.py`
showed the script only rewrites the LAST `xxxHDRS:` block onwards —
i.e., the appended ORNGBL/TST custom-stage tail. Stock backgrounds'
SAGs are assumed stable across builds.

That assumption breaks the moment any BBB in `MK7MIL.LOD` before
the custom stuff shifts. Concretely, re-enabling `BBB> COMESOON`
or `BBB> MKCD` (which the postmortem advises keeping in the LOD
for address stability) shifts every subsequent SAG by the size of
the re-enabled content. The bddtool flow doesn't catch it.

## New tooling

### `tools/promote_bgndtbl_stock_sags.py`

Reads `tmp/load2/BGNDTBL.MK7` (a snapshot of MK7MIL's LOAD2 output
that we now preserve via IMGBUILD.BAT before REVX/ORNGBL LODs
overwrite the shared `tmp/load2/BGNDTBL.ASM`). For each label
present in both the snapshot and `src/BGNDTBL.ASM`, patches the
first `.long SAG` line in src/ to match the snapshot. Labels only
in src/ (the custom ORNGBL/TST tail, retired backgrounds) are
preserved.

Modes: `--apply` (patch + drop `src/BGND.OBJ`/`mk2.out`),
`--check` (exit 1 on drift), `--verbose`.

### `data/IMGBUILD.BAT`

Added a line after MK7MIL's LOAD2 run:
```
copy C:\TMP\LOAD2\BGNDTBL.ASM C:\TMP\LOAD2\BGNDTBL.MK7
```
Preserves MK7's BGNDTBL output so the new promoter has a reference
even after subsequent LODs (NINJA2/JCHRIP/ORNGBL) overwrite the
shared file.

### `build.py` — 5-phase pipeline

```
Phase A:  LOAD2 (image build) -> tmp/load2/*.TBL + BGNDTBL.MK7 snap
Phase B1: promote_tbls.py    -> sync per-character TBLs into src/
Phase B2: promote_bgndtbl_stock_sags.py --apply -> sync stock BGND SAGs
Phase C:  GSPA + GSPLNK       -> src/mk2.out
Phase D:  --check both promoters; fail build if drifted post-assembly
```

### `tools/promote_tbls.py` now patches CTRL too

Follow-up from the Reptile air-spit investigation: `promote_tbls.py`
is no longer SAG-only. It now treats both the first `.long SAG` and
the LOAD2 control word as LOAD2-owned fields. This matters when a LOD
switches `ZON>` / compression behavior: LOAD2 may keep the same label
but change `0x6000` raw-control words into `0x6180` / `0x6080`
zero-compressed controls.

The script still preserves the source table layout
(`W,H,ANIX,ANIY / SAG / CTRL`) and leaves palette pointers / hand-added
records alone. The change caught one stale sidecar immediately:
`src/JCHRIP.TBL` had old varied CTRL words while the current
`tmp/load2/JCHRIP.TBL` emits `0x6000` controls. That sidecar is not
currently included by ASM (`JC2DEATHBLO*` is inline in `src/MKJC.TBL`),
but keeping it synchronized prevents a future re-include from reviving
the same render bug class.

### Other diagnostic tools that helped

- `tools/map_retired_ranges.py` — SAG range table for every BBB
  payload (retired vs live). Writes `doc/RETIRED_RANGES.md`. Useful
  when planning a new overlay; tells you which physical byte range
  to target and what's currently there.
- `tools/build_sag_map.py` — three-way diff of `src/BGNDTBL.ASM` vs
  `tmp/load2/BGNDTBL.ASM` vs IRW header placement. Writes
  `doc/CURRENT_SAG_MAP.md`. Spots unexpected BGND-table drift across
  the three sources of truth while treating the known `OFHDRS`
  raw-vs-runtime bank-1 decode difference as expected.

## Constraint locked

Per user direction: **mods must remain playable on stock MK2 T-Unit
arcade hardware** (1 MB program ROM, 12 MB video ROM split bank-0
8 MB + bank-1 4 MB). No MKMIL8.LOD, no expanded ROM chip counts in
`makevrom.py`. Bank-1 has ~121 KB of slack past MK7MIL's ENDMARKER
but adding a real new bank-1 window requires hardware that stock
MK2 boards don't have.

Custom content paths in priority order:
1. **Fixed move/fatality image-ROM wrappers** — use `MOVEART1`/`MOVEART2`
   only within their documented capacity and table-promotion rules.
2. **Retired BBB video-ROM overlays** — overlay onto bytes whose
   runtime caller is commented out. ATRAX1-4, COMESOON, HISCORE1,
   MKTEAM, MKSTORY1-3, NUENT1-2 are mapped in
   `doc/RETIRED_RANGES.md`.
3. **End-of-bank-1 slack** (~121 KB after MK7MIL ENDMARKER) — small
   single-payload slot for backgrounds that won't fit in retired
   ranges.

## Outstanding (low priority)

- Reptile air-spit body render — current tree has the multi-chunk
  `NJJUMPSPIT*A/B/C` path, `ZON>` in `data/NINJA2.LOD`, and CTRL words
  synchronized against LOAD2. Projectile flight was reported clean;
  body sprites still need MAME validation. If they still mangle, look
  past stale table fields and inspect the runtime multipart/object path.
- Reconcile `tools/promote_tbls.py` vs `tools/sync_load2_tables.py`.
  Both handle per-character TBL syncing. `promote_tbls.py` is wired
  into the build; `sync_load2_tables.py` is a more flexible standalone
  alternative. Either pick one as canonical or document when to use
  which.

---

# Pass 2 — smart promoter + inventory tools

After the initial 4-phase pipeline shipped, the user reported that
graphics were still mangled. Investigation showed that the first
promoter version did a wholesale **file replace** of `src/*.TBL` from
`tmp/load2/*.TBL`. That clobbered hand-added content like the JCHRIP
entries inline in `src/MKJC.TBL` (29 records, ~130 lines worth) — the
Cage head-rip fatality lost its chunk descriptors. Same risk for the
SUBNADO palette pointers Asure added to `src/MKNJ.TBL`.

## Changes this pass

### `tools/promote_tbls.py` — smart merge

Replaced the file-replace logic with a label-aware merger:

- For each label present in both `src/*.TBL` and `tmp/load2/*.TBL`:
  patch only the first `.long SAG` line on that record to match regen.
- For labels only in `src/`: preserve untouched (probably from another
  LOD, or hand-augmented like JC2DEATHBLO entries).
- For labels only in regen: append at the bottom of the src/ file
  before any `.TEXT` directive (LOAD2 added new content).
- Trailing palette pointers (`.long FOO_P`) and any other lines past
  the SAG are preserved exactly.

Validation: corrupting 3 SAGs in `src/MKNJ.TBL` triggers `STALE` in
check mode and produces an in-place patch (`3 SAGs updated, 0 labels
appended`) that restores file to byte-identical against HEAD.

### `src/MKJC.ASM`

Reverted the `.INCLUDE JCHRIP.TBL` line I added in Pass 1 — it caused
duplicate-definition errors once `src/MKJC.TBL` was restored from HEAD
with its inline JC2DEATHBLO entries. The smart-merge now preserves
those inline entries, so the include line is no longer needed.

### `tools/find_unused_sprites.py` — IMG-internal-name inventory

Walks every `data/*.IMG`, extracts internal sprite names from the
16-byte name field, and reports names that don't appear anywhere in
`src/*.{ASM,TBL,GLO,H}` or `data/*.LOD`. Filters out chunk parts
(`FOO1A`) whose parent (`FOO1`) is referenced.

**Limit**: Only works for IMGs that have populated internal names
(NINJAS\*, BOSS\*, MKBGANI, etc.). Most character IMGs (KANG\*, CAGE\*,
HATHED\*, KAT\*, RAID\*, UGMO\*, NUJAX\*) ship with empty 16-byte name
fields and rely on LOD `--->` ordering for naming. For those, see the
next tool.

Modes: `--csv`, `--md`, `--per-img`.

### `tools/find_unused_records.py` — LOD-position inventory

Walks every `data/*.LOD`, counts how many records each LOD claims via
`--->` lines per IMG, and compares against the IMG's total record
count. Records past the exported count are unused.

Top unused-record IMGs (rough orientation, see `doc/UNUSED_RECORDS.md`
for full table):

- `MKBGANI.IMG`: 181 of 202 (90%) — background animations, only 10% used
- `BLOOD.IMG`: 101 of 216 (47%) — blood variants
- `KAT11.IMG`: 90 of 187 (48%) — Kitana extras
- `CASTLE.IMG`: 85 of 85 (100%) — entire file unused
- `CAGE10.IMG`: 79 of 228 (35%) — Cage frames (head-rip lives here)
- `RAIDWALK.IMG`: 79 of 89 (89%) — Raiden walk variants
- `NINJAS11.IMG`: 74 of 160 — ninja extras
- `MKSCORE.IMG`: 73 of 85 (86%) — score-related, mostly unused

Total: **5,357 unreferenced records across 166 IMGs**. Some of these
are real cut content; some are LOAD2-skipped padding. Each candidate
needs visual inspection (via `midway-imgtool` per user's tip) before
wiring in.

### `doc/UNUSED_SPRITES.md` (~7500 lines)

Markdown report grouped by name-family. Useful for the small subset of
IMGs with named records (search for `NINJAS`, `BOSS`, etc.).

### `doc/UNUSED_RECORDS.md` (~170 lines)

Markdown report grouped by IMG file with coverage percentages. This
is the right starting point for "what scrapped content exists" — pick
an IMG, open it in `midway-imgtool`, inspect records `[exported..total)`.

## Outstanding work, in priority order

### 1. Reptile air-spit — still broken

`do_rp_airspit` in `src/MKZAP.ASM` is using `a_spit` (ground pose) as a
fallback because the multi-chunk NJJUMPSPIT path was never finished.
The fix is straightforward and was prototyped earlier in this session:

1. Update `data/NINJA2.LOD` to load multi-chunk parts:
   `NJJUMPSPIT1A` (PON>), then POF> with `NJJUMPSPIT2A,NJJUMPSPIT2B`,
   `NJJUMPSPIT3A,NJJUMPSPIT3B,NJJUMPSPIT3C`.
2. In `src/MKNJ.ASM`, update `NJJUMPSPITF1/2/3` wrappers to multi-chunk:
   - `NJJUMPSPITF1: .long NJJUMPSPIT1A, 0`
   - `NJJUMPSPITF2: .long NJJUMPSPIT2A, NJJUMPSPIT2B, 0`
   - `NJJUMPSPITF3: .long NJJUMPSPIT3A, NJJUMPSPIT3B, NJJUMPSPIT3C, 0`
3. In `src/MKZAP.ASM` `air_spit_proc`, change `movk 9,a9`
   (`a_jumpspit_head`) to `movk 3,a9` (`a_acid_fly` — stock `NJACID*`
   projectile). Drop the `NJUMPSPITHED1/2` chunks from REVX entirely
   (they don't need to be there; the projectile uses video-ROM acid
   frames).
4. Remove `a_jumpspit_head` line from `rp_anitab2[9]` in `src/MKNJ.ASM`.
5. Rebuild — smart-promoter will pick up the new NJJUMPSPIT*A/B/C
   addresses LOAD2 emits.

### 2. JC head-rip — needs MAME verification

The assembly now links cleanly (the missing `.INCLUDE JCHRIP.TBL` was a
red herring — JC2DEATHBLO entries are already inline in
`src/MKJC.TBL`). Whether the fatality renders correctly in MAME hasn't
been verified this session. Test path: run a Cage match in MAME, get
fatality range, input `Fwd, Fwd, Up, HP` (or whatever the JC head-rip
combo is per `src/MKDEATH.ASM`).

### 3. Re-attempt user's "all ninjas garbled" sighting

The user reported that all ninjas were garbled in MAME during this
session. I couldn't reproduce it from static analysis after the smart-
merge restoration. Most likely candidate: the pipeline ran while my
`bd7ad0c` stash was active, so the test build had broken state.
Rerunning `python build.py` from current source should produce a clean
build; user should re-test and report which sprites still look wrong
if any.

### 4. Map ATRAX / COMESOON / HISCORE physical ranges

Per the Outer Haven postmortem, the strategy for adding new content is:
disable runtime callers (done), map the freed physical video-ROM
address ranges, then overlay new payloads. The mapping step hasn't
been done. Concretely: parse `src/BGNDTBL.ASM` (or LOAD2's regen) to
find the SAG of each retired background's first chunk and the SAG +
size of the last, giving an exclusive `[start, end)` byte range per
retired payload. Output should look like:

```
COMESOON   0x05E04F03 .. 0x05EXXXXX  (162,650 bytes)
ATRAX1     0xXXXXXXXX .. 0xXXXXXXXX  (58,823 bytes)
...
```

This goes in a new `doc/RETIRED_RANGES.md` and feeds the
overlay-placement decisions for the next custom stage / content add.

### 5. Inventory follow-through

The `tools/find_unused_records.py` output is a starting list, not a
recommendation list. Real "scrapped move" candidates need:

1. Visual inspection via `midway-imgtool` (open the IMG, look at
   records `[exported..total)`).
2. Cross-reference with the original `.PTG` / `.TAG` ToolSmith files
   (in `src/`) — those name some symbols that never made the final
   build (e.g., `src/MK2.TAG` has `KTSONYAPUNCH` references).
3. Decide which to re-wire and place them only in a documented image-ROM
   wrapper or retired video-ROM range; REVX is not allocatable.

A good first target by file size: `MKBGANI.IMG` (background animations)
has the largest unused fraction at 90%. If any of those are recognizable
stage-element animations (water ripples, torch flames, etc.) that
weren't wired into a stage, they could enhance backgrounds without
costing much ROM.

## Files added/changed this pass

- `tools/promote_tbls.py` — rewritten as label-aware smart merger.
- `tools/find_unused_sprites.py` — new (IMG-internal-name scan).
- `tools/find_unused_records.py` — new (LOD-position scan).
- `doc/UNUSED_SPRITES.md` — generated report.
- `doc/UNUSED_RECORDS.md` — generated report.
- `src/MKJC.ASM` — reverted `.INCLUDE JCHRIP.TBL` line (no longer needed).
