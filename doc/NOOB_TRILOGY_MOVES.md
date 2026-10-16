# Noob Saibot's MK Trilogy moves, ported

Two of MK Trilogy's three Noob Saibot specials, ported from the N64 source
leak on 2026-09-28: the **ghost ball** (Down, Forward + LP) and the
**teleport slam** (Down, Up). Feature switches `noobghost` and `noobslam`
in `src/MAINEQU.ASM`, both `1`.

The third — the **alter ego** clone — is not ported; see "Not ported" below.

## His whole move list

Trimmed to this on 2026-10-04, by request - it is the complete set:

| input | move | where |
|---|---|---|
| D, F + LP | ghost ball | `noob_lo_punch` -> `do_noob_ghost` (MKZAP.ASM) |
| D, U | teleport slam | `noob_up` -> `do_noob_slam` (MKPROP.ASM) |
| F, F + HP | shadow throw | `noob_hi_punch` -> `do_noob_ego_prop` (MKPROP.ASM) |
| Away + LP+BL+LK | Sub-Zero's slide | `slide_check` -> `do_slide` |
| U, D + HK, in the air | Reptile's dive kick | `noob_hi_kick` -> `do_reptile_superk` (MKPROP.ASM) |

The five SHADOW moves - shadow slide, shadow kick, shadow dive, shadow portal
and shadow teleport - stay compiled out under `noob_extras` (`0`), which is
also why the slam has Down,Up to itself: `noob_up` tests the shadow teleport
first and reaches the slam only in the `.else`.

### The dive kick is Reptile's, not a copy of it

`noobdive` (MAINEQU.ASM, `1`). `noob_hi_kick` is `rphk_dive` word for word:
the same `scom_super_rep`, the same `0a0h` `distance_from_ground` gate, the
same `do_reptile_superk`, and `airborn_xfer` rather than `restricted_xfer`
because the move is only legal off the ground.

It needed no art, hitbox or reaction, and that is not luck:

* `super_reptile_scan` (MKPROP.ASM) already picks the strike record by ochar -
  `hh_stk_superk` for Kung Lao, `nj_stk_superk` for everyone else - and Noob
  reads `nj_strikes`, so he gets `stk_rp_superk` exactly as Reptile does.
  **This is the half that would have gone wrong silently**: index `012h` is
  `stk_super_rep` in `hh_strikes` but `stk_slide` in `nj_strikes`, a shin-high
  box parked at y 125, which is why the launch height is the assertion and not
  the hit.
* `flight_call` resolves `a9 = 01eh` through `get_char_ani`, and anitab1 row
  `01eh` is `a_njflipkick`, which Noob has on `sm_anitab1`.

### The shadow he leaves is Reptile's decoy

`superk_afterimage` (MKPROP.ASM) takes `ft_noob` beside `ft_reptile`, so the
dive leaves one gmo object in his own colours, parked at the launch point and
flashing out - the same thing Reptile leaves, which is the point. Kung Lao and
Ermac still get none. Nothing in that routine was Reptile-specific but the
compare: the pose is anitab1 `01eh` either way (`NJFLIPKICK` for both, they
share the art) and the copy wears the diver's own palette off `*a11(opal)`.
Measured identical to Reptile's: `NJFLIPKICK1A`, 33 ticks, drift 0, and he is
61px away from it by the time it goes.

#### The ghost-trail version, built and switched off

`noobdive_ghost` (MAINEQU.ASM, `0`). It was tried first the other way round at
the user's request - "instead of the decoy it just does the teleport shadow
behind the kick" - and then reverted to match Reptile. `1` gives it back: the
dive arms `ghost_arm_n` (MKDISP.ASM) on the teleport slam's own pens and
palette (`nbs_ghost_pens` / `nbs_ghost_p`, the three that cool to near-black)
and `superk_afterimage` skips him (`noobdive_copy`), so he gets one shadow or
the other, never both. It costs no object, no process and no palette:
`ghost_rec` blits his pose in ONE pen out of a `.bss` ring.

**Keep `RSK_GHOST_GAP` with it, because the gap is the whole difference between
a trail and two smudges.** `ghost_arm_n` always writes `GHA_GAP` - 3 ticks
between snapshots - which is right for the SLAM, a climb of thirty-odd ticks.
The dive is over in six to eight (measured: it connects at `since=6..8` at
*every* spacing the rig parks him at), so at 3 the ring never held more than two
and the oldest was barely clear of him: that build read as "it doesn't trail
behind the kick well", and the rig said the same in numbers, `ghosts_snapped 1`
over a 5-tick armed window. At `RSK_GHOST_GAP` 2 it is 7 armed ticks and 3
snapshots, strung out along the line he came down. `ghost_arm_n` re-writes
`GHA_GAP` on every arm, so the tightened gap cannot leak into the slam.

