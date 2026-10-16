# MK1: Shang Tsung defeated - the souls escape

What MK1 plays when you beat Shang Tsung, pulled out of the arcade ROM
(`C:\MAME\roms\mk.zip`, rev 5.0 T-unit), with the art, the lanes and the timings.

```
python tools/mk1_shang_souls_extract.py            # static, from mk.zip -> tmp/mk1_shang_souls/
tools/run_mk1_shang_defeat_capture.ps1             # live MAME capture (automatic, ~2 min),
                                                   #   then the extractor + capture.gif
```

The extractor needs nothing but `mk.zip`. It writes one transparent PNG per
frame (all frames of an animation on one canvas, one anchor, so they play back
in place), a strip and a GIF per animation at the game's own speed, `sheet.png`,
`sequence.txt` and `lanes.json` (every frame down to its pieces, SAGs and
anipoints). Every timing it prints is read from an instruction immediate in
MK1's routine, after checking the opcode, so another ROM revision fails instead
of guessing.

## What happens

`t` is in game ticks (54.7068 Hz, 18.28 ms), from the moment `gstate` becomes
`0Bh`. The ~ times are from the capture; the durations are from the code.

| t | what | where it comes from |
|---|------|---------------------|
| 0 | Final blow. He lost wearing **Goro** (Shang had morphed), 6 screen flashes, 4 ticks on / 4 off | `FFDD2990` |
| ~50 | He morphs back: his Goro-morph lane **reversed**, 4 ticks a frame | Shang entry 14 |
| ~62 | He **shakes**: `69FF0 6A110 6A230 6A110`, 4 ticks each, x +7 / -7 alternating every step; the doorway flashes | entry 20, `FFDD2EE0`, `FFDD3C80` |
| ~50 on | **A soul every 27 ticks**, alternating sides, cycling Sonya, Sub-Zero, Scorpion, Liu Kang, Raiden, Kano, Johnny Cage, then round again | `FFDD31F0` |
| per soul | A stance copy of Shang, drifting 2-5 px/tick, 8 ticks, with that fighter's scream | `FFDD39B0`, `FFDB8190` |
| | Shang's morph lane into that fighter, 3 frames x 6 ticks | entry `7+char` via `FFD75550` |
| | It stops and *is* the fighter: stagger (`41h`, 4 frames x 4) then knockdown (`2Ah` @3), sound `B1h` | the fighter's own table |
| | **Scorpion's toasty flame** at -128,-24 burns it away, 5 ticks a frame; the soul is deleted under it | ninja `18h` / `1Fh`, `FFDD3E60` |
| ~370 | After 320 ticks of souls: flashes again, souls cleared | `FFDD2760` |
| ~418 | He **collapses**: entry 15, two parts at 4 ticks, then lies there (entry 17) | `FFD77360` |
| ~570 | "YOU HAVE DEFEATED SHANG TSUNG", "YOU ARE THE SUPREME MORTAL KOMBAT WARRIOR", the ending | |

The soul is the whole trick: MK1 does not have a "soul" sprite. Each one is a
fresh Shang object that runs Shang's ordinary **morph** lane for the next fighter
on the list and then the fighter's ordinary **hit reactions**, and the fire is
Scorpion's fatality flame with the build-up skipped (`addi 0E0h,a9` - seven
lane entries). Nothing in the sequence is art made for it except Shang's shake
and collapse frames.

The soul matching the human's own fighter wears that fighter's **mirror-match**
palette (`PAL_ALT`, `FFC83AC0`), because it is the second of that character on
screen; `--player <ochar>` reproduces it, and the capture wrapper passes it
through.

## The trigger

At the end of a match the game picks the winner by comparing `@1051330` with
`@1051610` (per-player counters, cleared at game start), and if the human won
it asks `FFCA2C60` for the next ladder entry. `FFFFh` - the end of the ladder,
which only ever follows Shang - branches (`FFCA0880`, or `FFCA0C50` on a second
path) to `FFCA53C0`: `gstate = 0Bh`, sound `0Fh`, `JA FFDD2160`.

`FFDD2160` flashes the screen, waits for the winner to stop moving, and starts
a process on Shang's object at `FFDD2D70`, which creates the soul spawner
(`FFDD31F0`, pid `3001h`) and - because his `ochar` is 8 - shakes him. The
doorway flash (`FFDD3C80`) runs alongside. 320 ticks later the spawner is
killed, the screen flashes again, and Shang's process is sent to `FFD77360`:
the collapse.

## Reading MK1 - what is different from MK2

* **Image record**: `.word W,H,anix,aniy / .long SAG` - **no control word**.
  The first record of a group carries a `.long palette` too (16 bytes, not 12).
* **Every sprite is 6bpp, uncompressed.** 10,678 records chain SAG to SAG at
  exactly `W*H*6` bits; no other bpp matches a single pair.
