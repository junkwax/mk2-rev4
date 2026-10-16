#!/usr/bin/env python3
"""
Sync image header fields from LOAD2-generated TBL files into src/*.TBL.

Default mode is report-only. Use --apply to patch source tables.

The script matches by label, not by line number, so hand-added labels are
preserved. It can also use a unique label from any tmp/load2/*.TBL as a fallback,
which lets src/MKJC.TBL pick up JC2DEATHBLO* data emitted by JCHRIP.TBL.
"""

from __future__ import annotations

import argparse
import csv
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


LABEL_RE = re.compile(r"^\s*([A-Za-z_.$?][A-Za-z0-9_.$?]*)\s*:")
WORD_RE = re.compile(r"^(\s*)\.word(\s+)(.*?)(\s*(?:;.*)?)$", re.IGNORECASE)
LONG_RE = re.compile(r"^(\s*)\.long(\s+)(.*?)(\s*(?:;.*)?)$", re.IGNORECASE)
NUMERIC_LONG_RE = re.compile(r"^\s*0?[0-9a-fA-F]+H\s*$")


@dataclass(frozen=True)
class WordRef:
    line_index: int
    values: tuple[int, ...]


@dataclass(frozen=True)
class LongRef:
    line_index: int
    value: int


@dataclass(frozen=True)
class HeaderEntry:
    label: str
    table: str
    size_line: int
    size_word_count: int
    sag_line: int
    ctrl_line: int
    ctrl_word_count: int
    sizx: int
    sizy: int
    anix: int
    aniy: int
    sag: int
    ctrl: int
    palette: str | None = None
    palette_line: int | None = None


@dataclass(frozen=True)
class DiffRow:
    src_table: str
    label: str
    load2_table: str | None
    field: str
    old: str
    new: str
    status: str


PRESERVED_PALETTE_REFS = {}


def preserve_palette_ref(entry: HeaderEntry) -> bool:
    return (entry.table.upper(), entry.label.upper()) in PRESERVED_PALETTE_REFS


def split_comment(payload: str) -> tuple[str, str]:
    if ";" not in payload:
        return payload, ""
    before, after = payload.split(";", 1)
    return before, ";" + after


def parse_number(token: str) -> int | None:
    token = token.strip()
    if not token:
        return None
    neg = token.startswith("-")
    body = token[1:] if neg else token
    try:
        if body.upper().endswith("H"):
            value = int(body[:-1], 16)
        else:
            value = int(body, 10)
    except ValueError:
        return None
    return -value if neg else value


def parse_word_values(line: str) -> tuple[int, ...] | None:
    match = WORD_RE.match(line.rstrip("\r\n"))
    if not match:
        return None
    values_text, _comment = split_comment(match.group(3))
    values: list[int] = []
    for raw in values_text.split(","):
        value = parse_number(raw)
        if value is None:
            return None
        values.append(value)
    return tuple(values)


def parse_long_value(line: str) -> int | None:
    match = LONG_RE.match(line.rstrip("\r\n"))
    if not match:
        return None
    value_text, _comment = split_comment(match.group(3))
    value_text = value_text.strip()
    if not NUMERIC_LONG_RE.match(value_text):
        return None
    return parse_number(value_text)


def parse_long_symbol(line: str) -> str | None:
    match = LONG_RE.match(line.rstrip("\r\n"))
    if not match:
        return None
    value_text, _comment = split_comment(match.group(3))
    value_text = value_text.strip()
    if NUMERIC_LONG_RE.match(value_text):
        return None
    if not value_text:
        return None
    return value_text


def format_hex_long(value: int) -> str:
    text = f"{value:08x}H"
    return "0" + text if text[0].isalpha() else text


def format_ctrl(value: int) -> str:
    return f"0{value & 0xFFFF:04x}H"


def replace_directive_values(line: str, values_text: str) -> str:
    newline = ""
    if line.endswith("\r\n"):
        newline = "\r\n"
        line = line[:-2]
    elif line.endswith("\n"):
        newline = "\n"
        line = line[:-1]

    match = WORD_RE.match(line) or LONG_RE.match(line)
    if not match:
        raise ValueError(f"not an assembler directive: {line!r}")
    indent, spacing, _old_values, comment = match.groups()
    directive = ".word" if WORD_RE.match(line) else ".long"
    return f"{indent}{directive}{spacing}{values_text}{comment}{newline}"


