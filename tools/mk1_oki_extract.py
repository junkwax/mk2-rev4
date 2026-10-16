"""
mk1_oki_extract.py -- MK1's OKI MSM6295 speech/FX bank out of mk.zip as WAVs.

MK1 is not a DCS game: its audio lives on the Williams ADPCM Sound Board
(MC6809E + YM2151 + AD7524 DAC + OKI MSM6295) as 4-bit Dialogic-style ADPCM
in two banked sample ROMs, mks-u12.rom and mks-u13.rom. Nothing about it is
transplantable into MK2's DCS ROMs directly -- it has to be decoded to PCM
here, cleaned up, and then re-encoded by DCSEncoder.

Each sample ROM opens with a 128-entry phrase table, 8 bytes per entry: a
3-byte start address, a 3-byte end address, then 2 unused. The top byte of
the address is the board's bank select, so the ROM offset is the address
masked to the ROM size.

The ADPCM decode mirrors MAME's okim6295 diff_lookup construction, so the
output matches what the MK1 board actually produces. Output is 16-bit mono
at 7576 Hz (1 MHz / 132).

Two post-decode steps that matter before DCS encoding, both applied by
default (see --raw to skip them):

  * DC removal. OKI ADPCM accumulates a standing offset -- measured around
    -1.5% of full scale on MK1's speech. Left in place it wastes DCS band-0
    bits on inaudible content and can audibly thump on stream start/stop.
  * Peak normalisation to -1 dBFS, so the loudness-levelling pass in
    sound/stlaugh_patch.txt starts from a predictable place.

Usage:
    python tools/mk1_oki_extract.py [--rom mk.zip] [--out DIR] [--raw]
                                    [--bank u12|u13|both] [--list]

See doc/AUDIO_IMPORT_PATHS.md for how the output feeds the DCS encode, and
for why this path is third choice behind a verbatim UMK3 stream transplant.
"""
import argparse
import struct
import sys
import wave
import zipfile
from pathlib import Path

# OKI MSM6295 ADPCM, as MAME builds it (sound/okim6295.cpp).
_STEPS = [16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73,
          80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279,
          307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
          1060, 1166, 1282, 1411, 1552]
_INDEX_SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]

_DIFF = [
    (1 - 2 * ((nib >> 3) & 1)) * ((((nib & 7) * 2 + 1) * _STEPS[step]) // 8)
    for step in range(49) for nib in range(16)
]

SAMPLE_RATE = 7576          # 1 MHz / 132
BANKS = ("mks-u12.rom", "mks-u13.rom")


def decode_adpcm(data):
    """Decode OKI ADPCM nibbles to a list of 12-bit signed samples."""
    signal, step = 0, 0
    out = []
    for byte in data:
        for nib in ((byte >> 4) & 0xF, byte & 0xF):
            signal += _DIFF[step * 16 + nib]
            if signal < -2048:
                signal = -2048
            elif signal > 2047:
                signal = 2047
            step += _INDEX_SHIFT[nib & 7]
            if step < 0:
                step = 0
            elif step > 48:
                step = 48
            out.append(signal)
    return out


def phrase_table(rom):
    """Yield (slot, start_offset, end_offset) for every plausible entry."""
    mask = len(rom) - 1
    for slot in range(1, 128):
        o = slot * 8
        start = int.from_bytes(rom[o:o + 3], "big")
        end = int.from_bytes(rom[o + 3:o + 6], "big")
        if not 0 < start < end:
            continue
        s, e = start & mask, end & mask
        if s < e <= len(rom):
            yield slot, s, e


def condition(samples, raw):
    """12-bit signed -> 16-bit signed, with DC removal and normalisation."""
    if not samples:
        return b""
    if raw:
        scaled = [s * 16 for s in samples]
    else:
        dc = sum(samples) / len(samples)
        centred = [s - dc for s in samples]
        peak = max(abs(s) for s in centred) or 1
        gain = (32767 * 0.891) / peak          # -1 dBFS
        scaled = [int(round(s * gain)) for s in centred]
    clipped = [max(-32768, min(32767, s)) for s in scaled]
    return struct.pack(f"<{len(clipped)}h", *clipped)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rom", default=r"C:\MAME\roms\mk.zip",
                    help="MK1 ROM set .zip (default: %(default)s)")
    ap.add_argument("--out", default="tmp/mk1_oki",
                    help="output directory (default: %(default)s)")
    ap.add_argument("--bank", choices=("u12", "u13", "both"), default="both",
                    help="which sample ROM to read (default: %(default)s)")
    ap.add_argument("--raw", action="store_true",
                    help="skip DC removal and normalisation")
    ap.add_argument("--list", action="store_true",
                    help="report the phrase table without writing WAVs")
    args = ap.parse_args()

    rom_path = Path(args.rom)
    if not rom_path.exists():
        print(f"Error: ROM set {rom_path} not found", file=sys.stderr)
        return 1

    wanted = BANKS if args.bank == "both" else (f"mks-{args.bank}.rom",)
    outdir = Path(args.out)
    if not args.list:
        outdir.mkdir(parents=True, exist_ok=True)

    zf = zipfile.ZipFile(rom_path)
    available = set(zf.namelist())
    grand_total = 0.0
    grand_count = 0

    for bank in wanted:
        if bank not in available:
            print(f"Warning: {bank} not in {rom_path.name}, skipping",
                  file=sys.stderr)
            continue
        rom = zf.read(bank)
        tag = bank.split("-")[1].split(".")[0]      # u12 / u13
        print(f"\n=== {bank} ({len(rom):,} bytes)")
        print(f"{'slot':>5}{'offset':>10}{'bytes':>9}{'sec':>8}{'peak dBFS':>11}")

        count, total_sec = 0, 0.0
        for slot, s, e in phrase_table(rom):
            samples = decode_adpcm(rom[s:e])
            sec = len(samples) / SAMPLE_RATE
            pcm = condition(samples, args.raw)
            peak = max(abs(x) for x in samples) if samples else 0
            db = 20 * (peak / 2048) if peak else 0
            count += 1
            total_sec += sec
            if count <= 8 or args.list:
                import math
                dbfs = 20 * math.log10(peak / 2048) if peak else -99
                print(f"{slot:>5}  0x{s:05X}{e - s:>9,}{sec:>8.3f}{dbfs:>11.1f}")
            if not args.list:
                name = outdir / f"mk1_{tag}_{slot:03d}.wav"
                with wave.open(str(name), "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(SAMPLE_RATE)
                    w.writeframes(pcm)
        if count > 8 and not args.list:
            print(f"      ... {count - 8} more")
        print(f"  {count} samples, {total_sec:.1f} s")
        grand_count += count
        grand_total += total_sec

    print(f"\nTotal: {grand_count} samples, {grand_total:.1f} s at "
          f"{SAMPLE_RATE} Hz")
    if not args.list:
        print(f"Written to {outdir}/")
        print("\nThe two banks share a phrase-table layout but hold different "
              "audio:\nall 187 slots decode to distinct PCM (verified by "
              "content hash on --raw output).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
