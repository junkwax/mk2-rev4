#!/usr/bin/env python3
"""Refresh src/MK1PITBG.ASM from LOAD2 MK1PIT output.

LOAD2 emits the BLKS records in BDB/depth order. MK2's background scanner
expects each BMOD block table to be sorted by X because it binary-searches the
first visible X and stops when block X exceeds the right edge. For MK1PIT that
means an unsorted table only renders the first few wall strips.

This helper combines tmp/load2/BGNDPAL.ASM and tmp/load2/BGNDTBL.MK7, then sorts
MK1PITBLKS by X for the runtime source include. It also emits split background
and foreground BMODs so the single front spike art can be drawn after objlst
without pulling the floor strip in front of fighters.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


WORD_RE = re.compile(r"\.word\s+(.+)$", re.IGNORECASE)


def asm_int(token: str) -> int:
    token = token.strip().rstrip(",")
    if token.lower().startswith("0x"):
        return int(token, 16)
    if token.upper().endswith("H"):
        return int(token[:-1], 16)
    if re.search(r"[A-Fa-f]", token):
        return int(token, 16)
    return int(token, 10)


def word_values(line: str) -> list[int]:
    line = line.split(";", 1)[0]
    match = WORD_RE.search(line)
    if not match:
        return []
    return [asm_int(part) for part in match.group(1).split(",") if part.strip()]


def strip_load2_preamble(path: Path) -> str:
    lines = path.read_text(encoding="ascii", errors="replace").splitlines()
    return "\n".join(lines[3:])


def parse_blks_records(body: str, label: str = "MK1PITBLKS") -> list[list[int]]:
    values: list[int] = []
    saw_end = False
    for line in body.splitlines():
        vals = word_values(line)
        if vals and vals[0] == 0xFFFF:
            saw_end = True
            break
        values.extend(vals)
    if not saw_end:
        raise ValueError(f"{label} section has no 0FFFFH end marker")
    if len(values) % 4:
        raise ValueError(f"{label} has {len(values)} words, not divisible by 4")
    return [values[i:i + 4] for i in range(0, len(values), 4)]


def sort_records_x_major(records: list[list[int]]) -> list[list[int]]:
    return [record for _old_index, record in sorted(enumerate(records), key=lambda item: (item[1][1], item[0]))]


def sorted_MK1PIT_records(body: str) -> list[list[int]]:
    return sort_records_x_major(parse_blks_records(body))


def palette_index(record: list[int]) -> int:
    flags, _x, _y, hdr = record
    return (flags & 0x000F) | (((hdr >> 12) & 0x000F) << 4)


def layer_index(record: list[int]) -> int:
    flags, _x, _y, _hdr = record
    return (flags >> 8) & 0xFF


def set_hflip(record: list[int], enabled: bool) -> list[int]:
    out = record.copy()
    if enabled:
        out[0] |= 0x0010
    else:
        out[0] &= ~0x0010
    return out


def mirror_alternating_front_spikes(records: list[list[int]]) -> list[list[int]]:
    """Alternate hflip on the repeated 168x94 front spike panels."""
    out: list[list[int]] = []
    spike_panel_index = 0
    for record in records:
        layer = layer_index(record)
        _flags, _x, _y, hdr = record
        if layer == 0x40 and palette_index(record) == 11 and (hdr & 0x0FFF) == 3:
            out.append(set_hflip(record, (spike_panel_index & 1) == 0))
            spike_panel_index += 1
        else:
            out.append(record)
    return out


def is_MK1PIT_single_spike(record: list[int]) -> bool:
    _flags, _x, _y, hdr = record
    return layer_index(record) == 0x42 and palette_index(record) == 11 and (hdr & 0x0FFF) == 0x27


MK1PIT_BOTTOM_SPIKE_Y = 265
MK1PIT_GORE_FOREGROUND_Y_SHIFT = 265
MK1PIT_MIN_BMOD_HEIGHT = 375


def set_layer(record: list[int], layer: int) -> list[int]:
    out = record.copy()
    out[0] = (out[0] & 0x00FF) | ((layer & 0xFF) << 8)
    return out


def is_MK1PIT_top_spike_row(record: list[int]) -> bool:
    _flags, _x, y, hdr = record
    return layer_index(record) == 0x42 and palette_index(record) == 6 and (hdr & 0x0FFF) == 0x02 and y == 0


def tune_MK1PIT_runtime_layout(records: list[list[int]]) -> list[list[int]]:
    """Move the source top spike row to the bottom; keep mirrored end caps, drop overshoot copies."""
    out: list[list[int]] = []
    for record in records:
        if is_MK1PIT_top_spike_row(record):
            moved = record.copy()
            if not (50 <= moved[1] <= 1039):
                continue
            moved = set_layer(moved, 0x43)
            moved[2] = MK1PIT_BOTTOM_SPIKE_Y
            if moved[1] == 50:
                moved = set_hflip(moved, False)
            out.append(moved)
        elif layer_index(record) == 0x43:
            moved = record.copy()
            moved[2] += MK1PIT_GORE_FOREGROUND_Y_SHIFT
            out.append(moved)
        else:
            out.append(record)
    return out


def mirror_alternating_single_spikes(records: list[list[int]]) -> list[list[int]]:
    """Alternate hflip by X group for the stacked 4x16 foreground spike sprite."""
    out: list[list[int]] = []
    spike_group_index = 0
    last_spike_x: int | None = None
    for record in records:
        if is_MK1PIT_single_spike(record):
            x = record[1]
            if x != last_spike_x:
                last_spike_x = x
                spike_group_index += 1
            out.append(set_hflip(record, (spike_group_index & 1) == 0))
        else:
            out.append(record)
    return out


def is_MK1PIT_foreground(record: list[int]) -> bool:
    _flags, _x, _y, _hdr = record
    layer = layer_index(record)
    return is_MK1PIT_single_spike(record) or layer == 0x43


def is_MK1PIT_bottom_spike_runtime(record: list[int]) -> bool:
    _flags, _x, y, hdr = record
    return layer_index(record) == 0x43 and palette_index(record) == 6 and (hdr & 0x0FFF) == 0x02 and y == MK1PIT_BOTTOM_SPIKE_Y


def blks_section(label: str, records: list[list[int]], comment: str | None = None) -> str:
    out = [f"{label}:"]
    if comment:
        out.append(f"\t; {comment}")
    for flags, x, y, hdr in records:
        out.append(f"\t.word\t0{flags:04X}H,{x},{y},0{hdr:04X}H")
    out.append("\t.word\t0FFFFH\t;End Marker")
    return "\n".join(out)


def bmod_section(
    label: str,
    width: int,
    height: int,
    block_label: str,
    count: int,
    hdr_label: str = "TPLHDRS",
    pal_label: str = "TPLPALS",
) -> str:
    return "\n".join(
        [
            f"{label}:",
            f"\t.word\t{width},{height},{count}\t;x size, y size, #blocks",
            f"\t.long\t{block_label}, {hdr_label}, {pal_label}",
        ]
    )


LABEL_RE = re.compile(r"(?m)^([A-Za-z_][A-Za-z0-9_]*):\s*$")
BMOD_LONG_RE = re.compile(
    r"\.long\s+([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)",
    re.IGNORECASE,
)


def label_section(table_body: str, label: str) -> tuple[str, int, int]:
    start_match = re.search(rf"(?m)^{re.escape(label)}:\s*$", table_body)
    if not start_match:
        raise ValueError(f"could not find {label} section")
    next_match = LABEL_RE.search(table_body, start_match.end())
    end = next_match.start() if next_match else len(table_body)
    return table_body[start_match.end():end], start_match.start(), end


def generated_load2_modules(table_body: str) -> list[dict[str, object]]:
    modules: list[dict[str, object]] = []
    for bmod_match in re.finditer(r"(?m)^([A-Za-z_][A-Za-z0-9_]*BMOD):\s*$", table_body):
        bmod_label = bmod_match.group(1)
        if bmod_label.startswith("MK1PIT"):
            continue
        bmod_body, bmod_start, bmod_end = label_section(table_body, bmod_label)
        long_match = BMOD_LONG_RE.search(bmod_body)
        if not long_match:
            continue
        blks_label = long_match.group(1)
        hdr_label = long_match.group(2)
        pal_label = long_match.group(3)
        if blks_label.startswith("MK1PIT"):
            continue
        blks_body, blks_start, blks_end = label_section(table_body, blks_label)
        bmod_words: list[int] = []
        for line in bmod_body.splitlines():
            bmod_words = word_values(line)
            if bmod_words:
                break
        if len(bmod_words) < 3:
            raise ValueError(f"{bmod_label} should contain width,height,block count")
        width, height, count = bmod_words[:3]
        records = parse_blks_records(blks_body, blks_label)
        if count != len(records):
            raise ValueError(f"{bmod_label} count {count} != {blks_label} record count {len(records)}")
        modules.append(
            {
                "bmod_label": bmod_label,
                "blks_label": blks_label,
                "records": records,
                "width": width,
                "height": height,
                "hdr_label": hdr_label,
                "pal_label": pal_label,
                "start": min(blks_start, bmod_start),
                "end": max(blks_end, bmod_end),
            }
        )
    return sorted(modules, key=lambda module: int(module["start"]))


def renamed_label_section(table_body: str, source_label: str, output_label: str) -> str:
    section, _start, _end = label_section(table_body, source_label)
    return f"{output_label}:{section.rstrip()}\n\n"


def MK1PIT_records_and_bounds(table_body: str) -> tuple[list[list[int]], int, int, str, str, str]:
    match = re.search(r"(?ms)^MK1PITBLKS:\n(.*?)^MK1PITBMOD:\n(.*)$", table_body)
    if match:
        bmod_words: list[int] = []
        hdr_label = "TPLHDRS"
        pal_label = "TPLPALS"
        for line in match.group(2).splitlines():
            long_match = BMOD_LONG_RE.search(line)
            if long_match:
                hdr_label = long_match.group(2)
                pal_label = long_match.group(3)
            bmod_words = word_values(line)
            if bmod_words:
                break
        if len(bmod_words) < 3:
            raise ValueError("MK1PITBMOD should contain width,height,block count")
        width, height, _count = bmod_words[:3]
        return parse_blks_records(match.group(1), "MK1PITBLKS"), width, height, table_body[:match.start()], hdr_label, pal_label

    modules = generated_load2_modules(table_body)
    if not modules:
        raise ValueError("could not find MK1PITBLKS/MK1PITBMOD or LOAD2 module BLKS/BMOD sections")

    # MK1PIT is the final BBB> entry in MK7MIL.LOD. Current LOAD2 output names
    # those chunks bridge0/bridge1 and pairs them with ITHDRS/ITPALS, so use the
    # trailing header/palette group instead of assuming stable MK1PIT labels.
    last_hdr = modules[-1]["hdr_label"]
    last_pal = modules[-1]["pal_label"]
    tail_modules: list[dict[str, object]] = []
    for module in reversed(modules):
        if module["hdr_label"] != last_hdr or module["pal_label"] != last_pal:
            break
        tail_modules.append(module)
    modules = list(reversed(tail_modules))

    records: list[list[int]] = []
    width = 0
    height = 0
    for module in modules:
        records.extend(module["records"])  # type: ignore[arg-type]
        width = max(width, int(module["width"]))
        height = max(height, int(module["height"]))
    prefix = renamed_label_section(table_body, str(last_hdr), "TPLHDRS")
    return records, width, height, prefix, "TPLHDRS", "TPLPALS"


def sort_MK1PIT_blocks(table_body: str) -> str:
    records, width, height, prefix, hdr_label, pal_label = MK1PIT_records_and_bounds(table_body)
    height = max(height, MK1PIT_MIN_BMOD_HEIGHT)
    sorted_records = sort_records_x_major(tune_MK1PIT_runtime_layout(mirror_alternating_single_spikes(mirror_alternating_front_spikes(sort_records_x_major(records)))))

    foreground = [record for record in sorted_records if is_MK1PIT_foreground(record)]
    background = [record for record in sorted_records if not is_MK1PIT_foreground(record)]
    foreground_spikes = [record for record in foreground if is_MK1PIT_bottom_spike_runtime(record)]
    foreground_overlay = [record for record in foreground if not is_MK1PIT_bottom_spike_runtime(record)]

    sections = [
        blks_section("MK1PITBLKS", sorted_records, "full sorted reference table"),
        bmod_section("MK1PITBMOD", width, height, "MK1PITBLKS", len(sorted_records), hdr_label, pal_label),
        "",
        blks_section("MK1PITBGBLKS", background, "runtime back/mid art, drawn before objlst"),
        bmod_section("MK1PITBGBMOD", width, height, "MK1PITBGBLKS", len(background), hdr_label, pal_label),
        "",
        blks_section("MK1PITFGBLKS", foreground, "runtime foreground reference table, sorted by X"),
        bmod_section("MK1PITFGBMOD", width, height, "MK1PITFGBLKS", len(foreground), hdr_label, pal_label),
        "",
        blks_section("MK1PITFSBLKS", foreground_spikes, "runtime bottom spike row, drawn before gore overlay"),
        bmod_section("MK1PITFSBMOD", width, height, "MK1PITFSBLKS", len(foreground_spikes), hdr_label, pal_label),
        "",
        blks_section("MK1PITGOREBLKS", foreground_overlay, "runtime gore/cutout overlay, drawn after spike row"),
        bmod_section("MK1PITGOREBMOD", width, height, "MK1PITGOREBLKS", len(foreground_overlay), hdr_label, pal_label),
    ]
    return prefix + "\n".join(sections)


def build_MK1PITBG_text(root: Path) -> str:
    tbl_path = root / "tmp" / "load2" / "BGNDTBL.MK7"
    if not tbl_path.exists():
        tbl_path = root / "tmp" / "load2" / "BGNDTBL.ASM"
    if not tbl_path.exists():
        raise FileNotFoundError("missing tmp/load2/BGNDTBL.MK7")

    tbl = sort_MK1PIT_blocks(strip_load2_preamble(tbl_path).strip())
    return "\n".join(
        [
            "; MK1PIT generated -- do not hand-edit.",
            "; Regenerate with: python tools\\refresh_MK1PITBG.py",
            "; Palette labels live in src\\BGNDPAL.ASM; this include emits table data only.",
            "; MK1PITBLKS and runtime split BLKS tables are sorted by X for MK2's background scanner.",
            "; Runtime foreground is split into spike-row and gore overlay modules for draw order.",
            "",
            "\t.globl\tMK1PITBGBLKS",
            "\t.globl\tMK1PITBGBMOD",
            "\t.globl\tMK1PITFGBLKS",
            "\t.globl\tMK1PITFGBMOD",
            "\t.globl\tMK1PITFSBLKS",
            "\t.globl\tMK1PITFSBMOD",
            "\t.globl\tMK1PITGOREBLKS",
            "\t.globl\tMK1PITGOREBMOD",
            "",
            tbl,
            "",
        ]
    )


def body_from_first_label(text: str) -> str:
    match = re.search(r"(?m)^[A-Za-z_][A-Za-z0-9_]*:\s*", text)
    return text[match.start():].strip() if match else text.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh src/MK1PITBG.ASM from tmp/load2 output")
    parser.add_argument("--mk2-root", type=Path, default=Path.cwd())
    parser.add_argument("--check", action="store_true", help="Only check whether src/MK1PITBG.ASM is current")
    args = parser.parse_args()

    root = args.mk2_root.resolve()
    out_path = root / "src" / "MK1PITBG.ASM"
    generated = build_MK1PITBG_text(root)

    if args.check:
        current = out_path.read_text(encoding="ascii", errors="replace") if out_path.exists() else ""
        if body_from_first_label(current) != body_from_first_label(generated):
            print("src/MK1PITBG.ASM is stale or not X-sorted", file=sys.stderr)
            return 1
        print("src/MK1PITBG.ASM is current")
        return 0

    out_path.write_text(generated, encoding="ascii", newline="\n")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())






