#!/usr/bin/env python3
"""Generate tools/sag_labels.txt - a flat "SAG<TAB>LABEL<TAB>FILE" index of every
image record in src/.

An image record is a label followed (within a few lines) by

        .word   w,h,anix,aniy
        .long   0<sag>H

so a SAG read out of an object's `osag` / multipart RAM at runtime can be turned
back into the art it is showing.  Used by the MAME probe scripts to name the
sprites they find on screen.
"""
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"
OUT = Path(__file__).resolve().parent / "sag_labels.txt"

LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):?\s*$")
WORD_RE = re.compile(r"^\s+\.word\s", re.IGNORECASE)
LONG_RE = re.compile(r"^\s+\.long\s+0?([0-9A-Fa-f]+)[Hh]\s*$")


def scan(path):
    out = []
    pending = None      # (label, lines_since_label, saw_word)
    try:
        text = path.read_text(errors="replace").splitlines()
    except OSError:
        return out
    for line in text:
        m = LABEL_RE.match(line)
        if m:
            pending = [m.group(1), 0, False]
            continue
        if pending is None:
            continue
        pending[1] += 1
        if WORD_RE.match(line):
            pending[2] = True
            continue
        lm = LONG_RE.match(line)
        if lm and pending[2]:
            sag = int(lm.group(1), 16)
            # image-data bit addresses only - skips code/table pointers.  MK2 art
            # spans roughly 0x01exxxxx (low MK2MIL frames) up to 0x0dxxxxxx.
            if 0x01800000 <= sag < 0x10000000:
                out.append((sag, pending[0], path.name))
            pending = None
            continue
        if pending[1] > 4:
            pending = None
    return out


def main():
    records = []
    for pattern in ("*.TBL", "*.ASM"):
        for path in sorted(SRC.glob(pattern)):
            records.extend(scan(path))
    seen = {}
    with OUT.open("w") as fh:
        for sag, label, src in records:
            # first definition wins; note collisions on stderr only
            if sag in seen:
                continue
            seen[sag] = label
            fh.write("%08x\t%s\t%s\n" % (sag, label, src))
    print("wrote %s (%d unique SAGs from %d records)" % (OUT, len(seen), len(records)))


if __name__ == "__main__":
    sys.exit(main())
