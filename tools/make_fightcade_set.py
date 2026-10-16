#!/usr/bin/env python3
"""
make_fightcade_set.py - the T-unit build as a SUBMITTABLE FBNeo / Fightcade set.

Why this is not just rom/mk2.zip
--------------------------------
`mamerom.py` ends with `crc_spoof.spoof_zip()`, which bends 4 bytes of padding
in every changed chip until its CRC32 equals RETAIL's - so FBNeo's own `mk2`
driver loads the build as if it were Midway's L3.1. That is fine for private
play and useless for inclusion: Fightcade matches games by set name, a set
that answers to `mk2` collides with the real game, and nobody can tell the two
apart by checksum. A set for inclusion is a CLONE of `mk2` under its own name,
with its own, REAL CRCs - exactly how FBNeo already carries `mk2ute`, `mk2p`
and `mk2chal` (src/burn/drv/midway/d_tunit.cpp).

What it writes (dist/fightcade/<set>/)
--------------------------------------
  <set>.zip              split clone set: only the chips that differ from
                         retail, named <set>.<chip> (FBNeo's hack convention).
                         The untouched chips load from the parent mk2.zip.
  <set>_standalone.zip   the same set non-merged (all 20 chips) for anyone
                         without the parent at hand. Same CRCs.
  fbneo_<set>.cpp        the BurnRomInfo table + BurnDriver block to paste
                         after BurnDrvMk2ute in d_tunit.cpp.
  fbneo_d_tunit.patch    (with --fbneo-src) that block as a unified diff
                         against an upstream d_tunit.cpp.
  <set>.dat              ClrMamePro/Logiqx XML entry, cloneof="mk2", with
                         crc / md5 / sha1 per chip.
  SHA256SUMS.txt         every file above.

What it proves before writing
-----------------------------
* THE PROGRAM ROM IS THE FIGHTCADE CUT, not rom/'s: src/ is copied to
  tmp/fightcade/, `hidearn` set to 0 there (Jade, Ermac and Rain from
  power-on), assembled + linked + laid out exactly as makerom.py does, and
  " FC" appended to the version string when it fits. src/ and rom/ are never
  touched, so the arcade build keeps EARNING them. `--as-played` packages
  rom/mk2_uj12/ug12.bin instead.
* Every video and sound chip is the one the user actually plays: it is
  compared with the installed rom/mk2.zip copy and may differ ONLY inside
  crc_spoof's 4-byte window (the spoof being taken off, nothing else).
  (`--as-played` checks the program chips the same way.)
* The program ROM is not older than src/mk2.out (a stale makerom run).
* The sound chips come from sound/mk2_stlaugh.zip - the patched set - and
  makesound.py's own staleness check must pass.
`--release` additionally refuses a PLAYTEST version string, a dirty tree, and
(with --as-played) `hidearn` on: FBNeo never loads NVRAM in a netplay session (drv.cpp DrvInit:
`if (kNetGame) ... else StatedAuto(0)`), so a fighter that must be EARNED into
CMOS can never be picked on Fightcade.

  python tools/make_fightcade_set.py                       # set mk2rev4
  python tools/make_fightcade_set.py --set mk2r40 --title "..."
  python tools/make_fightcade_set.py --fbneo-src path/to/d_tunit.cpp
  python tools/make_fightcade_set.py --release             # refuse a playtest
"""
import argparse
import difflib
import hashlib
import os
import re
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROM = os.path.join(ROOT, "rom")
RETAIL_ZIP = os.path.join(ROOT, "mk2.zip")
INSTALLED_ZIP = os.path.join(ROM, "mk2.zip")
SOUND_ZIP = os.path.join(ROOT, "sound", "mk2_stlaugh.zip")
MK2_OUT = os.path.join(ROOT, "src", "mk2.out")
DIAGMENU = os.path.join(ROOT, "src", "DIAGMENU.ASM")

