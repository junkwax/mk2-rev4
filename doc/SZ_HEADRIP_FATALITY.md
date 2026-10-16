# Sub-Zero MK1 Head Rip — source of truth

Sub-Zero's third fatality: he reaches into the victim, tears the head off with
the spine still attached, and holds it up as his victory pose. Built 2026-08-03
from an IMGTOOL World View export, validated in MAME on both screen sides.

Companion docs: [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) (how one
gets wired), [FATALITY_ALIGNMENT.md](FATALITY_ALIGNMENT.md) (how placement
works and how to prove it).

---

## Status

| | |
|---|---|
| Route | direct `movi do_sz_headrip,a7` — **not** in `db1_table`/`db2_table` |
| Trigger | **test hook only**: `sz_headrip_hp_test = 1` (MAINEQU.ASM), plain HP during Finish Him at ≤ `080h` |
| Retail input | **not chosen yet** |
| Existing Sub-Zero fatalities | both untouched — `do_shatter_punch` (db1) and `do_pitch` (db2) |
| AI drone | cannot reach it (drone only goes through `do_fatality_1`/`_2`) |
| Harness | `tools/run_sz_headrip_test.ps1 -Side left|right` → PASS both sides |

`sz_headrip_hp_test` must go to **0** before this ships, at which point a real
`scom_*` pattern goes in `sz_hi_punch` ahead of the shatter combo.

---

## The three lanes

Authored together in IMGTOOL's World View at 12 FPS against one shared anchor.
Tables live in [MKNJ.ASM](../src/MKNJ.ASM); the controller is `do_sz_headrip`
in [MKDEATH.ASM](../src/MKDEATH.ASM).

| beat | source ticks | Sub-Zero | spine | head | victim |
|---|---:|---|---|---|---|
| 1 | 1 | `NJSCORPSWIPE9` | — | — | — |
| 2 | 1 | `NJHIPUNCH2` | — | — | — |
| 3 | 16 | `NJHIPUNCH3` (the grab) | — | — | **shakes** (48 ticks) |
| 4 | 1 | `NJUPPERCUT4` — **the rip** | `SPINERIP1` | his head, pos 1 | `sz_headrip_fall` |
| 5 | 2 | `NJELBO1` | `SPINERIP2` | pos 2 | — |
| 6 | 2 | `NJSUBVIC2` | `SPINERIP3` | pos 3 | — |
| 7 | held | `NJSUBVIC3` — victory pose | `SPINERIP4` | pos 4 | — |

Beats 3 and 5-7 deviate from the 12 FPS export, retuned by eye after seeing it
run: the grab went 10 -> 16 so the reach-in reads before the rip, and the three
raise beats doubled so holding the head up is not a flicker. `NJUPPERCUT4`
stays at 1 deliberately — it *is* the yank, and it carries the prop's biggest
travel (the head crosses 57px between prop frames 1 and 2), so slowing it
softens the one beat that should snap.

`sz_headrip_pairs` stores **authored source ticks**, not scheduler ticks;
`szhr_pair_driver`/`szhr_triple_pair` scale ×5 once (12 FPS = 4.56 scheduler
ticks, ×5 errs slower). Same contract as `rd_decap_body_pairs`.

**Sub-Zero's own pass needed no new art.** Every frame above is a stock
`NINJAS*.IMG` multipart wrapper that already existed in MKNJ.ASM and the video
ROM. Only the two props are new.

### One process drives all three lanes

`szhr_triple_pair` advances Sub-Zero and both props, then sleeps once. Two
sleeping worker processes would drift apart by a scheduler tick; this cannot.
Prop objects/cursors live in `p_store1`..`p_store4` because the beat loop needs
them across yields. Either prop may be zero (object pool exhaustion) and its
lane is simply skipped; `szhr_no_props` still plays Sub-Zero's whole authored
pass, the way `rbd_no_bolt` does for Raiden's missing bolt.

---

## The victim shakes before the rip — UMK3's shake, UMK3's numbers

Added 2026-10-03 by request. UMK3's own head rip ends its victim reaction on
one line (`r_head_rip`, MKFATAL.C):

```c
shake_a8_up(current_proc->pa8, 2, 2, 3, 8);   // -> shake2(obj,2,2,8,3)
```

`shake2` (MKUTIL.C) is `+xpixel,+ypixel / sleep / -xpixel,-ypixel / sleep`,
`shakes` times — so **2 px of x AND 2 px of y together, 3 ticks a half, 8
shakes = 48 ticks** of a 2 px diagonal jitter. Those four numbers are the whole
of what was taken; `szhr_victim_shake` (MKDEATH.ASM) is that loop and nothing
else.

