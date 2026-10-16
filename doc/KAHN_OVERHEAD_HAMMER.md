# Shao Kahn's over-the-top hammer, re-cut to nine frames

`kahn_hammer_top` (`src/MKBOSS.ASM`) is Shao Kahn's overhead mallet swing — a
fighting move, not a finisher, whose payoff is the **dizzy** it leaves rather
than the damage it does. It was six frames of `BGHAMMERTOP` art with the strike
on the last one. It is now **nine**, with a purple glow riding the wind-up and a
**branch** at the end: a swing that touches nothing carries on into the floor.

Reference for the pacing it inherited from MK3 is in the routine's own comments;
this file is about what the re-cut changed.

## The lane

`a_sk_hamtop` (`src/MKSK.ASM`, `sk_anitab2` slot `0fh`), eighteen A/B strips out
of `data/BOSS8.IMG`:

| frame | pose | glow | ticks |
|-------|------|------|-------|
| 1 | reaches back for it | — | 2 |
| 2 | takes hold, and **gathers** | — | 2 + **4 windup** |
| 3 | hauls it clear | `HAMMERGLOWTOP1` | 2 |
| 4 | up past the shoulder | `HAMMERGLOWTOP2` | 2 |
| 5 | overhead | `HAMMERGLOWTOP3` | 2 |
| 6 | straight up | `HAMMERGLOWTOP4` | 2 |
| 7 | high overhead | `HAMMERGLOWTOP5` | 2 |
| **8** | **over the top — CONTACT** | glow deleted | 2 (the contact scan) |
| | | | **4 windup + 16 swing** |
| 9 | hammer buried in the floor | — | **24**, whiff only |

**Frames 1 and 3 are the new ones.** Everything from the old lane shifted up by
two, so the old contact frame 6 is now frame 8. Any comment or rig that still
says "contact on 6" is stale.

## A 4-tick windup, then a 16-tick swing

The swing is a flat **2 ticks a frame** from the first reach to the moment the
box closes — seven `sleep 2`s plus frame 8's two-tick contact scan, which is not
a separate hold, it *is* the eighth frame's hold. Two ticks is 27.4fps, the rate
the game already uses for spins and projectiles; at 18.28ms a tick the swing is
293ms.

**In front of that sits `khtp_windup`, 4 ticks on frame 2** — the pose where he
has both hands on the hammer behind him and has not started hauling yet. That is
the anticipation: he gathers, *then* he swings. It sits on 2 rather than 1
because 1 is only the reach and there is nothing to gather on yet, and rather
than at the apex (frame 7) because a hold up there reads as a pause *in* the
swing instead of a wind-up *before* it. Move the constant onto frame 7's sleep
for the apex beat instead — that is where the pre-MK3 pacing put its tell, on
what was frame 5 before the lane grew.

It is deliberately **not** folded into the 16. The swing stays a flat 2 ticks a
frame and the windup is a separate named number in front of it, so either tunes
without disturbing the other — and nothing after contact moves with either,
because the 44-tick sum is measured from contact.

**This puts the tell back, deliberately.** The pacing before was MK3's:
`sk_hammer` hands `striker` an ani speed of 1, so every frame plays at one tick
and the whole swing is over in six. That buys an unreactable startup and pays
for it with a long, fully punishable recovery — a move you punish rather than
one you react to. At 2 ticks a frame the trade goes the other way: the wind-up
is long enough to see and duck, and the nine frames of art actually get shown
instead of flickering past in an eighth of a second. The glow gains too — it
rides frames 3–7, so it is on screen for 10 ticks rather than 5.

Going back to MK3's version is a search-and-replace of the seven `sleep 2`s with
`sleep 1` and nothing else. **None of the numbers after contact move with it** —
they are all measured from contact, not from the start of the move.

## The branch

`p_store3` stopped being a boolean and is now three-way. Test it with `cmpi`.

| `p_store3` | what happened | what the swing does |
|---|---|---|
| 1 | clean hit | stop on 8, hold, retract from 7, cash the dizzy in |
| 2 | blocked | stop on 8, hold, retract from 7, **no** follow-up |
| 0 | touched nothing | play frame 9, quake, retract from 8 |

A **block counts as contact**. The hammer hit a guard, not the ground; a blocked
overhead that also stumbled the blocker through the floor would make blocking it
pointless.

## The ground pound

