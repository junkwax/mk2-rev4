#!/usr/bin/env python3
r"""MK3 ROBOT SMOKE (Wolf only, ochar 24) - his art, out of deadlythirdcombat's
ROBO1-13.IMG into libraries and packs, as tools/make_nightwolf.py does for
Nightwolf.

MK3 carries its three robot ninjas - Sektor (ft_robo1), Cyrax (ft_robo2) and
the hidden SMOKE (ft_smoke) - as ONE module: MKROBO.ASM with MKROBO.TBL /
MKROBO2.TBL / MKROBO3.TBL (MK3SRC/V13).  Smoke is Sektor's body (the RB*
frames; Cyrax's are RB2*) in his own costume, SMOKE1_P (MK3 MKGUYS
character_palettes_1; SMOKE2_P on _2).  So unlike Nightwolf the record list
is NOT "every record the tables name": it is every record SMOKE'S LANES can
draw.  `lanes()` walks MKROBO.ASM from the rows his port uses, taking each
`ani_ochar_jump` the way MK3 does for ft_smoke (his branch is a jump, every
other fighter's falls through), and keeps the blocks it reaches; the art is
the record names those blocks name.  tools/make_robosmoke_asm.py emits the
same blocks as his lanes, so the pack and the lanes cannot disagree.

  * Body art is drawn in his costume, so it packs POF>.  The robot body was
    authored on ROBO_P / Sektor's R1PAL1_P+R1PAL2_P / BLACK; every other
    palette is an effect on an object of its own and packs PON>.
  * His spear is NOT packed here: MK3's is the COMEHERE trident, which MK2
    already packs for ninja Smoke (data/SMROPE.LOD) - his TABLE2 row 1 draws
    MK2's own records, anchored for MK2's do_throw_spear / do_rope_pull.
  * THE u110-u113 BLOCK, right above Nightwolf: linear 0x16E2000.. 0x1800000.
    Loaded RELOC lower and moved up by makevrom.py WOLF_RELOCATE; `--tables`
    adds the distance to every SAG and merges the packs' tables into
    src/RSMOKE.TBL.

    python tools/make_robosmoke.py            # report
    python tools/make_robosmoke.py --apply    # write the IMGs and the LODs
    python tools/make_robosmoke.py --tables   # Phase B: src/RSMOKE.TBL from tmp/load2
    python tools/make_robosmoke.py --check    # Phase D: IMGs, LODs, RSMOKE.TBL current
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk1pit as pit              # noqa: E402
import make_nightwolf as nw            # noqa: E402  (read_lib, select art helpers)
import make_umk3sonya_asm as sny       # noqa: E402  (blocks / tokens)

ROOT = Path(__file__).resolve().parent.parent
DTC = nw.DTC
MK3SRC = nw.MK3SRC
MKROBO = MK3SRC / "MKROBO.ASM"
MK3_TABLES = ("MKROBO.TBL", "MKROBO2.TBL", "MKROBO3.TBL")
LOAD2 = ROOT / "tmp" / "load2"
OUT_TBL = ROOT / "src" / "RSMOKE.TBL"

# MK3 MAINEQU: which fighter an ani_ochar_jump names
FT = {"ft_robo1": 7, "ft_robo2": 8, "ft_smoke": 14}
ME = FT["ft_smoke"]
BODY_PALS = {"ROBO_P", "R1PAL1_P", "R1PAL2_P", "R2PAL1_P", "R2PAL2_P", "BLACK", "SMOKE1_P"}
COSTUME = "SMOKE1_P"

# robo_anitab1 rows his port draws (MK2 TABLE1 -> these; make_robosmoke_asm.TABLE1)
ROWS1 = ["a_stance", "a_walkf", "a_walkb", "a_duck", "a_jump", "a_fflip", "a_bflip", "a_turn",
         "a_duck_turn", "a_block", "a_duck_block", "a_hikick", "a_lokick", "a_knockdown",
         "a_hit_hi", "a_hit_lo", "a_getup", "a_hipunch", "a_lopunch", "a_sweep_kick",
         "a_sweep_fall", "a_sweepup", "a_duck_punch", "a_duck_kick_hi", "a_duck_kick_lo",
         "a_duck_hit", "a_uppercut", "a_jump_kick", "a_flip_kick", "a_flip_punch",
         "a_roundhouse", "a_knee", "a_elbow", "a_stumble", "a_victory"]
# ...and the robo_anitab2 lanes his specials draw
ROWS2 = ["a_chest_open", "a_robo_telepunch", "a_inviso", "a_air_slam", "a_run"]
# Two MK3 lanes are rebuilt in MK2's shape out of their frames instead of
# walked (make_robosmoke_asm.py): a_dizzy (MK3's robots spark while stunned -
# shock_init / shock_check / stun_speed_*, MK3 code MK2 does not have) and
# a_throw (Sektor's: its grabbing arm is a second RBMECARM object).  His
# throw is MK3 Smoke's own - a_smoke_throw's lunge into smoke_slam's
# a_air_slam, art already packed for his air throw - so RBSHOLDER1-4 are
# now drawn by NOTHING (packed and unused until the next repack drops them).
# Their frames are walked from here.
FRAMES = [f"RBSTUNNED{n}" for n in range(1, 9)] + [f"RBSHOLDER{n}" for n in range(1, 5)]
# ...and RBFLIPPED1-5, which only MK3's own "flipped by" lanes draw: the MK2
# ninja thrown lanes his victim rows are copied from are re-pointed at them
FRAMES += [f"RBFLIPPED{n}" for n in range(1, 6)]
# MK3 lanes that carry nothing he can use (Sektor/Cyrax fluff his lanes
# never reach is dropped by the walk itself).  His RUN is in: the Wolf board
# has a Run button and he alone uses it (RSMOKEM.ASM rs_run)
DROP_LABELS: set[str] = set()

RELOC = 0x400000
RELOC_BITS = RELOC * 8
# (stem, LOAD2 table, Wolf linear base, linear end) - sized off real LOAD2 runs
PACKS = [("RSMOKA", "RSLA", 0x16E2000, 0x1736000),      # packs to 339,238 B
         ("RSMOKB", "RSLB", 0x1736000, 0x1780000)]      # 267,984 B (with the run)
SEL = ("RSSEL", "RSLS", 0x1780000, 0x178A000)            # 32,248 B
# 0x178A000..0x1800000 (472 KB) is left for his fatality art
SPLIT_RECORDS = 400
SPLIT_BYTES = 950_000


# --------------------------------------------------------------------------
# his lanes out of MKROBO.ASM
# --------------------------------------------------------------------------
def resolve_ochar(body):
    """Body lines with every ani_ochar_jump resolved for ft_smoke: his branch
    becomes an ani_jump, anybody else's is dropped (MK3 falls through)."""
    toks = []          # (kind, line) with the jump triple spread over lines
    out, k = [], 0
    while k < len(body):
        ln = body[k]
        code = ln.split(";")[0]
        if re.search(r"\bani_ochar_jump\b", code):
            rest = [t for t in re.findall(r"\w+", code.split("ani_ochar_jump", 1)[1])]
            j = k + 1
            while len(rest) < 2:
                rest += re.findall(r"\w+", body[j].split(";")[0].replace(".long", ""))
                j += 1
            who, target = rest[0], rest[1]
            if who not in FT:
                raise SystemExit(f"ani_ochar_jump on unknown {who}")
            if FT[who] == ME:
                out.append(f"\t.long\tani_jump,{target}\t; MK3: ani_ochar_jump {who} (his branch)")
            k = j
            continue
        out.append(ln)
        k += 1
    del toks
    return out


