# NOOBPORT per-block depth prototype

**Status: implemented; offline checks and a MAME run pass, 12 September 2026.**
This is opportunity 03 in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md),
and the second of its
[first prototypes](../GRAPHICS_OPPORTUNITIES.md#82-first-prototypes) after
[BLDXPD](BLDXPD_PROTOTYPE.md). FBNeo/Fightcade and physical hardware have not
been tested.

## Result

`data/NOOBPORT.LOD` now sets depth **per block** instead of once for the file.
LOAD2 reads `packbits` as it walks the LOD, so a `PPP>` applies to every
`--->` after it until the next one - three blocks, two depths:

| Block | Records | Palette | Depth | Packed bytes |
|---|---:|---|---:|---:|
| `NOOBPORTAL1-12` - the vortex | 12 | NBPORTL_P, 32 entries | 6 → **5** | 30,059 → 25,128 |
| `NSPORTALSHOT1-3` A/B - his body | 6 | NOOBDEF_P, 64 entries | 6 → **6** | 10,872 → 10,872 |
| `NOOBAIRGUNK3-8` - the blast | 5 | NOOBGUK_P, 31 entries | 6 → **5** | 17,613 → 14,768 |

| Measurement | Before | After |
|---|---:|---:|
| Packed image payload | 58,552 bytes | 50,778 bytes |
| IRW file including 68-byte header | 58,620 bytes | 50,846 bytes |
| Capacity remaining in the 65,536-byte slot | 6,984 bytes | 14,758 bytes |

**7,774 bytes saved: approximately 13.3% of the previous payload.** The
audit's screening estimate for this opportunity was 7,766; the real pack came
out 8 bytes better. The slot keeps its base and end (`0x796000..0x7A6000`) and
**nothing moves into the recovered bytes**. No pixel index, palette entry,
anchor, dimension, animation table or line of source changed.

### The body strips are the point of the prototype, not an omission

The whole table screens as 11,086 bytes, and 3,320 of that is the six
`NSPORTALSHOT` strips: only 3 of their 64 palette entries are ever indexed, so
a max-index scan would happily take them to 4 bpp. They are **Noob himself**,
living in an effect-named sidecar, and that is the exact failure mode the audit
warns table-name-only screening about. They are pinned at 6 with an explicit
`PPP> 6`, and the offline guard fails if they ever move - the open question is
the CPU shadow reader's ownership of a fighter record, not the packer.

### Why mixed depth is safe here, when it garbled SONICCLAP

Both effect sets are drawn by **multipart** objects - `get_proj_obj_m` for the
hole, `gmo_proc` for the blast - so every frame goes through `ani2`
([MKUTIL.ASM](../../src/MKUTIL.ASM)), which writes each piece's control word as
the *record's* `icontrol` with only the two flip bits substituted:

```asm
	move	*a5(icontrol),a2,w
	andi	0ffcfh,a2		; clear the "flip" bits
	...
	move	a2,*a1+,w		; ram entry #3 = control word
```

The previous depth cannot survive into the next frame. The SONICCLAP garble was
an `ani0` merge keeping stale depth bits, which is a different path and is
still a real hazard for single-part `ani0` lanes. Every lane here is uniform
anyway: all twelve vortex frames land on 5 and all five blast frames land on 5,
so nothing changes depth mid-animation.

## Validation

- The real LOAD2 binary (`DMA 2`, version `03/14/95`) chose the intended
  depths. `/B` was not used - it **disables** the max-index scan.
- Every one of the 23 records, before and after, decodes out of the packed IRW
  at the depth its own control word claims and matches the authored
  `NOOBPORT.IMG` indices **exactly**, including transparent pixels, along with
  every anchor, dimension, SAG contiguity and the final payload padding.
- The change survives the normal pipeline, not just an isolated fixture: a full
  `build.py` Phase A sweep over all 30 LODs produced a byte-identical payload
  to the single-LOD run.
- `build.py` (full Phase A-D), `makerom.py`, `makevrom.py` and packaging all
  completed in an isolated `git worktree`, because the main checkout was being
  edited at the time. The test zip is under `tmp/nbpproto/rom`; the normal
  arcade ROM was never overwritten.
- One MAME run passed **both** verdicts: the existing move rig
  (`tools/noob_portal_test.lua` - hole opens under the victim, born on
  `NOOBAIRGUNK6`, swallows him, drops him behind Noob, and a jump still clears
  it) and the new packing observer. The observer checked **879 live multipart
  pieces across 2,664 refreshes**: every piece's live mpram control word equal
  to its own record's, every piece drawing at the depth it was packed at, and
  **15 five-bit and 6 six-bit records live in the same sequence** - the
  mixed-depth claim itself, under test, rather than inferred.

## A finding this turned up: two vortex frames never draw

`NOOBPORTAL11` and `NOOBPORTAL12` were never reached in any pass, and the
arithmetic says they cannot be. `noob_portal_proc` ([MKZAP.ASM](../../src/MKZAP.ASM))
runs `NOOB_PORTAL_OPEN` + `NOOB_PORTAL_LIFE` = 50 ticks at
`NOOB_PORTAL_SPIN` = 5 ticks a frame, so an untouched portal dies on frame 10 -
and a portal that **connects** dies sooner still, because the hit *replaces*
the remaining life with `NOOB_PORTAL_HOLD` rather than adding to it. That is
2,176 packed bytes of art that never reaches the screen, equally unreachable
before this repack. It is recorded, not fixed: either retiming the portal or
trimming the lane is a gameplay change, not a packing one. The observer lists
the two by name and fails if that set ever changes in either direction.

## Reproduce

Read-only packed-art check, also registered in build Phase D:

```powershell
python tools/check_noobport_packing.py            # per-record report
python tools/check_noobport_packing.py --check    # quiet unless it fails
python tools/check_noobport_packing.py --baseline # expect the old uniform 6bpp
```

After rebuilding and packaging a ROM with the current table and payload:

```powershell
python tools/run_noobport_prototype.py --rom-dir tmp/nbpproto/rom
```

It runs under `mame_mk2test.exe` with private cfg/NVRAM/input/snapshot
directories, so it neither kills nor joins another rig's session, and it fails
on a missing verdict, a timeout, a wrong control word, a changed depth, a
palette that moves under an object, or an input file changing during the run.

## Files and evidence

- [LOD](../../data/NOOBPORT.LOD) and [generated table](../../src/NOOBPORT.TBL).
- [Offline guard](../../tools/check_noobport_packing.py) and
  [build registration](../../build.py).
- [Runtime observer](../../tools/noobport_runtime_test.lua),
  [isolated runner](../../tools/run_noobport_prototype.py) and the existing
  [move rig](../../tools/noob_portal_test.lua) it composes with.
- [Recorded packing and test results](noobport_prototype_results.json).
- [Slot ownership](../../makevrom.py) and the
  [asset ledger](../ASSET_SPACE_LEDGER.md).

The next storage prototype in the audit's order is opportunity 05: share one
cross-LOD `STBURST` pair between `MK3MIL` and `MK7MIL`. Unlike these two it
cannot be done with a LOD directive - repointing a header alone saves zero
bytes, so the duplicate has to be omitted and the containing payload compacted.
