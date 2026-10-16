#!/usr/bin/env python3
"""Fail the build when LOAD2 leaves an incomplete image pass behind."""
import re
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
LOG = REPO / "data" / "IMGBUILD.LOG"

REQUIRED_LODS = [
    "MK2MIL",
    "MK3MIL",
    "MK4MIL",
    "MK5MIL",
    "MK6MIL",
    "MK7MIL",
    "MK8MIL",
    "MOVEART2",
    "MOVEART1",
    "SCLAP",
    "SHAOSIT",
    "GOROWALK",
    "FLAPJACK",
    "KITSPIN",
    "JADERANG",
    "JADVIC",
    # STGORO retired with the custom Shang "Goro lives" reveal; its
    # 0x790000..0x797000 slot is free. See the REM block in data/IMGBUILD.BAT.
    "MK1SKULL",
    # VSNBMOV / VSSMMOV (Noob and Smoke VS portraits) are not built while
    # vs_noob_smoke_pics is 0 (MAINEQU.ASM) - their space went to the Dead
    # Pool hangers.  Put them back here if it goes back to 1.
    # VSJDMOV retired 2026-09-25 - Jade moved into MK8MIL (program ROM).
    "SZSPINE",
]

FROM_RE = re.compile(r"from:\s+C:\\DATA\\([A-Za-z0-9_]+)\.lod", re.IGNORECASE)
ERROR_RE = re.compile(r"\b[A-Za-z0-9_]+\s+ERROR:")
# LOAD2 does not treat an unresolvable record name as an error: it prints this,
# skips the record and carries on, so a LOD naming records the library does not
# have still "completes" with a byte summary. JADVIC1/JADVIC2 shipped this way
# for months - both built to a header with zero payload while MKFN.ASM went on
# referencing the labels. Any occurrence is a build failure.
MISSING_IMAGE_RE = re.compile(r"Couldn't find image \[([^\]]+)\]")

# Pre-existing unresolved names, accepted so the check flags only NEW breakage.
# Every entry here is a real hole in the art, not a false positive - do not add
# to this list to silence a LOD you just edited.
KNOWN_MISSING = {
    # Baraka sword-kick 'C' subframes were never authored in the leak.
    "MK3MIL": {"UGSWORDKICK1C", "UGSWORDKICK2C", "UGSWORDKICK3C"},
    # Dead Pool corner hangers: only Boon's skeleton has pixel data in the
    # library. See doc/DEADPOOL_HANGER_HANDOFF.md - the other six devs' bodies
    # are named in the LOD but were never exported.
    "MOVEART1": {
        f"D{who}HANG1{part}"
        for who in ("GEO", "JEFF", "JOHN", "MARK", "SAL", "STEVE", "TONY")
        for part in ("A", "B", "C")
    },
    # Sentinel name, not real art.
    "FLAPJACK": {"ENDMARKER"},
}
# A sidecar that resolves nothing writes a zero-byte payload. Catch that too,
# in case a future LOAD2 build stops printing the per-record message.
EMPTY_PAYLOAD_RE = re.compile(r"Bytes Represented in Tables\s*\.*\s*0 dec", re.IGNORECASE)


def split_sections(text: str):
    sections = {}
    current_name = None
    current_lines = []
    for line in text.splitlines():
        match = FROM_RE.search(line)
        if match:
            if current_name is not None:
                sections[current_name.upper()] = "\n".join(current_lines)
            current_name = match.group(1).upper()
            current_lines = [line]
        elif current_name is not None:
            current_lines.append(line)
    if current_name is not None:
        sections[current_name.upper()] = "\n".join(current_lines)
    return sections


def main() -> int:
    if not LOG.exists():
        print(f"ERROR: {LOG} not found; LOAD2 did not produce a log")
        return 1

    text = LOG.read_text(encoding="latin-1", errors="replace")
    failures = []

    for i, line in enumerate(text.splitlines(), 1):
        if ERROR_RE.search(line):
            failures.append(f"line {i}: {line.strip()}")

    sections = split_sections(text)
    for lod, section in sections.items():
        allowed = KNOWN_MISSING.get(lod, set())
        missing = [n for n in MISSING_IMAGE_RE.findall(section) if n not in allowed]
        if missing:
            shown = ", ".join(missing[:6])
            more = f" (+{len(missing) - 6} more)" if len(missing) > 6 else ""
            failures.append(
                f"{lod}.LOD names {len(missing)} record(s) its library does not"
                f" have: {shown}{more}"
            )
        if EMPTY_PAYLOAD_RE.search(section):
            failures.append(f"{lod}.LOD produced an empty payload (0 bytes in tables)")

    for lod in REQUIRED_LODS:
        section = sections.get(lod)
        if section is None:
            failures.append(f"{lod}.LOD did not appear in IMGBUILD.LOG")
            continue
        if "TOTAL bytes written" not in section:
            failures.append(f"{lod}.LOD did not complete with a byte summary")

    if failures:
        print("ERROR: LOAD2 log check failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("LOAD2 log check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
