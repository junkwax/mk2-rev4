# Converting an IMGTOOL lane export into an MK2 animation lane

This is the transformation `tools/wvp_to_lane.py` performs, written out step by
step. It is what turned the `a_imgtool_slot*` drafts into `a_sa_windup` and
`a_sa_helitest` in `src/MKSA.ASM`.

Every rule below was arrived at by building it wrong first and measuring in
MAME. The wrong readings are recorded next to the right ones, because each of
them looked plausible.

---

## 0. Read the project, not the paste

A pasted export is a snapshot. The project file in `data/` is the source of
truth, and it has been edited between most exports in this project. Two of the
six lanes built so far were stale on arrival - one missing two whole frames,
another with a frame at the wrong offset.

imgtool writes these as `.WAX` (they were `.WVP` through v3.31.0); the
generator takes the path either way, plus a slot index. Everything below reads
`slot.N.*`.

---

## 1. Frame index to record name

`slot.N.sequence_frames` holds IMG record **indices**, not names.

    doc  = frame_doc_idx[i] < 0 ? slot.N.doc_idx : frame_doc_idx[i]
    name = library[doc].records[ sequence_frames[i] ].name

Read the name out of the IMG header; do not trust the export comment.

---

## 2. Substitute to what the ROM actually holds

A project authored against the shipping libraries names **whole frames**. The
ROM often only holds those as A/B/C strips, already wrapped as a multipart with
the same anipoint - so the wrapper is a free, exact stand-in needing no new art:

| project name | emit | why |
|---|---|---|
| `SPIN1..SPIN5` | `UGSPIN1..UGSPIN5` | same anipoint: `UGSPIN2A` is (48,-5), so is `SPIN2` at idx 36 |
| `SPIN2FLIP/3FLIP/4FLIP` | `UGSPIN2/3/4` **plus an extra X mirror** | the FLIP records are pre-mirrored art; `ani_flip` over the base is the stock idiom, `a_sa_spin` does exactly this |
| `UGTURN1FLIP` | `UGTURN1` + X mirror | same |
| `STKNOCKEDOWN1..7` | `STKNOCKDOWN1..7` | the exporter spells it with an extra E |

**The silent trap.** `SPIN2`..`SPIN2FLIP` exist *twice* - once in `UGMO9.IMG`
on the stock anipoints, once in the `SAHELI` sidecar **re-anchored** for an
older dive. LOAD2 binds a bare `SPIN2` to the highest-indexed record, i.e. the
sidecar copy. Writing `SPIN2` into a lane authored against `UGMO9.IMG`
assembles clean and draws against the wrong anchor.

Verify a substitution by unioning the wrapper strips and comparing to the
project's `w x h`. All 16 in the dive matched within 1px.

---

## 3. Timing: sleep is the gcd of the holds

`slot.N.frame_delays` are per-entry holds **in game ticks**. A lane carries one
sleep, so:

    sleep         = gcd(frame_delays)
    rows(entry i) = frame_delays[i] / sleep

That is what the export prints as `hold 4t = 4 rows x 1t`. Holds of
`1,4,4,4,4,4,4,4` give sleep 1 and 29 rows; holds all `2` give sleep 2 and one
row each.

**Not** `state.default_hold` - that is only the hold a *new* frame gets, not
the lane rate. Reading it as the sleep made a lane four times too slow.

**Not** the tick rate either. The tick rate is hardware: 54.7068 Hz, one game
tick per display refresh, 18.279 ms. A lane at sleep 4 holds each row for
exactly 4 emulator frames - measured, not assumed.

imgtool >= v3.31.0 records this as `state.tick_hz`, a constant - the preview
rate stopped being adjustable, so there is no authored-at value left to store.
Older projects spell it `state.fps` and *can* carry something other than
54.7068; their `frame_delays` are then **preview** ticks, and the gcd of them
is not a game-tick sleep. `wvp_to_lane.py` reads either key and warns when it
sees a non-hardware rate.

What the shipped game uses (`tools/anim_timing_survey.py`):

| sleep | fps | used for |
|---|---|---|
| 1 | 54.7 | `jade_boomerang_proc`, `do_smoke_speed` - rare |
| 2 | 27.4 | **spins** (`do_spin`, `do_hh_spin`), projectiles |
| 3-4 | 13.7-18.2 | strikes, reactions, walking - **58% of all sites** |
| 6 | 9.1 | victories |
| 8-10 | <=6.8 | fatality beats |

---

## 4. Flips: absolute states in, toggles out

`slot.N.frame_mirror` is a bitmask per entry: **bit0 = flip X, bit1 = flip Y**,
and it is that entry's *absolute* state. The engine only has toggles
(`ani_flip`, `ani_flip_v`), so emit one **only where the state changes**.

The base state is the character's own facing - which is why nothing is emitted
for entry 0 unless it is mirrored, and why one lane serves both sides.

Confirm bit0 is X and not Y: read it the other way and `UGSTANCE2` feet land at
64 instead of 223.

---

## 5. Offsets: the sign rule is per frame, not per lane

`slot.N.local_dx/local_dy` are **editor-space anipoint offsets**. The preview
draws at `anchor - anieff(ani + dA, size, flip)`, so the drawn offset from the
anchor is `-dA` unflipped and `+dA` flipped. `multi_adjust_xy` does
`oxpos += dX` / `oypos += dY` and negates **dX alone** under `b_fliph`.
Equating the two:

    dX = fliph ? +local_dx : -local_dx    per frame, off frame_mirror bit 0
    dY = flipv ? +local_dy : -local_dy    per frame, off frame_mirror bit 1

