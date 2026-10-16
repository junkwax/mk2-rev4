#!/usr/bin/env python3
r"""Retail MK2's MIRROR-MATCH costumes, out of the read-only tree and into
`data/MK2PALS.IMG` + `src/MK2PALS.ASM`, wired to Start+HP.

WHAT THIS IS.  `character_palettes_2` is what CLAUDE.md calls the secondary
default: the costume a fighter wears on Start+LP AND the one player 2 is handed
automatically in a mirror match.  Retail's twelve are Midway's, and this tree
has moved several of them - the ninjas took UMK costumes, Kitana took silver -
so the shipped alternate is no longer reachable on the slot it shipped on.
This puts Midway's twelve, and the twelve BLOODIED counterparts the cut-up art
is drawn in, on **Start+HP**: `character_palettes_4` and
`bloody_character_palettes_4` rows 0-11 (MKGUYS.ASM).

WHY THE PALETTES ARE COPIES AND NOT THE EXISTING SYMBOLS.  Pointing slot 4 at
`tmgold_p` would make slot 4 an ALIAS of slot 2: repainting the costume in
IMGTOOL would then silently change the mirror match too.  These are their own
records under their own names, so Start+HP can be repainted on its own.

WHY THE WORDS COME FROM `mk2-readonly` AND NOT FROM src/.  Two of the twenty
four have DRIFTED in this tree and would otherwise ship as "retail" while
being something else:

    RADRED_P     2 of 64 entries  (re-extracted here from RADBOLT1.IMG)
    KATBLU3_P   28 of 64 entries

Both are reported by `--report`.  The source of truth is the read-only tree's
`src/`, because that is the copy retail's ROM shipped - not its IMG libraries,
which are the AUTHORING side and can disagree with it.  Every palette is then
looked for in a read-only `data/*.IMG` BY CONTENT, never by name, and the
record it was found in is printed: that is a proof the words are Midway's and
not a transcription.  Kitana is why it matters - retail's `KATBLU3_P` resolves
to `KAT11.IMG:KATBLU3_P`, while THIS tree's symbol of the same name resolves
to `KAT1.IMG:KATBLU2_P`.  Same name, two different palettes, and only the
content match can tell which one a row is pointing at.

THE TWELVE ROWS ARE READ, NOT TYPED.  `character_palettes_2` and the second
`.long` of each `bloody_palettes` row are parsed out of the read-only
`src/MKGUYS.ASM`, so pointing this at the wrong tree fails instead of quietly
producing a plausible-looking wrong set.  Only the ROSTER below - which gore
library each fighter's reference art comes out of - is authored here.

A PALETTE ON ITS OWN CANNOT BE JUDGED, so each record gets a frame to hold it
against, the way `KATPAL.IMG` does: the fighter's STANCE for the costume and
his TORSO RIP for the blood palette, pixels copied verbatim out of the
read-only gore library that already carries both palettes.  Kitana/Mileena and
the three ninjas share a body, so those records hold identical pixels and
differ only in `palnum` - which is the point, because it is what lets IMGTOOL
show the costumes side by side.

`palnum` IS OFFSET BY THREE: the library header counts NUMDEFPAL phantom
palettes that are not in the file, so `palnum = 3 + index in the file`.

`MK2PALS.IMG` is in NO LOD.  LOAD2 never reads it and no pixel of it reaches a
ROM - only `src/MK2PALS.ASM`, which this generates, is linked.  Re-run after
every repaint; Phase D's `--check` fails the build if the two disagree.

THE LIBRARY IS SHARED, AND THAT IS WHY THE CHECK IS BY CONTENT.  This tool
OWNS `src/MK2PALS.ASM` - that file is generated whole and compared byte for
byte.  It does not own the whole of `data/MK2PALS.IMG`: the library has become
the place palettes get authored in IMGTOOL (Khameleon's four are there, and
dozens of others), so demanding the file equal a freshly written one failed the
build for work that had broken nothing.  Instead `--check` asks the only
question that matters for a library that ships no pixels - are the 24 records
this tool put there still there, word for word - and it asks BY CONTENT, so a
record IMGTOOL renamed still answers yes and prints the name it now has.  Five
of the twelve have been renamed that way already (`M2KTBLU_P` is the record
called `KTALT1_P` today).

For the same reason `--apply` will NOT rewrite an IMG that carries records this
tool does not own; it rewrites the ASM and says so.  `--rebuild-img` forces the
fresh library and is how the file is started from nothing - it DISCARDS every
hand-authored record in it.

    python tools/make_mk2pals.py              # report, write nothing
    python tools/make_mk2pals.py --report     # + drift and provenance detail
    python tools/make_mk2pals.py --apply      # write the ASM (and the IMG if
                                              #   it holds nothing else)
    python tools/make_mk2pals.py --rebuild-img  # force a fresh IMG - DESTRUCTIVE
    python tools/make_mk2pals.py --check      # Phase D: fail on drift
    python tools/make_mk2pals.py --rgb        # + the colours as hex
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                            # noqa: E402
from backup_code_palettes import NUMDEFPAL, pal_record, write_lib   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
LEAK = REPO.parent / "mk2-readonly" / "mk2-main"
IMG_OUT = REPO / "data" / "MK2PALS.IMG"
ASM_OUT = REPO / "src" / "MK2PALS.ASM"

LIB_HDR, IMAGE = ip.LIB_HDR, ip.IMAGE

# A fresh library header, shaped like data/KATPAL.IMG's: version 1588, no
# seq/scr/dam tables, the 0xABCD magic and the -1 filler IMGTOOL writes.
# write_lib() recomputes the first three fields.
FRESH_HDR = [0, 0, 0, 1588, 0, 0, 0, 0xABCD, b"\xff\xff\xff\xff", 0, 0, 0]

# ochar, code, fighter, the read-only gore library that carries BOTH of his
# retail alternate palettes, his stance record, his torso-rip record, and the
# two names the copies take here.  Baraka's rip was authored as two strips
# with no composite, so his reference is the larger one.
ROSTER = [
    (0,  "TM", "Kung Lao",    "HATHED11.IMG", "TMSTANCE1",  "TMRIPTORSO1",  "M2TMGLD_P", "M2TMBLD_P"),
    (1,  "LK", "Liu Kang",    "KANG10.IMG",   "LKSTANCE1",  "LKRIPTORSO1",  "M2LKBLU_P", "M2LKBLD_P"),
    (2,  "JC", "Johnny Cage", "CAGE10.IMG",   "JCSTANCE1",  "JCRIPTORSO1",  "M2JCRED_P", "M2JCBLD_P"),
    (3,  "UG", "Baraka",      "UGMO10.IMG",   "UGSTANCE1",  "UGRIPTORSO1A", "M2UGBLU_P", "M2UGBLD_P"),
    (4,  "KT", "Kitana",      "KAT11.IMG",    "KT1STANCE1", "KTRIPTORSO1",  "M2KTBLU_P", "M2KTBLD_P"),
    (5,  "ML", "Mileena",     "KAT11.IMG",    "KT2STANCE1", "KTRIPTORSO1",  "M2MLPRP_P", "M2MLBLD_P"),
    (6,  "ST", "Shang Tsung", "TSUNG10.IMG",  "STSTANCE1",  "STRIPTORSO1",  "M2STBLU_P", "M2STBLD_P"),
    (7,  "RD", "Raiden",      "RAID9.IMG",    "RNSTANCE1",  "RNRIPTORSO1",  "M2RDRED_P", "M2RDBLD_P"),
    (8,  "SZ", "Sub-Zero",    "NINJAS11.IMG", "NJ1STANCE1", "NJRIPTORSO1",  "M2SZBLU_P", "M2SZBLD_P"),
    (9,  "RP", "Reptile",     "NINJAS11.IMG", "NJ2STANCE1", "NJRIPTORSO1",  "M2RPGRN_P", "M2RPBLD_P"),
    (10, "SC", "Scorpion",    "NINJAS11.IMG", "NJ3STANCE1", "NJRIPTORSO1",  "M2SCYEL_P", "M2SCBLD_P"),
    (11, "JX", "Jax",         "NUJAX10.IMG",  "JXSTANCE1",  "JXRIPTORSO1",  "M2JXBLU_P", "M2JXBLD_P"),
]


# ---------------------------------------------------------------------------
# The read-only tree: the two tables, and every palette's words
# ---------------------------------------------------------------------------
# A palette block is `NAME:` / `.word count` / `.word ...`.  img_palette's own
# reader treats only `*` in column 1 as a comment; this tree also writes `;`
# comments inside a block (RADRED_P has one), and a reader that stops at one
# reports the palette MISSING - which reads as "retail does not have it".
PAL_BLOCK = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*):?[ \t]*\n"
    r"((?:(?:[ \t]*\.word[^\n]*|[ \t]*;[^\n]*|\*[^\n]*)\n)+)", re.M)


def asm_palettes(path: Path) -> dict:
    out = {}
    for m in PAL_BLOCK.finditer(path.read_text(encoding="latin-1")):
        vals = []
        for line in m.group(2).splitlines():
            s = line.strip()
            if s.startswith(";") or s.startswith("*"):
                continue
            for tok in line.split(".word", 1)[-1].split(","):
                tok = tok.strip()
                if not tok:
                    continue
                try:
                    vals.append(int(tok[:-1], 16) if tok[-1] in "hH" else int(tok, 0))
                except ValueError:
                    vals = None
                    break
            if vals is None:
                break
        # the count word has to agree with what follows, or it is not a palette
        if vals and len(vals) >= 2 and vals[0] == len(vals) - 1:
            out[m.group(1)] = vals[1:]
    return out


def tree_palettes(root: Path) -> dict:
    """Every palette in a tree's src/, first definition wins."""
    out = {}
    for f in sorted((root / "src").glob("*.ASM")):
        for k, v in asm_palettes(f).items():
            out.setdefault(k, v)
    return out