Disarmed after `flight_call` returns (he landed) and in `super_rep_hit` (he
connected and is frozen - a ghost of a man standing still is a silhouette parked
on top of him). Neither is on every path, since `super_rep_hit` unwinds the
process stack and jumps away, so `gh_life` expiring is the backstop, exactly as
it is for the slam.

One thing he does **not** get:

* **the CPU throwing it.** `drone_ajump_call`'s dive gate (MKDRONE.ASM,
  `drnsuperk`) tests ochar for `ft_reptile` and `ft_hathead`, and **MKDRONE
  sits ON the GSPA out-of-memory cliff**: a `cmpi ft_noob` plus its `jreq`,
  four lines with the `.if`, aborts the assembly with `>> Out of memory`.
  Measured - the minimal version with no comment at all still aborts. Giving
  it to the CPU means moving the `drnsuperk` block out of MKDRONE (see
  MKDRNEW.ASM) first, and that routine hand-unwinds its caller's process
  stack, so it is a refactor rather than a move.

`noobcpu` is unaffected by that second point: its rule is that the CPU uses
only moves a player has, not that it uses all of them.

### Rig

`tools/run_reptile_divekick_test.ps1 -Char noob` - the existing dive-kick rig,
extended with a third character. Noob is a secret fighter and **a select
forced to `ft_noob` never confirms**, so it confirms SCORPION on the grid and
swaps the fighter slot during post-select, the way
`tools/noob_divekick_test.lua` does for the shadow dive.

Measured: `act_reptile_fly` set, body on `NJFLIPKICK3A`, 8px/tick forward and
accelerating down, lands, 26 damage, and the victim goes **60px straight up** -
`r_flipk`, i.e. `stk_rp_superk` and not `stk_slide`. `-Char reptile` and
`-Char kunglao` both still PASS unchanged. The control is a `noobdive 0` ROM:
the same trial reaches the fight as Noob (`p1=15`) and reports
`dive_never_fired` on all four spacings.

**The shadow is ASSERTED, and the expectation is READ OUT OF `noobdive_ghost`**
rather than written into the rig - hardcoding either would make it fail honestly
on a correct build the day the switch moves, which is the kind of failure that
gets a rig ignored. The two are EXCLUSIVE for every character: as shipped, Noob
and Reptile a decoy and no ghosts, Kung Lao neither
(`afterimage_as_expected` / `ghosts_as_expected`). That is what catches the two
regressions worth catching: a gate widened to everybody, and a build that armed
both shadows for Noob. The decoy half is judged on three readings together,
because the copy and the diving man wear the same frame - seen, stayed >= 10
ticks, and he LEFT it (>= 30px of gap, drift <= 4); a `find_afterimage` that had
locked onto the diver would show a drift that tracks him rather than a gap that
opens. The trail half reads the ring directly (`gh_src`, `gh_n`, `gh_snaps`, all
`.global`): armed for THIS fighter for the whole flight, and `gh_snaps`
ADVANCING, which is the half a leftover setup cannot fake. `-Inviso` expects no
decoy, since `superk_afterimage` runs ahead of `clear_inviso` and correctly
skips itself for an invisible man.

## Where the source actually is

There is **no PC or PSX source leak**. `Workplace/Mortal Kombat Trilogy PSX`
is 30 disc `.bin` tracks and `Workplace/Mortal_Kombat_Trilogy_1997` is the PC
retail install — both binaries. The leak with code in it is
`Workplace/MKTRILOGY_source_N64`, the N64 build's C tree, which this repo
already reads for Rain (`tools/make_rainn64_img.py`,
`tools/trilogy_rain_bolt_extract.py`, `tools/import_trilogy_rain_kamel.py`).

Everything below cites it as `SEG/GAMECODE/<file>`.

| Move | Trilogy source | Input table |
|---|---|---|
| Ghost ball | `do_proj_noob_zap` / `noob_zap_proc`, MKZAP.C:414, :430 | `sm_noob_lpc`, MKSCOMBO.S:936 |
| Teleport slam | `prop_do_noob_slam` / `noob_hit`, MKPROP.C:4588, :4514 | `sm_noob_uc`, MKSCOMBO.S:1072 |
| Alter ego | `stat_do_noob_ego` / `noob_ego`, MKSTAT.C:210, :279 | `sm_noob_hpc`, MKSCOMBO.S:981 |

### Reading those input tables

Each `sm_*` record stores the motion **newest first** — the same convention
MK2's own `scom_*` records use, which is why `combo_edit.py` says it takes
inputs oldest-first and reverses them. `sm_noob_uc` stores `sw_up, sw_down`,
which reads as **Down then Up**, and that matches the published Teleport Slam
input. `sm_noob_lpc` stores `sw_right, sw_down` = **Down, Forward**.

`secret_move_search` itself is not in the leak (it survives only as a
prebuilt `.O`), so the convention above is established from the Up/Down case
rather than read off the matcher.

## Damage numbers are portable; reaction indices are not

The two games' strike records are on the **same damage scale**. Trilogy's
`stk_nj_hi_punch` is `0x0b03` and this tree's `stk_njhipunch` is `00b03h` —
identical. So Trilogy's damage words are carried across raw, which is what
the Rain ports above already do.

