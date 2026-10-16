# MK2 Netplay — Implementation Log

Reference for netplay-specific changes to the MK2 source. Each section covers
what was done, why it matters, and what is still outstanding.

---

## Architecture Overview

Netplay is implemented as a GGRS/GGPO-style wrapper around MAME emulation.
The game itself runs normally; the wrapper intercepts input reads, advances
frames, and (for rollback) saves/restores emulator state. The source-level
changes listed here ensure the game engine is deterministic so both peers
compute identical game state from identical inputs.

**Core requirement**: given the same `@rand` seed and the same sequence of
inputs, both machines must produce byte-for-byte identical game state every
frame. Any non-deterministic read that feeds game logic breaks this.

---

## Changes: Already Done

### Boot flow

| File | What | Why |
|------|------|-----|
| `SYSEQU.ASM` | `forcefree equ 0` | The ROM is coin operated again. Free play is granted at RUN time from `f_netplay` instead — see **Free play is now runtime** below |
| `MKINIT.ASM` | `netplay_boot_start` proc | Skips attract mode, drops straight into character select |
| `MKAMODE.ASM` | Game-over → `netplay_boot_start` | Auto-restart after a set ends; no attract loop |
| `MKINIT.ASM` | Diag entry gated on `f_netplay` mid-game, live at boot | Diag clears RAM and reseeds state; cannot be allowed mid-session. A cabinet still needs the operator menu, so the TEST switch works whenever `f_netplay` is clear |
| `DIAGCMOS.ASM` | `get_adj(adjfrepl)` returns free play while `f_netplay` is set | One hook covers every free-play test in the game |
| `DIAGDTST.ASM` | Skip "press button to continue" wait | Startup tests complete without operator input |

### Free play is now runtime, not hardwired

`forcefree equ 1` used to hardwire the whole build free, which meant a
cabinet, a local two-player game and an online session all behaved the same:
no coins, no credit display, no operator menu. That is wrong for everything
except the online session.

Free play is now decided by **`f_netplay`**, the flag the host wrapper already
owns:

| `f_netplay` | Behaviour |
|-------------|-----------|
| `0` (cold boot, cabinet, local play) | Coin operated. Pricing comes from the coinage dipswitch or CMOS exactly like a stock L3.1 board. Attract shows `CREDITS: n` / `INSERT COIN`, `cr_strtp` refuses START at zero credits, and the TEST switch opens the operator menu |
| non-zero (online session) | Free play. Attract shows `FREE PLAY`, START always passes, the TEST switch is dead, and `play9` takes the rematch loop instead of the buy-in countdown |

The hook is a single test at the top of `get_adj` (`DIAGCMOS.ASM`). Every free
play question in the game — `checkfree`, `cr_both`, `cr_strtp`, `cr_contp`,
`get_cstr`, `plotcoinage` — funnels through `get_adj(adjfrepl)`, so patching
the read patches all of them and the credit display follows for free. The four
`.if forcefree` short circuits in `DIAGCOIN.ASM` now assemble out and fall
through to that read.

`forcefree equ 1` still works if a build really does want to be hardwired
free, but **do not use it for netplay** — poke `f_netplay` instead, or the
offline half of the build loses its coin handling again.

**Host side (wired).** `f_netplay` is written by the host wrapper and never by
the ROM. `Workplace/freeplay-gametalk` does it from
`netcore::set_netplay_flag`:

- `reset_for_netplay` writes `1`. Every netplay start funnels through it, and
  it runs *after* the clean boot savestate is reloaded (so the reload cannot
  undo it) and *before* the first GGRS save (so rollback carries it).
- Session teardown writes `0`, so Lab and Arcade do not inherit free credits.
- The write is refused when `mk2_addr_check` reports a ROM mismatch.
  `NETPLAY_ACTIVE_ADDR` is `.bss`; on a different ROM build it is some other
  variable, and corrupting that is worse than the coin gate it would lift.
- **Both peers must see the same value.** The flag feeds `cr_strtp`, the
  `play9` rematch branch and `combo_slack`, so a one-sided poke desyncs GGRS
  by itself.

Regenerate the offset and ship the paired ROM together, as the last step of a
build (see [FREEPLAY_FBNEO_REFACTORING.md](FREEPLAY_FBNEO_REFACTORING.md) for
why `--rom` matters):

