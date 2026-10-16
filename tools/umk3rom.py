#!/usr/bin/env python3
r"""Read the UMK3 arcade ROM (C:\MAME\roms\umk3.zip) the way tools/make_mk1pit.py's
MK1 class reads mk.zip: the program ROM as one flat megabyte at FF800000h
(u54 even bytes, u63 odd), and the image ROM as MAME's umk3 driver lays it out -
four chips a 4 MB block, byte-interleaved lane by lane:

    0 MB  u133 u132 u131 u130      12 MB  umk-u121 .. u118
    4 MB  u129 u128 u127 u126      20 MB  umk-u113 .. u110
    8 MB  u125 u124 u123 u122

(the order makewolf.py writes ours in).  A SAG is a bit address, so the byte is
SAG >> 3 - the same for every bank, which is what make_mk3cave.sag_phys does
too.  Records decode with make_mk1pit.decode_record (same DMA format).
"""
from __future__ import annotations

import struct
import zipfile
from pathlib import Path

ROM_ZIP = Path("C:/MAME/roms/umk3.zip")
BASE = 0xFF800000
CHIP = 0x100000
BLOCKS = [(0x000000, ("u133", "u132", "u131", "u130")),
          (0x400000, ("u129", "u128", "u127", "u126")),
          (0x800000, ("u125", "u124", "u123", "u122")),
          (0xC00000, ("umk-u121", "umk-u120", "umk-u119", "umk-u118")),
          (0x1400000, ("umk-u113", "umk-u112", "umk-u111", "umk-u110"))]


class UMK3:
    def __init__(self, path: Path = ROM_ZIP):
        if not path.exists():
            raise SystemExit(f"{path} missing - UMK3 (MAME `umk3`) is the source")
        with zipfile.ZipFile(path) as z:
            names = z.namelist()

            def member(tag):
                for n in names:
                    if n.endswith("." + tag) or n.endswith(tag + ".bin") or n.endswith("_" + tag):
                        return z.read(n)
                raise SystemExit(f"{path}: no member for {tag}")

            ev, od = member("u54"), member("u63")
            p = bytearray(len(ev) * 2)
            p[0::2], p[1::2] = ev, od
            self.p = bytes(p)
            g = bytearray(b"\xff" * 0x1800000)
            for base, chips in BLOCKS:
                for lane, tag in enumerate(chips):
                    data = member(tag)
                    g[base + lane:base + 4 * CHIP:4] = data
            self.g = bytes(g)

    def o(self, bit):
        return (bit - BASE) // 8

    def w(self, bit):
        return struct.unpack_from("<H", self.p, self.o(bit))[0]

    def sw(self, bit):
        return struct.unpack_from("<h", self.p, self.o(bit))[0]

    def l(self, bit):
        return struct.unpack_from("<I", self.p, self.o(bit))[0]

    def palette(self, bit):
        n = self.w(bit)
        if not 1 <= n <= 256:
            raise SystemExit(f"UMK3 {bit:08X}: not a palette")
        return [self.w(bit + 16 * (i + 1)) for i in range(n)]

    def find_long(self, v):
        pat, out = struct.pack("<I", v), []
        i = self.p.find(pat)
        while i >= 0:
            if i % 2 == 0:
                out.append(BASE + i * 8)
            i = self.p.find(pat, i + 1)
        return out