The **strike routine word is not portable**. MK2 packs `hit<<8 | block`
where the high byte indexes the *attacker's* per-character reaction table;
Trilogy's high byte indexes one flat `reaction_tables[]` (MKREACT.C:41) and
has bit 7 set. Trilogy's `0x8504` means `reaction_tables[0x85]` =
`r_noob_zap`; the MK2 equivalent had to be given a row of its own.

## The ghost ball

**Down, Forward + Low Punch.** `noob_lo_punch` (MOVES.ASM) →
`do_noob_ghost` → `projectile_jumps` slot `2ch` → `do_noob_ghost` /
`noob_ghost_proc` (MKZAP.ASM).

| | |
|---|---|
| Body | TABLE1 `026h`, `a_njzap` — the stock ninja ice-throw pose. Trilogy poses him on Sub-Zero's freeze cast frames too (`SZICEPRO1/2/3`), so this costs nothing. |
| Missile | TABLE2 `00eh`, `a_noob_ghost` (MKNJ.ASM). Three parts: form, a looping flight, the dissolve. |
| Speed | `0a0000h` — Trilogy's `SCX(0xa0000)`, 10 px a tick. |
| Box | `stk_noob_ghost`, `nj_strikes` `27h`. Trilogy's `stk_noob_zap` geometry unchanged. |
| Damage | 5 hit / 2 block — Trilogy's, and see the warning below. |
| Reaction | `r_noob_ghost`, `react_to_nj` `1fh`. |

### The art is the PSX skull, and it is the user's own library

`data/NOOBPROJ.IMG` — 22 frames `RNPSX524`–`RNPSX545` plus one 32-entry
palette `NJP44` — was authored by the user in IMGTOOL and handed to this
port. It is **not** what the N64 build draws this move with: that is
`GHOSTFORM1/3/4/5` + `GHOSTLOOP1/3/5/7` + `GHOSTDISP1-3` in
`SEG/CHARDATA/MNINJA`, a smaller skull on the same idea (11 frames, 16
colours, ~12.6 KB).

**Three filenames, two of them one letter apart:**

| | |
|---|---|
| `data/NOOBPROJ.IMG` | the user's authored source library, 22 frames + `GHSTRNG_P`. In no LOD directly. |
| `data/NOOBPRJ.LOD` / `.IRW`, `src/NOOBPRJ.TBL` | the projectile pack — `GHOSTPROJ1-12`, 9,402 bytes at `0x9C7000`. |
| `data/NOOBRING.LOD` / `.IRW`, `src/NOOBRING.TBL` | the ghost-ring pack — `GHOSTRING1-10`, 13,524 bytes at `0xB7A000`. |

Two packs because together they are 23,157 bytes and no single free run left in
either bank is that big.

### A renderer bug that nearly shipped the wrong reading

The first cut of this port packed 15 of the 22 frames and played the last
three as the ball's *dissolve*. They are not a dissolve — they are the **ghost
ring**, a separate effect drawn on the victim.

What hid it was a preview renderer that assumed `stride == W`. IMG rows are
padded to 4 pixels, and `GHOSTRING3/4/8` are 97/97/98 wide, so the preview
sheared them into diagonal streaks that looked exactly like a ball coming
apart. Rendered at `stride = (W+3) & ~3` they are plainly two skulls orbiting,
swapping sides and changing size with the perspective. LOAD2 always had this
right; only the preview was wrong.

The anipoints said the same thing and were the evidence I should have read
first: every `GHOSTRING` frame's `anix` is **positive** (+30..+45) where every
projectile frame's is negative, because these records are anchored to be drawn
*on* somebody rather than thrown *from* somebody.

### The damage is faithful, not balanced

**5 hit / 2 block is Trilogy's number for a move whose real payload is not
its damage.** In Trilogy, `r_noob_zap` spawns `noob_zap_flash`
(MKREACT.C:396): the victim flickers white for 40 beats (20 against a drone,
~4.4 seconds), a ring of `GHOSTCPLOOP` ghosts circles him, and **Noob is made
invincible** for the whole of it (`set_nocol` + `set_noflip` on
`p_otherguy`).

**That payload is ported (2026-10-06) - see "The curse" below.** The damage is
still Trilogy's 5, which is right once the ball carries the curse.

## The ghost ring, and the victim's flash

`r_noob_ghost` (MKREACT.ASM) spawns `noob_ghost_ring` (MKZAP.ASM) — Trilogy's
`noob_zap_flash` + `noob_ghost` (N64 MKREACT.C:396 and :344) run as one
process. Two skulls orbit the man the ball hit while his body flickers white,
the teleport whoosh loops under it, then the ring fades and he is put back in
his own colours.

