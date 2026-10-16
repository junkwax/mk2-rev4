#!/usr/bin/env python3
"""Constant-colour fighter ghosts (ghost_rec, MKDISP.ASM) - opportunity 16.

    python tools/run_ghost_test.py --rom-dir tmp/ghosts/rom --map tmp/ghosts/mk2.map

Two boots of tools/ghost_test.lua against one frozen ROM, identical inputs,
P1 walking right then left.  Per snapshot:

  armed      every pixel that differs from the off boot is one of the ghost
             pens, exactly - a ghost is a silhouette in its age's colour and
             nothing else changes (the fighters, drawn after, are intact);
             and the ghost list holds gh_n entries once the ring is full.
  disarmed   identical to the off boot: nothing outlives gh_src going to 0.
  always     free objects and free processes equal between the two boots:
             the ghosts took neither.

Private cfg/NVRAM/snapshot directories under mame_mk2test.exe.
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
MODES = ("off", "on")


def boot(mame, frozen, mode, run, seconds, n, gap):
    d = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), GH_MODE=mode, GH_N=str(n), GH_GAP=str(gap), GH_LOG=str(d / "gh.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/ghost_test.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def rgb555(w):
    r, g, b = (w >> 10) & 31, (w >> 5) & 31, w & 31
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2))


SNAP_RE = re.compile(r"SNAP rel(\d+) frame=\d+ armed=(\d) ghosts=(-?\d+) objfree=(-?\d+) procfree=(-?\d+) p1x=(-?\d+) wx=(-?\d+)")


def judge(run):
    out = {}
    for m in MODES:
        text = (run / m / "gh.log").read_text(errors="replace")
        out[m] = (text, sorted((run / m / "snap").rglob("*.png")), SNAP_RE.findall(text))
    ok, report = True, {}
    for m in MODES:
        res = re.search(r"RESULT (.*)", out[m][0])
        print("%-3s snaps=%d  %s" % (m, len(out[m][1]), res.group(1) if res else "NO RESULT"))
        report[m + "_result"] = res.group(1) if res else None
        if not res or len(out[m][1]) != len(out[m][2]) or len(out[m][2]) != len(out["off"][2]):
            print("FAIL: %s snapshots/log mismatch" % m)
            ok = False
    if not ok:
        return 1
    n = int(re.search(r"n=(\d+)", out["on"][0]).group(1))
    pens = [rgb555(int(w, 16)) for _, w in re.findall(r"PEN age=(\d+) word=\w+ rgb555=(\w+)", out["on"][0])][:n]
    pen_set = set(pens)
    report["pens_rgb"] = pens
    total_ghost_px = 0
    best = (-1, None)
    for i, (on_s, off_s) in enumerate(zip(out["on"][2], out["off"][2])):
        rel, armed, ghosts = int(on_s[0]), on_s[1] == "1", int(on_s[2])
        a = Image.open(out["off"][1][i]).convert("RGB")
        b = Image.open(out["on"][1][i]).convert("RGB")
        if a.size != (400, 254) or b.size != (400, 254):
            raise ValueError("Expected complete 400x254 captures")
        pa, pb = a.load(), b.load()
        diff = unexplained = 0
        for y in range(254):
            for x in range(400):
                if pa[x, y] != pb[x, y]:
                    diff += 1
                    if pb[x, y] not in pen_set:
                        unexplained += 1
        pools_same = on_s[3:5] == off_s[3:5]
        camera_same = on_s[5:7] == off_s[5:7]
        if armed:
            this_ok = unexplained == 0 and pools_same and camera_same
            total_ghost_px += diff
            if diff > best[0]:
                best = (diff, i)
        else:
            this_ok = diff == 0 and ghosts == 0 and pools_same
        ok &= this_ok
        report["snap%02d" % i] = dict(rel=rel, armed=armed, ghosts_listed=ghosts, pixels_changed=diff,
                                      not_a_ghost_pen=unexplained, objfree=[int(on_s[3]), int(off_s[3])],
                                      procfree=[int(on_s[4]), int(off_s[4])], p1x=int(on_s[5]), passed=this_ok)
        print("snap %2d rel%d %s ghosts=%d  changed %5d  not-a-pen %d  objfree %s/%s  procfree %s/%s  p1x=%s  -> %s"
              % (i, rel, "armed   " if armed else "disarmed", ghosts, diff, unexplained, on_s[3], off_s[3],
                 on_s[4], off_s[4], on_s[5], "ok" if this_ok else "FAIL"))
    full = [int(s[2]) for s in out["on"][2] if s[1] == "1"]
    if total_ghost_px == 0 or max(full) != n:
        print("FAIL: ghosts never drew (%d px) or the list never reached %d (max %d)" % (total_ghost_px, n, max(full)))
        ok = False
    report.update(passed=ok, ghost_pixels_total=total_ghost_px, ghosts_max=max(full))
    if best[1] is not None:
        i = best[1]
        a = Image.open(out["off"][1][i]).convert("RGB")
        b = Image.open(out["on"][1][i]).convert("RGB")
        strip = Image.new("RGB", (808, 254), (255, 255, 255))
        strip.paste(a, (0, 0))
        strip.paste(b, (408, 0))
        strip.save(run / "ghosts_pair.png")
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


def prearm(run):
    """Both boots' PREARM lines, or None where one is missing.  The attract and
    select automation is scheduled on Lua frame callbacks and is NOT
    deterministic under load - 8 boots of one ROM reached 3 different fight
    starts - so a pair is only comparable if these match."""
    lines = {}
    for m in MODES:
        f = run / m / "gh.log"
        hit = re.search(r"PREARM (.*)", f.read_text(errors="replace")) if f.exists() else None
        lines[m] = hit.group(1) if hit else None
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--gap", type=int, default=3)
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--attempts", type=int, default=4, help="re-boot a pair that started differently")
    ap.add_argument("--rejudge", type=Path)
    args = ap.parse_args()
    if args.rejudge:
        pre = prearm(args.rejudge)
        if pre["on"] is not None and pre["on"] != pre["off"]:
            print("FAIL: the two boots started different fights: %s | %s" % (pre["off"], pre["on"]))
            return 1
        return judge(args.rejudge)
    out_dir = ROOT / "tmp/ghosts/tests"
    out_dir.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, args.attempts + 1):
        run = Path(tempfile.mkdtemp(prefix="run-", dir=out_dir))
        frozen = run / "frozen"
        (frozen / "src").mkdir(parents=True)
        (frozen / "rom").mkdir(parents=True)
        shutil.copy2(args.map, frozen / "src/mk2.map")
        shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")
        with ThreadPoolExecutor(len(MODES)) as pool:
            list(pool.map(lambda m: boot(args.mame, frozen, m, run, args.seconds, args.n, args.gap), MODES))
        pre = prearm(run)
        if pre["off"] is not None and pre["on"] == pre["off"]:
            print("attempt %d: both boots start identical (%s)" % (attempt, pre["off"]))
            return judge(run)
        print("attempt %d: the boots started different fights (%s | %s) - re-booting"
              % (attempt, pre["off"], pre["on"]))
    print("FAIL: no matched pair in %d attempts" % args.attempts)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
