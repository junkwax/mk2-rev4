# Audio loudness — making any import sit with MK2's own sounds

**Read this before adding any sound to the ROM**, whatever its source: MP3,
WAV, a web rip, an MK1 OKI decode, a UMK3 `.dcs` stream, or a new recording.
Every number here was measured over **all 248 distinct retail MK2 sounds**
(2026-10-14). Use it instead of tuning by ear or copying another track's level.

## The rule

| What | Value |
|---|---|
| Source WAV loudness | **−15 LUFS** integrated (ITU BS.1770) |
| Source WAV peak | **≤ −1 dBFS** |
| Track level, sfx / voice | **`SetMixingLevel($64)`** (100) → plays at about **−21.5 LUFS** |
| Track level, music | `SetMixingLevel($6C)` (108) → about −19.5 LUFS |
| Track level, menu / UI blips | about `$41` (65) → about −30 LUFS |
| Acceptable, as played (sfx/voice) | **−23 … −20 LUFS** |
| Never above, during a fight | −17.5 LUFS |

You don't work these out by hand. The tool below does it.

## The one command

```
python tools/prep_dcs_audio.py <any input> sound/NAME.wav [--class sfx|voice|music|ui] [--limit N]
```

It decodes the input with ffmpeg (MP3, WAV, OGG, FLAC, M4A and anything else ffmpeg
reads), mixes to mono and resamples to 31,250 Hz. It then removes DC and anything
below 20 Hz, trims silence from the ends, sets the gain to −15 LUFS with peaks held
at −1 dBFS, and adds 3 ms edge fades. It writes a 16-bit WAV and **prints the exact
`SetMixingLevel` line to put on the track**:

```
$ python tools/prep_dcs_audio.py ~/new/thing.mp3 sound/THING.wav
input   ~/new/thing.mp3
         -18.9 LUFS  peak  -5.1 dBFS
output  sound/THING.wav  (1.150 s, 31250 Hz mono 16-bit)
         -15.0 LUFS  peak  -1.3 dBFS
track   SetMixingLevel($63);    // 99 - class sfx, plays at ~-21.6 LUFS (target -21.5)
```

Then reference the WAV in `sound/stlaugh_patch.txt` and use that level:

```
stream Thing "THING.wav";
track $XXXX channel 1 {
    SetMixingLevel($63);    // 99 - prep_dcs_audio.py, plays at ~-21.6 LUFS
    Play(Thing);
    Wait(stream);
};
```

The printed level is **not always 100**. Sounds with sharp attacks (punches,
claps, falls) hit the −1 dBFS peak cap before they reach −15 LUFS, so the tool
makes up the difference at the mixer: about 4 steps per dB. If even `$7F` can't
reach the target, it prints a warning. In that case re-run with `--limit 3`
to `--limit 6`, which lets a lookahead limiter shave the peaks so the WAV gets
louder.

### Classes

- `sfx` (default) and `voice` share a target. In retail, hits, whooshes,
  projectiles and speech all sit in the same band. Kahn's announcer lines are
  the tightest group, at −21.9.
- `music` plays about 2 dB louder, matching retail stage tunes.
- `ui` is for cursor moves, ticks and menu blips, which retail keeps around −30.

## MP3 sources: the rules

1. **Feed the original MP3 straight to the tool.** It decodes the MP3 once, and
   the WAV it writes is lossless, so the only lossy steps left are the MP3 you
   started with and DCS itself.
2. **Never re-export to MP3** at any stage, including after a gain change in
   Audacity. A second MP3 generation followed by DCS is what made
   CAGEHEADHOLE_YEAH sound "static/wonky" (patch note (17)).
3. **Never run the tool on its own output** or on an earlier `_norm`/`_preboost`
   copy. Always go back to the original source.
4. If you edit the clip in Audacity first (trim, EQ, denoise), export **WAV**,
   then run the tool on that WAV. Its loudness step replaces any manual
   normalising.

## Verbatim `.dcs` imports (UMK3 etc.)

A `.dcs` stream is stored byte-for-byte, so you can't change its source level.
Set the track level from a measurement instead:

1. Build a scratch ROM with the stream on a test track at `SetMixingLevel($7F)`.
   Use DCSEncoder `-o <scratch>.zip`, never the live zip.
2. `DCSExplorer.exe -I --terse --extract-tracks=<dir>/t <scratch>.zip`
3. `python tools/prep_dcs_audio.py --check <dir>/t_XXXX.wav`. It prints how many
   steps to come down from 127.

UMK3 was mastered louder than MK2, so these usually land around 95–110. If
the stream is too quiet even at `$7F`, either accept it or transcode from a
decoded WAV through the tool. See AUDIO_IMPORT_PATHS.md, "The general lesson".

## Checking a finished sound

Always check the **as-played** decode, not the WAV you fed in:

```
DCSExplorer.exe -I --terse --extract-tracks=out/t <built>.zip
python tools/prep_dcs_audio.py --check out/t_XXXX.wav [--class ...]
```

