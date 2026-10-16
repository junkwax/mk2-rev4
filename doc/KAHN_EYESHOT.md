# Shao Kahn's green projectile

The star Ermac got in `doc/ERMAC_FIREBALL.md`, given back to the man UMK3 drew
it for, with his own wind-up in front of it.

Verified on screen, not just built:

```
python build.py && python makerom.py && python makevrom.py && python mamerom.py --source-video

.\tools\run_kahn_boss_moves_test.ps1 -Mame "C:\MAME\mame_mk2test.exe" `
    -Move eyeshot -PuppetHold -PinPlayers -PinSpacing 208 -AllowP1Damage -Repeat 4
```

```
ack move=eyeshot rel=1
eyeshot_spawn rel=13  bolt_x=624 kahn_x=696 lead=-72     12 ticks of wind-up, 72px in front
eyeshot PASS rel=150 spawn_rel=13 travel=-100 hit_rel=23 hp=161->126 dmg=35 cast=$00d1 impact=$014c
eyeshot PASS ... hp=126->91  dmg=35
eyeshot PASS ... hp=91->56   dmg=35
eyeshot PASS ... hp=56->21   dmg=35
```

...and blocked, which is a different half of the strike record entirely
(`-BlockVictim` holds P1's block button through the move):

```
eyeshot PASS ... hp=161->155 dmg=6 cast=$00d1 impact=$014f
eyeshot PASS ... hp=155->149 dmg=6 cast=$00d1 impact=$014f
```

...and the AI throws it unprompted. A plain Liu Kang vs Shao Kahn match:

```
normal_debug4_change rel=248 debug4=0x5050 p1=(141,107) p2=(325,80)
```

`0x5050` is `kahn_eyeshot`'s own breadcrumb and the pair are 184px apart — the
far band, which is the only band it lives in.

## Where every number came from

**MK3's arcade source, not a movelist and not a guess.**
`c:\Users\you\Workplace\mk3-rebuild-main\mk3-rebuild-main\REV21` has this move
whole:
`sk_zap` (MKBOSS.ASM:361) → `do_sk_zap` / `sk_zap_proc` (MKZAP.ASM:513/544),
`stk_sk_zap` (MKSTK.ASM:112), `r_sk_charge` (MKREACT.ASM). `do_sk_zap` is
short enough to quote in full, and it is quoted in the comment on
`do_kahn_eyeshot` (MKZAP.ASM).

| piece | where |
|---|---|
| wind-up art | `BGEYESHOT1-4` (BOSS8.IMG), eight A/B strips, `a_sk_eyeshot` / `a_sk_eyeshot_rev`, `sk_anitab2[15h]`/`[16h]` (MKSK.ASM) |
| flight art | `ERMFIRE1-11` — the same starburst Ermac throws, shared not copied, via `sk_anitab2[17h]` |
| impact art | `a_ermac_fireboom` = `BIGXPLODE1-10` (TCXPLODE.IMG), already in the ROM |
| launcher | `projectile_jumps[29h]` → `do_kahn_eyeshot` (MKZAP.ASM) |
| flight | `kahn_eyeshot_proc` (MKZAP.ASM) |
| strike | `stk_sk_eyeshot`, `sk_strikes[10h]` (MKSTK.ASM) — 35 hit / 6 block |
| hit reaction | `r_kahn_eyeshot`, `react_to_sk[08h]` (MKREACT.ASM) |
| block | `b_ermac_fireball`, `block_xfers[2ah]` |
| AI | `kahn_eyeshot`, one of `rt_kahn_far`'s seven picks (MKBOSS.ASM) |
| sound | `tsound 10dh` — ERMACSHOT, this move's own UMK3 clip |
| art slot | `data/BOSSHAM.LOD`, bank 0 |

**Timing, ported exactly.** `do_sk_zap` opens `movi 000030024H,a9 / jsrp
animate_a9` — sleep 3 over anitab slot `024h` — then `sleep 010H` and part two
at `movk 4,a0 / jsrp mframew`. So: 4 frames × 3 ticks of lean-in, 16 ticks held
while the star leaves, 3 frames × 4 ticks straightening up. **40 ticks, 731ms.**
That length is the move: it is a far-range zoning throw and walking into it is
meant to be free.

**Slot `024h` is this art, and that was checked rather than assumed.** UMK3's
lane at byte `0x22d58` carries four composites of 95x148, 95x150, 90x145 and
88x131 — BOSS8.IMG's `BGEYESHOT1-4` to the pixel, and their anipoints to within
3px. The same scan puts `BGHAMMERTOP` on slot `01ah`, which is the literal
`movi 01aH,a9` in MK3's own `sk_hammer`, so the slot numbering is shared and
this is a match, not an inference.

**Part two needed no new art.** UMK3's lane is two parts out of the same four
frames: 1,2,3,4 then 3,2,1. `a_sk_eyeshot_rev` is that, and it starts at 3
because frame 4 is already on screen and held through the spawn.

## Three things that do NOT port, and why

The general rule this move is the third example of (after the air knee and the
overhead hammer): **behaviour ports, table indices never do.**

**The strike routine word.** MK3's `06415h` is `064h` into MK3's reaction table
and `015h` into MK3's block table. Neither numbering exists here. What crossed
is `r_sk_charge`'s three constants, by hand.

**The spawn offset.** MK3 positions the star with `adjust_xy_a5(-014h,-6)`,
measured against UMK3's anipoints — which anchor the star near Kahn's hand.
`tools/make_ermfire_img.py` **re-centred** it when the art was imported, so ours
anchors at the frame's middle. Carried across verbatim the star draws a
body-width low and left. `048h,03eh` puts the star's centre where UMK3 puts it:
72px in front of his origin, 62 below it. The rig checks this directly —
`lead=-72` in the log above is that number, read off the object.

**The sound.** `ochar_sound 1` is a per-character index. `tsound 10dh` is
ERMACSHOT, the clip lifted out of UMK3 for Ermac's copy of this shot, so giving
it to Kahn is returning it.

## The audio, read off the latch

Three tracks, all measured at the hardware latch (`@sound`, `01d01030h`) rather
than assumed — the rig taps it, so a `-sound none` run still asserts what the
game *sent*. `tsound` loads its argument into `a0` through a macro, so a
wired-looking source line is not evidence anything went out.

| rel | track | what | from |
|---|---|---|---|
| 0 | `$04e5`/`$04e2` | Kahn's attack voice | `kahn_attack_voice`, MK3's `group_sound 0` |
| 0 | `$00d1` | **ERMACSHOT** — the cast | `tsound 10dh` |
| 22 | `$014c` hit / `$014f` blocked | the impact | `hit_or_blocked_sound 0f1h` |

**These are TRIPLES.** A `triple_sndtab` entry is a BASE track and
`triple_sound` picks whichever of the three channels is free, so `$014a/b/c` all
mean "sk spear hit" and `$00d0/1/2` all mean ERMACSHOT. The rig's first version
looked for the exact base and reported `no_impact_sound` on a perfectly good
`$014c`; sets, not single values.

**The cast is UMK3's own clip for this exact shot.** `ERMACSHOT` was lifted out
of UMK3 for Ermac's copy of this projectile, so giving it to Kahn is returning
it. MK3 calls `ochar_sound 1` there, a per-character index that does not port.

**The impact is an MK2 addition, not an MK3 port, and that is deliberate.**
MK3's `sk_zap_proc` plays no explicit impact sound at all — its audio is the
strike record's `sf_squeeze` plus the reaction's `rsnd_big_smack` and wasted
voice. **`rsnd_big_smack` is a bare `rets` in MK2** (MKSOUND.ASM:762 — the code
after it is dead), so porting that call would add nothing, and
`r_kahn_eyeshot`'s `rsnd_wasted_voice` already covers MK3's `group_sound 2`.
That leaves the burst silent, so `hit_or_blocked_sound 0f1h` is layered on —
which is what `kahn_spear_proc` and `ermac_zap_proc` both do for this class.

`0f1h`/`0f2h` ("sk spear hit"/"blocked") over the obvious alternative `0d1h`/
`0d2h` ("goro fireball hit"/"blocked"), and the reason is that
`hit_or_blocked_sound` reaches the blocked entry by `inc a0` — so the pair has
to make sense as a pair. `0f1h`/`0f2h` are `sp_bighit|31` and `|29`, matched
boss-tier durations. `0d1h`/`0d2h` are `|81` and `|16`, and `0d2h`'s track
(`06ah`) is shared with Sub-Zero's ice cast. A blocked star should not sound
like someone casting freeze.

## The victim reaction — and a correction to the Ermac writeup

`r_kahn_eyeshot` is MK3's `r_sk_charge`: **shake (6,6), `away_x_vel 050000h`,
sleep 3** on the stumble lane. Harder shove and faster recovery than MK2's own
projectile stumble (`r_kahn_spear`: (4,4), `030000h`, sleep 4) — MK3's own
comment says the speed is deliberate, "FASTER STUMBLE = faster recovery", so the
zoning tool does not also buy him a free approach.

Two indices in MK3's version stay MK2's: `a6` (it selects a row of `rs_calls`
through `ochar_call`) and the ani row, which is `023h` here rather than MK3's
`020h`. `a5` **is** MK3's — `airborn_hit_no_sound`, so catching a jumping man
with the star does not also fire the thud.

**doc/ERMAC_FIREBALL.md attributes UMK3 reaction `065h` to Shao Kahn's green
projectile. MK3's source says otherwise, and it is worth writing down because
the same table is going to be read again.**

- MK3's `stk_sk_zap` — the projectile's own strike record — carries routine
  `06415h`, and MK3's reaction table is `62 r_sk_punch / 63 r_sk_hammer /
  64 r_sk_charge / 65 r_sk_air_charge`. So the projectile's reaction is
  **`r_sk_charge`**.
- The routine the Ermac port transcribed (shake `0000a000ah`, `away_x_vel
  030000h`, `animate_a9 000040020h`, airborne alternate) is byte-for-byte
  **`r_sk_hammer`** — the OVERHEAD HAMMER's reaction.
- MK3's `r_sk_air_charge`, the one actually sitting at `65`, is not a stumble at
  all: it is `flight(060000h,-060000h,08000h,5,01eh)` into a thud and a get-up.

UMK3's reaction table is shifted relative to MK3's in this region (the doc's own
"alternate = 063h" lines up with MK3's `061h`), so the Ermac read was two
entries off and landed on the hammer. **It does not matter to Ermac's move** —
what he got is a stumble, it looks right, and 20/3 on a playable character was
always a judgement call rather than a port. It matters to anyone who reads that
paragraph as a fact about which UMK3 reaction belongs to which Kahn move.

## Damage: 35/6, and where it sits

MK3's own number for this move (`02306h`), unchanged, and deliberately below his
spear:

| move | hit | block |
|---|---|---|
| spear (`stk_sk_spear`) | 40 | 8 |
| **green star** | **35** | **6** |
| Ermac's copy (`stk_ermac_zap`) | 20 | 3 |

The spear is the quick committed throw; the star is the slow one that hits
harder and shoves further. Ermac's is a third weaker because a player controls
him.

**The BOX is not MK3's, and copying it would have been the same bug
`stk_ermac_zap` hit.** MK3's `078h/029h` puts the front edge 120px ahead of the
object — right for art anchored at a bolt's tail, wrong for a 66x58 star whose
anipoint was re-centred. The offsets are the star's half-extents (`021h`,
`-01dh`); only the sizes are MK3's (52x49), which are the star's own to within
2px.

## The muzzle flash — the one line Midway commented out

`a_sk_eyeshot` ends on a fifth entry that is not a frame:

```asm
a_sk_eyeshot
	.long	BGEYESHOT1
	.long	BGEYESHOT2
	.long	BGEYESHOT3
	.long	BGEYESHOT4
	.long	ani_sladd		; ...and the muzzle flash on the last frame
	.long	KAHNGLOW
	.long	0

