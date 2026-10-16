#!/usr/bin/env python3
"""Erase isolated "dot artifact" pixels from Midway IMG frames.

A stray is a connected blob (8-connectivity) of at most --max-cluster
non-transparent pixels that touches nothing else in the frame.  Those render
as loose dots floating around a sprite - e.g. the specks around Raiden during
his victory bolts, which are authored into the stock RADBOLT2.IMG art.

The frame's header (w/h/anipoints) is never touched and the file never changes
size: only pixel bytes inside a frame's own rectangle are zeroed, so the LOD /
LOAD2 pipeline is unaffected apart from having less to pack.

Usage:
    python tools/clean_stray_px.py data/RADBOLT2.IMG RNVICBOLT            # report
    python tools/clean_stray_px.py data/RADBOLT2.IMG RNVICBOLT --apply    # write
    python tools/clean_stray_px.py data/RADBOLT2.IMG RNVICBOLT --check    # CI gate
"""
import argparse
import shutil
import struct
import sys
from collections import deque
from pathlib import Path

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")


def cstr(b):
    return b.split(b"\0", 1)[0].decode("latin-1", errors="replace")


def _plausible(raw):
    n = raw.split(b"\0", 1)[0]
    return bool(n) and all(32 <= c < 127 for c in n)


def load_frames(data):
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    best = None
    for istart in (oset, oset + palcnt * PALETTE.size):
        score = sum(
            1
            for i in range(imgcnt)
            if _plausible(data[istart + i * IMAGE.size:istart + i * IMAGE.size + 16])
        )
        if best is None or score > best[0]:
            best = (score, istart)
    istart = best[1]
    frames = []
    for i in range(imgcnt):
        rec = IMAGE.unpack_from(data, istart + i * IMAGE.size)
        frames.append(dict(idx=i, name=cstr(rec[0]), w=rec[4], h=rec[5], o=rec[7]))
    return frames


def stride_of(w):
    return (w + 3) // 4 * 4


def find_strays(data, f, max_cluster):
    w, h, o = f["w"], f["h"], f["o"]
    st = stride_of(w)
    rows = [list(data[o + y * st:o + y * st + w]) for y in range(h)]
    seen = [[False] * w for _ in range(h)]
    strays = []
    for y in range(h):
        for x in range(w):
            if rows[y][x] == 0 or seen[y][x]:
                continue
            q, comp = deque([(x, y)]), []
            seen[y][x] = True
            while q:
                cx, cy = q.popleft()
                comp.append((cx, cy))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and rows[ny][nx]:
                            seen[ny][nx] = True
                            q.append((nx, ny))
            if len(comp) <= max_cluster:
                strays.append(comp)
    return strays


def overlap_guard(frames):
    """Refuse to write if any two frames share pixel bytes."""
    spans = sorted(
        ((f["o"], f["o"] + stride_of(f["w"]) * f["h"], f["name"]) for f in frames if f["h"]),
        key=lambda s: s[0],
    )
    for (a0, a1, an), (b0, b1, bn) in zip(spans, spans[1:]):
        if b0 < a1:
            return f"{an} ({a0:#x}..{a1:#x}) overlaps {bn} ({b0:#x}..{b1:#x})"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("img")
    ap.add_argument("prefix", help="frame-name prefix, e.g. RNVICBOLT")
    ap.add_argument("--max-cluster", type=int, default=4)
    ap.add_argument("--apply", action="store_true", help="write the cleaned IMG")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any stray remains (drift gate)")
    args = ap.parse_args()

    path = Path(args.img)
    data = bytearray(path.read_bytes())
    frames = load_frames(data)
    targets = [f for f in frames if f["name"].upper().startswith(args.prefix.upper())]
    if not targets:
        print(f"no frames match prefix {args.prefix!r} in {path.name}")
        return 1

    bad = overlap_guard(frames)
    if bad and args.apply:
        print(f"REFUSING to write: frame pixel spans overlap - {bad}")
        return 2

    total_clusters = total_px = 0
    for f in targets:
        strays = find_strays(data, f, args.max_cluster)
        if not strays:
            continue
        npx = sum(len(c) for c in strays)
        total_clusters += len(strays)
        total_px += npx
        print(f"{f['name']:<16} {f['w']:>3}x{f['h']:<3} strays={len(strays):<3} px={npx}")
        if args.apply:
            st = stride_of(f["w"])
            for comp in strays:
                for x, y in comp:
                    data[f["o"] + y * st + x] = 0

    print(f"\n{path.name} [{args.prefix}*]: {total_clusters} stray clusters, "
          f"{total_px} pixels (<= {args.max_cluster}px each)")

    if args.check:
        if total_clusters:
            print("CHECK FAILED: strays present")
            return 1
        print("CHECK OK: no strays")
        return 0

    if args.apply and total_clusters:
        backup = path.with_suffix(path.suffix + ".straybak")
        if not backup.exists():
            shutil.copy2(path, backup)
            print(f"backup -> {backup.name}")
        path.write_bytes(bytes(data))
        print(f"cleaned {path.name}")
    elif args.apply:
        print("nothing to do")
    return 0


if __name__ == "__main__":
    sys.exit(main())
