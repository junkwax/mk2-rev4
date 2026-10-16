#!/usr/bin/env python3
"""Does the power-up clear reach all of .bss?  Old ROM vs new ROM.

    python tools/run_clear_test.py --old-rom-dir tmp/palcoal/rom --old-map tmp/palcoal/mk2.map \\
                                   --new-rom-dir tmp/clear/rom --new-map tmp/clear/mk2.map

Boots tools/clear_test.lua on both: seed RAM with a pattern, soft-reset, count
what survives clscrach.  PASS needs all three:

  old ROM, upper band     pattern LEFT - proves the test can see the bug (and
                          that MAME's soft reset does not zero RAM itself)
  new ROM, upper band     pattern 0   - the clear now reaches `end`
  both ROMs, control      pattern 0   - the band both always cleared
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

ROOT = Path(__file__).resolve().parents[1]


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
    env.update(MK2_ROOT=str(fr), CL_LOG=str(d / "cl.log"))
    cmd = [str(mame.resolve()), "mk2", "-rompath", str(fr / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "bgfx", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/clear_test.lua"), "-seconds_to_run", str(seconds)]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       timeout=seconds + 240, check=True)
    text = (d / "cl.log").read_text(errors="replace")
    bands = {m.group(1): (int(m.group(2)), int(m.group(3)))
             for m in re.finditer(r"BAND (\w+) \w+\.\.\w+ pattern_left=(\d+) of (\d+)", text)}
    return bands, "RESULT done" in text


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mame", type=Path, default=Path("C:/MAME/mame_mk2test.exe"))
    ap.add_argument("--old-rom-dir", type=Path, required=True)
    ap.add_argument("--old-map", type=Path, required=True)
    ap.add_argument("--new-rom-dir", type=Path, required=True)
    ap.add_argument("--new-map", type=Path, required=True)
    ap.add_argument("--seconds", type=int, default=60)
    args = ap.parse_args()
    out = ROOT / "tmp/clear/tests"
    out.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
    jobs = {"old": (args.old_rom_dir, args.old_map), "new": (args.new_rom_dir, args.new_map)}
    with ThreadPoolExecutor(2) as pool:
        res = dict(zip(jobs, pool.map(lambda k: boot(args.mame, jobs[k][0], jobs[k][1], k, run, args.seconds), jobs)))
    report, ok = {}, True
    for k, (bands, done) in res.items():
        report[k] = dict(done=done, bands={b: dict(pattern_left=v[0], words=v[1]) for b, v in bands.items()})
        print("%-3s done=%s  %s" % (k, done, "  ".join("%s: %d of %d left" % (b, v[0], v[1]) for b, v in bands.items())))
        ok &= done and "upper" in bands and "control" in bands and bands["control"][0] == 0
    if ok:
        ok &= res["old"][0]["upper"][0] > 0 and res["new"][0]["upper"][0] == 0
    report["passed"] = ok
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
