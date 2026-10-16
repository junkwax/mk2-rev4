# MK2 Fatality Wiring Guide

How to wire a fatality (new or restored) end-to-end, distilled from the
2026-07-13 Johnny Cage headhole rebuild. This is the procedural companion to
[MK2_READONLY_FATALITY_COMMON_CONTRACT.md](MK2_READONLY_FATALITY_COMMON_CONTRACT.md)
(the behavioral rules) and
[JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md](JC_HEADHOLE_FATALITY_SOURCE_OF_TRUTH.md)
(a complete worked example).

This guide gets a fatality *running*. For getting it to land in the right
place — the anipoint/mirror model, the alignment tuners, and how to prove
placement rather than eyeball it — see
[FATALITY_ALIGNMENT.md](FATALITY_ALIGNMENT.md).

## 0. Read first, then copy an architecture

`../mk2-readonly/mk2-main` is the behavioral source of truth. Pick the stock
fatality closest to yours (the contract doc has a comparison matrix), copy
its *architecture* — controller shape, process ownership, palette handling —
and document every intentional difference. Do not design from a `.WVP`
preview, a YouTube capture, or memory.

## 1. Asset lane — where sprite data is allowed to live

**Hard rules (space is the constraint that kills projects):**

- **MK8MIL / REVX / "ROMX" program-ROM space is FULL and off limits.** No
  new LOD target at `0xFFD...`, no `makerom.py` REVX registration, no normal
  sprite pointed at program ROM. The T-Unit blitter cannot PIXBLT from
  program ROM anyway (see `feedback_no_program_rom_pixblt` history — the
  only workaround is the REVX→SCRATCH→DMA path, and REVX itself has no room).
- New fatality art goes in a **video-ROM move-art wrapper LOD**:
  `MOVEART2.LOD` (or a new `MOVEART3+` slot). `MOVEART1.LOD` is frozen —
  do not grow it. Check [ASSET_SPACE_LEDGER.md](ASSET_SPACE_LEDGER.md) and
  [CUSTOM_CONTENT.md](CUSTOM_CONTENT.md) for the current free ranges before
  claiming one, and [CURRENT_SAG_MAP.md](CURRENT_SAG_MAP.md) for what is
  already packed.
- Keep custom art **out of the stock character LODs** (MK2MIL..MK7MIL) so
  their SAGs never drift.

**Pipeline (one direction only):**

```text
sprite pixels + anipoints in the .IMG          <- the only editable source
        |  (LOD lists IMG name + record names; POF> = no palette field)
LOAD2 (build.py Phase A)
        |
data/*.IRW  +  tmp/load2/<NAME>.TBL snapshot   <- generated, never hand-edit
        |  (copy snapshot verbatim into src/; Phase B promote_tbls.py
        |   patches only SAG/CTRL afterward, so W/H/anipoints must be right
        |   in the IMG, not "fixed" in the TBL)
src/<NAME>.TBL   .INCLUDEd by the owning character/module .ASM
```

Rules learned the hard way:

- **Anipoints live in the IMG.** If a sprite set has no authored anipoints
  (all `0,0`), author them into the IMG record table — never as code-side
  offset tables or hand-edited TBL rows. A TBL that disagrees with its IMG
  will be silently un-fixed by the next Phase A.
- **`POF>` records carry no palette pointer — leave it that way** for any
  art drawn on a player object or as a multipart piece (see §4).
- After any `.IMG`/`.LOD` change, all four build stages must run:
  `build.py` → `makerom.py` → `makevrom.py` → `mamerom.py`. Program and
  video ROMs move together; a stale video ROM shows garbled or yellow art.

## 2. Attacker animation data

Two stock-legal shapes:

- **Even cadence:** a plain frame-pointer table (0-terminated groups),
  driven by `jsrp mframew` with the tick count in `a0`, or `animate_a9`
  for tables with inline ani commands.
- **Authored uneven cadence** (e.g. a native IMG sequence with per-step
  ticks): store native `[frame(.long), tick(.word)]` pairs once and drive
  them with a small local `mframe_a0`-style driver. **Mind the tick unit:**
  IMGTOOL sequences are authored at their own frame rate (typically
  12 FPS), while the scheduler ticks at the 54.7 Hz display rate — scale
  in the driver (12 FPS = 4.56 game ticks per authored tick; use x5, the
  nearest integer, which errs slower/more dramatic), never by baking
  scaled values into the table. Give the driver a pair count so the
  controller can hand off the victim at the authored contact step without
  splitting the table (`jc_headhole_pairs` pattern):

