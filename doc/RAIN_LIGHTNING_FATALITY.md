# RAIN's lightning fatality

**Down, Down, Back, Forward + HIGH KICK**, in FINISH HIM, within `rnf_maxdist`
(0c0h). MK Trilogy's own input for his second fatality — `sm_rain_hkc` ->
`do_fatality_2` -> `rain_bolt_strikes` (MKFATAL.C, the N64 source).

Code: `src/MKRAINF.ASM` (all of it), `rain_hi_kick` + `scom_rain_db2`
(MOVES.ASM, the input), `rainfatal` (MAINEQU.ASM, the switch). Rig:
`tools/run_rain_fatality_test.ps1 [-Victim all] [-SnapEvery N] [-Stage N]`.
`-Stage` forces `curback`; **4 is THE LIVING FOREST**, the stage the palette
faults showed on, and the one to re-check after touching `rnf_light` - it has
a big lit floor and background props where the Dead Pool has neither.

## One bolt, built the way lightning is

The finale is ONE bolt, modelled on high-speed footage of lightning striking
buildings: Saba, da Silva, Pantuso & da Silva (2022), *Close View of the
Lightning Attachment Process Unveils the Streamer Zone Fine Structure*,
Geophysical Research Letters, doi:10.1029/2022GL101482 (Phantom v2012 at
40,000 frames/s). What the paper shows, and where each piece lives:

| the physics | in the game | code |
|---|---|---|
| a **negative stepped leader** comes down out of the cloud in short jagged steps with pauses between | the main channel steps every 6-9 ticks, 2-5 px down and leaning at him, from just under the life bars | `rnf_step_main`, `RNF_STEP`, `RNF_DROP`, `RNF_LEAN` |
| it **branches**, and the branches are attempts that die | a branch starts one step in four, grows 6 joints sideways and down past the fighters' heads, and stops | `rnf_new_branch`, `rnf_step_branches` |
| every tip wears a **streamer zone** - the fine brush the paper resolves | a fan of short filaments ahead of each growing tip, re-rolled every tick so it shimmers | `rnf_draw_brushes`, `rnf_brush_at` |
| the field lifts **upward positive leaders** off every high point (31 in the paper) | seven: off the man's head, off RAIN's head, and off the floor either side; the others first, his last | `rnf_try_launch`, `rnf_up_origins` |
| exactly **one connects** and the rest **abort** | only his (slot 0) can attach; at that tick every other one is gone | `rnf_try_attach`, `rnf_attach_now` |
| the **return stroke** lights the joined channel | a heavy 5-strand stroke, the play-area strobe, the stage flared and the ground shaken - and he splits | `rnf_return_stroke`, `rnf_draw_bright` |

The playfield only has ~50 px of sky between the life bars and a standing
man's head, so the build-up cannot be in height. It is in **time** (the
pauses) and in **slant**: the cloud starts 80-112 px off to one side, and
while the leader is more than `RNF_NEAR` (40) px to the side of him it
mostly travels (drops 2-3), only coming down properly once it is over him.
About two seconds from the first step to the strike.

Attachment asks two things: the leader must be within `RNF_ATTACH_X` (20)
of being over him AND down to his upward leader's tip - or it is forced once
it reaches his head height (a leader never passes the man it is going for).
The process also forces it at the end of `RNF_LIFE`, and the director has
its own ceiling (`RNF_WAIT`) on top of that.

## Everything else on screen

* **The dark.** `init_death_blow`'s own fade is only a dim: `death_blow_fader`
  kills its fadeprocs after 10 of `fadeout_tab`'s 16 ticks, which leaves
  **every** palette - background, props, gore - at entry 10, `40/128`. That
  number is `RNF_LT_REST`, and the storm is written around it. `rnf_lt_dark`
  **starts there** and takes the BACKGROUND palettes on down to 1/8.
  * It used to start at `120/128`, which was a bug you could see: by the time
    the arms are up the stock dim has already run, so re-fading from the top
    threw the whole stage back up to near daylight for half a second before
    it fell again. Measured off the rig's capture, the dominant scale over
    the scenery went `128, 108, 91, 66, `**`116`**`, 79, 46, 24, 11`. It is
    now monotone: `128, 91, 61, 29, 21, 16, 11`.
