#!/usr/bin/env python3
r"""THE THRONE ROOM's EMPTY THRONE - drawn when Shang Tsung is in the fight.

Shang Tsung sits on the throne of THE THRONE ROOM (curback 01Ch, src/MK1THRN.ASM)
and watches the fight.  When either player - human or CPU - IS Shang Tsung, he
cannot also be up there, so the stage leaves him out and draws the throne
empty instead (mk1thrn_calla, the way sitting_kahn leaves Kahn's chair).

THE ART is `thrnchair` in data/MKBGANI.IMG, the whole throne repainted empty
(107x152, THRNCHR_p, 127 colours - 7bpp).  The whole record does not fit:
packed it is ~9.9KB and the video ROM's largest free run is under 3KB.  But
almost all of it is ALREADY ON SCREEN - the throne's back and arms are plane
5's background, and Shang only ever covers the middle of it.  So this packs a
PATCH, and the patch is decided against EVERY CAMERA THE THRONE IS ON SCREEN
AT, not one: plane 5 is the only background plane that moves with the patch
(it scrolls at plane 4's rate).  The wall and the gong are plane 7 (1/32 of a
pixel slower per camera pixel - up to ~15 px of drift) and MK1's own throne
base is plane 8, which never scrolls at all.  The first cut decided against the
start camera alone, and every pixel it left to "matching" plane 7 or 8 showed
something else as soon as the camera moved: a missing pixel on the seat, a
blue gap under it.

    under Shang (the union of every packed record of his, at his anchor):
      chair opaque       drawn, unless plane 5 is that exact colour there
      chair transparent  left alone if plane 5 is there (it moves with us) or
                         if only the wall/gong (planes 6-7) ever shows there -
                         that is the room's own parallax.  WALL_RED if MK1's
                         throne base (plane 8, which never scrolls) or the sky
                         can show there at any on-screen camera: he hid both
    anywhere else in the chair's box, only where the SKY can show - a pixel
    no plane draws at some on-screen camera, so the stage's erase colour (the
    sky blue) leaks through.  MK1's plane-7 wall has such holes at the top of
    the throne back, between the dragon ornaments, and they leak with Shang
    seated too:
      chair opaque       drawn
      chair transparent  the colour planes 6-8 show there most often across
                         those cameras, nearest in the chair's palette

--check re-simulates every on-screen camera with the patch in place and fails
if the sky shows anywhere in the chair's box, or MK1's throne base shows under
Shang.  A flat WALL_RED over the wall next to the throne back was tried and
cut a notch into the gong as soon as the camera moved: plane 7 slides there.

The cost, chosen 2026-10-05: the parts of `thrnchair` outside his silhouette
are not drawn unless they plug a sky hole - its gold feet and repainted base
stay MK1's.  WALL_RED (6b0000, the wall either side of the gap under the seat)
is not in the chair's palette, so it is appended as THRCHP_P's 128th entry -
the one slot PPP> 7 had spare.

WHERE IT GOES is measured, not chosen: `thrnchair` is template-matched
against the stage at its start camera, and its world top-left is CHAIR_XY on
plane 5.  Plane 5 scrolls at the same rate as plane 4 (mk1t_rate5 ==
mk1t_rate4), the plane Shang is drawn against, so the patch rides his list
(mk1p_sky_lst) and is laid by his own mk1t_sh_piece: each strip's anipoint is
set so that his anchor (mk1t_sh_x, mk1t_sh_y) minus the anipoint is the
strip's top-left.  --check fails if the match moves or either rate changes.

The patch is cut into STRIPS by rows, one per free run (STRIPS below), because
no single run holds it.

    python tools/make_thrnchair.py            # write data/THRCHP.IMG, the LODs, src/THRCHP.ASM
    python tools/make_thrnchair.py --check    # Phase D: fail if any of them has drifted
    python tools/make_thrnchair.py --png DIR  # the patch, the chair, and the stage with each

Edit the chair in IMGTOOL (data/MKBGANI.IMG, `thrnchair`), then re-run this
and rebuild.  Never edit data/THRCHP.IMG by hand.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import make_mk1pit as pit        # noqa: E402  (IMG writer, LOD address, IRW decode)
import make_mk1throne as thr     # noqa: E402  (MK1 layout, render, plane_x)

DATA = ROOT / "data"
SRC = ROOT / "src"
CHAIR_IMG = DATA / "MKBGANI.IMG"
CHAIR_REC = "thrnchair"
CHAIR_PAL = "THRNCHR_p"
SHANG_IMG = DATA / "MK1TRSH.IMG"
SHANG_LODS = ("MK1TRSH", "MK1TRS2")
SCREEN_W = 400

OUT_IMG = DATA / "THRCHP.IMG"
OUT_ASM = SRC / "THRCHP.ASM"
PAL_NAME = "THRCHP_P"           # NOT THRNCHR_p: that name is MKBGANI.IMG's
PPP = 7                         # THRNCHR_p has 127 entries; WALL_RED is the 128th
WALL_RED = 13 << 10             # 15-bit 6b0000 - the wall either side of the gap

# MEASURED: thrnchair's world top-left on plane 5, from the template match at
# the start camera (3,930 of its 10,641 pixels identical to the stage there;
# the rest are under Shang or the repaint).  --check re-measures it.
CHAIR_XY = (649, 53)
MATCH_MIN = 3500

# (record, LOD/IRW name, phys start, phys end, bank, first chair row, row after last)
# Each is the free tail of one of THE THRONE ROOM's own packs - finished,
# generated art - with the strip's base rounded up to 0x100 past that pack's
# payload.  makevrom.py's slot ends for MK1TRS2, MK1TR1 and MK1TR2 are pulled
# back to these bases; make_mk1throne.py's PACKS/SHANG_PACKS are NOT, because
# its deal fills to 90% of those numbers and a smaller one would re-deal the
# stage.  If that tool's art ever grows into a strip, makevrom refuses the
# overlap.  Rows cut at 61 and 97 off a packed-size estimate: ~1.6K/1.4K/1.3K
# against 2,304/2,048/1,792 - over 28% spare, against the 3-14% this tree's
# estimates run low (the first cut's estimate ran 7% under LOAD2).
STRIPS = [
    ("THRCHP1", "THRCHP1", 0x9E7700, 0x9E8000, 1, 0, 61),     # MK1TRS2's tail
    ("THRCHP2", "THRCHP2", 0x796C00, 0x797400, 0, 61, 97),    # MK1TR1's tail
    ("THRCHP3", "THRCHP3", 0xBFBB00, 0xBFC200, 1, 97, 152),   # MK1TR2's tail
]

LIB = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
TAB = "\t"


def read_img(path):
    data = path.read_bytes()
    imgcnt, palcnt, oset = LIB.unpack_from(data, 0)[:3]
    imgs = {}
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        name = r[0].split(b"\0")[0].decode()
        ax = r[2] - 0x10000 if r[2] & 0x8000 else r[2]
        ay = r[3] - 0x10000 if r[3] & 0x8000 else r[3]
        w, h, palnum, off = r[4], r[5], r[6], r[7]
        stride = (w + 3) & ~3
        imgs[name] = dict(w=w, h=h, ax=ax, ay=ay, palnum=palnum,
                          px=[list(data[off + y * stride:off + y * stride + w]) for y in range(h)])
    pals = {}
    p0 = oset + imgcnt * IMAGE.size
    for i in range(palcnt - 3):
        name, _pad, bpp, cnt, fo, *_ = PALETTE.unpack_from(data, p0 + i * PALETTE.size)
        pals[name.split(b"\0")[0].decode()] = dict(
            palnum=i + 3, bpp=bpp, words=[struct.unpack_from("<H", data, fo + 2 * k)[0] for k in range(cnt)])
    return imgs, pals


def asm_set(path, name):
    m = re.search(r"^" + re.escape(name) + r"\s+\.set\s+(\S+)", path.read_text(errors="replace"), re.M)
    if not m:
        raise SystemExit(f"{name} not found in {path.name}")
    v = m.group(1)
    return int(v[:-1], 16) if v.upper().endswith("H") else int(v)


def lod_records(name):
    text = (DATA / f"{name}.LOD").read_text(errors="replace")
    return [r.strip() for line in re.findall(r"^--->\s*(.+)$", text, re.M) for r in line.split(",")]


def chair():
    imgs, pals = read_img(CHAIR_IMG)
    if CHAIR_REC not in imgs:
        raise SystemExit(f"{CHAIR_REC} is not in {CHAIR_IMG.name}")
    rec = imgs[CHAIR_REC]
    pal = pals.get(CHAIR_PAL)
    if pal is None or rec["palnum"] != pal["palnum"]:
        raise SystemExit(f"{CHAIR_REC} is not on {CHAIR_PAL} any more")
    if len(pal["words"]) > 1 << PPP:
        raise SystemExit(f"{CHAIR_PAL} has {len(pal['words'])} entries - more than PPP> {PPP} holds")
    return rec, pal


def shang_cover(W, H):
    """[y][x] True where any packed Shang record draws, in chair space."""
    ax, ay = asm_set(SRC / "MK1THRNB.ASM", "mk1t_sh_x"), asm_set(SRC / "MK1THRNB.ASM", "mk1t_sh_y")
    imgs, _ = read_img(SHANG_IMG)
    cov = [[False] * W for _ in range(H)]
    names = [n for lod in SHANG_LODS for n in lod_records(lod)]
    for n in names:
        im = imgs[n]
        ox, oy = ax - im["ax"] - CHAIR_XY[0], ay - im["ay"] - CHAIR_XY[1]
        for y, row in enumerate(im["px"]):
            for x, v in enumerate(row):
                if v and 0 <= oy + y < H and 0 <= ox + x < W:
                    cov[oy + y][ox + x] = True
    return cov, (ax, ay), len(names)


def render_planes(L, pred):
    mods = L["mods"]
    try:
        L["mods"] = [m for m in mods if pred(m["plane"])]
        return thr.render(L, L["rec"]["start"], show_ground=False)
    finally:
        L["mods"] = mods


def stage_layers(L):
    """The stage at its start camera: (behind = planes 5-8 only, full)."""
    return render_planes(L, lambda p: p >= 5), render_planes(L, lambda p: True)


def check_rates():
    b = SRC / "MK1THRNB.ASM"
    r4, r5 = asm_set(b, "mk1t_rate4"), asm_set(b, "mk1t_rate5")
    if r4 != r5:
        raise SystemExit(f"plane 4 ({r4:X}h) and plane 5 ({r5:X}h) no longer scroll together - "
                         "the patch cannot ride Shang's list any more")


def measure(L, rec, pal):
    """Re-find thrnchair on the stage: CHAIR_XY must still be the best match."""
    _behind, full = stage_layers(L)
    sp = full.load()
    worldy, start = L["rec"]["worldy"], L["rec"]["start"]
    cx, cy = CHAIR_XY[0] - start, CHAIR_XY[1] - worldy      # every plane is at `start` there

    def score(ox, oy):
        n = 0
        for y, row in enumerate(rec["px"]):
            for x, v in enumerate(row):
                if v and 0 <= ox + x < full.width and 0 <= oy + y < full.height \
                        and sp[ox + x, oy + y] == thr.rgb(pal["words"][v]):
                    n += 1
        return n

    here = score(cx, cy)
    if here < MATCH_MIN:
        raise SystemExit(f"{CHAIR_REC} matches the stage in only {here} pixels at CHAIR_XY {CHAIR_XY} "
                         f"(needs {MATCH_MIN}) - the art or the stage moved")
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        if score(cx + dx, cy + dy) >= here:
            raise SystemExit(f"CHAIR_XY {CHAIR_XY} is no longer the best match ({dx:+d},{dy:+d} ties or wins)")
    return here


def world_plane(L, plane):
    """One plane drawn in WORLD coordinates, exactly as thr.render lays it:
    (rgb int array with -1 where nothing is drawn, world x0, world y0)."""
    import numpy as np
    ms = [m for m in L["mods"] if m["plane"] == plane]
    boxes = []
    for m in ms:
        for blk in m["blks"]:
            im = L["imgs"][blk[3] & 0xFFF]
            boxes.append((m["x"] + blk[1], m["y"] + blk[2], im["w"], im["h"]))
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    arr = np.full((y1 - y0, x1 - x0), -1, dtype=np.int64)
    for m in ms:
        for blk in sorted(m["blks"], key=lambda b: -(b[0] & 0xFFF0)):
            f, bx, by, hw = blk
            im = L["imgs"][hw & 0xFFF]
            pal = L["pals"][L["remap"][thr.pal_of(blk)]][1]
            px = np.frombuffer(bytes(im["px"]), dtype=np.uint8).astype(np.int64).reshape(im["h"], im["w"])
            if f & 0x10:
                px = px[:, ::-1]
            lut = np.array([-1] + [(lambda c: c[0] << 16 | c[1] << 8 | c[2])(thr.rgb(w)) for w in pal[1:]]
                           + [-1] * 256, dtype=np.int64)
            col = lut[px]
            ys, xs = m["y"] + by - y0, m["x"] + bx - x0
            view = arr[ys:ys + im["h"], xs:xs + im["w"]]
            view[px != 0] = col[px != 0]
    return arr, x0, y0


def chair_view(world, wx, wy, W, H):
    """W x H of a world plane with its top-left at world (wx, wy); -1 off it."""
    import numpy as np
    arr, x0, y0 = world
    out = np.full((H, W), -1, dtype=np.int64)
    sy0, sx0 = wy - y0, wx - x0
    ya, yb = max(0, sy0), min(arr.shape[0], sy0 + H)
    xa, xb = max(0, sx0), min(arr.shape[1], sx0 + W)
    if ya < yb and xa < xb:
        out[ya - sy0:yb - sy0, xa - sx0:xb - sx0] = arr[ya:yb, xa:xb]
    return out


def camera_views(L, W, H):
    """Every distinct view of planes 6-8 behind the chair, over every camera
    that puts any of it on screen: [(composite, on-screen column mask)].
    Plane 6 is drawn over 7, over 8 (dlists_mk1thrn order)."""
    import numpy as np
    rec = L["rec"]
    worlds = {p: world_plane(L, p) for p in (6, 7, 8)}
    views, seen = [], set()
    cols = np.arange(W)
    for cam in range(rec["left"], rec["right"] + 1):
        px = thr.plane_x(L, cam)
        sx = CHAIR_XY[0] - px[4]                  # the chair's screen x
        if sx + W <= 0 or sx >= SCREEN_W:
            continue
        key = (sx, px[6] - px[4], px[7] - px[4], px[8] - px[4])
        if key in seen:
            continue
        seen.add(key)
        comp = np.full((H, W), -1, dtype=np.int64)
        src = np.zeros((H, W), dtype=np.int64)    # which plane shows: 0 = the sky
        for p in (8, 7, 6):                       # back to front
            v = chair_view(worlds[p], CHAIR_XY[0] + px[p] - px[4], CHAIR_XY[1], W, H)
            comp = np.where(v >= 0, v, comp)
            src = np.where(v >= 0, p, src)
        onscr = (sx + cols >= 0) & (sx + cols < SCREEN_W)
        views.append((comp, src, np.broadcast_to(onscr, (H, W))))
    return views


def build(L):
    import numpy as np
    check_rates()
    rec, pal = chair()
    W, H = rec["w"], rec["h"]
    matched = measure(L, rec, pal)
    cov = np.array(shang_cover(W, H)[0])
    _c, anchor, nshang = shang_cover(1, 1)
    words = pal["words"] + [WALL_RED]
    if len(words) > 1 << PPP:
        raise SystemExit(f"{CHAIR_PAL} has no spare slot left for WALL_RED at PPP> {PPP}")
    wall = len(words) - 1
    packed = np.array([(lambda c: c[0] << 16 | c[1] << 8 | c[2])(thr.rgb(w)) for w in words], dtype=np.int64)
    chairpx = np.array(rec["px"], dtype=np.int64)
    # plane 5 moves with the patch, so it is the same at every camera
    p5 = chair_view(world_plane(L, 5), CHAIR_XY[0], CHAIR_XY[1], W, H)
    views = camera_views(L, W, H)
    sky = np.zeros((H, W), dtype=bool)
    base = np.zeros((H, W), dtype=bool)          # MK1's throne base, plane 8
    for comp, src, onscr in views:
        sky |= (comp < 0) & onscr & (p5 < 0)
        base |= (src == 8) & onscr & (p5 < 0)

    mask = np.zeros((H, W), dtype=np.int64)
    opaque = chairpx != 0
    # under Shang
    draw = cov & opaque & (p5 != packed[chairpx])
    mask[draw] = chairpx[draw]
    # the wall and the gong (planes 6/7) are the room's own parallax and may
    # show; MK1's throne base (plane 8, never scrolls) and the sky may not
    fill = cov & ~opaque & (p5 < 0) & (base | sky)
    mask[fill] = wall
    # elsewhere, only where the sky can leak
    plug = ~cov & sky
    mask[plug & opaque] = chairpx[plug & opaque]
    nplug = 0
    rgbs = [thr.rgb(w) for w in words]
    for y, x in zip(*np.nonzero(plug & ~opaque)):
        seen = {}
        for comp, _src, onscr in views:
            c = int(comp[y, x])
            if c >= 0 and onscr[y, x]:
                seen[c] = seen.get(c, 0) + 1
        if not seen:
            raise SystemExit(f"chair ({x},{y}): the sky shows at every camera and the chair is clear there")
        c = max(seen, key=lambda k: (seen[k], k))
        c = (c >> 16, (c >> 8) & 255, c & 255)
        mask[y, x] = min(range(1, len(words)), key=lambda i: sum((a - b) ** 2 for a, b in zip(rgbs[i], c)))
        nplug += 1

    # the proof, over the same cameras: no sky in the chair's box, and nothing
    # but plane 5 or the patch under Shang
    for comp, src, onscr in views:
        bare = (mask == 0) & (p5 < 0) & onscr
        if (bare & (comp < 0)).any():
            y, x = np.argwhere(bare & (comp < 0))[0]
            raise SystemExit(f"PROOF FAILED: the sky still shows at chair ({x},{y})")
        if (bare & cov & (src == 8)).any():
            y, x = np.argwhere(bare & cov & (src == 8))[0]
            raise SystemExit(f"PROOF FAILED: MK1's throne base still shows under Shang at chair ({x},{y})")

    mask = mask.tolist()
    nfill = int(fill.sum())
    if STRIPS[0][5] != 0 or STRIPS[-1][6] != H or any(a[6] != b[5] for a, b in zip(STRIPS, STRIPS[1:])):
        raise SystemExit(f"STRIPS must cover rows 0..{H} with no gap")
    strips = []
    for name, lod, s, e, bank, r0, r1 in STRIPS:
        rows = [y for y in range(r0, r1) if any(mask[y])]
        if not rows:
            raise SystemExit(f"{name} (rows {r0}..{r1}) holds no patch pixel - re-cut STRIPS")
        cols = [x for x in range(W) if any(mask[y][x] for y in rows)]
        y0, y1, x0, x1 = rows[0], rows[-1], cols[0], cols[-1]
        px = [row[x0:x1 + 1] for row in mask[y0:y1 + 1]]
        # anchor - anipoint = the strip's world top-left (mk1t_sh_piece's rule)
        anix = anchor[0] - (CHAIR_XY[0] + x0)
        aniy = anchor[1] - (CHAIR_XY[1] + y0)
        strips.append(dict(name=name, lod=lod, start=s, end=e, bank=bank,
                           w=x1 - x0 + 1, h=y1 - y0 + 1, ax=anix, ay=aniy, px=px, x0=x0, y0=y0))
    npx = sum(v != 0 for row in mask for v in row)
    return dict(rec=rec, pal=dict(pal, words=words), nfill=nfill, nplug=nplug, nviews=len(views),
                mask=mask, strips=strips, matched=matched, npx=npx,
                nshang=nshang, anchor=anchor)


def img_bytes(B):
    images = [(s["name"], s["ax"], s["ay"], s["w"], s["h"],
               bytes(v for row in s["px"] for v in row), 0) for s in B["strips"]]
    return pit.build_img(images, [(PAL_NAME, PPP, B["pal"]["words"])])


def lod_text(s):
    return f"""***> {pit.lod_address(s['start'])}