| | Trilogy | here |
|---|---|---|
| beats | 40 (20 vs a drone) | `NGR_BEATS` 40 |
| flash | `process_sleep(3)` × 2 | `NGR_FLASH` 3 ticks white / 3 normal |
| ring rate | `init_anirate(4)` | `NGR_RATE` 4 |
| whoosh | every 12 beats, `borrow_ochar_sound(0xc, FT_NOOB)` | `NGR_SND` 12, `tsound 087h` |
| z | `FRONT_Z+5` | `front_z+5` |

### The sounds, traced

Trilogy's ghost ball borrows its whole sound set from other fighters, so there
is no "right" stream to carry over — only the right *kind*:

| Trilogy call | resolves to | here |
|---|---|---|
| `borrow_ochar_sound(0x2, FT_LIA)` cast | `st_lia[2]` = `ST_LIA_FIREBALL` | `tsound 06ah`, the ninja freeze cast |
| `borrow_ochar_sound(0x3, FT_LIA)` hit | `ST_LIA_FIREBALL_HIT` | `hit_or_blocked_sound 0f1h` |
| `borrow_ochar_sound(0x4, FT_LIA)` blocked | `ST_LIA_FIREBALL_BLOCK` | (same call — it covers both) |
| `borrow_ochar_sound(0xc, FT_NOOB)` flash loop | `st_nj[0xc]` = **`ST_SCORP_TELE`** | **`tsound 087h`** |

The last one is a real 1:1: `ST_SCORP_TELE` is the teleport whoosh, and `087h`
is this tree's same sound (`do_noob_teleport` and `do_hh_teleport` both call it
"the teleport whoosh").

### THE TRAP: `--asm-only` never re-runs LOAD2, so the tables go stale

**This cost four builds and looked exactly like a code bug.** The artist
re-saved `data/NOOBPROJ.IMG` with corrected anipoints; every build after that
was `python build.py --asm-only`, which **skips Phase A** and therefore never
re-runs LOAD2; so `src/NOOBPRJ.TBL` kept the anipoints baked in by an earlier
LOAD2 pass and the ROM kept shipping them. The table said `anix 40` while the
IMG said `-50`.

It is invisible because the code is provably innocent — `do_noob_ghost`'s
`adjust_xy_a5` is `(0,0)` — and because the IMG's mtime is newer than
everything, so the art *looks* current. The only thing that compares the two
is:

```
python img_anipoint.py sync-tbl data/NOOBPROJ.IMG src/NOOBPRJ.TBL --check
```

Both Noob tables are now checked in **Phase D**, next to the MK1SKULL guard
that exists for the same reason. A drift now fails the build and prints what
to do (a full `build.py`, not `--asm-only`, then copy `tmp/load2/*.TBL` over
`src/`).

**Rule: after editing anipoints in an IMG, a full `build.py` is mandatory.**
`--asm-only` is for source-only changes.

### Anipoints position the BALL but not the RING

This is the single most confusing thing about the two halves and it is worth
stating plainly:

| | built by | positioned by |
|---|---|---|
| the ball | `get_proj_obj_m` -> `gmo_proc`, **multipart** | the IMG's `anix`/`aniy` ALONE - `adjust_xy_a5` is (0,0) |
| the ring | `gso_dmawnz`, **single-part** | `NGR_DX` / `NGR_DY` in MKZAP.ASM only |

`get_single_obj` (MKUTIL.ASM) copies a record's `isag` and `isize` and nothing
else, so a single-part object's `oxval`/`oyval` **are** its top-left corner
and the anipoints are never read. Proven the hard way: the whole `GHOSTRING`
set was shifted 62 px with `img_anipoint.py`, rebuilt, and the drawn position
did not move by a pixel. Trilogy has the same constraint and solves it the
same way — `adjust_xy_a5(obj_circle, -46, 26)` inside its `noob_ghost`.

So: **to move the ring, edit `NGR_DX`/`NGR_DY`. To move the ball, edit the
anipoints.** The ring's authored anipoints are deliberately left alone.

Both were corrected on 2026-09-28 against measurements on THE DEAD POOL:

- the **ring** was drawing on the victim's head and slightly right of him;
  `NGR_DX -45`, `NGR_DY 60` brings it across his middle.
- the **ball** was spawning about 90 px right and 45 px low — well clear of
  Noob's hands, which the throw pose plainly puts at chest height. The whole
  `GHOSTPROJ` set was shifted `+90, +45`, which also brings `anix` from
  `-47..-70` into `+20..+43`, i.e. roughly half each frame's width, so the art
  is now anchored near its own centre and `adjust_xy_a5(028h, 02dh)` — the
  offset inherited from Ermac's fireball, "out of his hands" — lands it there.

### Two things that will bite

**The lane is named directly, never through `get_char_ani2`.** `a_noob_ring`
belongs to Noob, but the object rides on the **victim** — `get_char_ani2` would
resolve row `0fh` of *his* TABLE2, which for a Jax or a Raiden is an unrelated
animation. It is `.globl`'d in MKNJ and `movi a_noob_ring,a9` in MKZAP, and it
is deliberately **not** in `noob_anitab2`, so nothing implies it is reached
that way.