LONGS = re.compile(r"^\s*\.long\s+([^;*\n]+)", re.M)


def table_rows(text: str, label: str, want: int, per_row: int) -> list:
    """The first `want` rows of `.long`s under `label`.  Stops at the next
    label so a short table is an error, not a silent read into the next one."""
    m = re.search(r"^%s\s*$" % re.escape(label), text, re.M)
    if not m:
        raise SystemExit("%s: no such table in the read-only MKGUYS.ASM" % label)
    tail = text[m.end():]
    end = re.search(r"^[A-Za-z_][A-Za-z0-9_]*\s*$", tail, re.M)
    body = tail[:end.start()] if end else tail
    rows = []
    for lm in LONGS.finditer(body):
        cells = [c.strip() for c in lm.group(1).split(",") if c.strip()]
        if len(cells) != per_row:
            raise SystemExit("%s: a row has %d entries, expected %d: %r"
                             % (label, len(cells), per_row, lm.group(1)))
        rows.append(cells)
    if len(rows) < want:
        raise SystemExit("%s: only %d rows, expected at least %d"
                         % (label, len(rows), want))
    return rows[:want]


def retail_pairs() -> list:
    """(costume, blood) symbol per ochar 0..11, read out of the read-only
    MKGUYS.ASM.  `bloody_palettes` rows are [nice, ugly] and the mirror match
    is the UGLY one - change_to_bloody_pal adds 32 bits for b_ugly_pal."""
    txt = (LEAK / "src" / "MKGUYS.ASM").read_text(encoding="latin-1")
    cos = [r[0] for r in table_rows(txt, "character_palettes_2", 12, 1)]
    bld = [r[1] for r in table_rows(txt, "bloody_palettes", 12, 2)]
    return list(zip(cos, bld))


