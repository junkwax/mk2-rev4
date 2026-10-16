#!/usr/bin/env python3
"""Prepare ANY audio file for DCSEncoder so it sits at MK2's retail loudness.

Takes mp3/wav/ogg/flac/m4a/... (anything ffmpeg reads), and writes a clean
31,250 Hz mono 16-bit WAV mastered to the house target, then prints the
SetMixingLevel to put on its track.  See doc/AUDIO_LOUDNESS.md for where the
numbers come from (measured over all 248 distinct retail MK2 sounds).

    python tools/prep_dcs_audio.py in.mp3 sound/OUT.wav            # sfx / voice
    python tools/prep_dcs_audio.py in.mp3 sound/OUT.wav --class music
    python tools/prep_dcs_audio.py in.wav sound/OUT.wav --limit 4   # punchy impact
    python tools/prep_dcs_audio.py --check decoded_track.wav        # as-played check

The pipeline: ffmpeg decode -> mono -> 31,250 Hz -> DC/sub-20 Hz high-pass
-> optional silence trim -> gain to -15 LUFS (peaks held at -1 dBFS, with an
optional lookahead limiter) -> 3 ms edge fades -> 16-bit WAV.  It always
works from the ORIGINAL source; never feed it its own output or an MP3 you
re-exported, and never convert the result back to MP3.
"""
import argparse, shutil, subprocess, sys
import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as sg
from scipy.ndimage import minimum_filter1d

SR = 31250
WAV_LUFS = -15.0          # retail streams are mastered here (median -15.3)
PEAK_CEIL = -1.0          # DCS decode overshoots peaks by up to ~1 dB
DB_PER_STEP = 20 * np.log10(0.9733)   # SetMixingLevel: -0.235 dB per step, $7F = 0 dB
# Effective (as-played) targets, retail medians.  sfx and voice are one band.
TARGETS = {"sfx": -21.5, "voice": -21.5, "music": -19.5, "ui": -30.0}
BAND = {"sfx": (-23.0, -20.0), "voice": (-23.0, -20.0), "music": (-21.6, -18.6), "ui": (-33.0, -27.0)}
HARD_MAX = -17.5          # nothing retail plays in a fight is louder than this


