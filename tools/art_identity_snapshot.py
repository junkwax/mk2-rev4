#!/usr/bin/env python3
"""Fingerprint every sprite record's DECODED PIXELS, so a reflow can be proved.

Moving art inside a packed run - deleting a dead record, repacking a lane at a
lower depth, sharing one payload between two consumers - shifts every SAG after
it.  The promoters regenerate the tables, the build links, the ROM boots, and
nothing anywhere says whether the picture a given label points at is still the
same picture.  A SAG is not evidence: it is exactly the thing that moved.

So this decodes the pixels each record actually points at, out of the packed
video ROM, and hashes them:

    python tools/art_identity_snapshot.py --write tmp/art_before.json
    ... change a LOD, rebuild, makevrom ...
    python tools/art_identity_snapshot.py --compare tmp/art_before.json

CHANGED is the finding that matters: a label whose pixels are not what they
were.  ADDED/REMOVED are expected whenever records are deliberately added to or
dropped from a LOD, and are listed rather than counted as failures unless
--strict is given.

Records whose header cannot be decoded (the parser does not cover every manual
or BLIMP layout) are carried as "undecodable" and compared by that status only,
so they cannot silently turn into a false PASS.

Two flags decide whether a CHANGED record is breakage or bookkeeping:

  load2   the current LOAD2 pass emits this record, so promote_tbls rewrites
          its SAG and it reflows with its payload.
  used    some src/*.ASM or *.GLO mentions the label, so something can draw it.

A record that is neither emitted nor used is a leftover: a header promote_tbls
preserves because it is src-only, for art no LOD loads any more.  Its SAG does
not move when the run around it reflows, so its pixels change and nothing
cares.  Those are reported under STALE and do not fail; a CHANGED record that
IS used fails, which is the case that matters.
"""
from __future__ import annotations

import argparse
import ast
import bisect
import hashlib
import importlib.util
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def flat_rom(mv):
    """The packed video ROM exactly as makevrom lays it out, plus its spans."""
    tree = ast.parse((ROOT / "makevrom.py").read_text())
    shipping = next(ast.literal_eval(n.value) for n in ast.walk(tree)
                    if isinstance(n, ast.Assign) and any(
                        isinstance(t, ast.Name) and t.id == "irw_files"
                        for t in n.targets))
    rom = bytearray(b"\xff" * mv.VIDEO_SIZE)
    spans = []
    for name in shipping:
        path = ROOT / "data" / name
        if not path.exists():
            raise SystemExit("Missing shipped IRW: %s - run makevrom.py" % name)
        base, bank, data = mv.parse_irw(path)
        if bank not in mv.BANK_OFFSETS:
            bank = mv.FILE_BANK.get(name, 0)
        start = mv.BANK_OFFSETS[bank] + mv.image_byte_offset(base, bank)
        end = start + len(data)
        if not 0 <= start < end <= mv.VIDEO_SIZE:
            raise ValueError(f'{name}: payload outside video ROM')
        if any(start < e and end > s for s,e,*_ in spans):
            raise ValueError(f'{name}: overlapping active payloads')
        rom[start:start + len(data)] = data
        spans.append((start, start + len(data), name, bank))
    spans.sort()
    return rom, spans


def decode(rom, w, h, sag, ctrl, end):
    """Indexed pixels for one record, or None if the header does not decode."""
    bpp = (ctrl >> 12) & 7 or 8
    lm, tm = (ctrl >> 8) & 3, (ctrl >> 10) & 3
    comp = bool(ctrl & 0x80)
    pos = sag
    pixels = bytearray(w * h)

    def read(at, n):
        j, shift = divmod(at, 8)
        return ((rom[j] | rom[j + 1] << 8) >> shift) & ((1 << n) - 1)

    for y in range(h):
        if comp:
            if pos + 8 > end:
                return None
            hdr = read(pos, 8)
            pos += 8
            lead, trail = (hdr & 15) << lm, (hdr >> 4) << tm
        else:
            lead = trail = 0
        count = w - lead - trail
        if count < 0 or pos + count * bpp > end:
            return None
        for x in range(lead, w - trail):
            pixels[y * w + x] = read(pos, bpp)
            pos += bpp
    return pixels


def live_lod_tables():
    """Table names an `ASM>` line in a LOD that IMGBUILD.BAT still runs writes."""
    bat = ROOT / "data/IMGBUILD.BAT"
    if not bat.exists():
        return None
    tables = set()
    for name in re.findall(r"load2\s+(\w+)", bat.read_text(errors="ignore"), re.I):
        lod = ROOT / "data" / (name + ".LOD")
        if lod.exists():
            tables.update(t.upper() for t in re.findall(r"^ASM>\s*(\S+)", lod.read_text(errors="ignore"), re.M))
    return tables


def load2_emitted():
    """Record labels the CURRENT LOAD2 pass wrote, per table file.

    LOAD2 never deletes a table file, so tmp/load2 keeps every table a retired
    LOD section once wrote (MKVOGEL.TBL, MKRDWALK.TBL after 2026-09-09).  Only
    tables a live LOD still writes count, or retired art reads as packed.
    """
    emitted = defaultdict(set)
    tmp = ROOT / "tmp/load2"
    if not tmp.is_dir():
        return emitted
    live = live_lod_tables()
    for path in sorted(tmp.glob("*.TBL")):
        if live is not None and path.name.upper() not in live:
            continue
        for line in path.read_text(errors="ignore").splitlines():
            m = re.match(r"^(\w+):\s*$", line)
            if m:
                emitted[path.name.upper()].add(m.group(1))
    return emitted