def is_code(ln):
    code = ln.split(";")[0]
    if ln[:1] not in (" ", "\t"):
        code = re.sub(r"^[A-Za-z_]\w*", "", code)
    return bool(re.match(r"^\s+[a-z]{2,8}\b", code)) and not re.match(r"^\s+\.", code)


def lanes():
    """[(label, body lines)] of every MKROBO block his lanes reach, in file
    order, ochar jumps resolved; and the set of labels."""
    lines = MKROBO.read_text(errors="replace").splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip().lower() == ".text") + 1
    bl = [(lab, resolve_ochar(body)) for lab, body in sny.blocks(lines[start:])]
    index = {lab: i for i, (lab, _b) in enumerate(bl) if lab}
    keep, todo, seen = set(), list(ROWS1 + ROWS2 + FRAMES), set()

    def data(body):
        return [ln for ln in body if sny.tokens(ln) or re.search(r"\.long\s+0\b", ln.split(";")[0])]
    while todo:
        lab = todo.pop()
        if lab in seen or lab not in index or lab in DROP_LABELS:
            continue
        seen.add(lab)
        j = index[lab]
        chain = [j]
        while True:      # a block falls into the next unless it ends on a jump
            d = data(bl[chain[-1]][1])
            nxt = chain[-1] + 1
            if nxt >= len(bl) or (d and re.search(r"\bani_jump\b", d[-1])):
                break
            if d and not re.match(r"^(a_|[A-Z])", bl[nxt][0] or "A"):
                chain.append(nxt)      # a continuation part
                continue
            if not d:                  # a stacked label: falls through
                chain.append(nxt)
                continue
            break
        for c in chain:
            if any(is_code(ln) for ln in bl[c][1]):
                raise SystemExit(f"his lanes walked into MK3 code at {bl[c][0]}")
            keep.add(c)
            seen.add(bl[c][0])
            for ln in bl[c][1]:
                toks = sny.tokens(ln)
                for i, t in enumerate(toks):
                    if i and toks[i - 1] == "ani_calla":
                        continue          # a routine, not a lane
                    if t in index and t not in seen:
                        todo.append(t)
    return [bl[i] for i in sorted(keep)], {bl[i][0] for i in keep}


