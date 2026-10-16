#!/usr/bin/env python3
r"""MK3/UMK3 SONYA BLADE, ripped out of C:\MAME\roms\umk3.zip into data/UMK3SNYA.IMG
plus her pack data/UMK3SNY.LOD - for the Wolf build's Sonya (Shang Tsung's morph
only, her full move set, no run and no dial-a-combos; doc/WOLF_CONTENT_PLAN.md).

THE ART IS MK3'S, AND THE TABLES SAY SO.  MK3's arcade source
(MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13) carries her record tables,
MKSONYA.TBL (444 records) then MKSONYA2.TBL (54), and UMK3 packs exactly those
headers, in exactly that order, at FFBCF230..FFBDCCF0 of its program ROM: every
one of the 498 matches width, height, anipoint and control word, and
MKSONYA.TBL's SAGs ARE UMK3's (SBSTANCE1A 05199B0h).  So every record is taken
positionally off that table, under MK3's own name, its pixels decoded at the
UMK3 SAG.  The run frames (SBRUN*) are left out - she has no run here.

  * A header carries a palette only when it opens a group (the .long after it
    in the TBL); body records are drawn in whichever costume she wears
    (SBSTANCE1A's SBGREEN_P, 1B's SBLTBLU_P - `character_palettes_1/2` row 1),
    so they pack POF>.  The effects keep their own palettes and pack PON>:
    the energy ring (SBENG5, SBZAP6-16: sbzap_p), the blood drops (dROP_p),
    the kiss (SPARKIS_P, KISSORB_P), the kiss's energy ball (ENGPINK_P, named
    by MK3's hand-written FAKE_ENGBALL1 header) and the guts (GUTS_P).
  * Her animation tables (`character_anitabs1/2` FFB02B90 / FFB02ED0, MK3's
    MKGUYS order - Kano 0, Sonya 1: FF836EB0 42h rows, FF8377D0 6 rows) are
    walked too, for the per-lane sheets in tmp/umk3sonya/ and to prove every
    piece a lane draws is one of the 498.

    python tools/make_umk3sonya.py            # report
    python tools/make_umk3sonya.py --apply    # write the IMG, the LOD and the sheets
    python tools/make_umk3sonya.py --check    # IMG + LOD still match umk3.zip
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from umk3rom import UMK3   # noqa: E402
import make_mk1pit as pit  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT_IMG = ROOT / "data" / "UMK3SNYA.IMG"
OUT_FIMG = ROOT / "data" / "UMK3SNFA.IMG"     # her fatality art (see main)
OUT_LOD = ROOT / "data" / "UMK3SNY.LOD"
# the fatality art (MK3's shared SBFIRE / SKELFIRE) is a LOD of its own: with
# it in UMK3SNY.LOD, 521 records, LOAD2 garbled the names it was reading
# ("Image Library [C:\DATA\<junk>] could not be opened") and sat on a prompt
# for good - 483 records was fine.  Same IMG, next free Wolf run.
OUT_FAT = ROOT / "data" / "UMK3SNF.LOD"
OUT_DIR = ROOT / "tmp" / "umk3sonya"
MK3SRC = Path("C:/Users/you/Workplace/MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13")
TABLES = (("MKSONYA.TBL", 0xFFBCF230), ("MKSONYA2.TBL", 0xFFBDB510))
TABLES_END = 0xFFBDCCF0
DROP = re.compile(r"^SBRUN")            # no run
# effects: drawn on objects of their own, in their own palettes
EFFECT = re.compile(r"^(SBENG5|SBZAP|SBDROP|SPARKISS|KISSORB|ENGBALL|GUTS)")
# Wolf only: linear 0xC88000 (just above SCORPION'S LAIR's floor), LOD form
# 0x2000000 + (linear - 0x800000) * 8 - makevrom.py's wolf_irw_files rule
LOD_BASE = 0x4440000
FAT_BASE = 0x4980000         # Wolf linear 0xD30000, past UMK3SNY's ~634 KB
HDR_BITS = 112
# MK3 MKFATAL.TBL records the fatalities need: the run starts at SBFIRE1's
# UMK3 header and stops after FATAL_LAST, keeping FATAL_KEEP
FATAL_RUN = ("SBFIRE1", 0xFFD41490)
FATAL_LAST = "SKELFIRE24A"
FATAL_KEEP = re.compile(r"^(SBFIRE|SKELFIRE)\d")
SONYA = 1
ANITABS1, ANITABS2 = 0xFFB02B90, 0xFFB02ED0
TAB1_ROWS, TAB2_ROWS = 0x42, 6
# command -> operand bits; 1 (jump) ends the walk (MK3 MKANI.ASM)
OPS = {0: 0, 2: 0, 3: 16, 4: 32, 5: 0, 6: 32, 7: 32, 8: 64, 9: 0, 10: 32,
       11: 32, 12: 0, 13: 0, 14: 0, 15: 16}


# --------------------------------------------------------------------------
# MK3's tables
# --------------------------------------------------------------------------
def tbl_records(name):
    """[(record, (w, h, anix, aniy), control, palette name or None)]"""
    lines = (MK3SRC / name).read_text(errors="replace").splitlines()
    out = []
    for i, ln in enumerate(lines):
        m = re.match(r"^(\w+):\s*$", ln)
        if not m:
            continue
        g = tuple(int(v) for v in re.findall(r"-?\d+", lines[i + 1]))
        ctrl = int(re.search(r"([0-9a-fA-F]+)[hH]", lines[i + 3]).group(1), 16)
        p = re.match(r"\s*\.long\s+(\w+)\s*$", lines[i + 4]) if i + 4 < len(lines) else None
        out.append((m.group(1), g, ctrl, p.group(1).upper() if p else None))
    return out


def lane_names():
    txt = (MK3SRC / "MKSONYA.ASM").read_text(errors="replace").splitlines()
    out = {}
    for tab in ("sonya_anitab1", "sonya_anitab2"):
        i = next(n for n, ln in enumerate(txt) if ln.strip() == tab) + 1
        names = []
        while i < len(txt):
            s = txt[i].split(";")[0].strip()
            i += 1
            if not s:
                if names and txt[i - 1].strip() == "":
                    if not txt[i].strip().startswith(".long"):
                        break
                continue
            m = re.match(r"\.long\s+(\w+)", s)
            if not m:
                break
            names.append(m.group(1))
        out[tab[-1]] = names
    return out


# --------------------------------------------------------------------------
# the ROM
# --------------------------------------------------------------------------
def inside(a):
    return 0xFF800000 <= a <= 0xFFFFFFF0 and (a & 15) == 0


def header(u, a):
    return dict(w=u.w(a), h=u.w(a + 16), ax=u.sw(a + 32), ay=u.sw(a + 48),
                sag=u.l(a + 64), ctrl=u.w(a + 96))


def is_pal(u, v):
    return inside(v) and 1 <= u.w(v) <= 256


def records(u):
    """Every record, in table order, off UMK3's own header table."""
    out, pal_of = [], {}
    for name, a in TABLES:
        group = None
        for rec, g, ctrl, pal in tbl_records(name):
            h = header(u, a)
            if (h["w"], h["h"], h["ax"], h["ay"]) != g or h["ctrl"] != ctrl:
                raise SystemExit(f"{rec}: UMK3's header at {a:08X} is not MK3's - wrong umk3.zip?")
            if pal:
                group = u.l(a + HDR_BITS)
                if not is_pal(u, group):
                    raise SystemExit(f"{rec}: {group:08X} is not a palette")
                pal_of.setdefault(group, pal)
            out.append(dict(h, name=rec, addr=a, group=group))
            a += HDR_BITS + (32 if pal else 0)
        if name == "MKSONYA.TBL" and a != TABLES[1][1]:
            raise SystemExit(f"MKSONYA.TBL ends at {a:08X}, not where MKSONYA2.TBL starts")
    if a != TABLES_END:
        raise SystemExit(f"the header table ends at {a:08X}, not {TABLES_END:08X}")
    return out, pal_of


