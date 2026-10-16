#!/usr/bin/env python3
"""
Audit every IMG library the build actually feeds to LOAD2 and report the
records inside it that no LOD ever asks for.

LOAD2 resolves a LOD's `---> NAME` list against the IMG record NAMES - the
A/B strips are separate pre-cut records in the library, not something LOAD2
carves at build time.  So "which subframes are we not using" is an exact set
difference, not a guess:

    unused(IMG) = {record names in IMG} - {names any live LOD names}

Buckets, because not every unused record is lost content:

  MISSING   a LOD asks for a name the IMG does not carry.  LOAD2 packs
            nothing and the label builds EMPTY - this is a build bug.
            (data/JADVIC1+2 shipped like this until they were re-sourced.)
  UNCUT     unused whole-frame record whose own A/B/C strips ARE loaded.
            Same art, other cut.  Redundant, not lost.
  STRIP     unused strip whose uncut parent (or a sibling strip) IS loaded.
  UNUSED    nothing related is loaded anywhere - real unloaded art.

"Live" LODs are the ones data/IMGBUILD.BAT actually runs; a LOD sitting on
disk behind a REM (STCUT, KGBLOOD, VSNOOB...) does not make art loaded.

Usage:
    python tools/img_subframe_audit.py                 # summary + per-IMG
    python tools/img_subframe_audit.py --img HATHED1   # one library
    python tools/img_subframe_audit.py --unused-only   # skip UNCUT/STRIP
    python tools/img_subframe_audit.py --missing       # just the build bugs
    python tools/img_subframe_audit.py --orphans       # IMGs no live LOD reads
    python tools/img_subframe_audit.py --check         # nonzero if MISSING
"""
from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")

# IMG record stride is not constant across the tree.  The v6.x libraries
# (0x062e..0x063c, all but three files) use the 50-byte record above.  The
# two version-0 libraries (FBFONT7) use a 42-byte record with no palnum -
# read those at stride 50 and every name past record 0 is garbage, which
# reads as "the LOD asks for a name the IMG does not have".  Detect it.
STRIDES = (50, 42, 58, 34, 66)

# ENDMARKER ends a table.  Some libraries (BOONPICS) carry a real record by
# that name and some do not, and LOAD2 logs "Couldn't find image" either way -
# so it counts as used where it exists and is never a MISSING finding.
SENTINELS = {"ENDMARKER"}

_STRIP_SUFFIX = re.compile(r"^(?P<base>.*?[0-9])(?P<tail>[A-Z]{1,2}[0-9]?)$")


def cstr(b: bytes) -> str:
    return b.split(b"\0", 1)[0].decode("latin-1", errors="replace")


def s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


# ---------------------------------------------------------------- IMG side


def _score(data, start, stride, imgcnt):
    """How many of the first records look like real named entries."""
    good = 0
    n = min(imgcnt, 24)
    for i in range(n):
        off = start + i * stride
        if off + stride > len(data):
            return -1
        nm = data[off:off + 16].split(b"\0", 1)[0]
        if not nm or not all(32 <= c < 127 for c in nm):
            continue
        w, h = struct.unpack_from("<HH", data, off + 22)
        if 0 < w <= 1024 and 0 < h <= 1024:
            good += 1
    return good


def read_img(path: Path):
    """Return (records, note).  records = list of dicts in file order."""
    data = path.read_bytes()
    if len(data) < LIB_HDR.size:
        return [], "too small"
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    if imgcnt == 0:
        return [], "imgcnt=0"

    best = (-1, None, None)
    for start in (oset, oset + palcnt * PALETTE.size):
        for stride in STRIDES:
            s = _score(data, start, stride, imgcnt)
            if s > best[0]:
                best = (s, start, stride)
    score, img_start, stride = best
    if score <= 0:
        return [], "could not locate record table (oset=%#x)" % oset

    recs = []
    for i in range(imgcnt):
        off = img_start + i * stride
        if off + stride > len(data):
            break
        name = cstr(data[off:off + 16])
        flags, anix, aniy, w, h = struct.unpack_from("<HHHHH", data, off + 16)
        # palnum only exists in the 50-byte v6 record
        pal = struct.unpack_from("<H", data, off + 26)[0] if stride >= 50 else -1
        recs.append({"idx": i, "name": name, "flags": flags,
                     "anix": s16(anix), "aniy": s16(aniy),
                     "w": w, "h": h, "pal": pal, "stride": stride})
    return recs, ""


