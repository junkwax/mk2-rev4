#!/usr/bin/env python3
"""Keep Armory in MK7MIL and repair its first compressed control bit."""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:;.*)?$")
SAG_RE = re.compile(r"^\s*\.long\s+0([0-9A-Fa-f]+)H(?:\s*;.*)?$")
ARMORY_LABELS = {
    "ry1HDRS",
    "ARM3BLKS",
    "ARM2BLKS",
    "ARM1BLKS",
    "ARM3BMOD",
    "ARM2BMOD",
    "ARM1BMOD",
}

MK7_IRW = "MK7MIL.IRW"
MK7_RAW_BASE = 0x03000000
IRW_HEADER_SIZE = 68
IRW_BASE_OFF = 44
IRW_SIZE_OFF = 48
IRW_CHECKSUM_OFF = 52
IRW_BANK_OFF = 60
BANK1_FLAT_BASE = 0x800000
BANK1_SAG_START = 0x04000000
EXPECTED_FIRST_BIT = 0


def parse_records(path: Path) -> tuple[list[str], list[tuple[str, list[str]]], list[str]]:
    raw = path.read_text(encoding="latin-1", errors="replace").split("\n")
    header: list[str] = []
    records: list[tuple[str, list[str]]] = []
    footer: list[str] = []
    current_label: str | None = None
    current_body: list[str] = []
    in_footer = False

    for line in raw:
        if in_footer:
            footer.append(line)
            continue
        if current_label is not None and re.match(r"^\s*\.include\b", line, re.IGNORECASE):
            records.append((current_label, current_body))
            current_label, current_body = None, []
            footer.append(line)
            in_footer = True
            continue
        if re.match(r"^\s*\.(?:TEXT|END)\b", line, re.IGNORECASE):
            if current_label is not None:
                records.append((current_label, current_body))
                current_label, current_body = None, []
            footer.append(line)
            in_footer = True
            continue

        match = LABEL_RE.match(line)
        if match:
            if current_label is not None:
                records.append((current_label, current_body))
            current_label = match.group(1)
            current_body = [line]
        elif current_label is None:
            header.append(line)
        else:
            current_body.append(line)

    if current_label is not None:
        records.append((current_label, current_body))
    return header, records, footer


def trim_body(lines: list[str]) -> list[str]:
    out = list(lines)
    while out and out[-1] == "":
        out.pop()
    return out


def extract_sags(body: list[str]) -> list[int]:
    values = []
    for line in body:
        match = SAG_RE.match(line)
        if match:
            values.append(int(match.group(1), 16))
    return values


def sag_to_flat_byte(sag: int) -> int:
    if sag < BANK1_SAG_START:
        raise ValueError(f"SAG 0x{sag:08X} is not in video bank 1")
    return BANK1_FLAT_BASE + (sag - BANK1_SAG_START) // 8


def payload_checksum(payload: bytes) -> int:
    total = 0
    even_length = len(payload) - (len(payload) % 2)
    for offset in range(0, even_length, 2):
        total = (total + struct.unpack_from("<H", payload, offset)[0]) & 0xFFFFFFFF
    if len(payload) % 2:
        total = (total + payload[-1]) & 0xFFFFFFFF
    return total


