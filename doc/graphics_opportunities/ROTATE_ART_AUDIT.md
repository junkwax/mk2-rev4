# ROTATE chunk-art removal candidates

**Palette follow-up verified (2026-09-13):** the orphaned `rot2_p` and
`DGUTZ2_P` definitions and exports are removed, saving 254 program-ROM bytes.
Independent map and chip comparisons confirm the peer's isolated result;
the installed combined build also passes the three ninja babality completion
controls. See [independent receipt](palette_cleanup_followup_results.json).

## Preservation repaired (2026-09-13)

**Package promotion completed:** the verified repair now replaces both
`rom/mk2.zip` and `C:\MAME\roms\mk2.zip`. Both prior packages were backed up
under `tmp/baby_window_restore/promotion-20260913-160454-142347/`. Post-copy
verification checks the ZIP, all three compiled headers and the reconstructed
video windows; both packages match the tested SHA-256 `e7b2a955...` exactly.
The ROM retains its tested pre-commit `70b5325` dirty build stamp; the repair
was subsequently committed as `761079f`. See
[promotion receipt](baby_window_promotion_results.json).

**Unused palettes removed (2026-09-13):** `rot2_p` (only `ROTATE1A` used
it) and `DGUTZ2_P` (only `ROTATE5A`) are gone from `IMGPAL7.ASM` and both
`.GLO` files. That frees **254 bytes of program ROM**. Nothing in `src/`
references either label.

- The map shows only those two symbols removed. `rot1_p`, between them, moved
  -130 bytes, and 236 later data symbols moved -254; code, `etext` and `end`
  are unchanged.
- `build.py --asm-only` passes every Phase D check, and makerom fits the chips.
- Against the verified repair package (`e7b2a955...`), all 12 video chips and
  all 6 sound chips are byte-identical; only the two program chips differ.
- Raiden's lift fatality passes on both packages. Its explosion draws with
  `rot1_p`, and the chunk watcher saw the same 239 piece frames, all 40 kept
  ROTATE records and 0 orphan pointers. **All 32 paired snapshots are
  pixel-identical.**

The package is private (`tmp/palprune/rom/mk2.zip`); neither `rom/mk2.zip`
nor the installed MAME ROM was replaced.
[Receipt](palette_prune_results.json).

`ROTATE10B` and `ROTATE10C` are restored immediately after `ROTATE9H` in
MK7MIL. All three ninja-baby raw windows again match their original
pre-prune SHA-256 (`f1852e0f...`). The original expected hashes are reinstated;
the changed-window baseline is removed. All 14 inline guards pass.

The restoration adds **742 bytes** to the current MK7MIL IRW
(1,579,664 → 1,580,406 bytes). **45 ROTATE records remain removed**, retaining
approximately **17,010 bytes** of the original ROTATE saving. The separate
broader prune is retained. Art identity reports two restored records,
137 moved with identical pixels, zero removed and zero changed retained art;
107 stale/unreferenced records remain separately classified.

Full LOAD2/promotion followed by assembly, all Phase D guards, private ROM
packaging and ten verifier tests pass. Table promotion initially duplicated
the manually restored headers; only those duplicate copies were removed
before the successful assembly. No shared ROM installation changed.

Three isolated MAME runs complete Reptile's babality against Sub-Zero,
Reptile and Scorpion, exercising all three aliases. Each reaches start,
baby-object swap and completion on its first attempt. The rig now accepts
`EBB_VICTIM` (default 11/Jax) and confines LP confirmation to character select.
Earlier Reptile-victim attempts leaked LP during intro and were correctly
refused by the game's eligibility check; they are not passing evidence.

This repairs preservation of the malformed legacy windows. It does not
claim to supply valid replacement baby art, nor screenshot equivalence or
physical-board validation. [Restoration receipts](baby_window_restoration_results.json).

Package verification after the reported SAG drift: all three compiled baby
headers in `tmp/baby_window_restore/rom/mk2.zip` use `0546387A`, and the
packaged video chips reconstruct the original `f1852e0f...` protected window.
The old pre-prune address was `054902F2`; movement alone is expected after
compaction. At verification time, repository `rom/mk2.zip` and installed
`C:\MAME\roms\mk2.zip` still held the post-prune `bfe81821...` window at the
new address. Neither was installed/replaced by this repair's private package.

## Review follow-up: protected inline dependencies (2026-09-13)

Historical finding, resolved by the preservation repair above:

The removal below changed bytes consumed by live ninja-baby headers; visual
preservation for those consumers remains unresolved. The fact that their
compressed stream was already malformed does not establish that changing it
is harmless. Re-recording the expected hashes records a new baseline; it does
not verify preservation of the old one.

`audit_inline_art_dependencies.py` intersects the original 87-record receipt
with the inline headers from `e9818ea`, before removal. All three baby aliases
overlap **ROTATE10B and ROTATE10C** within the raw-bit windows protected by
`sync_inline_sags.py`. Each window is **7,392 bits** (28×44×6). This is the
guard's conservative window, not the 4,600-bit decoder observation reported
below and not a claim about exact malformed-stream DMA behavior.

