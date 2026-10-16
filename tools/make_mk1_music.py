#!/usr/bin/env python3
r"""MK1'S STAGE MUSIC on the Wolf board - the arcade recordings in MK1_audio/,
cut to the loop each tune repeats, encoded by DCSEncoder into the Wolf sound
set's spare sockets (u6-u9).

MK1's music is NOT samples: the Y-unit sound board plays it live on a YM2151,
so the OKI ROMs hold none of it (DCSExplorer/mk1_audio/README.md).  The source
here is MKWarehouse's arcade recording set - the 16 files named
"NN - <name> - Dan Forden, Matt Furniss.flac", album "Mortal Kombat".  The
other files in that folder are other releases (Mega CD, Techno Syndrome) or MK2
cues, and are not used.

THE LOOP IS MEASURED, NOT TYPED.  An FM score replays deterministically, so the
recording at t and t+L lines up once L is the loop:
  1. the period is found on the spectrum (robust to FM phase drift) near the
     estimate below, then refined to the SAMPLE on the waveform (normalised
     cross-correlation of a 6 s window where the repeat is strongest);
  2. the loop starts at the EARLIEST point, on a DCS frame boundary, where the
     seam matches - everything before it is the intro, played once;
  3. DCS times a track in 240-sample frames (7.68 ms), so the loop is
     resampled to a whole number of frames.  The worst stretch is Goro's Lair's
     0.004%, far under anything audible, and it is what keeps `Wait(n)` from
     drifting against the stream across a long round.
Every tune is levelled to MK2's own stage music (measured -14..-16 dBFS RMS,
peaks ~-6): -15 dBFS RMS, peaks held at or below -3 dBFS.

Writes:
  sound/wolf/mk1/*.wav       intro + loop per tune, End stings, FINISH HIM loops
  sound/wolf_mk1music.txt    the patch makewolf.py appends (tracks $0700 up)
  src/WOLFMUSE.ASM           wmus_* equates - the codes MAIN.ASM's tune tables send

    python tools/make_mk1_music.py            # report
    python tools/make_mk1_music.py --apply    # write
    python tools/make_mk1_music.py --check    # they are current
"""
from __future__ import annotations

import argparse
import hashlib
import io
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "MK1_audio"
OUT_DIR = ROOT / "sound" / "wolf" / "mk1"
OUT_PATCH = ROOT / "sound" / "wolf_mk1music.txt"
OUT_EQU = ROOT / "src" / "WOLFMUSE.ASM"
SR = 31250
FRAME = 240                 # DCS frame, samples
FIRST_TRACK = 0x0700
RMS_DB, PEAK_DB = -15.0, -3.0      # stings / cues: plain gain
# The stage tunes are MASTERED, not just gained.  MK1's FM recordings carry
# ~15 dB between peak and average where MK2's own music carries ~9, so a
# plain gain with peaks held at -3 left the average at -17.7 - and DCSEncoder
# stores a stream ~6.4 dB under its WAV, so the Courtyard decoded at -24 and
# played ~9 dB under MK2's Tower music.  Gentle compression, then gain to
# TUNE_RMS_DB, then a peak limiter, brings the DECODED level to MK2's -15.
ENC_LOSS_DB = 6.4
# MEASURED IN THE MIX, 2026-10-08 (mk2wolf.exe -wavwrite, 25 s of an idle fight,
# EBU R128): MK2's nine stage tunes play at -43.2..-46.9 LUFS, median -44.0;
# the MK1 tunes mastered to a matching RMS played at -42.0..-43.0.  FM music
# carries more of its energy where the ear is sensitive, so equal RMS is NOT
# equal loudness - they read as loud (the user's report).  TUNE_TRIM_DB brings
# them onto MK2's median by loudness.
TUNE_TRIM_DB = -2.0
TUNE_RMS_DB = -15.0 + ENC_LOSS_DB + TUNE_TRIM_DB
# THE FINISH THEMES ARE BASS.  Mastered to the same RMS as the stage tunes they
# measured the same in the mix by level (-42.5 dB against -43..-45) and 2-5 LU
# QUIETER by loudness, with a spectral centroid of 80-150 Hz against 350-820:
# all their energy is where the ear, and a cabinet speaker, hears least.  They
# read as "way lower" than the fight music (the user's report, 2026-10-08).
# So they get the difference back in gain; the limiter in master() holds the
# peaks.
FIN_BOOST_DB = 3.5
# THE STAGE LOOPS ARE LEVELLED BY LOUDNESS, after mastering (2026-10-14): the
# whole-tune RMS left the Warrior Shrine's loop - The Cavern's quieter closing
# phrase, once TAIL made it the part that plays all round - at -16.7 LUFS
# against -15.4..-16.0 for the others, and it read as low (the user's report).
# -15.6 is the median of the pit, throne and courtyard loops as they were.
STAGE_LOOP_LUFS = -15.6
LEVEL = 100                 # SetMixingLevel, as MK2's own stage tunes
# DCS bit rate.  128000 (the encoder's default) until 2026-10-10: the
# MK1NEWAUD sets (Palace Gates' 47 s body loop + 31 s finish especially) needed
# a NINTH 1 MB sound socket at 128k; at 112k the set ends in u9 with ~40 KB free.
BITRATE = 112000

