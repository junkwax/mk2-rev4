# The costume palettes — `data/MK2PALS.IMG` on the seven lanes

Every costume a playable fighter can wear is now **authored in one place** —
`data/MK2PALS.IMG` — and carried into the ROM by
`tools/make_costume_palettes.py`. Two players can no longer end up in the same
costume.

Before this, a costume lived wherever it happened to have been authored:
`NINJAS3.IMG` for the UMK ninjas, `KAT104.IMG` for Kitana's silver,
`RADBOLT1.IMG` for Raiden's, the read-only tree for the twelve retail mirror
costumes, plus thirty-odd hand carries in `IMGPAL*.ASM`. Repainting one meant
finding which library owned it and which sync tool carried it.

## The scheme

Per fighter, a two-letter code, then the slot:

| record | lane | costume table | blood table |
|---|---|---|---|
| `<XX>MAIN_P` / `<XX>BLD_P` | default | `character_palettes_1` | `bloody_palettes` col 0 |
| `<XX>ALT1_P` / `<XX>BLD1_P` | START + HIGH PUNCH | `character_palettes_4` | `bloody_character_palettes_4` |
| `<XX>ALT2_P` / `<XX>BLD2_P` | START + LOW PUNCH | `character_palettes_2` | `..._2` |
| `<XX>ALT3_P` / `<XX>BLD3_P` | START + HIGH KICK | `character_palettes_5` | `..._5` |
| `<XX>ALT4_P` / `<XX>BLD4_P` | START + LOW KICK | `character_palettes_6` | `..._6` |
| `<XX>ALT5_P` / `<XX>BLD5_P` | START + BLOCK | `character_palettes_3` | `..._3` |

The slot number **is** the lane, so the seven tables MKGUYS.ASM already had
needed no restructuring — `character_palettes_2` is still both Start+LP and the
costume player 2 is handed in a mirror match.

**START+COIN is disabled** (`costcoin .set 0`, MAINEQU.ASM, 2026-09-27) — it is
in no `ALTn` slot and is no longer a costume lane at all.
`psel_repalt5_preview` and `claim_repalt5_pal` (MKSEL.ASM) both return "not
active", and `character_palettes_7` / `bloody_character_palettes_7` are
flattened to each fighter's default as well. `ALT6_P` records are reported as
unwired rather than guessed onto anything.

**Flattening the rows alone would not have disabled it**, which is the part
worth remembering: with the claim still live, a coin would claim a lane whose
palette equals the player's own default, the no-duplicate rule would find
player 1 already wearing it, and the coin would *shift* player 2 onto Start+HP
— a disabled button that changes your costume. The switch gates the claim; the
flattened rows are belt and braces. The lane is dropped from the no-duplicate
walk too (`costume_lanes .set 6+costcoin`), so a shifted player 2 can never
land on it.

**Kitana's BIV ramp is retired (2026-10-06).** `BIV1_P` used to sit on her
coin row so `kitana_biv_pal_proc` could cycle 14 hues through the colour map
it allocated - an outfit that changed colour mid-match. The proc, the table
and the 14 palettes are gone from the ROM (the words survive in
`data/KATPAL.IMG`), `COIN_KEEP` is empty, and her coin lane takes her default
like any fighter with no `KTALT6_P`.

The codes: `KL` Kung Lao, `LK` Liu Kang, `JC` Cage, `UG` Baraka, `KT` Kitana,
`ML` Mileena, `ST` Shang, `RD` Raiden, `SZ` Sub-Zero, `RP` Reptile,
`SC` Scorpion, `JX` Jax, `NS` Noob, `JD` Jade, `ER` Ermac, `RN` Rain.

## What is deliberately not in it

* **Kintaro (12), Shao Kahn (13), Smoke (14)** — CPU only, no costume
  management.
* **Khameleon (18)** — all seven of her lanes must resolve to the *same*
  palette id, because `kham_disguise_pal_proc` rewrites the contents of
  whatever colour map `KHMAIN_P` allocated. Her `KHALT1-4_P` are disguise
  payloads, not costumes. A Start+button alternate would break the cycle.
* **`RB*`** — not a fighter; a prop/effect set (user, 2026-09-26).
* **`SB*`** — superseded by the complete `SZ*` set. `SBALT4_P` and `SZALT4_P`
  both claimed START+LK and SZ won.
* **`M2*`** — still owned by `tools/make_mk2pals.py`, which has its own check.

## `KP_` is load-bearing, not cosmetic

