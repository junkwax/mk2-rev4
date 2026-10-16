# Pre-beta tester feedback - triage and worklist

Raised by testers before the beta drop. Each item below has been traced to
the code that actually decides it, so the next session starts at the edit
rather than at the search. Status is one of **DONE**, **READY** (site
found, change agreed, not yet made), **NEEDS A NUMBER** (site found, the
magnitude is a design call), or **OPEN** (still needs root-causing).

Frame numbers quoted here come from `doc/FRAME_ADVANTAGE.md`
(`tools/frame_advantage.py`). One tick = 18.28 ms.

Everything marked DONE below is in the source and builds clean. **None of it
has been played yet** - the fixes are static-analysis-grade, not
playtest-grade, and items 6 and 7 in particular want a look on screen.

---

## 1. Low-kick family rebalance  -  PUSHBACK KEPT, TIMING REVERTED

Two of the seven asks were about WHEN the low kick recovers and five were
about how far it shoves.  The shoves are in and staying.  The timing change
was built, played, and taken back out.

### What is in the ROM

`r_lokicked`, `r_duckkickedl` and `b_lokick` (MKREACT.ASM) carry raised
separation.  All three are cleanly scoped: across all 262 strike records
`r_lokicked` is reached only by `do_lo_kick` and `r_duckkickedl` only by
`do_duck_kickl`, so none of it leaks into another move.

| ask | done |
|---|---|
| LK standing hit pushback up | `r_lokicked` `away_x_vel` `020000h` -> `030000h` |
| LK block pushback up | `b_lokick` `020000h` -> `030000h` |
| blocked LK still unsafe | **-26**, unchanged |
| crouching LK hit pushback up | `r_duckkickedl` `030000h/070000h` -> `040000h/080000h` |
| crouching LP always pushes back | root-caused and fixed - see below |
| LK recovery reduced | **reverted, see below** |
| all LKs safe on hit | **reverted** - back to retail's -18 |
| LK on-hit opponent recovery up | **never built** - hitstun is still 20 |

**`b_hikick` and `b_lokick` were one label**, falling through, so the low
kick's blocked shove could not move without the high kick's.  Split; only the
low kick's changed.  That split stays.

### Why the timing went back

