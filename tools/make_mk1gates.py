#!/usr/bin/env python3
r"""PALACE GATES - MK1's second stage, as a WOLF-ONLY MK2 stage (curback 01Eh).

The great seated Buddha, the stone lions, the pagoda behind the wall and the
red dragon banners, with torches burning on the pillars at each end of the stage
and clouds drifting across the sky.  Code is src/MK1GATE.ASM; everything it is
built from is generated into src/MK1GTB.ASM by this tool, out of one source:

  C:\\MAME\\roms\\mk.zip    MK1 rev 5.0.  Stage table FFCA7E30, entry 1 =
                         FFCB9ED0 is PALACE GATES.

(The leak's KUNGFU4 has MK1's module layout, but the ROM is what ships, so the
art is decoded from it as THE COURTYARD's is - doc/MK1_COURTYARD_GATES.md.)

TWO KINDS OF ANIMATION, both read out of MK1's code (FFCBA130 creates them):

  FLAME  FFCBABC0, every 4 ticks: any BLOCK OBJECT whose ID - the high byte of
         its block flags - is 2, 3 or 4 steps through an 8-frame table
         (FFCBB110 / B210 / B310).  On this stage those are the TORCH FLAMES on
         the pillars at both ends: two ID-2 columns and one ID-3 on plane 2, one
         ID-4 (the big one by the gatehouse) on plane 1.  MK1's frame swap (FFC806E0) keeps the ANCHOR still:
         anchor = position + anix, or + (w-1-anix) when the object is
         H-flipped (FFC80D10) - and the first swap starts from a stand-in
         record (FFC864D0) whose anipoint is 0, so the anchor is the block's
         top-left, or its top-right when flipped.  MEASURED: the ID-2 column
         at block (218,56) drew at y 54 on a frame with aniy 2, 60 on aniy -4.
         An MK2 block never animates, and MK2's streamer (disp_del, BAKGND)
         deletes any object on a module's baklst once it leaves the window -
         so these blocks, and the torch cups (ID 1) that sit with them,
         come OUT of the modules and are built as objects on a list of their
         own per plane, drawn just behind that plane's blocks (MK1 sorts on
         that ID, and every module block is 3Eh or above).  The generator
         works out every frame's world top-left, so the stage code only swaps
         art and puts it there.
  CLOUDS FFCBA240: three clouds, two piece lists (FFCBA9E0, 3 pieces; FFCBAA60,
         4 pieces), anchored at screen x 15h / C5h / 185h, y 25h, drifting at
         8000h (half a pixel a tick); every 8 ticks any piece past screen x
         18Fh moves back 23Fh.  Each piece wraps on its own, so a cloud
         reassembles behind the left edge.  MK1 draws them on a plane with no
         module behind everything; here they ride plane 8 (rate 0) and the
         wrap is measured against its camera.

WOLF ONLY - art above the T-unit's 12 MB, module under `.if wunit`.

  --parts / --apply / --check / --report / --preview  as make_mk1court.py
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave      # noqa: E402
import make_mk1pit as pit        # noqa: E402
import make_mk1shrine as shrine  # noqa: E402
import make_mk1throne as thr     # noqa: E402
import make_mk1court as court    # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "MK1GTB.ASM"
SPR_IMG = DATA / "MK1GATMK.IMG"
SPR_TBL = SRC / "MK1GTM.TBL"
SCREEN_W, SCREEN_H = 400, 254

# Wolf video ROM, linear, after THE COURTYARD's (which ends at 0xC1C000)
PACKS = [
    # name      start       end         ppp
    ("MK1GT1", 0xC1C000, 0xC3C000, 0),   # 128 KB - the stage blocks (~99 KB packed)
    ("MK1GT2", 0xC3C000, 0xC40000, 8),   # 16 KB - blocks with a deeper last pixel
]                                        #   (none today, so no LOD is written)
SPR_PACK = ("MK1GTM", 0xC40000, 0xC50000)   # 64 KB - flames, torch cups, clouds
SPR_PPP = 6
PACK_MARGIN = 0.90

GATE_ENTRY = 1
GATE_MOD = 0xFFCB9ED0
GATE_CALLA = 0xFFCBA130
CALLA_CODE = [0x09C1, 0x2000, 0x09E7, 0xA240, 0xFFCB, 0x0D5F, 0x2810, 0xFFCE,
              0x09C1, 0x2000, 0x09E7, 0xABC0, 0xFFCB, 0x0D5F, 0x2810, 0xFFCE, 0x0960]
NAME_STR = b"PALACE GATES\0"
# (address, words) the generator's numbers come from - MAME's disassembler
CODE_CHECKS = {
    0xFFCBA240: [0x09CB, 0x0025],                  # MOVI 25h,A11  - cloud y
    0xFFCBA260: [0x09C7, 0x0015],                  # MOVI 15h,A7   - cloud 1 x
    0xFFCBA2B0: [0x09E5, 0xA9E0, 0xFFCB],          # MOVI FFCBA9E0h,A5
    0xFFCBA370: [0x09C7, 0x00C5],                  # MOVI C5h,A7   - cloud 2 x
    0xFFCBA3C0: [0x09E5, 0xAA60, 0xFFCB],          # MOVI FFCBAA60h,A5
    0xFFCBA440: [0x09C7, 0x0185],                  # MOVI 185h,A7  - cloud 3 x
    0xFFCBA490: [0x09E5, 0xA9E0, 0xFFCB],
    0xFFCBA520: [0x09E0, 0x8000, 0x0000],          # MOVI 8000h,A0 - x velocity
    0xFFCBA600: [0x09C0, 0x0008],                  # MOVI 8h,A0    - wrap check rate
    0xFFCBA680: [0x0B42, 0xFE70],                  # CMPI 18Fh,A2  - wrap past 399
    0xFFCBA700: [0x09C0, 0x023F],                  # MOVI 23Fh,A0 / NEG - back 575
    0xFFCBABC0: [0x09C0, 0x0004],                  # MOVI 4h,A0    - flame rate
    0xFFCBAC40: [0x1907],                          # MOVK 8h,A7    - 8 frames
    0xFFCBAC50: [0x09CB, 0x0004, 0x09E9, 0xB310, 0xFFCB],
    0xFFCBAD00: [0x09CB, 0x0003, 0x09E9, 0xB210, 0xFFCB],
    0xFFCBADB0: [0x09CB, 0x0002, 0x09E9, 0xB110, 0xFFCB],
}
CLOUD_Y = 0x25
CLOUDS = [(0x15, 0xFFCBA9E0), (0xC5, 0xFFCBAA60), (0x185, 0xFFCBA9E0)]
CLOUD_VEL = 0x8000
CLOUD_WRAP, CLOUD_BACK, CLOUD_RATE = 0x18F, 0x23F, 8
CLOUD_PAL = 0xFFEA8D10            # the .long after FFE98360, the group's first record
FLAME_TABS = {2: 0xFFCBB110, 3: 0xFFCBB210, 4: 0xFFCBB310}
FLAME_N, FLAME_RATE = 8, 4
PIECE_ID_MAX = 0x0F               # block ID (flags >> 8) below this = a piece

GROUND_NUDGE = -6
SHADOW_FAST = 2
PAL_PREFIX = "MK1GT_P"
SPR_PAL = "MK1GTS%02d_P"          # a module palette, as a sprite palette
CLD_PAL = "MK1GTCLD_P"
PLANE_NOTE = {                    # each plane rendered alone (tmp/mk1gates/planes.png)
    1: "the stone arch (left end) and the gatehouse (right end)",
    2: "the torch pillars at both ends",
    3: "the wall, the lions, the Buddha, the banners, a spear guard and the paving",
    4: "the trees",
    5: "the pagoda",
    6: "the mountains - rate 0, they never scroll",
}

LOD_BBB = court.LOD_BBB.replace("THE COURTYARD (MK1)", "PALACE GATES (MK1)") \
    .replace("make_mk1court.py", "make_mk1gates.py").replace("FFCBB410", "FFCB9ED0") \
    .replace(";  The leak's KUNGFU2 is a pre-release Courtyard, not this one.\n", "") \
    .replace("(src/MK1CRTB.ASM)", "(src/MK1GTB.ASM)")

LOD_SPR = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  PALACE GATES (MK1), WOLF ONLY - THE TORCH FLAMES AND THE
;  CLOUDS (linear 0x{start:06X}..0x{end:06X})
;
;  data/MK1GATMK.IMG is GENERATED by tools/make_mk1gates.py --parts out
;  of mk.zip: MK1's three flame tables (8 frames each), the torch
;  cups (blocks with ID 1) and the seven cloud pieces.  PON>: built
;  with gso_dmawnz, which reads the palette off the record; the
;  palettes are carried in src/MK1GTB.ASM.
;
;**************************************************************
PON>
ZON>
PPP> {ppp}
ASM> MK1GTM.TBL
MK1GATMK.IMG
{recs}
"""


