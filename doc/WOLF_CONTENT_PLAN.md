# Wolf-only content: plan and budget

The content planned for the Wolf build, costed against what the Wolf board has
free (see [WOLF_SPACE.md](WOLF_SPACE.md)), with the order to build it in. All
of it is **Wolf-only**: the T-unit has 8 KB of program ROM, 47 KB of video ROM
and 49 KB of sound ROM left, so none of it fits there.

How Wolf-only content is kept apart from the T-unit build (one tree, no fork):
code in Wolf-only modules whose body is `.if wunit` plus named feature switches
(`xxx .set wunit`) for hooks in shared code; art in LODs packed above 12 MB;
sound in a Wolf overlay patch applied after `stlaugh_patch.txt`. The T-unit
build must stay byte-identical when only Wolf content changes.

## The list

1. **Sindel** - new fighter, from MK3 / UMK3
2. **MK1 audio** - MK1's sound bank (voices, effects)
3. **Scorpion's Lair** - UMK3's stage
4. **Kano** (MK1) as a Shang Tsung morph
5. **MK1 music** for THE THRONE ROOM, Goro's Lair, THE PIT, THE WARRIOR SHRINE
6. **The Courtyard** and **Palace Gates** - MK1 stages, with their MK1 music

## What it costs (measured on this tree, 2026-10-07)

| item | program ROM | video ROM | sound ROM |
|---|---:|---:|---:|
| one MK1 stage (Courtyard, Palace Gates) | ~5-6 KB each (MK1PTOP 4.4, MK1THRN 5.5, MK1WSHR 6.3) | ~60-150 KB each | - |
| Scorpion's Lair (+ its stage fatality) | ~6-8 KB (+ ~1.6-2.5 KB) | ~100-200 KB | its UMK3 music, copied verbatim |
| Kano as a Shang morph | ~25-35 KB (a morph needs the full fighter: TABLE1, specials, AI rows) | ~400-500 KB | voices, small |
| Sindel | ~40-55 KB (fighter module 15-29 KB alone, plus moves, strikes, AI, reactions, fatalities, select/VS) | ~500-600 KB | voices + scream, small |
| MK1 music, 6 stages | < 1 KB (track numbers) | - | **~405 KB per minute** |
| MK1 audio (voices/effects) | - | - | small (125 s of 7.5 kHz samples in all) |
| **total** | **~85-115 KB** | **~1.2-1.6 MB** | **~2-2.5 MB** with 6 x ~1 min of music |
| **Wolf free** | **210,546 bytes** (was 6,270 - see step D) | 8 MB (MAME), 20 MB (board) | 1.05 MB (MAME), 5 MB (board) |

Music: 60 s of the MK1 capture (`DCSExplorer/mk1_audio`) encodes to 404,988
bytes at DCSEncoder's defaults; the tighter settings the custom clips use cost
more (468-503 KB). MK1's music is YM2151 FM, generated live, so it can only come
in as a recording of MAME playing it - `mk1_music_capture.lua` already does that.

## The three things that decide it

1. **Program ROM WAS ~15x over - now solved (step D).** Nothing past one MK1
   stage fitted until Wolf freed program ROM. The candidate is the **204 KB REVX pool** (the VS / ending
   movie frames): on the T-unit they must sit in program ROM because the movie
   player reads them with the CPU, but on Wolf the CPU can read image ROM through
   the `sysctrl` bank window (bits 8-9). Moving the frames into spare video ROM
   on Wolf would free up to ~200 KB. **Prerequisite for Sindel and Kano.**
2. **Music outgrows MAME's 4 sound chips.** MAME's `umk3` loads u2-u5 only, so
   1.05 MB is the testable ceiling - about 2.5 minutes of music in total, or
   ~25 s per stage for six stages. A real board with u6-u9 fitted has ~5 MB.
   Choices: loop a shorter section of each song, carry music only for the stages
   that matter most, or accept that the full set is real-hardware only.
