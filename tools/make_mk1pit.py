#!/usr/bin/env python3
r"""THE PIT - MK1's bridge stage, the whole shaft, and its uppercut fatality.

MK2 already has MK1's PIT BOTTOM (curback 00Ah, src/MK1PITBG.ASM): the spikes,
the corpses and the lower shaft, cut out of data/MK1PIT.BDB.  This imports the
REST of MK1's Pit as its own stage, THE PIT (curback 01Ah, src/MK1PTOP.ASM):
the bridge the fighters stand on, the spiked pillars all the way down, and the
night sky, so an uppercut in FINISH HIM throws the loser off the bridge and the
camera follows him 700 rows down to the bottom the other stage is made of.

EVERYTHING HERE IS READ, NOT REMEMBERED.  Two sources:

  data/KUNGFU5.BDB/.BDD  MK1's own background file for the Pit, from the leak.
                         bridge1 is ONE 1143x915 module - bridge, pillars and
                         pit floor in a single canvas - which is why MK1 needed
                         no cut.  MK1PIT.BDB is a crop of the same canvas.
  C:\MAME\roms\mk.zip    MK1 rev 5.0 (T-unit).  Its stage table is FFCA7E30;
                         entry 3, FFCB8690, is THE PIT: ground 264, camera y
                         45, x 264, limits 18..744, both modules at scroll
                         rate 020000h.  Its calla FFCB8950 builds the sky:
                           FFCB9C90  ten drifting clouds (three rows, three
                                     speeds, wrapped 23Fh left past x 18Fh)
                           FFCB8CE0  the six-piece rock outcrop, bottom left
                           FFCB8E40  the moon
                           FFCB8F10  one silhouette - a sleigh, a witch, a
                                     UFO... - crossing the moon, twice
                         All of it is m_noscroll: MK1 keeps the sky nailed to
                         the screen while the camera pans down the shaft.

A capture of the real thing (tools/run_mk1_pit_capture.ps1) confirms the fall
is a pan, not a cut: worldtly 45 -> 760 over ~40 frames, settling at 752.

WHAT GOES WHERE

  --sky     data/MK1PSKY.IMG (moon, rocks, clouds - 6bpp, three palettes) and
            data/MK1PFLY.IMG (the eight silhouettes - 2bpp).  Pieces keep MK1's
            anipoints verbatim, so `anchor - anipoint` rebuilds each cloud.
  --parts   The bridge and upper shaft: every KUNGFU5 block above MK1PIT's crop.
            Images whose PIXELS already sit in MK1PIT (TPLHDRS) are reused by
            SAG; only the rest are dealt first-fit-decreasing into PACKS,
            data/MK1PTn.BDB/.BDD, one fixed video-ROM slot each - no free run
            is big enough for all of it (make_mk3cave.py's technique).
  --apply   src/MK1PTOPB.ASM: layout equates, MK1PTHDRS (merged from TPLHDRS
            and the tmp/load2/BGNDTBL.PTn snapshots), MK1PTOPBLKS/BMOD, the
            four sky palettes and MK1's sky tables.
  --check   all of the above compared instead of written (Phase D).
  --preview renders screens from the same constants: tmp/mk1pit/preview.png.

COORDINATES.  World = MK1's own: world = KUNGFU5 canvas - (221, 907), which
puts bridge1's top-left at (0,112) exactly where FFCB8690 places it.  The
Pit Bottom modules are laid in the same world by matching their blocks'
pixels against KUNGFU5 (FIT_BOTTOM), then the stage's own nudges.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
import zipfile
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk3cave as cave  # noqa: E402  (BDD/BDB readers, LOAD2 size model)

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = ROOT / "src"
LOAD2 = ROOT / "tmp" / "load2"
OUT_ASM = SRC / "MK1PTOPB.ASM"
SKY_IMG = DATA / "MK1PSKY.IMG"
FLY_IMG = DATA / "MK1PFLY.IMG"
ROM_ZIP = Path(r"C:\MAME\roms\mk.zip")
SCREEN_W, SCREEN_H = 400, 254

# --------------------------------------------------------------------------
# Video ROM.  Physical addresses, end exclusive.  Mirrored in makevrom.py
# CUSTOM_VIDEO_SLOTS and each LOD's ***> line.
# --------------------------------------------------------------------------
PACKS = [
    # name      start     end        donor slot end pulled back to `start`
    ("MK1PT1", 0xBE9620, 0xBEDA20),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK1PT2", 0xBED770, 0xBF0D70),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK1PT3", 0xBE5A00, 0xBE8600),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK1PT4", 0xBF61D0, 0xBF7FD0),   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
]
# The sky's 6bpp records (moon, rocks, cloud pieces) are dealt the same way.
# NOT JCLOGO's guard: clip41 (MKDISP.ASM) treats any flipped piece with a SAG
# in 0x728000..0x72E140 as a Cage logo piece.
SKY_PACKS = [
    ("MK1PSK1", 0xBFC2E0, 0xBFECE0),  # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK1PSK2", 0x732D50, 0x734750),  # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK1PSK3", 0x9FE800, 0x9FFE00),  # SAHELI3  (payload ends 0x9FE4F0)
    ("MK1PSK4", 0xBE1A20, 0xBE2A20),  # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
    ("MK1PSK5", 0xBFEB10, 0xBFF710),  # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
]
FLY_PACK = ("MK1PFLY", 0xBFF090, 0xBFF690)   # repacked 2026-09-17 (SHASLAM), slot size kept so the deal is unchanged
PACK_MARGIN = 0.96


def lod_address(phys: int) -> str:
    """***> line: bank 0 = 02000000h + phys*8; bank 1 = 02000000h + (phys-800000h)*8, ',1'."""
    if phys >= 0x800000:
        return "%X,1" % (0x2000000 + (phys - 0x800000) * 8)
    return "%X" % (0x2000000 + phys * 8)


# --------------------------------------------------------------------------
# MK1 anchors (C:\MAME\roms\mk.zip, rev 5.0).  Each is checked when read.
# --------------------------------------------------------------------------
BASE = 0xFF800000
IROM = 0x02000000
MK1_STAGES = 0xFFCA7E30
PIT_MOD = 0xFFCB8690
PIT_CALLA = 0xFFCB8950
CLOUD_PROC = 0xFFCB9C90
CLOUD_TAB = 0xFFCB9650      # .long frame / .word x,y, 0-terminated
CLOUD_VEL = 0xFFCB98F0      # .word oxvel per cloud, same order
ROCK_OBJ = 0xFFCB8CE0       # img, pal, flags, x, y
ROCK_LIST = 0xFFCB8D60      # piece images, 0-terminated
ROCK_XY_AT = 0xFFCB8A80     # MOVI 00BB0000h,A4  (y:x)
MOON_OBJ = 0xFFCB95D0
FLY_OBJ = 0xFFCB9450
FLY_LIST = 0xFFCB94D0       # 8 images, randu(8)
CANVAS_TO_WORLD = (221, 907)

# fixed immediates in the two processes, each checked against its opcode
IMMEDIATES = {
    "cloud_wrap_x": (0xFFCBA680, 0x0B42, 0x18F, "cmpi"),     # CMPI 18Fh,A2
    "cloud_wrap_dx": (0xFFCBA700, 0x09C0, 0x23F, "movi"),    # MOVI 23Fh,A0 ; NEG
    "cloud_tick": (0xFFCBA600, 0x09C0, 0x8, "movi"),         # MOVI 8h,A0 ; prcslp
    "fly_first": (0xFFCB8F10, 0x09C0, 0x20, "movi"),         # MOVI 20h,A0 ; prcslp
    "fly_end_x": (0xFFCB91D0, 0x0B40, 0x18F, "cmpi"),        # CMPI 18Fh,A0
    "fly_restart_x": (0xFFCB9220, 0x09C0, -0x46, "movi"),    # MOVI FFBAh,A0
    "fly_gap": (0xFFCB9290, 0x09C0, 0x120, "movi"),          # MOVI 120h,A0 ; prcslp
}
FLY_XVEL = (0xFFCB9090, 0x09E0, 0x20000)                      # MOVI 20000h,A0 (32-bit)
FLY_PASSES = (0xFFCB9150, 0x184A, 2)                          # MOVK 2h,A10


class MK1:
    def __init__(self, path: Path = ROM_ZIP):
        if not path.exists():
            raise SystemExit(f"{path} missing - MK1 rev 5.0 (MAME `mk`) is the source of the sky")
        with zipfile.ZipFile(path) as z:
            ev, od = z.read("mkt-uj12.bin"), z.read("mkt-ug12.bin")
            p = bytearray(len(ev) * 2)
            p[0::2], p[1::2] = ev, od
            self.p = bytes(p)
            chip = 0x80000
            groups = [("ug14", "uj14", "ug19", "uj19"), ("ug16", "uj16", "ug20", "uj20"),
                      ("ug17", "uj17", "ug22", "uj22")]
            g = bytearray(chip * 12)
            for gi, grp in enumerate(groups):
                for lane, nm in enumerate(grp):
                    g[gi * chip * 4 + lane:(gi + 1) * chip * 4:4] = z.read("mkt-%s.bin" % nm)
            self.g = bytes(g)

    def o(self, bit):
        return (bit - BASE) // 8

    def w(self, bit):
        return struct.unpack_from("<H", self.p, self.o(bit))[0]

    def sw(self, bit):
        return struct.unpack_from("<h", self.p, self.o(bit))[0]

    def l(self, bit):
        return struct.unpack_from("<I", self.p, self.o(bit))[0]

    def image(self, bit):
        """MK1 record: .word W,H,anix,aniy / .long SAG (first of a group: + .long pal)."""
        w, h = self.w(bit), self.w(bit + 16)
        if not (0 < w <= 512 and 0 < h <= 512):
            raise SystemExit(f"MK1 {bit:08X}: not an image record ({w}x{h})")
        sag = self.l(bit + 64)
        pos = sag - IROM
        px = bytearray(w * h)
        g = self.g
        for i in range(w * h):
            v = 0
            q = pos + i * 6
            for b in range(6):
                v |= ((g[(q + b) >> 3] >> ((q + b) & 7)) & 1) << b
            px[i] = v
        return dict(addr=bit, w=w, h=h, ax=self.sw(bit + 32), ay=self.sw(bit + 48), px=bytes(px))

    def palette(self, bit):
        n = self.w(bit)
        if not 1 <= n <= 256:
            raise SystemExit(f"MK1 {bit:08X}: not a palette")
        return [self.w(bit + 16 * (i + 1)) for i in range(n)]

    def piece_list(self, bit):
        out = []
        while (v := self.l(bit)) != 0:
            out.append(v)
            bit += 32
        return out

    def checked(self, at, opcode, want=None):
        op = self.w(at)
        if op != opcode:
            raise SystemExit(f"MK1 {at:08X}: opcode {op:04X}, expected {opcode:04X} - wrong ROM revision?")
        if opcode == 0x184A:                       # MOVK k,A10
            return ((op >> 5) & 31) or 32
        v = self.sw(at + 16)
        if opcode in (0x0B42, 0x0B40):             # CMPI: stored one's complement
            v = ~v & 0xFFFF
        if want is not None and v != (want & 0xFFFF if want >= 0 else want):
            if not (want < 0 and v == want):
                raise SystemExit(f"MK1 {at:08X}: immediate {v:X}, expected {want:X}")
        return want if want is not None else v


def read_sky(rom: MK1):
    """Everything the calla at FFCB8950 builds, straight out of the ROM."""
    if rom.l(MK1_STAGES + 3 * 32) != PIT_MOD:
        raise SystemExit("MK1 stage table entry 3 is not FFCB8690 - wrong ROM revision?")
    if rom.l(PIT_MOD + 96) != PIT_CALLA:
        raise SystemExit("THE PIT's calla moved - wrong ROM revision?")
    for name, (at, op, want, _kind) in IMMEDIATES.items():
        rom.checked(at, op, want)
    if rom.w(FLY_XVEL[0]) != FLY_XVEL[1] or rom.l(FLY_XVEL[0] + 16) != FLY_XVEL[2]:
        raise SystemExit("MK1 flyer velocity immediate moved")
    if rom.checked(FLY_PASSES[0], FLY_PASSES[1]) != FLY_PASSES[2]:
        raise SystemExit("MK1 flyer pass count moved")

    clouds, frames = [], {}
    a, k = CLOUD_TAB, 0
    while (fr := rom.l(a)) != 0:
        x, y = rom.sw(a + 32), rom.sw(a + 48)
        vel = rom.w(CLOUD_VEL + 16 * k)
        if fr not in frames:
            frames[fr] = [rom.image(p) for p in rom.piece_list(fr)]
        clouds.append(dict(frame=fr, x=x, y=y, vel=vel))
        a += 64
        k += 1
    cloud_pal = rom.l(next(iter(frames.values()))[0]["addr"] + 96)

    def obj(at):
        return dict(img=rom.l(at), pal=rom.l(at + 32), x=rom.sw(at + 80), y=rom.sw(at + 96))

    moon, rock, fly = obj(MOON_OBJ), obj(ROCK_OBJ), obj(FLY_OBJ)
    if rom.w(ROCK_XY_AT) != 0x09E4:
        raise SystemExit("MK1 rock anchor immediate moved")
    rxy = rom.l(ROCK_XY_AT + 16)
    rock["x"], rock["y"] = rxy & 0xFFFF, rxy >> 16
    rocks = [rom.image(p) for p in rom.piece_list(ROCK_LIST)]
    flyers = [rom.image(rom.l(FLY_LIST + 32 * i)) for i in range(8)]
    return dict(
        clouds=clouds, frames=frames, cloud_pal=rom.palette(cloud_pal),
        moon=dict(rom.image(moon["img"]), x=moon["x"], y=moon["y"]), moon_pal=rom.palette(moon["pal"]),
        rocks=rocks, rock_xy=(rock["x"], rock["y"]), rock_pal=rom.palette(rock["pal"]),
        flyers=flyers, fly_xy=(fly["x"], fly["y"]), fly_src_pal=rom.palette(fly["pal"]),
        imm={k: v[2] for k, v in IMMEDIATES.items()},
    )


# --------------------------------------------------------------------------
# IMG writer (the format make_caveyes_img.py writes; LOAD2 reads it)
# --------------------------------------------------------------------------
LIB_HDR = struct.Struct("<HHIHHHHH4sHHH")
IMAGE = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")
NUMDEFPAL = 3
IMG_VERSION = 0x062E


def build_img(images, palettes):
    """images: [(name, anix, aniy, w, h, px, palindex)]; palettes: [(name, bits, words)]."""
    out = bytearray(LIB_HDR.size)
    pal_osets = []
    for _nm, _bits, words in palettes:
        pal_osets.append(len(out))
        out += struct.pack("<%dH" % len(words), *words)
    data_osets = []
    for _nm, _ax, _ay, w, h, px, _pi in images:
        data_osets.append(len(out))
        stride = (w + 3) & ~3
        for y in range(h):
            out += px[y * w:(y + 1) * w] + bytes(stride - w)
    oset = len(out)
    for (nm, ax, ay, w, h, _px, pi), do in zip(images, data_osets):
        out += IMAGE.pack(nm.encode("ascii"), 0, ax & 0xFFFF, ay & 0xFFFF, w, h, pi + NUMDEFPAL,
                          do, 0, 0, 0, 0, 0xFFFF, 0, 0xFFFF, 0xFFFF)
    for (nm, bits, words), po in zip(palettes, pal_osets):
        out += PALETTE.pack(nm.encode("ascii"), 0, bits, len(words), po, 0, 0, 0, 0, 0)
    LIB_HDR.pack_into(out, 0, len(images), len(palettes) + NUMDEFPAL, oset, IMG_VERSION,
                      0, 0, 0, 0xABCD, b"\0\0\0\0", 0, 0, 0)
    return bytes(out)


CLOUD_NAMES = {}      # frame address -> base name, assigned in table order


def sky_images(sky):
    """The two IMG files' contents, in a fixed order, plus a name map."""
    six, names = [], {}
    six.append(("PITMOON", 0, 0, sky["moon"], 0))
    for i, im in enumerate(sky["rocks"]):
        six.append((f"PITROCK{i + 1}", im["ax"], im["ay"], im, 1))
    n = 0
    for c in sky["clouds"]:
        if c["frame"] in names:
            continue
        n += 1
        names[c["frame"]] = f"PITCLD{n}"
        for j, im in enumerate(sky["frames"][c["frame"]]):
            six.append((f"PITCLD{n}{chr(65 + j)}", im["ax"], im["ay"], im, 2))
    sky_pals = [("PITMOON_P", 6, sky["moon_pal"]), ("PITROCK_P", 6, sky["rock_pal"]),
                ("PITCLD_P", 6, sky["cloud_pal"])]

    # The silhouettes use two entries of the moon's 64 (4 = 0424h, 1 = 0001h).
    # Carried as their own three-entry palette at 2bpp instead of 6.
    used = sorted({v for im in sky["flyers"] for v in im["px"] if v})
    remap = {0: 0}
    fly_words = [0]
    for v in used:
        remap[v] = len(fly_words)
        fly_words.append(sky["fly_src_pal"][v])
    if len(fly_words) > 4:
        raise SystemExit(f"flyers use {len(used)} colours - no longer 2bpp")
    two = []
    for i, im in enumerate(sky["flyers"]):
        px = bytes(remap[v] for v in im["px"])
        two.append((f"PITFLY{i + 1}", im["ax"], im["ay"], dict(im, px=px), 0))
    fly_pals = [("PITFLY_P", 2, fly_words)]
    return six, sky_pals, two, fly_pals, names


