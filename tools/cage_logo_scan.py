#!/usr/bin/env python3
r"""Find the OTOMIX logo on Johnny Cage's pants in every record the build packs,
and test whether it can be given palette indices of its own.  READ-ONLY.

The goal: hide the logo when Cage is drawn mirrored (it reads backwards) without
drawing new art.  The logo is drawn with palette indices 1-7, the grey ramp, but so
are his sneakers, eye whites, skin glints and outline pixels - so blacking out 1-7
would black out his shoes.  The plan this scan tests:

  1. free a few palette slots by merging colour pairs that are near-identical in
     EVERY palette the ROM can draw Cage with (costume alternates included);
  2. move only the logo's pixels onto the freed indices, which keep the grey values;
  3. at run time, point those entries at the pants colour while `m_fliph` is set.

Two palette layouts exist.  CAGE_P and the six costume palettes share one index
map; JCBLUD1_P/JCBLUD2_P (the bloodied victim art in CAGE10) are packed
differently - pants black is at 0x32, not 0x3f.  Each layout is merged separately.

A grey component (8-connected run of indices 1-7) is classified from what surrounds
it and its shape:
  LOGO   inside the pants - its neighbours are pants-dark, it touches no skin, and
         it is stroke-thin (letters) rather than a solid fill (a shoe)
  EDGE   the logo where it meets the leg's silhouette (touches transparency); hidden too
  MAYBE  close to LOGO but failed one test; NOT hidden, drawn yellow for review
  other  left alone (shoes, skin highlights, outlines)

    python tools/cage_logo_scan.py                  # summary + merge plan
    python tools/cage_logo_scan.py --sheets         # + review sheets in tmp/cage_logo/
    python tools/cage_logo_scan.py --only JCSTANCE  # restrict to record-name prefixes
    python tools/cage_logo_scan.py --features       # per-component feature table (tuning)

Sheets show each piece three times: as authored | components marked (magenta LOGO,
orange EDGE, yellow MAYBE) | what a MIRRORED frame would look like with LOGO/EDGE pixels in the
pants colour.  Nothing in data/ or src/ is written.
"""
from __future__ import annotations

import argparse
import itertools
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from make_stonecrk_img import read_img            # noqa: E402  (pixel-level IMG reader)
from img_subframe_audit import live_lods, collect  # noqa: E402  (what the LODs load)

OUT = ROOT / "tmp" / "cage_logo"
GREYS = range(1, 8)
HIDDEN = ("LOGO", "EDGE")                         # the pixels the plan would re-index
MARKED = {"LOGO": (255, 0, 255), "EDGE": (255, 128, 0), "MAYBE": (255, 255, 0)}

# IMG palette name -> layout.  The ROM palettes that share each layout follow.
LAYOUT_OF_IMG_PAL = {"CAGE_P": "cage", "JCBLUD1_P": "blud"}
ROM_PALETTES = {
    "cage": [("IMGPAL2.ASM", "CAGE_P"), ("MKGUYS.ASM", "CAGERED_P"), ("MKGUYS.ASM", "CAGEPUR_P"),
             ("MKGUYS.ASM", "JCALT1_P"), ("MKGUYS.ASM", "JCALT2_P"), ("MKGUYS.ASM", "JCALT3_P"),
             ("IMGPAL2.ASM", "CAGEP_P"), ("IMGPAL2.ASM", "CAGEALT_P"),        # costume table extras
             ("IMGPAL3.ASM", "JCNUFRZ_P"), ("IMGPAL3.ASM", "JCELEC_P")],      # frozen, electrocuted
    "blud": [("IMGPAL2.ASM", "JCBLUD1_P"), ("MKGUYS.ASM", "JCBLUD2_P")],
}


# ---------------------------------------------------------------- inputs

def rom_palette(asm: str, label: str) -> list[int]:
    """The 64 colour words that follow `label:` and its count word in src/<asm>."""
    text = (ROOT / "src" / asm).read_text(errors="replace").splitlines()
    for i, line in enumerate(text):
        if re.match(rf"^{re.escape(label)}:?\s*(;.*)?$", line):
            words = []
            for l in text[i + 1:]:
                m = re.match(r"^\s*\.word\s+(.*?)\s*(;.*)?$", l)
                if not m:
                    if words:
                        break
                    continue
                for tok in m.group(1).split(","):
                    tok = tok.strip()
                    words.append(int(tok[:-1], 16) if tok.lower().endswith("h") else int(tok, 0))
            if words[0] != len(words) - 1:
                raise SystemExit(f"{label}: count word {words[0]} but {len(words) - 1} colours")
            return words[1:]
    raise SystemExit(f"{label} not found in src/{asm}")


