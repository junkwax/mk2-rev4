# Custom Content Placement

This repo currently uses three placement strategies after the stock `MK2MIL`-`MK7MIL` LOAD2 passes. Character sprite chunks, BLIMP/BBB backgrounds, and stock-LOD appends have different table paths and different failure modes.

Global naming rules live in `doc/NAMING_CONVENTIONS.md`.

## Strategy A - REVX Program-ROM Payloads

Use this for CPU-read/movie payloads, such as VS portraits and ending/attract movie frames. Normal player PIXBLT sprite art belongs in image ROM.

Current occupant:

| LOD | IRW | Address | Approx size | Use |
| --- | --- | --- | ---: | --- |
| `data/MK8MIL.LOD` | `data/MK8MIL.IRW` | `0xFFED0000` | 155,512 bytes | REVX movie pool, 12 VS portraits (endings retired 2026-08-11, base rebased 2026-08-24) |

`makerom.py` reports 2,468 bytes free after the generated MK8 payload. Normal
player PIXBLT sprite art still belongs in image ROM.

**Base moved `0xFFD2B000` -> `0xFFD39000` on 2026-08-01.** The program ROM was
full: `.data` had grown to `0xFFD29ED0`, past the base makerom was then using,
so any new code overflowed into the movie pool. Roughly 10.2 KB was sitting
unused *between* the end of the payload and the REVX window end; shifting the
whole pool up hands that slack to `.text`/`.data`. Noob's three shadow moves are
what needed it.

Three places must agree on this address and nothing checks that they do:
`makerom.py`'s `REVX_PAYLOADS`, `data/MK8MIL.LOD`'s `***>` line, and
`src/MK8ZIP.TBL`'s `zipped_pics` equates. makerom embeds the payload at its own
address regardless of the base recorded in the IRW header, and the game reads it
through `MK8ZIP.TBL` - so a disagreement silently misaddresses every VS portrait
and ending. They were `0x1B00` bits apart before this change. `src/MK8ZIP.TBL`
is now taken straight from `tmp/load2/MK8ZIP.TBL` after a LOAD2 pass.

## Strategy B - Fixed Video-ROM Wrappers

Use this for new image-ROM sprites or BBB/background payloads that should not shift stock MIL addresses. The active custom video wrappers are placed in explicit fixed slots checked by `makevrom.py`.

| Wrapper | Purpose | Flat slot | Current payload end |
| --- | --- | --- | --- |
Verified against a fresh `python makevrom.py` run (2026-07-31).

| Wrapper | Purpose | Flat slot | Current payload end |
| --- | --- | --- | --- |
| `SZSPINE.IRW` | Sub-Zero head-rip spine + head props (free MK5-to-MOVEART2 gap) | `0x762000..0x7637FF` | `0x762580` |
| `MOVEART2.IRW` | second custom move/fatality pool | `0x763800..0x767FFF` | `0x767290` |
| `MOVEART1.IRW` | global move/fatality pool | `0x768000..0x77FFFF` | `0x77D7C8` |
| `SHAOSIT.IRW` | Shao Kahn throne stand-up frames (retired KGBLOOD slot) | `0x780000..0x788FFF` | `0x7885AE` |
| `STGORO.IRW` | Shang Tsung "Goro lives" morph poses | `0x790000..0x79FFFF` | `0x796FD6` |
| `KITSPIN.IRW` | Kitana overhead spin chop | `0x7A0000..0x7A4DFF` | `0x7A4D3C` |
| `MK1SKULL.IRW` | MK1 scortch fatality flame + skeleton | `0x7A4E00..0x7AFFFF` | `0x7AFE8A` |
| `GOROWALK.IRW` | Kahn Arena Goro walk pool | `0x7B0000..0x7BBFFF` | `0x7B8E4E` |
| `FLAPJACK.IRW` | FLAPJACK stage background | `0x7BC000..0x7EFFFF` | `0x7EE2C0` |
| `NOOBFX.IRW` | Noob shadow slide/kick/teleport frames (retired VSNOOB slot) | `0x797000..0x79B3FF` | `0x79A0E2` |
| `JADVIC.IRW` | Jade victory body + staff frames | `0x7F0000..0x7FFFFF` | `0x7FD112` |
| `MKSOUL1.IRW` | soul-suck corpse drop, `CORPSEDROP1-8` (bank 1) | `0x9F7000..0x9FFFFF` | `0x9FB3E2` |
| `SCLAP.IRW` | Shao Kahn Sonic Clap (bank 1) | `0xBF1000..0xBF3FFF` | `0xBF2D80` |
| `JADERANG.IRW` | Jade boomerang sidecar (bank 1) | `0xBF4000..0xBFFFFF` | `0xBF826A` |

`MKSOUL1` (2026-08-03) is the first sidecar placed in the **MK6-to-MK7 gap**
rather than after a bank's last payload. Bank 1 was deliberate: every other
piece of the soul-suck fatality's art — the per-character `*SOULSUCK*` wither
poses and the `CORPSE1A` husk — is `MKSOUL.IMG` content already inside MK6MIL,
so the drop sits with its own family. `MKSOUL1.IMG`'s palette table is
truncated the same way `MK1SKULL.IMG`'s is (header claims 4 records, one is
physically present), so the LOD is `POF>`; no runtime dressing is needed
because `do_drain` has already swapped the victim onto `CORPSE_P`.

`JADVIC` replaced the `JADVIC1` + `JADVIC2` pair (2026-07-31). Both halves of
that split had asked LOAD2 for `JDVICTORY*A`/`*B` multipart strips that
`JADERANG.IMG` never contained, so both built to a 68-byte header with **zero
payload** while `MKFN.ASM` kept referencing the labels — Jade's victory drew
unwritten ROM. The 15 composites pack to 51,456 bytes and fit the single
`0x7F0000` slot, releasing `0x789000..0x790000` entirely. LOAD2 reports an
unresolved record as a skip, not an error, which is why this passed the build
for months; `tools/check_load2_log.py` now fails on both unresolved names and
empty payloads.

