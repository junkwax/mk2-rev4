#!/usr/bin/env python3
r"""SINDEL'S SCREAM TEARS THE FLESH OFF - for every fighter in the cast (Wolf only).

MK3 drew this per fighter: seven frames a man (KLRIP/JXRIP/SNRIP... in
RIPFLESH.IMG; `ochar_ripped_anis`, MKLIA.ASM).  Laid side by side they are one
effect and no drawing: every ROW of the standing sprite is smeared BACKWARDS,
away from her, a little further each frame, the upper body first - three
frames with the body still under the streaks, then four where the body is
gone and only the streaks are left, thinning and blowing away, while the legs
break up into loose pixels.  (UMK3 kept one frame a fighter; the seven are
MK3's.)  No MK2 fighter has that art, so this BUILDS it the same way out of
each fighter's own sprite:

  * the source is his STUMBLE pose - TABLE1 row 023h, first frame, the pose
    `sd_rip_victim` (UMK3SDM.ASM) already stands him in - read out of the
    BUILT Wolf ROM (rom/wolf/umk3.zip + tmp/wolf/src/mk2.map), so it is the
    art the game draws, pieces composed on his anchor;
  * fighters that share a body share a lane (the ninjas, Kitana's body), so
    22 fighters are 11 bodies;
  * the pixels keep his own palette INDICES and the records are POF>, so the
    frames wear whatever costume he is in - no palette of their own;
  * one piece a frame, anchored on the stumble frame's anchor, facing right
    as all art does: "back" is -x, and the engine's flip turns it round.

Writes data/FLRIPA.IMG (+B if it would pass LOAD2's ~2 MB ceiling), their
LODs (Wolf linear 0xE58000 on), and src/FLRIPL.ASM - the frames, the lanes
and `sd_rip_lanes`, one long a fighter (0 = no art: the bosses).

    python tools/make_fleshrip.py --apply | --check | --png DIR
"""
from __future__ import annotations

import argparse
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import make_mk1pit as pit          # noqa: E402
import umk3rom                     # noqa: E402

ZIP = ROOT / "rom" / "wolf" / "umk3.zip"
MAP = ROOT / "tmp" / "wolf" / "src" / "mk2.map"
DATA = ROOT / "data"
OUT_ASM = ROOT / "src" / "FLRIPL.ASM"
NCHAR = 22
STUMBLE = 0x23
FRAMES = 7
PACKS = (("FLRIPA", 0xE58000), ("FLRIPB", 0xEE0000))
SPLIT_BYTES = 1_500_000
TAGS = "ABCDEFGHIJKLMNOPQRSTUV"
# WHAT IS LEFT STANDING: MK3's flayed body, SKELRIP1-3 - muscle and gut, not
# bone - straight out of MK3's own art library (it is one drawing for every
# fighter; `a_normal_skel`, MKLIA.ASM).  PON> on its own SKELRIP_P.
RIPFLESH = Path("C:/Users/you/Workplace/deadlythirdcombat-main/deadlythirdcombat-main/RIPFLESH.IMG")
FLAYED = ("SKELRIP1A", "SKELRIP1B", "SKELRIP2A", "SKELRIP2B", "SKELRIP3A", "SKELRIP3B")

# the effect, measured off MK3's own frames (JXRIP1-7: the piece grows 51 ->
# 70 -> 97 px wide while the body stands, then the streaks run 110-120 px
# and their anchor slides 143 -> 163 px behind him)
STREAK = (10, 30, 56)            # frames 1-3: longest streak behind the body, px
GONE_LEN = (70, 85, 95, 90)      # frames 4-7: longest streak
GONE_OFF = (14, 34, 52, 70)      #             how far it has blown back
GONE_DENS = (0.92, 0.75, 0.55, 0.35)
LEG_KEEP = (0.50, 0.28, 0.12, 0.0)
TOP_FULL, TOP_NONE = 0.40, 0.74  # rows above 40% of his height streak fully,
                                 # below 74% not at all (the legs)


def symbols():
    out = {}
    for line in MAP.read_text(errors="replace").splitlines():
        for a, n in re.findall(r"([0-9a-f]{8})\s+([\w\.]+)", line):
            out[n] = int(a, 16)
    return out