def img_bytes(entries, pals):
    return build_img([(nm, ax, ay, im["w"], im["h"], im["px"], pi) for nm, ax, ay, im, pi in entries], pals)


# --------------------------------------------------------------------------
# Background: KUNGFU5's top blocks, MK1PIT's modules, one world
# --------------------------------------------------------------------------
TOP_CUT_Y = None   # canvas row where MK1PIT's crop begins - measured, not set


def mask6(imgs):
    """Every palette here is 64 entries and MK1 stored this art at 6bpp, but
    four images carry ONE out-of-range index as their very last pixel (79, 107,
    153 - a BDDTool artifact).  LOAD2 writes that pixel wider than the record's
    6 bits and the overflow lands in the NEXT record's first rows: it shredded
    the lion statue's torso (KUNGFU5 4B, straight after 48 in a pack).  v & 63
    is exactly what MK1 drew."""
    for im in imgs.values():
        if max(im["px"], default=0) > 63:
            im["px"] = bytes(v & 63 for v in im["px"])
    return imgs


def load_sources():
    ki, ko, kp = cave.load_bdd(DATA / "KUNGFU5.BDD")
    mods, kb = cave.load_bdb(DATA / "KUNGFU5.BDB")
    mi, mo, mp = cave.load_bdd(DATA / "MK1PIT.BDD")
    _mmods, mb = cave.load_bdb(DATA / "MK1PIT.BDB")
    mask6(ki)
    mask6(mi)
    if [n for n, _ in kp] != [n for n, _ in mp][:len(kp)]:
        raise SystemExit("KUNGFU5 and MK1PIT palettes are no longer in the same order - TPLPALS indices would lie")
    return ki, ko, kp, kb, mi, mo, mb


