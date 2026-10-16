#!/usr/bin/env python3
"""THE TOWER's terracotta guards, one scroll rate PER DEPTH (twrdepth, BGND.ASM).

PLANE3 (TOWER3.BDB) holds all six guards in ONE module, so they all scrolled at
one rate while standing at three depths on the skewing floor - the back pair
slid ~74px against the marble under their feet over a full pan.  floor_code
scrolls floor row r at  scrollx6 * (1 + r/128)  (tower_skew_calla's sra 7), so
the rate that keeps a guard planted is the floor's rate at the row his feet
are on.

This splits PLANE3BLKS by the block z byte - 43 front, 42 middle, 41 back,
which is also the stage's draw order - into three SOURCE-ONLY modules in
src/BGNDTBL.ASM (TWRGD1/2/3 BLKS + BMOD; promote_bgndtbl_stock_records keeps
source-only records).  Each keeps PLANE3's own size and block coordinates, so
BGND.ASM places all three with PLANE3's `.word` and at the start camera
(every plane at worldtlx 361) nothing moves.

It also derives the scroll rates from the art - each depth's lowest opaque row
on screen, and the pillars' base from tower_pillar_reflections' anchor - and
--check fails if tower_scroll (BGND.ASM, .if twrdepth) disagrees, or if the
split copies no longer match PLANE3BLKS.

    python tools/tower_guard_depths.py            # report
    python tools/tower_guard_depths.py --apply    # (re)write the split records
    python tools/tower_guard_depths.py --check    # Phase D
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "src" / "BGNDTBL.ASM"
GLO = ROOT / "src" / "BGNDTBL.GLO"
BGND = ROOT / "src" / "BGND.ASM"
sys.path.insert(0, str(ROOT / "tools"))

DEPTHS = [(0x43, "TWRGD1", "front"), (0x42, "TWRGD2", "middle"), (0x41, "TWRGD3", "back")]
BEGIN = "; ---- tower_guard_depths.py: generated, do not edit (see the tool) ----"
END = "; ---- end tower_guard_depths.py ----"
WORLDTLY = -14          # tower_mod's initial world y: screen y = plane y + 14
SCROLL6 = 0x14000       # tower_scroll entry 6 - the wall, and the floor's scrollx6
SKEW_SHIFT = 7          # tower_skew_calla: sra 7


def read_plane3():
    t = TBL.read_text(errors="replace")
    m = re.search(r"^PLANE3BLKS:\s*\n(.*?)\.word\s+0FFFFH", t, re.M | re.S)
    if not m:
        raise SystemExit("PLANE3BLKS not found in BGNDTBL.ASM")
    words = []
    for line in m.group(1).splitlines():
        code = line.split(";")[0]
        if ".word" in code:
            words += [w.strip() for w in code.split(".word", 1)[1].split(",") if w.strip()]
    def num(w):
        return int(w[:-1], 16) if w.lower().endswith("h") else int(w)
    vals = [num(w) for w in words]
    if len(vals) % 4:
        raise SystemExit("PLANE3BLKS: word count not a multiple of 4")
    blocks = [tuple(vals[i:i + 4]) for i in range(0, len(vals), 4)]
    hm = re.search(r"^PLANE3BMOD:\s*\n\s*\.word\s+(\d+)\s*,\s*(\d+)\s*,\s*(\d+)", t, re.M)
    return blocks, (int(hm.group(1)), int(hm.group(2)), int(hm.group(3))), t


def spreads():
    """TWR_SPR2 / TWR_SPR3 (BGND.ASM): px each depth moves toward the stage
    centre - the left pair right, the right pair left.  The ASM owns the
    number because tower_reflections adds the same one to its strips."""
    t = BGND.read_text(errors="replace")
    out = {0x43: 0}
    for z, n in ((0x42, "TWR_SPR2"), (0x41, "TWR_SPR3")):
        m = re.search(rf"^{n}\s+\.set\s+(-?\d+)", t, re.M)
        if not m:
            raise SystemExit(f"{n} not found in BGND.ASM")
        out[z] = int(m.group(1))
    return out


def render(blocks, size):
    spr = spreads()
    out = [BEGIN,
           "; THE TOWER's guards split by depth (twrdepth, BGND.ASM): PLANE3BLKS by the",
           "; z byte, PLANE3's size, each depth moved inward by TWR_SPR2/3 (the",
           "; reflections in tower_reflections take the same offsets)."]
    for z, name, what in DEPTHS:
        mine = [b for b in blocks if b[0] >> 8 == z]
        out.append(f"{name}BLKS:\t\t\t; {what} guards (z {z:02X}h)")
        for i, (fl, x, y, h) in enumerate(mine):
            # x < half the module is the LEFT pair: inward is +x
            x = x + spr[z] if x < size[0] // 2 else x - spr[z]
            if not 0 <= x < size[0]:
                raise SystemExit(f"{name}: stagger pushes a block off the module (x {x})")
            out.append(f"\t.word\t0{fl:04X}H,{x},{y},0{h:X}H")
        out.append("\t.word\t0FFFFH\t;End Marker")
        out.append("")
        out.append(f"{name}BMOD:")
        out.append(f"\t.word\t{size[0]},{size[1]},{len(mine)}\t;x size, y size, #blocks")
        out.append(f"\t.long\t{name}BLKS, R2HDRS, R2PALS")
        out.append("")
    out.append(END)
    return "\n".join(out)


def bottoms(blocks):
    """Lowest screen row per depth, from each block's header height."""
    import stage_preview as sp
    imgs, order, _ = sp.load_bdd(ROOT / "data" / "TOWER3.BDD")
    # PLANE3BLKS' hdr word indexes R2HDRS, which is the BDD header ORDER
    t = TBL.read_text(errors="replace")
    hdrs = re.search(r"^R2HDRS:\s*\n(.*?)^\S", t, re.M | re.S).group(1)
    sizes = [tuple(int(v) for v in m.groups())
             for m in re.finditer(r"\.word\s+(\d+)\s*,\s*(\d+)\s*;?.*\n\s*\.long", hdrs)]
    off = _plane3_word()[1] - WORLDTLY
    res = {}
    for z, name, what in DEPTHS:
        mine = [b for b in blocks if b[0] >> 8 == z]
        res[name] = off + max(b[2] + sizes[b[3] & 0x3fff][1] - 1 for b in mine)
    return res