**Only a7-a12 survive a sleep, and that dictates the loop's shape.** The first
cut held the beat in a `callr` subroutine that slept between `mmtm sp` and
`mmfm sp`. Both halves are wrong: the system stack is shared, so another
process overwrites the saved slots across the yield, and a `callr`'s return
address lives on that same stack and does not survive the dispatcher. It took
the game down — the tell was **Noob's own object going NULL**
(`shape=00000000`) and his x reading 16191 a dozen ticks after the ball landed.
Now a8 is the ring, a9 the lane pointer, a10 the tick counter, a11 the beat
counter, the whoosh countdown is in `p_store3`, and every sleep is inline.

### The curse: he cannot hit, block or throw (`NGR_CURSE`, 2026-10-06)

While the ring is on him the victim **cannot hit, cannot block and cannot
throw**. That is Trilogy's real payload, and both Trilogy builds we can read
agree on it:

| | N64 (C source) | PC/PSX (`MKTRIL.EXE`, Watcom symbols) | here |
|---|---|---|---|
| flag | `PID_NOOB_ZAP_FLASH1/2` process exists | `l_norb_flash` p1:p2 word | `nb_cursed` (RAM.ASM) = his OBJECT, 0 = nobody |
| his strikes | `strike_check`: `q_am_i_noob_zap` -> no collision; Noob also `set_nocol` | `strike_check_a0` asks `q_am_i_noobed` | `strike_check` (JOY.ASM): the target is not the cursed man -> `no_collision` |
| his block | `is_he_blocking && !q_is_he_noob_zap` | same, before `is_he_blocking` | top of `is_he_blocking` -> `ihbn` (all six callers) |
| his throw | toss check refuses | `elbow_check` asks `q_am_i_noobed` | `toss_check` -> `toss_no` |
| length | 40 or 20 beats x 6 ticks - **see the bug below** | 16 x (5 white + 5 black) = 160 ticks, ends early if either bar is empty | **PC/PSX**: `NGR_BEATS` 16 x `NGR_FLASH` 5 x 2 = 160, ends on either bar empty or `winner_status` |
| flicker | white / normal | `character_whites` / `character_blacks` | **PC/PSX**: `jade_white_p` / `shock_black_p` (`ngr_white` / `ngr_black`) |
| damage | 5 in the strike record | strike 0; the reaction does 3, or what leaves him on 1 - **cannot KO**; skipped (and no ring) on an empty bar | **PC/PSX**: `stk_noob_ghost` 0 hit / 2 chip; `NBG_DAMAGE` 3 in `r_noob_ghost` |
| combo count | counts | `dec_my_p_hit` - not a hit in the string | **PC/PSX** |
| 2nd ball on a cursed man | curse moves onto Noob | same: he is freed (`back_to_normal`, no damage), Noob is `takeover_him`'d into the curse | **PC/PSX**: `nbg_backfire` -> `nb_self_curse`; the human may throw it (only the cooldown holds a ball off), the drone still will not |

**The strike gate is decided off the TARGET, not `a8`**, because `a8` is the
projectile's object when a zap strikes. With two fighters, a target that is
*not* the cursed man means the striker is on the cursed man's side, so this one
test covers his fists, his feet and his projectiles. Noob's invincibility is
the same rule seen from the other side, which is how the PC build does it too.
The ring publishes `nb_cursed` alongside `nb_ring_on`, takes it down on every
exit (`ngr_done`, `ngr_die`), and `round_init_longs` clears it.
`NGR_CURSE .set 0` (MKZAP.ASM) makes the ring cosmetic again; the gates read a
zero and do nothing. Still not ported: the victim drawn **translucent**,
because the T-Unit has no translucency.

**Matched to PC/PSX on every row (2026-10-06).** `nb_ring_on` now holds a
ring GENERATION (`nb_ring_gen`), not a flag: on a backfire the new ring on Noob
starts while the old one is still running, and `ngr_release` lets a ring drop
the flags only if they are still its own. Every reader still just tests
non-zero.

**Trilogy's own bug: on the N64 the length is random.** `noob_zap_flash` picks
40 or 20 beats with `am_i_joy()`, which reads `current_proc->pdata.p_flags`,
and `current_proc` is the flash process that was just created.
`process_create` (MKOS.C:77) never clears `pdata.p_flags`, so the bit is
whatever the last owner of that process slot left behind. The PC/PSX build
has no such split - a fixed 160 ticks - and neither does this port.

**The drone does not know it is cursed** - Trilogy's tests `q_am_i_noobed` in
`d_zap`, `stance_wait` and `d_beware` and holds off. There is a TODO beside the
ring check in MKDRONE.ASM; that module is at GSPA's ceiling, so the logic
belongs in MKDRNEW.ASM.

