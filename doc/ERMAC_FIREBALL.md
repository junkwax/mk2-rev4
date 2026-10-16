# Ermac's fireball — Down, Back + LP

The green starburst Shao Kahn throws in UMK3, on Ermac, thrown out of Sub-Zero's
normal freeze pose and bursting into BIGXPLODE on contact.

Verified on screen, not just built:

```
python build.py && python makerom.py && python makevrom.py && python mamerom.py --source-video
.\tools\run_ermac_fireball_test.ps1          # PASS ermac_fireball
.\tools\run_ermac_fireball_test.ps1 -Snap 2  # + frames in C:\MAME\snap\mk2
```

```
SOUND at t=10   SEND $00d0          ERMACSHOT, channel 1
FIRED at t=11 (p1_action=0x17)      act_ermac_zap
SPAWNED at t=21  bolt_x=509         Ermac at 469 - out of his hands
TRAVEL at t=28   +70 px forward     10 px/tick
HIT at t=33      p2 bar 161 -> 141  exactly 20
ENDED at t=21                       no wedged process
```

## Three borrowed halves, one new asset

| half | where it comes from | costs |
|---|---|---|
| **Throw pose** | TABLE1 row `026h`, `a_njzap` — the stock ninja ice-throw, i.e. Sub-Zero's normal freeze windup. MKNJ.ASM's own comment on that row already calls it "throwing fireball". | nothing |
| **Flight** | `ERMFIRE1-11`, the UMK3 starburst, imported into a new bank-1 sidecar | 12,476 bytes |
| **Impact** | `BIGXPLODE1-10` (TCXPLODE.IMG) — was in the IMG, never packed | ~37 KB |

Only the flight is new art. Ermac shares the ninja TABLE1, so the throw pose
needed no new rows at all.

## Wiring

| piece | where |
|---|---|
| input | `ermac_lo_punch`, `char_lo_punch[17]` (MOVES.ASM) — reuses `scom_decoy` (D,B); the button separates it from D,B+HP teleport |
| shim | `do_ermac_zap` → `local_zap` with `028h` (MOVES.ASM) |
| launcher | `projectile_jumps[0x28]` → `do_ermac_zap` (MKZAP.ASM) |
| flight | `ermac_zap_proc` (MKZAP.ASM) |
| action | `act_ermac_zap` = `017h` (MAINEQU.ASM) |
| strike | `stk_ermac_zap`, `ermac_strikes[0x23]` (MKSTK.ASM) — 20 hit / 3 block |
| art lane | `a_ermac_fire`, `ermac_anitab2[0x0a]` (MKNJ.ASM) — 11 frames, loops |
| impact lane | `a_ermac_fireboom` (MKZAP.ASM) — `BIGXPLODE1-10`, plays once |
| palette | `ERMFIRE_P` (IMGPAL6.ASM), applied at runtime — the LOD is `POF>` |
| sidecar | `data/ERMFIRE.LOD` → bank 1 `0xBE8000..0xBEE000` |
| sound | `tsound 10dh` in `do_ermac_zap` → `triple_sndtab` $10D → calls $00D0-$00D2, the ERMACSHOT triple staged on OLDRIP (MKSOUND.ASM, `sound/stlaugh_patch.txt` note (26)) |

D,B+LP was free: Reptile's force ball, which Ermac inherits, is **Back,Back**+LP,
so the two do not collide and he keeps the force ball and the slide.

## Six things that were wrong on the way, and what each looked like

Worth keeping, because none of them announced itself as what it was.

**1. The button mask.** `ermac_lo_punch` started with `ermac_hi_punch`'s mask
(`f1b1|...`). `combo_look_lr` fails if any button *in the mask* is held, and
**LP is b1** — so it was asking that LP not be held while the player holds LP.
The move simply never fired, with no error anywhere. Every other LP special uses
`f1b0|f1b2|f1b3|f1b4`; that is the tell.

