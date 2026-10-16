# Dead art prune: nine packed runs nothing draws

**Status: removed, 2026-09-13.** This is the second pass after the
[ROTATE removal](ROTATE_ART_AUDIT.md), under opportunity 28 in
[the graphics audit](../GRAPHICS_OPPORTUNITIES.md). Forty-seven sprite
records that LOAD2 packed on every build and no code could reach are gone,
freeing **53,416 bytes** across four video-ROM LODs and the SHAOSIT sidecar.

## How the candidates were found

`tools/dead_loaded_art.py` finds 655 packed labels that nothing in `src/`
names (~137 KB), then drops **all** of them. Its run filter treats any
unnamed run that follows a referenced frame as live, on the theory that an
animation lane advances into the next record. That theory is right for some
code and wrong for most: MK2 animation is pointer lists, so a list that ends
in `0` or `ani_jump` cannot step anywhere. Each run below was checked by
reading how the frame before it is actually used.

`tools/art_identity_snapshot.py` also had a blind spot, fixed in this pass.
LOAD2 never deletes a table file, so `tmp/load2` still held `MKVOGEL.TBL`
and `MKRDWALK.TBL` from art retired on 2026-09-09, and their records read as
"packed". It now counts only tables a LOD still in `IMGBUILD.BAT` writes.

## What was removed

| Run | LOD | Bytes | Why nothing can draw it |
|---|---|---:|---|
| `timefloor2-9` | MK6MIL | 13,721 | The stock Portal `put_float`s `timefloor1` alone, with no animator; Outer Haven builds the staircase from TIMEFLR.LOD's per-tile strips |
| `KIDTHUNDER5-7` | MK7MIL | 9,141 | Raiden's friendship lists (`KIDD5-7`, MKFRIEND) name only the pieces `5A/5B`, `6A-D`, `7A-D` |
| ~~`TMESCAPE1A-3D`~~ | MK2MIL | 7,828 | **RESTORED 2026-09-13.** Not unnamed: HATHED12.IMG authors it as sequence `X CAYP` (TMESCAPE1, 2, 3 held 32) inside a script that tumbles out on `JFLIPSQ2` and lands - Kung Lao's cut airborne escape dive, drawn at flip-kick height and never coded. Wired back as `do_hh_escape` (airborne F,F+LP, `hat_anitab2` 3): a dive into a Mileena-style floor roll on his tuck frames, with a contact-only box (`stk_hhescape`, `react_to_hh` row 19h = `r_kano`); rig `tools/run_kunglao_escape_test.ps1` |
| `KTPLANT1/2`, `KTPLANTARM1/2` | MK6MIL | 5,946 | Kitana's plant lists name only `KTPLANT1A-3C` |
| `LKIMPALED3A-C`, `5A-B` | MK2MIL | 4,674 | `LKIMPALED3` is a list of `LKIMPALED2A`; no list names `5A/5B` |
| `SHAOSIT1A-D` | SHAOSIT sidecar | 4,542 | `KAHNSIT` draws the whole `SHAOSIT1`; only the `2*`/`3*` strips are stand-up pieces. Frees room inside the fixed sidecar slot |
| `LILXPLODE1-7` | MK7MIL | 3,310 | The fireball impact now plays `BIGXPLODE1-10`; LILXPLODE was named only in a comment. BIGXPLODE swpals `RDBOOM` itself, so the dropped `PON>` carrier costs nothing |
| `KT1STANCE7A/B` | MK3MIL | 2,884 | Kitana's stance lane stops at `KT1STANCE6` |
| `CHUNK12A-C` | MK6MIL | 1,370 | Unnamed; `CHUNK11` before them ends in `0` |

MK7MIL shrank 1,592,116 -> 1,579,664 bytes (12,452), against 12,451 decoded
for its two runs.

**Kept on purpose:** our own staged art (SAHELI2/3, LKDUBLKN, NEWSONYA,
ST1DEATHBLO13-15), records inside a hand-written header's decode window
(NJBABE, BONE3_SPIT*, RNVICBOLT1A), the copyright art, and the retired
backgrounds (COMESOON, MKTEAM, ATRAX), which overlap and need their own pass.

## Authored-sequence audit (2026-09-13, after TMESCAPE)

