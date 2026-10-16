#!/usr/bin/env python3
r"""TWO BORROWED EFFECT PALETTES, OUT OF TWO OTHER GAMES' ROMS AND INTO ONE IMG.

Neither palette exists in any MK2 library, in any form:

  `JDBRITE_P`  UMK3's `jade_bright_p` - the full-body flash Jade wears for the
               whole of her SHADOW KICK.  `prop_do_jade_prop` (MKPROP.C:355)
               opens with `player_swpal(current_proc, jade_bright_p, obj)`, and
               the palette is index-for-index a BRIGHT GREEN re-hue of
               `JADE1_P`: her flesh ramp, her white-to-black grey ramp and her
               costume ramp all become one green ramp, mean luminance 9.7 ->
               16.1.  It is a CODE palette (lower case in `MKGUYS.H`), so it is
               in no IMG - not in `deadlythirdcombat`'s 266 libraries either.
               Only the arcade ROM has the words.

  `MK1LTNG_P`  MK1 RAIDEN'S LIGHTNING - a 62-step violet-to-white ramp.  His
               branching bolts are drawn in three of its slots (14 violet, 35
               lilac, 62 white) and his glow art sweeps the whole ramp.  It is
               ONE OF THREE per-fighter glow ramps, which is what makes it his
               rather than a shared "electric" palette: Cage's glow art is on a
               GREEN ramp (FFE99F10) and Sonya's on a MAGENTA one (FFE9F460),
               each the `.long` in its own fighter's art.

    python tools/make_fxpal_img.py              # report, write nothing
    python tools/make_fxpal_img.py --apply      # create/update data/FXPALS.IMG
    python tools/make_fxpal_img.py --check      # fail if the IMG has drifted
    python tools/make_fxpal_img.py --rgb        # + the colours as hex
    python tools/make_fxpal_img.py --png DIR    # PNG previews of the frames

A PALETTE ON ITS OWN CANNOT BE JUDGED, so each one ships with a frame the game
really draws in it, composited out of that game's own art:

  `JDBRITE1`   Jade's extended low kick (`KTLOKICK6` + `KTLOKICK6A`, UMK3's
               `KITANA4.IMG`).  `prop_do_jade_prop` plays `ANIM_LOKICK` - the
               shadow kick has no art of its own - so this IS the pose the
               flash is worn on.  It uses 60 of the 64 slots.
  `MK1LTNG1`   one frame of the branching bolt, off the lane at FFD343C0.
               Three slots only: that is the whole of a bolt.
  `MK1LTNG2`   Raiden's own glow silhouette, `raiden_anitab[24]` frame 0, which
               sweeps 57 of the 64 - the frame to judge the RAMP against.

`data/FXPALS.IMG` is in NO LOD.  LOAD2 never reads it and no pixel of it
reaches a ROM: it is a reference library, the role `data/KATPAL.IMG` already
plays for the MK1 fighter palettes.  For the same reason `--check` is NOT
wired into Phase D - the library is meant to be opened and edited in IMGTOOL,
and a build gate would turn a colour experiment into a failed build.  Run
`--check` by hand when you want to know whether it still matches the ROMs.

HOW EACH PALETTE WAS FOUND, and what `collect()` re-proves on every run
----------------------------------------------------------------------
Both were found by CONTENT and then confirmed against CODE, and both proofs
run again every time this tool is invoked, so a wrong address fails loudly
instead of writing a plausible-looking palette:

  jade_bright_p.  Every 64-entry palette block in `umk3.zip` was scored for
  green-dominance and for how closely its per-slot luminance tracks `JADE1_P`;
  one block won on both (63 of 64 green, mean |dlum| 6.5).  Its label's bit
  address FFA510E0 has EXACTLY ONE 32-bit reference in the megabyte, and the
  code around that reference is `prop_do_jade_prop` instruction for
  instruction - `MOVI 0217h` (ACT_JADE_PROP) into init_special_act, the
  palette into player_swpal, `MOVK 6` (ST_JADE_PROP), `MOVI 0030h`
  (FX_JADE_SMOKE), `MOVI 0012h` (ANIM_LOKICK).  The three immediates are
  asserted.

  MK1 lightning.  MK1 image records carry no palette field, so the palette is
  the `.long` that follows the FIRST record of a group (4 longs, then 3 per
  record after it).  The glow group at FFF2A700 carries FFE9EC40 at FFF2A760,
  and the bolt object header at FFD34000 carries it too.  The sibling check
  above is what attributes it to RAIDEN.
"""
from __future__ import annotations

