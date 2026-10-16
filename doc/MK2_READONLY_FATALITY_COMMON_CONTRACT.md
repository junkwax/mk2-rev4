# MK2 Readonly Fatality Contract

`../mk2-readonly/mk2-main` is the behavioral source of truth for fatality
work. Before changing a fatality, identify the closest stock controller there
and copy its *architecture*, not merely its final pose or a preview project.

This document separates rules that are actually shared by stock MK2 from
things that vary deliberately between fatalities. That distinction is
mandatory: a custom fatality must not acquire extra blood, repeated frames,
coordinate offsets, or an effect lifetime merely because a different stock
fatality happens to use them.

For the custom Johnny Cage headhole / brain-rip fatality, also read
`doc/JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md`. Its CAGE10 `DBLO2` table is the
authoritative custom-attacker timing source; this document supplies the stock
runtime contract around it.

## Source hierarchy

Use sources in this order:

1. **Behavior and engine semantics:** `mk2-readonly/mk2-main/src/`.
   Compare stock controller code, process helpers, palette handling, and
   effect ownership there.
2. **Unique custom art that does not exist in readonly:** inspect the actual
   source asset and its decoded sequence. For Cage headhole that is
   `data/CAGE10.IMG`, sequence `DBLO2`.
3. **Current asset placement:** use `doc/CUSTOM_CONTENT.md` and
   `doc/ASSET_SPACE_LEDGER.md`. Normal PIXBLT sprites stay in the fixed
   video-ROM wrappers; REVX is locked and off limits.

`data/*.WVP` files are custom IMGTOOL/World View previews. They are never
authoritative for stock behavior, source frame ticks, player placement,
palettes, or runtime process wiring.

## What stock table fatalities truly share

These are the common contracts evidenced by the readonly `db1_table` and
`db2_table` controller routes (`src/MKDEATH.ASM:29-55`).

| Contract | Readonly evidence | Required implication |
|---|---|---|
| Common start | Every stock table controller enters through `init_death_blow` (`MKDEATH.ASM:2660-2681`). | Start a normal fatality through the standard controller path; do not directly begin a sprite loop from input code. |
| Attacker baseline | `init_death_blow` calls `init_special`; it stops/grounds/faces the attacker, restores the normal palette, sets special state, disables buttons, and puts the attacker in front (`MOVES.ASM:4089-4104`). | Treat this as the baseline state. Add later lineup or palette changes only when the selected fatality needs them. |
| Input safety gate | The common fatality transfer checks Finish Him state, concurrent fatality state, victim state/airborne state, violence settings, and distance (`MOVES.ASM:3873-3935`). | Keep the normal fatality transfer/gate in the input route. |
| Process ownership | `takeover_him` stops the victim, disables input, clears invisibility, resets palette, removes its slave, marks reacting, and fast-transfers the existing victim process (`MKUTIL.ASM:3141-3175`). | When the victim has an independent reaction, transfer the victim process; do not try to run both player bodies as attacker-owned props. |
| Cooperative controller stack | `jsrp` pushes a continuation on the process stack and `retp` restores it (`MACROS.HDR:355-386`); stock fatality animation helpers are entered with `jsrp mframew`. | Any helper that can yield through `sleep` or `prcslp` must be entered with `jsrp` and return with `retp`. A normal `callr` continuation cannot safely span a scheduler yield. |
| Completion handshake | `death_blow_complete` clears the global fatality state; the match flow waits for that state (`MKDEATH.ASM:2699-2712`, `MAIN.ASM:1184-1193`). | Call completion exactly once at the intended gameplay-release point. A final image alone does not finish a fatality. |

## What is deliberately not universal

Do not turn any item below into boilerplate.

