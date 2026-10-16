#!/usr/bin/env python3
r"""MK1's nine fighters' colours, out of `mk.zip` and into `data/KATPAL.IMG`.

WHY: MK1's palettes are only in MK1's program ROM.  Nothing in this tree can
open them, recolour them, or diff a repaint against them, so any MK1-derived
art authored here has been eyeballed against a screenshot.  This puts the
words in an IMG library, which is the one container IMGTOOL can open.

`KATPAL.IMG` is in NO LOD file - LOAD2 never reads it and none of this reaches
a ROM.  It is a reference library, the same role `tools/backup_code_palettes.py`
gives it for the ROM's own code-only palettes, and that tool's `--apply`
preserves records it does not own (it rebuilds from `read_lib`'s full list and
only adds or updates its own MANIFEST names), so the two co-exist.

    python tools/import_mk1_palettes.py              # report, write nothing
    python tools/import_mk1_palettes.py --apply      # write them into the IMG
    python tools/import_mk1_palettes.py --check      # fail if any drifted
    python tools/import_mk1_palettes.py --rgb        # + the colours as hex

MK1's two tables are 9 `.long` each, by ochar: `FFC839A0` is the palette a
fighter is given and `FFC83AC0` the one he wears in a mirror match.  THE 9 IS
NOT ASSUMED - the primary table's ninth entry ends exactly where the mirror
table begins, and this asserts that, so a wrong base address cannot quietly
read nine pointers out of the middle of something else.

Two of the sixteen are ALREADY IN THIS TREE under Midway's own names, and that
is the anchor check: MK1's Kano is `data/MK1BLOOD.IMG:KANO_P` word for word and
MK1's Goro is `data/GOROSIZE.IMG:GONGORO_P`.  Both are asserted before anything
is written - they are two independent proofs the table addresses still resolve.

Goro and Shang have no mirror palette (both tables point at the same words), so
the mirror set is SEVEN records, not nine; a duplicate is skipped, not written.

REPTILE IS IN NEITHER TABLE and reading them alone misses him - which is what
happened on the first pass here.  He is not an ochar in MK1, just the shared
ninja body in a green costume, so his palette is an immediate in the code.  He
comes in through `SPECIALS` and is identified by the ninja BODY match described
there, so the total is SEVENTEEN records, not sixteen.

Names are capped at NINE characters by the IMG palette record's 10-byte field
(377 names in `data/` are 9 long and none is 10), and the plain names collide
with MK2's own - `CAGE_P`, `KANO_P`, `SCORP_P` and `SONYA_P` all already exist
in `data/`, which is what `tools/check_img_names.py` exists to catch.  Hence
the `MK1` prefix and the abbreviated stems below.
"""
from __future__ import annotations

import argparse
import struct
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                    # noqa: E402
from backup_code_palettes import (NUMDEFPAL, pal_record, read_lib,   # noqa: E402
                                  write_lib)

REPO = Path(__file__).resolve().parent.parent
ROM_ZIP = Path(r"C:\MAME\roms\mk.zip")
TARGET = REPO / "data" / "KATPAL.IMG"

BASE = 0xFF800000               # program ROM, TMS34010 BIT addresses
PAL_PRIMARY = 0xFFC839A0        # .long per ochar - the palette he is given
PAL_MIRROR = 0xFFC83AC0         # .long per ochar - mirror-match palette
NCHAR = 9                       # ochar 0..8; asserted against the table gap

