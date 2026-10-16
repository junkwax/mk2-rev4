#!/usr/bin/env python3
r"""Build data/RAINBOLT.IMG - RAIN's LIGHTNING BOLT.

SOURCE CHANGED 2026-09-26 (second time).  The bolt is no longer Trilogy's
RAINLT art at all.  It is now the repurposed NIGHTWOLF / JAX lightning the
user assembled in IMGTOOL - which is what Trilogy itself drew the move with
(see rain_bolt_proc's own comment: "crack - Nightwolf's lightning in
Trilogy").  Thirteen frames, RNBOLT1-13, authored in data/RAINPSX/RAINFX.IMG
and laid out in data/RAINBOLT.WAX.

    python tools/make_rainbolt_img.py            # write data/RAINBOLT.IMG
    python tools/make_rainbolt_img.py --check    # Phase D: fail if it drifted

## Only the PIECES ship

Every one of the 13 frames is subframed (RNBOLT1A..RNBOLT13B, 45 records).
The uncut parents are NOT emitted: they exist in RAINFX.IMG as the authoring
view, and shipping them would both waste the slot and COLLIDE with MKNJ.ASM,
where RNBOLT1..RNBOLT13 are the piece-list labels.  Subframing takes the set
from 91,356 px to 68,152.

## One palette

The three lightning palettes were merged by the user into LIGHTN_P, 16
colours, and every RNBOLT record indexes it (verified: 0 pixels past the
palette, max index 14).  It ships as RAINLT_P, so rain_bolt_proc's single
runtime getfpal is unchanged and RAINBOLT.LOD stays POF> at PPP> 4.

## Re-anchored on the STRIKE POINT

RAINFX.IMG's anipoints are in the WAX's own frame, where the floor sits 121
below the anchor and the strike point 54 to its left.  Both were MEASURED off
the settled ground ring rather than assumed: RNBOLT9-13 all have h-ay = 121
exactly, and their horizontal centres (ax - w/2) cluster at -54.  Adding
(PX,PY) puts every frame in the engine's convention, where the object sits at
@ground_y and a record draws at oypos-ay - so the ring lands exactly on the
floor and nothing is hand-tuned.  Re-derive these from the ring, never guess:
an anchor error here is invisible in the IMG and obvious only in motion.
"""
import argparse, importlib.util, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SRC = ROOT / "data" / "RAINPSX" / "RAINFX.IMG"
OUT = ROOT / "data" / "RAINBOLT.IMG"

