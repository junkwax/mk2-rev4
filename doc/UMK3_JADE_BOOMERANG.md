# Jade's Razor-Rang, extracted from the UMK3 arcade ROM

Everything below came out of `C:\MAME\roms\umk3.zip` and the UMK3 PS1 C
source. Nothing is from a movelist, a wiki, or memory. Re-derive it any time
with:

```
python tools/umk3_jade_extract.py            # full report
python tools/umk3_jade_extract.py --tbl      # JADERANG.TBL-shaped anipoints
```

Two sources, and they cover different halves:

| Half | Source | Why it is authoritative |
|---|---|---|
| Art, animation lanes, anipoints, hitbox, damage | `umk3.zip` u54/u63 program ROM | The shipped arcade data itself |
| Hit and block handling | `umk3.zip` program ROM, **disassembled** - see "The hit and block handler" below | The shipped arcade code itself |
| Trajectories, tick counts, trail cadence | UMK3 PS1 C source (`MKZAP.C`) | It writes **arcade** values as literals and scales them at compile time (`SYSTEM.H`: `SCX`/`SCY` are 80%/85% of arcade), so the literal in the source *is* the arcade number |

The ROM is byte-interleaved (u54 = even, u63 = odd) into a flat 1 MB image
whose TMS34010 base is `0xFF800000` - the same layout MK2 uses, so
`byte offset = (bit addr - 0xFF800000) / 8`.

## How the anchors were found

Three independent identifications, all agreeing. That agreement is what makes
this safe to build on:

1. **The art.** MK3's image records are laid out exactly like MK2's -
   `.word W,H,anix,aniy` / `.long SAG` / `.word control`. Scanning the whole
   1 MB ROM for a run of records whose W x H match our own `BRANG4-9` returns
   **exactly one hit**, at byte `0x097f4e`.
2. **The lanes.** `lia_anitab2[2]` and `[4]` sit two slots apart and point at
   the throw and the flight lanes, matching `MKGUYS.H`'s
   `ANIM_JADE_ZAP = 0x02` / `ANIM_BOOMERANG = 0x04`.
3. **The hitbox.** Strike index `0x14` - the one
   `projectile_flight_call(obj, 0x14)` uses - carries strike routine
   `0x6800`, and `MKREACT.C` lists `r_boomerang` at reaction `0x68`.

A fourth confirmation fell out afterwards: **every control word in our
`src/JADERANG.TBL` already matched UMK3's byte for byte.** Our art is a
frame-for-frame rip of the arcade set; only the anipoints had drifted.

## The art

`0x097f4e`, 18 consecutive records. "ours" is the `src/JADERANG.TBL` name.

| UMK3 | ours | W x H | anix | aniy | role |
|---|---|---|---|---|---|
| REL1 | BRANG1 | 49x29 | 54 | -9 | throw-time slave frame |
| REL2 | BRANG2 | 81x26 | 23 | 3 | throw-time slave frame |
| REL3 | - | 60x45 | -43 | -1 | **unused by any lane** |
| REL4 | BRANG3 / BRANG3F | 51x18 | 25 | 5 | first frame of the flight loop |
| SPIN1 | BRANG4 | 48x29 | 27 | 12 | flight |
| SPIN2 | BRANG5 | 18x50 | 13 | 23 | flight |
| SPIN3 | BRANG6 | 29x47 | 16 | 25 | flight |
| SPIN4 | BRANG7 | 50x18 | 26 | 12 | flight |
| SPIN5 | BRANG8 | 47x29 | 21 | 16 | flight |
| SPIN6 | BRANG9 | 19x49 | 5 | 26 | flight |
| SPIN7 | - | 29x47 | 12 | 22 | **unused by any lane** |
| SPIN8 | - | 13x46 | 4 | 25 | **unused by any lane** |
| TRAIL1-6 | BRTRAIL1-6 | see tool | | | dotted motion echoes |

Three blade frames (REL3, SPIN7, SPIN8) have **no references anywhere in the
ROM** - dead art in the arcade set itself. Our rip never carried REL3, which
is why our nine `BRANG` frames map onto UMK3's ten.

## The lanes

**`ANIM_JADE_ZAP`** (`lia_anitab2[2]`, byte `0x0254a4`) - the throw. Jade's
body is a two-piece composite per frame; the blade rides along as an engine
*slave*, driven by lane commands:

```
ani_sladd  -> 39x38 blade-at-rest (the only frame in this group with a palette)
ani_slani  -> REL1
frame        35x125 + 42x123        (Jade)
ani_slani  -> REL2
frame        49x95  + 42x125
ani_calla  -> boomerang_adjust      (adjust_xy_a5 slave, +0x48, +0x20)
frame        53x89  + 76x112
0                                   (end of part 1)
frame        49x95  + 42x125        (part 2: the recovery, retraced)
frame        35x125 + 42x123
0
```

`boomerang_adjust` was verified by disassembling its target: `movi 048h,a0 /
movi 020h,a1` - exactly the `SCX(0x48), SCY(0x20)` in `MKANI.C`'s
`calla_jumptbl[34]`.

**`ANIM_BOOMERANG`** (`lia_anitab2[4]`, byte `0x025516`) - the flight. Seven
frames, looping back to their own first entry:

```
REL4, SPIN1, SPIN2, SPIN3, SPIN4, SPIN5, SPIN6, ani_jump -> REL4
```

At anirate 2 that is **14 ticks per revolution**, and ours is the same: the
lane is `UBREL4` plus the six `SPIN` frames, looping on `UBREL4`. It was six
frames re-entering at the first SPIN (12 ticks, 17% fast) for as long as
`UBREL4` was re-anchored for a travel path and could not sit in the loop - see
"Point-blank: the release geometry".

## Flight and trajectory

From `MKZAP.C`. All four variants share one setup and one flight; only the
per-tick arc differs.

| Variant | C entry | arc | behaviour |
|---|---|---|---|
| straight | `do_proj_jade_zap_med` | `0` | flat |
| upward | `do_proj_jade_zap_hi` | `-0xc000`/tick | leaves level, climbs |
| downward | `do_proj_jade_zap_lo` | `+0x5000`/tick | leaves level, dips |
| returning | `do_proj_jade_zap_ret` | sentinel `1` | flips `oxvel` once off screen |

```
throw     do_next_a9_frame, sleep 6, mframew 4,
          spawn, sleep 0x20, mframew 3 (part 2 recovery)
flight    set_proj_vel(0x90000, anirate 2)   = 9 px/tick, 2 ticks/frame
blocked   init_anirate(2); oyvel = -0x30000; oxvel = -oxvel
trail     spawn every 2 ticks; each lives framew(3) = 3 ticks
hit       r_boomerang: shake_a11(4,6), BLOOD_BOOMER x7, stumble back 0x40000
```

