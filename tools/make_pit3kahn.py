#!/usr/bin/env python3
r"""SHAO KAHN ON HIS THRONE IN THE PIT III (curback 022h, WOLF ONLY).

data/NEWSHAO.IMG (UMK3's Kahn library) carries a SEATED Shao Kahn that no
MK3/UMK3 code ever draws - nothing in MK3SRC, the UMK3 C port or this tree
names SHATAUNT / SHACKNE / SHAFISTS / SHASITLEG (the IMG's own sequences
SHANSIT and SHANSIT_1 group them, every hold 1, so there is no authored
timing).  They are a torso set plus ONE shin:

  SHATAUNT1-4   the rest pose and a clawing taunt
  SHACKNE1-11   the arm swept out over the armrest
  SHAFISTS1-7   both fists raised and brought down
  SHASITLEG     the shin, draped over the throne's gargoyle armrest

The torso and the shin share one anchor (their anipoints put the shin under
the torso), and drawn FLIPPED, facing the fight, on THE PIT III's throne at
the right end of the bridge (plane 1, the fighters' own plane), they sit in
it to the pixel: torso behind the seat back with an arm on the armrest, the
shin over the armrest post.  The anchor (KAHN_X/KAHN_Y) was chosen by
compositing against the stage render - `--preview` redraws that proof.

No throne block needs to cover him, so he draws on a private list
(up3_kahn_lst, RAM.ASM) straight after baklst1, in front of the throne and
behind the fighters.

  data/UP3KN.LOD     LOD over NEWSHAO.IMG (PON> - the records name
                     BGPAL1_P, Kahn's own palette, which MK2 already links)
  src/UP3KAHNB.ASM   GENERATED: LOAD2's tmp/load2/UP3KN.TBL with the SAGs
                     relocated, the placement, the lanes

Linear 0x1568000..0x1590000, the start of the growth THE PIT 3's tool and
make_nightwolf.py leave free (0x1568000..0x1600000); loaded 4 MB lower and
moved up by makevrom.py WOLF_RELOCATE, as every u110-u113 pack is.

  --parts   write data/UP3KN.LOD and data/UP3LANT.IMG
  --apply   write src/UP3KAHNB.ASM (Phase B2d8c2, after LOAD2)
  --check   both match, and the packed pixels decode to NEWSHAO.IMG's
  --preview [CAMX]  composite every pose on the stage -> tmp/pit3kahn/
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk1pit as pit        # noqa: E402
import make_mk1court as court    # noqa: E402
import make_mk3cave as cave      # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
IMG = DATA / "NEWSHAO.IMG"
PACK = ("UP3KN", 0x1568000, 0x1590000)
RELOC = 0x400000                  # makevrom.py WOLF_RELOCATE
RELOC_BITS = RELOC * 8
OUT_ASM = SRC / "UP3KAHNB.ASM"
TBL = LOAD2 / "UP3KN.TBL"
PAL = "BGPAL1_P"

# The anchor, in plane-1 world coordinates (= the fighters' world: THE PIT
# III's plane 1 scrolls at 20000h).  Chosen by composite at the right scroll
# limit (camera 801): the torso's bottom row on the seat cushion, the shin
# over the gargoyle armrest.
KAHN_X = 1130
KAHN_Y = 40

# Where the SHIN goes, off that anchor, in SCREEN pixels (+x right, +y down).
# The torso and shin share an anchor in the IMG, but there the THIGH is drawn
# by the throne UMK3's art was made for (SHAGETUP1 shows the whole seated
# leg): its front panel hides the thigh and the shin hangs in front of it.
# THE PIT III's seat is a plain block with the torso sitting ON it, so at the
# shared anchor the shin floats 4px under him, connected to nothing.  It
# sits squarely in front of the gargoyle armrest post: knee at the gargoyle's
# head, boot at the post's foot (y ~200), the shin over the post's column
# (2026-10-13, playtest: "should evenly match in front of the gargoyle"; an
# earlier cut tucked it under his belt down the seat front, at LEG_DX 36).
LEG_DX = -14
LEG_DY = -6

TAUNT = [f"SHATAUNT{i}" for i in range(1, 5)]
CACKLE = [f"SHACKNE{i}" for i in range(1, 12)]
FISTS = [f"SHAFISTS{i}" for i in range(1, 8)]
LEG = "SHASITLEG"
GETUP = [f"SHAGETUP{i}" for i in range(1, 5)]
FRAMES = TAUNT + CACKLE + FISTS + [LEG] + GETUP
REST = "SHATAUNT1"

# FINISH HIM: he RISES out of the throne (SHAGETUP1-4 - the whole body, seated
# leg and all, so the shin object is parked out of sight while they play) and
# then throws his arm out at the loser as he says it.  NEWSHAO has no standing
# point, so the point is MK2's own: BGTALK1-5 over BGTALKLEG1 (data/BOSS5.IMG,
# the a_sk_talkup Kahn points with in a fight), on the same BGPAL1_P - word for
# word, which read_talk() asserts.  Packed here as whole PON> records (MK2's
# copies are POF> multipart pieces, no use to a gso_dmawnz object) and
# labelled UP3<name> so nothing can ever bind them to MKSK's BGTALKn lists.
# At the shared anchor SHAGETUP4's feet and BGTALKLEG1's land on the deck
# together (--preview draws every beat).
TALK_IMG = DATA / "BOSS5.IMG"
TALK = [f"BGTALK{i}" for i in range(1, 6)]
TALKLEG = "BGTALKLEG1"
TALK_FRAMES = TALK + [TALKLEG]

# HE RISES OFF THE SHIN HE IS KNEELING ON.  SHAGETUP1-2 draw the seated leg
# themselves, and at the shared anchor their shin lies RISE_SHIN (1,1) off
# where SHASITLEG would - but the seated shin is drawn LEG_DX/LEG_DY off that
# anchor (in front of the gargoyle post), so the leg would jump 15px back and
# 7px down on the first frame of the rise.  So the whole rise AND the standing
# point are drawn RISE_DX/RISE_DY off the anchor: the leg carries on from where
# he knelt and he finishes standing that much further in front of the throne
# (2026-10-14, playtest: "his front legs that are kneeled should inherit the
# standing up position, have them flush together").  rise_shin() measures the
# offset by template match and --check fails if the art stops agreeing.
RISE_SHIN = (1, 1)
RISE_DX = LEG_DX - RISE_SHIN[0]
RISE_DY = LEG_DY - RISE_SHIN[1]

# The gestures, each from the rest pose back to it.  The art has no authored
# timing; 5 ticks a frame (10.9 fps) is MK2's rate for heavier moves, and
# every gesture holds its far pose so it reads.
GESTURES = {
    "taunt": [("SHATAUNT2", 5), ("SHATAUNT3", 5), ("SHATAUNT4", 18), ("SHATAUNT3", 5),
              ("SHATAUNT2", 5)],
    "cackle": [(n, 4) for n in CACKLE[1:]] + [(CACKLE[-1], 20)]
              + [(n, 4) for n in reversed(CACKLE[1:-1])],
    "fists": [("SHAFISTS2", 4), ("SHAFISTS3", 4), ("SHAFISTS4", 4), ("SHAFISTS5", 30),
              ("SHAFISTS6", 5), ("SHAFISTS7", 5), ("SHAFISTS1", 5)],
    # FINISH HIM, in three lanes so up3k_proc can speak between them: up out
    # of the seat (ending stood on BGTALK1, where the legs object appears), the
    # arm out (the line is said as it lands on BGTALK5), the arm back down.
    "rise": [("SHAGETUP1", 5), ("SHAGETUP2", 5), ("SHAGETUP3", 5), ("SHAGETUP4", 6)],
    "point": [("BGTALK2", 3), ("BGTALK3", 3), ("BGTALK4", 3), ("BGTALK5", 3)],
    "lower": [("BGTALK4", 4), ("BGTALK3", 4), ("BGTALK2", 4), ("BGTALK1", 4)],
}
POINT_HOLD = 70                   # ticks on BGTALK5 after the line starts

# THE LANTERNS.  MKBGANI2.IMG (deadlythirdcombat - the MK3/UMK3 art tree) has
# a green lantern set on GRNLIT_P, the palette THE PIT III's own BDD carries,
# that no stage file places and no MK3/UMK3 code names (grepped: MK3SRC, the
# UMK3 C port, mk3-rebuild): LANTRN01-06, a dome that SPINS, 143x61; and
# LANTRNA + LANTRNB, the left and right halves of a big HANGING lantern
# (116x115, cage on top, spike below - the same design as the 36x35 one the
# stage does draw).  Placement is this project's (2026-10-13, the user's
# call: "replace the small ones"): the two domes take the two small lanterns'
# places on PLANE 3 - which carries nothing else - DRAWN AT A QUARTER SIZE
# (DMA oscale 0400h, an integer step so no uneven banding): 143 -> 36 px,
# the small lantern's own width, centred on each small one's centre
# (2026-10-13, the user's call: "shrink them to the old lantern size").  And
# the big lantern's body hangs UNDER each dome at the same quarter size, so
# each is one whole lantern - dome cap, green cage, spike - about 36x37 px,
# the old small lantern's footprint (2026-10-13, the user's call: "lantern a/b
# need to be below the spinning tops and resized").  At full size the cage's
# rim sits 30 px under the dome's top and the dome is drawn over it, so the
# spinning cap reads as the lantern's lid.
LANT_SRC = Path(r"C:\Users\you\Workplace\deadlythirdcombat-main\deadlythirdcombat-main\MKBGANI2.IMG")
LANT_IMG = DATA / "UP3LANT.IMG"       # the trimmed copy LOAD2 reads - written by --parts
DOME = [f"LANTRN0{i}" for i in range(1, 7)]
HANG = ["LANTRNA", "LANTRNB"]
LANT_FRAMES = DOME + HANG
LANT_SRC_PAL = "GRNLIT_P"
LANT_PAL = "UP3LT_P"                  # its name in the ROM
SMALL_X = (0, 133)                    # the small lanterns' blocks, plane-3 x (UP33BLKS)
SMALL_Y, SMALL_W, SMALL_H = 109, 36, 35   # ...y (up3_m3_y) and size (header 35h)
DOME_SCALE = 4                        # drawn at 1/DOME_SCALE (oscale step 0400h)
DOME_HALF = 72                        # LANTRN anchor to the dome's centre column
DOME_TICKS = 4                        # spin: no authored timing; 13.7 fps
CUP_DY = 8                            # the cage's top, below the dome's top (30 / 4)
CUP_DX = 2                            # ...and right of centre: the spike's tip is the
                                      #   joined picture's column 57/58, which the DMA's
                                      #   every-4th sampling lands ~1 px left of the
                                      #   dome's own centre (0.5 px right on average over
                                      #   the six spin frames) - playtest, 2026-10-13
CUP_BX = 14                           # LANTRNB off LANTRNA: a scaled half is 14-15 px,
                                      #   so they overlap a column rather than gap


LIB = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALREC = struct.Struct("<10s BB H I H H B B H")


def read_newshao():
    d = IMG.read_bytes()
    ic, pc, oset = LIB.unpack_from(d, 0)[:3]
    imgs = {}
    for i in range(ic):
        r = IMAGE.unpack_from(d, oset + i * IMAGE.size)
        n = r[0].split(b"\0")[0].decode()
        ax = r[2] - 0x10000 if r[2] & 0x8000 else r[2]
        ay = r[3] - 0x10000 if r[3] & 0x8000 else r[3]
        w, h, pn, off = r[4], r[5], r[6], r[7]
        st = (w + 3) & ~3
        imgs[n] = dict(w=w, h=h, ax=ax, ay=ay, pn=pn,
                       px=b"".join(d[off + y * st:off + y * st + w] for y in range(h)))
    p0 = oset + ic * IMAGE.size
    pals = []
    for i in range(pc):
        nm, _p, _b, cnt, fo, *_ = PALREC.unpack_from(d, p0 + i * PALREC.size)
        nm = nm.split(b"\0")[0].decode("latin-1")
        pals.append((nm, [struct.unpack_from("<H", d, fo + 2 * k)[0] for k in range(cnt)]
                     if fo + 2 * cnt <= len(d) and cnt < 256 else []))
    for n in FRAMES:
        if n not in imgs:
            raise SystemExit(f"{IMG.name} has no {n}")
        if pals[imgs[n]["pn"] - 3][0] != PAL:
            raise SystemExit(f"{n} is drawn in {pals[imgs[n]['pn'] - 3][0]}, not {PAL}")
    return imgs, pals[imgs[REST]["pn"] - 3][1]


def lab(n):
    """The ASM label of a packed frame: BOSS5's are prefixed (MKSK.ASM already
    has BGTALK1-5 as its own multipart lists)."""
    return "UP3" + n if n in TALK_FRAMES else n


def read_talk(kahn_pal):
    """BOSS5.IMG's point frames, which must be on Kahn's own palette."""
    imgs, pals = read_lib(TALK_IMG)
    for n in TALK_FRAMES:
        if n not in imgs:
            raise SystemExit(f"{TALK_IMG.name} has no {n}")
        nm, words = pals[imgs[n]["pn"] - 3]
        if nm != PAL or words != kahn_pal:
            raise SystemExit(f"{TALK_IMG.name}:{n} is not drawn in NEWSHAO's {PAL}")
    return {n: imgs[n] for n in TALK_FRAMES}


def rise_shin(imgs):
    """Where SHAGETUP1's own shin lies off SHASITLEG at the shared anchor (the
    best exact-pixel match within 12px)."""
    def place(n):
        im = imgs[n]
        w = im["w"]
        left, top = -(w - 1 - im["ax"]), -im["ay"]
        return {(left + (w - 1 - x), top + y): c for y in range(im["h"]) for x in range(w)
                if (c := im["px"][y * w + x])}
    shin, g = place(LEG), place(GETUP[0])
    best = max(((sum(1 for (x, y), c in shin.items() if g.get((x + dx, y + dy)) == c), dx, dy)
                for dx in range(-12, 13) for dy in range(-12, 13)))
    return best[1], best[2]


def read_lib(path):
    """{name: rec} and [(palname, words)] of an IMG library."""
    d = Path(path).read_bytes()
    ic, pc, oset = LIB.unpack_from(d, 0)[:3]
    p0 = oset + ic * IMAGE.size
    pals = []
    for i in range(pc - 3):     # the count includes LOAD2's 3 built-in palettes, never stored
        nm, _p, _b, cnt, fo, *_ = PALREC.unpack_from(d, p0 + i * PALREC.size)
        nm = nm.split(b"\0")[0].decode("latin-1")
        ok = cnt < 256 and fo + 2 * cnt <= len(d)
        pals.append((nm, [struct.unpack_from("<H", d, fo + 2 * k)[0] for k in range(cnt)] if ok else []))
    imgs = {}
    for i in range(ic):
        r = IMAGE.unpack_from(d, oset + i * IMAGE.size)
        n = r[0].split(b"\0")[0].decode("latin-1")
        w, h, pn, off = r[4], r[5], r[6], r[7]
        st = (w + 3) & ~3
        imgs[n] = dict(w=w, h=h, pn=pn,
                       ax=r[2] - 0x10000 if r[2] & 0x8000 else r[2],
                       ay=r[3] - 0x10000 if r[3] & 0x8000 else r[3],
                       px=b"".join(d[off + y * st:off + y * st + w] for y in range(h)))
    return imgs, pals


def lantern_img_bytes():
    """data/UP3LANT.IMG out of MKBGANI2.IMG: the eight lantern records and
    GRNLIT_P, nothing else - 63 KB for LOAD2 to read instead of a megabyte of
    other stages' art, and nothing in it the tool did not put there."""
    imgs, pals = read_lib(LANT_SRC)
    for n in LANT_FRAMES:
        if n not in imgs:
            raise SystemExit(f"{LANT_SRC.name} has no {n}")
        if pals[imgs[n]["pn"] - 3][0] != LANT_SRC_PAL:
            raise SystemExit(f"{n} is drawn in {pals[imgs[n]['pn'] - 3][0]}, not {LANT_SRC_PAL}")
    words = pals[imgs[DOME[0]]["pn"] - 3][1]
    return pit.build_img([(n, imgs[n]["ax"], imgs[n]["ay"], imgs[n]["w"], imgs[n]["h"], imgs[n]["px"], 0)
                          for n in LANT_FRAMES], [(LANT_SRC_PAL, 6, words)])


