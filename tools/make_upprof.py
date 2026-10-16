#!/usr/bin/env python3
"""
THE ATTRACT CHARACTER PROFILES, REDRAWN AROUND data/UPPROF.IMG - WOLF ONLY.

Retail's profile (show_next_bio, MKAMODE.ASM) is one layout - STORY1's 138x158
portrait well, the nameplate under it, the text panel to the right - with the
portrait unzipped from the movie pool.  UPPROF.IMG's ten paintings come in two
shapes, so this lays two screens out of STORY1's OWN tiles (stone, cracks,
panel fill, the eight bevel pieces - already packed by data/WSTORY.LOD, so no
new background art), and the paintings are packed by data/UPPROF.LOD.

  TALL  121x158 (Liu Kang, Mileena, Reptile, Scorpion, Baraka)
  WIDE  171x111 (Cage, Jax, Kitana, Raiden, Sub-Zero)

Every profile: the text panel keeps retail's 187px text width (so no bio is
re-broken) and is flush RIGHT, MARGIN in from the side, but is only as TALL as
its own bio - no empty lines - so each fighter gets a layout of his own.  The
panel and the portrait + nameplate column are each centred top to bottom on
the screen.  The WIDE column sits at the left MARGIN, GAP of stone short of
the panel; the TALL one is centred across that open stone.

THE BLOCKS NEVER CLIP, because a BDB block cannot.  An edge or fill longer
than its run is pulled back to end flush and OVERLAPS the piece before it (the
step STORY1 itself uses); a run SHORTER than one piece - the nameplate's 25px
sides and fill - takes a header with a smaller HEIGHT and the same SAG, which
the DMA reads as the image's top rows (rows are read in order, so that holds
for a compressed image too).  Nothing is cropped across.  The stone is laid
under everything at the lowest z; tiles wholly inside a well are left out.
The paintings have no index-0 pixel, so the stone under the portrait well is
covered.

Writes src/UPPROF.ASM (`.if wunit`): the paintings' palettes (under the IMG's
own names, which the PON> records name), one block module per profile on a copy of
WSTORY.ASM's STORY1 headers (WY1HDRS) plus the three crops, and upprof_table,
which show_next_bio reads per bio index (0 = no new profile).

    python tools/make_upprof.py --apply     write src/UPPROF.ASM (Phase B2d9e)
    python tools/make_upprof.py --check     it is current (Phase D)
    python tools/make_upprof.py --preview   render tmp/upprof_preview/ FROM THE
                                            BLOCK LISTS (what the ROM draws)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_stonecrk_img import read_img            # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "UPPROF.IMG"
WSTORY = ROOT / "src" / "WSTORY.ASM"
OUT = ROOT / "src" / "UPPROF.ASM"
TBL = ROOT / "src" / "UPPROF.TBL"
AMODE = ROOT / "src" / "MKAMODE.ASM"

W, H = 400, 254

# show_next_bio's index (c_amode_bio, ochar order) -> (portrait record, pf_ prefix)
BIOS = {
    1: ("LIUPROF_vda", "lk"), 2: ("CAGEPROF_vda", "jc"), 3: ("UGPROF_vda", "sa"),
    4: ("KITPROF_vda", "fn1"), 5: ("MILPROF_vda", "fn2"), 7: ("RADPROF_vda", "rd"),
    8: ("SUBPROF_vda", "sz"), 9: ("REPPROF_vda", "rp"), 10: ("SCRPROF_vda", "sc"),
    11: ("JAXPROF_vda", "jx"),
}
NBIOS = 12                     # show_next_bio cycles 0..11; 0 (Kung Lao) and 6 (Shang) have no painting yet

# WY1HDRS index (STORY1.BDD's image order)
STONE, CRACK_A, CRACK_B, LEFT, TL, BL, TOP, FILL, BOT, BR, RIGHT, TR = range(12)
FILL_NP, LEFT_NP, RIGHT_NP = 12, 13, 14       # crops appended: the nameplate's 25 rows

# block z (the flags' high byte); low byte 40h | palette (Y1PALS: 0 DARKBLU, 1 BLUSTUF, 2 STONE3)
Z_STONE, Z_CRACK, Z_FILL, Z_EDGE, Z_CORNER = 0x32, 0x33, 0x3B, 0x3C, 0x40

TEXT_PAD = 5                    # text panel padding, all four sides
TEXT_W = 184                    # widest bio line + its 1px shadow (checked in layouts())
TEXT_IW = TEXT_W + 2 * TEXT_PAD  # text panel width, inner (retail's was 187)
LINE = 16                       # rd11font line: 'H' 11px * 1.5
GLYPH_H = 13                    # tallest glyph (J, Q: 12) + its 1px shadow
NAMEPLATE_IH = 25               # retail's nameplate, inner
MARGIN = 7                      # stone outside the boxes, left and right
GAP = 5                         # stone between a WIDE portrait and the panel
TEXT_TOP = TEXT_PAD             # panel inner top -> first line of text
TEXT_LEFT = TEXT_PAD            # panel inner left -> text
PANEL_X = W - MARGIN - (TEXT_IW + 8)
BIO1_LINES = 5                  # every bio1 is 5 lines - retail's own split
BIO2_DY = BIO1_LINES * LINE     # 050h, where retail put every bio2


# bios whose text panel is drawn exactly as tall as the portrait + nameplate
# column beside it (Scorpion, the user's call 2026-10-10), the text centred in it
MATCH_COLUMN = {"sc"}


def panel_ih(lines):
    """Inner height of a panel holding `lines` lines: TEXT_TOP above the
    first, the last line's glyphs + shadow, TEXT_TOP again below."""
    return TEXT_TOP + (lines - 1) * LINE + GLYPH_H + TEXT_TOP

