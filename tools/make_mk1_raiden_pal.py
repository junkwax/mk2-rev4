#!/usr/bin/env python3
r"""MK1 RAIDEN'S COLOURS ON MK2 RAIDEN'S SPRITE - `M2RDMK1_P` in data/RADPALS.IMG.

The ask: "get the MK1 Raiden palette onto the MK2 Raiden, hat and everything,
without redrawing the sprite".  MK1's palette CANNOT be copied across and no
index map exists between the two.  MK1's 64 entries are a photo QUANTISATION -
unordered, one bucket per colour the digitised costume happened to contain -
while MK2's are AUTHORED RAMPS, where slot k of a group is shade k of one
garment.  Index n means nothing in common across the two files.

So the transfer is by REGION, not by index.  Both sprites are segmented into
garments, and each of MK2's ramp groups is re-coloured with the statistics of
the MK1 garment that plays the same part:

    MK2 slots            what the ART uses them for       MK1 source
    1..17                the TABARD                       the ROBE  (see below)
    18..21, 23, 25..40   the HAT cone, and the bare HANDS the HAT
    22                   the one near-black               the BLACK
    24                   the robe's white highlight       the ROBE, brightest
    41..58               ONE ramp: cloth + shadow + face  the ROBE, floored dark
    59..61               the arm / back EMBLEM            the ROBE  (see below)
    62..63               orange, and #087bff              UNTOUCHED - see below

MK2's groups were READ OFF THE ART, not assumed: `RNSTANCE1` was masked one
group at a time and each group's pixels looked at.  1..17 is the tabard alone,
25..40 the hat cone plus the hands, and 41..58 is one continuous grey ramp in
`RADRED_P` (#181818 -> #f6f6f6) covering sleeves, trousers, boots, cloth
shadow AND the shadowed face.

**THE TABARD IS THE WHOLE PROBLEM, AND IT IS SOLVED BY DISGUISE.**  MK1's
Raiden has no tabard - his torso is open white robe with a narrow black V -
while MK2's is a vest hanging to mid-thigh and is the largest single thing on
the sprite.  It cannot be removed without redrawing, so it is painted in the
SAME CLOTH as the robe and stops reading as a separate garment.  Its 17 slots
are AREA-MATCHED (each takes the MK1 robe's luminance at its own cumulative
share of the tabard's pixels), so the panel's rendered luminance histogram is
the MK1 robe's: mean 189,209,212 against MK1's 189,207,209.

**THE HAT IS AREA-MATCHED TOO, AND LUMINANCE MAPPING IS THE WRONG TOOL THERE.**
MK2's hat is mostly BRIGHT slots, so mapping luminance to luminance parks all
of it in the sparse pink top of MK1's hat and the straw comes out peach.
Matched by area it lands on MK1's tan body (#a47b41, #c59c5a), which is what
the hat actually is.  Hat mean 191,140,88 against MK1's 190,139,85.

**59..61 IS AN EMBLEM, NOT LIGHTNING - CHECKED BEFORE RECOLOURING.**  All 1070
records in data/RAID*.IMG + RADBOLT1 + RAIDWALK that sit on a Raiden palette
were histogrammed: 59..61 appear in small counts (at most 87 px) on ordinary
body frames, which is a garment mark, while 63 (#087bff) is the BOLT art
(RN2BOLT*, up to 188 px) and 62 is two pixels of one stance frame.  63 and 62
are therefore left exactly as `RADRED_P` has them - recolouring 63 would
repaint his lightning.

**THE ELECTRICAL FUZZ IS REAL MK1 DATA, AND A WEIGHTED MEAN DELETES IT.**  MK1's
robe is **21.5% saturated speckle** - violet #9c73ee, electric blue #4a6aee,
cyan #83f6ee, teal #4ab4b4 - scattered single pixels the digitiser left behind,
which read as crackle on the costume.  Averaging the region into a smooth ramp
matches its MEAN and drops its chroma spread from 25.7 to 11.9, and the robe
goes flat.  So the robe is fitted from BOTH halves of the distribution: a
smooth curve and a `speckle_curve`, mixed per slot in proportion to how
scattered THE ART uses that slot (`isolation`, measured on RNSTANCE1 - slots
43..51 are 69-100% isolated dither, the tabard's body slots 9..12 are 10-28%
solid folds).  `--fuzz 0` is the flat version, `--fuzz 1` the default:
spread 19.9 at a mean error of 6.0 instead of 4.4.  **The ceiling is the art,
not the palette** - 25.7 needs more scattered pixels than MK2's sprite has.

WHAT A PALETTE CANNOT DO, stated rather than discovered later:
  * The tabard keeps its BLACK OUTLINE.  The 206 pixels bordering it are index
    22, which is also the belt, the hat's underside and every hand outline, so
    lightening it would wash out the whole sprite.  He reads as a white-robed
    Raiden wearing a white tabard, not as a man with no tabard.
  * The EMBLEM survives the same way - a white medallion inside black line work.
  * MK1's BOOTS are olive-grey; MK2 draws his boots in 48..54, the same ramp as
    his trousers, so they come out robe-coloured.
  * MK1's grey-green forearm BRACERS have no MK2 slot at all.

Fit basis is `RNSTANCE1`, the frame being judged.  The mapping is monotone in
slot index, so every other frame follows it consistently - checked on
RNVICTORY2, RNWALK3, RNHIKICK2, RNTHROBOLT3, RNUPPERCUT2, RNSTUNNED4,
RNJUMPFLIP8, RNSWEEPKICK1, RNDUCKBLOCK2 and RNHIDUCKICK1.

    python tools/make_mk1_raiden_pal.py                 # report the fit only
    python tools/make_mk1_raiden_pal.py --apply         # write into RADPALS.IMG
    python tools/make_mk1_raiden_pal.py --check         # has M2RDMK1_P drifted?
    python tools/make_mk1_raiden_pal.py --preview DIR   # PNG sheets to judge it
    python tools/make_mk1_raiden_pal.py --asm           # an IMGPAL-style block

NOT IN PHASE D, deliberately - `data/MK2PALS.IMG`'s reasoning in reverse.
RADPALS.IMG is in NO LOD, LOAD2 never reads it and no pixel of it reaches a
ROM, so a build gate would only fail the build when the workbench is edited in
IMGTOOL, which is what the workbench is for.  `--check` is here for when it is
wanted.  Nothing in this tool touches the game.

TRAP, and it picked the wrong source here once: `data/KATPAL.IMG` ALSO holds a
record called MK1RAIDST1, and its pixels are indexed against `MK1RAI1_P`
(palnum 145), not `MK1RAID_P` - the same picture, differently indexed, and
drawn under MK1RAID_P it is noise.  So the MK1 pair is read out of RADPALS.IMG
where the record's own palnum resolves to MK1RAID_P BY NAME, and that
resolution is asserted before anything is fitted.
"""
import argparse
import math
import struct
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKBENCH = ROOT / "data" / "RADPALS.IMG"      # read, and written by --apply
MK2_SRC = ROOT / "data" / "RAID1.IMG"          # the shipped MK2 art + RADRED_P