Every variant launches **flat**; the arc is applied one tick at a time during
flight (`boomerang_call` does `oyvel += p_store8`). An upward throw therefore
leaves her hand level and curves, rather than starting already angled.

## The hit and block handler

Read out of the ROM, not the C source, because "the blade bounces when it is
blocked" looked like something inherited from Kung Lao's hat and needed
settling one way or the other. It is not inherited: **the arcade bounces it
too.** Reproduce with `tools/umk3_boom_dasm.ds`
(`mame umk3 -debug -debugscript tools/umk3_boom_dasm.ds`), which dumps
`0xFFA9E000` onward; `boomerang_proc` ends at bit `0xFFAA2A20`, immediately
after its `JA projectile_flight_call`, and `boom_trail_proc` sits just below
it at `0xFFAA3000` (byte `0x054600`) - that adjacency is what identifies the
routine.

```
FFAA2960  MOVI  14h,A11              strike index 14h - the boomerang box
FFAA2980  MOVI  FFAA2D20h,A6         per-tick callback (the arc / the return)
FFAA29F0  JA    FFAB4A30h            projectile_flight_call - returns on contact

FFAA2A20  MOVE  B2,B2                blocked ?
FFAA2A30  JRNE  FFAA2B70h            yes -> the bounce

  clean hit
FFAA2A40  CALLR FFAB56C0h            p_action = 500h   (dead_projectile)
FFAA2A60  MOVI  50h,A0 -> *A8(0D0h)  ozpos = front_z
FFAA2AA0  next_anirate / sleep 1 / proj_onscreen_test / delete_proj_and_die

  blocked
FFAA2B70  MOVK  2,A0 ; CALLA init_anirate
FFAA2BB0  MOVI  FFFD0000h,A1 -> oyvel     up at 3 px/tick
FFAA2C00  oxvel = -oxvel                  REVERSED
FFAA2C50  the same fly-out loop
```

Three things fall out of that listing:

* **A blocked blade reverses.** No lineup, no randomness, no dented frame -
  `init_anirate(2)`, an upward kick, and the sign of `oxvel`. Our
  `jbp_blocked` used to call `match_me_with_him` and `multi_adjust_xy 0,030h`
  first, re-seating the blade on the blocker's anipoint; *those* were the hat
  leftovers and they are gone.
* **`dead_projectile` and `front_z` are on the CLEAN HIT ONLY.** We run them
  on both paths deliberately: `act_proj_dead` is this engine's "spent" marker,
  and without it the drone keeps dodging a harmless blade (`MKDRONE` `cpsd5`)
  and Shao Kahn's clap keeps deflecting it (`MKZAP` `ksdf_scan`).
* **Neither post-contact loop spawns a trail.** Ours does, deliberately - a
  blade that connects and then flies on as a bare unsmoked sprite reads as a
  bug.

**Nothing in the arcade mirrors the blade when it turns.** All three of UMK3's
reversals - the blocked bounce at `FFAA2C00`, the offscreen turnaround at
`FFAA2E50`, and (in the C source) the same negate - only touch `oxvel`. The
sprite keeps the flip it launched with, so an arcade blade moonwalks home.
Ours goes through one helper, `jbp_reverse_x`, which negates `oxvel` and then
calls `flip_multi`, so the art turns with the travel. Two things follow for
free: `strike_check` reads `b_fliph` to decide which side of `oxpos` the box
extends, so a returning blade that missed on the way out now reaches the way
it is actually flying; and the shadow trail clones the blade's live record, so
the echoes turn with it instead of changing handedness mid-flight.

Neither loop runs another strike check, so contact is once per throw either
way. And the return sentinel is never consulted after contact: the callback at
`FFAA2D20` only runs from inside `projectile_flight_call`, so in the arcade a
returning throw that *connects* never comes back. **That is where this build
deliberately departs.**

Here, a clean hit does not end the returning throw's outbound leg and does not
turn it around either. The blade passes through the man it hit, carries on to
the **same screen edge a miss would have reached**, turns there, and comes
home - one flight path for hit and miss, with only the damage between them.
`jbp_unblocked` sends it back to `jbp_loop` (where the `p_store8` state machine
lives) with the sentinel still armed, and `jbp_check` skips the strike test
while `p_action == act_proj_dead`, so the extra lap cannot be a second hit.
Measured: contact at tick 20, carried **153 px past** the victim, turned at
tick 37 (x 784, against a world window of 387..787), came back **414 px**. A
miss in the same build turns at tick 36 and comes back 423 px - the same path.

It can also **catch him again coming home**. `act_proj_dead` makes the rest of
the outbound leg collision-free; `jbp_return_arm` clears it at the turn, so the
blade is live for the trip back - at most one hit per leg, two per throw. The
homeward hit uses its own strike record, `fn_strikes` entry `01ah`
(`stk_jade_boom_ret`), byte for byte `stk_jade_boom` except the hit reaction:
`018h` -> `019h`. That is `r_jade_boom_back`, the same blood, shake, stumble
lane and timing as the outbound hit with one line changed -
`away_x_vel` -> `towards_x_vel` - so a blade arriving from the far side **drags
him toward Jade** instead of shoving him away from her. Measured: hit #1 at
tick 20 carried him 42 px away, hit #2 at tick 41 carried him 39 px toward
(the -15 rather than -20 on the second is the game's own combo damage
scaling, not something this does).

A block is the exception and keeps the arcade's behaviour: it reverses on the
contact tick and comes straight back. A guarded blade is spent and stays spent
- it never reaches the turn that would re-arm it.

## Hitbox and damage

`strike_tables[16]` (FT_JADE) resolves to `lia_strikes` at byte `0x05e6d0`,
shared by ochar 15/16/17 - Kitana, Jade and Mileena, exactly as MK3's
`lia_strikes` is. Entry `0x14`:

```
x offset  0x17 (23)      y offset  -17
x size    0x27 (39)      y size    0x22 (34)
routine   0x6800         damage    0x1403  = 20 on hit / 3 on block
```

That box is a 39x34 square sitting **on** the blade's anchor, not reaching out
in front of it. What we shipped before was a copy of Kitana's fan box
(`x_off=0x3a`, `x_size=0x38`), which reached about 32 px further forward than
the blade art - the reason the boomerang used to register a hit while it still
looked short of the target.

**The strike routine word does not port.** `0x6800` indexes UMK3's reaction
table (`0x68` = `r_boomerang`); ours stays `0x1810`. Only the box, the damage
and the sound are portable. Same rule as the Kahn air-knee port.

Damage scale: 20/166 of UMK3's bar is 12.0%; 20/161 of ours is 12.4%. Close
enough that the arcade number is taken verbatim rather than rescaled.

## The trail

