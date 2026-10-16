#!/usr/bin/env python3
"""flybrain_atlas.py - where every cell in the fly actually is, for the dashboard.

The neuron view used to lay cells out on rings by class, because nobody had looked for
coordinates. MaleCNS v1.0 carries them: `somaLocation` in the body annotations, the
[x, y, z] of each cell body, for 141,781 of the 211,577 bodies. This projects them into
a top-down picture of the whole central nervous system - the brain with its optic lobes
spread either side, the neck, and the ventral nerve cord below it - and records where
each cell of the fly's circuit sits in that picture, so the page can light the real
cells in the real places.

The axes, measured rather than assumed:
  z   the long axis, 10k..134k. The brain is z 13k-43k, there is NOTHING between 43k and
      63k (the neck), and the nerve cord is z 63k-133k. Screen y.
  x   left-right, 2k..94k. The fly's RIGHT side is LOW x (somaSide R has mean x 24.7k,
      L 72.4k), so x is mirrored: a cell named _R draws on the right, as the eye panels
      and every other view on the dashboard already have it.
  y   the depth axis, dropped by the projection.

A cell of the circuit is a cell TYPE on one side (AVLP396_R), not one body, so it is
drawn as every body of that type on that side - LC4 is a spray of ~50 cells across the
optic lobe, and it lights up as a spray. Names without a side take both sides; the
extractor's `untyped<bodyId>` nodes are that one body.

  python tools/flybrain_atlas.py                  # -> C:\\tmp\\flybrain\\atlas.json
  python tools/flybrain_atlas.py --bg 80000       # denser background
  python tools/flybrain_atlas.py --check          # the atlas is still what this would write

The page draws the background once (it never changes) and only the lit cells per frame.
"""
import argparse
import json
import os
import re
import sys

import numpy as np
import pyarrow.compute as pc
import pyarrow.feather as feather

DATA = r"C:\tmp\flybrain"
ANN = "body-annotations-male-cns-v1.0-minconf-0.5.feather"
NETS = [r"C:\tmp\flybrain\out\flynet.lua", r"C:\tmp\flybrain\out\flynet_chase.lua",
        r"C:\tmp\flybrain\out\flynet_oa.lua", r"C:\tmp\flybrain\out\flynet_body.lua"]
OUT = r"C:\tmp\flybrain\atlas.json"
W = 1000                 # picture width in atlas units; the height follows the anatomy
PAD = 12
MAX_PER_CELL = 80        # the biggest visual types run to hundreds of bodies; 80 reads the same
SEED = 2026              # the background sample is fixed, so the atlas is reproducible


def read_nets(paths):
    """Every cell name in the circuits the rig can fly (first-seen order), and who each
    one is wired to - by name, so the nets' separate index spaces never mix."""
    names, seen, links = [], set(), {}
    for p in paths:
        if not os.path.exists(p):
            continue
        text = open(p, encoding="utf-8").read()
        block = re.search(r"names\s*=\s*\{(.*?)\}", text, re.S)
        if not block:
            continue
        local = re.findall(r'"([^"]+)"', block.group(1))
        for n in local:
            if n not in seen:
                seen.add(n)
                names.append(n)
        edges = re.search(r"edges\s*=\s*\{(.*?)\n\s*\}", text, re.S)
        for a, b in re.findall(r"\{\s*(\d+)\s*,\s*(\d+)\s*,\s*-?\d+\s*\}", edges.group(1) if edges else ""):
            na, nb = local[int(a) - 1], local[int(b) - 1]
            links.setdefault(na, set()).add(nb)
            links.setdefault(nb, set()).add(na)
    return names, links


def load(data):
    t = feather.read_table(os.path.join(data, ANN), columns=["bodyId", "type", "somaSide", "somaLocation"])
    loc = t.column("somaLocation").combine_chunks()
    t = t.filter(pc.and_(pc.is_valid(loc), pc.equal(pc.list_value_length(loc), 3)))
    xyz = t.column("somaLocation").combine_chunks().flatten().to_numpy().reshape(-1, 3)
    body = t.column("bodyId").to_numpy()
    typ = np.array(t.column("type").to_pylist(), dtype=object)
    side = np.array(t.column("somaSide").to_pylist(), dtype=object)
    return body, typ, side, xyz


def project(xyz):
    """[x, z] -> atlas units, x mirrored so the fly's right is on the right."""
    x, z = xyz[:, 0].astype(float), xyz[:, 2].astype(float)
    x0, x1, z0, z1 = x.min(), x.max(), z.min(), z.max()
    s = (W - 2 * PAD) / (x1 - x0)
    h = int(round((z1 - z0) * s)) + 2 * PAD
    px = PAD + (x1 - x) * s
    py = PAD + (z - z0) * s
    return np.round(px).astype(int), np.round(py).astype(int), h


