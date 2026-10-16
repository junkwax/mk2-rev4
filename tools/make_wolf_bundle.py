#!/usr/bin/env python3
"""make_wolf_bundle.py - a Wolf build that plays its own audio for ANYONE.

THE PROBLEM.  The Wolf set uses all eight sound sockets (u2-u9, 8 MB): MK1's
stage music fills u6-u9 (doc/WOLF_SPACE.md "Sound").  Stock MAME's `umk3`
driver loads only u2-u5, and a DCS address in u6+ WRAPS onto u2 with no error,
so a tester on stock MAME hears the wrong audio and nothing says why.  No
repack can fix that: the audio is ~8 MB and stock MAME has room for 4.

THE FIX.  Ship the patched single-driver MAME (tools/mame_wolf, `mk2wolf.exe`)
WITH the set.  This writes dist/mk2wolf_bundle/ and dist/mk2wolf_bundle.zip:

    mk2wolf.exe          stripped (only Windows system DLLs - portable)
    roms/umk3.zip        rom/wolf/umk3.zip (makewolf.py's output)
    PLAY.bat             mk2wolf umk3 -rompath roms ...
    README.txt           what it is, why stock MAME sounds wrong
    source/              umk3_u6u9.patch + where MAME's source is (GPL-2.0)

    python tools/make_wolf_bundle.py
    python tools/make_wolf_bundle.py --mame C:\\path\\mk2wolf.exe --no-zip
"""
import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEF_MAME = Path(r"C:\Users\you\Workplace\mame-src\mk2wolf.exe")
STRIP = Path(r"C:\msys64\mingw64\bin\strip.exe")
MAME_TAG = "mame0287"

README = """MORTAL KOMBAT II - Wolf build ({stamp})
==========================================

Double-click PLAY.bat.  When MAME shows the red "wrong checksums" box, press
any key - that box is expected (this is a source-built ROM set).

USE THE mk2wolf.exe IN THIS FOLDER, NOT YOUR OWN MAME.
The game's audio fills all eight sound sockets of the Wolf (UMK3) sound board.
Stock MAME's umk3 driver only loads four of them, and a sound stored in the
other four silently plays as garbage from the first four - no error, the audio
is just wrong.  mk2wolf.exe is MAME {ver} with one change: its umk3 driver
loads all eight sound sockets, and the twelve VIDEO sockets UMK3 leaves empty
(u102-u109, u114-u117), which this set may put art in.  It runs only the
Midway Wolf games.

On real hardware: burn all eight sound chips (u2-u9) from roms/umk3.zip, and
every mk2wolf_video_rom_uNNN chip that is not blank (FF).

Controls are MAME's defaults (Tab opens the menu).  Settings and saves go to
cfg/ and nvram/ next to this file.

source/ holds the patch and where MAME's source lives (MAME is GPL-2.0).
"""

PLAY = (
    "@echo off\r\n"
    "cd /d \"%~dp0\"\r\n"
    "start \"\" mk2wolf.exe umk3 -rompath roms -cfg_directory cfg "
    "-nvram_directory nvram -snapshot_directory snap -skip_gameinfo -video d3d\r\n"
)

SOURCE_NOTE = """mk2wolf.exe is MAME {ver} (https://github.com/mamedev/mame, tag {tag}),
licensed GPL-2.0-or-later, built with umk3_u6u9.patch applied and nothing else:

    git clone --depth 1 --branch {tag} https://github.com/mamedev/mame
    cd mame && git apply umk3_u6u9.patch
    make SUBTARGET=mk2wolf SOURCES=src/mame/midway/midwunit.cpp TOOLS=0

The patch doubles the umk3 "dcs" region to 16 MB and loads u6-u9 at
800000h-E00000h, and loads video sockets u117-u114 at 1000000h and
u109-u102 at 1800000h-1C00000h of the existing 32 MB "video" region.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mame", type=Path, default=DEF_MAME)
    ap.add_argument("--rom", type=Path, default=ROOT / "rom" / "wolf" / "umk3.zip")
    ap.add_argument("--out", type=Path, default=ROOT / "dist" / "mk2wolf_bundle")
    ap.add_argument("--no-zip", action="store_true")
    a = ap.parse_args()

    if not a.mame.exists():
        sys.exit(f"{a.mame} not found - build it per tools/mame_wolf/README.md")
    if not a.rom.exists():
        sys.exit(f"{a.rom} not found - run makewolf.py first")
    out_obj = ROOT / "tmp" / "wolf" / "src" / "mk2.out"
    if out_obj.exists() and out_obj.stat().st_mtime > a.rom.stat().st_mtime:
        sys.exit(f"{a.rom} is older than {out_obj} - re-run makewolf.py")
    with zipfile.ZipFile(a.rom) as z:
        names = {n.lower() for n in z.namelist()}
    for u in range(6, 10):
        if not any(f"_u{u}." in n or n.endswith(f".u{u}") for n in names):
            sys.exit(f"{a.rom} has no u{u} sound chip - this is not a u2-u9 set")

    if a.out.exists():
        shutil.rmtree(a.out)
    (a.out / "roms").mkdir(parents=True)
    (a.out / "source").mkdir()
    exe = a.out / "mk2wolf.exe"
    shutil.copy2(a.mame, exe)
    if STRIP.exists():
        subprocess.run([str(STRIP), "--strip-all", str(exe)], check=True)
    shutil.copy2(a.rom, a.out / "roms" / "umk3.zip")
    shutil.copy2(ROOT / "tools" / "mame_wolf" / "umk3_u6u9.patch", a.out / "source")
    ver = MAME_TAG.replace("mame0", "0.")
    stamp = ""
    asm = (ROOT / "src" / "DIAGMENU.ASM").read_text(errors="replace")
    for line in asm.splitlines():
        if "REVISION" in line and ".string" in line.lower():
            stamp = line.split('"')[1] if '"' in line else ""
            break
    (a.out / "README.txt").write_text(README.format(ver=ver, stamp=stamp or "Wolf"), newline="\r\n")
    (a.out / "PLAY.bat").write_bytes(PLAY.encode())
    (a.out / "source" / "SOURCE.txt").write_text(SOURCE_NOTE.format(ver=ver, tag=MAME_TAG), newline="\r\n")

    mb = exe.stat().st_size / 1e6
    print(f"wrote {a.out}  (mk2wolf.exe {mb:.1f} MB)")
    if not a.no_zip:
        zp = a.out.with_suffix(".zip")
        if zp.exists():
            zp.unlink()
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(a.out.rglob("*")):
                if p.is_file():
                    z.write(p, Path(a.out.name) / p.relative_to(a.out))
        print(f"wrote {zp}  ({zp.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
