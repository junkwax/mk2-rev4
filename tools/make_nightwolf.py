#!/usr/bin/env python3
r"""MK3 NIGHTWOLF (Wolf only, ochar 23) - his art, out of deadlythirdcombat's
INDIAN1-12.IMG into three libraries and three packs.

THE RECORDS ARE MK3'S.  MK3's arcade source (MK3SRC/V13) carries Nightwolf
("indian") as MKIND.ASM plus three record tables, MKIND.TBL / MKIND2.TBL /
MKIND3.TBL - 1,045 headers - and every one of those names is a record in
deadlythirdcombat's INDIAN*.IMG (the authored libraries, palettes and
anipoints included).  So the pack is exactly MK3's record list, in MK3's
order, minus the run (MK2 has no run button): no ROM decode, no renaming.

  * Body art is drawn in his costume (INBLU_P; INYEL_P on the alternate
    lanes, MK3's MKGUYS character_palettes), so it packs POF>.  Every record
    authored on another palette is an effect drawn on an object of its own
    and packs PON>: GRNFLM_P (the reflector), GFIRE_p / INGLOW_P (the shoulder
    charge glow), INAXE_P (the hatchet), ZAP_P / ASH_P / WISP_P (the
    fatality's disintegration) and LIGHTNG_P.  All are <= 64 colours, so one
    depth (PPP> 6) serves every section.
  * Three libraries, because LOAD2 garbles names and hangs on an IMG past
    ~2 MB, and a LOD past ~480 records (doc/WOLF_SONYA.md): data/NWOLFA-C.IMG,
    each with its own pack data/NWOLFA-C.LOD.
  * THE u110-u113 BLOCK.  Linear 0x1600000.. (stock MAME loads u110-u113).
    LOAD2 refuses a load address of 8000000 and up, so each LOD is based
    RELOC (4 MB) lower and makevrom.py WOLF_RELOCATE moves the payload up;
    `--tables` adds the same distance to every SAG LOAD2 wrote and merges the
    three tables into src/NWOLF.TBL (LOAD2's own NWLA-C.TBL are never
    included).

    python tools/make_nightwolf.py            # report
    python tools/make_nightwolf.py --apply    # write the IMGs and the LODs
    python tools/make_nightwolf.py --tables   # Phase B: src/NWOLF.TBL from tmp/load2
    python tools/make_nightwolf.py --check    # Phase D: IMGs, LODs, NWOLF.TBL current
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk1pit as pit  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DTC = Path("C:/Users/you/Workplace/deadlythirdcombat-main/deadlythirdcombat-main")
MK3SRC = Path("C:/Users/you/Workplace/MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13")
MK3_TABLES = ("MKIND.TBL", "MKIND2.TBL", "MKIND3.TBL")
LOAD2 = ROOT / "tmp" / "load2"
OUT_TBL = ROOT / "src" / "NWOLF.TBL"

BODY_PAL = "INBLU_P"
DROP = re.compile(r"^(INRUN|ININTORUN)")          # no run
RELOC = 0x400000
RELOC_BITS = RELOC * 8
# (stem, LOAD2 table, Wolf linear base, linear end).  B and C are placed after
# the MEASURED size of the pack below them (a real LOAD2 run - estimating off
# the IMG runs low).  0x1568000..0x1600000 is left for THE PIT 3's growth.
PACKS = [("NWOLFA", "NWLA", 0x1600000, 0x165C000),      # packs to 348,360 B
         ("NWOLFB", "NWLB", 0x165C000, 0x16B8000),      # 358,532 B
         ("NWOLFC", "NWLC", 0x16B8000, 0x16D8000)]      # 112,430 B
SPLIT_RECORDS = 400            # a LOD past ~480 records garbled LOAD2
SPLIT_BYTES = 950_000          # an IMG past ~2 MB hung it

LIB = struct.Struct("<HHIHHHHH4sHHH")
IMAGE = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")


# --------------------------------------------------------------------------
def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def read_lib(path):
    """{name: dict(w,h,ax,ay,px,pal,words)} for every record of one IMG."""
    d = path.read_bytes()
    ic, pc, o = LIB.unpack_from(d, 0)[:3]
    first = all(32 <= c < 127 for c in d[o:o + 4])
    ib, pb = (o, o + ic * IMAGE.size) if first else (o + pc * PALETTE.size, o)
    out = {}
    for i in range(ic):
        (n, _fl, ax, ay, w, h, palnum, oset, *_r) = IMAGE.unpack_from(d, ib + i * IMAGE.size)
        name = n.split(b"\0")[0].decode("latin-1")
        stride = (w + 3) & ~3
        px = b"".join(d[oset + y * stride:oset + y * stride + w] for y in range(h))
        pn, _pf, _bits, numc, po = PALETTE.unpack_from(d, pb + (palnum - 3) * PALETTE.size)[:5]
        words = list(struct.unpack_from("<%dH" % numc, d, po))
        out.setdefault(name, []).append(dict(w=w, h=h, ax=s16(ax), ay=s16(ay), px=px,
                                             pal=pn.split(b"\0")[0].decode("latin-1").upper(),
                                             words=words, lib=path.name))
    return out


def mk3_records():
    """[(name, (w,h,ax,ay))] in MK3's table order."""
    out = []
    for t in MK3_TABLES:
        lines = (MK3SRC / t).read_text(errors="replace").splitlines()
        for i, ln in enumerate(lines):
            m = re.match(r"^(\w+):\s*$", ln)
            if m:
                g = tuple(int(v) for v in re.findall(r"-?\d+", lines[i + 1]))
                out.append((m.group(1), g))
    return out


