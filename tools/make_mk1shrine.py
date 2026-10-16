#!/usr/bin/env python3
r"""THE WARRIOR SHRINE - MK1's statue gallery, as an MK2 stage (curback 01Bh).

The stage the MK1 fighters' statues stand in - Sub-Zero, Cage, Kano, Goro,
Liu Kang, Raiden and Sonya on their plinths between the pillars - under a
night sky with a moon, a line of trees and a mountain behind.  Code is
src/MK1WSHR.ASM; everything it is built from is generated into
src/MK1WSHRB.ASM by this tool.

EVERYTHING HERE IS READ, NOT REMEMBERED.  Two sources:

  data/KUNGFU1.BDB/.BDD  MK1's own background file for the shrine, from the
                         leak: three modules - WOKWAY1 (the shrine), WOKWAY2
                         (the trees) and WOKWAY3 (the mountain).
  C:\MAME\roms\mk.zip    MK1 rev 5.0 (T-unit).  Stage table FFCA7E30, entry
                         2 = FFCB7160 is the shrine.  --check proves, every
                         build, that KUNGFU1 IS what MK1 shipped: all 242
                         blocks equal MK1's three module block lists (flags,
                         x, y, header, palette), all 93 images decode to the
                         same pixels out of MK1's video ROM, all 12 palettes
                         are the same words.  The layout numbers - erase
                         colour, ground, camera, limits, module placements,
                         scroll rates - are taken off the record, not typed.

THE PLANES.  MK1 keeps nine planes like MK2 does, and the record's third
.long names the first bak?mods it fills: 01095550h, plane-table entry 1
(FFCB61A0, five .longs an entry - bits, worldtly, worldtlx, bakmods, list).
Entry e's worldtlx is 0104F890h - 32e, and MK1's scroller adds scroll-table
.long 8-e to it: FFCBFCA0 stores the table's nine values from 0104F670h up,
and FFC79E00 adds 0104F670h+32k into 0104F790h+32k.  So the shrine is on
entry 1 at 020000h (the fighters' speed), the trees on entry 2 at 010000h
and the mountain on entry 3 at 0 - it never scrolls sideways.  MK2's table
runs the same way (mk1ptop_scroll: first .long plane 8, last plane 0), so
entry e is simply MK2's baklst e.

THE MOON.  The shrine's calla, FFCB8E40, is exactly THE PIT's moon
subroutine (THE PIT's own calla CALLRs it): one m_noscroll object, the
PITMOON record at (90,20).  MK2 already ships that record for THE PIT, so
MK1WSHR.ASM just runs MK1PTOP.ASM's mk1p_moon - no art of its own.

WHAT GOES WHERE

  --parts   Three KUNGFU1 images already sit in THE PIT's packs with the same
            pixels (KUNGFU5 carries them too) - their SAGs are reused, read
            out of src/MK1PTOPB.ASM.  The other 90 are dealt first-fit
            decreasing into PACKS, data/MK1WSn.BDB/.BDD + .LOD, one fixed
            bank-0 slot each at the top of an oversized guard
            (make_mk3cave.py's technique; no free run holds ~82KB:
            FLAPJACK's is ~73KB, HANGJOHD's the other ~14KB).
  --apply   src/MK1WSHRB.ASM: layout equates, MK1WSHDRS (merged from the
            tmp/load2/BGNDTBL.WSn snapshots and the Pit's headers), the three
            modules' BLKS/BMOD and the twelve palettes.  Every record is
            decoded back out of its IRW and compared with KUNGFU1 first.
            It also writes the parallax tables (wshrpar in src/MK1WSHR.ASM,
            see "Parallax" below) after proving them: every floor row
            decodes from its offset, and no camera leaves a floor hole.
  --check   all of the above compared instead of written (Phase D).
  --preview renders screens from the same constants: tmp/mk1shrine/preview.png
            (--par for the parallax layers)
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave  # noqa: E402  (BDD/BDB readers, LOAD2 size model)
import make_mk1pit as pit    # noqa: E402  (MK1 ROM reader, IRW decode, LOD helpers)

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "MK1WSHRB.ASM"
PIT_ASM = SRC / "MK1PTOPB.ASM"
SOURCE = "KUNGFU1"
SCREEN_W, SCREEN_H = 400, 254

# --------------------------------------------------------------------------
# Video ROM.  Physical addresses, end exclusive.  Mirrored in makevrom.py
# CUSTOM_VIDEO_SLOTS and each LOD's ***> line (the tool writes the LODs).
# Bank 0: background art is DMA-drawn and never walked by shadow_p1p2's
# bank-less CPU read, so either bank would do - bank 0 is where the room is.
# --------------------------------------------------------------------------
PACKS = [
    # name      start     end       PPP  donor slot end pulled back to `start`
    ("MK1WS1", 0x7D4200, 0x7E5C00, 0),   # FLAPJACK   (payload ends 0x7D3A6E)
    ("MK1WS2", 0x75BE00, 0x75F400, 0),   # HANGJOHD   (payload ends 0x75B9B6)
    ("MK1WS3", 0x7E5C00, 0x7E6000, 6),   # the top 1KB of MK1WS1's run: WIDE_TAIL
]
PACK_MARGIN = 0.96

# LOAD2's auto depth (PPP> 0) sizes a block by every pixel BUT THE LAST, then
# writes that last pixel at its own width - the overflow lands in the NEXT
# record's first rows.  KUNGFU1 DE and E4 end on STONEBD_P 34 with nothing
# else above 22, so LOAD2 stored them at 5bpp and shredded E7 (318 of 560
# pixels) in the first build.  34 is a real colour of that 54-entry palette,
# MK1 draws it, and no index under 32 holds the same colour - so rather than
# repaint a pixel, such an image goes into a pack forced to PPP> 6.
# (THE PIT's KUNGFU5 has the same tails, out of range there: make_mk1pit.py
# mask6.)

# --------------------------------------------------------------------------
# MK1 anchors (C:\MAME\roms\mk.zip, rev 5.0).  Each is checked when read.
# --------------------------------------------------------------------------
SHRINE_ENTRY = 2
SHRINE_MOD = 0xFFCB7160
MOON_SUB = 0xFFCB8E40
PLANE_TABLE = 0xFFCB61A0        # 9 x (.long bits, worldtly, worldtlx, bakmods, list)
PLANE_WORLDTLX0 = 0x0104F890    # entry e's worldtlx = this - 32e
# the moon subroutine, word for word: MOVI FFCB95D0h,A14 / CALLA FFC8A620h /
# MOVE A8,A0 / MOVI 104F930h,B4 / JA FFC7F9F0h - one object, and nothing else
MOON_CODE = [0x09EE, 0x95D0, 0xFFCB, 0x0D5F, 0xA620, 0xFFC8, 0x4D00,
             0x09F4, 0xF930, 0x0104, 0xC080, 0xF9F0, 0xFFC7]
# MK1's scroller: the table's values land at 0104F670h+32k (FFCBFCA0,
# MOVI 104F790h,B0 / MMTM B0,B1-B9) and are added to 0104F790h+32k (FFC79E00)
SCROLL_CODE = {0xFFCBFCA0: [0x09F0, 0xF790, 0x0104, 0x0990, 0x7FC0],
               0xFFC79E00: [0x09FA, 0xF670, 0x0104, 0x09FB, 0xF790, 0x0104]}

# MK2's fighters stand lower on their anchor than MK1's - THE PIT measured
# ~7 rows (tools/make_mk1pit.py GROUND_Y) and moved its ground from MK1's 264
# to 258.  Same nudge here, so the boots land on the floor row MK1's did.
GROUND_NUDGE = -6
SHADOW_FAST = 2                 # every fightable stage: compressed pieces via shadf


def read_mk1(rom):
    """The shrine's stage record, plane mapping and moon, checked."""
    if rom.l(pit.MK1_STAGES + SHRINE_ENTRY * 32) != SHRINE_MOD:
        raise SystemExit("MK1 stage table entry 2 is not FFCB7160 - wrong ROM revision?")
    rec = dict(erase=rom.w(SHRINE_MOD), ground=rom.w(SHRINE_MOD + 16), worldy=rom.sw(SHRINE_MOD + 32),
               start=rom.w(SHRINE_MOD + 48), left=rom.w(SHRINE_MOD + 64), right=rom.w(SHRINE_MOD + 80),
               calla=rom.l(SHRINE_MOD + 96), scroll=rom.l(SHRINE_MOD + 128), bakmods=rom.l(SHRINE_MOD + 160))
    if rec["calla"] != MOON_SUB:
        raise SystemExit(f"the shrine's calla is {rec['calla']:08X}, not the moon subroutine FFCB8E40")
    code = [rom.w(MOON_SUB + 16 * i) for i in range(len(MOON_CODE))]
    if code != MOON_CODE or rom.l(MOON_SUB + 16) != pit.MOON_OBJ:
        raise SystemExit("FFCB8E40 is no longer MK1's one-object moon subroutine")
    for at, words in SCROLL_CODE.items():
        if [rom.w(at + 16 * i) for i in range(len(words))] != words:
            raise SystemExit(f"MK1 scroller at {at:08X} moved - the plane/rate mapping is unproven")

    planes = []
    for e in range(9):
        base = PLANE_TABLE + 160 * e
        if rom.l(base + 64) != PLANE_WORLDTLX0 - 32 * e:
            raise SystemExit(f"MK1 plane table entry {e}: worldtlx {rom.l(base + 64):08X}")
        planes.append(dict(bakmods=rom.l(base + 96), list=rom.l(base + 128)))
    first = [p["bakmods"] for p in planes].index(rec["bakmods"])
    if first < 1:
        raise SystemExit("the shrine starts on MK1's plane 0 - MK2 has no baklst0")

    mods, a = [], SHRINE_MOD + 192
    while (m := rom.l(a)) != 0xFFFFFFFF:
        e = first + len(mods)
        blks, q = [], rom.l(m + 48)
        while rom.w(q) != 0xFFFF:
            blks.append(tuple(rom.w(q + 16 * k) for k in range(4)))
            q += 64
        mods.append(dict(addr=m, x=rom.sw(a + 32), y=rom.sw(a + 48), w=rom.w(m), h=rom.w(m + 16),
                         n=rom.w(m + 32), blks=blks, hdrs=rom.l(m + 80), pals=rom.l(m + 112),
                         plane=e, rate=rom.l(rec["scroll"] + 32 * (8 - e))))
        a += 64
    if len({(m["hdrs"], m["pals"]) for m in mods}) != 1:
        raise SystemExit("the shrine's modules no longer share one header table and palette list")
    rec["moon_plane"] = [p["list"] for p in planes].index(0x0104F930)
    return rec, mods


