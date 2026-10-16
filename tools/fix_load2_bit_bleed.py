#!/usr/bin/env python3
"""Repair LOAD2's stray pixel bits in named records, against the authored IMG.

LOAD2 sometimes ORs a stray bit or two into a compressed record's last rows,
and which pixels it hits depends on where the record lands in its run, so a
record can change every time art before it grows or shrinks.  MKSPLIT.TBL's
JXSPLIT9A (Jax's split fatality, NUJAX10.IMG) has been 1, 2 and 4 pixels
wrong in three builds; art_identity_snapshot.py flags it as CHANGED whenever
MK6MIL reflows.

For each record in REPAIRS this decodes the stored record out of its IRW,
re-reads the same image out of the authored IMG, masks the authored indices
to the record's bits per pixel, and rewrites only the pixel values that
differ - never a row header, never a bit outside the record.  It re-derives
everything from the current tables every run, so it follows the record when
it moves.  It refuses (exit 2) rather than guess when:

  - the record's size differs from the authored image,
  - a row header does not decode or the walk leaves the IRW payload,
  - another record's SAG falls inside this record's bits,
  - more than MAX_FIX pixels differ (a wrong image, not bit bleed).

    python tools/fix_load2_bit_bleed.py            # report
    python tools/fix_load2_bit_bleed.py --apply    # Phase B, after LOAD2
    python tools/fix_load2_bit_bleed.py --check    # Phase D: exit 1 if unrepaired
"""
from __future__ import annotations

import argparse
import bisect
import importlib.util
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (table file, label, authored IMG under data/)
REPAIRS = [
    ("MKSPLIT.TBL", "JXSPLIT9A", "NUJAX10.IMG"),
    # Shang Tsung's nut crunch: 6 px, all 3 -> 0, rows 116-120 of 121.
    ("MKST.TBL", "STNUTCRUNCH1B", "TSUNG9.IMG"),
    # NOT pitblood1b (MKBGANI): its 3 px run down column 2 mid-record and its
    # sibling pitblood1a differs from MKBGANI.IMG in 159 px that are not bleed,
    # so the authored IMG is not proven to be the intended pixels there.
]

MAX_FIX = 16
IRW_HEADER_SIZE = 68
IRW_SIZE_OFF = 48
IRW_CHECKSUM_OFF = 52


def _module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def payload_checksum(payload: bytes) -> int:
    """Same sum fix_armory_mk7_bg.py keeps in the IRW header."""
    total = 0
    even = len(payload) - (len(payload) % 2)
    for off in range(0, even, 2):
        total = (total + struct.unpack_from("<H", payload, off)[0]) & 0xFFFFFFFF
    if len(payload) % 2:
        total = (total + payload[-1]) & 0xFFFFFFFF
    return total


def authored_pixels(img_path: Path, label: str):
    imgdump = _module("imgdump", ROOT / "imgdump.py")
    data = img_path.read_bytes()
    imgcnt, palcnt, oset = struct.unpack_from("<HHI", data, 0)
    _, img_start, _ = imgdump.detect_record_layout(data, oset, imgcnt, palcnt)
    for k in range(imgcnt):
        f = imgdump.IMAGE.unpack_from(data, img_start + k * imgdump.IMAGE.size)
        if imgdump.cstr(f[0]).upper() == label.upper():
            w, h, off = f[4], f[5], f[7]
            stride = (w + 3) & ~3
            return w, h, [data[off + y * stride:off + y * stride + w] for y in range(h)]
    raise LookupError(f"{label} not in {img_path.name}")


