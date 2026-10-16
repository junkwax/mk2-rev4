#!/usr/bin/env python
"""Prove ani2's guards can never bite real art.

`ani2` (MKUTIL.ASM) refuses a multipart piece whose size cannot be real, and
stops a piece list that will not fit the buffer it is being laid into.  Those
limits live in src/DISPEQU.ASM (`mp_maxx`, `mp_maxy`, `mp_max`) and in
MKUTIL.ASM (`ANI2_PROCMAX`), and they are only safe while every piece and
every list in the build is comfortably inside them - so this measures them.

The guards are what stops a runaway list from rebooting the cabinet; see the
long note on `mp_max` in DISPEQU.ASM.  If art ever grows past one of these
numbers, the symptom is a piece silently missing from a frame, which is
exactly the kind of thing nobody notices for a year.  Hence --check.

    python tools/audit_piece_sizes.py           # report
    python tools/audit_piece_sizes.py --check   # exit 1 if art is at the limit
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

# A piece record: a label, then its geometry, then its SAG.  Both spellings
# ("NAME:" in the generated .TBL, "NAME" alone in hand-written .ASM) occur.
REC_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*):?[ \t]*(?:;.*)?$\r?\n"
    r"^[ \t]+\.word[ \t]+(-?\d+)[ \t]*,[ \t]*(-?\d+)[ \t]*,[ \t]*(-?\d+)[ \t]*,[ \t]*(-?\d+)[ \t]*(?:;.*)?$\r?\n"
    r"^[ \t]+\.long[ \t]",
    re.MULTILINE,
)

LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):?[ \t]*(?:;.*)?$")
LONG_RE = re.compile(r"^[ \t]+\.long[ \t]+(.*)$")
# A multipart piece is named <stem><letter>: FISTPULP3A..FISTPULP3S,
# STONEBASEA/B, NJGLORING1A/1B.  An animation SCRIPT lists whole frames
# instead - GOOBER1..GOOBER14, SPURT1..8, TREEANI1..7 - and never reaches
# ani2, so counting those as piece lists would put the cap in the wrong place.
SUFFIX_RE = re.compile(r"^(.*[A-Za-z0-9])([A-Z])$")


def read(path):
    return path.read_text(encoding="latin-1")


def collect_pieces():
    """name -> (file, line, W, H)"""
    pieces = {}
    for f in sorted(SRC.glob("*.TBL")) + sorted(SRC.glob("*.ASM")):
        text = read(f)
        for m in REC_RE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            pieces[m.group(1)] = (f.name, line, int(m.group(2)), int(m.group(3)))
    return pieces


def is_multipart(entries):
    """True when the entries look like the PIECES of one frame."""
    stems = {}
    for e in entries:
        m = SUFFIX_RE.match(e)
        if m:
            stems.setdefault(m.group(1), 0)
            stems[m.group(1)] += 1
    return any(n >= 2 for n in stems.values())


def collect_lists(pieces):
    """[(file, line, label, n)] for every multipart piece list.

    A list is a label followed by one or more .long lines and terminated by a
    0 entry.  Only runs that actually name known piece records are counted -
    the same shape is used for plain pointer tables all over the source.
    """
    out = []
    for f in sorted(SRC.glob("*.ASM")) + sorted(SRC.glob("*.TBL")):
        lines = read(f).splitlines()
        label, line_no, entries, open_list = None, 0, [], False
        for n, raw in enumerate(lines, 1):
            s = raw.split(";")[0].rstrip()
            if not s.strip():
                continue
            m = LABEL_RE.match(s)
            if m:
                label, line_no, entries, open_list = m.group(1), n, [], True
                continue
            m = LONG_RE.match(s)
            if m and open_list:
                for e in m.group(1).split(","):
                    e = e.strip()
                    if e in ("0", "0h", "00h"):
                        known = [x for x in entries if x in pieces]
                        if known and is_multipart(entries):
                            out.append((f.name, line_no, label, len(entries)))
                        open_list = False
                        break
                    entries.append(e)
                continue
            open_list = False
    return out


def equates():
    """The limits, read out of the source rather than repeated here."""
    vals = {}
    disp = read(SRC / "DISPEQU.ASM")
    for name in ("mp_max", "mp_maxx", "mp_maxy"):
        m = re.search(r"^%s[ \t]+\.set[ \t]+(\d+)" % name, disp, re.MULTILINE)
        vals[name] = int(m.group(1)) if m else None
    # ANI2_PROCMAX is (prcsiz-pdata-32)/mp_length, all from MAINEQU/DISPEQU.
    mainequ = read(SRC / "MAINEQU.ASM")

    def hexequ(text, name):
        m = re.search(r"^%s[ \t]+\.set[ \t]+([0-9a-fA-F]+)h" % name, text, re.MULTILINE)
        return int(m.group(1), 16) if m else None

    prcsiz, pdata = hexequ(mainequ, "prcsiz"), hexequ(mainequ, "pdata")
    m = re.search(r"^mp_length[ \t]+\.set[ \t]+(.+?)[ \t]*(?:;.*)?$", disp, re.MULTILINE)
    mp_length = eval(m.group(1)) if m else None
    vals["mp_length"] = mp_length
    vals["ANI2_PROCMAX"] = (prcsiz - pdata - 32) // mp_length
    return vals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if art exceeds a limit")
    args = ap.parse_args()

    lim = equates()
    pieces = collect_pieces()
    lists = collect_lists(pieces)

    widest = max(pieces.items(), key=lambda kv: kv[1][2])
    tallest = max(pieces.items(), key=lambda kv: kv[1][3])
    longest = max(lists, key=lambda t: t[3]) if lists else None

    print("%d piece records, %d piece lists" % (len(pieces), len(lists)))
    print("  widest   %-22s %4d  (mp_maxx %d)  %s:%d"
          % (widest[0], widest[1][2], lim["mp_maxx"], widest[1][0], widest[1][1]))
    print("  tallest  %-22s %4d  (mp_maxy %d)  %s:%d"
          % (tallest[0], tallest[1][3], lim["mp_maxy"], widest[1][0], tallest[1][1]))
    if longest:
        print("  longest  %-22s %4d  (mp_max %d)  %s:%d"
              % (longest[2], longest[3], lim["mp_max"], longest[0], longest[1]))

    # Lists too long for a PROCESS BLOCK are legal only if their object gets a
    # dedicated shape RAM.  There is no way to tell statically which buffer a
    # list is drawn into, so name them and let a human keep the answer.
    fat = sorted((n, f, ln, lab) for f, ln, lab, n in lists if n > lim["ANI2_PROCMAX"])
    if fat:
        print("\n  %d list(s) longer than a process block's %d nodes - each of these"
              % (len(fat), lim["ANI2_PROCMAX"]))
        print("  MUST be drawn into a dedicated shape RAM, never a gmo_proc object:")
        for n, f, ln, lab in fat:
            print("    %-24s %2d pieces   %s:%d" % (lab, n, f, ln))

    bad = []
    if widest[1][2] > lim["mp_maxx"]:
        bad.append("%s is %d wide, past mp_maxx %d" % (widest[0], widest[1][2], lim["mp_maxx"]))
    if tallest[1][3] > lim["mp_maxy"]:
        bad.append("%s is %d tall, past mp_maxy %d" % (tallest[0], tallest[1][3], lim["mp_maxy"]))
    if longest and longest[3] > lim["mp_max"]:
        bad.append("%s has %d pieces, past mp_max %d" % (longest[2], longest[3], lim["mp_max"]))

    if bad:
        print("\nFAIL - ani2 would silently drop real art:")
        for b in bad:
            print("  " + b)
        return 1 if args.check else 0
    print("\nOK - every piece and every list is inside ani2's guards")
    return 0


if __name__ == "__main__":
    sys.exit(main())
