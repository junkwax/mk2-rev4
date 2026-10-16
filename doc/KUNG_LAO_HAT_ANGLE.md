# Kung Lao's hat banks into the angle it is flying at

`slicehat` / `slhatcap` (MAINEQU.ASM) · `hat_proc` (MKZAP.ASM) ·
`slicehat_pics` (MKHH.ASM) · `data/SLICEHAT.LOD` · rig
`tools/run_slicehat_test.ps1`

## What was already there

**Retail MK2 already steers the hat.** `hat_proc` (MKZAP.ASM) reads the
thrower's stick every tick of the flight and adds `±0a000h` to the hat's
`oyvel` for Up / Down. That is Midway's code, unchanged here.

What it never had was a sprite to match. The flight loop is `j_hatloop` -
`HATFLY4` and `HATFLY5`, two flat 20-pixel-tall motion blurs - and it runs at
`init_anirate 4` whatever angle the hat is actually travelling at. A hat
steered hard up looks exactly like a hat thrown flat.

## What the art is

`SLICEHAT1-16` in `data/HATHED12.IMG`. They are **not** Midway's:
mk2-readonly's `HATHED12.IMG` has no record of that name, and before this
nothing in `src/` or in any LOD referenced one, so not a pixel of them had
ever reached a ROM.

Measure the principal axis of each frame's opaque mask and you get a ramp of
bank angles (degrees, y down):

| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|
| +0.9 | -4.9 | -12.7 | -21.4 | -30.7 | -38.8 | -38.5 | -30.9 |

| 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
|---|---|---|---|---|---|---|---|
| -22.4 | -13.7 | -6.0 | 0.0 | +4.9 | +12.7 | +21.4 | +30.7 |

### The art is DIRECTIONAL: every frame carries a motion trail

A pale smear lies off **one side** of each hat, and which side is measured,
not guessed - split the opaque pixels by luminance and the trail's centroid
sits 0.6 to 5.3px to one side of the body's:

| frames | trail side | drawn for a hat flying |
|---|---|---|
| 1-6 | **LEFT** | RIGHT |
| 7-16 | **RIGHT** | LEFT |

So the sixteen are **not** sixteen banks, and **not** two spin phases. They
are **six banks drawn twice, once per travel direction**, plus four extra
banks that exist leftward only:

- `1-6` against `12-7` are mirror pairs at the same bank - silhouette IoU
  0.98 at level, degrading only because they are hand-redrawn rather than
  flipped. The artist mirrored them by hand so the **lit rim stays on the
  same side of the screen** in both directions, which a DMA flip cannot do.
- `13-16` (+4.9 .. +30.7) have no rightward counterpart.

**This was got wrong once.** Reading the `1-6` / `7-12` split as two spin
phases put `SLICEHAT13-16` on a *rightward* dive with the trail **leading**,
which is exactly what the trail is there to prevent.

## What is packed

**All sixteen**, 13,112 bytes, and `hat_proc` picks the set **by facing** so
each throw draws the art authored for the way it is going:

| bucket | thrown RIGHT | thrown LEFT | on screen |
|---|---|---|---|
| 0 | `SLICEHAT6` | `SLICEHAT6` (*) | -38.8 |
| 1 | `SLICEHAT5` | `SLICEHAT16` | -30.7 |
| 2 | `SLICEHAT4` | `SLICEHAT15` | -21.4 |
| 3 | `SLICEHAT3` | `SLICEHAT14` | -12.7 |
| 4 | `SLICEHAT2` | `SLICEHAT13` | -4.9 |
| 5 | `SLICEHAT1` | `SLICEHAT12` | +0.9 (level) |
| 6-10 | `SLICEHAT11,10,9,8,7` | same | +6.0 .. +38.5 |

The **dive** row is the leftward art in both cases, because **there are no
rightward dive frames at all** - `1-6` is climb and level only. For a
rightward throw it is H-flipped, which mirrors the trail and negates the bank
together and so yields a rightward dive whose trail is still behind.

**(*) The one gap.** The leftward climb tops out at +30.7 (`SLICEHAT16`), so
bucket 0 - the steepest climb - has no leftward frame and falls back to
`SLICEHAT6` mirrored. That is the only sprite in the set whose lighting
mirrors. A leftward climb at about -38 would close it.

