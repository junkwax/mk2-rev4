#!/usr/bin/env python3
"""Back the ROM's OWN palettes up into an IMG library, and audit which ones
have no library behind them at all.

WHY THIS EXISTS: nothing in the build promotes an IMG palette into the ROM.
LOAD2 emits a `.long <NAME>_P` reference and expects that symbol to already
exist in IMGPAL*.ASM, so every palette in the game is a hand-pasted block of
`.word`s (tools/img_palette.py reads them OUT of an IMG; this puts them back).
That makes the ASM the only copy of some palettes: re-author the IMG and the
ROM does not change, delete the IMG and the ROM does not notice.  A palette
whose words live in no library cannot be opened in IMGTOOL, cannot be
recoloured, and cannot be checked against anything.

    python tools/backup_code_palettes.py                    # audit, all palettes
    python tools/backup_code_palettes.py --unbacked         # just the orphans
    python tools/backup_code_palettes.py --dead             # linked but unused
    python tools/backup_code_palettes.py --apply            # write the manifests
    python tools/backup_code_palettes.py --check            # Phase D: no drift
    python tools/backup_code_palettes.py --roundtrip F.IMG  # prove the writer

The audit classifies every palette in src/IMGPAL*.ASM by where its EXACT words
can be found, searching by CONTENT and never by name - a palette that was
renamed on its way into the ASM (KATSILV_P is KAT104.IMG's KATBLU5_P) is backed
up, and a palette that kept its name while the IMG was recoloured under it is
NOT:

    leak      the words are in the read-only leak       - Midway's, verbatim
    work      the words are in a data/*.IMG in the tree - authored here
    NOWHERE   the words exist only in the ASM           - nothing to open

The leak is the pristine tree next door, not this one; --leak points at another.
"""
from __future__ import annotations

import argparse
import collections
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                    # noqa: E402

REPO = Path(__file__).resolve().parent.parent
LEAK = REPO.parent / "mk2-readonly" / "mk2-main"

LIB_HDR = struct.Struct("<HHIHHHHH4sHHH")
IMAGE   = struct.Struct("<16sHHHHHHIIHHHHHHH")
PALETTE = struct.Struct("<10sBBHIHHBBH")
assert (LIB_HDR.size, IMAGE.size, PALETTE.size) == (28, 50, 26)

NUMDEFPAL = 3           # palcnt on disk counts three palettes not in the file

# ---------------------------------------------------------------------------
# What each library is asked to carry.  A palette is listed BY THE NAME THE
# CODE USES, and its words come from src/IMGPAL*.ASM, because that is the copy
# the ROM ships.  The record written into the IMG keeps the code's name too, so
# --check can find it again and IMGTOOL shows which symbol is being edited.
# ---------------------------------------------------------------------------
MANIFEST = {
    # Kitana's family - her own costumes, her Start+Coin cycle and Jade's
    # victory map.  Khameleon's anchor used to be here as KHAM1_P, a copy of
    # BIV1_P; she wears KHMAIN_P now (IMGPAL6.ASM, out of MK2PALS.IMG) and the
    # copy is gone from the ROM, so the name is gone from here too.  KATSILV_P is the silver she wears on
    # Start+LP: it is KAT104.IMG's KATBLU5_P, it is in NO leak library, and
    # this is its only copy outside the ASM.  BIV1-14_P are NOT the BIV
    # records in KAT10.IMG/KAT104.IMG - 37 of their 64 entries differ - so
    # these are the cycle the ROM actually runs.
    "data/KATPAL.IMG": [
        "KATSILV_P",
        "JADE_P", "JADEV_P",
    ],
    # BIV1-14_P (Kitana's Start+Coin hue cycle) were retired from the ROM on
    # 2026-10-06 with kitana_biv_pal_proc.  Their words STAY in KATPAL.IMG -
    # that copy is now the only one - but they are no longer guarded here,
    # because --check would demand them back in the linked source.

    # The attic.  --dead found 36 palettes nothing linked references; 31 of
    # them are still in an IMG somewhere, so deleting those loses nothing.
    # These five were in NO library, so they are put in one BEFORE --strip
    # removes them - otherwise the delete is the only copy gone.
    #   BOX14_P    a select-box palette, off Mileena's square 2026-09-25
    #   STGORO1_P  Goro reveal / Kintaro fatality looks, applied at runtime by
    #   GOROLK_P     player_swpal.  Their art slot was reclaimed, so the
    #   JTGORO_P     comments in IMGPAL6 describe a path that no longer exists
    #   SCPALT4_P  Scorpion Start+LK costume, orphaned by a costume repoint
    "data/DEADPAL.IMG": [
        "BOX14_P", "STGORO1_P", "GOROLK_P", "JTGORO_P", "SCPALT4_P",
    ],
}