def pieces(u, f):
    if not inside(f):
        return None
    out, a = [], f
    for _ in range(16):
        p = u.l(a)
        if p == 0:
            return out or None
        if not inside(p):
            return None
        h = header(u, p)
        if not (1 <= h["w"] <= 400 and 1 <= h["h"] <= 300 and h["sag"] < 0xC000000):
            return None
        out.append(p)
        a += 32
    return None


def walk(u, a, stop):
    out = []
    while inside(a) and a < stop:
        v = u.l(a)
        if v == 0:
            out.append(("END",))
            a += 32
            continue
        if v == 1:
            out.append(("JUMP", u.l(a + 32)))
            break
        if v in OPS:
            out.append(({11: "SLADD"}.get(v, f"CMD{v}"), u.l(a + 32) if v == 11 else None))
            a += 32 + OPS[v]
            continue
        if pieces(u, v) is None:
            break
        out.append(("FRAME", v))
        a += 32
    return out


def lanes(u):
    t1, t2 = u.l(ANITABS1 + 32 * SONYA), u.l(ANITABS2 + 32 * SONYA)
    if (t1, t2) != (0xFF836EB0, 0xFF8377D0):
        raise SystemExit(f"Sonya's tables are {t1:08X}/{t2:08X} - wrong umk3.zip?")
    rows = [("1", k, u.l(t1 + 32 * k)) for k in range(TAB1_ROWS)]
    rows += [("2", k, u.l(t2 + 32 * k)) for k in range(TAB2_ROWS)]
    starts = sorted({a for _t, _k, a in rows if inside(a)} | {t1, t2})
    out = []
    for tab, k, a in rows:
        if inside(a):
            nxt = next((b for b in starts if b > a), a + 32 * 200)
            out.append((tab, k, a, walk(u, a, min(nxt, a + 32 * 400))))
    return out