# ---------------------------------------------------------------- LOD side


def live_lods():
    """LOD basenames IMGBUILD.BAT actually runs (REM lines excluded)."""
    bat = (DATA / "IMGBUILD.BAT").read_text(errors="replace")
    out = []
    for line in bat.splitlines():
        s = line.strip()
        if s.upper().startswith("REM"):
            continue
        m = re.search(r"load2\s+([A-Za-z0-9_]+)", s, re.I)
        if m:
            out.append(m.group(1).upper())
    return out


def parse_lod(path: Path):
    """-> (uses, ppp)  uses = {IMG stem upper: [names]}"""
    uses = {}
    ppp = {}
    cur = None
    depth = 0
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith(";"):
            continue
        m = re.match(r"^PPP>\s*(\d+)", line, re.I)
        if m:
            depth = int(m.group(1))
            continue
        m = re.match(r"^([A-Za-z0-9_.\-]+)\.(?:IMG|img)\s*$", line)
        if m:
            cur = m.group(1).upper()
            uses.setdefault(cur, [])
            ppp.setdefault(cur, depth)
            continue
        if line.startswith("--->"):
            if cur is None:
                continue
            for n in line[4:].split(","):
                n = n.strip().upper()
                if n:
                    uses[cur].append(n)
    return uses, ppp


def collect(lod_names):
    used, origin, ppp = {}, {}, {}
    for lod in lod_names:
        p = DATA / (lod + ".LOD")
        if not p.exists():
            continue
        u, d = parse_lod(p)
        for img, names in u.items():
            used.setdefault(img, set()).update(names)
            origin.setdefault(img, set()).add(lod)
            if img not in ppp or ppp[img] == 0:
                ppp[img] = d.get(img, 0)
    return used, origin, ppp


# ---------------------------------------------------------------- classify


def base_of(name):
    m = _STRIP_SUFFIX.match(name)
    return m.group("base") if m else None


def classify(name, gused):
    """Bucket a record that this library does not load.

    `gused` is every name loaded from ANY live library, not just this one -
    the same art is routinely carried in two libraries (UGMO9 / UGMO9SP) and
    a per-library set would call half the tree unused.
    """
    if name in gused:
        return "ELSEWHERE"
    for u in gused:
        if u.startswith(name) and len(u) > len(name) and u[len(name)].isalpha():
            return "UNCUT"
    b = base_of(name)
    if b:
        if b in gused:
            return "STRIP"
        for u in gused:
            if u.startswith(b) and u != name:
                return "STRIP"
    return "UNUSED"


def bytes_at(w, h, bpp):
    if bpp <= 0:
        bpp = 8
    return (w * h * bpp + 7) // 8


# ---------------------------------------------------------------- report


def build_report(only_img=None):
    lods = live_lods()
    used, origin, ppp = collect(lods)

    gused = set()
    for names in used.values():
        gused |= names

    rows = []
    for img in sorted(used):
        path = DATA / (img + ".IMG")
        if not path.exists():
            alt = DATA / (img + ".img")
            if alt.exists():
                path = alt
        if not path.exists():
            rows.append({"img": img, "error": "IMG FILE NOT FOUND",
                         "lods": sorted(origin[img]), "missing": sorted(used[img]),
                         "unused": [], "ppp": ppp.get(img, 0), "nrec": 0, "nused": 0})
            continue
        recs, note = read_img(path)
        allnames = {r["name"].upper() for r in recs}
        u = used[img]
        depth = ppp.get(img, 0)
        unused = []
        for r in recs:
            nm = r["name"].upper()
            if nm in u or not nm:
                continue
            unused.append(dict(r, kind=classify(nm, gused),
                               bytes=bytes_at(r["w"], r["h"], depth)))
        rows.append({"img": img, "error": note, "lods": sorted(origin[img]),
                     "missing": sorted(u - allnames - SENTINELS), "unused": unused,
                     "ppp": depth, "nrec": len(recs), "nused": len(u & allnames)})

    referenced = set(used)
    orphans = []
    seen = set()
    for p in sorted(DATA.glob("*.IMG")) + sorted(DATA.glob("*.img")):
        stem = p.stem.upper()
        if stem in referenced or stem in seen:
            continue
        seen.add(stem)
        recs, _ = read_img(p)
        orphans.append({"img": stem, "nrec": len(recs), "size": p.stat().st_size})

    if only_img:
        rows = [r for r in rows if r["img"] == only_img.upper()]
    return rows, orphans, lods


