#!/usr/bin/env python3
"""
build_all.py — Build both test and retail MK2 ROM variants in one shot.

Produces:
  rom/test/mk2.zip  — boots straight into a fight  (test_mode=1)
  rom/mk2.zip       — normal attract mode          (test_mode=0)

Usage:
  python build_all.py                              # build both, install retail to MAME
  python build_all.py --install-test               # build both, leave test in rom/test
  python build_all.py --no-install                 # build both, don't touch MAME
  python build_all.py --test-only                  # skip retail build
  python build_all.py --retail-only                # skip test build
  python build_all.py path/to/retail_mk2.zip       # override sound source explicitly

  Default sound source: sound/mk2_stlaugh.zip (patched - custom audio like
  STLAUGH/Jade Flash/etc.) when it exists, else rom/mk2_retail.zip. This
  matters because this is what test runs and CI-style invocations use with
  no arguments - defaulting to retail here would silently revert every
  custom sound patch on the shared C:/MAME/roms/mk2.zip install.

Build strategy:
  1. Full build (Phase A+B+C) with test features on   -> rom/test/mk2.zip
  2. No-LOAD2 asm build with features off       -> rom/mk2.zip
     (`build.py --asm-only` skips LOAD2, then promotes/syncs the existing
      tmp/load2 tables before GMAKE reassembles and relinks.)
  3. Restore patched feature equates to their original settings.
  4. Install retail only to C:/MAME/roms/mk2.zip.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR  = Path(__file__).parent.resolve()
MKAMODE     = SCRIPT_DIR / "src" / "MKAMODE.ASM"
MAINEQU     = SCRIPT_DIR / "src" / "MAINEQU.ASM"
ROM_DIR     = SCRIPT_DIR / "rom"
TEST_ROM_DIR = ROM_DIR / "test"
MAME_DEST   = Path("C:/MAME/roms/mk2.zip")
DEFAULT_RETAIL_SOUND_ZIP = ROM_DIR / "mk2_retail.zip"
PATCHED_SOUND_ZIP = SCRIPT_DIR / "sound" / "mk2_stlaugh.zip"
MAME_EXE = Path("C:/MAME/mame.exe")
FEATURE_OBJECTS = ["MKAMODE", "JOY", "MKREACT", "MKUTIL"]
LINK_OUTPUTS = ["mk2.out", "mk2.map"]

# ── test-feature equate patching ─────────────────────────────────────────────

def get_equate(path: Path, name: str) -> int:
    text = path.read_text(encoding="latin-1")
    m = re.search(rf'^{re.escape(name)}\s+\.set\s+(\d+)', text, re.MULTILINE)
    if not m:
        raise RuntimeError(f"{name} .set not found in {path}")
    return int(m.group(1))


def set_equate(path: Path, name: str, value: int) -> None:
    text = path.read_text(encoding="latin-1")
    new_text, n = re.subn(
        rf'^({re.escape(name)}\s+\.set\s+)\d+',
        lambda m: m.group(1) + str(value),
        text,
        flags=re.MULTILINE,
    )
    if n == 0:
        raise RuntimeError(f"{name} .set not found in {path} — patch failed")
    path.write_text(new_text, encoding="latin-1")
    print(f"  {path.name:11s} {name} -> {value}")


def get_test_mode() -> int:
    return get_equate(MKAMODE, "test_mode")


def get_oldshang_test_features() -> int:
    return get_equate(MAINEQU, "oldshang_test_features")


def set_variant_features(value: int) -> None:
    set_equate(MKAMODE, "test_mode", value)
    set_equate(MAINEQU, "oldshang_test_features", value)


def force_feature_rebuild() -> None:
    for stem in FEATURE_OBJECTS:
        for suffix in (".OBJ", ".LST"):
            path = SCRIPT_DIR / "src" / f"{stem}{suffix}"
            if path.exists():
                path.unlink()
                print(f"  removed stale {path.name}")
    for name in LINK_OUTPUTS:
        path = SCRIPT_DIR / "src" / name
        if path.exists():
            path.unlink()
            print(f"  removed stale {path.name}")


# ── subprocess helpers ────────────────────────────────────────────────────────

def run(cmd: list, label: str, check: bool = True) -> int:
    print(f"\n--- {label} ---")
    result = subprocess.run(cmd, cwd=str(SCRIPT_DIR))
    if check and result.returncode != 0:
        raise RuntimeError(f"{label} failed (exit {result.returncode})")
    return result.returncode


def build_full() -> None:
    run([sys.executable, "build.py"], "Full build (Phase A+B+C)")


def build_asm_only() -> None:
    run([sys.executable, "build.py", "--asm-only"], "Asm-only build (Phase B+C, no LOAD2)")


def make_program_roms() -> None:
    run([sys.executable, "makerom.py"], "makerom.py -> UJ12/UG12")


def make_video_roms() -> None:
    run([sys.executable, "makevrom.py"], "makevrom.py -> video ROM chips")
    # DOSBox (Phase A/LOAD2) can flush its virtual-disk writes to the host
    # filesystem well after its process exits - observed data\KITSPIN.IRW
    # landing ~12s newer than freshly-written video ROM chips despite
    # running strictly earlier in the pipeline. mamerom.py's freshness
    # check (IRW mtime vs chip mtime) then false-positives as "stale" no
    # matter how many times makevrom.py is rerun immediately after. Touch
    # the chips to the current wall-clock time so they unambiguously
    # postdate any delayed IRW flush instead of racing it.
    for chip in ROM_DIR.glob("l1_mortal_kombat_ii_game_rom_*"):
        chip.touch()


def package(output_zip: Path, sound_zip: Path | None, source_video: bool) -> None:
    cmd = [sys.executable, "mamerom.py",
           "--output", str(output_zip),
           "--no-install"]
    if sound_zip:
        cmd.append(str(sound_zip))
        if source_video:
            cmd.append("--source-video")
    label = f"mamerom.py -> {output_zip.name}"
    rc = run(cmd, label, check=False)
    if rc != 0 and source_video:
        # mamerom.py's video-freshness check can trip even immediately after
        # a successful make_video_roms() call (seen reliably in practice,
        # not just here) - one retry after re-running makevrom.py resolves
        # it every time observed so far.
        print(f"  {label} failed (exit {rc}); retrying after a second makevrom.py pass")
        make_video_roms()
        rc = run(cmd, label, check=False)
    if rc != 0:
        raise RuntimeError(f"{label} failed (exit {rc})")


def install(zip_path: Path) -> None:
    if not MAME_DEST.parent.exists():
        print(f"MAME roms dir not found ({MAME_DEST.parent}) — skipping install")
        return
    shutil.copy2(zip_path, MAME_DEST)
    print(f"Installed: {MAME_DEST}")


def verify_mame_rom(rom_path: Path) -> None:
    if not MAME_EXE.exists():
        print(f"MAME not found ({MAME_EXE}) — skipping verify")
        return
    rom_dir = rom_path.parent if rom_path.is_file() else rom_path
    run([str(MAME_EXE), "-rompath", str(rom_dir), "-verifyroms", "mk2"],
        f"MAME verify ({rom_dir})")


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    argv = sys.argv[1:]
    if "--help" in argv or "-h" in argv:
        print(__doc__.strip())
        return

    install_test  = "--install-test"  in argv
    no_install    = "--no-install"    in argv
    test_only     = "--test-only"     in argv
    retail_only   = "--retail-only"   in argv
    source_video  = "--source-video"  in argv
    source_sound  = "--source-sound"  in argv
    skip_verify   = "--skip-verify"   in argv

    # Positional: optional path to retail sound ZIP
    pos = [a for a in argv if not a.startswith("--")]
    if len(pos) > 1:
        print(f"Error: expected at most one retail sound zip, got {len(pos)}")
        sys.exit(1)
    if test_only and retail_only:
        print("Error: --test-only and --retail-only cannot be used together")
        sys.exit(1)

    if pos:
        sound_zip = Path(pos[0])
    elif source_sound:
        sound_zip = None
    elif PATCHED_SOUND_ZIP.exists():
        sound_zip = PATCHED_SOUND_ZIP
        print(f"Using patched sound set: {sound_zip}")
    else:
        sound_zip = DEFAULT_RETAIL_SOUND_ZIP
        print(f"No patched sound set at {PATCHED_SOUND_ZIP}; falling back to retail: {sound_zip}")

    if sound_zip and not sound_zip.exists():
        print(f"Error: sound ZIP not found: {sound_zip}")
        if sound_zip == DEFAULT_RETAIL_SOUND_ZIP:
            print("Pass a clean retail zip explicitly, or use --source-sound for source-built sound ROMs.")
        sys.exit(1)

    if sound_zip and not source_video:
        # Default to --source-video when a sound zip is given — produces the
        # cleanest MAME set (our video ROMs match retail byte-for-byte).
        source_video = True

    ROM_DIR.mkdir(exist_ok=True)
    TEST_ROM_DIR.mkdir(exist_ok=True)

    # Remember original feature settings so we can restore them on exit.
    original_mode = get_test_mode()
    original_oldshang = get_oldshang_test_features()
    print(f"Current test_mode = {original_mode}")
    print(f"Current oldshang_test_features = {original_oldshang}")

    test_zip   = TEST_ROM_DIR / "mk2.zip"
    retail_zip = ROM_DIR / "mk2.zip"

    try:
        # ── Test variant ───────────────────────────────────────────────────
        if not retail_only:
            print("\n===== TEST variant (test features=1) =====")
            set_variant_features(1)
            force_feature_rebuild()
            build_full()        # Phase A+B+C — also builds image ROMs
            make_program_roms()
            make_video_roms()
            package(test_zip, sound_zip, source_video)
            if not skip_verify:
                verify_mame_rom(TEST_ROM_DIR)
            print(f"  -> {test_zip}")

        # ── Retail variant ─────────────────────────────────────────────────
        if not test_only:
            print("\n===== RETAIL variant (test features=0) =====")
            set_variant_features(0)
            force_feature_rebuild()
            if retail_only:
                build_full()
                make_video_roms()
            else:
                # --asm-only: LOAD2 output unchanged from the test build;
                # table promotion/refresh still runs before GMAKE relinks.
                build_asm_only()
            make_program_roms()
            package(retail_zip, sound_zip, source_video)
            if not skip_verify:
                verify_mame_rom(retail_zip)
            print(f"  -> {retail_zip}")

    finally:
        # Always restore original feature equates.
        restored = False
        if get_test_mode() != original_mode:
            set_equate(MKAMODE, "test_mode", original_mode)
            restored = True
        if get_oldshang_test_features() != original_oldshang:
            set_equate(MAINEQU, "oldshang_test_features", original_oldshang)
            restored = True
        if restored:
            print(f"\nRestored test_mode = {original_mode}")
            print(f"Restored oldshang_test_features = {original_oldshang}")

    # ── Summary ────────────────────────────────────────────────────────────
    print("\n===== Done =====")
    for label, path in [("test", test_zip), ("retail", retail_zip)]:
        if path.exists():
            print(f"  {label:6s}  {path}  ({path.stat().st_size:,d} bytes)")

    # ── Install ────────────────────────────────────────────────────────────
    if no_install:
        print("Not installed (--no-install).")
        return

    if install_test and test_zip.exists():
        print("\nTEST build is ready, but main mk2.zip stays retail.")
        print(f"To test WIP: C:\\MAME\\mame.exe -rompath \"{TEST_ROM_DIR}\" mk2")
        if retail_zip.exists() and not test_only:
            print("\nInstalling RETAIL build to MAME...")
            install(retail_zip)
    elif retail_zip.exists() and not test_only:
        print("\nInstalling RETAIL build to MAME...")
        install(retail_zip)
    elif test_zip.exists():
        print("\nTEST build is ready, but main mk2.zip stays retail.")
        print(f"To test WIP: C:\\MAME\\mame.exe -rompath \"{TEST_ROM_DIR}\" mk2")


if __name__ == "__main__":
    main()