def asm_int(tok):
    tok = tok.strip()
    return int(tok[:-1], 16) if tok[-1] in "hH" else int(tok)


def read_blks(label, text):
    m = re.search(rf"^{label}:\s*$", text, re.M)
    if not m:
        raise SystemExit(f"src/MK1PITBG.ASM: no {label}")
    out = []
    for line in text[m.end():].splitlines():
        s = line.split(";")[0].strip()
        if not s:
            continue
        if not s.lower().startswith(".word"):
            break
        v = [asm_int(t) for t in s.split(None, 1)[1].split(",")]
        if v[0] == 0xFFFF:
            break
        out.append(v)
    return out


def bottom_modules(mi, mo):
    """MK1PIT's three runtime modules exactly as src/MK1PITBG.ASM carries them."""
    text = (SRC / "MK1PITBG.ASM").read_text(encoding="latin-1")
    hdrs = cave.read_hdrs(SRC / "MK1PITBG.ASM")
    if len(hdrs) != len(mo) or any((h[0], h[1]) != (mi[o]["w"], mi[o]["h"]) for h, o in zip(hdrs, mo)):
        raise SystemExit("TPLHDRS no longer maps 1:1 onto MK1PIT.BDD")
    out = {}
    for lab in ("MK1PITBG", "MK1PITFS", "MK1PITGORE"):
        bl = []
        for flags, x, y, hw in read_blks(lab + "BLKS", text):
            idx = mo[hw & 0x0FFF]
            bl.append(dict(img=mi[idx], x=x, y=y, pal=(flags & 0xF) | ((hw >> 12) << 4),
                           flip=bool(flags & 0x10)))
        out[lab] = bl
    return out, hdrs