# --------------------------------------------------------------------------
# MK1
# --------------------------------------------------------------------------
def block_id(b):
    return b[0] >> 8


def read_mk1(rom):
    if rom.l(pit.MK1_STAGES + GATE_ENTRY * 32) != GATE_MOD:
        raise SystemExit(f"MK1 stage table entry {GATE_ENTRY} is not {GATE_MOD:08X}")
    nm = rom.l(thr.NAME_TABLE + GATE_ENTRY * 32)
    o = (nm - pit.BASE) // 8
    if bytes(rom.p[o:o + len(NAME_STR)]) != NAME_STR:
        raise SystemExit(f"MK1 stage {GATE_ENTRY} is not named {NAME_STR!r}")
    m = GATE_MOD
    rec = dict(erase=rom.w(m), ground=rom.w(m + 16), worldy=rom.sw(m + 32),
               start=rom.w(m + 48), left=rom.w(m + 64), right=rom.w(m + 80),
               calla=rom.l(m + 96), scroll=rom.l(m + 128), bakmods=rom.l(m + 160))
    if rec["calla"] != GATE_CALLA or \
       [rom.w(GATE_CALLA + 16 * i) for i in range(len(CALLA_CODE))] != CALLA_CODE:
        raise SystemExit(f"{GATE_CALLA:08X} is no longer MK1's two-process gates calla")
    for at, words in list(CODE_CHECKS.items()) + list(shrine.SCROLL_CODE.items()):
        if [rom.w(at + 16 * i) for i in range(len(words))] != words:
            raise SystemExit(f"MK1 code at {at:08X} is not what this import was read from")
    # PALACE GATES' bakmods names plane-table entry 0, not 1 (THE PIT's does
    # too): MK2's baklst N carries MK1 plane N-1, so every rate is read one
    # table entry along from THE COURTYARD's.
    planes = [rom.l(shrine.PLANE_TABLE + 160 * e + 96) for e in range(9)]
    rec["first"] = planes.index(rec["bakmods"])
    if rec["first"] != 0:
        raise SystemExit(f"palace gates starts on MK1's plane {rec['first']}, not 0")
    mods = thr._placements(rom, GATE_MOD)
    if [md["plane"] for md in mods] != list(range(1, 7)):
        raise SystemExit(f"palace gates' planes are {[md['plane'] for md in mods]}, not 1..6")
    if len({(md["hdrs"], md["pals"]) for md in mods}) != 1:
        raise SystemExit("palace gates' modules no longer share one header table")
    for md in mods:
        md["rate"] = mk1_rate(rom, rec, md["plane"])
    return rec, mods