```asm
* a9 = pair stream, a11 = pairs to play; prcslp preserves a9/a11
my_pairs
	move	*a9+,a0,l
	jreq	myp_done
	calla	ani2
	move	*a9+,a0,w
	calla	prcslp
	dsj	a11,my_pairs
myp_done
	retp
```

Never duplicate frame labels to fake holds and never resample ticks from a
preview timeline — the tick field *is* the hold.

## 3. Victim animation data

- The victim reaction art belongs in the **victim's own module**, selected
  through an `anitab1` slot via `get_char_ani` — never streamed from the
  attacker's code.
- Slot `40h` was `DUMMY` in stock and now carries `a_headhole_fall`; a new
  fatality's victim table takes the next free slot (append to *every*
  normal character's anitab1, same index everywhere; use `jrnc`/`ochar`
  guards for Kintaro/Shao Kahn, whose tables are short).
- **Attach props to the body as multipart pieces, not overlay processes.**
  Player frames are 0-terminated lists of part records; appending one more
  record (e.g. a head, a wound) makes it inherit position, mirroring,
  z-order, and palette automatically, driven by each part's own IMG
  anipoint. Multipart RAM is `32*40` bits per player = up to 11 parts;
  stock frames use at most 5-6.

```asm
LKHOLE1
	.long	LKDEADLEG1A,LKDEADLEG1B
	.long	LKDEADTORSO1A,LKDEADTORSO1B
	.long	LKDEADHEAD1,0          ; appended piece rides the body
```

- Keep the stock group structure (0-terminated groups per `mframew` call)
  so the stock reaction cadence — including things like the decap knee
  wobble — replays without custom choreography.
- A separately-*moving* object (flying head, projectile prop) is the one
  case for a worker process; model it on `decapped_head` (MKCANNED.ASM)
  with an explicit `pa10` anchor, per the contract doc.
- **Single-object frame advance is `ani_flag`, never `ani0`.** The `ani`
  core takes the *new* oflags word in `a4`; `ani_flag` loads it from the
  object and `ani` sanitizes it against the frame's `icontrol`. `ani0`
  trusts whatever is already in `a4` — called after a sleep that is
  scheduler garbage, which lands in `oflags` and produces an invisible or
  screen-corrupting blit. (This was the old headhole iteration's
  never-diagnosed "late SPILL visibility issue".)

## 4. Palettes and Z

- **Never hardcode a palette into a TBL record for character art.** The
  same records serve both costumes, and shared modules serve several
  fighters (ninjas + Smoke/Noob, females + Jade). The victim body/pieces get
  their palette at runtime from `change_to_bloody_pal`, which indexes
  `bloody_palettes` (MKGUYS.ASM) by `ochar` and costume.
- Standalone effect objects created with `gso_dmawnz` need a
  palette-bearing bootstrap record; stock `BLOOD.IMG` effects use `BLOOD_P`.
- Z-order per lane: `init_special` puts the attacker in front by default;
  use `me_in_back` / `me_in_front` only when the contact art needs it, and
  say why in a comment.

## 5. Controller (MKDEATH.ASM)

Skeleton that satisfies the common contract:

```asm
do_my_fatality
	movk	1,a0			; fade = yes
	movk	2,a1			; death blow #
	callr	init_death_blow		; common gate + init_special + tone
	callr	disable_repell
	; optional z-order / lineup decisions, each justified

	movi	wait_forever,a7
	calla	takeover_him		; stop the victim while lining up
	...get attacker ani, match_him_with_me_f if the art needs contact...

	...play windup...
	movi	my_victim_fall,a7	; hand the victim its reaction at the
	calla	takeover_him		; authored contact step
	...play the rest of the attacker pass...

	sleep	<enough for the reaction to settle>
	callr	death_blow_complete	; exactly once
	jauc	victory_animation
```

Victim reaction (runs in the victim's own process; clone the nearest stock
reaction — `decap_fall` is the usual model):

```asm
my_victim_fall
	calla	rsnd_death_voice
	calla	face_opponent
	calla	change_to_bloody_pal
	movi	<slot>,a9
	calla	get_char_ani
	calla	do_next_a9_frame
	sleep	030h			; stock stand-there beat
	movk	6,a0
	jsrp	mframew			; group 1
	...shake_a11 / me_in_front / more groups per the model...
	jruc	local_wait_forever	; terminal hold survives victory
```

Non-negotiables (from the contract): enter every yielding helper with
`jsrp`/`retp`; one controller route, no duplicate implementation; the
victim is `takeover_him`-transferred, never puppeteered from the attacker;
completion is one call at the designed gameplay-release point; **no
scheduler-phase sleep compensation** — hand off at the boundary instead.