It reports OK / TOO LOUD / TOO QUIET and the `SetMixingLevel` change that
fixes it. The band is retail's middle half, so about half of retail falls
outside it on purpose (the crowd cheer is −17.6, for example). Imports should aim
for the median and land inside the band. Don't use `--check` to judge retail
sounds.

Verified end to end 2026-10-14. Two MP3s and three WAVs were prepped, encoded at
the printed levels and decoded, and all five played at **−21.5 to −21.7 LUFS**.

## Where the numbers come from

Retail baseline: the unpatched sound ROM in `C:\MAME\roms\mk2r302.zip`. It passes
the DCS checksum, unlike the live `mk2.zip`, which carries our imports. Every
track was decoded as played, and channel-copy duplicates were removed, leaving
248 distinct sounds.

| Retail, as played | n | p10 | p25 | **median** | p75 | p90 |
|---|---:|---:|---:|---:|---:|---:|
| sfx + voice | 217 | −26.3 | −23.1 | **−21.6** | −20.0 | −18.2 |
| voice only | 99 | −24.5 | −22.8 | **−21.5** | −20.4 | −19.1 |
| Kahn announcer | 32 | −22.9 | −22.6 | **−21.9** | −20.6 | −20.3 |
| music | 31 | −22.6 | −21.6 | **−19.4** | −18.6 | −17.7 |
| retail `SetMixingLevel`, sfx+voice | | 85 | 95 | **100** | 105 | 110 |
| retail stream loudness (= as played − mixer) | | −19.2 | −17.4 | **−15.3** | −13.4 | −11.8 |

So retail masters its streams **hot (about −15 LUFS)** and turns them down with
**level about 100**. The rule copies that convention, so imports behave like
native sounds, including how much room there is to turn them up or down later.

### Facts the rule depends on

- **`SetMixingLevel` is logarithmic: −0.235 dB per step**, and `$7F` (127) is 0 dB.
  So gain = 20·log10(0.9733)·(127 − L): level 100 is −6.35 dB and level 64 is
  −14.8 dB. The source is `DCSDecoder/Doc/DCS_format_reference.html`, "Mixing
  multiplier factor".
- **DCSEncoder is unity gain.** Encoding and then decoding at `$7F` came back
  within 0.15 dB RMS and 0.5 dB LUFS on pink noise, a sine and two voice clips.
  The `ENC_LOSS_DB = 6.4` in `tools/make_mk1_music.py` is not encoder loss. It is
  the −6.35 dB of `SetMixingLevel(100)`, which those tunes use. That script's
  numbers still work because the two cancel, but don't carry the "encoder loses
  6 dB" idea anywhere else.
- **DCS can push peaks up by as much as about 1 dB** (+1.1 dB measured on a sine).
  That is why the source cap is −1 dBFS and not 0.
- **`DCSExplorer --extract-streams` WAVs are not unity.** Each stream is decoded at
  the level of the first track that references it. To measure a stream, extract
  tracks (`--extract-tracks`) and subtract the mixer gain.
- Loudness of clips shorter than 400 ms is the mean K-weighted power of the
  whole clip. The retail survey used the same rule, so short sounds are compared
  like for like.
- Cross-channel ducking (`SetMixingLevel(channel N, decrease …)`, used when a
  voice lowers the music) isn't part of these numbers. They describe each sound
  on its own.

## Custom sounds in mk2.zip that are off target (as of 2026-10-14)

Measured as played from the live `mk2.zip`. The suggested level brings each one to
about −21.5. **Nothing has been changed yet**: some were boosted by ear on purpose,
so confirm with the user before you level them, and with the owning session where
there is one.

| Track | Sound | Now (LUFS) | Level now → suggested |
|---|---|---:|---|
| `$0282` | CageHeadholeYeah | −12.7 | 127 → ~90 |
| `$0368` | JadeBoomWhoosh | −13.9 | 127 → ~95 |
| `$036A` | JadeNitroKick | −14.8 | 120 → ~92 |
| `$0373` | Frosty | −15.9 | 127 → ~103 |
| `$0118` | ShangClap | −17.0 | 127 → ~108 |
| `$00B2` | ScorpFall | −18.0 | 127 → ~112 |
| `$0046` / `$0352` | NoobName | −24.6 / −24.3 | 101 → ~114 / 98 → ~110 |
| `$0323` | FlyBrain (**fly session owns it**) | −24.3 | 112 → ~124 |
| `$0358` | JadeProtect (retriggered 10×) | −24.0 | 115 → ~126 |
| `$0564` | JadeZap (`.dcs`) | −23.9 | 125 → 127 (still ~0.5 dB short) |

Everything else custom already falls in the −23 … −20 band.

## Regenerating the survey

```
DCSExplorer.exe -I --terse --extract-tracks=ret/t C:\MAME\roms\mk2r302.zip
DCSExplorer.exe -I -p C:\MAME\roms\mk2r302.zip > ret_programs.txt
```

Then run each track through `prep_dcs_audio.py --check`, or through the same
`lufs()` function. Remove channel-copy duplicates first by comparing track
programs, and classify using the descriptions in `sound/MK2.LST`.