def mk1_rate(rom, rec, mk2plane):
    """MK1's scroll rate for the plane MK2 draws as baklst<mk2plane>."""
    e = mk2plane - 1 + rec["first"]
    return rom.l(rec["scroll"] + 32 * (8 - e)) if 0 <= e <= 8 else 0


def bg_image(rom, md, b):
    a = md["hdrs"] + 80 * (b[3] & 0xFFF)
    w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
    rows, _ = pit.decode_record(rom.g, sag - pit.IROM, w, h, ctrl)
    return dict(w=w, h=h, ax=0, ay=0, px=bytes(v for r in rows for v in r))


def pieces(rom, mods):
    """Every block with an ID under 10h: [dict(plane, id, flip, frames=[(rec name,
    world x, world y)], z)] plus the sprite records and palettes they need."""
    recs, out = {}, []                # name -> (image, palette label)

    def pal(p):
        return SPR_PAL % p, rom.palette(rom.l(mods[0]["pals"] + 32 * p))

    pals = {}
    for md in mods:
        for b in md["blks"]:
            i = block_id(b)
            if i > PIECE_ID_MAX:
                continue
            flags, bx, by, hw = b
            flip = bool(flags & 0x10)
            wx, wy = md["x"] + bx, md["y"] + by
            plab, words = pal(thr.pal_of(b))
            pals[plab] = words
            if i in FLAME_TABS:
                tab = FLAME_TABS[i]
                frames = []
                bw = bg_image(rom, md, b)["w"]
                # the anchor: MK1's first swap starts from FFC864D0, anipoint 0
                ax = wx + (bw - 1 if flip else 0)
                for k in range(FLAME_N):
                    ra = rom.l(tab + 32 * k)
                    nm = f"GTFLM{i}_{k + 1}"
                    im = rom.image(ra)
                    if max(im["px"]) >= len(words):
                        raise SystemExit(f"{nm} indexes {max(im['px'])}, palette has {len(words)}")
                    recs.setdefault(nm, (im, plab))
                    off = (im["w"] - 1 - im["ax"]) if flip else im["ax"]
                    frames.append((nm, ax - off, wy - im["ay"]))
            elif i == 1:
                im = bg_image(rom, md, b)
                nm = f"GTBASE{len([r for r in recs if r.startswith('GTBASE')]) + 1}"
                recs[nm] = (im, plab)
                frames = [(nm, wx, wy)]
            else:
                raise SystemExit(f"block ID {i} at ({wx},{wy}) - MK1's process does not "
                                 "animate it and this import does not know what it is")
            out.append(dict(plane=md["plane"], id=i, flip=flip, frames=frames, z=i))
    return out, recs, pals