def build(data, net_paths, n_bg):
    nets, links = read_nets(net_paths)
    body, typ, side, xyz = load(data)
    px, py, h = project(xyz)

    rng = np.random.default_rng(SEED)
    pick = np.sort(rng.choice(len(px), size=min(n_bg, len(px)), replace=False))
    bg = np.empty(2 * len(pick), dtype=int)
    bg[0::2], bg[1::2] = px[pick], py[pick]

    # index the bodies by type once, rather than scanning 141k rows per cell
    by_type = {}
    for i, t in enumerate(typ):
        if isinstance(t, str):
            by_type.setdefault(t, []).append(i)
    by_body = {int(b): i for i, b in enumerate(body)}

    cells, missing = {}, []
    for name in nets:
        m = re.match(r"^untyped(\d+)(?:_[LR])?$", name)
        if m:
            rows = [by_body[int(m.group(1))]] if int(m.group(1)) in by_body else []
        else:
            sm = re.match(r"^(.*)_([LR])$", name)
            base, want = (sm.group(1), sm.group(2)) if sm else (name, None)
            rows = [i for i in by_type.get(base, []) if want is None or side[i] == want]
        if not rows:
            missing.append(name)
            continue
        if len(rows) > MAX_PER_CELL:
            rows = [rows[int(k)] for k in np.linspace(0, len(rows) - 1, MAX_PER_CELL)]
        pts = []
        for i in rows:
            pts += [int(px[i]), int(py[i])]
        cells[name] = pts

    # Cells with no cell body in the CNS. The ear (JO-*, Johnston's organ) is the case
    # that matters: its cell bodies are out in the antenna, and the annotations carry no
    # point for them at all - no somaLocation, no tosomaLocation. Rather than invent one,
    # draw each at the centre of the cells it is wired to in the circuit, which is where
    # its axons end. Listed as "inferred" so the page can draw them as what they are.
    def centroid(n):
        p = cells[n]
        return sum(p[0::2]) / (len(p) // 2), sum(p[1::2]) / (len(p) // 2)

    inferred, unplaced = [], []
    for name in missing:
        near = [centroid(n) for n in links.get(name, ()) if n in cells]
        if not near:
            unplaced.append(name)
            continue
        cells[name] = [int(round(sum(x for x, _ in near) / len(near))),
                       int(round(sum(y for _, y in near) / len(near)))]
        inferred.append(name)

    # A few ear subtypes are wired only to OTHER ear cells, so the pass above found no
    # placed partner for them. They go with the rest of the ear - the same organ entering
    # by the same nerve - rather than being left out, which would hide them when they fire.
    for name in list(unplaced):
        kin = [cells[n] for n in inferred if n.split("-")[0] == name.split("-")[0] and "-" in name]
        if kin:
            cells[name] = [int(round(sum(p[0] for p in kin) / len(kin))),
                           int(round(sum(p[1] for p in kin) / len(kin)))]
            inferred.append(name)
            unplaced.remove(name)

    return {
        "source": "MaleCNS v1.0 somaLocation, top-down (x mirrored, z)",
        "w": W, "h": h, "bodies": int(len(px)),
        "bg": bg.tolist(), "cells": cells, "inferred": inferred, "missing": unplaced,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", default=DATA)
    ap.add_argument("--net", action="append", help="a flynet .lua (default: both shipped nets)")
    ap.add_argument("--bg", type=int, default=60000, help="background bodies to draw")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    atlas = build(args.data, args.net or NETS, args.bg)
    blob = json.dumps(atlas, separators=(",", ":"))
    if args.check:
        try:
            same = open(args.out, encoding="utf-8").read() == blob
        except OSError:
            same = False
        print("atlas: %s" % ("current" if same else "STALE - rerun without --check"))
        return 0 if same else 1
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(blob)
    placed = len(atlas["cells"]) - len(atlas["inferred"])
    print("atlas: %d bodies, %d drawn as background, %d circuit cells at their somas, "
          "%d placed by their wiring, %d not placed"
          % (atlas["bodies"], len(atlas["bg"]) // 2, placed, len(atlas["inferred"]), len(atlas["missing"])))
    print("       %dx%d atlas units, %d KB -> %s" % (atlas["w"], atlas["h"], len(blob) // 1024, args.out))
    if atlas["missing"]:
        print("       no position for: %s%s" % (", ".join(atlas["missing"][:12]),
                                              " ..." if len(atlas["missing"]) > 12 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