# FBNeo's mk2RomDesc order, with the region flags and gfx placement it uses.
# (retail file name, size, short chip name, FBNeo flags)
LAYOUT = [
    ("l3.1_mortal_kombat_ii_game_rom_uj12.uj12", 0x080000, "uj12", "1 | BRF_PRG | BRF_ESS", "TMS34010"),
    ("l3.1_mortal_kombat_ii_game_rom_ug12.ug12", 0x080000, "ug12", "1 | BRF_PRG | BRF_ESS", ""),
    ("l1_mortal_kombat_ii_sound_rom_u2.u2", 0x080000, "u2", "2 | BRF_PRG | BRF_ESS", "DCS sound banks"),
    ("l1_mortal_kombat_ii_sound_rom_u3.u3", 0x080000, "u3", "2 | BRF_PRG | BRF_ESS", ""),
    ("l1_mortal_kombat_ii_sound_rom_u4.u4", 0x080000, "u4", "2 | BRF_PRG | BRF_ESS", ""),
    ("l1_mortal_kombat_ii_sound_rom_u5.u5", 0x080000, "u5", "2 | BRF_PRG | BRF_ESS", ""),
    ("l1_mortal_kombat_ii_sound_rom_u6.u6", 0x080000, "u6", "2 | BRF_PRG | BRF_ESS", ""),
    ("l1_mortal_kombat_ii_sound_rom_u7.u7", 0x080000, "u7", "2 | BRF_PRG | BRF_ESS", ""),
    ("l1_mortal_kombat_ii_game_rom_ug14.ug14", 0x100000, "ug14", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 0)", "GFX"),
    ("l1_mortal_kombat_ii_game_rom_uj14.uj14", 0x100000, "uj14", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 1)", ""),
    ("l1_mortal_kombat_ii_game_rom_ug19.ug19", 0x100000, "ug19", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 2)", ""),
    ("l1_mortal_kombat_ii_game_rom_uj19.uj19", 0x100000, "uj19", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 3)", ""),
    ("l1_mortal_kombat_ii_game_rom_ug16.ug16", 0x100000, "ug16", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 0)", ""),
    ("l1_mortal_kombat_ii_game_rom_uj16.uj16", 0x100000, "uj16", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 1)", ""),
    ("l1_mortal_kombat_ii_game_rom_ug20.ug20", 0x100000, "ug20", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 2)", ""),
    ("l1_mortal_kombat_ii_game_rom_uj20.uj20", 0x100000, "uj20", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 3)", ""),
    ("l1_mortal_kombat_ii_game_rom_ug17.ug17", 0x100000, "ug17", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 0)", ""),
    ("l1_mortal_kombat_ii_game_rom_uj17.uj17", 0x100000, "uj17", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 1)", ""),
    ("l1_mortal_kombat_ii_game_rom_ug22.ug22", 0x100000, "ug22", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 2)", ""),
    ("l1_mortal_kombat_ii_game_rom_uj22.uj22", 0x100000, "uj22", "3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 3)", ""),
]

# crc_spoof's window is 4 bytes; it may move backwards to find real padding
# (find_tail_padding_offset), so allow it anywhere in the chip's last 1 KB.
SPOOF_TAIL = 0x400


def die(msg):
    print("REFUSED: " + msg)
    sys.exit(1)


