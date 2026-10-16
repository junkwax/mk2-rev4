#!/usr/bin/env python3
"""Intersect guarded inline art windows with an art-audit receipt.

Works even when an inline header cannot decode. These are the conservative
raw-bit windows protected by sync_inline_sags, not exact DMA read extents.
No ROM, guard hash or source file is modified.
"""
import argparse
import json
import subprocess
from pathlib import Path

import sync_inline_sags as inline

ROOT = Path(__file__).resolve().parents[1]


def dependencies(records, sources):
    findings = []
    seen = set()
    for filename, text in sources.items():
        for match in inline.RECORD.finditer(text):
            label = match['label']
            if label not in inline.SITES or inline.SITES[label][0] != filename:
                continue
            seen.add(label)
            start = int(match['sag'], 16)
            bpp = (int(match['ctrl'], 16) >> 12) & 7 or 8
            end = start + int(match['w']) * int(match['h']) * bpp
            overlaps = []
            for record in records:
                lo = record['sag_bits']
                hi = lo + record['payload_bits']
                overlap = min(end, hi) - max(start, lo)
                if overlap > 0:
                    overlaps.append(dict(label=record['label'], overlap_bits=overlap,
                                         source_references=record.get('references', [])))
            if overlaps:
                findings.append(dict(inline_label=label, file=filename,
                                     start_bits=start, protected_window_bits=end-start,
                                     overlaps=overlaps))
    missing = sorted(set(inline.SITES) - seen)
    if missing:
        raise ValueError('Missing guarded inline headers: ' + ', '.join(missing))
    return findings


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--audit', type=Path, required=True, help='ROTATE audit receipt matching the source revision')
    ap.add_argument('--source-ref', help='git revision containing matching inline headers; otherwise current files')
    ap.add_argument('--json', type=Path, required=True)
    args = ap.parse_args()
    audit = json.loads(args.audit.read_text())
    sources = {}
    for filename in sorted({site[0] for site in inline.SITES.values()}):
        if args.source_ref:
            sources[filename] = subprocess.check_output(
                ['git', 'show', f'{args.source_ref}:src/{filename}'], cwd=ROOT).decode('latin-1')
        else:
            sources[filename] = (ROOT/'src'/filename).read_text(encoding='latin-1')
    findings = dependencies(audit['details'], sources)
    blocked = sorted({r['label'] for f in findings for r in f['overlaps'] if not r['source_references']})
    result = dict(source_ref=args.source_ref or 'working-tree', audit=str(args.audit),
                  findings=findings, no_identifier_candidates_with_inline_dependencies=blocked,
                  scope='Known sync_inline_sags raw-bit guard windows only; not exact DMA spans or a complete reachability proof')
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(f'{len(findings)} guarded inline windows overlap recorded art; '
          f'{len(blocked)} no-identifier candidates have protected-window dependencies: {", ".join(blocked)}')


if __name__ == '__main__':
    main()