**Both axes, and X only since 2026-08-24.** This used to read `dX = -local_dx`
ALWAYS, on the argument that the engine's own `b_fliph` negation in
`multi_adjust_xy` cancels the preview's X mirror. That negation is real, but
the generator deliberately steps around it - offsets are emitted at *base
facing* (see below) precisely so a per-entry flip cannot reach them - so it
never fired, and every flipX entry drew `2*dAX` away.

It hid because unflipped entries are identical under both readings.
`a_sa_windup` is unflipped throughout, verified clean in MAME, and the rule
looked settled. Check X the way `tools/wv_trace_x.py` does - on the DRAWN
centre, not the anchor, since the anchor is *supposed* to jump when a frame
mirrors:

    dX = -dAX (old)   ctr  73  64  64  82  60  -80  -64 ...   5 jumps of 96-140px
    dX mirrored (new) ctr  73  64  64  82  60   42   60 ...   0 jumps

**This is why a lane-wide negation half-works.** The dive is V-flipped on 21 of
its 27 frames and those 21 carry the whole descent, so "as-is" looked right
there and drove the six unflipped landing frames through the floor. The windup
is unflipped throughout, so every row negates - not because that lane is
special, but because it is the `flipv=0` half of the same rule.

### Absolute to cumulative

The rows are absolute offsets from the anchor; `ani_adjustxy` is cumulative.
Emit the **difference** between consecutive entries, **once per entry** - never
once per repeated row.

### Emit at base facing

`multi_adjust_xy` negates dx against whatever `b_fliph` is *at that moment*,
and the lane's dAX is in facing space - mirrored by the character's facing
alone, not by a per-entry flipX. So drop back to base facing, apply the offset
there, and only then put the entry's own flipX on:

    if currently flipped:   ani_flip        ; back to base
                            ani_adjustxy
    if entry wants flipX:   ani_flip        ; the entry's own mirror
    if flipv changes:       ani_flip_v
                            <frame>

Emitting the offset while a per-entry flipX was still set sent two frames the
wrong way and left the actor 151px from where the project put him.

---

## 6. Where to seat the object

The cumulative dY total says it. If the lane's last pose is a standing pose
that must land on the floor, seat at `p_ganiy - total_dY`.

The dive's dY sums to `-12`, so `do_sa_helitest` seats at `p_ganiy+12`; the
windup's row 0 is at offset 0, so `init_special_act`'s grounding is correct
as-is.

Check with `tools/wv_trace.py`, which walks a lane's **feet** against the floor
(223) using the export's own draw equation. That is how both sign errors were
caught without a rebuild:

    correct  feet  224 218 191 167 146 124 107  78  48
    as-is    feet  224 230 257 281 304 324 343 370 400   <- 176px through the floor

---

## 7. Rate segments

MK2 changes rate *within* a move rather than running a long lane at one speed -
`do_wheel_kick` is 4 then 3, `do_kintaro_fatal` 3 then 10. `mframew_a0` takes
`a0 = [sleep|rows]` and leaves `a9` on the next row, so segments chain.

The generator emits a `<label>_rate` table of `.word sleep,rows` pairs, and
`sahp_walk_rate` (MOVES.ASM) walks it. Rows are classified by **label**, so
re-authoring moves the boundaries instead of stranding a hand-written count.

---

## 8. Hooks

`ani_calla` is transparent to the frame counter, so a callback can sit at any
entry without disturbing rate-table row counts. That is how the victim handover
and the four blood spawns fire from inside the lane, on the row the project's
`Show@` window opens on.

---

## The command

    python tools/wvp_to_lane.py data/barakabladeup.WVP \
           --slot 0 --label a_sa_windup --wrappers --spin-sleep 1 \
           --out tmp/windup_gen.inc

`--wrappers` emits multipart labels directly instead of generating single-frame
wrappers. `--spin-sleep N` runs `UGSPIN*` rows at N and emits the rate table.
`--call-entry N=LABEL` plants an `ani_calla` before entry N.

---

## Worked example: the going-up windup

Input `data/barakabladeup.WVP` slot 0:

    sequence_frames = 6,7,14,42,41,40,39,38        (UGMO9.IMG indices)
    frame_delays    = 1,4,4,4,4,4,4,4
    frame_mirror    = 0,0,0,0,0,0,0,0
    local_dx        = 0,0,-17,-7,-10,-8,-5,-4
    local_dy        = 0,0,46,68,104,128,193,234

Step 1-2, names and substitution:

    UGJUMP1, UGJUMP2, UGVICTORY1, SPIN2FLIP->UGSPIN2+X, SPIN3FLIP->UGSPIN3+X,
    SPIN4FLIP->UGSPIN4+X, SPIN5->UGSPIN5, SPIN4->UGSPIN4

Step 3, timing: `gcd(1,4,4,4,4,4,4,4)` = 1, so **sleep 1** and rows
`1,4,4,4,4,4,4,4` = **29 rows**, 29 ticks.

Step 5, offsets. Every frame is unflipped, so both axes invert:

    dX = -local_dx = 0, 0, 17, 7, 10, 8, 5, 4
    dY = -local_dy = 0, 0, -46, -68, -104, -128, -193, -234

Differenced, one per entry:

    17,-46   -10,-22   3,-36   -2,-24   -3,-65   -1,-41

which is exactly what the export prints as its `ani_adjustxy` operands.

Step 6, seat: row 0 is at offset 0 and `UGJUMP1` feet land at 222 against a
floor of 223, so no seating change - he starts on the ground and climbs 234px
to feet at -9, off the top.
