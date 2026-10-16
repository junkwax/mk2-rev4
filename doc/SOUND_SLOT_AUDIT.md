# MK2 sound slot audit

**Audited 2026-09-06** against `sound/mk2_stlaugh.zip` as built, not against the
patch notes. Companion to `doc/UNUSED_AUDIO.md`: that file is a *census* of
retail audio nothing can reach; this one is a *ledger* of what
`sound/stlaugh_patch.txt` actually did to the ROM and whether every slot it
touched lines up with the game code that dispatches it.

Durable identifiers here are the hex call codes. Stream addresses move on every
re-encode and are quoted only as evidence of one specific build.

> Regenerating the evidence:
>
> ```
> DCSExplorer.exe -I --info --terse -p mk2.zip                > retail.txt
> DCSExplorer.exe -I --info --terse -p sound/mk2_stlaugh.zip  > patched.txt
> python tools/sound_reach.py
> ```
>
> then diff the two dumps track by track and cross-reference the changed set
> against every `track` block in `sound/stlaugh_patch.txt`. The two sets must
> be *identical* — see "Verification chain" below.

---

## Headline

| | |
|---|---|
| Tracks changed vs retail | **67** — exactly the 67 the patch declares |
| Unexplained ROM changes | **0** |
| Chips used | **6** (U2–U7), no phantom U8 |
| Reclaimed slots with a live dispatcher | **0** (was 1 — DTHUN2, fixed in note 29) |
| Occupied call codes `sound_reach.py` reports as free | **12** — see "Analyzer blind spots" |

Two incidents of the same shape have now been found and fixed, in opposite
directions:

- **Raiden's torpedo yell** (fixed 2026-09-04, patch note 28) — audio was
  reclaimed out from under code that already dispatched it.
- **Mountain Top's distant thunder** (fixed 2026-09-06, patch note 29) — code
  was newly pointed at audio that had already been reclaimed.

Neither is visible to `tools/sound_reach.py`. Both are the reason for the rule
at the bottom of this document.

---

## Verification chain

What was actually checked. Retail baseline is `mk2-main/mk2.zip`.

- ✅ **Exactly 67 track programs differ from retail**, and that set is identical
  to the 67 `track` blocks the patch declares. 0 changed-but-not-declared,
  0 declared-but-not-changed.
- ✅ **GIB1/GIB3 fully restored.** `$02AE`–`$02B0` and `$02B4`–`$02B6` carry
  retail level 104 and retail `Wait(174)`/`Wait(153)`; only the stream
  addresses moved as the packer relaid the ROM.
- ✅ **DTHUN2 fully restored.** `$0236`–`$0238` carry retail level 105, the
  channel-0 duck of 20, `Wait(80)`, the 38-step restore and `Wait(36) End;` —
  the same 890.88 ms program as retail.
- ✅ **The installed MAME set is the patched audio.** All six sound chips match
  `mk2_stlaugh.zip` byte for byte except 4 bytes at `0x7FFFC` on each — the
  deliberate FBNeo CRC spoof (`crc_spoof.py`), outside the DCS data area. Side
  effect: DCSExplorer reports a U2 checksum warning. Expected.
- ✅ **No reclaimed slot has a raw caller.** Every `movi <code>,a3` feeding
  `send_code_a3` was enumerated; none targets a no-op'd track.
- ✅ **No reclaimed slot has a live table caller.** Of the 20 remaining no-op'd
  tracks, none has a `triple_sndtab`/`tab2` row pointing at it. (Before note
  29 exactly one did: index 3 → `$0236`.)

---

## Custom audio — what plays

Thirteen source clips over 41 track slots. Channel copies marked *dead* cost
only track-program bytes: the encoder deduplicates the stream, so all three
tracks in a family point at one address.

