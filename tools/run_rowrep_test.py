#!/usr/bin/env python3
"""Graphics audit row 24: prove TMS34010 row repetition drives the MK2 screen.

Runs tools/rowrep_test.lua once (private windowed MAME under -debug), then for
every capture window whose two f_rowrep=0 captures are identical (a static
scene), checks that the f_rowrep=n capture is the 0-capture with every row
shown n+1 times.  The repetition may start mid-count at the top of the
visible area, so each check tries every phase and reports the best.

    python tools/run_rowrep_test.py --rompath tmp/rowrep/rom --root tmp/rowrep/frozen
"""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent


def rows(img):
    w, h = img.size
    px = img.load()
    return [tuple(px[x, y] for x in range(w)) for y in range(h)]


def check_stretch(normal, stretched, n):
    """Best phase p: stretched[y] == normal[(y + p) // (n + 1)] for most y."""
    best = None
    for p in range(n + 1):
        ok = bad = 0
        for y, row in enumerate(stretched):
            src = (y + p) // (n + 1)
            if src >= len(normal):
                continue
            if row == normal[src]:
                ok += 1
            else:
                bad += 1
        if best is None or ok > best["match"]:
            best = dict(phase=p, match=ok, mismatch=bad)
    best["identical_to_normal"] = stretched == normal
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rompath", required=True)
    ap.add_argument("--root", required=True, help="repo or frozen copy holding src/mk2.map")
    ap.add_argument("--out", default=str(REPO / "tmp/rowrep/run"))
    ap.add_argument("--mame", default=r"C:\MAME\mame_mk2test.exe")
    ap.add_argument("--starts", default="700,1000,1400,1900,2600")
    ap.add_argument("--analyse-only", action="store_true")
    args = ap.parse_args()
    # MAME runs with its working directory set to the run folder, so every path
    # handed to it has to be absolute or it silently resolves somewhere else.
    args.rompath = str(Path(args.rompath).resolve())
    args.root = str(Path(args.root).resolve())

    out = Path(args.out).resolve()
    if not args.analyse_only:
        for d in ("ini", "cfg", "nvram", "snap", "state", "input"):
            (out / d).mkdir(parents=True, exist_ok=True)
        for old in (out / "snap").rglob("*.png"):
            old.unlink()
        (out / "go.ds").write_text("go\n", encoding="ascii")
        env = {k: v for k, v in os.environ.items() if not k.startswith("ROWREP_")}
        env.update(ROWREP_ROOT=str(Path(args.root)), ROWREP_LOG=str(out / "rowrep.log"),
                   ROWREP_STARTS=args.starts)
        cmd = [args.mame, "mk2", "-rompath", str(Path(args.rompath)), "-video", "gdi", "-sound", "none",
               "-nothrottle", "-skip_gameinfo", "-autoboot_script", str(REPO / "tools/rowrep_test.lua"),
               "-seconds_to_run", "120", "-debug", "-debugscript", str(out / "go.ds"), "-window", "-nomax"]
        for opt, d in (("-inipath", "ini"), ("-cfg_directory", "cfg"), ("-nvram_directory", "nvram"),
                       ("-snapshot_directory", "snap"), ("-state_directory", "state"),
                       ("-input_directory", "input")):
            cmd += [opt, str(out / d)]
        with open(out / "mame_out.log", "w") as fh:
            subprocess.run(cmd, cwd=str(out), env=env, stdout=fh, stderr=subprocess.STDOUT)

    log = (out / "rowrep.log").read_text(errors="replace").splitlines()
    snap_re = re.compile(r"SNAP idx=(\d+) window=(\d+) label=(\w+) frame=(\d+) f_rowrep=(\d+) dpystrt=(\w+) dpyadr=(\w+) gstate=(\d+)")
    shots = sorted((out / "snap").rglob("*.png"))
    windows = {}
    for line in log:
        m = snap_re.search(line)
        if m:
            idx, win, label = int(m.group(1)), int(m.group(2)), m.group(3)
            windows.setdefault(win, {})[label] = dict(path=shots[idx] if idx < len(shots) else None,
                                                      dpystrt=m.group(6), gstate=int(m.group(8)))
    report = {"windows": []}
    for win, caps in sorted(windows.items()):
        entry = {"window": win, "dpystrt": {k: v["dpystrt"] for k, v in caps.items()}}
        if any(c["path"] is None for c in caps.values()) or len(caps) < 5:
            entry["verdict"] = "missing captures"
            report["windows"].append(entry)
            continue
        r0a, r0b = rows(Image.open(caps["r0a"]["path"]).convert("RGB")), rows(Image.open(caps["r0b"]["path"]).convert("RGB"))
        entry["static"] = r0a == r0b
        if not entry["static"]:
            entry["verdict"] = "scene moved between the two 0-captures - not judged"
            report["windows"].append(entry)
            continue
        for n, label in ((1, "r1"), (2, "r2"), (3, "r3")):
            entry[label] = check_stretch(r0a, rows(Image.open(caps[label]["path"]).convert("RGB")), n)
        entry["verdict"] = "PASS" if all(entry[l]["mismatch"] == 0 and not entry[l]["identical_to_normal"]
                                         for l in ("r1", "r2", "r3")) else "FAIL"
        report["windows"].append(entry)
    judged = [w for w in report["windows"] if w.get("verdict") in ("PASS", "FAIL")]
    report["verdict"] = ("PASS" if judged and all(w["verdict"] == "PASS" for w in judged)
                         else "NO-VERDICT" if not judged else "FAIL")
    (out / "rowrep_results.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
