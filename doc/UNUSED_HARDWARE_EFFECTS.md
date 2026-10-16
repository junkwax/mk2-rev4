# Untapped T-unit hardware effects — what the blitter can do that MK2 never asked for

**Status:** audit complete, nothing implemented in ROM. Surveyed 2026-08-20
against `mk2-readonly` (retail L3.1 source) and the current `mk2-main` tree,
then **tested live in MAME** — see `tools/hw_effects_demo.lua`, which drives
each effect on a running fight. Two claims in the first draft did not survive
that test and are corrected in place (items 2b and 4).

**TL;DR** — the DMA blitter and the 34010's display hardware carry several
fixed-function features that reach the object pipeline *today* and are simply
never exercised. Three of them (vertical flip, per-object constant colour,
non-square scale) need **no engine work and no new video ROM** — the plumbing
already runs on every blit, the game just always passes the neutral value. This
is the same shape of find as the DMA scaler (`oscale`), which retail pinned at
1:1 and we later used for 2x sprites.

Everything below was verified by grep across both trees; the verification
commands are in the appendix so future sessions can re-check rather than
re-trust. The *behavioural* claims were then checked in the emulator:

```
tools/run_hw_effects_demo.ps1              # narrated tour, recordable pace
tools/run_hw_effects_demo.ps1 -Manual      # drive it yourself from the numpad
```

The demo names each effect on screen as it applies it — which item below it
demonstrates, what to look for, and for the two that do not work, why — so a
screen recording of it is self-explanatory.

---

**Companion document:** this audit covers the **DMA object path**. The 34010's
own graphics instructions and the raster counters are covered separately in
[UNUSED_GRAPHICS_PRIMITIVES.md](UNUSED_GRAPHICS_PRIMITIVES.md) - notably the
`LINE` instruction (zero uses anywhere), the VRAM block fill (used once, at
boot), and `vcount` polling, which gets most of item 7's raster split without
item 7's interrupt cost.

---

**Looking for which primitive to use for a given effect?** [GRAPHICS_CAPABILITIES.md](GRAPHICS_CAPABILITIES.md) indexes this document
and [UNUSED_GRAPHICS_PRIMITIVES.md](UNUSED_GRAPHICS_PRIMITIVES.md) together by *what you want on
screen*, and collects the traps that apply to both.

---

## Summary

| # | Feature | Wired to hw? | Uses in retail | Engine work | Art cost |
|---|---------|--------------|----------------|-------------|----------|
| 1 | Vertical flip (`m_flipv`) | yes, **BUILT** — half of the Portal's sparks | **0** | none | none |
| 2 | Constant-colour substitution (`oconst`) | yes; built as a hit flash and **removed** | text/cursor/PONG + 1 fx | ~1 word write | none |
| 2b | ...its inverse `m_conzer` | yes, but **no-op on compressed art** | 0 | n/a | new art |
| 3 | Non-square `oscale` (X≠Y) | yes, **BUILT** — the hit pop's squash | square scales only | none | none |
| 4 | `dpystrt` as a line offset | yes, but **only from inside the page flip** | 2 fixed values | small | none |
| 5 | `dpytap` horizontal tap | built, then **retired** — a band moves the foreground too | 1 fixed value | small | none |
| 6 | DMA window clip rect | yes | page bounds only | medium | none |
| 7 | Mid-screen raster interrupt | equates only | **0** | high | none |
| 8 | 34010 PPOP / PMASK | equates only | **0** | high | none |
| 9 | Low-bpp art (1/2 bpp) | yes, per frame | text + bogline | none | *saves* ROM |

---

## How the per-object DMA path works (why 1-3 are free)

