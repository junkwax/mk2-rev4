# THE DEAD POOL — Boon's acid drop, and the rig that measures it

Ed Boon hangs on the first hook over the pool (`hanger_initab[0]`, world x
**573**, `ed_start_y` = **20**), and he is the only hanger on a **clock**
trigger: `hp_hang` (`src/MKHANG.ASM`) fires `hp_drop_begin` the first tick the
round clock reads `ed_drop_at_clock` (95) or lower — not Finish Him, not the
per-hanger `hanger_drop_delays` autodrop, which is 0 for him.

The whole thing is one long process with no verdict of its own, so the rig
measures it from the **outside** — `hp_body_ptr[0]` plus a walk of
`objlst`/`objlst2`/`objlst3` — and segments it into the beats the ROM actually
walks.

## The beats, and what each one is measured against

| Beat | What the ROM does | Budget (ticks) |
|------|-------------------|----------------|
| `hang` | body parked at `ed_start_y` on the hook, chain above it | — |
| `trigger` | `hp_drop_busy` 0→1, `hp_dropped[0]` latches 1 | clock ≤ 95 |
| `fall` | `oypos += ed_drop_step` (3) every `drop_ticks` (4); one 20-px band eaten as each breaches the surface | **224** |
| `submerge` | fall loop exits at `acid_body_hide_y` = `ed_acid_under_y` (188); multipart body blanked | — |
| `splash` | `acidsplash1a` + `hanger_splash_proc` | **80** (`sloop 050h`) |
| `simmer` | `simmer_fx_proc` | **300** (`acid_simmer_wait`) |
| `prerise` | three bubbles — only when `hanger_fx_enable` is 1 | **80**, else 0 |
| `rise` | DEDHANG skeleton, six bands revealed cumulatively, from `acid_rise_start` (192) up to `ed_start_y` at `rise_step` (**3**) every `rise_ticks` (4) | **232** |
| `done` | `hp_drop_busy` 1→0, skeleton parked, `hp_hold_acid` | — |

Total budget as built: **836 ticks ≈ 15.3 s** after the trigger — a ~4 s sink
and a ~4 s rise around the splash and simmer.

**Three lines, not one.** With the body cut into six 20-px bands it does not
stop at the surface, it sinks *through* it, so `ed_crossline_y` (76, his feet
touch — where the acid sizzle fires and where the chain plants) and
`ed_acid_under_y` (188 = 76 + the 112-row body, his head goes under — where the
fall ends and the last band is gone) are 112 rows apart. They used to be the
same number. The chain keeps `acid_pull_line_y`; it hangs in air, it does not
sink.

**Sound:** the acid sizzle is `UNUSED_AUDIO.md`'s reserved `ACID` (12,644 B,
2.80 s, calls 268-270 = `010ch`), which had no `triple_sndtab` entry since the
leak. It is index **`$10e`**, `sp_splash|153`, fired once from `hp_fall_lp` on
the tick his feet break the surface — detected from `a9` alone by asking whether
the previous step was still above the line, so it needs no flag and cannot
double-fire — and left to run under the whole sink.

**Every one of those numbers is read out of `src/MKHANG.ASM` at run time**, not
inherited — the rig parses the `.equ` block and `hanger_initab`'s first
`.word` pair, so retuning an equate retunes the rig instead of breaking it.
The one hard-coded number is the `sloop 050h` splash hold, which is not an
equate.

## Running it

```powershell
.\tools\run_deadpool_boon_drop_test.ps1                 # natural clock, ~4s into the round
.\tools\run_deadpool_boon_drop_test.ps1 -ClockJump      # slam the clock to the trigger
.\tools\run_deadpool_boon_drop_test.ps1 -Trace          # per-tick trace
.\tools\run_deadpool_boon_drop_test.ps1 -Throttle       # real speed, to judge the FEEL
```

The rig forces the stage and the character select and **nothing else** — it
never writes into the drop sequence, so what it measures is what the ROM does.
Two humans, both idle, so the round runs its clock down without interference.

Source-built sets trip MAME's CRC warning and it parks there at ~0 CPU, so the
launcher posts Enter/Space until the Lua writes `ready.flag` — the same
pattern as `run_shang_soul_escape_test.ps1`. A missing ready flag means MAME
never ran frames, which is a different failure from a failed check.

Output: `CHECK <PASS|FAIL|SKIP> <name>` per beat, `BEATS`/`BUDGET` timelines,
`MEASURE` lines for the things that are observations rather than assertions,
and one `RESULT` line. Run dir under `tools/screens/deadpool_boon_drop/`.

### The probes it reads

`hp_dbg_where` and `hp_dbg_beat` are already `.global` in MKHANG and the rig
leans on both:

- `hp_dbg_beat` is the hang loop's tick counter. **Standing still means the
  hang loop is not running at all** — which is a completely different problem
  from a gate saying no.
- `hp_dbg_where` is the breadcrumb through the gate chain: `1` hang-loop top,
  `2` past the eligibility table, `3` at the clock compare, `10`/`11` setup,
  `100+n` "the index resolved to n".

It also walks the `active` process list, because a hang loop that never ticks
is either a stuck process or a dead one, and only the process list can tell
those apart.

## The bug it found: a sprite pointer in a12

**`hanger_proc` parked the TINCHAIN4 connector in `a12`, which is the process
stack pointer.** Its own header said so - "TINCHAIN4 (a12)".

The consequence was total and silent. `prcd2` (MPROC.ASM) sanity-checks every
process context it restores, and a12 pointing into the object area fails its
"process stack inside the proc block" bound, so it dropped `hanger_proc` via
`sucide` on the process's **very first wake, every single time**. The hangers
hung there and nothing ever happened - no drop, and the chain/hook sat at
whatever coordinates setup left them at, because `hp_update_chain` only runs
inside the hang loop. Without that guard it would have been scribbling on RAM
through `pushp` instead, so the guard converted a memory-corrupting bug into a
no-op.

The connector now lives in `hp_conn_ptr[index]`, a per-hanger `.bss` slot read
back exactly the way `hp_body_ptr` already was, and `hp_update_chain` keeps it
in **a5** for the duration. Only a7-a12 survive a sleep and a12 is not a
general-purpose register, so there was never a spare one - the slot is the
answer, not a different register.

### How the rig got there

Worth recording, because each step ruled out a whole class:

1. `hp_dbg_beat` never left 0 while `hp_dbg_where` reached 100 - the process
   finished setup and never executed one instruction past its first sleep.
2. A tick-by-tick census of the `active` list: 16 processes at frame 714
   including pid 6, 15 at 715, **and nothing else changed**. Not a sweep - a
   single targeted reclaim. Its own six `pid_edpool_fx` children, created
   moments earlier, all survived.
3. The record was on the `free` list with `procid` still 6 - reclaimed, not
   renamed by an `xferprc`.
4. A `kilwho` probe in `kilall` (temporary, `kilwho` in SYSEQU.ASM) recorded
   **zero** hits on pid 6, which ruled out `dallprc`, `killit` and `murder`.
5. A matching probe in `sucide` caught it: one hit, a7 inside MKHANG.
6. Naming `prcd2`'s three guards said which one: `a12 BELOW the proc block`,
   with a12 = `0x010793d0` - an object pointer.

`sleep` vs `sloop` was a red herring, though `hp_hang` is a `sloop` now like
every other wait in the file.

## What the rig measures now

`RESULT PASS pass=20 fail=0 skip=1`, with the sequence running end to end:

```
BEATS hang=810 trigger=942 submerge=1162 splash=1162 skel=1542 rise=1546
      rise_done=1774 done=1774
fall_rate        220 ticks, budget 224 (168px / 3px per 4 ticks)
strips_cut_progressively   hp_lower_strips 6 -> 1
rise_rate        228 ticks, budget 232 (172px / 3px per 4 ticks)
rise_monotonic   0 frames went back down
```

The one SKIP is `prerise_bubbles`, because `hanger_fx_enable` is 0 in this
build - the rig says so rather than pretending.

`hp_lower_strips`, `hp_skel_visible` and `hp_splash_x` are `.global` now. That
matters more than it sounds: **a multipart object carries no frame SAG in
`osag`**, so walking the object lists cannot see the body or the skeleton at all
(both read `art=none` in the trace while plainly on screen). Those three flags
are the only honest signal for the band cut and for whether the bones are
actually inserted. The band bookkeeping also moved out of `hp_strip_fx` into
`hp_strip_note`, because it had been sitting inside `.if hanger_fx_enable` - so
with the FX off the count never moved and nothing could tell whether the
band-by-band cut worked.

## Where they hang: the order photo, and what the camera can see

**The nine hangers are placed off the reference sheet**, not off the camera.
The sheet's row of bodies spans 0..426 px, and that maps straight onto the
acid's world x **195..947**, so the bodies span the whole pool the way the
sheet spans the page. Left to right the sheet reads Geo, Mark, Sal, an empty
hook, Steve, John, Eric, **Ed** (~340 -> world **767**) and **Tony** (~405 ->
**892**). `hanger_initab` (MKHANG.ASM) holds the pairs; x is the body's LEFT
edge, because a hanger's `oxpos` is its top-left anchor.

