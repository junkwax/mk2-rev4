#!/usr/bin/env python3
"""Render a BDB/BDD stage the way the GAME composes it, not the way BDDTool does.

BDDTool shows one flat canvas.  The game cuts that canvas into modules by
BOUNDING BOX, gives each module its own display list (baklst1..8), its own world
X (worldtlx..worldtlx8) and its own parallax rate (the stage's scroll table),
then draws them in the order of the stage's dlists_ table.  Three consequences
BDDTool cannot show you:

  * a block belongs to the FIRST module whose box contains it, so dropping new
    art on top of an existing module silently joins that module;
  * a module's origin is re-cropped to the min x/y of its members, so adding one
    block to the left of a module shifts every other block in it;
  * two modules on different planes never keep their canvas spacing on screen -
    they only line up at one camera position.

This reads the truth out of src/BGND.ASM plus the .BDB/.BDD and draws the actual
400x254 screen at any camera position.

    python tools/stage_preview.py tower --bdb TWRSIDE --modules
    python tools/stage_preview.py tower --bdb TWRSIDE --at left,mid,right --grid

--at takes named stops (left/mid/right, from the stage's own scroll limits) or a
raw worldtlx for the fighting plane; every other plane is derived through the
scroll table, which is what makes the parallax visible.

Verified against the machine: tools/tower_stage_probe.lua reports worldtly=-14,
ground_y=229, and at one camera x=126 x2=243 x3=184 x4=199 x6=214 - ratios
0.502 / 0.753 / 0.689 / 0.626 against the fighting plane, matching the scroll
table's 0x10000 / 0x18000 / 0x16000 / 0x14000 over 0x20000.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCREEN_W, SCREEN_H = 400, 254
HEADCT = 10          # ldbgnd2.c: module labels are truncated to 10 chars


# ---------------------------------------------------------------- BDD / BDB

def load_bdd(path: Path):
    d = path.read_bytes()
    pos = d.index(b"\n") + 1
    n = int(d[:pos].split()[0])
    imgs, order = {}, []
    for _ in range(n):
        j = d.index(b"\n", pos)
        p = d[pos:j].split()
        idx, w, h = int(p[0], 16), int(p[1]), int(p[2])
        pos = j + 1
        imgs[idx] = dict(w=w, h=h, px=d[pos:pos + w * h])
        order.append(idx)
        pos += w * h
    pals = []
    while pos < len(d):
        j = d.index(b"\n", pos)
        nm, cnt = d[pos:j].split()
        cnt = int(cnt)
        pos = j + 1
        pals.append((nm.decode(), [struct.unpack_from("<H", d, pos + 2 * k)[0] for k in range(cnt)]))
        pos += 2 * cnt
    return imgs, order, pals


def load_bdb(path: Path):
    lines = [l.strip() for l in path.read_text().splitlines() if l.strip()]
    hd = lines[0].split()
    name = hd[0]
    xl, yl, zl, nmods, npals, nblocks = (int(v) for v in hd[1:7])
    mods = []
    for l in lines[1:1 + nmods]:
        t = l.split()
        mods.append(dict(name=t[0], x1=int(t[1]), x2=int(t[2]), y1=int(t[3]), y2=int(t[4])))
    blks = []
    for l in lines[1 + nmods:1 + nmods + nblocks]:
        t = l.split()
        blks.append(dict(z=int(t[0], 16), x=int(t[1]), y=int(t[2]), hdr=int(t[3], 16), pal=int(t[4])))
    return name, (xl, yl), npals, mods, blks


def assign_modules(mods, blks, imgs, order):
    """Reproduce ldbgnd2.c: crop each module to the blocks it contains, then
    claim blocks in module order - first module wins, `put` is sticky."""
    hidx = {h: i for i, h in enumerate(order)}
    for b in blks:
        b["hi"] = hidx[b["hdr"]]
        im = imgs[b["hdr"]]
        b["x2"] = b["x"] + im["w"] - 1
        b["y2"] = b["y"] + im["h"] - 1
        b["put"] = None

    def inside(b, m):
        return (b["x"] >= m["x1"] and b["y"] >= m["y1"]
                and b["x2"] <= m["x2"] and b["y2"] <= m["y2"])

    for m in mods:                                   # /* correct Module Coors */
        got = [b for b in blks if inside(b, m)]
        if got:
            m["x1"] = min(b["x"] for b in got)
            m["y1"] = min(b["y"] for b in got)
            m["x2"] = max(b["x2"] for b in got)
            m["y2"] = max(b["y2"] for b in got)
    for m in mods:                                   # /* WRITE out BLOCKS */
        m["label"] = m["name"][:HEADCT]
        m["blocks"] = []
        for b in blks:
            if b["put"] is None and inside(b, m):
                b["put"] = m["name"]
                m["blocks"].append(b)
    return [b for b in blks if b["put"] is None]


# ---------------------------------------------------------------- BGND.ASM

def _num(tok: str) -> int:
    """One GSPA integer literal: 0e5h, 365, -31, 02cch."""
    tok = tok.split(";")[0].strip()
    m = re.fullmatch(r"(-?)0?([0-9a-fA-F]+)[hH]", tok)
    if m:
        v = int(m.group(2), 16)
        return -v if m.group(1) else v
    return int(tok, 10)


def _expr(tok: str, consts: dict) -> int:
    """A GSPA constant expression, e.g. (1120/2)-(scrrgt/2) or 0e5h-wy_offset-19.
    GSPA integer-divides, and so does Python's //."""
    tok = tok.split(";")[0].strip()
    for name, val in consts.items():
        tok = re.sub(rf"\b{name}\b", str(val), tok)
    tok = re.sub(r"\b0?([0-9a-fA-F]+)[hH]\b", lambda m: str(int(m.group(1), 16)), tok)
    tok = tok.replace("/", "//")
    return int(eval(tok, {"__builtins__": {}}, {}))