KAHNGLOW
	.long	KAHNGLOWA,0
```

That is MK3's own structure, uncommented. `REV21/MKSK.ASM`'s `a_zap` reads

```asm
a_zap	.long	SHABLO2 / SHABLO3 / SHABLO4 / SHABLO8
;	.long	ani_sladd,KAHNGLOW		<- commented out by Midway
	.long	0
KAHNGLOW	.long	KAHNGLOWA			<- and no terminator
```

**`SHABLO2/3/4/8` ARE `BGEYESHOT1-4`.** 95x148, 95x150, 90x145 and 88x131,
matched by size and anipoint against BOSS8.IMG — the same check that put
BGHAMMERTOP on slot `01ah`. So the four frames this lane already played were
always the MK3 lane; the glow was the only piece of it MK2 did not have.

**Two independent sources agree on which frame it hangs off, and it is not
the last one in the library.** `data/NEWSHAO.IMG` carries a hand-made
IMGTOOL sequence called `sb` (`python tools/imgseq.py data/NEWSHAO.IMG`):

```
sb  sequence  (3 rows)
    SHABLO8      <- idx 272, a pixel-identical duplicate of SHABLO8 (idx 41),
                    made only so the pairing could be previewed
    KAHNGLOWA
    KAHNGLOWB
```

`SHABLO8`, not `SHABLO10`. `SHABLO8` is the release frame — the one
`do_kahn_eyeshot` already holds through the spawn, and the reason
`a_sk_eyeshot_rev` starts at 3 rather than 4. The library also holds
`SHABLO1`, `5`, `6`, `7`, `9` and `10`, and **none of them reached a table in
MK3 either**; they are authored-but-unshipped, and putting them in costs
~25KB of bank 0 that does not exist. The other IMG sequences (`SHAN`,
`SHANSIT`, `SHAOHAM`) are IMGTOOL import batches, not animations — `SHAN`
runs SHABLO1-10 straight into SHADEAD1-5.

**Only `KAHNGLOWA`.** `KAHNGLOWB` is a second flash record in the library that
reached no table in MK3 or MK2, and `data/SKGLOW.LOD` deliberately does not
load it. Midway's `KAHNGLOW` also has no `,0` terminator — the tell that the
line was cut before it ever ran, since `ani2` walks a piece list until it
reads 0. Ours has one, and `tools/audit_multipart_lists.py --check` wants it.

### Where it lives: 306 bytes, bank 1

`KAHNGLOWA` is 29x38 on the 15-entry `SKGLOW_P`, so PPP 4 — and `SKGLOW_P` out
of NEWSHAO.IMG is byte-identical to MK3's own (`REV21/IMGPAL7.ASM`), checked
word for word. It is a **bank-1** sidecar for HAMGLOW's reason: an overlay
object with no shadow, so `shadow_p1p2`'s `shad7` CPU read — which has no
video-ROM bank select and is what pins every body strip in `data/BOSSHAM.LOD`
to bank 0 — never walks it.

It could not go in `data/HAMGLOW.LOD`: that slot is `0xBDFAE0..0xBE0C20` and
its payload is **4,416 of 4,416 bytes**. `0x9FC000..0x9FD000` was unclaimed —
MKSOUL1's slot ends at `0x9FC000`, MK1PSK3's base is `0x9FE800`, and the
10,240 bytes between them belonged to nobody. This takes the bottom 4,096 and
leaves 6,144 free above it. Payload is 306 bytes.

### `p_slave` does not survive `get_proj_obj_m`

The trap, and it was measured rather than reasoned about. `ani_sladd` hangs
the flash on `*a13(p_slave)` — and then `get_proj_obj_m`, eight instructions
later, ends on

```asm
	move	a10,*a13(p_slave),l		; projectiles are slave objects
