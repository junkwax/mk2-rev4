#!/usr/bin/env python3
"""Dump the SEQSCR (authored animation sequences) out of a Midway IMG.

The ASM frame list in src/*.ASM does NOT tell you which rows an artist
authored, or how long each is held.  That lives in a sequence pool at the tail
of the .IMG, past the IMAGE/PALETTE records.  Read it before re-framing or
retiming any move.

Layout (matches midway-imgtool's img_io.cpp / wmpstruc.h, not a guess):
  - LIB_HDR carries version / seqcnt / scrcnt.
  - The pool follows oset + imgcnt*50 + (palcnt-3)*26.  palcnt counts the three
    default palettes that are NEVER on disk, so only palcnt-3 records are
    there - adding all of palcnt walks 78 bytes past the first record, which is
    why this tool used to skip it (UPPER CUT in TIGER4.IMG, BLOODA1 in
    RBLOOD.IMG).
  - A record is 98 bytes and an ENTRY 18 for version >= 0x634 (the far-pointer
    model); 58 / 16 below that.
  - In a record: name at +0 (16 bytes), flags at +16 (0x40 = a sequence),
    num at +18, startx/starty at +84/+86, damage table at +88.
  - In an ENTRY (far): target index at +4, ticks at +6, dX/dY at +8/+10.
  - SEQUENCE entries are stored in REVERSE playback order; SCRIPT entries run
    forward, and index sequences rather than images.
  - Sequences come first in the pool, then scripts.

Usage:
    python tools/imgseq.py data/HATHED2.IMG              # list sequences
    python tools/imgseq.py data/NUJAX5.IMG JUMPPRO       # one sequence
"""
import struct
import sys
from pathlib import Path

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
SEQFLG = 0x40
NUM_DEF_PAL = 3


def _plausible(raw):
    n = raw.split(b"\0", 1)[0]
    return bool(n) and all(32 <= c < 127 for c in n)


def load(path):
    data = path.read_bytes()
    imgcnt, palcnt, oset, version, seqcnt, scrcnt = LIB_HDR.unpack_from(data, 0)[:6]
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
    names = {}
    for i in range(imgcnt):
        rec = IMAGE.unpack_from(data, istart + i * IMAGE.size)
        names[i] = rec[0].split(b"\0", 1)[0].decode("latin-1")
    pool = oset + imgcnt * IMAGE.size
    if palcnt > NUM_DEF_PAL:
        pool += (palcnt - NUM_DEF_PAL) * PALETTE.size
    far = version >= 0x634
    return dict(data=data, names=names, pool=pool, imgcnt=imgcnt,
                seqcnt=seqcnt, scrcnt=scrcnt, version=version,
                rec_size=98 if far else 58, entry_size=18 if far else 16,
                index_at=4 if far else 2, ticks_at=6 if far else 4)


def records(lib):
    """Every SEQSCR record, in pool order, with its entries decoded."""
    data, out = lib["data"], []
    off = lib["pool"]
    for i in range(lib["seqcnt"] + lib["scrcnt"]):
        if off + lib["rec_size"] > len(data):
            break
        name = data[off:off + 16].split(b"\0", 1)[0].decode("latin-1").strip()
        flags, num = struct.unpack_from("<HH", data, off + 16)
        script = i >= lib["seqcnt"]
        rows = []
        for e in range(num):
            eo = off + lib["rec_size"] + e * lib["entry_size"]
            if eo + lib["entry_size"] > len(data):
                break
            idx = struct.unpack_from("<h", data, eo + lib["index_at"])[0]
            rows.append((eo, idx, data[eo + lib["ticks_at"]]))
        if not script:
            rows.reverse()          # sequences are stored back to front
        out.append(dict(offset=off, name=name, flags=flags, script=script,
                        rows=rows))
        off += lib["rec_size"] + num * lib["entry_size"]
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = Path(sys.argv[1])
    want = sys.argv[2].upper() if len(sys.argv) > 2 else None
    lib = load(path)
    recs = records(lib)
    seq_names = {i: r["name"] for i, r in enumerate(recs) if not r["script"]}
    print("=== %s === version %#06x seqcnt=%d scrcnt=%d pool=%#x"
          % (path.name, lib["version"], lib["seqcnt"], lib["scrcnt"],
             lib["pool"]))
    for rec in recs:
        if want and rec["name"].upper() != want:
            continue
        total = sum(t for _, _, t in rec["rows"])
        print("\n%s  %s  (%d rows, %d ticks)  @%#x"
              % (rec["name"], "script" if rec["script"] else "sequence",
                 len(rec["rows"]), total, rec["offset"]))
        for _, idx, ticks in rec["rows"]:
            label = (seq_names.get(idx, "seq[%d]?" % idx) if rec["script"]
                     else lib["names"].get(idx, "?"))
            print("    %-18s %3d tick(s)" % (label, ticks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
