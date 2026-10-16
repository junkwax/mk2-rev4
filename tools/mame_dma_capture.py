#!/usr/bin/env python3
"""
Capture exact MAME Midway-DMA sprite renders for custom move work.

MAME 0.287 exposes a debugger command:

    midblit pngdma,1,<directory>,1

That command logs every unique DMA source as a PNG, with optional JSON metadata,
using MAME's real T-Unit blitter. This tool creates the debugger script, can
launch MAME, and then builds a small contact sheet for selected TBL labels.

Typical use:

    python tools/mame_dma_capture.py --launch --tbl src/NINJA2.TBL

Trigger the move in MAME, quit MAME, and inspect the emitted contact sheet.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import subprocess
from pathlib import Path


LABEL_RE = re.compile(r"^(\w+):\s*$")
WORD_RE = re.compile(r"^\s*\.word\s+(.+?)(?:\s*;.*)?$", re.IGNORECASE)
LONG_RE = re.compile(r"^\s*\.long\s+(.+?)(?:\s*;.*)?$", re.IGNORECASE)


def parse_int(token: str) -> int | None:
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


def split_values(line: str) -> list[str] | None:
    match = WORD_RE.match(line)
    if not match:
        return None
    return [item.strip() for item in match.group(1).split(",") if item.strip()]


def parse_tbl(path: Path) -> dict[str, dict[str, int | str | None]]:
    """Parse source-style or LOAD2-style image headers from a TBL file."""
    labels: dict[str, dict[str, int | str | None]] = {}
    current: str | None = None
    body: list[str] = []

    def flush() -> None:
        nonlocal current, body
        if current is None:
            return
        words = [line for line in body if WORD_RE.match(line)]
        longs = [line for line in body if LONG_RE.match(line)]
        if not words or not longs:
            current = None
            body = []
            return

        first_word = split_values(words[0]) or []
        first_long = LONG_RE.match(longs[0]).group(1).strip()
        sag = parse_int(first_long)

        # Normalized source layout:
        #   .word W,H,ANIX,ANIY / .long SAG / .word CTRL
        # Raw LOAD2 layout:
        #   .word W,H / .long SAG / .word ANIX,ANIY,CTRL
        w = h = anix = aniy = ctrl = None
        if len(first_word) >= 4:
            w, h, anix, aniy = (parse_int(x) for x in first_word[:4])
            if len(words) >= 2:
                ctrl_vals = split_values(words[1]) or []
                if ctrl_vals:
                    ctrl = parse_int(ctrl_vals[0])
        elif len(first_word) >= 2 and len(words) >= 2:
            w, h = (parse_int(x) for x in first_word[:2])
            ctrl_vals = split_values(words[1]) or []
            if len(ctrl_vals) >= 3:
                anix, aniy, ctrl = (parse_int(x) for x in ctrl_vals[:3])

        labels[current] = {
            "label": current,
            "w": w,
            "h": h,
            "anix": anix,
            "aniy": aniy,
            "sag": sag,
            "ctrl": ctrl,
        }
        current = None
        body = []

    for line in path.read_text(errors="replace").splitlines():
        label = LABEL_RE.match(line)
        if label:
            flush()
            current = label.group(1)
            body = []
        elif current is not None:
            if line.strip().upper().startswith(".TEXT"):
                flush()
            else:
                body.append(line)
    flush()
    return labels


def write_debug_script(path: Path, capture_dir: Path) -> None:
    mame_path = capture_dir.resolve().as_posix()
    path.write_text(
        "\n".join(
            [
                f"midblit pngdma,1,{mame_path},1",
                "g",
                "",
            ]
        )
    )


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig", errors="replace"))
    except Exception:
        return {}


def load_dma_captures(capture_dir: Path) -> dict[int, tuple[Path, dict]]:
    captures: dict[int, tuple[Path, dict]] = {}
    for json_path in capture_dir.glob("0x*.json"):
        meta = load_json(json_path)
        dma = meta.get("DMAState")
        if not isinstance(dma, dict):
            continue
        try:
            addr = int(json_path.stem, 16)
        except ValueError:
            continue
        png_path = json_path.with_suffix(".png")
        if png_path.exists():
            captures[addr] = (png_path, meta)
    return captures


def build_contact_sheet(
    capture_dir: Path,
    labels: dict[str, dict[str, int | str | None]],
    wanted: list[str],
    output: Path,
) -> None:
    try:
        from PIL import Image, ImageDraw
    except ImportError as exc:
        raise SystemExit("Pillow is required for contact sheets: pip install Pillow") from exc

    entries = []
    for name in wanted:
        info = labels.get(name)
        if not info:
            entries.append((name, None, None, None))
            continue
        sag = info.get("sag")
        png = capture_dir / f"0x{sag:08x}.png" if isinstance(sag, int) else None
        js = capture_dir / f"0x{sag:08x}.json" if isinstance(sag, int) else None
        entries.append((name, info, png if png and png.exists() else None, js if js and js.exists() else None))

    opened = []
    for name, info, png, js in entries:
        if png:
            image = Image.open(png).convert("RGBA")
        else:
            image = Image.new("RGBA", (96, 96), (32, 0, 0, 255))
            draw = ImageDraw.Draw(image)
            draw.rectangle((0, 0, 95, 95), outline=(255, 64, 64, 255), width=2)
            draw.text((8, 40), "missing", fill=(255, 220, 220, 255))
        opened.append((name, info, image, load_json(js) if js else {}))

    if not opened:
        raise SystemExit("No labels selected for contact sheet")

    cell_w = max(img.width for _, _, img, _ in opened) + 24
    cell_h = max(img.height for _, _, img, _ in opened) + 58
    cols = min(4, len(opened))
    rows = (len(opened) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (20, 20, 24, 255))
    draw = ImageDraw.Draw(sheet)

    for idx, (name, info, image, meta) in enumerate(opened):
        x = (idx % cols) * cell_w
        y = (idx // cols) * cell_h
        sag = info.get("sag") if info else None
        ctrl = info.get("ctrl") if info else None
        label = name
        detail = ""
        if isinstance(sag, int):
            detail = f"{sag:08X}"
            if isinstance(ctrl, int):
                detail += f" ctrl={ctrl:04X}"
        if meta:
            dma = meta.get("DMAState", {})
            bpp = dma.get("BitsPerPixel")
            if bpp is not None:
                detail += f" bpp={bpp}"

        draw.text((x + 8, y + 6), label, fill=(240, 240, 240, 255))
        draw.text((x + 8, y + 22), detail, fill=(180, 200, 255, 255))
        sheet.alpha_composite(image, (x + 12, y + 48))

    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)


def build_row_sheet(
    capture_dir: Path,
    labels: dict[str, dict[str, int | str | None]],
    wanted: list[str],
    output: Path,
) -> None:
    """Stack row-sized DMA captures within each label's SAG range.

    MAME's midblit logger dumps ZON-compressed sprites as many one-row source
    blits. The exact label SAG often corresponds to only the first row, so this
    sheet groups all captured rows until the next known label address.
    """
    try:
        from PIL import Image, ImageDraw
    except ImportError as exc:
        raise SystemExit("Pillow is required for contact sheets: pip install Pillow") from exc

    captures = load_dma_captures(capture_dir)
    sorted_sags = sorted(
        info["sag"]
        for info in labels.values()
        if isinstance(info.get("sag"), int)
    )

    def next_sag_after(sag: int) -> int | None:
        for candidate in sorted_sags:
            if candidate > sag:
                return candidate
        return None

    opened = []
    for name in wanted:
        info = labels.get(name)
        sag = info.get("sag") if info else None
        if not isinstance(sag, int):
            opened.append((name, info, None, 0, 0, "missing label"))
            continue

        end = next_sag_after(sag)
        if end is None:
            row_items = [(addr, item) for addr, item in captures.items() if addr == sag]
        else:
            row_items = [(addr, item) for addr, item in captures.items() if sag <= addr < end]
        row_items.sort(key=lambda item: item[0])

        rows = []
        max_w = 0
        total_h = 0
        for _, (png_path, meta) in row_items:
            image = Image.open(png_path).convert("RGBA")
            rows.append(image)
            max_w = max(max_w, image.width)
            total_h += image.height

        if not rows:
            opened.append((name, info, None, 0, 0, "no DMA rows"))
            continue

        stitched = Image.new("RGBA", (max_w, max(total_h, 1)), (0, 0, 0, 0))
        y = 0
        for row in rows:
            stitched.alpha_composite(row, (0, y))
            y += row.height
        opened.append((name, info, stitched, len(rows), total_h, ""))

    if not opened:
        return

    cell_w = max((img.width if img else 96) for _, _, img, _, _, _ in opened) + 24
    cell_h = max((img.height if img else 96) for _, _, img, _, _, _ in opened) + 74
    cols = min(4, len(opened))
    rows_count = (len(opened) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell_w, rows_count * cell_h), (20, 20, 24, 255))
    draw = ImageDraw.Draw(sheet)

    for idx, (name, info, image, row_count, stitched_h, note) in enumerate(opened):
        x = (idx % cols) * cell_w
        y = (idx // cols) * cell_h
        sag = info.get("sag") if info else None
        ctrl = info.get("ctrl") if info else None
        expected = ""
        if info and isinstance(info.get("w"), int) and isinstance(info.get("h"), int):
            expected = f" expected={info['w']}x{info['h']}"
        detail = ""
        if isinstance(sag, int):
            detail = f"{sag:08X}"
            if isinstance(ctrl, int):
                detail += f" ctrl={ctrl:04X}"
        rows_text = note or f"rows={row_count} h={stitched_h}{expected}"

        draw.text((x + 8, y + 6), name, fill=(240, 240, 240, 255))
        draw.text((x + 8, y + 22), detail, fill=(180, 200, 255, 255))
        draw.text((x + 8, y + 38), rows_text, fill=(190, 220, 190, 255))
        if image:
            sheet.alpha_composite(image, (x + 12, y + 64))
        else:
            draw.rectangle((x + 12, y + 64, x + 107, y + 159), outline=(255, 64, 64, 255), width=2)
            draw.text((x + 20, y + 104), "missing", fill=(255, 220, 220, 255))

    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mame", type=Path, default=Path(r"C:\MAME\mame.exe"))
    parser.add_argument("--rom", default="mk2")
    parser.add_argument("--rompath", type=Path, default=Path(r"C:\MAME\roms"))
    parser.add_argument("--tbl", type=Path, default=Path("src/NINJA2.TBL"))
    parser.add_argument("--labels", help="Comma-separated TBL labels to sheet; default = all labels in --tbl")
    parser.add_argument("--capture-dir", type=Path, help="Existing/new capture directory")
    parser.add_argument("--launch", action="store_true", help="Launch MAME with DMA PNG logging enabled")
    parser.add_argument("--window", action="store_true", default=True)
    parser.add_argument("--no-window", dest="window", action="store_false")
    parser.add_argument("--sheet", type=Path, help="Contact sheet output path")
    args = parser.parse_args()

    repo = Path.cwd()
    labels = parse_tbl(args.tbl)
    wanted = [item.strip() for item in args.labels.split(",")] if args.labels else list(labels)

    if args.capture_dir:
        capture_dir = args.capture_dir
    else:
        stamp = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
        capture_dir = repo / "tmp" / "mame_dma" / f"{args.tbl.stem.lower()}_{stamp}"
    capture_dir.mkdir(parents=True, exist_ok=True)

    debug_script = capture_dir / "capture.mdbg"
    write_debug_script(debug_script, capture_dir)

    print(f"Capture directory: {capture_dir}")
    print(f"Debug script:      {debug_script}")
    print("Debugger command:  midblit pngdma,1,<capture-dir>,1")

    if args.launch:
        cmd = [
            str(args.mame),
            args.rom,
            "-rompath",
            str(args.rompath),
            "-skip_gameinfo",
            "-debug",
            "-debugscript",
            str(debug_script),
        ]
        if args.window:
            cmd.append("-window")
        print("Launching MAME. Trigger the move, then quit MAME to build the contact sheet.")
        subprocess.run(cmd, check=False)

    output = args.sheet or (capture_dir / "contact_sheet.png")
    build_contact_sheet(capture_dir, labels, wanted, output)
    print(f"Contact sheet: {output}")
    row_output = output.with_name(f"{output.stem}_rows{output.suffix}")
    build_row_sheet(capture_dir, labels, wanted, row_output)
    print(f"Row sheet:     {row_output}")

    missing = []
    for name in wanted:
        info = labels.get(name)
        sag = info.get("sag") if info else None
        if not isinstance(sag, int) or not (capture_dir / f"0x{sag:08x}.png").exists():
            missing.append(name)
    if missing:
        print("Missing captures:", ", ".join(missing))
        print("That means MAME did not DMA those labels during the captured run.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
