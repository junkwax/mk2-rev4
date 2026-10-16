# `ani0` accumulates control-word bits (sprite shears mid-animation)

**TL;DR** — `ani0` **ORs** each new frame's `icontrol` into the object's existing
`oflags` instead of replacing it. Control bits therefore only ever turn ON.
If frame *N* of an animation sets a control bit that frame *N+1* needs CLEAR,
frame *N+1* and everything after it is blitted with the wrong line format and
shears into speckle. The art is fine, the SAG is fine, the palette is fine.

Mask `oflags` down to the flip/DMA bits **before** calling `ani0`:

```asm
	move	*a8(oflags),a4,w
	andi	dmago|dmaclp|dmawnz|m_fliph|m_flipv|00fh,a4
	move	a4,*a8(oflags),w
	calla	ani0
```

Found 2026-08-14 on Shao Kahn's sonic clap after several days of chasing the
wrong cause. Read this before touching any hand-stepped animation.

---

## The tell

This bug looks like a data problem and is not one. All four of these together:

1. The first few frames render **perfectly**, then it degrades from one
   specific frame onward and never recovers.
2. The bad frame is the one **after** a frame whose `icontrol` differs.
3. Colours appear that are **not in the sprite's palette** — e.g. red dashes in
   a five-colour green wave. That means the blitter is reading pixel indices
   the art never contained, i.e. wrong stride. (Wrong *palette* gives wrong
   colours with a coherent shape. Wrong *stride* gives scatter.)
4. The art **verifies byte-exact** against the source `.IMG`
   (`python tools/verify_img_import.py` → "0 frame(s) differ").

Point 4 is the one that saves you. If the packed data in the IRW decodes back
to exactly what is in the IMG, stop looking at the art, the palette, the
`PPP>` depth, the SAG and the anipoints. The data is right and something at
runtime is telling the hardware to read it wrong.

## Why it happens

`ani0` (MKDISP.ASM) reloads the current flags and falls into `anig1`:

```
ani0	mmtm	sp,...
	move	*a8(oflags),a5,w	; <-- OLD flags, kept as-is
	move	*a8(oimg),a3,l
	jruc	anig1
```

`anig1` hands them to `gsagof`, which does **not** clear them:

```
gsagof
	move	*a1(isag),a3,l		; new frame's sag
	zext	a4,w			; a4 = OLD oflags, zero-extended
	move	*a1(icontrol),a2,w	; new frame's control word
	or	a2,a4			; <-- OR, not MOVE
```

and `anig1` then stores that straight back: `move a4,*a8(oflags),w`.

So `oflags(new) = oflags(old) | icontrol(new)`. Every control bit any frame
has ever set stays set for the rest of the object's life.

**`ani` gets this right** and is the reference for what the mask should be
(MKDISP.ASM:1571):

```
	andi	dmago|dmaclp|m_fliph|m_flipv|00fh,a4	; keep flip info and dma info
	move	*a1(icontrol),a2,w
	or	a2,a4
```

`ani0` simply skips that `andi`. Anything driven through `ani0` inherits the
bug; anything driven through `ani`/`ani_flag`/`mframew` does not.

## The concrete case: SONICLAP

Control words for the wave (`src/MKSK.TBL`, after LOAD2):

| frames | ctrl | note |
|---|---|---|
| 1 | `0x3080` | compressed, 1× lead/trail |
| 2–3 | `0x3480` | compressed, **`0400h` trail multiplier set** |
| 4–7 | `0x3080` | needs `0400h` **clear** |
| 8–11 | `0x3000` | uncompressed |

`kahn_sonic_proc` steps the frames with `ani0`. Frames 2–3 set `0400h`; frames
4+ never cleared it, so from frame 4 on every scanline's trailing transparent
run was shifted by the wrong amount and the wave became a speckle block.

This reproduced identically at **6 bpp and at 3 bpp**, which is what finally
ruled the depth out — a packing mismatch would not survive changing the
packing. Fixed in `kahn_sonic_proc` (MKZAP.ASM) with the mask shown at the top.

## Who else is exposed

`ani0` callers, as of 2026-08-14:

| site | risk |
|---|---|
| `MKZAP.ASM` `kahn_sonic_proc` | **was broken, now masked** |
| `MKZAP.ASM` ~876, ~895 | check if those frame lists have varying `icontrol` |
| `MKBOSS.ASM:2518` (`kahn_hamswipe_proc`) | ditto |
| `MKUTIL.ASM:1048` | generic "setup the new image" path |

`MKDEATH.ASM` already avoids `ani0` in two places on purpose ("ani_flag, not
ani0: ani0 skips the current-oflags reload"), so this has been felt before
without being named.

**How to check a frame list quickly:** pull the `.word` control values for the
sequence out of its `.TBL` and see whether they are all identical. If they are,
the accumulation is harmless. If any bit differs between consecutive frames,
that animation is exposed.

```
grep -A3 '^MYFRAME[0-9]*:' src/MYCHAR.TBL | grep -E '^\s+\.word\s+0[0-9A-Fa-f]+H'
```

## Fixing it centrally (not done — read before you try)

The obvious repair is to put the `andi` inside `ani0` itself so every caller is
covered. That was deliberately **not** done: `ani0` is called from generic
display paths and some callers may be relying on a bit surviving across frames.
Changing it is an engine-wide behaviour change that needs a full battle-
stability sweep, not a one-move test. The per-call-site mask costs three
instructions and cannot regress anything else.

## See also

- `doc/SPRITE_BPP_MISMATCH.md` — the *other* cause of "colours right, shape
  scattered", and the earlier investigation of this same wave. Its original
  conclusion ("the engine always blits 6 bpp, no header fix is possible") is
  wrong; that doc now carries a correction.
- `tools/verify_img_import.py` — decodes every frame out of the IMG and out of
  the built IRW and diffs them. Run this **first** on any garble report; it
  splits "bad art/packing" from "bad runtime parameters" in one command.
- `tools/audit_sprite_bpp.py` — decodes packed frames straight out of the video
  ROM; its `BitReader` is the confirmed **LSB-first** field walker. An
  MSB-first reader produces convincing garbage (indices of 52 out of a
  five-colour palette) and will send you chasing a bpp ghost.
- Control-word bit layout: `dmabpp` (bits 12-14) in `src/SYSEQU.ASM`; the
  per-line `dmacmp` (bit 7) + lead/trail multipliers (bits 8-9 / 10-11) are
  documented at the top of `tools/audit_sprite_bpp.py`.
