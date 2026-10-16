# Mortal Kombat II — Rev 4.0 (T-unit)

A rebuild of Midway's 1993 arcade *Mortal Kombat II* for the stock Williams/Midway
**T-unit** board, with new moves, new fatalities, restored cut content, new and
restored stages, a competitive ruleset and a stronger CPU. This is the build
submitted to **FBNeo / Fightcade** as the set `mk2rev4` (clone of `mk2`).

> **What this repository is (and is not).** It holds only the work done for
> this project: documentation, the build/analysis/test tooling, the project's
> own hand-written modules, the FBNeo driver entry, and **binary patches**.
> It contains **no Midway/Warner Bros. source code, art, audio or ROM data**,
> and none of the TI TMS34010 toolchain. To play it you need your own copy of
> the retail `mk2` ROM set; the patches turn it into `mk2rev4`.

Snapshot: source commit `b2f2f233`, version string `REV 4.0 (EAA637) FC`.

## Play it

```
python patch/apply_patch.py path/to/mk2.zip          # -> mk2rev4.zip
```

Input is the standard MAME/FBNeo `mk2` set (program L3.1, video + sound L1).
Retail chips are found by SHA-1, and all 20 output chips are checked against
[`patch/CHIPS.tsv`](patch/CHIPS.tsv), so a wrong dump is refused rather than
producing a broken set. Needs only Python 3.8+.

There are three patches (~3 MB) - program, video, sound - each against the
*flat* image rather than a single chip, because moved art shifts the chips'
byte interleave. Sprites live at bit addresses, so the video patch is made
against the retail image plus seven bit-shifted copies of it
([`patch/romsets.py`](patch/romsets.py)). The files are valid BPS, but use
`apply_patch.py` rather than a generic patcher. `make_bps.py` regenerates them.

Copy `mk2rev4.zip` into your FBNeo/Fightcade `roms` folder; the
driver entry is in [`fbneo/`](fbneo/).

The game runs unchanged on FBNeo's existing `mk2` hardware code — same 20
chips at the same sizes, no new hardware. Notes for netplay, DIP switches and
the set itself are in [`fbneo/README.txt`](fbneo/README.txt).

## What changed

Highlights (full detail in [`doc/`](doc/) — start with
[`doc/ENGINEERING_NOTES.md`](doc/ENGINEERING_NOTES.md), the project's running
build and behaviour notes, and [`doc/CHANGELOG.md`](doc/CHANGELOG.md)):

**Built from source.** Program, video and sound ROMs are all rebuilt from the
1993 source with the original DOS toolchain under DOSBox; the source-built video
ROMs matched retail L3.1 byte for byte before any art changed.

**Ruleset**
- Juggle damage scaling, UMK3-style combo counting and a combo counter
- Back-block (DIP switch: MAME's unused "Comic Book Offer"), perfect block
- First tie of a match draws, the next is SUDDEN DEATH on 10% bars
- Throws go through damage scaling; Jax's multi-slam diminishes
- Anti-juggle separation fixes (Liu Kang's fireball, teleports out of a push-back)

**Fighters**
- Hidden fighters Jade, Ermac and Rain playable (unlocked from
  power-on in this Fightcade cut — FBNeo keeps no NVRAM in netplay)
- Rain: lightning bolt, storm cloud hold, super roundhouse, lightning fatality
- Liu Kang double knee, Kitana's two-way fan decapitation, Jade's staff impale,
  Mileena's sai split, Shang Tsung's elbow chain and a morph into Rain,
  Scorpion's forward teleport, Smoke's own harpoon, Kung Lao's angled and
  returning hat, Noob's dive kick, and more
- Costume lanes on every Start+button combo, authored in one palette library;
  two players never wear the same costume; Raiden's lightning matches his costume
- Kintaro: air grab, face smash, spinning backhand, get-up kick; Shao Kahn's
  soul rip, hammer glass crack, and stone-creep ending

**Stages** — MK1's Pit, Warrior Shrine and Throne Room (with Shang Tsung
watching and applauding), MK3's Cave, Dead Pool hanging bodies and acid drops,
Yoteigai Tor stage fatality, Kahn's Arena heat haze, and others.

**CPU** — uses its own moves and fatalities, jump-in punches, fixes to a
reboot in its jump-in logic, boss punish logic.

## Repository layout

| Path | Contents |
|---|---|
| `patch/` | `mk2rev4_{program,video,sound}.bps` (retail → rev 4.0), `CHIPS.tsv` (SHA-1s), `apply_patch.py`, `make_bps.py` |
| `fbneo/` | FBNeo/Fightcade driver entry, diffs against `d_tunit.cpp`, Logiqx `.dat`, submission notes |
| `doc/` | Design notes, investigations and findings for every feature; `doc/graphics_opportunities/` |
| `tools/` | ~320 Python tools (generators, importers, `--check` build guards, analysis) and ~830 MAME Lua / PowerShell test rigs |
| `*.py` (root) | Build pipeline: `build.py`, `makerom.py`, `makevrom.py`, `makesound.py`, `mamerom.py`, `burnfix.py`, editors (`hitbox_edit.py`, `frame_edit.py`, `combo_edit.py`), `sym_resolve.py` |
| `asm/` | TMS34010 modules written from scratch by this project (they `.include` the game's headers and do not assemble on their own) |
| `data/*.WAX`, `*.WVP` | IMGTOOL world/preview projects: authored fatality and move timing/placement (text, no pixel data) |

## Rebuilding from source

The tools here expect the full source tree, art and the TI toolchain, none of
which are distributed. They are published so the work is documented and
reproducible by anyone who already has those materials. The pipeline is:

```
python build.py && python makerom.py && python makevrom.py && python makesound.py && python mamerom.py
python tools/make_fightcade_set.py      # the FBNeo cut (hidden fighters unlocked)
```

Many tools and rigs contain absolute Windows paths from the original machine
(`C:\Users\you\Workplace\mk2-main`, `C:\MAME`); adjust to your layout.

## Legal

*Mortal Kombat* is a trademark of Warner Bros. Entertainment Inc. This is an
unofficial, non-commercial fan project with no affiliation with Warner Bros.,
NetherRealm Studios or Midway. No copyrighted game data is included; you must
own the original ROMs to use the patches.