A = " - Dan Forden, Matt Furniss.flac"
# THE STAGE SETS (2026-10-10, the user's mapping).  MK1NEWAUD/ holds each tune
# as three files, and that is how MK1 ITSELF plays them - three consecutive
# sound commands per stage (tools/run_mk1_music_cmd_probe.ps1: 03/04/05 for
# one stage, 07/08/09 for the next):
#   "NN <name>.flac"         the stage tune - sent at every round start, so it
#                            restarts from its intro each round; the recording
#                            fades out, so it is cut to intro + measured loop
#   "<name> - Loop.flac"     FINISH HIM - sent once, the board loops it.  Cut
#                            by hand, but NOT on its period: every file opens
#                            with a 0.7-0.85 s lead-in and ends mid-phrase, so
#                            played end into start the seam scored -0.15..0.20.
#                            hand_loop plays the lead-in ONCE and loops whole
#                            periods (FIN_PERIOD) from there
#   "<name> - End.flac"      the KILLING BLOW (round won, or after the finish)
#                            - MK1 has no separate victory sting.  Here: the
#                            winner tune, and in place of MK2's "death blow
#                            over" tune 035h after a fatality (wolf_dbc_tune,
#                            MAIN.ASM)
#   Temple Gate -> THE COURTYARD    The Bridge -> THE PIT
#   Throne Room -> the PIT BOTTOM   The Cavern -> THE WARRIOR SHRINE
#   Throne Room -> THE THRONE ROOM  Palace Gates -> PALACE GATES
#   (Shang Tsung was the Pit Bottom's until 2026-10-11 - PITBOT_OWN)
# These are DIFFERENT arrangements from
# MK1_audio's (spectral match 0.41-0.59), so no loop point carries over.
# key: (tune, loop, end, loop estimate s) - estimates MEASURED: spectral
# self-similarity, refined to the sample.  Temple Gate, Throne Room and Shang
# Tsung repeat sample for sample (seam 0.96-0.98).
# The Bridge, The Cavern and The Palace Gates repeat TOO, but only at the end
# (2026-10-13, brute-force 1 s window search against every later offset): one
# 39-46 s pass, then a short phrase repeating sample for sample until the fade,
# which starts at ~54.5 s in all three.  Until then these were called "no
# repeat anywhere" and looped as a crossfaded 45 s body (find_body_loop, seam
# 0.51-0.63) - the period search only looked near one estimate and the fixed
# FADE_S trim cut the repeat region short.  TAIL gives (where the repeat starts,
# roughly; the period is the set's est): find_tail_loop places the seam.
NEW = ROOT / "MK1NEWAUD"
TAIL = {"pit": 40.0, "shrine": 45.0, "gates": 38.5}
TAIL_END_S = 54.5           # the three tails' fades start here (1 s RMS, measured)
# the FINISH HIM files' periods (measured as above; each file holds 1.5-4.7 of them)
FIN_PERIOD = {"pit": 9.370, "shrine": 8.810, "throne": 3.873, "courtyard": 5.856, "gates": 10.225,
              "pitbot": 4.996}


