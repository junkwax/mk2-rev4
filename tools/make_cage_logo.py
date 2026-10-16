#!/usr/bin/env python3
r"""Cut the OTOMIX logo off Johnny Cage's pants into subframes of its own.

The logo on his pants reads backwards whenever he is drawn mirrored.  It shares
its palette indices (the grey ramp, 1-7) with his sneakers, eye whites and skin
glints, and 184 of the 190 pieces that carry it carry those too, so neither a
palette swap nor a per-piece swap can hide it.  So the logo gets pieces of its
own - the Kahn stone-crack trick (tools/make_stonecrk_img.py):

  base   <PIECE>   the piece with its logo pixels put back to MIDWAY'S OWN: retail
                   MK2 has no OTOMIX on these frames (checked against mk2.zip), and
                   the retail IMG is still in git at ORIG_REV because data/CAGE*.IMG
                   are skip-worktree.  Written back into the piece's own IMG, same
                   size, anipoint and label.  Two pieces added in this project
                   (JCSHADOWKICK1A/2A) have no retail record; their logo is found
                   by the classifier and filled from the pants around it.
  patch  <PIECE>L  the logo pixels alone, cropped, 0 elsewhere, anipoint moved by
                   the crop.  All 190 live in data/JCLOGO.IMG, packed by
                   data/JCLOGO.LOD into their own bank-0 slot.

and every frame list that draws <PIECE> draws <PIECE>L straight after it, so it
lands on top.  Facing right, base + patch is the original piece EXACTLY - the
proof below checks every pixel of every piece before anything is written.
Facing left, the display walker skips any piece whose SAG is in JCLOGO's slot
(cagelogo, MKDISP.ASM), so the logo is not drawn: that is decided per piece on
every display pass, not by any process.

The logo is what differs from retail near the changed grey lettering
(LOGO_REACH): other repairs to the same pieces - a blood stump, split-leg
shading - stay in the base and so show both ways.  Because base + patch is
exact, a wrong call can only change how he looks facing LEFT, never facing
right.  --apply re-reads data/ with the patches composed back on, so running it
again cuts exactly the same thing; --restore writes the painted art back.

    python tools/make_cage_logo.py --apply     # write IMGs + lists
    python tools/make_cage_logo.py --check     # Phase D: fail if anything drifted
    python tools/make_cage_logo.py --sheets    # review strips in tmp/cage_logo_cut/
    python tools/make_cage_logo.py --restore   # compose the logo back into the IMGs, unpatch lists
"""
from __future__ import annotations

import argparse
import hashlib
import re
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import cage_logo_scan as scan                       # noqa: E402  classifier
from img_subframe_audit import live_lods, collect   # noqa: E402  what the LODs load

ORIG_REV = "6a5588da444e83c8f2a9fa2b66cfd2c9b2dc18d2"
PATCH_IMG = ROOT / "data" / "JCLOGO.IMG"
PATCH_GLO = ROOT / "src" / "JCLOGO.GLO"     # .global for every logo piece: MKJC defines,
                                           # MKDEATH/MKDIE draw some of them
SUFFIX = "L"
SHEETS = ROOT / "tmp" / "cage_logo_cut"
LIST_FILES = ("MKJC.ASM", "MKDIE.ASM", "MKDEATH.ASM", "MKFX.ASM")
SKIP_IMGS = {"JCLOGO"}                  # our own output is not a source

# Classifier corrections, by piece: pixels (x, y) in the ORIGINAL piece.  A
# component containing a listed pixel is forced into ("logo") or out of ("keep")
# the patch.  Empty until the sheets say otherwise.
OVERRIDES: dict[str, dict[str, list[tuple[int, int]]]] = {}

LIB = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")


# ---------------------------------------------------------------- pristine art

def git_blob(path: str) -> bytes:
    # A scratch copy of the tree has no .git: MK2_GIT_DIR points at the real one.
    import os
    git_dir = os.environ.get("MK2_GIT_DIR") or str(ROOT / ".git")
    return subprocess.run(["git", "--git-dir", git_dir, "show", f"{ORIG_REV}:{path}"],
                          capture_output=True, check=True).stdout


