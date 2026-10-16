# getprc Null-Return Bug Fixes

## Background

`getprc` allocates a process slot from the shared pool (~168 slots). When the pool is
exhausted it returns **a0 = 0** — but its exit path runs `mmfm sp,a2,a12` before `rets`,
which sets the Z flag from **a12** (the restored stack pointer), not from a0. A `jreq`
placed directly after `calla getprc` therefore does **not** test a0. The required idiom
is:

```asm
calla getprc
move  a0,a0      ; set Z from a0
jreq  fail_label
```

This idiom is established in `MKBLOOD.ASM:39-41` and was used as the model for all
fixes below.

---

## Root Cause of the Reptile Air Spit Crash

After 8–9 air spits the process pool became thin. The next spit's `getprc` returned 0,
and unguarded callers wrote process-init data to `*a0(field)` with a0 = 0. Bit address 0
in TMS34010 is the start of **screen RAM** (FLOORORG display list). Writing garbage into
the display list corrupts the display program executed by the hardware during video
blanking, causing:

- Animation timers to stop advancing ("animation speeds up")
- Opponents to freeze in place
- CPU eventually spinning in `clear_ram` / similar screen-zeroing utility with a0 = 0

Confirmed crash state: **PC = FF8EEA30, a0 = 00000000** (inside `clear_ram` loop,
zeroing screen RAM from address 0).

---

## Fixes Applied

### 1. `gmo_proc` — MKUTIL.ASM

Creates a `multi_dummy_proc` + display object for multipart overlays. Called by
`get_proj_obj_m` and directly by `spit_proc`.

**Problem:** `getprc` return not tested; if 0, subsequent writes go to screen RAM.

**Fix:** Added `move a0,a0 / jreq gmo_fail` after `calla getprc`. `gmo_fail` returns
a0 = 0, a8 = 0 so callers can detect failure.

---

### 2. `get_proj_obj_m` — MKZAP.ASM

Wrapper around `gmo_proc`; creates the projectile overlay object. Used by nearly every
projectile move.

**Problem:** No null check on `gmo_proc` return; `move a0,*a8(oslink),l` would write 0
to screen RAM if a8 = 0.

**Fix:** Added `jreq gpo_m_fail` after `move a8,a10`. `gpo_m_fail` restores a8 (via
`pull`) and returns a10 = 0. All callers must test a10 after the call.

**Important:** `get_proj_obj_m` ends with `calla match_ani_points; rets`. On success,
`match_ani_points` may return with Z = 1 (e.g. when flip bits match, leaving the result
of an equal `cmp`). Callers **must not** use `jreq` directly after `callr get_proj_obj_m`
— they must explicitly re-test a10:

```asm
callr  get_proj_obj_m
move   a10,a10       ; re-test — Z from match_ani_points is unreliable
jreq   fail_label
```

---

### 3. `spawn_proj_proc` — MKZAP.ASM

Calls `getprc` to create the projectile flight process (air_spit_proc, spit_proc, etc.).

**Problem:** No null check; subsequent writes of `p_action`, `pa8`, `p_store*` fields
to address 0 corrupt screen RAM.

**Fix:** `move a0,a0 / jreq spp_fail` after `calla getprc`. `spp_fail: rets` with
a0 = 0, Z = 1.

---

### 4. `do_rp_airspit` — MKZAP.ASM

Orchestrates Reptile's air acid spit: face overlay windup → acid blob → spit proc.

**Two guarded call sites:**

**Face overlay (first `get_proj_obj_m`):**
```asm
callr  get_proj_obj_m
move   a10,a0          ; sets Z correctly from a10
jreq   rpas_skip_face_ins
calla  insobj
rpas_skip_face_ins
```
Without the guard, `insobj(0)` would corrupt the object list.

**Acid blob (second `get_proj_obj_m`):**
```asm
callr  get_proj_obj_m
move   a10,a10         ; explicit Z re-test (match_ani_points clobbers Z)
jreq   airspit_no_acid
; ... spawn spit proc ...
airspit_no_acid
```
Without the guard, a10 = 0 propagates into `pa8`, so `air_spit_proc` starts with a8 = 0
and crashes on `match_ani_points`.

---

### 5. `spit_proc` — MKZAP.ASM

Ground spit process. Calls `gmo_proc` directly (not via `get_proj_obj_m`).

**Problem:** `move a0,*a8(oslink),l` immediately after `calla gmo_proc`; if gmo_proc
fails, a8 = 0 → screen RAM write.

**Fix:**
```asm
calla  gmo_proc
move   a8,a8
jreq   spit_proc_shared   ; pool full; skip overlay, go direct to flight
```
The spit still flies without the face overlay.

---

### 6. `make_1_exp` — MKFX.ASM

Spawns a bone explosion particle.

**Fix:** `move a0,a0 / jreq make_1_exp_done` after `calla getprc`.

---

### 7. `spawn_a6_bones` — MKFX.ASM

Spawns paired bone particles. Two `create` calls; second can fail after first succeeded,
leaving first proc with uninitialised `p_store3` (doubly-dereferenced as a frame pointer
→ crash in `bone_init`).

**Fix:** Null checks after each `create`; `move a5,*a14(p_store3),l` pre-populated
before the second `create` so a bail-out leaves a valid frame pointer in the first proc.

---

## Drone Throw Guard Addition — MKDRONE.ASM

### Problem

`drone_body_slam` already checked `is_stick_away` (joystick back direction) to abort a
CPU throw. The block button was not checked, allowing the CPU to throw a player who was
holding block.

### Fix

Added `check_block_bit` to the opponent-context check block. `check_block_bit` reads
`@switch` (raw hardware input) and uses `procid` to select P1 or P2 mask, so it works
correctly with A13 swapped to the opponent's process:

```asm
mmtm  sp,a13,a8
move  *a13(p_otherguy),a8,l
move  *a13(p_otherproc),a13,l
calla is_stick_away
jrc   dbs_opp_abort        ; back held
callr check_block_bit      ; block button also escapes
dbs_opp_abort
mmfm  sp,a13,a8
jrc   drone_slam_abort     ; back or block → no throw
```

`check_block_bit` was also exported (`JOY.ASM` `.global`, `MAINEQU.ASM` declaration) so
MKDRONE.ASM can link to it.

---

## Files Changed

| File | Change |
|------|--------|
| `src/MKUTIL.ASM` | `gmo_proc` null guard + `gmo_fail` label |
| `src/MKZAP.ASM` | `get_proj_obj_m` null guard; `spawn_proj_proc` null guard; `do_rp_airspit` two null guards + `move a10,a10` Z-fix; `spit_proc` null guard |
| `src/MKFX.ASM` | `make_1_exp` null guard; `spawn_a6_bones` two null guards + p_store3 safety pre-fill |
| `src/MKDRONE.ASM` | `drone_body_slam` block-button throw escape |
| `src/JOY.ASM` | `.global check_block_bit` export |
| `src/MAINEQU.ASM` | `check_block_bit` added to JOY global declarations |