def _set(n, name, est):
    return (f"{n:02d} {name}.flac", f"{n + 1:02d} {name} - Loop.flac", f"{n + 2:02d} {name} - End.flac", est)


TUNES = {
    "pit":       _set(12, "The Bridge", 6.481),
    "shrine":    _set(18, "The Cavern", 4.410),
    "throne":    _set(15, "The Throne Room", 42.887),
    "courtyard": _set(6, "The Temple Gate", 15.6924),
    "gates":     _set(9, "The Palace Gates", 7.812),
    "pitbot":    _set(27, "Shang Tsung", 37.6245),
}
PITBOT_OWN = False          # Pit Bottom on its own Shang Tsung set (else THE THRONE ROOM's)
FADE_S = 12.0              # the recordings fade out over their last ~9 s
SEAM_GOOD = 0.9             # a sample-level seam this good needs no crossfade
SEAM_XFADE = 8192           # else: 0.26 s crossfade across it
BODY_XFADE = SR // 2        # find_body_loop's seam: 0.5 s
# OUTER HAVEN (curback 16h) plays the GENESIS port's Tomb set - "genesis mk2
# audio/" (MK2 Mega Drive rips, same file naming).  key -> (looped tune, loop
# estimate, one-shot sting or None).  Loop lengths measured the same way:
# 32.64 s and 15.36 s (spectral period, both whole multiples of 7.68 ms x 250).
# THE CREDITS (the cast roll, MKEND.ASM cast_of_characters): TECHNO SYNDROME,
# the Mortal Kombat theme (MK1_audio/16).  One 8-bar phrase looped - 14.42 s at
# 133 bpm, measured - taken where the track is LOUDEST among the seams that
# match as well as the best one, so it is the full arrangement and not the
# sparse intro.  The whole track is 3.3 MB at this bit rate and the sound ROM
# has ~270 KB left, which is why it is a phrase and not the song.
CREDITS = ("16. Techno Syndrome.flac", 14.42)
CREDITS_BITRATE = 96000
CREDITS_ON = False
GEN = ROOT / "genesis mk2 audio"
GEN_TUNES = {
    "ohaven":      ("08 - The Tomb - Special Portal" + A, 32.64, "10 - The Tomb ~ Over" + A),
    "ohaven_crit": ("09 - The Tomb ~ Critical" + A, 15.36, None),
}


# --------------------------------------------------------------------------
def load(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR),
                          "-f", "s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.int16).astype(np.float64) / 32768


def ncc(a, b):
    a = a - a.mean()
    b = b - b.mean()
    d = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / d) if d else 0.0


def spec(x, hop=736, nfft=2048):
    n = (len(x) - nfft) // hop
    idx = np.arange(nfft)[None, :] + hop * np.arange(n)[:, None]
    S = np.log1p(np.abs(np.fft.rfft(x[idx] * np.hanning(nfft)[None, :], axis=1))[:, 6:600] * 50)
    S -= S.mean(axis=1, keepdims=True)
    S /= np.linalg.norm(S, axis=1, keepdims=True) + 1e-9
    return S, hop