**What was deliberately NOT taken.** UMK3 also poses the victim on
`ANIM_SCARED` (`0x4c`, MKGUYS.H) and then `fast_fadeout`s to a **black screen**
for the rip itself, bringing the players back `set_inviso` against an empty
background. MK2 has no scared lane at all, and our rip plays in the arena with
both props on screen, so neither comes across. The pose, art, props,
separation, blood and everything after the rip stay ours.

**It starts when the GRAB closes, not when he is taken over.** UMK3 reaches
first (`get_char_ani(ANIM_TABLE1,ANIM_HIPUNCH); mframew(6)`) and *then* calls
`takeover_him(r_head_rip)`, so there the two instants are the same. Ours takes
him over before the windup, because that is where `sz_headrip_reach` sets the
separation — so `do_sz_headrip` runs the two approach pairs, hands him the
shake with **`xfer_otherguy`** (the bare transfer; `takeover_him`'s chores were
done already and must not be redone), and only then holds the grab. 48 ticks of
shake inside an 80-tick hold: he struggles, goes limp, the head comes off.

**MK2's own `shake_him_up` could not be used** — it shakes `oxpos` only, and
UMK3's moves both axes by the same amount on the same tick. The harness checks
exactly that (`unpaired=0`), so a port that had reused the x-only routine would
fail there and nowhere else.

`oxpos`/`oypos` **are** the integer halves of `oxval`/`oyval` (DISPEQU.ASM
`080h`/`090h` and `0a0h`/`0b0h` — the same storage), so the writes stick, and
both halves are symmetric so he finishes exactly where `adjust_him_xy` put him.
Nothing re-anchors the victim during the hold, which is the condition
`kahn_bigp_carry` (MKBOSS.ASM) documents as the one that makes a nudge like
this useless. `a8` and `a11` both survive `prcslp`, as Midway's own
`shake_him_up` already relies on.

Measured in MAME, both sides:
`SHAKE OK amp=2/2 hold=3 cycles=8 unpaired=0 samples=90`.

---

## The head is the VICTIM's head

Nine head sprites and thirteen palettes in `SPINERIP.IMG`. The **art** is
shared by body type and the **palette** is what separates characters that
share a silhouette, so `NJSPINE1` serves all five male ninjas and `KTSPINE1`
both female ninjas plus Jade:

| ochar | victim | sprite | palette |
|---:|---|---|---|
| 0 | Kung Lao | `TMSPINE1` | `TMSPINE_P` |
| 1 | Liu Kang | `LKSPINE1` | `LKSPINE_P` |
| 2 | Johnny Cage | `JCSPINE1` | `JCSPINE_P` |
| 3 | Baraka | `UGSPINE1` | `UGSPINE_P` |
| 4 / 5 | Kitana / Mileena | `KTSPINE1` | `KTSPINE_P` / `MILSPNE_P` |
| 6 | Shang Tsung | `STSPINE1` | `STSPINE_P` |
| 7 | Raiden | `RADSPINE1` | `RADSPNE_P` |
| 8 / 9 / 10 | Sub-Zero / Reptile / Scorpion | `NJSPINE1` | `SUBSPNE_P` / `REPSPNE_P` / `SCRSPNE_P` |
| 11 | Jax | `JXSPINE1` | `JXSPINE_P` |
| 12 / 13 | Kintaro / Shao Kahn | `LKSPINEHEAD1` | `LKHED_P` — **no art yet** |
| 14 / 15 | Smoke / Noob | `NJSPINE1` | `SCRSPNE_P` — **stand-in** |
| 16 | Jade | `KTSPINE1` | `MILSPNE_P` — **stand-in** |

Both `sz_head_ani_table` and `sz_head_pal_table` (MKNJ.ASM) are **exactly 17
entries** and must stay that way — `ft_jade` is 16 and anyone can be the
victim, so a short table gets read off the end and jumped through. That is the
bug class that made Jade crash the game from `ochar_power_punches`. Verified
statically: the two symbols are 544 bits apart = 17 longs.

Dropping real art in later is a one-row edit per table — swap `SCRSPNE_P` for
`SMKSPNE_P` / `NOBSPNE_P` and `MILSPNE_P` for `JADSPNE_P` once they exist.

### The head's travel is in CODE; the spine's is in ART

This is the one deliberate split from the "anipoints live in the IMG" rule,
and it exists because each head is a **single record**:

