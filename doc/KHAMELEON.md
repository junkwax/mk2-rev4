# KHAMELEON (ft_kham = 18)

A fifth hidden fighter: the **union of the three female ninjas**. She wears
their colours in turn — a **disguise cycle**, one every six to seven seconds —
moves and takes damage like the other hidden fighters, is fought on
**YOTEIGAI TOR**, and has **no fatality of any kind**.

She costs almost nothing in ROM. Every animation, strike record, reaction
and sound she uses already exists for Kitana, Mileena or Jade — the only new
art in the whole feature is her life-bar name plate, and the only new data is
four 130-byte palettes.

| | |
|---|---|
| `ochar` | **18** (`ft_kham`, MAINEQU.ASM) |
| TABLE1 | `fn3_anitab1` — the shared female-ninja table (one block, three labels) |
| TABLE2 | **`fn4_anitab2`** (new, MKFN.ASM) — the union |
| strikes | `fn_strikes` (shared with Kitana/Mileena/Jade) |
| reactions | `react_to_fn` |
| palette | **`KHMAIN_P`** anchor + the three disguises `KHALTJ_P`/`KHALTK_P`/`KHALTM_P` (MK2PALS.IMG -> IMGPAL6.ASM) |
| life bar | **`BAR_KHAM`** — MKSCORE.IMG, 87×10, packed via MK6MIL.LOD |
| arena | `curback` **018h** — YOTEIGAI TOR, forced for the CPU encounter only |
| fatality | **none** — no fatality, no pit fatality, no babality |
| access | **1 player, five taps of START on the BATTLE PLAN screen** — the next opponent is her (`kham_ladder_enable`). She is **CPU-only**; there is no way to pick her |

## Her moveset

All twelve specials plus the throw, on four buttons and one stick motion.
They coexist for exactly one reason: **no two share a motion on the same
button.** That is the invariant the whole design rests on, and
`tools/run_kham_moves_test.ps1` is the thing that guards it.

| button | motion | move | from |
|---|---|---|---|
| HP | F,D,B | Square Wave Punch | Kitana |
| HP | B,B,B | Fan Lift | Kitana |
| HP | B,F | Boomerang (rising) | Jade |
| HP + LP | F,F | Fan Throw | Kitana |
| HP **held, released** | — | Sai Throw | Mileena |
| LP | B,B,F | Boomerang (returning) | Jade |
| LP | B,F | Boomerang (straight) | Jade |
| HK | B,B,D | Ground Roll | Mileena |
| HK | B,F | Jade Flash (projectile dodge) | Jade |
| LK | F,F | Teleport Kick | Mileena |
| LK | B,F | Boomerang (dipping) | Jade |
| LK | D,F | Blazing Nitro Kick | Jade |
| stick | hold Block, F,F | Overhead Spin Chop | Kitana |

**Longer motions are tested first** wherever one contains another — the
history behind a `B,B,F` also contains a `B,F`, so a straight-first LP handler
would swallow every returning throw. `kham_lo_punch` (MOVES.ASM) is written
in that order deliberately.

Her handlers are `kham_hi_punch` / `kham_lo_punch` / `kham_hi_kick` /
`kham_lo_kick` in MOVES.ASM. `char_joyright[18]` reuses Kitana's `fn1_lr`
and `char_hip_open[18]` reuses Mileena's `fn2_hp_open` unchanged — those two
are already exactly what she wants.

## The one real merge conflict: the sai

