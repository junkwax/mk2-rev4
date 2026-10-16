#!/usr/bin/env python3
r"""Preview the PALETTE way of hiding Johnny Cage's OTOMIX logo, against the
subframe cut that ships (tools/make_cage_logo.py).  READ-ONLY - renders and
measures, writes nothing but PNGs under tmp/cage_logo_pal/.

The shipping method gives the logo its own PIECE and the walker skips that piece
while he is mirrored, so facing left he is Midway's pixels exactly.  The palette
method instead paints the logo back INTO each piece on palette slots nothing else
uses, and hides it by writing the pants colour into those slots - no extra
pieces, so data/JCLOGO.IMG's 24,628 bytes of bank 0 come back and 174 records and
their frame-list entries go away.

It costs three things, all measured here:

  1. slots have to be FREED, by merging colour pairs that are near-identical in
     every palette Cage can wear.  That repaints a share of his OTHER pixels -
     both facings, all the time.
  2. only the LETTERING gets slots.  The dark halo the letters are drawn with
     sits within a few steps of the pants already, so it stays put and shows as
     a faint residue when the logo is hidden.
  3. rare stray colours in the lettering (a handful of pixels each) are
     re-quantised onto the nearest slot, so the visible logo shifts slightly.

Panels per piece: painted today | palette-visible | palette-hidden | retail
(what the shipping cut shows when he faces left).

    python tools/cage_logo_pal_preview.py                  # measure + sheets
    python tools/cage_logo_pal_preview.py --slots 6        # slots per layout
    python tools/cage_logo_pal_preview.py --only JCSTANCE  # name prefixes
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import cage_logo_scan as scan                         # noqa: E402
import make_cage_logo as cut                          # noqa: E402
from img_subframe_audit import live_lods, collect     # noqa: E402

OUT = ROOT / "tmp" / "cage_logo_pal"
LAYOUT_OF_PAL = {"CAGE_P": "cage", "JCBLUD1_P": "blud"}
PANTS = {"cage": 0x3F, "blud": 0x32}
RESIDUE_STEPS = 5           # closer than this to the pants: leave it, it is invisible
LETTERS = range(1, 7)       # the grey ramp the lettering is drawn with


def rgb(pal, i):
    return scan.rgb5(pal[i])


def dist(pal, a, b):
    return max(abs(x - y) for x, y in zip(rgb(pal, a), rgb(pal, b)))


def load():
    """Every live Cage piece: its base (retail pants), its logo patch, its layout."""
    used, _o, _p = collect(live_lods())
    patches = cut.read_patches()
    out = []
    for img in sorted(used):
        path = ROOT / "data" / f"{img}.IMG"
        if img == "JCLOGO" or not path.exists():
            continue
        try:
            recs, pals = cut.parse_img(path.read_bytes())
        except Exception:
            continue
        for name in sorted(used[img]):
            r = recs.get(name)
            pal = pals.get(r["palnum"]) if r else None
            if not pal or pal["name"] not in LAYOUT_OF_PAL:
                continue
            out.append(dict(img=img, name=name, rec=r, patch=patches.get(name),
                            layout=LAYOUT_OF_PAL[pal["name"]]))
    return out


def plan_slots(pieces, rom, nslots):
    """Freed slots per layout, and how each logo colour is handled."""
    use = {lay: Counter() for lay in rom}
    seen = {lay: Counter() for lay in rom}
    for p in pieces:
        for row in p["rec"]["px"]:
            use[p["layout"]].update(row)
        if p["patch"]:
            for row in p["patch"]["px"]:
                for v in row:
                    if v:
                        seen[p["layout"]][v] += 1
    plans, maps = {}, {}
    for lay, pals in rom.items():
        pal = pals["CAGE_P" if lay == "cage" else "JCBLUD1_P"]
        # EVERY logo colour gets a slot, so hiding it leaves NOTHING behind: a halo
        # pixel only 3 steps off the pants still reads as a ghost of the lettering
        # on near-black cloth.  The logo's colours are quantised onto the nslots
        # most common ones, and a slot carries its representative's colour out of
        # whichever palette he is wearing - so the freeze and shock palettes follow
        # on their own, with no second table to keep in step.
        letters = sorted(seen[lay], key=lambda v: -seen[lay][v])[:nslots]
        plan = scan.merge_plan(lay, len(letters), pals, use[lay])
        slots = [drop for _keep, drop, _w, _m in plan][:len(letters)]
        mapping, qerr = {}, Counter()
        for v, n in seen[lay].items():
            near = min(letters, key=lambda g: dist(pal, v, g))
            mapping[v] = slots[letters.index(near)]
            qerr[dist(pal, v, near)] += n
        plans[lay] = dict(plan=plan, merge={d: k for k, d, _w, _m in plan},
                          letters=letters, slots=slots, qerr=qerr,
                          use=use[lay], seen=seen[lay])
        maps[lay] = mapping
    return plans, maps


def build(piece, plans, maps):
    """(painted today, palette-visible, palette-hidden) pixel grids."""
    lay, r, pat = piece["layout"], piece["rec"], piece["patch"]
    merge = plans[lay]["merge"]
    mapping = maps[lay]
    painted = [row[:] for row in r["px"]]
    if pat:
        ox, oy = r["ax"] - pat["ax"], r["ay"] - pat["ay"]
        for cy in range(pat["h"]):
            for cx in range(pat["w"]):
                if pat["px"][cy][cx]:
                    painted[oy + cy][ox + cx] = pat["px"][cy][cx]
    vis = [[merge.get(v, v) for v in row] for row in r["px"]]      # merges on the base
    if pat:
        ox, oy = r["ax"] - pat["ax"], r["ay"] - pat["ay"]
        for cy in range(pat["h"]):
            for cx in range(pat["w"]):
                v = pat["px"][cy][cx]
                if v:
                    vis[oy + cy][ox + cx] = mapping.get(v, merge.get(v, v))
    hid = [row[:] for row in vis]
    slots = set(plans[lay]["slots"])
    for y, row in enumerate(hid):
        for x, v in enumerate(row):
            if v in slots:
                hid[y][x] = PANTS[lay]
    return painted, vis, hid


def measure(pieces, plans, maps, rom):
    print("PALETTE METHOD, measured against the subframe cut that ships\n")
    for lay in ("cage", "blud"):
        P = plans[lay]
        pal = rom[lay]["CAGE_P" if lay == "cage" else "JCBLUD1_P"]
        tot = sum(P["use"].values())
        moved = sum(P["use"][d] for d in P["merge"])
        worst = max(w for _k, _d, w, _m in P["plan"])
        names = ", ".join(rom[lay])
        print(f"[{lay}] {len(P['slots'])} slots freed by merging {len(P['plan'])} colour pairs")
        print(f"   the merges repaint {moved} of {tot} pixels ({100 * moved / tot:.1f}%) of his other art,")
        print(f"   worst colour error {worst} step(s) of 31, across {names}")
        seen = sum(P["seen"].values())
        q = P["qerr"]
        shifted = sum(n for d, n in q.items() if d)
        print(f"   all {seen} logo pixels sit on those slots, so hiding it leaves nothing behind")
        print(f"   the VISIBLE logo is quantised onto {len(P['letters'])} colours: {shifted} px "
              f"({100 * shifted / seen:.0f}%) shift, worst {max(q)} step(s), "
              f"mean {sum(d * n for d, n in q.items()) / seen:.2f}\n")

    # Hidden vs Midway's own pixels, split: WHERE THE LOGO WAS is what would read
    # as a ghost of the lettering; everywhere else is the merges, which are the
    # same 1-2 steps whether he faces left or right.
    ghost, elsewhere = Counter(), Counter()
    worst_piece = []
    for p in pieces:
        if not p["patch"]:
            continue
        lay = p["layout"]
        pal = rom[lay]["CAGE_P" if lay == "cage" else "JCBLUD1_P"]
        pat = p["patch"]
        ox, oy = p["rec"]["ax"] - pat["ax"], p["rec"]["ay"] - pat["ay"]
        logo_at = {(ox + cx, oy + cy) for cy in range(pat["h"]) for cx in range(pat["w"])
                   if pat["px"][cy][cx]}
        _painted, _vis, hid = build(p, plans, maps)
        retail = p["rec"]["px"]
        n = worstd = 0
        for y, row in enumerate(hid):
            for x, v in enumerate(row):
                d = dist(pal, v, retail[y][x]) if v != retail[y][x] else 0
                if not d:
                    continue
                if (x, y) in logo_at:
                    ghost[lay] += 1
                    n += 1
                    worstd = max(worstd, d)
                else:
                    elsewhere[lay] += 1
        if n:
            worst_piece.append((n, worstd, p["name"]))
    worst_piece.sort(reverse=True)
    print("HIDDEN look vs Midway's own pixels (what the shipping cut shows facing left):")
    print(f"   WHERE THE LOGO WAS: {sum(ghost.values())} px of {sum(len(p['patch']['px']) and 1 or 0 for p in pieces if p['patch']) and ''}"
          f"{sum(sum(1 for row in p['patch']['px'] for v in row if v) for p in pieces if p['patch'])} "
          f"differ - anything here is a ghost of the lettering")
    print(f"   elsewhere in the same pieces: {sum(elsewhere.values())} px, the merges")
    for n, d, name in worst_piece[:6]:
        print(f"   {name:16s} {n:4d} ghost px, worst {d} step(s)")
    if not worst_piece:
        print("   none - the hidden look is pixel-identical")


def sheets(pieces, plans, maps, rom, only, scale=4):
    from PIL import Image, ImageDraw
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("pal_*.png"):
        old.unlink()
    tiles = []
    for p in pieces:
        if not p["patch"]:
            continue
        if only and not any(p["name"].startswith(o) for o in only):
            continue
        lay = p["layout"]
        pal = rom[lay]["CAGE_P" if lay == "cage" else "JCBLUD1_P"]
        painted, vis, hid = build(p, plans, maps)
        # each panel gets the palette the ROM would be holding for it: the freed
        # slots carry the lettering greys while it shows, the pants colour while
        # it is hidden.  Rendering both with the stock palette is what made the
        # logo come out skin-coloured.
        show_pal, hide_pal = list(pal), list(pal)
        for g, slot in zip(plans[lay]["letters"], plans[lay]["slots"]):
            show_pal[slot] = pal[g]
            hide_pal[slot] = pal[PANTS[lay]]
        grids = ((painted, pal), (vis, show_pal), (hid, hide_pal), (p["rec"]["px"], pal))
        w, h = p["rec"]["w"], p["rec"]["h"]
        t = Image.new("RGB", (w * 4 + 12, h + 12), (40, 40, 40))
        for k, (g, gp) in enumerate(grids):
            im = Image.new("RGB", (w, h), (0, 70, 0))
            for y in range(h):
                for x in range(w):
                    if g[y][x]:
                        im.putpixel((x, y), tuple(c * 255 // 31 for c in rgb(gp, g[y][x])))
            t.paste(im, (k * (w + 4), 12))
        ImageDraw.Draw(t).text((1, 0), p["name"], fill=(220, 220, 220))
        tiles.append(t)
    page_w, page, x, y, row_h, pages = 2800 // scale, [], 0, 0, 0, []
    for t in tiles:
        if x + t.width > page_w:
            x, y, row_h = 0, y + row_h + 6, 0
        if y + t.height > 2000 // scale:
            pages.append(page)
            page, x, y, row_h = [], 0, 0, 0
        page.append((t, x, y))
        x += t.width + 10
        row_h = max(row_h, t.height)
    if page:
        pages.append(page)
    for i, pg in enumerate(pages, 1):
        H = max(py + t.height for t, _, py in pg)
        im = Image.new("RGB", (page_w, H), (40, 40, 40))
        for t, px_, py in pg:
            im.paste(t, (px_, py))
        im.resize((im.width * scale, im.height * scale), Image.NEAREST).save(OUT / f"pal_{i:02d}.png")
    print(f"\nsheets: {len(tiles)} pieces on {len(pages)} pages in {OUT.relative_to(ROOT)}"
          f"  (painted today | palette-visible | palette-hidden | retail)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--slots", type=int, default=6)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--no-sheets", action="store_true")
    a = ap.parse_args()
    rom = {lay: {lab: scan.rom_palette(asm, lab) for asm, lab in lst}
           for lay, lst in scan.ROM_PALETTES.items()}
    pieces = load()
    plans, maps = plan_slots(pieces, rom, a.slots)
    measure(pieces, plans, maps, rom)
    if not a.no_sheets:
        sheets(pieces, plans, maps, rom, a.only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