- **Spine** — four records, four authored anipoints. Travel is in the art.
- **Head** — one record per body type. Frames 2-4 move the *object* with
  `ani_adjustxy` (`-65,+38` / `-43,-64` / `-2,-20`). Only the frame-1
  anipoint is per-character, authored so each head starts on its own
  victim's head; because every head then starts at the same drawn position
  (centre `anchor+94.5`, top `anchor+22`, all nine records, to half a pixel),
  one travel schedule lands them all in the same place in his fist.

`multi_adjust_xy` negates dx when the object is flipped, so this still mirrors
correctly with no second set of values — the same reason the NOOBFX rows in
MKNJ.ASM are safe. Confirmed in both facings: the head steps −49/−34/−24 with
Sub-Zero on the left and +49/+34/+24 on the right.

**`szhr_triple_pair` must step the head with `do_next_a9_frame`, not a raw
`ani2`.** Only the command-aware walker applies `ani_adjustxy`; a raw `ani2`
would silently leave the head parked on the victim for the whole pass.

`LKSPINEHEAD2-5` are retired — they were the generic head's four travel
anipoints, all five records shared one deduped payload, and `ani_adjustxy`
replaced them.

---

## Why the victim takes `tongued_fall`, not `decap_fall`

They are the same routine: `decap_fall` creates the `pid_head` worker that
throws a detached head across the screen, then falls through into
`tongued_fall`, which does everything else (neck-blood batch, bloody palette,
`anitab1` slot `3Ch` headless body, stand-there beat, fall to knees, shake).

**Sub-Zero is holding the head, so there must not be a second one.** Entering
at `tongued_fall` is stock — it is exactly what Reptile's tongue fatality does,
for exactly the same reason. `sz_headrip_fall` is barely more than the jump:

```asm
sz_headrip_fall
	calla	rsnd_death_voice
	calla	face_opponent
	...two create_blood_proc calls, see below...
	jauc	tongued_fall
```

The harness asserts `pid_head` never appears in the active process list. That
is the single check most worth keeping if this is ever refactored.

### Neck blood: two layers

`sz_headrip_fall` fires `create_blood_proc` twice before handing off:

- **`0Ah` `decaped_blood`** — the stock decap geyser. `decap_fall` fires this
  *twice* (once itself, once again inside `tongued_fall`), so entering at
  `tongued_fall` gives only one batch; this is the missing first one.
- **`15h` `headrip_neck_blood`** (new, MKBLOOD.ASM) — Baraka's blade-shred
  spray. `do_shred` (his Back,Back,Back + LP) throws `shred_drip` from the
  victim's **torso**, `oypos + 30h..60h` and offset `30h` to one side because a
  blade is arriving from that direction. The copy retargets the spawn point to
  the neck/head (`oypos -8..+16`) and centres the x spread — nothing is
  swinging in from a side here. Art, random throw, gravity and splat are
  `shred_drip` unchanged.

`headrip_neck_blood` runs a fixed 4 bursts of 6 drips out of its own
`p_store1`, because `shred_blood`'s loop condition is the *attacker's*
`p_action == act_shred` and nobody is shredding. The count lives in process
memory rather than a register: `getprc` only guarantees a2/a12 across a
`create`, and it also has to survive a `sleep`. 24 droplets sits well inside
`MAX_BLOOD` (64).

---

## Placement

**The props carry their own placement.** Every exported local offset in the
World View lane is `(0,0)`: Sub-Zero's own object is the anchor, and each
frame's art anipoint (authored in `SPINERIP.IMG`) walks the assembly out of the
victim and up into his hand. `do_sz_headrip` does `match_ani_points` onto him
and nothing else — there is no offset constant, so both facings mirror
correctly by construction (see FATALITY_ALIGNMENT.md §1a).

The one constant is the *victim's* separation:

```asm
sz_headrip_reach	.set	05ch	; 92 px
```

**It is set by the GRAB, not by the props.** `NJHIPUNCH3`'s fist tip reaches
`+80` from Sub-Zero's own anchor, and the victim's near edge sits at
`reach - victim_anix`. The lane was authored at `070h` (112), which leaves the
fist short of *every* victim in the roster:

| victim | `anix` | near edge @112 | gap vs fist |
|---|---:|---:|---:|
| Jax | 21 | 91 | +11 |
| ninjas, Shang | 25 | 87 | +7 |
| Cage, Liu Kang | 29 | 83 | +3 |

`05Ch` puts the fist 8-15px *inside* all of them, so he actually takes hold.

