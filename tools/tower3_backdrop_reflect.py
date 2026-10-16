#!/usr/bin/env python3
"""THE TOWER's backdrop reflection - the wall, the arch and the sky in the marble.

Generates src/TWRBKREF.ASM, which `tower_backdrop_reflections` (src/BGND.ASM)
reads at stage load and every tick. Everything in it is DERIVED from files that
are themselves generated or authored elsewhere, so it is regenerated here and
checked in Phase D rather than hand-maintained:

  twr_bkwall_tbl   one record per PLANE5BLKS block (BGNDTBL.ASM): which R2HDRS
                   header, the dimmed palette, flip/transparency bits, plane x,
                   the y to hand the engine, a PER-BLOCK ystep, and ozval.
  twr_runner_tbl   the carpet runner's span per floor-texture row, measured off
                   CASFLOOR1-6 (data/MKFLOORS.IMG), for the runner overlay pass.
  twr_dmap         depth -> reflected row, and twr_drawn, the rows the DMA
  twr_drawn        draws at the sky's fixed step - the follower never divides.
  SLATE_R DECORA_R NEWCLD_R MONK_R
                   the four palettes the reflection draws in: SLATE and DECORA
                   (BGNDPAL.ASM - the wall), newcld_p (the clouds) and MONKPAL_p
                   (the monk), every channel scaled to REFL_K.

WHY A PER-BLOCK YSTEP.  The DMA is a nearest-neighbour scaler and sizes every
blit from its own source height - it knows nothing about where the block above
went. Measured on the real machine (tools/tower_scale_rounding_probe.lua): a
reduction draws CEIL(h * 256 / step) rows, never floor. At one shared 1/6 step,
stacked wall blocks round independently and open 1-row marble seams across the
reflection. So each block is given the rows it must cover to tile EXACTLY
against its neighbours,

    rows = floor((B - y0) / N) - floor((B - y0 - h) / N)        (half-open)

and the step that makes the hardware draw exactly that many,

    step = ceil(h * 256 / rows),   checked: ceil(h * 256 / step) == rows.

B is the wall's base line in plane y (= the floor's top row) and y0 the block's
top. Blocks that collapse to 0 rows are dropped. Tiling is then verified column
by column below, not assumed.

    python tools/tower3_backdrop_reflect.py            # report + check, exit 0/1
    python tools/tower3_backdrop_reflect.py --check    # same, for build.py
    python tools/tower3_backdrop_reflect.py --apply    # (re)write src/TWRBKREF.ASM
"""
from __future__ import annotations

import argparse
import math
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tower3_statue_layout as T          # noqa: E402  (BGND.ASM placement reader)
import tower3_reflection_align as R       # noqa: E402  (floor band)

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from imgdump import detect_record_layout, cstr, IMAGE, PALETTE  # noqa: E402

BGNDTBL = ROOT / "src" / "BGNDTBL.ASM"
BGNDPAL = ROOT / "src" / "BGNDPAL.ASM"
IMGPAL6 = ROOT / "src" / "IMGPAL6.ASM"
MKFLOORS = ROOT / "data" / "MKFLOORS.IMG"
OUT = ROOT / "src" / "TWRBKREF.ASM"
MKDISP = ROOT / "src" / "MKDISP.ASM"
BGND = ROOT / "src" / "BGND.ASM"
EOL = "\r\n"                       # GSPA is a DOS tool


def floor_geometry(tex_width: int):
    """(floor_x, line width) as floor_code actually uses them, from MKDISP.ASM.

    Both are local .sets / immediates inside MKDISP, invisible to BGND.ASM, and
    the runner pass reproduces floor_code's per-line maths - so they are read
    from the source and emitted as TWR_FLOORX / TWR_FLOORW rather than retyped,
    and checked against the art: floor_x must be the texture's real width.
    """
    t = MKDISP.read_text(errors="replace")
    m = re.search(r"^floor_x\s+\.set\s+(\d+)", t, re.M)
    if not m:
        raise SystemExit("floor_x not found in MKDISP.ASM")
    floorx = int(m.group(1))
    # Anchor on the LABEL lines. The first mention of floor_code is a comment
    # 2,700 lines earlier, and the first floor_exit is a `jrn floor_exit`
    # branch that comes BEFORE the size immediate - slicing on either cut the
    # routine short and missed the very line this is looking for.
    s = re.search(r"^floor_code\b", t, re.M)
    e = re.search(r"^floor_exit\b", t, re.M)
    if not (s and e):
        raise SystemExit("floor_code / floor_exit labels not found in MKDISP.ASM")
    body = t[s.start():e.start()]
    m = re.search(r"movi\s+0*1(0[0-9a-fA-F]{3})h\s*,\s*a6", body)
    if not m:
        raise SystemExit("floor_code's y:x size immediate not found")
    linew = int(m.group(1), 16)
    if floorx != tex_width:
        raise SystemExit(f"MKDISP floor_x {floorx} != CASFLOOR width {tex_width}")
    return floorx, linew

