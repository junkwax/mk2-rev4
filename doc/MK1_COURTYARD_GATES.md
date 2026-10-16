# THE COURTYARD and PALACE GATES (MK1) - research notes

Wolf-only stages (doc/WOLF_CONTENT_PLAN.md step C). Status: **both are built**
(2026-10-07): THE COURTYARD is curback `1Dh`, PALACE GATES `1Eh` - see the two
"as built" sections at the end. Both are in the normal stage rotation.

Sources: MK1 rev 5.0 `C:\MAME\roms\mk.zip`, read through `tools/make_mk1pit.py`'s
`MK1` reader; stage table entries per doc/MK1_THRONE_ROOM.md; MK1 code
disassembled with MAME's debugger (`dasm` over `FFCB9E00`, 0x6000 bits, and the
round-end hook table at `FFCACF50`).

## The records

| | THE COURTYARD | PALACE GATES |
|---|---|---|
| stage table entry | 0 | 1 |
| record | `FFCBB410` | `FFCB9ED0` |
| erase colour | 21407 | 21407 |
| ground | 280 | 268 |
| camera y | 40 | 28 |
| start x | 366 | 331 |
| scroll limits | 73 .. 634 | 40 .. 800 |
| calla | `FFCBB6F0` | `FFCBA130` |
| scroll table | `FFCBDE40` | `FFCBDF60` |
| first plane (`bakmods`) | `01095550h` | `01095530h` |
| modules | 8, one header table `FFE45C10`, palettes `FFE86500` | 6, headers `FFE48BD0`, palettes `FFE8BC50` |

## Is the BDB in the tree the shipped stage?

Matched module by module, block lists compared as THE WARRIOR SHRINE's tool does
(flags, x, y, header):

- **PALACE GATES = `data/KUNGFU4`, all 6 modules identical** (wokway0b..5b).
  The shrine notes called KUNGFU4 "a daytime Palace Gates variant"; the LAYOUT
  is MK1's - pixels and palettes still have to be checked against the ROM.
- **THE COURTYARD is NOT `data/KUNGFU2`.** Only ARENA3 and ARENA4 match; ARENA1,
  ARENA2 and ARENA5 differ in size (1068x100 vs MK1's 1033x96, 857x195 vs
  699x116, 632x105 vs 632x104) and the BDB has one block outside every module
  (image 00 at 839,1012). KUNGFU2 is a pre-release Courtyard: the stage must be
  decoded out of `mk.zip`, as THE THRONE ROOM was (`tools/make_mk1throne.py`).

## The animated pieces (the calla's processes)

Both callas only start processes (`MOVI 2000h,A1` / `MOVI <proc>,A7` /
`CALLA FFCE2810h` - create, pid 2000h).

**THE COURTYARD - one process, `FFCBB780`: THE MONKS.** Every 8 ticks
(`MOVI 8,A0`, `JA FFCE2260h` = sleep and loop) it walks the object lists of MK1
planes 2 and 3 (`104F950h`, `104F930h` - plane-table entries 2 and 3) and steps
each object's counter at `*A8(240h)` 1..6, pointing the object at the next of
six image records (`FFE976C0h`..`FFE978A0h`, step 60h, table `FFCBBB30h`)
through `CALLA FFC805E0h`. Rendered (`rom.image`, `tmp/mk1_court/anim_frames.png`)
the records are **a row of six monks**, 105x43, 62 colours: frames 1-6 are their
idle loop. The second table (`FFCBBBF0h`: `FFE97900h`/`960h`/`9C0h`, repeated)
is **the monks with their hands together - a bow** - loaded into A10 and not
used by the loop; the round-end hook (below) is the likely user.

**Measured in MK1** (`tools/mk1_court_objs.lua`: a real 1P game held on the
courtyard, both lists dumped every 60 frames). In MK1 a background BLOCK IS AN
OBJECT on its plane's list - the lists hold the blocks on screen (6-7 of a
module's 7-8, added and removed as the camera scrolls). The two lists are the
TWO ROWS OF MONKS:

