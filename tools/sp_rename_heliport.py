#!/usr/bin/env python3
"""Rename the Baraka heliport records inside the *SP.IMG working copies.

data/UGMO4SP.IMG, UGMO7SP.IMG and UGMO9SP.IMG are IMGTOOL working copies of
UGMO4/UGMO7/UGMO9 that exist ONLY to feed data/SAHELI.LOD + SAHELI2.LOD - the
Up,Up+LK heliport sequence.  Their pixels are identical to the shipping
libraries; what differs is the anipoints, which are where the whole World View
lane's placement lives.

Seven of the frames the lane uses keep their original names in those copies,
and those names are already taken in src/: MKSA.ASM defines multipart wrappers
called UGVICTORY1, UGFLIPPED3, UGHIKICK3, UGKNOCKDOWN1/2/3 and UGSTANCE1 over
the stock A/B/C strips.  LOAD2 emits a table label named after the IMG record
(load2.c writes animg->name straight into the .TBL) and has no rename syntax -
`:' on a ---> entry is a start-column selector and `*' is a copy count - so
loading them under their own names would collide at assembly time.

This renames them in place, in the SP copies only.  The shipping UGMO4/UGMO7/
UGMO9 libraries are never touched.  Re-run it after re-exporting any of the SP
files from IMGTOOL, or LOAD2 will report "Couldn't find image".

    python tools/sp_rename_heliport.py            # rename
    python tools/sp_rename_heliport.py --check    # non-zero if any are missing
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# file -> {original name: heliport name}.  SAH = Sword Arms HELIport.
RENAMES = {
    "UGMO9SP.IMG": {"UGVICTORY1": "SAHVICTORY1", "UGSTANCE1": "SAHSTANCE1"},
    # UGFLIPPED1/2/4 joined the lane when it was re-authored in
    # data/barakadown3.wvp (the crash-in and the two flipX+flipY tumble
    # frames).  Same collision as the rest: MKSA.ASM already defines stock
    # multipart wrappers called UGFLIPPED1, UGFLIPPED2 and UGFLIPPED4.
    "UGMO7SP.IMG": {"UGFLIPPED3": "SAHFLIPPED3", "UGKNOCKDOWN3": "SAHKNOCK3",
                    "UGKNOCKDOWN2": "SAHKNOCK2", "UGKNOCKDOWN1": "SAHKNOCK1",
                    "UGFLIPPED1": "SAHFLIPPED1", "UGFLIPPED2": "SAHFLIPPED2",
                    "UGFLIPPED4": "SAHFLIPPED4"},
    "UGMO4SP.IMG": {"UGHIKICK3": "SAHHIKICK3"},
}


def records(data):
    imgcnt, _palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    for i in range(imgcnt):
        off = oset + i * IMAGE.size
        raw = data[off:off + 16]
        yield off, raw.split(b"\0", 1)[0].decode("latin-1")


def main():
    check = "--check" in sys.argv[1:]
    problems = []
    for fname, table in RENAMES.items():
        path = ROOT / "data" / fname
        if not path.exists():
            problems.append(f"{fname}: missing")
            continue
        data = bytearray(path.read_bytes())
        found = {new: False for new in table.values()}
        changed = 0
        for off, name in records(bytes(data)):
            if name in table:
                new = table[name]
                data[off:off + 16] = new.encode("ascii").ljust(16, b"\0")
                found[new] = True
                changed += 1
            elif name in found:
                found[name] = True
        missing = [n for n, ok in found.items() if not ok]
        if missing:
            problems.append(f"{fname}: no record for {', '.join(sorted(missing))}")
            continue
        if changed and not check:
            path.write_bytes(bytes(data))
            print(f"{fname}: renamed {changed} record(s)")
        elif changed and check:
            problems.append(f"{fname}: {changed} record(s) still under stock names")
        else:
            print(f"{fname}: already renamed")
    for p in problems:
        print(f"ERROR: {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