import argparse
import struct
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                        # noqa: E402
from backup_code_palettes import (LIB_HDR, NUMDEFPAL, pal_record,  # noqa: E402
                                  read_lib, write_lib)
from import_mk1_palettes import (Mk1Rom, img_bytes, img_record,  # noqa: E402
                                 rgb)

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "data" / "FXPALS.IMG"

# --- UMK3 ------------------------------------------------------------------
UMK3_ZIP = Path(r"C:\MAME\roms\umk3.zip")
UMK3_EVEN = "l1.2_mortal_kombat_3_u54_ultimate.u54"
UMK3_ODD = "l1.2_mortal_kombat_3_u63_ultimate.u63"
UMK3_BASE = 0xFF800000

JADE_BRIGHT = 0x04A21C          # byte offset of the `.word 64` count
JADE_BRIGHT_BIT = 0xFFA510E0    # the same place as the label's bit address

# The three immediates `prop_do_jade_prop` carries either side of the swpal,
# as (name, byte offset RELATIVE to the palette's one code reference, value).
# Held relative so the check is about the ROUTINE, not about absolute offsets.
PROP_SIGNATURE = [
    ("ACT_JADE_PROP -> init_special_act", -0x0A, 0x0217),
    ("FX_JADE_SMOKE -> create_fx",        +0x14, 0x0030),
    ("ANIM_LOKICK -> get_char_ani",       +0x1E, 0x0012),
]

UMK3_ART = Path(r"C:\Users\you\Workplace\deadlythirdcombat-main"
                r"\deadlythirdcombat-main")
JADE_REF_IMG = "KITANA1.IMG"    # carries JADE1_P, the palette the flash re-hues
JADE_ART_IMG = "KITANA4.IMG"    # carries the KTLOKICK lane
JADE_FRAME = ["KTLOKICK6", "KTLOKICK6A"]

# --- MK1 -------------------------------------------------------------------
MK1_ZIP = Path(r"C:\MAME\roms\mk.zip")
MK1_LIGHT = 0xFFE9EC40          # Raiden's glow / lightning ramp
MK1_GLOW_GROUP = 0xFFF2A700     # first record of the glow group...
MK1_GLOW_PAL_LONG = 0xFFF2A760  # ...and the `.long` that follows it
MK1_BOLT_HEADER = 0xFFD34000    # the bolt object header's palette long
MK1_BOLT_LANE = 0xFFD343C0      # the branching-bolt lane
MK1_BOLT_FRAME = 4              # its widest, most branched frame
MK1_RAIDEN = 2                  # ochar
MK1_GLOW_SLOT = 24              # raiden_anitab[24] - his glow silhouette
MK1_BOLT_SLOTS = {0, 14, 35, 62}

# The two other fighters with a glow lane of their own.  Their palettes are
# NOT imported - they are the control that says Raiden's is Raiden's.
MK1_SIBLINGS = [
    (0xFFE99F10, "cage", "green"),
    (0xFFE9F460, "sonya", "magenta"),
]

# A fresh library header, field for field as data/KATPAL.IMG's - the one
# reference library in this tree, and a header IMGTOOL already opens here.
BLANK_HDR = [0, NUMDEFPAL, 0, 1588, 0, 0, 0, 0xABCD, b"\xff\xff\xff\xff", 0, 0, 0]


def lum(word: int) -> float:
    r, g, b = (word >> 10) & 31, (word >> 5) & 31, word & 31
    return (r * 77 + g * 151 + b * 28) / 256.0


