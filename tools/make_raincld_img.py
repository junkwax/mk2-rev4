#!/usr/bin/env python3
r"""Build data/RAINCLD.IMG - RAIN's water move (the storm cloud), 1:1 from MK
Trilogy (N64).

Trilogy's do_proj_rain_zap / rain_zap_proc (MKZAP.C) throw a storm cloud that
traps the man it hits and lets Rain steer him with the stick.  Its art is in
SEG/CHARDATA/MNINJA and is decoded here by tools/make_rainn64_img.py's
decompressors (transcribed from U64MAIN.C).  Nothing is redrawn - every pixel
index is the N64's:

  RAPROFORM1,3,4,6,7  the cloud forming      a_rain_cloud parts 1 + 3
  RAPROLOOP1,4,5      the cloud in flight    (j_rain, looping)
  RNZAP11-16          the cloud bursting     a_rain_cloud part 4
  RNDROP01-5B         a raindrop in flight   FX_SONYA_GLOBE's glob_fly -
  RNDROP06-13         a raindrop splashing   the ninja ANIM_ZAP parts 3/4

    python tools/make_raincld_img.py            # write data/RAINCLD.IMG
    python tools/make_raincld_img.py --check    # Phase D: fail if drifted

## Re-anchored from N64 pixels to arcade pixels

The N64 draws the arcade world at 80% x / 85% y (SYSTEM.H SCF_X / SCF_Y) and
its art is drawn at that size.  The cloud's anipoints are offsets from RAIN'S
anchor (Trilogy's ani_sladd hangs the cloud off him), so carried across
unchanged they would put a cloud thrown in an arcade-size world 20% too close
to his hand.  Every cloud-object frame (RAPROFORM, RAPROLOOP, RNZAP) is
re-anchored as

    anix' = round(anix / 0.80)
    aniy' = round((aniy + 9) / 0.85)

The +9 is Trilogy's adj_rain_proj (MKANI.C: adjust_xy_a5(obj, 0, -9)),
applied the tick the cloud appears and carried by every later frame - baked
in here so the MK2 object can stay lined up on Rain's anchor.  The pixels
stay N64-size, as the lightning bolt's do (data/RAINBOLT.IMG).

The drops keep Trilogy's anipoints: rain_drop_proc places them outright, and
only their frame-to-frame registration matters.

## Depths

  RNCLOUD_P  32 colours -> the cloud at 5bpp (every index up to 31 is used)
  RNZAP_P    RNCLOUD_P's first 8 entries -> the burst at 3bpp.  RNZAP is
             uncompress_8 art, indices 0..4 of the SAME ramp, and at runtime
             the object keeps RNCLOUD_P for it.  The 8-entry record exists
             only for LOAD2: an explicit PPP> 3 is silently raised back to
             the palette's own depth when the palette has more than 8
             colours, so pointing RNZAP at the 32-entry ramp would pack it
             at 5.  Nothing in src/ carries RNZAP_P - the LOD is POF> there.
  RNDROP_P   9 colours (NEWdrop_p), padded to 16 -> 4bpp
"""
import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "data" / "RAINCLD.IMG"

SCF_X, SCF_Y = 0.80, 0.85
ADJ_Y = 9                       # adj_rain_proj

CLOUD = ["RAPROFORM1", "RAPROFORM3", "RAPROFORM4", "RAPROFORM6", "RAPROFORM7",
         "RAPROLOOP1", "RAPROLOOP4", "RAPROLOOP5",
         "RNZAP11", "RNZAP12", "RNZAP13", "RNZAP15", "RNZAP16"]
DROPS = ["RNDROP01", "RNDROP02", "RNDROP03", "RNDROP04", "RNDROP05", "RNDROP5B",
         "RNDROP06", "RNDROP07", "RNDROP08", "RNDROP09", "RNDROP10", "RNDROP11",
         "RNDROP12", "RNDROP13"]
# IMG palette name, N64 label
PALS = [("RNCLOUD_P", "RNCLOUD_PAL"), ("RNDROP_P", "NEWdrop_p")]


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# Slots 0-4 are FROZEN.  RNZAP (the burst) draws from indices 0..4 of this
# same palette and RNZAP_P is literally RNCLOUD_P's first 8 entries, so
# moving those colours would re-index the burst as well - and a colour that
# slid past slot 7 would fall outside its 3bpp window entirely.
CLOUD_FREEZE = 5


def luma(c):
    """5:5:5 -> perceptual brightness, the axis the ramp is sorted on."""
    r, g, b = (c >> 10) & 31, (c >> 5) & 31, c & 31
    return (r * 299 + g * 587 + b * 114) / 1000