3. **Sindel's art has to be decoded out of an MK3 ROM set.** The MK3 tree has
   her code and `.TBL` headers (`REV21`) but no `.IMG` art. The umk3 donor's
   u122-u133 are MK3's own chips, but UMK3 replaced u118-u121; if any of her
   frames live there, `mk3.zip` (not on this machine) is needed. Same approach
   as THE THRONE ROOM's decode from `mk.zip`.

## Build order

| step | what | why first |
|---|---|---|
| A | Wolf art region above 12 MB in `makevrom.py` / `build.py` / `makewolf.py` | **done** - every new image needs it |
| B | Wolf sound overlay (`sound/wolf_patch.txt`) + MK1 music capture -> loop -> encode | cheap, independent |
| C | Courtyard, Palace Gates (MK1, decoded from `mk.zip`, the THE THRONE ROOM tooling) + their music, then music for the 4 existing MK1 stages | **THE COURTYARD and PALACE GATES done** (curback `1Dh` / `1Eh`, 2026-10-07 - `tools/make_mk1court.py` / `make_mk1gates.py`, `src/MK1CRT.ASM` / `MK1GATE.ASM`, doc/MK1_COURTYARD_GATES.md); their music is still the Tower set until step B |
| D | Free program ROM on Wolf (VS portraits into video ROM) | **done** - 6,270 -> 210,546 bytes |
| E | Scorpion's Lair | **done** (curback `1Fh`, 2026-10-07 - `tools/make_umk3lair.py`, `src/UMK3LAIR.ASM`, doc/UMK3_SCORPIONS_LAIR.md), stage fatality included; the CPU does not take it yet |
| F | Kano as a Shang morph | a full fighter in disguise. **Art ripped** (2026-10-07): `tools/make_mk1kano.py --apply` writes `data/MK1KANO.IMG` - all 71 of his MK1 lanes (fighter table `FFCE4B90` entry 1), 199 frames, 1,310 piece records with anipoints, `KANO1_P` / `KANO2_P` (given / mirror), ~628 KB flat 6bpp; the lane -> frame -> piece map and per-lane sheets are in `tmp/mk1kano/` (`lanes.txt`, `all_lanes.png`). Reference library, in no LOD yet. Next: map his lanes onto MK2's anitab rows, then the move code |
| F2 | MK3 Sonya as a Shang morph | **Her body and her four specials are in** (2026-10-07; rings, square wave, leg grab, bicycle kick - `src/UMK3SNYM.ASM`, 12/12 in `wolf_sonya_specials.lua`): Shang's Down+Block+LP (placeholder) morphs him into ochar 20, and she walks, strikes, jumps, blocks and takes hits in her own MK3 art (all 498 UMK3 records, 483 packed at 0xC88000). Every ochar table carries a Wolf-only row (`tools/wolf_fighter_rows.py`), T-unit byte-identical. Fatalities (both use MK3's run button), CPU and the drawn morph frames to come. See [WOLF_SONYA.md](WOLF_SONYA.md) |
| G | Sindel | the largest item - art decode, moves, AI, fatalities, select / VS |
| H | MK3 Nightwolf (ochar 23) | **Selectable and fighting** (2026-10-12): a START tap on Liu Kang's square; all 995 of MK3's records (deadlythirdcombat `INDIAN*.IMG`, by MK3's own `MKIND*.TBL` names) in the u110-u113 block, MK3's lanes, his four MK3 specials (arrow, hatchet uppercut, reflector, shoulder charge) proven by damage. Fatalities, voice, VS portrait to come. See [WOLF_NIGHTWOLF.md](WOLF_NIGHTWOLF.md) |

## Decisions (2026-10-07)

- **Sindel** - from UMK3; a **hidden START tap on Mileena**'s select cell
  (like Jade / Ermac / Rain). It was on Shang Tsung's cell until 2026-10-10.
- **Scorpion's Lair** - added, **with its stage fatality**.
- **Stage rotation** - every new stage (THE COURTYARD, PALACE GATES, SCORPION'S
  LAIR) joins the NORMAL rotation, `match_stage_cycle` (MAIN.ASM) and
  `vs_stage_cycle` (MKSEL.ASM), under `.if wunit`; MK1's three existing stages
  (`1Ah`-`1Ch`) are already in it.
- **Kano** - Shang's morph carries Kano's **full MK1 move set**.
- **MK3 Sonya** (2026-10-07) - Wolf only, reachable ONLY as a Shang Tsung morph (like Kano), with her UMK3 specials and fatalities.
- **Shang's morph inputs are MK3's own** (`MK3SRC/V13/MOVES.ASM`), minus the run
  button, as long as no other input of his already has them (the user's call):
  **Sonya** Down + Block + LP (MK3: Down + LP + Block + Run, `check_st_2_sonya`);
  **Kano** Back, Forward + Block (`sm_st_bc` entry `do_st_2_kano`); **Sindel**
  Back, Down, Back + LK (`sm_st_lkc`). Checked against Shang's MK2 inputs: Kano's
  B,F is not the tail of his Liu Kang B,F,F (test Kano after it), and Kung Lao's
  B,D,B is on HK, not LK.
- **Sindel and Sonya get NO RUN and NO UMK3 dial-a-combos** (the user's call): they play by MK2's rules - walk, block, MK2's normals, plus their own specials.
- **Music** - the **full** MK1 stage audio, end stings included. That exceeds
  MAME's four sound chips (1.05 MB free), so the full set is real-hardware
  sized; how to test it in MAME is an open item.
- **Kano and MK1 stage art** are ripped out of `mk.zip` into IMG libraries
  (`data/MK1KANO.IMG` and per-stage libraries), palettes included, with each
  stage's ANIMATED background pieces - the same decode THE THRONE ROOM used.

## Sources

| item | art | code |
|---|---|---|
| Sindel | `deadlythirdcombat-main/LIA1-11.IMG` (MK3's code name: `ft_lia` = 6) | MK3 `REV21` asm; UMK3 C (`UltimateMortalKombat3/.../src`) for UMK3 changes |
| Scorpion's Lair | `deadlythirdcombat-main/MKHELL.BDB/.BDD` | UMK3 C: `MKBKGD.C`, `MKFATAL.C`, `MKREACT.C` |
| Sonya (MK3/UMK3) | `umk3.zip`, decoded into `data/UMK3SNYA.IMG` (`deadlythirdcombat-main/BLADE1-11.IMG` is the art library) | MK3 arcade asm `MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13` (`MKSONYA.ASM`, `MOVES.ASM`, `MKSTK.ASM`...); UMK3 C for UMK3 changes |
| Kano (MK1) | `mk.zip`, decoded into `data/MK1KANO.IMG` | MK1 arcade (disassembly), MK2's Shang morph plumbing |
| Courtyard, Palace Gates | `mk.zip` (THE THRONE ROOM's decode) | MK1 stage records |
| MK1 music / audio | MAME capture (`DCSExplorer/mk1_audio`), OKI bank | - |
| cross-check | `deadlythirdcombat-main/mk3_rev1.zip` (MK3 rev 2.0 ROM set) | - |
| MK3 source / rebuild | `mk3-rebuild-main` (`REV13`, `REV21` asm + `.TBL`s, `ti/`, `DATA/`) | the MK3 game itself |

## Open questions

- **Testing the full music in MAME.** `umk3` loads four 1 MB sound chips; the
  full MK1 music needs more. Options: a local MAME driver with u6-u9, or a
  short-loop MAME variant of the sound set beside the full one.

## Sindel - a selectable fighter (2026-10-08): ochar 21, START tap on Mileena

She is in the Wolf ROM and pickable. **Ochar 21**, not the 22 first planned:
the ochar tables need contiguous rows and Kano does not exist yet, so he takes
the next one.

- **Art:** `tools/make_umk3sindel.py` rips exactly the 494 pieces her UMK3
  animation tables draw (`character_anitabs1/2` entry 6: TABLE1 `FF88C760`,
  TABLE2 `FF88D080`) out of `umk3.zip`. 449 take MK3's own names (UMK3's
  header run from `FFC271C0` is MKLIA.TBL + MKLIA2.TBL + MKLIA3.TBL record for
  record until MKLIA3's third); 45 are UMK3-only and are named here:
  `SNHAIR1-36` (the hair wrap, body art in her costume) and `SNFIREB1-9` (the
  redrawn fireball, its own palette `SNFIREB_P`).
  - Two libraries and two packs, because one ~2 MB IMG hangs LOAD2:
    `data/UMK3SDA` (269 records, linear 0xD6A000, 365,008 B packed) and
    `data/UMK3SDB` (225, linear 0xDC8000, 355,596 B). `--check` (Phase D)
    decodes every packed record back to umk3.zip's pixels.
  - LOAD2 FINISHES on these; it is the DOSBox window that does not close when
    one LOD is run by hand. Watch for `tmp/load2/<stem>.TBL`, then kill it.
- **Lanes:** `tools/make_umk3sindel_asm.py` writes `src/UMK3SDL.ASM` by
  DECOMPILING her UMK3 lanes, not by copying MK3's `MKLIA.ASM` - 287 records
  MK3's lanes name are drawn by none of her UMK3 lanes, and two UMK3 lanes are
  art MK3 never had. The animator commands are the same numbers in MK3 and
  MK2. `ani_calla` targets are mapped by hand (`CALLA`): `sweep_sounds` is
  MK2's, `new_float_ani` / `slave_inviso` / `slave_viso` are local copies.
  TABLE2 row 9 (`ochar_ripped_anis`) is a table of MK3 fighters' lanes, not a
  lane, and is 0. Thrown / fatality-victim rows are Kitana's MK2 lanes, as
  for Sonya, with 69 frames made Sindel's.
  - `tools/sindel_lane_proof.py` walks every lane in the BUILT Wolf ROM beside
    the UMK3 lane it came from, following jumps: same commands, operands and
    decoded pixels. 51 of 51.
- **Fighter rows:** `tools/wolf_fighter_rows.py` `SINDEL` - her lanes,
  `LPRP_P` on every costume lane, `sindel_strikes` (MK3's `stk_li_*` boxes on
  Kitana's layout), `BAR_SINDEL`, "SINDEL WINS" + its announcer line (086h),
  her ladder mug. Handlers: `sd_*` (src/UMK3SDM.ASM).
  - **MOVES.ASM is at GSPA's ceiling on the Wolf pass**: a second fighter's
    row per table aborted it with `>> Out of memory`. The generated blocks are
    now ONE data line per table with short comments.
- **Select:** a clean START tap on Mileena's square (moved off Shang Tsung's
  on 2026-10-10; the box wipe is `FN2BOX1-9` in `data/MKBOXES.IMG`, counting
  UP like Ermac's, FN2BOX2-9 packed by `data/SNBOX.LOD` on the library
  palette named `SNBOX1`) (`morph_table`,
  MKSEL.ASM; `f_sindel_cheat1/2`, `sindel_pos`, `sindel_pick` in RAM.ASM;
  `pid_sinbox` 012ch; `sindel_select_cheat_apply`, MAIN.ASM). Always
  unlocked. Her VS portrait is `zipped_pics` 15h via `vs_sanitize_char_a8`.
- **Rigs** (Wolf ROM, `tools/run_wolf_boot_probe.ps1 -Script ...`):
  `wolf_sindel_select.lua` - real joystick to Mileena (Down, Down), START on / off / on
  (flag and box frame 1/8, 0/0, 1/8), then she must fight as ochar 21;
  `SS_NOTAP=1` is the control (fights as Mileena).
  `wolf_sindel_view.lua` - 16 basics with snapshots, no reboot.
  **A rig must press BOTH Start buttons**: "2 Players Start" alone leaves P1
  out of the game and `p1_char` reads FFFFh.
- **Moves** (2026-10-08, `src/UMK3SDM.ASM`, hand-written; MK3's inputs, no run):

  | move | input | MK3 routine |
  |---|---|---|
  | fireball | Forward, Forward + LP | `do_lia_forward_zap` |
  | air fireball | Down, Forward + LK in the air (also while levitating) | `do_lia_anglez` |
  | scream | Forward, Forward, Forward + HP | `stat_do_lia_scream` + `r_scream` |
  | levitate | Back, Back, Forward + HK; stick flies her, Block lands | `do_lia_fly` |
  | scream fatality | Back, Back, Forward + Block, close | `lia_scream_rip` |
  | hair spin fatality | Down, Down, Back + Block, 050h-090h apart | `lia_hair_spin` |
  | babality | Down, Down, Down + LK (Kitana's) | - |
  | stage fatality | Down, Forward, Forward + Block (the ninjas') | - |

  - **The two fatality inputs are this project's**: MK3 put both on RUN /
    BLOCK taps, and there is no run.
  - Strike rows 1Bh-1Fh of `sindel_strikes`: the scream (hit -> `react_to_fn`
    1Bh `r_sd_scream`, MKREACT.ASM, Wolf only; no damage) and the fireballs
    (MK3's boxes, 20 / 2; the hit is MILEENA's sai stumble `r_tsai` - Kitana's
    fan hit staggers a man back for over a second).
  - **The scream fatality is adapted.** MK3 flays the victim on art drawn per
    MK3 fighter (`ochar_ripped_anis`), which no MK2 body has: here he is held
    shaking with blood tearing off him and is left MK3's skeleton
    (SKELFIRE14-24, Sonya's kiss pack), which collapses.
  - **Pit II cannot be done TO her**: `do_down_the_pit` (MKDEATH.ASM) gives a
    victim of ochar 21 the plain finishing uppercut - she has no Pit II fall
    art yet. In the routine itself, so the CPU's path is covered too. Take
    the `.if wunit` block out when her fall frames exist.
  - **Three traps this port hit:**
    - **MK2's `set_inviso` takes the object in a0** (MK3's takes a8). A
      straight port never hides anything - and Sonya's kiss had the same
      slip, fixed with it.
    - **UMK3's TABLE1 is not MK3's past the "flipped by" rows**: her
      projectile lane is UMK3 row 3Fh, not MK3's 37h (`UMK3_ROW`).
    - **A lane keeps parts AFTER its loop jump** (`ani_jump,loop / 0 /
      more`): the fireball's burst, the scream's lean back, the spinning top
      flying apart. The ripper and decompiler both follow it now - the first
      cut stopped at the jump and never packed the burst art.
    - A loop count held in a10 across `calla`s is not safe (the scream's
      victim shook forever); it lives in the process.
  - Rigs: `wolf_sindel_specials.lua` (8/8: fireball 20, scream holds 126
    frames for no damage and lets go, air fireball 20, levitate + Block) and
    `wolf_sindel_fatal.lua` (`WF_FATAL=RIP|HAIR|BABY|PIT|PIT2`, all PASS;
    PIT2 is Scorpion trying Pit II on her and must NOT start).
- **Fixes from play, 2026-10-08:**
  - **Losing to a sweep left her SITTING UP**: MK3's sweep fall ends
    cross-legged, MK2's ends flat, and MK2 parks a beaten fighter on that
    frame. `check_stay_down` (MKREACT.ASM) puts a beaten ochar 20+ on the
    last frame of her knockdown instead (Sonya too).
  - **FINISH HER** for ochar 20 and 21 (MAIN.ASM `hoh2`).
  - **Palette artifacts when thrown / launched**: the borrowed non-thrown
    rows (bike-kicked, banged, nut-crunched, Kintaro's throw) still drew
    Kitana's flipped / knockdown / stumble / stunned frames in her colours;
    they take Sindel's now, clamped to her last frame of a family. Only the
    gore frames (decap, torso rip, impale, back break, head hole) are still
    Kitana's art - she has none.
  - **Fireball**: the ball starts 8 out and 20h down (her mouth) and the
    burst is placed ON the victim (lined up, 80h back, top 0E0h over the
    floor) - UMK3's `lia_forward_proc`, which the first port left out, so it
    burst at his feet. The air fireball's burst is placed MK3's way too.
  - **Air fireball**: input window 12h -> 20h and the height line 0B0h ->
    0A0h (MK2's own air-special line). Works from a straight or a forward
    jump (`AIRZAP` / `AIRZAPF` in the rig).
  - NOT REPRODUCED: "the scream randomly throws a low kick". The scream is
    clean on a hit, a whiff and a block (`SCREAM`, `SCREAMFAR`, `SCREAMBLK`).
    Her HIGH KICK lane opens on her low-kick frames (UMK3's art), and a
    missed scream input at close range is a plain High Punch / elbow.
- **Still to do:** her own baby art (she turns into Kitana's baby), the CPU
  using her specials, a Shang morph into her, alternate costumes (every lane
  is `LPRP_P`), her Pit II fall frames (yours to add), and the camera does
  not hold still while she levitates (MK3's `set_ignore_y`).

### The assets packed 2026-10-07

- **VS portrait:** `SINDELVS_vda` in `data/TMPLOAD.IMG` (138x158, palette
  `SINDELVS`, 247 colours). Built with `tools/vda_export.py TMPLOAD.IMG
  SINDELVS_vda VS_SD` and `tools/implode.py pack VS_SD` into `data/VS_SD.BIN`
  (15,301 bytes).
  - It lives in its OWN pack, `data/MK8WOLF.LOD`, and NOT in `MK8MIL.LOD`.
    MK8MIL is also the T-unit's program-ROM REVX pool, which has ~8 KB
    left, and Sindel is Wolf only.
  - MK8WOLF is based at the Wolf CPU address `05FA0000h`, which is inside the
    VS window `[wolf_vs_cpu, wolf_vs_end)` at linear 0FF4000h. So
    `VS_SD` (`src/MK8WZIP.TBL`) is used as it is: `zipped_pics` row **15h**
    in UNZIP.ASM, under `.if wunit`. `movie_run` selects bank 1 for it like
    the shared portraits.
  - `makewolf.py` places it, and dies if the shared portraits grow into it.
    They have 13,484 bytes of room today.
- **Name plate:** `BAR_SINDEL` in `data/MKSCORE.IMG` (49x10). Packed by
  `data/WOLFHUD.LOD` (linear 0xD50000, POF> ZON> PPP> 0, as MK6MIL's score
  area). `src/WOLFHUD.TBL` is included by MKDISP.ASM under `.if wunit`.
- **Name plate SAG:** `BAR_SINDEL` is `06A80000h`, bank 1, like every Wolf
  pack. A hand-run LOAD2 without `/E` once wrote it as `04A80000h`, which is
  bank 0 at linear 550000h - the wrong art, with no error. The build's own
  IMGBUILD.BAT line has `/E`.
- **Select-box wipe:** `SNBOX1-9` in `data/MKBOXES.IMG`, packed by
  `data/SNBOX.LOD` (Wolf linear 0xD58000, PON> ZOF> PPP> 8, 30,800 bytes).
  - It counts DOWN, like Rain's: SNBOX9 is Shang, colour-identical to the
    stock STBOX (3,850 of 3,850), so it is not packed and STBOX is frame 0.
    SNBOX1 is Sindel. The separate `SNBOX` record (SINBOX_P) is unpacked, as
    Rain's `RNBOX` is.
  - The lane is `sindel_frames` (MKSEL.ASM, `.if wunit`).
  - The palette `SNSTBOX_P` (238 colours) and its dimmed twin `SNSTBOXD_P`
    (R-12, G-11, B kept; the rule reproduces BOX15D_P from BOX15_P exactly)
    are generated into `src/SNBOXPAL.ASM` by `tools/make_snbox_pals.py`
    (Phase D `--check`). `box_dim_table` has her row under `.if wunit`.
- **Ladder mug** (the 1-player mountain): `smsnbox` in `data/MOUNTAIN.IMG`
  (35x45, `SNBOX65_P`, 7 bpp). It is the second section of `data/SNBOX.LOD`,
  and its palette is carried by the same tool.
- **All of it was wired 2026-10-08** - see the section above.
- **Checked:** every packed record decodes back to its library's pixels through
  its label (SNBOX1-8, smsnbox, BAR_SINDEL), and the packs read back byte for byte out of the 12-16 MB chips
  (u121..u118) in `rom/wolf/umk3.zip`. The T-unit is byte-identical apart from
  the build stamp.
