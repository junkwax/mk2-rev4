#!/usr/bin/env python3
r"""Build data/RAINBUB.IMG - the WATER BUBBLE the man held in RAIN's cloud is
suspended in (rainbub / rbub_shell, MAINEQU.ASM).

MK1's Hydro Sphere is a translucent ball of water with the victim inside it.
NOTHING ON THIS HARDWARE BLENDS, so a ball you can see through cannot be
drawn as a filled sprite - it would simply hide him.  What is drawn instead
is a SHELL: the rim, the speculars and a few caustic streaks, with the whole
interior left at index 0 (transparent) so every pixel of the man inside is
the DMA's own.  That is also what makes it cheap - the art is ~20% opaque and
the LOD is ZON>, so the zero runs cost almost nothing.

IT RIDES THE CLOUD'S OWN PALETTE, RNCLOUD_P, and that is not a convenience:

  * it is already linked and already in the ROM, so no palette is
    hand-carried into an IMGPAL file and none can drift;
  * make_raincld_img.py's reindex_cloud already sorted slots 5..31 into ONE
    CONTIGUOUS LUMINANCE RAMP (59 -> 210), which is the whole reason
    rzap_cycle can rotate it without swapping unrelated colours;
  * slots 1-4 are the burst's bright cyan-whites (luminance 221-241) and are
    OUTSIDE the cycled window, so a specular drawn in them STAYS PUT while
    the body of the rim flows underneath - exactly the split the cloud's own
    design note argues for.

THE RIM'S INDEX VARIES WITH ANGLE, not just with depth through the band.
That is what makes a palette rotation read as light TRAVELLING AROUND the
sphere rather than the whole rim pulsing: going once round the circle walks
the ramp, so shifting the ramp slides the bright part along it.

    python tools/make_rainbub_img.py            # write data/RAINBUB.IMG
    python tools/make_rainbub_img.py --check    # Phase D: prove it matches
    python tools/make_rainbub_img.py --png DIR  # preview the frames
"""
import argparse
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from make_mk1_raiden_pal import read_img, write_img, rgb   # noqa: E402

SRC = ROOT / "data" / "RAINCLD.IMG"        # template records AND the palette
OUT = ROOT / "data" / "RAINBUB.IMG"

W = H = 120                 # a standing fighter's box is ~55 x 100, so the
                            # sphere round it is sqrt(55^2+100^2) ~ 114 across
CX = CY = (W - 1) / 2.0
R = 58.0                    # outer radius
RIM = 5.5                   # rim band thickness at its thinnest
# ONE FRAME, and that is a MEASUREMENT, not a preference.  LOAD2 packs a
# 120x120 5bpp shell at 19% coverage into 7,225 bytes - ZON> saves only ~20%,
# because the transparent interior splits every row into two runs rather than
# one - so three frames are 21,675 against a 16,940-byte hole.  The motion this
# art was designed for is the PALETTE CYCLE (the rim's index walks a triangle
# round the circle for exactly that), so the frames were the part to drop.  The
# frame table and stepper below are still general: raise this and add records to
# data/RAINBUB.LOD and there is room for one more in the slot, not two.
FRAMES = 1

# RNCLOUD_P's own layout, proved in --check rather than assumed here.
PAL = "RNCLOUD_P"
SPEC_LO, SPEC_HI = 1, 4     # frozen bright cyan-whites (the burst's)
BODY_LO, BODY_HI = 5, 20    # rzap_cycle's window (rzap_cyc_start/count)
BRIGHT_HI = 31              # 21..31 are ramp too, but static


def field(frame):
    """-> a [H][W] float intensity image, 0 = nothing drawn."""
    ph = 2.0 * math.pi * frame / FRAMES
    f = [[0.0] * W for _ in range(H)]
    for y in range(H):
        dy = y - CY
        for x in range(W):
            dx = x - CX
            d = math.hypot(dx, dy)
            if d > R + 0.5:
                continue
            a = math.atan2(dy, dx)          # 0 = right, +pi/2 = down

            # --- the rim.  Thicker low and to the right, where a real sphere
            # pools its light, and thinnest at the top.
            thick = RIM * (1.0 + 0.55 * math.sin(a) + 0.25 * math.cos(a))
            thick = max(2.0, thick)
            inner = R - thick
            v = 0.0
            if d >= inner:
                t = (d - inner) / thick                 # 0 inner .. 1 outer
                v = 0.45 + 0.55 * math.sin(math.pi * min(1.0, t) ** 0.7)
                v *= 1.0 - 0.28 * max(0.0, math.cos(a + 1.9))

            # --- the specular: a small bright blob up and to the LEFT, plus
            # the bounce highlight low and to the RIGHT.
            for (ang, rad, rx, ry, amp) in (
                    (-2.30, 0.63 * R, 9.0, 15.0, 1.60),     # key light
                    (0.75, 0.80 * R, 6.5, 9.0, 1.15)):      # bounce
                sx, sy = CX + rad * math.cos(ang), CY + rad * math.sin(ang)
                q = ((x - sx) / rx) ** 2 + ((y - sy) / ry) ** 2
                if q < 1.0:
                    v = max(v, amp * (1.0 - q) ** 0.5)

            # --- caustics: thin arcs inside the shell that drift per frame.
            for k, (rad, wid, span, amp) in enumerate(
                    ((0.74, 2.1, 0.55, 0.88), (0.52, 1.8, 0.40, 0.74),
                     (0.86, 1.6, 0.30, 0.82))):
                c = rad * R
                if abs(d - c) < wid:
                    centre = -2.1 + ph + k * 2.0
                    da = (a - centre + math.pi) % (2 * math.pi) - math.pi
                    if abs(da) < span:
                        e = (1.0 - abs(da) / span) * (1.0 - abs(d - c) / wid)
                        v = max(v, amp * e)
            f[y][x] = v
    return f