| list | objects | world y | world x (step 87) | MK1 module |
|---|---|---|---|---|
| `104F950h` | 6-7 | 189 (`0BDh`) | 294 .. 729 | module 3, 717x43 at (207,189), 8 blocks |
| `104F930h` | 7 | 176 (`0B0h`) | 251 .. 773 | module 4, 630x43 at (251,176), 7 blocks |

Object fields: image record at `+180h` (the frame being shown), x at `+80h`
and y at `+A0h` (16.16), the frame counter at `+240h`. Every block is one image
- six monks, 108x43 (MK1 header index 0) - and every object carries the same
counter, so the whole crowd moves in step through the six 105x43 frames.

**The MK2 port.** An MK2 BDB block never animates (BGND.ASM `tower_flames`: an
animated piece is a runtime object on a plane list with no module on it). So
MK1's modules 3 and 4 become RUNTIME OBJECTS in MK2 - 8 + 7 monk rows at the
blocks' positions, on those two planes' lists, drawn at MK1's rates for them,
stepped through the six frames every 8 ticks; the bow frames at round end.

**PALACE GATES - two processes** (`FFCBA130` creates both; everything here
was read with MAME's disassembler and measured in a real MK1 game,
`tools/mk1_court_objs.lua` with `MK1C_STAGE=1`).
- `FFCBA240`, THE CLOUDS: three clouds from two piece lists (`FFCBA9E0`, 3
  pieces; `FFCBAA60`, 4 pieces) at screen x `15h` / `C5h` / `185h`, y `25h`,
  each piece its own object on list `104F8F0h` (a plane with no module), x
  velocity `8000h` (half a pixel a tick). Every 8 ticks any piece past screen
  x `18Fh` (399) moves back `23Fh` (575) - piece by piece, so a cloud
  reassembles behind the left edge. Palette `FFEA8D10` (the group's own).
- `FFCBABC0`, THE TORCH FLAMES: every 4 ticks it walks two planes' lists and
  steps any object whose ID (`*A8(C0h)`) is 2, 3 or 4 through an 8-frame
  table (`FFCBB110` / `B210` / `B310`), counter at `*A8(240h)`. **The ID is
  the high byte of the BLOCK's flag word** - these are background blocks the
  streamer turns into objects, which is why the lists looked empty in most
  dumps: the torches are at the two ends of the stage and only exist while
  the camera is near them. A watchpoint on a live one's ID field
  (`FFCE40F0`, the generic block-object builder, called from the
  background process whose `*A13(60h)` is the stage record) settled it. On
  this stage: two ID-2 flames and one ID-3 on plane 2 (the pillar torches),
  one big ID-4 on plane 1 (by the gatehouse), plus ID-1 torch cups that do
  not animate.
- **MK1's frame swap keeps the anchor still** (`FFC806E0` / `FFC80D10`):
  anchor = position + anix, or + (w-1-anix) when H-flipped, and the first
  swap starts from a stand-in record `FFC864D0` whose anipoint is 0 - so the
  anchor is the block's top-left (top-right if flipped). Measured: the ID-2
  flame at block (218,56) drew at y 54 on a frame with aniy 2 and at y 60 on
  aniy -4.
- **The module list starts on MK1's plane 0**, not 1 (THE PIT's does too), so
  MK2's baklst N carries MK1 plane N-1 and every rate is one table entry along.