Every generated symbol is the IMG record name prefixed `KP_`. **Six of the
library's record names already exist in `src/` as different palettes** — the
library's `LKALT3_P` differs from the linked symbol of that name by **56 entries
of 64** — and `RPBLD1_P` / `SCBLD1_P` collide with the ninja blood palettes
`RPBLD1_p` / `SCBLD1_p` by *case alone*. Emitting the record names verbatim
would either fail the link or quietly resolve a costume row to the wrong
palette. `src/COSTPAL.ASM` names the record each symbol came from.

## Fallbacks, and the gaps are the worklist

**A lane with no record of its own takes the fighter's default**, costume and
blood alike — his `<XX>MAIN_P` / `<XX>BLD_P` when the library carries one,
otherwise whatever `character_palettes_1` / `bloody_palettes` column 0 already
point at. `python tools/make_costume_palettes.py --matrix` prints the
per-fighter grid and lists every lane still falling back.

**Never the palette that lane happened to hold**, and that is the whole point.
Five fighters had a *clean costume* sitting in a blood row — Rain's Start+HK,
Start+LK and Start+Block were all `SUBALT4_P`, Ermac's Start+LP was `ERUMK2_P` —
so being cut up on those lanes left them looking untouched: the same defect the
NINJAS11 blood palettes were authored to fix, still live on the lanes nobody had
looked at. The costume side had the same shape of problem — a lane left alone
kept a palette with nothing to do with the fighter's current set.

A button that falls back to the default **looks like it does nothing**, which is
correct. And if the other player is already wearing that default, the
no-duplicate rule rolls player 2 forward to the next open lane, so he still gets
a costume of his own.

`data/MK2PALS.IMG` is in **no LOD** — LOAD2 never reads it and no pixel of it
reaches a ROM. Only the generated `src/COSTPAL.ASM` links. So a repaint that was
never re-imported changes nothing and errors nowhere, which is why
`make_costume_palettes.py --check` is a Phase D gate.

### Clearing a red gate: run `--apply`, never `git checkout`

When the gate goes red the fix is `python tools/make_costume_palettes.py
--apply`. It is **not** safe to reach for `git checkout src/MKGUYS.ASM` to make
the drift go away, and the difference is not obvious from the message the gate
prints.

`src/COSTPAL.ASM` is wholly generated, so reverting it costs nothing — the tool
writes it back. `src/MKGUYS.ASM` is **hand-written code with generated regions
inside it**: the `.ref` block and the `character_palettes_N` /
`bloody_palettes` rows are the tool's, everything around them is not. `--apply`
rewrites only its own regions and carries the hand code through untouched
(verified 2026-09-27: regenerating from a tree holding an unrelated hand fix
reproduced the file byte for byte). A `checkout` does not know the difference
and takes the hand code with it.

The live example is `pnorm2`'s carry test (`jrc pnorm3`, MKGUYS.ASM around
line 2542): it keeps `pm_alt_pal` raised when `swpal` finds no free colour map,
so a failed swap retries on the next `player_normpal` instead of leaving the
man in a freeze/shock palette for the rest of the round. It is a few lines
long, it sits nowhere near the tables, and nothing in a red-gate message
mentions it. Reverting the file to clear the gate would delete it silently and
the gate would go green — a repaint bug reintroduced by the act of tidying up.

A red gate means the linked tables disagree with `data/MK2PALS.IMG`; it never
means the surrounding file is wrong. And because Phase D exits on its first
failure, a red one here also means every later guard never ran — so the state
is unknown, not known-good.


## Death fade

A costume palette a fighter can *wear* must be in `death_fade_excludes` or he
dims while the stage fades (the 2026-09-08 Ermac defect;
`tools/audit_fade_excludes.py` is the gate). Costume palettes are always added.

Blood palettes are added only for the fighters in `BLOOD_STAYS_LIT`
(Kitana, Sub-Zero, Reptile, Scorpion), which reproduces today's behaviour: the
ninja-bodied fighters stay lit while cut up, the stock ones still dim as retail
does. **That set is authored, not computed.** The honest test is "was the
palette this row replaced excluded?", and that palette is gone after the first
`--apply` — computing it made the tool undo its own exclusions on the second
run, which is how the bug was found. Ermac and Rain belong in the set the day
their `BLD_P` is authored; the report warns when a fighter outside it is about
to lose an exclusion.

---

# Two players never wear the same costume

`costnodup` (MAINEQU.ASM); `costume_pal_a0` / `blood_pal_a0` (MKGUYS.ASM).

A costume the other player already has is refused, and the button **rolls
forward to the next one on offer** — default, Start+HP, LP, HK, LK, Block,
Start+Coin, wrapping. Retail only stopped two players claiming the same
*button*; it did nothing about them claiming the same *colours*, which matters
far more now that the palettes are authored per lane.

## Only player 2 yields