```

so the **star overwrites the pointer**, the flash is orphaned, and the
`delete_slave` that was supposed to take it frees the star's record instead.
The spark then sits on his face for the rest of the round: the rig watched it
at his x through rel 240 with the object count never coming back down.

`jax_zap_proc` (MKZAP.ASM) guards the same call the same way — save `p_slave`
across it, put it back. Here the flash goes on the **process stack** rather
than a register, because `a2` does not survive a `sleep` and `p_slave` does
not survive the call; the process stack survives both. It is popped at
`keye_no_obj`, which every path through the routine falls into, so the stack
stays balanced even when `get_proj_obj_m` fails.

Restoring `p_slave` rather than deleting the flash with `safe_delobj` is
deliberate: `delete_slave` goes through `delobjp`, which gives the colour map
back. `safe_delobj` does not `delpal`, and he throws this move over and over —
one leaked map per shot drains the pool. The star does not need `p_slave`:
`kahn_eyeshot_proc` owns it and ends on `delete_proj_and_die`, exactly as
`ermac_zap_proc` does.

### And it needs a palette the instant it appears

`gmo_proc` knows nothing about palettes and `SKGLOW.LOD` is `POF>`, so
`kahn_glow_slave_pal` takes `SKGLOW_P` with `getfpal` the moment the lane
returns. This is not cosmetic: a `getobj`-family block comes back **zeroed**,
and `opal 0` is not "no palette" — it IS colour map #0, the pinned map the
life bars and player shadows address by number. Left alone the flash would
reach `delobjp`, `delpal` slot 0, and recolour the HUD for the rest of the
round. Same contract as `jade_boom_slave_pal`.

A failed `getfpal` is left alone rather than forced: the flash draws in the
inherited map for six ticks and `delete_slave` takes it away. Wrong colours
for a tenth of a second beat a pool that can wedge the round.

### Timing: MK3's 16 ticks, split 6 + 10

`KAHNGLOW` is a single image with no lane of its own, so held for the whole
`sleep 010h` it would sit frozen on his face long after the star had gone.
The hold is split `sleep 6` / `delete_slave` / `sleep 00ah` — **6 + 10 = 010h**,
so the move's total timing is unchanged to the tick.

### The rig had to be recalibrated, and that is a finding

The move now puts **two** new objects on `objlst`, and the flash is inserted
ahead of the star. `kahn_boss_moves_test.lua` used to walk `objlst`, take the
first entry that was not there before, and `break` — so it measured the FLASH
and reported `star_never_moved` while the star was flying and hitting for 35.
A green-looking screenshot would have "confirmed" the feature while the rig
called a regression.

It now tracks every new non-player object and tells them apart by what they
**did**: the star is the one that travelled, the flash is one that never moved
and was deleted. The flash's absence is a hard failure, so the glow has a
regression test rather than a screenshot:

```
eyeshot_obj rel=13 obj=0x0107c780 x=696 kahn_x=696 lead=0     <- the flash
eyeshot_obj rel=13 obj=0x0107cba0 x=624 kahn_x=696 lead=-72   <- the star
eyeshot PASS rel=150 spawn_rel=13 lead=-72 travel=-90 facing=left
       hit_rel=22 hp=161->126 dmg=35 cast=$00d1 impact=$014c flash=rel13-19
