# Fatality Alignment — how sprites get placed, and how to tell whether it worked

Companion to [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md). That guide
covers getting a fatality to *run*. This one covers getting it to land in the
right place, and — the harder half — proving that it did.

Written 2026-08-03 after Scorpion's MK1 scortch shipped with the flame 143 px
off on one side of the screen and nobody noticed for weeks.

---

## 1. The placement model

`ganiof` (`MKDISP.ASM` ~1645) is the whole story:

```
left_edge = anchor - anix_eff

anix_eff = anix                    not h-flipped
anix_eff = (sizex - 1) - anix      h-flipped
```

The **anipoint is the anchor**, and the art hangs off it. Two consequences do
most of the damage in practice:

**a) Art mirrors exactly about the anipoint.** The drawn centre relative to the
anchor is `c` one way and `-c` the other:

```
c = -anix + (sizex - 1)/2      unflipped
c = +anix - (sizex - 1)/2      flipped
```

So **a hand-tuned nudge constant in the sequence code can never be right on both
sides of the screen.** One that centres the effect with the attacker on the left
throws it `2*dx` away with the attacker on the right. If you find yourself
adding `movi <n>,a0 / add a0,*a8(oxval)` to make something line up, the
anipoint is wrong — fix the art, not the code. See
[`img_anipoint.py`](../img_anipoint.py).

**b) `oxval` is the master, and it must be adjusted RELATIVELY.** `oxpos`
(`0x090`) is the integer half of `oxval` (`0x080`), so writing it does work —
but `ani`/`ani2` maintain `oxval` by *adding* each frame's anipoint delta, so
stomping an absolute value there breaks the base every later frame is measured
from. `move *a8(oxval),a0,l / addi N*010000h,a0 / move a0,*a8(oxval),l` shifts a
whole animation together and leaves that chain intact.

**c) Multipart geometry lives in the ani2 record, not the object.** For a
multiparter, `oimg` points at a per-piece RAM record laid out
`sag(32) size(32) ctrl(16) dx(16) dy(16)` — so width is at bit **+32** and the
*applied* anipoint offset at bit **+80**. The head object's `osizex` reads back
**0**. Getting this wrong silently produces `nil`/zero widths in a probe.

---

## 2. What the engine gives you

A dozen-odd placement verbs, all in `MKUTIL.ASM` / `MKZAP.ASM` / `MKBLOOD.ASM`:

```
match_ani_points      match_single          match_me_with_him
lineup_with_a11_offset    a11_blood_lineup      get_blood_lineup_a11
lineup_1pwm           lineup_rope_with_him  psycho_lineup
shocker_lineup        gush_lineup           noog_lineup_1
ground_multi          ground_player         multi_adjust_xy    center_around_me
```

**Every one of these is a setter. Not one returns a verdict.** There is no
`are_we_lined_up`, and there never was — nothing at runtime in a 1993 arcade
game has any reason to ask whether a sprite landed correctly.

That asymmetry is why placement bugs survive: the code confidently places the
sprite every frame and nothing anywhere can disagree with it.

Notes on the two you'll use most:

- **`match_ani_points`** copies `oxval`/`oyval` **and flips the object to match
  the reference's facing**. For a single (non-multipart) object it takes
  `match_single`, which recomputes `oxpos` from the object's *own* position — so
  it does not move a single object onto anything by itself.
- **`multi_adjust_xy`** moves only the one object handed to it, despite the
  name. `ground_multi` is the one that walks the `oslink` chain.

---

## 3. Tooling that exists today

### Interactive tuners (nudge by eye, get numbers out)

| tool | scope | controls |
|---|---|---|
| `tools/jc_kheart_placement.lua` + `run_jc_kheart_placement.ps1` | KHEART lane, Cage headhole. Pauses per authored scene frame. | arrows move; `Space`/`S` commit+advance; `A` commit+back; `Esc` exit |
| `tools/deadpool_ed_tuner.lua` | Dead Pool Ed + chain. Continuous, also tunes Z. | arrows = chain anchor; `WASD` = Ed relative; `Z/X`,`C/V` = z; `Space`/`N` = frame step; `T` restart; `R` mark a reading |

`jc_kheart_placement` writes a CSV/TXT with `base_world_x/y`,
`final_world_x/y`, `delta_x/y` per scene, so you nudge visually and get numbers
to bake in.

**Its structure is the reusable part**: it is not a standalone harness. It is
`dofile(jc_headhole_fatality_test.lua)` plus env flags
(`JC_KHEART_PLACEMENT=1`, `..._MAX_REL`, `..._STATE_DIR`). The base harness owns
boot / matchup / Finish-Him; the tuner only adds the pause-and-nudge layer.
That's the cheap way to bolt a tuner onto any existing fatality harness.

Use the kheart pattern when the offset must differ per frame; the ed_tuner
pattern when there's a single anchor to dial in.

### Snap-only harnesses

These write fighter `oxpos`/`oxval` purely to force a deterministic distance so
the move fires, then assert **liveness** — frames present, z-order, no crash.
They say nothing about where anything landed:

`st_decap_fatality_test`, `st_soul_suck_test`, `st_kintaro_morph_test`,
`baraka_spark_finishim_test`, `shang_tomb_spike_test`, `jc_headhole_*`,
`scorpion_scortch_mk1_test`, `kahn_boss_moves_test`, `kahn_playable_jump_test`,
`arena_goro_observe`.

### No positioning at all

Pure regression checks: `reptile_tongue_fatality_test`,
`raiden_bolt_decap_test`, `shang_flip_decap_test`.

### Actual geometry measurement

Two places, both bespoke, nothing shared:

- `jc_headhole_fatality_test.lua`'s placement machinery (records coordinates;
  **you** are the assertion — it does not judge).
- `scorpion_scortch_mk1_test.lua`'s `draw_centre()` + the `CENTRE` / `VSBODY`
  log lines (~30 lines, added 2026-08-02).

---

## 4. The gap, and what would close it

There is no shared helper. Every new harness starts from zero and defaults to
"does it crash" rather than "is it in the right place."

Proposed `tools/lineup.lua`:

```lua
lineup.centre(obj)              -- drawn centre (ani2 record: dx @+80, w @+32)
lineup.span(obj)                -- left, right
lineup.delta(a, b)              -- signed pixels between two objects' centres
lineup.watch(label, a, b, tol)  -- per-frame log + PASS/FAIL at the end
```

so a harness reads:

```lua
lineup.watch("fire vs victim", fire_obj, victim_ref, 25)
```

**Not built yet.** Worth doing only if more placement work is expected; for a
one-off, copying the 30 lines out of the scortch harness is fine.

---

## 5. Gotchas, all of them paid for

**Capture the victim reference BEFORE `takeover_him`.** After the swap, the
"victim" object *is* the corpse/skeleton — measuring against it afterwards
compares the effect to itself and always passes.

**Snap the winner BEFORE handing the loser to `dizzy_dude`.** Its first act is
`face_opponent`, and that is the only thing that turns the loser around.
Snapping afterwards leaves them facing the way they already were — so a
"mirrored" test silently re-runs the same case and passes against nothing. This
exact bug made an entire `-Side right` run meaningless.

**Never compare screenshots taken at different `rel=` values.** The camera
scrolls between them, so identical world positions land at different screen
positions. Measure in world coordinates, or log `worldtlx`.

**Pixel-identical frames share one SAG, so a probe cannot tell them apart.**
LOAD2 dedups by foreground checksum. Sub-Zero's `LKSPINEHEAD1-4` differ only in
their anipoints, so all four got the same payload address and a SAG→label table
reported every one of them as `LKSPINEHEAD4` — which reads exactly like "three
frames never rendered". Identify such frames by the anipoint `ani2` applied
(multipart RAM `+80`) instead.

**The flipped offset `ani2` stores is `sizex - anix`, not `(sizex-1) - anix`.**
§1's formula is `ganiof`'s; the value that lands in the multipart record
measures one higher (16 wide, `anix` −107 → 123, not 122). Immaterial for
placement, fatal for a probe that matches on it exactly — accept both forms.

**`multi_adjust_xy` negates dx against the object it MOVES, not against you.**
After `match_him_with_me_f` that object is the victim, whose facing was just set
*opposite* to yours so he looks at you — so a positive `adjust_him_xy` dx walks
him backwards into the space behind you. Pass it negated. It still mirrors
correctly on both screen sides, because his facing mirrors with yours. Cost a
run on the Sub-Zero head rip: attacker at 688 facing right, victim landed at
576 instead of 800.

**Anipoints are metadata — editing them does not move pixels.** The `.IRW` stays
byte-identical, SAGs don't move, the video ROM is untouched. Safe to iterate on.

**`ground_multi` grounds by the sprite's BOTTOM EDGE, not the anipoint** — it
calls `lowest_mpart` and shifts the whole chain so the lowest piece sits on
`ground_y`. So **a uniform `aniy` shift on anything grounded after its frame is
loaded is a silent no-op**: the sprite is simply re-planted in the same place.

Order is everything:

| sequence | does the art's `aniy` matter? |
|---|---|
| `ground_multi` → `do_next_a9_frame` (the MK1 flame) | **yes** — `ani` applies the new frame's anipoint delta after grounding |
| `do_next_a9_frame` → `ground_multi` (the MK1 skeleton) | **no** — grounding overrides it |

For the second case a vertical offset has to be an explicit post-ground nudge
(`mk1skel_drop` in `MKFX.ASM`). That is the one place a placement constant in
code is legitimate: `aniy` physically cannot express it, and Y has no facing to
mirror, so the "never use a constant" rule (§1a) does not apply. **The relative
`aniy` between frames still matters** — keep `H - aniy` uniform across the
sequence or the pile will drift as it collapses.

**Check which record form the LOD actually loads.** `MK1SKULL.LOD` loads
MK1FIRE **composites** but MK1SKEL **A/B strips**; the other form of each sits
in the IMG and the TBL and ships nowhere. Editing the unloaded twin is a silent
no-op. Relationship when transferring a delta:
`composite anix == strip A anix`, `composite aniy == strip B aniy`.

**A hand-maintained sidecar `.TBL` can desync from its `.IMG`.** Nothing in
`build.py` promotes `MK1SKULL.TBL`, so Phase D now runs
`img_anipoint.py sync-tbl --check` against it. Do the same for any new sidecar.

**Reading an imgtool crosshair edit:** a drag writes X *and* Y. If an edit
collapses a column of distinct `anix` values to one uniform number across every
frame, that is a mouse artefact, not intent — cross-check whether the other lane
moved in X at all before taking it literally.

---

## 6. Related

- [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) — getting one to run
- [RAIDEN_LIGHTNING_FATALITY_ANIPTS.md](RAIDEN_LIGHTNING_FATALITY_ANIPTS.md) — a worked per-frame anipoint capture
- [gmo_proc_convention.md](gmo_proc_convention.md) — overlay object creation
- `../img_anipoint.py` — list / shift / set IMG anipoints, `sync-tbl` to mirror them into a hand-maintained TBL
- `../midway-imgtool/doc/ANIPOINT_MIRROR_TODO.md` — proposed imgtool features to make mirror errors visible at authoring time