def mk3_records():
    """{name: (w,h,ax,ay)} from MK3's robot tables."""
    out = {}
    for t in MK3_TABLES:
        tl = (MK3SRC / t).read_text(errors="replace").splitlines()
        for i, ln in enumerate(tl):
            m = re.match(r"^(\w+):\s*$", ln)
            if m:
                out[m.group(1)] = tuple(int(v) for v in re.findall(r"-?\d+", tl[i + 1]))
    return out


def wanted():
    """Record names his lanes draw, in first-use order."""
    blocks, labels = lanes()
    tab = mk3_records()
    names = []
    for _lab, body in blocks:
        for ln in body:
            for t in sny.tokens(ln):
                if t in tab and t not in labels and t not in names:
                    names.append(t)
    return names, tab


def resolve():
    libs = {}
    for n in range(1, 14):
        for nm, cands in nw.read_lib(DTC / f"ROBO{n}.IMG").items():
            libs.setdefault(nm, []).extend(cands)
    names, tab = wanted()
    recs = []
    for nm in names:
        cands = libs.get(nm)
        if not cands:
            raise SystemExit(f"{nm}: drawn by his lanes but in no ROBO*.IMG")
        g = tab[nm]
        fit = [c for c in cands if (c["w"], c["h"]) == g[:2]] or cands
        if len({c["px"] for c in fit}) > 1:
            raise SystemExit(f"{nm}: {len(fit)} different records of that name in "
                             f"{[c['lib'] for c in fit]} - pick one by hand")
        r = dict(fit[0], name=nm)
        r["body"] = r["pal"] in BODY_PALS
        recs.append(r)
    pals = {}
    for r in recs:
        if pals.setdefault(r["pal"], r["words"]) != r["words"]:
            raise SystemExit(f"{r['pal']}: two different palettes of that name")
    return recs, pals


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
             f";  MK3 ROBOT SMOKE (Wolf only) - GENERATED by tools/make_robosmoke.py",
             f";  --apply out of deadlythirdcombat's ROBO*.IMG: every record his",
             f";  MKROBO.ASM lanes draw.  Linear 0x{base:X}..0x{end:X}, loaded 4 MB",
             f";  lower (LOAD2 refuses 8000000+) and moved up by makevrom.py",
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
        k = "POF>" if r["body"] else "PON>"
        if k != kind:
            flush()
            lines.append(k)
            kind = k
        run.append(r["name"])
    flush()
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# The select screen: Reptile's box wiping into his, and his ladder mug
# --------------------------------------------------------------------------
HEAD = (DTC / "MKSEL.IMG", "HDSMOKE")      # MK3's own select-screen head, 48x59
BOX_FRAMES = 8                              # RSBOX2..9 (frame 0 is the stock RPBOX)


def head_image(w, h):
    from PIL import Image
    hd = nw.read_lib(HEAD[0])[HEAD[1]][0]
    im = Image.new("RGB", (hd["w"], hd["h"]))
    im.putdata([nw.rgb15(hd["words"][v]) for v in hd["px"]])
    return im.resize((w, h), Image.LANCZOS)


