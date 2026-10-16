#!/usr/bin/env python3
"""
Which `BBB>` background payloads in data/MK7MIL.LOD are unreachable, and
exactly how many video-ROM bytes are theirs ALONE.

Why a tool and not a table: every SAG in here moves whenever anything ahead
of it in MK7MIL repacks, so a hand-written address list is wrong by the next
build. Re-run this after any build that touches MK7MIL.

How the BBB -> data mapping is established
------------------------------------------
NOT by guessing at bddtool's truncated label names. LOAD2 emits BGNDTBL.ASM
sections in `BBB>` order, one HDRS section per background followed by its
BLKS/BMOD labels, so walking `tmp/load2/BGNDTBL.MK7` in parallel with the
`BBB>` list in the LOD is exact. (That is how MK1CAVE was found to own
fu7HDRS/dun1-10BLKS, which an earlier pass had misattributed to Pit II.)

Reachability
------------
A background's blocks are reachable if its `*_mod` in src/BGND.ASM can be
selected. Each retired entry below was checked by hand to the call site; the
evidence string is printed with the row. The mods live in `table_o_mods` and
are ALSO selectable by `curback` index, so an entry is only retired when
nothing loads it by name AND no live path sets that index.

Shared blocks are safe
----------------------
LOAD2 dedups identical source blocks across BBB payloads onto one SAG, so a
block a live background also declares stays packed when a retired one is
removed. Only the EXCLUSIVE chunks disappear - which is exactly the number
this tool reports.

Usage:
    python tools/retired_bgnd_audit.py            # summary
    python tools/retired_bgnd_audit.py --md       # doc/RETIRED_BGND_RECLAIM.md
    python tools/retired_bgnd_audit.py --check    # nonzero if a LIVE bbb lost
                                                  # its BBB> line
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import map_retired_ranges as M  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LOD = ROOT / "data" / "MK7MIL.LOD"
SNAP = ROOT / "tmp" / "load2" / "BGNDTBL.MK7"

# Verified 2026-09-09 by walking each *_mod to its call site.  "retired" means
# NOTHING can select the mod: no `movi <mod>,a0` anywhere, and every routine
# that would set its table_o_mods index is commented out.
RETIRED = {
    "MKSTORY1": ("end_h_mod   idx 12",
                 "no movi; endings removed 2026-08-11, the_story jsrp's all commented (MKAMODE.ASM:75)"),
    "MKSTORY2": ("end_v_mod   idx 13", "as MKSTORY1"),
    "MKSTORY3": ("(no BMOD)",
                 "BGND.ASM contains no `.long STORY3BMOD` at all - unreferenced even by a table"),
    "ATRAX1":   ("atrax1_mod  idx 0e", "only reachable from the_story; every jsrp commented"),
    "ATRAX2":   ("atrax2_mod  idx 0f", "as ATRAX1"),
    "ATRAX3":   ("atrax3_mod  idx 10", "as ATRAX1"),
    "ATRAX4":   ("atrax4_mod  idx 11", "as ATRAX1"),
    "MKTEAM":   ("team_mod    idx 0b",
                 "team_mod has exactly 2 mentions in src/ - the table entry and its own definition"),
    "HISCORE1": ("hstd_mod    idx 15",
                 "only user is high_score_background (MKHSTD.ASM:883); its 2 callers are "
                 "print_rankings (all jsrp commented) and amode_button_hstd (no callers)"),
    "COMESOON": ("(no BMOD)",
                 "advertise_comic jsrp's all commented (MKAMODE.ASM:90/98/431); no `.long comesoonBMOD`"),
    "STORY1":   ("bio_mod     idx 14", "only reachable from the_story; every jsrp commented"),
}

# Checked and found LIVE - an earlier RETIRED_BBB list in
# tools/map_retired_ranges.py has some of these wrong.  Do not remove.
LIVE_NOTES = {
    "NUENT1": "LIVE - initials1_mod, loaded by enter_initials (MKHSTD.ASM:119); "
              "check_enter_initials is called from MAIN.ASM:618",
    "NUENT2": "LIVE - initials2_mod (MKHSTD.ASM:120), same path",
    "MKHUGE": "LIVE - huge_mod, huge_mk_logo is called uncommented at MKAMODE.ASM:80",
    "MK1CAVE": "LIVE - mk1_mod idx 9, GORO'S LAIR (owns fu7HDRS + dun1-10BLKS)",
    "MKVERSUS": "LIVE - vs_mod, MKSEL.ASM:4887",
    "MK1PIT": "LIVE - its chunks are reached through MK1PITBG.ASM, which Phase B2c "
              "regenerates; the emitted bridge0/1BMOD are unused but the DATA is not",
}


def load():
    bbb = [l.split(">", 1)[1].strip()
           for l in LOD.read_text(errors="replace").splitlines()
           if l.startswith("BBB>")]
    lines = SNAP.read_text(errors="replace").splitlines()
    labels, body, cur = [], {}, None
    for l in lines:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", l)
        if m:
            cur = m.group(1)
            labels.append(cur)
            body[cur] = []
        elif cur:
            body[cur].append(l)

    groups, g = [], None
    for L in labels:
        if L.upper().endswith("HDRS"):
            g = {"hdrs": L, "labels": [L]}
            groups.append(g)
        elif g:
            g["labels"].append(L)
    if len(groups) != len(bbb):
        raise SystemExit(
            "BBB count %d != HDRS section count %d - the LOD and the snapshot "
            "are out of step; re-run `python build.py`." % (len(bbb), len(groups)))
    return bbb, dict(zip(bbb, groups)), body


def analyse():
    bbb, own, body = load()
    chunks = {}
    geom = {}
    for name, g in own.items():
        cs = M.extract_chunks_from_hdrs(body[g["hdrs"]])
        chunks[name] = {c[0] for c in cs}
        for sag, w, h in cs:
            geom.setdefault(sag, (w, h))
    allsag = sorted(set().union(*chunks.values()))
    idx = {s: i for i, s in enumerate(allsag)}

    def size(s):
        i = idx[s]
        return (allsag[i + 1] - s) // 8 if i + 1 < len(allsag) else 0

    live, ret = set(), set()
    for n, cs in chunks.items():
        (ret if n in RETIRED else live).update(cs)
    excl = sorted(ret - live)
    return bbb, own, chunks, geom, allsag, size, live, ret, excl


def runs_of(excl, allsag, size):
    es, runs, cur = set(excl), [], []
    for s in allsag:
        if s in es:
            cur.append(s)
        elif cur:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    runs.sort(key=lambda r: -sum(size(s) for s in r))
    return runs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    bbb, own, chunks, geom, allsag, size, live, ret, excl = analyse()

    if a.check:
        gone = [n for n in list(RETIRED) + list(LIVE_NOTES) if n not in bbb]
        bad = [n for n in gone if n in LIVE_NOTES]
        for n in gone:
            print("%s: BBB> line no longer in MK7MIL.LOD%s"
                  % (n, "  <-- LIVE, THIS IS A BUG" if n in LIVE_NOTES else "  (retired, expected)"))
        if bad:
            print("FAIL: %d live background(s) removed" % len(bad))
            return 1
        print("OK: every live BBB> is still present")
        return 0

    total = sum(size(s) for s in excl)
    runs = runs_of(excl, allsag, size)

    if not a.md:
        print("retired BBBs %d / live %d" % (len(RETIRED), len(bbb) - len(RETIRED)))
        print("chunks: retired %d, shared with live %d, exclusive %d"
              % (len(ret), len(ret & live), len(excl)))
        print("EXCLUSIVE bytes: %s" % format(total, ","))
        for n in sorted(RETIRED):
            if n not in chunks:
                print("  %-10s ALREADY REMOVED" % n)
                continue
            e = [c for c in chunks[n] if c not in live]
            print("  %-10s %-10s %3d chunks, %3d exclusive, %9s bytes"
                  % (n, own[n]["hdrs"], len(chunks[n]), len(e),
                     format(sum(size(c) for c in e), ",")))
        print("\ncontiguous exclusive runs:")
        for r in runs:
            print("  %#09x..%#09x  %3d chunks %9s bytes"
                  % (M.sag_to_flat_byte(r[0])[1],
                     M.sag_to_flat_byte(r[-1])[1] + size(r[-1]),
                     len(r), format(sum(size(s) for s in r), ",")))
        return 0

    P = print
    P("# Retired background reclaim")
    P("")
    P("Generated by `python tools/retired_bgnd_audit.py --md`. **Every address")
    P("here moves on the next MK7MIL repack** - regenerate rather than trusting")
    P("a stale copy.")
    P("")
    P("## What this is")
    P("")
    P("`data/MK7MIL.LOD` packs %d background payloads via `BBB>`. %d of them"
      % (len(bbb), len(RETIRED)))
    P("cannot be reached by any code path. Their blocks are in the video ROM of")
    P("every build. Removing the `BBB>` line stops LOAD2 packing them.")
    P("")
    P("LOAD2 dedups identical source blocks across payloads onto a single SAG,")
    P("so a block a **live** background also declares survives the removal.")
    P("Only chunks exclusive to retired payloads disappear - **%s bytes**."
      % format(total, ","))
    P("")
    P("| | count |")
    P("|---|---:|")
    P("| chunks referenced by a retired payload | %d |" % len(ret))
    P("| ...also referenced by a live payload (KEPT) | %d |" % len(ret & live))
    P("| ...exclusive to retired payloads (FREED) | %d |" % len(excl))
    P("")

    P("## The retired payloads")
    P("")
    P("| BBB | HDRS | mod / index | chunks | excl | bytes | evidence |")
    P("|---|---|---|---:|---:|---:|---|")
    for n in sorted(RETIRED, key=lambda x: -sum(
            size(c) for c in chunks.get(x, ()) if c not in live)):
        if n not in chunks:
            P("| `%s` | - | %s | - | - | ALREADY REMOVED | %s |"
              % (n, RETIRED[n][0], RETIRED[n][1]))
            continue
        e = [c for c in chunks[n] if c not in live]
        P("| `%s` | `%s` | `%s` | %d | %d | %s | %s |"
          % (n, own[n]["hdrs"], RETIRED[n][0], len(chunks[n]), len(e),
             format(sum(size(c) for c in e), ","), RETIRED[n][1]))
    P("")

    P("## Backgrounds that look retired and are NOT")
    P("")
    P("`tools/map_retired_ranges.py` has an older `RETIRED_BBB` set that lists")
    P("NUENT1/NUENT2 as retired. They are not. Removing these breaks a screen:")
    P("")
    for n, why in sorted(LIVE_NOTES.items()):
        P("- **`%s`** - %s" % (n, why))
    P("")

    P("## Contiguous runs freed")
    P("")
    P("| flat start | flat end | chunks | bytes |")
    P("|---|---|---:|---:|")
    for r in runs:
        P("| `%#09x` | `%#09x` | %d | %s |"
          % (M.sag_to_flat_byte(r[0])[1],
             M.sag_to_flat_byte(r[-1])[1] + size(r[-1]),
             len(r), format(sum(size(s) for s in r), ",")))
    P("")

    P("## Every exclusive chunk (the rollback manifest)")
    P("")
    P("Owner is the retired payload(s) that declare the chunk.")
    P("")
    P("| SAG | flat byte | w x h | bytes | owners |")
    P("|---|---|---|---:|---|")
    for s in excl:
        ow = sorted(n for n in RETIRED if n in chunks and s in chunks[n])
        w, h = geom.get(s, (0, 0))
        P("| `%#010x` | `%#09x` | %dx%d | %s | %s |"
          % (s, M.sag_to_flat_byte(s)[1], w, h, format(size(s), ","),
             ", ".join(ow)))
    P("")

    P("## How to remove")
    P("")
    P("Delete the `BBB> <NAME>` line from `data/MK7MIL.LOD` and rebuild")
    P("(`python build.py`). Nothing else needs to change:")
    P("")
    P("- **Do NOT touch `table_o_mods` in `src/BGND.ASM`.** It is indexed by")
    P("  `curback`; deleting an entry shifts every index after it and would")
    P("  repoint Outer Haven (16), FLAPJACK (17) and Yoteigai Tor (18).")
    P("- **Do NOT delete the sections from `src/BGNDTBL.ASM`.** The promoters")
    P("  classify a label missing from the snapshot as `src_only` and preserve")
    P("  it untouched, so the build stays quiet.")
    P("")
    P("## Rollback")
    P("")
    P("Restore the `BBB> <NAME>` line and rebuild. The payload is rebuilt from")
    P("the same BDB/BDD on disk, so nothing is lost by removing it - the art is")
    P("in `data/`, not only in the ROM.")
    P("")
    P("**The hazard is a partial rollback.** After removal, the `*HDRS`")
    P("sections still sitting in `src/BGNDTBL.ASM` keep their last-known SAGs,")
    P("which now point at whatever moved into those addresses. That is inert")
    P("only while nothing can select the mod. If you ever re-enable")
    P("`the_story`, `advertise_comic` or `print_rankings`, **restore the")
    P("`BBB>` line first** or the screen decodes unrelated pixels - the exact")
    P("failure mode of the ACIDHANG hangers.")
    P("")
    P("`python tools/retired_bgnd_audit.py --check` fails if a LIVE payload's")
    P("`BBB>` line ever goes missing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
