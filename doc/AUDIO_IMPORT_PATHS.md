# Importing audio from UMK3, MK1 and the web into MK2's DCS ROMs

**Verified 2026-09-17** by building real ROM sets, not by reading DCSEncoder's
documentation. Every claim below has a regeneration command attached.

Three sources were asked about — UMK3, MK1, and mkwarehouse WAV rips. They are
not three versions of the same job. One is a byte copy with zero quality loss,
one is a full transcode from a much worse source format, and one is a transcode
from material of unknown provenance. They are ranked here in that order, which
is also the order of decreasing audio quality and increasing ROM cost.

Durable identifiers here are ROM filenames, hex sound-call codes and OKI phrase
slot numbers. Stream addresses move on every re-encode and are quoted only as
evidence of one specific build.

---

## Headline

| | |
|---|---|
| UMK3 → MK2 | **Verbatim byte copy, zero transcoding loss.** Proven: 35,916 bytes landed byte-for-byte identical |
| MK1 → MK2 | **Full transcode required.** MK1 is not a DCS game — OKI MSM6295 ADPCM at 7,576 Hz |
| WAV → MK2 | **Already the working pipeline.** `sound/stlaugh_patch.txt` does this today |
| Binding constraint | **ROM space, not format compatibility.** Retail MK2 repacks with **7,856 bytes free** |
| Cost, UMK3 verbatim | ~5,900 bytes/sec |
| Cost, MK1 transcode | ~3,970 bytes/sec |

The format questions all came back clean. The one that did not is space: a
single 36 KB UMK3 import overflowed retail MK2 into a phantom U8 chip that does
not exist on the hardware. Read "Budget" below before planning any import.

---

## Path 1 — UMK3, verbatim DCS stream transplant

**This is the only path with no generation loss at all, and it should be the
default for anything UMK3 already contains.**

UMK3 and MK2 run the same DCS software, so a UMK3 stream is not re-encoded on
import — its bytes are copied into the MK2 ROM unchanged.

### Why it works

```
DCSExplorer.exe -I --info C:\MAME\roms\umk3.zip
```

reports `DCS audio board, Software 1.01 (1993)` for UMK3 — the same software
version MK2 runs, and therefore the same 1994+ frame format. Both are 31,250 Hz
mono.

That was confirmed the hard way rather than taken on trust: all **541** UMK3
streams parse cleanly against MK2's exact Huffman codebooks and band tables,
accounting for 99.8% of the listed stream bytes with zero errors. The two games'
bitstreams are the same format down to the codebook.

DCS Explorer's raw export carries this across:

```
DCSExplorer.exe -I --terse --extract-format=raw --extract-streams=out/s C:\MAME\roms\umk3.zip
```

Each `.dcs` file opens with `DCSa` / `9400` / `0001` / `7A12` — signature,
DCS-94+ format, 1 channel, 31,250 Hz. DCSEncoder recognises that header and,
when the target ROM is the same format version, stores the stream data
unmodified.

### Proof it is verbatim

A real patch was built against retail MK2 importing UMK3 stream `3CF018`:

```
stream UmkTest "TESTIMPORT.dcs";
track $02E9 channel 1 {
    SetMixingLevel($7F);
    Play(UmkTest);
    Wait(stream);
};
```

```
DCSEncoder.exe --patch --rom-prefix=* --rom-size=* -o test_out.zip mk2.zip test_import.txt
```

The encoder reported `497 DCS frames, 35916 bytes in ROM` — exactly the size of
the `.dcs` data section, so nothing was re-encoded. Searching the output ROM for
the source bytes found all **35,916 bytes byte-for-byte identical** at
`l1_mortal_kombat_ii_sound_rom_u2.u2` offset `0x046074`.

### What does *not* come across

- **Track programs.** Only the stream is imported. UMK3's track programs,
  channel assignments and mixing levels stay behind, and MK2 track blocks have
  to be written by hand — as `sound/stlaugh_patch.txt` already does. This is
  not a limitation in practice: a DCS stream is channel-agnostic, so there is
  no 6-channel-to-4-channel problem to solve. UMK3 allocating 6 channels and
  MK2 allocating 4 is a property of the track programs, not the audio.
- **Loudness.** UMK3 was mastered louder than MK2. Set `SetMixingLevel()`
  explicitly on every imported track and run it through the loudness-levelling
  pass that note (13) of `stlaugh_patch.txt` describes, or imports will sit
  above the retail mix.

