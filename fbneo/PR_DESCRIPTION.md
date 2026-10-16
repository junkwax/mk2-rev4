Added "Mortal Kombat II (rev 4.0)" (`mk2rev4`, clone of `mk2`).

A program, video and sound ROM replacement for the stock Midway T-unit board:
the same 20 chips at the same sizes, no new hardware. The driver entry is data
only - it reuses `Mk2Init`, `Mk2InputInfo` and `Mk2DIPInfo` - and is placed
after `BurnDrvMk2ute` in `src/burn/drv/midway/d_tunit.cpp`, flagged
`BDF_CLONE | BDF_HACK`.

Version string in the operator menu: `REV 4.0 (EAA637) FC`

The zip `mk2rev4.zip` (CRC32 of the zip `0xEF0AE6FE`) contains:

| file | size | crc32 |
|---|---|---|
| `mk2rev4.uj12` | 0x080000 | `fd23dd93` |
| `mk2rev4.ug12` | 0x080000 | `d40d34fd` |
| `mk2rev4.u2` | 0x080000 | `fff86ce6` |
| `mk2rev4.u3` | 0x080000 | `a5d9baa8` |
| `mk2rev4.u4` | 0x080000 | `51ef6866` |
| `mk2rev4.u5` | 0x080000 | `373de0e7` |
| `mk2rev4.u6` | 0x080000 | `b05d11bf` |
| `mk2rev4.u7` | 0x080000 | `a51de7aa` |
| `mk2rev4.ug14` | 0x100000 | `9c864f0f` |
| `mk2rev4.uj14` | 0x100000 | `3314f622` |
| `mk2rev4.ug19` | 0x100000 | `e768a4ce` |
| `mk2rev4.uj19` | 0x100000 | `04305b16` |
| `mk2rev4.ug16` | 0x100000 | `1e5325f3` |
| `mk2rev4.uj16` | 0x100000 | `8004a3b6` |
| `mk2rev4.ug20` | 0x100000 | `0c929fba` |
| `mk2rev4.uj20` | 0x100000 | `7ed4ba0d` |
| `mk2rev4.ug17` | 0x100000 | `3924479e` |
| `mk2rev4.uj17` | 0x100000 | `a1af4391` |
| `mk2rev4.ug22` | 0x100000 | `d7bd61c3` |
| `mk2rev4.uj22` | 0x100000 | `53dc6b89` |

Every chip differs from L3.1, so all 20 are in the clone zip. md5/sha1 for each
are in the attached `mk2rev4.dat`.

Notes for netplay:
- No wall clock or host-specific state is read. Coin-op by default.
- The hidden fighters (Jade, Ermac, Rain) are selectable from power-on in this
  set, because FBNeo does not load NVRAM in a netplay session.
- The unused "Comic Book Offer" DIP is BACK-BLOCK in this build (default On =
  holding away blocks; Off = block button only, as retail).
