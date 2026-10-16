#!/usr/bin/env python3
r"""THE WOLF SOUND OVERLAY - UMK3's own sounds for the Wolf-only fighters (MK3
Sonya, Sindel), carried byte for byte out of C:\MAME\roms\umk3.zip.

The Wolf board's DCS set has ~1 MB free (doc/WOLF_UNIT.md "Sound") where the
T-unit's has a few KB, so these go in a Wolf-ONLY patch, sound/wolf_patch.txt,
which makewolf.py appends to sound/stlaugh_patch.txt.  The T-unit never sees it.

WHICH SOUNDS is read out of MK3's arcade source, MKSOUND.ASM
(MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13) - the track numbers there are
UMK3's DCS tracks (reference-umk3-arcade-sound-track-numbers):
  * `st_sonya` and `st_lia` (ochar_sound_tables 1 and 6): their effects;
  * the female row of each voice group (`gs_attack` ... `gs_death`, group 0 =
    gp_female, which ochar_voice_groups gives BOTH of them);
  * Shao Kahn's name calls for them: "Sonya", "Sonya wins", "Sindel",
    "Sindel wins" (Sindel's victory needs her name).

HOW: DCSExplorer lists every UMK3 track's program in the patch language
DCSEncoder reads; each sound's three programs (channels 1-3) are copied with
their mixing levels and waits, given a new Wolf track number ($0600 up, a
triple each), and every stream they play is exported RAW (.dcs) into
sound/wolf/umk3/ - both boards run DCS software 1.01, so the encoder stores
the bytes unchanged: no re-encode.

It also writes src/WOLFSND.ASM: the triple_sndtab2 rows the game sends them
with (`.word priority|duration,track`, MK3's own priority and duration), and
an equate per sound (wsnd_<key>) = its triple_sndtab2 index.

    python tools/make_wolf_audio.py            # report
    python tools/make_wolf_audio.py --apply    # streams, wolf_patch.txt, WOLFSND.ASM
    python tools/make_wolf_audio.py --check    # they are current
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MK3SRC = Path("C:/Users/you/Workplace/MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13")
UMK3 = Path("C:/MAME/roms/umk3.zip")
EXPLORER = Path("C:/Users/you/Workplace/DCSExplorer/x64/Release/DCSExplorer.exe")
OUT_PATCH = ROOT / "sound" / "wolf_patch.txt"
OUT_DIR = ROOT / "sound" / "wolf" / "umk3"
OUT_ASM = ROOT / "src" / "WOLFSND.ASM"
FIRST_TRACK = 0x0600
FIRST_INDEX = 0x69          # the next triple_sndtab2 row after "throne room applause"

# the sound ROM's last chip has ~40 KB left (2026-10-10): his voice and the
# knife's impact fit; the spinning knife (10.6 KB), the ball (9.8 KB) and the
# rest stay on MK2's own sounds until room is found
# MK1 KANO's sounds are MK1's own now (MK1_KANO below) and NONE of MK3's Kano
# ships (2026-10-10, the user's call, for room): MK3's blocked-knife clang went
# (MK1's knife hit plays for a block too), and Ed Boon's uppercut and death
# screams (17.3 KB) went for MK1's knife throw and cannonball - those two
# voice kinds take MK2's male line, as MK1's own were never caught in a probe.
KANO_KEEP: set[str] = set()
KANO_GROUP = 3              # MK3 gp_male3 - E Boon (ochar_voice_groups[0], Kano)
VOICE_GROUPS = ["gs_attack", "gs_jump", "gs_wasted", "gs_grab", "gs_slam",
                "gs_tripped_voice", "gs_face_hit_voice", "gs_shook", "gs_death"]
# Shao Kahn's lines (MKSOUND.ASM's announcer table rows) for them
NAME_ROWS = {"sonya_name": "Shao Kahn: Sonya", "sonya_wins": "Shao Kahn: Sonya wins",
             "sindel_name": "Shao Kahn: Sindel", "sindel_wins": "Shao Kahn: Sindel wins"}
# triple_sndtab rows (MK3 MKSOUND.ASM) for Sonya's fatalities, appended last
FX_ROWS = {"fx_flames": 0x20, "fx_bones": 0x21, "fx_crush": 0x23,
           # Sindel's hair spin: MK3's hair_blood (MKFX.ASM) sends crunch #1
           # and #2 with each of its three blood bursts.  APPENDED, so every
           # earlier wsnd_* index and track number stays where it was.
           "fx_crunch1": 0x24, "fx_crunch2": 0x25}
# UMK3 MUSIC carried the same way - one channel-0 track each, its program and
# streams byte for byte.  MK3's GRAVEYARD (background 9: round_1_tunes 2Dh,
# round_23_tunes 2Eh, finish_tunes 2Fh, winner_tunes 30h "gravend") is THE
# CAVE's soundtrack on Wolf (curback 19h, MAIN.ASM's four tune tables).
FIRST_MUSIC = 0x06F0
MUSIC = [("cave_r1", 0x2D, "MK3 Graveyard, round 1 (intro + loop)"),
         ("cave_r23", 0x2E, "MK3 Graveyard, rounds 2-3 (loop)"),
         ("cave_finish", 0x2F, "MK3 Graveyard, FINISH HIM"),
         ("cave_win", 0x30, "MK3 Graveyard, the win sting (gravend)"),
         # UMK3's own tune tables (FF812F70, 27 rows a table) give background
         # 0Ch - BKGD_HADES_MOD, SCORPION'S LAIR - 1Dh/1Eh/1Fh/20h
         ("lair_r1", 0x1D, "UMK3 Scorpion's Lair, round 1 (intro + loop)"),
         ("lair_r23", 0x1E, "UMK3 Scorpion's Lair, rounds 2-3 (loop)"),
         ("lair_finish", 0x1F, "UMK3 Scorpion's Lair, FINISH HIM"),
         ("lair_win", 0x20, "UMK3 Scorpion's Lair, the win sting"),
         # background 06h - BKGD_SOUL_MOD, THE SOUL CHAMBER (curback 21h) -
         # 21h/22h/23h/24h ("tongueend").  THE PIT 3 (0Ah, curback 22h) needs
         # nothing new: UMK3 plays it the Pit set, 1Dh-20h, which IS the set
         # the Lair carries above (UMK3 reuses the Pit music in Hell).
         # APPENDED, so every earlier wmus_* stays where it was; 06F8h-06FBh,
         # the last four before MK1's music at 0700h.
         ("soul_r1", 0x21, "UMK3 Soul Chamber, round 1 (intro + loop)"),
         ("soul_r23", 0x22, "UMK3 Soul Chamber, rounds 2-3 (loop)"),
         ("soul_finish", 0x23, "UMK3 Soul Chamber, FINISH HIM"),
         ("soul_win", 0x24, "UMK3 Soul Chamber, the win sting (tongueend)")]
ALIASES: dict[str, str] = {}
# UMK3 sounds NOTHING in src/ sends (2026-10-10, reclaimed for MK1 Kano at the
# user's word: "take out any umk3/mk3 stuff we aren't using") - 3.4 KB.  Each
# KEEPS ITS triple_sndtab2 ROW, pointed at the stand-in's tracks, because rows
# after them are sent by NUMBER: MKSEL.ASM's `movi 085h` (Sindel's name) and
# MAIN.ASM's winner-speech `086h` (Sindel wins) would slide onto the wrong
# sound if a row went.  Retired key -> the sound its row plays instead.
# Sindel is a select-screen fighter, so nothing of hers or of the female voice
# she shares is retired; MK3 Sonya is reachable ONLY as Shang's morph, so the
# announcer never says her name and her two calls go.
RETIRED = {"sonya_name": "sindel_name", "sonya_wins": "sindel_wins"}
GROUPS = {"sp_ground": 0x18, "sp_block1": 0x1F, "sp_voice1": 0x41, "sp_effect": 0x50, "sp_hit1": 0x55,
          "sp_hit2": 0x61, "sp_kahnvc": 0x62, "sp_bonusv": 0x70}


def mk3_sounds():
    """[(key, track, group, level, comment)] in a fixed order."""
    txt = (MK3SRC / "MKSOUND.ASM").read_text(errors="replace").splitlines()
    row = re.compile(r"^\s*\.word\s+(sp_\w+)\|(\d+),\s*>?([0-9a-fA-F]+)\s*;\s*(.*)$")

    def table(label):
        i = next(n for n, ln in enumerate(txt) if re.match(label + r"\b", ln))
        out = []
        for ln in txt[i + 1:]:
            m = row.match(ln)
            if not m:
                if out and ln.strip() == "":
                    break
                if ln.strip() and not ln.strip().startswith(";"):
                    break
                continue
            out.append((m.group(1), int(m.group(2)), int(m.group(3), 16), m.group(4).strip()))
        return out

    seen, res = {}, []

    def add(key, g, lvl, trk, com):
        if trk in seen:                 # the same UMK3 sound under another name
            ALIASES[key] = seen[trk]
            return
        seen[trk] = key
        res.append((key, trk, g, lvl, com))

    for who, lab in (("sonya", "st_sonya"), ("sindel", "st_lia")):
        for n, (g, lvl, trk, com) in enumerate(table(lab)):
            add(f"{who}_{n}", g, lvl, trk, f"{lab}[{n}] {com}")
    for gname in VOICE_GROUPS:
        i = next(n for n, ln in enumerate(txt) if re.match(gname + r"\b", ln))
        per = int(re.search(r"\.word\s+(\d+)", txt[i + 1]).group(1))
        rows = []
        for ln in txt[i + 2:]:
            m = row.match(ln)
            if m:
                rows.append(m)
            if len(rows) == per:
                break
        for n, m in enumerate(rows):                    # group 0 = gp_female
            add(f"fem_{gname[3:]}_{n}", m.group(1), int(m.group(2)), int(m.group(3), 16),
                f"{gname}[female {n}] {m.group(4).strip()}")
    for key, want in NAME_ROWS.items():
        m = next(row.match(ln) for ln in txt if row.match(ln) and row.match(ln).group(4).endswith(want))
        add(key, m.group(1), int(m.group(2)), int(m.group(3), 16), want)
    # MK3's generic effects her fatalities play (`tsound n` = triple_sndtab[n])
    i = next(n for n, ln in enumerate(txt) if re.match(r"triple_sndtab\s*$", ln))
    gen = {}
    for ln in txt[i + 1:]:
        if re.match(r"^[A-Za-z_]\w*", ln):         # the next label ends the table
            break
        m = row.match(ln)
        if m:
            k = re.match(r">?([0-9a-fA-F]+)\s*-\s*(.*)$", m.group(4))
            gen[int(k.group(1), 16)] = (m.group(1), int(m.group(2)), int(m.group(3), 16), k.group(2))
    for key, n in FX_ROWS.items():
        g, lvl, trk, com = gen[n]
        add(key, g, lvl, trk, f"triple_sndtab[{n:02x}] {com}")
    # MK1 KANO (Wolf, ochar 22) - APPENDED, so every earlier wsnd_* index and
    # track number stays where it was.  st_kano (MK3's ochar 0) for his
    # effects, and his MK3 voice: ochar_voice_groups[0] = gp_male3 (Ed Boon),
    # row KANO_GROUP of every voice group.
    for n, (g, lvl, trk, com) in enumerate(table("st_kano")):
        if f"kano_{n}" in KANO_KEEP:
            add(f"kano_{n}", g, lvl, trk, f"st_kano[{n}] {com}")
    for gname in VOICE_GROUPS:
        i = next(n for n, ln in enumerate(txt) if re.match(gname + r"\b", ln))
        per = int(re.search(r"\.word\s+(\d+)", txt[i + 1]).group(1))
        rows = []
        for ln in txt[i + 2:]:
            m = row.match(ln)
            if m:
                rows.append(m)
            if len(rows) == per * (KANO_GROUP + 1):
                break
        for n, m in enumerate(rows[per * KANO_GROUP:]):
            if f"m3_{gname[3:]}_{n}" not in KANO_KEEP:
                continue
            add(f"m3_{gname[3:]}_{n}", m.group(1), int(m.group(2)), int(m.group(3), 16),
                f"{gname}[male3 {n}] {m.group(4).strip()}")
    return res


# MK1 KANO's OWN SOUNDS (Wolf, ochar 22), out of MK1 itself, measured by
# tools/run_mk1_kano_probe.ps1 (MAME `mk`, Kano vs an idle 2P Sonya, so every
# male voice is his): the command byte the game sent, and the OKI phrase the
# sound board played for it.  MK Warehouse's MK1 rips (MK1_audio/mkw_mk1_sounds)
# are named by that same command byte in decimal - mk1-00192 is command C0h -
# and match the OKI phrases at 0.82-0.87.  The OKI clips are read from
# mks-u12.rom by phrase slot (the exact bytes the board plays); the knife's two
# sounds are YM2151 FM, which no sample ROM holds, so those come from the
# Warehouse recordings.
# The Wolf sound set is nearly full after this (2026-10-10) - see RETIRED for
# the UMK3 sounds reclaimed to make room.
#   key, source, group, level, comment
MK1_KANO = [
    ("mk1kn_knife_throw", ("wh", "unused/mk1-00136.mp3"), "sp_effect", 110,
     "MK1 88h knife thrown (YM2151 - MK Warehouse mk1-00136)"),
    ("mk1kn_ball_go", ("wh", "unused/mk1-00138.mp3"), "sp_effect", 110,
     "MK1 8Ah cannonball, curls up (YM2151 - MK Warehouse mk1-00138)"),
    ("mk1kn_ball_roll", ("wh", "unused/mk1-00139.mp3"), "sp_effect", 110,
     "MK1 8Bh cannonball, rolls (YM2151 - MK Warehouse mk1-00139)"),
    # (MK1 sends NO voice with the cannonball - 8Ah at the curl and 8Bh at the
    # launch are all tools/run_mk1_kano_probe.ps1 -BallTest logs, so the DCh
    # "yell" (OKI u12 slot 82) this used to play before it is gone.)
    ("mk1kn_knife_stab", ("wh", "unused/mk1-00153.mp3"), "sp_hit1", 115,
     "MK1 99h knife hits (YM2151 - MK Warehouse mk1-00153)"),
    # THE HEART RIP (MAME `mk`, run_mk1_kano_probe.ps1 -TwoPlayer -Win -Heart):
    # 7Ah 44h as the heart is torn out, then 7Ah 45h / 7Ah 46h alternating for
    # as long as he holds it up - lub as it contracts, dub 23 ticks later, on a
    # 42-tick cycle.  All three are in mks-u13.rom, where no phrase-table slot
    # is trusted (the board banks that chip): the bytes MAME's OKI read, by
    # offset and length.  MK Warehouse hitsounds/mk1-00324, 325, 326.
    ("mk1kn_heart_rip", ("u13", 0x25FC1, 3157), "sp_hit1", 118, "MK1 7Ah 44h the heart torn out (OKI u13 25FC1h)"),
    ("mk1kn_heart_lub", ("u13", 0x26C15, 1113), "sp_effect", 118, "MK1 7Ah 45h heartbeat, lub (OKI u13 26C15h)"),
    ("mk1kn_heart_dub", ("u13", 0x2706D, 1203), "sp_effect", 118, "MK1 7Ah 46h heartbeat, dub (OKI u13 2706Dh)"),
]
# HIS VOICE IS MK2's STANDARD MALE SET (2026-10-10, the user's call: "just use
# Kano's specials and leave the other sounds to the standard male MK2 sounds").
# MK1's own, all measured in MAME `mk` and all in MK Warehouse's male/ folder
# by command byte, if they are ever wanted: C0h-C6h swing grunts (OKI u12 slots
# 37-43), C7h jump (44), C8h/C9h throw grab and yell (45, 46), D0h/D1h hurt
# (72, 73), CBh/CCh/CDh the uppercut screams (u12 slot 23; u13 at 2C60Eh and
# 2D0BFh), CEh the death scream (u12 slot 49, 3 s).  About 46 KB encoded.
# A clip that must LAST as long as the move it scores, in GAME TICKS.  MK1's
# curl whirr (8Ah) runs until 8Bh replaces it - at the launch, or when the curl
# TIMES OUT: Block held 900 ticks, MK1 sent 8Bh 128 ticks after 8Ah on its own
# (run_mk1_kano_probe.ps1 -TwoPlayer -BallTest -BallHold 900).  The Warehouse
# recording stops at 2.19 s (120 ticks), so its steady middle is repeated, with
# crossfaded seams, out to the full 128; do_kn_ball (MK1KNM.ASM) cuts it with
# 8Bh on the same channel whenever he launches sooner.
# UMK3 sounds read off UMK3's OWN triple_sndtab (arcade FFB54F60, a word of
# group|level and a word of track per row) - rows MK3 left empty.  APPENDED
# after every MK1 clip, so no earlier wsnd_* index or track moves.
#   key, UMK3 tsound row, comment
UMK3_TABLE = 0xFFB54F60
UMK3_TAIL = [
    # SCORPION'S LAIR: fall_in_lava's tsound(0x5f) "-DHS-" as the lava takes
    # him (FFAE36E0) - the hiss.  One 4 KB stream, looped and faded by its
    # own program.
    ("lair_hiss", 0x5F, "UMK3 tsound 5Fh - the lava hiss (fall_in_lava)"),
    # THE PIT III: Shao Kahn on his throne (UMK3PIT3.ASM up3k_proc) mocks the
    # loser of each round.  These are the four lines UMK3 gives a winning Kahn
    # (rsnd_skb, MKSOUND.C / MK3 REV13 MKSOUND.ASM) - none of them is in MK2,
    # whose own Kahn set (triple_sndtab2 42h-4Fh) has "bow to me", "all too
    # easy" and the rest.  Two are UMK3 tsound rows; the other two live only in
    # Kahn's own ochar table (st_sk 9/0Ah), so they are named by TRACK, with
    # st_sk's group and level.  Track numbers checked against umk3.zip's table.
    ("sk_pathetic", 0x82, "UMK3 tsound 82h - Shao Kahn: That was pathetic"),
    ("sk_neverwin", 0x7D, "UMK3 tsound 7Dh - Shao Kahn: You will never win"),
    ("sk_stilltry", (0x24F4, "sp_kahnvc", 118), "UMK3 st_sk 9 - Shao Kahn: You're still trying to win?"),
    ("sk_nolaugh", (0x2503, "sp_kahnvc", 86), "UMK3 st_sk 0Ah - Shao Kahn: Don't make me laugh"),
]


# MK3 NIGHTWOLF (Wolf, ochar 23) - MK3's ochar 3.  APPENDED after UMK3_TAIL,
# so nothing earlier moves.  Read out of MK3's MKSOUND.ASM like Sonya's:
#   * st_indian, all fifteen rows (ochar_sound_tables[3]) - his move effects;
#     rows 2, 6 and 0Ah-0Eh are his fatalities', carried now so wiring those
#     later needs no renumbering;
#   * his voice: ochar_voice_groups[3] = gp_male2, DAN FORDEN, row 2 of every
#     voice group MK2 has a kind for (rsnd_mk3df, MKSOUND.ASM - MK3's jump and
#     "shook" voices have no MK2 caller and are left out);
#   * Shao Kahn's "Night Wolf" (php_nwolf, MKSEL.ASM) and "Nightwolf wins"
#     (winner_speech row 23, MAIN.ASM) - both referenced there BY NUMBER.
NW_FX_KEYS = ["nw_arrow_appear", "nw_arrow_fire", "nw_burning_axe", "nw_arrow_hit",
              "nw_arrow_blocked", "nw_axe_up", "nw_knee_break", "nw_reflector",
              "nw_shoulder", "nw_axe_hit", "nw_light_start", "nw_light_loop",
              "nw_light_end", "nw_lightning_axe", "nw_lightning_him"]
NW_GROUP = 2                # MK3 gp_male2 - Dan Forden (ochar_voice_groups[3])
NW_VOICES = ["gs_attack", "gs_wasted", "gs_grab", "gs_slam", "gs_tripped_voice",
             "gs_face_hit_voice", "gs_death"]
NW_NAMES = {"nw_name": "Shao Kahn: Night Wolf", "nw_wins": "Shao Kahn: Nightwolf wins"}


def nwolf_rows():
    """[(key, track, group, level, comment)] - MK3 Nightwolf, in a fixed order."""
    txt = (MK3SRC / "MKSOUND.ASM").read_text(errors="replace").splitlines()
    row = re.compile(r"^\s*\.word\s+(sp_\w+)\|(\d+),\s*>?([0-9a-fA-F]+)\s*;\s*(.*)$")
    i = next(n for n, ln in enumerate(txt) if re.match(r"st_indian\b", ln))
    fx = []
    for ln in txt[i + 1:]:
        if re.match(r"^[A-Za-z_]\w*", ln):         # the next label ends the table
            break
        m = row.match(ln)
        if m:
            fx.append(m)
    if len(fx) != len(NW_FX_KEYS):
        raise SystemExit(f"st_indian has {len(fx)} rows, NW_FX_KEYS names {len(NW_FX_KEYS)}")
    out = [(k, int(m.group(3), 16), m.group(1), int(m.group(2)), f"st_indian[{n:x}] {m.group(4).strip()}")
           for n, (k, m) in enumerate(zip(NW_FX_KEYS, fx))]
    for gname in NW_VOICES:
        i = next(n for n, ln in enumerate(txt) if re.match(gname + r"\b", ln))
        per = int(re.search(r"\.word\s+(\d+)", txt[i + 1]).group(1))
        rows = []
        for ln in txt[i + 2:]:
            m = row.match(ln)
            if m:
                rows.append(m)
            if len(rows) == per * (NW_GROUP + 1):
                break
        for n, m in enumerate(rows[per * NW_GROUP:]):
            out.append((f"nw_{gname[3:]}_{n}", int(m.group(3), 16), m.group(1), int(m.group(2)),
                        f"{gname}[male2 {n}] {m.group(4).strip()}"))
    for key, want in NW_NAMES.items():
        m = next(row.match(ln) for ln in txt if row.match(ln) and row.match(ln).group(4).endswith(want))
        out.append((key, int(m.group(3), 16), m.group(1), int(m.group(2)), want))
    return out


def umk3_tail_rows():
    import umk3rom
    rom = umk3rom.UMK3(UMK3)
    by_code = {v: k for k, v in GROUPS.items()}
    out = []
    for key, row, com in UMK3_TAIL:
        if isinstance(row, tuple):              # (track, group, level): not in triple_sndtab
            trk, g, lvl = row
            out.append((key, trk, g, lvl, com))
            continue
        a = UMK3_TABLE + 32 * row
        gl, trk = rom.w(a), rom.w(a + 16)
        if (gl >> 8) not in by_code:
            raise SystemExit(f"UMK3 tsound {row:02X}h: group {gl >> 8:02X}h is not in GROUPS")
        out.append((key, trk, by_code[gl >> 8], gl & 0xFF, com))
    return out


MK1_HOLD_TICKS = {"mk1kn_ball_go": 128}
MK1_ZIP = Path("C:/MAME/roms/mk.zip")
MK1_WH = ROOT / "MK1_audio" / "mkw_mk1_sounds"
MK1_DIR = ROOT / "sound" / "wolf" / "mk1kano"
OKI_RATE = 7576
WH_RATE = 15625                 # the FM recordings, band-limited to 7 kHz first


def mk1_clip(src):
    """(rate, int16 samples) for one MK1 source - conditioned the way the T-unit's
    MK1 imports are (stlaugh_patch.txt note 18): 20 Hz high-pass for the OKI's DC
    offset, silence trimmed, 5 ms edge fades, -3 dBFS peak."""
    import numpy as np
    import zipfile
    sys.path.insert(0, str(ROOT / "tools"))
    import mk1_oki_extract as oki
    kind, ref = src[0], src[1]
    if kind == "u13":
        rom = zipfile.ZipFile(MK1_ZIP).read("mks-u13.rom")
        x, rate = np.array(oki.decode_adpcm(rom[ref:ref + src[2]]), float), OKI_RATE
    elif kind == "oki":
        rom = zipfile.ZipFile(MK1_ZIP).read("mks-u12.rom")
        span = {slot: (a, b) for slot, a, b in oki.phrase_table(rom)}[ref]
        x, rate = np.array(oki.decode_adpcm(rom[span[0]:span[1]]), float), OKI_RATE
    else:
        raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", str(MK1_WH / ref), "-ac", "1",
                              "-af", "lowpass=f=7000", "-ar", str(WH_RATE), "-f", "s16le", "-"],
                             capture_output=True, check=True).stdout
        x, rate = np.frombuffer(raw, dtype=np.int16).astype(float), WH_RATE
    # 20 Hz one-pole high-pass, forward and back (zero phase)
    a = 1.0 / (1.0 + 2 * np.pi * 20 / rate)
    for _ in range(2):
        y = np.zeros_like(x)
        for i in range(1, len(x)):
            y[i] = a * (y[i - 1] + x[i] - x[i - 1])
        x = y[::-1]
    on = np.where(np.abs(x) > np.abs(x).max() * 0.02)[0]
    x = x[max(0, on[0] - rate // 200):on[-1] + rate // 50].copy()
    f = rate // 200
    x[:f] *= np.linspace(0, 1, f)
    x[-f:] *= np.linspace(1, 0, f)
    x *= 32767 * 10 ** (-3 / 20) / np.abs(x).max()
    return rate, np.round(x).astype("<i2")


def mk1_sustain(rate, pcm, ticks):
    """Lengthen a steady clip to exactly `ticks` game ticks by repeating its
    middle third, each seam an equal-power 40 ms crossfade; the clip's own
    opening and ending are kept."""
    import numpy as np
    want = int(round(ticks / 54.7068 * rate))
    x = pcm.astype(float)
    n, xf = len(x), int(rate * 0.040)
    if n >= want:
        return pcm[:want].copy()
    a, b = n // 3, 2 * n // 3                 # the steady body to repeat
    head, body, tail = x[:b], x[a:b], x[b:]
    t = np.linspace(0, np.pi / 2, xf)
    fo, fi = np.cos(t), np.sin(t)

    def join(p, q):
        return np.concatenate([p[:-xf], p[-xf:] * fo + q[:xf] * fi, q[xf:]])
    out = head
    while len(out) + len(tail) - xf < want:
        out = join(out, body)
    cut = len(out) + len(tail) - xf - want    # end the repeat early so the ending
    if cut:                                   # lands exactly on `want` - the seam
        out = out[:-cut]                      # into it is still crossfaded
    out = join(out, tail)
    assert len(out) == want, (len(out), want)
    return np.clip(np.round(out), -32768, 32767).astype("<i2")


def mk1_wav(rate, pcm):
    import io
    import wave
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return b.getvalue()


def mk1_sounds():
    """[(key, wav name, wav bytes, seconds, group, level, comment)]"""
    out = []
    for key, src, g, lvl, com in MK1_KANO:
        rate, pcm = mk1_clip(src)
        if key in MK1_HOLD_TICKS:
            pcm = mk1_sustain(rate, pcm, MK1_HOLD_TICKS[key])
        out.append((key, f"{key}.wav", mk1_wav(rate, pcm), len(pcm) / rate, g, lvl, com))
    return out


def umk3_programs():
    out = subprocess.run([str(EXPLORER), "-I", "--info", "--programs", str(UMK3)],
                         capture_output=True, text=True).stdout
    progs = {}
    for m in re.finditer(r"Track \$([0-9a-fA-F]+) Channel (\d+) \{[^\n]*\n(.*?)\n\};", out, re.S):
        progs[int(m.group(1), 16)] = (int(m.group(2)), m.group(3))
    return progs


def export_streams(addrs):
    """Raw (.dcs) exports of the given UMK3 stream addresses into OUT_DIR."""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        subprocess.run([str(EXPLORER), "-I", "--terse", "--extract-format=raw",
                        f"--extract-streams={td}/u", str(UMK3)],
                       capture_output=True, text=True)
        got = {}
        for p in Path(td).glob("*"):
            m = re.search(r"_([0-9A-Fa-f]{6})\.", p.name)
            if m:
                got[int(m.group(1), 16)] = p
        for a in addrs:
            if a not in got:
                raise SystemExit(f"UMK3 stream ${a:06X} was not exported (have {len(got)})")
            (OUT_DIR / f"U{a:06X}.dcs").write_bytes(got[a].read_bytes())


def build(progs, sounds, mk1=()):
    lines = ["// THE WOLF SOUND OVERLAY - GENERATED by tools/make_wolf_audio.py; edit the",
             "// tool, never this file.  Appended by makewolf.py to stlaugh_patch.txt",
             "// for the Wolf board ONLY.  UMK3's own track programs and streams (raw",
             "// .dcs, byte for byte) for MK3 Sonya and Sindel - see the tool.", ""]
    streams, tracks, rows, missing = set(), [], [], []
    sounds = [s for s in sounds if all(s[1] + ch in progs for ch in range(3)) or missing.append(s)]
    for k, (key, trk, g, lvl, com) in enumerate(sounds):
        new = FIRST_TRACK + 3 * k
        if key in RETIRED:              # its row stays, its tracks and streams go
            rows.append((key, None, g, lvl, com, trk))
            continue
        for ch in range(3):
            pch, body = progs[trk + ch]
            body = re.sub(r"(?i)SetMixingLevel\(level (\d+)\)", r"SetMixingLevel(\1)", body)
            body = re.sub(r"//.*", "", body)
            body = re.sub(r"\(channel (\d)\b", lambda m: f"(channel {m.group(1)}", body)
            for a in re.findall(r"stream \$([0-9A-Fa-f]{6})", body):
                streams.add(int(a, 16))
            body = re.sub(r"stream \$([0-9A-Fa-f]{6})", lambda m: f"U{m.group(1).upper()}", body)
            body = "\n".join(ln.rstrip() for ln in body.splitlines() if ln.strip())
            tracks.append(f"track ${new + ch:04X} channel {ch + 1} {{    // {key}: UMK3 ${trk + ch:04X} - {com}\n{body}\n}};")
        rows.append((key, new, g, lvl, com, trk))
    # a retired row plays its stand-in's tracks
    at = {r[0]: r[1] for r in rows}
    rows = [(k, at[RETIRED[k]], g, l, c, t) if k in RETIRED else (k, n, g, l, c, t)
            for k, n, g, l, c, t in rows]
    # MK1's own clips (MK1_KANO), after every UMK3 sound
    mk1_lines = []
    for key, wav, _b, sec, g, lvl, com in mk1:
        new = FIRST_TRACK + 3 * len(rows)
        frames = int(sec / 0.00768) + 2           # DCS frames of 7.68 ms
        name = "MK1KN_" + key[6:].upper()
        # an explicit bitrate: at the encoder's default these 14 clips put the
        # Wolf set past its 8th (last) 1 MB socket.  48 kbit/s is DCSEncoder's
        # floor, and plenty: the OKI clips carry nothing above 3.8 kHz and the
        # FM recordings are band-limited to 7 kHz
        mk1_lines.append(f'stream {name} "wolf/mk1kano/{wav}" (bitrate=48000);')
        for ch in range(3):
            tracks.append(f"track ${new + ch:04X} channel {ch + 1} {{    // {key}: {com}\n"
                          f"    SetMixingLevel({lvl});\n    Play({name});\n    Wait({frames}) End;\n}};")
        rows.append((key, new, g, min(255, int(sec * 54.7068) + 1), com, None))
    # UMK3_TAIL - UMK3 programs and streams, after the MK1 clips
    for key, trk, g, lvl, com in umk3_tail_rows():
        new = FIRST_TRACK + 3 * len(rows)
        for ch in range(3):
            if trk + ch not in progs:
                raise SystemExit(f"{key}: UMK3 track ${trk + ch:04X} has no program")
            pch, body = progs[trk + ch]
            body = re.sub(r"(?i)SetMixingLevel\(level (\d+)\)", r"SetMixingLevel(\1)", body)
            body = re.sub(r"//.*", "", body)
            for a in re.findall(r"stream \$([0-9A-Fa-f]{6})", body):
                streams.add(int(a, 16))
            body = re.sub(r"stream \$([0-9A-Fa-f]{6})", lambda m: f"U{m.group(1).upper()}", body)
            body = "\n".join(ln.rstrip() for ln in body.splitlines() if ln.strip())
            tracks.append(f"track ${new + ch:04X} channel {ch + 1} {{    // {key}: UMK3 ${trk + ch:04X} - {com}\n{body}\n}};")
        rows.append((key, new, g, lvl, com, trk))
    # MK3 NIGHTWOLF - after the UMK3 tail.  A UMK3 track already carried (by
    # an earlier row or one of his own) is an ALIAS, not a second copy.
    have = {t: k for k, _n, _g, _l, _c, t in rows if t is not None}
    for key, trk, g, lvl, com in nwolf_rows():
        if trk in have:
            ALIASES[key] = have[trk]
            continue
        have[trk] = key
        new = FIRST_TRACK + 3 * len(rows)
        for ch in range(3):
            if trk + ch not in progs:
                raise SystemExit(f"{key}: UMK3 track ${trk + ch:04X} has no program")
            pch, body = progs[trk + ch]
            body = re.sub(r"(?i)SetMixingLevel\(level (\d+)\)", r"SetMixingLevel(\1)", body)
            body = re.sub(r"//.*", "", body)
            for a in re.findall(r"stream \$([0-9A-Fa-f]{6})", body):
                streams.add(int(a, 16))
            body = re.sub(r"stream \$([0-9A-Fa-f]{6})", lambda m: f"U{m.group(1).upper()}", body)
            body = "\n".join(ln.rstrip() for ln in body.splitlines() if ln.strip())
            tracks.append(f"track ${new + ch:04X} channel {ch + 1} {{    // {key}: UMK3 ${trk + ch:04X} - {com}\n{body}\n}};")
        rows.append((key, new, g, lvl, com, trk))
    if FIRST_TRACK + 3 * len(rows) > FIRST_MUSIC:
        raise SystemExit("the sound triples have grown into the music tracks - move FIRST_MUSIC")
    if FIRST_MUSIC + len(MUSIC) > 0x0700:     # tools/make_mk1_music.py FIRST_TRACK
        raise SystemExit("the UMK3 music has grown into MK1's music tracks ($0700 up)")
    for k, (key, trk, com) in enumerate(MUSIC):
        pch, body = progs[trk]
        if pch != 0:
            raise SystemExit(f"UMK3 track ${trk:04X} is not a channel-0 (music) track")
        body = re.sub(r"(?i)SetMixingLevel\(level (\d+)\)", r"SetMixingLevel(\1)", body)
        body = re.sub(r"//.*", "", body)
        for a in re.findall(r"stream \$([0-9A-Fa-f]{6})", body):
            streams.add(int(a, 16))
        # the STREAM keyword stays: the encoder only lets it go when the
        # stream is Play's sole parameter, and these carry `repeat N`
        body = re.sub(r"stream \$([0-9A-Fa-f]{6})", lambda m: f"stream U{m.group(1).upper()}", body)
        body = body.replace("repeat forever", "repeat 0")   # the opcode's own 00
        # Wait(Forever) is the opcode's FFFF.  DCSEncoder takes the word but
        # writes a wait of ZERO, so the track hit its End on the first frame
        # and took its looping stream down with it: the Cave's and the Lair's
        # FINISH HIM tunes were SILENT (measured -71 dB under a -43 dB fight
        # tune, 2026-10-08) with the right code on the latch.  Say it in frames.
        body = body.replace("Wait(Forever)", "Wait(65535)")
        body = "\n".join(ln.rstrip() for ln in body.splitlines() if ln.strip())
        tracks.append(f"track ${FIRST_MUSIC + k:04X} channel 0 {{    // {key}: UMK3 ${trk:04X} - {com}\n{body}\n}};")
    for key, trk, _g, _l, com in missing:
        lines.append(f"// NOT IN UMK3: {key} - MK3 track ${trk:04X} ({com}) has no program in umk3.zip")
    out = lines + [f'stream U{a:06X} "wolf/umk3/U{a:06X}.dcs";' for a in sorted(streams)] + mk1_lines + [""] + tracks
    return "\n".join(out) + "\n", sorted(streams), rows, missing


def build_asm(rows):
    out = [";" + "*" * 70,
           ";  THE WOLF SOUND OVERLAY's triple_sndtab2 rows - GENERATED by",
           ";  tools/make_wolf_audio.py.  Included by MKSOUND.ASM inside",
           ";  triple_sndtab2, under .if wunit; the tracks are sound/wolf_patch.txt's.",
           ";  [priority | duration], channel-1 track - MK3's own priority and",
           ";  duration (clamped to a byte).",
           ";" + "*" * 70]
    for n, (key, new, g, lvl, com, trk) in enumerate(rows):
        src = f"UMK3 ${trk:04X} " if trk is not None else ""
        if key in RETIRED:
            src = f"RETIRED, plays {RETIRED[key]} - was {src}"
        out.append(f"\t.word\t0{GROUPS[g]:02x}00h|{min(lvl, 255)},0{new:04x}h\t; {FIRST_INDEX + n:02x} {key} - {src}{com}")
    return "\n".join(out) + "\n"


def build_equ(rows):
    out = [";  wsnd_* - triple_sndtab2 indices of the Wolf overlay (tools/make_wolf_audio.py)"]
    for n, (key, *_r) in enumerate(rows):
        out.append(f"wsnd_{key}\t.set\t0{FIRST_INDEX + n:02x}h")
    for key, to in ALIASES.items():
        out.append(f"wsnd_{key}\t.set\twsnd_{to}\t; the same UMK3 track")
    for k, (key, trk, com) in enumerate(MUSIC):
        out.append(f"wmus_{key}\t.set\t0{FIRST_MUSIC + k:04x}h\t; {com} (UMK3 ${trk:04X})")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    sounds = mk3_sounds()
    progs = umk3_programs()
    mk1 = mk1_sounds()
    patch, streams, rows, missing = build(progs, sounds, mk1)
    for key, trk, _g, _l, com in missing:
        print(f"  not in umk3.zip: {key} ${trk:04X} {com}")
    asm, equ = build_asm(rows), build_equ(rows)
    print(f"Wolf overlay: {len(rows)} sounds ({len(rows) * 3} tracks from ${FIRST_TRACK:04X}), "
          f"{len(streams)} UMK3 streams; triple_sndtab2 {FIRST_INDEX:02x}h..{FIRST_INDEX + len(rows) - 1:02x}h")
    eqp = ROOT / "src" / "WOLFSNDE.ASM"
    if a.apply:
        export_streams(streams)
        MK1_DIR.mkdir(parents=True, exist_ok=True)
        for _k, wav, b, *_r in mk1:
            (MK1_DIR / wav).write_bytes(b)
        OUT_PATCH.write_text(patch, encoding="utf-8")
        OUT_ASM.write_text(asm, encoding="latin-1", newline="\r\n")
        eqp.write_text(equ, encoding="latin-1", newline="\r\n")
        size = sum((OUT_DIR / f"U{s:06X}.dcs").stat().st_size for s in streams)
        print(f"wrote {OUT_PATCH.relative_to(ROOT)}, {OUT_ASM.name}, {eqp.name}, "
              f"{len(streams)} streams ({size:,} B) in {OUT_DIR.relative_to(ROOT)}")
    if a.check:
        bad = [p.name for p, t in ((OUT_PATCH, patch), (OUT_ASM, asm), (eqp, equ))
               if not p.exists() or p.read_text(encoding="latin-1").replace("\r\n", "\n") != t]
        bad += [f"U{s:06X}.dcs" for s in streams if not (OUT_DIR / f"U{s:06X}.dcs").exists()]
        bad += [wav for _k, wav, b, *_r in mk1 if not (MK1_DIR / wav).exists() or (MK1_DIR / wav).read_bytes() != b]
        if bad:
            raise SystemExit(f"Wolf sound overlay is stale: {bad} - rerun tools/make_wolf_audio.py --apply")
        # rows the game sends BY NUMBER (MKSEL.ASM name calls, MAIN.ASM's
        # winner_speech) - a reorder here would play somebody else's line
        idx = {key: FIRST_INDEX + n for n, (key, *_r) in enumerate(rows)}
        php = r"^{}\s*\n\s*movi\s+\w+,a0[^\n]*\n\s*movi\s+0?([0-9a-f]+)h,a1"
        for f, pat, key in (("MKSEL.ASM", php.format("php_sindel"), "sindel_name"),
                            ("MKSEL.ASM", php.format("php_nwolf"), "nw_name"),
                            ("MAIN.ASM", r"\.word\s+(?:\w+,){1}(\w+?)h?,\w+,\w+,\w+\s*;\s*20 sonya", "sindel_wins"),
                            ("MAIN.ASM", r"\.word\s+(?:\w+,){3}(\w+?)h?,\w+\s*;\s*20 sonya", "nw_wins")):
            m = re.search(pat, (ROOT / "src" / f).read_text(encoding="latin-1").replace("\r\n", "\n"), re.M | re.I)
            if not m or int(m.group(1), 16) != idx[key]:
                raise SystemExit(f"{f}: {key} is sent as {m.group(1) if m else '?'}h, the overlay has it at "
                                 f"{idx[key]:02x}h - fix the number there")
        print("Wolf sound overlay is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
