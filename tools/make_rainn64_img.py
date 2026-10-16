#!/usr/bin/env python3
r"""Build data/RAINN64.IMG - every piece of RAIN's own art in MK Trilogy (N64).

The Trilogy ninja body is SHARED art (Scorpion/Reptile/Sub-Zero frames drawn
in Rain's palette), so what is Rain's alone in SEG/CHARDATA/MNINJA is:

  RAPROFORM1-7, RAPROLOOP1-5   his storm-cloud projectile (a_rain_cloud parts
                               1 and 3), palette RNCLOUD_PAL
  RNZAP11-16                   the cloud hitting (a_rain_cloud part 4); these
                               frames carry no palette of their own - the
                               object is still on RNCLOUD_PAL
  RNDROP01-13                  rain drops, palette NEWdrop_p
  RAINLT1-6 (3A/3B, 4A/4B)     his lightning bolt (a_rain_bolt), RAINLT_PAL

Every frame is decoded from the text listings (MKNJ.ATD headers, MKNJ.ATT
pixels, MKNJ.DCT dictionary) with the decompressors transcribed from
SEG/GAMECODE/U64MAIN.C (uncompress_image):

  type 0x0F  uncompress_8               8-colour RLE
  type 0x10  uncompress_16              16-colour RLE
  type 0x16/0x17/0x18  dict_uncompress_32_final   32-colour dictionary RLE

Each frame must unpack to exactly its header's byte count, and that must be
H * (W rounded up to 4) - rows are stored padded to 4 pixels; the pad is
cropped off.  Anipoints are Trilogy's own, unchanged (data/RAINBOLT.IMG is
the bolt RE-ANCHORED for the game; this file is the untouched source art).

The IMG also carries Rain's body palettes (rain, alt, cut, ghost, rip, baby,
brutality, ...) as extra palette records that no image here references, for
use on the shared ninja frames.

    python tools/make_rainn64_img.py            # write data/RAINN64.IMG
    python tools/make_rainn64_img.py --png      # + PNG previews to tmp/rainn64/
    python tools/make_rainn64_img.py --check    # fail if the file has drifted
"""
import argparse
import os
import re
import struct
import sys
from pathlib import Path

TRIL = Path(r"C:\Users\you\Workplace\MKTRILOGY_source_N64\MKTRIL~1\SEG")
NJ = TRIL / "CHARDATA" / "MNINJA"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "RAINN64.IMG"
PNG = ROOT / "tmp" / "rainn64"

# Same layouts as make_ermfire_img.py (the proven writer).
LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

# frame name prefix -> the palette it draws in (N64 label, IMG name)
FRAMES = [
    (r"RAPROFORM\d+|RAPROLOOP\d+|RNZAP\d+", "RNCLOUD_PAL"),
    (r"RNDROP\w+", "NEWdrop_p"),
    (r"RAINLT\w+", "RAINLT_PAL"),
]
# where each frame palette lives, and its IMG record name (<= 9 chars)
FRAME_PALS = {
    "RNCLOUD_PAL": (TRIL / "GAMECODE" / "IMGPAL.S", "RNCLOUD_P"),
    "NEWdrop_p": (NJ / "NINJAPRO.RGB", "RNDROP_P"),
    "RAINLT_PAL": (NJ / "NEWPAL" / "RAINLGT.RGB", "RAINLT_P"),
}
# Rain's body palettes (unreferenced here; for the shared ninja art)
BODY_PALS = [
    ("RAIN.RGB", "rain_PAL", "RAIN_P"),
    ("RAINALT.RGB", "rainalt_PAL", "RAINALT_P"),
    ("RAINCUT.RGB", "raincut_PAL", "RAINCUT_P"),
    ("RAINALTC.RGB", "rainaltcut_PAL", "RAINALTC"),
    ("RAINGHOS.RGB", "rainghost_PAL", "RAINGHO_P"),
    ("RAINRIP.RGB", "rainrip_PAL", "RAINRIP_P"),
    ("RAINPRO.RGB", "RAINPRO_PAL", "RAINPRO_P"),
    ("RAINLT.RGB", "CLOUD9_PAL", "CLOUD9_P"),
    ("BABYRAIN.RGB", "BABYrain_PAL", "BABYRAINP"),
    ("BHRAIN.RGB", "BHRAIN_PAL", "BHRAIN_P"),
]