If both players ran the rule they would **chase** each other: P1 sees P2 in his
colours and moves, P2 then sees the new palette and moves as well, and the
select screen oscillates for as long as both buttons are held. P1 always wears
what he asked for. It is also the choice MK2 already made — in a mirror match it
is P2 who is handed the alternate (`check_same_character_pal`).

## It resolves from global state only

`alt_pal_owner` and `p1_char`, nothing else. The select-screen preview and
`player_normpal` in the fight therefore reach the same answer with nothing
passed between them. **That is what makes it safe:** `player_normpal` runs again
on every knockdown, every morph and every Raiden dim, so a rule that had to be
*remembered* would come undone on the first repalette of the round and put
player 2 back in player 1's colours mid-fight.

`costume_pal_a0` is a drop-in replacement for `get_char_long` — same input,
same output, clobbers no more (a0, a1) — which is the whole trick: the previews
and `player_normpal` both resolve a costume by handing a table to
`get_char_long`, so swapping the routine puts the rule on every lane at once,
the default and the mirror included.

## The blood palette has to move with the costume

A shifted player 2 still has his **claimed** lane in `oflags2` — that is what
claimed the button, and what `change_to_bloody_pal` reads. Resolving his gore
off those bits dresses him in the cut-up palette of the costume he did *not*
get, and his body changes colour the first time he is cut. Both routines
therefore run one shared shift (`costume_lane_shift`) and index parallel tables
(`costume_offer` / `blood_offer`) with the answer. `bloody_palettes` is the odd
one out — `[nice, ugly]` pairs, only column 0 ever read — so `blood_offer`
carries log2 of each row size beside the table.

## Where the refusals were

Twelve of them, in two families in MKSEL.ASM, all removed:

* `psap` / `psf` / `pslp` / `psr` / `psk` / `psl` — the preview-object path.
* `csap` / `csrf` / `cslp` / `csrp` / `csrk` / `csrl` — the select-process path,
  which is the one that **writes** the claim. Leaving the refusal in this family
  would have overruled the preview: player 2 would watch the costume he was
  given on the select screen and then fight in his default.

Both players may now claim the same lane; the bits in `alt_pal_owner` are
per-player, so that is harmless, and `costume_pal_a0` is what keeps them out of
one costume.

`costnodup .set 0` restores retail: the button is simply refused, the player
keeps his default, and a mirror match can put both fighters in one palette.

---

# The CPU picks a random costume in 1P - `dronecos`

`drone_costume_pick` (MKGUYS.ASM), called from `setup_players` before
`make_player_2_obj`. It writes player 2's claim into `@alt_pal_owner` and gets
out of the way: the costume, the cut-up palette, `death_fade_excludes` and the
no-duplicate rule all resolve from that word already, so the CPU's pick is
indistinguishable from a human holding Start and a button.

**Once per opponent, not per round.** `setup_players` runs once per *round*
inside `play_1_round`, so rolling on every call would repaint the CPU between
rounds of one match. `@dcos_for` holds the ochar the standing pick was rolled
for, **stored as ochar+1** because `.bss` powers up as 0 and 0 is a real ochar -
stored raw, a first opponent of Kung Lao would read as "already rolled".

**It rolls among DISTINCT palettes, not lanes.** Every unauthored lane falls
back to the default, so rolling lanes would land on the default most of the time
and look like nothing happened. Pass one counts the palettes that are not a
repeat of an earlier lane's; pass two walks to the n'th of those.

**Noob, Smoke and Khameleon are included**, because it reads the live tables and
not the generator's roster - any ochar works. Measured: Noob has 4 distinct
costumes and all four appear; **Smoke and Khameleon have exactly 1**, so their
roll is inert until more are authored, and for Khameleon that is the *safe*
outcome - a different palette id would break `kham_disguise_pal_proc`'s cycle.