PX, PY = 54, 106            # WAX frame -> strike point (measured, see above)
#
# PY was 121, which is where the settled ring's own art puts it FLUSH on
# @ground_y (RNBOLT9-13 all have h-ay = 121 exactly).  The user's call on
# 2026-09-27 was to drop the whole effect 15px below that line: the ring
# reads as sitting ON the floor rather than standing on it, and the shaft
# comes down that much further into frame.  It is a deliberate offset from
# the measured value, not a re-measurement - if the art ever changes,
# re-derive 121 off the ring and subtract the 15 again.
#
# ONE anchor for all thirteen frames, and it must stay that way.  The WAX puts
# every frame at the same origin (local_dx/local_dy are all 0), so the artist's
# own anipoints ARE the alignment: the shaft's ink stops 81-83 below the
# anchor, the ground burst opens at 75 and runs to 105/109, and the settled
# ring reaches 121.  Shaft and burst OVERLAP by ~8 rows - that overlap is what
# joins the bolt to the floor.
#
# A split anchor was tried on 2026-09-27 (shaft +83, ground +121) because the
# strike frames looked as though they floated 38px off the ground.  They did -
# but not because the anchor was wrong.  The two lanes were being played one
# after the other, so during the strike the burst had not been drawn yet and
# the shaft really did end in mid air.  The fix is the composite rows in
# MKNJ.ASM (RNBOLT3+RNBOLT5, RNBOLT4+RNBOLT6), not a second anchor: moving the
# shaft down 38 slides it THROUGH the burst now that both are on screen at
# once.
BPP = 4
PAL_NAME = b"RAINLT_P"
SRC_PAL = "LIGHTN_P"
NFRAMES = 13


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def build():
    import re
    mk1 = load("make_mk1_raiden_pal")
    erm = load("make_ermfire_img")          # the proven IMG writer
    imgs, pals = mk1.read_img(SRC)
    by = {i["name"]: i for i in imgs}
    pal = next((p for p in pals if p["name"] == SRC_PAL), None)
    if pal is None:
        sys.exit("%s carries no palette named %s" % (SRC.name, SRC_PAL))
    cols = list(pal["words"])
    if len(cols) != 1 << BPP:
        sys.exit("%s has %d entries, expected %d" % (SRC_PAL, len(cols), 1 << BPP))

    rows = []
    for n in range(1, NFRAMES + 1):
        stem = "RNBOLT%d" % n
        kids = sorted(k for k in by
                      if re.fullmatch(re.escape(stem) + r"[A-Z]", k))
        if not kids:
            sys.exit("%s has no subframes - the parent would have to ship and "
                     "would collide with MKNJ.ASM's piece-list label" % stem)
        for k in kids:
            r = by[k]
            if r["palnum"] != pal["palnum"]:
                sys.exit("%s is on palnum %d, expected %s (%d)"
                         % (k, r["palnum"], SRC_PAL, pal["palnum"]))
            px = [v for row in r["px"] for v in row]
            if px and max(px) >= len(cols):
                sys.exit("%s uses index %d past the %d-entry palette"
                         % (k, max(px), len(cols)))
            rows.append((k, r["w"], r["h"], r["ax"] + PX, r["ay"] + PY, px))
    erm.PAL_NAME, erm.OUR_BPP = PAL_NAME, BPP
    return erm.build(rows, cols), rows, erm


def pal_in_asm_drift():
    """RAINLT_P is hand-carried into src/IMGPAL6.ASM (nothing promotes a POF>
    sidecar's palette).  None if it matches RAINFX.IMG's LIGHTN_P."""
    import re
    mk1 = load("make_mk1_raiden_pal")
    _imgs, pals = mk1.read_img(SRC)
    want = list(next(p for p in pals if p["name"] == SRC_PAL)["words"])
    txt = (ROOT / "src" / "IMGPAL6.ASM").read_text(encoding="latin-1")
    m = re.search(r"^RAINLT_P:\s*\n\s*\.word\s+(\d+)\s*\n((?:\s*\.word[^\n]*\n)+)", txt, re.M)
    if not m:
        return "RAINLT_P not found in src/IMGPAL6.ASM"
    have = [int(x, 16) for x in re.findall(r"0([0-9A-Fa-f]{4})H", m.group(2))]
    if int(m.group(1)) != len(want) or have != want:
        return "src/IMGPAL6.ASM RAINLT_P differs from RAINFX.IMG %s - re-copy it" % SRC_PAL
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    blob, rows, _erm = build()
    drift = pal_in_asm_drift()
    if a.check:
        if not OUT.exists() or OUT.read_bytes() != blob:
            sys.exit("data/RAINBOLT.IMG has drifted - re-run without --check")
        if drift:
            sys.exit(drift)
        print("RAINBOLT.IMG OK (%d records, RAINLT_P matches)" % len(rows))
        return
    OUT.write_bytes(blob)
    px = sum(w * h for _n, w, h, _a, _b, _p in rows)
    print("wrote %s  (%d records, %d bytes; %d px = %d bytes at %dbpp before LOAD2)"
          % (OUT, len(rows), len(blob), px, px * BPP // 8, BPP))
    for n, w, h, ax, ay, _p in rows:
        print("   %-10s %3dx%-3d ani(%4d,%4d)" % (n, w, h, ax, ay))
    if drift:
        print("  NOTE: " + drift)


if __name__ == "__main__":
    main()