def clouds(rom):
    recs, out = {}, []
    words = rom.palette(CLOUD_PAL)
    for cx, lst in CLOUDS:
        for a in rom.piece_list(lst):
            im = rom.image(a)
            if max(im["px"]) >= len(words):
                raise SystemExit(f"cloud piece {a:08X} indexes past {CLD_PAL}")
            nm = recs.get(a, (None,))[0] or f"GTCLD{len(recs) + 1}"
            recs[a] = (nm, im)
            out.append((nm, cx - im["ax"], CLOUD_Y - im["ay"]))
    return out, {nm: (im, CLD_PAL) for nm, im in recs.values()}, words


def layout():
    rom = pit.MK1()
    rec, allmods = read_mk1(rom)
    pcs, precs, ppals = pieces(rom, allmods)
    mods = []
    for md in allmods:
        m2 = dict(md)
        m2["blks"] = [b for b in md["blks"] if block_id(b) > PIECE_ID_MAX]
        mods.append(m2)
    imgs, order, uniq, pals, remap, share = thr.art(rom, mods)
    pals = [(f"{PAL_PREFIX}{k:02d}", w, p) for k, (_l, w, p) in enumerate(pals)]
    cl, crecs, cwords = clouds(rom)
    sprites = dict(precs)
    sprites.update(crecs)
    spals = dict(ppals)
    spals[CLD_PAL] = cwords
    return dict(rom=rom, rec=rec, mods=mods, allmods=allmods, imgs=imgs, order=order,
                uniq=uniq, pals=pals, remap=remap, share=share, pieces=pcs, clouds=cl,
                sprites=sprites, spals=spals)


def ground_y(L):
    return L["rec"]["ground"] + GROUND_NUDGE


def rec_scroll(L, plane):
    return mk1_rate(L["rom"], L["rec"], plane)


