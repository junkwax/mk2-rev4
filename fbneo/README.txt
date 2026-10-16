Mortal Kombat II (rev 4.0)
FBNeo set: mk2rev4  (clone of mk2, BDF_HACK)
Version string in the operator menu: REV 4.0 (EAA637) FC
Source commit: b2f2f233

WHAT IT IS
  Mortal Kombat II L3.1 rebuilt from Midway's leaked source with new
  moves, fatalities, a competitive ruleset (juggle damage scaling, combo
  counting, back-block, perfect block, sudden death) and a stronger CPU.
  It is a program + video + sound ROM replacement for the STOCK T-unit
  board: the same 20 chips at the same sizes, no new hardware, no extra
  regions. It runs on FBNeo's existing mk2 hardware code unchanged -
  Mk2Init, Mk2InputInfo, Mk2DIPInfo - so the driver entry is data only.

FILES
  mk2rev4.zip             the clone set (every chip differs from retail,
                         so all 20 are in it, named mk2rev4.<chip>)
  mk2rev4_standalone.zip  identical content; kept for symmetry with
                         future builds that share chips with the parent
  fbneo_mk2rev4.cpp       BurnRomInfo + BurnDriver, to place after
                         BurnDrvMk2ute in src/burn/drv/midway/d_tunit.cpp
  fbneo_d_tunit.patch     the same as a diff against upstream d_tunit.cpp
  mk2rev4.dat             Logiqx XML entry (crc/md5/sha1)
  SHA256SUMS.txt          checksums of every file here

ROMS
  mk2rev4.uj12     524288  crc fd23dd93  sha1 6b9a07166b50796e82863068ef14837498592808
  mk2rev4.ug12     524288  crc d40d34fd  sha1 afe49e506a0f989785ca30d1b5c9d5227032ee60
  mk2rev4.u2       524288  crc fff86ce6  sha1 9912cc81ff2ca2b0a80b0dbe881c7cf1f77cf515
  mk2rev4.u3       524288  crc a5d9baa8  sha1 30ba2e364eb6b3ef85ad33e5abb0e36ace4c67ad
  mk2rev4.u4       524288  crc 51ef6866  sha1 6ea6d6bbf9ed00e00ce952c6126bb0ed8698fd40
  mk2rev4.u5       524288  crc 373de0e7  sha1 a98eb3cf50fb3776429e6e12e85b8875ffcefca5
  mk2rev4.u6       524288  crc b05d11bf  sha1 bb19cb3adb2d36c44552f257a35b75aef595c668
  mk2rev4.u7       524288  crc a51de7aa  sha1 9a6dd45179230c81a2a5f597ed49d1394d828586
  mk2rev4.ug14    1048576  crc 9c864f0f  sha1 c310cb2711f1bf5030ddc9372a39a32f6e91b674
  mk2rev4.uj14    1048576  crc 3314f622  sha1 1ca8da30ae49b0945e8560f790e7c22ed963a87f
  mk2rev4.ug19    1048576  crc e768a4ce  sha1 69c47a4556e6184b9086af922b69050cf4debb3c
  mk2rev4.uj19    1048576  crc 04305b16  sha1 d601b461501a1ffb10912165f8062ffdf4a2b350
  mk2rev4.ug16    1048576  crc 1e5325f3  sha1 3e1307c5d7241f52a26c28760711e0ca0a073d8e
  mk2rev4.uj16    1048576  crc 8004a3b6  sha1 5252b786b843cf8b608293ae9c039106e69ed882
  mk2rev4.ug20    1048576  crc 0c929fba  sha1 19c7e86254f8f8574666391fc706d6f9ffc937a9
  mk2rev4.uj20    1048576  crc 7ed4ba0d  sha1 74167ec3323e1059e96e9d47f6a85800f9448ef7
  mk2rev4.ug17    1048576  crc 3924479e  sha1 1f5078406122e1ea2816e34f24a5597040740faa
  mk2rev4.uj17    1048576  crc a1af4391  sha1 fe4d5d5099b42e5ba1cb24800078624f2b2c5787
  mk2rev4.ug22    1048576  crc d7bd61c3  sha1 d24d400ea8f19331dac205fa759b627039c9d6af
  mk2rev4.uj22    1048576  crc 53dc6b89  sha1 60035420f9cd7dc808af4695e0ac575248253ba0

DIP SWITCHES
  Uses the stock Mk2DIPList. One switch has a new meaning: the unused
  "Comic Book Offer" switch (0x21 bit 0x08) is BACK-BLOCK in this build -
  On (the FBNeo default) = holding away from the opponent blocks; Off =
  block button only, as retail. "Powerup Test" should stay Off (default).

NETPLAY NOTES
  * Deterministic: no wall clock, no host-specific state; random numbers
    come from the game's own generator.
  * Coin-op by default. Insert coins as on any arcade set.
  * FBNeo does not load NVRAM during a netplay session, so the game starts
    each online session on factory CMOS defaults on both sides.
  * Hidden fighters (Jade, Ermac, Rain): selectable from power-on in this build - the
    arcade build earns them in 1P and saves that to CMOS, which FBNeo
    does not keep across a netplay session, so this cut unlocks them.

CONTACT / PERMISSION
  <name, contact, and a statement that the author agrees to the set being
   included in FBNeo and Fightcade>
