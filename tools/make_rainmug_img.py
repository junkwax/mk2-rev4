#!/usr/bin/env python3
r"""Build data/RAINMUG.IMG - RAIN's character-select portrait, 1:1 from MK
Trilogy (N64).

The select screen's head mugs live in SEG/COMMON/MUGS: MUGS.ATT carries the
pixels as text, ARTMUGS.S the record (`HDRAIN: .word HDRAIN_IMG / .half 45,
34, 0, 0 / .word HDRAIN_P` - 45 high, 34 wide; MUGS.ATD's `50, 38` is a
stale copy and does not match the data).  HDRAIN_IMG is compression type 0x14,
NHunsimpleRLE (SEG/GAMECODE/U64MAIN.C):

  signed byte n < 0   the next byte, 1-n times
  signed byte n >= 0  the next n+1 bytes, literally

It must unpack to exactly the header's 1620 bytes = 45 rows of 36 (34 padded
to 4); the two pad columns are index 0 and are cropped off.  No other pixel
is index 0, so the portrait is opaque.

Palette: HDRAIN_P, COMMON/MUGS/HDRAIN.RGB HDRAIN_PAL, 128 entries (7bpp) -
the one ARTMUGS.S's record names.  The tree also carries a raindim_PAL (in
COMMON/MUGS and, different again, ATTRACT/SELECT) that nothing in the game
code references and that does not match these indices - drawn with it the
portrait comes out as noise - so it is left out.

    python tools/make_rainmug_img.py            # write data/RAINMUG.IMG
    python tools/make_rainmug_img.py --png      # + tmp/rainmug/*.png previews
    python tools/make_rainmug_img.py --check    # fail if the file has drifted
"""
import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "RAINMUG.IMG"
PNG = ROOT / "tmp" / "rainmug"

W, H = 34, 45               # ARTMUGS.S
PALS = [("HDRAIN_P", "HDRAIN.RGB", "HDRAIN_PAL")]


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def unsimple_rle(src):
    """NHunsimpleRLE (type 20)."""
    hdr = int.from_bytes(src[:4], "big")
    typ, size = (hdr >> 24) & 0x3F, hdr & 0xFFFFFF
    if typ != 20:
        raise ValueError("type %d is not NHunsimpleRLE" % typ)
    out, i = bytearray(), 4
    while len(out) < size:
        n = src[i]; i += 1
        if n >= 0x80:
            out += bytes([src[i]]) * (1 - (n - 0x100)); i += 1
        else:
            out += src[i:i + n + 1]; i += n + 1
    if len(out) != size or i != len(src):
        raise SystemExit("HDRAIN_IMG: unpacked %d of %d, read %d of %d bytes"
                         % (len(out), size, i, len(src)))
    return bytes(out)


def build():
    n64 = load("make_rainn64_img")
    mugs = n64.TRIL / "COMMON" / "MUGS"
    raw = unsimple_rle(n64.img_bytes(n64.read(mugs / "MUGS.ATT"), "HDRAIN_IMG"))
    stride = (W + 3) & ~3
    if len(raw) != stride * H:
        raise SystemExit("HDRAIN_IMG: %d bytes, %dx%d padded is %d" % (len(raw), W, H, stride * H))
    pad = {raw[r * stride + c] for r in range(H) for c in range(W, stride)}
    if pad != {0}:
        raise SystemExit("HDRAIN_IMG: pad columns are not all index 0: %s" % sorted(pad))
    px = b"".join(raw[r * stride:r * stride + W] for r in range(H))
    pals = []
    for name, fn, label in PALS:
        cols = [n64.mk2_colour(v) for v in n64.n64_pal(mugs / fn, label)]
        if len(cols) != 128:
            raise SystemExit("%s: %d entries, expected 128" % (label, len(cols)))
        pals.append((name, cols, 7, label))
    if max(px) >= 128:
        raise SystemExit("HDRAIN uses index %d, past 127" % max(px))
    fr = [dict(name="HDRAIN", w=W, h=H, anix=0, aniy=0, px=px, pal="HDRAIN_PAL")]
    return n64, fr, pals


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--png", action="store_true")
    a = ap.parse_args()
    n64 = load("make_rainn64_img")
    if not n64.NJ.exists():
        print("RAINMUG: Trilogy source not present - skipping")
        return 0
    n64, fr, pals = build()
    data = n64.build(fr, pals)
    if a.check:
        if not OUT.exists() or OUT.read_bytes() != data:
            print("RAINMUG: %s missing or differs from a fresh build - regenerate it" % OUT)
            return 1
        print("RAINMUG.IMG OK")
        return 0
    back = n64.read_back(data)[0]
    f = fr[0]
    if (f["name"], f["w"], f["h"], f["anix"], f["aniy"], f["px"]) != back:
        sys.exit("round trip failed")
    OUT.write_bytes(data)
    print("wrote %s  (HDRAIN %dx%d, %d bytes; palettes %s)"
          % (OUT, W, H, len(data), ", ".join(p[0] for p in pals)))
    if a.png:
        from PIL import Image
        PNG.mkdir(parents=True, exist_ok=True)
        for name, cols, _b, _l in pals:
            im = Image.new("RGB", (W, H))
            im.putdata([n64.rgb(cols[p] << 1) for p in f["px"]])
            im.resize((W * 6, H * 6), Image.NEAREST).save(PNG / ("HDRAIN_" + name + ".png"))
        print("previews in", PNG)
    return 0


if __name__ == "__main__":
    sys.exit(main())
