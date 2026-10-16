#!/usr/bin/env python3
"""EARNING a hidden fighter (hidearn, MAINEQU.ASM), proved in MAME.

    python tools/run_hidden_earn_test.py --rom tmp/hidearn/rom --map tmp/hidearn/mk2.map
    python tools/run_hidden_earn_test.py --rom ... --map ... --only jade

Each case boots on a FRESH private nvram, plays a real 1P match against a forced
CPU opponent (tools/hidden_earn_test.lua) and requires hid_earned to read the
expected mask after the match AND after a soft reset - the reset clears .bss, so
the second read can only come out of cmos (adj_hidearn, reloaded by dipinit).

Cases:  jade  - beat CPU Jade       -> 1 (Jade)
        kahn  - beat CPU Shao Kahn  -> 2 (Ermac)
        smoke - beat CPU Smoke      -> 4 (Rain)
        jax   - beat CPU Jax        -> 0 (control: an ordinary win earns nothing)
        lose  - LOSE to CPU Jade    -> 0 (control: the CPU winning earns nothing)
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAME = Path("C:/MAME/mame_mk2test.exe")
CASES = {
    "jade": (16, 1, False),
    "kahn": (13, 2, False),
    "smoke": (14, 4, False),
    "jax": (11, 0, False),
    "lose": (16, 0, True),
}


def run_case(name: str, rom: Path, mapf: Path, out: Path, seconds: int) -> str:
    target, expect, lose = CASES[name]
    d = out / name
    if d.exists():
        shutil.rmtree(d)
    fr = d / "frozen" / "src"
    fr.mkdir(parents=True)
    shutil.copy2(mapf, fr / "mk2.map")
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "go.ds").write_text("go\n", encoding="ascii")
    env = os.environ.copy()
    env.update(MK2_ROOT=str(d / "frozen"), HE_LOG=str(d / "he.log"), HE_TARGET=str(target),
               HE_EXPECT=str(expect), HE_LOSE="1" if lose else "0")
    cmd = [str(MAME), "mk2", "-rompath", str(rom), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "gdi", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/hidden_earn_test.lua"), "-seconds_to_run", str(seconds),
            "-debug", "-debugscript", str(d / "go.ds"), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=d, env=env, stdout=log, stderr=subprocess.STDOUT,
                       timeout=seconds * 6 + 300, check=False)
    text = (d / "he.log").read_text(errors="replace") if (d / "he.log").exists() else ""
    m = re.findall(r"^\[he\] (PASS|FAIL|NOVERDICT) (.*)$", text, re.M)
    return f"{m[-1][0]} {m[-1][1]}" if m else f"NOVERDICT no verdict in {d / 'he.log'}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rom", type=Path, required=True, help="dir holding mk2.zip")
    ap.add_argument("--map", type=Path, required=True, help="the mk2.map that zip was linked with")
    ap.add_argument("--only", choices=sorted(CASES), action="append")
    ap.add_argument("--seconds", type=int, default=900)
    a = ap.parse_args()
    out = ROOT / "tmp/hidden_earn"
    out.mkdir(parents=True, exist_ok=True)
    bad = 0
    for name in a.only or list(CASES):
        v = run_case(name, a.rom.resolve(), a.map.resolve(), out, a.seconds)
        print(f"{name:6s} {v}", flush=True)
        bad += not v.startswith("PASS")
    print("ALL PASS" if not bad else f"{bad} case(s) not PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