def iter_label_ranges(lines: list[str]) -> Iterable[tuple[str, int, int]]:
    labels: list[tuple[str, int]] = []
    for index, line in enumerate(lines):
        match = LABEL_RE.match(line)
        if match:
            labels.append((match.group(1), index))
    for pos, (label, start) in enumerate(labels):
        end = labels[pos + 1][1] if pos + 1 < len(labels) else len(lines)
        yield label, start, end


def parse_table(path: Path) -> dict[str, HeaderEntry]:
    lines = path.read_text(encoding="latin-1").splitlines(keepends=True)
    entries: dict[str, HeaderEntry] = {}

    for label, start, end in iter_label_ranges(lines):
        words: list[WordRef] = []
        first_numeric_long: LongRef | None = None
        palette: str | None = None
        palette_line: int | None = None

        for line_index in range(start + 1, end):
            line = lines[line_index]
            word_values = parse_word_values(line)
            if word_values is not None:
                words.append(WordRef(line_index, word_values))
                continue

            long_value = parse_long_value(line)
            if long_value is not None and first_numeric_long is None:
                first_numeric_long = LongRef(line_index, long_value)
                continue

            if first_numeric_long is not None and palette is None:
                symbol = parse_long_symbol(line)
                if symbol is not None:
                    palette = symbol
                    palette_line = line_index

        if first_numeric_long is None or not words:
            continue

        before_sag = [word for word in words if word.line_index < first_numeric_long.line_index]
        after_sag = [word for word in words if word.line_index > first_numeric_long.line_index]
        if not before_sag or not after_sag:
            continue

        size_word = before_sag[0]
        ctrl_word = after_sag[0]

        if len(size_word.values) >= 4:
            sizx, sizy, anix, aniy = size_word.values[:4]
            if len(ctrl_word.values) < 1:
                continue
            ctrl = ctrl_word.values[0]
        elif len(size_word.values) == 2 and len(ctrl_word.values) >= 3:
            sizx, sizy = size_word.values
            anix, aniy, ctrl = ctrl_word.values[:3]
        else:
            continue

        entries[label] = HeaderEntry(
            label=label,
            table=path.name,
            size_line=size_word.line_index,
            size_word_count=len(size_word.values),
            sag_line=first_numeric_long.line_index,
            ctrl_line=ctrl_word.line_index,
            ctrl_word_count=len(ctrl_word.values),
            sizx=sizx,
            sizy=sizy,
            anix=anix,
            aniy=aniy,
            sag=first_numeric_long.value,
            ctrl=ctrl,
            palette=palette,
            palette_line=palette_line,
        )

    return entries


def build_load2_index(load2_dir: Path) -> tuple[dict[str, dict[str, HeaderEntry]], dict[str, HeaderEntry], set[str]]:
    by_table: dict[str, dict[str, HeaderEntry]] = {}
    by_label: dict[str, list[HeaderEntry]] = {}

    for path in sorted(load2_dir.glob("*.TBL")):
        entries = parse_table(path)
        by_table[path.name.upper()] = entries
        for entry in entries.values():
            by_label.setdefault(entry.label.upper(), []).append(entry)

    unique: dict[str, HeaderEntry] = {}
    conflicts: set[str] = set()
    for label, entries in by_label.items():
        signatures = {(e.sizx, e.sizy, e.anix, e.aniy, e.sag, e.ctrl, e.palette) for e in entries}
        if len(signatures) == 1:
            unique[label] = entries[0]
        else:
            conflicts.add(label)
    return by_table, unique, conflicts


def pick_load2_entry(
    src_entry: HeaderEntry,
    src_table: str,
    load2_by_table: dict[str, dict[str, HeaderEntry]],
    load2_unique_by_label: dict[str, HeaderEntry],
    use_global_labels: bool,
) -> HeaderEntry | None:
    table_entries = load2_by_table.get(src_table.upper(), {})
    direct = table_entries.get(src_entry.label)
    if direct is not None:
        return direct
    direct = table_entries.get(src_entry.label.upper())
    if direct is not None:
        return direct
    if not use_global_labels:
        return None
    return load2_unique_by_label.get(src_entry.label.upper())