def git(*args):
    try:
        return subprocess.run(["git"] + list(args), cwd=ROOT, timeout=30,
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def rom_name():
    m = re.search(r'^rom_name\s+\.string\s+"([^"]*)"',
                  open(DIAGMENU, encoding="latin-1").read(), re.M)
    return m.group(1) if m else "?"


def load_chips():
    """The 20 chips as BUILT (never spoofed)."""
    chips = {}
    for name, size, short, _, _ in LAYOUT:
        if short in ("uj12", "ug12"):
            path = os.path.join(ROM, "mk2_%s.bin" % short)
            chips[name] = open(path, "rb").read()
        elif short.startswith("u") and short[1:].isdigit():
            pass  # sound, below
        else:
            chips[name] = open(os.path.join(ROM, name), "rb").read()
    with zipfile.ZipFile(SOUND_ZIP) as z:
        for name, _, short, _, _ in LAYOUT:
            if short[1:].isdigit() and short.startswith("u") and len(short) == 2:
                chips[name] = z.read(name)
    for name, size, *_ in LAYOUT:
        if len(chips[name]) != size:
            die("%s is %d bytes, expected %d" % (name, len(chips[name]), size))
    return chips


def check_against_installed(chips, names):
    """Each named chip must equal what the user plays, bar the spoof window."""
    if not os.path.exists(INSTALLED_ZIP):
        die("no rom/mk2.zip - run mamerom.py first so there is a played set to match")
    with zipfile.ZipFile(INSTALLED_ZIP) as z:
        for name, size, *_ in LAYOUT:
            if name not in names:
                continue
            have, mine = z.read(name), chips[name]
            cut = size - SPOOF_TAIL
            if have[:cut] != mine[:cut]:
                die("%s differs from rom/mk2.zip before its last 0x%X bytes - the "
                    "build and the installed set are not the same game; "
                    "rebuild/repackage first" % (name, SPOOF_TAIL))
            diff = [i for i in range(cut, size) if have[i] != mine[i]]
            if len(diff) > 4 or (diff and diff[-1] - diff[0] > 3):
                die("%s differs from rom/mk2.zip by %d tail bytes at 0x%X.. - more "
                    "than crc_spoof's 4-byte window" % (name, len(diff), diff[0]))


# ------------------------------------------------- the Fightcade program ROM
WORK = os.path.join(ROOT, "tmp", "fightcade")
FC_TAG = " FC"     # appended to rom_name when it fits (cmos holds 29 chars)


def fightcade_program(want_tag=True):
    """Assemble + link src/ in a PRIVATE copy with hidearn 0, return (even, odd, rom_name).

    FBNeo never loads NVRAM in a netplay session, so a fighter that must be
    EARNED into CMOS can never be picked on Fightcade: this build gives Jade,
    Ermac and Rain from power-on. src/, src/mk2.out and rom/ are not touched -
    the T-unit build keeps earning them. Same shape as makewolf.assemble().
    """
    import shutil
    sys.path.insert(0, ROOT)
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    from build import get_dosbox_path
    import makerom
    dosbox = get_dosbox_path()
    if not dosbox:
        die("DOSBox not found")

    src = os.path.join(ROOT, "src")
    newer = [f for f in os.listdir(src)
             if os.path.splitext(f)[1].upper() in (".ASM", ".TBL", ".GLO", ".HDR")
             and f.upper() != "FPADDR.ASM"      # Phase E writes it AFTER the link
             and os.path.getmtime(os.path.join(src, f)) > os.path.getmtime(MK2_OUT)]
    if newer:
        die("%d source file(s) newer than src/mk2.out (%s...) - build the T-unit "
            "first, so the Fightcade cut differs from it ONLY by hidearn"
            % (len(newer), ", ".join(sorted(newer)[:5])))

    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, "data"))
    os.makedirs(os.path.join(WORK, "tools"))
    shutil.copytree(src, os.path.join(WORK, "src"),
                    ignore=shutil.ignore_patterns("*.OBJ", "*.obj", "mk2.out", "*.LST",
                                                  "*.map", "*.MAP", "MCY*", "MCZ*"))
    for f in ("ART.OUT", "OART.OUT"):
        if os.path.exists(os.path.join(ROOT, "data", f)):
            shutil.copy2(os.path.join(ROOT, "data", f), os.path.join(WORK, "data", f))
    for f in os.listdir(os.path.join(ROOT, "data")):
        if f.upper().startswith("ED") and f.upper().endswith(".ASM"):
            shutil.copy2(os.path.join(ROOT, "data", f), os.path.join(WORK, "data", f))
    for f in ("GSPA.EXE", "GSPLNK.EXE", "GMAKE.EXE"):
        shutil.copy2(os.path.join(ROOT, "tools", f), os.path.join(WORK, "tools", f))

    me = os.path.join(WORK, "src", "MAINEQU.ASM")
    t = open(me, encoding="latin-1", newline="").read()
    t, n = re.subn(r"^(hidearn\s+\.set\s+)1-wunit", r"\g<1>0", t, flags=re.M)
    if n != 1:
        die("could not find 'hidearn .set 1-wunit' in MAINEQU.ASM - update this tool")
    open(me, "w", encoding="latin-1", newline="").write(t)

    dm = os.path.join(WORK, "src", "DIAGMENU.ASM")
    t = open(dm, encoding="latin-1", newline="").read()
    m = re.search(r'^rom_name\s+\.string\s+"([^"]*)"', t, re.M)
    name = m.group(1)
    if want_tag and len(name) + len(FC_TAG) <= 29:
        t = t[:m.end(1)] + FC_TAG + t[m.end(1):]
        name += FC_TAG
        open(dm, "w", encoding="latin-1", newline="").write(t)

    shutil.copy2(os.path.join(ROOT, "dosbox_asm.conf"), os.path.join(WORK, "dosbox_asm.conf"))
    print("  assembling the Fightcade cut (hidearn 0) in tmp/fightcade ...")
    if os.environ.get("MK2_GSPA_STAGE", "1") != "0":
        import gspa_stage
        wsrc = Path(WORK) / "src"
        mods = gspa_stage.modules_to_assemble(wsrc)
        failed = gspa_stage.assemble(wsrc, Path(WORK) / "asmstage", mods, str(dosbox),
                                     Path(WORK) / "asmstage.log")
        if failed:
            print("  staged assembly failed for %s - GMAKE retries them unpruned"
                  % ", ".join(failed))
    subprocess.run([str(dosbox), "-conf", "dosbox_asm.conf", "-noconsole", "-exit"],
                   cwd=WORK, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = open(os.path.join(WORK, "build.log"), encoding="latin-1", errors="replace").read()
    bad = [l for l in log.splitlines()
           if re.search(r"Errors|undefined|Out of memory|not built|Aborted", l)
           and "No Errors" not in l]
    out = os.path.join(WORK, "src", "mk2.out")
    if bad or not os.path.exists(out):
        print("\n".join(bad[:30]))
        die("Fightcade assembly failed - see %s" % os.path.join(WORK, "build.log"))

    sections = makerom.read_coff(Path(out))
    rom, placed = makerom.build_rom_image(sections)
    makerom.embed_revx_payloads(rom, Path(ROOT), placed)
    even, odd = makerom.interleave(rom)
    if not makerom.validate_capacity(len(even), len(odd), len(rom)):
        die("Fightcade program ROM over capacity")
    return bytes(even), bytes(odd), name


def check_fresh():
    if os.path.getmtime(os.path.join(ROM, "mk2_uj12.bin")) < os.path.getmtime(MK2_OUT):
        die("rom/mk2_uj12.bin is older than src/mk2.out - run makerom.py")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "makesound.py"), "--check"],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        die("sound/mk2_stlaugh.zip is stale - run makesound.py")