def referenced_labels():
    """Every identifier mentioned by hand-written source, so 'used' is honest.

    Include TBL operands as potential references, but not their label
    definitions. Generated tables may also hold pointer lists or aliases.
    This remains a conservative identifier scan, not a reachability proof.
    """
    used = set()
    for pattern in ("*.ASM", "*.GLO", "*.HDR"):
        for path in sorted((ROOT / "src").glob(pattern)):
            used.update(re.findall(r"[A-Za-z_][\w]*",
                                   path.read_text(errors="ignore")))
    for path in sorted((ROOT / "src").glob("*.TBL")):
        for line in path.read_text(errors="ignore").splitlines():
            line = line.split(';', 1)[0]
            line = re.sub(r'^\s*[A-Za-z_]\w*\s*:', '', line)
            used.update(re.findall(r'[A-Za-z_]\w*', line))
    return used


def snapshot():
    mv = _module("mv", ROOT / "makevrom.py")
    bpp = _module("bppaudit", ROOT / "tools/audit_sprite_bpp.py")
    rom, spans = flat_rom(mv)
    starts = [s[0] for s in spans]
    emitted, used = load2_emitted(), referenced_labels()

    def owner(sag):
        i = bisect.bisect_right(starts, sag // 8) - 1
        return spans[i] if i >= 0 and sag < spans[i][1] * 8 else None

    records = {}
    collisions = defaultdict(set)
    for fname, label, w, h, sag, ctrl in bpp.parse_tbls(str(ROOT / "src")):
        key = "%s:%s" % (fname, label)
        collisions[key].add((w, h, sag, ctrl))
        span = owner(sag)
        entry = dict(file=fname, label=label, width=w, height=h,
                     bpp=(ctrl >> 12) & 7 or 8,
                     irw=span[2] if span else None, sag="0x%08x" % sag,
                     load2=label in emitted.get(fname.upper(), ()),
                     used=label in used)
        px = None
        if span and 0 < w <= 1023 and 0 < h <= 1023:
            px = decode(rom, w, h, sag, ctrl, span[1] * 8)
        entry["pixels"] = hashlib.sha256(px).hexdigest() if px is not None else None
        records[key] = entry
    duplicated = sorted(k for k, v in collisions.items() if len(v) > 1)
    return dict(records=records, duplicate_labels=duplicated,
                irw_count=len(spans),
                undecodable=sum(1 for r in records.values()
                                if r["pixels"] is None))


FIELDS = ("width", "height", "bpp", "irw", "sag", "pixels", "load2", "used")


def compare(now, was, strict):
    old, new = was["records"], now["records"]
    changed, stale, moved = [], [], 0
    for key in sorted(set(old) & set(new)):
        a, b = old[key], new[key]
        if a["pixels"] != b["pixels"] or (a["width"], a["height"]) != (b["width"], b["height"]):
            entry = dict(record=key,
                         before={k: a.get(k) for k in FIELDS},
                         after={k: b.get(k) for k in FIELDS})
            # Neither emitted by LOAD2 nor mentioned by hand-written source:
            # a candidate stale header. This identifier heuristic is not
            # proof that computed-address consumers cannot reach it.
            (stale if not b.get("load2") and not b.get("used")
             else changed).append(entry)
        elif a["sag"] != b["sag"]:
            moved += 1
    # A leftover header can also stop decoding entirely, when the run it points
    # into shrinks out from under it. Same class as STALE, same verdict.
    became = sorted(k for k in set(old) & set(new)
                    if old[k]["pixels"] is not None and new[k]["pixels"] is None
                    and (new[k].get("load2") or new[k].get("used")))
    became_stale = sorted(k for k in set(old) & set(new)
                          if old[k]["pixels"] is not None and new[k]["pixels"] is None
                          and not new[k].get("load2") and not new[k].get("used"))
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    print("records %d (was %d); %d moved with identical pixels; "
          "%d added, %d removed; %d stale-unreferenced; %d CHANGED"
          % (len(new), len(old), moved, len(added), len(removed),
             len(stale) + len(became_stale), len(changed)))
    for name, items in (("ADDED", added), ("REMOVED", removed),
                        ("NOW UNDECODABLE", became),
                        ("STALE UNDECODABLE", became_stale)):
        for k in items[:40]:
            print("  %s  %s" % (name, k))
        if len(items) > 40:
            print("  %s  (+%d more)" % (name, len(items) - 40))
    for label, group in (("STALE", stale[:12]), ("CHANGED", changed[:40])):
        for c in group:
            print("  %s %s: %s %s -> %s %s  (load2=%s used=%s)"
                  % (label, c["record"], c["before"]["irw"], c["before"]["sag"],
                     c["after"]["irw"], c["after"]["sag"],
                     c["after"]["load2"], c["after"]["used"]))
        if label == "STALE" and len(stale) > 12:
            print("  STALE (+%d more)" % (len(stale) - 12))
    bad = bool(changed) or bool(became)
    if strict:
        bad = bad or bool(added) or bool(removed) or bool(stale)
    print("ART IDENTITY " + ("FAILED" if bad else "OK"))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", type=Path, help="write a fingerprint file")
    ap.add_argument("--compare", type=Path, help="compare against one")
    ap.add_argument("--strict", action="store_true",
                    help="also fail on added/removed records")
    args = ap.parse_args()

    now = snapshot()
    if args.compare:
        return compare(now, json.loads(args.compare.read_text()), args.strict)
    if args.write:
        args.write.parent.mkdir(parents=True, exist_ok=True)
        args.write.write_text(json.dumps(now, indent=1) + "\n", encoding="utf-8")
        print("wrote %s: %d records, %d undecodable, %d labels with conflicting headers"
              % (args.write, len(now["records"]), now["undecodable"],
                 len(now["duplicate_labels"])))
        return 0
    print("%d records across %d IRWs; %d undecodable"
          % (len(now["records"]), now["irw_count"], now["undecodable"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