def entry_diffs(src: HeaderEntry, load2: HeaderEntry, fields: set[str]) -> list[tuple[str, str, str]]:
    diffs: list[tuple[str, str, str]] = []
    if "size" in fields:
        old = (src.sizx, src.sizy, src.anix, src.aniy)
        new = (load2.sizx, load2.sizy, load2.anix, load2.aniy)
        if old != new:
            diffs.append(("size", ",".join(map(str, old)), ",".join(map(str, new))))
    if "sag" in fields and src.sag != load2.sag:
        diffs.append(("sag", format_hex_long(src.sag), format_hex_long(load2.sag)))
    if "ctrl" in fields and src.ctrl != load2.ctrl:
        diffs.append(("ctrl", format_ctrl(src.ctrl), format_ctrl(load2.ctrl)))
    if "palette" in fields and src.palette != load2.palette and not preserve_palette_ref(src):
        diffs.append(("palette", str(src.palette), str(load2.palette)))
    return diffs


def patch_table(path: Path, load2_entries: dict[str, HeaderEntry], fields: set[str]) -> int:
    lines = path.read_text(encoding="latin-1").splitlines(keepends=True)
    src_entries = parse_table(path)
    changed = 0

    for label, src in src_entries.items():
        load2 = load2_entries.get(label.upper())
        if load2 is None:
            continue

        if "size" in fields and (src.sizx, src.sizy, src.anix, src.aniy) != (
            load2.sizx,
            load2.sizy,
            load2.anix,
            load2.aniy,
        ):
            if src.size_word_count >= 4:
                lines[src.size_line] = replace_directive_values(
                    lines[src.size_line],
                    f"{load2.sizx},{load2.sizy},{load2.anix},{load2.aniy}",
                )
            elif src.size_word_count == 2 and src.ctrl_word_count >= 3:
                lines[src.size_line] = replace_directive_values(
                    lines[src.size_line],
                    f"{load2.sizx},{load2.sizy}",
                )
                lines[src.ctrl_line] = replace_directive_values(
                    lines[src.ctrl_line],
                    f"{load2.anix},{load2.aniy},{format_ctrl(load2.ctrl)}",
                )
            changed += 1

        if "sag" in fields and src.sag != load2.sag:
            lines[src.sag_line] = replace_directive_values(lines[src.sag_line], format_hex_long(load2.sag))
            changed += 1

        if "ctrl" in fields and src.ctrl != load2.ctrl:
            if src.ctrl_word_count == 1:
                lines[src.ctrl_line] = replace_directive_values(lines[src.ctrl_line], format_ctrl(load2.ctrl))
            elif src.ctrl_word_count >= 3:
                lines[src.ctrl_line] = replace_directive_values(
                    lines[src.ctrl_line],
                    f"{load2.anix},{load2.aniy},{format_ctrl(load2.ctrl)}",
                )
            changed += 1

        if (
            "palette" in fields
            and src.palette_line is not None
            and load2.palette is not None
            and src.palette != load2.palette
            and not preserve_palette_ref(src)
        ):
            lines[src.palette_line] = replace_directive_values(lines[src.palette_line], load2.palette)
            changed += 1

    if changed:
        path.write_text("".join(lines), encoding="latin-1")
    return changed


