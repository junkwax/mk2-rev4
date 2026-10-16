#!/usr/bin/env python3
"""
Map MK2 BLIMP/BBB background payloads to TMS SAG ranges AND flat video-ROM
byte ranges, and flag which ones are retired per the Outer Haven postmortem.

Approach (per Asure's notes 2026-04-29 and the SAG-decode investigation
2026-05-15):
- tmp/load2/BGNDTBL.MK7 is preferred when present because it captures the
  stock MK7 background table before any sidecar promotion rewrites live
  labels into retired slots. Fallback is src/BGNDTBL.ASM.
- Each BBB has xxxBMOD -> .long xxxBLKS, yyyHDRS, yyyPALS.
- yyyHDRS is a flat list of (W, H, SAG, ctrl) per chunk.
- Sequential SAGs across ALL HDRS sections (sorted globally) give the
  packed size of each chunk: `chunk_size_bits = next_sag - this_sag`.
  Sidesteps the zero-compression / pixel-packing problem — we never
  compute size from W,H.
- A BBB's SAG range is [min_SAG_in_its_HDRS, last_chunk_SAG + last_chunk_size).
  That's the address window a new payload would have to occupy if it
  wants to overlay this BBB.

SAG-to-flat-byte decode:
- Bank 0 SAGs live in [0x02000000, 0x04000000) of TMS bit-addr space.
- Bank 1 SAGs live in [0x04000000, 0x06000000) (LOAD2 cumulatively packs
  bank-1 starting at 0x04000000 even though the LOD's ***> directive
  reads 0x02000000,1). Confirmed: tmp/load2/MK7MIL.TBL ENDMARKER is
  0x05F12057 after MK7MIL.LOD declares `***> 3000000,1` and packs
  1,975,308 bytes (= 0x05000000 + 0xF12060 bits).
- flat_byte = bank_base_in_flat + (sag - bank_base_in_sag) / 8
  where bank 0 base = 0x000000 (sag 0x02000000), bank 1 base = 0x800000
  (sag 0x04000000).

Retired BBBs (runtime caller commented out): SAG and flat-byte ranges
are safe to overlay. Live BBBs: do not overlay.

Usage:
    python tools/map_retired_ranges.py            # print summary
    python tools/map_retired_ranges.py --md       # write doc/RETIRED_RANGES.md
    python tools/map_retired_ranges.py --csv      # CSV stdout
    python tools/map_retired_ranges.py --verbose  # per-payload detail
    python tools/map_retired_ranges.py --source tmp/load2/BGNDTBL.MK7
"""
import argparse
import re
import sys
from pathlib import Path


# BBB names whose runtime callers are commented out (Outer Haven postmortem).
# Keys are the BBB> name in MK7MIL.LOD; values describe the disabled caller.
RETIRED_BBB = {
    "COMESOON":  "MK3 CD ad — advertise_comic disabled",
    "ATRAX1":    "Attract story bg 1 — the_story disabled",
    "ATRAX2":    "Attract story bg 2 — the_story disabled",
    "ATRAX3":    "Attract story bg 3 — the_story disabled",
    "ATRAX4":    "Attract story bg 4 — the_story disabled",
    "HISCORE1":  "Ranking screen — print_rankings disabled",
    "MKTEAM":    "Credits/team — caller disabled",
    "MKSTORY1":  "Story screen 1 — the_story disabled",
    "MKSTORY2":  "Story screen 2 — the_story disabled",
    "MKSTORY3":  "Story screen 3 — the_story disabled",
    "NUENT1":    "Name-entry 1 — caller disabled",
    "NUENT2":    "Name-entry 2 — caller disabled",
}