Every object block carries its own DMA parameters
([DISPEQU.ASM:52-63](../src/DISPEQU.ASM#L52-L63)):

```
ofset   .set 0e0h  ;      (16) precomputed page offset
oflags  .set 0f0h  ; a12  (16) bits 0-5 = DMA control (write/const/flip)
osag    .set 100h  ; a11  (32) source address
osize   .set 120h  ;  a9  (32) h,w
opal    .set 140h  ;  a8  (16) palette
oconst  .set 150h  ;      (16) constant colour   <-- rides in the same long as opal
oflags2 .set 160h  ;  a7  (32) game flags
oscale  .set 180h  ;  a6  (32) [yscale:xscale]
```

`dclipl` reads them with one `mmfm` ([MKDISP.ASM:73](../src/MKDISP.ASM#L73)),
pushes six longs onto the DMA queue
([MKDISP.ASM:188-196](../src/MKDISP.ASM#L188-L196)), and `dma_interupt`
`mmtm`s those six longs straight into the DMA registers
([MKDISP.ASM:252-259](../src/MKDISP.ASM#L252-L259)), descending from
`dmaregs` (0x1a800c0):

```
0x1a800a0  xscl:yscl   <- a6  (oscale)
0x1a80080  cmap:const  <- a8  (opal:oconst)
0x1a80060  hsize:vsize <- a9
0x1a80040  horiz:vert  <- a10
0x1a80020  sagl:sagh   <- a11
0x1a80000  offset:ctrl <- a12 (oflags in the low bits of the control half)
```

So scale, constant colour and the flip/const control bits are delivered to
silicon on **every single blit already**. Nothing needs adding — the game just
never writes anything but the neutral value.

Note the mmtm starts *below* `dmaregs`, so `dmatplft` (0x1a800c0) and
`dmartbot` (0x1a800d0) are **not** part of the per-object payload. That is why
item 6 is a group-level effect, not a per-object one.

Multipart objects re-merge the control word from the art table
([MKDISP.ASM:98-100](../src/MKDISP.ASM#L98-L100)):

```asm
andi	0803fffffh,a12		; clear compress/clip bits
or	a2,a12			; set "bits per pixel"
```

Mask `0x3f` **keeps bits 0-5**, so the write-mode, constant-substitute and both
flip bits survive on multipart fighters too. Only bpp / compression / clip come
from the art.

Single-part frames go through `ani`, which does the same thing with its own mask
([MKDISP.ASM:1571](../src/MKDISP.ASM#L1571)):

```asm
andi	dmago|dmaclp|m_fliph|m_flipv|00fh,a4	; keep flip info and dma info
move	*a1(icontrol),a2,w
or	a2,a4
```

`00fh` covers bits 0-3 — which includes both constant-substitute bits — so
`m_conzer` / `m_connon` / `m_fliph` / `m_flipv` all survive a frame change on
single-part objects as well. Set them once and they stick for the whole
animation.

---

## 1. Vertical flip — free, and the opcode is already built

`m_flipv` (bit 5, `dmavfl`) is honoured end to end: the flip coordinate
adjustment is in the clip path
([MKDISP.ASM:178-183](../src/MKDISP.ASM#L178-L183)), the bit survives every
frame change through both control-word merges (see above), and there is even an
animation-script opcode wired to it — `ani_flip_vert` → `flip_multi_v`
([MKUTIL.ASM:1034](../src/MKUTIL.ASM#L1034),
[MKUTIL.ASM:1190](../src/MKUTIL.ASM#L1190)).

**No `.TBL` in either tree ever emits `ani_flip_vert`.** Retail flips
horizontally thousands of times and vertically zero times. The only other
`m_flipv` references are masks that *preserve* it and `andni`s that *clear* it.

Buys: floor/water reflections, ceiling hangers, portal-inverted bodies, a real
hung-by-the-ankles pose, upside-down juggle spin.

Cost: one opcode in an animation table. Watch the anipoint — the flip adjust
adds `ysize` and nudges back up one line, so the anchor moves to the other end
of the sprite.

**Verified** (`tools/hw_effects_demo.lua`, 2026-08-20): forcing the bit on a
live fighter visibly flips the art, confirming it reaches the DMA. Note that
setting the bit *alone* on a multipart body flips each piece in place and
scatters them — a usable in-game pose needs `ani_flip_vert`, which re-lays the
piece anipoints too. Single-part objects flip cleanly.

**BUILT 2026-08-27** (`warplite_animator`, BGND.ASM, behind `fxdemo`): half of
the Portal's sparks take the bit. `warplite` is a **single-part** object built
by `gso_dmawnz_ns`, which is the case that flips cleanly, and its six frames
now play two ways up for one `ori` and no video ROM. Measured 7 bursts of 15
flipped, and the flipped ones report `oypos` 130 against the authored 124 —
that 6px is the anchor moving to the other end of the sprite, exactly as the
cost note above says.

Roll it per BURST and clear it with `andni` first. `ani0` ORs the frame's
control word into `oflags` rather than replacing it, so a bit set here stays
set until something takes it out — the same accumulation that made the sonic
clap's trail stick.

*It was first put on Yoteigai Tor's bolts, and that is worth recording as a
finding rather than deleting:* the bit was set correctly (`oflags` b5a2 against
b582) and the bolts **still could not be seen**. `LIGHTN_p` is almost entirely
dark blue — its brightest entry is (96,152,224) and most of the ramp is under
(0,0,56) — so against that stage's purple night sky the whole storm renders at
about (0,0,33) on (0,0,24). The bolts are there; a frame-buffer diff finds them
at screen (288,71). Nothing to do with the flip, and a real pre-existing
defect on that stage. Do not verify a flip on art nobody can see.

## 2. Per-object constant colour — free silhouettes and flashes

Substituting a constant for non-zero source pixels (`m_connon`, `dmacnz`) or for
zero pixels (`m_conzer`, `dmacz`) is a hardware mode
([SYSEQU.ASM:264-267](../src/SYSEQU.ASM#L264-L267)). The constant comes from
`oconst`, which the queue already carries.

Retail uses it for: diagnostic text, `MKTEXT`/`MKSEL` drop shadows and the
select cursor, PONG's 7-segment digits
([PONG.ASM:353-356](../src/PONG.ASM#L353-L356)) — and **exactly one in-fight
effect**: Scorpion's spear rope strobes white when the spear is blocked
([MKZAP.ASM:3259-3272](../src/MKZAP.ASM#L3259-L3272)). It is never used on a
*fighter*, and `m_conzer` on its own has *zero* uses in either tree.

That one precedent is the template — it is the whole idiom in ten lines:

```asm
	movi	00e0eh,a0
	move	a0,*a8(oconst),w	; constant color to flash with
	move	*a8(oflags),a9,w	; a9 = normal flags
	move	a9,a10
	andi	0fff0h,a10
	ori	dmacnz,a10		; a10 = "white" flags
```

Keep the normal flags in one register, build a const-substitute variant in
another, and alternate between them to strobe. Note it clears the low nibble
before OR-ing `dmacnz` — the write-mode bits are replaced, not added to.

The black player shadows are the second proof, at full sprite scale —
`shadow_p1p2` does the same thing by hand with `dmacal` and a black palette
([MKDISP.ASM:1760-1764](../src/MKDISP.ASM#L1760-L1764)).

Buys, with **no new art at all**:

- 1-frame white flash on a clean hit
- freeze-blue silhouette (Sub-Zero), burn-red silhouette
- ghost / afterimage trails — re-queue the same SAG at stale positions in a
  const colour
- teleport phase-out, invisibility flicker, electrocution strobe
- ~~`m_conzer` gives the inverse: fill the sprite's transparent region~~ - see
  the correction below

Cost: set `oconst` (one word) and OR the flag into `oflags`. Caveat: the
constant is an **index into the object's own colour map**, so the effect colour
has to exist in the palette that object is already using — same trick the
shadow pass uses with `bpal_black`. For a colour the character's palette does
not contain, swap `opal` for the duration too.

**Verified on hardware** (`tools/hw_effects_demo.lua`, 2026-08-20): setting
`m_connon` + `oconst` on a live fighter collapses the whole multipart body to
one flat colour, shape intact, opponent unaffected.

**BUILT AND REMOVED 2026-08-27** — the first bullet of that list, the 1-frame
white flash on a clean hit. It worked, it cost nothing, and it was taken out
at the owner's call: a white fighter on every connect is a lot of screen for
what it says. The wiring it shared with the squash is still there
(`hit_pop_arm` / `hit_pop_pass`, MKDISP.ASM, behind `fxdemo`) and now drives
item 3 alone, so putting the flash back is three writes and their restore.

Two things the ten-line idiom above does not tell you, and both are why this
entry is longer than "we deleted it":

- **The palette has to come with it.** `oconst` is an index into the object's
  OWN colour map, so a fighter flashed with 0e0eh comes out in whatever his
  costume happens to have at index 14 — a different colour per character.
  `opal` is set to **0** for the duration, because colour map 0 IS `boonpal`,
  pinned for the life of the machine (see the note in `getfpal`), where 0e0eh
  is white. No allocation, nothing that can fail, and it is exactly what
  `shadow_p1p2` does with `bpal_black`.
- **Hook it where a6 is, not where a8 is.** Every ordinary strike lands at
  `block_is_useless` (JOY.ASM), and a8 there is the ATTACKER — the strike box
  is built from his anchor. The victim is `*a13(p_otherguy)`, and `a6` (0/1,
  `bar_reducer`'s own convention) already says which player it is.
  `damage_to_me` is the other door, for throws and flips; it is not the main
  one, which is what the first attempt got wrong.

The state is per PLAYER and never a saved object pointer: `p1_obj`/`p2_obj` are
re-read every frame, so a fighter deleted mid-pop cannot leave the pass writing
into a freed block. That part survives the removal — it is what makes any
two-tick effect on a fighter safe.

Still unspent, and all cheaper than they look now that the idiom is written
down: Noob's shadow identity, a freeze-blue or burn-red silhouette, teleport
phase-out, and afterimage trails for characters that have no trail palette
(`trail_proc`, MKFX.ASM, currently needs a dedicated one per character —
`white_kahn_p`, `green_cage1_p`, `red_cage_p`).

### Correction: `m_conzer` does not work on MK2's art

`m_conzer` fills the *transparent* region, and it needs `m_wrzero` alongside it
(zero pixels are not written at all otherwise). Even with both set, **nothing
happens** — because every fighter frame is zero-compressed. A standard Liu Kang
record carries control word `06580H` ([MKLK.TBL:5](../src/MKLK.TBL#L5)):

```
0x6580 -> bpp = 6, zero-compression = ON (bit 7), ldx = 2x, trx = 2x
```

With compression on, the blitter **skips** transparent runs rather than
emitting zero pixels, so there is nothing for the constant to replace. The
inverse-silhouette / backdrop-plate idea is only available on **uncompressed**
art, which in practice means art authored specifically for it. Tested and
confirmed no-op; the demo script detects the compression bit and says so rather
than showing a blank result.

## 3. Non-square `oscale`

`oscale` is `[yscale:xscale]`, two independent 8.8 values (0x100 = 1:1, smaller
= magnified). `getobj` defaults it to `0x01000100`
([MKDISP.ASM:1234](../src/MKDISP.ASM#L1234)).

Retail varies it in only three places — the `MKFX` grow effects, `MKTOAST`, and
the pit-fall shrink in `MKFALL` — and **every one of those writes a square
scale**. The axes are independent in hardware.

Buys: squash-and-stretch on impact, flattened-by-hammer poses, a projectile
that stretches along its travel axis, dolly-zoom during a fatality.

Cost: none beyond the existing write. Already validated against ZON + 6bpp art
in the boss work, and **re-verified non-square**
(`tools/hw_effects_demo.lua`, 2026-08-20): a 2x-wide / half-height fighter
renders correctly, shadow included.

**BUILT 2026-08-27** — squash-and-stretch on impact, the first item on that
list, sharing the hit pop's two ticks: `0014000d0h` is 80% tall and 123% wide.

Measured rather than asserted, and the SHADOW is what to measure: it is one
flat colour on a light floor, so it segments out of the frame buffer without
any argument about what is sprite and what is not. **45 px wide squashed
against 35 px normal, on the same idle fighter = 1.29x**, where `xscale`
00d0h asks for 1.23x. `tools/hitpop_demo.lua` arms a long pop by hand for that
A/B, because two ticks of a real hit are never the same pose twice.

Arm it only when `oscale` is still `001000100h`. MKFX's grow, MKTOAST and the
pit-fall shrink in MKFALL each own the scale while they run, and a two-tick
squash that stomped one of those would restore the wrong size for the rest of
the round.

## 4. `dpystrt` as an arbitrary line offset — free full-screen shake

`dpystrt` is line-granular, but the game only ever writes the two page
constants ([MKUTIL.ASM:536-544](../src/MKUTIL.ASM#L536-L544),
[MKINIT.ASM:1321-1322](../src/MKINIT.ASM#L1321-L1322)).

Writing an offset shifts the **entire displayed image vertically with zero
redraw and zero DMA cost** — including the HUD. This is the cheap answer to
screen shake, and unlike the camera-based approach it never touches `worldtly`,
so it cannot fight live scrolling.

**Measured** (`tools/hw_effects_demo.lua`, 2026-08-20): the register is
reachable and reads back the expected `fffc`/`effc`, but an external per-frame
write is **always stomped** — the demo wrote `fd7c` and the next frame read
`effc`. The page flip rewrites `dpystrt` every frame and wins.

That does not kill the feature, it locates it: the shake offset has to be added
**inside** the flip write itself
([MKINIT.ASM:1321-1322](../src/MKINIT.ASM#L1321-L1322)), where the game already
computes the value. There is no way to layer it on from outside, which is also
why it cannot be prototyped in Lua — this one needs ROM code.

Still to test once wired: shifting reveals lines belonging to the other page,
and the autoerase colour rows live at lines 510-511
([MKDISP.ASM:1077-1078](../src/MKDISP.ASM#L1077-L1078)). Small amplitudes are
probably clean; large ones need a look.

## 5. `dpytap` — free full-screen horizontal shift

Written exactly once, at init, as `56/2` — "adjust for the curse"
([MKINIT.ASM:1230](../src/MKINIT.ASM#L1230)). It is a live register, and
because nothing rewrites it, a poke sticks.

**Verified working** (`tools/hw_effects_demo.lua`, 2026-08-20): writing it
slides the entire display horizontally — HUD, background and fighters together
— with no redraw and no DMA cost. Unlike `dpystrt`, this one *can* be driven
from outside. Combined with item 7 it becomes per-band wobble.

**BUILT as a per-band effect 2026-08-26 and then switched off. It does NOT
need item 7.** A
`vcount` poll is enough (UNUSED_GRAPHICS_PRIMITIVES §4), and mid-frame
`dpytap` writes ARE visible in MAME — the register feeds `coladdr`, which
midtunit's scanline callback consumes per line, so unlike a palette split
this can be developed and verified here rather than on hardware. The Kahn's
Arena sky shimmer (`arena_heat_proc`, [BGND.ASM](../src/BGND.ASM)) is a
travelling ±1 unit wave across `vcount` 64..98, costing one word write per
scanline band and no DMA at all.

Two things to know before reaching for it:

- **One unit is TWO pixels** at 8bpp. There is no finer horizontal
  adjustment available, so ±2 px is the smallest wobble this hardware can
  express.
- **A band moves everything on those scanlines, and this is what killed it.**
  The effect is applied by the video hardware to the whole row, so every
  plane on that row moves: on Kahn's Arena the band's rows carry Kahn's staff
  and orb, both dragon medallions and the pagoda roofs, and all of them shear
  with the fire. There is no band on that stage containing only background.
  A shimmer that must respect z-order has to move OBJECTS — see
  GRAPHICS_CAPABILITIES.md, "Why the raster band was removed".

## 6. DMA window clip rect

`dmatplft` / `dmartbot` plus the `dmaconfig` selector
([SYSEQU.ASM:238-241](../src/SYSEQU.ASM#L238-L241),
[MKINIT.ASM:1065-1078](../src/MKINIT.ASM#L1065-L1078)) form a hardware clip
rectangle. The game only ever uses it to bound the current draw page
([MKINIT.ASM:1326](../src/MKINIT.ASM#L1326),
[MKUTIL.ASM:533](../src/MKUTIL.ASM#L533),
[MKSEL.ASM:4128](../src/MKSEL.ASM#L4128)).

Buys: rectangular reveal wipes, letterboxed cinematics without art, portal
cut-outs where a fighter only renders inside a shape, mirror panels.

Cost: medium. Because the window registers sit above the queue `mmtm`, changing
them per object means touching the DMA interrupt path — the tightest code in
the game. Treat this as a **group-level** effect: drain the queue, set the
window, draw a batch, restore.

## 7. Mid-screen raster interrupt — the biggest novelty, the most invasive

`hsint` (half screen) and `dirq2int` (just before end of screen) are defined
([SYSEQU.ASM:185-193](../src/SYSEQU.ASM#L185-L193)) and referenced by
**nothing**. Only `eosint` is ever loaded into `dpyint`
([MKINIT.ASM:1213](../src/MKINIT.ASM#L1213)).

Wiring one raster split gives: per-band `dpytap` (heat shimmer over Kahn's
Arena flames, water ripple in the Dead Pool, portal wobble), per-band palette
swaps (different palette above/below a waterline), split scroll.

Cost: high. The display interrupt has to coexist with the DMA-completion
interrupt that drives the object queue, and CRAM writes during active display
may glitch. Prototype behind a `.set` switch.

## 8. 34010 PPOP / PMASK — present, but skip it

All 22 pixel-processing ops are defined
([SYSEQU.ASM:405-427](../src/SYSEQU.ASM#L405-L427)) with zero uses anywhere;
`pmask` is initialised to 0 ([MKINIT.ASM:1225](../src/MKINIT.ASM#L1225)) and
never touched again.

Recommendation: **do not pursue.** Sprites go through the custom DMA, not
`PIXBLT`, and the DMA has no read-modify-write path — so PPOP only applies to
34010-driven blits. A full-screen 34010 pass over 400x254x8bpp will not fit in
an 18.28ms tick. The classic plane-mask tint trick dies for the same reason.

Palette-level tinting (rewriting CRAM entries) remains the cheap route for
full-screen colour effects, and the game already has fade machinery.

## 9. Low-bpp art as a ROM-space lever

The bpp field is per frame, and only text and `draw_bogline` use 1-2bpp
([MKUTIL.ASM:635](../src/MKUTIL.ASM#L635),
[MKDISP.ASM:607](../src/MKDISP.ASM#L607)).

For large flat shapes — shockwave rings, portal discs, smoke plumes, silhouette
props — 1 or 2bpp art is 4-8x cheaper in video ROM than the usual 6bpp, and it
pairs naturally with item 2 (constant colour needs no palette detail at all).
Relevant given the stock-socket constraint. See `SPRITE_COMPRESSION.md` for the
rest of the ROM-budget picture.

---

## Recommended order

1. **Constant colour (item 2)** — built as a hit flash on 2026-08-27 and
   removed the same day for taste, so the *idiom* is proven and written down
   but nothing in the game uses it. Still the best payoff per byte: Noob's
   shadow identity, freeze tint, afterimage trails.
2. ~~**Vertical flip (item 1)**~~ — **built 2026-08-27**, half of Yoteigai
   Tor's bolts. `ani_flip_vert` still has no table that uses it, which is what
   a multipart pose needs.
3. **`dpystrt` shake (item 4)** — cheap experiment, and it sidesteps the
   camera-shake-vs-scrolling conflict entirely. **The next one.**

Item 3 is built as well (the hit pop's squash). Items 5-7 after `dpystrt`;
item 8 not at all.

## Measuring headroom first

The DMA is the frame budget. `bog_line` is a built-in raster-time meter — it
draws a green bar showing how much of the frame the DMA is eating. It is
present and switched off ([MKDISP.ASM:27](../src/MKDISP.ASM#L27)):

```asm
bog_line .set 0    ; -> 1 to draw the DMA-time bar
```

Turn it on before and after adding any of these to see what an effect actually
costs.

---

## Appendix — verification commands

Run from `src/` in either tree.

```bash
# items 1-3: features that reach hw but are never driven
grep -rl "ani_flip_vert" *.TBL *.ASM        # -> MKUTIL.ASM only (definition)
grep -rn "oconst" *.ASM | grep -v DISPEQU   # -> text/cursor/PONG/shadow + MKZAP spear
grep -rn "oscale" *.ASM | grep -v "DISPEQU\|MKSTRUCT"

# items 4-8: registers pinned to one value, or defined and unreferenced
for s in hsint dirq2int dpytap dpystrt pmask ppop m_conzer dmartbot; do
  printf "%-10s: " "$s"
  grep -rln "\b$s\b" *.ASM | grep -v "SYSEQU\|DISPEQU\|MAINEQU\|MKSTRUCT" | tr '\n' ' '
  echo
done
```

Expected in a clean tree: `hsint`, `dirq2int`, `ppop`, `m_conzer` and
`dmartbot` return nothing; `dpytap` and `pmask` return `MKINIT.ASM` only;
`dpystrt` returns `MKINIT.ASM MKUTIL.ASM` only.