def fit_bottom(ki, kb, bottom):
    """Where MK1PITBG's origin sits on the KUNGFU5 canvas: the most common
    offset between a runtime block and a KUNGFU5 block with the same pixels."""
    bykey = {}
    for b in kb:
        im = ki[b["hdr"]]
        bykey.setdefault((im["w"], im["h"], im["px"]), []).append((b["x"], b["y"]))
    votes = Counter()
    for bl in bottom["MK1PITBG"]:
        for cx, cy in bykey.get((bl["img"]["w"], bl["img"]["h"], bl["img"]["px"]), []):
            votes[(cx - bl["x"], cy - bl["y"])] += 1
    (ox, oy), n = votes.most_common(1)[0]
    if n < 40:
        raise SystemExit(f"MK1PITBG fits KUNGFU5 at only {n} blocks - the crop was re-cut, recheck by eye")
    return ox, oy


# Pit Bottom stage (BGND.ASM mk1pit_mod) places BG at (0,10) and FS/GORE at
# (15,4) - its nudge of the spike row against the wall.  Same nudge here.
FS_NUDGE = (15, 4 - 10)

# Runtime layout, MK1's own numbers (FFCB8690) where MK1 has one.
GROUND_Y = 258          # NOT MK1's 264.  MK2's fighters stand ~7 rows lower
                        # on their anchor than MK1's, so at 264 their feet
                        # landed on the deck's dark FRONT face.  258 puts the
                        # boots' last row on world 265, on the lit top face
                        # (249..268) with 16 rows of deck behind them for the
                        # shadow - THE DEAD POOL's walkway has 16 too
WORLD_Y = 45
SHADOW_BIAS = 2         # @shad_bias.  Was 6 (measured below); nudged up
                        # 4 (~3 drawn rows) 2026-09-17 by eye - the footing sat
                        # a touch low.  Measured, not guessed:
                        # tools/mk1pit_shadow_bias_sweep.lua sweeps it live and
                        # diffs shadows-on against shadows-off frames.  At +6
                        # (ground 258) the shadow's foot row lands on the
                        # boots' last row (+24, the first try, left it 14 under
                        # them).  A shadow climbs from its foot row, so the
                        # clip at the deck's top edge is what cuts it off
START_X = 264
LEFT, RIGHT = 18, 744
AUTOERASE = 0x0006              # FFCB8690's first word: 5R5G5B (0,0,6)
FALL_FLOOR_ABOVE_SCREEN_BOTTOM = 14   # Pit Bottom: ground 335 at camera 95 -> row 240


def top_blocks(ki, kb, cam_y, runtime):
    """KUNGFU5 bridge1 blocks the stage needs on top of the Pit Bottom modules,
    in world coordinates: every block that starts above the fall camera's top
    edge, minus the ones MK1PIT already draws at the same place with the same
    pixels.  Cutting at MK1PIT's own crop (canvas 1571) is NOT enough: the Pit
    Bottom's tuning moved its top spike row to the floor, which left a 50-row
    band of shaft wall that neither module carried."""
    ox, oy = CANVAS_TO_WORLD
    out = []
    for b in kb:
        if b["y"] >= 1954:
            continue                       # bridge0 (the spike row) is MK1PIT's
        im = ki[b["hdr"]]
        wx, wy = b["x"] - ox, b["y"] - oy
        if wy >= cam_y:
            continue
        if (wx, wy, im["w"], im["h"], im["px"], bool(b["z"] & 0x10)) in runtime:
            continue
        out.append(dict(b, wx=wx, wy=wy, img=im))
    return out


def layout():
    ki, ko, kp, kb, mi, mo, mb = load_sources()
    bottom, tplhdrs = bottom_modules(mi, mo)
    cx, cy = fit_bottom(ki, kb, bottom)     # MK1PITBG origin, canvas
    ox, oy = CANVAS_TO_WORLD
    bg_world = (cx - ox, cy - oy)
    fs_world = (bg_world[0] + FS_NUDGE[0], bg_world[1] + FS_NUDGE[1])
    runtime = set()
    for lab, (wx, wy) in (("MK1PITBG", bg_world), ("MK1PITFS", fs_world), ("MK1PITGORE", fs_world)):
        for b in bottom[lab]:
            im = b["img"]
            runtime.add((wx + b["x"], wy + b["y"], im["w"], im["h"], im["px"], b["flip"]))
    floor_y = bg_world[1] + (335 - 10)
    fall_cam = floor_y - (scrbot_row() - FALL_FLOOR_ABOVE_SCREEN_BOTTOM)
    top = top_blocks(ki, kb, fall_cam, runtime)
    x1 = min(b["wx"] for b in top)
    y1 = min(b["wy"] for b in top)
    x2 = max(b["wx"] + b["img"]["w"] for b in top)
    y2 = max(b["wy"] + b["img"]["h"] for b in top)
    for b in top:
        b["rx"], b["ry"] = b["wx"] - x1, b["wy"] - y1
    top.sort(key=lambda b: (b["rx"], b["ry"]))

    # which top images are already in the ROM (pixel-identical MK1PIT image)
    have = {}
    for i, o in enumerate(mo):
        im = mi[o]
        have.setdefault((im["w"], im["h"], im["px"]), i)
    used = []
    for b in top:
        if b["hdr"] not in used:
            used.append(b["hdr"])
    used.sort(key=ko.index)
    shared = {h: have[(ki[h]["w"], ki[h]["h"], ki[h]["px"])] for h in used
              if (ki[h]["w"], ki[h]["h"], ki[h]["px"]) in have}
    new = [h for h in used if h not in shared]

    # the pit floor (floor_y above): Pit Bottom stands its fighters at 335 with BG at 10
    return dict(ki=ki, ko=ko, kp=kp, top=top, top_box=(x1, y1, x2 - x1, y2 - y1), used=used,
                shared=shared, new=new, bottom=bottom, tplhdrs=tplhdrs, bg_world=bg_world,
                fs_world=fs_world, floor_y=floor_y, fall_cam=fall_cam, cut=cy)


