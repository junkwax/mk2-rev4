# Friendships removed (2026-09-20)

Every friendship is gone from the ROM — the nine finisher sequences, the
input patterns that reach them, the drone's and the fruit fly's routes into
them, the win-medal tally that counted them, and all 211 sprite records of
art. This is a deletion, not a compile-time switch: there is no `friendship`
equate to turn back on.

Reclaimed **199,386 bytes of bank-1 video ROM**, the largest single reclaim in
this tree. See `doc/ASSET_SPACE_LEDGER.md` under 2026-09-20 for the space
tables and the exact freed ranges.

## What a player sees

- No friendship. The nine input patterns (Kung Lao's rabbit-from-the-hat, Liu
  Kang's disco dance, Cage's autograph, Baraka's gift, Kitana's cake,
  Mileena's plant, Shang's rainbow, Raiden's KIDD THUNDER, the ninjas' doll
  advert, Jax's flex) do nothing. They fall through to the ordinary kick the
  button would have thrown.
- The babality is untouched. It was the other half of the same "no HP or LP
  thrown this round" gate and is unaffected.
- The win-medal row no longer has a smile. A round won with a fatality still
  wears a skull; every other win is a plain medal.
- The ending's rumour screen no longer offers `FRIENDSHIP ?` as a clue.
- The CPU's non-violent finish is now always a babality. It used to flip a
  coin between the two.

## Code removed

| file | what went |
|---|---|
| `src/MKFRIEND.ASM` | **deleted** (1,084 lines) — `fs_check`, `do_friendship`, `friendship_start/end`, all nine sequences, `start_bounce` + `friendship_letters`, the nine `scom_*_friend` patterns, `ochar_friendship_combos`, `friendship_jumps` |
| `src/MKFRIEND.TBL` | **deleted** — 179 sprite records |
| `src/MKFRND2.TBL` | **deleted** — 32 sprite records |
| `src/MAKEFILE`, `src/mk2.cmd`, `src/MAKE.BAT` | `MKFRIEND.OBJ` / the GSPA step dropped |
| `src/MOVES.ASM` | 17 `calla fs_check` sites, one beside each `bb_check` |
| `src/MAINEQU.ASM` | `fs_check`, `start_bounce`, `do_friendship`, `ochar_friendship_combos`, `p1_friends`, `p2_friends` globals; the flyinv `0FFFEh` mailbox index |
| `src/MKDRONE.ASM` | `drone_execute_fatality`'s coin flip — now `jauc do_babality` |
| `src/MKINIT.ASM` | `fip_friend`, the fly's `0FFFEh` request |
| `src/MAIN.ASM` | `start_bounce` call and the friendship arm of `win6`; the friendship arm of `count_death_blow`; `a1` out of `winner_tallies`; the `happy_symbols` medal row and table; four `p1_friends`/`p2_friends` clears |
| `src/RAM.ASM` | `p1_friends`, `p2_friends` |
| `src/MKEND.ASM` | `txt_c5` (`"FRIENDSHIP ?"`) and its `clue_table` row; the clue count `movk 11` → `movk 10` |
| `src/MKBONUS.TBL` | `BC_HAPPY1-3`, the smile medal |

Left in place deliberately: the six `FRIEND*_P` palettes in `IMGPAL6.ASM` and
`SMILE_P`, now dead program-ROM data. Program ROM is not the scarce resource
here and the `lggoro_p` precedent is to leave dead palettes alone.

## Three things that were easy to miss

**1. `start_bounce` lives in MKFRIEND but is called from MAIN.** It is the
bouncing `FRIENDSHIP` letter banner, and `MAIN.ASM:win6` called it directly
rather than through the sequence. Deleting the module without that call site
is an unresolved external at link time.

**2. `winner_tallies` returned three values and one of them is gone.** It
handed back `a0` = fatalities, `a1` = friendships, `a2` = rounds won, and the
medal row did `sub a0,a10 / sub a1,a10` to get the plain wins. With `a1` no
longer written, leaving that second `sub` in would subtract whatever happened
to be in the register. Both the write and the read were removed together.

**3. `tools/jcfkick_probe.py` counted the instructions.** It located Cage's
high-kick handler as `site - 0x60`, commented "two calla (bb_check, fs_check)
ahead of it". Removing one `calla` moves the handler by 0x30 bits and the
probe would have reported a plausible-looking wrong address. It is now
`site - 0x30`. Nothing else in the tree derives an address from an
instruction count, but this is the class of breakage a grep for "friendship"
does not find.

## Art removed

211 records, all bank 1, in two LOD blocks. The `.IMG` files are **not**
touched — only the `--->` entries that packed those records into the video
ROM — so the art is still authored and the feature is restorable from git.
That is also why `doc/UNUSED_SPRITES.md` and `doc/IMG_SUBFRAME_AUDIT.md` still
list it: those audit the IMGs, not the ROM.

`data/MK6MIL.LOD` — the `ASM> MKFRIEND.TBL` block (179 records):

| IMG | records |
|---|---|
| MKFRIEND | the ten bouncing `FRIENDSHIP_*` letters |
| HATHED12 | `TMHATRICK1A..8C`, `RABBIT1-4` |
| CAGE9 | `JCFSBONUS*`, `AUTOGRAPH1-8` |
| KANG9 | `LKDANCIN*` |
| UGMO8 | `UGFSBONUS*`, `UGGIFT1-3` |
| KAT10 | `KTBAKE*`, `KTPLANT*`, `MEPLANT1-7`, `KTCAKE1-3` |
| TSUNG9 | `STFSBONUS*`, `RAINBOW*` |
| NINJAS12 | `NJFSBONUS1A..4A` |
| MKSCORE | `BC_HAPPY1-3` (the smile medal, elsewhere in the file) |

`data/MK7MIL.LOD` — the `ASM> MKFRND2.TBL` block (32 records): `NJFSBONUS4B`,
`NJFSBONUS4C` (NINJAS12), `JXFSBONUS*` (NUJAX9), `KIDTHUNDER1..7D` (RAID8).

**Shared art was kept.** Several friendship frames drew pieces that belong to
a live animation and those pieces stayed: `JCVICTORYLEG1A/AL/B` (Cage's
victory legs, including their `L` logo pieces) and `JXVICTORY8B/8D` (Jax's
victory, which `jx_friend` re-pointed at runtime through
`fix_goskie_fuckup`). Only records the friendship alone used were removed.

**LOD state-machine note.** Both blocks were bracketed by `POF>` / `ZON>` /
`PPP> 6` directives. In each case the state entering the block and the state
leaving it were identical to the surrounding state, so the whole block came
out without re-stating anything — verified by walking the directives rather
than assumed. Get this wrong and the records *after* the hole get a palette
pointer or a bit depth they were not authored for.

## Audio the friendship owned (for a sound-ROM reclaim)

Derived from the code, not guessed. Every sound the feature fired, and whether
anything in the ROM still fires it after the removal.

**Read the namespace first — there are FOUR dispatch paths and the numbers
collide across them.** This is the trap in this area:

| how it is sent | what the number means |
|---|---|
| `send_code_a3` (`movi N,a3`) | a RAW code straight to the sound port. N *is* the DCS command |
| `tsound N` | INDEX into `triple_sndtab` (MKSOUND.ASM:121) -> resolves to a track |
| `tsound2 N` | INDEX into `triple_sndtab2` (MKSOUND.ASM:529) -> resolves to a track |
| `.byte send,N` | a RAW code sent from a TUNE SCRIPT (`send .set 1`, MKSOUND.ASM:25) |

`tsound 03ah` and `send_code_a3` with `03ah` are unrelated sounds. Comparing
across namespaces will tell you a dead cue is live, or a live one is dead.

The fourth path is easy to miss because it is `.byte` pairs, not a `calla`.
The tree has exactly one tune script, `fast_fade_music` (MKSOUND.ASM:1141),
and it is DEAD: nothing references the label, and both tables contain ZERO
tune-script entries (an entry is one when its priority word is negative —
`triple_sound`'s `jrn triple_tune`), so that branch is never taken. It sends
only `000h`, `021h`-`029h` and `061h`-`069h` (music/drum volume ramps), which
is why it changes none of the findings below — but any future audit has to
check it, and it is the sole reason code `063h` appears in the ROM at all.

### Now unreferenced — safe to reclaim

| cue | resolves to | what it is | was fired by |
|---|---|---|---|
| `tsound 0d5h` | track **0329h** | `; d5 = kt` — the KIDD THUNDER sting | `kidd_thunder_proc` (Raiden) |
| `tsound2 058h` | track **03cfh** | `sp_bossv1` — Shao Kahn: "FRIENDSHIP" | MAIN.ASM `win6` friendship arm |
| `tsound2 059h` | track **044ch** | `sp_bossv1` — Shao Kahn: "FRIENDSHIP?" | MAIN.ASM `win6`, 03ah ticks later |
| raw **03ah** | (DCS command) | friendship tune | `fn2_friend`, `st_friend` |
| raw **03bh** | (DCS command) | friendship tune | `lk_friend` |
| raw **03eh** | (DCS command) | friendship tune | hh, jc, sa, fn1, rd, nj, jx |

Each of those three tracks appears exactly **once** across both tables, and no
remaining `send_code_a3` sends `03ah`, `03bh` or `03eh`. The surviving raw
codes are `32h 33h 34h 35h 36h 38h 39h 3ch 3fh 40h 41h 5ah 5bh b2h b9h eeh
10fh 135h 20ch 21bh 285h 358h 35eh 368h 36ah 3ffh 564h 55aah`.

### OUTCOME: reclaimed 2026-09-20 — 60,108 bytes (58.7 KB)

Taken by the DCS session with its user's approval. **13 tracks no-op'd to free
6 streams** — a stream only comes back when *every* track referencing it stops,
which is why the counts are grouped:

| stream | bytes | freed by no-op'ing |
|---|---:|---|
| `$165CE2` | 20,907 | `$003a` |
| `$21872A` | 16,056 | `$003b` + `$0063` |
| `$3467E8` | 10,526 | `$003e` |
| `$45BBCC` | 5,653 | `$0329` + `$032a` + `$032b` |
| `$52543E` | 3,819 | `$03cf` + `$03d0` + `$03d1` |
| `$53AD1E` | 3,147 | `$044c` + `$044d` + `$044e` |
| **total** | **60,108** | |

`$003b`'s 16 KB needed both halves of an argument: nothing in the GAME sends
`063h` (below), and nothing in the DCS track programs reaches `$0063` either —
this build has no Queue opcodes, empty deferred-indirect tables, and only two
Defer targets in the whole ROM (`$0033`, `$0037`).

**Latent trap.** `063h` is dead only because its sole sender, the tune script
`fast_fade_music` (MKSOUND.ASM:1141), is unreferenced. The script is still in
the ROM and is a plausible thing to wire up later — it is a ready-made fast
music fade. If anyone does, the `063h` step now hits a no-op'd track and the
ramp has a hole in it, which is audible and very hard to debug because the
source looks correct.

Not repackaged deliberately: a `mamerom` run re-rolls `crc_spoof`'s tail bytes
and would replace a verified install with an unverified zip. The reclaim is
headroom, not audio — nothing the game can reach changes. The smaller sound
set ships with whatever repackage happens next.

One place a reclaimed track is still reachable by a human: the operator sound
test in the diagnostics menu can request arbitrary track numbers, so these now
audition as silence.

### Must NOT be reclaimed

- `tsound2 004h` -> track **0239h**, "lightning strike". `kidd_thunder_proc`
  fired it, but so do `MKCANNED.ASM:581` and `MKFX.ASM:506` (Raiden's zap).
  Still live.
- raw **03fh**, "TUNE babality/friendship over". Still sent by
  `death_blow_complete` for fatalities and babalities.

### Not friendship-only, so nothing to reclaim

- `init_death_blow` creates `make_db_tone` — the death-blow tone, shared with
  every fatality and babality.
- `death_blow_complete` takes an early exit on `fs_fatality`
  (`cmpi fs_fatality,a1 / jreq dbc9`), so the friendship never sent the
  "death blow over" tune at all.

### Already dead before this change

Raw `37h` and `3dh` have no `send_code_a3` site and never had one in
MKFRIEND either — pre-existing dead codes, not freed by this work.

### What this list does NOT tell you

These are the cues the GAME sends. Whether a given DCS command owns stream
data, and how many bytes any of it frees, is a question for the sound ROM
side — a tune command may be a control opcode rather than a stream. The three
track numbers (0329h, 03cfh, 044ch) are the concrete reclaim candidates; the
patch file's convention is that a replaceable entry is a run of sound calls
(e.g. "745-747 ($02E9-$02EB)"), so expect these to sit in similar groups.

Regenerate this analysis after any change with the namespace-aware scan
described above; a plain grep for the number is what gets it wrong.


## Restoring it

```
git checkout <rev> -- src/MKFRIEND.ASM src/MKFRIEND.TBL src/MKFRND2.TBL \
                      data/MK6MIL.LOD data/MK7MIL.LOD
```
then put `MKFRIEND.OBJ` back in `src/MAKEFILE` and `src/mk2.cmd`, and revert
the hook edits listed in the table above. A full `python build.py` is
required — the art is repacked and every SAG after the restored blocks moves.
