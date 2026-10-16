#!/usr/bin/env python3
r"""MK1 KANO, ripped out of C:\MAME\roms\mk.zip (rev 5.0) into data/MK1KANO.IMG -
every piece record any of his animation lanes draws, with its anipoint, and both
of his palettes - for the Wolf build's Kano (Shang Tsung's morph, MK1's full move
set; doc/WOLF_CONTENT_PLAN.md step F).

Read, not remembered, through tools/mk1_yunit_extract.py's T-unit reader:
  * the fighter animation list is FFCE4B90 (found by shape and asserted there);
    Kano is ochar 1, so his table is its second .long;
  * a lane is a run of frames - each a 0-ended list of piece records sharing
    one anchor - with commands between them (0 end of part, 1 jump, 2 flip,
    3 adjust x, 4 adjust x,y, 5 no-sleep, 6 calla); every part of every lane
    is walked, so nothing a lane can reach is missed;
  * his palettes are the .long at FFC839A0 + 32 (the colours he is given)
    and FFC83AC0 + 32 (a mirror match) - tools/import_mk1_palettes.py proves
    those two tables.

A piece used by several lanes is written ONCE, named after the first lane and
frame that draws it: K<lane>_<frame><piece letter>, lanes in hex.  The full
lane -> frame -> piece map is written beside the contact sheets
(tmp/mk1kano/lanes.txt), because that map, not the IMG, is what the port is
built from.

    python tools/make_mk1kano.py            # report
    python tools/make_mk1kano.py --apply    # write data/MK1KANO.IMG + sheets
    python tools/make_mk1kano.py --check    # the IMG still matches mk.zip

The IMG is a reference library in NO LOD (like data/KATPAL.IMG): nothing here
reaches a ROM yet.  The pack that does is cut from it when the port is built.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mk1_yunit_extract as mk1   # noqa: E402
import make_mk1pit as pit         # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT_IMG = ROOT / "data" / "MK1KANO.IMG"
OUT_DIR = ROOT / "tmp" / "mk1kano"
KANO = 1
ANITAB_LIST = 0xFFCE4B90
PAL_TABLES = {"KANO1_P": 0xFFC839A0, "KANO2_P": 0xFFC83AC0}   # given / mirror
MAX_LANES = 0x60


def walk(rom, a, stop):
    """One lane's frames over ALL its parts: (frame, dx, dy).  A lane's parts
    follow one another, each ended by a 0, and nothing in the data says how
    many there are - so the walk stops at the next lane's own start address
    (stop), at a JUMP (1), or at anything that is not a frame or a command."""
    out, dx, dy = [], 0, 0
    while rom.inside(a) and a < stop:
        v = rom.l(a)
        if v == 0:
            a += 32
            continue
        if v == 1:
            break
        if v == 3:
            dx += rom.sw(a + 32); a += 48; continue
        if v == 4:
            dx += rom.sw(a + 32); dy += rom.sw(a + 48); a += 64; continue
        if v in (2, 5):
            a += 32; continue
        if v == 6:
            a += 64; continue
        if not rom.inside(v) or not rom.pieces(v):
            break
        out.append((v, dx, dy))
        a += 32
    return out


def lanes(rom):
    """[(index, address, [(frame, dx, dy)], source lines)] for every lane."""
    starts = []
    for k in range(MAX_LANES):
        a = rom.ani(KANO, k)
        if rom.inside(a):
            starts.append((k, a))
    addrs = sorted({a for _k, a in starts})
    out = []
    for k, a in starts:
        nxt = next((b for b in addrs if b > a), a + 32 * 64)
        fr = walk(rom, a, min(nxt, a + 32 * 160))
        if fr:
            out.append((k, a, fr, rom.lane_source(a, limit=96)))
    return out


def collect(rom, L):
    """record address -> name, in first-use order; frame -> [record]."""
    names, frames = {}, {}
    for k, _a, fr, _src in L:
        for fi, (f, _dx, _dy) in enumerate(fr):
            ps = rom.pieces(f)
            frames.setdefault(f, ps)
            for pi, p in enumerate(ps):
                names.setdefault(p, f"K{k:02X}_{fi + 1}{chr(65 + pi)}")
    return names, frames


def read(rom):
    # find_anitab_list leaves rom.anitab_list on the LAST candidate it tried,
    # so the answer is set after it returns
    if mk1.find_anitab_list(rom) != ANITAB_LIST:
        raise SystemExit("mk.zip's fighter animation list is not at FFCE4B90 - wrong revision?")
    rom.anitab_list = ANITAB_LIST
    L = lanes(rom)
    names, frames = collect(rom, L)
    pals = {nm: rom.palette(rom.l(t + 32 * KANO)) for nm, t in PAL_TABLES.items()}
    recs = {}
    for a, nm in names.items():
        im = rom.image(a)
        px = rom.pixels(im["w"], im["h"], im["sag"])
        if px is None:
            raise SystemExit(f"{nm} ({a:08X}) does not decode")
        recs[a] = dict(name=nm, w=im["w"], h=im["h"], ax=im["anix"], ay=im["aniy"],
                       px=bytes(px.astype("uint8").tobytes()))
        if max(recs[a]["px"]) >= len(pals["KANO1_P"]):
            raise SystemExit(f"{nm} indexes past KANO1_P")
    return L, names, frames, recs, pals


def build_img(names, recs, pals):
    entries = [(recs[a]["name"], recs[a]["ax"], recs[a]["ay"], recs[a]["w"], recs[a]["h"],
                recs[a]["px"], 0) for a in names]
    return pit.build_img(entries, [(nm, 6, words) for nm, words in pals.items()])


def sheets(rom, L, names, pals):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    pal = pals["KANO1_P"]
    lines = [f"MK1 KANO (mk.zip rev 5.0) - fighter table {rom.anitab(KANO):08X}, "
             f"{len(L)} lanes, {len(names)} piece records", ""]
    for k, a, fr, src in L:
        im = mk1.strip(rom, fr, pal, scale=1)
        im.save(OUT_DIR / f"lane_{k:02X}.png")
        lines.append(f"lane {k:02X}  {a:08X}  {len(fr)} frames")
        for s in src:
            lines.append("    " + s)
            parts = s.split()
            if len(parts) >= 3 and parts[1] == "FRAME":
                f = int(parts[2], 16)
                lines.append("        " + " ".join(names[p] for p in rom.pieces(f)))
    (OUT_DIR / "lanes.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    rom = mk1.TRom(mk1.ROMS / "mk.zip")
    L, names, frames, recs, pals = read(rom)
    nbytes = sum(r["w"] * r["h"] for r in recs.values()) * 6 // 8
    print(f"MK1 KANO: {len(L)} lanes, {len(frames)} frames, {len(names)} piece records, "
          f"~{nbytes:,} B at flat 6bpp; palettes " +
          ", ".join(f"{n} ({len(w)})" for n, w in pals.items()))
    img = build_img(names, recs, pals)
    if a.apply:
        OUT_IMG.write_bytes(img)
        sheets(rom, L, names, pals)
        print(f"wrote {OUT_IMG.relative_to(ROOT)} ({len(img):,} bytes) and {OUT_DIR.relative_to(ROOT)}/")
    if a.check:
        if not OUT_IMG.exists() or OUT_IMG.read_bytes() != img:
            raise SystemExit(f"{OUT_IMG.relative_to(ROOT)} has drifted from mk.zip - rerun --apply")
        print("MK1KANO.IMG matches mk.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