# --------------------------------------------------------------------------
def read(u):
    recs, pal_of = records(u)
    by_addr = {r["addr"]: r for r in recs}
    by_sag = {}
    for r in recs:
        by_sag.setdefault((r["sag"], r["w"], r["h"]), r)
    L = lanes(u)
    # every piece a lane draws is one of the table's records (a hand-written
    # header elsewhere, MK3's FAKE_*, draws a table record's pixels)
    fakes = {}
    for _t, _k, _a, ev in L:
        for e in ev:
            if e[0] in ("FRAME", "SLADD") and e[1]:
                for p in pieces(u, e[1]) or []:
                    if p in by_addr:
                        continue
                    h = header(u, p)
                    r = by_sag.get((h["sag"], h["w"], h["h"]))
                    if r is None:
                        raise SystemExit(f"lane piece {p:08X} is none of the 498 records")
                    fakes[p] = r
    # the energy ball and the guts are drawn in their FAKE header's palette
    fake_pal = {}
    for p, r in fakes.items():
        v = u.l(p + HDR_BITS)
        if is_pal(u, v):
            fake_pal[r["name"]] = v
    pal_name = dict(pal_of)
    by_pal_name = {v: k for k, v in pal_of.items()}
    named = {}
    costume = [u.l(recs[0]["addr"] + HDR_BITS), u.l(recs[1]["addr"] + HDR_BITS)]
    for a in costume:
        named[a] = (pal_name[a], u.palette(a))
    keep = []
    for r in recs:
        if DROP.match(r["name"]):
            continue
        rows, _bpp = pit.decode_record(u.g, r["sag"], r["w"], r["h"], r["ctrl"])
        r["px"] = bytes(v for row in rows for v in row)
        if EFFECT.match(r["name"]):
            stem = re.match(r"^[A-Z]+", r["name"]).group(0)
            if stem in ("ENGBALL", "GUTS"):
                # ENGBALL15B, the ball crushed to pulp, is authored on GUTS_P in
                # MK3's own library (deadlythirdcombat BLADE11.IMG palnum 9,
                # every other ball frame is ENGPINK_P)
                src = "GUTS" if stem == "GUTS" or r["name"] == "ENGBALL15B" else "ENGBALL1"
                r["pal"] = fake_pal[src]
                pal_name.setdefault(r["pal"], "GUTS_P" if src == "GUTS" else "ENGPINK_P")
            else:
                # MKSONYA2.TBL INTERLEAVES its groups (SPARKISS1, KISSORB1,
                # SPARKISS2, KISSORB2 ...), so the palette is the one its
                # family's opening record names, not the last one above it
                fam = {"SBENG": "SBZAP_P", "SBZAP": "SBZAP_P", "SBDROP": "DROP_P",
                       "SPARKISS": "SPARKIS_P", "KISSORB": "KISSORB_P"}[stem]
                r["pal"] = by_pal_name[fam]
        else:
            r["pal"] = costume[0]
        if r["pal"] not in named:
            named[r["pal"]] = (pal_name[r["pal"]], u.palette(r["pal"]))
        if max(r["px"]) >= len(named[r["pal"]][1]):
            raise SystemExit(f"{r['name']} indexes past {named[r['pal']][0]}")
        keep.append(r)
    # the fire kiss (fatality 1) burns him down to a skeleton on MK3's SHARED
    # fatality art - SBFIRE1/2 and, because a_sb_skeleton_burn has no
    # terminator, the SKELFIRE1-24 collapse it runs on into (MKFATAL.ASM).
    # Not her tables: UMK3 keeps MKFATAL.TBL's headers in one run, walked from
    # SBFIRE1's and each proved against MK3's geometry
    name0, a = FATAL_RUN
    tab = tbl_records("MKFATAL.TBL")
    k = next(n for n, t in enumerate(tab) if t[0] == name0)
    group = None
    for rec, g, ctrl, pal in tab[k:]:
        h = header(u, a)
        if (h["w"], h["h"], h["ax"], h["ay"]) != g or h["ctrl"] != ctrl:
            raise SystemExit(f"{rec}: UMK3's header at {a:08X} is not MK3's - wrong umk3.zip?")
        if pal:
            group = (u.l(a + HDR_BITS), pal)
            if not is_pal(u, group[0]):
                raise SystemExit(f"{rec}: {group[0]:08X} is not a palette")
        nxt = a + HDR_BITS + (32 if pal else 0)
        if FATAL_KEEP.match(rec):
            r = dict(h, name=rec, addr=a, group=None)
            rows, _bpp = pit.decode_record(u.g, r["sag"], r["w"], r["h"], r["ctrl"])
            r["px"] = bytes(v for row in rows for v in row)
            r["pal"] = group[0]
            if r["pal"] not in named:
                named[r["pal"]] = (group[1], u.palette(r["pal"]))
            if max(r["px"]) >= len(named[r["pal"]][1]):
                raise SystemExit(f"{rec} indexes past {group[1]}")
            keep.append(r)
        a = nxt
        if rec == FATAL_LAST:
            break
    return keep, named, L, by_addr, fakes


