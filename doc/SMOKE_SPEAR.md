# Smoke's harpoon

`smrope` (MAINEQU.ASM) — Smoke throws the spear on his own rope instead of
Scorpion's.

## What was actually wrong

Smoke has always thrown the spear. `zap_offsets` row 14 (MKDRONE.ASM) is
`00ch`, the same `do_throw_spear` Scorpion uses, and `rt_special_start` row 14
is `drone_zap_jsrp`. He is a CPU-only fighter — `smoke_select_enable .set 0`,
so he is reached through `toasty_check` (MKTOAST.ASM: Down + Start on THE
PORTAL while "Toasty!" is up) — and `char_lo_punch` row 14 is `sucide`, so the
drone path is not merely his usual path, it is his **only** one. A human Smoke
cannot throw it at all.

What he did not have was a rope of his own:

```
sm_anitab2
sc_anitab2
        .long   a_throw_spear    ; 0
        .long   a_rope_ani       ; 1 - rope animations
```

`sm_anitab2` was a bare alias label stacked on `sc_anitab2` — and this is
Midway's own arrangement, not something this tree dropped; `mk2-readonly`
carries the identical two lines. So every lane Smoke reached was Scorpion's.
That is right for six of the seven rows and he still shares them. Row 1 is the
rope, and it meant Smoke paid out SCORPION's: `BIGRP1`/`BIGRP2` in flight and
`SPEARHIT` once it stuck.

## The art was already drawn

`COMEHERE1`, `COMEHERE2` and `COMEHERE3` sit in `data/NEWROPE.IMG` beside
Scorpion's records. They are a second rope — a coiled **spring** with a
**trident** head — built to exactly the same three-frame shape:

| record | size | what it is |
|---|---|---|
| `COMEHERE1` | 327×18 | flight, coil phase 1 |
| `COMEHERE2` | 327×18 | flight, coil phase 2 |
| `COMEHERE3` | 317×14 | pulled straight — stuck in him, hauling him in |

Retail never packed them, and neither did this tree: `mk2-readonly` has no
reference to `COMEHERE` anywhere in `src/` or any LOD either. (`NUROPE1/2/3`,
one shelf over, are a third unshipped rope on the 2bpp `TWINE_P` and are still
unpacked.)

The lane that walks them is `a_sm_rope_ani` (MKNJ.ASM), and the **parts have to
line up with `a_rope_ani`'s**, because `spear_proc` and `do_rope_pull`
(MKZAP.ASM) walk the lane by part number and never by character:

* part 1 — the flight loop, `COMEHERE1` → `COMEHERE2` → `ani_jump`
* part 2 — the taut frame, `COMEHERE3`, worn from the moment it sticks until
  the man is at Smoke's feet
* part 3 — the pull wiggle, **shared with Scorpion's `ROPEPULL` strips**.
  Nothing reaches it: `do_rope_pull` takes `find_part2` exactly once and stops.
  A part that is never drawn is better shared than duplicated in art nobody
  will see.

## The anipoints carry the alignment — no code knows about it

All three of Scorpion's rope records put the **shaft's centre line on anchor
+31.5**, and that is the only thing holding the rope at the right height:

```
BIGRP1     shaft y rel anchor +30..+33   tip at +135
BIGRP2     shaft y rel anchor +30..+33   tip at +135
SPEARHIT   shaft y rel anchor +30..+33   tip at +127
```

`COMEHERE1/2/3` shipped with `anix = aniy = 0`, so they were given anipoints
that land on those same three numbers (`img_anipoint.py set`):

| record | anix | aniy | shaft lands | tip lands |
|---|---|---|---|---|
| `COMEHERE1` | 191 | −23 | +30..+33 | +135 |
| `COMEHERE2` | 191 | −23 | +30..+33 | +135 |
| `COMEHERE3` | 189 | −25 | +30..+33 | +127 |

Because the rope is a one-piece **multipart** object, frame changes go through
`ani2`, which does not migrate the object — the anipoint is a pure draw offset,
so the 8px settle between flight and taut reproduces retail's exactly.

