#!/usr/bin/env python3
"""
video_frames.py - turn a gameplay clip into contact sheets an LLM can read.

Claude cannot watch video. It CAN read images, so the way to share a combo is
to sample frames and tile them, with a timestamp burned into each tile so the
resulting discussion can talk about real timings ("at 1.20s he lands the
uppercut") instead of vague ordering.

    python tools/video_frames.py "C:/path/clip.mp4"
    python tools/video_frames.py clip.mp4 --fps 20 --grid 4x3 --width 480

Output goes to a per-clip folder under --out (default: the session scratchpad
if it exists, else tmp/video). Sheets are named sheet_00.png, sheet_01.png ...
in time order.

Notes
  * --fps is the SAMPLE rate, not the clip's rate. 10-15 is plenty for reading
    a combo's structure; go to 30+ only when exact frame counts matter.
  * Keep --width high enough that sprites stay legible; 480 is the floor for
    a 1920-wide capture.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

FFMPEG = shutil.which("ffmpeg") or r"C:\ffmpeg\bin\ffmpeg.exe"
FFPROBE = shutil.which("ffprobe") or r"C:\ffmpeg\bin\ffprobe.exe"


def probe(path):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate",
         "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=0", str(path)],
        capture_output=True, text=True).stdout
    info = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info.setdefault(k, v)
    return info


def default_out():
    scratch = os.environ.get("CLAUDE_SCRATCHPAD")
    if scratch and Path(scratch).is_dir():
        return Path(scratch) / "video"
    return Path("tmp") / "video"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--fps", type=float, default=12.0, help="sample rate (default 12)")
    ap.add_argument("--grid", default="3x3", help="tiles per sheet, COLSxROWS (default 3x3)")
    ap.add_argument("--width", type=int, default=640, help="tile width px (default 640)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--start", type=float, default=None, help="clip start seconds")
    ap.add_argument("--dur", type=float, default=None, help="seconds to take")
    args = ap.parse_args()

    src = Path(args.video)
    if not src.exists():
        sys.exit(f"no such video: {src}")
    if not Path(FFMPEG).exists() and not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found")

    info = probe(src)
    print(f"{src.name}: {info.get('width')}x{info.get('height')} "
          f"{info.get('r_frame_rate')} dur={info.get('duration')}")

    out_root = Path(args.out) if args.out else default_out()
    out = out_root / src.stem.replace(" ", "_")
    if out.exists():
        shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)

    cols, rows = (int(x) for x in args.grid.lower().split("x"))

    # Burn the source timestamp into each tile. drawtext needs a font; fall
    # back to no text rather than failing the whole extraction, because the
    # sheets are still useful without it.
    font = None
    for cand in (r"C\:/Windows/Fonts/consola.ttf", r"C\:/Windows/Fonts/arial.ttf"):
        raw = cand.replace("\\", "")
        if Path(raw).exists():
            font = cand
            break

    vf = [f"fps={args.fps}", f"scale={args.width}:-1"]
    if font:
        vf.append(
            f"drawtext=fontfile='{font}':text='%{{pts\\:hms}}':"
            f"x=6:y=6:fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.6"
        )
    vf.append(f"tile={cols}x{rows}:margin=4:padding=4:color=0x202020")

    cmd = [FFMPEG, "-v", "error", "-y"]
    if args.start is not None:
        cmd += ["-ss", str(args.start)]
    cmd += ["-i", str(src)]
    if args.dur is not None:
        cmd += ["-t", str(args.dur)]
    cmd += ["-vf", ",".join(vf), str(out / "sheet_%02d.png")]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:2000])
        sys.exit("ffmpeg failed")

    sheets = sorted(out.glob("sheet_*.png"))
    per = cols * rows
    print(f"{len(sheets)} sheet(s), {per} frames each @ {args.fps} fps -> {out}")
    for i, s in enumerate(sheets):
        t0 = i * per / args.fps + (args.start or 0)
        t1 = (i + 1) * per / args.fps + (args.start or 0)
        print(f"  {s}   covers {t0:5.2f}s - {t1:5.2f}s")


if __name__ == "__main__":
    main()
