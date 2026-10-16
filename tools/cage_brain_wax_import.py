#!/usr/bin/env python3
"""Generate where each victim stands for JOHNNY CAGE'S BRAIN PUNCH, from
data/CAGEBRAIN.WAX.

    python tools/cage_brain_wax_import.py           rewrite the generated block
    python tools/cage_brain_wax_import.py --check   exit 1 if it is stale
    python tools/cage_brain_wax_import.py --show    print the table, write nothing

The IMGTOOL project holds Cage on JCHIPUNCH3 (CAGE2.IMG, unmirrored, offset 0)
and, one slot per body, that body's head-with-the-hole frame (*HEADHOLE1 /
*DEADHEAD1 - the first frame of a_headhole_fall), MIRRORED to face him and
moved by local_dx/dy until the head sits on the fist.

The head is the LAST piece of that frame's multipart list and every piece
hangs off the one object anchor, so moving the head in the WAX is moving the
whole body: the generated row puts the victim's ANCHOR where the WAX put the
head's.  No anipoint in any IMG changes.

OFFSETS.  local_dx/dy are added to the frame's anipoint, and IMGTOOL mirrors
with the game's own rule (MirrorConvention_Ani2: left = anchor - (w - anix)),
so a mirrored frame's anchor lands at origin + dx and every frame's at
origin - dy.  The origin is Cage's anchor.  So the victim's anchor is dx in
front of Cage and -dy below him.

The row is `.word -dx,-dy`, read by adjust_him_tbl (get_his_char_long +
multi_adjust_xy) after match_him_with_me_f has parked him on Cage's anchor
facing him - clapped_lineups' contract.  x is negated because
multi_adjust_xy negates it again on the victim, who faces the other way.

Rows are by VICTIM ochar.  Bodies share art (the seven ninjas, the four
female ninjas), so one slot covers each family; Kintaro and Shao Kahn have no
headhole art and keep the old fixed lineup (JCH_BOSS).  A body the WAX does
not carry is refused rather than defaulted, and so is a slot the game would
not draw the way IMGTOOL does (a mirrored Cage, an offset Cage, an unmirrored
victim).  It also proves each module's first headhole frame still ends on the
record its slot was posed with.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jade_impale_wax_import as wax       # IMG + WAX readers

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "CAGEBRAIN.WAX")
ASM = os.path.join(ROOT, "src", "MKDEATH.ASM")
BEGIN = ";>>>WAX BEGIN cage_brain"
END = ";<<<WAX END cage_brain"

CAGE_REC = "JCHIPUNCH3"
JCH_BOSS = (56, 7)          # the single lineup every victim used to get

# head record prefix -> (module that draws it, its HOLE1 frame label)
FAMILIES = {
    "TM": ("MKHH.ASM", "HHHOLE1"), "LK": ("MKLK.ASM", "LKHOLE1"),
    "JC": ("MKJC.ASM", "JCHOLE1"), "UG": ("MKSA.ASM", "UGHOLE1"),
    "KT": ("MKFN.ASM", "KTHOLE1"), "ST": ("MKST.ASM", "STHOLE1"),
    "RN": ("MKRD.ASM", "RNHOLE1"), "NJ": ("MKNJ.ASM", "NJHOLE1"),
    "JX": ("MKJX.ASM", "JXHOLE1"),
}
# ochar 0..19 -> head prefix (None = boss, fixed lineup)
OCHARS = ["TM", "LK", "JC", "UG", "KT", "KT", "ST", "RN", "NJ", "NJ",
          "NJ", "JX", None, None, "NJ", "NJ", "KT", "NJ", "KT", "NJ"]
NAMES = ["Kung Lao", "Liu Kang", "Johnny Cage", "Baraka", "Kitana",
         "Mileena", "Shang Tsung", "Raiden", "Sub-Zero", "Reptile",
         "Scorpion", "Jax", "Kintaro", "Shao Kahn", "Smoke", "Noob Saibot",
         "Jade", "Ermac", "Khameleon", "Rain"]


def slots(kv):
    """every slot with an IMG behind it -> (record, dx, dy, mirror, slot)"""
    out = []
    for n in range(int(kv.get("slot.count", "0"))):
        path = kv.get(f"slot.{n}.doc_path", "")
        seq = wax.ints(kv, f"slot.{n}.sequence_frames")
        if not path or not seq:
            continue
        if len(seq) != 1:
            sys.exit(f"CAGEBRAIN.WAX slot {n}: {len(seq)} frames; each slot is ONE pose")
        name = os.path.basename(path.replace("\\", "/"))
        recs, _ = wax.read_img(os.path.join(ROOT, "data", name))
        if not 0 <= seq[0] < len(recs):
            sys.exit(f"CAGEBRAIN.WAX slot {n}: index {seq[0]} is outside {name}")
        g = lambda k: (wax.ints(kv, f"slot.{n}.{k}") or [0])[0]
        out.append((recs[seq[0]], g("local_dx"), g("local_dy"), g("frame_mirror"), n))
    return out


def hole_pieces(src, label, module):
    """the piece list a frame label names, across lines, up to its 0"""
    m = re.search(rf"^{label}\b(.*)$", src, re.M)
    if not m:
        sys.exit(f"{module}: no {label} frame list")
    pieces, rest = [], src[m.start(1):].splitlines()
    for line in rest:
        line = line.split(";", 1)[0]
        d = re.search(r"\.long\s+(.*)", line)
        if not d:
            if line.strip():
                break
            continue
        for p in (x.strip() for x in d.group(1).split(",")):
            if p == "0":
                return pieces
            if p:
                pieces.append(p)
    sys.exit(f"{module}: {label} has no 0 terminator")


def build():
    kv = wax.parse_wax(WAX)
    cage, heads = None, {}
    for rec, dx, dy, m, n in slots(kv):
        if rec["name"] == CAGE_REC:
            if dx or dy or m & 1:
                sys.exit(f"slot {n}: {CAGE_REC} must sit unmirrored at offset 0 - "
                         f"it is the origin every head is measured from")
            cage = rec
            continue
        if not re.search(r"(HEADHOLE|DEADHEAD)1$", rec["name"]):
            continue
        if not m & 1:
            sys.exit(f"slot {n}: {rec['name']} is not mirrored - the victim faces Cage")
        pre = rec["name"][:2]
        if pre not in FAMILIES:
            sys.exit(f"slot {n}: {rec['name']} - no fighter draws a {pre} headhole")
        if pre in heads:
            sys.exit(f"slots {heads[pre][3]} and {n} both pose the {pre} head")
        heads[pre] = (rec["name"], dx, -dy, n)
    if cage is None:
        sys.exit(f"CAGEBRAIN.WAX has no {CAGE_REC} slot")
    for pre, (module, hole) in FAMILIES.items():
        if pre not in heads:
            sys.exit(f"CAGEBRAIN.WAX poses no {pre} head (needed by {module})")
        src = open(os.path.join(ROOT, "src", module), errors="replace").read()
        pieces = hole_pieces(src, hole, module)
        if not pieces or pieces[-1] != heads[pre][0]:
            sys.exit(f"{module}: {hole} ends on {pieces[-1:]} - the WAX posed "
                     f"{heads[pre][0]}; the head must be the LAST piece")

    rows = []
    for ochar, pre in enumerate(OCHARS):
        reach, drop = JCH_BOSS if pre is None else heads[pre][1:3]
        src = "no headhole art: the old fixed lineup" if pre is None else \
            f"{heads[pre][0]} (slot {heads[pre][3]})"
        rows.append((ochar, reach, drop, src))
    return rows


def head_centre(lib_glob, name):
    """middle of a head record's opaque pixels, from its anchor (facing space)"""
    import glob
    for f in sorted(glob.glob(os.path.join(ROOT, "data", lib_glob))):
        recs, _ = wax.read_img(f)
        for r in recs:
            if r["name"] == name:
                px = r["px"]
                ys = [y for y, row in enumerate(px) if any(row)]
                xs = [x for x in range(r["w"]) if any(row[x] for row in px)]
                return (xs[0] + xs[-1]) / 2 - r["ax"], (ys[0] + ys[-1]) / 2 - r["ay"]
    return None