# ---------------------------------------------------------------------------
# IMG libraries: a tolerant reader for the sources, because the gore libraries
# carry seq/scr tables that backup_code_palettes.read_lib refuses to move.
# Nothing is written back to them, so only the image table is needed.
# ---------------------------------------------------------------------------
def read_images(path: Path) -> dict:
    """-> {NAME: (record, pixels)} for one library."""
    data = path.read_bytes()
    hdr = LIB_HDR.unpack_from(data, 0)
    imgcnt, oset = hdr[0], hdr[2]

    def plausible(off):
        raw = data[off:off + 16].split(b"\0", 1)[0]
        return bool(raw) and all(32 <= c < 127 for c in raw)

    if sum(plausible(oset + i * IMAGE.size) for i in range(imgcnt)) <= imgcnt // 2:
        raise SystemExit("%s: image table is not where it is expected" % path.name)
    out = {}
    for i in range(imgcnt):
        rec = list(IMAGE.unpack_from(data, oset + i * IMAGE.size))
        w, h, base = rec[4], rec[5], rec[7]
        stride = (w + 3) & ~3                       # 8bpp on disk
        px = data[base:base + stride * h]
        if len(px) != stride * h:
            raise SystemExit("%s: %s runs off the end of the file"
                             % (path.name, ip.cstr(rec[0])))
        out[ip.cstr(rec[0]).upper()] = (rec, px)
    return out