def resolve():
    libs = {}
    for n in range(1, 13):
        for nm, cands in read_lib(DTC / f"INDIAN{n}.IMG").items():
            libs.setdefault(nm, []).extend(cands)
    recs, dropped = [], 0
    for nm, g in mk3_records():
        if DROP.match(nm):
            dropped += 1
            continue
        cands = libs.get(nm)
        if not cands:
            raise SystemExit(f"{nm}: in MK3's tables but in no INDIAN*.IMG")
        fit = [c for c in cands if (c["w"], c["h"]) == g[:2]] or cands
        px = {c["px"] for c in fit}
        if len(px) > 1:
            raise SystemExit(f"{nm}: {len(fit)} different records of that name in "
                             f"{[c['lib'] for c in fit]} - pick one by hand")
        recs.append(dict(fit[0], name=nm))
    # one palette per name: every library must agree on its words
    pals = {}
    for r in recs:
        if pals.setdefault(r["pal"], r["words"]) != r["words"]:
            raise SystemExit(f"{r['pal']}: two different palettes of that name")
    return recs, pals, dropped


def split(recs):
    groups, cur, size = [], [], 0
    for r in recs:
        b = r["w"] * r["h"]
        if cur and (len(cur) >= SPLIT_RECORDS or size + b > SPLIT_BYTES):
            groups.append(cur)
            cur, size = [], 0
        cur.append(r)
        size += b
    groups.append(cur)
    if len(groups) != len(PACKS):
        raise SystemExit(f"his art splits into {len(groups)} libraries, PACKS has {len(PACKS)}")
    return groups


def img_bytes(group, pals):
    names = list(dict.fromkeys(r["pal"] for r in group))
    idx = {n: i for i, n in enumerate(names)}
    images = [(r["name"], r["ax"], r["ay"], r["w"], r["h"], r["px"], idx[r["pal"]]) for r in group]
    return pit.build_img(images, [(n, 6, pals[n]) for n in names])


