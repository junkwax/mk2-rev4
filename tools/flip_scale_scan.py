#!/usr/bin/env python3
"""Art the DMA could draw by flipping or scaling another record - opportunity 17.

    python tools/flip_scale_scan.py                    # summary
    python tools/flip_scale_scan.py --json out.json    # every class, for review

The T-unit blitter supports flips (dmahfl/dmavfl) and scaling (oscale),
so a payload that is exactly another payload mirrored - or exactly
another scaled up 2x - is video ROM spent on art the hardware could produce.
This decodes every record out of the packed video ROM (the same layout and
decoder tools/art_identity_snapshot.py proves reflows with) and finds:

  flip classes   distinct payloads of one size whose pixels are the same
                 picture in some orientation (as stored / H / V / H+V).
                 Keep one; the rest are reclaimable.
  exact dups     distinct payloads that are identical as stored.  Reported
                 separately - that was opportunity 05's (cross-LOD sharing).
  2x copies      a payload whose every 2x2 block is one colour and whose
                 half-size image is another payload, in any orientation.

"Reclaimable" is PAYLOAD bits, not a plan: a flipped consumer also needs its
anipoint mirrored around the art's width, multipart pieces re-offset, and a
live consumer of every record removed.  `used` is the same identifier scan
art_identity_snapshot uses - a hint, not reachability.

Distinct dimensions or compression settings at one SAG are separate views.
Overlapping views, including conservative windows for undecodable headers,
are excluded from estimates. Literal inline ASM headers are included; computed
headers and unparsed formats still need a manual consumer audit. Run on current
LOAD2 output and promoted source tables. Totals are not additive across classes.
"""
from __future__ import annotations

import argparse
import bisect
import hashlib
import importlib.util
import json
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def decode_bits(rom, w, h, sag, ctrl, end):
    """(pixels, bits consumed) - art_identity_snapshot.decode, plus the size."""
    bpp = (ctrl >> 12) & 7 or 8
    lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    comp = bool(ctrl & 0x80)
    pos = sag
    px = bytearray(w * h)

    def read(at, n):
        j, shift = divmod(at, 8)
        hi = rom[j + 1] if j + 1 < len(rom) else 0
        return ((rom[j] | hi << 8) >> shift) & ((1 << n) - 1)

    for y in range(h):
        if comp:
            if pos + 8 > end:
                return None, 0
            hdr = read(pos, 8)
            pos += 8
            lead, trail = (hdr & 15) << lm, (hdr >> 4) << tm
        else:
            lead = trail = 0
        count = w - lead - trail
        if count < 0 or pos + count * bpp > end:
            return None, 0
        for x in range(lead, w - trail):
            px[y * w + x] = read(pos, bpp)
            pos += bpp
    return bytes(px), pos - sag


def hflip(px, w, h):
    return b"".join(px[y * w:(y + 1) * w][::-1] for y in range(h))


def vflip(px, w, h):
    return b"".join(px[y * w:(y + 1) * w] for y in range(h - 1, -1, -1))


def h256(b):
    return hashlib.sha256(b).hexdigest()


def orientations(px, w, h):
    hh = hflip(px, w, h)
    return {"as_stored": h256(px), "h": h256(hh), "v": h256(vflip(px, w, h)), "hv": h256(vflip(hh, w, h))}


def half(px, w, h):
    """The exact half-size image, or None if some 2x2 block is not uniform."""
    if w % 2 or h % 2 or w < 2 or h < 2:
        return None
    w2, h2 = w // 2, h // 2
    out = bytearray(w2 * h2)
    for y in range(h2):
        for x in range(w2):
            a = px[(2 * y) * w + 2 * x]
            if not (px[(2 * y) * w + 2 * x + 1] == a and px[(2 * y + 1) * w + 2 * x] == a
                    and px[(2 * y + 1) * w + 2 * x + 1] == a):
                return None
            out[y * w2 + x] = a
    return bytes(out)