# BBB name -> BMOD label in src/BGNDTBL.ASM. The bddtool's emitted naming
# is quirky (Asure-truncated): COMESOON -> comesoonBMOD, ATRAX1 ->
# ATRXMOD1BMOD, etc. Extend if a new BBB target gets added.
BBB_TO_BMOD = {
    # Retired
    "COMESOON": "comesoonBMOD",
    "ATRAX1":   "ATRXMOD1BMOD",
    "ATRAX2":   "ATRXMOD2BMOD",
    "ATRAX3":   "ATRXMOD3BMOD",
    "ATRAX4":   "ATRXMOD4BMOD",
    "HISCORE1": "HISCRMOD1BMOD",
    "MKTEAM":   "TEAMMOD1BMOD",
    "MKSTORY1": "STORY1BMOD",
    "MKSTORY2": "STORY2BMOD",
    "MKSTORY3": "STORY3BMOD",
    # Live — backgrounds with runtime callers still in place. Map each
    # to its BMOD label so the "Live (do not overlay)" table is populated
    # and the makevrom preflight has a complete picture of forbidden
    # ranges. (NUENT1/NUENT2 omitted — BMOD label not yet identified.)
    "NUPOOL":   "DPUL1BMOD",   # Pit II (uses one of the DPUL set)
    "TOMB":     "TMOD1BMOD",
    "TOWER2":   "PLANE4BMOD",  # Tower at top — guess; verify from BGND.ASM stage table
    "BATTLE":   "BAT1BMOD",
    "FOREST2":  "wood1BMOD",
    "ARMORY1":  "ARM1BMOD",
    "BRIDGE1":  "BRIDGE0BMOD",
    # SPIRAL/ARENA/MKHUGE/MOUNTAIN/MKSELECT/MKWINNER/MKVERSUS BMOD names
    # not yet identified; the postmortem strategy only needs the retired
    # set for overlay planning, so this is non-blocking.
}


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$")
BMOD_BODY_RE = re.compile(
    r"^\s*\.long\s+([A-Za-z_][\w]*),\s*([A-Za-z_][\w]*),\s*([A-Za-z_][\w]*)\s*(?:;.*)?$"
)
SAG_LINE_RE = re.compile(r"^\s*\.long\s+0([0-9a-fA-F]+)[Hh]\s*(?:;.*)?$")
WORD_LINE_RE = re.compile(r"^\s*\.word\s+(.+?)(?:;.*)?$")


def _display_path(repo: Path, path: Path) -> str:
    try:
        return f"`{path.resolve().relative_to(repo.resolve()).as_posix()}`"
    except ValueError:
        return f"`{path}`"


def parse_bgnd_tbl(path: Path):
    """Walk src/BGNDTBL.ASM and return:
        bmods[label] -> (blks_label, hdrs_label, pals_label)
        sections[label] -> list of body line strings (until next label)
    """
    text = path.read_text(errors="replace")
    bmods = {}
    sections = {}
    current_label = None
    current_body = []
    for line in text.splitlines():
        m = LABEL_RE.match(line)
        if m:
            if current_label is not None:
                sections[current_label] = current_body
            current_label = m.group(1)
            current_body = []
            continue
        if current_label is not None:
            current_body.append(line)
    if current_label is not None:
        sections[current_label] = current_body

    for label, body in sections.items():
        if not label.endswith("BMOD"):
            continue
        for line in body:
            m = BMOD_BODY_RE.match(line)
            if m:
                bmods[label] = (m.group(1), m.group(2), m.group(3))
                break
    return bmods, sections


def extract_chunks_from_hdrs(hdrs_body):
    """A HDRS section is a flat sequence of (W,H,SAG,ctrl) records.
    Returns list of (sag_int, w, h)."""
    chunks = []
    pending_wh = None
    for raw in hdrs_body:
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        m = WORD_LINE_RE.match(raw)
        if m:
            vals = [v.strip() for v in m.group(1).split(",")]
            if len(vals) == 2 and all(_looks_int(v) for v in vals):
                try:
                    pending_wh = (int(vals[0]), int(vals[1]))
                except ValueError:
                    pending_wh = None
            continue
        m = SAG_LINE_RE.match(raw)
        if m and pending_wh is not None:
            sag = int(m.group(1), 16)
            chunks.append((sag, pending_wh[0], pending_wh[1]))
            pending_wh = None
    return chunks