**When this moves, `SPINERIP1` and `LKSPINEHEAD1` must move with it**, same
amount and same sign, or the ripped head stops appearing where the victim's
head actually was. Only frame 1 — frames 2-4 are anchored to Sub-Zero's hand
and do not care where the victim stood. The 112→92 change was paired with
`anix += 20` on both frame-1 records.

`RIPDELTA` in the harness is what proves it: **−6 px** with Sub-Zero on the
left, **+5 px** on the right, unchanged across that retune.

### 2026-10-03: the head goes UNDER the fist

Reported after seeing it run: *"needs the heads under subzeros fist,
everything needs to move down some and a few frames need the head better
aligned with his fist and hand placement."* All three are the same fault.

As it stood, the assembly was placed against **the spine**, not the hand, and
the head rode the spine's far end:

| beat | his frame | fist (centre x, bottom y) | head was | |
|---|---|---|---|---|
| 5 | `NJELBO1` | `(30, 68)` | `x[40,51] y[53,86]` | dangling at the floor on his far side |
| 6 | `NJSUBVIC2` | `(-4, -4)` | `x[6,17] y[-20,13]` | beside his own face, 15 px past the fist |
| 7 | `NJSUBVIC3` | `(-15, -20)` | `x[-18,-7] y[-44,-11]` | **above** the fist, clear of the top of his sprite |

The hold is the one held forever, and there the head stood a head's length
*over* the hand with bare spine between — which is what reads as floating.

The rule now is one rule for all three carry beats: **the holding fist sits on
the top of the head**, so the head hangs under it and the spine runs on down.
Each target is measured off the fist in Sub-Zero's own frame (`NJELBO1`,
`NJSUBVIC2`, `NJSUBVIC3`), not nudged by eye:

| beat | head centre x | head top y | overlap |
|---|---:|---:|---|
| 5 | 30 | 60 | fist covers the top ~8 px |
| 6 | −13 | −4 | fist on the top-right corner |
| 7 | −15 | −24 | fist covers the top ~4 px |

**Beat 6 is pulled a few px outboard of its fist on purpose.** There the fist
is immediately left of Sub-Zero's own masked face (`x[0,17]`), so a strictly
under-the-fist head covers it — and `TMSPINE1`, Kung Lao's hatted head, is 34
wide. Trailing the head outboard also reads better: a head being swung up lags
the hand.

**Frame 1 is not in this.** It is the rip, and it has to stay where the
victim's head actually was — that is `sz_headrip_reach`'s invariant below, and
`RIPDELTA` is what proves it. The beat is one authored tick and the victim is
standing in front of it, so almost none of it is on screen anyway.

**Both lanes moved by identical per-frame deltas**, so the head/spine bond the
art authored is untouched (spine top stays ~23 px under the head top at every
beat). Head via `ani_adjustxy` in MKNJ.ASM, spine via `SPINERIP2-4`'s anipoints
in `data/SPINERIP.IMG` → `img_anipoint.py sync-tbl` → `src/SZSPINE.TBL`:

| record | anix | aniy |
|---|---|---|
| `SPINERIP1` | −93 (unchanged) | −47 (unchanged) |
| `SPINERIP2` | −44 → **−28** | −76 → **−83** |
| `SPINERIP3` | −10 → **15** | −4 → **−20** |
| `SPINERIP4` | 14 → **17** | 14 → **−6** |

Only the anipoints moved, so no pixel moved and no LOAD2 run was needed —
`build.py --asm-only` is enough. Phase D's `img_anipoint.py sync-tbl --check`
is what stops the IMG and the TBL drifting apart.

### The earlier retune onto his fist

As exported, the assembly ended `x[17..32]` while the raised fist is
`x[-16..-10]` — 37px away on the far side of his own head, attached to neither
hand. Frames 2-4 of **both** lanes were shifted in the IMG to ease it onto the
fist, landing at `(-37,-16)`: head fully covering the fist, spine running down
his forearm. **Frame 1 was left out of that shift** — it is the rip beat and
was already on the victim to within 6px. (Frame 1 does move, but only ever with
`sz_headrip_reach`, for the separate reason above. The two edits are
independent: reach owns frame 1, the hold pose owns frames 2-4.) The shift is
eased 1/3, 2/3, 3/3 across frames 2-4 so the travel stays smooth instead of
snapping on the last beat.

Both lanes moved by identical per-frame deltas, so the head/spine relationship
the art authored is untouched.

### The mirror is toward HIM — measured, 2026-10-05