def load_records(only):
    used, _origin, _ppp = collect(live_lods())
    recs = []
    for img in sorted(used):
        path = ROOT / "data" / f"{img}.IMG"
        if not path.exists():
            continue
        try:
            imgs, pals = read_img(path)
        except (UnicodeDecodeError, ValueError, IndexError):
            continue
        by_num = {v["palnum"]: (k, v["words"]) for k, v in pals.items()}
        for name in sorted(used[img]):
            r = imgs.get(name)
            if r is None:
                continue
            pal_name, words = by_num.get(r["palnum"], (None, None))
            if pal_name not in LAYOUT_OF_IMG_PAL:
                continue
            if only and not any(name.startswith(p) for p in only):
                continue
            recs.append(dict(img=img, name=name, pal=pal_name, layout=LAYOUT_OF_IMG_PAL[pal_name],
                             words=words, rec=r))
    return recs


# ---------------------------------------------------------------- classification

def rgb5(w):
    return (w >> 10) & 31, (w >> 5) & 31, w & 31


def neighbour_class(words, c):
    if c == 0:
        return "T"                      # transparent
    if c in GREYS:
        return "G"
    r, g, b = rgb5(words[c])
    if max(r, g, b) <= 5:
        return "D"                      # pants-dark
    if b >= r + 4 and b >= g + 4:
        return "B"                      # blue (waistband, cuffs, wrist)
    return "S"                          # skin / anything else