def check_source(rom, mods, imgs, order, pals, bdb_mods):
    """KUNGFU1 against what MK1 shipped.  Returns [(bdb module, mk1 module)]."""
    bad = []
    pairs = []
    for mm in mods:
        want = sorted((f & ~0x40, x, y, h) for f, x, y, h in mm["blks"])
        hit = None
        for bm in bdb_mods:
            ours = sorted(((b["z"] & 0xFFF0) | (b["pal"] & 0xF), b["rx"], b["ry"],
                           order.index(b["hdr"]) + ((b["pal"] >> 4) << 12)) for b in bm["blocks"])
            if (bm["w"], bm["h"]) == (mm["w"], mm["h"]) and ours == want:
                hit = bm
        if hit is None:
            bad.append(f"MK1 module {mm['addr']:08X} ({mm['w']}x{mm['h']}) has no identical KUNGFU1 module")
        pairs.append((hit, mm))
    hd = mods[0]["hdrs"]
    for i, o in enumerate(order):
        a = hd + 80 * i
        w, h, sag, ctrl = rom.w(a), rom.w(a + 16), rom.l(a + 32), rom.w(a + 64)
        im = imgs[o]
        if (w, h) != (im["w"], im["h"]):
            bad.append(f"MK1 header {i} is {w}x{h}, KUNGFU1 {o:02X} is {im['w']}x{im['h']}")
            continue
        rows, bpp = pit.decode_record(rom.g, sag - pit.IROM, w, h, ctrl)
        m = (1 << bpp) - 1
        if any(rows[y][x] != im["px"][y * w + x] or im["px"][y * w + x] > m for y in range(h) for x in range(w)):
            bad.append(f"KUNGFU1 {o:02X} ({w}x{h}): pixels are not MK1's")
    for i, (nm, words) in enumerate(pals):
        if rom.palette(rom.l(mods[0]["pals"] + 32 * i)) != words:
            bad.append(f"KUNGFU1 palette {nm} is not MK1's")
    if bad:
        raise SystemExit("KUNGFU1 is not MK1's warrior shrine:\n  " + "\n  ".join(bad))
    return pairs


# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------
def pit_headers():
    """THE PIT's merged headers, keyed by KUNGFU5 image: (w, h, addr, ctrl, src)."""
    text = PIT_ASM.read_text(encoding="latin-1")
    m = re.search(r"^MK1PTHDRS:\s*$", text, re.M)
    if not m:
        raise SystemExit(f"{PIT_ASM}: no MK1PTHDRS - run tools/make_mk1pit.py --apply first")
    out = {}
    lines = text[m.end():].lstrip("\r\n").splitlines()
    i = 0
    while i + 2 < len(lines):
        mw = re.match(r"^\s*\.word\s+(\d+),(\d+)\s*;\s*KUNGFU5 ([0-9A-F]{2}) <- (.*)$", lines[i])
        if not mw:
            break
        addr = pit.asm_int(lines[i + 1].split(None, 1)[1])
        ctrl = pit.asm_int(lines[i + 2].split(None, 1)[1])
        out[int(mw.group(3), 16)] = (int(mw.group(1)), int(mw.group(2)), addr, ctrl, mw.group(4).strip())
        i += 3
    if not out:
        raise SystemExit(f"{PIT_ASM}: MK1PTHDRS is empty")
    return out