Asked for directly: *"we have to make sure if subzero flips over the opponent
or on the other side the mirror toward him so the hand is over the head."*

Both props hang off Sub-Zero's own anchor and take **his** facing, three
independent ways, and all three have to agree:

| | |
|---|---|
| `match_ani_points` | copies his `oxval`/`oyval` **and**, for a multiparter, `flip_multi`s the prop to his facing |
| `multi_adjust_xy` | negates the head lane's `ani_adjustxy` dx when the object is flipped |
| `ganiof` | mirrors the art about the anipoint |

and his own facing is re-derived, not remembered: `do_sz_headrip` opens with
`face_opponent`, which asks `is_he_right` and `flip_multi`s if it disagrees. So
a cross-up is handled by construction — he turns, and the props are built from
whatever he is at the rip.

**That used to be believed rather than measured.** The 2026-10-03 placement was
verified by looking at two screenshots, which is exactly the kind of check that
silently stops being true. It is now a number, in both facings:

`tools/szhr_align_expect.py` generates, from the art, where each prop must be
drawn **relative to Sub-Zero's anchor, in facing space** (x measured from his
anchor and negated when he faces left). In facing space the same numbers must
come back whichever way he is turned — that *is* "the mirror is toward him" —
and the rig asserts it every frame both props are up:

| run | b4 | b5 | b6 | b7 | |
|---|---|---|---|---|---|
| `-Side left` | 94/22 | 29/60 | −14/−4 | −16/−24 | `flip=false` |
| `-Side right` | 96/22 | 31/60 | −12/−4 | −14/−24 | `flip=true` |
| `-Side right -CrossUp` | 96/22 | 31/60 | −12/−4 | −14/−24 | `flip=true` |

`dx=+0 dy=+0` against the generated expectation on all four beats of all three
runs, 211 samples each. **The 1–2 px between the facings is the only thing the
mirror cannot avoid**: `ganiof`'s flipped offset is `sizex - anix` where the
unflipped one is `anix`, plus `(w-1)//2` truncation — so it is 2 px for an even
width and 1 for an odd one, which is what `ALIGN_TOL_X` covers and nothing more.
A real mirror fault is twice the offset: ~30 px at the hold, ~190 px at the rip.

**`FIST`** is the other half — the hand over the head, in facing space, on the
beats where he is holding it (6 and 7; at the rip the head is still out at the
victim, which is what `sz_headrip_reach` is for). It requires the fist box and
the head box to overlap in x and the head's top to be at or just under the
fist's bottom. The fist boxes are **authored, not computed** — "which pixels are
his hand" is a judgement about a drawing — so the tool fails the build if the
geometry of any strip of those four poses moves, rather than quietly measuring
against a hand that is no longer there.

**`-CrossUp`** is the case as it was put: it stands him on the **wrong** side
through Finish Him, lets the game turn him, and puts him across 15 frames before
the press, so he arrives at the fatality having had to change facing. Nothing in
the rig touches his facing — that is the point. A run that did not actually
cross and turn is a failure, not a pass: `CROSS OK side left->right flip
false->true` is what a real one logs.

**`-Negative`** mirrors the head prop off his facing once it exists (its
anipoint is ~90 px off its anchor, so flipping it about that anchor throws the
head ~190 px across the screen) and the run must report `ALIGN BAD`.

### Watch the sign

`adjust_him_xy` → `multi_adjust_xy` negates dx against **the object it is
moving** — and that is the victim, whose facing `match_him_with_me_f` has just
set *opposite* to Sub-Zero's so he looks at him. A positive dx therefore walks
him **backwards, into the space behind Sub-Zero**. The first run measured him
landing at 576 with Sub-Zero at 688 facing right, i.e. 112 px the wrong way.
The controller passes `-sz_headrip_reach` for this reason. Because the victim's
facing mirrors with Sub-Zero's, the one negated constant is right on both
sides.

### Per-character victims — authored, 2026-10-05

Done, and the numbers are **authored, not fitted**. `data/SUBSPINE.WAX` lays
Sub-Zero's grab frame `NJHIPUNCH3` at the origin and each body's own **STUNNED**
pose — the pose the victim is actually standing in during Finish Him — at the x
his hand should attach. `tools/subspine_wax_import.py` turns that into
`sz_headrip_reaches` (MKNJ.ASM, 20 rows) and `szhr_reach_a0` (MKDEATH.ASM) reads
it off the victim's ochar. Exactly the `head_lineups` precedent this section used
to point at.

