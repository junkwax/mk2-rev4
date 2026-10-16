"""Decode a kahn_fatality_audio_probe.lua trace into a real sound timeline.

The probe logs the raw bytes the game writes to the DCS latch.  Pairing them
into track numbers has to be done with the parity re-locked, because sndres
leaves a stray 0ffffh in the stream at boot (see the probe's own note).  The
lock is trivial once you know it: a real MK2 track number is $0000-$04ff, so
the HIGH byte of a pair is always <= 7.

Usage:  python tools/decode_sound_trace.py <log> [--from MS] [--to MS]
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SEND_RE = re.compile(r"^\[snd\]\s+([\d.]+)ms.*SEND \$([0-9a-f]{4})", re.I)
RAW_RE = re.compile(r"^\[snd\]\s+([\d.]+)ms.*RAW latch ([0-9a-f]{4})", re.I)
ROW_RE = re.compile(r"^\s*\.word\s+([\w|]+),0?([0-9a-f]+)h\s*;\s*(.*?)\s*$", re.I)


def load_names():
    """code -> (label, priority, duration) straight out of MKSOUND.ASM."""
    names = {}
    table = "?"
    for line in (ROOT / "src" / "MKSOUND.ASM").read_text(errors="replace").splitlines():
        if line.startswith("triple_sndtab2"):
            table = "t2"
        elif line.startswith("triple_sndtab"):
            table = "t1"
        m = ROW_RE.match(line)
        if not m:
            continue
        head, code, comment = m.group(1), int(m.group(2), 16), m.group(3)
        pd = re.match(r"^(sp_\w+)\|(\d+)$", head)
        pri, dur = (pd.group(1), int(pd.group(2))) if pd else (None, None)
        for ch in range(3):
            # two indices can share a base code (e.g. $0320 is both t1 105 and
            # the patched t2 5b "I WIN"), so keep every label - reporting only
            # the first one names the wrong caller
            prev = names.get(code + ch)
            label = f"{table} {comment} [ch{ch + 1}]"
            if prev:
                names[code + ch] = (f"{prev[0]} / {label}", prev[1] or pri, prev[2] or dur)
            else:
                names[code + ch] = (label, pri, dur)
    # raw send_code_a3 callers - not in either table
    names[0x0034] = ("STING death-blow (make_db_tone)", None, None)
    names[0x0035] = ("TUNE death-blow-over (death_blow_complete)", None, None)
    names[0x003F] = ("TUNE babality/friendship over", None, None)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--from", dest="lo", type=float, default=0.0)
    ap.add_argument("--to", dest="hi", type=float, default=float("inf"))
    args = ap.parse_args()

    names = load_names()

    # rebuild the byte stream: every logged SEND is two consecutive bytes
    stream = []
    for line in pathlib.Path(args.log).read_text(errors="replace").splitlines():
        m = SEND_RE.match(line)
        if m:
            ms, word = float(m.group(1)), int(m.group(2), 16)
            stream.append((ms, word >> 8))
            stream.append((ms, word & 0xFF))
            continue
        m = RAW_RE.match(line)
        if m:
            stream.append((float(m.group(1)), None))  # parity break

    out, i = [], 0
    while i < len(stream) - 1:
        ms, hi = stream[i]
        if hi is None:
            i += 1
            continue
        if hi > 0x07:            # cannot be the high byte of a track number
            i += 1               # re-lock: this byte is a leftover
            continue
        lo = stream[i + 1][1]
        if lo is None:
            i += 1
            continue
        out.append((ms, (hi << 8) | lo))
        i += 2

    prev = None
    for ms, code in out:
        if not (args.lo <= ms <= args.hi):
            continue
        label, pri, dur = names.get(code, ("(unknown)", None, None))
        extra = ""
        if dur:
            extra = f"   pri={pri} dur={dur} ticks (~{int(dur * 18.4)}ms)"
        gap = f"+{ms - prev:7.1f}" if prev is not None else "        "
        prev = ms
        print(f"{ms:9.1f}ms {gap}  $%04x  {label}{extra}" % code)


if __name__ == "__main__":
    sys.exit(main())
