#!/usr/bin/env python3
r"""Decode Mortal Kombat 1 **Y-unit** art straight out of `mkla1.zip` (rev 1.0,
08/09/92) - the earliest released MK1 - and diff it against the T-unit rev 5.0
set in `mk.zip`.

Nothing here is remembered: the image format, the record layout, the animation
tables and the palettes are all derived from the two ROM sets, and every
structural claim is re-checked on load so a different revision fails loudly
instead of producing plausible nonsense.

    python tools/mk1_yunit_extract.py                 # -> tmp/mk1_yunit/
    python tools/mk1_yunit_extract.py --char 0        # one fighter's lanes
    python tools/mk1_yunit_extract.py --diff          # rev1.0 vs rev5.0 art
    python tools/mk1_yunit_extract.py --orphans       # frames nothing points at

The Y-unit is NOT the T-unit, in four ways that matter:

  * **Pixels are planar across the ROM set.** MAME's `gfx` region is 8MB with
    the twelve 512K chips loaded flat at 0x000000. One pixel is six bits taken
    two at a time from three 2MB chunks (0x000000 / 0x200000 / 0x400000):
    `pixel[i] = d(0) | d(1)<<2 | d(2)<<4`, `d(k) = (base[k*0x200000 + i//4] >>
    (2*(i%4))) & 3`.  The T-unit packs the same six bits contiguously in a
    bit stream instead.
  * **SAG is a CPU address into the image window, 8 bits per pixel.** Both
    boards map image ROM at 0x02000000, but a Y-unit SAG is
    `0x02000000 + pixel*8` (MAME: `offset >> 3` indexes one byte per pixel),
    where a T-unit SAG is `0x02000000 + pixel*6`.
  * **Rows are padded to a multiple of four pixels.**  `stride = (w+3) & ~3`.
    The T-unit stores rows back to back with no padding at all.  This is why a
    byte-level diff of the two gfx sets finds almost nothing even though the
    art is the same.
  * Everything above the pixels is identical: an image record is
    `.word W,H,anix,aniy / .long SAG` (96 bits), a frame is a 0-terminated
    list of image pointers, a lane is a list of frame pointers with the
    commands 0 end / 1 jump / 2 flip / 3 adjust x / 4 adjust x,y / 5 no-sleep /
    6 calla, and `ANITAB_LIST` is nine `.long` per-fighter tables (Scorpion and
    Sub-Zero share one).

`ANITAB_LIST` is located by its own shape rather than hardcoded: nine ROM
pointers where entries 4 and 5 are equal and each target is a table of ROM
pointers.  rev 1.0 lands on 0xFFCE0600, rev 5.0 on 0xFFCE4B90 (the address the
MK2 repo's `mk1_shang_souls_extract.py` already uses, which is the check).
"""
from __future__ import annotations

import argparse
import collections
import re
import struct
import sys
import zipfile
from pathlib import Path

try:
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("needs numpy")
try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("needs Pillow (pip install pillow)")

REPO = Path(__file__).resolve().parent.parent
ROMS = Path(r"C:\MAME\roms")
BASE = 0xFF800000          # program ROM byte 0, as a TMS34010 bit address
IROM = 0x02000000          # image window; SAGs are absolute
CHIP = 0x80000

# mkla1: maindata is ROM_LOAD16_BYTE u105/u89; gfx is twelve flat 512K chips
Y_PROG = ("mkg-u105.la1", "mkg-u89.la1")
Y_GFX = ["mkg-u111.rom", "mkg-u112.rom", "mkg-u113.rom", "mkg-u114.rom",
         "mkg-u95.rom", "mkg-u96.rom", "mkg-u97.rom", "mkg-u98.rom",
         "mkg-u106.rom", "mkg-u107.rom", "mkg-u108.rom", "mkg-u109.rom"]
Y_REGION = 0x800000        # MAME's "gfx" region, 6MB filled
Y_CHUNK = Y_REGION // 4    # 2MB per bitplane pair

# mk (rev 5.0 T-unit): three groups of four chips, ROM_LOAD32_BYTE per group
T_PROG = ("mkt-uj12.bin", "mkt-ug12.bin")
T_GROUPS = [("ug14", "uj14", "ug19", "uj19"),
            ("ug16", "uj16", "ug20", "uj20"),
            ("ug17", "uj17", "ug22", "uj22")]

CHARS = ["JohnnyCage", "Kano", "Raiden", "LiuKang", "Scorpion", "SubZero",
         "Sonya", "Goro", "ShangTsung"]
CMD = {0: "END", 1: "JUMP", 2: "FLIP", 3: "ADJX", 4: "ADJXY", 5: "NOSLEEP", 6: "CALLA"}


# --------------------------------------------------------------------------
# ROM loading
# --------------------------------------------------------------------------
def _prog(z: zipfile.ZipFile, names) -> bytes:
    ev, od = z.read(names[0]), z.read(names[1])
    out = bytearray(len(ev) * 2)
    out[0::2], out[1::2] = ev, od
    return bytes(out)