def hashes(data):
    return {"crc": "%08x" % (zlib.crc32(data) & 0xFFFFFFFF),
            "md5": hashlib.md5(data).hexdigest(),
            "sha1": hashlib.sha1(data).hexdigest(),
            "sha256": hashlib.sha256(data).hexdigest()}


def write_zip(path, members):
    # Fixed timestamps + stored order -> the same build gives the same zip bytes.
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for fname, data in members:
            zi = zipfile.ZipInfo(fname, date_time=(1993, 10, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)


def driver_block(setname, title, year, rows):
    ident = setname[0].upper() + setname[1:]
    lines = ["static struct BurnRomInfo %sRomDesc[] = {" % setname]
    prev_group = None
    for i, (fname, size, crc, flags, comment) in enumerate(rows):
        group = flags.split()[0]
        if prev_group is not None and group != prev_group:
            lines.append("")
        prev_group = group
        name = '"%s",' % fname
        tail = " //  %d%s" % (i, (" " + comment) if comment else "")
        lines.append("\t{ %-44s 0x%06x, 0x%s, %s },%s" % (name, size, crc, flags, tail))
    lines += [
        "};",
        "",
        "STD_ROM_PICK(%s)" % setname,
        "STD_ROM_FN(%s)" % setname,
        "",
        "struct BurnDriver BurnDrv%s = {" % ident,
        '\t"%s", "mk2", NULL, NULL, "%s",' % (setname, year),
        '\t"%s\\0", NULL, "hack", "Midway T-Unit",' % title,
        "\tNULL, NULL, NULL, NULL,",
        "\tBDF_GAME_WORKING | BDF_CLONE | BDF_HACK, 2, HARDWARE_MIDWAY_TUNIT, GBF_VSFIGHT, 0,",
        "\tNULL, %sRomInfo, %sRomName, NULL, NULL, NULL, NULL, Mk2InputInfo, Mk2DIPInfo," % (setname, setname),
        "    Mk2Init, TUnitExit, TUnitFrame, TUnitDraw, TUnitScan, &nTUnitRecalc, 0x8000,",
        "    TUNIT_SCREEN_WIDTH, TUNIT_SCREEN_HEIGHT, 4, 3",
        "};",
    ]
    return "\n".join(lines) + "\n"


def fbneo_patch(src_path, block):
    text = open(src_path, encoding="utf-8", newline="").read()
    anchor = re.search(r"struct BurnDriver BurnDrvMk2ute = \{.*?\n\};\n", text, re.S)
    if not anchor:
        die("--fbneo-src has no BurnDrvMk2ute block to insert after")
    nl = "\r\n" if "\r\n" in text else "\n"
    new = text[:anchor.end()] + nl + block.replace("\n", nl) + text[anchor.end():]
    return "".join(difflib.unified_diff(
        text.splitlines(True), new.splitlines(True),
        "a/src/burn/drv/midway/d_tunit.cpp", "b/src/burn/drv/midway/d_tunit.cpp"))


def dat_entry(setname, title, year, rows_full):
    out = ['<?xml version="1.0"?>',
           '<datafile>',
           '\t<game name="%s" cloneof="mk2" romof="mk2">' % setname,
           '\t\t<description>%s</description>' % title.replace("&", "&amp;"),
           '\t\t<year>%s</year>' % year,
           '\t\t<manufacturer>hack</manufacturer>']
    for fname, size, h, merge in rows_full:
        m = ' merge="%s"' % merge if merge else ""
        out.append('\t\t<rom name="%s"%s size="%d" crc="%s" md5="%s" sha1="%s"/>'
                   % (fname, m, size, h["crc"], h["md5"], h["sha1"]))
    out += ['\t</game>', '</datafile>']
    return "\n".join(out) + "\n"


def pr_description(setname, title, version, dat_rows, zip_crc):
    """The PR body, in the shape of fightcade-fbneo #16 (UMK3 BETA 2, merged)."""
    rows = "\n".join("| `%s` | 0x%06X | `%s` |" % (f, s, h["crc"]) for f, s, h, _ in dat_rows)
    return """\
Added "%(title)s" (`%(set)s`, clone of `mk2`).

A program, video and sound ROM replacement for the stock Midway T-unit board:
the same 20 chips at the same sizes, no new hardware. The driver entry is data
only - it reuses `Mk2Init`, `Mk2InputInfo` and `Mk2DIPInfo` - and is placed
after `BurnDrvMk2ute` in `src/burn/drv/midway/d_tunit.cpp`, flagged
`BDF_CLONE | BDF_HACK`.

Version string in the operator menu: `%(version)s`

The zip `%(set)s.zip` (CRC32 of the zip `0x%(zcrc)08X`) contains:

| file | size | crc32 |
|---|---|---|
%(rows)s

Every chip differs from L3.1, so all 20 are in the clone zip. md5/sha1 for each
are in the attached `%(set)s.dat`.

Notes for netplay:
- No wall clock or host-specific state is read. Coin-op by default.
- The hidden fighters (Jade, Ermac, Rain) are selectable from power-on in this
  set, because FBNeo does not load NVRAM in a netplay session.
- The unused "Comic Book Offer" DIP is BACK-BLOCK in this build (default On =
  holding away blocks; Off = block button only, as retail).
""" % {"title": title, "set": setname, "version": version, "zcrc": zip_crc & 0xFFFFFFFF,
       "rows": rows}


def hidearn_tunit():
    """True if the T-unit build makes hidden fighters EARNED (saved to CMOS)."""
    txt = open(os.path.join(ROOT, "src", "MAINEQU.ASM"), encoding="latin-1").read()
    m = re.search(r"^hidearn\s+\.set\s+(\S+)", txt, re.M)
    return bool(m) and m.group(1).replace("-wunit", "").strip() not in ("0",)


def reviewer_readme(setname, title, version, commit, dirty, dat_rows, earn):
    rom_lines = "\n".join("  %-14s %8d  crc %s  sha1 %s" % (f, s, h["crc"], h["sha1"])
                          for f, s, h, _ in dat_rows)
    return """\
%(title)s
FBNeo set: %(set)s  (clone of mk2, BDF_HACK)
Version string in the operator menu: %(version)s
Source commit: %(commit)s%(dirty)s

WHAT IT IS
  Mortal Kombat II L3.1 rebuilt from Midway's leaked source with new
  moves, fatalities, a competitive ruleset (juggle damage scaling, combo
  counting, back-block, perfect block, sudden death) and a stronger CPU.
  It is a program + video + sound ROM replacement for the STOCK T-unit
  board: the same 20 chips at the same sizes, no new hardware, no extra
  regions. It runs on FBNeo's existing mk2 hardware code unchanged -
  Mk2Init, Mk2InputInfo, Mk2DIPInfo - so the driver entry is data only.

FILES
  %(set)s.zip             the clone set (every chip differs from retail,
                         so all 20 are in it, named %(set)s.<chip>)
  %(set)s_standalone.zip  identical content; kept for symmetry with
                         future builds that share chips with the parent
  fbneo_%(set)s.cpp       BurnRomInfo + BurnDriver, to place after
                         BurnDrvMk2ute in src/burn/drv/midway/d_tunit.cpp
  fbneo_d_tunit.patch     the same as a diff against upstream d_tunit.cpp
  %(set)s.dat             Logiqx XML entry (crc/md5/sha1)
  SHA256SUMS.txt          checksums of every file here

ROMS
%(roms)s

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
  * Hidden fighters (Jade, Ermac, Rain): %(earn)s

CONTACT / PERMISSION
  <name, contact, and a statement that the author agrees to the set being
   included in FBNeo and Fightcade>
""" % {"title": title, "set": setname, "version": version,
       "commit": commit or "?", "dirty": "  (uncommitted changes)" if dirty else "",
       "roms": rom_lines,
       "earn": ("EARNED in 1P and saved to CMOS in this build - online they will "
                "NEVER be selectable. Rebuild with hidearn 0 for a Fightcade cut."
                if earn else "selectable from power-on in this build - the\n"
                "    arcade build earns them in 1P and saves that to CMOS, which FBNeo\n"
                "    does not keep across a netplay session, so this cut unlocks them.")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="mk2rev4", help="FBNeo set name (<= 8 chars is customary)")
    ap.add_argument("--title", default=None)
    ap.add_argument("--year", default="2026")
    ap.add_argument("--fbneo-src", help="upstream FBNeo d_tunit.cpp to diff against")
    ap.add_argument("--fightcade-src",
                    help="fightcadeorg/fightcade-fbneo d_tunit.cpp to diff against (the PR target)")
    ap.add_argument("--release", action="store_true",
                    help="refuse a PLAYTEST version string or a dirty tree")
    ap.add_argument("--as-played", action="store_true",
                    help="package rom/'s program ROM as built (hidden fighters EARNED) "
                         "instead of assembling the Fightcade cut")
    ap.add_argument("--no-tag", action="store_true",
                    help="do not append ' FC' to the version string of the Fightcade cut")
    ap.add_argument("--allow-earned", action="store_true",
                    help="with --release --as-played, accept hidden fighters that must be earned")
    ap.add_argument("--no-verify-installed", action="store_true",
                    help="skip the match against rom/mk2.zip (not for a submission)")
    a = ap.parse_args()

    setname = a.set.lower()
    if not re.fullmatch(r"[a-z0-9]{1,16}", setname):
        die("set name must be lower-case letters/digits")
    version = rom_name()
    rev = re.search(r"REV\s*([\d.]+)", version, re.I)
    title = a.title or "Mortal Kombat II (Rev %s, hack)" % (rev.group(1) if rev else "?")
    commit = git("rev-parse", "--short", "HEAD")
    dirty = bool(git("status", "--porcelain"))

    if a.release:
        if "PLAYTEST" in version.upper():
            die("version string is '%s' - a release must not say PLAYTEST" % version)
        if dirty or version.endswith("*)"):
            die("tree is dirty - cut a submission from a commit")
        if a.as_played and hidearn_tunit() and not a.allow_earned:
            die("hidearn is on: FBNeo skips NVRAM in netplay, so Jade/Ermac/Rain "
                "could never be picked on Fightcade. Set hidearn 0 and rebuild, "
                "or pass --allow-earned")

    check_fresh()
    chips = load_chips()
    prog = {LAYOUT[0][0], LAYOUT[1][0]}
    if not a.no_verify_installed:
        # video + sound always; the program only when it is the played one
        check_against_installed(chips, {n for n, *_ in LAYOUT}
                                if a.as_played else {n for n, *_ in LAYOUT} - prog)
    earned = hidearn_tunit() if a.as_played else False
    if not a.as_played:
        even, odd, version = fightcade_program(want_tag=not a.no_tag)
        chips[LAYOUT[0][0]], chips[LAYOUT[1][0]] = even, odd

    with zipfile.ZipFile(RETAIL_ZIP) as z:
        retail = {n: z.read(n) for n in z.namelist()}

    out_dir = os.path.join(ROOT, "dist", "fightcade", setname)
    os.makedirs(out_dir, exist_ok=True)

    rows, split, full, dat_rows, report = [], [], [], [], []
    for name, size, short, flags, comment in LAYOUT:
        data = chips[name]
        h = hashes(data)
        same = retail.get(name) == data
        fname = name if same else "%s.%s" % (setname, short)
        rows.append((fname, size, h["crc"], flags, comment))
        full.append((fname, data))
        if not same:
            split.append((fname, data))
        dat_rows.append((fname, size, h, name if same else None))
        report.append("  %-42s %s  %s" % (fname, h["crc"], "parent (retail)" if same else "CHANGED"))

    write_zip(os.path.join(out_dir, setname + ".zip"), split)
    write_zip(os.path.join(out_dir, setname + "_standalone.zip"), full)
    block = driver_block(setname, title, a.year, rows)
    open(os.path.join(out_dir, "fbneo_%s.cpp" % setname), "w", newline="\n").write(block)
    if a.fbneo_src:
        open(os.path.join(out_dir, "fbneo_d_tunit.patch"), "w", newline="").write(
            fbneo_patch(a.fbneo_src, block))
    if a.fightcade_src:
        open(os.path.join(out_dir, "fightcade_d_tunit.patch"), "w", newline="").write(
            fbneo_patch(a.fightcade_src, block))
    open(os.path.join(out_dir, "PR_DESCRIPTION.md"), "w", newline="\n").write(
        pr_description(setname, title, version, dat_rows,
                       zlib.crc32(open(os.path.join(out_dir, setname + ".zip"), "rb").read())))
    open(os.path.join(out_dir, setname + ".dat"), "w", newline="\n").write(
        dat_entry(setname, title, a.year, dat_rows))

    info = ["set        %s (clone of mk2)" % setname,
            "program    %s" % ("as played (rom/mk2_uj12/ug12.bin)" if a.as_played
                               else "Fightcade cut: hidearn 0, assembled in tmp/fightcade"),
            "title      %s" % title,
            "version    %s" % version,
            "commit     %s%s" % (commit or "?", "  (UNCOMMITTED CHANGES)" if dirty else ""),
            "", "chips"] + report
    open(os.path.join(out_dir, "BUILD_INFO.txt"), "w", newline="\n").write("\n".join(info) + "\n")

    open(os.path.join(out_dir, "README.txt"), "w", newline="\n").write(
        reviewer_readme(setname, title, version, commit, dirty, dat_rows, earned))

    sums = []
    for f in sorted(os.listdir(out_dir)):
        if f == "SHA256SUMS.txt" or not os.path.isfile(os.path.join(out_dir, f)):
            continue
        sums.append("%s  %s" % (hashlib.sha256(open(os.path.join(out_dir, f), "rb").read()).hexdigest(), f))
    open(os.path.join(out_dir, "SHA256SUMS.txt"), "w", newline="\n").write("\n".join(sums) + "\n")

    print("\n".join(info))
    print("\nwrote %s" % os.path.relpath(out_dir, ROOT))
    if "PLAYTEST" in version.upper() or dirty:
        print("NOTE: not a release cut (%s%s) - fine for a test, rebuild with --release to submit"
              % (version, ", dirty tree" if dirty else ""))


if __name__ == "__main__":
    main()
