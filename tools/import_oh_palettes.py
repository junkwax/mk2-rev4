#!/usr/bin/env python3
"""
Import Outer Haven background palettes from a BLIMP .BDD/.BDB export into
src/BGNDPAL.ASM.

WHY THIS EXISTS: the artist's exports keep the SAME palette NAMES with
DIFFERENT colours, and their `_N` suffixes do not correspond between files -
OUTERHA used an irregular set, UPDATEDBL a `_3` set, newhut a `_7` set.  Four
hand-imports in a row each needed the .BDB re-read to find which record was
live.  Guessing from a name is how you install the wrong grade.

So the record is never named here.  The .BDB is the authority: it lists every
object with the palette record that object uses, and the block counts
fingerprint which ohPALS slot each one is.

    slot 0  oh_timeB_p     13 blocks   sky
    slot 1  oh_dusk3_p      2 blocks   sky
    slot 2  oh_timea_p      1 block    sky
    slot 3  oh_dusk1_p      2 blocks   sky
    slot 4  oh_ptemple_p   20 blocks   the two pagoda tower huts
    slot 5  oh_pwalls_p    26 blocks   the beams and the curb
    slot 6  oh_babymo_p     1 block    the moon

Those counts come from src/BGNDTBL.ASM - the low nibble of each block's flags
word is the index BAKGND.ASM looks ohPALS up with - and are re-derived from
the ASM on every run, not hardcoded, so a background edit cannot silently
invalidate them.

Usage:
    python tools/import_oh_palettes.py <bdd> --slots 4          # huts only
    python tools/import_oh_palettes.py <bdd> --slots 4,5
    python tools/import_oh_palettes.py <bdd> --slots all
    python tools/import_oh_palettes.py <bdd> --check            # report only
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BGNDPAL = ROOT / "src" / "BGNDPAL.ASM"
BGNDTBL = ROOT / "src" / "BGNDTBL.ASM"

# ohPALS slot -> (ASM label, which BLKS tables can carry it, human name)
SLOTS = [
    ("oh_timeB_p",   "sky"),
    ("oh_dusk3_p",   "sky"),
    ("oh_timea_p",   "sky"),
    ("oh_dusk1_p",   "sky"),
    ("oh_ptemple_p", "the two pagoda tower huts"),
    ("oh_pwalls_p",  "the beams and the curb"),
    ("oh_babymo_p",  "the moon"),
]
BLKS = ["spiral1BLKS", "ohspiral2BLKS", "spiral3BLKS", "spiral4BLKS"]


def read_line(d, p):
    while p < len(d) and d[p] in (10, 13):
        p += 1
    e = d.find(b"\n", p)
    if e < 0:
        raise ValueError("unterminated line in BDD")
    return d[p:e].decode("ascii", "replace").rstrip("\r"), e + 1


def bdd_palettes(path):
    """name -> [colour words], in file order."""
    data = Path(path).read_bytes()
    pos = 0
    line, pos = read_line(data, pos)
    for _ in range(int(line)):                      # skip the image blocks
        line, pos = read_line(data, pos)
        _, w, h, _f = line.split()
        pos += int(w) * int(h)
    out = []
    while pos < len(data):
        line, pos = read_line(data, pos)
        if not line:
            continue
        name, cnt = line.split()
        cnt = int(cnt)
        out.append((name, list(struct.unpack_from("<%dH" % cnt, data, pos))))
        pos += cnt * 2
    return out


def bdb_objects(path):
    """Palette record index used by each OBJECT, plane-definition lines excluded.

    Header is `name worldw worldh ? modules palettes objects`; the module
    lines follow, then the objects.  The module lines also have five fields,
    so slicing by the declared counts is the only safe way to tell them apart.
    """
    lines = [l.strip() for l in Path(path).read_text().splitlines() if l.strip()]
    head = lines[0].split()
    nmod, nobj = int(head[4]), int(head[6])
    objs = lines[1 + nmod: 1 + nmod + nobj]
    return [int(l.split()[4]) for l in objs if len(l.split()) == 5]


def asm_slot_counts():
    """Blocks per ohPALS slot, derived from the live BLKS tables."""
    s = BGNDTBL.read_text(encoding="latin-1")
    counts = {}
    for tbl in BLKS:
        i = s.index(tbl + ":")
        j = s.index("0FFFFH", i)
        for m in re.findall(r"\.word\t0([0-9A-Fa-f]{4})H", s[i:j]):
            counts[int(m, 16) & 0xF] = counts.get(int(m, 16) & 0xF, 0) + 1
    return counts


def asm_palette(text, label):
    i = text.index("\n" + label + ":")
    j = text.index("\n\n", i)
    out = []
    for line in text[i:j].split("\n"):
        line = line.split(";")[0]                   # ignore hex inside prose
        m = re.match(r"\s*\.word\s+(.+)$", line)
        if not m:
            continue
        for tok in m.group(1).split(","):
            tok = tok.strip()
            if re.fullmatch(r"0[0-9A-Fa-f]+[Hh]", tok):
                out.append(int(tok.rstrip("Hh"), 16))
    return out


def resolve(bdd, bdb):
    """slot -> (record index, record name, colours), via the BDB."""
    pals = bdd_palettes(bdd)
    used = bdb_objects(bdb)
    order = sorted(set(used))
    if len(order) != len(SLOTS):
        sys.exit("BDB names %d palette records, expected %d - layout changed?"
                 % (len(order), len(SLOTS)))
    want = asm_slot_counts()
    got = {slot: used.count(rec) for slot, rec in enumerate(order)}
    bad = [s for s in range(len(SLOTS)) if want.get(s, 0) != got[s]]
    if bad:
        for s in range(len(SLOTS)):
            print("  slot %d  ASM %3d blocks  BDB %3d blocks  %s"
                  % (s, want.get(s, 0), got[s], "MISMATCH" if s in bad else "ok"))
        sys.exit("block counts disagree - the BDB does not describe this stage")
    return {s: (rec, pals[rec][0], pals[rec][1]) for s, rec in enumerate(order)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bdd", type=Path)
    ap.add_argument("--slots", default="all")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    bdb = a.bdd.with_suffix(".BDB")
    if not bdb.exists():
        bdb = a.bdd.with_suffix(".bdb")
    table = resolve(a.bdd, bdb)

    which = (range(len(SLOTS)) if a.slots == "all"
             else [int(x) for x in a.slots.split(",")])
    text = BGNDPAL.read_text(encoding="latin-1")
    print("%s  (%d palettes)  ->  %s\n" % (a.bdd.name, len(bdd_palettes(a.bdd)), bdb.name))
    changed = 0
    for slot in range(len(SLOTS)):
        label, what = SLOTS[slot]
        rec, name, pal = table[slot]
        cur = asm_palette(text, label)
        diff = sum(1 for x, y in zip(cur, pal) if x != y) + abs(len(cur) - len(pal))
        mark = "" if slot in which else "   (not selected)"
        print("  slot %d  %-14s rec %-3d %-14s %2d/%d entries differ%s"
              % (slot, label, rec, name, diff, len(pal), mark))
        if slot not in which or a.check or diff == 0:
            continue
        head = ('; %s - `%s` from data/BLUEPTL_MK2/%s,\n'
                '\t\t; palette record %d.  Resolved by %s, which assigns that\n'
                '\t\t; record to all %d blocks of this layer - the suffix is\n'
                '\t\t; per-export bookkeeping and means nothing across files.\n'
                '\t\t; Imported by tools/import_oh_palettes.py.'
                % (what, name, a.bdd.name, rec, bdb.name, len(bdb_objects(bdb))
                   and sum(1 for r in bdb_objects(bdb) if r == rec)))
        body = ("\n" + label + ":\t" + head + "\n\t.word\t%d\t;pal size\n" % len(pal)
                + "\n".join("\t.word\t" + ",".join("0%04XH" % v for v in pal[k:k + 8])
                            for k in range(0, len(pal), 8)))
        i = text.index("\n" + label + ":")
        j = text.index("\n\n", i)
        text = text[:i] + body + text[j:]
        changed += 1
    if changed and not a.check:
        BGNDPAL.write_text(text, encoding="latin-1", newline="")
        print("\nwrote %d palette(s) into src/BGNDPAL.ASM" % changed)
    elif not a.check:
        print("\nnothing to write - selected slots already match")


if __name__ == "__main__":
    main()