**Round-end hook, `FFCAD160`.** THE COURTYARD's own entry in MK1's round-end
hook table (THE THRONE ROOM's clap falls through into it): plays MK1 sound
`3Fh` (`CALLA FFCDF160h`), then finds process `2000h` (the stage's animation
process) and restarts it (`*A0(60h)` <- `*A0(80h)`). The sound is a crowd
reaction to the round; it has to come in with the MK1 audio (step B).

## THE COURTYARD as built

| piece | where |
|---|---|
| importer | `tools/make_mk1court.py` (`--parts`, `--apply` = Phase B2d6, `--check` in Phase D, `--report`, `--preview`) |
| stage module | `src/MK1CRT.ASM`, whole body under `.if wunit`; generated data `src/MK1CRTB.ASM` |
| art | `data/MK1CY1` (37 block images, 46,608 B at linear `0xC00000`, LOD `***> 4000000,1`) and the monk sprite pack `data/MK1CYM` (`data/MK1CRTMK.IMG`, six frames, 16,380 B at `0xC14000`) - both in makevrom's `wolf_irw_files`, never the T-unit chips |
| tables | `table_o_mods` 1Dh (BGND.ASM), the four tune tables (MAIN.ASM - the Tower set until MK1's music is in), `match_stage_cycle` / `vs_stage_cycle` / `vs_stage_prev`, `background_names` "THE COURTYARD" (MKSEL.ASM) - all under `.if wunit` |

**The monks.** MK1's modules 3 and 4 are `skip_bakmod` in the MK2 list; their
15 blocks are built by `mk1c_monks` as objects on `baklst3` / `baklst4` at each
block's world top-left (frames packed at anipoint 0, because MK1's frame swap
never moves an object) and stepped through MK1CYMONK1-6 every 8 ticks with
`ani_flag`. **MK1 gives the two rows different palettes** (MK1 11 for the near
row, 0 for the far one): the records carry `MK1CYMK3_P` and the far row claims
`MK1CYMK4_P` after it is built - claim first, then `delpal` the one
`gso_dmawnz` took. The three hands-together frames are in the IMG and not
packed: MK1 loads them and never shows them. The round-end hook (`FFCAD160`:
MK1 sound `3Fh`, then restart the monk process) is NOT ported - it needs MK1's
audio (step B).

**The right scroll limit is 620, not MK1's 634** (2026-10-10). Where the
right-hand spear guard's robe meets the floor lip, nothing on any plane covers
plane-1 world x 1034+, so the erase colour (sky blue) shows through: first at
camera 630, 24 pixels at screen x 390-399, rows 205-222, by 634. MK1 has the
same gap and barely shows it, because its display sits 1-2 px left of MK2's
for the same worldtlx (a parked MK1 frame at the start camera, no poke,
matches our render at dx -1). **The camera also does not stop AT the limit**:
`scr_right` (BGND.ASM) refuses to scroll only once `worldtlx >= right_edge`
and still applies that tick's step, so a walking camera stops at limit+2 and
the fastest row (`0a0000h`) can reach limit+9. `right_limit()` in the tool
takes the highest limit whose cameras limit..limit+9 (`SCROLL_OVERSHOOT`) all
render with no erase pixel from plane 1's top down; `--check` regenerates it.
Rig `tools/wolf_court_edge.lua` (via `run_wolf_boot_probe.ps1`) walks to the
edge, logs `worldtlx` and snapshots: at 629 it stopped at 631 with 3 sky
pixels, matching the render for 631.

**The throne is empty when Shang Tsung is fighting** (2026-10-10). In MK1 he
is painted into the chair: one 48x55 block of module 6 (header `25h`, palette
7, at 201,71 - the module's rearmost block, touching no other). The tool takes
that block out of the module and packs it as a sprite record in `MK1CYM`
(`MK1CYTHRN`), plus `MK1CYTHRNE`, the chair with nobody in it. `mk1c_throne`
(called from `mk1c_monks`) builds one object at the block's world top-left
(543,92) on `mk1c_th_lst`, drawn with plane 6's camera straight after
`baklst6`: the empty record when `p1_char` or `p2_char` is `ft_st` - human or
CPU, THE THRONE ROOM's rule - else the seated one. Not on `baklst6` itself:
the block streamer deletes objects on a module's list. **MK1 has no empty
Courtyard throne** (Shang is fought in the Throne Room), so `empty_throne()`
paints it: posts and arms are MK1's pixels, mirrored from the half he does not
cover and tiled where he covers both; the back, seat and front are filled in
the chair's own reds. That part is this project's art - change it in the tool.
Rig `tools/run_wolf_court_throne.ps1`: three real 1P games (Kang/Cage seated;
Shang/Cage and Kang/CPU Shang empty), the object's SAG and position read for
300 fight frames - 3/3 PASS, `-Negative` (crossed expectation) FAILS.

**BGND.ASM is at GSPA's ceiling on the Wolf pass.** `table_o_mods` 1Dh as two
separate `.if wunit` blocks (the `.globl` up top, the `.long` in the table)
aborted BGND with `>> Out of memory`; ONE block holding both, inside the table,
assembles - and was measured with room for two more stage entries (Palace
Gates, Scorpion's Lair) in the same block. Measure in a scratch copy of
`tmp/wolf/src` (`gspa BGND -H -v10` in DOSBox), not in the shared tree.

**Verified.** T-unit: `src/mk2.out` and both program chips byte-identical
except the build stamp, all 12 video chips identical. Wolf: `python makewolf.py`,
then `tools/run_wolf_boot_probe.ps1 -Script wolf_court_check.lua` - a real 1P
game with curback held at 1Dh through select/VS: all 15 monks at MK1's block
positions, 74 frame steps of exactly 8 ticks over 600 fight frames, every
object on the same frame, frames 1-6 in order - **PASS**; snapshots in
`tmp/wolf_court/snap/`.

## PALACE GATES as built

| piece | where |
|---|---|
| importer | `tools/make_mk1gates.py` (`--parts`, `--apply` = Phase B2d7, `--check` in Phase D, `--report`, `--preview`, `--expect` for the rig) |
| stage module | `src/MK1GATE.ASM`, whole body under `.if wunit`; generated data `src/MK1GTB.ASM` |
| art | `data/MK1GT1` (61 block images, 99,656 B at linear `0xC1C000`) and the sprite pack `data/MK1GTM` (`data/MK1GATMK.IMG`: 24 flame frames, 2 torch cups, 7 cloud pieces, 27,950 B at `0xC40000`) |
| tables | curback 1Eh beside 1Dh in every table THE COURTYARD is in |

**The torches are objects on lists of their own.** MK2's block streamer
(`disp_del`, BAKGND.ASM) deletes any object on a module's baklst once it
leaves the window - and dereferences its `oplink` doing it - so the flame
blocks and the cups come OUT of modules 1 and 2 and live on `mk1g_pl1_lst` /
`mk1g_pl2_lst`, drawn just behind their plane's blocks with the plane's own
camera (MK1 sorts by that ID, and every module block is 3Eh or above).
Higher z draws IN FRONT - the plane-3 spear guard (4153h) stands in front of
the wall (4040h) in MK1 and in MK2; an earlier preview sorted the other way
and hid him. The generator works out every flame frame's world top-left from
MK1's anchor rule, so the stage code only swaps art and puts it there. Each
torch starts 3 frames on from the last so they do not flicker in step.

**The clouds** ride plane 8 (rate 0) on `mk1g_cld_lst`, placed at MK1's
screen x plus plane 8's camera, `oxvel` `8000h`, and wrapped every 8 ticks
against that camera.

**Verified.** T-unit byte-identical. Wolf: `tools/run_wolf_boot_probe.ps1
-Script wolf_gates_check.lua` (expectations from `make_mk1gates.py --expect`)
- a real 1P game on curback 1Eh: 2,406 samples, every piece always on one of
its own frames at exactly the computed position (0 misplaced), each flame
through all 8 frames in order, 99 steps of exactly 4 ticks; clouds 50 px in
100 ticks, 4 wraps, never past screen x 404 - **PASS**. Snapshots at the left
end show the torches lit (`tmp/wolf_gates/snap/`).

**Not ported:** music (both stages play the Tower set until MK1's music is
in) and THE COURTYARD's round-end crowd sound.