def lod_text(stem, tbl, base, end, group):
    lines = [f"***> {pit.lod_address(base - RELOC)}",
             "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
             ";**************************************************************",
             ";",
             f";  MK3 NIGHTWOLF (Wolf only) - GENERATED by tools/make_nightwolf.py",
             f";  --apply out of deadlythirdcombat's INDIAN*.IMG; every name is",
             f";  MK3's own (MKIND*.TBL).  Linear 0x{base:X}..0x{end:X}, loaded",
             f";  4 MB lower (LOAD2 refuses 8000000+) and moved up by makevrom.py",
             f";  WOLF_RELOCATE.  Body POF> (his costume), effects PON>.",
             ";",
             ";**************************************************************",
             "ZON>",
             "PPP> 6",
             f"ASM> {tbl}.TBL",
             f"{stem}.IMG"]
    kind = None
    run = []

    def flush():
        for i in range(0, len(run), 8):
            lines.append("---> " + ",".join(run[i:i + 8]))
        run.clear()
    for r in group:
        k = "POF>" if r["pal"] == BODY_PAL else "PON>"
        if k != kind:
            flush()
            lines.append(k)
            kind = k
        run.append(r["name"])
    flush()
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# The select screen: Liu Kang's box wiping into his, his ladder mug, his plate
# --------------------------------------------------------------------------
SEL = ("NWSEL", "NWLS", 0x16D8000, 0x16E2000)
HEAD = (DTC / "MKSEL.IMG", "HDINDIAN")     # MK3's own select-screen head, 48x59
BOX_FRAMES = 8                              # NWBOX2..9 (frame 0 is the stock LKBOX)
# the plate's letters: (plate in MKSCORE.IMG, letter segment index)
PLATE = [("N", "BAR_KINTARO", 2), ("I", "BAR_KINTARO", 1), ("G", "BAR_SHANG", 4),
         ("H", "BAR_SHANG", 1), ("T", "BAR_KNOCKOUT", -1), ("W", "BAR_EDWARD", 2),
         ("O", "BAR_KINTARO", -1), ("L", "BAR_SINDEL", -1), ("F", "BAR_FLYBRAIN", 0)]


def rgb15(w):
    return (((w >> 10) & 31) * 255 + 15) // 31, (((w >> 5) & 31) * 255 + 15) // 31, ((w & 31) * 255 + 15) // 31


def to15(c):
    r, g, b = (round(v * 31 / 255) for v in c[:3])
    return (r << 10) | (g << 5) | b


def head_image(w, h):
    from PIL import Image
    hd = read_lib(HEAD[0])[HEAD[1]][0]
    im = Image.new("RGB", (hd["w"], hd["h"]))
    im.putdata([rgb15(hd["words"][v]) for v in hd["px"]])
    return im.resize((w, h), Image.LANCZOS)


def quantize(im, ncol):
    """[(15-bit word)], pixel indices 0..ncol-1 - the image's own colours."""
    q = im.quantize(colors=ncol, method=2, dither=0)       # median cut, no dither
    pal = q.getpalette()[:ncol * 3]
    words = [to15(pal[i * 3:i * 3 + 3]) for i in range(ncol)]
    return words, list(q.tobytes())