def _looks_int(s):
    s = s.strip()
    return s and (s.lstrip("-").isdigit())


# Bank decode constants (see module docstring).
BANK0_SAG_START = 0x02000000
BANK1_SAG_START = 0x04000000
BANK0_FLAT_BASE = 0x000000
BANK1_FLAT_BASE = 0x800000


def sag_to_flat_byte(sag: int) -> tuple[int, int]:
    """Decode a TMS bit-addr SAG into (bank, flat_byte_offset).

    Raises ValueError if the SAG is outside known banks.
    """
    if BANK0_SAG_START <= sag < BANK1_SAG_START:
        bits_in_bank = sag - BANK0_SAG_START
        return 0, BANK0_FLAT_BASE + bits_in_bank // 8
    if BANK1_SAG_START <= sag < BANK1_SAG_START + 0x02000000:
        bits_in_bank = sag - BANK1_SAG_START
        return 1, BANK1_FLAT_BASE + bits_in_bank // 8
    raise ValueError(f"SAG 0x{sag:08x} outside known bank space")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path,
                        help="BGNDTBL source to parse; defaults to tmp/load2/BGNDTBL.MK7 if present")
    parser.add_argument("--md", action="store_true",
                        help="write doc/RETIRED_RANGES.md instead of stdout")
    parser.add_argument("--csv", action="store_true",
                        help="emit CSV (name,start_sag,end_sag,bits,bytes,retired,note)")
    parser.add_argument("--verbose", action="store_true",
                        help="show per-chunk SAGs and sizes for each payload")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    stock_snapshot = repo / "tmp" / "load2" / "BGNDTBL.MK7"
    fallback_source = repo / "src" / "BGNDTBL.ASM"
    if args.source:
        bgnd_tbl = args.source if args.source.is_absolute() else repo / args.source
        source_note = _display_path(repo, bgnd_tbl)
    elif stock_snapshot.exists():
        bgnd_tbl = stock_snapshot
        source_note = f"{_display_path(repo, bgnd_tbl)} stock MK7 LOAD2 snapshot"
    else:
        bgnd_tbl = fallback_source
        source_note = f"{_display_path(repo, bgnd_tbl)} fallback"
    if not bgnd_tbl.exists():
        print(f"error: {bgnd_tbl} not found", file=sys.stderr)
        return 2

    bmods, sections = parse_bgnd_tbl(bgnd_tbl)

    # Gather chunks for the BBBs we know about; also collect every chunk
    # globally so we can use neighbor-SAG deltas to size each chunk.
    per_bbb_chunks = {}  # bbb_name -> [(sag, w, h)]
    global_sags = set()
    for bbb_name, bmod_label in BBB_TO_BMOD.items():
        triple = bmods.get(bmod_label)
        if not triple:
            per_bbb_chunks[bbb_name] = ([], f"missing {bmod_label}")
            continue
        _, hdrs_label, _ = triple
        hdrs_body = sections.get(hdrs_label)
        if hdrs_body is None:
            per_bbb_chunks[bbb_name] = ([], f"missing {hdrs_label}")
            continue
        chunks = extract_chunks_from_hdrs(hdrs_body)
        per_bbb_chunks[bbb_name] = (chunks, hdrs_label)
        global_sags.update(c[0] for c in chunks)

    # Also pull every SAG in every HDRS section, not just the known BBBs,
    # so neighbor-delta sizing has the full picture (the next chunk after
    # COMESOON's last chunk might be from a non-retired BBB whose BMOD we
    # haven't mapped).
    for label, body in sections.items():
        if label.endswith("HDRS"):
            for sag, _, _ in extract_chunks_from_hdrs(body):
                global_sags.add(sag)
    sorted_sags = sorted(global_sags)
    sag_idx = {s: i for i, s in enumerate(sorted_sags)}

    def chunk_size_bits(sag: int) -> int | None:
        """Bits between this SAG and the next-SAG globally. None if this is
        the last SAG (no neighbor to derive size from)."""
        i = sag_idx.get(sag)
        if i is None or i + 1 >= len(sorted_sags):
            return None
        return sorted_sags[i + 1] - sag

    rows = []  # (name, hdrs, n_chunks, min_sag, max_sag, payload_size_bits, retired, note)
    for bbb_name, (chunks, hdrs_or_note) in per_bbb_chunks.items():
        if not chunks:
            rows.append((bbb_name, None, 0, None, None, None,
                         bbb_name in RETIRED_BBB, hdrs_or_note))
            continue
        sags = [c[0] for c in chunks]
        min_sag = min(sags)
        max_sag = max(sags)
        last_size = chunk_size_bits(max_sag)
        if last_size is None:
            # No neighbor — assume zero (range ends at max_sag). Caller
            # should be cautious about this BBB; it's the last payload
            # in the table.
            payload_size_bits = max_sag - min_sag
            end_sag = max_sag
            note = "last in table; end is approximate (no neighbor SAG)"
        else:
            payload_size_bits = (max_sag + last_size) - min_sag
            end_sag = max_sag + last_size
            note = ""
        rows.append((bbb_name, hdrs_or_note, len(chunks), min_sag, end_sag,
                     payload_size_bits, bbb_name in RETIRED_BBB, note))

    rows.sort(key=lambda r: (not r[6], r[3] if r[3] is not None else 0))

    def _flat_range(sag_start: int, sag_end: int):
        """Return (bank, flat_start, flat_end) for a SAG range that lives in
        a single bank, or None if it spans banks or falls outside known
        bank ranges. flat_end is exclusive."""
        try:
            b_start, flat_start = sag_to_flat_byte(sag_start)
            # Convert end SAG; if exactly at the bank boundary, snap to the
            # bank's flat end rather than raising.
            if sag_end == BANK1_SAG_START + 0x02000000:
                b_end = 1
                flat_end = BANK1_FLAT_BASE + 0x02000000 // 8
            else:
                b_end, flat_end = sag_to_flat_byte(sag_end)
        except ValueError:
            return None
        if b_start != b_end:
            return None
        return (b_start, flat_start, flat_end)

    if args.csv:
        print("bbb,hdrs,n_chunks,bank,start_sag,end_sag,size_bits,size_bytes,"
              "flat_start,flat_end,retired,note")
        for (name, hdrs, n, min_sag, end_sag, size_bits, retired, note) in rows:
            if min_sag is None:
                print(f"{name},,0,,,,,,,,{retired},{note}")
                continue
            fr = _flat_range(min_sag, end_sag)
            if fr is None:
                bank_s = flat_s = flat_e = ""
            else:
                bank_s, flat_s, flat_e = fr
                flat_s = f"0x{flat_s:06x}"
                flat_e = f"0x{flat_e:06x}"
            print(f"{name},{hdrs},{n},{bank_s},0x{min_sag:08x},0x{end_sag:08x},"
                  f"{size_bits},{size_bits // 8},{flat_s},{flat_e},{retired},{note}")
        return 0

    out_file = None
    if args.md:
        out_file = repo / "doc" / "RETIRED_RANGES.md"
        out_file.parent.mkdir(exist_ok=True)
        f = out_file.open("w", encoding="utf-8", newline="\n")
    else:
        f = sys.stdout

    def w(*a):
        print(*a, file=f)

    w("# Retired video-ROM SAG ranges\n")
    w(f"Generated by `tools/map_retired_ranges.py` from {source_note}.")
    w("")
    w("Each row is one `BBB>` background payload in `data/MK7MIL.LOD`. "
      "Retired payloads have their runtime callers commented out per the "
      "Outer Haven postmortem — their SAG ranges are candidates for "
      "deliberate overlay by new content.")
    w("")
    w("Addresses are TMS bit-addresses (the format `.long XXXXXXXXh` in "
      "`HDRS` sections). Chunk size is derived from the delta to the next "
      "SAG globally — this sidesteps zero-compression / `PPP>` bpp "
      "uncertainty (we never compute size from W×H).")
    w("")
    w("To overlay a retired range, use `Start SAG`/`End SAG` as the runtime "
      "address window and `Flat start`/`Flat end` as the physical video-ROM "
      "window. The new payload must fit in `Size (bytes)`. For bank-1 LOAD2 "
      "sidecars, the `***>` directive is the raw LOAD2 address plus `,1`, not "
      "necessarily the runtime SAG; for example runtime `0x05e43418` uses "
      "`***> 3E43418,1`.")
    w("")
    def _fmt_flat(sag_start, sag_end):
        fr = _flat_range(sag_start, sag_end)
        if fr is None:
            return "—", "—", "—"
        bank, fs, fe = fr
        return str(bank), f"`0x{fs:06x}`", f"`0x{fe:06x}`"

    w("## Retired (overlay-eligible)\n")
    w("Confirm the new payload's packed size ≤ `Size (bytes)`. The flat-byte "
      "columns are the physical position in the assembled 12 MB video ROM. "
      "For bank-1 sidecars, derive the `***>` directive from the raw LOAD2 "
      "address, not directly from the runtime `Start SAG`.\n")
    w("| BBB | HDRS | Chunks | Bank | Start SAG | End SAG | Flat start | Flat end | Size (bytes) | Reason |")
    w("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for (name, hdrs, n, min_sag, end_sag, size_bits, retired, note) in rows:
        if not retired:
            continue
        if min_sag is None:
            w(f"| `{name}` | — | 0 | — | — | — | — | — | — | {note} |")
            continue
        bank, fs, fe = _fmt_flat(min_sag, end_sag)
        reason = RETIRED_BBB.get(name, "")
        if note:
            reason = f"{reason} ({note})"
        w(f"| `{name}` | `{hdrs}` | {n} | {bank} | `0x{min_sag:08x}` | "
          f"`0x{end_sag:08x}` | {fs} | {fe} | {size_bits // 8:,} | {reason} |")

    w("")
    w("## Live (do not overlay)\n")
    w("| BBB | HDRS | Chunks | Bank | Start SAG | End SAG | Flat start | Flat end | Size (bytes) |")
    w("|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for (name, hdrs, n, min_sag, end_sag, size_bits, retired, note) in rows:
        if retired:
            continue
        if min_sag is None:
            w(f"| `{name}` | — | 0 | — | — | — | — | — | — |")
            continue
        bank, fs, fe = _fmt_flat(min_sag, end_sag)
        w(f"| `{name}` | `{hdrs}` | {n} | {bank} | `0x{min_sag:08x}` | "
          f"`0x{end_sag:08x}` | {fs} | {fe} | {size_bits // 8:,} |")

    if args.verbose:
        w("")
        w("## Per-chunk detail (verbose)\n")
        for (name, hdrs, n, *_) in rows:
            if hdrs is None or hdrs.startswith("missing"):
                continue
            chunks = extract_chunks_from_hdrs(sections.get(hdrs, []))
            w(f"### {name} (`{hdrs}`, {len(chunks)} chunks)\n")
            w("| # | SAG | W | H | Size (bits) | Size (bytes) |")
            w("|---:|---:|---:|---:|---:|---:|")
            for i, (sag, ww, hh) in enumerate(chunks):
                sz_bits = chunk_size_bits(sag)
                sz_str = f"{sz_bits:,}" if sz_bits else "—"
                sb = sz_bits // 8 if sz_bits else None
                sb_str = f"{sb:,}" if sb is not None else "—"
                w(f"| {i} | `0x{sag:08x}` | {ww} | {hh} | {sz_str} | {sb_str} |")
            w("")

    if out_file:
        f.close()
        print(f"wrote {out_file}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