def stumble(u, S, oc):
    """(frame address, composed rows, anchor x, anchor y, palette words) or None."""
    try:
        tab = u.l(S["character_anitabs1"] + 32 * oc)
        f = u.l(u.l(tab + 32 * STUMBLE))
        pcs, a = [], f
        while u.l(a):
            pcs.append(u.l(a))
            a += 32
            if len(pcs) > 12:
                return None
        hs = []
        for p in pcs:
            h = dict(w=u.w(p), h=u.w(p + 16), ax=u.sw(p + 32), ay=u.sw(p + 48),
                     sag=u.l(p + 64), ctrl=u.w(p + 96))
            if not (0 < h["w"] <= 400 and 0 < h["h"] <= 300):
                return None
            rows, _ = pit.decode_record(u.g, h["sag"], h["w"], h["h"], h["ctrl"])
            h["rows"] = rows
            hs.append(h)
        pal = u.palette(u.l(S["character_palettes_1"] + 32 * oc))
    except Exception:
        return None
    if not hs:
        return None
    x0 = min(-h["ax"] for h in hs); y0 = min(-h["ay"] for h in hs)
    x1 = max(h["w"] - h["ax"] for h in hs); y1 = max(h["h"] - h["ay"] for h in hs)
    img = [[0] * (x1 - x0) for _ in range(y1 - y0)]
    for h in hs:
        for y, row in enumerate(h["rows"]):
            for x, v in enumerate(row):
                if v:
                    img[y - h["ay"] - y0][x - h["ax"] - x0] = v
    return f, img, -x0, -y0, pal