* **The storm passes WITH THE STORM, not after it.** `rsv_tail` splits its
  `RNF_S_POP` wait: `RNF_S_RELIGHT` (018h) ticks to let `rnf_lt_final`'s
  19-tick flare land, then `rnf_lt_rest` back up to `RNF_LT_REST`, then the
  rest of the wait. Total timing is unchanged. Everything after the last bolt
  - the burst, the gore, the victory pose - therefore sits in exactly the
  light every other fatality in the game has.
  * The relight is about the STAGE, not the gore - see the next bullet for
    what the gore needed, which is a different routine and was found later.

* **It lights the whole STAGE, not just the background blocks.** `rnf_light`
  walks all of `palram` and skips `death_fade_excludes` - the same set
  `death_blow_fader` dims for every other fatality in the game. It used to
  walk `bpalram` only (the `bgnd_dim` walk), on the reasoning that the
  fighters, the bars and the toasts live in `fpalram` and so could never be
  bleached by a flash's above-128 multipliers. But **a stage is not only its
  background blocks**: `setup_floor_info` (BGND.ASM) takes the FLOOR's palette
  from `getfpal`, and every background-list prop is a `gso_dmawnz` object, so
  those are `fpalram` too. The storm took the scenery to 1/8 and left the
  ground and the props where the stock dim had got to.
  * On **THE LIVING FOREST** that is unmissable, and it is what the bug was
    reported against: a big lit floor, and three mad-tree faces (`tree_animator`,
    BGND.ASM) drawn as opaque rectangles over the trunks. Clustering the
    per-pixel scale at the gather gave three populations - `11/128` over the
    trees, `59/128` over the floor and the faces, `128/128` for the HUD and the
    two fighters - so it read as a glowing floor and a bright square of bark
    hanging in a black wood. Afterwards there are two: the stage, and the
    excluded HUD and fighters.
  * What must stay lit is not "`fpalram`", it is `death_fade_excludes`. That
    list is already load-bearing - if it were missing a costume the fighters
    would dim in every fatality in the game - so this reuses the game's own
    answer rather than inventing a second one. The floor, the props and the
    gore move with the stage, which is what lightning does to them.
  * It costs nothing measurable. Same 80-slot walk on every flash, on the
    forest: `palq_drops +0`, `dma late +0 lost +0`, `peak_overload 34` -
    identical to the `bpalram`-only version.  * **AND ONLY THE STAGE THAT WAS THERE WHEN THE STORM BEGAN.**
    `rnf_pal_snap` records the palette set on the FIRST `rnf_light` call, and
    every call after it re-drives that same set: a slot that was empty then,
    or has been re-let since, is not the storm's to touch. This is what makes
    the storm behave like the stock dim, and it is **not** an optimisation -
    it is the whole difference between the two.
    * `death_blow_fader` (MKDEATH.ASM) is a **one-shot**: it fades, sleeps
      10, `dallprc`s every `pid_fade` and dies. From tick ~10 of any other
      fatality in the game, nothing dims anything ever again. **Gore is
      created hundreds of ticks later** - `exp_burst` -> `change_to_bloody_pal`
      (MKDIE.ASM) - so `getfpal` queues it from ROM at full brightness and it
      stays there. That is what a finisher's body parts look like.
    * `rnf_light` is not a one-shot: it runs on the dark, on all 14 bolt
      flashes and on the relight, every one of them AFTER the split. Re-
      walking the LIVE palette set therefore caught the chunks and dragged
      them to `RNF_LT_REST`, and the body parts came out dim in a way they do
      in no other fatality.
    * It was **reported twice from play before it was found**, because
      against a stage at that same 40/128 dim gore reads as consistent rather
      than as wrong, and because the first look at it - a ninja victim, whose
      blood palette IS in `death_fade_excludes` and so was never touched by
      either fader - showed the opposite symptom and sent the search the
      wrong way. `BLOOD_STAYS_LIT` was never the cause and is untouched.
  * The exclusion scan runs on the first call only; the snapshot carries it
    forward. Measured after: `palq_drops +0`, `dma late +0 lost +0`,
    `peak_overload` 34/32, unchanged.