def deck_band(L):
    """The bridge deck, world rows: the run of rows that are opaque across the
    whole fighting span (left limit .. right limit + a screen) in the top
    module.  The shadow is clipped to exactly this, the way THE DEAD POOL clips
    it to its walkway - above it is sky, below it the pillar capitals."""
    x1, y1, tw, _h = L["top_box"]
    span = range(LEFT, min(RIGHT + SCREEN_W, x1 + tw))   # the art ends at x 1142
    rows = {}
    for b in L["top"]:
        im = b["img"]
        w, h = im["w"], im["h"]
        bx, by = x1 + b["rx"], y1 + b["ry"]
        flip = bool(b["z"] & 0x10)
        for yy in range(h):
            wy = by + yy
            if not GROUND_Y - 40 <= wy <= GROUND_Y + 60:
                continue
            row = rows.setdefault(wy, set())
            for xx in range(w):
                if im["px"][yy * w + xx]:
                    row.add(bx + (w - 1 - xx if flip else xx))
    # >= 90% rather than every column: the deck's first two rows (249, 250)
    # are chipped stone, 94% and 99% covered.  Demanding all of them put the
    # clip at 251 and left a 2-row strip of deck showing above every shadow.
    need = len(span) * 9 // 10
    full = [wy for wy, xs in rows.items() if sum(1 for x in span if x in xs) >= need]
    if not full:
        raise SystemExit("no deck row spans the fighting area - the bridge art moved")
    top = min(full)
    bot = top
    while bot + 1 in full:
        bot += 1
    if not top <= GROUND_Y <= bot:
        raise SystemExit(f"ground {GROUND_Y} is not on the deck ({top}..{bot})")
    return top, bot


def scrbot_row():
    return SCREEN_H     # scrbot (DISPEQU) is the 254-row screen


# --------------------------------------------------------------------------
# Packs
# --------------------------------------------------------------------------
def deal(L):
    ki = L["ki"]
    cap = [int((e - s) * 8 * PACK_MARGIN) for _, s, e in PACKS]
    used = [0] * len(PACKS)
    got = [[] for _ in PACKS]
    for idx in sorted(L["new"], key=lambda i: (-cave.packed_bits(ki[i]), i)):
        bits = cave.packed_bits(ki[idx])
        for k in range(len(PACKS)):
            if used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(idx)
                break
        else:
            raise SystemExit(f"image {idx:X} ({bits // 8} bytes) fits no pack")
    order = L["ko"]
    return [sorted(g, key=order.index) for g in got], used


def part_files(L):
    ki, kp = L["ki"], L["kp"]
    groups, _ = deal(L)
    files = {}
    for (name, _s, _e), group in zip(PACKS, groups):
        if not group:
            continue
        bdd = bytearray(b"%d\n" % len(group))
        for idx in group:
            im = ki[idx]
            bdd += b"%x %d %d %d\n" % (idx, im["w"], im["h"], im["big"])
            bdd += im["px"]
        for nm, words in kp:
            bdd += b"%s %d\n" % (nm.encode(), len(words))
            bdd += struct.pack("<%dH" % len(words), *words)
        x, lines = 0, []
        for idx in group:
            lines.append("4000 %d 0 %X 0" % (x, idx))
            x += ki[idx]["w"] + 4
        hmax = max(ki[i]["h"] for i in group)
        bdb = [f"{name} {max(x, 1)} {hmax} 255 1 {len(kp)} {len(group)}",
               f"{name} 0 {max(x - 5, 0)} 0 {hmax - 1}"] + lines
        files[f"{name}.BDD"] = bytes(bdd)
        files[f"{name}.BDB"] = ("\n".join(bdb) + "\n").encode()
    return files


def pack_lod(name, start, end):
    return f"""***> {lod_address(start)}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE PIT (MK1) - bridge / shaft image pack {name[-1]} (phys 0x{start:06X}..0x{end:06X})
;
;  data/{name}.BDB/.BDD are GENERATED by tools/make_mk1pit.py --parts
;  from data/KUNGFU5.BDB/.BDD, MK1's own Pit background.  The images
;  MK1PIT (the Pit Bottom) does not already carry are dealt across
;  fixed slots and --apply merges the header tables back into one
;  module (src/MK1PTOPB.ASM).  Do not edit the pack BDB/BDD by hand.
;
;  PPP> 0: per-block auto depth, as every BBB> in MK7MIL.  DMA-drawn
;  background, never walked by shadow_p1p2's bank-less CPU read, so
;  either bank is safe.
;
;**************************************************************
ZON>
POF>
PPP> 0
GLO> BGNDTBL.GLO
BBB> {name}
"""


def sprite_lod(name, start, end, what, img, records, ppp):
    recs = ",".join(records)
    return f"""***> {lod_address(start)}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE PIT (MK1) - the sky: {what} (phys 0x{start:06X}..0x{end:06X})
;
;  data/{img} is GENERATED by tools/make_mk1pit.py --sky out of
;  C:\\MAME\\roms\\mk.zip - MK1's own records, pixels and anipoints.
;  Phase D checks it still matches.  PON>: the stage builds these with
;  gso_dmawnz_ns -> object_setup, which reads the palette off the record.
;  The palettes are carried in src/MK1PTOPB.ASM (generated too).
;
;  PPP> {ppp}, and its own LOD, because a mixed-depth LOD is what garbled
;  SONICCLAP.  ZON>: the clouds are mostly transparent run.
;
;**************************************************************
PON>
ZON>
PPP> {ppp}
ASM> {name}.TBL
{img}
---> {recs}
"""


def deal_sky(six):
    """First-fit decreasing over SKY_PACKS; returns [[record name...]] per pack."""
    cap = [int((e - st) * 8 * PACK_MARGIN) for _, st, e in SKY_PACKS]
    used = [0] * len(SKY_PACKS)
    got = [[] for _ in SKY_PACKS]
    order = [e[0] for e in six]
    for nm, _ax, _ay, im, _pi in sorted(six, key=lambda e: (-cave.packed_bits(e[3]), e[0])):
        bits = cave.packed_bits(im)
        for k in range(len(SKY_PACKS)):
            if used[k] + bits <= cap[k]:
                used[k] += bits
                got[k].append(nm)
                break
        else:
            raise SystemExit(f"sky record {nm} ({bits // 8} bytes) fits no pack")
    return [sorted(g, key=order.index) for g in got], used


def lod_files(L, six, two):
    files = {}
    groups, _ = deal(L)
    for (name, st, e), g in zip(PACKS, groups):
        if g:
            files[f"{name}.LOD"] = pack_lod(name, st, e).encode()
    sky_groups, _ = deal_sky(six)
    for (name, st, e), g in zip(SKY_PACKS, sky_groups):
        if g:
            files[f"{name}.LOD"] = sprite_lod(name, st, e, "moon, rocks and clouds", SKY_IMG.name, g, 6).encode()
    name, st, e = FLY_PACK
    files[f"{name}.LOD"] = sprite_lod(name, st, e, "the silhouettes", FLY_IMG.name, [x[0] for x in two], 2).encode()
    return files