class Rom:
    """common half: program ROM addressing, records, frames, lanes"""

    def __init__(self, prog: bytes):
        self.P = prog

    # --- program ROM ------------------------------------------------------
    def inside(self, bit: int) -> bool:
        return BASE <= bit < 0x100000000 and 0 <= (bit - BASE) // 8 < len(self.P) - 16

    def off(self, bit: int) -> int:
        return (bit - BASE) // 8

    def w(self, bit): return struct.unpack_from("<H", self.P, self.off(bit))[0]
    def sw(self, bit): return struct.unpack_from("<h", self.P, self.off(bit))[0]
    def l(self, bit): return struct.unpack_from("<I", self.P, self.off(bit))[0]

    def image(self, bit) -> dict:
        return dict(addr=bit, w=self.w(bit), h=self.w(bit + 16),
                    anix=self.sw(bit + 32), aniy=self.sw(bit + 48),
                    sag=self.l(bit + 64))

    def palette(self, bit) -> list[int]:
        n = self.w(bit)
        if not 1 <= n <= 256:
            raise ValueError("no palette at %08x" % bit)
        return [self.w(bit + 16 * (i + 1)) for i in range(n)]

    # --- structure --------------------------------------------------------
    def records(self) -> dict:
        """SAG -> (byte offset of the record, w, h, anix, aniy)"""
        P, N, out = self.P, len(self.P), {}
        for o in range(0, N - 4, 2):
            v, = struct.unpack_from("<I", P, o)
            if not (IROM <= v < IROM + (self.pixel_count() * self.sag_step())):
                continue
            p = o - 8
            if p < 0:
                continue
            w, h = struct.unpack_from("<HH", P, p)
            if not (1 <= w <= 480 and 1 <= h <= 480):
                continue
            ax, ay = struct.unpack_from("<hh", P, p + 4)
            if not (-600 <= ax <= 600 and -600 <= ay <= 600):
                continue
            out.setdefault(v, (p, w, h, ax, ay))
        return out

    def coherent(self, recs=None) -> dict:
        """records whose pixels actually decode as an image (rows correlate)"""
        recs = recs if recs is not None else self.records()
        keep = {}
        for sag, (p, w, h, ax, ay) in recs.items():
            a = self.pixels(w, h, sag)
            if a is None or h < 3 or w < 3:
                continue
            s = a != 0
            if (s[:-1] == s[1:]).mean() >= 0.80 and 0.02 < s.mean() < 0.999:
                keep[sag] = (p, w, h, ax, ay)
        return keep

    def pieces(self, frame) -> list[int]:
        out, a = [], frame
        if not self.inside(frame):
            return out
        for _ in range(32):
            if not self.inside(a):
                break
            v = self.l(a)
            if v == 0 or not self.inside(v):
                break
            out.append(v)
            a += 32
        return out

    def lane(self, addr, parts=1, limit=64):
        """frames of a lane as (frame, dx, dy); adjust commands accumulate"""
        out, a, dx, dy, ends, n = [], addr, 0, 0, 0, 0
        while n < limit and self.inside(a):
            v = self.l(a)
            if v == 0:
                ends += 1
                a += 32
                if ends >= parts:
                    break
                continue
            if v == 1:
                break
            if v == 3:
                dx += self.sw(a + 32); a += 48; continue
            if v == 4:
                dx += self.sw(a + 32); dy += self.sw(a + 48); a += 64; continue
            if v in (2, 5):
                a += 32; continue
            if v == 6:
                a += 64; continue
            if not self.inside(v):
                break
            out.append((v, dx, dy))
            a += 32
            n += 1
        return out

    def lane_source(self, addr, limit=64) -> list[str]:
        """the lane as written: one line per command"""
        out, a, n = [], addr, 0
        while n < limit and self.inside(a):
            v = self.l(a)
            if v in (0, 1):
                out.append("%08x  %s" % (a, CMD[v]))
                break
            if v in (2, 5):
                out.append("%08x  %s" % (a, CMD[v])); a += 32; continue
            if v == 3:
                out.append("%08x  ADJX %d" % (a, self.sw(a + 32))); a += 48; continue
            if v == 4:
                out.append("%08x  ADJXY %d,%d" % (a, self.sw(a + 32), self.sw(a + 48)))
                a += 64; continue
            if v == 6:
                out.append("%08x  CALLA %08x" % (a, self.l(a + 32))); a += 64; continue
            if not self.inside(v):
                out.append("%08x  ?? %08x" % (a, v)); break
            out.append("%08x  FRAME %08x  (%d pieces)" % (a, v, len(self.pieces(v))))
            a += 32; n += 1
        return out

    def anitab(self, ochar): return self.l(self.anitab_list + 32 * ochar)
    def ani(self, ochar, k): return self.l(self.anitab(ochar) + 32 * k)

    # --- the whole frame graph -------------------------------------------
    def frames(self, recs) -> list[tuple[int, int]]:
        """every 0-terminated run of image pointers, as (address, piece count)"""
        R = {BASE + v[0] * 8 for v in recs.values()}
        P, N, out, o = self.P, len(self.P), [], 0
        L = lambda x: struct.unpack_from("<I", P, x)[0]
        while o < N - 8:
            if L(o) in R:
                q = o
                while q < N - 4 and L(q) in R:
                    q += 4
                if q < N - 4 and L(q) == 0:
                    out.append((BASE + o * 8, (q - o) // 4))
                o = q + 4
            else:
                o += 2
        return out

    def pointer_census(self) -> collections.Counter:
        P, N = self.P, len(self.P)
        c = collections.Counter()
        for o in range(0, N - 4, 2):
            c[struct.unpack_from("<I", P, o)[0]] += 1
        return c


class YRom(Rom):
    """mkla1 - Mortal Kombat rev 1.0, Midway Y-unit"""
    name = "mkla1 (rev 1.0, Y-unit)"

    def __init__(self, zip_path: Path):
        with zipfile.ZipFile(zip_path) as z:
            # mkla1 names its program ROMs *.la1; the prototypes use their own
            # names (mkprot8.105 / .89).  Take the two 512K members that are
            # not one of the twelve known gfx chips, u105/even first.
            # some prototype zips are merged and carry the T-unit parent's
            # mkt-* chips as well; those are never the Y-unit program ROMs.
            names = [n for n in z.namelist()
                     if n not in Y_GFX and z.getinfo(n).file_size == CHIP
                     and not Path(n).name.lower().startswith(("mkt-", "mks-"))]
            if len(names) != 2:
                raise SystemExit("%s: expected 2 program ROMs, found %s"
                                 % (zip_path.name, names))
            names.sort(key=lambda n: 0 if ("105" in n or "u105" in n) else 1)
            self.name = "%s (%s / %s)" % (zip_path.stem, *names)
            super().__init__(_prog(z, names))
            raw = np.zeros(Y_REGION, np.uint8)
            blob = b"".join(z.read(n) for n in Y_GFX)
            raw[:len(blob)] = np.frombuffer(blob, np.uint8)
        i = np.arange(Y_REGION, dtype=np.uint32)
        sh = (2 * (i % 4)).astype(np.uint8)
        q = (i // 4).astype(np.uint32)
        self.px = (((raw[q] >> sh) & 3)
                   | (((raw[Y_CHUNK + q] >> sh) & 3) << 2)
                   | (((raw[2 * Y_CHUNK + q] >> sh) & 3) << 4)).astype(np.uint8)

    def pixel_count(self): return Y_REGION
    def sag_step(self): return 8

    @staticmethod
    def stride(w): return (w + 3) & ~3

    def pixels(self, w, h, sag):
        s = (sag - IROM) // 8
        st = self.stride(w)
        a = self.px[s:s + st * h]
        if a.size < st * h:
            return None
        return a.reshape(h, st)[:, :w]


class TRom(Rom):
    """mk - Mortal Kombat rev 5.0, Midway T-unit"""
    name = "mk (rev 5.0, T-unit)"

    def __init__(self, zip_path: Path):
        with zipfile.ZipFile(zip_path) as z:
            super().__init__(_prog(z, T_PROG))
            g = bytearray(CHIP * 4 * len(T_GROUPS))
            for gi, grp in enumerate(T_GROUPS):
                b = gi * CHIP * 4
                for lane, nm in enumerate(grp):
                    g[b + lane:b + CHIP * 4:4] = z.read("mkt-%s.bin" % nm)
        self.g = np.frombuffer(bytes(g), np.uint8)

    def pixel_count(self): return self.g.size * 8 // 6
    def sag_step(self): return 6

    def pixels(self, w, h, sag):
        b0, n = sag - IROM, w * h * 6
        if b0 < 0 or b0 + n > self.g.size * 8:
            return None
        by0, by1 = b0 // 8, (b0 + n + 7) // 8
        bits = np.unpackbits(self.g[by0:by1], bitorder="little")[b0 - by0 * 8:][:n]
        return (bits.reshape(w * h, 6) * (1 << np.arange(6))).sum(1).astype(np.uint8).reshape(h, w)


# --------------------------------------------------------------------------
# anchors found by shape, not by memory
# --------------------------------------------------------------------------
def find_anitab_list(rom: Rom) -> int:
    """nine ROM pointers, [4]==[5] (Scorpion and Sub-Zero share a table), each
    target itself a run of ROM pointers"""
    P, N = rom.P, len(rom.P)
    L = lambda o: struct.unpack_from("<I", P, o)[0]

    def table_like(bit):
        o = (bit - BASE) // 8
        if not (0 <= o < N - 32 * 4):
            return False
        n = sum(1 for k in range(32)
                if L(o + 4 * k) == 0 or (BASE <= L(o + 4 * k) < 0x100000000
                                         and L(o + 4 * k) % 16 == 0))
        return n >= 20

    best = []
    for o in range(0, N - 9 * 4, 2):
        vs = [L(o + 4 * k) for k in range(9)]
        if any(not (BASE <= v < 0x100000000) or v % 16 for v in vs):
            continue
        if vs[4] != vs[5] or len(set(vs)) != 8:
            continue
        if not all(table_like(v) for v in vs):
            continue
        # in a real fighter table, entry 0 is the stance: a lane of >= 4 frames
        # whose frames carry several pieces each.  Score all nine.
        rom.anitab_list = BASE + o * 8
        score = 0
        for c in range(9):
            fr = rom.lane(rom.ani(c, 0))
            if len(fr) >= 4 and sum(len(rom.pieces(f)) for f, _, _ in fr) >= 4 * len(fr):
                score += 1
        best.append((score, BASE + o * 8))
    if not best:
        raise SystemExit("ANITAB_LIST not found - unexpected ROM revision?")
    best.sort(key=lambda s: (-s[0], s[1]))
    if best[0][0] < 6:
        raise SystemExit("ANITAB_LIST not convincing (best score %d)" % best[0][0])
    return best[0][1]


def find_palettes(y: YRom, t: TRom) -> list[int]:
    """rev 5.0 keeps a .long-per-fighter palette table at FFC839A0; the same 64
    colours appear verbatim in rev 1.0, so match on content"""
    out = []
    for i in range(9):
        p = t.l(0xFFC839A0 + 32 * i)
        cols = t.palette(p)
        blob = struct.pack("<%dH" % len(cols), *cols)
        pos = y.P.find(blob)
        out.append(BASE + (pos - 2) * 8 if pos >= 2 else None)
    return out


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
def rgb(cols):
    return [(((c >> 10) & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31,
             (c & 31) * 255 // 31) for c in cols]


def draw_frame(rom: Rom, frame, pal=None):
    """one frame's pieces composited on their shared anchor -> RGBA, anchor"""
    ps = []
    for pa in rom.pieces(frame):
        im = rom.image(pa)
        a = rom.pixels(im["w"], im["h"], im["sag"])
        if a is not None:
            ps.append((im, a))
    if not ps:
        return None, (0, 0)
    xs, ys = [], []
    for im, _ in ps:
        xs += [-im["anix"], -im["anix"] + im["w"]]
        ys += [-im["aniy"], -im["aniy"] + im["h"]]
    x0, y0 = min(xs), min(ys)
    out = Image.new("RGBA", (max(xs) - x0, max(ys) - y0), (0, 0, 0, 0))
    px = out.load()
    cols = rgb(pal) if pal else None
    for im, a in ps:
        ox, oy = -im["anix"] - x0, -im["aniy"] - y0
        for yy in range(im.shape_h if False else a.shape[0]):
            row = a[yy]
            for xx in range(a.shape[1]):
                v = int(row[xx])
                if v:
                    c = cols[v] if cols and v < len(cols) else (v * 4,) * 3
                    px[ox + xx, oy + yy] = c + (255,)
    return out, (-x0, -y0)


def strip(rom: Rom, frames, pal=None, scale=1, labels=None, bg=(16, 16, 24)):
    imgs = [draw_frame(rom, f if isinstance(f, int) else f[0], pal)[0] for f in frames]
    imgs = [(im.resize((im.width * scale, im.height * scale), Image.NEAREST)
             if im else None) for im in imgs]
    top = 16 if labels else 0
    W = sum((im.width if im else 20) + 8 for im in imgs) or 20
    H = max((im.height if im else 20) for im in imgs) + top
    cv = Image.new("RGB", (W, H), bg)
    dr = ImageDraw.Draw(cv)
    x = 0
    for i, im in enumerate(imgs):
        if im:
            cv.paste(im, (x, top), im)
        if labels:
            lab, col = labels[i]
            dr.text((x, 2), lab, fill=col)
        x += (im.width if im else 20) + 8
    return cv


def gif(rom: Rom, frames, pal, path, ms=110):
    cells = [draw_frame(rom, f, pal) for f in frames]
    ims = [c[0] for c in cells if c[0]]
    if not ims:
        return
    ax = max(c[1][0] for c in cells if c[0])
    ay = max(c[1][1] for c in cells if c[0])
    W = ax + max(im.width - c[1][0] for im, c in zip(ims, [c for c in cells if c[0]]))
    H = ay + max(im.height - c[1][1] for im, c in zip(ims, [c for c in cells if c[0]]))
    out = []
    for im, (px, py) in [(c[0], c[1]) for c in cells if c[0]]:
        cv = Image.new("RGB", (W, H), (24, 24, 32))
        cv.paste(im, (ax - px, ay - py), im)
        out.append(cv)
    out[0].save(path, save_all=True, append_images=out[1:], duration=ms, loop=0)


# --------------------------------------------------------------------------
# jobs
# --------------------------------------------------------------------------
def job_lanes(y: YRom, pals, outdir: Path, ochar: int):
    d = outdir / ("lanes_%02d_%s" % (ochar, CHARS[ochar]))
    d.mkdir(parents=True, exist_ok=True)
    pal = y.palette(pals[ochar]) if pals[ochar] else None
    lines = []
    for k in range(0x60):
        a = y.ani(ochar, k)
        if not y.inside(a):
            continue
        fr = y.lane(a, parts=3, limit=32)
        if not fr:
            continue
        im = strip(y, fr, pal, scale=1)
        im.save(d / ("lane_%02X.png" % k))
        lines.append("lane %02X  %08x  %d frames" % (k, a, len(fr)))
        lines += ["    " + s for s in y.lane_source(a, limit=32)]
    (d / "lanes.txt").write_text("\n".join(lines), encoding="utf-8")
    print("%s: %d lanes -> %s" % (CHARS[ochar], sum(1 for l in lines if l.startswith("lane")), d))


def job_orphans(y: YRom, t: TRom, pals, outdir: Path):
    """frames that no 32-bit word in the ROM points at - authored, never played"""
    res = {}
    for rom, tag in ((y, "mkla1"), (t, "mk_rev5")):
        recs = rom.records()
        fr = rom.frames(recs)
        ptr = rom.pointer_census()
        orph = [(a, n) for a, n in fr if ptr[a] == 0]
        res[tag] = (fr, orph)
        print("%-8s frames %d, unreferenced %d" % (tag, len(fr), len(orph)))
    d = outdir / "orphan_frames"
    d.mkdir(parents=True, exist_ok=True)
    fr, orph = res["mkla1"]
    pal = y.palette(pals[0]) if pals[0] else None
    labels = [("%08x" % a, (255, 120, 120)) for a, n in orph]
    for i in range(0, len(orph), 12):
        chunk = orph[i:i + 12]
        strip(y, [a for a, n in chunk], pal, scale=2,
              labels=labels[i:i + 12]).save(d / ("orphans_%03d.png" % i))
    (d / "orphan_frames.txt").write_text(
        "\n".join("%08x  %d pieces" % (a, n) for a, n in orph), encoding="utf-8")
    print("orphan frames -> %s" % d)


def job_diff(y: YRom, t: TRom, outdir: Path):
    """which images exist in one revision and not the other (by silhouette)"""
    import hashlib
    def sigs(rom):
        out = {}
        for sag, (p, w, h, ax, ay) in rom.coherent().items():
            a = rom.pixels(w, h, sag)
            sil = np.ascontiguousarray((a != 0).astype(np.uint8))
            out[sag] = (p, w, h, ax, ay,
                        hashlib.md5(sil).hexdigest(),
                        hashlib.md5(np.ascontiguousarray(a)).hexdigest())
        return out
    sy, st = sigs(y), sigs(t)
    SY = {r[5] for r in sy.values()}
    ST = {r[5] for r in st.values()}
    VT = {r[6] for r in st.values()}
    only = sorted(sag for sag, r in sy.items() if r[5] not in ST)
    print("mkla1 images  %d" % len(sy))
    print("rev5.0 images %d" % len(st))
    print("pixel-identical in both: %d" % sum(1 for r in sy.values() if r[6] in VT))
    print("in rev1.0 only: %d   in rev5.0 only: %d"
          % (len(only), sum(1 for r in st.values() if r[5] not in SY)))
    d = outdir / "diff"
    d.mkdir(parents=True, exist_ok=True)
    (d / "rev1_only.txt").write_text(
        "\n".join("sag %08x  rec %08x  %dx%d" % (s, BASE + sy[s][0] * 8, sy[s][1], sy[s][2])
                  for s in only), encoding="utf-8")
    print("-> %s" % d)


def job_cage_flip(y: YRom, t: TRom, pals, outdir: Path):
    """Johnny Cage's flip (anim 0Eh forward / 0Fh reversed) and the frame that
    sits in the middle of its art and is played by neither"""
    d = outdir / "cage_flip"
    d.mkdir(parents=True, exist_ok=True)
    pal = y.palette(pals[0])
    used = [f for f, dx, dy in y.lane(y.ani(0, 0x0E), parts=1, limit=32)]
    recs = y.records()
    ptr = y.pointer_census()
    frames = {a for a, n in y.frames(recs)}
    # the unused frame: a frame nothing points at, whose pieces' SAGs fall
    # between the first and second frame of the flip
    s0 = max(y.image(p)["sag"] for p in y.pieces(used[0]))
    s1 = min(y.image(p)["sag"] for p in y.pieces(used[1]))
    cut = [a for a in sorted(frames)
           if ptr[a] == 0 and y.pieces(a)
           and s0 < min(y.image(p)["sag"] for p in y.pieces(a)) < s1]
    if len(cut) != 1:
        print("!! expected exactly one cut flip frame, found %d" % len(cut))
    restored = [used[0]] + cut + used[1:]
    lab_u = [("%08x" % a, (180, 200, 230)) for a in used]
    lab_r = [("%08x" % a, (255, 90, 90) if a in cut else (180, 200, 230)) for a in restored]
    strip(y, used, pal, scale=2, labels=lab_u).save(d / "flip_shipped.png")
    strip(y, restored, pal, scale=2, labels=lab_r).save(d / "flip_restored.png")
    gif(y, used, pal, d / "flip_shipped.gif")
    gif(y, restored, pal, d / "flip_restored.gif")
    for a in restored:
        im, _ = draw_frame(y, a, pal)
        im.save(d / ("frame_%08x%s.png" % (a, "_UNUSED" if a in cut else "")))
    lines = ["Johnny Cage flip - mkla1 (MK1 rev 1.0, Y-unit)", ""]
    for k in (0x0E, 0x0F):
        lines += ["anim %02Xh  lane %08x" % (k, y.ani(0, k))]
        lines += ["    " + s for s in y.lane_source(y.ani(0, k), limit=32)]
        lines += [""]
    lines += ["cut frame(s): " + " ".join("%08x" % a for a in cut), ""]
    for a in restored:
        mark = "   <-- CUT, played by neither lane" if a in cut else ""
        lines.append("frame %08x%s" % (a, mark))
        for p in y.pieces(a):
            im = y.image(p)
            lines.append("    rec %08x  %3dx%-3d  ani(%d,%d)  sag %08x"
                         % (p, im["w"], im["h"], im["anix"], im["aniy"], im["sag"]))
    # and the same lane in rev 5.0, to show the cut is not a rev-1.0 thing
    lines += ["", "rev 5.0 (mk.zip) anim 0Eh lane %08x" % t.ani(0, 0x0E)]
    lines += ["    " + s for s in t.lane_source(t.ani(0, 0x0E), limit=32)]
    (d / "flip.txt").write_text("\n".join(lines), encoding="utf-8")
    print("Cage flip -> %s" % d)
    print("  shipped %d frames, cut frame(s): %s"
          % (len(used), " ".join("%08x" % a for a in cut)))


def job_export_lane(y: YRom, t: TRom, pals, outdir: Path, ochar: int, index: int):
    """one lane, ready to become an MK2 IMG: every piece as an indexed PNG
    carrying the arcade palette, every frame composited on its anchor, and a
    JSON with sizes, anipoints and SAGs - checked against rev 5.0"""
    import json
    name = "%s_%02X" % (CHARS[ochar], index)
    d = outdir / ("lane_" + name)
    (d / "pieces").mkdir(parents=True, exist_ok=True)
    pal = y.palette(pals[ochar])
    flat = [c for rgb3 in rgb(pal) for c in rgb3]
    flat += [0] * (768 - len(flat))
    lane_addr = y.ani(ochar, index)
    frames = [f for f, _, _ in y.lane(lane_addr, parts=1, limit=64)]
    # rev 5.0 carries the same lane; prove the pixels are the same
    t_frames = [f for f, _, _ in t.lane(t.ani(ochar, index), parts=1, limit=64)]
    same = len(t_frames) == len(frames)
    out = dict(rom="mkla1 (MK1 rev 1.0, Y-unit)", fighter=CHARS[ochar],
               anim_index="%02Xh" % index, lane="%08x" % lane_addr,
               palette=dict(address="%08x" % pals[ochar], count=len(pal),
                            colors=["%04X" % c for c in pal]),
               rev5_lane="%08x" % t.ani(ochar, index), frames=[])
    for fi, f in enumerate(frames):
        fr = dict(frame="%08x" % f, pieces=[])
        tp = t.pieces(t_frames[fi]) if same else []
        for pi, pa in enumerate(y.pieces(f)):
            im = y.image(pa)
            a = y.pixels(im["w"], im["h"], im["sag"])
            png = Image.fromarray(a, "P")
            png.putpalette(flat)
            png.info["transparency"] = 0
            fn = "f%d_p%d.png" % (fi + 1, pi + 1)
            png.save(d / "pieces" / fn, transparency=0)
            match = None
            if tp and pi < len(tp):
                ti = t.image(tp[pi])
                tb = t.pixels(ti["w"], ti["h"], ti["sag"])
                match = bool(tb is not None and tb.shape == a.shape and (tb == a).all()
                             and (ti["anix"], ti["aniy"]) == (im["anix"], im["aniy"]))
                same = same and match
            fr["pieces"].append(dict(record="%08x" % pa, w=im["w"], h=im["h"],
                                     anix=im["anix"], aniy=im["aniy"],
                                     sag="%08x" % im["sag"], png="pieces/" + fn,
                                     rev5_identical=match))
        comp, (ax, ay) = draw_frame(y, f, pal)
        comp.save(d / ("frame%d.png" % (fi + 1)))
        fr.update(composite="frame%d.png" % (fi + 1), composite_w=comp.width,
                  composite_h=comp.height, composite_anix=ax, composite_aniy=ay)
        out["frames"].append(fr)
    out["rev5_identical"] = same
    (d / "lane.json").write_text(json.dumps(out, indent=2), encoding="utf-8")
    strip(y, frames, pal, scale=3,
          labels=[("%08x" % f, (255, 220, 120)) for f in frames]).save(d / "strip.png")
    gif(y, frames, pal, d / "anim.gif", ms=int(1000 / 54.7068 * 3))
    print("%s lane %02Xh (%08x): %d frames, rev5.0 identical: %s -> %s"
          % (CHARS[ochar], index, lane_addr, len(frames), same, d))


VANDAN_TBL = REPO / "data" / "VANDAN.TBL"
VANDAN_REC = re.compile(
    r"^(\w+)\s*\n\s*\.word\s+(\d+),(\d+)\s*\n\s*\.word\s+(-?\d+),(-?\d+)"
    r"\s*\n\s*\.long\s+0([0-9A-Fa-f]+)h", re.M)


def read_vandan(prefix: str) -> dict:
    """image records out of data/VANDAN.TBL (the decompiled MK1 Cage tables).
    The SAGs there are rev 5.0 (T-unit) addresses."""
    txt = VANDAN_TBL.read_text(encoding="latin-1")
    out = {}
    for mm in VANDAN_REC.finditer(txt):
        if mm.group(1).startswith(prefix):
            out[mm.group(1)] = dict(w=int(mm.group(2)), h=int(mm.group(3)),
                                    anix=int(mm.group(4)), aniy=int(mm.group(5)),
                                    sag=int(mm.group(6), 16))
    return out


def job_flipkick(y: YRom, t: TRom, pals, outdir: Path, others=()):
    """Johnny Cage's unused FLIP KICK - VDFKICK1-4.

    The four frames are named in `data/VANDAN.ASM`, where the frame lists are
    commented out: the game has no `VDFKICK1`..`4` frame records and nothing
    points at where they were, so only the 29 image records survive.  They are
    read from `data/VANDAN.TBL` and decoded straight out of the ROM.
    """
    import json
    d = outdir / "cage_flipkick"
    (d / "pieces").mkdir(parents=True, exist_ok=True)
    recs = read_vandan("VDFKICK")
    frames = [["VDFKICK1" + c for c in "ABCDEFG"],
              ["VDFKICK2" + c for c in "ABCDEFG"],
              ["VDFKICK3" + c for c in "ABCDEFGH"],
              ["VDFKICK4" + c for c in "ABCDEFG"]]
    missing = [n for f in frames for n in f if n not in recs]
    if missing:
        raise SystemExit("VANDAN.TBL is missing %s" % missing)
    pal = t.palette(0xFFE99B00)              # GRIMM_P - Cage's palette
    cols = rgb(pal)
    flat = [c for c3 in cols for c in c3] + [0] * (768 - 3 * len(cols))
    # the same pixels in the Y-unit builds, matched by content
    import hashlib
    def hh(rom, w, h, sag):
        a = rom.pixels(w, h, sag)
        return None if a is None else hashlib.md5(np.ascontiguousarray(a)).hexdigest()
    idx = {rom.name: {hh(rom, w, h, s): (s, p) for s, (p, w, h, ax, ay) in rom.coherent().items()}
           for rom in (y,) + tuple(others)}
    out = dict(what="Johnny Cage's unused FLIP KICK (VDFKICK1-4)",
               source="data/VANDAN.ASM / VANDAN.TBL; pixels decoded from mk.zip (rev 5.0)",
               palette="GRIMM_P @ FFE99B00 (rev 5.0), %d colours" % len(pal),
               note="no frame records exist and nothing points at them - "
                    "only the 29 image records survive", frames=[])
    cells = []
    for fi, names in enumerate(frames, 1):
        xs, ys = [], []
        for n in names:
            r = recs[n]
            xs += [-r["anix"], -r["anix"] + r["w"]]
            ys += [-r["aniy"], -r["aniy"] + r["h"]]
        x0, y0 = min(xs), min(ys)
        comp = Image.new("RGBA", (max(xs) - x0, max(ys) - y0), (0, 0, 0, 0))
        cpx = comp.load()
        fr = dict(frame="VDFKICK%d" % fi, pieces=[])
        for n in names:
            r = recs[n]
            a = t.pixels(r["w"], r["h"], r["sag"])
            png = Image.fromarray(a, "P")
            png.putpalette(flat)
            png.save(d / "pieces" / (n + ".png"), transparency=0)
            for yy in range(r["h"]):
                for xx in range(r["w"]):
                    v = int(a[yy][xx])
                    if v:
                        cpx[-r["anix"] - x0 + xx, -r["aniy"] - y0 + yy] = cols[v] + (255,)
            k = hh(t, r["w"], r["h"], r["sag"])
            fr["pieces"].append(dict(
                name=n, w=r["w"], h=r["h"], anix=r["anix"], aniy=r["aniy"],
                sag_rev5="%08x" % r["sag"], png="pieces/%s.png" % n,
                also_in={nm: ("sag %08x rec %08x" % (v[k][0], BASE + v[k][1] * 8))
                         for nm, v in idx.items() if k in v}))
        comp.save(d / ("VDFKICK%d.png" % fi))
        fr.update(composite="VDFKICK%d.png" % fi, w=comp.width, h=comp.height,
                  anix=-x0, aniy=-y0)
        out["frames"].append(fr)
        cells.append(("VDFKICK%d  %dx%d" % (fi, comp.width, comp.height), comp))
        print("  VDFKICK%d  %d pieces  %dx%d  anipoint (%d,%d)"
              % (fi, len(names), comp.width, comp.height, -x0, -y0))
    (d / "flipkick.json").write_text(json.dumps(out, indent=2), encoding="utf-8")
    sc = 3
    W = sum(c[1].width * sc + 14 for c in cells)
    H = max(c[1].height for c in cells) * sc + 24
    cv = Image.new("RGB", (W, H), (245, 245, 245))
    dr = ImageDraw.Draw(cv)
    x = 0
    for lab, im in cells:
        im2 = im.resize((im.width * sc, im.height * sc), Image.NEAREST)
        bg = Image.new("RGB", im2.size, (245, 245, 245))
        bg.paste(im2, (0, 0), im2)
        cv.paste(bg, (x, 22))
        dr.text((x, 5), lab, fill=(150, 0, 0))
        x += im2.width + 14
    cv.save(d / "flipkick_strip.png")
    # GIF on one canvas, anchors aligned
    ax = max(f["anix"] for f in out["frames"])
    ay = max(f["aniy"] for f in out["frames"])
    W = ax + max(c[1].width - f["anix"] for c, f in zip(cells, out["frames"]))
    H = ay + max(c[1].height - f["aniy"] for c, f in zip(cells, out["frames"]))
    gif_frames = []
    for (lab, im), f in zip(cells, out["frames"]):
        g = Image.new("RGB", (W, H), (24, 24, 32))
        g.paste(im, (ax - f["anix"], ay - f["aniy"]), im)
        gif_frames.append(g)
    gif_frames[0].save(d / "flipkick.gif", save_all=True,
                       append_images=gif_frames[1:], duration=110, loop=0)
    print("Cage flip kick -> %s" % d)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(REPO / "tmp" / "mk1_yunit"))
    ap.add_argument("--roms", default=str(ROMS))
    ap.add_argument("--char", type=int, help="dump one fighter's lanes (0-8)")
    ap.add_argument("--all-lanes", action="store_true", help="dump every fighter")
    ap.add_argument("--diff", action="store_true", help="rev 1.0 vs rev 5.0 art")
    ap.add_argument("--orphans", action="store_true", help="unreferenced frames")
    ap.add_argument("--flip", action="store_true", help="Johnny Cage's flip only")
    ap.add_argument("--flipkick", action="store_true",
                    help="Johnny Cage's unused FLIP KICK (VDFKICK1-4)")
    ap.add_argument("--lane", metavar="OCHAR:INDEX",
                    help="export one lane MK2-ready, e.g. 0:28 (Cage's flying kick)")
    a = ap.parse_args()

    roms = Path(a.roms)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    y = YRom(roms / "mkla1.zip")
    t = TRom(roms / "mk.zip")
    y.anitab_list = find_anitab_list(y)
    t.anitab_list = find_anitab_list(t)
    if t.anitab_list != 0xFFCE4B90:
        print("!! rev 5.0 ANITAB_LIST came out %08x, not FFCE4B90" % t.anitab_list)
    print("ANITAB_LIST: mkla1 %08x, rev5.0 %08x" % (y.anitab_list, t.anitab_list))
    pals = find_palettes(y, t)

    did = False
    if a.flipkick:
        job_flipkick(y, t, pals, out); did = True
    if a.lane:
        oc, ix = a.lane.split(":")
        job_export_lane(y, t, pals, out, int(oc, 0), int(ix, 16))
        did = True
    if a.flip:
        job_cage_flip(y, t, pals, out); did = True
    if a.diff:
        job_diff(y, t, out); did = True
    if a.orphans:
        job_orphans(y, t, pals, out); did = True
    if a.char is not None:
        job_lanes(y, pals, out, a.char); did = True
    if a.all_lanes:
        for c in range(9):
            job_lanes(y, pals, out, c)
        did = True
    if not did:
        job_cage_flip(y, t, pals, out)
        job_orphans(y, t, pals, out)
        job_lanes(y, pals, out, 0)
        job_diff(y, t, out)


if __name__ == "__main__":
    main()
