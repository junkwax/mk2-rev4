"""PKZIP method-6 (Imploding) codec for the MK2 movie/.BIN pipeline."""

def read_tree(data, off):
    n = data[off] + 1; off += 1
    lens = []
    for _ in range(n):
        v = data[off]; off += 1
        lens += [(v & 0xf) + 1] * (((v >> 4) & 0xf) + 1)
    return lens, off

def canonical(lens, complement):
    """symbol -> (code, length). Canonical by (length, symbol)."""
    codes = {}
    code = 0
    for L in range(1, 17):
        for sym, sl in enumerate(lens):
            if sl == L:
                codes[sym] = ((code ^ ((1 << L) - 1)) if complement else code, L)
                code += 1
        code <<= 1
    return codes

class BitIn:
    def __init__(self, d, off): self.d, self.p, self.b, self.n = d, off, 0, 0
    def bit(self):
        if self.n == 0:
            self.b = self.d[self.p]; self.p += 1; self.n = 8
        v = self.b & 1; self.b >>= 1; self.n -= 1
        return v
    def bits(self, k):          # LSB-first multi-bit field
        v = 0
        for i in range(k): v |= self.bit() << i
        return v

def decode_sym(bi, lut):
    code, L = 0, 0
    while L < 16:
        code = (code << 1) | bi.bit(); L += 1
        s = lut.get((code, L))
        if s is not None: return s
    raise ValueError("bad code")

def explode(payload, outlen, dict_bits=6, complement=True):
    lt, off = read_tree(payload, 0)
    dt, off = read_tree(payload, off)
    lmap = {(c, L): s for s, (c, L) in canonical(lt, complement).items()}
    dmap = {(c, L): s for s, (c, L) in canonical(dt, complement).items()}
    bi = BitIn(payload, off)
    out = bytearray()
    while len(out) < outlen:
        if bi.bit():                                  # 1 = literal
            out.append(bi.bits(8))
        else:                                         # 0 = match
            dlow = bi.bits(dict_bits)
            dhigh = decode_sym(bi, dmap)
            dist = ((dhigh << dict_bits) | dlow) + 1
            ln = decode_sym(bi, lmap)
            if ln == 63: ln += bi.bits(8)
            ln += 2                                   # 2-tree mode minimum
            # The 4K window starts ZERO-FILLED, so a match may legally reach
            # back before the start of output - it copies zeros.  Frames whose
            # art begins with a run of 0 pixels open with exactly such a token.
            for _ in range(ln):
                src = len(out) - dist
                out.append(out[src] if src >= 0 else 0)
    return bytes(out)


# ---------------------------------------------------------------- encoder ---

def _pack_tree(lens):
    """Inverse of read_tree: run-length the bit lengths into definition bytes."""
    runs = []
    for L in lens:
        if runs and runs[-1][0] == L and runs[-1][1] < 16:
            runs[-1][1] += 1
        else:
            runs.append([L, 1])
    out = bytearray([len(runs) - 1])
    for L, cnt in runs:
        out.append(((cnt - 1) << 4) | (L - 1))
    return bytes(out)

def _lengths_from_freqs(freqs, nsym, maxbits=16):
    """Package-merge style length assignment, capped at maxbits."""
    import heapq
    # every symbol must get a code (the tree is a complete 64-entry table)
    f = [max(1, freqs[i]) for i in range(nsym)]
    # ordinary Huffman first
    h = [(f[i], i, [i]) for i in range(nsym)]
    heapq.heapify(h)
    lens = [0] * nsym
    while len(h) > 1:
        w1, _, g1 = heapq.heappop(h)
        w2, _, g2 = heapq.heappop(h)
        for s in g1 + g2: lens[s] += 1
        heapq.heappush(h, (w1 + w2, min(g1 + g2), g1 + g2))
    # enforce the 16-bit ceiling, keeping the code complete (Kraft == 1)
    while max(lens) > maxbits:
        over = max(range(nsym), key=lambda s: lens[s])
        lens[over] -= 1
        under = min(range(nsym), key=lambda s: (lens[s], -f[s]))
        lens[under] += 1
    return lens

class BitOut:
    def __init__(self): self.data = bytearray(); self.acc = 0; self.n = 0
    def bit(self, v):
        self.acc |= (v & 1) << self.n; self.n += 1
        if self.n == 8: self.data.append(self.acc); self.acc = 0; self.n = 0
    def bits(self, v, k):                      # LSB-first field
        for i in range(k): self.bit((v >> i) & 1)
    def code(self, c, L):                      # canonical code, MSB-first
        for i in range(L - 1, -1, -1): self.bit((c >> i) & 1)
    def flush(self):
        if self.n: self.data.append(self.acc); self.acc = 0; self.n = 0
        return bytes(self.data)

def _matches(src, dict_bits=6, max_dist=None, min_len=2):
    """Greedy LZ77 with a hash chain.  Yields ('lit',b) / ('mat',dist,len)."""
    max_dist = max_dist or (1 << (dict_bits + 6))
    n = len(src); i = 0
    heads = {}
    chain = [-1] * n
    while i < n:
        best_len = 0; best_dist = 0
        if i + min_len <= n:
            key = src[i:i+2]
            j = heads.get(key, -1)
            tries = 0
            while j >= 0 and tries < 64:
                d = i - j
                if d > max_dist: break
                L = 0
                lim = min(320, n - i)
                while L < lim and src[j + L] == src[i + L]: L += 1
                if L > best_len: best_len, best_dist = L, d
                if best_len >= lim: break
                j = chain[j]; tries += 1
        if best_len >= min_len and best_len >= 2:
            yield ('mat', best_dist, best_len)
            step = best_len
        else:
            yield ('lit', src[i]); step = 1
        for k in range(i, min(i + step, n - 1)):
            key = src[k:k+2]
            chain[k] = heads.get(key, -1); heads[key] = k
        i += step