`stk_njspear` (`nj_strikes` 011h, the box both ninjas' ropes are tested with)
therefore needs no change: the trident arrives where the spear did.

## Two things that will bite a re-cut

**`ZOF>` is load-bearing.** `data/SMROPE.LOD` packs uncompressed, and Midway's
own `NEWROPE` section in `data/MK4MIL.LOD` is `ZOF>` for exactly the five rope
records with `ZON>` again straight after. The reason is the clip:
`set_rope_clip` sets `dmaclp` and `lineup_rope_with_him` writes a column count
into `ofset`, which makes the DMA **skip that many source columns** — and there
is no indexing part way into a zero-run record. Turn compression on and the
rope draws as garbage from the moment it sticks.

With `ZOF>` and `PPP> 5` the payload is exactly `W*H*5` bits a record:
327·18·5 twice plus 317·14·5 = 81,050 bits = **10,132 bytes**, which is what
LOAD2 wrote.

**The taut frame's width was a hard-coded constant.**
`lineup_rope_with_him` clips the rope to the gap between the two fighters:

```asm
	movi	304,a0          ; <- SPEARHIT's width, written in
	sub	a3,a0           ;    a3 = x distance
	abs	a0              ;    clip value
	move	a0,*a10(ofset),w
```

That 304 is Midway's (it is identical in `mk2-readonly`) and was true while
Scorpion was the only man on a rope. `COMEHERE3` is 317 wide, so a rope
measured with the other one's number draws 13px past him. It now reads the
width off the frame it is actually drawing:

```asm
	move	*a10(oimg),a0,l		; a0 = the rope's multipart ram
	move	*a0(mp_sizex),a0,w	; a0 = the taut frame's own width
```

Both ropes measure themselves and neither has a number in the code.

## Where it lives

| | |
|---|---|
| art | `data/NEWROPE.IMG` — `COMEHERE1/2/3`, palette `CUM_P` |
| pack | `data/SMROPE.LOD` — bank 1, `0xB7E000..0xB82000`, top of the MK7MIL free run, hard under MK3CV2 |
| table | `src/SMROPE.TBL`, generated by LOAD2 (`ASM>`), copied by `tools/promote_tbls.py` |
| palette | `CUM_P` in `src/IMGPAL6.ASM` — 27 entries, one grey luminance ramp |
| lane | `a_sm_rope_ani` + `sm_anitab2` (MKNJ.ASM) |
| clip | `lineup_rope_with_him` (MKZAP.ASM) |
| flag | `smrope` (MAINEQU.ASM) |

`CUM_P` keeps the IMG's own name on purpose: `COMEHERE1` is listed `PON>`, so
LOAD2 writes `.long CUM_P` into the generated table off the palette record's
name. Renaming it in one place and not the other is an unresolved symbol;
renaming it in both is a binary edit to shipped art for nothing.

## Rig

```
python tools/smoke_spear_expect.py                 # regenerate expectations
tools\run_smoke_spear_test.ps1 -Who both           # smoke + the scorpion control
```

It measures **the SAG the DMA was handed** — the rope is a one-piece multipart
object, so `obj(oimg)` is its multipart RAM and `mp_sag` is the record actually
being drawn. It finds the rope by walking `objlst`/2/3 for that SAG rather than
through `p_slave`, which is re-pointed and cleared by `delete_slave` and reads
as a live object full of rubbish once it is stale.

Expectations are **regenerated from `src/SMROPE.TBL` and `src/MKNJ.TBL` on
every run** (`tools/smoke_spear_expect.py`), because a rebuild moves every SAG
in a pack and a rig holding last week's numbers would compare the live object
against art that has since moved — and pass. The generator also refuses if a
record is missing or its width no longer matches `data/NEWROPE.IMG`.

The second half is the clip, as an identity on the live object:

```
ofset + |x distance| == mp_sizex
```

true for both ropes only if the code reads the width off the frame it is
drawing. With the old constant it holds for Scorpion and is 13 out for Smoke,
so **`-Who scorpion` is a real control, not a formality**.

### What is proved, and what is not

| | |
|---|---|
| the art packs and round-trips | **proved** — all three records decode out of the built video ROM byte-identical to `data/NEWROPE.IMG`, with the right geometry and anipoints |
| Smoke's table reaches them | **proved** — `tools/art_ref_graph.py --explain COMEHERE1/2/3` returns LIVE, reached through `SMROPE1`/`SMROPE2`/`SMROPEHIT`, i.e. `a_sm_rope_ani` → `sm_anitab2` → `character_anitabs2[14]`. Scorpion's `BIGRP1`/`SPEARHIT` stay LIVE, so nothing was taken from him |
| the clip still works | **proved at runtime** on a real spear pull: the identity held 25 frames of 25, zero breaks, `mp_sizex` reading 304 for `SPEARHIT` |
| a live CPU Smoke draws COMEHERE | **NOT proved at runtime** — see below |

**The rig cannot currently make a drone act.** It reaches the fight correctly
— select, confirm, the forced char ids, the bars and the clock all hold, and P1
walks — but the CPU fighter sits in `act_stance` (0x0303) for every frame and
never decides anything. This is **not** about Smoke: with `MK2_SPEAR_FT=1`
(Liu Kang, an ordinary fighter) the drone is inert in exactly the same way,
1,602 frames of 0x0303 and byte-identical positions. Ruled out on the way:
the RNG stir (`MK2_SPEAR_STIR=0` is the same), the `p_state` writes
(`MK2_SPEAR_STATES=0` is the same), and `f_freeze_timer` (it only skips the
clock decrement, MAIN.ASM:832). A run ending `HARNESS: drone never acted` is
reporting the rig, not the art.

The one real spear the rig has captured came from the **attract demo**, which
does run live drones — that is where the 25 clip samples came from. Making the
drone act in a forced match is the open piece of work here.

### The trap that cost three runs

**Attract mode runs both the select screen and a demo fight, at the same
gstates a real game uses.** A rig that latches `charsel`/`confirm`/`fighting`
on the first sighting of each latches them all during the attract loop — and
once `fighting_frame` is set, `pressed()` stops driving the coin and the start
button, so the rig never starts a game at all. It then sits watching attract
mode for the whole run, reports the drone as inert in `act_stance` the entire
time, and scores the **demo's own Scorpion spear** against whoever it was
supposed to be testing. Nothing latches before frame 1100 now (the coin goes in
at 700–980, Start at 1000–1080).

Two more, both already known elsewhere in the tree and both true here:

* **Stir `@rand` every frame.** It is reseeded from constants at round start,
  so a scripted rig replays one stream and a single roll decides whether the
  drone ever picks its special. Same treatment as
  `tools/cage_drone_ball_probe.lua`.
* **P1 has to move.** Against a completely passive player the drone stands in
  `act_stance` with the gap frozen, and never reaches the decision that picks
  its special. P1 walks back and forth for the whole run, which sweeps the
  range through every band.
