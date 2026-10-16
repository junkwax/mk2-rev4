#!/usr/bin/env python
"""Where Sub-Zero's head-rip props must be drawn, generated from the art.

The head rip hangs two props off Sub-Zero's own anchor and lets the display
mirror them with his facing (`match_ani_points` copies his flip onto each prop;
`multi_adjust_xy` negates the lane's dx when flipped; `ganiof` mirrors the art
about the anipoint).  So "the hand is over the head" is a statement about the
props' position RELATIVE TO HIS ANCHOR, IN FACING SPACE - and in facing space
it must read the same whichever way he is turned.

That is what this emits, so the rig asserts it instead of me looking at a
screenshot:

    left   = anchor - anix                        (ganiof, unflipped)
    left   = anchor - (sizex - anix)              (flipped; the harness note in
                                                   doc/SZ_HEADRIP_FATALITY.md
                                                   records the off-by-one)
    centre = left + (w - 1) // 2                  (what draw_span reports)

so, with `cum` the lane's cumulative ani_adjustxy at that beat,

    facing-space centre = cum - anix + (w - 1) // 2          unflipped
                        = cum - anix + w - (w - 1) // 2      flipped

The two differ by 1 px (odd w) or 2 px (even w) - integer truncation plus the
`sizex` / `sizex - 1` ambiguity - which is why the rig compares with a small
tolerance rather than demanding equality.  A MIRROR FAULT is nothing like that
size: it is twice the offset, ~30 px at the hold and ~190 px at the rip.

THE FIST BOXES ARE AUTHORED, NOT COMPUTED.  "Which pixels are his hand" is a
judgement about a drawing, made once off a 5x render of each frame; nothing can
derive it.  What IS checked is that the frames they were measured against have
not moved - size and anipoint of every strip of all four poses - so if the art
is re-exported this fails instead of silently measuring against a hand that is
no longer there.

    python tools/szhr_align_expect.py            # write tools/szhr_align_expect.lua
    python tools/szhr_align_expect.py --check    # Phase D: art unchanged, file current
"""

import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tools" / "szhr_align_expect.lua"

LIB = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# Sub-Zero's four prop beats: his frame's strips, and the spine record that
# joins him on that beat.  sz_headrip_pairs (MKNJ.ASM) pairs 4-7.
BEATS = {
    4: (["NJUPPERCUT4A", "NJUPPERCUT4B", "NJUPPERCUT4C"], "SPINERIP1"),
    5: (["NJELBO1A", "NJELBO1B"], "SPINERIP2"),
    6: (["NJSUBVIC2A", "NJSUBVIC2B", "NJSUBVIC2C", "NJSUBVIC2D", "NJSUBVIC2E"], "SPINERIP3"),
    7: (["NJSUBVIC3A", "NJSUBVIC3B", "NJSUBVIC3C"], "SPINERIP4"),
}

SZ_LIBS = {"NJUPPERCUT4": "NINJAS3", "NJELBO1": "NINJAS2",
           "NJSUBVIC2": "NINJAS9", "NJSUBVIC3": "NINJAS9"}

# His HOLDING FIST, measured off a 5x render of each pose, unflipped, relative
# to his own anchor: (x0, x1, y0, y1) inclusive.  Beat 5 is the near gloved hand
# at his hip; beats 6 and 7 are the raised fist.
FIST = {
    4: (70, 78, 28, 40),
    5: (25, 35, 58, 68),
    6: (-9, 1, -13, -4),
    7: (-19, -11, -28, -20),
}

# The geometry those measurements were taken against.  name -> (w, h, anix, aniy)
FIST_BASIS = {
    "NJUPPERCUT4A": (54, 136, 39, -5), "NJUPPERCUT4B": (33, 132, -15, -5),
    "NJUPPERCUT4C": (30, 15, -48, -28),
    "NJELBO1A": (26, 109, 22, -31), "NJELBO1B": (33, 127, -4, -10),
    "NJSUBVIC2A": (13, 37, 23, 7), "NJSUBVIC2B": (36, 42, 10, 12),
    "NJSUBVIC2C": (24, 110, 22, -30), "NJSUBVIC2D": (17, 94, -2, -30),
    "NJSUBVIC2E": (16, 107, -19, -30),
    "NJSUBVIC3A": (16, 167, 22, 28), "NJSUBVIC3B": (25, 123, 6, 0),
    "NJSUBVIC3C": (15, 108, -19, -28),
}


def read_img(path):
    data = path.read_bytes()
    imgcnt, _palcnt, oset = LIB.unpack_from(data, 0)[:3]
    out = {}
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        name = r[0].split(b"\0")[0].decode()
        ax = r[2] - 0x10000 if r[2] & 0x8000 else r[2]
        ay = r[3] - 0x10000 if r[3] & 0x8000 else r[3]
        out[name] = (r[4], r[5], ax, ay)          # w, h, anix, aniy
    return out