### Cost

UMK3's 541 streams are 4,043,123 bytes for 684.7 seconds — **5,905 bytes per
second**, against MK2's own retail average of 5,240. UMK3 was encoded at a
slightly higher bit rate (47.2 kbps vs MK2's 41.9), so a UMK3 import costs about
13% more ROM per second than equivalent MK2 content.

There is no way to shrink it without giving up the verbatim property. See
`doc/` note below on why re-encoding it would be a mistake.

---

## Path 2 — MK1, full transcode from OKI ADPCM

**MK1 is not a DCS game and nothing about it transplants.** MAME reports its
audio hardware as:

```
mame.exe -listxml mk
  <chip type="audio" tag="adpcm" name="Williams ADPCM Sound Board"/>
  <chip type="cpu"   tag="adpcm:cpu"    name="Motorola MC6809E"     clock="2000000"/>
  <chip type="audio" tag="adpcm:ym2151" name="YM2151 OPM"           clock="3579545"/>
  <chip type="audio" tag="adpcm:dac"    name="AD7524 DAC"/>
  <chip type="audio" tag="adpcm:oki"    name="OKI MSM6295 ADPCM"    clock="1000000"/>
```

`mks-u3.rom` is the 6809 program. `mks-u12.rom` and `mks-u13.rom` are the
sample ROMs: 4-bit Dialogic-style ADPCM at 1 MHz / 132 = **7,576 Hz**, each
opening with the standard 128-entry phrase table (8 bytes per entry: 3-byte
start, 3-byte end, 2 unused; the top address byte is the board's bank select).

### Extraction

`tools/mk1_oki_extract.py` decodes both banks to WAV, mirroring MAME's
`okim6295` `diff_lookup` construction so the output matches what the real board
produces:

```
python tools/mk1_oki_extract.py                    # both banks -> tmp/mk1_oki/
python tools/mk1_oki_extract.py --list             # phrase table only
python tools/mk1_oki_extract.py --raw              # skip DC removal + normalise
```

**187 samples, 555.3 seconds.** The two banks share a phrase-table *layout* —
slots 1–8 have identical start/end offsets in both — but hold different audio;
all 187 decode to distinct PCM, verified by content hash on `--raw` output.
There is no de-duplication to do.

A handful of slots (`u13` 124 and 125, for instance, at 36.8 s and 26.6 s)
decode to implausibly long runs. Those are table entries whose end address
reaches the end of the bank rather than a real phrase boundary — they are music
beds or unbounded entries, not single clips. Audition and trim them by hand
before budgeting ROM for them; the per-second cost figures below assume normal
speech-length clips.

### The decode is real audio, not plausible garbage

Checked statistically rather than assumed:

| Sample | RMS | DC offset | Railed | Zero-crossing rate |
|---|---:|---:|---:|---:|
| `u12` slot 5 | −13.7 dBFS | −1.6% | 0.15% | 921 Hz |
| `u12` slot 12 | −12.9 dBFS | −1.7% | 0.18% | 377 Hz |
| `u12` slot 20 | −9.8 dBFS | −0.9% | 0.38% | 498 Hz |

Zero-crossing rates of 377–921 Hz and RMS around −10 to −14 dBFS are textbook
voiced speech. A broken ADPCM decode rails continuously and shows a
zero-crossing rate near Nyquist; this does neither.

### Two things the extractor fixes, and why they matter

- **DC removal.** OKI ADPCM accumulates a standing offset — measured at roughly
  −1.5% of full scale across MK1's speech. Left in, it spends DCS band-0 bits
  on something inaudible and can thump on stream start and stop.
- **Peak normalisation to −1 dBFS**, so the existing loudness-levelling pass
  starts somewhere predictable.

Pass `--raw` to skip both if you want the unmodified board output.

### Quality ceiling

This path is lossy, but **the loss is dominated by the source, not by DCS**. A
7,576 Hz 4-bit ADPCM sample carries roughly 3.8 kHz of bandwidth at about 30 dB
SNR. DCS at its default settings is comfortably above that on both axes, so the
DCS encode adds very little on top of what MK1 already threw away. What you hear
will be MK1's limitations, faithfully preserved.

### Cost — and the one place this path wins

Three MK1 samples encoded through DCSEncoder against retail MK2:

| Source | Frames | Duration | ROM bytes | Rate |
|---|---:|---:|---:|---:|
| `u12` slot 5 | 59 | 0.453 s | 1,763 | 3,892 B/s |
| `u12` slot 12 | 77 | 0.591 s | 2,210 | 3,739 B/s |
| `u12` slot 20 | 90 | 0.691 s | 2,962 | 4,286 B/s |

**~3,970 bytes/sec — about a third cheaper than a UMK3 verbatim import.** That
is not the encoder doing better; it is the narrowband source. MK1 content only
occupies DCS bands 0–4 (roughly 0–3.8 kHz), and bands 5 and up encode as
zero-width at almost no cost. A second of MK1 speech genuinely costs less ROM
than a second of UMK3.

If ROM space is the binding constraint and the content exists in both games,
MK1 is the cheaper import — at MK1's fidelity.

---

## Path 3 — mkwarehouse WAV → DCS

**This already works and needs no new tooling.** `sound/stlaugh_patch.txt`
imports `.wav` today:

```
stream Laugh "STLAUGH.wav";
stream NoobName "NOOBNAME.wav";
```

DCSEncoder accepts WAV, MP3, Ogg Vorbis and FLAC, resamples to 31,250 Hz and
encodes. Nothing about the mechanism is new or in question.

The concern with this path is **provenance, not mechanism**. Site rips are
typically 22 kHz, frequently MP3-sourced, and sometimes taken from home ports
rather than the arcade boards. Encoding one into DCS stacks a second lossy
generation on top of whatever the rip already lost.

So: for anything that exists in UMK3, Path 1 is strictly better — it is the
original data, bit for bit. For anything that exists in MK1, Path 2 is strictly
better — it reads the arcade ROM directly instead of someone's recording of it.
**Path 3 is for material that exists in neither**, and there it is the only
option and perfectly serviceable.

If a rip is the only source, check it before spending ROM on it: confirm the
real bandwidth (a 22 kHz file upsampled from 11 kHz is common) and prefer the
highest-rate original available.

---

## Budget

This is the part that actually constrains the work.

Retail MK2 repacked through DCSEncoder with an empty patch script:

```
DCSEncoder.exe --patch --rom-prefix=* --rom-size=* -o baseline.zip mk2.zip baseline.txt
```

| Chip | Used | Free |
|---|---:|---:|
| U2 | 524,256 | 32 |
| U3 | 524,226 | 62 |
| U4 | 524,246 | 42 |
| U5 | 524,242 | 46 |
| U6 | 524,242 | 46 |
| U7 | 516,660 | **7,628** |
| | | **7,856 total** |

That is **1.3 seconds** of UMK3 verbatim audio, or **2.0 seconds** of
MK1-sourced audio. The six 512 KiB chips are otherwise full.

The 36 KB single-stream test build above overflowed into a `U8` chip that does
not exist on MK2 hardware — exactly what `makesound.py`'s phantom-U8 guard is
there to catch. **Watch that guard on every re-encode involving an import.**

### Funding imports

Every import beyond ~7.8 KB has to be paid for from the confirmed-dead pool in
`doc/UNUSED_AUDIO.md` — **160,798 bytes** across 47 unreachable clips. Combined
with the baseline free space that is a ceiling of roughly:

- **28 seconds** of UMK3 verbatim audio, or
- **42 seconds** of MK1-sourced audio

and that is the whole budget, assuming every dead clip is reclaimed.

`doc/SOUND_SLOT_AUDIT.md` lists clean untouched triples available now: SKB1L
(4,708 B), COINDROP (4,728 B), GBIGSLIP (4,014 B), RIPARMS (3,766 B). ACID is
larger at 12,644 B but is reserved for planned content.

**A no-op reclaim stays safe only while nothing starts dispatching that slot.**
The DTHUN2 correction in `doc/UNUSED_AUDIO.md` is the worked example: a slot
that was genuinely dead when analysed became live eighteen days later when
`peak_thunder` started randomising over it, and `tools/sound_reach.py` could not
catch it because the index arrives through `randu` arithmetic rather than a
`tsound` literal.

### Do not try to compress your way out of this

Measured against retail MK2, there is no meaningful lossless headroom in the DCS
format. 94% of the ROM is sample codewords, and the stock 1993 Huffman codebooks
already sit within **1.6%** of the order-0 entropy of the symbols they emit.
LZMA over the entire stream region recovers **0.5%**. There are zero duplicate
streams. A retuned, MK2-specific codebook set would free about 51 KiB (1.7%) and
would break DCSExplorer's native decoder; a full order-1 arithmetic coder would
net about 130 KiB and requires rewriting the decoder's inner loop on a 10 MHz
ADSP-2105 driving four channels.

Space comes from deleting dead audio, not from re-compressing live audio.

### Worth one schematic check

`MakeROMPointer` in DCSDecoder decodes chip select as `(addr >> 20) & 7` — the
DCS *software* addresses 8 MiB across 8 chips. UMK3 demonstrates that the DCS
architecture runs fine on 1 MiB chips: its four sound ROMs are 1,048,576 bytes
each.

Whether MK2's board wires U8/U9, or accepts a 27C080 in place of the 27C040s, is
a question about board traces and socket pinout that this repo cannot answer and
`makesound.py`'s guard currently assumes "no". It is worth answering from the
schematic, because the answer is worth between 512 KiB and 3 MiB — two orders of
magnitude more than every reclaim and compression idea in this document
combined.

---

## Recommended order of work

1. **Decide what content is actually wanted**, and check UMK3 for it first.
   Anything UMK3 has, take verbatim — it is free of quality loss and needs no
   new tooling.
2. **For MK1 content**, run `tools/mk1_oki_extract.py` and audition the 187
   clips before budgeting. They are cheap per second but they sound like 1992.
3. **Fall back to WAV rips only** for material in neither ROM.
4. **Fund it from `doc/UNUSED_AUDIO.md`** before encoding, not after, and
   re-run `tools/sound_reach.py` on every slot being reclaimed.
5. **Re-verify with the audit chain** in `doc/SOUND_SLOT_AUDIT.md`: dump retail
   and patched track programs, diff them, and confirm the changed set is exactly
   the set the patch declares.

## Worked example — Jade, 2026-09-17

The first import done through this document, and a caution about what "import
it from UMK3" turns out to mean once the clips in `sound/` are examined.

**Identify before importing.** `tools/dcs_fingerprint.py` matched the existing
Jade clips against all 541 decoded UMK3 streams:

| Clip in `sound/` | UMK3 stream | Score | Verdict |
|---|---|---:|---|
| `JADENITROKICK_prev.wav` | `$070794` (track `$52A8`) | 1.000 | certain, runner-up 0.964 |
| `JADEBOOMWHOOSH_orig_backup.wav` | `$102AF6` (track `$0226`) | 0.997 | certain, r = **1.0000** at sample level |
| `JADEINV.wav` | — | 0.939 | **no match**, field flat to 0.932 |

The finding that mattered: **the Jade audio in the build was already UMK3
first-generation.** `JADEBOOMWHOOSH_orig_backup.wav` is a bit-identical decode
of UMK3 `$102AF6`. The pipeline was never a web rip.

**JadeNitroKick — swapped.** Verbatim `.dcs` import, 5,693 B against 6,890 B,
**+1,196 bytes reclaimed** (measured before/after, not predicted). The stream is
3.60 dB hotter than the enhanced WAV, so `SetMixingLevel` went `$70` → `$4A` to
hold note (13)'s target exactly. Verified byte-for-byte in the built ROM at
U6 `0x059140`, and the semantic track-program diff across the whole ROM is
exactly two lines — the level, and `Wait(119)` → `Wait(121)` for the 15 ms
longer stream.

**JadeBoomWhoosh — deliberately not swapped.** The clip in use is already that
UMK3 stream, peak-normalised **+10.95 dB** because note (13) could not reach the
loudness target by level alone. Its `SetMixingLevel` is already maxed at `$7F`.
A verbatim import would drop the boomerang ~11 dB with no headroom to recover
it. The single DCS re-encode generation is the price of that gain, and it is
worth paying.

**The general lesson.** A verbatim import is only better when the clip is used
at the loudness the source ROM recorded it at. Once a clip has been normalised
or gain-staged to fit MK2's mix, the re-encode is doing necessary work and
"importing it properly" is a regression. Check `SetMixingLevel` headroom before
every swap:

```
python tools/dcs_fingerprint.py --corpus umk3wav sound/CLIP.wav
python tools/dcs_fingerprint.py --verify sound/CLIP.wav umk3wav/u_XXXX_....wav
```

**Correction — JadeProtect / Flash, ported.** `JADEINV.wav` did not
fingerprint because it was never a single stream: it is a *recording* of UMK3
retriggering `ST_JADE_FLASH` (track `52b2`, stream `$070304`) once per blink —
ten 110.66 ms slices, 6 ticks apart at 54.7068 Hz. UMK3's own source
(`UltimateMortalKombat3/.../src/MKSOUND.H`, `MKSOUND.C` `st_fn[]`,
`MKSTAT.C` `jade_flash_proc`) settled it, and also confirmed the other two
identifications above (`226` = `ST_JADE_ARROW`, `52a8` = `ST_JADE_PROP`).
The port now stores the stream verbatim (1,168 B, **6,108 bytes reclaimed**),
copies UMK3's track program (level 115, `Wait(50)`), and sends `$0358` from
inside `jade_flash_blink_proc` once per blink. `tools/jade_boomerang_test.lua`
proves it in MAME: ten sends, every gap 6 frames, and the sends stop when a hit
drops the flash. See `sound/stlaugh_patch.txt` note (36).

**ZAP added, TELE deliberately not** (patch note (37)). `ST_JADE_ZAP` (`348`)
is UMK3's boomerang *hit* sound — `r_boomerang` plays the attacker's sound 5 —
so it is sent from `r_jade_boom` and `r_jade_boom_back`, verbatim on the
reclaimed SKB1L slot `$0564`. In MAME it fires on the frame the blade takes HP,
on the outbound hit and the homeward hit, and not on a blocked throw.
`ST_JADE_TELE` (`375`) is filed under JADE in `MKSOUND.H` only because Jade,
Kitana and Mileena share one sound table; its one caller is Mileena's teleport,
so Jade never plays it and it was not added. NitroKick's track now uses UMK3's
own `$52A8` program (level 120).

## Regenerating the evidence

```
# Path 1 — format compatibility and verbatim transplant
DCSExplorer.exe -I --info C:\MAME\roms\umk3.zip
DCSExplorer.exe -I --terse --extract-format=raw --extract-streams=out/s C:\MAME\roms\umk3.zip
DCSEncoder.exe --patch --rom-prefix=* --rom-size=* -o test.zip mk2.zip <script>

# Path 2 — MK1 extraction
mame.exe -listxml mk
python tools/mk1_oki_extract.py --list

# Budget baseline
DCSEncoder.exe --patch --rom-prefix=* --rom-size=* -o baseline.zip mk2.zip <empty script>
```

---

## Verifying an install — two traps that give false answers

Both of these were hit on 2026-09-28 while confirming the verbatim Jade whoosh
and the DRAW line, and both produce a confident wrong result rather than an
error, so they are worth knowing before you trust a check.

**1. You cannot find a program table row by searching the ROM zip.** The
TMS34010 program is split across *paired 8-bit chips*, so a 16-bit word never
appears contiguously in any single chip or in a concatenation of them. Searching
the installed zip for `sp_bossv1|54,021eh` returns zero occurrences whether the
row is there or not. Search **`src/mk2.out`** instead — the linked object is not
interleaved, and the row appears exactly once:

```
python - <<'PY'
out = open('src/mk2.out','rb').read()
w = 0x7036                      # sp_bossv1 (070h<<8) | duration 54
print(out.count(bytes([w & 0xff, w >> 8, 0x1e, 0x02])))   # -> 1
PY
```

Stream *audio* is the opposite case: DCS streams are stored linearly, so a
`.dcs` data section (skip its 36-byte header) does appear verbatim in the zip,
which is exactly how the byte-copy census works.

**2. `crc_spoof`'s patch window moves, so do not compare chips by hash or by
trimming a fixed tail.** It rewrites 4 bytes near the end of each chip, but the
offset differs per chip — `0x7ffbc` on ug12/uj12, `0x0fffca` and `0x0fff84` on
others in earlier runs. Hashing reports "no match" for a perfectly good install,
and ignoring only the last 4 bytes does too. Count differing byte *positions*:
4 contiguous bytes near the end is the spoof; anything else is a real
difference.

**Neither check sees the failure that has actually shipped here**, which is a
packaging step silently selecting retail sound. Only decoding the installed set
catches that:

```
DCSExplorer.exe -I --extract-tracks=<dir>/t C:\MAME\roms\mk2.zip
```

then confirm the tracks you changed decode at the length and loudness the trial
encode predicted. On 2026-09-28 that gave DRAW `$021E-$0220` at -20.06 dB /
1.01s and Jade's whoosh `$0368` at -17.13 dB / 0.79s, both matching their trial
figures — so the 1.8 dB the verbatim whoosh costs is the stream, not packaging.
