# Wiring STLAUGH as Shang Tsung's victory laugh

**Status:** the sound is already in the DCS ROMs and verified working. What's
missing is (a) the game-code trigger and (b) the win-pose animation, which is
currently a static single frame. This doc gives an agent everything needed to
finish the job.

---

## 1. What already exists (do not redo)

The laugh audio (`sound/STLAUGH.mp3`, 1.62 s) has been DCS-encoded and patched
into a complete MAME ROM set at **`sound/mk2_stlaugh.zip`** using DCSEncoder's
`--patch` mode (script: `sound/stlaugh_patch.txt`). It occupies **sound calls
745–747 ($02E9–$02EB)**, which were the confirmed-unused GEXPLODE ("Ninja Girl
1: about to explode") tracks. Details:

- Track $02E9 = channel 1, $02EA = channel 2, $02EB = channel 3 — same clip,
  one per DCS channel, matching the game's dispatch convention (see §2).
- Stream: 211 DCS frames (1620.48 ms), 6,071 bytes, stored once at DCS address
  `$43CD62` (U6 offset `$3CD62`). Byte-for-byte verified against the encoder
  output, and decoded/auditioned via DCSExplorer.
- The zip contains all 20 files (game ROMs copied through unmodified), so it
  works directly as a MAME `mk2` ROM set.

To regenerate it (only if the clip or level changes):

```
cd sound
<DCSExplorer>/x64/Release/DCSEncoder.exe --patch --rom-prefix=* --rom-size=* ^
    --stream-dir=. -o mk2_stlaugh.zip ..\mk2.zip stlaugh_patch.txt
```

**WARNING — do not use the PLBUILD toolchain for this.** Raw DCS streams are
NOT the same format as `SNDS/*.CMP`: PLBUILD repacks .CMP data (strips
per-frame padding using an undocumented header field), which corrupts a raw
DCS payload. This was attempted and produced garbage audio. `.CMP` is an
intermediate format we cannot currently generate. DCSEncoder `--patch` against
the retail zip is the only supported path for new audio.

## 2. How MK2 game code triggers sounds

`src/MKSOUND.ASM` owns dispatch. Game code calls the `tsound <index>` macro
(`src/MACROS.HDR`), which loads the index into `a0` and calls `triple_sound`.
That indexes **`triple_sndtab`** (in MKSOUND.ASM), whose entries are:

```
.word   <priority-class>|<duration>, <sound-call-code>
```

- `<priority-class>` is one of the `sp_*` equates (high byte). Use
  **`sp_victsp`** ($61xx, "victory speech") — it's what Liu Kang's victory
  "ooooo" uses.
- `<duration>` (low byte) is the channel-busy timer in ticks; it gates when a
  lower-priority sound may steal the channel. Reference points: Kang's victory
  speech = 87, the ~2 s "X wins" announcements = 121. STLAUGH is 1.62 s, so
  **~105** is appropriate.
- `<sound-call-code>` is the code for **channel 1**; `triple_sound` picks a
  free channel and sends code, code+1, or code+2 (see `tsnd1/tsnd2/tsnd3`).
  This is exactly why STLAUGH occupies three consecutive calls. Use `02e9h`.

The table currently has 255 entries (indices $00–$FE, last one is
`sp_victsp|45,0282h ; fe = Dan Forden "Yeah!"`, followed by the `triple_end`
label). `triple_sound` bounds-checks against `triple_end`, so **appending one
entry at the end is safe** and makes the new index **$FF**. Verify the count
before assuming $FF:

```
awk '/^triple_sndtab$/,/^triple_end$/' src/MKSOUND.ASM | grep -c '\.word'
```

### Step 2a — add the table entry

In `src/MKSOUND.ASM`, immediately before `triple_end`:

```asm
	.word	sp_victsp|105,02e9h	; ff = Shang Tsung victory laugh (STLAUGH)
```

## 3. The victory-pose code path

Winner celebration is `victory_animation` in `src/MKCANNED.ASM`. It checks
`am_i_shang` first (catches morphed states) and jumps to **`st_victory`**;
otherwise it dispatches via the `victory_jumps` table (Shang is also index 6
there). Current `st_victory`:

```asm
st_victory
	movi	ft_st,a0
	calla	am_i_him		; am I in shang form ???
	jreq	stv5			; yes
	jsrp	back_to_shang_form
stv5	movi	029h,a9
	calla	do_first_a9_frame	; <-- STATIC first frame only
	jruc	local_wait_forever
```

Note `do_first_a9_frame`: unlike `generic_victory` (which runs
`movi 000060029h,a9 / jsrp animate_a9` — animation $29 at rate 6), Shang only
shows the first frame of his win pose. That is the "animation isn't wired up"
part.

The pattern to copy is **`lk_victory`** (same file), which adds a victory
voice line with a game-state guard:

```asm
lk_victory
	move	@gstate,a0,w
	cmpi	gs_psel,a0
	jreq	generic_victory		; no sound during player-select replays
	tsound	03ah			; kang: Oooooo
	jruc	generic_victory
```

### Step 3a — wire the laugh (minimal change)

Add the same guard + `tsound 0ffh` to `st_victory`, after the morph-back (so
the laugh coincides with Shang being visibly Shang):

```asm
st_victory
	movi	ft_st,a0
	calla	am_i_him
	jreq	stv5
	jsrp	back_to_shang_form
stv5	move	@gstate,a0,w
	cmpi	gs_psel,a0
	jreq	stv6
	tsound	0ffh			; Shang Tsung victory laugh (STLAUGH)
stv6	movi	029h,a9
	calla	do_first_a9_frame
	jruc	local_wait_forever
```

### Step 3b — animate the pose (the unfinished part)

To make him actually animate like other characters, replace the
`do_first_a9_frame` call with the generic pattern:

```asm
stv6	movi	000060029h,a9
	jsrp	animate_a9
	jruc	local_wait_forever
```

**Verify first** that Shang's animation $29 has more than one frame — check
what `get_char_ani` returns for `ft_st` index $29 (his character animation
table; if it's a single-frame pose, the original static call was intentional
and the frames need to come from elsewhere, e.g. his taunt/attract laugh
frames). If the anim table only has one frame, keep `do_first_a9_frame` and
treat the laugh audio as the deliverable; sourcing laugh animation frames is a
separate sprite task.

Timing note: if the laugh should sync with a specific animation beat, insert a
`sleep <ticks>` before `tsound` (see `kahn_victory` in the same file for a
sleep-then-sound example).

## 4. Build & install

1. Rebuild program ROMs the normal way (`python build.py` — Phase C uses
   `dosbox_asm.conf`).
2. The sound side must come from **`sound/mk2_stlaugh.zip`**, not the retail
   zip and not PLBUILD's `sound/U2-U7.ROM`. As of 2026-07-11, plain
   `python mamerom.py` uses the patched zip **by default** whenever it exists;
   passing an explicit retail zip prints a warning that the patched audio
   (STLAUGH) will be absent.
3. Expect MAME CRC complaints for both program and sound ROMs — normal for
   source-built sets. The single "bong" at boot means internal checksums pass.
   The DCS boot-time ROM checksums in mk2_stlaugh.zip are valid (DCSEncoder
   regenerates them).

## 5. Testing

- **Sound alone (no program-ROM changes needed):** install `mk2_stlaugh.zip`
  and trigger sound call 745 directly — either through the test-mode sound
  test, or a MAME Lua/debugger write of $02 then $E9 to the sound latch (see
  existing harnesses like `tools/run_mame_small.ps1` / `mk2_test.lua` for the
  Lua patterns used in this repo).
- **Full path:** pick Shang Tsung, win a round, confirm the laugh plays at the
  victory pose (and not on the player-select screen). Also win as *morphed*
  Shang (win while transformed) to exercise the `back_to_shang_form` branch.
- Regression: trigger a couple of other victory sounds (Liu Kang win = call
  index $3A path) to confirm the appended table entry didn't shift anything —
  it can't if appended before `triple_end`, but verify anyway.

## 6. File inventory

| File | Role |
|---|---|
| `sound/mk2_stlaugh.zip` | Patched, verified MAME ROM set (STLAUGH on calls 745–747) |
| `sound/stlaugh_patch.txt` | DCSEncoder patch script (rebuild recipe in header) |
| `sound/STLAUGH.mp3` | Source audio |
| `sound/STLAUGH.dcs` | Raw DCS-encoded stream (DCSa wrapper, for reference) |
| `src/MKSOUND.ASM` | `triple_sndtab` — add entry $FF here |
| `src/MKCANNED.ASM` | `st_victory` — add `tsound 0ffh` + animation here |
| `doc/STLAUGH_SHANG_VICTORY.md` | This document |
| `doc/UNUSED_AUDIO.md` | Census of all 58 unused audio files (~236 KB) available for reuse |
| `tools/sound_reach.py` | Reachability analysis that produced the census |
| `sound/unused_mp3/` | MP3 previews of every unused clip |

**Status update:** steps 2a and 3a are DONE (table entry $FF added, `st_victory`
plays it with the gstate guard, static frame kept). Built and installed to
`C:\MAME\roms\mk2.zip`. Remaining: step 3b (animate the win pose) if desired.