**2. The strike index moved under it.** `stk_ermac_teleport` landed on
`ermac_strikes[0x22]` from other work while this was being built, pushing
`stk_ermac_zap` to `0x23` — while `ermac_zap_proc` still passed `022h`. It
builds, it runs, and it silently does the teleport's 15/4 instead of 20/3. Only
the balance lock caught it. An index into a table someone else can insert into
is not a constant.

**3. The promoter does not sync anipoints.** `make_ermfire_img.py` was changed to
re-centre the art, LOAD2 re-cut it, and `src/ERMFIRE.TBL` **kept the old
anipoints** — `promote_tbls` syncs SAG and control words but never
`.word W,H,anix,aniy`. The IMG said `(33,29)` and the table still said
`(-59,-39)`. Copy `tmp/load2/<name>.TBL` over `src/` when geometry changes.

**4. UMK3's anipoints are Kahn's hand, not the star's centre.** Carried across
verbatim they drew the star ~55px low and ~92px left — on screen, at the
opponent's *feet*. `make_ermfire_img.py` re-anchors to the frame centre, which
is honest because the star is radially symmetric.

**5. The strike box was still Kahn's.** `stk_sk_spear`'s `078h` puts the front
edge 120px ahead of the object, correct for a 158px bolt anchored at its tail
and badly wrong for a 66px star centred on its origin: the hit landed while the
star was still most of a body-width short. **The rig passed the whole time** —
it checked that a hit happened for 20, not that the art was touching anything.
The box is now the star's own size, centred.

**6. HOBOOM carried no palette** (the burst it replaced, kept because the trap
is general). `skull_hit` reads the frame's `icmap` and
swpals it, and that works there because it uses row `027h`, whose `DRAGNBALL1`
record carries `.long FIRE_P`. `HOBOOM10` has no palette line at all, so the same
read fetched nothing and the burst shipped green-on-green. Kang's own fireball
never notices — its object is already on `FIRE_P` from the flight. Ours names it
outright. Its anipoints are his too (`anix -100`), so the burst also had to be
pulled back 113px to land on the man it hit.

## The art

Eleven frames, `0x95f04` onward in the UMK3 program ROM, off Shao Kahn's
`anitab2` slot `017h` (lane `0x22dbc`, which loops). Identified by
`tools/umk3_ermac_fireball_extract.py`; imported by `tools/make_ermfire_img.py`,
which is gated in Phase D so it cannot silently drift.

**5bpp, not 6.** The arcade stores these at 6bpp but every frame tops out at
colour index 30 against a 31-entry palette, so the re-cut is lossless and costs a
fifth less: 21,925 bytes instead of 26,310 before LOAD2's zero-compression, and
**12,476 bytes** after it, against a 24,576-byte slot.

**Bank 1, deliberately.** `ERMACSLM` and `JADERANG` are pinned to bank 0 because
they are *body* frames: a body casts a shadow and `shadow_p1p2` walks the
compressed data with a CPU read that has no video-ROM bank select. A projectile
casts no shadow and only the DMA — which is bank-aware — ever reads this, so
bank 1 is correct rather than a compromise. It sits at the top of the free run
above MK7MIL, hard under HICLOUD, leaving MK7MIL ~74KB to grow into.

Note the LOD base for bank 1 is **bank-relative** with a `,1` suffix:
`***> 3F40000,1` = `0x2000000 + (0xBE8000-0x800000)*8`. Getting that wrong fails
`check_sag_coverage` with the table pointing `0x4000000` away from its payload.

## Damage

20 on hit, 3 on block. UMK3's own number for Kahn's projectile is **35/6** and
his MK2 spear is **40/8** — both boss-grade, on a character the player never
controls. Ermac also has the teleport and the telekinetic slam.

## The sound — the slot was already waiting for this move

