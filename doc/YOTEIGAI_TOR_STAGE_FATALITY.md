# YOTEIGAI TOR's stage fatality — off the bridge, down the mountain

The third stage fatality. Unlike THE PIT II's it never cuts away, and unlike
THE DEAD POOL's it is a real `check_dtp` fatality rather than a modifier on an
ordinary uppercut. The victim is knocked off the bridge, the camera rides the
mountain down 756 rows, and he goes into the blood-red sea at its foot.


## The current shape (2026-10-05)

Everything below this section is the history of how it got here. Where it
disagrees with this section, this section is right.

**The body moves freely.** He keeps the line the uppercut gave him from the hit
to the water, as THE PIT (MK1) does, and nothing turns him round. Two things
used to: a throw that could come back OVER the winner when the water ran out
ahead of him, and a mid-air catch (`mtn_steer_to_sea`) that leaned him back in
from the edge. Both kept him on the water and both read as the body bouncing.
The hook is now `mtn_fall_behind` and does only the display-list swap.

**The camera stays still sideways**, as it always has here (`stop_scrolling`
in `peak_fall_scroll`). This is the deliberate difference from THE PIT (MK1),
whose camera pans with the body.

**What is aimed is the SPEED of the throw, never its direction.** It is always
away from the winner. `r_fall_off_mountain` measures how much water is left
ahead of him on screen (`peak_water_bounds`, the same 88px margin) and picks
`room * 640` in 16.16 - the speed that runs out just as he goes in, since the
fall is ~104 ticks - capped at `peak_throw_vel` (2px) and floored at
`peak_throw_min` (1/4 px, so a cornered man still drifts off the hit rather
than going straight up). A man already past the usable water comes down at its
very edge; the SPLASH is then slid onto the water (`peak_splash_lip`, 24px),
not the body - a few pixels at most.