# Libraries that hold palettes the code no longer has.  --apply fills one from
# the ASM while the block is still there; once --strip has removed the block
# there is nothing to compare against, so --check asserts the other direction:
# the words are still here, and nothing has re-added the palette to the ROM.
ATTIC = {"data/DEADPAL.IMG"}


# ---------------------------------------------------------------------------
# IMG library round-trip.  Every field is carried through verbatim; only the
# counts and the data offsets are recomputed, so a rebuild with nothing added
# is byte-identical to what it read (--roundtrip asserts exactly that).
# ---------------------------------------------------------------------------
def read_lib(path: Path):
    data = path.read_bytes()
    hdr = list(LIB_HDR.unpack_from(data, 0))
    imgcnt, palcnt, oset = hdr[0], hdr[1], hdr[2]
    if hdr[4] or hdr[5] or hdr[6]:
        raise SystemExit("%s carries seq/scr/dam tables (%d/%d/%d) that this "
                         "tool does not know how to move"
                         % (path.name, hdr[4], hdr[5], hdr[6]))

    def plausible(off):
        raw = data[off:off + 16].split(b"\0", 1)[0]
        return bool(raw) and all(32 <= c < 127 for c in raw)

    img_first = sum(plausible(oset + i * IMAGE.size)
                    for i in range(imgcnt)) > imgcnt // 2
    img_start = oset if img_first else oset + (palcnt - NUMDEFPAL) * PALETTE.size
    pal_start = oset + imgcnt * IMAGE.size if img_first else oset

    images = []
    for i in range(imgcnt):
        rec = list(IMAGE.unpack_from(data, img_start + i * IMAGE.size))
        w, h, base = rec[4], rec[5], rec[7]
        stride = (w + 3) & ~3                       # 8bpp on disk
        images.append((rec, data[base:base + stride * h]))

    pals = []
    for i in range(palcnt - NUMDEFPAL):
        rec = list(PALETTE.unpack_from(data, pal_start + i * PALETTE.size))
        count, base = rec[3], rec[4]
        pals.append((rec, list(struct.unpack_from("<%dH" % count, data, base))))
    return hdr, images, pals, img_first


def write_lib(hdr, images, pals, img_first) -> bytes:
    """Palette colour data, then image pixel data, then the two tables - the
    order SaveImgFile writes and the order every library in data/ is in."""
    out = bytearray(LIB_HDR.size)
    pal_bases = []
    for _rec, words in pals:
        pal_bases.append(len(out))
        out += struct.pack("<%dH" % len(words), *words)
    img_bases = []
    for _rec, px in images:
        img_bases.append(len(out))
        out += px

    oset = len(out)
    img_tbl, pal_tbl = bytearray(), bytearray()
    for (rec, _px), base in zip(images, img_bases):
        rec = list(rec)
        rec[7] = base
        img_tbl += IMAGE.pack(*rec)
    for (rec, words), base in zip(pals, pal_bases):
        rec = list(rec)
        rec[3], rec[4] = len(words), base
        pal_tbl += PALETTE.pack(*rec)
    out += (img_tbl + pal_tbl) if img_first else (pal_tbl + img_tbl)

    hdr = list(hdr)
    hdr[0], hdr[1], hdr[2] = len(images), len(pals) + NUMDEFPAL, oset
    LIB_HDR.pack_into(out, 0, *hdr)
    return bytes(out)


