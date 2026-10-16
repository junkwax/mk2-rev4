#!/usr/bin/env python3
"""Keep Ermac's re-anchored lift-windup records in step with the ninja art.

Ermac's telekinetic-lift windup reuses three STOCK ninja frames - NJELBO1,
NJELBO2 and NJHIPUNCH7 - but at anipoints the user re-authored in IMGTOOL so
the four poses share one anchor (anix 22) and rise together.  Two of them
moved:

    NJELBO2     composite aniy  -2  ->  -3   (whole frame 1px lower)
    NJHIPUNCH7  composite anix  20  ->  22   (whole frame 2px further back)

NJELBO1 did not move and is used as-is.

Re-cutting the art was not an option: these are MK4MIL frames that Sub-Zero,
Scorpion and Reptile all draw, and moving their anipoints would move the pose
for every ninja in the game.  Duplicating the PIXELS into Ermac's sidecar was
not an option either - the two frames pack to about 10 KB and the sidecar slot
has 8,132 bytes left.

So `src/MKNJ.TBL` carries CLONE records - `ERELBO2A/B`, `ERHIPUNCH7A/B/C` -
that point at the same SAGs with shifted anipoints.  promote_tbls MERGES
MKNJ.TBL rather than regenerating it, so src-only labels like these survive
promotion untouched... which is exactly the problem: LOAD2 never emits them,
so nothing would ever update their SAG when the ninja art moves.  A stale SAG
does not draw a wrong picture, it draws torn rows from whatever moved in
underneath.

This is the syncer for that, in the shape sync_jc_kheart_open.py established:
copy W/H/SAG/control from the source record every build, keep the anipoint
override, and fail the build if they have drifted.

    python tools/sync_ermac_lane.py            # report
    python tools/sync_ermac_lane.py --check    # Phase D gate, non-zero on drift
    python tools/sync_ermac_lane.py --apply    # rewrite the clones
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "src" / "MKNJ.TBL"

# clone -> (source record, d_anix, d_aniy)
#
# Adding a constant to EVERY strip of a composite shifts the whole composite by
# that amount and leaves the strips' relative layout alone.  The composite
# anchor is max(anix) / max(aniy) over the strips, so +2 on every anix moves the
# composite anix 20 -> 22.
CLONES = {
    "ERELBO2A":    ("NJELBO2A",    0, -1),
    "ERELBO2B":    ("NJELBO2B",    0, -1),
    "ERHIPUNCH7A": ("NJHIPUNCH7A", 2,  0),
    "ERHIPUNCH7B": ("NJHIPUNCH7B", 2,  0),
    "ERHIPUNCH7C": ("NJHIPUNCH7C", 2,  0),
}

REC = re.compile(
    r"^(?P<name>[A-Za-z_][A-Za-z0-9_]*):[ \t]*\r?\n"
    r"(?P<wline>[ \t]*\.word[ \t]+(?P<w>-?\d+),(?P<h>-?\d+),"
    r"(?P<ax>-?\d+),(?P<ay>-?\d+)[ \t]*\r?\n)"
    r"(?P<sline>[ \t]*\.long[ \t]+(?P<sag>[0-9A-Fa-f]+)H[ \t]*\r?\n)"
    r"(?P<cline>[ \t]*\.word[ \t]+(?P<ctrl>[0-9A-Fa-f]+)H[ \t]*\r?\n)",
    re.MULTILINE)


def parse(text):
    out = {}
    for m in REC.finditer(text):
        out[m.group("name")] = dict(
            w=int(m.group("w")), h=int(m.group("h")),
            ax=int(m.group("ax")), ay=int(m.group("ay")),
            sag=m.group("sag"), ctrl=m.group("ctrl"), span=m.span())
    return out


def wanted(recs, name):
    src, dax, day = CLONES[name]
    if src not in recs:
        return None, "source record %s not in %s" % (src, TBL.name)
    s = recs[src]
    return dict(w=s["w"], h=s["h"], ax=s["ax"] + dax, ay=s["ay"] + day,
                sag=s["sag"], ctrl=s["ctrl"]), None


def render(name, r, eol):
    src, dax, day = CLONES[name]
    note = []
    if dax:
        note.append("anix %+d" % dax)
    if day:
        note.append("aniy %+d" % day)
    return (
        "%s:%s"
        "\t.word   %d,%d,%d,%d%s"
        "\t.long   0%sH%s"
        "\t.word   0%sH%s"
        % (name, eol, r["w"], r["h"], r["ax"], r["ay"], eol,
           r["sag"], eol, r["ctrl"], eol))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true",
                   help="exit non-zero if any clone has drifted")
    g.add_argument("--apply", action="store_true", help="rewrite the clones")
    args = ap.parse_args()

    text = TBL.read_text(encoding="latin-1", newline="")
    eol = "\r\n" if "\r\n" in text else "\n"
    recs = parse(text)

    missing = [n for n in CLONES if n not in recs]
    drift = []
    for name in CLONES:
        want, err = wanted(recs, name)
        if err:
            print("ERROR: %s" % err)
            return 2
        if name in missing:
            continue
        have = recs[name]
        # Compare the hex fields NUMERICALLY.  They are captured as written,
        # so `002282f9a` and `0002282f9a` are the same address with different
        # leading-zero padding - a string compare calls that drift forever.
        def same(k):
            if k in ("sag", "ctrl"):
                return int(have[k], 16) == int(want[k], 16)
            return have[k] == want[k]
        diffs = [k for k in ("w", "h", "ax", "ay", "sag", "ctrl") if not same(k)]
        if diffs:
            drift.append((name, diffs, have, want))

    if not missing and not drift:
        print("ermac lane clones: %d records, all in step with the ninja art"
              % len(CLONES))
        return 0

    for name in missing:
        want, _ = wanted(recs, name)
        print("MISSING  %-13s would be %dx%d ani=%d,%d sag=%s ctrl=%s"
              % (name, want["w"], want["h"], want["ax"], want["ay"],
                 want["sag"], want["ctrl"]))
    for name, diffs, have, want in drift:
        print("DRIFTED  %-13s %s" % (name, ", ".join(
            "%s %s -> %s" % (k, have[k], want[k]) for k in diffs)))

    if args.check:
        print("\nRun `python tools/sync_ermac_lane.py --apply` to fix.")
        return 1
    if not args.apply:
        print("\n(report only - pass --apply to write, --check to gate a build)")
        return 1

    # Rewrite existing clones in place, append any that are missing.  Done from
    # the end backwards so earlier spans stay valid.
    for name, _, _, want in sorted(drift, key=lambda d: -recs[d[0]]["span"][0]):
        a, b = recs[name]["span"]
        text = text[:a] + render(name, want, eol) + text[b:]
    if missing:
        block = [eol,
                 "* Ermac's lift windup reuses these ninja frames at re-authored",
                 "* anipoints so the four poses share one anchor.  SAME SAGs, so no",
                 "* extra pixels - see tools/sync_ermac_lane.py, which keeps the",
                 "* geometry in step with the source records and gates the build.",
                 ""]
        text = text.rstrip() + eol + eol.join(block).replace("\n", eol)
        for name in CLONES:
            if name in missing:
                want, _ = wanted(recs, name)
                text += render(name, want, eol)
        text += eol
    TBL.write_text(text, encoding="latin-1", newline="")
    print("\nwritten to %s" % TBL)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