```

Object count returns to its baseline of 2; the orphaned-flash build sat at 3
for the rest of the round.

## The hold is animated now, and the SPEAR paid for it

MK3 drew ten SHABLO frames for this move and its lane plays four of them, so
Kahn used to stand **frozen** on BGEYESHOT4 for the whole of `do_kahn_eyeshot`'s
16-tick hold. `SHABLO9` and `SHABLO10` are the next two frames of that pose:

```asm
a_sk_eyeshot_hold		; sk_anitab2[1dh]
	.long	BGEYESHOT5		; SHABLO9A,  SHABLO9B
	.long	BGEYESHOT6		; SHABLO10A, SHABLO10B
	.long	0
```

driven after the star is in the air, replacing a dead `sleep`:

```asm
	sleep	6			; the spark rides the release
	calla	delete_slave
	movi	01dh,a9			; a_sk_eyeshot_hold
	calla	get_char_ani2
	movk	5,a0
	jsrp	mframew			; 2 frames x 5 = 00ah
```

**6 + 10 = 010h**, so MK3's total timing is unchanged to the tick. Five ticks a
frame rather than the wind-up's three because this is a settle, not a wind-up.

### The anipoints are hand-adjusted, and that is not optional

BOSS8's `BGEYESHOT` cut and NEWSHAO's `SHABLO` cut are the same art in frames
of reference **one pixel apart**: aligning BGEYESHOT4 (88x131, ani 26,-38)
against SHABLO8 (88x131, ani 26,-39) needs `dy -1`. So `src/MKSK.TBL` carries
`-66/-38/-66/-39` where NEWSHAO.IMG says `-67/-39/-67/-40`, and the lane does
not hop a pixel at frame 4. `sync_mksk_mk5.py` rewrites SAG and control words
only - size and anipoint words are left alone - which is what makes a hand
anchor survive a rebuild. Do not "fix" them back to the IMG.

### Where the bytes came from: the spear

Shao Kahn's SPEAR was removed to pay for this. `a_sk_spear` / `SPEAR1-13` /
`j_spear` (MKSK.ASM), `do_kahn_spear` / `kahn_spear_proc` (MKZAP.ASM),
`kahn_zap` and `kdtest_zap` (MKBOSS.ASM), and **BGSPEAR1-13 - 10,176 bytes of
bank 0**, which SHABLO9/10 then spent ~8,000 of.

**It only became reclaimable because Ermac moved off it.** `ermac_zap_proc`
drew this exact lane while his fireball was standing on Kahn's bolt;
`a_ermac_fire` (MKNJ.ASM:226, the ERMFIRE sidecar in bank 1) took ninja TABLE2
row `0ah` over, which made the spear the last consumer. The `BGSPEAR`
references still in MKZAP.ASM's comments were stale before this change and are
corrected now.

**The AI had already been moved off it too** - `rt_kahn_far`'s own comment reads
"the green star - was a second spear". `kahn_zap` is **kept as a label** and is
now one line, `jruc kahn_eyeshot`: ~15 call sites hang off it (the knee's
out-of-reach bail, the get-up answer, `kahn_zap_or_sonic`, `rt_kahn_start`,
`rt_kahn_far`), every one a tuned range/odds decision, and rewriting them all
would risk the tuning to gain a name. The AI's question was always "throw
something"; only the answer changed. Going through `kahn_eyeshot` rather than
duplicating it means those sites also pick up its `debug4 = 05050h` breadcrumb.

**`kdtest_zap` (rig code 12) was deleted, not re-pointed.** An alias would make
`-Move 12` quietly test the eyeshot and report a pass for it; 12 now falls
through to `kdtest_no` and the rig correctly says `move_not_acknowledged`.

**`stk_sk_spear` (MKSTK row 4) and `r_kahn_spear` (react_to_sk row 02h) stay.**
Both tables are indexed by number, other records point into them by index, and
MKSTK.ASM's own note on `stk_ermac_zap` turns on `react_to_sk[02h]` being what
it is. `sk_anitab1[6]` takes `kahn_dummy`, which is what row `12h` already uses
for a dead row - **not** `a_sk_eyeshot`, whose lane ends on `ani_sladd` and
would read as "lane unwalkable" to `hurtbox_lock.py`.

`doc/hurtbox.lock` was regenerated: one row removed (`06h a_sk_spear`), row
`06h` joining the existing unresolved list beside `12h`. Nothing else moved.

## Checked against UMK3, and three things moved

The port was made from MK3 REV21's asm. Re-checking it against UMK3's own C
source (`UltimateMortalKombat3-master/src/MKZAP.C`, `do_proj_sk_zap`) and
MK3's arcade sound tables found three real divergences. Everything else
matched: damage `02306h`, box sizes `034h`/`031h`, `r_sk_charge`'s four
constants, `group_sound(2)` -> `rsnd_wasted_voice`, the 4x3 wind-up, the
`0a0000h`/anirate-3 flight, and `mframew(4)` recovery.

### 1. The hold is UMK3's 32 ticks, not MK3's 16

```
MK3 asm     sleep 010H          = 16
UMK3 C      process_sleep(0x20) = 32
```

The arcade doubled it between the two games and this now runs 32:
`sleep 6` (the flash) + four hold rows at 6 (`024h`) + `sleep 2`. **This is a
balance change** - the move is 16 ticks longer end to end and correspondingly
more punishable. UMK3 does not ANIMATE its hold, it just freezes for longer;
the frames are ours, the window is theirs.

### 2. The cast sound fired 12 ticks early

Both arcade sources put `ochar_sound(1)` **after** the lean and immediately
before the projectile is fetched:

```asm
MK3    animate_a9 (lean forward) / movk 1,a0 / calla ochar_sound
UMK3   animate_a9(3,ANIM_ZAP);  ochar_sound(1);
```

`tsound 10dh` was at the top of `do_kahn_eyeshot`, so the photon cracked
while he was still winding up. Moved: the rig now logs `$00d1@12` against a
`spawn_rel=13`, where it used to read `$00d1@0`.

The **attack voice** is correctly placed and always was - MK3's AI `sk_zap`
opens `clr a0 / calla group_sound` ("voice: attack") before `do_zap`, which is
what `kahn_attack_voice` does in `kahn_eyeshot` (`$04e5@0`).

### 3. `a6` was the wrong boss reaction

`r_kahn_eyeshot` passed `movk 2,a6`, copied from `r_kahn_spear`. `a6` is the
**boss reaction offset** (MKREACT.ASM:383) - it only fires when the VICTIM is
Shao Kahn, indexing `kahn_reactions` (MKBOSS.ASM):

```
2 = sweep kicked            <- was
4 = stumble / shake / smack <- now
6 = uppercutted             <- MK3's literal 6, wrong table
```

MK3's `r_sk_charge` passes 6 with the comment "bossy = stumbly", but that 6
indexes MK3's table, not ours - the same class of non-porting index as the
`06415h` routine word. What ports is the intent, and 4 is the stumble that
also matches the `shake_a11(6,6)` and smack already in the routine.

### The sound was already the right one, and that is now proved

MK3's arcade `st_sk` table (REV21 `MKSOUND.ASM:1480`) names it outright:

```asm
st_sk
	.word	sp_effect|40,02cbH 	; 0 - shadow shoulder (borrow)
	.word	sp_effect|50,0334H	; 1 - fire photon (borrow from kabal)
	.word	sp_hit1|23,018bH		; 2 - klang 1 !!