That placement has a consequence worth stating plainly: **most of them are off
screen most of the time.** With both fighters idle the Dead Pool camera parks
at `worldtlx = 373`, showing world x **373..773**, so Ed at 767 is at the right
edge of the neutral framing and Tony at 892 is not in it at all. The camera has
to travel. `hanger_coords[i].x` is written straight into `oxpos` and the pool's
back plane `DPUL5BMOD` is `baklst1` at scroll rate `020000h` - the same 1.0x
the object list runs at - so a hanger's x and a fighter's `oxpos` are the same
number with no parallax correction.

Ed sat at **573** while he was the only body, which is the centre of that
neutral window and the centre of the acid, and every measurement the rig took
was of a sequence framed for free. It is not framed for free any more, so the
rig pulls the two idle fighters over to whichever hanger it is watching
(`pin_fighters_at`, `-NoPinCam` / `DP_PIN_CAM=0` turns it off) rather than
writing `worldtlx`, which BGND recomputes from the fighters anyway. Where they
go took three tries, each one visible in the filmstrip:

- **either side of his column** - the camera got there (worldtlx 608) and the
  fighters stood in front of the whole drop;
- **both to his left** - the camera centres between them and stopped at 498,
  leaving him 6px from the right border and entirely off screen, and
  `body_on_screen` PASSED, because it only tested his left edge;
- **both to his right** (x+55, x+100) - the camera runs to 695 and he hangs at
  screen ~197 with nothing in front of him. `body_on_screen` now needs his
  whole body inside the window.

```
MEASURE camera worldtlx 373..695 -> screen centre world x 573..895 (ed_x=892, ...)
CHECK PASS body_on_screen      ed_x=892, camera showed world x 373..1095
CHECK PASS body_over_the_acid  ed_x=892, acid 195..947 with 30px margin -> safe 225..917
```

## Three bodies a match, one per zone

**The pool hangs THREE of its nine bodies, and picks a different three when a
match starts.** All nine at once was a wall of bodies, and it was the same
wall every match. `hp_pick_lineup` (MKHANG.ASM, called from `create_hangers`)
narrows `hanger_acid_live` down to three in `hp_live_now`, and that RAM table
- not the ROM one - is what the stage spawns and what `hp_acid_live_slot`
reads at runtime. `hanger_rotate .equ 0` puts all nine back.

**ONE PER ZONE, so they are spread rather than clumped.** The stage is split
in three by the view the round opens on (world 373..772, `hz_mid_lo` /
`hz_mid_hi`): the left corner, that view, and the right corner. One body comes
out of each, so a match always has somebody hanging in front of the fighters
at the bell and somebody in each corner for the camera to find. As the layout
stands that is:

| zone | bodies |
|------|--------|
| left corner (x < 373) | Ed 239, Mark 276, Sal 367 |
| opening view (373..772) | Tony 453, Eric 522, Geo 622, John 708 |
| right corner (x > 772) | Jeff 787, Steve 900 |

**The zones are measured, not listed.** `hp_zone_of_x` reads each body's world
x out of `hanger_coords`, which `create_hangers` has already filled from
`hanger_initab` - so moving a body in the layout editor
(`tools/run_deadpool_hanger_layout.ps1`) moves it between zones with it, and
there is no second table to keep in step.

**WHICH three is a bag, not a roll.** Each zone keeps `hp_zone_bag` (who it
has not dealt yet this cycle) and `hp_zone_last` (who it hung last match).
It deals out of the bag, and refills only when the bag is empty - so a zone
shows everybody it has before it shows anyone twice. The body that just hung
is barred from the pick that FOLLOWS a refill, which is what stops a new cycle
opening on a repeat.

**Hold him out of the BAG on a refill instead and the cycle collapses.** That
was the first cut: refill = zone minus last. A zone of three then deals three,
two, two, two... and the probe showed one body in four of eight matches. He is
held out of the one pick instead, and the same probe then showed a clean
round-robin - Ed, Mark, Sal, Ed, Mark, Sal over twelve.

A zone of two can only alternate, which is the best "somebody new" it has; a
zone of one hangs the same body every match, and a zone of none just stays
empty.

**Deliberately NOT `randu`, and NOT `@tick` either.** `randu` is out for the
same reason as `hp_fx_hold_a0` further down this file: `@rand` is the game's
own stream and MAIN.ASM re-seeds it per round from
`battle_num ^ p1_wiar ^ p2_wiar`, so a roll here would both shift the AI's
rolls for the rest of the round and hand back the same number every time.

The first cut used `@tick` instead - and **`@tick` is a constant here**.
`tick` is in `round_init_words`, so `round_init` zeroes it and
`create_hangers` runs a few ticks later, every single round. The probe is what
showed it: the picks came out a perfectly regular round-robin (Ed, Mark, Sal,
Ed, Mark, Sal), because the chooser handed back the same number every time and
the bag was doing all the work. It was not wrong, just fully predictable, and
the comment claiming otherwise was the actual bug.

`hp_pick_stir` is a private 16-bit xorshift in `.bss` that lives across
matches and is advanced once per pick, seeded off the **value** of `@rand` -
read, never advanced, which costs the stream nothing - so a new match number
starts it somewhere else. The BAG is still what guarantees the three are
different; the stir only decides the order inside a cycle. With it in, the
same twelve picks come out shuffled and still deal each body of a zone
exactly once per cycle.

**Rounds 2 and 3 keep the three the match started with.** `create_hangers`
picks only when `round_num` is 1 - the same test that already decides whether
`hp_dropped` is reset - and `hp_live_now` is `.bss`, so the round-2 and
round-3 rebuilds find the same three, with whoever went in already a skeleton.

## How many fall in a round: one or two, not all three

**The three are the same three for the whole match and a body that goes in
STAYS in, so if all three could go in during round 1 there would be nothing
left to watch.** `hp_round_cap` is this round's allowance, rolled by
`create_hangers` on EVERY round (unlike the lineup, which is picked once a
match) out of `drops_per_round_min`..`drops_per_round_max` = 1..2.
`hp_round_drops` counts what the round has spent, incremented in
`hp_drop_begin` beside `hp_drop_busy`, and the drop trigger refuses once it
reaches the cap.

It is a **ceiling, not a quota**. The on-screen test and the 15-second pause
still apply on top of it, so a round can perfectly well see nobody fall - the
camera never went near anyone, or the pause had not run out. What it stops is
the pool emptying itself in one round.

**The cap check sits after the in-view test**, so a capped round still counts
`hp_next_drop_ticks` down. That is deliberate: the pause carries across
rounds, so the next round opens ready rather than waiting another 15 seconds.
The measured consequence is that a body whose pause ran out during a capped
round goes in on the next round's very FIRST fighting frame.

### Measured, by A/B

Same run, same seed, same frames - only `drops_per_round_max` differs:

| | round 1 | round 2 | round 3 |
|---|---|---|---|
| cap 2 | Mark (f881), **Jeff (f2562)** | John | - |
| cap 1 | Mark (f881) | John | **Jeff (f8478)** |

Jeff had the room, the camera and the pause at frame 2562 either way. At cap 1
he does not go, and waits two rounds. That is the cap doing the work and not
the round simply running out - which is what a single cap-1 run on its own
could not tell you.

### The rig

`tools/run_deadpool_rotation_probe.ps1` reads `hp_live_now` off the running
machine every time the pick fires and checks three things: three bodies, one
in each zone, and none of them in the lineup before. 12/12 picks PASS.

It gets more than one pick per run the honest way: `create_hangers` picks when
`round_num` reads 1, and `round_init` gets there by incrementing, so the probe
holds `round_num` at **0** between rounds. Every round then builds the stage
down exactly the path a new match takes. Nothing about the pick itself is
written.

```
PICK 1: Ed(left) John(view) Jeff(right)
PICK 2: Mark(left) Geo(view) Steve(right)
PICK 3: Sal(left) Eric(view) Jeff(right)
PICK 4: Ed(left) Tony(view) Steve(right)
```

`-Mode drops` runs the other half: real matches, rounds played out, watching
what actually falls. It checks the three stay the same all match, that nobody
who went in came back out, and that no round exceeded its own cap. 2/2 matches
PASS.

```
MATCH 1 hangs Mark(left) John(view) Jeff(right)
  round 1: cap 2 | already in the acid: nobody     | fell: Jeff,Mark (2)
  round 2: cap 2 | already in the acid: Jeff,Mark  | fell: John (1)
  round 3: cap 2 | already in the acid: all three  | fell: nobody (0)
```

**Two things that rig had to learn, both of them about WHEN it looks:**

- **Open the round in the round INTRO, not on the first frame of the fight.**
  Because the pause carries across rounds, a body can go in on the round's
  very first fighting frame - the same frame the rig noticed the round number
  had changed. Snapshotting "who is already in the acid" there counted his
  fall as pre-existing state and lost it. The stage (and so the lineup and the
  cap) is built before the intro, so opening the round there is both earlier
  than any drop and later than `create_hangers`.
- **Only the three on the hooks mean anything.** `ch_reset_lp` writes
  `hp_dropped = 1` for the six that are NOT in the lineup, so no body of
  theirs can appear - and they are not spawned at all. Reading `hp_dropped`
  across all nine reports six bodies in the acid that do not exist.

A `FLIP` line for every `hp_dropped` change, with the game state it happened
in, is what made the first of those visible - it is left in.

