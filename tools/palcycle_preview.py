"""Preview a palette cycle on a stage before touching the ROM.

    python tmp/palcycle_preview.py <stage> <BDB> <PALNAME> <start_hex> <count> [--tick 6] [--also PAL:start:count:tick ...]

Renders the stage the way tools/stage_preview.py composes it (mid camera), then:
  mask.png    every pixel drawn from PALNAME[start..start+count) in magenta
  cycle.gif   one full loop of the rotation, stepped every --tick game ticks
              (54.7 Hz), with any --also cycles running at the same time
"""
import argparse
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import stage_preview as sp  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("stage"); ap.add_argument("bdb"); ap.add_argument("pal")
ap.add_argument("start"); ap.add_argument("count", type=int)
ap.add_argument("--tick", type=int, default=6)
ap.add_argument("--also", action="append", default=[], help="PAL:start_hex:count:tick, an existing cycle to run too")
ap.add_argument("--out", default=None)
ap.add_argument("--game-pal", action="append", default=[],
                help="INDEX=LABEL: draw BDD palette INDEX with src/BGNDPAL.ASM LABEL's colours (what the ROM loads)")
args = ap.parse_args()
start = int(args.start, 16)

asm = (ROOT / "src" / "BGND.ASM").read_text(errors="replace")
st = sp.parse_stage(asm, args.stage, dict(scrrgt=399, wy_offset=0xe0))
imgs, order, pals = sp.load_bdd(ROOT / "data" / f"{args.bdb}.BDD")
if args.game_pal:
    bgndpal = (ROOT / "src" / "BGNDPAL.ASM").read_text(errors="replace")
    for spec in args.game_pal:
        idx, label = spec.split("=")
        mm = re.search(r"^%s:[^\n]*\n((?:\s*\.word[^\n]*\n)+)" % re.escape(label), bgndpal, re.M)
        vals = []
        for ln in mm.group(1).splitlines():
            for v in re.findall(r"[0-9A-Fa-f]+H|\d+", ln.split(";")[0].replace(".word", "")):
                vals.append(int(v[:-1], 16) if v.upper().endswith("H") else int(v))
        cols = vals[1:1 + vals[0]]
        name = pals[int(idx)][0]
        pals[int(idx)] = (name, cols + pals[int(idx)][1][len(cols):])
        print("palette %s (%s) drawn with %s's %d game colours" % (idx, name, label, len(cols)))
_n, _w, _np, mods, blks = sp.load_bdb(ROOT / "data" / f"{args.bdb}.BDB")
sp.assign_modules(mods, blks, imgs, order)
by_label = {m["label"] + "BMOD": m for m in mods}
names = [n.upper() for n, _ in pals]
target = names.index(args.pal.upper())
main_rate = sp.rate_for_plane(st["scroll"], 1) or 0x20000
out = Path(args.out) if args.out else ROOT / "tmp" / "palcycle" / f"{args.stage}_{args.pal}_{args.start}"
out.mkdir(parents=True, exist_ok=True)


def render(cur_pals, mask=None):
    im = Image.new("RGBA", (sp.SCREEN_W, sp.SCREEN_H), (0, 0, 0, 255))
    px = im.load()
    hits = 0
    for head, _wtl in st["dlists"]:
        m2 = re.fullmatch(r"baklst(\d)", head)
        if not m2:
            continue
        plane = int(m2.group(1))
        p = next((pp for pp in st["planes"] if pp and pp["plane"] == plane), None)
        mod = by_label.get(p["mod"]) if p else None
        if mod is None:
            continue
        wxn = st["worldtlx"]
        for b in sorted(mod["blocks"], key=lambda b: ((b["z"] >> 8) & 0xff, b["y"])):
            sx = round(p["x"] + (b["x"] - mod["x1"]) - wxn)
            sy = p["y"] + (b["y"] - mod["y1"]) - st["worldtly"]
            pal = cur_pals[b["pal"]][1]
            if mask is not None and b["pal"] == target:
                img = imgs[b["hdr"]]
                w, h, data = img["w"], img["h"], img["px"]
                flip = bool(b["z"] & 0x10)
                for y in range(h):
                    for x in range(w):
                        i = data[y * w + x]
                        if not i:
                            continue
                        dx, dy = sx + (w - 1 - x if flip else x), sy + y
                        if 0 <= dx < sp.SCREEN_W and 0 <= dy < sp.SCREEN_H:
                            if start <= i < start + mask:
                                px[dx, dy] = (255, 0, 255, 255); hits += 1
                            else:
                                r, g, bb, _ = sp.bgr555(pal[i]) if i < len(pal) else (0, 0, 0, 255)
                                px[dx, dy] = (r // 3, g // 3, bb // 3, 255)
            else:
                sp.blit(px, imgs[b["hdr"]], pal, sx, sy, bool(b["z"] & 0x10))
    return im, hits


mask_im, hits = render(pals, mask=args.count)
mask_im.save(out / "mask.png")

cycles = [(target, start, args.count, args.tick)]
for a in args.also:
    pn, s, c, t = a.split(":")
    cycles.append((names.index(pn.upper()), int(s, 16), int(c), int(t)))
steps = 1
for _pi, _s, c, t in cycles:
    steps = max(steps, c * t)
frames = []
for tick in range(0, steps, 2):
    cur = [(n, list(cols)) for n, cols in pals]
    for pi, s, c, t in cycles:
        k = (tick // t) % c
        seg = cur[pi][1][s:s + c]
        cur[pi][1][s:s + c] = seg[-k:] + seg[:-k] if k else seg   # cycle_forward direction
    frames.append(render(cur)[0].convert("P", palette=Image.ADAPTIVE))
frames[0].save(out / "cycle.gif", save_all=True, append_images=frames[1:], duration=int(2 * 1000 / 54.7), loop=0)
print("pixels using %s[%02x..%02x]: %d" % (args.pal, start, start + args.count - 1, hits))
print("wrote", out / "mask.png", "and", out / "cycle.gif", "(%d frames)" % len(frames))