_PROV_CACHE = None


def provenance(sym: str, words: list) -> str:
    """Which read-only data/*.IMG record holds these exact words.  The match is
    BY CONTENT - a palette renamed on its way into the ASM still resolves, and
    one that kept its name while the library was recoloured under it does not.

    Several libraries can carry the same words under different names, so the
    record whose NAME is also the symbol wins when there is one; otherwise the
    first by filename.  Without that preference JXBLUD1_P reports as
    MKJXARMS.IMG's JXARMS_P - true, and unreadable."""
    global _PROV_CACHE
    if _PROV_CACHE is None:
        _PROV_CACHE = {}
        for p in sorted((LEAK / "data").glob("*.IMG")):
            try:
                pals = ip.palettes(p)
            except Exception:
                continue
            for name, w in pals:
                _PROV_CACHE.setdefault(tuple(w), []).append((p.name, name))
    hits = _PROV_CACHE.get(tuple(words), [])
    for lib, name in hits:
        if name.upper() == sym.upper():
            return "%s:%s" % (lib, name)
    return "%s:%s" % hits[0] if hits else ""


def sym_drift(ours: dict, sym: str, retail: list):
    """How far this tree's copy of the same symbol has moved from retail's.
    None when the symbol is not in this tree at all."""
    mine = ours.get(sym)
    if mine is None:
        return None
    if len(mine) != len(retail):
        return len(retail)
    return sum(1 for a, b in zip(mine, retail) if a != b)


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
def collect():
    """-> (rows, pal_records, img_records).  rows is one dict per fighter."""
    pairs = retail_pairs()
    leak_words = tree_palettes(LEAK)
    ours = tree_palettes(REPO)
    libs = {}

    rows, pals, imgs = [], [], []
    for spec, (csym, bsym) in zip(ROSTER, pairs):
        ochar, code, who, lib, stance, gore, pname, bname = spec
        for sym in (csym, bsym):
            if sym not in leak_words:
                raise SystemExit("%s: %s is in retail's table but has no words "
                                 "in the read-only src/" % (who, sym))
        if lib not in libs:
            libs[lib] = read_images(LEAK / "data" / lib)
        art = libs[lib]
        for rec_name in (stance, gore):
            if rec_name.upper() not in art:
                raise SystemExit("%s: %s has no record %s" % (who, lib, rec_name))

        cw, bw = leak_words[csym], leak_words[bsym]
        rows.append(dict(ochar=ochar, who=who, lib=lib,
                         csym=csym, bsym=bsym, pname=pname, bname=bname,
                         cwords=cw, bwords=bw,
                         cprov=provenance(csym, cw), bprov=provenance(bsym, bw),
                         cdrift=sym_drift(ours, csym, cw),
                         bdrift=sym_drift(ours, bsym, bw),
                         stance=stance, gore=gore))

        # palette records first: the image records point at them by index
        ci, bi = len(pals), len(pals) + 1
        pals.append((pal_record(pname, cw), cw))
        pals.append((pal_record(bname, bw), bw))

        for rec_name, new_name, pi in ((stance, "M2%sSTANCE" % code, ci),
                                       (gore, "M2%sTORSO" % code, bi)):
            rec, px = art[rec_name.upper()]
            rec = list(rec)
            rec[0] = new_name.encode("ascii")
            rec[6] = NUMDEFPAL + pi        # palnum is offset by three
            imgs.append((rec, px))
    return rows, pals, imgs