Part 2 of `ANIM_BOOMERANG` is a **flat list of image records** (not frame
wrappers), which is why `boom_trail_proc` dereferences it one level less than
a lane walker would:

```
part 1   REL4 , SPIN1 , SPIN2 , SPIN3 , SPIN4 , SPIN5 , SPIN6
part 2   WISP , TRAIL1, TRAIL2, TRAIL3, TRAIL4, TRAIL5, TRAIL6
```

`boom_trail_proc` is at byte `0x054600`:

```
MOVK 16,A0 / MOVE A0,*A8(01f0h)   obj->ochar = FT_JADE
MOVK 4,A9  / CALLR get_char_ani2  ANIM_BOOMERANG
CALLA find_part2
MOVE *A9+,A5,L                    <- POST-INCREMENT
CALLA <gso_dmawnz>                build the object from a5
CALLA lineup_1pwm                 (falls into ani_adjust_single)
MOVK 3,A0 / jsrp framew           walk what a9 now points at
```

**Every echo plays the whole list.** The read is `*A9+`, so `a5` gets part2[0]
(the wisp) to build the object with and `a9` is left on `TRAIL1`; `framew`
then walks `TRAIL1..TRAIL6` at 3 ticks a frame. Each puff lives ~18 ticks, and
a fresh one is dropped every 2 ticks, so six to nine are alive at once. It is
a dissipating smear of smoke, not a ghost of the blade.

> **Two earlier readings in this file were wrong and are corrected here.**
> The first claimed part2[0] was stamped unconditionally and `TRAIL1-6` were
> dead art. That came from reading `9725` as the non-incrementing `0x87`
> form. Checked against three known encodings in our own ROM - `8721` is
> `move *a9,a1,l`, `8780` is `move *a12,a0,l`, `a20c` is `move a0,-*a12,l` -
> `0x87` is `*Rs`, `0x97` is `*Rs+`, `0xA2` is `-*Rd`. The second is below.

The `jsrp` is unambiguous: the macro is `getpc a7 / addi 060h,a7 /
move a7,-*a12,l / jauc`, and the bytes are `0147 0b07 0060 a2ec c080`. Its
target at byte `0x377bc` matches our own `framew` opcode for opcode,
including the `jrc`-first test that distinguishes it from `mframew`:

```
a20c        move a0,-*a12,l
0d3f 002e   callr frame_a9
ca05        jrc  fwdone        <- framew tests carry first; mframew tests Z
8780        move *a12,a0,l
0d5f ...    calla prcslp
c0f8        jruc fwloop
```

### Spawn cadence, from the arcade

The caller sits immediately above the proc and is a countdown of two:

```
a0 = *a13(0250h)     ; pdata is 0100h, so 0250h IS p_store2
dec a0
jrne -> store        ; not yet
create(pid 0x11e, boom_trail_proc)
a0 = 2
store a0 -> *a13(0250h)
```

One puff every 2 ticks. `p_store2` is the same name the PS1 source uses for
it, which is a good cross-check on both readings.

### Where a puff actually lands - ON the blade

`lineup_1pwm` (byte `0x036a52`, identified by structure) copies the blade's
`oxpos`/`oypos` and flip onto the puff, then falls into `ani_adjust_single`,
which subtracts the puff's own anipoint:

```
oxpos -> oxpos  (0x090)
oypos -> oypos  (0x0b0)
oflags (0x0f0), ANDI
oimg   (0x1a0)  ianioffx (0x020)  ianioffy (0x030)  isize (0x000)
```

So at creation the puff is offset by `UBWISP`'s `(71,-8)`, about 48px behind
the blade. **That offset does not survive.** `ani` (MKDISP.ASM:3685) diffs the
old frame's anipoint against the new one's and adds the delta to
`oxval`/`oyval` - it keeps the anipoint **pinned in world space** - and
`framew` applies `TRAIL1` on the same tick the object is built, before
anything is drawn. The 71px is handed straight back.

The wisp is therefore only ever an **anchor donor**: it is never visible, and
its anipoint is cancelled the instant the first trail frame lands. A puff sits
on the blade, and the spacing you see in game is the blade moving between
spawns:

    9 px/tick x 2-tick spawn = 18 px between puffs

Measured in our build: 576, 594, 612, 630, 648, 666, 684, 702, 720, 738.

> **This is the second correction.** An earlier pass here quoted "~48px
> behind and ~25px below", derived from the creation step alone without
> checking what `ani` does next. `jade_boom_trail_back` / `_drop` existed to
> encode that and are gone.

The arcade also does **not recolour** the trail. The only palette anywhere in
the boomerang group sits on that 39x38 frame, and it is the blade's own
16-entry purple ramp - the same sixteen colours as our `jade_boom_p`, merely
ordered bright-to-dark instead of in IMG order. There is no shadow palette,
and `BOOMSH_P`, the 4-shade dark ramp this used to recolour onto, **does not
exist anywhere in the arcade ROM** - it was invented here.


### Getting the real frame

The arcade's trail image is not in our art set, so it had to come out of the
graphics ROMs - `tools/umk3_gfx_extract.py`:

- The video region is five groups of four 1 MB chips, each group 4-way
  byte-interleaved, per MAME's own `-listxml umk3`, **with a 4 MB hole at
  `0x1000000`** (group 5 loads at `0x1400000`).
- A record's SAG is a bit offset straight into that region: byte = `SAG/8`,
  and frames are not byte-aligned.
- Pixels are **6bpp, LSB-first** within the stream.
- Control-word bit 7 is `dmacmp` (SYSEQU.ASM). When set, each row is one
  8-bit header - low nibble = leading transparent pixels, high nibble =
  trailing - followed only by the pixels between them, with each nibble
  scaled by a shift from the control word: `lead << ((ctrl>>8)&3)`,
  `trail << ((ctrl>>10)&3)`. That is exactly what MKDISP.ASM's `shad7`
  walks. A `06000h` frame is flat `w*h*bpp` bits.

Calibrated on `BRTRAIL4`, the one boomerang frame with an uncompressed control
word, by a test that does not need positions to line up: the correct decode
must yield only the two or three ink values the art actually uses. 6bpp
LSB-first produced exactly `{8,9,10}` - UMK3's indexes for `03892h/03491h/
03070h`, the dark band that art is drawn in. Every other depth produced noise.

The self-test does **not** reach 100% against our own IMG, and cannot: our
`JADERANG.IMG` is a re-indexed rip rather than a bit copy. `BRTRAIL4` carries
only `{7,13}` where the ROM has `{8,9,10}` - a shade was merged on the way in
- and our palette is a permutation of UMK3's besides. Compressed frames land
around 78% identical, which is the shape agreeing and the indexes not.

The frame itself:

```
python tools/umk3_gfx_extract.py --sag 064fd214 --size 39x38 --ctrl 6480 \
    --pal ffdb5c70 --raw boomghost.bin
