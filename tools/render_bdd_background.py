#!/usr/bin/env python3
"""Render a Midway BDD/BDB background composite to a PNG.

This is an offline sanity check for the BLIMP/BDD source data before LOAD2 and
MAME packaging. It follows BDB object order, palette selection, transparency
index 0, and raw BDD tile pixels.
"""
from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path


def read_line(data: bytes, pos: int) -> tuple[str, int]:
    while pos < len(data) and data[pos] in (10, 13):
        pos += 1
    end = data.find(b"\n", pos)
    if end < 0:
        raise ValueError("unterminated text line in BDD")
    line = data[pos:end].decode("ascii", errors="replace").rstrip("\r")
    return line, end + 1


def bgr555_to_rgba(value: int) -> tuple[int, int, int, int]:
    r = ((value >> 10) & 0x1F) << 3
    g = ((value >> 5) & 0x1F) << 3
    b = (value & 0x1F) << 3
    return r, g, b, 255


def load_bdd(path: Path):
    data = path.read_bytes()
    pos = 0
    line, pos = read_line(data, pos)
    image_count = int(line)

    images = {}
    for _ in range(image_count):
        line, pos = read_line(data, pos)
        idx_s, w_s, h_s, flags_s = line.split()
        idx = int(idx_s, 16)
        width = int(w_s)
        height = int(h_s)
        size = width * height
        pixels = data[pos : pos + size]
        if len(pixels) != size:
            raise ValueError(f"truncated pixel data for image {idx_s}")
        pos += size
        images[idx] = {
            "width": width,
            "height": height,
            "flags": int(flags_s),
            "pixels": pixels,
        }

    palettes = []
    while pos < len(data):
        line, pos = read_line(data, pos)
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError(f"bad palette header: {line!r}")
        name, count_s = parts
        count = int(count_s)
        colors = []
        for _ in range(count):
            if pos + 2 > len(data):
                raise ValueError(f"truncated palette data for {name}")
            value = struct.unpack_from("<H", data, pos)[0]
            pos += 2
            colors.append(bgr555_to_rgba(value))
        palettes.append((name, colors))

    return images, palettes


def load_bdb(path: Path):
    lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
    header = lines[0].split()
    if len(header) != 7:
        raise ValueError(f"bad BDB header: {lines[0]!r}")
    name = header[0]
    world_w = int(header[1])
    world_h = int(header[2])
    module_count = int(header[4])
    object_count = int(header[6])

    objects = []
    for line in lines[1 + module_count : 1 + module_count + object_count]:
        wx_s, depth_s, sy_s, ii_s, fl_s = line.split()
        objects.append(
            {
                "wx": int(wx_s, 16),
                "x": int(depth_s),
                "y": int(sy_s),
                "idx": int(ii_s, 16),
                "palette": int(fl_s),
            }
        )

    return name, world_w, world_h, objects


def layer_name(obj: dict) -> str:
    high = obj["wx"] >> 8
    if high == 0x32:
        return "p_bg"
    if high == 0x3C:
        return "p_1"
    if high == 0x40:
        return "p_2"
    return f"wx_{high:02x}"


def draw_objects(
    rgba: bytearray,
    width: int,
    height: int,
    images: dict,
    palettes: list,
    objects: list,
    x_offset: int = 0,
) -> None:
    for obj in objects:
        image = images[obj["idx"]]
        _palette_name, palette = palettes[obj["palette"]]
        pixels = image["pixels"]
        img_w = image["width"]
        img_h = image["height"]
        for yy in range(img_h):
            dst_y = obj["y"] + yy
            if dst_y < 0 or dst_y >= height:
                continue
            for xx in range(img_w):
                dst_x = obj["x"] + xx - x_offset
                if dst_x < 0 or dst_x >= width:
                    continue
                pal_idx = pixels[yy * img_w + xx]
                if pal_idx == 0 or pal_idx >= len(palette):
                    continue
                off = (dst_y * width + dst_x) * 4
                rgba[off : off + 4] = bytes(palette[pal_idx])


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)


def write_png(path: Path, width: int, height: int, rgba: bytearray) -> None:
    rows = bytearray()
    stride = width * 4
    for y in range(height):
        rows.append(0)
        start = y * stride
        rows.extend(rgba[start : start + stride])
    try:
        from PIL import Image
    except ImportError:
        raise ImportError("Pillow is required for PNG output. Please run: pip install Pillow")
    im = Image.frombytes("RGBA", (width, height), bytes(rgba))
    im.save(path, "PNG")

    payload = bytearray()
    payload.extend(b"\x89PNG\r\n\x1a\n")
    payload.extend(png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
    payload.extend(png_chunk(b"IDAT", zlib.compress(bytes(rows), level=9)))
    payload.extend(png_chunk(b"IEND", b""))
    path.write_bytes(payload)


def render(
    bdb_path: Path,
    bdd_path: Path,
    output: Path,
    width: int | None,
    height: int | None,
    viewport: int | None,
    worldx: int,
    fixed_layers: set[str],
    skip_layers: set[str],
) -> None:
    images, palettes = load_bdd(bdd_path)
    name, world_w, world_h, objects = load_bdb(bdb_path)
    objects = [obj for obj in objects if layer_name(obj) not in skip_layers]

    if viewport is not None:
        width = viewport
    elif width is None:
        width = max(world_w, max(obj["x"] + images[obj["idx"]]["width"] for obj in objects))
    if height is None:
        height = max(world_h, max(obj["y"] + images[obj["idx"]]["height"] for obj in objects))

    rgba = bytearray(width * height * 4)
    if viewport is None:
        draw_objects(rgba, width, height, images, palettes, objects)
    else:
        fixed = [obj for obj in objects if layer_name(obj) in fixed_layers]
        scrolling = [obj for obj in objects if layer_name(obj) not in fixed_layers]
        draw_objects(rgba, width, height, images, palettes, fixed, x_offset=0)
        draw_objects(rgba, width, height, images, palettes, scrolling, x_offset=worldx)

    output.parent.mkdir(parents=True, exist_ok=True)
    write_png(output, width, height, rgba)
    print(f"Rendered {name}: {width}x{height} -> {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Render a BDB/BDD background composite to PNG")
    parser.add_argument("bdb", type=Path)
    parser.add_argument("bdd", type=Path)
    parser.add_argument("-o", "--output", type=Path, default=Path("tmp/bdd_background.png"))
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--viewport", type=int, help="Render a clipped viewport width")
    parser.add_argument("--worldx", type=lambda value: int(value, 0), default=0,
                        help="World X offset for scrolling layers when --viewport is used")
    parser.add_argument("--fixed-layer", action="append", default=[],
                        help="Layer name to keep screen-fixed in viewport mode, e.g. p_bg")
    parser.add_argument("--skip-layer", action="append", default=[],
                        help="Layer name to omit, e.g. p_bg, p_1, or p_2")
    args = parser.parse_args()
    render(
        args.bdb,
        args.bdd,
        args.output,
        args.width,
        args.height,
        args.viewport,
        args.worldx,
        set(args.fixed_layer),
        set(args.skip_layer),
    )


if __name__ == "__main__":
    main()