def collect_payloads(records, rom, spans, used, emitted):
    """Keep distinct decode views; never merge headers just because SAGs match.

    Flip/draw-mode bits do not change stored pixels. Dimensions, depth and
    compression do. A second view into any part of a payload makes deletion
    ambiguous, so exclude both views from the automatic savings shortlist.
    """
    starts = [s[0] for s in spans]
    payloads, skipped, uncertain = {}, defaultdict(list), []
    for fname, label, w, h, sag, ctrl in records:
        name = f"{fname}:{label}"
        loaded = label in emitted.get(fname.upper(), ())
        if not loaded and label not in used:
            skipped["stale_unreferenced"].append(name)
            continue
        i = bisect.bisect_right(starts, sag // 8) - 1
        span = spans[i] if i >= 0 and sag < spans[i][1] * 8 else None
        if not span or not (0 < w <= 1023 and 0 < h <= 1023):
            skipped["outside_or_invalid"].append(name)
            continue
        key = (sag, w, h, ctrl & 0x7f80)
        p = payloads.get(key)
        if p is None:
            px, bits = decode_bits(rom, w, h, sag, ctrl, span[1] * 8)
            if px is None:
                skipped["undecodable"].append(name)
                # A failed decode must not make a neighbouring allocation look
                # free. Bound every row by its uncompressed width plus header.
                bound = w * h * ((ctrl >> 12) & 7 or 8)
                if ctrl & 0x80:
                    bound += h * 8
                uncertain.append(dict(sag=sag, bits=min(bound, span[1] * 8 - sag),
                                      labels=[name], overlaps=[]))
                continue
            p = payloads[key] = dict(sag=sag, w=w, h=h, ctrl=ctrl,
                                     bits=bits, px=px, irw=span[2], bank=span[3],
                                     labels=[], used=False, load2=False, overlaps=[])
        p["labels"].append(name)
        p["used"] |= label in used
        p["load2"] |= loaded

    active = []
    for p in sorted([*payloads.values(), *uncertain], key=lambda p: p["sag"]):
        active = [q for q in active if q["sag"] + q["bits"] > p["sag"]]
        for q in active:
            if p["bits"]:
                p["overlaps"].extend(q["labels"])
                q["overlaps"].extend(p["labels"])
        active.append(p)
    return payloads, dict(skipped)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--min-bytes", type=int, default=0, help="only list classes freeing at least this much")
    args = ap.parse_args()

    ais = _module("ais", ROOT / "tools/art_identity_snapshot.py")
    mv = _module("mv", ROOT / "makevrom.py")
    bpp = _module("bppaudit", ROOT / "tools/audit_sprite_bpp.py")
    rom, spans = ais.flat_rom(mv)
    used = ais.referenced_labels()
    emitted = ais.load2_emitted()
    if not emitted:
        raise SystemExit("No current LOAD2 tables; run the art build before scanning.")
    records = list(bpp.parse_tbls(str(ROOT / "src")))
    inline = _module("inline_sags", ROOT / "tools/sync_inline_sags.py")
    for path in sorted((ROOT / "src").glob("*.ASM")):
        for m in inline.RECORD.finditer(path.read_text(encoding="latin-1")):
            records.append((path.name, m['label'], int(m['w']), int(m['h']),
                            int(m['sag'], 16), int(m['ctrl'], 16)))
    payloads, skipped = collect_payloads(records, rom, spans, used, emitted)
    eligible = [p for p in payloads.values() if not p["overlaps"]]

    # flip classes and exact duplicates
    by_class = defaultdict(list)
    for p in eligible:
        o = orientations(p["px"], p["w"], p["h"])
        p["orient"] = o
        p["canon"] = min(o.values())
        by_class[(p["w"], p["h"], p["canon"])].append(p)

    flip_classes, dup_classes = [], []
    for (w, h, canon), members in by_class.items():
        if len(members) < 2:
            continue
        stored = defaultdict(list)
        for m in members:
            stored[m["orient"]["as_stored"]].append(m)
        # exact duplicates inside the class
        for group in stored.values():
            if len(group) > 1:
                dup_classes.append(dict(w=w, h=h, members=group,
                                        reclaim_bits=sum(g["bits"] for g in group) - max(g["bits"] for g in group)))
        if len(stored) < 2:
            continue
        # one representative per distinct stored picture; keep the largest-used one
        reps = [max(g, key=lambda m: (m["used"], m["bits"])) for g in stored.values()]
        keep = max(reps, key=lambda m: (m["used"], m["bits"]))
        kinds = []
        for r in reps:
            if r is keep:
                continue
            rel = next(k for k, v in keep["orient"].items() if v == r["orient"]["as_stored"])
            kinds.append((r, rel))
        flip_classes.append(dict(w=w, h=h, keep=keep, others=kinds,
                                 reclaim_bits=sum(r["bits"] for r, _ in kinds)))

    # exact 2x copies of another payload (any orientation)
    canon_index = defaultdict(list)
    for p in eligible:
        for k, v in p["orient"].items():
            canon_index[(p["w"], p["h"], v)].append((p, k))
    scale_pairs = []
    for p in eligible:
        hp = half(p["px"], p["w"], p["h"])
        if hp is None:
            continue
        key = (p["w"] // 2, p["h"] // 2, h256(hp))
        for small, k in canon_index.get(key, ()):
            if small["sag"] != p["sag"]:
                scale_pairs.append(dict(big=p, small=small, orientation=k, reclaim_bits=p["bits"]))
                break

    def labels(m):
        return ", ".join(m["labels"][:3]) + (" +%d" % (len(m["labels"]) - 3) if len(m["labels"]) > 3 else "")

    fb = sum(c["reclaim_bits"] for c in flip_classes) // 8
    db = sum(c["reclaim_bits"] for c in dup_classes) // 8
    sb = sum(c["reclaim_bits"] for c in scale_pairs) // 8
    print("decoded %d distinct views; %d excluded for overlapping storage" %
          (len(payloads), len(payloads) - len(eligible)))
    print("skipped: " + ", ".join(f"{k}={len(v)}" for k, v in sorted(skipped.items())))
    print("flip classes      %4d   reclaimable %7d bytes   (%d of them with every member referenced)"
          % (len(flip_classes), fb, sum(1 for c in flip_classes if c["keep"]["used"] and all(r["used"] for r, _ in c["others"]))))
    print("exact duplicates  %4d   reclaimable %7d bytes   (opportunity 05's territory)" % (len(dup_classes), db))
    print("2x copies         %4d   reclaimable %7d bytes" % (len(scale_pairs), sb))
    print("Candidate estimates only; categories are alternatives, not additive savings.")
    print()
    print("largest flip classes:")
    for c in sorted(flip_classes, key=lambda c: -c["reclaim_bits"])[:25]:
        if c["reclaim_bits"] // 8 < args.min_bytes:
            break
        print("  %4dx%-4d keep %-45s %s" % (c["w"], c["h"], labels(c["keep"])[:45], "used" if c["keep"]["used"] else "UNUSED"))
        for r, rel in c["others"]:
            print("            %-3s %6d B  %-42s %s  [%s bank %d]" % (rel, r["bits"] // 8, labels(r)[:42],
                                                                 "used" if r["used"] else "UNUSED", r["irw"], r["bank"]))
    if dup_classes:
        print("\nexact duplicates (every copy after the first is reclaimable):")
        for c in sorted(dup_classes, key=lambda c: -c["reclaim_bits"]):
            if c["reclaim_bits"] // 8 < args.min_bytes:
                break
            print("  %4dx%-4d %6d B" % (c["w"], c["h"], c["reclaim_bits"] // 8))
            for m in sorted(c["members"], key=lambda m: m["sag"]):
                print("            %6d B  %-42s %s  [%s bank %d]" % (m["bits"] // 8, labels(m)[:42],
                                                                "used" if m["used"] else "UNUSED", m["irw"], m["bank"]))
    if scale_pairs:
        print("\n2x copies:")
        for s in sorted(scale_pairs, key=lambda s: -s["reclaim_bits"])[:15]:
            print("  %6d B  %s (%dx%d) = 2x %s %s" % (s["reclaim_bits"] // 8, labels(s["big"])[:40], s["big"]["w"], s["big"]["h"],
                                                   s["orientation"], labels(s["small"])[:40]))

    if args.json:
        def slim(m):
            return dict(labels=m["labels"], w=m["w"], h=m["h"], sag="0x%08x" % m["sag"], bytes=m["bits"] // 8,
                        bits=m["bits"], ctrl="0x%04x" % m["ctrl"],
                        irw=m["irw"], bank=m["bank"], used=m["used"], load2=m["load2"])
        out = dict(payloads=len(payloads), flip_reclaim_bytes=fb, dup_reclaim_bytes=db, scale_reclaim_bytes=sb,
                   skipped=skipped,
                   overlapping_views=[dict(slim(p), overlaps=p["overlaps"])
                                      for p in payloads.values() if p["overlaps"]],
                   flip_classes=[dict(w=c["w"], h=c["h"], reclaim_bytes=c["reclaim_bits"] // 8, keep=slim(c["keep"]),
                                      others=[dict(slim(r), relation=rel) for r, rel in c["others"]])
                                 for c in sorted(flip_classes, key=lambda c: -c["reclaim_bits"])],
                   dup_classes=[dict(w=c["w"], h=c["h"], reclaim_bytes=c["reclaim_bits"] // 8,
                                     members=[slim(m) for m in sorted(c["members"], key=lambda m: m["sag"])])
                                for c in sorted(dup_classes, key=lambda c: -c["reclaim_bits"])],
                   scale_pairs=[dict(big=slim(s["big"]), small=slim(s["small"]), orientation=s["orientation"],
                                     reclaim_bytes=s["reclaim_bits"] // 8)
                                for s in sorted(scale_pairs, key=lambda s: -s["reclaim_bits"])])
        args.json.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
        print("\nwrote %s" % args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