def layout():
    rom = pit.MK1()
    rec, mods = read_mk1(rom)
    imgs, order, pals = cave.load_bdd(DATA / f"{SOURCE}.BDD")
    bdb_mods, blks = cave.load_bdb(DATA / f"{SOURCE}.BDB")
    bdb_mods = cave.assign_modules(bdb_mods, blks, imgs)
    for bm in bdb_mods:
        bl = bm["blocks"]
        x1 = min(b["x"] for b in bl)
        y1 = min(b["y"] for b in bl)
        bm["w"] = max(b["x"] + imgs[b["hdr"]]["w"] for b in bl) - x1
        bm["h"] = max(b["y"] + imgs[b["hdr"]]["h"] for b in bl) - y1
        for b in bl:
            b["rx"], b["ry"] = b["x"] - x1, b["y"] - y1
        bl.sort(key=lambda b: (b["rx"], b["ry"]))
    pairs = check_source(rom, mods, imgs, order, pals, bdb_mods)

    # images whose pixels THE PIT already put in the ROM (KUNGFU5 shares them)
    ki, _ko, _kp = cave.load_bdd(DATA / "KUNGFU5.BDD")
    pit.mask6(ki)
    have = pit_headers()
    by_px = {}
    for k, hdr in have.items():
        im = ki[k]
        by_px.setdefault((im["w"], im["h"], im["px"]), (k, hdr))
    shared = {}
    for o in order:
        im = imgs[o]
        got = by_px.get((im["w"], im["h"], im["px"]))
        if got:
            shared[o] = got
    new = [o for o in order if o not in shared]
    return dict(rom=rom, rec=rec, pairs=pairs, imgs=imgs, order=order, pals=pals,
                shared=shared, new=new)


def ground_y(L):
    return L["rec"]["ground"] + GROUND_NUDGE


# --------------------------------------------------------------------------
# Packs
# --------------------------------------------------------------------------
def wide_tail(im):
    """True when LOAD2's auto depth (every pixel but the last) is too narrow
    for the last pixel."""
    return cave._bpp(im["px"][-1]) > cave._bpp(max(im["px"][:-1], default=0))