def build_img(recs, named):
    pal_list = list(named)
    entries = [(r["name"], r["ax"], r["ay"], r["w"], r["h"], r["px"], pal_list.index(r["pal"]))
               for r in recs]
    return pit.build_img(entries, [(named[a][0], 6, named[a][1]) for a in pal_list])


def build_lod(recs, named):
    """Body POF> at 6bpp (drawn in her costume palette, so the record carries
    none), then each effect palette's records PON> at that palette's depth."""
    costume = [a for a, (nm, _w) in named.items() if nm in ("SBGREEN_P", "SBLTBLU_P")]
    body = [r["name"] for r in recs if r["pal"] in costume]
    own = {}
    for r in recs:
        if r["pal"] not in costume and not FATAL_KEEP.match(r["name"]):
            own.setdefault(r["pal"], []).append(r["name"])

    def lst(names):
        return ["---> " + ",".join(names[i:i + 8]) for i in range(0, len(names), 8)]

    out = [f"***> {LOD_BASE:X},1", "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
           ";" + "*" * 62, ";",
           ";  MK3 SONYA (Wolf only) - GENERATED by tools/make_umk3sonya.py --apply",
           ";  out of umk3.zip (data/UMK3SNYA.IMG); every name is MK3's own.  Linear",
           f";  0x{0x800000 + (LOD_BASE - 0x2000000) // 8:X}.  Body POF> (drawn in her costume palette), effects PON>.",
           ";", ";" + "*" * 62,
           "POF>", "ZON>", "PPP> 6", "ASM> UMK3SNY.TBL", "UMK3SNYA.IMG"] + lst(body)
    for pal, names in own.items():
        nm, words = named[pal]
        out += ["PON>", f"PPP> {max(1, (len(words) - 1).bit_length())}"] + lst(names)
    return "\n".join(out) + "\n"


