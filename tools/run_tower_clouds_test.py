#!/usr/bin/env python3
"""THE TOWER's cloud rows: stock art vs mirrored draws - opportunity 17.

    python tools/run_tower_clouds_test.py --stock-rom-dir tmp/clear/rom --stock-map tmp/clear/mk2.map \\
                                          --flip-rom-dir tmp/clouds/rom --flip-map tmp/clouds/mk2.map

Boots tools/tower_clouds_test.lua on both ROMs - fighters hidden, the two
cloud rows drifting and wrapping on their own - and requires:

  same fight    both boots' PREARM lines equal (the attract automation is not
                deterministic under load; an unmatched pair is re-booted)
  identical     every snapshot pixel-identical between the ROMs, the floor
                reflection band included (backdrop_follow copies each cloud's
                oflags and ofset, so a mirrored cloud reflects mirrored)
  exercised     the flip ROM has mirrored clouds, and at least one snapshot
                caught a mirrored cloud edge-clipped - the swapped skip bytes
                actually drawn, not just assembled
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
SNAP_RE = re.compile(r"SNAP rel(\d+) clouds=(\d+) mirrored=(\d+) mirrored_clipped=(\d+) clipped=(\d+)")


def boot(mame, rom_dir, mapf, label, run, seconds):
    d = run / label
    fr = d / "frozen"
    (fr / "src").mkdir(parents=True)
    (fr / "rom").mkdir(parents=True)
    shutil.copy2(mapf, fr / "src/mk2.map")
    shutil.copy2(rom_dir / "mk2.zip", fr / "rom/mk2.zip")
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(fr), TC_LOG=str(d / "tc.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(fr / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/tower_clouds_test.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--stock-rom-dir", type=Path, required=True)
    ap.add_argument("--stock-map", type=Path, required=True)
    ap.add_argument("--flip-rom-dir", type=Path, required=True)
    ap.add_argument("--flip-map", type=Path, required=True)
    ap.add_argument("--attempts", type=int, default=4)
    ap.add_argument("--seconds", type=int, default=170)
    args = ap.parse_args()
    out = ROOT / "tmp/clouds/tests"
    out.mkdir(parents=True, exist_ok=True)
    jobs = {"stock": (args.stock_rom_dir, args.stock_map), "flip": (args.flip_rom_dir, args.flip_map)}
    for attempt in range(1, args.attempts + 1):
        run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
        with ThreadPoolExecutor(2) as pool:
            list(pool.map(lambda k: boot(args.mame, jobs[k][0], jobs[k][1], k, run, args.seconds), jobs))
        text = {k: (run / k / "tc.log").read_text(errors="replace") for k in jobs}
        pre = {k: (re.search(r"PREARM (.*)", t).group(1) if re.search(r"PREARM (.*)", t) else None) for k, t in text.items()}
        if pre["stock"] and pre["stock"] == pre["flip"]:
            print("attempt %d: both boots start identical (%s)" % (attempt, pre["stock"][:80]))
            break
        print("attempt %d: boots started differently (%s | %s) - re-booting" % (attempt, pre["stock"], pre["flip"]))
    else:
        print("FAIL: no matched pair")
        return 1

    shots = {k: sorted((run / k / "snap").rglob("*.png")) for k in jobs}
    snaps = {k: SNAP_RE.findall(text[k]) for k in jobs}
    ok = len(shots["stock"]) == len(shots["flip"]) == len(snaps["flip"]) > 0
    diffs, mirrored_clipped_snaps, mirrored_max = [], 0, 0
    for i in range(min(len(shots["stock"]), len(shots["flip"]))):
        a = Image.open(shots["stock"][i]).convert("RGB")
        b = Image.open(shots["flip"][i]).convert("RGB")
        if a.size != (400, 254) or b.size != (400, 254):
            raise ValueError("Expected complete 400x254 captures")
        pa, pb = a.load(), b.load()
        d = sum(1 for y in range(254) for x in range(400) if pa[x, y] != pb[x, y])
        diffs.append(d)
        s = snaps["flip"][i]
        mirrored_max = max(mirrored_max, int(s[2]))
        if int(s[3]) > 0:
            mirrored_clipped_snaps += 1
        if d and len([x for x in diffs if x]) <= 5:
            print("  snap %d rel%s differs by %d px (flip: mirrored %s, mirrored clipped %s)" % (i, s[0], d, s[2], s[3]))
    stock_mirrored = max((int(s[2]) for s in snaps["stock"]), default=0)
    ok &= not any(diffs) and mirrored_max > 0 and mirrored_clipped_snaps > 0 and stock_mirrored == 0
    report = dict(passed=ok, run=str(run), snapshots=len(diffs), differing_snapshots=len([d for d in diffs if d]),
                  max_diff_px=max(diffs, default=0), flip_mirrored_clouds=mirrored_max,
                  snapshots_with_a_mirrored_cloud_clipped=mirrored_clipped_snaps, stock_mirrored_clouds=stock_mirrored)
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("snapshots %d  differing %d (max %d px)  mirrored clouds %d  snapshots with a mirrored cloud clipped %d  stock mirrored %d"
          % (report["snapshots"], report["differing_snapshots"], report["max_diff_px"], mirrored_max,
             mirrored_clipped_snaps, stock_mirrored))
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
