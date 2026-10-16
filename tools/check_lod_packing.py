#!/usr/bin/env python3
"""Check one sidecar's packed records against the authored IMG, at a set depth.

A packing depth (LOD `PPP>`) is lossless only if every stored index fits it.
LOAD2 prints, but does not fail, when it overrides a requested depth, and a
table that was not re-promoted still carries the old control word.  So for
each named set this decodes every record of a table straight out of its
shipped IRW at the depth the record's own control word claims, requires that
depth to be the one the set was repacked to, and compares the pixels with the
authored IMG.  A wrong depth, a stale table, a shifted SAG or a lossy repack
all fail here instead of on screen.

    python tools/check_lod_packing.py            # report every set
    python tools/check_lod_packing.py --check    # Phase D: quiet unless it fails
    python tools/check_lod_packing.py --set SHAOFIST
"""
import argparse
import ast
import bisect
import importlib.util
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name -> (table in src/, authored IMG in data/, label prefix or None for all,
#          expected bits per pixel)
SETS = {
    # SHAOFIST (Kahn's portal-punch pulp burst) was here - retired 2026-09-29,
    # see src/MAINEQU.ASM's kfistpulp note.
    # VS screen stage-name plate (MOVEART1).  OVERSEL_P is 15 colours.
    "VSART": ("VSART.TBL", "KOMBATZN.IMG", None, 4),
    # Cage's headhole heart (MOVEART2).  jtblood_p is 12 colours.
    "JCMK1BLD": ("JCMK1BLD.TBL", "MK1BLOOD.IMG", None, 4),
    # Scorpion's ambient hand fire (MOVEART2).  HNDFIRE_P is 8 colours.
    "FIREHAND": ("FIREHAND.TBL", "FIREHAND.IMG", None, 3),
    # Outer Haven staircase strips.  Not a repack: here for timefloor4A, which
    # LOAD2's checksum folded onto timefloor2D's width-padded image.
    "TIMEFLR": ("TIMEFLR.TBL", "MKBGANI.IMG", None, 5),
}

# Labels LOAD2 folded onto another label's stored image although their authored
# pixels are that image MIRRORED.  LOAD2's duplicate detection treats a mirror
# as a duplicate, and the table control word carries no flip, so the game draws
# these labels mirrored.  Pre-existing packing defects, kept here as exact
# expectations so the check still decodes them: label -> (label whose pixels
# are stored, "h" / "v" / "hv" relation of the authored images).
KNOWN_FOLDS = {
    "FISTPULP4W": ("FISTPULP4V", "h"),
}

IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# LOAD2 (load2.h) pads any image narrower than this to this width, and reads
# the extra columns out of the IMG's own row stride, not as zeros.
MIN_IMG_WIDTH = 3


def mirrored(px, w, h, how):
    rows = [px[y * w:(y + 1) * w] for y in range(h)]
    if "h" in how:
        rows = [r[::-1] for r in rows]
    if "v" in how:
        rows = rows[::-1]
    return b"".join(rows)


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def authored(img):
    blob = img.read_bytes()
    count, palcnt, offset = struct.unpack_from("<HHI", blob)
    imd = _module("imgdump", ROOT / "imgdump.py")
    _, start, _ = imd.detect_record_layout(blob, offset, count, palcnt)
    out = {}
    for i in range(count):
        r = IMAGE.unpack_from(blob, start + i * IMAGE.size)
        w, h, pix = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        pw = max(w, MIN_IMG_WIDTH)
        out[r[0].split(b"\0", 1)[0].decode("latin-1").upper()] = (
            w, h, b"".join(blob[pix + y * stride: pix + y * stride + w] for y in range(h)),
            b"".join(blob[pix + y * stride: pix + y * stride + pw] for y in range(h)))
    return out


def shipped_irws():
    mv = _module("mv", ROOT / "makevrom.py")
    tree = ast.parse((ROOT / "makevrom.py").read_text())
    names = next(ast.literal_eval(n.value) for n in ast.walk(tree)
                 if isinstance(n, ast.Assign)
                 and any(isinstance(t, ast.Name) and t.id == "irw_files" for t in n.targets))
    spans = []
    for name in names:
        path = ROOT / "data" / name
        base, bank, payload = mv.parse_irw(path)
        if bank not in mv.BANK_OFFSETS:
            bank = mv.FILE_BANK.get(name, 0)
        start = mv.BANK_OFFSETS[bank] + mv.image_byte_offset(base, bank)
        spans.append((start, start + len(payload), name, payload))
    spans.sort()
    return spans


def check_set(name, spans, starts, tables):
    tbl, img, prefix, want_bpp = SETS[name]
    source = authored(ROOT / "data" / img)
    recs = [t for t in tables if t[0].upper() == tbl.upper()
            and (prefix is None or t[1].upper().startswith(prefix))]
    if not recs:
        raise ValueError(f"{name}: no records in {tbl}")
    stored = 0
    for _, label, w, h, sag, ctrl in recs:
        bpp = (ctrl >> 12) & 7 or 8
        if bpp != want_bpp:
            raise ValueError(f"{label}: stored at {bpp} bpp, expected {want_bpp}")
        key = label.upper()
        if key not in source:
            raise ValueError(f"{label}: not a record in {img}")
        src_w, src_h = source[key][:2]
        if (w, h) != (max(src_w, MIN_IMG_WIDTH), src_h):
            raise ValueError(f"{label}: {w}x{h} in {tbl} but {src_w}x{src_h} in {img}")
        k = bisect.bisect_right(starts, sag // 8) - 1
        if k < 0 or sag // 8 >= spans[k][1]:
            raise ValueError(f"{label}: SAG {sag:#x} is in no shipped IRW")
        base, _, irw, payload = spans[k]
        pos = sag - base * 8

        def take(n):
            nonlocal pos
            if pos < 0 or pos + n > len(payload) * 8:
                raise ValueError(f"{label}: packed pixels run past {irw}")
            byte, shift = divmod(pos, 8)
            value = int.from_bytes(payload[byte:byte + 3], "little") >> shift
            pos += n
            return value & ((1 << n) - 1)

        pixels = bytearray()
        begin = pos
        for y in range(h):
            lead = trail = 0
            if ctrl & 0x80:
                header = take(8)
                lead = (header & 15) << ((ctrl >> 8) & 3)
                trail = (header >> 4) << ((ctrl >> 10) & 3)
            if lead + trail > w:
                raise ValueError(f"{label} row {y}: invalid compression header")
            pixels.extend(bytes(lead))
            pixels.extend(take(bpp) for _ in range(w - lead - trail))
            pixels.extend(bytes(trail))
        mask = (1 << bpp) - 1
        want = source[key][3]
        if key in KNOWN_FOLDS:
            stored_as, how = KNOWN_FOLDS[key]
            if mirrored(want, w, h, how) != source[stored_as][3]:
                raise ValueError(f"{label}: KNOWN_FOLDS says it is {stored_as} mirrored "
                                 f"({how}) in {img}, and it no longer is - re-check the fold")
            want = source[stored_as][3]
        if any(v > mask for v in want):
            raise ValueError(f"{label}: authored indices exceed {bpp} bpp - the repack is lossy")
        if bytes(pixels) != bytes(want):
            raise ValueError(f"{label}: packed pixels differ from {img} at {bpp} bpp")
        stored += pos - begin
    return len(recs), stored // 8


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="quiet unless it fails")
    ap.add_argument("--set", choices=sorted(SETS), action="append")
    args = ap.parse_args()
    bppm = _module("bppaudit", ROOT / "tools/audit_sprite_bpp.py")
    tables = list(bppm.parse_tbls(str(ROOT / "src")))
    spans = shipped_irws()
    starts = [s[0] for s in spans]
    failed = False
    for name in args.set or sorted(SETS):
        try:
            count, stored = check_set(name, spans, starts, tables)
        except (ValueError, OSError) as exc:
            print(f"LOD packing check FAILED: {exc}")
            failed = True
            continue
        if not args.check:
            print(f"{name}: {count} records at {SETS[name][3]} bpp, {stored:,} B of packed "
                  f"records, pixel-identical to {SETS[name][1]}")
    if not failed:
        print(f"LOD packing OK: {', '.join(args.set or sorted(SETS))}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