def repair_mk7_bit(repo: Path, first_sag: int, apply: bool) -> bool:
    path = repo / "data" / MK7_IRW
    data = bytearray(path.read_bytes())
    if len(data) < IRW_HEADER_SIZE:
        raise ValueError(f"{path} is shorter than the IRW header")

    declared_size = struct.unpack_from("<I", data, IRW_SIZE_OFF)[0]
    base = struct.unpack_from("<I", data, IRW_BASE_OFF)[0]
    bank = struct.unpack_from("<I", data, IRW_BANK_OFF)[0]
    if declared_size == 0:
        base = MK7_RAW_BASE
        payload_size = len(data) - IRW_HEADER_SIZE
    else:
        payload_size = declared_size
    if bank not in (0, 1):
        bank = 1
    if IRW_HEADER_SIZE + payload_size > len(data):
        raise ValueError(f"{path} declares a truncated payload")

    flat_start = (BANK1_FLAT_BASE if bank == 1 else 0) + (base - 0x02000000) // 8
    first_flat = sag_to_flat_byte(first_sag)
    payload_offset = first_flat - flat_start
    if payload_offset < 0 or payload_offset >= payload_size:
        raise ValueError(
            f"ry1HDRS[0] flat byte 0x{first_flat:06X} is outside {path.name}"
        )

    bit_index = first_sag & 0x7
    mask = 1 << bit_index
    file_offset = IRW_HEADER_SIZE + payload_offset
    dirty = bool(data[file_offset] & mask) != bool(EXPECTED_FIRST_BIT)
    print(
        f"Armory ry1HDRS[0]: SAG=0x{first_sag:08X} "
        f"flat=0x{first_flat:06X} bit={bit_index} "
        f"status={'needs repair' if dirty else 'clean'}"
    )

    if apply and dirty:
        if EXPECTED_FIRST_BIT:
            data[file_offset] |= mask
        else:
            data[file_offset] &= ~mask
        if declared_size:
            payload = bytes(data[IRW_HEADER_SIZE:IRW_HEADER_SIZE + payload_size])
            struct.pack_into("<I", data, IRW_CHECKSUM_OFF, payload_checksum(payload))
        path.write_bytes(data)
        print(f"Repaired Armory first bit in {path}")
    return dirty


def remove_stale_outputs(repo: Path) -> None:
    for name in ("BGND.OBJ", "BGND.LST", "BGNDTBL.OBJ", "BGNDTBL.LST", "mk2.out"):
        path = repo / "src" / name
        if path.exists():
            path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="repair MK7 and sync Armory records")
    parser.add_argument("--check", action="store_true", help="exit 1 if the repair is not applied")
    parser.add_argument("--verbose", action="store_true", help="list changed table labels")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    src_path = repo / "src" / "BGNDTBL.ASM"
    snapshot_path = repo / "tmp" / "load2" / "BGNDTBL.MK7"
    if not src_path.exists() or not snapshot_path.exists():
        print("error: run LOAD2 MK7MIL before repairing Armory", file=sys.stderr)
        return 2

    header, src_records, footer = parse_records(src_path)
    _snapshot_header, snapshot_records, _snapshot_footer = parse_records(snapshot_path)
    src_by_label = {label: body for label, body in src_records}
    snapshot_by_label = {label: body for label, body in snapshot_records}
    missing = sorted(
        label for label in ARMORY_LABELS
        if label not in src_by_label or label not in snapshot_by_label
    )
    if missing:
        print(f"error: missing Armory labels: {', '.join(missing)}", file=sys.stderr)
        return 2

    first_sags = extract_sags(snapshot_by_label["ry1HDRS"])
    if not first_sags:
        print("error: generated ry1HDRS has no SAG records", file=sys.stderr)
        return 2

    changed = sorted(
        label for label in ARMORY_LABELS
        if trim_body(src_by_label[label]) != trim_body(snapshot_by_label[label])
    )
    print(f"Armory normal-MK7 records aligned: {len(ARMORY_LABELS) - len(changed)}")
    print(f"Armory normal-MK7 records changed: {len(changed)}")
    if args.verbose:
        for label in changed:
            print(f"  - {label}")

    try:
        bit_dirty = repair_mk7_bit(repo, first_sags[0], args.apply)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.check:
        return 1 if changed or bit_dirty else 0
    if not args.apply:
        if changed or bit_dirty:
            print("Run with --apply to restore normal MK7 Armory records and repair the bit.")
        return 0

    if changed:
        out_lines = list(header)
        for label, body in src_records:
            out_lines.extend(snapshot_by_label.get(label, body))
        out_lines.extend(footer)
        old_text = src_path.read_text(encoding="latin-1", errors="replace")
        new_text = "\n".join(out_lines)
        if old_text.endswith("\n") and not new_text.endswith("\n"):
            new_text += "\n"
        if new_text != old_text:
            src_path.write_text(new_text, encoding="latin-1", errors="replace")
            remove_stale_outputs(repo)
            print(f"Restored {len(changed)} Armory record group(s) to normal MK7 locations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
