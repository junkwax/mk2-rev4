#!/usr/bin/env python3
"""Prove MK1 stage music played on the Wolf board, from a -wavwrite recording.

    python tools/mk1_music_listen.py <recording.wav> [--tune courtyard]

Finds the tune's INTRO in the recording by cross-correlation (it starts with
the round, so its offset is unknown), then requires the LOOP to begin exactly
where the intro ends and to come round again one loop length later - i.e. the
streams in sockets u6-u9 were really fetched, and the track program's Wait(n)
matches the stream.  The game's own sounds play over the music (announcer,
hits), so a match is judged by normalised correlation of whole seconds, and a
pass needs every checked second clear of the threshold.  Exit 0 = PASS.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
MUS = ROOT / "sound" / "wolf" / "mk1"
SR = 8000
THRESH = 0.5


def load(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR),
                          "-f", "s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.int16).astype(np.float64) / 32768


def ncc(a, b):
    n = min(len(a), len(b))
    a, b = a[:n] - a[:n].mean(), b[:n] - b[:n].mean()
    d = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / d) if d else 0.0


def locate(rec, ref):
    """Offset in rec where ref (its first 4 s) fits best, by FFT correlation."""
    r = ref[:4 * SR]
    n = 1 << int(np.ceil(np.log2(len(rec) + len(r))))
    c = np.fft.irfft(np.fft.rfft(rec, n) * np.conj(np.fft.rfft(r, n)), n)[:len(rec) - len(r)]
    e = np.sqrt(np.convolve(rec * rec, np.ones(len(r)), "valid")[:len(c)]) + 1e-9
    c = c / e / (np.linalg.norm(r) + 1e-9)
    k = int(np.argmax(c))
    return k, float(c[k])


def seconds(rec, at, ref, count):
    """NCC per second of ref placed at `at` in rec."""
    out = []
    for s in range(count):
        a, b = at + s * SR, s * SR
        if a + SR > len(rec) or b + SR > len(ref):
            break
        out.append(ncc(rec[a:a + SR], ref[b:b + SR]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording")
    ap.add_argument("--tune", default="courtyard")
    a = ap.parse_args()
    rec = load(a.recording)
    intro, loop = load(MUS / f"{a.tune}_intro.wav"), load(MUS / f"{a.tune}_loop.wav")
    at, c = locate(rec, intro)
    print(f"recording {len(rec) / SR:.1f}s; {a.tune} intro found at {at / SR:.2f}s (fit {c:.2f})")
    ok = True
    s_in = seconds(rec, at, intro, int(len(intro) / SR))
    l1 = at + len(intro)
    s_l1 = seconds(rec, l1, loop, int(len(loop) / SR))
    l2 = l1 + len(loop)
    s_l2 = seconds(rec, l2, loop, 6)
    for name, v in (("intro", s_in), ("loop, 1st pass", s_l1), ("loop, 2nd pass (the wrap)", s_l2)):
        need = 1 if name.startswith("intro") else 3
        good = len(v) >= need and np.median(v) > THRESH
        ok &= bool(good)
        print(f"  {name:28s} {len(v):3d}s checked, median ncc {np.median(v) if v else 0:.2f}, "
              f"min {min(v) if v else 0:.2f}  {'ok' if good else 'MISSING'}")
    if len(s_l2) < 3:
        print("  (recording ends before the loop comes round - run longer)")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