def rip(img, seed):
    """Seven frames [(rows, x of the source's column 0)] - the canvas only ever
    grows to the LEFT (behind him), so a frame's anchor is the source's plus
    that."""
    rnd = random.Random(seed)
    H, W = len(img), len(img[0])
    # one strength a row, in short runs, so neighbouring rows tear together
    u, r = [], 0
    while r < H:
        n = rnd.choice((1, 1, 2, 2, 3))
        v = 0.0 if rnd.random() < 0.12 else rnd.uniform(0.3, 1.0)
        u += [v] * n
        r += n
    u = u[:H]
    ext = [r for r in range(H) if any(img[r])]
    top, bot = ext[0], ext[-1]

    def hw(r):
        t = (r - top) / max(1, bot - top)
        return max(0.0, min(1.0, (TOP_NONE - t) / (TOP_NONE - TOP_FULL)))

    PAD = max(STREAK[-1], max(GONE_LEN) + max(GONE_OFF)) + 4
    out = []
    for k in range(FRAMES):
        fr = [[0] * (PAD + W) for _ in range(H)]
        for r in range(H):
            row = img[r]
            xs = [x for x in range(W) if row[x]]
            if not xs:
                continue
            xb, xe = xs[0], xs[-1]
            w = hw(r)
            if k < 3:
                for x in xs:
                    fr[r][PAD + x] = row[x]
                L = int(STREAK[k] * u[r] * w)
                seg = min(xe - xb + 1, 20)
                for d in range(1, L + 1):
                    if d > L * 0.55 and rnd.random() < 0.35:
                        continue
                    c = row[xb + d * seg // (L + 1)] or row[xb]
                    fr[r][PAD + xb - d] = c
            else:
                t = k - 3
                keep = LEG_KEEP[t] * (1.0 - w)
                for x in xs:
                    if rnd.random() < keep:
                        fr[r][PAD + x] = row[x]
                if w > 0 and u[r] > 0:
                    L = int(GONE_LEN[t] * u[r] * (0.45 + 0.55 * w))
                    off = int(GONE_OFF[t] * (0.5 + 0.5 * u[r]))
                    span = xe - xb + 1
                    # RUNS, not dots: MK3's streaks are unbroken lines with
                    # gaps torn in them, thinner the further they have blown
                    d = 0
                    while d < L:
                        far = d / max(1, L)
                        on = rnd.randint(3, 14)
                        if rnd.random() < GONE_DENS[t] * (1.0 - 0.45 * far):
                            for e in range(d, min(L, d + on)):
                                c = row[xe - e * span // max(1, L)] or row[xb]
                                x = PAD + xe - off - e
                                if 0 <= x < PAD + W:
                                    fr[r][x] = c
                        d += on + rnd.randint(0, 2 + int(6 * far * (t + 1) / 2))
        out.append((fr, PAD))
    return out


def crop(fr, pad, ax, ay):
    ys = [y for y, r in enumerate(fr) if any(r)]
    if not ys:
        return None
    y0, y1 = ys[0], ys[-1] + 1
    xs = [x for r in fr[y0:y1] for x, v in enumerate(r) if v]
    x0, x1 = min(xs), max(xs) + 1
    rows = [r[x0:x1] for r in fr[y0:y1]]
    return dict(w=x1 - x0, h=y1 - y0, ax=ax + pad - x0, ay=ay - y0,
                px=bytes(v for r in rows for v in r))


def build():
    if not ZIP.exists() or not MAP.exists():
        raise SystemExit(f"{ZIP} / {MAP} missing - run python makewolf.py first")
    u = umk3rom.UMK3(ZIP)
    S = symbols()
    bodies, lane_of = [], []
    for oc in range(NCHAR):
        st = stumble(u, S, oc)
        if st is None:
            lane_of.append(None)
            continue
        f, img, ax, ay, pal = st
        k = next((i for i, b in enumerate(bodies) if b["f"] == f), None)
        if k is None:
            k = len(bodies)
            tag = TAGS[k]
            frames = []
            for n, (fr, pad) in enumerate(rip(img, 0x51DE1 + k)):
                c = crop(fr, pad, ax, ay)
                if c is None or c["w"] > 320 or c["h"] > 220:
                    raise SystemExit(f"body {tag} frame {n + 1}: empty or past ani2's limits")
                c["name"] = f"FR{tag}{n + 1}"
                c["body"] = k
                frames.append(c)
            bodies.append(dict(f=f, tag=tag, pal=pal, frames=frames, ochars=[oc], src=(img, ax, ay)))
        else:
            bodies[k]["ochars"].append(oc)
        lane_of.append(k)
    return bodies, lane_of


def flayed():
    """([record], palette words) - MK3's SKELRIP pieces, as authored."""
    import make_cage_logo as cl
    if not RIPFLESH.exists():
        raise SystemExit(f"{RIPFLESH} missing - MK3's art library holds the flayed body")
    recs, pals = cl.parse_img(RIPFLESH.read_bytes())
    out, pn = [], None
    for n in FLAYED:
        r = recs[n]
        pn = pn if pn is not None else r["palnum"]
        if r["palnum"] != pn:
            raise SystemExit("the flayed body is on more than one palette")
        out.append(dict(name=n, w=r["w"], h=r["h"], ax=r["ax"], ay=r["ay"],
                        px=bytes(v for row in r["px"] for v in row), body="flayed"))
    return out, pals[pn]["words"]


def lod_base(lin):
    return 0x2000000 + (lin - 0x800000) * 8


def outputs(bodies, lane_of):
    files = {}
    fl, flpal = flayed()
    recs = [f for b in bodies for f in b["frames"]]
    packs, size, cur = [[]], 0, 0
    for r in recs:
        n = ((r["w"] + 3) & ~3) * r["h"]
        if size + n > SPLIT_BYTES and packs[cur]:
            packs.append([]); cur += 1; size = 0
        packs[cur].append(r); size += n
    if len(packs) > len(PACKS):
        raise SystemExit("more art than the two packs hold")
    for (stem, lin), group in zip(PACKS, packs + [[]] * (len(PACKS) - len(packs))):
        if not group:
            continue
        used = sorted({r["body"] for r in group})
        entries = [(r["name"], r["ax"], r["ay"], r["w"], r["h"], r["px"], used.index(r["body"]))
                   for r in group]
        plist = [(f"FR{bodies[b]['tag']}_P", 6, bodies[b]["pal"]) for b in used]
        first = stem == PACKS[0][0]
        if first:                       # the flayed body rides the first pack
            entries += [(r["name"], r["ax"], r["ay"], r["w"], r["h"], r["px"], len(plist)) for r in fl]
            plist.append(("SKELRIP_P", 6, flpal))
        files[f"data/{stem}.IMG"] = pit.build_img(entries, plist)
        names = [r["name"] for r in group]
        lod = [f"***> {lod_base(lin):X},1", "IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L",
               ";" + "*" * 62, ";",
               ";  THE FLESH RIP (Sindel's scream, Wolf only) - GENERATED by",
               f";  tools/make_fleshrip.py --apply.  Linear 0x{lin:X}.  POF>: the frames",
               ";  are each fighter's own sprite smeared, in his own palette indices,",
               ";  so they are drawn in whatever costume he wears.",
               ";", ";" + "*" * 62, "ZON>", f"ASM> {stem}.TBL", f"{stem}.IMG", "POF>", "PPP> 6"]
        lod += ["---> " + ",".join(names[i:i + 8]) for i in range(0, len(names), 8)]
        if first:
            lod += ["PON>", "PPP> 6", "---> " + ",".join(FLAYED)]
        files[f"data/{stem}.LOD"] = ("\n".join(lod) + "\n").encode()
    o = [";" + "*" * 70,
         ";  THE FLESH RIP - GENERATED by tools/make_fleshrip.py.  Do not hand-edit.",
         ";  Included by UMK3SDM.ASM (Wolf only).  One piece a frame; sd_rip_lanes",
         ";  is indexed by the VICTIM's ochar, 0 = no art (he keeps the old shake).",
         ";" + "*" * 70, "", "\t.data", ""]
    for b in bodies:
        o.append(f"; body {b['tag']} - ochar " + ", ".join(str(x) for x in b["ochars"]))
        for f in b["frames"]:
            o.append(f"fr_{f['name']}\t.long\t{f['name']},0")
        o.append(f"sd_rip_{b['tag']}")
        for f in b["frames"]:
            o.append(f"\t.long\tfr_{f['name']}")
        o.append("\t.long\t0")
        o.append("")
    o.append("; what is left standing - MK3's flayed body (a_normal_skel)")
    for k in (1, 2, 3):
        o.append(f"sd_SKELRIP{k}\t.long\tSKELRIP{k}A,SKELRIP{k}B,0")
    o += ["sd_a_flayed", "\t.long\tsd_SKELRIP1,sd_SKELRIP2,sd_SKELRIP3", "\t.long\t0", "",
          "SKELRIP_P:", f"\t.word\t{len(flpal)}"]
    for i in range(0, len(flpal), 8):
        o.append("\t.word\t" + ",".join("0%04xh" % v for v in flpal[i:i + 8]))
    o.append("")
    o.append("sd_rip_lanes")
    for oc, k in enumerate(lane_of):
        o.append(f"\t.long\t{'sd_rip_' + bodies[k]['tag'] if k is not None else '0'}\t\t; {oc}")
    o += ["", "\t.text"]
    files["src/FLRIPL.ASM"] = ("\n".join(o) + "\n").encode()
    return files, packs


def png(bodies, out):
    from PIL import Image
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    for b in bodies:
        img, ax, ay = b["src"]
        cells = [dict(w=len(img[0]), h=len(img), ax=ax, ay=ay, px=bytes(v for r in img for v in r))] + b["frames"]
        mx = max(c["ax"] for c in cells); my = max(c["ay"] for c in cells)
        W = sum(mx + c["w"] - c["ax"] + 6 for c in cells)
        H = my + max(c["h"] - c["ay"] for c in cells)
        cv = Image.new("RGB", (W, H), (24, 24, 34))
        x = 0
        for c in cells:
            for i, v in enumerate(c["px"]):
                if v:
                    cv.putpixel((x + mx - c["ax"] + i % c["w"], my - c["ay"] + i // c["w"]),
                                pit.rgb(b["pal"][v] if v < len(b["pal"]) else 0x7C1F))
            x += mx + c["w"] - c["ax"] + 6
        cv.save(out / f"fleshrip_{b['tag']}.png")
    print(f"wrote {len(bodies)} sheets in {out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--png")
    a = ap.parse_args()
    if a.check and (not ZIP.exists() or not MAP.exists()):
        print("make_fleshrip: no Wolf build to read the poses from - not checked")
        return 0
    bodies, lane_of = build()
    files, packs = outputs(bodies, lane_of)
    if a.png:
        png(bodies, a.png)
    if a.apply:
        for rel, data in files.items():
            (ROOT / rel).write_bytes(data)
            print(f"wrote {rel}  ({len(data):,} bytes)")
        print(f"{len(bodies)} bodies, {sum(len(p) for p in packs)} frames in {sum(1 for p in packs if p)} pack(s)")
    if a.check:
        bad = [rel for rel, data in files.items()
               if not (ROOT / rel).exists() or (ROOT / rel).read_bytes() != data]
        if bad:
            print("make_fleshrip: STALE - " + ", ".join(bad) + "  (python tools/make_fleshrip.py --apply)")
            return 1
        print(f"make_fleshrip: OK ({len(bodies)} bodies, {sum(len(p) for p in packs)} frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