MODULE = "PLANE5"                  # the wall, baklst6
# DEPTH.  The wall's full height (DMAX) maps onto the MROWS rows of marble
# between the floor's top row and the carpet - measured by floor_band, 54
# today - so the reflection reaches the carpet's edge exactly.  It was a flat
# 1/6, which stopped ~20 rows short and left a hard edge of bare flagstone
# across the middle of the floor.
REFL_K = 0.80                      # was 0.76 (CASTLE.IMG's SHADE is SLATE at 76%)
# ...and FLATTEN it.  Scaling every channel keeps a palette's CONTRAST, so the
# mirror came out as sharp as the wall itself and read as a second room under
# the floor - players called it dizzying.  Midway's own floor reflections in
# CASTLE.IMG are not dimmed copies of the wall: reflex1-3 wear `shine' and
# PILREF wears `reflx', and those palettes keep the wall's MEAN while squashing
# its highlights.  Measured here, 5-bit channels over the non-zero entries:
#
#     slate  (the wall)     mean 12.9  9.3  9.0   max 25 21 22   sd 4.0 3.7 3.8
#     shine  (their floor)  mean 10.5  8.5  9.4   max 18 20 23   sd 3.7 3.9 6.7
#     reflx  (their pillar) mean 10.7  8.1  8.1   max 16 13 13   sd 2.9 2.4 2.6
#
# So each channel is pulled toward its OWN palette's mean by REFL_FLAT and then
# scaled, which lands on reflx's shape instead of on a scaled-down wall.
REFL_FLAT = 1.00                   # contrast kept, per palette, toward its mean
#                                    (1.00 = off; the tint below does the work)
# ...and TINT it toward the marble.  Flattening alone did not fix the dizzy
# feeling, and measuring why is easy: the mirror does not read as a sheen
# because it is too SHARP, it reads as a window because it is BLUE against a
# brown floor.  The reflected sky is the wall's sky, and no amount of dimming
# changes its hue.  So each reflected colour is pulled toward the floor's own
# tint - CASFLR1_p's mean, normalised, applied at the colour's OWN luminance,
# so the mirror keeps its light and shade and only loses its foreign colour.
# Midway had the same problem and solved it in the art: CASTLE.IMG's reflex1-3
# reflect the castle wall, not a sky, so their `shine' palette never had a
# blue to lose.  THE TOWER's wall has an open arch in it and ours does.
REFL_TINT = 0.60                   # 0 = keep the reflection's own hue
WORLDTLY = -14                     # screen = plane - worldtly, at rest
MAP_LEN = 320
# The sky quad is TILED, and this is why.  The reflected band is the full 1120px
# width of the wall, and ONE object that wide draws nothing at all: the DMA's
# destination x-size field is narrower than 16 bits, so 1120 arrives as
# 1120 & 511 = 96 - and 96 pixels at the band's left edge are off the left of
# the screen at every camera position the stage allows.  The failure looks
# exactly like the object never being queued.  Measured: the object was alive on
# its list, size=1120x54, flags=E00C, and not one pixel of it on screen.
# 256 is well inside the field, and splits the band into five objects of which
# at most two are ever on screen.
SKY_TILE = 256                     # no longer used: see SKY_W
# ONE quad, pinned to the camera, instead of tiles spanning the whole wall.
# The tiles were static in plane x, so 2-3 of them intersected the screen
# and the DMA billed 512-768 px of width to cover a 400 px view - the
# emulators charge an unscaled blit its whole programmed w*h, off-screen
# overhang included.  The quad is a flat colour, so a screen-wide one that
# backdrop_follow moves with worldtlx6 draws exactly the same picture.
# SKY_MARGIN covers the follower running a tick behind the camera: plane 6
# scrolls at 0.625x, so even the scroller's ceiling is ~6 px a tick.
SKY_MARGIN = 8
SKY_W = 400 + 2 * SKY_MARGIN       # must stay under the DMA's 512 x-size
RUNNER_CX = 599.5                  # the runner is symmetric about this column

# (source label, file, generated label)
PALETTES = [("SLATE", BGNDPAL, "SLATE_R"), ("DECORA", BGNDPAL, "DECORA_R"),
            ("newcld_p", IMGPAL6, "NEWCLD_R"), ("MONKPAL_p", IMGPAL6, "MONK_R")]
