# Kitana's fan decapitation — the fan swings back, and cuts twice

`FANSWIPESQ`, the sequence Midway embedded in `data/KAT9.IMG` beside Kitana's
fatality art, is a full **back and forth**: the fan goes out, hangs at the top
of the swing, and comes back down to her stance. The lane the game plays
(`a_fan_swipe`, `src/MKFN.ASM`) stops at the top, so retail's blade crosses the
victim **once** and the whole return half of the authored animation has never
been drawn.

It is drawn now, and the second pass is what takes the head: the first cuts him
and he staggers, the fan hangs out there for its authored hold, and on the way
back it decapitates him.

Built 2026-09-26. `fandecap2 .set 0` (MAINEQU.ASM) is retail's single slice.

## The input is unchanged

**Block, Block, Block + High Kick**, in FINISH HIM, within `048h`
(`fn1_hi_kick` → `bcom_fn1_db2`, MOVES.ASM; `do_fatality_2` → `db2_table[4]` →
`do_fan_decap`, MKDEATH.ASM). Nothing about the gate, the range or the
dispatch moved.

## The authored sequence

`python tools/fan_swipe_seq_import.py --dump` reads it out of the IMG:

| # | frame | preview hold | game ticks | |
|---|---|---|---|---|
| 1 | KTFANSWIPE1 | 1 | 4 | fan closed, her stance |
| 2 | KTFANSWIPE2 | 1 | 4 | open, arm back — the wind-up |
| 3 | KTFANSWIPE3 | 1 | 4 | open, swung across her |
| 4 | KTFANSWIPE4 | 1 | 4 | the fan leaves her hand, out in front |
| 5 | KTFANSWIPE5 | 1 | 4 | arm fully extended, fan at full reach |
| 6 | KTFANSWIPE6 | **15** | **60** | the fan is back at her raised hand |
| 7 | KTFANSWIPE5 | 1 | 4 | and out it goes again |
| 8 | KTFANSWIPE4 | 1 | 4 | |
| 9 | KTFANSWIPE3 | 1 | 4 | |
| 10 | KTFANSWIPE2 | 1 | 4 | |
| 11 | KTFANSWIPE1 | 1 | 4 | back to her stance |

100 ticks, about 1.8 seconds.

**A seqscr hold byte counts PREVIEW ticks, not game ticks**, and one preview
tick is `round(54.7 / fps)` game ticks — the same conversion, and the same
trap, that [LK_DOUBLE_KNEE.md](LK_DOUBLE_KNEE.md) documents at length.
FANSWIPESQ is authored at IMGTOOL's **13.7 fps**, so the unit is **4**. Read as
game ticks the whole fatality would be 26 ticks — a flicker.

**Retail's own code is the corroboration that 4 is right.** Frame 6's authored
hold is 60 game ticks; retail holds it for two lane frames at 4 plus
`sleep 030h`, which is 56. Nobody could have derived the sleep from the
sequence, so the two agreeing to within a frame is independent evidence.

## What was added, and what was deliberately not touched

`a_fan_swipe` is **shared with her Back+HP power punch** (`do_fan_swipe`,
MOVES.ASM), which plays part 1 through `striker_2` and part 2 through
`retract_strike` and stops. Re-cutting the lane from the sequence would have
silently changed a live move's startup, active frames and recovery — so the
return half went on as two more **parts** instead, which the power punch never
reaches:

```
a_fan_swipe
        part 1   FANSWIPE1 1 2 3 4 [ani_nosleep] 5      retail — the swing out
        part 2   FANSWIPE6 6                            retail — the top
        part 3   FANSWIPE5                              new — back out: SECOND SLICE
        part 4   FANSWIPE4 3 2 1                        new — down to her stance
```

Parts 3 and 4, and the two `fdc_` timing equates in MKDEATH.ASM, are
**generated** by `tools/fan_swipe_seq_import.py` (Phase D `--check`). Edit the
sequence in IMGTOOL and re-run the tool; never hand-edit the blocks. The tool
also checks that the outward half of the sequence still names the frames
retail's parts 1 and 2 play, so a re-authored FANSWIPESQ fails the build
rather than disagreeing with the code in silence.

## The two slices

`do_fan_decap` (MKDEATH.ASM):

| beat | what happens |
|---|---|
| windup | first frame of the lane, `sleep 030h` — retail's dramatic pause |
| part 1 | the swing out, 4 ticks a frame |
| **first slice** | `r_first_swipe` — Scorpion's own first-of-two blade reaction: slice sound, wasted voice, blood, a stumble that then holds |
| | `sleep fdc_rate` — FANSWIPE5 finally gets its authored beat (see below) |
| part 2 | FANSWIPE6 twice, then `sleep fdc_hold` = 60 ticks at the top |
| part 3 | FANSWIPE5 — the fan goes back out through him |
| **second slice** | death voice, slice sound, `decap_fall` — the head comes off |
| part 4 | FANSWIPE4..1, down to her stance |