| ochar | victim | pose | reach | vs the old 92 |
|---|---|---|---:|---:|
| 0 | Kung Lao | `TMSTUNNED4` | 102 | +10 |
| 1 | Liu Kang | `LKSTUNNED1` | 94 | +2 |
| 2 | Johnny Cage | `JCSTUNNED1` | 87 | −5 |
| 3 | Baraka | `UGSTUNNED7` | 84 | −8 |
| 4/5/16/18 | Kitana / Mileena / Jade / Khameleon | `KTSTUNNED1` | 97 | +5 |
| 6 | Shang Tsung | `STSTUNNED5` | 77 | −15 |
| 7 | Raiden | `RNSTUNNED6` | 99 | +7 |
| 8/9/10/14/15/17/19 | the male ninjas | `NJSTUNNED1` | 91 | −1 |
| 11 | Jax | `JXSTUNNED4` | 88 | −4 |
| 12/13 | Kintaro / Shao Kahn | — | 92 | `sz_headrip_reach` |

**IMGTOOL's `local_dx` is an ANIPOINT offset and it mirrors**: the anchor sits at
`origin - dx` unmirrored and `origin + dx` mirrored. Two of the nine slots are
mirrored, because those stunned poses are drawn facing right and have to turn to
face him — read the sign off `frame_mirror`, not off the number.

**Y is deliberately ignored.** The WAX carries a `local_dy` per victim, but the
game grounds both fighters (`adjust_him_xy` takes `a1 = 0`), so applying it would
lift the victim off the floor. Measured, the authored dy is the editor-side floor
correction — each stunned pose has a different anipoint-to-sole distance — plus a
few px of eyeballing. Taking it would be a bug.

**The ochar → body mapping is read out of `sz_head_ani_table`**, not typed in the
generator, so the reach table and the head-sprite table cannot disagree about
which bodies share a shape. The boss rows carry the fallback as a **literal**,
because `sz_headrip_reach` is a `.set` and a `.set` does not cross objects.

#### Still open: the rip beat is a different constraint