def pal_record(name: str, words: list[int]) -> list:
    """A fresh palette record.  bitspix is what the entry count implies - it is
    the depth LOAD2 reads for a `PPP> 0` block, and a 64-entry palette is 6."""
    bits = max(1, (len(words) - 1).bit_length())
    return [name.encode("ascii")[:9], 0, bits, len(words), 0, 0, 0, 0, 0, 0]


# ---------------------------------------------------------------------------
# What the build actually links, and what actually references a symbol
# ---------------------------------------------------------------------------
INCLUDE = re.compile(r"^\s*\.(?:include|copy)\s+([A-Za-z0-9_.]+)", re.I | re.M)
TOKEN   = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DECLARE = re.compile(r"^\s*\.(globl|global|ref|def|include|copy|file|option)\b", re.I)

# A palette block is `NAME:` / `.word count` / `.word ...` with count == the
# number of words that follow.  A SPRITE RECORD can match that by accident:
# `.word W,H,anix,aniy` / `.long SAG` / `.word ctrl` / `.long PAL` reads as a
# 3-entry palette whenever W is 3.  Every such false hit seen in this tree is
# 3 entries (FISTPULP*, FONT7*, JC*L, CAVEYE1, RODIMPALE7, tornado7C...), and
# the smallest palette that is really a palette is 10 (FRIENDO_P), so blocks
# under this many words are not trusted.  Raise it, never lower it, without
# re-checking by hand - deleting a sprite record is not recoverable from the
# ASM alone.
MIN_PALETTE_WORDS = 8


def linked_sources():
    """Every source file the build assembles or pulls in, transitively, from
    the .OBJ targets in src/MAKEFILE.  A .TBL sitting in src/ that no ASM
    includes is NOT linked - src/MKVOGEL.TBL is the case that matters, because
    it is VOGEL_p's only referrer and it reaches no ROM."""
    src = REPO / "src"
    mk = (src / "MAKEFILE").read_text(encoding="latin-1")
    byname = {p.name.upper(): p for p in src.iterdir() if p.is_file()}
    out, queue = {}, [m.group(1).upper() + ".ASM"
                      for m in re.finditer(r"([A-Za-z0-9_]+)\.OBJ", mk)]
    while queue:
        f = queue.pop().upper()
        if f in out:
            continue
        p = byname.get(f)
        if p is None:
            continue
        out[f] = p
        for m in INCLUDE.finditer(p.read_text(encoding="latin-1")):
            queue.append(m.group(1))
    return out


def real_uses(files):
    """NAME(upper) -> {(file, line)} for lines that USE the symbol: not its own
    `NAME:` definition, not a .globl/.ref declaration, not a comment."""
    uses = collections.defaultdict(set)
    for p in files:
        try:
            lines = p.read_text(encoding="latin-1").splitlines()
        except Exception:
            continue
        for i, ln in enumerate(lines, 1):
            code = ln.split(";", 1)[0]
            if not code.strip() or code.lstrip().startswith("*"):
                continue
            if DECLARE.match(code):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", code)
            label = m.group(1).upper() if m else None
            if m:
                code = code[m.end():]
            for t in TOKEN.finditer(code):
                if t.group(0).upper() != label:
                    uses[t.group(0).upper()].add((p.name, i))
    return uses


SKIP_IN_RUN = re.compile(r"[.](globl|global|ref|def|even)\b", re.I)
LABEL_ONLY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):[ 	]*$")


def alias_names(files):
    """LAST label of each run of adjacent labels -> every name in that run.

    `NAME:` / `ALIAS:` / `.word count` is one palette under two symbols, and
    ip.asm_palettes only ever attributes the words to the LAST label - so the
    exported alias is invisible to this scan.  Reading the alias as unused is
    what deleted OVERSEL_P's and TCARY_P's bodies in 22b9dbc3 while live code
    still pointed at them: the symbol then resolved to the NEXT palette in the
    file and the art drew in another palette's colours."""
    out = {}
    for p in files:
        try:
            lines = p.read_text(encoding="latin-1").splitlines()
        except Exception:
            continue
        run = []
        for ln in lines:
            m = LABEL_ONLY.match(ln)
            if m:
                run.append(m.group(1))
                continue
            s = ln.strip()
            # Blank lines, comments and declarations do not END a run: the
            # assembler gives `X:` the address of the next thing that emits
            # data whatever sits between, which is exactly how TCARY_P came to
            # mean TALT_P with a `.globl TALT_P` line in the gap.
            if run and (not s or s.startswith(";") or s.startswith("*")
                        or SKIP_IN_RUN.match(s)):
                continue
            if run and s.lower().startswith(".word") and len(run) > 1:
                out[run[-1].upper()] = list(run)
            run = []
    return out


