#!/usr/bin/env python3
"""Measure ROTATE chunk art and retain reference evidence; never delete assets.

Identifier absence is a candidate signal, not reachability proof. Prelinked
objects, numeric pointers and computed table access require separate review.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

import art_identity_snapshot as identity
import audit_sprite_bpp as headers
import flip_scale_scan as pixels
import audit_inline_art_dependencies as inline_dependencies

ROOT = Path(__file__).resolve().parents[1]
FAMILY = re.compile(r"ROTATE\d+[A-H]", re.I)


def union_bits(intervals):
    end = total = 0
    for start, stop in sorted(intervals):
        total += max(0, stop - max(start, end))
        end = max(end, stop)
    return total


def source_references(labels):
    refs = {label: [] for label in labels}
    digest = hashlib.sha256()
    for path in sorted((ROOT / "src").iterdir()):
        if path.suffix.upper() not in {".ASM", ".TBL", ".GLO", ".HDR", ".INC"}:
            continue
        raw = path.read_bytes()
        digest.update(path.name.encode() + b"\0" + raw + b"\0")
        for number, line in enumerate(raw.decode("latin-1").splitlines(), 1):
            if line.lstrip().startswith("*"):
                continue
            code = line.split(";", 1)[0]
            # Definitions aren't consumers; preserve any operands after them.
            code = re.sub(r"^\s*[A-Za-z_]\w*:\s*", "", code)
            for token in set(re.findall(r"[A-Za-z_]\w*", code.upper())) & labels:
                refs[token].append(dict(file=path.relative_to(ROOT).as_posix(),
                                        line=number, text=line.strip()))
    return refs, digest.hexdigest()


def audit():
    mv = identity._module("rotate_makevrom", ROOT / "makevrom.py")
    rom, spans = identity.flat_rom(mv)
    all_headers = list(headers.parse_tbls(str(ROOT / "src")))
    selected = [r for r in all_headers if r[0] == "MKCHUNKS.TBL" and FAMILY.fullmatch(r[1])]
    if not selected:
        raise ValueError("No ROTATE records parsed; cannot report an empty pass")
    labels = {r[1].upper() for r in selected}
    refs, source_hash = source_references(labels)
    emitted = identity.load2_emitted()
    records, intervals = [], []
    for file, label, w, h, sag, ctrl in selected:
        span = next((s for s in spans if s[0]*8 <= sag < s[1]*8), None)
        if span is None:
            raise ValueError(f"{label}: no packed payload owner")
        decoded, bits = pixels.decode_bits(rom, w, h, sag, ctrl, span[1]*8)
        if decoded is None or bits <= 0:
            raise ValueError(f"{label}: decode failed")
        intervals.append((sag, sag+bits))
        records.append(dict(label=label, width=w, height=h, sag_bits=sag,
                            payload_bits=bits, irw=span[2],
                            pixel_sha256=hashlib.sha256(decoded).hexdigest(),
                            load2_emitted=label in emitted.get(file.upper(), set()),
                            references=refs[label.upper()]))
    # Look for other headers whose decoded spans overlap candidate pixels.
    # Shared bytes cannot be counted as physically removable for this family.
    owners = {r['irw'] for r in records}
    overlaps = []
    for file, label, w, h, sag, ctrl in all_headers:
        if file == "MKCHUNKS.TBL" and label.upper() in labels:
            continue
        span = next((s for s in spans if s[2] in owners and s[0]*8 <= sag < s[1]*8), None)
        if span is None:
            continue
        if not (0 < w <= 1023 and 0 < h <= 1023):
            continue
        decoded, bits = pixels.decode_bits(rom, w, h, sag, ctrl, span[1]*8)
        if decoded is not None and any(sag < end and sag+bits > start for start,end in intervals):
            overlaps.append(dict(file=file,label=label,sag_bits=sag,payload_bits=bits))
    groups = {}
    for r in records:
        group = re.match(r"ROTATE\d+", r['label']).group()
        groups.setdefault(group, []).append((r['sag_bits'],r['sag_bits']+r['payload_bits']))
    inline_sources = {name:(ROOT/'src'/name).read_text(encoding='latin-1')
                      for name in {site[0] for site in inline_dependencies.inline.SITES.values()}}
    inline_uses = inline_dependencies.dependencies(records, inline_sources)
    protected_labels = {r['label'] for window in inline_uses for r in window['overlaps']}
    return dict(status="candidate_only_reachability_unproven",
                source_sha256=source_hash,
                irw_sha256={name:hashlib.sha256((ROOT/'data'/name).read_bytes()).hexdigest() for name in sorted(owners)},
                records=len(records), unique_payloads=len({s for s,e in intervals}),
                packed_union_bits=union_bits(intervals),
                no_identifier_reference_bits=union_bits([(r['sag_bits'],r['sag_bits']+r['payload_bits'])
                                                         for r in records if not r['references']]),
                referenced_records=sum(bool(r['references']) for r in records),
                other_header_overlaps=overlaps,
                guarded_inline_overlaps=inline_uses,
                no_identifier_candidates_with_inline_dependencies=sorted(
                    r['label'] for r in records if not r['references'] and r['label'] in protected_labels),
                groups={k:union_bits(v) for k,v in groups.items()}, details=records,
                limits=["Conservative source identifier scan, not a linked reachability graph",
                        "Numeric/computed pointers and prelinked ART.OUT/OART.OUT not resolved",
                        "Parsed sprite headers only; unsupported layouts may contain aliases",
                        "Packed bits are a footprint; LOAD2 alignment/reflow determines actual ROM savings"])


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--json',type=Path,required=True)
    args=ap.parse_args()
    result=audit()
    args.json.parent.mkdir(parents=True,exist_ok=True)
    args.json.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(f"{result['records']} records; {result['packed_union_bits']} packed bits "
          f"({result['packed_union_bits']/8:g} bytes); {result['referenced_records']} identifier users; "
          f"{len(result['other_header_overlaps'])} other-header overlaps")
    print('Candidate evidence only; no assets changed.')


if __name__=='__main__':
    main()
