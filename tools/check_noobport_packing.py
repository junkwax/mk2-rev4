"""Check NOOBPORT's packed indices, anchors, geometry and per-record depth.

data/NOOBPORT.LOD carries three independent sets in one sidecar, and since
opportunity 03 they are no longer packed at one depth:

    NOOBPORTAL1-12    the vortex           5 bpp (NBPORTL_P, 32 entries)
    NSPORTALSHOT1-3   Noob's own body      6 bpp (NOOBDEF_P, 64 entries)
    NOOBAIRGUNK3-8    the opening blast    5 bpp (NOOBGUK_P, 31 entries)

The body strips stay at 6: they are FIGHTER art in an effect-named file and
their palette needs the width.  This guard is what makes that split a
contract rather than a comment - it decodes every record straight out of the
packed IRW at the depth its own control word claims and compares the result
to the authored NOOBPORT.IMG indices, so a wrong depth, a stale table, a
shifted SAG or a lossy repack all fail here instead of on screen.

No rebuild and no mutation.  --baseline expects the old uniform 6 bpp.
"""
import argparse
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from makevrom import parse_irw, CUSTOM_VIDEO_SLOTS

# LOD order.  The packed payload is laid down in exactly this order, so the
# list doubles as the contiguity check.
VORTEX = [f'NOOBPORTAL{i}' for i in range(1, 13)]
BODY = [f'NSPORTALSHOT{i}{s}' for i in (1, 2, 3) for s in 'AB']
BLAST = [f'NOOBAIRGUNK{i}' for i in (3, 4, 5, 6, 8)]
NAMES = VORTEX + BODY + BLAST
DEPTHS = {**{n: 5 for n in VORTEX}, **{n: 6 for n in BODY},
          **{n: 5 for n in BLAST}}

IRW_BASE = 0x05C5D480           # data/NOOBPORT.LOD ***> 5C5D480 (repacked 2026-09-17)
SAG_BASE = IRW_BASE - 0x02000000  # table SAGs are IROM-relative flat bit addrs
IMAGE = struct.Struct('<16s HHH HH H II H HHH HHH')
RECORD = re.compile(
    r'^(\w+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)'
    r'\s*\n\s*\.long\s+0?([0-9a-f]+)H\s*\n\s*\.word\s+0?([0-9a-f]+)H',
    re.M | re.I)


def authored(img):
    """Every NOOBPORT.IMG record as (w, h, anix, aniy, indices)."""
    blob = img.read_bytes()
    count, _, offset = struct.unpack_from('<HHI', blob)
    out = {}
    for i in range(count):
        r = IMAGE.unpack_from(blob, offset + i * IMAGE.size)
        w, h, start = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        sign = lambda v: v - 0x10000 if v & 0x8000 else v
        out[r[0].split(b'\0', 1)[0].decode('latin-1')] = (
            w, h, sign(r[2]), sign(r[3]),
            b''.join(blob[start + y*stride: start + y*stride + w]
                     for y in range(h)))
    return out


