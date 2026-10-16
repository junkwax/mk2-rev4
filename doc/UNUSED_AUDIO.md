# MK2 unused audio census

> **Current free space and what is ready for overwrite:** see
> [Free space and reclaim candidates (2026-09-20)](#free-space-and-reclaim-candidates-2026-09-20)
> below. (Its opening figures predate the friendship reclaim it records as
> DONE; re-measure before relying on them.)

> **RE-AUDIT 2026-10-06 — the inventory below had gone stale in 20 rows.**
> Every inventory row was re-checked three ways against the installed build
> (`C:\MAME\roms\mk2.zip`, built 2026-10-06 01:24) and the retail set
> (`mk2-stock-build/rom/mk2_retail.zip`): (1) the row's first track in
> `DCSExplorer -I --info -p` of both sets, with the stream bytes compared
> raw (`--extract-format=raw`), (2) every `triple_sndtab`/`tab2` row pointing
> at that track, (3) every sender of those indices — `tsound`/`tsound2`,
> `movi ..,a0/a1` into `triple_sound*`, packed `random_triple` pools, `.word`
> pools, and `randu` arithmetic, read in context. Findings:
>
> - **SPLISH1/2/3 are LIVE**, not uncertain. Retail audio, byte-identical
>   streams, table rows $73-$75 unchanged. Sent by `blood_random_splish_sound`
>   (MKBLOOD.ASM, 6 callers — stock has the routine but no callers), the Dead
>   Pool acid (MKHANG.ASM `hp_splish`: $73 surface breach, $74 drip, $75
>   bubble pop) and Noob's shadow moves (MKZAP.ASM `random_triple 000030073h`,
>   5 sites).
>   ⚠️ **SPLISH3's table duration is half the clip.** `sp_splish|20,0209h`:
>   20 ticks, but MK2.LST gives the track as 38.9 ticks (0.71 s). SPLISH1
>   (17 vs 17.6) and SPLISH2 (14 vs 14.2) match. After tick 20 `triple_sound`
>   treats the channel as free and any later sound can cut it off. The
>   value is retail's, but retail never played SPLISH3, so it was never
>   heard. The lost tail is quiet (0.6% of the clip's energy), so the clipped
>   ending will be subtle at most.
> - Also LIVE and wrongly listed as unused: `MUNCH` (`tsound 0103h`,
>   MKDEATH.ASM), `VPATTAK2` (`tsound 0108h`, Cage headhole windup grunt),
>   `LILSTAB1-3` (`do_shred` / `sounds_of_shred` cycle $A0-$A2).
> - Slots REUSED since their row was written: `VPDEATH` → FROSTY (note 57,
>   $102), `JHFELCH` → FLYBRAIN wins (note 50, tab2 $61, MAIN.ASM), `REPTPOOF`
>   → throne room applause (note 56, tab2 $68, MK1THRN.ASM), `BODINFLT` →
>   KAHNCOWARD "Run, coward" (note 58, tab2 $63, MKBOSS.ASM), `BIGFALL1` →
>   ScorpFall (note 18), `KISS2` → ScorpFat2 (note 19), `SKB1L` → JadeZap
>   (note 37), `DFYEA` → MK1 Cage headhole "Yeah" (tab1 $FE), `KOTOE1` → DRAW
>   (note 52, tab2 $67), `VPREACT1` → Rain wins (tab2 $65), `VPREACT2` ch2 →
>   JadeBoomWhoosh (ch1/ch3 no-op'd, note 13), `VPREACT3` ch1 → JadeNitroKick.
> - **No live sender reaches an emptied slot.** 11 table rows point at
>   tracks that are bare `End;` in the build (tab1 $99 $B9 $CA $D5 $F9, tab2
>   $52-$55 $58 $59). No `tsound`, pool, `.word` table or `randu` range sends
>   any of them, so this check found nothing like the DTHUN2 problem.
> - `tools/sound_reach.py` is now wrong in BOTH directions, so don't treat
>   its output as the final word. It reports DTHUN2 unreached (`randu`
>   arithmetic) and the four hidden-fighter name tracks
>   ($0352/$035B/$0361/$036D) unreached (MKSEL.ASM `psel_hidden_pick` loads
>   the index into `a1`), and it maps every call to its ORIGINAL `.CMP`, so a
>   reused slot still reports under the old clip's name.

A reachability analysis of every sound-dispatch mechanism in the game source
found **47 audio files (160,798 bytes compressed) that no in-game code path can
trigger** in the current source (2026-07-21). That's the audio equivalent of
about a third of a sound ROM chip, and it confirms and greatly extends the 10
clips documented on cut-content sites.

> Correction history (from a full per-file audit of every literal occurrence
> of each call code and table index across the source tree):
> - FATAL2 ("End Fatality" music) IS played — `death_blow_complete`
>   (MKDEATH.ASM) sends call 53 when a death blow finishes (skipped for actual
>   fatalities, where the gloom music lingers; babality swaps in call 63). A
>   conditional between the `movi` and `send_code_a3` had pushed the send
>   outside the analysis window (now widened in `tools/sound_reach.py`).
> - KOTOA (call 545) and KOTOB (call 548) ARE played — but only as the
>   operator test-menu move/select beeps (`mm_sound`/`ms_sound` equates,
>   DIAGMENU.ASM `menu_move_sound`/`menu_select_sound`). They were missed
>   because they're sent by symbolic name, not hex literal. Moved to the
>   diagnostics-only section below.
> - TNGUESTK is confirmed as an INTENTIONAL cut: MKDEATH.ASM:2877 contains its
>   commented-out trigger (`; tsound 099h ; sound: tongue stick`) with the
>   scorpion-spear hit sound substituted on the line above.
> - DTHUN2 was double-confirmed dead: every thunder animation script sends
>   table index 2 (Thunder #1), and `thunder_spawner` only ever passes
>   indices 0/1/2.
> - **CORRECTION (2026-09-06) — DTHUN2 stopped being dead on 2026-08-19.**
>   The reading above was right when it was written, and `stlaugh_patch.txt`
>   note (20) no-op'd calls 566-568 on 2026-08-01 on the strength of it. Then
>   `peak_thunder` (`src/BGND.ASM`, the Mountain Top storm) landed eighteen
>   days later and randomizes its rumble over `triple_sndtab2` index **2 or
>   3** — `movk 2,a0 / randu / addi 1,a0` — so index 3 was being dispatched at
>   an empty slot. Roughly one in five small bolts flashed with no sound (the
>   big `thunder4` strike always takes index 4 and was never affected).
>   **DTHUN2 has been restored** (patch note 29); it was only no-op'd, so
>   deleting the `End;` blocks brings the retail streams back, at a cost of
>   2,274 bytes. `tools/sound_reach.py` still reports 566-568 as UNREACHED and
>   cannot be expected to catch this: the index arrives through `randu`
>   arithmetic, not a `tsound` literal. **The general lesson is the mirror of
>   the GIB correction below: a no-op reclaim stays safe only while nothing
>   NEW starts dispatching its table index. When adding a stage or move that
>   sends a `triple_sndtab`/`tab2` index, check that index against the
>   no-op'd slots in `stlaugh_patch.txt`, not just against the analyzer.**
> - The audit also cleared all previously *uncertain* entries (RIPARMS,
>   MILESPIT, SPLISH1-3, SKREACT1-4) [SPLISH1-3 since wired up — LIVE as of
>   the 2026-10-06 re-audit]: every literal occurrence of
>   their codes/indices in the source is coordinates, masks, equates, or
>   image IDs — none is a sound dispatch. Remaining risk is limited to
>   arithmetic the scan can't follow (computed `addi` chains), which was also
>   spot-checked (the only such dispatch found is the ice-slip cycle, already
>   counted as reachable).
> - The restored Cage headhole fatality uses `BWHOOSH3` and `BIGHIT3`
>   (`tsound 0100h`/`0101h` in MKDEATH.ASM — confirmed live). The table also
>   grew entries for `VPDEATH` ($102) and `MUNCH` ($103), but as of this
>   writing **neither has an actual caller anywhere in the source** — they
>   remain genuinely unused despite having table slots. `JAXAHH` ($104) is
>   live (MKSLAM.ASM, replaces the generic human throw voice). Mileena's ball
>   roll uses `MILEBALL`.
> - `GEXPLODE` is no longer present as an unused stream in the patched sound
>   ROM because its slot was replaced by `STLAUGH`.
> - `JETFX` is no longer unused: its slot (calls 70-72) was replaced with
>   `NOOBWINS.mp3` (Noob Saibot's "wins" line) and wired through
>   `triple_sndtab2` index $5A, which is read by the pre-existing
>   `winner_speech` table (indexed by winning character — entry 15 = `ft_noob`
>   = $5A) after every round. No `victory_jumps`-side trigger was needed;
>   `noob_victory` deliberately does *not* also fire $5A, to avoid playing the
>   line twice.
> - Two more `JH: gibberish` takes (`GIB1`, `GIB2`, `GIB3`) and `DFYEA`
>   ("DF: Yeah!") turned up as unused once the analyzer's table-index range
>   was widened to cover recently-added entries — not new cuts, just
>   previously out-of-range for the scan.
> - `VPJUMP` (calls 856-858, smallest of the VP scratch bank) is no longer
>   unused: replaced with `JADEFLASH.mp3` (a 58-frame/445.44ms shimmer clip)
>   and triggered from `src/MKZAP.ASM do_jade_flash_test` at the start of the
>   Jade Flash palette-blink effect (10 white/normal pairs, 60 ticks/460.8ms
>   total). Sent as a raw call code via `send_code_a3` rather than through
>   `triple_sndtab`, since no table entry pointed at this slot. A single play
>   covers 96.7% of the blink window almost exactly, so no `Loop()` is used —
>   two plays would nearly double the length and badly overshoot it.
>   (Later refined: replaced with `JADEFLASHLOOP.mp3`, a trimmed 110ms segment
>   played 4x via DCSEncoder's `Play(stream, repeat N)`, landing at 440ms —
>   just under the window rather than relying on one long single play.)
> - `VPGRAB` (calls 862-864, VP scratch bank) is no longer unused: replaced
>   with `SUBNADOSTART.mp3` (157 frames/1205.76ms) and triggered from
>   `src/MOVES.ASM do_sz_tornado` as the tornado's initial cue, replacing
>   `tsound 06ah` ("ice cast sound"). The following `tsound 0d7h` (arctic
>   blast) was left untouched — both `06ah` and `0d7h` are shared with other
>   Sub-Zero effects and death sequences (MKDEATH.ASM, MKZAP.ASM), so their
>   table entries were not repurposed; only this one call site was redirected
>   via a direct raw call code, same as JadeFlash.
> - `ENDGUY` (call 55, "music: End One player map") is no longer unused: its
>   track was redefined as a no-op (`End;`, no `Play()`) purely to reclaim its
>   8,664 bytes. Adding `SUBNADOSTART` pushed the total custom-audio footprint
>   past the original 6-chip (U2-U7) budget — DCSEncoder silently spilled the
>   overflow into a phantom 7th chip (U8) that doesn't exist on real MK2
>   hardware and isn't in `mamerom.py`'s `SOUND_ROMS` map, so it would have
>   been silently dropped on install. Reclaiming ENDGUY's dead space (it has
>   zero callers) brought everything back inside 6 chips. **Lesson: check the
>   DCSEncoder ROM layout report for extra chips beyond U7 after every patch
>   that adds new audio — the original 6 chips are already close to full.**
> - `GIB5` (calls 800-802, JH scratch bank) is no longer unused: replaced with
>   `KAHNIWIN.wav` (157 frames/1205.76ms), Shao Kahn's "I WIN" victory line,
>   wired through `triple_sndtab2` index `$5B` and `winner_speech` entry `d`
>   (`ft_final_boss`) so it speaks under the "SHAO KAHN WINS" banner. Note
>   that unlike the other JH-bank clips, GIB5 **does** have a `triple_sndtab`
>   entry (index 105, labelled "Raiden torpedo pool") — it is dead only
>   because nothing dispatches index 105, which `tools/sound_reach.py`
>   confirms; the table-entry column of the inventory below doesn't capture
>   that distinction, so check the analyzer, not just the family label, before
>   repurposing. Reclaiming its 5,704 bytes roughly paid for the new stream,
>   so no additional no-op reclaim was needed (U7 finished with 3,472 bytes
>   free). This one also required a game-code gate change: `bonus_count`
>   (MAIN.ASM) used to skip the winner speech entirely whenever the final boss
>   was in the match, so entry `d` could never have fired. The gate is now
>   narrowed rather than removed — Kahn's own win speaks, the human's "X WINS"
>   line stays suppressed in a Kahn match exactly as in retail.
> - `GIB2` (calls 689-691, JH scratch bank) is no longer unused: replaced with
>   `ERMACWINS.wav` (242 frames/1858.56 ms), Ermac's victory line, wired through
>   `triple_sndtab2` index `$5C` and `winner_speech` entry `17` (`ft_ermac`).
>   Ermac had been borrowing Reptile's line (entry 17 held `$0F`) since he is a
>   Reptile clone; `winner_text` entry 17 was still on `pf_rp_win` too, so the
>   banner read "REPTILE WINS" — it now points at a new `pf_er_win`
>   ("ERMAC WINS"). Unlike GIB5 next door, none of GIB1/GIB2/GIB3 has a
>   `triple_sndtab` entry at all, so there was no live-looking row to mislead;
>   `tools/sound_reach.py` reports the whole 686-694 run as UNREACHED, and
>   after the patch it correctly splits into 686-688 + 692-694. No gate change
>   was needed (Ermac is an ordinary selectable fighter, so `pwt1` already
>   reaches him). Reclaiming GIB2's 5,306 bytes roughly paid for the 6,203-byte
>   stream. The clip the user supplied was the name alone ("Ermac", 0.967 s)
>   with no "wins" suffix, so the suffix was spliced on the same way NOOBWINS
>   was built — lifted from `NOOBWINS.wav` itself, which carries a hard splice
>   gap at 1.610-1.630 s with the stock "WINS" running from 1.630 s to its end
>   (1.106 s). That took the stream to 11,081 bytes and spilled 2,800 into a
>   phantom U8, so `GIB1` (686-688, 5,166 B) and `GIB3` (692-694, 3,992 B) were
>   no-op'd to reclaim 9,158 bytes — buying lasting headroom per the note (17b)
>   lesson rather than covering just the spill. U7 finished with 5,690 bytes
>   free. **The whole JH gibberish bank (686-694) is now retired.**
> - **CORRECTION (2026-09-04) — the JH gibberish bank was never dead.** Both
>   entries above rest on `tools/sound_reach.py` reporting calls 686-694 and
>   800-802 as UNREACHED. It cannot see them: retail dispatched GIB1/GIB2/GIB3
>   from `do_raiden_dive` as `random_triple 000030079h`, a packed
>   `[count,first]` literal rather than a `tsound` line, and GIB5 was later
>   added to that same pool (`raiden_dive_yell_calls`, `src/MKPROP.ASM`). So
>   index `105` *was* dispatched, and so were `$79`/`$7A`/`$7B`. Once all four
>   slots were spent, Raiden's torpedo went silent half the time and shouted
>   "ERMAC WINS" or Kahn's "I WIN" the other half. **GIB1 and GIB3 have been
>   restored** (patch note 28) — they were only no-op'd, so deleting their
>   `End;` blocks brings the retail streams back, and the dive randomizes over
>   `$79`/`$7B` again. GIB2 and GIB5 cannot come back: those slots hold
>   ERMACWINS and KAHNIWIN, which stay where they are — `$02B1` and `$0320`
>   are genuinely unused space now that nothing dispatches `$7A` or `$105`.
>   Cost: 9,158 bytes, exactly the headroom note (25) bought; U7 finished with
>   5,550 bytes free and no phantom U8. `tools/sound_reach.py` has been taught
>   to resolve `.word` pools fed to `triple_sound`/`triple_sound2`, and to
>   honour `*`-in-column-1 comment lines, so this class of pool can no longer
>   read as dead audio.
> - `OLDRIP` (calls 208-210, alt take) is no longer unused: `ERMACSHOT.wav`
>   (205 frames/1574.4 ms) took the slot, and is now **wired** — it was staged
>   unwired for one revision, then claimed by the move it was staged for.
>   Ermac's fireball (Down,Back + LP, `do_ermac_zap` in MKZAP.ASM) fires it as
>   `tsound 10dh`, a new `triple_sndtab` entry `sp_effect|85,0d0h`, replacing
>   the `tsound 06ah` (subzero throw ice) it had borrowed as a stand-in. The
>   table route, not a raw `$00D0` send, because a combat SFX wants the three-
>   channel arbitration; duration 85 is the clip's 1567 ms in 18.4 ms game
>   ticks per the `$5B` unit warning. Wiring it turned up one more stale row of
>   the `SWRDSCRP` kind, in the other direction: `triple_sndtab` index `$BA`
>   ("loud rip sound") **already pointed at call `0d0h`**. Nothing dispatches
>   `$BA` — which is exactly why the analyzer read the triple as dead and it
>   was safe to restage — but the row is still there, now labelled for a clip
>   that is no longer a rip. Both rows carry a note about the other. `GOODBOD1` (145-147, also an alt take,
>   3,236 B) was no-op'd alongside it to leave a working cushion, and stays
>   no-op'd.
> - ⚠️ **`SWRDSCRP` (calls 366-368) is LIVE and its row above was stale.** It is
>   now the Shang decap laugh scrape (`triple_sndtab` index 109, `$016E`). It
>   was the obvious pick by size when hunting a slot for `ERMACSHOT` and would
>   have silently broken that fatality's audio. This is the note-(21) trap
>   inverted — there a dead clip had a live-*looking* table entry; here the
>   census said "unused" about a clip that had since been wired. **Always
>   re-run `tools/sound_reach.py` and treat its UNREACHED list as
>   authoritative; this table is a snapshot and can go stale in either
>   direction.**
> - `GORGRWL2` (calls 1203-1205, 10,256 B) was a **false positive** in every
>   previous run of the analyzer: it is live, sent from `BGND.ASM:1880` as
>   `tsound arena_goro_growl_snd` (Goro's one intimidating growl as he starts
>   his arena walk-in). The scan only understood hex literals, so any sound
>   dispatched through a `.set` equate looked dead — and at 10,256 bytes this
>   was the single largest apparent block of free space in the ROM, i.e. the
>   one most likely to be repurposed, which would have silently killed the
>   growl. `tools/sound_reach.py` now builds an equate table from the source
>   and resolves symbolic operands for `tsound`/`tsound2`, the `,a0`
>   table-index sends, and the `,a3` direct sends. A sweep confirmed GORGRWL2
>   was the **only** sound hidden this way. The same fix made the old
>   hard-coded `mm_sound`/`ms_sound` (KOTOA/KOTOB) special case unnecessary,
>   and it has been removed.
>
>   **Corrected totals: 35 files / 123,212 bytes unused** (the 47 files /
>   160,798 bytes in the opening paragraph and the inventory table below are
>   the original survey and have not been restated per-row; re-run the
>   analyzer for current numbers). Of that, only ~67 KB is actually
>   *available*: roughly 43 KB has already been spent by
>   `sound/stlaugh_patch.txt` (no-op'd or replaced) and is already reflected
>   in chip usage, and `ACID` (12,644 B) is reserved. Live chip headroom after
>   the KAHNIWIN patch is 3,798 bytes aggregate but only ~3,472 usable, since
>   a stream needs contiguous room inside one chip (see reclaim note (9) in
>   the patch script).

- Analysis script: `tools/sound_reach.py` (re-run with `python tools/sound_reach.py`)
- MP3 previews of all 58: **`sound/unused_mp3/`** (converted from the
  uncompressed `sound/SNDS/*.SND` masters — full source quality, not DCS-decoded)

## How "unused" was determined

The script extracts every reachable sound call from the TMS34010 source:
`tsound`/`tsound2` macro literals, `triple_sndtab`/`triple_sndtab2` computed
dispatch (random ranges, per-character packed voice banks, `hit_or_blocked_sound`
+1 offsets, the ice-slip voice cycle, `randsnd`/`randsnd2` pairs), animation-script
`ani_sound` opcodes, data tables (`winner_speech`, Kahn taunts, round announce,
select-screen name speech, cursor sounds, per-stage tune tables), and direct
`send_code_a3` immediates. It maps those to the 1,188 sound calls defined in
`sound/MK2.PLS` SOUNDCALLS, then flags any `.CMP` audio file whose *every*
referencing playlist is unreachable.

**Confidence:** high but not absolute. Rows marked *uncertain* could plausibly
be triggered via animation-data paths the static scan can't fully see
(sound opcodes embedded in LOAD2-side graphics tables). Definitive proof
requires runtime tracing (MAME Lua logging sound-port writes over a full
playthrough). Rows marked *known-10* match the externally documented
cut-content list. Everything can still be played manually via the operator
diagnostics sound test, or with `DCSExplorer.exe` against the sound ROMs.

> - **CORRECTION (2026-09-04): the retail ROM DOES carry a standalone "WINS"
>   suffix stream, and standalone "Smoke" and "Jade" name streams.** Note (24)
>   in `sound/stlaugh_patch.txt` asserted the opposite ("every retail win line
>   is a single baked `<NAME> WINS` phrase") and paid for it: `GIB1`/`GIB3`
>   were no-op'd to fund a copy of the suffix that was already in the ROM.
>   Dump the set with `DCSExplorer --programs` and every retail win line —
>   `$038D`, `$0390`, `$0399`, `$03A5`, `$03A8`, `$03AB` … — is a two-`Play()`
>   chain onto the SHARED suffix stream `$17EBEC`, with the name stream in
>   front of it. `$03A8` and `$03AB` therefore prove that "Smoke" (`$1754D4`,
>   119 frames) and "Jade" (`$331480`, 119 frames) exist as name-only streams,
>   even though retail has no name-only TRACK for either.
>   Acted on: `NOOBWINS`/`ERMACWINS` were re-split so their streams carry the
>   NAME ONLY (`NOOBNAME.wav`/`ERMACNAME.wav`, cut from the shipped clips at
>   their splice points) and the win tracks chain `$17EBEC` behind them. That
>   removed ~2.0 s of duplicated suffix audio and took usable headroom from
>   3,182 bytes to 13,996.
> - `VPTRIP` (859-861), `VPTHROW` (865-867), `VPATTAK1` (850-852) and
>   `VPWAST1` (877-879) are no longer merely reclaimed: those four now-empty
>   track triples carry the **select-screen name calls for the four hidden
>   fighters** (`triple_sndtab2` $5D-$60, dispatched by MKSEL.ASM's
>   `psel_hidden_pick`). Their original audio stays dropped — only the track
>   numbers were reused, so none of the earlier space reclaim is given back,
>   and Smoke's and Jade's lines add no audio at all because they play the
>   retail streams above.

## Inventory (sorted by compressed size)

| File (SNDS/) | .CMP bytes | Length | Sound calls | Description | Notes |
|---|---|---|---|---|---|
| ACID | 12,644 | 2.80 s | 268-270 | acid sizzle | **RESERVED - planned for future use, do not repurpose** |
| BIGFALL1 | 7,352 | 0.95 s | 178-180 | Big Fall #1 | **REUSED** - now ScorpFall (note 18; `triple_sndtab` $10C plus raw `$00B2`) |
| BODINFLT | 6,920 | 0.84 s | 1026-1028 | Death: Kitana - Body inflates | **RECLAIMED then REUSED** - no-op'd for space (note 12); track numbers now Shao Kahn's "RUN, COWARD" (`KAHNCOWARD.wav`, note 58, `triple_sndtab2` $63, MKBOSS.ASM) |
| KISS2 | 6,836 | 0.85 s | 1023-1025 | Death: Kitana - Kiss #2 | **REUSED** - known-10 cut, now ScorpFat2 (note 19; raw `$03FF`, MKFX.ASM `scorpion_flame`) |
| VPDEATH | 6,664 | 2.29 s | 883-885 | Vince: death | **RECLAIMED then REUSED** - no-op'd in note 38, slot now FROSTY (note 57; `triple_sndtab` $102, `tsound 0102h` in PONG.ASM/BGND.ASM) |
| JHFELCH | 6,640 | 2.98 s | 803-805 | JH: hmmmm | **RECLAIMED then REUSED** - known-10 cut, no-op'd for space (note 17b); slot now FLYBRAIN + "wins" (note 50, `triple_sndtab2` $61, MAIN.ASM). Protect $0323-$0325 |
| REPTPOOF | 6,440 | 1.15 s | 280-282 | Reptile and other's magical poof | **REUSED** - GoroStandby's freed slot now carries the MK1 throne room applause (note 56, `triple_sndtab2` $68, MK1THRN.ASM `mk1t_shang`) |
| GIB5 | 5,704 | 1.60 s | 800-802 | JH: gibberish #5 | **REPURPOSED** - now Shao Kahn's "I WIN" (`KAHNIWIN.wav`); `triple_sndtab` index 105 *was* dispatched, via the Raiden torpedo pool - see the 2026-09-04 correction |
| GIB2 | 5,306 | 1.44 s | 689-691 | JH: gibberish #2 | **REPURPOSED** - now Ermac's victory line (`ERMACWINS.wav`); was `triple_sndtab` $7A and live in the Raiden torpedo pool - see the 2026-09-04 correction |
| GIB1 | 5,166 | 1.34 s | 686-688 | JH: gibberish #1 | **RESTORED** (note 28) - `triple_sndtab` $79, live again in the Raiden torpedo pool |
| COINDROP | 4,728 | 0.78 s | 187-189 | coin drop | **RECLAIMED** (note 31) - only table row is `triple_sndtab` f9, never sent |
| SKB1L | 4,708 | 0.62 s | 1380-1382, 1395 | Shao Kahn: destruction rumble #2 | **RECLAIMED then REUSED** - no-op'd in note 34, slot now JadeZap (note 37; raw `$0564`, MKREACT.ASM) |
| SWRDSCRP | 4,414 | 0.82 s | 366-368 | Edward: sword scrape | ⚠️ **NO LONGER UNUSED** - now live as the Shang decap laugh scrape (`triple_sndtab` index 109, $016E); this row was stale and nearly cost a repurpose |
| MUNCH | 4,182 | 0.54 s | 250-252 | Liu Kang: dragon bites in half | **LIVE** - `tsound 0103h` (MKDEATH.ASM, the bite) |
| GIB3 | 3,992 | 1.18 s | 692-694 | JH: gibberish #3 | **RESTORED** (note 28) - `triple_sndtab` $7B, live again in the Raiden torpedo pool |
| SPLISH3 | 3,960 | 0.71 s | 521-523 | Splish #3 | **LIVE** (re-audit 2026-10-06) - `triple_sndtab` $75: blood splish pool, Dead Pool bubble pop, Noob shadow moves. ⚠️ table duration 20 ticks vs 38.9-tick clip, so later sounds can cut it off |
| VPWAST2 | 3,818 | 1.11 s | 880-882 | Vince: wast #2 | **RECLAIMED then REUSED** - no-op'd for space (note 12), track numbers now Khameleon's win line (`KHAMNAME.wav`, note 32) |
| RIPARMS | 3,766 | 0.55 s | 256-258 | Jax: rip arms off | **RECLAIMED** (note 34) - no-op'd for the Khameleon win line / Kahn taunt; any table row is flagged DO NOT USE in MKSOUND.ASM |
| OLDRIP | 3,430 | 0.49 s | 208-210 | old rip | **LIVE** - replaced by `ERMACSHOT.wav` and wired to Ermac's fireball (`triple_sndtab` $10D, `do_ermac_zap`); do not repurpose |
| GOODBOD1 | 3,236 | 0.47 s | 145-147 | Body hit #3 | **RECLAIMED** - alt take, no-op'd to give the staged `ERMACSHOT` slot a cushion |
| LILSTAB1 | 3,228 | 0.49 s | 438-440, 447 | Baraka: little stab #1 | **LIVE** - `triple_sndtab` $A0, Baraka's shred cycle (`sounds_of_shred`) |
| LILSTAB3 | 3,032 | 0.46 s | 444-447 | Baraka: little stab #3 | **LIVE** - `triple_sndtab` $A2, Baraka's shred cycle (`sounds_of_shred`) |
| SKREACT4 | 2,876 | 0.91 s | 1265-1267 | Shao Kahn: react #4 | **RECLAIMED** (note 34) - no-op'd for the Khameleon win line / Kahn taunt; any table row is flagged DO NOT USE in MKSOUND.ASM |
| LILSTAB2 | 2,802 | 0.41 s | 441-443, 447 | Baraka: little stab #2 | **LIVE** - `triple_sndtab` $A1, Baraka's shred cycle (`sounds_of_shred`) |
| VPWAST1 | 2,640 | 0.81 s | 877-879 | Vince: wast #1 | **RECLAIMED then REUSED** - no-op'd for space, now the select-screen "Ermac" name track (`ERMACNAME.wav`) |
| SPLISH1 | 2,388 | 0.32 s | 515-517 | Splish #1 | **LIVE** (re-audit 2026-10-06) - `triple_sndtab` $73: blood splish pool, Dead Pool surface breach, Noob shadow moves |
| SKREACT3 | 2,354 | 0.71 s | 1262-1264 | Shao Kahn: react #3 | **RECLAIMED** (note 34) - no-op'd for the Khameleon win line / Kahn taunt; any table row is flagged DO NOT USE in MKSOUND.ASM |
| DTHUN2 | 2,274 | 0.89 s | 566-568 | Distant Thunder #2 | **NOT UNUSED — RESTORED** (note 29): `triple_sndtab2` index 3 is dispatched by `peak_thunder` on Mountain Top; see the 2026-09-06 correction |
| VPTHROW | 2,186 | 0.76 s | 865-867 | Vince: throw | **RECLAIMED then REUSED** - no-op'd for space, now the select-screen "Jade" name track (plays the RETAIL `$331480` stream; no new audio) |
| DFYEA | 2,184 | 0.71 s | 642-644 | DF: Yeah! | **REUSED** - `triple_sndtab` $FE (`tsound 00feh`, MKDEATH.ASM) now plays MK1's Cage headhole "Yeah" (`MK1_CAGEHEADHOLE_YEAH.wav`) |
| LKSPIKED | 2,086 | 0.61 s | 765-767 | Liu Kang: spiked | **RECLAIMED then REUSED** - no-op'd in note 34, track numbers now the SUDDEN DEATH tie line (`SUDDENDEATH.wav`, note 38) |
| SPLISH2 | 2,004 | 0.26 s | 518-520 | Splish #2 | **LIVE** (re-audit 2026-10-06) - `triple_sndtab` $74: blood splish pool, Dead Pool drip landing, Noob shadow moves |
| MILESPIT | 1,786 | 0.59 s | 181-183 | Mileena spits bones | **RECLAIMED** (note 38) - `triple_sndtab` ca never sent; row flagged DO NOT USE |
| KOTOE2 | 1,684 | 0.34 s | 554-556 | Cursor: high E | **RECLAIMED** (note 31) - abandoned koto cursor scheme; KOTOA/KOTOB (545/548) stay live as the test-menu beeps |
| SKREACT1 | 1,670 | 0.48 s | 1256-1258 | Shao Kahn: react #1 | **RECLAIMED** (note 34) - no-op'd for the Khameleon win line / Kahn taunt; any table row is flagged DO NOT USE in MKSOUND.ASM |
| VPREACT3 | 1,620 | 0.55 s | 874-876 | Vince: react #3 | **REUSED** - ch1 ($036A) plays JadeNitroKick (raw, MOVES.ASM); ch2/ch3 no-op'd (note 13) |
| KOTOD2 | 1,514 | 0.30 s | 551-553 | Cursor: high D | **RECLAIMED** (note 31) - abandoned koto cursor scheme; KOTOA/KOTOB (545/548) stay live as the test-menu beeps |
| KOTOE1 | 1,434 | 0.36 s | 542-544 | Cursor: low E | **RECLAIMED then REUSED** (note 31) - track numbers now the "DRAW" announcer line (note 52, `triple_sndtab2` $67, MAIN.ASM) |
| VPTRIP | 1,338 | 0.55 s | 859-861 | Vince: trip | **RECLAIMED then REUSED** - no-op'd for space, now the select-screen "Smoke" name track (plays the RETAIL `$1754D4` stream; no new audio) |
| KOTOFS | 1,332 | 0.32 s | 557-559 | Cursor: F# | **RECLAIMED** (note 31) - abandoned koto cursor scheme; KOTOA/KOTOB (545/548) stay live as the test-menu beeps |
| TNGUESTK | 1,324 | 0.25 s | 1041-1043 | Death: Reptile - tongue sticks | **RECLAIMED** (note 34) - no-op'd for the Khameleon win line / Kahn taunt; any table row is flagged DO NOT USE in MKSOUND.ASM |
| VPATTAK1 | 1,320 | 0.48 s | 850-852 | Vince: attack #1 | **RECLAIMED then REUSED** - no-op'd for space, now the select-screen "Noob Saibot" name track (`NOOBNAME.wav`) |
| KOTOCS | 1,276 | 0.28 s | 560-562 | Cursor: C# | **RECLAIMED** (note 31) - abandoned koto cursor scheme; KOTOA/KOTOB (545/548) stay live as the test-menu beeps |
| SKREACT2 | 1,208 | 0.57 s | 1259-1261 | Shao Kahn: react #2 | **RECLAIMED** (note 34) - no-op'd for the Khameleon win line / Kahn taunt; any table row is flagged DO NOT USE in MKSOUND.ASM |
| VPREACT2 | 1,196 | 0.46 s | 871-873 | Vince: react #2 | **REUSED** - ch2 ($0368) plays JadeBoomWhoosh (raw, MKZAP.ASM); ch1/ch3 no-op'd (note 13) |
| VPATTAK2 | 1,182 | 0.47 s | 853-855 | Vince: attack #2 | **LIVE** - known-10 cut, wired as the Cage headhole windup grunt (`triple_sndtab` $108, `tsound 0108h`) |
| VPREACT1 | 954 | 0.44 s | 868-870 | Vince: react #1 | **REUSED** - track numbers now "Rain wins" (`triple_sndtab2` $65, `winner_speech` entry 19) |

**Total: 160,798 bytes** (out of ~3 MB total audio).

Note: `GORGRWL2`, `JAXYEAH`, `CAGEKISS`, and `JAXAHH` have all been wired to
game code since the previous revision of this doc (Jax's and Cage's victory
poses, and Jax's throw voice respectively) and are no longer unused — see the
correction history above.

Families: *VP scratch bank* = Vince Pontarelli (sound designer) placeholder
voice recordings; as of the 2026-10-06 re-audit **none of the 12 clips at
calls 850-885 is free any more** — `VPATTAK2` is live as retail audio and the
other 11 slots are either reused (`VPGRAB`, `VPJUMP`, `VPDEATH` → FROSTY,
the four hidden-fighter names, Khameleon/Rain wins, the Jade UMK3 sounds) or
no-op'd for space. *JH* =
Jon Hey, ditto — but that bank is now spent: `GIB5` and `GIB2` were reassigned
to the Shao Kahn and Ermac victory lines, and `GIB1`/`GIB3` are back in
service as Raiden's torpedo yell (they were briefly no-op'd; see the 2026-09-04
correction), so nothing is left to reclaim at calls 686-694. *koto cursor scheme* = koto-scale notes for an abandoned
musical select-screen cursor — notably, two of the eight notes (A and B)
shipped as the operator test-menu beeps, so the scheme wasn't fully abandoned,
just demoted to diagnostics. *alt take* = alternate recordings of effects
where the game only wired takes #1/#2.

Unused in gameplay but reachable from operator diagnostics (not counted in
the total above): ARC1/ARC2/ARC3 (Raiden arcing), DFATAK1/DFATAK2 (Dan Forden
attack), KOTOA (test-menu move beep, `mm_sound`), KOTOB (test-menu select
beep, `ms_sound`).

## Free space and reclaim candidates (2026-09-20)

> **DONE 2026-09-20.** The friendship audio below has been RECLAIMED: 13 tracks
> no-op'd in `sound/stlaugh_patch.txt` note (46), freeing 6 streams and 60,108
> bytes. The build now has **83,080 bytes free** (U7 alone holds 82,822).
> Verified after building: all 13 tracks are bare `End;`, both keepers still
> play, and the stream count went 416 -> 410. The sections below are kept as
> the reasoning and the method; the candidate tables are now a record of what
> was taken, not a to-do list.
>
> **Latent trap this creates.** `$0063`'s only sender is the tune script
> `fast_fade_music` (`MKSOUND.ASM:1141`), which nothing references — that is
> *why* it was reclaimable. The script is still in the ROM and is a plausible
> thing to wire up later: a ready-made fast music fade ramping
> `061h/063h/065h/067h/069h` against drum steps `021h-029h`. If anyone does,
> the `063h` step will hit a no-op'd track and the ramp will have a hole in it
> — audible as an uneven fade, and very hard to debug, because the source will
> look correct. Re-point that step before using `fast_fade_music`.

Measured, not estimated: chip figures come from a DCSEncoder `--patch` build of
the current `sound/stlaugh_patch.txt`, stream sizes from
`DCSExplorer -I --info --terse -s` on the built set.

### Free space in the current build

| Chip | Used | Free |
|---|---:|---:|
| U2 | 524,242 | 46 |
| U3 | 524,226 | 62 |
| U4 | 524,246 | 42 |
| U5 | 524,268 | 20 |
| U6 | 524,256 | 32 |
| U7 | 501,740 | **22,548** |
| | | **22,750 total** |

Practically all of it is in U7; the other chips are packed. Retail baseline for
comparison was 7,856 bytes free, so custom audio has been paying for itself
through reclaims rather than eating the headroom.

### Ready for overwrite — friendship audio

`mk2-main-05` removed the friendships on 2026-09-20 (code plus 211 art
records), orphaning their audio. Nothing in the ROM can reach these now.
**Nothing here has been reclaimed yet** — it is all still in the build.

| Tracks to no-op | What it is | Frees |
|---|---|---:|
| `$003a` | friendship tune (raw `03ah`) | 20,907 |
| `$003e` | friendship tune (raw `03eh`) | 10,526 |
| `$0329` + `$032a` + `$032b` | KIDD THUNDER sting, Raiden friendship (`tsound 0d5h`) | 5,653 |
| `$03cf` + `$03d0` + `$03d1` | Shao Kahn "FRIENDSHIP" (`tsound2 058h`) | 3,819 |
| `$044c` + `$044d` + `$044e` | Shao Kahn "FRIENDSHIP?" (`tsound2 059h`) | 3,147 |
| | **total** | **44,052 (43.0 KB)** |

Taking all of it would put the build near 66 KB free.

**Plus `$003b` + `$0063`, 16,056 bytes — resolved 2026-09-20, also reclaimable.**
`$003b` (friendship tune, raw `03bh`) shares stream `$21872A` with `$0063`,
which loops that same stream forever. No-opping `$003b` alone frees nothing;
**both** tracks have to go, and both are dead:

* Port side (mk2-main-ef): the only sender of `063h` in the tree is
  `.byte send,063h` inside the tune script `fast_fade_music`
  (`MKSOUND.ASM:1146`), and nothing references `fast_fade_music`. Tune scripts
  are only reached when a table entry's priority word is negative, and both
  tables have zero such entries, so `triple_tune` is never taken. No
  `send_code_a3` sends `063h` either.
* Track side (this side, and the check the port-side scan cannot make): a DCS
  track can invoke another track from inside its own program, so "the game
  never sends it" is not enough. In this build it cannot happen — there are
  **no `Queue` opcodes at all**, the deferred-indirect tables are empty
  (`--ditables` reports "None"), and the only cross-track mechanism present is
  `Defer`, with exactly two targets in the whole ROM: `$0033` and `$0037`.
  Neither is `$0063`, and neither is any candidate above.

**So the full reclaim is 60,108 bytes (58.7 KB)**, which would leave the build
with roughly 81 KB free.

### Do NOT reclaim these

| Track | Why it survives |
|---|---|
| `$0239` (+ `$023a`, `$023b`), 11,780 B | "lightning strike". Fired from `kidd_thunder_proc`, so it reads as friendship-only audio — but `MKCANNED.ASM:581` and `MKFX.ASM:506` still fire it for Raiden's zap. This is the entry most likely to be reclaimed by mistake. |
| `$003f`, 11,349 B | "TUNE babality/friendship over". `death_blow_complete` still sends it for fatalities and babalities. |

`raw 37h` and `3dh` are dead as well, but were dead before the friendship
removal — don't credit them to it.

**One place a reclaimed track is still reachable by a human:** the operator
sound test in the diagnostics menu can request arbitrary track numbers, so
anything reclaimed auditions there as silence or garbage. That is already true
of every reclaim made to date and is not a reason to hold back — just the one
symptom an operator can produce on purpose.

**A fifth dispatch path was checked and is clean** (mk2-main-ef, 2026-09-20):
code that writes the sound port directly, bypassing `send_code_a3`
(`MKINIT.ASM:90/94`, `DIAGMENU.ASM:1525/1529`, `DIAGPRNT`, `MKSOUND.ASM:1436`).
Every one of those writes is control-plane — `0FE00h` reset, `0FF00h` interrupt
strobe, `0FFFFh` release, `0FD00h` musicbit — high-byte control values, not
track codes. Nothing computes or sends a candidate code.

### Three traps in this analysis

1. **FOUR dispatch paths, same numbers.** A number means nothing until you know
   which path carries it:
   | Path | What the number is |
   |---|---|
   | `send_code_a3` (`movi N,a3`) | RAW code written to the sound port |
   | `tsound N` | index into `triple_sndtab` (`MKSOUND.ASM:121`) |
   | `tsound2 N` | index into `triple_sndtab2` (`MKSOUND.ASM:529`) |
   | `.byte send,N` | RAW code sent from a tune script |
   A table entry is one `.word pri|dur , track` pair — the second word is the
   track. So `tsound 03ah` (Kang's "Oooooo") and raw `03ah` (a friendship tune)
   are unrelated sounds. An earlier pass called three codes live off a `tsound`
   grep and had to retract it; a later pass missed the tune-script path
   entirely. Check all four.
2. **Channel siblings share one stream.** A cue's channel-1/2/3 tracks point at
   the same stream, so the bytes come back only when *all* of them stop
   referencing it — hence the grouped rows above.
3. **Streams can be shared across unrelated cues**, as `$003b`/`$0063` are.
   Check the reference count before counting any stream as reclaimable.

## Reusing these slots for new audio

The proven pipeline (see `doc/STLAUGH_SHANG_VICTORY.md`):

1. Replace the tracks with DCSEncoder `--patch` against the retail zip
   (`sound/stlaugh_patch.txt` is the template). Patch mode keeps every stream
   that is still referenced by an unpatched track, so **unused audio stays in
   the ROM until you deliberately replace its tracks** — nothing is lost by
   accident.
2. Trigger from game code via a new `triple_sndtab`/`triple_sndtab2` entry
   (channel-1 call code; dispatch adds +1/+2 for channels 2/3).
3. Never route new audio through PLBUILD/`.CMP` — see the warning in the
   STLAUGH doc.

Do **not** reuse these reserved slots: ACID (calls 268-270, planned content)
or REPTPOOF (280-282, `GORO_STANDBY` staged). The four VP triples marked
**REUSED** below are also taken now (hidden-fighter select-screen names). OLDRIP (208-210) is no longer
merely reserved — `ERMACSHOT` is live on it, fired by Ermac's fireball.

And do **not** pick a slot from the table above without re-running
`tools/sound_reach.py` first — see the `SWRDSCRP` warning in the correction
history.
