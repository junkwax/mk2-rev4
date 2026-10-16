# Cut Content Candidates

Static archaeology pass for moves, animations, and sprite groups that look
disabled, orphaned, or partially cut while still having code and/or table
coverage in the source tree.

This is not a runtime-verified list. Treat each entry as a revival candidate:
confirm art coverage, confirm current LOAD2/TBL addresses, then test in MAME.

## Highest-confidence coded candidates

| Candidate | Evidence | Current state | Revival notes |
| --- | --- | --- | --- |
| Baraka/Sword Arms spin | `src/MOVES.ASM:1273` has `; jruc death ; disabled Midway's Baraka spin path`; `do_spin` exists at `src/MOVES.ASM:2545`. | In this tree it is already re-enabled through fast block taps and dispatches to `do_spin`. | Good reference for how a Midway-disabled path can be restored. Verify gameplay tuning rather than art coverage. |
| Johnny Cage head-pop fatality | `do_head_pop1` exists at `src/MKDEATH.ASM:1436`; Cage's `db2_table` slot points to it, matching `mk2-src.zip`. | Restored as Cage fatality 2. | Use this as the stock-source baseline for Cage DB2. The custom headhole/brain-rip feature is one separate `do_jc_headhole` route; do not create another brain-rip route. |
| Johnny Cage power punch | `do_jc_pp` is exported in `src/MAINEQU.ASM:404`; `stk_jc_pp` and `r_jc_pp` exist; `a_jc_pp` and all `JCPOWERPUNCH*` wrapper lines are commented at `src/MKJC.ASM:1510-1530`. | Partially coded but animation is commented out, and `do_jc_pp` has no active definition found in this pass. | Needs deeper trace through `JOY.ASM` power-punch hook and likely a new/finished move routine. Art may need LOAD2 coverage if `JCPOWERPUNCH*` is not currently emitted. |
| Cage headhole / brain-rip fatality | [JC headhole source of truth](JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md) documents the active `do_jc_headhole` controller and CAGE10 `DBLO2` attacker lane. | One custom fatality, currently under visual validation. | Use the fixed image-ROM move-art wrappers. REVX is full/off limits and is not a sprite restoration path. |

## Animation/frame leftovers with code wrappers

| Candidate | Evidence | Current state | Revival notes |
| --- | --- | --- | --- |
| Ninja knee extra frames | `src/MKNJ.ASM:1102` says `left over unused frames`; `NJKNEE4`, `NJKNEE5`, `NJKNEE6` are defined at `src/MKNJ.ASM:1107-1109` and emitted in `data/MK4MIL.LOD:147-148`. | Defined and loaded, but `a_njknee` uses only `NJKNEE1`, `NJKNEE2`, `NJKNEE3`. | Easiest visual experiment: append these to the knee animation and test offsets. |
| Cage projectile extra frame | `JCTHROW3` is defined at `src/MKJC.ASM:1289`; active `a_jczap` comments it out at `src/MKJC.ASM:1281`; art is in `data/MK2MIL.LOD:444`. | Loaded but skipped. | Try adding it back between `JCTHROW2` and the zero separator to see whether it was cut for timing or alignment. |
| Cage flying uppercut/bike-kick frame | `JCFLYBO1` is defined at `src/MKJC.ASM:1439`; `a_shoruken` comments it out at `src/MKJC.ASM:1431`; art is in `data/MK2MIL.LOD:457`. | Loaded but skipped. | Candidate for smoothing Cage's rising uppercut/related reaction sequence. |
| Sword Arms elbow extra | `UGELBO4` is defined at `src/MKSA.ASM:848`; `a_saelbow` uses only `UGELBO1-3`. | Loaded but not used by the active elbow animation. | Could be a recovery or impact frame. Compare offsets against `UGELBO3`. |
| Shang Tsung elbow intro frames | `STELBO1` and `STELBO2` are defined at `src/MKST.ASM:866-867`; `a_stelbow` starts at `STELBO3`. | Loaded but skipped. | Likely early wind-up frames. Reinsert carefully because elbow timing affects close combat. |
| Shao Kahn jump frames | `BGJUMP1-3` are defined at `src/MKSK.ASM:254-256`; art is in `data/MK5MIL.LOD:105`. | Defined/loaded, but no active Kahn animation reference was found in this static pass. | Needs boss AI/action trace before wiring. Could be unused jump behavior. |
| Shao Kahn slam frames | `BGSLAM1-6` are defined at `src/MKSK.ASM:384-389`; art is in `data/MK5MIL.LOD:120`. | Defined/loaded, but no active reference was found in this pass. | Likely a cut throw/slam concept. Needs `MKBOSS.ASM` and hit reaction trace. |
| Ninja fatality fat frames | `FATNINJA1` and `FATNINJA5` are defined at `src/MKDIE.ASM:1497-1506`; both are commented out of `a_sc_fat/a_sz_fat/a_rp_fat` at `src/MKDIE.ASM:1486` and `src/MKDIE.ASM:1492`; art is in `data/MK6MIL.LOD:223-226`. | Loaded but skipped in the active ninja fat sequence. | Good candidate for restoring a longer explosion/fat animation. |
| Blood drip splat | `a_drip_splat` exists at `src/MKBLOOD.ASM:1565`; a jump to it is commented at `src/MKBLOOD.ASM:596`. | Animation target exists but is not reached from that commented path. | Needs blood-process trace to see if another path superseded it. |
| Fan opening frames | `fans2`, `fans3`, `fans4` are defined at `src/MKFN.ASM:1243-1245`; `fans2-4` are commented as `fans openning up (too slow)` at `src/MKFN.ASM:1218-1220`. | Frames exist; active fan fly starts later/faster. | Deliberately cut for speed. Useful if we want a slower or more readable fan-open animation. |

