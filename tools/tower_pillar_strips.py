#!/usr/bin/env python3
"""THE TOWER's pillar reflections as STRIPS that lean with the floor and fade
(twrpslice, BGND.ASM) - generates src/TWRPREF.ASM.

The reflection used to be ONE object: the pillar tile (R2HDRS[TWR_PHDR]) drawn
m_flipv at TWR_PSCALE.  One object scrolls at one rate, so it stood bolt
upright while the floor it lies on skews - floor row r scrolls at
scrollx6 * (1 + r/128) (tower_skew_calla) - and it ended on a hard edge.

This cuts it into TWR_PREF_N horizontal strips of TWR_PREF_K reflected lines.
Each strip is the same tile, started at the right source ROW and flipped, so
the picture is unchanged at the start camera; twr_prefl_shear (BGND.ASM) moves
each strip sideways by its floor row's skew every frame, in the display pass
right after floor_code has worked that skew out.  The last strips draw in
PILRF1-3_P, PILREF_P blended toward the marble's mean colour, so the
reflection fades into the floor.

The tile is ZERO-COMPRESSED (dmacmp): every row starts with a lead/trail byte,
so a row's address is not row * width * bpp.  The row offsets are read out of
the packed video ROM here (tools/art_identity_snapshot.py's decoder), which is
why this is a generator and --check is in Phase D.

    python tools/tower_pillar_strips.py --apply
    python tools/tower_pillar_strips.py --check
"""
from __future__ import annotations

import argparse
import importlib.util
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "TWRPREF.ASM"
BGND = ROOT / "src" / "BGND.ASM"
TBL = ROOT / "src" / "BGNDTBL.ASM"
PAL = ROOT / "src" / "BGNDPAL.ASM"

K = 2                       # reflected lines per strip
FADE = [(0.0, 0), (0.30, 1), (0.55, 2), (0.80, 3)]   # (t blend, level) by line
FADE_FROM = 0.62            # fraction of the reflection where the fade starts
WORLDTLY = -14


def mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def num(tok):
    tok = tok.strip()
    return int(tok[:-1], 16) if tok[-1:].lower() == "h" else int(tok)


def bgnd_consts():
    t = BGND.read_text(errors="replace")
    phdr = int(re.search(r"^TWR_PHDR\s+\.set\s+(\d+)", t, re.M).group(1))
    psc = int(re.search(r"^TWR_PSCALE\s+\.set\s+0([0-9A-Fa-f]+)h", t, re.M).group(1), 16)
    anchor = int(re.search(r"^twr_pillar_left\s*\n\s*\.long\s+0([0-9A-Fa-f]{8})h", t, re.M).group(1), 16)
    skew_y = int(re.search(r"^tower_floor_info.*?\.word\s+0?([0-9a-fA-F]+)h\s*;\s*skew y",
                           t, re.M | re.S).group(1), 16)
    return phdr, psc >> 16, anchor >> 16, skew_y


def r2hdr(i):
    t = TBL.read_text(errors="replace")
    body = re.search(r"^R2HDRS:\s*\n(.*?)^\S", t, re.M | re.S).group(1)
    ents = re.findall(r"\.word\s+(\d+)\s*,\s*(\d+).*?\n\s*\.long\s+0?([0-9A-Fa-f]+)H.*?\n\s*\.word\s+0?([0-9A-Fa-f]+)H", body)
    w, h, sag, ctrl = ents[i]
    return int(w), int(h), int(sag, 16), int(ctrl, 16)


def row_offsets(w, h, sag, ctrl):
    """Bit offset of every row's start, relative to sag - walked in the ROM."""
    ais = mod("ais", ROOT / "tools" / "art_identity_snapshot.py")
    mv = mod("mv", ROOT / "makevrom.py")
    rom, _spans = ais.flat_rom(mv)
    bpp = (ctrl >> 12) & 7 or 8
    lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    if not ctrl & 0x80:
        return [r * w * bpp for r in range(h + 1)]
    pos, offs = sag, []
    for _ in range(h):
        offs.append(pos - sag)
        j, sh = divmod(pos, 8)
        hdr = ((rom[j] | rom[j + 1] << 8) >> sh) & 0xff
        lead, trail = (hdr & 15) << lm, (hdr >> 4) << tm
        if lead + trail > w:
            raise SystemExit(f"row header {hdr:02x} does not decode - wrong SAG?")
        pos += 8 + (w - lead - trail) * bpp
    offs.append(pos - sag)
    return offs


def pal_words(text, name):
    m = re.search(rf"^{name}:.*?\n\s*\.word\s+(\d+).*?\n(.*?)(?:\n\s*\n|\n\S)", text, re.M | re.S)
    n = int(m.group(1))
    words = [num(w) for w in re.findall(r"([0-9A-Fa-f]+H)", m.group(2))]
    return words[:n]


