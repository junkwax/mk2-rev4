#!/usr/bin/env python3
"""
Package MK2 ROMs into a MAME-compatible mk2.zip.

Usage:
    python mamerom.py                                       # source program+video; sound from
                                                            # sound/mk2_stlaugh.zip (patched, has
                                                            # STLAUGH) if present, else retail
                                                            # sound from rom/mk2_retail.zip
    python mamerom.py --full-source-sound                   # source program+video+sound
                                                            # (sound ROMs won't match retail)
    python mamerom.py --no-install                          # write retail to rom/mk2.zip
                                                            # or test to rom/test/mk2.zip
    python mamerom.py --install-test                        # write/use rom/test/mk2.zip
    python mamerom.py path/to/retail_mk2.zip                # our program, retail video+sound
    python mamerom.py path/to/retail_mk2.zip --source-video # our program+video, retail sound
                                                            # (recommended: fewest CRC warnings
                                                            # when retail zip is a clean L3.1 dump)

Our LOAD2 pipeline with Asure's flags produces video ROMs that match retail L3.1
byte-for-byte. Use --source-video to prefer our build over the retail zip's video
ROMs (useful when the retail zip is a mixed/modified dump).
"""
import sys
import shutil
import zipfile
import re
from pathlib import Path

MAIN_MAME_DIR = Path("C:/MAME/roms")

# Sound ROMs (from sound/ directory — PLBUILD-generated, CRCs won't match retail)
SOUND_ROMS = {
    "U2.ROM": "l1_mortal_kombat_ii_sound_rom_u2.u2",
    "U3.ROM": "l1_mortal_kombat_ii_sound_rom_u3.u3",
    "U4.ROM": "l1_mortal_kombat_ii_sound_rom_u4.u4",
    "U5.ROM": "l1_mortal_kombat_ii_sound_rom_u5.u5",
    "U6.ROM": "l1_mortal_kombat_ii_sound_rom_u6.u6",
    "U7.ROM": "l1_mortal_kombat_ii_sound_rom_u7.u7",
}

# Program ROMs (from makerom.py output)
PROGRAM_ROMS = {
    "mk2_uj12.bin": "l3.1_mortal_kombat_ii_game_rom_uj12.uj12",
    "mk2_ug12.bin": "l3.1_mortal_kombat_ii_game_rom_ug12.ug12",
}

# Video ROMs (from makevrom.py output, already MAME-named)
VIDEO_ROM_NAMES = [
    "l1_mortal_kombat_ii_game_rom_ug14.ug14",
    "l1_mortal_kombat_ii_game_rom_uj14.uj14",
    "l1_mortal_kombat_ii_game_rom_ug19.ug19",
    "l1_mortal_kombat_ii_game_rom_uj19.uj19",
    "l1_mortal_kombat_ii_game_rom_ug16.ug16",
    "l1_mortal_kombat_ii_game_rom_uj16.uj16",
    "l1_mortal_kombat_ii_game_rom_ug20.ug20",
    "l1_mortal_kombat_ii_game_rom_uj20.uj20",
    "l1_mortal_kombat_ii_game_rom_ug17.ug17",
    "l1_mortal_kombat_ii_game_rom_uj17.uj17",
    "l1_mortal_kombat_ii_game_rom_ug22.ug22",
    "l1_mortal_kombat_ii_game_rom_uj22.uj22",
]

# Every IRW that makevrom.py writes into the video-ROM chips.  Packaging a
# freshly linked program against video chips made before one of these payloads
# was regenerated gives valid CRCs but corrupted sprites at runtime.
ACTIVE_VIDEO_IRWS = [
    "MK2MIL.IRW", "MK3MIL.IRW", "MK4MIL.IRW", "MK5MIL.IRW",
    "MK6MIL.IRW", "MK7MIL.IRW", "MOVEART2.IRW", "MOVEART1.IRW",
    "SHAOSIT.IRW", "SCLAP.IRW", "KITSPIN.IRW", "GOROWALK.IRW",
    "FLAPJACK.IRW", "JADERANG.IRW",
]


def load_program_roms(rom_dir):
    """Load our built program ROMs. Returns dict of mame_name -> bytes."""
    result = {}
    for src_name, mame_name in PROGRAM_ROMS.items():
        path = rom_dir / src_name
        if not path.exists():
            print(f"  ERROR: {src_name} not found — run 'python makerom.py' first")
            sys.exit(1)
        result[mame_name] = path.read_bytes()
    return result