`ERMACSHOT.wav` had been sitting encoded in the ROM on the dead OLDRIP triple
(calls $00D0-$00D2) for a revision, deliberately unwired, reserved for "a
future Ermac move" — `sound/stlaugh_patch.txt` note (26). This is that move,
so the throw now fires it instead of the `tsound 06ah` (Sub-Zero's ice cast)
it borrowed alongside the freeze pose.

Wired through **`triple_sndtab` index $10D** (`sp_effect|85,0d0h`) rather than
as a raw `send_code_a3` to $00D0, which is the other route note (26) offered.
A raw send always takes channel 1; the table route lets `triple_sound` pick
whichever of the three channels is free and lose honestly to a bigger sound.
That is what a projectile cast wants — the raw-send pattern exists for Jade's
flash and the tornado cue, which must not be arbitrated away.

`sp_effect` is the tier both $061 ("lk fireball fire") and $0D4 ("kahn spear
throw") already carry, which is the right company — on screen this **is**
Kahn's projectile. The duration column is **85**, the clip's 1567 ms in
**18.4 ms game ticks**: `soundup` decrements `chan?dur` once per game tick, so
this column is not the DCS track's `Wait()` frame count. Getting that unit
wrong reserves the channel for two to three times the clip and silently
starves the next sound — the trap written up at index $5B in MKSOUND.ASM.

## The rigs

`tools/ermac_fireball_test.lua` checks SOUND / FIRED / SPAWNED / TRAVEL / HIT /
DAMAGE / ENDED, and names the near miss: if Reptile's force ball comes out
instead it reports `act_slow_orb`.

SOUND taps the hardware latch rather than listening — `send_code_a3` writes a
track as two bytes on `@sound` (01d01030h), so the run can assert $00D0-$00D2
went out even with `-sound none`. It pairs those bytes with the parity re-lock
`tools/decode_sound_trace.py` documents: `sndres` leaves an odd byte in the
stream at boot, and blind pairing is a byte out for the whole run — which
reads exactly like the move sending nothing. A real track is $0000-$04FF, so a
high byte above 7 cannot start a pair. `FB_SNDTRACE=1` logs every track the
game sends, which is what separates "the move sent nothing" from "the tap saw
nothing".

It also carries a fix that applies to **every** Ermac rig in the tree. The five
Block presses never armed the unlock: `check_ermac_blk_cheat` gates on the select
**cursor** via `*a13(p_mychar)`, which a rig poking `@p1_char` does not move, so
`ermac_teleslam_test`, `ermac_teleport_test` and this one all ran as **Reptile**
— every committed log shows `p1_char=9`. Driving `f_ermac_cheat1` directly (the
flag the fifth press sets, which `ermac_select_cheat_apply` turns into
`ft_ermac`) fixes it, and the cursor and flag must both be held to the end of
select or the apply fires early and the pick drifts off Reptile.
`ermac_teleport_test.lua` **passes for the first time** with that fix.


## The impact — BIGXPLODE1-10, and the victim reaction that was wrong

The burst is `BIGXPLODE1-10` out of `TCXPLODE.IMG`, played by
`a_ermac_fireboom` at the point of contact. It fires on a **block as well as a
clean hit**, and that needs no extra test: `strike_check_a0` returns carry for
both and only `b2` distinguishes them, so a path that never reads `b2` covers
both by construction. On a block the burst lands just in front of the guard,
where the shot actually stopped.

These frames were in `TCXPLODE.IMG` from the start and **no LOD had ever
exported them** — the board carried them in the IMG and never packed the
pixels. `data/MK7MIL.LOD` now packs them beside the `LILXPLODE1-7` it always
carried (~37 KB, bank 1). One palette for the whole IMG, `RDBOOM`, so the proc
swpals that; `ERMFIRE_P` is still loaded from the flight and would otherwise
tint the fire green.

They are **not** centre-anchored: `aniy` runs 29 → 87 against heights of
56 → 84, so the anchor walks to the base of the sprite as it grows and the
burst blooms upward out of the contact point.

### The victim reaction — UMK3's own, ported by its numbers

It took three goes, and the arcade ROM settled it rather than analogy.

| tried | what it is | why wrong |
|---|---|---|
| `0225h` | copied from `stk_sk_spear` | the high byte indexes the **attacker's** table, and `react_to_ermac[02h]` is `r_hipunched` — a jab |
| `1001h` | `r_orb`, Reptile's force ball | not a stumble at all: flies the victim into `land_on_my_back` |
| `1d10h` | `r_lkzap`, Liu Kang's fireball | *is* a stumble, but the wrong one — see below |
| **`1d25h`** | **`r_ermac_fireball`** — UMK3 reaction `065h` | correct |

UMK3 does **not** use one reaction for all projectiles; Liu Kang's fireball
carries `055h`, so "a fireball stumble" was not specific enough.

> **CORRECTION (2026-09-03): `065h` is not the projectile's, it is the OVERHEAD
> HAMMER's.** MK3's arcade *source* settles it where a disassembly could not.
> `stk_sk_zap` — the green projectile's own strike record — carries routine
> `06415h`, and MK3's reaction table reads `62 r_sk_punch / 63 r_sk_hammer /
> 64 r_sk_charge / 65 r_sk_air_charge`, so the projectile's reaction is
> **`r_sk_charge`** (shake (6,6), `away_x_vel 050000h`, sleep 3). The routine
> transcribed below — shake (10,10), `030000h`, sleep 4, airborne alternate —
> is byte-for-byte MK3's **`r_sk_hammer`**, and MK3's `r_sk_air_charge` (the one
> actually at `65`) is not a stumble at all but a flight into a thud. UMK3's
> table is shifted relative to MK3's in this region — the "alternate = `063h`"
> line below matches MK3's `061h` — so the read was two entries off and landed
> on the hammer.
>
> **Nothing below needs changing for Ermac.** What he got is a stumble, it looks
> right, and 20/3 on a playable character was always a judgement call rather
> than a port. The correction matters to anyone reading this as a fact about
> which UMK3 reaction belongs to which Kahn move. Shao Kahn's own copy of this
> shot uses `r_sk_charge`'s numbers — see doc/KAHN_EYESHOT.md.

Reaction `065h` lives at `0FFAE7720h` (found via UMK3's reaction table at byte
`0x5ab80`, 123 entries — validated against `068h`, the boomerang, whose
push-and-animate shape matches its documented behaviour). Disassembled with
MAME's `dasm`:

```
MOVI FFAE7EB0h,A5     alternate = reaction 063h (a flight, for the heavy case)
MOVK 1,A6
MOVI 000A000Ah,A11    shake (10,10)
MOVI 00030000h,A0     away_x_vel - shove him back
MOVI 00040020h,A9     animate_a9: sleep 4, ani 020h
```

**Which Kahn strike matters, and box size picks the wrong one.** His UMK3 table
has `065h` on index `05h` (70x74, 32/5) and `064h` on `03h`/`04h`. `064h` is a
flight into a landing — a knockdown. Index `04h` is 52x49, the closest match to
the star's own size, so reading the box alone picks it and gets a knockdown
instead of the stumble.

`r_ermac_fireball` (MKREACT.ASM) carries UMK3's shake, push and frame rate
exactly. What does **not** port is the ani index: UMK3 asks for row `020h` of
the victim's TABLE1 and MK2's tables are laid out differently, so it uses `023h`
— this game's "hit in face", the row its own projectiles use. The visible
difference from MK2's own projectile stumble is the shake: `(10,10)` against
MK2's `(4,4)`.

Block stays `025h`. UMK3's `015h` is an index into *its* block table; block
reactions do not port by number.


## The second fireball hung the game — palette ownership

Reported from a live game: throw one fireball, fine; throw a second and it
locks up hard, with the star drawing **black** on the way in. MAME's debugger
had the PC parked on `JA $` inside `illegal_opcode`.

`ermac_zap_proc` was calling `swpal` to put `ERMFIRE_P` on the projectile. That
is wrong for an object one instruction old, and the reason is ownership:

```
swpal   getfpal                 ; take a free colour map
        delpal  <- on a8        ; FREE THE ONE THE OBJECT IS HOLDING
        store the new one
```

A fresh `gmo_proc` object is holding a palette it **inherited and does not
own**. `delpal` → `freepal` decrements that map's count, and `freepal` ends in
`lockup` if a count ever goes negative — which is what the second throw of the
round does.

The black star is the tell *before* the hang: `getfpal` had nothing left to
give, so `swpal` took its early exit and kept the inherited palette, and 6bpp
art indexed into it.

The fix is the idiom `get_noob_shadow_obj` already uses for exactly this
situation — a new object that needs a palette of its own:

```
	movi	ERMFIRE_P,a0
	calla	getfpal
	jreq	ermz_nopal	; no colour map free - carry on without it
	move	a0,*a8(opal),w
ermz_nopal
```

No `delpal`, because there is nothing of ours to free yet. The `swpal` on the
**impact** palette stays — by then the object does own `ERMFIRE_P`, so freeing
it is correct — and `delobjp` releases the last one when the projectile dies.

**...unless `getfpal` failed.** Then the object never took a map of its own, the
inherited one is still on it, and the impact `swpal` frees exactly the map the
spawn was careful not to touch — the same hang, one branch further down. Only
reachable with the colour-map pool already exhausted, which is why four throws
do not find it. `kahn_eyeshot_proc` (MKZAP.ASM) records the take in `p_store3`
and skips the impact `swpal` when it failed; this routine still does not.

### The rig could not have caught this, and now can

`tools/ermac_fireball_test.lua` threw exactly one fireball, and one throw can
never see this: the first allocation succeeds and the pool damage is invisible
until the next `getfpal`. It now takes `FB_SHOTS` (default 1, **regression
value 4**) and judges each shot on its own record.

Confirmed both ways rather than assumed — with the old `swpal` restored the rig
reports `shots landed: 1 of 4` and fails; with the fix, 4 of 4 land at 20 damage
each.


## Both victim sequences were already in the ROM

Neither half needed a new lane — the question "is this prebuilt?" was worth
asking, because both answers are yes.

**The stumble is TABLE1 row `023h`.** `a_njstumble` (and its per-character
twins) is literally `STUMBLE1-6` then a terminator, and `animate_a9` on row
`023h` is what `r_ermac_fireball` was already doing. The only thing added is the
return: the lane ends on STUMBLE6 mid-stagger, and dropping to stance from there
reads as a snap, so the reaction now replays STUMBLE1 for 4 ticks before
`local_reaction_exit`. `get_char_ani` has to re-resolve the row first because
`animate_a9` leaves `a9` on the terminator.

**The block shudder is `block_shake`.** It already does exactly the described
sequence:

```
block_shake
	calla	get_char_ani        ; row 0bh - the block lane
	addi	32,a9               ; skip BLOCK1, start on BLOCK2
blk2	calla	do_next_a9_frame    ; BLOCK2
	move	a11,a0 / prcslp
	calla	do_next_a9_frame    ; BLOCK3
	move	a11,a0 / prcslp
	subi	32*2,a9             ; step back
	dsj	a10,blk2            ; a10 = how many 2,3 pairs
```

`a10` is the pair count, so `3` is BLOCK2,3,2,3,2,3. Stock `b_standard` uses
`a10=2`; `b_ermac_fireball` (block_xfers `02ah`) is `b_standard` with `a10=3`
and a gentle `away_x_vel 018000h`, because `blocked_start` does not move the
blocker at all and a fireball bursting on a guard should push it. Deliberately
not `b_kahn_sonic`, which SKIDS the blocker — that is a zoning tool's job.

The block index was `025h` until now, which is `b_kahn_punch`: the fourth Kahn
value that came across with the strike box and means something different here.
The others were the box offset, the HOBOOM anipoints and the hit reaction.
