#!/usr/bin/env python3
"""Background strip distortion (strip_layer, MKDISP.ASM) - prototype #8.

    python tools/run_strips_test.py --rom-dir tmp/strips/rom --map tmp/strips/mk2.map
    python tools/run_strips_test.py --rom-dir tmp/strips/rom --map tmp/strips/mk2.map --motion

Boots of tools/strips_test.lua against one frozen ROM - THE WASTELAND,
baklst6 the banded list - and per snapshot:

  zero == base        8 bands at offset 0 draw exactly the ordinary list:
                      no seam, no gap, no doubled row, the DMA clip and the
                      software window come back for every later list.
  plus != base        the banded list is really on screen (else the rest of
                      the test proves nothing).
  alt, band k rows    == plus (k even) or minus (k odd): each band moved by
                      exactly its own offset, and every LATER list (castle,
                      floor, near planes, fighters) over those rows is
                      untouched - the distortion is background-only.
  alt, other rows     == base.

Default: fighters hidden and parked, camera still, three snapshots, six boots
(the sixth, `wave`, only feeds the strip image).  --motion: fighters visible
and walking right then left, so the camera scrolls and they cross the band
rows; fifteen snapshots, five boots.  It also requires the camera to have
moved, and reports whether any baklst6 object carried a velocity (the
velocity-once rule is only exercised if one did).

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
MODES = ("base", "zero", "plus", "minus", "alt", "wave")
MOTION_MODES = ("base", "zero", "plus", "minus", "alt")


def boot(mame, frozen, mode, run, seconds, top, h, n, d, motion):
    dd = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (dd / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), ST_MODE=mode, ST_TOP=str(top), ST_H=str(h), ST_N=str(n),
               ST_D=str(d), ST_MOTION="1" if motion else "0", ST_LOG=str(dd / "st.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(frozen / "rom"), "-inipath", str(dd / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(dd / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/strips_test.lua"), "-seconds_to_run", str(seconds)]
    with (dd / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def judge(run):
    modes = tuple(m for m in MODES if (run / m / "st.log").exists())
    out = {}
    for m in modes:
        text = (run / m / "st.log").read_text(errors="replace")
        out[m] = (text, sorted((run / m / "snap").rglob("*.png")))
    motion = "motion=1" in out["base"][0]
    snaps = re.findall(r"SNAP rel(\d+) frame=\d+(?: wx=(-?\d+) wx6=(-?\d+) objs=(-?\d+) moving=(-?\d+))?",
                       out["base"][0])
    nsnap = len(snaps)
    ok, report = nsnap > 0, {"motion": motion, "snapshots": nsnap}
    for m in modes:
        res = re.search(r"RESULT (.*)", out[m][0])
        line = res.group(1) if res else "NO RESULT"
        print("%-5s snaps=%d  %s" % (m, len(out[m][1]), line))
        report[m + "_result"] = line
        banded = int(re.search(r"banded=(\d+)", line).group(1)) if res else -1
        refused = int(re.search(r"refused=(\d+)", line).group(1)) if res else -1
        if len(out[m][1]) != nsnap or refused != 0 or (banded == 0) != (m == "base"):
            print("FAIL: %s banded=%d refused=%d snaps=%d (want %d)" % (m, banded, refused, len(out[m][1]), nsnap))
            ok = False
    if not ok:
        return 1
    # every boot must have seen the same camera, or the frames are not comparable
    for m in modes:
        if re.findall(r"SNAP rel\d+ frame=\d+ wx=(-?\d+)", out[m][0]) != [s[1] for s in snaps if s[1]]:
            print("FAIL: %s saw a different camera than base" % m)
            ok = False
    wxs = [int(s[1]) for s in snaps if s[1]]
    if motion:
        report["camera_range"] = [min(wxs), max(wxs)]
        report["baklst6_objects"] = max(int(s[3]) for s in snaps)
        report["baklst6_moving_max"] = max(int(s[4]) for s in snaps)
        print("camera x %d..%d, baklst6 objects %d, with velocity at a snapshot: %d"
              % (min(wxs), max(wxs), report["baklst6_objects"], report["baklst6_moving_max"]))
        if max(wxs) == min(wxs):
            print("FAIL: the camera never moved")
            ok = False
    top, h, n = map(int, re.search(r"top=(\d+) h=(\d+) n=(\d+)", out["alt"][0]).groups())
    band_of = {}
    for k in range(n):
        for y in range(top + k * h, min(top + (k + 1) * h, 254)):
            band_of[y] = k

    for i in range(nsnap):
        img = {m: Image.open(out[m][1][i]).convert("RGB") for m in modes}
        if any(im.size != (400, 254) for im in img.values()):
            raise ValueError('Expected complete 400x254 captures in every mode')
        W, Hh = img["base"].size
        px = {m: img[m].load() for m in modes}
        b = px["base"]
        zero_diff = sum(1 for y in range(Hh) for x in range(W) if px["zero"][x, y] != b[x, y])
        plus_moved = sum(1 for y in range(Hh) for x in range(W) if px["plus"][x, y] != b[x, y])
        in_bad = out_bad = 0
        bad_rows = set()
        for y in range(Hh):
            if y in band_of:
                ref = px["plus"] if band_of[y] % 2 == 0 else px["minus"]
            else:
                ref = b
            for x in range(W):
                if px["alt"][x, y] != ref[x, y]:
                    bad_rows.add(y)
                    if y in band_of:
                        in_bad += 1
                    else:
                        out_bad += 1
        this_ok = zero_diff == 0 and plus_moved > 0 and in_bad == 0 and out_bad == 0
        ok &= this_ok
        report["snap%d" % i] = dict(rel=int(snaps[i][0]), camera_x=int(snaps[i][1]) if snaps[i][1] else None,
                                    zero_vs_base=zero_diff, plus_vs_base=plus_moved,
                                    alt_band_rows_wrong=in_bad, alt_other_rows_wrong=out_bad,
                                    wrong_rows=sorted(bad_rows)[:40], passed=this_ok)
        print("snap %2d rel%s%s: zero-vs-base %d  plus-moved %d  alt: band rows wrong %d, other rows wrong %d%s  -> %s"
              % (i, snaps[i][0], (" wx=" + snaps[i][1]) if snaps[i][1] else "", zero_diff, plus_moved,
                 in_bad, out_bad, ("  rows " + ",".join(map(str, sorted(bad_rows)[:12]))) if bad_rows else "",
                 "ok" if this_ok else "FAIL"))
        if i == 0 and "wave" in modes:
            crop = (0, max(0, top - 20), W, min(Hh, top + n * h + 20))
            strip = Image.new("RGB", (W, (crop[3] - crop[1]) * 3 + 16), (255, 255, 255))
            for j, m in enumerate(("base", "alt", "wave")):
                strip.paste(img[m].crop(crop), (0, j * (crop[3] - crop[1] + 8)))
            strip.resize((strip.width * 2, strip.height * 2), Image.NEAREST).save(run / "strips_strip.png")
        if motion and i in (0, nsnap // 2, nsnap - 1):
            pair = Image.new("RGB", (W * 2 + 8, Hh), (255, 255, 255))
            pair.paste(img["base"], (0, 0))
            pair.paste(img["alt"], (W + 8, 0))
            pair.save(run / ("motion_pair_%02d.png" % i))
    report["passed"] = ok
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--h", type=int, default=12)
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--d", type=int, default=6)
    ap.add_argument("--motion", action="store_true", help="visible walking fighters, scrolling camera")
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--rejudge", type=Path)
    args = ap.parse_args()
    if args.rejudge:
        return judge(args.rejudge)
    out_dir = ROOT / "tmp/strips/tests"
    out_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="motion-" if args.motion else "run-", dir=out_dir))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    shutil.copy2(args.map, frozen / "src/mk2.map")
    shutil.copy2(args.rom_dir / "mk2.zip", frozen / "rom/mk2.zip")
    modes = MOTION_MODES if args.motion else MODES
    with ThreadPoolExecutor(len(modes)) as pool:
        list(pool.map(lambda m: boot(args.mame, frozen, m, run, args.seconds,
                                     args.top, args.h, args.n, args.d, args.motion), modes))
    return judge(run)


if __name__ == "__main__":
    raise SystemExit(main())
