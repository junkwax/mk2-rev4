#!/usr/bin/env python3
"""
makesound.py -- regenerate the patched DCS sound set (sound/mk2_stlaugh.zip)
from sound/stlaugh_patch.txt using DCSEncoder --patch mode.

This is the ONLY step that turns the sound patch script + source clips into
the mk2_stlaugh.zip that mamerom.py installs. The rest of the build pipeline
(build.py / makerom.py / makevrom.py) does NOT touch it, so after editing
stlaugh_patch.txt or any source clip you MUST run this (or the full pipeline
below) before packaging, or the ROM keeps the previous custom audio.

Recommended full pipeline (from repo root):
    python build.py && python makerom.py && python makevrom.py \
        && python makesound.py && python mamerom.py --source-video

DCSEncoder.exe lives in the DCSExplorer repo, not here. This script searches
the usual locations; override with --encoder <path> if it moved.
"""

import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
SOUND_DIR = SCRIPT_DIR / "sound"
PATCH_SCRIPT = SOUND_DIR / "stlaugh_patch.txt"
OUTPUT_ZIP = SOUND_DIR / "mk2_stlaugh.zip"
RETAIL_ZIP = SCRIPT_DIR / "mk2.zip"          # prototype/retail source ROM set

# Candidate DCSEncoder.exe locations (first existing wins).
ENCODER_CANDIDATES = [
    Path("c:/Users/you/Workplace/DCSExplorer/x64/Release/DCSEncoder.exe"),
    Path("c:/Users/you/Workplace/DCSExplorer/x64/Debug/DCSEncoder.exe"),
]


def find_encoder(override):
    if override:
        p = Path(override)
        if not p.exists():
            print(f"Error: --encoder path not found: {p}")
            sys.exit(1)
        return p
    for c in ENCODER_CANDIDATES:
        if c.exists():
            return c
    print("Error: DCSEncoder.exe not found in known locations:")
    for c in ENCODER_CANDIDATES:
        print(f"    {c}")
    print("Pass --encoder <path> to point at it.")
    sys.exit(1)


def referenced_stream_files():
    """Every source clip named by a `stream Name "file" [(params)];` line in the patch."""
    import re
    files = []
    for line in PATCH_SCRIPT.read_text(encoding="utf-8").splitlines():
        # the optional (name=value, ...) list is per-stream encoder params
        m = re.match(r'\s*stream\s+\w+\s+"([^"]+)"\s*(?:\([^)]*\))?\s*;', line)
        if m:
            files.append(SOUND_DIR / m.group(1))
    return files


def is_stale():
    """True if the patch script or any referenced clip is newer than the zip."""
    if not OUTPUT_ZIP.exists():
        return True
    zip_mtime = OUTPUT_ZIP.stat().st_mtime_ns
    inputs = [PATCH_SCRIPT] + referenced_stream_files()
    for f in inputs:
        if f.exists() and f.stat().st_mtime_ns > zip_mtime:
            return True
    return False


def main():
    argv = sys.argv[1:]
    override = None
    if "--encoder" in argv:
        i = argv.index("--encoder")
        override = argv[i + 1] if i + 1 < len(argv) else None
    check_only = "--check" in argv

    if not PATCH_SCRIPT.exists():
        print(f"Error: {PATCH_SCRIPT} not found")
        sys.exit(1)
    if not RETAIL_ZIP.exists():
        print(f"Error: prototype ROM {RETAIL_ZIP} not found")
        sys.exit(1)

    if check_only:
        if is_stale():
            print(f"STALE: {OUTPUT_ZIP.name} is older than the patch script/clips."
                  f" Run 'python makesound.py'.")
            sys.exit(1)
        print(f"OK: {OUTPUT_ZIP.name} is current.")
        return

    encoder = find_encoder(override)
    cmd = [str(encoder), "--patch", "--rom-prefix=*", "--rom-size=*",
           f"--stream-dir={SOUND_DIR}", "-o", str(OUTPUT_ZIP),
           str(RETAIL_ZIP), str(PATCH_SCRIPT)]
    print(f"Encoding patched sound set with {encoder.name} ...")
    result = subprocess.run(cmd, cwd=str(SOUND_DIR))
    if result.returncode != 0:
        print(f"Error: DCSEncoder failed (exit {result.returncode})")
        sys.exit(result.returncode)

    # Guard against the phantom-U8 overflow (7th chip does not exist on real
    # MK2 hardware and is dropped by mamerom.py's SOUND_ROMS map).
    import zipfile
    with zipfile.ZipFile(OUTPUT_ZIP) as z:
        u8 = [n for n in z.namelist() if "_u8" in n.lower() or n.lower().endswith("u8")]
    if u8:
        print("\n*** WARNING: DCSEncoder spilled into a phantom U8 chip "
              f"({', '.join(u8)}). This does NOT exist on real hardware and "
              "will be dropped on install. Reclaim more dead audio (no-op a "
              "confirmed-unused slot in stlaugh_patch.txt) and re-run.")
        sys.exit(2)

    print(f"\nWrote {OUTPUT_ZIP}")


if __name__ == "__main__":
    main()
