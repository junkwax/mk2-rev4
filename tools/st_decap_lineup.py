#!/usr/bin/env python3
"""Where each victim stands for SHANG TSUNG'S OLD-SHANG BLADE DECAPITATION
(do_st_decap, MKDEATH.ASM), measured off the art so the blade is in his neck.

    python tools/st_decap_lineup.py            rewrite stdc_place + the rig's expectation
    python tools/st_decap_lineup.py --check    Phase D: exit 1 if either is stale
    python tools/st_decap_lineup.py --show     print the measurements, write nothing
    python tools/st_decap_lineup.py --png DIR  render Shang + every body at its spacing

THE CUT IS ONE PICTURE.  Shang holds STLAUGHFAT13 (the follow-through, blade
out and angled up) for the whole time the victim stands headless on the first
frame of his own a_decapfall.  So "the blade is in his neck" is a statement
about two still frames, and both are measured here:

  the BLADE   the run of thin columns at the right-hand end of STLAUGHFAT13
              (nothing else in the frame is <= BLADE_THICK rows tall), as a
              centre line y(x) off Shang's anchor
  the STUMP   the top rows of the victim's first decapfall frame - the wound -
              as (centre x, top y) off HIS anchor

The two anchors are not at one height: each fighter stands at
ground_y - ochar_ground_offsets[ochar] (MKGUYS.ASM), which is read from the
source, never typed.

THE BLADE IS ANGLED AND THAT IS WHAT MAKES THIS WORK WITHOUT LIFTING ANYBODY.
It climbs ~16 px over its 36 px length, and every body's stump height falls in
or just above that span - so there is a point ALONG the blade at each victim's
neck height, and the lineup is purely horizontal: a short neck stands nearer
the guard, a tall one out at the tip.  Nobody is floated or sunk (the brain
punch's jch_place does both, because a fist has one height).

Three bodies - Baraka, Raiden, Jax - are taller than the tip reaches.  They
take the outermost usable column and the blade sits RESID px under the top of
the wound; MAX_RESID fails the build if art ever moves that past what reads as
a cut.  BLADE_IN keeps the tip a few px THROUGH the neck, never short of it.

stdc_place is one word per victim ochar: the distance from Shang's anchor to
his, in the direction Shang faces.  Bodies share art (the ninjas, the female
ninjas), so one measurement covers each family.  Kintaro and Shao Kahn have no
decap art (decap_fall gives them the knockdown) and take BOSS_D.

The rig (tools/run_st_decap_lineup_test.ps1) reads tools/st_decap_lineup_expect.lua
and asserts the same numbers off the live objects at the cut.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jade_impale_wax_import as wax       # IMG reader (records + pixels)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASM = os.path.join(ROOT, "src", "MKDEATH.ASM")
LUA = os.path.join(ROOT, "tools", "st_decap_lineup_expect.lua")
BEGIN = ";>>>GEN BEGIN st_decap_lineup"
END = ";<<<GEN END st_decap_lineup"

BLADE_IMG, BLADE_REC = "OGTSUNG1.IMG", "STLAUGHFAT13"
BLADE_THICK = 4         # a blade column is at most this many rows
BLADE_MIN_LEN = 24      # ...and there must be this many of them, or it is not the blade
BLADE_IN = 4            # the tip ends at least this far PAST the stump's centre
BLADE_GUARD = 6         # ...and the stump is at least this far out from the guard
STUMP_ROWS = 3          # the wound = the top rows of the headless frame
MAX_RESID = 8           # px the blade may sit under the top of the wound
BOSS_D = 72             # no decap art: about the middle of the measured spacings
GATE = 0x60             # fatality_xfer_close's range; a spacing past it would PUSH him

# body family -> (module, the IMG its decap art is authored in)
FAMILIES = {
    "TM": ("MKHH.ASM", "HATHED11.IMG"), "LK": ("MKLK.ASM", "KANG10.IMG"),
    "JC": ("MKJC.ASM", "CAGE10.IMG"), "UG": ("MKSA.ASM", "UGMO10.IMG"),
    "KT": ("MKFN.ASM", "KAT11.IMG"), "ST": ("MKST.ASM", "TSUNG10.IMG"),
    "RN": ("MKRD.ASM", "RAID9.IMG"), "NJ": ("MKNJ.ASM", "NINJAS11.IMG"),
    "JX": ("MKJX.ASM", "NUJAX10.IMG"),
}
# pieces that are overlays, not body: Cage's OTOMIX logo strips (JCLOGO.IMG)
OVERLAY = re.compile(r"^JC\w+L$")
# ochar 0..19 -> family (None = boss)
OCHARS = ["TM", "LK", "JC", "UG", "KT", "KT", "ST", "RN", "NJ", "NJ",
          "NJ", "JX", None, None, "NJ", "NJ", "KT", "NJ", "KT", "NJ"]
NAMES = ["Kung Lao", "Liu Kang", "Johnny Cage", "Baraka", "Kitana",
         "Mileena", "Shang Tsung", "Raiden", "Sub-Zero", "Reptile",
         "Scorpion", "Jax", "Kintaro", "Shao Kahn", "Smoke", "Noob Saibot",
         "Jade", "Ermac", "Khameleon", "Rain"]
ST_OCHAR = 6


def die(msg):
    sys.exit("st_decap_lineup: " + msg)


def tbl_geometry():
    """name -> (w, h, anix, aniy) as the ROM carries it (src/*.TBL is what links)"""
    out = {}
    for fn in sorted(os.listdir(os.path.join(ROOT, "src"))):
        if not fn.upper().endswith(".TBL"):
            continue
        txt = open(os.path.join(ROOT, "src", fn), errors="replace").read()
        for n, w, h, ax, ay in re.findall(
                r"^(\w+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)", txt, re.M):
            out.setdefault(n, (int(w), int(h), int(ax), int(ay)))
    return out


def record(img, name, tbl):
    """pixels from the IMG, geometry from the linked TBL - and they must agree"""
    recs, pals = wax.read_img(os.path.join(ROOT, "data", img))
    r = next((x for x in recs if x["name"] == name), None)
    if r is None:
        die(f"{img} has no record {name}")
    g = tbl.get(name)
    if g is None:
        die(f"no src/*.TBL carries {name}")
    if (r["w"], r["h"], r["ax"], r["ay"]) != g:
        die(f"{name}: {img} says w,h,anix,aniy = {(r['w'], r['h'], r['ax'], r['ay'])} but "
            f"the linked TBL says {g} - promote the IMG (or its anipoint) before this "
            f"can measure what the game draws")
    pal = list(pals.values())
    r = dict(r)
    r["pal"] = pal[r["palnum"] - 3] if 0 <= r["palnum"] - 3 < len(pal) else None
    return r


def cloud(recs):
    """{(x, y): colour word} off the anchor, facing right"""
    out = {}
    for r in recs:
        for y in range(r["h"]):
            row = r["px"][y]
            for x in range(r["w"]):
                if row[x]:
                    p = r["pal"]
                    out[(x - r["ax"], y - r["ay"])] = p[row[x]] if p and row[x] < len(p) else 0x7fff
    return out


def first_frame(module, table):
    """the frame label a_<table> opens on, and its piece list"""
    src = open(os.path.join(ROOT, "src", module), errors="replace").read()
    m = re.search(rf"^{table}\b(?:\s*\.long\s+(\w+))?(?:[^\n]*\n\s*\.long\s+(\w+))?", src, re.M)
    lab = (m.group(1) or m.group(2)) if m else None
    if not lab:
        die(f"{module}: no {table}")
    m = re.search(rf"^{lab}\b(.*)$", src, re.M)
    if not m:
        die(f"{module}: {table} opens on {lab}, which has no piece list")
    pieces = []
    for line in src[m.start(1):].splitlines():
        line = line.split(";", 1)[0]
        d = re.search(r"\.long\s+(.*)", line)
        if not d:
            if line.strip():
                break
            continue
        for p in (x.strip() for x in d.group(1).split(",")):
            if p == "0":
                return lab, pieces
            if p:
                pieces.append(p)
    die(f"{module}: {lab} has no 0 terminator")


def ground_offsets():
    src = open(os.path.join(ROOT, "src", "MKGUYS.ASM"), errors="replace").read()
    m = re.search(r"^ochar_ground_offsets\b(.*?)^\s*\.if\b", src, re.S | re.M)
    if not m:
        die("ochar_ground_offsets not found in src/MKGUYS.ASM")
    vals = [int(v, 16) for v in re.findall(r"^\s*\.word\s+0?([0-9a-fA-F]+)h", m.group(1), re.M)]
    if len(vals) != 20:
        die(f"ochar_ground_offsets has {len(vals)} rows before its Wolf block, expected 20")
    return vals


def lane_guard():
    """the two facts about the lane this measurement stands on"""
    src = open(os.path.join(ROOT, "src", "MKST.ASM"), errors="replace").read()
    m = re.search(r"^a_st_decap_laugh\s*\n\s*\.long\s+(\w+)", src, re.M)
    if not m or m.group(1) != "STLF13":
        die("a_st_decap_laugh (MKST.ASM) no longer opens on STLF13 - the frame Shang "
            "holds at the cut changed, so the blade must be re-measured on the new one")
    if not re.search(rf"^STLF13\s+\.long\s+{BLADE_REC},0", src, re.M):
        die(f"STLF13 (MKST.ASM) is no longer the single piece {BLADE_REC}")


def blade_line(tbl):
    r = record(BLADE_IMG, BLADE_REC, tbl)
    c = cloud([r])
    right = max(x for x, _ in c)
    line, x = {}, right
    while True:
        ys = sorted(y for (px, y) in c if px == x)
        if not ys or ys[-1] - ys[0] + 1 > BLADE_THICK or len(ys) != ys[-1] - ys[0] + 1:
            break
        line[x] = (ys[0] + ys[-1]) / 2.0
        x -= 1
    if len(line) < BLADE_MIN_LEN:
        die(f"{BLADE_REC}: only {len(line)} thin columns at its right-hand end - that is "
            f"not a blade; the art changed and BLADE_* must be looked at again")
    xs = sorted(line)
    if line[xs[0]] <= line[xs[-1]]:
        die(f"{BLADE_REC}: the blade no longer climbs toward its tip, which is what lets "
            f"one horizontal spacing reach every neck height")
    return line, c


def measure():
    lane_guard()
    tbl = tbl_geometry()
    gofs = ground_offsets()
    blade, shang = blade_line(tbl)
    xs = sorted(blade)
    lo, hi = xs[0] + BLADE_GUARD, xs[-1] - BLADE_IN
    fam = {}
    for pre, (module, img) in FAMILIES.items():
        lab, pieces = first_frame(module, "a_decapfall")
        recs = [record("JCLOGO.IMG" if OVERLAY.match(p) else img, p, tbl) for p in pieces]
        body = cloud(recs)
        top = min(y for _, y in body)
        wound = [x for (x, y) in body if y < top + STUMP_ROWS]
        fam[pre] = dict(label=lab, pieces=pieces, body=body, top=top,
                        xc=(min(wound) + max(wound)) // 2, w=max(wound) - min(wound) + 1)
    rows = []
    for ochar, pre in enumerate(OCHARS):
        if pre is None:
            rows.append(dict(ochar=ochar, d=BOSS_D, boss=True))
            continue
        f = fam[pre]
        rise = gofs[ochar] - gofs[ST_OCHAR]         # his anchor is this far ABOVE Shang's
        want = f["top"] - rise                      # top of the wound, off Shang's anchor
        bx = min(range(lo, hi + 1), key=lambda x: (abs(blade[x] - want), -x))
        resid = blade[bx] - want                    # + = blade under the top of the wound
        d = bx + f["xc"]                            # he faces Shang, so his art is mirrored
        if not 0 <= resid <= MAX_RESID:
            die(f"{NAMES[ochar]}: the blade would sit {resid:+.1f} px off the top of his "
                f"wound (limit 0..{MAX_RESID}) - horizontal spacing no longer reaches him")
        if not 0 < d <= GATE:
            die(f"{NAMES[ochar]}: spacing {d} is outside 1..{GATE}")
        rows.append(dict(ochar=ochar, d=d, boss=False, fam=pre, bx=bx, by=blade[bx],
                         xc=f["xc"], top=f["top"], rise=rise, resid=resid, label=f["label"]))
    return rows, fam, blade, shang, gofs


def kano_d():
    """MK1 KANO (Wolf, ochar 22): the same measurement on HIS first decap frame
    (kn_a_decapfall, src/MK1KNL.ASM - built out of MK1's headless body by
    tools/kano_synth.py), with his Wolf ochar_ground_offsets row.  Read by
    tools/wolf_fighter_rows.py for his stdc_place row."""
    import glob
    tbl = tbl_geometry()
    blade, _shang = blade_line(tbl)
    xs = sorted(blade)
    lo, hi = xs[0] + BLADE_GUARD, xs[-1] - BLADE_IN
    _lab, pieces = first_frame("MK1KNL.ASM", "kn_a_decapfall")
    libs = {}
    for f in sorted(glob.glob(os.path.join(ROOT, "data", "KANO*.IMG"))):
        if re.fullmatch(r"KANO\d+", os.path.splitext(os.path.basename(f))[0]):
            for r in wax.read_img(f)[0]:
                libs[r["name"]] = os.path.basename(f)
    body = cloud([record(libs[p], p, tbl) for p in pieces])
    top = min(y for _, y in body)
    wound = [x for (x, y) in body if y < top + STUMP_ROWS]
    src = open(os.path.join(ROOT, "src", "MKGUYS.ASM"), errors="replace").read()
    m = re.search(r"^ochar_ground_offsets\b.*?\.if\s+wunit[^\n]*\n\s*\.word\s+([^;\n]*)", src, re.S | re.M)
    wolf = [int(v.strip().rstrip("hH"), 16) for v in m.group(1).split(",")]
    rise = wolf[22 - 20] - ground_offsets()[ST_OCHAR]
    want = top - rise
    bx = min(range(lo, hi + 1), key=lambda x: (abs(blade[x] - want), -x))
    resid = blade[bx] - want
    d = bx + (min(wound) + max(wound)) // 2
    if not 0 <= resid <= MAX_RESID or not 0 < d <= GATE:
        die(f"MK1 Kano: blade {resid:+.1f} px off his wound, spacing {d} - out of range")
    return d


def render_asm(rows):
    w = max(len(n) for n in NAMES)
    out = [BEGIN,
           "; GENERATED by tools/st_decap_lineup.py from the art (OGTSUNG1.IMG's",
           "; STLAUGHFAT13 blade against each body's first a_decapfall frame) - re-run",
           "; the tool, never edit this block.",
           ";",
           "; How far in front of Shang each victim's anchor stands, by victim ochar,",
           "; so the point of the blade at HIS neck height is in his neck.  The blade",
           "; climbs toward its tip: short necks stand in, tall ones out.",
           "stdc_place"]
    for r in rows:
        if r["boss"]:
            note = "no decap art: a middling spacing"
        else:
            note = (f"{r['label']}: blade x{r['bx']:+d} on his wound, "
                    f"{r['resid']:.1f} px under its top")
        out.append(f"\t.word\t{r['d']}\t; {r['ochar']:2} {NAMES[r['ochar']]:{w}}  {note}")
    import wolf_fighter_rows
    out += wolf_fighter_rows.block("stdc_place", "word", [[str(r["d"])] for r in rows]) or []
    out.append(END)
    return "\n".join(out) + "\n"


def render_lua(rows, blade):
    xs = sorted(blade)
    out = ["-- GENERATED by tools/st_decap_lineup.py - do not edit.",
           "-- Shang's blade decapitation, as the art says it must line up.  Everything is",
           "-- in SHANG'S FACING SPACE off his anchor: +x is the way he faces, +y is down.",
           "--   d      victim anchor x - Shang anchor x",
           "--   bx,by  the point of the blade that is in his neck",
           "--   xc,top his wound (centre, top row) off HIS anchor, his own facing space",
           "--   rise   his anchor is this far above Shang's (ochar_ground_offsets)",
           "--   resid  by - (top - rise): px the blade sits under the top of the wound",
           "return {",
           f"  max_resid = {MAX_RESID},",
           f"  blade = {{x0 = {xs[0]}, x1 = {xs[-1]}, y0 = {blade[xs[0]]}, y1 = {blade[xs[-1]]}}},",
           "  victim = {"]
    for r in rows:
        if r["boss"]:
            out.append(f"    [{r['ochar']}] = {{name = '{NAMES[r['ochar']]}', d = {r['d']}, boss = true}},")
        else:
            out.append(f"    [{r['ochar']}] = {{name = '{NAMES[r['ochar']]}', d = {r['d']}, "
                       f"bx = {r['bx']}, by = {r['by']}, xc = {r['xc']}, top = {r['top']}, "
                       f"rise = {r['rise']}, resid = {r['resid']}}},")
    out += ["  },", "}", ""]
    return "\n".join(out)


def rgb(c):
    return ((c >> 10 & 31) << 3, (c >> 5 & 31) << 3, (c & 31) << 3)


def png(outdir, rows, fam, shang):
    from PIL import Image
    os.makedirs(outdir, exist_ok=True)
    seen, cells = set(), []
    for r in rows:
        if r["boss"] or r["fam"] in seen:
            continue
        seen.add(r["fam"])
        cells.append(r)
    cw, ch, ox, oy = 150, 190, 45, 20
    sheet = Image.new("RGB", (cw * len(cells), ch), (40, 0, 60))
    for i, r in enumerate(cells):
        x0 = i * cw + ox
        for (x, y), v in fam[r["fam"]]["body"].items():
            sheet.putpixel((x0 + r["d"] - x, oy + y - r["rise"]), rgb(v))
        for (x, y), v in shang.items():
            sheet.putpixel((x0 + x, oy + y), rgb(v))
    sheet = sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST)
    path = os.path.join(outdir, "st_decap_lineup.png")
    sheet.save(path)
    print("wrote", path, "(" + ", ".join(r["fam"] for r in cells) + ")")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--png", metavar="DIR")
    a = ap.parse_args()
    rows, fam, blade, shang, _gofs = measure()
    block, lua = render_asm(rows), render_lua(rows, blade)
    if a.png:
        png(a.png, rows, fam, shang)
    if a.show:
        print(block, end="")
        return 0
    asm = open(ASM, newline="", encoding="latin-1").read()
    nl = "\r\n" if "\r\n" in asm else "\n"
    if BEGIN not in asm or END not in asm:
        die(f"{ASM}: no {BEGIN} / {END} markers")
    i, j = asm.index(BEGIN), asm.index(END)
    j = asm.index("\n", j) + 1
    new = asm[:i] + block.replace("\n", nl) + asm[j:]
    old_lua = open(LUA, encoding="utf-8").read() if os.path.exists(LUA) else None
    if a.check:
        bad = []
        if new != asm:
            bad.append("src/MKDEATH.ASM stdc_place")
        if old_lua != lua:
            bad.append("tools/st_decap_lineup_expect.lua")
        if bad:
            print("st_decap_lineup: STALE against the art: " + ", ".join(bad) +
                  " - run tools/st_decap_lineup.py")
            return 1
        print("st_decap_lineup: stdc_place and the rig's expectation match the art")
        return 0
    if new != asm:
        open(ASM, "w", newline="", encoding="latin-1").write(new)
        print("st_decap_lineup: wrote stdc_place")
    if old_lua != lua:
        open(LUA, "w", encoding="utf-8", newline="\n").write(lua)
        print("st_decap_lineup: wrote", os.path.relpath(LUA, ROOT))
    if new == asm and old_lua == lua:
        print("st_decap_lineup: already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
