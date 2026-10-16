# MK3 ROBOT SMOKE - Wolf only, ochar 24, a START tap on Reptile

The cyborg Smoke from MK3, on the Wolf build only. **Status (2026-10-13):
selectable; his body, smoke trail, all four specials, his RUN and his MK3
COMBOS are in and proven.** The turbo meter is not drawn (`rsturbobar 0`) - he
is meant to be CPU-only.
Fatality, his own voice and sounds, his VS portrait and the CPU playing him are
still to come.

## How to reach him

On the select screen, put the cursor on **Reptile** and tap **START** (tap
again to go back). The box wipes from Reptile's face into MK3's own Smoke head,
as Liu Kang's does into Nightwolf's. Confirm as usual. Always unlocked.
Block x5 on the same square still gives Ermac: `rsmoke_select_cheat_apply`
(MAIN.ASM) only swaps a pick that is *still* Reptile, and it runs after
Ermac's.

## What he is in MK3

MK3 carries its three robot ninjas - Sektor (`ft_robo1`), Cyrax (`ft_robo2`)
and the hidden Smoke (`ft_smoke`) - as **one module**, `MKROBO.ASM` +
`MKROBO.TBL`/`MKROBO2.TBL`/`MKROBO3.TBL` (MK3SRC/V13). Smoke is **Sektor's body**
(the `RB*` frames; Cyrax's are `RB2*`) in his own costume, `SMOKE1_P`
(`SMOKE2_P` on the alternate), with a puff-of-smoke process on him the whole
fight (`smoke_smoke`, MKFX). So his record list is not "everything the tables
name" (it was for Nightwolf): it is everything **his lanes** draw.

## Where it all comes from

| piece | where |
|---|---|
| art | `tools/make_robosmoke.py`: `lanes()` walks MKROBO.ASM from the rows his port uses, taking each `ani_ochar_jump` the way MK3 does for `ft_smoke` (his branch becomes an `ani_jump`, Sektor's/Cyrax's are dropped) and never following an `ani_calla` into code; the art is the records those blocks name - **341**, all body, taken by name out of deadlythirdcombat's `ROBO1-13.IMG`. Two libraries + packs, `data/RSMOKA/B.IMG/.LOD`, 567 KB packed, `POF>` (his costume) |
| where | Wolf linear **0x16E2000-0x1780000**, the u110-u113 block right above Nightwolf (stock MAME loads it); loaded 4 MB lower and moved up by `makevrom.py WOLF_RELOCATE`. `--tables` (Phase B2d9r) relocates every SAG and merges LOAD2's `RSLA/RSLB/RSLS.TBL` into **`src/RSMOKE.TBL`**. **0x178A000-0x1800000 (472 KB) is left for his fatality art** |
| select art | `data/RSSEL.IMG/.LOD` (0x1780000, 32 KB), same tool: **RSBOX2-9** (Reptile's `RPBOX` wiping into MK3's `HDSMOKE`, `RSBOX_P` = RPBOX's colours at their own indices + his) and **smrsbox** (ladder mug, `RSMUG_P`). No name plate: MK2 already has `BAR_SMOKE` |
| spear art | **not packed again**: MK3's robot throws the same COMEHERE trident MK2 packs for ninja Smoke (`data/SMROPE.LOD`). His TABLE2 row 1 is ninja Smoke's own `a_sm_rope_ani` (MKNJ exports it) |
| lanes | `tools/make_robosmoke_asm.py` -> **`src/RSMOKEL.ASM`** (Phase B2d9r): his MK3 lanes (labels `rs_`), `rsmoke_anitab1` in MK2's TABLE1 layout, `rsmoke_anitab2`, `rsmoke_strikes`, his palettes |
| moves | **`src/RSMOKEM.ASM`** (hand-written) |
| ochar tables | `tools/wolf_fighter_rows.py` `RSMOKE` (proxy **ninja Smoke**, ochar 14) + the four tables padded past 20 rows by hand (MKDIE `ochar_arm_ripped_ani` / `inflate_animations`, MKDEATH `arm_ripped_adjust`, MKBLOOD `arm_flow_lineups`) + `stance_mirror` (MKGUYS) |
| select | `morph_table` row `ft_reptile -> 24`, `rsmoke_frames`, `pid_rsbox` 012eh, `box_dim_table` (BOX10_P and RSBOX_P + dimmed `RSBOXD_P`), `php_rsmoke` (ninja Smoke's "Smoke" call, 05dh), `vsca_rs` (Reptile's VS portrait for now) - MKSEL.ASM; `rsmoke_select_cheat_apply` (MAIN.ASM); `f_rsmoke_cheat1/2`, `rsmoke_pos`, `rsmoke_pick` (RAM.ASM) |
| throw | **MK3 Smoke's own throw**: MK3's `a_throw` sends `ft_smoke` to `a_smoke_throw` and `smoke_slam` slams on `a_air_slam`, so row 24 is `RBAIRSLAM3 \| 5-9 \| 9` (his air throw's art). It used to be Sektor's `RBSHOLDER` throw, whose grabbing arm MK3 draws as a SECOND object (`RBMECARM`, `ani_sladd`) - never made here, so he threw with no arm. `RBSHOLDER1-4` are packed and unused. `body_slam_init` (MKSLAM) gives ochar 24 **Scorpion's** "flipped by" row - every other Wolf fighter gets Kitana's, which is timed for a different throw |
| smoke | `pim_check_smoke` (MKGUYS) starts `rs_smoke_proc` on him: a puff every 4 ticks, none while he is invisible (MK3's `ssm4`) |

### Why ninja Smoke is his proxy

Every ochar table needs a row for him. A strike record's reaction word indexes
the **attacker's** `react_to_*` table, and his specials reuse MK2's ninja spear
(`spear_proc` fires strike row 11h = `stk_njspear`), so his strike table and
reaction table must both be the ninjas'. Of the ninjas, ninja Smoke matches
best: same spear, his projectile pids/oids and zap rows, his "SMOKE WINS",
announcer line and `BAR_SMOKE` plate. What ninja Smoke has *as a hidden boss* is
overridden back to an ordinary fighter's: `ochar_damage_table` 0 (not
`xlate_secret`), Reptile's walk, flip damage 34, `generic_victory` (shadow on).

## TABLE1

MK2 rows map onto his MK3 lanes by meaning. Rebuilt in MK2's shape from his
own frames: block, duck block, knockdown, flip kick (MK2 walks them one part
further than MK3 lays them out); **the jump** (row 6: MK2's `do_land_animation`
plays its PART 2 on every landing and MK3's `a_jump` has one part, so he ran off
the end into frame data and **vanished for the whole landing** - after every
jump, flip and teleport uppercut; `ani2_clip` counted it. His landing is
RBJUMP2,1, as the ninja's `a_njjumpup` lands on 2,1); **the throw** (row 24 - Sektor's `RBSHOLDER`
shoulder throw in `normal_slam`'s 1 | 5 | 3 shape, because `double_mframew`
stops on the VICTIM's terminator and every "flipped by ninja" lane is 1 | 5);
and **the dizzy** (row 28 - MK3's robots spark while stunned with MK3 code MK2
lacks, so it is a plain `RBSTUNNED` loop). Row 26 is his chest opening, 27 the
rope.

Rows MK3 has no lane for - thrown by each MK2 fighter (2Ah-35h), shredded (25h)
and the fatality-victim rows (36h-41h) - are the **male ninjas'** MK2 lanes
copied in (`rsn_`), with every ninja stumble / flipped / knockdown / stunned /
sweep-up / hit / sweep-fall / get-up frame swapped for his own of the same
number (91 frames). MKNJ's `ani_ochar_jump` branches are dropped - ochar 24
never matches them. **The gore frames are still the ninja's art** (decap, torso
rip, impale, back break, head hole, nut crunch) in Smoke's costume. Open item.

## His specials (`src/RSMOKEM.ASM`)

| move | input | how | measured |
|---|---|---|---|
| spear | Back, Back + LP | MK2's own `do_spear` / `do_throw_spear` / `do_rope_pull`; his TABLE2 row 0 is the chest opening (`RBCHEST1,2` \| `RBCHEST2` pull pose), row 1 the rope. **It leaves his CHEST, as MK3's**: `do_throw_spear` (MKZAP) moves the rope a further -81,+17 for ochar 24 (MK3's `do_smoke_spear` -120h,+28h, rebased onto our COMEHERE anipoints), and `lineup_rope_with_him` drops the taut rope 17px below his top (measured: both on the same row) | `act_spear`, P1 pulled in, 8 |
| teleport uppercut | Forward, Forward + LK (also from a jump) | MK3's `do_robo_tele` line for line: down into the floor, up out of it beside him on TABLE2 row 2 (`a_robo_telepunch`), strike row 12h (MK3 `stk_ro_tele` box, the ninja uppercut's reaction, MK3's damage); refused once he is 2 hits into a string (MK3 `q_smoke_tele`) | `act_decoy` -> `act_uppercut`, 16 |
| invisibility | hold Block, Up, Up + HP | MK3's `do_inviso` (TABLE2 row 3, six frames at 2, a smoke burst) on MK2's own `b_inviso` + `pid_inviso` machinery, so everything MK2 does for an invisible man applies | m_inviso on, then off |
| air throw | Block, in the air, close to an airborne man | `rs_block` is MK3's `smoke_block_close` (= MK2's `sc_block` test); `do_rs_air_slam` is MK2's `do_air_body_slam` with his MK3 air-slam art (TABLE2 row 4: `RBAIRSLAM3` \| `5-9`) | `act_bodyslam`, 34 |

- **Invisibility's input differs from MK3's** (Up, Up + Run): MK2 has no run
  button, and Up jumps unless Block is held - holding Block through the Ups is
  MK2's own grammar for an Up,Up move (Reptile's invisibility, Scorpion's MK3
  fatality). The combo mask leaves Block out so it may be held.
- **Block on the ground** goes to `check_nj_dtp`: the ninjas' pit / stage
  fatality, as Rain's row does.
- Sounds are MK2 stand-ins (`rsnd_whoosh` for the teleport; the spear's own;
  `p1p2_sound` for the air throw).

## His run (`rs_run`, RSMOKEM.ASM)

**Hold Run while walking forward.** MK3's `joy_run`: TABLE2 row 5 (MK3's
`a_run`, RBRUN1-12), spending one tick of **turbo** a tick; he stops when the
turbo is gone, Run is let go, the stick leaves "toward", or he passes the other
man. The meter is MK3's (but **not drawn**: `rsturbobar .set 0`, RSMOKEM.ASM; `1`
brings the bar back): 48 (`full_turbo`), refilled one a tick after 40 ticks
unused (`turbo_raise_delay`), full again every round, and **emptied by every
combo hit** (MK3's `zero_turbo_bar`, "avoid sprint abusers"). It is drawn as
MK3 drew it, a thin yellow bar under his strength bar: score-area DMA entries
21/22 (`setup_score_ram`, MKDISP.ASM - the list had room for 30, used 20),
sized every frame by `rs_turbo_frame` (called from MKINIT's main loop), zero
wide - not drawn - for anybody but him.

- **He runs at 7 px a tick, not MK3's 8.** The camera picks the first
  `right_scrolls` row at least as fast as the fastest fighter, and there is no
  8 row (7, then 10): at 8 the camera takes 10, outruns him and stops - the Kano
  flip shake.
- **THE WOLF'S RUN BUTTON IS A SECOND BLOCK BUTTON, for everybody.** MAME's
  umk3 IN1 puts "P1 Run"/"P2 Run" at bits 2/6, `wolf_inputs` (MKINIT) carries
  IN1 into `gsw2` unchanged, and `swtab` entries 42h/46h - "doubled for sf2 kit"
  - send those bits to `p1_button2`/`p2_button2`: Block. So on the Wolf, Run has
  always been an extra Block, and still is for every other fighter. For him the
  press would spawn a block that took him over before the run started (the
  first rig run read `act_blockhi` while Run was held), so on Wolf those two
  entries go to `p1_runbutton`/`p2_runbutton`, which drop the press when the
  player is ochar 24 and pass it to Block otherwise.
- MK3's run footstep (`rsnd_footstep`) has no MK2 sound: `rs_footstep` is silent.
- Jumping out of a run does not jump further (MK3's `do_flip` checks for the
  run lane) - not ported.

## His combos (`rs_elbow` / `rs_knee` / `rs_combo`, RSMOKEM.ASM)

MK3's dial-a-combos (`process_combo_table`, MKCOMBO.ASM) with his own tables
(`ct_smoke_*`), opened from his close high punch (`do_elbow`) and his close
high kick (`do_knee`) - MOVES.ASM jumps to his for ochar 24 only:

| opener | then | hits |
|---|---|---|
| close HP (elbow) | HP, LK, HK, LP | 5 |
| close HP (elbow) | HP, HK | 3 |
| close HP (elbow) | HP, LP | 3 |
| close HK (knee) | HK, LP | 3 |

Each next button must come within **9 ticks** (MK3's time allowed); a press made
while the last hit is still animating counts (MK3's combo RAM did the same - here
it is the button-close queue, read as Liu Kang's double knee reads it). The
animations are his MK3 lanes' own combo parts (elbow parts 3/4, knee, high
kick); the hits are rows 13h-15h of his strike table: MK3's `combo_strike_table`
box and damage (7, 1 chip) on the ninja's face-hit / elbow / roundhouse
reactions, so MK2's combo damage scaling applies. Only a human combos (the CPU
never plays him). **Trap it hit:** `get_char_ani` loads a14, so the part number
has to be kept off a14 across it - with a14 = 0 `find_part_a14` spins without
sleeping and the whole board hangs mid-frame.

## Verified

`tools/wolf_rsmoke_check.lua` (`tools/run_wolf_boot_probe.ps1 -Script
wolf_rsmoke_check.lua -Env "WS_MAP=<repo>\tmp\wolf\src\MK2.MAP"`), Wolf ROM,
2-player: P2's cursor starts on Reptile; START on/off/on reads flag/frame
**1/8, 0/0, 1/8**; P2 fights as **ochar 24**; invisibility on and off, spear 8,
teleport uppercut 16, **run 7.00 px/tick (turbo 48 -> 17, read out of `rs_turbo`; both
bars 0 wide - not drawn; back to 48)**, **elbow combo 5 hits (24 6 6 6 3)**,
**knee combo 3 hits (16 6 3)**, **ground throw 34** (THROW phase), air throw
34, `ani2_clip` unmoved in every phase (a landing that runs off its lane fails
it - the teleport uppercut did, +2, before row 6 got its part 2), no reboot -
**PASS** (2026-10-13). `RS_TRACE=1` logs his frame every tick, `RS_SNAPALL=1`
snaps every tick, `RS_ONLY=SPEAR,THROW` plays only those phases. The rig resolves
Forward/Back from the two positions every frame (the teleport puts him on the
other side). `RS_NOTAP=1` is the control: P2 fights as Reptile and plays the same RUN and
ELBOWC phases, which must both FAIL - he blocks on Run and walks (0.9 px/tick),
his elbow is one hit, no turbo bar for either player - **PASS**.
Nightwolf's rig still passes on the same ROM. T-unit: `RSMOKEL.OBJ` /
`RSMOKEM.OBJ` assemble empty and every other edit is inside `.if wunit`; the
one exception is MKNJ's new `.globl a_sm_rope_ani`, a symbol export with no code
bytes.

## Not done

- fatalities (MK3: the earth blow-up `smoke_blowup_earth` / `smoke_arm` with the
  `EARTH*`/`SMMECARM*`/`SMBOMB` art in MKROBO3.TBL - not packed yet; 540 KB is
  reserved above his packs), animality / friendship / babality n/a;
- his own voice and move sounds (MK3's robot set);
- his VS portrait (Reptile's shows); MK3 has no robot-Smoke bio VDA either;
- the CPU never plays him (human-picked only), and his drone rows are ninja
  Smoke's;
- the gore rows draw the ninja's art;
- a Shang Tsung morph into him.