* **The light.** The strike re-fades them with `rnf_lt_final`, whose
  multipliers start ABOVE 128 (fadepal clamps per channel, so >128 is
  brighter than the art was authored) and fall back to the dark level - not
  to 0: the stage is still there. Peak 200, not 255: bleach the wall and the
  bolt has nothing to stand out against. Only `bpalram` is walked (the
  `bgnd_dim` walk), so fighters, bars and toasts never flare.
* **The sky** (`irqskye`) pulses blue-white; **the strobe** is the block-fill
  flash over the play area (`flash_col` / `flash_back` 0 / `flash_ticks`).
  The band list `arm_flash_band` is NOT usable: it is inside `.if fxdemo`.
* **The man** starts jolting on the tick the first bolt **lands**, and never
  before it: his own shocked frames (`shocker_info`, the ones Raiden's fry
  uses), the electrified palette, a sideways shake.
* **The ground** keeps a splash and a scorch where it hit (`rnf_scorch_proc`,
  his B,B+HP bolt's ground art).

## The man while the bolts are on him (`rnf_victim`)

He is **held, not animated**. The first strike stands him on the FIRST frame
of his own stumble lane (TABLE1 row `023h`, STUMBLE1 — every fighter carries
it) where he stood, and that is the pose for the whole salvo: no further
frames, and he is never turned round. What moves is the current in him:

* the **electrocution palette cycle** Raiden's grab uses (`shockcyc`,
  `shocker_shaker` MOVES.ASM) — FREZ, ELEC, WHITE, BLACK, a beat every
  `RNF_CYC_BEAT` (3) ticks — running **continuously** from the first strike to
  the split, never back to his own colours in between;
* a **1 px buzz**, `RNF_JIT_X` each side of where he stood, a side per tick
  (`rv_jitter`). It is measured from `p_store1` every tick rather than added
  to, so it cannot drift over the ~200 ticks the salvo lasts;
* **smoke** off the body from the first strike (`rnf_body_smoke`): one stock
  `smoke_a_1` puff every `RNF_BSMOKE_GAP` (5) ticks, the same puff and density
  the two halves get afterwards (`rnf_smoker`, `smoke_a_guy`). It re-reads
  `p1_obj`/`p2_obj` before every puff and stops on `rnf_split`, because
  `smoke_a_1` walks a11's multipart chain and `r_shocker_pop` sets the body
  inviso and bursts it — `rain_bolt_smoke` (MKZAP.ASM) has the same guard for
  the same reason.

### Nothing happens to him until a bolt lands

`rv_lp` gates every one of those on **`@rnf_struck`** - the one-shot the first
strike sets in `rnf_sbolt_hit` - and `do_rain_fatal` clears it on the way in.
It used to gate on a CHANGE in the strike COUNT, `@rnf_bolts`, and **nothing
cleared that count**: `rnf_salvo` zeroes it, but not until after the arms are
up and `RNF_GATHER` has run, and `takeover_him` has had the victim watching
since before the arms moved. So the SECOND Rain fatality of a session opened
with the previous one's 14 sitting there, `rv_lp` read it as a strike on its
very first tick, and he stood on STUMBLE1 and fried - palette cycling, buzzing
and smoking - through the arms going up and the whole gather, with nothing in
the sky. The first one of a session looked right, because `.bss` starts at 0.

`do_rain_fatal` now clears `@rnf_bolts` too, and `rnf_bolts` is declared with
the rest of the state it clears rather than 170 lines further down beside
`rnf_salvo`, which is how it came to be missed.

The rig proves it rather than assuming it: it **seeds** `@rnf_bolts = 14` at
FINISH HIM (`RNF_SEED_BOLTS`, on by default - a single rig run can never reach
a second fatality, so the leftover has to be planted) and counts x
ALTERNATIONS while `rnf_struck` is still 0. Fixed: 0, on all twelve victims.
The control - the count gate put back - is 29.

Gating on `rnf_struck` also fixes the shelved CPU-drawn version for free:
nothing in the `rnf_geo 1` path ever increments `rnf_bolts`, so under it the
victim would never have jolted at all. `rnf_attach_now` sets `rnf_struck`.