def green_dominant(word: int) -> bool:
    r, g, b = (word >> 10) & 31, (word >> 5) & 31, word & 31
    return g > r and g > b


def blue_dominant(word: int) -> bool:
    r, g, b = (word >> 10) & 31, (word >> 5) & 31, word & 31
    return b >= r and b >= g


def red_dominant(word: int) -> bool:
    r, g, b = (word >> 10) & 31, (word >> 5) & 31, word & 31
    return r > g and r >= b


# ---------------------------------------------------------------------------
# UMK3
# ---------------------------------------------------------------------------
def umk3_rom() -> bytes:
    with zipfile.ZipFile(UMK3_ZIP) as z:
        even, odd = z.read(UMK3_EVEN), z.read(UMK3_ODD)
    if len(even) != len(odd):
        raise SystemExit("umk3 program ROM halves differ in size")
    flat = bytearray(len(even) * 2)
    flat[0::2], flat[1::2] = even, odd
    return bytes(flat)


def jade_bright(rom: bytes) -> list[int]:
    """`jade_bright_p`, with its three anchors re-proved."""
    if UMK3_BASE + JADE_BRIGHT * 8 != JADE_BRIGHT_BIT:
        raise SystemExit("JADE_BRIGHT and JADE_BRIGHT_BIT disagree")
    count = struct.unpack_from("<H", rom, JADE_BRIGHT)[0]
    if count != 64:
        raise SystemExit("no palette at %06X: the count word reads %d, not 64"
                         % (JADE_BRIGHT, count))
    words = list(struct.unpack_from("<64H", rom, JADE_BRIGHT + 2))
    if any(w >= 0x8000 for w in words):
        raise SystemExit("%06X holds words with bit 15 set - not 5-5-5 colours"
                         % JADE_BRIGHT)

    # --- anchor 1: exactly one reference, and it is a 32-bit MOVI ----------
    pat = struct.pack("<I", JADE_BRIGHT_BIT)
    refs, start = [], 0
    while (i := rom.find(pat, start)) >= 0:
        refs.append(i)
        start = i + 1
    if len(refs) != 1:
        raise SystemExit(
            "%08X is referenced %d times, not once - `jade_bright_p` has "
            "exactly ONE use in UMK3 (player_swpal in prop_do_jade_prop), so "
            "this is not it" % (JADE_BRIGHT_BIT, len(refs)))
    ref = refs[0]
    if struct.unpack_from("<H", rom, ref - 2)[0] != 0x09E0:
        raise SystemExit("the long at %06X is not the operand of a 32-bit MOVI"
                         % ref)

    # --- anchor 2: the routine around it is prop_do_jade_prop -------------
    for what, delta, want in PROP_SIGNATURE:
        got = struct.unpack_from("<H", rom, ref + delta)[0]
        if got != want:
            raise SystemExit(
                "prop_do_jade_prop's signature does not hold at %06X: %s "
                "should be %04Xh at %+d, reads %04Xh.  Either the ROM is a "
                "different revision or this is another routine"
                % (ref, what, want, delta, got))

    # --- anchor 3: it is JADE1_P, re-hued brighter ------------------------
    ref_pals = dict((n.upper(), w)
                    for n, w in ip.palettes(UMK3_ART / JADE_REF_IMG))
    jade1 = ref_pals.get("JADE1_P")
    if jade1 is None:
        raise SystemExit("%s carries no JADE1_P - the re-hue check cannot run"
                         % JADE_REF_IMG)
    if len(jade1) != len(words):
        raise SystemExit("JADE1_P has %d entries, this has %d - they are not "
                         "the same palette re-hued" % (len(jade1), len(words)))
    greens = sum(1 for w in words if green_dominant(w))
    if greens < 60:
        raise SystemExit("only %d of 64 entries are green - `jade_bright_p` is "
                         "a bright GREEN flash" % greens)
    mean_b = sum(map(lum, words)) / 64.0
    mean_j = sum(map(lum, jade1)) / 64.0
    if mean_b - mean_j < 3.0:
        raise SystemExit("mean luminance %.1f against JADE1_P's %.1f - a FLASH "
                         "is brighter than the costume it replaces"
                         % (mean_b, mean_j))
    # A flash brightens, slot for slot - EXCEPT at the top of the ramp, where
    # JADE1_P's two whites (36 #ffffff, 48 #a4ffc5) cannot stay as bright once
    # they are green: pure green is 24.4 of a possible 31.  So a handful of
    # near-white slots may lose a little, and nothing may lose much.
    drops = [(i, lum(jade1[i]) - lum(words[i]))
             for i in range(64) if lum(words[i]) < lum(jade1[i]) - 0.5]
    steep = [i for i, d in drops if d > 3.0]
    if steep or len(drops) > 4:
        raise SystemExit("%d slots come out darker than JADE1_P's (%s), %s past "
                         "3 luminance steps - a flash brightens"
                         % (len(drops), [i for i, _d in drops[:8]], steep[:8]))
    return words


