# Reptile's acid spit — the UMK3 green projectile, out of the arcade ROM

> **This started life as a hunt for Ermac's fireball and found the wrong
> asset.** Ermac's fireball is the projectile **Shao Kahn** throws, and MK2
> already carries it as `BGSPEAR1-13` / `a_sk_spear` / `stk_sk_spear` — nothing
> needs importing for that move. What is documented below is genuinely Reptile's
> **acid spit**: correctly located, correctly decoded and proved, just not the
> move that was being looked for. It is kept because the extraction is sound and
> the structural map of UMK3's tables in it is reusable.

Everything below came out of `C:\MAME\roms\umk3.zip`. Nothing is from a
movelist, a wiki, or memory. Re-derive it any time with:

```
python tools/umk3_ermac_fireball_extract.py                    # the report
python tools/umk3_ermac_fireball_extract.py --verify           # the decode proof
python tools/umk3_ermac_fireball_extract.py --render tmp/ermac # + PNG sheets
python tools/umk3_ermac_fireball_extract.py --tbl              # MK2 .TBL shape
```

Nothing here is currently being ported. The value is the table map and the
decode method.

## The roster, and two corrections to `UMK3_ERMAC_TELESLAM.md`

`character_anitabs1` is at byte `0x60572` and is **26 entries, not 15**;
`character_anitabs2` follows immediately at `0x605da` with 26 more. The index is
the **character**, and the ground truth for the ordering is the 26-entry
`"<NAME> WINS"` pointer array at `0x33cc2`:

| | | | |
|---|---|---|---|
| 0 KANO | 7 SEKTOR | 14 SMOKE (robot) | 21 CLASSIC SUB-ZERO |
| 1 SONYA | 8 CYRAX | 15 KITANA | 22 HUMAN SMOKE |
| 2 JAX | 9 KUNG LAO | 16 JADE | 23 NOOB SAIBOT |
| 3 NIGHTWOLF | 10 KABAL | 17 MILEENA | 24 MOTARO |
| 4 SUB-ZERO | 11 SHEEVA | 18 SCORPION | 25 SHAO KAHN |
| 5 STRYKER | 12 SHANG TSUNG | 19 REPTILE | |
| 6 SINDEL | 13 LIU KANG | **20 ERMAC** | |

That ordering is what makes every shared table make sense, which is why it is
safe to build on: slots **7/8/14** share one table (the three cyborgs),
**15/16/17** share one (the three female ninjas — and 16's anitab2 is `0x22fb4`,
exactly the `lia_anitab2` `tools/umk3_jade_extract.py` already relies on), and
**18–23** share one (the six male ninjas).

So:

1. `UMK3_ERMAC_TELESLAM.md` calls body 7 "male ninja". Body 7 is **SEKTOR**. The
   male ninjas are 18–23, and their anitab1 is `0x26b46`, not `0x13f74`.
2. It says the table has 15 entries. It has 26.

**Neither breaks the shipped teleport-slam.** `--check-teleslam` re-derives the
row-`0x44` hold offsets for all 26 bodies and they are byte-identical
everywhere — `(−24,−131) (10,−128) (36,−109) (10,−128)` — so reading them off
Sektor gave the same numbers the real ninja carries. The label was wrong, the
port was not.

## Where the acid spit lives

`male_ninja_anitab2` is `0x26c6a`, 19 slots, shared by all six male ninjas.
Eighteen slots are body art. Slot **`0x07`** is the projectile, and two
independent things say so:

1. Its frames point **straight at image records** for an 11×10 sprite, not at
   the 120px-tall body art every other slot uses.
2. It ends in `ani_jump` back to its own head — it **loops**. That is the shape
   a projectile-in-flight lane has, and it is the same shape `ANIM_BOOMERANG`
   (`lia_anitab2[4]`) has in the Jade extraction.

It is the only lane in the table with either property.

Slot `0x06`'s `ani_sladd` slave carries a second art block that shares the
projectile's palette, so the two are one move — a long beam that breaks up into
droplets, presumably the launch/impact half.

## The art

Thirteen records, `0x9c08c` onward. The first four are the flight loop; the rest
are the dissipation the lane plays once the loop breaks.