```powershell
python tools\export_freeplay_addresses.py --rom rom\mk2.zip --rust-out ..\freeplay-gametalk\src\mk2_addrs.rs
copy /y rom\mk2.zip ..\freeplay-gametalk\mk2.zip
```

Anything else that drives this ROM offline has to pay for its credits.
freeplay-gametalk's Lab auto-start now pulses the coin slot before Start
(`lab_autostart_pulses` in its `main.rs`); a rig that only presses Start will
sit at the attract screen forever.

The alternative, if the wrapper would rather not write game RAM: set the
coinage dipswitch to *Coinage Source = Dipswitch* + *USA-Free Play*. The ROM
honours it through `set_dip_coinage` and the result is a genuinely free
machine, at the cost of the whole cabinet being free rather than just the
online session.

---

### Input handling

| File | What | Why |
|------|------|-----|
| `MKINIT.ASM:1457` | Input debounce reduced from 2-frame to 1-frame | Saves ~16.7ms of input latency. Hardware bounce is not a concern in emulation — inputs are clean digital signals |

### Character select determinism

| File | What | Why |
|------|------|-----|
| `MKSEL.ASM:3040–3160` | Random-select uses isolated local xorshift16 seeded from match state | Avoids touching `@rand` or `@hcount` during select. Both peers independently derive the same random walk from deterministic inputs (battle_num, tick, cursor positions, wiar scores). Per-player salts prevent P1 and P2 always picking the same character |

---

## Changes: This Session

### 1. Remove `hcount` from `random()` — DONE

### 2. Separate blood RNG — DONE

**Files changed**: `RAM.ASM`, `UTIL.ASM`, `MAINEQU.ASM`, `MKBLOOD.ASM`, `MKINIT.ASM`