def find_loop_near_start(x, est, within=24.0, lead=0.25):
    """For a recording that does NOT repeat sample for sample (MK1's finish
    themes: the FM voices drift, the best sample seam is 0.7-0.8 and sits a
    minute in): the period near `est` by the same spectral test, and the best
    seam in the first `within` seconds - the caller drops what precedes it
    and crossfades the seam."""
    S, hop = spec(x)
    cands = range(int((est - 0.06) * SR / hop), int((est + 0.06) * SR / hop) + 1)
    Lh = max(cands, key=lambda l: float((S[:len(S) - l] * S[l:]).sum(axis=1).mean()))
    L = Lh * hop
    win = SR
    pos = range(int(lead * SR), int(within * SR), FRAME * 4)
    score = [(ncc(x[p:p + win], x[p + L:p + L + win]), p) for p in pos]
    c, start = max(score)
    # the spectral period is only good to one hop (23 ms): refine it to the
    # sample at that seam, then take the best seam again with the exact period
    W = 2 * SR
    seg = x[start:start + W]
    c, L = max((ncc(seg, x[start + l:start + l + W]), l) for l in range(L - hop, L + hop + 1, 2))
    score = [(ncc(x[p:p + win], x[p + L:p + L + win]), p) for p in pos]
    c, start = max(score)
    return start, L, c


def crossfade_loop(x, s, L, n=1024):
    """x[s:s+L] with its last n samples blended into the n samples BEFORE s,
    so the loop's end runs into its own start."""
    loop = x[s:s + L].copy()
    w = np.linspace(0.0, 1.0, n)
    loop[-n:] = loop[-n:] * (1 - w) + x[s - n:s] * w
    return loop


def find_loop(x, est):
    """(start, length) in samples: the exact period near `est`, and the earliest
    frame-aligned point from which the seam matches."""
    S, hop = spec(x)
    L0 = int(round(est * SR / hop))
    sim = (S[:len(S) - L0] * S[L0:]).sum(axis=1)
    w = int(6 * SR / hop)
    t0 = int(np.argmax(np.convolve(sim, np.ones(w) / w, "valid"))) * hop
    W = 6 * SR
    seg = x[t0:t0 + W]
    c, L = max((ncc(seg, x[t0 + l:t0 + l + W]), l)
               for l in range(int((est - 0.03) * SR), int((est + 0.03) * SR)))
    # earliest seam: score every frame-aligned 1 s window at s against s+L, and
    # take the earliest within 3% of the BEST seam anywhere in the tune - a
    # threshold off the refining window alone placed Palace Gates' seam in its
    # first second, before the two passes line up (0.76 against 0.98 later)
    win = SR
    pos = list(range(0, len(x) - L - win, FRAME * 4))
    score = [ncc(x[s:s + win], x[s + L:s + L + win]) for s in pos]
    best = max(score)
    start = next(s for s, v in zip(pos, score) if v >= 0.97 * best)
    return start, L, ncc(x[start:start + win], x[start + L:start + L + win])