Frame 9 is Jax's ground punch — `do_quake` (`src/MOVES.ASM`) — copied rather
than called, because `do_quake` drives Jax's own animation and his energy object
through his anitab and only its payoff transfers. All three pieces of that
payoff are present, in `do_quake`'s order:

```
is_he_airborn / is_he_a_boss  ->  no damage (do_quake's own exempts)
damage_to_him + takeover_him r_quake  ->  the stumble
shake_a11 000090008h  ->  the earthquake
```

The shake fires on every path including the two that take no damage, so a
jumping opponent still sees the floor move.

**There is no box and no range test**, exactly as in `do_quake`. A quake is not
a strike; it reaches whoever is standing on the floor. That is the single thing
here most likely to want changing, and if it does, the honest change is a
distance gate on the takeover rather than a smaller number — shaving the damage
just makes it a bad move instead of a strong one.

Damage is `khtp_pound_damage`, `00ah` (10). `do_quake`'s own is `015h` (21), but
that is Jax's *whole move*, where this is what a missed overhead picks up on the
way through. Ten is a quarter of `stk_sk_hamtop`'s 39, which keeps the swing
worth landing.

## The retract, and the timing sum that goes with it

Two reverse lanes, because the two paths leave a different frame on screen:

- `a_sk_hamtop_rev` (slot `10h`) — **7, `BGUPPERCUT7`**. Frame 8 is skipped
  because the contact scan and the post-hit hold are already showing it.
- `a_sk_hamtop_rev8` (slot `19h`) — **8, 7, `BGUPPERCUT7`**. On the whiff path
  frame 9 is what is on screen, so going straight to 7 would teleport the hammer
  back over his head.

**Neither lane runs the wind-up back down at all.** One frame off the impact
pose to `BGHAMMERTOP7`, then straight to `BGUPPERCUT7` — Kahn's uppercut
follow-through pose, which reads as him settling after a big swing. Stance
follows.

This was cut twice. `7,6,5,4,3,2,1` put the hammer back *behind* him, all the
way to the reach he started from, which reads as winding up for a second swing
he never throws. `7,6,5,BGUPPERCUT7` fixed that but still walked him back up
through the raised poses on the way to settling. One frame and a settle is the
whole recovery: **the swing ends, it does not rewind.**

`BGUPPERCUT7` is a three-piece multipart (A/B/C) and needs no special handling —
`mframew` walks it through `do_next_a9_frame` like every other entry. It is the
same frame `a_sk_bigpow` uses as its payoff.

At 3 ticks an entry that is **6 ticks on the connect path and 9 on the whiff**,
down from 21/24 and then 12/15.

**Frame 9 holds for as long as the ground is actually shaking — 24 ticks**, and
that is measured rather than felt. `shake_a11` is handed `000090008h`, which
`es_sub` (`src/MKFX.ASM`) reads as 9 pixels and **eight** iterations, and each
iteration is a `sleep 3`. 8 × 3 = 24.

That number matters because the first two attempts at it were both wrong in the
same direction. At 4 ticks Kahn was lifting the hammer back out of the floor
twenty ticks before the floor stopped moving — the pose that caused the quake
was gone while the quake was still happening. Now the hammer stays buried for
the whole of it and the retract only starts once things settle.

It is the **whole** hold: the ground-pound path jumps *past* MK3's shared 8-tick
`boss_post_hit` rather than adding to it, so `khtp_pound_hold` in `kahtop_quake`
is the only thing keeping frame 9 on screen. If 24 ever drags, the two obvious
shorter settings are `00ch` (12, half the shake — he lifts out as it dies down)
and `008h` (8, one tick per shake iteration); below about 6 the "came from
nowhere" read comes back.

It re-times nothing else. The 44-tick sum below is on the **connect** path only,
and `p_store3` is 0 here, so this number moves freely.

**The follow-up punish is timed against the VICTIM's stun clock, which did not
move when the swing did.** Three numbers have to keep summing to 44 ticks from
contact:

```
00eh (14, MK3's connect-only hold)
+  8  (MK3 boss_post_hit)
+  6  (retract, 2 entries x 3)
+ 010h (16, the wait before kahn_punch)
= 44
```

That last term is the shock absorber and has taken every re-time: `01ch` ->
`007h` adopting MK3's recovery, -> `001h` (its floor) when the retract grew to
seven frames, -> `00ah` when the retract was cut to four entries, -> `010h` now
the retract is two. It has more slack than it has ever had. Let the sum drift past 44 and
the punch lands after the stun has worn off, which hands the player a free hit.