### Pinning one body for the other rigs

`hp_lineup_force` is a bitmask in RAM: non-zero, it IS the lineup, and the
rotation's own state is left untouched. `tools/deadpool_boon_drop_test.lua`
writes `1 << DP_HANGER` into it every frame, so the drop rig still watches
whichever body it was asked to and gets him alone - no neighbour's drop can
leak into his window. `tools/deadpool_hanger_layout.lua` writes all nine bits,
because the layout editor places all nine.

## The drop schedule: on screen, 15 seconds apart, once per match

**Every live body goes in once per match, only while he is on screen, with at
least 15 seconds between drops, and stays in for the rest of the match.**
`hanger_acid_live` (MKHANG.ASM) lists the bodies whose art is packed;
`hp_live_now` is the three of them this match is actually hanging (see "Three
bodies a match" above), and the schedule below is theirs.

- **On screen.** A body lets go only when ALL of him is inside the camera -
  `hp_drop_in_view`, screen x `hanger_drop_view_left..right` = 0..350 (room
  for the widest body, Ed's 50). It used to allow 24px off either side and
  test only the left edge, so a body whose left edge was 20px from the right
  border - nothing of him in view - passed.
- **The pause.** One countdown, `hp_next_drop_ticks`, in fighting ticks:
  **nobody goes in for the first `first_drop_ticks` (821 = 15.0s) of a
  match**, and every drop after waits at least `drop_pause_ticks` (821 =
  15.0s) from the moment the previous body is back up on his hook
  (`hp_rise_done`). Being on screen can only add to that. It counts only while
  a fight is live (`gs_fighting`, `winner_status` 0) and nobody is in the
  acid.

  That opening 15 seconds is **fighting time, not wall time**: the countdown
  is armed when the stage is built but only spent by `hp_drop_count`, which
  every waiting body calls after the `gs_fighting` / `winner_status` tests -
  so the round intro, the banners and any pause do not eat into it. It was 128
  (~2.3s, where `:95` on the old round clock fell), which put a body in the
  acid before the fight had really started. The two numbers are the same 821
  and written out separately because GSPA resolves a `.equ` single-pass and
  `first_drop_ticks` is defined above `drop_pause_ticks`.

  **Measured, and the rig asserts it**: `run_deadpool_rotation_probe.ps1
  -Mode drops` reports the first fall of a match's round 1 as ticks since the
  first fighting frame - `+820`, against `+127` before the change. Round 1 is
  the only round it can assert on, because the countdown CARRIES ACROSS
  rounds: a round that ends with 3 seconds left on it is followed by one whose
  first body goes in 3 seconds after the bell, which is correct and was
  observed (`+439` after a short round).
- **Counted once a tick.** Every waiting body's process asks, so
  `hp_drop_count` stamps `@tick` and the second one to ask in a tick does not
  count it again. `hp_rise_done` stamps the tick it sets the pause in too: the
  first run measured 820 ticks, because another body's process later in that
  same tick counted it straight away.
- **Not in order.** Whoever is on screen when the pause is up goes next. A
  fixed order stalled the whole pool whenever the body next in line was off
  screen - at rest the camera shows only world 373..773, so Tony at 892 could
  hold everybody up for a whole round. The last version chained them in
  hanger order; the one before gave each body a round-clock value, which
  could not fit a third drop into a ~58s round.
- **Once in, stays in.** `create_hangers` resets `hp_dropped` and the
  countdown only when `round_num` is 1 (`round_init` counts the round before
  `do_a11_background` builds the stage). In rounds 2 and 3 a dropped body is
  spawned as his skeleton on the hook and the countdown carries over. A round
  that ends in the middle of a drop never reaches `hp_rise_done`, so
  `create_hangers` sets the pause itself in that case.
- **Finish Him drops nobody.**

The rig checks it. `starts_on_screen`: where the camera had him when he let
go. `next_drop_waits` (natural timing only): how long after his drop the next
body went in. `-ClockJump` holds the round clock at 99 and cuts every wait to
2 ticks; `-NextRound` checks round 2 (`stays_in_the_acid`); `-NoPinCam` leaves
the camera at rest, which is the negative - Tony at 892 never goes in.

```
RESULT PASS pass=46 skip=1 hanger=3 x=600   (John, -ClockJump -NextRound)
RESULT PASS pass=46 skip=1 hanger=0 x=767   (Ed,   -ClockJump -NextRound)
CHECK PASS next_drop_waits  the next body let go 821 ticks after he was back
                            on his hook, want >= 821 (15s)      (Tony, natural)
-NoPinCam -Hanger 2: camera 373..373, Tony never on screen, never went in;
                     John (on screen) went in, Ed (6px in view) did not
```

### The chain rig is per hanger now

Every number the chain assembly is placed with was a single equate while Ed was
the only body that dropped, and Tony's `data/TONYHANG.WAX` stacks the pieces
differently. They are tables now, indexed by hanger:

| table | what it holds | Ed | Tony |
|-------|---------------|----|------|
| `hanger_hook_xofs` / `hanger_hook_yofs` | TINHOOK off the body's top-left | 18, -8 | 15, 0 |
| `hanger_conn_xofs` / `hanger_conn_from_hook` | TINCHAIN4's x, and its top off the hook's | 20, -69 | 19, -63 |
| `hanger_chain_xofs` / `hanger_chain_from_hook` | longchain's x, and its top off the hook's | 20, -278 | 18, -272 |
| `hanger_fx_xofs` | where the pool FX centre on him | 24 | 17 |
| `hanger_body_strip_count` | bands in his body | 6 | 3 |

Two of those were doing damage as constants:

- **`acid_hook_y_bias` was a second copy of Ed's hook offset**, read by the
  acid branch while the hanging branch read `hanger_hook_yofs`. They could only
  ever agree for one body, and when they disagreed the hook jumped the tick the
  branch changed. Both branches read the table now.
- **The connector shared the chain's x.** That is right for Ed - his WAX's 22
  against the chain's 20 is a pixel of centring on a 3px-wide link - and wrong
  for anybody whose WAX stacks them differently.

**Tony's chain is the WAX, straightened.** `TONYHANG.WAX` puts TINHOOK at x+15
y 0 and TINCHAIN4 at x+19 y-63 against his body's top-left, and those are used
exactly as measured. Its longchain is a placement reference only - it sits 21px
left of the connector and 150 rows short of reaching it - so the chain is
centred over the connector (5 wide over 3, one to the left: x+18) and ends two
rows into it (`-63 - 211 + 2 = -272`), the same 2-row overlap Ed's has.

### The FX follow the body that is dropping

`hp_fx_center_a0` adds `hanger_fx_xofs[i]`, so every bubble, drip, ripple and
splash centres on the body in the acid. Two of them could not: the EDACID boil
lanes and the steam are **children with no hanger index of their own** - their
`p_store` slots are their own animation state - and `ed_fx_place_keyed` read
`hanger_coords[0]` outright, so every lane played on ED whoever was actually in
the acid. `hp_drop_begin` writes two globals for them now: `hp_fx_x` (the
dropping body's x) and `hp_fx_dx` (his FX centre against Ed's, so the
`acid_smoke_pts` rows measured on Ed still land on the bones). `hp_drop_busy`
allows one drop at a time, so there is never a second writer - the same
argument `hp_drip_y` already stands on.

## The cut is row-exact, not band-at-a-time - BOTH WAYS

The bands are how the art is sliced; they are **not** how the body is eaten.
Terminating the multipart list alone loses a whole band at a time - six hard
pops across a four-second sink. So the cut walks the shape RAM and shortens the
band the surface is crossing:

```asm
hp_lss_lp
	move	*a2,a0,l		; sag 0 ends the list: he is wholly above
	jrz	hp_lss_end
	move	a4,a5
	sub	a9,a5			; rows of HIM above the surface
	move	*a2(mp_aniy),a0,w	; this piece sits oypos - dy down the body...
	add	a0,a5			; ...so this many of its own rows are above
	jrle	hp_lss_cut_here		; wholly under: the list stops before it
	move	*a2(mp_sizey),a0,w	; its full height, as ani2 just rebuilt it
	cmp	a0,a5
	jrge	hp_lss_whole
	move	a5,*a2(mp_sizey),w	; the band the surface is cutting through
```

`mp_sizey` (DISPEQU.ASM:87) is a piece's ROW COUNT and the blit draws top-down
from the piece's own y, so shortening it clips the **bottom**. `ani2` rebuilds
the full shape at the top of `hp_lower_section_shape` every call, so the clip is
never cumulative.

**It is measured off the pieces, and it used to be measured off `strip_step`.**
The old count was `ceil((188 - top) / 20)` with a seek to that many entries,
which is true of Ed and of nobody else: Tony is THREE 40px bands, so the count
came out at six, the seek ran off the end of his list and the clip wrote a
height into whatever followed it in the shape RAM. A piece already carries its
own `dy` and its own height, so nothing has to be told a band height - which
also means a body can be cut into whatever bands its art wants.

**And each piece is cut on its own, because not every body is cut into
bands.** John's two pieces sit SIDE BY SIDE - `JOHNHANG1A` is his left side,
full height, and `JOHNHANG1B` his right side from row 17 down - so the surface
crosses both at once. The walk used to stop the list at the first piece the
surface was cutting ("nothing under a cut band can be dry"), which is true of
stacked bands and dropped John's whole right side the tick his feet went in.
Now every piece is cut by itself, a piece wholly under is taken out of the
list (the pieces after it close up behind it), and the list ends after the
last one still showing. Stacked bands come out exactly as before - Ed and Tony
re-passed 46/46 on it. The breach is still marked once per pass, so two
pieces crossing on the same tick cannot skip the 0 -> 1 edge the sizzle keys
off.

**This is UNUSED_HARDWARE_EFFECTS #6's outcome without #6's cost.** That item
wants `dmatplft`/`dmartbot` moved around a batch - drain the queue, set the
window, draw, restore - inside the DMA interrupt path; `shadf` (MKDISP.ASM,
which is how this stage already keeps shadows out of the acid via
`shad_ytop`/`shad_ybot`) is the one place in the tree that does it. Here the
clip is a property of ONE PIECE, and a piece already carries its own height.
The window rect is still the answer for anything a resize cannot express -
clipping the MIDDLE of a sprite, or clipping in x.

**Never write a height larger than the art.** The DMA would read past the frame
and spray whatever follows it in the image ROM across the screen. Ed's band F
is 12 rows where the others are 20, so the compare is against the piece's own
size - which is now the only thing the cut looks at.
The rig's histogram used to show that as `12x96` - but those 96 frames were not
all the guard. **Twelve of them were a bug, and it is the one that made his feet
"just miss" the acid.** The band count is `ceil((188 - top) / 20)`, and the clamp
after it was `cmp a4,a1 / jrlt`: *fewer* bands than he has means "partly under",
anything else means "wholly above - draw every band in full". With all SIX
bands in view the last one can still be partly under - that is exactly the
moment his feet go in - so band F (the shoes, 12 rows) drew whole for 12 px past
the surface, then lost all 12 rows in one step. `hp_breached` is set by the cut,
so the sizzle and the first bubble waited for that step too. It is `jrle` now:
only a count *past* the band total means he is wholly above.

```
before  row_clip bottom-band heights ... 12x56 ...    feet: 12px through the acid, then a pop
after   row_clip bottom-band heights ... 12x4  ...    cut at the surface, bubble at his feet
```

The same clamp popped the bones' 16-row band F at the end of the rise (`16x61`
-> `16x8`). `cut_is_row_exact` had passed straight through it - it only counts
*distinct* heights, and all twenty were there. `cut_never_stalls` and
`rise_never_stalls` now fail if any height is held more than 20 frames while his
top is below his crossline (above that line every band is legitimately full
height; one step of the sink holds a height ~8). The rig measures that
crossline from the body's own piece records - `188 - max(-aniy + h)`, which is
76 for Ed's 112 rows and 68 for Tony's 120 - rather than using
`ed_crossline_y`, which is Ed's.

### The rise is the same picture

Going down, the body is eaten from the bottom as it sinks; coming up, the
skeleton is revealed from the top as it is pulled out. **That is the same
statement - "draw the rows above the waterline" - so it is the same code.**
`hp_cut_shape_to_surface` takes `a8` = the multipart object and `a9` = its top
Y, and both directions call it; `hp_lower_section_shape` is now just that plus
the strip note the sink needs for its bubbles.

The rise used to walk `a_acidbones_rise`, a hand-authored list of six
cumulative shapes, one row per rise step - so the bones arrived in six lumps
while the body going down was being eaten a pixel row at a time. `hp_rise_lp`
measures it off the skeleton's own Y now, and `hp_pull_lp` is gone with the
table it existed for (it was the "shape list ran out, keep rising with whatever
is current" tail; a geometric cut has no list to run out of). The authored
tables are kept as the reference but no longer drive anything.

Two things had to change with it:

- **The skeleton is built from `hanger_skel_full`, not `hanger_skel_first`.**
  `get_multi_obj` sets `*a8(oshape)` from what it is given, and the cut restores
  the full shape from there every pass - built from `hanger_skel_first` (ONE
  band) it could never reveal more than that one band however far it rose.
- **`hanger_skel_full` was still `dedhang1_r03`** - three of the six - left
  behind when the shapes were extended to `r06`. The parked skeleton was
  missing its bottom half and nothing caught it, because the rig had no check
  that looked at the finished skeleton's piece count. `rise_is_row_exact` now
  reports `max_pieces`, which is 6.

Measured, both directions:

```
cut_is_row_exact   bottom band drew 20 distinct heights (1..20 rows)
rise_is_row_exact  top band drew 20 distinct heights (1..20 rows), max 6 bands out
```

where band-at-a-time cutting and a six-shape table would each show exactly one.
EDHANG1F is 12 rows and DEDHANG1F is 16, not 20, which is why those two heights
are where band F's full size shows up - see the clamp bug above for why they
used to show up far too often.

```
cut_never_stalls   no cut height held longer than 8 frames
rise_never_stalls  no reveal height held longer than 8 frames
```

## The bubbles at the cut edge

`hanger_fx_enable` is **1** now, and the parent survives it. The note on file
said the child FX procs stalled `hanger_proc` during pull-up; that diagnosis
predates the `a12` bug, which dropped the parent on its first wake every time.
With a12 fixed the bubbles run and `hanger_proc_survives` still passes, so the
old reason is retired.

Two stubs fell out of switching it on, both invisible while the block was
compiled out:

- **`hp_spawn_lift_drip` was never written.** It was called from
  `hp_lift_bubble_fx` under `hanger_fx_enable` alone, so the assembler went
  looking for it the moment the bubbles came on. That block is gated on
  `hanger_drip_enable` now, which is what it was always meant to answer to.
- **`hanger_drip_enable` had no definition either** - the old handoff doc
  quotes it as `.equ 0`, but it is not in the source. It is defined now, and
  documented as a stub: implement the drip before setting it.

### Layering: -6 was four layers behind the thing it was hiding

The rig prints every layer it sees, and the sinking body is at **z = -2**:

```
MEASURE layers body_z=-2  bubble_z=-6/-1  chain_z=-9/-3  splash_z=-6
CHECK PASS bubbles_in_front_of_body  body_z=-2, bubbles seen on z -6/-1
```

`acid_fx_z` is -6 - correct for the ambient boil and the pre-rise beats, which
belong *behind* the bones - but a bubble cannot hide a cut edge from behind it.
The lowering bubbles get `acid_lower_fx_z` = **-1**, in front of the body and
still behind the fighters and the stage lip. They are also centred now:
`lower_bubble_xofs` is **6**, not 18, so they break over the cut rather than off
his shoulders.

**And the whole group is `bubble_x_nudge` (6) further right.** Measured with a
ruler over the filmstrip, the cluster centred on screen ~217 while his torso
centred on ~223. The nudge goes on the lowering bubbles *and* the ripple they
throw, and into `ed_fx_x_nudge` (10 -> 16) for the EDACID lanes, so the set
moves together. After: bubbles centre on ~223 at shots 40 / 56 / 70.

**Each bubble on its own clock.** They used to pop in lockstep: the six EDACID
lanes are all created on one tick by `hp_start_acid_boil` and all slept
`ed_fx_frame_ticks` (5) every frame, and every lowering bubble ran `framew` at
4. Holds now come off `fx_hold_tab` (4-6, averaging 5) and `bubl_hold_tab`
(6-9, averaging ~7), walked by **one shared counter**, `hp_fx_hold_ctr`.

**The sinking bubble was one bubble looping in place.** A new one every 2
lowering steps (8 ticks), on one of two spots (+-6 by parity), each popping its
four frames in 12-20 ticks: there was always a bubble on the same spot, cycling
fast. Now `lower_bubble_mask` is 03 (one every 16 ticks), each takes its own
spot off `lower_bubble_xtab` (eight unequal offsets across his width, indexed
`>>2` so one bubble is one step), its frames hold 6-9 ticks, and the ripple
comes every 4th *bubble* (`andi 0fh` - with mask 03, `andi 3` would have been
every one). `sinking_bubbles_not_too_fast` times only the z -1 bubbles: an
EDACID lane that steps off BUBL art is banked as a pop-only life, so lane
numbers always read ~4.5 and would gate nothing useful. The
lanes call it in turn, so on any frame each draws a different entry and they
drift apart from their first sleep; the averages keep the authored tempo, so
rows that encode holds still hold about as long. It is deliberately *not*
`randu` - that draws from `@rand`, the game's own RNG, and every extra call
would shift the AI's rolls for the rest of the round.

```
CHECK PASS bubbles_out_of_step  158 bubble frame changes over 139 ticks: 1.14 per
                                tick on average, at most 3 at once
```

The rig compares each bubble's frame with the tick before. Lanes sharing one hold
change all together, several per tick; lanes on their own holds change one or
two at a time.

**Separate entry points, not a shared z variable.** `bubble_proc_front_deep` /
`_front_mid` push their layer at entry and `bubble_proc_common` pops it. A
global set before `create` would race: the child does not run until the
dispatcher reaches it, and `hp_lower_one_bubble` fires a ripple in the same call
that must stay at `acid_fx_z`.

**A rig flaw worth remembering:** the census recorded only the *first* object of
each kind, and the ambient bubbles come earlier in the object list, so
`bubbles_in_front_of_body` reported a false FAIL - the front bubbles existed and
were never looked at. It collects every object's z per kind now. The same flaw
is why `hook_z` reads `-9/-8/-3/-2`: several objects, one slot.

## The chain goes in with him

`longchain` used to pin at `acid_pull_line_y` the moment he was below the
waterline - the chain stopped at the surface and he sank away from the end of
it. It tracks his top the whole way now, in and back out. It needs no z work:
it is already at **-3**, one layer behind the body at -2.

**The two placement paths had different offsets**, and that was a visible pop.
`hp_uc_normal_chain` puts the chain at `body + hook_yofs + hbody_chain_ofs`;
the acid branch skipped the `hook_yofs`, so the chain JUMPED 18 px the tick he
crossed the waterline and swapped branches. The rig measures the gap between
the chain's bottom and his top across the whole drop and fails on any spread:

```
CHECK PASS chain_follows_him   chain bottom minus body top stayed within 18..18
MEASURE chain_at_hang      longchain@596/-173
MEASURE chain_at_submerge  longchain@596/-1     <- under the acid with him
MEASURE chain_at_done      longchain@596/-173   <- back where it started
```

### The chain honours the waterline too

Following him under means the chain is *drawn* below the surface, which is
chain painted on top of the pool - the one thing the acid is there to hide. So
it gets the same clip the body gets, one level simpler: `longchain` is a single
object, so the row count is the **high half of `osize`** rather than a piece's
`mp_sizey`.

`hp_clip_chain_to_surface` runs from `hp_uc_sync_vals`, the common exit of every
placement path, and recomputes the height every tick - nothing restores it,
`gso_dmawnz` set the size once at spawn and the object lives for the round. Same
rule as everywhere else: **never taller than the art** (211 rows), and floored
at 1 rather than 0 because a zero-height blit is not worth finding out about.

```
CHECK PASS chain_stops_at_the_surface  chain's drawn bottom reached 0 px past
                                       the acid surface (y 188)
```

## The FX follow the acid, not a constant

**Nothing boils until the acid actually touches him.** `hp_breached[index]` is
0 dry, **1 on the tick his first row goes under**, 2 thereafter, set in
`hp_lss_cut` where the clip actually happens. The sizzle and the first bubble
both fire on the 0->1 edge, so they land on the same frame.

That replaced a `ed_crossline_y` compare in `hp_fall_lp`. The crossline is
where his feet *meet* the surface, which is a tick or two before the first row
is eaten, and the bubbles were on a different clock again - they came off the
band COUNT dropping, which is the first *whole* band lost, twelve pixels later
still. Three effects, three clocks. One event now.

**No bubbles on the way out.** The boil is what the acid does while it is eating
him; once the bones are coming back out it is drips running off them, and a
surface still churning reads as a second body going in. The pre-rise beats keep
`hp_acid_fx_trio` - they are the last of the boil.

**The drips are MKSKULL's own two lanes.** `hp_spawn_lift_drip` - the routine
that was a stub - is written: `a_body_drip` (greendrip0, 3x10, one bead that
`body_drip_proc` walks down to the pool) is **DRIP**, and `a_acid_drip`
(greendrip1-9, growing to 55x29) is **BIGDRIPS**. They alternate so the big one
does not fire every time.

They land in **different places on him**, not just different columns. Every
drip used to come off the centre line at one height, which reads as a leak
rather than a body sheeting. `lift_drip_xofs` and `lift_drip_yofs` are paired
eight-entry tables of unequal, unordered offsets - x spanning +-30 (his width is
50), y spanning 8..108 down his 116 rows - walked by the same counter, so each
entry is a *spot* and the cycle cannot be picked out of a four-second rise.

The y is measured from the **skeleton's top**, so the spot rides up with him,
and it is clamped above the waterline: a drip that starts under the acid has
nothing to run down.

**But every drip ENDS in the pool, on one line.** The x varies; the landing y
does not. The last frame of each drip is locked to `acid_ripple_y` - the line
the ripples are drawn on - and only `lift_drip_yjit` moves it, 1-2 px either way
(paired with the same index), so the splashes do not stack into a single row
and never leave the line. A drip that ends 10 px up the wall does not read as
falling into anything. `hp_drip_land_y` carries it beside `hp_drip_y`:

- **BIGDRIPS** (`acid_drip_proc`) plays its whole greendrip1-9 lane on the
  landing line - it is the splash, and greendrip9 is the last bead going in.
- **DRIP** (`body_drip_proc`) starts on him at the `lift_drip_yofs` spot and
  falls to the landing line, stopping exactly on it. It reads the landing y
  into `a9` at spawn, because `a9` survives the sleeps and the next spawn
  rewrites the global.

```
CHECK PASS drips_land_in_the_pool  12 drips landed on y 182..186
                                   (182x4 183x2 184x2 185x2 186x2), want 184 +-2
```

The rig measures each drip's **anchor** (`oypos` + the frame's TBL anipoint y,
which is what `hp_place_single_fx` places) and records its lowest point until
the object goes away.

**No new drip in the last 8 px of the pull** (`lift_drip_stop_band`). The last
drip of the rise used to spawn 184 ticks in, with him almost home: it started at
world y 47, up by the hook, 7 px off his left arm (the table's -30 / +8 spot),
and fell the whole screen to the pool - it read as coming off him from nowhere.
`hp_spawn_lift_drip` now returns without spawning once the rise Y is within
8 px of `ed_start_y`; the drip before it (176 ticks, y 55) is kept. The rig logs
every lift drip's first appearance (`MEASURE lift_drip_spawns`) and
`no_late_drip_up_by_the_hook` fails if one starts above world y 60 (now: 103).

`hp_drip_y` carries the start height to the child. It is a plain global, not
per-hanger, and that is deliberate: the `hp_*_slot` helpers resolve the index
out of the CURRENT process's `p_store1` and a drip child has no index of its
own, while `hp_drop_busy` allows only one drop at a time so there is never a
second writer. Every spawn site sets it - including `hp_acid_fx_trio`, which
puts the surface line back - so no caller inherits another's height.

```
CHECK PASS lift_drips_are_spread  16 columns (x 545..591) and 71 distinct x,y
                                  spots, y span 35..180
```

## data/EDHANG.WAX is the placement, and only the placement

The WAX is an IMGTOOL **world project**, not art - it references frames that
already exist (`MKHANG.IMG` 0 / 9 / 10 / 11) and carries no baked lane. What it
authors is exactly one thing: **where TINHOOK, TINCHAIN4 and longchain sit in
relation to EDHANG1.** EDHANG1 itself stays where `hanger_initab` puts him.

| WAX slot | order | frame | dx | dy | from EDHANG1 |
|---|---|---|---|---|---|
| 0 | 0 | `EDHANG1` | -25 | -48 | the reference |
| 2 | 1 | `TINHOOK` | -43 | -40 | dx 18, dy **-8** |
| 1 | 2 | `TINCHAIN4` | -47 | +29 | dx 22, dy **-77** |
| 3 | 3 | `longchain` | -45 | +238 | dx 20, dy **-286** |

**Both axes measure AWAY from the origin, so the deltas flip sign coming in.**
Two independent checks confirm that reading rather than assuming it:

1. **Every joint meets.** longchain is 211 rows from -286, ending at -75, where
   the connector starts at -77. The connector is 70 from -77, ending at -7,
   where the hook starts at -8. The hook is 21 from -8, ending 13 rows *into*
   the body - the neck overlap.
2. **The x values land within 2-3 px of the 23 / 21** that were hand-tuned in
   this file long before the WAX existed.

The code hangs the connector and the chain off the HOOK rather than the body, so
those two are stored as the WAX offsets less the hook's:
`wax_tinchain_from_hook` = -69, `wax_chain_from_hook` = -278. Measured at the
hook with his top at 20: hook 12, connector -57, chain -266.

**Four sprites, nothing else** - no linked run of TINCHAIN4s, no animated
connector, no reach cap.

## He hangs below the HUD, on the WAX's own stack

**Hang height is 46, not 20.** `FLASH_TOP` is 46 - the first play-area line
under the HUD - and at 20 the hook and every chain joint sat *behind the green
life bar*, so the chain appeared to stop dead in mid-air above his head. The
join now lands in the play area. Cost: 142 px of fall to the crossline instead
of 168 (~3.5 s, not ~4.1 s).

**The WAX stack, exactly: longchain / TINCHAIN4 / TINHOOK, top to bottom.**
An earlier pass swapped the two chain pieces (longchain on the hook, TINCHAIN4
above it) because at a hang of 20 the WAX's longchain, 286 rows above him, was
off the top of the screen. At 46 that reason is gone: the HUD hides the same
rows *at the hang* in either order, and during the drop only the WAX order ever
shows TINCHAIN4. Swapped, TINCHAIN4 sat 211 rows up for the whole sequence -
screen -94..-24 at its *lowest*, the rise start - which is exactly "on the way
up the tinchain is completely gone". Now:

```
MEASURE chain_at_hang   chain screen=-232..-21  connector=-23..47   hook=46..67
MEASURE chain_at_rise   chain screen= -91..120  connector=118..188  hook=187..196 (9 rows, clipped)
```

`wax_chain_yofs` -286 / `wax_tinchain_yofs` -77 / `wax_hook_yofs` -8 are the
WAX's own joints: longchain ends at -75 against the connector's -77 (2 rows of
overlap), the connector ends at -7 against the hook's -8 (1 row).

**TINHOOK sits BEHIND him** - and that is a deliberate departure from the WAX.
The imgtool sorts slots by z, then `order`, and draws in that sequence:
EDHANG1 is order 0, TINHOOK order 1, so the WAX draws the hook *over* the body,
its curl (rows 18-20, 13 rows into him) caught in his collar. Tried that way,
it reads as sitting *on* him rather than as the thing he hangs from, so
`wax_hook_zbias` is **-1**: the hook draws one layer behind, -3 against the
hanging body at -2 and -9 against the bones at -8. The cost is the one the
front layer was solving - the curl is hidden in his collar and only the 1 px
shank shows between chain and shoulder - and that is the accepted trade.
`hook_behind_him` in the rig keeps it there; flip the equate to +1 and invert
that check to go back.

**No simmer park.** While he was under, the hook and connector used to be parked
at `chain_hidden_y`. With the WAX stack that would have left longchain dangling
70 rows above the pool with nothing under it, so every piece now follows him the
whole way and `hp_clip_one_to_surface` sets a piece `inviso` when it has no rows
above the surface at all - which is the only thing the park was for (the clip's
1-row floor would otherwise paint a sliver on the pool).

```
CHECK PASS hook_meets_chain      both joints (longchain->TINCHAIN4, TINCHAIN4->TINHOOK) stayed within -2..-1
CHECK PASS hook_in_front_of_him  hook z minus body/bones z ran 1..1 while the hook was drawn
```

## Two placement paths, one set of numbers

Every "jump" fixed in this section was the same bug: the human-body branch and
the acid/skeleton branch of `hp_update_chain` carrying *different* offsets, so
the chain moved the tick one branch handed to the other.

- **Hook y:** `acid_hook_y_bias` was +18 while `hanger_hook_yofs` said -8. On
  the parked skeleton that left longchain's bottom at world 38 and the hook's top
  at 64 - a 26 px gap. It is now `wax_hook_yofs`.
- **Chain / hook x:** the body moved onto the WAX's 20 / 18, the skeleton's
  `hanger_skel_chain_xofs` / `hanger_skel_hook_xofs` stayed at 23 / 21, and the
  chain slid 3 px sideways at submerge. Both now read the `wax_*` equates.
- **The stop Y:** the fall stops on the first step past the 188 line - 190,
  from 46 in steps of 3 - but submerge then snapped the hidden body to
  `acid_rise_start` (192) and the skeleton and the rise counter started there
  too. The chain hopped 2 px *after* it had stopped. `hp_sink_y[index]` now
  records where he actually stopped; the skeleton spawns there and the rise
  counts down from there. It is a slot rather than `a9` because `create` clobbers
  `a9` between the submerge and the skeleton.

The rig guards all three:

```
CHECK PASS chain_never_jumps  chain x 593..593, biggest one-frame y move 3 px (a step is 3)
CHECK PASS hook_meets_chain   hook top minus longchain bottom stayed within 0..0
```

`chain_never_jumps` is the one to trust for this class of bug: any disagreement
between branches shows up as a one-frame move bigger than a step.

## One chain assembly, and only one

`longchain` + `TINCHAIN4` + `TINHOOK` are a single hanging rig. They all follow
the body at fixed offsets, in the acid or out of it, and
`hp_clip_chain_to_surface` clips **all three** at the waterline against their
own art heights (211 / 70 / 21 - never ask for more rows than the art).

**What that replaced: `hp_uc_hook_deep`.** When the hook was judged "too deep to
show without reading as a floor hook" it hid the hook and bridged the gap with
`TINCHAIN4` **alone**, positioned against the OLD fixed chain anchor
(`acid_pull_line_y + hbody_chain_ofs`) and capped by `ed_chain_reach_cap`. Once
the chain started following him that anchor stopped meaning anything, so on the
way up a lone connector popped in unrelated to where the chain actually was - a
second chain out of nowhere. The whole special case is gone.

## The pool is quiet until he touches it

The six EDACID lanes used to be created at **scene setup** and ran for the whole
round, so the pool boiled from FIGHT onwards with nothing in it - and by the time
he actually went in there was no change to see. They are the acid *reacting* to
him, so `hp_start_acid_boil` runs on the breach edge (with the sizzle and the
first bubble) and `hp_stop_acid_boil` kills the lanes and their objects once the
bones are **clear of the acid** (`hp_rise_done`). It used to stop them the moment
the bones started up, which left a dead-flat pool under a skeleton still being
pulled out of it; the boil now runs the whole pull-out (`bubbles_during_the_rise`:
181 frames). `existp` stops a second drop in one round stacking a second set. The
boil's own EDACID drip lanes keep their authored rows through the rise, so
`drips_land_in_the_pool` holds only the lift drips (OID not `pid_edpool_fx`) to
the landing line.

**If the body ever blits as a solid magenta block**, that is not the cut: on
2026-09-12 `.bss` had grown past the fixed system stack top (`stckst`,
SYSEQU.ASM) and MKHANG's piece list sat in the live stack. `stckst` is now
`0117fff0h` and `tools/check_stack_clearance.py` fails the build if it recurs.
The rig's `DP_TAP=1` puts a write tap on the body's piece RAM and names every
writer's PC - the only legal ones are `ani2` and `hp_cut_shape_to_surface`.

```
CHECK PASS pool_is_quiet_until_he_touches_it  peak acid FX: 0 before the
        trigger, 9 while he goes in, 5 once the bones are rising
```

**A bug the rig caught in my own table walk:** `hp_spawn_lift_drip` only fires
when the lift counter passes `lift_drip_mask`, so consecutive drips see a
counter 4 apart - and `andi 7` on that yields only TWO of the eight table
entries. `srl 2` before the mask makes one drip one table step. The check said
"drips came off 2 columns"; it reads 61 now. `lift_drip_mask` also went 3 -> 1,
because at 3 only about seven drips fired in the whole rise.

## ACIDSMOKE: the steam coming out with him

`ACIDSMOKE1-5` (`data/ACIDHANG.IMG`, 33x28 up to 73x53, four colours) is placed
by `data/EDSMOKEACID.WAX` and played by **`hp_rise_smoke_proc`**: created on the
tick the bones are built - right where `hp_stop_acid_boil` stops the boil - and
swept by `hp_rise_done` with `dallprc`/`dallobj` on `pid_edpool_smoke`, so it
exists exactly while he is coming out. It loops `a_acid_smoke` at
`smoke_frame_ticks` (4, the WAX's own hold) and draws at `acid_smoke_z` =
bones + 1, in front of them as the WAX orders the slots.

**Reading the WAX.** IMGTOOL draws a world slot at
`left = origin_x - (art anix + slot local_dx)`, `top` likewise
(`WorldDrawMarkedLaneSprites`, `platform/ui_canvas.cpp`): the slot offset
*shifts the art's own anipoint*, and the two add. With origin (200,20), the body
at local (47,-89) and the smoke at (96,-90) (102,-77) (85,-72) (79,-72)
(69,-75):

```
body  top-left (153,109), 50x116  -> x 153..203, y 109..225
smoke top-left (69,200) (58,174) (71,164) (69,164) (80,170)
```

a plume standing just left of him, straddling the acid, its top climbing
200 -> 164 as it grows.

**Y is the pool's, not his.** The y values are absolute, because the WAX draws
the body *part way out*: anchored to his top instead, the plume would start
~50 px BELOW the pool - on the walkway - at the rise start, where his top is at
187. `acid_smoke_pts` rows are `(x, WAX world y + aniy)`, since
`hp_place_single_fx` places the anchor and `anchor = top-left + anipoint`.

**X is CENTRED on him, which is the one thing the WAX does not do.** Its own
offsets stand the plume 73..95 px to his LEFT, and on screen that read as a
separate cloud beside the pool rather than steam off the bones. Each row is
centred instead - `art left = his left + (50 - w) / 2`, plus the frame's own
`anix` - so the five frames sit at art-left offsets +8, +2, -5, -11, -9 across
his 50 px column.

**Behind him, and ONCE.** `acid_smoke_z` is `acid_skel_z - 1`: he rises *out of*
the steam, and a plume in front hides the art it is meant to frame. And the lane
plays exactly once, ~30 ticks (`smoke_frame_ticks` 6 - the WAX's 4 was over in
20 and read as a flash), then the proc deletes itself - it used to loop
for the whole ~188-tick rise, which read as a smoking pool instead of one gout
of steam as he breaks the surface. `hp_rise_done` still sweeps the pid, for a
round that tears down mid-pass.

**The ACID hiss plays again on the way out**, the same `snd_acid_sizzle` as the
breach going in, fired next to `hp_stop_acid_boil`. It sits *outside* the
`hanger_fx_enable` gate: a sound is not an object.

**And the pool gurgles while he is under it.** `snd_acid_bubble` is
`triple_sndtab` **f6**, "bubble" (`sp_splash|32`, call 0106h) - already in the
table since the leak and dispatched by nothing. It fires once per simmer beat,
five times across the 300-tick hold, from `simmer_fx_proc`'s loop.

Two things decided where it goes. **Not at the breach:** the sizzle is
`sp_splash|153` and holds that class for its full 2.8 s, so a `|32` bubble
underneath it is either dropped or cuts it off. And **not in
`hp_simmer_fx_once`**, which looks like the obvious home and has *no callers* -
a sound put there never plays. `simmer_fx_proc` (created at the submerge) is the
live one. `triple_sound` saves a0-a3, so dropping a `tsound` into that loop
costs its `a10`/`a11` nothing.

```
CHECK PASS smoke_only_on_the_rise  0 frames before the bones existed, 20 from there to the park
CHECK PASS smoke_runs_its_lane     5 of the 5 ACIDSMOKE frames were seen
CHECK PASS smoke_sits_on_the_pool  art top stayed in world y 146..182 (the WAX's rows, lifted 10 by acid_smoke_rise)
CHECK PASS smoke_keeps_his_column  5 distinct x offsets from his anchor, spanning -11..8
CHECK PASS smoke_plays_once        on screen for 20 frames; looping the rise was ~196
```

### Four traps getting it into the ROM

1. **A stray Ctrl-Z (0x1A) ended `src/ACIDHANG.TBL`.** Records appended *below*
   it assemble fine - GSPA reads straight past, the ROM had the art and drew it -
   but anything opening the file in text mode stops dead there. The rig loaded
   none of the five, could not name the sprite it was looking at, and reported
   the smoke as entirely missing. The tell was `art records loaded:` not rising.
   New `MEASURE unnamed_on_the_rise` lists anything on screen the rig cannot
   name, which is what found it.
2. **`MK7MIL.LOD` still named 38 records the MKHANG.IMG re-cut had dropped**
   (`EDLEG1`/`EDBODY1`/`EDHEAD1`, their strips, and the eight developers' strip
   sets). LOAD2 skips an unresolvable name with a log line rather than an error,
   so Phase A1 failed the build - meaning **no LOAD2 pass at all**, for any art.
   Retired from the LOD, from `MKHANGN.TBL`, and from `MKHANG.ASM`:
   `a_edpool_down_full` is gone (its only reader, `edpoolfull_body_proc`, is
   never created and now walks the bands), and the eight parked hangers point at
   `a_edhang1_full` - resolvable, never drawn, since `create_hangers` spawns Ed
   alone. Re-cut a developer into bands and his own list goes back there.
3. **`PPP> n` in a LOD sets bits-per-pixel per block.** MOVEART1 is a frozen
   pool with 56 bytes of guard; at the wrapper's `PPP> 6` the four-colour smoke
   packed to ~9.9KB, ran 2,330 bytes past `0x752600` into SHAOSIT, and
   `makevrom.py` refused to write the chips. `PPP> 2` packs it at ~3.3KB. Six
   bits a pixel for four colours spends 12,945 pixels x 4 wasted bits.
4. **A new IMG palette takes three edits, not one.** `SMOKCID_P` needed its
   words in `IMGPAL7.ASM` (nothing promotes an IMG palette - read them out with
   `python tools/img_palette.py data/ACIDHANG.IMG SMOKCID_P`) *and* a `.globl`
   in `src/IMGTBL.GLO`, or the TBL's `.long SMOKCID_P` is undefined at link.
   And no `.ref` in MKHANG.ASM for the art labels: it includes ACIDHANG.TBL,
   which defines them, and GSPA rejects a symbol used in both REF and DEF.

## Still to do

- **A shadow on the body as it goes in.** Not started. Note the constraint
  before picking an approach: this stage deliberately clips floor shadows out of
  the acid - `shad_hi`/`shad_lo` in BGND.ASM pin the band to the stone walkway
  (screen 208..245) precisely so the rows that would land in the acid are not
  drawn - and widening it would put the FIGHTERS' shadows in the pool too. The
  acid-reflection system that would have been the natural home was removed
  (DEADPOOL_ACID_REFLECTIONS.md). So this wants its own dark silhouette copy of
  the body drawn behind it, in a shadow palette matching EHANG_p's bpp.
- `hanger_drip_enable` is 0 and must stay there until `hp_spawn_lift_drip` is
  actually written - body drips sheeting off the rising bones.
- **Seven of the nine hangers are still parked.** Bringing one up is: cut its
  body and skeleton into bands in the IMGs, pack them (see "Where Tony's art
  went" below), give it a `hanger_chunks` / `hanger_skel_full` list and a
  `hanger_body_strip_count`, measure its chain off its own WAX into the
  per-hanger tables, then set its `hanger_acid_live` row and gap and run the rig with
  `DP_HANGER=<n>` (`-Hanger <n>`). Ed (0) and Tony (2) are done, both 45/45:
  both on the schedule (`-Hanger 0` watches Ed).
  The rig tells two hangers' chains apart by column (they share the
  `longchain`/`TINCHAIN4`/`TINHOOK` art - taking whichever came first measured
  Ed's chain against Tony's body), and `hook_meets_chain` checks each joint
  against the one THAT body's WAX authors: Ed's connector ends 1 row into the
  hook, Tony's 7.

## John

From `data/JOHNHANG.WAX` (origin 200,20; every anipoint 0), measured off his
body's top-left: TINHOOK x+21 y-5, TINCHAIN4 x+24 y-70 (so 65 above the hook,
ending 5 rows into it - authored, and `hook_meets_chain` expects that -5, not
Ed's -1), and the WAX's longchain at x+5 is straightened like Tony's to x+23,
ending two rows into the connector (-274 off the hook). His legs centre at
x+25 - Ed's are at 24.9 - so his FX centre is Ed's 24. He hangs at world 600,
two places left of Ed on the sheet (an estimate - the sheet does not give an
exact column for him). 110 rows, crossline 78.

His art is `data/HANGJOHN.LOD` (body) and `data/HANGJOHD.LOD` (skeleton),
2,242 + 2,390 bytes in bank 0, in the slot NOOBFX held. **That space came from
turning Noob's added moves off** (`noob_extras .set 0`, MAINEQU.ASM - the
shadow slide, kick, dive, portal and teleport, and their NOOBFX/NOOBPORT art)
**and the Noob and Smoke VS portraits** (`vs_noob_smoke_pics .set 0` - they
show Sub-Zero's and Scorpion's pictures again, the fighters they unlock from).
About 90KB of bank 0 is free again: 25.5KB at 0x759060 (John uses the first
4.6KB), 50.8KB where NOOBPORT was, 14.3KB where VSSMMOV was.

## Geo

From `data/GEOHANG.WAX`: TINHOOK x+15 y-10, TINCHAIN4 x+18 y-75 (65 above the
hook, 5 rows into it, like John), the WAX's longchain at x-1 straightened to
x+17 (-274 off the hook). Legs centre x+20, so his FX centre is 19. 135 rows
- the tallest yet - so at y 46 his feet are at 181, seven rows over the
acid. Cut like John: A his left side full height, B a 14x46 piece on his
right (rows 84..130).

He hangs at world **230**, first on the sheet, at the left end of the pool.
The camera cannot go further left than worldtlx **183**, so he is always
within 47px of the left edge of the screen - he can only go in when the fight
has carried the camera all the way over, and he is seen at the edge when he
does. `starts_on_screen` passed at screen x 12.

His art is `data/HANGGEO.LOD` / `HANGGEOD.LOD`, 2,252 + 2,248 bytes, at the
bottom of the bank-0 run NOOBPORT held (0x78BA90).

## All nine: the illustration, spacing and heights

The rest came from `data/RESTHANG.WAX` - one slot that plays every remaining
body (and Geo, whose numbers match `GEOHANG.WAX` exactly, the check that the
WAX reads the same way) against ONE hook at (205,125) and TINCHAIN4 at
(208,60). So every connector is 65 above its hook and ends 5 rows into it,
each longchain is straightened over its connector, and each FX centre is his
legs' centre - 1 (the rule Ed, John and Geo follow):

| hanger | x | top | feet | hook | conn | fx | pieces |
|---|---|---|---|---|---|---|---|
| Geo 4 | 661 | 51 | 186 | +15,-10 | +18 | 19 | side by side |
| Mark 1 | 256 | 34 | 161 | +33,-8 | +36 | 30 | body + arm |
| Sal 6 | 445 | 72 | 180 | +13,-6 | +16 | 17 | side by side |
| Jeff 5 | 328 | 52 | 179 | +21,+5 | +24 | 21 | head + body |
| Steve 7 | 774 | 59 | 186 | +15,-3 | +18 | 21 | side by side |
| John 3 | 197 | 34 | 144 | +21,-5 | +24 | 24 | side by side |
| Eric 8 | 555 | 70 | 184 | +19,-4 | +22 | 18 | side by side |
| Ed 0 | 837 | 45 | 157 | +18,-8 | +20 | 24 | six bands |
| Tony 2 | 910 | 66 | 186 | +15,0 | +19 | 17 | three bands |

**x is EVEN**: Geo held at 225 (the acid's safe edge), Tony at 892, ~40px
between every pair of neighbours. Two other layouts were tried: the image's
x mapped straight onto the acid pushed Geo past the safe edge, and clamping
him back left him 6px from Mark; the image's own spacing, mapped between Geo
and Tony, kept the image's bunching on the left (and Jeff hangs on its empty
hook) - gaps of 20, 11 and 16px. Both read as a cramped left side.

**y is the illustration's ORDER** (drawn at game scale; tops 70..170): Mark
and John highest, then Ed, Steve, Eric/Tony/Sal, and Geo lowest; Jeff, not in
it, between Ed and Steve. Geo sets the range: he is the tallest body, so his
top cannot go below 51 without his feet going into the acid (feet <= 186).
All of them hang BELOW the life bars (34 at the highest), spread wide -
`34 + (t-70) * 0.45` - each clamped so his feet stay at or above 186. That
clamp holds tall Geo, Steve and Tony up, so Geo's head is not the lowest; his
feet are. Tried and dropped: heads above the life bars (Mark and John at 1),
and everyone squeezed above Geo's 51 (too little separation).

**The opening view shows three: Sal, Eric and Geo.** At rest the camera shows
world 373..773; those three are spread evenly across it (~72px from each edge
and between them). The other six hang wholly outside it and come into view as
the fight moves the camera - John, Mark and Jeff to the left, Steve, Ed and
Tony to the right - each group pushed out to the end of the acid (195..947)
to spread it as far as it goes: ~14px apart on the left, ~22 on the right.
Any wider and they would have to peek into the opening view.
`body_over_the_acid` checks his whole width against the acid.

**A body on a hook is never quite still** (`hp_idle_sway_a0`): every
`idle_sway_min + randu(idle_sway_span)` ticks - 10..25 seconds - a hanger
leans ONE pixel through `idle_sway_tab`, mostly hanging straight, then rolls
his next wait. **Each body moves differently**: his own lean length
(`hanger_idle_hold`: a step every 8, 16 or 32 ticks - ~2.3, 4.7 or 9.4s a
lean), his own first direction (`hanger_idle_dir`), and his own random wait,
so no two move alike or together. The skeletons on their chains do it too.
The step index is `(ticks done) >> hold` with a REGISTER count - and `srl
Rs,Rd` shifts by the NEGATED register: without the `neg` it shifted 28, every
step read as 0 and nobody leaned at all. The rig's `idle_swing` caught it (x
constant over 30s on five bodies) and measures a 1px lean now.

**They go dark on a fatality.** The hangers' palettes were in
`death_fade_excludes`, put there to keep them out of Raiden's victory dim - but
that one list is shared by `death_blow_fader` (every fatality and babality)
and `raiden_dimmer`/`raiden_undimmer`, so they hung there lit while the stage
went dark around them. They are in `raiden_dim_excludes` now (MKGUYS.ASM), a
list that FALLS THROUGH into `death_fade_excludes`: Raiden's faders pass it
and skip the hangers plus everything else, the fatality fade passes
`death_fade_excludes` and darkens them. Measured on Jax's arm rip in the Dead
Pool: Steve's bright magenta pixels went 258 -> 0 once the fade ran (they held
at 258 all the way through before), and every hanger dims with the wall while
the fighters, blood and HUD stay lit. `tools/audit_fade_excludes.py --check`
still passes (every costume palette excluded).