def build_fat_lod(recs, named):
    """MK3's shared fatality art her kiss draws, PON> at its palette's depth."""
    own = {}
    for r in recs:
        if FATAL_KEEP.match(r["name"]):
            own.setdefault(r["pal"], []).append(r["name"])
    out = [f"***> {FAT_BASE:X},1", "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
           ";" + "*" * 62, ";",
           ";  MK3 SONYA's FATALITY ART (Wolf only) - GENERATED by",
           ";  tools/make_umk3sonya.py --apply out of umk3.zip (MK3 MKFATAL.TBL's",
           f";  SBFIRE / SKELFIRE).  Linear 0x{0x800000 + (FAT_BASE - 0x2000000) // 8:X}.",
           ";", ";" + "*" * 62, "ZON>", "ASM> UMK3SNF.TBL", "UMK3SNFA.IMG"]
    for pal, names in own.items():
        nm, words = named[pal]
        out += ["PON>", f"PPP> {max(1, (len(words) - 1).bit_length())}"]
        out += ["---> " + ",".join(names[i:i + 8]) for i in range(0, len(names), 8)]
    return "\n".join(out) + "\n"


def draw_frame(u, f, by_addr, fakes, by_name, named):
    from PIL import Image
    ps = []
    for p in pieces(u, f):
        r = by_addr.get(p) or fakes[p]
        ps.append(by_name.get(r["name"]))
    ps = [r for r in ps if r]
    if not ps:
        return None, (0, 0)
    x0 = min(-r["ax"] for r in ps)
    y0 = min(-r["ay"] for r in ps)
    x1 = max(r["w"] - r["ax"] for r in ps)
    y1 = max(r["h"] - r["ay"] for r in ps)
    im = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
    for r in ps:
        pal = named[r["pal"]][1]
        for y in range(r["h"]):
            for x in range(r["w"]):
                v = r["px"][y * r["w"] + x]
                if v:
                    im.putpixel((x - r["ax"] - x0, y - r["ay"] - y0), pit.rgb(pal[v]) + (255,))
    return im, (-x0, -y0)


