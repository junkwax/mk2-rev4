#!/usr/bin/env python3
"""Read/edit animation points in a Midway IMG, and sync them into a .TBL.

The anipoint is the anchor every drawn sprite hangs off: the display puts the
art at (anchor - anix_eff), where anix_eff is `anix` normally and
`sizex-1-anix` when the object is h-flipped.  So the art mirrors about the
anipoint whenever the facing changes.  An anipoint in the wrong place cannot
be corrected with a constant in the game code - a constant that centres the
art one way throws it 2*dx the other way.  Fix it in the art.

Struct layout matches imgdump.py (doc/it/wmpstruc.inc): IMAGE records are 50
bytes, anix at +16h and aniy at +18h, both little-endian int16.

Usage:
    python img_anipoint.py list data/MK1SKULL.IMG
    python img_anipoint.py list data/MK1SKULL.IMG --name MK1FIRE
    python img_anipoint.py shift data/MK1SKULL.IMG --name MK1FIRE --dx 143
    python img_anipoint.py shift data/MK1SKULL.IMG --name MK1SKEL --dx -40
    python img_anipoint.py set data/MK1SKULL.IMG --name MK1FIRE1 --x 75
    python img_anipoint.py sync-tbl data/MK1SKULL.IMG src/MK1SKULL.TBL
    python img_anipoint.py sync-tbl data/MK1SKULL.IMG src/MK1SKULL.TBL --check

`shift`/`set` write a one-time .bak beside the IMG.  `sync-tbl --check` exits
non-zero if the TBL's anix/aniy have drifted from the IMG, which is the whole
point of keeping the IMG authoritative - nothing in build.py promotes a
hand-maintained sidecar TBL, so drift is otherwise silent.
"""
import argparse
import re
import struct
import sys
from pathlib import Path

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
assert (LIB_HDR.size, PALETTE.size, IMAGE.size) == (28, 26, 50)

ANIX_OFF = 18  # 16-byte name + 2-byte flags
ANIY_OFF = 20


def s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def cstr(b: bytes) -> str:
    return b.split(b"\0", 1)[0].decode("latin-1", errors="replace")


def _plausible_name(raw: bytes) -> bool:
    name = raw.split(b"\0", 1)[0]
    return bool(name) and all(32 <= ch < 127 for ch in name)


def records(data: bytes):
    """Yield (index, name, file_offset, anix, aniy, w, h) for every IMAGE."""
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    # Libraries write IMAGE-first or PALETTE-first; score both for real names.
    best = None
    for img_start in (oset, oset + palcnt * PALETTE.size):
        score = sum(
            _plausible_name(data[img_start + i * IMAGE.size:][:16])
            for i in range(imgcnt)
            if img_start + (i + 1) * IMAGE.size <= len(data)
        )
        if best is None or score > best[0]:
            best = (score, img_start)
    if not best[0]:
        raise SystemExit("could not locate IMG record table")
    img_start = best[1]

    for i in range(imgcnt):
        off = img_start + i * IMAGE.size
        if off + IMAGE.size > len(data):
            break
        name, _flags, anix, aniy, w, h = IMAGE.unpack_from(data, off)[:6]
        yield i, cstr(name), off, s16(anix), s16(aniy), w, h


def matching(data: bytes, pattern: str | None):
    for rec in records(data):
        if pattern is None or pattern.upper() in rec[1].upper():
            yield rec


def cmd_list(args) -> int:
    data = Path(args.img).read_bytes()
    print(f"{'idx':>4} {'name':<16} {'W':>4} {'H':>4} {'anix':>6} {'aniy':>6}")
    print("-" * 46)
    for i, name, _off, anix, aniy, w, h in matching(data, args.name):
        print(f"{i:>4} {name:<16} {w:>4} {h:>4} {anix:>6} {aniy:>6}")
    return 0


def _write(path: Path, data: bytearray, dry_run: bool) -> None:
    if dry_run:
        print("(dry run - nothing written)")
        return
    bak = path.with_suffix(path.suffix + ".bak")
    if not bak.exists():
        bak.write_bytes(path.read_bytes())
        print(f"backup -> {bak}")
    path.write_bytes(bytes(data))
    print(f"wrote {path}")


def cmd_edit(args) -> int:
    path = Path(args.img)
    data = bytearray(path.read_bytes())
    hits = list(matching(bytes(data), args.name))
    if not hits:
        print(f"no records match {args.name!r}", file=sys.stderr)
        return 1

    for _i, name, off, anix, aniy, _w, _h in hits:
        if args.cmd == "shift":
            nx, ny = anix + args.dx, aniy + args.dy
        else:
            nx = args.x if args.x is not None else anix
            ny = args.y if args.y is not None else aniy
        struct.pack_into("<h", data, off + ANIX_OFF, nx)
        struct.pack_into("<h", data, off + ANIY_OFF, ny)
        print(f"  {name:<16} anix {anix:>5} -> {nx:<5}  aniy {aniy:>5} -> {ny}")

    _write(path, data, args.dry_run)
    return 0


# A TBL record is `NAME:` followed by `.word sizex,sizey,anix,aniy`.
TBL_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$")
TBL_WORD = re.compile(r"^(\s*\.word\s+)(-?\d+),(-?\d+),(-?\d+),(-?\d+)(\s*.*)$")


