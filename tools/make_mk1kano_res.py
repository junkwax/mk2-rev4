#!/usr/bin/env python3
r"""MK1 KANO's SPARE ART - every picture of him in mk.zip that his Wolf port
does not draw as it stands - in one reference library, data/MK1KNRES.IMG.

Not a pack: no LOD reads it and no pixel reaches a ROM (the role
data/KATPAL.IMG and data/FXPALS.IMG play).  It is somewhere to go LOOKING for
a pose when a frame needs one, in IMGTOOL, the way tools/kano_synth.py went
looking for the headless body and the severed head.

    KR<lane>_<step>   an MK1 lane frame no KANO<n>.IMG frame shows as its pose
                      (lane/step: tmp/mk1kano/lanes.txt; first lane that draws it).
                      Lane 4Fh's headless decap body is here: kano_synth CUTS it
                      into the decap / legs / torso frames, so the whole
                      drawings live only here.
    KRHEAD1-4         MK1's SEVERED HEAD, four drawings of it rolling (records
                      FFF04C40-FFF04D60): a one-image lane at FFD12F90 and a
                      frame at FFD23760, neither in Kano's fighter table.
                      kano_synth builds the rolling head and the head hole off them.
    KRORPHAN1         a forward-leaning fighting crouch, 7 pieces (FFEF3520-
                      FFEF3760) whose pixels sit inside Kano's own image ROM and
                      which NOTHING in the program ROM points at - drawn by
                      Midway and never played.

How these were found, so the next search does not start over: his lane
records' PIXEL addresses (SAG) fall in three runs of image ROM (his body,
the decap body, the heart rip's drips); a record whose pixels lie inside one
of those runs is his whatever its header says.  Searching by header address
is useless - every fighter's headers are interleaved.

    python tools/make_mk1kano_res.py            # report
    python tools/make_mk1kano_res.py --apply    # write data/MK1KNRES.IMG
    python tools/make_mk1kano_res.py --check    # still what mk.zip + the port say

NOT in Phase D: it is a workbench, and an IMGTOOL edit to it should not fail
the build.  --check is for after a change to the port's pose map.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_mk1kano_port as P      # noqa: E402
import make_mk1pit as pit          # noqa: E402
import kano_subframes as ks        # noqa: E402
import kano_synth                  # noqa: E402
import mk1_yunit_extract as mk1x   # noqa: E402

OUT = P.DATA / "MK1KNRES.IMG"
ORPHAN = (0xFFEF3520, 0xFFEF3580, 0xFFEF35E0, 0xFFEF3640, 0xFFEF36A0, 0xFFEF3700, 0xFFEF3760)


def entries():
    M = P.mk1()
    rom, frames, recs, lanes = M["rom"], M["frames"], M["recs"], M["lanes"]
    P.build()
    P.touch_all()
    shown = {s[1] for s in P.CONTENT.values() if s[0] == "mk1"}
    out, seen = [], set()
    for lane in sorted(lanes, key=lambda k: int(k, 16)):
        for i, f in enumerate(lanes[lane]):
            if f in shown or f in seen:
                continue
            seen.add(f)
            cv, ax, ay = ks.composite([recs[a] for a in frames[f]])
            out.append((f"KR{lane}_{i}", ax, ay, cv, f"lane {lane} step {i}, frame {f:08X}"))
    byhdr = {mk1x.BASE + v[0] * 8: (s,) + v[1:] for s, v in rom.records().items()}
    mine = {rom.image(a)["sag"] for a in recs}

    def rec(h):
        if h not in byhdr:
            raise SystemExit(f"no image record at {h:08X} - wrong mk.zip?")
        s, w, hh, ax, ay = byhdr[h]
        if s in mine:
            raise SystemExit(f"{h:08X} is drawn by his lanes after all")
        return dict(w=w, h=hh, ax=ax, ay=ay, px=rom.pixels(w, hh, s).astype("uint8").tobytes())
    for k, h in enumerate(kano_synth.HEADS):
        r = rec(h)
        out.append((f"KRHEAD{k + 1}", r["ax"], r["ay"],
                    np.frombuffer(r["px"], np.uint8).reshape(r["h"], r["w"]), f"record {h:08X}"))
    cv, ax, ay = ks.composite([rec(h) for h in ORPHAN])
    out.append(("KRORPHAN1", ax, ay, cv, "records FFEF3520-FFEF3760, unreferenced"))
    return out, M["pals"]


def build():
    ents, pals = entries()
    img = pit.build_img([(n, ax, ay, cv.shape[1], cv.shape[0], cv.astype("uint8").tobytes(), 0)
                         for n, ax, ay, cv, _w in ents],
                        [(nm, 6, words) for nm, words in pals.items()])
    return ents, img


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    ents, img = build()
    for n, _ax, _ay, cv, why in ents:
        print(f"  {n:<12} {cv.shape[1]:>3}x{cv.shape[0]:<3}  {why}")
    print(f"MK1KNRES.IMG: {len(ents)} images, {len(img):,} bytes")
    if a.apply:
        OUT.write_bytes(img)
        print(f"wrote {OUT.relative_to(P.ROOT)}")
    if a.check:
        if not OUT.exists() or OUT.read_bytes() != img:
            print("make_mk1kano_res: STALE data/MK1KNRES.IMG")
            return 1
        print("make_mk1kano_res: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