def dead(min_words: int = MIN_PALETTE_WORDS):
    """Palette blocks in LINKED source that nothing linked references.  A
    `.globl` does not count as a use: it only publishes the symbol, and the
    whole point is that nobody took it up.  A block carrying several labels is
    dead only when NONE of them is used - see alias_names."""
    linked = linked_sources()
    pals = {}
    for p in linked.values():
        try:
            d = ip.asm_palettes(p)
        except Exception:
            continue
        for n, w in d.items():
            if len(w) >= min_words:
                pals[n.upper()] = (p.name, n, w)
    uses = real_uses(list(linked.values()))
    aliases = alias_names(list(linked.values()))
    rows = [(("/".join(aliases.get(n, [v[1]]))), v[0], len(v[2]))
            for n, v in sorted(pals.items())
            if not any(uses.get(a.upper())
                       for a in aliases.get(n, [v[1]]))]
    total = 0
    for orig, f, c in rows:
        # count + words, as .word data in the program ROM
        b = c * 2 + 2
        total += b
        print("  %-24s %-14s %3d entries  %5d bytes" % (orig, f, c, b))
    print("\n%d palette blocks of >=%d words in %d linked files; %d referenced "
          "by nothing linked = %d bytes of program ROM"
          % (len(pals), min_words, len(linked), len(rows), total))
    print("Blocks under %d words are not reported - a sprite record can look "
          "like a 3-entry palette.  See MIN_PALETTE_WORDS." % min_words)
    return rows


def newlib(path: Path) -> int:
    """Create an empty palette library --apply can then fill.  The header is
    KATPAL.IMG's: version 0x0634, bufscr FFFFFFFF, no seq/scr/dam tables."""
    if path.exists():
        print("%s already exists" % path.name)
        return 1
    hdr = [0, NUMDEFPAL, 0, 0x0634, 0, 0, 0, 0xABCD, b"\xff\xff\xff\xff", 0, 0, 0]
    path.write_bytes(write_lib(hdr, [], [], True))
    print("%s: created empty (%d bytes)" % (path.name, path.stat().st_size))
    return 0


# ---------------------------------------------------------------------------
# Strip: remove a dead palette's block and every declaration of it
# ---------------------------------------------------------------------------
BLOCK_LINE = re.compile(r"^\s*\.word\b|^\*")


