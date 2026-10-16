#!/usr/bin/env python3
"""Check every cross-object PC-relative branch actually reaches its target.

A `callr` or a long `jr`/`jruc` to a symbol in ANOTHER object carries a 16-bit
signed displacement in WORDS (-32768..32767, about +/-64KB).  GSPLNK does not
check that the linked distance fits: when it does not, it silently keeps the
low 16 bits and the branch lands ~64KB away.  That was the intermittent Dead
Pool TRAP 30 - MKDRONE's `callr check_block_bit` (JOY.ASM) needed -32838 words,
was linked as +32698, and landed mid-instruction in MKHANG's code.  Code only
grows, so this recurs silently; CLAUDE.md already records two earlier cases.

This is exact, not a source heuristic.  Every object file records a relocation
for each external reference, and GSPA's type 25 is the 16-bit PC-relative
one.  (Type 24 looks similar and is NOT a branch: it is a complemented 32-bit
immediate, the operand of `cmpi`, which is why it targets RAM variables.  A
first version counted it and reported 27 impossible "branches".)  The opcode
in front of every type-25 site is read out of the object file and must be a
relative branch or call, so a misclassified relocation fails loudly instead
of passing quietly.  The linker map gives each object's final .text base.
For every such relocation:

    site      = object .text base + relocation offset   (the displacement word)
    pc_after  = site + 16                                (end of the instruction)
    needed    = (symbol address - pc_after) / 16         (words)

and it fails if `needed` is outside -32768..32767.  Given --rom it also reads
the word the linker actually wrote and reports where the branch really lands,
so a failure names the address the CPU would jump to.

    python tools/check_pcrel_range.py            # report
    python tools/check_pcrel_range.py --check    # Phase D: exit 1 on any overflow
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PCREL_TYPES = {25}

def is_relative_branch(op):
    """CALLR, or a long-form JRcc/JRUC (low byte 00 selects the 16-bit form)."""
    return op == 0x0D3F or ((op & 0xF000) == 0xC000 and (op & 0x00FF) == 0)
RELOC_SIZE = 10
SYM_SIZE = 18
ROM_BASE = 0xFF800000


def read_map(path):
    text = path.read_text(errors="replace")
    bases = {}
    for m in re.finditer(r"^\s+([0-9a-f]{8})\s+([0-9a-f]{8})\s+(\S+\.OBJ)\s+\(\.text\)", text, re.M | re.I):
        bases[m.group(3).upper()] = (int(m.group(1), 16), int(m.group(2), 16))
    syms = {}
    for addr, name in re.findall(r"([0-9a-f]{8})\s+([A-Za-z_][\w$.]*)", text):
        syms.setdefault(name, int(addr, 16))
    # Output SECTIONS are branch targets too - MKDISP does `jruc SHADORG` - and
    # the map lists them in its allocation table, not among the symbols.
    for m in re.finditer(r"^([A-Za-z_.]\w*)\s+\d+\s+([0-9a-f]{8})\s+[0-9a-f]{8}", text, re.M):
        syms.setdefault(m.group(1), int(m.group(2), 16))
    return bases, syms


def read_obj(path):
    d = path.read_bytes()
    _magic, nsec, _ts, symptr, nsyms, opthdr, _flags = struct.unpack_from("<HHiiiHH", d, 0)
    strtab = symptr + nsyms * SYM_SIZE
    names = {}
    i = 0
    while i < nsyms:
        raw = d[symptr + i * SYM_SIZE: symptr + (i + 1) * SYM_SIZE]
        if raw[:4] == b"\0\0\0\0":
            so = struct.unpack_from("<i", raw, 4)[0]
            end = d.index(b"\0", strtab + so)
            name = d[strtab + so:end].decode("latin-1")
        else:
            name = raw[:8].rstrip(b"\0").decode("latin-1")
        naux = raw[17]
        names[i] = name
        i += 1 + naux
    relocs = []
    off = 20 + opthdr
    for _ in range(nsec):
        sname = d[off:off + 8].rstrip(b"\0").decode("latin-1")
        _p, _v, _size, _scn, relptr, _ln, nreloc, _nl, _fl = struct.unpack_from("<iiiiiiHHi", d, off + 8)
        if sname == ".text":
            for k in range(nreloc):
                vaddr, symndx, rtype = struct.unpack_from("<iiH", d, relptr + k * RELOC_SIZE)
                if rtype in PCREL_TYPES:
                    op = struct.unpack_from("<H", d, _scn + (vaddr - 16) // 8)[0]
                    relocs.append((vaddr, names.get(symndx, "?"), rtype, op))
        off += 40
    return relocs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", type=Path, default=ROOT / "src/mk2.map")
    ap.add_argument("--rom", type=Path, default=None,
                    help="flat program ROM, only to report where a bad branch lands "
                         "(Phase D runs before makerom, so it is not the default)")
    ap.add_argument("--src", type=Path, default=ROOT / "src")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    bases, syms = read_map(args.map)
    rom = args.rom.read_bytes() if args.rom and args.rom.exists() else None
    checked, bad, unresolved, odd = 0, [], [], []
    for obj in sorted(args.src.glob("*.OBJ")):
        base = bases.get(obj.name.upper())
        if base is None:
            continue                      # not linked into this image
        for vaddr, name, rtype, op in read_obj(obj):
            if not is_relative_branch(op):
                odd.append((obj.name, vaddr, name, op))
                continue
            if name not in syms:
                unresolved.append((obj.name, vaddr, name))
                continue
            site = base[0] + vaddr
            pc_after = site + 16
            delta = syms[name] - pc_after
            checked += 1
            if delta % 16 == 0 and -32768 <= delta // 16 <= 32767:
                continue
            lands = None
            if rom is not None:
                o = (site - ROM_BASE) // 8
                w = struct.unpack_from("<H", rom, o)[0]
                sw = w - 0x10000 if w & 0x8000 else w
                lands = (pc_after + sw * 16) & 0xFFFFFFFF
            bad.append((obj.name, site, name, syms[name], delta / 16, rtype, lands))

    print("checked %d cross-object PC-relative branches in %d linked objects"
          % (checked, sum(1 for o in args.src.glob("*.OBJ") if o.name.upper() in bases)))
    for obj, site, name, tgt, words, rtype, lands in bad:
        print("  OUT OF RANGE  %-12s site %08x -> %s @ %08x needs %+.0f words (type %d)%s"
              % (obj, site, name, tgt, words, rtype,
                 "; linked branch lands at %08x" % lands if lands is not None else ""))
    for obj, vaddr, name in unresolved:
        print("  unresolved    %-12s +%x -> %s (not in the map)" % (obj, vaddr, name))
    for obj, vaddr, name, op in odd:
        print("  NOT A BRANCH  %-12s +%x -> %s opcode %04x (relocation type misread?)"
              % (obj, vaddr, name, op))
    if odd or unresolved:
        print("PC-relative range UNCERTAIN: %d unexpected site(s)" % (len(odd) + len(unresolved)))
        return 1 if args.check else 0
    if bad:
        print("PC-relative range FAILED: %d branch(es) wrap - use calla / jauc" % len(bad))
        return 1 if args.check else 0
    print("PC-relative range OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