# --------------------------------------------------------------------------
# Packs
# --------------------------------------------------------------------------
def deal(L):
    imgs = L["imgs"]
    cap = [int((e - s) * 8 * PACK_MARGIN) for _n, s, e, _p in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(L["uniq"], key=lambda i: (-cave.packed_bits(imgs[i]), i)):
        im = imgs[idx]
        want = 8 if court.wide_tail(im) else 0
        bits = im["w"] * im["h"] * 8 if want else cave.packed_bits(im)
        for k, (_n, _s, _e, ppp) in enumerate(PACKS):
            if ppp == want and used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    return [sorted(g) for g in got], used


def spr_order(L):
    return sorted(L["sprites"], key=lambda n: (n[:6], len(n), n))


def part_files(L):
    imgs = L["imgs"]
    groups, _ = deal(L)
    files = {}
    for (name, s, e, ppp), group in zip(PACKS, groups):
        if not group:
            continue
        bdd = bytearray(b"%d\n" % len(group))
        for idx in group:
            im = imgs[idx]
            bdd += b"%x %d %d %d\n" % (idx, im["w"], im["h"], im["big"])
            bdd += im["px"]
        for label, words, _p in L["pals"]:
            bdd += b"%s %d\n" % (label.encode(), len(words))
            bdd += struct.pack("<%dH" % len(words), *words)
        x, lines = 0, []
        for idx in group:
            lines.append("4000 %d 0 %X 0" % (x, idx))
            x += imgs[idx]["w"] + 4
        hmax = max(imgs[i]["h"] for i in group)
        bdb = [f"{name} {max(x, 1)} {hmax} 255 1 {len(L['pals'])} {len(group)}",
               f"{name} 0 {max(x - 5, 0)} 0 {hmax - 1}"] + lines
        files[f"{name}.BDD"] = bytes(bdd)
        files[f"{name}.BDB"] = ("\n".join(bdb) + "\n").encode()
        why = ("per-block auto depth, as every BBB> in MK7MIL" if ppp == 0 else
               "LOAD2's auto depth ignores a block's LAST pixel and spills it into the "
               "next record; these blocks' last pixel needs more bits than the rest")
        files[f"{name}.LOD"] = LOD_BBB.format(addr=court.lod_addr(s), n=name[-1], start=s,
                                              end=e, name=name, ppp=ppp, why=why).encode()
    # the sprite pack
    pnames = list(L["spals"])
    names = spr_order(L)
    entries = []
    for nm in names:
        im, plab = L["sprites"][nm]
        entries.append((nm, im["ax"], im["ay"], im["w"], im["h"], im["px"], pnames.index(plab)))
    pl = [(p, cave._bpp(max(max(L["sprites"][n][0]["px"]) for n in names
                            if L["sprites"][n][1] == p)), L["spals"][p]) for p in pnames]
    files[SPR_IMG.name] = pit.build_img(entries, pl)
    name, s, e = SPR_PACK
    bits = sum(cave.packed_bits(L["sprites"][n][0]) for n in names)
    if bits > (e - s) * 8 * PACK_MARGIN:
        raise SystemExit(f"the sprites (~{bits // 8} B) do not fit {name}")
    files[f"{name}.LOD"] = LOD_SPR.format(addr=court.lod_addr(s), start=s, end=e,
                                          ppp=SPR_PPP,
                                          recs=chr(10).join("---> " + ",".join(names[i:i + 8])
                                                          for i in range(0, len(names), 8))).encode()
    return files


# --------------------------------------------------------------------------
# --apply
# --------------------------------------------------------------------------
def merged_headers(L):
    imgs = L["imgs"]
    groups, _ = deal(L)
    by = {}
    for (name, start, end, _p), group in zip(PACKS, groups):
        if not group:
            continue
        snap = LOAD2 / f"BGNDTBL.{name[-3:]}"
        if not snap.exists():
            raise SystemExit(f"{snap} missing - run python build.py")
        hdrs = cave.read_hdrs(snap)
        if len(hdrs) != len(group):
            raise SystemExit(f"{snap}: {len(hdrs)} headers, pack has {len(group)} images")
        for idx, (w, h, addr, ctrl) in zip(group, hdrs):
            im = imgs[idx]
            if (w, h) != (im["w"], im["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}, MK1 says {im['w']}x{im['h']}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} outside {start:X}..{end:X}")
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
    for i, j in L["share"].items():
        w, h, addr, ctrl, src = by[j]
        by[i] = (w, h, addr, ctrl, f"{src} (MK1 shares one SAG with {j:02X})")
    return [by[i] for i in L["order"]]


def spr_tbl():
    if not SPR_TBL.exists():
        raise SystemExit(f"{SPR_TBL} missing - run python build.py")
    out, lines = {}, SPR_TBL.read_text(encoding="latin-1").splitlines()
    for i, ln in enumerate(lines):
        t = ln.strip()
        if t.endswith(":") and t.startswith("GT"):
            w, h, _ax, _ay = (int(v, 0) for v in lines[i + 1].split(None, 1)[1].split(","))
            sag = int(lines[i + 2].split()[1].rstrip("Hh"), 16)
            ctrl = int(lines[i + 3].split()[1].rstrip("Hh"), 16)
            out[t[:-1]] = (w, h, sag, ctrl)
    return out


def decode_at(addr, w, h, ctrl):
    p = cave.sag_phys(addr)
    for name, *_r in PACKS + [SPR_PACK]:
        if not (DATA / f"{name}.IRW").exists():
            continue
        start, payload = court.wolf_irw(name)
        if start <= p < start + len(payload):
            rows, _b = pit.decode_record(payload, pit.runtime_bit(addr) - start * 8, w, h, ctrl)
            return name, bytes(v for r in rows for v in r), start + len(payload)
    raise SystemExit(f"SAG {addr:08X} (linear {p:X}) is in no written Wolf pack")


def verify_rom(L, hdrs):
    bad = []
    for name, s, e, *_r in PACKS + [SPR_PACK]:
        if (DATA / f"{name}.IRW").exists():
            start, payload = court.wolf_irw(name)
            if start != s or start + len(payload) > e:
                bad.append(f"{name}: payload {start:X}..{start + len(payload):X} outside {s:X}..{e:X}")
    for idx, (w, h, addr, ctrl, src) in zip(L["order"], hdrs):
        try:
            name, px, _end = decode_at(addr, w, h, ctrl)
        except IndexError:
            bad.append(f"MK1 {idx:02X} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, L["imgs"][idx]["px"]) if a != b)
        if n:
            bad.append(f"{name}: MK1 {idx:02X} ({w}x{h}, {src}) - {n} pixels differ from mk.zip")
    tbl = spr_tbl()
    for nm, (im, _p) in L["sprites"].items():
        if nm not in tbl:
            bad.append(f"{nm} is not in {SPR_TBL.name}")
            continue
        w, h, sag, ctrl = tbl[nm]
        try:
            name, px, _end = decode_at(sag, w, h, ctrl)
        except IndexError:
            bad.append(f"{nm} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, im["px"]) if a != b)
        if (w, h) != (im["w"], im["h"]) or n:
            bad.append(f"{name}: {nm} - {n} pixels differ from mk.zip")
    return bad


def build_asm(L, hdrs):
    rec, mods = L["rec"], L["mods"]
    h4 = court.h4
    o = []
    w = o.append
    w("; PALACE GATES (MK1) - GENERATED by tools/make_mk1gates.py --apply.  Do not hand-edit.")
    w("; Art and layout: MK1's stage record FFCB9ED0 (C:\\MAME\\roms\\mk.zip), read by the tool.")
    w("; Included only under .if wunit (src/MK1GATE.ASM) - Wolf-only art.")
    w("")
    w(f"mk1g_erase\t.set\t{h4(rec['erase'])}")
    w(f"mk1g_ground\t.set\t{ground_y(L)}\t\t; MK1's {rec['ground']} {GROUND_NUDGE:+d}")
    w(f"mk1g_worldy\t.set\t{rec['worldy']}")
    w(f"mk1g_start\t.set\t{rec['start']}")
    w(f"mk1g_left\t.set\t{rec['left']}")
    w(f"mk1g_right\t.set\t{rec['right']}")
    w(f"mk1g_shad_fast\t.set\t{SHADOW_FAST}")
    for e in range(9):
        w(f"mk1g_rate{e}\t.set\t{h4(rec_scroll(L, e), 6)}\t\t; plane {e}"
          + (f" - {PLANE_NOTE[e]}" if e in PLANE_NOTE else ""))
    for md in mods:
        n = md["plane"]
        w(f"mk1g_m{n}_x\t.set\t{md['x']}\t\t; plane {n} - {PLANE_NOTE[n]}")
        w(f"mk1g_m{n}_y\t.set\t{md['y']}")
    w(f"mk1g_flm_rate\t.set\t{FLAME_RATE}\t\t; MK1 FFCBABC0: MOVI 4h,A0 - ticks a flame frame")
    w(f"mk1g_flm_n\t.set\t{FLAME_N}\t\t; MOVK 8h,A7 - frames a flame table")
    w(f"mk1g_cld_vel\t.set\t{h4(CLOUD_VEL, 6)}\t\t; MOVI 8000h,A0 - half a pixel a tick")
    w(f"mk1g_cld_wrap\t.set\t{CLOUD_WRAP}\t\t; CMPI 18Fh,A2 - past screen x 399...")
    w(f"mk1g_cld_back\t.set\t{CLOUD_BACK}\t\t; MOVI 23Fh,A0 / NEG - ...back 575")
    w(f"mk1g_cld_n\t.set\t{len(L['clouds'])}\t\t; cloud pieces")
    w(f"mk1g_pc_n\t.set\t{len(L['pieces'])}\t\t; flame + torch-cup pieces")
    w("")
    w("\t.data")
    w("")
    w("MK1GTHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["order"]):
        w(f"\t.word\t{hw},{hh}\t\t; MK1 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["order"])}
    for md in mods:
        lab = "MK1GT%d" % md["plane"]
        w(f"{lab}BLKS:\t\t\t\t; {PLANE_NOTE[md['plane']]}")
        for blk in md["blks"]:
            f, bx, by, hw = blk
            np = L["remap"][thr.pal_of(blk)]
            w("\t.word\t%s,%d,%d,%s" % (h4((f & 0xFFF0) | (np & 0xF)), bx, by,
                                        h4(hidx[hw & 0xFFF] + ((np >> 4) << 12))))
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{md['w']},{md['h']},{len(md['blks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, MK1GTHDRS, MK1GTPALS")
        w("")
    w("MK1GTPALS:")
    for label, _words, p in L["pals"]:
        w(f"\t.long\t{label}\t\t; MK1 palette {p}")
    w("")
    for label, words in [(lb, wd) for lb, wd, _p in L["pals"]] + list(L["spals"].items()):
        w(f"{label}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    w("")
    w("; THE TORCH FLAMES - blocks MK1 gives an ID under 10h, built as")
    w("; objects.  Per piece: .word frames, flip, z / .long its list, then per")
    w("; frame .long record / .word world x, y (the top-left, worked out from")
    w("; MK1's anchor rule by the tool).  0 ends it.")
    w("mk1g_pieces:")
    for pc in L["pieces"]:
        lst = "mk1g_pl%d_lst" % pc["plane"]
        w(f"\t.word\t{len(pc['frames'])},{int(pc['flip'])},{pc['z']}\t; plane {pc['plane']}, "
          f"ID {pc['id']}" + (" - flipped" if pc["flip"] else ""))
        w(f"\t.long\t{lst}")
        for nm, x, y in pc["frames"]:
            w(f"\t.long\t{nm}")
            w(f"\t.word\t{x},{y}")
    w("\t.word\t0")
    w("")
    w("; THE CLOUDS - .long record / .word SCREEN x, y at the start (MK1's anchor")
    w("; minus the piece's anipoint).  The stage adds plane 8's camera.")
    w("mk1g_clouds:")
    for nm, x, y in L["clouds"]:
        w(f"\t.long\t{nm}")
        w(f"\t.word\t{x},{y}")
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------
def plane_x(L, cam):
    s = L["rec"]["start"]
    return {e: s + (cam - s) * rec_scroll(L, e) // 0x20000 for e in range(9)}


def render(L, cam, tick=0, planes=None):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cam_y = rec["worldy"]
    px_x = plane_x(L, cam)
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), court.rgb(rec["erase"]))
    px = scr.load()

    def put(im, ox, oy, pal, flip=False):
        w, h = im["w"], im["h"]
        for y in range(h):
            ty = oy + y
            if not 0 <= ty < SCREEN_H:
                continue
            row = im["px"][y * w:(y + 1) * w]
            for x in range(w):
                tx = ox + x
                if 0 <= tx < SCREEN_W:
                    v = row[w - 1 - x] if flip else row[x]
                    if v:
                        px[tx, ty] = court.rgb(pal[v])

    show = planes or set(range(1, 9))
    if 8 in show:
        for nm, x, y in L["clouds"]:
            im, p = L["sprites"][nm]
            put(im, x + tick // 2, y - cam_y, L["spals"][p])
    for plane in range(8, 0, -1):
        if plane not in show:
            continue
        camx = px_x[plane]
        for pc in sorted((p for p in L["pieces"] if p["plane"] == plane), key=lambda p: p["z"]):
            nm, x, y = pc["frames"][(tick // FLAME_RATE) % len(pc["frames"])]
            im, p = L["sprites"][nm]
            put(im, x - camx, y - cam_y, L["spals"][p], pc["flip"])
        md = next((m for m in L["mods"] if m["plane"] == plane), None)
        if md is None:
            continue
        # HIGHER z IN FRONT: PALACE GATES' spear guard (4153h) stands in
        # front of the wall (4040h) in MK1 and in MK2 alike
        for blk in sorted(md["blks"], key=lambda b: b[0] & 0xFFF0):
            f, bx, by, hw = blk
            put(L["imgs"][hw & 0xFFF], md["x"] + bx - camx, md["y"] + by - cam_y,
                L["pals"][L["remap"][thr.pal_of(blk)]][1], bool(f & 0x10))
    if planes is None:
        gy = ground_y(L) - cam_y
        ImageDraw.Draw(scr).line([(0, gy), (SCREEN_W - 1, gy)], fill=(255, 0, 0))
    return scr


def preview(L, cams):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cams = cams or [rec["left"], rec["start"], rec["right"]]
    out = ROOT / "tmp" / "mk1gates"
    out.mkdir(parents=True, exist_ok=True)
    shots = [(c, render(L, c)) for c in cams]
    sheet = Image.new("RGB", (SCREEN_W, (SCREEN_H + 12) * len(shots)), (16, 16, 20))
    dr = ImageDraw.Draw(sheet)
    for k, (c, im) in enumerate(shots):
        sheet.paste(im, (0, k * (SCREEN_H + 12)))
        dr.text((4, k * (SCREEN_H + 12) + 2), "camera %d" % c, fill=(255, 255, 0))
    sheet.save(out / "preview.png")
    pl = Image.new("RGB", (SCREEN_W * 3, SCREEN_H * 2))
    for k, p in enumerate(range(1, 7)):
        pl.paste(render(L, rec["start"], planes={p}), ((k % 3) * SCREEN_W, (k // 3) * SCREEN_H))
    pl.save(out / "planes.png")
    print(f"wrote {out / 'preview.png'} and planes.png")


def report(L):
    rec = L["rec"]
    print(f"PALACE GATES (MK1) - record {GATE_MOD:08X}, entry {GATE_ENTRY}  (Wolf only)")
    print(f"  erase {rec['erase']:04X}  ground {rec['ground']} (MK2 {ground_y(L)})  camera y "
          f"{rec['worldy']}  start {rec['start']}  limits {rec['left']}..{rec['right']}")
    for md, full in zip(L["mods"], L["allmods"]):
        print(f"    plane {md['plane']}  {md['w']:5d}x{md['h']:<4d} at ({md['x']:4d},{md['y']:4d})  "
              f"rate {md['rate']:06X}  {len(md['blks'])} blocks (+{len(full['blks']) - len(md['blks'])} pieces)")
    print(f"  art: {len(L['order'])} headers, {len(L['uniq'])} payloads, {len(L['pals'])} palettes")
    groups, used = deal(L)
    for (name, s, e, ppp), g, u in zip(PACKS, groups, used):
        print(f"  {name} PPP>{ppp} {s:06X}..{e:06X}: {len(g)} images ~{u // 8:,} B "
              f"({100 * u / 8 / (e - s):.0f}%)")
    sb = sum(cave.packed_bits(im) for im, _p in L["sprites"].values()) // 8
    print(f"  sprites: {len(L['sprites'])} records, {len(L['spals'])} palettes, ~{sb:,} B in {SPR_PACK[0]}")
    for pc in L["pieces"]:
        print(f"    plane {pc['plane']} ID {pc['id']} flip {int(pc['flip'])}: " +
              " ".join(f"{n}@({x},{y})" for n, x, y in pc["frames"][:3]) +
              (" ..." if len(pc["frames"]) > 3 else ""))
    print("    clouds: " + " ".join(f"{n}@({x},{y})" for n, x, y in L["clouds"]))


def expect(L, path):
    """tools/wolf_gates_check.lua's expectations, from the build: per piece its
    frames as (SAG, world x, world y), and the cloud constants."""
    tbl = spr_tbl()
    o = ["-- GENERATED by tools/make_mk1gates.py --expect.  Do not edit.", "return {",
         f"  rate = {FLAME_RATE}, cld_n = {len(L['clouds'])}, cld_wrap = {CLOUD_WRAP}, "
         f"cld_back = {CLOUD_BACK}, cld_vel = {CLOUD_VEL},", "  pieces = {"]
    for pc in L["pieces"]:
        fr = ", ".join("{0x%08X, %d, %d}" % (tbl[n][2], x, y) for n, x, y in pc["frames"])
        o.append(f"    {{plane = {pc['plane']}, id = {pc['id']}, frames = {{{fr}}}}},")
    o += ["  },", "}"]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(chr(10).join(o) + chr(10))
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parts", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--preview", nargs="*", type=int, metavar="CAMX")
    ap.add_argument("--expect", metavar="LUA", help="write the Wolf rig's expectations")
    a = ap.parse_args()
    if not any((a.parts, a.apply, a.check, a.report, a.expect, a.preview is not None)):
        ap.error("one of --parts / --apply / --check / --report / --preview")
    L = layout()
    if a.report:
        report(L)
    if a.preview is not None:
        preview(L, a.preview)
    if a.expect:
        expect(L, a.expect)
    files = {}
    if a.parts or a.check:
        files.update(part_files(L))
    if a.parts:
        for nm, data in files.items():
            (DATA / nm).write_bytes(data)
            print(f"wrote data/{nm}  ({len(data):,} bytes)")
    asm = None
    if a.apply or a.check:
        hdrs = merged_headers(L)
        bad = verify_rom(L, hdrs)
        if bad:
            raise SystemExit("PALACE GATES' art is not MK1's:\n  " + "\n  ".join(bad))
        asm = build_asm(L, hdrs)
        if a.apply:
            OUT_ASM.write_text(asm, encoding="latin-1")
            print(f"wrote {OUT_ASM.relative_to(ROOT)}  ({len(asm.splitlines())} lines)")
    if a.check:
        drift = [f"data/{nm} is not the tool's - rerun --parts" for nm, data in files.items()
                 if not (DATA / nm).exists() or (DATA / nm).read_bytes() != data]
        if not OUT_ASM.exists() or OUT_ASM.read_text(encoding="latin-1") != asm:
            drift.append(f"{OUT_ASM.relative_to(ROOT)} has drifted - rerun --apply")
        if drift:
            raise SystemExit("PALACE GATES (MK1) check FAILED:\n  " + "\n  ".join(drift))
        print("PALACE GATES (MK1): packs, tables and packed pixels all match mk.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