| Slots | Sound | Displaced | Trigger | Status |
|---|---|---|---|---|
| `$02E9`–`$02EB` | STLAUGH | GEXPLODE | Shang victory pose — `MKCANNED.ASM st_victory`, tab `$FF` | live ×3 |
| `$0046`–`$0048` | NOOBNAME + retail "wins" (`$17EBEC`) | JETFX | Round-end winner speech — tab2 `$5A`, `winner_speech` `ft_noob` | live ×3 |
| `$02B1`–`$02B3` | ERMACNAME + retail "wins" | GIB2 | Round-end winner speech — tab2 `$5C`, `ft_ermac` | live ×3 |
| `$0320`–`$0322` | KAHNIWIN | GIB5 | Round-end winner speech — tab2 `$5B`, `ft_final_boss` (gate narrowed in `MAIN.ASM`) | live ×3 |
| `$00D0`–`$00D2` | ERMACSHOT | OLDRIP | Ermac fireball D,B+LP — tab `$10D`, `tsound 10dh` in `do_ermac_zap` | live ×3 |
| `$00B2`–`$00B4` | SCORPFALL | BIGFALL1 | Toasty skeleton collapse (raw `$00B2` in `mk1_burnt_skeleton`) and Shang soul-suck husk (tab `$10C`) | live ×3 |
| `$0282`–`$0284` | CAGEHEADHOLE_YEAH | DFYEA | Cage headhole fatality death blow — `tsound 00feh`, `MKDEATH jc_headhole_pairs` | live ×3 |
| `$0352`–`$0354` | NOOBNAME (select name) | VPATTAK1 *(already reclaimed)* | Hidden-fighter pick — tab2 `$5F`, `psel_hidden_pick` | live ×3 |
| `$036D`–`$036F` | ERMACNAME (select name) | VPWAST1 *(already reclaimed)* | Hidden-fighter pick — tab2 `$60` | live ×3 |
| `$0358` | JADEINV | VPJUMP | Jade Flash shimmer — raw ch1, `MKZAP do_jade_flash_test` | live; `$0359`/`$035A` dead |
| `$035E` | SUBNADOSTART | VPGRAB | Sub-Zero tornado start — raw ch1, `MOVES do_sz_tornado` | live; `$035F`/`$0360` dead |
| `$03FF` | SCORPFAT2 | KISS2 | Scorpion U,U+HP MK1 burn — raw ch1, `MKFX scorpion_flame` | live; `$0400`/`$0401` dead |
| `$0368` | JADEBOOMWHOOSH *(UMK3)* | VPREACT2 ch2 | Jade boomerang throw, layered — raw ch2; `jade_zap3` pinned to ch1 so it cannot collide | live |
| `$036A` | JADENITROKICK *(UMK3)* | VPREACT3 ch1 | Jade Nitro Kick D,F+LK — raw ch1, `MOVES do_fn1_nitro` | live |
| `$0118`–`$011A` | GORO_STANDBY | REPTPOOF | — none — | **staged, unwired** |

`GORO_STANDBY` is the only custom clip holding ROM space with nothing to
trigger it. Deliberate per patch note (6) — reserved the way ACID is, until a
Goro use is decided.

### Retail streams reused — zero new audio

| Slots | Plays | Displaced | Trigger |
|---|---|---|---|
| `$035B`–`$035D` | `$1754D4` retail "Smoke" name | VPTRIP *(already reclaimed)* | Select-screen pick — tab2 `$5D` |
| `$0361`–`$0363` | `$331480` retail "Jade" name | VPTHROW *(already reclaimed)* | Select-screen pick — tab2 `$5E` |

Both exist because every retail "X WINS" line is `Play(<name>) + Play($17EBEC)`
rather than one baked phrase, so the name halves were already standalone
streams in the ROM.

---

## Reclaimed slots — audio dropped from the ROM

20 tracks redefined as a bare `End;`, which drops the backing stream. All are
recoverable by deleting the block and re-encoding — nothing here is destroyed,
only unreferenced. None currently has a dispatcher.

| Slots | Clip | Bytes | Freed for |
|---|---|---:|---|
| `$0037` | ENDGUY — End One player map music | 8,664 | note (5) · SUBNADOSTART |
| `$0402`–`$0404` | BODINFLT — Kitana body inflates | 6,920 | note (12) · Jade UMK3 pair |
| `$0323`–`$0325` | JHFELCH — JH: hmmmm | 6,640 | note (17b) · lasting headroom |
| `$0370`–`$0372` | VPWAST2 | 3,818 | note (12) · Jade UMK3 pair |
| `$0091`–`$0093` | GOODBOD1 — Body hit #3, alt take | 3,236 | note (27) · ErmacShot cushion |
| `$036B`, `$036C` | VPREACT3 ch2/ch3 — JadeNitroKick's dead siblings | ~1,620 | note (13) · loudness pass |
| `$0367`, `$0369` | VPREACT2 ch1/ch3 — JadeBoomWhoosh's dead siblings | ~1,196 | note (13) · loudness pass |
| `$0364`–`$0366` | VPREACT1 | 954 | note (9) · CageHeadholeYeah |

### Reversed, and staying reversed

| Slots | Clip | State | Why |
|---|---|---|---|
| `$0236`–`$0238` | DTHUN2 | **retail audio restored** | `peak_thunder` dispatches tab2 index 3 on Mountain Top (note 29) |
| `$02AE`–`$02B0` | GIB1 — tab `$79` | **retail audio restored** | Raiden torpedo yell, pool entry 1 of 2 (note 28) |
| `$02B4`–`$02B6` | GIB3 — tab `$7B` | **retail audio restored** | Raiden torpedo yell, pool entry 2 of 2 (note 28) |
| `$02B1`–`$02B3` | GIB2 — tab `$7A` | **gone for good** | Holds ERMACWINS. Row kept only so the table lines up; flagged DO NOT USE in `MKSOUND.ASM` |
| `$0320`–`$0322` | GIB5 — tab `$105` | **gone for good** | Holds KAHNIWIN. Removed from the torpedo pool |
| `$0429`–`$042B` | MILEBALL | **retail audio restored** | BarakaCoptr swap backed out; heliport uses the retail spin-ball again |