`TMESCAPE` was restored because "no source names it" missed that HATHED12.IMG
authors it as a sequence: an unfinished move, not dead art. So every record
removed that day, from this prune, the ROTATE families and the
[duplicate prune](DUP_ART_PRUNE.md), was checked against its source IMG's
SEQSCR pool with `tools/imgseq.py`:

| Sequence that uses removed frames | Frames | Verdict |
|---|---|---|
| `spill` (BLOOD.IMG) | `SPILL1-13` | Covered - the fatality plays MKBLOOD's live copy of the same frames; only JCSPILL's unlinked copy went |
| unnamed 1->9->2 staircase (MKBGANI.IMG) | `timefloor2-9` | Covered - Outer Haven animates this staircase from TIMEFLR.LOD's per-tile strips; the stock Portal shows `timefloor1` only |
| kid thunder (RAID8.IMG) | `KIDTHUNDER5-7` | Covered - the friendship draws the same frames from their split pieces |
| `LILBOOM1` (TCXPLODE.IMG) | `LILXPLODE1-7` | An authored 7-frame small explosion, not a move; unused since Ermac's impact became BIGXPLODE. Still in the IMG if wanted |

No authored sequence uses the HATSWIPE splits, `LKIMPALED3/5`,
`KT1STANCE7A/B`, the `KTPLANT` composites, `SHAOSIT1A-D`, `CHUNK12A-C`,
`FlameD1-4` or the removed ROTATE families (MKCHUNKS.IMG has no sequences).
No other removal hides an unfinished move.

**Rule for the next prune:** run `python tools/imgseq.py data/<IMG>` on each
candidate's source IMG before calling it dead. Only a candidate that no code
names *and* no sequence uses is really dead.

## Build and pixel evidence

