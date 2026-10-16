"""
dcs_fingerprint.py -- find which ROM stream a clip came from.

Given a query WAV (a rip, a hand-prepped clip, a backup generation) and a
directory of decoded ROM streams, this reports which stream the query matches
and how strongly. It is how sound/stlaugh_patch.txt note (35) identified UMK3
stream $070794 as the source of JADENITROKICK.wav, and it is the tool to reach
for before assuming any clip's provenance.

The match is log-mel spectral correlation with per-frame mean removal, which
survives what a clip typically goes through between the ROM and sound/: gain
changes, peak normalisation, mild EQ or "enhancement", resampling, and
trimming. It does NOT survive time-stretching or pitch shifting.

Scores are normalised correlation in [-1, 1]. Read them by MARGIN, not by
absolute value:

  * A true match scores ~0.99+ and leaves the runner-up far behind. The
    JADENITROKICK identification was 1.000 against a 0.964 runner-up.
  * A field of near-identical scores around 0.93-0.96 with no separation
    means NO match -- the query is not in the corpus. Short queries
    (under ~0.3 s) discriminate poorly and cluster like this even when the
    source really is present; prefer the longest, least-processed generation
    of a clip you have.

Confirm anything you intend to act on with --verify, which does a sample-level
Pearson correlation at the best lag. An unprocessed decode of the same stream
returns r = 1.0000; a normalised or enhanced generation returns less but stays
high, and unrelated audio collapses toward 0.

Building a corpus to search:

    DCSExplorer.exe -I --terse --extract-streams=umk3wav/u C:\\MAME\\roms\\umk3.zip

Usage:
    python tools/dcs_fingerprint.py --corpus umk3wav QUERY.wav [QUERY2.wav ...]
    python tools/dcs_fingerprint.py --corpus umk3wav --verify CLIP.wav STREAM.wav
    python tools/dcs_fingerprint.py --corpus umk3wav --top 10 CLIP.wav

See doc/AUDIO_IMPORT_PATHS.md for what to do with a confirmed match -- in
particular, why a verbatim .dcs import is not always the right answer even when
the match is perfect.
"""
import argparse
import glob
import math
import os
import sys
import wave

try:
    import numpy as np
    from numpy.lib.stride_tricks import sliding_window_view
except ImportError:
    sys.exit("dcs_fingerprint.py needs numpy (pip install numpy)")

SR = 31250          # the DCS sample rate; everything is resampled to it
NFFT = 512
HOP = 128
NMEL = 40
MIN_FRAMES = 8


def read_wav(path):
    with wave.open(path, "rb") as w:
        n, sr, ch = w.getnframes(), w.getframerate(), w.getnchannels()
        raw = w.readframes(n)
        width = w.getsampwidth()
    if width != 2:
        raise ValueError(f"{path}: expected 16-bit PCM, got {width * 8}-bit")
    d = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if ch > 1:
        d = d.reshape(-1, ch).mean(axis=1)
    if sr != SR and len(d) > 1:
        t = np.linspace(0, len(d) - 1, int(round(len(d) * SR / sr)))
        d = np.interp(t, np.arange(len(d)), d)
    return d