**They swing on the way down** (`hp_sway_a0`): +-3px over one `sway_tab`
cycle of 16 fall moves (~1.2s), halved once the acid has his feet, and back on
his column when he goes under - the splash, the bubbles and the bones are all
built on it. The chain and hook swing with him: `hp_update_chain` used to lock
the hanging body's chain to the drop point once he was past the waterline,
which with a swing would have left the chain behind, so only the skeleton
locks now. The rig's `fall_swings` wants his x to move, stay within +-3, and
come back to his column; `chain_never_jumps` allows the swing.

**The late drip up by the hook was only fixed by luck.** `lift_drip_stop_band`
was 8px, and whether the last drip of a rise starts high depends on which of
the eight `lift_drip_yofs` spots comes round last - Ed's runs landed a low
one, Mark's (hung higher) drew the 8 and started a drip at world 45, seven
rows under his top. It is 24 now, and the rig's threshold is his own top + 14
instead of Ed's old 60: the highest drip starts at y 101-105 on all nine.

Things this turned up:

- **Eric drew in Ed's colours.** MKHANG.IMG named his palette `EHANG_p`,
  the same as Ed's, with different colours. It is `ERIHANG_p` now (the user
  renamed it in the IMG; `IMGPAL7.ASM` / the `.GLO`s follow); his skeleton
  palette `ERICDED_P` was missing and is added.
