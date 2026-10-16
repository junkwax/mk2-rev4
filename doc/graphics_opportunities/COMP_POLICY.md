# Per-asset compression policy scan (opportunity 31)

14 September 2026. **Measured offline; nothing changed.** The compressed art
is already optimal; what is left is 29 deliberately raw records worth
18,921 bytes, whose safety depends on how each one is drawn.

## Method

[`tmp/comp_policy/comp_policy.py`](../../tmp/comp_policy/comp_policy.py)
decodes every record in `src/*.TBL` out of the packed video ROM (through
`tools/art_identity_snapshot.py`) and re-runs **LOAD2's own zero-compression
analysis** over the decoded pixels - a line-for-line port of
[`zcom.c`](../load2/zcom.c) with its quirks: lead zeros stop counting at 120,
trailing zeros only count in the last 120 columns, the lead/trail shifts are
chosen by leftover zeros, every row keeps at least `ZCOMPIXELS` (10) stored
pixels, images 10 pixels wide or less stay raw, and raw wins when it is smaller.

**Validation:** for compressed records the port must reproduce the bits the
record really occupies (walked by the decoder). It matches **9,732 of 9,832**.
The 100 misses are records that were not packed by that routine - MK7MIL
background/hand-carried records, the hand-repacked NOOBPORT, BOSSHAM, MTOPFLR,
SAHELI, NOOBFX, FLAPJACK and similar - and are excluded from the savings.
(A first, greedy model disagreed on 8,281 records and over-promised 39,751 B;
it is not used.)

## Result

| | |
|---|---:|
| Records decoded | 9,832 (98 undecodable) |
| Compressed records that would be smaller with other shifts, or raw | **0** |
| Raw records LOAD2's encoder would store smaller compressed | **29** |
| Bytes those 29 would save | **18,921** (18,352 referenced) |

Every one of the 29 sits under an authored `ZOF>` (zero compression off) in
its LOD: MK4MIL (Scorpion's rope), MK6MIL (select boxes, clouds, title and
message text), HICLOUD, and a few MK7MIL/RAIN leftovers. They are raw on
purpose, so the question is each consumer, not the encoder.

| Group | Records | Bytes | Consumer | Verdict |
|---|---|---:|---|---|
| Scorpion's spear rope | BIGRP1/2, SPEARHIT, ROPEPULL1-3 | 5,924 | `do_throw_spear` / `spear_proc` (MKZAP) fly it under the register window (`dmaclp`, `set_rope_clip`) with the old skip clip commented out - but `do_rope_pull` -> `lineup_rope_with_him` **writes `ofset` = 304 - distance and calls `flip_multi`** | **Not safe** without the flipped-clip skip-swap work (same case as the Tower row clouds) |
| Ladder screen | peakboss, smframe1/2 | 3,048 | `setup_ladder_screen` / `plot_a_box` (MKSEL): plain `gso_dmawnz` objects, no scale, no clip | **Plausible** - rigs already reach the ladder (`kahn_ladder_test.lua`, `dyn_map_probe.lua`) |
| Tower high clouds | CLOUD2, CLOUD3 | 2,530 | `tower_high_cloud_proc` (BGND): drifting, register-window clip, not flipped | **Plausible** |
| Attract title | bigthund1, kombatxt, mortaltxt, thunder3a, strike1 | 3,301 | `mkint*` (MKFX): slide-in by velocity, palette animation; no scale seen | Plausible, attract only - low value |
| Tower row clouds | cloud1a, cloud1b | 2,663 | `clip_a_row` (BGND): `ofset` skip clipping **and** mirroring | **Not safe** without the flipped-clip skip-swap work |
| Grown messages | FIGHT, FINISHHIM, FINISHHER | 855 | `grow_msg` (MKFX): scaled 3x -> 1x -> 3x | **Excluded** - LOAD2 never compresses scaling images |
| Leftovers | mk2copyrgt, STEVEHG1E-G, EDHANG1E, EDHEAD1D, EDBODY1D, DROPHIT2 | ~600 | mostly unreferenced | not worth a repack |

The plausible groups add up to **8,879 bytes** (ladder 3,048 + high clouds
2,530 + attract title 3,301), but a raw -> compressed flip
is not a pure storage change: under `shad_fast` mode 2 a compressed fighter
piece takes the fast shadow path, and any clip/flip consumer must be proved
pixel-identical in MAME. Each flip is a LOD edit (`ZOF>` -> `ZON>` around that
image) plus a repack with a decoded-pixel (`art_identity_snapshot.py`) proof.

