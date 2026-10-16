# `mk2_court` - the hidden copyright / security-test screen

Retail's attract loop calls `mk2_court` straight after `midway_presents`
(MKAMODE.ASM, `amode_loop`). The leak has the call and the `.global`, but not
the routine, so this tree carries a one-instruction stub
([src/MKAMODE.ASM](../src/MKAMODE.ASM), `mk2_court` = `retp`) and the call is
commented out.

**It is not an attract-mode screen.** It is a hidden screen that only appears
while a secret two-player button combination is held, and it reports whether
the board passes Midway's security test. With no combination held it returns
on its first tick, so the stub loses nothing a normal player ever saw.

Everything below was read out of the retail L3.1 set (`mk2.zip` in the repo
root): the call was located in the program ROM, the routine disassembled with
MAME's `unidasm`, and the art it draws decoded from the video ROM. Nothing in
the tree was changed.

## Where it is in retail

| Thing | Retail address | Program ROM offset |
|---|---|---|
| `amode_loop`'s run of `jsrp`s | - | `0x8620` |
| `midway_presents` | `FF847980` | - |
| **`mk2_court`** | **`FFA1D970`** | **`0x43B2E`** |
| image table (3 entries + terminator) | `FFA1E0C0` | - |
| obfuscated-call trampoline | `FF964E10` | `0x2C9C2` |
| second trampoline | `FFA1D690` | `0x43AD2` |
| code checksum | `FF905190` | `0x20A32` |

The routine sits next to the ladder and high-score code, not next to
MKAMODE. `MAINEQU.ASM` lists it under `* mkbug.asm`
(`.global system_lockup,dpystrt,mk2_court`), so it belonged in MKBUG.ASM and
was cut from that file with the rest of the security code.

How the call was found: a `jsrp` assembles to a fixed ten bytes
(`47 01 07 0b 60 00 ec a2 80 c0`) followed by the 32-bit target. Retail has
1,199 of them; the twelve consecutive ones at `0x8620` are `amode_loop`, and
the second target is `mk2_court`.

## What the routine does

1. **Polls for the combination, once a tick, for `0x140` ticks (about 5.8 s).**
   Both switch ports are read and inverted. If either compare fails on any
   tick it jumps to the exit (`mmfm a12,a7` / `exgpc a7`, i.e. `retp`).
2. **Clears the screen** and draws three images from the table.
3. **Runs the security test.** `a5` starts as `failed`. It becomes `passed`
   only if all three of these succeed:
   - a call through the trampoline at `FF964E10`, whose own address is hidden
     (`movi 0FE164E10h,a14` / `addi 01800000h,a14` / `jump a14`) and which
     jumps to `a8 + 3BFA0h`;
   - a call through the second trampoline at `FFA1D690` (`a8 + 0E9D30h`);
   - the checksum at `FF905190`, which sums words over two code regions into
     `a8` and must leave a fixed constant.
4. **Draws the verdict**, sleeps another `0x140` ticks, clears, returns.

### The combination

All of these at once, for the whole window:

| Port | Test | Meaning |
|---|---|---|
| `switch` (`01600000h`) | `~switch & 247F7Fh == 6131h` | P1: stick bit 0 + High Punch + Block. P2: stick bit 0 + Block + High Kick. Every other stick/button bit in the mask released, including bits 18 and 21. |
| `switch2` (`01600020h`) | `~switch2 & 33h == 21h` | P1 Low Punch held, P2 Low Kick held; P1 Low Kick and P2 Low Punch released. |

Stick bit 0 is Up: `b_jdown` is bit 1 in MAINEQU.ASM. Bits 18 and 21 were
not identified.

### The screen

| Image | Size | Position | Reads |
|---|---|---|---|
| `mk2copyrgt` | 162x46 | x 120, y 48 | THIS IS / MORTAL KOMBAT II / COPYRIGHT 1993 / MIDWAY MANUFACTURING COMPANY |
| `thisver` | 93x8 | x 128, y 144 | THIS VERSION |
| `passed` / `failed` | 46x8 / 45x8 | y 167 | PASSED / FAILED |
| `thesectest` | 123x8 | x 128, y 192 | THE SECURITY TEST |

So it reads "THIS VERSION PASSED THE SECURITY TEST" or "... FAILED ...".

The name is probably literal - a screen Midway could bring up on a seized
board as evidence in court. That is an inference; nothing in the source says
so.

## What is still in the tree

The code is missing; the data is not.

- [src/MKCOPY.TBL](../src/MKCOPY.TBL) - the five headers, 1bpp (`01000H`),
  palette `copy_p`.
- [src/MKBUG.ASM](../src/MKBUG.ASM) line 28 - `.include mkcopy.tbl`, so the
  headers are linked.
- `data/MKCOPY.IMG`, packed by [data/MK6MIL.LOD](../data/MK6MIL.LOD)
  (`ASM> mkcopy.tbl`, `---> mk2copyrgt,thisver,thesectest,passed,failed`),
  bank 1.
- `copy_p` in [src/IMGPAL6.ASM](../src/IMGPAL6.ASM).

Nothing draws any of it.

## Options

- **Leave the stub (current state).** No player-visible difference from
  retail. The five images stay packed in bank 1 unused.
- **Rebuild the display half.** About 40 instructions from the disassembly:
  the poll loop, the three-entry table, the verdict object. The verdict itself
  cannot be honestly rebuilt - it calls the security process that was never in
  the leak (`secbust_proc` is a stub here) and compares a checksum constant
  specific to the retail link - so it would have to be hardwired or left out.
- **Reclaim the art.** Drop the MKCOPY section from `MK6MIL.LOD` and the
  include from MKBUG.ASM to get the bank-1 bytes back.

## Reproducing the findings

```
# deinterleave the retail program ROM (uj12 = even bytes, ug12 = odd)
# then:
unidasm flat.bin -arch tms34010 -basepc 0xffa1d970 -skip 0x43B2E
```

The art decodes from the retail video chips at bank-1 offset
`0x800000 + (SAG - 04000000h) / 8`, one bit per pixel, with each row padded
to a multiple of 4 pixels. SAGs are in `src/MKCOPY.TBL`.
