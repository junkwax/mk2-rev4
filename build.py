#!/usr/bin/env python3
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROM_NAME_RE = re.compile(r'(rom_name\s+\.string\s+")([^"]+)(")')
HASH_SUFFIX_RE = re.compile(r"\s+\([0-9A-Fa-f]{5,6}\*?\)$")
INCLUDE_RE = re.compile(r'^\s*\.INCLUDE\s+"?([^"\s;]+)"?', re.IGNORECASE)
ROM_NAME_MAX_CHARS = 29


def get_dosbox_path() -> Path:
    system = platform.system()

    if system == "Darwin":
        paths = [
            Path("/Applications/DOSBox.app/Contents/MacOS/dosbox"),
            Path.home() / "Applications/DOSBox.app/Contents/MacOS/dosbox",
            Path("/Applications/DOSBox-X.app/Contents/MacOS/dosbox-x"),
            Path.home() / "Applications/DOSBox-X.app/Contents/MacOS/dosbox-x",
        ]
    elif system == "Windows":
        local_appdata = os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))
        prog86 = os.environ.get("PROGRAMFILES(X86)", "C:\\Program Files (x86)")
        prog   = os.environ.get("PROGRAMFILES",       "C:\\Program Files")
        paths = [
            Path(local_appdata) / "Programs" / "DOSBox Staging" / "dosbox.exe",
            Path(local_appdata) / "Programs" / "DOSBox-Staging"  / "dosbox.exe",
            Path(prog86) / "DOSBox-0.74-3" / "DOSBox.exe",
            Path(prog)   / "DOSBox-0.74-3" / "DOSBox.exe",
            Path(prog86) / "DOSBox-0.74"   / "DOSBox.exe",
            Path(prog)   / "DOSBox-0.74"   / "DOSBox.exe",
        ]
    else:
        paths = [
            Path("/usr/bin/dosbox"),
            Path("/usr/local/bin/dosbox"),
            Path.home() / ".local/bin/dosbox",
        ]

    for path in paths:
        if path.exists():
            return path

    dosbox = shutil.which("dosbox")
    if dosbox:
        return Path(dosbox)

    return None


def git_output(args, cwd: Path) -> str:
    return subprocess.check_output(["git", *args], cwd=str(cwd), text=True).strip()


def get_build_id(repo: Path) -> str:
    try:
        short_hash = git_output(["rev-parse", "--short=6", "HEAD"], repo).upper()
        dirty = bool(git_output(["status", "--porcelain", "--untracked-files=no"], repo))
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "LOCAL"

    if dirty:
        return f"{short_hash[:5]}*"
    return short_hash


def update_rom_name(repo: Path) -> None:
    diagmenu = repo / "src" / "DIAGMENU.ASM"
    text = diagmenu.read_text(encoding="utf-8", errors="replace")
    match = ROM_NAME_RE.search(text)
    if not match:
        raise RuntimeError("rom_name string not found in src/DIAGMENU.ASM")

    base_name = HASH_SUFFIX_RE.sub("", match.group(2))
    build_id = get_build_id(repo)
    rom_name = f"{base_name} ({build_id})"
    if len(rom_name) > ROM_NAME_MAX_CHARS:
        raise RuntimeError(
            f"ROM name '{rom_name}' is {len(rom_name)} chars; max is {ROM_NAME_MAX_CHARS}"
        )

    new_text = text[:match.start(2)] + rom_name + text[match.end(2):]
    if new_text != text:
        diagmenu.write_text(new_text, encoding="utf-8", errors="replace")
        print(f"ROM name: {rom_name}")
    else:
        print(f"ROM name: {rom_name} (unchanged)")


def sync_short_asm_aliases(repo: Path) -> None:
    """Mirror long data ASM names to DOS-friendly 8.3 include names."""
    aliases = [
        ("EDPOOLFULL.ASM", "EDPFULL.ASM"),
    ]

    data_dir = repo / "data"
    for long_name, short_name in aliases:
        src = data_dir / long_name
        dst = data_dir / short_name
        if not src.exists():
            continue
        src_bytes = src.read_bytes()
        if dst.exists() and dst.read_bytes() == src_bytes:
            continue
        dst.write_bytes(src_bytes)
        print(f"ASM alias: data/{short_name} <= data/{long_name}")


def _include_path(src_dir: Path, current_file: Path, name: str) -> Path | None:
    raw = Path(name)
    candidates = []
    if raw.is_absolute():
        candidates.append(raw)
    else:
        candidates.append(current_file.parent / raw)
        candidates.append(src_dir / raw)

    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return None


def _collect_includes(src_dir: Path, path: Path, memo: dict[Path, set[Path]], stack: set[Path]) -> set[Path]:
    path = path.resolve()
    if path in memo:
        return memo[path]
    if path in stack:
        return set()

    stack.add(path)
    deps: set[Path] = set()
    try:
        lines = path.read_text(encoding="latin-1", errors="replace").splitlines()
    except OSError:
        lines = []

    for line in lines:
        match = INCLUDE_RE.match(line)
        if not match:
            continue
        include = _include_path(src_dir, path, match.group(1))
        if include is None:
            continue
        deps.add(include)
        deps.update(_collect_includes(src_dir, include, memo, stack))

    stack.remove(path)
    memo[path] = deps
    return deps


def remove_stale_include_objects(repo: Path) -> None:
    """Force reassembly when an included TBL/GLO/ASM changed.

    The DOS makefile only tracks top-level .ASM timestamps. Most sprite SAGs,
    palette globals, and generated image headers live in included files, so an
    include-only edit can otherwise link a fresh mk2.out from stale object code.
    """
    src_dir = repo / "src"
    memo: dict[Path, set[Path]] = {}
    removed: list[tuple[str, str]] = []

    for asm in sorted(src_dir.glob("*.ASM")):
        obj = src_dir / f"{asm.stem}.OBJ"
        if not obj.exists():
            continue

        deps = {asm.resolve()}
        deps.update(_collect_includes(src_dir, asm, memo, set()))
        try:
            obj_mtime = obj.stat().st_mtime
        except OSError:
            continue

        newest_dep = None
        newest_mtime = obj_mtime
        for dep in deps:
            try:
                dep_mtime = dep.stat().st_mtime
            except OSError:
                continue
            if dep_mtime > newest_mtime:
                newest_dep = dep
                newest_mtime = dep_mtime

        if newest_dep is not None:
            obj.unlink()
            removed.append((obj.name, newest_dep.name))

    if removed:
        print(f"  Phase C0: removed {len(removed)} stale object(s) with newer includes")
        for obj_name, dep_name in removed[:20]:
            print(f"    {obj_name} <- {dep_name}")
        if len(removed) > 20:
            print(f"    ... {len(removed) - 20} more")
    else:
        print("  Phase C0: included-file object check clean")