Rig: `tools/run_noob_curse_test.ps1 [-Package] [-Negative] [-Only kinds]`, 2-player Noob v
Jax, private nvram/cfg. 12 trials: the six below plus `dmg` (3 off a full bar),
`cap` (2 -> 1, no KO), `len` (curse held 160), `backfire` (curse on Noob),
`rise` and `slamblock` (the teleport slam, below) - 12/12; `-Negative` fails
the five curse-dependent ones. Three rules, each as a no-ring control and then under a
real ring put on Jax by a real ghost ball: his elbow on Noob (control 24,
cursed 0), Noob's elbow into his held guard (control guarded for 6, cursed hit
through for 24), his throw (control `act_bodyslam` for 28, cursed none). 6/6;
`-Negative` zeroes `nb_cursed` every frame and fails exactly the three cursed
trials. A trial counts only if the attack is seen on the attacker - a close
High Punch is the ELBOW (`0114h`), not `0101h` - and only once Noob is out of
his own post-throw `act_proj_sd` (`0604h`), or his punch never comes out.

## The teleport slam

**Down, Up, no button.** `noob_up` (MOVES.ASM) → `do_noob_slam` →
`propell_table` slot `14h` → `do_noob_slam` / `noob_slam_ride` (MKPROP.ASM).

He rises off the top of the screen, teleports in beside the other man,
springs back **up** into him, and — if he catches him — rides him **down
through the floor**, both re-entering from the top.

**The rise and the block were corrected against PC/PSX on 2026-10-06** (N64
`prop_do_noob_slam` and MKTRIL.EXE's propell agree):

- **He comes up out of the floor on the climb frame, not the throw pose.** He
  re-enters with his top at `ground_y - 060h` (`NBS_SINK`, ~35px below
  standing) still on `NJREPVIC3`, rising at `-0a0000h` under `08000h`, and
  **stays on it for the whole rise** (user, 2026-10-06). The grab window still
  opens only once `oypos - 010h <= p_ganiy` (`NBS_REACH`), but Trilogy's
  `pose_a9(0,ANIM_THROW)` at that point is NOT taken: the sink clears in two
  ticks of a ~20-tick rise, so he was in the throw stance for nearly all of
  it. The throw lane plays only on a catch.
- **Blocked, he is a sitting duck and flips off the blocker**: Trilogy's
  `zoom_blocked` / `noob_tele_blocked` - `act_decoy_sd`, lined up on him and
  16px off **on the side he came up on** (Trilogy's `multi_adjust_xy(0x10,0)`
  after the match moves along the VICTIM's facing, which put him in front of a
  man he had come up behind - the side is now taken before the match and the
  offset written outright), the FORWARD FLIP (TABLE1 7, first frame skipped) on a hop of
  `flight(010000h, -080000h, 06000h, 2)`, then `do_land_animation`. The old
  port fell straight down still in `act_noob_slam`. Measured: 42 ticks of
  `NJJUMPFLIP`, and Jax's uppercut through the hop took 40 off him.
- **The victim's bounce on a catch is PC/PSX's**: `flight(030000h, -0a0000h,
  08000h, 4)` in `noob_slammed` (the N64 had `020000h, -0b0000h`).
- **QUARTER DAMAGE on the bounce**, Trilogy's `set_quarter_damage` (both
  builds): from the slam's own hit until he is back to normal, everything that
  hits him does a quarter, floor 1. It rides the existing `rhhalf` cut:
  `rh_half` is now a SHIFT count (1 half, 2 quarter), `bar_reducer` applies
  it, `back_to_normal` and `round_init_longs` clear it, and arming the half
  never downgrades a quarter. `noob_slammed` sets 2.

**No new art at all.** Trilogy poses him on `ANIM_VICTORY` going up and
`ANIM_THROW` for the grab; here those are TABLE1 `029h` (the victory pose
every `anitab1` carries) and `024h` (the flip/throw pose `body_slam_init`
itself uses).

Every helper Trilogy's C names already exists in this tree **under the same
name**, which is why the port is short:

| Trilogy | here |
|---|---|
| `body_slam_init` | `MKSLAM.ASM:73` — and it already has an `ft_noob` branch |
| `takeover_him` / `sans_repell` | `MKUTIL.ASM:3798` / `:2595` |
| `double_next_a9` | `MKUTIL.ASM:3781` |
| `land_on_my_back` | `MKREACT.ASM` |

### It shares Down,Up with the shadow teleport

`noob_extras`' shadow teleport (`do_noob_teleport`) uses the same motion and
the same `scom_noob_tele` record. They cannot both have it, so the slam sits
in the `.else`: with `noob_extras 1` the shadow teleport wins and the slam is
unreachable, keeping the older move bit-identical. `scom_noob_tele` is not
itself inside `.if noob_extras`, so the record is there either way.

Since `noob_extras` is `0` (its ~63 KB of bank-0 art went to the Dead Pool
hangers), Down,Up is free today.

### Things that will bite