class BitBuf:
    """Little-endian bit access into one IRW's payload by flat ROM bit address."""

    def __init__(self, buf: bytearray, bit_base: int):
        self.buf, self.base = buf, bit_base

    def _span(self, at: int, n: int):
        rel = at - self.base
        if rel < 0 or (rel + n + 7) // 8 > len(self.buf) - IRW_HEADER_SIZE:
            raise IndexError(f"bit {at:#x} outside the IRW payload")
        return IRW_HEADER_SIZE + rel // 8, rel % 8

    def read(self, at: int, n: int) -> int:
        j, s = self._span(at, n)
        v = int.from_bytes(self.buf[j:j + 4], "little")
        return (v >> s) & ((1 << n) - 1)

    def write(self, at: int, n: int, value: int) -> None:
        j, s = self._span(at, n)
        v = int.from_bytes(self.buf[j:j + 4], "little")
        mask = ((1 << n) - 1) << s
        v = (v & ~mask) | ((value << s) & mask)
        self.buf[j:j + 4] = v.to_bytes(4, "little")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    mv = _module("mv", ROOT / "makevrom.py")
    bppm = _module("bppaudit", ROOT / "tools/audit_sprite_bpp.py")
    tables = list(bppm.parse_tbls(str(ROOT / "src")))
    all_sags = sorted(t[4] for t in tables)

    # Which shipped IRW holds which flat bytes - makevrom's own layout.
    irws = []
    import ast
    tree = ast.parse((ROOT / "makevrom.py").read_text())
    shipping = next(ast.literal_eval(n.value) for n in ast.walk(tree)
                    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "irw_files" for t in n.targets))
    for name in shipping:
        path = ROOT / "data" / name
        base, bank, payload = mv.parse_irw(path)
        if bank not in mv.BANK_OFFSETS:
            bank = mv.FILE_BANK.get(name, 0)
        start = mv.BANK_OFFSETS[bank] + mv.image_byte_offset(base, bank)
        irws.append((start, start + len(payload), name, path))
    irws.sort()
    starts = [i[0] for i in irws]

    unrepaired = 0
    dirty_files: dict[Path, bytearray] = {}
    for tbl, label, img in REPAIRS:
        rec = [t for t in tables if t[0].upper() == tbl.upper() and t[1] == label]
        if len(rec) != 1:
            print(f"error: {tbl}:{label} found {len(rec)} times", file=sys.stderr)
            return 2
        _, _, w, h, sag, ctrl = rec[0]
        k = bisect.bisect_right(starts, sag // 8) - 1
        if k < 0 or sag // 8 >= irws[k][1]:
            print(f"error: {label} SAG {sag:#x} is in no shipped IRW", file=sys.stderr)
            return 2
        flat_start, _, irw_name, irw_path = irws[k]
        buf = dirty_files.get(irw_path) or bytearray(irw_path.read_bytes())
        bits = BitBuf(buf, flat_start * 8)

        aw, ah, rows = authored_pixels(ROOT / "data" / img, label)
        if (aw, ah) != (w, h):
            print(f"error: {label} is {w}x{h} in {tbl} but {aw}x{ah} in {img}", file=sys.stderr)
            return 2

        bpp = (ctrl >> 12) & 7 or 8
        comp = bool(ctrl & 0x80)
        lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
        pmask = (1 << bpp) - 1
        pos, fixes = sag, []
        try:
            for y in range(h):
                if comp:
                    hdr = bits.read(pos, 8)
                    pos += 8
                    lead, trail = (hdr & 15) << lm, (hdr >> 4) << tm
                else:
                    lead = trail = 0
                if lead + trail > w:
                    print(f"error: {label} row {y} header {hdr:#04x} does not decode", file=sys.stderr)
                    return 2
                for x in range(w):
                    want = rows[y][x] & pmask
                    if lead <= x < w - trail:
                        got = bits.read(pos, bpp)
                        if got != want:
                            fixes.append((x, y, pos, got, want))
                        pos += bpp
                    elif want:
                        # a non-zero authored pixel LOAD2 chose to skip: not bit bleed
                        print(f"error: {label} ({x},{y}) is authored {want} but not stored", file=sys.stderr)
                        return 2
        except IndexError as exc:
            print(f"error: {label}: {exc}", file=sys.stderr)
            return 2
        end = pos
        inside = [s for s in all_sags[bisect.bisect_right(all_sags, sag):] if s < end]
        if inside:
            print(f"error: {label} bits [{sag:#x},{end:#x}) contain other records at {', '.join(hex(s) for s in inside[:4])}", file=sys.stderr)
            return 2
        if len(fixes) > MAX_FIX:
            print(f"error: {label} differs from {img} in {len(fixes)} pixels (> {MAX_FIX}); not bit bleed", file=sys.stderr)
            return 2

        print(f"{tbl}:{label} {w}x{h} bpp{bpp} SAG {sag:#010x} in {irw_name}: "
              f"{len(fixes)} stray pixel(s) vs {img}" + (" - clean" if not fixes else ""))
        for x, y, at, got, want in fixes:
            print(f"  ({x},{y}) bit {at:#x}: {got} -> {want}")
        if fixes and args.apply:
            for x, y, at, got, want in fixes:
                bits.write(at, bpp, want)
            dirty_files[irw_path] = buf
        elif fixes:
            unrepaired += len(fixes)

    for path, buf in dirty_files.items():
        declared = struct.unpack_from("<I", buf, IRW_SIZE_OFF)[0]
        if declared:
            struct.pack_into("<I", buf, IRW_CHECKSUM_OFF,
                             payload_checksum(bytes(buf[IRW_HEADER_SIZE:IRW_HEADER_SIZE + declared])))
        path.write_bytes(buf)
        print(f"repaired {path.relative_to(ROOT)}")

    if args.check and unrepaired:
        print(f"{unrepaired} stray pixel(s) unrepaired - run tools/fix_load2_bit_bleed.py --apply")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