def require_fresh_source_video(script_dir, rom_dir):
    """Refuse to package source video chips older than their LOAD2 inputs."""
    irw_paths = [script_dir / "data" / name for name in ACTIVE_VIDEO_IRWS]
    missing_irws = [path.name for path in irw_paths if not path.exists()]
    if missing_irws:
        print("  ERROR: active video IRW(s) missing — run 'python build.py' first:")
        for name in missing_irws:
            print(f"    {name}")
        sys.exit(1)

    chip_paths = [rom_dir / name for name in VIDEO_ROM_NAMES]
    missing_chips = [path.name for path in chip_paths if not path.exists()]
    if missing_chips:
        print("  ERROR: source video ROM chip(s) missing — run 'python makevrom.py' first")
        sys.exit(1)

    newest_irw = max(irw_paths, key=lambda path: path.stat().st_mtime_ns)
    oldest_chip = min(chip_paths, key=lambda path: path.stat().st_mtime_ns)
    if newest_irw.stat().st_mtime_ns > oldest_chip.stat().st_mtime_ns:
        print("  ERROR: source video ROM chips are stale relative to LOAD2 output.")
        print(f"    newest IRW: {newest_irw.relative_to(script_dir)}")
        print(f"    oldest chip: {oldest_chip.relative_to(script_dir)}")
        print("    Run 'python makevrom.py' before packaging with mamerom.py.")
        sys.exit(1)


def source_test_mode_enabled(script_dir):
    """Return True when MKAMODE.ASM is currently patched for test boot."""
    path = script_dir / "src" / "MKAMODE.ASM"
    try:
        text = path.read_text(encoding="latin-1")
    except OSError:
        return False
    m = re.search(r"^test_mode\s+\.set\s+(\d+)", text, re.MULTILINE)
    return bool(m and int(m.group(1)) != 0)


def is_video_rom(name):
    return any(n in name.lower() for n in ("ug14","uj14","ug19","uj19","ug16","uj16",
                                           "ug20","uj20","ug17","uj17","ug22","uj22"))


def is_program_rom(name):
    return "uj12" in name.lower() or "ug12" in name.lower()


def write_merge_mode(output, retail_zip, program_roms, rom_dir, source_video=False):
    """Merge mode: take retail zip, replace program ROMs. Optionally replace video too."""
    if source_video:
        print(f"Merge mode (sound-only): using {retail_zip.name} for SOUND, our build for PROGRAM+VIDEO.\n")
    else:
        print(f"Merge mode: using {retail_zip.name} for video/sound, our build for program.\n")

    # Load our source-built video ROMs if requested
    video_roms = {}
    if source_video:
        require_fresh_source_video(Path(__file__).parent.resolve(), rom_dir)
        for vname in [
            "l1_mortal_kombat_ii_game_rom_ug14.ug14", "l1_mortal_kombat_ii_game_rom_uj14.uj14",
            "l1_mortal_kombat_ii_game_rom_ug19.ug19", "l1_mortal_kombat_ii_game_rom_uj19.uj19",
            "l1_mortal_kombat_ii_game_rom_ug16.ug16", "l1_mortal_kombat_ii_game_rom_uj16.uj16",
            "l1_mortal_kombat_ii_game_rom_ug20.ug20", "l1_mortal_kombat_ii_game_rom_uj20.uj20",
            "l1_mortal_kombat_ii_game_rom_ug17.ug17", "l1_mortal_kombat_ii_game_rom_uj17.uj17",
            "l1_mortal_kombat_ii_game_rom_ug22.ug22", "l1_mortal_kombat_ii_game_rom_uj22.uj22",
        ]:
            path = rom_dir / vname
            if not path.exists():
                print(f"  ERROR: {vname} not found — run 'python makevrom.py' first")
                sys.exit(1)
            video_roms[vname] = path.read_bytes()

    replaced, kept = [], []

    with zipfile.ZipFile(retail_zip, "r") as src:
        with zipfile.ZipFile(output, "w", zipfile.ZIP_STORED) as dst:
            for item in src.namelist():
                if is_program_rom(item) or (source_video and is_video_rom(item)):
                    replaced.append(item)
                    continue
                dst.writestr(item, src.read(item))
                kept.append(item)

            for mame_name, data in program_roms.items():
                dst.writestr(mame_name, data)
            for mame_name, data in video_roms.items():
                dst.writestr(mame_name, data)

    print(f"Replaced with source-built:")
    for name in replaced:
        print(f"  - {name}")
    for name in list(program_roms) + list(video_roms):
        size = len(program_roms.get(name) or video_roms.get(name))
        print(f"  + {name}  ({size:,d} bytes)")

    print(f"\nKept from {retail_zip.name} ({len(kept)} ROMs):")
    for name in kept:
        print(f"  = {name}")