**The skull.** Rises at 4 ticks a frame (was 10) and does NOT bob - tried
as a run of fish-bite tugs, then one, then dropped at the user's call.
`peak_bob_tab` is empty; its commented row is one tug (fleshup7 -> 3, 4 rows,
1 tick a frame down and 2 back up), so bringing it back is data. Then it drifts towards whichever side of the screen
has MORE room (its middle against screen x 199) at 1/4 px a
tick (`peak_skull_drift` 04000h, half THE DEAD POOL skeleton's speed), and
keeps going.

**`skull_lane` keeps it vertical.** `ani` migrates `oxval` as well as `oyval`
by the anipoint delta, fleshup's `anix` runs 8..16 while the head stays at the
left of every frame, so `framew` walked the skull up to 8px sideways a lane and
the bob read as diagonal. `skull_lane` puts `oxval` back after each frame
change; the drift is untouched because `dclipl` adds `oxvel` between frames.

**No rain once he is off the bridge.** `dlists_peak_fall` leaves
`peak_rain_lst` out, so the storm stops drawing the tick `mtn_fall_behind`
installs it - his feet into the deck. The rain process carries on unseen; the
next round's module puts `dlists_peak` back. The storm is a hash of
`battle_num` and the pairing (`peak_weather_roll`), so the rig forces it with
`PK_BATTLE` (3..8 are wet for Liu Kang v Jax) and logs `RAIN rel=... drops=`.

**The camera floor is the last PAINTED row**, `peak_art_bot` 1040, not the
module's last row 1042: mount1's water blocks stop two rows short, and parking
on 1042 left two rows of sky along the bottom of the screen.
`tools/peak_sea_band.py --check` measures it (`painted`) and the rig reads it.

**No ripples** (tried, with THE DEAD POOL's `pooldrip1-4` recoloured onto
`mtntop1_p`, and removed at the user's call).

**The rocks stay in front of the skull, and the bottom-left corner is filled,
with no new art** (`peak_dress_bottom`, called the tick he goes in). Both are
CLONES of live `baklst3` block objects - the whole object block copied word for
word, so sag, size, flags and colour map are exactly the plane's:

| clone | block (mount1BLKS) | list | why |
|---|---|---|---|
| the spike | `04243H,396,922,03AH` | `peak_front_lst`, after the skull | a cut-out block of its own |
| the flat rock | `04043H,325,943,028H` | `peak_front_lst` | likewise |
| rock face + water | `04143H,91,878,04H`, moved -91 | `peak_fill_lst`, BEFORE `baklst3` | mount1 has NO blocks below row 896 at module x 0..90 |
| the water's last rows | `04044H,91,937,05H`, moved -91 | `peak_fill_lst` | likewise |
| the right-hand column | every block starting at module x 389..470 that reaches row 690, except the spike, moved +83 and +166 | `peak_fill_lst` | mount1 stops at x 508, with its own empty corner below row 816; the screen reaches x ~590 |

The skull has to be drawn after `baklst3` (behind it, the water surface washed
the whole skull out), so the rocks standing in the water drew BEHIND it; the
spike and the flat rock happen to be their own transparent blocks, so a copy on
a list after the skull fixes exactly them. The fill copies are drawn BEFORE
`baklst3`, so the real blocks cover the overlap and the copies only show
through the hole - which was a black box under the cliff at the left end of the
stage. Module x/y + (304, 82) is plane-3 world. Nothing scrolls sideways for
the rest of the round, so a copy made once stays right. Both new lists live in
RAM.ASM with `.globl` (kept out of MAINEQU) and are cleared at the top of the
fall with `peak_skull_lst`, before the hook can install the list that walks
them - previously `peak_skull_lst` was cleared only when the skull was made,
after `dlists_peak_fall` was already walking it.

The right side is copied as one translated COLUMN (`peak_fill_right`), not
block by block: copying each block by its own width left seams in the water, a
step in the waterline and a strip of sky above, because the blocks have
transparent edges. The step is 83 - the water block (03Ch) is 84 wide with an
EMPTY last column, so 84 left a 1px crack at every join.

Rig additions: `PK_SNAP=a:b:step` snapshots across a beat, `-Observe N` to
watch the float, and a `LIST` line at rel 300 with both clone lists.

---

## How it fires

Exactly the way the Pit and the Tomb do — the same per-character
stage-fatality motion, at the same range. `check_dtp` ([MOVES.ASM:8143](../src/MOVES.ASM))
gated on `curback` 018h:

| condition | where |
|---|---|
| `f_no_violence` off | `check_dtp` |
| `winner_status == 3` (FINISH HIM) | `check_dtp` |
| `curback` is 6, 1 **or 018h** | `check_dtp`, and Shang's own copy in `st_down` |
| the character's `scom_*_dtp` motion | `combo_look_lr` |
| `get_x_dist <= 048h` | `fatality_xfer_close` |

All ten `scom_*_dtp` handlers reach it, so every fighter inherits this at once
and so does the drone ([MKDRONE.ASM:1195-1198](../src/MKDRONE.ASM)). Liu Kang's
is **Back, Forward, Forward + Low Kick** inside a 36-tick window.

**There are TWO stage gates and they are not the same code.** `st_down`
pre-tests `curback` itself before ever reaching `check_dtp`. A stage added to
one has to be added to the other or Shang silently cannot do it.

`do_down_the_mountain` ([MKDEATH.ASM](../src/MKDEATH.ASM)) is
`do_down_the_pit` with one word changed: the victim gets `act_mtn_fall`
(050ch) instead of `act_pit_fall`, and `r_upcutted` dispatches that to
`r_fall_off_mountain` ([BGND.ASM](../src/BGND.ASM)). It keeps
`pit_fatality` as its `f_death` number, so the audit, the death-blow tone and
`death_blow_complete`'s music cue all behave exactly as the Pit's do.

## Why there is no cut

`mount1BMOD` is **509 x 961** ([BGNDTBL.ASM:2655](../src/BGNDTBL.ASM)) and sits
at world y 82. The deck is at world y 247 and the feet at 265, so there are
**796 rows of mountain below the fighters** and the bottom 22 of them are the
sea. The Pit II needs `falling_down_the_pit`'s quadrant scene because its shaft
does not exist as art; this one does.

`worldtly` is advanced by `scrolly` for *every* plane, unclamped, in the
display pass itself ([MKDISP.ASM:851](../src/MKDISP.ASM)) — the same mechanism
the Pit shaft descends on. The module streams its own blocks in through
`multi_plane`/`bgnd_ud1` as the camera moves. Nothing else is needed.

The velocity triple is the Pit's, untouched: `-0c0000h` launch, `06000h`
gravity, `00fh` animation. Only the floor moves.

```
feet            world y  265
waterline       world y 1021
mount1 ends     world y 1042
peak_fall_drop  = 1021 - 265 + 12 = 768   (12px UNDER the surface - he goes in)
```

~103 ticks against the Pit II's 118. It reads identically.

## The geometry, and the tool that guards it

Every number is measured off `MOUNTAIN.BDB`/`.BDD`:

```
python tools/peak_sea_band.py            # report
python tools/peak_sea_band.py --check    # what Phase D runs
python tools/peak_sea_band.py --dump tmp/mount1.png
```

| equate | value | what it is |
|---|---|---|
| `peak_sea_y` | 1021 | the waterline, world y |
| `peak_sea_lft/rgt` | 395..792 | the sea's extent, **plane 3's** world x |
| `peak_sea_cx` | 593 | where the body is aimed |
| `peak_sea_bot` | 1042 | mount1's last row |
| `peak_fall_cam_y` | `peak_sea_bot-scrbot` = 789 | the camera's floor |
| `peak_behind_y` | 150 | where he goes behind the bridge |
| `peak_fall_drop` | 768 | deck line to 12px under the water |

Re-cutting the BDD moves all of them without touching a line of source, which
is the failure `tools/deadpool_acid_band.py` already exists to catch on THE
DEAD POOL. This runs in Phase D for the same reason.

## The three things that were actually hard

### 1. The sea is on a different plane from the body

`mount1BMOD` is `baklst3` at `08000h` — a **quarter** of the fighting plane's
`020000h`. So a fighter's `oxpos` and a block in that module only line up at
one camera position, and a fixed world x would be right there and wrong
everywhere else. This is THE DEAD POOL's ledge problem with parallax on top.

`mtn_steer_to_sea`, `flight_call`'s every-tick hook, asks the question in
SCREEN space — the only space the two share:

```
    body screen x = oxpos       - worldtlx
    sea  screen x = peak_sea_cx - worldtlx3
```

Equate them and the target is `oxpos = peak_sea_cx + worldtlx - worldtlx3`.
No division, and no assumption about the scroll rate: `worldtlx3` is a live
variable, so retuning plane 3 carries this with it.

**It has to start at the APEX, not at the ground line.** `away_x_vel` throws
him 2px a tick for the whole climb. Waiting for his anipoint to pass
`peak_ground_y` let him put 127px between himself and the water before the
steering was allowed to look at him, and he then ran out of fall trying to get
back — measured, from the far end of the bridge. The first moment the throw has
finished reading is `oyvel >= 0`.

`peak_steer_vel` is `050000h`, 5px a tick. The worst case is the camera pinned
at a scroll limit with a fighter at the edge of his own bounds, ~250px, and
there are ~70 ticks between the apex and the water. **`018000h` and `030000h`
were both measured short.** Do not trim it back without re-running the sweep.

### 2. A velocity chase stops where the body stops

Copying `*a11(oyvel)` into `scrolly` means the camera halts the instant
`flight`'s `stop_me` does, and the frame ends up wherever he happened to come
down — 12 rows high on the first trial, which crops the sea to a ten-row strip
along the bottom of the screen. `pfs_settle` closes the last rows onto
`peak_fall_cam_y` under its own power at 4px a tick, so the waterline lands in
the same place every time.

It is gated on how far down the mountain he is, not just on `oyvel`: he is
standing still on the bridge before the uppercut too.

The clamp is checked **before** the chase, not after. Terminal velocity here is
~27px a tick, so testing after the fact would still let it overshoot the last
row of art by most of a screen of autoerase black.

### 3. He has to fall BEHIND the bridge

`dlists_peak` draws `objlst` after `baklst5` and `baklst4`, so a fighter stands
in front of the far railing and on top of the stone deck. Right while he is
standing on it; wrong the moment he is falling past it. Left alone the victim
drops in FRONT of the bridge he was just thrown off.

`dlists_peak_fall` moves the fighters back a course — after the mountain,
before the deck. Only `baklst7`, the near railing, is still in front of them,
and it was in front of them before: it is the near lip of the bridge.

**A z sort cannot do this.** `ozval` only orders objects within one list; the
deck and the railings are hand-placed objects on `baklst4/5/7` and the order
between lists is that table and nothing else.

The swap fires at `peak_behind_y`, 24px of fall past standing height, which is
where his feet start disappearing into the deck. Testing his ANIPOINT against
the ground line is **115px too late** — by then he is already clear underneath
and the swap has nothing left to hide.

The winner is on `objlst` too, so for the ~30 frames the bridge is still on
screen his feet are behind the deck's top rows. That is the whole cost, it is
paid while the camera is already pulling away from him, and the alternative —
unlinking a live player object out of `objlst` into a background list
mid-flight, from inside `flight_call` — is a much worse trade.

Nothing swaps it back. The round ends there, and the next one re-runs the
stage's module, which installs `dlists_peak` again.

## The splash costs nothing

It is THE DEAD POOL's own `acidsplash1a-8`, already in MK6MIL, `swpal`'d onto
`mtntop1_p` at the moment of impact. The first 44 entries of that palette are
`apool_p`'s ramp re-hued — same luminance order, crimson instead of acid green
— so one `swpal` turns the green splash into this stage's blood-red one with no
new art and no new video ROM.

**If either palette is re-authored, re-check that correspondence.** Nothing in
the build enforces it; it is a property of how the art was drawn.

## Closing it out

The skull's frame is where `death_blow_complete` is called. It raises `f_death`
to -1 **and** sends `035h`, the death-blow-over tune. This used to be a
hand-written `f_death = -1`, copied from THE DEAD POOL, and that is only half
of the job: `rfom3` calls `nosounds`, which kills the `034h` death-blow tone
`make_db_tone` started at the uppercut, and nothing ever started anything
again — so from the throw to the round tearing down the only audio was the
scream, the splash and the bubble, over silence. THE DEAD POOL gets away with
the same shortcut only because it never calls `nosounds` at all; its tone
plays straight through the drop.

The call sits exactly where the flag write did, so `f_death` still goes to -1
on the same tick it always did. PIT II (`fall7`, MKFALL.ASM), THE TOMB and THE
PIT (MK1) all close the same way.

## The skull

`fleshup1-7` out of `MKSKULL.IMG`, the only new art in the whole feature —
2,170 bytes in `data/MTNSKUL.LOD`, bank 0, carved off the top of the
FLAPJACK-to-JADVIC hole so FLAPJACK keeps its base and 3,998 bytes of guard.

`a_mtn_skull` runs once at sleep 6 (the rate `MOUNTSKULL1.WAX` was authored
at), then parks on `fleshup7` and sets `oxvel` to `-peak_skull_drift` —
**half a pixel a tick, back towards the winner**, the opposite direction to THE
DEAD POOL's skeleton. `dclipl` adds `oxvel` every frame for anything in a drawn
list, so there is no process to run.

The rise is the art's own anipoints doing the work: `fleshup1` sits at aniy -14
and `fleshup7` at -6, so the sprite climbs 8px across the lane while growing
from 9 rows to 17. `framew` walks that; nothing in the code moves it.

`mtntop1_p` is carried by hand in [IMGPAL7.ASM](../src/IMGPAL7.ASM) next to
this stage's `DROPS`, because nothing in the build promotes an IMG palette into
the ROM and `data/MTNSKUL.LOD` is `PON>`. Read it back out with
`python tools/img_palette.py data/MKSKULL.IMG mtntop1_p`.

## Testing

```
pwsh tools/run_peak_stage_fatality_test.ps1 -VictimX 400 -Side left
pwsh tools/run_peak_stage_fatality_test.ps1 -VictimX 1000 -Side right
```

One run is one trial: pin the victim at `-VictimX` with the attacker `-Gap`
away on `-Side`, drive Liu Kang's motion, and watch. It fails on any of four
separate things, only one of which is "did the fatality fire":

* the victim never gets `act_mtn_fall` — **trigger**
* the camera does not land exactly on `peak_fall_cam_y` — **camera**
* the splash lands outside the water in SCREEN terms — **aim**
* the skull never rises, or never drifts — **payoff**

**`-VictimX` is the variable that matters.** The aim failure is invisible in
the middle of the bridge and only shows up from the ends, which is exactly what
`tools/run_deadpool_slime_fall_test.ps1` exists for on THE DEAD POOL. Sweep it
before believing a change.

The rig holds the pin for `PK_SETTLE` (540) frames before firing, so the
scroller can travel to the pinned position. Without that the trial is not a
position on the bridge at all: `pin()` teleports the fighters, the scroller
closes ~2px a tick, and a fatality fired 10 frames later happens with the body
400px off the camera — which cannot happen in play and makes the aim look far
worse than it is.

### If the log is never created

That is MAME's red ROM-warning screen, not a crash and not this fatality.

It appears on **every** run: the mk2 driver carries undumped PLDs, and on top
of that every source build changes the program and video SHA1s, so the set can
never verify clean. There is no `-skip_warnings` switch in this build. MAME
parks on "press any key", the autoboot Lua never loads, no log is ever created,
and the runner reports it as a missing verdict.

`tools/mame_dismiss_warning.ps1` answers it, and this rig launches it. It has
to be a **separate process**: a rig that started MAME with redirected
stdout/stderr never owns the foreground, so Windows refuses its
`SetForegroundWindow` and the injected keys go nowhere. Any new MAME rig in
this tree needs the same two things this one took two passes to get right -
that poker, and `mame_mk2test.exe` rather than `mame.exe`, so two sweeps do not
`Stop-Process` each other.

Separately, a run that produces a log but no `RESULT` line, with the frame
counter stalled a few hundred frames in, is contention with another MAME - kill
strays and re-run. See `reference_mame_rig_contention`.

## Sweep result

Nine positions across the bridge, both sides, all PASS. Re-run 2026-09-22 after
the steer was rewritten (see "The shape of the fall" below):

| victim x | attacker side | landed | splash, screen x | xturns |
|---|---|---|---|---|
| 120 | left | 201 | 181 | 0 |
| 200 | right | 246 | 146 | 1 |
| 250 | left | 313 | 216 | 0 |
| 400 | left | 463 | 216 | 0 |
| 500 | right | 475 | 75 | 1 |
| 700 | left | 627 | 227 | 1 |
| 760 | left | 687 | 227 | 1 |
| 850 | left | 773 | 223 | 1 |
| 1000 | left | 857 | 157 | 1 |
| 1000 | right | 840 | 85 | 0 |

`xturns` 0 means the fall never changed horizontal direction at all - the
throw was aimed and nothing touched it afterwards. 1 is the single turn from
the launch's own velocity.

Every one reached `peak_fall_cam_y` exactly, produced a splash and a skull, and
ended with `f_death` = -1. Note the far positions: at 1000 the steering pulls
him ~200px back over the water, which is what `peak_steer_vel` is sized for.

**The numbers all moved, and they moved towards the target.** The aim is
checkable: `mtn_steer_to_sea`'s target is `oxpos = peak_sea_cx + worldtlx -
worldtlx3`, and the trace says where he settled.

| victim x | target oxpos | settled | miss |
|---|---|---|---|
| 760 left | 638 | 640 | 2 px (was 660, 22 px) |
| 700 left | 593 | 595 | 2 px (was 721, 128 px) |

The old steer stopped dead as soon as it was inside `peak_sea_slop`, so it
habitually finished ~20 px short; 700 left was 128 px out because `repell` had
taken the steer over entirely for part of the fall. The ramp coasts the last
few pixels instead of braking, so he arrives on the number.

## The code lives in src/PEAKFAT.ASM

Moved there 2026-09-22. `r_fall_off_mountain`, `peak_fall_scroll`,
`mtn_steer_to_sea`, `peak_water_bounds`, the splash, the rising skull,
`dlists_peak_fall` and the `peak_*` equates only they use. BGND.ASM was over
GSPA's memory ceiling again - it is the third split, after `src/TWRBACK.ASM`
and `src/ARENAKIN.ASM` - and it dropped from 8,422 to 7,994 lines.

`peak_ground_y` is in `src/MAINEQU.ASM` now, because BGND.ASM's stage record
and PEAKFAT.ASM's fall both need it and `.set` equates do not cross an object
boundary. `mtnskul.tbl` moved WITH the skull and is no longer included by
BGND.ASM: including one table from two objects duplicates its data in ROM.

BGND.ASM keeps the STAGE - `peak_mod`, its scroller, the rain, and
`a_green_splash`, which THE DEAD POOL uses too and which is now `.globl`.

## The skull rises out of the water, not over it

`peak_skull_lst` (RAM.ASM, beside `peak_rain_lst`) is the skull's own display
list, and `dlists_peak_fall` draws it BEFORE `baklst3`. So the mountain plane -
which is the sea and the rocks standing in it - covers him: the submerged part
is hidden and the rocks at the waterline pass in front.

It has to be a list of its own. `ozpos` only orders objects WITHIN one list;
the sea is background blocks on `baklst3`, and the order between lists is
`dlists_peak_fall` and nothing else. The list is cleared at the fall rather
than at round start, because the object pool is rebuilt between rounds and a
stale pointer left in it would be walked.

The rig had to learn about it too: `find_art()` walks `objlst`/`objlst2`/
`objlst3`, so the first run after the change reported `no_skull` on a skull
that was plainly on screen - the rig measuring its own list, not the game.

## The throw is aimed, not corrected

*History - superseded by "The current shape (2026-10-05)" above.*


THE DEAD POOL's `fis3` trick (`r_fall_in_slime`, BGND.ASM), for the same
reason: the arc is known, so ask where it LANDS rather than correcting it on
the way down. `peak_mtn_arc` (208 px) is the whole fall's sideways travel at
`peak_throw_vel` - 32 ticks up and 72 down, ~104 ticks at 2 px each. If
throwing him away from the winner would land him outside
`peak_water_bounds`, he is thrown back OVER the winner instead: inward,
towards the middle, and then nothing touches him for the rest of the fall.

`away_x_vel` negates a negative `a0`, so passing `-peak_throw_vel` flies him
towards the winner from either side.

**This is what takes the wall-bounce out, and the ramped steer did not.** A
mid-air correction is still a correction however smoothly it is ramped: the
body flies one way, something invisible turns it round, and that reads as a
bounce because that is what it is. Ramping only changed how *abrupt* the
bounce was. A throw aimed the other way to begin with is just the uppercut,
and `mtn_steer_to_sea` is left as a last-resort catch that writes nothing at
all at every position swept.

## xor does not set N

*History - superseded by "The current shape (2026-10-05)" above.*


`mtn_steer_to_sea` compares two signs - the throw's direction against the
body's current velocity - and it does it with two branches, not an XOR.

`xor a3,a1` followed by `jrnn` assembles clean, runs, and tests the N flag
left by the instruction *before* it. On the TMS34010 the logical ops set Z and
leave N alone. The test silently became "is he left of the winner", and the
only symptom was an 18-tick delay: the ease-out fired the tick the body's
`oxpos` crossed the winner's (measured, attacker at 702: held -5 px/tick from
rel 56 to 74 and eased at 75) instead of the tick he came back inside the
bounds. Nothing about it looks wrong in the source.

## The rising skull

*History - superseded by "The current shape (2026-10-05)" above.*

It never touched the water. Measured against the waterline - screen row 232
with the camera on its clamp, `PK_SKULLTRACE=1` in the rig - the skull's
BOTTOM row was 223..229 on every one of its seven frames, so it floated
entirely in the air and came to rest 25 rows above the lake with 9 rows of
sky under its chin.

`peak_skull_y` was `peak_sea_y-17` and is now `peak_sea_y-3`. It is where the
FIRST frame sits, not the last: the frames migrate `oypos` 8 rows up as they
play, because `anig1` (MKDISP.ASM) moves it by the anipoint delta on every
frame change - the same trap THE PIT (MK1)'s blood fountain hit. At -3,
`fleshup1` breaks the surface with its crown showing and `fleshup7` rests with
its top 11 rows clear of the water and its bottom 5 under.

| | was | now |
|---|---|---|
| `peak_skull_y` | `peak_sea_y-17` | `peak_sea_y-3` |
| rest position | 25 rows above the water | 11 above, 5 under |
| `peak_skull_drift` | 08000h, 1/2 px/tick (27 px/s) | 02000h, 1/8 px/tick |
| rise rate | 6 ticks/frame, 42 total | 10 ticks/frame, 70 total |

## The shape of the fall

*History - superseded by "The current shape (2026-10-05)" above.*


`PK_FALLTRACE=1` logs the victim's screen x and both velocities once per tick,
and the `RESULT` line carries `xturns` - how many times he changed horizontal
DIRECTION. One is correct: thrown out, steered back. The rig fails above one.

Traced at victim x 760, attacker left, the version before 2026-09-22 read
`xturns=7`:

| rel | what happened |
|---|---|
| 008-039 | thrown, +2 px/tick out - the climb is fine, the steer sits out the rise |
| 040 | apex: **+2 to -5 on one tick**, a 7 px swing |
| 063 | **-5 to +3** - `repell_now` takes the steer over as the body falls past the winner |
| 072-076 | **-5, +3, -5, +3, -5 on consecutive ticks** - the two of them writing on alternate ticks |
| 077-090 | -5 settles |
| 091 | **-5 to 0**, dead stop, 14 ticks before the water |

The winner was dragged 36 px along the bridge (`atk_x` 705 -> 669) while it
happened.

Two changes, both shared with THE PIT (MK1) - see `doc/MK1_PIT_STAGE.md`, where
the same two defects were found first:

- **`f_norepell` is set for the fall** (`disable_repell`, MKDEATH.ASM). That
  removes the takeover, the judder and the dragged winner.
- **The steer ramps** at `peak_steer_acc` (1/2 px a tick per tick) towards
  `peak_steer_vel` instead of being assigned, and ramps back down the same way.
  The apex becomes a 14-tick curve through zero and the arrival a coast rather
  than a brake. It costs ~5 ticks of the ~70 between the apex and the sea,
  against the ~20 ticks of margin `peak_steer_vel` was chosen with; the far
  positions above are the proof that margin is still there.

After: +2, +1.5, +1, +0.5, 0, -0.5 ... -5, held, then -4.5 ... -0.5, 0 onto the
target. `xturns` is 0 or 1 at every one of the nine positions.
