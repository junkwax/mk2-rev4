"""Is the SUDDEN DEATH line actually IN the recorded mix?

The rig's sound-latch tap proves the ROM SENT the track.  It cannot prove the
track plays - a mis-encoded or empty stream sends exactly the same code.  This
matches the recording against the source clip instead, so the run reports a
number rather than asking somebody to listen.

Method: correlate LOG SPECTROGRAMS over the speech band (300-3400Hz), not
amplitude envelopes.  The envelope version of this check could not tell the
line from the music - a voice at about -19dBFS under a full mix barely moves
the envelope - and scored the real event at 0.20-0.41 against controls of
0.34, which is no verdict at all.  Per-frame spectral shape in the voice band
survives the music: the same recording scores 0.66 against 0.35.

Music plays under the line, so the score is compared against CONTROL windows
elsewhere in the same recording - the verdict is that the event window scores
far above every control, not that it scores high on its own.

  python tools/suddeath_wav_check.py <recording.wav> <rig log> [LABEL]

LABEL is "SUDDEN DEATH" (the default) or "DRAW" - the two announcer lines the
rule produces, at the second tie and the first.  The log supplies the event
time ("sound latch: track ... (LABEL) at <ms>").

**The label is matched, not just the first latch line.**  Both events log in
the same format, and DRAW fires at round 1 while SUDDEN DEATH fires at round 3,
so a bare "first match" search would score the DRAW line and report it as the
sudden-death verdict - a pass that proves the wrong thing.
"""
import re
import sys
import wave
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly, spectrogram

ENV_HZ = 500          # envelope sample rate (kept: used to place windows)
WINDOW_MS = 3000      # how much of the recording to search from the event
CONTROLS = 14         # control windows, spread over the recording
BAND = (300, 3400)    # speech band - where the line survives the music
NPERSEG, NOVERLAP = 1024, 768
SLIDE = (-20, 60)     # spectrogram frames to slide the clip within a window


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        n, ch, sw, sr = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(n)
    if sw != 2:
        raise SystemExit(f"{path}: expected 16-bit PCM, got {sw*8}-bit")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def envelope(x, sr):
    """Rectified, smoothed, decimated to ENV_HZ."""
    x = np.abs(x - x.mean())
    win = max(1, int(round(sr / ENV_HZ)))
    if win > 1:                              # box-smooth then decimate
        k = np.ones(win) / win
        x = np.convolve(x, k, mode="same")
    env = resample_poly(x, ENV_HZ, sr)
    return np.maximum(env, 0.0)


def specgram(x, sr):
    """Log spectrogram over the speech band, per-frame mean removed."""
    f, t, S = spectrogram(x, fs=sr, nperseg=NPERSEG, noverlap=NOVERLAP)
    S = np.log1p(S[(f >= BAND[0]) & (f <= BAND[1])])
    return S - S.mean(axis=0, keepdims=True), t


def spec_score(clip_S, rec_S, rec_t, t_ms):
    """Best correlation of the clip's spectrogram near t_ms."""
    n = clip_S.shape[1]
    i = int(np.searchsorted(rec_t, t_ms / 1000.0))
    best = -1.0
    a = clip_S.ravel()
    a = a - a.mean()
    denom_a = np.sqrt((a * a).sum())
    for off in range(*SLIDE):
        j = i + off
        if j < 0 or j + n > rec_S.shape[1]:
            continue
        b = rec_S[:, j:j + n].ravel()
        b = b - b.mean()
        d = denom_a * np.sqrt((b * b).sum())
        if d:
            best = max(best, float((a * b).sum() / d))
    return best


def ncc(needle, hay):
    """Best normalised cross-correlation of needle over hay, and its offset."""
    n = len(needle)
    if len(hay) < n:
        return 0.0, 0
    a = needle - needle.mean()
    denom_a = np.sqrt((a * a).sum())
    if denom_a == 0:
        return 0.0, 0
    best, best_i = -1.0, 0
    # stride the search: envelope resolution is 2ms, 10ms steps are plenty
    step = max(1, ENV_HZ // 100)
    for i in range(0, len(hay) - n + 1, step):
        seg = hay[i:i + n]
        b = seg - seg.mean()
        denom_b = np.sqrt((b * b).sum())
        if denom_b == 0:
            continue
        r = float((a * b).sum() / (denom_a * denom_b))
        if r > best:
            best, best_i = r, i
    return best, best_i


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    wav_path, log_path = Path(sys.argv[1]), Path(sys.argv[2])
    label = (sys.argv[3] if len(sys.argv) > 3 else "SUDDEN DEATH").upper()
    clips = {"SUDDEN DEATH": "SUDDENDEATH.wav", "DRAW": "DRAW.wav"}
    if label not in clips:
        raise SystemExit(f"unknown label {label!r}; want one of {sorted(clips)}")
    root = Path(__file__).resolve().parent.parent
    clip_path = root / "sound" / clips[label]

    log = log_path.read_text(errors="ignore")
    m = re.search(r"sound latch: track ([0-9a-f]{4}) \(" + re.escape(label)
                  + r"\) at ([0-9.]+)ms", log)
    if not m:
        print(f"[wav] the log has no {label} sound-latch line - "
              "was the run made with -Listen ?")
        return 2
    track, event_ms = m.group(1), float(m.group(2))

    if not clip_path.exists():
        print(f"[wav] source clip missing: {clip_path}")
        return 2

    rec, rec_sr = read_wav(wav_path)
    clip, clip_sr = read_wav(clip_path)
    if clip_sr != rec_sr:                     # compare like with like
        from math import gcd
        g = gcd(rec_sr, clip_sr)
        clip = resample_poly(clip, rec_sr // g, clip_sr // g)
        clip_sr = rec_sr

    dur_s = len(rec) / rec_sr
    print(f"[wav] {label}: recording {dur_s:.1f}s @{rec_sr}Hz, "
          f"clip {len(clip)/clip_sr:.2f}s, track {track} sent at {event_ms:.0f}ms")
    if event_ms / 1000.0 > dur_s:
        print("[wav] FAIL: the event is past the end of the recording")
        return 1

    clip_S, _ = specgram(clip, clip_sr)
    rec_S, rec_t = specgram(rec, rec_sr)

    score = spec_score(clip_S, rec_S, rec_t, event_ms)
    print(f"[wav] event window r={score:.3f} (speech band {BAND[0]}-{BAND[1]}Hz)")

    # controls: the same search elsewhere in the recording, skipping the event
    rng = np.linspace(1000, max(1000.0, dur_s * 1000 - WINDOW_MS), CONTROLS)
    ctrl = []
    for t in rng:
        if abs(t - event_ms) < WINDOW_MS:
            continue
        ctrl.append(spec_score(clip_S, rec_S, rec_t, t))
    if not ctrl:
        print("[wav] no control windows - recording too short to judge")
        return 2
    c_max, c_mean = max(ctrl), float(np.mean(ctrl))
    print(f"[wav] controls  n={len(ctrl)}  max={c_max:.3f}  mean={c_mean:.3f}")

    # The line must beat every control window, with room to spare.
    if score > 0.5 and score > c_max + 0.15:
        print(f"[wav] PASS: the {label} line is in the mix "
              f"(r={score:.3f} vs best control {c_max:.3f})")
        return 0
    print(f"[wav] FAIL: the {label} window is not distinguishable from the music "
          f"(r={score:.3f}, best control {c_max:.3f})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