# --------------------------------------------------------------------------
# --apply
# --------------------------------------------------------------------------
def merged_headers(L):
    ki = L["ki"]
    groups, _ = deal(L)
    by = {}
    for (name, start, end), group in zip(PACKS, groups):
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
            if (w, h) != (ki[idx]["w"], ki[idx]["h"]):
                raise SystemExit(f"{snap}: header {idx:X} is {w}x{h}, BDD says {ki[idx]['w']}x{ki[idx]['h']}")
            p = cave.sag_phys(addr)
            if not start <= p < end:
                raise SystemExit(f"{snap}: {idx:X} SAG {addr:08X} (phys {p:X}) outside {start:X}..{end:X}")
            hi = max(hi, p + (cave.packed_bits(ki[idx]) + 7) // 8)
            by[idx] = (w, h, addr, ctrl, f"{name} {idx:02X}")
        if hi > end:
            raise SystemExit(f"{name}: payload runs to {hi:X}, slot ends {end:X}")
    for idx, t in L["shared"].items():
        w, h, addr, ctrl = L["tplhdrs"][t]
        by[idx] = (w, h, addr, ctrl, f"TPLHDRS[{t}] (MK1PIT)")
    return [by[i] for i in L["used"]]


_MV = None


def _irw(name):
    """(physical start byte, payload) of data/<name>.IRW, the way makevrom seats it."""
    global _MV
    if _MV is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location("makevrom", ROOT / "makevrom.py")
        _MV = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_MV)
    path = DATA / f"{name}.IRW"
    if not path.exists():
        raise SystemExit(f"{path} missing - run python build.py")
    base, bank, payload = _MV.parse_irw(path)
    if bank not in _MV.BANK_OFFSETS:
        bank = _MV.FILE_BANK.get(f"{name}.IRW", 0)
    return _MV.BANK_OFFSETS[bank] + _MV.image_byte_offset(base, bank), payload


def decode_record(payload, rel_bit, w, h, ctrl):
    """One DMA record out of an IRW payload: [row] of palette indices.  Row
    header (compressed records) = lead nibble | trail nibble, scaled by the
    control word's lm/tm, as tools/fix_load2_bit_bleed.py reads them."""
    bpp = (ctrl >> 12) & 7 or 8
    comp = bool(ctrl & 0x80)
    lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    pos = rel_bit

    def bits(at, n):
        j = at // 8
        if at < 0 or j + 4 > len(payload) + 3:
            raise IndexError(at)
        v = int.from_bytes(payload[j:j + 4].ljust(4, b"\0"), "little")
        return (v >> (at % 8)) & ((1 << n) - 1)

    rows = []
    for _ in range(h):
        lead = trail = 0
        if comp:
            hdr = bits(pos, 8)
            pos += 8
            lead, trail = (hdr & 15) << lm, (hdr >> 4) << tm
        row = [0] * w
        for x in range(lead, max(lead, w - trail)):
            row[x] = bits(pos, bpp)
            pos += bpp
        rows.append(row)
    return rows, bpp


def runtime_bit(addr):
    """Header SAG (runtime form) -> physical video-ROM BIT address."""
    return addr - 0x4000000 + 0x800000 * 8 if addr >= 0x4000000 else addr


def verify_rom(L, hdrs, sky_entries):
    """Decode every record this stage put into the video ROM back out of its
    IRW and compare it with the source pixels.  LOAD2 has more than one way of
    writing a record that is not what it was given (bit bleed, the overflow
    above), and a wrong record draws as garbage that no table check sees.
    Returns a list of problems."""
    bad = []
    ki = L["ki"]
    groups, _ = deal(L)
    by_idx = dict(zip(L["used"], hdrs))
    for (name, _s, _e), group in zip(PACKS, groups):
        if not group:
            continue
        start, payload = _irw(name)
        for idx in group:
            w, h, addr, ctrl, _src = by_idx[idx]
            try:
                rows, bpp = decode_record(payload, runtime_bit(addr) - start * 8, w, h, ctrl)
            except IndexError:
                bad.append(f"{name}: KUNGFU5 {idx:02X} runs off the IRW")
                continue
            m = (1 << bpp) - 1
            px = ki[idx]["px"]
            n = sum(1 for y in range(h) for x in range(w) if rows[y][x] != px[y * w + x] & m)
            if n:
                bad.append(f"{name}: KUNGFU5 {idx:02X} ({w}x{h}) - {n} pixels differ from the source")

    want = {nm: im for nm, _ax, _ay, im, _pi in sky_entries}
    for name in [n for n, *_ in SKY_PACKS] + [FLY_PACK[0]]:
        tbl = SRC / f"{name}.TBL"
        if not tbl.exists():
            continue
        recs = []
        cur = None
        vals = []
        for line in tbl.read_text(encoding="latin-1").splitlines():
            lab = re.match(r"^(\w+):", line)
            if lab:
                cur, vals = lab.group(1), []
                continue
            mm = re.match(r"^\s*\.(word|long)\s+(.*)$", line)
            if cur and mm:
                vals += [v.strip() for v in mm.group(2).split(";")[0].split(",")]
                if len(vals) >= 6:
                    w, h = int(vals[0]), int(vals[1])
                    recs.append((cur, w, h, int(vals[4][:-1], 16), int(vals[5][:-1], 16)))
                    cur = None
        if not recs:
            continue
        start, payload = _irw(name)
        base = min(r[3] for r in recs)
        for lab, w, h, sag, ctrl in recs:
            im = want.get(lab)
            if im is None:
                continue
            try:
                rows, bpp = decode_record(payload, sag - base, w, h, ctrl)
            except IndexError:
                bad.append(f"{name}: {lab} runs off the IRW")
                continue
            m = (1 << bpp) - 1
            n = sum(1 for y in range(h) for x in range(w) if rows[y][x] != im["px"][y * w + x] & m)
            if n:
                bad.append(f"{name}: {lab} ({w}x{h}) - {n} pixels differ from the source")
    return bad


def sprite_tbl_check():
    """The sprite TBLs are promote_tbls' job; only fail if they are absent."""
    names = [n for n, *_ in SKY_PACKS] + [FLY_PACK[0]]
    return [n for n in names if not (SRC / f"{n}.TBL").exists()]


def h4(v, d=4):
    return "0%0*XH" % (d, v & ((1 << (4 * d)) - 1))


