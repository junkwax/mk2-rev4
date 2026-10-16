#!/usr/bin/env python3
"""cpu_patch (MKDISP.ASM) - small CPU pixel operations on the finished picture.

    python tools/run_cpu_patch_test.py --build tmp/cpu_patch/build
    python tools/run_cpu_patch_test.py --build tmp/cpu_patch/build --rect 80,80,64,64 --block 8

--build holds rom/mk2.zip and mk2.map.  Three boots of tools/cpu_patch_test.lua
on one frozen ROM, one after another (windowed -debug, private directories),
fighters parked, the rectangle over Liu Kang (P1) and the far planes behind him:

  none     nothing armed                                           (baseline)
  mosaic   BLOCK x BLOCK blocks -> inside, every pixel equals the baseline's
           pixel at its block's top-left corner
  stipple  pen PEN of colour map MAP on the (x+y)-odd checkerboard -> those
           pixels are the pen's colour and EVERY other pixel inside equals the
           baseline exactly: the untouched pixel of each word keeps its own
           palette selector through the word write

Outside the rectangle both armed modes must equal none, and the rel-460
capture (disarmed) must equal none over the whole screen in every mode.
The boots must agree on PREARM (fighter x, rand) before any pixel is judged.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MODES = ("none", "mosaic", "stipple")


def boot(mame, frozen, mode, args, run):
    d = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "go.ds").write_text("go\n", encoding="ascii")
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), CP_MODE=mode, CP_RECT=args.rect, CP_BLOCK=str(args.block),
               CP_PEN=str(args.pen), CP_MAP=str(args.map_sel), CP_LOG=str(d / "cp.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "gdi", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/cpu_patch_test.lua"), "-seconds_to_run", str(args.seconds),
            "-debug", "-debugscript", str(d / "go.ds"), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       timeout=args.seconds * 6 + 300, check=False)


def rgb555(w):
    r, g, b = (w >> 10) & 31, (w >> 5) & 31, w & 31
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2))


def judge(run, stip_refused=False):
    logs, snaps = {}, {}
    for m in MODES:
        p = run / m / "cp.log"
        logs[m] = p.read_text(errors="replace") if p.exists() else ""
        snaps[m] = sorted((run / m / "snap").rglob("*.png"))
    ok, report = True, {}
    prearm = {m: (re.search(r"PREARM (.*)", logs[m]) or [None, None])[1] for m in MODES}
    for m in MODES:
        res = re.search(r"RESULT (.*)", logs[m])
        print("%-7s snaps=%d  PREARM %s\n         %s" % (m, len(snaps[m]), prearm[m], res.group(1) if res else "NO RESULT"))
        report[m] = dict(result=res.group(1) if res else None, prearm=prearm[m])
        passes = int(re.search(r"passes=(\d+)", res.group(1)).group(1)) if res else -1
        refused = int(re.search(r"refused=(\d+)", res.group(1)).group(1)) if res else -1
        want = (passes == 0) if m == "none" else (passes > 0 and refused == 0)
        if m == "stipple" and stip_refused:
            want = passes == 0 and refused > 0
        if not want or len(snaps[m]) != 3:
            print("FAIL: %s ran the pass %d times (%d refused), %d snapshots" % (m, passes, refused, len(snaps[m])))
            ok = False
    if len(set(prearm.values())) != 1 or None in prearm.values():
        print("FAIL: the boots are not in step at PREARM - pixel comparison would mean nothing")
        ok = False
    if not ok:
        (run / "result.json").write_text(json.dumps(dict(report, passed=False), indent=2) + "\n", encoding="utf-8")
        return 1

    y0, x0, h, w, n, pen, cmap = map(int, re.search(
        r"rect y=(\d+) x=(\d+) h=(\d+) w=(\d+) block=(\d+) pen=(\d+) map=(\d+)", logs["stipple"]).groups())
    pen_rgb = np.array(rgb555(int(re.search(r"PEN .* colour=(\w+)", logs["stipple"]).group(1), 16)))
    inside = np.zeros((254, 400), bool)
    inside[y0:y0 + h, x0:x0 + w] = True
    yy, xx = np.mgrid[0:254, 0:400]
    stip = inside & (((xx + yy) & 1) == 1)
    kept = inside & ~stip

    for i in range(3):
        img = {m: np.asarray(Image.open(snaps[m][i]).convert("RGB")).astype(np.int16) for m in MODES}
        if any(a.shape != (254, 400, 3) for a in img.values()):
            raise ValueError("expected complete 400x254 captures")
        base = img["none"]
        diff = {m: np.any(img[m] != base, axis=2) for m in ("mosaic", "stipple")}
        armed = i < 2
        row = dict(armed=armed)
        if not armed:
            row.update(mosaic_vs_none=int(diff["mosaic"].sum()), stipple_vs_none=int(diff["stipple"].sum()))
            this_ok = row["mosaic_vs_none"] == 0 and row["stipple_vs_none"] == 0
        else:
            # mosaic: each block equals the baseline's top-left pixel of that block
            expect = base.copy()
            for by in range(y0, y0 + h, n):
                for bx in range(x0, x0 + w, n):
                    expect[by:by + n, bx:bx + n] = base[by, bx]
            mos_bad = int(np.any(img["mosaic"] != expect, axis=2)[inside].sum())
            mos_changed = int(diff["mosaic"][inside].sum())
            # stipple: pen on the checker, the baseline everywhere else
            st = img["stipple"]
            st_pen_bad = int(np.any(st != pen_rgb, axis=2)[stip].sum())
            st_kept_bad = int(diff["stipple"][kept].sum())
            kept_colours = len({tuple(c) for c in base[kept].tolist()})
            row.update(mosaic_outside=int(diff["mosaic"][~inside].sum()), mosaic_changed_inside=mos_changed,
                       mosaic_wrong=mos_bad, stipple_outside=int(diff["stipple"][~inside].sum()),
                       stipple_pen_wrong=st_pen_bad, stipple_pen_px=int(stip.sum()),
                       stipple_kept_changed=st_kept_bad, stipple_kept_px=int(kept.sum()),
                       kept_distinct_colours=kept_colours)
            stip_ok = row["stipple_outside"] == 0 and st_pen_bad == 0 and st_kept_bad == 0
            if stip_refused:  # refused whole: the stipple boot must equal the baseline everywhere
                row["stipple_vs_none"] = int(diff["stipple"].sum())
                stip_ok = row["stipple_vs_none"] == 0
            this_ok = row["mosaic_outside"] == 0 and mos_changed > 0 and mos_bad == 0 and stip_ok
            if i == 0:
                crop = (slice(max(0, y0 - 24), min(254, y0 + h + 24)), slice(max(0, x0 - 24), min(400, x0 + w + 24)))
                parts = [img[m][crop].astype(np.uint8) for m in MODES]
                gap = np.full((parts[0].shape[0], 6, 3), 255, np.uint8)
                strip = np.concatenate([parts[0], gap, parts[1], gap, parts[2]], axis=1)
                Image.fromarray(strip).resize((strip.shape[1] * 3, strip.shape[0] * 3), Image.NEAREST).save(
                    run / "cpu_patch_strip.png")
        row["passed"] = this_ok
        ok &= this_ok
        report["snap%d" % i] = row
        print("snap %d: %s -> %s" % (i, {k: v for k, v in row.items() if k not in ("armed", "passed")},
                                     "ok" if this_ok else "FAIL"))
    report.update(passed=ok, rect=[y0, x0, h, w], block=n, pen=pen, map=cmap)
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--build", type=Path, help="directory with rom/mk2.zip and mk2.map")
    ap.add_argument("--rect", default="100,96,32,32", help="y,x,h,w - x and w even, w and h multiples of --block")
    ap.add_argument("--block", type=int, default=4)
    ap.add_argument("--pen", type=int, default=14, help="stipple pen (14 = bpal_white)")
    ap.add_argument("--map-sel", type=int, default=0, help="stipple colour map (0 = boonpal)")
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--rejudge", type=Path, help="judge an existing run directory, no boots")
    ap.add_argument("--expect-stipple-refused", action="store_true",
                    help="the rectangle is over CP_STIPPX: the stipple must be refused whole")
    args = ap.parse_args()
    if args.rejudge:
        return judge(args.rejudge, args.expect_stipple_refused)
    out_dir = ROOT / "tmp/cpu_patch/tests"
    out_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=out_dir))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    shutil.copy2(args.build / "mk2.map", frozen / "src/mk2.map")
    shutil.copy2(args.build / "rom/mk2.zip", frozen / "rom/mk2.zip")
    for m in MODES:  # one at a time: concurrent rigs perturb each other's boots
        boot(args.mame, frozen, m, args, run)
    return judge(run, args.expect_stipple_refused)


if __name__ == "__main__":
    raise SystemExit(main())
