"""Round-trip check: does the video ROM hold exactly the art that was authored?

Answers "did my IMG re-import actually land" without eyeballing it in game, and
separates an art problem from a pipeline problem.  Defaults to Kahn's SONICLAP
wave; override with VII_IMG / VII_IRW / VII_TBL / VII_PREFIX / VII_N.


Top row  = art decoded straight out of data/BOSS4.IMG (what was authored).
Bottom   = art decoded out of the built sidecar data/SCLAP.IRW using the real
           control-word semantics the blitter uses (bpp = ctrl bits 12-14,
           dmacmp = bit 7 per-line lead/trail nibbles shifted by bits 8-9 /
           10-11).

A mismatch means the import/packing is wrong.  Magenta = out-of-palette index.
"""
import os, re, struct, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_NAME = os.environ.get("VII_IMG", "BOSS4.IMG")
IRW_NAME = os.environ.get("VII_IRW", "SCLAP.IRW")
TBL_NAME = os.environ.get("VII_TBL", "MKSK.TBL")
PREFIX = os.environ.get("VII_PREFIX", "SONICLAP")
NFRAMES = int(os.environ.get("VII_N", "11"))
LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
IRW_HEADER_SIZE, IRW_BASE_OFF, IRW_SIZE_OFF = 68, 44, 48
FRAMES = [f"{PREFIX}{i}" for i in range(1, NFRAMES + 1)]


def rgb(w):
    return ((w >> 10 & 31) * 255 // 31, (w >> 5 & 31) * 255 // 31, (w & 31) * 255 // 31)


# ------------------------------------------------------------------ the IMG
img = open(os.path.join(ROOT, "data", IMG_NAME), "rb").read()
imgcnt, palcnt, oset = LIB_HDR.unpack_from(img, 0)[:3]
pal_start = oset + imgcnt * IMAGE.size
recs = {}
for i in range(imgcnt):
    f = IMAGE.unpack_from(img, oset + i * IMAGE.size)
    nm = f[0].split(b"\0", 1)[0].decode("latin-1")
    if nm in FRAMES:
        recs[nm] = dict(w=f[4], h=f[5], palnum=f[6], off=f[7])
pals = []
for i in range(palcnt):
    p = PALETTE.unpack_from(img, pal_start + i * PALETTE.size)
    pals.append(dict(name=p[0].split(b"\0", 1)[0].decode("latin-1"),
                     bpp=p[2], ncol=p[3], off=p[4]))
pal = pals[recs[FRAMES[0]]["palnum"] - 3]   # palnum is 3-BASED
cols = list(struct.unpack_from(f"<{pal['ncol']}H", img, pal["off"]))
print(f"palette '{pal['name']}' bits_pr_pxl={pal['bpp']} ncol={pal['ncol']}")
print("colours: " + " ".join(f"{c:04X}" for c in cols))


def from_img(n):
    r = recs[n]
    w, h, stride = r["w"], r["h"], (r["w"] + 3) & ~3
    out = [[img[r["off"] + y * stride + x] for x in range(w)] for y in range(h)]
    return out, w, h


# ------------------------------------------------------------------ the ROM
irw = open(os.path.join(ROOT, "data", IRW_NAME), "rb").read()
base = struct.unpack_from("<I", irw, IRW_BASE_OFF)[0]
size = struct.unpack_from("<I", irw, IRW_SIZE_OFF)[0]
payload = irw[IRW_HEADER_SIZE:IRW_HEADER_SIZE + size]
print(f"\nSCLAP.IRW base={base:#x} size={size} payload={len(payload)}")

TBL = open(os.path.join(ROOT, "src", TBL_NAME), "r", errors="replace").read()
tbl = {}
for n in FRAMES:
    m = re.search(rf"^{n}:\s*\n\s*\.word\s+([-\d]+),([-\d]+),([-\d]+),([-\d]+)\s*\n"
                  rf"\s*\.long\s+0?([0-9A-Fa-f]+)H\s*\n\s*\.word\s+0?([0-9A-Fa-f]+)H",
                  TBL, re.M)
    if m:
        tbl[n] = dict(w=int(m.group(1)), h=int(m.group(2)),
                      sag=int(m.group(5), 16), ctrl=int(m.group(6), 16))


class Bits:
    def __init__(self, buf, bitpos):
        self.b, self.p = buf, bitpos

    def read(self, n):
        # LSB-first: how the 34010 walks a field stream (audit_sprite_bpp.py)
        v = 0
        for i in range(n):
            p = self.p + i
            if (p >> 3) >= len(self.b):
                raise EOFError
            v |= ((self.b[p >> 3] >> (p & 7)) & 1) << i
        self.p += n
        return v


BPP_OVERRIDE = int(os.environ.get("SONIC_BPP", "0"))


def from_rom(n):
    e = tbl[n]
    bpp = BPP_OVERRIDE or ((e["ctrl"] >> 12) & 7 or 8)
    cmpd = bool(e["ctrl"] & 0x80)
    ldx, trx = (e["ctrl"] >> 8) & 3, (e["ctrl"] >> 10) & 3
    # IRW `base` is a BIT address in LOD space; a bank-1 sidecar's runtime SAG
    # carries an extra 0x2000000 (SCLAP.LOD is `***> 3F88000,1`).
    delta = e["sag"] - base
    if delta >= 0x2000000:
        delta -= 0x2000000
    br = Bits(payload, delta)
    w, h = e["w"], e["h"]
    rows = []
    for _ in range(h):
        if cmpd:
            hdr = br.read(8)
            lead, trail = (hdr & 0xF) << ldx, (hdr >> 4) << trx
            npix = w - lead - trail
            row = [0] * lead + [br.read(bpp) for _ in range(max(npix, 0))] + [0] * trail
        else:
            row = [br.read(bpp) for _ in range(w)]
        rows.append(row[:w] + [0] * max(0, w - len(row)))
    return rows, w, h, e["ctrl"], bpp, cmpd


cw = sum(recs[f]["w"] + 4 for f in FRAMES)
ch = max(recs[f]["h"] for f in FRAMES)
sheet = Image.new("RGB", (cw, ch * 2 + 8), (20, 20, 28))
px = sheet.load()
x0 = 0
bad = 0
for f in FRAMES:
    a, w, h = from_img(f)
    for y in range(h):
        for x in range(w):
            i = a[y][x]
            px[x0 + x, y] = rgb(cols[i]) if i < len(cols) else (255, 0, 255)
    try:
        b, bw, bh, ctrl, bpp, cmpd = from_rom(f)
        for y in range(bh):
            for x in range(bw):
                i = b[y][x]
                px[x0 + x, ch + 8 + y] = rgb(cols[i]) if i < len(cols) else (255, 0, 255)
        same = a == b
        mx = max(max(r) for r in b)
        if not same:
            bad += 1
        print(f"  {f:<11} {w}x{h} ctrl={ctrl:#06x} bpp={bpp} cmp={'Y' if cmpd else 'N'} "
              f"maxidx={mx} {'MATCH' if same else '*** DIFFERS ***'}")
    except Exception as exc:
        bad += 1
        print(f"  {f:<11} ROM decode FAILED: {exc!r}")
    x0 += w + 4

out = sys.argv[1] if len(sys.argv) > 1 else "soniclap_check.png"
sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST).save(out)
print(f"\n{bad} frame(s) differ. wrote {out} (top={IMG_NAME}, bottom={IRW_NAME})")