The check that it is still right is that **`kahn_punch` is entered at the same
`rel` it was before** — the retract lost 9 ticks and the wait gained 9, so the
total is unchanged.

The ground-pound path never reaches that wait: `p_store3` is 0 and the test
sends it straight to `drone_reaction_exit`.

## The glow

`a_sk_hamglow` (slot `18h`), five single-image composites, driven by the
**fatality's own overlay code**. `kahn_hamswipe_start` and `kahn_hamglow_start`
are two entry points onto one builder (`kahn_glow_build`) that differ only in the
`sk_anitab2` slot, which travels in `a0` — not `a9`, which is the caller's
animation script.

The glow comes up on frame 3 because that is where the hammer comes clear of his
back; on 1 and 2 a streak there reads as a smear on his armour. It goes to
`front_z+1` immediately, unlike the fatality's, whose hammer is still behind
Kahn when its overlay starts. It is taken down by the sixth
`kahn_hamswipe_next`, on frame 8, running off the table's terminator.

### The art it draws

`data/HAMGLOW.LOD`, **bank 1**, `PPP 4`, 4,416 bytes. Bank 1 is correct and not
a shortcut: these are overlay objects with no shadow, so `shadow_p1p2`'s `shad7`
CPU read — which has no video-ROM bank select and is what pins every body strip
in `data/BOSSHAM.LOD` to bank 0 — never touches them. Its own slot rather than
extra records in `BOSSHAM.LOD` because `PURPHAM_P` is 16 entries, so the art is
4bpp where `BOSSHAM` is 6bpp wall to wall, and a mixed-depth LOD is what garbled
SONICCLAP.

### The garble: `ani0` ORs the control word

**Fixed 2026-09-10.** `HAMMERGLOWTOP2` and `3` drew sheared into offset
horizontal slabs, `TOP5` lost most of itself, and `TOP4` was clean. That pattern
is not random and it is not the anipoints — it is `ani0` ORing each frame's
`icontrol` into the old `oflags` instead of replacing it (`MKDISP.ASM` `gsagof`:
`zext a4,w` / `or a2,a4`), so control bits accumulate and can never clear.

The lead/trail nibble shifts live in bits 8–11, and ORing them forward predicts
exactly what was on screen:

| step | own ctrl | after the OR | effect |
|---|---|---|---|
| `TOP1` → `TOP2` | `4880` | `4a80` | lead 0 → 2 — **sheared** |
| `TOP2` → `TOP3` | `4880` | `4a80` | lead 0 → 2 — **sheared** |
| `TOP3` → `TOP4` | `4a80` | `4a80` | already 2 — **clean** |
| `TOP4` → `TOP5` | `4080` | `4a80` | lead *and* trail 0 → 2 — **most of it gone** |

`TOP4` coming out clean while both its neighbours did not is the whole proof: it
is the only frame whose own control word already equals the accumulated one. The
fatality's side glow had it too (`SIDE1 4b80` → `SIDE2 4880`, `SIDE2` → `SID3
4680`), so one fix covered both.

The fix is the two lines `kahn_sonic_proc` (`src/MKZAP.ASM`) already carries for
the identical bug — SONICLAP sheared into speckle from frame 4 on for exactly
this reason:

```asm
	move	*a8(oflags),a4,w
	andi	dmago|dmaclp|dmawnz|m_fliph|m_flipv|00fh,a4
	move	a4,*a8(oflags),w
	calla	ani0