Which buckets flip is `slhat_flipfrom_r` (6) / `slhat_flipfrom_l` (1) in
MAINEQU.ASM, not a column in the table, so the two cannot disagree. Both sets
are a contiguous run from some bucket upward, which is why a threshold says it
exactly.

### There is no spin, and that is the art's doing

Retail's hat spins - `j_hatloop` walks `HATFLY4` / `HATFLY5` at
`init_anirate 4`, 13.7fps - and this gives that up. The two frames at each
bank are the two **travel directions**, not two spin phases, so alternating
them would point half the frames' trails forwards. **The spin is the price of
the bank.**

An earlier cut did exactly that: it alternated `1-6` with `7-12` every 4 ticks
and measured as a clean spin at retail's rate, while putting `SLICEHAT13-16`
on a rightward dive with the trail leading.

### `SLICEHAT16`'s `aniy` is a sign slip, and it has come back twice

It ships at **`-19`** where its neighbours run 14-23, which puts its centre
**36px** out of line with every other frame - they all sit between 0 and -8.
The hat then **leaps 40px** the moment a left-thrown hat reaches the steepest
climb, and back again on the way down, which is what it looks like from the
cabinet: a jump at one point of the stick's travel, in both directions.

Its rightward twin `SLICEHAT5` is the same 48x34 at the same bank and has
`aniy` 20, which is what pins the value.

`data/HATHED12.IMG` is hand-edited in IMGTOOL, so fixing it here is undone by
the next save - it has been reverted once already. **`tools/slicehat_expect.py
--check` is in Phase D for exactly this**: it recomputes where every bucket
places the hat, in both facings, and fails the build if two neighbours step
more than 3px in Y or 5.5px in X. A jump cannot ship silently again.

The X thresholds are looser because two steps are authoring variance rather
than faults, and cannot be fixed without editing the artist's anipoints: the
leftward family is consistently 2-4px off the mirror of the rightward one
(`SLICEHAT12` by 4, `13-16` by 2). That leaves a 5px lateral step at
level->dive thrown right, and 4px at the bucket 0/1 boundary thrown left.
Matching the two families in IMGTOOL would close both.

Bank-1 sidecar at `0x9E0000..0x9E4000` (16,384 bytes), hard under JDROD's
fixed base. RAINCLD gave up the top half of its old 32,768-byte slot and
still keeps ~7KB of growth. Bank 1 is safe for the same reason RAINBOLT is:
the hat is a bare projectile object and casts no shadow, so `shadow_p1p2`'s
bank-less CPU read never walks it.

## How the frame is chosen

`slhat_frame` (MKZAP.ASM) off `slicehat_pics` (rightward) or
`slicehat_picsl` (leftward) in MKHH.ASM, index 0 = steepest climb, 10 =
steepest dive, 5 = level. One frame per bucket; the sign of `oyvel` picks the
bucket and the hat's own `oflags` picks the set.

`oxvel` is a constant `0c0000h` (12.0 px/tick) for the whole flight, so the
flight angle is a function of `oyvel` **alone** and no divide is needed: the
bucket edges are precomputed `oyvel` values, `tan(angle) * 12.0`, each one
the midpoint between two drawn angles (`slhat_b1..b5`, MAINEQU.ASM).

**The facing IS consulted, and it has to be.** The artist mirrored the frames
by hand rather than letting the DMA flip them, which is what keeps the lit rim
on the same side of the screen in both directions - so using one set for both
would mirror the lighting on every left throw, and that is the whole reason
twelve of these sixteen records exist.

Both halves reach five banks either way.

## The palette, and why it is swapped

`SHAT1_P`, hand-carried into `src/IMGPAL6.ASM` and policed by
`tools/sync_slicehat_pal.py --check` (Phase D). The IMG's records name
`SHAT3_P` in their `palnum` field and that is **not** what ships - the LOD is
`POF>` and `hat_proc` applies `SHAT1_P` at runtime, the role `RNCLOUD_P`
plays for Rain's cloud.

