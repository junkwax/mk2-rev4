#!/usr/bin/env python3
r"""Build data/STONECRK.IMG - Shao Kahn's stone-crack frames as crack-only overlays.

Graphics audit row 30 (doc/graphics_opportunities/MULTIPART_SHARE_SCAN.md).  `a_stone_crack`
(MKSK.ASM, Kahn's animation table entry 16, played by the turn-to-stone ending in MKFX.ASM)
walks BGSTONECRACK1..8, each a two-piece frame of the same statue with cracks spreading over
it.  Frames 1, 2 and 4-7 differ from the plain statue (STONEBODA/B) almost only by RECOLOURED
pixels, so each is rebuilt as

    STONEBASEA, STONEBASEB, STONEPATnA, STONEPATnB     (queued in that order: patches on top)

  STONEBASEA  STONEBODA, exactly.  It is packed PON> and has to stay the first piece of the
              first frame: make_kahn_obj reads the palette off that record (*a5(icmap) ->
              player_swpal), which used to be BGSTONECRACK1A.
  STONEBASEB  STONEBODB with every pixel that some crack frame makes transparent cleared.  A
              patch only writes non-zero pixels, so it cannot erase; those positions (on the
              statue's outline) are left out of the base, and a frame that keeps one gets it
              back from its own patch.
  STONEPATnp  frame n, piece p, wherever it differs from its base - 0 elsewhere - cropped to
              the changed pixels.  Its anipoint is the base's minus the crop offset, so it lands
              on exactly the pixels it replaces.

Every frame is PROVED before anything is written: the base with its patch composited over it
(non-zero patch pixels win) must equal the original piece, pixel for pixel.  Frame 3 (its A/B
split sits one column over) and frame 8 (a different size) keep their own art.

    python tools/make_stonecrk_img.py            # write data/STONECRK.IMG
    python tools/make_stonecrk_img.py --check    # Phase D: fail if it has drifted

Source is data/BOSS7.IMG, the authored art - for every piece used here its pixels equal the
packed ROM's (checked 2026-09-15).  The palette is BOSS7's BGSTONE_P record, copied, so the
name LOAD2 emits on STONEBASEA is the one src/IMGPAL5.ASM defines.
"""
import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "BOSS7.IMG"
OUT = ROOT / "data" / "STONECRK.IMG"

LIB = struct.Struct("<HHIHHHHH 4s HHH")               # 28
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")   # 50
PALETTE = struct.Struct("<10s BB H I H H B B H")      # 26

PAL_NAME = "BGSTONE_P"
FRAMES = (1, 2, 4, 5, 6, 7)
PALNUM = 3            # 3-based: the only palette record in the file


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


def geometry(rec):
    return rec["w"], rec["h"], rec["ax"], rec["ay"]