def write_full_source_mode(output, rom_dir, sound_dir):
    """Full source mode: package everything we built from source."""
    print("Full source mode: packaging source-built program + video + sound.")
    print("NOTE: graphics may be garbled (video ROM layout != original TBL pointers)\n")

    require_fresh_source_video(Path(__file__).parent.resolve(), rom_dir)
    missing = []
    with zipfile.ZipFile(output, "w", zipfile.ZIP_STORED) as zf:
        print("Program ROMs:")
        for src_name, mame_name in PROGRAM_ROMS.items():
            path = rom_dir / src_name
            if path.exists():
                zf.writestr(mame_name, path.read_bytes())
                print(f"  + {mame_name} ({path.stat().st_size:,d} bytes)")
            else:
                missing.append(src_name)
                print(f"  MISSING: {src_name} — run 'python makerom.py'")

        print("\nVideo ROMs:")
        for mame_name in VIDEO_ROM_NAMES:
            path = rom_dir / mame_name
            if path.exists():
                zf.writestr(mame_name, path.read_bytes())
                print(f"  + {mame_name} ({path.stat().st_size:,d} bytes)")
            else:
                missing.append(mame_name)
                print(f"  MISSING: {mame_name} — run 'python makevrom.py'")

        print("\nSound ROMs:")
        for src_name, mame_name in SOUND_ROMS.items():
            path = sound_dir / src_name
            if path.exists():
                zf.writestr(mame_name, path.read_bytes())
                print(f"  + {mame_name} ({path.stat().st_size:,d} bytes)")
            else:
                missing.append(src_name)
                print(f"  MISSING: {src_name}")

    if missing:
        print(f"\nWARNING: {len(missing)} ROM(s) missing")