CRACKS = [(CRACK_A, 6, 160), (CRACK_B, 364, 6), (CRACK_A, 372, 226), (CRACK_B, 120, 222),
          (CRACK_A, 190, 0), (CRACK_B, 18, 200), (CRACK_A, 60, 230)]


# ---------------------------------------------------------------- headers

def story1_headers():
    """WSTORY.ASM's WY1HDRS: [(w, h, sag, ctrl)] in STORY1.BDD order."""
    text = WSTORY.read_text()
    m = re.search(r"^WY1HDRS:\n(.*?)^\w", text, re.M | re.S)
    if not m:
        sys.exit("make_upprof: no WY1HDRS in src/WSTORY.ASM (run make_wolf_story.py --apply)")
    vals = []
    for line in m.group(1).splitlines():
        line = line.split(";")[0].strip()
        if not line:
            continue
        d, args = line.split(None, 1)
        for a in args.split(","):
            a = a.strip()
            vals.append((d, int(a[:-1], 16) if a.upper().endswith("H") else int(a)))
    hdrs = []
    for i in range(0, len(vals), 4):
        (_, w), (_, h), (_, sag), (_, ctrl) = vals[i:i + 4]
        hdrs.append((w, h, sag, ctrl))
    want = [(52, 50), (28, 25), (16, 28), (4, 74), (4, 4), (4, 4), (60, 4), (48, 57),
            (60, 4), (4, 4), (4, 74), (4, 4)]
    if [(w, h) for w, h, _, _ in hdrs] != want:
        sys.exit(f"make_upprof: WY1HDRS is no longer STORY1's 12 headers in BDD order: {hdrs}")
    w, h, sag, ctrl = hdrs[FILL]
    hdrs.append((w, NAMEPLATE_IH + 1, sag, ctrl))     # +1: the fill's first row is empty
    for k in (LEFT, RIGHT):
        w, h, sag, ctrl = hdrs[k]
        hdrs.append((w, NAMEPLATE_IH, sag, ctrl))
    return hdrs


_PIX = None