```

**Track `$0334`.** `sound/stlaugh_patch.txt`'s `ErmacShot` is UMK3 stream
`$318096`, which note (39) had already identified - by spectral correlation,
independently of any of this - as **track `$0334`**. Same stream.

DCSExplorer confirms the shape: `$0334` is 1520.64ms on channel 1, with
`$0335` and `$0336` its channel-2/3 siblings - a triple, which is why the rig
reads the latch as `$00d1` rather than the base of our own triple.

So MK2 plays the exact clip UMK3 plays for this move. The name `ErmacShot` is
a misnomer inherited from the clip's filename; the sound is Shao Kahn's fire
photon, borrowed in UMK3 from Kabal. Our mixing level (`$64`) is deliberately
MK2's own - re-measured against the retail SFX median, not UMK3's `level 110`.

**Note for anyone re-deriving sound numbers**: UMK3's C source is the PSX /
Windows port (`wess_seq_stop`, WESS sequence numbers), so its `MK3SND.H`
`#define ST_SK_PHOTON 330` is a PORT index and does NOT map to a DCS track.
The arcade track numbers live in MK3 REV21's `MKSOUND.ASM` tables.

## The palette, and the hang that is not there

`ERMFIRE.LOD` is `POF>`, so the star carries no ramp and the object would
otherwise draw in Kahn's costume colours. `kahn_eyeshot_proc` **takes** a colour
map with `getfpal` and stores it; it does not `swpal`. `swpal` opens by
`delpal`ing whatever the object currently holds, and a fresh `gmo_proc` object
holds a map it *inherited and does not own* — `freepal` ends in `lockup` when a
count goes negative. That is the hang the second Ermac fireball of a round used
to cause.

