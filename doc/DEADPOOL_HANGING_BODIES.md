# Dead Pool — Hanging Bodies Planning Doc

## Current test body positions (`hanger_initab` in `src/MKHANG.ASM`)

The active Dead Pool test setup no longer uses the old background placement
table. These are deliberately uneven positions for the new strip bodies and
their matching acid skeletons, spread across the scroll range with distinct
heights. The parallax layer uses `worldtlx4` for scroll correction (see
`hp_compute_base_x`).

| # | Human strip | Acid strip | worldx | worldy | Match drop delay |
|---|-------|-------|--------|--------|-----------------|
| 0 | `EDHANG1A-L` | `DEDHANG1A-L` | 92 | 14 | `0x0240` |
| 1 | `MARKHANG1A-M` | `DMARKHANG1A-M` | 225 | 54 | `0x0420` |
| 2 | `TONYHANG1A-L` | `DTONYHANG1A-M` | 365 | 22 | `0x0600` |
| 3 | `JOHNHANG1A-K` | `DJOHNHANG1A-L` | 535 | 64 | `0x07e0` |
| 4 | `GEOHANG1A-N` | `DGEOHANG1A-N` | 690 | 30 | `0x09c0` |
| 5 | `JEFFHANG1A-M` | `DJEFFHANG1A-M` | 835 | 48 | `0x0ba0` |
| 6 | `SALHANG1A-K` | `DSALHANG1A-L` | 1010 | 16 | `0x0d80` |
| 7 | `STEVEHG1A-M` | `DSTEVEHANG1A-M` | 1215 | 60 | `0x0f60` |
| 8 | `ERICHANG1A-L` | none | 470 | 10 | never drops |

`NHANGERS` is currently `9`, and `NSTRIP_HANGERS` is also `9`, so all active
bodies use multipart strip assembly. `hp_dropped` persists across rounds in the
same match: a body that fell in round 1 respawns as its acid strip in round 2/3
instead of resetting to the human body. Eric is the permanent static hanger.
Drop timers can expire offscreen, but `hp_drop_in_view` holds the body until its
parallax-corrected anchor is inside the current viewport.

---

## ACIDHANG.IMG — acid body strip file

Located at `data/ACIDHANG.IMG`. Current body strip records confirmed from the
IMG IMAGE header table:

| Body | Acid strip records |
|------|--------------------|
| Ed | `DEDHANG1A-L` |
| Mark | `DMARKHANG1A-M` |
| Tony | `DTONYHANG1A-M` |
| John | `DJOHNHANG1A-L` |
| Geo | `DGEOHANG1A-N` |
| Jeff | `DJEFFHANG1A-M` |
| Sal | `DSALHANG1A-L` |
| Steve | `DSTEVEHANG1A-M` |

> **Note:** ACIDHANG.IMG is currently packed by `data/MOVEART1.LOD` and emitted as
> `src/ACIDHANG.TBL`. TINCHAIN4, TINHOOK, and longchain still come from MKHANG.IMG in MK7MIL;
> the full old ACIDBONES sprites remain retired.

---

## Player chain sprites

Disabled for the current hanging-body test (`player_chain_enable .equ 0` in
`src/MKHANG.ASM`). Fixed hanger chains/hooks still render and animate with each
body; only the overhead `longchain` + `TINHOOK` pair that followed each fighter
has been removed.

When re-enabled, each fighter displays a `longchain` + `TINCHAIN4` + `TINHOOK` behind them
(ozpos = -1, behind fighters):

- **longchain** (5x211 px): vertical chain from off-screen top down to near
  the fighter's head. Anchor at top-left (anix=0, aniy=0).
- **TINCHAIN4** (4x70 px): short connector segment behind the body/hook.
- **TINHOOK** (8x21 px): the hook where the chain terminates, at the fighter's
  upper-chest area. Anchor at top-left.

| Sprite | `oypos` offset | Rationale |
|--------|---------------|-----------|
| `longchain` top | -250 | places top ~21px above screen; bottom at -250+211 = -39 |
| `TINHOOK` top | -40 | hook at approximately upper-chest/shoulder area |

Live-tune via MAME: `w@<pc_chain_obj/8>=<new_ypos>` or use the hanger coord
RAM table pattern from `hanger_coords`.

---

## Current animation sequence (IMPLEMENTED)

### Player chains (disabled)
`player_chain_proc` remains in `MKHANG.ASM`, but `create_hangers` no longer
spawns it while `player_chain_enable` is `0`.

### Hanging body drop + strip skeleton rise (active — hanger_proc)

Triggers:
- Per-hanger match countdown while `gstate == gs_fighting` and `winner_status == 0`.
- `winner_status == 3` (Finish Him) still drops any visible bodies that have not already gone.
- Both paths pass through `hp_drop_in_view`; offscreen bodies wait instead of
  starting their drop out of frame.

1. **Fall**: body + chain + hook animate downward together
   (`drop_step=8px` per `drop_ticks=4` ticks) from init Y until
   `acid_body_hide_y=0x40`. The loop checks the hide threshold before drawing
   each step so the corpse never renders over the foreground floor lip.