def select_art():
    """[(name, ax, ay, w, h, px, palname)], {palname: (bits, words)}"""
    box = nw.read_lib(ROOT / "data" / "MKBOXES.IMG")["RPBOX"][0]
    bw, bpx = box["words"], box["px"]
    if 0 in bpx:
        raise SystemExit("RPBOX draws index 0 - the wipe palette assumes it does not")
    w, h = box["w"], box["h"]
    face_words, face_px = nw.quantize(head_image(w, h), 255 - len(bw))
    words = list(bw) + face_words
    face = [len(bw) + v for v in face_px]
    images = []
    for n in range(1, BOX_FRAMES + 1):
        edge = round(w * n / BOX_FRAMES)
        px = bytes(face[y * w + x] if x < edge else bpx[y * w + x] for y in range(h) for x in range(w))
        images.append((f"RSBOX{n + 1}", 0, 0, w, h, px, "RSBOX_P"))
    mug_words, mug_px = nw.quantize(head_image(35, 45), 127)
    images.append(("smrsbox", 0, 0, 35, 45, bytes(v + 1 for v in mug_px), "RSMUG_P"))
    # no name plate here: MK2 already has SMOKE's (BAR_SMOKE, MKSCORE.IMG),
    # and his p1/p2_powerbar_names rows name it (wolf_fighter_rows.py RSMOKE)
    pals = {"RSBOX_P": (8, words), "RSMUG_P": (7, [0] + mug_words)}
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
        ";  Reptile <-> MK3 ROBOT SMOKE select screen (Wolf only) - GENERATED",
        ";  by tools/make_robosmoke.py --apply.  Linear 0x%X..0x%X, loaded" % (base, end),
        ";  4 MB lower and moved up by makevrom.py WOLF_RELOCATE.",
        ";",
        ";  RSBOX2-9: Reptile's RPBOX wiping into MK3's own select head",
        ";  (deadlythirdcombat MKSEL.IMG HDSMOKE, scaled to the box) from the",
        ";  left - RPBOX is frame 0 of the lane (rsmoke_frames, MKSEL.ASM).",
        ";  smrsbox: his 1-player ladder mug, RSMUG_P.",
        ";",
        ";**************************************************************",
        "PON>", "ZOF>", "PPP> 8", f"ASM> {tbl}.TBL", f"{stem}.IMG",
        "---> " + ",".join(f"RSBOX{n}" for n in range(2, BOX_FRAMES + 2)),
        "PPP> 0", "---> smrsbox", ""])


def files():
    recs, pals = resolve()
    out = {}
    for (stem, tbl, base, end), g in zip(PACKS, split(recs)):
        out[ROOT / "data" / f"{stem}.IMG"] = img_bytes(g, pals)
        out[ROOT / "data" / f"{stem}.LOD"] = lod_text(stem, tbl, base, end, g).replace("\n", "\r\n").encode()
    out[ROOT / "data" / f"{SEL[0]}.IMG"] = select_img()
    out[ROOT / "data" / f"{SEL[0]}.LOD"] = select_lod().replace("\n", "\r\n").encode()
    return out, recs, pals


# --------------------------------------------------------------------------
# Phase B: LOAD2's tables, relocated, as one src/RSMOKE.TBL
# --------------------------------------------------------------------------
def tables_text():
    out = [";" + "*" * 70,
           ";  MK3 ROBOT SMOKE (Wolf only) - his record headers.  GENERATED by",
           ";  tools/make_robosmoke.py --tables out of LOAD2's tmp/load2/RSL*.TBL",
           f";  with every SAG moved up {RELOC_BITS:X}h bits (makevrom.py WOLF_RELOCATE).",
           ";" + "*" * 70]
    for stem, tbl, base, end in PACKS + [SEL]:
        p = LOAD2 / f"{tbl}.TBL"
        if not p.exists():
            raise SystemExit(f"{p} missing - run LOAD2 on data/{stem}.LOD first (build.py Phase A)")
        n = 0
        lo = 0x4000000 + (base - 0x800000 - RELOC) * 8 + RELOC_BITS
        hi = 0x4000000 + (end - 0x800000 - RELOC) * 8 + RELOC_BITS
        for ln in p.read_text(encoding="latin-1").splitlines():
            m = re.match(r"^(\s*\.long\s+)0?([0-9a-fA-F]+)[hH](.*)$", ln)
            if m:
                sag = int(m.group(2), 16) + RELOC_BITS
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
    fl, recs, pals = files()
    body = sum(r["body"] for r in recs)
    print(f"ROBOT SMOKE: {len(recs)} records ({body} body, {len(recs) - body} effect), "
          f"palettes {sorted(pals)}")
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
            raise SystemExit(f"stale: {stale} - rerun tools/make_robosmoke.py --apply")
        if (LOAD2 / f"{PACKS[0][1]}.TBL").exists():
            if not OUT_TBL.exists() or OUT_TBL.read_text(encoding="latin-1") != tables_text():
                raise SystemExit("src/RSMOKE.TBL is stale - rerun tools/make_robosmoke.py --tables")
        print("ROBOT SMOKE libraries, packs and tables are current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
