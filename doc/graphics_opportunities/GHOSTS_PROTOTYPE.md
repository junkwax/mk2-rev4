# Constant-colour fighter ghosts (`ghost_rec`)

**Status: implemented and validated in MAME, 12 September 2026.** This covers
opportunity 16 (silhouettes, echo trails, charge ghosts) and §6.1 of
[the graphics audit](../GRAPHICS_OPPORTUNITIES.md). It is **compiled in but
off at run time**: nothing happens until a producer writes `gh_src`. FBNeo and
physical hardware have not been run.

**Verdict:** it works, and it is cheaper than the trail the game already has.
Any fighter can have afterimages. Each ghost costs its blits and nothing
else: no object from the pool, no process, no palette slot and no authored
palette.

![Liu Kang walking right: left, no ghosts; right, four ghosts 3 ticks apart - blue, purple, hot purple, dark red - behind him and over the floor. Both fighters are untouched.](ghosts_pair.png)

## What was there, and what it cost

`trail_proc` ([MKFX.ASM](../../src/MKFX.ASM)) draws Cage's shadow kick and
shadow punch and Kahn's shadows. Each shadow costs:

| | per shadow |
|---|---|
| Object | one, from the 358-object pool |
| Process | one **whole process** (`shadow_dummy_proc`), used only as RAM for the shadow's multipart pieces, plus the `trail_proc` process itself |
| Palette | an authored full-colour shadow palette: `green_cage1_p`, `red_cage_p` or `white_kahn_p`. **Only Cage and Kahn have one**, so no other fighter can trail |

The stock trail is 7 shadows (8 for Kahn), so it holds 7–8 objects and 8–9
processes while it runs.

## How `ghost_rec` does it

| | |
|---|---|
| Code | `ghost_rec`, `ghr_slot`, `ghr_copy` ([MKDISP.ASM](../../src/MKDISP.ASM)), called at the top of `display` |
| List | `ghost_lst`: an ordinary display list, named in `dlists_battle` ([BGND.ASM](../../src/BGND.ASM)) between the `-2` shadow marker and `objlst` |
| Inputs | `gh_src` (the *address of* `p1_obj`/`p2_obj`, 0 = off), `gh_n` (1–6), `gh_gap` (ticks), `gh_col[6]` (pen per age) |
| Storage | a `.bss` ring of 7 slots, each an object block plus 13 pieces of its own: 14,672 bits |
| Switch | `ghosts .set 1` ([MAINEQU.ASM](../../src/MAINEQU.ASM)) |

- **Snapshots.** Every `gh_gap` ticks the fighter is copied into the next ring
  slot: the object fields `dclipl` reads, plus his whole multipart chain (sag,
  size, control word with flips merged, dx, dy), so the ghost is exactly his
  pose at that moment.
- **Drawing.** The ghost's `oflags` are the fighter's with `dmacnz`, so every
  pixel the art writes comes out in `oconst`'s pen. `opal` is 0, `boonpal`,
  which is pinned for the life of the machine, so there is nothing to
  allocate.
- **No new draw path.** The slots are linked oldest first onto `ghost_lst`,
  and the stock walker and clipper draw them. They land behind the fighter,
  who is drawn later from `objlst`, over the floor and its shadows, and the
  newest ghost sits on top of the older ones.
- **The newest snapshot is never linked.** It is this frame's pose, exactly
  under the fighter, so the ring is `gh_n + 1` and ages 1..`gh_n` are drawn.
- **Following the fighter.** `gh_src` names the pointer, not the object, so a
  new fighter object next round is followed rather than a freed one. Zeroing
  `gh_src` or `gh_n` empties the list on the same frame.

## Result

THE WASTELAND, Liu Kang (P1) against Johnny Cage, both visible. P1 walks
right, then left. There are two boots on one frozen ROM with identical inputs.
The ghosts (4, 3 ticks apart) are armed from rel 300 to rel 560, with
snapshots every 10 frames and two after disarming.

| Gate | Result, 26 snapshots |
|---|---|
| Every changed pixel is a ghost pen (exact RGB from colour RAM) | **0** exceptions in 87,649 changed pixels |
| Ghosts actually drawn | 1,916–5,177 px per armed snapshot; the list holds 4 once the ring is full |
| No object taken | free objects equal between the boots at **every** snapshot |
| No process taken | free processes equal between the boots at **every** snapshot (160/160) |
| Nothing persists | both disarmed snapshots pixel-identical to the unarmed boot |
| Cost | DMA queue peak +16 cells (576 → 672 words), `peak_overload` 2 in both boots, `dmaq_late` 0 |

## The rig finding

The first run "failed" catastrophically: about 48,000 pixels differed, with
Liu Kang frozen mid-air and the free-object counts diverging. It was not the
ghosts. A per-frame trace showed the two boots had diverged **before**
arming. A control of 8 unarmed boots, 4 on this ROM and 4 on the strips ROM
with no ghost code, reached **three different fight starts**. The attract and
select automation is scheduled on Lua frame callbacks, and under load that is
not deterministic.

