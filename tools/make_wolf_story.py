#!/usr/bin/env python3
"""
THE ATTRACT STORY + CHARACTER-PROFILE BACKGROUNDS, WOLF ONLY.

Midway's attract mode opened on four story screens (`the_story`,
MKAMODE.ASM - Shang Tsung, Liu Kang, Kintaro, Shao Kahn) and showed a
character profile before every demo fight (`show_next_bio`, whose fighter
then plays the demo as player 1).  The T-unit build retired the five
backgrounds those screens sit on - ATRAX1-4 (`atrax1_mod`..`atrax4_mod`) and
STORY1 (`bio_mod`) - out of data/MK7MIL.LOD for space
(doc/RETIRED_BGND_RECLAIM.md), so their header tables in src/BGNDTBL.ASM now
point at whatever moved into those addresses.

The Wolf board has the room.  data/WSTORY.LOD packs the five BDBs above the
T-unit's 12 MB (Wolf linear 0xF80000), IMGBUILD.BAT snapshots LOAD2's tables
as tmp/load2/BGNDTBL.WST / BGNDPAL.WST, and this tool writes src/WSTORY.ASM:
the five records renamed W* (headers with the Wolf SAGs, blocks, modules)
and five Wolf copies of the stage modules, `wstory_mods`, which
one_story_screen (MKAMODE.ASM) uses in place of table_o_mods 0Eh-11h / 14h
under `.if wunit`.  The whole file assembles to nothing on a T-unit build.

The palettes are NOT copied: src/BGNDPAL.ASM still carries X1PALS..Y1PALS
and their colours, and --apply/--check fail if LOAD2's palettes ever stop
matching them word for word.

  --apply   write src/WSTORY.ASM from the snapshots
  --check   fail if src/WSTORY.ASM, or the palette match, has drifted
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOAD2 = ROOT / "tmp" / "load2"
SNAP_TBL = LOAD2 / "BGNDTBL.WST"
SNAP_PAL = LOAD2 / "BGNDPAL.WST"
OUT = ROOT / "src" / "WSTORY.ASM"
SRC_PAL = ROOT / "src" / "BGNDPAL.ASM"
LOD = ROOT / "data" / "WSTORY.LOD"

# (stage module in BGND.ASM, table_o_mods index, BMOD, HDRS, BLKS, PALS)
# The module words are BGND.ASM's own atrax1_mod..atrax4_mod / bio_mod /
# end_h_mod / end_v_mod.
STAGES = [
    ("wstory1_mod", 0x0E, "ATRXMOD1", "X1", 0x02E, 0x010),
    ("wstory2_mod", 0x0F, "ATRXMOD2", "X2", 0x02E, 0x010),
    ("wstory3_mod", 0x10, "ATRXMOD3", "X3", 0x02E, 0x010),
    ("wstory4_mod", 0x11, "ATRXMOD4", "X4", 0x02E, 0x010),
    ("wbio_mod",    0x14, "STORYMOD", "Y1", 0x020, 0x013),
    # the ENDING backgrounds (show_a0_ending, UNZIP.ASM): BGND.ASM's end_h_mod /
    # end_v_mod, MKSTORY1.BDB's STORY1 module and MKSTORY2.BDB's STORY2
    ("wendh_mod",   0x12, "STORY1",   "ORY1", 0x022, 0x028),
    ("wendv_mod",   0x13, "STORY2",   "ORY2", 0x029, 0x012),
]

LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")

# THE BLACK STRIP DOWN THE RIGHT EDGE.  The four story layouts stop their
# right-hand column of stone tiles at world x 365 (a 52x50 tile, header 0,
# palette 1), which ends at screen x 392 - so screen x 393-399 was black from
# the top down to the text-box row (y 188), where the bottom row (x 396)
# carries on.  Retail shipped it that way.  One more column fills it, 50 px
# over (the tiles' own step: 52 wide, 2 px overlap), rows 35..185 as the 365
# column.
#
# IT IS NOT PART OF THE STAGE MODULE, AND THAT IS LOAD-BEARING.  Appended to
# the stock block lists, the column pushed ATRAX3 (story screen 3) over the
# frame's DMA budget: each tile is blitted at its full 52 px although only 7
# show, the last four frames before display_off started with blits pending
# (dmaq_late 0 -> 4), and what the display abandons is the TAIL of the queue -
# the text panel (z 40h, last on baklst1) - so screen 1's text showed through
# screen 3's panel.  So the column is its own tiny module per screen
# (wstory_edges), drawn by wstory_edge_pass (MKAMODE.ASM) in a SECOND pass
# after the screen is done, the way try_another_line adds text: auto-erase is
# off, so the page keeps its pixels and four tiles land on top in 2 frames.
EDGE_X = 415
EDGE_ROWS = (35, 85, 135, 185)
EDGE_TILE = (52, 50)            # header 0 of every ATRAX layout
EDGE_FLAGS = 0x3241             # the stock stone tiles' flags
EDGE_STAGES = ("ATRXMOD1", "ATRXMOD2", "ATRXMOD3", "ATRXMOD4")


def records(path):
    """label -> list of body lines (raw), in file order."""
    out, cur = {}, None
    for line in path.read_text(errors="replace").splitlines():
        m = LABEL_RE.match(line)
        if m:
            cur = m.group(1)
            out[cur] = []
            continue
        if cur is not None and line.strip():
            out[cur].append(line.rstrip())
    return out


def body(lines):
    return [l.split(";")[0].strip() for l in lines if l.split(";")[0].strip()]


# MKSTORY2 (the vertical ending's background) is Midway's DEV art as the leak
# has it: its BDD carries BOX2, STONE2 and its own BOOM15, while RETAIL'S
# ORY2PALS in src/BGNDPAL.ASM points at BOX1 / STONE3 and a different BOOM15 -
# the shipped palettes were edited after the BDD was saved.  The pixels are
# retail's (this tree's video ROM matched retail byte for byte while MK7MIL
# still packed MKSTORY2), and the W* modules reference BGNDPAL.ASM's palettes
# by label, so the ending draws in retail's colours; LOAD2's own copies of
# these four are simply not used.
RETAIL_PALS_WIN = {"ORY2PALS", "BOX2", "STONE2", "BOOM15"}


def check_palettes():
    """Every palette (and PALS list) LOAD2 wrote must be in src/BGNDPAL.ASM, word for word."""
    snap, src = records(SNAP_PAL), records(SRC_PAL)
    bad = []
    for label, lines in snap.items():
        if label in RETAIL_PALS_WIN:
            continue
        want = body(lines)
        have = body(src.get(label, []))[:len(want)]
        if have != want:
            bad.append(label if label in src else f"{label} (missing)")
    return bad


def build():
    tbl = records(SNAP_TBL)
    w = []
    a = w.append
    a("**************************************************************************")
    a("*  GENERATED by tools/make_wolf_story.py --apply - do not edit by hand.  *")
    a("*                                                                        *")
    a("*  The attract story backgrounds (ATRAX1-4) and the character-profile    *")
    a("*  background (STORY1), WOLF ONLY: packed by data/WSTORY.LOD above the   *")
    a("*  T-unit's 12 MB.  The T-unit retired them out of MK7MIL.LOD, so the    *")
    a("*  stock records in BGNDTBL.ASM point at other art; these W* copies     *")
    a("*  carry the Wolf SAGs.  one_story_screen (MKAMODE.ASM) takes            *")
    a("*  wstory_mods in place of table_o_mods 0Eh-14h under .if wunit.       *")
    a("*  MKSTORY1/2 are the ending backgrounds (show_a0_ending, UNZIP.ASM).    *")
    a("**************************************************************************")
    a('\t.file\t"wstory.asm"')
    a("\t.width\t132")
    a("\t.option\tb,d,l,t")
    a("\t.mnolist")
    a("")
    a("\t.include\tdispequ.asm")
    a("\t.include\tsysequ.asm")
    a("\t.include\tmacros.hdr")
    a("\t.include\tmainequ.asm")
    a("")
    a("\t.if\twunit")
    a("\t.globl\twstory_mods,wstory_edges")
    a("\t.ref\t" + ",".join(f"{p}PALS" for _m, _i, _b, p, _y, _x in STAGES))
    a("")
    a("\t.text")
    a("wst_return")
    a("\trets")
    a("")
    a("\t.data")
    a("")
    a("* which table_o_mods entry each Wolf module stands in for - read by")
    a("* one_story_screen (MKAMODE.ASM): .word index, .long module")
    a("wstory_mods")
    for mod, idx, *_ in STAGES:
        a(f"\t.word\t0{idx:02X}h")
        a(f"\t.long\t{mod}")
    a("\t.word\t-1")
    a("")
    a("* BGND.ASM's no_scroll (local there): nothing on these screens moves")
    a("wst_no_scroll")
    for _ in range(9):
        a("\t.long\t0")
    a("")
    for mod, idx, bmod, pfx, wy, wx in STAGES:
        a(f"{mod}")
        a("\t.word\t0\t\t\t; autoerase color")
        a("\t.word\t000h\t\t\t; ground y")
        a(f"\t.word\t0{wy:03X}h\t\t\t; initial world y")
        a(f"\t.word\t0{wx:03X}h\t\t\t; initial worldx")
        a("\t.word\t-0500h\t\t\t; scroll left limit")
        a("\t.word\t0500h\t\t\t; scroll right limit")
        a("\t.long\twst_return")
        a("\t.long\twst_no_scroll\t\t; scroll table")
        a("\t.long\tdlists_bogus")
        a("\t.long\tbak1mods")
        a(f"\t.long\tW{bmod}BMOD")
        a("\t.word\t-006h,000h")
        a("\t.long\t0ffffffffh")
        a("")
    for mod, idx, bmod, pfx, wy, wx in STAGES:
        hdrs, blks, bm = f"{pfx}HDRS", f"{bmod}BLKS", f"{bmod}BMOD"
        for lab in (hdrs, blks, bm):
            if lab not in tbl:
                raise SystemExit(f"make_wolf_story: {lab} is not in {SNAP_TBL}")
        a(f"W{hdrs}:")
        w.extend(tbl[hdrs])
        a(f"W{blks}:")
        blines = list(tbl[blks])
        w.extend(blines)
        a(f"W{bm}:")
        bml = list(tbl[bm])
        want = f"{blks}, {hdrs}, {pfx}PALS"
        if not any(want in l for l in bml):
            raise SystemExit(f"make_wolf_story: {bm} does not read '{want}'")
        w.extend(l.replace(want, f"W{blks}, W{hdrs}, {pfx}PALS") for l in bml)
        a("")
    # the right-edge column, one module per story screen (see EDGE_X)
    a("* the right-edge stone column per story screen - read by wstory_edge_pass")
    a("* (MKAMODE.ASM): .long the screen's block module (what init_bakmods left in")
    a("* bak1mods), .long its edge module, ..., .long 0.  Keyed on the BMOD, not")
    a("* the table_o_mods index: lm_printf reuses the process's p_store words")
    a("wstory_edges")
    for mod, idx, bmod, *_ in STAGES:
        if bmod in EDGE_STAGES:
            a(f"\t.long\tW{bmod}BMOD,{mod}_edge")
    a("\t.long\t0")
    a("")
    for mod, idx, bmod, pfx, wy, wx in STAGES:
        if bmod not in EDGE_STAGES:
            continue
        hdrs = f"{pfx}HDRS"
        first = body(tbl[hdrs])[0]
        if tuple(int(v) for v in first.split(None, 1)[1].split(",")) != EDGE_TILE:
            raise SystemExit(f"make_wolf_story: {hdrs}[0] is not the {EDGE_TILE} stone tile ({first})")
        stock = [l.replace(" ", "").replace("\t", "") for l in body(tbl[f"{bmod}BLKS"])]
        if f".word0{EDGE_FLAGS:04X}H,365,35,00H" not in stock:
            raise SystemExit(f"make_wolf_story: {bmod}BLKS no longer has the stock 365 column this extends")
        a(f"{mod}_edge")
        a("\t.word\t0\t\t\t; autoerase color")
        a("\t.word\t000h\t\t\t; ground y")
        a(f"\t.word\t0{wy:03X}h\t\t\t; initial world y")
        a(f"\t.word\t0{wx:03X}h\t\t\t; initial worldx")
        a("\t.word\t-0500h\t\t\t; scroll left limit")
        a("\t.word\t0500h\t\t\t; scroll right limit")
        a("\t.long\twst_return")
        a("\t.long\twst_no_scroll\t\t; scroll table")
        a("\t.long\tdlists_bogus")
        a("\t.long\tbak1mods")
        a(f"\t.long\tWE{bmod}BMOD")
        a("\t.word\t-006h,000h")
        a("\t.long\t0ffffffffh")
        a(f"WE{bmod}BLKS:")
        for y in EDGE_ROWS:
            a(f"\t.word\t0{EDGE_FLAGS:04X}H,{EDGE_X},{y},00H")
        a("\t.word\t0FFFFH\t;End Marker")
        a(f"WE{bmod}BMOD:")
        a(f"\t.word\t{EDGE_X + EDGE_TILE[0]},349,{len(EDGE_ROWS)}\t;x size, y size, #blocks")
        a(f"\t.long\tWE{bmod}BLKS, W{hdrs}, {pfx}PALS")
        a("")
    a("\t.endif")
    a("")
    return "\n".join(w)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apply", action="store_true")
    g.add_argument("--check", action="store_true")
    args = ap.parse_args()

    for p in (SNAP_TBL, SNAP_PAL, LOD):
        if not p.exists():
            print(f"make_wolf_story: {p} missing (run build.py - IMGBUILD.BAT packs WSTORY)")
            return 1
    bad = check_palettes()
    if bad:
        print("make_wolf_story: LOAD2's palettes for the story backgrounds no longer match "
              "src/BGNDPAL.ASM: " + ", ".join(bad))
        return 1
    text = build()
    if args.apply:
        old = OUT.read_text() if OUT.exists() else None
        if old != text:
            OUT.write_text(text)
            print(f"make_wolf_story: wrote {OUT.relative_to(ROOT)}")
        else:
            print(f"make_wolf_story: {OUT.relative_to(ROOT)} unchanged")
        return 0
    if not OUT.exists() or OUT.read_text() != text:
        print(f"make_wolf_story: {OUT.relative_to(ROOT)} is stale - run tools/make_wolf_story.py --apply")
        return 1
    print(f"make_wolf_story: OK ({len(STAGES)} Wolf story/bio/ending backgrounds, palettes match BGNDPAL.ASM)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
