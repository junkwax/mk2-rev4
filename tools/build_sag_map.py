#!/usr/bin/env python3
"""
Snapshot the current MK2 build's SAG-to-flat-byte map and flag drift
between the three sources of truth:

  1. src/BGNDTBL.ASM       ? SAGs the assembled mk2.out actually uses
                              (compiled into program ROM via .long)
  2. tmp/load2/BGNDTBL.ASM ? SAGs LOAD2 emitted on the most recent
                              IMGBUILD run (truth for the LAST LOD only;
                              LOAD2 overwrites this file each run)
  3. data/*.IRW header     ? base address LOAD2 stamped in each IRW;
                              defines where bytes physically live

When any two of these disagree the runtime fetches bytes from the wrong
place and you get a "looks fine on the diagnostic preview but garbled
in MAME" failure.

Outputs `doc/CURRENT_SAG_MAP.md` (default --md) or stdout (default).

Usage:
    python tools/build_sag_map.py            # write doc/CURRENT_SAG_MAP.md
    python tools/build_sag_map.py --print    # stdout instead of file
    python tools/build_sag_map.py --csv      # CSV stdout
"""
import argparse
import re
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
try:
    from makevrom import parse_irw as parse_makevrom_irw
except Exception:
    parse_makevrom_irw = None


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$")
SAG_LINE_RE = re.compile(r"^\s*\.long\s+0([0-9a-fA-F]+)[Hh]\s*(?:;.*)?$")
WORD_LINE_RE = re.compile(r"^\s*\.word\s+(.+?)(?:;.*)?$")

# IRW header field offsets (per imgdump.py / makevrom.py).
IRW_HEADER_SIZE = 68
IRW_BASE_OFF = 44   # u32 base address (TMS bit-addr that LOD's ***> set)
IRW_SIZE_OFF = 48   # u32 payload byte count
IRW_BANK_OFF = 60   # u32 bank (0/1, or 0xFFFF if /E not used)

# Bank decode (validated against tmp/load2/MK7MIL.TBL ENDMARKER 0x05F12057
# matching `0x05000000 + 1,975,308 * 8` = 0x05F12060 ? off by 9 from
# alignment). See tools/map_retired_ranges.py for the same math.
BANK0_SAG_START = 0x02000000
BANK1_SAG_START = 0x04000000
BANK0_FLAT_BASE = 0x000000
BANK1_FLAT_BASE = 0x800000


def sag_to_flat_byte(sag: int):
    if BANK0_SAG_START <= sag < BANK1_SAG_START:
        return 0, BANK0_FLAT_BASE + (sag - BANK0_SAG_START) // 8
    if BANK1_SAG_START <= sag < BANK1_SAG_START + 0x02000000:
        return 1, BANK1_FLAT_BASE + (sag - BANK1_SAG_START) // 8
    return None, None


def parse_label_sags(path: Path):
    """Return {label: first_sag_int} for every HDRS section in the file."""
    sags = {}
    if not path.exists():
        return sags
    text = path.read_text(errors="replace")
    current = None
    saw_sag_for_current = False
    for line in text.splitlines():
        m = LABEL_RE.match(line)
        if m:
            current = m.group(1)
            saw_sag_for_current = False
            continue
        if current is None or saw_sag_for_current:
            continue
        # Only collect the first SAG per label (that's the chunk start).
        m = SAG_LINE_RE.match(line)
        if m:
            sags[current] = int(m.group(1), 16)
            saw_sag_for_current = True
    return sags


def parse_irw_headers(data_dir: Path):
    """Return {filename: (base_sag, payload_bytes, bank)} for every IRW."""
    out = {}
    for path in sorted(data_dir.glob("*.IRW")):
        try:
            if parse_makevrom_irw is not None:
                base, bank, payload = parse_makevrom_irw(path)
                out[path.name] = (base, len(payload), bank)
                continue
            hdr = path.read_bytes()[:IRW_HEADER_SIZE]
            if len(hdr) < IRW_HEADER_SIZE:
                continue
            base = struct.unpack_from("<I", hdr, IRW_BASE_OFF)[0]
            size = struct.unpack_from("<I", hdr, IRW_SIZE_OFF)[0]
            bank = struct.unpack_from("<I", hdr, IRW_BANK_OFF)[0]
            out[path.name] = (base, size, bank)
        except (OSError, struct.error):
            continue
    return out