def strip(names) -> int:
    """Delete each named palette's `NAME:` + `.word` block, the contiguous
    comment run directly above it, and every `.globl`/`.ref` of it under src/.

    The declarations are not optional: `.globl X` with no definition in the
    module turns X into an EXTERNAL reference, so leaving one behind trades a
    few dead bytes for an undefined-symbol link failure."""
    src = REPO / "src"
    want = {n.upper() for n in names}
    removed, decls = {}, 0

    for p in sorted(src.iterdir()):
        if not p.is_file() or p.suffix.upper() not in (".ASM", ".TBL", ".GLO", ".HDR"):
            continue
        lines = p.read_text(encoding="latin-1").splitlines(keepends=True)
        drop = set()
        for i, ln in enumerate(lines):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$", ln)
            if m and m.group(1).upper() in want:
                j = i + 1
                if j < len(lines) and re.match(r"^\s*\.word\s", lines[j]):
                    while j < len(lines) and BLOCK_LINE.match(lines[j]):
                        j += 1
                    drop.update(range(i, j))
                    # the comment run + .globl directly above, back to a blank
                    k = i - 1
                    while k >= 0:
                        s = lines[k].strip()
                        if not s:
                            break
                        if (s.startswith(";") or s.startswith("*")
                                or re.match(r"^\s*\.(globl|global|ref)\b", lines[k], re.I)):
                            drop.add(k)
                            k -= 1
                            continue
                        break
                    removed.setdefault(m.group(1), p.name)
            d = re.match(r"^\s*\.(?:globl|global|ref)\s+([A-Za-z_][A-Za-z0-9_,\s]*)", ln, re.I)
            if d and i not in drop:
                syms = [s.strip() for s in d.group(1).split(",") if s.strip()]
                keep = [s for s in syms if s.upper() not in want]
                if len(keep) != len(syms):
                    decls += len(syms) - len(keep)
                    if keep:
                        lines[i] = "\t.globl\t" + ",".join(keep) + "\n"
                    else:
                        drop.add(i)
        if drop:
            out = "".join(l for i, l in enumerate(lines) if i not in drop)
            p.write_text(out, encoding="latin-1", newline="")
            print("  %-16s -%d lines" % (p.name, len(drop)))
        elif any(re.match(r"^\s*\.globl", l) for l in lines):
            new = "".join(lines)
            if new != p.read_text(encoding="latin-1"):
                p.write_text(new, encoding="latin-1", newline="")

    missing = want - {n.upper() for n in removed}
    print("\nremoved %d palette blocks, %d declarations" % (len(removed), decls))
    if missing:
        print("!! no block found for: %s" % ", ".join(sorted(missing)))
        return 1
    return 0


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------
def scan_imgs(root: Path):
    """-> {tuple(words): [(file, name)]} over every IMG library under root."""
    out = collections.defaultdict(list)
    for p in sorted((root / "data").glob("*.IMG")):
        try:
            pals = ip.palettes(p)
        except Exception:
            continue
        for name, words in pals:
            out[tuple(words)].append((p.name, name))
    return out


def asm_pals():
    """Every palette the ROM carries, from EVERY linked source file - not just
    IMGPAL*.ASM.  Palettes also live in MKGUYS, MKSEL, MKDIE, MKFX, BGND,
    MKZAP, MK1WSHRB, SOULPAL and several generated .TBLs; a first pass over
    IMGPAL* alone saw 402 of them and missed 108.

    IMGPAL*.ASM holds nothing but palettes, so it is taken whole.  Everywhere
    else a `.word`-block match can be a SPRITE RECORD (see MIN_PALETTE_WORDS),
    so short blocks from those files are left out."""
    out = {}
    for p in sorted(linked_sources().values()):
        palette_only = p.name.upper().startswith("IMGPAL")
        try:
            found = ip.asm_palettes(p)
        except Exception:
            continue
        for n, w in found.items():
            if palette_only or len(w) >= MIN_PALETTE_WORDS:
                out[n] = (p.name, w)
    return out


def classify(leak_root: Path):
    asm = asm_pals()
    leak = scan_imgs(leak_root)
    work = scan_imgs(REPO)
    rows = []
    for name, (asmfile, words) in sorted(asm.items(), key=lambda kv: kv[0].upper()):
        t = tuple(words)
        pool = leak if t in leak else (work if t in work else None)
        if pool is None:
            rows.append((name, asmfile, "NOWHERE", "%d entries" % len(words)))
            continue
        same = [x for x in pool[t] if x[1].upper() == name.upper()]
        f, n = (same or pool[t])[0]
        rows.append((name, asmfile, "leak" if pool is leak else "work",
                     "%s:%s" % (f, n)))
    return rows


def audit(leak_root: Path, only_unbacked: bool):
    rows = classify(leak_root)
    n = collections.Counter(r[2] for r in rows)
    for name, asmfile, where, note in rows:
        if only_unbacked and where != "NOWHERE":
            continue
        print("  %-14s %-13s %-8s %s" % (name, asmfile, where, note))
    print("\n%d palettes in src/IMGPAL*.ASM: %d in the leak, %d authored here, "
          "%d NOWHERE but the ASM"
          % (sum(n.values()), n["leak"], n["work"], n["NOWHERE"]))
    return rows