## 6. Input dispatch (MOVES.ASM)

A fatality trigger has three parts:

1. **The handler** — the character's button/motion handler owns the
   trigger (e.g. `jc_up` = Cage stick-Up, `jc_hi_punch` = Cage HP). The
   trigger button/motion is *not* in the combo table.
2. **The combo** — a `scom_*` pattern checked with `combo_look_lr`
   (facing-aware, windowed). Inspect/edit with `python combo_edit.py show
   <scom>`.
3. **The route** — either a shared slot:
   `db1_table[ochar]` / `db2_table[ochar]` reached through
   `do_fatality_1` / `do_fatality_2`, or a direct `movi do_x,a7` route.

```asm
xx_handler
	move	@winner_status,a0,w
	cmpi	3,a0
	jrne	death			; only during FINISH HIM
	movi	f1b...,a0
	movi	f2b...,a1
	movi	scom_my_fatality,a11
	callr	combo_look_lr
	jrnc	death
	movi	060h,a1			; max distance in pixels
	movi	do_my_fatality,a7	; or do_fatality_1/2 via db tables
	jruc	fatality_xfer_close
```

`fatality_xfer_close` then enforces the full common gate: distance ≤ `a1`,
violence/blood settings on, `winner_status == 3`, `f_death` clear (one
fatality at a time), victim not airborne, and the victim process parked in
the `dizzy`/`super_frozen` wakeup. You get all of that for free — do not
re-implement any of it in the controller.

For bring-up before the real input exists, use a test hook: a `.set` flag
in MAINEQU.ASM guarding an `.if` block in the handler that routes a plain
button press to the controller (`jc_headhole_hp_test` pattern). Ship with
the flag set to 0.

## 7. Sounds

Append entries to the `triple_sounds` table in MKSOUND.ASM (before
`triple_end`; indexes above `0xff` are fine — `triple_sound` bounds-checks)
and fire them with `tsound <index>`. Character screams come free via
`rsnd_death_voice` in the victim reaction.

## 8. Build and verify

```powershell
$env:ALLOW_STOCK_BG_DRIFT='1'   # only if other in-flight bg work needs it
python build.py && python makerom.py && python makevrom.py && python mamerom.py "mk2.zip" --source-video
```

- With `test_mode=1` in MKAMODE.ASM, `mamerom.py` writes the zip to
  `rom/test/mk2.zip` and leaves the MAME retail install untouched — run it
  with `mame -rompath "<repo>\rom\test;C:\MAME\roms" mk2`.
- Lua harness gotchas (all verified 2026-07-13, MAME `-autoboot_script`):
  - This MAME's TMS34010 Lua `space:read/write` takes **BIT addresses**;
    `sym_resolve.py --dump` also prints bit addresses. Use them directly;
    object/process pointers read from RAM are bit addresses too.
  - Use `emu.register_frame_done(...)`; `add_machine_frame_notifier`'s
    subscription gets garbage-collected.
  - To reach FINISH HIM in a `test_mode` fight (which never runs the real
    match flow): write the victim proc's `pwake` (+0xE0) to `dizzy_dude`,
    assert `winner_status=3` every frame, leave the health bars alone
    (zeroing a bar ends the round in 3 ticks), then send the trigger input.
  - Judge frame progression via the multipart SAG at `oimg`, not `oypos` —
    a body falls through its art anipoints; the object origin never moves.
  - See `tools/jc_headhole_clean_test.lua` for a working template.
- A real pass = trigger through the actual input gate, full victim
  reaction, terminal hold surviving into victory, completion handshake
  observed (`f_death` 2 → -1), no lockup — on both screen sides and with
  at least two victim families (one `DEADHEAD`-style and one
  `HEADHOLE`-style module).

## 9. Checklist

1. Closest readonly architecture named; differences documented.
2. Art packed in a MOVEART wrapper (never MK8MIL/REVX/program ROM);
   anipoints authored in the IMG; src TBL = LOAD2 snapshot.
3. Attacker table holds native ticks; no duplicated labels.
4. Victim art is an anitab1 slot in every normal module; attached props are
   multipart pieces; boss guard present.
5. No hardcoded palettes; `change_to_bloody_pal` at runtime.
6. Controller follows §5 skeleton; yielding helpers use `jsrp`/`retp`;
   `death_blow_complete` exactly once.
7. Input goes through `combo_look_lr` + `fatality_xfer_close`; test hook
   flag returned to 0.
8. Full 4-stage rebuild; harness pass per §8; MKAMODE restored to retail.