def implode(src, dict_bits=6):
    """Compress to a PKZIP method-6 stream (2 trees, no literal tree)."""
    toks = list(_matches(src, dict_bits))
    lfreq = [0] * 64; dfreq = [0] * 64
    for t in toks:
        if t[0] == 'mat':
            _, dist, L = t
            raw = L - 2
            lfreq[min(raw, 63)] += 1
            dfreq[(dist - 1) >> dict_bits] += 1
    llens = _lengths_from_freqs(lfreq, 64)
    dlens = _lengths_from_freqs(dfreq, 64)
    lcodes = canonical(llens, True)
    dcodes = canonical(dlens, True)
    bo = BitOut()
    for t in toks:
        if t[0] == 'lit':
            bo.bit(1); bo.bits(t[1], 8)
        else:
            _, dist, L = t
            bo.bit(0)
            d = dist - 1
            bo.bits(d & ((1 << dict_bits) - 1), dict_bits)
            c, n = dcodes[d >> dict_bits]; bo.code(c, n)
            raw = L - 2
            if raw >= 63:
                c, n = lcodes[63]; bo.code(c, n); bo.bits(raw - 63, 8)
            else:
                c, n = lcodes[raw]; bo.code(c, n)
    return _pack_tree(llens) + _pack_tree(dlens) + bo.flush()


# -------------------------------------------------------------------- cli ---

def _synth_zip(payload, raw, name=b'X.FRM'):
    """Wrap a stream in a minimal method-6 ZIP so a real explode can check it."""
    import struct, zlib
    crc = zlib.crc32(raw) & 0xffffffff
    lfh = struct.pack('<IHHHHHIIIHH', 0x04034b50, 10, 0, 6, 0, 0,
                      crc, len(payload), len(raw), len(name), 0) + name
    cd = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 10, 0, 6, 0, 0,
                     crc, len(payload), len(raw), len(name), 0, 0, 0, 0, 0, 0) + name
    off = len(lfh) + len(payload)
    eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 1, 1, len(cd), off, 0)
    return lfh + payload + cd + eocd


def main(argv):
    import os, subprocess, tempfile
    here = os.path.dirname(os.path.abspath(__file__))
    data = os.path.join(os.path.dirname(here), 'data')
    if len(argv) < 2:
        print(__doc__)
        print("usage: implode.py pack <STEM> [...]   build data/<STEM>.BIN from .FRM + .HDR")
        print("       implode.py verify <STEM> [...] explode an existing .BIN, compare to .FRM")
        print("       implode.py verify-all          check every .FRM/.BIN pair in data/")
        return 1
    cmd, stems = argv[1], argv[2:]
    if cmd == 'verify-all':
        stems = sorted(n[:-4] for n in os.listdir(data) if n.endswith('.BIN'))
        cmd = 'verify'
    rc = 0
    for stem in stems:
        frm_p = os.path.join(data, stem + '.FRM')
        hdr_p = os.path.join(data, stem + '.HDR')
        bin_p = os.path.join(data, stem + '.BIN')
        if not (os.path.exists(frm_p) and os.path.exists(hdr_p)):
            print(f"{stem}: missing .FRM or .HDR"); rc = 1; continue
        raw = open(frm_p, 'rb').read()
        hdr = open(hdr_p, 'rb').read()
        if cmd == 'verify':
            if not os.path.exists(bin_p):
                print(f"{stem}: no .BIN"); rc = 1; continue
            pay = open(bin_p, 'rb').read()[len(hdr):]
            got = explode(pay, len(raw))
            print(f"{stem}: {'OK' if got == raw else 'MISMATCH'}")
            rc |= (got != raw)
            continue
        if cmd != 'pack':
            print(f"unknown command {cmd}"); return 1
        pay = implode(raw)
        if explode(pay, len(raw)) != raw:
            print(f"{stem}: self round-trip FAILED, refusing to write"); rc = 1; continue
        # second opinion from a real explode implementation, if one is around
        verdict = 'unzip unavailable'
        try:
            with tempfile.TemporaryDirectory() as td:
                zp = os.path.join(td, 't.zip')
                open(zp, 'wb').write(_synth_zip(pay, raw))
                out = subprocess.run(['unzip', '-p', zp], capture_output=True)
                verdict = 'unzip OK' if out.stdout == raw else 'unzip REJECTED'
                if out.stdout != raw:
                    print(f"{stem}: {verdict}, refusing to write"); rc = 1; continue
        except FileNotFoundError:
            pass
        open(bin_p, 'wb').write(hdr + pay)
        print(f"{stem}: wrote {os.path.basename(bin_p)}  hdr={len(hdr)} + payload={len(pay)}"
              f" = {len(hdr)+len(pay)} bytes  [{verdict}]")
    return rc


if __name__ == '__main__':
    import sys
    raise SystemExit(main(sys.argv))
