#!/usr/bin/env python3
"""
Every promoted SAG must point inside the payload its own sidecar wrote.

Why this exists
---------------
A sidecar's base address reaches the game through src/<TABLE>.TBL, which
tools/promote_tbls.py refreshes from LOAD2's output.  When that promotion
works, the SAG and the payload move together and nothing looks different.
When it does NOT - a hand-maintained table, a `.set`-only table the record
parser skipped, a LOD rebased without re-running LOAD2 - the table keeps the
OLD address and the game blits whatever moved in underneath it.  Nothing
else in the build notices: the assembler is happy, the linker is happy, and
makevrom only checks payloads against slots, never tables against payloads.

That is exactly what happened on 2026-08-10 while packing bank 0.  Two live
examples the same afternoon:

  * VSNBZIP.TBL, a one-line `VS_NB .set <addr>`, had never been promoted at
    all, because promote_tbls matches records by a label with a trailing
    colon.  It reported "ok" no matter how stale it was.
  * data/UMK3FIRE.LOD was left on a base that the pack had since given to
    MK1SKULL, so its records pointed straight through live art.

This check catches both classes in about a second.

What it does NOT flag
---------------------
Labels no .LOD exports.  Several tables legitimately carry records for art
that is present in the .IMG but deliberately not loaded - MK1SKULL.TBL has
20 of them (the MK1SKEL composites and the MK1FIRE A/B strips; the LOD loads
the other form of each).  Those addresses are stale by definition and
nothing references them, so they are reported only under --verbose.

Sidecars that are built but not written into the ROM (absent from makevrom's
irw_files, e.g. UMK3FIRE while its art is being re-cut) are SKIPPED with a
note rather than failed.

Usage
-----
    python tools/check_sag_coverage.py            # report
    python tools/check_sag_coverage.py --verbose  # also list dead labels
    python tools/check_sag_coverage.py --check    # exit non-zero on failure
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IRW_HEADER = 68
LOAD2_BASE = 0x02000000   # LOD ***> addresses are relative to this, both banks
BANK_SPAN = 0x04000000    # SAG space: bank0 [0,4M bits), bank1 [4M,8M bits)

RECORD_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*):\s*\n\s*\.word[^\n]*\n\s*\.long\s+0([0-9a-fA-F]+)H",
    re.M)

# Pure hand-written equate sources that share label names with real art but do
# not hold SAGs (MKFLOORS' FL_* are floor-layer addresses in their own space).
# Same list promote_tbls.py refuses to touch.
HAND_MAINTAINED = {"MKFLOORS.TBL"}

# Records a .LOD names that its library does not actually contain.  LOAD2 logs
# "Couldn't find image", skips them, and still emits a table entry - so these
# SAGs point outside every payload by construction and always have.  Same set
# tools/check_load2_log.py allows; keep the two in step.
KNOWN_MISSING = (
    {"UGSWORDKICK1C", "UGSWORDKICK2C", "UGSWORDKICK3C"}   # never authored
    | {"ENDMARKER"}                                       # sentinel, not art
    # Dead Pool corner hangers: only Boon's skeleton has pixel data.
    # See doc/DEADPOOL_HANGER_HANDOFF.md.
    | {f"D{who}HANG1{part}"
       for who in ("GEO", "JEFF", "JOHN", "MARK", "SAL", "STEVE", "TONY")
       for part in ("A", "B", "C")}
)


def written_irws():
    """The irw_files list from makevrom.py - the set actually put in the ROM."""
    src = (REPO / "makevrom.py").read_text()
    m = re.search(r"irw_files\s*=\s*\[(.*?)\]", src, re.S)
    if not m:
        sys.exit("error: could not find irw_files in makevrom.py")
    body = re.sub(r"#[^\n]*", "", m.group(1))       # drop commented-out entries
    return set(re.findall(r'"([^"]+\.IRW)"', body))


def sidecars():
    """name -> dict(bank, sag_lo, sag_hi, exports, written)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("makevrom", REPO / "makevrom.py")
    mv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mv)

    live = written_irws()
    out = {}
    for lod in sorted((REPO / "data").glob("*.LOD")):
        name = lod.stem
        irw = REPO / "data" / f"{name}.IRW"
        text = lod.read_text(errors="replace")
        m = re.match(r"\*\*\*>\s*([0-9A-Fa-f]+)(?:\s*,\s*(\d))?", text)
        if not m or not irw.exists():
            continue
        addr = int(m.group(1), 16)
        bank = int(m.group(2)) if m.group(2) else mv.FILE_BANK.get(f"{name}.IRW", 0)
        local = addr - LOAD2_BASE
        size_bits = (irw.stat().st_size - IRW_HEADER) * 8
        # Sprite records and movie frames do NOT store the same thing.
        #   ---> sprites  ->  SAG space: local bit offset + bank * 0x4000000
        #   FRM>  movies   ->  the raw LOAD2 address, verbatim (VS_NB .set 05c6c000h)
        # Comparing a movie equate against the sprite range is a guaranteed
        # false positive - they differ by exactly LOAD2_BASE.
        exports, movies = set(), set()
        for line in text.splitlines():
            if line.startswith("--->"):
                exports.update(n.strip() for n in line[4:].split(",") if n.strip())
            elif line.startswith("FRM>"):
                movies.update(n.strip() for n in line[4:].split(",") if n.strip())
        out[name] = dict(bank=bank,
                         lo=local + bank * BANK_SPAN,
                         hi=local + bank * BANK_SPAN + size_bits,
                         raw_lo=addr,
                         raw_hi=addr + size_bits,
                         exports=exports,
                         movies=movies,
                         written=f"{name}.IRW" in live)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true", help="list unexported (dead) labels too")
    ap.add_argument("--check", action="store_true", help="exit non-zero on failure")
    args = ap.parse_args()

    cars = sidecars()
    # A label can be exported by more than one LOD (the same art name appears
    # in several MIL payloads).  Collect every owner and accept a SAG that is
    # inside ANY of them - picking just one is a false-positive machine.
    owner = {}
    for name, c in cars.items():
        for label in c["exports"] | c["movies"]:
            owner.setdefault(label, set()).add(name)

    bad, dead, skipped, checked = [], [], set(), 0
    for tbl in sorted((REPO / "src").glob("*.TBL")):
        if tbl.name in HAND_MAINTAINED:
            continue
        text = tbl.read_text(errors="replace")
        # sprite records: LABEL: / .word .. / .long <SAG>
        pairs = [(lbl, int(sag, 16), False) for lbl, sag in RECORD_RE.findall(text)]
        # `LABEL .set <addr>` movie equates
        pairs += [(lbl, int(v, 16), True) for lbl, v in
                  re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\s+\.set\s+0?([0-9a-fA-F]+)h",
                             text, re.M | re.I)]
        for label, sag, is_movie in pairs:
            if label in KNOWN_MISSING:
                continue
            owners = owner.get(label)
            if not owners:
                dead.append((tbl.name, label, sag))
                continue
            live_owners = [o for o in owners if cars[o]["written"]]
            if not live_owners:
                skipped.update(owners)
                continue
            checked += 1
            ok = False
            for o in live_owners:
                c = cars[o]
                lo, hi = ((c["raw_lo"], c["raw_hi"]) if is_movie else (c["lo"], c["hi"]))
                if lo <= sag < hi:
                    ok = True
                    break
            if not ok:
                c = cars[live_owners[0]]
                lo, hi = ((c["raw_lo"], c["raw_hi"]) if is_movie else (c["lo"], c["hi"]))
                bad.append((tbl.name, label, sag, "/".join(sorted(live_owners)), lo, hi))

    print(f"checked {checked:,} exported SAGs against {len(cars)} sidecar payloads")
    if skipped:
        for car in sorted(skipped):
            print(f"  SKIP  {car} - built but not in makevrom's irw_files (staged, not shipped)")
    if args.verbose and dead:
        print(f"\n{len(dead)} label(s) no .LOD exports (stale by definition, unreferenced):")
        for t, l, s in dead:
            print(f"  {t:16s} {l:16s} {s:#09x}")

    if bad:
        print(f"\nFAIL - {len(bad)} SAG(s) point outside their own sidecar:")
        for t, l, s, car, lo, hi in bad:
            print(f"  {t:16s} {l:16s} {s:#09x}  not in {car} [{lo:#09x}..{hi:#09x})")
        print("\nUsually means a LOD was rebased without re-running LOAD2 +")
        print("promote_tbls, or the table is not promotable (see promote_tbls.py).")
        return 1

    print("\nPASS - every exported SAG lands inside its own sidecar's payload")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