def story1_pixels():
    """STORY1.BDD's images in header (BDD) order - the pixels WY1HDRS points at."""
    global _PIX
    if _PIX is None:
        from stage_preview import load_bdd
        imgs, order, _ = load_bdd(ROOT / "data" / "STORY1.BDD")
        _PIX = [imgs[k] for k in order]
    return _PIX


# ---------------------------------------------------------------- layout

class Layout:
    def __init__(self, hdrs, iw, ih, lines, match_column=False):
        self.hdrs = hdrs
        self.blocks = []                       # (z, pal, x, y, hdr)
        self.iw, self.ih = iw, ih
        col_h = (ih + 8) + (NAMEPLATE_IH + 8)  # well + nameplate
        self.ph = panel_ih(lines)
        self.text_dy = 0
        if match_column:                       # the panel spans the column exactly;
            if col_h - 8 < self.ph:            # the text block centred in it
                sys.exit(f"make_upprof: {lines} lines do not fit a {col_h}px panel")
            self.text_dy = (col_h - 8 - self.ph) // 2
            self.ph = col_h - 8
        self.py = (H - (self.ph + 8)) // 2     # panel centred top to bottom
        col_w = iw + 8
        self.left = MARGIN
        if ih > iw:
            self.left = MARGIN + (PANEL_X - GAP - MARGIN - col_w) // 2
        self.top = (H - col_h) // 2           # ...and so is the column
        self.np_y = self.top + 4 + ih + 4
        if self.left + col_w + GAP > PANEL_X:
            sys.exit(f"make_upprof: a {iw}x{ih} portrait does not fit left of the panel")
        wells = [(PANEL_X + 4, self.py + 4, TEXT_IW, self.ph),
                 (self.left + 4, self.top + 4, iw, ih)]
        boxes = [(PANEL_X, self.py, TEXT_IW + 8, self.ph + 8),
                 (self.left, self.top, col_w, ih + 8),
                 (self.left, self.np_y, col_w, NAMEPLATE_IH + 8)]
        sw, sh = self.size(STONE)
        for y in range(0, H, 50):
            for x in range(0, W, 50):
                if not any(wx <= x and x + sw <= wx + ww and wy <= y and y + sh <= wy + wh
                           for wx, wy, ww, wh in wells):
                    self.add(Z_STONE, 1, x, y, STONE)
        for hdr, x, y in CRACKS:
            cw, ch = self.size(hdr)
            if not any(x < bx + bw and bx < x + cw and y < by + bh and by < y + ch
                       for bx, by, bw, bh in boxes):
                self.add(Z_CRACK, 2, x, y, hdr)
        self.box(PANEL_X, self.py, TEXT_IW, self.ph, fill=True)
        self.box(self.left, self.top, iw, ih)
        self.box(self.left, self.np_y, iw, NAMEPLATE_IH, fill=True)

    def size(self, hdr):
        return self.hdrs[hdr][0], self.hdrs[hdr][1]

    def opaque(self, hdr):
        """(ox, oy, w, h) of the header's drawn pixels.  STORY1's pieces carry
        EMPTY margins - the top/bottom edges' last column, the panel fill's
        first row and column - which retail hides under the next piece or the
        bevel.  Laid flush by their full size, those margins showed the stone
        through as a 1px line beside every right-hand corner and inside the
        panel's top and left edges."""
        g = story1_pixels()[hdr if hdr < 12 else (FILL, LEFT, RIGHT)[hdr - 12]]
        w, h = self.size(hdr)
        rows = [y for y in range(h) if any(g["px"][y * g["w"] + x] for x in range(w))]
        cols = [x for x in range(w) if any(g["px"][y * g["w"] + x] for y in range(h))]
        return cols[0], rows[0], cols[-1] - cols[0] + 1, rows[-1] - rows[0] + 1

    def add(self, z, pal, x, y, hdr):
        self.blocks.append((z, pal, x, y, hdr))

    def run(self, hdr, x, y, length, horiz, z=Z_EDGE):
        ox, oy, w, h = self.opaque(hdr)
        piece = w if horiz else h
        if piece > length:
            sys.exit(f"make_upprof: a {length}px run of header {hdr} needs a crop")
        pos = 0
        while True:
            pos = min(pos, length - piece)
            self.add(z, 1, x + pos - ox if horiz else x, y - oy if horiz else y + pos - oy, hdr)
            if pos + piece >= length:
                return
            pos += piece - 1

    def fill(self, hdr, x, y, w, h):
        ox, oy, tw, th = self.opaque(hdr)
        if tw > w or th > h:
            sys.exit(f"make_upprof: a {w}x{h} fill of header {hdr} needs a crop")
        ys = list(range(0, h - th, th)) + [h - th]
        xs = list(range(0, w - tw, tw)) + [w - tw]
        for yy in ys:
            for xx in xs:
                self.add(Z_FILL, 0, x + xx - ox, y + yy - oy, hdr)

    def box(self, x, y, iw, ih, fill=False):
        np = ih == NAMEPLATE_IH
        if fill:
            self.fill(FILL_NP if np else FILL, x + 4, y + 4, iw, ih)
        self.run(TOP, x + 4, y, iw, True)
        self.run(BOT, x + 4, y + 4 + ih, iw, True)
        self.run(LEFT_NP if np else LEFT, x, y + 4, ih, False)
        self.run(RIGHT_NP if np else RIGHT, x + 4 + iw, y + 4, ih, False)
        self.add(Z_CORNER, 1, x, y, TL)
        self.add(Z_CORNER, 1, x + 4 + iw, y, TR)
        self.add(Z_CORNER, 1, x, y + 4 + ih, BL)
        self.add(Z_CORNER, 1, x + 4 + iw, y + 4 + ih, BR)

    # where things go, screen = block coordinates (the module sits at world 0,0)
    def portrait_xy(self):
        return self.left + 4, self.top + 4

    def title_xy(self):
        return self.left + 4 + self.iw // 2, self.np_y + 4 + (NAMEPLATE_IH - 11) // 2

    def bio_xy(self):
        return PANEL_X + 4 + TEXT_LEFT, self.py + 4 + TEXT_TOP + self.text_dy


