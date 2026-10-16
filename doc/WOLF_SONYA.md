# MK3 SONYA - Wolf only, Shang Tsung's morph (ochar 20)

Sonya Blade from MK3/UMK3, on the Wolf build only, reached only as a Shang Tsung
morph (doc/WOLF_CONTENT_PLAN.md). No run, no dial-a-combos: she plays by MK2's
rules. **Status: her body and her four specials are in** - the morph, every
normal, jumps, blocks, hit reactions, the revert, and the energy rings, square
wave, leg grab and bicycle kick. Her fatalities (both use MK3's run button -
an open question), the CPU and the morph's own transition frames are still to
come.

## How to reach her

Shang Tsung: **hold Down + Block, tap Low Punch** (`stlp_fight`, MOVES.ASM) -
MK3's own input (`check_st_2_sonya`: Down + LP + Block + Run) without the run
button, which this game does not have. It is the same chord shape as his Rain
morph on Low Kick; block held means no combo special can be live
(`button_mask`), so it collides with nothing.

The transition is a **stand-in**: Mileena's retail morph frames under Jade's
green (`a_st_2_sonya`, MKST.ASM, `st_anitab2` row 17h; `st_hidden_morph_row`
answers ochar 20 with that row and `SHJADE_P`), landing on her first stance
frame. The user is drawing the real Shang-to-Sonya frames.

## Where it all comes from

| piece | where |
|---|---|
| art | `tools/make_umk3sonya.py`: all 498 of her records in UMK3's header table (`FFBCF230..FFBDCCF0`), which is MK3's `MKSONYA.TBL` + `MKSONYA2.TBL` record for record - the run frames (`SBRUN*`) left out, 483 kept. `data/UMK3SNYA.IMG` + `data/UMK3SNY.LOD`, packed at Wolf linear `0xC88000` (634 KB). `--check` proves the IMG, the LOD and every packed record against `umk3.zip` |
| lanes | `tools/make_umk3sonya_asm.py` -> `src/UMK3SNYL.ASM`: MK3's own `MKSONYA.ASM` lanes (labels `sn_`), `sonya_anitab1` in MK2's TABLE1 layout, `sonya_anitab2` (MK3's six rows), her eight palettes |
| ochar tables | `tools/wolf_fighter_rows.py`: one `.if wunit` row for ochar 20 in each of the 132 ochar-indexed tables `tools/audit_char_tables.py` knows - Kitana's row (her proxy) unless `OVERRIDES` names Sonya's own |
| morph | `do_st_2_sonya` / `stlp_fight` / `st_hidden_morph_row` (MOVES.ASM), `a_st_2_sonya` (MKST.ASM) |
| specials | `src/UMK3SNYM.ASM` (hand-written): her handlers, rings, square wave, leg grab, bicycle kick |
| rigs | `tools/run_wolf_boot_probe.ps1 -Script wolf_sonya_check.lua` (body; `WS_MAP` / `WS_TBL` in the environment) and `-Script wolf_sonya_specials.lua` (`WS_MAP`; `WS_ONLY=RINGS,SQUARE,LEGS,BIKE`, `WS_TRIALS`, `WS_TRACE`, `WS_COLBOX=1` hitbox overlay, `WS_FILM=1` filmstrip) |

**The art is MK3's.** UMK3 packs exactly MK3's records in MK3's order, and
`MKSONYA.TBL`'s SAGs are UMK3's own, so every record carries MK3's name. Most
of her art is reached by animation tables, but ~95 records are reached by CODE
(the ring projectile `SBZAP6-16`, the kiss `SPARKISS`/`KISSORB`, the drops
`SBDROP`, the ring-throw pose `SBTHROWPRO`) - which is why the rip walks the
header table and not the animation tables.

**Palettes.** Her body is drawn in her costume (`SBGREEN_P`, `SBLTBLU_P` on
Start+LP and the mirror lane), so the body packs `POF>`. Effects pack `PON>` in
their own: `SBZAP_P` (ring), `DROP_P`, `SPARKIS_P`, `KISSORB_P`, `ENGPINK_P`
(the kiss's energy ball - named by MK3's hand-written `FAKE_ENGBALL1` header)
and `GUTS_P`. `MKSONYA2.TBL` INTERLEAVES its groups (SPARKISS1, KISSORB1,
SPARKISS2...), so a palette is taken by family, not from the record above.
`ENGBALL15B`, the crushed ball, is authored on `GUTS_P` (MK3's own
`BLADE11.IMG`, palnum 9).

## TABLE1 - what MK3 has and MK2 needs

MK2's TABLE1 rows 0-29h map onto her MK3 lanes by meaning (skip = walk;
`a_throw` is her body slam; `a_zap` her projectile throw). Rows MK3 has no lane
for are **Kitana's MK2 lanes copied in**:

- **2Ah-35h, thrown by each MK2 fighter**: Kitana's lanes (their adjustments are
  timed to MK2's throws), with her stumble / flipped / knockdown / stunned /
  sweep-up frames replaced by Sonya's of the same number (69 frames). **Not yet
  seen in the rig.**
- **36h-42h and 25h/27h, the fatality victim rows**: Kitana's lanes **and
  Kitana's art** - Sonya has no gore in MK2's shape. The Kitana records those
  lanes draw are local to MKFN, so `make_umk3sonya_asm.py` copies their headers
  into `UMK3SNYL.ASM` (no palette long: drawn in Sonya's palette). Open item.

## Her specials (`src/UMK3SNYM.ASM`, hand-written)

Inputs are MK3's own (`MK3SRC/V13/MOVES.ASM`); none uses the run button.

| move | input | from | lands for |
|---|---|---|---|
| energy rings | Down, Forward + LP | MK3 `do_sonya_zap` / `sonya_zap_proc` on MK2's projectile plumbing (Jax's wave): TABLE1 026h throw (glow palette, the ring as a slave in her hands), 027h flight; a PREZAP check at her hands first (stk 01ch), then 8 a tick checking 01bh, part two the burst | 19 |
| square wave | Forward, Back + HP | MK3 `do_square_wave` (`do_sny_square`), NOT Kitana's MK2 one | 27 |
| leg grab | Down + LP + Block | MK3 `do_leg_throw` through Baraka's MK2 port of it (`do_sa_leggrab`): catch window, boss check, z re-asserted, victim on his KNOCKDOWN1 and flipped on slot 035h part two in lockstep with hers, `salg_slammed` landing | 26 |
| bicycle kick | Back, Back, Down + HK | MK3 `sonya_bike_kick`: she rises on a slant, a man she catches rides up on her feet, then `r_bike_kicked_done` drops him | 22 |

Damage is MK3's (stk damage words), and MK2's combo scaling applies on top.

**Her strike table** (`sonya_strikes`, generated into `UMK3SNYL.ASM`) keeps
Kitana's index layout, so MK2's own code finds its rows: normals 00h-0fh take
MK3's boxes (they fit her sprites) with Kitana's MK2 reaction, damage, score
and sound; 15h is MK3's square box; her specials sit after Kitana's 1ah rows
(1bh ring, 1ch prezap, 1dh bike, 1eh leg grab). **TABLE2** is MK3's six lanes
re-ordered: 0 leg grab, 1 bike, 2 death kiss, 3 energy ball, 4 gutz, 5 square.

Three things learned on the way:

- **MK3's square-wave height (060h) flew her along the top of the screen**:
  MK2's `distance_off_ground` is `p_ganiy - oypos`, the TOP of her stance
  sprite against the top of the frame she is in, which is not MK3's measure.
  01ch (`snysq_height`) puts her punch box across a standing man's head - set
  by the `f_colbox` overlay (`WS_COLBOX=1`), not by eye.
- **A loop counter pushed on the system stack does not survive a `sleep`**
  (the stack is shared by every process): the first leg grab rebooted the
  board on its throw. The count lives in `p_store1` now.
- **The leg grab needs a reaction row**: its record says hit 1ah / block 18h,
  and Kitana's `react_to_fn` (her proxy) ended at 19h, so row 1ah
  (`r_sa_leggrab`) is appended there under `.if wunit` - harmless to the
  female ninjas, who never strike with 1ah.

Exports made for her, all `.if wunit`: `death`, `salg_slammed` (MOVES.ASM);
`proj_strike_check`, `null_proj_stk` (MKZAP.ASM).

## The ochar tables (`wolf_fighter_rows.py`)