def read(p):
    return Path(p).read_text(encoding="latin-1")


def n64_pal(path, label):
    m = re.search(r"^" + re.escape(label) + r":\s*\n\s*\.word\s+(\d+)\s*\n((?:\s*\.half[^\n]*\n?)+)",
                  read(path), re.M)
    if not m:
        sys.exit("palette %s not found in %s" % (label, path))
    vals = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{4})", m.group(2))]
    n = int(m.group(1))
    if len(vals) < n:
        sys.exit("palette %s: %d entries, header says %d" % (label, len(vals), n))
    return vals[:n]


def mk2_colour(v):                # N64 RRRRRGGGGGBBBBBA -> MK2 0RRRRRGGGGGBBBBB
    return (v >> 1) & 0x7FFF


def rgb(v):
    return tuple(((v >> s) & 31) * 255 // 31 for s in (11, 6, 1))


# ---- decompressors, transcribed from U64MAIN.C -----------------------------

def uncompress_8(src, size):
    out, i = bytearray(), 4
    while len(out) < size:
        ch = src[i]; i += 1
        if ch & 0x80:
            out += bytes((ch & 0x7F) + 1)
        elif ch & 0x40:
            out.append((ch >> 3) & 7)
            if len(out) < size:
                out.append(ch & 7)
        else:
            pix = ch & 7
            if pix == 0:
                out += bytes([(ch >> 3) & 7]) * src[i]; i += 1
            else:
                out += bytes([pix]) * (((ch >> 3) & 7) + 3)
    return out


def uncompress_16(src, size):
    out, i = bytearray(), 4
    while len(out) < size:
        ch = src[i]; i += 1
        if ch & 0x80:
            out += bytes((ch & 0x7F) + 7)
            continue
        sw, c = ch >> 4, ch & 0xF
        if sw == 0:
            out += bytes([c]) * src[i]; i += 1
        elif sw == 7:
            n = c + 3
            while n > 0:
                v = src[i]; i += 1
                out.append(v >> 4); n -= 1
                if n:
                    out.append(v & 0xF); n -= 1
        else:
            out += bytes([c]) * sw
    return out


def dict_uncompress_32_final(src, size, dct):
    typ = src[0]
    top4, mini = None, 0
    if typ == 24:
        top4, fd = src[4:8], 8
    elif typ == 23:
        mini, fd = src[4], 5
    else:
        fd = 4
    flen = src[fd]; fd += 1
    if flen & 0x80:
        flen = ((flen & 0x7F) << 8) | src[fd]; fd += 1
    i = fd + flen
    bits, flip = 8, src[fd]; fd += 1
    out = bytearray()
    while len(out) < size:
        ch = src[i]; i += 1
        if ch & 0x80:
            k = (ch & 0x7F) << 1
            pair = (dct[k + 1], dct[k]) if flip & 0x80 else (dct[k], dct[k + 1])
            out += bytes(pair)
            bits -= 1
            if bits == 0:
                flip, bits = src[fd], 8; fd += 1
            else:
                flip = (flip << 1) & 0xFF
            continue
        sw, c = ch >> 5, ch & 0x1F
        if sw == 3:
            out += bytes([c]) * src[i]; i += 1
        elif sw == 2:
            if top4 is None:
                out += bytes([mini]) * (c + 3)
            else:
                out += bytes([top4[(c >> 3) & 3]]) * ((c & 7) + 3)
        elif sw == 1:
            out += bytes([c, c])
        else:
            out.append(c)
    return out


def uncompress(src, dct):
    hdr = int.from_bytes(src[:4], "big")
    typ, size = (hdr >> 24) & 0x3F, hdr & 0xFFFFFF
    if typ == 15:
        out = uncompress_8(src, size)
    elif typ == 16:
        out = uncompress_16(src, size)
    elif typ in (22, 23, 24):
        out = dict_uncompress_32_final(src, size, dct)
    else:
        raise ValueError("compression type %d not handled" % typ)
    return bytes(out), len(out), size, typ


# ---- source parsing --------------------------------------------------------

def headers(atd):
    """name -> (img_label, h, w, anix, aniy) for every frame record, both the
    NAME: .word NAME_SUB,0 / NAME_SUB: form and the plain NAME: form."""
    out = {}
    pat = (r"^(\w+?)(?:_SUB)?:\s*\n\s*\.word\s+(\w+_IMG)\s*\n\s*"
           r"\.half\s+([-\d]+),\s*([-\d]+),\s*([-\d]+),\s*([-\d]+)")
    for m in re.finditer(pat, atd, re.M):
        out[m.group(1)] = (m.group(2),) + tuple(int(m.group(k)) for k in range(3, 7))
    return out


def img_bytes(att, label):
    m = re.search(r"^" + re.escape(label) + r":\s*\n((?:\s*\.byte[^\n]*\n)+)", att, re.M)
    if not m:
        sys.exit("no pixel data for " + label)
    return bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", m.group(1)))


def frames():
    atd, att = read(NJ / "MKNJ.ATD"), read(NJ / "MKNJ.ATT")
    dct = bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", read(NJ / "MKNJ.DCT")))
    if len(dct) != 256:
        sys.exit("MKNJ.DCT: %d bytes, expected 256" % len(dct))
    hd = headers(atd)
    order = [ln.split(":")[0] for ln in atd.splitlines() if re.match(r"^\w+:\s*$", ln)]
    out = []
    for pat, pal in FRAMES:
        for name in order:
            if not re.fullmatch(pat, name) or name not in hd:
                continue
            label, h, w, ax, ay = hd[name]
            px, got, size, typ = uncompress(img_bytes(att, label), dct)
            stride = (w + 3) & ~3
            if got != size or size != stride * h:
                sys.exit("%s: type %d unpacked %d, header says %d, stride*H is %d"
                         % (name, typ, got, size, stride * h))
            px = b"".join(px[r * stride:r * stride + w] for r in range(h))
            out.append(dict(name=name, w=w, h=h, anix=ax, aniy=ay, px=px, pal=pal, typ=typ))
    return out


def bpp_for(n):
    b = 1
    while (1 << b) < n:
        b += 1
    return b


def palettes():
    """[(img_name, mk2 colours, bpp, n64 label)] - frame palettes first"""
    out = []
    for label, (path, name) in FRAME_PALS.items():
        out.append((name, [mk2_colour(v) for v in n64_pal(path, label)], label))
    for fn, label, name in BODY_PALS:
        out.append((name, [mk2_colour(v) for v in n64_pal(NJ / fn, label)], label))
    res = []
    for name, cols, label in out:
        b = bpp_for(len(cols))
        cols = cols + [0] * ((1 << b) - len(cols))     # pad to a clean ramp
        res.append((name, cols, b, label))
    return res


# ---- IMG writer ------------------------------------------------------------

def build(fr, pals):
    palno = {label: i for i, (_n, _c, _b, label) in enumerate(pals)}
    blob = bytearray()
    pal_offs = []
    for _n, cols, _b, _l in pals:
        pal_offs.append(LIB.size + len(blob))
        blob += struct.pack("<%dH" % len(cols), *cols)
    offs = []
    for f in fr:
        offs.append(LIB.size + len(blob))
        w, stride = f["w"], (f["w"] + 3) & ~3
        for y in range(f["h"]):
            blob += f["px"][y * w:(y + 1) * w] + b"\0" * (stride - w)
    oset = LIB.size + len(blob)
    hdr = LIB.pack(len(fr), len(pals) + 3, oset, 0x0634, 0, 0, 0,
                   0xABCD, b"\xff\xff\xff\xff", 0, 0, 0)
    imgs = bytearray()
    for f, off in zip(fr, offs):
        imgs += IMAGE.pack(f["name"].encode().ljust(16, b"\0"), 0,
                           f["anix"] & 0xFFFF, f["aniy"] & 0xFFFF, f["w"], f["h"],
                           palno[f["pal"]] + 3,        # 3-based
                           off, 0, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF)
    precs = bytearray()
    for (name, cols, b, _l), off in zip(pals, pal_offs):
        precs += PALETTE.pack(name.encode().ljust(10, b"\0"), 0, b, len(cols), off, 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(blob) + bytes(imgs) + bytes(precs)


def read_back(data):
    imgcnt, _pc, oset = LIB.unpack_from(data, 0)[:3]
    out = []
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        w, h, off = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        px = b"".join(data[off + y * stride: off + y * stride + w] for y in range(h))
        sx = lambda v: v - 0x10000 if v & 0x8000 else v
        out.append((r[0].split(b"\0")[0].decode(), w, h, sx(r[2]), sx(r[3]), px))
    return out


def write_pngs(fr, pals):
    from PIL import Image
    PNG.mkdir(parents=True, exist_ok=True)
    bylabel = {label: cols for _n, cols, _b, label in pals}
    for f in fr:
        cols = bylabel[f["pal"]]
        im = Image.new("RGBA", (f["w"], f["h"]))
        im.putdata([(0, 0, 0, 0) if i == 0 else rgb(cols[i] << 1) + (255,) for i in f["px"]])
        bg = Image.new("RGBA", im.size, (40, 40, 60, 255))
        bg.alpha_composite(im)
        bg.resize((f["w"] * 3, f["h"] * 3), Image.NEAREST).save(PNG / (f["name"] + ".png"))
    print("previews in", PNG)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--png", action="store_true")
    a = ap.parse_args()
    if not NJ.exists():
        if a.check:
            print("RAINN64: Trilogy source not present - skipping check")
            return 0
        sys.exit("Trilogy source not found: %s" % NJ)
    fr, pals = frames(), palettes()
    palsize = {label: len(cols) for _n, cols, _b, label in pals}
    for f in fr:
        hi = max(f["px"])
        if hi >= palsize[f["pal"]]:
            sys.exit("%s uses index %d, past %s's %d entries" % (f["name"], hi, f["pal"], palsize[f["pal"]]))
    data = build(fr, pals)
    if a.check:
        if not OUT.exists() or OUT.read_bytes() != data:
            print("RAINN64: %s missing or differs from a fresh build - regenerate it" % OUT)
            return 1
        print("RAINN64.IMG OK (%d frames, %d palettes)" % (len(fr), len(pals)))
        return 0
    for f, b in zip(fr, read_back(data)):
        if (f["name"], f["w"], f["h"], f["anix"], f["aniy"], f["px"]) != b:
            sys.exit("round trip failed on " + f["name"])
    OUT.write_bytes(data)
    print("wrote %s  (%d frames, %d palettes, %d bytes)" % (OUT, len(fr), len(pals), len(data)))
    for f in fr:
        print("   %-11s %3dx%-3d ani(%4d,%4d)  type %2d  max idx %2d  %s"
              % (f["name"], f["w"], f["h"], f["anix"], f["aniy"], f["typ"], max(f["px"]), f["pal"]))
    for name, cols, b, label in pals:
        print("   pal %-9s %2d colours %dbpp  (%s)" % (name, len(cols), b, label))
    if a.png:
        write_pngs(fr, pals)
    return 0


if __name__ == "__main__":
    sys.exit(main())