def quantise(f):
    """intensity -> RNCLOUD_P index.  The BODY's index walks the ramp with the
    ANGLE, so rotating the ramp slides light round the sphere; the speculars
    go in the frozen 1-4 so they do not travel with it."""
    px = [[0] * W for _ in range(H)]
    span = BODY_HI - BODY_LO
    for y in range(H):
        dy = y - CY
        for x in range(W):
            v = f[y][x]
            if v < 0.16:
                continue
            if v >= 1.05:                                   # specular
                k = SPEC_HI - int(min(3, (v - 1.05) / 0.22))
                px[y][x] = max(SPEC_LO, min(SPEC_HI, k))
                continue
            dx = x - CX
            a = math.atan2(dy, dx)
            # A TRIANGLE round the circle, not a saw: a saw jumps BODY_HI ->
            # BODY_LO at the seam and that seam is a hard edge down one side
            # of the rim.  0 at both ends and 1 opposite is continuous, and a
            # palette rotation then sweeps the bright part round symmetrically.
            walk = 1.0 - abs(2.0 * ((a + math.pi) / (2 * math.pi)) - 1.0)
            i = BODY_LO + int(round(walk * span))
            i += int(round((v - 0.16) / 0.89 * 6.0)) - 2    # depth in the band
            # CLAMPED TO THE CYCLED WINDOW.  Anything above BODY_HI is outside
            # rzap_cycle's rotation and would sit still while the rest of the
            # rim flowed past it - a brighter rim is not worth a dead patch.
            if i > BODY_HI:
                i = BODY_HI
            if i < BODY_LO:
                i = BODY_LO
            px[y][x] = i
    return px


def build():
    imgs, pals = read_img(SRC)
    pal = next(p for p in pals if p["name"] == PAL)
    tmpl = imgs[0]
    out = []
    for n in range(FRAMES):
        px = quantise(field(n))
        r = dict(tmpl)
        r["name"] = "RNBUB%d" % (n + 1)
        r["w"], r["h"] = W, H
        r["ax"], r["ay"] = int(CX + 0.5), int(CY + 0.5)     # the anchor IS the
                                                            # centre, so the code
                                                            # places it on the
                                                            # victim's middle
        r["palnum"] = pal["palnum"]
        r["px"] = px
        out.append(r)
    return out, [pal]


def report(recs):
    for r in recs:
        on = sum(1 for row in r["px"] for v in row if v)
        print("  %-8s %dx%d  anchor %d,%d  opaque %d/%d (%.1f%%)  max idx %d"
              % (r["name"], r["w"], r["h"], r["ax"], r["ay"], on, W * H,
                 100.0 * on / (W * H), max(v for row in r["px"] for v in row)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--png", metavar="DIR")
    a = ap.parse_args()

    recs, pals = build()

    # The palette's shape is what the art is indexed against, so prove it
    # rather than trusting the comment above.
    words = pals[0]["words"]
    if len(words) != 32:
        print("FAIL: %s has %d entries, not 32" % (PAL, len(words)))
        return 1
    lum = [0.299 * rgb(w)[0] + 0.587 * rgb(w)[1] + 0.114 * rgb(w)[2] for w in words]
    if not all(lum[i] <= lum[i + 1] + 6 for i in range(BODY_LO, 31)):
        print("FAIL: %s slots %d..31 are no longer one rising ramp - the art is"
              " indexed against that order" % (PAL, BODY_LO))
        return 1
    if min(lum[SPEC_LO:SPEC_HI + 1]) <= max(lum[BODY_LO:]):
        print("FAIL: %s slots %d-%d are no longer brighter than the ramp, so a"
              " specular drawn in them would not read as one" % (PAL, SPEC_LO, SPEC_HI))
        return 1

    if a.png:
        from PIL import Image
        d = Path(a.png)
        d.mkdir(parents=True, exist_ok=True)
        for r in recs:
            im = Image.new("RGB", (W, H), (32, 32, 40))
            for y in range(H):
                for x in range(W):
                    v = r["px"][y][x]
                    if v:
                        im.putpixel((x, y), rgb(words[v]))
            im.resize((W * 3, H * 3), Image.NEAREST).save(d / (r["name"] + ".png"))
        print("wrote %d previews to %s" % (len(recs), d))

    if a.check:
        if not OUT.exists():
            print("FAIL: %s is missing - run tools/make_rainbub_img.py" % OUT.name)
            return 1
        have, _ = read_img(OUT)
        want = {r["name"]: r for r in recs}
        if len(have) != len(want):
            print("FAIL: %s has %d records, expected %d" % (OUT.name, len(have), len(want)))
            return 1
        for r in have:
            w = want.get(r["name"])
            if w is None:
                print("FAIL: unexpected record %s" % r["name"])
                return 1
            if (r["w"], r["h"], r["ax"], r["ay"]) != (w["w"], w["h"], w["ax"], w["ay"]):
                print("FAIL: %s geometry drifted" % r["name"])
                return 1
            if r["px"] != w["px"]:
                print("FAIL: %s pixels differ from the generator" % r["name"])
                return 1
        print("RAINBUB.IMG OK - %d records match the generator, %s intact"
              % (len(have), PAL))
        return 0

    n = write_img(OUT, recs, pals)
    print("wrote %s (%d bytes)" % (OUT, n))
    report(recs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