It shares **not one word of 64** with `TMHATS_P`, the palette the hat object
is already alive on by the time the flight starts (`do_throw_hat` builds it
on `HATFLY1A`, and a frame change never re-reads a record's `icmap`).
`TMHATS_P` is a bright cyan cel ramp; this is a dense photographic blue with
deep darks it simply has not got, so re-indexing the art onto the hat's own
palette was not an option. `hat_proc` therefore calls `swpal` at the top of
the flight and swaps back at `hatp8`. That costs **+1 foreground colour map**
for the duration of every throw: retail's flying hat and the reappearing one
in Kung Lao's hands were both on `TMHATS_P`, so one map served both.

**A failed swap is not fatal and must not be.** `swpal` returns carry set
when the colour-map pool is empty - a mirror match is when it is tightest -
and drawing SLICEHAT pixels through `TMHATS_P` would be a hat in somebody
else's colours. The flight falls back to retail's HATFLY loop instead.
`delobjp` frees whichever map the object ends up holding, so neither outcome
leaks one.

## `slhatcap` is a gameplay change and is a switch of its own

Retail's steer is **uncapped**: `oyvel` grows `0a000h` a tick for as long as
the stick is held, and over a ~33-tick crossing it can reach ~20 px/tick,
near 60°. The art stops at 38.8°.

- `slhatcap 1` (default) caps `|oyvel|` at `slhat_ymax` (`09A000h` = 9.625
  px/tick = 38.7°) so the sprite never lies about the angle. It costs roughly
  half the maximum vertical deflection a held stick used to buy - the same
  ceiling `orb_aim_ymax` and `rzap_aim` put on their own steers.
- `slhatcap 0` is retail's flight path exactly, and the frame index simply
  **saturates** past the drawn range.

## A hat that connects keeps the bank it hit with

`hatp8` used to hand the palette back to `TMHATS_P` on contact, which dropped
the sprite to retail's flat `HATFLY` blur on the frame it landed - the hat
appeared to turn into a different object as it struck. The restore now lives
in `hat_blocked` alone, which is the path that actually needs it: only the
blocked spin re-points `a9` (`find_ani_part2` -> `hatfly8-11`), and that is
`TMHATS_P` art. `hatpc` keeps calling `slhat_frame` while the palette is
still ours, so a hat that connects sails on at whatever bank it arrived with.

## ...and the blood comes out where it caught him

`hitpoint` (MAINEQU.ASM). Once the hat crosses at whatever height it is flying
at, a spray anchored to the middle of the victim's chest is visibly wrong: a
hat steered over his head and a hat steered through his knees produced exactly
the same burst, in exactly the same place.

**Shao Kahn's flying knee already needed this**, for the same reason and in
the same words - `kahn_knee_contact` (MKREACT.ASM) exists because the knee
"arrives on a 25-degree climb and can catch a man anywhere from the hip to the
head", so `blood_procs[16h]` takes its spawn point in `a9` instead of baking
it in. What is new here is that the point is no longer hand-computed per move.

**`strike_check` stamps it, because `strike_check` is the only thing that
knows it.** At the moment a collision is *proven* - after the last
`jruc no_collision`, so a live attack touching nobody costs nothing - the two
rectangles are both still in registers:

| | |
|---|---|
| `a2` / `a3` | the victim's box, top-left / bottom-right, packed `[y,x]` |
| `a4` / `a5` | the strike box's |
| `a10` | the victim |

The centre of the rectangle those two **share** is written to `hit_pt` (a
p1:p2 pair of longs, RAM.ASM) as a packed `[y,x]` offset from the victim's own
origin, with x mirrored into **facing space**. That is exactly the form
`adjust_blood_a0` takes, so a consumer *adds* it to whatever offset it already
had and nothing else about the spray changes.

It is **measured, not chosen**: the overlap is the thing the compare tested,
so by definition it is where he was hit. `a5` becomes the strike flags two
instructions later, which is why the stamp is taken there and not further
down.

**Only `hat_blood` reads it** - `blood_procs[13h]`, which is the projectile
blood: Kung Lao's hat and Jade's boomerang, outbound (`hat33`) and homeward
(`r_jade_boom_back`). Both of those cross a man at whatever height they are
flying at. The burst lands on the contact point and the drips keep their
`030h` below it, because that separation is the authored shape of the spray -
what moves is the whole thing, onto the wound. The anchored sprays are left
alone deliberately: several of them are aimed at something real
(`sai_waist_blood` at the cut, `kahn_knuckle_blood` at the knuckle row) rather
than merely defaulted, and pointing another one at `hit_pt` is two lines when
it is wanted.

**Each droplet reads the point for itself, off `a11`.** `hit_point_a9` is
given the man in `a11` and not in `a8`, because every caller has already run
`get_jt_blood`, which leaves `a8` holding the droplet it just made. `a11` is
where these routines keep the man, and `get_jt_blood` pushes it across
`gso_dmawnz` precisely so it survives. Taking the point once in `hat_blood`
and inheriting it through `create` would work - `getprc` passes `a8-a11` - but
it would mean trusting `a9` across `gso_dmawnz`, which nothing guarantees.

**`hit_pt` adds 64 bits to `.bss`**, so every RAM address after it moves. Any
rig holding a cached address from an older map reads the wrong thing; that is
the only thing in this change with a blast radius beyond the spray itself.

`hitpoint .set 0` puts both offsets back to retail's `020h` / `050h`.

## The boomerang

`slhatboom` (MAINEQU.ASM), `slhat_boom` / `slhat_reverse` (MKZAP.ASM).

**Hold Low Punch and the hat comes back** - the button it was *thrown* with
(`scom_hh_throw` is Back, Forward + LP), so the gesture is "keep holding what
you threw with" rather than a second button to learn. Kitana's fan works the
same way on her own throw button.

**Low Punch is on `switch2`, not `switch`.** `p1b1` / `p2b1` are marked
"switch 2" in MAINEQU for a reason: `switch` is `01600000h`, `switch2` is
`01600020h`, and the masks **overlap** - `p2b1` and `p1b0` are both `010h`.
Moving this off High Punch by swapping the constant alone, while still reading
`@switch`, would have tested *player one's High Punch* for player two's Low
Punch. `slhat_lp_held` copies JOY.ASM's own low-punch read (`fa_t_free`),
`@switch2` and all.

It cannot share Kitana's `fan_check_hp_held`: that spends a drone's committed
hold out of `p_store3`, which in `hat_proc` is the `am_i_joy` flag.

### The turn happens off screen, and that is the whole manoeuvre

The hat leaves one side and comes back already travelling the other way, so
the change of art reads as **flush** rather than as a pivot the player
watched. There is no turnaround art, and the trail forbids faking one by
flipping mid-flight - but the real reason is simply that seeing it turn is
the failure mode.

**This is where it differs from Kitana.** Her fan curls `fan_turn_margin`
(96px) *inside* the edge, in full view, because the curl **is** her move's
signature. The hat's is not: the rotation exists to get it turned round. So
the trigger is `proj_onscreen_test`, not a turn line, and `slhat_curl_ticks`
is short (2) so the whole rotation fits in the gap.

**It coasts first.** `proj_onscreen_test` goes false at *one pixel* of
clearance, which is not a margin. Measured: a turn begun on that tick put the
hat 29px past a window edge at 1107 with its sprite spanning 1108..1162 - off
screen by a single pixel, and any camera drift would have shown the pivot.
`slhat_turn_delay` (2 ticks, 24px) buys real daylight and costs nothing
anyone can see.

**It is a rotation, not a sign flip.** `slhat_curl_step` turns the velocity
*vector* - half a shear, then a whole one, then half again, velocity Verlet,
which holds the speed to 0.4% where the obvious two-line form swings it 22%.
Kitana's `fan_curl_step`, which cannot be called directly: hers takes the
throw direction out of `p_store6`, and in `hat_proc` that slot is the
SLICEHAT palette flag. The facing is re-derived from the x velocity on every
tick of it (`fan_face_travel`, reused as-is) because x changes sign part way
through - **set** from the sign, never toggled on the crossing.

**The return leg draws the OPPOSITE FRAME, never a mirrored one.** Coming out
of the rotation **both axes are snapped** to the mirror of what went in - the
turn is six degrees short of nothing useful at 2 ticks, so neither exit
velocity is trusted. Kitana snaps her x for the same reason; the hat snaps y
as well, because the twin pairing **is** the sign of `oyvel`. A boomerang
that went out rising comes back falling, and because `slicehat_pics` is
ordered by angle with level in the middle, that sign change turns bucket N
into bucket 10-N. Which lands on exactly the hand-drawn twin:

| | | | | | |
|---|---|---|---|---|---|
| 1 ↔ 12 | 2 ↔ 11 | 3 ↔ 10 | 4 ↔ 9 | 5 ↔ 8 | 6 ↔ 7 |

Those pairs are the same bank drawn for the two directions, and **they carry
different glimmers** - which is the whole reason to use the twin rather than
flip the sprite: a mirror puts the lit edge on the wrong side. Nothing
indexes that pairing by hand; it falls out of the sign change and the table's
ordering, so the two cannot drift apart.

It is **not** `flip_multi`, which XORs the flag and re-runs `ani2` on the
frame already showing - i.e. mirrors it. The facing comes from
`fan_face_travel` instead, so no sprite is ever mirrored. That also turns the
strike box round, which is right: the hat really is coming the other way.

### It recentres on the way home

Out of the turn the hat is banked at the mirror of whatever it went out on,
and **holding that bank all the way back is what made it arch off the screen**
instead of crossing it - it leaves, turns, and then flies out of the top or
bottom still diving. So on the homeward legs it settles: `slhat_recenter` a
tick towards level until it is flying straight, and the bank frames sweep the
ramp back down to `SLICEHAT1`/`12` on their own, because `slhat_frame` reads
the `oyvel` this is moving.

**Only when he is not steering.** A held direction wins outright - the settle
is what the hat does when nothing is being asked of it, not a force fighting
the player. It hangs off the steer's own "no up or down" case, so the two are
one mechanism and cannot disagree. Same size as the steer's nudge: about
fifteen ticks from the steepest bank to level, against a homeward leg of
roughly thirty.

The last step **lands exactly on zero** rather than stepping past and hunting
either side, which at this size would be a visible twitch between `SLICEHAT1`
and its neighbours for the rest of the flight.

The legs are `p_store7`: 0 outward, **4 coasting clear**, **3 rotating**, 1
homeward and out of bounds, 2 homeward and visible. `p_store8`'s low half is
the countdown for each - **a WORD, because its high half is `slhat_vturn`**
(the outbound bank in 8.8, Kitana's `fan_vturn` trick). Left as a long it
read the stored bank back as part of the count and a 2-tick turn ran for 96.
And `slhat_vturn` is defined down beside the `p_store` block, not with the
other `slhat_` equates: GSPA resolves a `.set` in one pass and rejects a
forward reference to `p_store8` outright, the same trap `rh_half_dmg` hit
against `full_strength`.

The steer is suppressed while the rotation owns the velocity - a held stick
would fight it `0a000h` at a time and bend the turn.

**The turn must not fall through to the on-screen test.** Reversing `oxvel`
does not move the hat, so it is still outside the window that tick and the
test would delete it on the spot - it would flip its velocity and die in the
same tick, and nothing would ever come back. Jade's blade carries the
identical hazard and the identical note (`jbp_return_arm`).

Legs are `p_store7` (0 outward, 1 home and out of bounds, 2 home and visible)
with `p_store8` a bounded wait, both **seeded at the top of `hat_proc`**
because `getprc` does not zero `pdata` and a recycled block would otherwise
start a fresh throw already halfway home.

**A hat that connected does not come back** - it falls into the hit loop and
dies off the edge as it always has. Jade's blade does get a second leg; doing
the same here means restructuring `hatpc` as well.

**The drone commits to it up front**, the way Jade's does. A person holding
HP is committing to the recovery and can be punished for it, so the drone does
not get the payoff for free: `slhat_drone_hold` rolls a hold duration at the
instant of the throw (Jade's own `rpt_boom_hold` odds - the roll can come up
"tapped", more often the easier the setting) and `slhat_hp_held` spends it
down.

It **cannot** share Kitana's `fan_check_hp_held`: hers spends the budget out of
`p_store3`, and in this process that slot is `hat_proc`'s own `am_i_joy` flag,
so calling it would decrement the flag that decides whether the hat can be
steered at all. The hat's copy keeps the budget in `p_store5`.

## Traps

**A plain hit does not re-point `a9`.** Only the blocked path does
(`hat_blocked` → `find_ani_part2`). A hat that connects falls into `hatpa`,
which leaves `a9` in the flight loop - so it carries on drawing
`hatfly3/4/5` while it sails off screen, and with no steer, because `hatpc`
has no joystick read. **A hat that is quietly hitting something therefore
looks exactly like this table failing: HATFLY art and a frozen `oyvel`.** It
cost a rig cycle: the victim was parked in front of the thrower and the hat
reached him three ticks in. The tell is `p_action = act_proj_dead` (0500h).

**`proj_strike_check` does not eat process scratch here.** That was the first
guess and it was wrong. Markers written into `p_store4/5/6/7/8` at the top of
the flight all survive to the end of it; the clear that looked like a clobber
was `hat_proc`'s own one at `hatp8`. The flag lives in `p_store6` only
because `hat_proc` already spends 1, 2 and 3.

**The rig's per-tick lag is real and is not slop.** `hat_proc` draws the
frame from the `oyvel` it *starts* the tick with, then steers, then sleeps -
so the frame on screen belongs to the previous sample's velocity, and that is
what the check compares against. Comparing against the current one fails by
exactly one bucket for the whole of every steered trial.

## Rig

```
python tools/slicehat_expect.py                 # SAGs + thresholds from the build
python tools/slicehat_expect.py --check         # Phase D: placement continuity
.\tools\run_slicehat_test.ps1 [-Snap] [-Map ..] [-RomPath ..]
SLH_TRACE=1                                     # per-tick object/process trace
```

**It starts MAME detached and pokes the ROM-warning screen.** Source-built
ROMs always trip that warning and MAME sits there waiting for a key, which
ends the run with **"NO LOG - MAME never started"** - a signature that reads
exactly like a broken ROM. `tools/mame_dismiss_warning.ps1` has to be a
separate process: this shell redirects MAME's stdout, so it never owns the
foreground and Windows refuses its `SetForegroundWindow`. Earlier runs only
got past it by luck of focus.

It runs on **`mame_slhtest.exe`**, a copy of `mame.exe` under a name of its
own. A shared "test" binary isolates nothing - several rigs here default to
`mame_mk2test.exe` and clean up by process *name*, so a concurrent session's
sweep kills this one mid-run. Same signature again: every trial NOT REACHED,
which is a NO-VERDICT and not a failure.

It measures **the SAG the DMA was handed**, against the hat's own `oyvel`,
and asserts the *wiring*: for every sampled tick the frame drawn is the one
that velocity calls for, by the same thresholds `hat_proc` uses. A rig that
only watched the sprite change would pass on a table wired backwards, and
inverting the arms is the likely regression. Expectations are regenerated
from `src/SLICEHAT.TBL` and `src/MAINEQU.ASM` on every run, because a rebuild
moves every SAG in the pack.

It also asserts the **trail** and the **facing**: the right set must be chosen
for the hat's own `oflags`, and the flip checked against the piece's own
control word. Checking the frame alone would pass on a hat flying trail-first;
checking one facing only would never draw `SLICEHAT12-16` at all. Measured,
10/10 PASS:

| trial | what it proves | result |
|---|---|---|
| flat / up / down | the rightward ramp | 13/13, 22/22, 22/22 |
| Lflat / Lup / Ldown | the leftward ramp, the hand-drawn set | 14/14, 23/23, 22/22 |
| boom / Lboom | HP held: turns OFF SCREEN, lands on the TWIN, then levels out | hidden, `5`->`8`, `8`->`5`, `|oyvel|` 450560 -> 0 |
| dboom | the drone's budget drives the return, no button held | 40 -> 39, hidden |
| hit | connects and keeps its bank | 10 SLICEHAT frames after contact |
| hit / hiup / hidwn | **the contact point follows the hat** | see below |

Zero trail-backwards in all ten. `oyvel` stops at exactly +/-630784 =
`09A000h` = `slhat_ymax`. The rig also reads `fpal_fail` (PALL.ASM) around
each trial, so an exhausted colour-map pool - which makes `swpal` fail and
`hat_proc` fall back to HATFLY - is reported as a *cause* rather than as a
bare "never found the hat".

The `hit` trial exists because every other one parks the victim clear, so
none of them ever exercised the contact path. `boom` incidentally shows the
returning hat connecting on the way home, which is the point of the move.

**Two rig rules the turn needed.** The bucket after the turn must be read from
the CURRENT `oyvel`, not from `prev_yv` - that is the pre-turn velocity, so
reading it reported the bucket the hat had just left and the twin test could
never pass. And the turn tick is **exempt from the one-tick lag model**: every
other tick draws from the `oyvel` it started with, but `slhat_reverse` negates
and calls `slhat_frame` in the same breath, so on that tick alone the frame is
already the post-turn one. Measured, the ROM drew bucket 10-N there while the
rig expected N - the pairing working, not failing.

**What is asserted is the SIGN change, not the exact bucket.** The steer runs
on the same tick and pulls `oyvel` straight back, so the bucket lands near
10-N rather than on it; the sign flip is what must hold exactly, and it is
what turns N into 10-N.

**And that it comes home level.** The boomerang trials release the stick once
the turn has begun - the settle only happens when nothing is being asked of
the hat, so a trial that held Up the whole flight could never have seen it.

**The contact point is proved by A/B, not by one hit.** A single hit cannot
show that the stamp moves - any constant that happens to land on his chest
would pass, which is precisely the behaviour being replaced. So the same hit
is taken three times at three heights and the stamped y must follow, in the
right order: climbing < level < diving, by at least 8px a step.

The height is **seeded, not steered**. Over the ~12 ticks this flight lasts
the steer only accumulates a few pixels - far inside the noise - so the rig
writes `oyvel` once on the first tick the hat exists. Nothing fights it on the
outward leg: `slhat_recenter_a1` returns 0 there by design. Two consequences
worth knowing: the seeded trials stand **300px apart** rather than 150,
because at 150 the hat is already two ticks from him when `find_hat` first
sees it and a seeded 3 px/tick had moved it six pixels by contact; and the
seeding tick is **exempt from the lag model**, for the turn's own reason - the
frame on screen was picked from the `oyvel` the tick began with, and the rig
has just written a different one.

Each trial also requires the point to be **on his body** (0..0b0h off his
origin, which is his sprite top). A stamp taken off the wrong object, or never
taken at all, fails that on its own without needing the A/B.

**And that every tick of the rotation was out of sight** - the requirement the
whole manoeuvre exists to meet. Two rig rules that took a run each to find:
check visibility on **leg 3 only**, because leg 4 is the coast and is
marginally clear *by design* (that is what it exists to widen), so counting it
reported the rotation as visible before the rotation had started; and do not
assert that `|oxvel|` passes through near-zero - that is the signature of a
*visible* loop, and this one is deliberately partial and snapped.

`dboom` isolates the drone path rather than driving a CPU throw, which this
harness cannot do (the drone sits in `act_stance` - see
`run_smoke_spear_test.ps1`): it clears the thrower's `pb_joy` so
`slhat_hp_held` takes the drone branch, seeds the budget, and requires the hat
to come back with **no HP held**.

**Rig and code traps worth not repeating.**

- `oflags` is at **0f0h**, not 0x20. The wrong offset made the flip check read
  an unrelated field and fail every sample.
- **A register shift silently never fired.** The flip rule was first a bit mask
  per facing, tested with `srl a3,a5` / `andi 1,a5`; the extra flip was then
  applied on *neither* side. Both masks are contiguous runs, so a compare
  against a threshold says the same thing in one instruction and works.
- **Lua's `and`/`or` is not a conditional.** The expected flip was written
  `xflip and (not objflip) or objflip`, which collapses to `objflip` whenever
  the middle term is false - so it agreed with a build that never flipped at
  all, and only the *other* facing disagreed. A boolean XOR (`objflip ~= xflip`)
  is what was meant.
- There is no SAG-to-bucket map and there cannot be one: the same record serves
  two buckets across the two facings. Resolve the bucket from `oyvel`. An
  earlier version indexed a table with the resulting nil, which threw on every
  flipped tick, killed the handler, and reported a spin failure while the code
  was fine - the tell was `[LUA ERROR]` in MAME's own stdout.

**An empty run is not a PASS**: `finish()` fails if fewer than every trial
produced a result. It reported PASS with zero trials once, when a missing
symbol aborted before the first one.
