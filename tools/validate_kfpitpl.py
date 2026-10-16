#!/usr/bin/env python3
"""Validate the KFPITPL Pit-bottom background payload and render path.

This is the fast pre-MAME gate for the current Pit proof. It checks:

* KFPITPL.LOD, KFPITPL.IRW, and KFPITBG.ASM agree on the current bank-0 base.
* KFPITBG.ASM is in sync with the most recent LOAD2 KFP output.
* Every BLKS entry references a valid TPLHDRS image and TPLPALS palette.
* The runtime background/foreground split matches the single-spike foreground rule.
* rom/debug/video_flat.bin contains the KFPITPL.IRW payload at the expected
  physical video offset.
* The runtime table/video decode visually matches the source BDB/BDD within a
  small pixel tolerance.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

from refresh_kfpitbg import body_from_first_label, build_kfpitbg_text


IRW_HEADER_SIZE = 68
IRW_BASE_OFF = 44
IRW_SIZE_OFF = 48
IRW_BANK_OFF = 60

IROM_BASE = 0x02000000
BANK_OFFSETS = {0: 0x000000, 1: 0x800000}

DEFAULT_LOAD_BASE = 0x05D40000
DEFAULT_TABLE_BASE = 0x03D40000
DEFAULT_BANK = 0
DEFAULT_ALLOWED_FLAT_START = 0x7A8000
DEFAULT_ALLOWED_FLAT_END = 0x800000


class CheckError(RuntimeError):
    pass


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
    match = re.search(r"\.word\s+(.+)$", line, re.IGNORECASE)
    if not match:
        return []
    return [asm_int(part) for part in match.group(1).split(",") if part.strip()]


def long_values(line: str) -> list[str]:
    line = line.split(";", 1)[0]
    match = re.search(r"\.long\s+(.+)$", line, re.IGNORECASE)
    if not match:
        return []
    return [part.strip() for part in match.group(1).split(",") if part.strip()]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckError(message)


def find_label(text: str, label: str) -> re.Match[str]:
    match = re.search(rf"(?m)^{re.escape(label)}:\s*", text)
    if not match:
        raise CheckError(f"missing label {label}")
    return match


def section_between(text: str, start_label: str, end_label: str | None = None) -> str:
    start = find_label(text, start_label).end()
    if end_label is not None:
        end = find_label(text, end_label).start()
        return text[start:end]
    next_label = re.search(r"(?m)^[A-Za-z_][A-Za-z0-9_]*:\s*", text[start:])
    end = start + next_label.start() if next_label else len(text)
    return text[start:end]


def has_label(text: str, label: str) -> bool:
    return re.search(rf"(?m)^{re.escape(label)}:\s*", text) is not None


def parse_lod(path: Path) -> tuple[int, int | None]:
    text = path.read_text(encoding="ascii", errors="replace")
    match = re.search(
        r"(?m)^\s*\*\*\*>\s*(0x[0-9A-Fa-f]+|[0-9A-Fa-f]+)(?:\s*,\s*(\d+))?",
        text,
    )
    if not match:
        raise CheckError(f"{path} has no ***> directive")
    base = int(match.group(1), 0 if match.group(1).lower().startswith("0x") else 16)
    bank = int(match.group(2)) if match.group(2) is not None else None
    return base, bank


def read_irw(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    require(len(data) >= IRW_HEADER_SIZE, f"{path} is shorter than the IRW header")
    base = struct.unpack_from("<I", data, IRW_BASE_OFF)[0]
    size = struct.unpack_from("<I", data, IRW_SIZE_OFF)[0]
    bank = struct.unpack_from("<I", data, IRW_BANK_OFF)[0]
    payload = data[IRW_HEADER_SIZE : IRW_HEADER_SIZE + size]
    require(len(payload) == size, f"{path} payload truncated: header={size} actual={len(payload)}")
    return base, bank, payload


def video_linear_offset(base_addr: int, bank: int) -> int:
    require(bank in BANK_OFFSETS, f"bank must be 0 or 1, got 0x{bank:x}")
    return BANK_OFFSETS[bank] + ((base_addr - IROM_BASE) // 8)


def parse_blocks_section(text: str, start_label: str, end_label: str) -> list[dict]:
    blocks_body = section_between(text, start_label, end_label)
    values: list[int] = []
    saw_end = False
    for line in blocks_body.splitlines():
        vals = word_values(line)
        if vals and vals[0] == 0xFFFF:
            saw_end = True
            break
        values.extend(vals)
    require(saw_end, f"{start_label} has no 0FFFFH end marker")
    require(len(values) % 4 == 0, f"{start_label} has {len(values)} words, not divisible by 4")

    blocks = []
    for index in range(0, len(values), 4):
        flags, x, y, hdr_word = values[index : index + 4]
        blocks.append(
            {
                "flags": flags,
                "layer": (flags >> 8) & 0xFF,
                "x": x,
                "y": y,
                "hdr": hdr_word & 0x0FFF,
                "pal": (flags & 0x000F) | (((hdr_word >> 12) & 0x000F) << 4),
                "raw": (flags, x, y, hdr_word),
            }
        )
    return blocks


def parse_bmod_section(text: str, label: str, expected_block_label: str) -> dict:
    bmod_body = section_between(text, label)
    dims = None
    refs = None
    for line in bmod_body.splitlines():
        vals = word_values(line)
        if vals and dims is None:
            dims = vals
        longs = long_values(line)
        if len(longs) >= 3 and refs is None:
            refs = longs[:3]
    require(dims is not None and len(dims) >= 3, f"{label} has no width,height,count")
    expected_refs = [expected_block_label, "TPLHDRS", "TPLPALS"]
    require(refs == expected_refs, f"{label} does not reference {','.join(expected_refs)}")
    return {"width": dims[0], "height": dims[1], "count": dims[2], "refs": refs}


def is_kfpitpl_foreground(block: dict) -> bool:
    single_spike = block["layer"] == 0x42 and block["pal"] == 11 and block["hdr"] == 0x27
    return single_spike or block["layer"] == 0x43


def parse_kfpitbg(path: Path):
    text = path.read_text(encoding="ascii", errors="replace")

    pals_body = section_between(text, "TPLPALS")
    pal_labels = []
    for line in pals_body.splitlines():
        pal_labels.extend(long_values(line))
    require(pal_labels, "TPLPALS has no palette labels")

    hdrs_body = section_between(text, "TPLHDRS", "KFPITPLBLKS")
    hdrs = []
    lines = hdrs_body.splitlines()
    i = 0
    while i + 2 < len(lines):
        wh = word_values(lines[i])
        longs = long_values(lines[i + 1])
        ctrl = word_values(lines[i + 2])
        if len(wh) == 2 and len(longs) == 1 and len(ctrl) == 1:
            hdrs.append(
                {
                    "width": wh[0],
                    "height": wh[1],
                    "addr": asm_int(longs[0]),
                    "ctrl": ctrl[0],
                }
            )
            i += 3
        else:
            i += 1
    require(hdrs, "TPLHDRS has no parseable image headers")

    blocks = parse_blocks_section(text, "KFPITPLBLKS", "KFPITPLBMOD")
    bmod = parse_bmod_section(text, "KFPITPLBMOD", "KFPITPLBLKS")

    split = None
    if has_label(text, "KFPITPLBGBLKS") and has_label(text, "KFPITPLFGBLKS"):
        bg_blocks = parse_blocks_section(text, "KFPITPLBGBLKS", "KFPITPLBGBMOD")
        fg_blocks = parse_blocks_section(text, "KFPITPLFGBLKS", "KFPITPLFGBMOD")
        split = {
            "bg_blocks": bg_blocks,
            "fg_blocks": fg_blocks,
            "bg_bmod": parse_bmod_section(text, "KFPITPLBGBMOD", "KFPITPLBGBLKS"),
            "fg_bmod": parse_bmod_section(text, "KFPITPLFGBMOD", "KFPITPLFGBLKS"),
        }

    return {
        "palettes": pal_labels,
        "hdrs": hdrs,
        "blocks": blocks,
        "bmod": bmod,
        "split": split,
    }


def generated_kfpitbg_text(root: Path) -> str | None:
    try:
        return build_kfpitbg_text(root)
    except FileNotFoundError:
        return None


def run_makevrom(root: Path) -> None:
    result = subprocess.run(
        [sys.executable, "makevrom.py", "--debug-bin"],
        cwd=str(root),
        text=True,
    )
    if result.returncode != 0:
        raise CheckError(f"makevrom.py --debug-bin failed with exit {result.returncode}")


def render_compare(args: argparse.Namespace, root: Path) -> dict:
    tools_dir = args.bddtool_root / "tools"
    require(tools_dir.exists(), f"bddtool tools dir not found: {tools_dir}")
    sys.path.insert(0, str(tools_dir))
    try:
        import render_bgproof_mk2 as renderer
    except Exception as exc:  # pragma: no cover - import error is user-facing
        raise CheckError(f"could not import bddtool render_bgproof_mk2.py: {exc}") from exc

    out_dir = args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    ns = SimpleNamespace(
        table=root / "src" / "KFPITBG.ASM",
        palette_asm=root / "src" / "KFPITBG.ASM",
        irw=root / "data" / "KFPITPL.IRW",
        video_flat=root / "rom" / "debug" / "video_flat.bin",
        use_video_flat=not args.no_video_flat,
        no_video_flat=args.no_video_flat,
        rom_zip=None,
        address_adjust=-0x02000000,
        bmod_label="KFPITPLBMOD",
        pals_label="TPLPALS",
        bdb=root / "data" / "KFPITPL.BDB",
        bdd=root / "data" / "KFPITPL.BDD",
        source_module="KFPITPL",
        source_offset_x=args.source_offset_x,
        source_offset_y=args.source_offset_y,
    )
    if not args.no_video_flat:
        require(ns.video_flat.exists(), f"{ns.video_flat} missing; run makevrom.py --debug-bin")

    runtime, width, height = renderer.render_runtime(ns)
    source = renderer.source_render(ns, width, height)
    runtime_png = out_dir / "kfpitpl_runtime.png"
    source_png = out_dir / "kfpitpl_source.png"
    diff_png = out_dir / "kfpitpl_diff.png"
    viewport_png = out_dir / f"kfpitpl_expected_worldx{args.viewport_x}.png"
    renderer.write_png(runtime_png, width, height, runtime)
    renderer.write_png(source_png, width, height, source)
    viewport = crop_rgba(source, width, height, args.viewport_x, args.viewport_y, args.viewport_width, args.viewport_height)
    renderer.write_png(viewport_png, args.viewport_width, args.viewport_height, viewport)
    mismatches = renderer.write_diff(diff_png, width, height, runtime, source)

    nontransparent = sum(1 for i in range(3, len(runtime), 4) if runtime[i] != 0)
    unique_rgba = len({bytes(runtime[i : i + 4]) for i in range(0, len(runtime), 4)})
    return {
        "width": width,
        "height": height,
        "mismatches": mismatches,
        "nontransparent": nontransparent,
        "unique_rgba": unique_rgba,
        "runtime_png": str(runtime_png),
        "source_png": str(source_png),
        "diff_png": str(diff_png),
        "viewport_png": str(viewport_png),
    }


def crop_rgba(
    rgba: bytes | bytearray,
    width: int,
    height: int,
    x: int,
    y: int,
    crop_w: int,
    crop_h: int,
) -> bytearray:
    out = bytearray(crop_w * crop_h * 4)
    for yy in range(crop_h):
        sy = y + yy
        if sy < 0 or sy >= height:
            continue
        for xx in range(crop_w):
            sx = x + xx
            if sx < 0 or sx >= width:
                continue
            src = (sy * width + sx) * 4
            dst = (yy * crop_w + xx) * 4
            out[dst:dst + 4] = rgba[src:src + 4]
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate KFPITPL Pit-bottom background products")
    parser.add_argument("--mk2-root", type=Path, default=Path.cwd())
    parser.add_argument("--expected-load-base", type=lambda s: int(s, 0), default=DEFAULT_LOAD_BASE)
    parser.add_argument("--expected-table-base", type=lambda s: int(s, 0), default=DEFAULT_TABLE_BASE)
    parser.add_argument("--expected-bank", type=int, choices=(0, 1), default=DEFAULT_BANK)
    parser.add_argument("--allowed-flat-start", type=lambda s: int(s, 0), default=DEFAULT_ALLOWED_FLAT_START)
    parser.add_argument("--allowed-flat-end", type=lambda s: int(s, 0), default=DEFAULT_ALLOWED_FLAT_END)
    parser.add_argument("--rebuild-video", action="store_true", help="Run makevrom.py --debug-bin before validation")
    parser.add_argument("--no-video-flat", action="store_true", help="Render directly from KFPITPL.IRW instead of video_flat.bin")
    parser.add_argument("--skip-render", action="store_true", help="Skip bddtool runtime/source PNG render comparison")
    parser.add_argument("--bddtool-root", type=Path, default=Path(r"C:\Users\you\Workplace\midway-bddtool"))
    parser.add_argument("--output-dir", type=Path, default=Path("tmp/kfpitpl_validate"))
    parser.add_argument("--source-offset-x", type=int, default=1, help="LOAD2 emits BLKS x positions one pixel left of BDB source")
    parser.add_argument("--source-offset-y", type=int, default=0)
    parser.add_argument("--viewport-x", type=int, default=0)
    parser.add_argument("--viewport-y", type=int, default=32)
    parser.add_argument("--viewport-width", type=int, default=400)
    parser.add_argument("--viewport-height", type=int, default=254)
    parser.add_argument("--max-render-mismatches", type=int, default=40000,
                        help="Tolerance is loose because KFPITPLBLKS is X-sorted for runtime; MAME re-sorts display objects by z/y.")
    args = parser.parse_args()

    root = args.mk2_root.resolve()
    args.bddtool_root = args.bddtool_root.resolve()
    args.output_dir = (root / args.output_dir).resolve() if not args.output_dir.is_absolute() else args.output_dir.resolve()

    if args.rebuild_video:
        run_makevrom(root)

    lod_base, lod_bank = parse_lod(root / "data" / "KFPITPL.LOD")
    irw_base, irw_bank, payload = read_irw(root / "data" / "KFPITPL.IRW")
    table = parse_kfpitbg(root / "src" / "KFPITBG.ASM")

    require(lod_base == args.expected_load_base, f"KFPITPL.LOD base 0x{lod_base:08x} != 0x{args.expected_load_base:08x}")
    require((lod_bank or 0) == args.expected_bank, f"KFPITPL.LOD bank {lod_bank or 0} != {args.expected_bank}")
    require(irw_base == args.expected_load_base, f"KFPITPL.IRW base 0x{irw_base:08x} != 0x{args.expected_load_base:08x}")
    require(irw_bank == args.expected_bank, f"KFPITPL.IRW bank 0x{irw_bank:x} != {args.expected_bank}")

    bmod = table["bmod"]
    blocks = table["blocks"]
    hdrs = table["hdrs"]
    palettes = table["palettes"]
    require(bmod["count"] == len(blocks), f"KFPITPLBMOD count {bmod['count']} != BLKS count {len(blocks)}")
    for idx, block in enumerate(blocks):
        require(block["hdr"] < len(hdrs), f"block {idx} references HDR {block['hdr']} but only {len(hdrs)} exist")
        require(block["pal"] < len(palettes), f"block {idx} references palette {block['pal']} but only {len(palettes)} exist")
    for idx in range(1, len(blocks)):
        require(
            blocks[idx]["x"] >= blocks[idx - 1]["x"],
            f"KFPITPLBLKS is not sorted by X at block {idx - 1}->{idx}: "
            f"{blocks[idx - 1]['x']} > {blocks[idx]['x']}. Run python tools\\refresh_kfpitbg.py",
        )
    split = table["split"]
    if split is not None:
        bg_blocks = split["bg_blocks"]
        fg_blocks = split["fg_blocks"]
        require(split["bg_bmod"]["count"] == len(bg_blocks), "KFPITPLBGBMOD count does not match KFPITPLBGBLKS")
        require(split["fg_bmod"]["count"] == len(fg_blocks), "KFPITPLFGBMOD count does not match KFPITPLFGBLKS")
        require(
            sorted(block["raw"] for block in bg_blocks + fg_blocks) == sorted(block["raw"] for block in blocks),
            "KFPITPL runtime split tables do not recombine to the full sorted KFPITPLBLKS table",
        )
        for idx, block in enumerate(bg_blocks):
            require(not is_kfpitpl_foreground(block), f"KFPITPLBGBLKS block {idx} should be in KFPITPLFGBLKS")
        for idx, block in enumerate(fg_blocks):
            require(is_kfpitpl_foreground(block), f"KFPITPLFGBLKS block {idx} does not match foreground rule")
        for label, records in (("KFPITPLBGBLKS", bg_blocks), ("KFPITPLFGBLKS", fg_blocks)):
            for idx in range(1, len(records)):
                require(records[idx]["x"] >= records[idx - 1]["x"], f"{label} is not sorted by X at {idx - 1}->{idx}")

    sag_start = min(hdr["addr"] for hdr in hdrs)
    sag_end = max(hdr["addr"] for hdr in hdrs)
    table_payload_end = args.expected_table_base + len(payload) * 8
    require(sag_start == args.expected_table_base, f"first TPLHDRS SAG 0x{sag_start:08x} != 0x{args.expected_table_base:08x}")
    require(sag_end < table_payload_end, f"last TPLHDRS SAG 0x{sag_end:08x} outside payload end 0x{table_payload_end:08x}")

    gen = generated_kfpitbg_text(root)
    if gen is not None:
        current = (root / "src" / "KFPITBG.ASM").read_text(encoding="ascii", errors="replace")
        require(
            body_from_first_label(current) == body_from_first_label(gen),
            "src/KFPITBG.ASM is not in sync with sorted tmp/load2/BGNDPAL.ASM + BGNDTBL.KFP. "
            "Run python tools\\refresh_kfpitbg.py",
        )

    flat_start = video_linear_offset(irw_base, irw_bank)
    flat_end = flat_start + len(payload)
    require(args.allowed_flat_start <= flat_start, f"KFPITPL flat start 0x{flat_start:06x} is before allowed retired range")
    require(flat_end <= args.allowed_flat_end, f"KFPITPL flat end 0x{flat_end:06x} exceeds allowed retired range 0x{args.allowed_flat_end:06x}")

    video_flat = root / "rom" / "debug" / "video_flat.bin"
    if not args.no_video_flat:
        require(video_flat.exists(), f"{video_flat} missing; run makevrom.py --debug-bin")
        video = video_flat.read_bytes()
        require(video[flat_start:flat_end] == payload, f"video_flat.bin does not contain KFPITPL payload at 0x{flat_start:06x}")

    render = None
    if not args.skip_render:
        render = render_compare(args, root)
        require(render["mismatches"] <= args.max_render_mismatches,
                f"render mismatch {render['mismatches']} > {args.max_render_mismatches}")
        min_opaque = render["width"] * render["height"] // 2
        require(render["nontransparent"] > min_opaque,
                f"runtime render too sparse: {render['nontransparent']} opaque pixels")
        require(render["unique_rgba"] > 128, f"runtime render has too few colors: {render['unique_rgba']}")

    summary = {
        "status": "passed",
        "lod_base": f"0x{lod_base:08X}",
        "irw_bank": irw_bank,
        "payload_bytes": len(payload),
        "table_base": f"0x{args.expected_table_base:08X}",
        "flat_range": f"0x{flat_start:06X}..0x{flat_end - 1:06X}",
        "palettes": len(palettes),
        "headers": len(hdrs),
        "blocks": len(blocks),
        "bmod": bmod,
        "split": {
            "background_blocks": len(split["bg_blocks"]),
            "foreground_blocks": len(split["fg_blocks"]),
        } if split is not None else None,
        "render": render,
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "latest.json").write_text(json.dumps(summary, indent=2) + "\n")

    print("KFPITPL validation: OK")
    print(f"  payload: {len(payload):,} bytes at flat 0x{flat_start:06X}..0x{flat_end - 1:06X}")
    print(f"  table:   {len(hdrs)} headers, {len(palettes)} palettes, {len(blocks)} blocks")
    if split is not None:
        print(f"  split:   {len(split['bg_blocks'])} background blocks, {len(split['fg_blocks'])} foreground blocks")
    if render:
        print(f"  render:  {render['width']}x{render['height']} mismatches={render['mismatches']} "
              f"opaque={render['nontransparent']} colors={render['unique_rgba']}")
        print(f"  pngs:    {args.output_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckError as exc:
        print(f"KFPITPL validation: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
