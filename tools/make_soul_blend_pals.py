#!/usr/bin/env python3
r"""Build src/SOULPAL.ASM - blend palettes for the souls that have no morph art.

Shang's defeat (src/MKSOULS.ASM, doc/MK2_SHANG_SOUL_ESCAPE.md) turns a copy of
him into each fighter through that fighter's MORPH lane: STSTANCE1, three
Shang-into-X blend frames, X.  Retail authored those blends for the eleven
fighters Shang could morph into (st_anitab2 0-11).  Smoke, Noob, Ermac, Jade
and Khameleon came later and have none, but each one is drawn from art that
does: the ninjas are Sub-Zero / Reptile's frames, Jade and Khameleon are
Kitana's.  So their souls borrow that fighter's blend frames, and only the
PALETTE has to be new.

Khameleon's target is KHMAIN_P, the ANCHOR of her disguise cycle
(MKGUYS.ASM kham_disguise_pal_proc) - her own lavender, not one of the three
ninja disguises she changes into during a fight.  Her soul is a soul of HER,
so it wears the colour she is picked in.

The blend palettes are their own quantised mixes (SHZERO_P shares 6 of 61
colours with SUB_P), so an index remap is not available.  Instead every blend
colour that reads as the BASE fighter's costume - saturated, and within
HUE_WINDOW degrees of the base costume's hue - is re-hued onto the target's
costume and its saturation and brightness scaled by the target/base ratio.
Everything else (Shang's skin, hair, robe) is left exactly as authored.

    python tools/make_soul_blend_pals.py           # write src/SOULPAL.ASM
    python tools/make_soul_blend_pals.py --check   # fail if it has drifted (Phase D)
"""
from __future__ import annotations

import argparse
import colorsys
import glob
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "src" / "SOULPAL.ASM"

HUE_WINDOW = 40.0       # degrees either side of the base costume hue
MIN_SAT = 0.18          # below this a colour is grey, not costume

# label -> (base fighter's blend palette, base fighter's own palette, target palette)
SOULS = [
    ("SOULSMK_P", "SHZERO_P", "SUB_P", "smoke_p", "Smoke - Sub-Zero's blend frames"),
    ("SOULNOB_P", "SHZERO_P", "SUB_P", "NOOBDEF_P", "Noob Saibot - Sub-Zero's blend frames"),
    ("SOULERM_P", "REPTILE", "REP_P", "ERMAC_P", "Ermac - Reptile's blend frames"),
    ("SOULJAD_P", "SHBLU_P", "KATBLU_P", "JDALTHP_P", "Jade - Kitana's blend frames"),
    ("SOULKHM_P", "SHBLU_P", "KATBLU_P", "KHMAIN_P", "Khameleon - Kitana's blend frames"),
]


def load_palettes() -> dict[str, list[int]]:
    """every `LABEL: / .word count / .word colours...` record in src/*.ASM"""
    pals: dict[str, list[int]] = {}
    for f in sorted(glob.glob(str(REPO / "src" / "*.ASM"))):
        cur, words = None, []
        for ln in open(f, errors="ignore").read().split("\n"):
            m = re.match(r"^([A-Za-z_]\w*):?\s*(;.*)?$", ln)
            if m and not ln[:1].isspace():
                if cur and words:
                    pals[cur] = words
                cur, words = m.group(1), []
                continue
            m = re.match(r"^\s+\.word\s+(.*)", ln)
            if m and cur:
                for tok in m.group(1).split(";")[0].split(","):
                    tok = tok.strip()
                    try:
                        words.append(int(tok[:-1], 16) if tok[-1:] in "hH" else int(tok, 0))
                    except ValueError:      # an expression, not a colour - not a palette
                        cur = None
                        break
        if cur and words:
            pals[cur] = words
    out = {}
    for k, v in pals.items():
        if v and v[0] + 1 <= len(v):
            out[k] = v[1:1 + v[0]]
    return out