**`oypos` IS THE SPRITE'S TOP, AND TRILOGY'S HEIGHT CONSTANTS DO NOT CARRY.**
This one cost a build-and-rig cycle and is the most transferable lesson here.
Trilogy's `prop_do_noob_slam` writes `oypos = ground_y - SCY(0x60)` before the
spring. Carried across literally, the grab never connected: measured in-game,
a standing fighter's `oypos` is **85** and the floor line (`ground_y`) is
**216** — so `ground_y - 0x60` = 120 put Noob's *top* 35 px **below** standing,
i.e. his feet under the floor, and the grab box swept up from underneath the
other man instead of through him. The rig's tell was unambiguous and is worth
copying: **the victim's y never moved at all** (`jax y range 77..77`) while
everything else about the move — the action code, the climb, the landing
distance — was correct.

The fix is not a tuned constant. `teleport_next_to_a9` has *already* placed him
on the floor beside the man, so the reposition is simply deleted and the spring
starts from there; and `stk_noob_slam` is sized off `stk_njuppercut`, MK2's own
rising attack, rather than off Trilogy's record.

**Signed vs unsigned `oypos`.** The climb reuses `do_noob_teleport`'s
`cmpi NBS_TOP,a0 / jrgt`, which works up there only because `oypos` is
*negative* off the top of the screen. After the teleport he is placed at a
*positive* y above the floor, so every test in the descent and the ride is
signed (`jrlt`, `jrn`).

**`sans_repell` is re-armed every tick of the ride.** `body_slam_init` sets
`f_norepell` to `030h` = 48 ticks, and the through-the-floor ride is longer
than that; letting it lapse lets `repell` shove the two apart while they are
inside each other.

**The victim's velocity is copied from Noob's every tick**, because he is
held for the whole ride rather than xfer'd — otherwise the two separate on
the way down and he lands somewhere else. He is released at the end through
`post_fb_xfers`, the same table `normal_slam` releases into, so every ochar
lands the way it lands out of any other throw.

### Verified

`tools/run_noob_trilogy_test.ps1` -> `tools/noob_trilogy_test.lua`, derived
from the existing `noob_moves_test.lua` scaffolding. Forces P1 = Noob vs Jax,
drives each motion, PASS:

```
ghost_seen         true     GHOSTPROJ1-3 form, 4-12 flight loop
ghost_travel       70       px, while Noob stays put
ghost_noob_static  true
ghost_damage       5        Trilogy's number exactly
ring_seen          true     all 10 GHOSTRING frames - orbit AND fade
ring_ticks         249      on screen, ~4.5s, Trilogy's 40 beats
slam_fired         true     p_action 0212 (act_noob_slam)
slam_climb         234      px off the screen top
slam_gap           62       px from Jax on re-entry
slam_victim_below_floor  true    top 77 -> 147, feet 70px under the floor
slam_victim_above_screen true    y -152, carried back in from the top
slam_grabbed       true     p_action 0212 -> 0507 (act_bodyslam)
```

Confirmed by eye as well as by counter: the ball forms at Noob's hands at
chest height, the ring straddles the victim's middle, and the victim flashes
solid white through it.

**A rig note that cost a cycle.** The detector walked the multipart shape
chain only, so it could not see the ring at all once the ring became a
single-part object — it reported `ring_seen false` on a build where the ring
was drawing perfectly. `obj_frame` now checks `osag` (0x100) first and falls
back to the chain.

### Rigging it: do NOT score on damage### Rigging it: do NOT score on damage

`stk_noob_slam` carries **`damage_hit` 0** by design — the grab hands off to
`body_slam_init` and the slam applies its own damage, so the record's hit
byte is only the chip a *blocked* slam costs.

It is one of twelve records in the build with `damage_hit` 0 (the grabs,
lifts, setups and freezes). A rig that scores "connected" as *damage dealt >
0* reads a perfectly landing grab as a miss — another session lost a Kitana
run to exactly this, because `stk_spinfan` is also 0 and a clean fan lift
scored 0 of 1,485 attempts. **Score on the victim's `p_action` changing, or
on him leaving the ground.**

**And measure the descent against his own standing `y`, not the floor line.**
The same trap one layer down: `oypos` is the sprite's TOP and a fighter is
~139 px tall, so a man standing on a floor at `ground_y` 216 has a top of 77 —
and his top *never* passes 216 however far through the floor he is dragged. A
first cut of this rig compared top against `ground_y` and scored a ride that
plainly happened (top 77 → 147, i.e. feet 70 px under the floor) as "never
went below". `slam_victim_below_floor` now measures `jax_max_y - jax_y0_start`.

## Getting to fight him: the held-Start challenge

`noob_start_override .set 1` (MAINEQU). In a **one-player** game, hold Start
for `noob_hold_ticks` (140, ~2.6s) on the **battle plan** - the mountain
screen between select and the fight - and that match's drone becomes Noob.

The other two routes are unchanged and still off: the 25-match two-player win
streak (`noob_check`, MKTOAST.ASM, live) and the Sub-Zero + Block x5 select
unlock (`noob_select_enable`, 0).