The runner now logs a `PREARM` line (both fighters' x, the camera and the
free-object count) at rel 299. It re-boots a pair that did not start
identical, and `--rejudge` refuses one. **Any rig that compares boots needs
the same check.** The earlier palette-rect and strips comparisons matched
without it, but that was not guaranteed.

## A finding outside the prototype: `.bss` the power-up clear misses

`clscrach` ([MKINIT.ASM](../../src/MKINIT.ASM)) zeroes 0x8000 longs from
`scratch`: 01000000–01100000. `.bss` now runs to `end` at **0111faf0**, so 53
symbols are never cleared at power-up. They include the sound channel state
`chan1pri`..`chan3dur`, `hanger_coords`, `peak_rain_ram`, `cave_eyes_ram`
and the string buffers. MAME zero-fills RAM, so no emulator run can show it;
on a physical board those start as whatever the RAM holds. The ghost
variables sit well inside the cleared range.

**Fixed the same day.** `clscrach` now clears from `scratch` through the
linker's `end`. None of the 38 variables above the old line was meant to
survive the clear: they are runtime flags, sound channel state, and
coin/audit scratch, from modules that link late. In the shipped game's
smaller `.bss` they sat inside the cleared range.
`tools/run_clear_test.py` proves the fix in MAME. It seeds 01100000..`end`
with a pattern and soft-resets, so POWERUP runs over dirty RAM. The old ROM
left **8,114 of 8,115** pattern words in that band, and the fixed ROM leaves
**0**. A control band below 01100000 is clean on both
([receipt](scratch_clear_results.json)).
`tools/check_stack_clearance.py --check` (Phase D) now fails if the clear
stops covering `.bss`. Pointed at the old `clscrach`, it fails; on the fixed
one, it passes.

## Shipped on Liu Kang's bicycle kick (15 September 2026)

The user chose to make the ghosts a real feature. Liu Kang's flying bicycle
kick now trails 4 afterimages, 3 ticks apart, in blue, purple, hot purple and
dark red.

| | |
|---|---|
| Producer | `do_bicycle` / `bike_call` ([MKPROP.ASM](../../src/MKPROP.ASM)): `ghost_arm` on the first flight tick, `ghost_disarm` at contact (hit or blocked) and on landing after a whiff |
| API | `ghost_arm` (a8 = the fighter, a0 = lifetime) and `ghost_disarm` (a8), in [MKDISP.ASM](../../src/MKDISP.ASM) next to `ghost_rec` |
| Lifetime | new `gh_life`: `ghost_rec` counts it down and disarms at 0, so a round end that takes the fighter's process cannot leave a trail running. 0 still means no limit, for rigs that arm by hand |
| Stages | `ghost_lst` is now in every fight stage's display list, just before `objlst`, as in `dlists_battle`: Portal, Arena, Bridge, Tomb, Tomb ceiling, Dead Pool, Tower, Forest, Armory, FLAPJACK, MK1 Pit, Yoteigai Tor, Goro's Lair ([BGND.ASM](../../src/BGND.ASM)) |

Two decisions came out of the first MAME look:

- **The trail is the flight only.** A hit becomes a 48-tick punching-bag loop
  in place, where ghosts would only stack on him, so contact ends it.
- **Arm on the first flight tick, not at the top of `do_bicycle`.**
  `flight_call` only sets the kick animation up; the first snapshot after an
  arm at the top of the move caught him still standing, and left a full
  stance silhouette at the take-off spot. `bike_call` runs just before
  `next_anirate` draws the first kick frame, and `a11` (its collision-free
  count) is 6 only on that first call.

**MAME** (`tools/bike_ghost_test.lua`, runner `tmp/hitlight/run_bike_ab.py`).
Two-player boots, P1 Liu Kang against an idle Jax. Each boot runs three kicks:
from 380 px (whiff), from 110 px (hit), and from 110 px into a held block.
Each boot is paired with an identical one that writes `gh_n = 0` every frame,
and the pair must start identically (PREARM).

| Gate | Result, 8 stages (Dead Pool, Tomb, Tower, Forest, Portal, Arena, Outer Haven, Wasteland) |
|---|---|
| Every trial arms, draws and disarms | 24/24. The whiff shows 4 ghosts and disarms on landing (rel 30); hit and block show 1 and disarm at contact (rel 12); `gh_src` 0 at the end |
| Every changed pixel is a ghost pen | **0** exceptions in 43-44 K changed pixels per stage |
| No object or process taken | free-object and free-process counts equal to the trail-off boot at all 45 sampled frames on every stage |
| First ghost is a kick pose | yes (`tmp/hitlight/bike_trail_st0_fixed.png`) |

The combined build, with the default-on hit light plus this, passes the
27-battle stability sweep 27/27.

## Two more producers: Raiden's dive and the slide (15 September 2026)

| Move | Fighters | Arms | Disarms | Lifetime |
|---|---|---|---|---|
| Bicycle kick (`do_bicycle` / `bike_call`) | Liu Kang | first flight tick (`a11` = 6) | contact, or landing after a whiff | 64 |
| Torpedo dive (`do_raiden_dive`) | Raiden | just before the `dive3` strike loop, velocity already running | `dive_hit` (covers hit **and** blocked: a block reaches `dive_blocked` through it) and the whiff's `stop_me` | 48 |
| Slide (`do_slide`) | Sub-Zero, Kitana, Mileena, Jax, Noob | first pass of the `slide4` STRIKE loop | `slide_is_over`, which every path funnels through | 32 |

