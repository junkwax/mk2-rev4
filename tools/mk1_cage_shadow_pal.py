#!/usr/bin/env python3
r"""Pull Johnny Cage's SHADOW palette out of MK1 (mk.zip, rev 5.0 T-unit),
and derive a shadow version of any BODY palette from it.

Nothing here is remembered: the palette pointer is read off the first record of
the shadow art group, which is reached by walking Cage's own animation table.

    python tools/mk1_cage_shadow_pal.py                      # -> tmp/mk1_cage_shadow/
    python tools/mk1_cage_shadow_pal.py --check              # verify the anchors only
    python tools/mk1_cage_shadow_pal.py --shadowize CAGE_P   # shadow a BODY palette

Cage is ochar 0.  Two of his lanes draw the shadow kick:
  * 21h - the green silhouette of Cage himself (the shadow that leaves his body)
  * 22h - the comet streak it flies behind
Both live in one record group, ffedd6a0..; the group's first record carries
`.long palette` at +96 bits (MK1 record = .word W,H,anix,aniy / .long SAG, and
only a group's first record adds the palette).  That pointer is ffe99f10, a
64-entry ramp: black -> deep green -> bright green -> white.  Cage's own body
palette is ffe99b00 (browns/flesh) - a different palette, do not confuse them.

Colour word is xRRRRRGGGGGBBBBB, 5 bits per channel, same shape as MK2's.

MK1's shadow is its OWN ART, not a recolour.  The lane-21h records are 6bpp
pictures in their own right (60 distinct indices), and none is pixel-identical
to any frame in Cage's body lanes - so there is no index-for-index remap to
lift.  To shadow a body palette you have to DERIVE one, which is what
`--shadowize` and `--allpal` do.

They do NOT map onto MK1's ramp.  That ramp climbs to white, so mapping onto it
reproduces MK1's BRIGHT GREEN GHOST - correct as a copy of MK1, wrong as a
shadow.  Three ramps are available via `--ramp`:

  teal      (default) `tint_ramp` - MEASURED off a reference shadow trail.
            Red is held down while green and blue climb, so the darks are
            near-neutral and only the highlights go cyan.  `--scale` darkens
            or brightens it without changing that character.
  grey      `grey_ramp` - dark neutral, `--grey-top` (default 8 of 31).
  mk1green  MK1's own ramp, i.e. a copy of MK1's ghost.

`MK1JCSH_P` in ALLPAL.IMG is always MK1's ramp VERBATIM regardless of --ramp:
it is measured data, not a derivation, and it is the reference the other two
are meant to be compared against.

Index 0 stays transparent.  Anything darker than the ramp's floor lands on pure
black, which is OPAQUE in a 6bpp sprite - same as MK1's own index 1.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mk1_shang_souls_extract as M  # noqa: E402

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None

CAGE = 0                    # ochar
ANI_STANCE = 0x00
ANI_SHADOW_BODY = 0x21      # green Cage silhouette
ANI_SHADOW_STREAK = 0x22    # the comet streak
GROUP_FIRST = 0xFFEDD6A0    # first record of the shadow group (carries the palette)
EXPECT_PAL = 0xFFE99F10
MK1_BODY_PAL = 0xFFE99B00   # MK1 Cage's own body palette
MK1_RAMP = []               # filled from the ROM at run time (--ramp mk1green)

# THE SHADOW-KICK PALETTE ITSELF, found by live capture and then located in the
# ROM.  It is a CODE palette - nothing in the art names it - which is why a
# sweep of palettes named by sprite groups missed it, exactly as MK2's own
# green_cage1_p/red_cage_p and UMK3's jade_bright_p are code palettes.
# Proved three ways: byte-identical to MAME colour map 5 during a real shadow
# kick; exactly ONE 32-bit reference in the program ROM (FFDAD660, preceded by
# MOVI <32>,An); and 38 of its 64 entries are the single flat colour 10A6.
MK1_SHADOW_PAL = 0xFFDAD980
MK1_SHADOW_REF = 0xFFDAD660     # where that pointer sits; MOVI is the word before
MK1_SHADOW_FLAT = 0x10A6        # (4,5,6) - the dark body colour

OUT = M.REPO / "tmp" / "mk1_cage_shadow"


def lum(c):
    return 0.299 * ((c >> 10) & 31) + 0.587 * ((c >> 5) & 31) + 0.114 * (c & 31)


def shadowize(src, ramp):
    """each source colour -> the shadow-ramp colour of the same luminance"""
    return [0] + [min(ramp, key=lambda s: abs(lum(s) - lum(c))) for c in src[1:]]


# --- the TEAL ramp, MEASURED off a reference screenshot -------------------
# 44k shadow-trail pixels sampled and bucketed by luminance: red stays low and
# almost flat while green and blue climb together, so the trail is CYAN, not
# blue - near-neutral in the darks, teal in the highlights.  The bulk of the
# pixels (17k of 44k) sit at the dark end, which is what makes it read as a
# shadow rather than as a coloured man.  Endpoints in 5-bit channels:
#     darkest  (25,28,33)/255 -> (3, 3, 4)
#     brightest(62,121,133)/255 -> (8,15,16)
TINT_DARK = (3, 3, 4)
TINT_BRIGHT = (8, 15, 16)

GREY_TOP = 8            # brightest level a grey shadow reaches, of 31


def tint_ramp(src, dark=TINT_DARK, bright=TINT_BRIGHT, scale=1.0):
    """A TEAL shadow: the source palette's own luminance order interpolated
    between two measured endpoints, per channel.

    Neutral grey was wrong and so was a flat blue tint.  The reference ramps
    the CHANNELS AT DIFFERENT RATES - red barely moves (3 -> 8 of 31) while
    green and blue nearly quintuple (3 -> 15, 4 -> 16) - so the darks come out
    almost neutral and only the highlights go cyan.  A single hue applied at
    constant saturation cannot do that.

    `scale` multiplies both endpoints if the whole thing wants to be darker or
    brighter without changing its character.
    """
    ls = [lum(c) for c in src[1:]]
    lo, hi = min(ls), max(ls)
    span = (hi - lo) or 1
    out = [0]
    for c in src[1:]:
        t = (lum(c) - lo) / span
        v = []
        for d, b in zip(dark, bright):
            x = int(round((d + t * (b - d)) * scale))
            v.append(max(0, min(31, x)))
        out.append((v[0] << 10) | (v[1] << 5) | v[2])
    return out

def grey_ramp(src, top=GREY_TOP, floor=0):
    """A DARK NEUTRAL shadow: the source palette's own luminance order, spread
    across `floor`..`top` of 31 with R=G=B.

    MK1's ramp is the wrong shape for this - it climbs all the way to white, so
    mapping onto it gives a BRIGHT ghost (which is what MK1's shadow kick is)
    rather than a shadow.  This compresses into the dark end instead and drops
    the hue entirely.  Contrast is low by construction: that is what a shadow
    looks like, and `top` is the one knob - 6 is nearly black, 14+ reads as a
    grey photograph of the man rather than his shadow.

    The spread is over the source's OWN luminance range, not 0..31, so a
    costume that never reaches white still uses the whole ramp.
    """
    ls = [lum(c) for c in src[1:]]
    lo, hi = min(ls), max(ls)
    span = (hi - lo) or 1
    out = [0]
    for c in src[1:]:
        t = (lum(c) - lo) / span
        v = max(0, min(31, int(round(floor + t * (top - floor)))))
        out.append((v << 10) | (v << 5) | v)
    return out


def learned_ramp(rom, src):
    """Shadow a palette the way MK1 ACTUALLY does, learned from its own pair.

    MK1's shadow palette is index-aligned with Cage's BODY palette, so the two
    together define a transfer function: body luminance -> shadow colour.  It
    is not a smooth ramp - 38 of 64 entries are one flat dark colour and only
    the brightest sixth of the body palette gets the teal highlight run - which
    is why every hand-built ramp looked wrong.

    Self-tested in `check_learned_ramp`: relearning from MK1's own body palette
    reproduces MK1's shadow palette 63 of 64 entries exactly.
    """
    body, shad = rom.palette(MK1_BODY_PAL), rom.palette(MK1_SHADOW_PAL)
    pairs = sorted(((lum(body[i]), shad[i])
                    for i in range(1, min(len(body), len(shad)))), key=lambda q: q[0])
    ls = [lum(c) for c in src[1:]]
    lo, hi = min(ls), max(ls)
    span = (hi - lo) or 1
    blo, bhi = pairs[0][0], pairs[-1][0]
    bspan = (bhi - blo) or 1
    out = [0]
    for c in src[1:]:
        want = blo + (lum(c) - lo) / span * bspan
        out.append(min(pairs, key=lambda q: abs(q[0] - want))[1])
    return out


def check_learned_ramp(rom):
    """the transfer function must rebuild MK1's own shadow palette"""
    shad = rom.palette(MK1_SHADOW_PAL)
    back = learned_ramp(rom, rom.palette(MK1_BODY_PAL))
    same = sum(1 for a, b in zip(back, shad) if a == b)
    if same < len(shad) - 2:
        sys.exit("learned ramp rebuilds only %d of %d entries of %08X"
                 % (same, len(shad), MK1_SHADOW_PAL))
    return same, len(shad)


def locate_shadow(rom):
    """MK1_SHADOW_PAL, re-proved rather than trusted"""
    w = rom.palette(MK1_SHADOW_PAL)
    if len(w) != 64:
        sys.exit("%08X is %d entries, not 64" % (MK1_SHADOW_PAL, len(w)))
    flat = sum(1 for c in w if c == MK1_SHADOW_FLAT)
    if flat < 30:
        sys.exit("%08X has only %d entries of the flat body colour %04X - "
                 "not the shadow palette" % (MK1_SHADOW_PAL, flat, MK1_SHADOW_FLAT))
    import struct
    refs = rom.p.count(struct.pack("<I", MK1_SHADOW_PAL))
    if refs != 1:
        sys.exit("%08X has %d references in the program ROM, expected exactly 1"
                 % (MK1_SHADOW_PAL, refs))
    # MK1_SHADOW_REF is where the 32-bit POINTER sits; the opcode is the word
    # before it (MOVI IL,An = 0000 1001 111R RRRR)
    if rom.w(MK1_SHADOW_REF - 16) & 0xFFE0 != 0x09E0:
        sys.exit("the word before %08X is %04X, not a MOVI <32>,An"
                 % (MK1_SHADOW_REF, rom.w(MK1_SHADOW_REF - 16)))
    return w, flat


def read_asm_palette(path, label):
    """pull a `.word n / .word ...` palette out of a hand-maintained IMGPAL file"""
    marker = "\n" + label + ":\n"
    blk = path.read_text().split(marker, 1)[1].split("\n\n", 1)[0]
    n = int(re.search(r"\.word\s+(\d+)", blk).group(1))
    cols = [int(w, 16) for w in re.findall(r"0?([0-9A-Fa-f]+)H", blk)][:n]
    if len(cols) != n:
        sys.exit("%s: expected %d colours, parsed %d" % (label, n, len(cols)))
    return cols


def asm_block(label, cols, note):
    head = "; %s\n\n\t.globl\t%s\n\n%s:\n\t.word\t%d\n" % (note, label, label, len(cols))
    return head + "".join(
        "\t.word\t" + ",".join("0%04XH" % c for c in cols[i:i + 8]) + "\n"
        for i in range(0, len(cols), 8))


def locate(rom):
    """the shadow palette, found rather than assumed"""
    first = rom.pieces(rom.lane(rom.ani(CAGE, ANI_SHADOW_STREAK), parts=1)[0][0])[0]
    if first != GROUP_FIRST:
        sys.exit("streak lane no longer starts at %08x (got %08x) - not rev 5.0 mk?"
                 % (GROUP_FIRST, first))
    pal = rom.l(first + 96)
    if pal != EXPECT_PAL or rom.w(pal) != 64:
        sys.exit("shadow palette moved: %08x (%d colours)" % (pal, rom.w(pal)))
    # the whole shadow block is ONE group: no other record in it names a palette,
    # which is what makes lane 21h (the body silhouette) share lane 22h's palette
    extra = [a for a in range(0xFFEDC000, 0xFFEDE800, 16)
             if a != first and (rom.l(a + 96) >> 20) == 0xFFE
             and rom.l(a + 96) % 8 == 0 and 1 <= rom.w(rom.l(a + 96)) <= 256
             and 0 < rom.w(a) < 400 and 0 < rom.w(a + 16) < 400]
    if extra:
        sys.exit("more than one palette in the shadow block: %s"
                 % " ".join("%08x" % a for a in extra))
    return pal


def render_words(rom, frames, words):
    """M.render, but driven by colour WORDS instead of a palette address"""
    cols = [(((c >> 10) & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31,
             (c & 31) * 255 // 31) for c in words]
    placed, xs, ys = [], [0], [0]
    for frame, dx, dy in frames:
        ps = []
        for pa in rom.pieces(frame):
            im = rom.image(pa)
            x, y = dx - im["anix"], dy - im["aniy"]
            ps.append((im, x, y))
            xs += [x, x + im["w"]]
            ys += [y, y + im["h"]]
        placed.append(ps)
    x0, y0 = min(xs) - 2, min(ys) - 2
    W, H = max(xs) - x0 + 2, max(ys) - y0 + 2
    out = []
    for ps in placed:
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        px = img.load()
        for im, x, y in ps:
            for yy, row in enumerate(rom.pixels(im)):
                for xx, v in enumerate(row):
                    if v:
                        px[x - x0 + xx, y - y0 + yy] = cols[v] + (255,)
        out.append(img)
    return out


def band(rom, frames, pal):
    """one filmstrip; `pal` is either a palette ADDRESS or a list of colour words"""
    if isinstance(pal, int):
        imgs, _, _ = M.render(rom, frames, pal)
    else:
        imgs = render_words(rom, frames, pal)
    w, h = imgs[0].size
    s = Image.new("RGBA", (w * len(imgs), h), (0, 0, 0, 255))
    for i, im in enumerate(imgs):
        s.alpha_composite(im, (i * w, 0))
    return s


def composite(rom, frame):
    """One MK1 frame's pieces flattened into a canvas of 8-bit palette indices -
    the form an IMG library stores - plus the canvas's own anipoint.

    A piece is drawn at anchor - (anix, aniy), so the canvas's anipoint is
    MINUS its top-left corner in anchor space, in BOTH axes.  Getting the y
    sign wrong is silent - the frame still writes, still round-trips and still
    passes a drift check, because nothing else in the file disagrees with it.
    `check_anipoint_convention` is what actually pins it.
    """
    pieces = [rom.image(p) for p in rom.pieces(frame)]
    x0 = min(-p["anix"] for p in pieces)
    y0 = min(-p["aniy"] for p in pieces)
    w = max(p["w"] - p["anix"] for p in pieces) - x0
    h = max(p["h"] - p["aniy"] for p in pieces) - y0
    rows = [bytearray(w) for _ in range(h)]
    for p in pieces:
        px, py = -p["anix"] - x0, -p["aniy"] - y0
        for yy, row in enumerate(rom.pixels(p)):
            dst = rows[py + yy]
            for xx, v in enumerate(row):
                if v:
                    dst[px + xx] = v
    return w, h, -x0, -y0, [bytes(r) for r in rows]


def check_anipoint_convention(rom, images, inames, s16):
    """Rebuild a frame ALLPAL ALREADY carries and require the geometry to match.
    ALLPAL's MK1CAGEST1 is MK1 Cage's stance frame 1, so it can be recomputed
    from the ROM outright - and it is the only thing that can prove the sign of
    the anipoint we write for a frame the library does NOT already have."""
    if "MK1CAGEST1" not in inames:
        sys.exit("ALLPAL.IMG carries no MK1CAGEST1 to pin the anipoint against")
    rec = images[inames.index("MK1CAGEST1")][0]
    have = (rec[4], rec[5], s16(rec[2]), s16(rec[3]))
    w, h, ax, ay, _rows = composite(rom, rom.lane(rom.ani(CAGE, ANI_STANCE),
                                                 parts=1, limit=24)[0][0])
    if (w, h, ax, ay) != have:
        sys.exit("anipoint convention disagrees: MK1CAGEST1 is %dx%d (%d,%d) in "
                 "ALLPAL.IMG but recomputes to %dx%d (%d,%d)"
                 % (have + (w, h, ax, ay)))


def derive(src, args):
    """the shadow ramp the command line asked for"""

    if args.ramp == "mk1shadow":
        return learned_ramp(args._rom, src)
    if args.ramp == "grey":
        return grey_ramp(src, args.grey_top)
    if args.ramp == "mk1green":
        return shadowize(src, sorted(set(MK1_RAMP[1:]), key=lum))
    return tint_ramp(src, scale=args.scale)


def allpal_apply(rom, pal, cols, check: bool, args) -> int:
    """Add the shadow palettes to data/ALLPAL.IMG, each with a frame that can
    actually be judged in it.  Reuses the library's OWN pixels wherever it
    already carries the right art, so nothing is re-decoded that need not be."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import backup_code_palettes as B          # noqa: E402
    import img_palette as ip                  # noqa: E402

    target = M.REPO / "data" / "ALLPAL.IMG"
    if not target.exists():
        sys.exit("%s does not exist" % target)
    hdr, images, pals, img_first = B.read_lib(target)
    # The guard is SEMANTIC, not byte-identity.  A library the user has saved
    # from IMGTOOL normally carries slack - dead bytes from records that moved
    # or shrank - so a byte-identical round-trip fails on a perfectly good file
    # and refuses to write (it did, on a save with 120 bytes of slack).  What
    # actually has to hold is that rebuilding loses nothing: every image with
    # its pixels and geometry, every palette with its words and name.
    rebuilt = B.write_lib(hdr, images, pals, img_first)
    raw = target.read_bytes()
    if rebuilt != raw:
        import tempfile, os
        t = Path(tempfile.gettempdir()) / "_allpal_roundtrip.img"
        t.write_bytes(rebuilt)
        try:
            _h, im2, pa2, _f = B.read_lib(t)
        finally:
            os.remove(t)
        lost = []
        if len(im2) != len(images):
            lost.append("image count %d -> %d" % (len(images), len(im2)))
        if len(pa2) != len(pals):
            lost.append("palette count %d -> %d" % (len(pals), len(pa2)))
        for i in range(min(len(images), len(im2))):
            if images[i][1] != im2[i][1] or list(images[i][0][0:7]) != list(im2[i][0][0:7]):
                lost.append("image %d (%s)" % (i, ip.cstr(images[i][0][0])))
        for i in range(min(len(pals), len(pa2))):
            if pals[i][1] != pa2[i][1] or pals[i][0][0] != pa2[i][0][0]:
                lost.append("palette %d (%s)" % (i, ip.cstr(pals[i][0][0])))
        if lost:
            sys.exit("%s does not survive a rebuild - refusing to touch it:\n  %s"
                     % (target.name, "\n  ".join(lost[:8])))
        print("   (%s carries %d bytes of slack; the rebuild drops it and loses "
              "nothing)" % (target.name, len(raw) - len(rebuilt)))

    pnames = [ip.cstr(r[0]) for r, _w in pals]
    inames = [ip.cstr(r[0]) for r, _p in images]

    # provenance: the library's MK1CAGE_P must BE the ROM's body palette, or
    # the frame we are about to shadow is not the art we measured
    if "MK1CAGE_P" not in pnames:
        sys.exit("ALLPAL.IMG carries no MK1CAGE_P to anchor against")
    if pals[pnames.index("MK1CAGE_P")][1] != rom.palette(MK1_BODY_PAL):
        sys.exit("ALLPAL.IMG's MK1CAGE_P is not the ROM's %08x - anchor moved"
                 % MK1_BODY_PAL)

    def asm_pal(label):
        hits = [p for p in sorted(M.REPO.glob("src/IMGPAL*.ASM"))
                if ("\n" + label + ":\n") in p.read_text()]
        if len(hits) != 1:
            sys.exit("%s: found in %d IMGPAL files" % (label, len(hits)))
        return read_asm_palette(hits[0], label)

    def lib_frame(name):
        rec, px = images[inames.index(name)]
        w, h = rec[4], rec[5]
        stride = (w + 3) & ~3
        return w, h, s16(rec[2]), s16(rec[3]), [px[y * stride:y * stride + w]
                                                for y in range(h)]

    def s16(v):
        return v - 0x10000 if v & 0x8000 else v

    check_anipoint_convention(rom, images, inames, s16)
    shadow_words, flat = locate_shadow(rom)
    relearn = check_learned_ramp(rom)
    shadow_frame = composite(rom, rom.lane(rom.ani(CAGE, ANI_SHADOW_BODY),
                                           parts=1, limit=24)[0][0])
    mw, mh, max_, may, mrows = shadow_frame
    entries = [
        # palette     words                                frame name       frame
        ("MK1JCSH_P", cols,
         "MK1's shadow ramp at %08x, verbatim" % EXPECT_PAL,
         "MK1JCSHADOW1", (mw, mh, max_, may, mrows)),
        ("MK1SHAD_P", shadow_words,
         "MK1's REAL shadow-kick palette %08x, verbatim (%d of 64 entries are "
         "the flat body colour %04X)" % (MK1_SHADOW_PAL, flat, MK1_SHADOW_FLAT),
         "MK1SHADOW1", lib_frame("MK1CAGEST1")),
        ("MK1JCBS_P", derive(rom.palette(MK1_BODY_PAL), args),
         "MK1CAGE_P (%08x) through the %s rule - rebuilds the real one %d/%d"
         % (MK1_BODY_PAL, args.ramp, relearn[0], relearn[1]),
         "MK1CAGESHAD1", lib_frame("MK1CAGEST1")),
        ("JCSHAD_P", derive(asm_pal("CAGE_P"), args),
         "MK2's CAGE_P as a %s shadow" % args.ramp,
         "JCSHADST1", lib_frame("JCSTANCE1")),
    ]

    bad, changed = 0, []
    for pname, words, _desc, fname, (w, h, ax, ay, rows) in entries:
        used = max(max(r) for r in rows)
        if used >= len(words):
            sys.exit("%s uses index %d but %s has only %d colours"
                     % (fname, used, pname, len(words)))
        i = pnames.index(pname) if pname in pnames else None
        if i is None:
            if check:
                print("MISSING %s: ALLPAL.IMG carries no such palette" % pname)
                bad += 1
            else:
                pals.append((B.pal_record(pname, words), words))
                pnames.append(pname)
                changed.append("+" + pname)
        elif pals[i][1] != words:
            if check:
                print("DRIFT   %s: ALLPAL.IMG has %d colours, we derive %d"
                      % (pname, len(pals[i][1]), len(words)))
                bad += 1
            else:
                pals[i] = (pals[i][0], words)
                changed.append("~" + pname)

        if pname not in pnames:          # check mode, palette absent
            print("MISSING %s: no palette to index its frame against" % fname)
            bad += 1
            continue
        pn = pnames.index(pname) + B.NUMDEFPAL
        stride = (w + 3) & ~3
        px = b"".join(r + b"\0" * (stride - w) for r in rows)
        rec = [fname.encode("ascii")[:15], 0, ax & 0xFFFF, ay & 0xFFFF,
               w, h, pn, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        j = inames.index(fname) if fname in inames else None
        if j is None:
            if check:
                print("MISSING %s: ALLPAL.IMG carries no such frame" % fname)
                bad += 1
            else:
                images.append((rec, px))
                inames.append(fname)
                changed.append("+" + fname)
        elif images[j][1] != px or list(images[j][0][2:7]) != rec[2:7]:
            if check:
                print("DRIFT   %s: frame or palette index moved" % fname)
                bad += 1
            else:
                images[j] = (rec, px)
                changed.append("~" + fname)

    if check:
        print("ALLPAL.IMG: %d palettes + %d frames checked, %d off"
              % (len(entries), len(entries), bad))
        return bad

    blob = B.write_lib(hdr, images, pals, img_first)
    if blob == target.read_bytes():
        print("ALLPAL.IMG is already current")
        return 0
    bak = target.with_suffix(".IMG.pre_jcshadow.bak")
    if not bak.exists():
        bak.write_bytes(target.read_bytes())
        print("backed up -> %s" % bak.name)
    target.write_bytes(blob)
    print("wrote ALLPAL.IMG (%d bytes, %d images, %d palettes): %s"
          % (len(blob), len(images), len(pals), " ".join(changed)))
    for pname, words, desc, fname, _f in entries:
        print("   %-10s %2d colours  judged on %-13s  %s"
              % (pname, len(words), fname, desc))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify anchors, write nothing")
    ap.add_argument("--ramp",
                    choices=("mk1shadow", "teal", "grey", "mk1green"),
                    default="mk1shadow",
                    help="mk1shadow (default, MK1's real shadow-kick transfer "
                         "function), teal (fitted off a screenshot), grey "
                         "(dark neutral), mk1green (MK1's glow ramp)")
    ap.add_argument("--scale", type=float, default=1.0, metavar="F",
                    help="darken/brighten the teal ramp without changing its "
                         "character (default 1.0)")
    ap.add_argument("--grey-top", type=int, default=GREY_TOP, metavar="N",
                    help="brightest level a derived shadow reaches, of 31 "
                         "(default %d; 6 is nearly black, 14+ stops reading as "
                         "a shadow)" % GREY_TOP)
    ap.add_argument("--allpal", action="store_true",
                    help="add the shadow palettes (+ a frame each) to data/ALLPAL.IMG")
    ap.add_argument("--shadowize", metavar="LABEL", nargs="*",
                    help="also emit <LABEL>SHAD_P: a body palette from src/IMGPAL*.ASM "
                         "mapped onto MK1's shadow ramp (default CAGE_P)")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()

    rom = M.Rom(M.ROM_ZIP)
    args._rom = rom
    pal = locate(rom)
    cols = rom.palette(pal)
    rgb = [(((c >> 10) & 31), ((c >> 5) & 31), (c & 31)) for c in cols]
    if args.allpal:
        global MK1_RAMP
        MK1_RAMP = cols
        raise SystemExit(allpal_apply(rom, pal, cols, args.check, args))
    if args.check:
        print("OK  shadow palette %08x, %d colours (MK1 body palette %08x)"
              % (pal, len(cols), MK1_BODY_PAL))
        return

    out = args.out
    out.mkdir(parents=True, exist_ok=True)

    (out / "MK1JCSHAD.ASM").write_text(
        "; MK1 Johnny Cage's SHADOW palette, read out of mk.zip at %08x by\n"
        "; tools/mk1_cage_shadow_pal.py.  64 colours, xRRRRRGGGGGBBBBB.\n"
        "; Used by MK1 Cage lanes 21h (green silhouette) and 22h (streak).\n\n"
        % pal + asm_block("MK1JCSHAD_P", cols, "MK1's own shadow ramp, verbatim"))

    (out / "palette.json").write_text(json.dumps(
        dict(source="mk.zip (MK1 rev 5.0, T-unit)", address="%08x" % pal,
             group_first="%08x" % GROUP_FIRST,
             lanes={"21": "shadow silhouette", "22": "shadow streak"},
             mk1_body_palette="%08x" % MK1_BODY_PAL,
             format="xRRRRRGGGGGBBBBB, 5 bits per channel",
             words=["%04x" % c for c in cols],
             rgb5=[list(t) for t in rgb],
             rgb8=[[(v << 3) | (v >> 2) for v in t] for t in rgb]), indent=1))

    if Image is not None:
        sw = Image.new("RGB", (8 * 24, 8 * 24))
        px = sw.load()
        for i, (r, g, b) in enumerate(rgb):
            c = ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2))
            ox, oy = (i % 8) * 24, (i // 8) * 24
            for y in range(24):
                for x in range(24):
                    px[ox + x, oy + y] = c
        sw.save(out / "swatch.png")
        for name, ani in (("21_shadow_body", ANI_SHADOW_BODY),
                          ("22_shadow_streak", ANI_SHADOW_STREAK)):
            fr = rom.lane(rom.ani(CAGE, ani), parts=1, limit=24)
            band(rom, fr, pal).save(out / ("lane%s.png" % name))

    if args.shadowize is not None:
        chunks = []
        for label in (args.shadowize or ["CAGE_P"]):
            hits = [p for p in sorted(M.REPO.glob("src/IMGPAL*.ASM"))
                    if ("\n" + label + ":\n") in p.read_text()]
            if len(hits) != 1:
                sys.exit("%s: found in %d IMGPAL files" % (label, len(hits)))
            body = read_asm_palette(hits[0], label)
            shad = derive(body, args)
            name = (label[:-2] if label.endswith("_P") else label) + "SHAD_P"
            chunks.append(asm_block(
                name, shad,
                "%s (%s, %d colours) as a %s shadow"
                % (label, hits[0].name, len(body), args.ramp)))
            print("  %-12s -> %-14s %d colours, %d land on pure black"
                  % (label, name, len(shad), sum(1 for c in shad[1:] if c == 0)))
        (out / "SHADPAL.ASM").write_text(
            "; GENERATED by tools/mk1_cage_shadow_pal.py --shadowize - do not edit by hand.\n"
            "; Body palettes as DARK NEUTRAL shadows (see grey_ramp).  MK1's own\n"
            "; ramp climbs to white and gives a bright green ghost, not a shadow.\n\n"
            + "\n".join(chunks))
        if Image is not None:
            # the proof: MK1's own body palette shadowized, beside MK1's real shadow art
            mk1 = derive(rom.palette(MK1_BODY_PAL), args)
            stance = rom.lane(rom.ani(CAGE, ANI_STANCE), parts=1, limit=24)
            shad21 = rom.lane(rom.ani(CAGE, ANI_SHADOW_BODY), parts=1, limit=24)
            bands = [band(rom, stance, MK1_BODY_PAL), band(rom, stance, mk1),
                     band(rom, shad21, pal)]
            W, H = max(b.width for b in bands), sum(b.height for b in bands)
            cmp = Image.new("RGBA", (W, H), (0, 0, 0, 255))
            y = 0
            for b in bands:
                cmp.alpha_composite(b, (0, y))
                y += b.height
            cmp.save(out / "shadowize_compare.png")

    print("shadow palette %08x, %d colours -> %s" % (pal, len(cols), out))


if __name__ == "__main__":
    main()
