"""Put Kintaro's stomp art back to the size Midway drew it.

`a_goro_stomp` is TIGERJUMP1-6, and the game draws the A-D STRIPS of each
frame, not the composites.  In this tree the strips of frames 1-4 are SMALLER
than retail's - 0.8 on frames 1-3, 0.64 on frame 4 - while frames 5 and 6 are
retail to the byte:

    TIGERJUMP1B   38x93   retail 48x117
    TIGERJUMP4B   22x91   retail 34x143
    TIGERJUMP5B   34x124  retail 34x124   <- untouched

They were shrunk when SMTIGERJUMP1-4 (the small Kahn's Arena prop that leaps
out of the stands, data/SMTIGER.LOD) was authored into the same IMG: the prop
art is 0.8 of the stomp, and the shrunken copies landed on the stomp's own
strip records.  Nothing caught it because a_goro_stomp is hard to reach in a
normal fight, and src/MKGORO.TBL was later re-cut to match the shrunken art,
so every piece of metadata agreed with every other.

What the player saw: a Kintaro two thirds his fight size dropping onto Shang
Tsung at the end of the soul escape, and the same in the in-fight stomp.

This restores the 15 strips - pixels AND geometry - out of the pristine copy
of the leaked source, and leaves everything else in TIGER3.IMG alone,
SMTIGERJUMP included.  The retail pixels are appended at the end of the file
and the records repointed, because they no longer fit where they sat; nothing
else in the file moves.

    python tools/restore_tigerjump.py            # restore (idempotent)
    python tools/restore_tigerjump.py --check    # Phase D: still retail?

The restored strips are bigger, so MK4MIL cannot hold all of them any more -
data/TIGJMP1-5.LOD carry the overflow.  See doc/KINTARO_STOMP_ART.md.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OURS = ROOT / "data" / "TIGER3.IMG"
RETAIL = Path(r"C:\Users\you\Workplace\mk2-readonly\mk2-main\data\TIGER3.IMG")

IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
LIB_HDR = struct.Struct("<HHI")

STRIPS = [f"TIGERJUMP{f}{c}"
          for f, cols in ((1, "ABCD"), (2, "ABC"), (3, "ABCD"), (4, "ABCD"))
          for c in cols]


def records(data: bytes) -> dict[str, tuple[int, tuple]]:
    imgcnt, _palcnt, oset = LIB_HDR.unpack_from(data, 0)
    out = {}
    for i in range(imgcnt):
        off = oset + i * IMAGE.size
        rec = IMAGE.unpack_from(data, off)
        name = rec[0].split(b"\0", 1)[0].decode("latin-1")
        out[name] = (off, rec)
    return out


def pixels(data: bytes, rec: tuple) -> list[bytes]:
    w, h, o = rec[4], rec[5], rec[7]
    stride = (w + 3) & ~3
    return [data[o + y * stride:o + y * stride + w] for y in range(h)]


def restore(check: bool) -> int:
    if not RETAIL.exists():
        print(f"missing the read-only retail tree: {RETAIL}")
        return 2
    ours, retail = OURS.read_bytes(), RETAIL.read_bytes()
    r_ours, r_ret = records(ours), records(retail)

    stale = []
    for name in STRIPS:
        if name not in r_ours or name not in r_ret:
            print(f"{name}: missing from one of the IMGs")
            return 2
        o_rec, t_rec = r_ours[name][1], r_ret[name][1]
        same_geom = o_rec[2:6] == t_rec[2:6]          # anix, aniy, w, h
        if not (same_geom and pixels(ours, o_rec) == pixels(retail, t_rec)):
            stale.append(name)

    if check:
        if stale:
            print("TIGERJUMP strips are NOT Midway's art: " + ", ".join(stale))
            print("run: python tools/restore_tigerjump.py")
            return 1
        print(f"restore_tigerjump: {len(STRIPS)} strips match retail OK")
        return 0

    if not stale:
        print(f"restore_tigerjump: {len(STRIPS)} strips already match retail")
        return 0

    out = bytearray(ours)
    for name in STRIPS:
        off, o_rec = r_ours[name]
        t_rec = r_ret[name][1]
        w, h = t_rec[4], t_rec[5]
        stride = (w + 3) & ~3
        blob = bytearray()
        for row in pixels(retail, t_rec):
            blob += row + bytes(stride - w)
        where = len(out)                       # append: nothing else moves
        out += blob
        new = list(o_rec)
        new[2], new[3], new[4], new[5] = t_rec[2], t_rec[3], w, h
        new[7] = where
        IMAGE.pack_into(out, off, *new)
        print(f"  {name:<13} {o_rec[4]}x{o_rec[5]} -> {w}x{h}  at {where:#x}")

    OURS.write_bytes(bytes(out))
    print(f"restore_tigerjump: restored {len(stale)} strip(s); "
          f"{OURS.name} {len(ours)} -> {len(out)} bytes")
    print("now rebuild from Phase A (LOAD2 repacks MK4MIL + TIGJMP1-5)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify only; non-zero exit if the art is not retail's")
    args = ap.parse_args()
    return restore(args.check)


if __name__ == "__main__":
    raise SystemExit(main())
