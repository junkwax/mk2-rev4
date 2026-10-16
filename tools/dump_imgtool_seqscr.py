#!/usr/bin/env python3
"""Dump the IMGTOOL sequence-editor (seqscr) records an .IMG carries.

    python tools/dump_imgtool_seqscr.py data/TIGER3.IMG [NAME]

Format, as established in doc/KINTARO_GETUP_KICK.md: after the image table an
IMG can carry sequence-editor records - a 16-byte name, a second string,
`40 00`, a u16 frame count, 15 dwords of dead editor pointers, a
`0a00 0a00 ffffffffffff` trailer, then the frame list at an 18-byte stride
starting at count+0x52.  Each entry is `u16 zero, u16 image index, u8 hold, u8 junk`.

TWO TRAPS, both from that write-up:
  * the junk byte is uninitialised editor state, NOT a second timing field;
  * the list is stored NEWEST-FIRST, so it plays in reverse file order.  The
    check is that STOMP then reads TIGERJUMP1,2,3,4 ascending, which is what
    a_goro_stomp (src/MKGORO.ASM) already plays.
"""
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import imgdump  # noqa: E402

TRAILER = bytes.fromhex("0a000a00ffffffffffff")


def image_names(data):
    imgcnt, palcnt, oset = struct.unpack_from("<HHI", data, 0)
    _, img_start, _ = imgdump.detect_record_layout(data, oset, imgcnt, palcnt)
    return [imgdump.cstr(imgdump.IMAGE.unpack_from(data, img_start + i * imgdump.IMAGE.size)[0])
            for i in range(imgcnt)]


def records(data, names):
    """every seqscr record: (name, offset, [(image, hold), ...]) in PLAY order

    Anchored on the `40 00` at name+0x10, with the count right behind it and
    the frame list at name+0x64 on an 18-byte stride.
    """
    out = []
    for m in re.finditer(re.escape(bytes([0x40, 0x00])), data):
        nm_off = m.start() - 0x10
        if nm_off < 0:
            continue
        raw = data[nm_off:nm_off + 16]
        if not raw[:1].isalpha():
            continue
        if data[nm_off + 0x50:nm_off + 0x5e] != bytes.fromhex("000000000a000a00ffffffffffff"):
            continue
        cnt = struct.unpack_from("<H", data, nm_off + 0x12)[0]
        if not 1 <= cnt <= 64:
            continue
        base = nm_off + 0x64
        frames, ok = [], True
        for i in range(cnt):
            # entry: u16 (0), u16 image index, u8 hold, u8 editor junk
            idx, hold = struct.unpack_from("<HB", data, base + i * 18 + 2)
            if not 0 <= idx < len(names):
                ok = False
                break
            frames.append((names[idx], hold))
        if ok:
            out.append((imgdump.cstr(raw), nm_off, frames[::-1]))
    return out


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "data" / "TIGER3.IMG"
    want = sys.argv[2].upper() if len(sys.argv) > 2 else None
    data = path.read_bytes()
    names = image_names(data)
    for nm, off, frames in records(data, names):
        if want and want not in nm.upper():
            continue
        print(f"== {nm or '(unnamed)'}  @{off:#x}  {len(frames)} frames")
        print("   " + " ".join(f"{n}[{h:02x}]" for n, h in frames))


if __name__ == "__main__":
    main()
