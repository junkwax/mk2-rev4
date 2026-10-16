# Kahn fist reuse: packed-pixel prototype

**Completed: pruned 15 September 2026; additional multipart MAME coverage
passed 19 September 2026.**
`BGBIGFIST1C` is an exact horizontal mirror of `BGBIGFIST1B` in the current
packed video data. Sharing B's payload could remove **1,729 bytes** of C's
art, before accounting for added code/headers. The measured packed-ROM
reclamation was **1,728 bytes**, as recorded below.

## The two consumers

`MKSK.ASM:BGBIGFIST1` draws C as a multipart piece. `MKUTIL.ASM:ani2`
already combines object facing with the header flip using XOR. Keeping C's
54×67 dimensions and `(2,-41)` anchor, while substituting B's SAG and B's
compression control with `m_fliph` set, preserves its placement and pixels.
Use B's **whole compression control**, not C's control with just a flip added.

`MKZAP.ASM:kahn_big_fist_piece_start` also creates C as a single object.
`match_ani_points` overwrites its horizontal flip to match the victim, so a
mirrored header alone loses the mirror. The later `adjust_xy_a5` call uses
that same facing to move the piece 32 pixels from the victim. Restoring the
mirror before that adjustment reverses its direction: a **64-pixel error**.

The proposed correction retains C's original anchor for both consumers and
restores the header's horizontal mirror **after `adjust_xy_a5`, before
`insobj`**, only in Kahn's piece-start helper. A separate single-object anchor
header is unnecessary with this approach. Implemented insertion:

```asm
        move    *a7(oimg),a0,l
        move    *a0(icontrol),a0,w
        andi    m_fliph,a0
        move    *a7(oflags),a1,w
        xor     a0,a1
        move    a1,*a7(oflags),w
```

The ordinary pieces have no header mirror bit, so this leaves their flags
unchanged. The assembled helper passed the runtime comparisons below.
Do not apply this globally to `match_ani_points`.

## Evidence

[Prototype tool](../../tools/kahn_fist_reuse_prototype.py) decodes the current
IRWs and models both placement paths, including the single-object 32-pixel
adjustment. It compares palette indices on a 400×254 canvas at both facings,
seven horizontal positions and six vertical positions, including clipped and
fully off-screen cases.

- **168 comparisons pass**, with 73 cases containing visible baseline pixels.
- Header-only reuse fails 32 cases, confirming the negative control catches
  the single-object orientation error.
- A second negative control restores the mirror too early and detects the
  positioning error at both facings.
- Input hashes, exact header controls, payload sizes and per-case counts are
  in the [receipt](kahn_fist_reuse_results.json).

![Stock, header-only reuse and corrected reuse at both facings; grayscale palette indices](kahn_fist_reuse_comparison.png)

This models decoded pixels and placement; it does not emulate DMA clipping
or compressed-stream traversal. The preview uses grayscale palette indices,
not the game's palette. No MAME, hardware, scaling, strike-box, lifetime or
palette validation is claimed.

```powershell
python tools/kahn_fist_reuse_prototype.py --output tmp/kahn_fist_reuse
```

## Runtime gate before pruning

Retain C's original packed payload for the first assembled A/B comparison.
Add a separate mirrored alias anchored to B, guarded against SAG drift, and
route both consumers through it with the scoped post-placement correction.
Compare normal portal attacks and the portal finisher at both facings and
screen edges, including cleanup and collision placement. Exercise the
multipart animation separately if those scenarios only draw single pieces.

Only after these comparisons pass should C's LOD entry be removed. Then
rebuild/promote tables, compare retained art identity, check inline SAG guards,
and repeat the runtime comparison against the frozen pre-prune package.

### Runtime gate, run 15 September 2026: PASS

The alias and the post-placement mirror restore were already committed
(`BGBIGFIST1C_MIRROR` in MKSK.ASM, used by both consumers; the XOR restore
after `adjust_xy_a5` in `kahn_big_fist_piece_start`).

**Packages.** Two packages were built from one tree
(`tmp/kahn_fist_runtime/build_ab.py`, both asm-only, all locks and guards
passing):

- **old:** both consumers temporarily pointed back at `BGBIGFIST1C`'s own art.
  The script restores the edit in `finally`, and git shows the tree back as
  committed.
- **new:** the tree as committed.

