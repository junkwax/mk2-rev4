#!/usr/bin/env python3
r"""sync_raiden_elec_palettes.py - keep src/IMGPAL4.ASM's ELECTRIC palettes
equal to the records authored in `data/MK2PALS.IMG`.

RAIDEN'S ELECTRICITY IS COLOURED BY WHICH COSTUME HE IS WEARING
(`raiden_electric_pal` / `raiden_elec_offer`, MKGUYS.ASM), and the user's
mapping is one palette per costume lane:

    RDMAIN_P  (the default, Start+BLOCK, Start+COIN)  ->  ELEC_P
    RDALT1_P  (Start + HIGH PUNCH)                    ->  ELECRED_P
    RDALT2_P  (Start + LOW PUNCH / the mirror)        ->  ELECPRL_P
    RDALT3_P  (Start + HIGH KICK)                     ->  ELECPRL_P
    RDALT4_P  (Start + LOW KICK)                      ->  ELECPRL_P

The costumes themselves are carried by tools/make_costume_palettes.py, which
reads the same library.  THE ELECTRIC PALETTES ARE NOT IN ITS SCHEME - they are
effect palettes, not `<XX>ALTn_P` costume records - so they need their own
carry, and this is it.  Both tools reading `data/MK2PALS.IMG` is the point: the
costume and the current in it are recoloured side by side in one library.

`ELECPRL_P` EXISTS ONLY IN MK2PALS.IMG.  `data/RAID8.IMG` carries an
`ELECPUR_P` that is a DIFFERENT purple - 51 entries of 53 differ - so the two
are not each other under another name, and the linked symbol has to be the
MK2PALS one.

WHY A BUILD GATE.  Nothing promotes an IMG palette into the ROM: IMGPAL*.ASM is
hand-maintained, and `data/MK2PALS.IMG` is in no LOD, so LOAD2 never reads it
and no pixel of it reaches a ROM.  A recolour in IMGTOOL would ship the OLD
colours with no error anywhere - the failure `tools/sync_rain_palette.py` and
`tools/make_mk2pals.py` were both written for.  So: edit the palette in
IMGTOOL, re-run this, and Phase D fails the build if anyone forgets.

Records are found by NAME in the library's palette table, never by position,
and the comparison is on the WORDS - a block that already carries the right
colours is left alone whatever its formatting.

    python tools/sync_raiden_elec_palettes.py           # report only
    python tools/sync_raiden_elec_palettes.py --apply   # rewrite from the IMG
    python tools/sync_raiden_elec_palettes.py --check   # Phase D: fail on drift
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                            # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "MK2PALS.IMG"
ASM = ROOT / "src" / "IMGPAL4.ASM"

SHOCK = ROOT / "data" / "MKSHOCK.IMG"

# symbol -> (library, record name in it, which costume lanes wear it - the
# generated comment)
NAMES = {
    "ELEC_P":    (IMG, "ELEC_P", "RDMAIN_P - his default, Start+BLOCK and Start+COIN"),
    "ELECRED_P": (IMG, "ELECRED_P", "RDALT1_P - Start + HIGH PUNCH"),
    "ELECPRL_P": (IMG, "ELECPRL_P", "RDALT2_P/RDALT3_P/RDALT4_P - Start + LP, HK and LK"),
    # THE X-RAY FLASH in his lift fatality (LUBUZZ2, data/LUBUZZ.LOD): the
    # victim drawn as a skeleton in the current, in the SAME pairing as the
    # bolt - MKSHOCK.IMG draws it in all three and rd_lift_buzz (MKRDLIF.ASM)
    # swaps him onto the one Raiden's costume names.  The library calls the
    # purple one BUZZER, so the symbol keeps that name.
    "BUZBLUE_P": (SHOCK, "BUZBLUE", "X-ray flash under RDMAIN_P - his default, Start+BLOCK and Start+COIN"),
    "BUZRED_P":  (SHOCK, "BUZRED", "X-ray flash under RDALT1_P - Start + HIGH PUNCH"),
    "BUZZER_P":  (SHOCK, "BUZZER", "X-ray flash under RDALT2_P/RDALT3_P/RDALT4_P - Start + LP, HK and LK"),
}

# Every one of these has to be in death_fade_excludes (MKGUYS.ASM) or the bolts
# dim with the stage while the fighters stay lit.
FADE_LIST = ROOT / "src" / "MKGUYS.ASM"


def img_words() -> dict[str, list[int]]:
    found: dict[str, list[int]] = {}
    for lib in {src for src, _rec, _c in NAMES.values()}:
        want = {rec: sym for sym, (src, rec, _c) in NAMES.items() if src == lib}
        for name, words in ip.palettes(lib):
            sym = want.get(name)
            if sym and sym not in found:
                found[sym] = list(words)
        missing = sorted(rec for rec, sym in want.items() if sym not in found)
        if missing:
            raise SystemExit("%s: no palette record named %s"
                             % (lib.name, ", ".join(missing)))
    return found


def block(name: str, words: list[int]) -> str:
    rows = ["\t.word\t" + ",".join("0%04XH" % w for w in words[i:i + 8])
            for i in range(0, len(words), 8)]
    src, _rec, note = NAMES[name]
    return ("\t.globl\t%s\n%s:\n\t; %s.  Authored in %s - "
            "tools/sync_raiden_elec_palettes.py.\n\t.word\t %d\n%s\n"
            % (name, name, note, src.name, len(words), "\n".join(rows)))


def pattern(name: str) -> re.Pattern:
    # the optional .globl and comment lines the generated block owns, then the
    # count and its .word rows
    return re.compile(
        r"(?:^\t\.globl\t" + name + r"\s*\n)?"
        r"^" + name + r":[ \t]*\n"
        r"(?:^[ \t]*;[^\n]*\n)*"
        r"^[ \t]*\.word[ \t]+\d+[ \t]*\n"
        r"(?:^[ \t]*\.word[^\n]*\n)+", re.M)


def parse_words(text: str) -> list[int]:
    out: list[int] = []
    for line in text.splitlines():
        s = line.strip()
        if not s.lower().startswith(".word"):
            continue
        for tok in s[5:].split(","):
            tok = tok.strip()
            if not tok:
                continue
            out.append(int(tok[:-1], 16) if tok[-1] in "hH" else int(tok, 10))
    return out[1:]                      # drop the leading colour count


def check_fade_excludes(names) -> int:
    txt = FADE_LIST.read_text(encoding="latin-1")
    start = txt.find("\ndeath_fade_excludes")
    if start < 0:
        print("MKGUYS.ASM: no death_fade_excludes label")
        return 1
    tail = txt[start:]
    rc = 0
    for name in names:
        if not re.search(r"^\t\.long\t" + name + r"\s*$", tail, re.M):
            print("%s: not in death_fade_excludes (MKGUYS.ASM) - it "
                  "would dim with the stage" % name)
            rc = 1
    return rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="rewrite IMGPAL4.ASM")
    ap.add_argument("--check", action="store_true", help="Phase D: fail on drift")
    a = ap.parse_args()

    pals = img_words()
    txt = ASM.read_text(encoding="latin-1")
    rc, wrote = 0, []

    for name in NAMES:
        src = NAMES[name][0]
        m = pattern(name).search(txt)
        if not m:
            print("%s: no block in %s - add one by hand once, then re-run"
                  % (name, ASM.name))
            rc = 1
            continue
        have = parse_words(m.group(0))
        want = pals[name]
        if have == want:
            print("%s OK - %d colours, matches %s" % (name, len(want), src.name))
            continue
        diff = sum(1 for x, y in zip(have, want) if x != y) + abs(len(have) - len(want))
        if a.check or not a.apply:
            print("%s: %s differs from %s by %d of %d - run "
                  "tools/sync_raiden_elec_palettes.py --apply"
                  % (name, ASM.name, src.name, diff, len(want)))
            rc = 1
            continue
        txt = txt[:m.start()] + block(name, want) + txt[m.end():]
        wrote.append("%s (%d of %d)" % (name, diff, len(want)))

    if wrote:
        ASM.write_text(txt, encoding="latin-1", newline="")
        print("rewrote %s" % ", ".join(wrote))

    rc |= check_fade_excludes(NAMES)
    return rc


if __name__ == "__main__":
    sys.exit(main())