def s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def read_img_lib(path: Path):
    """name -> record, for a library `read_lib` will not touch (KITANA4.IMG
    carries seq/scr tables).  Read only: nothing here writes a UMK3 library."""
    data = path.read_bytes()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]

    def plausible(off):
        raw = data[off:off + 16].split(b"\0", 1)[0]
        return bool(raw) and all(32 <= c < 127 for c in raw)

    img_first = sum(plausible(oset + i * ip.IMAGE.size)
                    for i in range(imgcnt)) > imgcnt // 2
    img_start = oset if img_first else None
    if img_start is None:
        for pc in (palcnt, palcnt - NUMDEFPAL):
            if plausible(oset + pc * ip.PALETTE.size):
                img_start = oset + pc * ip.PALETTE.size
                break
    if img_start is None:
        raise SystemExit("%s: cannot find the image table" % path.name)

    out = {}
    for i in range(imgcnt):
        rec = ip.IMAGE.unpack_from(data, img_start + i * ip.IMAGE.size)
        w, h, base = rec[4], rec[5], rec[7]
        stride = (w + 3) & ~3
        out[ip.cstr(rec[0])] = dict(anix=s16(rec[2]), aniy=s16(rec[3]), w=w,
                                    h=h, stride=stride,
                                    px=data[base:base + stride * h])
    return out


def lay_pieces(pieces):
    """Pieces on one canvas at (-anix, -aniy), index 0 transparent.

    -> (w, h, anchor x, anchor y, rows).  Every caller here draws ONE frame,
    where the lane's own dx/dy are shared by every piece and so cancel."""
    xs = [-p["anix"] for p in pieces]
    ys = [-p["aniy"] for p in pieces]
    minx, miny = min(xs), min(ys)
    w = max(x + p["w"] for x, p in zip(xs, pieces)) - minx
    h = max(y + p["h"] for y, p in zip(ys, pieces)) - miny
    rows = [[0] * w for _ in range(h)]
    for x, y, p in zip(xs, ys, pieces):
        x -= minx
        y -= miny
        for r in range(p["h"]):
            src = p["px"][r * p["stride"]:r * p["stride"] + p["w"]]
            dst = rows[y + r]
            for c, v in enumerate(src):
                if v:
                    dst[x + c] = v
    return w, h, -minx, -miny, rows


def jade_frame():
    lib = read_img_lib(UMK3_ART / JADE_ART_IMG)
    missing = [n for n in JADE_FRAME if n not in lib]
    if missing:
        raise SystemExit("%s carries no %s - the shadow kick's pose has moved"
                         % (JADE_ART_IMG, ", ".join(missing)))
    return lay_pieces([lib[n] for n in JADE_FRAME])


# ---------------------------------------------------------------------------
# MK1
# ---------------------------------------------------------------------------
def mk1_pieces(rom: Mk1Rom, frame_addr: int):
    """A frame's pieces, in `lay_pieces`'s shape, decoded out of the gfx ROMs."""
    out = []
    for addr in rom.pieces(frame_addr):
        im = rom.image(addr)
        rows = rom.pixels(im)
        out.append(dict(anix=im["anix"], aniy=im["aniy"], w=im["w"],
                        h=im["h"], stride=im["w"],
                        px=bytes(v for row in rows for v in row)))
    if not out:
        raise SystemExit("frame %08X has no pieces" % frame_addr)
    return out


