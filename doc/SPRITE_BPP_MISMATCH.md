# Sprite garble from a bits-per-pixel mismatch (Kahn SONICCLAP case study)

> **CORRECTED 2026-08-14 — read this box before the rest of the doc.**
>
> **The SONICCLAP garble this doc is a case study of was NOT a bpp problem.**
> The real cause was `ani0` OR-ing each frame's control word into the object's
> flags instead of replacing it, so the `0400h` trail multiplier set by
> SONICLAP2/3 stayed set for frames 4+ and every later frame was blitted with
> the wrong line format. It reproduced identically at 6 bpp *and* at 3 bpp,
> which is what finally ruled the depth out. Full write-up and the fix:
> **`doc/ANI0_CONTROL_WORD_ACCUMULATION.md`** — read that one first.
>
> Two claims below are also wrong and cost rebuilds on their own:
>
> - *"The engine blits at 6 bpp"* / *"no header-bit fix is possible."* False.
>   The blitter takes bits-per-pixel from each frame's control word (`dmabpp`,
>   bits 12-14) and honours it — that is the whole premise of
>   `tools/audit_sprite_bpp.py`, which repacks sprites at 4 or 5 bpp for a
>   straight space saving "with zero runtime cost". Control-word edits looked
>   inert here only because the accumulation bug above was overwriting them.
> - *"Build-side knobs (`PPP>`) cannot force this."* False. The palette-size
>   override only beats `PPP>` when the palette has MORE colours than `PPP>`
>   bits can index.
>
> **The rule this doc should have stated: the PACKING must equal the
> `bits_pr_pxl` of the PALETTE the art is assigned to.** Not "must be 6".
> SONICLAP is on `CLAPG_P` (`bits_pr_pxl = 3`, 5 colours), so `data/SCLAP.LOD`
> now says `PPP> 3`. That is correct and worth keeping — it halved the sidecar
> (7552 -> 4004 bytes) — but it was never the garble.
>
> Verify packing with `python tools/verify_img_import.py`: it decodes every
> frame out of the IMG and out of the built IRW and diffs them. "0 frame(s)
> differ" means the data is right and you should be looking at runtime
> parameters, not the art.

**TL;DR** — If a custom sprite renders as a *scattered* spray of otherwise
correct-colored pixels (shape wrong, colors right), suspect a **bits-per-pixel
(bpp) packing mismatch**, not a header/control-word bug. If LOAD2 packs the
pixel data at a bpp that disagrees with the palette the art is assigned to,
every row's stride is wrong and the image shears/scatters.

This doc records the Shao Kahn SONICCLAP wave investigation (2026-07-22), which
burned several rebuilds chasing header bits before the real cause surfaced. Read
it before touching any custom sprite that renders as garbage.

---

## Symptom

Kahn's restored sonic-clap **wave** (`SONICLAP1..11`, the traveling bar) drew as
a scattered spray of green/white pixels with a bright core. The **body** frames
(`BGSONICLAP*`, Kahn clapping) rendered fine. Colors looked plausible (green
energy), but the *shape* was noise — the tell-tale of a stride/packing error,
not a wrong palette (a wrong palette gives wrong *colors*, coherent shape).

## What was DISPROVEN (don't repeat these)

1. **The `org` bit (`0x0400`) in the control word.** An old note claimed the two
   clean frames (`SONICLAP2/3`) were the ones with `org` set, so forcing `org`
   on all 11 "should" fix it. Forced it → **pixel-identical garble.** Worse, the
   committed `MKSK.TBL` *already* carried this (SONICLAP1 = `0x6480`), but LOAD2
   rewrites it to `0x6080` on every full build — so it was self-reverting *and*
   useless.
2. **The control-word bpp field** (`dmabpp`, bits 12-14; [SYSEQU.ASM](../src/SYSEQU.ASM)
   `dmabpp .set 7000h`, value 1-7 = bpp, `0` = 8). Forced it to declare 8bpp →
   **also zero visual change.**

**Key realization:** *per-frame control-word edits had no visible effect at all.*
For these projectile objects the DMA pixel size does not come from the frame's
`icontrol` word in a way that any TBL edit can move — the engine effectively
renders 6 bpp regardless (it's hardcoded in places, e.g. the shadow SAG-advance
in [MKDISP.ASM](../src/MKDISP.ASM) "+ 4x = 6 bits per pixel"). So **no header-bit
fix is possible.** If control-word edits do nothing, the data itself is wrong.

