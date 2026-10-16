#!/usr/bin/env python3
"""Report source SAG references that overlap the live KFPITPL video payload."""
from __future__ import annotations

import argparse
import re
import struct
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


IRW_HEADER_SIZE = 68
IRW_BASE_OFF = 44
IRW_SIZE_OFF = 48
IRW_BANK_OFF = 60

IROM_BASE = 0x02000000
BANK_SIZE_BITS = 0x02000000
BANK1_FLAT = 0x800000

SOURCE_EXTS = {".ASM", ".TBL", ".GLO"}


@dataclass(frozen=True)
class Ref:
    path: Path
    line_no: int
    label: str
    sag: int
    flat: int
    text: str


def read_irw_range(path: Path) -> tuple[int, int, int, int, int]:
    data = path.read_bytes()
    if len(data) < IRW_HEADER_SIZE:
        raise ValueError(f"{path} is shorter than the IRW header")
    base = struct.unpack_from("<I", data, IRW_BASE_OFF)[0]
    size = struct.unpack_from("<I", data, IRW_SIZE_OFF)[0]
    bank = struct.unpack_from("<I", data, IRW_BANK_OFF)[0]
    if len(data) < IRW_HEADER_SIZE + size:
        raise ValueError(f"{path} payload is truncated: header says {size} bytes")
    sag = base + (BANK_SIZE_BITS * bank)
    flat = sag_to_flat(sag)
    if flat is None:
        raise ValueError(f"{path} SAG 0x{sag:08x} is not in video ROM space")
    return sag, flat, flat + size, size, bank


def sag_to_flat(sag: int) -> int | None:
    if 0x02000000 <= sag < 0x04000000:
        return (sag - IROM_BASE) // 8
    if 0x04000000 <= sag < 0x08000000:
        return BANK1_FLAT + ((sag - 0x04000000) // 8)
    return None


def parse_asm_int(token: str) -> int | None:
    token = token.strip().rstrip(",")
    token = token.split(";", 1)[0].strip()
    if not token:
        return None
    try:
        if token.lower().startswith("0x"):
            return int(token, 16)
        if token.upper().endswith("H"):
            return int(token[:-1], 16)
        if re.fullmatch(r"[0-9A-Fa-f]{7,8}", token):
            return int(token, 16)
    except ValueError:
        return None
    return None


def long_tokens(line: str) -> list[str]:
    line = line.split(";", 1)[0]
    match = re.search(r"\.long\s+(.+)$", line, re.IGNORECASE)
    if not match:
        return []
    return [part.strip() for part in match.group(1).split(",") if part.strip()]


def scan_refs(root: Path) -> list[Ref]:
    refs: list[Ref] = []
    label = ""
    for path in sorted((root / "src").rglob("*")):
        if path.suffix.upper() not in SOURCE_EXTS:
            continue
        rel = path.relative_to(root)
        text = path.read_text(encoding="ascii", errors="replace")
        for line_no, line in enumerate(text.splitlines(), 1):
            label_match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
            if label_match:
                label = label_match.group(1)
            for token in long_tokens(line):
                sag = parse_asm_int(token)
                if sag is None:
                    continue
                flat = sag_to_flat(sag)
                if flat is None:
                    continue
                refs.append(Ref(rel, line_no, label, sag, flat, line.strip()))
    return refs


def is_intended_kfpitpl(ref: Ref) -> bool:
    return ref.path.as_posix().lower() == "src/kfpitbg.asm"


def summarize(refs: list[Ref]) -> list[tuple[str, int, int, int]]:
    groups: dict[str, list[Ref]] = defaultdict(list)
    for ref in refs:
        groups[f"{ref.path}:{ref.label or '(no label)'}"].append(ref)
    rows = []
    for key, group in groups.items():
        rows.append((key, len(group), min(r.flat for r in group), max(r.flat for r in group)))
    return sorted(rows, key=lambda row: (row[2], row[0]))


def print_refs(title: str, refs: list[Ref], root: Path, limit: int) -> None:
    print(title)
    if not refs:
        print("  none")
        return
    for ref in refs[:limit]:
        print(
            f"  {ref.path}:{ref.line_no} {ref.label or '(no label)'} "
            f"SAG=0x{ref.sag:08X} flat=0x{ref.flat:06X} :: {ref.text}"
        )
    if len(refs) > limit:
        print(f"  ... {len(refs) - limit} more")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan source SAG refs against KFPITPL payload bytes")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--irw", type=Path, default=Path("data/KFPITPL.IRW"))
    parser.add_argument("--near", type=lambda value: int(value, 0), default=0x40000)
    parser.add_argument("--limit", type=int, default=24)
    parser.add_argument("--fail-on-conflict", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    irw = args.irw if args.irw.is_absolute() else root / args.irw
    sag, flat_start, flat_end, size, bank = read_irw_range(irw)
    refs = scan_refs(root)

    inside = [ref for ref in refs if flat_start <= ref.flat < flat_end]
    intended = [ref for ref in inside if is_intended_kfpitpl(ref)]
    conflicts = [ref for ref in inside if not is_intended_kfpitpl(ref)]
    near = [
        ref
        for ref in refs
        if flat_start - args.near <= ref.flat < flat_end + args.near and ref not in inside
    ]

    print(
        f"KFPITPL payload: SAG=0x{sag:08X} bank={bank} "
        f"flat=0x{flat_start:06X}..0x{flat_end - 1:06X} size={size:,}"
    )
    print(f"numeric video SAG refs scanned: {len(refs)}")
    print()

    print(f"inside payload: {len(inside)} refs")
    for key, count, first, last in summarize(inside):
        normalized_key = key.replace("\\", "/").lower()
        mark = "intended" if normalized_key.startswith("src/kfpitbg.asm:") else "overlap"
        print(f"  {mark:8} {count:3d} 0x{first:06X}..0x{last:06X} {key}")
    print()

    print_refs("non-KFPITPL refs starting inside payload:", conflicts, root, args.limit)
    print()
    print_refs(f"nearby refs within +/-0x{args.near:X}:", near, root, args.limit)

    if conflicts and args.fail_on_conflict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
