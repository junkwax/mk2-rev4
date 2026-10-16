"""rd11font text the way stringer (DIAGTEXT.ASM) lays it, for the profile
previews (tools/make_upprof.py --preview): glyphs out of data/MKFONT.IMG's
vfont* records, advance = glyph width + 2, space = 'H' width/2 + 2, a line =
'H' height * 1.5, a 1px black shadow down-right.  And the bios themselves,
read out of MKAMODE.ASM's pf_<who>_title/bio1/bio2 strings."""
from __future__ import annotations

import re
from pathlib import Path

from make_stonecrk_img import read_img

ROOT = Path(__file__).resolve().parent.parent


class Font:
    ORD = {"!": "exc", '"': "quo", "#": "num", "$": "dol", "%": "per", "&": "and",
           "'": "app", "(": "pr1", ")": "pr2", "*": "ast", "+": "pls", ",": "com",
           "-": "min", ".": "period", "/": "slash", ":": "col", ";": "sem",
           "<": "les", "=": "equ", ">": "grt", "?": "que"}

    def __init__(self):
        imgs, _ = read_img(ROOT / "data" / "MKFONT.IMG")
        self.g = {n[5:]: r for n, r in imgs.items() if n.startswith("vfont")}
        h = self.g["H"]
        self.space = h["w"] // 2
        self.line = h["h"] + h["h"] // 2

    def glyph(self, c):
        return None if c == " " else self.g.get(self.ORD.get(c, c.upper()))

    def width(self, s):
        x = 0
        for c in s:
            g = self.glyph(c)
            x += (self.space if g is None else g["w"]) + 2
        return x - 2 if s else 0

    def draw(self, px, s, x, y, rgb, center=False, w=400, h=254):
        for li, line in enumerate(s.split("\n")):
            cx = x - self.width(line) // 2 if center else x
            cy = y + li * self.line
            for c in line:
                g = self.glyph(c)
                if g is None:
                    cx += self.space + 2
                    continue
                gx, gy = cx - g["ax"], cy - g["ay"]
                for sh, col in ((1, (0, 0, 0)), (0, rgb)):
                    for yy, row in enumerate(g["px"]):
                        for xx, i in enumerate(row):
                            qx, qy = gx + xx + sh, gy + yy + sh
                            if i and 0 <= qx < w and 0 <= qy < h:
                                px[qx, qy] = col
                cx += g["w"] + 2


def bios():
    src = (ROOT / "src" / "MKAMODE.ASM").read_text(errors="replace")
    out = {}
    for m in re.finditer(r"^pf_(\w+)_(title|bio1|bio2)\n(.*?)\.byte\s+0", src, re.M | re.S):
        who, part, body = m.groups()
        text = "".join(s.replace("\\n", "\n") for s in re.findall(r'\.string\s+"(.*)"', body))
        out.setdefault(who, {})[part] = text.rstrip("\n")
    return out