```

`ani` (`MKDISP.ASM:1571`) masks down to the flip/DMA bits first for exactly this
reason; `ani0` does not, so every caller has to do it itself. **Anything driving
a multi-frame lane through `ani0` needs these lines.**

### Where the anipoints put the streak

**Measured, not guessed.** The overlay is placed by `match_ani_points`, which
puts the glow's own anipoint on Kahn's, so a glow frame's anipoint is "where
Kahn's origin is, relative to this streak". The retail-era blur this replaces
(`BGHAMSWIPE1-4`) was authored that way and landed within about 30px of the
hammer head, one frame of it exactly on it:

| old blur | offset from the hammer head |
|---|---|
| `BGHAMSWIPE1` | (-30, -37) |
| `BGHAMSWIPE2` | (+28, +8) |
| `BGHAMSWIPE3` | (-2, 0) |
| `BGHAMSWIPE4` | (-14, -9) |

Against that yardstick, here is where the current set lands. The `TOP1` anipoint
was set by hand on 2026-09-10 (it had been `(0,0)`, i.e. never set); the other
four are as first authored:

| glow | rides | offset from the hammer head | reads as |
|---|---|---|---|
| `HAMMERGLOWTOP1` | `BGHAMMERTOP3` | (+32, -34) | on the hammer ✓ |
| `HAMMERGLOWTOP2` | `BGHAMMERTOP4` | (+64, -37) | on the hammer ✓ |
| `HAMMERGLOWTOP3` | `BGHAMMERTOP5` | (+64, -16) | |
| `HAMMERGLOWTOP4` | `BGHAMMERTOP6` | (+37, +1) | |
| `HAMMERGLOWTOP5` | `BGHAMMERTOP7` | (+21, +11) | |
| `HAMMERGLOWSIDE1` | `BGFATHAM2` | (+33, -29) | |
| `HAMMERGLOWSIDE2` | `BGFATHAM3` | (+101, +6) | |
| `HAMMERGLOWSID3` | `BGFATHAM4` | (+49, +17) | |

`TOP1` moving from (-79,+27) to (+32,-34) is what put it on the weapon, and it
also put it on the **same side** as the rest of the family — the whole set now
sits up and to the left of the head, which is what a trail leading the hammer
should look like.

These are static measurements against the body art. **Do not read a "detached"
frame off a screenshot without checking the control words first** — before the
`ani0` fix above, three of the five were sheared, and a sheared streak looks
misplaced whatever its anipoint says. With the mask in, the lane draws as one
coherent shape growing along the hammer.

The wiring is unaffected either way — the lane runs, the flip follows Kahn, the
palette is right and the overlay deletes itself. Placement is one command per
frame:

```
python img_anipoint.py list data/BOSS8.IMG --name HAMMERGLOW
python img_anipoint.py set data/BOSS8.IMG --name HAMMERGLOWTOP1 --x 131 --y -3
```

Subtract the offset above from the current anipoint to put the streak's centroid
on the hammer head; add a lead back on if the streak is meant to run ahead of it,
which is what `BGHAMSWIPE1`'s (-30,-37) looks like it was doing. Re-run
`python build.py` afterwards — the SAGs and the geometry both live in
`src/HAMGLOW.TBL`, which is promoted, so nothing has to be edited by hand.

## The fatality's blur is now this glow

`data/BOSS8.IMG` no longer carries `BGHAMSWIPE1-4`. The motion blur was
re-authored as the same purple streak, three frames instead of four:
`HAMMERGLOWSIDE1`, `HAMMERGLOWSIDE2`, `HAMMERGLOWSID3` — and `HAMMERGLOWSID3` is
`BGHAMSWIPE2`'s geometry to the pixel (77x14 at 7,-51 against 6,-51), so this is
a re-skin of one overlay and not a new effect.

`a_sk_hamswipe` points at the new labels; `kahn_hamswipe_start` is otherwise
unchanged. `kahn_hammer` still calls `kahn_hamswipe_next` five times, so the
run-off-the-end that takes the glow down now happens on `BGFATHAM5` instead of
`BGFATHAM6` — one frame after contact rather than two. The fifth call is a no-op
and is left in place deliberately, so restoring a fourth frame needs no code
change.

`BGHAMSWIP_P` (12 entries, near-black) is gone from `src/IMGPAL5.ASM` and
`PURPHAM_P` (16 entries, a blue-to-white ramp) has taken its slot.

## Where the ROM space came from

The eighteen `BGHAMMERTOP` strips are 44,733 bytes and pushed `BOSSHAM` to
86,968 against a 73,216-byte slot. Strips are not a style choice here — the same
nine frames as whole composites are 56,679, measured both ways with
`dosbox_bossham.conf`, and the sidecar total goes 98,914 -> 86,968.

The remaining 13,752 came from **TIMEFLR moving to bank 1**. Outer Haven's
staircase strips are background art — DMA-drawn off a private display list,
never walked by `shadow_p1p2` — so they had no reason to hold 14,336 bytes of
bank 0 open, and bank 1 is where every other background in the game already
lives. `SAHELI`, `MTOPFLR`, `RAIN` and `NOOBPORT` each slid down by exactly that
much behind it, spending none of their own guards; `NOOBPORT` keeps its full
65,536-byte slot and 6,984-byte guard because that art is still growing.

| file | before | after |
|---|---|---|
| `TIMEFLR` | bank 0 `0x786800` | bank 1 `0xBE0000` |
| `HAMGLOW` | — | bank 1 `0xBE4000` (new) |
| `SAHELI` | `0x78A000` | `0x786800` |
| `MTOPFLR` | `0x791000` | `0x78D000` |
| `RAIN` | `0x79A000` | `0x795E00` |
| `NOOBPORT` | `0x79A200` | `0x796000` |
| `BOSSHAM` | `0x7AA200`, 73,216 | `0x7A6000`, 90,112 |

`BOSSHAM` ends with 3,144 bytes of guard. Bank 0's largest free run is back down
to NOOBPORT's 6,984-byte guard, and the largest run anywhere is now 12,168 bytes
in bank 1 above `ERMFIRE`.

## Testing

`tools/run_kahn_boss_moves_test.ps1 -Move hamtop` drives it. Two things about
that rig matter here.

**`-PuppetHold` is required.** Without it the request races the live AI against
a passive dummy and reports `move_not_acknowledged`.

**Making a Kahn move MISS needs `-PinEscape`, added for this work.** Pinning the
pair wide does not produce a whiff: every attack stalks first
(`kahn_stalk_a11` loops until the gap closes to its own target) and a pin Kahn
cannot walk out of makes that loop run forever, which the rig then reports as the
move never firing. So the gap has to start inside the stalk's target and open up
*during the wind-up*, which is also the only way a real fight produces a whiff.
`-PinEscapeDelay` is when, in frames after the request; the default 6 is past the
one-tick stalk and comfortably inside the 14-tick wind-up.

```
# connect -> dizzy
pwsh tools/run_kahn_boss_moves_test.ps1 -Move hamtop -PuppetHold `
    -PinPlayers -PinSpacing 100 -AllowP1Damage

# whiff -> ground pound
pwsh tools/run_kahn_boss_moves_test.ps1 -Move hamtop -PuppetHold `
    -PinPlayers -PinSpacing 100 -PinEscape 160 -AllowP1Damage