def _melbank():
    def hz2mel(f):
        return 2595 * np.log10(1 + f / 700)

    def mel2hz(m):
        return 700 * (10 ** (m / 2595) - 1)

    pts = mel2hz(np.linspace(hz2mel(80), hz2mel(SR / 2), NMEL + 2))
    bins = np.clip(np.floor((NFFT + 1) * pts / SR).astype(int), 0, NFFT // 2)
    fb = np.zeros((NMEL, NFFT // 2 + 1))
    for i in range(NMEL):
        l, c, r = bins[i], bins[i + 1], bins[i + 2]
        c = max(c, l + 1)
        r = max(r, c + 1)
        if r > NFFT // 2:
            break
        fb[i, l:c] = np.linspace(0, 1, c - l, endpoint=False)
        fb[i, c:r] = np.linspace(1, 0, r - c, endpoint=False)
    return fb


_FB = _melbank()
_WIN = np.hanning(NFFT)


def logmel(x):
    """Gain- and EQ-invariant spectral fingerprint, one unit vector per frame."""
    if len(x) < NFFT:
        x = np.pad(x, (0, NFFT - len(x)))
    frames = sliding_window_view(x, NFFT)[::HOP]
    spec = np.abs(np.fft.rfft(frames * _WIN, axis=1)) ** 2
    m = np.log(spec @ _FB.T + 1e-6)
    m -= m.mean(axis=1, keepdims=True)
    return m / np.maximum(np.linalg.norm(m, axis=1, keepdims=True), 1e-9)


def best_match(q, c):
    """Best normalised correlation of q against c over all alignments."""
    flipped = False
    if len(c) < len(q):
        q, c, flipped = c, q, True
    nq = len(q)
    best, off = -1.0, 0
    for i in range(len(c) - nq + 1):
        s = float((q * c[i:i + nq]).sum()) / nq
        if s > best:
            best, off = s, i
    return best, (-off if flipped else off)


def verify(a_path, b_path, max_lag=1200):
    """Sample-level Pearson r at the best lag: 1.0000 means same recording."""
    a, b = read_wav(a_path), read_wav(b_path)
    best, blag = -1.0, 0
    for lag in range(-max_lag, max_lag + 1, 2):
        xa, ya = (a[-lag:], b[:len(a) + lag]) if lag < 0 else (a[lag:], b[:len(a) - lag])
        n = min(len(xa), len(ya))
        if n < 2000:
            continue
        xa = xa[:n] - xa[:n].mean()
        ya = ya[:n] - ya[:n].mean()
        d = math.sqrt(float((xa * xa).sum()) * float((ya * ya).sum()))
        if d <= 0:
            continue
        r = float((xa * ya).sum()) / d
        if r > best:
            best, blag = r, lag
    return best, blag


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("queries", nargs="+", help="clip(s) to identify")
    ap.add_argument("--corpus", default="umk3wav",
                    help="directory of decoded ROM streams (default: %(default)s)")
    ap.add_argument("--top", type=int, default=6,
                    help="candidates to list (default: %(default)s)")
    ap.add_argument("--verify", action="store_true",
                    help="two args: sample-level Pearson r between them")
    args = ap.parse_args()

    if args.verify:
        if len(args.queries) != 2:
            sys.exit("--verify takes exactly two WAV paths")
        r, lag = verify(args.queries[0], args.queries[1])
        print(f"sample-level Pearson r = {r:.4f} at lag {lag}")
        print("  same recording, unprocessed" if r > 0.999 else
              "  same recording, processed" if r > 0.4 else
              "  NOT the same recording")
        return 0

    corpus = sorted(glob.glob(os.path.join(args.corpus, "*.wav")))
    if not corpus:
        sys.exit(f"no WAVs in {args.corpus}/ -- extract a corpus first "
                 f"(see this file's header)")
    print(f"corpus: {len(corpus)} streams in {args.corpus}/\n")

    cache = {}
    for p in corpus:
        try:
            d = read_wav(p)
        except Exception:
            continue
        if len(d) >= NFFT:
            m = logmel(d)
            if m.shape[0] >= MIN_FRAMES:
                cache[p] = m

    for qp in args.queries:
        try:
            qd = read_wav(qp)
        except Exception as e:
            print(f"=== {qp}: {e}\n")
            continue
        qm = logmel(qd)
        if qm.shape[0] < MIN_FRAMES:
            print(f"=== {qp}: too short to fingerprint\n")
            continue
        scores = sorted(((score, off, p)
                         for p, cm in cache.items()
                         for score, off in [best_match(qm, cm)]), reverse=True)
        dur = len(qd) / SR
        print(f"=== {os.path.basename(qp)}  ({dur:.3f}s, {qm.shape[0]} frames)")
        for s, off, p in scores[:args.top]:
            print(f"   {s:6.3f}  off={off * HOP / SR:7.3f}s  {os.path.basename(p)}")
        if len(scores) > 1:
            margin = scores[0][0] - scores[1][0]
            verdict = ("confident" if margin > 0.02 else
                       "WEAK -- margin too small, treat as unidentified")
            print(f"   margin over runner-up: {margin:.3f}  ({verdict})")
            if dur < 0.3:
                print(f"   note: {dur:.3f}s query is short; prefer a longer "
                      f"or less-processed generation")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