# Per makevrom.py ? IRWs without a header bank fall back to filename.
IRW_FILE_BANK = {
    "MK2MIL.IRW": 0, "MK3MIL.IRW": 0, "MK4MIL.IRW": 0, "MK5MIL.IRW": 0,
    "MK6MIL.IRW": 1, "MK7MIL.IRW": 1,
    "MOVEART2.IRW": 0, "MOVEART1.IRW": 0, "SCLAP.IRW": 1,
}


def irw_flat_range(name: str, base_sag: int, payload: int, bank: int):
    """Compute flat byte range [start, end) that makevrom places this IRW at."""
    if bank not in (0, 1):
        bank = IRW_FILE_BANK.get(name, 0)
    # makevrom uses byte_offset = (base - 0x02000000) / 8, then adds bank base.
    # But for bank 1, the IRW header's `base` is the in-bank ***> value
    # (e.g., 0x03000000 for MK7MIL.LOD `***> 3000000,1`); the flat math
    # subtracts 0x02000000, not the bank-1 SAG start. That matches the
    # makevrom code exactly.
    bank_flat = BANK0_FLAT_BASE if bank == 0 else BANK1_FLAT_BASE
    byte_off = (base_sag - 0x02000000) // 8
    start = bank_flat + byte_off
    end = start + payload
    return bank, start, end


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print", action="store_true",
                        help="emit to stdout instead of writing the doc")
    parser.add_argument("--csv", action="store_true",
                        help="emit CSV (label,src_sag,gen_sag,drift)")
    args = parser.parse_args()

    repo = REPO
    src_tbl = repo / "src" / "BGNDTBL.ASM"
    gen_tbl = repo / "tmp" / "load2" / "BGNDTBL.ASM"
    data_dir = repo / "data"

    src_sags = parse_label_sags(src_tbl)
    gen_sags = parse_label_sags(gen_tbl)
    irw_headers = parse_irw_headers(data_dir)

    # SAG-drift candidates: labels present in both src and gen.
    common = sorted(set(src_sags) & set(gen_sags))
    drift = []
    aligned = 0
    for lbl in common:
        if src_sags[lbl] != gen_sags[lbl]:
            drift.append((lbl, src_sags[lbl], gen_sags[lbl]))
        else:
            aligned += 1

    src_only = sorted(set(src_sags) - set(gen_sags))
    gen_only = sorted(set(gen_sags) - set(src_sags))
    expected_intentional_drift = [
        (lbl, ssag, gsag)
        for lbl, ssag, gsag in drift
        if (lbl == "OFHDRS" and ssag - gsag == 0x02000000)
        or (lbl == "ry1HDRS" and ssag - gsag == 1)
    ]
    unexpected_drift = [
        (lbl, ssag, gsag)
        for lbl, ssag, gsag in drift
        if (lbl, ssag, gsag) not in expected_intentional_drift
    ]

    if args.csv:
        print("label,src_sag,gen_sag,src_minus_gen")
        for lbl, ssag, gsag in drift:
            print(f"{lbl},0x{ssag:08x},0x{gsag:08x},{ssag - gsag}")
        return 0

    f = sys.stdout if args.print else (repo / "doc" / "CURRENT_SAG_MAP.md").open("w", encoding="utf-8", newline="\n")
    def w(*a): print(*a, file=f)

    w("# Current build SAG map\n")
    w("Snapshot of where the three SAG sources of truth agree and disagree. "
      "Run this after `python build.py` to spot SAG drift that causes "
      "in-MAME background/sprite artifacts.\n")
    w("Sources:")
    w("- **src** = `src/BGNDTBL.ASM` (compiled into mk2.out ? runtime reads these)")
    w("- **gen** = `tmp/load2/BGNDTBL.ASM` (overwritten by each LOD's LOAD2 run; "
      "only reflects the LAST LOD's output)")
    w("- **IRW** = `data/*.IRW` header base addresses + payload sizes")
    w("")

    w("## IRW physical placement\n")
    w("How each IRW maps into the 12 MB flat video ROM (per makevrom.py math).\n")
    w("| IRW | Bank | SAG base | Payload bytes | Flat start | Flat end |")
    w("|---|---:|---:|---:|---:|---:|")
    for name, (base, size, bank) in irw_headers.items():
        b, start, end = irw_flat_range(name, base, size, bank)
        if name in IRW_FILE_BANK or bank in (0, 1):
            w(f"| `{name}` | {b} | `0x{base:08x}` | {size:,} | `0x{start:06x}` | `0x{end:06x}` |")
        else:
            w(f"| `{name}` | program-ROM | `0x{base:08x}` | {size:,} | ? | ? |")
    w("")

    w("## SAG drift: src vs LOAD2 regen\n")
    w(f"- Labels aligned: **{aligned}**")
    w(f"- Labels drifted: **{len(drift)}**")
    w(f"- src-only (e.g., retired payloads, hand-added): **{len(src_only)}**")
    w(f"- gen-only (just-emitted by latest LOAD2 run): **{len(gen_only)}**")
    w("")

    if unexpected_drift:
        w("### Unexpected drifted labels (will cause artifacts)\n")
        w("These labels exist in both src/ and tmp/load2/, but their first "
          "SAGs differ for a reason this tool does not recognize. That usually "
          "means src/BGNDTBL.ASM is stale or the decode rules changed. "
          "Investigate before blaming palette or object state.\n")
        w("| Label | src SAG | gen SAG | ? (bits) |")
        w("|---|---:|---:|---:|")
        for lbl, ssag, gsag in unexpected_drift[:50]:
            w(f"| `{lbl}` | `0x{ssag:08x}` | `0x{gsag:08x}` | "
              f"{ssag - gsag:+,d} |")
        if len(unexpected_drift) > 50:
            w(f"\n_(showing first 50 of {len(unexpected_drift)})_")
        w("")

    if expected_intentional_drift:
        w("### Expected intentional SAG differences\n")
        w("These labels differ for documented build-pipeline reasons and are "
          "not evidence of stale BGND-table promotion. `OFHDRS` is a raw "
          "versus runtime bank decode case. `ry1HDRS` is the Armory "
          "stock-copy overlay: the source table intentionally starts one bit "
          "after the COMESOON byte slot so the copied stock Armory bitstream "
          "keeps its original intra-byte alignment.\n")
        w("| Label | runtime src SAG | generated LOAD2 SAG | ? (bits) |")
        w("|---|---:|---:|---:|")
        for lbl, ssag, gsag in expected_intentional_drift:
            w(f"| `{lbl}` | `0x{ssag:08x}` | `0x{gsag:08x}` | "
              f"{ssag - gsag:+,d} |")
        w("")

    if gen_only:
        w("### Labels only in tmp/load2/ regen (not yet promoted)\n")
        w("New labels the most recent LOAD2 run emitted that aren't in "
          "src/BGNDTBL.ASM. Typical for the LAST LOD in the build chain ? "
          "LOAD2 overwrites `tmp/load2/BGNDTBL.ASM` each run, so these are "
          "the LAST LOD's contribution.\n")
        w("| Label | gen SAG |")
        w("|---|---:|")
        for lbl in gen_only[:30]:
            w(f"| `{lbl}` | `0x{gen_sags[lbl]:08x}` |")
        if len(gen_only) > 30:
            w(f"\n_(showing first 30 of {len(gen_only)})_")
        w("")

    if src_only:
        w("### Labels only in src/ (retired payloads + cross-LOD content)\n")
        w("These survive in src/BGNDTBL.ASM but the current `tmp/load2/` "
          "snapshot doesn't know about them ? either retired BBBs (callers "
          "disabled but address stability preserved per the postmortem) or "
          "content that comes from an earlier LOD whose `tmp/load2/` output "
          "was overwritten.\n")
        w(f"Count: **{len(src_only)}**. (Listing skipped to keep this file "
          f"actionable; use `--print` to see them.)")
        w("")

    if unexpected_drift == [] and gen_only == []:
        w("## Conclusion\n")
        w("Build is consistent for live BGND-table purposes: every unexpected "
          "shared-label drift is clear, and the most recent LOAD2 run emitted "
          "nothing not already promoted. If you're still seeing artifacts, the "
          "source is **not** BGND-table SAG drift ? look elsewhere:\n")
        w("- Per-character TBLs (MKLK.TBL, MKNJ.TBL, etc.) ? run "
          "`python tools/promote_tbls.py --check`.")
        w("- IRW physical packing ? diff against retail with "
          "`python mamerom.py path/to/retail.zip --source-video`.")
        w("- Custom slot collision ? compare fixed-slot ranges above "
          "against the live table.")
        w("- Palette / DMA-control bits in HDRS records ? these aren't "
          "tracked by this tool; check `src/BGNDPAL.ASM` and the BMOD "
          "flags word.")

    if not args.print:
        f.close()
        out = repo / "doc" / "CURRENT_SAG_MAP.md"
        print(f"wrote {out}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
