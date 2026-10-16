#!/usr/bin/env python3
r"""THE CRACKLE THAT RUNS OVER RAIDEN'S BODY, IN THE COLOUR OF HIS CURRENT.

His ambient `RN*BOLT` flash (`data/RADBOLT1.IMG`, six styles, 102 pieces) is
painted against the COSTUME layout, not against a bolt palette - `ELEC_P` has
only 53 entries and the art indexes 63, which would read past it as CRAM
garbage.  So the crackle wears whatever palette Raiden's costume is, and its
colour is one slot of that palette.

WHICH SLOT IS MEASURED, NOT ASSUMED.  This decodes all 102 pieces out of the
built video ROM and histograms the indices they draw in.  Measured 2026-09-28:

    index   pixels   what it is in every KP_RD*_P
    ------  -------  --------------------------------------------------
      0      22809   transparent
     24       3437   (31,31,31) - the white arc core
     48-57     ~440  a grey ramp (ALT4's is faintly teal) - the fringe
     63       5742   (1,15,31) - THE COLOUR.  60% of the lit pixels

So one slot carries the hue, and `MKGUYS.ASM`'s comment naming [62] and [63] is
off: 62 is not drawn at all.

**AND IT IS THE SAME BLUE IN ALL FIVE COSTUMES**, which is why a red Raiden
threw red lightning, fried the other man red - and crackled BLUE (the user,
2026-09-28).  `data/MK2PALS.IMG` was authored with one crackle blue for every
lane.

MIDWAY'S OWN RAIDEN COSTUMES DISAGREE, AND THEY ARE STILL IN THE TREE.  Every
palette `raiden_costume_pal` used to name outright differs from the others in
**slot 63 and nowhere else the crackle draws**:

    RADBLU_P   ( 6,25,31) blue     RADALT_P   ( 9, 1,31) violet
    RADALT2_P  ( 3, 0,31) violet   RADWHI_P   ( 9, 1,31) violet
    RADALT4_P  (18, 5,31) PURPLE   RADRED_P   (31, 3, 1) RED

The crackle colour was always per-costume; it was lost when
`make_costume_palettes.py` repointed `character_palettes_1..7` at MK2PALS.IMG.
So the two new colours are LIFTED, not invented: `RADRED_P`'s slot 63 for the
red lane and `RADALT4_P`'s for the purple ones - and both match the hue of the
bolt palette they are paired with (`ELECRED_P` is R=31 dominant, `ELECPRL_P` is
R above G with B high).

The default lane keeps MK2PALS' own blue, so nothing changes for the costume
that was already right.

WHAT THIS WRITES: `src/RDCRACK.ASM`, one palette per non-blue lane - a copy of
that lane's costume palette with the colour slot replaced.  Copies, not
aliases, and the white core and the grey fringe are left exactly as the costume
has them, so the crackle keeps its own shading.  The blue lanes name the costume
palette itself (`raiden_crackle_offer`, MKGUYS.ASM), so a repaint in IMGTOOL
still moves them.

    python tools/make_raiden_crackle_palettes.py           # report only
    python tools/make_raiden_crackle_palettes.py --apply   # write src/RDCRACK.ASM
    python tools/make_raiden_crackle_palettes.py --check   # Phase D: fail on drift
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "RDCRACK.ASM"
COSTPAL = ROOT / "src" / "COSTPAL.ASM"
MKGUYS = ROOT / "src" / "MKGUYS.ASM"
IMGPAL3 = ROOT / "src" / "IMGPAL3.ASM"
MKRD = ROOT / "src" / "MKRD.ASM"
BOLTTBL = ROOT / "src" / "MKBOLTS.TBL"

NL = "\n"
ENTRIES = 64                    # the art indexes 63, so nothing shorter will do

# A slot is THE COLOUR if it is saturated and carries a real share of the lit
# pixels.  Both tests matter: the white core is unsaturated, and the fringe is
# faintly tinted on one costume but is a few per cent of the pixels.
SAT_MIN = 6                     # max channel - min channel, out of 31
SHARE_MIN = 0.05                # of the lit (non-transparent) pixels

# lane -> (the costume palette it wears, the crackle colour it should carry,
#          where that colour comes from).  Parallel to costume_offer /
#          raiden_elec_offer / shock_elec_colours (MKGUYS.ASM) - same lanes,
#          same order - and the blue rows are NOT generated: they name the
#          costume palette itself.
LANES = [
    ("default",         "KP_RDMAIN_P", None,           None),
    ("start + high punch", "KP_RDALT1_P", "RDCRK_ALT1_P", "RADRED_P"),
    ("start + low punch",  "KP_RDALT2_P", "RDCRK_ALT2_P", "RADALT4_P"),
    ("start + high kick",  "KP_RDALT3_P", "RDCRK_ALT3_P", "RADALT4_P"),
    ("start + low kick",   "KP_RDALT4_P", "RDCRK_ALT4_P", "RADALT4_P"),
    ("start + block",   "KP_RDMAIN_P", None,           None),
]

# where each source palette's words live (both are still linked, and both are
# hand-carried, so --check compares words and would catch a repaint)
SOURCE_FILE = {"RADRED_P": MKGUYS, "RADALT4_P": MKGUYS}


def rgb(w: int) -> tuple[int, int, int]:
    return ((w >> 10) & 31, (w >> 5) & 31, w & 31)


def sat(w: int) -> int:
    c = rgb(w)
    return max(c) - min(c)


def parse_pal(text: str, name: str) -> list[int] | None:
    m = re.search(r"^" + re.escape(name) + r":[ \t]*\n"
                  r"(?:^[ \t]*;[^\n]*\n)*"
                  r"^[ \t]*\.word[ \t]+(\d+)[ \t]*\n"
                  r"((?:^[ \t]*\.word[^\n]*\n)+)", text, re.M)
    if not m:
        return None
    out = []
    for tok in re.findall(r"0?[0-9A-Fa-f]+[Hh]|\b\d+\b", m.group(2)):
        out.append(int(tok[:-1], 16) if tok[-1] in "hH" else int(tok, 10))
    return out


def crackle_pieces() -> list[str]:
    """Every piece of the six ambient lanes a_rn1bolt..a_rn6bolt."""
    txt = MKRD.read_text(errors="replace")
    lanes = re.findall(r"^a_rn[1-6]bolt\s*\n((?:\s*\.long[^\n]*\n)+)", txt, re.M)
    frames = {n for body in lanes
              for n in re.findall(r"\b(RN[1-6]BOLT\d+)\b", body)}
    pieces: set[str] = set()
    for m in re.finditer(r"^(RN[1-6]BOLT\d+)\s*\n((?:\s*\.long[^\n]*\n)+)", txt, re.M):
        if m.group(1) in frames:
            pieces.update(re.findall(r"\b(RN[1-6]BOLT\d+[A-Z])\b", m.group(2)))
    return sorted(pieces)


def art_histogram() -> collections.Counter:
    """Palette index -> pixel count, decoded out of the built video ROM."""
    spec = importlib.util.spec_from_file_location(
        "_audit", str(ROOT / "tools" / "audit_sprite_bpp.py"))
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    rom, _ = audit.build_video_rom(str(ROOT / "data"))

    recs = {}
    pat = re.compile(r"^([A-Z0-9_]+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)\s*\n"
                     r"\s*\.long\s+0?([0-9a-fA-F]+)[Hh]\s*\n\s*\.word\s+0?([0-9A-Fa-f]+)[Hh]",
                     re.M)
    for m in pat.finditer(BOLTTBL.read_text(errors="replace")):
        recs[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(6), 16),
                            int(m.group(7), 16))

    hist: collections.Counter = collections.Counter()
    for label in crackle_pieces():
        if label not in recs:
            print("%s: no record in %s" % (label, BOLTTBL.name))
            continue
        w, h, sag, ctrl = recs[label]
        # MOST OF THESE RECORDS ARE COMPRESSED, and a plain bpp-at-a-time read
        # of one is garbage that still looks like a histogram: the first cut of
        # this tool read 62 and 60 and 38 as "colours" and picked slot 15.  Each
        # row of a compressed record opens with a byte of lead/trail skips,
        # shifted by the record's own ldx/trx - the decoder in
        # tools/extract_bolt_paths.py, which this mirrors.
        bpp = (ctrl >> 12) & 7 or 8
        comp = bool(ctrl & 0x80)
        ldx, trx = (ctrl >> 8) & 3, (ctrl >> 10) & 3
        br = audit.BitReader(rom, sag)
        for _ in range(h):
            if comp:
                hdr = br.read(8)
                if hdr is None:
                    break
                lead, trail = (hdr & 0x0F) << ldx, (hdr >> 4) << trx
                n = w - lead - trail
                if n < 0:
                    break
                hist[0] += w - n
                for _ in range(n):
                    v = br.read(bpp)
                    if v is None:
                        break
                    hist[v] += 1
            else:
                for _ in range(w):
                    v = br.read(bpp)
                    if v is None:
                        break
                    hist[v] += 1
    return hist


def colour_slots(hist: collections.Counter, pal: list[int]) -> list[int]:
    lit = sum(n for i, n in hist.items() if i)
    out = []
    for idx, n in sorted(hist.items()):
        if idx == 0 or idx >= len(pal):
            continue
        if sat(pal[idx]) >= SAT_MIN and n >= lit * SHARE_MIN:
            out.append(idx)
    return out


def block(name: str, words: list[int], notes: list[str]) -> str:
    rows = ["\t.word\t" + ",".join("0%04XH" % w for w in words[i:i + 8])
            for i in range(0, len(words), 8)]
    return ("\t.globl\t%s\n%s:\n%s\n\t.word\t %d\n%s\n"
            % (name, name, NL.join("\t; " + t for t in notes),
               len(words), NL.join(rows)))


def generate(pals: dict[str, list[int]], slots: list[int]) -> str:
    head = [
        "; GENERATED by tools/make_raiden_crackle_palettes.py - do not edit by hand.",
        ";",
        "; THE AMBIENT CRACKLE OVER RAIDEN'S BODY, IN THE COLOUR OF HIS CURRENT.",
        "; The RN*BOLT art is painted against the COSTUME layout (ELEC_P has 53",
        "; entries and the art indexes 63), so the crackle wears a costume palette",
        "; and its hue is slot %s of it - measured off the art, not assumed."
        % ", ".join(str(s) for s in slots),
        ";",
        "; data/MK2PALS.IMG gave all five Raiden costumes the SAME crackle blue, so",
        "; a red Raiden crackled blue.  Each palette here is a copy of one costume",
        "; with that slot set to Midway's own crackle colour for this current -",
        "; RADRED_P's for red, RADALT4_P's for purple, both still linked in",
        "; src/MKGUYS.ASM.  The white arc core and the grey fringe are left exactly",
        "; as the costume has them.",
        ";",
        "; The BLUE lanes are not here: raiden_crackle_offer (MKGUYS.ASM) names the",
        "; costume palette itself, so a repaint in IMGTOOL still moves them.",
        "\t.FILE \"rdcrack.asm\"",
        "\t.OPTION B,D,L,T",
        "",
    ]
    body = []
    for who, costume, sym, src in LANES:
        if sym is None:
            continue
        words = list(pals[costume])
        colour = pals[src][slots[0]]
        for s in slots:
            words[s] = colour
        c = rgb(colour)
        body.append(block(sym, words, [
            "%s - %s" % (sym, who),
            "%s with slot%s %s = %s's (%d,%d,%d)"
            % (costume, "" if len(slots) == 1 else "s",
               ",".join(str(s) for s in slots), src, c[0], c[1], c[2]),
        ]))
    return NL.join(head) + NL + NL.join(body)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    rc = 0
    texts = {COSTPAL: COSTPAL.read_text(encoding="latin-1"),
             MKGUYS: MKGUYS.read_text(encoding="latin-1"),
             IMGPAL3: IMGPAL3.read_text(encoding="latin-1")}

    # the costume palettes this build really links, and the two source palettes
    pals: dict[str, list[int]] = {}
    for name in sorted({c for _, c, _, _ in LANES}):
        p = parse_pal(texts[COSTPAL], name)
        if p is None:
            print("%s: not in %s - has make_costume_palettes.py run?"
                  % (name, COSTPAL.name))
            return 1
        pals[name] = p
    for name, where in SOURCE_FILE.items():
        p = parse_pal(texts[where], name)
        if p is None:
            print("%s: not in %s - the authored crackle colour is gone"
                  % (name, where.name))
            return 1
        pals[name] = p

    for name, p in pals.items():
        if len(p) != ENTRIES:
            print("%s: %d entries, the crackle art indexes 63" % (name, len(p)))
            rc = 1

    # WHICH SLOT IS THE COLOUR - measured off the art every run
    hist = art_histogram()
    lit = sum(n for i, n in hist.items() if i)
    slots = colour_slots(hist, pals["KP_RDMAIN_P"])
    print("the crackle draws %d lit pixels over %d pieces; indices:"
          % (lit, len(crackle_pieces())))
    for idx, n in sorted(hist.items()):
        if idx == 0:
            continue
        c = rgb(pals["KP_RDMAIN_P"][idx]) if idx < ENTRIES else (0, 0, 0)
        print("  %2d  %6d px  %4.1f%%  default costume (%2d,%2d,%2d)  sat %2d%s"
              % (idx, n, 100.0 * n / lit, c[0], c[1], c[2],
                 sat(pals["KP_RDMAIN_P"][idx]), "   <- THE COLOUR"
                 if idx in slots else ""))
    if not slots:
        print("no slot in the art is both saturated and %d%% of the pixels - the "
              "art or the costume palette has changed" % int(SHARE_MIN * 100))
        return 1

    # THE COSTUMES REALLY DO ALL CARRY ONE BLUE - the thing being fixed.  Worth
    # printing rather than asserting: authoring a per-costume crackle in IMGTOOL
    # is a legitimate way to solve this, and then these rows would differ.
    seen = {}
    for who, costume, sym, src in LANES:
        seen.setdefault(rgb(pals[costume][slots[0]]), []).append(costume)
    print("slot %d across the costumes: %s" % (slots[0], "; ".join(
        "%s %s" % (c, ",".join(dict.fromkeys(v))) for c, v in seen.items())))
    for name in ("RADRED_P", "RADALT4_P"):
        print("  %s slot %d = %s (Midway's own)"
              % (name, slots[0], rgb(pals[name][slots[0]])))

    # the offer table has to stay parallel to costume_offer
    want = [sym or costume for _, costume, sym, _ in LANES]
    m = re.search(r"^raiden_crackle_offer\s*\n((?:[ \t]*(?:\.long|\.if|\.endif)[^\n]*\n)+)",
                  texts[MKGUYS], re.M)
    if not m:
        print("MKGUYS.ASM: no raiden_crackle_offer table")
        rc = 1
    else:
        have = re.findall(r"\.long\s+([A-Za-z_][A-Za-z0-9_]*)", m.group(1))
        if have[:len(want)] != want:
            print("MKGUYS.ASM raiden_crackle_offer disagrees with this tool:")
            for i, (h, w) in enumerate(zip(have + [None] * len(want), want)):
                if h != w:
                    print("  lane %d: %s, expected %s" % (i, h, w))
            rc = 1
        else:
            print("raiden_crackle_offer matches the lanes - %d rows" % len(want))

    text = generate(pals, slots)

    # each generated palette differs from its costume ONLY in the colour slots
    for who, costume, sym, src in LANES:
        if sym is None:
            continue
        got = parse_pal(text, sym)
        diff = [i for i in range(ENTRIES) if got[i] != pals[costume][i]]
        if diff != slots and diff != []:
            print("%s differs from %s at %s, not just the colour slots %s"
                  % (sym, costume, diff, slots))
            rc = 1
    print("%d palettes, each a copy of its costume with slot %d moved"
          % (sum(1 for _, _, s, _ in LANES if s), slots[0]))

    cur = OUT.read_text(encoding="latin-1") if OUT.exists() else None
    if cur == text:
        print("src/RDCRACK.ASM OK")
    elif a.apply:
        OUT.write_text(text, encoding="latin-1", newline="")
        print("wrote src/RDCRACK.ASM")
    else:
        print("src/RDCRACK.ASM is %s - run "
              "tools/make_raiden_crackle_palettes.py --apply"
              % ("missing" if cur is None else "stale"))
        rc = 1

    return rc


if __name__ == "__main__":
    sys.exit(main())