def _plane3_word():
    lines = BGND.read_text(errors="replace").splitlines()
    for i, l in enumerate(lines):
        if ".long" in l.split(";")[0] and "PLANE3BMOD" in l.split(";")[0]:
            w = lines[i + 1].split(";")[0].split(".word", 1)[1].split(",")
            return int(w[0]), int(w[1])
    raise SystemExit("no .long PLANE3BMOD in BGND.ASM")


def floor_top():
    t = BGND.read_text(errors="replace")
    m = re.search(r"^tower_floor_info.*?\.word\s+0?([0-9a-fA-F]+)h\s*;\s*skew y", t, re.M | re.S)
    return int(m.group(1), 16)


def pillar_base():
    t = BGND.read_text(errors="replace")
    # the anchor itself (packed y:x, y = the first row BELOW the column), not
    # the comment beside it - that comment went stale once already
    m = re.search(r"^twr_pillar_left\s*\n\s*\.long\s+0([0-9A-Fa-f]{8})h", t, re.M)
    y = int(m.group(1), 16) >> 16
    return y - 1 - WORLDTLY


def rate_at(row):
    return round(SCROLL6 * (1 + row / (1 << SKEW_SHIFT)))


def tower_scroll_twrdepth():
    t = BGND.read_text(errors="replace")
    # up to the next LABEL - the block's own comment lines start in column 0
    body = re.search(r"^tower_scroll\s*\n(.*?)^[A-Za-z_]\w*\s*$", t, re.M | re.S).group(1)
    blk = re.search(r"\.if\s+twrdepth(.*?)\.else", body, re.S)
    if not blk:
        raise SystemExit("tower_scroll has no .if twrdepth block")
    vals = {}
    for m in re.finditer(r"\.long\s+0?([0-9a-fA-F]+)h\s*;\s*(\d)\b", blk.group(1)):
        vals[int(m.group(2))] = int(m.group(1), 16)
    return vals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    blocks, size, tbl = read_plane3()
    want = render(blocks, size)
    ft = floor_top()
    rows = {k: v - ft for k, v in bottoms(blocks).items()}
    prow = pillar_base() - ft
    expect = {3: rate_at(rows["TWRGD1"]), 7: rate_at(rows["TWRGD2"]),
              8: rate_at(rows["TWRGD3"]), 4: rate_at(prow)}
    for (z, name, what) in DEPTHS:
        n = sum(1 for b in blocks if b[0] >> 8 == z)
        print(f"{name} {what:6s}: {n:2d} blocks, feet on floor row {rows[name]:2d} -> "
              f"{expect[{'TWRGD1': 3, 'TWRGD2': 7, 'TWRGD3': 8}[name]] / 0x20000:.4f}x")
    print(f"pillars       : base on floor row {prow:2d} -> {expect[4] / 0x20000:.4f}x")
    if sum(1 for b in blocks if b[0] >> 8 in (0x41, 0x42, 0x43)) != size[2]:
        print("FAIL: PLANE3 has blocks outside z 41-43h - a depth with no plane")
        return 1

    have = re.search(re.escape(BEGIN) + r".*?" + re.escape(END), tbl, re.S)
    glo = GLO.read_text(errors="replace")
    missing_glo = [n for _, n, _ in DEPTHS if f"{n}BMOD" not in glo]
    bad = []
    if not have or have.group(0).replace("\r\n", "\n") != want:
        bad.append("split records stale - run --apply")
    if missing_glo:
        bad.append(f"BGNDTBL.GLO lacks {missing_glo}")
    try:
        got = tower_scroll_twrdepth()
        for k, v in expect.items():
            if got.get(k) != v:
                bad.append(f"tower_scroll entry {k} is {got.get(k, 0):05x}h, the floor "
                           f"under it wants {v:05x}h")
    except SystemExit as e:
        bad.append(str(e))

    if a.apply:
        nl = "\r\n" if "\r\n" in tbl else "\n"
        block = want.replace("\n", nl)
        if have:
            tbl = tbl[:have.start()] + block + tbl[have.end():]
        else:
            anchor = re.search(r"^dpdeckBMOD:.*?\n.*?\n.*?\n", tbl, re.M | re.S)
            tbl = tbl[:anchor.end()] + nl + block + nl + tbl[anchor.end():]
        TBL.write_text(tbl, newline="")
        if missing_glo:
            gnl = "\r\n" if "\r\n" in glo else "\n"
            glo = glo.rstrip("\r\n") + gnl + "".join(f"\t.globl\t{n}BMOD{gnl}" for n in missing_glo)
            GLO.write_text(glo, newline="")
        print("wrote split records" + (" + .globl" if missing_glo else ""))
        bad = [b for b in bad if "stale" not in b and "GLO" not in b]
    for b in bad:
        print("FAIL:", b)
    if a.check and bad:
        return 1
    if not bad:
        print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