def emit_md(rows, orphans, lods, tot, n_missing, a):
    P = print
    P("# IMG subframe audit")
    P("")
    P("Generated by `python tools/img_subframe_audit.py --md`. For every IMG")
    P("library a live LOD reads, this is the set of records inside it that no")
    P("live LOD ever names - LOAD2 resolves `---> NAME` against the record")
    P("names in the library, so it is an exact difference, not an estimate.")
    P("")
    P("`~bytes` is **uncompressed** `w*h*ppp/8` at the LOD's colour depth - an")
    P("upper bound. What a frame actually costs in video ROM is whatever it")
    P("packs to after LOAD2's zero compression.")
    P("")
    P("| bucket | meaning |")
    P("|---|---|")
    P("| `MISSING` | a live LOD names a record the library does not carry. LOAD2 logs `Couldn't find image` and the label builds EMPTY. A build bug. |")
    P("| `UNUSED` | nothing related is loaded from any library - real unloaded art. |")
    P("| `UNCUT` | whole-frame record whose own A/B/C strips are loaded. Same art, other cut. |")
    P("| `STRIP` | strip whose uncut parent or a sibling strip is loaded. |")
    P("| `ELSEWHERE` | this exact name is loaded from a different library. |")
    P("")
    P("## Totals")
    P("")
    P("| | records | ~bytes |")
    P("|---|---:|---:|")
    P("| in live libraries | %s | |" % format(sum(r["nrec"] for r in rows), ","))
    P("| loaded by a live LOD | %s | |" % format(sum(r["nused"] for r in rows), ","))
    for k in ("UNUSED", "UNCUT", "STRIP", "ELSEWHERE"):
        P("| `%s` | %s | %s |" % (k, format(tot[k][0], ","), format(tot[k][1], ",")))
    P("| `MISSING` | %d | |" % n_missing)
    P("")
    P("%d live LODs, %d IMG libraries." % (len(lods), len(rows)))
    P("")

    P("## MISSING - LOD names that resolve to nothing")
    P("")
    hit = False
    for r in rows:
        if r["missing"]:
            hit = True
            P("**%s.IMG** (loaded by %s): %s"
              % (r["img"], ", ".join(r["lods"]), ", ".join("`%s`" % m for m in r["missing"])))
            P("")
    if not hit:
        P("None.")
        P("")

    P("## Unused records, by library")
    P("")

    def weight(x):
        return sum(u["bytes"] for u in x["unused"]
                   if not a.unused_only or u["kind"] == "UNUSED")

    for r in sorted(rows, key=lambda x: -weight(x)):
        sel = [u for u in r["unused"]
               if (not a.unused_only or u["kind"] == "UNUSED")
               and u["bytes"] >= a.min_bytes]
        if not sel:
            continue
        nb = sum(u["bytes"] for u in sel)
        P("### %s.IMG" % r["img"])
        P("")
        P("Loaded by %s, ppp %d, %d of %d records loaded. %d unused, ~%s bytes."
          % (", ".join("`%s`" % l for l in r["lods"]), r["ppp"], r["nused"],
             r["nrec"], len(sel), format(nb, ",")))
        P("")
        P("| bucket | name | size | anchor | pal | ~bytes |")
        P("|---|---|---|---:|---:|---:|")
        for u in sorted(sel, key=lambda x: -x["bytes"]):
            P("| `%s` | `%s` | %dx%d | %d,%d | %d | %s |"
              % (u["kind"], u["name"], u["w"], u["h"], u["anix"], u["aniy"],
                 u["pal"], format(u["bytes"], ",")))
        P("")

    P("## IMG libraries no live LOD reads at all")
    P("")
    P("These cost no ROM - they are art on disk the build never opens.")
    P("")
    P("| library | records | file bytes |")
    P("|---|---:|---:|")
    for o in sorted(orphans, key=lambda x: -x["size"]):
        P("| `%s` | %d | %s |" % (o["img"], o["nrec"], format(o["size"], ",")))
    P("")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img")
    ap.add_argument("--md", action="store_true")
    ap.add_argument("--unused-only", action="store_true")
    ap.add_argument("--missing", action="store_true")
    ap.add_argument("--orphans", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--min-bytes", type=int, default=0)
    a = ap.parse_args()

    rows, orphans, lods = build_report(a.img)
    n_missing = sum(len(r["missing"]) for r in rows)

    if a.check:
        if n_missing:
            for r in rows:
                for m in r["missing"]:
                    print("MISSING %s.IMG has no record %s" % (r["img"], m))
            print("FAIL: %d LOD name(s) resolve to nothing" % n_missing)
            return 1
        print("OK: %d live IMG libraries, every LOD name resolves" % len(rows))
        return 0

    if a.orphans:
        tot = sum(o["size"] for o in orphans)
        print("# IMG libraries no live LOD reads: %d  (%.0f KB on disk)\n"
              % (len(orphans), tot / 1024))
        for o in sorted(orphans, key=lambda x: -x["size"]):
            print("  %-14s %5d records  %9s bytes"
                  % (o["img"], o["nrec"], format(o["size"], ",")))
        return 0

    if a.missing:
        print("# LOD names that resolve to no IMG record (label builds EMPTY)\n")
        hit = False
        for r in rows:
            if r["missing"]:
                hit = True
                print("%s.IMG  (loaded by %s)" % (r["img"], ", ".join(r["lods"])))
                for m in r["missing"]:
                    print("    " + m)
        if not hit:
            print("  none")
        return 0

    kinds = ("UNUSED", "UNCUT", "STRIP", "ELSEWHERE")
    tot = dict((k, [0, 0]) for k in kinds)
    for r in rows:
        for u in r["unused"]:
            tot[u["kind"]][0] += 1
            tot[u["kind"]][1] += u["bytes"]

    if a.md:
        return emit_md(rows, orphans, lods, tot, n_missing, a)

    print("# IMG subframe audit - %d live LODs, %d IMG libraries\n"
          % (len(lods), len(rows)))
    print("records in live libraries : %s" % format(sum(r["nrec"] for r in rows), ","))
    print("loaded by a live LOD      : %s" % format(sum(r["nused"] for r in rows), ","))
    for k in kinds:
        print("%-26s: %s records, ~%s bytes uncompressed"
              % (k, format(tot[k][0], ","), format(tot[k][1], ",")))
    print("%-26s: %d" % ("MISSING (build bugs)", n_missing))
    print()

    def weight(x):
        return sum(u["bytes"] for u in x["unused"]
                   if not a.unused_only or u["kind"] == "UNUSED")

    for r in sorted(rows, key=lambda x: -weight(x)):
        sel = [u for u in r["unused"]
               if (not a.unused_only or u["kind"] == "UNUSED")
               and u["bytes"] >= a.min_bytes]
        if not sel and not r["missing"] and not r["error"]:
            continue
        nb = sum(u["bytes"] for u in sel)
        print("## %s.IMG  [%s]  ppp=%d  %d/%d loaded  -  %d unused, ~%s bytes"
              % (r["img"], ", ".join(r["lods"]), r["ppp"], r["nused"],
                 r["nrec"], len(sel), format(nb, ",")))
        if r["error"]:
            print("    !! " + r["error"])
        for m in r["missing"]:
            print("    MISSING  " + m)
        for u in sorted(sel, key=lambda x: -x["bytes"]):
            print("    %-7s %-20s %4dx%-4d anch %4d,%-5d pal %-3d ~%9sb"
                  % (u["kind"], u["name"], u["w"], u["h"], u["anix"],
                     u["aniy"], u["pal"], format(u["bytes"], ",")))
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