def reindex_cloud(cols, frames):
    """Sort the cloud's shades into one contiguous LUMINANCE ramp and remap
    every pixel to match.

    This is what makes a palette CYCLE possible.  As Trilogy authored it the
    32 colours are in no order at all - bright highlights at 1-5, then darks
    and mid-tones interleaved for the rest - so rotating a range of entries
    swaps unrelated colours and reads as a corrupt palette rather than as
    motion (the failure [[project_palette_cycle_scan]] documents).  Sorted,
    neighbouring shades sit at neighbouring indices, and because the art is
    smoothly shaded (measured: median neighbour step 1.0 luma of a possible
    31, 67% of adjacent pixels within 2) rotating the ramp moves light
    THROUGH the cloud.

    Returns the new palette and the new-slot -> old-index order.
    """
    tail = sorted(range(CLOUD_FREEZE, len(cols)), key=lambda i: luma(cols[i]))
    order = list(range(CLOUD_FREEZE)) + tail
    perm = {old: new for new, old in enumerate(order)}
    for f in frames:
        if f["pal"] in ("RNCLOUD_PAL", "RNZAP_PAL"):
            # bytes, not a list: n64.build concatenates these with padding
            f["px"] = bytes(perm[v] for v in f["px"])
    return [cols[old] for old in order], order


def build():
    n64 = load("make_rainn64_img")
    fr = {f["name"]: f for f in n64.frames()}
    allpals = {label: (name, cols, b) for name, cols, b, label in n64.palettes()}
    pals = []
    for name, label in PALS:
        _n, cols, b = allpals[label]
        pals.append((name, cols, b, label))
    out = []
    for name in CLOUD + DROPS:
        f = dict(fr[name])
        if name.startswith("RNZAP"):
            f["pal"] = "RNZAP_PAL"
        if name in CLOUD:
            f["anix"] = round(f["anix"] / SCF_X)
            f["aniy"] = round((f["aniy"] + ADJ_Y) / SCF_Y)
        out.append(f)
    # the ramp, and the pixels that index it, together
    _n, cols, _b = allpals["RNCLOUD_PAL"]
    cols, order = reindex_cloud(cols, out)
    for i, (name, _c, b, label) in enumerate(pals):
        if label == "RNCLOUD_PAL":
            pals[i] = (name, cols, b, label)
    pals.append(("RNZAP_P", cols[:8], 3, "RNZAP_PAL"))    # packing only, see top
    for f in out:
        if f["pal"] == "RNZAP_PAL" and f["px"] and max(f["px"]) >= 8:
            sys.exit("%s uses index %d after the re-index - past RNZAP_P's 8"
                     % (f["name"], max(f["px"])))
    return n64, out, pals


def pal_asm(name, cols):
    rows = [cols[i:i + 8] for i in range(0, len(cols), 8)]
    body = "\n".join("\t.word\t" + ",".join("0%04XH" % c for c in r) for r in rows)
    return "%s:\n\t.word\t %d\n%s\n" % (name, len(cols), body)


def pal_in_asm_drift(pals):
    """RNCLOUD_P / RNDROP_P are hand-carried into src/IMGPAL6.ASM."""
    import re
    txt = (ROOT / "src" / "IMGPAL6.ASM").read_text(encoding="latin-1")
    for name, cols, _b, label in pals:
        if name == "RNZAP_P":
            continue                    # packing only - never in src/
        m = re.search(r"^" + name + r":\s*\n\s*\.word\s+(\d+)\s*\n((?:\s*\.word[^\n]*\n)+)", txt, re.M)
        if not m:
            return "%s not found in src/IMGPAL6.ASM" % name
        have = [int(x, 16) for x in re.findall(r"0([0-9A-Fa-f]{4})H", m.group(2))]
        if int(m.group(1)) != len(cols) or have != cols:
            return "src/IMGPAL6.ASM %s differs from the N64's %s - re-copy it" % (name, label)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--pal-asm", action="store_true", help="print the palettes as ASM")
    a = ap.parse_args()
    try:
        n64, fr, pals = build()
    except SystemExit as e:
        if a.check and "not found" in str(e):
            print("RAINCLD: Trilogy source not present - skipping check")
            return 0
        raise
    if not n64.NJ.exists():
        print("RAINCLD: Trilogy source not present - skipping check")
        return 0
    size = {label: len(cols) for _n, cols, _b, label in pals}
    for f in fr:
        if max(f["px"]) >= size[f["pal"]]:
            sys.exit("%s uses index %d, past %s" % (f["name"], max(f["px"]), f["pal"]))
    data = n64.build(fr, pals)
    if a.pal_asm:
        for name, cols, _b, _l in pals:
            print(pal_asm(name, cols))
        return 0
    if a.check:
        if not OUT.exists() or OUT.read_bytes() != data:
            print("RAINCLD: %s missing or differs from a fresh build - regenerate it" % OUT)
            return 1
        bad = pal_in_asm_drift(pals)
        if bad:
            print("RAINCLD: " + bad)
            return 1
        print("RAINCLD.IMG OK (%d frames, palettes match)" % len(fr))
        return 0
    for f, b in zip(fr, n64.read_back(data)):
        if (f["name"], f["w"], f["h"], f["anix"], f["aniy"], f["px"]) != b:
            sys.exit("round trip failed on " + f["name"])
    OUT.write_bytes(data)
    print("wrote %s  (%d frames, %d bytes)" % (OUT, len(fr), len(data)))
    for f in fr:
        print("   %-11s %3dx%-3d ani(%4d,%4d)  max idx %2d" %
              (f["name"], f["w"], f["h"], f["anix"], f["aniy"], max(f["px"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