IHDR SIZX:W,SIZY:W,ANIX:W,ANIY:W,SAG:L,CTRL:W,PAL:L
;**************************************************************
;
;  THE THRONE ROOM (MK1) - THE EMPTY THRONE, strip {s['name'][-1]}
;  (bank {s['bank']}, phys 0x{s['start']:06X}..0x{s['end']:06X})
;
;  GENERATED by tools/make_thrnchair.py out of data/MKBGANI.IMG's
;  thrnchair - only the pixels Shang Tsung covers that differ from
;  the throne already in the background.  Do not edit by hand.
;
;  PON>: built with gso_dmawnz -> object_setup, which reads the
;  palette off the record.  {PAL_NAME} is src/THRCHP.ASM (generated).
;  PPP> {PPP}: the chair's palette has {len_pal} entries.
;
;**************************************************************
PON>
ZON>
PPP> {PPP}
ASM> {s['lod']}.TBL
{OUT_IMG.name}
---> {s['name']}
"""


def asm_text(B):
    o = [";**************************************************************************",
         "; GENERATED by tools/make_thrnchair.py - do not edit.",
         ";",
         "; THE THRONE ROOM's empty throne: the palette its strips point at (PON>)",
         "; and the strips mk1t_chair lays, in order.  Out of data/MKBGANI.IMG's",
         f"; {CHAIR_REC} on {CHAIR_PAL}; {B['npx']} patch pixels under Shang's {B['nshang']} packed records.",
         ";**************************************************************************",
         "",
         PAL_NAME + ":",
         TAB + ".word" + TAB + str(len(B["pal"]["words"]))]
    w = B["pal"]["words"]
    for i in range(0, len(w), 8):
        o.append(TAB + ".word" + TAB + ",".join("%05XH" % v for v in w[i:i + 8]))
    o += ["", "mk1t_chair_n" + TAB + ".set" + TAB + str(len(B["strips"])) + TAB + TAB + "; strips in mk1t_chair_recs",
          "mk1t_chair_recs:"]
    for s in B["strips"]:
        o.append(TAB + ".long" + TAB + s["name"] + TAB + TAB + "; %dx%d, chair rows %d..%d" %
                 (s["w"], s["h"], s["y0"], s["y0"] + s["h"] - 1))
    o += [TAB + ".long" + TAB + "0", ""]
    return "\n".join(o)


def outputs(B):
    global len_pal
    len_pal = len(B["pal"]["words"])
    out = {OUT_IMG: img_bytes(B), OUT_ASM: asm_text(B).encode()}
    for s in B["strips"]:
        out[DATA / f"{s['lod']}.LOD"] = lod_text(s).encode()
    return out


len_pal = 0


def verify_irw(B):
    """Decode each strip back out of its IRW through the promoted TBL."""
    bad = []
    for s in B["strips"]:
        tbl = SRC / f"{s['lod']}.TBL"
        irw = DATA / f"{s['lod']}.IRW"
        if not tbl.exists() or not irw.exists():
            bad.append(f"{s['lod']}: no {tbl.name}/{irw.name} yet - run python build.py")
            continue
        m = re.search(re.escape(s["name"]) + r":\s*\n\s*\.word\s+([^\n]+)\n\s*\.long\s+(\S+)\s*\n\s*\.word\s+(\S+)",
                      tbl.read_text(errors="replace"), re.I)
        if not m:
            bad.append(f"{tbl.name}: no record {s['name']}")
            continue
        geo = [int(t.strip().rstrip("Hh"), 16) if t.strip().upper().endswith("H") else int(t)
               for t in m.group(1).split(",")]
        sag = int(m.group(2).rstrip("Hh"), 16)
        ctrl = int(m.group(3).rstrip("Hh"), 16)
        if (geo[0], geo[1]) != (s["w"], s["h"]):
            bad.append(f"{s['name']}: TBL says {geo[0]}x{geo[1]}, the patch is {s['w']}x{s['h']}")
            continue
        start, payload = pit._irw(s["lod"])
        try:
            rows, _bpp = pit.decode_record(payload, pit.runtime_bit(sag) - start * 8, s["w"], s["h"], ctrl)
        except IndexError:
            bad.append(f"{s['name']}: runs off {irw.name}")
            continue
        if rows != s["px"]:
            n = sum(a != b for ra, rb in zip(rows, s["px"]) for a, b in zip(ra, rb))
            bad.append(f"{s['name']}: {n} pixels packed wrong")
    return bad


def png(B, L, out_dir):
    from PIL import Image
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    rec, words = B["rec"], B["pal"]["words"]
    W, H = rec["w"], rec["h"]
    scale = 3
    sheet = Image.new("RGB", (W * 2, H), (255, 0, 255))
    for y in range(H):
        for x in range(W):
            if rec["px"][y][x]:
                sheet.putpixel((x, y), thr.rgb(words[rec["px"][y][x]]))
            if B["mask"][y][x]:
                sheet.putpixel((W + x, y), thr.rgb(words[B["mask"][y][x]]))
    sheet.resize((W * 2 * scale, H * scale), Image.NEAREST).save(out / "patch.png")
    behind, _ = stage_layers(L)
    mods = L["mods"]
    L["mods"] = [m for m in mods if m["plane"] < 5]
    front = thr.render(L, L["rec"]["start"], show_ground=False)
    L["mods"] = mods
    er = thr.rgb(L["rec"]["erase"])
    start, worldy = L["rec"]["start"], L["rec"]["worldy"]
    scr = behind.copy()
    p = scr.load()
    for s in B["strips"]:
        ox = B["anchor"][0] - s["ax"] - start
        oy = B["anchor"][1] - s["ay"] - worldy
        for y, row in enumerate(s["px"]):
            for x, v in enumerate(row):
                if v and 0 <= ox + x < scr.width and 0 <= oy + y < scr.height:
                    p[ox + x, oy + y] = thr.rgb(words[v])
    f = front.load()
    for y in range(scr.height):
        for x in range(scr.width):
            if f[x, y] != er:
                p[x, y] = f[x, y]
    scr.save(out / "empty_throne.png")
    print(f"wrote {out / 'patch.png'} and {out / 'empty_throne.png'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="fail if any output differs from a fresh build")
    ap.add_argument("--png", metavar="DIR", help="render the patch and the stage with it")
    args = ap.parse_args()
    L = thr.layout()
    B = build(L)
    outs = outputs(B)
    for s in B["strips"]:
        print(f"  {s['name']}: {s['w']}x{s['h']} ani ({s['ax']},{s['ay']})  -> {s['lod']} "
              f"bank {s['bank']} 0x{s['start']:06X}..0x{s['end']:06X} ({s['end'] - s['start']:,} B)")
    print(f"  {B['npx']} patch pixels ({B['nfill']} WALL_RED, {B['nplug']} plugging sky holes; {B['nviews']} camera views); thrnchair matches the stage in {B['matched']} at {CHAIR_XY}")
    if args.png:
        png(B, L, args.png)
        return 0
    if args.check:
        stale = [p.relative_to(ROOT) for p, b in outs.items() if not p.exists() or p.read_bytes() != b]
        if stale:
            print("STALE: " + ", ".join(str(p) for p in stale) + " - run python tools/make_thrnchair.py")
            return 1
        bad = verify_irw(B)
        if bad:
            print("\n".join("FAIL " + b for b in bad))
            return 1
        print("make_thrnchair: OK")
        return 0
    for p, b in outs.items():
        if not p.exists() or p.read_bytes() != b:
            p.write_bytes(b)
            print(f"wrote {p.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