`fn1_anitab2` (Kitana's TABLE2) **already contains every Jade lane** — rows
6-9 and 0bh are the boomerang, the nitro kick and its retraction. So Kitana +
Jade needed no reconciliation at all; `fn4_anitab2` rows 0-0bh are
bit-identical to hers and every Kitana and Jade routine, all of which index
those rows with a hardcoded `movk`, resolves unchanged.

Mileena is the collision. Her sai lanes are TABLE2 **5, 6, 7**, and in
Kitana's table 5 is the square-wave punch while 6 and 7 are the boomerang
throw and spin.

**The sai was the cheaper half to move**, because it is read from five call
sites and nowhere else, whereas 6/7/8 are read by boomerang code Jade shares.
So `fn4_anitab2` carries the sai at **0ch, 0dh, 0eh**, and
`kham_sai_ani2` (MKZAP.ASM) biases the index by `kham_sai_bias` = 7 when
`ochar` is `ft_kham`. Everybody else falls straight through and Mileena's own
throw is untouched.

`a0` is free at all six sites for the simplest possible reason:
`get_char_ani2` opens with `move *a8(ochar),a0,w`, so `a0` is already
destroyed by the call the wrapper replaces.

### The sixth site, and why it was missed (fixed 2026-09-06)

The first pass biased five sites - the ground throw, the air throw and the
flight loop - and shipped with **`saih4` still calling `get_char_ani2`
directly**. `saih4` is the tail shared by both `sai_hit` branches, so it runs
whether the sai lands or is blocked, and it reads the flight lane and then
takes `find_part2` of it: *the impact frames are part two of the same lane.*
Nothing at the call site says "sai".

For Khameleon that resolved index 6 of **her** table - `a_fn1_boom_spin` -
so a few frames of **Jade's boomerang** appeared at the moment of contact.
No crash, no build error, no assembler warning: just the wrong art for three
ticks, at the one moment the player is looking somewhere else.

**`tools/audit_kham_sai_lanes.py` now enumerates all six sites and fails the
build if any of them is raw** (Phase D, "khameleon sai lane bias"). It is
negative-tested: put the `calla get_char_ani2` back and it fails, naming the
line. That guard is the coverage that matters, because this failure is
invisible to every other check in the pipeline.

## The disguise cycle

She is a union of the three female ninjas and she wears it. Her own lavender
**`KHMAIN_P`** is what she is picked in, and once the fight is up she changes
into **Jade's green (`KHALTJ_P`)**, **Kitana's blue (`KHALTK_P`)** and
**Mileena's magenta (`KHALTM_P`)** in turn, one every **six to seven seconds**,
round and round for as long as the round is live.

**She is not morphing.** Only the colours change: her moveset, her frames and
her hurt boxes are hers throughout.

### The mechanism

`kham_disguise_pal_proc` (MKGUYS.ASM) is built on the retired (2026-10-06) `kitana_biv_pal_proc`'s
shape, and that proc's comment is the one to read first. In short, it rewrites
the *contents* of one colour map with `palset` rather than swapping palette
ids — `swpal` would hand `getfpal` a different id on every change, a
`getfpal`/`delpal` pair per change out of `nmfpal`=35, which is the churn the
Kahn power-up blink was retired for.

So **`character_palettes_1..7[ft_kham]` is `KHMAIN_P` and must stay
`KHMAIN_P`.** It is the single id every re-select resolves to — `player_normpal`
after each reaction, a round reset, a morph back — and each of those hits
`getfpal`'s *already there* path, which does **not** re-queue a transfer. She
keeps the map with whatever disguise is loaded in it and never snaps back.
A Start+button alternate would defeat the cycle, which is why all seven rows
hold the one id.

The **three disguises are never a palette anybody wears.** They are `palset`
payloads written into that one map, which is why they are in no
`character_palettes_N` table, need no bloodied twin, and are absent from
`death_fade_excludes` — the fade only ever sees the anchor.

### Why one map can hold any of them

All four palettes agree on indices **0-30 and 59-63** — skin, hair, eyes and
the gore markers are identical in all four — and differ only across the
costume ramp at **31-55**. That is what makes a change of disguise read as a
change of clothes rather than of character, and it is what lets the rig pick
one colour (index 40, distinct in all four) to name which disguise is loaded
and another (index 5, identical in all four) as the *is this even her map*
sentinel.

`KHMAIN_P` is still its own record rather than an alias of anything, for the
reason the retired `KHAM1_P` existed: **`getfpal` keys a colour map on the
palette pointer.** Two wearers of one id share one map, and two procs
repainting it from two independently advancing indices read on screen as a
flicker rather than a cycle. She and a Start+Coin Kitana can both run a
palette cycle in the same fight precisely because their anchors differ.

### The interval

| equate (MKGUYS.ASM) | value | |
|---|---|---|
| `kham_dis_min` | 328 ticks | 6.00 s at 54.7068 Hz — the shortest hold |
| `kham_dis_span` | 56 | `blood_randu` returns 1..56, so the hold is 328..383 ticks = **6.00..7.00 s** |
| `kham_dis_steps` | 3 | entries in `kham_disguise_pals` |

The gap is **re-rolled on every change** so the cycle does not read as a
metronome, and it is drawn from **`blood_randu`, not `randu`** — this is
cosmetic, so the gameplay RNG stream stays where the fight left it.

**The wait is taken a tick at a time**, the way `lightning` takes its own
random gap, and that is load-bearing rather than lazy. `setup_players` runs
once **per round** inside `play_1_round` (MAIN.ASM), so a fresh proc is created
every round — and at six or seven seconds a proc sleeping through the end of a
round would still be asleep when the next round's proc appears. Two of these
on one object each carry their own index, drift apart, and flip her costume
every tick. Checking `lgt_round_active` every tick is what stops that
stacking; a single `sleepr` of the whole gap would not.

### Adding her own colour back to the rotation

As shipped the cycle is the three ninjas alone and `KHMAIN_P` is what she is
picked in and opens the first round on. Appending `.long KHMAIN_P` to
`kham_disguise_pals` and bumping `kham_dis_steps` to 4 puts her own lavender
into the rotation as a fourth step.

### Where the words live, and who owns them

The four palettes are authored in **`data/MK2PALS.IMG`** and carried into
`src/IMGPAL6.ASM` by **`tools/sync_alt_costume_palettes.py`**, whose `--check`
runs in Phase D. Nothing in the build promotes an IMG palette into the ROM, so
without that carry a repaint in IMGTOOL would ship the old colours with no
error anywhere. **Edit the IMG, then run the tool — never the words.**

`KHAM1_P` (IMGPAL5.ASM), the byte-identical copy of `BIV1_P` she used to wear,
is **gone**: `KHMAIN_P` does its job. `tools/make_soul_blend_pals.py` now
derives `SOULKHM_P` from `KHMAIN_P`, so her soul in Shang's defeat wears the
colour she is picked in rather than one of the disguises.

### Shared guards

`kpal_owner_live` and `kpal_paint` (MKGUYS.ASM) are the two halves both palette
cycles now share, split out of `ktbiv_step` so hers cannot drift away from
Kitana's:

1. `kpal_owner_live` — a8 is still one of the two live fighter objects, so
   `*a8(...)` may be read at all;
2. `kpal_paint` — the anchor is in colour ram **and** her object is still
   wearing that map. On a blood palette during a fatality, on `jade_white_p`,
   or once her object is gone, the change is skipped, so the cycle can never
   repaint a map that now belongs to somebody else.

A skipped change does **not** advance the index, so the cycle resumes on the
disguise it was owed rather than losing it.

### Rig

`tools/run_kham_disguise_test.ps1` drives the real summons (1P, five taps of
**Start on the battle plan** — a hidden fighter cannot be forced into a fight,
so the gesture IS the harness), watches the **drone** (player 2), pins **both** bars
so the whole run stays inside one round, and then watches the colour map her
object is actually wearing. PASS = she opens on the anchor, the three disguises
arrive in `kham_disguise_pals`' order, the cycle wraps, and **every interval
between changes is inside the authored window**.

That last clause is the point. The old BIV cycle stepped every 4 ticks, so a
rig proving only "the colours moved" would pass on either; a gap outside
328..383 fails here. The first observed change is deliberately **not** timed —
the proc is created during `pfsetup` and has already been counting before
`gstate` reaches fighting, so only the gaps *between* changes are whole
intervals.

Expectations are regenerated from `data/MK2PALS.IMG` on every run by
`tools/kham_disguise_expect.py`, so the rig cannot pass against a colour that
was true before the last repaint; the generator also asserts that index 5 is
still identical in all four and index 40 still distinct, so a repaint that
flattens the ramp fails the generator instead of producing a rig that cannot
discriminate. `-Negative` rotates the expected colours by one and **must** fail — a rig that
only notices "the map changed" would pass it. **`-NoTaps` is the control for
the summons itself**: the same 1P game with no taps, which must reach the
fight against the tower's own opponent. Measured, the two runs are identical
to the frame — battle plan at 404, fight at 932 — and differ only in the
drone: char 11 without the taps, char 18 with.

The retired BIV rig for her is in `_old/kham_bivpal_rig/`.

## How she is reached: the battle plan screen

**One player, on the mountain between matches: tap START five times and the
next opponent is Khameleon.** `kham_ladder_enable` (MAINEQU.ASM). She is a
CPU-only fighter — there is no longer any way to *pick* her, and both earlier
unlocks are compiled out: Mileena + Start ×5 on the select screen
(`kham_select_enable`, retired 2026-09-27) and Kitana + Block ×5 before that.

Two halves:

- **`kham_ladder_tap`** (MKSEL.ASM) counts the taps and latches `f_kham_next`.
  It hangs off **`escape_button_update`**, which is the per-tick heartbeat of
  every wait loop on that screen — `ladder_sleep`, the pan-down and the box
  plot — so one hook covers the whole screen. That matters: a per-screen
  gesture spread over three loops is the same shape as the sai-lane bias that
  shipped broken with one call site missed.
- **`kham_ladder_summon`** (MAIN.ASM) spends the flag on the next drone.

It counts **releases**, not ticks held — `l_kham_ladder` remembers whether Start
was down last tick — so leaning on the button is one tap, not five. `do_ladder`
clears all three words on the way in, so a summons cannot survive a game, and
the flag is **consumed**, so one summons is one match.

### Two traps this hit

**`set_drone_ochar` runs BEFORE `do_ladder`.** The obvious home for the
consumer is beside the live "hold High Punch → fight Jade" override inside
`set_drone_ochar`, and that is wrong: the play loop picks the drone *before* the
battle plan is drawn, so a flag latched by taps **on** that screen cannot be
read there. Put it there and she is summoned for the match *after* the next one
— except `do_ladder`'s own entry clear wipes the flag first, so she never comes
out at all and nothing errors. Hence `kham_ladder_summon`, called from the play
loop *after* `jsrp do_ladder`.

**Start is safe on this screen, and that is not obvious.**
`escape_button_update` skips the battle plan on
`p1b0|p1b2|p1b3|p1sf2` + `p1b1|p1b4`, which looks like it includes Start and
does not: **`p1sf2` is not `p1_start_sw`**. They are different bits, and
`morph_start_tap` proves it — that detector reads `p1_start_sw` for its tap and
lists `p1sf2` as a *spoiler*, which would make it self-defeating if they were
the same. So Start has never been one of the skip buttons and five taps cannot
cut the screen short underneath the player.

Gating the cheat off also un-gated Mileena's square in `auto_select_check`
(MAIN.ASM): that skip existed only so her five Starts did not feed the 1P Kahn
cheat, so it is now `.if kham_select_enable` too and her square behaves as
retail again.

## Scaling: she is a hidden fighter, on the CPU's side of the gate

Per the decision taken when this was built, she follows Jade/Smoke/Noob/Ermac
exactly rather than being unconditionally strong:

- `ochar_damage_table[18]` = `xlate_secret` — 3/4 damage taken, **and the same
  `ps_active` gate**, so it applies only while the CPU is playing her.
- `decode_walk_table`'s `secretwalk` block sends a **human** Khameleon to
  Kitana's walk row (`ft_fn1`); the CPU keeps the boss speed, because a fast
  secret *opponent* is the point.

`walk_forward_info[18]` / `walk_backward_info[18]` are Jade's fast rows
(`3,04800h` / `4,03000h`), which is what the CPU gets.

## The arena

`boss_minumum_diff` (MAIN.ASM) gained a `bmdif_kham_test` block in the same
shape as Jade's, forcing `curback` **018h** and difficulty 8 — and, like
Jade's, gated on `secret_is_cpu`, so **a player who unlocks her keeps the
selected stage** rather than being dragged to her arena for the whole ladder.
Jade's "no Jade in this match" exit was re-pointed at the new test so it is
not skipped.

She is not yet scheduled as a ladder opponent, so nothing puts her on the
other side of the screen in ordinary play — that is part of the access work
still open.

## No fatality

Deliberate, and enforced in four independent places:

- all of `char_hik_open` / `char_lop_open` / `char_lok_open` row 18 are
  `sucide`, and so is `char_block[18]` (no pit fatality);
- none of her handlers carry the `winner_status == 3` preamble that
  `fn1_hi_kick` and `fn2_lo_punch` open with, and none reaches `check_dtp`,
  `do_fatality_1/2` or `fatality_xfer` — verified by grep over the block;
- `db1_table` / `db2_table` stay 12 rows, reachable only from ochar 0-11;
- `bb_check` gates at `cmpi 12 / jrhs`, so the babality is out too.
  (Friendships were removed from the ROM entirely on 2026-09-20.)

`char_hip_open[18]` is `fn2_hp_open`, which is Mileena's **sai** handler, not
a fatality route.

## The unlock is PROVISIONAL

`kham_select_enable` (MAINEQU.ASM) = 1: **hover Kitana, press Block five
times.** Kitana is the one female ninja with no unlock on her (Mileena
carries Jade's), and Block ×5 is the shape Smoke/Noob/Ermac already use.

It is switched on so she is *reachable and therefore testable* — a hidden
fighter cannot be forced into a fight by any rig, so the cheat path is the
test harness. Changing the input is a one-line edit to
`check_kham_blk_cheat`'s `ft_fn1` test plus the `chbc_` dispatch above it.

The plumbing mirrors Ermac's exactly: six `.bss` variables in RAM.ASM,
`check_kham_blk_cheat` / `clear_kham_blk_held` / `clear_kham_cheat_progress`
in MKSEL.ASM, a `php_kham` arm in `psel_hidden_pick`, and
`kham_select_cheat_apply` in MAIN.ASM. The two `clear_*` routines sit
**outside** the `.if` because `clear_hidden_blk_held`, the Block dispatch's
no-match exit and `ncp_stay_kitana` all call them unguarded.

## The announcer says nothing

There is no "Khameleon" name stream. `winner_speech[18]` is **0**, which
`pwt1`'s existing `jreq pwt2` already treats as "no call", and
`psel_hidden_pick` returns speech index 0 for her so `cmove9` skips creating
the speech proc entirely. The banner still reads **KHAMELEON WINS**
(`pf_kham_win`). Adding a real name later is a `triple_sndtab2` entry plus a
`stlaugh_patch.txt` clip and these two zeros.

## Tests

```
tools\run_kham_moves_test.ps1                            # all 13 specials
tools\run_kham_disguise_test.ps1                       # summons + disguise cycle
tools\run_kham_disguise_test.ps1 -NoTaps               # control: no taps, no her
tools\run_kham_disguise_test.ps1 -Negative             # ... must FAIL
tools\run_kham_stage_test.ps1                            # arena, both ways
tools\run_kham_sai_hit_test.ps1                          # sai art vs Mileena
python tools\audit_kham_sai_lanes.py                     # (also in Phase D)
```

Status at time of writing: unlock 2/2 players + 2 off-base regressions,
**13/13 specials**, arena forced for the CPU and *not* forced for a
human. Kitana's own cycling costume and the
Ermac/Jade unlocks re-tested green.

### Two traps these rigs hit, both of which look like the feature failing

- **A move rig must know which way she is pointing.** The first version of
  `kham_moves_test.lua` hardcoded forward = Right. The square wave is a
  *travelling* move: it carried her from x=484 to x=744, straight past an
  opponent parked at 655. Every test after it was entered in the wrong facing
  and read as a failure — **eleven "missing" specials, all of them fine.**
  The rig now latches facing from the two x positions at the start of each
  test.
- **The sai rig cannot land a sai on a scripted victim.** The drone ducks
  every one; pinning it with `p2_xvel = 0` holds the range but freezes it into
  a fighter that never engages at all; a second human is never hit either.
  All three fail **identically for Mileena**, which is how we know it is the
  rig. So `run_kham_sai_hit_test.ps1` photographs the *flight* lane - index 6,
  the exact index the bug got wrong - against Mileena as a control, and the
  impact is covered by `audit_kham_sai_lanes.py` instead, since `saih4`
  resolves that same lane with that same call.
- **Writing `p2_char` at the select screen makes it a two-player match.**
  `p2_state` goes `ps_active`, and then `secret_is_cpu` correctly answers "a
  human has her" and `count_active_players` returns 2 — so
  `boss_minumum_diff` deliberately leaves both the arena and the difficulty
  alone. The stage probe was manufacturing the exact condition the feature is
  designed to skip, and reported `curback=0x00`. It reported the same for
  **Jade**, whose forcing has shipped for months, which is what identified it.
  `run_kham_stage_test.ps1 -Mode control` runs that Jade comparison on
  purpose: run it first whenever this rig says the stage was not forced.