def parse_fields(raw: str) -> set[str]:
    valid = {"size", "sag", "ctrl", "palette"}
    fields = {item.strip().lower() for item in raw.split(",") if item.strip()}
    unknown = fields - valid
    if unknown:
        raise SystemExit(f"unknown --fields values: {', '.join(sorted(unknown))}")
    return fields


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", type=Path, default=Path("src"), help="source table directory")
    parser.add_argument("--load2", type=Path, default=Path("tmp/load2"), help="LOAD2 table output directory")
    parser.add_argument("--tables", nargs="*", help="specific source table filenames to inspect")
    parser.add_argument("--fields", default="size,sag,ctrl", help="comma list: size,sag,ctrl,palette")
    parser.add_argument("--apply", action="store_true", help="patch src tables")
    parser.add_argument("--check", action="store_true", help="exit nonzero if any selected source table is stale")
    parser.add_argument("--no-backup", action="store_true", help="do not create .load2sync.bak files with --apply")
    parser.add_argument("--no-global-labels", action="store_true", help="only match labels from the same table filename")
    parser.add_argument("--details", action="store_true", help="print every differing field")
    parser.add_argument("--csv", type=Path, help="write detailed CSV report")
    parser.add_argument("--dump-load2", type=Path, help="write every normalized LOAD2 image header to CSV")
    args = parser.parse_args()

    fields = parse_fields(args.fields)
    load2_by_table, load2_unique_by_label, load2_conflicts = build_load2_index(args.load2)
    use_global_labels = not args.no_global_labels

    if args.dump_load2:
        args.dump_load2.parent.mkdir(parents=True, exist_ok=True)
        with args.dump_load2.open("w", newline="", encoding="utf-8") as fp:
            writer = csv.DictWriter(
                fp,
                fieldnames=["table", "label", "sizx", "sizy", "anix", "aniy", "sag", "ctrl", "palette"],
            )
            writer.writeheader()
            for table in sorted(load2_by_table):
                for label in sorted(load2_by_table[table]):
                    entry = load2_by_table[table][label]
                    writer.writerow(
                        {
                            "table": entry.table,
                            "label": entry.label,
                            "sizx": entry.sizx,
                            "sizy": entry.sizy,
                            "anix": entry.anix,
                            "aniy": entry.aniy,
                            "sag": format_hex_long(entry.sag),
                            "ctrl": format_ctrl(entry.ctrl),
                            "palette": entry.palette or "",
                        }
                    )
        print(f"LOAD2 header dump written: {args.dump_load2}")

    if args.tables:
        src_paths = [args.src / table for table in args.tables]
    else:
        src_paths = sorted(args.src.glob("*.TBL"))

    rows: list[DiffRow] = []
    patch_maps: dict[Path, dict[str, HeaderEntry]] = {}
    summary: list[tuple[str, int, int, int, int]] = []

    for src_path in src_paths:
        if not src_path.exists():
            rows.append(DiffRow(src_path.name, "", None, "", "", "", "missing-src-table"))
            continue

        src_entries = parse_table(src_path)
        patch_map: dict[str, HeaderEntry] = {}
        matched = 0
        missing = 0
        changed_labels: set[str] = set()

        for src_entry in src_entries.values():
            load2_entry = pick_load2_entry(
                src_entry,
                src_path.name,
                load2_by_table,
                load2_unique_by_label,
                use_global_labels,
            )
            if load2_entry is None:
                missing += 1
                if src_entry.label.upper() in load2_conflicts:
                    rows.append(
                        DiffRow(src_path.name, src_entry.label, None, "", "", "", "global-label-conflict")
                    )
                continue

            matched += 1
            diffs = entry_diffs(src_entry, load2_entry, fields)
            if diffs:
                changed_labels.add(src_entry.label)
                patch_map[src_entry.label.upper()] = load2_entry
                for field, old, new in diffs:
                    rows.append(
                        DiffRow(src_path.name, src_entry.label, load2_entry.table, field, old, new, "diff")
                    )

        patch_maps[src_path] = patch_map
        summary.append((src_path.name, len(src_entries), matched, missing, len(changed_labels)))

    print("LOAD2 table sync report")
    print(f"  source: {args.src}")
    print(f"  load2:  {args.load2}")
    print(f"  fields: {','.join(sorted(fields))}")
    print()
    print(f"{'table':<16} {'entries':>7} {'matched':>7} {'missing':>7} {'changed':>7}")
    for table, entries, matched, missing, changed in summary:
        if changed or missing:
            print(f"{table:<16} {entries:7d} {matched:7d} {missing:7d} {changed:7d}")

    total_changed_labels = sum(item[4] for item in summary)
    print()
    print(f"Changed labels: {total_changed_labels}")
    print(f"Diff fields:    {sum(1 for row in rows if row.status == 'diff')}")
    if load2_conflicts and use_global_labels:
        print(f"Global label conflicts skipped: {len(load2_conflicts)}")

    if args.details:
        print()
        for row in rows:
            if row.status != "diff":
                continue
            print(f"{row.src_table}:{row.label}: {row.field} {row.old} -> {row.new} ({row.load2_table})")

    if args.csv:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="", encoding="utf-8") as fp:
            writer = csv.DictWriter(
                fp,
                fieldnames=["src_table", "label", "load2_table", "field", "old", "new", "status"],
            )
            writer.writeheader()
            for row in rows:
                writer.writerow(row.__dict__)
        print(f"CSV written: {args.csv}")

    if args.check:
        if total_changed_labels:
            print("Check failed: source tables are stale.")
            return 1
        print("Check passed: source tables match LOAD2.")
        return 0

    if args.apply:
        print()
        print("Applying updates...")
        for src_path, patch_map in patch_maps.items():
            if not patch_map:
                continue
            if not args.no_backup:
                backup = src_path.with_name(src_path.name + ".load2sync.bak")
                if not backup.exists():
                    shutil.copy2(src_path, backup)
            changed = patch_table(src_path, patch_map, fields)
            print(f"  {src_path}: {changed} field updates")
    else:
        print()
        print("Report-only. Re-run with --apply to patch src tables.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
