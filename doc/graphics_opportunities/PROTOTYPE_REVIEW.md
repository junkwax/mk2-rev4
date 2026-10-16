# Independent prototype verification

19 September follow-up: [Kahn fist multipart coverage](KAHN_FIST_REUSE_PROTOTYPE.md#multipart-coverage-follow-up-19-september-2026-pass)
passes in both facings, both before and after pruning: **396/396 paired
screenshots identical**, matching piece traces, zero witness failures.
This uses synthetic animation pointers in private copies of the frozen
September 15 packages, not a rebuild of the current work in progress.
The verification suite passes 16 tests.

Kahn follow-up (13 September): the
[fist reuse prototype](KAHN_FIST_REUSE_PROTOTYPE.md) passes 168 offline
packed-pixel comparisons across both consumers, both facings and clipped
positions. Negative controls expose lost mirroring and an early-flip
placement error. **Runtime A/B passed on 15 September**: portal attack and
fatality from both sides, 99/99 and 137/137 snapshots identical (see that
doc). Art removal still awaits sign-off.

Latest follow-up (13 September): the flip/duplicate scanner now separates
different decode layouts at the same SAG and excludes overlapping storage,
including undecodable inline baby windows. **15 regression tests pass**.
See the [scanner review](FLIPREUSE_PROTOTYPE.md#scanner-follow-up--13-september-2026)
and [receipt](flip_scan_review_results.json). This follow-up changes analysis
tools only; Kahn's 1,729-byte fist reuse remains a prototype candidate.

Review date: 12 September 2026. This review checks the other agent's storage
and floor-skip work before continuing the fast-shadow prototype.

## Confirmed on the current checkout

- BLDXPD packing check passes: 46,142 payload bytes; exact authored images and
  the intended 4/3/2/1-bit controls.
- NOOBPORT packing check passes: 50,778 payload bytes. The separate body lane
  remains at 6 bpp. Further Noob work is deferred as requested; existing work
  was not reverted or extended.
- The STBURST before/after comparison was rerun against
  `tmp/art_before_stburst.json`: **627 moved with identical decoded pixels,
  23 removed, 0 changed**. The source's live `a_burst` lane uses MKST's
  bank-0 records; the removed MKFATAL copy has no named source consumer.
- All six inline SAG guards pass. The global coverage check passes for
  **9,293 exported SAGs across 46 payloads**.
- The floor source guard passes. The captured negative result applies to a
  constant top-row skip, not every possible floor-culling technique.
- Fresh MAME runs with the corrected floor runner reproduce **Tower 54**
  (positive control) and **Wasteland 0**, each at three camera stops:
  [review receipt](floor_skip_review_results.json).

The STBURST MAME verdicts in the earlier receipt are historical evidence;
this review did not rerun those three fatality/victory rigs. Its short-bolt
test did not reach a fight and remains inconclusive. No FBNeo or physical
hardware result is being inferred from MAME.

## Verification-tool defects corrected

| Defect | Correction |
|---|---|
| `sync_inline_sags.py` could write new addresses after recording a hash failure | All proposed edits are held until every site passes. A failed check leaves source untouched. |
| `run_floor_skip_probe.py` ignored `--rom-dir` | The selected ROM is frozen, with an explicit matching `--map` option. |
| Unequal screenshot dimensions could be discarded as if nothing changed | The comparison rejects them. |
| A partial pair of floor runs could yield a result | Require all three captures per side and successful MAME exit. |
| Art-identity reference screening ignored table operands | TBL pointer/alias operands now count as potential references, excluding label definitions. |
| Art reconstruction allowed overlapping/out-of-bounds payloads | Reject either condition before fingerprinting. |

The shared sprite-table reader also now closes files explicitly. Four focused
regression tests pass, covering failed-hash write prevention, selected-ROM/map
freezing, unequal-image rejection and TBL reference handling:

```powershell
python tools/test_graphics_verification.py
```

The art-identity comparison still passes after these changes. Its **109
stale-unreferenced records** remain a heuristic classification, not permission
to delete them: computed-address consumers, nonstandard structures and
unparsed references require a separate reachability audit. Duplicate equality
alone also does not establish whether either copy has a live consumer.

## Follow-up after the visual prototype commits

The other agent completed owned hit light, palette-map rectangles, interlayer
lines and background strips in `fdece73` and `c9a7ae9`. All are still inactive
without their runtime producer/switch. The review continued from those commits
and rebuilt a private ROM; [fresh receipts](graphics_followup_results.json)
record its input hashes and results separately from the earlier reports.

- **Hit light:** lit/control mirror runs pass again: 52 five-refresh lights,
  zero sharer changes, zero unrestored palettes and zero leaked private maps.
  The runner now requires a successful emulator exit as well as its PASS
  marker. A focused regression case verifies that a late emulator failure
  cannot be hidden by that marker; all five verification regression tests pass.
- **Palette-map rectangle:** 32×32 passes with 243/262 recoloured pixels in
  the two armed captures and none after disarming. The source now refuses
  areas above 1,024 pixels before the map walk. Both 27×38 and 64×80 refuse
  all 140 armed requests per enabled mode, with zero changed pixels in every
  paired capture. The original 80×64 overrun remains historical evidence,
  not an accepted workload. The cap bounds work, not total scene time.
- **Strips:** all six modes pass again, including zero-offset equivalence
  and alternating-band reference equality. No new late frames or queue drops
  were reported. These runs have hidden fighters and a parked camera; moving
  fighter occlusion, scrolling and moving background-object velocity remain
  additional cases, rather than consequences of the still-image result.
- **Interlayer lines:** all three boots pass again, with zero off-line pixel
  differences and HUD coverage at row 40. The separate fighter-depth rig was
  not rerun in this review.
- **Kombat Tomb:** the completed six-pair frozen-build receipt is now recorded:
  162 identical paired captures and **43.6% fewer total DMA starts**. A fresh
  Kitana/Scorpion comparison on the newer combined build also passes all 27
  captures and 781 trace rows, with no new late frames.

Rectangle and strip scorers now reject any screenshot that is not a complete
400×254 frame. Build guards, assembly, program/video generation and private
packaging passed; the existing Boxlab freshness warning remains. No shared
MAME ROM installation was changed. Further Noob work remains deferred.

At this review checkpoint, forced process-kill cleanup was still untested;
the interruption follow-up below supersedes that status. The subsequent
[hit-only hook follow-up](HITLIGHT_PROTOTYPE.md#hit-only-hook-follow-up) fixes
the blocked-contact case: the old ROM produced 26 lights on 26 blocked kicks;
the final twelve-run sweep covers Liu Kang, Kitana and Sub-Zero, with **80
blocked contacts and no lights**, plus **156 clean-hit lights** restoring
correctly. See [the retained before/after receipt](hitlight_block_gate_results.json).
FBNeo and physical-board tests remain outstanding for all these effects.

**Continuation, same day:** the two open items on the visual prototypes are
closed on the frozen strips ROM.

- **Strips `--motion`:** visible walking fighters, and a camera scrolling
  442 → 632 → 489, over 15 snapshots. Zero-offset bands equal the ordinary
  entry, and alternating bands equal the shifted references, at every
  snapshot. The same holds with a constructed 1 px/refresh velocity on a
  baklst6 object, which exercises the velocity-once rule.
- **Interlayer fighter-depth rig:** it passes again with the same numbers.

See [STRIPS_PROTOTYPE.md](STRIPS_PROTOTYPE.md#motion-follow-up) and
[PALRECT_PROTOTYPE.md](PALRECT_PROTOTYPE.md).

## Sources and continuation

**Independent palette/combined-build follow-up (2026-09-13):** reconciled the
concurrent `rot2_p`/`DGUTZ2_P` removal with the peer's completed palette and
duplicate-art work. The isolated palette-only map confirms 254 bytes saved:
`rot1_p` moves by 130 bytes, `silo_p` by 254, and `etext` is unchanged. All
18 video/sound chips are identical to the repaired baseline. The current
installed combined package matches all 20 chips of the peer's tested
`tmp/dupprune` package. Reptile's babality against Sub-Zero, Reptile and
Scorpion completes on the first attempt in three independent runs on that
matched combined ROM/map. The newer installation was preserved; the mixed
working-tree build was not used to attribute savings or overwrite it. See
[verification receipt](palette_cleanup_followup_results.json).

**Repair installed (2026-09-13):** repository and installed MAME packages now
match the verified baby-window repair. Both previous packages are backed up;
post-copy checks confirm all three compiled headers and original video-window
hashes. The tested build was promoted unchanged. See
[promotion receipt](baby_window_promotion_results.json).

**Baby-window preservation repaired (2026-09-13):** ROTATE10B/C are restored
in their required sequence. All three historical baby-window hashes match
again; all 14 inline guards pass. Cost: 742 bytes, leaving 45 ROTATE records
removed and approximately 17,010 bytes saved. Art identity finds 137 identical
moves, two restored records and no changed retained art. Build/private package,
ten verifier tests and babality completion for Sub-Zero, Reptile and Scorpion
all pass. The original malformed art remains malformed; this restores its
bytes. See [repair](ROTATE_ART_AUDIT.md#preservation-repaired-2026-09-13)
and [receipts](baby_window_restoration_results.json).

**Post-prune review (2026-09-13):** the other agent completed ROTATE and
broader dead-art pruning in `70b5325`. Historical inline-window analysis
confirms a remaining issue: `SZBABE`/`RPBABE`/`SCBABE` protected windows overlap
removed ROTATE10B/C. Their changed expected hashes do not prove preservation,
even though the original compressed stream was malformed. The audit now
reports these dependencies and fails on missing guarded headers. Ten tests
pass. See [review and unresolved scope](ROTATE_ART_AUDIT.md#review-follow-up-protected-inline-dependencies-2026-09-13).

**ROTATE cost-saving candidate audit (2026-09-13):** the new offline audit
finds 47 records occupying **17,752 packed bytes** without source identifier
references, and protects 40 records named by chunk animation tables from a
blanket unused-family assumption. No art was deleted. Linked/prelinked and
computed references remain to resolve before a deletion prototype. The
flip-reuse next-candidate list now reflects the already-completed mirrored
arms. Eight verifier tests pass; see [audit and limits](ROTATE_ART_AUDIT.md).

**Freeze replacement-light follow-up (2026-09-13):** 14 MAME runs pass,
including six enabled/control replacement pairs and the older-owner-only
regression pair. Each older light is reaped; its replacement saves the frozen
palette, runs five refreshes with exact tint checks, and restores that palette
until natural thaw. Original reference counts return correctly. The
exact-PID `kilall` replacement path is now directly exercised. This extends
the older-owner-only coverage below without changing game code. See
[scope](HITLIGHT_PROTOTYPE.md#freeze-replacement-light-follow-up-2026-09-13)
and [receipts](hitlight_freeze_replacement_results.json).

**Freeze palette takeover follow-up (2026-09-13):** 12 MAME runs pass.
Sub-Zero's real ice-ball input takes palette ownership from six held older
lights across both players and three victim families. Each older light exits
without clobbering the freeze palette or leaking its map/reference; natural
thaw restores the original palette. Replacement hitlight creation is disabled
to isolate the old owner's exit. Earlier exploratory runs allowed a new light
and failed those narrower expectations; they are retained separately. See
[scope](HITLIGHT_PROTOTYPE.md#freeze-palette-takeover-follow-up-2026-09-13)
and [receipts](hitlight_freeze_takeover_results.json).

**Real between-round teardown follow-up (2026-09-13):** 12 MAME runs pass
across both players and three fighter families. Six deliberately held owned
sleepers are reclaimed by the reaper after objects and palette allocations
have been cleared during normal round flow. Every next-round occupied
palette ID/reference-count comparison matches its disabled control. This
closes the specific between-round teardown gap left by the earlier guard
tests below; other transitions, direct `kill` and newer-palette takeover
remain open. Six verifier regression tests pass. See
[scope and procedure](HITLIGHT_PROTOTYPE.md#real-between-round-teardown-follow-up-2026-09-13)
and [retained receipts](hitlight_round_teardown_results.json).

**Round-state guard follow-up (2026-09-13):** 24 additional MAME runs pass
on the same frozen build. Pulsing `f_death` or a non-fighting `gstate`
ended **630 active lights** across both players and three fighter families;
all restored by the next sample with no ownership errors or palette leaks.
The rig restores the guard after one refresh and retains live allocations,
so full teardown remains open. In particular, `murder_myoinit` clears
objects/palettes before removing processes, an order these pulses do not
exercise. See [receipts](hitlight_round_guard_results.json) and
[test scope](HITLIGHT_PROTOTYPE.md#round-state-guard-follow-up-2026-09-13).

**P2 ownership follow-up (2026-09-13):** the same frozen combined ROM/map
passed 18 additional MAME runs, including **318 P2 interruptions** across
Liu Kang, Kitana and Sub-Zero. Every interruption restored by the next sampled
refresh with zero ownership errors or palette-reference leaks. P2 normal-hit
and blocked-contact controls and a P1 normal-hit regression pair also pass.
The runner now supports `--side 2` and freezes its Lua rig with the inputs.
No game-source changes were needed. Full round teardown, newer-palette
takeover and direct `kill`/`kilall` invocation remain open; see
[P2 evidence](hitlight_p2_results.json) and the
[updated scope](HITLIGHT_PROTOTYPE.md#p2-ownership-follow-up-2026-09-13).

**Interruption follow-up on the combined `b1ee461` build:**
[hit-light cleanup](HITLIGHT_PROTOTYPE.md#interruption-cleanup-follow-up)
passed 16 MAME runs, including **312 forced-exit/runtime-disable interruptions**
across three fighter families. All restored by the next sampled refresh,
with zero original-reference or private-map leaks. Ordinary hits and blocked
contacts still pass. The scheduler now calls the ownership-checked helper
from `sucide`, `kill` and `kilall`; only the terminal path and runtime switch
are directly driven by the rig. See [retained receipts](hitlight_interruption_results.json).

The rig now verifies two human players and selected fighter identities and
controls every P1/P2 input, correcting a zero-contact block test that had
left some controls outside its scope. The other agent's ghosts, palette-queue,
flip-reuse and motion follow-ups are retained; the combined build checks pass,
but this interruption sweep is not an independent rerun of every new effect.

The continuation is implemented and measured in the
[Wasteland fast-shadow prototype](WASTELAND_SHADOW_PROTOTYPE.md): all twelve
standard fighters, 162 identical paired captures, 51.5% fewer total DMA starts.

- [STBURST report](STBURST_PROTOTYPE.md) and
  [original receipt](stburst_prototype_results.json).
- [Floor-skip report](FLOOR_SKIP_PROTOTYPE.md) and
  [original measurements](floor_skip_results.json).
- [Inline guard](../../tools/sync_inline_sags.py),
  [art identity](../../tools/art_identity_snapshot.py),
  [floor runner](../../tools/run_floor_skip_probe.py),
  [regression tests](../../tools/test_graphics_verification.py).
