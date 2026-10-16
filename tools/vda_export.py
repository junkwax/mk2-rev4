#!/usr/bin/env python3
"""Export a movie frame from an IMG library into .FRM + .HDR for implode.py.

The authoring loop is: edit the frame in imgtool, then

    python tools/vda_export.py TMPLOAD.IMG END_MLH1_vda END_MLH
    python tools/implode.py pack END_MLH
    python build.py && python makerom.py && python makevrom.py && python mamerom.py --source-video

This encodes the IMG quirks that are easy to get wrong (see
doc/MOVIE_BIN_FORMAT.md and the IMG notes there):

  * `palnum` on an image record is 3-BASED - subtract 3 to index the palette
    table.  Getting this wrong silently picks a neighbouring palette.
  * The palette record's `size` field is written as 0; the real length is
    ncol * 2 bytes at the given offset.
  * Pixel rows are stored top-down at a 4-byte-aligned stride (138 -> 140,
    280 -> 280).  A `.FRM` wants them UNPADDED and BOTTOM-UP, because
    movie_run starts at the bottom-left of the frame and blits upward.
  * `.HDR` is w, h, 1, ncol, 0 then ncol-1 palette words, starting at
    palette index 1 (index 0 is skipped).

Pass --png to also write a preview rendered the way the game will show it.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from imgdump import LIB_HDR, IMAGE, PALETTE, detect_record_layout, cstr

PALNUM_BASE = 3          # image records count 3 phantom leading palettes


def export(img_path, record, stem, want_png=False, data_dir=None):
    data = open(img_path, 'rb').read()
    imgcnt, palcnt, oset = struct.unpack_from('<HHI', data, 0)[:3]
    _, img_start, pal_start = detect_record_layout(data, oset, imgcnt, palcnt)

    rec = None
    for i in range(imgcnt):
        off = img_start + i * IMAGE.size
        if off + IMAGE.size > len(data):
            break
        f = IMAGE.unpack_from(data, off)
        if cstr(f[0]) == record:
            rec = f
            break
    if rec is None:
        raise SystemExit(f"record {record!r} not found in {img_path}")

    w, h, palnum, o = rec[4], rec[5], rec[6], rec[7]
    p = PALETTE.unpack_from(data, pal_start + (palnum - PALNUM_BASE) * PALETTE.size)
    pname, ncol, poff, psize = cstr(p[0]), p[3], p[4], p[5]
    psize = psize or ncol * 2            # the size field is written as 0

    stride = (w + 3) & ~3                # 4-byte row alignment
    span = h * stride
    if o + span > len(data):
        raise SystemExit(f"pixel data runs past EOF (need {span} bytes at {o:#x})")

    rows = [data[o + y * stride: o + y * stride + w] for y in range(h)]
    frm = b''.join(rows[::-1])           # .FRM is bottom-up
    hdr = bytearray(struct.pack('<5H', w, h, 1, ncol, 0))
    for i in range(1, ncol):             # palette entries start at index 1
        hdr += data[poff + i * 2: poff + i * 2 + 2]

    ddir = data_dir or os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), 'data')
    fp = os.path.join(ddir, stem + '.FRM')
    hp = os.path.join(ddir, stem + '.HDR')
    old = open(fp, 'rb').read() if os.path.exists(fp) else None
    oldh = open(hp, 'rb').read() if os.path.exists(hp) else None
    open(fp, 'wb').write(frm)
    open(hp, 'wb').write(bytes(hdr))

    print(f"{record} -> {stem}")
    print(f"  {w}x{h} stride={stride} palette={pname!r} ncol={ncol}")
    print(f"  {stem}.FRM {len(frm)} bytes"
          f"{'' if old is None else ('  (changed)' if frm != old else '  (identical)')}")
    print(f"  {stem}.HDR {len(hdr)} bytes"
          f"{'' if oldh is None else ('  (changed)' if bytes(hdr) != oldh else '  (identical)')}")
    if old is not None and len(old) != len(frm):
        print(f"  !! previous .FRM was {len(old)} bytes - dimensions changed")

    if want_png:
        try:
            from PIL import Image
        except ImportError:
            print("  (PIL not available, skipping preview)")
            return
        lut = [(0, 0, 0)] * 256
        for i in range(1, ncol):
            v = struct.unpack_from('<H', data, poff + i * 2)[0]
            lut[i] = (((v >> 10) & 31) * 255 // 31,
                      ((v >> 5) & 31) * 255 // 31, (v & 31) * 255 // 31)
        im = Image.new('RGB', (w, h))
        im.putdata([lut[b] for r in rows for b in r])   # top-down = as the game shows it
        png = os.path.join(ddir, stem + '_preview.png')
        im.save(png)
        print(f"  preview -> {png}")


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        print("usage: vda_export.py <IMG> <RECORD> <STEM> [--png]")
        return 1
    img = argv[1]
    if not os.path.isabs(img) and not os.path.exists(img):
        img = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), 'data', img)
    export(img, argv[2], argv[3], '--png' in argv)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