def parse_img(data: bytes):
    imgcnt, palcnt, oset = LIB.unpack_from(data, 0)[:3]
    recs, pals = {}, {}
    for i in range(imgcnt):
        r = IMAGE.unpack_from(data, oset + i * IMAGE.size)
        name = r[0].split(b"\0")[0].decode("latin-1")
        w, h, palnum, off = r[4], r[5], r[6], r[7]
        stride = (w + 3) & ~3
        recs[name] = dict(name=name, w=w, h=h, ax=r[2] - 0x10000 if r[2] & 0x8000 else r[2],
                          ay=r[3] - 0x10000 if r[3] & 0x8000 else r[3], palnum=palnum, off=off,
                          stride=stride,
                          px=[list(data[off + y * stride:off + y * stride + w]) for y in range(h)])
    p0 = oset + imgcnt * IMAGE.size
    for i in range(palcnt - 3):
        name, _pad, bpp, cnt, fo, *_ = PALETTE.unpack_from(data, p0 + i * PALETTE.size)
        pals[i + 3] = dict(name=name.split(b"\0")[0].decode("latin-1"), bpp=bpp,
                           words=[struct.unpack_from("<H", data, fo + 2 * k)[0] for k in range(cnt)])
    return recs, pals


def read_patches():
    """{piece name: patch rec} out of data/JCLOGO.IMG, if it has been cut before."""
    if not PATCH_IMG.exists():
        return {}
    recs, _p = parse_img(PATCH_IMG.read_bytes())
    return {n[:-len(SUFFIX)]: r for n, r in recs.items() if n.endswith(SUFFIX)}


def compose(rec, patch):
    """A piece with its patch's non-zero pixels on top, placed by anipoint."""
    px = [row[:] for row in rec["px"]]
    ox, oy = rec["ax"] - patch["ax"], rec["ay"] - patch["ay"]
    for cy in range(patch["h"]):
        for cx in range(patch["w"]):
            if patch["px"][cy][cx]:
                px[oy + cy][ox + cx] = patch["px"][cy][cx]
    return px


def load_art():
    """-> {img: (bytes, recs)}, [(img, rec, layout, words, pal, pristine rec or None)]

    `rec` is the piece AS DRAWN FACING RIGHT: data/<img>.IMG with its JCLOGO patch
    composed back on, so a second --apply cuts exactly what the first one did.
    `pristine` is the same piece in git at ORIG_REV - Midway's own art.  The
    CAGE*.IMG files are skip-worktree, so HEAD still holds retail while data/
    holds this project's repaint; a missing record means the piece was added here.
    """
    used, _o, _p = collect(live_lods())
    patches = read_patches()
    blobs, pieces = {}, []
    for img in sorted(used):
        path = ROOT / "data" / f"{img}.IMG"
        if img in SKIP_IMGS or not path.exists():
            continue
        data = path.read_bytes()
        try:
            recs, pals = parse_img(data)
        except (struct.error, IndexError, UnicodeDecodeError):
            continue
        try:
            pristine = parse_img(git_blob(f"data/{img}.IMG"))[0]
        except (subprocess.CalledProcessError, struct.error, IndexError, UnicodeDecodeError):
            pristine = {}
        hit = False
        for name in sorted(used[img]):
            r = recs.get(name)
            pal = pals.get(r["palnum"]) if r else None
            if not pal or pal["name"] not in scan.LAYOUT_OF_IMG_PAL:
                continue
            drawn = dict(r, px=compose(r, patches[name])) if name in patches else r
            o = pristine.get(name)
            if o and (o["w"], o["h"], o["ax"], o["ay"]) != (r["w"], r["h"], r["ax"], r["ay"]):
                o = None
            pieces.append((img, drawn, scan.LAYOUT_OF_IMG_PAL[pal["name"]], pal["words"], pal, o))
            hit = True
        if hit:
            blobs[img] = (data, recs)
    return blobs, pieces


# ---------------------------------------------------------------- the cut

LOGO_REACH = 2      # repaint pixels this close (manhattan) to changed lettering