def as_asm(rows) -> str:
    out = [
        "; GENERATED by tools/make_mk2pals.py - do not edit by hand.",
        "; Retail MK2's MIRROR-MATCH costumes (character_palettes_2) and the",
        "; bloodied palettes the cut-up art is drawn in, lifted from the",
        "; read-only tree.  Only the COSTUMES link from here (character_palettes_4",
        "; rows 0-11, MKGUYS.ASM): the bloodied ones are authored in",
        "; data/MK2PALS.IMG but linked by tools/make_costume_palettes.py as",
        "; COSTPAL's KP_*BLD1_P (bloody_character_palettes_4), so copies here were",
        "; never read - 1,550 bytes of program ROM (doc/ASSET_SPACE_LEDGER.md).",
        ";",
        "; These are COPIES, not the shipped symbols: Start+HP can be",
        "; repainted in data/MK2PALS.IMG without moving the mirror match.",
        "\t.FILE \"mk2pals.asm\"",
        "\t.OPTION B,D,L,T",
        "",
    ]
    for r in rows:
        out.append("\t.globl\t%s" % r["pname"])
    out += ["\t.DATA", "\t.even", ""]
    for r in rows:
        for kind, name, sym, words, prov in (
                ("costume", r["pname"], r["csym"], r["cwords"], r["cprov"]),):
            out.append("; %-12s %-8s - retail %s%s"
                       % (r["who"], kind, sym,
                          (" (%s)" % prov) if prov else " (in no library)"))
            out.append(ip.as_asm(name, words))
            out.append("")
    return "\n".join(out) + "\n"


def report(rows, rgb: bool, detail: bool) -> None:
    print("%-13s %-9s %-11s %-9s %-11s" % ("fighter", "Start+HP", "from retail",
                                           "bloodied", "from retail"))
    for r in rows:
        print("%-13s %-9s %-11s %-9s %-11s"
              % (r["who"], r["pname"], r["csym"], r["bname"], r["bsym"]))
    if detail:
        print("\nprovenance (read-only data/*.IMG, matched BY CONTENT):")
        for r in rows:
            for name, sym, prov in ((r["pname"], r["csym"], r["cprov"]),
                                    (r["bname"], r["bsym"], r["bprov"])):
                print("  %-9s = %-10s %s" % (name, sym, prov or "IN NO LIBRARY"))
        print("\ndrift - this tree's own copy of the same symbol vs retail's:")
        any_drift = False
        for r in rows:
            for sym, d in ((r["csym"], r["cdrift"]), (r["bsym"], r["bdrift"])):
                if d is None:
                    print("  %-10s not in this tree" % sym)
                    any_drift = True
                elif d:
                    print("  %-10s %d entries differ" % (sym, d))
                    any_drift = True
        if not any_drift:
            print("  none - every symbol still matches retail word for word")
    if rgb:
        print()
        for r in rows:
            for name, words in ((r["pname"], r["cwords"]), (r["bname"], r["bwords"])):
                print("%s  %s" % (name, " ".join(
                    "%02X%02X%02X" % (((w >> 10) & 31) * 8, ((w >> 5) & 31) * 8,
                                      (w & 31) * 8) for w in words[:16])))