def select_art():
    """[(name, ax, ay, w, h, px, palname)], {palname: (bits, words)}"""
    boxes = read_lib(ROOT / "data" / "MKBOXES.IMG")["LKBOX"][0]
    lkw, lkpx = boxes["words"], boxes["px"]
    if 0 in lkpx:
        raise SystemExit("LKBOX draws index 0 - the wipe palette assumes it does not")
    w, h = boxes["w"], boxes["h"]
    face_words, face_px = quantize(head_image(w, h), 255 - len(lkw))
    words = list(lkw) + face_words                        # LKBOX's colours keep their indices
    face = [len(lkw) + v for v in face_px]
    images = []
    for n in range(1, BOX_FRAMES + 1):                    # NWBOX2..NWBOX9: wipes in from the left
        edge = round(w * n / BOX_FRAMES)
        px = bytes(face[y * w + x] if x < edge else lkpx[y * w + x] for y in range(h) for x in range(w))
        images.append((f"NWBOX{n + 1}", 0, 0, w, h, px, "NWBOX_P"))
    mug_words, mug_px = quantize(head_image(35, 45), 127)
    mug_words = [0] + mug_words                            # index 0 transparent, never drawn
    images.append(("smnwbox", 0, 0, 35, 45, bytes(v + 1 for v in mug_px), "NWMUG_P"))
    score = read_lib(ROOT / "data" / "MKSCORE.IMG")
    rows = [[] for _ in range(10)]
    for i, (_ch, plate, k) in enumerate(PLATE):
        r = score[plate][0]
        cols = [any(r["px"][y * r["w"] + x] for y in range(r["h"])) for x in range(r["w"])]
        segs, x = [], 0
        while x < r["w"]:
            if cols[x]:
                s = x
                while x < r["w"] and cols[x]:
                    x += 1
                segs.append((s, x))
            else:
                x += 1
        s, e = segs[k]
        for y in range(10):
            rows[y] += [r["px"][y * r["w"] + c] for c in range(s, e)] + ([0] if i < len(PLATE) - 1 else [])
    pw = len(rows[0])
    images.append(("BAR_NIGHTWOLF", 0, 0, pw, 10, bytes(v for row in rows for v in row), "SCORE_P"))
    pals = {"NWBOX_P": (8, words), "NWMUG_P": (7, mug_words),
            "SCORE_P": (6, list(score["BAR_KANG"][0]["words"]))}
    return images, pals


def select_img():
    images, pals = select_art()
    names = list(pals)
    return pit.build_img([(n, ax, ay, w, h, px, names.index(p)) for n, ax, ay, w, h, px, p in images],
                         [(n, pals[n][0], pals[n][1]) for n in names])


def select_lod():
    stem, tbl, base, end = SEL
    return "\n".join([
        f"***> {pit.lod_address(base - RELOC)}",
        "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
        ";**************************************************************",
        ";",
        ";  Liu Kang <-> MK3 NIGHTWOLF select screen (Wolf only) - GENERATED by",
        ";  tools/make_nightwolf.py --apply.  Linear 0x%X..0x%X, loaded 4 MB" % (base, end),
        ";  lower and moved up by makevrom.py WOLF_RELOCATE, as his body packs.",
        ";",
        ";  NWBOX2-9: Liu Kang's LKBOX wiping into MK3's own select head",
        ";  (deadlythirdcombat MKSEL.IMG HDINDIAN, scaled to the box) from the",
        ";  left - LKBOX is frame 0 of the lane (nwolf_frames, MKSEL.ASM).  One",
        ";  palette, NWBOX_P: LKBOX's colours at their own indices, then his.",
        ";  PON> / ZOF> / PPP> 8 as data/SNBOX.LOD.",
        ";  smnwbox: his 1-player ladder mug (the same head at 35x45), NWMUG_P.",
        ";  BAR_NIGHTWOLF: his name plate, letters cut out of MK2's own plates",
        ";  (MKSCORE.IMG), POF> as every plate - drawn in the score palette.",
        ";",
        ";**************************************************************",
        "PON>", "ZOF>", "PPP> 8", f"ASM> {tbl}.TBL", f"{stem}.IMG",
        "---> " + ",".join(f"NWBOX{n}" for n in range(2, BOX_FRAMES + 2)),
        "PPP> 0", "---> smnwbox",
        "POF>", "ZON>", "PPP> 0", "---> BAR_NIGHTWOLF", ""])


def files():
    recs, pals, dropped = resolve()
    out = {}
    for (stem, tbl, base, end), g in zip(PACKS, split(recs)):
        out[ROOT / "data" / f"{stem}.IMG"] = img_bytes(g, pals)
        out[ROOT / "data" / f"{stem}.LOD"] = lod_text(stem, tbl, base, end, g).replace("\n", "\r\n").encode()
    out[ROOT / "data" / f"{SEL[0]}.IMG"] = select_img()
    out[ROOT / "data" / f"{SEL[0]}.LOD"] = select_lod().replace("\n", "\r\n").encode()
    return out, recs, pals, dropped