def logo_from_retail(rec, pristine):
    """The logo is what this project painted over Midway's pants: the pixels that
    differ from retail, near the grey lettering.  Not every difference - the same
    pieces carry other repairs (a blood stump, split-leg shading) that must stay
    in both facings - so only differences within LOGO_REACH of a changed grey."""
    diff = {(x, y) for y in range(rec["h"]) for x in range(rec["w"])
            if rec["px"][y][x] != pristine["px"][y][x]}
    seeds = [(x, y) for x, y in diff if rec["px"][y][x] in scan.GREYS]
    return {(x, y) for x, y in diff
            if any(abs(x - a) + abs(y - b) <= LOGO_REACH for a, b in seeds)}


def logo_from_classifier(rec, words):
    forced = OVERRIDES.get(rec["name"], {})
    want_in = set(map(tuple, forced.get("logo", [])))
    want_out = set(map(tuple, forced.get("keep", [])))
    out = set()
    for c in scan.components(rec, words):
        pts = set(c["pts"])
        kind = scan.classify(c)
        if pts & want_out:
            continue
        if kind in scan.HIDDEN or pts & want_in:
            out |= pts
    return out


def fill_base(rec, words, logo, pants):
    """The piece with its logo pixels repainted from the pants around them: each
    pass takes, for every still-unpainted logo pixel touching a painted one, the
    most common dark (pants) neighbour.  Never transparent, so the silhouette and
    every extent - hence every hurt box - are unchanged."""
    px = [row[:] for row in rec["px"]]
    w, h = rec["w"], rec["h"]

    def dark(v):                                # -1 marks a pixel still to paint
        return v > 0 and v not in scan.GREYS and scan.neighbour_class(words, v) == "D"

    todo = set(logo)
    for x, y in todo:
        px[y][x] = -1
    while todo:
        painted = {}
        for x, y in todo:
            votes = Counter()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if (dx or dy) and 0 <= nx < w and 0 <= ny < h and dark(px[ny][nx]):
                        votes[px[ny][nx]] += 1
            if votes:
                painted[(x, y)] = min(votes.items(), key=lambda kv: (-kv[1], kv[0]))[0]
        if not painted:                         # nothing dark touches what is left
            for x, y in todo:
                px[y][x] = pants
            break
        for (x, y), v in painted.items():
            px[y][x] = v
        todo -= set(painted)
    return px


def cut(pieces):
    """-> {img: {name: base px}}, [(patch name, patch rec, layout)], proof count"""
    bases, patches, proved = {}, [], 0
    for img, rec, layout, words, _pal, pristine in pieces:
        if pristine is not None:
            logo = logo_from_retail(rec, pristine)
            base = [[pristine["px"][y][x] if (x, y) in logo else v for x, v in enumerate(row)]
                    for y, row in enumerate(rec["px"])]
        else:                                   # added in this project: no retail to go back to
            logo = logo_from_classifier(rec, words)
            base = fill_base(rec, words, logo, 0x3F if layout == "cage" else 0x32) if logo else None
        if not logo:
            continue
        xs = [x for x, _ in logo]
        ys = [y for _, y in logo]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        crop = [[rec["px"][y][x] if (x, y) in logo else 0 for x in range(x0, x1 + 1)] for y in range(y0, y1 + 1)]
        patch = dict(w=x1 - x0 + 1, h=y1 - y0 + 1, ax=rec["ax"] - x0, ay=rec["ay"] - y0, px=crop, layout=layout)

        # PROOF: the base, then the patch's non-zero pixels on top, placed by anipoint
        comp = [row[:] for row in base]
        ox, oy = rec["ax"] - patch["ax"], rec["ay"] - patch["ay"]
        for cy in range(patch["h"]):
            for cx in range(patch["w"]):
                if crop[cy][cx]:
                    comp[oy + cy][ox + cx] = crop[cy][cx]
        if comp != rec["px"]:
            sys.exit(f"PROOF FAILED: {rec['name']} + {rec['name']}{SUFFIX} is not {rec['name']}")
        if any((v == 0) != (o == 0) for rb, ro in zip(base, rec["px"]) for v, o in zip(rb, ro)):
            sys.exit(f"{rec['name']}: the base changed the silhouette")
        proved += 1
        bases.setdefault(img, {})[rec["name"]] = base
        patches.append((rec["name"] + SUFFIX, patch))
    return bases, patches, proved