The safety was bought entirely out of the attacker's side.  `do_lo_kick` got
its own tail, tested `b2` (strike_check's blocked flag) and skipped the whole
18-tick hangtime on a clean hit: recovery on hit went 38 -> 20 against an
unchanged 20 of hitstun, so the kick landed on exactly **+0**.

The arithmetic was right and it played wrong.  18 ticks is 329 ms, and every
other normal in the game still pays it, so the low kick became the only move
whose leg snapped back the instant it connected - the attacker finished
recovering before the victim finished reacting.  The hangtime IS the impact.

The third ask is why it had to come out of the attacker's side at all:
**"LK (on hit) opponent recovery increased" was never implemented.**  With
the victim's hitstun left at retail's 20, the only lever left for "safe on
hit" was deleting the attacker's hold.  Paying for it on the victim's side
instead - a trailing hold in `r_lokicked` plus a shorter (not absent)
hangtime - would land on the same +0 with the impact intact.  That is the
version to build if the family is revisited.

Reverted to stock: `do_lo_kick` falls through into `kick2` again, the
hangtime is paid on ANY contact, and `ochar_lk_retract` / `lkret_std` /
`lkret_fn` went with it (they only existed to land every character on the 20
ticks that made the 0 come out).  `tools/audit_char_tables.py` dropped the
table from its Phase D list.

Measured after the revert (`tools/frame_advantage.py`): whiff 32, block 44,
hit 44; **-18 on hit, -26 on block**, and -22/-30 for the four female ninjas
whose retract lane is six frames rather than five.  All of that is retail.

**Crouching LP "now always causes pushback"** was a real bug, not a tuning
value. `r_duckpunched` called `repell_one_of_us` *above* its ducking test, so
both paths looked covered - but the standing path falls into `r_lopunched`,
which calls `reaction_start_abc` a **second** time, and `reaction_start_chores`
ends with `calla stop_me`. The velocity was thrown away before it moved
anybody. A crouching jab into a standing opponent separated the two by
nothing; the same jab into a crouching one shoved him. Each path now pushes
after the last thing that could stop it.  Unaffected by the revert.


### The lock now covers pushback

`doc/balance.lock` grew a `[pushback]` section: 39 `away_x_vel` /
`repell_one_of_us` magnitudes, per reaction handler. Four of this pass's
changes were balance values that the lock did not see - the build stayed green
while they moved. It would not now.

## 1b. Roundhouse / uppercut vs crouch block  -  DOES NOT REPRODUCE

Measured with `tools/run_crouchblock_test.ps1`: the two fighters are pinned at
an exact offset which is **swept** 40 -> 112px, P2 is confirmed in
`act_blocklo` (0701h), and contact is read as damage off P2's bar.

| | connects at | damage |
|---|---|---|
| roundhouse vs standing block | 40, 52, 64, 76, 88, 100 | **8 x10** |
| roundhouse vs **crouch** block | 40, 52, 64, 76, 88, 100, 112 | **8 x10** |
| uppercut vs standing block | 40, 52, 64, 76, 88 | **10 x8** |
| uppercut vs **crouch** block | 40, 52, 64, 76, 88 | **10 x8** |

8 is `stk_*roundh`'s chip byte and 10 is `stk_*uppercut`'s. **Both moves
connect at every distance in range, against a crouching guard exactly as
against a standing one, and are cleanly blocked.** Nothing passes through and
nothing whiffs. The few misses are at 100-112px on the uppercut, whose reach
is 75-78 - that is correct.

### The earlier "confirmed" result was a rig bug, and it was mine

The first four runs reported the roundhouse connecting only at 40px against a
crouching guard, and the uppercut at no distance at all against a standing
one. That was **P2 dying mid-run**. The sweep harness pins P1's bar, not P2's,
so 17 chips at 8 apiece took P2 from 161 to nothing during the FIRST phase;
the round then ended, `gstate` left 2, the addon returned early and every
later phase ran on a corpse. The giveaway in hindsight: the crouching rows
connected only at the FIRST distance step of their sweep.

Pinning P2's bar - reading the damage delta each frame *before* refilling it,
since chip is the contact signal - changed rh_crouch from 3/20 to 10/11 and
up_stand from 0/20 to 8/12.

On the strength of the bad measurement, all nine `stk_*roundh` y_sizes had
been normalised to a box bottom of `oypos+77`. It changed nothing (still 3
connects, still 40px), which is what prompted the re-examination, and it was
**reverted** rather than shipped. `src/MKSTK.ASM` is unmodified.

### What is left, and it is a question not a bug

If "connect against crouch block" was meant as **"beat crouch block"** - a
roundhouse being a high attack that a crouching guard should not stop, i.e.
32 damage instead of 8 chip - then that is a deliberate design change, not a
fix, and a large one: it makes two moves per character unblockable while
crouching. It is cheap to implement (a block-height rule of the kind
`is_he_blocking` already applies via the record's flags - `sf_duck` marks a
move that must be blocked LOW) but it needs to be asked for explicitly.

Ask the testers which they meant before anything changes here.

## 2. Sub-Zero ground ice hitbox  -  DONE

`stk_floor_ice` [MKSTK.ASM](../src/MKSTK.ASM) is now **sized off the art**
instead of by feel, which is what "cover the entire Ground Ice" asks for.

The active puddle is one frame. `floor_ice_proc` (MKZAP.ASM) plays part 1
(FLRICE1-6, the ball forming), then part 2 - a single frame, **FLRICE7** -
and sits in its `fip5` strike loop on that frame for the whole
`floor_ice_time`. FLRICE8-13 are the melt, by which point the strike check
has stopped. So FLRICE7 is the entire question:

```
NJFLOORICE7   .word 114,21,-54,-128        W,H,anix,aniy
```

A piece's world edge is `oxpos - dx`, and `strike_check` builds an unflipped
attacker's rect as `[oxpos + x_offset - x_size, oxpos + x_offset]`. So the
puddle is drawn across `oxpos+54 .. oxpos+168` while the old `09dh`/`060h`
box covered `oxpos+61 .. oxpos+157` - **11px short at the front**, the far
end an opponent gets knocked onto, and 7px short at the back. Y was 16 tall
against 21 drawn.

| | was | now |
|---|---|---|
| x_offset | `09dh` (157) | `0a8h` (168) = `-anix + W` |
| x_size | `060h` (96) | `072h` (114) = `W` |
| y_size | `010h` (16) | `015h` (21) = `H` |

`doc/balance.lock` regenerated - this is the only balance value that moved.

## 3. Kung Lao uppercut, missing frame 3  -  DONE

`TMUPPERCUT3` listed its third piece as `TMUPPERCUT3B` - the hat - twice,
so `TMUPPERCUT3C` (23x123 at anchor -18,-24, the trailing arm; the exact
counterpart of `TMUPPERCUT2C` and `TMUPPERCUT4B`) was never drawn. Fixed at
[MKHH.ASM:822](../src/MKHH.ASM#L822).

This is the "inline ASM sprite records rot" class: the piece list lives in
`.ASM` and no promoter checks it against the `.TBL`.

**The sweep was run.** `tools/audit_multipart_lists.py` checks all 2,286
piece lists in `src/*.ASM` against all 10,201 piece records in `src/*.TBL`
and reports two things: a piece drawn TWICE in one list (never legitimate -
pieces carry their own dx/dy, so drawing one twice puts it in the same
place), and a piece that exists with drawn siblings but is referenced
nowhere. Both together is the Kung Lao signature, and it flags that as
CONFIRMED.

Result: **CONFIRMED none** after the fix - Kung Lao's was the only duplicate
in the game. The weaker UNDRAWN list found one real second instance and
three false positives:

- **Kintaro's get-up, FIXED.** `TIGERGETUP3` and `TIGERGETUP4`
  ([MKGORO.ASM](../src/MKGORO.ASM)) each drew A-D while the `.TBL` carries
  A-**E**. The dx values march steadily leftward - 23, 4, -14, -40, -66 -
  so E is the continuation strip, and both frames were losing their leftmost
  ~30px. Frames 1 and 2 have only the parts they draw, so the lane is
  otherwise consistent. Now draws A-E.
- `RN1DETHBOLT1A` / `RNVICBOLT1A` - not missing, deliberately replaced by
  `KLUDGE_RN1DETHBOLT1A` / `KLUDGE_BOLT1A` in MKRD.ASM.
- `SOULSUCKKT1B` / `SOULSUCKKT2B` - the FNDRAIN lane draws A only, and
  `SOULSUCKKT3` has no B at all, so A-only is consistent across the lane.
- `tornado7C` - a 3x2 speck, and the ~80 `*HANG1*` entries are the Dead Pool
  corpse slices, which are placed by code rather than by a literal list.

`--check` exits non-zero on a CONFIRMED, so it is ready to wire into Phase D
if you want the class gated rather than audited.

## 4. Reptile stays invisible when blocking certain moves  -  DONE

Invisibility is `m_inviso` on `oflags2`, set by `do_inviso`
[MOVES.ASM:5867](../src/MOVES.ASM#L5867) and watched by `inviso_proc`, which
dies as soon as something else clears the bit.

The reveal lives in `reaction_start_chores` (MKREACT.ASM, `andni m_inviso`).
Both `reaction_start` and `blocked_start` route through it, so the *ordinary*
block path already reveals him. Two kinds of contact never reach it, and both
are now covered by **`reveal_a8` / `reveal_otherguy`**
([MKUTIL.ASM](../src/MKUTIL.ASM), next to `clear_inviso`):

- **A move that consults `is_he_blocking` itself** and then declines to
  transfer the blocker. Only two callers exist outside the strike path, and
  they behave differently:
  - `sahp_fire_victim` / `sahv_he_blocked` - Baraka's helicopter dive.
    The blocker keeps his own process and eats `SAHV_CHIP` off the bar.
    Chip came off, so the contact is real: **reveals** now.
  - `do_raiden_shocker` / `useless_shock` - the blocker is left completely
    untouched, no damage, no reaction. That is a whiff, not contact:
    **deliberately does not reveal**.
- **A reaction handler that exits before its own `reaction_start`.** Scanning
  every `block_xfers` target for a path to `blocked_start` found exactly one:
  `r_floor_ice` (row 15, so it is a *block* handler as well as a hit one).
  Its "no ice proc" and "I am free of this ice" exits jump to
  `reaction_exit` first. Damage is already off the bar by then: **reveals**
  now.

`reveal_*` is **guarded** rather than a bare `clear_inviso`, and that is the
point of having a routine at all - `clear_inviso` also turns `m_shadow` back
ON, so calling it blind hands a shadow to anyone who deliberately dropped
one. Only a fighter who was actually hidden is touched.

Not yet confirmed against the tester's repro: they said "certain moves"
without naming them. If it still happens, the next place to look is contact
that never enters `block_xfers` at all.

## 5. KOUNTER / PUNISH / REVERSAL callouts  -  DONE

A red word with a black shadow, about the middle of the screen. It **flies in
from the fighter's own edge of the screen**, coasts to a stop, sits for 1.3s
and flies back out - MK3's combo message, ported tick for tick (see below).

It is drawn the way MK3 draws its own: **one DMA object per glyph**, in the
font the credits line uses (`rd11font` / `vfont*`, MKTEXT.ASM - the "2 CREDITS
TO START" font), through the shared object text engine `cot_*` in MKDISP.ASM.
Not `PIXBLT`: that can only expand 1bpp glyphs the CPU can read, which is
`sysfont` and nothing else, while these are image-ROM art blitted in
constant-colour mode. It still costs **no art** - the glyphs are already in
the ROM.

The engine picks the font **per character**: `0-9` come from `MK2FONT0-9`, the
15-point digits, and everything else from the small letters. That is where the
numbers being big and the words being small comes from, and it means a line
has two heights in it - so the layout hangs off the **baseline**, with each
glyph sitting its own font's line height above it.

Behind `hudcall .set 1` in [MAINEQU.ASM](../src/MAINEQU.ASM) (it has to be
there, not in MKDISP - JOY, MOVES and MKREACT all test it). The knobs are
`hudcall_rev` and the five numbers of the flight, all of them MK3's.

### What decides the word

At the clean-hit path (`block_is_useless`, JOY.ASM - where a13 is certainly
the attacker and a6 already says which bar is about to be reduced),
`hud_callout` walks a ladder, first match wins:

| # | word | when |
|---|---|---|
| 1 | **FIRST HIT** | the round's first clean hit, `cal_first` |
| 2 | **BLOCK PUNISH** | victim in `06xx` recovery, and the strike he is recovering from was BLOCKED |
| 2 | **PUNISH** | same, but that strike HIT |
| 2 | **WHIFF PUNISH** | same, but it touched nothing at all |
| 3 | **ANTI-AIR** | he is in one of the four jump attacks, its strike window is still live, he is off the ground and I am not (narrowed - see 13) |
| 4 | **REVERSAL** | his attack started within `hudcall_rev` ticks of becoming actionable |
| 5 | **KOUNTER** | he was attacking (`01xx`) and got hit out of it |

MK2's action codes are categorised by their high byte, which makes most of
that nearly free. `05xx` (`act_reacting`) is deliberately excluded from every
rung - hitting a man already in a reaction is a combo, and a word on each hit
of a juggle would re-arm the flight on every hit. `act_upcutted` is `0606h`, a
06xx that is a *reaction* rather than a recovery, so it is excluded by name.

**The punishes sit above REVERSAL on purpose.** "You punished the recovery"
says more about an exchange than "you came out of stun fast", and the two
overlap constantly: a block punish starts on the first actionable frame out of
blockstun, which is a reversal by `hudcall_rev`'s own test. With REVERSAL on
top the punish words would almost never appear.

### There was a detour through DMA objects

The word was built once in the 15-point MK2 font (`rd15font`) as one DMA
object per glyph at `oscale` half, which is how MK3 draws its own combo
message. It works and it is in the history, but it is **not** what ships: the
style that was chosen is the readout's, and the readout is `sysfont` on the
CPU path. Two features that sit inches apart on the same screen should not be
two different fonts.

Worth keeping from it, because it is the reason that font cannot go down the
CPU path if it is ever wanted again: `rd15font`'s glyphs are image-ROM art
blitted in **constant-colour** mode (`dmacnz`), where the art is a mask and
`oconst` supplies the colour. `PIXBLT` cannot read it. Drawing it means
objects, on the model of `strnchar` (DIAGTEXT.ASM), and the trap there is that
`oscale` scales the ART but not the LAYOUT - the advance has to be halved too
(`(isizex + 2) >> 1`), or you get correct letters at double spacing.

### Two producers, one queue

The callouts and the combo readout both queue into `hud_list`, and putting
them back on the same path broke two things that had each been fine alone:

- **`HUD_MAXS` was 6.** The readout is four records (two lines, each a shadow
  and then the text), the callouts two each, and both players can have both:
  4x2 + 2x2 = **12**. `hud_str` drops a record when the queue is full, so at 6
  whichever producer ran second silently lost its word with nothing to say so.
- **Record indices are not fixed.** `hud_callout_draw` queues *before*
  `hud_combo_draw` at `dsa9`, so the readout's four records start at index 0
  only when no callout is up, and slide by two per callout on screen. The
  hudcmb rig assumed index 0 and read a live KOUNTER as a broken readout; it
  now finds its records by content.

### Telling a whiff punish from a block punish

This is the only one that needed new state, and the naive place to keep it
does not work. What separates the three punishes is what the victim's last
strike DID, so `cal_last` holds one of CAL_NOTHING / CAL_BLOCKED / CAL_HIT:

- **set** at the two contact points - `strike_blocked` and `block_is_useless`
  - both of which already have `a6` resolved to which bar is being reduced,
  so `a6^1` is the attacker without needing `procid`, and unlike `procid` that
  is right for a projectile too.
- **reset** by `cal_watch`, on the `p_stk` edge. `p_stk` is the strike table a
  fighter is striking with right now, so 0 -> nonzero is "a new strike is
  live", and it is the only signal in the game that means exactly that. The
  obvious alternative - reset at the end of the move - is thirty scattered
  sites in MOVES.ASM alone, and one of them missed leaves a stale answer that
  reads as the WRONG punish rather than as no punish.

### ANTI-AIR could not use am_i_airborn

`am_i_airborn` reads the attacker's object out of **a8**, and strike_check's
own comment says why that is not safe here: *"a8 can be a projectile object"*.
On a fireball hit it measures the FIREBALL's height against the THROWER's
ground line and answers about neither of them. `cal_airborn` (MKDISP.ASM) asks
the same question off `p1_obj` / `p1_proc` instead, so a man standing on the
ground whose projectile stuffs a jump-in gets the anti-air he earned.

### The combo count is hudcmb's, not this one's

An **N HIT COMBO** word was built here first, armed from `back_to_normal` the
way MK3 arms its combo message. It has been **removed**: `hudcmb` is a second,
independent count of the same thing - a live readout that ticks up per hit and
carries the damage total - and two announcements of one combo is one too many.
This feature is the WORD; the count is hudcmb's.

### The entrance is MK3's, not an approximation of it

MK3 announces a combo by sliding `N HITS` / `NN% DAMAGE` in from the side, and
that is what this borrows: `fx_combo` / `setup_combo_message` /
`slide_combo_msg` in MK3's `MKFX.ASM`. The numbers are copied, not tuned:

| phase | ticks | what happens each tick |
|---|---|---|
| slide | `15h` | `x += xvel`, then `xvel -= xvel>>3` - MK3's own "damping to look kool" |
| coast | `2` | `x += xvel` at whatever the damping left |
| park | `48h` | `xvel = 0` |
| out | `10` | `xvel = -(entry velocity)`, then it is gone |

105 ticks end to end, 1.9s, of which 1.3s is the word standing still. Entry
speed is MK3's `0f0000h` - 15 px/tick.

Three details are worth writing down because getting any of them wrong still
*looks* like a slide:

- **Move first, then damp.** MK3's object mover adds `oxvel` to `oxpos` for
  the whole list *before* the process owning the object gets its slice, so a
  tick is always move-then-damp. Damping first loses the first frame of travel
  and lands the word 13 pixels short.
- **The two sides start differently, and that is deliberate.** Off the left is
  `-(width of the word)`; off the right is `scrrgt` whatever the word is. MK3
  has the same asymmetry (`osizex` one way, `scrrgt` the other). Because the
  travel is fixed, it lands every p1 word on the same **right** edge (114) and
  every p2 word on the same **left** one (284) - the two sides mirror about
  the middle of the screen without anything measuring a centre.
- **The word is the ATTACKER's, so it comes in on the attacker's side.** MK3
  reaches the same rule from the other end: `fx_combo` is created by the man
  being *hit*, and starts from the edge away from him.

`hud_strwidth` (MKDISP.ASM) is the one thing MK3 did not need - it read the
width off the sprite's `osizex`, and a font has to be measured instead. It
walks the same directory `hud_string` draws from and adds the same width+1 per
glyph, so it stops exactly where the drawer would.

### Sliding in needed a left edge on hud_string

`hud_string` used to reject any record with a negative x outright, which would
have made a word entering from the left **pop** into place at x=0 instead of
uncovering. Clipping it properly turned out to be free: `pageaddr` carries
`xpadding`, so a dest x of 0..55 lands in the page's own left padding - real
memory, off the visible raster. A glyph hanging off the left edge is simply
drawn there. Only glyphs further out than the padding are dropped, because
those would give the XY address a negative x and write into the END of the row
above.

The advance had to change with it: `add a7,a3` carries out of the x half into
the y half the moment x crosses `0ffffh`, which a negative x eventually does.
`addxy` adds the halves separately and cannot.

### The window had to be measured, not guessed

At `hudcall_rev = 8` the distribution was **39 REVERSAL : 1 KOUNTER : 0
PUNISH**. Under any pressure at all the next attack follows a `reaction_exit`
inside 8 ticks, so REVERSAL outranked everything and the word never left the
screen - the exact opposite of "recognizable but not distracting". At **3**,
which is what a reversal actually means (the first actionable frame), the same
fight gives **26 : 7 : 1**.

### Verified

`tools/run_hudcall_test.ps1`. Every arming is cross-checked against the
victim's action **read independently** on the same frame - a rig that only
counted armings would pass a routine that always said PUNISH.

The flight is checked the same way, and for the same reason: "it slides" is
not the claim, "it slides on MK3's numbers" is, and only a position-by-position
compare can tell those apart. The rig recomputes MK3's curve from the constants
in `MKFX.ASM` - written out again in the addon rather than read from the ROM,
which would agree with whatever the ROM happened to hold - and compares every
frame of `cal_x` against it. The start is included, with the word's width
measured independently out of `sysfont`.

Latest run: **34 callouts, 0 mismatches**, drawn on 2329 frames,
`f_doscore=1`; **26 complete flights, 0 off MK3's curve**, 7 cut short by a
re-arm (MK3 does that too - `fx_combo` opens by killing any message already
up). p1 enters at -41 and parks at 58; p2 enters at 384 and parks at 284,
which is what the model says to the pixel.

An arming is `cal_arms` ticking over now. It used to be "`cal_tick` jumped back
to full", which the slide made meaningless: `cal_tick` is a phase clock and
reaches a maximum three times in one callout's life.

Two rig traps worth keeping: `hud_count` is zeroed by `hud_pass` every frame
("consume the list"), so Lua always reads 0 - use the `hud_drew` sentinel
instead; and an arming is `cal_tick` jumping back to full, not `cal_word`
changing, or a word re-arming as itself is invisible and 2341 frames of
drawing get counted as "4 callouts".

The rig deliberately stress-tests at point-blank with both players mashing, so
its callout frequency is a ceiling, not what play looks like. Whether 1.4s
still feels right in a real match is a judgement to make on screen.

## 6. Reptile frozen mid-Acid-Spit loses his face  -  DONE

**Reptile's acid spit draws his head as a separate slave object.** `a_spit`
[MKNJ.ASM](../src/MKNJ.ASM) is four parts: NJREPSPIT1/3/4 is the body and
SPITH1/3/4 is the face, and `do_spit` / `do_rp_airspit`
([MKZAP.ASM](../src/MKZAP.ASM)) carry the face on its own object,
re-anchored to the body every tick by `match_ani_points` inside
`face_sleep`. The body frames underneath have no face of their own.

`reaction_start_chores` deletes every slave ("no slaves !!"). Every reaction
does that - but every *other* reaction then runs its own `animate_a9` a tick
later and paints over the result. `r_ice` is the one that does not: it holds
whatever frame the victim was on and freezes it for `080h` ticks. That is
the charm of the move (frozen mid-kick) and also the only way a broken pose
can stay on screen. Freezing Reptile mid-spit took his head off and held the
picture for two and a half seconds.

**He keeps the pose, and his face keeps its own colours.**

The face has to stay its own object. It carries its **own palette** -
`REPHED_P`, 5bpp/32 entries, where the body is 6bpp/64 - and
`get_multi_obj` reads `icmap` off the **first piece only**, so a multipart
object has exactly one palette. Merging the face art into the body's chain
was tried and reverted for that reason: the geometry would have been perfect
(a piece sits at `oxpos - dx`, and `match_ani_points` aligns the two
anipoints, so the pixel lands identically) but the face would have been drawn
in the body's frozen ninja ramp.

So `r_ice` rescues the face object **before** chores can delete it - it
detaches it from `p_slave`, so `delete_slave` finds nothing - and then owns it
for the whole freeze:

- **Colour.** `freeze_spit_face_pal` ([MKZAP.ASM](../src/MKZAP.ASM)) `swpal`s
  it to **`REPFFRZ_P`**, extracted from ALLDUDES.IMG palette record 69 into
  [IMGPAL4.ASM](../src/IMGPAL4.ASM). Record 70 there is `REPFFR1_P`, the
  matching thawed palette - byte-for-byte identical to the `REPHED_P` already
  linked, so no duplicate was added.
- **Anchor.** The `sleep 080h` is now 080h ticks taken one at a time with a
  `match_ani_points` on each, so the face rides `shake_him_up`'s jitter and
  any flip. The counter lives in `p_store2`, not a register - `match_ani_points`
  is a `calla` and nothing promises a11 across one.
- **Drop.** `freeze_wakeup` deletes it via `frzface_delete_a0` *before*
  `player_normpal`, so the two palette releases happen in the order they were
  taken, and clears `p_store1` so a later freeze cannot delete it twice.

It goes back on its own: `swpal` balances its refcounts, `delobjp` releases
the frozen map, and the next spit builds a fresh face off `icmap`. Measured -
`palcnt[7]` and `palcnt[11]` both return to 0 and the next spit comes back up
on `0707`.

### Two failures this went through, and why the design is what it is

Both were found by A/B behind the `frzface` switch, not by reading.

**1. It locked the game up at the thaw.** The first version ran the anchor
from its own process (`frozen_face_proc`, own pid, self-terminating on an
`oshape` change). With the path off, the same rig thawed clean at t=207 and
the sweep passed; with it on, the lockup was at exactly t=207 - in `freepal`'s
`lockup ; negative palette count, oh shit !!` guard. `A0=ffffffff` is
`dec a0 / jrnn` failing, and `A1` resolved through `palram + n*palrsiz` to
colour map **#9**, which a per-frame `palcnt` probe then caught the body being
moved onto at t=51 and drained to zero underneath.

The cause was ownership. A gmo object's multipart RAM lives inside its dummy
**process's** data block, so keeping the face alive already costs one process;
a second one on top, owning that object from outside the process that rescued
it, is what the palette bookkeeping did not survive. One owner, one delete.

**2. The face outlived the freeze.** Reported from playtest: "the face stays
on screen after the freeze is done and the body disappears." `freeze_wakeup`
is **not** the only way out of `r_ice` - being hit, shattered or finished
transfers the process to another reaction and r_ice's cleanup never runs at
all. A face only `freeze_wakeup` can remove therefore outlives every takeover.

Fixed by putting the face **back into `p_slave`** once chores has been and
gone. Every reaction runs `reaction_start_chores` and chores deletes
`p_slave` - so the engine's own invariant now reaps it on every exit r_ice
does not control, and `freeze_wakeup` just calls `delete_slave` for the
ordinary one.

### What is verified

`tools/run_reptile_frozen_spit_test.ps1` - both sides spam until an iceball
lands during a spit; the freeze is never timed, because scripting one on input
timing is known here to burn runs. `-Break` walks Sub-Zero in and punches him
out of the ice instead, which is exit (2).

| | normal exit | `-Break` (hit out of it) |
|---|---|---|
| left the ice | t=207, ice expired | t=155, `act=0503` |
| `p_slave` registered | yes | yes |
| face gone at +4 ticks | yes | yes |
| verdict | PASS | PASS |

**The rig was checked against the bug**, which is the part that makes the
PASSes mean anything: with the `p_slave` re-attach removed it reports
`p_slave=00000000 match=false`, `LINGERING FACE`, `problems=3`, FAIL.

Two rig traps worth keeping in mind if you extend it: object slots are pooled,
so his *next* spit reuses the same address (identity is by palette, not
pointer), and the exit-tick sample is too eager - the taking-over reaction
deletes `p_slave` inside its own chores, so the verdict is sampled four ticks
later.

## 7. Raiden alt palette flips to red on knockdown / teleport  -  DONE

Not a Raiden bug and not a select-screen bug - a **mirror-match rule that
predates manual costumes**.

`player_normpal`'s tail (`pnorm_check_temp_alt`,
[MKGUYS.ASM](../src/MKGUYS.ASM)) decides which half of a mirror wears the
alternate costume by reading the *other* man's `b_ugly_pal` and nothing
else. That is correct only while a mirror pair can be exactly
`{default, ugly}`, which is what `make_player_obj` produces on its own: P1
keeps `character_palettes_1`, and `check_same_character_pal` hands P2
`m_ugly_pal`. Each man looks at the other, sees the opposite of himself, and
they agree.

A **manual** costume breaks the agreement. If the opponent picked one at
select (Start+HP/HK/LK/Coin/LP), `make_player_obj` takes his `repaltN`
branch and never reaches `check_same_character_pal` - so he is legitimately
NOT ugly, and the default-costume player, reading one bit, concluded he must
therefore be the ugly one and flipped himself to `character_palettes_2`.

For Raiden that is `RADRED_P`. It only showed after the first palette swap
because `pb_alt_pal` gates the whole tail - and Raiden always swaps, his
lightning and his teleport both do. Hence "the moment he gets knocked down
or teleports, he turns red", and the tester's own instinct that it was
"borrowing lightning color" was pointing at the right trigger.

The honest question is "is he on his DEFAULT costume", so the test now asks
that: `m_ugly_pal | m_start_alt_pal | m_repalt2..5_pal`. Zero means he is on
his default and I take the alt; anything else means I stay on mine. The
retail `{default, ugly}` case is unchanged in both directions.

Applies to every character, not just Raiden - Raiden is only the one who
swaps palettes often enough to have found it.

## 8. AI loses to spammed Cage ceiling uppercut  -  DONE

**A missing table row, not an AI gap.** `beware_lookup` (MKDRONE.ASM) maps the
opponent's action to a reaction handler through `catagory_table`, and
`counter_propell`'s row **20f** - `act_jc_ceiling` - was a literal `0`,
"no handler", under a comment reading *"unused: act_jc_ceiling never set"*.

That comment was wrong. `do_jc_ceiling` (MKPROP.ASM) sets the action on its
third instruction. So the drone's threat system could not see the move at all,
and the tester's "basically destroys them when spammed" is exactly what a
handler of 0 produces. Row 211 immediately below carries a note about the same
class of bug being fixed once already.

Row 20f is now **`drone_block`** - not an evasion, because the move rockets
off-screen and **teleports to 28px in front of you**; there is nowhere to go.
That is precisely the case the other `drone_block` rows are commented "there
is nothing to gain by guessing". It guards, then punishes the landing if it is
close enough, which turns spamming it into a losing trade.

### Measured, before and after

`tools/run_jcceiling_test.ps1` - Cage spams the move at a drone, and the
DAMAGE says which of three things happened: ~29-40 clean, ~6-10 guarded (chip),
0 whiffed. P2's bar is refilled every frame after the delta is taken, or the
drone dies and the rest of the run measures a corpse.

| | attempts | clean hit | blocked | whiffed |
|---|---|---|---|---|
| before, diff 9 | 15 | **7 (46%)** | **0** | 8 |
| after, diff 9 | 18 | **1 (5%)** | **9** | 8 |

Not one attempt was guarded before the fix. Afterwards it is guarded half the
time and clean hits fall to 5%.

### The guard is difficulty-scaled

A bare `drone_block` in the table was not scaled at all - a diff 2 drone
guarded 5 of 7, as well as a diff 9 one, which makes the easy AI perfect
against one specific move and inconsistent with everything around it.

Row 20f now points at **`c_jc_ceiling`**, which asks `ask_mr_diff` whether he
reads it this time and falls through to `drone_block` only if he does. Losing
the roll exits without reacting at all - no consolation move, because anything
else would be a guess at where the teleport lands.

`jcc_guard_pct` is the curve, out of 1000 on `randper`'s scale:

    .word   100,200,300,400,500,600,700,800,880,950

Measured, as the share of attempts that CONNECTED which were guarded - whiffs
are the drone happening to be elsewhere and say nothing about whether he can
read the move:

| diff | guarded |
|---|---|
| 0 | 30% |
| 1 | 50% |
| 5 | 70% |
| 9 | 80% |

Monotonic, and flatter than the table because `drone_block` holds a guard for
up to 35 ticks and the drone also blocks for its own reasons - so the floor is
the drone's incidental blocking, not the gate.

**Each point is ONE deterministic playthrough, not a sample.** `@rand` reseeds
identically every round, so re-running the same difficulty returns the same
numbers to the hit (diff 1 did, twice). The curve across four difficulties is
the signal; the individual percentages are not confidence intervals.

### Also spotted

- `diff_avoid_repeats` (MKDRONE.ASM) - a complete anti-move-spam system,
  scanning the drone's hit queue for a move being abused - **has no callers**.
  It is dead code. Wiring it up would generalise this fix to every spammed
  move rather than this one, but it would change drone behaviour across the
  board and wants its own measured pass.
- The dispatch comment at `jchip3` (MOVES.ASM) says the input is **"D,D,U +
  HP"**. The real combo table says **Forward, Forward, Back + HP**
  (`combo_edit.py show scom_jc_ceiling`). The comment is stale; the rig was
  written against it and produced zero attempts until it was checked.

## 9. The same bug class, swept for  -  1 FIXED, 3 REPORTED

Item 8 was a `0` in a drone dispatch table under a comment that was wrong.
That is worth generalising, because the row below it already carried a note
about the identical bug being fixed once before, and rows 15/16 of the
projectile table carry a third ("was past end of table: no handler = never
blocked"). Three occurrences is a pattern, not bad luck.

`tools/audit_drone_reactions.py` resolves **every action the game actually
assigns** through `beware_lookup`'s real path - high byte indexes
`catagory_table`, low byte indexes the sub-table it names - and reports the
ones that land on a `0` or past the end of their table.

148 `act_*` equates, 135 assigned somewhere, 126 resolving through the tables.
**18 holes**, of which most are correct: `act_stance`, `act_duck`,
`act_walkf`, `act_backup`, `act_postattack`, `act_stunned`, `act_balled`,
`act_pre_shatter`, `act_super_froze` and friends are states there is nothing
to react to. The audit's value is that the list is short enough to judge.

### Fixed: Ermac's fireball ran off the end of the table

`act_ermac_zap` is `0017h` and `counter_proj_table` ended at `16h` - so the
lookup read **one past the end**, landing on `counter_attack_table`'s first
entry. That happens to be a `0`, so it read as "no handler" rather than
jumping into garbage; the drone simply never reacted to his fireball. The two
rows above it record the same fix being made for Sub-Zero's air ice and
Reptile's air spit. Ermac was added later and missed.

Row `17h` is now `c_ermac_zap`, a two-line handler identical to `c_spark` and
`c_jax_zap` - it is a straight fireball and gets straight-fireball handling.
The audit now reports 17 holes instead of 18.

**Not measured in game**, and worth saying plainly: Ermac is a secret fighter
and cannot be forced into a rig (select-forcing and `test_mode` both fail for
the hidden roster). The hole is proven statically and the fix is a copy of the
adjacent handler; the stability sweep is the only behavioural gate it got.

### The other three holes: two filled, one declined

All three were moves this project ADDED whose reaction row was never filled -
the same story as Cage's. They needed **three different answers**, which is
why they were measured rather than filled with `drone_block` on sight.

| action | | verdict |
|---|---|---|
| `act_ermac_tks` | `011bh` | `c_ermac_tks` -> `drone_block` |
| `act_noob_portal` | `0117h` | `c_noob_portal` -> `drone_block_proj` |
| `act_square` | `0207h` | **left at 0, deliberately** |

**Ermac's telekinetic slam** is a grab but a *blockable* one:
`do_ermac_teleslam` (MKSLAM.ASM) runs its active window through
`strike_check_a0` and reads `b2`, and its own comment says a blocked catch
"skips even the pause". Its WHIFF was already handled - `act_ermac_tks_sd` is
tiered at 3 in `sd_punish_tier` - so the only thing missing was the answer to
the live one.

**Noob's portal** needed the projectile answer, not the melee one.
`act_noob_portal` is the CAST: `do_noob_portal` plays his throw animation and
spawns a projectile, and the damage arrives with that. `drone_block_proj`
guards, waits for the spawn and waits for it to pass; `drone_block` would have
tried to punish a man who is not standing next to him.

**Kitana's square wave is not a hole worth filling.** `do_square_wave` climbs
`0e0h` = 224px above the ground before it travels, so it passes clean over a
standing opponent - driven at a pinned 70px it connected **0 times in 11
attempts**. It can only catch an AIRBORNE victim, and an airborne fighter
cannot block, so a handler would guard against nothing. The row keeps its 0
with the reasoning written beside it, and `audit_drone_reactions.py` now
separates "decided against, here is why" from "nobody has looked".

Both new handlers are gated on `ask_mr_diff` through the shared
`guard_read_pct` curve, for the same reason `c_jc_ceiling` is: these moves
have long enough windups that beware's own reaction delay never bites, so
without the gate the guard would not scale with difficulty.

### Not verified in game, and why

Only the square wave could be measured. **Noob and Ermac cannot be forced into
a fight** - the sweep harness reports `never_reached_fight` for both, where
Jade (16) and Smoke (14) force fine. So `c_ermac_tks` and `c_noob_portal` are
reasoned from the move source and modelled on the handler their neighbours
use; the stability sweep is the only behavioural gate they got. If they ever
become drivable, `tools/run_dronehole_test.ps1` already takes `HOLE=tks` and
`HOLE=portal`.

---

## 10. Second pass on the callouts  -  2 FIXED

Two follow-ups from the same tester after playing the build with the callouts
in it.

### "The wording needs to shrink back to what it normally is after each hit"

The ask, in full: *"the wording needs to shrink back to what it normally is
after each hit. the idea is to give a visual idea the combo is about to wear
out."*

It was not doing that. `cmb_ease` stepped `cmb_scl` down **one step per tick**,
so the pop was over in four ticks and the remaining ~60 ticks of the
`hudcmb_hold` window all drew at one size. The readout said "a hit just
landed" and nothing at all about how much of the window was left.

`cmb_ease` now derives the step from the combo clock instead of counting its
own way down:

```
step = (hudcmb_hold - cmb_tick) >> HUDCMB_SCLSHF     clamped to COT_SCLMAX
```

Every hit re-arms `cmb_tick` to `hudcmb_hold`, so the size snaps back to full
on each hit and eases down as the window closes - which is the cue. The shift
rather than a divide because `DIVU` on this chip wants a register pair; a
build-time `.emsg` fires if `hudcmb_hold >> HUDCMB_SCLSHF` ever stops matching
`COT_SCLMAX`, so re-tuning the hold cannot quietly mistime the fade.

The **red flash moved to its own counter**, `cmb_pop` (`HUDCMB_REDTICK` = 3
ticks). It used to be "steps 0-1 of the scale draw red", which with the scale
now spread across the whole window would have meant half the string drawn red
for two seconds.

### Measured

`tools/run_combofade_test.ps1` + `sweep_addon_combofade.lua`. Two jabs, then
silence for longer than the window - **jabbing continuously never fades at
all**, because every hit re-arms the clock, which is correct behaviour and
useless as a measurement (a 30-hit run sat at step 0 the whole way):

```
  hits=1   ticks_left=64  scale_step=0
  hits=2   ticks_left=64  scale_step=0
  hits=2   ticks_left=48  scale_step=1
  hits=2   ticks_left=32  scale_step=2
  hits=2   ticks_left=16  scale_step=3
  ... x4 combos
SUMMARY distinct steps=4  resets=13
VERDICT PASS - 4 steps across the window, 13 re-pops on new hits
```

One step per 16 ticks, evenly across the window, snapping back to full on
every new hit. Sizes shown are 1:1 -> 0.94 -> 0.89 -> 0.84 (`cot_scltab`);
the resting 0.80 lands exactly as the readout expires.

**Two rig traps on the way there**, both worth keeping:

- **Low punch inside grab range is the THROW.** Pinned at 55px, every poke
  came out as a body slam (`p1act = 0507 act_bodyslam`) and not one hit ever
  landed - the log read `hits=0` forever and looked like the feature was
  dead. High punch at 70px lands jabs.
- The readout does not exist below `hudcmb_min` = 2 hits, so a rig that
  manages one hit reads `scale_step=0` and never moves. That is the process
  not being there, not the fade being broken.

### "Sub-Zero's freeze counts as a punish when it shouldn't"

Reading the classifier did not settle this - a frozen victim is `act_frozen`
(0401h), category 4, which never reaches `hc_pun`'s gate at all. Measured
instead, with both fighters' actions logged beside every arming
(`tools/run_freezepun_test.ps1`):

```
WHIFFPUN p1  victim(p2) act 060c (was 060c)  attacker act 0604     x5
```

It was **WHIFF PUNISH**, not PUNISH, and it was arming for *Sub-Zero* - the
ice ball connecting on a victim already in `act_ret_kick` recovery, with Sub
himself in `act_proj_sd`. Landing a freeze is not a punish; the victim is
frozen, there is nothing to punish.

Gated in `hud_callout` on the strike routine word's high byte:

```
HC_ROW_ICE      .set 013h
HC_ROW_FLOORICE .set 015h
```

Placed at `hc_frzchk` **below** the FIRST HIT rung. At the top of the routine
it suppressed the round's FIRST HIT whenever the opening hit was a freeze.

Re-measured after: `WHIFFPUN` gone (was 5), `FIRSTHIT x1` back, `FLAWBLK x2`
(unrelated and expected).

### Gate

`run_battle_stability_sweep.ps1` on both changes together: **25 / 25 PASS,
0 issues**.

---

## 11. HUD colour pass  -  DONE

Four asks, all on the same screen furniture:

- the top **%** number small in `MK2FDE_P`, growing and switching to the
  re-exported all-red `MK2RDf_P` on every hit, back down to normal size and
  then into `MK2FDE_P`
- **every** font shadow `#420000`
- **more space between the FIRST HIT icon and the word**, the same on the
  right as on the left
- the **fighting toasts** in `#FFFFCE`

### The two new pens

The words are 1bpp masks blitted in CONSTANT COLOUR, and a constant colour is
a PEN INDEX, not an RGB - so both colours had to become entries in `boonpal`,
which is colour map 0 and pinned. boonpal shipped with two spare pens (both
`0000H`, neither ever named); one already carried the old amber. Both are now
spoken for:

| pen | index | colour | used by |
|-----|-------|--------|---------|
| `bpal_toast` | 9 | `7FF9H` #FFFFCE | the toast words (`HUDC_RED`) |
| `bpal_dkred` | 10 | `2000H` #420000 | every shadow `cot_build` draws |

The shadow is one site: `cot_build` lays a shadow glyph and a text glyph per
character, and the shadow was `bpal_black`. Changing it there covers the
callouts, the hit count, the rule and the FONTFADE digits at once.

### The red palette was renamed in the IMG

`MKFONT.IMG` now calls it `MK2RDf_P` (it was `MK2FDE1_P`) and its 23 live
entries are all `7C00H`. Nothing in the build promotes an IMG palette into the
ROM - LOAD2 emits a `.long <NAME>_P` and expects the symbol to exist - so it
was re-extracted into `IMGPAL6.ASM` by name, with the symbol renamed
everywhere to match the IMG. New tool for exactly this:

```
python tools/img_palette.py data/MKFONT.IMG                 # list
python tools/img_palette.py data/MKFONT.IMG MK2RDf_P --rgb  # ASM block
python tools/img_palette.py data/MKFONT.IMG --check src/IMGPAL6.ASM
```

### Two bugs the colour work uncovered

**The shrink was never on screen.** `cmb_dirty` compared the hit count and the
damage total and nothing else, so the readout redrew only when a HIT changed
one of them. `cmb_ease` walked `cmb_scl` down in RAM and the objects kept
whatever size the last hit built them at. `cmb_redraw` had been saving the
step it drew at into `cmb_showns` all along; nothing ever read it. Now it
does. **The previous section's verification measured `cmb_scl` and passed
while the screen did not move** - the variable is not the picture.

**The ease had nowhere to land.** At `HUDCMB_SCLSHF` = 4, five steps of 16
ticks is the whole `40h` window, so `COT_SCLMAX` - the resting size, and with
it `MK2FDE_P` - was reached on the tick the readout expired and was never
actually seen. At 3 it is home after `20h` and spends the remaining `20h`
there. Two build-time asserts hold it: one that `HUDCMB_SCLSTEP` is
`1 << HUDCMB_SCLSHF`, one that the ease gets home `HUDCMB_SCLREST` ticks
early.

The colour now follows the size rather than a clock of its own (`cmb_pop` and
`HUDCMB_REDTICK` are gone): below `COT_SCLMAX` draws `MK2RDf_P`, at it
`MK2FDE_P`. One number, both cues - and a string still being extended never
reaches the fade, which is what makes red mean "live".

### The icon gap was mirrored, not equal

`COT_ICONGAP` is 18 now (was 9), but the constant was never the whole story:
the icons carry an x anipoint of their own - `DRAGTOST` -7, `GOROTOST` -4,
`RADTOST` 0 - and `cot_icon` honoured it, which slid the art out from under
the x it was given. p1's icon sits left of the word so -7 ATE 7px of the gap;
p2's sits right of it so the same -7 ADDED 7. Measured at `COT_ICONGAP` = 18:

```
p1 toast: gap to the word = 11 px
p2 toast: gap to the word = 25 px
```

`cot_icon` now takes the y anipoint only, so the caller's x IS the drawn left
edge. Re-measured: **18 and 18**. The letters need no such treatment - vfont
glyphs are anix 0, and a whole-word shift would not change the spacing inside
the word anyway.

### Verified

`tools/run_hudcolour_test.ps1` (+ `sweep_addon_hudcolour.lua`), which reads
what is DRAWN, not what the variables say - the object's own `opal`, `oscale`
and `oconst`, and the pens straight out of CRAM:

```
  boonpal[ 9] = 7FF9h  #ffffce      boonpal[10] = 2000h  #420000
  p1 toast: icon 16x, gap to the word = 18 px
  p2 toast: icon 16x, gap to the word = 18 px
  p1 toast: word oconst=0909h (#FFFFCE), shadow oconst=0A0Ah (#420000)
  scl=0 palette=MK2RDf_P oscale=01000100      scl=3 palette=MK2RDf_P oscale=01300130
  scl=1 palette=MK2RDf_P oscale=01100110      scl=4 palette=MK2FDE_P oscale=01400140
  scl=2 palette=MK2RDf_P oscale=01200120
VERDICT PASS - red exactly while cmb_scl < COT_SCLMAX
```

Snapshots of both states are in `tools/screens/hudcolour`. **They have to be
taken late:** `video:snapshot()` returns the buffer rendered BEFORE this
frame's logic ran, so a shot taken on the frame the state changes shows the
state before it - the first "resting size" shot came out big and red. Five
frames of lag fixes it. The other trap is that the readout SLIDES IN, so a
shot taken on the first hit of a string catches it still off the left edge.

`run_battle_stability_sweep.ps1`: **25 / 25 PASS, 0 issues.**

---

## 12. Second colour pass, and the anti-air freeze  -  DONE

### The grow is shelved, not deleted

`hudcmb_grow` (MAINEQU.ASM) is **0**: the damage total draws at its resting
size all the time and only the PALETTE moves - `MK2RDf_P` while the string is
live, `MK2FDE_P` once the window has run down. Everything the grow needs is
still here and still exercised - `cmb_ease` walks `cmb_scl` either way,
because that step is what picks the palette - so putting the size back is
this one switch. The measure and the build read the same constant, so an aim
that disagrees with the drawn width is not possible.

Rig proof, on the objects rather than the variables:

```
  scl=0 palette=MK2RDf_P oscale=01400140      scl=3 palette=MK2RDf_P oscale=01400140
  scl=1 palette=MK2RDf_P oscale=01400140      scl=4 palette=MK2FDE_P oscale=01400140
  scl=2 palette=MK2RDf_P oscale=01400140
```

### Colours and spacing

- `MK2FDE_P` re-extracted from the updated `MKFONT.IMG` (`img_palette.py`).
- the hit count **and the rule** are `bpal_toast` #FFFFCE now, the same as
  the toast words. Measured: `oconst=0909h` on both.
- `COT_ICONGAP` is `COT_SPACE+COT_GAP` - one character space, spelled the way
  the font spells one, rather than a number. **7px on both sides**, measured
  off the objects.

`img_palette.py --check` also had a hole worth naming: its parser wanted an
unbroken run of `.word` lines, so the comment I added inside `boonpal` made it
skip that palette **silently** - which prints as "no drift". Comments are part
of a run now, and the two IMG stubs that share a name with a real ROM palette
are reported as an explicit `skip`, not passed over.

### ANTI-AIR on Sub-Zero's freeze

Reported: *"anti air should not use sub zeros air freeze attack registering"*.

The classifier said this could not happen - `hc_frzchk` drops any hit whose
strike-routine row is 13h or 15h, and `air_ice_proc` publishes 013h/014h,
both `stk_ice1`/`stk_ice2`, both routine word `1313h`. Measuring
(`tools/run_airfreeze_test.ps1`) confirmed the freeze itself is clean: with
FIRST HIT pre-spent, **the ice hit arms nothing at all**.

It is the FOLLOW-UP. A man frozen out of a jump hangs in the air in
`act_frozen` **0401h - category 4, not 5** - so he sailed past `hc_air`'s
"already reacting" test, still read as airborne, and every jab into him came
up ANTI-AIR:

```
ANTIAIR p1 victim(p2) act 0401 (was 0401) AIRBORNE  attacker act 0101   x10
```

`hc_air` now excludes 04xx alongside 05xx. The whole family is the same
shape - stunned, frozen, speared, shocked, morphed, roped, balled - every one
a state the ATTACKER put him in, which is the opposite of jumping at
somebody. Re-measured: **17 anti-airs, every one of them `act_jumpup`
(030b), none frozen.**

Two rig notes: FIRST HIT sits above the freeze gate on purpose, so an opening
freeze takes that word and no rung below it ever runs - the rig pins
`cal_first` to get past it. And `oypos` is head-anchored and **signed**: an
unsigned read prints 65518 at the top of a jump and labels it "ground".

`run_battle_stability_sweep.ps1`: **25 / 25 PASS, 0 issues.**

### Follow-up: the red is shelved too, and the % moved a pixel

`hudcmb_red` (MAINEQU.ASM) joins `hudcmb_grow` at **0**: the damage total
stays in `MK2FDE_P` for the whole window and `MK2RDf_P` is not drawn at all.
Off, the second `getfpal` in `cot_build` does not run either - the palette
pool is recycled round to round and a slot held for nothing is a real cost.

With both switches down nothing about the readout varies with `cmb_scl`, so
`cmb_dirty` stops comparing it (`.if hudcmb_grow+hudcmb_red`): otherwise it
redrew the whole readout five times a window to produce the identical picture.

`HUDCMB_PCTDY` = 1 moves the percentage one pixel down. Its own constant
rather than a change to `HUDCMB_TOPY`, because the rule and the hit line hang
off TOPY as well and only the number was meant to move. Measured off the
objects: **% line y=77, rule/hits top y=94** - one down, block unmoved.

```
  scl=0..4  palette=MK2FDE_P  oscale=01400140      (no red, no grow)
  % line y=77, rule/hits top y=94
  toast word oconst=0909h  shadow oconst=0A0Ah  icon gap 7px
VERDICT PASS
```

`run_battle_stability_sweep.ps1`: **25 / 25 PASS, 0 issues.**

### Follow-up: the readout re-centred itself on every hit

Reported: *"continuing the combo makes the hit/percentage jump back a few
pixels or so rather than stay in place"*.

Both lines are centred on the rule, so the left edge is
`middle - width/2` - and the width moves under it. The FONTFADE digits are
**8, 9 and 10 wide** (MKTEXT.TBL), so "19%" is a pixel narrower than "12%",
and a digit gained takes the whole line half a glyph left. `cmb_redraw`
re-measured on every redraw, so every hit re-centred the readout.

`hudcmb_pinw` = 1: the width is measured ONCE per string (`cmb_hitw` /
`cmb_dmgw`) and kept, so a number that gains a digit grows to the RIGHT off a
left edge that does not move. `hud_combo_hit` clears both when a new string
starts, which is the only place a re-centre is allowed.

Negative control, the same rig with `hudcmb_pinw` = 0:

```
  parked at hits=8:  % x=42
  JUMP at hits=9:    % x=41 (was 42)
  JUMP at hits=12:   % x=42 (was 41)
  ... 6 jumps in one string
```

and with it back at 1: **DRIFT 0 jumps**, with the only x change being a NEW
string re-centring (`parked at hits=5: x=42` then `parked at hits=2: x=48`).

Two rig lessons, both from this one check silently doing nothing twice:

- **`cmb_xv` is not a "parked" flag from outside.** Gating the check on it
  meant the check never ran and reported 0 jumps - a pass that measured
  nothing. Parked is now decided by watching: ten frames at the same x.
- **The Lua error was in the log the whole time.** `hits` was never defined
  in this rig, so the comparison threw `attempt to compare nil with number`
  every frame and killed the rest of the callback - and the run still printed
  `VERDICT PASS`. `tools/hudcolour_mame.err` said `[LUA ERROR]` on every line
  of it. Read the rig's stderr before believing its verdict.

`run_battle_stability_sweep.ps1`: **25 / 25 PASS, 0 issues.**

---

## 13. ANTI-AIR narrowed to an actual anti-air  -  DONE

Reported: *"anti air toast should be narrowed - when there is an attack from
the opponent, the other player is still on the ground and is able to knock the
opponent out of the air. It can't be something where like an air freeze is
done at the wrong timing and then automatically sets the player up for an
attack. It has to be something where timing is pretty critical, like a high
kick out of an incoming flip kick - where if the high kick didn't land or
wasn't done they would be hit."*

Section 12 fixed the freeze follow-up by excluding `04xx`, and then measured
what was left: **17 anti-airs, every one of them `act_jumpup` (030b)**. That
number is the whole problem. The rung was `airborne AND not in a reaction`,
and "airborne" with nothing else attached is a man who pressed Up. Hitting him
is not a read, it is not risky, and it was almost the only thing earning the
word.

### The rung is a positive test now

`hc_air` (MKDISP.ASM) asks three things instead of excluding categories:

1. **His action is one of the four JUMP ATTACKS** - `act_flykick` /
   `act_flypunch` (the jump-in kick and punch, which MOVES.ASM itself calls
   *"flip kick ??"*) and `act_jupkick` / `act_juppunch` (the straight-up
   pair). They are listed in `hc_airatk`, the same table shape as
   `hc_notpunish`.
2. **That attack's strike window has not run out.** Those four actions are
   *exactly* `air_strike`'s callers, which is what makes step 2 readable:
   `air_strike` counts its remaining collision checks down in `p_store1` and
   leaves the window at zero. Nonzero means his box is still being tested
   against me on this tick - **had I not hit him first, he would have hit
   me**, which is the sentence the report asked for. It stays zero for the
   whole falling tail and the landing.
3. **He is off the ground under his own power and I am not**, unchanged.

The `04xx` / `05xx` category tests that used to stand there are **gone**
rather than kept as belt and braces: step 1 is a whitelist of four attack
codes, and no state anybody was ever *put* in is one of them. The freeze that
sets up the free hit still dies one rung earlier at `hc_frzchk`.

The projectile anti-air survives on purpose - `cal_airborn` asks about the
PLAYERS, not about `a8` - so a fireball that stuffs a live jump-in still earns
the word.

### Measured

`tools/run_antiair_test.ps1` + `tools/sweep_addon_antiair.lua`. P2 jumps at P1
over and over and the phase is picked per JUMP: empty jump, kick late (window
live on arrival), kick early (window spent on arrival). P1 crouches and
uppercuts whatever arrives, so all three get hit by the same move at the same
range and only the victim's state differs.

```
  hit t=196   victim act 0200 window 12  AIRATK-LIVE  -> ANTIAIR
  hit t=346   victim act 0200 window 0   AIRATK-SPENT -> (no word)
  hit t=490   victim act 0308 window 1   NEUTRAL-JUMP -> (no word)
  ...
  RESULT AIRATK-LIVE -> ANTIAIR             x8
  RESULT AIRATK-SPENT -> (no word)          x3
  RESULT NEUTRAL-JUMP -> (no word)          x8
  VERDICT PASS  (8 live jump attacks stuffed, 0 wrong)
```

Every live flip kick stuffed out of the air got the word; **nothing else did**
- not the neutral jumps that used to be all of it, and not the flip kick whose
16 checks had already run out, which is a free hit on a falling man.

Two rig traps, both of which produced a confident wrong answer first:

- **`act_fk_sd` (060d) is not a hit on the victim.** MOVES.ASM sets it on the
  flip kick's own *wham* path, so P2's kick LANDING on P1 looked like P2 being
  hit and scored four phantom "live jump attack, no word" events that never
  happened.
- **The word arms one tick before the victim's reaction.** Matching only
  forwards printed every real anti-air as a "ground hit" and every stuffed
  kick as "(no word)" - both halves wrong, from one frame of skew. The match
  looks backwards as well now.

A fixed `t % 100` cycle for "attack this time / empty this time" also has to
be avoided: a knockdown plus the getup is about 200 ticks, so every jump
landed on the same parity and the first 15-jump run contained **no jump attack
at all**. The phase is picked when the jump starts.

`run_battle_stability_sweep.ps1`: **25 / 25 PASS, 0 issues.**

### "The combo toast still occasionally fires on 1 hit"

It did, and the gate that was supposed to stop it was in the wrong place.
`hud_combo_hit` tests `hudcmb_min` before **creating** the flight, which is
enough to stop a lone poke conjuring a readout out of nothing. It is not
enough to stop `1 HITS` being **drawn**, because the flight may already be
there:

```
a string of five is on screen, its 40h-tick window still open
the victim recovers  ->  back_to_normal zeroes his p_hit
the attacker lands one more hit
```

`p_hit` is what `hud_combo_hit` reads to tell a new string from a continuing
one, so it resets the counters to a single hit - and the create it then skips
was never going to run, because the *old* string's `cmb_fly` is still alive.
`cmb_dirty` saw 5 become 1 and the next redraw put `1 HITS` up. The same hole
was open during the entry slide, which never redrew at all.

The minimum now lives in `cmb_redraw`: below it the readout draws nothing and
stamps its shown-state, so it costs one clear rather than a rebuild per tick.
It keeps its process and its clock - the count is still accumulating and the
second hit brings it straight back - it just has nothing on screen until the
string is a combo. `cmbf_damp` / `cmbf_coast` picked up the same
dirty-check the parked loop already had, so a count that moves mid-flight is
drawn instead of ignored.

### The freeze and the spear were breaking their own chain

`hudcmb_hold` is 40h ticks. Sub-Zero's ice ball holds the victim for **80h**,
the floor-ice slip for 50h, and Scorpion's spear drags him in and leaves him
dizzy for longer still. So the window closed with the man standing there
frozen, `cmbf_gone` zeroed `cmb_tick`, and the hit that thawed him opened a
*new* string - `1 HITS` on the back half of a move the attacker had already
paid for.

`cmb_holding` stops the clock while the victim is in a state he cannot act
out of. It is the same ruling `dmgscale` already makes (MAINEQU.ASM, "THE
STUN EXEMPTION") and for the same moves, so the readout and the damage curve
now agree about what a link is:

| action | | |
|---|---|---|
| `act_frozen` | 0401 | Sub-Zero's ice ball, 80h ticks (`r_ice`) |
| `act_speared_sd` | 0605 | the spear drag AND the dizzy after it (`do_rope_pull`); Shao Kahn's over-the-top hammer borrows it verbatim |
| `act_slipping` | 060e | the floor-ice slip, 50h ticks (`r_floor_ice`) |
| `act_jax_dizzy` | 0610 | Jax's elbow |

Paused, not extended: nothing there re-arms `cmb_tick`, so a victim who comes
out of the hold unhit still loses the readout with whatever the window had
left. Not `act_stunned` - `dizzy_dude` zeroes `p_hit` on purpose so the
winning round's string does not run on into the fatality.

**Measured**, same rig and same driver, baseline built with the fix backed
out (`tools/run_hudcmb_test.ps1`, `sweep_addon_hudcmb.lua`):

```
                                        without      with
  frames with a readout up at 1 hit         154         0
  cmb_tick ticks lost under a freeze         17         0
  layout_exact                              4/4       4/4
```

Three rig traps, each of which produced a confident wrong answer first:

- **The rig was pinning `cmb_tick` to `hudcmb_hold` every frame**, to keep a
  process alive into its forced-layout sweep. With that running the clock
  cannot go down for *any* reason, so "the clock did not run down while he
  was frozen" passed against a ROM that had never heard of the hold. The
  top-up is now off while the hold is measured.
- **The existing `1 HITS` check read a nil `objlst`** (the local is
  `objlst_sym`), walked whatever chain address 0 pointed at, and reported 2
  frames of a failure worth 154. It also cannot schedule the case: the
  readout has to *already* be up when the new string opens, so the rig now
  zeroes the victim's `p_hit` itself while a string of two is live.
- **A hit landing inside the hold re-arms the clock**, which is the feature
  working, so the assertion is "never ran down", not "never moved" - and the
  driver is parked for those 40 frames anyway.

Pre-existing and untouched by either fix: the rig's shadow tally
(`frames_wrong=130`) looks for an `oconst` of `0f0f` on glyphs that are
FONTFADE art off a palette, finds no shadows, and holds `VERDICT` at FAIL.
Identical on both builds.