def find_body_loop(x):
    """For a recording with NO repeat in it (The Bridge, The Cavern: one pass
    and a fade - spectral self-similarity sits at 0.5-0.6 for every lag, the
    sample-level seam under 0.1): loop the whole body.  The loop starts in the
    first 2-8 s and ends in the 4 s before the fade begins (the last 0.25 s
    window within 3 dB of the body's median level), the pair chosen so the
    1.5 s before each sound most alike - crossfade_loop blends the end into
    the material before the start.  Returns (start, length, similarity)."""
    h = SR // 4
    env = np.array([20 * np.log10(np.sqrt((x[i:i + h] ** 2).mean()) + 1e-12)
                    for i in range(0, len(x) - h, h)])
    med = float(np.median(env[: len(env) * 3 // 4]))
    fade = (int(np.nonzero(env >= med - 3.0)[0][-1]) * h) - SR
    S, hop = spec(x)
    w = int(1.5 * SR / hop)

    def ctx(t):
        f = t // hop
        return S[f - w:f]
    best = (-1.0, 0, 0)
    for s in range(2 * SR, 8 * SR, hop):
        a = ctx(s)
        for e in range(fade - 4 * SR, fade, hop):
            c = float((a * ctx(e)).sum(axis=1).mean())
            if c > best[0]:
                best = (c, s, e)
    c, s, e = best
    s -= s % FRAME
    e -= e % FRAME
    return s, e - s, c


def refine_period(x, est, a, b):
    """The period near `est` to the sample: x[a:b] against itself shifted."""
    L0 = int(est * SR)
    n = min(b, len(x)) - a - L0 - 300           # one window length for every shift
    return max((ncc(x[a:a + n], x[a + l:a + l + n]), l) for l in range(L0 - 300, L0 + 301))[1]


def find_tail_loop(x, est, t0):
    """For a tune whose repeat is only at its end (TAIL): the period near `est`
    over t0+2 s .. end, the earliest frame-aligned point near t0 from which the
    seam holds (0.5 s windows >= 0.85 for the next 40 start choices), then the
    STRONGEST seam within one period after it - the intro grows by under a
    period and the seam goes from ~0.86 to 0.98-1.0.  x ends where the fade
    starts.  Returns (start, length, seam ncc)."""
    w = SR // 2
    L = refine_period(x, est, int((t0 + 2) * SR), len(x))
    lo = int((t0 - 3) * SR)
    pos = range(lo - lo % FRAME, min(int((t0 + 6) * SR), len(x) - L - w), FRAME)
    ok = [(ncc(x[s:s + w], x[s + L:s + L + w]), s) for s in pos]
    first = next(s for i, (_c, s) in enumerate(ok) if min(c for c, _s in ok[i:i + 40]) >= 0.85)
    c, start = max((ncc(x[s:s + w], x[s + L:s + L + w]), s)
                   for s in range(first, min(first + L, len(x) - L - w), FRAME))
    return start, L, c


def find_fin_loop(x, est):
    """A FINISH HIM file: its period near `est`, as many whole periods as fit
    after a lead-in of up to 1 s, starting at the frame-aligned point in that
    first second where the seam is best.  Returns (lead-in, length, seam ncc)."""
    w = SR // 2
    P = refine_period(x, est, SR // 2, len(x) - SR)
    k = (len(x) - SR - SR // 4) // P
    c, s = max((ncc(x[s:s + w], x[s + k * P:s + k * P + w]), s)
               for s in range(0, min(SR, len(x) - k * P - w), FRAME))
    return s, k * P, c


def stretch(y, n):
    """Linear resample of y to exactly n samples (used for <0.01% stretches)."""
    return np.interp(np.linspace(0, len(y) - 1, n), np.arange(len(y)), y)


def trim_tail(y, floor_db=-60.0):
    lvl = 10 ** (floor_db / 20)
    nz = np.nonzero(np.abs(y) > lvl)[0]
    return y[:nz[-1] + 1] if len(nz) else y


def ffilter(y, chain):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-",
                          "-af", chain, "-f", "f32le", "-"],
                         input=y.astype("<f4").tobytes(), capture_output=True, check=True).stdout
    return np.frombuffer(raw, "<f4").astype(np.float64)[:len(y)]


def lufs(y):
    """Integrated loudness (EBU R128) of y, tiled to >= 8 s so a short loop
    measures as it plays."""
    y = np.tile(y, int(np.ceil(8 * SR / len(y))))
    err = subprocess.run(["ffmpeg", "-nostats", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-",
                          "-af", "ebur128", "-f", "null", "-"],
                         input=y.astype("<f4").tobytes(), capture_output=True, check=True).stderr.decode()
    return float([ln.split()[1] for ln in err.splitlines() if ln.strip().startswith("I:")][-1])


def master(x, rms_db=TUNE_RMS_DB):
    """Compress, gain to rms_db, limit peaks to -0.3 dBFS - on the WHOLE tune,
    before it is cut, so the intro, the loop and its seam share one envelope."""
    y = ffilter(x, "acompressor=threshold=-24dB:ratio=3:attack=10:release=150:knee=6")
    y = y * (10 ** (rms_db / 20) / np.sqrt((y * y).mean()))
    y = ffilter(y, "alimiter=limit=0.966:attack=3:release=80:level=disabled")
    return y, 20 * np.log10(np.sqrt((y * y).mean()) + 1e-12)


def level(*parts):
    """One gain for all parts (intro + loop share it): RMS to RMS_DB, peak <= PEAK_DB."""
    whole = np.concatenate(parts)
    rms = np.sqrt((whole * whole).mean())
    g = 10 ** (RMS_DB / 20) / rms
    pk = np.abs(whole).max() * g
    if pk > 10 ** (PEAK_DB / 20):
        g *= 10 ** (PEAK_DB / 20) / pk
    return [p * g for p in parts], 20 * np.log10(g)


def wav_bytes(y):
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(np.clip(np.round(y * 32767), -32768, 32767).astype("<i2").tobytes())
    return b.getvalue()


# --------------------------------------------------------------------------
def build():
    files, report, tracks, equ = {}, [], [], []
    streams = []
    t = FIRST_TRACK

    def add_stream(name, y):
        files[f"{name}.wav"] = wav_bytes(y)
        streams.append(f'stream MK1_{name} "wolf/mk1/{name}.wav" (bitrate={BITRATE});')
        return len(y) // FRAME

    def looped(src, key, tune, est, vic, nointro=False, fade=0.0):
        nonlocal t
        x = load(src / tune)
        if src == NEW and key in TAIL:
            x = x[:int(TAIL_END_S * SR)]            # up to its fade, measured
            s, L, c = find_tail_loop(x, est, TAIL[key])
        elif not est:
            s, L, c = find_body_loop(x)
        else:
            if fade:
                x = x[:len(x) - int(fade * SR)]     # never loop into the recording's fade
            s, L, c = (find_loop_near_start if nointro else find_loop)(x, est)
        n = int(round(L / FRAME))

        def cut(x):
            if nointro:
                return x[:0], stretch(crossfade_loop(x, s, L), n * FRAME)
            if not est:
                # no repeat in the recording: the whole body, its end blended in
                return x[:s], stretch(crossfade_loop(x, s, L, BODY_XFADE), n * FRAME)
            if c < SEAM_GOOD:
                return x[:s], stretch(crossfade_loop(x, s, L, SEAM_XFADE), n * FRAME)
            return x[:s], stretch(x[s:s + L], n * FRAME)
        rms = TUNE_RMS_DB + (FIN_BOOST_DB if nointro else 0.0)
        y, g = master(x, rms)
        intro, loop = cut(y)
        trim = 0.0
        if src == NEW and not nointro:
            # the LOOP is what plays all round: bring it to STAGE_LOOP_LUFS,
            # the whole tune by one gain so the intro runs into it unbroken
            trim = STAGE_LOOP_LUFS - lufs(loop)
            y, g = master(x, rms + trim)
            intro, loop = cut(y)
        lf = add_stream(f"{key}_loop", loop)
        body = [f"    SetMixingLevel({LEVEL});"]
        if len(intro):
            inf = add_stream(f"{key}_intro", intro)
            body.append(f"    Play(MK1_{key}_intro);")
            body.append(f"    Wait({inf}) Loop {{")
        else:
            body.append("    Loop {")
        body += [f"      Play(MK1_{key}_loop);", f"      Wait({lf})", "    }", "    Wait(Forever) End;"]
        if nointro:
            s = 0
        tracks.append(f"track ${t:04X} channel 0 {{    // MK1 {key}: intro {s / SR:.2f}s, "
                      f"loop {L / SR:.4f}s -> {n} frames (stretch {(n * FRAME - L) / L * 100:+.4f}%), "
                      f"seam ncc {c:.3f}\n" + "\n".join(body) + "\n};")
        equ.append((f"wmus_{key}", t, f"{key}: intro {s / SR:.1f}s + {L / SR:.2f}s loop"))
        report.append(f"  {key:10s} intro {s / SR:5.2f}s  loop {L / SR:7.4f}s = {n} frames  "
                      f"seam ncc {c:.3f}  mastered to {g:.1f} dBFS RMS (loop trim {trim:+.1f} dB, "
                      f"loop {lufs(loop):.1f} LUFS)")
        t += 1
        if vic is None:
            return
        # the victory / End sting, played once
        v, g = master(trim_tail(load(src / vic)))
        add_stream(f"{key}_win", v)
        tracks.append(f"track ${t:04X} channel 0 {{    // MK1 {key} {'End' if fade else 'victory'}, "
                      f"{len(v) / SR:.2f}s\n"
                      f"    SetMixingLevel({LEVEL});\n    Play(MK1_{key}_win);\n"
                      f"    Wait(stream) End;\n}};")
        equ.append((f"wmus_{key}_win", t, f"{key} {'End' if fade else 'victory'} sting"))
        t += 1

    def hand_loop(key, name, est):
        """A FINISH HIM file (MK1NEWAUD's "- Loop.flac"): its lead-in played
        ONCE, then whole periods looped (find_fin_loop), resampled to whole
        DCS frames."""
        nonlocal t
        x = load(NEW / name)
        s, L, c = find_fin_loop(x, est)
        x, g = master(x)
        n = int(round(L / FRAME))
        intro, loop = x[:s], stretch(x[s:s + L], n * FRAME)
        lf = add_stream(f"{key}_loop", loop)
        body = [f"    SetMixingLevel({LEVEL});"]
        if len(intro):
            inf = add_stream(f"{key}_intro", intro)
            body += [f"    Play(MK1_{key}_intro);", f"    Wait({inf}) Loop {{"]
        else:
            body.append("    Loop {")
        body += [f"      Play(MK1_{key}_loop);", f"      Wait({lf})", "    }", "    Wait(Forever) End;"]
        tracks.append(f"track ${t:04X} channel 0 {{    // MK1 {key}: {name}, lead-in {s / SR:.3f}s, "
                      f"loop {L / SR:.4f}s -> {n} frames (stretch {(n * FRAME - L) / L * 100:+.4f}%), "
                      f"seam ncc {c:.3f}\n" + "\n".join(body) + "\n};")
        equ.append((f"wmus_{key}", t, f"{key}: lead-in {s / SR:.2f}s + {L / SR:.2f}s loop"))
        report.append(f"  {key:10s} lead-in {s / SR:5.3f}s  loop {L / SR:7.4f}s = {n} frames  "
                      f"seam ncc {c:.3f}  mastered to {g:.1f} dBFS RMS")
        t += 1

    stages = [k for k in TUNES if k != "pitbot"]
    for key in stages:
        full, _loop, end, est = TUNES[key]
        looped(NEW, key, full, est, end, fade=FADE_S)
    for key, (tune, est, vic) in GEN_TUNES.items():
        looped(GEN, key, tune, est, vic)
    for key in stages:
        hand_loop(f"{key}_fin", TUNES[key][1], FIN_PERIOD[key])
    # the Pit Bottom plays THE THRONE ROOM's set (2026-10-11, the user's call):
    # MK1's "Shang Tsung" set is no longer encoded, so its three streams go back to
    # the sound ROM.  It was the LAST set built, so no other track number moves.
    # PITBOT_OWN = True restores it.
    if PITBOT_OWN:
        full, loop, end, est = TUNES["pitbot"]
        looped(NEW, "pitbot", full, est, end, fade=FADE_S)
        hand_loop("pitbot_fin", loop, FIN_PERIOD["pitbot"])
    else:
        codes = {nm: code for nm, code, _c in equ}
        for suf in ("", "_win", "_fin"):
            equ.append((f"wmus_pitbot{suf}", codes[f"wmus_throne{suf}"], f"pitbot{suf}: THE THRONE ROOM's"))

    # the credits, last of all so no other track number moves.  OFF since
    # 2026-10-09 (the user's call): the cast roll plays MK2's own music again
    # and the ~170 KB goes back to the sound ROM.  CREDITS_ON = True restores it.
    if CREDITS_ON:
        credits_track(files, streams, tracks, equ, report, t)
        t += 1

    patch = ["// MK1'S STAGE MUSIC (Wolf only) - GENERATED by tools/make_mk1_music.py;",
             "// edit the tool, never this file.  Appended by makewolf.py; the streams",
             "// go wherever the encoder puts them, which is the spare sockets u6-u9.", ""]
    patch += streams + [""] + tracks
    asm = [";  wmus_* - MK1 music track codes on the Wolf board (tools/make_mk1_music.py)"]
    asm += [f"{nm}\t.set\t0{code:04x}h\t; {com}" for nm, code, com in equ]
    return files, "\n".join(patch) + "\n", "\n".join(asm) + "\n", report


def credits_track(files, streams, tracks, equ, report, t):
    """Techno Syndrome looped for the cast roll (CREDITS_ON)."""
    x = load(SRC / CREDITS[0])
    _s, L, _c = find_loop(x, CREDITS[1])
    win = SR
    cand = [(ncc(x[q:q + win], x[q + L:q + L + win]), q) for q in range(SR * 4, len(x) - L - win, FRAME * 8)]
    best = max(v for v, _q in cand)
    q = max((float(np.sqrt((x[q:q + L] ** 2).mean())), q) for v, q in cand if v >= 0.97 * best)[1]
    x, g = master(x)
    n = int(round(L / FRAME))
    loop = stretch(crossfade_loop(x, q, L), n * FRAME)
    files["credits_loop.wav"] = wav_bytes(loop)
    streams.append(f'stream MK1_credits_loop "wolf/mk1/credits_loop.wav" (bitrate={CREDITS_BITRATE});')
    seam = ncc(x[q:q + win], x[q + L:q + L + win])
    tracks.append(f"track ${t:04X} channel 0 {{    // Techno Syndrome, the credits: {L / SR:.3f}s "
                  f"from {q / SR:.2f}s, seam ncc {seam:.3f}\n"
                  f"    SetMixingLevel({LEVEL});\n    Loop {{\n      Play(MK1_credits_loop);\n"
                  f"      Wait({len(loop) // FRAME})\n    }}\n    Wait(Forever) End;\n}};")
    equ.append(("wmus_credits", t, "Techno Syndrome, looped, for the cast roll"))
    report.append(f"  credits    loop {L / SR:7.4f}s from {q / SR:.2f}s  mastered to {g:.1f} dBFS RMS")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    files, patch, asm, report = build()
    secs = sum(len(b) - 44 for b in files.values()) / 2 / SR
    print("MK1 stage music:")
    print("\n".join(report))
    print(f"  {len(files)} streams, {secs:.1f}s of audio")
    if a.apply:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        for n, b in files.items():
            (OUT_DIR / n).write_bytes(b)
        OUT_PATCH.write_text(patch, encoding="utf-8")
        OUT_EQU.write_text(asm, encoding="utf-8", newline="\r\n")
        print(f"wrote {len(files)} WAVs in {OUT_DIR.relative_to(ROOT)}, {OUT_PATCH.name}, {OUT_EQU.name}")
    if a.check:
        bad = [n for n, b in files.items() if not (OUT_DIR / n).exists()
               or hashlib.sha1((OUT_DIR / n).read_bytes()).digest() != hashlib.sha1(b).digest()]
        if bad or not OUT_PATCH.exists() or OUT_PATCH.read_text(encoding="utf-8") != patch \
                or not OUT_EQU.exists() or OUT_EQU.read_text(encoding="utf-8") != asm:
            raise SystemExit(f"MK1 music has drifted ({bad[:4]}) - rerun --apply")
        print("MK1 music is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