### Why it is counted on the battle plan and not at the handoff

The disabled version tested the switch once inside `set_drone_ochar`, and
that routine picks the drone **before** `do_ladder` draws the battle plan -
so the only thing it could ever catch was a momentary press at one instant.
`kham_ladder_summon`'s comment in the same file already spells this out for
Khameleon, which is why hers runs after `do_ladder`. Noob's now does too:

| | |
|---|---|
| `noob_ladder_hold` (MKSEL.ASM) | counts unbroken ticks off `escape_button_update`, the per-tick hook that already hosts Khameleon's tap counter. Any gap zeroes it. |
| `noob_ladder_summon` (MAIN.ASM) | spends the count after `do_ladder`, beside hers. |
| `c_noob_hold` (RAM.ASM) | the counter. `.globl` at the definition, `.ref` in MKSEL and MAIN - **not** a `.global` in MAINEQU, which RAM.ASM includes and which therefore aborts with SYMBOL USED IN BOTH REF AND DEF. |

### Two measurements behind the numbers

**Start is not an escape button.** `escape_button_update`'s mask is
`p1b0|p1b2|p1b3|p1sf2` (and p2); `p1_start_sw` is a different bit. So holding
it does not skip the screen out from under the count.

**The countable window is 192 ticks (3.5s), not the whole screen.** Only the
four `ladder_sleep` spans run the hook - `030h + 040h + 030h + 020h`; the pan
loop and the closing `sleep 040h` do not. 140 leaves ~50 ticks of slack.
**Do not set `noob_hold_ticks` above ~180.**

### It shares a switch with Khameleon, deliberately

Her summons is five Start **taps**; this is one unbroken **hold**, which
registers as a single tap on her counter and can never reach her five. A
completed hold also clears `c_kham_ladder`, so one battle plan cannot queue
both. The hold wins because it is the harder gesture to perform by accident -
the same reasoning that deleted Jade's High-Punch override on 2026-09-27.

**Not yet verified at runtime.** `tools/noob_hold_probe.lua` exists (derived
from `ladder_char_probe.lua`) but does not get past attract - its coin/start
drive never reaches the select screen, with or without the CMOS cleared.
That is a rig fault, not a ROM one, but the feature is reasoned correct
rather than measured correct.

## Not ported: the alter ego

Trilogy's third special (`stat_do_noob_ego`, HP-close) spawns a second Noob
that **runs** at the opponent and either throws him or explodes. Two reasons
it is out:

- **MK2 has no run lane.** Running is an MK3 invention; there is no
  `ANIM_RUN` for the clone to use. Making it walk is a redesign, not a port.
- The explosion itself would be nearly free — `get_ego_and_vel` (MKFX.C)
  draws 36 flying pieces of **Reptile's spit glob** recoloured to
  `SHADOW_P`, and this tree has both.

The user's direction was to try another ninja walk animation sped up. That is
the obvious next step and is not attempted here.

## Also not ported: the ghost-ball stun

Covered above under the damage note — `noob_zap_flash` and `noob_ghost`
(MKREACT.C:396, :344). Beyond the balance question there are two hard
blockers:

- the ring of ghosts needs **hardware translucency** (`M_XLU_ON |
  HALF_XLU`), which the T-Unit has not got;
- `GHOSTCPLOOP1-4` have headers in `MKNJ.ATD` but **no pixel data anywhere in
  the leak** — the N64 build references them and never packs them.

## Files

| file | what changed |
|---|---|
| `src/MAINEQU.ASM` | `noobghost` / `noobslam`; `act_noob_ghost 011fh`, `act_noob_slam 0212h`; `nj_stk_noobghost 027h`, `nj_stk_noobslam 028h` |
| `src/MKZAP.ASM` | `.ref NBGHOST_P`; `projectile_jumps` `2ch`; `do_noob_ghost` + `noob_ghost_proc` |
| `src/MKPROP.ASM` | `propell_table` `14h`; `do_noob_slam` + `noob_slam_ride` |
| `src/MKNJ.ASM` | `.INCLUDE NOOBPRJ.TBL`; `a_noob_ghost` lane; `noob_anitab2` row `0eh` |
| `src/MOVES.ASM` | `noob_lo_punch` D,F test; `noob_up` `.else` branch; two stubs; `scom_noob_ghost` |
| `src/MKSTK.ASM` | `stk_noob_ghost`, `stk_noob_slam` + `nj_strikes` rows `27h`/`28h` + their guards |
| `src/MKREACT.ASM` | `r_noob_ghost`; `react_to_nj` row `1fh` |
| `src/IMGPAL6.ASM` | `NBGHOST_P` |
| `src/NOOBPRJ.TBL` | generated by LOAD2 — do not hand-edit |
| `data/NOOBPRJ.LOD` | the pack; `data/IMGBUILD.BAT` runs it |
| `makevrom.py` | bank map, slot `0x9C7000..0x9CB000`, `irw_files` |
