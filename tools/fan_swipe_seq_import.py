#!/usr/bin/env python3
r"""Generate the RETURN half of a_fan_swipe from FANSWIPESQ in data/KAT9.IMG.

    python tools/fan_swipe_seq_import.py            # rewrite the blocks
    python tools/fan_swipe_seq_import.py --check    # fail if they drifted (Phase D)
    python tools/fan_swipe_seq_import.py --dump     # just print the sequence

KITANA'S FAN DECAPITATION is only half built in retail.  `FANSWIPESQ`, the
sequence Midway embedded in KAT9.IMG beside the fatality art, is a full
BACK AND FORTH:

    KTFANSWIPE1 2 3 4 5 6 5 4 3 2 1

- the fan goes out, hangs at the top of the swing, and comes back down to her
stance.  The lane the game actually plays (`a_fan_swipe`, src/MKFN.ASM) stops
at the top: part 1 is the swing out, part 2 is two frames of FANSWIPE6, and
that is the end of it.  So the blade crosses the victim ONCE and the whole
return half of the authored animation is unused.

This generates the missing half as two more PARTS on the same lane, and the
timing equates `do_fan_decap` (src/MKDEATH.ASM) drives them with.  Parts 1 and
2 are NOT touched: her Back+HP power punch (`do_fan_swipe`, MOVES.ASM) plays
exactly those two through striker_2 + retract_strike, and rewriting them from
the sequence would silently change a live move's startup and recovery.  What
this does instead is CHECK that the outward half of the sequence still names
the frames that lane plays, so a re-authored FANSWIPESQ fails the build rather
than disagreeing with the code in silence.

THE HOLD BYTES ARE PREVIEW TICKS, NOT GAME TICKS.  One preview tick is
`round(54.7 / fps)` game ticks and FANSWIPESQ is authored at IMGTOOL's
13.7 fps, so the unit is 4 - the same conversion, and the same trap, as
tools/lk_dubknee_seq_import.py documents at length.  Read as game ticks the
whole fatality would be 26 ticks long.  The corroboration that 4 is right is
retail's own code: FANSWIPE6's authored hold is 15 preview ticks = 60 game
ticks, and retail holds it for its two lane frames at 4 plus `sleep 030h` = 56.

THE SEQSCR RECORD LAYOUT IS NOT THE SAME IN EVERY IMG.  KANG3.IMG (which
lk_dubknee_seq_import.py reads) puts the frame list at name+0x64 on an
18-byte stride; KAT9.IMG puts it at name+0x3c on a 16-byte stride, because
its editor records carry 16-bit node pointers where KANG3's carry 32-bit
ones.  Rather than hardcode either, `read_sequence` below solves for (base,
stride) against the record's own count and fails if the candidates disagree.
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import imgdump  # noqa: E402

IMG = ROOT / "data" / "KAT9.IMG"
LANE_ASM = ROOT / "src" / "MKFN.ASM"
DEATH_ASM = ROOT / "src" / "MKDEATH.ASM"
SEQ = "FANSWIPESQ"

# one preview tick, in game ticks: round(54.7068 / 13.7) == 4
TICKS_PER_PREVIEW = 4

# the outward half, as `a_fan_swipe` parts 1 and 2 already play it.  Part 1
# doubles FANSWIPE1 and marks FANSWIPE5 ani_nosleep; part 2 doubles FANSWIPE6.
# Only the ORDER is asserted here, which is what the sequence actually says.
OUT_FRAMES = ["KTFANSWIPE%d" % n for n in (1, 2, 3, 4, 5, 6)]
# how many lane entries part 2 spends on the top-of-swing frame, so the sleep
# that makes up the authored hold can be worked out.  Proved against the ASM.
TOP_FRAME = "KTFANSWIPE6"

LANE_BEGIN = "* --- BEGIN GENERATED (tools/fan_swipe_seq_import.py) - do not hand-edit\n"
LANE_END = "* --- END GENERATED\n"
EQU_BEGIN = "* --- BEGIN GENERATED (tools/fan_swipe_seq_import.py) - do not hand-edit\n"
EQU_END = "* --- END GENERATED\n"


def image_names(data):
    imgcnt, palcnt, oset = struct.unpack_from("<HHI", data, 0)
    _, img_start, _ = imgdump.detect_record_layout(data, oset, imgcnt, palcnt)
    return [imgdump.cstr(imgdump.IMAGE.unpack_from(data, img_start + i * imgdump.IMAGE.size)[0])
            for i in range(imgcnt)]


def read_sequence(data, names, want):
    """[(image name, hold)] in PLAY order.  The list is stored NEWEST-FIRST.

    Entry shape is the same in every IMG seen - u16 zero, u16 image index,
    u8 hold, u8 uninitialised editor junk - but the stride and the offset the
    list starts at are not, so both are solved for.  Every candidate that
    validates must agree, or this fails rather than guessing.
    """
    needle = want.encode("ascii") + b"\x00"
    at = data.find(needle)
    if at < 0:
        raise SystemExit(f"{want} not found in {IMG.name}")
    if struct.unpack_from("<H", data, at + 0x10)[0] != 0x0040:
        raise SystemExit(f"{want} is not a seqscr record (no 40 00 at +0x10)")
    count = struct.unpack_from("<H", data, at + 0x12)[0]
    if not 1 <= count <= 64:
        raise SystemExit(f"{want} frame count {count} is not plausible")

    solutions = {}
    for stride in (16, 18, 20, 24):
        for base in range(at + 0x20, at + 0x80, 2):
            if base + count * stride > len(data):
                continue
            frames = []
            for i in range(count):
                at_i = base + i * stride
                zero, idx, hold, _junk = struct.unpack_from("<HHBB", data, at_i)
                # +0 and +6..+9 are the node's zeroed fields.  Without the
                # second one, windows that happen to land on a run of junk
                # read every frame as image index 0 and validate too.
                if zero or struct.unpack_from("<I", data, at_i + 6)[0]:
                    frames = None
                    break
                if idx >= len(names) or not 1 <= hold <= 0xFF:
                    frames = None
                    break
                frames.append((names[idx], hold))
            if frames:
                solutions.setdefault(tuple(frames), []).append((base - at, stride))
    if not solutions:
        raise SystemExit(f"{want}: no (base, stride) reads {count} sane entries")
    if len(solutions) > 1:
        detail = "; ".join(f"{loc} -> {[n for n, _ in f]}" for f, loc in solutions.items())
        raise SystemExit(f"{want}: ambiguous record layout - {detail}")
    frames, where = next(iter(solutions.items()))
    return list(reversed(frames)), where[0]   # (offset from the name, stride)


def split(entries):
    """(outward, return) halves, split at the single peak frame."""
    names = [n for n, _ in entries]
    if names != OUT_FRAMES + OUT_FRAMES[-2::-1]:
        raise SystemExit(
            f"{SEQ} is no longer the out-and-back {OUT_FRAMES[0]}..{OUT_FRAMES[-1]}..{OUT_FRAMES[0]}\n"
            f"  it reads {names}\n"
            "  a_fan_swipe's parts 1 and 2 and do_fan_decap's two slices are built on that shape")
    n = len(OUT_FRAMES)
    return entries[:n], entries[n:]


def timings(out, back):
    """(ticks per ordinary frame, extra ticks to hold the top of the swing)."""
    holds = {h for _, h in out[:-1]} | {h for _, h in back}
    if holds != {1}:
        raise SystemExit(f"{SEQ}: every frame but the peak used to hold 1 preview tick, now {sorted(holds)} - "
                         "do_fan_decap drives each part with a single rate, so it needs re-cutting")
    rate = TICKS_PER_PREVIEW
    top = out[-1][1] * TICKS_PER_PREVIEW
    spent = lane_top_frames() * rate
    if top < spent:
        raise SystemExit(f"{SEQ}: {TOP_FRAME} is authored at {top} ticks but a_fan_swipe's part 2 "
                         f"already spends {spent} on it")
    if rate > 32:
        raise SystemExit(f"{SEQ}: {rate} ticks a frame does not fit do_fan_decap's `movk fdc_rate,a0`")
    return rate, top - spent


def lane_top_frames():
    """How many entries a_fan_swipe's part 2 spends on TOP_FRAME.

    The hold `do_fan_decap` sleeps is the authored hold MINUS what the lane
    already spends, so this is read rather than assumed: a hand edit to part 2
    that this did not notice would quietly change the pose's length.
    """
    text = LANE_ASM.read_text()
    m = re.search(r"^a_fan_swipe\b(.*?)^KTFANSWIPE1\n", text, re.S | re.M)
    if not m:
        raise SystemExit("a_fan_swipe not found in src/MKFN.ASM")
    parts, cur = [], []
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith("*") or not line.startswith(".long"):
            continue
        val = line.split(None, 1)[1].split(";")[0].strip()
        if val == "0":
            parts.append(cur)
            cur = []
        else:
            cur.append(val)
    if len(parts) < 2:
        raise SystemExit("a_fan_swipe has fewer than two parts - part 2 is the top of the swing")
    if set(parts[1]) != {TOP_FRAME}:
        raise SystemExit(f"a_fan_swipe's part 2 is {parts[1]}, expected only {TOP_FRAME}")
    return len(parts[1])


def render_lane(back):
    body = [LANE_BEGIN,
            "* The RETURN half of FANSWIPESQ (data/KAT9.IMG), which retail never plays.\n"
            "* Part 3 is the one frame that carries the fan back out through him - the\n"
            "* SECOND SLICE - and part 4 brings her down to her stance.  Parts 1 and 2\n"
            "* above are retail's and are shared with her Back+HP power punch.\n"]
    for i, (name, _hold) in enumerate(back):
        body.append("\t.long\t%s\n" % name)
        if i == 0:
            body.append("\t.long\t0\t\t\t; part 3 - the fan back out: SECOND SLICE\n")
    body.append("\t.long\t0\t\t\t; part 4 - down to her stance\n")
    body.append(LANE_END)
    return "".join(body)


def render_equates(seq, rate, hold):
    frames = " ".join("%s[%d]" % (n.replace("KTFANSWIPE", ""), h) for n, h in seq)
    return "".join([
        EQU_BEGIN,
        "* FANSWIPESQ (data/KAT9.IMG), in PLAY order, as preview ticks:\n",
        "*   %s\n" % frames,
        "* One preview tick is %d game ticks (13.7 fps).\n" % TICKS_PER_PREVIEW,
        "*\n",
        "fdc_rate\t.set\t%d\t; ticks a frame, both ways through the swing\n" % rate,
        "fdc_hold\t.set\t%d\t; the rest of %s's authored hold at the top\n" % (hold, TOP_FRAME),
        EQU_END,
    ])


def region(path, begin, end):
    text = path.read_text()
    try:
        a = text.index(begin)
        b = text.index(end, a) + len(end)
    except ValueError:
        raise SystemExit(f"markers not found in {path.name} - put the BEGIN/END GENERATED pair back")
    return text, a, b, text[a:b]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dump", action="store_true")
    args = ap.parse_args()

    data = IMG.read_bytes()
    entries, where = read_sequence(data, image_names(data), SEQ)

    if args.dump:
        print(f"{SEQ}: {len(entries)} entries at name+{where[0]:#x} stride {where[1]}, "
              f"{TICKS_PER_PREVIEW} game ticks per preview tick")
        for name, hold in entries:
            print(f"  {name:<14} {hold:2d} x{TICKS_PER_PREVIEW} = {hold * TICKS_PER_PREVIEW:3d} ticks")
        print(f"  total: {sum(h for _, h in entries) * TICKS_PER_PREVIEW} ticks")
        return 0

    out, back = split(entries)
    rate, hold = timings(out, back)
    want = {LANE_ASM: (LANE_BEGIN, LANE_END, render_lane(back)),
            DEATH_ASM: (EQU_BEGIN, EQU_END, render_equates(entries, rate, hold))}

    rc = 0
    for path, (begin, end, block) in want.items():
        text, a, b, have = region(path, begin, end)
        if args.check:
            if have != block:
                print(f"{path.name} DRIFTED from {SEQ} in data/{IMG.name}")
                print("--- in " + path.name + "\n" + have)
                print("+++ from the IMG\n" + block)
                rc = 1
            continue
        if have != block:
            path.write_text(text[:a] + block + text[b:])
            print(f"rewrote {path.name}")
        else:
            print(f"{path.name} already current")
    if args.check and rc == 0:
        print("fan swipe return half OK (%d frames back, %d ticks a frame, %d held at the top)"
              % (len(back), rate, hold))
    elif args.check:
        print("regenerate: python tools/fan_swipe_seq_import.py")
    return rc


if __name__ == "__main__":
    sys.exit(main())
