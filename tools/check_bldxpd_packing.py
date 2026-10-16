"""Check BLDXPD's packed indices, anchors, palette fields and per-frame depth.

No rebuild or mutation. --sag-base is only for the isolated non-dual-bank
LOAD2 fixture; production defaults require the fixed bank-1 runtime SAG.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from makevrom import parse_irw
from make_bldxpd_img import read_back

DEPTHS = [4] * 7 + [3] * 3 + [2] * 2 + [1]
PATTERN = re.compile(
    r'^(BLDXPD\d+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)'
    r'\s*\n\s*\.long\s+0?([0-9a-f]+)H\s*\n\s*\.word\s+0?([0-9a-f]+)H'
    r'\s*\n\s*\.long\s+(\w+)', re.M | re.I)


def check(irw, tbl, img, sag_base=0x05E55480, baseline=False):
    base, bank, payload = parse_irw(irw)
    if base != 0x03E55480 or bank not in (1, 0xffff):
        raise ValueError(f'Wrong fixed-slot header: {base:#x}, bank={bank}')
    if len(payload) > 65536:  # historical cap; the real slot is makevrom's (packed 2026-09-17)
        raise ValueError('BLDXPD exceeds its fixed 64 KiB slot')
    records = PATTERN.findall(tbl.read_text(encoding='ascii'))
    original = read_back(img.read_bytes())
    names = [f'BLDXPD{i}' for i in range(1, 14)]
    if [r[0] for r in records] != names or [r[0] for r in original] != names:
        raise ValueError('Expected exactly the 13 ordered BLDXPD records')
    details = []
    end = 0
    for i, (record, authored) in enumerate(zip(records, original)):
        name, w, h, ax, ay, sag, ctrl, pal = record
        w,h,ax,ay = map(int, (w,h,ax,ay))
        sag,ctrl = int(sag,16),int(ctrl,16)
        bpp = (ctrl >> 12) & 7 or 8
        expected = 4 if baseline else DEPTHS[i]
        if (name,w,h,ax,ay) != authored[:5] or pal != 'BLDXPD_P':
            raise ValueError(f'{name}: geometry/anchor/palette changed')
        if bpp != expected:
            raise ValueError(f'{name}: expected {expected} bpp, got {bpp}')
        pos = sag - sag_base
        if pos != end:
            raise ValueError(f'{name}: noncontiguous or wrong SAG ({pos} != {end})')

        def take(n):
            nonlocal pos
            if pos < 0 or pos+n > len(payload)*8:
                raise ValueError(f'{name}: truncated packed pixels')
            byte, shift = divmod(pos,8)
            value = int.from_bytes(payload[byte:byte+2], 'little') >> shift
            pos += n
            return value & ((1 << n)-1)

        pixels = bytearray()
        for y in range(h):
            lead = trail = 0
            if ctrl & 0x80:
                header = take(8)
                lead = (header & 15) << ((ctrl >> 8) & 3)
                trail = (header >> 4) << ((ctrl >> 10) & 3)
            if lead + trail > w:
                raise ValueError(f'{name} row {y}: invalid compression header')
            pixels.extend(bytes(lead))
            pixels.extend(take(bpp) for _ in range(w-lead-trail))
            pixels.extend(bytes(trail))
        if pixels != authored[5]:
            raise ValueError(f'{name}: packed pixels differ from authored IMG')
        end = pos
        details.append(dict(frame=name,bpp=bpp,width=w,height=h,sag=f'{sag:08x}',
                            control=f'{ctrl:04x}',pixels=len(pixels)))
    # LOAD2 pads the complete payload to a 16-bit boundary.
    if (end+15)//16*2 != len(payload):
        raise ValueError('Unexpected data following the last frame')
    return dict(payload_bytes=len(payload),irw_file_bytes=irw.stat().st_size,
                slot_bytes=65536,slot_remaining=65536-len(payload),frames=details)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--irw',type=Path,default=ROOT/'data/BLDXPD.IRW')
    p.add_argument('--tbl',type=Path,default=ROOT/'src/BLDXPD.TBL')
    p.add_argument('--img',type=Path,default=ROOT/'data/BLDXPD.IMG')
    p.add_argument('--sag-base',type=lambda s:int(s,0),default=0x05E55480)
    p.add_argument('--baseline',action='store_true')
    p.add_argument('--check',action='store_true',help='read-only check (also the default; build.py compatibility)')
    p.add_argument('--json',type=Path)
    args=p.parse_args()
    try:
        result=check(args.irw,args.tbl,args.img,args.sag_base,args.baseline)
    except (ValueError,OSError) as exc:
        print(f'BLDXPD packing FAIL: {exc}');return 1
    if args.json:
        args.json.parent.mkdir(parents=True,exist_ok=True)
        args.json.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('BLDXPD packing PASS: 13 exact index/anchor/palette matches; depths '+
          ','.join(str(f['bpp']) for f in result['frames']))
    print(f"Payload {result['payload_bytes']} bytes; IRW file {result['irw_file_bytes']}; "
          f"reserved slot remaining {result['slot_remaining']} bytes")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
