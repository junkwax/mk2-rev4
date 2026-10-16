#!/usr/bin/env python3
"""Decode every movie frame out of the BUILT ROMs and compare to its .FRM.

This is the end-to-end check for the movie/.BIN pipeline: it proves that each
frame is at the address its *ZIP.TBL label claims, that its .HDR survived
packing, and that the imploded stream decodes to exactly the pixels in
data/<name>.FRM.  In other words it answers "will every ending, attract screen
and VS portrait actually render?" without visiting them in MAME.

    python tools/verify_movies.py

Run it after anything that repacks or moves movie payloads: re-imploding with
tools/implode.py, editing a LOD that carries FRM> lines, or shifting a slot in
makevrom.py.  Requires makerom.py + makevrom.py to have been run first, since
it reads rom/mk2_flat.bin and the 12 video chips.

Frames with no .FRM/.HDR pair (FL_*, VS_JCN1) are skipped - only their .BIN
survives in the leak, so there is nothing to compare against.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from implode import explode

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Which table lives in which ROM.  Program-ROM (REVX) frames are addressed
# inside the 1 MB flat image; video-ROM frames are 4-way interleaved.
#
# Every video-ROM movie frame is in BANK 0, and that is a hard requirement, not
# a coincidence: movie_run (UNZIP.ASM) has no video-ROM bank select, so a
# bank-1 label decodes whatever bank 0 holds at the same window.  video_at
# below therefore treats a label as a bank-0 offset unconditionally.  A
# bank-1 frame shows up here as ".HDR in ROM does not match" and in MAME as a
# hang on the VS screen.
TABLES = [
    ("MK8ZIP.TBL", "program", "REVX / MK8MIL"),
    ("MKZIP.TBL", "video", "video ROM / MK5MIL"),
    ("VSNBZIP.TBL", "video", "video ROM / VSNBMOV"),
    ("VSSMZIP.TBL", "video", "video ROM / VSSMMOV"),
]

# Noob's and Smoke's sidecars are only BUILT while vs_noob_smoke_pics is 1
# (MAINEQU.ASM).  At 0 their LODs are out of IMGBUILD.BAT, their slots are
# commented out in makevrom.py and UNZIP.ASM does not even include their ZIP
# tables - but src/VSNBZIP.TBL and src/VSSMZIP.TBL stay on disk holding their
# last addresses, so checking them reads whatever moved in and reports two
# confident failures for frames that are not in the ROM at all.  Read the flag
# rather than hardcoding it, so this follows the switch in both directions.
GATED_TABLES = {"VSNBZIP.TBL": "vs_noob_smoke_pics",
                "VSSMZIP.TBL": "vs_noob_smoke_pics"}


def asm_flag(name, default=1):
    """Value of a `<name> .set <n>` equate in src/MAINEQU.ASM."""
    p = os.path.join(ROOT, "src", "MAINEQU.ASM")
    try:
        txt = open(p, encoding="latin-1").read()
    except OSError:
        return default
    m = re.search(r"^%s\s+\.set\s+(\d+)" % re.escape(name), txt, re.M)
    return int(m.group(1)) if m else default

# Labels that survive in a *ZIP.TBL with no payload of their own.  Retiring a
# FRM> line does not remove its label - LOAD2 just emits it at whatever address
# the next frame landed on, so the label aliases its neighbour and a naive
# compare reads that neighbour's bytes against this frame's .HDR.
RETIRED = {
    # Retired 2026-08-01; now aliases VS_JCN.  data/VS_JC.* remain on disk.
    "VS_JC",
}

VIDEO_GROUPS = {
    0: ("ug14.ug14", "uj14.uj14", "ug19.ug19", "uj19.uj19"),
    1: ("ug16.ug16", "uj16.uj16", "ug20.ug20", "uj20.uj20"),
    2: ("ug17.ug17", "uj17.uj17", "ug22.ug22", "uj22.uj22"),
}


def load_roms():
    prog_p = os.path.join(ROOT, "rom", "mk2_flat.bin")
    if not os.path.exists(prog_p):
        raise SystemExit("rom/mk2_flat.bin missing - run makerom.py first")
    prog = open(prog_p, "rb").read()
    chips = {}
    for g, names in VIDEO_GROUPS.items():
        paths = [os.path.join(ROOT, "rom",
                              f"l1_mortal_kombat_ii_game_rom_{n}") for n in names]
        if not all(os.path.exists(p) for p in paths):
            raise SystemExit("video ROM chips missing - run makevrom.py first")
        chips[g] = [open(p, "rb").read() for p in paths]
    return prog, chips


def main():
    prog, chips = load_roms()

    def prog_at(bitaddr, n):
        off = (bitaddr // 8) & 0xFFFFF
        return prog[off:off + n]

    def video_at(bitaddr, n):
        # Movie frames are always bank 0 (see TABLES), so the label's in-bank
        # offset is also its linear offset into the 12 MB image.
        flat = bitaddr // 8 - 0x400000
        g = flat >> 22
        rel = flat - (g << 22)
        c = chips[g]
        return bytes(c[(rel + i) & 3][(rel + i) >> 2] for i in range(n))

    readers = {"program": prog_at, "video": video_at}
    total_bad = 0
    for tbl, space, label in TABLES:
        gate = GATED_TABLES.get(tbl)
        if gate and not asm_flag(gate):
            print(f"{label:<22} not built ({gate} = 0), skipped")
            continue
        path = os.path.join(ROOT, "src", tbl)
        if not os.path.exists(path):
            print(f"{label}: {tbl} not found, skipped")
            continue
        rows = [(m.group(1), int(m.group(2), 16)) for m in
                re.finditer(r"^(\w+)\s+\.set\s+0?([0-9a-fA-F]+)h",
                            open(path, encoding="latin-1").read(), re.M)]
        read = readers[space]
        ok = bad = skip = 0
        for name, addr in rows:
            fp = os.path.join(ROOT, "data", name + ".FRM")
            hp = os.path.join(ROOT, "data", name + ".HDR")
            if name in RETIRED or not (
                    os.path.exists(fp) and os.path.exists(hp) and os.path.getsize(fp)):
                skip += 1
                continue
            raw = open(fp, "rb").read()
            hdr = open(hp, "rb").read()
            blob = read(addr, len(hdr) + len(raw) + 4096)
            if blob[:len(hdr)] != hdr:
                print(f"  {name}: .HDR in ROM does not match data/{name}.HDR")
                if space == "video":
                    print(f"    (is {name} in a BANK 1 slot? movie_run has no bank "
                          f"select - a movie frame must be bank 0 or it hangs)")
                bad += 1
                continue
            try:
                out = explode(blob[len(hdr):], len(raw))
            except Exception as exc:
                print(f"  {name}: stream failed to decode ({exc})")
                bad += 1
                continue
            if out == raw:
                ok += 1
            else:
                print(f"  {name}: decoded pixels differ from data/{name}.FRM")
                bad += 1
        print(f"{label:<22} {ok:>3} verified  {bad} bad  {skip} skipped")
        total_bad += bad

    print()
    if total_bad:
        print(f"FAIL - {total_bad} frame(s) will not render correctly")
        return 1
    print("PASS - every movie frame decodes from the ROM to its source pixels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