- **Steve's shirt is magenta in the art.** `SVHANG_p` renders it that way
  straight out of the IMG, so the game is faithful; the illustration has it
  red. An art fix, not a code one.
- **The respawned skeleton's layer.** A body that went in earlier comes back
  as his skeleton - which used to start on the hanging layer (-2) for a frame,
  putting the hook in front of the bones. It starts on `acid_skel_z` now.
- **The rig's clock hold never held.** `clk_tens`/`clk_ones` are the display
  copy; the round clock lives in the master process's registers. With nine
  bodies queued the round timed out (game over, on equal health) in the
  middle of the drop being watched. `-ClockJump` now sets `f_freeze_timer`,
  the training-mode switch.
- **The rig's column windows** are the art's own now (body at his x, chain
  rig 0..45 right of it, FX within 34 of his FX centre, the wide splash
  further left), and the cut height is read off the piece reaching lowest -
  Mark's arm piece held its 39 rows while his body was being eaten.

**A body hung at the top of the world never finished rising.** The rise
steps 3px up and stops once it is past his hang height - and the step was
`zext`-ed. Mark and John hang at y 1, the last step takes them to -2, zext
made that 65534, "past his hook" never came true and the pull-up ran forever
holding `hp_drop_busy`, so no other body could go in either (Ed's run showed
that: he never got a turn). It is `sext` now, in the step and where the rise
loop reads the height back. Nothing hung high enough to reach 0 before.