def head_travel():
    """The three ani_adjustxy pairs of a_sz_head_* (MKNJ.ASM), as cumulatives."""
    txt = (ROOT / "src" / "MKNJ.ASM").read_text(encoding="latin-1")
    m = re.search(r"^a_sz_head_gen\b.*?^\s*\.long\s+0\s*$", txt, re.S | re.M)
    if not m:
        sys.exit("szhr_align_expect: a_sz_head_gen not found in src/MKNJ.ASM")
    pairs = re.findall(r"\.long\s+ani_adjustxy\s*\n\s*\.word\s+(-?\d+),(-?\d+)", m.group(0))
    if len(pairs) != 3:
        sys.exit(f"szhr_align_expect: expected 3 ani_adjustxy rows, found {len(pairs)}")
    cum, x, y = [(0, 0)], 0, 0
    for dx, dy in pairs:
        x += int(dx); y += int(dy)
        cum.append((x, y))
    return cum                                    # index 0..3 == beats 4..7


def spine_geometry():
    """SPINERIP1-4 as the ROM carries them - src/SZSPINE.TBL is what links."""
    txt = (ROOT / "src" / "SZSPINE.TBL").read_text(encoding="latin-1")
    out = {}
    for name, w, h, ax, ay in re.findall(
            r"^(\w+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)", txt, re.M):
        out[name] = (int(w), int(h), int(ax), int(ay))
    return out


def facing_space(cum_dx, cum_dy, w, anix, aniy):
    """Expected facing-space centre/top of a prop, both facings."""
    unflipped = cum_dx - anix + (w - 1) // 2
    flipped = cum_dx - anix + w - (w - 1) // 2
    return unflipped, flipped, cum_dy - aniy


def build():
    spiner = read_img(ROOT / "data" / "SPINERIP.IMG")
    spine_tbl = spine_geometry()
    cum = head_travel()

    sz = {}
    for stem in set(SZ_LIBS.values()):
        sz.update(read_img(ROOT / "data" / f"{stem}.IMG"))

    drift = [(n, FIST_BASIS[n], sz.get(n)) for n in FIST_BASIS if sz.get(n) != FIST_BASIS[n]]

    heads = sorted(n for n in spiner if n.endswith("SPINE1") or n == "LKSPINEHEAD1")
    lines = [
        "-- GENERATED by tools/szhr_align_expect.py - do not edit.",
        "-- Where the head-rip props must be drawn, relative to Sub-Zero's anchor,",
        "-- IN FACING SPACE.  Same numbers whichever way he is turned: that is what",
        "-- 'the mirror is toward him' means, and it is what the rig asserts.",
        "return {",
        "  fist = {",
    ]
    for b in sorted(BEATS):
        x0, x1, y0, y1 = FIST[b]
        lines.append(f"    [{b}] = {{x0={x0}, x1={x1}, y0={y0}, y1={y1}}},")
    lines += ["  },", "  spine = {"]
    for b, (_frames, rec) in sorted(BEATS.items()):
        w, _h, ax, ay = spine_tbl[rec]
        unf, fl, top = facing_space(cum[b - 4][0], cum[b - 4][1], w, ax, ay)
        lines.append(f"    [{b}] = {{rec='{rec}', cx={unf}, cx_flip={fl}, top={top}, w={w}}},")
    lines += ["  },", "  head = {"]
    for rec in heads:
        w, _h, ax, ay = spiner[rec]
        per = []
        for b in sorted(BEATS):
            unf, fl, top = facing_space(cum[b - 4][0], cum[b - 4][1], w, ax, ay)
            per.append(f"[{b}]={{cx={unf}, cx_flip={fl}, top={top}}}")
        lines.append(f"    ['{rec}'] = {{w={w}, " + ", ".join(per) + "},")
    lines += ["  },", "}", ""]
    return "\n".join(lines), drift


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    text, drift = build()
    if drift:
        for name, want, got in drift:
            print(f"  {name}: fist measured against {want}, art now {got}")
        sys.exit("szhr_align_expect: Sub-Zero's head-rip poses MOVED - the authored "
                 "fist boxes in FIST{} were measured against the old art and must be "
                 "re-measured off a render before this can be trusted.")

    if a.check:
        if not OUT.exists():
            sys.exit(f"szhr_align_expect: {OUT} missing - run without --check")
        if OUT.read_text(encoding="utf-8") != text:
            sys.exit(f"szhr_align_expect: {OUT} is stale - re-run without --check")
        print(f"OK: {OUT.name} matches the art")
        return
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