MK1_PAL, MK1_REC = "MK1RAID_P", "MK1RAIDST1"
MK2_PAL, MK2_REC = "RADRED_P", "RNSTANCE1"     # RADRED_P for STRUCTURE, not colour
NEW_PAL, NEW_REC = "M2RDMK1_P", "MK1RDST1"     # 9 chars: the IMG field truncates at 9

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26
NUMDEFPAL = 3                       # palcnt over-counts by 3; palnum = 3 + file index

# --- MK1 segmentation.  Boxes are in MK1RAIDST1's own 71x136 pixels. ---------
MK1_FACE = (26, 17, 49, 41)         # his face reaches ABOVE the brim's y, and its
                                    # forehead and cheek are warm - left in, they
                                    # land in the hat and pink the straw
MK1_BRACER = [(13, 49, 35, 73), (45, 35, 63, 61)]     # the grey-green forearm guards
MK1_BOOT_Y = 108
MK1_DARK = 50                       # below this luminance it is his black V / belt
MK1_WARM = 22                       # R-B over this, with R>G, is straw or skin

ROBE_GAMMA = 0.60                   # fitted: robe mean error 25 -> 2.7
ROBE_FLOOR = 14.0                   # pin the bottom of 41..58 black - it is his face
HAT_GAIN = 0.94                     # fitted: hat mean error 19 -> 3.4
FUZZ = 1.0                          # how much of MK1's electrical speckle to keep
SPECKLE = 34.0                      # chroma above which an MK1 robe colour IS speckle