Every row is inside `.if wunit`, so **the T-unit build is byte-identical**
(checked against `mk2.out` after every step). The tool evaluates each table's
own `.if` blocks for the Wolf build, so it knows rows 0..19 and appends row 20
after the last line. Tables already longer than 20 rows (four of them) are
left alone. Three tools generate char tables of their own -
`cage_brain_wax_import.py`, `make_soulrip_pals.py`, `subspine_wax_import.py` -
and call `wolf_fighter_rows.block()` so their output carries the same block.
`sz_headrip_reaches` / `sz_headrip_poses` were char-indexed and missing from
the audit; they are listed now.

**MKDRONE took 24 `.if wunit` blocks without the GSPA out-of-memory abort**
(measured in a scratch copy first, both boards).

**A table's last line is its last DATA line**, extended only over `.else` /
`.endif` lines that close a block the table itself opened. The first cut
counted any directive, so a table followed by an unrelated `.if` (MKSTK's
`.if stkphase`) had her row put INSIDE that block; MKDISP, MKDRONE and MKGUYS
had the same misplacement until it was fixed.

Overrides today: her two animation tables, her strike table, all seven costume
tables and their blood twins, `bloody_palettes`, her four handlers (HP, LP,
Block, HK -> `sny_*`, UMK3SNYM.ASM), every other special-move handler row
(`sucide` - Kitana's would play fan lanes out of HER table 2),
`ochar_power_punches` and `ochar_baby_combos` (0). Everything else is
Kitana's: her reactions (`react_to_fn`, plus row 1ah), her freeze / shock
palettes (which repaint the body in KITANA's colour layout - wrong on Sonya,
open item), her drone rows.

## Verified

`wolf_sonya_specials.lua`: 12 of 12 - rings 19 (then 15, 9: they chain, so
MK2's combo scaling cuts them), square wave 27, leg grab 26, bicycle kick 22,
each thrown three times at an idle Jax from a set gap, no reboot.

`wolf_sonya_check.lua`, 2-player Shang v Jax on the Wolf build: the chord
morphs him at +66 ticks; over 3,000 ticks of walking, punches, kicks,
uppercut, sweep, jumps, block, hits from Jax and the timed revert (re-morphed
each time) she is drawn with **99 distinct pieces of her own and none that are
not** (the morph frames, `act_morph`, are Shang's and excluded), and
`illop_count` never moves - **PASS**. T-unit `mk2.out` byte-identical.

## Her voice and sounds (`tools/make_wolf_audio.py`)

Her UMK3 sounds, and Sindel's, are a Wolf-only sound overlay. The tool reads
MK3's `MKSOUND.ASM` tables (`st_sonya`, `st_lia`, the female rows of the
`gp_*` groups, the name/wins lines) for the track numbers. It exports those
streams RAW out of `umk3.zip` with DCSExplorer into `sound/wolf/umk3/`
(27 streams, 134 KB; both boards run DCS 1.01, so they are stored byte for
byte). Then it writes three things:

- `sound/wolf_patch.txt`: tracks $0600..$0659, one triple per sound.
  `makewolf.py` appends it to the Wolf patch.
- `src/WOLFSND.ASM`: `triple_sndtab2` rows 69h..86h.
- `src/WOLFSNDE.ASM`: the `wsnd_*` equates.

Sindel's fly-across ($030C) is not in `umk3.zip`. `--check` runs in Phase D.

`rsnd_ochar` (MKSOUND.ASM) sends ochar 20 (Sonya) and 22 (Sindel, to come)
to `rsnd_mk3fem`. It maps MK2's female voice indices onto the overlay's
rows and sends them with **`triple_sound2`**: the overlay is in table 2, and
`triple_sound` (table 1) plays an unrelated MK2 sound.

Measured on the sound port (`wolf_sonya_specials.lua`, `WS_SND=1`):

| moment | track |
|---|---|
| rings thrown | 0600 |
| ring hit, Jax hit the same tick | 0604 |
| square-wave fly | 060C |
| her attack yell | 0631 |
| bicycle | 060B, 060F |

**Rig trap:** the port takes two byte writes per code (`FFhi`, `FFlo`).
Read in pairs. Reading them shifted by one byte turned 0604 + 02AA into a
phantom "0402".

## Her fatalities (`src/UMK3SNYM.ASM`)

MK3's two, `sonya_kiss` and `sonya_kiss_crusher` (MKFATAL.ASM), ported
call for call. MK3 put both on the RUN button; here (the user's call) Block
stands in:

| | input | range | MK3 |
|---|---|---|---|
| fire kiss | Back, Forward, Down, Down + **Block** | anywhere | B,F,D,D + Run |
| crusher | **hold Block**, Up, Up, Back, Down | 0d0h-140h apart | Block+Run held, U,U,B,D |

- **The crusher fires on the stick, not a button.** It is MK3's
  `sonya_down_close` (`sm_sonya_dc`): the Down press with Block (and Run)
  HELD. The held Block is what stops the two Ups jumping. It is
  `char_joydown` row 20 -> `sny_down`.
- **Fire kiss.** Her TABLE2 row 2 is played frame for frame with the orb
  (row 2 part 2: SPARKISS, then KISSORB with a `swpal`, because `frame_a9`
  never re-reads a palette). The orb arcs over and comes down onto his chest
  in 10h ticks. He screams and is replaced by MK3's burning skeleton.
- **MK3's `a_sb_skeleton_burn` has no terminator.** Its two `SBFIRE` frames
  run straight on into `a_robo_skeleton_burn`, SKELFIRE1-24: catch fire, burn
  (looped 3 times), the standing skeleton, the collapse. That is the skeleton
  MK3 shows, so all 36 records are packed. They are MK3's SHARED fatality art
  (MKFATAL.TBL), found in UMK3's header table from `SBFIRE1` (FFD41490),
  where MKFATAL's headers run contiguously, and each one is checked against
  MK3's geometry.
- **The skeleton's palette is MK2's own.** MK3's `SKELFIR_P` is
  `IMGPAL6.ASM`'s word for word, so the lanes generator `.ref`s it rather
  than emitting a second copy. A duplicate symbol aborted the Wolf link.
- **Crusher.** She blows the kiss (row 2 part 1). The energy ball (our row 3,
  MK3's 4) forms beside her, glides until it is over him, and holds him
  struggling on his own stumble lane (MK2 row 23h; MK3's 20h part 2 does not
  exist in MK2). Then it crushes: his duck (MK2 row 5), and he BECOMES her
  gutz (our row 4, MK3's 5; `ani_swpal` onto `GUTS_P`) on the floor, in two
  bursts of blood.
- **Sounds** (overlay rows): `wsnd_sonya_6` for the blown kiss,
  `wsnd_sonya_7` for the crusher's rumble, and MK3's generic `fx_flames`,
  `fx_bones` and `fx_crush` (`triple_sndtab` 20h/21h/23h, appended to the
  overlay by `make_wolf_audio.py`'s `FX_ROWS`).

**LOAD2 TRAP - THE IMAGE LIBRARY HAS A SIZE CEILING.** With the skeleton
added, `UMK3SNYA.IMG` grew to 2.26 MB. LOAD2 then read garbage record names
("Image Library [C:\DATA\<junk>] could not be opened"), wrote a 65 KB stub
and sat on a prompt inside the DOSBox window, so the build hung with nothing
in `IMGBUILD.LOG`. At 1.94 MB it is fine. The record count was NOT the cause:
the 483-record LOD failed too once the IMG was big. So the fatality art is
its own library AND pack: `data/UMK3SNFA.IMG` + `data/UMK3SNF.LOD` (Wolf linear
0xD30000, 109 KB), `src/UMK3SNF.TBL`. Diagnose a hung LOAD2 by running the
one LOD alone with its output redirected to a file.

Rig `tools/wolf_sonya_fatal.lua` (`WF_FATAL=KISS|CRUSH`): morph, a jab KO into
FINISH HIM, the input, then `f_death` must go to 1 / 2 and on to -1, with no
reboot. Snapshots every 6 frames. Both PASS, and the snapshots show the whole
of each fatality.

## Not done

- her pit fatality (Forward, Forward, Down + HP), and her fatalities for the CPU;
- the morph's own frames (being drawn);
- the thrown lanes are unverified;
- the gore rows draw Kitana's art;
- her body uses Kitana's freeze / shock palettes.
