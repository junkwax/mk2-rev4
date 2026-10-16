# Kintaro's stomp art was shrunk - and put back

`a_goro_stomp` (ani `0ah`, MKGORO.ASM) is `TIGERJUMP1-6`, and the game draws
the **A-D strips** of each frame, not the composites. In this tree the strips
of frames 1-4 had been replaced with SMALLER copies:

| strip | Midway | this tree (before) | ratio |
|-------|--------|--------------------|-------|
| TIGERJUMP1B | 48x117 | 38x93 | 0.80 |
| TIGERJUMP2A | 67x107 | 53x86 | 0.79 |
| TIGERJUMP3B | 45x127 | 36x101 | 0.80 |
| TIGERJUMP4B | 34x143 | 22x91 | 0.64 |
| TIGERJUMP5B | 34x124 | 34x124 | **untouched** |

Frames 5 and 6 are retail to the byte; only 1-4 were shrunk.

**How it happened.** `SMTIGERJUMP1-4` - the small Kintaro prop that leaps out
of the Kahn's Arena stands (`data/SMTIGER.LOD`, ARENAKIN.ASM) - is 0.8 of the
stomp, authored into the same `data/TIGER3.IMG`. That edit left shrunken
copies on the stomp's own strip records. `src/MKGORO.TBL` was then re-cut to
match the shrunken art ([[reference_frozen_tbl_geometry_drift]]), so every
piece of metadata agreed with every other and nothing looked broken: right
SAG, right palette, 1:1 scale, right bpp - just a smaller Kintaro.

**What it looked like.** A Kintaro about two thirds his fight size coming down
on Shang Tsung at the end of the soul escape ([[project_shang_soul_escape]]),
and the same shrinkage in the in-fight stomp (`goro_psycho_stomp`, MKBOSS.ASM).
It went unseen because that lane is hard to reach in a normal fight - the soul
escape's finisher was the first thing to draw it.

## The restore

`tools/restore_tigerjump.py` copies the 15 strips - pixels AND geometry - out
of the pristine `C:\Users\you\Workplace\mk2-readonly\mk2-main\data\TIGER3.IMG`.
It appends the retail pixels at the end of the file and repoints the records,
so nothing else in the IMG moves and `SMTIGERJUMP` is untouched. `--check`
runs in Phase D, so the art cannot silently shrink again.

`src/MKGORO.TBL` is now in `promote_tbls.py`'s `GENERATED_TABLES`. It used to
be frozen, which is what let its geometry be re-cut to match bad art.

## Where the art lives now

Restored, the 15 strips pack to 28,764 bytes against 17,111 shrunk, and MK4MIL
had 1,048 bytes of slack. So six strips moved out into holes that were already
free, the way THE CAVE's `MK3CV1-4` and the soul rip's `SKSOUL1-5` are dealt:

| pack | strip | bytes | slot | sits at the bottom of |
|------|-------|-------|------|------------------------|
| TIGJMP1 | TIGERJUMP4C | 2,758 | 0x75B310..0x75BE00 | JADMIL2's guard |
| TIGJMP2 | TIGERJUMP4B | 2,486 | 0x7E5120..0x7E5C00 | MK1WS1's guard |
| TIGJMP3 | TIGERJUMP3C | 2,318 | 0x7ED860..0x7EE210 | REPERM's guard |
| TIGJMP4 | TIGERJUMP1D | 2,026 | 0x4018A0..0x402100 | HANGSAL's guard |
| TIGJMP5 | TIGERJUMP1C | ~1,700 | 0x7D3A70..0x7D4200 | FLAPJACK's guard |
| TIGJMP6 | TIGERJUMP4D | 1,044 | 0x7BBBD0..0x7BC000 | HANGTNYD's guard |

The other nine strips stay in MK4MIL at retail size.

**These holes are TIGHT** - TIGJMP1 has 42 bytes to spare. Two rules came out
of building them:

* **Anchor at the BOTTOM of the hole, not the top.** Every other sidecar here
  sits hard under the next file's base. These cannot: an overrun would land on
  that base. At the bottom, an overrun eats slack instead, and `makevrom.py`'s
  slot check names it.
* **Round the base UP past the payload below it.** TIGJMP1 was first placed at
  0x75B300, ten bytes inside JADMIL2's payload (it ends 0x75B30A), and
  `makevrom.py` refused it as an overlapping payload.

Estimating the packed size from the IMG (8-bit row header + 6bpp between the
first and last non-zero pixel) runs **3-14% low** against what LOAD2 actually
writes - `TIGERJUMP3D` came out 2,036 against an estimated 1,783 and overran
FLAPJACK's hole, which is why `TIGERJUMP1C` is in TIGJMP5 instead. Size a
tight slot off a real LOAD2 run, not off the estimate. Exact per-record sizes
are the SAG deltas in a promoted TBL.

## It is a gameplay change

The hurt box is computed from the sprite, so restoring the art changed what
Kintaro can be hit by during the stomp - `doc/hurtbox.lock` was regenerated:

```
-kintaro  0ah a_goro_stomp  4  -61.. +66   +1.. +120
+kintaro  0ah a_goro_stomp  4  -84.. +87   +3.. +149
```

He is bigger on those frames now, so he is easier to hit out of the stomp.
That is retail's box; the small one was the bug.

## The drop itself

Separately from the art, the soul escape's drop was playing the wrong half of
the lane: it cycled part one (`TIGERJUMP1-4`, the crouch and take-off, which
ends with him leaving the ground legs-first) all the way down, then played the
pounce after he had landed. `soul_kintaro_finish` (MKSOULS.ASM) now falls on
part two the way `goro_psycho_stomp` does - `TIGERJUMP5` down, `TIGERJUMP6` as
a brace `soul_kin_brace` px above the floor, `TIGERJUMP2` as the landing
crouch, then the lane's first frame, which is what retail's
`goro_psycho_land_frame` lands him on.

Rig: `tools/run_shang_soul_escape_test.ps1` - the drop starts about 50 frames
after `leap@`, and the log's `KIN +n` lines carry the shape and the scale.