def mk1_lightning(rom: Mk1Rom) -> list[int]:
    """Raiden's lightning ramp, with all four anchors re-proved."""
    words = rom.palette(MK1_LIGHT)
    if len(words) != 64:
        raise SystemExit("%08X has %d entries, not 64" % (MK1_LIGHT, len(words)))
    if words[0] != 0:
        raise SystemExit("%08X does not start on black" % MK1_LIGHT)
    if words[62] != 0x7FFF:
        raise SystemExit("slot 62 of %08X is %04Xh, not white - the bolt's "
                         "core is white" % (MK1_LIGHT, words[62]))
    cool = sum(1 for w in words[1:63] if blue_dominant(w))
    if cool < 58:
        raise SystemExit("only %d of 62 entries are blue-dominant - that is "
                         "not a lightning ramp" % cool)

    # --- anchor 1: the group header at FFF2A700 names it ------------------
    w, h = rom.w(MK1_GLOW_GROUP), rom.w(MK1_GLOW_GROUP + 16)
    if not (1 <= w <= 400 and 1 <= h <= 300):
        raise SystemExit("%08X is not an image record (%dx%d)"
                         % (MK1_GLOW_GROUP, w, h))
    if MK1_GLOW_PAL_LONG - MK1_GLOW_GROUP != 96:
        raise SystemExit("the palette long is not 96 bits past the record")
    got = rom.l(MK1_GLOW_PAL_LONG)
    if got != MK1_LIGHT:
        raise SystemExit("the glow group at %08X names palette %08X, not %08X"
                         % (MK1_GLOW_GROUP, got, MK1_LIGHT))

    # --- anchor 2: the bolt object header names it too --------------------
    got = rom.l(MK1_BOLT_HEADER)
    if got != MK1_LIGHT:
        raise SystemExit("the bolt header at %08X names palette %08X, not %08X"
                         % (MK1_BOLT_HEADER, got, MK1_LIGHT))

    # --- anchor 3: THE SIBLINGS - this is Raiden's, not "electric" --------
    # Cage and Sonya are the only other fighters with a glow lane, and each
    # one's art names a ramp of its own.  If these two ever read as the same
    # palette, or as the same hue, the per-fighter reading is wrong.
    for addr, who, hue in MK1_SIBLINGS:
        sib = rom.palette(addr)
        if len(sib) != 64:
            raise SystemExit("%s's glow palette %08X has %d entries, not 64"
                             % (who, addr, len(sib)))
        if sib == words:
            raise SystemExit("%s's glow palette %08X is the SAME words as "
                             "Raiden's - then it is not his" % (who, addr))
        body = sib[1:63]
        want = green_dominant if hue == "green" else red_dominant
        if sum(1 for c in body if want(c)) < len(body) // 2:
            raise SystemExit("%s's glow palette %08X is not mostly %s - the "
                             "sibling check has landed on the wrong address"
                             % (who, addr, hue))

    # --- anchor 4: the bolt really is drawn in three of its slots ---------
    frames = rom.lane(MK1_BOLT_LANE, limit=40)
    if len(frames) < 6:
        raise SystemExit("the bolt lane at %08X walks to %d frames"
                         % (MK1_BOLT_LANE, len(frames)))
    used = set()
    for frame, _dx, _dy in frames:
        for p in mk1_pieces(rom, frame):
            used.update(p["px"])
    if not used <= MK1_BOLT_SLOTS:
        raise SystemExit("the bolt lane uses slots %s - a bolt is drawn in %s"
                         % (sorted(used), sorted(MK1_BOLT_SLOTS)))
    core, mid, edge = words[62], words[35], words[14]
    if not lum(edge) < lum(mid) < lum(core):
        raise SystemExit("slots 14/35/62 are not dark-to-light (%.1f/%.1f/%.1f)"
                         " - the bolt has a white core and a violet edge"
                         % (lum(edge), lum(mid), lum(core)))
    return words