```

Breadcrumbs in `debug4`:

| value | meaning |
|---|---|
| `0x5040` | the swing started |
| `0x5041` | connected — victim dizzy |
| `0x5042` | blocked |
| `0x5043` | whiffed — ground pound |

Measured 2026-09-09 at the 16-tick pacing:

| path | contact | damage | recovered |
|---|---|---|---|
| connect | `0x5041` at rel 20 | 39 (161 → 122), dizzy played and ended | rel 145 |
| whiff | `0x5043` at rel 22 | 10 (161 → 151), victim stumbled | rel 55 |

**The `rel` figures move with the timing, and by exactly the amount changed**,
which is the check each time that a change landed where it was meant to:

| change | connect contact | whiff contact | whiff recovery |
|---|---|---|---|
| MK3's 1 tick/frame | rel 9 | rel 11 | rel 39 |
| swing → 2 ticks/frame (+7) | rel 16 | rel 18 | rel 46 |
| frame 9 hold 4 → 24 (+20) | — | — | rel 66 |
| `khtp_windup` 4 (+4) | rel 20 | rel 22 | rel 70 |
| retract → `...5, BGUPPERCUT7` (−9) | rel 20 | rel 22 | rel 61 |
| retract → `7, BGUPPERCUT7` (−6) | rel 20 | rel 22 | rel 55 |

Connect recovery stays at rel 145 across both of those rows on purpose: each
time the retract lost ticks the punish wait gained the same number, so the
44-tick sum is intact. That column not moving **is** the regression test.

The damage and the branch do not depend on any of it.

The hammer-smash fatality still runs end to end on the re-pointed glow
(`0x5030` → `0x5031`, victim dead, Kahn back in the stalk).

### One bug found on the way in

`kdtest_hamtop` (`src/MKBOSS.ASM`) had no `jruc kdtest_yes` and fell straight
into `kdtest_eyeshot`, which overwrites `a0`. Every "test the over-the-top
hammer" request had therefore been throwing the green star instead, and the rig
reported it as the hammer never firing. Same shape as `chd_pressure` falling into
`charge_slam_check` in `MKDRONE.ASM`: the bug arrives when a **new** case is
appended below an existing one that ended in a fall-through to the shared exit.

## NEWSHAO.IMG's two hammer lanes, audited 2026-09-20

NEWSHAO.IMG carries re-exports of BOTH hammer swings and both glows. They were
audited against the BOSS8.IMG art the ROM already uses, and **only one frame of
the four lanes is new**.

### The art is the same art

| | measured | verdict |
|---|---|---|
| `SHAHEADHAM(n)` vs `BGHAMMERTOP(n)` | 0-0.4% of pixels differ, **six of nine identical** | same, 1:1 |
| `SHASIDEHAM(n+1)` vs `BGFATHAM(n)` | 0.2-1.1% (one frame 5.1%) | same, offset by one |
| `HAMMERGLOW*` / `HAMMERGLOWB*` vs `HAMMERGLOWTOP*` / `SIDE*` | 89-98% raw, **0.3-0.9% after `v -> 16-v`** | same picture, inverted indices |

**A note in MKSTK.ASM said `SHAHEADHAM2..8` was `BGHAMMERTOP1-6`. It is wrong**
- wrong on frame count and on size - and is corrected in place. The mapping is
one for one across all nine.

### The glow palette is PURPHAM_P reversed

`HAMGLO_P[i] == PURPHAM_P[16-i]`, pivot at index 8, which is why the glow art
compares as 89-98% different until the indices are inverted. **Packing NEWSHAO's
glow art while still applying `PURPHAM_P` gives a glow that is bright where it
should be dark** - it builds clean and looks wrong. `BGPAL1_P` on the other hand
is byte-identical between the two libraries, so the body art is safe either way.

### Which glow goes with which swing

Settled by RELATIVE anipoint (glow minus body), not by name:

| swing | glow | rides frames |
|---|---|---|
| overhead (`a_sk_hamtop`) | `HAMMERGLOW1-5` / `HAMMERGLOWTOP1-5`, seqscr `GLO1` | **3 -> 7**, one per frame |
| fatality (`a_sk_fatham`) | `HAMMERGLOWB1-3` / `HAMMERGLOWSIDE1,SIDE2,SID3`, seqscr `GLO2` | **3, 4, 5** |

The relative offsets match the pairing the ROM already had to **0-2px on all
eight pairs**, so MK2 was pairing them correctly before this audit.

### NEWSHAO re-anchors, consistently

```
overhead   SHAHEADHAM(n)   - BGHAMMERTOP(n)  =  (-4,-2)   every frame
fatality   SHASIDEHAM(n+1) - BGFATHAM(n)     = (-29,-9)   every frame
```

The -29 is a different anchor convention, not noise. Adopting it would move the
fatality art 29px relative to Kahn's object, which invalidates `stk_sk_hammer`'s
hand-tuned box and the frame-by-frame `kahn_hamswipe_front` / `_next` z logic -
for pixels that are already in the ROM. **So the swap was not made.**

### What WAS taken: SHASIDEHAM1, the startup frame

`a_sk_fatham` now opens on it - Kahn stands with the hammer still down before he
reaches for it, the anticipation beat the BOSS8 cut never had (it opened on
BGFATHAM1 with the hammer already coming up). Five ticks, and **additive**:
nothing below it is re-timed, so the swing, the strike window and every beat the
victim is walked through keep the numbers they were tuned with.

It is packed in `data/MK5MIL.LOD`, not `data/BOSSHAM.LOD`, for two reasons:
BOSSHAM's slot (`0x7980F0..0x7AD4B0`) is full with **zero gap on either side**
(JADMIL1 below, SHASLAM above), and `BOSSHAM.TBL` is in promote_tbls'
`GENERATED_TABLES`, which is copied VERBATIM - a hand-tuned anipoint there would
be overwritten on the next build. `MKSK.TBL` is merged and `sync_mksk_mk5.py`
preserves anipoints, which is the same reason SHABLO9/10 live there.

**Its anipoint is rebased +30,+7** into BOSS8's frame of reference. The pair
either side of the join is `BGFATHAM1` (65,-18) against `SHASIDEHAM2` (35,-25),
so +30,+7 carries frame 1 across with its relationship to frame 2 intact.

Cost: **2,802 bytes**, which fit MK5MIL's existing hole with 442 bytes to spare -
that guard is now thin, so check it before adding anything else to MK5MIL.

Verified: `SHASIDEHAM1A [LIVE]` in `art_ref_graph`, reached from `SHASIDEHAM1`;
`-Move hammer` and `-Move hamtop` both run clean; all Phase D guards pass.