# ochar order, from `get_char_ani`'s table list at FFCE4B90.  The stem is what
# fits in nine characters with the MK1 prefix and the _P suffix this tree uses
# for a palette; the mirror stem drops a letter for the `2`.  Liu Kang's mirror
# is KNG2, not KAN2, because KAN2 is Kano's.
CHARS = [
    # ochar, name,          primary,      mirror
    (0, "Johnny Cage", "MK1CAGE_P", "MK1CAG2_P"),
    (1, "Kano",        "MK1KANO_P", "MK1KAN2_P"),
    (2, "Raiden",      "MK1RAID_P", "MK1RAI2_P"),
    (3, "Liu Kang",    "MK1KANG_P", "MK1KNG2_P"),
    (4, "Scorpion",    "MK1SCOR_P", "MK1SCO2_P"),
    (5, "Sub-Zero",    "MK1SUBZ_P", "MK1SUB2_P"),
    (6, "Sonya",       "MK1SONY_P", "MK1SON2_P"),
    (7, "Goro",        "MK1GORO_P", "MK1GOR2_P"),
    # Shang is TSNG, not SHNG: `data/OLDSHNG.IMG` already carries a palette
    # called MK1SHNG_P and it is a DIFFERENT THING - 62 entries of the MK1
    # old-man Shang art that was reverted on 2026-09-20, 59 of them differing
    # from the fighter's.  Neither library is in a LOD so nothing breaks
    # today, but a same-name-different-palette pair is precisely what
    # tools/check_img_names.py exists to catch.
    (8, "Shang Tsung", "MK1TSNG_P", "MK1TSN2_P"),
]

# The two palettes this tree already holds under Midway's own names.  Not a
# nicety - they are the only evidence available here that PAL_PRIMARY still
# points where it did, so a miss is fatal rather than a warning.
ANCHORS = {
    1: ("data/MK1BLOOD.IMG", "KANO_P"),
    7: ("data/GOROSIZE.IMG", "GONGORO_P"),
}

# --- the ninjas share a body, and that is what identifies a third one -------
# Scorpion (ochar 4) and Sub-Zero (5) share one anim table and one set of art.
# Their palettes are split: indices 0..31 are the BODY - the neutral greys
# 0-19 and the flesh/brown ramp 20-31 - and 32..63 are the COSTUME.  Both
# ninjas and both their mirror palettes carry byte-identical bodies and differ
# only in the costume ramp.
NINJA_BODY = 32                 # indices below this are the shared body
NINJA_REF = 5                   # ochar to take the reference body from

# Palettes that are NOT in either ochar table.  REPTILE IS NOT AN OCHAR IN
# MK1 - he is the shared ninja body in a green costume, fought once as the
# hidden bonus match, and his palette is a hardcoded immediate in the code near
# FFC83790 rather than a table row.  Reading the two 9-entry tables therefore
# MISSES HIM ENTIRELY, which is exactly what happened on the first import.
#
# FFC83E60 is the only green palette in the whole program ROM carrying the
# ninja body, and that is how it was found: a luma-correlation sweep is NOT
# enough on its own (two unrelated monotone ramps at FFCD72D0/FFCD76E0 score
# 0.98 against Sub-Zero and share 1 of 32 body entries), so the test that
# decides is the body match below, not a hue or a correlation.
#
# There is no mirror Reptile - only one green ninja palette exists, which fits
# a fighter who is never fought in a mirror match.
SPECIALS = [
    (0xFFC83E60, "MK1REPT_P", "Reptile, the third ninja costume"),
]

# --- one stance frame per fighter, to hold the palette against -------------
# A palette on its own cannot be judged.  `KATPAL.IMG` already carries exactly
# one image for this reason - `KT2STANCE1`, Kitana's stance, with `palnum`
# pointing at her `KATPRPL_P` - so each fighter here gets the same treatment:
# the FIRST FRAME of his stance lane (anim table index 0), composited, with
# `palnum` pointing at his own palette.
#
# `palnum` IS OFFSET BY THREE.  The library header counts NUMDEFPAL phantom
# palettes that are not in the file, so `palnum = 3 + index in the file` -
# KT2STANCE1's 3 is the FIRST palette, not the fourth.  Writing the bare index
# silently points every image three palettes too early.
ANITAB_LIST = 0xFFCE4B90        # .long per ochar; get_char_ani indexes it
STANCE_ANI = 0                  # anim table entry 0 is the stance lane
IROM = 0x02000000               # image ROM base; SAG is absolute into it