# ---------------------------------------------------------------- emit

def tbl_hash():
    import hashlib
    return hashlib.sha1(TBL.read_bytes()).hexdigest()[:12] if TBL.exists() else "absent"


def layouts(hdrs, imgs):
    """One Layout per bio index: its painting's shape, its bio's line count."""
    import upprof_text
    text = upprof_text.bios()
    lay = {}
    for i, (rec, who) in BIOS.items():
        b = text[who]
        n1 = b["bio1"].count("\n") + 1
        if n1 != BIO1_LINES:
            sys.exit(f"make_upprof: pf_{who}_bio1 is {n1} lines - bio 2 is drawn {BIO1_LINES} lines down")
        font = upprof_text.Font()
        widest = max(font.width(l) for l in (b["bio1"] + "\n" + b["bio2"]).split("\n")) + 1
        if widest > TEXT_W:
            sys.exit(f"make_upprof: a pf_{who} line is {widest}px with its shadow - the panel holds {TEXT_W}")
        r = imgs[rec]
        lay[i] = Layout(hdrs, r["w"], r["h"], n1 + b["bio2"].count("\n") + 1,
                        match_column=who in MATCH_COLUMN)
    return lay


def emit():
    hdrs = story1_headers()
    imgs, pals = read_img(IMG)
    bypal = {p["palnum"]: (n, p["words"]) for n, p in pals.items()}
    shapes = {}
    for _, (rec, _) in BIOS.items():
        r = imgs[rec]
        shapes.setdefault("tall" if r["h"] > r["w"] else "wide", (r["w"], r["h"]))
    for _, (rec, _) in BIOS.items():
        r = imgs[rec]
        if (r["w"], r["h"]) != shapes["tall" if r["h"] > r["w"] else "wide"]:
            sys.exit(f"make_upprof: {rec} is {r['w']}x{r['h']} - one size per shape")
    lay = layouts(hdrs, imgs)

    o = []
    o += ["**************************************************************************",
          "*  GENERATED by tools/make_upprof.py --apply - do not edit by hand.      *",
          "*                                                                        *",
          "*  The attract character profiles around data/UPPROF.IMG's paintings,    *",
          "*  WOLF ONLY: their palettes, two screens laid out of STORY1's own       *",
          "*  tiles (data/WSTORY.LOD), and upprof_table for show_next_bio.          *",
          "**************************************************************************",
          f"; UPPROF.TBL {tbl_hash()} - a repack changes THIS file (gmake watches only the .ASM)",
          '\t.file\t"upprof.asm"', "\t.width\t132", "\t.option\tb,d,l,t", "\t.mnolist", "",
          "\t.include\tdispequ.asm", "\t.include\tsysequ.asm", "\t.include\tmacros.hdr",
          "\t.include\tmainequ.asm", "", "\t.if\twunit", "\t.globl\tupprof_table", "\t.ref\tY1PALS", "",
          "\t.include\tupprof.tbl\t; the paintings (data/UPPROF.LOD)", "",
          "\t.text", "upp_return", "\trets", "", "\t.data", ""]
    o += ["* per show_next_bio index (c_amode_bio): .long module (0 = no new profile,",
          "* skipped), .long painting, .word x,y painting, .word x,y title (centre),",
          "* .word x,y bio.  160 bits a row.",
          "upprof_table"]
    for i in range(NBIOS):
        if i not in BIOS:
            o.append(f"\t.long\t0,0\t\t\t; {i}")
            o.append("\t.word\t0,0,0,0,0,0")
            continue
        rec, who = BIOS[i]
        L = lay[i]
        (px, py), (tx, ty), (bx, by) = L.portrait_xy(), L.title_xy(), L.bio_xy()
        o.append(f"\t.long\tupp_{who}_mod,{rec}\t; {i} pf_{who}")
        o.append(f"\t.word\t{px},{py},{tx},{ty},{bx},{by}")
    o += ["", "* BGND.ASM's no_scroll (local there): nothing on these screens moves",
          "upp_no_scroll"] + ["\t.long\t0"] * 9 + [""]
    for i, L in sorted(lay.items()):
        k = BIOS[i][1]
        xs = max(x + L.size(h)[0] for _, _, x, _, h in L.blocks)
        ys = max(y + L.size(h)[1] for _, _, _, y, h in L.blocks)
        o += [f"upp_{k}_mod",
              "\t.word\t0\t\t\t; autoerase color", "\t.word\t000h\t\t\t; ground y",
              "\t.word\t0\t\t\t; initial world y", "\t.word\t0\t\t\t; initial worldx",
              "\t.word\t-0500h\t\t\t; scroll left limit", "\t.word\t0500h\t\t\t; scroll right limit",
              "\t.long\tupp_return", "\t.long\tupp_no_scroll\t\t; scroll table",
              "\t.long\tdlists_bogus", "\t.long\tbak1mods", f"\t.long\tUPP{k.upper()}BMOD",
              "\t.word\t0,0", "\t.long\t0ffffffffh", ""]
        o.append(f"UPP{k.upper()}BLKS:")
        for z, pal, x, y, h in sorted(L.blocks, key=lambda b: (b[2], b[3], b[0])):
            o.append(f"\t.word\t0{(z << 8) | 0x40 | pal:04X}H,{x},{y},{h:02X}H")
        o += ["\t.word\t0FFFFH\t;End Marker", f"UPP{k.upper()}BMOD:",
              f"\t.word\t{xs},{ys},{len(L.blocks)}\t;x size, y size, #blocks",
              "\t.long\tUPP{0}BLKS, UPPHDRS, Y1PALS".format(k.upper()), ""]
    o += ["* WSTORY.ASM's WY1HDRS (STORY1.BDD order), then the nameplate's crops:",
          "* the panel fill and the two side edges at 25 rows, on the same SAGs",
          "UPPHDRS:"]
    for i, (w, h, sag, ctrl) in enumerate(hdrs):
        o += [f"\t.word\t{w},{h}\t; {i}", f"\t.long\t0{sag:08X}H", f"\t.word\t0{ctrl:04X}H"]
    o.append("")
    o.append("* the paintings' palettes, under the names their PON> records carry")
    o.append("* (once each: two paintings may share one - SUBPROF_vda is on CAGEPROFP)")
    done = set()
    for _, (rec, _) in sorted(BIOS.items()):
        name, words = bypal[imgs[rec]["palnum"]]
        if name in done:
            continue
        done.add(name)
        o += [f"{name}:", f"\t.word\t{len(words)}"]
        for j in range(0, len(words), 8):
            o.append("\t.word\t" + ",".join(f"0{w:04x}h" for w in words[j:j + 8]))
    o += ["", "\t.endif", ""]
    return "\n".join(o), lay, hdrs