# --------------------------------------------------------------------------
# Phase B: LOAD2's tables, relocated, as one src/NWOLF.TBL
# --------------------------------------------------------------------------
def tables_text():
    out = [";" + "*" * 70,
           ";  MK3 NIGHTWOLF (Wolf only) - his record headers.  GENERATED by",
           ";  tools/make_nightwolf.py --tables out of LOAD2's tmp/load2/NWLA-C.TBL",
           f";  with every SAG moved up {RELOC_BITS:X}h bits (makevrom.py WOLF_RELOCATE).",
           ";" + "*" * 70]
    for stem, tbl, base, end in PACKS + [SEL]:
        p = LOAD2 / f"{tbl}.TBL"
        if not p.exists():
            raise SystemExit(f"{p} missing - run LOAD2 on data/{stem}.LOD first (build.py Phase A)")
        n = 0
        for ln in p.read_text(encoding="latin-1").splitlines():
            m = re.match(r"^(\s*\.long\s+)0?([0-9a-fA-F]+)[hH](.*)$", ln)
            if m:
                sag = int(m.group(2), 16) + RELOC_BITS
                # LOAD2's SAG is the LOD address plus 2000000h for bank 1
                lo, hi = 0x4000000 + (base - 0x800000 - RELOC) * 8 + RELOC_BITS, \
                    0x4000000 + (end - 0x800000 - RELOC) * 8 + RELOC_BITS
                if not lo <= sag < hi:
                    raise SystemExit(f"{tbl}.TBL: SAG {sag:X} outside its slot {lo:X}..{hi:X}")
                ln = f"{m.group(1)}0{sag:x}H{m.group(3)}"
                n += 1
            out.append(ln.rstrip())
        out.append(f";  ({tbl}.TBL: {n} records)")
    return "\n".join(out) + "\n"


def measure():
    for stem, tbl, base, end in PACKS + [SEL]:
        irw = ROOT / "data" / f"{stem}.IRW"
        if irw.exists():
            sz = irw.stat().st_size
            print(f"  {stem}.IRW {sz:9,} bytes   slot 0x{base:X}..0x{end:X} ({end - base:,})"
                  f"{'   ** OVERFLOWS **' if sz > end - base else ''}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--tables", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    fl, recs, pals, dropped = files()
    print(f"NIGHTWOLF: {len(recs)} records ({dropped} run frames left out), palettes {sorted(pals)}")
    for p, data in fl.items():
        if p.suffix == ".IMG":
            print(f"  {p.name}: {len(data):,} bytes")
    measure()
    if a.apply:
        for p, data in fl.items():
            if not p.exists() or p.read_bytes() != data:
                p.write_bytes(data)
                print(f"wrote {p.relative_to(ROOT)}")
    if a.tables:
        t = tables_text()
        if not OUT_TBL.exists() or OUT_TBL.read_text(encoding="latin-1") != t:
            OUT_TBL.write_text(t, encoding="latin-1", newline="\r\n")
            print(f"wrote {OUT_TBL.relative_to(ROOT)}")
    if a.check:
        stale = [p.name for p, d in fl.items() if not p.exists() or p.read_bytes() != d]
        if stale:
            raise SystemExit(f"stale: {stale} - rerun tools/make_nightwolf.py --apply")
        if (LOAD2 / f"{PACKS[0][1]}.TBL").exists():
            if not OUT_TBL.exists() or OUT_TBL.read_text(encoding="latin-1") != tables_text():
                raise SystemExit("src/NWOLF.TBL is stale - rerun tools/make_nightwolf.py --tables")
        print("NIGHTWOLF libraries, packs and tables are current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
