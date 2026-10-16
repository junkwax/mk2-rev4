#!/usr/bin/env python3
"""
Simulate and render the visual effect from AOUTHAV.ASM.

This script recreates the "Blue Vortex" background effect described in the
TMS34010 assembly source. It operates in two phases, just like the original:

1.  **Static Map Generation**: Creates a 400x228 map of color indices based
    on a geometric formula. This is done once.
2.  **Animated Rendering**: Generates frames of an animation by simulating
    the per-scanline palette shifting described in the assembly's main loop.

The final output is an animated GIF named 'aouthav_vortex.gif'.

Requires: Pillow, numpy
  pip install Pillow numpy
"""
import argparse
from pathlib import Path
import numpy as np
from PIL import Image

WIDTH, HEIGHT = 400, 228
CENTER_X, CENTER_Y = 200, 114

def generate_static_map() -> np.ndarray:
    """
    Generates the 400x228 8-bit index map based on the formula in
    the AOUTHAV.ASM static generation loop.
    """
    print("Generating static index map...")
    x_coords = np.arange(WIDTH).reshape(1, WIDTH)
    y_coords = np.arange(HEIGHT).reshape(HEIGHT, 1)

    dx = x_coords - CENTER_X
    dy = y_coords - CENTER_Y

    dist_sq = dx**2 + dy**2

    # Vectorized implementation of the assembly logic
    a1 = (x_coords * dist_sq) >> 8
    a1 &= 0x1F
    a2 = dist_sq >> 6
    a1 += a2
    a1 = ~a1
    a1 &= 0x1F
    a1 += 1

    # Apply the black core mask
    black_core_mask = dist_sq < 576
    a1[black_core_mask] = 0

    return a1.astype(np.uint8)

def bgr555_to_rgba(val: int) -> tuple[int, int, int, int]:
    """Converts a 15-bit BGR555 color to an RGBA tuple."""
    r = ((val >> 10) & 0x1F) * 8
    g = ((val >> 5) & 0x1F) * 8
    b = (val & 0x1F) * 8
    return r, g, b, 255

def render_frame(static_map: np.ndarray, time_idx: int) -> Image.Image:
    """
    Renders a single frame of the animation by applying per-scanline
    palette shifts.
    """
    rgba_frame = np.zeros((HEIGHT, WIDTH, 4), dtype=np.uint8)

    for y in range(HEIGHT):
        # 1. Generate the palette for this specific scanline
        palette = np.zeros((33, 4), dtype=np.uint8)
        palette[0] = [0, 0, 0, 255]  # Color 0 is always black

        # This implements the color formula from the raster loop
        phase_offset = (y + time_idx) & 0x1F
        
        for i in range(1, 33):
            intensity_idx = (i + phase_offset) & 0x1F
            intensity = intensity_idx << 3

            # Recreate the "Max Blue, Med Green, Zero Red" color scheme
            b5 = (intensity >> 3) & 0x1F
            g5 = ((intensity // 2) >> 3) & 0x1F
            r5 = 0
            
            bgr555 = (r5 << 10) | (g5 << 5) | b5
            palette[i] = bgr555_to_rgba(bgr555)

        # 2. Apply the palette to the static index map for this row
        row_indices = static_map[y, :]
        rgba_frame[y, :, :] = palette[row_indices]

    return Image.fromarray(rgba_frame, 'RGBA')

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("-o", "--output", type=Path, default=Path("aouthav_vortex.gif"), help="Output GIF file path.")
    parser.add_argument("-f", "--frames", type=int, default=60, help="Number of frames to render.")
    parser.add_argument("-d", "--duration", type=int, default=33, help="Frame duration in milliseconds (33ms ≈ 30fps).")
    parser.add_argument("-s", "--speed", type=int, default=0x0028, help="Fixed-point velocity step per frame (from ASM).")
    args = parser.parse_args()

    static_map = generate_static_map()

    frames = []
    time_accumulator = 0
    print(f"Rendering {args.frames} frames...")
    for i in range(args.frames):
        time_accumulator += args.speed
        time_idx = time_accumulator >> 16

        print(f"  Frame {i+1}/{args.frames} (time_idx={time_idx})...")
        frame_img = render_frame(static_map, time_idx)
        frames.append(frame_img)

    print(f"Saving animated GIF to {args.output}...")
    frames[0].save(
        args.output,
        save_all=True,
        append_images=frames[1:],
        optimize=False,
        duration=args.duration,
        loop=0
    )
    print("Done.")

if __name__ == "__main__":
    main()