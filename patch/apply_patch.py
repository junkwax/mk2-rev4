#!/usr/bin/env python3
"""Build mk2rev4.zip (the FBNeo / Fightcade set) from YOUR OWN retail MK2 ROMs.

    python apply_patch.py path/to/mk2.zip [mk2rev4.zip]

Needs Python 3.8+ and nothing else. The input is the standard MAME/FBNeo
`mk2` set (Mortal Kombat II L3.1 program ROMs, L1 video + sound ROMs). Retail
chips are found by SHA-1 (any file names work), and every chip is checked
against CHIPS.tsv before and after patching, so a wrong or bad dump is refused
instead of producing a broken set.

The three .bps files are standard BPS, but they patch the FLAT program, video
and sound images (romsets.py), not single chips, and the video patch's source
is the retail image plus seven bit-shifted copies of it - so use this script
rather than a generic patcher.
"""
import hashlib
import os
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import romsets  # noqa: E402


def _num(p, i):
    v, s = 0, 1
    while True:
        x = p[i]
        i += 1
        v += (x & 0x7F) * s
        if x & 0x80:
            return v, i
        s <<= 7
        v += s


def bps_apply(patch, src):
    if patch[:4] != b'BPS1':
        raise ValueError('not a BPS patch')
    if zlib.crc32(patch[:-4]) != int.from_bytes(patch[-4:], 'little'):
        raise ValueError('patch file is corrupt')
    i = 4
    src_size, i = _num(patch, i)
    tgt_size, i = _num(patch, i)
    meta_size, i = _num(patch, i)
    i += meta_size
    if len(src) != src_size:
        raise ValueError(f'source is {len(src)} bytes, patch wants {src_size}')
    if zlib.crc32(src) != int.from_bytes(patch[-12:-8], 'little'):
        raise ValueError('source does not match (wrong ROM set?)')
    out = bytearray(tgt_size)
    o = src_rel = tgt_rel = 0
    end = len(patch) - 12
    while i < end:
        d, i = _num(patch, i)
        cmd, ln = d & 3, (d >> 2) + 1
        if cmd == 0:            # SourceRead
            out[o:o + ln] = src[o:o + ln]
            o += ln
        elif cmd == 1:          # TargetRead
            out[o:o + ln] = patch[i:i + ln]
            i += ln
            o += ln
        else:
            d, i = _num(patch, i)
            off = (-1 if d & 1 else 1) * (d >> 1)
            if cmd == 2:        # SourceCopy
                src_rel += off
                out[o:o + ln] = src[src_rel:src_rel + ln]
                src_rel += ln
                o += ln
            else:               # TargetCopy (may overlap: byte by byte)
                tgt_rel += off
                for _ in range(ln):
                    out[o] = out[tgt_rel]
                    o += 1
                    tgt_rel += 1
    if zlib.crc32(out) != int.from_bytes(patch[-8:-4], 'little'):
        raise ValueError('patched image failed its checksum')
    return bytes(out)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src_zip = sys.argv[1]
    dst_zip = sys.argv[2] if len(sys.argv) > 2 else 'mk2rev4.zip'

    rows = []
    with open(os.path.join(HERE, 'CHIPS.tsv')) as f:
        next(f)
        for line in f:
            if line.strip():
                rows.append(line.rstrip('\n').split('\t'))

    by_sha = {}
    with zipfile.ZipFile(src_zip) as z:
        for n in z.namelist():
            data = z.read(n)
            by_sha[hashlib.sha1(data).hexdigest()] = data

    retail = {}
    for chip, src_name, src_sha, _, _ in rows:
        if src_sha not in by_sha:
            sys.exit(f'missing retail chip {chip} ({src_name}, sha1 {src_sha})')
        retail[chip] = by_sha[src_sha]

    images = romsets.to_images(retail)
    out_images = {}
    for name in ('program', 'sound', 'video'):
        with open(os.path.join(HERE, f'mk2rev4_{name}.bps'), 'rb') as f:
            out_images[name] = bps_apply(f.read(), romsets.source_for(name, images[name]))
        print(f'ok  {name}')
    chips = romsets.to_chips(out_images)

    with zipfile.ZipFile(dst_zip, 'w', zipfile.ZIP_DEFLATED) as out:
        for chip, _, _, dst_name, dst_sha in rows:
            data = chips[chip]
            if hashlib.sha1(data).hexdigest() != dst_sha:
                sys.exit(f'{dst_name}: output sha1 mismatch')
            out.writestr(zipfile.ZipInfo(dst_name, (1993, 10, 1, 0, 0, 0)), data,
                         zipfile.ZIP_DEFLATED)
    print(f'wrote {dst_zip} ({len(rows)} chips verified) - put it in your FBNeo/Fightcade roms folder')


if __name__ == '__main__':
    main()