def main():
    asm_only = "--asm-only" in sys.argv  # skip Phase A (LOAD2), but still promote existing tmp/load2 tables

    script_dir = Path(__file__).parent.resolve()
    build_log = script_dir / "build.log"
    mk2_out = script_dir / "src" / "mk2.out"

    dosbox = get_dosbox_path()
    if not dosbox:
        print("Error: DOSBox not found.")
        print("Install DOSBox 0.74-3 from https://www.dosbox.com/")
        sys.exit(1)

    conf_load2 = script_dir / "dosbox_load2.conf"
    conf_asm   = script_dir / "dosbox_asm.conf"
    for c in (conf_load2, conf_asm):
        if not c.exists():
            print(f"Error: {c.name} not found in {script_dir}")
            sys.exit(1)

    try:
        update_rom_name(script_dir)
        sync_short_asm_aliases(script_dir)
    except RuntimeError as exc:
        print(f"Error: {exc}")
        sys.exit(1)

    def run_dosbox(conf, label):
        print(f"  {label}")
        # -exit: required on DOSBox Staging to let the autoexec `exit` actually
        # terminate the session. Without it, Staging shows "Preventing an early
        # 'exit' call from terminating" and the window hangs.
        cmd = [str(dosbox), "-conf", str(conf), "-noconsole", "-exit"]
        result = subprocess.run(cmd, cwd=str(script_dir))
        if result.returncode != 0:
            print(f"Error: DOSBox returned {result.returncode} during {label}")
            sys.exit(result.returncode)

    def fail_with_build_log(message):
        print(f"Error: {message}")
        if build_log.exists():
            print("build.log tail:")
            lines = build_log.read_text(encoding="latin-1", errors="replace").splitlines()
            for line in lines[-80:]:
                print(line)
        sys.exit(1)

    def verify_asm_build(start_mtime):
        if not mk2_out.exists():
            fail_with_build_log("Phase C did not produce src/mk2.out")

        out_mtime = mk2_out.stat().st_mtime
        if out_mtime < start_mtime:
            fail_with_build_log("src/mk2.out is stale after Phase C")

        if not build_log.exists():
            fail_with_build_log("Phase C did not produce build.log")

        log_text = build_log.read_text(encoding="latin-1", errors="replace")
        failure_markers = [
            "Assembler Aborted",
            "Errors in source",
            "symbol referencing errors",
            "undefined",
            "not built",
            "Error:",
        ]
        for marker in failure_markers:
            if marker in log_text:
                fail_with_build_log(f"Phase C reported '{marker}'")

    print(f"Starting DOSBox build: {dosbox}")

    if asm_only:
        print("  --asm-only: skipping Phase A (LOAD2); promoting existing tmp/load2 tables")

    # Phase A: LOAD2 first - produces tmp/load2/*.TBL with current SAG layout
    if not asm_only:
        print("  Phase A0: Check stock MK7 BDB/BDD files against mk2-readonly")
        bg_asset_check = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "check_stock_bg_assets.py")],
            cwd=str(script_dir),
        )
        if bg_asset_check.returncode != 0:
            print(f"Error: check_stock_bg_assets.py returned {bg_asset_check.returncode}")
            sys.exit(bg_asset_check.returncode)

        # Before LOAD2 runs, not after: a duplicate record name means LOAD2
        # packs the LAST match and the promoted TBL keeps its old palette
        # line, so the sprite ships in another palette's colours with a green
        # build.  Nothing downstream can see it - the control word can come
        # out identical and every index can still be in range.  Scorpion's
        # select box shipped that way on 2026-09-23 and a player found it.
        print("  Phase A0b: IMG record/palette name collisions")
        img_name_check = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "check_img_names.py"),
             "--check"],
            cwd=str(script_dir),
        )
        if img_name_check.returncode != 0:
            print("Error: IMG name collisions drifted from doc/img_names.lock "
                  f"(returncode {img_name_check.returncode})")
            sys.exit(img_name_check.returncode)
        print("  Phase A0b: IMG names OK")

        run_dosbox(conf_load2, "Phase A: Image ROM build (LOAD2 -> IRW + tmp/load2/*.TBL)")
        print("  Phase A1: Check LOAD2 log for incomplete image passes")
        load2_check = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "check_load2_log.py")],
            cwd=str(script_dir),
        )
        if load2_check.returncode != 0:
            print(f"Error: check_load2_log.py returned {load2_check.returncode}")
            sys.exit(load2_check.returncode)

    if not asm_only or (script_dir / "tmp" / "load2").exists():
        # Phase B1: Promote per-character LOAD2 tables (MKLK.TBL, MKNJ.TBL, etc.)
        # so GSPA sees fresh sprite SAGs. Without this, character sprites render
        # garbled when any .LOD changes.
        print("  Phase B1: Promote tmp/load2/*.TBL -> src/")
        promote = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "promote_tbls.py")],
            cwd=str(script_dir),
        )
        if promote.returncode != 0:
            print(f"Error: promote_tbls.py returned {promote.returncode}")
            sys.exit(promote.returncode)

        # Phase B1a: MKFX.ASM has a private inline MKRIGHT1 header for
        # CRIGHT.IMG. Keep it synced with the LOAD2-promoted MKMK3.TBL record.
        print("  Phase B1a: Sync MKFX inline MKRIGHT1 from MKMK3.TBL")
        mkright = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_mkfx_mkright1.py")],
            cwd=str(script_dir),
        )
        if mkright.returncode != 0:
            print(f"Error: sync_mkfx_mkright1.py returned {mkright.returncode}")
            sys.exit(mkright.returncode)

        # Phase B1a2: MKDEATH.ASM keeps a re-anchored inline copy of the
        # KHEART6B record (KHEART6B_OPEN) for Cage's headhole fatality.
        # Keep its SAG/size/ctrl synced with the promoted JCMK1BLD.TBL.
        print("  Phase B1a2: Sync KHEART6B_OPEN from JCMK1BLD.TBL")
        kheart = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_jc_kheart_open.py")],
            cwd=str(script_dir),
        )
        if kheart.returncode != 0:
            print(f"Error: sync_jc_kheart_open.py returned {kheart.returncode}")
            sys.exit(kheart.returncode)

        # Phase B1a3: JCBLOOD.TBL's JCSTAB/JCSPLAT records are hand-made
        # copies of BLOOD.IMG's STAB/SPLAT (IMG anipoints, stock SAGs) for the
        # same fatality's wound spray. No LOD emits them, so resync SAG/ctrl/
        # size from the promoted MKBLOOD.TBL and anipoints from BLOOD.IMG.
        print("  Phase B1a3: Sync JCSTAB/JCSPLAT from MKBLOOD.TBL + BLOOD.IMG")
        jcblood = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_jc_blood.py")],
            cwd=str(script_dir),
        )
        if jcblood.returncode != 0:
            print(f"Error: sync_jc_blood.py returned {jcblood.returncode}")
            sys.exit(jcblood.returncode)

        # Phase B1b: MKHANG.ASM includes a small hand-maintained MKHANGN.TBL
        # shim, while LOAD2 emits those hanger labels inside MKCHUNKS.TBL.
        # Keep the shim synced so MKHANG.IMG edits update runtime bodies too.
        print("  Phase B1b: Sync MKHANGN + ACIDHANG hanger shims from LOAD2 labels")
        mkhangn = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_load2_tables.py"),
             "--tables", "MKHANGN.TBL", "ACIDHANG.TBL",
             "--fields", "size,sag,ctrl,palette",
             "--apply", "--no-backup"],
            cwd=str(script_dir),
        )
        if mkhangn.returncode != 0:
            print(f"Error: sync_load2_tables.py MKHANGN returned {mkhangn.returncode}")
            sys.exit(mkhangn.returncode)

        # Phase B1c: GOROWALK is a background sidecar included directly by
        # ARENAKIN.ASM. LOAD2 owns its subframe size/anipt/SAG/CTRL fields, but the
        # source table keeps the hand-selected KINTWLK_P palette.
        print("  Phase B1c: Sync GOROWALK sidecar subframe headers")
        gorowalk = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_load2_tables.py"),
             "--tables", "GOROWALK.TBL",
             "--fields", "size,sag,ctrl",
             "--apply", "--no-backup"],
            cwd=str(script_dir),
        )
        if gorowalk.returncode != 0:
            print(f"Error: sync_load2_tables.py GOROWALK returned {gorowalk.returncode}")
            sys.exit(gorowalk.returncode)

        # Phase B1d: SCLAP.LOD is the last MKSK.TBL emitter and carries only the
        # eleven SONICLAP sidecar records, so promote_tbls.py never sees a Shao
        # Kahn record. Patch them from IMGBUILD.BAT's MK5MIL snapshot instead.
        print("  Phase B1d: Sync Shao Kahn MKSK records from MK5MIL snapshot")
        mksk = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_mksk_mk5.py")],
            cwd=str(script_dir),
        )
        if mksk.returncode != 0:
            print(f"Error: sync_mksk_mk5.py returned {mksk.returncode}")
            sys.exit(mksk.returncode)

        # Phase B2: Promote stock-background records in src/BGNDTBL.ASM from the
        # tmp/load2/BGNDTBL.MK7 snapshot. This includes SAGs plus BLKS/BMOD
        # placement records, so live BDB/BDD edits made in BDDTool reach the game.
        print("  Phase B2: Promote stock BGNDTBL records from MK7MIL snapshot")
        bgnd_records = subprocess.run(
            [sys.executable, str(script_dir / "tools" /
                                 "promote_bgndtbl_stock_records.py"), "--apply"],
            cwd=str(script_dir),
        )
        if bgnd_records.returncode != 0:
            print(f"Error: promote_bgndtbl_stock_records.py returned "
                  f"{bgnd_records.returncode}")
            sys.exit(bgnd_records.returncode)

        # Phase B2a: Sync stock-background SAGs in src/BGNDTBL.ASM from the
        # tmp/load2/BGNDTBL.MK7 snapshot. Usually a no-op after full-record
        # promotion, but left as a guardrail for address-only changes.
        print("  Phase B2a: Sync stock BGNDTBL SAGs from MK7MIL snapshot")
        bgnd = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "promote_bgndtbl_stock_sags.py"),
             "--apply"],
            cwd=str(script_dir),
        )
        if bgnd.returncode != 0:
            print(f"Error: promote_bgndtbl_stock_sags.py returned {bgnd.returncode}")
            sys.exit(bgnd.returncode)

        # Phase B2b: Sync ALL anonymous BGNDTBL SAGs (OLHDRS inline entries).
        # promote_bgndtbl_stock_sags.py only handles 28 labeled headers;
        # this catches the remaining ~500+ unlabeled per-tile SAG values.
        print("  Phase B2b: Sync anonymous BGNDTBL SAGs (inline OLHDRS entries)")
        bgnd2 = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_bgndtbl_sags.py")],
            cwd=str(script_dir),
        )
        if bgnd2.returncode != 0:
            print(f"Error: sync_bgndtbl_sags.py returned {bgnd2.returncode}")
            sys.exit(bgnd2.returncode)

        # Phase B2c: Regenerate src/MK1PITBG.ASM from the baked MK7 snapshot.
        # SAGs shift whenever MK7MIL.LOD or upstream background data changes.
        print("  Phase B2c: Refresh MK1PITBG.ASM from BGNDTBL.MK7")
        kfp = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "refresh_mk1pitbg.py")],
            cwd=str(script_dir),
        )
        if kfp.returncode != 0:
            print(f"Error: refresh_mk1pitbg.py returned {kfp.returncode}")
            sys.exit(kfp.returncode)

        # Phase B2d2: THE CAVE's 60 images are dealt across four fixed-slot
        # BBB> packs (data/MK3CV1-4.LOD) because no free run holds ~201KB.
        # Merge the four LOAD2 header snapshots back into the stage's four
        # modules, plus the FL_CAVE floor SAG, in src/MK3CAVBG.ASM.
        print("  Phase B2d2: Merge THE CAVE pack tables")
        cave = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk3cave.py"), "--apply"],
            cwd=str(script_dir),
        )
        if cave.returncode != 0:
            print(f"Error: make_mk3cave.py returned {cave.returncode}")
            sys.exit(cave.returncode)

        # Phase B2d3: THE PIT (MK1).  The bridge/shaft images the Pit Bottom
        # does not carry are dealt across four BBB> packs (data/MK1PT1-4.LOD);
        # merge their header snapshots with TPLHDRS into one module, plus the
        # sky's palettes and MK1's cloud/silhouette tables, in src/MK1PTOPB.ASM.
        print("  Phase B2d3: Merge THE PIT (MK1) pack tables")
        mk1pit = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk1pit.py"), "--apply"],
            cwd=str(script_dir),
        )
        if mk1pit.returncode != 0:
            print(f"Error: make_mk1pit.py returned {mk1pit.returncode}")
            sys.exit(mk1pit.returncode)

        # Phase B2d4: THE WARRIOR SHRINE (MK1).  data/KUNGFU1's images are dealt
        # across two BBB> packs (data/MK1WS1-2.LOD); merge their header
        # snapshots, plus the three SAGs it shares with THE PIT (read out of
        # src/MK1PTOPB.ASM, so this runs after B2d3), into src/MK1WSHRB.ASM.
        print("  Phase B2d4: Merge THE WARRIOR SHRINE (MK1) pack tables")
        mk1wshr = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk1shrine.py"), "--apply"],
            cwd=str(script_dir),
        )
        if mk1wshr.returncode != 0:
            print(f"Error: make_mk1shrine.py returned {mk1wshr.returncode}")
            sys.exit(mk1wshr.returncode)

        # Phase B2d5: THE THRONE ROOM (MK1).  No .BDB/.BDD for it exists in the
        # leak, so make_mk1throne.py decodes all 45 images out of mk.zip and
        # deals them across four BBB> packs (data/MK1TR1-4.LOD); merge their
        # header snapshots into the stage's seven modules in src/MK1THRNB.ASM.
        print("  Phase B2d5: Merge THE THRONE ROOM (MK1) pack tables")
        mk1thrn = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk1throne.py"), "--apply"],
            cwd=str(script_dir),
        )
        if mk1thrn.returncode != 0:
            print(f"Error: make_mk1throne.py returned {mk1thrn.returncode}")
            sys.exit(mk1thrn.returncode)

        # Phase B2d6: THE COURTYARD (MK1), Wolf only.  make_mk1court.py decodes
        # it out of mk.zip into data/MK1CY1 + the monk sprite pack MK1CYM, both
        # above the T-unit's 12 MB; merge the snapshot into src/MK1CRTB.ASM
        # (assembled only under .if wunit).
        print("  Phase B2d6: Merge THE COURTYARD (MK1, Wolf) pack tables")
        mk1crt = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk1court.py"), "--apply"],
            cwd=str(script_dir),
        )
        if mk1crt.returncode != 0:
            print(f"Error: make_mk1court.py returned {mk1crt.returncode}")
            sys.exit(mk1crt.returncode)

        # Phase B2d7: PALACE GATES (MK1), Wolf only - make_mk1gates.py, the
        # same shape: data/MK1GT1 + the sprite pack MK1GTM -> src/MK1GTB.ASM.
        print("  Phase B2d7: Merge PALACE GATES (MK1, Wolf) pack tables")
        mk1gt = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk1gates.py"), "--apply"],
            cwd=str(script_dir),
        )
        if mk1gt.returncode != 0:
            print(f"Error: make_mk1gates.py returned {mk1gt.returncode}")
            sys.exit(mk1gt.returncode)

        # Phase B2d8: SCORPION'S LAIR (UMK3), Wolf only - make_umk3lair.py:
        # data/LAIR1 + LAIRM + the floor LAIRFL -> src/UMK3LRB.ASM.
        print("  Phase B2d8: Merge SCORPION'S LAIR (UMK3, Wolf) pack tables")
        lair = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_umk3lair.py"), "--apply"],
            cwd=str(script_dir),
        )
        if lair.returncode != 0:
            print(f"Error: make_umk3lair.py returned {lair.returncode}")
            sys.exit(lair.returncode)

        # Phase B2d8b: JADE'S DESERT (UMK3), Wolf only - make_umk3desert.py:
        # data/DSRT1 + DSRTM + the floor DSRTFL -> src/UMK3DSB.ASM.
        print("  Phase B2d8b: Merge JADE'S DESERT (UMK3, Wolf) pack tables")
        dsrt = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_umk3desert.py"), "--apply"],
            cwd=str(script_dir),
        )
        if dsrt.returncode != 0:
            print(f"Error: make_umk3desert.py returned {dsrt.returncode}")
            sys.exit(dsrt.returncode)

        # Phase B2d8c: THE SOUL CHAMBER + THE PIT 3 (UMK3), Wolf only -
        # make_umk3stages.py: data/USC1 + USCM + USCFL -> src/UMK3SCB.ASM,
        # data/UP31 -> src/UMK3P3B.ASM.
        print("  Phase B2d8c: Merge THE SOUL CHAMBER + THE PIT 3 (UMK3, Wolf) pack tables")
        u3st = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_umk3stages.py"), "--apply"],
            cwd=str(script_dir),
        )
        if u3st.returncode != 0:
            print(f"Error: make_umk3stages.py returned {u3st.returncode}")
            sys.exit(u3st.returncode)

        # Phase B2d8c2: SHAO KAHN ON HIS THRONE in THE PIT III, Wolf only -
        # make_pit3kahn.py: LOAD2's tmp/load2/UP3KN.TBL (NEWSHAO.IMG's seated
        # Kahn), SAGs relocated -> src/UP3KAHNB.ASM.
        print("  Phase B2d8c2: THE PIT III throne Kahn (Wolf) pack table")
        p3k = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_pit3kahn.py"), "--apply"],
            cwd=str(script_dir),
        )
        if p3k.returncode != 0:
            print(f"Error: make_pit3kahn.py returned {p3k.returncode}")
            sys.exit(p3k.returncode)

        # Phase B2d8d: MK3 NIGHTWOLF (Wolf only) - make_nightwolf.py --tables:
        # LOAD2's tmp/load2/NWLA-C.TBL, SAGs relocated into the u110 block,
        # merged into src/NWOLF.TBL.
        print("  Phase B2d8d: MK3 NIGHTWOLF (Wolf) pack tables")
        nwt = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_nightwolf.py"), "--tables"],
            cwd=str(script_dir),
        )
        if nwt.returncode != 0:
            print(f"Error: make_nightwolf.py returned {nwt.returncode}")
            sys.exit(nwt.returncode)

        # Phase B2d9n: MK3 NIGHTWOLF's lanes (src/NWOLFL.ASM), Wolf only -
        # MK3's MKIND.ASM lanes + Liu Kang's thrown/victim lanes (copies of
        # MKLK.TBL headers), so after B1 and B2d8d.
        print("  Phase B2d9n: MK3 NIGHTWOLF (Wolf) lanes")
        nwl = subprocess.run(
            [sys.executable, "-W", "ignore", str(script_dir / "tools" / "make_nightwolf_asm.py"), "--apply"],
            cwd=str(script_dir),
        )
        if nwl.returncode != 0:
            print(f"Error: make_nightwolf_asm.py returned {nwl.returncode}")
            sys.exit(nwl.returncode)

        # Phase B2d9r: MK3 ROBOT SMOKE (Wolf only) - make_robosmoke.py --tables
        # (LOAD2's tmp/load2/RSLA/RSLB/RSLS.TBL, SAGs relocated into the u110
        # block, merged into src/RSMOKE.TBL), then his lanes (src/RSMOKEL.ASM:
        # MK3's MKROBO.ASM lanes + the male ninjas' thrown/victim lanes, with
        # copies of MKNJ.TBL headers), so after B1.
        print("  Phase B2d9r: MK3 ROBOT SMOKE (Wolf) pack tables and lanes")
        for rs_tool, rs_arg in (("make_robosmoke.py", "--tables"), ("make_robosmoke_asm.py", "--apply")):
            rsr = subprocess.run(
                [sys.executable, "-W", "ignore", str(script_dir / "tools" / rs_tool), rs_arg],
                cwd=str(script_dir),
            )
            if rsr.returncode != 0:
                print(f"Error: {rs_tool} returned {rsr.returncode}")
                sys.exit(rsr.returncode)

        # Phase B2d9a: MK3 Sonya's lanes (src/UMK3SNYL.ASM), Wolf only - it
        # carries copies of Kitana's MKFN.TBL headers, so it is regenerated
        # after B1 has promoted the tables.
        print("  Phase B2d9a: MK3 SONYA (Wolf) lanes")
        sny = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_umk3sonya_asm.py"), "--apply"],
            cwd=str(script_dir),
        )
        if sny.returncode != 0:
            print(f"Error: make_umk3sonya_asm.py returned {sny.returncode}")
            sys.exit(sny.returncode)

        # Phase B2d9c: MK1 Kano's lanes (src/MK1KNL.ASM), Wolf only - Liu
        # Kang's lanes on Kano's MK1 frames, named out of the promoted
        # src/MK1KNO.TBL, so it is regenerated after B1.
        print("  Phase B2d9c: MK1 KANO (Wolf) lanes")
        kno = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_mk1kano_port.py"), "--apply"],
            cwd=str(script_dir),
        )
        if kno.returncode != 0:
            print(f"Error: make_mk1kano_port.py returned {kno.returncode}")
            sys.exit(kno.returncode)

        # Phase B2d9d: the attract story + bio backgrounds, Wolf only -
        # data/WSTORY.LOD (ATRAX1-4, STORY1) -> src/WSTORY.ASM.
        print("  Phase B2d9d: attract story + bio backgrounds (Wolf)")
        wst = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_wolf_story.py"), "--apply"],
            cwd=str(script_dir),
        )
        if wst.returncode != 0:
            print(f"Error: make_wolf_story.py returned {wst.returncode}")
            sys.exit(wst.returncode)

        # Phase B2d9e: the attract profiles around data/UPPROF.IMG, Wolf only -
        # palettes + the two layouts (on WSTORY.ASM's STORY1 headers, so after
        # B2d9d) -> src/UPPROF.ASM.
        print("  Phase B2d9e: attract profile portraits + layouts (Wolf)")
        upp = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_upprof.py"), "--apply"],
            cwd=str(script_dir),
        )
        if upp.returncode != 0:
            print(f"Error: make_upprof.py returned {upp.returncode}")
            sys.exit(upp.returncode)

        # Phase B2d9b: UMK3 Sindel's lanes (src/UMK3SDL.ASM), Wolf only -
        # decompiled out of umk3.zip, plus copies of Kitana's MKFN.TBL headers.
        print("  Phase B2d9b: UMK3 SINDEL (Wolf) lanes")
        sdl = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_umk3sindel_asm.py"), "--apply"],
            cwd=str(script_dir),
        )
        if sdl.returncode != 0:
            print(f"Error: make_umk3sindel_asm.py returned {sdl.returncode}")
            sys.exit(sdl.returncode)

        # Phase B2d9: the Wolf-only fighters (MK3 Sonya, ochar 20) - one
        # `.if wunit` row per ochar-indexed table, so the T-unit is untouched.
        print("  Phase B2d9: Wolf-only fighter rows in every ochar table")
        wfr = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "wolf_fighter_rows.py"), "--apply"],
            cwd=str(script_dir), stdout=subprocess.DEVNULL,
        )
        if wfr.returncode != 0:
            print(f"Error: wolf_fighter_rows.py returned {wfr.returncode}")
            sys.exit(wfr.returncode)

        # Phase B2e: Keep Armory in its normal MK7 range and repair the one
        # LOAD2 compression bit that garbles ry1HDRS[0].
        print("  Phase B2e: Repair Armory inside MK7MIL")
        armory = subprocess.run(
            [sys.executable, str(script_dir / "tools" /
                                 "fix_armory_mk7_bg.py"), "--apply"],
            cwd=str(script_dir),
        )
        if armory.returncode != 0:
            print(f"Error: fix_armory_mk7_bg.py returned {armory.returncode}")
            sys.exit(armory.returncode)

        # Phase B2e2: LOAD2 ORs stray bits into the last rows of some
        # compressed records, and WHICH pixels depends on where the record
        # lands - JXSPLIT9A has been 1, 2 and 4 pixels wrong as MK6MIL reflowed.
        # Rewrite those pixel values from the authored IMG, in the IRW, before
        # makevrom packs it.  Refuses rather than guesses (wrong size, other
        # records inside the range, too many differences).
        print("  Phase B2e2: Repair LOAD2 stray pixel bits from authored IMGs")
        bleed = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "fix_load2_bit_bleed.py"), "--apply"],
            cwd=str(script_dir),
        )
        if bleed.returncode != 0:
            print(f"Error: fix_load2_bit_bleed.py returned {bleed.returncode}")
            sys.exit(bleed.returncode)

        # Phase B2f: MKSEL.ASM uses two inline MKVERSUS restore chunks for the
        # stage-select text panel. Sync them from the current RSUSHDRS records.
        print("  Phase B2f: Sync MKSEL VS restore chunks from BGNDTBL.ASM")
        vs_restore = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "sync_mksel_vs_restore.py")],
            cwd=str(script_dir),
        )
        if vs_restore.returncode != 0:
            print(f"Error: sync_mksel_vs_restore.py returned {vs_restore.returncode}")
            sys.exit(vs_restore.returncode)

        # Phase B2g: data/MK2PALS.IMG is the costume WORKBENCH - every
        # fighter's <XX>MAIN_P / <XX>ALTn_P and their <XX>BLDn_P twins, opened
        # and repainted in IMGTOOL. It is in no LOD, so LOAD2 never reads it
        # and nothing else carries it: src/COSTPAL.ASM and the costume rows of
        # MKGUYS.ASM's seven tables are generated from it. That makes it the
        # one library a repaint or a NEW costume reaches the ROM from only by
        # running this, so it is promoted here like any other table rather
        # than merely checked - Phase D's --check then guards a hand edit to
        # the generated files, which is what that check is for.
        #
        # Safe to run every build: BLOOD_STAYS_LIT is authored rather than
        # derived from the rows this rewrites, so --apply is idempotent (a
        # second run is a no-op, proven before this was wired in).
        print("  Phase B2g: Promote costume palettes from data/MK2PALS.IMG")
        costpal = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "make_costume_palettes.py"),
             "--apply"],
            cwd=str(script_dir), capture_output=True, text=True,
        )
        if costpal.returncode != 0:
            print(costpal.stdout)
            print(costpal.stderr)
            print(f"Error: make_costume_palettes.py returned {costpal.returncode}")
            sys.exit(costpal.returncode)
        for line in costpal.stdout.splitlines():
            if line.startswith("wrote ") or " <- " in line:
                print(f"    {line.strip()}")
    else:
        print("Error: --asm-only needs tmp/load2 from a previous LOAD2 pass.")
        print("Run `python build.py` after BDD/IMG/LOD changes that need LOAD2 to repack IRWs.")
        sys.exit(2)

    # Phase C: assemble + link with fresh SAGs
    if mk2_out.exists():
        mk2_out.unlink()
        map_path = script_dir / "src" / "mk2.map"
        if map_path.exists():
            map_path.unlink()
        print("  Phase C: removed stale mk2.out before link")
    remove_stale_include_objects(script_dir)
    asm_start_mtime = mk2_out.stat().st_mtime if mk2_out.exists() else 0
    # Phase C1: assemble out of date modules STAGED, each with a MAINEQU pruned
    # to the globals it names (tools/gspa_stage.py).  GSPA pays for every
    # .global it is handed and aborts "Out of memory" near ~630 KB; pruning
    # gave MOVES 3-4x the margin, and the linked mk2.out is byte-identical
    # (gspa_stage.py --verify).  GMAKE then only links - and re-assembles,
    # unpruned, anything the stage could not.  MK2_GSPA_STAGE=0 turns it off.
    staged_log = ""
    if os.environ.get("MK2_GSPA_STAGE", "1") != "0":
        sys.path.insert(0, str(script_dir / "tools"))
        import gspa_stage
        src_dir = script_dir / "src"
        mods = gspa_stage.modules_to_assemble(src_dir)
        if mods:
            print(f"  Phase C1: staged assembly of {len(mods)} module(s), pruned MAINEQU")
            stage_log = script_dir / "tmp" / "asmstage.log"
            stage_log.write_text("", encoding="latin-1")
            failed = gspa_stage.assemble(src_dir, script_dir / "tmp" / "asmstage", mods,
                                         str(dosbox), stage_log)
            staged_log = stage_log.read_text(encoding="latin-1", errors="replace")
            if failed:
                print(f"  Phase C1: {len(failed)} module(s) failed staged - GMAKE will retry them "
                      f"unpruned: {', '.join(failed)}")
    run_dosbox(conf_asm, "Phase C: Assemble + Link (gmake -> mk2.out)")
    if staged_log and build_log.exists():
        build_log.write_text(staged_log + build_log.read_text(encoding="latin-1", errors="replace"),
                             encoding="latin-1")
    verify_asm_build(asm_start_mtime)

    # Phase D: sanity check - promotion and repair tools in --check mode. Fails the
    # build if anything drifted between promote and now (catches manual
    # TBL/ASM edits that would silently produce garbled sprites/backgrounds).
    print("  Phase D: SAG sanity check")
    for name, tool in [
        ("per-character TBLs", "promote_tbls.py"),
        ("MKFX inline MKRIGHT1", "sync_mkfx_mkright1.py"),
        ("Cage KHEART6B_OPEN inline record", "sync_jc_kheart_open.py"),
        ("Cage JCSTAB/JCSPLAT copies", "sync_jc_blood.py"),
        ("Shao Kahn MKSK records", "sync_mksk_mk5.py"),
        # Ermac's lift windup reuses NJELBO2 / NJHIPUNCH7 at re-authored
        # anipoints.  The clone records live in MKNJ.TBL as src-only labels,
        # which promote_tbls preserves and LOAD2 therefore never updates - so
        # nothing else would notice their SAGs going stale when the ninja art
        # moves, and a stale SAG draws torn rows rather than a wrong picture.
        ("Ermac lift-windup clone records", "sync_ermac_lane.py"),
        ("stock BGNDTBL records", "promote_bgndtbl_stock_records.py"),
        # THE TOWER's terracotta guards. data/TOWER3.BDB is hand-laid, not
        # promoted, and BDDTool cannot show what the game will do with it: a
        # guard dropped inside PLANE4's box joins the pillars and drags their
        # origin, records out of ascending-x order are dropped by bsrch1stxb,
        # and all six guards share one display list so their z ramp is what
        # decides which of the overlapping pairs occludes which. This
        # re-derives the layout and also diffs TOWER3's stock half against
        # data/TOWER2.BDB/.BDD, which check_stock_bg_assets.py cannot do for a
        # stage that has no mk2-readonly counterpart.
        #
        # TOWER3 replaced TWRSIDE here (2026-09-03). TWRSIDE split two guards
        # across baklst1 and baklst3; TOWER3 puts three mirrored pairs in one
        # module on baklst3, so twrside_statue_layout.py and
        # twrside_flame_align.py no longer describe the shipped stage and are
        # not run. They are kept in tools/ for the history, not the build.
        ("TOWER3 terracotta guard layout", "tower3_statue_layout.py"),
        # All six guards got animated torches on 2026-09-04. The flames are
        # runtime pid_bani objects, so their coordinates live in BGND.ASM as
        # constants derived from the BDB - re-spacing the row or dragging the
        # module in BDDTool's Runtime view silently strands them in mid-air,
        # and no editor render shows it. This fails the build on that drift.
        ("TOWER3 guard torch alignment", "tower3_flame_align.py"),
        # The guards got REFLECTIONS in the marble on 2026-09-09 - STATREF1a/1b,
        # 2a/2b, 3a/3b out of CASTLE.IMG (data/STATREF.LOD), the strips Midway
        # drew for a castle stage that was never built. Same staleness class as
        # the torches above: runtime objects whose coordinates are BDB-derived
        # constants in BGND.ASM. This also fails the build if a strip drifts off
        # the marble and onto the red carpet in the floor's near half, which is
        # the one way it can be perfectly aligned and still look wrong.
        ("TOWER3 guard reflection alignment", "tower3_reflection_align.py"),
        ("TOWER guards/pillars at the floor's rate (twrdepth)", "tower_guard_depths.py"),
        ("TOWER pillar reflection strips + fade (twrpslice)", "tower_pillar_strips.py"),
        ("TOWER pillar reflection art PILREFD (twrpilref)", "make_pilref_img.py"),
        # The two PILLARS got reflections on 2026-09-10, and those cost no art
        # at all - m_flipv plus a non-square oscale on the pillar's own tile.
        # Three things can rot: the derived base positions, TWR_PHDR (the
        # R2HDRS index the tile is read from - point it at the wrong header and
        # the stage reflects some other piece of art), and the drawn height,
        # which grows DOWNWARD off the marble onto the carpet if the tile is
        # ever re-cut taller.
        ("TOWER3 pillar reflection alignment", "tower3_pillar_reflect.py"),
        # The backdrop - wall, arch, clouds and monk - got reflected
        # 2026-09-10 from src/TWRBKREF.ASM, which this regenerates and
        # compares. It is derived from BGNDTBL.ASM (the wall's blocks and
        # headers), BGND.ASM (the module's placement and the floor's skew y),
        # four palettes, MKDISP's floor_x and the runner in MKFLOORS.IMG -
        # and it also proves the wall's per-block ysteps tile exactly, column
        # by column, because at a shared 1/6 step they would crack.
        ("TOWER3 backdrop reflection data", "tower3_backdrop_reflect.py"),
        # data/TWRJNT.BIN - THE TOWER's floor joints + carpet, drawn back over
        # the reflection by twr_runner_code - is derived from FL_TOW.BIN (the
        # floor's own texture) and twr_runner_tbl (TWRBKREF.ASM, above).  If
        # either moves and the BIN does not, the joints stop lining up with
        # the marble under them and the runner drifts off its own carpet.
        ("TOWER floor joints texture", "make_twrjnt_bin.py"),
        # data/ARNSKY.BIN + src/ARNSKYEQ.ASM - KAHN'S ARENA's sky as one raw
        # texture for sky_rows.  Derived from ARENA.BDB/.BDD and arena_mod; if
        # either moves and the texture does not, the haze draws the old sky.
        ("KAHN'S ARENA sky texture", "make_arnsky_bin.py"),
        ("stock BGNDTBL SAGs", "promote_bgndtbl_stock_sags.py"),
        ("anonymous BGNDTBL SAGs", "sync_bgndtbl_sags.py"),
        ("MK1PIT background split tables", "refresh_mk1pitbg.py"),
        # THE CAVE: the pack BDB/BDDs must still be the deal of data/MK3CAVE,
        # and src/MK3CAVBG.ASM must still be the merge of the four snapshots -
        # a header mapped to the wrong image draws another block's pixels.
        ("THE CAVE pack tables", "make_mk3cave.py"),
        # THE PIT (MK1): the sky IMGs must still be MK1's art out of mk.zip, the
        # packs the deal of data/KUNGFU5, every LOD the tool's own, and
        # src/MK1PTOPB.ASM the merge of the snapshots with TPLHDRS.
        ("THE PIT (MK1) sky, packs and tables", "make_mk1pit.py"),
        # THE WARRIOR SHRINE (MK1): data/KUNGFU1 must still be MK1's shipped
        # shrine (blocks, pixels, palettes against mk.zip), the packs its deal,
        # and src/MK1WSHRB.ASM the merge of the snapshots with THE PIT's SAGs.
        ("THE WARRIOR SHRINE (MK1) packs and tables", "make_mk1shrine.py"),
        # THE THRONE ROOM (MK1): the packs must still be the tool's deal of the
        # 45 images it decodes out of mk.zip, every LOD its own, and
        # src/MK1THRNB.ASM the merge of the four snapshots - and every packed
        # record must still decode back to MK1's own pixels.
        ("THE THRONE ROOM (MK1) packs and tables", "make_mk1throne.py"),
        # THE COURTYARD (MK1, Wolf only): packs, monk IMG, src/MK1CRTB.ASM, and
        # every packed record decoding back to MK1's own pixels.
        ("THE COURTYARD (MK1, Wolf) packs and tables", "make_mk1court.py"),
        ("PALACE GATES (MK1, Wolf) packs and tables", "make_mk1gates.py"),
        ("SCORPION'S LAIR (UMK3, Wolf) packs, floor and tables", "make_umk3lair.py"),
        ("JADE'S DESERT (UMK3, Wolf) packs, floor and tables", "make_umk3desert.py"),
        ("THE SOUL CHAMBER + THE PIT 3 (UMK3, Wolf) packs and tables", "make_umk3stages.py"),
        ("THE PIT III throne Kahn (Wolf) pack and table", "make_pit3kahn.py"),
        # MK3 Sonya (Wolf only): data/UMK3SNYA.IMG + data/UMK3SNY.LOD still
        # umk3.zip's, and every ochar table still carries her Wolf row.
        ("MK3 SONYA (Wolf) art library and pack", "make_umk3sonya.py"),
        ("MK3 NIGHTWOLF (Wolf) art libraries, packs and table", "make_nightwolf.py"),
        ("MK3 NIGHTWOLF (Wolf) lanes", "make_nightwolf_asm.py"),
        ("MK3 ROBOT SMOKE (Wolf) art libraries, packs and table", "make_robosmoke.py"),
        ("MK3 ROBOT SMOKE (Wolf) lanes", "make_robosmoke_asm.py"),
        ("MK3 SONYA (Wolf) lanes", "make_umk3sonya_asm.py"),
        ("UMK3 SINDEL (Wolf) art libraries and packs", "make_umk3sindel.py"),
        ("UMK3 SINDEL (Wolf) lanes", "make_umk3sindel_asm.py"),
        ("the flesh rip (Wolf) frames and lanes", "make_fleshrip.py"),
        # MK1 Kano (Wolf only): data/MK1KNO.LOD is still KANO1-9.IMG's and the
        # morph's, and src/MK1KNL.ASM still Liu Kang's lanes on his frames.
        ("MK1 KANO (Wolf) pack and lanes", "make_mk1kano_port.py"),
        # Attract story + bio backgrounds (Wolf): src/WSTORY.ASM still the
        # WSTORY snapshot, and its palettes still BGNDPAL.ASM's.
        ("attract story + bio backgrounds (Wolf)", "make_wolf_story.py"),
        # Attract profiles (Wolf): src/UPPROF.ASM still UPPROF.IMG's palettes,
        # the two layouts on WSTORY.ASM's headers, and the current UPPROF.TBL.
        ("attract profile portraits + layouts (Wolf)", "make_upprof.py"),
        ("UMK3 SINDEL (Wolf) costumes from MK2PALS.IMG", "make_sindel_palettes.py"),
        ("Wolf-only fighter rows", "wolf_fighter_rows.py"),
        # Sonya's / Sindel's UMK3 audio: sound/wolf_patch.txt, the raw .dcs
        # streams and src/WOLFSND*.ASM still match MK3's tables and umk3.zip.
        ("Wolf sound overlay (UMK3 Sonya/Sindel)", "make_wolf_audio.py"),
        # Shang -> Sindel select-box wipe palettes (Wolf): src/SNBOXPAL.ASM is
        # still MKBOXES.IMG's SNSTBOX_P and its dimmed twin.
        ("Sindel box-wipe palettes (Wolf)", "make_snbox_pals.py"),
        # THE THRONE ROOM's empty throne, drawn when Shang Tsung is fighting:
        # data/THRCHP.IMG must still be the patch cut out of MKBGANI.IMG's
        # thrnchair, thrnchair must still sit where it was measured, and every
        # strip must decode back out of its IRW.
        ("THE THRONE ROOM empty throne patch", "make_thrnchair.py"),
        ("Armory MK7 background repair", "fix_armory_mk7_bg.py"),
        ("LOAD2 stray pixel bit repair", "fix_load2_bit_bleed.py"),
        ("MKSEL VS restore chunks", "sync_mksel_vs_restore.py"),
        # Baraka's Start+button alternates live only in data/UGMO1.IMG's
        # palette table - LOAD2 never emits them, because nothing in the LOD
        # references them (alt_pal_owner picks them at runtime). So they are
        # hand-carried into src/ and nothing else would notice them rotting.
        ("Baraka alt palettes", "sync_baraka_alt_pals.py"),
        # Jade's default costume palette, JDALTHP_P, has the same exposure:
        # it is a KAT1.IMG record nothing in the LOD references, so LOAD2 never
        # emits it and promote_tbls.py syncs table fields rather than IMGPAL
        # colour words. Repainting it in IMGTOOL changes data/KAT1.IMG and
        # nothing else, and the ROM keeps shipping the stale hand carry.
        ("Jade default palette", "sync_jade_pal.py"),
        # data/RAIN.IMG has no upstream: RAIN.IMG is not in either leak, so the
        # six frames are transcribed inside tools/make_rain_img.py and the IMG
        # is generated from them. Nothing else would notice a hand-edited IMG,
        # and a wrong one packs to a different size and slides every SAG.
        ("Yoteigai Tor rain IMG", "make_rain_img.py"),
        # data/CAVEYES.IMG has no upstream either: GORO'S LAIR's glowing eyes
        # are MK1's, so the six frames and the four-colour palette are
        # transcribed inside tools/make_caveyes_img.py and the IMG is generated
        # from them. Same exposure as RAIN: nothing else would notice a
        # hand-edited one, and a wrong one packs to a different size and slides
        # every SAG in the sidecar.
        ("Goro's Lair eyes IMG", "make_caveyes_img.py"),
        # data/ERMFIRE.IMG is generated from the UMK3 ROM the same way, and has
        # the same exposure: nothing else in the tree would notice a hand-edited
        # or half-rebuilt one, and a wrong IMG packs to a different size and
        # slides every SAG in the sidecar.  Skips itself if umk3.zip is absent.
        ("Ermac fireball IMG", "make_ermfire_img.py"),
        # data/RAINBOLT.IMG is generated from the MK Trilogy N64 source tree the
        # same way - a hand edit or stale regeneration packs to a different size
        # and slides every SAG in the sidecar.  Skips itself if the tree is absent.
        ("Rain lightning bolt IMG", "make_rainbolt_img.py"),
        # ...and src/RAINBOLT.TBL, the sidecar's HAND-CARRIED headers.  Nothing
        # in Phase B promotes them, so they go stale silently whenever the IMG's
        # geometry or record set changes - twice so far.
        ("Rain lightning bolt TBL", "check_rainbolt_tbl.py"),
        # data/RAINCLD.IMG (the water move's storm cloud) - same source, same
        # exposure; its --check also guards RNCLOUD_P / RNDROP_P in IMGPAL6.
        ("Rain storm cloud IMG", "make_raincld_img.py"),
        # ...and the WATER BUBBLE the man it catches hangs in.  The art is
        # ("Rain water bubble IMG", "make_rainbub_img.py") was here.  RETIRED
        # 2026-09-29: data/RAINBUB.LOD is out of data/IMGBUILD.BAT, so LOAD2
        # never reads data/RAINBUB.IMG and regenerating it every build bought
        # nothing.  The tool and the IMG are both KEPT as the restore path -
        # see src/MAINEQU.ASM's rainbub note.  Put this line back with the LOD:
        # its --check is what proves the records still match the generator AND
        # that RNCLOUD_P is still one rising ramp, since the art is PON> on the
        # cloud's palette and a re-index would draw it in the wrong shades with
        # a perfectly green build.
        # RNUMK1_P (Rain's default costume) is hand-carried from NINJAS10.IMG into
        # IMGPAL6.ASM; nothing promotes IMG palettes, so a recolour would ship stale.
        ("Rain costume palette", "sync_rain_palette.py"),
        # SHAT3_P (KUNG LAO'S HAT AT BANK ANGLE - SLICEHAT1-6/13-16, packed by
        # data/SLICEHAT.LOD) is hand-carried out of HATHED12.IMG into IMGPAL6.ASM
        # the same way, and it is NOT the palette the hat normally wears: hat_proc
        # swaps to it for the flight, so a recolour that never reached the ROM
        # would change colour halfway through the throw and nowhere else.
        ("Kung Lao hat angle palette", "sync_slicehat_pal.py"),
        # ...and that the eleven bank frames still place the hat in a smooth ramp.
        # One frame per bank and the stick walks up and down it, so two neighbours
        # that disagree about where the hat sits make it JUMP as the bucket changes
        # - and every frame is individually valid, so nothing else would notice.
        # SLICEHAT16 shipped 36px out of line once and the hat leapt 40px.
        ("Kung Lao hat frame placement", "slicehat_expect.py"),
        # HATGBL_P (KUNG LAO'S VICTORY HAT GLEAM - TMHATGLEAM1-6) is hand-carried
        # out of HATHED10.IMG into IMGPAL7.ASM.  That section of data/MK2MIL.LOD is
        # POF>, so the records carry no palette field and hh_victory assigns this one
        # to the gleam's own object; a recolour in IMGTOOL reaches the ROM through
        # nothing else, and the gleam was grey for years because no binding existed.
        ("Kung Lao hat gleam palette", "sync_hatgleam_pal.py"),
        # SCORE2_P out of MKSCORE.IMG into IMGPAL6.ASM - the MEDAL5 win medals
        # under the life bars.  Hand-carried, so a recolour must not ship silently.
        ("win medal palette", "sync_score2_pal.py"),
        # discqr_rows (MKAMODE.ASM) is the attract Discord page's QR code, encoded
        # from INVITE_URL in the tool.  A hand edit or a changed invite must not ship
        # a code that scans to the old link - or to nothing.
        ("Discord page QR code", "make_discord_qr.py"),
        # The Start+button costume palettes that are hand-carried out of the IMG
        # libraries: the five ninjas' UMK costumes (NINJAS3.IMG) and Kitana's
        # SILVER (KAT104.IMG).  RNUMK2_P is in THIS set, not sync_rain_palette.py's.
        ("Alternate costume palettes", "sync_alt_costume_palettes.py"),
        # a_rain_suprh (MKNJ.ASM) is generated from data/RAINSUPROUND.WAX - the
        # knee -> super roundhouse link; an edited project must not ship stale.
        ("Rain super roundhouse lane", "rain_suprh_wax_import.py"),
        # a_lkdubknee (MKLK.ASM) is generated from DUBLKNEESQ, the sequence
        # embedded in data/KANG3.IMG - LIU KANG'S DOUBLE KNEE.  Its holds are
        # PREVIEW ticks x4, and reading them as game ticks once already shipped
        # the carry-on at twice its authored rate, so the lane is generated and
        # this fails the build if the two drift.
        ("Liu Kang double knee lane", "lk_dubknee_seq_import.py"),
        # ...and the SPIKE it ends in: where lk_spike (MKLKDK.ASM) puts the
        # victim, upside down, and how long, from data/KANGDBLKNEE.WAX.  Its
        # check also fails if the WAX's Liu Kang lane stops matching the
        # DUBLKNEESQ lane above, which is what the victim is timed against.
        ("Liu Kang double knee spike", "lk_dknee_wax_import.py"),
        # a_fan_swipe's parts 3 and 4 (MKFN.ASM) and do_fan_decap's timing
        # equates (MKDEATH.ASM) are generated from FANSWIPESQ, the sequence
        # embedded in data/KAT9.IMG - KITANA'S FAN DECAPITATION swinging out
        # AND BACK.  Same preview-tick trap as the double knee above, and its
        # --check also fails if the sequence stops being the out-and-back the
        # two slices are cut on.
        ("Kitana fan decap return half", "fan_swipe_seq_import.py"),
        # The victim half of RAIN's lightning fatality (MKRAINF.ASM) comes from
        # data/RAINSPLIT.WAX, and its --check also proves every fighter still has
        # the 039h/041h frames the split looks up in his own art.
        ("Rain lightning fatality split", "rain_split_wax_import.py"),
        # JADE's staff impale (do_jade_impale, MKDEATH.ASM): her body lane, the
        # staff lane, the staff's palette and the tip the victim is dropped on
        # are all generated from data/JDIMPALE2.WAX - an edited project must not
        # ship stale.
        ("Jade staff impale lanes", "jade_impale_wax_import.py"),
        # JOHNNY CAGE's brain punch (do_jc_headhole, MKDEATH.ASM): where each
        # victim stands so the fist is in his head is jch_place, generated from
        # data/CAGEBRAIN.WAX - an edited project must not ship stale.
        ("Cage brain punch lineup", "cage_brain_wax_import.py"),
        # SHANG TSUNG's blade decapitation (do_st_decap, MKDEATH.ASM): how far
        # in front of him each body stands so the blade is in its neck is
        # stdc_place, MEASURED off STLAUGHFAT13's blade and each body's first
        # a_decapfall frame - re-exported art must not ship a stale spacing.
        ("Shang blade decap lineup", "st_decap_lineup.py"),
        # ERMAC's telekinetic head rip (MKERFAT.ASM): his lane (MKNJ), its holds,
        # the beats and the head's whole flight, plus the headless-torso parts
        # of row 039h in all nine fighter modules, are generated from
        # data/ERMACFAT2.WAX - an edited project must not ship stale.
        ("Ermac head rip fatality", "ermac_headrip_wax_import.py"),
        # UMK3's exploding-body blood burst (BLDXPD1-13), decoded 1:1 out of
        # C:/MAME/roms/umk3.zip by tools/make_bldxpd_img.py - the same
        # generated-from-the-arcade discipline as the fireball above, so a hand
        # edit or a stale regeneration of data/BLDXPD.IMG fails the build.
        ("UMK3 blood burst IMG", "make_bldxpd_img.py"),
        # Shao Kahn's stone-crack frames 1, 2 and 4-7 as the shared statue plus
        # crack-only patches, generated from data/BOSS7.IMG and proved pixel-exact
        # against the original pieces by tools/make_stonecrk_img.py - a hand edit
        # or stale regeneration of data/STONECRK.IMG fails the build.
        ("Kahn stone-crack overlay IMG", "make_stonecrk_img.py"),
        # Johnny Cage's OTOMIX logo cut into pieces of its own (data/JCLOGO.IMG)
        # and the pieces it came off put back to Midway's pants, proved pixel-
        # exact (piece + logo == the painted art) by tools/make_cage_logo.py,
        # which also fails if any frame list draws a logo'd piece without its
        # logo, or the walker's slot constants no longer match the LOD.
        ("Cage OTOMIX logo cut", "make_cage_logo.py"),
        # Kintaro's stomp art.  The TIGERJUMP1A-4D strips had been SHRUNK in
        # this tree (0.8 on frames 1-3, 0.64 on frame 4) when the small arena
        # prop SMTIGERJUMP1-4 was authored into the same IMG, so he dropped on
        # Shang Tsung two thirds his fight size and the in-fight stomp shrank
        # with him.  This fails the build if they ever stop matching Midway's
        # art in the read-only tree.  See doc/KINTARO_STOMP_ART.md.
        ("Kintaro stomp art", "restore_tigerjump.py"),
        # BLDXPD now changes depth within its framew lane. Validate decoded
        # pixels and the linked-source controls, not just the authored IMG.
        ("UMK3 blood burst packing", "check_bldxpd_packing.py"),
        # NOOBPORT carries three sets at TWO depths: the vortex and the blast
        # at 5bpp, and Noob's own cast strips still at 6 because they are
        # fighter art in an effect-named sidecar.  Nothing in the LOD or the
        # table says which record belongs to which set, so the split is only a
        # contract while this decodes every record at the depth its own
        # control word claims and compares it to the authored IMG indices.
        ("Noob shadow portal packing", "check_noobport_packing.py"),
        # Sidecars repacked at a lower depth because every stored index fits
        # it (SHAOFIST 6 -> 5 bpp).  Decodes every record out of the shipped
        # IRW at its control word's depth, requires the repacked depth, and
        # compares with the authored IMG - so a LOAD2 depth override, a stale
        # table or a lossy repack fails here.
        ("Lower-depth sidecar packing", "check_lod_packing.py"),
        # The last six sprite headers nothing regenerates: three babality
        # records in MKBABY.ASM and three KLUDGE_* bolt records in MKRD.ASM,
        # all pointing at a bit offset inside somebody else's packed payload in
        # MK7MIL.  They are correct until that run reflows, and then they draw
        # whatever slid into the address - which is exactly what deleting the
        # dead STBURST block did to all six at once on 2026-09-12.  Anchored to
        # a promoted record now, with the packed bits under each one hashed.
        ("hand-carried inline SAGs", "sync_inline_sags.py"),
        # The system stack top (stckst, SYSEQU.ASM) is a fixed address and the
        # linker packs .bss upward without knowing it exists. When .bss grew
        # past it, MKHANG's variables sat in the live stack: every call wrote
        # over them (Ed's acid-drop body blitted as a magenta block) and every
        # write to them corrupted a return address. Reads the linked mk2.map.
        ("system stack clear of .bss", "check_stack_clearance.py"),
        # grab_screen (GAME OVER, barge-in, buy-in) zeroes the list heads in
        # RAM.ASM's baklst8..last_objlst block and leaves @dlists walking. A
        # stage list head declared anywhere else keeps pointing at a freed
        # object and the display draws the whole free pool: THE TOWER, then
        # PALACE GATES on a full-bar timeout (2026-10-10). Source-only.
        ("dlist heads inside grab_screen's block", "check_dlist_heads.py"),
        # THE TOWER is the only stage that stops floor_code drawing rows it
        # knows are painted over (skew_skip = 54), and what makes that safe is
        # that its own reflection lists are drawn AFTER floor_code. If that
        # ordering is ever changed, or another stage starts setting skew_skip
        # without being measured, the bare autoerase colour shows through the
        # floor. Source-only; the measurement itself is
        # tools/run_floor_skip_probe.py.
        ("floor-skip coverage basis", "floor_skip_audit.py"),
        # A callr / long jr to ANOTHER object carries a 16-bit word displacement
        # (+/-64KB) and GSPLNK wraps an overflow without a word.  MKDRONE's
        # callr check_block_bit did exactly that and was the intermittent Dead
        # Pool TRAP 30.  Exact: every type-25 relocation in every linked .OBJ,
        # recomputed against the map.
        ("cross-object PC-relative range", "check_pcrel_range.py"),
        # The Dead Pool stage fatality throws the victim into the acid BEHIND
        # the walkway, and that acid is only a band in the middle of the arena -
        # both ends of the back plane are the raised stone ledge under a
        # doorway. dp_acid_raw_lft/rgt (BGND.ASM) are read off DEDPOOL.BDB, so
        # re-cutting the BDD moves the pool without touching a line of source
        # and r_fall_in_slime quietly starts landing bodies on dry rock.
        ("Dead Pool acid band", "deadpool_acid_band.py"),
        # YOTEIGAI TOR's stage fatality has the same exposure and worse
        # consequences: it drops the victim 756 rows down mount1BMOD into the
        # sea at its foot, and peak_sea_y / peak_sea_lft/rgt / peak_sea_bot
        # (BGND.ASM) are all read off MOUNTAIN.BDB.  Re-cutting the BDD moves
        # the waterline, and the camera clamp with it - too low and the module
        # runs out of blocks and the autoerase colour shows as a black band
        # under the splash.
        ("Yoteigai Tor sea band", "peak_sea_band.py"),
        # Same idea, applied to how the game PLAYS rather than how it looks.
        # Every strike record, every blockstun constant, every combo window and
        # every ruleset switch is locked in doc/balance.lock; a diff fails the
        # build until it is regenerated deliberately. Before this, a damage
        # byte could change and the build stayed green.
        ("balance lock", "balance_lock.py"),
        # The hurt box is not authored anywhere - it is computed from the
        # sprite - so an art edit changes what a fighter can be hit by with no
        # diff in any file. balance.lock guards the numbers a human typed;
        # hurtbox.lock guards the ones the art decides, over the DEFENSIVE
        # lanes (stance, walk, duck, jumps, reactions, getups).
        ("hurtbox lock", "hurtbox_lock.py"),
        # src/SOULPAL.ASM is generated from the blend palettes and fighter
        # palettes it recolours (MKSOULS.ASM - Shang's souls).  A repaint of
        # any of them leaves the souls blending through the old colours with
        # no error anywhere unless this regenerates and compares.
        ("soul blend palettes", "make_soul_blend_pals.py"),
        # a_soul_shake (MKSOULS.ASM) is generated from data/TSHANGEND.WAX -
        # the IMGTOOL project is the choreography for Shang's shake while his
        # souls leave.  A saved project that nobody re-imported would leave
        # the ROM playing the old lane with no error anywhere.
        ("shang soul-escape shake", "shang_end_wax_import.py"),
        # src/SKSOULP.ASM is the same kind of file for SHAO KAHN'S SOUL RIP:
        # the green ramps its soul is drawn in, generated from the victim
        # palettes in data/MKSUCK.IMG.  A repaint there would otherwise leave
        # the soul green in last week's colours with nothing to say so.
        ("soul rip palettes", "make_soulrip_pals.py"),
        # src/MK2PALS.ASM and data/MK2PALS.IMG are retail's twelve mirror-match
        # costumes and their bloodied counterparts, on Start+HP
        # (character_palettes_4 / bloody_character_palettes_4 rows 0-11).  The
        # IMG is in no LOD, so LOAD2 never reads it and only the generated ASM
        # ships: a repaint in IMGTOOL would otherwise change nothing at all,
        # which is the same silent failure sync_jade_pal.py guards above.
        ("retail mirror costumes on Start+HP", "make_mk2pals.py"),
        # src/COSTPAL.ASM and the costume rows of MKGUYS.ASM's seven
        # character_palettes_N / bloody_character_palettes_N tables ARE
        # data/MK2PALS.IMG, read by tools/make_costume_palettes.py: every
        # fighter's <XX>MAIN_P / <XX>ALTn_P / <XX>BLDn_P on the lane that
        # matches.  Same silent failure as the entry above, one scale up - the
        # IMG is in no LOD, so a costume repainted or added in IMGTOOL reaches
        # nothing until the tool runs, and the build would stay green.
        ("costume palettes from MK2PALS.IMG", "make_costume_palettes.py"),
        # RAIDEN'S ELECTRICITY IS COLOURED BY HIS COSTUME
        # (raiden_elec_offer, MKGUYS.ASM), so the two are authored side by
        # side in data/MK2PALS.IMG: ELEC_P for RDMAIN_P, ELECRED_P for
        # RDALT1_P and ELECPRL_P for RDALT2-4_P.  ELECPRL_P exists ONLY in
        # that library - data/RAID8.IMG's ELECPUR_P is a different purple, 51
        # entries of 53 apart - and IMGPAL4.ASM is hand-maintained, so a
        # recolour of the current would ship the old colours silently.  This
        # also fails if one of the three leaves death_fade_excludes, which
        # would dim the bolts while the fighters stay lit.
        ("Raiden electric palettes", "sync_raiden_elec_palettes.py"),
        # src/SHOCKPAL.ASM is the SAME PAIRING on the VICTIM: the electrocution
        # flash is his own body repainted, and which of ALLDUDES.IMG's three
        # colours it is drawn in is Raiden's costume.  Midway drew all three
        # sets and wired only the blue one, so this carries the other 19
        # records and builds the two tables - and it also proves the blue table
        # in MKGUYS.ASM still agrees with its roster, because red and purple
        # are generated from the same one.
        ("Raiden shock flash colours", "make_shock_palettes.py"),
        # ...and the THIRD place his current shows: the ambient crackle over his
        # own body.  That art is painted against the COSTUME layout, so its hue
        # is one slot (63) of a costume palette - and data/MK2PALS.IMG gave all
        # five Raiden costumes the same crackle blue, so a red Raiden crackled
        # blue.  src/RDCRACK.ASM is a copy of each costume with that slot moved
        # to Midway's own crackle colour for the current, and this re-measures
        # WHICH SLOT off the art every run, so art that changes which index it
        # draws in fails the build instead of recolouring the wrong thing.
        ("Raiden body crackle colours", "make_raiden_crackle_palettes.py"),
        # ksr_script (MKSOULRP.ASM) IS data/SHAOSOULSUCK.WAX - Kahn's frames,
        # the victim's poses and offsets, and when the soul shows.  Editing
        # the project and not re-importing is the whole failure mode here,
        # and it looks like the game ignoring the edit.
        ("Kahn soul rip lane", "kahn_soulrip_wax_import.py"),
    ]:
        check = subprocess.run(
            [sys.executable, str(script_dir / "tools" / tool), "--check"],
            cwd=str(script_dir),
        )
        if check.returncode != 0:
            print(f"Error: {name} check failed (returncode {check.returncode})")
            sys.exit(check.returncode)

    # Every table indexed by ochar must have one row per fighter. A short one
    # is not a wrong number, it is a read past the end - a garbage code address
    # handed to `jump`, or a garbage tick count handed to prcslp. That is the
    # class the Jade(16) crash shipped as, and adding Ermac(17) made 45 more
    # tables short at once. Nothing checked this before, so it only ever got
    # found by playing the character.
    print("  Phase D: char-indexed table row count")
    char_table_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "audit_char_tables.py")],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if char_table_check.returncode != 0:
        print(char_table_check.stdout)
        print("Error: char-indexed table audit failed "
              f"(returncode {char_table_check.returncode})")
        sys.exit(char_table_check.returncode)
    print("  Phase D: char-indexed tables OK")

    # ani2's guards (MKUTIL.ASM) refuse a multipart piece whose size cannot be
    # real, and stop a piece list that will not fit the buffer it is going
    # into. They are what keeps a lost list terminator from marching 112-bit
    # nodes across .bss and ending in a 65535 x 65529 blit the DMA is still
    # running three minutes later - i.e. a cabinet reboot. They are only safe
    # while every piece and every list in the build is inside them, so measure
    # it: art that grows past a limit would go silently missing from a frame.
    print("  Phase D: ani2 piece limits")
    piece_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "audit_piece_sizes.py"), "--check"],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if piece_check.returncode != 0:
        print(piece_check.stdout)
        print("Error: art is outside ani2's guards "
              f"(returncode {piece_check.returncode})")
        sys.exit(piece_check.returncode)
    print("  Phase D: ani2 piece limits OK")

    # p_beware_return/a10/a11 are ONE slot each and drone_beware is re-entrant,
    # so a reaction handler that walks in with `jsrp drone_approach` is running
    # a loop that can dispatch a SECOND reaction and overwrite them. Exiting
    # such a handler through return_to_beware then resumes a loop whose process
    # -stack frame is already popped, and the frames drain until `retp` reads
    # the word above the process block and jumps into RAM - illegal_opcode's
    # `jauc $`. Reported from real play 2026-09-09 (Reptile vs the Noob drone).
    print("  Phase D: drone beware re-entry")
    beware_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "audit_beware_reentry.py"),
         "--check"],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if beware_check.returncode != 0:
        print(beware_check.stdout)
        print("Error: drone beware re-entry audit failed "
              f"(returncode {beware_check.returncode})")
        sys.exit(beware_check.returncode)
    print("  Phase D: drone beware re-entry OK")

    # death_fade_excludes (MKGUYS.ASM) is what keeps FIGHTERS lit while the
    # stage fades - through every fatality, every babality and Raiden's
    # lightning. A costume palette missing from it dims the fighter wearing
    # it, on screen, with no build error and nothing to see in any diff. That
    # shipped: Ermac darkened through his own fatality until it was reported,
    # and six more costumes added since retail had the identical defect that
    # nobody had noticed.
    print("  Phase D: fade-exclusion coverage")
    fade_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "audit_fade_excludes.py"), "--check"],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if fade_check.returncode != 0:
        print(fade_check.stdout)
        print("Error: fade-exclusion audit failed "
              f"(returncode {fade_check.returncode})")
        sys.exit(fade_check.returncode)
    print("  Phase D: fade exclusions OK")

    # The fruit fly asks for moves by NUMBER (flyinv, MAINEQU.ASM): the number is
    # an index into src/FLYMOVES.ASM, and tools/flybrain_moves.lua carries the same
    # order. Both come from the switch handlers in MOVES.ASM; if those change and
    # the pair is not regenerated, the fly asks for one move and gets another.
    print("  Phase D: fly move table")
    fly_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "make_fly_moves.py"), "--check"],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if fly_check.returncode != 0:
        print(fly_check.stdout)
        print("Error: fly move table is stale - run python tools/make_fly_moves.py "
              f"(returncode {fly_check.returncode})")
        sys.exit(fly_check.returncode)
    print("  Phase D: fly move table OK")

    # Khameleon's sai lanes are relocated in her TABLE2 (see doc/KHAMELEON.md).
    # A sai animation lookup that skips kham_sai_ani2 draws Jade's boomerang
    # instead - no crash, no build error, just the wrong art for a few frames.
    # That shipped once, on the shared hit/blocked impact tail.
    print("  Phase D: khameleon sai lane bias")
    kham_sai_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "audit_kham_sai_lanes.py")],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if kham_sai_check.returncode != 0:
        print(kham_sai_check.stdout)
        print("Error: khameleon sai lane audit failed "
              f"(returncode {kham_sai_check.returncode})")
        sys.exit(kham_sai_check.returncode)
    print("  Phase D: khameleon sai lanes OK")

    # Khameleon is a CPU-only opponent who fights as whichever female ninja she
    # currently has on (kham_fight_as_guise, MAINEQU.ASM), which routes twenty
    # of MKDRONE's char-table reads through kd_char_long/kd_char_word/
    # kd_ochar_jump. That is a per-character bias spread over many call sites -
    # exactly the shape that shipped her sai lanes broken above - so this
    # enumerates EVERY char-indexed table the drone reads and fails when one is
    # unclassified, on the wrong helper, or when the costume order and the
    # play-as order disagree.
    print("  Phase D: khameleon drone rows")
    kham_rows_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "audit_kham_drone_rows.py"),
         "--check"],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if kham_rows_check.returncode != 0:
        print(kham_rows_check.stdout)
        print("Error: khameleon drone row audit failed "
              f"(returncode {kham_rows_check.returncode})")
        sys.exit(kham_rows_check.returncode)
    print("  Phase D: khameleon drone rows OK")

    # WHICH special comes out. This is fatal on purpose, and it is fatal
    # because of what it caught: `joyskip` let Shang's 1-skull B,B match past
    # the two forwards of his 3-skull B,B,F,F and fire instead of it, and that
    # build passed the 25-battle stability sweep AND the behaviour lock,
    # because the wrong move coming out is neither a crash nor one of the ten
    # locked behaviours. Nothing else in this pipeline can see it.
    #
    # A new collision is always a bug - either a new special shares a prefix
    # with an existing one, or the matcher got looser. Both want a person.
    print("  Phase D: special-move command collisions")
    collision_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "combo_collision_audit.py")],
        cwd=str(script_dir), capture_output=True, text=True,
    )
    if collision_check.returncode != 0:
        print(collision_check.stdout)
        print("Error: a special can now fire instead of another one "
              f"(returncode {collision_check.returncode})")
        sys.exit(collision_check.returncode)
    print("  Phase D: command collisions OK")

    mkhangn_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "sync_load2_tables.py"),
         "--tables", "MKHANGN.TBL", "ACIDHANG.TBL",
         "--fields", "size,sag,ctrl,palette",
         "--check"],
        cwd=str(script_dir),
    )
    if mkhangn_check.returncode != 0:
        print(f"Error: MKHANGN/ACIDHANG hanger table check failed (returncode {mkhangn_check.returncode})")
        sys.exit(mkhangn_check.returncode)

    gorowalk_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "sync_load2_tables.py"),
         "--tables", "GOROWALK.TBL",
         "--fields", "size,sag,ctrl",
         "--check"],
        cwd=str(script_dir),
    )
    if gorowalk_check.returncode != 0:
        print(f"Error: GOROWALK sidecar table check failed (returncode {gorowalk_check.returncode})")
        sys.exit(gorowalk_check.returncode)

    # Cross-check that every promoted SAG actually lands inside the payload its
    # own sidecar wrote. The promoters each verify their own table; nothing
    # verified tables AGAINST payloads until 2026-08-10, which is how a LOD
    # rebase could silently leave a table pointing at whatever moved in
    # underneath it. Cheap (~1s) and it caught two real cases the day it was
    # written - see tools/check_sag_coverage.py.
    sag_coverage_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "check_sag_coverage.py"), "--check"],
        cwd=str(script_dir),
    )
    if sag_coverage_check.returncode != 0:
        print(f"Error: SAG coverage check failed (returncode {sag_coverage_check.returncode})")
        sys.exit(sag_coverage_check.returncode)

    # LKREDRG_P / DRAGNRD_P in IMGPAL6.ASM are hand-copied out of
    # MKDRAGON.IMG's palette pool for the red-dragon flame fatality. Nothing
    # promotes them, so an imgtool recolour would leave the ROM drawing the old
    # ramp with no error anywhere. This already happened once: palrec 5 was
    # renamed LKDRAG_P -> LKREDRG_P and recoloured while the ASM kept the leak's
    # values.
    dragon_pal_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "sync_dragon_palettes.py"), "--check"],
        cwd=str(script_dir),
    )
    if dragon_pal_check.returncode != 0:
        print(f"Error: dragon palette check failed (returncode {dragon_pal_check.returncode})")
        sys.exit(dragon_pal_check.returncode)

    # ROBOFIRE.TBL is LOAD2-generated, but that is NOT enough to keep it
    # honest: promote_tbls.py syncs a record's SAG and control word and never
    # its `.word W,H,anix,aniy`, so re-anchoring a frame in HORNBUCK.IMG
    # updates tmp/load2 and leaves src/ carrying the old anipoint with no
    # error anywhere. That is exactly what happened when ROBOFIRE5 moved from
    # -53,-19 to -51,-20 - the ROM kept drawing the blast on the old anchor.
    robofire_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/HORNBUCK.IMG", "src/ROBOFIRE.TBL", "--check"],
        cwd=str(script_dir),
    )
    if robofire_anipoint_check.returncode != 0:
        print(f"Error: ROBOFIRE anipoint check failed (returncode {robofire_anipoint_check.returncode})")
        sys.exit(robofire_anipoint_check.returncode)

    # MK1SKULL.TBL is hand-maintained (no promoter writes it), but its
    # anipoints have to stay equal to MK1SKULL.IMG's - the scortch sequence
    # relies on the art carrying its own placement instead of a fudge constant
    # in MKFX.ASM. Nothing else would catch a drift here.
    anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/MK1SKULL.IMG", "src/MK1SKULL.TBL", "--check"],
        cwd=str(script_dir),
    )
    if anipoint_check.returncode != 0:
        print(f"Error: MK1SKULL anipoint check failed (returncode {anipoint_check.returncode})")
        sys.exit(anipoint_check.returncode)

    # NOOBPRJ.TBL / NOOBRING.TBL are hand-copied out of tmp/load2 like
    # MK1SKULL above, and Noob's ghost ball is placed ENTIRELY by the
    # anipoints in data/NOOBPROJ.IMG - do_noob_ghost's adjust_xy_a5 is
    # deliberately (0,0) so the art alone decides where the ball leaves his
    # hands and where the ring sits on the victim.
    #
    # That makes a stale table invisible and total: 2026-09-28 the artist
    # re-saved the IMG, every subsequent build was `--asm-only` (which SKIPS
    # Phase A, so LOAD2 never re-ran), and the ROM kept shipping anipoints
    # from an earlier pass - anix 40 against the IMG's -50 - for four builds
    # while the code was demonstrably doing nothing to them.  Nothing else in
    # the tree compares the two.
    for img, tbl, tag in (("data/NOOBPROJ.IMG", "src/NOOBPRJ.TBL", "NOOBPRJ"),
                          ("data/NOOBPROJ.IMG", "src/NOOBRING.TBL", "NOOBRING")):
        noob_anipoint_check = subprocess.run(
            [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
             img, tbl, "--check"],
            cwd=str(script_dir),
        )
        if noob_anipoint_check.returncode != 0:
            print(f"Error: {tag} anipoint check failed "
                  f"(returncode {noob_anipoint_check.returncode})")
            print("       Re-run LOAD2 for that pack (a full `python build.py`,")
            print("       not --asm-only) and copy tmp/load2/*.TBL over src/.")
            sys.exit(noob_anipoint_check.returncode)

    # JCMK1BLD.TBL (Cage's headhole KHEART prop) is LOAD2-promoted for SAG and
    # control only, so a re-anchor in MK1BLOOD.IMG never reaches it:
    # KHEART6C/6D sat at the 2026-07-13 anipoints for two months after the IMG
    # moved them, and the heart's resting frames drew 5-9px off.
    kheart_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/MK1BLOOD.IMG", "src/JCMK1BLD.TBL", "--check"],
        cwd=str(script_dir),
    )
    if kheart_anipoint_check.returncode != 0:
        print(f"Error: JCMK1BLD anipoint check failed (returncode {kheart_anipoint_check.returncode})")
        sys.exit(kheart_anipoint_check.returncode)

    # MKSOUL1.TBL is hand-maintained the same way, and for the same reason:
    # the soul-suck corpse drop is positioned entirely by CORPSEDROP1-8's own
    # anipoints (a_corpse_drop in MKFX.ASM has no adjustxy fudge), so a
    # re-export of MKSOUL1.IMG that moves an anchor must move the table too.
    soul_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/MKSOUL1.IMG", "src/MKSOUL1.TBL", "--check"],
        cwd=str(script_dir),
    )
    if soul_anipoint_check.returncode != 0:
        print(f"Error: MKSOUL1 anipoint check failed (returncode {soul_anipoint_check.returncode})")
        sys.exit(soul_anipoint_check.returncode)

    # SZSPINE.TBL is promoted (promote_tbls.py owns its SAG/CTRL), but the
    # promoter never touches the `.word sizx,sizy,anix,aniy` line - and the
    # whole Sub-Zero head-rip placement lives in those anipoints. The spine and
    # head are anchored to Sub-Zero by match_ani_points with no offset constant
    # anywhere in MKDEATH.ASM, so an IMG re-export that moves an anchor without
    # moving the table would silently misplace both props.
    szspine_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/SPINERIP.IMG", "src/SZSPINE.TBL", "--check"],
        cwd=str(script_dir),
    )
    if szspine_anipoint_check.returncode != 0:
        print(f"Error: SZSPINE anipoint check failed (returncode {szspine_anipoint_check.returncode})")
        sys.exit(szspine_anipoint_check.returncode)

    # Where those anipoints and the head lane's ani_adjustxy rows PUT the props,
    # in facing space off Sub-Zero's anchor - what run_sz_headrip_test.ps1
    # asserts so "the hand is over the head" is a number and not a screenshot.
    # It also fails if Sub-Zero's own head-rip poses move, because the fist
    # boxes the expectation is judged against were measured off those frames.
    # Where his hand attaches, per victim: the authored WAX against the table
    # MKNJ.ASM carries.  Edit the WAX, re-run the tool - never the block.
    print("  Phase D: Sub-Zero head-rip per-victim reach (SUBSPINE.WAX)")
    szhr_reach_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "subspine_wax_import.py"), "--check"],
        cwd=str(script_dir),
    )
    if szhr_reach_check.returncode != 0:
        print(f"Error: SUBSPINE.WAX reach table failed (returncode {szhr_reach_check.returncode})")
        sys.exit(szhr_reach_check.returncode)

    print("  Phase D: Sub-Zero head-rip prop alignment")
    szhr_align_check = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "szhr_align_expect.py"), "--check"],
        cwd=str(script_dir),
    )
    if szhr_align_check.returncode != 0:
        print(f"Error: head-rip alignment expectation failed (returncode {szhr_align_check.returncode})")
        sys.exit(szhr_align_check.returncode)

    # The SHAOFIST anipoint check was here.  src/SHAOFIST.TBL was retired
    # 2026-09-29 with data/SHAOFIST.LOD (see src/MAINEQU.ASM's kfistpulp note),
    # so there is no merged table left to drift.  data/SHAOFIST.IMG is still on
    # disk as the restore path; if the pulp is ever re-packed, put this check
    # back with it - the drift it caught (2026-08-17, a re-export that MOVED an
    # anipoint on an existing record, which the merge never rewrites) is a
    # property of the merge, not of that one export.

    # JADERANG.TBL is hand-maintained and only HALF of it tracks the IMG.
    # JDTHROWBLADE2-4 and BRANG1-3 are Jade's boomerang RELEASE path: their
    # JADERANG.IMG anipoints are authored on her own origin, in lockstep with
    # the throw poses, and `ani` turns the frame-to-frame deltas into the
    # blade's actual travel out of her hand - so an IMG re-anchor that does
    # not reach the table silently moves the blade off her hand, and nothing
    # else in the build would notice (promote_tbls merges SAG/control only and
    # deliberately never rewrites `.word W,H,anix,aniy`). BRANG4-9 and
    # BRTRAIL1-6 are excluded on purpose: those loop, a looping sequence must
    # net to zero, so the source table carries spin pivots instead of the
    # IMG's world-motion layout. See the header comment in src/JADERANG.TBL.
    jaderang_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/JADERANG.IMG", "src/JADERANG.TBL", "--check",
         "--only", "JDTHROWBLADE2,JDTHROWBLADE3,JDTHROWBLADE4"],
        cwd=str(script_dir),
    )
    if jaderang_anipoint_check.returncode != 0:
        print(f"Error: JADERANG release-path anipoint check failed "
              f"(returncode {jaderang_anipoint_check.returncode})")
        sys.exit(jaderang_anipoint_check.returncode)

    # The BLADE half of src/JADERANG.TBL comes from data/JDUMK3.IMG (the UMK3
    # arcade art), and JADERANG.TBL is NOT in promote_tbls' GENERATED_TABLES -
    # nothing in the build regenerates it. So an anipoint re-authored in the
    # IMG reaches the editor and NOT the ROM, silently, and the move keeps
    # running with the old anchors. That is exactly what happened 2026-09-01
    # when UBREL1-4 were re-anchored as a release travel path: the IMG said
    # (46,-13) (24,-5) (-37,-2) (-85,-27) while the table still said the
    # arcade's (54,-9) (23,3) (-43,-1) (25,5).
    #
    # UBREL4 -> UBSPIN1 is also load-bearing in code: jade_boomerang_proc's
    # release handoff hardcodes that anipoint STEP as adjust_xy_a5 112,39.
    # Change these anchors and that constant has to move with them.
    jdumk3_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/JDUMK3.IMG", "src/JADERANG.TBL", "--check"],
        cwd=str(script_dir),
    )
    if jdumk3_anipoint_check.returncode != 0:
        print(f"Error: JDUMK3 blade anipoint check failed "
              f"(returncode {jdumk3_anipoint_check.returncode})")
        sys.exit(jdumk3_anipoint_check.returncode)

    # MKSA2.TBL is merged, not copied, so Baraka's blade spark is exposed to
    # exactly the drift SHAOFIST hit: promote_tbls owns the SAG and control
    # word and deliberately never rewrites `.word W,H,anix,aniy`. The
    # anipoints are only HALF the spark's placement: a_saprojani is three
    # separately anchored groups and MKZAP.ASM adds a code offset to two of
    # them - UGSPARK1-2 form in his hands off multi_adjust_xy a1=-0ch in
    # do_sa_zap, UGSPARK3-4 are the flight loop and take no offset at all
    # (travel is set_proj_vel, not anipoint deltas), and UGSPARK5-11 are the
    # hit burst placed by multi_adjust_xy a0=-080h in spark_hit. A table
    # anipoint that drifts from the IMG therefore moves the art off whatever
    # constant its own group was authored against. Scoped with --only because
    # the rest of MKSA2.TBL is stock leaked geometry that is 1:1 with retail
    # and must not be policed against a re-exported IMG. Caught 2026-08-20,
    # when UGSPARK1-11's composites were re-anchored in UGMO8.IMG: the strips
    # that actually ship kept their old anchors, and nothing in the build
    # noticed. UGSPARK7B/8B/8C/11B are left out on purpose - they exist in
    # UGMO8.IMG but are in neither MK3MIL.LOD nor the UGSPARK7/8/11 frame
    # lists, so those three composites ship as only part of their authored art.
    ugspark_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/UGMO8.IMG", "src/MKSA2.TBL", "--check",
         "--only", "UGSPARK1A,UGSPARK2A,UGSPARK3A,UGSPARK3B,"
                   "UGSPARK4A,UGSPARK5A,UGSPARK6A,UGSPARK7A,"
                   "UGSPARK8A,UGSPARK9A,UGSPARK9B,UGSPARK10A,"
                   "UGSPARK10B,UGSPARK11A"],
        cwd=str(script_dir),
    )
    if ugspark_anipoint_check.returncode != 0:
        print(f"Error: UGSPARK anipoint check failed "
              f"(returncode {ugspark_anipoint_check.returncode})")
        sys.exit(ugspark_anipoint_check.returncode)

    # Same table, same exposure, different art: UGSWORDKICK1A..6B are Baraka's
    # scissor leg grab (a_sa_leggrab / do_sa_leggrab). data/UGMO9.IMG carries a
    # two-strip re-cut of the leaked three/four-way one, and the strips shipped
    # with anipoints that did not reassemble the pose - the head landed a
    # frame-height away from the body. They were re-anchored so every pose puts
    # its ground contact (his feet in 1-2, the planted blade in 3-6) on the same
    # spot the stance stands on, which is the whole reason the move needs no
    # fudge constant in MOVES.ASM. promote_tbls owns their SAG and deliberately
    # never rewrites `.word W,H,anix,aniy`, so without this a re-export that
    # moves an anchor is silent. --resize is deliberate here: this art HAS been
    # re-cut, and the table has to follow the sizes too.
    swordkick_anipoint_check = subprocess.run(
        [sys.executable, str(script_dir / "img_anipoint.py"), "sync-tbl",
         "data/UGMO9.IMG", "src/MKSA2.TBL", "--check", "--resize",
         "--only", "UGSWORDKICK1A,UGSWORDKICK1B,UGSWORDKICK2A,UGSWORDKICK2B,"
                   "UGSWORDKICK3A,UGSWORDKICK3B,UGSWORDKICK4A,UGSWORDKICK4B,"
                   "UGSWORDKICK5A,UGSWORDKICK5B,UGSWORDKICK6A,UGSWORDKICK6B"],
        cwd=str(script_dir),
    )
    if swordkick_anipoint_check.returncode != 0:
        print(f"Error: UGSWORDKICK anipoint check failed "
              f"(returncode {swordkick_anipoint_check.returncode})")
        sys.exit(swordkick_anipoint_check.returncode)

    # boxlab is the PUBLIC face of the strike tables, and the point of it is
    # that whatever is published is what the ROM was built from. Nothing here
    # can enforce that - the checkout is a sibling repo with its own history
    # and is not always present - so this reports and never fails the build.
    # `--check` ignores the provenance stamp, so it only speaks up when the
    # DATA has actually moved and the public copy needs regenerating.
    boxlab_dir = script_dir.parent / "boxlab"
    if boxlab_dir.is_dir():
        print("  Phase D: boxlab public data freshness")
        boxlab_check = subprocess.run(
            [sys.executable, str(script_dir / "tools" / "boxlab_export.py"), "--check"],
            cwd=str(script_dir),
        )
        if boxlab_check.returncode != 0:
            print("  WARNING: the boxlab checkout no longer matches this build.")
            print("           Run 'python tools/boxlab_export.py' and review the")
            print("           diff before publishing. Not fatal - the ROM is fine.")
        else:
            print("  Phase D: boxlab public data OK")

    print("  Phase E: Export Freeplay FBNeo RAM address manifest")
    freeplay_addrs = subprocess.run(
        [sys.executable, str(script_dir / "tools" / "export_freeplay_addresses.py")],
        cwd=str(script_dir),
    )
    if freeplay_addrs.returncode != 0:
        print(f"Error: export_freeplay_addresses.py returned {freeplay_addrs.returncode}")
        sys.exit(freeplay_addrs.returncode)
    sys.exit(0)


if __name__ == "__main__":
    main()
