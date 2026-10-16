#!/usr/bin/env python3
"""One post-build report: what this build is, what it costs, and whether it is installed.

Graphics audit opportunity 29.  Every number here already had a tool; the
trouble was that each lived in its own command, got re-run by hand, and a
session that did not run all of them shipped on a guess.  On 2026-09-13 alone
several sessions installed over one another, a stale dead table failed Phase D,
and "is the installed zip really this build?" was answered by hand three times.

Sections:
  freshness   mtimes of mk2.out, program bins, video chips, newest IRW
  installed   rom/mk2.zip and C:\\MAME\\roms\\mk2.zip against the CURRENT rom/ chips,
              ignoring only crc_spoof's 4-byte tail patch per chip
  space       video free per bank, largest run, program-ROM headroom
              (tools/rom_space_report.py)
  guards      the Phase D style checks, run exactly as they ship (exit code +
              last line): SAG coverage, inline SAGs, stack clearance, PC-relative
              range, table drift, BLDXPD/NOOBPORT packing
  stale       tmp/load2 tables no live LOD writes (they fake "packed")
  art         optional: decoded-pixel identity against a saved baseline

Nothing here fails the build or writes into src/ or rom/.

    python tools/build_report.py                              # report
    python tools/build_report.py --baseline tmp/art_before.json   # + pixel diff
    python tools/build_report.py --write-baseline tmp/art_now.json
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import io
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tmp" / "build_report"
INSTALLED = [ROOT / "rom" / "mk2.zip", Path("C:/MAME/roms/mk2.zip")]
PROGRAM_CHIPS = {"l3.1_mortal_kombat_ii_game_rom_uj12.uj12": "mk2_uj12.bin",
                 "l3.1_mortal_kombat_ii_game_rom_ug12.ug12": "mk2_ug12.bin"}
SPOOF_TAIL = 0x100          # crc_spoof patches 4 bytes inside each chip's last page

GUARDS = [
    ("SAG coverage", ["tools/check_sag_coverage.py", "--check"]),
    ("inline SAGs", ["tools/sync_inline_sags.py", "--check"]),
    ("stack clearance", ["tools/check_stack_clearance.py", "--check"]),
    ("PC-relative range", ["tools/check_pcrel_range.py", "--check"]),
    ("table drift", ["tools/promote_tbls.py", "--check"]),
    ("BLDXPD packing", ["tools/check_bldxpd_packing.py"]),
    ("NOOBPORT packing", ["tools/check_noobport_packing.py"]),
]


def stamp(p: Path):
    return dt.datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S") if p.exists() else None


SKEW = 120   # DOSBox stamps its outputs (mk2.out, IRWs) from its own clock, which
             # runs ahead of the host - reference_dosbox_clock_skew_mtime_guard


def freshness():
    irws = sorted((ROOT / "data").glob("*.IRW"), key=lambda p: p.stat().st_mtime)
    video = sorted((ROOT / "rom").glob("l1_mortal_kombat_ii_game_rom_*"), key=lambda p: p.stat().st_mtime)
    out_p, bin_p = ROOT / "src/mk2.out", ROOT / "rom/mk2_uj12.bin"
    return {
        "src/mk2.out": stamp(out_p),
        "rom/mk2_uj12.bin": stamp(bin_p),
        "oldest video chip": stamp(video[0]) if video else None,
        "newest IRW": ("%s (%s)" % (stamp(irws[-1]), irws[-1].name)) if irws else None,
        "video chips older than newest IRW (beyond %ds skew)" % SKEW:
            bool(video and irws and video[0].stat().st_mtime + SKEW < irws[-1].stat().st_mtime),
        "program bins older than mk2.out (beyond %ds skew)" % SKEW:
            bool(bin_p.exists() and out_p.exists() and bin_p.stat().st_mtime + SKEW < out_p.stat().st_mtime),
    }


def chip_matches(a: bytes, b: bytes):
    if len(a) != len(b):
        return False
    diff = [i for i in range(len(a)) if a[i] != b[i]] if a != b else []
    return all(i >= len(a) - SPOOF_TAIL for i in diff) and len(diff) <= 4


def installed():
    current = {}
    for member, name in PROGRAM_CHIPS.items():
        p = ROOT / "rom" / name
        if p.exists():
            current[member] = p.read_bytes()
    for p in (ROOT / "rom").glob("l1_mortal_kombat_ii_game_rom_*"):
        current[p.name] = p.read_bytes()
    out = []
    for zp in INSTALLED:
        if not zp.exists():
            out.append(dict(path=str(zp), present=False))
            continue
        z = zipfile.ZipFile(zp)
        names = set(z.namelist())
        stale = [m for m, data in current.items() if m not in names or not chip_matches(z.read(m), data)]
        out.append(dict(path=str(zp), present=True, modified=stamp(zp),
                        sha256=hashlib.sha256(zp.read_bytes()).hexdigest(),
                        chips_checked=len(current), chips_not_from_current_rom=sorted(stale)))
    return out


def space():
    r = subprocess.run([sys.executable, "tools/rom_space_report.py"], cwd=ROOT, capture_output=True, text=True)
    text = r.stdout
    pick = lambda pat: (re.search(pat, text) or [None, None])[1]
    return {
        "video free total": pick(r"TOTAL VIDEO FREE: ([\d,]+) bytes"),
        "bank 0 free": pick(r"bank 0 ([\d,]+) /"),
        "bank 1 free": pick(r"bank 1 ([\d,]+)\)"),
        "largest run": pick(r"LARGEST SINGLE RUN: ([^\n]+)"),
        "program linked": pick(r"linked code\+tables: ([\d,]+) bytes"),
        "program headroom": pick(r"HEADROOM FOR MORE CODE/TABLES: ([\d,]+) bytes"),
    }


def guards():
    out = []
    for name, cmd in GUARDS:
        if not (ROOT / cmd[0]).exists():
            out.append(dict(guard=name, status="missing"))
            continue
        r = subprocess.run([sys.executable, *cmd], cwd=ROOT, capture_output=True, text=True)
        lines = [l for l in (r.stdout + r.stderr).splitlines() if l.strip()]
        out.append(dict(guard=name, status="PASS" if r.returncode == 0 else "FAIL (exit %d)" % r.returncode,
                        last=lines[-1][:160] if lines else ""))
    return out


def art(baseline: Path | None, write: Path | None):
    sys.path.insert(0, str(ROOT / "tools"))
    import art_identity_snapshot as ais
    stale = []
    live = ais.live_lod_tables()
    if live is not None:
        stale = sorted(p.name for p in (ROOT / "tmp/load2").glob("*.TBL") if p.name.upper() not in live)
    result = dict(stale_load2_tables=stale)
    if not (baseline or write):
        return result
    now = ais.snapshot()
    if write:
        write.parent.mkdir(parents=True, exist_ok=True)
        write.write_text(json.dumps(now, indent=1) + "\n", encoding="utf-8")
        result["baseline_written"] = str(write)
    if baseline:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = ais.compare(now, json.loads(baseline.read_text()), False)
        lines = buf.getvalue().splitlines()
        result["identity"] = dict(baseline=str(baseline), passed=code == 0,
                                  summary=next((l for l in lines if l.startswith("records ")), ""),
                                  changed=[l.strip() for l in lines if l.strip().startswith("CHANGED")][:40])
    return result


def markdown(rep):
    md = ["# Build report", "", "Generated %s" % rep["generated"], "", "## Freshness", ""]
    md += ["- %s: %s" % (k, v) for k, v in rep["freshness"].items()]
    md += ["", "## Installed", ""]
    for z in rep["installed"]:
        if not z["present"]:
            md.append("- %s: missing" % z["path"])
        else:
            verdict = "matches current rom/ chips" if not z["chips_not_from_current_rom"] else \
                "NOT the current build: %s" % ", ".join(z["chips_not_from_current_rom"])
            md.append("- %s (%s, sha256 %s...): %s" % (z["path"], z["modified"], z["sha256"][:12], verdict))
    md += ["", "## Space", ""] + ["- %s: %s" % (k, v) for k, v in rep["space"].items()]
    md += ["", "## Guards", "", "| Guard | Status | Last line |", "|---|---|---|"]
    md += ["| %s | %s | %s |" % (g["guard"], g["status"], g.get("last", "").replace("|", "/")) for g in rep["guards"]]
    rt = rep.get("runtime")
    md += ["", "## Runtime budgets", ""]
    if not rt:
        md.append("- no tmp/build_report/runtime.json - run `python tools/run_runtime_budget.py`")
    else:
        md.append("- from %s (%s, %d frames each)" % (rt["generated"], Path(rt["rom_zip"]).name, rt["observe_frames"]))
        md += ["", "| Scenario | Sweep | Objects | Processes | Blood | Peak overload | DMA queue cells | Over/late/lost | qdma drops | palq drops |",
               "|---|---|---|---|---|---|---|---|---|---|"]
        for s in rt["scenarios"]:
            md.append("| %s | %s | %s/%s | %s/%s | %s/64 | %s | %s/500 | %s/%s/%s | %s | %s |" % (
                s["label"], s["sweep"].replace("|", "/")[:40], s.get("obj"), s.get("obj_pool"), s.get("proc"), s.get("proc_pool"),
                s.get("blood"), s.get("peak_overload"), s.get("deep_dmaq_cells"), s.get("dmaq_over"), s.get("dmaq_late"),
                s.get("dmaq_lost"), s.get("qdma_drops"), s.get("palq_drops")))
    a = rep["art"]
    md += ["", "## Art", "", "- stale tmp/load2 tables (no live LOD writes them): %s" % (", ".join(a["stale_load2_tables"]) or "none")]
    if "identity" in a:
        i = a["identity"]
        md.append("- identity vs %s: %s - %s" % (i["baseline"], "PASS" if i["passed"] else "FAIL", i["summary"]))
        md += ["  - " + c for c in i["changed"]]
    return "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", type=Path, help="art_identity_snapshot JSON to compare decoded pixels against")
    ap.add_argument("--write-baseline", type=Path, help="write a fresh art identity snapshot here")
    ap.add_argument("--no-guards", action="store_true", help="skip running the guard tools")
    args = ap.parse_args()
    runtime_path = OUT / "runtime.json"
    rep = dict(generated=dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), freshness=freshness(),
               installed=installed(), space=space(), guards=[] if args.no_guards else guards(),
               runtime=json.loads(runtime_path.read_text()) if runtime_path.exists() else None,
               art=art(args.baseline, args.write_baseline))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "report.json").write_text(json.dumps(rep, indent=2) + "\n", encoding="utf-8")
    text = markdown(rep)
    (OUT / "report.md").write_text(text, encoding="utf-8")
    print(text)
    print("wrote %s" % (OUT / "report.md"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