def build_asm(L, hdrs, sky, names):
    o = []
    w = o.append
    x1, y1, tw, th = L["top_box"]
    w("; THE PIT (MK1) - GENERATED by tools/make_mk1pit.py --apply.  Do not hand-edit.")
    w("; Bridge + shaft: data/KUNGFU5.BDB/.BDD blocks above the Pit Bottom crop.")
    w("; Sky: C:\\MAME\\roms\\mk.zip (MK1 rev 5.0), calla FFCB8950.")
    w("")
    w("; ---- layout (MK1's FFCB8690 unless noted; world = KUNGFU5 canvas - 221,907) ----")
    w(f"mk1p_erase\t.set\t{h4(AUTOERASE)}")
    w(f"mk1p_ground\t.set\t{GROUND_Y}")
    w(f"mk1p_worldy\t.set\t{WORLD_Y}")
    w(f"mk1p_start\t.set\t{START_X}")
    w(f"mk1p_left\t.set\t{LEFT}")
    w(f"mk1p_right\t.set\t{RIGHT}")
    w(f"mk1p_top_x\t.set\t{x1}\t\t; MK1PTOPBMOD")
    w(f"mk1p_top_y\t.set\t{y1}")
    w(f"mk1p_bg_x\t.set\t{L['bg_world'][0]}\t\t; MK1PITBGBMOD - fitted by pixels")
    w(f"mk1p_bg_y\t.set\t{L['bg_world'][1]}")
    w(f"mk1p_fs_x\t.set\t{L['fs_world'][0]}\t\t; MK1PITFS/GOREBMOD - Pit Bottom's own nudge")
    w(f"mk1p_fs_y\t.set\t{L['fs_world'][1]}")
    w(f"mk1p_floor_y\t.set\t{L['floor_y']}\t\t; where the body lands (Pit Bottom's ground)")
    w(f"mk1p_fall_cam\t.set\t{L['fall_cam']}\t\t; the camera's floor during the fall")
    dtop, dbot = deck_band(L)
    w(f"mk1p_shad_hi\t.set\t{GROUND_Y - dtop}\t\t; shadow clip: deck top row {dtop}")
    w(f"mk1p_shad_lo\t.set\t{dbot - GROUND_Y}\t\t; ... and its last row {dbot}")
    w(f"mk1p_shad_bias\t.set\t{SHADOW_BIAS}\t\t; rows the shadow is moved down onto the deck")
    im = sky["imm"]
    w("")
    w("; ---- the sky (FFCB9C90 clouds, FFCB8F10 the silhouette) ----")
    w(f"mk1p_cloud_wrap_x\t.set\t{h4(im['cloud_wrap_x'])}\t; an anchor past this ...")
    w(f"mk1p_cloud_wrap_dx\t.set\t{h4(im['cloud_wrap_dx'])}\t; ... goes back this far")
    w(f"mk1p_cloud_tick\t.set\t{im['cloud_tick']}")
    w(f"mk1p_moon_x\t.set\t{sky['moon']['x']}")
    w(f"mk1p_moon_y\t.set\t{sky['moon']['y']}")
    w(f"mk1p_rock_x\t.set\t{sky['rock_xy'][0]}")
    w(f"mk1p_rock_y\t.set\t{sky['rock_xy'][1]}")
    w(f"mk1p_fly_x\t.set\t{sky['fly_xy'][0]}")
    w(f"mk1p_fly_y\t.set\t{sky['fly_xy'][1]}")
    w(f"mk1p_fly_restart_x\t.set\t{im['fly_restart_x']}")
    w(f"mk1p_fly_end_x\t.set\t{h4(im['fly_end_x'])}")
    w(f"mk1p_fly_first\t.set\t{h4(im['fly_first'])}")
    w(f"mk1p_fly_gap\t.set\t{h4(im['fly_gap'])}")
    w(f"mk1p_fly_xvel\t.set\t{h4(FLY_XVEL[2], 6)}")
    w(f"mk1p_fly_passes\t.set\t{FLY_PASSES[2]}")
    npieces = 1 + len(sky["rocks"]) + sum(len(sky["frames"][c["frame"]]) for c in sky["clouds"])
    w(f"mk1p_sky_objs\t.set\t{npieces}\t\t; moon + rocks + every cloud piece (the silhouette is its own)")
    w("")
    w("\t.data")
    w("")
    w("MK1PTHDRS:")
    for (hw, hh, addr, ctrl, src), idx in zip(hdrs, L["used"]):
        w(f"\t.word\t{hw},{hh}\t\t; KUNGFU5 {idx:02X} <- {src}")
        w(f"\t.long\t{h4(addr, 8)}")
        w(f"\t.word\t{h4(ctrl)}")
    w("")
    hidx = {idx: i for i, idx in enumerate(L["used"])}
    w("MK1PTOPBLKS:")
    for b in L["top"]:
        flags = (b["z"] & 0xFFF0) | (b["pal"] & 0xF) | 0x40
        hw = hidx[b["hdr"]] + ((b["pal"] >> 4) << 12)
        w(f"\t.word\t{h4(flags)},{b['rx']},{b['ry']},{h4(hw)}")
    w("\t.word\t0FFFFH")
    w("MK1PTOPBMOD:")
    w(f"\t.word\t{tw},{th},{len(L['top'])}\t;x size, y size, #blocks")
    w("\t.long\tMK1PTOPBLKS, MK1PTHDRS, TPLPALS")
    w("")
    w("; ---- sky palettes (the IMG records point at these through PON>) ----")
    six, sky_pals, two, fly_pals, _ = sky_images(sky)
    for nm, _bits, words in sky_pals + fly_pals:
        w(f"{nm}:")
        w(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            w("\t.word\t" + ",".join(h4(v) for v in words[i:i + 8]))
    w("")
    w("; ---- clouds: piece list, x, y, oxvel.  MK1 FFCB9650 / FFCB98F0 ----")
    frames_done = set()
    for c in sky["clouds"]:
        base = names[c["frame"]]
        if base in frames_done:
            continue
        frames_done.add(base)
        w(f"{base.lower()}_parts")
        for j in range(len(sky["frames"][c["frame"]])):
            w(f"\t.long\t{base}{chr(65 + j)}")
        w("\t.long\t0")
    w("mk1p_clouds")
    for c in sky["clouds"]:
        w(f"\t.long\t{names[c['frame']].lower()}_parts")
        w(f"\t.word\t{c['x']},{c['y']}")
        w(f"\t.long\t{h4(c['vel'], 8)}")
    w("\t.long\t0")
    w("mk1p_rocks")
    for i in range(len(sky["rocks"])):
        w(f"\t.long\tPITROCK{i + 1}")
    w("\t.long\t0")
    w("mk1p_flyers")
    for i in range(len(sky["flyers"])):
        w(f"\t.long\tPITFLY{i + 1}")
    w("mk1p_flyers_end")
    w("")
    w("\t.text")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------
# preview
# --------------------------------------------------------------------------
def rgb(c):
    return (((c >> 10) & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31, (c & 31) * 255 // 31)


def render(L, sky, names, cam_x, cam_y, show_ground=True):
    from PIL import Image, ImageDraw
    pals = L["kp"]
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), rgb(AUTOERASE))
    tiles = {}

    def tile(im, pal, flip, words=None):
        key = (id(im), pal, flip)
        if key not in tiles:
            p = words if words is not None else pals[pal][1]
            t = Image.new("RGBA", (im["w"], im["h"]))
            t.putdata([(0, 0, 0, 0) if v == 0 else rgb(p[v] if v < len(p) else 0x7C1F) + (255,) for v in im["px"]])
            if flip:
                t = t.transpose(Image.FLIP_LEFT_RIGHT)
            tiles[key] = t
        return tiles[key]

    def sprite(im, x, y, words):
        t = tile(im, None, False, words)
        scr.paste(t, (x, y), t)

    # the sky, screen-fixed (MK1 m_noscroll): moon, silhouette, clouds, rocks
    sprite(sky["moon"], sky["moon"]["x"], sky["moon"]["y"], sky["moon_pal"])
    fly = sky["flyers"][0]
    sprite(fly, sky["fly_xy"][0] + 180, sky["fly_xy"][1], sky["fly_src_pal"])
    for c in sky["clouds"]:
        for im in sky["frames"][c["frame"]]:
            sprite(im, c["x"] - im["ax"], c["y"] - im["ay"], sky["cloud_pal"])
    rx, ry = sky["rock_xy"]
    for im in sky["rocks"]:
        sprite(im, rx - im["ax"], ry - im["ay"], sky["rock_pal"])

    x1, y1, _w, _h = L["top_box"]
    for b in L["top"]:
        t = tile(b["img"], b["pal"], bool(b["z"] & 0x10))
        scr.paste(t, (x1 + b["rx"] - cam_x, y1 + b["ry"] - cam_y), t)
    bx, by = L["bg_world"]
    for b in L["bottom"]["MK1PITBG"]:
        t = tile(b["img"], b["pal"], b["flip"])
        scr.paste(t, (bx + b["x"] - cam_x, by + b["y"] - cam_y), t)
    fx, fy = L["fs_world"]
    for lab in ("MK1PITFS", "MK1PITGORE"):
        for b in L["bottom"][lab]:
            t = tile(b["img"], b["pal"], b["flip"])
            scr.paste(t, (fx + b["x"] - cam_x, fy + b["y"] - cam_y), t)
    d = ImageDraw.Draw(scr)
    if show_ground:
        for gy, col in ((GROUND_Y, (255, 255, 0)), (L["floor_y"], (255, 0, 0))):
            d.line([(0, gy - cam_y), (SCREEN_W, gy - cam_y)], fill=col)
    return scr


# --------------------------------------------------------------------------
def dos(fn, data):
    """LOD/BDB are text for DOS tools: written CRLF, the way git (autocrlf)
    checks them out.  The BDD is binary and written as is."""
    if fn.upper().endswith((".LOD", ".BDB")):
        return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    return data


def same_file(path, fn, data):
    have = path.read_bytes()
    if fn.upper().endswith((".LOD", ".BDB")):
        return have.replace(b"\r\n", b"\n") == data.replace(b"\r\n", b"\n")
    return have == data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sky", action="store_true", help="write data/MK1PSKY.IMG + MK1PFLY.IMG")
    ap.add_argument("--parts", action="store_true", help="write the pack BDB/BDD and every LOD")
    ap.add_argument("--apply", action="store_true", help="write src/MK1PTOPB.ASM from the LOAD2 snapshots")
    ap.add_argument("--check", action="store_true", help="fail if anything generated is stale")
    ap.add_argument("--preview", nargs="*", metavar="X,Y", help="cameras (default: MK1's start + the pan + the bottom)")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    L = layout()
    sky = read_sky(MK1())
    six, sky_pals, two, fly_pals, names = sky_images(sky)
    rc = 0

    if a.report or not any((a.sky, a.parts, a.apply, a.check, a.preview is not None)):
        groups, used = deal(L)
        print(f"top module {L['top_box'][2]}x{L['top_box'][3]} at world ({L['top_box'][0]},{L['top_box'][1]}), "
              f"{len(L['top'])} blocks, {len(L['used'])} images ({len(L['shared'])} reuse MK1PIT, {len(L['new'])} new)")
        print(f"MK1PIT crop starts at canvas y {L['cut']}; BG world {L['bg_world']}, FS world {L['fs_world']}")
        print(f"pit floor world y {L['floor_y']}, fall camera {L['fall_cam']}, deck rows {deck_band(L)}")
        for (name, s, e), g, u in zip(PACKS, groups, used):
            print(f"  {name}  {s:06X}..{e:06X}  {len(g):2d} images  ~{u // 8:6d} of {e - s:6d} bytes")
        sky_groups, sky_used = deal_sky(six)
        for (name, st, e), g, u in zip(SKY_PACKS, sky_groups, sky_used):
            print(f"  {name} {st:06X}..{e:06X}  {len(g):2d} records ~{u // 8:6d} of {e - st:6d} bytes")
        fb = sum(cave.packed_bits(x[3]) for x in two) // 3
        print(f"  {FLY_PACK[0]} {FLY_PACK[1]:06X}..{FLY_PACK[2]:06X}   8 records ~{fb // 8:6d} of {FLY_PACK[2] - FLY_PACK[1]:6d} bytes")

    want = {SKY_IMG: img_bytes(six, sky_pals), FLY_IMG: img_bytes(two, fly_pals)}
    parts = part_files(L)
    lods = lod_files(L, six, two)
    if a.sky:
        for p, data in want.items():
            if not p.exists() or p.read_bytes() != data:
                p.write_bytes(data)
                print(f"wrote {p.relative_to(ROOT)}")
    if a.parts:
        for fn, data in {**parts, **lods}.items():
            p = DATA / fn
            if not p.exists() or not same_file(p, fn, data):
                p.write_bytes(dos(fn, data))
                print(f"wrote data/{fn}")
    if a.check:
        stale = [p.name for p, d in want.items() if not p.exists() or p.read_bytes() != d]
        stale += [fn for fn, d in {**parts, **lods}.items() if not (DATA / fn).exists() or not same_file(DATA / fn, fn, d)]
        if stale:
            print("THE PIT (MK1) sources stale (run tools/make_mk1pit.py --sky --parts, then python build.py): "
                  + ", ".join(stale))
            rc = 1
        missing = sprite_tbl_check()
        if missing:
            print("sprite tables missing from src/: " + ", ".join(missing))
            rc = 1

    if a.apply or a.check:
        hdrs = merged_headers(L)
        problems = verify_rom(L, hdrs, six + two)
        if problems:
            print("THE PIT (MK1): the video ROM does not hold what it was given:")
            for msg in problems:
                print("  " + msg)
            return 1
        text = build_asm(L, hdrs, sky, names)
        old = OUT_ASM.read_text(encoding="latin-1") if OUT_ASM.exists() else ""
        if a.apply and old != text:
            OUT_ASM.write_text(text, encoding="latin-1")
            for s in ("MK1PTOP.OBJ", "mk2.out"):
                (SRC / s).unlink(missing_ok=True)
            print("wrote src/MK1PTOPB.ASM")
        elif a.check:
            if old != text:
                print("src/MK1PTOPB.ASM is stale (run tools/make_mk1pit.py --apply)")
                rc = 1
            else:
                print("THE PIT (MK1) sky, packs and tables are current")

    if a.preview is not None:
        from PIL import Image
        cams = [tuple(int(v) for v in c.split(",")) for c in a.preview] or [
            (START_X, WORLD_Y), (LEFT, WORLD_Y), (RIGHT, WORLD_Y),
            (START_X, 300), (START_X, 520), (START_X, L["fall_cam"])]
        shots = [render(L, sky, names, x, y) for x, y in cams]
        cols = 3
        rows = (len(shots) + cols - 1) // cols
        sheet = Image.new("RGB", ((SCREEN_W + 4) * cols, (SCREEN_H + 4) * rows), (0, 255, 0))
        for i, s in enumerate(shots):
            sheet.paste(s, ((i % cols) * (SCREEN_W + 4), (i // cols) * (SCREEN_H + 4)))
        out = ROOT / "tmp" / "mk1pit" / "preview.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(out)
        print(f"wrote {out.relative_to(ROOT)}  cameras {cams}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
