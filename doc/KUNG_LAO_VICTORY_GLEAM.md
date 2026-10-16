# Kung Lao's victory hat gleam gets its own object

`hhgleam` (MAINEQU.ASM) · `hh_victory` (MKCANNED.ASM) · `a_hh_vicgleam` (MKHH.ASM)
· `HATGBL_P` (IMGPAL7.ASM, carried by `tools/sync_hatgleam_pal.py`)

At the end of Kung Lao's victory a spark runs round the brim of his hat —
`TMHATGLEAM1-6`, six small records in `data/HATHED10.IMG`. It was always grey.
It is blue now, and the reason it could not be blue before is worth writing
down, because it is a property of the display engine rather than of this art.

## Why an IMG palette edit could not reach it

Three things stood between `data/HATHED10.IMG` and the screen, and any one of
them is enough on its own:

1. **`PPP> 6`.** [data/MK2MIL.LOD:10](../data/MK2MIL.LOD#L10) sets the pack
   depth for the whole Kung Lao section, so LOAD2 packs the gleam at 6 bpp
   regardless of the palette record's own `bits_pr_pxl` (3). Decoded out of the
   built video ROM the six records are `ctrl=6080`/`6580` — bpp 6 — carrying
   indices 1-7 and nothing else.
2. **`POF>`.** That section emits no palette field, so
   [src/MKHH.TBL:1673](../src/MKHH.TBL#L1673) onward is `.word W,H,anix,aniy` /
   `.long SAG` / `.word ctrl` with no `.long <palette>`. The binding between the
   record and the IMG palette **does not exist in the ROM**.
3. **It was a multipart piece.** `a_hh_victory_hat`'s rows are
   `TMVICTORY8A,TMVICTORY8B,TMHATGLEAMn` — the gleam was part of Kung Lao's own
   object, and MKDISP loads an object's palette translate **once**, before its
   multipart loop. Every piece of an object draws in one palette, full stop.

So the gleam's seven indices landed on Kung Lao's costume slots 1-7, which in
every one of his costumes is a white-to-dark-grey highlight ramp
(`0739C,06F7B,06739,05AD6,05294,04E73,04210`). That is what you saw, whatever
`HATHED10.IMG` said. Editing the IMG palette — or repointing the records'
`palind` at a new one — changes the IMGTOOL preview and nothing else; the
packed bytes do not even move, which is the confusing part. A full `build.py`
after such an edit leaves `src/MKHH.TBL` byte-identical.

**The general rule: a visual that needs its own palette needs its own object.**
This tree already had two instances of it before this one — Jade's victory
staff (`jade_victory`, 4 bpp on `JDSTGLO_P`) and Baraka's blade sparks
(`sa_victory`). Both say so in their own comments.

## What was built

`a_hh_vicgleam` (MKHH.ASM, `hat_anitab2` row 8) is the same six records with
the body pieces removed — one piece per row, so the object can carry a palette
of its own. No new art and no repack: `TMHATGLEAM1-6` are untouched, still at
the same SAGs, still 6 bpp.

`hh_victory` then follows `jade_victory`'s shape exactly:

```
	movi	000060029h,a9
	jsrp	animate_a9		; stock victory; a_victory ends on
					; TMVICTORY8 and leaves it displayed
	gmo_proc		-> jreq hh_vic_solo   (retail's inline lane)
	match_ani_points	   sit it on him, copy his facing
	opal = his, then getfpal HATGBL_P over the top
	ozval = his + 1		   insobja8
	mframew 4		   six rows, the lane's own cadence
	set_inviso		   hide it; his body still holds TMVICTORY8
	local_wait_forever
```

Points that are load-bearing rather than incidental:

- **His costume index goes in `opal` first, `HATGBL_P` over it.** The records
  are `POF>`, so `get_multi_obj`'s `*a5(icmap)` read runs off the end of the
  record and whatever `opal` the object came up with is garbage. Seeding it with
  an index that is safe to draw in means a `getfpal` failure degrades to
  retail's grey instead of to boonpal's yellows.
- **`getfpal`, never `swpal`.** `swpal` opens with an unconditional `delpal` on
  that garbage index, which is how `freepal`'s count underflows into its lockup.
  Same note as `jade_victory`'s staff block and the boomerang's `gjbo` block in
  MKZAP.ASM.
- **No cleanup, deliberately.** Hand-deleting a `gmo` object here is the exact
  move that wedged Kahn's glow. `set_inviso` stops the draw (MKDISP tests
  `b_inviso` inside the multipart branch, which is the branch this object
  takes) and the round teardown owns the rest — `oinit` rebuilds the object free
  list, `murder` kills `gmo_proc`'s `pid_mpo` dummy, and `dispinit`'s `clrpal`
  reclaims the colour map. A `delpal` here would be a double free, because
  `delpal` does not zero `opal`.
- **`set_inviso` writes `oflags2` (0x160), not `oflags` (0x0f0).** The rig
  watched the wrong field first and reported a gleam that never hid — a rig
  fault wearing a regression's clothes.
- **The seventh row is gone.** retail's lane ended on a bare `TMVICTORY8` to put
  the clean pose back after the gleam; his body never leaves that pose now, so
  hiding the gleam object does the same job.

Cost: **one foreground colour map** (`nmfpal` is 35) for the 24 ticks of the
gleam, plus 18 bytes of program ROM for the palette. `fpal_fail` was 0 across
the measured run.

## Editing the colour

Open `data/HATHED10.IMG` in IMGTOOL, repaint `HATGBL_P`, then:

```
python tools/sync_hatgleam_pal.py      # carry the words into src/IMGPAL7.ASM
python build.py --asm-only && python makerom.py && python mamerom.py
```

`tools/sync_hatgleam_pal.py --check` is Phase D. It exists because nothing
promotes an IMG palette into the ROM: without it a repaint ships the old colours
with no error anywhere, which is the failure this whole entry is about.

A pixel change to `TMHATGLEAM1-6` themselves still needs a full `build.py`
(Phase A/LOAD2) and `makevrom.py`.

## Rig

```
tools/run_hh_gleam_test.ps1              # 1P, Kung Lao vs Jax, forced round win
tools/run_hh_gleam_test.ps1 -Negative    # crossed expectation; must FAIL
```

What it asserts, in order — each one is there because passing without it would
mean nothing:

| assertion | what it rules out |
|---|---|
| the gleam object is **not** `p1_obj`, and `p1_obj` carries no `TMHATGLEAM` piece | the split never happened; every palette claim below would be meaningless |
| `palram[opal & 0xff]` holds `HATGBL_P`, with that row's `palcnt` non-zero | the object drawing in something else. `freepal` leaves the id behind, so a zero count is **no verdict**, not a pass |
| six stages in order at exactly 4 ticks | a lane that skipped or doubled rows |
| `ozval` > his | the gleam drawn behind the brim |
| `m_inviso` set in `oflags2` after the last row, and his body still on `TMVICTORY8` | a spark parked on the brim for the rest of the victory — how Baraka's was reported |
| no object with a gleam SAG once round 2 is fighting | the object leaking past the teardown |
| `fpal_fail` did not rise | an exhausted pool reported as a wrong palette instead of as **no verdict** |
| `tools/hh_gleam_pixels.py` finds ≥20 pixels of HATGBL_P's exact colours in the snapshots | the object pointing at the palette with nothing painted behind it — the Jade sidecar hole passed its harness that way for months |

Measured: 6 stages, cadence 4/4/4/4/4, `palram` map 8 count 1 →
`HATGBL_P`, z in front, hidden at the end, released into round 2, 74 HATGBL_P
pixels in the best frame, `fpal_fail` 0. `-Negative` (expect his costume)
fails at the palette compare, as it must.

The costume ramp the gleam used to wear is pure grey in every slot it touches,
so a single saturated-blue pixel from this palette cannot come from the old
behaviour — which is what makes the pixel count a real discriminator rather
than a smoke test.

## Switch

`hhgleam .set 0` (MAINEQU.ASM) is retail's shape exactly: `a_hh_victory_hat`
played on his own object with `animate2_a9`, gleam in costume grey. The lane,
the table row and the whole block in `hh_victory` compile out; `HATGBL_P` stays
linked as 18 bytes of unreferenced data. Both settings assemble clean.
