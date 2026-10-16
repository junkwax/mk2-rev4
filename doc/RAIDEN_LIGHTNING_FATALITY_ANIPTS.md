# Raiden Lightning (Lift) Fatality

During FINISH HIM: **hold High Kick for 5 seconds** and release in range
(`MOVES.ASM rd_hk_open`, `rd_lift_hold`), then **hold Up and keep tapping High Punch**
until he explodes. Stop mashing (no HP within `rd_lift_mash_window` ticks, or Up let go)
and it fizzles: the bolt and smoke go, the body drops to the floor and the round ends as
a plain win (`rd_lift_fizzle`). Gated by `raiden_lift_fatal_enable` in `MAINEQU.ASM`.
Code: `do_raiden_lift_fatal` in `MKDEATH.ASM`.

## Source of truth: `data/RAIDELEC.WAX`

The game follows the IMGTOOL World View project `data/RAIDELEC.WAX` step for
step, holds included. `tools/raiden_lift_wax_import.py` generates every table
below from it, so re-run it after saving the WAX (`--check` reports stale
output):

| Lane | WAX slot | Game table |
|---|---|---|
| Raiden body | slot 6 (RAID8.IMG `RN1DETHBLO*`) | `a_death_zap1` (MKRD.ASM): RN1DETHBLO1 lead-in, then a row per step |
| Lightning | slot 0 (RADBOLT2.IMG `RN1DETHBOLT*`) | `a_death_bolt1` (MKRD.ASM): a row per step |
| Victim | the one victim slot (default authored on Liu Kang: KANG5 / KANG6 / KANG10) | `rd_lift_vic_script` (MKRDLIF.ASM) + per-fighter `rd_lift_*_tbl` |
| Victim, per family | `RAIDELECNJ.WAX` (the ninjas) - same Raiden and bolt, own poses and anipoints | `rd_lift_vic_script_nj`, frames named outright; `rd_lift_vic_scripts` picks by ochar |

A **step** is every stretch of ticks in which none of the three slots changes
frame. The slots may hold their frames for different lengths, but they have to
end on the same tick. By request, the RN1DETHBLO6-10 electrocution stretch then
plays 5 more times (`LOOP_EXTRA` in the importer), with smoke rising off the
victim from its first pass (`rd_lift_smoke`, a PUFF every 2 ticks, drawn behind
him), and the bolts draw in front of the victim (`front_z+3`). DB1's 5-tick BLO2 hold is
not used.

<!--
  HAND-WRITTEN SECTIONS GO ABOVE "## Row timeline".  raiden_lift_wax_import.py
  replaces everything between "## Row timeline" and "## Victim poses", and
  everything between the pose table and "**What the WAX offset is.**" - prose
  parked in either range is silently deleted on the next run.
-->

## The opening pause and the chime (`rdl_pause`)

Every other fatality in `MKDEATH.ASM` holds its opening pose before anything
happens - `do_dragon` and `do_decap` for `030h`, `do_raiden_fry` for `020h`,
several labelled "dramatic pause !!". This one went straight in on row 0's
4-tick hold, so it read as Raiden snapping into it with no beat.

**That is also what silenced the chime.** `init_death_blow` creates
`make_db_tone`, which calls `nosounds`, sleeps 2 and sends `034h` - so the tone
was always being sent, it just had six ticks before the bolt's own
`tsound 05ah` / `tsound 0c7h` landed on top of it. `a_death_zap1`'s lead-in row
carries no frame-triggered sound of its own, so with the pause in, `034h` has
all `rdl_pause` ticks to itself.

**The `sleep` goes BEFORE `takeover_him`, not after.** `rd_lifted_victim` opens
with its own `sleep 4` - exactly row 0's hold, "the bolt has not reached him
yet" - and then starts flickering the electrocution palette. Pausing after the
takeover would have the victim cooking for most of a second with no lightning
on him. Held before it, he stays in his own FINISH HIM loop, which is what the
other fatalities show during their pause.