**`p_store3` also records whether the take succeeded**, which `ermac_zap_proc`
does not. If `getfpal` came back empty the object is still on the inherited map,
and the `swpal` at impact would then free exactly the map the spawn was careful
not to touch. Only reachable with the colour-map pool exhausted — but it is the
same hang, so the impact path checks first. **`ermac_zap_proc` still has that
hole.**

`-Repeat 4` exists for this class: one throw can never see it, because the first
allocation succeeds and the pool damage is invisible until the next `getfpal`.
Four land at 35 each with no hang.

## The art cost 17,006 bytes and bank 0 had nowhere to put them

These are **body** frames, so bank 1 was never an option — `shadow_p1p2`'s
`shad7` walks the compressed data with a CPU read that has no video-ROM bank
select, and a bank-1 body frame gets a shredded shadow while the sprite itself
draws perfectly. Bank 0's largest free run was **8,132 bytes**.

The strips went into `data/BOSSHAM.LOD` — same IMG, same `BGPAL1_P`, same
`PPP> 6`, and its `ASM> BOSSHAM.TBL` is in `promote_tbls.py`'s
`GENERATED_TABLES`, so the records promote themselves. No new TBL, include,
IMGBUILD step, promoter entry or makevrom slot.

The room came from pulling the chain below it down, which spent only guards the
LODs themselves call slack or frozen:

| sidecar | was | now | note |
|---|---|---|---|
| MTOPFLR | 0x791000..0x79B800 | 0x791000..**0x79A000** | base unchanged; guard 6,832 → 688, art finished |
| RAIN | 0x79B800 | **0x79A000** | 276 bytes, frozen (MK3's records, transcribed) |
| NOOBPORT | 0x79C000 | **0x79A200** | slot size and its 6,984-byte guard **unchanged** — that art is still growing |
| BOSSHAM | 0x7AC000..0x7BA000 | **0x7AA200..0x7BC000** | 72,054 of 73,216 |
| RNVIC7 | 0x7BA000 | **0x7FE200** | out to the ERMACSLM tail, bank 0's largest hole, which had no other claimant |

Every one of those tables is promoted or copied from the LOAD2 snapshot, so a
rebase is self-healing; `tools/check_sag_coverage.py` confirms all 9,292
exported SAGs still land inside their own payloads.

**BOSSHAM's guard is now 1,162 bytes. This sidecar is full** — a fourth Kahn
animation needs a slot moved, not a record appended. FLAPJACK's `0x7BC000` base
is the ceiling and has 8,102 bytes of its own slack if it has to give.

### `tools/rom_space_report.py` was over-reporting bank 0 by 14,318 bytes

`TIMEFLR.IRW` was missing from `makevrom.py`'s `FILE_BANK`, which is the dict
that report walks. Outer Haven's staircase was therefore invisible to it, and
the run after JADERANG showed as one free 15,258-byte hole — the largest in
bank 0 — with the staircase sitting in it. Fixed by adding the entry; placement
was never affected (bank 0 is that lookup's default and the `/E` headers carry
the real bank), and makevrom's own overlap guard would have caught a build
placed there. Bank 0 free reads 53,816 now, not 68,066.

## The rig

`-Move eyeshot` on the shared Kahn harness (`tools/kahn_boss_moves_test.lua`,
`kahn_debug_test` code 18). It judges five things and "the animation looked
right" is not one of them: the star has to **exist** as an object, appear in
**front** of him, **travel the way he is facing**, take exactly
`stk_sk_eyeshot`'s damage, and leave him out of the move.

The direction test earns its keep. A star that spawns and sits still is
`set_proj_vel` never running; one that goes backwards is the `b_fliph` branch
inside it reading the wrong object. Both draw a perfectly good sprite, and a rig
that only checked "damage happened" passes either.

It finds the projectile by **identity** — what is on `objlst` now that was not
there when the move was requested — not by geometry. A multipart root carries
`osizex`/`osizey` of zero (the pieces hold the art), so matching on frame size
can never hit; that cost `ermac_fireball_test.lua` a whole run to discover.

**`-PuppetHold` is required.** Without it the request is never acknowledged: the
AI is still driving and `kahn_debug_test` only runs where Kahn polls it.

**`-PinSpacing 208`.** The move has no range gate of its own, so it fires point
blank too — but its AI entry is far-band only, and at the default 72px you are
testing the move rather than the way Kahn throws it.

**`-BlockVictim`** holds P1's block button from the request to well past
contact. The block byte of a strike record indexes `block_xfers`, a completely
different table from the hit byte, so a landed hit proves nothing about the
blocked path; with the switch on the rig demands the CHIP number and fails if
the *hit* sound triple comes out. BLOCK is a dedicated button in MK2, so no
direction is needed and the victim does not have to be walked into a stance.

**`KAHN_SNDTRACE=1`** logs every track the game sends, not just this move's. A
run reporting `cast=NONE` cannot otherwise tell "the move sent nothing" from
"the tap saw nothing".
