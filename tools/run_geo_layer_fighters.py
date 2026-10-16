#!/usr/bin/env python3
"""geo_layer depth against the FIGHTERS: a later display list, judged per boot.

    python tools/run_geo_layer_fighters.py --rom-dir tmp/geolayer/rom --map tmp/geolayer/mk2.map --pen 7

Two boots, fighters VISIBLE and parked apart, two full-width lines through
their bodies.  Frame timing can differ between boots, so nothing is compared
across boots - each is judged on its own snapshots:

  front   geo_pass at dsa9 is on top of everything: both rows are pen colour
          across the full width.
  layer   geo_layer sits before the fighters' lists: the rows are pen colour
          except where a fighter stands, and every gap falls inside a window
          around a fighter's logged screen x - OR is static stage art from
          a later list (baklst1/2, e.g. THE WASTELAND's rock ridge at row
          190): the same x in every snapshot, with the camera parked.
          Row 150 crosses only the fighters and the far planes, so it must
          have no static gaps at all.
"""
import argparse, os, re, shutil, subprocess, tempfile, json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from PIL import Image
ROOT = Path(__file__).resolve().parents[1]
ROWS = (150, 190)
HALF = 70            # a fighter's width either side of his anchor, generous

def boot(mame, frozen, mode, pen, run, seconds):
    d = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"): (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), GL_MODE=mode, GL_PEN=str(pen), GL_SHOW="1",
               GL_ROWS=",".join(map(str, ROWS)), GL_LOG=str(d / "gl.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for o, sub in (("cfg","cfg"),("nvram","nvram"),("snapshot","snap"),("state","state"),("input","input")):
        cmd += ["-" + o + "_directory", str(d / sub)]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/geo_layer_test.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), timeout=seconds + 240)
    text = (d / "gl.log").read_text(errors="replace")
    return text, sorted((d / "snap").rglob("*.png")), re.findall(r"SNAP \S+ frame=\d+ p1x=(-?\d+) p2x=(-?\d+)", text)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path, required=True); ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--pen", type=int, required=True); ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--rejudge", type=Path, help="judge an existing run directory, no boots")
    a = ap.parse_args()
    if a.rejudge:
        run = a.rejudge; res = {}
        for m in ("front", "layer"):
            text = (run / m / "gl.log").read_text(errors="replace")
            res[m] = (text, sorted((run / m / "snap").rglob("*.png")),
                      re.findall(r"SNAP \S+ frame=\d+ p1x=(-?\d+) p2x=(-?\d+)", text))
        return judge(run, res)
    out_dir = ROOT / "tmp/geolayer/tests"; out_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="fighters-", dir=out_dir)); fr = run / "frozen"
    (fr / "src").mkdir(parents=True); (fr / "rom").mkdir(parents=True)
    shutil.copy2(a.map, fr / "src/mk2.map"); shutil.copy2(a.rom_dir / "mk2.zip", fr / "rom/mk2.zip")
    with ThreadPoolExecutor(2) as pool:
        res = dict(zip(("front", "layer"), pool.map(lambda m: boot(a.mame, fr, m, a.pen, run, a.seconds), ("front", "layer"))))
    return judge(run, res)

def judge(run, res):
    ok, report = True, []
    # the pen's RGB: the majority colour of the front boot's line rows
    im0 = Image.open(res["front"][1][0]).convert("RGB")
    from collections import Counter
    pen_rgb = Counter(im0.getpixel((x, ROWS[0])) for x in range(im0.width)).most_common(1)[0][0]
    # static later-list art: layer gaps outside the fighters present in EVERY snapshot
    static = {}
    for y in ROWS:
        sets = []
        for i, png in enumerate(res["layer"][1]):
            im = Image.open(png).convert("RGB"); p1x, p2x = map(int, res["layer"][2][i])
            sets.append({x for x in range(im.width) if im.getpixel((x, y)) != pen_rgb
                         and not any(c - HALF <= x <= c + HALF for c in (p1x, p2x))})
        static[y] = set.intersection(*sets) if sets else set()
    for mode in ("front", "layer"):
        text, shots, pos = res[mode]
        for i, png in enumerate(shots):
            im = Image.open(png).convert("RGB"); p1x, p2x = map(int, pos[i])
            windows = [(p1x - HALF, p1x + HALF), (p2x - HALF, p2x + HALF)]
            for y in ROWS:
                gaps = [x for x in range(im.width) if im.getpixel((x, y)) != pen_rgb]
                inside = [x for x in gaps if any(lo <= x <= hi for lo, hi in windows)]
                outside = len([x for x in gaps if x not in inside and x not in static[y]])
                st = len([x for x in gaps if x in static[y]])
                rec = dict(mode=mode, snap=i, row=y, gaps=len(gaps), gaps_inside_fighters=len(inside),
                           gaps_static_stage=st, gaps_unexplained=outside, p1x=p1x, p2x=p2x)
                report.append(rec)
                good = (len(gaps) == 0) if mode == "front" else (
                    len(inside) > 0 and outside == 0 and (st > 0) == (y == ROWS[1]))
                ok &= good
                print("%-5s snap %d row %d: gaps %3d (fighters %3d, static stage %3d, unexplained %d)  p1x=%d p2x=%d  %s"
                      % (mode, i, y, len(gaps), len(inside), st, outside, p1x, p2x, "ok" if good else "FAIL"))
    (run / "result.json").write_text(json.dumps(dict(passed=ok, pen_rgb=pen_rgb, report=report), indent=2) + "\n")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run)); return 0 if ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
