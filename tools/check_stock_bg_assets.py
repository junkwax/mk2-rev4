#!/usr/bin/env python3
"""Guard stock MK7 BDB/BDD files against accidental BDDTool rewrites."""
from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
DATA = REPO / "data"
READONLY_DATA = REPO.parent / "mk2-readonly" / "mk2-main" / "data"
LOD = DATA / "MK7MIL.LOD"

BBB_RE = re.compile(r"^\s*BBB>\s*([A-Za-z0-9_]+)", re.IGNORECASE)

# Deliberately edited stages whose current content is blessed.  mk2-readonly
# still holds the original leak copies, so a plain reference compare flags them
# forever.  Pinning the exact hash keeps the guard useful: these edits pass, but
# any *further* accidental BDDTool rewrite still fails because it would produce
# a hash matching neither the reference nor the pin.
#
# Re-pin only after confirming the new content is intended and that
# mk2asset.bgnd_stale.check_stage_stale reports no findings for the stage.
KNOWN_BASELINES = {
    # Edited 2026-07-16; bgnd_stale clean, verified 2026-07-20.
    "NUPOOL.BDB": "0e51664dba9c247e5aa45e8429004b9794a1476c",
    "NUPOOL.BDD": "538da609e3673070f6045f46291f2e0515cbaf21",
    "BATTLE.BDB": "4186bfb40a89d1089a24d6925d12842c66558d0f",
    "BATTLE.BDD": "04520b97639f63b5ce73e97c3dd461f6e14aed0d",
    "FOREST2.BDB": "903ed3cf36efbc9bc7a85a75900dd67a5a39edd6",
    "FOREST2.BDD": "e3a9cd3a9424a92a3c8146e6aba4571d46a09f4c",
}

# MK1PIT is custom rev3.3 content intentionally cooked into MK7MIL.  It has no
# stock counterpart in mk2-readonly, so the stock drift guard should not treat
# its missing reference as an error.
CUSTOM_BACKGROUNDS = {
    "MK1PIT",
    # TOWER3 is THE TOWER: stock TOWER2 plus six terracotta guards in their own
    # PLANE3 module.  It has no mk2-readonly counterpart so it cannot be
    # reference-compared here.  Its stock half is guarded instead by
    # `python tools/tower3_statue_layout.py --check` (Phase D), which diffs it
    # against data/TOWER2.BDB/.BDD - and those two stay pinned below.
    "TOWER3",
}

# Stages that no longer appear in MK7MIL.LOD but are still the reference a live
# stage is derived from.  Keep checking them so the chain back to mk2-readonly
# is unbroken.
EXTRA_REFERENCE_BACKGROUNDS = {
    "TOWER2",       # reference for TOWER3
}


def sha1(path: Path) -> str:
    h = hashlib.sha1()
    data = path.read_bytes()
    if path.suffix.upper() == ".BDB":
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    h.update(data)
    return h.hexdigest()


def stock_backgrounds() -> list[str]:
    if not LOD.exists():
        raise FileNotFoundError(f"{LOD} not found")
    names = []
    for line in LOD.read_text(encoding="latin-1", errors="replace").splitlines():
        match = BBB_RE.match(line)
        if match:
            names.append(match.group(1).upper())
    return names


def main() -> int:
    if os.environ.get("ALLOW_STOCK_BG_DRIFT") == "1":
        print("Stock BG asset check skipped because ALLOW_STOCK_BG_DRIFT=1")
        return 0

    if not READONLY_DATA.exists():
        print(f"WARNING: stock BG asset check skipped; {READONLY_DATA} not found")
        return 0

    drift = []
    missing = []
    names = stock_backgrounds()
    names += [n for n in sorted(EXTRA_REFERENCE_BACKGROUNDS) if n not in names]
    for base in names:
        if base in CUSTOM_BACKGROUNDS:
            continue
        for ext in ("BDB", "BDD"):
            rel = f"{base}.{ext}"
            current = DATA / rel
            reference = READONLY_DATA / rel
            if not current.exists() or not reference.exists():
                missing.append(rel)
                continue
            current_hash = sha1(current)
            reference_hash = sha1(reference)
            known_hash = KNOWN_BASELINES.get(rel.upper())
            if current_hash != reference_hash and current_hash != known_hash:
                drift.append((
                    rel,
                    current.stat().st_size,
                    reference.stat().st_size,
                    current_hash[:12],
                    reference_hash[:12],
                ))

    if missing:
        print("ERROR: stock BG reference/current files missing:")
        for rel in missing:
            print(f"  - {rel}")
        return 1

    if drift:
        print("ERROR: stock MK7 background assets differ from mk2-readonly.")
        print("These files feed the fragile LOAD2 BBB path; keep stock stages")
        print("pure and move edits into wrapper/sidecar assets until validated.")
        print("Set ALLOW_STOCK_BG_DRIFT=1 only for a deliberate experimental build.")
        for rel, cur_size, ref_size, cur_hash, ref_hash in drift:
            print(
                f"  - {rel}: current {cur_size} bytes sha1 {cur_hash}, "
                f"readonly {ref_size} bytes sha1 {ref_hash}"
            )
        return 1

    print("Stock BG asset check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