def kano_row(lk_reach, lk_drop):
    """MK1 KANO (Wolf, ochar 22): his headhole frames are Liu Kang's lane on his
    own art (tools/kano_synth.py), so his row is Liu Kang's moved by where his
    head sits against Liu Kang's in HOLE1.  Facing Cage, a point hx in front
    of the anchor is at anchor - hx, so the reach grows by hx(Kano) - hx(LK);
    y is down, so the drop grows by hy(LK) - hy(Kano)."""
    lk, kn = head_centre("KANG*.IMG", "LKDEADHEAD1"), head_centre("KANO*.IMG", "KNHOLEHEAD1")
    if not lk or not kn:
        return None
    return round(lk_reach + kn[0] - lk[0]), round(lk_drop + lk[1] - kn[1])


def render(rows):
    w = max(len(n) for n in NAMES)
    out = [BEGIN,
           "; GENERATED by tools/cage_brain_wax_import.py from data/CAGEBRAIN.WAX -",
           "; edit the project in IMGTOOL and re-run the tool, never this block.",
           ";",
           "; Where each victim stands for the brain punch: his ANCHOR off Cage's, by",
           "; victim ochar, so his head is on the fist.  [x:y] words for adjust_him_tbl",
           "; after match_him_with_me_f; x is minus the reach (multi_adjust_xy negates",
           "; it again on a man facing the other way), y is plus = DOWN.",
           "jch_place"]
    for ochar, reach, drop, src in rows:
        out.append(f"\t.word\t{-reach},{drop}\t; {ochar:2} {NAMES[ochar]:{w}}  {src}")
    # the Wolf-only fighters' rows (tools/wolf_fighter_rows.py owns the form)
    import wolf_fighter_rows
    # (Kano's row is worked out from Liu Kang's: wolf_fighter_rows._kano_jch)
    out += wolf_fighter_rows.block("jch_place", "word",
                                   [[str(-r), str(d)] for _o, r, d, _s in rows]) or []
    out.append(END)
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    block = render(build())
    if a.show:
        print(block, end="")
        return 0
    asm = open(ASM, newline="").read()
    nl = "\r\n" if "\r\n" in asm else "\n"
    if BEGIN not in asm or END not in asm:
        sys.exit(f"{ASM}: no {BEGIN} / {END} markers")
    i, j = asm.index(BEGIN), asm.index(END)
    j = asm.index("\n", j) + 1
    new = asm[:i] + block.replace("\n", nl) + asm[j:]
    if a.check:
        if new != asm:
            print("cage_brain_wax_import: src/MKDEATH.ASM jch_place is STALE against "
                  "data/CAGEBRAIN.WAX - run tools/cage_brain_wax_import.py")
            return 1
        print("cage_brain_wax_import: jch_place matches data/CAGEBRAIN.WAX")
        return 0
    if new != asm:
        open(ASM, "w", newline="").write(new)
        print("cage_brain_wax_import: wrote jch_place")
    else:
        print("cage_brain_wax_import: jch_place already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