Added `@blood_rand` (32-bit BSS, seeded to `0xF00DCAFE` at boot — distinct from
`@rand`'s `0x81261A8C`). Added `blood_random`/`blood_randu`/`blood_srand`/
`blood_randper` to `UTIL.ASM` — identical xorshift32 logic operating on
`@blood_rand` only.

All 42 RNG call sites in `MKBLOOD.ASM` redirected to blood-local functions.
`random_splish_sound` renamed to `blood_random_splish_sound` with its
`random_triple` → `blood_randu` dependency inlined, so the splash sound
selection no longer touches `@rand` either.

Pool-exhaustion divergence is now harmless: whether `pid_blood` procs are
created or not, `@rand` advances identically on both peers.

---

### Previously done: Remove `hcount` from `random()` — DONE

**File**: `src/UTIL.ASM` lines 78–79 (removed)

**Problem**: The `random()` function ended with:
```asm
    move    @hcount,a1
    rl      a1,a0       ; rotate output by hardware scanline counter
```
`hcount` is the live display scanline counter at hardware address `0xC00001C0`.
It reads whatever horizontal scanline the beam is on at the exact CPU cycle the
instruction executes. Two machines cannot be scanline-synchronized at this
granularity — even running the same code, the scanline differs by an
unpredictable amount per call.

This made **every call to `randu`, `randper`, and `srand` return a different
value on each peer** even with an identical `@rand` state. Hit reactions, blood
trajectories, AI decisions, projectile behavior — anything using randomness
would desync immediately.

**Fix**: Removed the two `hcount` lines. xorshift32 output (period 2^32−1) has
excellent bit distribution without the rotation. The `@rand` state itself
advances identically on both peers.

**Risk**: None. xorshift32 is well-studied. The rotation was a holdover from the
original single-bit LFSR era and provided no statistical benefit.

---

### 3. Round-start `@rand` reseed — DONE

**File**: `src/MAIN.ASM` lines 509–519 (inserted before `gs_fighting`)

**Problem**: `@rand` is seeded once at boot (`81261a8ch`). Minor per-frame
differences (proc pool jitter, object Z-sort tie-breaking) can cause the two
peers' `@rand` states to drift by a small amount. The drift accumulates across
rounds — by round 3 of a close set, the states may differ enough to cause
visible desyncs on hit reactions.

**Fix**: At the top of `play_1_round`, just before the `gs_fighting` state
transition, both RNGs are reseeded from synchronized variables:

```asm
    move    @battle_num,a0,w
    move    @p1_wiar,a1,w
    xor     a1,a0
    move    @p2_wiar,a1,w
    xor     a1,a0
    movi    81261a8ch,a1
    xor     a1,a0           ; mix with constant -- guarantees non-zero, fills upper bits
    move    a0,@rand,l
    xori    0f00dcafeh,a0   ; different constant for blood RNG
    move    a0,@blood_rand,l
```

`battle_num`, `p1_wiar`, and `p2_wiar` are all 16-bit BSS variables that both
peers increment at identical game-state transitions. XORing with `81261a8ch`
guarantees the upper 16 bits are non-zero (xorshift32 dead-state guard) and
provides good bit coverage. The `blood_rand` seed is derived from `rand` seed
XOR `0f00dcafeh` — structurally different so the two RNG streams don't track.

Drift window resets to zero at each round boundary. A close 3-round set that
previously accumulated enough drift to desync on hit reactions now re-syncs
entering every round.

---

### 4. Widen combo input windows — DONE

**File**: `src/MOVES.ASM` lines 5159, 5169 (`button_look_lr` and `combo_look_lr`)

**Problem**: All `scom_*` entries have a time window (first `.word` in the
combo table, in ticks, 1 tick = 18.28ms). With any input delay added by the
netplay layer, tight windows become difficult to hit reliably.

Windows ranged from `0x10` (256ms) to `0x38` (896ms). Tightest ones:
`scom_spark`, `scom_floor_ice`, `scom_hh_teleport`, `scom_ice_ball`,
`scom_lightning`, `scom_rd_melt` — all at `0x10`.

**Fix**: Added `addi 6,a9` after the window load in both `button_look_lr`
and `combo_look_lr`. One central change widens every combo window by 6 ticks
(96ms) without touching individual `scom_*` entries:

```asm
    move    *a11+,a9,w      ; a9 = time frame allowed
    addi    6,a9            ; netplay: widen window 6 ticks (96ms) to cover input delay
```

Effect: `0x10` → 22 ticks (352ms), `0x18` → 30 ticks (480ms), `0x38` → 62
ticks (1134ms). Covers ~6 frames of extra input latency at 18.28ms/tick.

---

### 5. Per-frame desync detection export — DONE

**Files**: `src/RAM.ASM` (BSS), `src/MAINEQU.ASM` (export), `src/MPROC.ASM` (write)

**Problem**: When desyncs occur, they are invisible until HP or position
visibly diverges — often many frames later. Early detection lets the wrapper
resync or disconnect before match state becomes garbage.

**Fix**: Added `netplay_sync` (16-bit BSS) to RAM, written every tick by
`prcdsp` in MPROC.ASM.

**Improved 2026-08-28.** The original was a flat XOR of five values:
```
netplay_sync = p1_bar XOR p2_bar XOR rand[15:0] XOR p1_xpos XOR p2_xpos
```
Two problems, one of each kind:

* **XOR is commutative, so it is blind to a swap.** A divergence where two of
  the mixed values exchange places — p1_bar and p2_bar, or the two X positions
  — produces a byte-identical checksum. Verified: `[A1,32,…]` and `[32,A1,…]`
  both hash to `13b7`.
* **Coverage was thin.** No Y, no `p_action`, no `p_hit`. A divergence in
  height, in what either fighter was *doing*, or in the juggle counter stayed
  invisible until it eventually moved HP or X — many frames later, or never.

Now: **rotate the accumulator 5 bits between terms, then fold the high half
back in before storing**, over eleven values — both bars, `rand`, both X, both
Y, both `p_action`, both `p_hit`. Objects and processes are still null-guarded
for non-fight states.

The fold is not optional and nearly shipped missing. `RL` rotates the whole
32-bit register, so storing with `,w` discards the top half; measured over
200,000 random single-bit divergences that **masked 53% of them** — far worse
than the flat XOR it replaced. With the fold in place:

| | flat XOR | rotate + fold |
|---|---|---|
| swap of two terms | **blind** | detected |
| single-bit divergence masked | 0 / 200,000 | **0 / 200,000** |
| unrelated states colliding | 2 / 200,000 | 4 / 200,000 |

Collisions land at ~1-in-65536 either way, which is what a 16-bit checksum
should do. **The wrapper contract is unchanged** — same address, same
`read_u16`.

**Wrapper integration**: `netplay_sync` is exported via MAINEQU.ASM. Use
`sym_resolve.py --dump | grep netplay_sync` to get the current byte address.
Read `space:read_u16(addr)` each frame in the Lua/GGRS wrapper and compare
with the peer's value. A mismatch means game state has diverged — resync or
disconnect.

```lua
-- example Lua (mk2_test.lua style)
local sync_addr = 0x010edca0  -- update with: python sym_resolve.py --dump | grep netplay_sync
local function get_sync() return mem:read_u16(sync_addr) end
```

---

### 6. Separate weather RNG + hashed weather roll - DONE

**Files changed**: `RAM.ASM`, `UTIL.ASM`, `MAINEQU.ASM`, `MKINIT.ASM`, `BGND.ASM`

Yoteigai Tor's rain (`peak_rain`) respawns 24 drops several times a second and
each respawn wants three numbers - thousands of `@rand` advances a round, and
**how many happen depends on how many display objects the pool had free**
(`objs_available` gates the whole storm). That is the blood problem again, one
scale up.

Added `@weather_rand` (32-bit BSS, seeded to `0x5EED7A11` at boot - distinct
from `@rand`'s `0x81261A8C` and `@blood_rand`'s `0xF00DCAFE`) with
`weather_random` / `weather_randu` in `UTIL.ASM`. All three RNG call sites in
`prn_respawn` redirected. `peak_rain` no longer touches `@rand` at all.

The **decision** - whether it rains on this match - is a separate problem,
because that one has to match on both peers or they are looking at different
stages. It is not a draw from any generator: `peak_weather_roll` hashes
`battle_num`, `p1_char`, `p2_char`, `p1_wiar`, `p2_wiar` and tests the low byte
against `PEAK_RAIN_ODDS`. No RNG state is read or advanced, so there is nothing
to drift; a peer whose pool ran dry still computes the same answer. The roll
also reseeds `@weather_rand` from that key every round, so cosmetic drift in
the jitter heals at the next round boundary rather than persisting.

Verified by `tools/peak_rain_test.lua`, which carries an independent Lua
implementation of the hash and asserts the ASM seeded `@weather_rand` with the
same 32-bit key (run it with `RAIN_FORCE=dry`, where `peak_rain` dies before
churning it: measured `a8f47afe` both sides).

---

## Determinism Reference

| Source | Deterministic? | Notes |
|--------|---------------|-------|
| `@rand` xorshift32 | YES | hcount removed; round-start reseed keeps per-round drift to zero |
| `@hcount` hardware reg | YES | Removed from `random()`; remaining reads are inside `.if ERRORTEST` dead code |
| `@vcount` hardware reg | YES | Only inside `.if bog_line` dead code (bog_line=0) |
| `@switch` input port | YES | Wrapper substitutes remote inputs each frame |
| `@tick` frame counter | YES | Incremented once per frame in ISR; part of saved/restored rollback state |
| `@battle_num` / wiar scores | YES | Incremented at identical game-state transitions on both peers |
| Blood proc `randu` calls | YES | Isolated to `@blood_rand` (fix #2); pool exhaustion no longer touches `@rand` |
| `random_triple` sound select | YES | Calls `randu` from synchronous fight events — same triggers on both peers, same advance count |
| `randsnd` / `randsnd2` | YES | Read-only `@rand` access (sign bit only); no advancement |
| Drone AI (`MKDRONE.ASM`) | YES (H vs H) | Drone doesn't run when both players are human |
| Background procs (`BGND.ASM`) | YES | Created and driven by same game events; `randu`/`randper` advance identically. **Exception, handled**: `peak_rain` is gated on `objs_available`, so its RNG use is pool-dependent - it was moved to `@weather_rand` (fix #6) |
| Stage weather roll | YES | `peak_weather_roll` is a pure hash of `battle_num`/chars/wiar. Reads no RNG and advances none, so pool or proc divergence cannot change the answer |
| `@weather_rand` drop jitter | COSMETIC ONLY | Nothing but `peak_rain`'s drop positions reads it; reseeded from the match key every round, so drift heals at the round boundary |
| Process Z-sort (`yzsort`) | YES | Ties broken by insertion order; deterministic if object creation order is deterministic |
| `UNZIP.ASM` `HCOUNT` reads | YES | Inside `.if ERRORTEST` dead code — never compiled |

---

## Build Note

All netplay changes compile with the standard build pipeline:

```
python build.py --asm-only && python makerom.py && python mamerom.py "mk2.zip" --source-video
```

`SYSEQU.ASM` changes (e.g., `forcefree`) require a full `build.py` (Phase A+B+C)
since that header is included by nearly every ASM file.