## False positives and active paths

| Item | Why it is not a cut candidate |
| --- | --- |
| Raiden dive | `src/MOVES.ASM:2084` has a commented local stub, but the move is active: `scom_rd_dive` dispatches to `do_raiden_dive` at `src/MOVES.ASM:301-305`, implemented at `src/MKPROP.ASM:1474`. |
| Cage ceiling uppercut | Looks like a prototype because of the comment `D,D,U + HP = ceiling uppercut ?`, but it is active in this tree: `src/MOVES.ASM:1428-1431`, implementation at `src/MKPROP.ASM:845`. |
| `RN1BOLT*` wrappers near Raiden stance | There are commented duplicate wrappers at `src/MKRD.ASM:131-144`, but active wrappers exist later at `src/MKRD.ASM:1526-1539`. |
| Generic `jruc death` fallthroughs in `MOVES.ASM` | Most are normal "no special matched, return to death label" exits, not disabled moves. The Baraka/Sword Arms spin line is special because it has an explicit disabled-path comment. |

## Art-only inventories to inspect

These are not proven coded moves, but they are strong places to visually inspect
in WIMP/midway-imgtool:

- `doc/UNUSED_RECORDS.md`: record-count inventory. Top files include `MKBGANI.IMG`, `BLOOD.IMG`, `KAT11.IMG`, `CASTLE.IMG`, `CAGE10.IMG`, `RAIDWALK.IMG`, `NINJAS11.IMG`, and `MKSCORE.IMG`.
- `doc/UNUSED_SPRITES.md`: name-family inventory for IMG files with populated internal names. Search families like `PCUT*`, `RCUT*`, `CASTLE`, and `MKBGANI`.

## Suggested next pass

1. Render or inspect the specific art frames for the high-confidence entries.
2. For each candidate, verify its TBL entries are current after the latest LOAD2 rebuild.
3. Prefer small animation-only experiments first: `NJKNEE4-6`, `JCFLYBO1`, `JCTHROW3`, `UGELBO4`, `STELBO1-2`.
4. Save bigger behavior restorations for separate branches: Cage power punch, Kahn jump/slam, and any alternate Cage head-rip/head-pop routing experiments.
5. Put new normal PIXBLT sprite chunks in a documented fixed image-ROM wrapper
   (`MOVEART1`/`MOVEART2` as capacity permits), never REVX. Read
   `doc/CUSTOM_CONTENT.md` and `doc/ASSET_SPACE_LEDGER.md` before allocating.