def mk1_frames(rom: Mk1Rom):
    """-> [(name, description, w, h, anix, aniy, rows)]"""
    out = []

    frames = rom.lane(MK1_BOLT_LANE, limit=40)
    frame, _dx, _dy = frames[MK1_BOLT_FRAME]
    w, h, ax, ay, rows = lay_pieces(mk1_pieces(rom, frame))
    out.append(("MK1LTNG1", "branching bolt, lane %08X frame %d"
                % (MK1_BOLT_LANE, MK1_BOLT_FRAME), w, h, ax, ay, rows))

    lane = rom.ani(MK1_RAIDEN, MK1_GLOW_SLOT)
    glow = rom.lane(lane, limit=40)
    if not glow:
        raise SystemExit("raiden_anitab[%d] (%08X) walks to nothing"
                         % (MK1_GLOW_SLOT, lane))
    frame, _dx, _dy = glow[0]
    w, h, ax, ay, rows = lay_pieces(mk1_pieces(rom, frame))
    spread = len(set(v for r in rows for v in r))
    if spread < 40:
        raise SystemExit("raiden_anitab[%d] frame 0 uses only %d slots - it is "
                         "meant to sweep the ramp" % (MK1_GLOW_SLOT, spread))
    out.append(("MK1LTNG2", "glow silhouette, raiden_anitab[%d] frame 0, %d "
                "of 64 slots" % (MK1_GLOW_SLOT, spread), w, h, ax, ay, rows))
    return out


# ---------------------------------------------------------------------------
def collect():
    """-> (palette rows, image rows).  Every anchor is proved before either
    list is returned, so nothing partial is ever written."""
    rom = umk3_rom()
    bright = jade_bright(rom)
    jw, jh, jax, jay, jrows = jade_frame()

    mk1 = Mk1Rom(MK1_ZIP, gfx=True)
    light = mk1_lightning(mk1)

    pals = [
        ("JDBRITE_P", "UMK3 jade_bright_p - %08X" % JADE_BRIGHT_BIT, bright),
        ("MK1LTNG_P", "MK1 Raiden's lightning - %08X" % MK1_LIGHT, light),
    ]
    imgs = [("JDBRITE1", "Jade's low kick (%s), the shadow kick's pose"
             % "+".join(JADE_FRAME), jw, jh, jax, jay, jrows, "JDBRITE_P")]
    for name, desc, w, h, ax, ay, rows in mk1_frames(mk1):
        imgs.append((name, desc, w, h, ax, ay, rows, "MK1LTNG_P"))
    return pals, imgs


def report(pals, imgs, show_rgb):
    have = {}
    if TARGET.exists():
        have = dict((n.upper(), w) for n, w in ip.palettes(TARGET))
    for name, desc, words in pals:
        slot = have.get(name.upper())
        state = ("new" if slot is None else
                 "current" if slot == words else "DRIFTED")
        print("  %-10s %-46s %2d entries  %s"
              % (name, desc, len(words), state))
        if show_rgb:
            for i in range(0, len(words), 8):
                print("       %2d  %s"
                      % (i, " ".join(rgb(c) for c in words[i:i + 8])))
    print()
    for name, desc, w, h, ax, ay, rows, palname in imgs:
        used = len(set(v for r in rows for v in r))
        print("  %-10s %-46s %3dx%-3d anchor %3d,%-4d %2d slots  under %s"
              % (name, desc, w, h, ax, ay, used, palname))


