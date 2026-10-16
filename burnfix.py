#!/usr/bin/env python3
"""burnfix.py - prepare a source-built MK2 set for real Midway T-unit hardware.

Background
----------
There is no security-chip check left in this source tree to bypass:

  * MAIN.ASM:3409  secbust_proc  is a bare `die` stub (the real security
    process was never in the leak), so nothing ever talks to the board's
    security hardware.
  * DIAGMENU.ASM:6085 sec_random_trash / :6138 post_sec_trash (the "trash
    RAM then lock the system" retaliation) have no callers anywhere.

What *does* bite a burned set is the power-on ROM self test:

    MKINIT.ASM POWERUP -> powertst -> powercputest -> cputest -> romcheck

romcheck (DIAGDTST.ASM:1852) sums every byte of each chip and compares the
low 16 bits against a constant baked into the program ROM:

    cksum1 / cksum2                (DIAGDTST.ASM:4014) - uj12 / ug12
    iromchips rom_chip records     (DIAGDTST.ASM:4078) - the 12 video chips

Those constants are a dev-snapshot leftover and this branch's art has
diverged from retail anyway, so all 14 chips report BAD, you get a red
"ROM BAD" screen plus the error tone on every cold boot, and the game only
continues after the ~0x200000-iteration timeout at DIAGDTST.ASM:1009.

This tool makes the self test *pass* rather than bypassing it - a genuinely
bad EPROM burn still gets caught, which is what you want when you are
committing 14 chips to a cabinet.

Usage
-----
    python burnfix.py                 # do the right next step, self-guiding
    python burnfix.py sync-video      # video sums -> src/DIAGDTST.ASM
    python burnfix.py fix-program     # force uj12/ug12 sums, emit rom/burn/
    python burnfix.py verify          # check all 14 chips against the table

Typical flow after a full build:

    python build.py && python makerom.py && python makevrom.py
    python burnfix.py                 # patches DIAGDTST.ASM, tells you to rebuild
    python build.py --asm-only && python makerom.py
    python burnfix.py                 # now emits rom/burn/ and verifies

Burn the files in rom/burn/ - NOT the ROMs inside mk2.zip.  mamerom.py runs
crc_spoof.spoof_zip() on the zip, which rewrites 4 bytes of tail padding in
each program chip to satisfy FBNeo's CRC table; that breaks the internal
checksum this tool just fixed.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
DIAGDTST = os.path.join(ROOT, "src", "DIAGDTST.ASM")
ROMDIR = os.path.join(ROOT, "rom")
BURNDIR = os.path.join(ROMDIR, "burn")
SOUNDZIP = os.path.join(ROOT, "sound", "mk2_stlaugh.zip")
SOUNDDIR = os.path.join(ROOT, "sound")

PROG_LANES = [
    # (built file,        DIAGDTST constant, socket)
    ("mk2_uj12.bin", "cksum1", "uj12"),
    ("mk2_ug12.bin", "cksum2", "ug12"),
]

# Per-lane byte offset of the VECTORS section (flat 0xFFF80 / 2 lanes).
VECTORS_OFF = 0x7FFC0
# crc_spoof.spoof_zip() rewrites 4 bytes here for FBNeo; stay clear of it so a
# repackaged zip and a burned chip differ in exactly one known place.
CRC_SPOOF_OFF = 0x7FFBC
# 258 filler bytes is the worst case: each can absorb at most 255 of the
# 0..0xFFFF correction.
PAD_LEN = 258
PAD_END = CRC_SPOOF_OFF - 4        # 0x7FFB8
PAD_START = PAD_END - PAD_LEN      # 0x7FEB6
FILLER = 0xFF

EPROM_TYPE = {524288: "27C040 (4 Mbit)", 1048576: "27C080 (8 Mbit)"}


def chksum(data: bytes) -> int:
    """The exact algorithm romcheck uses: 8-bit adds, keep the low 16 bits."""
    return sum(data) & 0xFFFF


def read_text(path: str) -> str:
    with open(path, "r", encoding="latin-1", newline="") as fh:
        return fh.read()


def write_text(path: str, text: str) -> None:
    with open(path, "w", encoding="latin-1", newline="") as fh:
        fh.write(text)


# --------------------------------------------------------------------------
# src/DIAGDTST.ASM parsing
# --------------------------------------------------------------------------

RE_CKSUM = re.compile(r"^(cksum[12])\s+\.equ\s+0?([0-9A-Fa-f]+)h", re.M)
RE_ROMCHIP = re.compile(r"^(\s*)rom_chip\s+([^;\r\n]*?)\s*(;.*)?$")


def prog_targets() -> dict[str, int]:
    """cksum1 / cksum2 as the assembler will bake them into the program ROM."""
    text = read_text(DIAGDTST)
    found = {m.group(1): int(m.group(2), 16) for m in RE_CKSUM.finditer(text)}
    missing = {"cksum1", "cksum2"} - set(found)
    if missing:
        sys.exit(f"burnfix: {DIAGDTST} has no {' or '.join(sorted(missing))} .equ")
    return found


def iromchips_entries(lines: list[str]) -> list[tuple[int, str, int]]:
    """Walk the live iromchips table.

    Returns (line index, socket name e.g. 'ug14', current checksum) per chip,
    stopping at the `.long 0` terminator so the commented-out 16-chip variant
    and the iromchipsnew daughterboard table are left alone.
    """
    out: list[tuple[int, str, int]] = []
    inside = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not inside:
            if re.match(r"^iromchips\b", line):
                inside = True
            continue
        if re.match(r"^\s*\.long\s+0\b", line):
            break
        if stripped.startswith(";") or not stripped:
            continue
        m = RE_ROMCHIP.match(line.rstrip("\r\n"))
        if not m:
            continue
        args = [a.strip() for a in m.group(2).split(",")]
        if len(args) < 7:
            continue
        comment = m.group(3) or ""
        sock = re.search(r"\b(u[gj]\d{2})\b", comment)
        if not sock:
            sys.exit(f"burnfix: iromchips line {i + 1} has no ug../uj.. socket comment")
        out.append((i, sock.group(1), int(args[6].rstrip("hH"), 16)))
    if len(out) != 12:
        sys.exit(f"burnfix: expected 12 iromchips records, parsed {len(out)}")
    return out


def video_file(sock: str) -> str:
    hits = sorted(glob.glob(os.path.join(ROMDIR, "*." + sock)))
    if not hits:
        sys.exit(f"burnfix: no rom/*.{sock} - run 'python makevrom.py' first")
    if len(hits) > 1:
        sys.exit(f"burnfix: {len(hits)} candidates for {sock}: {hits}")
    return hits[0]


def set_rom_chip_cksum(line: str, value: int) -> str:
    m = RE_ROMCHIP.match(line.rstrip("\r\n"))
    eol = line[len(line.rstrip("\r\n")):]
    args = m.group(2).split(",")
    # Preserve the original per-argument spacing, replace only the digits.
    args[6] = re.sub(r"0?[0-9A-Fa-f]+h", f"0{value:04X}h", args[6], count=1)
    comment = (" " + m.group(3)) if m.group(3) else ""
    body = ",".join(args)
    # rebuild with the original leading whitespace and a tab before the comment
    rebuilt = f"{m.group(1)}rom_chip {body.lstrip()}"
    if comment:
        rebuilt += "\t" + comment.strip()
    return rebuilt + eol


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_sync_video(check_only: bool = False) -> bool:
    """Write the real video-ROM sums into iromchips.  True if already current."""
    text = read_text(DIAGDTST)
    lines = text.splitlines(keepends=True)
    entries = iromchips_entries(lines)

    changed = []
    for idx, sock, have in entries:
        want = chksum(open(video_file(sock), "rb").read())
        if want != have:
            changed.append((idx, sock, have, want))
            lines[idx] = set_rom_chip_cksum(lines[idx], want)

    if not changed:
        print("  iromchips table already matches the 12 built video ROMs")
        return True

    for _, sock, have, want in changed:
        print(f"  {sock}: 0x{have:04X} -> 0x{want:04X}")

    if check_only:
        print(f"  {len(changed)} image-ROM checksum(s) stale in src/DIAGDTST.ASM")
        return False

    shutil.copyfile(DIAGDTST, DIAGDTST + ".burnfix.bak")
    write_text(DIAGDTST, "".join(lines))
    print(f"  wrote {len(changed)} checksum(s) to src/DIAGDTST.ASM "
          f"(backup: DIAGDTST.ASM.burnfix.bak)")
    return False


def force_lane(data: bytearray, target: int, sock: str) -> None:
    """Trim tail filler until the whole-chip byte sum lands on `target`."""
    if len(data) != 524288:
        sys.exit(f"burnfix: {sock} is {len(data)} bytes, expected 524288")

    window = data[PAD_START:PAD_END]
    if any(b != FILLER for b in window):
        bad = next(i for i, b in enumerate(window) if b != FILLER)
        sys.exit(
            f"burnfix: {sock} correction window "
            f"0x{PAD_START:05X}-0x{PAD_END:05X} is not 0x{FILLER:02X} filler "
            f"(first real byte at 0x{PAD_START + bad:05X}).  The program ROM has "
            f"grown into the tail - pick a new window or free some space."
        )

    need_sub = (chksum(data) - target) & 0xFFFF
    off = PAD_START
    while need_sub:
        take = min(255, need_sub)
        data[off] = FILLER - take
        need_sub -= take
        off += 1

    got = chksum(data)
    if got != target:
        sys.exit(f"burnfix: {sock} landed on 0x{got:04X}, wanted 0x{target:04X}")


def cmd_fix_program() -> None:
    targets = prog_targets()
    os.makedirs(BURNDIR, exist_ok=True)

    manifest = []
    for fname, const, sock in PROG_LANES:
        src = os.path.join(ROMDIR, fname)
        if not os.path.exists(src):
            sys.exit(f"burnfix: {src} missing - run 'python makerom.py' first")
        data = bytearray(open(src, "rb").read())
        before = chksum(data)
        target = targets[const]
        force_lane(data, target, sock)
        used = sum(1 for b in data[PAD_START:PAD_END] if b != FILLER)
        out = os.path.join(BURNDIR, f"{sock}.bin")
        open(out, "wb").write(bytes(data))
        print(f"  {sock}: 0x{before:04X} -> 0x{target:04X} ({const}), "
              f"{used} filler byte(s) at 0x{PAD_START:05X}")
        manifest.append((f"{sock}.bin", len(data), sock, target, "program"))

    for _, sock, _ in iromchips_entries(read_text(DIAGDTST).splitlines(keepends=True)):
        src = video_file(sock)
        data = open(src, "rb").read()
        out = os.path.join(BURNDIR, f"{sock}.bin")
        shutil.copyfile(src, out)
        manifest.append((f"{sock}.bin", len(data), sock, chksum(data), "video"))

    snd = 0
    if os.path.exists(SOUNDZIP):
        with zipfile.ZipFile(SOUNDZIP) as z:
            for name in z.namelist():
                m = re.search(r"\.(u[2-7])$", name)
                if not m:
                    continue
                data = z.read(name)
                out = os.path.join(BURNDIR, f"{m.group(1)}.bin")
                open(out, "wb").write(data)
                manifest.append((f"{m.group(1)}.bin", len(data), m.group(1),
                                 chksum(data), "sound (DCS)"))
                snd += 1
        print(f"  copied {snd} DCS sound ROM(s) from sound/mk2_stlaugh.zip")
    else:
        for n in range(2, 8):
            src = os.path.join(SOUNDDIR, f"U{n}.ROM")
            if not os.path.exists(src):
                continue
            data = open(src, "rb").read()
            out = os.path.join(BURNDIR, f"u{n}.bin")
            shutil.copyfile(src, out)
            manifest.append((f"u{n}.bin", len(data), f"u{n}", chksum(data),
                             "sound (DCS)"))
            snd += 1
        print(f"  copied {snd} DCS sound ROM(s) from sound/U*.ROM "
              f"(no mk2_stlaugh.zip - custom audio NOT included)")

    lines = [
        "Mortal Kombat II - source build, burn set",
        "",
        "Program + video sums below are what romcheck (DIAGDTST.ASM:1852)",
        "recomputes on the board at power-on; they match the constants linked",
        "into the program ROM, so the power-on test reports all chips good.",
        "DCS sound ROMs are checked by the sound board itself, not by romcheck.",
        "",
        f"{'file':12s} {'socket':8s} {'bytes':>9s}  {'sum':>6s}  {'eprom':18s} kind",
    ]
    for fname, size, sock, sm, kind in manifest:
        lines.append(f"{fname:12s} {sock:8s} {size:9d}  0x{sm:04X}  "
                     f"{EPROM_TYPE.get(size, '?'):18s} {kind}")
    lines += [
        "",
        "Burn these files, not the ROMs inside mk2.zip: mamerom.py runs",
        "crc_spoof.spoof_zip(), which rewrites 4 bytes at 0x7FFBC of each",
        "program chip to satisfy FBNeo's CRC table and would invalidate the",
        "internal checksum.",
        "",
    ]
    write_text(os.path.join(BURNDIR, "MANIFEST.txt"), "\n".join(lines))
    print(f"  wrote {len(manifest)} chip image(s) + MANIFEST.txt to rom/burn/")


def cmd_verify() -> bool:
    """Check every chip the board will test against the linked-in constants."""
    targets = prog_targets()
    text = read_text(DIAGDTST)
    entries = iromchips_entries(text.splitlines(keepends=True))
    ok = True

    for fname, const, sock in PROG_LANES:
        cand = os.path.join(BURNDIR, f"{sock}.bin")
        src = cand if os.path.exists(cand) else os.path.join(ROMDIR, fname)
        if not os.path.exists(src):
            print(f"  {sock:6s} MISSING")
            ok = False
            continue
        got = chksum(open(src, "rb").read())
        want = targets[const]
        good = got == want
        ok &= good
        print(f"  {sock:6s} sum=0x{got:04X} {const}=0x{want:04X} "
              f"{'OK' if good else 'BAD'}   [{os.path.relpath(src, ROOT)}]")

    for _, sock, want in entries:
        cand = os.path.join(BURNDIR, f"{sock}.bin")
        src = cand if os.path.exists(cand) else video_file(sock)
        got = chksum(open(src, "rb").read())
        good = got == want
        ok &= good
        print(f"  {sock:6s} sum=0x{got:04X} table=0x{want:04X} "
              f"{'OK' if good else 'BAD'}   [{os.path.relpath(src, ROOT)}]")

    print(f"  -> power-on ROM test will {'PASS' if ok else 'FAIL'} on all 14 chips")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", nargs="?", default="auto",
                    choices=["auto", "sync-video", "fix-program", "verify"])
    ap.add_argument("--check", action="store_true",
                    help="sync-video: report staleness, exit 1, change nothing")
    args = ap.parse_args()

    if args.command == "sync-video":
        return 0 if cmd_sync_video(args.check) or not args.check else 1
    if args.command == "fix-program":
        cmd_fix_program()
        return 0
    if args.command == "verify":
        return 0 if cmd_verify() else 1

    # auto: sync the table first; it needs a rebuild before the program lanes
    # can be finalised, because the table lives in the program ROM.
    print("[1/2] image-ROM checksum table")
    current = cmd_sync_video()
    if not current:
        print("\nsrc/DIAGDTST.ASM changed - the table lives in the program ROM,")
        print("so reassemble before finalising the program lanes:\n")
        print("    python build.py --asm-only && python makerom.py")
        print("    python burnfix.py\n")
        return 2

    print("[2/2] program-ROM checksums")
    cmd_fix_program()
    print("\nverify")
    return 0 if cmd_verify() else 1


if __name__ == "__main__":
    sys.exit(main())
