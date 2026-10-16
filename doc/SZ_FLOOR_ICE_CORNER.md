# Sub-Zero's ground freeze in the corner (`szicecorner`)

`szicecorner .set 1` (MAINEQU.ASM) lets Sub-Zero's floor ice (Down, Back + LK)
come out against a man in the corner. `0` is retail.

## What retail did

`sz_lo_kick` (MOVES.ASM) refused the move when the victim was within `060h`
of either stage limit (`get_his_dfe`). The same rule is in the CPU's legality
check (`dzl_puddle`, MKDRONE.ASM) and carried into UMK3 unchanged
(`q_floor_ice`, MOVES.C). Neither source explains it.

## Why: the slip cannot finish against a wall

`floor_ice_hit` (MKZAP.ASM) hands the victim the puddle's two ends in
`a10`/`a11`. `r_floor_ice` (MKREACT.ASM) slides him toward the farther end at
1px a tick. **It sets the velocity once per leg** and loops until he is
within 5px of that end before turning.

In a corner the puddle reaches past the line `gravity_n_bounds` (MKDISP.ASM)
holds a fighter to (`left_edge+03ah` .. `right_edge+scrrgt-030h`). The clamp
stops him short of that end and zeroes his velocity. The leg can never
finish, so he stands still in the slip pose for the rest of the 64-80 ticks.

Measured with the fix NOPped out (see below): he slid into the wall and stood
there for **49** ticks. That happens at spots retail's refusal covers. It also
happens for **29** ticks at a spot 50px off the wall, which is OUTSIDE retail's
096px test, because that test measures from `left_edge`/`right_edge` and the
clamp sits 58/48px inside it. So retail's gate only roughly covered the bug.
That conclusion comes from the code plus the NOPped run, not from a run of the
retail ROM.

## The fix

- The edge test in `sz_lo_kick` and `dzl_puddle` compares against
  `060h*(1-szicecorner)`, which is 0 with the switch on. This is arithmetic,
  not `.if`, because MKDRONE is at GSPA's ceiling.
- `r_floor_ice` clamps `a10`/`a11` to the clamp band before the slip starts,
  under `.if szicecorner`. A wall end then equals where he will actually stop,
  so the 5px test fires and he turns at the wall. Mid-screen the clamp does
  nothing and the slip is unchanged.

Balance cost: the corner is where 64-80 helpless ticks pay off most. The
`l_pud` cooldown (`040h*3`) is unchanged.

## Rig

`tools/run_sz_floorice_corner_test.ps1 [-Package] [-Negative]` - 2P Sub-Zero
against an idle Reptile. Eight casts at pinned positions: mid-screen (two
gaps), pinned at each wall, 30px off each wall at a close gap, and 50px off.
For each cast the rig records the victim's x every slipping tick. A trial
fails if he stands still for more than 3 ticks in a row.

- Positive: 8/8 slide. In `rightwall` he turns at 1093, the wall less 5.
- `-Negative` NOPs the two clamp moves in `:maincpu`. They are located by
  their bytes, so a ROM without the fix is refused. Mid-screen and pinned at
  the wall must still pass. The four near/wall trials must STICK, and they do
  (49/49/29/29 ticks).

**Rig trap:** a victim pinned AT the wall is a useless test. He is at the
puddle's far end, his first leg goes away from the wall, and 80 ticks never
bring him back, so both ROMs measure identical. The stuck case needs his
first leg to head for the wall: a close gap with him a little off it.