## Root cause: the art was packed at the wrong bpp

Bits-per-pixel is a property of the **palette**, not the image
(`PALETTE.bits_pr_pxl`, [doc/load2/wmpstruc.h](load2/wmpstruc.h)). Reading the
source `.IMG` directly:

| Art | Assigned palette (in IMG) | palette bpp | Colors the art actually uses |
|-----|---------------------------|:-----------:|:----------------------------:|
| `SONICLAP1..11` (wave) | `CLAPG1_P` (palnum 11) | **8** | only indices 0-4 (5 colors) |
| `BGSONICLAP*` (body, fine) | `BGPAL1_P` (palnum 5) | 6 | 0-63 |

LOAD2 packs based on palette size: if the assigned palette has more colors than
the requested `PPP>` bits allow, it **overrides** `PPP` and packs at the
palette's `bits_pr_pxl` ([load2.c](load2/load2.c) ~L2302, "Can't fit into N bits
per pixel"). The wave art only *uses* 5 colors, but it was **assigned to an 8bpp
palette**, so LOAD2 packed the sidecar data at 8 bpp while the game blits it at
6 bpp → misaligned rows → scatter.

The wave art lives in a fixed sidecar `data/SCLAP.LOD` (`***> 3F88000,1`,
runtime `0x05F88000`, physical `0xBF1000`, bank 1) that duplicates
`SONICLAP1..11` out of `BOSS4.IMG`. `makevrom` places `SCLAP.IRW` there, so the
SAG was correct — **not** a placement/drift bug. The game loads `CLAP_P` (3bpp,
5 colors) via `getfpal` in [MKZAP.ASM](../src/MKZAP.ASM) `kahn_get_sonic_obj`.

## The fix (superseded — see the corrected box at the top)

The 2026-07-22 conclusion was "re-assign the wave art to a 6-bpp palette so
LOAD2 packs at 6 to match the engine". The art was indeed moved off the 8bpp
palette, which removed the *original* garble. But it was moved onto `CLAPG_P`
at **3** bpp while `SCLAP.LOD` still said `PPP> 6`, so the packing was now too
WIDE instead of too narrow, and a subtler garble came back partway through the
animation.

The durable rule is **packing must equal the assigned palette's
`bits_pr_pxl`** — set `PPP>` in the LOD to that number. Build-side knobs are
not powerless: the palette-size override only wins when the palette has more
colours than `PPP>` can index.

## Diagnosis checklist for "my custom sprite renders as garbage"

1. Is the **shape** scattered but the **colors** plausible? → bpp/stride, not
   palette. (Wrong colors + coherent shape → palette. Wrong *position* → SAG /
   anipoints / placement.)
2. Dump the source `.IMG` (`python imgdump.py data/FOO.IMG`) and note each
   frame's **palnum**. Cross-check that palette's `bits_pr_pxl` (read the
   PALETTE records directly; imgdump doesn't print bpp). **It must be 6** for
   normal T-unit sprites.
3. If the palette is 8bpp (or anything ≠ 6) but the art uses few colors, that's
   the bug: re-assign the art to a 6bpp palette in the imgtool and re-export.
4. Sanity: does editing the frame's control word in the TBL change anything
   in-game? If **no**, stop editing headers — the data is mispacked.
5. Confirm placement is fine first: SAG (in the TBL) should land inside the
   IRW's runtime range that `makevrom` reports for that LOD/sidecar.

## Pointers

- Control-word / DMA bpp field: [SYSEQU.ASM](../src/SYSEQU.ASM) `dmabpp .set 7000h`
- Image header field offsets: [SYSEQU.ASM](../src/SYSEQU.ASM) `isize`=0, `isag`=0x40, `icontrol`=0x60
- Engine's 6bpp assumption: [MKDISP.ASM](../src/MKDISP.ASM) (shadow SAG advance)
- LOAD2 packing / palette override: [doc/load2/load2.c](load2/load2.c) ~L2299-2313
- IMG palette bpp field: [doc/load2/wmpstruc.h](load2/wmpstruc.h) `bits_pr_pxl`
- Wave code: [MKZAP.ASM](../src/MKZAP.ASM) `do_kahn_sonic` / `kahn_get_sonic_obj` / `kahn_sonic_proc`
- Sidecar: `data/SCLAP.LOD`; palette `CLAP_P` in [IMGPAL5.ASM](../src/IMGPAL5.ASM)
