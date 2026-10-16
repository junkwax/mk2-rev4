#!/usr/bin/env python3
"""Composite what the TOWER actually puts on screen: every module placed by its
BGND.ASM .word offset relative to its LOAD2-shrunk origin, each plane scrolled
at its own tower_scroll rate, drawn in dlists_tower order."""
import os, sys, struct, zlib

D = r'C:\Users\you\Workplace\mk2-main\data'
STAGE = sys.argv[1] if len(sys.argv) > 1 else 'TOWER3'
OUT   = sys.argv[2] if len(sys.argv) > 2 else 'tower3.png'
CAMS  = [int(a) for a in sys.argv[3:]] or [361]

SCREEN_W, SCREEN_H = 400, 254
WORLDTLX0, WORLDTLY = 361, -14
FIGHT_LINE = 243
PLAYFIELD = 0x20000

# module -> (BGND .word offset, tower_scroll rate), in dlists_tower draw order
PLANES = [('PLANE5', 0.625), ('PLANE4', 0.6875), ('PLANE3', 0.8125)]

def read_line(f):
    b = bytearray()
    while True:
        c = f.read(1)
        if not c: return None if not b else b.decode('latin1')
        if c == b'\n': return b.decode('latin1').rstrip('\r')
        b += c

def load_bdd(p):
    imgs, pals = {}, []
    with open(p, 'rb') as f:
        n = int(read_line(f).strip())
        for _ in range(n):
            q = read_line(f).split()
            idx, w, h = int(q[0], 16), int(q[1]), int(q[2])
            imgs[idx] = (w, h, f.read(w * h))
        while True:
            ln = read_line(f)
            if ln is None: break
            if not ln.strip(): continue
            nm, cnt = ln.split()[0], int(ln.split()[1])
            raw = f.read(cnt * 2)
            cols = []
            for i in range(cnt):
                v = struct.unpack_from('<H', raw, 2 * i)[0]
                r = (v >> 10) & 31; g = (v >> 5) & 31; b = v & 31
                cols.append((r * 255 // 31, g * 255 // 31, b * 255 // 31))
            pals.append((nm, cols))
    return imgs, pals

def load_bdb(p):
    L = [l.rstrip('\n').rstrip('\r') for l in open(p, encoding='latin1') if l.strip()]
    h = L[0].split(); nmod = int(h[4])
    mods = [[q.split()[0]] + list(map(int, q.split()[1:5])) for q in L[1:1 + nmod]]
    objs = [[int(q[0], 16), int(q[1]), int(q[2]), int(q[3], 16), int(q[4])]
            for q in (x.split() for x in L[1 + nmod:])]
    return mods, objs

def ti_int(t):
    """TI assembler literal: decimal, or hex with a trailing h (e.g. -021h)."""
    t = t.strip()
    neg = t.startswith('-')
    if neg: t = t[1:]
    v = int(t[:-1], 16) if t[-1:].lower() == 'h' else int(t)
    return -v if neg else v


def bgnd_offset(module):
    """The .word x,y following '.long <module>BMOD' in BGND.ASM's tower_mod."""
    src = open(r'C:\Users\you\Workplace\mk2-main\src\BGND.ASM', encoding='latin1').read().split('\n')
    lo = next(i for i, l in enumerate(src) if l.startswith('tower_mod'))
    hi = next(i for i, l in enumerate(src) if i > lo and l.startswith('tower_scroll'))
    for i in range(lo, hi):
        code = src[i].split(';')[0]
        if '.long' in code and module + 'BMOD' in code:
            for nxt in src[i + 1:i + 8]:
                c2 = nxt.split(';')[0]
                if '.word' in c2:
                    a, b = c2.split('.word', 1)[1].strip().split(',')[:2]
                    return ti_int(a), ti_int(b)
    return None

def assign(mods, x, y, w, h):
    for i, (n, x1, x2, y1, y2) in enumerate(mods):
        if x >= x1 and x + w - 1 <= x2 and y >= y1 and y + h - 1 <= y2: return n
    return None

def png(path, w, h, rows):
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    open(path, 'wb').write(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

imgs, pals = load_bdd(os.path.join(D, STAGE + '.BDD'))
mods, objs = load_bdb(os.path.join(D, STAGE + '.BDB'))
offs = {m: bgnd_offset(m) for m, _ in PLANES}
origins = {}
for name, _r in PLANES:
    inb = [o for o in objs if assign(mods, o[1], o[2], imgs[o[3]][0], imgs[o[3]][1]) == name]
    origins[name] = (min(o[1] for o in inb), min(o[2] for o in inb), len(inb))
print("%s: " % STAGE + "  ".join("%s off=%s origin=(%d,%d) blocks=%d"
      % (n, offs[n], origins[n][0], origins[n][1], origins[n][2]) for n, _ in PLANES))

tiles = []
for ci, cam in enumerate(CAMS):
    fb = [[(28, 28, 34)] * SCREEN_W for _ in range(SCREEN_H)]
    for name, rate in PLANES:
        ox, oy = offs[name]
        mx, my, _n = origins[name]
        scroll = WORLDTLX0 + (cam - WORLDTLX0) * rate
        blocks = [o for o in objs if assign(mods, o[1], o[2], imgs[o[3]][0], imgs[o[3]][1]) == name]
        blocks.sort(key=lambda o: (o[0] >> 8))          # insobj_v: ascending z
        for wx, bx, by, ii, pal in blocks:
            w, h, pix = imgs[ii]
            px = ox + (bx - mx) - scroll
            py = oy + (by - my) - WORLDTLY
            cols = pals[pal][1]
            hf, vf = bool(wx & 0x10), bool(wx & 0x20)
            for r in range(h):
                sy = int(py) + r
                if not (0 <= sy < SCREEN_H): continue
                srow = (h - 1 - r) if vf else r
                for c in range(w):
                    sx = int(px) + c
                    if not (0 <= sx < SCREEN_W): continue
                    v = pix[srow * w + ((w - 1 - c) if hf else c)]
                    if v == 0 or v >= len(cols): continue
                    fb[sy][sx] = cols[v]
    for x in range(0, SCREEN_W, 8):                      # fighting line marker
        fb[FIGHT_LINE][x] = (255, 80, 80)
    tiles.append((cam, fb))

GAP = 6
H = SCREEN_H * len(tiles) + GAP * (len(tiles) - 1)
rows = []
for ti, (cam, fb) in enumerate(tiles):
    if ti: rows += [[0, 0, 0] * SCREEN_W for _ in range(GAP)]
    for r in fb: rows.append([v for px in r for v in px])
png(OUT, SCREEN_W, H, rows)
print("wrote %s  (%d camera position(s): %s)" % (OUT, len(CAMS), ', '.join(map(str, CAMS))))