# ochar, image record name, the palette it is drawn under.  Scorpion, Sub-Zero
# and Reptile are ALL ochar 4/5's art - one shared lane, one shared body - so
# the three records hold identical pixels and differ only in `palnum`.  That is
# the point: three copies is what lets IMGTOOL show the three costumes side by
# side, which one shared record cannot do.
STANCES = [
    (0, "MK1CAGEST1", "MK1CAGE_P"),
    (1, "MK1KANOST1", "MK1KANO_P"),
    (2, "MK1RAIDST1", "MK1RAID_P"),
    (3, "MK1KANGST1", "MK1KANG_P"),
    (4, "MK1SCORST1", "MK1SCOR_P"),
    (5, "MK1SUBZST1", "MK1SUBZ_P"),
    (6, "MK1SONYST1", "MK1SONY_P"),
    (7, "MK1GOROST1", "MK1GORO_P"),
    (8, "MK1TSNGST1", "MK1TSNG_P"),
    (4, "MK1REPTST1", "MK1REPT_P"),
]

# A fresh IMAGE record's fixed fields, copied off KT2STANCE1 so IMGTOOL sees
# the same shape it already reads in this library.
IMG_FLAGS, IMG_D, IMG_LIB, IMG_FRM = 0, 0, 0, 0
IMG_A2, IMG_PTBL, IMG_OPALS = 0xFFFF, 0xFFFF, 0xFFFF


GFX_CHIP = 0x80000
GFX_GROUPS = [("ug14", "uj14", "ug19", "uj19"),
              ("ug16", "uj16", "ug20", "uj20"),
              ("ug17", "uj17", "ug22", "uj22")]