TABARD = list(range(1, 18))
HAT_FAMILY = [18, 19, 20, 21, 23] + list(range(25, 41))
CLOTH = list(range(41, 59))
EMBLEM = [59, 60, 61]
BLACK_SLOT, WHITE_SLOT = 22, 24


def cstr(b):
    return b.split(b"\0", 1)[0].decode("latin-1", "replace")


def read_img(path):
    """-> (images, palettes) in file order, each keeping its raw record tuple."""
    data = Path(path).read_bytes()
    imgcnt, palcnt, oset = LIB.unpack_from(data, 0)[:3]
    imgs, pals = [], []
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        w, h, off = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        imgs.append(dict(
            name=cstr(r[0]), w=w, h=h, palnum=r[6], raw=r,
            ax=r[2] - 0x10000 if r[2] & 0x8000 else r[2],
            ay=r[3] - 0x10000 if r[3] & 0x8000 else r[3],
            px=[list(data[off + y * stride: off + y * stride + w]) for y in range(h)]))
    p0 = oset + imgcnt * IMAGE.size
    for i in range(max(0, palcnt - NUMDEFPAL)):
        r = PALETTE.unpack_from(data, p0 + i * PALETTE.size)
        cnt, fo = r[3], r[4]
        pals.append(dict(name=cstr(r[0]), palnum=NUMDEFPAL + i, bpp=r[2], raw=r,
                         words=list(struct.unpack_from("<%dH" % cnt, data, fo))))
    return imgs, pals


def write_img(path, imgs, pals):
    """Rebuild the library.  Every record keeps its own raw tuple and only the two
    data offsets are recomputed, so nothing else in the file is disturbed."""
    blob = bytearray()
    pal_offs, img_offs = [], []
    for p in pals:
        pal_offs.append(LIB.size + len(blob))
        blob += struct.pack("<%dH" % len(p["words"]), *p["words"])
    for r in imgs:
        img_offs.append(LIB.size + len(blob))
        stride = (r["w"] + 3) & ~3
        for row in r["px"]:
            blob += bytes(row) + b"\0" * (stride - r["w"])
    oset = LIB.size + len(blob)
    out = bytearray(LIB.pack(len(imgs), len(pals) + NUMDEFPAL, oset,
                             0x0634, 0, 0, 0, 0xABCD, b"\xff\xff\xff\xff", 0, 0, 0))
    out += blob
    for r, off in zip(imgs, img_offs):
        f = list(r["raw"])
        f[0] = r["name"].encode("latin-1").ljust(16, b"\0")[:16]
        f[2] = r["ax"] & 0xFFFF
        f[3] = r["ay"] & 0xFFFF
        f[4], f[5], f[6], f[7] = r["w"], r["h"], r["palnum"], off
        out += IMAGE.pack(*f)
    for p, off in zip(pals, pal_offs):
        f = list(p["raw"])
        f[0] = p["name"].encode("latin-1").ljust(10, b"\0")[:10]
        f[3], f[4] = len(p["words"]), off
        out += PALETTE.pack(*f)
    Path(path).write_bytes(bytes(out))
    return len(out)


