#!/usr/bin/env python3
r"""RAIN's and KHAMELEON's colours, out of MK Trilogy and into `data/KATPAL.IMG`.

WHY: neither fighter exists in any arcade ROM.  Rain is Trilogy-only and
Khameleon is N64-Trilogy-only, so `C:\MAME\roms\umk3.zip` - the source of the
64-entry palettes already in this library - does not carry a single word of
either.  The only copy on this machine is the N64 Trilogy source tree, and
nothing in this project could open it, so every Rain repaint here has been
eyeballed against a screenshot.  This puts the words in an IMG library, which
is the one container IMGTOOL can open.

    python tools/import_trilogy_rain_kamel.py           # report, write nothing
    python tools/import_trilogy_rain_kamel.py --apply   # write them into the IMG
    python tools/import_trilogy_rain_kamel.py --check   # fail if any drifted
    python tools/import_trilogy_rain_kamel.py --rgb     # + the colours as hex
    python tools/import_trilogy_rain_kamel.py --png     # + stance previews

`KATPAL.IMG` is in NO LOD file - LOAD2 never reads it and none of this reaches
a ROM.  It is a reference library, and `tools/backup_code_palettes.py --apply`
and `tools/import_mk1_palettes.py --apply` both preserve records they do not
own, so the three co-exist.

THESE ARE 32-ENTRY, 5bpp PALETTES AND THE REST OF THE LIBRARY IS 64-ENTRY,
6bpp.  That is not a mistake and it cannot be fixed by padding.  The N64 port
re-indexed every character palette down to 32 colours: Trilogy's `KIT1_P` and
UMK3's `KIT1_P` share 7 of 32 colours and NO index position, so a Trilogy
palette dropped onto one of this library's UMK3 stances draws a correct-looking
picture in scrambled colours - `tools/check_img_names.py`'s failure mode,
arrived at from the other direction.  Hence the sprite: each costume palette
gets Trilogy's OWN ninja stance, decoded from the same tree, so what IMGTOOL
shows is the palette on the art it was authored for.

WHICH STANCE IS NOT CHOSEN HERE - IT IS READ.  `a_stance` (MKNJ.ASM,
MKFN.ASM) opens with `ani_ochar_jump` rows for the ochars that have a lane of
their own; neither `ft_rain` nor `ft_kamel` is one, so both fall through to
the default, and the default is Scorpion's `SCSTANCE1` for the male ninja and
Kitana's `KTSTANCE1` for the female.  `--check` re-reads that list and fails
if either fighter ever acquires a lane.

Four independent proofs run before anything is written:

  * `FT_RAIN` / `FT_KAMEL` are read out of `MKGAME.H`, not assumed, and
    `character_palettes_1[]` / `_2[]` in `MKGUYS.C` must name the four costume
    palettes AT THOSE INDICES.  A table that grew a row fails here rather than
    importing somebody else's costume under Rain's name.
  * ten of the nineteen palettes exist a second time in the tree, as the
    artist's own `.RGB` file under a different symbol (`RAIN1_P` is
    `MNINJA/RAIN.RGB:rain_PAL`, `KAMEL1_P` is `FNINJA/KAMMYNU.RGB:kammynu_PAL`
    - Khameleon's shipped palette is the one called "kammy NEW", not `kammy1`),
    and every one must be word-for-word identical.
  * the stance record names its own palette (`SCSTANCE1_SUB` ends
    `.word SCORP1_P`), and that must be the body reference this import
    measures against.
  * the SHARED BODY RAMP.  The male ninjas share their first 17 entries and
    the female ninjas their first 21 - neutral greys, then flesh - and each
    costume palette's share is pinned to the exact number it has today.  Rain
    shares all 17 and Khameleon all 21; `KAM2_P` and the two unshipped
    `kammy` passes share 1, because they recolour the skin as well, which is
    what `JADE1_P` does too.  Pinning the number, rather than requiring a
    match, is what makes a swapped palette fail instead of a recoloured one.

NOT EVERY PALETTE GETS A SPRITE.  Only the six that are worn by a fighter
STANDING UP: the four in `character_palettes_1/2`, plus the two unshipped
`kammy` passes, which draw correctly on the same body.  The other thirteen are
for art this import does not carry - the two halves of a body cut in half, a
ripped torso, a babality, a brutality, Shang mid-morph, the ghost - so a
stance under them would be a picture of the wrong thing, not a preview.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import img_palette as ip                                        # noqa: E402
import make_rainn64_img as N64                                  # noqa: E402
from backup_code_palettes import (NUMDEFPAL, pal_record, read_lib,  # noqa: E402
                                  write_lib)
from import_mk1_palettes import img_record, img_bytes           # noqa: E402

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "data" / "KATPAL.IMG"
PNGDIR = REPO / "tmp" / "trilogy_rain_kamel"

TRIL = N64.TRIL                                 # ...\MKTRIL~1\SEG
GAME = TRIL / "GAMECODE"
IMGPAL = GAME / "IMGPAL.S"                      # the shipped palette source
MKGUYS = GAME / "MKGUYS.C"                      # character_palettes_1 / _2
MKGAME = GAME / "MKGAME.H"                      # FT_* ochar numbers
MN = TRIL / "CHARDATA" / "MNINJA"
FN = TRIL / "CHARDATA" / "FNINJA"

# --- the two shared bodies -------------------------------------------------
# `ref` is the palette the stance record itself names, and `body` is how many
# leading entries every costume on that body shares with it.  17 and 21 are
# measured, not guessed: RAIN2/REP1/SUBZ1/ERMAC1 all share exactly 17 with
# SCORP1_P, and KAMEL1/MIL1 exactly 21 with KIT1_P.
BODIES = {
    "m": dict(dir=MN, stem="MKNJ", ref="SCORP1_P", body=17, who="male ninja"),
    "f": dict(dir=FN, stem="MKFN", ref="KIT1_P", body=21, who="female ninja"),
}

# --- what is imported ------------------------------------------------------
# name        the record written into KATPAL.IMG (the IMG palette name field
#             is TEN BYTES, so nine characters plus the terminator - three of
#             Trilogy's own symbols are a letter too long and are clipped)
# label       the symbol in IMGPAL.S, or in the .RGB file named by `src`
# src         None = IMGPAL.S (shipped); a filename = that .RGB only
# body        which shared body the palette is for
# share       leading entries it shares with that body's `ref`
# twin        the artist's second copy of the same words, or None
# stance      the image record name to draw the body under it, or None
PALETTES = [
    # ---- RAIN, ochar 26 ---------------------------------------------------
    ("RAIN1_P", "RAIN1_P", None, "m", 17, "RAIN.RGB:rain_PAL",
     "MKTRAINST1", "default costume - character_palettes_1[FT_RAIN]"),
    ("RAIN2_P", "RAIN2_P", None, "m", 17, "RAINALT.RGB:rainalt_PAL",
     "MKTRAI2ST1", "alternate / mirror - character_palettes_2[FT_RAIN]"),
    ("RAINCUT_P", "RAINCUT_P", None, "m", 11, "RAINCUT.RGB:raincut_PAL",
     None, "cut in half"),
    ("RAIN2CUTP", "RAIN2CUT_P", None, "m", 11, "RAINALTC.RGB:rainaltcut_PAL",
     None, "cut in half, alternate costume"),
    ("RAINRIP_P", "RAINRIP_P", None, "m", 1, "RAINRIP.RGB:rainrip_PAL",
     None, "torso ripped off"),
    ("BHRAIN_P", "BHRAIN_P", None, "m", 1, "BHRAIN.RGB:BHRAIN_PAL",
     None, "brutality"),
    ("BABYRAINP", "BABYRAIN_P", None, "m", 1, "BABYRAIN.RGB:BABYrain_PAL",
     None, "babality"),
    ("MORFRAINP", "MORFRAIN_P", None, "m", 1, None,
     None, "Shang Tsung morphing into him"),
    ("RAINSCARP", "RAINSCAR_P", None, "m", 0, "RAINGHOS.RGB:rainghost_PAL",
     None, "ghost / scar"),
    # ---- KHAMELEON, ochar 27 ----------------------------------------------
    ("KAMEL1_P", "KAMEL1_P", None, "f", 21, "KAMMYNU.RGB:kammynu_PAL",
     "MKTKAMST1", "default costume - character_palettes_1[FT_KAMEL]"),
    ("KAM2_P", "KAM2_P", None, "f", 1, None,
     "MKTKAM2ST1", "alternate / mirror - character_palettes_2[FT_KAMEL]"),
    ("KAMCUT_P", "KAMCUT_P", None, "f", 7, None, None, "cut in half"),
    ("KAMRIP_P", "KAMRIP_P", None, "f", 1, None, None, "torso ripped off"),
    ("BHKAM_P", "BHKAM_P", None, "f", 1, None, None, "brutality"),
    ("BABYKAM_P", "BABYKAM_P", None, "f", 1, "BABYKAM.RGB:BABYKAM_PAL",
     None, "babality"),
    ("KAMORF_P", "KAMORF_P", None, "f", 1, None,
     None, "Shang Tsung morphing into her"),
    ("KAMSCAR_P", "KAMSCAR_P", None, "f", 1, None, None, "ghost / scar"),
    # The two Khameleon passes IMGPAL.S does NOT carry.  Nothing in the game
    # references either - `kammynu` ("kammy new") is what shipped - but both
    # are complete costumes and draw correctly on the body, so they come in
    # with a stance of their own rather than as words nobody can judge.
    ("KAMMY1_P", "kammy1_PAL", "KAMMY1.RGB", "f", 1, None,
     "MKTKMY1ST1", "unshipped earlier costume (in the .RGB only)"),
    ("KAMMY2_P", "kammy2_PAL", "KAMMY2.RGB", "f", 1, None,
     "MKTKMY2ST1", "unshipped earlier costume (in the .RGB only)"),
]

# --- the VS-screen portraits: THE ONLY 64-COLOUR RAIN AND KHAMELEON THERE IS -
# `CHARDATA/{MNINJA,FNINJA}` keep the arcade 64-colour originals beside the
# reductions (`MKNJ.PAL` as flat 15-bit, `MKFN.PAL` in the N64 alpha form; both
# are UMK3's own words to within a few slots) - but Rain and Khameleon are NOT
# among them.  Those files are February 1996 and the two fighters' palettes are
# April-June, authored straight at 32 colours, after the reduction.  And the
# reduction cannot be undone: it RE-QUANTISED rather than selected, so Trilogy's
# `KIT1_P` and UMK3's share 7 of 32 colours and no index correspondence at all.
#
# `ATTRACT/VS` is the exception.  The VS-screen portrait is a separate, larger
# drawing that stayed at 64 colours, and both fighters have their own pieces in
# it - `VRAINGREEN1A-E` in `rain_pieces`, `VKAMGREEN1A-F` in `kamel_pieces`.
# So these five ARE Midway's Rain and Khameleon at full arcade colour depth.
# They are for the portrait art, which lives in a texture blob this import does
# not decode, so they come in as words with no sprite.
VSDIR = TRIL / "ATTRACT" / "VS"

# name, the file the SHIPPED copy is in, its label, the artist's twin, what it is
VS_PALETTES = [
    ("RNVS1_P", "VSMNINJA.MAS", "SCORPRAIN1_PAL", "RAIN.RGB:SCORPRAIN1_PAL",
     "RAIN's VS portrait - the ramp the RAINGREEN records name"),
    ("RNVS2_P", "VSMNINJA.MAS", "SCORPRAIN2_PAL", "RAINALT.RGB:RAIN2_PAL",
     "RAIN's VS portrait - the ramp rain_pieces overrides to"),
    ("RNVSA_P", "RAIN1.RGB", "rain1_PAL", None,
     "RAIN VS, unshipped variant (RAIN1.RGB)"),
    ("RNVSB_P", "RAIN2.RGB", "rain2_PAL", None,
     "RAIN VS, unshipped variant (RAIN2.RGB)"),
    ("KAMVS_P", "VSFNINJA.MAS", "KAMGREY_P", "KAMGREY.RGB:kamgrey_PAL",
     "KHAMELEON's VS portrait"),
]

# The VS proof: the portrait piece lists must still carry each fighter's own
# pieces, under the palette imported for them.
#   module, piece-list label, the piece prefix that is his alone, its palette
VS_PIECES = [
    ("ARTMNI~1.S", "rain_pieces", "VRAINGREEN", "SCORPRAIN2_PAL"),
    ("ARTFNI~1.S", "kamel_pieces", "VKAMGREEN", None),
]

# The costume palettes, and where the game's own tables must name them.
# table -> {ochar symbol: palette label}
COSTUMES = {
    "character_palettes_1": {"FT_RAIN": "RAIN1_P", "FT_KAMEL": "KAMEL1_P"},
    "character_palettes_2": {"FT_RAIN": "RAIN2_P", "FT_KAMEL": "KAM2_P"},
}


def read(p: Path) -> str:
    return p.read_text(encoding="latin-1")


# ---------------------------------------------------------------------------
# the Trilogy source
# ---------------------------------------------------------------------------

def ft_numbers(text: str) -> dict:
    """`#define FT_NAME n` out of MKGAME.H."""
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r"^#define\s+(FT_\w+)\s+(\d+)", text, re.M)}


def c_table(text: str, name: str) -> list:
    """`void *NAME[] = { A, B, ... };` as a list of symbols, comments stripped.

    The comments in MKGUYS.C's two tables disagree with each other (ermac is
    labelled 21 and classic sub-zero 20, in that order), so POSITION is the
    only thing read here."""
    m = re.search(r"\b" + re.escape(name) + r"\s*\[\s*\]\s*=\s*\{(.*?)\}\s*;",
                  text, re.S)
    if not m:
        sys.exit("%s: no table called %s" % (MKGUYS.name, name))
    body = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)
    return [t.strip() for t in body.split(",") if t.strip()]


def stance_frame(cfg: dict, ft_here: str) -> str:
    """The frame `a_stance` reaches for a fighter with no lane of his own.

    The lane opens with `ani_ochar_jump / ft_<who> / a_<who>_stance` triples
    and then falls through to the default frame list.  Returns the first
    default frame, and refuses if `ft_here` is one of the fighters that has
    been given a lane - which would mean this import is drawing the wrong
    body."""
    asm = read(cfg["dir"] / (cfg["stem"] + ".ASM"))
    m = re.search(r"^a_stance\s*$(.*?)^\s*\.long\s+ani_jump", asm, re.S | re.M)
    if not m:
        sys.exit("%s.ASM: cannot find a_stance" % cfg["stem"])
    toks = []
    for ln in m.group(1).splitlines():
        t = re.match(r"\s*\.long\s+(.*?)\s*(?:;.*)?$", ln)
        if t:
            toks += [x.strip() for x in t.group(1).split(",") if x.strip()]
    jumps, first, i = [], None, 0
    while i < len(toks):
        if toks[i] == "ani_ochar_jump":
            jumps.append(toks[i + 1])
            i += 3
            continue
        first = first or toks[i]
        i += 1
    if ft_here in jumps:
        sys.exit("%s.ASM: a_stance now branches on %s - this import would draw "
                 "the wrong lane" % (cfg["stem"], ft_here))
    if not first:
        sys.exit("%s.ASM: a_stance has no default frame" % cfg["stem"])
    return first


HDR = (r"^(\w+?)(?:_SUB)?:\s*\n\s*\.word\s+(\w+_IMG)\s*\n\s*"
       r"\.half\s+(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)"
       r"(?:\s*\n\s*\.word\s+(\w+)\s*$)?")


def stance_art(cfg: dict, name: str):
    """-> (w, h, anix, aniy, pixel indices, the palette the record names).

    A Trilogy frame header is `.half H, W, anix, aniy` - height FIRST, the
    reverse of an MK2 image record - and the pixels are stored with each row
    padded to 4, which is cropped off here the way make_rainn64_img.py does."""
    d = cfg["dir"]
    atd, att = read(d / (cfg["stem"] + ".ATD")), read(d / (cfg["stem"] + ".ATT"))
    dct = bytes(int(x, 16) for x in
                re.findall(r"0x([0-9A-Fa-f]{2})", read(d / (cfg["stem"] + ".DCT"))))
    if len(dct) != 256:
        sys.exit("%s.DCT: %d bytes, expected 256" % (cfg["stem"], len(dct)))
    rec = None
    for m in re.finditer(HDR, atd, re.M):
        if m.group(1) == name:
            rec = m
            break
    if rec is None:
        sys.exit("%s.ATD: no frame record called %s" % (cfg["stem"], name))
    label, h, w = rec.group(2), int(rec.group(3)), int(rec.group(4))
    ax, ay, pal = int(rec.group(5)), int(rec.group(6)), rec.group(7)
    px, got, size, typ = N64.uncompress(N64.img_bytes(att, label), dct)
    stride = (w + 3) & ~3
    if got != size or size != stride * h:
        sys.exit("%s: type %d unpacked %d, header says %d, stride*H is %d"
                 % (name, typ, got, size, stride * h))
    if pal != cfg["ref"]:
        sys.exit("%s names palette %s, not %s - the body reference this import "
                 "measures against has moved" % (name, pal, cfg["ref"]))
    rows = b"".join(px[r * stride:r * stride + w] for r in range(h))
    return w, h, ax, ay, rows, pal


# ---------------------------------------------------------------------------
# collect + prove
# ---------------------------------------------------------------------------

def leading_match(a, b) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def collect():
    """-> (palette rows, stance rows).  Everything is proved before it returns.

    A palette row is (name, label, desc, mk2 colour words).
    A stance row is (name, desc, w, h, anix, aniy, pixels, palette name)."""
    if not IMGPAL.exists():
        sys.exit("Trilogy source not found: %s" % TRIL)

    shipped = read(IMGPAL)
    ft = ft_numbers(read(MKGAME))
    guys = read(MKGUYS)

    # --- proof 1: the game's own costume tables ---------------------------
    for table, wanted in COSTUMES.items():
        rows = c_table(guys, table)
        for ftname, label in wanted.items():
            if ftname not in ft:
                sys.exit("%s defines no %s" % (MKGAME.name, ftname))
            i = ft[ftname]
            if i >= len(rows):
                sys.exit("%s has %d rows, %s is %d - the table cannot hold him"
                         % (table, len(rows), ftname, i))
            if rows[i] != label:
                sys.exit(
                    "COSTUME TABLE FAILED: %s[%s = %d] is %s, not %s.  Either "
                    "the table gained a row or the ochar numbers moved - do "
                    "not write anything until this is understood."
                    % (table, ftname, i, rows[i], label))

    # --- the palettes, with the twin and body-ramp proofs ------------------
    pals, words = [], {}
    for name, label, src, body, share, twin, _st, desc in PALETTES:
        path = IMGPAL if src is None else BODIES[body]["dir"] / src
        w = [N64.mk2_colour(v) for v in N64.n64_pal(path, label)]
        words[name] = w
        pals.append((name, label, "%s - %s" % (desc, label), w))

    ref = {k: [N64.mk2_colour(v) for v in N64.n64_pal(IMGPAL, cfg["ref"])]
           for k, cfg in BODIES.items()}

    for name, label, src, body, share, twin, _st, _d in PALETTES:
        # --- proof 2: the artist's second copy ----------------------------
        if twin:
            fn, sym = twin.split(":")
            tw = [N64.mk2_colour(v)
                  for v in N64.n64_pal(BODIES[body]["dir"] / fn, sym)]
            if tw != words[name]:
                sys.exit("TWIN FAILED: %s (%s) differs from %s - one of the "
                         "two sources has been edited" % (name, label, twin))
        # --- proof 4: the shared body ramp --------------------------------
        got = leading_match(words[name], ref[body])
        if got != share:
            sys.exit(
                "BODY RAMP FAILED: %s shares %d leading entries with %s, not "
                "%d.  The %s body is %d entries; a costume that shares all of "
                "them wears the stock skin and one that shares fewer recolours "
                "it, so a changed number means these are not the words this "
                "import was written against."
                % (name, got, BODIES[body]["ref"], share, BODIES[body]["who"],
                   BODIES[body]["body"]))

    # --- the VS portraits, proved off the portrait piece lists ------------
    for mod, plist, prefix, override in VS_PIECES:
        src = read(VSDIR / mod)
        m = re.search(r"^" + re.escape(plist) + r":(.*?)\.word\s+0\s*$",
                      src, re.S | re.M)
        if not m:
            sys.exit("%s: no piece list called %s" % (mod, plist))
        rows = re.findall(r"\.word\s+(\w+)\s*,\s*(\w+)", m.group(1))
        mine = [(p, o) for p, o in rows if p.startswith(prefix)]
        if not mine:
            sys.exit("VS FAILED: %s carries no %s* piece - the portrait no "
                     "longer has art of its own" % (plist, prefix))
        want = override or "0"
        bad = [(p, o) for p, o in mine if o != want]
        if bad:
            sys.exit("VS FAILED: %s's %s draws under %s, not %s"
                     % (plist, bad[0][0], bad[0][1], want))

    for name, mod, label, twin, _desc in VS_PALETTES:
        w = [N64.mk2_colour(v) for v in N64.n64_pal(VSDIR / mod, label)]
        if len(w) != 64:
            sys.exit("%s (%s:%s) has %d entries, not 64 - the VS palettes are "
                     "the 64-colour set and that is the whole point of them"
                     % (name, mod, label, len(w)))
        if twin:
            fn, sym = twin.split(":")
            tw = [N64.mk2_colour(v) for v in N64.n64_pal(VSDIR / fn, sym)]
            if tw != w:
                sys.exit("TWIN FAILED: %s (%s:%s) differs from %s - one of the "
                         "two sources has been edited" % (name, mod, label, twin))
        words[name] = w
        pals.append((name, label, "%s - %s" % (_desc, label), w))

    # --- proof 3: which lane, and the stance art --------------------------
    art, frame_of = {}, {}
    for key, cfg in BODIES.items():
        ftname = "ft_rain" if key == "m" else "ft_kamel"
        frame = stance_frame(cfg, ftname)
        frame_of[key] = frame
        art[key] = stance_art(cfg, frame)

    stances = []
    for name, label, src, body, share, twin, st, desc in PALETTES:
        if not st:
            continue
        w, h, ax, ay, px, _pal = art[body]
        hi = max(px)
        if hi >= len(words[name]):
            sys.exit("%s uses index %d, past %s's %d entries"
                     % (frame_of[body], hi, name, len(words[name])))
        stances.append((st, "%s %s, %dx%d" % (BODIES[body]["who"],
                                              frame_of[body], w, h),
                        w, h, ax, ay, img_bytes(w, h,
                                                [list(px[r * w:(r + 1) * w])
                                                 for r in range(h)]), name))
    return pals, stances


# ---------------------------------------------------------------------------
# report / write
# ---------------------------------------------------------------------------

def report(pals, stances, show_rgb: bool) -> None:
    have = dict((n.upper(), w) for n, w in ip.palettes(TARGET))
    for name, _label, desc, w in pals:
        slot = have.get(name.upper())
        state = ("new" if slot is None else
                 "current" if slot == w else "DRIFTED")
        print("  %-10s %-52s %2d entries  %s" % (name, desc, len(w), state))
        if show_rgb:
            for i in range(0, len(w), 8):
                print("       %2d  %s"
                      % (i, " ".join(N64.rgb(c << 1) for c in w[i:i + 8])))
    hi = {}
    try:
        _h, images, _p, _f = read_lib(TARGET)
        hi = {ip.cstr(r[0]).upper(): (r, px) for r, px in images}
    except Exception:
        pass
    print()
    for name, desc, w, h, ax, ay, px, palname in stances:
        slot = hi.get(name.upper())
        state = ("new" if slot is None else
                 "current" if slot[1] == px and slot[0][4] == w
                 and slot[0][5] == h else "DRIFTED")
        print("  %-11s %-34s anchor %3d,%-4d under %-10s %s"
              % (name, desc, ax, ay, palname, state))


def apply_or_check(pals, stances, check: bool) -> int:
    hdr, images, lib, img_first = read_lib(TARGET)
    have = {ip.cstr(r[0]).upper(): i for i, (r, _w) in enumerate(lib)}
    bad, changed = 0, []

    for name, _label, _desc, w in pals:
        i = have.get(name.upper())
        if i is None:
            if check:
                print("MISSING %s: %s carries no such palette" % (name, TARGET.name))
                bad += 1
                continue
            lib.append((pal_record(name, w), w))
            have[name.upper()] = len(lib) - 1
            changed.append("+" + name)
        elif lib[i][1] != w:
            if check:
                print("DRIFT   %s: %s has %d entries, Trilogy's source has %d"
                      % (name, TARGET.name, len(lib[i][1]), len(w)))
                bad += 1
                continue
            lib[i] = (pal_record(name, w), w)
            changed.append("~" + name)

    # palnum is resolved HERE, against the palette list as it now stands, so a
    # palette added or reordered above cannot leave an image pointing at the
    # wrong one.  It is 3-BASED: the header counts NUMDEFPAL phantom palettes
    # that are not in the file.
    palnum = {ip.cstr(r[0]).upper(): i + NUMDEFPAL
              for i, (r, _w) in enumerate(lib)}
    hi = {ip.cstr(r[0]).upper(): i for i, (r, _px) in enumerate(images)}
    for name, _desc, w, h, ax, ay, px, palname in stances:
        pn = palnum.get(palname.upper())
        if pn is None:
            print("!! %s: palette %s is not in %s" % (name, palname, TARGET.name))
            bad += 1
            continue
        rec = img_record(name, w, h, ax, ay, pn)
        i = hi.get(name.upper())
        if i is None:
            if check:
                print("MISSING %s: %s carries no such image" % (name, TARGET.name))
                bad += 1
                continue
            images.append((rec, px))
            hi[name.upper()] = len(images) - 1
            changed.append("+" + name)
        elif images[i][1] != px or images[i][0][2:7] != rec[2:7]:
            if check:
                print("DRIFT   %s: %s has %dx%d/pal %d, Trilogy's source has "
                      "%dx%d/pal %d" % (name, TARGET.name, images[i][0][4],
                                        images[i][0][5], images[i][0][6],
                                        w, h, pn))
                bad += 1
                continue
            images[i] = (rec, px)
            changed.append("~" + name)

    if check:
        print("%s: %d Trilogy palettes, %d stance images checked"
              % (TARGET.name, len(pals), len(stances)))
        return bad

    blob = write_lib(hdr, images, lib, img_first)
    if blob != TARGET.read_bytes():
        TARGET.write_bytes(blob)
        print("%s: now %d palettes, %d images, %d bytes  (%s)"
              % (TARGET.name, len(lib), len(images), len(blob),
                 " ".join(changed) or "offsets only"))
    else:
        print("%s: already current" % TARGET.name)
    return 0


def write_pngs(pals, stances) -> None:
    from PIL import Image
    PNGDIR.mkdir(parents=True, exist_ok=True)
    byname = {n: w for n, _l, _d, w in pals}
    tiles = []
    for name, _desc, w, h, _ax, _ay, px, palname in stances:
        cols = byname[palname]
        # px is the ON-DISK form: rows padded to a multiple of 4 PIXELS.  The
        # pad is real bytes, so it has to come off again before PIL is handed
        # w*h entries.
        stride = (w + 3) & ~3
        flat = b"".join(px[y * stride:y * stride + w] for y in range(h))
        im = Image.new("RGBA", (w, h))
        im.putdata([(0, 0, 0, 0) if i == 0 else N64.rgb(cols[i] << 1) + (255,)
                    for i in flat])
        bg = Image.new("RGBA", im.size, (40, 40, 60, 255))
        bg.alpha_composite(im)
        bg.resize((w * 3, h * 3), Image.NEAREST).save(PNGDIR / (name + ".png"))
        tiles.append(im)
    cw = max(t.width for t in tiles) + 8
    ch = max(t.height for t in tiles) + 4
    sheet = Image.new("RGBA", (cw * len(tiles), ch), (40, 40, 60, 255))
    for k, t in enumerate(tiles):
        sheet.alpha_composite(t, (k * cw + (cw - t.width) // 2, 2))
    sheet.resize((sheet.width * 3, sheet.height * 3),
                 Image.NEAREST).save(PNGDIR / "costumes.png")
    # every palette as a swatch strip, for the thirteen with no sprite
    for name, _l, _d, cols in pals:
        sw = Image.new("RGB", (len(cols), 1))
        sw.putdata([N64.rgb(c << 1) for c in cols])
        sw.resize((len(cols) * 12, 24), Image.NEAREST).save(
            PNGDIR / ("swatch_" + name + ".png"))
    print("previews in", PNGDIR)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="import MK Trilogy's Rain and Khameleon palettes into "
                    "data/KATPAL.IMG")
    ap.add_argument("--apply", action="store_true", help="write them into the IMG")
    ap.add_argument("--check", action="store_true",
                    help="fail if any of them is missing or has drifted")
    ap.add_argument("--rgb", action="store_true", help="print the colours too")
    ap.add_argument("--png", action="store_true", help="stance + swatch previews")
    a = ap.parse_args()

    if not IMGPAL.exists():
        if a.check:
            print("TRILOGY RK: Trilogy source not present - skipping check")
            return 0
        print("!! Trilogy source not found: %s" % TRIL)
        return 1
    if not TARGET.exists():
        print("!! %s does not exist" % TARGET)
        return 1

    pals, stances = collect()
    if a.apply or a.check:
        rc = 1 if apply_or_check(pals, stances, a.check) else 0
        if a.png:
            write_pngs(pals, stances)
        return rc

    print("=== MK Trilogy: Rain + Khameleon (%s) -> %s" % (TRIL.name, TARGET.name))
    report(pals, stances, a.rgb)
    twins = sum(1 for p in PALETTES if p[5]) + sum(1 for p in VS_PALETTES if p[3])
    unship = sum(1 for p in PALETTES if p[2]) + sum(1 for p in VS_PALETTES if not p[3])
    print("\n%d palettes: %d fighting (32-colour - the only version Midway made "
          "of either fighter) and %d VS-portrait (64-colour).\n%d have a second "
          "copy in the artist's .RGB; %d are in no shipped table.  %d stance "
          "images.\nRun with --apply to write them."
          % (len(pals), len(PALETTES), len(VS_PALETTES), twins, unship,
             len(stances)))
    if a.png:
        write_pngs(pals, stances)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