class Mk1Rom:
    """MK1 rev 5.0's program ROM, de-interleaved.  Bit addresses in, as the
    map holds them; the two 512K lanes are even/odd BYTES of the word.

    The image ROM is loaded too, four-way interleaved in three groups, the
    same way tools/mk1_shang_souls_extract.py loads it."""

    def __init__(self, path: Path, gfx: bool = False):
        with zipfile.ZipFile(path) as z:
            ev, od = z.read("mkt-uj12.bin"), z.read("mkt-ug12.bin")
            p = bytearray(len(ev) * 2)
            p[0::2], p[1::2] = ev, od
            self.p = bytes(p)
            self.g = b""
            if gfx:
                g = bytearray(GFX_CHIP * 4 * len(GFX_GROUPS))
                for gi, grp in enumerate(GFX_GROUPS):
                    base = gi * GFX_CHIP * 4
                    for lane, nm in enumerate(grp):
                        g[base + lane:base + GFX_CHIP * 4:4] = z.read("mkt-%s.bin" % nm)
                self.g = bytes(g)

    def off(self, bit: int) -> int:
        if not BASE <= bit <= 0xFFFFFFFF or (bit - BASE) % 8:
            raise ValueError("not a program-ROM byte address: %08X" % bit)
        o = (bit - BASE) // 8
        if o >= len(self.p):
            raise ValueError("%08X is past the end of the program ROM" % bit)
        return o

    def w(self, bit): return struct.unpack_from("<H", self.p, self.off(bit))[0]
    def sw(self, bit): return struct.unpack_from("<h", self.p, self.off(bit))[0]
    def l(self, bit): return struct.unpack_from("<I", self.p, self.off(bit))[0]

    # --- sprites ----------------------------------------------------------
    # An MK1 image record is `.word W,H,anix,aniy / .long SAG` and carries NO
    # control word - that is an MK2 field.  Field 0 is 16 bits and field 1 is
    # 32, the reverse of MK2's.
    def image(self, bit):
        return dict(addr=bit, w=self.w(bit), h=self.w(bit + 16),
                    anix=self.sw(bit + 32), aniy=self.sw(bit + 48),
                    sag=self.l(bit + 64))

    def pieces(self, frame):
        """a frame is a 0-terminated list of image-record pointers"""
        out, a = [], frame
        while (v := self.l(a)) != 0:
            out.append(v)
            a += 32
        return out

    def pixels(self, im):
        """rows of 6bpp palette indices.  T-unit art is uncompressed, packed
        LSB-first with the bits contiguous and rows NOT padded (the Y-unit
        pads to 4 - see doc/MK1_YUNIT_ART.md)."""
        if not self.g:
            raise RuntimeError("image ROM not loaded - construct with gfx=True")
        pos, g, w, out = im["sag"] - IROM, self.g, im["w"], []
        for _ in range(im["h"]):
            row = []
            for _ in range(w):
                v = 0
                for b in range(6):
                    p = pos + b
                    v |= ((g[p >> 3] >> (p & 7)) & 1) << b
                row.append(v)
                pos += 6
            out.append(row)
        return out

    def anitab(self, ochar): return self.l(ANITAB_LIST + 32 * ochar)
    def ani(self, ochar, i): return self.l(self.anitab(ochar) + 32 * i)

    def lane(self, addr, limit=64):
        """frames of a lane as (frame, dx, dy), to the first END marker.
        1 jump, 2 flip, 3 adjx, 4 adjxy, 5 nosleep, 6 calla."""
        out, a, dx, dy, n = [], addr, 0, 0, 0
        while n < limit:
            v = self.l(a)
            if v == 0 or v == 1:
                break
            if v == 3:
                dx += self.sw(a + 32); a += 48; continue
            if v == 4:
                dx += self.sw(a + 32); dy += self.sw(a + 48); a += 64; continue
            if v in (2, 5):
                a += 32; continue
            if v == 6:
                a += 64; continue
            out.append((v, dx, dy))
            a += 32
            n += 1
        return out

    def palette(self, bit):
        """MK1 palette = `.word count` then `count` 15-bit colours, one per
        long slot.  Same 5-5-5 words an MK2 IMG palette holds, so the import
        is a copy - there is nothing to convert."""
        n = self.w(bit)
        if not 1 <= n <= 256:
            raise ValueError("no palette at %08X (count reads %d)" % (bit, n))
        return [self.w(bit + 16 * (i + 1)) for i in range(n)]


def composite(rom: Mk1Rom, ochar: int):
    """The first frame of `ochar`'s stance, its pieces laid on one canvas.

    -> (width, height, anix, aniy, rows of 6bpp indices).  A piece goes at
    `(dx - anix, dy - aniy)`; index 0 is transparent and is NOT copied, or a
    piece's empty corner would punch a hole in the one behind it.  The
    composite's own anipoint is the frame anchor in canvas coordinates, which
    keeps `aniy` negative exactly as KT2STANCE1's is."""
    frames = rom.lane(rom.ani(ochar, STANCE_ANI), limit=16)
    if not frames:
        raise SystemExit("ochar %d's stance lane at %08X walks to nothing"
                         % (ochar, rom.ani(ochar, STANCE_ANI)))
    frame, dx, dy = frames[0]
    ims = [rom.image(pa) for pa in rom.pieces(frame)]
    if not ims:
        raise SystemExit("ochar %d's stance frame %08X has no pieces"
                         % (ochar, frame))

    box = [(dx - im["anix"], dy - im["aniy"]) for im in ims]
    minx = min(x for x, _y in box)
    miny = min(y for _x, y in box)
    w = max(x + im["w"] for (x, _y), im in zip(box, ims)) - minx
    h = max(y + im["h"] for (_x, y), im in zip(box, ims)) - miny

    rows = [[0] * w for _ in range(h)]
    for (x, y), im in zip(box, ims):
        x -= minx
        y -= miny
        for r, src in enumerate(rom.pixels(im)):
            dst = rows[y + r]
            for c, v in enumerate(src):
                if v:
                    dst[x + c] = v
    return w, h, dx - minx, dy - miny, rows


