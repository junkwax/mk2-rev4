#!/usr/bin/env python3
"""Shao Kahn's turn-to-stone ending, captured on two ROMs and compared frame by frame.

    python tools/run_kahn_stone_capture.py --old tmp/reflect_fx/build --new tmp/stone_share/build

Each build dir holds rom/mk2.zip and mk2.map.  tools/kahn_stone_capture.lua plays a
one-player game into a forced CPU Shao Kahn, wins 2-0 and records the ending: one
snapshot per animation frame of the stone Kahn (matched by animation index k, not
by time), then a tail through the stone explosion.  The two boots run one after
the other (windowed -debug, private directories).

PASS needs both boots to reach the ending with the same number of animation
frames, and every animation-frame capture to be pixel-identical between the two
ROMs.  Tail captures (the explosion) are reported, not gated: the chunks'
first-frame record is a separate fix (tools/sync_inline_sags.py).
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
MAME = Path("C:/MAME/mame_mk2test.exe")


def boot(build: Path, tag: str, run: Path, tbl: Path | None, seconds: int):
    d = run / tag
    fr = d / "frozen"
    (fr / "src").mkdir(parents=True)
    shutil.copy2(build / "mk2.map", fr / "src/mk2.map")
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "go.ds").write_text("go\n", encoding="ascii")
    env = os.environ.copy()
    env.update(MK2_ROOT=str(fr), KSC_LOG=str(d / "ksc.log"), KSC_TBL=str(tbl) if tbl else "")
    cmd = [str(MAME), "mk2", "-rompath", str(build / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "gdi", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(ROOT / "tools/kahn_stone_capture.lua"), "-seconds_to_run", str(seconds),
            "-debug", "-debugscript", str(d / "go.ds"), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                       timeout=seconds * 6 + 300, check=False)


def load(d: Path):
    text = (d / "ksc.log").read_text(errors="replace") if (d / "ksc.log").exists() else ""
    snaps = sorted((d / "snap").rglob("*.png"))
    # the order snapshots were taken in, matched to their log lines
    kinds = re.findall(r"SNAP (k=\d+|tail) frame=(\d+)", text)
    anims = re.findall(r"ANIM k=(\d+) frame=(\d+) rel=(\d+) pieces=(\d+) (\S+)", text)
    return text, snaps, kinds, anims


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old", type=Path, required=True)
    ap.add_argument("--new", type=Path, required=True)
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--rejudge", type=Path)
    a = ap.parse_args()
    if a.rejudge:
        run = a.rejudge
    else:
        out = ROOT / "tmp/stone_share/capture"
        out.mkdir(parents=True, exist_ok=True)
        run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
        boot(a.old, "old", run, None, a.seconds)
        boot(a.new, "new", run, ROOT / "src/MKSK.TBL", a.seconds)
    res = {}
    for tag in ("old", "new"):
        text, snaps, kinds, anims = load(run / tag)
        end = re.search(r"END (.*)", text)
        res[tag] = dict(snaps=snaps, kinds=kinds, anims=anims, end=end.group(1) if end else "no END")
        print("%s: %s, %d animation frames, %d snapshots" % (tag, res[tag]["end"], len(anims), len(snaps)))
        for k, fr_, rel, n, names in anims:
            print("   k=%-2s rel=%-4s pieces=%s %s" % (k, rel, n, names))
    ok = True
    report = dict(run=str(run), frames=[])
    if len(res["old"]["anims"]) != len(res["new"]["anims"]) or not res["old"]["anims"]:
        print("FAIL: animation frame counts differ or no ending reached")
        ok = False
    # The first version "passed" on a recording of round 2: it armed on the
    # wrong game state and compared two identical fights.  So the recording has
    # to prove it IS the stone sequence: both boots armed on the dlists_bogus
    # gate, and the new build's frames are stone art by label (MKSK.TBL).
    for tag in ("old", "new"):
        text = (run / tag / "ksc.log").read_text(errors="replace") if (run / tag / "ksc.log").exists() else ""
        if not re.search(r"STONE_ARMED .* dlists_gate=true", text):
            print("FAIL: %s never armed on the stone sequence (dlists_bogus)" % tag)
            ok = False
    new_first = [names.split(",")[0] for _k, _f, _r, _n, names in res["new"]["anims"]]
    stone = [n for n in new_first if n in ("STONEBASEA", "BGSTONECRACK3A", "BGSTONECRACK8A")]
    report["new_stone_frames"] = len(stone)
    print("new build: %d of %d animation frames start with a stone-crack record" % (len(stone), len(new_first)))
    if len(stone) < 7:
        print("FAIL: fewer than 7 stone-crack frames on the new build - not the ending")
        ok = False

    def by_kind(tag):
        m = {}
        for (kind, _), p in zip(res[tag]["kinds"], res[tag]["snaps"]):
            m.setdefault(kind, []).append(p)
        return m
    ko, kn = by_kind("old"), by_kind("new")
    for kind in sorted(set(ko) & set(kn), key=lambda s: (s == "tail", int(s[2:]) if s.startswith("k=") else 0)):
        for i, (po, pn) in enumerate(zip(ko[kind], kn[kind])):
            A = np.asarray(Image.open(po).convert("RGB")).astype(int)
            B = np.asarray(Image.open(pn).convert("RGB")).astype(int)
            d = int(np.any(A != B, axis=2).sum()) if A.shape == B.shape else -1
            gated = kind != "tail"
            report["frames"].append(dict(kind=kind, index=i, diff_px=d, gated=gated))
            if gated and d != 0:
                ok = False
            if gated or d:
                print("%-6s #%d: %s px differ%s" % (kind, i, d, "" if gated else " (tail, not gated)"))
    tail_same = sum(1 for f in report["frames"] if f["kind"] == "tail" and f["diff_px"] == 0)
    tail_all = sum(1 for f in report["frames"] if f["kind"] == "tail")
    print("tail (explosion) captures identical: %d / %d" % (tail_same, tail_all))
    if not any(f["gated"] for f in report["frames"]):
        print("FAIL: no animation-frame captures to compare")
        ok = False
    report["passed"] = ok
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("%s (%s)" % ("PASS" if ok else "FAIL", run))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