def rgb(w):
    return (((w >> 10) & 31) * 255 // 31, ((w >> 5) & 31) * 255 // 31, (w & 31) * 255 // 31)


def to_word(c):
    r, g, b = (min(31, max(0, int(round(v * 31 / 255.0)))) for v in c)
    return (r << 10) | (g << 5) | b


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def inbox(x, y, box):
    x0, y0, x1, y1 = box
    return x0 <= x <= x1 and y0 <= y <= y1


def mk1_regions(rec, words):
    """MK1RAIDST1's pixels -> {region: Counter(rgb -> pixel count)}."""
    cols = [rgb(w) for w in words]
    per = {}
    for y, row in enumerate(rec["px"]):
        for x, v in enumerate(row):
            if not v:
                continue
            c = cols[v]
            r, g, b = c
            if lum(c) < MK1_DARK:
                k = "BLACK"
            elif r - b > MK1_WARM and r > g:
                k = "FLESH" if (y >= 30 or inbox(x, y, MK1_FACE)) else "HAT"
            elif y >= MK1_BOOT_Y:
                k = "BOOT"
            elif any(inbox(x, y, bb) for bb in MK1_BRACER) and g >= b - 8 and r <= g + 8:
                k = "BRACER"
            else:
                k = "ROBE"
            per.setdefault(k, Counter())[c] += 1
    return per


def chroma_curve(hist, sigma=26.0):
    """f(L) -> the region's TYPICAL colour at luminance L.

    Each sample is scaled to L keeping its chroma, then the samples are averaged
    with a Gaussian weight in luminance and their own pixel counts.  A flat
    quantile lookup would hand back one arbitrary photo bucket and make the ramp
    blotchy; this returns the region's colour, at the luminance asked for."""
    pts = [(lum(c), c, n) for c, n in hist.items()]

    def f(target):
        num, den = [0.0, 0.0, 0.0], 0.0
        for l, c, n in pts:
            w = n * math.exp(-((l - target) ** 2) / (2 * sigma * sigma))
            if w <= 0:
                continue
            s = target / l if l > 1 else 1.0
            for i in range(3):
                num[i] += w * c[i] * s
            den += w
        if den == 0:
            return (int(target),) * 3
        o = [num[i] / den for i in range(3)]
        cur = lum(o)
        if cur > 1:                                  # re-hit the luminance exactly
            o = [v * target / cur for v in o]
        return tuple(int(round(max(0, min(255, v)))) for v in o)
    return f


def chroma(c):
    """How far a colour departs from a neutral grey of its own luminance."""
    l = lum(c)
    return max(abs(c[i] - l) for i in range(3))


def speckle_curve(hist, sigma=30.0, floor=SPECKLE):
    """f(L) -> the region's SATURATED colour near L, or None if it has none there.

    MK1's robe is 21.5% saturated speckle - violet #9c73ee, electric blue
    #4a6aee, cyan #83f6ee, teal #4ab4b4 - scattered single pixels left by the
    digitisation.  That IS the electrical crackle on the costume.  A plain
    weighted mean (`chroma_curve`) averages it away and the robe comes out flat:
    chroma spread 11.9 against MK1's 25.7.  This curve is the other half of the
    distribution, so the two can be mixed back together."""
    pts = [(lum(c), c, n) for c, n in hist.items() if chroma(c) >= floor]

    def f(target):
        num, den = [0.0, 0.0, 0.0], 0.0
        for l, c, n in pts:
            w = n * math.exp(-((l - target) ** 2) / (2 * sigma * sigma))
            if w <= 0:
                continue
            s = target / l if l > 1 else 1.0
            for i in range(3):
                num[i] += w * c[i] * s
            den += w
        if den == 0:
            return None
        o = [num[i] / den for i in range(3)]
        cur = lum(o)
        if cur > 1:
            o = [v * target / cur for v in o]
        return tuple(int(round(max(0, min(255, v)))) for v in o)
    return f


def isolation(rec):
    """slot -> the fraction of its pixels with no 4-neighbour of the same slot.

    This is how the art itself says which slots are SPECKLE and which are solid
    shading.  On RNSTANCE1 slots 43..51 are 69-100% isolated (the robe's own
    dither) while the tabard's body slots 9..12 are 10-28% (smooth folds), so
    the speckle colours can be aimed at the pixels that already scatter."""
    px, W, H = rec["px"], rec["w"], rec["h"]
    tot, iso = Counter(), Counter()
    for y in range(H):
        for x in range(W):
            v = px[y][x]
            if not v:
                continue
            tot[v] += 1
            if not any(0 <= x + dx < W and 0 <= y + dy < H and px[y + dy][x + dx] == v
                       for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                iso[v] += 1
    return {k: iso[k] / n for k, n in tot.items()}


def qlum(hist, q):
    """The luminance at pixel-area quantile q of a region."""
    pts = sorted((lum(c), n) for c, n in hist.items())
    tot = sum(n for _, n in pts)
    acc = 0.0
    for l, n in pts:
        acc += n
        if q <= acc / tot:
            return l
    return pts[-1][0]


def area_match(slots, use, src, colour_at, out, lo=0.02, hi=0.995, gain=1.0):
    """Give each slot the source region's colour at its own share of the group's
    pixels, kept strictly increasing so an unused slot cannot fold the ramp.
    `colour_at(luminance, slot) -> rgb`."""
    tot = sum(use.get(i, 0) for i in slots) or 1
    acc, prev = 0.0, 0.0
    for i in slots:
        n = use.get(i, 0)
        q = (acc + n / 2.0) / tot if n else acc / tot
        acc += n
        l = qlum(src, min(hi, max(lo, q))) * gain
        if l <= prev:
            l = prev + 3.0
        prev = l
        out[i] = to_word(colour_at(l, i))


def build(mk1_rec, mk1_words, mk2_rec, rad_words, fuzz=FUZZ):
    """-> (64 palette words, the MK1 region histograms)."""
    per = mk1_regions(mk1_rec, mk1_words)
    robe, hat, black = per["ROBE"], per["HAT"], per["BLACK"]
    f_robe = chroma_curve(robe)
    f_hat = chroma_curve(hat, sigma=24.0)
    f_speck = speckle_curve(robe)
    iso = isolation(mk2_rec)

    use = Counter()
    for row in mk2_rec["px"]:
        use.update(row)
    del use[0]

    mk2L = [lum(rgb(w)) for w in rad_words]
    out = list(rad_words)
    robe_top = qlum(robe, 0.995)

    def cloth(l, slot):
        """The robe's colour at luminance l, pulled toward MK1's speckle in
        proportion to how scattered the ART uses this slot."""
        base = f_robe(l)
        spk = f_speck(l)
        a = fuzz * iso.get(slot, 0.0)
        if spk is None or a <= 0:
            return base
        a = min(1.0, a)
        return tuple(base[i] + (spk[i] - base[i]) * a for i in range(3))

    # 41..58 - ONE ramp in the art, so one ramp here.  Its own shape is kept and
    # rescaled; the bottom is pinned dark because the shadowed FACE rides on it.
    span = mk2L[CLOTH[-1]] - mk2L[CLOTH[0]]
    for k in CLOTH:
        t = (mk2L[k] - mk2L[CLOTH[0]]) / span
        out[k] = to_word(cloth(ROBE_FLOOR + (robe_top - ROBE_FLOOR) * pow(t, ROBE_GAMMA), k))

    # the tabard MK1 does not have, in MK1's own cloth
    area_match(TABARD, use, robe, cloth, out)
    # the hat, and the hands that share its ramp
    area_match(sorted(HAT_FAMILY, key=lambda i: mk2L[i]), use, hat,
               lambda l, _slot: f_hat(l), out, hi=0.98, gain=HAT_GAIN)

    out[WHITE_SLOT] = to_word(f_robe(robe_top))
    out[BLACK_SLOT] = to_word(sorted(black.items(), key=lambda t: -t[1])[0][0])

    # the emblem, folded into the sleeve it sits on
    lo, hi = mk2L[EMBLEM[0]], mk2L[EMBLEM[-1]]
    for i in EMBLEM:
        t = (mk2L[i] - lo) / (hi - lo)
        out[i] = to_word(f_robe(robe_top * (0.84 + 0.16 * t)))

    return out, per


# ---------------------------------------------------------------- reporting --
MK2_HAT = set(HAT_FAMILY)
MK2_ROBE = set(CLOTH) | {WHITE_SLOT}
MK2_TAB = set(TABARD)
MK2_FACEBOX = (24, 18, 40, 40)


def mk2_regions(rec, words):
    cols = [rgb(w) for w in words]
    per = {}
    for y, row in enumerate(rec["px"]):
        for x, v in enumerate(row):
            if not v:
                continue
            if v in MK2_HAT:
                k = "HAT" if y < 34 else "FLESH"
            elif v in MK2_TAB:
                k = "TABARD"
            elif v == BLACK_SLOT:
                k = "BLACK"
            elif v in MK2_ROBE:
                k = "BLACK" if (v in (41, 42, 43, 44) and inbox(x, y, MK2_FACEBOX)) else "ROBE"
            else:
                continue
            per.setdefault(k, Counter())[cols[v]] += 1
    return per


def mean(hist):
    tot = sum(hist.values())
    return tot, [sum(c[i] * n for c, n in hist.items()) / tot for i in range(3)]


def spread(hist):
    """The region's mean chroma - how much colour it carries off the grey axis.
    The SPECKLE lives here and not in the mean, which is why a palette can match
    the mean perfectly and still look flat."""
    tot = sum(hist.values())
    return sum(chroma(c) * n for c, n in hist.items()) / tot


def report(mk1_per, mk2_rec, words):
    got = mk2_regions(mk2_rec, words)
    print("region    MK1 mean          on MK2 sprite      err   chroma spread")
    rows = [("HAT", "HAT"), ("ROBE", "ROBE"), ("BLACK", "BLACK"),
            ("FLESH", "FLESH"), ("TABARD", "ROBE")]
    worst = 0.0
    for name, src in rows:
        if src not in mk1_per or name not in got:
            continue
        ta, ma = mean(mk1_per[src])
        tb, mb = mean(got[name])
        d = math.dist(ma, mb)
        worst = max(worst, d)
        note = "   (vs MK1's robe - MK1 has no tabard)" if name == "TABARD" else ""
        print("%-9s %3d,%3d,%3d n=%-5d %3d,%3d,%3d n=%-5d %5.1f   %4.1f vs %4.1f%s"
              % (name, ma[0], ma[1], ma[2], ta, mb[0], mb[1], mb[2], tb, d,
                 spread(got[name]), spread(mk1_per[src]), note))
    return worst


def as_asm(name, words, per_line=8):
    out = ["%s:" % name, "\t.word\t %d" % len(words)]
    for i in range(0, len(words), per_line):
        out.append("\t.word\t" + ",".join("0%XH" % w if w > 9 else "0%dH" % w
                                          for w in words[i:i + per_line]))
    return "\n".join(out)


def preview(dirpath, mk1_rec, mk1_words, mk2_rec, rad_words, new_words, others):
    from PIL import Image, ImageDraw
    d = Path(dirpath)
    d.mkdir(parents=True, exist_ok=True)

    def draw(rec, words, scale=4):
        im = Image.new("RGB", (rec["w"], rec["h"]), (255, 0, 255))
        px = im.load()
        for y in range(rec["h"]):
            for x in range(rec["w"]):
                v = rec["px"][y][x]
                if v:
                    px[x, y] = rgb(words[v])
        return im.resize((rec["w"] * scale, rec["h"] * scale), Image.NEAREST)

    panels = [("MK1 art / MK1RAID_P", mk1_rec, mk1_words),
              ("MK2 art / RADRED_P", mk2_rec, rad_words)]
    panels += [("MK2 art / " + n, mk2_rec, w) for n, w in others]
    panels += [("MK2 art / " + NEW_PAL, mk2_rec, new_words)]
    ims = [(n, draw(r, w)) for n, r, w in panels]
    W = sum(i.width for _, i in ims) + 20 * (len(ims) + 1)
    H = max(i.height for _, i in ims) + 30
    sheet = Image.new("RGB", (W, H), (25, 25, 25))
    dr = ImageDraw.Draw(sheet)
    x = 20
    for n, i in ims:
        sheet.paste(i, (x, 26))
        dr.text((x, 8), n, fill=(255, 255, 255))
        x += i.width + 20
    sheet.save(d / "mk1_raiden_compare.png")
    return d / "mk1_raiden_compare.png"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="write %s into %s" % (NEW_PAL, WORKBENCH.name))
    ap.add_argument("--check", action="store_true", help="fail if %s has drifted" % NEW_PAL)
    ap.add_argument("--asm", action="store_true", help="print the IMGPAL-style block")
    ap.add_argument("--preview", metavar="DIR", help="write comparison PNGs")
    ap.add_argument("--fuzz", type=float, default=FUZZ, metavar="K",
                    help="how much of MK1's electrical speckle to keep, 0 = none "
                         "(default %g; 0 matches the mean best, 1 matches the look)" % FUZZ)
    args = ap.parse_args()

    if not WORKBENCH.exists():
        sys.exit("%s is missing - it carries the MK1 reference pair" % WORKBENCH)
    imgs, pals = read_img(WORKBENCH)
    byname = {p["name"]: p for p in pals}
    bynum = {p["palnum"]: p for p in pals}
    recs = {r["name"]: r for r in imgs}

    if MK1_REC not in recs or MK1_PAL not in byname:
        sys.exit("%s needs both %s and %s" % (WORKBENCH.name, MK1_REC, MK1_PAL))
    mk1_rec = recs[MK1_REC]
    # THE ASSERTION THAT MATTERS - see the KATPAL trap in the docstring
    resolved = bynum.get(mk1_rec["palnum"], {}).get("name")
    if resolved != MK1_PAL:
        sys.exit("%s's palnum %d resolves to %r, not %s - its pixels are indexed "
                 "against another palette and the fit would be made on noise"
                 % (MK1_REC, mk1_rec["palnum"], resolved, MK1_PAL))
    mk1_words = byname[MK1_PAL]["words"]

    m2imgs, m2pals = read_img(MK2_SRC)
    m2by = {p["name"]: p for p in m2pals}
    m2rec = next((r for r in m2imgs if r["name"] == MK2_REC), None)
    if m2rec is None or MK2_PAL not in m2by:
        sys.exit("%s needs both %s and %s" % (MK2_SRC.name, MK2_REC, MK2_PAL))
    rad_words = m2by[MK2_PAL]["words"]

    words, mk1_per = build(mk1_rec, mk1_words, m2rec, rad_words, fuzz=args.fuzz)

    print("%s  <-  %s of %s, on %s's ramps   (fuzz %g)"
          % (NEW_PAL, MK1_PAL, WORKBENCH.name, MK2_PAL, args.fuzz))
    print("MK1 regions: " + ", ".join("%s %d" % (k, sum(v.values()))
                                      for k, v in sorted(mk1_per.items())))
    worst = report(mk1_per, m2rec, words)
    print("worst region mean error: %.1f of 255" % worst)

    if args.asm:
        print()
        print(as_asm(NEW_PAL, words))

    if args.check:
        have = byname.get(NEW_PAL)
        if have is None:
            print("%s: %s is not in the file - run --apply" % (NEW_PAL, WORKBENCH.name))
            return 1
        if have["words"] != words:
            n = sum(1 for a, b in zip(have["words"], words) if a != b)
            print("%s: DRIFTED - %d of %d entries differ from a fresh fit"
                  % (NEW_PAL, n, len(words)))
            return 1
        print("%s in %s matches a fresh fit" % (NEW_PAL, WORKBENCH.name))
        return 0

    if args.apply:
        pal = byname.get(NEW_PAL)
        if pal is None:
            pal = dict(name=NEW_PAL, palnum=NUMDEFPAL + len(pals), bpp=6,
                       raw=byname[MK1_PAL]["raw"], words=words)
            pals.append(pal)
        else:
            pal["words"] = words
        rec = recs.get(NEW_REC)
        if rec is None:
            # Template the record on one ALREADY IN THIS FILE, not on RAID1's.
            # RAID1's RNSTANCE1 carries IMGTOOL metadata the workbench's records
            # do not (flags 1, a stamp in field 8, junk after the name's NUL), and
            # copying it in leaves one record in the file shaped unlike its peers.
            rec = dict(m2rec, name=NEW_REC, raw=mk1_rec["raw"])
            imgs.append(rec)
        rec["px"] = [row[:] for row in m2rec["px"]]
        rec["w"], rec["h"] = m2rec["w"], m2rec["h"]
        rec["ax"], rec["ay"] = m2rec["ax"], m2rec["ay"]
        rec["palnum"] = pal["palnum"]
        n = write_img(WORKBENCH, imgs, pals)
        # read it straight back - a library this tool rebuilt is worth proving
        ri, rp = read_img(WORKBENCH)
        rb = {p["name"]: p for p in rp}
        rr = {r["name"]: r for r in ri}
        assert rb[NEW_PAL]["words"] == words, "palette did not survive the write"
        assert rr[NEW_REC]["px"] == m2rec["px"], "pixels did not survive the write"
        assert rb[MK1_PAL]["words"] == mk1_words, "%s was disturbed" % MK1_PAL
        assert rr[MK1_REC]["px"] == mk1_rec["px"], "%s was disturbed" % MK1_REC
        print("wrote %s (%d bytes): palette %s (palnum %d), record %s on it"
              % (WORKBENCH, n, NEW_PAL, pal["palnum"], NEW_REC))
        print("kept: " + ", ".join(p["name"] for p in pals if p["name"] != NEW_PAL))

    if args.preview:
        others = [(p["name"], p["words"]) for p in pals
                  if p["name"] not in (MK1_PAL, NEW_PAL) and len(p["words"]) == 64]
        out = preview(args.preview, mk1_rec, mk1_words, m2rec, rad_words, words, others)
        print("preview -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