```

39x38, 286 ink pixels (19% coverage), using all 16 entries of BOOMRNG_P.
Rendered, it is a thin wisp rather than a blade - which fits: the throw lane
starts the slave on this frame and only then switches it to REL1/REL2, and the
throw cues `ST_JADE_ARROW`, "arrow appear". It is the boomerang materialising. Its anipoint is `71,-8`,
far outside its own box, because the same frame is the blade hanging off
Jade's hand during the throw (`ani_sladd`).

It was re-indexed from UMK3's palette order into BOOMRNG_P's, appended to
`data/JADERANG.IMG` and listed LAST in `JADERANG.LOD` so every frame above it
keeps the SAG it already had. `promote_tbls` then wrote the `BOOMGHOST` record
into `src/JADERANG.TBL` by itself.

**It did not fit.** JADERANG went from 17,408 to 17,618 bytes and ran 210 bytes
into TIMEFLR, which starts immediately after it in the bank-0 sidecar pack.
makevrom's overlap guard refused to write the chips - and when TIMEFLR was
moved forward 512 bytes to `0x786600`, its *base* guard refused too, because
makevrom pins each sidecar's expected LOD base as well. Both had to be updated
together. TIMEFLR keeps 598 bytes of guard; the next thing to grow here has to
come out of SAHELI's run or move somebody.

Verified afterwards with `tools/check_sag_coverage.py`: 9,257 exported SAGs,
every one landing inside its own sidecar's payload - which is the check that
catches a relocated base whose table did not follow it.

Two details that matter for placement:

- **The echo is a single-part object**, so MKDISP's `no_multi` path draws it
  straight at `oxpos/oypos` and subtracts no anipoint. The offset has to be
  baked into the position - and because we read a raw table record rather than
  a piece `ani2` already processed, `ani2`'s flip rule has to be applied by
  hand: `fliph -> dx = isizex - ianioffx`, `flipv -> dy = isizey - ianioffy`
  (MKUTIL.ASM `an2`/`an3`).
- **The control word** is the echo record's own (`& 0ffcfh`, dropping its stale
  flip bits) OR the blade's `oflags & 0803fh`. Record word alone loses the go
  bit; `oflags` alone loses the bpp field and shears the art.

We do not carry the 39x38 frame, so `BRANG3F` gets no echo. At a spawn every
other tick, one gap in seven is not visible.

**What this replaced:** a clone of the blade's own live frame recoloured onto
a synthesised dark ramp (`jade_boom_shadow_p` / BOOMSH_P). It got the spin for
free, but it was a full blade silhouette in the wrong colours, and it read far
heavier than the arcade's sparse dotted streaks. `jade_boom_shadow_p` is now
unused; it is kept in `MKZAP.ASM` only as the record of that approach.

## The release path (REL1-3), and the REL4 that went back

The arcade's flight lane opens on `REL4` and loops seven frames, and so does
ours. It did not always: `UBREL1-4` were all four re-anchored here as a TRAVEL
PATH, with the loop cut down to the six `SPIN` frames.

`UBREL1-3` are still ours and still re-anchored, which is the part that is a
deliberate deviation - they are fitted to MK2 Jade's arm rather than MK3
Kitana's. They are within 8px of Midway's anyway (`46/24/-37` against
`54/23/-43`). `UBREL3`, which the arcade's own lane table never references, is
part of that path and is packed for it. There is no wisp/materialise frame:
`UBWISP` (the 39x38 the arcade stamps for its trail) is in `JDUMK3.IMG` but is
not part of the move and is not packed.

**`UBREL4` went back to Midway's `(25,5)` on 2026-09-27.** At `-85,-27` it was
112px across and 39px down from `SPIN1`'s `27,12`, so it could not live in the
loop - it would have snapped the art once per revolution - and the flight had
to put that step on the ANCHOR instead (`adjust_xy_a5 112,39`). That step is
what opened the first strike box at +105 and made the move miss anyone standing
close. Anchored on its own art it sits 2px across and 7px down from `SPIN1` and
loops cleanly, and the release displacement is the arcade's `boomerang_adjust`
(+72,+32) instead. The whole reasoning is in "Point-blank: the release
geometry" below.

Her throw is still 14 ticks: the 2-tick beat that used to hold `UBREL4` in her
hand is now 2 more ticks of `JDTHROW4` with the blade on `UBREL3`.

### The blade is a SLAVE of the throw lane

`a_fn1_boom_throw` now carries the blade the way the arcade does - `ani_sladd`
to spawn it, `ani_slani` between Jade's poses:

```
ani_sladd  UREL1     JDTHROW2      pose 1, 6 ticks
ani_slani  UREL2     JDTHROW3      pose 2, 4 ticks
ani_slani  UREL3     JDTHROW4      pose 3, 2 ticks
ani_slani_sleep UREL4               ... still pose 3, 2 ticks
ani_calla  jade_boom_release        released
```

`do_ani_slani` swaps `a8` to the slave and leaves `a9` on THIS lane, so the
entry after the command is the slave's next frame. `ani_slani_sleep` is what
lets `UBREL4` have its own 2 ticks without Jade changing pose - it returns
rather than fetching another image for her.

**Why this matters: there is now ONE clock.** Before, `jade_zap3` ran 6/4/4 and
`jade_boomerang_proc` ran its own 6/4/2/2 windup as a separate process, and the
two had to be kept summing to the same 14 ticks BY HAND - each file carried a
comment warning about the other. Now a single `do_next_a9_frame` steps Jade's
pose and the blade's frame together and they cannot drift.

It also deleted a guard. `jbp_windup_ok` used to poll every windup step to see
whether Jade had been knocked out of the throw, re-validating her procid stamp
each time. The blade is her `p_slave` now, and `reaction_start_chores`
(MKREACT.ASM:369) calls `delete_slave` - "no slaves !!" - on the way into ANY
reaction, so an interrupted throw drops the blade through the engine's own
path. Nothing is stranded either: `jade_boom_release` only spawns the flight
process at the instant it clears `p_slave`.

This stays ONE lane part. The recovery is part 2 and `jade_zap3` reaches it
with `find_part2`; there is no `find_part3`.

Measured after the conversion, the release is byte-identical to the
code-driven version it replaced - same frames, same ticks, same pixels.

**The windup runs at anirate 1, not 2.** `next_anirate` only advances every
`p_anirate`-th call (see [[reference_mk2_next_anirate_throttle]]), so at rate 2
the four hand-paced calls landed only two advances - `UBREL2` held 6 ticks
instead of 4 and the handoff fired two frames early, throwing the anchor 112px
while `UBREL3` was still on screen. The flight rate is written straight
(`p_anirate`/`p_anicount` = 2) at the handoff rather than through
`init_anirate`, which forces `p_anicount=1` and would cut `SPIN1` to one tick.

**The anipoints are NOT promoted.** `src/JADERANG.TBL` is not in
promote_tbls' `GENERATED_TABLES`; the SAG/control/size are merged from LOAD2
but `.word W,H,anix,aniy` never is. Re-anchoring in `data/JDUMK3.IMG` reaches
the editor and not the ROM. `build.py` Phase B now locks the two together
(`img_anipoint.py sync-tbl data/JDUMK3.IMG src/JADERANG.TBL --check`); run the
same command without `--check` to push an IMG re-anchor through. The
`boomerang_adjust` displacement is the arcade's own and is NOT derived from
those anchors, but `UBREL4`'s anipoint is load-bearing for the loop and has to move
with them.

## What this build does with it

| | before | now |
|---|---|---|
| flight speed | `0C0000h` (12 px/tick) | `090000h` (9 px/tick) - **identical to the arcade**; both boards run 400x254 at 54.706840 Hz, so that is ~492 px/sec on each |
| anirate | 1 tick/frame | 2 ticks/frame |
| flight loop | 6 frames (BRANG4-9) | 7 frames (BRANG3F + BRANG4-9) |
| spin anipoints | hand-centred approximations | UMK3's true pivots |
| trajectory | one auto-aimed angle at the chest | four real arcs |
| blocked bounce | down at 5 px/tick, dead `@rand` coin flip, hat's `match_me_with_him` + `multi_adjust_xy` lineup | up at 3 px/tick, flipped where it stands |
| returning throw, clean hit | flew on through and died at the edge, same as the arcade | passes through, turns at the SAME edge a miss uses, comes home |
| returning throw, blocked | bounced back (arcade) | unchanged - bounces on the contact tick |
| second hit on the way home | impossible - the blade was gone | lands, with its own record (`01ah`) whose reaction pulls him FORWARD |
| art on any turnaround | kept its launch flip - flew home backwards, as the arcade does | mirrored with the travel (`jbp_reverse_x` -> `flip_multi`) |
| trail life | 4 ticks | 3 ticks |
| trail art | recoloured clone of the blade | BOOMGHOST, the arcade's own frame, extracted from the graphics ROMs |
| trail colour | synthesised dark ramp (BOOMSH_P) | the blade's own BOOMRNG_P |
| hitbox | Kitana's fan box | UMK3's own 39x34 |
| damage | 24 / 6 | 20 / 3 |

Inputs (chosen for this build - UMK3's own five `SMOVE` tables use a RUN
button MK2 does not have, so its mapping cannot port verbatim):

```
Back, Forward + LP          straight
Back, Forward + HP          upward
Back, Forward + LK          downward
Back, Back, Forward + LP    returning (comes back if it misses)
```

`jade_lo_punch` tests the three-direction pattern **before** the two-direction
one, because the tail of `Back,Back,Forward` *is* `Back,Forward`.

### One thing the arcade gets wrong too

`projectile_flight_call` reverses the returning throw and then, in the same
tick, runs the offscreen test that deletes it - the blade would flip its
velocity and die without ever coming back. MK2's `jbp_return_arm` had
inherited the same shape (harmless while the variant had no input wired to
it). It now jumps back to the top of the flight loop instead, and
`jbp_returning` governs the trip home on a bounded countdown
(`jade_boom_return_ticks`), handing control back to the normal rules once the
blade is visible again.

## Point-blank: the release geometry

**A man standing close to Jade could not be hit by this move at all**, and the
blade was drawn crossing him. The cause was geometry, not collision code, and
the fix is the arcade's own arrangement. Measured on the real ROM, pair pinned,
one straight throw at each separation
(`tools/run_jade_boom_prezap_test.ps1`):

| separation | before | after |
|---|---|---|
| 24 px  | nothing | nothing - the arcade does not connect here either |
| 48 px  | nothing | nothing |
| 72 px  | **nothing** | **-20**, flight tick 15 |
| 104 px | -20 | -20 |
| 130 px | -20 | -20 |
| 190 px | -20 | -20 |

### Why the hole was there

The blade's box is 39 px wide sitting on its anchor (`stk_jade_boom`:
`xoff 017h`, `xsize 027h`, so `[anchor-16, anchor+23]` - the arcade's record).
What matters is where that anchor IS when the first strike check runs, and this
tree had built up a mechanism the arcade does not have:

* `UBREL4` was re-anchored here to `(-85,-27)` as part of a travel path - the
  release anipoints themselves walked the blade out of her grip.
* That put its art 85 px in front of her by the last wind-up frame, and it
  meant `UBREL4` could not sit in the flight loop (it would snap the art 112 px
  once per revolution), so the loop was six frames instead of seven.
* The flight then needed a **112 px anchor step** (`adjust_xy_a5(112,39)`) to
  pick that art up, which opened the first strike box at **+105** - and it only
  ever moves further away at 9 px/tick.

So nothing tested the span between Jade and +105, and the blade visibly crossed
it. Measured before the change: the blade sat at +112 on the handoff frame and
the first strike test happened at +121.

### What the arcade does instead

Two things, and they replace all of the above:

* `UBREL4` keeps Midway's own anipoint `(25,5)`, so the anchor is ON the art -
  which is what lets that frame live in the flight loop. UMK3's
  `ANIM_BOOMERANG` (lia_anitab2[4], byte 0x025516) is `REL4, SPIN1..6,
  ani_jump` - **seven frames, 14 ticks a revolution** at anirate 2.
* The displacement is `boomerang_adjust` (MKANI.C, the `ani_calla` in
  `ANIM_JADE_ZAP`): `adjust_xy_a5(p_slave, SCX(048h), SCY(020h))` = **+72,
  +32** on the anchor at the release. The UMK3 PS1 source writes arcade values
  and scales them at compile time, so those literals are the arcade numbers.

First strike box therefore opens at `[+56,+95]` and lands at `[+65,+104]` one
tick later, instead of `[+105,+144]`. Verified: the rig reads the release
displacement straight off the objects and gets **+72,+32**, and counts **7**
distinct flight frames.

### The wind-up is ours, deliberately

`UBREL1-3` keep their own anipoints. Those really are fitted to MK2 Jade's arm
rather than MK3 Kitana's, and they are within 8 px of Midway's anyway (46/24/-37
against 54/23/-43). Only `UBREL4` went back, and its 110 px difference was never
an art fit - it was the travel-path mechanism standing in for the anchor nudge.

Her throw is unchanged in length: the beat that used to hold `UBREL4` in her
hand for 2 ticks is now 2 more ticks of `JDTHROW4` with the blade still on
`UBREL3`, so the release still lands 14 ticks in.

### What UMK3 does for the projectiles that DO need help

Worth recording, because it is the general answer to "the projectile spawns on
top of him" and it is how this investigation started. UMK3 gives those moves a
box anchored on the **thrower**, checked **before the projectile flies**,
reading its damage and reaction out of the flight's own strike record:
`strike_check_box` (MKJOY.C), wrapped by `local_strike_check_box` (MKZAP.C)
with the Motaro and Jade-Flash gates.

| move | pre-flight boxes (arcade px) | on a hit |
|---|---|---|
| Liu Kang fireball (`lk_zap_entry`) | four, stepping out as the dragon forms: `39h/9/29h/20h`, then `80h`, `a4h`, `d0h` | `lk_prezap_hit` - no projectile is ever created |
| Sub-Zero ice (`ice_collision_check`) | five, 3 ticks apart, each stepping the ice's frame: `60h,60h,88h,a4h,b5h` | `sz_zap_hit` |
| Shang skull (`skull_proc`) | one: `57h/15h/52h/16h` | `make_lineup_explode` - detonates on the spot |
| Jax zap (`jax_zap_proc`) | a whole strike record of its own, `0x13`, at the muzzle; flies on `0x12` | `jax_zap_hit` |
| Motaro rocket (`rocket_hunt`) | proximity: `get_rough_hypotenuse < 010h` | `rocket_explode` |

Liu Kang's first box is the tell: `[16, 57]` in front of his anchor, reaching
back almost to his own body - exactly the span his flying fireball can never
test.

**Jade's boomerang is not on that list**, so the arcade has a small dead zone
here and so do we now: 24 and 48 px do not connect. One was built for this move
(`jboomclose` / `stk_jade_boom_close`, a box on Jade from her anchor to where
the flight box takes over, 6/6 on the rig) and then **removed on 2026-09-27**,
the user's call - the boomerang should behave as it does in the arcade, and the
release geometry was the actual fault. It is in git history if it is ever
wanted; do not re-add it to MAINEQU.ASM without reading the next paragraph.

### MAINEQU.ASM is a cliff

Removing that feature was not only a behaviour decision. `MAINEQU.ASM` is
`.include`d by ~70 objects, so every line in it is assembled 70 times, and
`MKDEATH.ASM` at 7,245 lines is the module closest to GSPA's memory ceiling -
it already needs `PASS 1.1`/`PASS 1.2 ON SECTION .text`. While MAINEQU sat ~84
lines above HEAD, MKDEATH failed with `>> Out of memory, Aborting` and nothing
linked at all. Trimming prose did not fix it and neither did removing two
symbols; only getting the file back to about its HEAD length did. It is 4,779
lines now against HEAD's 4,781, and that is the working ceiling, not headroom.
Prose belongs in doc/.

### Rig

`tools/run_jade_boom_prezap_test.ps1` - a distance sweep, because distance is
the whole claim. 6/6. It asserts:

1. the release displacement is the arcade's **+72,+32**, read off the objects
   rather than inferred from whether something got hit - this is the entire
   change in one number, and a 112 here means the old anchor step is back;
2. the flight loop is **7** distinct frames - six means `UBREL4` fell out of the
   lane again;
3. 72, 104, 130 and 190 px each connect **once**, by the flying blade (72 is the
   one that matters - it was a clean miss before);
4. 24 px does **not** connect, which is the arcade's own hole and also the check
   that no prezap is compiled in;
5. the blade always flies - measured +297 px every trial.

48 px is **measured and reported, not asserted**: his squeezed column is a
quarter of his width, so whether it reaches +65 on the first flight tick is a
pixel question, and a rig that asserted it would be claiming precision it does
not have.

Two traps it hit, both worth keeping:

* **The blade must be selected by KIND, not position.** A multipart object's
  `oxpos` is its ANCHOR; a single-part object's is its drawn TOP-LEFT. The trail
  puffs carry blade SAGs too, so "furthest downrange" picked puffs routinely and
  counted all six `UBTRAIL` frames as flight frames - 13 instead of 7. The blade
  is the one multipart object with a blade SAG.
* **Leaving the fight mid-run is a crash, and the rig now says so.** A blown
  system stack shows up here as `gstate 2 -> 0` a tick or two after the release,
  with no lockup and no Lua error; without that check the run just reads as "the
  throws stopped firing".

### The trap that cost a build cycle

`mmtm sp,a0,a1,a2,a5,a10` against `mmfm sp,a0,a1,a2,a10` in the same routine.
Adding `a5` to the save list (for `adjust_xy_a5`, which takes its object there)
and not to the restore leaves one word on the system stack, and the `rets`
returns into it. The board resets about 14 ticks into the throw - no lockup, no
assembler complaint, nothing in the log but `gstate 2 -> 0`. If a routine grows
a register in its `mmtm`, check the `mmfm` in the same edit.

### The old boomerang rigs were blind, not passing

`jade_boom_arcs_test.lua`, `jade_boom_contact_return_test.lua` and
`jade_boom_shadow_test.lua` all carried a hardcoded blade SAG window of
`03c10000..03c32000`. The pack has since moved to `03bd5f10`, so `find_blade`
matched **nothing** and the contact-return rig reported "blade only tracked for
0 tick(s)" against a perfectly good ROM. All three now derive the window from
`src/JADERANG.TBL` on every run - the same guard the shadow rig had already
applied to its frame-NAME table, with its own comment explaining why, while its
window went stale anyway.

With that fixed all three PASS - all four arcs, the returning throw's two hits,
the blocked bounce, and the trail.

### The trail hitches exactly once, at contact

Fixing the SAG window let the shadow rig reach an assertion it had never been
able to run, and it failed it: *"puffs are 27 px apart, want ~18"*. The data
turned out to be clean rather than noisy - spawns at rel 118, 120, 122, **125**,
127, 129, 131, 133, 135 at x 576, 594, 612, **639**, 657, 675, 693, 711, 729.
Every gap is exactly 18 px except one 27, and that one straddles the contact
tick (rel 123).

The cause is two lines of MKZAP. A hit leaves `jbp_loop` for `jbp_fly_through`,
and `jbp_fly_through_start` **reloads the spawn countdown** (`movk 2,a11`)
rather than trusting `a11` across `strike_check` / `init_anirate` /
`jbp_reverse_x` - deliberately, and the comment there says so. The echo that
was due two ticks after the last one therefore arrives three ticks after it:
one 9 px tick of extra blade travel, once per flight.

That is the ROM being slightly uneven, not wrong, and the trail through the
fly-out is our own addition anyway (UMK3's two post-contact loops spawn no
trail at all). So the rig now carries an **allowance for that one transition**
and holds every other gap to 18. It is an allowance, not a widened tolerance,
and that distinction was tested rather than asserted: with `BLADE_SPEED`
temporarily set to 12 the strict path fires on **8 of the 9 gaps**, so the
check is demonstrably still live everywhere except across contact.

### The anipoints were checked against the source, not assumed

Before touching the rig, every record was compared against
`deadlythirdcombat-main/KITANA7.IMG`, where Midway's own boomerang art lives as
`BOOMERANG1-13` + `BRTRAIL1-6`:

| | ours | KITANA7.IMG | |
|---|---|---|---|
| `UBSPIN1-6` | 27,12 / 13,23 / 16,25 / 26,12 / 21,16 / 5,26 | identical | match |
| `UBTRAIL1-6` | 9,16 / 21,6 / 10,12 / 4,15 / 12,11 / 10,4 | identical | match |
| `UBWISP` | 71,-8 | identical | match |
| `UBREL1` | 46,-13 | 54,-9 | **re-anchored here** |
| `UBREL2` | 24,-5 | 23,3 | **re-anchored here** |
| `UBREL3` | -37,-2 | -43,-1 | **re-anchored here** |
| `UBREL4` | -85,-27 | 25,5 | **re-anchored here** |

Sizes match on all seventeen. So the flight and trail geometry is Midway's to
the pixel and the spacing complaint could only ever have been about the
measurement - and the four REL frames are the documented local deviation (see
"The release path (REL1-4) - a deviation, on purpose").

That last row is also independent corroboration of the prezap analysis above:
KITANA7's `BOOMERANG5` anipoint is `25,5`, exactly what the arcade program ROM
extract reports for REL4, which is what lets the arcade keep the blade's anchor
on its art and move it only +72 with `boomerang_adjust`. Our `-85,-27` travel
anchoring is what puts the whole 112 px step on the anchor at the handoff, and
with it the first strike box 40 px further out.

## The other move: the shadow kick / "Blazing Nitro Kick"

UMK3 reaches it as a *body propel* (`prop_do_jade_prop`, via
`do_body_propell(0x18)`), not a zap. It was ported here from Trilogy in an
earlier pass, and **the arcade agrees with Trilogy on every timing constant**,
so almost nothing needed to change:

| | ours | UMK3 arcade |
|---|---|---|
| drive speed | `080000h` | `0080000h` (8 px/tick) |
| anirate | 1 | 1 |
| windup, no hitbox | 5 ticks | 5 ticks |
| first strike check | tick 6 | tick 6 |
| active window | 7 ticks, damping + check each | same |
| recovery | 8 ticks damping only | same |
| damping | `oxvel -= oxvel>>3` | same |
| tail: whiff / hit / block | `020h` / `010h` / `020h` | `020h` / `010h` / `020h` |
| damage | `01303h` = 19 / 3 | `01303h` = 19 / 3 |

The strike record is `lia_strikes` entry `0x10` - the one
`prop_do_jade_prop` passes to `strike_check_a0`. Same three-way cross-check as
the boomerang: routine `06901h`, and `MKREACT.C` lists `r_jade_prop` at
`069h`.

**What was aligned:** the box shape. It read `067h/028h/04ah/010h` and is now
the arcade's `061h/028h/05bh/014h`. The old box reached 6 px further out but
was 23 px shallower behind the tip - spanning `[29,103]` against the arcade's
`[6,97]`. A box starting that far in front of her is the same shape as the
stock uppercut's point-blank dead zone: an opponent close enough sits inside
the near edge and the kick passes through. The arcade box runs almost back to
her own origin.

The y offset needed nothing - `028h` was tuned here by measurement to make the
kick duckable and had already landed on the arcade's value. The y *size* going
`010h` to `014h` cuts crouch clearance from five pixels to one, so it was
measured rather than assumed: standing P2 takes 19, crouching P2 takes 0
without blocking.

**What was deliberately not aligned:**

- **The animation.** UMK3 has no unique art for this move - it plays
  `ANIM_TABLE1 / ANIM_LOKICK`, the universal low kick, at dash speed. Ours
  runs a bespoke lane plus an `a_fn1_nitro_out` retraction that fixes a problem
  the arcade never had (KTLOKICK1 has no rear leg, so handing that pose
  straight to the stance snapped her ~45 px backwards).
- **The reaction word.** `0171eh` to `r_jc_shadow` here vs `06901h` to
  `r_jade_prop` there. Not portable, and behaviourally they already agree -
  both knock down, both push away at exactly `060000h`.
- **The drone gate.** Ours is range + difficulty (`opener_in_range`,
  `ask_mr_diff`); UMK3's `q_jade_prop` refuses on opponent state,
  `p_hit >= 2`, or a `l_block_fk` cooldown.

Palette flash, smoke cadence and sound were already UMK3-sourced.

## The third move: the Flash (projectile invisibility)

UMK3 reaches it as a *stationary* (`do_jade_flash` -> `do_stationary(STAT_JADE
= 0x1a)` -> `stat_do_jade_flash`, MKSTAT.C). The structure matches ours
closely, including where the immunity hooks in:

```
UMK3    proj_strike_check: if is_jade_protected() -> CARRY_CLR (miss)
                           else strike_check_a0(obj, strkoff)