2. **Sink**: chain + hook are dropped to `acid_rise_start=0xC0`, then the body
   is deleted immediately (`delobjp`).
3. **Splash**: `acidsplash1a` sprite at body X; `green_splash_proc` plays
   `a_green_splash` animation at `acid_fx_y=0xB8`.
4. **Drip burst**: two staggered `drip_proc` instances play MKSKULL
   `greendrip1-0` just above the acid lip after the body disappears. The drip
   effect runs out-of-line so it cannot clobber the main hanger process state.
   Acid FX use `acid_fx_z = -6`, so the bridge/floor lip can mask them.
5. **Wait + bubble boil**: `sleep 0x50`, then three `BUBL1-4` bubble procs
   boil around the body center one after another. Each bubble now plays one full
   cycle and the next one waits `pre_rise_bubble_gap=0x18`, so the bubbles do
   not overlap. X stagger is kept tight around the saved splash X.
6. **Chain pullback**: spawn the matching sliced skeleton set at
   `acid_rise_start=0xC0`; chain and hook stay alive and travel with the skeleton.
7. **Rise**: play the cumulative skeleton strip reveal while rising with
   `rise_step=2px` per `rise_ticks=4` ticks until `hp_origin_y` (the original
   hanging-body Y). `hp_place_skel_pull` pins word coords, fixed-point coords,
   and z-order so the skeleton stays aligned to the hook/chain and remains
   behind the acid/floor foreground (`acid_skel_z = -8`). `hp_update_chain`
   copies that z to the hook and chain once the body submerges, so the metal
   also sits behind the acid lip during pullback.
8. **Ripples**: stable `pooldrip1-6` ripple procs play during the skeleton rise.
9. **Hold**: skeleton, hook, and chain stay at the original hanger position via
   `hp_hold_acid`; the acid body continues to track stage parallax on later rounds.

Player-fall path (`r_fall_in_slime` in `BGND.ASM`) still uses `acidskel1-11`
(original retail animation) — unchanged.

---

## Originally-planned animation sequence

### Trigger
- Uppercut (`do_upcut`) on Dead Pool while `curback == 0` and `winner_status == 3`
  (Finish Him). Both magic-button check (all 3 buttons) already in `MOVES.ASM`.
- Loser gets `act_slime_fall`, winner plays out via `act_upcut_sd` + `victory_animation`.

### Drop phase (existing — `r_fall_in_slime` in `BGND.ASM`)
1. Loser flies toward acid with `flight()`.
2. Green acid splash: `a_green_splash` table (`acidsplash1a` .. `acidsplash8` from `MKBGANI.TBL`).
3. Loser sprite goes invisible (`set_inviso`), pauses 0x50 ticks.

### Skeleton rise phase (implemented — ACIDBONES1-4)
4. Spawn skeleton at splash position using `ACIDBONES1`..`ACIDBONES4` from ACIDHANG.IMG.
5. Animate rise using `framew` + a new `a_acidbones_rise` table (replaces or extends
   the existing `acidskel1-11` animation).
6. Hold skeleton on screen; play optional sound (`>f6` bubble, `>f7` oh-maw).

### Chain retract (future)
7. After skeleton rises, animate `longchain` shortening (if custom frames available).
8. If no retract art: cut chain and fade skeleton.

---

## MKSKULL.IMG — additional Dead Pool acid sprites

`data/MKSKULL.IMG` contains 78 images with acid drip, ripple, and splash effects
already in the video ROM. Key sprite names:

| Sprites | Description |
|---------|-------------|
| `rip1..rip9` | Acid ripple animation (9 frames) |
| `lash1a..lash8` | Acid splash variants (8 frames + sub-frames) |
| `ip1..ip6` | Additional impact/drip frames |
| `el1..el8` | Electric/effect frames |

These are loaded from MK7MIL.LOD and are already available as chunk records.
Good candidates for enriching the acid splash or adding ambient acid effects.

Palette note: `BUBL1`, `greendrip1`, and `pooldrip1` in `src/MKBGANI.TBL` now
carry `.long apool_p`, matching `acidsplash1a` and `acidskel1`. The animation
follow-up frames inherit the object palette after `gso_dmawnz` creates the first
frame. `drip_proc` plays the full `greendrip1-0` sequence; `ripple_proc` plays
`pooldrip1-6`.

---

## Key source files

| File | Role |
|------|------|
| `src/MKHANG.ASM` | Creates hanging bodies + player chains |
| `src/MKCHUNKS.TBL` | Chunk records for TINHOOK, longchain, *HANG sprites |
| `src/BGND.ASM` | `r_fall_in_slime`, `calla_dedpool`, display lists |
| `src/MKBGANI.TBL` | `acidskel1-11` and `acidsplash*` chunk records |
| `data/MOVEART1.LOD` | LOD build list for the current ACIDHANG.IMG strip skeletons |
| `data/ACIDHANG.IMG` | Acid strip bodies and palettes used after each hanger drops |