# ---------------------------------------------------------------- preview

def preview(lay, hdrs, out_dir):
    from PIL import Image
    from stage_preview import load_bdd, bgr555
    import upprof_text
    bimgs, order, bpals = load_bdd(ROOT / "data" / "STORY1.BDD")
    pal3 = [p[1] for p in bpals]
    imgs, pals = read_img(IMG)
    bypal = {p["palnum"]: p["words"] for p in pals.values()}
    font, text = upprof_text.Font(), upprof_text.bios()
    out_dir.mkdir(parents=True, exist_ok=True)
    shots = []
    for i, (rec, who) in sorted(BIOS.items()):
        r = imgs[rec]
        L = lay[i]
        im = Image.new("RGB", (W, H), (0, 0, 0))
        px = im.load()
        for z, pal, x, y, h in sorted(L.blocks, key=lambda b: b[0]):
            g = bimgs[order[h if h < 12 else (FILL, LEFT, RIGHT)[h - 12]]]
            hh = hdrs[h][1]                    # the header's own height: a crop reads the top rows
            for yy in range(hh):
                for xx in range(g["w"]):
                    c = g["px"][yy * g["w"] + xx]
                    if c and 0 <= x + xx < W and 0 <= y + yy < H:
                        px[x + xx, y + yy] = bgr555(pal3[pal][c])[:3]
        ox, oy = L.portrait_xy()
        for yy, row in enumerate(r["px"]):
            for xx, c in enumerate(row):
                if c:
                    px[ox + xx, oy + yy] = bgr555(bypal[r["palnum"]][c])[:3]
        b = text[who]
        tx, ty = L.title_xy()
        font.draw(px, b["title"], tx, ty, (248, 248, 0), center=True)
        bx, by = L.bio_xy()
        font.draw(px, b["bio1"], bx, by, (248, 248, 248))
        font.draw(px, b["bio2"], bx, by + BIO2_DY, (248, 248, 248))
        name = rec.split("PROF")[0].lower()
        im.resize((W * 3, H * 3), Image.NEAREST).save(out_dir / f"{name}.png")
        shots.append(im)
    sheet = Image.new("RGB", (W * 2 + 8, (H + 8) * 5), (40, 40, 40))
    for i, im in enumerate(shots):
        sheet.paste(im, ((i % 2) * (W + 8), (i // 2) * (H + 8)))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(out_dir / "sheet.png")
    print("make_upprof: preview ->", out_dir)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apply", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--preview", action="store_true")
    a = ap.parse_args()
    text, lay, hdrs = emit()
    if a.preview:
        preview(lay, hdrs, ROOT / "tmp" / "upprof_preview")
        return
    if a.check:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit("make_upprof: src/UPPROF.ASM is stale - run tools/make_upprof.py --apply")
        print("make_upprof: OK")
        return
    OUT.write_text(text)
    n = {k: len(L.blocks) for k, L in lay.items()}
    print(f"make_upprof: wrote {OUT.relative_to(ROOT)} (blocks: {n})")


if __name__ == "__main__":
    main()
