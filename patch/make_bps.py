#!/usr/bin/env python3
"""Make the three BPS patches from a retail mk2 set and a built mk2rev4 set.

    python make_bps.py path/to/mk2.zip path/to/mk2rev4.zip [outdir]

Diffs the flat (de-interleaved) images, not the chips: art that moved in the
build shifts the byte interleave, so per-chip diffs cannot see that it is the
same data, while a flat diff turns it into SourceCopy commands. Sprite records
sit at BIT addresses, so the video patch's source is the retail image followed
by seven copies of it shifted right 1..7 bits (romsets.expand_bits) - moved art
is then a copy from whichever copy lines up. Every patch is re-applied with
apply_patch.bps_apply and checked before it is written.
"""
import hashlib
import os
import sys
import zipfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romsets  # noqa: E402
from apply_patch import bps_apply  # noqa: E402

K = 16        # match key length
STRIDE = 16   # source index sampling
MIN_COPY = 16


def enc(n):
    out = bytearray()
    while True:
        x = n & 0x7F
        n >>= 7
        if n == 0:
            out.append(x | 0x80)
            return out
        out.append(x)
        n -= 1


def diff(src, tgt):
    index = {}
    for p in range(0, len(src) - K + 1, STRIDE):
        index.setdefault(src[p:p + K], p)

    out = bytearray(b'BPS1')
    out += enc(len(src)) + enc(len(tgt)) + enc(0)
    lit_start = 0          # start of pending TargetRead literal
    src_rel = 0
    t = 0
    n = len(tgt)

    def flush(upto):
        nonlocal lit_start
        if upto > lit_start:
            ln = upto - lit_start
            out.extend(enc(((ln - 1) << 2) | 1))
            out.extend(tgt[lit_start:upto])
        lit_start = upto

    def run_len(a, ai, b, bi, limit):
        ln = 0
        while ln < limit:
            step = min(4096, limit - ln)
            if a[ai + ln:ai + ln + step] == b[bi + ln:bi + ln + step]:
                ln += step
                continue
            while ln < limit and a[ai + ln] == b[bi + ln]:
                ln += 1
            return ln
        return ln

    while t < n:
        # 1. same offset in source (SourceRead)
        if t < len(src) and src[t:t + K] == tgt[t:t + K]:
            ln = run_len(src, t, tgt, t, min(len(src), n) - t)
            flush(t)
            out.extend(enc(((ln - 1) << 2) | 0))
            t += ln
            lit_start = t
            continue
        # 2. moved data (SourceCopy)
        s = index.get(tgt[t:t + K])
        if s is not None:
            fwd = run_len(src, s, tgt, t, min(len(src) - s, n - t))
            back = 0
            while back < t - lit_start and back < s and src[s - back - 1] == tgt[t - back - 1]:
                back += 1
            if fwd + back >= MIN_COPY:
                cs, ct, ln = s - back, t - back, fwd + back
                flush(ct)
                out.extend(enc(((ln - 1) << 2) | 2))
                off = cs - src_rel
                out.extend(enc((abs(off) << 1) | (1 if off < 0 else 0)))
                src_rel = cs + ln
                t = ct + ln
                lit_start = t
                continue
        t += 1
    flush(n)
    out += zlib.crc32(src).to_bytes(4, 'little')
    out += zlib.crc32(tgt).to_bytes(4, 'little')
    out += zlib.crc32(out).to_bytes(4, 'little')
    return bytes(out)


def read_set(path):
    chips = {}
    with zipfile.ZipFile(path) as z:
        for n in z.namelist():
            chip = n.rsplit('.', 1)[1].lower()
            if chip in romsets.ALL:
                chips[chip] = (n, z.read(n))
    return chips


def main():
    retail_zip, rev_zip = sys.argv[1:3]
    outdir = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(os.path.abspath(__file__))
    retail = read_set(retail_zip)
    rev = read_set(rev_zip)
    src_img = romsets.to_images({c: d for c, (_, d) in retail.items()})
    tgt_img = romsets.to_images({c: d for c, (_, d) in rev.items()})
    for name in ('program', 'sound', 'video'):
        src = romsets.source_for(name, src_img[name])
        patch = diff(src, tgt_img[name])
        assert bps_apply(patch, src) == tgt_img[name], name
        with open(os.path.join(outdir, f'mk2rev4_{name}.bps'), 'wb') as f:
            f.write(patch)
        print(f'{name:8s} {len(tgt_img[name]):>9,} bytes -> patch {len(patch):>9,}', flush=True)
    with open(os.path.join(outdir, 'CHIPS.tsv'), 'w', newline='\n') as f:
        f.write('chip\tretail_name\tretail_sha1\tmk2rev4_name\tmk2rev4_sha1\n')
        for chip in romsets.ALL:
            rn, rd = retail[chip]
            tn, td = rev[chip]
            f.write(f'{chip}\t{rn}\t{hashlib.sha1(rd).hexdigest()}\t{tn}\t{hashlib.sha1(td).hexdigest()}\n')


if __name__ == '__main__':
    main()
