#!/usr/bin/env python3
r"""UMK3 SINDEL, ripped out of C:\MAME\roms\umk3.zip into two libraries and two
packs - data/UMK3SDA.IMG + data/UMK3SDA.LOD and data/UMK3SDB.IMG +
data/UMK3SDB.LOD - for the Wolf build's Sindel (hidden: a START tap on Mileena
Tsung's select cell; no run, no dial-a-combos; doc/WOLF_CONTENT_PLAN.md).

LANE-DRIVEN, NOT TABLE-DRIVEN (unlike make_umk3sonya.py).  What is packed is
exactly the pieces her own animation tables draw - `character_anitabs1/2`
entry 6 (MK3's MKGUYS order, "lia"): TABLE1 FF88C760 (42h rows) and TABLE2
FF88D080 (11 rows) - less the ones only her RUN lane (TABLE1 3Eh) draws.

  * UMK3 keeps her headers in one run from FFC271C0 that is MK3's MKLIA.TBL +
    MKLIA2.TBL + MKLIA3.TBL record for record, until MKLIA3's third record
    (the SMDRIP records changed).  Every header in that run is proved against
    MK3's geometry and control word and takes MK3's own name.
  * The 45 pieces past it are UMK3's own and MK3 has no name for them:
    her HAIR WRAP (TABLE2 0Ah, 36 pieces -> SNHAIR1.., POF> in her costume) and
    the redrawn FIREBALL (TABLE1 24h, palette FFDD5760, 9 -> SNFIREB1..).
  * Body pieces are drawn in whichever costume she wears (LPRP_P opens the
    group) and pack POF> at 6bpp; every effect keeps its own palette, PON>.
  * One library this size (~2 MB) is past LOAD2's ceiling (garbled names,
    then a prompt inside DOSBox - make_umk3sonya.py), so the records are dealt
    in lane order into two IMGs and two LODs.

    python tools/make_umk3sindel.py            # report
    python tools/make_umk3sindel.py --apply    # write IMGs, LODs, sheets
    python tools/make_umk3sindel.py --check    # still umk3.zip's (+ the packs)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from umk3rom import UMK3   # noqa: E402
import make_mk1pit as pit  # noqa: E402
import make_umk3sonya as sny  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "tmp" / "umk3sindel"
LIA = 6
TAB1, TAB2 = 0xFF88C760, 0xFF88D080
TAB1_ROWS, TAB2_ROWS = 0x42, 11
RUN_ROW = 0x3E
HDR_RUN = 0xFFC271C0
MK3_TABLES = ("MKLIA.TBL", "MKLIA2.TBL", "MKLIA3.TBL")
# UMK3-only palettes, named here (MK3 has neither)
OWN_PALS = {0xFFDD5760: ("SNFIREB_P", "SNFIREB")}
# the hair wrap opens no group: it is POF> body art (her hair) in her costume
HAIR_ROW = ("2", 0x0A)
# Wolf linear runs (makevrom.py wolf_irw_files): A at 0xD6A000 just above
# LAIRWALL (packs to 365,008 B), B at 0xDC8000 right after it - B is
# placed after A's measured size - see PACKS
# MK3 families drawn on objects of their own, in their own palettes
EFFECTS = ((r"^LISHOKWAV", "SHOCK_P"), (r"^LIFLASH", "LIFLASH_P"),
           (r"^LIASPIT", "LIASPIT_P"), (r"^LIAXPLOD", "LIXPLOD_P"), (r"^TOP", "FLESH_P"))
PACKS = (("UMK3SDA", 0x4B50000), ("UMK3SDB", 0x4E40000))
SPLIT_BYTES = 1_050_000          # IMG size at which records move to the B library


def lin(lod):
    return 0x800000 + (lod - 0x2000000) // 8


def walk(u, a, stop):
    """sny.walk, carried on PAST a loop: MK3 lanes keep further parts after
    an `ani_jump` (a_projectile's hit explosion, the scream's lean back) -
    `.long ani_jump,loop / .long 0 / more frames` - which find_part2 reaches
    by skipping the 0.  Only a 0 followed by a real frame continues."""
    out = []
    while True:
        ev = sny.walk(u, a, stop)
        out += ev
        if not ev or ev[-1][0] != "JUMP":
            return out
        n = sum(1 for e in ev if e[0] in ("FRAME", "END"))  # 32 bits each
        a += 32 * n + sum(32 + sny.OPS[int(e[0][3:])] for e in ev if e[0].startswith("CMD"))
        a += 64 * sum(1 for e in ev if e[0] in ("SLADD", "JUMP"))
        if not (a + 32 < stop and u.l(a) == 0 and sny.pieces(u, u.l(a + 32)) is not None):
            return out
        out.append(("END",))
        a += 32


def lanes(u):
    t1, t2 = u.l(sny.ANITABS1 + 32 * LIA), u.l(sny.ANITABS2 + 32 * LIA)
    if (t1, t2) != (TAB1, TAB2):
        raise SystemExit(f"Sindel's tables are {t1:08X}/{t2:08X} - wrong umk3.zip?")
    rows = [("1", k, u.l(t1 + 32 * k)) for k in range(TAB1_ROWS)]
    rows += [("2", k, u.l(t2 + 32 * k)) for k in range(TAB2_ROWS)]
    starts = sorted({a for _t, _k, a in rows if sny.inside(a)} | {t1, t2})
    out = []
    for tab, k, a in rows:
        if sny.inside(a):
            nxt = next((b for b in starts if b > a), a + 32 * 200)
            out.append((tab, k, a, walk(u, a, min(nxt, a + 32 * 400))))
    return out


def lane_pieces(u, L):
    """{piece: {(tab, row)}} in first-drawn order"""
    out = {}
    for tab, k, _a, ev in L:
        for e in ev:
            if e[0] in ("FRAME", "SLADD") and e[1]:
                for p in sny.pieces(u, e[1]) or []:
                    out.setdefault(p, set()).add((tab, k))
    return out


def read(u):
    L = lanes(u)
    P = lane_pieces(u, L)
    P = {p: s for p, s in P.items() if s != {("1", RUN_ROW)}}
    mk3 = [t for name in MK3_TABLES for t in sny.tbl_records(name)]
    # walk UMK3's header run, naming each header MK3's way while it still is MK3's
    hdr, a, k, grp, matched = {}, HDR_RUN, 0, None, True
    top = max(P)
    while a <= top:
        h = sny.header(u, a)
        v = u.l(a + sny.HDR_BITS)
        has = sny.is_pal(u, v)
        if has:
            grp = v
        name = None
        if matched and k < len(mk3):
            rec, g, ctrl, pal = mk3[k]
            if (h["w"], h["h"], h["ax"], h["ay"]) == g and h["ctrl"] == ctrl and bool(pal) == has:
                name = rec
            else:
                matched = False
        hdr[a] = (name, grp, has)
        a += sny.HDR_BITS + (32 if has else 0)
        k += 1
    missing = [p for p in P if p not in hdr]
    if missing:
        raise SystemExit(f"{len(missing)} lane pieces are not in the header run ({missing[0]:08X})")
    pal_names = {}
    for rec, _g, _c, pal in mk3:
        pass
    # palette names: the MK3 record that opens a group names its palette
    for a2, (name, grp, has) in hdr.items():
        if has and name:
            rec = next(t for t in mk3 if t[0] == name)
            pal_names[grp] = rec[3]
    pal_names.update({v: n for v, (n, _s) in OWN_PALS.items()})
    costume = hdr[HDR_RUN][1]
    if pal_names.get(costume) != "LPRP_P":
        raise SystemExit("her first header does not open LPRP_P - wrong umk3.zip?")
    hdr = {a2: (n, (costume if g is None else g), h2) for a2, (n, g, h2) in hdr.items()}
    by_pal = {n: v for v, n in pal_names.items()}
    count = {}
    named, recs = {}, []
    for p in sorted(P):
        name, grp, _has = hdr[p]
        if name is None:
            if grp in OWN_PALS:
                stem = OWN_PALS[grp][1]
            elif P[p] == {HAIR_ROW}:
                stem, grp = "SNHAIR", costume
            else:
                raise SystemExit(f"{p:08X}: no MK3 name, palette {grp:08X}, lanes {P[p]}")
            count[stem] = count.get(stem, 0) + 1
            name = f"{stem}{count[stem]}"
        else:
            # a POF> body record sits inside whatever group the TBL is in
            # (LIHOVR follows SHOCK_P), so the family decides, not the group
            fam = next((pn for rx, pn in EFFECTS if re.match(rx, name)), None)
            grp = by_pal[fam] if fam else costume
        h = sny.header(u, p)
        rows, _bpp = pit.decode_record(u.g, h["sag"], h["w"], h["h"], h["ctrl"])
        r = dict(h, name=name.upper(), addr=p, pal=grp, lanes=P[p])
        r["px"] = bytes(v for row in rows for v in row)
        if grp not in named:
            named[grp] = (pal_names[grp], u.palette(grp))
        if max(r["px"]) >= len(named[grp][1]):
            raise SystemExit(f"{r['name']} indexes past {named[grp][0]}")
        recs.append(r)
    if len({r["name"] for r in recs}) != len(recs):
        raise SystemExit("two records share a name")
    return recs, named, costume, L


def deal(recs):
    """Lane order, body first: A until SPLIT_BYTES of IMG, then B."""
    def key(r):
        t, k = min(r["lanes"])
        return (t, k, r["addr"])
    out, size, half = ([], []), 0, 0
    for r in sorted(recs, key=key):
        size += r["w"] * r["h"] + 32
        if size > SPLIT_BYTES:
            half = 1
        out[half].append(r)
    return out


def build_img(recs, named):
    pals = [a for a in named if any(r["pal"] == a for r in recs)]
    entries = [(r["name"], r["ax"], r["ay"], r["w"], r["h"], r["px"], pals.index(r["pal"]))
               for r in recs]
    return pit.build_img(entries, [(named[a][0], 6, named[a][1]) for a in pals])


def build_lod(stem, base, recs, named, costume):
    body = [r["name"] for r in recs if r["pal"] == costume]
    own = {}
    for r in recs:
        if r["pal"] != costume:
            own.setdefault(r["pal"], []).append(r["name"])

    def lst(names):
        return ["---> " + ",".join(names[i:i + 8]) for i in range(0, len(names), 8)]

    out = [f"***> {base:X},1", "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
           ";" + "*" * 62, ";",
           ";  UMK3 SINDEL (Wolf only) - GENERATED by tools/make_umk3sindel.py --apply",
           f";  out of umk3.zip (data/{stem}.IMG).  Linear 0x{lin(base):X}.  Body POF>",
           ";  (drawn in her costume palette), effects PON>.",
           ";", ";" + "*" * 62, "ZON>", f"ASM> {stem}.TBL", f"{stem}.IMG"]
    if body:
        out += ["POF>", "PPP> 6"] + lst(body)
    for pal, names in own.items():
        out += ["PON>", f"PPP> {max(1, (len(named[pal][1]) - 1).bit_length())}"] + lst(names)
    return "\n".join(out) + "\n"


def sheets(recs, named, L, u):
    from PIL import Image
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for p in OUT_DIR.glob("lane*.png"):
        p.unlink()
    by_addr = {r["addr"]: r for r in recs}
    lines = [f"UMK3 SINDEL (umk3.zip) - {len(L)} lanes, {len(recs)} records packed", ""]
    for tab, k, a, ev in L:
        lines.append(f"table{tab} {k:02X} {a:08X}")
        ims = []
        for e in ev:
            if e[0] in ("FRAME", "SLADD") and e[1]:
                ps = [by_addr.get(p) for p in sny.pieces(u, e[1])]
                lines.append(f"    {e[0]:6s} {e[1]:08X}  " + " ".join(r["name"] if r else "-" for r in ps))
                ps = [r for r in ps if r]
                if not ps:
                    continue
                x0 = min(-r["ax"] for r in ps); y0 = min(-r["ay"] for r in ps)
                x1 = max(r["w"] - r["ax"] for r in ps); y1 = max(r["h"] - r["ay"] for r in ps)
                im = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
                for r in ps:
                    pal = named[r["pal"]][1]
                    for i, v in enumerate(r["px"]):
                        if v:
                            im.putpixel((i % r["w"] - r["ax"] - x0, i // r["w"] - r["ay"] - y0),
                                        pit.rgb(pal[v]) + (255,))
                ims.append((im, -y0))
            else:
                lines.append("    " + " ".join(f"{x:08X}" if isinstance(x, int) else str(x)
                                                for x in e if x is not None))
        if ims:
            ay = max(o for _i, o in ims)
            H = ay + max(i.height - o for i, o in ims)
            cv = Image.new("RGB", (sum(i.width + 6 for i, _o in ims), max(H, 1)), (24, 24, 32))
            x = 0
            for im, o in ims:
                cv.paste(im, (x, ay - o), im)
                x += im.width + 6
            cv.save(OUT_DIR / f"lane{tab}_{k:02X}.png")
    (OUT_DIR / "lanes.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    u = UMK3()
    recs, named, costume, L = read(u)
    halves = deal(recs)
    print(f"UMK3 SINDEL: {len(recs)} records, ~{sum(r['w'] * r['h'] for r in recs) * 6 // 8:,} B "
          f"at flat 6bpp; palettes " + ", ".join(f"{n} ({len(w)})" for n, w in named.values()))
    outs = []
    for (stem, base), part in zip(PACKS, halves):
        img = build_img(part, named)
        lod = build_lod(stem, base, part, named, costume)
        outs.append((stem, base, part, img, lod))
        print(f"  {stem}: {len(part)} records, IMG {len(img):,} B, linear 0x{lin(base):X}")
    if a.apply:
        for stem, _b, _p, img, lod in outs:
            (ROOT / "data" / f"{stem}.IMG").write_bytes(img)
            (ROOT / "data" / f"{stem}.LOD").write_text(lod, newline="\r\n")
        sheets(recs, named, L, u)
        print(f"wrote {', '.join(s for s, *_ in outs)} + {OUT_DIR.relative_to(ROOT)}/")
    if a.check:
        for stem, base, part, img, lod in outs:
            if (ROOT / "data" / f"{stem}.LOD").read_text() != lod:
                raise SystemExit(f"data/{stem}.LOD has drifted - rerun --apply")
            if (ROOT / "data" / f"{stem}.IMG").read_bytes() != img:
                raise SystemExit(f"data/{stem}.IMG has drifted from umk3.zip - rerun --apply")
            sny.verify_pack(part, stem, base)
        print("UMK3 SINDEL libraries and packs match umk3.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