ours    proj_strike_check: if jade_flash_active   -> carry clear (miss)
                           else strike_check_a0
```

`is_jade_protected()` requires the other guy to be `FT_JADE`, then walks the
active process list for a `PID_JADE_FLASH` process whose `pa8` is that Jade.
**The shield IS the flash process** - there is no flag and no timer. Ours uses
`f_jade_flash`, a per-player `@tick` expiry stamp (`JFLASH_TICKS = 60`).

| | ours | UMK3 arcade |
|---|---|---|
| window | 60 ticks (`JFLASH_TICKS`) | 10 pulses x 6 ticks = 60 ticks |
| blink | 10 x (white 3 ticks, normal 3 ticks) | same |
| white palette | `jade_white_p` (local copy of WHITE_P) | `white_p` |
| player freed after | 4 ticks | `reaction_exit` right after the spawn |
| immunity hook | `proj_strike_check` | `proj_strike_check` |
| immunity carrier | expiry stamp | the flash process's existence |
| sound | once at activation (`0358h` JADEPROTECT) | `ochar_sound(0xc)` once **per pulse**, 10x |
| player cooldown | `l_jade_flash` >= `080h` (128 ticks) | **none** |
| drone cooldown | drone counter branch | `q_jade_flash`: `l_flash` >= `0x40*2` (128) |

Two differences were found. Both were checked against the **arcade ROM**, not
just the port - see "Reading the arcade's code" below.

- **Being hit did not drop our shield. FIXED.** UMK3's `jade_flash_sleep`
  tests `PM_REACTING` on every 3-tick beat and, if Jade is reacting, restores
  her palette and kills the process - which ends the immunity *immediately*,
  because over there the process *is* the immunity. Ours only bailed when the
  round ended, so a flashing Jade who got punched kept projectile immunity for
  the rest of the 60 ticks; there was no counter-play. `jfbp_reacting`
  (MKZAP.ASM) now runs the same test after each beat and `jfbp_done` clears
  the expiry stamp along with the blink.
- **The player cooldown is ours, and it is being KEPT.** `l_flash` is written
  by `stat_do_jade_flash` and read in exactly one place - `q_jade_flash`, the
  *drone* predicate - so the arcade has no separate player gate. But that is
  not the same as "the arcade has no cooldown": 128 ticks is the **only**
  cooldown the arcade defines for this move, and it governs the only actor
  that uses it there. Dropping ours would leave the Flash with no gate at all,
  which matches no arcade code path. Ours keeps the arcade's number and
  applies it to the actor this build actually has.

Everything else - window length, blink cadence, white palette, near-instant
return of control, and the hook point - already matched.

### The Flash tests were stale, not failing

`jade_flash_free`, `jade_flash_cooldown_reuse` and `flash_free_move` had been
failing as "never saw action=0x115" and were being carried as known-broken.
They were a **test** bug: the harness pressed Right then Left, but the input
was changed from Forward,Back to Back,Forward on 2026-07-24 and the sequences
were never updated, so `combo_look_lr` never matched and the move could not
fire. The two `avoid` tests around them (`jade_flash_gated`, `kitana_no_flash`)
were passing for the wrong reason - a dead input avoids everything.

With the directions swapped to match `scom_jade_flash` (the same Left,Right the
boomerang tests already used), `-Modes jade` reports
`PASS reason=all_10_checks_confirmed`: the Flash fires, she walks 100 px while
it runs, the cooldown blocks a re-use at 100 ticks and allows one at 210.

## Reading the arcade's code, not just the port

The PS1 source is a *port*. Its literals are arcade values by construction
(the `SCX`/`SCY` scaling), which is why the data above could be trusted - and
all of it was independently confirmed against the ROM anyway. But the
*behaviour* (tick counts, trajectory constants, the flash rules) was only ever
port-sourced. Those were checked directly in `umk3.zip` afterwards.

**The encoding toehold** came from `boomerang_adjust`, which is real code at
byte `0x0254e0` and decodes exactly:

```
09c0 0048        MOVI  048h,A0
09c1 0020        MOVI  020h,A1
b7a5 0190        MOVE  *A13(0190h),A5,L     ; 0190h = p_slave
c080 ff9bcb30    JAUC  adjust_xy_a5         ; tail call
```

`p_slave` landing on `0190h` confirms the whole read. From there: `09C0|reg` =
MOVI with a 16-bit immediate, `09E0|reg` = MOVI with a 32-bit one, `0D5F` =
CALLA, `C080` = JAUC absolute, `C0nn` = short relative jump, `1800|K<<5|reg` =
MOVK.

**The four trajectories are arcade values.** At byte `0x05446c`:

```
09c0 5000        MOVI  05000h,A0        <- the DOWNWARD arc
c005             JR    -> 0x05447c
09e0 4000 ffff   MOVI  0FFFF4000h,A0    <- the UPWARD arc
c001             JR    -> 0x05447c
...
1820             MOVK  1,A0             <- the RETURN sentinel
c008             JR    -> 0x05447c
0x05447c:        MOVE  ...A13(0310h)...  ; 0310h = p_store8
```

All the entry points converge on one routine that stashes A0 into `p_store8`.
That is the arcade's own jade-zap dispatch, and it carries exactly the
constants the port showed.

**The flash rules are arcade behaviour.** `PID_JADE_FLASH` (`011fh`) appears as
a code immediate in exactly two places, matching its two C uses. At
`0x058108`:

```
09c1 011f            MOVI  011fh,A1              ; the pid
09e7 0970 ffac       MOVI  0FFAC0970h,A7         ; jade_flash_proc
0d5f ff969dd0        CALLA getprc
09e0 2c70 0106       MOVI  001062C70h,A0         ; l_flash
0d5f ff9b84a0        CALLA update_tsl
```

which gives both `jade_flash_proc` (byte `0x05812e`) and `l_flash`'s RAM
address for free. `jade_flash_proc` opens `MOVK 10,A9` - the ten pulses - and
each `MOVI 3,A0 / CALLA prcslp` is followed immediately by a read of offset
`0210h` (`p_flags` is `pdata+110h`) and a conditional branch out. That is the
`PM_REACTING` early-out, in the arcade.

`l_flash` is referenced at exactly two addresses in the whole ROM: the write
above, and one read at `0x03c040` - `MOVI l_flash,A0 / CALLA get_tsl / CMPI`.
The CMPI operand is stored `0ff7fh`, and TMS34010 stores CMPI immediates
complemented, so it is testing **128** - `q_jade_flash`'s `0x40*2`. One
reader, and it is the drone predicate.

`white_p` sits at byte `0x060fbe`: 64 entries, every one `0FFFFh`. (An earlier
scan missed it because MK2's own WHITE_P uses `07FFFh`.)

## Verification

`tools/run_jade_boom_arcs_test.ps1` throws all four in one fight and measures
the live projectile object. Measured, not asserted from source:

```
med  dy=+0     |dx|/tick=9   frame hold=2   7 distinct frames
hi   dy=-225   |dx|/tick=9   frame hold=2   7 distinct frames
lo   dy=+86    |dx|/tick=9   frame hold=2   7 distinct frames
ret  oxvel flipped at tick 40 (xvel=fff70000 = -9 px/tick), came back 441 px
```

It also reads `p_store7` on the thrower's process at the moment of the throw,
which is the only thing that says *which* variant fired - the action code
(`act_jade_boom`) is identical for all four, and so is `dy` for straight and
returning.

The opponent has to be pinned out of the lane for that rig to mean anything: a
hit sends the flight down `jbp_fly_through`, where no arc and no return check
run, so a blade that connects stops being the thing being measured.

`tools/run_jade_boom_shadow_test.ps1` proves the trail from the data: every
echo is one of the six `BRTRAILn` frames, it is the one **paired** with a spin
frame the blade wore in the last few ticks (membership alone would pass a
trail stuck on one echo), its palette slot resolves to sixteen BOOMRNG_P
colours, and its centre lands within a few px of the blade's anchor.

`tools/run_jade_boomerang_test.ps1 -Modes jade` confirms the damage in a normal
fight (`hp 161->141, drop=20`).

`tools/run_jade_nitro_crouch_test.ps1` covers the shadow kick's box in both
directions - the standing control proves it still connects at all, which a
crouch-only test cannot. Its runner now refuses to report PASS unless both
modes actually reached a verdict: a run that dies before the fight logs no
FAIL lines, and the old scoring called that a pass.