* **SAG is absolute** (`0x02000000` based). Video ROM is three groups of four
  512K chips, `ug14/uj14/ug19/uj19`, `ug16/uj16/ug20/uj20`, `ug17/uj17/ug22/uj22`,
  4-way byte interleaved - MK2's layout at half the size.
* **Field sizes are reversed**: field 0 is 16 bits, field 1 is 32. So
  `MOVE @1051A10h,A0,0` reads a word.
* A **frame** is a 0-terminated list of image pointers; each piece lands at
  `anchor - (anix, aniy)`, as in MK2. A **lane** is a list of frames with
  commands: 0 end of part, 1 jump, 2 flip, 3 adjust x (`.word`), 4 adjust x,y
  (`.word,.word`), 5 frame without sleep, 6 calla. The current frame lives at
  `*A8(220h)`.
* An object's **palette** is the `.long` in its first piece's record
  (`*A0(60h)`) - which is how the morph lanes' `calla FFD6C3F0` sets theirs -
  or, for a fighter, `PAL_PRIMARY[ochar]` at `FFC839A0`.

| | |
|---|---|
| `FFCE4AA0` | `get_char_ani`: `a9 = anitab[*a8(260h)][a9]` |
| `FFCE4B90` | anim-table list by ochar: 0 Cage, 1 Kano, 2 Raiden, 3 Liu Kang, 4/5 the ninjas (one table), 6 Sonya, 7 Goro, **8 Shang = `FFD68D10`** |
| `FFCB30E0` | ladder slot -> ochar, per human character: slots 0-5 the others, 6 Goro, **7 Shang**, 8 mirror |
| `FFCB2C60` | the four ladders; every one has slot 7 at position 14, then `FFFFh` |
| `FFC839A0` / `FFC83AC0` | primary / mirror-match palette by ochar |
| `FFDB8190` | per-character soul scream |

Shang's 21-entry table, for what was identified: 0 stance, 1-2 walks, 4 an
8-piece flame object (a piece list, not a lane), 5 the flaming-skull fireball,
6 his victory (arms up in flame - played by the victory dispatcher at
`FFDF24E0`), **7-14 morph into ochar 0-7**, 15/17 collapse and lie, 18-20 the
shake. The throne Shang who claps in the Courtyard is separate art, driven
from `FFD6E660`.

How the anchors were established, in order: Shang's palette is `FFE9FFB0`
(62 of 64 colours equal to our dev-era `data/MK1SHANG.IMG`); only one image
block uses it; the only table pointing into that block is `FFD68D10`; the only
list pointing at that is `FFCE4B90`, read by `FFCE4AA0`. The defeat routine is
the one place that tests `ochar == 8` and then asks for index 20 (`14h`).
`data/MK1SHANG.IMG`'s own frame sizes match nothing in the ROM - it was re-cut,
like `MK1SKULL.IMG` (see `tools/mk1_flame_timing_probe.lua`) - so do not anchor
on it.

## The capture, and three traps

`tools/mk1_shang_defeat_capture.lua` plays the game to this point with no input:
it forces ladder position 14 until Shang is picked, pins P1's health, holds
Shang's at 1 while P1 walks in punching, and records from `gstate 0Bh` on: a
snapshot per frame, every blit off the DMA registers (`blits.log`), and colour
RAM slots 0-15 (`cram.bin`). Shang falls on the same frame every run.

MK1 RAM it relies on (bit addresses; `space:read/write` take them as-is):
`gstate @1051190`, ladder pointer `@10519F0`, ladder position `@1051A10`,
P1/P2 ochar `@1051290`/`@1051570`, P1/P2 health `@1051300`/`@10515E0` (max
`0A1h`), the match-winner counters `@1051330`/`@1051610`, player objects
`@1051230`/`@1051510`.

1. **The tower screen scrolls forever at position 14.** It scrolls to the rung
   for the current position and Shang's position has no normal rung. Show it
   position 0, then put 14 back when the fight starts - the end-of-match check
   reads `table[pos+1]`.
2. **The DMA tap goes silent.** `install_write_tap` returns a passthrough
   handler; nothing referenced it, GC collected it before the Shang fight, and
   the first capture logged zero blits. It is pinned in a global now.
3. **A fresh nvram boots to "CMOS INVALID - FACTORY SETTINGS RESTORED"**, which
   eats the first coin. The rig presses HP at frame 600 and retries coin/start
   until the select screen appears.

The capture is also the proof for the extractor: a frame rebuilt from nothing
but `blits.log`, the ROM and `cram.bin` matches MAME's snapshot on every
sprite, and every object's colour RAM equals the ROM palette the extractor
derives for it (the Kano soul included, once `--player` is honoured).