def deal(L):
    """First-fit decreasing.  A WIDE_TAIL image may only go into a PPP> 6
    pack, every other image only into a PPP> 0 one."""
    imgs = L["imgs"]
    cap = [int((e - s) * 8 * PACK_MARGIN) for _, s, e, _p in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(L["new"], key=lambda i: (-cave.packed_bits(imgs[i]), i)):
        bits = cave.packed_bits(imgs[idx])
        want = 6 if wide_tail(imgs[idx]) else 0
        for k in range(len(PACKS)):
            if PACKS[k][3] == want and used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    order = L["order"]
    return [sorted(g, key=order.index) for g in got], used


def part_files(L):
    imgs, pals = L["imgs"], L["pals"]
    groups, _ = deal(L)
    files = {}
    for (name, _s, _e, _p), group in zip(PACKS, groups):
        if not group:
            continue
        bdd = bytearray(b"%d\n" % len(group))
        for idx in group:
            im = imgs[idx]
            bdd += b"%x %d %d %d\n" % (idx, im["w"], im["h"], im["big"])
            bdd += im["px"]
        for nm, words in pals:
            bdd += b"%s %d\n" % (nm.encode(), len(words))
            bdd += struct.pack("<%dH" % len(words), *words)
        x, lines = 0, []
        for idx in group:
            lines.append("4000 %d 0 %X 0" % (x, idx))
            x += imgs[idx]["w"] + 4
        hmax = max(imgs[i]["h"] for i in group)
        bdb = [f"{name} {max(x, 1)} {hmax} 255 1 {len(pals)} {len(group)}",
               f"{name} 0 {max(x - 5, 0)} 0 {hmax - 1}"] + lines
        files[f"{name}.BDD"] = bytes(bdd)
        files[f"{name}.BDB"] = ("\n".join(bdb) + "\n").encode()
    return files


def pack_lod(name, start, end, ppp):
    return f"""***> {pit.lod_address(start)}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE WARRIOR SHRINE (MK1) - image pack {name[-1]} (phys 0x{start:06X}..0x{end:06X})
;
;  data/{name}.BDB/.BDD are GENERATED by tools/make_mk1shrine.py --parts
;  from data/KUNGFU1.BDB/.BDD, MK1's own shrine background.  Its images
;  are dealt across fixed slots and --apply merges the header tables
;  back into the stage's three modules (src/MK1WSHRB.ASM).  Do not
;  edit the pack BDB/BDD by hand.
;
{PPP_NOTE[ppp]}
;
;**************************************************************
ZON>
POF>
PPP> {ppp}
GLO> BGNDTBL.GLO
BBB> {name}
"""


PPP_NOTE = {
    0: """;  PPP> 0: per-block auto depth, as every BBB> in MK7MIL.  DMA-drawn
;  background, never walked by shadow_p1p2's bank-less CPU read.""",
    6: """;  PPP> 6, NOT 0: these blocks end on a pixel wider than all the
;  rest, and LOAD2's auto depth ignores a block's last pixel - it
;  would store them a bit short and spill into the next record.
;  See WIDE_TAIL in the tool.""",
}


def lod_files(L):
    groups, _ = deal(L)
    return {f"{name}.LOD": pack_lod(name, st, e, ppp).encode()
            for (name, st, e, ppp), g in zip(PACKS, groups) if g}


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
        hi = 0
        for idx, (w, h, addr, ctrl) in zip(group, hdrs):
            if (w, h) != (imgs[idx]["w"], imgs[idx]["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}, BDD says {imgs[idx]['w']}x{imgs[idx]['h']}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} (phys {p:X}) outside {start:X}..{end:X}")
            hi = max(hi, p + (cave.packed_bits(imgs[idx]) + 7) // 8)
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
        if hi > end:
            raise SystemExit(f"{name}: payload runs to {hi:X}, slot ends {end:X}")
    for idx, (k, (w, h, addr, ctrl, src)) in L["shared"].items():
        by[idx] = (w, h, addr, ctrl, f"THE PIT's KUNGFU5 {k:02X} ({src})")
    return [by[i] for i in L["order"]]


_PAYLOADS = {}


def irw_holding(phys):
    """(name, start, payload) of the IRW whose written payload holds a physical
    byte.  By payload, not by declared slot: slots nest (SCLAP's still spans
    THE PIT's bank-1 packs), payloads never overlap - makevrom refuses that."""
    if pit._MV is None:
        pit._irw("MK1PT1")          # loads makevrom
    for irw, (s, e, *_r) in pit._MV.CUSTOM_VIDEO_SLOTS.items():
        if not s <= phys < e or not (DATA / irw).exists():
            continue
        name = irw[:-4]
        if name not in _PAYLOADS:
            _PAYLOADS[name] = pit._irw(name)
        start, payload = _PAYLOADS[name]
        if start <= phys < start + len(payload):
            return name, start, payload
    raise SystemExit(f"phys {phys:X} is in no written IRW payload")


def verify_rom(L, hdrs):
    """Decode every record the stage draws back out of the IRW that holds it
    and compare it with KUNGFU1 - LOAD2 has more than one way of writing a
    record that is not what it was given (THE PIT's make_mk1pit.py mask6)."""
    bad = []
    for idx, (w, h, addr, ctrl, src) in zip(L["order"], hdrs):
        name, start, payload = irw_holding(cave.sag_phys(addr))
        try:
            rows, bpp = pit.decode_record(payload, pit.runtime_bit(addr) - start * 8, w, h, ctrl)
        except IndexError:
            bad.append(f"{name}: KUNGFU1 {idx:02X} runs off the IRW")
            continue
        px = L["imgs"][idx]["px"]       # unmasked: a record stored too narrow
        n = sum(1 for y in range(h) for x in range(w) if rows[y][x] != px[y * w + x])
        if n:
            bad.append(f"{name}: KUNGFU1 {idx:02X} ({w}x{h}, {src}) - {n} pixels differ from the source")
    return bad


# --------------------------------------------------------------------------
# Parallax (wshrpar in src/MK1WSHR.ASM).  MK1 moves the whole shrine at the
# fighters' speed.  With the switch on, WOKWAY1 is drawn as three layers:
#
#   BACK   the statue row - statues, columns, balustrade, plinths, obelisks -
#          on its own plane at BACK_RATE, slower than the fighters
#   FLOOR  the walkway and the deck, NOT as blocks: wshr_floor redraws them in
#          BAND_ROWS-row bands straight out of the blocks' own video-ROM data,
#          each band shifted by its own amount (the Cavern water's technique -
#          no new art).  A band's camera is interpolated between the BACK
#          plane's real worldtlx and the fighters': the top band moves exactly
#          with the statue row, so the plinth bases stay planted on the
#          walkway; the ground row moves exactly with the fighters, so their
#          feet stay planted; the rows nearer the viewer run faster.  That is
#          MK2's skewed floor, in steps of BAND_ROWS rows.
#   FRONT  the side gates, at the fighters' speed, drawn over both
#   UNDER  the floor again, flat, at the fighters' speed, drawn BEFORE the
#          bands.  Wherever a band covers - everywhere but a few pixels -
#          it is never seen.  Where one cannot (a gap between two deck ends
#          MK1 hid under a gate: no tile there to carry on), it shows MK1's
#          own pixels in MK1's own place, and a band the queue could not
#          take shows the plain floor rather than the sky
#
# Holes are checked, not hoped for: --check renders every camera from the
# left limit to the right one and fails if any pixel MK1 drew below the
# horizon is left uncovered.
# --------------------------------------------------------------------------
FLOOR_PALS = ("GRND2P", "NUFL_P", "COBLP")
FRONT_PALS = ("NUGATEP",)
BACK_PLANE = 4
BACK_RATE = 0x1C000             # 7/8 of the fighters' speed
# FLOOR_BANDS False (the default since 2026-09-19, at the user's call): the
# floor is MK1's, flat, at the fighters' speed - baklst5 carries every floor
# block and wshr_floor is not assembled.  True brings back the MK2-style
# spreading floor below (written to src/MK1WSHRB.ASM as mk1w_fbands, which
# MK1WSHR.ASM follows) - then --apply and python build.py --asm-only.
FLOOR_BANDS = False
BAND_ROWS = 3
# A back-row block reaching more than this many rows into the floor is part of
# the floor's geometry, not the statue row's: the two perspective side walls at
# each end (48 and 51), which run from the walkway toward the viewer.  Left on
# the back plane, the faster walkway bands slid out from under their diagonal
# and opened a staircase of holes along it; drawn in the bands, each of their
# rows moves with the floor row it stands on.  The plinth bases (6 rows in)
# stay with their statues.
SEAM_ROWS = 2 * BAND_ROWS
# MK1 cropped the floor to its camera: the walkway starts at world x 86 with
# the left limit at 87.  A band that runs ahead of the camera reads past that
# edge (44px at the left limit), so each end of each floor row is carried on
# by one more copy of the fully opaque tile that ends it - the walkway's dirt,
# the deck's cobbles - which just continues the texture out under the gates.
# The same goes for a GAP between two tiles: the walkway stops for 9px at
# x 142..151, which the left gate's inner post hides in MK1; with the walkway
# sliding under the post, the gap walked out from behind it a little further
# in each band - a staircase of holes.  The tile left of a gap is carried on
# into it.  A tile with any transparency (the ramps' diagonals) is never
# copied.


def layer_of(L, b):
    nm = L["pals"][b["pal"]][0]
    return "floor" if nm in FLOOR_PALS else "front" if nm in FRONT_PALS else "back"


def par_layers(L):
    """WOKWAY1 split: {'front': module, 'back': module, 'floor': [blocks]}.
    Modules are re-cropped to their own blocks (world origin wx, wy) and
    their blocks kept in x order, which bsrch1stxb needs."""
    bm, mm = [p for p in L["pairs"] if p[1]["plane"] == 1][0]
    imgs = L["imgs"]
    out = {"floor": []}
    groups = {"front": [], "back": []}
    blks = []
    for b in bm["blocks"]:
        im = imgs[b["hdr"]]
        blks.append(dict(b, wx=mm["x"] + b["rx"], wy=mm["y"] + b["ry"], w=im["w"], h=im["h"],
                         layer=layer_of(L, b)))
    top = min(b["wy"] for b in blks if b["layer"] == "floor")
    for b in blks:
        if FLOOR_BANDS and b["layer"] == "back" and b["wy"] + b["h"] > top + SEAM_ROWS:
            b["layer"] = "floor"
        (out["floor"] if b["layer"] == "floor" else groups[b["layer"]]).append(b)
    out["floor"] = edge_pads(L, out["floor"]) + out["floor"]      # pads first: drawn behind
    groups["back"] = back_pads(L, groups["back"], groups["front"]) + groups["back"]   # pads drawn behind
    out["bands"] = par_bands(L, out)
    for b in out["floor"]:
        b["pieces"] = span_pieces(L, out["bands"], b)
    groups["under"] = [b for b in out["floor"] if not b.get("pad")]    # every candidate, for now
    for k, bl in groups.items():
        x1 = min(b["wx"] for b in bl)
        y1 = min(b["wy"] for b in bl)
        mod = dict(name=k, wx=x1, wy=y1, w=max(b["wx"] + b["w"] for b in bl) - x1,
                   h=max(b["wy"] + b["h"] for b in bl) - y1, blocks=[])
        for b in bl:
            mod["blocks"].append(dict(b, rx=b["wx"] - x1, ry=b["wy"] - y1))
        mod["blocks"].sort(key=lambda b: (b["rx"], b["ry"]))
        out[k] = mod
    return out


def par_model(L):
    """par_layers, with the underlay cut down to the blocks that ever show:
    every camera is rendered without it, and a candidate is kept only if one
    of its own pixels lands on a pixel the other layers leave open.  The
    whole floor drawn twice cost ~28k pixels a frame for a few dozen that
    are ever seen - and DMA time is what this stage has least of."""
    if "_P" in L:
        return L["_P"]
    P = par_layers(L)
    if not FLOOR_BANDS:                  # the flat floor IS the "underlay": all of it
        L["_P"] = P
        return P
    rec = L["rec"]
    cand = P["under"]["blocks"]
    keep = set()
    y_top = min(b["wy"] for b in P["floor"] if layer_of(L, b) == "floor") - rec["worldy"]
    for cam in range(rec["left"], rec["right"] + 1):
        flat = render_layers(L, P, cam, rec["worldy"], par=False).getchannel("A").load()
        bands = render_layers(L, P, cam, rec["worldy"], par="bands").getchannel("A").load()
        for i, b in enumerate(cand):
            if i in keep:
                continue
            im = L["imgs"][b["hdr"]]
            x0, y0 = P["under"]["wx"] + b["rx"] - cam, P["under"]["wy"] + b["ry"] - rec["worldy"]
            if x0 >= SCREEN_W or x0 + im["w"] <= 0:
                continue
            for yy in range(max(0, y_top - y0), im["h"]):
                sy = y0 + yy
                if sy >= SCREEN_H:
                    break
                row = yy * im["w"]
                for xx in range(max(0, -x0), min(im["w"], SCREEN_W - x0)):
                    sx = x0 + xx
                    if flat[sx, sy] and not bands[sx, sy] and \
                            im["px"][row + (im["w"] - 1 - xx if b["z"] & 0x10 else xx)]:
                        keep.add(i)
                        break
                if i in keep:
                    break
    bl = [cand[i] for i in sorted(keep)]
    if bl:
        x1, y1 = min(P["under"]["wx"] + b["rx"] for b in bl), min(P["under"]["wy"] + b["ry"] for b in bl)
        mod = dict(name="under", wx=x1, wy=y1, blocks=[])
        for b in bl:
            mod["blocks"].append(dict(b, rx=P["under"]["wx"] + b["rx"] - x1, ry=P["under"]["wy"] + b["ry"] - y1))
        mod["w"] = max(b["rx"] + b["w"] for b in mod["blocks"])
        mod["h"] = max(b["ry"] + b["h"] for b in mod["blocks"])
        mod["blocks"].sort(key=lambda b: (b["rx"], b["ry"]))
        P["under"] = mod
    else:
        P["under"] = dict(name="under", wx=0, wy=0, w=0, h=0, blocks=[])
    L["_P"] = P
    return P


# The walkway is one featureless tile of dirt: shear inside it cannot be
# seen, and its blits were half the frame's.  It is drawn a whole tile at a
# time at the statue row's speed (the top band's F), so its plinth bases stay
# planted and it costs what the flat stage paid.  Only the deck - the oval,
# the strips' ends, the ramps - and the side walls are drawn band by band.
WHOLE_PALS = ("GRND2P",)


def span_pieces(L, bands, b):
    """[(row in the block, rows, band index)] - how one span is drawn."""
    if L["pals"][b["pal"]][0] in WHOLE_PALS:
        top = next(i for i, (_y, _n, F) in enumerate(bands) if F == 0x10000)
        return [(0, b["h"], top)]
    out = []
    for i, (y0, rows, _F) in enumerate(bands):
        r0 = max(y0, b["wy"]) - b["wy"]
        r1 = min(y0 + rows, b["wy"] + b["h"]) - b["wy"]
        if r0 < r1:
            out.append((r0, r1 - r0, i))
    return out


def edge_pads(L, fl):
    """Copies of fully opaque floor tiles: one past each end of each floor
    row, and one into each gap between two tiles of a row."""
    imgs = L["imgs"]
    solid = lambda b: 0 not in imgs[b["hdr"]]["px"]
    pads = []

    def add(b, wx):
        pad = dict(b, wx=wx, pad=True)
        if not any(q["hdr"] == pad["hdr"] and q["wx"] == wx and q["wy"] == pad["wy"] for q in pads):
            pads.append(pad)

    for y in range(min(b["wy"] for b in fl), max(b["wy"] + b["h"] for b in fl)):
        row = sorted((b for b in fl if b["wy"] <= y < b["wy"] + b["h"]), key=lambda b: b["wx"])
        if solid(row[0]):
            add(row[0], row[0]["wx"] - row[0]["w"])
        last = max(row, key=lambda b: b["wx"] + b["w"])
        if solid(last):
            add(last, last["wx"] + last["w"])
        reach, left = row[0]["wx"] + row[0]["w"], row[0]
        for b in row[1:]:
            if b["wx"] > reach and solid(left) and solid(b):
                add(left, reach)                    # carried on into the gap
            if b["wx"] + b["w"] > reach:
                reach, left = b["wx"] + b["w"], b
    return pads


# The statue row has hairline gaps MK1 kept behind the gates' posts - the
# balustrade stops for 2px at x 155..157 behind the left gate's inner post.
# With the row sliding behind the gates that became a 2px bar of sky at the
# left limit.  A gap this narrow, and ENTIRELY behind a gate in MK1's own
# picture, is closed with a copy of the block left of it, drawn behind,
# placed so its right edge lands on the gap's far side.  Gaps MK1 left in
# plain view are MK1's picture and stay as they are.
BACK_GAP = 4


def opaque_cols(L, bl, y):
    """World x of every opaque pixel the blocks put on world row y."""
    imgs = L["imgs"]
    xs = set()
    for b in bl:
        if b["wy"] <= y < b["wy"] + b["h"]:
            im = imgs[b["hdr"]]
            r = (y - b["wy"]) * im["w"]
            for xx in range(im["w"]):
                if im["px"][r + xx]:
                    xs.add(b["wx"] + (im["w"] - 1 - xx if b["z"] & 0x10 else xx))
    return xs


def back_pads(L, bl, front):
    """Gaps are runs of uncovered PIXELS (a block's own edge columns can be
    transparent), at most BACK_GAP wide, with the statue row on both sides
    and a gate over every pixel of them in MK1.  Each is closed with a copy
    of the block left of it, centred on the gap so its solid middle fills it."""
    imgs = L["imgs"]
    pads = []
    for y in range(min(b["wy"] for b in bl), max(b["wy"] + b["h"] for b in bl)):
        cov = opaque_cols(L, bl, y)
        if not cov:
            continue
        hidden = None
        x = min(cov)
        while x <= max(cov):
            if x in cov:
                x += 1
                continue
            g0 = x
            while x not in cov:
                x += 1
            if x - g0 > BACK_GAP:
                continue
            if hidden is None:
                hidden = opaque_cols(L, front, y)
            if not all(c in hidden for c in range(g0, x)):
                continue
            left = [b for b in bl if b["wy"] <= y < b["wy"] + b["h"] and b["wx"] <= g0 - 1 < b["wx"] + b["w"]
                    and 0 not in imgs[b["hdr"]]["px"][(y - b["wy"]) * b["w"] + b["w"] // 2 - 2:
                                                      (y - b["wy"]) * b["w"] + b["w"] // 2 + 3]]
            if not left:
                continue
            b = left[0]
            wx = (g0 + x) // 2 - b["w"] // 2
            if not any(q["hdr"] == b["hdr"] and q["wx"] == wx and q["wy"] == b["wy"] for q in pads):
                pads.append(dict(b, wx=wx, pad=True))
    return pads


def par_bands(L, P):
    """[(world y0, rows, F)] - F is the band's place between the BACK plane
    (0x10000) and the fighters (0), 16.16, negative below the ground row."""
    fl = P["floor"]
    y_lo = min(b["wy"] for b in fl if layer_of(L, b) == "floor")    # the walkway's top
    y_hi = max(b["wy"] + b["h"] for b in fl)
    y_up = min(b["wy"] for b in fl)                                 # the side walls' tops
    g2 = ground_y(L) * 2
    top2 = y_lo * 2 + (min(BAND_ROWS, y_hi - y_lo) - 1)       # band 0's centre, doubled
    out = [(y_up, y_lo - y_up, 0x10000)] if y_up < y_lo else []    # above the floor: the back plane
    for y0 in range(y_lo, y_hi, BAND_ROWS):
        rows = min(BAND_ROWS, y_hi - y0)
        c2 = y0 * 2 + rows - 1
        out.append((y0, rows, ((g2 - c2) << 16) // (g2 - top2)))
    return out


def plane_x(L, cam, rate):
    """A plane's worldtlx integer, as the scroller leaves it (floor, like sra)."""
    s = L["rec"]["start"]
    return s + (((cam - s) * rate) >> 17)


def band_cam(L, cam, F):
    """The x a band is drawn from: the fighters' camera plus F of the way to
    the BACK plane's.  The same integer steps as wshr_floor."""
    return cam + (((plane_x(L, cam, BACK_RATE) - cam) * F) >> 16)


def render_layers(L, P, cam_x, cam_y, par=True):
    """The shrine plane (WOKWAY1, or its three layers) on a transparent
    screen - alpha is coverage, which is what the hole scan reads."""
    from PIL import Image
    imgs, pals = L["imgs"], L["pals"]
    scr = Image.new("RGBA", (SCREEN_W, SCREEN_H), (0, 0, 0, 0))
    tiles = L.setdefault("_tiles", {})

    def tile(b):
        key = (b["hdr"], b["pal"], bool(b["z"] & 0x10))
        if key not in tiles:
            im = imgs[b["hdr"]]
            p = pals[b["pal"]][1]
            t = Image.new("RGBA", (im["w"], im["h"]))
            t.putdata([(0, 0, 0, 0) if v == 0 else pit.rgb(p[v]) + (255,) for v in im["px"]])
            if key[2]:
                t = t.transpose(Image.FLIP_LEFT_RIGHT)
            tiles[key] = t
        return tiles[key]

    if par == "under":                   # the underlay alone, for the scan
        mod = P["under"]
        for b in mod["blocks"]:
            _paste_clip(scr, tile(b), mod["wx"] + b["rx"] - cam_x, mod["wy"] + b["ry"] - cam_y)
        return scr
    if not par:
        bm, mm = [p for p in L["pairs"] if p[1]["plane"] == 1][0]
        for b in bm["blocks"]:
            t = tile(b)
            scr.alpha_composite(t, (mm["x"] + b["rx"] - cam_x, mm["y"] + b["ry"] - cam_y)) \
                if -t.width < mm["x"] + b["rx"] - cam_x < SCREEN_W else None
        return scr

    def paste(t, x, y, box=None):
        if box:
            t = t.crop(box)
        if -t.width < x < SCREEN_W and -t.height < y < SCREEN_H:
            scr.alpha_composite(t, (x, y)) if x >= 0 and y >= 0 else _paste_clip(scr, t, x, y)

    if par != "bands":                   # "bands" = without the underlay
        mod = P["under"]
        for b in mod["blocks"]:
            paste(tile(b), mod["wx"] + b["rx"] - cam_x, mod["wy"] + b["ry"] - cam_y)
    bands = P["bands"]
    for b in (P["floor"] if FLOOR_BANDS else []):    # span by span, as wshr_floor walks them
        for r0, n, i in b["pieces"]:
            bc = band_cam(L, cam_x, bands[i][2])
            paste(tile(b), b["wx"] - bc, b["wy"] + r0 - cam_y, (0, r0, b["w"], r0 + n))
    bx = plane_x(L, cam_x, BACK_RATE)
    for k, cx in (("back", bx), ("front", cam_x)):
        mod = P[k]
        for b in mod["blocks"]:
            paste(tile(b), mod["wx"] + b["rx"] - cx, mod["wy"] + b["ry"] - cam_y)
    return scr


def _paste_clip(scr, t, x, y):
    cx, cy = max(0, -x), max(0, -y)
    t = t.crop((cx, cy, t.width, t.height))
    if t.width > 0 and t.height > 0:
        scr.alpha_composite(t, (x + cx, y + cy))


def hole_scan(L, P, step=1, under=True):
    """Every camera from the left limit to the right one: pixels MK1 covers
    in the floor's rows that the parallax layers leave open.  [(cam, count)].
    under=False scans without the underlay: what shows THROUGH to it."""
    rec = L["rec"]
    # Only the floor's own rows: above them the statue row is SUPPOSED to
    # uncover sky and trees as it slides - that is the parallax.  The floor
    # is solid wall to wall in MK1, so any gap in its rows is a hole.
    y_top = min(b["wy"] for b in P["floor"] if layer_of(L, b) == "floor") - rec["worldy"]
    bad = []
    for cam in list(range(rec["left"], rec["right"] + 1, step)) + [rec["right"]]:
        flat = render_layers(L, P, cam, rec["worldy"], par=False).getchannel("A")
        par = render_layers(L, P, cam, rec["worldy"], par=True if under else "bands").getchannel("A")
        a = flat.crop((0, y_top, SCREEN_W, SCREEN_H)).tobytes()
        b = par.crop((0, y_top, SCREEN_W, SCREEN_H)).tobytes()
        n = sum(1 for p, q in zip(a, b) if p and not q)
        if n:
            bad.append((cam, n))
    return bad


def row_bits(L, hdr):
    """Bits from a record's SAG to the start of each of its rows, walked out
    of the IRW that holds it the way the DMA reads it: a compressed row is an
    8-bit [trail:lead] header plus the pixels between them.  Proved by
    decoding every row FROM its offset and comparing it with the art - a
    band starts its blit at any row, so one wrong offset draws garbage."""
    w, h, addr, ctrl = hdr[:4]
    name, start, payload = irw_holding(cave.sag_phys(addr))
    base = pit.runtime_bit(addr) - start * 8
    bpp = (ctrl >> 12) & 7 or 8
    comp = bool(ctrl & 0x80)
    lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    offs, pos = [], 0
    for _ in range(h):
        offs.append(pos)
        if comp:
            j = (base + pos) // 8
            v = int.from_bytes(payload[j:j + 4].ljust(4, b"\0"), "little") >> ((base + pos) % 8)
            lead, trail = (v & 15) << lm, ((v >> 4) & 15) << tm
            pos += 8 + max(0, w - lead - trail) * bpp
        else:
            pos += w * bpp
    return offs, (name, payload, base)


def check_row_bits(hdr, img, offs, where):
    name, payload, base = where
    w, h, _addr, ctrl = hdr[:4]
    for r, off in enumerate(offs):
        rows, _b = pit.decode_record(payload, base + off, w, 1, ctrl)
        if rows[0] != list(img["px"][r * w:(r + 1) * w]):
            return f"{name}: row {r} of a {w}x{h} floor record does not decode from its offset"
    return None


def par_asm(L, hdrs, P):
    """The parallax tables (wshrpar, src/MK1WSHR.ASM): equate lines, data
    lines, and any problem found."""
    o, bad = [], []
    w = o.append
    hidx = {idx: i for i, idx in enumerate(L["order"])}

    def module(lab, mod):
        w(f"{lab}BLKS:")
        for b in mod["blocks"]:
            z = b["z"] & 0xFFF0
            if b.get("pad"):
                z = max(0, z - 0x100)            # one step behind: shows only in the gap
            flags = z | (b["pal"] & 0xF) | 0x40
            hw = hidx[b["hdr"]] + ((b["pal"] >> 4) << 12)
            w(f"\t.word\t{h4(flags)},{b['rx']},{b['ry']},{h4(hw)}")
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{mod['w']},{mod['h']},{len(mod['blocks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, MK1WSHDRS, MK1WSPALS")
        w("")

    w("")
    w("; ---- parallax (wshrpar): statue row, floor bands, gates, underlay ----")
    module("WSBACK", P["back"])
    module("WSFRONT", P["front"])
    module("WSUNDER", P["under"])
    eq = [f"mk1w_fbands\t.set\t{1 if FLOOR_BANDS else 0}\t\t; 0: the floor flat (MK1's), 1: wshr_floor's bands",
          f"mk1w_back_rate\t.set\t{h4(BACK_RATE, 6)}\t; the statue row's plane (4)",
          f"mk1w_mb_x\t.set\t{P['back']['wx']}", f"mk1w_mb_y\t.set\t{P['back']['wy']}",
          f"mk1w_mf_x\t.set\t{P['front']['wx']}", f"mk1w_mf_y\t.set\t{P['front']['wy']}",
          f"mk1w_mu_x\t.set\t{P['under']['wx']}", f"mk1w_mu_y\t.set\t{P['under']['wy']}"]
    if not FLOOR_BANDS:
        return eq, o, bad
    bands = P["bands"]
    w("WSFBANDS:\t\t\t; F per band (16.16: 1 = the statue row, 0 = the fighters)")
    for y0, rows, F in bands:
        w(f"\t.long\t{h4(F, 8)}\t\t; world rows {y0}..{y0 + rows - 1}")
    w("")
    by_hdr = dict(zip(L["order"], hdrs))
    tabs = {}
    for b in P["floor"]:
        if b["hdr"] in tabs:
            continue
        offs, where = row_bits(L, by_hdr[b["hdr"]])
        msg = check_row_bits(by_hdr[b["hdr"]], L["imgs"][b["hdr"]], offs, where)
        if msg:
            bad.append(f"KUNGFU1 {b['hdr']:02X}: {msg}")
        tabs[b["hdr"]] = offs
    w("WSFSPANS:\t\t\t; header, palette, row offsets, pieces / world x, flip")
    for k, b in enumerate(P["floor"]):
        w(f"\t.long\tMK1WSHDRS+{hidx[b['hdr']] * 80},{PAL_PREFIX}{L['pals'][b['pal']][0]},WSFR_{b['hdr']:02X},WSFP_{k}"
          + ("\t; pad" if b.get("pad") else ""))
        w(f"\t.word\t{b['wx']},{1 if b['z'] & 0x10 else 0}")
    w("")
    # A background palette is only loaded while a block that uses it is on
    # a display list, and the floor's blocks no longer are (the underlay is
    # a few end pieces).  mk1wshr_calla loads these itself, as
    # setup_floor_info loads a skewed floor's - without it the walkway was
    # never drawn and at the start camera no floor at all.
    w("WSFPALS:\t\t\t; every palette a floor span uses, loaded by the calla")
    for nm in dict.fromkeys(L["pals"][b["pal"]][0] for b in P["floor"]):
        w(f"\t.long\t{PAL_PREFIX}{nm}")
    w("\t.long\t0")
    w("")
    w("; pieces: count, then [row in the block, rows, world y, band]")
    for k, b in enumerate(P["floor"]):
        w(f"WSFP_{k}:")
        w(f"\t.word\t{len(b['pieces'])}")
        for r0, n, i in b["pieces"]:
            w(f"\t.word\t{r0},{n},{b['wy'] + r0},{i}")
    w("")
    for idx, offs in tabs.items():
        w(f"WSFR_{idx:02X}:")
        for i in range(0, len(offs), 8):
            w("\t.long\t" + ",".join(str(v) for v in offs[i:i + 8]))
    margin = max(abs(band_cam(L, c, F) - c) for c in (L["rec"]["left"], L["rec"]["right"]) for _y, _r, F in bands)
    eq += [f"mk1w_nband\t.set\t{len(bands)}",
          f"mk1w_nspan\t.set\t{len(P['floor'])}",
          f"mk1w_fmargin\t.set\t{margin + 1}\t\t; furthest a band runs from the fighters' camera"]
    return eq, o, bad


def h4(v, d=4):
    return "0%0*XH" % (d, v & ((1 << (4 * d)) - 1))


PAL_PREFIX = "MK1W_"


def build_asm(L, hdrs):
    rec = L["rec"]
    o = []
    w = o.append
    w("; THE WARRIOR SHRINE (MK1) - GENERATED by tools/make_mk1shrine.py --apply.  Do not hand-edit.")
    w("; Art: data/KUNGFU1.BDB/.BDD, proven identical to MK1 rev 5.0's shipped modules.")
    w("; Layout: MK1's stage record FFCB7160 (C:\\MAME\\roms\\mk.zip), read by the tool.")
    w("")
    w("; ---- layout ----")
    w(f"mk1w_erase\t.set\t{h4(rec['erase'])}\t\t; MK1's autoerase - the night sky")
    w(f"mk1w_ground\t.set\t{ground_y(L)}\t\t; MK1's {rec['ground']} {GROUND_NUDGE:+d} (MK2 fighters stand lower on the anchor)")
    w(f"mk1w_worldy\t.set\t{rec['worldy']}")
    w(f"mk1w_start\t.set\t{rec['start']}")
    w(f"mk1w_left\t.set\t{rec['left']}")
    w(f"mk1w_right\t.set\t{rec['right']}")
    w(f"mk1w_shad_fast\t.set\t{SHADOW_FAST}")
    eq, par_lines, _bad = par_asm(L, hdrs, par_model(L))
    o.extend(eq)
    for bm, mm in L["pairs"]:
        n = mm["plane"]
        w(f"mk1w_m{n}_x\t.set\t{mm['x']}\t\t; {bm['name']} on plane {n}")
        w(f"mk1w_m{n}_y\t.set\t{mm['y']}")
        w(f"mk1w_rate{n}\t.set\t{h4(mm['rate'], 6)}")
    w("")
    w("\t.data")
    w("")
    w("MK1WSHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["order"]):
        w(f"\t.word\t{hw},{hh}\t\t; KUNGFU1 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["order"])}
    for bm, _mm in L["pairs"]:
        lab = bm["name"].upper()
        w(f"{lab}BLKS:")
        for b in bm["blocks"]:
            flags = (b["z"] & 0xFFF0) | (b["pal"] & 0xF) | 0x40
            hw = hidx[b["hdr"]] + ((b["pal"] >> 4) << 12)
            w(f"\t.word\t{h4(flags)},{b['rx']},{b['ry']},{h4(hw)}")
        w("\t.word\t0FFFFH")
        w(f"{lab}BMOD:")
        w(f"\t.word\t{bm['w']},{bm['h']},{len(bm['blocks'])}\t;x size, y size, #blocks")
        w(f"\t.long\t{lab}BLKS, MK1WSHDRS, MK1WSPALS")
        w("")
    w("MK1WSPALS:")
    for nm, _words in L["pals"]:
        w(f"\t.long\t{PAL_PREFIX}{nm}")
    w("")
    for nm, words in L["pals"]:
        w(f"{PAL_PREFIX}{nm}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    o.extend(par_lines)
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------
# preview
# --------------------------------------------------------------------------
def render(L, sky, cam_x, cam_y, show_ground=True, par=False):
    from PIL import Image, ImageDraw
    rec = L["rec"]
    rgb = pit.rgb
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), rgb(rec["erase"]))
    imgs, pals = L["imgs"], L["pals"]
    moon = sky["moon"]
    t = Image.new("RGBA", (moon["w"], moon["h"]))
    t.putdata([(0, 0, 0, 0) if v == 0 else rgb(sky["moon_pal"][v]) + (255,) for v in moon["px"]])
    scr.paste(t, (moon["x"], moon["y"]), t)
    tiles = {}
    for bm, mm in sorted(L["pairs"], key=lambda p: -p[1]["plane"]):     # back to front
        if par and mm["plane"] == 1:
            lay = render_layers(L, par_model(L), cam_x, cam_y)
            scr.paste(lay, (0, 0), lay)
            continue
        px_cam = rec["start"] + (cam_x - rec["start"]) * mm["rate"] // 0x20000
        for b in bm["blocks"]:
            key = (b["hdr"], b["pal"], bool(b["z"] & 0x10))
            if key not in tiles:
                im = imgs[b["hdr"]]
                p = pals[b["pal"]][1]
                tt = Image.new("RGBA", (im["w"], im["h"]))
                tt.putdata([(0, 0, 0, 0) if v == 0 else rgb(p[v]) + (255,) for v in im["px"]])
                if key[2]:
                    tt = tt.transpose(Image.FLIP_LEFT_RIGHT)
                tiles[key] = tt
            tt = tiles[key]
            scr.paste(tt, (mm["x"] + b["rx"] - px_cam, mm["y"] + b["ry"] - cam_y), tt)
    if show_ground:
        d = ImageDraw.Draw(scr)
        gy = ground_y(L) - cam_y
        d.line([(0, gy), (SCREEN_W, gy)], fill=(255, 255, 0))
    return scr


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--parts", action="store_true", help="write the pack BDB/BDD and LODs")
    ap.add_argument("--apply", action="store_true", help="write src/MK1WSHRB.ASM from the LOAD2 snapshots")
    ap.add_argument("--check", action="store_true", help="fail if anything generated is stale")
    ap.add_argument("--preview", nargs="*", metavar="X", help="camera x values (default: left, start, right)")
    ap.add_argument("--par", action="store_true", help="--preview with the parallax layers (wshrpar 1)")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    L = layout()
    rec = L["rec"]
    rc = 0

    if a.report or not any((a.parts, a.apply, a.check, a.preview is not None)):
        print(f"MK1 FFCB7160: erase {rec['erase']:04X} ground {rec['ground']} (MK2 {ground_y(L)}) "
              f"camera y {rec['worldy']} x {rec['start']} limits {rec['left']}..{rec['right']}; "
              f"moon on MK1 plane {rec['moon_plane']}")
        for bm, mm in L["pairs"]:
            print(f"  plane {mm['plane']}  {bm['name']:8s} {mm['w']}x{mm['h']} at ({mm['x']},{mm['y']}) "
                  f"rate {mm['rate']:06X}  {len(bm['blocks'])} blocks")
        print(f"{len(L['order'])} images: {len(L['shared'])} reuse THE PIT's SAGs "
              f"({', '.join('%02X<-%02X' % (o, k) for o, (k, _h) in L['shared'].items())}), {len(L['new'])} new")
        groups, used = deal(L)
        for (name, s, e, ppp), g, u in zip(PACKS, groups, used):
            print(f"  {name}  {s:06X}..{e:06X}  PPP {ppp}  {len(g):2d} images  ~{u // 8:6d} of {e - s:6d} bytes"
                  + (f"  ({', '.join('%02X' % i for i in g)})" if ppp else ""))

    parts = part_files(L)
    lods = lod_files(L)
    if a.parts:
        for fn, data in {**parts, **lods}.items():
            p = DATA / fn
            if not p.exists() or not pit.same_file(p, fn, data):
                p.write_bytes(pit.dos(fn, data))
                print(f"wrote data/{fn}")
    if a.check:
        stale = [fn for fn, d in {**parts, **lods}.items()
                 if not (DATA / fn).exists() or not pit.same_file(DATA / fn, fn, d)]
        if stale:
            print("THE WARRIOR SHRINE packs stale (run tools/make_mk1shrine.py --parts, then python build.py): "
                  + ", ".join(stale))
            rc = 1

    if a.apply or a.check:
        hdrs = merged_headers(L)
        problems = verify_rom(L, hdrs)
        if problems:
            print("THE WARRIOR SHRINE: the video ROM does not hold what it was given:")
            for msg in problems:
                print("  " + msg)
            return 1
        P = par_model(L)
        _eq, _lines, problems = par_asm(L, hdrs, P)
        holes = hole_scan(L, P)
        if holes:
            problems.append(f"the parallax layers leave floor holes at {len(holes)} cameras "
                            f"(first {holes[0][0]}: {holes[0][1]} px)")
        if problems:
            print("THE WARRIOR SHRINE parallax (wshrpar):")
            for msg in problems:
                print("  " + msg)
            return 1
        text = build_asm(L, hdrs)
        old = OUT_ASM.read_text(encoding="latin-1") if OUT_ASM.exists() else ""
        if a.apply and old != text:
            OUT_ASM.write_text(text, encoding="latin-1")
            for s in ("MK1WSHR.OBJ", "mk2.out"):
                (SRC / s).unlink(missing_ok=True)
            print("wrote src/MK1WSHRB.ASM")
        elif a.check:
            if old != text:
                print("src/MK1WSHRB.ASM is stale (run tools/make_mk1shrine.py --apply)")
                rc = 1
            elif rc == 0:
                print("THE WARRIOR SHRINE packs and tables are current (KUNGFU1 == MK1's shipped shrine)")

    if a.preview is not None:
        from PIL import Image
        sky = pit.read_sky(L["rom"])
        cams = [int(v) for v in a.preview] or [rec["left"], rec["start"], rec["right"]]
        shots = [render(L, sky, x, rec["worldy"], par=a.par) for x in cams]
        sheet = Image.new("RGB", ((SCREEN_W + 4) * len(shots), SCREEN_H), (0, 255, 0))
        for i, s in enumerate(shots):
            sheet.paste(s, (i * (SCREEN_W + 4), 0))
        out = ROOT / "tmp" / "mk1shrine" / "preview.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(out)
        print(f"wrote {out.relative_to(ROOT)}  cameras {cams}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