**Run.** `tools/run_kahn_fist_reuse.py`, now windowed under `-debug`, drives
Kahn's portal attack (`KAHN_TEST_CODES=4`) and the portal fatality from both
sides. An independent witness checks every live fist piece's SAG against the
record it must be drawn from, and logs its position, flip bits and palette.

| Scenario | Side | Witness samples (old / new), failures | Snapshots identical | Piece traces |
|---|---|---|---:|---|
| Portal attack | left | 25 / 25, 0 | **99 / 99** | equal |
| Portal attack | right | 25 / 25, 0 | **99 / 99** | equal |
| Portal fatality (fired in both) | left | 127 / 127, 0 | **137 / 137** | equal |
| Portal fatality (fired in both) | right | 127 / 127, 0 | **137 / 137** | equal |

The old and new ROM hashes differ, so the two packages really are the two
variants, and a mis-built package would have shown 0 witness samples. Results:
[attack](kahn_fist_runtime_attack.json), [fatality](kahn_fist_runtime_fatality.json).

### Pruned, 15 September 2026 (with sign-off)

`BGBIGFIST1C` was removed from three places: its entry on MK5MIL.LOD line 134,
its MKSK.TBL record, and its `.globl` in the hand-maintained IMGTBL.GLO.

- **Build.** A full build with LOAD2. Phase D first stopped on the
  hand-carried SAG check: every MK5MIL record after C moved back by exactly
  C's size (0x360E bits), including `BIGSTONE1`/`LILSTONE1`, so their
  hand-carried copies `KAHNBIG1`/`KAHNLIL1` were stale.
  `tools/sync_inline_sags.py` rewrote them to 037f497ch / 037f969ch after
  its pixel-hash check passed. The asm-only rebuild then passed every guard.
- **Art identity** (whole ROM, before vs after): exactly 1 record removed
  (`BGBIGFIST1C`), 0 added, and 253 moved with identical pixels. The 8 CHANGED
  `MKRDWALK.TBL` records are the known false alarm: a retired, never-linked
  table (see MK5MIL.LOD).
- **Space.** MK5MIL's free run grew from 42,466 to 44,194 bytes, so **1,728 B
  of video ROM were freed** (bank 0 free is now 124,040 B).
- **Runtime rerun.** The frozen pre-prune `new` package against the pruned one,
  both drawing through `BGBIGFIST1C_MIRROR` (`--old-mirror`): **PASS**. The
two ROMs differ. Portal attack from both sides: 99/99 snapshots identical,
witness 25/25 samples with 0 failures. Portal fatality from both sides
(fired in every boot): 137/137 identical, witness 127/127 with 0 failures.
Piece traces are equal in all four comparisons. Results:
[attack](kahn_fist_prune_attack.json), [fatality](kahn_fist_prune_fatality.json).

Private package `tmp/kahn_fist_runtime/pruned`, not installed.

### Multipart coverage follow-up, 19 September 2026: PASS

The earlier witness checked single objects only. The runner now accepts
`--multipart` to exercise the separate `ani2`/multipart display path. It
copies a frozen package, verifies the six-piece fist list against its map,
and replaces six portal attacker animation pointers in that **private test
ROM** with the fist list. Source files and supplied packages are untouched.
This is synthetic display-path coverage, not a change to the shipped move.

The additional witness checks C's multipart RAM entry against its expected
SAG and object-facing XOR header-flip, and compares piece offsets and actor
positions between packages. It must observe at least six multipart samples;
the original single-object and cleanup checks still apply.

| Comparison | Facings | Multipart samples per boot | Identical screenshots |
|---|---|---:|---:|
| Original C vs mirrored B | both | 6 | 198/198 |
| Mirrored B before vs after pruning | both | 6 | 198/198 |

All eight boots exited successfully with zero witness failures. Multipart
and single-object traces match in each pair. Receipts:
[reuse](kahn_fist_multipart_runtime.json),
[post-prune](kahn_fist_multipart_prune.json).

```powershell
python tools/run_kahn_fist_reuse.py --old tmp/kahn_fist_runtime/old --new tmp/kahn_fist_runtime/new --multipart
python tools/run_kahn_fist_reuse.py --old tmp/kahn_fist_runtime/new --new tmp/kahn_fist_runtime/pruned --old-mirror --multipart
```

The verification suite passes **16 tests**, including a test that injection
changes only the six intended pointers and rejects an inconsistent layout
without rewriting the ZIP. These runs use the frozen September 15 packages;
they do not validate the September 19 working tree. Screen-edge multipart
clipping, scaling and physical hardware remain outside this follow-up.