No divide: `modu` appears nowhere in this tree, so the roll masks to the
smallest power of two covering the count and re-rolls the overshoots, bounded at
eight tries. Randomness is a private xorshift seeded off the *value* of `@rand`
(`hp_pick_stir`'s pattern), so the gameplay stream and netplay determinism are
untouched. Attract mode (two drones) is excluded.

## The trap that cost a build cycle

**Hooking `pnorm2` alone was not enough.** `player_normpal` is called at the end
of `make_player_obj`, but `pnorm_check_temp_alt` refuses to do anything unless
the *calling process* has `pb_alt_pal` up - and `make_player_obj` clears
`p_flags` a few lines earlier. So for the INITIAL costume it returns immediately
and the palette comes from `make_player_obj`'s own direct read. Both fighters
came out of a mirror match in one palette, and the rig caught it. The fix routes
that direct read through `costume_pal_a0` too, and sets `oid` there -
`make_player_1_obj` / `make_player_2_obj` set `oid` only *after*
`make_player_obj` returns, so the rule could not tell which player it was
looking at.

# Rig

`tools/run_costume_test.ps1`, expectations regenerated from the linked source by
`tools/costume_expect.py` on every run.

    -Mode nodup   2P mirror, P1 claims START+LP (the lane the mirror rule hands
                  P2), asserts P2 lands on lane 3 SPECIFICALLY - "they differ"
                  would also pass on garbage.
    -Mode drone   1P: the CPU's palette is one of HIS lanes, is not P1's, and is
                  UNCHANGED in round 2.  -Rolls N requires two different lanes
                  across runs.

## Three rig traps, all of which made working ASM look broken

1. **Forcing `p2_char` makes the game treat player 2 as PRESENT.** `p2_state`
   came up `ps_active` - a human with nobody on the sticks - so `setup_players`
   handed him `joy_2_proc` and `drone_costume_pick` correctly refused to dress a
   human. Every roll landed on the default. Pin `p2_state = 0` as well
   (MAIN.ASM: "p?_state is ps_active for humans and 0 for drones during the
   match"); `shang_soul_escape_test.lua:240` already did.
2. **Pin the pair until the fight is RUNNING, not just through the select
   states.** `setup_players` reads `@p2_char` during the round intro, after
   `GS_PSEL`/`GS_POST` are gone - the game picked its own ladder opponent in
   between and the costume was compared against the wrong fighter's lanes.
3. **A scripted rig boots deterministically, so `@rand` is identical every run**
   - and so is the seed, and so is the pick. Five rolls all chose lane 0 and it
   looked like a broken roll. `CT_JITTER` shifts the input schedule a few frames
   per trial, which is what a real player does by not pressing start on the same
   frame.

# Palettes carried by NAME, not by the lane scheme

A move's palette is not a costume - no lane, no blood twin, no table row - but it
has the same failure mode the costume set has: `data/MK2PALS.IMG` is in NO LOD,
so a repaint in IMGTOOL reaches nothing until a tool carries it, and a
hand-carried copy in `IMGPAL*.ASM` silently ships last week's colours. The
generator's `CARRY` dict names such palettes, emits them into `src/COSTPAL.ASM`
and puts them under Phase D's `--check` with everything else. They get no table
row and no `death_fade_excludes` entry - whoever uses the palette decides that.

    JDKIK_P -> KP_JDKIK_P    Jade's Blazing Nitro Kick (do_fn1_nitro, MOVES.ASM)

**Jade's nitro kick** wore `NROKICK_P` (IMGPAL3.ASM, hand-patched from KAT4.IMG
record 7). It now wears `KP_JDKIK_P`, which differs from it in **63 of 64
entries** - a repaint, not a tweak. Three old copies are left linked and are now
referenced by nothing: `NROKICK_P`, its alias `NITROK_P`, and `JADEKCK_P`, which
was already dead before this. `tools/backup_code_palettes.py --dead` will strip
them if the ~390 bytes are ever wanted.

The `.ref` is **local to MOVES.ASM**, deliberately. `src/IMGTBL.GLO` is how that
module sees palette symbols today, but it is `.include`d by **51** modules, and
MAINEQU by ~70 - one line in either is paid for that many times, which is what
put MKDEATH over GSPA's ceiling on 2026-09-27. Only MOVES needs the name.

The nitro palette is NOT in `death_fade_excludes`, matching `NROKICK_P`, which
was not either. So Jade dims during the kick if a stage fade overlaps it, exactly
as before - not changed unasked.

## Status - VERIFIED IN MAME## Status - VERIFIED IN MAME

* All four changed files assemble **No Errors, No Warnings**; the tree links and
  Phase D is green end to end.
* `callr setup_players -> drone_costume_pick` MEASURED off a listing: 4,930
  bytes, 15% of the +/-32KB budget. MKGUYS `.text` is 15,250 bytes total, so any
  intra-object `callr` in that file has 2.1x margin. `check_pcrel_range --check`
  does NOT cover this - it checks cross-object branches only.
* **nodup: PASS** on Liu Kang (`KP_LKALT2_P` -> `KP_LKALT3_P`, maps 6 and 7) and
  Scorpion (`KP_SCALT2_P` -> `KP_SCALT3_P`).
* **drone: 5/5 PASS on Noob**, all four of his distinct lanes seen across five
  jittered rolls (0, 1, 3, 2, 2), each with a different seed, and the costume
  unchanged in round 2 every time.
* **drone: 2/2 PASS each on Smoke and Khameleon**, roll correctly inert.
