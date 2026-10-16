#!/usr/bin/env python3
"""Runtime pool peaks DURING finishers - graphics audit row 10's open half.

    python tools/run_fatality_budget.py --build tmp/cpu_patch/build
    python tools/run_fatality_budget.py --build tmp/cpu_patch/build --only toasty,souls

--build holds rom/mk2.zip and mk2.map.  Each scenario is an existing rig that
already performs one finisher, run under tools/fatality_budget_wrap.lua, which
samples every frame:

  obj / proc     in use = pool - free-list length (358 / 168)
  blood          blood_count against MAX_BLOOD (64)
  fg / bg        palette slots with palcnt != 0 (35 / 45)
  ROM            peak_overload and deep_dmaq re-latched from the finisher's
                 first frame; qdma/dmaq/palq counters as deltas over it

PRE = boot to the finisher's first frame (f_death != 0, or winner_status 4 for
the souls); FIN = from there to the end of the run.  Scenarios run one after
another (windowed -debug, private directories, a frozen copy of src/ and
tools/ so hard-coded rig paths read the map that matches the ROM).
Writes tmp/fatality_budget/<run>/summary.json.
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

ROOT = Path(__file__).resolve().parents[1]
MAME = Path("C:/MAME/mame_mk2test.exe")

# (label, rig inside tools/, env (FROZEN / LOGDIR substituted), emulated seconds, verdict regex)
SCENARIOS = [
    ("toasty", "specials_finishim_test.lua",
     dict(SPEC_CASE="sc_toasty_fatality", SPEC_LOG="{LOGDIR}/rig.log"), 200, r"\[spec\] (PASS|FAIL)[^\n]*"),
    ("raiden_lift", "raiden_lift_fatality_test.lua",
     dict(MK2_ROOT="{FROZEN}", RDLF_LOG="{LOGDIR}/rig.log", RDLF_OBSERVE="400"), 240, r"\[rdlf\] (PASS|FAIL)[^\n]*"),
    ("kunglao_split", "split_fatality_victim_test.lua",
     dict(MK2_ROOT="{FROZEN}", SFV_ATTACKER="kunglao", SFV_VICTIM="kitana", SFV_LOG="{LOGDIR}/rig.log"),
     320, r"\] (PASS|FAIL) [^\n]*"),
    ("kahn_fatality", "kahn_boss_moves_test.lua",
     dict(KAHN_TEST_ROOT="{FROZEN}", KAHN_TEST_LOG="{LOGDIR}/rig.log", KAHN_TEST_CODE="16",
          KAHN_PORTAL_FATALITY="1", KAHN_ALLOW_P1_DAMAGE="1", KAHN_SNAP_EVERY="1000000"),
     320, r"(PASS|FAIL)[^\n]*"),
    ("souls", "shang_soul_escape_test.lua",
     dict(SSE_LOG="{LOGDIR}/rig.log", SSE_READY="{LOGDIR}/ready.flag", SSE_SNAP_EVERY="1000000",
          SSE_MODE="souls", SSE_STAGE="-1", SSE_DUMP_AT="0"), 900, r"\[sse\] (PASS|FAIL)[^\n]*"),
]
FIELD = re.compile(r"(PRE|FIN) \S+ obj=(\w+)/\d+\(@(\w+)\) proc=(\w+)/\d+\(@(\w+)\) blood=(\w+)/64 "
                   r"fg=(\w+)/\d+ bg=(\w+)/\d+ walk_fail=(\d+)")


def freeze(build: Path, fr: Path):
    (fr / "src").mkdir(parents=True)
    (fr / "tools").mkdir()
    (fr / "rom").mkdir()
    shutil.copy2(build / "mk2.map", fr / "src/mk2.map")
    shutil.copy2(build / "rom/mk2.zip", fr / "rom/mk2.zip")
    for pat in ("*.TBL", "*.ASM", "*.GLO"):
        for f in (ROOT / "src").glob(pat):
            shutil.copy2(f, fr / "src" / f.name)
    for f in (ROOT / "tools").glob("*.lua"):
        shutil.copy2(f, fr / "tools" / f.name)


def boot(scn, fr: Path, run: Path, extra_env=None, tag=""):
    label, rig, env_t, seconds, _ = scn
    d = run / (label + ("_" + tag if tag else ""))
    for sub in ("ini", "cfg", "nvram", "snap", "state", "input"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "go.ds").write_text("go\n", encoding="ascii")
    env = os.environ.copy()
    subst = lambda v: v.replace("{FROZEN}", fr.as_posix()).replace("{LOGDIR}", d.as_posix())
    env.update({k: subst(v) for k, v in env_t.items()})
    env.update(FB_ROOT=fr.as_posix(), FB_LOG=(d / "fb.log").as_posix(), FB_LABEL=label, FB_TARGET="tools/" + rig)
    env.update(extra_env or {})
    cmd = [str(MAME), "mk2", "-rompath", str(fr / "rom"), "-inipath", str(d / "ini")]
    for option in ("cfg", "nvram", "snapshot", "state", "input"):
        cmd += ["-" + option + "_directory", str(d / ("snap" if option == "snapshot" else option))]
    cmd += ["-video", "gdi", "-sound", "none", "-nothrottle", "-skip_gameinfo",
            "-autoboot_script", str(fr / "tools/fatality_budget_wrap.lua"), "-seconds_to_run", str(seconds),
            "-debug", "-debugscript", str(d / "go.ds"), "-window", "-nomax"]
    with (d / "mame.log").open("w") as log:
        subprocess.run(cmd, cwd=d, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=seconds * 8 + 600,
                       check=False)


def collect(scn, run: Path):
    label, _, _, _, vpat = scn
    d = run / label
    fb = (d / "fb.log").read_text(errors="replace") if (d / "fb.log").exists() else ""
    rig = (d / "rig.log").read_text(errors="replace") if (d / "rig.log").exists() else ""
    if not re.search(vpat, rig) and (d / "mame.log").exists():  # the rigs also print to stdout
        rig = (d / "mame.log").read_text(errors="replace")
    res = dict(label=label, dir=str(d))
    for m in FIELD.finditer(fb):
        keys = ("obj", "obj_at", "proc", "proc_at", "blood", "fg", "bg", "walk_fail")
        res[m[1].lower()] = {k: (int(v) if v.lstrip("-").isdigit() else None) for k, v in zip(keys, m.groups()[1:])}
    m = re.search(r"FINISHER_START .* in_use obj=(\w+) proc=(\w+)", fb)
    if m:
        res["at_start"] = dict(obj=int(m[1]) if m[1].isdigit() else None, proc=int(m[2]) if m[2].isdigit() else None)
    m = re.search(r"FINROM \S+ start=(\d+) frames=(\d+) (.*)", fb)
    if m:
        res["fin_start"], res["fin_frames"] = int(m[1]), int(m[2])
        res["rom"] = dict(kv.split("=", 1) for kv in m[3].split())
    res["finisher_seen"] = "FINISHER_START" in fb
    vs = re.findall(vpat, rig)
    res["rig_verdict"] = re.search(vpat, rig)[0].strip() if vs else "no verdict"
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", type=Path, required=True)
    ap.add_argument("--only", help="comma list of scenario labels")
    ap.add_argument("--rejudge", type=Path)
    args = ap.parse_args()
    scns = SCENARIOS
    if args.only:
        want = set(args.only.split(","))
        scns = [s for s in SCENARIOS if s[0] in want]
    if args.rejudge:
        run = args.rejudge
    else:
        out = ROOT / "tmp/fatality_budget"
        out.mkdir(parents=True, exist_ok=True)
        run = Path(tempfile.mkdtemp(prefix="run-", dir=out))
        fr = run / "frozen"
        freeze(args.build, fr)
        for s in scns:
            boot(s, fr, run)
    results = [collect(s, run) for s in scns]
    (run / "summary.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    for r in results:
        pre, fin = r.get("pre", {}), r.get("fin", {})
        st = r.get("at_start", {})
        print("%-14s finisher=%-5s | at start obj %s proc %s | PRE obj %s proc %s blood %s fg %s bg %s | "
              "FIN obj %s(@%s) proc %s blood %s fg %s bg %s walkfail %s | %s | rig: %s" % (
                  r["label"], r["finisher_seen"], st.get("obj"), st.get("proc"),
                  pre.get("obj"), pre.get("proc"), pre.get("blood"), pre.get("fg"),
                  pre.get("bg"), fin.get("obj"), fin.get("obj_at"), fin.get("proc"), fin.get("blood"), fin.get("fg"),
                  fin.get("bg"), fin.get("walk_fail"), r.get("rom"), r["rig_verdict"]))
    print("run dir:", run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