| Topic | Readonly evidence | Rule for new work |
|---|---|---|
| Per-frame ticks | `mframew` applies one caller delay; `ani_nosleep` suppresses it (`MKUTIL.ASM:1266-1283`, `1178-1191`). Controllers also use direct `sleep` stages. | Use the chosen source’s authored cadence. Repeated labels are valid only where the source script repeats them. |
| Dual-object timing | `double_mframew` drives two objects with one cadence; `mframew_him` switches context to the victim (`MKUTIL.ASM:3079-3137`, `3047-3054`). | Synchronize only objects that genuinely share a cadence. Separate effects get separate processes. |
| Variable step timing | The readonly engine has `mframe_a0`, a `[frame, tick]` pair driver (`MKUTIL.ASM:1385-1395`), although stock controllers do not call it. | A custom sequence with directly sourced unequal ticks may use this primitive rather than duplicating frames or sampling a preview timeline. |
| Distance and lineup | The common gate rejects a target that is too far away; it does not place the target (`MOVES.ASM:3873-3879`). Cage torso rip then uses `match_him_with_me_f`, while Kitana fan decap does not (`MKDEATH.ASM:2143-2150`, `247-271`). | Add matching, offsets, edge handling, or no-flip only when the selected source/art proves it is necessary. |
| Blood | `create_blood_proc` selects a worker by effect ID and respects no-blood mode (`MKBLOOD.ASM:28-66`). Decap uses selector `0x0a`; torso rip uses `7`; impale uses `8`; split uses `9`. | Pick a blood worker only if its art, anchor, count, and lifetime fit the fatality. Blood is not automatic initialization. |
| Z order and palette | `init_special` only gives the initial attacker baseline. Shared decap later changes victim palette and ordering (`MKCANNED.ASM:409-445`). | Define layer and palette per lane. Do not copy an entire object flags word or assume a table palette field is enough. |
| Persistence and victory | Decap head/body workers persist after the attacker calls completion; Reptile has a post-completion tail; some fatalities wait instead of going straight to victory. | Decide intentionally which objects die, hold, or survive victory. Completion and cleanup are separate decisions. |

## Readonly comparison matrix

Use the closest stock architecture as a starting point, then document each
intentional difference.

| Stock fatality | Attacker timing | Victim/effect design | Placement / exit lesson |
|---|---|---|---|
| Kitana F2 fan decap | First pose, `sleep 0x30`, `mframew 4`, then another `mframew 4` and recovery pause (`MKDEATH.ASM:247-271`). `ani_nosleep` marks the cut frame in `a_fan_swipe` (`MKFN.ASM:1758-1783`). | `takeover_him_sr(decap_fall)` creates the victim body, one head worker, and two decap-blood batches. | No bespoke controller XY correction. It completes then enters victory while victim effects persist. |
| Cage stock head-pop | Fixed cadence through `animate_a9`; victim falls through the shared decap route (`MKDEATH.ASM:1436-1503`). | Same decap head/blood architecture as fan decap. | Good completion pattern; wrong visual recipe for headhole because it detaches the head. |
| Cage torso rip | Attacker `mframew`, victim `mframew_him`, then `double_mframew` (`MKDEATH.ASM:2138-2227`). | Blood selector `7`, plus detached body objects. | Explicit `match_him_with_me_f` is justified by contact art. |
| Kung Lao split | Attacker and swipe object use `double_mframew` (`MKDEATH.ASM:1619-1669`). | Victim owns split-body/blood work (`r_split_in_2`). | Align a separately created effect with `match_ani_points`; do not put it in attacker frames. |
| Baraka impale | Mixes attacker, victim, and synchronized stages (`MKDEATH.ASM:2376-2461`). | Victim uses bloody palette and blood selector `8`. | Has special edge/behind/lineup logic; it is not global fatality boilerplate. |
| Reptile tongue | Mixes `mframew`, `double_mframew`, and a custom two-tick loop (`MKDEATH.ASM:1890-2099`). | Owns a temporary head/tongue composition instead of generic decap head logic. | Completion precedes a lingering visual/audio tail. |

## Asset and runtime lanes

Model every fatality as independently owned lanes:

