# Duplicate art prune: the rest of opportunity 05

**Status: removed and installed, 2026-09-13 (user-approved).** Opportunity 05
in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md) listed 4,668 bytes of
exact pixel duplicates left after STBURST. A regenerated scan
(`tools/flip_scale_scan.py` now writes `dup_classes`) splits them into dead
copies, which are deleted here, and a remainder not worth sharing.

## Removed: 24 records nothing can draw

| Copy | Where | Why it was dead |
|---|---|---|
| `SPILL1-13` | MOVEART2 bank-0 sidecar, `JCSPILL.TBL` | **No ASM includes `JCSPILL.TBL`**, so these records were packed and never linked. The Cage spill in MKDEATH resolves to `MKBLOOD.TBL`'s exported `SPILL1-13` in MK6MIL; the scan called both "used" only because the names match. About 2,216 B of payload. |
| `HATSWIPE1A-4B` (7) | MK2MIL | Kung Lao's `HHHSWIPE1-4` draw the whole `HATSWIPE1-4` frames from MOVEART1; only `HATSWIPE5A-8B` are used from MK2MIL. MK2MIL.IRW shrank 1,150 bytes. |
| `FlameD1-4` | MK6MIL | Unnamed; BGND's flame lists use `FlameB`/`FlameC`. MK6MIL.IRW shrank 148 bytes. |

`src/JCSPILL.TBL` itself was deleted too, together with its stale
`tmp/load2` copy. Otherwise `tools/check_sag_coverage.py` (Phase D) fails:
it matches MK6MIL's exported `SPILL` labels against the dead table's
addresses, and `promote_tbls.py` would recreate the table from LOAD2's leftover.
`tools/jc_headhole_fatality_test.lua` only warns when that table is missing,
and labels spills from MKBLOOD.

## Not taken

| Class | Bytes | Reason |
|---|---:|---|
| `SAHKNOCK1` = Baraka `UGKNOCKDOWN1A` | 2,555 | Our own staged, unwired SAHELI2 art - kept on purpose |
| `HANDFLAME1-9` (MOVEART2, FIREHAND) = `FlameB/C` (MK6MIL) | ~400 | Both sides live, in different banks; sharing would need cross-bank alias headers |
| Font glyphs, end markers | a few | Not worth a header each |

## Evidence

| Gate | Result |
|---|---|
| Art identity against the pre-prune build | **24 removed, exactly these; 3,000 moved with identical pixels**; 1 changed, `JXSPLIT9A`, the known LOAD2 bit bleed (against authored NUJAX10.IMG: 4 wrong pixels before, 2 after) |
| Build | Phase D passes, including SAG coverage once the dead table was gone; the peer Cage-blood guards report "JCBLOOD.TBL aligned" and "JCMK1BLD.TBL anipoints match". Program and video chips fit |
| Attract, 40 shots, against the installed build it replaces (same code, old art) | **40 of 40 pixel-identical** |
| Install | `rom/mk2.zip` and `C:\MAME\roms\mk2.zip`: all 20 chips byte-identical to the tested package |

The build also carries two peers' finished, uncommitted changes that were on
disk when it ran: `bloodfade` (MAINEQU/MKBLOOD, mk2-main-8f) and the Cage
JCSTAB/JCSPLAT SAG sync (JCBLOOD.TBL, JCMK1BLD.TBL, `tools/sync_jc_blood.py`,
`build.py`, mk2-main-5f). The attract A/B compared against their installed
build, so those changes are on both sides. The package it replaced is backed
up in `tmp/dupprune/backup-20260913-173802/`.

[Receipt](dup_art_prune_results.json)