def img_holds_ours(rows) -> tuple:
    """(missing, where) - are our 24 palettes still in the library, BY CONTENT?

    Matched on the colour words, never on the record name: IMGTOOL renames are
    routine and harmless here, because only src/MK2PALS.ASM is linked.  `where`
    maps our symbol to the record name it was found under, so a rename is
    reported rather than merely tolerated.
    """
    if not IMG_OUT.exists():
        return [r["pname"] for r in rows] + [r["bname"] for r in rows], {}
    byword = {}
    for name, words in ip.palettes(IMG_OUT):
        byword.setdefault(tuple(words), []).append(name)
    missing, where = [], {}
    for r in rows:
        for name, words in ((r["pname"], r["cwords"]), (r["bname"], r["bwords"])):
            hit = byword.get(tuple(words))
            if hit:
                where[name] = hit[-1]           # LAST match, as LOAD2 resolves
            else:
                missing.append(name)
    return missing, where


def img_is_only_ours(rows) -> bool:
    """True when every record in the library is one of ours - i.e. nothing has
    been authored into it by hand and a full rewrite would lose nothing."""
    if not IMG_OUT.exists():
        return True
    ours = {tuple(w) for r in rows for w in (r["cwords"], r["bwords"])}
    return all(tuple(words) in ours for _n, words in ip.palettes(IMG_OUT))


def apply_or_check(rows, pals, imgs, check: bool, rebuild_img: bool) -> int:
    asm = as_asm(rows)
    asm_stale = not ASM_OUT.exists() or ASM_OUT.read_text(encoding="latin-1") != asm
    missing, where = img_holds_ours(rows)

    if check:
        rc = 0
        if asm_stale:
            print("src/MK2PALS.ASM is stale - re-run tools/make_mk2pals.py --apply")
            rc = 1
        if missing:
            print("data/MK2PALS.IMG no longer carries %d of the palettes this "
                  "tool put there:" % len(missing))
            for name in missing:
                print("    %s" % name)
            print("re-run tools/make_mk2pals.py --apply (or --rebuild-img to "
                  "start the library over)")
            rc = 1
        if rc:
            return rc
        renamed = {k: v for k, v in where.items() if k != v}
        print("MK2PALS: %d palettes, %d reference frames, in step%s"
              % (len(pals), len(imgs),
                 " (%d renamed in IMGTOOL: %s)"
                 % (len(renamed), ", ".join("%s=%s" % kv
                                            for kv in sorted(renamed.items())))
                 if renamed else ""))
        return 0

    ASM_OUT.write_text(asm, encoding="latin-1")
    print("src/MK2PALS.ASM   %d palettes, %d bytes" % (len(pals), len(asm)))

    if rebuild_img or img_is_only_ours(rows):
        blob = write_lib(list(FRESH_HDR), imgs, pals, True)
        IMG_OUT.write_bytes(blob)
        print("data/MK2PALS.IMG  %d palettes, %d images, %d bytes"
              % (len(pals), len(imgs), len(blob)))
        return 0

    extra = len(ip.palettes(IMG_OUT)) - 2 * len(rows)
    print("data/MK2PALS.IMG  left alone - it carries %d palette(s) this tool "
          "does not own" % max(extra, 0))
    if missing:
        print("                  but %d of ours are NOT in it: %s"
              % (len(missing), ", ".join(missing)))
        print("                  add them in IMGTOOL, or --rebuild-img to "
              "start over (DISCARDS the hand-authored records)")
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--rebuild-img", action="store_true",
                    help="force a fresh data/MK2PALS.IMG - DISCARDS every "
                         "hand-authored palette in it")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--rgb", action="store_true")
    a = ap.parse_args()
    if not (LEAK / "src" / "MKGUYS.ASM").exists():
        raise SystemExit("the read-only tree is not at %s" % LEAK)
    rows, pals, imgs = collect()
    if not (a.apply or a.check or a.rebuild_img):
        report(rows, a.rgb, a.report or a.rgb)
        return 0
    return apply_or_check(rows, pals, imgs, a.check, a.rebuild_img)


if __name__ == "__main__":
    sys.exit(main())