It used to walk the stumble lane a frame at a time and `flip_multi` him on
**every** strike, which read as the man flailing about rather than being
fried. The rig's per-tick line is the proof either way — through the new
version the victim's sag and `oflags` never change and x alternates
`base-1` / `base+1`:

```
ZAP + 44 zap=512 victim x=638 y=77 z=4f fl=8012 ffa14310
ZAP + 45 zap=512 victim x=636 y=77 z=4f fl=8012 ffa14310
ZAP + 46 zap=512 victim x=638 y=77 z=4f fl=8012 ffa14310
```

## The split plays on every victim's own art

`data/RAINSPLIT.WAX` is authored on the ninja: two visible slots on
`NINJAS11.IMG`, `NJDECAPLEG1-7` (legs) and `NJRIPTORSO1-6` (torso).
`tools/rain_split_wax_import.py` turns them into two template lanes in which
every frame is a PLACEHOLDER:

| placeholder | what it means | where it is found at run time |
|---|---|---|
| `0100h+n` | his `DECAPLEGn` | row 039h (`a_torso_ripped`), at `rnf_legpos`'s part/row |
| `0200h+n` | his `RIPTORSOn` | row 041h (`a_swipe_torso`), part 1, row n-1 |

`rnf_build` copies a template into RAM at the split and swaps each
placeholder for the victim's own frame; the flips and offsets are ordinary
animation commands, so `do_next_a9_frame` applies them. The importer's
`--check` (Phase D) re-reads every fighter module and fails the build if
either row stops carrying the frames.

## The budget - two limits, both measured

**1. `geo_list` is 192 segments a frame and it is SHARED.** `hudtext` draws
the HUD's words through it, and `geo_seg` drops whatever does not fit,
silently. A seven-strand return stroke put it over for the whole afterglow
and the HUD lost letters. `geo_full` (MKDISP.ASM) now counts every segment
dropped for a full list, and the rig FAILS if it moves. Hence: fingers climb
6 joints, brushes are 5 filaments at the leader and 2 at each finger (each
finger's brush on alternate ticks), and the return stroke is 5 strands.

**2. Pixels cost frame time.** `geo_pass` plots every pixel in software with
interrupts off, after draining the DMA. When the frame overruns (`overload`
3), the bolt process has not re-queued its lines before the display draws,
and **that frame has no bolt** - a blink. The rig logs `overload` every
frame of the build-up. Measured on the final build: the growth phase is
drawn one strand wide (the heavy weight is kept for the strike), branches
grow 6 joints; the first overrun moved from +94 to +113, and what remains is
roughly one blinked frame in five over the last half-second, when the
geometry is at its largest and he is jolting. It reads as the leader
flickering, which real stepped leaders do - but it is an artifact, and the
next cut is fewer fingers or branches.

Final numbers, one whole fatality against Jax on THE DEAD POOL: geo list
full +0, page-guard drops +0, palette-queue drops 0, dma late 0 / lost 0,
`peak_overload` 31 (baseline 4).

## Traps this hit

* **A build packaged against the PREVIOUS `mk2.out`.** DOSBox finishes
  writing `mk2.out` after `build.py` returns, so `build.py && makerom.py`
  can package the old link. The rig refuses a `mk2.zip` older than
  `mk2.out`; run `makerom.py` as its own step and check the times.
* **A Python splice that anchored on `rnf_try_launch\n` hit the `callr` to
  it first.** Anchor on the label at the start of a line.
* **Sampling a flag every 15 ticks missed a 14-tick event every time** and
  read as "the victim never reacts" - log every frame the flag is set.
* **The rig needs the ROM-warning dismissal loop** (PostMessage o/k/space/
  enter, as the sai-split rig does); without it MAME parks on the red box and
  the lua log is never even created.
* `shocker_info` gives a row AND an offset, and Jax's offset is the last
  frame of his lane (`rv_base` steps back for a valid pair);
  `shocker_lineup` is Raiden's, not a general helper; the thrown torso has
  `m_shadow` cleared or its shadow would float; `mpyu` writes a register
  PAIR (the slots are 256 bits so a shift finds them).