| name | W×H | byte | anix | aniy | SAG | ctrl |
|---|---|---|---|---|---|---|
| ACIDGLOB1 | 11×10 | `0x9c08c` | −12 | −3 | `06bff030h` | `4000h` |
| ACIDGLOB2 | 9×11 | `0x9c09e` | −14 | −2 | `06bff1e8h` | `4000h` |
| ACIDGLOB3 | 11×10 | `0x9c0ac` | −12 | −3 | `06bff374h` | `4000h` |
| ACIDGLOB4 | 13×6 | `0x9c0ba` | −11 | −5 | `06bff52ch` | `4000h` |
| ACIDSPLAT1 | 19×9 | `0x9c0c8` | −8 | −1 | `06bff664h` | `4080h` |
| ACIDSPLAT2 | 33×11 | `0x9c0d6` | 0 | 0 | `06bff8a4h` | `4580h` |
| ACIDSPLAT3 | 33×7 | `0x9c0e4` | 0 | −4 | `06bffc88h` | `4180h` |
| ACIDSPLAT4 | 33×5 | `0x9c0f2` | 0 | −6 | `06bfff60h` | `4080h` |
| ACIDSPLAT5 | 23×5 | `0x9c100` | −6 | −6 | `06c001cch` | `4080h` |
| ACIDSPLAT6 | 21×4 | `0x9c10e` | −7 | −7 | `06c00370h` | `4080h` |
| ACIDSPLAT7 | 17×4 | `0x9c11c` | −9 | −7 | `06c004a4h` | `4080h` |
| ACIDSPLAT8 | 13×3 | `0x9c12a` | −12 | −8 | `06c005a0h` | `4000h` |
| ACIDSPLAT9 | 8×3 | `0x9c138` | −15 | −8 | `06c0063ch` | `4000h` |

The SAGs above are **UMK3's**. They are recorded so the extraction can be
re-run, not so they can be pasted into our source — our art gets re-cut into our
own video ROM and gets our own SAGs, the same way every other import has.

## The palette, and the 18-byte record gap

Image records are 7 words / 14 bytes, but the gap from the first record to the
second is **18**. The extra long is an inline palette pointer — which is how the
palette was found rather than guessed:

```
0x9c08c  record   11x10 ...
0x9c09a  .long    0ffdb6bc0h        -> palette at byte 0xb6d78, 16 entries
0x9c09e  record    9x11 ...
```

`0xb6d78` is 16 entries — exactly 4bpp — and it is a green-to-hot-yellow ramp
(the acid):

| | | | |
|---|---|---|---|
| 0 `#6A6A94` (transparent) | 4 `#399C00` | 8 `#ACDE00` | 12 `#FFDE5A` |
| 1 `#006200` | 5 `#52AC00` | 9 `#D5EE00` | 13 `#F6DE8B` |
| 2 `#007300` | 6 `#6ABD00` | 10 `#FFFF00` | 14 `#EEE6BD` |
| 3 `#298B00` | 7 `#8BCD00` | 11 `#FFEE29` | 15 `#E6E6E6` |

Index 0 is the transparent slot, so its stored colour never reaches the screen.
The same palette pointer appears again at `0x9bfe0`, at the head of slot `0x06`'s
block, and that shared pointer is what ties the two blocks into one move.

## Why the decode is trustworthy

The control word's top nibble is the bit depth (4/5/6 here), and for an
**uncompressed** frame (control bit 7 clear) the next frame's SAG has to be
exactly `w*h*bpp` bits further on. Every uncompressed frame in the block
satisfies that on the nose — 440, 396, 440, 312 and 156 bits — so the record
layout, the bit depth and the SAG base are all confirmed rather than assumed.
`--verify` re-runs the check and exits non-zero if it ever stops holding.

## Damage

All six male ninjas share **one** strike table at `0x5e4f8` (27 entries), so each
ninja's specials sit at different indexes in it. Which index the fireball handler
passes lives in TMS34010 code, and this extraction does not disassemble — so the
index is **inferred, not proven**. It is a strong inference, though: the ball's
widest frame is 33×11, and exactly one row in the whole table has a box that
shape.

| idx | box | at | routine | damage |
|---|---|---|---|---|
| `0x19` | 34×9 | (109, 58) | `07701h` | **20 on hit / 3 on block** |

Hit reaction `0x77`, block reaction `0x01`. UMK3's full health is `0a6h` (166)
against MK2's `0a1h` (161), so damage carries over at about 0.97:1 — near enough
to 1:1 that 20/3 can be used directly.

## What is NOT recoverable from the data

The **tick rate** and the **flight velocity** are set by the caller in code, not
stored in the lane — the same limitation `UMK3_ERMAC_TELESLAM.md` hit, for the
same reason. Nothing in the ROM's data section carries them. They have to be
chosen against MK2's own projectiles and then tuned on screen; MK2's existing
`set_proj_vel` speeds are the right reference, and the Jade import landed on
`0090000h` (9 px/tick) at 2 ticks per frame for a comparable projectile.

The **victim reaction** does not need importing at all. MK2 already has projectile
hit reactions, and the sensible thing is to reuse the one Reptile's force ball
and Sub-Zero's ice blast already drive rather than port UMK3 reaction `0x77`.

## Attribution

The male ninjas share their anitab2, their anitab1 and their strike table, so the
ROM's **data** cannot say on its own which of the six throws this — the
per-character difference is in the handler code. It is **Reptile's acid spit**:
the ball is a small green glob and the slot-`0x06` block is a long spray that
breaks into droplets and splashes, which is what the spit does and is not what a
force ball or a fireball does.

This is exactly the limit worth remembering: shared tables mean the data locates
the *asset* but never the *owner*. Owner attribution needs the handler code or a
look in MAME.
