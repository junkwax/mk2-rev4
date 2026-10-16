#!/usr/bin/env python3
"""reflect_p1p2 (MKDISP.ASM) - a stage's water reflection, graphics audit row 21.

    python tools/run_reflect_test.py --build tmp/reflect_fx/build

--build holds rom/mk2.zip and mk2.map.  Four boots of tools/reflect_test.lua on
THE DEAD POOL, one after another (windowed -debug, private directories):

  none     baseline, f_reflect never set
  stage    the stage's own record, f_reflect on FROM POWER-UP
  phase1   the same record with one phase (density comparison)
  flip     a mirror hung from the front acid strip

Gates, each against the none boot:
  leak     the attract and select captures are identical in every mode - the
           2026-08-20 version drew on exactly those screens
  band     every changed pixel of an armed capture lies on the record's band
           rows (ground_y - worldtly + top..bot) and is the pen's colour
  some     an armed capture changes at least one pixel
  off      the rel-460 capture (f_reflect cleared) is identical
  step     all four boots log the same PREARM line
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
MODES = ("none", "stage", "phase1", "flip")
BANDS = {"stage": (-28, -17), "phase1": (-28, -17), "flip": (22, 29)}


def boot(mame, frozen, mode, run, seconds):
    d = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "go.ds").write_text("go\n", encoding="ascii")
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), RF_MODE=mode, RF_LOG=str(d / "rf.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "gdi", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/reflect_test.lua"), "-seconds_to_run", str(seconds),
            "-debug", "-debugscript", str(d / "go.ds"), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       timeout=seconds * 6 + 300, check=False)


def rgb555(w):
    r, g, b = (w >> 10) & 31, (w >> 5) & 31, w & 31
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2))


def judge(run):
    logs = {m: (run / m / "rf.log").read_text(errors="replace") if (run / m / "rf.log").exists() else "" for m in MODES}
    snaps = {m: sorted((run / m / "snap").rglob("*.png")) for m in MODES}
    ok, report = True, {}
    pre = {m: (re.search(r"PREARM p1x=(\S+) p2x=(\S+) rand=(\S+)", logs[m]) or [None])[0] for m in MODES}
    for m in MODES:
        res = re.search(r"RESULT (.*)", logs[m])
        print("%-7s snaps=%d  %s\n        %s" % (m, len(snaps[m]), pre[m], res.group(1) if res else "NO RESULT"))
        report[m] = dict(result=res.group(1) if res else None, prearm=pre[m], snaps=len(snaps[m]))
        if len(snaps[m]) != 5 or not res:
            print("FAIL: %s has %d captures (want 2 pre-fight + 3) or no RESULT" % (m, len(snaps[m])))
            ok = False
    if len(set(pre.values())) != 1 or None in pre.values():
        print("FAIL: boots not in step at PREARM")
        ok = False
    if not ok:
        (run / "result.json").write_text(json.dumps(dict(report, passed=False), indent=2) + "\n")
        return 1
    pen = np.array(rgb555(int(re.search(r"PEN colour=(\w+)", logs["stage"]).group(1), 16)))
    img = {m: [np.asarray(Image.open(p).convert("RGB")).astype(np.int16) for p in snaps[m]] for m in MODES}
    geo = {m: [(int(a), int(b)) for a, b in re.findall(r"SNAP rel\d+ frame=\d+ ground_y=(-?\d+) wty=(-?\d+)", logs[m])]
           for m in MODES}
    for m in MODES[1:]:
        rows = {}
        for i in range(5):
            diff = np.any(img[m][i] != img["none"][i], axis=2)
            n = int(diff.sum())
            if i < 2:                                   # attract, select: the leak test
                rows["leak_%d" % i] = n
                good = n == 0
            elif i == 4:                                # rel 460, disarmed
                rows["off"] = n
                good = n == 0
            else:                                       # rel 400 / 430, armed
                g, wty = geo[m][i - 2]
                top, bot = BANDS[m]
                y0, y1 = g - wty + top, g - wty + bot
                ys, xs = np.nonzero(diff)
                outside = int(((ys < y0) | (ys > y1)).sum())
                wrong = int(np.any(img[m][i][diff] != pen, axis=1).sum())
                rows["armed_%d" % i] = dict(changed=n, band=[y0, y1], outside_band=outside, not_pen=wrong,
                                            rows=[int(ys.min()), int(ys.max())] if n else None)
                good = n > 0 and outside == 0 and wrong == 0
            ok &= good
        report[m].update(rows)
        print("%-7s %s" % (m, rows))
    a = report["stage"].get("armed_2", {}).get("changed", 0)
    b = report["phase1"].get("armed_2", {}).get("changed", 0)
    report["density_two_phases_vs_one"] = round(a / b, 2) if b else None
    print("density, two phases / one: %s (%d vs %d px)" % (report["density_two_phases_vs_one"], a, b))
    crop = (slice(150, 254), slice(0, 400))
    strip = np.concatenate([img[m][2][crop].astype(np.uint8) for m in MODES], axis=0)
    Image.fromarray(strip).resize((strip.shape[1] * 2, strip.shape[0] * 2), Image.NEAREST).save(run / "reflect_strip.png")
    report["passed"] = ok
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--build", type=Path)
    ap.add_argument("--seconds", type=int, default=240)
    ap.add_argument("--rejudge", type=Path)
    args = ap.parse_args()
    if args.rejudge:
        return judge(args.rejudge)
    out = ROOT / "tmp/reflect_fx/tests"
    out.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
    fr = run / "frozen"
    (fr / "src").mkdir(parents=True)
    (fr / "rom").mkdir()
    shutil.copy2(args.build / "mk2.map", fr / "src/mk2.map")
    shutil.copy2(args.build / "rom/mk2.zip", fr / "rom/mk2.zip")
    for m in MODES:
        boot(args.mame, fr, m, run, args.seconds)
    return judge(run)


if __name__ == "__main__":
    raise SystemExit(main())