def check(irw, tbl, img, sag_base=SAG_BASE, baseline=False):
    base, bank, payload = parse_irw(irw)
    if base != IRW_BASE or bank not in (0, 0xffff):
        raise ValueError(f'Wrong fixed-slot header: {base:#x}, bank={bank}')
    start, end_addr, _ = CUSTOM_VIDEO_SLOTS['NOOBPORT.IRW']
    if len(payload) > end_addr - start:
        raise ValueError(f'NOOBPORT exceeds its {end_addr-start}-byte slot')

    records = RECORD.findall(tbl.read_text(encoding='ascii'))
    if [r[0] for r in records] != NAMES:
        raise ValueError('Expected exactly the 23 ordered NOOBPORT records')
    source = authored(img)

    details = []
    end = 0
    for name, w, h, ax, ay, sag, ctrl in records:
        w, h, ax, ay = map(int, (w, h, ax, ay))
        sag, ctrl = int(sag, 16), int(ctrl, 16)
        bpp = (ctrl >> 12) & 7 or 8
        expected = 6 if baseline else DEPTHS[name]
        if name not in source:
            raise ValueError(f'{name}: not a record in NOOBPORT.IMG')
        if (w, h, ax, ay) != source[name][:4]:
            raise ValueError(f'{name}: geometry/anchor differs from the IMG')
        if bpp != expected:
            raise ValueError(f'{name}: expected {expected} bpp, got {bpp}')
        pos = sag - sag_base
        if pos != end:
            raise ValueError(f'{name}: noncontiguous or wrong SAG '
                             f'({pos} != {end})')

        def take(n):
            nonlocal pos
            if pos < 0 or pos + n > len(payload) * 8:
                raise ValueError(f'{name}: truncated packed pixels')
            byte, shift = divmod(pos, 8)
            value = int.from_bytes(payload[byte:byte+2], 'little') >> shift
            pos += n
            return value & ((1 << n) - 1)

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
            pixels.extend(take(bpp) for _ in range(w - lead - trail))
            pixels.extend(bytes(trail))
        if pixels != source[name][4]:
            raise ValueError(f'{name}: packed pixels differ from authored IMG')
        end = pos
        details.append(dict(record=name, bpp=bpp, width=w, height=h,
                            sag=f'{sag:08x}', control=f'{ctrl:04x}',
                            pixels=len(pixels), packed_bits=pos - (sag-sag_base)))
    # LOAD2 pads the complete payload to a 16-bit boundary.
    if (end + 15) // 16 * 2 != len(payload):
        raise ValueError('Unexpected data following the last record')
    return dict(payload_bytes=len(payload), irw_file_bytes=irw.stat().st_size,
                slot_bytes=end_addr - start,
                slot_remaining=end_addr - start - len(payload),
                records=details)


def noob_extras_on():
    """MAINEQU.ASM's noob_extras: 0 means NOOBPORT is not built at all (its
    space went to the Dead Pool hangers), so there is nothing to check."""
    m = re.search(r"^noob_extras\s+\.set\s+(\d+)",
                  (ROOT / "src" / "MAINEQU.ASM").read_text(encoding="latin-1"), re.M)
    return m is None or m.group(1) != "0"


def main():
    if not noob_extras_on():
        print("NOOBPORT packing: SKIP - noob_extras is 0 (MAINEQU.ASM), the pack is not built")
        return 0
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--irw', type=Path, default=ROOT/'data/NOOBPORT.IRW')
    ap.add_argument('--tbl', type=Path, default=ROOT/'src/NOOBPORT.TBL')
    ap.add_argument('--img', type=Path, default=ROOT/'data/NOOBPORT.IMG')
    ap.add_argument('--sag-base', type=lambda v: int(v, 0), default=SAG_BASE,
                    help='only for an isolated non-dual-bank LOAD2 fixture')
    ap.add_argument('--baseline', action='store_true',
                    help='expect the pre-prototype uniform 6 bpp')
    ap.add_argument('--check', action='store_true', help='quiet unless it fails')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    if not args.irw.exists():
        print('NOOBPORT: no packed IRW - skipping check')
        return 0
    try:
        result = check(args.irw, args.tbl, args.img, args.sag_base, args.baseline)
    except Exception as exc:
        print(f'NOOBPORT packing check FAILED: {exc}')
        return 1
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    if not args.check:
        for r in result['records']:
            print(f"  {r['record']:<16} {r['width']:>3}x{r['height']:<3} "
                  f"{r['bpp']} bpp  ctrl {r['control']}  sag {r['sag']}  "
                  f"{r['packed_bits']//8:>6} B")
    print(f"NOOBPORT packing OK: {result['payload_bytes']} payload bytes, "
          f"{result['slot_remaining']} left in its {result['slot_bytes']}-byte slot")
    return 0


if __name__ == '__main__':
    sys.exit(main())