Measured: Raiden's opening pose goes from 3 frames to 51, and the rig anchors
its step comparison on the bolt's first frame rather than on the fatality
start, so the WAX lane is untouched.

## The victim's audio (`rsnd_death_voice` + the repeating zap)

**He sounds like the other electrocution now.** Retail's `do_raiden_fry` - hold
LK in FINISH HIM, the same current - is dispatched off a KICK, not the grab, so
it gives its victim no voice at all; what it does is re-send `tsound 0c7h`, the
super zap, every two shake cycles for the whole cook (`p_store8` counts them
down). The voice MK2 does pair with this current is in `do_raiden_shocker`
(MOVES.ASM), which plays `rsnd_death_voice` on the man the moment the grab
takes him.

So the lift plays both: his death voice as the bolt reaches him (flag bit 3,
which used to be `rsnd_react_voice`, a grunt), then the zap again on the first
step of **every** pass of the RN1DETHBLO6-10 stretch (flag bit 7) - 20 ticks
apart against the fry's 24, the closest the 4-tick steps get. The long
`disturbing_scream` (Liu Kang's `b8h`, ~2.2s) is what made this fatality sound
unlike the other one and is off; `SCREAM_PASSES = (0,)` in the importer puts it
back on the WAX's own pass, and bit 2 still carries it.

`LOOP_EXTRA` is 5, so the stretch plays six times: 36 steps, 144 ticks of lane,
and two more Up+HP mash checks than before.

**That data lives in `src/MKRDLIF.ASM`, not MKDEATH.** The ten victim scripts
and the four per-ochar pose tables are ~840 lines of pure data, and unrolling
two more passes into all ten scripts aborted MKDEATH with GSPA's
`>> Out of memory`. The code that walks them stays in MKDEATH, which imports
`rd_lift_vic_scripts` with a `.ref`; the new object needs only
`.include mainequ.asm`, because all 80 art labels the tables name are already
`.global` there.

## What `DB1` actually holds, frame by frame

`DB1` in `data/RAID8.IMG` is Midway's authored sequence for this lane
(`python tools/dump_imgtool_seqscr.py data/RAID8.IMG DB1`):

    RN1DETHBLO1[01] RN1DETHBLO2[05] RN1DETHBLO3[01] ... RN1DETHBLO10[01]
    RN1DETHBLO6[01] RN1DETHBLO7[01] RN1DETHBLO8[01] RN1DETHBLO9[01] RN1DETHBLO10[01]

Hold bytes are PREVIEW ticks, 4 game ticks each in this tree. So:

- the **opening** frame holds **1** (= 4 game ticks), which is exactly
  `LEAD_HOLD`; the **5 is on the SECOND frame**, RN1DETHBLO2, and is worth 20
  game ticks. `data/RAIDELEC.WAX` holds every entry of every slot at 4, so that
  authored beat is the one thing of DB1's the WAX does not carry. Giving it
  back is a live option, not done.
- DB1 plays the 6-10 stretch **twice**, i.e. Midway's own `LOOP_EXTRA` was 1.

## The view rises while he cooks (`rdlcam`)

`rd_lift_camera` (MKDEATH.ASM), created just before the row loop, dies with the
fatality. `rdlcam .set 0` next to it is retail framing.

**The problem it fixes.** The bolt holds him about 180 rows above Raiden's
anchor and the HUD covers the top ~44 rows of the frame. Measured on the Armory
with the camera at rest (`worldtly` 0 = `ceiling_y`): his pieces draw at world
y 28..90, so the health bars and the timer sit on top of him and all the player
ever saw of the electrocution was the two bolts and the smoke. The view lifts
`rdl_cam_up` = 48 rows at `rdl_cam_step` = 2 rows a tick, holds while he cooks
and through the burst, and comes back down. Either way it lands on the exact
row it started from.

**`f_noscrolly` has to go up, and that rules out `@scrolly`.** The vertical
chase (`scrl6`, BGND.ASM) reads both fighters' `oypos`, and a hanging victim's
ANCHOR is low - 191 on the Armory, below the barrier - even while his pixels
are off the top of the screen, so the chase pulls the view straight back down.
But the pinned path does not return: it jumps to `scrl9`, which is `clr a0`
falling into `move a0,@scrolly,l`, so **the scroller zeroes the scroll velocity
every frame while `f_noscrolly` is up**. Driving the camera by writing
`@scrolly` and letting the display pass integrate it - which is how `scrl6`
itself moves the camera - therefore cannot work here. Measured: 48 rows of lift
arrived as 40, spread over the wrong 30 ticks, landing after the electrocution
it was supposed to frame. `rd_lift_camera` steps `worldtly+16` outright instead
(a WORD write - the 16 bits above it are `scrollx8`'s fraction).

**How far it may rise is MEASURED PER STAGE** (`rdl_cam_room`, MKDEATH.ASM,
2026-10-06). The backdrop runs out of blocks somewhere above `ceiling_y`, and
past that the frame shows the stage's erase/sky colour and the ragged tops of
the planes. **The HUD does not hide it.** This section used to say the top 44
rows were covered and bounded the lift at `44 + climb_limit`; the bars are not
a full-width strip, and a fixed 48-row lift showed a black band on the Armory,
the Tomb and the Throne Room ("the screen goes too high"), and on the Dead Pool
the dark-green erase colour with the plane tops cut ragged ("weird background
artifacts") - there the art is good to 48, and `r_shocker_pop`'s shake
(`000080008h`, which moves the view UP first) put the peak at 56.

So the hold row is `max(home - rdl_cam_up, ceiling_y - room + rdl_cam_shake)`,
and the view does not lift at all when that is not above home. `room` was
measured by pinning the view in a 2-player fight and lifting it 4 rows at a
time at the start camera and both scroll limits, until the colour seen at a
240-row lift reached row 0 (least of the three; 96 = no edge found):

| curback | stage | room | lift now |
|---|---|---:|---:|
| 0 / 17h | Dead Pool | 48 | 40 |
| 1 | Tomb | 28 | 20 |
| 4 | Living Forest | 36 | 28 |
| 5 | Armory | 16 | 8 |
| 7 / 16h | Portal / Outer Haven | 4 | none |
| 0ah | MK1 Pit | 36 | 28 |
| 1bh | Warrior Shrine | 72 | 48 |
| 1ch | Throne Room | 20 | 12 |
| 2, 6, 8, 9, 18h-1ah | sky stages | 96 | 48 |

The cost is framing on the low-art stages: on the Armory and the Throne Room
the hanging victim sits closer to the bars again.

**There is ONE shake at the pop.** `do_raiden_lift_fatal` used to fire its own
`shake_a11 00008000ch` straight after `r_shocker_pop`'s `000080008h`.
`shake_a11` is `create_and_kill`, so the second killed the first mid-pass:
the first never gave back its 8 rows (the view stayed 8 up for the rest of the
shot) and the second moved 8 MORE up, so the burst's first frames sat 16 rows
over the hold and showed 6-8 rows of erase colour on every stage. The second
shake is commented out; the pop's own shake is the same 8 px.

**A stage that pinned its own vertical camera is left alone.** `climb_limit 0`
is `calla_tower` (BGND.ASM) saying so - THE TOWER's floor is a mirror, so every
pillar, guard, cloud and reflection rides the view - and a stage that never
leaves `ceiling_y` has no art above it to uncover either. There the first
instruction of `rd_lift_camera` bails and the fatality plays exactly as before.

**Coming home is keyed to `@f_death` leaving `rdl_fatal_num`** -
`death_blow_complete` on the way into the victory, and `rd_lift_fizzle`'s
`f_death` 0 when he stops mashing. Deliberately not the pop: the burst and the
head leaving the top of the frame are still framed up there. The 8-row screen
shake after the pop runs on top of the held view and undoes only its own
displacement (`es_sub`, MKFX.ASM), so the landing row is still exact.

Measured, the rig reading `worldtly+16` per frame:

| Stage | `ceiling_y` | `climb_limit` | rest -> hold -> end |
|---|---:|---:|---|
| Armory (5) | 0 | 16 | 0 -> -48 -> 0 |
| Dead Pool (0) | -8 | 16 | -8 -> -56 -> -8 |
| THE TOWER (3) | -14 | 0 | -14 throughout, `f_noscrolly` never set |

## Row timeline

Generated from the WAX: one row per step (a step ends whenever any lane
changes frame). The RN1DETHBLO6-RN1DETHBLO10 stretch plays 5 more times after its WAX
pass, and the smoke starts on its first step. Every family shares these steps;
the victim column is the default project.

| Step | Body | Bolt | Victim | Hold (ticks) |
|---:|---|---|---|---:|
| 0 | RN1DETHBLO1 | - | untouched (lead-in) | 4 |
| 1 | RN1DETHBLO2 | RN1DETHBOLT1 | WAX 0 STUMBLE1 + death | 4 |
| 2 | RN1DETHBLO3 | RN1DETHBOLT2 | WAX 1 FLIPPED2 | 4 |
| 3 | RN1DETHBLO4 | RN1DETHBOLT3 | WAX 2 FLIPPED2 | 4 |
| 4 | RN1DETHBLO5 | RN1DETHBOLT4 | WAX 3 BACKBREAK3 | 4 |
| 5 | RN1DETHBLO6 | RN1DETHBOLT5 | WAX 4 KNOCKDOWN7 + smoke starts | 4 |
| 6 | RN1DETHBLO7 | RN1DETHBOLT6 | WAX 5 BACKBREAK3 | 4 |
| 7 | RN1DETHBLO8 | RN1DETHBOLT7 | WAX 6 KNOCKDOWN7 | 4 |
| 8 | RN1DETHBLO9 | RN1DETHBOLT8 | WAX 7 BACKBREAK3 | 4 |
| 9 | RN1DETHBLO10 | RN1DETHBOLT9 | WAX 8 KNOCKDOWN7 | 4 |
| 10 | RN1DETHBLO6 | RN1DETHBOLT5 | WAX 4 KNOCKDOWN7  (loop 1) | 4 |
| 11 | RN1DETHBLO7 | RN1DETHBOLT6 | WAX 5 BACKBREAK3  (loop 1) | 4 |
| 12 | RN1DETHBLO8 | RN1DETHBOLT7 | WAX 6 KNOCKDOWN7  (loop 1) | 4 |
| 13 | RN1DETHBLO9 | RN1DETHBOLT8 | WAX 7 BACKBREAK3  (loop 1) | 4 |
| 14 | RN1DETHBLO10 | RN1DETHBOLT9 | WAX 8 KNOCKDOWN7  (loop 1) | 4 |
| 15 | RN1DETHBLO6 | RN1DETHBOLT5 | WAX 4 KNOCKDOWN7  (loop 2) + mash check | 4 |
| 16 | RN1DETHBLO7 | RN1DETHBOLT6 | WAX 5 BACKBREAK3  (loop 2) | 4 |
| 17 | RN1DETHBLO8 | RN1DETHBOLT7 | WAX 6 KNOCKDOWN7  (loop 2) | 4 |
| 18 | RN1DETHBLO9 | RN1DETHBOLT8 | WAX 7 BACKBREAK3  (loop 2) | 4 |
| 19 | RN1DETHBLO10 | RN1DETHBOLT9 | WAX 8 KNOCKDOWN7  (loop 2) | 4 |
| 20 | RN1DETHBLO6 | RN1DETHBOLT5 | WAX 4 KNOCKDOWN7  (loop 3) + mash check | 4 |
| 21 | RN1DETHBLO7 | RN1DETHBOLT6 | WAX 5 BACKBREAK3  (loop 3) | 4 |
| 22 | RN1DETHBLO8 | RN1DETHBOLT7 | WAX 6 KNOCKDOWN7  (loop 3) | 4 |
| 23 | RN1DETHBLO9 | RN1DETHBOLT8 | WAX 7 BACKBREAK3  (loop 3) | 4 |
| 24 | RN1DETHBLO10 | RN1DETHBOLT9 | WAX 8 KNOCKDOWN7  (loop 3) | 4 |
| 25 | RN1DETHBLO6 | RN1DETHBOLT5 | WAX 4 KNOCKDOWN7  (loop 4) + mash check | 4 |
| 26 | RN1DETHBLO7 | RN1DETHBOLT6 | WAX 5 BACKBREAK3  (loop 4) | 4 |
| 27 | RN1DETHBLO8 | RN1DETHBOLT7 | WAX 6 KNOCKDOWN7  (loop 4) | 4 |
| 28 | RN1DETHBLO9 | RN1DETHBOLT8 | WAX 7 BACKBREAK3  (loop 4) | 4 |
| 29 | RN1DETHBLO10 | RN1DETHBOLT9 | WAX 8 KNOCKDOWN7  (loop 4) | 4 |
| 30 | RN1DETHBLO6 | RN1DETHBOLT5 | WAX 4 KNOCKDOWN7  (loop 5) + mash check | 4 |
| 31 | RN1DETHBLO7 | RN1DETHBOLT6 | WAX 5 BACKBREAK3  (loop 5) | 4 |
| 32 | RN1DETHBLO8 | RN1DETHBOLT7 | WAX 6 KNOCKDOWN7  (loop 5) | 4 |
| 33 | RN1DETHBLO9 | RN1DETHBOLT8 | WAX 7 BACKBREAK3  (loop 5) | 4 |
| 34 | RN1DETHBLO10 | RN1DETHBOLT9 | WAX 8 KNOCKDOWN7  (loop 5) | 4 |
| 35 | RN1DETHBLO10 | RN1DETHBOLT10 | WAX 9 KNOCKDOWN7 + mash check | 4 |
| 36 | RN1DETHBLO10 | RN1DETHBOLT11 | WAX 10 KNOCKDOWN7 | 4 |

Then `r_shocker_pop` blows the victim apart. His head (`rd_lift_head`) flies
straight up out of the burst and off the top of the frame, stays there while
the debris lands, then falls back LAST and bounces four times, each lower
(`rd_lift_head_bounces`).

## Victim poses and placement

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | STUMBLE1 | 78,44 | yes |  | 78,-44 | 4 |
| 1 | FLIPPED2 | 79,57 | yes |  | 79,-57 | 4 |
| 2 | FLIPPED2 | 61,77 | yes |  | 61,-77 | 4 |
| 3 | BACKBREAK3 | -26,140 |  |  | 26,-140 | 4 |
| 4 | KNOCKDOWN7 | 3,180 |  |  | -3,-180 | 4 |
| 5 | BACKBREAK3 | 3,130 |  |  | -3,-130 | 4 |
| 6 | KNOCKDOWN7 | 2,181 |  |  | -2,-181 | 4 |
| 7 | BACKBREAK3 | 2,139 |  |  | -2,-139 | 4 |
| 8 | KNOCKDOWN7 | 6,181 |  |  | -6,-181 | 4 |
| 9 | KNOCKDOWN7 | 0,181 |  |  | 0,-181 | 4 |
| 10 | KNOCKDOWN7 | -5,179 |  |  | 5,-179 | 4 |

**TM family** - `data/RAIDELECLAO.WAX`, victim slot 4, frames named outright - kung lao:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | TMSTUMBLE1 | 75,36 | yes |  | 75,-36 | 4 |
| 1 | TMSOULSUCK1 | 77,32 | yes |  | 77,-32 | 4 |
| 2 | TMFLIPPED1 | 49,63 | yes |  | 49,-63 | 4 |
| 3 | TMFLIPPED5 | -37,32 |  | yes | 37,32 | 4 |
| 4 | TMKNOCKDOWN6 | 10,78 |  | yes | -10,78 | 4 |
| 5 | TMKNOCKDOWN5 | 11,70 |  | yes | -11,70 | 4 |
| 6 | TMKNOCKDOWN7 | 20,87 |  | yes | -20,87 | 4 |
| 7 | KLBUZZ2 | 24,76 |  |  | -24,-76 | 4 |
| 8 | TMKNOCKDOWN7 | 18,89 |  | yes | -18,89 | 4 |
| 9 | TMBACKBREAK2 | 12,32 |  | yes | -12,32 | 4 |
| 10 | TMKNOCKDOWN7 | 17,93 |  | yes | -17,93 | 4 |

**LK family** - `data/RAIDELECLIUFRONT.WAX`, victim slot 3, frames named outright - liu kang:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | LKSTUMBLE1 | 78,44 | yes |  | 78,-44 | 4 |
| 1 | LKSOULSUCK1 | 85,39 | yes |  | 85,-39 | 4 |
| 2 | LKFLIPPED2 | 54,70 | yes |  | 54,-70 | 4 |
| 3 | LKBACKBREAK2 | -34,7 |  | yes | 34,7 | 4 |
| 4 | LUBUZZ2 | 14,57 |  |  | -14,-57 | 4 |
| 5 | LKBACKBREAK3 | 11,42 |  | yes | -11,42 | 4 |
| 6 | LKKNOCKDOWN7 | 1,79 |  | yes | -1,79 | 4 |
| 7 | LKBACKBREAK3 | 15,32 |  | yes | -15,32 | 4 |
| 8 | LUBUZZ2 | 16,63 |  |  | -16,-63 | 4 |
| 9 | LKBACKBREAK3 | 4,37 |  | yes | -4,37 | 4 |
| 10 | LKKNOCKDOWN7 | 3,84 |  | yes | -3,84 | 4 |

**JC family** - `data/RAIDELECCAGE.WAX`, victim slot 3, frames named outright - johnny cage:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | JCSTUMBLE1 | 74,41 | yes |  | 74,-41 | 4 |
| 1 | JCFLIPPED1 | 63,64 | yes |  | 63,-64 | 4 |
| 2 | JCKNOCKDOWN6 | -49,102 |  | yes | 49,102 | 4 |
| 3 | JCBACKBREAK2 | -20,23 |  | yes | 20,23 | 4 |
| 4 | SZBUZZ2 | -2,58 |  |  | 2,-58 | 4 |
| 5 | JCBACKBREAK2 | 16,33 |  | yes | -16,33 | 4 |
| 6 | JCKNOCKDOWN7 | 19,76 |  | yes | -19,76 | 4 |
| 7 | JCBACKBREAK3 | -1,40 |  | yes | 1,40 | 4 |
| 8 | JCBACKBREAK2 | 14,24 |  | yes | -14,24 | 4 |
| 9 | SZBUZZ2 | -1,68 |  |  | 1,-68 | 4 |
| 10 | JCKNOCKDOWN7 | 7,79 |  | yes | -7,79 | 4 |

**UG family** - `data/RAIDELECUGMO.WAX`, victim slot 4, frames named outright - baraka:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | UGSTUMBLE1 | 71,25 | yes |  | 71,-25 | 4 |
| 1 | UGSOULSUCK1 | 85,46 | yes |  | 85,-46 | 4 |
| 2 | UGFLIPPED1 | 64,77 | yes |  | 64,-77 | 4 |
| 3 | UGBACKBREAK1 | -28,-3 |  | yes | 28,-3 | 4 |
| 4 | UGBACKBREAK2 | 7,15 |  | yes | -7,15 | 4 |
| 5 | UGBACKBREAK3 | -1,28 |  | yes | 1,28 | 4 |
| 6 | KNBUZZ2 | 18,65 |  |  | -18,-65 | 4 |
| 7 | UGKNOCKDOWN6 | 16,85 |  | yes | -16,85 | 4 |
| 8 | KNBUZZ2 | 16,65 |  |  | -16,-65 | 4 |
| 9 | UGBACKBREAK2 | 6,10 |  | yes | -6,10 | 4 |
| 10 | UGKNOCKDOWN6 | -2,80 |  | yes | 2,80 | 4 |

**KT family** - `data/RAIDELECKAT.WAX`, victim slot 4, frames named outright - kitana, mileena, jade, khameleon:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | KTSTUMBLE1 | 81,25 | yes |  | 81,-25 | 4 |
| 1 | KTSOULSUCK1 | 89,45 | yes |  | 89,-45 | 4 |
| 2 | KTKNOCKDOWN4 | -55,69 |  | yes | 55,69 | 4 |
| 3 | KTBACKBREAK3 | -24,14 |  | yes | 24,14 | 4 |
| 4 | KTKNOCKDOWN6 | 11,75 |  | yes | -11,75 | 4 |
| 5 | LIBUZZ2 | 7,62 |  |  | -7,-62 | 4 |
| 6 | KTKNOCKDOWN6 | 14,71 |  | yes | -14,71 | 4 |
| 7 | KTBACKBREAK3 | 7,21 |  | yes | -7,21 | 4 |
| 8 | SBBUZZ2 | 13,58 |  |  | -13,-58 | 4 |
| 9 | KTKNOCKDOWN6 | 4,78 |  | yes | -4,78 | 4 |
| 10 | KTKNOCKDOWN3 | 14,30 |  | yes | -14,30 | 4 |

**ST family** - `data/RAIDELECTSUNG.WAX`, victim slot 2, frames named outright - shang tsung:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | STSTUMBLE1 | 77,35 | yes |  | 77,-35 | 4 |
| 1 | STSOULSUCK1 | 84,40 | yes |  | 84,-40 | 4 |
| 2 | STFLIPPED2 | 59,83 | yes |  | 59,-83 | 4 |
| 3 | STBACKBREAK2 | -31,2 |  | yes | 31,2 | 4 |
| 4 | TSBUZZ2 | 10,70 |  |  | -10,-70 | 4 |
| 5 | STBACKBREAK2 | 5,22 |  | yes | -5,22 | 4 |
| 6 | STBACKBREAK3 | 13,23 |  | yes | -13,23 | 4 |
| 7 | TSBUZZ2 | 5,81 |  |  | -5,-81 | 4 |
| 8 | STKNOCKEDOWN7 | 8,85 |  | yes | -8,85 | 4 |
| 9 | STBACKBREAK3 | 7,27 |  | yes | -7,27 | 4 |
| 10 | STKNOCKEDOWN7 | 5,87 |  | yes | -5,87 | 4 |

**RN family** - `data/RAIDELECRAD.WAX`, victim slot 4, frames named outright - raiden:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | RNSTUMBLE1 | 80,39 | yes |  | 80,-39 | 4 |
| 1 | RDSOULSUCK1 | 92,49 | yes |  | 92,-49 | 4 |
| 2 | RNFLIPPED2 | 56,77 | yes |  | 56,-77 | 4 |
| 3 | RNBACKBREAK3 | -23,23 |  | yes | 23,23 | 4 |
| 4 | RDBUZZ2 | 70,18 |  |  | -70,-18 | 4 |
| 5 | RNBACKBREAK3 | 15,46 |  | yes | -15,46 | 4 |
| 6 | RNKNOCKDOWN7 | 33,86 |  | yes | -33,86 | 4 |
| 7 | RNBACKBREAK2 | 25,13 |  | yes | -25,13 | 4 |
| 8 | RDBUZZ2 | 73,22 |  |  | -73,-22 | 4 |
| 9 | RNKNOCKDOWN7 | 23,87 |  | yes | -23,87 | 4 |
| 10 | RNKNOCKDOWN7 | 20,89 |  | yes | -20,89 | 4 |

**NJ family** - `data/RAIDELECNJ.WAX`, victim slot 1, frames named outright - sub-zero, reptile, scorpion, kintaro, shao kahn, smoke, noob saibot, ermac, rain:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | NJSTUMBLE1 | 88,36 | yes |  | 88,-36 | 4 |
| 1 | NJSOULSUCK1 | 84,39 | yes |  | 84,-39 | 4 |
| 2 | NJFLIPPED2 | 62,71 | yes |  | 62,-71 | 4 |
| 3 | NJGETUP4 | -29,33 |  | yes | 29,33 | 4 |
| 4 | KNBUZZ2 | 15,61 |  |  | -15,-61 | 4 |
| 5 | NJBACKBREAK2 | 6,22 |  | yes | -6,22 | 4 |
| 6 | NJBACKBREAK1 | 21,5 |  | yes | -21,5 | 4 |
| 7 | NJBACKBREAK3 | 13,19 |  | yes | -13,19 | 4 |
| 8 | KNBUZZ2 | 11,68 |  |  | -11,-68 | 4 |
| 9 | NJKNOCKDOWN6 | 20,74 |  | yes | -20,74 | 4 |
| 10 | NJBACKBREAK2 | 5,12 |  | yes | -5,12 | 4 |

**JX family** - `data/RAIDELECJAX.WAX`, victim slot 4, frames named outright - jax:

| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |
|---:|---|---:|:-:|:-:|---:|---:|
| 0 | JXSTUMBLE1 | 81,29 | yes |  | 81,-29 | 4 |
| 1 | JXSOULSUCK1 | 83,42 | yes |  | 83,-42 | 4 |
| 2 | JXFLIPPED2 | 68,87 | yes |  | 68,-87 | 4 |
| 3 | JXBACKBREAK3 | 0,16 |  | yes | 0,16 | 4 |
| 4 | KNBUZZ2 | 16,62 |  |  | -16,-62 | 4 |
| 5 | JXKNOCKDOWN3 | 18,24 |  | yes | -18,24 | 4 |
| 6 | JXKNOCKDOWN7 | 24,90 |  | yes | -24,90 | 4 |
| 7 | JXKNOCKDOWN6 | 14,77 |  | yes | -14,77 | 4 |
| 8 | JXKNOCKDOWN7 | 25,89 |  | yes | -25,89 | 4 |
| 9 | JXBACKBREAK3 | 22,25 |  | yes | -22,25 | 4 |
| 10 | KNBUZZ2 | 16,62 |  |  | -16,-62 | 4 |

**What the WAX offset is.** A WAX `local_dx/dy` is an ANIPOINT offset from the
shared anchor. Raiden's slot sits on that anchor with no offset, so the anchor
is Raiden's `oxpos/oypos`. A fighter frame never moves its anchor, and each
piece draws at `anchor - anipoint`, mirrored when flipped. The victim's anchor
therefore goes at `Raiden + (mirrored ? +dAX : -dAX, -dAY)`, in Raiden's facing.
This is the same per-frame rule `tools/wvp_to_lane.py` and imgtool's exporter
use. The old screenshot "photo pairs" that used to live in this doc were never
in this frame of reference, and are gone.

**Order in `rd_lift_pose_victim`:**
1. `ani2` the pose.
2. `match_ani_points` onto Raiden, which puts him on Raiden's anchor and facing.
3. `multi_adjust_xy`, whose flip negation is then Raiden's.
4. `flip_multi` for mirrored entries.

The victim is posed from Raiden's process, so the three lanes cannot drift. His
own process only flickers the shock palette.

**Per-fighter frames:** Kitana, Mileena, Jade and Khameleon use
`KTGETFLIPPED2` and `KTKNOCKDOWN6` (their knockdown lane ends on 6). Baraka's
stumble is `UGSTUMBL1E1` (sic). Kintaro, Kahn and the other hidden ninjas use
the ninja row, as in the other char-indexed tables.

**Draw order:** Raiden `back_z`, smoke `front_z+1`, victim `front_z+2`, bolts
`front_z+3` (in front of the victim by request - the WAX draws the victim on top).

## Test

`tools/run_raiden_lift_fatality_test.ps1` (Raiden vs Liu Kang) forces a real FINISH
HIM, inputs F,F,F+LK, and on every frame the bolt is up checks:
- the victim pose family,
- his offset from Raiden (sign-flipped with Raiden's facing),
- his facing against the table above.

It checks every frame against the step the WAX says should be showing, so a
step that starts late or holds too long fails too. It fails on any mismatch,
off-table art, lockup or hang. It snapshots every
row as `stepNN_<body frame>`. Snapshots land in `<run dir>\mk2\`.
