#!/usr/bin/env python3
"""Kitana's boomerang fan turning in flight: old ROM vs new ROM.

    python tools/run_fan_flip_ab.py --old-rom-dir tmp/clouds/rom --old-map tmp/clouds/mk2.map \\
                                    --new-rom-dir tmp/kt2arm/rom --new-map tmp/kt2arm/mk2.map

Boots tools/fan_flip_ab.lua on both ROMs (windowed under MAME's debugger by
default; --fullscreen to opt out) and requires:

  exercised   the new ROM threw the fan and saw it change facing in flight
  new         the new ROM never shows a piece flip disagreeing with the fan
              object's: fan_turn re-lays the pieces with ani2 on the tick the
              facing changes, and dclipl draws the piece's flip
  identical   when the old ROM turned on the same tick too, every snapshot
              around the turn is pixel-identical between the two ROMs

The old ROM is reference only.  Before the fan_at_turn_line fix (a jrn that
read N from worldtlx) a LEFT throw never turned, so there is nothing to
pair and the pixel check is skipped.  Measured 0 on both
sides: fan_proc animates at init_anirate 1, so next_anirate re-lays the pieces
every tick and fanp_turn's flip write is always followed by one before the
next sleep.  --side left throws from the right half of the screen.

Snapshots around the first turn are paired into a strip for review.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def boot(mame, rom_dir, mapf, label, run, seconds, windowed, side):
    d = run / label
    fr = d / "frozen"
    (fr / "src").mkdir(parents=True)
    (fr / "rom").mkdir(parents=True)
    shutil.copy2(mapf, fr / "src/mk2.map")
    shutil.copy2(rom_dir / "mk2.zip", fr / "rom/mk2.zip")
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(fr), FF_LOG=str(d / "ff.log"), FF_SIDE=side)
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(fr / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/fan_flip_ab.lua"), "-seconds_to_run", str(seconds)]
    if windowed:
        ds = d / "go.ds"
        ds.write_text("go" + chr(10), encoding="ascii")
        cmd += ["-debug", "-debugscript", str(ds), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 600, check=False)
    text = (d / "ff.log").read_text(errors="replace") if (d / "ff.log").exists() else ""
    res = re.search(r"RESULT fan_frames=(\d+) turns=(\d+) mismatch_frames=(\d+) first_turn=(\w+)", text)
    return dict(label=label, dir=str(d),
                result=dict(fan_frames=int(res.group(1)), turns=int(res.group(2)), mismatch_frames=int(res.group(3)),
                            first_turn=res.group(4)) if res else None,
                turns=re.findall(r"TURN rel=(\d+) oflip (\d)->(\d)", text),
                mismatches=re.findall(r"FAN rel=(\d+) .* MISMATCH", text),
                snaps=re.findall(r"SNAP rel=(\d+)", text))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--old-rom-dir", type=Path, required=True)
    ap.add_argument("--old-map", type=Path, required=True)
    ap.add_argument("--new-rom-dir", type=Path, required=True)
    ap.add_argument("--new-map", type=Path, required=True)
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--fullscreen", action="store_true", help="do not run windowed under the debugger")
    ap.add_argument("--side", choices=("right", "left"), default="right", help="which way Kitana throws")
    args = ap.parse_args()
    out = ROOT / "tmp/fanflip/tests"
    out.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-%s-" % args.side, dir=out))
    jobs = (("old", args.old_rom_dir, args.old_map), ("new", args.new_rom_dir, args.new_map))
    with ThreadPoolExecutor(2) as pool:
        reps = dict((r["label"], r) for r in pool.map(
            lambda j: boot(args.mame, j[1], j[2], j[0], run, args.seconds, not args.fullscreen, args.side), jobs))
    for lab in ("old", "new"):
        r = reps[lab]
        print("%-3s %s  turns %s  mismatch rels %s" % (lab, r["result"], r["turns"][:4], r["mismatches"][:8]))
    new, old = reps["new"]["result"], reps["old"]["result"]
    # the new ROM must throw, turn, and never show a piece behind the object;
    # the old ROM is reference only (before the fan_at_turn_line fix a LEFT
    # throw never turns at all)
    ok = bool(new) and new["fan_frames"] > 0 and new["turns"] > 0 and new["mismatch_frames"] == 0
    same_turn = bool(old) and old["turns"] > 0 and bool(new) and old["first_turn"] == new["first_turn"]
    if not same_turn:
        print("old ROM %s - turn window not pixel-compared" %
              ("did not turn" if not old or old["turns"] == 0 else "turned on a different tick"))
    pixel_diffs = []
    # pair the snapshots taken around the first turn (same rel in both boots when the turn lines up)
    try:
        so = sorted(Path(reps["old"]["dir"], "snap").rglob("*.png"))
        sn = sorted(Path(reps["new"]["dir"], "snap").rglob("*.png"))
        n = min(len(so), len(sn), 13)
        if n:
            W, H = 400, 254
            strip = Image.new("RGB", (W * 3 + 16, H * n), (255, 255, 255))
            for i in range(n):
                a = Image.open(so[i]).convert("RGB"); b = Image.open(sn[i]).convert("RGB")
                m = Image.new("RGB", (W, H), (0, 0, 0)); pm, pa, pb = m.load(), a.load(), b.load()
                d = 0
                for y in range(H):
                    for x in range(W):
                        if pa[x, y] != pb[x, y]:
                            pm[x, y] = (255, 0, 0)
                            d += 1
                pixel_diffs.append(d)
                strip.paste(a, (0, H * i)); strip.paste(b, (W + 8, H * i)); strip.paste(m, (2 * W + 16, H * i))
            strip.save(run / "fan_turn_strip.png")
            print("strip: %s (%d rows: old | new | diff)  differing px per pair %s" % (run / "fan_turn_strip.png", n, pixel_diffs))
    except Exception as e:
        print("strip failed: %s" % e)
    if same_turn and (not pixel_diffs or any(pixel_diffs)):
        ok = False
    (run / "result.json").write_text(json.dumps(dict(passed=ok, side=args.side, turn_pixel_diffs=pixel_diffs, reports=reps),
                                                indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