def main():
    script_dir = Path(__file__).parent.resolve()
    rom_dir = script_dir / "rom"
    sound_dir = script_dir / "sound"

    # Parse --output <path> (allows build_all.py to direct output without side effects)
    argv = sys.argv[1:]
    output_override = None
    filtered = []
    i = 0
    while i < len(argv):
        if argv[i] == "--output" and i + 1 < len(argv):
            output_override = Path(argv[i + 1])
            i += 2
        else:
            filtered.append(argv[i])
            i += 1

    args = [a for a in filtered if not a.startswith("--")]
    source_video = "--source-video" in filtered
    full_source_sound = "--full-source-sound" in filtered
    no_install = "--no-install" in filtered
    install_test = "--install-test" in filtered
    allow_retail_sound = "--allow-retail-sound" in filtered
    is_test_build = source_test_mode_enabled(script_dir)
    main_output = rom_dir / "mk2.zip"
    test_output = rom_dir / "test" / "mk2.zip"
    output = output_override or (test_output if (is_test_build or install_test) else main_output)

    if is_test_build and output.resolve() == main_output.resolve():
        print(f"test_mode=1 detected; redirecting output from {main_output} to {test_output}")
        output = test_output
    output.parent.mkdir(parents=True, exist_ok=True)

    # Patched sound set (DCSEncoder --patch output; retail sound + custom
    # streams such as STLAUGH on calls 745-747). When present it is the
    # preferred default sound source — plain retail would silently revert
    # the patched sound calls to their original (cut) content.
    patched_sound_zip = sound_dir / "mk2_stlaugh.zip"

    def warn_if_sound_stale():
        # The build pipeline does NOT regenerate mk2_stlaugh.zip; only
        # makesound.py (DCSEncoder) does. If the patch script or a source clip
        # is newer than the zip, someone edited sounds without re-encoding and
        # this install would silently ship the PREVIOUS custom audio. Warn
        # loudly so it isn't discovered by ear three builds later.
        import re
        patch = sound_dir / "stlaugh_patch.txt"
        if not (patched_sound_zip.exists() and patch.exists()):
            return
        zmt = patched_sound_zip.stat().st_mtime_ns
        inputs = [patch]
        for line in patch.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r'\s*stream\s+\w+\s+"([^"]+)"\s*;', line)
            if m:
                inputs.append(sound_dir / m.group(1))
        stale = [f.name for f in inputs if f.exists() and f.stat().st_mtime_ns > zmt]
        if stale:
            print("*" * 70)
            print("WARNING: mk2_stlaugh.zip is OLDER than the sound patch inputs:")
            for n in stale:
                print(f"           {n}")
            print("         The custom audio in this build is STALE. Run")
            print("         'python makesound.py' before packaging.")
            print("*" * 70 + "\n")

    if args:
        retail_zip = Path(args[0])
        if not retail_zip.exists():
            print(f"Error: {retail_zip} not found")
            sys.exit(1)
        if (patched_sound_zip.exists() and retail_zip.resolve() != patched_sound_zip.resolve()
                and not allow_retail_sound):
            # Explicit zip args used to silently win over the patched set here
            # (only a warning, sound still reverted to retail) - this is
            # exactly what CLAUDE.md's own documented recipe
            # (`mamerom.py "mk2.zip" --source-video`) does, so following the
            # project's own docs was silently wiping out every custom sound
            # patch on every run. Now it takes a deliberate opt-in to actually
            # get retail sound when a patched set exists.
            print(f"NOTE: ignoring {retail_zip} for sound; using patched set")
            print(f"      {patched_sound_zip} instead, since it exists. Pass")
            print(f"      --allow-retail-sound to actually force retail sound.\n")
            retail_zip = patched_sound_zip
        if retail_zip.resolve() == patched_sound_zip.resolve():
            warn_if_sound_stale()
        program_roms = load_program_roms(rom_dir)
        write_merge_mode(output, retail_zip, program_roms, rom_dir, source_video=source_video)
    else:
        default_retail_zip = rom_dir / "mk2_retail.zip"
        if patched_sound_zip.exists() and not full_source_sound:
            print(f"Using patched sound set: {patched_sound_zip}\n")
            warn_if_sound_stale()
            program_roms = load_program_roms(rom_dir)
            write_merge_mode(output, patched_sound_zip, program_roms, rom_dir, source_video=True)
        elif default_retail_zip.exists() and not full_source_sound:
            program_roms = load_program_roms(rom_dir)
            write_merge_mode(output, default_retail_zip, program_roms, rom_dir, source_video=True)
        else:
            if not default_retail_zip.exists() and not full_source_sound:
                print(f"Warning: {default_retail_zip} not found; falling back to source-built sound.")
            write_full_source_mode(output, rom_dir, sound_dir)

    print(f"\nROM set: {output} ({output.stat().st_size:,d} bytes)")

    # CRC-spoof the modified ROMs so FBNeo accepts the set (FBNeo validates
    # each ROM against hardcoded CRC32s from its mk2 driver table).
    try:
        import crc_spoof
        print()
        crc_spoof.spoof_zip(output)
    except Exception as e:
        print(f"Warning: crc_spoof failed: {e}")

    # A build that cannot be identified cannot be run in a bracket. The
    # manifest has to be written AFTER crc_spoof, because that rewrites four
    # bytes of padding in each program chip - so the hashes only mean
    # something once the zip is in the state a player receives.
    try:
        import subprocess as _sp
        _sp.run([sys.executable,
                 str(Path(__file__).parent / "tools" / "release_manifest.py"),
                 "--zip", str(output)],
                cwd=str(Path(__file__).parent), timeout=120)
    except Exception as e:
        print(f"Warning: manifest not written: {e}")

    if no_install:
        print("Not installed because --no-install was passed.")
        print(f"\nTo test locally: C:\\MAME\\mame.exe -rompath \"{output.parent}\" mk2")
    elif install_test or is_test_build:
        print(f"TEST build ready: {output}")
        print("Main retail rom/mk2.zip and C:\\MAME\\roms\\mk2.zip were left untouched.")
        print(f"\nTo test WIP: C:\\MAME\\mame.exe -rompath \"{output.parent}\" mk2")
    elif MAIN_MAME_DIR.exists():
        dest = MAIN_MAME_DIR / "mk2.zip"
        shutil.copy2(output, dest)
        print(f"Installed RETAIL build: {dest}")
        print(f"\nTo test full game: C:\\MAME\\mame.exe mk2")


if __name__ == "__main__":
    main()
