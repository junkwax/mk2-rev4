"""Decode the Baraka World View lane's frames straight out of the built
sidecar IRWs and answer two questions without the emulator:

  1. Do the *FLIP records actually hold MIRRORED pixels?  SPIN2FLIP is
     supposed to be SPIN2 reversed.  If LOAD2's duplicate-image test
     collapsed them (getcksum cannot tell a row from its reverse) they would
     hold identical pixels, and the "flip" would visibly not happen in game
     no matter what the animation script says.
  2. What does each pose actually look like, un-flipped, as authored?

Decoder is the one from tools/verify_img_import.py (ctrl bits 12-14 = bpp,
bit 7 = zero-compressed, bits 8-9 / 10-11 = lead/trail nibble shifts).
"""
import os, re, struct, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IRW_HEADER_SIZE, IRW_BASE_OFF, IRW_SIZE_OFF = 68, 44, 48

SETS = [
    ("SAHELI.IRW",  "SAHELI.TBL",
     ["UGSPINDOWN1","SPIN2","SPIN3","SPIN4","SPIN5","SPIN4FLIP","SPIN3FLIP","SPIN2FLIP"]),
    # SAHELI2 retired 2026-09-19 (its slot is MK1ST1, old-man Shang).
]

class Bits:
    def __init__(self, buf, bitpos): self.b, self.p = buf, bitpos
    def read(self, n):
        v = 0
        for i in range(n):
            p = self.p + i
            if (p >> 3) >= len(self.b): raise EOFError
            v |= ((self.b[p >> 3] >> (p & 7)) & 1) << i
        self.p += n
        return v

def load_tbl(name):
    txt = open(os.path.join(ROOT, "src", name), "r", errors="replace").read()
    out = {}
    for m in re.finditer(r"^(\w+):\s*\n\s*\.word\s+([-\d]+),([-\d]+),([-\d]+),([-\d]+)\s*\n"
                         r"\s*\.long\s+0?([0-9A-Fa-f]+)H\s*\n\s*\.word\s+0?([0-9A-Fa-f]+)H",
                         txt, re.M):
        out[m.group(1)] = dict(w=int(m.group(2)), h=int(m.group(3)),
                               anix=int(m.group(4)), aniy=int(m.group(5)),
                               sag=int(m.group(6), 16), ctrl=int(m.group(7), 16))
    return out

def decode(payload, base, e):
    bpp = (e["ctrl"] >> 12) & 7 or 8
    cmpd = bool(e["ctrl"] & 0x80)
    ldx, trx = (e["ctrl"] >> 8) & 3, (e["ctrl"] >> 10) & 3
    # The SAG and the IRW base can disagree by exactly one bank bit in either
    # direction (SAHELI: LOD 5C50000 vs SAG 03C50000; SAHELI2: LOD 3F90000,1
    # vs SAG 05F90000).  Payloads are ~200Kbit, so normalising modulo the bank
    # bit is unambiguous.
    delta = (e["sag"] - base) % 0x2000000
    br = Bits(payload, delta)
    w, h = e["w"], e["h"]
    rows = []
    for _ in range(h):
        if cmpd:
            hdr = br.read(8)
            lead, trail = (hdr & 0xF) << ldx, (hdr >> 4) << trx
            npix = w - lead - trail
            rows.append([0]*lead + [br.read(bpp) for _ in range(max(npix, 0))] + [0]*trail)
        else:
            rows.append([br.read(bpp) for _ in range(w)])
    return rows, bpp, cmpd

def main():
    tiles = []
    for irw_name, tbl_name, frames in SETS:
        irw = open(os.path.join(ROOT, "data", irw_name), "rb").read()
        base = struct.unpack_from("<I", irw, IRW_BASE_OFF)[0]
        size = struct.unpack_from("<I", irw, IRW_SIZE_OFF)[0]
        payload = irw[IRW_HEADER_SIZE:IRW_HEADER_SIZE + size]
        tbl = load_tbl(tbl_name)
        print(f"\n=== {irw_name} base={base:#x} size={size} ===")
        pix = {}
        for n in frames:
            e = tbl[n]
            rows, bpp, cmpd = decode(payload, base, e)
            pix[n] = rows
            print(f"  {n:<12} {e['w']:>3}x{e['h']:<3} ani=({e['anix']:>4},{e['aniy']:>4}) "
                  f"ctrl={e['ctrl']:#06x} bpp={bpp} cmp={'Y' if cmpd else 'N'} "
                  f"sag={e['sag']:#x}")
            tiles.append((n, rows, e))
        # mirror check
        for a, b in [("SPIN2","SPIN2FLIP"), ("SPIN3","SPIN3FLIP"), ("SPIN4","SPIN4FLIP")]:
            if a in pix and b in pix:
                ra, rb = pix[a], pix[b]
                same = ra == rb
                mirror = all(list(reversed(x)) == y for x, y in zip(ra, rb)) if len(ra)==len(rb) else False
                verdict = ("IDENTICAL - the flip art is NOT mirrored" if same
                           else "true horizontal mirror" if mirror
                           else "different pixels, but NOT an exact mirror")
                print(f"  [check] {a} vs {b}: {verdict}")

    # contact sheet of the raw art, as authored (no engine flips applied)
    PAD, SC = 6, 1
    maxh = max(len(r) for _, r, _ in tiles)
    totw = sum(len(r[0]) + PAD for _, r, _ in tiles)
    sheet = Image.new("RGB", (totw, maxh + 18), (25, 25, 25))
    from PIL import ImageDraw
    d = ImageDraw.Draw(sheet)
    x = 0
    for n, rows, e in tiles:
        w, h = len(rows[0]), len(rows)
        im = Image.new("RGB", (w, h))
        p = im.load()
        for yy in range(h):
            for xx in range(w):
                v = rows[yy][xx]
                # frames ride the player's palette (POF>), so index -> grey
                # ramp is the honest read: shape is what matters here.
                g = 0 if v == 0 else 40 + (v * 215) // 63
                p[xx, yy] = (0, 0, 70) if v == 0 else (g, g, g)
        sheet.paste(im, (x, 18))
        ax, ay = x + e["anix"], 18 + e["aniy"]
        d.line([(ax - 4, ay), (ax + 4, ay)], fill=(255, 0, 0))
        d.line([(ax, ay - 4), (ax, ay + 4)], fill=(255, 0, 0))
        d.text((x + 1, 4), n[:14], fill=(255, 255, 0))
        x += w + PAD
    sheet.save(os.path.join(ROOT, "tmp", "saheli_raw_art.png"))
    print("\nwrote tmp/saheli_raw_art.png")

main()
