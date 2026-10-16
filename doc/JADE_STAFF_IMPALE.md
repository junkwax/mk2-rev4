# Jade's staff impale

Jade's first fatality of her own. Input: in FINISH HIM, close, **Block,
Block, Block, Forward, Block**. It is UMK3's `jade_impale` (MKFATAL.C, her
fatality #2), with her part and the victim's fall authored in
`data/JDIMPALE2.WAX`.

Kill switch: `jadeimpale` (MAINEQU.ASM), set to 1. At 0 the input does
nothing and the code stays linked.

## What happens

1. She ducks, then uppercuts him (TABLE1 `005h`, then `01ch` at UMK3's
   rate 2). He takes the hit on the contact frame: uppercut blood, camera
   shake, the monster smack, his death voice.
2. He is thrown straight up, at UMK3's `-0x100000` with no gravity and
   `0x20000` away from her. He stops once he is `01a0h` above his ground,
   which is well off the top of the screen, and hangs there for `040h`
   ticks.
3. Meanwhile she plays the WAX: the staff comes round from behind her and
   is planted vertical at her fingertips. The staff is a second object with
   its own palette.
4. **His fall is authored in the WAX** (the victim lane, slot 10). From the
   tick the lane says, he is placed frame by frame onto the staff: he falls
   from above the screen at UMK3's speeds, the staff goes through him (the
   stab sound, his death voice and UMK3's pit blood fire as his back passes
   the tip), he lands, sits 5 ticks, then slides 10 px down, 1 px every 5
   ticks, and stays. Each frame positions his ANCHOR off her anchor at the
   lane's start.

   **Every victim is drawn on his own SWEEPFALL5**, the fifth frame of his
   sweep fall (TABLE1 `016h`) counted across its part terminator
   (`jdi_sweepfall5`; knockdown part 2 is the fallback). The lane is authored
   on Kitana's `KTSWEEPFALL5` (KAT6.IMG). Each fighter's pose sits
   differently off his anchor, so the game measures his drawn box
   (`mpart_bounds`) and moves him so that its MIDDLE is on the staff and its
   TOP matches the template's. The tip then comes 16 px out of every body, as
   authored, whatever his depth; the rig confirms it on Jax, Kitana, Liu
   Kang, Kung Lao and Cage.

   **...and he stops above her hand** (`jdi_hand_gap`, MAINEQU.ASM;
   `jdi_floor_y`, MKDEATH.ASM). Matching TOPS is only as good as the
   template, and the template is a flat 31 px pose: a landing frame that
   throws a limb UP has its drawn top nowhere near the back the staff goes
   through, so the same correction walks the REST of the body on down the
   staff. Measured off the art, lowest pixel below the tip:

   | victim | pose height | below the tip | clear of her fist |
   |---|---|---|---|
   | Shang | 28 | 44 | +19 |
   | Kitana / Mileena (template) | 31 | 47 | +16 |
   | Liu Kang | 42 | 58 | +5 |
   | Baraka | 43 | 59 | +4 |
   | ninjas | 47 | 63 | 0 |
   | Cage | 49 | 65 | **−2** |
   | Kung Lao | 56 | 72 | **−9** |
   | Raiden | 62 | 78 | **−15** |
   | Jax | 63 | 79 | **−16** |

   (her fist is 63 px below the tip, so the floor is 59.)

   Jax's trailing leg and Raiden's arm came to rest BELOW JADE'S OWN FIST -
   reported as the two of them sliding way too far down the pole, which is
   exactly what it is. So the importer measures her GRIP as well as the tip
   (`grip_of`: the topmost opaque row of her last pose inside the staff's own
   three columns - the only part of her that touches it is the fingers round
   it) and emits it as `jade_impale_geom[6]`; `do_jade_impale` turns it into
   `jdi_floor_y`, `jdi_hand_gap` (4) px above it, and the victim's lineup
   refuses to put his lowest pixel past that row.

   **It lifts the whole LANE, not the rest.** The excess comes off the y
   correction, which every authored frame is placed through, so the drop
   simply starts and ends that much higher; clamping the last frame alone
   would snap him back up out of a fall he had already made. Measured after:
   nobody past the floor, the four shortest poses untouched, and the two the
   report names raised 19 and 20 px. The cost is paid at the other end - the
   tip is no longer 16 px out of a clamped victim's *box* (Jax −4, Raiden
   −3), but that box top is the limb that is thrown up, not his back, and
   over the staff's own columns the tip is still well inside him.

   `--seed-victim` rebuilds the fall and slide into the existing victim slot.
   It keeps that slot's last frame as where he rests (record, doc, mirror,
   z, depth) and only moves x, putting his middle on the staff.

   His palette is NOT changed. UMK3 makes no change there, and MK2's bloody
   palettes are painted for the impaled art, so on his knockdown pose they
   smear his skin.

   `--seed-victim` (re)writes the victim lane from UMK3's drop: his back
   starts 0e0h above the tip at `0x40000` plus `0x20000` a tick, lands on it,
   then sinks a third and then a sixth of his height. It starts at lane tick
   54, when the old code dropped him. After seeding, edit the lane in
   IMGTOOL like any other.