def read_lanterns():
    if not LANT_IMG.exists():
        raise SystemExit(f"{LANT_IMG} missing - run tools/make_pit3kahn.py --parts")
    imgs, pals = read_lib(LANT_IMG)
    missing = [n for n in LANT_FRAMES if n not in imgs]
    if missing:
        raise SystemExit(f"{LANT_IMG.name} lacks {', '.join(missing)}")
    return imgs, pals[imgs[DOME[0]]["pn"] - 3][1]


def dome_dx(limgs, f):
    """A dome frame's top-left x off the dome's centre column, AT ITS DRAWN
    SCALE.  ani_flag re-anchors with the UNSCALED anipoints (-1..-13 across
    the spin), which on a quarter-size dome is a 13 px wobble - so the spin
    table carries this and up3l_proc places each frame itself."""
    return -((DOME_HALF + limgs[f]["ax"]) // DOME_SCALE)


def lantern_layout(limgs):
    """Per lantern, on plane 3: the dome - (first frame, centre x, top y); dome
    2 starts three frames on, so the pair is out of step - and its cage's two
    halves' top-lefts.  The whole lantern is centred on the small one it
    replaces.  Nothing here is flipped."""
    a = limgs[HANG[0]]
    aw = -(-a["w"] // DOME_SCALE)                         # a half's drawn width
    ch = -(-max(limgs[n]["h"] for n in HANG) // DOME_SCALE)
    top = SMALL_Y + SMALL_H // 2 - (CUP_DY + ch) // 2
    domes, cups = [], []
    for k, x0 in enumerate(SMALL_X):
        f = DOME[3 * k]
        cx = x0 + SMALL_W // 2
        domes.append((f, cx, top - limgs[f]["ay"]))
        cups.append((cx - aw + CUP_DX, cx - aw + CUP_DX + CUP_BX, top + CUP_DY))
    return domes, cups


LOD = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE PIT III (UMK3), WOLF ONLY - SHAO KAHN ON HIS THRONE
;  (linear 0x{start:06X}..0x{end:06X}, loaded 4 MB lower and moved
;  up by makevrom.py WOLF_RELOCATE - LOAD2 refuses 8000000+)
;
;  GENERATED by tools/make_pit3kahn.py --parts.  UMK3's seated
;  Kahn out of NEWSHAO.IMG, which no MK3/UMK3 code ever drew: the
;  torso poses and the one shin; then the green lanterns out of
;  MKBGANI2.IMG (UP3LANT.IMG, trimmed by the tool).  PON>: built
;  with gso_dmawnz, which takes the palette off the record.
;  Headers: src/UP3KAHNB.ASM (the tool relocates the SAGs).
;
;**************************************************************
PON>
ZON>
PPP> 6
ASM> UP3KN.TBL
NEWSHAO.IMG
{recs}
BOSS5.IMG
---> {trecs}
UP3LANT.IMG
{lrecs}
"""


def lod_text():
    name, s, e = PACK
    rows = [FRAMES[i:i + 6] for i in range(0, len(FRAMES), 6)]
    return LOD.format(addr=court.lod_addr(s - RELOC), start=s, end=e,
                      recs="\n".join("---> " + ",".join(r) for r in rows),
                      trecs=",".join(TALK_FRAMES),
                      lrecs="\n".join("---> " + ",".join(r) for r in (DOME, HANG)))


def read_tbl():
    if not TBL.exists():
        raise SystemExit(f"{TBL} missing - run python build.py")
    out, lines = {}, TBL.read_text(encoding="latin-1").splitlines()
    for i, ln in enumerate(lines):
        t = ln.strip()
        if t.endswith(":") and t[:-1] in FRAMES + TALK_FRAMES + LANT_FRAMES:
            w, h, ax, ay = (int(v, 0) for v in lines[i + 1].split(None, 1)[1].split(","))
            sag = int(lines[i + 2].split()[1].rstrip("Hh"), 16) + RELOC_BITS
            ctrl = int(lines[i + 3].split()[1].rstrip("Hh"), 16)
            out[t[:-1]] = (w, h, ax, ay, sag, ctrl)
    missing = [n for n in FRAMES + TALK_FRAMES + LANT_FRAMES if n not in out]
    if missing:
        raise SystemExit(f"{TBL.name} lacks {', '.join(missing)} - run python build.py")
    return out


def verify(imgs, tbl, limgs):
    name, s, e = PACK
    start, payload = court.wolf_irw(name)
    start += RELOC
    if start != s:
        raise SystemExit(f"{name}.IRW is based at {start:X}, the tool says {s:X}")
    if start + len(payload) > e:
        raise SystemExit(f"{name}.IRW runs to {start + len(payload):X}, past its slot end {e:X}")
    bad = []
    for n in FRAMES + TALK_FRAMES + LANT_FRAMES:
        w, h, ax, ay, sag, ctrl = tbl[n]
        im = imgs[n] if n in imgs else limgs[n]
        if (w, h, ax, ay) != (im["w"], im["h"], im["ax"], im["ay"]):
            bad.append(f"{n}: header {w}x{h} @{ax},{ay} is not the IMG's")
            continue
        p = cave.sag_phys(sag)
        if not s <= p < e:
            bad.append(f"{n}: SAG {sag:08X} outside the slot")
            continue
        try:
            rows, _b = pit.decode_record(payload, pit.runtime_bit(sag) - start * 8, w, h, ctrl)
        except IndexError:
            bad.append(f"{n} runs off {name}.IRW")
            continue
        got = bytes(v for r in rows for v in r)
        diff = sum(1 for a, b in zip(got, im["px"]) if a != b)
        if diff:
            bad.append(f"{n}: {diff} pixels differ from its library")
    if bad:
        raise SystemExit("THE PIT III Kahn pack is not its libraries' art:\n  " + "\n  ".join(bad))
    return start + len(payload)


def build_asm(imgs, tbl, used_end, limgs, lpal):
    h4 = court.h4
    r = imgs[REST]
    leg = imgs[LEG]
    o = []
    w = o.append
    w("; SHAO KAHN ON HIS THRONE, THE PIT III - GENERATED by tools/make_pit3kahn.py --apply.")
    w("; Do not hand-edit.  Art: data/NEWSHAO.IMG via data/UP3KN.LOD; the SAGs are")
    w("; LOAD2's tmp/load2/UP3KN.TBL moved up by WOLF_RELOCATE (+2000000h bits).")
    w("; Included only under .if wunit (src/UMK3PIT3.ASM) - Wolf-only art.")
    w(f"; Pack 0x{PACK[1]:X}..0x{used_end:X} of a slot to 0x{PACK[2]:X}.")
    w("; The green lanterns (UP3LANT.IMG, out of MKBGANI2.IMG) share the pack.")
    w("")
    w(f"up3k_x\t\t.set\t{KAHN_X}\t\t; his anchor, plane-1 world x")
    w(f"up3k_y\t\t.set\t{KAHN_Y}\t\t; ... and world y")
    # flip_single (MKUTIL) mirrors a single-part object IN PLACE: ani0 reads
    # the old and the new anipoint under the same, already-toggled flag, so
    # oxpos does not move.  So the FLIPPED top-left is what gets written, and
    # the anchor of a flipped frame is its top-left + (w-1-anix) - the rule
    # ani_flag then holds for every gesture frame, and the one --preview draws.
    # (The first cut wrote the UNFLIPPED top-left, expecting a pivot about the
    # anchor: in game the torso sat 13px left of the composite and the shin
    # hung 55px to the right of where it was drawn here, behind his back.)
    w(f"up3k_rest_x\t.set\t{KAHN_X - (r['w'] - 1 - r['ax'])}\t\t; {REST}'s top-left, FLIPPED -")
    w(f"up3k_rest_y\t.set\t{KAHN_Y - r['ay']}\t\t;   flip_single mirrors it in place")
    w(f"up3k_leg_x\t.set\t{KAHN_X - (leg['w'] - 1 - leg['ax']) + LEG_DX}\t\t; {LEG}'s, the same way, moved")
    w(f"up3k_leg_y\t.set\t{KAHN_Y - leg['ay'] + LEG_DY}\t\t;   LEG_DX/LEG_DY onto the seat front")
    tl = imgs[TALKLEG]
    w(f"up3k_rise_dx\t.set\t{RISE_DX}\t\t; the rise and the point, off his seated anchor -")
    w(f"up3k_rise_dy\t.set\t{RISE_DY}\t\t;   the leg carries on from the kneeling shin")
    w(f"up3k_tleg_x\t.set\t{KAHN_X - (tl['w'] - 1 - tl['ax']) + RISE_DX}\t\t; {TALKLEG}'s top-left, FLIPPED, on")
    w(f"up3k_tleg_y\t.set\t{KAHN_Y - tl['ay'] + RISE_DY}\t\t;   the risen anchor - the legs he stands on")
    w(f"up3k_hide_y\t.set\t-400\t\t; the shin, parked above the world while he stands")
    w(f"up3k_ptick\t.set\t{POINT_HOLD}\t\t; ticks on BGTALK5 after the line")
    domes, cups = lantern_layout(limgs)
    w("")
    w(f"up3l_ticks\t.set\t{DOME_TICKS}\t\t; a dome frame's hold")
    for k, (f, x, y) in enumerate(domes):
        w(f"up3l_d{k + 1}_cx\t.set\t{x}\t\t; dome {k + 1}: its centre column, plane 3")
        w(f"up3l_d{k + 1}_x\t.set\t{x + dome_dx(limgs, f)}\t\t;   {f}'s drawn top-left")
        w(f"up3l_d{k + 1}_y\t.set\t{y}")
    w(f"up3l_scale\t.set\t0{DOME_SCALE:x}000{DOME_SCALE:x}00h\t; oscale: drawn at 1/{DOME_SCALE}")
    for k, (ax, bx, y) in enumerate(cups):
        w(f"up3l_c{k + 1}a_x\t.set\t{ax}\t\t; lantern {k + 1}'s cage: LANTRNA's drawn top-left,")
        w(f"up3l_c{k + 1}b_x\t.set\t{bx}\t\t;   LANTRNB's beside it, plane 3")
        w(f"up3l_c{k + 1}_y\t.set\t{y}")
    w("")
    w("\t.data")
    w("")
    for n in FRAMES + TALK_FRAMES:
        fw, fh, ax, ay, sag, ctrl = tbl[n]
        w(f"{lab(n)}:")
        w(f"\t.word\t{fw},{fh},{ax},{ay}")
        w(f"\t.long\t{h4(sag, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
        w(f"\t.long\t{PAL}")
    for n in LANT_FRAMES:
        fw, fh, ax, ay, sag, ctrl = tbl[n]
        w(f"{n}:")
        w(f"\t.word\t{fw},{fh},{ax},{ay}")
        w(f"\t.long\t{h4(sag, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
        w(f"\t.long\t{LANT_PAL}")
    w("")
    w(f"{LANT_PAL}:\t\t\t\t; MKBGANI2.IMG's {LANT_SRC_PAL}")
    w(f"\t.word\t{len(lpal)}")
    for i in range(0, len(lpal), 8):
        w("\t.word\t" + ",".join(h4(v, 5) for v in lpal[i:i + 8]))
    w("")
    w("; the dome's spin: .long frame / .long its drawn top-left off the centre")
    w("; column (dome_dx in the tool), ended by a 0 long (up3l_proc loops it)")
    w("up3l_spin")
    for n in DOME:
        w(f"\t.long\t{n},{dome_dx(limgs, n)}")
    w("\t.long\t0")
    w("")
    w("; the gestures: .long frame / .word ticks, ended by a 0 long.  Each runs from")
    w(f"; the rest pose ({REST}) and up3k_play puts him back on it.")
    for g, steps in GESTURES.items():
        w(f"up3k_{g}")
        for n, t in steps:
            w(f"\t.long\t{lab(n)}")
            w(f"\t.word\t{t}")
        w("\t.long\t0")
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


def preview(imgs, pal, cams):
    import make_umk3stages as T
    from PIL import Image, ImageDraw
    L = T.layout("pit3")
    cams = cams or [801]

    def rgb(v):
        return ((v >> 10 & 31) * 255 // 31, (v >> 5 & 31) * 255 // 31, (v & 31) * 255 // 31)

    poses = [REST, "SHATAUNT4", CACKLE[-1], "SHAFISTS5"]
    shots = []
    for cam in cams:
        for pose in poses:
            scr = T.render(L, cam)
            px = scr.load()
            for n in (pose, LEG):
                im = imgs[n]
                fw = im["w"]
                dx, dy = (LEG_DX, LEG_DY) if n == LEG else (0, 0)
                left = KAHN_X - cam - (fw - 1 - im["ax"]) + dx  # ganiof, flipped
                top = KAHN_Y - im["ay"] + dy
                for y in range(im["h"]):
                    for x in range(fw):
                        c = im["px"][y * fw + x]
                        tx, ty = left + (fw - 1 - x), top + y
                        if c and 0 <= tx < 400 and 0 <= ty < 254:
                            px[tx, ty] = rgb(pal[c])
            ImageDraw.Draw(scr).text((4, 2), f"camera {cam}  {pose}", fill=(255, 255, 0))
            shots.append(scr)
    sheet = Image.new("RGB", (400 * len(poses), 254 * len(cams)))
    for k, s in enumerate(shots):
        sheet.paste(s, ((k % len(poses)) * 400, (k // len(poses)) * 254))
    out = ROOT / "tmp" / "pit3kahn"
    out.mkdir(parents=True, exist_ok=True)
    sheet.save(out / "preview.png")
    print(f"wrote {out / 'preview.png'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parts", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--preview", nargs="*", type=int, metavar="CAMX")
    a = ap.parse_args()
    if not any((a.parts, a.apply, a.check, a.preview is not None)):
        ap.error("one of --parts / --apply / --check / --preview")
    imgs, pal = read_newshao()
    imgs.update(read_talk(pal))
    lod = lod_text().encode()
    lod_path = DATA / f"{PACK[0]}.LOD"
    if a.parts:
        lod_path.write_bytes(lod)
        print(f"wrote data/{lod_path.name}")
        LANT_IMG.write_bytes(lantern_img_bytes())
        print(f"wrote data/{LANT_IMG.name}  ({len(LANT_FRAMES)} records + {LANT_SRC_PAL})")
    if a.preview is not None:
        preview(imgs, pal, a.preview)
    if a.apply or a.check:
        tbl = read_tbl()
        limgs, lpal = read_lanterns()
        end = verify(imgs, tbl, limgs)
        asm = build_asm(imgs, tbl, end, limgs, lpal)
        if a.apply:
            OUT_ASM.write_text(asm, encoding="latin-1")
            print(f"wrote src/{OUT_ASM.name}  ({len(FRAMES) + len(TALK_FRAMES) + len(LANT_FRAMES)} frames, pack to 0x{end:X})")
        if a.check:
            drift = []
            if rise_shin(imgs) != RISE_SHIN:
                drift.append(f"SHAGETUP1's shin lies {rise_shin(imgs)} off SHASITLEG, the tool says {RISE_SHIN}")
            if not lod_path.exists() or lod_path.read_bytes() != lod:
                drift.append(f"data/{lod_path.name} is not the tool's - rerun --parts")
            if not OUT_ASM.exists() or OUT_ASM.read_text(encoding="latin-1") != asm:
                drift.append(f"src/{OUT_ASM.name} has drifted - rerun --apply")
            if LANT_SRC.exists() and LANT_IMG.read_bytes() != lantern_img_bytes():
                drift.append(f"data/{LANT_IMG.name} is not {LANT_SRC.name}'s lanterns - rerun --parts")
            if drift:
                raise SystemExit("THE PIT III Kahn check FAILED:\n  " + "\n  ".join(drift))
            print(f"THE PIT III Kahn + lanterns: {len(FRAMES) + len(TALK_FRAMES) + len(LANT_FRAMES)} frames packed, "
                  f"decoded identical to NEWSHAO.IMG / {LANT_IMG.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