## Prototype: the three safe groups (14 September 2026)

**Enabled in source; built privately, not installed.**

- `data/MK6MIL.LOD`: `ZON>` around `smframe1,smframe2` and `peakboss` alone
  (`smgorobox,mysterybox` split onto their own `ZOF>` line so a raw/compressed
  tie cannot flip them), and around the MKTITLE line
  `mortaltxt,kombatxt,bigthund1,strike1,thunder3a`. FIGHT/FINISH HIM stay `ZOF>`.
- `data/HICLOUD.LOD`: `ZOF>` -> `ZON>` for CLOUD2/CLOUD3. They are swapped onto
  a raw `cloud1a` object with `ani_flag`, which is safe: `ani` (MKDISP) keeps
  only the old object's `dmago|dmaclp|flip|0fh` bits and ORs in the new image's
  own `icontrol`, so the compression bit and shifts come from the new record.

Full `build.py` (LOAD2 included), all Phase D guards pass (boxlab warning
only). The first `mamerom.py` refused to package because LOAD2's DOSBox
timestamps were ahead of the chips; `makevrom.py` was re-run after the clock
caught up and packaging passed - no guard bypassed.

| Check | Result |
|---|---|
| Scan re-run | the 10 targeted records now compressed; remaining candidates 18,921 -> 10,047 B = **8,874 B freed** (estimate 8,879) |
| `rom_space_report.py` | bank 1 free 346,576 -> **355,456 B** (+8,880); program headroom unchanged |
| `art_identity_snapshot.py` | 1,679 records moved with identical pixels; 1 CHANGED: `JXSPLIT9A` |
| `JXSPLIT9A` vs authored NUJAX10.IMG | LOAD2 left it **4 px** wrong in its last rows (2 after the Tower cloud flip, 1 in stock) - alignment-dependent bit bleed, not the compression change. **Now repaired:** [`tools/fix_load2_bit_bleed.py`](../../tools/fix_load2_bit_bleed.py) runs as Phase B2e2 (`--apply`) and in Phase D (`--check`), rewriting only the stray pixel values from the authored IMG inside the record's own bits. Full rebuild: 4 repaired, Phase D check clean, **0 px** differ from the authored art - better than stock |
| MAME, attract from power-on | 443 / 443 captures identical, old build vs new; title letters and "II" flash on screen |
| MAME, 1P start to the ladder | 368 / 368 identical; the BATTLE PLAN ladder is on screen in captures 140-160 |
| MAME, Tower fight (native) | 27 / 27 identical, 781 / 781 trace rows match, same DMA starts and timing |

The Tower sky shows through the arch in every capture and matches, but these
frames do not separately prove CLOUD2/CLOUD3 were in view; their decoded
pixels are identical and their swap path is checked in source. Rigs:
`tmp/comp_policy/attract_capture.lua` + `attract_ab.py` (`--mode attract|ladder`).

[memory note]: the LOAD2 bit-bleed record is known from the Tower cloud flip-reuse work.

Per-record output: `tmp/comp_policy/comp_policy.csv`, summary `tmp/comp_policy/summary.json`.

## The rope and the Tower row clouds stay raw (15 September 2026)

These two groups were parked until flipped-object clipping was solved. Row 17
has since solved it for the clouds (`cloud_mirror_off`/`on`). They are still
not being compressed, because what blocks them is the skip, not the flip.

- **`ofset` is used by these two consumers and nothing else.** Every writer in
  `src/*.ASM`: BGND's `clip_a_row` family (the row clouds), MKZAP's
  `lineup_rope_with_him` (the rope), and code that zeroes it or copies it
  (`getobj` defaults, the high clouds' "no clipping", TWRBACK's reflections,
  MKDISP's ghost copy). The stock screen-edge clipper `dclipl` clips through the
  DMA window, never `ofset`. Its flip-aware skip block is commented out.
- **Midway authored exactly those two groups `ZOF>`.** Everything else in the
  same LODs is `ZON>`.

So no stock board ever drew a compressed image with a skip, and the art that
needed a skip was deliberately left raw. A MAME A/B would only show MAME's
blitter, not the DMA2's. This project has to run on stock T-Unit boards, and 8,587 B is not worth that
risk. Both groups are closed.