def img_record(name: str, w: int, h: int, anix: int, aniy: int, palnum: int):
    """A fresh IMAGE record, shaped like KT2STANCE1's.  anix/aniy are signed
    and the field is unsigned, so they are masked here rather than at pack
    time - a negative aniy is the normal case, not an error."""
    return [name.encode("ascii")[:15], IMG_FLAGS, anix & 0xFFFF, aniy & 0xFFFF,
            w, h, palnum, 0, IMG_D, IMG_LIB, IMG_A2, IMG_A2, IMG_A2,
            IMG_FRM, IMG_PTBL, IMG_OPALS]


def img_bytes(w: int, h: int, rows) -> bytes:
    """8bpp on disk, one byte per index, rows padded to a multiple of 4
    PIXELS - the stride read_lib() reads back."""
    stride = (w + 3) & ~3
    out = bytearray(stride * h)
    for y, row in enumerate(rows):
        out[y * stride:y * stride + w] = bytes(row)
    return bytes(out)


def rgb(word: int) -> str:
    """A 15-bit colour word as #RRGGBB.  RED IS THE HIGH FIVE BITS - the same
    order `img_palette.py`, `make_soulrip_pals.py` and the MK1 extractor all
    use.  Reading it the other way round is self-concealing: it turns Scorpion
    yellow into Sub-Zero blue and both still look like plausible palettes."""
    r, g, b = (word >> 10) & 31, (word >> 5) & 31, word & 31
    return "#%02X%02X%02X" % (r * 255 // 31, g * 255 // 31, b * 255 // 31)


def collect(zip_path: Path, rom: "Mk1Rom | None" = None):
    """-> [(name, description, words)] in the order they go into the library.

    Proves the table length and both anchors before it returns anything."""
    rom = rom or Mk1Rom(zip_path)

    # The primary table's ninth entry ends where the mirror table starts: 9
    # longs is 0x120 bits.  If this fails, one of the two bases is wrong and
    # every pointer below is somebody else's data.
    gap = PAL_MIRROR - PAL_PRIMARY
    if gap != NCHAR * 32:
        raise SystemExit("the two palette tables are %d bits apart, not %d - "
                         "%08X..%08X does not hold exactly %d longs"
                         % (gap, NCHAR * 32, PAL_PRIMARY, PAL_MIRROR, NCHAR))

    prim = [rom.l(PAL_PRIMARY + 32 * i) for i in range(NCHAR)]
    mirr = [rom.l(PAL_MIRROR + 32 * i) for i in range(NCHAR)]

    # --- the anchors ------------------------------------------------------
    for ochar, (rel, name) in ANCHORS.items():
        want = rom.palette(prim[ochar])
        pals = dict((n.upper(), w) for n, w in ip.palettes(REPO / rel))
        got = pals.get(name.upper())
        if got is None:
            raise SystemExit("%s carries no palette called %s - the anchor "
                             "check cannot run" % (rel, name))
        if got != want:
            raise SystemExit(
                "ANCHOR FAILED: MK1 ochar %d's palette at %08X does not match "
                "%s:%s (%d vs %d entries).  Either PAL_PRIMARY is wrong or "
                "that library was recoloured - do not write anything until "
                "this is understood."
                % (ochar, prim[ochar], rel, name, len(want), len(got)))

    out, seen = [], {}
    for ochar, who, pname, mname in CHARS:
        pw = rom.palette(prim[ochar])
        out.append((pname, "%s - %08X" % (who, prim[ochar]), pw))
        seen[pname] = pw
    for ochar, who, pname, mname in CHARS:
        mw = rom.palette(mirr[ochar])
        if mw == seen[pname]:
            # Goro and Shang: both tables point at the same words, so there is
            # no second palette to import.  Writing one would be a duplicate
            # under a name that implies a difference.
            continue
        out.append((mname, "%s, mirror match - %08X" % (who, mirr[ochar]), mw))

    # --- the specials, each proved by the shared ninja body ----------------
    body = rom.palette(prim[NINJA_REF])[:NINJA_BODY]
    for addr, name, who in SPECIALS:
        ws = rom.palette(addr)
        if len(ws) != len(seen["MK1SUBZ_P"]):
            raise SystemExit("%08X has %d entries, the ninjas have %d - that is "
                             "not a ninja costume palette"
                             % (addr, len(ws), len(seen["MK1SUBZ_P"])))
        same = sum(1 for i in range(NINJA_BODY) if ws[i] == body[i])
        if same != NINJA_BODY:
            raise SystemExit(
                "SPECIAL FAILED: %08X (%s) shares only %d of %d BODY entries "
                "with the ninjas' - a ninja costume palette shares all of "
                "them, so either the address is wrong or this is not one."
                % (addr, name, same, NINJA_BODY))
        if ws[NINJA_BODY:] == rom.palette(prim[NINJA_REF])[NINJA_BODY:]:
            raise SystemExit("%08X (%s) has Sub-Zero's costume ramp too - it is "
                             "his palette, not a third one" % (addr, name))
        out.append((name, "%s - %08X" % (who, addr), ws))
    return out


def collect_stances(rom: Mk1Rom, pal_rows):
    """-> [(name, description, w, h, anix, aniy, pixel bytes, palette name)].

    The palette NAME is carried, not a number: `palnum` depends on where the
    palette lands in the library and is resolved at write time."""
    have = {n for n, _d, _w in pal_rows}
    out = []
    for ochar, name, palname in STANCES:
        if palname not in have:
            raise SystemExit("%s wants palette %s, which this import does not "
                             "produce" % (name, palname))
        w, h, ax, ay, rows = composite(rom, ochar)
        out.append((name, "ochar %d stance frame 1, %dx%d" % (ochar, w, h),
                    w, h, ax, ay, img_bytes(w, h, rows), palname))
    return out


def report(rows, show_rgb: bool) -> None:
    have = dict((n.upper(), w) for n, w in ip.palettes(TARGET))
    for name, desc, words in rows:
        slot = have.get(name.upper())
        state = ("new" if slot is None else
                 "current" if slot == words else "DRIFTED")
        print("  %-10s %-34s %2d entries  %s" % (name, desc, len(words), state))
        if show_rgb:
            for i in range(0, len(words), 8):
                print("       %2d  %s" % (i, " ".join(rgb(c) for c in words[i:i + 8])))


def report_stances(stances) -> None:
    have = {}
    try:
        _h, images, _p, _f = read_lib(TARGET)
        have = {ip.cstr(r[0]).upper(): (r, px) for r, px in images}
    except Exception:
        pass
    print()
    for name, desc, w, h, ax, ay, px, palname in stances:
        slot = have.get(name.upper())
        state = ("new" if slot is None else
                 "current" if slot[1] == px and slot[0][4] == w and slot[0][5] == h
                 else "DRIFTED")
        print("  %-11s %-34s anchor %3d,%-4d under %-10s %s"
              % (name, desc, ax, ay, palname, state))


def apply_or_check(rows, check: bool, stances=()) -> int:
    hdr, images, pals, img_first = read_lib(TARGET)
    have = {ip.cstr(r[0]).upper(): i for i, (r, _w) in enumerate(pals)}
    bad, changed = 0, []

    for name, _desc, words in rows:
        i = have.get(name.upper())
        if i is None:
            if check:
                print("MISSING %s: %s carries no such palette"
                      % (name, TARGET.name))
                bad += 1
                continue
            pals.append((pal_record(name, words), words))
            have[name.upper()] = len(pals) - 1
            changed.append("+" + name)
        elif pals[i][1] != words:
            if check:
                print("DRIFT   %s: %s has %d entries, MK1's ROM has %d"
                      % (name, TARGET.name, len(pals[i][1]), len(words)))
                bad += 1
                continue
            pals[i] = (pals[i][0], words)
            changed.append("~" + name)

    # --- the stance images ------------------------------------------------
    # palnum is resolved HERE, against the palette list as it now stands, so a
    # palette added or reordered above cannot leave an image pointing at the
    # wrong one.
    palnum = {ip.cstr(r[0]).upper(): i + NUMDEFPAL
              for i, (r, _w) in enumerate(pals)}
    hi = {ip.cstr(r[0]).upper(): i for i, (r, _px) in enumerate(images)}
    for name, _desc, w, h, ax, ay, px, palname in stances:
        pn = palnum.get(palname.upper())
        if pn is None:
            print("!! %s: palette %s is not in %s" % (name, palname, TARGET.name))
            bad += 1
            continue
        rec = img_record(name, w, h, ax, ay, pn)
        i = hi.get(name.upper())
        if i is None:
            if check:
                print("MISSING %s: %s carries no such image" % (name, TARGET.name))
                bad += 1
                continue
            images.append((rec, px))
            hi[name.upper()] = len(images) - 1
            changed.append("+" + name)
        elif images[i][1] != px or images[i][0][2:7] != rec[2:7]:
            if check:
                print("DRIFT   %s: %s has %dx%d/pal %d, MK1's ROM has %dx%d/pal %d"
                      % (name, TARGET.name, images[i][0][4], images[i][0][5],
                         images[i][0][6], w, h, pn))
                bad += 1
                continue
            images[i] = (rec, px)
            changed.append("~" + name)

    if check:
        print("%s: %d MK1 palettes, %d stance images checked"
              % (TARGET.name, len(rows), len(stances)))
        return bad

    blob = write_lib(hdr, images, pals, img_first)
    if blob != TARGET.read_bytes():
        TARGET.write_bytes(blob)
        print("%s: now %d palettes, %d images, %d bytes  (%s)"
              % (TARGET.name, len(pals), len(images), len(blob),
                 " ".join(changed) or "offsets only"))
    else:
        print("%s: already current" % TARGET.name)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="import MK1's character palettes into data/KATPAL.IMG")
    ap.add_argument("--zip", type=Path, default=ROM_ZIP,
                    help="MK1 rev 5.0 T-unit ROM set (default %s)" % ROM_ZIP)
    ap.add_argument("--apply", action="store_true", help="write them into the IMG")
    ap.add_argument("--check", action="store_true",
                    help="fail if any of them is missing or has drifted")
    ap.add_argument("--rgb", action="store_true", help="print the colours too")
    a = ap.parse_args()

    if not a.zip.exists():
        print("!! %s does not exist" % a.zip)
        return 1
    if not TARGET.exists():
        print("!! %s does not exist" % TARGET)
        return 1

    rom = Mk1Rom(a.zip, gfx=True)
    rows = collect(a.zip, rom)
    stances = collect_stances(rom, rows)
    if a.apply or a.check:
        return 1 if apply_or_check(rows, a.check, stances) else 0

    print("=== MK1 character palettes (%s) -> %s" % (a.zip.name, TARGET.name))
    report(rows, a.rgb)
    report_stances(stances)
    n_mirror = sum(1 for n, _d, _w in rows if n.endswith("2_P"))
    n_spec = len(SPECIALS)
    print("\n%d palettes: %d primary, %d mirror-match (Goro and Shang share "
          "theirs, so they have none), %d special (%s - in neither ochar "
          "table).\nRun with --apply to write them."
          % (len(rows), len(rows) - n_mirror - n_spec, n_mirror, n_spec,
             ", ".join(n for _a, n, _d in SPECIALS)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
