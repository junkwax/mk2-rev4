#!/usr/bin/env python3
"""
A TEST COPY of the Wolf set whose spare VIDEO chips carry a known pattern, so
tools/wolf_video_hi_check.lua can prove which sockets an emulator loads and in
what lane order.  The pattern is that script's: byte(i) = (i*7 + (i>>8)*13 +
(i>>16)*31) & 0xFF, i = linear video offset - 12 MB, dealt across a block's four
chips the way makewolf.py deals it (lane n -> the n-th chip named).

  --extra   the twelve sockets UMK3 leaves EMPTY (u117-u114, u109-u102,
            members mk2wolf_video_rom_uNNN): loaded only by tools/mame_wolf's
            mk2wolf.exe.  Stock MAME must FAIL this one - it is the control.

Reads rom/wolf/umk3.zip, writes tmp/wolf_video_pattern/umk3.zip; never touches
the built set.  Then:

  tools/run_wolf_boot_probe.ps1 -RomDir tmp\\wolf_video_pattern -Script wolf_video_hi_check.lua
      -Env WVH_BLOCKS=0x1000000,0x1800000,0x1C00000 -MameExe <mk2wolf.exe>
"""
import argparse
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from makewolf import EXTRA_VIDEO_BLOCKS  # noqa: E402

SRC = ROOT / "rom" / "wolf" / "umk3.zip"
OUT = ROOT / "tmp" / "wolf_video_pattern" / "umk3.zip"


def pattern_block(base):
    blk = bytearray(0x400000)
    for k in range(0x400000):
        i = base + k - 0xC00000
        blk[k] = (i * 7 + (i >> 8) * 13 + (i >> 16) * 31) & 0xFF
    return blk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extra", action="store_true", required=True)
    ap.parse_args()
    if not SRC.exists():
        print(f"make_wolf_video_pattern: {SRC} missing - run makewolf.py")
        return 1
    repl = {}
    for base, chips in EXTRA_VIDEO_BLOCKS:
        blk = pattern_block(base)
        for lane, chip in enumerate(chips):
            repl[f"mk2wolf_video_rom_{chip}.{chip}"] = bytes(blk[lane::4])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(SRC) as zi, zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zo:
        names = zi.namelist()
        missing = [n for n in repl if n not in names]
        if missing:
            print(f"make_wolf_video_pattern: {SRC} has no {missing[0]} - rerun makewolf.py")
            return 1
        for n in names:
            zo.writestr(n, repl.get(n, zi.read(n)))
    print(f"wrote {OUT} ({len(repl)} chips patterned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