def components(rec, words):
    w, h, px = rec["w"], rec["h"], rec["px"]
    seen = [[False] * w for _ in range(h)]
    for y0 in range(h):
        for x0 in range(w):
            if seen[y0][x0] or px[y0][x0] not in GREYS:
                continue
            seen[y0][x0] = True
            stack, pts = [(x0, y0)], []
            while stack:
                x, y = stack.pop()
                pts.append((x, y))
                for dx, dy in itertools.product((-1, 0, 1), repeat=2):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and px[ny][nx] in GREYS:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            ps = set(pts)
            nb = Counter()
            for x, y in pts:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if (nx, ny) in ps:
                        continue
                    nb["E" if not (0 <= nx < w and 0 <= ny < h) else neighbour_class(words, px[ny][nx])] += 1
            interior = sum(all((x + dx, y + dy) in ps for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                           for x, y in pts)
            yield dict(pts=pts, n=len(pts), nb=nb, interior=interior / len(pts),
                       light=sum(px[y][x] <= 3 for x, y in pts) / len(pts))


def classify(c):
    nb = c["nb"]
    tot = sum(v for k, v in nb.items() if k != "E") or 1
    d, t, s, b = (nb[k] / tot for k in "DTSB")
    c.update(d=d, t=t, s=s, b=b)
    if c["n"] < 3 or s > 0.25 or b > 0.1:
        return "other"
    # Shoes measure interior >= 0.5 with at most ~56% pants-dark around them; letters
    # are strokes.  A ducking or turned leg foreshortens the logo, so its strokes
    # thicken to ~0.4 - still wholly inside the pants, which a shoe never is.
    # A dark-brown pants fold can read as "skin" by RGB, so a stray S pixel is tolerated.
    if d >= 0.9 and s <= 0.1 and c["interior"] <= 0.45:
        return "LOGO"
    # the logo on the leg's silhouette edge: letters, so still thin, mostly pants around
    if d >= 0.6 and d + t >= 0.9 and s <= 0.1 and c["interior"] <= 0.3 and c["n"] >= 6:
        return "EDGE"
    # an arm or hand crossing the leg: the letters it overlaps touch skin
    if d >= 0.75 and t <= 0.2 and c["interior"] <= 0.3 and c["n"] >= 10:
        return "EDGE"
    if d >= 0.5 and c["interior"] <= 0.5:
        return "MAYBE"
    return "other"


# ---------------------------------------------------------------- merge plan

def dist(a, b):
    return max(abs(x - y) for x, y in zip(rgb5(a), rgb5(b)))


def merge_plan(layout, need, pals, pixel_use):
    """Disjoint (keep, drop) pairs, cheapest worst-case colour error across every ROM
    palette of the layout first.  `drop` pixels are repainted as `keep`."""
    greys = set(GREYS)
    cands = []
    for i, j in itertools.combinations(range(8, 64), 2):
        if i in greys or j in greys:
            continue
        worst = max(dist(p[i], p[j]) for p in pals.values())
        keep, drop = (i, j) if pixel_use[i] >= pixel_use[j] else (j, i)
        cands.append((worst, pixel_use[drop], keep, drop))
    cands.sort()
    taken, plan = set(), []
    for worst, moved, keep, drop in cands:
        if keep in taken or drop in taken:
            continue
        plan.append((keep, drop, worst, moved))
        taken |= {keep, drop}
        if len(plan) == need:
            break
    return plan


# ---------------------------------------------------------------- sheets

def rgb8(w):
    return tuple(v * 255 // 31 for v in rgb5(w))


def sheets(results, scale=2, only_marked=True):
    from PIL import Image
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("sheet_*.png"):
        old.unlink()
    tiles = []
    for res in results:
        if only_marked and not any(k in MARKED for k, _ in res["comps"]):
            continue
        rec, words = res["rec"], res["words"]
        pants = res["pants_index"]
        w, h = rec["w"], rec["h"]
        panels = [Image.new("RGB", (w, h), (0, 70, 0)) for _ in range(3)]
        for y, row in enumerate(rec["px"]):
            for x, c in enumerate(row):
                if c:
                    for p in panels:
                        p.putpixel((x, y), rgb8(words[c]))
        for kind, comp in res["comps"]:
            if kind not in MARKED:
                continue
            col = MARKED[kind]
            for x, y in comp["pts"]:
                panels[1].putpixel((x, y), col)
                if kind in HIDDEN:
                    panels[2].putpixel((x, y), rgb8(words[pants]))
        panels[2] = panels[2].transpose(Image.FLIP_LEFT_RIGHT)
        tile = Image.new("RGB", (w * 3 + 8, h + 12), (40, 40, 40))
        for k, p in enumerate(panels):
            tile.paste(p, (k * (w + 4), 12))
        tiles.append((res["name"], tile))

    from PIL import ImageDraw
    page_w, page, x, y, row_h, n = 2800 // scale, [], 0, 0, 0, 0
    placed = []
    for name, t in tiles:
        if x + t.width > page_w:
            x, y, row_h = 0, y + row_h + 6, 0
        if y + t.height > 2000 // scale:
            placed.append(page)
            page, x, y, row_h = [], 0, 0, 0
        page.append((name, t, x, y))
        x += t.width + 10
        row_h = max(row_h, t.height)
    if page:
        placed.append(page)
    for i, page in enumerate(placed, 1):
        H = max(py + t.height for _, t, _, py in page)
        img = Image.new("RGB", (page_w, H), (40, 40, 40))
        d = ImageDraw.Draw(img)
        for name, t, px_, py in page:
            img.paste(t, (px_, py))
            d.text((px_ + 1, py), name, fill=(220, 220, 220))
        img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
        img.save(OUT / f"sheet_{i:02d}.png")
        n += 1
    return len(tiles), n


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="record-name prefixes")
    ap.add_argument("--sheets", action="store_true", help="write review sheets to tmp/cage_logo/")
    ap.add_argument("--scale", type=int, default=2, help="sheet zoom (default 2)")
    ap.add_argument("--features", action="store_true", help="print every non-trivial component")
    a = ap.parse_args()

    recs = load_records(a.only)
    rom = {lay: {lab: rom_palette(asm, lab) for asm, lab in lst} for lay, lst in ROM_PALETTES.items()}

    results = []
    use = {lay: Counter() for lay in rom}
    logo_idx = {lay: Counter() for lay in rom}
    kinds = Counter()
    recs_with_logo = Counter()
    shallow = []
    for r in recs:
        words, rec = r["words"], r["rec"]
        for row in rec["px"]:
            use[r["layout"]].update(row)
        comps = []
        for c in components(rec, words):
            kind = classify(c)
            comps.append((kind, c))
            kinds[kind] += 1
            if kind in HIDDEN:
                for x, y in c["pts"]:
                    logo_idx[r["layout"]][rec["px"][y][x]] += 1
            if a.features and c["n"] >= 3:
                print(f"{r['name']:16s} {kind:5s} n={c['n']:4d} int={c['interior']:.2f} "
                      f"D={c['d']:.2f} T={c['t']:.2f} S={c['s']:.2f} B={c['b']:.2f} light={c['light']:.2f}")
        if any(k in HIDDEN for k, _ in comps):
            recs_with_logo[r["layout"]] += 1
            # freed slots are >= 0x20, so a logo record authored below 6bpp would need a deeper pack
            if max(max(row) for row in rec["px"]) < 32:
                shallow.append(r["name"])
        pants = 0x3F if r["layout"] == "cage" else 0x32
        results.append(dict(name=r["name"], rec=rec, words=words, comps=comps, pants_index=pants))

    print(f"records scanned: {len(recs)}  "
          + ", ".join(f"{lay}={sum(1 for r in recs if r['layout'] == lay)}" for lay in rom))
    print(f"grey components: " + ", ".join(f"{k}={v}" for k, v in kinds.most_common()))
    for lay in rom:
        li = logo_idx[lay]
        total_grey = sum(use[lay][i] for i in GREYS)
        print(f"\n[{lay}] records with logo: {recs_with_logo[lay]}   "
              f"logo pixels: {sum(li.values())} of {total_grey} grey pixels")
        print("  logo pixels by index: " + ", ".join(f"{i}:{li[i]}" for i in GREYS))
        need = sum(1 for i in GREYS if li[i])
        plan = merge_plan(lay, need, rom[lay], use[lay])
        print(f"  free {need} slots (one per grey level the logo uses) by merging, worst error "
              f"in 5-bit steps across {', '.join(rom[lay])}:")
        for keep, drop, worst, moved in plan:
            cols = " ".join(f"{p[keep]:04x}/{p[drop]:04x}" for p in rom[lay].values())
            print(f"    {drop:#04x} -> {keep:#04x}  worst {worst}  pixels repainted {moved:6d}   {cols}")

    print(f"\nlogo records whose max index is < 32 (would grow past 5bpp): {shallow or 'none'}")

    if a.sheets:
        n_tiles, n_pages = sheets(results, a.scale)
        print(f"\nsheets: {n_tiles} pieces on {n_pages} pages in {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
