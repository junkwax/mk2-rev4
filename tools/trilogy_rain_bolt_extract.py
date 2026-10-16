#!/usr/bin/env python3
"""trilogy_rain_bolt_extract.py - Rain's LIGHTNING BOLT art out of MK Trilogy (N64).

The art is not in any arcade ROM - Rain's bolt only ever shipped on the home
Trilogy.  The N64 source tree carries it as text:

  SEG/CHARDATA/MNINJA/MKNJ.ATD   frame headers  RAINLTn: .word RAINLTn_SUB,0
                                  RAINLTn_SUB: .word RAINLTn_IMG
                                               .half H, W, anix, aniy
                                  and the lane a_rain_bolt
  SEG/CHARDATA/MNINJA/MKNJ.ATT   pixels         RAINLTn_IMG: .byte ...
  SEG/CHARDATA/MNINJA/NEWPAL/RAINLGT.RGB   RAINLT_PAL (16 x RGBA5551)

Every RAINLT image carries header type 0x10, which uncompress_image
(U64MAIN.O, jump table in .rodata+0x18) sends to uncompress_16.  Its source
is not in the tree; the decoder below is transcribed from the MIPS object
(uncompress_16, 360 bytes, mode table at .rodata+0x80):

  header  .long  (type << 24) | unpacked byte count      big endian
  0x80|n            n+7 transparent (index 0) pixels
  0x00|c, count     colour c, `count` times (next byte)
  0x10..0x60 | c    colour c, 1..6 times (the high nibble)
  0x70|n            n+3 literal 4-bit pixels, two per byte, high nibble first

The decoder is proved by construction: every frame must unpack to exactly
the header's byte count, which must equal H * W-rounded-up-to-4 from
MKNJ.ATD (rows are stored padded to a multiple of 4 pixels; the pad is
cropped off).

  python tools/trilogy_rain_bolt_extract.py            # PNGs to tmp/rain_bolt/
  python tools/trilogy_rain_bolt_extract.py --list
"""
import argparse
import os
import re
import sys

TRIL = r"C:\Users\you\Workplace\MKTRILOGY_source_N64\MKTRIL~1\SEG\CHARDATA\MNINJA"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tmp", "rain_bolt")


def read(path):
    with open(path, encoding="latin-1") as f:
        return f.read()


def headers(atd):
    """name -> (img_label, h, w, anix, aniy, has_pal) for every RAINLT frame."""
    out = {}
    for m in re.finditer(r"^(RAINLT\w+)_SUB:\s*\n\s*\.word\s+(\w+)\s*\n\s*\.half\s+([-\d]+),\s*([-\d]+),\s*([-\d]+),\s*([-\d]+)"
                         r"(\s*\n\s*\.word\s+RAINLT_PAL)?", atd, re.M):
        out[m.group(1)] = (m.group(2), int(m.group(3)), int(m.group(4)),
                           int(m.group(5)), int(m.group(6)), bool(m.group(7)))
    return out


def lane(atd):
    m = re.search(r"^a_rain_bolt:\s*\n(.*?)^a_\w+:", atd, re.M | re.S)
    return [ln.split()[1] for ln in m.group(1).splitlines() if ln.strip().startswith(".word")]


def img_bytes(att, label):
    m = re.search(r"^" + re.escape(label) + r":\s*\n((?:\s*\.byte[^\n]*\n)+)", att, re.M)
    if not m:
        raise SystemExit("no pixel data for " + label)
    return bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", m.group(1)))


def uncompress_16(src):
    hdr = int.from_bytes(src[:4], "big")
    typ, size = hdr >> 24, hdr & 0xFFFFFF
    if typ & 0x3F != 0x10:
        raise ValueError("type %#x is not uncompress_16" % typ)
    out = bytearray()
    i = 4
    while len(out) < size:
        b = src[i]; i += 1
        if b & 0x80:
            out += bytes((b & 0x7F) + 7)
            continue
        mode, c = b >> 4, b & 0xF
        if mode == 0:
            out += bytes([c]) * src[i]; i += 1
        elif mode <= 6:
            out += bytes([c]) * mode
        else:
            n = c + 3
            while n > 0:
                v = src[i]; i += 1
                out.append(v >> 4); n -= 1
                if n:
                    out.append(v & 0xF); n -= 1
    return bytes(out[:size]), len(out), size


def palette():
    txt = read(os.path.join(TRIL, "NEWPAL", "RAINLGT.RGB"))
    m = re.search(r"^RAINLT_PAL:\s*\n\s*\.word\s+(\d+)\s*\n((?:\s*\.half[^\n]*\n)+)", txt, re.M)
    vals = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{4})", m.group(2))]
    assert len(vals) == int(m.group(1)), "palette count"
    return vals


def rgb(v):                       # N64 RGBA5551
    return tuple(((v >> s) & 31) * 255 // 31 for s in (11, 6, 1))


def mk2_colour(v):                # MK2: 0RRRRRGGGGGBBBBB
    return (v >> 1) & 0x7FFF


def frames():
    atd = read(os.path.join(TRIL, "MKNJ.ATD"))
    att = read(os.path.join(TRIL, "MKNJ.ATT"))
    out = {}
    for name, (label, h, w, ax, ay, pal) in sorted(headers(atd).items()):
        px, got, size = uncompress_16(img_bytes(att, label))
        stride = (w + 3) & ~3             # rows are stored padded to 4 pixels
        if got != size or size != stride * h:
            raise SystemExit("%s: unpacked %d, header says %d, stride*H is %d" % (name, got, size, stride * h))
        px = b"".join(px[r * stride:r * stride + w] for r in range(h))
        out[name] = dict(w=w, h=h, anix=ax, aniy=ay, pal=pal, px=px)
    return out, lane(atd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    fr, ln = frames()
    pal = palette()
    for n, f in fr.items():
        used = sorted(set(f["px"]))
        print("%-9s %3dx%-3d ani %4d,%4d  colours %s%s" % (n, f["w"], f["h"], f["anix"], f["aniy"],
              used, "  (+RAINLT_PAL)" if f["pal"] else ""))
    print("a_rain_bolt:", " ".join(ln))
    print("RAINLT_PAL (MK2):", " ".join("%04x" % mk2_colour(v) for v in pal))
    if a.list:
        return 0
    from PIL import Image
    os.makedirs(OUT, exist_ok=True)
    for n, f in fr.items():
        im = Image.new("RGBA", (f["w"], f["h"]))
        im.putdata([(0, 0, 0, 0) if i == 0 else rgb(pal[i]) + (255,) for i in f["px"]])
        bg = Image.new("RGBA", im.size, (40, 40, 60, 255))
        bg.alpha_composite(im)
        bg.resize((f["w"] * 3, f["h"] * 3), Image.NEAREST).save(os.path.join(OUT, n + ".png"))
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
