#!/usr/bin/env python3
"""Palette-map rectangle (pal_rect, MKDISP.ASM) - prototype #7's other half.

    python tools/run_palrect_test.py --rom-dir tmp/palrect/rom --map tmp/palrect/mk2.map

Three boots of tools/palrect_test.lua against one frozen ROM, fighters visible
and parked, the rectangle over Liu Kang (P1) and the far planes behind him:

  none    nothing armed                                        (baseline)
  ident   the rectangle, IDENTITY selector table   -> equal to none, every
          pixel of every snapshot: reading and writing the map plane changes
          nothing, the colour indices survive, sysctrl comes back.
  swap    P1's selector -> P2's (Cage's) selector   -> outside the rectangle
          equal to none; inside, every changed pixel is P1's colour index
          re-read through Cage's palette (same index, other palette), and no
          pixel whose colour is not in P1's palette changed at all.

The pass is armed until rel 440, so the rel-400 and rel-430 snapshots are
armed and rel 460 is not: it must equal none in every mode - nothing the map
writes outlives the frames it was armed for.

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
MODES = ("none", "ident", "swap")
# colour RAM, bit address: the T-unit's, and the Wolf's (doc/WOLF_OPPORTUNITIES.md W01 -
# --game umk3 is what proves the Wolf map-plane bit, mapplane in MKDISP.ASM)
CRAM = {"mk2": "0x01800000", "umk3": "0x01880000"}


def boot(mame, frozen, mode, rect, run, seconds, game="mk2"):
    d = run / mode
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(MK2_ROOT=str(frozen), PR_MODE=mode, PR_RECT=rect, PR_LOG=str(d / "pr.log"),
               PR_CRAM=CRAM[game])
    cmd = [str(mame.resolve()), game, "-rompath", str(frozen / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/palrect_test.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)


def load(run, mode):
    d = run / mode
    text = (d / "pr.log").read_text(errors="replace")
    return text, sorted((d / "snap").rglob("*.png"))


def rgb555(w):
    r, g, b = (w >> 10) & 31, (w >> 5) & 31, w & 31
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2))


def judge(run, expect_refused=False):
    out = {m: load(run, m) for m in MODES}
    ok, report = True, {}
    for m in MODES:
        res = re.search(r"RESULT (.*)", out[m][0])
        print("%-5s snaps=%d  %s" % (m, len(out[m][1]), res.group(1) if res else "NO RESULT"))
        report[m + "_result"] = res.group(1) if res else None
        passes = int(re.search(r"passes=(\d+)", res.group(1)).group(1)) if res else -1
        refused = int(re.search(r"refused=(\d+)", res.group(1)).group(1)) if res else -1
        want = (passes == 0) if m == "none" else (passes > 0 and refused == 0)
        if expect_refused:
            want = passes == 0 and (refused == 0 if m == "none" else refused > 0)
        if not want or len(out[m][1]) != 3:
            print("FAIL: %s ran the pass %d times (%d refused), %d snapshots" % (m, passes, refused, len(out[m][1])))
            ok = False
    if not ok:
        return 1
    text = out["swap"][0]
    y0, x0, h, w = map(int, re.search(r"rect y=(\d+) x=(\d+) h=(\d+) w=(\d+)", text).groups())
    o1, o2 = (int(v, 16) for v in re.search(r"OPAL p1=(\w+) p2=(\w+)", text).groups())
    pal = {int(s): [rgb555(int(hx[i:i + 4], 16)) for i in range(0, 1024, 4)]
           for s, hx in re.findall(r"PAL sel=(\d+) (\w+)", text)}
    pairs = {(o1 & 0xff, o2 & 0xff), (o1 >> 8, o2 >> 8)}
    # none-colour -> the set of colours the same index reads as through P2's palette
    expect = {}
    for s1, s2 in pairs:
        for i in range(256):
            expect.setdefault(pal[s1][i], set()).add(pal[s2][i])
    p1_colours = set(expect)
    inside = lambda x, y: x0 <= x < x0 + w and y0 <= y < y0 + h

    for i in range(3):
        img = {m: Image.open(out[m][1][i]).convert("RGB") for m in MODES}
        if any(im.size != (400, 254) for im in img.values()):
            raise ValueError('Expected complete 400x254 captures in every mode')
        W, H = img["none"].size
        px = {m: img[m].load() for m in MODES}
        base = px["none"]
        ident_diff = sum(1 for y in range(H) for x in range(W) if px["ident"][x, y] != base[x, y])
        out_diff = in_changed = unexplained = bg_changed = 0
        for y in range(H):
            for x in range(W):
                a, b = base[x, y], px["swap"][x, y]
                if a == b:
                    continue
                if not inside(x, y):
                    out_diff += 1
                    continue
                in_changed += 1
                if a not in p1_colours:
                    bg_changed += 1
                elif b not in expect[a]:
                    unexplained += 1
        armed = i < 2
        if expect_refused:
            this_ok = ident_diff == 0 and out_diff == 0 and in_changed == 0
        elif armed:
            this_ok = ident_diff == 0 and out_diff == 0 and in_changed > 0 and unexplained == 0 and bg_changed == 0
        else:
            this_ok = ident_diff == 0 and out_diff == 0 and in_changed == 0
        ok &= this_ok
        report["snap%d" % i] = dict(armed=armed, ident_vs_none=ident_diff, swap_outside_rect=out_diff,
                                    swap_changed_inside=in_changed, swap_unexplained=unexplained,
                                    swap_non_p1_changed=bg_changed, passed=this_ok)
        print("snap %d (%s): ident-vs-none %d  swap outside %d  inside changed %d "
              "(unexplained %d, non-P1 colour %d)  -> %s"
              % (i, "armed" if armed else "disarmed", ident_diff, out_diff, in_changed,
                 unexplained, bg_changed, "ok" if this_ok else "FAIL"))
        if armed and i == 0:
            crop = (max(0, x0 - 40), max(0, y0 - 30), min(W, x0 + w + 40), min(H, y0 + h + 30))
            strip = Image.new("RGB", ((crop[2] - crop[0]) * 2 + 8, crop[3] - crop[1]), (255, 255, 255))
            strip.paste(img["none"].crop(crop), (0, 0))
            strip.paste(img["swap"].crop(crop), (crop[2] - crop[0] + 8, 0))
            strip = strip.resize((strip.width * 2, strip.height * 2), Image.NEAREST)
            strip.save(run / "palrect_strip.png")
    report.update(passed=ok, expect_refused=expect_refused, rect=[y0, x0, h, w], opal=[o1, o2])
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--rom-dir", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--rect", default="100,96,32,32", help="y,x,h,w - x and w even; at most 1024 pixels")
    ap.add_argument("--expect-refused", action="store_true", help="require refused requests and all captures identical to the unarmed baseline")
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--game", choices=sorted(CRAM), default="mk2",
                    help="umk3 = the Wolf set (rom/wolf, tmp/wolf/src/MK2.MAP, mk2wolf.exe)")
    ap.add_argument("--rejudge", type=Path, help="judge an existing run directory, no boots")
    args = ap.parse_args()
    if args.rejudge:
        return judge(args.rejudge, args.expect_refused)
    out_dir = ROOT / "tmp/palrect/tests"
    out_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=out_dir))
    frozen = run / "frozen"
    (frozen / "src").mkdir(parents=True)
    (frozen / "rom").mkdir(parents=True)
    shutil.copy2(args.map, frozen / "src/mk2.map")
    shutil.copy2(args.rom_dir / f"{args.game}.zip", frozen / f"rom/{args.game}.zip")
    with ThreadPoolExecutor(len(MODES)) as pool:
        list(pool.map(lambda m: boot(args.mame, frozen, m, args.rect, run, args.seconds, args.game), MODES))
    return judge(run, args.expect_refused)


if __name__ == "__main__":
    raise SystemExit(main())
