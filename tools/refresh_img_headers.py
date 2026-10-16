#!/usr/bin/env python3
"""
Refresh source TBL image headers from LOAD2 output.

LOAD2 emits fresh image records in tmp/load2 after build.py runs. The source
TBL files use the same data in a normalized shape, but hand edits can leave
W/H/ANIX/ANIY, SAG, or CTRL stale after an IMG/LOD changes.

Default mode reports drift. Use --apply to patch the source TBL records.

Examples:
    python tools/refresh_img_headers.py --recent
    python tools/refresh_img_headers.py --table JXHEADHO.TBL --apply
    python tools/refresh_img_headers.py --recent --palette-defs
    python tools/refresh_img_headers.py --recent --apply --apply-palettes
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


LABEL_RE = re.compile(r"^(\w+):\s*$")
END_RE = re.compile(r"^\s*\.(?:TEXT|END)\b", re.IGNORECASE)
WORD_LINE_RE = re.compile(r"^(\s*\.word\s+)(.*?)(\s*(?:;.*)?)$", re.IGNORECASE)
LONG_LINE_RE = re.compile(r"^(\s*\.long\s+)(.*?)(\s*(?:;.*)?)$", re.IGNORECASE)
NUMERIC_LONG_RE = re.compile(r"^0?[0-9a-fA-F]+[Hh]$")
LOD_ASM_RE = re.compile(r"^\s*ASM>\s*([^\s;]+)", re.IGNORECASE)
LOD_IMG_RE = re.compile(r"^\s*([A-Za-z0-9_.$-]+\.IMG)\s*(?:;.*)?$", re.IGNORECASE)
LOD_LABEL_RE = re.compile(r"^\s*--->\s*(.+?)(?:\s*;.*)?$")


@dataclass
class ImageRecord:
    label: str
    body: list[str]
    dims_idx: int | None = None
    sag_idx: int | None = None
    ctrl_idx: int | None = None
    w: int | None = None
    h: int | None = None
    anix: int | None = None
    aniy: int | None = None
    sag: int | None = None
    ctrl: int | None = None
    palettes: tuple[str, ...] = ()
    palette_lines: tuple[int, ...] = ()


@dataclass(frozen=True)
class LodEntry:
    lod: Path
    tbl: str
    img: str | None
    label: str


@dataclass
class PaletteBlock:
    path: Path
    label: str
    body: list[str]
    values: tuple[int, ...]


def parse_int_token(token: str) -> int | None:
    token = token.strip()
    if not token:
        return None
    neg = token.startswith("-")
    body = token[1:] if neg else token
    try:
        if body.lower().startswith("0x"):
            value = int(body, 16)
        elif body.upper().endswith("H"):
            value = int(body[:-1], 16)
        else:
            value = int(body, 10)
    except ValueError:
        return None
    return -value if neg else value


def split_values(value_text: str) -> list[str]:
    return [item.strip() for item in value_text.split(";", 1)[0].split(",") if item.strip()]


def parse_records(path: Path):
    """Return (header, records, footer) for label-owned TBL records."""
    try:
        lines = path.read_text(errors="replace").split("\n")
    except OSError:
        return [], [], []

    header: list[str] = []
    records: list[tuple[str, list[str]]] = []
    footer: list[str] = []
    label: str | None = None
    body: list[str] = []
    in_footer = False

    for line in lines:
        if in_footer:
            footer.append(line)
            continue
        if END_RE.match(line):
            if label is not None:
                records.append((label, body))
                label, body = None, []
            footer.append(line)
            in_footer = True
            continue
        match = LABEL_RE.match(line)
        if match:
            if label is not None:
                records.append((label, body))
            label = match.group(1)
            body = [line]
        elif label is None:
            header.append(line)
        else:
            body.append(line)

    if label is not None:
        records.append((label, body))

    return header, records, footer


def numeric_long_value(text: str) -> int | None:
    value = text.strip()
    if not NUMERIC_LONG_RE.match(value):
        return None
    return int(value[:-1] if value.upper().endswith("H") else value, 16)


def parse_image_record(label: str, body: list[str]) -> ImageRecord | None:
    rec = ImageRecord(label=label, body=body)

    first_word_idx = None
    first_word_values: list[str] | None = None
    for idx, line in enumerate(body):
        match = WORD_LINE_RE.match(line)
        if match:
            values = split_values(match.group(2))
            if values:
                first_word_idx = idx
                first_word_values = values
                break

    if first_word_idx is None or first_word_values is None:
        return None

    if len(first_word_values) >= 4:
        parsed = [parse_int_token(value) for value in first_word_values[:4]]
        if any(value is None for value in parsed):
            return None
        rec.w, rec.h, rec.anix, rec.aniy = parsed  # type: ignore[assignment]
        rec.dims_idx = first_word_idx
    elif len(first_word_values) >= 2:
        parsed = [parse_int_token(value) for value in first_word_values[:2]]
        if any(value is None for value in parsed):
            return None
        rec.w, rec.h = parsed  # type: ignore[assignment]
        rec.dims_idx = first_word_idx
    else:
        return None

    for idx in range(first_word_idx + 1, len(body)):
        match = LONG_LINE_RE.match(body[idx])
        if not match:
            continue
        sag = numeric_long_value(match.group(2))
        if sag is not None:
            rec.sag = sag
            rec.sag_idx = idx
            break

    if rec.sag_idx is None:
        return None

    for idx in range(rec.sag_idx + 1, len(body)):
        match = WORD_LINE_RE.match(body[idx])
        if not match:
            continue
        values = split_values(match.group(2))
        if len(values) >= 3:
            parsed = [parse_int_token(value) for value in values[:3]]
            if any(value is None for value in parsed):
                continue
            rec.anix, rec.aniy, rec.ctrl = parsed  # type: ignore[assignment]
            rec.ctrl_idx = idx
            break
        if len(values) == 1:
            ctrl = parse_int_token(values[0])
            if ctrl is not None:
                rec.ctrl = ctrl
                rec.ctrl_idx = idx
                break

    if rec.ctrl_idx is None or rec.ctrl is None:
        return None

    palettes: list[str] = []
    palette_lines: list[int] = []
    for idx in range(rec.ctrl_idx + 1, len(body)):
        match = LONG_LINE_RE.match(body[idx])
        if not match:
            continue
        value = match.group(2).strip()
        if numeric_long_value(value) is None:
            palettes.append(value)
            palette_lines.append(idx)

    rec.palettes = tuple(palettes)
    rec.palette_lines = tuple(palette_lines)
    return rec


def parse_tbl(path: Path) -> tuple[list[str], dict[str, ImageRecord], list[tuple[str, list[str]]], list[str]]:
    header, raw_records, footer = parse_records(path)
    records: dict[str, ImageRecord] = {}
    for label, body in raw_records:
        rec = parse_image_record(label, body)
        if rec is not None:
            records[label] = rec
    return header, records, raw_records, footer


def format_sag(value: int) -> str:
    return f"0{value:x}H"


def format_ctrl(value: int) -> str:
    return f"0{value & 0xFFFF:04x}H"


def patch_word_line(line: str, values: list[str]) -> str:
    match = WORD_LINE_RE.match(line)
    if not match:
        return line
    return f"{match.group(1)}{','.join(values)}{match.group(3)}"


def patch_long_line(line: str, value: str) -> str:
    match = LONG_LINE_RE.match(line)
    if not match:
        return line
    return f"{match.group(1)}{value}{match.group(3)}"


def patch_record(
    src: ImageRecord,
    gen: ImageRecord,
    apply_palettes: bool,
    drop_extra_palettes: bool,
) -> list[str]:
    body = list(src.body)

    if src.dims_idx is not None and None not in (gen.w, gen.h, gen.anix, gen.aniy):
        body[src.dims_idx] = patch_word_line(
            body[src.dims_idx],
            [str(gen.w), str(gen.h), str(gen.anix), str(gen.aniy)],
        )

    if src.sag_idx is not None and gen.sag is not None:
        body[src.sag_idx] = patch_long_line(body[src.sag_idx], format_sag(gen.sag))

    if src.ctrl_idx is not None and gen.ctrl is not None:
        match = WORD_LINE_RE.match(body[src.ctrl_idx])
        if match:
            values = split_values(match.group(2))
            if len(values) >= 3:
                values[2] = format_ctrl(gen.ctrl)
            elif len(values) == 1:
                values[0] = format_ctrl(gen.ctrl)
            body[src.ctrl_idx] = f"{match.group(1)}{','.join(values)}{match.group(3)}"

    if apply_palettes and gen.palettes:
        if src.palette_lines:
            for line_idx, palette in zip(src.palette_lines, gen.palettes):
                body[line_idx] = patch_long_line(body[line_idx], palette)
            if len(gen.palettes) > len(src.palette_lines):
                insert_at = src.palette_lines[-1] + 1
                for palette in gen.palettes[len(src.palette_lines):]:
                    body.insert(insert_at, f"\t.long   {palette}")
                    insert_at += 1
        elif src.ctrl_idx is not None:
            insert_at = src.ctrl_idx + 1
            for palette in gen.palettes:
                body.insert(insert_at, f"\t.long   {palette}")
                insert_at += 1
    elif apply_palettes and drop_extra_palettes and src.palette_lines and not gen.palettes:
        for line_idx in sorted(src.palette_lines, reverse=True):
            del body[line_idx]

    return body


def compare_record(src: ImageRecord, gen: ImageRecord, include_palette_refs: bool) -> list[str]:
    changes: list[str] = []
    src_dims = (src.w, src.h, src.anix, src.aniy)
    gen_dims = (gen.w, gen.h, gen.anix, gen.aniy)
    if None not in src_dims + gen_dims and src_dims != gen_dims:
        changes.append(
            "ANIPTS "
            f"{src.w},{src.h},{src.anix},{src.aniy} -> "
            f"{gen.w},{gen.h},{gen.anix},{gen.aniy}"
        )
    if src.sag is not None and gen.sag is not None and src.sag != gen.sag:
        changes.append(f"SAG {format_sag(src.sag)} -> {format_sag(gen.sag)}")
    if src.ctrl is not None and gen.ctrl is not None and src.ctrl != gen.ctrl:
        changes.append(f"CTRL {format_ctrl(src.ctrl)} -> {format_ctrl(gen.ctrl)}")
    if include_palette_refs and src.palettes != gen.palettes:
        if gen.palettes and src.palettes:
            changes.append(
                "PAL "
                f"{','.join(src.palettes)} -> {','.join(gen.palettes)}"
            )
        elif gen.palettes:
            changes.append(f"PAL missing src; regen has {','.join(gen.palettes)}")
        elif src.palettes:
            changes.append(f"PAL extra src {','.join(src.palettes)}; regen has none")
    return changes


def reassemble(header: list[str], records: list[tuple[str, list[str]]], footer: list[str]) -> str:
    lines: list[str] = []
    lines.extend(header)
    for _, body in records:
        lines.extend(body)
    lines.extend(footer)
    return "\n".join(lines)


def parse_palette_block(path: Path, label: str, body: list[str]) -> PaletteBlock | None:
    values: list[int] = []
    for line in body[1:]:
        match = WORD_LINE_RE.match(line)
        if not match:
            continue
        for token in split_values(match.group(2)):
            value = parse_int_token(token)
            if value is None:
                return None
            values.append(value)
    if not values:
        return None
    return PaletteBlock(path=path, label=label, body=body, values=tuple(values))


def parse_palette_file(path: Path):
    header, raw_records, footer = parse_records(path)
    blocks: dict[str, PaletteBlock] = {}
    for label, body in raw_records:
        block = parse_palette_block(path, label, body)
        if block is not None:
            blocks[label] = block
    return header, raw_records, footer, blocks


def source_palette_files(src_dir: Path) -> list[Path]:
    files = sorted(src_dir.glob("IMGPAL*.ASM"))
    bg = src_dir / "BGNDPAL.ASM"
    if bg.exists():
        files.append(bg)
    return files


def generated_palette_files(gen_dir: Path) -> list[Path]:
    return sorted(gen_dir.glob("*PAL*.ASM"))


def first_palette_diff(src: PaletteBlock, gen: PaletteBlock) -> str:
    for idx, (src_value, gen_value) in enumerate(zip(src.values, gen.values)):
        if src_value != gen_value:
            return f"word {idx}: {format_ctrl(src_value)} -> {format_ctrl(gen_value)}"
    if len(src.values) != len(gen.values):
        return f"length {len(src.values)} -> {len(gen.values)}"
    return "values differ"


def check_palette_definitions(
    src_dir: Path,
    gen_dir: Path,
    allowed_palettes: set[str] | None,
    apply_defs: bool,
    limit_remaining: int,
) -> tuple[int, int, int]:
    """Compare tmp/load2 palette blocks against source palette definitions.

    Returns (stale_count, touched_files, printed_count).
    """
    src_index: dict[str, PaletteBlock] = {}
    src_parsed = {}
    for path in source_palette_files(src_dir):
        parsed = parse_palette_file(path)
        src_parsed[path] = parsed
        for label, block in parsed[3].items():
            src_index[label] = block

    stale = 0
    printed = 0
    replacements: dict[Path, dict[str, list[str]]] = {}

    for gen_path in generated_palette_files(gen_dir):
        _, _, _, gen_blocks = parse_palette_file(gen_path)
        for label, gen_block in gen_blocks.items():
            if allowed_palettes is not None and label not in allowed_palettes:
                continue
            src_block = src_index.get(label)
            if src_block is None:
                stale += 1
                if printed < limit_remaining:
                    print(f"PALDEF missing src for {gen_path.name}:{label}")
                    printed += 1
                continue
            if src_block.values == gen_block.values:
                continue
            stale += 1
            if printed < limit_remaining:
                print(
                    f"PALDEF {gen_path.name}:{label}  "
                    f"{src_block.path.relative_to(src_dir.parent)}  "
                    f"{first_palette_diff(src_block, gen_block)}"
                )
                printed += 1
            if apply_defs:
                replacements.setdefault(src_block.path, {})[label] = gen_block.body

    touched = 0
    if apply_defs:
        for path, by_label in replacements.items():
            header, raw_records, footer, _ = src_parsed[path]
            rebuilt: list[tuple[str, list[str]]] = []
            changed = False
            for label, body in raw_records:
                if label in by_label:
                    rebuilt.append((label, by_label[label]))
                    changed = True
                else:
                    rebuilt.append((label, body))
            if changed:
                path.write_text(reassemble(header, rebuilt, footer))
                touched += 1

    return stale, touched, printed


def parse_lod_entries(data_dir: Path) -> list[LodEntry]:
    entries: list[LodEntry] = []
    for lod in sorted(data_dir.glob("*.LOD")):
        current_tbl: str | None = None
        current_img: str | None = None
        try:
            lines = lod.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            asm_match = LOD_ASM_RE.match(line)
            if asm_match:
                current_tbl = asm_match.group(1).upper()
                continue

            img_match = LOD_IMG_RE.match(line)
            if img_match:
                current_img = img_match.group(1).upper()
                continue

            label_match = LOD_LABEL_RE.match(line)
            if label_match and current_tbl:
                labels = [label.strip() for label in label_match.group(1).split(",")]
                for label in labels:
                    if label:
                        entries.append(LodEntry(lod=lod, tbl=current_tbl, img=current_img, label=label))
    return entries


def git_changed_data(repo: Path) -> set[Path]:
    try:
        output = subprocess.check_output(
            ["git", "status", "--porcelain", "--", "data"],
            cwd=repo,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return set()

    changed: set[Path] = set()
    for line in output.splitlines():
        if len(line) < 4:
            continue
        path_text = line[3:].strip()
        if " -> " in path_text:
            path_text = path_text.split(" -> ", 1)[1]
        path = repo / path_text
        if path.suffix.upper() in {".IMG", ".LOD"}:
            changed.add(path.resolve())
    return changed


def mtime_recent_data(data_dir: Path, days: float) -> set[Path]:
    cutoff = time.time() - days * 24 * 60 * 60
    recent: set[Path] = set()
    for suffix in ("*.IMG", "*.LOD"):
        for path in data_dir.glob(suffix):
            try:
                if path.stat().st_mtime >= cutoff:
                    recent.add(path.resolve())
            except OSError:
                pass
    return recent


def recent_filter(repo: Path, days: float) -> tuple[set[str], set[str], list[Path]]:
    data_dir = repo / "data"
    changed = git_changed_data(repo) | mtime_recent_data(data_dir, days)
    changed = {path for path in changed if "_orig_lod" not in path.parts}
    changed_imgs = {path.name.upper() for path in changed if path.suffix.upper() == ".IMG"}
    changed_lods = {path.name.upper() for path in changed if path.suffix.upper() == ".LOD"}

    tables: set[str] = set()
    labels: set[str] = set()
    for entry in parse_lod_entries(data_dir):
        lod_changed = entry.lod.name.upper() in changed_lods
        img_changed = entry.img is not None and entry.img.upper() in changed_imgs
        if lod_changed or img_changed:
            tables.add(entry.tbl.upper())
            labels.add(entry.label)

    return tables, labels, sorted(changed)


def normalize_table_name(name: str) -> str:
    upper = name.upper()
    return upper if upper.endswith(".TBL") else f"{upper}.TBL"


def find_includers(src_dir: Path, tbl_name: str) -> list[Path]:
    pat = re.compile(rf"^\s*\.INCLUDE\s+{re.escape(tbl_name)}\s*$", re.IGNORECASE | re.MULTILINE)
    hits: list[Path] = []
    for asm in src_dir.glob("*.ASM"):
        try:
            if pat.search(asm.read_text(errors="replace")):
                hits.append(asm)
        except OSError:
            pass
    return hits


def invalidate_objs(src_dir: Path, tbl_name: str) -> list[str]:
    killed: list[str] = []
    for asm in find_includers(src_dir, tbl_name):
        for suffix in (".OBJ", ".LST"):
            target = asm.with_suffix(suffix)
            if target.exists():
                target.unlink()
                killed.append(target.name)
    return killed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--recent", action="store_true", help="only scan IMG/LOD assets changed in git or by mtime")
    parser.add_argument("--days", type=float, default=3.0, help="mtime window used by --recent (default: 3)")
    parser.add_argument("--table", action="append", default=[], help="limit to a source/generated TBL file")
    parser.add_argument("--label", action="append", default=[], help="limit to one image label")
    parser.add_argument("--apply", action="store_true", help="patch source TBL records in-place")
    parser.add_argument(
        "--apply-palettes",
        action="store_true",
        help="also insert/update palette refs when LOAD2 emits them; extra src palettes are still preserved",
    )
    parser.add_argument(
        "--drop-extra-palettes",
        action="store_true",
        help="with --apply-palettes, remove source TBL palette refs when LOAD2 emits none",
    )
    parser.add_argument("--headers-only", action="store_true", help="ignore TBL palette-ref drift")
    parser.add_argument(
        "--palette-defs",
        action="store_true",
        help="compare generated palette color definitions against src/IMGPAL*.ASM and src/BGNDPAL.ASM",
    )
    parser.add_argument(
        "--apply-palette-defs",
        action="store_true",
        help="replace matching source palette definitions with generated tmp/load2 palette data",
    )
    parser.add_argument(
        "--palette-defs-only",
        action="store_true",
        help="skip TBL header scanning and only compare generated palette color definitions",
    )
    parser.add_argument("--palette", action="append", default=[], help="limit palette definition checks to one label")
    parser.add_argument("--limit", type=int, default=200, help="maximum drift lines to print")
    parser.add_argument("--no-invalidate", action="store_true", help="do not remove includer OBJ/LST files after patching")
    parser.add_argument("--verbose", action="store_true", help="print unchanged scanned tables")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    src_dir = repo / "src"
    gen_dir = repo / "tmp" / "load2"

    if not gen_dir.exists():
        print(f"error: {gen_dir} does not exist; run python build.py first so LOAD2 emits fresh tables")
        return 2

    explicit_tables = {normalize_table_name(table) for table in args.table}
    explicit_labels = set(args.label)
    allowed_tables: set[str] | None = explicit_tables or None
    allowed_labels: set[str] | None = explicit_labels or None
    changed_paths: list[Path] = []

    if args.recent:
        recent_tables, recent_labels, changed_paths = recent_filter(repo, args.days)
        if allowed_tables is None:
            allowed_tables = recent_tables
        else:
            allowed_tables &= recent_tables
        if allowed_labels is None:
            allowed_labels = recent_labels
        else:
            allowed_labels &= recent_labels

        print("Recent IMG/LOD inputs:")
        if changed_paths:
            for path in changed_paths[:40]:
                print(f"  {path.relative_to(repo)}")
            if len(changed_paths) > 40:
                print(f"  ... {len(changed_paths) - 40} more")
        else:
            print("  none found")

    gen_tbls = [] if args.palette_defs_only else sorted(gen_dir.glob("*.TBL"))
    touched = 0
    palette_defs_touched = 0
    stale_records = 0
    stale_palette_defs = 0
    stale_tables = 0
    printed = 0
    objs_killed: list[str] = []
    palette_refs_seen: set[str] = set()

    for gen_path in gen_tbls:
        table_name = gen_path.name.upper()
        if allowed_tables is not None and table_name not in allowed_tables:
            continue
        src_path = src_dir / gen_path.name
        if not src_path.exists():
            continue

        src_header, src_records, src_raw_records, src_footer = parse_tbl(src_path)
        _, gen_records, _, _ = parse_tbl(gen_path)
        if not src_records or not gen_records:
            continue

        new_raw_records: list[tuple[str, list[str]]] = []
        table_stale = False
        table_touched = False
        table_scanned = 0

        for label, body in src_raw_records:
            src_rec = src_records.get(label)
            gen_rec = gen_records.get(label)
            if (
                src_rec is None
                or gen_rec is None
                or (allowed_labels is not None and label not in allowed_labels)
            ):
                new_raw_records.append((label, body))
                continue

            table_scanned += 1
            palette_refs_seen.update(gen_rec.palettes)
            changes = compare_record(src_rec, gen_rec, not args.headers_only)
            if changes:
                table_stale = True
                stale_records += 1
                if printed < args.limit:
                    print(f"STALE {gen_path.name}:{label}  " + "; ".join(changes))
                    printed += 1
                if args.apply:
                    new_raw_records.append(
                        (
                            label,
                            patch_record(
                                src_rec,
                                gen_rec,
                                args.apply_palettes,
                                args.drop_extra_palettes,
                            ),
                        )
                    )
                    table_touched = True
                else:
                    new_raw_records.append((label, body))
            else:
                new_raw_records.append((label, body))

        if table_stale:
            stale_tables += 1
        elif args.verbose and table_scanned:
            print(f"OK    {gen_path.name}  ({table_scanned} records)")

        if table_touched:
            src_path.write_text(reassemble(src_header, new_raw_records, src_footer))
            touched += 1
            if not args.no_invalidate:
                objs_killed.extend(invalidate_objs(src_dir, gen_path.name))

    if args.palette_defs or args.apply_palette_defs or args.palette_defs_only:
        explicit_palettes = set(args.palette)
        if explicit_palettes:
            allowed_palettes = explicit_palettes
        elif args.palette_defs_only:
            allowed_palettes = None
        elif args.recent or explicit_tables or explicit_labels:
            allowed_palettes = palette_refs_seen
        else:
            allowed_palettes = None
        pal_stale, pal_touched, pal_printed = check_palette_definitions(
            src_dir,
            gen_dir,
            allowed_palettes,
            args.apply_palette_defs,
            max(0, args.limit - printed),
        )
        stale_palette_defs += pal_stale
        palette_defs_touched += pal_touched
        printed += pal_printed

    total_stale = stale_records + stale_palette_defs

    if printed == args.limit and total_stale > printed:
        print(f"... {total_stale - printed} more stale records not shown; raise --limit to see them")

    if args.apply or args.apply_palette_defs:
        print(
            f"Patched {touched} TBL file(s), {palette_defs_touched} palette file(s); "
            f"stale records seen: {total_stale}"
        )
        if objs_killed:
            print("Invalidated includer outputs: " + ", ".join(sorted(set(objs_killed))))
    else:
        print(f"Found {total_stale} stale record(s) across {stale_tables} TBL file(s)")
        if total_stale:
            print("Re-run with --apply to patch W/H/ANIX/ANIY/SAG/CTRL fields.")
            if not args.headers_only:
                print("Palette refs are report-only unless --apply-palettes is supplied.")
            print("Palette color definitions are patched only with --apply-palette-defs.")

    return 1 if total_stale and not (args.apply or args.apply_palette_defs) else 0


if __name__ == "__main__":
    sys.exit(main())