5. She holds her last frame with the staff up (UMK3's `wait_forever`). She
   does not play a victory.

The vertical camera is frozen (`f_noscrolly`) for the whole thing, or it
would chase him 416 px up and never settle (see
`reference_mk2_camera_y_chase`).

## The input: two queues

Block, Block, Block, Forward, Block runs across both of MK2's input queues:
the Blocks go into the button-close queue, the Forward into the stick queue,
and no single reader matches across them. `jade_block` (MOVES.ASM,
`char_block` row 16) checks it in two steps:

1. `bcom_jade_impale` through `button_look_lr` matches four Blocks (the one
   being pressed included) inside a `040h`-tick window, as Jax's Block×4 + LP
   arm rip does.
2. `jdi_forward_between` then requires the newest stick entry to be a Forward
   (`sw_right` in face-right terms) stamped between the third Block and the
   one being pressed. The timestamps are ages off `@tick`, so the timer
   wrapping doesn't break it.

It only runs in FINISH HIM, with no other button held. The rig's
`-Negative noforward` mode proves step 2 is the gate: four Blocks without the
Forward never start it.

Range: `jdi_maxdist` = `050h`, through `fatality_xfer_close`.

## The art

- **Her body**: Kitana-body frames that already exist in MKFN.ASM
  (KTROUNDKIK7/8, KTHIPUNCH1/2), plus the user's own last pose, JDIMPALE6 in
  `data/KAT49.IMG`. That pose is packed as its own section at the tail of
  `data/MOVEART2.LOD` (bank 0, because it is fighter art and the shadow reads
  it) with its table in `JDIMPAL6.TBL`. The importer generates its one-piece
  frame list, `JDIMPALE6_F`.
- **The staff**: `RODIMPALE1-7` from `data/KITANA11.IMG`, which is UMK3's
  own staff (`JDFATA2`, `ANIM_ROD_IMPALE`). It is packed in
  `data/JDROD.LOD`, a bank-1 slot at `0x9E4000..0x9E8000` at the top of
  the MK6MIL free run, hard under RAINBOLT, using 6,584 of its 16,384 bytes.
  Bank 1 is safe because the staff is a bare object that casts no shadow.
  The LOD is POF>, so `do_jade_impale` gives the object `JDROD_P` (a
  verbatim copy of the IMG's `ROD_P`) with `getfpal`. This is the same
  palette split as her victory staff: MKDISP loads one palette per object.

## The WAX is the source of truth

`tools/jade_impale_wax_import.py` writes the block between
`;>>>WAX BEGIN jade_impale` and `;<<<WAX END jade_impale` in MKFN.ASM. Its
`--check` is in Phase D. After saving the project, re-run the tool; never
edit the block. It emits:

| output | what |
|---|---|
| `a_jade_impale` | `fn3_anitab2` row `0ch`: her frames, `ani_flip` wherever the WAX's mirror state changes, and `ani_adjustxy` for each frame's offset |
| `a_jade_rod` | row `0dh`: the staff frames plus `ani_adjustxy` |
| `JDROD1-7` | one-piece frame lists for `RODIMPALE1-7` |
| `jade_impale_geom` | `[hold, tip x, tip y, staff behind her, staff start x, y, the top of her grip]` |
| `jade_impale_vic` | the victim lane: `[frames, contact, template middle x, top, mirrored]`, then per frame `[show tick, hold (0 = for good), anchor x, anchor y]` |
| `JDROD_P` | `ROD_P`, verbatim |

**Offsets.** IMGTOOL's `local_dx/dy` are ANIPOINT offsets, so a frame's
anchor sits at origin − dx when unmirrored and origin + dx when mirrored
(y is always origin − dy). The origin is her anchor where the lane starts.
`ani_adjustxy` negates x on a flipped object, so each row is the anchor's
world step multiplied by that frame's flip. This makes the lane
facing-proof.

**The staff lane opens on a frame, not a command.** `gmo_proc` builds the
object from the lane's first entry. So the staff's first offset rides in
`jade_impale_geom[4..5]` and is applied with `multi_adjust_xy` after
`match_ani_points`.

**The tip is measured, not tuned.** It is the top opaque row of the last
staff frame, taken off the art. `do_jade_impale` turns it into world
coordinates for her facing before the lane starts, and publishes it in
`jdi_tip_x/y` (with `jdi_tip_ok` once the lane has finished). The victim
lines up on it with `mpart_bounds`: his middle over the tip, his bottom
`jdi_drop_h` above it. This replaces UMK3's hand-tuned
`ochar_staff_lineups` table. He has to be aimed by his drawn body, because
a lying pose keeps the STANDING anchor about 110 px above the drawn body.

Only VISIBLE slots count: JDIMPALE2.WAX also carries hidden scratch lanes
(fan swipes, the stance cycle, UMK3's own JDIMPALE1-6), and those are skipped.
The body is one frame shorter than the staff and has `hold_end=1`, so the
importer pads it with its last frame (KTHIPUNCH3), because `double_mframew`
needs lanes of equal length. A short lane without `hold_end` is refused.
Frames resolve to the frame list that draws their pieces, so KT1VICTORY1
becomes `KT1VIC1`.

The importer refuses what the generated lane cannot express: visible
windows, motion, dual draws, per-frame z, uneven holds (`double_mframew` has
one sleep), a mirrored staff frame, and a lane that ends mirrored.

## Rig

```
tools/run_jade_impale_test.ps1 [-Victim jax|...|all] [-Side left|right|both] [-SnapEvery N] [-Negative noforward]
```

The rig taps the real input (Block ×3, Forward, Block), 8 ticks apart. It checks:

- the fatality started and Jade never left the floor;
- he went at least 416 px up;
- the staff object existed and the staff was planted;
- `death_blow_complete` ran;
- at rest, the ROM's own `mpart_bounds` has the staff running through him:
  his bottom below the tip (`jdi_rest_dy > 0`), the tip no more than 40 px
  out of his top (`jdi_rest_dt`), and his middle within 40 px of it
  (`jdi_rest_dx`);
- **and that he stopped above her hand**: his lowest pixel is not past
  `jdi_floor_y`, the row the ROM itself clamped him to. Measured: Jax and
  Raiden rest exactly on it, Kitana 12 px clear and Shang 15;
- the game leaves the fight state afterwards. Both processes end in
  `wait_forever`, and the staff object is left for round teardown.

Frames are saved to `tmp/jade_impale/<victim>_<side>/`.

## Traps hit on the way

- `stop_me` clobbers `a0`-`a3`. Called between `mpart_bounds` and using the
  bounds, it put the victim 15,000 px up.
- **`mpart_bounds` cannot measure an object above the world top.** Its bottom
  starts from a sentinel of 0 and keeps the maximum, so with every piece's
  bottom negative it answers 0. The victim is measured with his anchor
  briefly parked at y = 100h (no sleep in between).
- `create_blood_proc` takes `a7`, so the victim walks his frames by table
  pointer rather than a counter in `a7`.

## Not done

- **CPU Jade cannot do it.** `drone_finish_him` still refuses ochar >= 12,
  as it does for every added fighter.
- **No babality or friendship** for her (see `project_jade_finish_gate`).