**Reworked victory art, 2026-08-01.** `JADVIC` now loads from `JADEVIC.IMG`
instead of `JADERANG.IMG` and carries **two lanes of 14 frames**:
`JDVICTORY1-14` (Jade's body, 6bpp, her normal `JADE_P` costume palette) and
`JDVICSTAFF1-14` (the glowing staff, 4bpp, its own 16-colour `JDSTGLO_P`).

**`JADE_P` was updated globally on 2026-08-01** to JADEVIC.IMG's own copy
(`src/IMGPAL6.ASM`). It differs from the old KAT11.IMG-derived version in
**entry 32 only**: `03BF1H` (bright green) -> `07FFFH` (white), which turns the
scattered specular pixels on her mask and costume into highlights rather than
blending them in. Entry 32 is 0.07-0.35% of pixels in the frames that use it.
Note this palette is Jade's costume in all seven `character_palettes` tables
**and Kitana's Start+LK alternate** (`character_palettes_6` index 4), so the
change reaches that costume too.
Measured payload **53,522** bytes of the 65,536-byte slot, 12,014 free.

The staff lane is loaded as **A/B multipart strips** (`JDVICSTAFF1A/1B`...),
added to `JADEVIC.IMG` on 2026-08-01 along with corrected anipoints on every
composite. The staff is a long thin diagonal whose composite bounding box is
mostly empty, so the split cut the raw pixel count 45% (83,930 -> 45,706).
Contrast `MK1SKULL.LOD`, where splitting cost more in record overhead than it
saved in trim - measure before assuming either way. The body frames stay
composites; the library has no A/B form for them.

The two lanes are **separate objects, not multipart pieces of one**, because
they need different palettes: MKDISP's display walk reloads sag/size/control/
anipoint per multipart piece but reads the palette translate once per object
(`a8 = const:palette xlate`, loaded before the `clip41` loop). `jade_victory`
in `MKCANNED.ASM` spawns the staff with `gmo_proc`, anchors it with
`match_ani_points`, gives it `JDSTGLO_P`, puts it at Jade's `ozval + 1` so it
draws **in front of** her, and runs both lanes through `double_mframew` off one
tick source. (`insobj` sorts ascending `ozval` and the display walk queues from
the head, so higher z draws later = nearer the viewer — `front_z` 0x50 vs
`back_z` 0x4f for P1/P2 is the same convention.) Both tables must stay the
same length — `double_mframew` stops on the *second* animation's terminator.
Neither lane migrates the object: `do_next_a9_frame` uses `ani2`, which only
rewrites multipart RAM, so the two objects cannot drift apart once
`match_ani_points` has equalised their `oxval`/`oyval`.

The staff object is deliberately never deleted — it belongs to the held final
pose — and the normal round teardown reclaims it;
`tools/jade_victory_test.lua` asserts that it is gone once round 2 starts.
The old `player_swpal JADEV_P` was removed with the old art: `JADEV_P` was
authored for the retired `JADERANG.IMG` frames and would wreck these.

SHAOSIT replaced the retired KGBLOOD wrapper (2026-07-14): the Kung Lao
SMGUSH blood pool had no remaining src references. `data/KGBLOOD.LOD` stays
on disk for reference; its IRW and TBL were deleted. SHAOSIT packs the
`MKBGANI.IMG` SHAOSIT1/2/3 frames plus the 1A-1D/2A-2D/3A-3C multipart
strips with the same `ZON>`/`PPP> 6` recipe as GOROWALK — moving them out
of MK6MIL's `PPP> 0` mkbgani section is what fixed their garbled rendering
(the art is 6bpp).

The old `bosssit1/2/3` frames were also reclaimed from `MK6MIL.LOD`'s
`PON>` line and from `MKBGANI.TBL` (2026-07-14) once SHAOSIT fully
superseded them — they had zero remaining references. This freed MK6MIL
down to a `0x9F6B3E` payload end, i.e. **38,082 bytes free** before the
`0xA00000` MK7MIL bank-1 boundary.

Raiden shortzap now lives in `MK3MIL`; MK1PIT is baked into `MK7MIL` as
`MK1PIT`, not a standalone `KFPITPL` wrapper. FLAPJACK currently uses
111,016 bytes of the `0x7BC000..0x7FFFFF` sidecar window and leaves 167,512
bytes before the bank-1 boundary.

The retired MK7 `COMESOON` window at `0xBC8683..0xBEA0AD` is unassigned and
provides 137,771 bytes for a future guarded overlay. Armory now remains in its
normal MK7 range; `tools/fix_armory_mk7_bg.py --apply` clears the one bad
compression bit in `ry1HDRS[0]` directly in `MK7MIL.IRW`. See
`doc/ARMORY_HDR0_BITFIX.md`.

## Strategy C - In-LOD Append To Stock MIL Files

Avoid this unless there is no fixed-slot alternative. Appending entries inside an existing `MK[2-7]MIL.LOD` changes LOAD2 layout and shifts every later SAG. If used, run LOAD2 for the modified LOD, promote affected tables, rebuild program/video ROMs together, and validate in MAME.

## References

- `data/IMGBUILD.BAT` - active 12-LOD LOAD2 order
- `data/MK8MIL.LOD` - REVX program-ROM movie payload
- `makerom.py` - REVX payload embedding and capacity checks
- `makevrom.py` - fixed video slot checks and video-ROM packing
- `doc/CURRENT_SAG_MAP.md` - generated current placement report

## Noob Saibot's shadow moves (2026-08-01)

`data/NOOBFX.LOD` packs six `NOOB.IMG` frames into the slot the retired VSNOOB
sprite left free (`0x797000`, 17,408 bytes): `NOOBSLIDE1-2`, `NOOBAIRKICK1-2`
and `NOOBTELE1-2`. Measured payload **12,514 bytes**, 4,894 free.

It is the only sidecar here packed at `PPP> 4` rather than 6. Every one of those
frames uses pixel values 0..14 only, so 4 bits is lossless - and it is also
necessary, because at 6bpp the payload is 18,440 bytes and overflows the slot by
1,032. 4bpp is ordinary for this ROM (294 stock records ship with the DMA
control word's bits 12-14 set to 4). `UMKNOOB_P` has 15 entries so `getfpal`
returns a 16-aligned block and the 4-bit pixels never disturb the palette base.

| Input | Move | Entry point |
| --- | --- | --- |
| D,B + LK | shadow slide | `do_noob_slide` (`MKZAP.ASM`) |
| D,B + LK **in the air** | **shadow dive kick** | `do_noob_dive` (`MKZAP.ASM`) |
| D,B + HK | shadow kick | `do_noob_kick` (`MKZAP.ASM`) |
| D,D + LK | **shadow portal** | `do_noob_portal` (`MKZAP.ASM`) |
| D,U | shadow teleport | `do_noob_teleport` (`MKPROP.ASM`) |
| Away + LP+BL+LK | **real slide** (Sub-Zero's) | `do_slide` (`MKPROP.ASM`) |

The slide (added 2026-08-18) is the stock Sub-Zero move on the stock Sub-Zero
input, not a new one: Noob is a ninja everywhere it matters, so `nj_strikes`
already gave him `stk_slide` at offset `012h` and `a_slide`'s `NJSLIDE1-3` art
is the sprite set he is already drawn from. Three things were needed and no
new art:

- `slide_check` has to be reachable from **all three** buttons in the motion
  (whichever is pressed last is the one that runs the detector), so
  `char_lo_punch` and `char_block` slot 15 stopped being `sucide` -
  `noob_lo_punch` / `noob_block` are bare `slide_check` calls - and
  `noob_lo_kick` now checks the slide before the shadow slide, the same order
  `sz_lo_kick` uses. `D,B+LK` cannot false-trigger it: the slide wants BLOCK
  and LP held too.
- `do_slide` read its animation from TABLE2 **row 0**, which for Noob is
  Scorpion's spear throw (`noob_anitab2` rows 0-6 are inherited from
  `sc_anitab2`). `slide_ani2` in `MKPROP.ASM` picks row `0ah` for `ft_noob`
  and row 0 for everyone else; `0ah` is the `a_slide` row that has been
  sitting dead in `noob_anitab2` since the shadow slide replaced his own.
- Nothing on the reaction side: `act_slide` / `act_slide_sd` are already in
  the drone's counter tables (`c_slide`, `c_slide_sd`), so the CPU blocks and
  punishes it exactly as it does Sub-Zero's.

The drone does **not** use it yet - `drone_slide` appears at ochar 8/9 in
`ochar_punish`, `ochar_duck_special`, `ochar_avoid_pro` and `skull_escape`,
and slot `0f` is still `0`/`drone_flip_kick`.

### Shadow dive kick (added 2026-08-18)

`D,B+LK` is one motion with two moves on it, split by where his feet are. On
the ground it is the shadow slide it has always been; from a jump it is a third
shadow — `do_noob_dive`, `projectile_jumps 27h`, variant 2 of the same
`get_noob_shadow_obj` / `noob_shadow_proc` pair the slide and kick use. Noob
does not dive: he **casts the flip kick, hangs where he cast it while the
shadow does the diving, and then simply falls**. Zero new art and zero video
ROM — the shadow rides `a_noob_airkick` (`NOOBAIRKICK1/2`, the D,B+HK kick's
own frames) and his body just holds the jump: `a_njjumpup` (`sm_anitab1 06h`).

Four things make it the air variant rather than a reskin of the kick:

- **The dispatch is most of the job.** `restricted_xfer` refuses an airborne
  caller outright, which is why a ground special has no air version by default,
  so the air half exits through `airborn_xfer` instead. `noob_lo_kick` asks
  `am_i_airborn` first — switching `a13` to the player through `p_store4`,
  because the handler runs in the *combo detector* process — then applies the
  `distance_from_ground >= 0a0h` gate. `0a0h` is this codebase's "meaningfully
  airborne" number; `MKDRONE`'s anti-air uses it too. Airborne but under the
  gate falls through to the normal air kick rather than eating the input.
- **`zap_air_init_special`, not `zap_init_special_act`.** The grounded init
  plants the caster on the floor, which would drop him out of the air the
  instant the move started, so the dive branches out of `do_noob_shadow_a0`
  ahead of that line and sets `p_action` by hand afterwards.
- **`stop_me` is the pause.** It zeroes his velocities *and* his gravity, so he
  stops dead at the cast instead of riding the rest of the jump arc. That hang
  is what sells the shadow as something that left him behind.
- **Noob himself does nothing.** He holds `NJJUMP3` — the airborne pose out of
  `a_njjumpup`, as against `NJJUMP2`'s launch and `NJJUMP1`'s landing — for the
  whole move; the kick belongs entirely to the shadow. He is posed on it
  explicitly rather than left on whatever frame the jump had reached, for the
  reason `noob_kick_windup` gives: the init has already transferred his joystick
  process out, so any frame he happens to be on freezes there.
- **Two palettes, one letter apart, not interchangeable.** Noob wears
  **`NOOBDE_P`** (NINJAS11.IMG record 31) via `player_swpal`; the shadow wears
  **`NOOBDEF_P`** (record 25) via `getfpal`. `NOOBDE_P` is far blacker — 39 of
  63 entries pure black against a handful, topping out at `00C63H` where
  `NOOBDEF_P` reaches `01CE7H` — so Noob hangs as a true silhouette and the
  shadow he threw keeps a little more form. Both are live on screen at once and
  the harness confirms it by sampling for the colours unique to each.
  `player_normpal` restores his before the drop; if he is hit mid-cast
  `reaction_start_chores` does it. No `m_shadow` suppression, unlike the
  teleport: that is only needed for 4bpp art, which `shadow_p1p2` shears.

  Extracting a palette from an IMG: the table starts at `0xAE570` in
  NINJAS11.IMG with 26-byte records — 8-byte name, colour count at `+4`, and an
  **absolute file offset** to the raw words at `+6`. Records pack from `0x1C` at
  128 bytes each, so record N is at `0x1C + N*0x80`.
- **`air_throw_drop`, not `do_proj_sitting_duck`.** It restores gravity, drops
  him from wherever he paused and runs `do_land_animation`. There is no
  sitting-duck window because the fall is one.

The shadow flies **Kung Lao's trajectory, steepened**. `do_reptile_superk` is
the move this is the projectile version of, right down to sharing its `a9` of
`01eh`, and its forward speed (`080000h`) and gravity (`04000h`) are taken
verbatim. The opening descent is **doubled** — `060000h` against his `030000h`.

That is a range dial, and which dial matters. Halving the forward speed shortens
the reach too, and was tried first, but it makes the shadow visibly crawl: what
reads as "a dive kick" is how fast it crosses the screen. Doubling the descent
lands it short while leaving it **faster** than Kung Lao's overall — 10px/tick
against his 8.5, since the components add in quadrature. To retune, move
`NOOB_DIVE_YVEL` (up for shorter, down for longer) and leave `NOOB_DIVE_XVEL`
alone, because XVEL is what the speed looks like. Measured: connects at **90px**
spacing, `step_dx` 8, descent opening at 6px/tick and accelerating.

**The gravity is integrated by hand** (`nsp_dive_floor`), for two independent
reasons. The object mover never does it: `dclipl` in MKDISP only *adds* velocity
to position, and accelerating is `flight`'s job — which runs in the owning
process, and a projectile on its own proc has no equivalent. And this object
could not hold a gravity value anyway: **`ograv .set oslink`** (DISPEQU.ASM) —
they are the same field — and `get_proj_obj_m` has pointed this object's
`oslink` at its multipart gmo dummy *process*. Writing gravity there would
overwrite that link, the same trap the `ground_multi` note in
`get_noob_shadow_obj` describes.

What ends the shadow is the **floor**, not an apex countdown —
`nsp_dive_floor` compares its `oypos` against `@ground_y` and drops it into the
existing `nsp_poof` smoke cloud, the same death the slide gets at its stop line.
It needs its own floor test because it is the other `a10 == 0` variant and the
slide's screen-edge stop keys on exactly that.

**The hit is a flip kick's**, which is the point of the move. `stk_noob_dive`
(appended at `nj_strikes 01fh`; appending never shifts the other ninjas'
indices) carries `stk_njflipk`'s routine word `0b12h`, so the victim takes
`r_flipk` — `flight` at `-080000h`, i.e. 8px/tick straight up — rather than
`stk_noob_kick`'s `r_hhjumpupk`, which only pushes a grounded victim 1px/tick
and plays a chest hit. Damage cannot tell the two records apart (both deal 26),
so `tools/noob_divekick_test.lua` measures the victim's **rise** instead:
60px in the field report, against the ~0 a jump-kick reaction would give.

The harness checks the **trajectory** by forward step and acceleration —
`step_dx` 8 and a per-tick descent that grows — never by absolute descent or by
angle. Absolute descent is actively misleading: on a dive the shadow that
*connects* has barely dropped, because it arrives sooner, so a `descends >= 40`
threshold scored good hits as misses and the sweep walked past them. The tell
was the victim losing exactly 26 HP on a try the report called a miss — **check
the victim's HP before believing a "didn't connect"**. Angle is no good either,
now that the dive is deliberately steeper than Kung Lao's: a run/drop ratio only
says which angle was picked, never whether it is accelerating at all.

Nothing was needed on the drone side: the counter table is indexed by the
attacker's **action**, and the dive reuses `act_noob_shadow` (`0116h`), which
already has `c_noob_shadow` in it.

### Shadows fly his real animations (2026-08-18)

Two of the three shadows are no longer authored NOOBFX art. They fly the move
Noob is visibly doing, cast off him in black:

| Variant | Shadow animation | Table |
| --- | --- | --- |
| 0 slide | `a_slide` — `NJSLIDE1/2/3`, his real Sub-Zero slide | anitab2 `0ah` |
| 1 kick | `a_noob_airkick` — `NOOBAIRKICK1/2`, still authored | anitab2 `08h` |
| 2 dive | `a_njflipkick` — `NJFLIPKICK1/2/3`, the descending kick | **anitab1** `1eh` |

Three things this drags along, and the first is the one that bites:

- **bpp.** Ninja records pack at 6bpp (control word `06580h`, bits 12-14 = 6) and
  address 64 colours; NOOBFX art is 4bpp on a 15-entry ramp. Handing
  `noob_shadow_p` to a 6bpp sprite lets every pixel value over 14 index off the
  end of the block — the `SONICCLAP` garble, and it is silent. `noob_shadow6_p`
  is the 64-entry version. Slot size is not the constraint (`getfpal` spaces
  slots 256 entries apart, `sll 8` in PALL.ASM); *defining* all 64 is.
- **The ramp is derived, not authored.** `NOOBALT_P` (Noob's own NINJAS1.IMG
  costume) remapped by luminance with a **gamma of 3**. A linear scale was tried
  first and read *lighter* than Noob on screen — his body renders on `NOOBDEF_P`,
  which is nearly all pure black. The curve pushes 16 of 63 entries to true black
  and drops mean luminance from 2.7 to 1.6, leaving only highlights lifted. Its
  top entry is `01D08h` against `UMKNOO1_P`'s `020E7h`, so it sits just inside the
  4bpp shadows' own band. Verified by sampling the rendered pixels, not by eye:
  a NEAREST upscale of a 400x254 frame is genuinely misleading here.
- **`get_char_ani`, not `get_char_ani2`, for the dive.** `a_njflipkick` is a
  TABLE 1 row. The two tables are unrelated lists and the wrong fetcher silently
  resolves a different row.

Each shadow's strike box is now its real move's box — `stk_noob_slide` took
`stk_slide`'s geometry, `stk_noob_dive` is `stk_njflipk` end to end — so art and
hitbox agree by construction instead of by measurement. Placement needs no
correction either (`NOOB_SLIDE_DY` / `NOOB_DIVE_DY` are 0): fighter art is drawn
against a fighter's anchor, which is the anchor `match_ani_points` already put
the shadow on. Only the kick still needs its measured `NOOB_KICK_LIFT`.

### Teleport lands in uppercut range (2026-08-18)

`teleport_next_to`'s own gap is `054h` = 84px, and `stk_njuppercut`'s box front
reaches `04eh` = 78 — so the obvious follow-up to a teleport whiffed by a hair.
`NOOB_TELE_GAP` closes it to `040h`; measured at **70px** in the harness, inside
the reach. The flight path is untouched, only where he re-enters.

Done through a new `teleport_next_to_a9` entry point rather than by editing the
`054h`, because `do_hh_teleport` and `melt_decoy` share that routine and neither
should move.

The slide and kick are **projectiles** - Noob stays on the spot and a detached
shadow travels. `do_slide`'s `towards_x_vel` on the player body is deliberately
absent. He does not slide or kick himself either: the slide snaps a roundhouse
(`a_njroundh`, NJROUNDKIK2 -> NJROUNDKIK1 -> NJROUNDKIK2 - out, coil, out, at
`NOOB_KIK_TICKS` either side of a longer `NOOB_KIK_COIL` middle) and the kick
holds `a_njstance`, so the shadow reads as something he casts rather
than something trailing him. The slide shadow also **survives its own hit** -
it strikes once, `dead_projectile` marks it spent, and it keeps travelling off
the screen instead of vanishing on contact. The kick still deletes on contact
(it was going to vanish at its apex a few ticks later regardless).

**Black smoke trail.** Both shadows drop a puff every `NOOB_TRAIL_RATE` ticks
(`noob_trail_tick`, MKZAP.ASM) and `noob_puff_proc` (MKFX.ASM) draws it. The art
is the stock `PUFF1..PUFF5` / `a_puff` smoke - `data/ACID1.IMG`, loaded through
`MK6MIL.LOD` into `MKFX.TBL` - recoloured to **`NOOBPUF_P`**, an authored
near-black palette that ships in ACID1.IMG right next to `ACID_P` and the stock
`PUFF_P`. No new art, no video-ROM cost.

Four things that decide how this behaves:

- **The proc lives in MKFX.ASM, not MKZAP.** `PUFF1` and `a_puff` are private
  labels of MKFX.OBJ (`MKFX.GLO` is a two-line stub nobody includes), so the
  puff has to be built where the art already is. `noob_puff_proc` is exported
  the way its neighbours are - one `.global` line in `MAINEQU.ASM`, next to
  `smoke_a_guy` / `nitro_smoke_tick`.
- **`swpal`, not a bare `getfpal`.** `object_setup` has already claimed `PUFF_P`
  off `PUFF1`'s icmap, so there is a live reference to release. The
  bare-getfpal rule in `get_noob_shadow_obj` is about *recycled* objects whose
  `opal` is stale; a fresh `gso_dmawnz` object is not one.
- **`NOOBPUF_P` is not exported anywhere** - no LOD pulls it and it is not in
  `IMGPAL6.ASM` - so `noob_puff_p` in MKFX.ASM is a local copy, the same
  arrangement as `noob_shadow_p` and `jade_boom_p`. It is a near-black ramp
  with a faint blue lift rather than a flat zero fill, which is what gives the
  puffs interior form instead of rendering them as solid blobs. To re-extract
  it: a PALETTE record's 4-byte field at `name+12` is an **absolute file
  offset** and the `H` before it is the entry count, so
  `struct.unpack_from('<16H', ACID1_bytes, 0x5C)` is the whole job - validate
  the decode by pulling `PUFF_P` from `0x3C` and diffing it against
  `IMGPAL6.ASM` first. Note `palcnt` in the LIB_HDR over-counts by 3: ACID1
  reports 6 palettes and has 3 (`ACID_P`, `PUFF_P`, `NOOBPUF_P`).
- **Puffs are spread at random over the shadow's whole multipart body box** -
  `smoke_a_1`'s placement, with the shadow standing in for a fighter - so the
  smoke sits *around* him instead of being paid out behind him like beads.
  This is safe on a projectile even though `ground_multi` is not: the
  `*_mpart` routines walk `*a8(oimg)` (the multipart RAM), while `ground_multi`
  walks `*a8(oslink)`, which `get_proj_obj_m` has pointed at its gmo dummy
  *process*. It also retires the hand-measured per-variant DYs the old
  point-drop placement needed.
- **The trail dies with the shadow on the same tick.** Each puff stamps the
  flight process's procid and runs `existp` every tick instead of handing
  `a_puff` to `framew`; when the shadow goes, the smoke goes. Verified: puffs
  peak at 5, and both hit zero on the frame the shadow leaves the screen.

`create` passes a8-a11 straight to the child, and all four are live in the
flight loop, so `noob_spawn_puff` saves them, reloads them as the child's
arguments, and puts them back.

**End of the slide: stop, then poof.** The slide no longer runs off the edge.
`noob_slide_edge_test` stops it `NOOB_SLIDE_STOP` px inside whichever border it
is heading for, `nsp_poof` freezes it, marks it `dead_projectile`, and builds a
cloud over it in `NOOB_POOF_WAVES` bursts of `NOOB_POOF_PUFFS` before deleting
it underneath. The kick is untouched - it still ends at its apex, and the stop
line is gated on `a10` (the apex countdown, zero only for the slide).

The poof puffs are spawned with **no proc to watch** (`a0 = 0`), unlike the
trail. That asymmetry is the effect: the trail is torn down with the shadow,
but the cloud he vanishes *into* has to outlive him or there is nothing left to
have hidden him. Measured: puffs peak at 20, the shadow is deleted at rel 31,
and the cloud clears on its own by rel 44.

> **`NOOB_SLIDE_STOP` is 8, and that is not a typo.** The stop is taken on the
> shadow's *drawn* leading edge, but NOOBSLIDE's art sits ~149px ahead of its
> anchor while `stk_noob_slide`'s box front is only 120 ahead - so the hitbox
> permanently trails the sprite by ~29px and **every pixel of margin costs a
> pixel of reach**. At `0x30` the slide stopped 16px short of an opponent at
> full screen distance and did no damage at all. Re-measure with
> `tools/noob_slidepose_probe.lua`, which logs `worldtlx` and the stop line,
> before touching it. The teleport is Kung Lao's flight path with Noob's own
`NOOBTELE` frames swapped over his sprite and `UMKNOOB_P` over his palette;
`reaction_start_chores` calls `player_normpal` on every reaction, so being hit
in mid-air restores him for free.

Verified by `tools/run_noob_moves_test.ps1`: shadow travels 160px with Noob
stationary, kick rises exactly 120px, both connect (22/26 damage), the slide
pops the victim 62px *straight up* with zero horizontal movement, and the
teleport crosses the screen and reverts.  `tools/noob_slidepose_probe.lua` is
the finer-grained one - it resolves MKNJ.TBL/MKJX.TBL SAGs, so it names Noob's
own frames and the victim's KNOCKDOWN frames instead of just the shadow's.

Three things that cost time and are easy to repeat:

- **Do not call `ground_multi` on a `get_proj_obj_m` object.** It walks
  `*a8(oslink)` as an object chain, but `get_proj_obj_m` sets `oslink` to the
  gmo dummy *process* - so it writes an oypos into the process block, follows
  the process's first long into garbage and walks memory until it reads a zero.
  It wedged Noob permanently in `act_noob_shadow`. `scorpion_flame` can call it
  because plain `gmo_proc` leaves `oslink` clear. Use `multi_adjust_xy` with a
  measured offset instead.
- **`get_noob_shadow_obj` clobbers `a9`**, leaving it on the shadow's own
  animation - which loops forever by design. Handing that to `mframew` walks
  *Noob* round it and never returns. Re-fetch his animation after any spawn.
- **`flight` runs its own `away_x_vel`** on the a0 it is handed, so the
  `towards_x_vel` call in front of `r_slide`'s flight is dead code - its value
  never survives. Any knockback change has to be passed *in*: `r_noob_slide`
  hands it a plain `0` to kill the knockback entirely (`dont_touch` is 13, not
  0, so a zero is a real request and not a skip).

## Noob Saibot's shadow portal (2026-08-18)

`D,D + LK`. A spinning green vortex opens in the floor **under the opponent**,
he falls through it, and he comes back out of the air **behind Noob's back**,
landing on it. Noob never moves - same relationship the two shadows have: he
casts (`a_njzap`, the ninja projectile-throw pose), the magic does the work.

`data/NOOBPORT.LOD` carries two sets from `NOOB.IMG`: `NOOBPORTAL1-12` (one
full rotation of the vortex) and `NSPORTALSHOT1-3` as A/B strips (Noob's own
body casting it). **48,882 bytes** at `PPP> 6` in a 57,344-byte slot,
`0x79C000..0x7AA000`, LOAD2 base `0x05CE0000`.

That figure tracks the IMG and the art is live - the vortex was re-cropped
twice and the cast frames re-authored once during the build, walking the
payload 38,604 -> 38,094 -> 37,902 -> 48,880 -> 48,882. **`python makevrom.py`
prints the live number; do not trust a figure written down here.**

**Where the space came from.** Carved off the TOP of the staged `UMK3FIRE` run,
the same way `BOSSHAM` and `RNVIC7` were, so UMK3FIRE keeps its `0x05C0E000`
base and only loses room above its payload. It is down to **124,928 bytes**
against the 140,160 its art currently packs to, and that is a deliberate trade
rather than an oversight: NOOBPORT fits in **no other free run in either bank**
(the next largest are the bank-1 MKSOUL1 tail at 20,412 and the JADVIC tail at
12,014), and UMK3FIRE is staged, not shipped. Re-cutting its frames as
multipart strips is what was always going to make it fit - the same re-cut took
SHAOFIST from 56,240 bytes to 26,664.

`PPP> 6` and its own sidecar rather than extra records in `NOOBFX.LOD`:
`NBPORTL_P` (NOOB.IMG palette record 3, file offset `0x74`) is a 32-entry green
ramp and the art uses every entry, so the 4bpp NOOBFX gets away with is lossy
here - and a mixed-depth LOD is what garbled SONICCLAP. `noob_portal_p` in
`MKZAP.ASM` is a local copy, applied with a bare `getfpal`; the LOD is `POF>`.

### The blast: `NOOBAIRGUNK3/4/5/6/8`

The hold on `SHOT3` is not a pause - it is exactly as long as the blast that
plays over it. Five frames at `NOOB_GUNK_RATE`, on an object of their own
(`a_noob_gunk`, `noob_anitab2` row `0d`):

| frame | where | what |
| --- | --- | --- |
| `GUNK3` | on Noob | out of his raised hands (`SHOT3`'s arms top out at -35; this sits -82..-19) |
| `GUNK4` | on Noob | climbing |
| `GUNK5` | **on the target** | the full column, arrived |
| `GUNK6` | on the target | reaches the floor (-9..+140; his feet stand on +139) - **the hole opens here** |
| `GUNK8` | on the target | the ground-level splash |

**7 is deliberately skipped** - `3-4-5-6-8` is a rise, a reach and a landing;
adding 7 back smooths the arrival into a sweep and loses the beat the hole is
born on.

**Ordering is the rule the move is built on: the floor does not open until the
blast is standing on it.** `GUNK3` and `GUNK4` are the launch and stay at his
hands; from `GUNK5` the object is re-aimed onto the exact spot the hole will
use. Both go through **`noob_aim_at_victim`** - one routine, so "the hole opens
where the blast landed" is true by construction rather than by two copies of
the same arithmetic that drift the first time either is touched. The harness
measures the gap between the two at the tick the hole appears and it is `0`.

It needs **its own object**, and that is a hard constraint rather than a
preference: a multipart object carries one `opal`, and this art is authored on
`NOOBGUK_P` (31 entries) while Noob's body is on `NOOBDEF_P`. So it cannot be
extra lanes on him however well the anipoints line up. `gmo_proc` rather than
`get_proj_obj_m` - the projectile slot is about to be taken by the hole itself,
and this is an overlay with no strike table and nothing for the drone to read.
Drawn at `front_z+1`, in front of everybody, unlike the hole which is behind.

`p_slave` is what makes it safe to interrupt: hit him mid-cast and
`reaction_start_chores` calls `delete_slave`, taking the blast with him. Note
the order around the spawn - `get_proj_obj_m` stamps `p_slave` with the
**portal** and `get_noob_portal_obj` then clears it, so the blast claims it
back immediately afterwards. No sleep in between, so the unowned window is not
a window at all.

### Noob's own cast: `NSPORTALSHOT1/2/3`, and back out in reverse

He is not borrowing a ninja pose for this one. `a_noob_pshot` (`noob_anitab2`
row `0c`) is a plain three-entry list that **stops**, and `do_noob_portal`
walks it by hand: `SHOT1` -> `SHOT2` -> `SHOT3` (arms out, arms rising, arms
thrown up), then **holds `SHOT3`** while the blast plays over it, holds it a
further `NOOB_PSHOT_TAIL` after the blast is gone, and only then unwinds
`SHOT2` -> `SHOT1` and on into his **stance**.

Five constants, and they are the whole timing of the move - nothing computes
off them:

| | ticks | |
| --- | ---: | --- |
| `NOOB_PSHOT_IN` | 4 | each wind-up beat (`SHOT1`, `SHOT2`) |
| `NOOB_GUNK_RATE` | 3 | each blast frame; five of them, so `SHOT3` is held 15 |
| `NOOB_PSHOT_TAIL` | 8 | `SHOT3` held **after** the blast, before unwinding |
| `NOOB_PSHOT_OUT` | 4 | each beat of the reverse |

Total `2*IN + 5*RATE + TAIL + 2*OUT` = **39 ticks (~0.65s)**, before the
`NOOB_PORTAL_SD` recovery. It was 22 and read as rushed.

There is deliberately **no separate constant for the blast stretch** - the pose
is held for exactly as long as the blast lasts, so retiming one cannot leave
the other behind. `TAIL` is what makes it read as a committed cast rather than
a twitch: he throws it, the blast plays out, and he stays reaching a moment
before coming down.

That last step is `noob_pshot_restore`, and it is not cosmetic.
`do_proj_sitting_duck` only sets an action and sleeps - it never touches the
frame - so whatever is displayed when the cast ends stays up for the whole
`NOOB_PORTAL_SD` window. Finishing on `SHOT1` was wrong twice over: it read as
the cast getting stuck a frame short, and `player_normpal` had by then put his
`NOSAI_P` costume back underneath art authored for `NOOBDEF_P`, so those ten
ticks drew the pose in the wrong colours. Palette and frame therefore move
together on one tick with no sleep between them - the same pairing and order
`noob_tele_restore` uses coming out of the shadow teleport.

Hand-walked rather than handed to `mframew` because an animation table can
express neither the hold nor the reverse leg. `a11` carries the table base
across the sleeps (a7-a12 survive, a0-a6 do not) and every step reloads `a9`
from it, since `do_next_a9_frame` advances `a9`. After the spawn the base is
**re-fetched** rather than trusted: everything `get_noob_portal_obj` calls into
(`getfpal`, `match_ani_points`, `insobj`, `spawn_proj_proc`) treats a0-a11 as
scratch, and two instructions buy certainty.

The three frames share a floor line - drawn bottoms 138/138/139 below the
object anchor, against 139 for his `NJ3STANCE1` lanes - so his feet stay
planted across the whole cast and **no `ani_adjustxy` rows are needed**. Worth
re-checking after any re-export: it is the pair-anchor problem that needed
three adjust rows in `a_noob_slide` / `a_noob_airkick`.

They are drawn in **`SAIBOON_P`**, his own costume, and the cast **does not
swap anything**. `SAIBOON_P` (NINJAS11.IMG record 31) is Noob Saibot's default
and it never changes - every `character_palettes_*` variant for ochar 15 points
at it. Where a set of his frames names a different ramp in the IMG, that is how
the art was exported, not an instruction; `NOOBDEF_P` is the **clone's**
palette, the detached shadow he throws, and his body should never wear it.

**One exception survives, and it is art, not policy.** `do_noob_teleport` still
swaps to `UMKNOO1_P`: `NOOBTELE1/2` are 4bpp art whose *lit* entries are 11..14,
and `SAIBOON_P` is lit at 1..8 and black at 11..14 - so the mapping does not
shift, it **inverts**, and dropping the swap renders him as a bright blue
cut-out instead of a silhouette. Caught by A/B snapshot, not by reasoning.
Fixing it properly means re-authoring those two frames against `SAIBOON_P`.

### The geometry is the art's, not a tuning pass

`NOOBPORTAL`'s ellipse centre sits **131px below its anipoint**, which is
exactly how far a grounded fighter's feet sit below his (`p_ganiy` 77, floor at
~197 - the same 131 `NOOB_SLIDE_DY` was calibrated against). So
`get_noob_portal_obj` re-matches the object to the **victim** and drops it to
his *grounded* anchor, and the hole draws centred on his feet with **no offset
constant at all**. The harness logs `DY +0` and that is the whole placement.

Aiming at his *grounded* anchor rather than his current one is deliberate: a
portal thrown at a man in mid-jump opens on the floor he is going to land on,
not in the air under his feet.

`NOOBPORTAL4` shipped with an anipoint of `(-13,-6)` where the other eleven are
`(53..73, -104..-111)`. Corrected in the IMG with `img_anipoint.py` to
`(68,-111)` - an anipoint fix belongs in the art, because a constant that
centres it one way throws it `2*dx` the other the moment the object flips.

### The strike box is NOT on the anchor

This is the one thing to read before touching `stk_noob_portal`. The object's
anchor is head height; the ellipse is on the floor only because the *art*
carries that 131px in its own anipoint. The **strike box does not**, so a box
built around the anchor sits around the victim's chest. The first build did
exactly that (`y_offset -010h`) and it "worked" for the wrong reason - it was
catching his chest, and it caught a **jumping** opponent's chest just as
happily on the way past.

The shipped band is `y_offset 05ah / y_size 040h` - the bottom ~40px of a
standing fighter and the floor under him.

### Jumping over it is a STATE test, not a hitbox

**No box can express "he jumped over it", and trying was the second bug this
move shipped with.** However the band is set, a jump passes through the bottom
of it on the way up and again on the way down, so a portal armed for
`NOOB_PORTAL_LIFE` ticks catches the takeoff or the landing of nearly any jump
over it. Reported from play as "I flip jumped it and still fell in".

Being airborne is a *state*, so `noob_portal_proc` tests it as one: an
`is_he_airborn` gate in the strike loop, checked before `proj_strike_check`
every tick. It costs nothing to reach - `spawn_proj_proc` copies
`p_otherguy`/`p_otherproc` from the thrower, so on the portal's own process
they already point at the victim - and it answers yes on `oyvel != 0` *before*
it compares `oypos` to `p_ganiy`, which is what covers the very first tick of a
jump, where he has committed but has not moved yet.

Landing back into a hole that is still open **does** catch him, and that is
correct: the exemption is for being in the air, not for having jumped once.
Ducking does not avoid it either - a crouch raises the top of his box, never
his feet, and you cannot duck a hole.

`NOOB_PORTAL_OPEN` (8 ticks of spin-up with no strike box) is the other half of
the counterplay. The hole is placed exactly under him, so an armed-on-spawn
portal would connect on its first tick and there would be nothing to react to.

### Structure

It is an ordinary **projectile that does not travel** - `get_proj_obj_m`, one
`pid_proj1/2` slot per player (shared with both shadows, so it is refused while
one is alive), `tell_world_stk` / `proj_strike_check`, `dead_projectile` on
contact. That is what makes it behave like a move instead of a script: it can
be blocked, it can be jumped, and the drone reads it out of `p_joyport` like
any other threat.

**Drawn at `back_z-1`, BEHIND both fighters.** `get_proj_obj_m` hands every
projectile `front_z+1`, which is right for something flying at a man and wrong
for a hole in the floor - in front, the ellipse crosses the victim's shins and
reads as a ring hung in the air. `back_z-1` rather than `back_z` or
`front_z-1` because the two fighters occupy `front_z`/`back_z` and anything AT
either value can z-tie with a fighter and flicker on insertion order; same
value and same reason as the Cage blood pool (`MKDEATH.ASM`) and the hammer
blur's opening frames (`MKBOSS.ASM`).

Two things the harness had to learn the hard way, both worth knowing before
scripting any fighter by hand:

- **Nothing grounds a hand-launched fighter.** `gravity_n_bounds` integrates
  `ograv` into `oyvel` and stops there; landing is `flight`'s job
  (`clr ograv` / `stop_me` / `ground_player`) and a drone thrown by a debug
  write never enters flight. He accelerates downward forever, and the *next*
  pass then measures a victim thousands of px below the world.
- **A velocity handed to a CPU fighter is gone by the next frame** - the drone
  re-asserts its own `oxvel` from its state machine. Driving `oxpos` is the
  only way to make a drone actually travel.

The reposition is **not** in `MKZAP`. `stk_noob_portal`'s hit routine is
`r_noob_portal` (`react_to_nj` row `1b`), which runs on the **victim's**
process - so the swallow, the drop and the landing are his animation and his
recovery rather than a puppet sequence. Four beats:

1. KNOCKDOWN2, not KNOCKDOWN1 - frame 1 is the recoil off a blow that shoves
   you, and nothing shoved him (`r_noob_slide`'s reason).
2. He sinks `NOOB_RNP_SINK_TICKS` x `NOOB_RNP_SINK_STEP` = **24px**, drawn
   over the swirl the whole way down. That number is the art's: the ellipse
   spans ~21px above the floor line to ~22 below, so a deeper sink puts his
   feet below the hole entirely and he reads as melting through solid stage
   floor beside it rather than as going down it.
3. `m_inviso` for `NOOB_RNP_GONE` ticks.
4. `match_me_with_him` onto Noob, `multi_adjust_xy` **past** him, `oypos` above
   the top of the screen, `face_opponent`, visible again, `flight` down into
   the knockdown's part-2 back slam.

The near-edge fallback and the sign convention are `teleport_next_to`'s,
unaltered: after `match_me_with_him` the mover carries the reference's facing,
so negative is "out through his back" and positive is "in front of him".
Default is behind; when **Noob** is the one hugging a wall there is no behind
to drop into and the victim comes down in front of him instead.

**No smoke.** Both shadows trail black puffs and the slide vanishes into a
cloud of them, so smothering the swallow the same way was the obvious move -
it is not wanted here, the hole is the effect. Beat 2's short sink is what
replaces it: with no cloud to hide an overshoot behind, he simply must never
draw below the hole.

### Touch points

`NOOBPORT.TBL` (`.INCLUDE` in `MKNJ.ASM`, and in `promote_tbls.py`'s
`GENERATED_TABLES`); `a_noob_portal` + `noob_anitab2` row `0b`;
`nj_strikes` `1e` -> `stk_noob_portal`; `react_to_nj` `1b` -> `r_noob_portal`;
`projectile_jumps` `26` -> `do_noob_portal`; `scom_noob_portal` and the
`noob_lk_portal` branch in `noob_lo_kick`; `act_noob_portal` (`0117h`).

`scom_noob_portal`'s window is `020h`, wider than the shadows' `010h`: a
repeated direction has to pass through neutral to register twice, which costs
a couple of ticks a `D,B` roll does not.

### Proof

`tools/run_noob_portal_test.ps1` + `noob_portal_test.lua`, three passes:

| Pass | Asserts |
| --- | --- |
| `hit` | hole spawns on the victim (`DY +0`), the vortex frames play, 12 damage, victim goes `m_inviso`, comes down from `oypos -160`, ends on the far side of Noob, and **Noob turns to face him** |
| `jump_up` / `jump_fwd` / `jump_back` | victim launched on a real 138px arc (velocity + the game's own gravity, not a pinned `oypos`): no damage, no swallow, and the hole closes itself. `jump_up` stays directly over the hole so it cannot pass by drifting out of the x band; the other two travel ~90px |
| `lethal` | victim on 6 HP so the portal kills him - he must not be left invisible, which is the one window where that could happen |

## YOTEIGAI TOR - a playable stage on the ladder screen's mountain (2026-08-18)

`curback` **018h**, `peak_mod` in `src/BGND.ASM`. Reachable from the VS-screen
stage picker (`vs_stage_cycle`, MKSEL.ASM) and in the between-match rotation
(`match_stage_cycle`, MAIN.ASM), one past FLAPJACK.

### What it costs

**36,176 bytes of video ROM and nothing else.** The whole backdrop is
`MOUNTAIN.BDB`'s two modules, in the ROM since the leak driving `mountain_mod`
(the one-player ladder map). No new background art, no new background
palettes, no BGNDTBL work. Only the floor is new: `data/MTOPFLR.LOD` at
`0x791000..0x79C000`. See `doc/ASSET_SPACE_LEDGER.md`.

### The planes

| Plane | List | Art | Scroll rate | Why |
| --- | --- | --- | --- | --- |
| 6 | `baklst6` | `mount2BMOD` - sky, cloud sea, distant range | **0** | the backdrop is nailed down |
| 2 | `baklst2` | `thunder1a` bolts via `one_bang` | **0** | `m_noscroll`; behind the mountain |
| 3 | `baklst3` | `mount1BMOD` - the mountain, right of centre | `08000h` | 1/4 of the floor, ~190px of drift |
| 5 | `baklst5` | far railing - mirrored soulteeth, lifted 36px, `TEEFBA2_p` | `01C000h` | hangs back ~95px |
| 4 | `baklst4` | stone deck - `parallax1-3` + the same three mirrored | `020000h` | what you stand on |
| 7 | `baklst7` | near railing - the same strips, `DEATHZN_p` | `020C00h` | leads by ~18px, drawn IN FRONT of the fighters |
| 1 | - | the fighters (`objlst`) | `020000h` | the camera's own plane |

Three floor lanes back to front is what makes it read as a **bridge** rather
than a spiked field. Splitting one BDB across two planes at different rates is
what makes the backdrop a stage rather than a still.

### The floor is placed by anipoint, at runtime, and reuses its art mirrored

Neither half is a `FL_*` skew strip: `floor_code` has no transparency and both
are mostly transparent above their own ground line.

`peak_calla` places every piece by **anchor** and subtracts that record's own
anipoint off `*a5(ianioff)` - the same `subxy` `dclipl` performs for a
multipart object and does **not** do for a single-part one. Nothing in
`BGND.ASM` encodes where a piece of art goes:

- **`parallax1-3` are only the LEFT half** of the 1200-wide deck; the right
  half is the same three drawn with `m_fliph` in the order 3,2,1.
  `parallax4-6` exist in the IMG and are never packed. This is seamless
  because a mirrored tile's right edge *is* its own left edge.
- **The railings are A..E subframes**, each cropped to its own tooth. Their
  anipoints are positional exactly as the parallax slices' are (`1A..1E` run
  45, 9, -27, -63, -99), so every strip of a composite takes one anchor and
  reassembles itself. That is why the run table names a *list* of records per
  placement.
- **The far railing is the near one mirrored about the run's middle**, so a
  piece whose near copy starts at `nK` ends at `stlen-nK`; mirroring its
  anipoint collapses the anchor to `stlen-nK-sta` and the width cancels out.

**Mirroring an anipoint is `anix' = xsize-anix`** - the rule `MKUTIL`'s `an2`
applies on the ani path. `peak_calla` does it by hand. The draw side needs
nothing: `clip5` (MKDISP) already adds `xsize-1` to a flipped object's
coordinate, so `oxpos` stays the LEFT edge whether mirrored or not.

`peak_floor_anchor_y` is `ground_y-116`, which lands the deck's top row on the
feet line - a fighter's own anipoint sits ~115 rows above his feet, so that is
where the art was drawn to.

### The railings are one set of art on two palettes

Every packed strip binds `TEEFBAC_p` through its own `PAL:L`, and **both**
railings now swap away from it: the near runs to **`DEATHZN_p`**, the far runs
to **`TEEFBA2_p`**. That gives a three-step depth ramp by mean luminance -
near 7.1, far **2.0** - which is what sells the distance across the bridge.
`getfpal` refcounts by palette id, so 39 strips on one palette still cost a
single slot; the probe reads `opal` off all three lanes and fails unless they
are three different colour maps.

`TEEFBAC_p` stays in `IMGPAL7.ASM` even though nothing draws in it any more:
it is still what the 19 records name in their `PAL:L`, so the symbol has to
resolve. Each strip claims it and releases it again in the same breath.

The palette is stated per-run rather than inferred from the flip bit - they are
independent facts, and tying them would break the first time a mirrored piece
wanted the front colours.

**The register this lives in is not free.** The palette override was first
parked in `a14`, which is silently destroyed before the first strip is ever
placed: `set_dmawnz`, inside `gso_dmawnz`, uses `a14` as its scratch. Both
railings came out on the same colour map and it is *not* obvious in a
screenshot - the two palettes are close in shape. It sits in `a6` now, with
the destination list moved into `b4` for the run (nothing in the path writes
the B file; `insobj_v` only reads it). `peak_stage_test.lua` reads `opal` off
each lane and fails if two railings share a map - which is how it was caught.

### `teethflip1` is a reference sprite, and must not be packed

It is `soulteeth2` mirrored pixel for pixel. The only thing it carries that no
other record does is its **`aniy` against the soulteeth' `-113`**: the
difference is how far the far railing sits above the near one, and there is no
way to derive it from the near railing's own art.

**Re-read it, never assume it.** That anipoint has already moved once - `-75`
to `-77`, taking the lift from 38 to 36 - and a stale copy is a railing at the
wrong depth that still passes any "is it above" test. `peak_teeth_lift` is
written as `113-77` so the arithmetic is visible, and the probe asserts the
exact value rather than a sign. `peak_calla` mirrors the real
strips with `m_fliph` and drops the anchor by `peak_teeth_lift` instead of
packing a second set of art.

### The cost is objects, not bytes

The strips mean 39 pieces per railing rather than 10, and this stage
hand-inserts every piece into a background list where it is **never culled** -
stock stages get their tiles from a BMOD plane, and `disp_mod` only inserts
blocks that are on screen. The floor is **84 permanent objects** of a 358
pool. The probe reports `objs_free_min`: 320 free before the subframe re-cut,
**252 after**, in a quiet scene. Comfortable, but no longer free -
`object_setup` calls `ermac 5` when `getobj` comes back empty, so watch that
number if anything else on this stage grows.

### The three courses parallax against each other

The deck is pinned to `020000h` because the fighters walk on it - anything
else and the ground slides under their feet. The railings are free, and each
one gets its own plane so it can move independently: the near rail **leads**
the deck by ~18px across the stage, the far rail **hangs back ~95px**.
Measured, not assumed - the probe reports `near_drift` and `far_drift` and
fails if either sign is wrong.

**The opposition is bought on the far side, not evenly.** Slower only ever
pulls a strip further inside its own plane, so `baklst5` can be pushed hard;
`baklst7` cannot, because a faster plane's `worldtlx` runs *past* the railing's
world-0 start at the left limit. At `020C00h` the left limit lands on 9, which
is all the headroom there is - anything more and the front rail runs out of
art at the west end of the stage.

**Two things constrain this and both are easy to trip over:**

- **Plane 1 is not available.** `worldtlx` is the camera the scroller drives
  and the plane `objlst` draws on, so a rate there moves the *fighters*, not
  the art. The near railing was on `baklst1` when it was locked to the deck;
  giving it a rate meant moving it to `baklst7`.
- **`baklst7` has to be skipped explicitly in the module list.** The list
  terminates with `0ffffffffh` and `init_bakmods` only writes as many
  `bak?mods` as it is given, so a plane past the terminator keeps whatever
  module the *previous stage* left in it - and `multi_plane` will happily fill
  `baklst7` with that stage's blocks.

The near rail's rate has a ceiling around 1.05x: the railing starts at world 0
and its plane's own `worldtlx` must not outrun it at the left limit. The probe
tests coverage per lane against that lane's own `worldtlx` at both extremes,
which is the only meaningful test once the courses stop sharing a plane.

### The near railing draws over the fighters

`baklst7` sits **after `objlst`** in `dlists_peak`, so the front teeth stand in
front of the fighters — it is the near lip of the bridge and they are behind
it. Still ahead of `objlst2`, which carries the text, so ROUND 1 and FIGHT!!
are never occluded.

That railing is opaque and reaches ~50px up from the bottom of the screen, so
it covers feet and anything played low — sweeps, slides, ground freeze. That is
inherent to a foreground railing; the lever if it eats too much is
`peak_deck_y`, which moves the whole floor down relative to the fighters.

### Music

The stage plays **the Pit II set** — `001h/002h/003h/004h` in
`round_1_tunes`/`round_23_tunes`/`finish_tunes`/`winner_tunes`, the same four
values curback 6 uses. All four tables are 25 entries so index `018h` is a real
row and not a read past the end.

### The stage is sized to the art

The deck is exactly 1200 wide, so the limits sit inside it: `left_edge` 20,
`right_edge` 781, initial `worldtlx` 400 - 20px of margin at each end for the
round-start pan to overshoot into.

`tools/peak_stage_test.lua` re-derives all three courses from the live objects
and fails on a gap, an overlap, a deck that is not exactly 1200, a railing
that is not 1254, railings that do not land on the same span, a far railing
that is not above the near one, or two railings sharing a colour map. That is
what catches a re-cut - or a re-palette - of either IMG.

### `PON>`, unlike the sidecars around it

`object_setup` (MKUTIL.ASM) does a `getfpal` on `*a5(icmap)` at bit offset
`70h`. A `POF>` record leaves that field reading whatever follows it in the
link - the MKZAP/NOOBFX sidecars get away with it because they overwrite
`opal` afterwards. `parallaxP` and `DEATHZN_p` are `.global` in
`src/IMGPAL7.ASM`, spelled exactly as the IMG palette records are: LOAD2
copies a palette label verbatim, so `parallaxP` is not `PARALLAX_P`.

Both are declared 64 entries and zero-padded from the 58 and 62 they ship. The
art indexes to 57 and 61, so the pad is never addressed - it is there because a
6bpp colour map is 64 words and a short one leaves `getfpal` loading whatever
follows it into CRAM.

One LOD covers two IMG files only because both were already 6bpp. A
mixed-depth sidecar is what garbled SONICCLAP.

### Vertical layout, and the one number that is not a taste call

`worldtly` 32 with `ground_y` 265 puts the feet on screen row **233**. The
deck line and the ground line are now **separate constants** (`peak_deck_y`
247, `peak_ground_y` 265), so the fighters sit 18 rows into the deck rather
than on its back edge - and either can be nudged without dragging the other.
The floor anchor is `peak_deck_y-116`, where -116 is `parallax1`'s own `aniy`.

**`mount2`'s y is a ceiling.** The module is 240 rows and only rows 0..178 are
finished - below that the cloud sea is a patchwork of reused blocks with
visible seams, because the ladder screen covers that whole half with the
mountain and it was never completed. There are 212 rows of screen above the
teeth, so world y 66 (row 0 at screen 34, row 178 landing exactly on the floor
line) shows every usable row there is. Raising it further only trades sky for
seams. The ~34 rows left over sit at the **top**, where the autoerase colour
is the art's own night sky.

**`mount1`'s x puts the peak right of centre, not centred.** At world x 304 the
spire centre lands on screen ~272 when the camera is mid-stage - the same
framing the ladder map gives it, which is where the look comes from. It sweeps
177..367 across the stage, so at the hard left limit it grazes the right edge
and clips by a few pixels; that is the cost of the framing and it only happens
at the very end of the stage.

**`mount1`'s y is set by the HUD.** It sits at y **82**, putting the summit on
screen row 50. The life bars and names run to row 39 and the panel behind them
a little past that, so anything above ~45 is not on screen at all: an earlier
cut at y 40 put the summit on row 8, where the peak was hidden behind the bars
and the body below it read as a flat wall. Only the top ~144 rows are ever on
frame and the spire is under 70px wide there, so the 509-wide module box never
brings a cut edge into view at either scroll limit — which is what makes a
parallax this strong safe with one copy of the art.

`tools/peak_stage_test.lua` asserts this: it reports `mtn_top_screen` and fails
the run if the summit climbs above row 45.

### The storm

`peak_thunder` reuses `mountain_mod`'s `one_bang` and `lightning_table`
wholesale - same screen positions, same claps - and appends a **sixth slot**
carrying `a_thunder4`. Only
the schedule changes: `thunder_spawner` fires four bolts back to back on 38..66
tick gaps and loops, which is right for a map screen you look at for five
seconds and much too busy under a round. Here it is one bolt every 3..6
seconds off a random slot, ~40% of them with a clap.

It runs on **`pid_bani`, not `pid_fx`**. `killfx` sweeps every `pid_fx` process
and `oid_fx` object and it runs on fatalities, so as `pid_fx` the storm would
stop for good the first time somebody finished a round.

The bolts sit in `baklst2` **behind** the mountain, the same relationship
`dlists_bogus` gives them on the map screen.

**They are NOT `m_noscroll`, and that is the fix rather than the default.**
`one_bang` builds its bolt with `gso_dmawnz_ns`, which sets `m_noscroll` and
makes `dclipl` skip its `subxy a4,a10` — the coordinates in `lightning_table`
are then screen coordinates. That is right for the map screen, which never
scrolls. Here it was a visible glitch: the scroller pans up to 16px up when a
fighter jumps, the sky and the mountain slide down with it, and a
screen-pinned bolt visibly detaches from the sky it is supposed to be in.

So this stage has its own `peak_bang` and `peak_lightning_table` — `one_bang`
with the noscroll dropped and the table in **world** coordinates, written as
`screen + (peak_worldx0, peak_worldy0)` so they cannot drift if the opening
camera is ever retuned. X is still effectively fixed because plane 2's rate is
0, so `worldtlx2` never leaves `peak_worldx0`; Y now follows `worldtly` like
every other piece of sky. The map screen keeps stock `one_bang` and a stock
`lightning_table`, untouched — including its five slots, with `a_thunder4`
living only in the stage's own copy.

`m_noscroll` lives in **`oflags2`** (`0x160`), not `oflags` — `set_noscroll`
writes `oflags2` and `dclipl` tests `b_noscroll` in the register it loaded from
`oflags2`. The probe checks the real bit, and asserts it is CLEAR.

**Object coordinates are not proof of anything on their own.** A bolt placed
400px out would still report five tidy distinct positions while rendering off
the side of the screen. The probe converts each bolt to where it actually
draws — subtracting the plane's own `worldtl`, the way `dclipl` does — and
range-checks that against the 400x254 screen.

### The bolts belong to the SKY, not the mountain

Every one of the six bolt positions lands inside **mount2**'s box in
`MOUNTAIN.BDB` - they are sky-panel features. mount2's module origin is BDB
`(449,129)`, and converting the map screen's five slots through its own
placement (world `(0,0)`, `worldtly -48`) gives offsets of `(112,32)`,
`(192,16)`, `(288,0)`, `(256,13)`, `(304,8)` from that origin.

That matters because this stage scrolls and the map screen does not. On a
static screen "relative to the sky" and "fixed screen coordinate" are the same
thing, so the map screen's `lightning_table` could be written either way and
nobody could tell. Copying its raw screen numbers here was wrong: this stage
places mount2 somewhere else, so every bolt was displaced.

They are therefore written as offsets from `peak_sky_x`/`peak_sky_y`, and
plane 2 runs at the **sky's** rate (0). An earlier pass welded them to the
mountain's rate instead - that is the wrong relationship and it shows as the
strike sliding off the cloud it is drawn hanging from.

**`peak_bolt_drop` is the first of three liberties.** The map screen has no
life bars; this stage's HUD eats rows 0..~45, and two authored slots land at
screen y 34 and 42. Everything is pushed down a uniform amount so the highest
clears it - the arrangement is preserved, just lowered. **16 -> 36 -> 46 on
2026-09-01**; 16 was the minimum that cleared the HUD, the other 30 is a look
call that puts the rumbles down toward the cloud sea rather than up against
the bars. The small frames are 22..32 rows, so their tails now end around
screen 130..144 and the sea starts at ~148 - another 10 puts them *into* it,
which is a different look rather than a lower one.

**`peak_bolt_extra` (10) is the second, and it is per-slot.** The five are not
evenly spread: their authored `rel_y` run 32/16/0/13/8 and slot 2 already
carries a `+20`, so the effective order is 8/13/16/20/32 - slots 4, 3 and 1
bunch into eight rows at the top while slot 0 sits 24 below all of them. A
bigger uniform `peak_bolt_drop` moves the bunch and the outlier together and
never closes that. The top three take 10 each instead, giving 18/23/26/20/32.

**`peak_strike_lift` (20) is the third, and it is `thunder4` alone.** The small
bolts hang in the sky; the strike is the one that reaches down, so the two move
independently and in opposite directions.

Resolved screen positions after all three:

| slot | art | screen x | screen y |
| ---: | --- | ---: | ---: |
| 0 | `a_thunder1` | 109 | 112 |
| 1 | `a_thunder2` | 189 | 106 |
| 2 | `a_thunder3` | 285 | 100 |
| 3 | `a_thunder1` | 253 | 103 |
| 4 | `a_thunder1` | 301 | 98 |
| 5 | `a_thunder4` | 188 | 106 |

Those Y figures are the table values resolved by hand; the *drawn* rows differ
by each frame's own anipoint, which `ani` re-applies on the first `framew`.
Measured with `tools/peak_bolt_snap.lua`: slot 1 draws at 106, slot 4 at 108,
slot 2 at 101, slot 0 at 121, and the strike at 106 with its 74-row tail
ending at 180.

**Nothing here has ever needed an X correction, and that is not luck.** Plane 2
(the bolts) and plane 6 (the sky) both scroll at rate **0**, so the bolts are
welded to the backdrop and hold the same screen position however far the camera
runs - `peak_stage_test` asserts `worldtlx2 == worldtlx6` at all three camera
stops. Only Y ever had a conflict to resolve, because only Y had the HUD in it.
The X figures above are just `peak_sky_x + rel - peak_worldx0`, and since plane
2's rate is 0, `worldtlx2` never leaves `peak_worldx0`.

What the X column *does* show is that the five span screen 109..301 of a 400px
screen - the outer quarter each side never gets a strike. That is inherited
from the map screen's arrangement, where it was never noticeable because
nothing scrolled and the mountain filled the middle. Worth spreading if the
clustering ever reads as wrong; it is five `rel_x` values in one table.

**`thunder4` is the only one with an actual bolt.** `thunder1a`-`3a` are dim
glows inside a cloud, 22..32 rows of it; `thunder4b`/`4c` are a glow with a
70-row strike descending out of the frame. It sits at rel `(191,110)` -
screen `(188,144)` on paper.

**That arithmetic is wrong and it was wrong before the 2026-09-01 pass**: it
leaves out the anipoint. `peak_bang` writes the table y into `oypos`, then
`framew` runs and `ani` recomputes `oypos` off `oyval` *minus* the frame's own
`aniy`, which is 18 on every `thunder4` frame. The strike actually settles at
screen 126 as authored (116 with `peak_strike_lift`), so its 74-row tail ends
at 200, not 218 - **15px clear of the ledge at 215, never behind it**. Measured
with `tools/peak_bolt_snap.lua`. What sells it is the cloud sea it strikes
into, not contact with the deck.

**MOUNTAIN.BDB holds two lightning placements and they are 187px apart.** The
BDD editor's selection read-out gives world `(832,166)`; the bolt actually
drawn into the composition is at world `(640,239)`. Converting the viewer's
canvas through its own rulers reproduces the selection box at `(833,166)`
against that reported `(832,166)`, so the mapping is sound and the two really
are different objects. The drawn one is what this stage reproduces - the
selection sits at screen `(381,71)`, half off the right edge.

Slot 2 carries the authored `rel_y` of 0, the highest of the five, and
measured at screen 51 with the original `peak_bolt_drop` of 16 - right on the
HUD's edge. It takes an extra 20 of its own rather than dragging the other four
down with a larger global drop. That `+20` is why it is the one slot of the
three-highest group that does NOT also take `peak_bolt_extra`.

### Sound, and a wrong index inherited from the map screen

The cues are indices into `triple_sndtab2` (MKSOUND.ASM):

| index | sample |
| ---: | --- |
| 1 | buyin doors slam shut |
| 2 | distance thunder #1 |
| 3 | distance thunder #2 |
| **4** | **lightning strike** |

`thunder_spawner`, the ladder map's spawner, passes **1 and 2** - so half of
its thunder is a *door slam*. That is stock behaviour and it is left alone,
but this stage was copied from it and inherited the same mistake. The small
bolts now roll **2 or 3**, the two real rumbles.

`thunder4` - the 47x74 bolt that reaches down the sky - **always** plays index
**4**, the strike. A bolt that size landing silently is what reads as broken,
so it is not left to the 40% rumble roll.

**What is and is not verified.** `peak_stage_test.lua` taps the sound strobe at
`0x1d01030` and decodes the two-byte codes `send_code_a3` writes. It confirms a
distance-thunder code is sent and that **no door-slam code ever is** - the bug
above is provably gone. It does **not** confirm the strike code specifically:
the tap only captures a fraction of the writes (about seven codes across a
whole round, far fewer than the music alone produces), so a missing code is not
evidence of absence. The strike cue is verified by table inspection, not at
runtime.

Two things to know before trying to do better:

- **Sound verification needs `-Sound`.** Under `-sound none` the tap sees only
  the power-up handshake; the game's sends do not complete. The runner takes a
  `-Sound` switch and will also dump `tools/peak_stage_audio.wav` with
  `-wavwrite`.
- **Correlating that wav to a bolt does not work.** The strike windows are
  statistically indistinguishable from random windows against the continuous
  music (ratios 1.00/0.96/1.46 against a control median of 1.00 and a 90th
  percentile of 1.49), and the Lua frame counter does not map cleanly onto wav
  time anyway.

### `thunder4` costs nothing and had no table

`thunder4a-e` were already packed in `src/MKBGANI.TBL` - the leak wired
animation tables for `thunder1`, `2` and `3` and simply never built one for
`4`. Adding `a_thunder4` and a sixth `lightning_table` entry is pure program
ROM: **no video ROM at all**. It is the big one, 47x74 at full extent against
`thunder2`'s 40x32, which is also what makes it easy to confirm - the probe
records the widest bolt it sees and anything over 40 is slot 5.

Appending to the shared `lightning_table` is safe because `one_bang` indexes
it directly and nothing scans for the terminator; `thunder_spawner` (the
ladder map) walks indices 0..4 with explicit `inc`s and never reaches the new
one. `peak_thunder` rolls 0..5.

**Confirming it fires needs the RNG stirred.** `@rand` is reseeded identically
at every round start, so a scripted rig replays one fixed sequence of slot
draws however long it runs - thirteen strikes in a row never once rolled the
sixth entry, and rerunning produced the same thirteen. The probe now writes a
frame-derived seed into `@rand` periodically so the sample actually covers the
table.

**And the run has to stay inside the round clock.** The round timer is live;
past roughly 40 seconds of fight the round ends, the stage tears down, and
every reading after that belongs to another state. A 60-second pass reported a
192px-wide "bolt" on `baklst2` and three bogus scroll failures. `HOLD` is 700
frames per camera stop for that reason.

### Verifying it

```
pwsh tools/run_peak_stage_test.ps1
```

Boots into the stage, walks the camera to both scroll limits, and reports the
geometry, the per-plane scroll travel and the strike count. Four snapshots land
in `tools/screens/peak_stage/run_<stamp>/`. The field report proves the numbers
- it does **not** prove the picture; look at the snapshots.

The camera drive is the part that matters and the part that was wrong first
time: writing the fighters' `oxval` for 40 frames never left the middle of the
stage, and a floor one tile short would have passed. It holds each target for
240+ frames now and asserts that `worldtlx` actually reached both limits.

### The rain (2026-09-01)

The stage had lightning from the day it was built and nothing falling out of
it. It has both now: `peak_rain` in `src/BGND.ASM`, 24 drops on their own
display list, created alongside `peak_thunder` from `peak_calla`.

**The art is MK3's, and it is in neither leak.** `mk3-rebuild/REV21/MKRAIN.TBL`
carries six records - `DROP1-4` and `DROPHIT1-2` - and nothing else: the whole
`rain !!` block in MK3's `MKDISP.ASM` is commented out, `rain_ram` in its
`RAM.ASM` with it, and `DROP1` is `.global`'d in its `MAINEQU.ASM` with zero
references. It never shipped in MK3 either. What that dead block plotted was
not even these records - it CPU-plotted `drop_1`, an `[offset,pixel]` list that
exists nowhere in the archive. So there was nothing to port but table records
pointing into an image ROM we do not have, and the motion was ours to write
whichever way this went.

`REV21/img/MKDMIL.LOD` names the source as `c:\video\supermk3\img\RAIN.IMG`.
That file is not in the leak - `REV21/img` has eight IMGs and RAIN is not one.

**Recovered from UMK3 instead.** The dead include survived into UMK3, so its
program ROM still carries the six records: byte `0x9d6ec` of the `u54`/`u63`
interleave, SAGs `0x0bd58aab..`, control word `0x3000`. Decoding those against
the assembled gfx ROMs gives the pixels verbatim. The gfx base was derived
empirically (a 4 MB shift off the naive MAME group layout) and the proof is the
picture: six contiguous records all decoding to coherent, related art at one
single shift is not a coincidence, and the SAG deltas are exactly `w*h*3` bits.

`tools/make_rain_img.py` now holds the frames as reviewable ASCII and builds
`data/RAIN.IMG` from them; it is the source of truth, and Phase D fails the
build if the IMG drifts from it.

**Four drops, one animation frame.** `DROP2/3/4` share a pixel mask outright
and `DROP1` is the same streak a row longer - they are four *brightnesses*, not
four frames. What turns them into depth is `rain_art`/`rain_yvel`/`rain_xvel`/
`rain_deck` giving each tier its own speed and its own line on the deck:

| tier | art | DROPS entries | fall | drift | breaks |
| ---: | --- | --- | ---: | ---: | --- |
| 0 | `DROP1` | 3,4,6 - white/light | 16 | -5 | 30 rows into the deck |
| 1 | `DROP2` | 1,3,6,7 | 14 | -4 | 20 rows in |
| 2 | `DROP3` | 1,7 | 12 | -4 | recycles silently |
| 3 | `DROP4` | 2,5 - darkest | 10 | -3 | recycles silently |

`xvel` is not a taste call: the art leans 5px left over its 16 rows, so
anything other than `-5/16` of the fall speed is a picture of motion pointing
somewhere it is not going. The far two tiers do not splash because `DROPHIT2`
is 16px wide and a burst that size on the far half of the deck reads as a
puddle.

**One process, no counter.** The obvious shape - a spawner plus a process per
drop, the way blood works - needs a live count to cap it, and a cosmetic
counter that leaks its decrement on any exit path stops the effect for the rest
of the session. That is exactly what `blood_count` did. A fixed set of slots
built once and driven from one loop cannot leak. It is also why all 24 objects
are taken at once behind `objs_available`: `object_setup` calls `ermac 5` when
the pool is dry and `ermac` is `jauc $`, a hang. Either the whole storm fits or
there is no weather.

**`m_noscroll`, but the deck line is derived every tick.** Rain has no world
position to betray, so every coordinate is a screen coordinate. The one thing
that must track the world is the line the drops break on, and that is computed
from `peak_deck_y - worldtly` on each pass. The camera pans up to 16px
vertically when a fighter jumps and a splash pinned to a fixed screen row
visibly leaves the deck when it does.

**Drawn in front of the fighters and behind the near railing**, and both halves
of that are geometry. The two splashing tiers break 30 and 20 rows into the
deck; the feet stand 18 rows in (`peak_ground_y - peak_deck_y`), so every
splash there is is nearer the camera than the fighters. The near railing is the
front lip of the bridge, so it is in front of everything. Built behind `objlst`
first, which put the whole storm into the backdrop and hid the splashes behind
the bone teeth.

**`ani_flag`, not `ani0`.** This cost a build. `ani0` takes the object's new
`oflags` as an INPUT in `a4` and does not re-derive it, so calling it without
setting `a4` hands the blit whatever is left in that register. The failure is
not a wrong-looking sprite - it is *no sprite*: the 24 objects were on the
list, in the right place, moving correctly, and drew nothing at all, which
looks exactly like a display-list mistake and is not one. `MKDEATH.ASM`'s
head-spill lane documents the same trap. `ani_flag` is `ani0` plus
`move *a8(oflags),a4,w`, which is what a plain frame swap with no flip change
needs.

**Cost.** 276 bytes of video ROM in a 2,048-byte slot at `0x79B800`, carved off
the top of `MTOPFLR`'s (which keeps its `0x05C88000` base and 6,832 bytes of
guard). 24 objects out of 358 - `objs_free_min` 228 with the storm running, the
same figure `peak_stage_test` reports. `peak_overload` **2** and `qdma_drops`
**0** measured across a whole round, which is the clean value: every pass
finished inside its tick. The `28` an early run reported was the session
high-water mark including character select and the round-start pan - the probe
zeroes it at fight start now, which is the only way that number means anything.

### Verifying the rain

```
powershell -ExecutionPolicy Bypass -File tools/run_mame_small.ps1 `
  -Mame "C:\MAME\mame_mk2test.exe" `
  -Script "<repo>\tools\peak_rain_test.lua" `
  -SnapshotDirectory "<repo>\tmp\rain_snaps" `
  -ReadyFile "<repo>\tools\peak_rain_ready.flag" -NoSound -NoThrottle -Wait
```

A screenshot of rain is almost worthless - 24 thin streaks read as noise
whether they are moving, frozen or all in one place - so `peak_rain_test.lua`
measures the live objects over a whole round instead: 24 on the list, all
`m_noscroll`, all on **one** colour map (a second means a record lost its
`PON>` binding), every slot moving and falling, each drop drifting the way
its own streak leans (the wind changes sides every ~3-7s, so both directions
must appear and none may drift against its slant - see `peak_rain`), slots
recycling, both splash frames appearing, and the splashes landing 15..50 rows
into the deck **derived from `worldtly` at the time of the sample**.

That last check was wrong first time and reported a failure against working
code: it subtracted `worldtly` from an `oypos` that, on an `m_noscroll` object,
*is already* the screen row. A probe that double-subtracts the camera fails
exactly when the code is right.

The one thing the probe cannot see is whether any of it reaches the frame
buffer, and that is not hypothetical - the `ani0` bug above passed every one of
those assertions. Check the snapshots, and note that MAME expands the 5-bit
palette with a bare `<<3`: matching `DROPS` against `(v<<3)|(v>>2)` finds
nothing and looks like the rain is invisible when it is not.

**`peak_calla` runs once per ROUND, not once per stage** - `play_1_round`
(MAIN.ASM) calls `do_a11_background` on every round - so it issues its two
`create`s again each time. That is the one thing about this effect that could
corrupt something rather than just look wrong: a second `peak_rain` would drive
the same `peak_rain_ram` through object pointers the pool rebuild has since
handed to somebody else. It does not happen - the probe ends round 1
deliberately and re-measures - but it is not obvious from the source and it is
worth re-checking if the round flow ever changes:

| | round 1 | round 2 |
| --- | ---: | ---: |
| drops on the list | 24 | 24 |
| objects free | 228 | 229 |
| largest single-tick fall | 16 | 16 |

That last row is the detector. Tier 0 falls 16 and nothing legitimate can
exceed it, so a doubled advance shows up as 32. **Measure it on the contact
point, not on `oypos`**: the anipoints are not uniform (DROP2 is 17 where the
other three are 16, the splashes are 11 and 13), so a frame swap moves `oypos`
by the *difference* on top of that tick's fall and a landing frame reads as a
21-pixel drop. The first version of the check reported "a second peak_rain is
running" on a build where exactly one was.

The colour-map count is a **per-round** invariant for the same reason: all 24
drops share one map at any moment, but `getfpal` hands out a different slot in
round 2 than in round 1, and a set accumulated across the boundary reports two
maps on a correct build.

Both of those were probe bugs that failed working code, which is the failure
mode to watch for here - alongside the `ani0` one above, which was the reverse:
code that failed while passing every assertion the probe made.

### It does not always rain (2026-09-01)

The storm is always here - `peak_thunder` runs on every visit - but the rain is
sometimes, the way the Living Forest only sometimes has somebody standing in
the trees. `peak_weather_roll` (BGND.ASM) decides, and `peak_rain` dies on its
first tick when the answer is dry, so a dry match takes **no objects at all**.

`PEAK_RAIN_ODDS` is 86 out of 256 — a touch over one match in three. Measured
across 69,360 match states: 33.6%.

**The roll is not a draw from any generator.** It is a pure hash of five words
both machines already agree on by the time the stage is built:

```
battle_num, p1_char, p2_char, p1_wiar, p2_wiar
```

shifted together, mixed with one pass of the same xorshift the RNGs use, and
tested against the low byte. No RNG state means there is nothing to drift: a
peer whose object pool ran dry, or who skipped a blood spray, still computes
the same answer. `@rand` would have been safe to *read* — but `randper`
advances it, and that is the exact hazard `@blood_rand` was split off to avoid.

**No stored flag, and no `round_num` test.** Every input is constant across the
rounds of a match, so re-rolling on each round returns the same answer by
construction — the weather cannot change between round 1 and round 2 — while a
stored flag would need clearing on a path somebody eventually forgets.

**The inputs are chosen for what changes.** `battle_num` alone repeats the same
weather for every rematch on a 2P cabinet, where it does not move; the win
streaks do, so a rematch is a fresh roll. The characters are in there so the
same rung of the ladder is not always wet.

### The drop jitter is on its own RNG too

`prn_respawn` wants three numbers per respawn, a respawn every few ticks per
drop, 24 drops. On `@rand` that is thousands of advances a round, and **how
many of them happen depends on how many objects the pool had free** — the
`objs_available` gate. That is the same divergence `@blood_rand` exists to
prevent, so the rain got `@weather_rand` and `weather_random`/`weather_randu`
in `UTIL.ASM`.

Divergence *there* is harmless by construction: nothing but the drop jitter
reads it, and `peak_weather_roll` reseeds it from the match key at the top of
every round, so two peers that drifted are back in step at the next round
boundary.

### Verifying both branches

```
                     powershell ... -Script tools\peak_rain_test.lua     # wet
$env:RAIN_FORCE="dry"; powershell ... -Script tools\peak_rain_test.lua   # dry
```

The probe carries a **second implementation** of `peak_weather_roll`, in Lua,
and steers P2's character until the roll gives the branch it wants to test —
deliberately not a read of some stored flag, because the whole netplay claim is
that the answer is a pure function of those five words. If the two ever
disagree the probe fails.

The dry branch is where that can be checked *exactly*: `peak_rain` dies right
after the roll, so `@weather_rand` still holds the raw key. Measured
`a8f47afe` from the ASM against `a8f47afe` from the Lua. In a wet match the
respawns have churned it long before the probe can look (`a9fc723a` seeded,
`3ce128e5` observed), which is why the seed is only asserted on the dry side.

| | dry | wet |
| --- | --- | --- |
| objects taken | **0** | 24 |
| round 2 | reached | 24 drops, 229 free |
| verdict | PASS | PASS |