def _block(lines, label):
    out, on = [], False
    for l in lines:
        if re.match(rf"^{re.escape(label)}\b", l):
            on = True
            continue
        if on:
            if re.match(r"^\S", l) and not l.lstrip().startswith(";"):
                break
            out.append(l)
    return out


def _payload(body):
    """Flatten .word/.long payloads into a list of tokens, in order."""
    out = []
    for l in body:
        l = l.split(";")[0].strip()
        m = re.match(r"^\.(word|long)\s+(.*)$", l, re.I)
        if not m:
            continue
        for tok in m.group(2).split(","):
            tok = tok.strip()
            if tok:
                out.append(tok)
    return out


def parse_stage(asm: str, stage: str, consts: dict):
    """Pull <stage>_mod, <stage>_scroll and dlists_<stage> out of BGND.ASM.

    Field order is init_bakmods' (BGND.ASM): autoerase colour, ground y, initial
    world y, initial worldx, left limit, right limit, calla, scroll table,
    dlists, bak1mods, then 64 bits per plane - module pointer plus x,y - until
    0ffffffffh."""
    lines = asm.splitlines()
    mod = _payload(_block(lines, stage + "_mod"))
    scroll = [_num(t) for t in _payload(_block(lines, stage + "_scroll"))]

    ground_y = _expr(mod[1], consts)
    worldtly = _expr(mod[2], dict(consts, ground_y=ground_y))
    worldtlx = _expr(mod[3], consts)
    left, right = _expr(mod[4], consts), _expr(mod[5], consts)

    i = 6 + 3 + 1                       # calla, scrtab, dlists, bak1mods
    planes, plane = [], 1
    while i < len(mod):
        tok = mod[i]
        if re.fullmatch(r"0?f{8}h", tok, re.I):
            break
        # Not every stage ends its plane list with 0ffffffffh: port_mod follows
        # baklst6 with `center_x` and a centering table, and walking into that
        # reads a module name where an x coordinate should be. Anything that is
        # neither a module pointer nor skip_bakmod ends the list.
        if not tok.endswith("BMOD") and tok != "skip_bakmod":
            break
        if tok == "skip_bakmod":
            planes.append(None)
            i += 1
        else:
            # _expr, not _num: a plane's world x can be an expression, e.g.
            # battle_mod's `(1282-784)/2`.
            planes.append(dict(mod=tok, x=_expr(mod[i + 1], consts),
                               y=_expr(mod[i + 2], consts), plane=plane))
            i += 3
        plane += 1

    dlists = []
    for l in _block(lines, "dlists_" + stage):
        l = l.split(";")[0].strip()
        m = re.match(r"^\.long\s+([^,]+?)\s*(?:,\s*(\S+))?$", l)
        if m:
            dlists.append((m.group(1).strip(), m.group(2)))
    return dict(ground_y=ground_y, worldtly=worldtly, worldtlx=worldtlx,
                left=left, right=right, scroll=scroll, planes=planes, dlists=dlists)


