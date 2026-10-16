# Fly Pong - two fruit flies play Ed Boon's Pong

A separate ROM that is nothing but MK2's hidden Pong (`src/PONG.ASM`), first to 99,
match after match, with each paddle played by one fly brain. Built for streaming; the
normal game and the R2V2 demo build are untouched.

## The ROM

`pong_only .set 1` in `src/MKAMODE.ASM` (it is `0` in the tree - flip it, build, flip it
back). `amode` then creates `pong_only_proc` instead of attract mode, which loops
`play_pong` and clears up between matches the way MAIN.ASM does after the secret match.

- `pong_win` (PONG.ASM, `.bss`): points to win. 0 = Ed Boon's 7, so the in-game secret
  match is unchanged. `pong_only_win` (99) sets it. The score display has two digits, so 99
  is the ceiling.
- `pong_reset`: with it set, every point puts the ball back to its opening speed and
  restarts the speed-up clock (`pong_point_reset`). Ed Boon's 7-point match speeds the ball
  up six times over the first ~70 s of the MATCH and holds it at 2x. Its vertical speed then
  reaches 4.7 px/tick against a paddle that moves 3, so in a race to 99 most of every match
  was physically unplayable. `pong_only_reset .set 0` restores his rule.
- **The score counts to 99** (`stp3`, PONG.ASM). Ed Boon's `digit_table` held the finished
  14-segment pattern for scores 0-15 only - enough for first-to-7 - so from 16 on the board
  read past the table and drew garbage (seen on the stream once the scores reached the
  teens). `stp3` now splits the number into tens and ones and looks each up in
  `seg7_table`, his own per-digit patterns, leading zero kept. Proved by seeding the scores
  at 38/86 and snapshotting real points to 40/89; the old ROM draws 20/17 as broken shapes.
  The frozen ROM with this is `C:/tmp/flybrain/pong_rom_v3`.
- **The ball quickens on every return** (`pong_hit_quicken`, needs `pong_reset`): the three
  speeds each hit copies onto the ball go up 3% per return, to a cap of 1.5x the serve speed
  (the user asked for it gentle), and `pong_point_reset` puts them back for the next serve.
  Measured on a rally: 3.50, 3.61, 3.71 ... 5.14, 5.30 and it holds there; every new point
  starts at 3.50 again. Ed Boon's timed speed-up (`speed_up_ball`) dies at once in this
  build so the two do not stack; his own 7-point match never sets `pong_reset` and keeps it.
  The frozen ROM is `C:/tmp/flybrain/pong_rom_v4`.