PAL_FOR = {"SLATE": "SLATE_R", "DECORA": "DECORA_R"}


def dmap(d, mrows, dmax):
    """Depth below the base line -> reflected row.  Monotonic, so the
    half-open [dmap(Dlo), dmap(Dhi+1)) intervals of stacked blocks tile."""
    return (d * mrows) // dmax


def num(tok: str) -> int:
    tok = tok.strip()
    neg = tok.startswith("-")
    if neg:
        tok = tok[1:].strip()
    v = int(tok[:-1], 16) if tok[-1:].lower() == "h" else int(tok)
    return -v if neg else v


def words_after(text: str, label: str, stop: str | None = None):
    """Every .word/.long value after `label:` (up to `stop`, if given)."""
    i = text.index(label + ":")
    blk = text[i + len(label) + 1:]
    if stop:
        blk = blk[:blk.index(stop)]
    out = []
    for line in blk.splitlines():
        code = line.split(";")[0]
        m = re.search(r"\.(word|long)\s+(.*)", code)
        if not m:
            if re.match(r"^[A-Za-z_]\w*:", code.strip()):
                break                         # the next label
            continue
        for v in m.group(2).split(","):
            if v.strip():
                try:
                    out.append(num(v))
                except ValueError:
                    out.append(v.strip())     # a symbol (R2PALS entries)
    return out


def palette(text: str, label: str):
    """(size, [words]) of a `.word n ;pal size` palette."""
    vals = words_after(text, label)
    n = vals[0]
    return n, vals[1:1 + n]


FLOOR_PAL = "CASFLR1_p"           # the marble the reflection lies on
LUM = (0.30, 0.59, 0.11)           # what the eye weighs each channel at


def marble_tint():
    """The floor palette's own hue, as unit-sum channel weights.

    Derived, never typed: repaint the floor and the reflection follows it.
    Entry 0 is transparency and is left out, the way pal_mean does."""
    txt = BGND.read_text(errors="replace")
    n, vals = palette(txt, FLOOR_PAL)
    cs = [((v >> 10) & 31, (v >> 5) & 31, v & 31) for v in vals if v]
    if not cs:
        raise SystemExit(f"{FLOOR_PAL} has no colours to take a tint from")
    m = [sum(c[i] for c in cs) / len(cs) for i in range(3)]
    s = sum(m)
    if s <= 0:
        raise SystemExit(f"{FLOOR_PAL} averages to black")
    return [x / s for x in m]


def pal_mean(vals):
    """Mean 5-bit channels over a palette's NON-ZERO entries.  Entry 0 is
    transparency, not a colour: averaging it in would drag the mean down and
    make a reflection darker the more transparent its art happens to be."""
    cs = [((v >> 10) & 31, (v >> 5) & 31, v & 31) for v in vals if v]
    if not cs:
        return None
    return tuple(sum(c[i] for c in cs) / len(cs) for i in range(3))


def dim(v: int, mean=None) -> int:
    """One palette word, dimmed AND flattened - see REFL_FLAT above.

    v == 0 stays 0: index 0 is the art's transparency and the blit's write
    mode keys off it, so blending it toward the mean would paint over every
    hole the wall lets the sky through."""
    if v == 0:
        return 0
    c = [(v >> 10) & 31, (v >> 5) & 31, v & 31]
    if REFL_TINT:
        # the same luminance, wearing the floor's hue
        tint = marble_tint()
        lum = sum(x * w for x, w in zip(c, LUM))
        scale = lum / sum(x * w for x, w in zip(tint, LUM))
        c = [x + (h * scale - x) * REFL_TINT for x, h in zip(c, tint)]
    if mean is not None and REFL_FLAT != 1.0:
        # Compress DOWNWARD only.  Pulling a channel toward the mean lifts the
        # dark end as much as it drops the bright end, and on a bright palette
        # that is backwards: newcld_p's mean is its CLOUDS, so flattening
        # turned the sky pen - the darkest thing in it, and the colour the sky
        # quad is drawn in - INTO something brighter than the undimmed
        # autoerase sky it is supposed to sit behind.  Midway's own reflection
        # palette says the same: reflx keeps slate's darks (min 2 -> 2) and
        # squashes its highlights (max 25 -> 16).
        c = [min(m + (x - m) * REFL_FLAT, x) for x, m in zip(c, mean)]
    c = [max(0, min(31, int(round(x * REFL_K)))) for x in c]
    return (c[0] << 10) | (c[1] << 5) | c[2]