def to_hsv(c):
    return colorsys.rgb_to_hsv(((c >> 10) & 31) / 31, ((c >> 5) & 31) / 31, (c & 31) / 31)


def from_hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h, max(0.0, min(1.0, s)), max(0.0, min(1.0, v)))
    return (round(r * 31) << 10) | (round(g * 31) << 5) | round(b * 31)


def costume(pal):
    """weighted circular-mean hue, mean saturation and mean value of a
    palette's saturated colours - what its costume reads as"""
    xs = ys = wsum = ssum = vsum = 0.0
    n = 0
    for c in pal[1:]:
        h, s, v = to_hsv(c)
        if s < MIN_SAT or v < 0.08:
            continue
        w = s * v
        xs += w * math.cos(2 * math.pi * h)
        ys += w * math.sin(2 * math.pi * h)
        wsum += w
        ssum += s
        vsum += v
        n += 1
    if not n:                         # an all-grey costume (Smoke): no hue
        vals = [to_hsv(c)[2] for c in pal[1:]]
        return None, 0.0, sum(vals) / len(vals)
    hue = (math.atan2(ys, xs) / (2 * math.pi)) % 1.0
    return hue, ssum / n, vsum / n


def hue_dist(a, b):
    d = abs(a - b) % 1.0
    return min(d, 1.0 - d) * 360.0


def blend_for(blend, base, target):
    bh, bs, bv = costume(base)
    th, ts, tv = costume(target)
    tvals = [to_hsv(c)[2] for c in target[1:]]
    tmean = sum(tvals) / len(tvals)
    out = [blend[0]]
    changed = 0
    for c in blend[1:]:
        h, s, v = to_hsv(c)
        if s >= MIN_SAT and bh is not None and hue_dist(h, bh) <= HUE_WINDOW:
            if th is None:            # grey target: drain the colour, keep the ramp
                nh, ns, nv = h, s * 0.12, v * (tmean / max(bv, 1e-3))
            else:
                nh, ns, nv = th, s * (ts / max(bs, 1e-3)), v * (tv / max(bv, 1e-3))
            out.append(from_hsv(nh, ns, nv))
            changed += 1
        else:
            out.append(c)
    return out, changed


def render(pals) -> str:
    lines = [
        "; GENERATED by tools/make_soul_blend_pals.py - do not edit by hand.",
        "; Blend palettes for the souls with no morph art of their own (MKSOULS.ASM):",
        "; the base fighter's Shang-into-X blend palette with its costume colours",
        "; re-hued onto the target's.  See doc/MK2_SHANG_SOUL_ESCAPE.md.",
        '\t.FILE "soulpal.asm"',
        "\t.OPTION B,D,L,T",
        "",
    ]
    for label, *_ in SOULS:
        lines.append("\t.globl\t%s" % label)
    lines += ["\t.DATA", "\t.even", ""]
    for label, blend, base, target, note in SOULS:
        for need in (blend, base, target):
            if need not in pals:
                sys.exit("palette %s not found in src/*.ASM" % need)
        cols, changed = blend_for(pals[blend], pals[base], pals[target])
        lines.append("; %s: %s re-hued from %s onto %s (%d of %d colours)"
                     % (note, blend, base, target, changed, len(cols)))
        lines.append("%s:" % label)
        lines.append("\t.word\t%d" % len(cols))
        for i in range(0, len(cols), 8):
            lines.append("\t.word\t" + ",".join("0%04XH" % c for c in cols[i:i + 8]))
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = render(load_palettes())
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            print("src/SOULPAL.ASM is stale - run python tools/make_soul_blend_pals.py")
            return 1
        print("  soul blend palettes OK")
        return 0
    OUT.write_text(text)
    print("wrote %s" % OUT)
    for line in text.split("\n"):
        if line.startswith("; ") and "re-hued" in line:
            print(" ", line[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
