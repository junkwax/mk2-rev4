#!/usr/bin/env python3
r"""JADE'S DESERT - UMK3's desert stage, as a WOLF-ONLY MK2 stage (curback 020h).

Code is src/UMK3DSRT.ASM; everything it is built from is generated into
src/UMK3DSB.ASM by this tool, out of one source:

  C:\\MAME\\roms\\umk3.zip    UMK3 (MAME `umk3`), read by tools/umk3rom.py.
                           The stage record is FF9516F0 (BKGD_DESERT_MOD 0Eh;
                           UMK3's stage table FF9501F0 points its retired BANK
                           slot 02h and slot 12h at the same record).

deadlythirdcombat's MKDESERT.BDB/.BDD is the art library; the ROM is what is
imported, the way tools/make_umk3lair.py imports SCORPION'S LAIR.

  RECORD  FF9516F0: erase 08F3h, world y 0, ground F8h, start x 190h, limits
          0..321h; calla FF951E20, scroll FF951AA0, dlists FF951BC0;
          DESERT1..4 on UMK3 planes 1..4, all four centred; then the floor:
          FL_DESER (1200x40, 6bpp), its palette, height 28h, skew_7 (FF9622E0,
          the same as SCORPION'S LAIR's: dx -= scroll >> 7).
  RATES   plane 1 18000h, 2 10000h, 3 8000h, 4 0 - the fighters (plane 0) 20000h.
  DLISTS  baklst4, 3, 2 on their own cameras; baklst5 ON PLANE 2's camera (the
          buried Cyrax); baklst1; the floor; the shadows; the objects.
  CALLA   create_dumb_animators_w (FF951E70): one entry - CYRXSAND1..4
          (FF951F10, Cyrax half buried in the sand), 7 ticks a frame, at table
          (-B0h, 8Ah) on baklst5.  MK3's init_bakmods runs the calla BEFORE the
          module list, so a4_to_world_coor's worldtlx1 is still the start x:
          world x = table x + 190h (SCORPION'S LAIR measured the same rule).

PLANES MOVE UP ONE.  MK2's worldtlx is the fighters' camera AND plane 1's, and
UMK3's plane 1 scrolls at 3/4 of the fighters, so UMK3 plane n is MK2 baklst
n+1 (worldtlx(n+1)) and baklst1 is a skip_bakmod - PALACE GATES' arrangement.

No stage fatality: UMK3 has none on this stage.

WOLF ONLY - art above the T-unit's 12 MB (the u110-u113 block, linear
0x1400000+), module under `.if wunit'.
  --parts / --apply / --check / --report / --preview
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave      # noqa: E402
import make_mk1pit as pit        # noqa: E402
import make_mk1throne as thr     # noqa: E402
import make_mk1court as court    # noqa: E402
import make_umk3lair as lair     # noqa: E402
import umk3rom                   # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "UMK3DSB.ASM"
SPR_IMG = DATA / "UMK3DSMK.IMG"
SPR_TBL = LOAD2 / "UMK3DSM.TBL"        # LOAD2's own - SAGs pre-relocation
FLOOR_BIN = DATA / "FL_DSRT.BIN"
FLOOR_SRC = Path("C:/Users/you/Workplace/deadlythirdcombat-main/deadlythirdcombat-main/BINFILES/FL_DESER.BIN")
SCREEN_W, SCREEN_H = 400, 254
FLOOR_W = 1200                    # MKDISP floor_x

# Wolf video ROM, linear - the u110-u113 block, which nothing used before
# (makewolf.py writes that block's four chips once it holds any art; the DMA
# reaches it - tools/run_wolf_vrom_reach_test.ps1, doc/WOLF_SPACE.md).
# LOAD2 REFUSES a load address of 8000000 and up ("Illegal load address") -
# the start of that very block - so each LOD is based RELOC lower, inside the
# u114-u117 hole MAME never loads, and makevrom.py (WOLF_RELOCATE) moves the
# payload up by RELOC.  Every SAG this tool emits has RELOC_BITS added, which is
# why Cyrax's headers are generated here and LOAD2's UMK3DSM.TBL is never
# included: its SAGs are the pre-relocation ones.
RELOC = 0x400000
RELOC_BITS = RELOC * 8
PACKS = [("DSRT1", 0x1400000, 0x1428000, 0),    # 160 KB - the stage blocks
         ("DSRT2", 0x1428000, 0x142C000, 8)]    # deeper last pixel (wide_tail)
SPR_PACK = ("DSRTM", 0x142C000, 0x1430000)      # 16 KB - the buried Cyrax
FLOOR_PACK = ("DSRTFL", 0x1430000, 0x143C000)   # 48 KB - FL_DSRT, 36,300 B raw
SPR_PPP = 6
PACK_MARGIN = 0.90
GROUND_LIFT = lair.GROUND_LIFT    # MK2 stands feet ON ground_y; UMK3 ~8 px above
SHADOW_FAST = 2
PLANE_SHIFT = 1                   # UMK3 plane n -> MK2 baklst n+1

REC = 0xFF9516F0
STAGE_TABLE, STAGE_IDX = 0xFF9501F0, 0x0E
CALLA, SCROLL, DLISTS = 0xFF951E20, 0xFF951AA0, 0xFF951BC0
ANIM_TAB = 0xFF951E70             # create_dumb_animators_w's table
CYRAX_LIST = 0xFF951F10
SKEW_7 = 0xFF9622E0
# (address, words) - what the import was read from; a different ROM fails here
CODE_CHECKS = {
    CALLA: [0x09E6, 0x1E70, 0xFF95],                      # MOVI FF951E70h,A6
    SKEW_7: [0x07AB, 0xF370, 0x0105, 0x2B29, 0x452B],     # skew_7
}
UMK3_PLANES = [1, 2, 3, 4]
PAL_PREFIX = "DSRT_P"
CYX_PAL = "DSRTCYX_P"
FLOOR_PAL = "DSRTFL_P"
PLANE_NOTE = {                    # UMK3 plane -> what it carries
    1: "the broken stone wall along the arena",
    2: "the near dunes and the ruined statues",
    3: "the far dunes",
    4: "the clouds - rate 0",
}


class R(umk3rom.UMK3):
    pass


def mk2_plane(p):
    return p + PLANE_SHIFT


# --------------------------------------------------------------------------
def read_umk3(rom):
    for at, words in CODE_CHECKS.items():
        if [rom.w(at + 16 * i) for i in range(len(words))] != words:
            raise SystemExit(f"UMK3 code at {at:08X} is not what this import was read from")
    if rom.l(STAGE_TABLE + 32 * STAGE_IDX) != REC:
        raise SystemExit("UMK3's stage table no longer points the desert at FF9516F0")
    rec = dict(erase=rom.w(REC), worldy=rom.sw(REC + 16), ground=rom.w(REC + 32),
               start=rom.w(REC + 48), left=rom.w(REC + 64), right=rom.w(REC + 80),
               calla=rom.l(REC + 96), scroll=rom.l(REC + 128), dlists=rom.l(REC + 160))
    if (rec["calla"], rec["scroll"], rec["dlists"]) != (CALLA, SCROLL, DLISTS):
        raise SystemExit("UMK3 desert record's pointers moved")
    mods, a, plane = [], REC + 224, 1
    while True:
        v = rom.l(a)
        if v == 1:
            plane += 1
            a += 32
            continue
        if v in (0xFFFFFFFE, 0xFFFFFFFF):
            break
        mods.append(dict(addr=v, w=rom.w(v), h=rom.w(v + 16), n=rom.w(v + 32),
                         hdrs=rom.l(v + 80), pals=rom.l(v + 112), blks=lair.blocks(rom, v),
                         x=rom.sw(a + 32), y=rom.sw(a + 48), plane=plane))
        plane += 1
        a += 64
    if [m["plane"] for m in mods] != UMK3_PLANES:
        raise SystemExit(f"the desert's planes are {[m['plane'] for m in mods]}, not {UMK3_PLANES}")
    centred = []
    if rom.l(a) == 0xFFFFFFFE:
        a += 32
        while (m := rom.l(a)) != 0:
            centred.append(next(md["plane"] for md in mods if md["addr"] == m))
            a += 64
        a += 32
    if sorted(centred) != UMK3_PLANES:
        raise SystemExit(f"the desert centres planes {centred}, not all four")
    rec["centred"] = centred
    rec["floor"] = dict(sag=rom.l(a), pal=rom.l(a + 32), height=rom.w(a + 64),
                        scroll=rom.l(a + 80), skew=rom.l(a + 112))
    if rec["floor"]["skew"] != SKEW_7:
        raise SystemExit("the desert's floor is no longer skew_7")
    for md in mods:
        md["rate"] = rom.l(SCROLL + 32 * (8 - md["plane"]))
        if len(md["blks"]) != md["n"]:
            raise SystemExit(f"UMK3 module {md['addr']:08X}: block count disagrees")
    return rec, mods


def art(rom, mods):
    hd, pl = mods[0]["hdrs"], mods[0]["pals"]
    if any((m["hdrs"], m["pals"]) != (hd, pl) for m in mods):
        raise SystemExit("the desert's modules no longer share one header table")
    order = sorted({b[3] & 0xFFF for m in mods for b in m["blks"]})
    imgs = {}
    for i in order:
        a = hd + 80 * i
        w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
        rows, _ = pit.decode_record(rom.g, sag, w, h, ctrl)
        imgs[i] = dict(idx=i, w=w, h=h, big=0, px=bytes(v for r in rows for v in r), mk_sag=sag)
    share, first = {}, {}
    for i in order:
        k = imgs[i]["mk_sag"]
        if k in first:
            share[i] = first[k]
        else:
            first[k] = i
    uniq = [i for i in order if i not in share]
    used = sorted({thr.pal_of(b) for m in mods for b in m["blks"]})
    remap = {p: k for k, p in enumerate(used)}
    pals = [(f"{PAL_PREFIX}{k:02d}", rom.palette(rom.l(pl + 32 * p)), p) for k, p in enumerate(used)]
    return imgs, order, uniq, pals, remap, share


def sprites(rom, start):
    """Cyrax, half buried (create_dumb_animators_w's one entry)."""
    t = ANIM_TAB
    rate, first, x, y, lst, blst = (rom.w(t), rom.l(t + 16), rom.sw(t + 48), rom.sw(t + 64),
                                    rom.l(t + 80), rom.l(t + 112))
    if lst != CYRAX_LIST or rom.w(t + 144) != 0 or lair.anim_list(rom, lst)[0] != first:
        raise SystemExit("the desert's animator table changed")
    if blst != 0x0105DB70:                      # UMK3 baklst5
        raise SystemExit(f"Cyrax is on UMK3 list {blst:08X}, not baklst5")
    frames = lair.anim_list(rom, lst)
    pal = rom.palette(rom.l(frames[0] + 112))
    recs = {}
    for k, a in enumerate(frames):
        im = lair.rec_image(rom, a)
        if max(im["px"]) >= len(pal):
            raise SystemExit(f"CYRXSAND{k + 1} indexes {max(im['px'])}, {CYX_PAL} has {len(pal)}")
        recs[f"CYRXSAND{k + 1}"] = im
    # a4_to_world_coor adds worldtlx1, which is still the record's start x
    # when the calla runs (MK3 BGND.ASM init_bakmods: calla, then modules)
    return dict(rate=rate, x=x + start, y=y, recs=recs, pal=pal, n=len(frames))


def layout():
    rom = R()
    rec, mods = read_umk3(rom)
    imgs, order, uniq, pals, remap, share = art(rom, mods)
    cyx = sprites(rom, rec["start"])
    fl = rec["floor"]
    fb = (fl["sag"] + 0x2000000) >> 3           # MK3's setup_floor_info adds 02000000h
    floor = bytes(rom.g[fb:fb + FLOOR_W * fl["height"] * 6 // 8])
    return dict(rom=rom, rec=rec, mods=mods, imgs=imgs, order=order, uniq=uniq, pals=pals,
                remap=remap, share=share, cyx=cyx, floor=floor, floorpal=rom.palette(fl["pal"]))


def rec_scroll(L, plane):
    """UMK3 plane's rate (0 = the fighters)."""
    return L["rom"].l(SCROLL + 32 * (8 - plane)) if 0 <= plane <= 8 else 0


def mk2_rates(L):
    """MK2 scroll table rate per MK2 plane 1..8 (plane 1 = the fighters)."""
    return {e: rec_scroll(L, e - PLANE_SHIFT) for e in range(1, 9)}


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
    return [f"CYRXSAND{k + 1}" for k in range(L["cyx"]["n"])]


LOD_SPR = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  JADE'S DESERT (UMK3), WOLF ONLY - Cyrax buried in the sand
;  (linear 0x{start:06X}..0x{end:06X}, loaded 4 MB lower and moved
;  up by makevrom.py WOLF_RELOCATE - LOAD2 refuses 8000000+)
;
;  data/UMK3DSMK.IMG is GENERATED by tools/make_umk3desert.py --parts
;  out of umk3.zip: CYRXSAND1-4 (FF951F10), with their anipoints and
;  their own palette (src/UMK3DSB.ASM).  PON>: built with gso_dmawnz,
;  which reads the palette off the record.
;
;**************************************************************
PON>
ZON>
PPP> {ppp}
ASM> UMK3DSM.TBL
UMK3DSMK.IMG
{recs}
"""

LOD_FLOOR = """***> {addr}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  JADE'S DESERT (UMK3), WOLF ONLY - skew floor (linear
;  0x{start:06X}..0x{end:06X}, loaded 4 MB lower and moved up by
;  makevrom.py WOLF_RELOCATE - LOAD2 refuses 8000000+)
;
;  FL_DSRT.BIN is UMK3's own floor (deadlythirdcombat's
;  BINFILES/FL_DESER.BIN), read out of umk3.zip at its SAG: 1200x40
;  raw 6bpp plus one guard row, the shape MKDISP's floor_code draws.
;  ZOF> - floor_code reads raw rows.
;
;**************************************************************
ZOF>
POF>
PPP> 6
ASM> DSRTFL.TBL
FRM> FL_DSRT
"""


def part_files(L):
    imgs = L["imgs"]
    groups, _ = deal(L)
    files = {}
    lod = court.LOD_BBB.replace("THE COURTYARD (MK1)", "JADE'S DESERT (UMK3)") \
        .replace("make_mk1court.py", "make_umk3desert.py") \
        .replace("C:\\\\MAME\\\\roms\\\\mk.zip - MK1's stage record FFCBB410.", "umk3.zip - UMK3's stage record FF9516F0.") \
        .replace(";  The leak's KUNGFU2 is a pre-release Courtyard, not this one.\n", "") \
        .replace("(src/MK1CRTB.ASM)", "(src/UMK3DSB.ASM)")
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
               "LOAD2's auto depth ignores a block's LAST pixel; these need more bits there")
        files[f"{name}.LOD"] = lod.format(addr=court.lod_addr(s - RELOC), n=name[-1], start=s, end=e,
                                          name=name, ppp=ppp, why=why).encode()
    names = spr_order(L)
    cyx = L["cyx"]
    entries = [(nm, cyx["recs"][nm]["ax"], cyx["recs"][nm]["ay"], cyx["recs"][nm]["w"],
                cyx["recs"][nm]["h"], cyx["recs"][nm]["px"], 0) for nm in names]
    files[SPR_IMG.name] = pit.build_img(entries, [(CYX_PAL, cave._bpp(len(cyx["pal"]) - 1), cyx["pal"])])
    name, s, e = SPR_PACK
    files[f"{name}.LOD"] = LOD_SPR.format(addr=court.lod_addr(s - RELOC), start=s, end=e, ppp=SPR_PPP,
                                          recs="---> " + ",".join(names)).encode()
    name, s, e = FLOOR_PACK
    files[f"{name}.LOD"] = LOD_FLOOR.format(addr=court.lod_addr(s - RELOC), start=s, end=e).encode()
    # one guard row after the last - the skew floor reads past a row's end at
    # the right scroll limit (SCORPION'S LAIR's yellow dash, 2026-10-08)
    row = FLOOR_W * 6 // 8
    files[FLOOR_BIN.name] = L["floor"] + L["floor"][-row:]
    return files


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
            addr += RELOC_BITS
            if (w, h) != (imgs[idx]["w"], imgs[idx]["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} outside {start:X}..{end:X}")
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
    for i, j in L["share"].items():
        w, h, addr, ctrl, src = by[j]
        by[i] = (w, h, addr, ctrl, f"{src} (UMK3 shares one SAG with {j:02X})")
    return [by[i] for i in L["order"]]


def spr_tbl():
    if not SPR_TBL.exists():
        raise SystemExit(f"{SPR_TBL} missing - run python build.py")
    out, lines = {}, SPR_TBL.read_text(encoding="latin-1").splitlines()
    for i, ln in enumerate(lines):
        t = ln.strip()
        if t.endswith(":") and t.startswith("CYRXSAND"):
            w, h, ax, ay = (int(v, 0) for v in lines[i + 1].split(None, 1)[1].split(","))
            out[t[:-1]] = (w, h, int(lines[i + 2].split()[1].rstrip("Hh"), 16) + RELOC_BITS,
                           int(lines[i + 3].split()[1].rstrip("Hh"), 16), ax, ay)
    return out


def floor_sag():
    import re
    p = LOAD2 / "DSRTFL.TBL"
    if not p.exists():
        raise SystemExit(f"{p} missing - run python build.py")
    m = re.search(r"^FL_DSRT\s+\.set\s+0?([0-9A-Fa-f]+)[hH]", p.read_text(encoding="latin-1"), re.M)
    if not m:
        raise SystemExit("tmp/load2/DSRTFL.TBL: no FL_DSRT")
    return int(m.group(1), 16) + RELOC_BITS


def decode_at(addr, w, h, ctrl):
    p = cave.sag_phys(addr)
    for name, *_r in PACKS + [SPR_PACK, FLOOR_PACK]:
        if not (DATA / f"{name}.IRW").exists():
            continue
        start, payload = court.wolf_irw(name)
        start += RELOC
        if start <= p < start + len(payload):
            rows, _b = pit.decode_record(payload, pit.runtime_bit(addr) - start * 8, w, h, ctrl)
            return name, bytes(v for r in rows for v in r)
    raise SystemExit(f"SAG {addr:08X} (linear {p:X}) is in no written Wolf pack")


def verify_rom(L, hdrs):
    bad = []
    for idx, (w, h, addr, ctrl, src) in zip(L["order"], hdrs):
        try:
            name, px = decode_at(addr, w, h, ctrl)
        except IndexError:
            bad.append(f"UMK3 {idx:02X} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, L["imgs"][idx]["px"]) if a != b)
        if n:
            bad.append(f"{name}: UMK3 {idx:02X} ({src}) - {n} pixels differ from umk3.zip")
    tbl = spr_tbl()
    for nm, im in L["cyx"]["recs"].items():
        if nm not in tbl:
            bad.append(f"{nm} is not in {SPR_TBL.name}")
            continue
        w, h, sag, ctrl, _ax, _ay = tbl[nm]
        try:
            name, px = decode_at(sag, w, h, ctrl)
        except IndexError:
            bad.append(f"{nm} runs off its IRW")
            continue
        n = sum(1 for a, b in zip(px, im["px"]) if a != b)
        if (w, h) != (im["w"], im["h"]) or n:
            bad.append(f"{name}: {nm} - {n} pixels differ from umk3.zip")
    fs = floor_sag()
    start, payload = court.wolf_irw(FLOOR_PACK[0])
    start += RELOC
    o = cave.set_phys(fs) - start
    if payload[o:o + len(L["floor"])] != L["floor"]:
        bad.append("FL_DSRT in the pack is not umk3.zip's floor")
    return bad, fs, tbl


def build_asm(L, hdrs, fsag, stbl):
    rec, mods = L["rec"], L["mods"]
    h4 = court.h4
    o = []
    w = o.append
    w("; JADE'S DESERT (UMK3) - GENERATED by tools/make_umk3desert.py --apply.  Do not hand-edit.")
    w("; Art and layout: UMK3's stage record FF9516F0 (C:\\MAME\\roms\\umk3.zip), read by the tool.")
    w("; Included only under .if wunit (src/UMK3DSRT.ASM) - Wolf-only art.")
    w("; MK2 planes are UMK3's plus one: MK2's plane 1 is the fighters' camera.")
    w("")
    for k, v in (("erase", h4(rec["erase"])), ("ground", rec["ground"] - GROUND_LIFT),
                 ("worldy", rec["worldy"]), ("start", rec["start"]),
                 ("left", rec["left"]), ("right", rec["right"]), ("shad_fast", SHADOW_FAST)):
        w(f"dsrt_{k}\t.set\t{v}")
    rates = mk2_rates(L)
    for e in range(1, 9):
        u = e - PLANE_SHIFT
        note = "the fighters, the floor" if u == 0 else (f"UMK3 plane {u} - {PLANE_NOTE[u]}" if u in PLANE_NOTE else "")
        w(f"dsrt_rate{e}\t.set\t{h4(rates[e], 6)}\t\t; plane {e}" + (f" - {note}" if note else ""))
    for md in mods:
        n = mk2_plane(md["plane"])
        w(f"dsrt_m{n}_x\t.set\t{md['x']}\t\t; plane {n} - {PLANE_NOTE[md['plane']]}")
        w(f"dsrt_m{n}_y\t.set\t{md['y']}")
    fl = rec["floor"]
    w(f"FL_DSRT\t\t.set\t{h4(fsag, 8)}\t; tmp/load2/DSRTFL.TBL")
    w(f"dsrt_fl_h\t.set\t{fl['height']}")
    w(f"dsrt_fl_y\t.set\t{254 + rec['worldy'] - fl['height']}\t\t; MK3's setup_floor_info: "
      "worldy + 254 - height")
    cyx = L["cyx"]
    first = cyx["recs"]["CYRXSAND1"]
    w(f"dsrt_cyx_rate\t.set\t{cyx['rate']}")
    w(f"dsrt_cyx_n\t.set\t{cyx['n']}")
    w(f"dsrt_cyx_x\t.set\t{cyx['x'] - first['ax']}\t\t; top-left: world x {cyx['x']} less CYRXSAND1's anipoint")
    w(f"dsrt_cyx_y\t.set\t{cyx['y'] + rec['worldy'] - first['ay']}")
    w("")
    w("\t.data")
    w("")
    w("DSRTHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["order"]):
        w(f"\t.word\t{hw},{hh}\t\t; UMK3 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["order"])}
    for md in mods:
        lab = "DSRT%d" % mk2_plane(md["plane"])
        w(f"{lab}BLKS:\t\t\t\t; {PLANE_NOTE[md['plane']]}")
        for blk in md["blks"]:
            f, bx, by, hw = blk
            np = L["remap"][thr.pal_of(blk)]
            w("\t.word\t%s,%d,%d,%s" % (h4((f & 0xFFF0) | (np & 0xF)), bx, by,
                                        h4(hidx[hw & 0xFFF] + ((np >> 4) << 12))))
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{md['w']},{md['h']},{len(md['blks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, DSRTHDRS, DSRTPALS")
        w("")
    w("DSRTPALS:")
    for label, _words, p in L["pals"]:
        w(f"\t.long\t{label}\t\t; UMK3 palette {p}")
    w("")
    allp = [(lb, wd) for lb, wd, _p in L["pals"]] + [(CYX_PAL, cyx["pal"]), (FLOOR_PAL, L["floorpal"])]
    for label, words in allp:
        w(f"{label}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    w("")
    w("; Cyrax's headers - LOAD2's tmp/load2/UMK3DSM.TBL with the SAGs relocated")
    for nm in spr_order(L):
        sw, sh, sag, ctrl, ax, ay = stbl[nm]
        w(f"{nm}:")
        w(f"\t.word\t{sw},{sh},{ax},{ay}")
        w(f"\t.long\t{h4(sag, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
        w(f"\t.long\t{CYX_PAL}")
    w("")
    w(f"dsrt_cyrax:\t\t\t; {CYRAX_LIST:08X}, in order")
    for nm in spr_order(L):
        w(f"\t.long\t{nm}")
    w("\t.long\t0")
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------
def plane_x(L, cam):
    """Every UMK3 plane's worldtlx at a fighters' camera of `cam`."""
    s = L["rec"]["start"]
    out = {}
    for e in range(9):
        base = s
        md = next((m for m in L["mods"] if m["plane"] == e), None)
        if md and e in L["rec"]["centred"]:
            base = md["w"] // 2 - 399 // 2      # center_x: scrrgt/2
        out[e] = base + (cam - s) * rec_scroll(L, e) // 0x20000
    return out


def render(L, cam, planes=None):
    from PIL import Image, ImageDraw
    rec = L["rec"]
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

    show = planes or set(range(1, 9)) | {"floor", "cyrax"}

    def plane(p):
        if p not in show:
            return
        md = next((m for m in L["mods"] if m["plane"] == p), None)
        if md is None:
            return
        for blk in sorted(md["blks"], key=lambda b: b[0] & 0xFFF0):
            f, bx, by, hw = blk
            put(L["imgs"][hw & 0xFFF], md["x"] + bx - px_x[p], md["y"] + by - rec["worldy"],
                L["pals"][L["remap"][thr.pal_of(blk)]][1], bool(f & 0x10))

    for p in (4, 3, 2):
        plane(p)
    if "cyrax" in show:
        cyx = L["cyx"]
        im = cyx["recs"]["CYRXSAND1"]
        put(im, cyx["x"] - im["ax"] - px_x[2], cyx["y"] - im["ay"], cyx["pal"])
    plane(1)
    if "floor" in show:
        fl, h = L["floor"], rec["floor"]["height"]
        y0 = 254 - h
        bits = int.from_bytes(fl, "little")
        cx = px_x[0] - rec["start"] + (FLOOR_W - SCREEN_W) // 2
        for r in range(h):
            for x in range(SCREEN_W):
                c = (x + cx) % FLOOR_W
                v = (bits >> (6 * (r * FLOOR_W + c))) & 63
                if v and 0 <= y0 + r < SCREEN_H:
                    px[x, y0 + r] = court.rgb(L["floorpal"][v])
    if planes is None:
        gy = rec["ground"] - GROUND_LIFT - rec["worldy"]
        ImageDraw.Draw(scr).line([(0, gy), (SCREEN_W - 1, gy)], fill=(255, 0, 0))
    return scr


def preview(L, cams):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    cams = cams or [rec["left"], rec["start"], rec["right"]]
    out = ROOT / "tmp" / "umk3desert"
    out.mkdir(parents=True, exist_ok=True)
    shots = [(c, render(L, c)) for c in cams]
    sheet = Image.new("RGB", (SCREEN_W, (SCREEN_H + 12) * len(shots)), (16, 16, 20))
    dr = ImageDraw.Draw(sheet)
    for k, (c, im) in enumerate(shots):
        sheet.paste(im, (0, k * (SCREEN_H + 12)))
        dr.text((4, k * (SCREEN_H + 12) + 2), "camera %d" % c, fill=(255, 255, 0))
    sheet.save(out / "preview.png")
    print(f"wrote {out / 'preview.png'}")


def report(L):
    rec = L["rec"]
    print(f"JADE'S DESERT (UMK3) - record {REC:08X}  (Wolf only)")
    print(f"  erase {rec['erase']:04X} ground {rec['ground']} world y {rec['worldy']} start "
          f"{rec['start']} limits {rec['left']}..{rec['right']}  centred planes {rec['centred']}")
    for md in L["mods"]:
        print(f"    UMK3 plane {md['plane']} -> MK2 baklst{mk2_plane(md['plane'])}  "
              f"{md['w']:5d}x{md['h']:<4d} at ({md['x']:4d},{md['y']:4d})  "
              f"rate {md['rate']:06X}  {len(md['blks'])} blocks")
    print(f"  art: {len(L['order'])} headers, {len(L['uniq'])} payloads, {len(L['pals'])} palettes")
    groups, used = deal(L)
    for (name, s, e, ppp), g, u in zip(PACKS, groups, used):
        print(f"  {name} PPP>{ppp} {s:07X}..{e:07X}: {len(g)} images ~{u // 8:,} B")
    print(f"  floor {rec['floor']['sag']:08X} h {rec['floor']['height']}, "
          f"{len(L['floor']):,} B, == BINFILES: {FLOOR_SRC.exists() and FLOOR_SRC.read_bytes()[:len(L['floor'])] == L['floor']}")
    c = L["cyx"]
    print(f"  Cyrax: {c['n']} frames at {c['rate']} ticks, world ({c['x']},{c['y']}) on plane 2's camera")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parts", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--preview", nargs="*", type=int, metavar="CAMX")
    a = ap.parse_args()
    if not any((a.parts, a.apply, a.check, a.report, a.preview is not None)):
        ap.error("one of --parts / --apply / --check / --report / --preview")
    L = layout()
    if a.report:
        report(L)
    if a.preview is not None:
        preview(L, a.preview)
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
        bad, fs, stbl = verify_rom(L, hdrs)
        if bad:
            raise SystemExit("JADE'S DESERT's art is not UMK3's:\n  " + "\n  ".join(bad))
        asm = build_asm(L, hdrs, fs, stbl)
        if a.apply:
            OUT_ASM.write_text(asm, encoding="latin-1")
            print(f"wrote {OUT_ASM.relative_to(ROOT)}  ({len(asm.splitlines())} lines)")
    if a.check:
        drift = [f"data/{nm} is not the tool's - rerun --parts" for nm, data in files.items()
                 if not (DATA / nm).exists() or (DATA / nm).read_bytes() != data]
        if not OUT_ASM.exists() or OUT_ASM.read_text(encoding="latin-1") != asm:
            drift.append(f"{OUT_ASM.relative_to(ROOT)} has drifted - rerun --apply")
        if drift:
            raise SystemExit("JADE'S DESERT (UMK3) check FAILED:\n  " + "\n  ".join(drift))
        print("JADE'S DESERT (UMK3): packs, floor, tables and packed pixels all match umk3.zip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