# LOAD2 clamps a cut sprite's WIDTH up to 3 when the art is narrower; the
# height is never touched. Confirmed on two unrelated IMGs: all 17 SHAOFIST
# size "mismatches" are IMG width 1 or 2 against TBL width 3 with equal
# heights, and BOSS5.IMG's 1x1 DOT is `.word 3,1` in MKSK.TBL. So a table
# that says 3 where the IMG says 1 is not drift, it is the clamp, and the
# table is right. Anything else is a genuine RE-CUT: the SAG follows the new
# pixels while W/H still describe the old ones, which draws the sprite at the
# wrong size from the right address - streaks and torn rows.
LOAD2_MIN_WIDTH = 3


def _tbl_size_ok(sx, sy, want_w, want_h) -> bool:
    return sy == want_h and sx == max(want_w, LOAD2_MIN_WIDTH)


def cmd_sync_tbl(args) -> int:
    img = {name: (anix, aniy, w, h)
           for _i, name, _off, anix, aniy, w, h in records(Path(args.img).read_bytes())}

    # --only restricts the comparison to named records. Needed when part of a
    # TBL is authored in the IMG and part is deliberately re-derived in the
    # source table - JADERANG is the first: BRANG1-3 are a release path whose
    # IMG anipoints ARE the placement, while BRANG4-9 loop, and a looping
    # sequence cannot carry net world motion. Without this the whole table
    # would have to go unchecked to keep the half that matters honest.
    if args.only:
        keep = {n.strip().upper() for n in args.only.split(",") if n.strip()}
        unknown = keep - set(img)
        if unknown:
            print(f"error: --only names not in {args.img}: "
                  f"{', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        img = {n: v for n, v in img.items() if n in keep}

    tbl_path = Path(args.tbl)
    lines = tbl_path.read_text().splitlines(keepends=True)
    out, drift, missing, recut, label = [], [], [], [], None

    for line in lines:
        m = TBL_LABEL.match(line.rstrip("\n"))
        if m:
            label = m.group(1)
            out.append(line)
            continue
        w_m = TBL_WORD.match(line.rstrip("\n"))
        if w_m and label is not None:
            sx, sy, anix, aniy = (int(w_m.group(i)) for i in range(2, 6))
            rec = img.get(label)
            if rec is None:
                missing.append(label)
            else:
                want_x, want_y, want_w, want_h = rec
                fit_w, fit_h = max(want_w, LOAD2_MIN_WIDTH), want_h
                size_ok = _tbl_size_ok(sx, sy, want_w, want_h)
                if not size_ok and not args.resize:
                    print(f"!! {label}: TBL size {sx}x{sy} != IMG {want_w}x{want_h}"
                          f" - refusing to touch this record (pass --resize if"
                          f" the art was RE-CUT and the table should follow)",
                          file=sys.stderr)
                    recut.append(label)
                elif not size_ok or (anix, aniy) != (want_x, want_y):
                    if not size_ok:
                        recut.append(label)
                    if (anix, aniy) != (want_x, want_y):
                        drift.append((label, anix, aniy, want_x, want_y))
                    line = (f"{w_m.group(1)}{fit_w},{fit_h},{want_x},{want_y}"
                            f"{w_m.group(6)}\n")
            label = None
        out.append(line)

    for label, ax, ay, wx, wy in drift:
        print(f"  {label:<16} anix {ax:>5} -> {wx:<5}  aniy {ay:>5} -> {wy}")
    if missing and not args.only:
        print(f"  ({len(missing)} TBL record(s) not in the IMG: "
              f"{', '.join(missing[:6])}{'...' if len(missing) > 6 else ''})")

    if recut:
        print(f"  ({len(recut)} record(s) RE-CUT: "
              f"{', '.join(recut[:6])}{'...' if len(recut) > 6 else ''})")
    if args.check:
        if drift or recut:
            print(f"DRIFT: {tbl_path} disagrees with {args.img} "
                  f"on {len(drift)} anipoint(s)", file=sys.stderr)
            return 1
        print(f"OK: {tbl_path} anipoints match {args.img}")
        return 0

    if not drift and not recut:
        print(f"OK: {tbl_path} already matches {args.img}")
        return 0
    _write(tbl_path, bytearray("".join(out).encode()), args.dry_run)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="print anipoints")
    p.add_argument("img")
    p.add_argument("--name", help="substring filter")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("shift", help="add a delta to matching anipoints")
    p.add_argument("img")
    p.add_argument("--name", required=True, help="substring filter")
    p.add_argument("--dx", type=int, default=0)
    p.add_argument("--dy", type=int, default=0)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_edit)

    p = sub.add_parser("set", help="set matching anipoints outright")
    p.add_argument("img")
    p.add_argument("--name", required=True, help="substring filter")
    p.add_argument("--x", type=int)
    p.add_argument("--y", type=int)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_edit)

    p = sub.add_parser("sync-tbl", help="copy IMG anipoints into a .TBL by name")
    p.add_argument("img")
    p.add_argument("tbl")
    p.add_argument("--check", action="store_true", help="report drift, write nothing")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--only", metavar="NAME[,NAME...]",
                   help="restrict to these records (rest of the TBL is left alone)")
    p.add_argument("--resize", action="store_true",
                   help="also rewrite W,H when the art was re-cut (default is "
                        "to refuse those records - a wrong size draws streaks)")
    p.set_defaults(func=cmd_sync_tbl)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