The reach fixes where his **hand** attaches. Where the **ripped head** appears at
the rip is a second constraint, and it is still one fixed anipoint
(`SPINERIP1` + each head's frame-1), so it cannot follow a per-victim victim.
Measured off the art — how far the prop head lands from where that body's head
actually was:

| | Shang | Baraka | Cage | Jax | ninjas | Liu Kang | Kitana | Raiden | Kung Lao |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| old (92) | +0.5 | +13.5 | +8.0 | +1.5 | +2.5 | +11.5 | +11.5 | +19.0 | +20.5 |
| authored | +15.5 | +21.5 | +13.0 | +5.5 | +3.5 | +9.5 | +6.5 | +12.0 | +10.5 |

So it is **redistributed, not introduced** — it was already up to 20 px out for
Kung Lao and Raiden under the single constant, and the mean is near enough
unchanged (9.8 → 10.8). It is one authored tick, with the victim standing in
front of it. The WAX now makes it fixable: a second generated table shifting both
props at creation by `victim_head_cx − prop_head_cx` and removing the shift on
the first beat (frames 2-4 are anchored to his hand) would zero every column.
**Not done** — the WAX authors where the hand attaches, not where the head
appears, so inventing that second number is a change to a beat nobody asked to
move.

---

## Art

`data/SPINERIP.IMG` → `data/SZSPINE.LOD` → `data/SZSPINE.IRW` →
`src/SZSPINE.TBL`, packed into a **new bank-0 sidecar**:

| | |
|---|---|
| Slot | `0x762000..0x7637FF` (6,144 bytes), LOAD2 address `0x05B10000` |
| Payload | **4,594 bytes** (1,550 free) |
| Why here | the free MK5-to-MOVEART2 gap. MOVEART2's own tail is 3,440 bytes — too tight with any margin — and MOVEART1 is frozen |
| Guard | MK5MIL's payload ends at `0x7612F8`, so it keeps `0xD08` bytes |

Packed at two bit depths on purpose: `PPP> 4` for the spine (`SZSPINE_P`, 9
colours), `PPP> 6` for the head (`LKHED_P`, 47). 6bpp for the spine would cost
~760 bytes for colours that do not exist.

`SPINERIP5-13` and `LKSPINEHEAD5-7` are alternate-anipoint takes left in the
IMG by the authoring pass. They are **not loaded** — records 1-4 of each carry
the World View placement this sequence was built against.

### Two objects, not one multiparter

`SZSPINE_P` and `LKHED_P` are different palettes, and MKDISP.ASM's `clip41`
display walk reads the palette translation **once per object**, before its
per-piece loop. So the spine and head cannot be pieces of one `ani2` row. Each
rides its own `gmo_proc` overlay object. Same constraint that split Jade's
victory staff off her body.

Palettes are applied with plain `getfpal` + `move a0,*a8(opal),w`, **not**
`swpal`: SZSPINE.LOD is `POF>`, so the records have no `icmap`, the object's
`opal` comes up garbage, and `swpal`'s unconditional `delpal` can underflow
`freepal` into its lockup.

Z: spine at `front_z+1`, head at `front_z+2` — in front of both players (he is
holding them out toward the camera) and the head in front of the spine it hangs
from. `insobj` sorts ascending `ozval` and the display walk queues from the
head of the list, so higher z draws last = nearer the viewer.

### Anipoint drift guard

`promote_tbls.py` owns SZSPINE.TBL's SAG/CTRL but never touches the
`.word sizx,sizy,anix,aniy` line — and those anipoints *are* the placement. So
`build.py` Phase D runs
`img_anipoint.py sync-tbl data/SPINERIP.IMG src/SZSPINE.TBL --check`. Do not
remove it: a re-export that moves an anchor without moving the table would
silently misplace both props with nothing else to catch it.

---

## Harness

```powershell
.\tools\run_sz_headrip_test.ps1 -Side left  -WarningDismissCount 5
.\tools\run_sz_headrip_test.ps1 -Side right -WarningDismissCount 5
.\tools\run_sz_headrip_test.ps1 -Side right -CrossUp  -WarningDismissCount 5
.\tools\run_sz_headrip_test.ps1 -Side left  -Negative -WarningDismissCount 5   # must FAIL
```

Asserts: `f_death == 11`; **the prop alignment** in facing space against
`tools/szhr_align_expect.lua`, and **the hand over the head** on the hold beats,
both in either facing; **the UMK3 shake** — amplitude 2 in *both* axes, 3
frames a half, 8 cycles, measured off the drawn object and failing the run if
wrong; all four `SPINERIP` and all four `LKSPINEHEAD` frames
render; props appear on the same beat as `NJUPPERCUT4`; **no `pid_head`
process ever exists**; props in front of both players and head in front of
spine every frame; the fatality completes. Logs `RIPDELTA` for placement and a
per-frame CSV, and snapshots each beat.

Two gotchas that cost a run each:

- **The head frames share one SAG.** `LKSPINEHEAD1-4` are pixel-identical and
  differ only in anipoint, so LOAD2's foreground-checksum dedup gives all four
  the same payload address — a SAG→label table can only ever report the last
  one loaded, which looks exactly like "three frames never rendered". The
  harness identifies them by the anipoint `ani2` applied instead.
- **Identifying head frames by anipoint is now obsolete** — every head record
  has its own payload, so a plain SAG lookup names them. It was needed while
  `LKSPINEHEAD1-4` were one deduped payload under four labels, and it went
  through two iterations: a merged unflipped+flipped key table worked only
  while the authored `anix` stayed far apart, then `LKSPINEHEAD4`'s flipped key
  (`16-20 = -4`) collided with `LKSPINEHEAD3`'s unflipped key and silently
  masked frame 3. The harness now checks the head **record** against the
  victim's ochar and proves the travel by watching `oxpos` take four distinct
  values.
- **Bosses and hidden fighters cannot be reached through this harness.**
  `-Victim 12/13` (Kintaro, Shao Kahn) locks up in character *select* at
  ~frame 470, before the fight, because `p2_char` is written to a value the
  select screen cannot represent; `-Victim 16` (Jade) never leaves select at
  all because she is a hidden fighter. Neither is a fault in the fatality —
  copy `battle_stability_sweep.lua`'s `force_matchup` if those paths ever need
  live coverage. The 17-wide tables are verified statically instead.
- **The flipped anipoint offset is `sizex - anix`.** FATALITY_ALIGNMENT.md §1
  describes `ganiof`'s mirror as `(sizex-1) - anix`; the value `ani2` stores in
  the multipart RAM record measures one higher (16 wide, `anix` −107 → 123, not
  122). The harness accepts both forms.

If a run produces no log at all, it is the ROM-checksum warning screen, not the
script — re-run with `-WarningDismissCount 5`.

---

## Touch points

| file | what |
|---|---|
| `data/SPINERIP.IMG` | the art (user-authored in imgtool) |
| `data/SZSPINE.LOD` | sidecar, 4bpp spine + 6bpp head |
| `data/IMGBUILD.BAT` | LOAD2 step 22/22 |
| `makevrom.py` | `CUSTOM_VIDEO_SLOTS` + `FILE_BANK` + `irw_files` |
| `tools/check_load2_log.py` | expected-LOD list |
| `build.py` | Phase D anipoint drift check |
| `src/SZSPINE.TBL` | promoted LOAD2 snapshot |
| `src/IMGPAL6.ASM` | `SZSPINE_P`, `LKHED_P` |
| `src/MKNJ.ASM` | `sz_headrip_pairs`, `a_sz_spine`, `a_sz_head`, `f_sz*` wrappers, `sz_anitab2` 8/9, `.INCLUDE SZSPINE.TBL` |
| `src/MKDEATH.ASM` | `do_sz_headrip`, `szhr_*` drivers, `sz_headrip_fall`, `.ref`s |
| `src/MKBLOOD.ASM` | `headrip_neck_blood` / `headrip_neck_drip` + `blood_procs` slot `15h` |
| `src/MAINEQU.ASM` | `sz_headrip_hp_test`, `.global do_sz_headrip` |
| `src/MOVES.ASM` | test hook in `szhp_fatality` |
| `tools/sz_headrip_test.lua` + `run_sz_headrip_test.ps1` | harness |

## 2026-10-06 - the victim's frame, facing and floor at the grab

Reported: after a super freeze the victim was on the wrong frame, a cross-up
then rip left him inverted / facing wrong, and he dropped a long way at the rip.

- **Frame.** `data/SUBSPINE.WAX` authors the hand against ONE frame of each
  body's dizzy loop (Jax STUNNED4, Raiden 6, Shang 5, Kung Lao 4, Baraka 7, the
  rest 1), but the takeover froze him on whatever he was showing - any of the
  seven when dizzy, frame 1 when thawed off the ice. `tools/subspine_wax_import.py`
  now also generates `sz_headrip_poses` (MKNJ.ASM, index into anitab1 028h; the
  tool proves each lane is seven plain frames in order) and
  `tools/szhr_pose_expect.lua` for the rig. `szhr_pose` (MKDEATH.ASM, replaces
  `szhr_thaw`) stands him on it at the takeover and still restores the shadow
  after a freeze. Bosses (-1) are left alone unless iced.
