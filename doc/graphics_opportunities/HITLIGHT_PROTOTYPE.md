# Owned-palette hit light

**Status: implemented and validated in MAME, 12 September 2026.** This is
[first prototype](../GRAPHICS_OPPORTUNITIES.md#82-first-prototypes) #6, "one
owned palette lighting/cycle recipe", for opportunity 13 (palette-driven
localized lighting) in [the graphics audit](../GRAPHICS_OPPORTUNITIES.md).
It adds a visual effect rather than saving a budget, so it is **compiled in
but off at run time**: nothing happens unless `f_hitlight` is written.
FBNeo/Fightcade and physical hardware have not been tested.

![Light 1, refreshes 129-138: the struck fighter (right) cools and returns; the attacker never changes](hitlight_strip.png)

## What it does

A five-refresh ice-blue pop on the fighter who has just been hit, done to his
**palette** — no objects, no pixels, no art.

The prototype exists to prove the ownership rule, not the colour. `getfpal`
keys a colour map by the palette's *address*, so every object on one palette
shares one map; tint that map in place and all of them light up. So the hit
fighter's current palette is **copied into a private RAM buffer**, and he is
swapped onto that buffer's address — a new id, so a colour map of his own.
Only that map is ever written, and every write is guarded on "he is still a
live fighter wearing the map allocated for our buffer".

| | |
|---|---|
| Hook | `reaction_start_chores` ([MKREACT.ASM](../../src/MKREACT.ASM)), after common cleanup including `player_normpal`; `blocked_start` bypasses the cosmetic hook |
| Code | `hitlight_start` / `hitlight_proc` / `hl_tint` ([MKFX.ASM](../../src/MKFX.ASM)) |
| Buffers | `hl_pal1`, `hl_pal2` ([RAM.ASM](../../src/RAM.ASM)) — count word + 64 colours each |
| Switches | `hitlight .set 1` compiles it in ([MAINEQU.ASM](../../src/MAINEQU.ASM)); `f_hitlight` enables it |
| Cost per light | one colour map for 5 refreshes, one `palset` per refresh, one process |

The envelope is five rows of per-channel multipliers (/128) plus a blue lift,
rebuilt from the untouched original every refresh, so there is no accumulated
error and the hand-back is exact: the proc swaps him back onto *exactly* the
palette he was wearing, including an alternate such as frozen or shocked.

## Result

Liu Kang mirror match, P2 punching an idle P1 every 30 refreshes, 1,600
measured refreshes, same frozen ROM for both runs.