def build_frames(imgs, pal):
    statue = {"A": imgs["STONEBODA"], "B": imgs["STONEBODB"]}
    for p, s in statue.items():
        if s["palnum"] != pal["palnum"]:
            sys.exit("STONEBOD%s is on palnum %d, not %s's %d" % (p, s["palnum"], PAL_NAME, pal["palnum"]))

    # every position some crack frame makes transparent where the statue is opaque
    erase = {"A": set(), "B": set()}
    for n in FRAMES:
        for p in "AB":
            f, s = imgs["BGSTONECRACK%d%s" % (n, p)], statue[p]
            if geometry(f) != geometry(s):
                sys.exit("BGSTONECRACK%d%s geometry %s is not the statue's %s" % (n, p, geometry(f), geometry(s)))
            if f["palnum"] != pal["palnum"]:
                sys.exit("BGSTONECRACK%d%s is on palnum %d" % (n, p, f["palnum"]))
            for y in range(s["h"]):
                for x in range(s["w"]):
                    if s["px"][y][x] and not f["px"][y][x]:
                        erase[p].add((x, y))

    bases = {}
    for p, s in statue.items():
        g = [row[:] for row in s["px"]]
        for x, y in erase[p]:
            g[y][x] = 0
        bases[p] = dict(s, px=g)

    out = [("STONEBASEA", bases["A"]), ("STONEBASEB", bases["B"])]
    proof = []
    for n in FRAMES:
        for p in "AB":
            f, b = imgs["BGSTONECRACK%d%s" % (n, p)], bases[p]
            w, h = b["w"], b["h"]
            if any(b["px"][y][x] and not f["px"][y][x] for y in range(h) for x in range(w)):
                sys.exit("BGSTONECRACK%d%s still needs an erase over the base" % (n, p))
            diff = [[f["px"][y][x] if f["px"][y][x] != b["px"][y][x] else 0 for x in range(w)] for y in range(h)]
            rows = [y for y in range(h) if any(diff[y])]
            cols = [x for x in range(w) if any(diff[y][x] for y in range(h))]
            if not rows:
                sys.exit("BGSTONECRACK%d%s is identical to its base - nothing to patch" % (n, p))
            y0, y1, x0, x1 = rows[0], rows[-1], cols[0], cols[-1]
            crop = [row[x0:x1 + 1] for row in diff[y0:y1 + 1]]
            patch = dict(w=x1 - x0 + 1, h=y1 - y0 + 1, ax=b["ax"] - x0, ay=b["ay"] - y0, palnum=b["palnum"], px=crop)
            # the proof: base, then the patch's non-zero pixels on top, placed by anipoint
            comp = [row[:] for row in b["px"]]
            ox, oy = patch["ax"] - b["ax"], patch["ay"] - b["ay"]    # base-local origin of the patch, negated
            for cy in range(patch["h"]):
                for cx in range(patch["w"]):
                    v = crop[cy][cx]
                    if v:
                        comp[cy - oy][cx - ox] = v
            if comp != f["px"]:
                sys.exit("PROOF FAILED: STONEBASE%s + STONEPAT%d%s is not BGSTONECRACK%d%s" % (p, n, p, n, p))
            proof.append("BGSTONECRACK%d%s" % (n, p))
            out.append(("STONEPAT%d%s" % (n, p), patch))
    return out, erase, proof


def build_img(frames, pal):
    blob = bytearray()
    pal_off = LIB.size
    blob += struct.pack("<%dH" % len(pal["words"]), *pal["words"])
    offsets = []
    for _name, rec in frames:
        offsets.append(LIB.size + len(blob))
        stride = (rec["w"] + 3) & ~3
        for row in rec["px"]:
            blob += bytes(row) + b"\0" * (stride - rec["w"])
    oset = LIB.size + len(blob)
    hdr = LIB.pack(len(frames), 1 + 3, oset, 0x0634, 0, 0, 0, 0xABCD, b"\xff\xff\xff\xff", 0, 0, 0)
    imgs = bytearray()
    for (name, rec), off in zip(frames, offsets):
        imgs += IMAGE.pack(name.encode().ljust(16, b"\0"), 0, rec["ax"] & 0xFFFF, rec["ay"] & 0xFFFF,
                           rec["w"], rec["h"], PALNUM, off, 0, 0, 0, 0, 0, 0, 0xFFFF, 0xFFFF)
    pals = PALETTE.pack(PAL_NAME.encode().ljust(10, b"\0"), 0, pal["bpp"], len(pal["words"]), pal_off, 0, 0, 0, 0, 0)
    return bytes(hdr) + bytes(blob) + bytes(imgs) + bytes(pals)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--check", action="store_true", help="fail if the file on disk differs from a fresh build")
    args = ap.parse_args()

    imgs, pals = read_img(SRC)
    if PAL_NAME not in pals:
        sys.exit("%s has no %s palette record" % (SRC.name, PAL_NAME))
    frames, erase, proof = build_frames(imgs, pals[PAL_NAME])
    data = build_img(frames, pals[PAL_NAME])

    if args.check:
        if not args.out.exists():
            print("STONECRK: %s missing - run tools/make_stonecrk_img.py" % args.out)
            return 1
        if args.out.read_bytes() != data:
            print("STONECRK: %s differs from a fresh build - regenerate it" % args.out)
            return 1
        print("STONECRK.IMG OK (%d frames, %d crack pieces proved)" % (len(frames), len(proof)))
        return 0

    args.out.write_bytes(data)
    print("proved: %d crack pieces composite exactly (%s)" % (len(proof), ", ".join(proof)))
    print("base erase positions (left out of the base): A %s  B %s" % (sorted(erase["A"]), sorted(erase["B"])))
    print("wrote %s (%d frames, %d bytes)" % (args.out, len(frames), len(data)))
    for name, rec in frames:
        print("  %-12s %3dx%-3d  anipoint (%d,%d)" % (name, rec["w"], rec["h"], rec["ax"], rec["ay"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
