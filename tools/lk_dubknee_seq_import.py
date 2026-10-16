#!/usr/bin/env python3
"""Generate a_lkdubknee (src/MKLK.ASM) from DUBLKNEESQ in data/KANG3.IMG.

    python tools/lk_dubknee_seq_import.py            # rewrite the block
    python tools/lk_dubknee_seq_import.py --check    # fail if it drifted (Phase D)
    python tools/lk_dubknee_seq_import.py --dump     # just print the sequence

LIU KANG'S DOUBLE KNEE is authored, not coded: `DUBLKNEESQ` is a sequence
Midway embedded in KANG3.IMG in 1993 and never wired up.  The lane the game
plays is generated from it here, so editing the sequence in IMGTOOL and
re-running this is the whole workflow - never hand-edit the block.

THE TICK CONVERSION IS THE WHOLE POINT OF THIS FILE.

A seqscr entry's hold byte is a count of PREVIEW ticks, not game ticks, and
one preview tick is `round(54.7 / fps)` game ticks (doc/IMGTOOL_LANE_CONVERSION
.md, and the note in CLAUDE.md: "authoring at 13.675 or 27.35 fps makes the
preview match the game exactly").  DUBLKNEESQ is authored at IMGTOOL's
13.7 fps, which is exactly `TICKS_PER_PREVIEW` below.

Reading the hold byte as GAME ticks makes the whole move 11 ticks long - a
flicker at 54.7 Hz - which is what happened on the first cut of this move:
the authored timing was dismissed as too fast to be real and replaced with
invented per-part speeds that ran the carry-on about twice the intended rate.
The sequence was right all along.  It is:

    LKKNEE1 1   LKKNEE2 1   LKKNEE3 3        <- these three ARE a_lkknee
    LKDUBLKNEE1 1   LKDUBLKNEE2 2
    LKDUBLKNEE3 1   LKDUBLKNEE4 1   LKBACKFIST1 1

x4 = 4, 4, 12 | 4, 8 | 4, 4, 4 game ticks.

The first three frames are the ORDINARY KNEE, which `lk_knee` (MKLKDK.ASM)
plays at retail's own speed so that an unlinked knee is unchanged - so they
are skipped here and only the carry-on is emitted.
"""
import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import imgdump  # noqa: E402

IMG = ROOT / "data" / "KANG3.IMG"
ASM = ROOT / "src" / "MKLK.ASM"
SEQ = "DUBLKNEESQ"

# one preview tick, in game ticks.  IMGTOOL previews DUBLKNEESQ at 13.7 fps
# and round(54.7068 / 13.7) == 4.
TICKS_PER_PREVIEW = 4

# the frames lk_knee already plays as the ordinary knee
SKIP_LEADING = ("LKKNEE1", "LKKNEE2", "LKKNEE3")

# where the part breaks go, and what lk_double_knee does with each part
PARTS = {
    "LKDUBLKNEE2": "part 1 - the wind-up",
    "LKDUBLKNEE3": "part 2 - the contact frame (its hold IS its active ticks)",
    "LKDUBLKNEE4": "part 3 - the drop",
    "LKBACKFIST1": "part 4 - the recovery (the victim is spiked: lk_spike, MKLKDK)",
}

BEGIN = "* --- BEGIN GENERATED (tools/lk_dubknee_seq_import.py) - do not hand-edit\n"
END = "* --- END GENERATED\n"


def image_names(data):
    imgcnt, palcnt, oset = struct.unpack_from("<HHI", data, 0)
    _, img_start, _ = imgdump.detect_record_layout(data, oset, imgcnt, palcnt)
    return [imgdump.cstr(imgdump.IMAGE.unpack_from(data, img_start + i * imgdump.IMAGE.size)[0])
            for i in range(imgcnt)]


def read_sequence(data, names, want):
    """(name, hold) in PLAY order.  The list is stored NEWEST-FIRST."""
    needle = want.encode("ascii") + b"\x00"
    at = data.find(needle)
    if at < 0:
        raise SystemExit(f"{want} not found in {IMG.name}")
    count = struct.unpack_from("<H", data, at + 0x12)[0]
    base = at + 0x64
    out = []
    for i in range(count):
        _, idx, hold, _junk = struct.unpack_from("<HHBB", data, base + i * 18)
        if idx >= len(names):
            raise SystemExit(f"{want} entry {i} image index {idx} out of range")
        out.append((names[idx], hold))
    return list(reversed(out))


def render(entries):
    body = [BEGIN]
    for name, hold in entries:
        ticks = hold * TICKS_PER_PREVIEW
        body.append("\t.long\t%s,%d\n" % (name, ticks))
        note = PARTS.get(name)
        if note:
            body.append("\t.long\t0\t\t\t; %s\n" % note)
    body.append(END)
    return "".join(body)


def current(text):
    try:
        a = text.index(BEGIN)
        b = text.index(END) + len(END)
    except ValueError:
        raise SystemExit("markers not found in src/MKLK.ASM - put the BEGIN/END "
                         "GENERATED pair back around a_lkdubknee's body")
    return a, b, text[a:b]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dump", action="store_true")
    args = ap.parse_args()

    data = IMG.read_bytes()
    entries = read_sequence(data, image_names(data), SEQ)

    lead = tuple(n for n, _ in entries[:len(SKIP_LEADING)])
    if lead != SKIP_LEADING:
        raise SystemExit(f"{SEQ} no longer starts with {SKIP_LEADING} (got {lead}) - "
                         "lk_knee plays those three, so the split has moved")
    carry = entries[len(SKIP_LEADING):]

    if args.dump:
        print(f"{SEQ}: {len(entries)} entries, {TICKS_PER_PREVIEW} game ticks per preview tick")
        for name, hold in entries:
            tag = "  (a_lkknee, played by lk_knee)" if name in SKIP_LEADING else ""
            print(f"  {name:<14} {hold} x{TICKS_PER_PREVIEW} = {hold * TICKS_PER_PREVIEW:2d} ticks{tag}")
        print(f"  carry-on total: {sum(h for _, h in carry) * TICKS_PER_PREVIEW} ticks")
        return 0

    missing = [n for n in PARTS if n not in {x for x, _ in carry}]
    if missing:
        raise SystemExit(f"{SEQ} no longer contains {missing} - PARTS needs updating "
                         "together with lk_double_knee's walk (MKLKDK.ASM)")

    want = render(carry)
    text = ASM.read_text()
    a, b, have = current(text)

    if args.check:
        if have != want:
            print("a_lkdubknee DRIFTED from DUBLKNEESQ in data/KANG3.IMG")
            print("--- in src/MKLK.ASM\n" + have)
            print("+++ from the IMG\n" + want)
            print("regenerate: python tools/lk_dubknee_seq_import.py")
            return 1
        print("a_lkdubknee OK (%d frames, %d ticks)"
              % (len(carry), sum(h for _, h in carry) * TICKS_PER_PREVIEW))
        return 0

    if have == want:
        print("a_lkdubknee already current")
        return 0
    ASM.write_text(text[:a] + want + text[b:])
    print("rewrote a_lkdubknee (%d frames, %d ticks)"
          % (len(carry), sum(h for _, h in carry) * TICKS_PER_PREVIEW))
    return 0


if __name__ == "__main__":
    sys.exit(main())