def marble_mean():
    """Mean colour of THE TOWER's floor texture (FL_TOW.BIN on CASFLR1_p)."""
    raw = (ROOT / "data" / "FL_TOW.BIN").read_bytes()
    t = BGND.read_text(errors="replace")
    m = re.search(r"^CASFLR1_p:\s*\n\s*\.word\s+(\d+)\s*\n(.*?)\n\s*\n", t, re.M | re.S)
    n = int(m.group(1))
    pal = [num(w) for w in re.findall(r"(0[0-9a-fA-F]+h)", m.group(2))][:n]
    bits = int.from_bytes(raw, "little")
    cnt = len(raw) * 8 // 6
    rs = gs = bs = 0
    for i in range(0, cnt, 7):          # a sample is plenty for a mean
        v = (bits >> (6 * i)) & 63
        c = pal[v] if v < len(pal) else 0
        rs += (c >> 10) & 31; gs += (c >> 5) & 31; bs += c & 31
    k = len(range(0, cnt, 7))
    return rs / k, gs / k, bs / k


def blend(words, mean, t):
    out = [words[0]]                    # entry 0 is transparent - leave it
    for c in words[1:]:
        r, g, b = (c >> 10) & 31, (c >> 5) & 31, c & 31
        r = round(r + (mean[0] - r) * t); g = round(g + (mean[1] - g) * t)
        b = round(b + (mean[2] - b) * t)
        out.append((r << 10) | (g << 5) | b)
    return out


def generate():
    phdr, ystep, anchor_y, skew_y = bgnd_consts()
    w, h, sag, ctrl = r2hdr(phdr)
    offs = row_offsets(w, h, sag, ctrl)
    lines = -(-(h * 0x100) // ystep)                # the DMA ceils a reduction
    step = ystep / 0x100                             # source rows per drawn line
    base_scr = anchor_y - WORLDTLY                   # first reflected line, screen
    strips = []
    j0 = 0
    while j0 < lines:
        k = min(K, lines - j0)
        bot = h - int(j0 * step)                     # one past the band's last row
        top = max(0, h - int((j0 + k) * step))
        ys = bot - top
        drawn = -(-(ys * 0x100) // ystep)
        frac = j0 / lines
        level = 0
        if frac >= FADE_FROM:
            level = 1 + min(2, int((frac - FADE_FROM) / ((1 - FADE_FROM) / 3)))
        strips.append(dict(off=offs[top], ys=ys, dy=j0 - ys + drawn,
                           L=base_scr + j0 - skew_y, level=level))
        j0 += k
    pals = PAL.read_text(errors="replace")
    base = pal_words(pals, "PILREF_P")
    mean = marble_mean()
    fades = [blend(base, mean, t) for t, lv in FADE[1:]]

    o = [f"; GENERATED by tools/tower_pillar_strips.py - do not edit.",
         f"; THE TOWER's pillar reflection as {len(strips)} strips of {K} lines (twrpslice):",
         f"; R2HDRS[{phdr}] {w}x{h} ctrl {ctrl:04X}h, {lines} reflected lines at ystep "
         f"{ystep:X}h, first line on screen {base_scr} = floor row {base_scr - skew_y}.",
         f"; Fade: PILREF_P blended toward the marble mean "
         f"({mean[0]:.1f},{mean[1]:.1f},{mean[2]:.1f}) by " +
         ", ".join(f"{t:.2f}" for t, _ in FADE[1:]) + ".",
         "",
         f"TWR_PREF_N	.set	{len(strips)}",
         "TWR_PREF_SZ	.set	96		; .long row offset, .word ysize, dy, floor row, level",
         "",
         "twr_pref_strips"]
    for s in strips:
        o.append(f"\t.long\t{s['off']}\n\t.word\t{s['ys']},{s['dy']},{s['L']},{s['level']}")
    o.append("")
    o.append("twr_pref_pals\t\t\t; by level")
    o.append("\t.long\tPILREF_P,PILRF1_P,PILRF2_P,PILRF3_P")
    for i, f in enumerate(fades, 1):
        o.append("")
        o.append(f"PILRF{i}_P:")
        o.append(f"\t.word\t{len(f)}")
        for a in range(0, len(f), 10):
            o.append("\t.word\t" + ",".join(f"0{c:04X}H" for c in f[a:a + 10]))
    return "\n".join(o) + "\n", strips, lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text, strips, lines = generate()
    print(f"{lines} lines -> {len(strips)} strips, floor rows "
          f"{strips[0]['L']}..{strips[-1]['L']}, fade levels "
          f"{[s['level'] for s in strips]}")
    have = OUT.read_text() if OUT.exists() else ""
    if a.apply:
        OUT.write_text(text)
        print("wrote", OUT.relative_to(ROOT))
        return 0
    if have != text:
        print("FAIL: src/TWRPREF.ASM is stale - run --apply")
        return 1 if a.check else 0
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