```text
attacker controller process
  +-- attacker animation/timing
  +-- victim player process, transferred to a reaction routine when needed
  +-- transient effect workers (blood, hit, splash, sound timing)
  `-- terminal workers (head, body, prop) only when the design needs them
```

Each spawned worker must state all of the following in source comments or its
call site:

- the owner/anchor object or process it receives;
- its palette and Z layer;
- its start boundary relative to the attacker source sequence;
- whether it is transient (`die`) or persistent (`wait_forever`);
- why its PID cannot collide with another active lane.

`create` passes saved registers into the new process; it does not make an
effect inherit a semantically correct victim anchor by magic. The readonly
decap head explicitly receives the victim pointer in `pa10`
(`MKCANNED.ASM:409-417`). Follow that level of explicitness.

## Required review checklist

Before accepting a fatality change, verify all of the following:

1. **Source selection:** named closest readonly controller(s), exact files,
   and documented intentional differences.
2. **Input/dispatch:** standard Finish-Him gate, correct F1/F2 table entry,
   one controller route, and no duplicate fatality implementation.
3. **Attacker sequence:** source frame order and ticks are explicit. Count
   each intended image reference; do not create timing holds by duplicating
   images unless the source animation itself repeats them.
4. **Yielding controller:** every helper that can sleep is called via `jsrp`
   and returns with `retp`; use `callr` only for a routine that cannot yield.
5. **Victim ownership:** existing victim process is transferred before its
   reaction. Companion effects have explicit anchors.
6. **Spacing and facing:** baseline from `init_special`; any matching,
   offset, forced flip, or edge handling cites source/art evidence.
7. **Blood/effects:** chosen effect IDs and count are intentional; no generic
   decap lane is accidentally inherited by a non-decap fatality.
8. **Palette/Z:** table headers, runtime palette transition, flip behavior,
   and draw order are verified on both screen sides.
9. **Lifetime:** each visual has a finite cleanup or an intentional terminal
   hold; completion occurs once and at the designed game-flow boundary.
10. **Assets:** normal sprites remain in a documented video-ROM wrapper; no
   `.WVP` or generated artifact is used as source; no normal sprite goes to
   REVX.
11. **Regression:** run a real fatality through its final hold/victory on both
    sides and with representative victim families; inspect frame order,
    palette, layering, and final process state.

## Cage headhole application

The current Cage headhole / brain-rip is one custom fatality, not a second
head-rip route. Its attacker lane is one pass through CAGE10 `DBLO2`:

`JC2DEATHBLO1`, `JC2DEATHBLO2`, `JC2DEATHBLO3`, `JCHIPUNCH3`,
`JCHIPUNCH2`, `JC2DEATHBLO4`, `JC2DEATHBLO5`, `JC2DEATHBLO6`,
`JC2DEATHBLO7`, `JC2DEATHBLO8`, `JC2DEATHBLO9`, `JC2DEATHBLO10`

with ticks `6, 1, 1, 10, 1, 1, 1, 1, 10, 1, 1, 10`. The sequence is encoded
once as `[frame, tick]` pairs in `a_jc_headhole` and driven by
`jc_headhole_pairs`, a counted local source-equivalent of readonly
`mframe_a0` (the utility label itself is not exported). Because that driver
yields between pairs, it is entered with `jsrp` and returns with `retp`.
The controller plays 3 pairs, hands the victim off with `takeover_him` at
the authored `JCHIPUNCH3` contact boundary, then plays the remaining 9.

The victim reaction (`jc_headhole_fall`) is the stock `decap_fall` contract
with the composite `a_headhole_fall` art at anitab1[`40h`]: the stock decap
leg/torso multipart frames with the character's head-with-hole record
appended as one more part, so the head inherits body position, mirroring,
z-order, and the runtime bloody palette by construction. There is no
detached-head worker, no decap neck-blood batch, and no companion prop
lanes. `BRAIN.IMG`, the KHEART lane, and all overlay/prop-process code are
retired. See `doc/JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md`.