| Gate (audit #6) | Lit run | Control (`f_hitlight=0`) |
|---|---|---|
| Hits landed | 53 | 53 |
| Lights | **52**, each exactly **5** refreshes, one process | 0 |
| **No unintended sharer change** | **0** changed refreshes of 260 lit | — |
| **Transfer queue bounded** | max depth **2** of 31 | — |
| **Restores on every exit** | **52/52** back on the original id; **0** leaked maps; ≤ 1 private map | 0 private maps ever |
| Colours correct | **208/208** tinted refreshes equal `tint(original, row)` exactly | — |
| First tick | **52/52** exactly *pending* (map untouched, transfer queued) | — |

The first-tick check matters. On the refresh the light starts, `opal` already
names the new map but both transfers only land on the next vblank, so a loose
check reads that as a wrong colour. The rig requires the map to hold *exactly*
what it held a refresh earlier, and the strip shows the displayed frame at
that refresh (rel 131) is the fighter's normal colours — no stale flash.

## The sharer had to be constructed

The obvious sharer does not exist: a mirror match gives P2
`character_palettes_2` (`check_same_character_pal`, [MKGUYS.ASM](../../src/MKGUYS.ASM)),
so two Liu Kangs are on different maps. The rig therefore adds a second
reference to the struck fighter's original map at fight start — an owner as far
as the allocator knows, so the map can never be released or re-let — and
requires its colour RAM to stay bit-identical for every lit refresh. That is a
stricter test than a mirror match would have been.

## Three bugs the rig found before it passed

All three would have shipped as "looks fine in one screenshot":

1. **The buffers were somewhere `palset` refuses.** Declared beside the code,
   they linked at `0x01114xxx`, above `stckst` (`0x010ffff0`), and `palset`
   rejects any source at or above it — silently. Every transfer, `getfpal`'s
   first one included, would have been dropped. Moved to RAM.ASM.
2. **The fighter never got his colours back.** `player_normpal` only restores
   when the *calling* process has `pm_alt_pal` up (`pnorm_check_temp_alt`).
   `player_swpal` from the detached process raised it on *itself*, so every
   later reaction on the player saw it down and did nothing: 1,590 refreshes on
   the private map. Now raw `swpal`, with `pm_alt_pal` raised on the player's
   own process (and taken down only if it was down before).
3. **The envelope ran off the end of its table.** A word `move` sign-extends,
   so the `0ffffh` terminator arrived as `0FFFFFFFFh` and `cmpi 0ffffh` never
   matched. A trace of the process's saved `a11` showed 19 rows instead of 5,
   reading the code after `hl_env` as colour multipliers. Now `jrn`, as
   `fadeproc` does.

## Hit-only hook follow-up

The initial shared hook also lit blocked contacts. The new guarded-contact
rig reproduced this on the previous ROM: **26 blocked high kicks caused 26
lights** with the switch on, versus zero with it off. The rig holds P1 Block
well before P2 starts kicking, requires at least three health reductions and
checks that every reduction occurs while the victim's action is high or low
block. Chip damage is counted as a contact, not mistaken for a clean hit.

`blocked_start_chores` now contains the existing gameplay cleanup. Both hit
and block entries still run it, including palette restoration, slave removal,
facing, movement stop and hit-queue accounting. Only `reaction_start_chores`
then calls `hitlight_start`. Its common return flags are preserved; the block
entry retains the previous zero return condition. No persistent suppression
flag or new RAM allocation is needed.

Final enabled/disabled tests and their frozen input hashes are recorded in
[the hit/block receipt](hitlight_block_gate_results.json). The effect remains
off by default; this change does not enable it for play.

Liu Kang, Kitana and Sub-Zero each passed a hit pair and a guarded-contact
pair: **12 MAME runs on one final ROM/map**. With the effect enabled, **80
blocked contacts produced zero lights**; clean hits produced **156 lights**,
each lasting five refreshes, with zero sharer changes, unrestored palettes
or leaked private maps. Both disabled controls and enabled runs have the same
contact counts for each case. The original failure is retained in the receipt.

Assembly and project guards passed, including branch-range and system-stack
clearance checks; private ROM packaging passed. Five verification regression
tests also pass. The existing Boxlab freshness warning remains. The system
stack guard checks reserved RAM clearance, not every possible call-chain depth.

## Interruption cleanup follow-up

`hitlight_reap` is now called before the scheduler unlinks a light through
`sucide`, `kill` or `kilall`. Allocation clears a cleanup marker before the
process can run; the marker is armed only after the private map is acquired.
The helper uses the sleeping process's saved owner and palette context, and
checks the current player object, player process and private palette before
restoring anything. If another effect has changed the palette, it leaves that
palette alone. It then releases the held original-palette reference.

The original palette is retained with one allocator reference while the light
runs. This keeps restoration from depending on a spare map becoming available;
it adds no palette beyond the one private map the light already used. Normal
completion and interrupted completion both release the reference. Turning
`f_hitlight` off now ends active lights at their next process wakeup.

The forced-exit rig bypasses `hlp_done` by replacing the sleeping light's wake
PC with `sucide` after its second observed lit refresh. It does not call the
cleanup helper directly. On the previous ROM, the private palette remained
visible for up to **19 refreshes**; the test failed. The new rig also checks
that the original palette's reference count returns to its pre-light value.
See [interruption receipts](hitlight_interruption_results.json).

The combined build at `b1ee461` passed **16 MAME runs**: forced termination
and runtime-disable pairs for Liu Kang, Kitana and Sub-Zero, plus ordinary-hit
and blocked-contact pairs. **312 interrupted lights** returned by the next
sampled refresh, with zero late restores, private-map leaks, sharer changes
or retained-original-reference leaks. Normal lights still last five refreshes;
the held-block control records 26 contacts with no light. These runs target P1.

The build, assembly guards and private packaging passed, as did five graphics
verification regression tests. The existing Boxlab export-freshness warning
remains. No shared ROM installation changed, and the effect remains off by
default.

An unrelated block-test failure exposed incomplete input isolation: some
player controls remained outside the rig, and two-human status was not
verified. The rig now sets both players active at selection, verifies their
identities, and controls every P1/P2 input field. On the same frozen ROM this
changed a zero-contact failed run into 26 verified blocked contacts with no
lights. The zero-contact run remains a failure, not evidence for the gate.

## P2 ownership follow-up (2026-09-13)

The same frozen combined ROM/map passed **18 additional MAME runs**: P2
forced-terminal and runtime-disable pairs for Liu Kang, Kitana and Sub-Zero,
P2 ordinary-hit and held-block pairs, and a P1 ordinary-hit regression pair.
All **318 P2 interruptions** restored by the next sampled refresh, with zero
wrong-owner observations, sharer changes, private-map leaks or retained
original references. P2 ordinary lights lasted five refreshes; 27 blocked
contacts per switch state produced no light. P1 normal behavior still passes.
See [P2 receipts and input hashes](hitlight_p2_results.json).

`--side 2` selects P2 as the recipient while keeping character-selection inputs
physically indexed. The rig checks that each lit recipient owns its exact
`hl_pal1`/`hl_pal2` buffer and has exactly one matching light process. This
exercises P2's mirror-match alternate palette, not merely a second run of the
P1 route. Each run now freezes its Lua rig alongside the ROM/map. No game-source
change or rebuild was needed; the effect remains off by default.

## Round-state guard follow-up (2026-09-13)

The same frozen ROM/map passed **24 additional MAME runs** covering both
players and Liu Kang, Kitana and Sub-Zero. **630 interrupted lights** restored
by the next sampled refresh, with zero ownership errors, sharer changes,
private-map leaks or retained original references. Each case includes an
effect-disabled control. See [guard receipts](hitlight_round_guard_results.json).

The new `--interrupt death` and `--interrupt state` modes pulse `f_death=1`
or `gstate=gs_amode` (1) after the second observed lit refresh. They restore
the previous value at the next sample, including on cleanup failure. Both
exercise `hl_live` while objects and palette allocations remain live. They
do not run the round transition or clear the palette table. No game-source
change or rebuild was required. Five graphics verification regression tests
also pass.

## Real between-round teardown follow-up (2026-09-13)

**12 MAME runs pass** on the same frozen combined ROM/map: enabled/control
pairs for P1 and P2 Liu Kang, Kitana and Sub-Zero. After two ordinary lights,
the rig holds the third owned light asleep (`psleep=0x7fff`), sets the
recipient's health to zero, releases all controls, and lets the game complete
its normal round transition. It does not call cleanup routines or clear
object/palette tables itself.

All **six held sleepers** reached `hitlight_reap` with both player-object
pointers already zero and their private map no longer allocated. A write tap
observes the ownership marker being cleared and checks that the CPU is within
the first 64 bytes of the exported reaper entry. This exercises the real
`murder_myoinit`/`oinit`/`murder` masked sweep after allocation clear.

Each run reaches the next fighting round and observes it for 240 refreshes;
from refresh 60 onward there are no live private maps, hitlight processes or
invalid fighter palette allocations. Every enabled/control pair has exactly
matching occupied palette IDs and reference counts at the end. The control
ends its round at a fixed frame, so these are allocation comparisons, not
identically timed input replays. See [teardown receipts](hitlight_round_teardown_results.json).

`--interrupt round` reproduces this case. An initial provenance assertion
referenced the unexported local `hlr_exit` label and failed inside the tap;
that failed harness run is retained separately. The final runs use the
exported entry and bounded PC check. Six verification regression tests pass,
including rejection of paired palette-count mismatches. No game-code change
or rebuild was needed; the effect remains off by default.

## Freeze palette takeover follow-up (2026-09-13)

**12 MAME runs pass** on the same frozen ROM/map: Sub-Zero attacks P1/P2
Liu Kang, Kitana and Sub-Zero, with an effect-disabled control per case.
The rig holds the third owned light asleep, disables creation of new lights,
and enters the stock down/forward/LP ice-ball input. No palette allocation or
fighter reaction is injected by the rig.

At `act_frozen` with the expected stock frozen palette, the rig verifies that
the held process is still armed and retains its original saved palette,
then wakes it. All **six older lights** exit by the next sample without
replacing the newer palette or retaining a private map. Across **954 enabled
frozen samples**, palette identity remains correct; after one transfer
refresh, every frozen colour equals the stock palette data. Natural thaw
restores the original palette, and its reference count matches the pre-light
value 60 refreshes later. See [takeover receipts](hitlight_freeze_takeover_results.json).

The initial experiment left new hitlights enabled. `r_ice` calls reaction
chores, which kill the older light and allocate a replacement, often at the
same process address. That new light briefly tints the frozen palette. Those
runs failed the older-owner-only expectations and remain excluded; a process
address alone cannot establish ownership continuity. The final rig suppresses
replacement lights and also checks the armed marker and saved original
palette. This isolates the older process's ownership-loss exit, with the
runtime switch disabled. Replacement-light behavior is covered separately below.

Reproduce with `--interrupt freeze --char 1`, `4` or `8`, and `--side 1` or
`2`. The attacker is always Sub-Zero in this mode. No game-code fix or rebuild
was needed; six verifier regression tests pass.

## Freeze replacement-light follow-up (2026-09-13)

**14 MAME runs pass** with the same frozen ROM/map: six enabled/control
pairs for P1/P2 Liu Kang, Kitana and Sub-Zero victims, plus the previous
older-owner-only regression pair. The new `--interrupt freeze-replace` mode
keeps hitlights enabled while the ice ball hits the held-light recipient.

All six older lights are reclaimed through the reaper's marker-clear path.
The replacement process must save the **frozen palette** as its original,
own its player's private buffer, and run exactly five observed refreshes.
All **24 post-pending envelope samples** match the expected tint calculation
from the stock frozen colours. After the light ends, the stock frozen
palette remains intact until natural thaw; the original fighter palette and
its reference count are restored afterward. No process or private-map leak
is observed. See [replacement receipts](hitlight_freeze_replacement_results.json).

This also drives `hitlight_start`'s exact-PID `kilall` replacement path with
an armed older light. It resolves the test expectation behind the earlier
failed experiments: a newly created light may tint the freeze palette, but
must restore that palette rather than the pre-freeze fighter palette.
No game-code change or rebuild was needed. Six verifier regression tests pass.
The runner rejects block/interruption combinations and unsupported freeze
victim indices before launching MAME.

## On by default (15 September 2026)

The user chose to make it a real feature. POWERUP (MKINIT.ASM) now sets
`f_hitlight` to 1 right after `clscrach`, under `.if hitlight`; writing 0 still
turns it off and ends any light in progress. `tools/run_hitlight_test.py` is
unaffected: it writes its own `HL_ENABLE` value at fight start, so the negative
control still runs with the light off.

**Real game flow, not a punch loop.** `tools/hitlight_watch.lua` rides along an
existing driver rig, using the path redirect from `fatality_budget_wrap.lua`,
and checks every refresh:

- no fighter is lit for more than 12 refreshes in a row;
- no colour map is held for, and no fighter wears, `hl_pal1`/`hl_pal2` while
  no `hitlight_proc` is alive;
- no `hitlight_proc` (011eh/011fh) lives more than 3 refreshes outside
  `gs_fighting`.

A run passes only if lights were seen to start. The runner is
`tmp/hitlight/run_watch.py`: private MAME dirs, 3 at a time, against a frozen
root that holds the drivers.

| Driver | Flow | Runs | Lights | Violations |
|---|---|---:|---:|---:|
| `buyin_continue_probe.lua` | 1P loss → round/match end → buy-in (gstate 3) → START → back into a fight | 1 | 45 | 0 |
| `kahn_ladder_test.lua` | drone vs Kahn on his Arena, round and match ends (Liu Kang, Raiden) | 2 | 10, 21 | 0 |
| `battle_stability_sweep.lua` | all 27 battles: every stage, Raiden's shocks on Jax, Jade/Kahn/Kintaro/Smoke/Noob as CPU | 27 | 1-11 each | 0 |

`f_hitlight` read 1 at the first fight of every run, so the ROM's default
works. All 27 sweep battles also passed the sweep's own crash and camera
verdicts on this ROM.

**One driver crashed, and it is not the hit light.** The Liu Kang ladder match
corrupts RAM in round 2 at frame 2397 (gstate 2 → 9F9Fh, and the same write
turns `f_hitlight` into 29642). No light, private map or light process was
alive then. It crashes on the same frame with the same state on the build
before this change (hit light off, 0 lights) and on the pre-session build
from 12:02 that day. It is the known drone-vs-drone ladder fault
([Kung Lao ladder flake](../../doc/AI_DRONE.md) is the same family: the ladder
drives the human side as a drone, which the game does not support). The
Raiden ladder match is clean.

- The guarded-contact follow-up exercises held standing block against high
  kicks; it is not a full sweep of projectile blocks, crouching blocks,
  bosses, perfect-block timing or custom reactions.
- The rig covers the scheduler terminal path, runtime switch, synthetic
  round-state guards and the real between-round teardown sweep. Direct
  `kill`, other `kilall` masks, match-end/buy-in/selection transitions,
  repeated transition stress and other palette-takeover effects remain
  separate cases. Freeze takeover is covered both with replacement lights
  disabled and with the normal replacement-light path enabled.
- MAME resolves palettes once per frame; the one-refresh pending state is judged
  from MAME's display only.

The real teardown test covers a different allocation order:
`murder_myoinit` calls `oinit` before `murder` (`MKUTIL.ASM`), and `oinit`
clears player-object pointers and calls `clrpal` (`MKDISP.ASM`). The later
`kilall` therefore encounters cleanup contexts whose objects/maps have already
been cleared. The held-sleeper test covers this order and the next round's
allocations; a guard pulse alone does not.

## Reproduce

```powershell
python build.py --asm-only; python makerom.py; python makevrom.py
python mamerom.py --no-install --output tmp/hitlight/rom/mk2.zip
Copy-Item src/mk2.map tmp/hitlight/mk2.map
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --block
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --interrupt terminate
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --interrupt disable
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --side 2 --char 4 --interrupt terminate
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --side 2 --char 4 --interrupt death
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --side 2 --char 4 --interrupt state
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --side 2 --char 4 --interrupt round
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --side 2 --char 4 --interrupt freeze
python tools/run_hitlight_test.py --rom-dir tmp/hitlight/rom --map tmp/hitlight/mk2.map --side 2 --char 4 --interrupt freeze-replace
python tools/hitlight_strip.py tmp/hitlight/tests/run-XXXX
```

Verify the package by content, not timestamps: DOSBox stamps the linker's files
with its own clock, several seconds ahead of the host.

## Files and evidence

- [Recorded results](hitlight_results.json) and [the strip](hitlight_strip.png).
- [Rig](../../tools/hitlight_test.lua), [runner](../../tools/run_hitlight_test.py),
  [strip builder](../../tools/hitlight_strip.py).
- `paltrans_start`/`paltrans_end` are now exported ([MAINEQU.ASM](../../src/MAINEQU.ASM))
  so rigs can read the palette transfer queue's depth.