def wall_blocks():
    t = BGNDTBL.read_text(errors="replace")
    mw, mh, nb = words_after(t, f"{MODULE}BMOD")[:3]
    bl = words_after(t, f"{MODULE}BLKS", stop="0FFFFH")
    recs = [tuple(bl[i:i + 4]) for i in range(0, len(bl) - 3, 4)]
    hv = words_after(t, "R2HDRS")
    hdrs = []
    for i in range(0, len(hv) - 3, 4):
        if not all(isinstance(v, int) for v in hv[i:i + 4]):
            break
        hdrs.append(tuple(hv[i:i + 4]))
    pals = [v for v in words_after(BGNDPAL.read_text(errors="replace"), "R2PALS")
            if isinstance(v, str)]
    return (mw, mh, nb), recs, hdrs, pals


def derive_wall(mrows):
    (mw, mh, nb), recs, hdrs, pals = wall_blocks()
    if len(recs) != nb:
        raise SystemExit(f"{MODULE}BLKS has {len(recs)} records, BMOD says {nb}")
    off = T._bgnd_offset(MODULE)
    if off is None:
        raise SystemExit(f"no placement for {MODULE}BMOD in BGND.ASM")
    mx, my = off
    B = my + mh                                  # base line, plane y

    out, dropped = [], []
    for i, (flags, x, y, ph) in enumerate(recs):
        z = (flags >> 8) & 0xFF
        fbits = (flags >> 4) & 0xF               # addblock: map_flags
        pal = (flags & 0xF) | (((ph >> 12) & 0xF) << 4)
        hdr = ph & 0xFFF
        w, h, sag, ctrl = hdrs[hdr]
        y0 = my + y
        rows = dmap(B - y0, mrows, mh) - dmap(B - y0 - h, mrows, mh)
        if rows <= 0:
            dropped.append((i, hdr, h))
            continue
        step = -(-(h * 256) // rows)
        if -(-(h * 256) // step) != rows or step < 0x100:
            raise SystemExit(f"block {i}: no step draws {h} rows as {rows}")
        top = B + dmap(B - y0 - h, mrows, mh)
        yeng = top - h + rows                    # m_flipv: clip6 adds ysize-1
        # addblock: transparent (0x40) -> write non-zero (2), else both (3);
        # the reflection keeps the block's own h-flip and INVERTS its v-flip
        orb = (2 if fbits & 4 else 3) | (0x10 if fbits & 1 else 0) | \
              (0 if fbits & 2 else 0x20)
        pname = pals[pal] if pal < len(pals) else None
        if pname not in PAL_FOR:
            raise SystemExit(f"block {i}: palette {pal} ({pname}) has no dimmed copy")
        out.append(dict(i=i, z=z, x=mx + x, y0=y0, w=w, h=h, hdr=hdr, rows=rows,
                        step=step, top=top, yeng=yeng, orb=orb, pal=PAL_FOR[pname]))
    # ozval preserves the REAL draw order: addblock inserts on z, then oyval,
    # so rank the originals that way and carry it in the low byte
    for rank, b in enumerate(sorted(out, key=lambda b: (b["z"], b["y0"], b["i"]))):
        b["ozval"] = b["z"] * 256 + rank
    return B, mh, out, dropped


def autoerase_colour():
    """tower_mod's first word - the sky, as a 5:5:5 value, straight from the
    stage table.  It is written there as arithmetic, so evaluate it."""
    src = (ROOT / "src" / "BGND.ASM").read_text(errors="replace")
    i = src.index(chr(10) + "tower_mod" + chr(10))
    pat = ("[.]word[ WS]+([0-9*+() -]+?)[ WS]*;[ WS]*autoerase colou?r"
           .replace("WS", chr(92) + "t"))
    m = re.search(pat, src[i:i + 400])
    if not m:
        raise SystemExit("tower_mod has no autoerase word")
    expr = m.group(1).strip()
    if not re.fullmatch(r"[0-9*+() -]+", expr):
        raise SystemExit("autoerase word %r is not plain arithmetic" % expr)
    return eval(expr, {"__builtins__": {}}, {})


def sky_backing(B, blocks, mrows):
    """The one quad that puts the SKY back behind the reflected wall.

    The wall is not a solid slab.  18.8% of PLANE5 is index 0, and every one
    of those pixels is somewhere the autoerase colour shows through: the big
    central arch, the row of small window panels along the top of the wall,
    and the tall slits either side of it.  The reflection is built out of the
    wall's own blocks, so all of that came out as bare flagstone - the
    mirrored windows had the FLOOR behind them, and the reflected clouds
    drifted across stone.

    The fix is one rectangle the size of the whole reflected band, drawn
    behind everything else in it.  That is safe for a reason worth stating:
    every pixel of the module is either transparent - where the sky belongs -
    or opaque, and every opaque pixel's reflection is drawn ON TOP of this
    quad.  check_tiling proves the per-block reflections tile every column
    exactly, so no opaque source row loses its reflected row.  The quad can
    only ever be seen where the wall itself lets the sky through.

    It needs no art and no palette of its own.  The DMA's write-mode nibble
    can replace BOTH zero and non-zero data with the constant colour
    (dmacal), and the constant is an index into the object's own colour map,
    so any source at all comes out as one flat colour.  It reads the floor's
    own texture - in bounds, 1120x54 at 6bpp is 362,880 bits into a
    540,000-bit image - and wears the dimmed CLOUD palette, which already
    carries the dimmed sky: the clouds are drawn against the sky, so the
    autoerase colour is one of their pens.
    """
    sky = autoerase_colour()
    src = palette(IMGPAL6.read_text(errors="replace"), "newcld_p")[1]
    if sky not in src:
        raise SystemExit(
            "newcld_p does not carry the autoerase colour %04X - it is the pen "
            "the sky quad is drawn in.  Pick another palette for it." % sky)
    top = min(b["top"] for b in blocks)
    bot = max(b["top"] + b["rows"] for b in blocks)
    if top != B or bot - top != mrows:
        raise SystemExit("the reflected band is %d..%d, not %d..%d - the sky "
                         "quad would not match it"
                         % (top, bot - 1, B, B + mrows - 1))
    first, last = hole_rows(B, blocks, mrows)
    first, last = max(0, first - 1), min(mrows - 1, last + 1)   # a row of margin
    if SKY_W >= 512:
        raise SystemExit("SKY_W %d: the DMA's x-size field is under 512" % SKY_W)
    return dict(y=B + first, h=last - first + 1, w=SKY_W, margin=SKY_MARGIN,
                first=first, last=last, pen=src.index(sky),
                sky=sky, dim=dim(sky, pal_mean(src)))


def hole_rows(B, blocks, mrows):
    """First and last band row where the reflected wall has ANY hole.

    A pixel of the band is a hole when no block writes a non-zero pixel to it
    - a union, so draw order does not matter.  Each block is sampled the way
    the DMA draws it: v-flipped, output row k taking source row k*step >> 8.
    Only the ROW extent is used, so the one-pixel x nudge an h-flipped block
    takes on screen (measured against a frame: +1 explains 1280 of the 1380
    sky pixels, 0 explains 1263) does not matter here.  Validated against
    the mid-stop frame: every autoerase pixel in the band falls on a row this
    says has holes."""
    import stage_preview as SP
    imgs, order, _pals = SP.load_bdd(ROOT / "data" / "TOWER3.BDD")
    W = max(b["x"] + b["w"] for b in blocks) + 2
    opaque = [[False] * W for _ in range(mrows)]
    covered = [[False] * W for _ in range(mrows)]
    for b in blocks:
        img = imgs[order[b["hdr"]]]
        w, h, px = img["w"], img["h"], img["px"]
        hf = bool(b["orb"] & 0x10)
        bottom = b["top"] + b["rows"] - 1
        for k in range(b["rows"]):
            s = (k * b["step"]) >> 8
            if s >= h:
                break
            r = bottom - k - B
            if not 0 <= r < mrows:
                continue
            row = px[s * w:(s + 1) * w]
            for c in range(w):
                x = b["x"] + (w - 1 - c if hf else c)
                if 0 <= x < W:
                    covered[r][x] = True
                    if row[c]:
                        opaque[r][x] = True
    x0 = min(b["x"] for b in blocks)
    x1 = max(b["x"] + b["w"] for b in blocks)
    rows = [r for r in range(mrows)
            if any(not opaque[r][x] for x in range(x0, x1))]
    if not rows:
        raise SystemExit("the reflected wall has no holes at all - no sky quad needed")
    return rows[0], rows[-1]


def check_tiling(B, blocks, mrows, dmax):
    """Column by column: the per-block reflections tile each contiguous source
    run EXACTLY - no gap (a marble crack) and no overlap.

    A source run over depths [Dlo, Dhi] reflects to the half-open rows
    [floor(Dlo/N), floor((Dhi+1)/N)), and the stacked blocks inside it must
    cover precisely that. The same rule drops a run's last partial group - at
    the wall's very top, its top 2 source rows - which is rounding, not a seam.
    (The first version compared against floor(D/N) per row, which keeps that
    partial row, and so failed every column at row 33 on correct data.)
    """
    problems = []
    xs = range(min(b["x"] for b in blocks), max(b["x"] + b["w"] for b in blocks))
    for x in xs:
        cov = [b for b in blocks if b["x"] <= x < b["x"] + b["w"]]
        rows = sorted({yy for b in cov for yy in range(b["y0"], b["y0"] + b["h"])})
        want, i = set(), 0
        while i < len(rows):
            j = i
            while j + 1 < len(rows) and rows[j + 1] == rows[j] + 1:
                j += 1
            dlo, dhi = B - 1 - rows[j], B - 1 - rows[i]
            want.update(range(dmap(dlo, mrows, dmax), dmap(dhi + 1, mrows, dmax)))
            i = j + 1
        got = set()
        for b in cov:
            got.update(range(b["top"] - B, b["top"] - B + b["rows"]))
        if got != want:
            problems.append(f"x={x}: rows {sorted(got ^ want)[:6]} are a seam "
                            f"or an overlap")
            if len(problems) > 5:
                break
    return problems


def runner_spans(floor_top, band_bottom):
    d = MKFLOORS.read_bytes()
    ic, pc, oset = struct.unpack_from("<HHI", d, 0)[:3]
    _, ist, pst = detect_record_layout(d, oset, ic, pc)
    recs = {}
    for i in range(ic):
        f = IMAGE.unpack_from(d, ist + i * IMAGE.size)
        recs[cstr(f[0])] = f
    pr = PALETTE.unpack_from(d, pst + (recs["CASFLOOR1"][6] - 3) * PALETTE.size)
    pal = struct.unpack_from("<%dH" % pr[3], d, pr[4])
    tex = []
    tiles = [recs["CASFLOOR%d" % k] for k in range(1, 7)]
    H = tiles[0][5]
    for y in range(H):
        row = []
        for f in tiles:
            w, o = f[4], f[7]
            st = (w + 3) & ~3
            row.extend(d[o + y * st + x] for x in range(w))
        tex.append(row)

    def cls(i):
        v = pal[i]
        r, g, b = (v >> 10) & 31, (v >> 5) & 31, v & 31
        if r > g + 6 and r > b + 3:
            return "R"
        if r >= 18 and g >= 12 and b <= g - 4 and r >= b + 8:
            return "G"
        return "."

    last = band_bottom - floor_top               # last texture row under the band
    spans = {}
    prev = None
    for y in range(min(last, H - 1), -1, -1):    # bottom-up: widest first
        row = [cls(tex[y][x]) for x in range(len(tex[y]))]
        if not any(c == "R" for c in row[520:680]):
            if prev is None:
                continue
            spans[y] = None
            prev = None
            continue
        c = int(RUNNER_CX)
        span = None
        if row[c] != "." or row[c + 1] != ".":
            lo = c if row[c] != "." else c + 1
            hi = lo
            while row[lo - 1] != ".":
                lo -= 1
            while row[hi + 1] != ".":
                hi += 1
            span = (lo, hi)
        if span is None or (prev and (span[1] - span[0]) < (prev[1] - prev[0]) - 6):
            # the ragged tip: whatever is non-marble inside the row below's span
            if prev is None:
                continue
            inside = [x for x in range(prev[0], prev[1] + 1) if row[x] != "."]
            span = (min(inside), max(inside)) if inside else None
        spans[y] = span
        prev = span if span else prev
    # The runner is a trapezoid widening toward the viewer, so no row can be
    # narrower than the row above it. The scan stops a pixel short each side
    # where the trim's anti-aliasing reads as marble (widths went ..50,50,48,52
    # ..), which would leave the reflection on the carpet's edge on that row -
    # so carry the envelope down: each row at least as wide as the one above.
    first = min(y for y, s in spans.items() if s)
    prev = None
    for y in range(first, last + 1):
        s = spans.get(y)
        if s and prev:
            spans[y] = (min(s[0], prev[0]), max(s[1], prev[1]))
        prev = spans.get(y) or prev
    return first, last, [spans.get(y) for y in range(first, last + 1)]


def generate():
    floor_top, carpet_top = R.floor_band()
    mrows = carpet_top - floor_top             # the marble to fill, measured
    B, dmax, blocks, dropped = derive_wall(mrows)
    sky = sky_backing(B, blocks, mrows)
    skystep = -(-(256 * dmax) // mrows)        # the sky's one fixed ystep
    band_bottom = max(b["top"] + b["rows"] for b in blocks) - 1 - WORLDTLY
    l0, l1, spans = runner_spans(floor_top, band_bottom)
    d = MKFLOORS.read_bytes()
    ic, pc, oset = struct.unpack_from("<HHI", d, 0)[:3]
    _, ist, _ = detect_record_layout(d, oset, ic, pc)
    widths = {}
    for i in range(ic):
        f = IMAGE.unpack_from(d, ist + i * IMAGE.size)
        widths[cstr(f[0])] = f[4]
    floorx, linew = floor_geometry(sum(widths["CASFLOOR%d" % k] for k in range(1, 7)))
    pals = {}
    for src, f, dst in PALETTES:
        n, vals = palette(f.read_text(errors="replace"), src)
        m = pal_mean(vals)
        pals[dst] = (src, n, [dim(v, m) for v in vals])

    L = []
    a = L.append
    a("; TWRBKREF.ASM - GENERATED by tools/tower3_backdrop_reflect.py.  DO NOT EDIT.")
    a(";")
    a("; THE TOWER's backdrop reflection data - see tower_backdrop_reflections in")
    a("; BGND.ASM and the generator's docstring.  Re-run the generator with --apply")
    a("; after anything that moves the wall, re-cuts it, or touches its palettes;")
    a("; Phase D fails the build if this file and its sources disagree.")
    a(";")
    a("\t.DATA")
    a(f"TWR_BKN\t\t.set\t{len(blocks)}\t\t; wall blocks reflected ({len(dropped)} collapse to 0 rows)")
    a("TWR_BKREC\t.set\t160\t\t; one record: 3 .long + 4 .word")
    a(f"TWR_BKBASE\t.set\t{B}\t\t; the wall's base line, plane y (= the floor's top row)")
    a(f"TWR_BKSTEP\t.set\t00{skystep:04X}0100h\t; the sky's fixed [ystep:xstep]")
    a(f"TWR_BKR\t\t.set\t{mrows}\t\t; rows of marble the reflection fills, to the carpet")
    a(f"TWR_BKDMAX\t.set\t{dmax}\t\t; the wall's depth, mapped onto TWR_BKR rows")
    a(f"TWR_RUNL0\t.set\t{l0}\t\t; first floor-texture row the runner pass redraws")
    a(f"TWR_RUNL1\t.set\t{l1}\t\t; last - the bottom of the reflection band")
    a(f"TWR_MAPN\t.set\t{MAP_LEN}")
    a(f"TWR_FLOORX\t.set\t{floorx}\t\t; MKDISP floor_x - one texture row, in pixels")
    a(f"TWR_FLOORW\t.set\t{linew}\t\t; floor_code's line width, and skew_sag's centring")
    a("")
    a("; The sky behind the reflected wall - ONE flat quad, no art and no palette")
    a("; of its own, pinned to the camera by backdrop_follow.  sky_backing() and")
    a("; hole_rows() carry why it is safe and how big it has to be.")
    a("; The autoerase colour is %04XH, dimmed to %04XH." % (sky["sky"], sky["dim"]))
    a("TWR_SKYW\t.set\t%d\t\t; the screen plus TWR_SKYM each side (DMA x < 512)" % sky["w"])
    a("TWR_SKYM\t.set\t%d\t\t; margin for the follower's one-tick lag" % sky["margin"])
    a("TWR_SKYY\t.set\t%d\t\t; plane y of band row %d, the first with a hole"
      % (sky["y"], sky["first"]))
    a("TWR_SKYH\t.set\t%d\t\t; rows %d..%d - the band has no holes outside them"
      % (sky["h"], sky["first"], sky["last"]))
    a("TWR_SKYCTL\t.set\t0E00Ch\t\t; dmago | 6bpp | dmacal - the floor's own")
    a("\t\t\t\t;   control word with the write mode set to")
    a("\t\t\t\t;   'constant on both zero and non-zero data',")
    a("\t\t\t\t;   which is what makes the source arbitrary")
    a("TWR_SKYPEN\t.set\t0%04Xh\t\t; NEWCLD_R pen %d, in BOTH bytes: oconst" % (sky["pen"] | (sky["pen"] << 8), sky["pen"]))
    a("\t\t\t\t;   colours a whole WORD of pixels at a time")
    a("")
    a("; .long dimmed palette, [ystep:0100h] oscale, ozval")
    a("; .word R2HDRS index, oflags bits to OR, plane x, engine y")
    a("twr_bkwall_tbl")
    for b in blocks:
        a(f"\t.long\t{b['pal']},00{b['step']:04X}0100h,{b['ozval']}"
          f"\t; blk {b['i']:2d} {b['w']}x{b['h']} -> {b['rows']} rows at screen "
          f"{b['top'] - WORLDTLY}")
        a(f"\t.word\t{b['hdr']},0{b['orb']:02X}h,{b['x']},{b['yeng']}")
    a("")
    # ONE RECORD PER ROW, and it has to stay that way.  Rows that share a span
    # look mergeable - 49 rows are only 22 distinct spans, so most of the pass's
    # blits look redundant - but the T-unit DMA HAS NO SOURCE STRIDE.  A sprite
    # gets away with multi-row blits because its rows are contiguous and the
    # blitter just advances by xsize; these rows are TWR_FLOORX apart.
    #
    # `ofset' is not a stride either.  It is per-row leading/trailing CLIP -
    # what clip_a_row uses to cut the clouds to the arch window, and what the
    # commented-out right-clip `sll 8,a2' in MKDISP's clip5 writes.  Built and
    # measured anyway: every merged group drew nothing at all, and the carpet
    # vanished from the whole band.
    a("; the carpet runner, texture columns [r0,r1] inclusive, one row each from")
    a("; TWR_RUNL0; r0 > r1 = no runner on that row.  Symmetric about column 599.5.")
    a("twr_runner_tbl")
    for k, s in enumerate(spans):
        r0, r1 = (s if s else (1, 0))
        a(f"\t.word\t{r0},{r1}\t\t; row {l0 + k}" + ("" if s else "  (none)"))
    a("")
    a(f"twr_dmap\t\t\t\t; depth -> reflected row, floor(i*{mrows}/{dmax})")
    vals = [dmap(i, mrows, dmax) for i in range(MAP_LEN)]
    for i in range(0, MAP_LEN, 16):
        a("\t.word\t" + ",".join(str(v) for v in vals[i:i + 16]))
    a("")
    a("twr_drawn\t\t\t\t; rows the DMA draws of h at TWR_BKSTEP - it ceils")
    vals = [-(-(i * 256) // skystep) for i in range(MAP_LEN)]
    for i in range(0, MAP_LEN, 16):
        a("\t.word\t" + ",".join(str(v) for v in vals[i:i + 16]))
    a("")
    for dst, (src, n, vals) in pals.items():
        a(f"{dst}:\t\t\t\t; {src}, tinted {REFL_TINT} to the marble,"
          f" flattened {REFL_FLAT}, then x {REFL_K}")
        a(f"\t.word\t{n}\t;pal size")
        for i in range(0, n, 10):
            a("\t.word\t" + ",".join("%04XH" % v for v in vals[i:i + 10]))
    a("\t.TEXT")
    return EOL.join(L) + EOL, dict(B=B, blocks=blocks, dropped=dropped, l0=l0,
                                   l1=l1, spans=spans, band_bottom=band_bottom,
                                   floor_top=floor_top, carpet_top=carpet_top,
                                   mrows=mrows, dmax=dmax)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    text, info = generate()
    blocks = info["blocks"]
    problems = check_tiling(info["B"], blocks, info["mrows"], info["dmax"])

    print(f"{MODULE}: {len(blocks)} wall blocks reflected, "
          f"{len(info['dropped'])} collapse to 0 rows; depth "
          f"{info['dmax']} -> {info['mrows']} rows, to the carpet")
    steps = sorted({b["step"] for b in blocks})
    print(f"  per-block ystep 0x{steps[0]:X}..0x{steps[-1]:X}, band screen y "
          f"{info['floor_top']}..{info['band_bottom']} "
          f"(marble ends {info['carpet_top'] - 1})")
    print(f"  runner pass: texture rows {info['l0']}..{info['l1']}, "
          f"widths {[s[1] - s[0] + 1 if s else 0 for s in info['spans']]}")
    if info["band_bottom"] >= info["carpet_top"]:
        problems.append(f"reflection band reaches screen y {info['band_bottom']}, "
                        f"onto the carpet ({info['carpet_top']})")
    for k, s in enumerate(info["spans"]):
        if s and abs((s[0] + s[1]) / 2 - RUNNER_CX) > 1:
            problems.append(f"runner row {info['l0'] + k} not symmetric: {s}")

    if args.apply:
        OUT.write_text(text, newline="")
        print(f"wrote {OUT.relative_to(ROOT)}")
    else:
        cur = OUT.read_text(errors="replace").replace("\r\n", "\n") if OUT.exists() else None
        if cur != text.replace("\r\n", "\n"):
            problems.append(f"{OUT.relative_to(ROOT)} is stale or missing - "
                            f"re-run with --apply")

    if problems:
        print("\nBACKDROP REFLECTION BROKEN:")
        for p in problems:
            print("  " + p)
        return 1
    print("  backdrop reflection data current; wall tiles exactly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
