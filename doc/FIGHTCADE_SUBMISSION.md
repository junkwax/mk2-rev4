# Submitting the T-unit build to Fightcade

Fightcade runs arcade games on its own fork of FBNeo and lists a game only if
that fork has a driver entry for it. Getting the build in therefore means
getting a **driver entry into FBNeo** under the build's own set name. Upstream
FBNeo already carries MK2 hacks this way (`mk2ute`, `mk2p`, `mk2chal` in
`src/burn/drv/midway/d_tunit.cpp`). Once the entry is there, ask Fightcade
to pick it up and open a channel for it.

## Why `rom/mk2.zip` cannot be submitted

`mamerom.py` CRC-spoofs every chip to retail's CRC, so FBNeo's own `mk2`
driver accepts the build *as* Midway's L3.1. A set that answers to `mk2`
collides with the real game, and nobody can tell the two apart. A submission
must be a clone under its own name, with real CRCs.
`tools/make_fightcade_set.py` builds exactly that.

## Make the packet

```
python build.py && python makerom.py && python makevrom.py && python makesound.py && python mamerom.py --source-video
python tools/make_fightcade_set.py --release --fbneo-src <upstream d_tunit.cpp>
```

Output goes to `dist/fightcade/mk2rev4/`: the clone zip, the driver block plus
a diff against upstream, a Logiqx `.dat` with crc/md5/sha1, a reviewer
`README.txt`, `BUILD_INFO.txt` and `SHA256SUMS.txt`. Before writing anything,
the packager checks that every video and sound chip equals the set installed
in `rom/mk2.zip` except for crc_spoof's 4 bytes. The program ROM is the
Fightcade cut (decision 1), built from the same source with one switch
changed.

`--release` refuses a `PLAYTEST` version string and a dirty tree (and, with
`--as-played`, `hidearn` on).

## Decisions before a release cut

1. **Hidden fighters are unlocked in the Fightcade cut only - done.** FBNeo
   never loads NVRAM in a netplay session (`DrvInit`,
   `src/burner/win32/drv.cpp`: `if (kNetGame) ... else StatedAuto(0)`), so
   every online session starts on factory CMOS. Fighters that must be EARNED
   into CMOS could never be picked there. So the packager does not use rom/'s
   program ROM. It copies `src/` to `tmp/fightcade/`, sets `hidearn 0` in the
   copy, and assembles + links it there, giving Jade, Ermac and Rain from
   power-on. Your `src/`, `rom/` and the arcade/MAME build are untouched and
   still earn them. It also appends " FC" to the version string when that fits
   in 29 characters. The PLAYTEST string is too long, so the tag only appears
   once PLAYTEST is dropped. Use `--as-played` to package rom/'s program
   instead. Proven 2026-10-14 with `tools/ermac_start_toggle_test.lua` on a
   private, factory-blank nvram. On the cut: Jade, Ermac and Rain all come out
   on a START tap (Jade failed one first run, then passed toggle and leave).
   On the arcade build, the control: Ermac and Rain stay locked.
2. **Version string.** Drop `PLAYTEST` from `rom_name` (`src/DIAGMENU.ASM`;
   `bump.py`), commit, then build from the clean tree.
3. **Set name and title.** The defaults are `mk2rev4` and
   "Mortal Kombat II (Rev 4.0, hack)". Change them with `--set` / `--title`.
   Each future release needs a new set name, because the CRCs change with
   every build.
4. **Known issue.** The round-hand-off freeze (2026-10-02, release notes
   "Known issues") is the kind of thing a netplay audience will hit. Decide
   whether to ship with it.
5. **Permission line.** Fill in the CONTACT / PERMISSION block of
   `README.txt`.

## Verify in FBNeo before sending

The driver entry is data only: it reuses `Mk2Init`, `Mk2InputInfo` and
`Mk2DIPInfo`. Even so, build FBNeo with the patch
(`~/Downloads/build-fbneo-windows.ps1`) and check these on `mk2rev4`:

- the set loads
- the single bong at boot
- a full 2P match
- the back-block DIP behaves
- a netplay session against yourself

The bytes already run under FBNeo's `mk2` driver as the spoofed set.
**This packet has not yet been run under its own name.**

## Send it

1. Open a PR to `finalburnneo/FBNeo` with `fbneo_d_tunit.patch`. The PR
   description is `README.txt`. Attach or link the zip; the maintainers check
   the CRCs.
2. After it merges, ask Fightcade (their Discord) to add `mk2rev4` to their
   FBNeo fork and open a channel for it.

This route is our reading of how other hacks reached Fightcade. Neither
project documents it, so confirm on the FBNeo issue tracker or the Fightcade
Discord first.