def apply_or_check(pals, imgs, check: bool) -> int:
    if TARGET.exists():
        hdr, images, libpals, img_first = read_lib(TARGET)
    else:
        if check:
            print("MISSING %s - run --apply to create it" % TARGET.name)
            return 1
        hdr, images, libpals, img_first = list(BLANK_HDR), [], [], True

    known = {ip.cstr(r[0]).upper(): i for i, (r, _w) in enumerate(libpals)}
    bad, changed = 0, []
    for name, _desc, words in pals:
        i = known.get(name.upper())
        if i is None:
            if check:
                print("MISSING %s: %s carries no such palette"
                      % (name, TARGET.name))
                bad += 1
                continue
            libpals.append((pal_record(name, words), words))
            known[name.upper()] = len(libpals) - 1
            changed.append("+" + name)
        elif libpals[i][1] != words:
            if check:
                print("DRIFT   %s: %s has %d entries, the ROM has %d"
                      % (name, TARGET.name, len(libpals[i][1]), len(words)))
                bad += 1
                continue
            libpals[i] = (libpals[i][0], words)
            changed.append("~" + name)

    # palnum is resolved against the palette list AS IT NOW STANDS - the
    # header counts NUMDEFPAL phantom palettes, so the first real one is 3.
    palnum = {ip.cstr(r[0]).upper(): i + NUMDEFPAL
              for i, (r, _w) in enumerate(libpals)}
    hi = {ip.cstr(r[0]).upper(): i for i, (r, _px) in enumerate(images)}
    for name, _desc, w, h, ax, ay, rows, palname in imgs:
        pn = palnum.get(palname.upper())
        if pn is None:
            print("!! %s: palette %s is not in %s"
                  % (name, palname, TARGET.name))
            bad += 1
            continue
        px = img_bytes(w, h, rows)
        rec = img_record(name, w, h, ax, ay, pn)
        i = hi.get(name.upper())
        if i is None:
            if check:
                print("MISSING %s: %s carries no such image"
                      % (name, TARGET.name))
                bad += 1
                continue
            images.append((rec, px))
            hi[name.upper()] = len(images) - 1
            changed.append("+" + name)
        elif images[i][1] != px or list(images[i][0][2:7]) != list(rec[2:7]):
            if check:
                print("DRIFT   %s: %s has %dx%d/pal %d, the ROM has %dx%d/pal %d"
                      % (name, TARGET.name, images[i][0][4], images[i][0][5],
                         images[i][0][6], w, h, pn))
                bad += 1
                continue
            images[i] = (rec, px)
            changed.append("~" + name)

    if check:
        print("%s: %d palettes, %d frames checked"
              % (TARGET.name, len(pals), len(imgs)))
        return bad

    blob = write_lib(hdr, images, libpals, img_first)
    if not TARGET.exists() or blob != TARGET.read_bytes():
        TARGET.write_bytes(blob)
        print("wrote %s (%d bytes): %s"
              % (TARGET.name, len(blob), " ".join(changed) or "no change"))
    else:
        print("%s is already current" % TARGET.name)
    return 0


def write_pngs(pals, imgs, out: Path):
    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("--png needs Pillow (pip install pillow)")
    out.mkdir(parents=True, exist_ok=True)
    words = dict((n.upper(), w) for n, _d, w in pals)
    for name, _desc, w, h, _ax, _ay, rows, palname in imgs:
        pal = words[palname.upper()]
        img = Image.new("RGB", (w, h))
        img.putdata([(((pal[v] >> 10) & 31) * 255 // 31,
                      ((pal[v] >> 5) & 31) * 255 // 31,
                      (pal[v] & 31) * 255 // 31) if v < len(pal)
                     else (255, 0, 255) for r in rows for v in r])
        img.resize((w * 2, h * 2), Image.NEAREST).save(out / ("%s.png" % name))
        print("  %s -> %s" % (name, out / ("%s.png" % name)))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true",
                    help="create or update data/FXPALS.IMG")
    ap.add_argument("--check", action="store_true",
                    help="fail if the IMG no longer matches the ROMs")
    ap.add_argument("--rgb", action="store_true", help="print the colours")
    ap.add_argument("--png", metavar="DIR", help="write PNG previews")
    args = ap.parse_args()

    pals, imgs = collect()
    if args.apply or args.check:
        return apply_or_check(pals, imgs, args.check)
    print("=== %s ===" % TARGET.name)
    report(pals, imgs, args.rgb)
    if args.png:
        write_pngs(pals, imgs, Path(args.png))
    else:
        print("\n--apply writes them; --png DIR renders the frames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
