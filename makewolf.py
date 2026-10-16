#!/usr/bin/env python3
"""
makewolf.py -- package this tree for the Wolf unit (the MK3 / UMK3 board).

Run AFTER the normal T-unit pipeline (build.py, makevrom.py, makesound.py),
because it reuses what they made:

    python build.py && python makerom.py && python makevrom.py && python makesound.py
    python makewolf.py

Steps (see doc/WOLF_UNIT.md):
  1. Assemble + link with wunit=1 in a PRIVATE copy, tmp/wolf/.  src/mk2.out,
     src/*.OBJ and every T-unit artifact are never touched, so a Wolf build
     cannot leave the T-unit tree half-built for another session.
  2. Program ROM -> u54 (even bytes, = uj12) / u63 (odd bytes, = ug12),
     with makerom.py's own section placement and REVX embed.
  3. Video ROMs: the T-unit chips from makevrom.py, renamed one for one
     (ug14 -> u133 ... uj22 -> u122, same offsets in MAME's video region).
  4. Sound: sound/stlaugh_patch.txt patched onto the Wolf DCS set in
     sound/wolf/ (Asure007's PLBUILD of MK2's sound for the 8K board).
     The patch script names eight retail streams by T-unit ROM address;
     those are found in the Wolf set BY CONTENT and translated, so the
     T-unit script stays the only one anybody edits.
  5. rom/wolf/umk3.zip = the donor umk3.zip with those files replaced.
     The PIC (u64) and the umk-u110..u121 chips stay the donor's.

It never writes C:/MAME/roms/umk3.zip.  Run it with
    mame umk3 -rompath rom/wolf
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).parent.resolve()
WORK = ROOT / "tmp" / "wolf"
OUT_DIR = ROOT / "rom" / "wolf"
DONOR = Path("C:/MAME/roms/umk3.zip")
WOLF_SOUND = ROOT / "sound" / "wolf"
PATCH = ROOT / "sound" / "stlaugh_patch.txt"
RETAIL_SOUND = ROOT / "mk2.zip"

# T-unit video chip -> UMK3 donor member.  MAME loads both at the same offset
# of the video region (ug14 @0, uj14 @1, ug19 @2, uj19 @3, ug16 @400000, ...).
VIDEO_MAP = {
    "ug14": "u133", "uj14": "u132", "ug19": "u131", "uj19": "u130",
    "ug16": "u129", "uj16": "u128", "ug20": "u127", "uj20": "u126",
    "ug17": "u125", "uj17": "u124", "ug22": "u123", "uj22": "u122",
}
# The twelve video sockets UMK3 leaves EMPTY (u117-u114 at 16 MB, u109-u102 at
# 24 MB).  Stock MAME's umk3 declares none of them; tools/mame_wolf's patched
# umk3 loads all twelve as "mk2wolf_video_rom_uNNN.uNNN", so art packed there
# (makevrom.py WOLF_EXTRA_BLOCKS) is seen only in mk2wolf.exe and on a board -
# the same footing as sound sockets u6-u9.  All twelve are always written
# (FF when unused): the patched driver refuses a set missing one.
EXTRA_VIDEO_BLOCKS = ((0x1000000, ("u117", "u116", "u115", "u114")),
                      (0x1800000, ("u109", "u108", "u107", "u106")),
                      (0x1C00000, ("u105", "u104", "u103", "u102")))
EXTRA_VIDEO_SOCKETS = {c for _, chips in EXTRA_VIDEO_BLOCKS for c in chips}
ENCODER_CANDIDATES = [
    Path("c:/Users/you/Workplace/DCSExplorer/x64/Release/DCSEncoder.exe"),
    Path("c:/Users/you/Workplace/DCSExplorer/x64/Debug/DCSEncoder.exe"),
]


def die(msg):
    print(f"makewolf: {msg}")
    sys.exit(1)


# ---------------------------------------------------------------- 1. assemble
def assemble():
    from build import get_dosbox_path
    dosbox = get_dosbox_path()
    if not dosbox:
        die("DOSBox not found")

    src = ROOT / "src"
    out = src / "mk2.out"
    if not out.exists():
        die("src/mk2.out missing - run build.py first (Phase B promotes the tables Wolf assembles from)")
    newer = [p.name for p in src.iterdir()
             if p.suffix.upper() in (".ASM", ".TBL", ".GLO", ".HDR")
             and p.stat().st_mtime > out.stat().st_mtime]
    if newer:
        print(f"  WARNING: {len(newer)} source file(s) newer than src/mk2.out "
              f"({', '.join(sorted(newer)[:5])}...) - the Wolf ROM will carry them, "
              "the T-unit ROM does not yet")

    if WORK.exists():
        shutil.rmtree(WORK)
    (WORK / "data").mkdir(parents=True)
    (WORK / "tools").mkdir()
    shutil.copytree(src, WORK / "src",
                    ignore=shutil.ignore_patterns("*.OBJ", "*.obj", "mk2.out", "*.LST", "*.map", "*.MAP"))
    for f in ("ART.OUT", "OART.OUT"):
        if (ROOT / "data" / f).exists():
            shutil.copy2(ROOT / "data" / f, WORK / "data" / f)
    for f in (ROOT / "data").glob("ED*.ASM"):
        shutil.copy2(f, WORK / "data" / f.name)
    for f in ("GSPA.EXE", "GSPLNK.EXE", "GMAKE.EXE"):
        shutil.copy2(ROOT / "tools" / f, WORK / "tools" / f)

    wu = WORK / "src" / "WUNIT.ASM"
    text = wu.read_text(encoding="latin-1")
    text, n = re.subn(r"^wunit\t\.set\t0", "wunit\t.set\t1", text, flags=re.M)
    if n != 1:
        die("could not set wunit in the WUNIT.ASM copy")
    wu.write_text(text, encoding="latin-1")

    # The power-up ROM test compares each video chip with the iromchips table
    # (DIAGDTST.ASM). src/ keeps whatever burnfix.py last synced, which goes
    # stale every time art changes; the Wolf copy gets the REAL sums of the
    # chips it is about to ship, so a Wolf package always passes its own test.
    # (u54/u63 are landed on cksum1/cksum2 after linking, in program_rom.)
    import burnfix
    dt = WORK / "src" / "DIAGDTST.ASM"
    lines = burnfix.read_text(str(dt)).splitlines(keepends=True)
    resynced = 0
    for idx, sock, cur in burnfix.iromchips_entries(lines):
        hits = sorted((ROOT / "rom").glob(f"*.{sock}"))
        if len(hits) != 1:
            die(f"expected one rom/*.{sock} from makevrom.py, found {len(hits)}")
        want = burnfix.chksum(hits[0].read_bytes())
        if want != cur:
            lines[idx] = burnfix.set_rom_chip_cksum(lines[idx], want)
            resynced += 1
    burnfix.write_text(str(dt), "".join(lines))
    print(f"  power-up video checksums: {resynced} of 12 resynced in the Wolf copy"
          + (" (src/ is stale - `python burnfix.py sync-video` fixes the T-unit's)" if resynced else ""))

    # tag the version string so a Wolf board says what it is
    dm = WORK / "src" / "DIAGMENU.ASM"
    t = dm.read_text(encoding="latin-1")
    # ... when there is room.  The name is stored in cmos in name_rev_size
    # (30) bytes, so 29 characters is the ceiling; "REV 4.0 - PLAYTEST (xxxxx*)"
    # is 27, and the line under it says WOLF UNIT anyway.
    m = re.search(r'rom_name\s+\.string\s+"([^"]*)"', t)
    n = 0
    if m and len(m.group(1)) + 2 <= 29:
        t, n = re.subn(r'(rom_name\s+\.string\s+"[^"]*?)(")', r"\1 W\2", t, count=1)
    if n == 1:
        dm.write_text(t, encoding="latin-1")

    conf = (ROOT / "dosbox_asm.conf").read_text(encoding="latin-1")
    (WORK / "dosbox_asm.conf").write_text(conf, encoding="latin-1")
    print("  Assembling with wunit=1 in tmp/wolf ...")
    # staged, each module with a MAINEQU pruned to what it names - the Wolf
    # pass is the one closest to GSPA's memory ceiling (build.py Phase C1,
    # tools/gspa_stage.py).  GMAKE then only links, and re-assembles unpruned
    # anything the stage could not.
    if os.environ.get("MK2_GSPA_STAGE", "1") != "0":
        sys.path.insert(0, str(ROOT / "tools"))
        import gspa_stage
        mods = gspa_stage.modules_to_assemble(WORK / "src")
        failed = gspa_stage.assemble(WORK / "src", WORK / "asmstage", mods, str(dosbox),
                                     WORK / "asmstage.log")
        if failed:
            print(f"  staged assembly failed for {', '.join(failed)} - GMAKE retries them unpruned")
    subprocess.run([str(dosbox), "-conf", "dosbox_asm.conf", "-noconsole", "-exit"],
                   cwd=str(WORK), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = (WORK / "build.log").read_text(encoding="latin-1", errors="replace")
    bad = [l for l in log.splitlines()
           if re.search(r"Errors|undefined|Out of memory|not built|Aborted", l) and "No Errors" not in l]
    wout = WORK / "src" / "mk2.out"
    if bad or not wout.exists():
        print("\n".join(bad[:30]))
        die(f"Wolf assembly failed - see {WORK / 'build.log'}")
    print(f"  tmp/wolf/src/mk2.out ({wout.stat().st_size:,d} bytes)")
    return wout


# ------------------------------------------------------------ 2. program rom
def program_rom(coff):
    import makerom
    sections = makerom.read_coff(coff)
    rom, placed = makerom.build_rom_image(sections)
    # NO REVX pool on Wolf: the VS portraits are read from image ROM instead
    # (UNZIP.ASM vs_base/vs_dest; placed by video_roms), so the program ROM
    # from the end of .data to the burnfix tail window is all code space.
    import burnfix
    code_end = max(end for _, end, label in placed if "VECTORS" not in str(label))
    limit = burnfix.PAD_START * 2            # flat offset of the checksum window
    if code_end > limit:
        die(f"Wolf program ROM: code ends at flat 0x{code_end:06X}, past the checksum window 0x{limit:06X}")
    print(f"  Wolf program ROM: code ends at flat 0x{code_end:06X}; {limit - code_end:,d} bytes free "
          f"(no REVX pool on Wolf)")
    even, odd = makerom.interleave(rom)
    if not makerom.validate_capacity(len(even), len(odd), len(rom)):
        die("program ROM over capacity")
    (WORK / "mk2w_flat.bin").write_bytes(rom)

    # The power-up ROM test (DIP "Powerup Test") sums each program chip and
    # compares it with cksum1 / cksum2, which are linked into the program. The
    # Wolf program is not the T-unit's, so land u54/u63 on those constants the
    # way burnfix.py does for uj12/ug12: by trimming FF filler in the dead tail.
    # MAME does not care; a burned board would otherwise report both chips BAD.
    import burnfix
    targets = burnfix.prog_targets()
    even, odd = bytearray(even), bytearray(odd)
    burnfix.force_lane(even, targets["cksum1"], "u54")
    burnfix.force_lane(odd, targets["cksum2"], "u63")
    print(f"  power-up checksums: u54 -> {targets['cksum1']:04X} (cksum1), u63 -> {targets['cksum2']:04X} (cksum2)")
    return bytes(even), bytes(odd)


# ------------------------------------------------------------------ 3. video
def video_roms():
    got = {}
    for sock, wolf in VIDEO_MAP.items():
        hits = sorted((ROOT / "rom").glob(f"*.{sock}"))
        if len(hits) != 1:
            die(f"expected one rom/*.{sock} from makevrom.py, found {len(hits)}")
        got[wolf] = hits[0].read_bytes()
    # Wolf-only art above 12 MB (makevrom.py's wolf_irw_files ->
    # rom/wolf_video_hi.bin, linear 12 MB onward). MAME's umk3 loads two of
    # those 4 MB blocks; a block with nothing in it keeps the donor's chips.
    hi = ROOT / "rom" / "wolf_video_hi.bin"
    flat = bytearray(hi.read_bytes() if hi.exists() else b"\xff" * (0x2000000 - 0xC00000))

    # The VS portraits (MK8MIL.IRW, the T-unit's REVX pool) go in the slot
    # UNZIP.ASM reads them from: wolf_vs_cpu with image bank 1, which is linear
    # 1*8MB + (cpu - 02000000h)/8 (tools/wolf_cpu_irom_window_check.lua).
    import makerom
    un = (WORK / "src" / "UNZIP.ASM").read_text(encoding="latin-1")
    m = re.search(r"^wolf_vs_cpu\s+\.set\s+0?([0-9A-Fa-f]+)h", un, re.M)
    if not m:
        die("UNZIP.ASM has no wolf_vs_cpu")
    vs_lin = 0x800000 + (int(m.group(1), 16) - 0x02000000) // 8
    payload = (ROOT / "data" / "MK8MIL.IRW").read_bytes()[makerom.REVX_IRW_HEADER_SIZE:]
    a, b = vs_lin - 0xC00000, vs_lin - 0xC00000 + len(payload)
    if b > 0x1000000 - 0xC00000:
        die(f"VS portraits ({len(payload):,d} bytes) overrun the 12-16 MB block from 0x{vs_lin:07X}")
    if any(x != 0xFF for x in flat[a:b]):
        die(f"a Wolf art pack overlaps the VS portrait slot 0x{vs_lin:07X}-0x{vs_lin + len(payload):07X}")
    flat[a:b] = payload
    print(f"  VS portraits: {len(payload):,d} bytes at video 0x{vs_lin:07X} (CPU 0x{m.group(1)}, bank 1)")
    # the Wolf-only portraits (data/MK8WOLF.LOD - Sindel): based at a Wolf CPU
    # address inside the same window, above the shared ones
    lod = (ROOT / "data" / "MK8WOLF.LOD").read_text(encoding="latin-1")
    wb = int(re.search(r"^\*\*\*>\s*([0-9A-Fa-f]+)", lod, re.M).group(1), 16)
    wend = 0x02000000 + (0x1000000 - 0x800000) * 8          # wolf_vs_end, 06000000h
    wpay = (ROOT / "data" / "MK8WOLF.IRW").read_bytes()[makerom.REVX_IRW_HEADER_SIZE:]
    w_lin = 0x800000 + (wb - 0x02000000) // 8
    if not (vs_lin <= w_lin and wb + len(wpay) * 8 <= wend):
        die(f"MK8WOLF.LOD base {wb:08X} is outside the VS window")
    if w_lin < vs_lin + len(payload):
        die(f"the shared VS portraits ({len(payload):,d} bytes) have grown into MK8WOLF at "
            f"0x{w_lin:07X} - move MK8WOLF.LOD's base up")
    flat[w_lin - 0xC00000:w_lin - 0xC00000 + len(wpay)] = wpay
    print(f"  Wolf-only VS portraits: {len(wpay):,d} bytes at video 0x{w_lin:07X} (CPU 0x{wb:08X}); "
          f"{w_lin - vs_lin - len(payload):,d} bytes of growth below for the shared ones")

    # the CHARACTER ENDINGS (data/ENDWOLF.LOD): based at a Wolf CPU address in
    # [wolf_end_cpu, wolf_end_end), read with image BANK 2 - linear
    # 2*8MB + (cpu - 02000000h)/8, in the u113..u110 block
    me = re.search(r"^wolf_end_cpu\s+\.set\s+0?([0-9A-Fa-f]+)h", un, re.M)
    mx = re.search(r"^wolf_end_end\s+\.set\s+0?([0-9A-Fa-f]+)h", un, re.M)
    if not (me and mx):
        die("UNZIP.ASM has no wolf_end_cpu / wolf_end_end")
    e_lo, e_hi = int(me.group(1), 16), int(mx.group(1), 16)
    lod = (ROOT / "data" / "ENDWOLF.LOD").read_text(encoding="latin-1")
    eb = int(re.search(r"^\*\*\*>\s*([0-9A-Fa-f]+)", lod, re.M).group(1), 16)
    epay = (ROOT / "data" / "ENDWOLF.IRW").read_bytes()[makerom.REVX_IRW_HEADER_SIZE:]
    if not (e_lo <= eb and eb + len(epay) * 8 <= e_hi):
        die(f"ENDWOLF.LOD ({eb:08X} + {len(epay):,d} bytes) leaves the endings window "
            f"{e_lo:08X}-{e_hi:08X} (UNZIP.ASM wolf_end_cpu/wolf_end_end)")
    # a bank-0 or bank-1 movie in the same CPU range would be read from bank 2
    for tbl in ("MKZIP.TBL", "MK8WZIP.TBL"):
        for lab, val in re.findall(r"^(\w+)\s+\.set\s+0?([0-9A-Fa-f]+)h", (WORK / "src" / tbl)
                                   .read_text(encoding="latin-1"), re.M):
            if e_lo <= int(val, 16) < e_hi:
                die(f"{tbl} {lab} ({val}h) is inside the bank-2 endings window - movie_run would read it from bank 2")
    e_lin = 0x1000000 + (eb - 0x02000000) // 8
    a, b = e_lin - 0xC00000, e_lin - 0xC00000 + len(epay)
    if any(x != 0xFF for x in flat[a:b]):
        die(f"a Wolf art pack overlaps the endings slot 0x{e_lin:07X}-0x{e_lin + len(epay):07X}")
    flat[a:b] = epay
    print(f"  character endings: {len(epay):,d} bytes at video 0x{e_lin:07X} (CPU 0x{eb:08X}, bank 2)")

    if True:
        for base, chips in ((0xC00000, ("u121", "u120", "u119", "u118")),
                            (0x1400000, ("u113", "u112", "u111", "u110"))):
            blk = flat[base - 0xC00000:base - 0xC00000 + 0x400000]
            if len(blk) < 0x400000 or blk.count(0xFF) == len(blk):
                continue
            for lane, chip in enumerate(chips):
                got[chip] = blk[lane::4]
            print(f"  Wolf-only art: {chips[0]}..{chips[-1]} (0x{base:07X}, "
                  f"{len(blk) - blk.count(0xFF):,d} non-FF bytes)")
        for base, chips in EXTRA_VIDEO_BLOCKS:
            blk = flat[base - 0xC00000:base - 0xC00000 + 0x400000]
            for lane, chip in enumerate(chips):
                got[chip] = blk[lane::4]
            used = len(blk) - blk.count(0xFF)
            if used:
                print(f"  Wolf-only art: {chips[0]}..{chips[-1]} (0x{base:07X}, {used:,d} non-FF bytes)"
                      " - mk2wolf.exe / a board only, stock MAME does not load these")

    # The assembled Wolf copy's iromchips table must match these exact chips
    # (assemble() synced it); a mismatch means rom/ changed after assembly.
    import burnfix
    lines = burnfix.read_text(str(WORK / "src" / "DIAGDTST.ASM")).splitlines(keepends=True)
    stale = [f"{sock}/{VIDEO_MAP[sock]}" for _, sock, want in burnfix.iromchips_entries(lines)
             if burnfix.chksum(got[VIDEO_MAP[sock]]) != want]
    if stale:
        die(f"video chips changed since the Wolf assembly ({', '.join(stale)}) - rerun without --no-asm")
    print("  power-up video checksums: all 12 match the Wolf build's iromchips")
    return got


# ------------------------------------------------------------------ 4. sound
def chips_from_zip(path):
    z = zipfile.ZipFile(path)
    d = {}
    for n in z.namelist():
        # DCSEncoder names a chip it adds past the prototype's last one after
        # THAT chip's extension - "mk2wolf_sound_rom_u6.u5" - so the socket is
        # the "_uN" in the stem when there is one.  Keying on the extension
        # alone read u6 and u7 BOTH as u5: each overwrote the real u5, the set
        # lost 92 of MK2's streams and played slow ticking garbage.
        m = re.search(r"_u([2-9])\.u\d$", n, re.I) or re.search(r"\.u([2-9])$", n, re.I)
        if m:
            k = int(m.group(1)) - 2
            if k in d:
                die(f"{path}: two members claim sound socket u{k + 2} ({n})")
            d[k] = z.read(n)
    return d


def wolf_patch_script():
    """stlaugh_patch.txt with every `stream $addr` re-pointed at the Wolf set.

    A DCS address is chip<<20 | offset, and the offset is masked by the chip
    size (DCSDecoder::MakeROMPointer), so on a 512K T-unit chip bit 19 mirrors.
    """
    tunit = chips_from_zip(RETAIL_SOUND)
    wolf = {n - 2: (WOLF_SOUND / f"U{n}.ROM").read_bytes() for n in (2, 3, 4, 5)}
    text = PATCH.read_text(encoding="utf-8")
    table = {}
    for a in sorted(set(m.upper() for m in re.findall(r"(?i)stream \$([0-9a-f]+)", text))):
        v = int(a, 16)
        chip, off = v >> 20, v & (len(tunit[v >> 20]) - 1)
        for size in (48, 128, 512):
            sig = tunit[chip][off:off + size]
            hits = [(k << 20) | m.start() for k, b in wolf.items() for m in re.finditer(re.escape(sig), b)]
            if len(hits) <= 1:
                break
        if len(hits) != 1:
            die(f"retail stream ${a} found {len(hits)} times in the Wolf sound set")
        table[a] = f"{hits[0]:06X}"
    for a, w in table.items():
        print(f"    stream ${a} -> ${w}")
    text = re.sub(r"(?i)(stream \$)([0-9a-f]+)", lambda m: m.group(1) + table[m.group(2).upper()], text)
    # the Wolf-ONLY overlay: UMK3's own sounds for the Wolf-only fighters
    # (tools/make_wolf_audio.py) - streams are named, never `stream $addr`
    overlay = ROOT / "sound" / "wolf_patch.txt"
    if overlay.exists():
        text += "\n" + overlay.read_text(encoding="utf-8")
        print(f"    + {overlay.name} (Wolf-only sounds)")
    # MK1's stage music (tools/make_mk1_music.py) - big enough that it is what
    # fills the spare sockets u6-u9
    music = ROOT / "sound" / "wolf_mk1music.txt"
    if music.exists():
        body = music.read_text(encoding="utf-8")
        # the WAVs are git-ignored (cut from MK1_audio/, also ignored), so a
        # fresh checkout has the patch but not its streams
        missing = [w for w in re.findall(r'stream \w+ "([^"]+\.wav)"', body)
                   if not (ROOT / "sound" / w).exists()]
        if missing:
            print(f"    WARNING: {len(missing)} MK1 music WAVs missing ({missing[0]} ...) - "
                  "MK1 stages play SILENCE; run tools/make_mk1_music.py --apply (needs MK1_audio/)")
        else:
            text += "\n" + body
            print(f"    + {music.name} (MK1 stage music)")
    return text


def dcs_checksum(b):
    """DCS ROM checksum: even-offset byte sum | odd-offset byte sum, each & FF."""
    return sum(b[0::2]) & 0xFF, sum(b[1::2]) & 0xFF


def wolf_proto_chip(n):
    """Asure's Wolf chip n, readable by DCSEncoder.

    PLBUILD (1994) stamped U3-U5 with a THREE-digit year - "U3 08/29/125" -
    and DCSDecoder's zip loader only accepts a chip whose header matches
    dd/dd/dd, so U3-U5 were silently left out: the encoder then wrote a
    catalog for U2 alone and the sound board played nothing at all.  The year
    is rewritten in place (same length) and the change is balanced in the
    chip's unused FF tail so its checksum still matches U2's index.
    """
    b = bytearray((WOLF_SOUND / f"U{n}.ROM").read_bytes())
    m = re.match(rb"U%d (\d\d/\d\d/)(\d{3})\x00" % n, bytes(b[:16]))
    if n > 2 and m:
        want = dcs_checksum(b)
        start = 3 + len(m.group(1))
        b[start:start + 4] = m.group(2)[1:] + b"\x00\x00"
        if bytes(b[-2:]) != b"\xff\xff":
            die(f"Wolf U{n} has no FF tail to balance the checksum in")
        e, o = dcs_checksum(b)
        b[-2] = (b[-2] + want[0] - e) & 0xFF
        b[-1] = (b[-1] + want[1] - o) & 0xFF
        assert dcs_checksum(b) == want
    return bytes(b)


def sound_roms(retail_only):
    proto = WORK / "proto_wolf.zip"
    with zipfile.ZipFile(proto, "w") as z:
        for n in (2, 3, 4, 5):
            z.writestr(f"mk2wolf_sound_rom_u{n}.u{n}", wolf_proto_chip(n))
    if retail_only:
        print("  Sound: Wolf set as built, no custom audio (--retail-sound)")
        return {n: (WOLF_SOUND / f"U{n}.ROM").read_bytes() for n in (2, 3, 4, 5)}

    enc = next((c for c in ENCODER_CANDIDATES if c.exists()), None)
    if not enc:
        die("DCSEncoder.exe not found (or pass --retail-sound)")
    print("  Sound: patching custom audio onto the Wolf set")
    script = WORK / "wolf_patch.txt"
    script.write_text(wolf_patch_script(), encoding="utf-8")
    outzip = WORK / "wolf_sound.zip"
    r = subprocess.run([str(enc), "--patch", "--rom-prefix=*", "--rom-size=*",
                        f"--stream-dir={ROOT / 'sound'}", "-o", str(outzip), str(proto), str(script)],
                       cwd=str(ROOT / "sound"), capture_output=True, text=True)
    if r.returncode != 0 or not outzip.exists():
        print("\n".join(l for l in r.stdout.splitlines() if "error" in l.lower())[:3000])
        die("DCSEncoder failed on the Wolf patch")
    got = chips_from_zip(outzip)
    # u2-u9: the Wolf sound section has EIGHT 1 MB sockets (doc/WOLF_SPACE.md).
    # Stock MAME's umk3 loads only u2-u5 (an 8 MB region, each byte-wide chip
    # spread over 2 MB of 16-bit words), so u6-u9 play only on a board or in
    # tools/mame_wolf - stock MAME ignores the extra members.
    if any(k > 7 for k in got):
        die(f"Wolf sound spilled past U9 (chips {[k + 2 for k in sorted(got)]})")
    for line in r.stdout.splitlines():
        if re.match(r"\s*U\d\s+1M", line):
            print("   ", line.strip())
    # the encoder repacks; a socket it did not need is left empty, as on a board.
    # All eight are written: tools/mame_wolf's umk3 lists u6-u9 and would
    # refuse a set missing one, and an empty (FF) chip burns as a blank.
    return {n: got.get(n - 2, b"\xff" * 0x100000) for n in range(2, 10)}


# -------------------------------------------------------------------- 5. zip
def package(even, odd, video, sound, donor):
    if not donor.exists():
        die(f"donor set {donor} not found (pass --donor)")
    repl = {}
    with zipfile.ZipFile(donor) as dz:
        names = dz.namelist()

        def member(pattern):
            hits = [n for n in names if re.search(pattern, n, re.I)]
            if len(hits) != 1:
                die(f"donor: expected one member matching {pattern}, found {hits}")
            return hits[0]

        repl[member(r"\.u54$")] = even
        repl[member(r"\.u63$")] = odd
        extra = {}
        for wolf, data in video.items():
            if wolf in EXTRA_VIDEO_SOCKETS:     # no member in umk3's set: added beside it
                extra[f"mk2wolf_video_rom_{wolf}.{wolf}"] = data
                continue
            # MK3's chips are "....u133", UMK3's own are "umk-u121.bin"
            repl[member(rf"(\.{wolf}|-{wolf}\.bin)$")] = data
        for n, data in sound.items():
            if n <= 5:
                repl[member(rf"\.u{n}$")] = data
            else:   # u6-u9 have no member in umk3's set: added beside it
                extra[f"mk2wolf_sound_rom_u{n}.u{n}"] = data
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        out = OUT_DIR / "umk3.zip"
        tmp = out.with_suffix(".tmp")
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as oz:
            for n in names:
                oz.writestr(n, repl.get(n, dz.read(n)))
            for n, data in extra.items():
                oz.writestr(n, data)
    os.replace(tmp, out)
    for n in names:
        print(f"    {'OURS ' if n in repl else 'donor'} {n}")
    print(f"\n  Wrote {out}  ({len(repl)} of {len(names)} members ours)")
    print(f"  Run:  mame umk3 -rompath {OUT_DIR}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--no-asm", action="store_true", help="reuse tmp/wolf/src/mk2.out")
    ap.add_argument("--retail-sound", action="store_true", help="Wolf sound without the custom audio patch")
    ap.add_argument("--donor", type=Path, default=DONOR, help=f"UMK3 donor set (default {DONOR})")
    a = ap.parse_args()

    print("[1/5] Wolf program assembly")
    if a.no_asm:
        coff = WORK / "src" / "mk2.out"
        if not coff.exists():
            die("--no-asm but tmp/wolf/src/mk2.out does not exist")
    else:
        coff = assemble()
    print("[2/5] Program ROM (u54/u63)")
    even, odd = program_rom(coff)
    print("[3/5] Video ROMs (u122-u133)")
    video = video_roms()
    print("[4/5] Sound ROMs (u2-u5)")
    sound = sound_roms(a.retail_sound)
    print("[5/5] Package")
    package(even, odd, video, sound, a.donor)


if __name__ == "__main__":
    main()
