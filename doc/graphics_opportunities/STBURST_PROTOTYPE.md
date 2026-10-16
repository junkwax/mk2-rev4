# STBURST cross-LOD prototype

**Status: implemented; offline checks and three MAME rigs pass, 12 September
2026.** This is opportunity 05 in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md)
and the third of its
[first prototypes](../GRAPHICS_OPPORTUNITIES.md#82-first-prototypes), after
[BLDXPD](BLDXPD_PROTOTYPE.md) and [NOOBPORT](NOOBPORT_PROTOTYPE.md).
FBNeo/Fightcade and physical hardware have not been tested.

## The audit had this one wrong, in a useful way

It was filed as a **sharing** problem: 23 `STBURST` pieces appearing byte for
byte in both `MK3MIL` and `MK7MIL`, with headers in `MKST.TBL` and
`MKFATAL.TBL`, to be fixed by pointing one consumer at the other's payload.

There is no second consumer. Shang's burst is played by `a_burst` →
`STBURST1..16` in [MKST.ASM](../../src/MKST.ASM), and MKST.ASM includes
`MKST.TBL` — 28 records pointing into MK3MIL, in bank 0. The 23 records
`MK7MIL` packed were written into `MKFATAL.TBL`, which only
[MKDEATH.ASM](../../src/MKDEATH.ASM) includes, and MKDEATH.ASM does not mention
`STBURST` anywhere. Neither set is `.global` — no `STBURST` symbol appears in
`mk2.map` at all — so each object file resolved its own copy and the MK7MIL one
had **no consumer**.

That is not a duplicate to be shared. It is **28,140 bytes of dead art**, and
the fix is to delete it. It reads as a duplicate in a pixel audit precisely
because the same art was staged into two runs and only one was ever wired up.

## Result

| Measurement | Before | After |
|---|---:|---:|
| `MK7MIL.IRW` payload | 1,637,980 bytes | 1,609,840 bytes |
| IRW file including header | 1,638,048 bytes | 1,609,908 bytes |
| Free run above MK7MIL (bank 1) | 24,996 bytes | **53,136 bytes** |
| Bank 1 free, total | 257,536 bytes | 285,676 bytes |

**28,140 bytes recovered**, plus 322 bytes of program `.data` from the 23 dead
headers. The recovered space is one contiguous run at `0xb89070..0xb96000`;
nothing has been moved into it. Bank 0 — the tight one — is unchanged.

This is 86% of the 32,801 bytes the audit measured across all 52 duplicate
groups. The other 29 groups are small (largest 2,555 bytes,
`UGKNOCKDOWN1A`/`SAHKNOCK1`; the `SPILL` set 1,517 in total) and those *are*
genuine two-consumer sharing problems needing the harder treatment.

## What a deletion actually costs: 627 records move

Removing bytes from the middle of a packed run slides everything after it.
Every promoted table follows automatically — and nothing in the build says
whether the picture a given label points at is still the same picture, because
the SAG is exactly what moved. So this prototype needed a check that did not
exist, and building it was most of the work:

**[tools/art_identity_snapshot.py](../../tools/art_identity_snapshot.py)**
decodes the pixels every record points at, out of the packed video ROM, and
hashes them.

```powershell
python tools/art_identity_snapshot.py --write tmp/art_before.json
... change a LOD, rebuild, makevrom ...
python tools/art_identity_snapshot.py --compare tmp/art_before.json
```

Over this change it reports **627 records moved with identical pixels, 23
removed, 0 CHANGED**. It separates breakage from bookkeeping with two flags per
record — whether the current LOAD2 pass emits it, and whether any hand-written
source mentions the label — so a leftover header for art no LOD loads any more
is reported as STALE instead of failing the run.

## The fallout the check could not see, and now can

`art_identity_snapshot.py` reads `.TBL` files. Six sprite headers are not in
any table: they are written by hand inside an `.ASM`, they point at a bit
offset in the **middle** of somebody else's packed payload in MK7MIL, and
nothing regenerates them.

| Record | Source | What it is |
|---|---|---|
| `SZBABE`, `RPBABE`, `SCBABE` | [MKBABY.ASM](../../src/MKBABY.ASM) | the ninja babality sprite, one art in three palettes |
| `KLUDGE_SHORTBOLT1A` | [MKRD.ASM](../../src/MKRD.ASM) | Raiden's short bolt |
| `KLUDGE_RN1DETHBOLT1A` | MKRD.ASM | his death bolt |
| `KLUDGE_BOLT1A` | MKRD.ASM | his victory bolt |

The deletion moved all six by -0x36F62 bits at once. Several headers of this
class already have private sync tools (`MKRIGHT1`, `KHEART6B_OPEN`, the MKSEL
VS restore chunks, the Ermac lane clones); these six had none, which is exactly
how this bug class ships.

**[tools/sync_inline_sags.py](../../tools/sync_inline_sags.py)** anchors each
one to the promoted record it sits inside, plus a fixed bit offset, and hashes
the packed bits under it. Registered in Phase D. Two details that matter:

- The hash is over **bits**, not bytes. SAGs are bit addresses and records are
  not byte aligned, so the same art at a new address usually sits at a
  different bit phase; a byte-wise hash reports differences that are not there.
  A known-good control (`SNOWBALL2`) proved the harness before it was trusted.
- None of the six decode as standalone images, because they point into the
  middle of another record. The contract is that the bits under the header do
  not change, not that they parse.

**The rewrite is provably neutral.** The pre-deletion payload was rebuilt for
the purpose, and all six rewritten addresses were verified to carry *exactly
the same bits* as the originals did before the change — addresses moved and
nothing else.

## Validation

- Only `MKST.ASM` references `STBURST` (39 mentions); `MKFATAL.TBL`'s 23
  headers had no referrer, and `mk2.map` exports no `STBURST` symbol.
- `check_sag_coverage.py`: PASS — every exported SAG lands inside its own
  sidecar. It is what caught the 23 stale `MKFATAL.TBL` headers that
  `promote_tbls` preserves as src-only labels; they were deleted by hand,
  because LOAD2 no longer emits them and nothing else would.
- Full `build.py` (Phases A–D), `makerom.py`, `makevrom.py` and packaging all
  pass, including the two new Phase D guards.
- Three MAME rigs, all PASS: `run_ermac_babality_test.ps1 -As ermac` and
  `-As reptile` (both draw `RPBABE`, one of the re-anchored records) and
  `run_raiden_victory_test.ps1` (`bolts_cleaned_up_by_rel_73`).

`tools/run_raiden_shortbolt_test.ps1` was also run; it is a state dumper with
no verdict and it never entered a fight (`gs=0` throughout), so it produced no
signal either way. That is its existing behaviour, not a finding here.

## Reproduce

```powershell
python tools/art_identity_snapshot.py --write tmp/art_before.json
python build.py && python makerom.py && python makevrom.py
python tools/art_identity_snapshot.py --compare tmp/art_before.json
python tools/sync_inline_sags.py --check
```

## Files and evidence

- [MK7MIL LOD](../../data/MK7MIL.LOD) — the removed block, and why.
- [Recorded results](stburst_prototype_results.json).
- [art_identity_snapshot.py](../../tools/art_identity_snapshot.py),
  [sync_inline_sags.py](../../tools/sync_inline_sags.py),
  [build registration](../../build.py).

The next prototype in the audit's order is number 5, one stage-specific opaque
floor skip — a frame-time change rather than a storage one, and the first of
these that cannot be verified offline at all.