# ---------------------------------------------------------------- outputs

def build_source_img(data: bytes, recs, bases) -> bytes:
    out = bytearray(data)
    for name, px in bases.items():
        r = recs[name]
        for y, row in enumerate(px):
            o = r["off"] + y * r["stride"]
            out[o:o + r["w"]] = bytes(row)
    return bytes(out)


def build_patch_img(patches, pal_words) -> bytes:
    """One palette record per layout (CAGE_P, JCBLUD1_P), copied from the source
    IMGs - POF> in the LOD, so they only feed LOAD2's depth check and our tools."""
    order = ["cage", "blud"]
    names = {"cage": "CAGE_P", "blud": "JCBLUD1_P"}
    blob = bytearray()
    pal_off = {}
    for lay in order:
        pal_off[lay] = LIB.size + len(blob)
        blob += struct.pack("<%dH" % len(pal_words[lay]), *pal_words[lay])
    offs = []
    for _name, p in patches:
        offs.append(LIB.size + len(blob))
        stride = (p["w"] + 3) & ~3
        for row in p["px"]:
            blob += bytes(row) + b"\0" * (stride - p["w"])
    oset = LIB.size + len(blob)
    hdr = LIB.pack(len(patches), len(order) + 3, oset, 0x0634, 0, 0, 0, 0xABCD, b"\xff\xff\xff\xff", 0, 0, 0)
    imgs = bytearray()
    for (name, p), off in zip(patches, offs):
        imgs += IMAGE.pack(name.encode().ljust(16, b"\0"), 0, p["ax"] & 0xFFFF, p["ay"] & 0xFFFF,
                           p["w"], p["h"], 3 + order.index(p["layout"]), off, 0, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF)
    pals = bytearray()
    for lay in order:
        pals += PALETTE.pack(names[lay].encode().ljust(10, b"\0"), 0, 6, len(pal_words[lay]),
                             pal_off[lay], 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(blob) + bytes(imgs) + bytes(pals)


def sync_lists(text: str, bases: set[str], add: bool) -> tuple[str, int]:
    """Insert (or remove) <PIECE>L straight after <PIECE> in every zero-terminated
    `.long` frame list.  Only lists: a group of consecutive `.long` lines whose last
    item is 0 - so a pointer table that happens to name a piece is left alone."""
    lines = text.split("\n")
    changes = 0
    i = 0
    while i < len(lines):
        if not re.match(r"^\s*(?:[A-Za-z_]\w*:?\s+)?\.long\b", lines[i].split(";")[0], re.I):
            i += 1
            continue
        j = i
        group = [i]
        while True:
            items = [t.strip() for t in re.sub(r"^\s*(?:[A-Za-z_]\w*:?\s+)?\.long\b", "", lines[j].split(";")[0], flags=re.I).split(",")]
            if items and items[-1] == "0":
                break
            nxt = j + 1
            if nxt < len(lines) and re.match(r"^\s+\.long\b", lines[nxt].split(";")[0], re.I):
                j = nxt
                group.append(j)
                continue
            group = None
            break
        if group:
            for k in group:
                code, sep, comment = lines[k].partition(";")
                if add:
                    new = code
                    for b in bases:
                        new = re.sub(rf"\b{b}\b(?!\s*,\s*{b}{SUFFIX}\b)", f"{b},{b}{SUFFIX}", new)
                else:
                    new = re.sub(rf"\s*,\s*(\w+){SUFFIX}\b", lambda m: "" if m.group(1) in bases else m.group(0), code)
                if new != code:
                    changes += 1
                    lines[k] = new + sep + comment
        i = j + 1
    return "\n".join(lines), changes


def slot_problems():
    """The walker knows a logo piece only by its SAG being in JCLOGO's slot, so the
    LOD's address, makevrom's slot and MKDISP's CL_SAG_LO/HI must agree."""
    out = []
    lod = (ROOT / "data" / "JCLOGO.LOD").read_text(errors="replace") if (ROOT / "data" / "JCLOGO.LOD").exists() else ""
    m = re.search(r"^\*\*\*>\s*([0-9A-Fa-f]+)\s*$", lod, re.M)
    slot = re.search(r'"JCLOGO\.IRW":\s*\((0x[0-9A-Fa-f]+),\s*(0x[0-9A-Fa-f]+)', (ROOT / "makevrom.py").read_text())
    disp = (ROOT / "src" / "MKDISP.ASM").read_text(errors="replace")
    lo = re.search(r"^CL_SAG_LO\s+\.set\s+0?([0-9A-Fa-f]+)h", disp, re.M | re.I)
    hi = re.search(r"^CL_SAG_HI\s+\.set\s+0?([0-9A-Fa-f]+)h", disp, re.M | re.I)
    if not (m and slot and lo and hi):
        return ["JCLOGO slot: cannot find the LOD ***> line, makevrom's slot, or CL_SAG_LO/HI"]
    base, start, end = int(m.group(1), 16), int(slot.group(1), 16), int(slot.group(2), 16)
    if (start + 0x400000) * 8 != base:
        out.append(f"JCLOGO slot: LOD ***> {base:X} is not makevrom's start 0x{start:X}")
    want_lo, want_hi = base - 0x2000000, (end + 0x400000) * 8 - 0x2000000
    if (int(lo.group(1), 16), int(hi.group(1), 16)) != (want_lo, want_hi):
        out.append(f"MKDISP CL_SAG_LO/HI {lo.group(1)}/{hi.group(1)} != slot {want_lo:X}/{want_hi:X}")
    return out


# ---------------------------------------------------------------- sheets

def write_sheets(pieces, bases, patches, scale=3):
    from PIL import Image, ImageDraw
    SHEETS.mkdir(parents=True, exist_ok=True)
    for old in SHEETS.glob("cut_*.png"):
        old.unlink()
    pmap = dict(patches)
    tiles = []
    for img, rec, layout, words, _pal, _o in pieces:
        base = bases.get(img, {}).get(rec["name"])
        if base is None:
            continue
        rgb = lambda v: tuple(c * 255 // 31 for c in scan.rgb5(words[v]))
        w, h = rec["w"], rec["h"]
        t = Image.new("RGB", (w * 3 + 8, h + 12), (40, 40, 40))
        for k, grid in enumerate((rec["px"], base, base)):
            p = Image.new("RGB", (w, h), (0, 70, 0))
            for y in range(h):
                for x in range(w):
                    if grid[y][x]:
                        p.putpixel((x, y), rgb(grid[y][x]))
            if k == 2:
                p = p.transpose(Image.FLIP_LEFT_RIGHT)
            t.paste(p, (k * (w + 4), 12))
        ImageDraw.Draw(t).text((1, 0), rec["name"], fill=(220, 220, 220))
        tiles.append(t)
    page_w, n, page, x, y, row_h = 2800 // scale, 0, [], 0, 0, 0
    pages = []
    for t in tiles:
        if x + t.width > page_w:
            x, y, row_h = 0, y + row_h + 6, 0
        if y + t.height > 2000 // scale:
            pages.append(page)
            page, x, y, row_h = [], 0, 0, 0
        page.append((t, x, y))
        x += t.width + 10
        row_h = max(row_h, t.height)
    if page:
        pages.append(page)
    for i, pg in enumerate(pages, 1):
        H = max(py + t.height for t, _, py in pg)
        im = Image.new("RGB", (page_w, H), (40, 40, 40))
        for t, px_, py in pg:
            im.paste(t, (px_, py))
        im.resize((im.width * scale, im.height * scale), Image.NEAREST).save(SHEETS / f"cut_{i:02d}.png")
        n += 1
    return len(tiles), n


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apply", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--restore", action="store_true")
    g.add_argument("--sheets", action="store_true")
    a = ap.parse_args()

    blobs, pieces = load_art()
    bases, patches, proved = cut(pieces)
    base_names = {n for per in bases.values() for n in per}
    pal_words = {}
    for _img, _rec, layout, _w, pal, _o in pieces:
        pal_words.setdefault(layout, pal["words"])
    new_imgs = {img: build_source_img(blobs[img][0], blobs[img][1], bases.get(img, {})) for img in blobs}
    patch_img = build_patch_img(patches, pal_words)
    print(f"cage logo: {proved} pieces cut and proved exact (base + patch == original) "
          f"across {len(bases)} IMGs; {sum(p['w'] * p['h'] for _, p in patches)} patch pixels")

    if a.sheets:
        t, n = write_sheets(pieces, bases, patches)
        print(f"sheets: {t} pieces on {n} pages in {SHEETS.relative_to(ROOT)} (original | base | base mirrored)")
        return 0

    if a.restore:
        for img, (data, recs) in blobs.items():
            drawn = {rec["name"]: rec["px"] for i, rec, *_ in pieces if i == img}
            (ROOT / "data" / f"{img}.IMG").write_bytes(build_source_img(data, recs, drawn))
        if PATCH_IMG.exists():
            PATCH_IMG.unlink()
        for f in LIST_FILES:
            p = ROOT / "src" / f
            raw = p.read_bytes().decode("latin-1")
            text, ch = sync_lists(raw, base_names, add=False)
            if ch:
                p.write_bytes(text.encode("latin-1"))
                print(f"  {f}: {ch} list lines unpatched")
        print("restored the logo into the source IMGs; data/JCLOGO.IMG removed")
        return 0

    bad = []
    for img, data in new_imgs.items():
        path = ROOT / "data" / f"{img}.IMG"
        if a.apply:
            if path.read_bytes() != data:
                path.write_bytes(data)
                print(f"  wrote data/{img}.IMG")
        elif path.read_bytes() != data:
            bad.append(f"data/{img}.IMG differs from pristine@{ORIG_REV[:7]} + the logo cut")
    if a.apply:
        if not PATCH_IMG.exists() or PATCH_IMG.read_bytes() != patch_img:
            PATCH_IMG.write_bytes(patch_img)
            print(f"  wrote {PATCH_IMG.relative_to(ROOT)} ({len(patches)} patches, {len(patch_img)} bytes)")
    elif not PATCH_IMG.exists() or PATCH_IMG.read_bytes() != patch_img:
        bad.append("data/JCLOGO.IMG differs from a fresh cut")
    glo = "".join("\t.global\t%s\r\n" % n for n, _ in patches).encode("ascii")
    if a.apply:
        if not PATCH_GLO.exists() or PATCH_GLO.read_bytes() != glo:
            PATCH_GLO.write_bytes(glo)
            print(f"  wrote {PATCH_GLO.relative_to(ROOT)}")
    elif not PATCH_GLO.exists() or PATCH_GLO.read_bytes() != glo:
        bad.append("src/JCLOGO.GLO differs from the cut's piece names")

    for f in LIST_FILES:
        p = ROOT / "src" / f
        raw = p.read_bytes().decode("latin-1")
        text, ch = sync_lists(raw, base_names, add=True)
        if ch:
            if a.apply:
                p.write_bytes(text.encode("latin-1"))
                print(f"  {f}: {ch} list lines patched")
            else:
                bad.append(f"src/{f}: {ch} frame-list lines draw a logo piece without its patch")

    if a.check:
        names_lod = set(re.findall(r"\b(\w+)\b", "\n".join(
            l[4:] for l in (ROOT / "data" / "JCLOGO.LOD").read_text(errors="replace").splitlines()
            if l.startswith("--->")))) if (ROOT / "data" / "JCLOGO.LOD").exists() else set()
        missing = sorted({n for n, _ in patches} - names_lod)
        extra = sorted(names_lod - {n for n, _ in patches})
        if missing or extra:
            bad.append(f"data/JCLOGO.LOD: missing {missing[:5]} extra {extra[:5]}")
        bad += slot_problems()
        for b in bad:
            print("CAGE LOGO:", b)
        if not bad:
            print("CAGE LOGO OK")
        return 1 if bad else 0

    lod_lines = []
    names = [n for n, _ in patches]
    for i in range(0, len(names), 5):
        lod_lines.append("---> " + ",".join(names[i:i + 5]))
    (ROOT / "tmp").mkdir(exist_ok=True)
    (ROOT / "tmp" / "jclogo_names.txt").write_text("\n".join(lod_lines) + "\n")
    print(f"  LOD name lines for data/JCLOGO.LOD -> tmp/jclogo_names.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