**Arm where the new pose is DRAWN, not where the move starts.** This cost three
attempts across two moves. A move sets its animation up and the first frame
only reaches the screen later - `flight_call` draws after its callback, and
`do_slide`'s lane runs 4 ticks a frame, so its first 8 ticks are still the
upright crouch (`NJSLIDE1`). Arming too early snapshots the *previous* pose:
the bicycle kick left a standing silhouette at the take-off spot, and the
slide stacked four standing Sub-Zeros over him. The fix in both cases is to
arm inside the loop that draws the travelling frames.

**MAME** (same rig and runner as above, `BG_MOVE` picks the producer and
`BG_CHAR` its owner):

| Run | Result |
|---|---|
| bike / dive / slide × whiff, hit, block × 2 stages | 18/18 trials arm, draw 4 ghosts (1 when a close kick connects early) and disarm themselves |
| Non-ghost pixels | **0** across every run |
| Objects and processes | free counts equal to the trail-off boot at all 45 sampled frames, every run |
| Stability sweep on the final build | 27/27 |
| Look | dive: an afterimage stretched behind Raiden. slide: the low sliding pose behind Sub-Zero (`tmp/hitlight/slide_trail_v2.png`) |

**A rig lesson worth keeping.** Two runs reported "never armed" for the dive
and slide while the feature worked: the rig only watched for arming in a phase
that began 150 frames after the inputs, and those moves fire immediately
(the bicycle kick fires on *release*, which is why it alone passed). Tracing
the raw state showed the trail arming and clearing exactly as intended. The
rig now tracks the trail in every phase and hangs its snapshots off the arm.
Before that, the inputs themselves were guessed twice and wrong; the real ones
come from `combo_edit.py` and the button-bit equates (b0 HP, b1 LP, b2 BL,
b3 HK, b4 LK): the dive is Back, Back, Forward + LK **airborne**, and the
slide is away + Block + Low Punch + Low Kick together.

## The stock shadows are NOT worth swapping (15 September 2026)

`trail_proc` (MKFX.ASM) is created at eight sites: Kahn's air knee and
shoulder charge, and Cage's shadow kick, back+HP punch, shoruken and ceiling
kick. Per shadow it spends **one object**, **one whole process**
(`shadow_dummy_proc`, created only because its `pdata` is the piece RAM) and
an authored palette swap - `green_cage1_p`, `red_cage_p` or `white_kahn_p`,
which is why only Cage and Kahn can trail at all. Kahn asks for 8 shadows,
Cage's kick 7, his back+HP 5. Ghosts cost none of that, so the swap looks
attractive on paper.

**Measured, on the installed ROM, no rebuild**
(`tools/cage_shadow_ghost_demo.lua`, stock vs a mode that sends every
`pid_trail`/`pid_jc_shadow` process to `sucide` and arms `ghost_rec` instead):

| | free processes during the kick | free objects |
|---|---|---|
| stock | 151..159 | 270..287 |
| ghosts | **156**..158 | 269..286 |

So about 5-8 processes come back. The object column proves nothing here: the
demo kills `trail_proc` after it has already made shadows, orphaning them, and
a real swap would never create them.

**Recommendation: leave the stock shadows alone.** The pools are not under
pressure - the busiest measured fight peaks at 35/168 processes and 46/358
objects - and the visual cost is high: stock draws green full-colour copies of
Cage, and constant-colour ghosts flatten his signature move into blue and
magenta silhouettes (`tmp/hitlight/cage_shadow_vs_ghost.png`). The ghost path
is the right tool for moves that have no trail at all, which is where it has
been used.

## Known limitations

- Wasteland only. Every stage that wants ghosts needs the `ghost_lst` entry in
  its dlist.
- One fighter at a time. Two trails would need a second ring and list.
- The pens are `boonpal`'s 16. A graded ghost in the fighter's own tint would
  need an owned palette ([the hit light](HITLIGHT_PROTOTYPE.md) shows how);
  the constant-colour version needs none.
- A producer (a move, a charge, a teleport) still has to be written. The rig
  arms it directly.

## Reproduce

```powershell
python build.py --asm-only; python makerom.py
python mamerom.py --no-install --output tmp/ghosts/rom/mk2.zip
Copy-Item src/mk2.map tmp/ghosts/mk2.map
python tools/run_ghost_test.py --rom-dir tmp/ghosts/rom --map tmp/ghosts/mk2.map
```

`GH_DIAG=1` adds the per-frame trace around the arm point. `--n` and `--gap`
change the trail.

## Files and evidence

- [Recorded results](ghosts_results.json), including the 8-boot
  nondeterminism control, and [the pair](ghosts_pair.png).
- [Rig](../../tools/ghost_test.lua), [runner](../../tools/run_ghost_test.py).