def rate_for_plane(scroll, plane):
    """The scroll table is handed to mmtm at scrollx0+32 with a1..a9, which
    reverses it: table entry i drives plane 8-i (entry 8 -> plane 0, the one
    that never moves).  Plane 1 is the fighting plane and shares worldtlx with
    objlst, so its entry is the 1.0x reference."""
    i = 8 - plane
    return scroll[i] if 0 <= i < len(scroll) else 0


# ---------------------------------------------------------------- render

def bgr555(v):
    return (((v >> 10) & 31) << 3, ((v >> 5) & 31) << 3, (v & 31) << 3, 255)


def blit(px, img, pal, ox, oy, flip):
    w, h, data = img["w"], img["h"], img["px"]
    for y in range(h):
        dy = oy + y
        if dy < 0 or dy >= SCREEN_H:
            continue
        row = y * w
        for x in range(w):
            i = data[row + x]
            if not i:
                continue                      # palette index 0 is transparent
            dx = ox + (w - 1 - x if flip else x)
            if 0 <= dx < SCREEN_W:
                px[dx, dy] = bgr555(pal[i]) if i < len(pal) else (255, 0, 255, 255)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", help="BGND.ASM stage prefix, e.g. tower")
    ap.add_argument("--bdb", required=True, help="data/<NAME>.BDB + .BDD")
    ap.add_argument("--at", default="mid", help="stops: left,mid,right or a raw worldtlx")
    ap.add_argument("--out", default=None, help="output dir (default tmp/stage_preview)")
    ap.add_argument("--modules", action="store_true", help="module report only")
    ap.add_argument("--grid", action="store_true", help="mark ground_y and a 50px grid")
    args = ap.parse_args()

    consts = dict(scrrgt=399, wy_offset=0xe0)
    asm = (ROOT / "src" / "BGND.ASM").read_text(errors="replace")
    st = parse_stage(asm, args.stage, consts)

    imgs, order, pals = load_bdd(ROOT / "data" / f"{args.bdb}.BDD")
    _name, _world, npals, mods, blks = load_bdb(ROOT / "data" / f"{args.bdb}.BDB")
    orphans = assign_modules(mods, blks, imgs, order)
    by_label = {m["label"] + "BMOD": m for m in mods}

    main_rate = rate_for_plane(st["scroll"], 1) or 0x20000
    centre = st["worldtlx"] + SCREEN_W // 2      # every plane starts here

    print(f"{args.stage}_mod: ground_y={st['ground_y']} worldtly={st['worldtly']} "
          f"worldtlx={st['worldtlx']} edges {st['left']}..{st['right']}")
    print(f"  ground_y is screen y {st['ground_y'] - st['worldtly']}; "
          f"design centre is world x {centre} on every plane")
    if len(pals) != npals:
        print(f"  ! BDB header says {npals} palettes, BDD holds {len(pals)}")
    for i, (pn, cols) in enumerate(pals):
        print(f"  pal[{i}] {pn} ({len(cols)} entries)")

    for p in st["planes"]:
        if p is None:
            continue
        m = by_label.get(p["mod"])
        rate = rate_for_plane(st["scroll"], p["plane"])
        if m:
            w, h = m["x2"] - m["x1"] + 1, m["y2"] - m["y1"] + 1
            off = (p["x"] + w / 2) - centre
            what = (f"{w}x{h} {len(m['blocks'])} blocks  canvas origin ({m['x1']},{m['y1']})"
                    f"  centre off by {off:+.1f}")
        else:
            what = "NOT IN THIS BDB"
        print(f"  baklst{p['plane']}  {p['mod']:<16} world ({p['x']},{p['y']})"
              f"  rate 0x{rate:05x} = {rate / main_rate:.4f}x  {what}")
    for m in mods:
        if not any(pp and pp["mod"] == m["label"] + "BMOD" for pp in st["planes"]):
            print(f"  UNWIRED   {m['label']}BMOD  "
                  f"{m['x2'] - m['x1'] + 1}x{m['y2'] - m['y1'] + 1} "
                  f"{len(m['blocks'])} blocks  canvas origin ({m['x1']},{m['y1']})")
    if orphans:
        print(f"  *** {len(orphans)} blocks in NO module - LOAD2 comments these "
              f"out and they never draw:")
        for b in orphans:
            print(f"        canvas ({b['x']},{b['y']}) hdr=0x{b['hdr']:02X} "
                  f"{imgs[b['hdr']]['w']}x{imgs[b['hdr']]['h']}")
    if args.modules:
        return 0

    from PIL import Image
    outdir = Path(args.out) if args.out else ROOT / "tmp" / "stage_preview"
    outdir.mkdir(parents=True, exist_ok=True)

    stops = {"left": st["left"], "mid": st["worldtlx"], "right": st["right"]}
    for name in args.at.split(","):
        name = name.strip()
        wx = stops.get(name)
        if wx is None:
            wx = int(name, 0)
        delta = wx - st["worldtlx"]

        im = Image.new("RGBA", (SCREEN_W, SCREEN_H), (0, 0, 0, 255))
        px = im.load()
        drawn = []
        for head, _wtl in st["dlists"]:
            m2 = re.fullmatch(r"baklst(\d)", head)
            if not m2:
                continue                      # -1 floor / -2 shadows / objlst
            plane = int(m2.group(1))
            p = next((pp for pp in st["planes"] if pp and pp["plane"] == plane), None)
            mod = by_label.get(p["mod"]) if p else None
            if mod is None:
                continue
            wxn = st["worldtlx"] + delta * rate_for_plane(st["scroll"], plane) / main_rate
            # insobj_v (MKDISP.ASM) keeps each baklst ASCENDING in ozval, tie
            # broken on y, and the head is queued first - so low z is at the
            # back and the tail is drawn on top.  Draw in that order, not in
            # BDB record order, or the preview cannot show a wrong z ramp.
            for b in sorted(mod["blocks"], key=lambda b: ((b["z"] >> 8) & 0xff, b["y"])):
                sx = round(p["x"] + (b["x"] - mod["x1"]) - wxn)
                sy = p["y"] + (b["y"] - mod["y1"]) - st["worldtly"]
                blit(px, imgs[b["hdr"]], pals[b["pal"]][1], sx, sy, bool(b["z"] & 0x10))
            drawn.append(f"baklst{plane}@{wxn:.0f}")

        if args.grid:
            gy = st["ground_y"] - st["worldtly"]
            for x in range(SCREEN_W):
                if 0 <= gy < SCREEN_H:
                    px[x, gy] = (255, 0, 0, 255)
            for x in range(0, SCREEN_W, 50):
                for y in range(0, SCREEN_H, 4):
                    px[x, y] = (0, 255, 255, 255)

        path = outdir / f"{args.stage}_{args.bdb}_{name}.png"
        im.save(path)
        print(f"wrote {path}  worldtlx={wx} ({delta:+d})  {', '.join(drawn)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