# ---------------------------------------------------------------------------
def apply_or_check(check: bool) -> int:
    asm = asm_pals()
    bad = 0
    for rel, names in MANIFEST.items():
        path = REPO / rel
        if not path.exists():
            print("!! %s does not exist" % rel)
            bad += 1
            continue
        hdr, images, pals, img_first = read_lib(path)
        have = {ip.cstr(r[0]).upper(): (i, w) for i, (r, w) in enumerate(pals)}
        changed = []
        attic = rel in ATTIC
        for name in names:
            if name not in asm:
                # An ATTIC library holds palettes --strip has DELETED, so the
                # code no longer defines them and there is nothing to compare
                # against.  The invariant there is the opposite one: the words
                # are still in the library, and nothing has quietly put the
                # palette back into the ROM.
                if attic:
                    if name.upper() in have:
                        continue
                    print("LOST    %s: gone from the code AND from %s" % (name, rel))
                else:
                    print("!! %s is not a palette in any linked source file" % name)
                bad += 1
                continue
            if attic:
                print("BACK    %s: defined in %s again - it is in the attic %s, "
                      "so remove it from one of the two"
                      % (name, asm[name][0], rel))
                bad += 1
                continue
            words = asm[name][1]
            slot = have.get(name.upper())
            if slot is None:
                if check:
                    print("MISSING %s: %s carries no such palette" % (name, rel))
                    bad += 1
                    continue
                pals.append((pal_record(name, words), words))
                changed.append("+" + name)
            elif slot[1] != words:
                if check:
                    print("DRIFT   %s: %s has %d entries, the ASM has %d"
                          % (name, rel, len(slot[1]), len(words)))
                    bad += 1
                    continue
                pals[slot[0]] = (pals[slot[0]][0], words)
                changed.append("~" + name)
        if check:
            print("%s: %d palettes checked" % (rel, len(names)))
            continue
        blob = write_lib(hdr, images, pals, img_first)
        if blob != path.read_bytes():
            path.write_bytes(blob)
            print("%s: now %d palettes, %d images, %d bytes  (%s)"
                  % (rel, len(pals), len(images), len(blob),
                     " ".join(changed) or "offsets only"))
        else:
            print("%s: already current" % rel)
    return bad


def roundtrip(path: Path) -> int:
    hdr, images, pals, img_first = read_lib(path)
    blob = write_lib(hdr, images, pals, img_first)
    raw = path.read_bytes()
    if blob == raw:
        print("%s: round-trip byte-identical (%d bytes, %d images, %d palettes)"
              % (path.name, len(raw), len(images), len(pals)))
        return 0
    print("%s: round-trip DIFFERS - rebuilt %d bytes, on disk %d"
          % (path.name, len(blob), len(raw)))
    for i in range(min(len(blob), len(raw))):
        if blob[i] != raw[i]:
            print("  first difference at 0x%X: %02X != %02X" % (i, blob[i], raw[i]))
            break
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--leak", default=str(LEAK),
                    help="pristine tree to compare against")
    ap.add_argument("--unbacked", action="store_true", help="audit: orphans only")
    ap.add_argument("--dead", action="store_true",
                    help="palette blocks nothing linked references")
    ap.add_argument("--apply", action="store_true", help="write the manifests")
    ap.add_argument("--check", action="store_true", help="fail if a manifest drifted")
    ap.add_argument("--roundtrip", metavar="IMG", help="prove the writer on one library")
    ap.add_argument("--newlib", metavar="IMG", help="create an empty palette library")
    ap.add_argument("--strip", action="store_true",
                    help="delete every --dead palette and its declarations")
    a = ap.parse_args()

    if a.roundtrip:
        return roundtrip(Path(a.roundtrip))
    if a.newlib:
        return newlib(Path(a.newlib))
    if a.strip:
        rows = dead()
        print()
        return strip([r[0] for r in rows])
    if a.dead:
        dead()
        return 0
    if a.apply or a.check:
        return 1 if apply_or_check(a.check) else 0
    leak = Path(a.leak)
    if not (leak / "data").is_dir():
        print("!! no data/ under %s" % leak)
        return 1
    audit(leak, a.unbacked)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