- **Facing.** A frozen man cannot turn, so a freeze + flip-over gave the takeover
  a man with his back to Sub-Zero; `match_him_with_me_f` already re-derives his
  facing from Sub-Zero's, and the rig now asserts it.
- **Floor.** `match_him_with_me_f` gives him Sub-Zero's anchor y for the grab
  (measured 110 against his own 101/102/112), and `tongued_fall` knelt him there.
  `sz_headrip_fall` now calls `ground_player` first, so his knees land on his own
  `p_ganiy`.

Rig: `run_sz_headrip_test.ps1 -Freeze` super-freezes him before the press, and
the new `GRAB` line checks pose, facing, reach and floor. All PASS:
left -CrossUp -Freeze Jax, right -CrossUp -Freeze Kung Lao, left -Freeze Raiden,
right -CrossUp Shang.

### Mirrored and unmirrored WAX slots (2026-10-06, follow-up)

The game always draws the victim facing Sub-Zero - `frame_mirror = 1` in the
WAX. Only Kung Lao and Liu Kang were mirrored there; the other seven were placed
unmirrored. A body is not symmetric about its anchor, so flipping it moves his
head by twice its offset, and the fist that sits on his head in the WAX missed it
in the game: Raiden 39px, Kitana 33, Cage 24, Jax 11, ninjas 9, Baraka 8, Shang 1.
What the WAX DOES agree on is the head under the hand (75-86px in front of
Sub-Zero, fist tip +79, in all nine slots), so `subspine_wax_import.py` keeps
that: an unmirrored slot's reach becomes `placed + 2 * head`, head = the centre
of his top 14 opaque rows off the anchor. Mirrored slots are unchanged, and
mirroring a slot in IMGTOOL and re-placing it gives the same number. Reaches now
run 60 (Raiden) to 102 (Kung Lao).

At the closer reaches the bodies overlap, and `takeover_him_sr`'s `sans_repell`
had cut `f_norepell` to 64 ticks, so repell came back in the hold and slid
Sub-Zero 3px away from the head he holds (rig: ALIGN b7 dx=+3). `do_sz_headrip`
calls `disable_repell` again after the rip.

Rig, all PASS: Raiden left -Freeze (reach 60, hand on the head - before, 25-30px
short), Kitana right -CrossUp (63).
