#!/usr/bin/env python3
r"""Prove the BUILT Wolf ROM's Sindel lanes draw what UMK3's do.

Walks every row of our `sindel_anitab1` that names a UMK3 lane, and every
row of `sindel_anitab2`, side by side with the UMK3 lane it was decompiled
from (umk3.zip), following jumps on both sides (a visited PAIR ends a loop),
and requires the same command stream: the same commands with the same
operands, and every frame the same pieces - geometry AND decoded pixels, each
out of its own image ROM.  ani_calla targets are compared through the map in
make_umk3sindel_asm.CALLA.

    python tools/sindel_lane_proof.py [--rom rom/wolf/umk3.zip] [--map tmp/wolf/src/mk2.map]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from umk3rom import UMK3                  # noqa: E402
import make_mk1pit as pit                 # noqa: E402
import make_umk3sonya as sny              # noqa: E402
import make_umk3sindel as rip             # noqa: E402
import make_umk3sindel_asm as gen         # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def symbols(mp):
    out = {}
    for ln in Path(mp).read_text(errors="replace").splitlines():
        for m in re.finditer(r"([0-9a-f]{8}) (\w+)", ln):
            out.setdefault(m.group(2), int(m.group(1), 16))
    return out


def piece_key(u, p, cache):
    if p not in cache:
        h = sny.header(u, p)
        rows, _ = pit.decode_record(u.g, h["sag"], h["w"], h["h"], h["ctrl"])
        cache[p] = (h["w"], h["h"], h["ax"], h["ay"], bytes(v for r in rows for v in r))
    return cache[p]


def step(u, a):
    """(event, next address or None, jump target or None)"""
    v = u.l(a)
    if v == 0:
        return ("end",), a + 32, None
    if v == 1:
        return ("jump",), None, u.l(a + 32)
    if v in (3, 4, 10):
        n = sny.OPS[v] // 16
        return ("cmd", v, tuple(u.sw(a + 32 + 16 * i) for i in range(n))), a + 32 + sny.OPS[v], None
    if v == 6:
        return ("calla", u.l(a + 32)), a + 64, None
    if v == 11:
        return ("sladd", u.l(a + 32)), a + 64, None
    if v <= 15:
        return ("cmd", v, ()), a + 32 + sny.OPS[v], None
    return ("frame", v), a + 32, None


def compare(us, them, a_us, a_them, calla, caches, limit=400, first_part=False):
    seen = set()
    n = 0
    while n < limit:
        if (a_us, a_them) in seen:
            return n, None
        seen.add((a_us, a_them))
        e1, n1, j1 = step(us, a_us)
        e2, n2, j2 = step(them, a_them)
        # UMK3's lane data stops where the next words are no longer lane
        # entries (a frame LIST follows it in ROM); everything up to here matched
        if e2[0] in ("frame", "sladd") and sny.pieces(them, e2[1]) is None:
            return n, None
        if e1[0] != e2[0]:
            return n, f"{a_us:08X}/{a_them:08X}: {e1[0]} vs {e2[0]}"
        k = e1[0]
        if k in ("frame", "sladd"):
            p1, p2 = sny.pieces(us, e1[1]), sny.pieces(them, e2[1])
            if p1 is None or p2 is None or len(p1) != len(p2):
                return n, f"{a_us:08X}: frame lists differ in length"
            for x, y in zip(p1, p2):
                if piece_key(us, x, caches[0]) != piece_key(them, y, caches[1]):
                    return n, f"{a_us:08X}: piece {x:08X} is not UMK3's {y:08X}"
        elif k == "calla":
            if calla.get(e2[1]) != e1[1]:
                return n, f"{a_us:08X}: calla {e1[1]:08X} vs UMK3 {e2[1]:08X}"
        elif e1 != e2:
            return n, f"{a_us:08X}: {e1} vs {e2}"
        n += 1
        if first_part and k == "end":
            return n, None      # an MK2_SHAPE row: ours carries MK2's own parts after this
        if k == "jump":
            a_us, a_them = j1, j2
        else:
            a_us, a_them = n1, n2
    return n, None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rom", default=str(ROOT / "rom" / "wolf" / "umk3.zip"))
    ap.add_argument("--map", default=str(ROOT / "tmp" / "wolf" / "src" / "mk2.map"))
    a = ap.parse_args()
    us, them = UMK3(Path(a.rom)), UMK3()
    sym = symbols(a.map)
    calla = {k: sym[v] for k, v in gen.CALLA.items() if v in sym}
    if len(calla) != len(gen.CALLA):
        raise SystemExit(f"map lacks {set(gen.CALLA.values()) - set(sym)}")
    names = gen.lane_names()
    t1u, t2u = sym["sindel_anitab1"], sym["sindel_anitab2"]
    t1t, t2t = rip.TAB1, rip.TAB2
    pairs = []
    for k, v in enumerate(gen.TABLE1):
        if v != "kt":
            pairs.append((f"TABLE1 {k:02x} {v}", us.l(t1u + 32 * k), them.l(t1t + 32 * gen.umk3_row(names["1"], v))))
    for k in range(rip.TAB2_ROWS):
        mine = us.l(t2u + 32 * k)
        if mine:
            pairs.append((f"TABLE2 {k:x} {names['2'][k]}", mine, them.l(t2t + 32 * k)))
    caches = ({}, {})
    bad = 0
    total = 0
    for what, x, y in pairs:
        row = int(what.split()[1], 16) if what.startswith("TABLE1") else -1
        n, err = compare(us, them, x, y, calla, caches, first_part=row in gen.MK2_SHAPE)
        total += n
        if err:
            bad += 1
            print(f"  BAD  {what}: {err}")
    print(f"{len(pairs) - bad} of {len(pairs)} lanes identical to UMK3 ({total} steps, "
          f"{len(caches[0])} pieces decoded)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