def sheets(u, recs, named, L, by_addr, fakes):
    from PIL import Image
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for p in OUT_DIR.glob("lane*.png"):
        p.unlink()
    names = lane_names()
    by_name = {r["name"]: r for r in recs}
    cache = {}
    lines = [f"UMK3 SONYA (umk3.zip) - {len(L)} lanes in her tables, {len(recs)} records packed", ""]
    for tab, k, a, ev in L:
        nm = names[tab][k] if k < len(names[tab]) else "umk3"
        lines.append(f"table{tab} {k:02X} {nm:24s} {a:08X}")
        ims = []
        for e in ev:
            if e[0] in ("FRAME", "SLADD") and e[1]:
                pn = [(by_addr.get(p) or fakes[p])["name"] for p in pieces(u, e[1])]
                lines.append(f"    {e[0]:6s} {e[1]:08X}  " + " ".join(pn))
                if e[1] not in cache:
                    cache[e[1]] = draw_frame(u, e[1], by_addr, fakes, by_name, named)
                if cache[e[1]][0] is not None:
                    ims.append(cache[e[1]])
            else:
                lines.append("    " + " ".join(str(x) if not isinstance(x, int) else f"{x:08X}"
                                                for x in e if x is not None))
        if ims:
            ax = max(o[0] for _i, o in ims)
            W = sum(max(i.width, 8) + 6 for i, _o in ims)
            H = ax and (max(o[1] for _i, o in ims) + max(i.height - o[1] for i, o in ims))
            ay = max(o[1] for _i, o in ims)
            cv = Image.new("RGB", (W, max(H, 1)), (24, 24, 32))
            x = 0
            for im, (_px, py) in ims:
                cv.paste(im, (x, ay - py), im)
                x += max(im.width, 8) + 6
            cv.save(OUT_DIR / f"lane{tab}_{k:02X}_{nm}.png")
    (OUT_DIR / "lanes.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    u = UMK3()
    recs, named, L, by_addr, fakes = read(u)
    nbytes = sum(r["w"] * r["h"] for r in recs) * 6 // 8
    print(f"UMK3 SONYA: {len(recs)} records (MK3's tables, run frames left out), "
          f"~{nbytes:,} B at flat 6bpp; palettes " +
          ", ".join(f"{n} ({len(w)})" for n, w in named.values()))
    # two libraries: LOAD2 garbles the record names of an IMG this big (2.26 MB
    # with the skeleton in it; 1.94 MB without is fine), so the fatality art
    # is its own IMG as well as its own LOD
    body = [r for r in recs if not FATAL_KEEP.match(r["name"])]
    fats = [r for r in recs if FATAL_KEEP.match(r["name"])]
    img = build_img(body, {k: v for k, v in named.items() if any(r["pal"] == k for r in body)})
    fimg = build_img(fats, {k: v for k, v in named.items() if any(r["pal"] == k for r in fats)})
    lod = build_lod(recs, named)
    fat = build_fat_lod(recs, named)
    if a.apply:
        OUT_IMG.write_bytes(img)
        OUT_FIMG.write_bytes(fimg)
        OUT_LOD.write_text(lod, newline="\r\n")
        OUT_FAT.write_text(fat, newline="\r\n")
        sheets(u, recs, named, L, by_addr, fakes)
        print(f"wrote {OUT_IMG.relative_to(ROOT)} ({len(img):,} bytes), {OUT_LOD.name}, "
              f"{OUT_DIR.relative_to(ROOT)}/")
    if a.check:
        if not OUT_LOD.exists() or OUT_LOD.read_text() != lod:
            raise SystemExit(f"{OUT_LOD.relative_to(ROOT)} has drifted - rerun --apply")
        if not OUT_FAT.exists() or OUT_FAT.read_text() != fat:
            raise SystemExit(f"{OUT_FAT.relative_to(ROOT)} has drifted - rerun --apply")
        if not OUT_IMG.exists() or OUT_IMG.read_bytes() != img:
            raise SystemExit(f"{OUT_IMG.relative_to(ROOT)} has drifted from umk3.zip - rerun --apply")
        if not OUT_FIMG.exists() or OUT_FIMG.read_bytes() != fimg:
            raise SystemExit(f"{OUT_FIMG.relative_to(ROOT)} has drifted from umk3.zip - rerun --apply")
        print("UMK3SNYA.IMG and UMK3SNY.LOD match umk3.zip")
        verify_pack([r for r in recs if not FATAL_KEEP.match(r["name"])], "UMK3SNY", LOD_BASE)
        verify_pack([r for r in recs if FATAL_KEEP.match(r["name"])], "UMK3SNF", FAT_BASE)
    return 0


def verify_pack(recs, stem, lod_base):
    """Every record LOAD2 packed (data/<stem>.IRW, src/<stem>.TBL) decodes
    back to UMK3's own pixels, under its own geometry.  Skipped, loudly, until
    the first LOAD2 run has made the pack."""
    irw, tbl = ROOT / "data" / f"{stem}.IRW", ROOT / "src" / f"{stem}.TBL"
    if not irw.exists() or not tbl.exists():
        print(f"{stem}.IRW / {stem}.TBL not built yet - pack not verified")
        return
    pay = irw.read_bytes()[68:]
    lines = tbl.read_text().splitlines()
    got = {}
    for i, ln in enumerate(lines):
        m = re.match(r"^(\w+):", ln)
        if m:
            g = [int(v) for v in re.findall(r"-?\d+", lines[i + 1])]
            sag = int(re.search(r"([0-9a-fA-F]+)H", lines[i + 2]).group(1), 16)
            ctrl = int(re.search(r"([0-9a-fA-F]+)H", lines[i + 3]).group(1), 16)
            got[m.group(1)] = (g, sag, ctrl)
    base = lod_base + 0x2000000           # the runtime SAG of the pack's first bit
    bad = [r["name"] for r in recs if r["name"] not in got]
    for r in recs:
        if r["name"] in bad:
            continue
        g, sag, ctrl = got[r["name"]]
        rows, _ = pit.decode_record(pay, sag - base, r["w"], r["h"], ctrl)
        if g != [r["w"], r["h"], r["ax"], r["ay"]] or bytes(v for row in rows for v in row) != r["px"]:
            bad.append(r["name"])
    if bad:
        raise SystemExit(f"{stem} pack: {len(bad)} records are not umk3.zip's ({bad[:6]}) - rebuild")
    print(f"{stem} pack: all {len(recs)} records decode to umk3.zip's pixels")
    return 0


if __name__ == "__main__":
    sys.exit(main())