- **FROSTY says so when he scores** (`pong_frosty`, PONG.ASM; needs `pong_reset`). The left
  paddle's point sends `tsound 0102h`, MKSOUND's row 102, which now plays
  `sound/FROSTY_UMK3.dcs` (0.80 s; the row's busy time is 44 ticks) from VPDEATH's
  reclaimed tracks `$0373-$0375` - `sound/stlaugh_patch.txt` note (57). Measured in MAME
  off the sound port: 7 left-paddle points, 7 sends of `$0373`, each in the scoring tick; 12
  right-paddle points, none. The ROM's sound chips are the Frosty set byte for byte apart
  from crc_spoof's 4-byte window. Frozen ROM `C:/tmp/flybrain/pong_rom_v5`.
- **`pong_only_proc` sets `gstate` to `gs_pfsetup` before anything else.** In `gs_amode`,
  joystick Down is "show the rankings" (`p1_joydown`/`p2_joydown`, MKINIT.ASM), which tore
  the court down the first time a fly steered down. Measured: paddles frozen at y 204/254
  with the ball off the court at 0-0. In any other state with nobody `ps_active`, the switch
  processes die in `p1_die_check`, and Pong reads `@switch` itself.

Build (announce in `tmp/session/TOOLCHAIN`):

```
# pong_only .set 1, then:
python build.py --asm-only && python makerom.py
python mamerom.py --source-video --no-install --output C:\tmp\flybrain\pong_rom_v2\mk2.zip
copy src\mk2.map C:\tmp\flybrain\pong_rom_v2\
# pong_only .set 0, then rebuild the normal tree
```

## The rig - `tools/flypong.lua`

**RAM.** Only `pong_win` and `pong_reset` are exported. The rest of PONG.ASM's `.bss`
follows `pong_win` in declaration order:

| Variable | Address |
|---|---|
| scores | `pong_win - 32`, `- 16` |
| ball | `+16` |
| `bxv` | `+48` |
| `byv` | `+80` |
| `play1` | `+112` |
| `play2` | `+144` |

**`.bss` is packed at BIT granularity, so none of these is word-aligned.** `pong_win`
itself sits 8 bits into a word, and a plain `read_u16` returns the value shifted by 8 (99
read as 25344). Every read goes through `rbits`.

**Each fly is the stream's own circuit.** `flynet_oa.lua` has 768 cells, and each fly keeps
its own membrane potentials:

- **Looming:** the ball coming at the fly drives LC4/LC6 by how fast its angular size grows
  and LPLC2/LPLC1 by how big it is. LC11 tracks it as a small moving object.
- **Eyes:** the fly faces across the court, so "above my paddle" is its LEFT eye.
- **Motion and sound:** vertical drift is wide-field flow (HS/H2/VS), and the paddle blip
  reaches the ear (JO-B/D).
- **Steering:** DNa01/DNa02 lean the choice up or down.

Measured, the circuit points at the ball unprompted: the lean is about +0.3 with the ball
above and -0.8 with it below.

**The learner** keeps a situation table with options UP / HOLD / DOWN, picked in proportion
to w^SHARP:

- **Situation key:** coming or going, which of 7 height buckets the ball is in against the
  paddle, drift direction, and distance.
- **Rewards:** a hit rewards the recent choices, weighted by how recently each was made. A
  miss carries the side the ball went past: moving toward that side is rewarded, moving away
  is punished, and holding is mildly punished.
- **Without the miss side**, a miss punished every choice alike. The fly that fell behind
  punished its good moves as hard as its bad ones and got worse: 38% to 6% hit rate over
  three matches.

**Fair:** both flies see the court `FP_REACT` frames late (8 = 146 ms) and decide every 3
frames. They move only through the joystick, at the ROM's 3 px a tick, and both start blank.

## Running it

```
.\tools\run_flypong.ps1 -MaxMinutes 60                 # fast, invisible training
.\tools\run_flypong_stream.ps1 -Fresh                  # the stream: window + page, restarts itself
python tools\flypong_dashboard.py --state <out>\pong.json   # the page alone, http://localhost:8778
```

The page reads `<out>/pong.json`, which the rig writes every 3 frames. It shows:

- the score;
- the court, with the ball where the flies SEE it (one reaction time ago);
- per fly: what its eyes report, its steering neurons, the situation in words, its choice
  odds, hit rate and last miss;
- **each fly's brain**: the fighting fly's anatomy view, every cell body at its MaleCNS
  position (`C:/tmp/flybrain/atlas.json`, `/atlas`), the circuit's cells lit in that fly's
  colour as they fire, and the traffic along the synapses of the firing ones. The rig writes
  the connectome once beside the state file (`pong.net.json`, `/net`) and then only the
  loudest 200 cells per fly as `[index, level]` pairs;
- the learning curve and rally lengths.

**The moments**: the rig publishes an `events` list - a record rally (and the record being
broken live), rally milestones from 20 hits in tens, match point, a match won - and the
court view pops each one up for ~2.5 s, keeps the last three in a ticker under the court,
and shows the live rally count with the record over the court. The subtitle says whether
the flies started blank or from saved brains, and how many points they have played.

**Every section has its own link**, for OBS, the same way as the fighting fly's dashboard:
click any section's heading, or open `/?view=score|court|left|right|brains|brainleft|brainright|learn|rallies`
(the bare `/court` form works too). Each fills the window and its text grows with it.
Add `?bare=1` for a transparent background.

Brains are saved to `<out>/brains.lua` at every match end and every 50 points.
`run_flypong_stream.ps1` restarts MAME on them, and `-Fresh` sets the old ones aside.
**It stops relaunching if the window is closed three times inside a minute**, or when
`<out>\STOP` exists.

**Nothing is ever typed at the window.** `mame_dismiss_warning.ps1` (what other rigs use for
MAME's ROM-warning screen) brings MAME to the front and injects Enter/Space as REAL key
presses every half second for up to three minutes, and that took the user's keyboard while
the stream ran. The window instead runs with `-debug -debugger none -debugscript go.ds`:
MAME skips its startup screens whenever the debugger is on, the debugger stays hidden, and
`go` starts the machine. Measured at 100% speed. (It also skips them for `-video none` and
for `-seconds_to_run` under 300, which is why every headless and short test passed while
the real stream sat on the warning, unanswerable, with the page showing yesterday's state.)

**MAME reads no keyboard, mouse or joystick** (`-keyboardprovider none` and the rest): the
flies drive the paddles through Lua's `set_value`, which does not need a provider. With the
`win32` provider the stream window took the keyboard whenever it had focus.

## The aim sense (FP_AIM, on by default)

**The flies plateaued without it.** An 8-hour self-play run (`C:/tmp/flybrain/pong_bg`,
121 matches) was at ~68% returns from its first hour to its last, and its rallies got
SHORTER: 2.9 hits on average over matches 4-13, 2.1 over 94-103. Both flies had met all 85
situations the table can tell apart within the first match; after that, learning only
reshuffled the same 85 entries. The table knew where the ball WAS (seven height bands), its
drift and its distance, and nothing about where it would ARRIVE, which is the read that
matters once the ball comes off a wall.

**With aim**, while the ball is coming the height band is the ball's ARRIVAL point at the
fly's own paddle line, against the paddle's centre. It is worked out from the same late
picture the fly always had (position and velocity), with the wall bounces folded in
(`move_ball` reflects the ball's top edge between y 9 and 241). So it is the same
information, only put together, and both flies get it. The eyes, the circuit and the
steering lean still run on where the ball is now.

Measured, an hour from blank, two seeds each (`C:/tmp/flybrain/pong_ab`, `compare.py`):

| Run | Returns, first to last quarter | Average rally | Best rally | Matches |
|---|---|---|---|---|
| aim 101 | 83% -> 87% | 5.4 -> 7.3 | 38 | 6 |
| aim 202 | 83% -> 83% | 5.5 -> 5.2 | 38 | 7 |
| now 101 | 69% -> 76% | 2.3 -> 3.4 | 22 | 13 |
| now 202 | 73% -> 79% | 3.1 -> 4.1 | 32 | 10 |

Aim learns almost at once and then levels off. A fresh "now" run beat the 8-hour one, so
**self-play past a point wears the table down** rather than building it up - worth knowing
before leaving a stream on for hours. `-NoAim` is the old fly.

## The weight ceiling scales the whole situation (2026-10-05)

The table's weights were clamped one option at a time at 50. Any option that kept being
rewarded piled up against the ceiling, and once two sat there the fly could no longer tell
them apart - seen live on the stream page: a ball far above, **UP 50 / DOWN 50**, chosen
54% / 46%. That is the likeliest reason self-play wore the table down over hours. Now when
an option passes 50, all three options of that situation are divided by the same factor:
the ratios (what was learned) survive and the numbers stay bounded. `-Clamp` (`FP_CLAMP=1`)
is the old rule. A six-hour comparison, two seeds per rule, is in `C:/tmp/flybrain/pong_long`
(`python C:/tmp/flybrain/pong_ab/compare.py C:/tmp/flybrain/pong_long`).