**Tony's body pack moved.** It sat in bank 1 right after MK6MIL, placed
against an MK6MIL 270 bytes shorter than the committed one; on the next full
LOAD2 build the two overlapped by 200 bytes and the inline-SAG check's flat
ROM refused it. Every build here after the pack was placed had been
`--asm-only` against the old IRWs, so none of them saw it. It is in bank 0 now,
above Steve's pack at 0x796A90. After touching any pack, check overlaps on a
FULL build, not an asm-only one.

Art: Mark/Jeff/Steve are one pack each (body + skeleton) up the run NOOBPORT
held, Sal/Eric in the slot VSSMMOV held: `data/HANGMARK/JEFF/STEV/SAL/ERIC.LOD`,
23.3KB in all. All nine pass 46/46 with `-ClockJump -NextRound`.

## Where Tony's art went, and the three traps on the way

His bands are six records - TONYHANG1A/B/C out of MKHANG.IMG (3 x 40 rows of a
120-row body) and DTONYHANG1A/B/C out of ACIDHANG.IMG (3 x 41 of 124) - and
**neither library's own wrapper had room for them**: MK7MIL has ~1.5KB after it
and MOVEART1 is a frozen 96KB slot with 56 bytes of guard, against ~2.9KB a
body. They live in two sidecars of their own, `data/HANGTONY.LOD` (body, bank 1
in the run after MK6MIL, the bank Ed's EDHANG1 bands are in) and
`data/HANGTNYD.LOD` (skeleton, bank 0 in SHASLAM's tail, the bank his DEDHANG1
bands are in). A SAG is absolute, so nothing cares which wrapper a record's
pixels came out of.

1. **The 15KB after MK4MIL is not free.** It is the obvious home - it is the
   largest run in bank 0 and `tools/rom_space_report.py` lists it as free -
   and it is `SKSOUL1`'s slot, another session's staged pack. Growing MK4MIL
   into it made `makevrom.py` refuse to write the chips, naming both the base
   drift and the overlap. That check is the reason this cost twenty minutes
   instead of a wrong ROM.
2. **A multipart piece record has to carry its own palette long.** The first
   pass packed under `POF>`, so LOAD2 wrote six records with no PAL field - and
   a record without one reads the NEXT record as its palette. Both sidecars are
   `PON>`. Worse, the promoter hid it: `promote_tbls.py` merges by label and
   patches sizes/SAG/ctrl, and there is no line to patch for a palette that is
   not there, so a rebuild that HAD the palettes left the palette-less copy in
   `src/`. Both tables are in `GENERATED_TABLES` now and are copied verbatim.
3. **A stale record keeps its SAG.** `src/MKCHUNKS.TBL` still held 126 records
   for the retired 10px hanger strips - every developer's body, plus
   EDBODY/EDLEG/EDHEAD - art that both IMGs stopped carrying when they were
   re-cut. Nothing includes that table (it is a LOAD2 snapshot) so they
   assembled into nothing and cost nothing, until `HANGTONY.LOD` started
   exporting the real `TONYHANG1A-C`: three of the stale records claimed those
   labels with addresses in MK7MIL and `tools/check_sag_coverage.py` failed the
   build. They are deleted.

## Related

- [DEADPOOL_EDACID_ANIMATION.md](DEADPOOL_EDACID_ANIMATION.md) — the EDACID /
  EDCHAIN lane wiring and the 12 fps tick
- [DEADPOOL_HANGER_HANDOFF.md](DEADPOOL_HANGER_HANDOFF.md) — the chain-gap and
  progressive-subframe history
- [DEADPOOL_STAGE_FATALITY.md](DEADPOOL_STAGE_FATALITY.md) — the *player*
  going into the pool, which is a different mechanism entirely