| Gate | Result |
|---|---|
| Art identity vs the pre-removal build | 47 removed, exactly these; **4,727 moved with identical pixels**; 2 changed, both LOAD2 bit bleed (below) |
| Inline SAG guard | 12 hand-written headers re-anchored (ninja babality, Mileena's arm aliases, `KLUDGE_SHORTBOLT1A`); every window hash unchanged |
| Phase D, chip capacity | Pass |

**The two changed sprites are the known bit-alignment defect**
([LOAD2 bit bleed](FLIPREUSE_PROTOTYPE.md)). Both moved from bit offset 4 to
0, and both differ only in stray value-3 pixels on the bottom rows. Against
the authored IMGs:

- `KIDTHUNDER7A` (RAID8.IMG): the old ROM had 1 wrong pixel, and **the new ROM matches the art exactly**.
- `STNUTCRUNCH1B` (TSUNG9.IMG): 5 wrong pixels before, 6 after, at shifted positions.

## Runtime evidence

Old ROM (the ROTATE build) against new, private dirs, windowed
(`tmp/deadart/run_runtime_ab.py`):

| Check | Result |
|---|---|
| Ermac's fireball (`tools/ermac_fireball_test.lua`), impact burst watched piece by piece | **PASS on both**; the same 30 frames of `BIGXPLODE`, all 10 records drawn, **0 pointers into the region that miss a record start** |
| Attract mode, 40 shots | 38 identical; the last two differ across the whole frame |
| Control: the old ROM booted twice | **40 of 40 identical** |

The two attract shots are not drawing damage. Both are the attract demo fight
(Sub-Zero vs Mileena, Living Forest), rendered correctly, but it had played
out differently. Since one ROM repeats exactly, the new ROM changed a
decision, so it was traced frame by frame:

- `gstate`, `@rand`, both fighters' positions, frames, actions and wake
  addresses, and the thrown sai's object all match **through frame 4115**.
- At 4116 the old Sub-Zero leaves his block and walks; the new one stays in
  MKDRONE's `wait_proj_pass` for 6 more ticks. The same AI rolls then land on
  a different point of the RNG stream, and the fight branches.
- `wait_proj_pass` reads the projectile process's `p_joyport` as a strike
  table: word 0 is the x offset, word 1 the x size. **Mileena's `sai_proc`
  never publishes one** (`tell_world_stk`), and `spawn_proj_proc` does not
  clear the field. It held `027fa5a8`, the header address of an unrelated
  sprite (`NJICEBALLS7`), left in the recycled process block. The words
  there are packed pixels, which this reflow changed: `71c7/1c71` before,
  `1c71/3c0c` after.

So the drone has always judged the sai by garbage, and any repack of the
art behind that address can change when it drops its guard. The removal
exposed this; it did not introduce it. A heuristic scan finds the same
missing publish in `jax_zap_proc`, `spark_proc`, `floor_ice_proc`,
`slow_proj_proc`, `short_bolt_proc`, `lightning_proc`, `st_skull_proc` and
`goro_fireball_proc` (Kahn's procs skip it on purpose, per their comments).
**Fixed 2026-09-13 (user-approved; changes AI behaviour).** In `src/MKZAP.ASM`:

- `proj_strike_check` now calls `tell_world_stk` first, with the check's own
  strike index, whenever the calling process is a projectile
  (`pid_proj1`/`pid_proj2`). Every projectile collision already goes through
  it, so all of them publish their real box. `do_fn_spinfan`, which checks
  from the player's own process where `p_joyport` is the joystick port, is
  excluded by that guard.
- `spawn_proj_proc` and the directly created `jax_zap_proc` point `p_joyport`
  at `null_proj_stk`, a zero record, instead of inheriting the recycled block.
- `slow_proj_proc` publishes at launch, since the forceball has no strike
  check until it bursts.

Evidence, AI-fix ROM against the palette-removal ROM:

| Check | Result |
|---|---|
| Phase D, chip capacity | Pass |
| Every projectile process's `p_joyport` over the whole attract loop (frames 1-4400) | **Old:** a proc read address `00000000` (words `3f3f`), and earlier runs showed the `027fa5a8` sprite address. **New:** only program-ROM strike tables (`ff925150`, `ff925270`, `ff925300`, `ff9283d0`) plus `null_proj_stk` on each projectile's first frame. Mileena's sai goes null -> `ff9283d0` (x offset `4d`, x size `38`) |
| Attract demo | diverges earlier (frame 4016): the AI now reacts to real boxes, as intended |
| Ermac's fireball rig | PASS, all 10 burst frames, 0 orphans |
| Kitana fan, left throw | PASS, identical turn (rel 188), 9/9 pixel-identical pairs |

Installed as `rom/mk2.zip` and `C:\MAME\roms\mk2.zip`, whose 20 chips are all
byte-identical to the tested package. The previous package (`e7b2a955...`)
is backed up in `tmp/aifix/backup-20260913-170049/`.
[Receipt](proj_strike_box_fix_results.json).

The Kahn throne stand-up (`SHAOSIT2`/`3` strips) was not run: its rig needs
a test-mode ROM. Those strips are covered by the pixel identity above.

## Third pass: 28 more records, ~23 KB (15 September 2026, with sign-off)

`tools/dead_loaded_art.py --all` on the current build lists 602 packed labels
that nothing in `src/` names. Most of them are kept on purpose (staged art,
decode windows, the copyright art). Each remaining candidate was checked four
ways:
- the retail source in `mk2-src.zip` names it nowhere in code;
- no frame list can step into it, since MK2 lanes are pointer lists ending
  in `0` or `ani_jump`;
- no hand-written header's decode window reads it
  (`tools/sync_inline_sags.py`);
- `tools/imgseq.py` finds it in no authored IMG sequence, named or unnamed.

| Removed | Bytes (SAG gap) | Why nothing draws it |
|---|---:|---|
| `SHAOSIT2`, `SHAOSIT3` (SHAOSIT sidecar) | 13,529 | Our sidecar. `KAHNSIT` draws `SHAOSIT1` whole; the stand-up is `KAHNSTAND1/2`, the `2A-D`/`3A-C` strips. MKBGANI.IMG's `boss` sequence is `bosssit1-3`, not these |
| `acidsplash1b`, `acidsplash2b` (MK6MIL) | 3,173 | Second halves of the acid splash's first two frames. Retail `a_green_splash` names only the `a` halves |
| `SOULSUCKKT1B`, `SOULSUCKKT2B` (MK6MIL) | 1,959 | Second halves of Kitana's drained frames. Retail `FNDRAIN1/2` name only `1A`/`2A` |
| `TMDEADLEG5C` (MK2MIL) | 1,185 | Named only in a retail comment (`;	.long TMDEADLEG5A,TMDEADLEG5B,TMDEADLEG5C,0`) |
| `SPRAYGLOB2-4`, `SPLASHa1-4`, `SPLASHb1-4` (MK6MIL) | 1,151 | No code in retail or ours. `SPLASHb1-4` are BLOOD.IMG's authored `slashb` effect, which no code ever played |
| `sil1-3`, `sil5-7` (MK7MIL, MKSILO.IMG) | 804 | No code anywhere; MKSILO.IMG has no sequences |
| `RAIDENHAT`, `TONYHAT` (MK6MIL) | 667 | No code anywhere |
| `BAR_SAIBOT` (MK6MIL) | 502 | No code anywhere; Noob's bar is `BAR_NOOB` |
| `BAR_QUAN` (MK6MIL) | 0 | Never in the IMG, so LOAD2 always skipped it. Its LOD name, table record and the two guards' known-missing entries (`check_load2_log.py`, `check_sag_coverage.py`) are gone |

About **22,970 bytes** by the tool's SAG gaps: ~14.7 KB in bank 0
(SHAOSIT, MK2MIL) and ~8.3 KB in bank 1. Bank 0 free is now 141,042 bytes
(`rom_space_report.py`).

**Kept after the check:**
- `AUTOGRAPH7`: it is frame 7 of Cage's authored autograph sequence (1-8),
  which the retail code skips.
- `RN1DETHBOLT1A`: `KLUDGE_RN1DETHBOLT1A` reads it.
- `LILSTONE1/5`: `LILSTONE5_MIRROR` and `KAHNLIL1` read them.
- `KHEART1`: in MK1BLOOD.IMG's `HEART1` sequence; 66 B.
- The staged SAHELI2/3, LKDUBLKN, ST1DEATHBLO13-15 and NEWSONYA art.

**Fixed on the way: the ninja torso in frame 6.** Retail `NJDECAP6` (Midway's
`a_decapfall`) and our `NJHOLE6` (Cage's headhole fall) drew `NJDECAPTORSO5`
in frame 6. `NJDECAPTORSO6` is its own authored pose (53×45, against 5's 28×68
and 7's 65×26), and Kitana's lists use torso n in frame n. Offline composites
of frames 5-7 show the torso snapping back upright in frame 6, and with the
fix it tips over smoothly (`tmp/deadart2/nj_fall_567.png`).

**Build.** The full LOAD2 build stopped in Phase D, correctly: the move left
`smfirebone6_mirror` (MKFX.ASM) on a stale SAG. `tools/sync_inline_sags.py`
rewrote it, `MKFX.OBJ` was deleted, and `build.py --asm-only` passes every
guard. Private package `tmp/deadart2`, not installed.

**Art identity** against the pre-prune build: the 28 records removed, 3,155
moved with identical pixels, 1 CHANGED. That is `pitblood1b`, which nothing
references. It has the same 3-pixel LOAD2 defect [BLEED_SCAN](BLEED_SCAN.md)
recorded (column 2, rows 33-35), and the move only changed the stray values.

**MAME, Kung Lao's neck decap on Sub-Zero** (`tmp/deadart2/run_decap_ab.py`,
the TIMEFLR build against this one, a capture every 2 frames). Both reach
FINISH HIM and the decap on the same frames, and both PASS. 129 of 132 captures
are identical. Captures 68-70 differ in one 58×84 box, the body, for the three
captures frame 6 is held. The old build shows the torso upright on legs already
lying flat; the new one shows it tipping over
(`tmp/deadart2/decap_0069_crop.png`).

**MAME, attract mode from power-on** (`tmp/comp_policy/attract_ab.py`, the same
two builds): **443 of 443 captures identical.**

**Battle stability sweep on the combined package** (`tmp/deadart2`, which also
carries the Kahn portal hang fix, the MOVEART repack and the TIMEFLR fix): **27
of 27 battles PASS.** The run covers every stage, Jade/Kahn/Kintaro/Smoke/Noob
as the CPU, and the battles added for earlier crash reports. It was run with
`tmp/deadart2/run_sweep.py`, the same battles and verdicts as
`tools/run_battle_stability_sweep.ps1`, but in private MAME directories. The
stock runner kills every MAME process and deletes the shared
`C:\MAME\nvram\mk2`.