The original source-name audit excluded ASM inline windows and skipped
undecodable headers in its decoded-span checks. It therefore could not rule
out this dependency. The ROTATE audit now reports guarded inline overlaps,
even for malformed streams, and explicitly lists affected no-identifier
candidates. Missing guarded headers fail the audit instead of returning an
empty result. Ten verifier tests pass, including both failure cases.

```powershell
python tools/audit_inline_art_dependencies.py --audit doc/graphics_opportunities/rotate_art_audit_results.json --source-ref e9818ea --json doc/graphics_opportunities/rotate_inline_dependency_results.json
```

[Historical dependency evidence](rotate_inline_dependency_results.json).
The pruning work is retained. Restoring the protected pre-prune bits, or
deliberately replacing and validating the affected baby art, remains required
before claiming preservation for these aliases. The explosion test below
does not exercise babalities.

## Removal record

Status: **removed, 2026-09-13.** The six unreferenced families (ROTATE1, 5, 6,
7, 10, 11: 47 records) are gone from `data/MK7MIL.LOD` and
`src/MKCHUNKS.TBL`, freeing **17,752 bytes of MK7MIL** (bank 1). The removal
began as an offline candidate audit, and it continues opportunities 05/28 from
the graphics audit and the unused-art lead in the flip-reuse prototype.

| Gate | Result |
|---|---|
| MK7MIL payload | 1,609,908 -> 1,592,116 bytes (-142,336 bits). 318 of those bits are the RADBOLT2.IMG repack packed in the same build (SNOWBALL2 moved `0545bb64` -> `0545ba26`), leaving **142,018 bits = 17,752 B** for ROTATE, 2 bits off the audit's union |
| Art identity (every decoded record, whole video ROM) | 47 removed, exactly these; 264 moved with identical pixels; 10 changed, all `RNVICBOLT*` packed from `RADBOLT2.IMG`, which is an earlier committed pixel edit that no LOAD2 run had packed yet, not this change |
| Build guards | Phase D passed after the inline-SAG guard caught the ninja babality header (below) and its hash was re-recorded |
| Bank 1 hole after MK7MIL | 70,928 bytes (`rom_space_report.py`) |
| Runtime, old vs new ROM | Raiden's lift fatality, which ends in `explode` through `explosion_animations`, **PASS on both**. The chunk watcher saw the same 239 frames with ROTATE pieces (peak 25), all 40 kept records drawn, and **0 pointers into the ROTATE region that miss a record start**. 31 of 32 paired snapshots are pixel-identical, all six explosion frames included; the one exception is 14 px of specks on Raiden's victory bolts, the RADBOLT2 edit |

The complete `MKCHUNKS.TBL` ROTATE family contains **87 records**, all present
in the current temporary LOAD2 tables, with **29,236 bytes** of decoded packed
payload. Forty records have named source consumers in `MKDIE.ASM`'s bone,
hip, limb, intestine and hand animation tables. Removing the whole family
would disregard those consumers.

The remaining **47 records occupy 17,752 packed bytes** and have no identifier
references in the scanned source. This expands the original ROTATE5 lead:

| Candidate family | Records | Packed bits | Byte equivalent |
|---|---:|---:|---:|
| ROTATE1 | 8 | 29,138 | 3,642.25 |
| ROTATE5 | 8 | 29,316 | 3,664.50 |
| ROTATE6 | 8 | 14,234 | 1,779.25 |
| ROTATE7 | 8 | 31,620 | 3,952.50 |
| ROTATE10 | 7 | 20,876 | 2,609.50 |
| ROTATE11 | 8 | 16,832 | 2,104.00 |
| Total | 47 | 142,016 | 17,752.00 |

Fractional byte equivalents are intentional: LOAD2 packs at bit offsets.
These are payload footprints, not measured savings from a rebuilt ROM.
The earlier ~1,830-byte ROTATE5 flip estimate counted roughly half of that
family; deleting an unused family and sharing mirrored art are different
opportunities.

## What the audit establishes

`tools/audit_rotate_art.py` decodes each candidate using its current SAG,
dimensions and DMA control word from the packed IRW layout. It retains pixel
hashes, the source-input hash, IRW hashes, generated-table membership, and
every source identifier reference with its location. It scans ASM/TBL/GLO/HDR/
INC files conservatively, excluding comments and colon label definitions.

Payload totals use interval unions, so aliases are not counted twice. No
other parsed header's decoded span overlaps these ROTATE payloads. This
overlap result covers the supported sprite-header layouts, not arbitrary
numeric pointers or unsupported tables.

The eight graphics verification tests pass, including new cases that require
animation operands to count as users and overlapping payloads to be counted
once. Run:

```powershell
python tools/audit_rotate_art.py --json doc/graphics_opportunities/rotate_art_audit_results.json
python tools/test_graphics_verification.py
```

## Reachability, resolved (2026-09-13)

The open questions above are now answered from source, and all six candidate
families (1, 5, 6, 7, 10, 11) are unreachable:

| Question | Finding |
|---|---|
| Prelinked objects | `OART.OUT` is no longer linked (`mk2.cmd`: dropped 2026-08-01 as a byte-identical copy). `ART.OUT`, the one that is linked, contains no `ROTATE` name. No `.GLO` exports a ROTATE label. |
| Who reaches ROTATE art | Only MKDIE's `explosion_animations`, a pointer table of named lists: `a_bone` (2), `a_hip` (3), `a_limb` (4), `a_intestin` (8), `a_hand` (9). Each list loops on itself with `ani_jump`. |
| Computed access | `explode` indexes `explosion_animations` by an `ani table offset` word from its data stream (`exp_burst` 0-4, `exp_kahn` 5-6, ice 7-10). Out of range, it would read another *list* pointer, never a header. The other computed site, `a_bone_lay` + `randu`, picks among `BONE3_SPIN` frames. Nothing steps from one ROTATE header to the next. |
| Inline headers | `sync_inline_sags.py` anchors `SZBABE`/`RPBABE`/`SCBABE` to `ROTATE9F` (+614 bits) and `KLUDGE_BOLT1A` to `SNOWBALL2`. **Correction, found by the build:** the babality header *starts* in ROTATE9F, but it is 28×44 at 6 bpp and its window runs through 9G and 9H into `ROTATE10B`, a candidate family. See "The ninja babality header" below. |
| Palettes | `ROTATE1A` is the only user of `rot2_p` and `ROTATE5A` the only user of `DGUTZ2_P`. Both live in hand-kept `IMGPAL7.ASM`, which the build does not regenerate, so removing the records leaves them defined and unused (a follow-up could drop them). |
| Table ownership | `MKCHUNKS.TBL` is promoted, and `promote_tbls` never deletes a label, so a removal must edit `MK7MIL.LOD` **and** delete the records from `src/MKCHUNKS.TBL` by hand. The LOD also lists `ROTATE11A` twice (PON and POF groups); LOAD2's table emits one. |

A runtime control for the kept families: `exp_burst` (the shatter at MKDIE:55
and :541) and `exp_kiss` draw `a_bone`/`a_hip`/`a_limb`/`a_intestin`/`a_hand`.
An art-identity baseline of the current video data is at
`tmp/rotate/art_before.json` (10,291 records).

## The ninja babality header

`SZBABE`, `RPBABE` and `SCBABE` (MKBABY.ASM `baby_images`, the victim baby
for Sub-Zero, Reptile, Scorpion, Smoke, Noob and Ermac) are one hand-written
header: 28×44, 6 bpp, compressed, SAG `054902f2h` in the stock layout.

The source-name audit missed it, because the header names no ROTATE label.
The build's inline-SAG guard caught it: after the removal, the bits at the
anchored address no longer hashed the same.

Decoded out of the pre-removal video ROM, **that window is not an image**:

- Rows 0-8 parse, then row 9's header asks for 15 lead + 14 trail pixels on
  a 28-pixel row.
- It reads 4,600 bits: the tail of ROTATE9F, all of 9G and 9H, and ~1,378
  bits of ROTATE10B.
- Rendered, it is streaky noise, before and after the removal alike.

So the ninja babality baby has been drawing garbage all along. That is a
pre-existing defect, not something this change introduced. The header was
evidently carried over from a layout where real art sat at that address.

After the removal, the same anchor (ROTATE9F + 614) reads identical bits until
the old ROTATE10B stretch, then BONE1_SPIT2. The guard's expected hash was
re-recorded rather than the anchor moved: there is no correct art to point at
either way. Restoring a real baby would need the art itself.

## Reproduce

```powershell
python tools/art_identity_snapshot.py --write tmp/rotate/art_before.json   # before the LOD edit
python build.py; python tools/sync_inline_sags.py; python build.py --asm-only
python makerom.py; python makevrom.py
python mamerom.py --no-install --output tmp/rotate/rom/mk2.zip
python tools/art_identity_snapshot.py --compare tmp/rotate/art_before.json
python tmp/rotate/run_watch.py     # Raiden lift fatality + chunk watcher, old vs new ROM, windowed
```

`run_watch.py` stages `src/*.TBL` plus MKRD/MKGUYS/MKFALL.ASM into each frozen
root, because the Raiden rig labels SAGs from them. Without them it fails at
rel 4 with `body_off_table`. `rot2_p` and `DGUTZ2_P` in IMGPAL7.ASM are now
unreferenced and could go in a follow-up.

[Machine-readable evidence](rotate_art_audit_results.json) ·
[Audit tool](../../tools/audit_rotate_art.py)