The first slice reuses `r_first_swipe` rather than getting a reaction of its
own because it is the identical beat: `do_spear_swipe`, Scorpion's two-swipe
spear fatality, is already a blade that cuts on the way past and kills on the
second pass, and MKDEATH.ASM's own comments already cross-reference Kitana's
fan decap as the model for that handoff.

### Two things that only show up on the machine

**Part 1's last entry is `ani_nosleep` + FANSWIPE5**, so `mframew` draws the
contact frame and returns in the same tick. That is right for the power punch,
where `striker_2`'s strike window then holds the pose — but on its own it means
the fatality never *draws* the fan at full reach: it went `1,2,3,4` and
straight to `6`. The rig's LANE line said exactly that and nothing else would
have. `sleep fdc_rate` after the first slice gives the frame its authored beat
without touching part 1.

**`takeover_him_sr`'s no-repell brake is only `040h` ticks** and the two-slice
sequence is about 135, so repell would come back on between the slices and
shove Kitana off the body. `disable_repell`'s `040h*40` is inlined instead —
that routine is 6,900 lines further down MKDEATH.ASM and a `callr` that far is
a PC-relative branch out of range (CLAUDE.md; `MK1PTOP.ASM` inlines it for the
same reason).

## The rig

```
python tools/fan_swipe_seq_import.py --dump        # the sequence, as the IMG holds it
.\tools\run_kitana_fan_decap_test.ps1 -Victim all  # 12 victims, one MAME run each
.\tools\run_kitana_fan_decap_test.ps1 -Victim subzero -SnapEvery 4
```

It forces a 2-player FINISH HIM, snaps the pair inside `048h` and plays the
real gesture. What it measures, and why each measurement is shaped the way it
is:

* **Kitana's drawn frame, every tick.** A fighter is a multipart object and its
  own `osize` fields are **0** — the pieces are 112-bit nodes in the process's
  shape RAM at `*obj(oimg)` and are not on `objlst`. Reading `osize` off the
  player object is what the first cut of the rig did, and it reported `0x0`
  every tick. The frame is identified by the first piece's size, looked up
  against the `KTFANSWIPEnA` records **parsed out of `src/MKFN.TBL`**, so the
  rig reads the geometry the build ships and cannot pass against a stale
  constant. All six sizes are distinct, which is what makes this work at all.
* **The lane, as an ordered run**: `1,2,3,4,5,6,5,4,3,2,1`. This is the whole
  claim, and it is the line to read.
* **Which pass took the head.** The detached head is found by its **process** —
  `decap_fall` does `create pid_head,decapped_head`, so the active list carries
  a process whose `procid` is `pid_head` and whose `pa8` is the head object.
  Matching on the *object* does not work, and the way it fails is worth
  keeping: `decapped_head` copies the victim's **ochar** onto its object and
  never writes an `oid` (`getobj` zeroes a fresh block), so ochar looks like
  the handle — and it is, for eleven of the twelve victims. **Kung Lao is ochar
  0**, which every object that never set one also reads as, so the ochar walk
  matched a stray object on the fatality's first tick and reported the head off
  before the swing had started: one FAIL in a 12-run sweep, in the rig, with
  the ROM correct. (The sai-split legs *are* found by oid, because
  `r_sai_split` copies that too — the two detectors are not interchangeable.)
  The head must appear at or after the first return frame, or this ROM is
  retail's timing wearing the new animation.
* **That the first slice did something.** The victim's drawn frame has to
  change before the head comes off; his palette must not change until it does,
  because `decap_fall` calls `change_to_bloody_pal` and `r_first_swipe` does
  not. That repalette is the killing slice, to the tick.

**12/12 PASS** over every victim. Sub-Zero's run, `fandecap2 .set 1`:

```
LANE 1,2,3,4,5,6,5,4,3,2,1
TOP  KTFANSWIPE6 drawn for 60 ticks (authored 15 preview ticks x4 = 60)
HEAD off at fatality tick +133, on KTFANSWIPE4 (return began +128)
VICTIM drew 13 different frames before the head came off; repalette at +133
PASS
```

and the control, `fandecap2 .set 0`, which must fail:

```
LANE 1,2,3,4,6
TOP  KTFANSWIPE6 drawn for 56 ticks
HEAD off at fatality tick +65, on KTFANSWIPE6 (return began +nil)
FAIL -- the swing out stopped at KTFANSWIPE4; the return half never played
```

Retail's 56 against the authored 60 is the tick conversion showing up in the
measurement, not a discrepancy.

## Space

None. All six frames were already packed — `KTFANSWIPE1A`..`6B` have been in
the video ROM since 1993, drawn by her power punch and by retail's half of
this fatality. The return half is 7 more `.long`s of program ROM.