Raiden's dive now randomizes over two shouts instead of retail's three. That is
the permanent residue of the torpedo incident and the only player-audible
difference left from it.

---

## Analyzer blind spots

`tools/sound_reach.py` is authoritative for *literal* dispatches and nothing
else. Two classes of dispatch it cannot see have already caused bugs, and one
is still uncorrected in its output.

### 1. Still wrong today — the hidden-fighter select names

`psel_hidden_pick` (`src/MKSEL.ASM:1729`) loads a table index into `a1`;
`cmove9` carries it to `select_speech` as `a10` and on to `triple_sound2`.
There is no `tsound` literal anywhere, so all twelve calls are still reported
UNREACHED under their old Vince Pontarelli names. **They are live and
occupied.**

| Calls | Table | What actually plays | Analyzer says |
|---|---|---|---|
| `$0352`–`$0354` | tab2 `$5F` | "Noob Saibot" select name | UNREACHED (VPATTAK1) |
| `$035B`–`$035D` | tab2 `$5D` | "Smoke" select name | UNREACHED (VPTRIP) |
| `$0361`–`$0363` | tab2 `$5E` | "Jade" select name | UNREACHED (VPTHROW) |
| `$036D`–`$036F` | tab2 `$60` | "Ermac" select name | UNREACHED (VPWAST1) |

Worth fixing in the tool: either follow `movi <idx>,a1` in a routine whose
caller reaches `triple_sound2`, or — cheaper and more robust — seed an explicit
"known live, analyzer cannot see it" list the way `reach2.update(...)` already
does for the cursor and grow-message sites.

### 2. Fixed, but keep in mind

- **`.word` pools fed to `triple_sound`** (the Raiden torpedo). The tool now
  resolves these, and honours `*`-in-column-1 comment lines.
- **Computed indices** (`randu` arithmetic, `addi` chains). Not modelled and
  probably not worth modelling. `peak_thunder`'s 2-or-3 draw is the known
  instance; it is why DTHUN2 read as dead while it was being played.

---

## ROM budget

As built, from DCSEncoder's own layout report:

| Chip | Bytes used | Unused |
|---|---:|---:|
| U2 | 524,246 | 42 |
| U3 | 524,226 | 62 |
| U4 | 524,246 | 42 |
| U5 | 524,256 | 32 |
| U6 | 524,054 | 234 |
| U7 | 520,762 | 3,526 |

Six chips, no phantom U8. Effectively all the slack lives on U7. Retail carried
439 streams; the patched set carries 429.

If more room is needed, the analyzer's confirmed-dead list still holds clean
untouched triples — SKB1L (4,708 B), COINDROP (4,728 B), GBIGSLIP (4,014 B),
RIPARMS (3,766 B). ACID is the biggest at 12,644 B but is reserved for planned
content. Watch `makesound.py`'s phantom-U8 guard on every re-encode.

---

## Build traps

- **`sound/U2.ROM`–`U7.ROM` contain none of the custom audio.** They are
  DOS-toolchain output dated April/July and predate every custom sound. The
  normal path is safe — `mamerom.py` defaults to `mk2_stlaugh.zip`, and even an
  explicit `mk2.zip` argument is overridden unless you pass
  `--allow-retail-sound`. But `--full-source-sound` still reads these stale
  chips, and the result is *worse* than plain retail: the game code would
  dispatch the new `triple_sndtab2` rows onto slots that still hold GIB2
  gibberish and the Vince scratch takes.
- **Nothing but `makesound.py` regenerates `mk2_stlaugh.zip`.** `build.py`,
  `makerom.py` and `makevrom.py` do not touch it. `makesound.py --check` and
  `mamerom.py`'s own staleness warning both catch a forgotten re-encode.
- **`mk2_audio_review/` in the DCSExplorer repo is a snapshot, not a source of
  truth.** It goes stale the moment `stlaugh_patch.txt` changes.

---

## The rule both incidents produce

A no-op reclaim is safe only for as long as nothing *new* starts dispatching
its table index. The analyzer proves the slot is dead *today*; it cannot
promise the slot stays dead, and it does not re-run itself when someone adds a
stage.

**When adding a stage, move or effect that sends a `triple_sndtab` / `tab2`
index, check that index against the no-op'd slots in `sound/stlaugh_patch.txt`
— not just against `tools/sound_reach.py`.** The no-op'd list is short and
lives in one file; the analyzer's blind spots do not.

And in the other direction, before reclaiming a slot: re-run the analyzer, then
check its verdict against this document's live-slot tables, because twelve of
the calls it lists as free are not.