def k_filter(sr):
    """ITU BS.1770 K-weighting, re-derived for an arbitrary rate."""
    G, Q, fc = 3.999843853973347, 0.7071752369554196, 1681.974450955533
    K = np.tan(np.pi * fc / sr); Vh = 10 ** (G / 20); Vb = Vh ** 0.4996667741545416
    a0 = 1 + K / Q + K * K
    b1 = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0]
    a1 = [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
    Q2, fc2 = 0.5003270373238773, 38.13547087602444
    K = np.tan(np.pi * fc2 / sr); d = 1 + K / Q2 + K * K
    return b1, a1, [1, -2, 1], [1, 2 * (K * K - 1) / d, (1 - K / Q2 + K * K) / d]


def lufs(x, sr=SR):
    """Gated integrated loudness.  Clips shorter than one 400 ms block use the
    mean K-weighted power of the whole clip - the same rule the retail survey
    used, so short sounds compare like for like."""
    b1, a1, b2, a2 = k_filter(sr)
    y = sg.lfilter(b2, a2, sg.lfilter(b1, a1, x))
    L, H = int(0.4 * sr), int(0.1 * sr)
    z = np.array([np.mean(y ** 2)]) if len(y) < L else \
        np.array([np.mean(y[i:i + L] ** 2) for i in range(0, len(y) - L + 1, H)])
    lk = -0.691 + 10 * np.log10(np.maximum(z, 1e-20))
    g = z[lk > -70]
    if not len(g):
        return -99.0
    rel = -0.691 + 10 * np.log10(g.mean()) - 10
    return float(-0.691 + 10 * np.log10(z[(lk > -70) & (lk > rel)].mean()))


def peak_db(x):
    return float(20 * np.log10(max(np.abs(x).max(), 1e-10)))


def decode(path):
    """Any format -> float mono at 31,250 Hz, via ffmpeg (soxr if built in)."""
    ff = shutil.which("ffmpeg") or r"C:\ffmpeg\bin\ffmpeg.exe"
    base = [ff, "-v", "error", "-i", path, "-ac", "1"]
    for af in (["-af", "aresample=resampler=soxr:precision=28"], []):
        r = subprocess.run(base + af + ["-ar", str(SR), "-f", "f32le", "-"], capture_output=True)
        if r.returncode == 0:
            return np.frombuffer(r.stdout, dtype=np.float32).astype(np.float64)
    sys.exit(f"ffmpeg could not decode {path}: {r.stderr.decode(errors='replace')}")


def trim(x, thresh_db=-60.0, pad_s=0.005):
    a = np.abs(x); on = np.nonzero(a > 10 ** (thresh_db / 20) * a.max())[0]
    if not len(on):
        return x
    p = int(pad_s * SR)
    return x[max(on[0] - p, 0):min(on[-1] + p + 1, len(x))]


def limit(x, ceil_db, look_s=0.002, release_s=0.05):
    """Lookahead peak limiter: gain never lets |x| exceed the ceiling."""
    ceil = 10 ** (ceil_db / 20)
    need = np.minimum(1.0, ceil / np.maximum(np.abs(x), 1e-12))
    n = max(int(look_s * SR), 1)
    # lookahead: the gain reaches its minimum before the peak arrives
    g = minimum_filter1d(need, 2 * n + 1, mode="nearest")
    rel = np.exp(-1.0 / (release_s * SR)); out = np.empty_like(g); cur = 1.0
    for i, v in enumerate(g):
        cur = v if v < cur else v + (cur - v) * rel
        out[i] = cur
    return x * out


def level_for(wav_lufs, target):
    """SetMixingLevel that plays a stream of this loudness at the target."""
    return int(round(127 + (target - wav_lufs) / -DB_PER_STEP))


def prep(args):
    x = decode(args.input)
    if not len(x):
        sys.exit("input decoded to zero samples")
    in_lufs, in_peak = lufs(x), peak_db(x)
    b, a = sg.butter(2, args.highpass / (SR / 2), "highpass")
    x = sg.filtfilt(b, a, x)                      # DC + sub-bass the cabinet can't play
    if not args.no_trim:
        x = trim(x)
    target_eff = TARGETS[args.cls]
    gain = WAV_LUFS - lufs(x)
    # music and ui still master to -15; only the track level differs
    y = x * 10 ** (gain / 20)
    if peak_db(y) > PEAK_CEIL:
        if args.limit > 0:
            # allow up to --limit dB of peak reduction, then cap the rest by gain
            over = peak_db(y) - PEAK_CEIL
            if over > args.limit:
                y *= 10 ** (-(over - args.limit) / 20)
            y = limit(y, PEAK_CEIL)
        else:
            y *= 10 ** ((PEAK_CEIL - peak_db(y)) / 20)
    f = int(0.003 * SR)
    if len(y) > 2 * f:
        ramp = np.linspace(0, 1, f); y[:f] *= ramp; y[-f:] *= ramp[::-1]
    out_lufs, out_peak = lufs(y), peak_db(y)
    lvl = level_for(out_lufs, target_eff)
    clamped = lvl > 127
    lvl = min(max(lvl, 0), 127)
    eff = out_lufs + DB_PER_STEP * (127 - lvl)
    wavfile.write(args.output, SR, np.clip(np.round(y * 32767), -32768, 32767).astype(np.int16))
    print(f"input   {args.input}")
    print(f"        {in_lufs:6.1f} LUFS  peak {in_peak:5.1f} dBFS")
    print(f"output  {args.output}  ({len(y) / SR:.3f} s, 31250 Hz mono 16-bit)")
    print(f"        {out_lufs:6.1f} LUFS  peak {out_peak:5.1f} dBFS")
    print(f"track   SetMixingLevel(${lvl:02X});    // {lvl} - class {args.cls}, "
          f"plays at ~{eff:.1f} LUFS (target {target_eff})")
    if clamped:
        short = target_eff - eff
        print(f"WARNING: {short:.1f} dB short of target even at $7F - the peak cap held the "
              f"WAV at {out_lufs:.1f} LUFS.  Re-run with --limit {int(np.ceil(short)) + 1} "
              f"(peak limiting) to close it.")


def check(path, cls):
    sr, x = wavfile.read(path); x = x.astype(np.float64)
    if x.ndim > 1:
        x = x.mean(1)
    x /= 32768.0
    l, p = lufs(x, sr), peak_db(x)
    lo, hi = BAND[cls]
    verdict = "OK" if lo <= l <= hi else ("TOO LOUD" if l > hi else "TOO QUIET")
    if l > HARD_MAX and cls != "music":
        verdict += f" (above {HARD_MAX}: louder than anything retail plays in a fight)"
    steps = round((TARGETS[cls] - l) / -DB_PER_STEP)
    print(f"{path}: {l:.1f} LUFS as played, peak {p:.1f} dBFS - {verdict} "
          f"[{cls} band {lo}..{hi}]" + (f"; change SetMixingLevel by {steps:+d}" if verdict != "OK" else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?")
    ap.add_argument("output", nargs="?")
    ap.add_argument("--class", dest="cls", choices=sorted(TARGETS), default="sfx",
                    help="sfx and voice share one target; music plays ~2 dB hotter, ui ~-30")
    ap.add_argument("--limit", type=float, default=0.0,
                    help="dB of peak limiting allowed to reach -15 LUFS (impacts: 3-6)")
    ap.add_argument("--highpass", type=float, default=20.0, help="high-pass corner, Hz (default 20)")
    ap.add_argument("--no-trim", action="store_true", help="keep leading/trailing silence")
    ap.add_argument("--check", metavar="WAV",
                    help="measure an AS-PLAYED decode (DCSExplorer --extract-tracks) against the band")
    a = ap.parse_args()
    if a.check:
        check(a.check, a.cls)
    elif a.input and a.output:
        prep(a)
    else:
        ap.error("need INPUT OUTPUT, or --check WAV")


if __name__ == "__main__":
    main()
