#!/usr/bin/env python3
r"""Bake Johnny Cage's OTOMIX logo into his art on PALETTE SLOTS of its own, so
it can be hidden by writing the pants colour into those slots instead of by
leaving a subframe out of the queue.

This is the alternative to the subframe cut that ships (tools/make_cage_logo.py,
doc/CAGE_OTOMIX_LOGO.md).  The two are mutually exclusive ART STATES and both are
reversible, because neither destroys a source:

    retail art        git at ORIG_REV (data/CAGE*.IMG are skip-worktree)
    the lettering     data/JCLOGO.IMG, which this tool only READS

    make_cage_logo.py --apply      -> the cut state (pieces + frame lists)
    make_cage_logo_pal.py --apply  -> the palette state (baked in, no pieces)

What --apply does, per layout (CAGE_P's index map, and the bloodied JCBLUD one):

  1. frees N slots by merging colour pairs that are near-identical in EVERY
     palette Cage can wear, repainting the dropped index out of his art;
  2. quantises every logo colour onto those slots - the halo shades too, since a
     pixel 3 steps off the pants still reads as a ghost of the lettering;
  3. writes the logo into the pieces on those slots, and the slot's colour into
     each palette, taken from that palette's own copy of the representative
     colour - so the freeze and shock palettes follow with no second table;
  4. drops <PIECE>L from the frame lists;
  5. writes src/JCPALEQ.ASM: the slots, what each one is HIDDEN as, and the
     palettes that count as Cage's - the runtime's whole contract.

Hiding is per slot, not one flat colour: most of the lettering sits on the pants,
but on JCSPLITLEG3B it sits on his white shoe, so that group hides as the shoe.

    python tools/make_cage_logo_pal.py --apply     # bake it
    python tools/make_cage_logo_pal.py --check     # Phase D
    python tools/make_cage_logo_pal.py --slots 8   # slots per layout
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import cage_logo_scan as scan                         # noqa: E402
import make_cage_logo as cut                          # noqa: E402
from img_subframe_audit import live_lods, collect     # noqa: E402

EQU = ROOT / "src" / "JCPALEQ.ASM"
PLAN = ROOT / "tools" / "cage_logo_pal_plan.json"   # the bake rewrites the palettes it
                                                    # plans from, so the plan is SAVED,
                                                    # never re-derived from the output
PANTS = {"cage": 0x3F, "blud": 0x32}
DEFAULT_SLOTS = 8
PAL_FILES = {}          # palette label -> (file, layout), filled from scan.ROM_PALETTES


def dist(pal, a, b):
    return max(abs(x - y) for x, y in zip(scan.rgb5(pal[a]), scan.rgb5(pal[b])))


# ---------------------------------------------------------------- the art

def painted_art():
    """Every live Cage piece as it is DRAWN today: Midway's pixels with this
    project's lettering composed back on, plus where each logo pixel sits."""
    used, _o, _p = collect(live_lods())
    patches = cut.read_patches()
    if not patches:
        sys.exit("data/JCLOGO.IMG is missing - the lettering lives there; "
                 "run tools/make_cage_logo.py --apply first")
    pieces = []
    for img in sorted(used):
        path = ROOT / "data" / f"{img}.IMG"
        if img == "JCLOGO" or not path.exists():
            continue
        data = path.read_bytes()
        try:
            recs, pals = cut.parse_img(data)
        except Exception:
            continue
        try:
            retail = cut.parse_img(cut.git_blob(f"data/{img}.IMG"))[0]
        except Exception:
            retail = {}
        for name in sorted(used[img]):
            r = recs.get(name)
            pal = pals.get(r["palnum"]) if r else None
            if not pal or pal["name"] not in scan.LAYOUT_OF_IMG_PAL:
                continue
            lay = scan.LAYOUT_OF_IMG_PAL[pal["name"]]
            pat = patches.get(name)
            # MIDWAY'S PIXELS, out of git - never data/, which --apply rewrites.
            # Reading the baked art back would make the plan depend on its own
            # output, and --check then disagrees with the bake it just made.
            o = retail.get(name)
            if o and (o["w"], o["h"], o["ax"], o["ay"]) != (r["w"], r["h"], r["ax"], r["ay"]):
                o = None
            if pat and not o:
                continue        # added in this project: no retail to hide back to,
                                # so it keeps its logo PIECE and the cut's skip
            base = o["px"] if o else r["px"]
            logo = {}
            if pat:
                ox, oy = r["ax"] - pat["ax"], r["ay"] - pat["ay"]
                for cy in range(pat["h"]):
                    for cx in range(pat["w"]):
                        v = pat["px"][cy][cx]
                        if v:
                            logo[(ox + cx, oy + cy)] = (v, base[oy + cy][ox + cx])
            pieces.append(dict(img=img, name=name, rec=r, base=base, logo=logo, layout=lay))
    return pieces


def plan(pieces, rom, nslots):
    """Per layout: the merges, the slots, and what every logo colour becomes."""
    use, seen, backing = {}, {}, {}
    for lay in rom:
        use[lay], seen[lay], backing[lay] = Counter(), Counter(), Counter()
    for p in pieces:
        lay = p["layout"]
        for row in p["base"]:                   # Midway's art, without the lettering
            use[lay].update(row)
        for (v, under) in p["logo"].values():
            seen[lay][v] += 1
            backing[lay][(v, under)] += 1
    out = {}
    for lay, pals in rom.items():
        pal = pals["CAGE_P" if lay == "cage" else "JCBLUD1_P"]
        pants = PANTS[lay]
        on_pants = Counter()
        off_pants = Counter()
        for (v, under), n in backing[lay].items():
            (on_pants if under == pants else off_pants)[v] += n
        # main slots: the lettering over the pants, quantised
        reps = [v for v, _n in on_pants.most_common(nslots)]
        groups = [dict(rep=r, hide=pants) for r in reps]
        # one more for lettering that sits on something else (the shoe on
        # JCSPLITLEG3B): hiding it as pants would punch a hole in the shoe
        if off_pants:
            under_common = Counter()
            for (v, under), n in backing[lay].items():
                if under != pants:
                    under_common[under] += n
            groups.append(dict(rep=off_pants.most_common(1)[0][0],
                               hide=under_common.most_common(1)[0][0]))
        merges = scan.merge_plan(lay, len(groups), pals, use[lay])
        if len(merges) < len(groups):
            sys.exit(f"{lay}: only {len(merges)} slots could be freed for {len(groups)} groups")
        for g, (_keep, drop, _w, _m) in zip(groups, merges):
            g["slot"] = drop
        # every logo colour -> a group: on the pants by colour, off it by backing
        qerr = Counter()
        mapping = {}
        for (v, under), n in backing[lay].items():
            if under != pants and off_pants:
                g = groups[-1]
            else:
                g = min(groups[:len(reps)], key=lambda g: dist(pal, v, g["rep"]))
            mapping[(v, under)] = g["slot"]
            qerr[dist(pal, v, g["rep"])] += n
        out[lay] = dict(groups=groups, merge={d: k for k, d, _w, _m in merges},
                        mapping=mapping, qerr=qerr, plan=merges, use=use[lay],
                        seen=seen[lay])
    return out


def bake_pixels(pieces, plans):
    """The art as the palette method needs it: merges applied, lettering on slots."""
    for p in pieces:
        P = plans[p["layout"]]
        px = [[P["merge"].get(v, v) for v in row] for row in p["base"]]
        for (x, y), (v, under) in p["logo"].items():
            px[y][x] = P["mapping"][(v, under)]
        p["baked"] = px


# ---------------------------------------------------------------- writing

def write_imgs(pieces, apply):
    """Back into each piece's own IMG, same offsets - geometry never changes."""
    bad = []
    by_img = {}
    for p in pieces:
        by_img.setdefault(p["img"], []).append(p)
    for img, ps in sorted(by_img.items()):
        path = ROOT / "data" / f"{img}.IMG"
        data = bytearray(path.read_bytes())
        for p in ps:
            r = p["rec"]
            for y, row in enumerate(p["baked"]):
                o = r["off"] + y * r["stride"]
                data[o:o + r["w"]] = bytes(row)
        if bytes(data) == path.read_bytes():
            continue
        if apply:
            path.write_bytes(bytes(data))
            print(f"  wrote data/{img}.IMG")
        else:
            bad.append(f"data/{img}.IMG is not the palette bake")
    return bad


def palette_words(lines, label):
    """(first line, last line, [count, colours...]) of a palette's block.

    The block is the run of `.word` lines straight after the label - the count
    word and then the colours.  Walked line by line rather than by regex over the
    rest of the file, which ran on into the NEXT palette."""
    for i, ln in enumerate(lines):
        if re.match(rf"^{re.escape(label)}:?[ \t]*(;.*)?$", ln.rstrip("\r")):
            break
    else:
        return None
    words, first, last = [], None, None
    for j in range(i + 1, len(lines)):
        m = re.match(r"^[ \t]*\.word[ \t]+(.*?)[ \t]*(;.*)?$", lines[j].rstrip("\r"))
        if not m:
            break
        if first is None:
            first = j
        last = j
        for tok in m.group(1).split(","):
            tok = tok.strip()
            words.append(int(tok[:-1], 16) if tok.lower().endswith("h") else int(tok, 0))
    return first, last, words


def write_palettes(plans, rom, apply):
    """slot <- the palette's own copy of the group's representative colour."""
    bad = []
    edits = {}
    for lay, pals in scan.ROM_PALETTES.items():
        for asm, label in pals:
            path = ROOT / "src" / asm
            raw = edits.get(asm) or path.read_bytes().decode("latin-1")
            crlf = "\r\n" in raw
            lines = raw.replace("\r\n", "\n").split("\n")
            found = palette_words(lines, label)
            if not found:
                sys.exit(f"src/{asm}: no palette {label}")
            first, last, words = found
            if len(words) != 65:
                sys.exit(f"src/{asm}: {label} has {len(words)} words, expected 65")
            want = list(words)
            for g in plans[lay]["groups"]:
                want[g["slot"] + 1] = words[g["rep"] + 1]      # +1: the count word
            # a rep is never a slot, so words[rep] is untouched by an earlier bake
            if want == words:
                continue
            body = [f"\t.word\t{want[0]:5d}"] + \
                   ["\t.word\t" + ",".join(f"0{w:04X}h" for w in want[1 + i:1 + i + 8])
                    for i in range(0, 64, 8)]
            lines[first:last + 1] = body
            text = "\n".join(lines)
            edits[asm] = text.replace("\n", "\r\n") if crlf else text
            if not apply:
                bad.append(f"src/{asm}: {label} does not carry the logo's slot colours")
    if apply:
        for asm, text in edits.items():
            (ROOT / "src" / asm).write_bytes(text.encode("latin-1"))
            print(f"  wrote src/{asm}")
    return bad


def equates(plans):
    out = ["* JCPALEQ.ASM - GENERATED by tools/make_cage_logo_pal.py.  Do not edit.",
           "*",
           "* Johnny Cage's OTOMIX logo lives on palette slots of its own.  While he is",
           "* drawn mirrored the lettering reads backwards, so those slots are re-pointed",
           "* at what the logo covers - the pants, or his shoe where it crosses one - in a",
           "* copy of his colour map (cagepal, MKDISP.ASM).  A pair is [slot, hidden as].",
           ""]
    for lay in ("cage", "blud"):
        P = plans[lay]
        out.append(f"cp_{lay}\t\t; count, then [slot, hidden as] pairs")
        out.append(f"\t.word\t{len(P['groups'])}")
        for g in P["groups"]:
            out.append(f"\t.word\t0{g['slot']:03X}h,0{g['hide']:03X}h")
        out.append("")
    out.append("cp_pals\t\t; the palettes that ARE Cage, and which set of slots")
    out.append("\t\t; each one uses.  A zero id ends it.")
    for lay in ("cage", "blud"):
        for _asm, label in scan.ROM_PALETTES[lay]:
            out.append(f"\t.long\t{label},cp_{lay}")
    out.append("\t.long\t0")
    out.append("")
    return "\r\n".join(out)


def write_equates(plans, apply):
    text = equates(plans).encode("ascii")
    if EQU.exists() and EQU.read_bytes() == text:
        return []
    if apply:
        EQU.write_bytes(text)
        print(f"  wrote src/{EQU.name}")
        return []
    return [f"src/{EQU.name} is not the current bake"]


# ---------------------------------------------------------------- report

def report(plans, rom, pieces):
    for lay in ("cage", "blud"):
        P = plans[lay]
        if not P["use"]:
            print(f"[{lay}] {len(P['groups'])} slots: " +
                  ", ".join(f"{g['slot']:#04x} hides as {g['hide']:#04x}" for g in P["groups"]))
            continue
        pal = rom[lay]["CAGE_P" if lay == "cage" else "JCBLUD1_P"]
        tot = sum(P["use"].values())
        moved = sum(P["use"][d] for d in P["merge"])
        seen = sum(P["seen"].values())
        q = P["qerr"]
        shifted = sum(n for d, n in q.items() if d)
        print(f"[{lay}] {len(P['groups'])} slots: " +
              ", ".join(f"{g['slot']:#04x} hides as {g['hide']:#04x}" for g in P["groups"]))
        print(f"   merges repaint {moved} of {tot} px ({100 * moved / tot:.1f}%), "
              f"worst {max(w for _k, _d, w, _m in P['plan'])} step(s) of 31")
        print(f"   {seen} logo px on slots; {shifted} ({100 * shifted / seen:.0f}%) shifted by "
              f"quantising, worst {max(q)}, mean {sum(d * n for d, n in q.items()) / seen:.2f}")


def save_plan(plans, rom):
    """The plan, plus the palette words it replaced - so --apply is idempotent and
    the palettes can be put back."""
    out = {}
    for lay, P in plans.items():
        out[lay] = dict(
            groups=[{k: g[k] for k in ("slot", "rep", "hide")} for g in P["groups"]],
            merge={str(d): k for d, k in P["merge"].items()},
            mapping={f"{v},{u}": s for (v, u), s in P["mapping"].items()},
            was={lab: [pal[g["slot"] + 1] for g in P["groups"]]
                 for lab, pal in rom[lay].items()})
    PLAN.write_text(json.dumps(out, indent=1, sort_keys=True))


def load_plan():
    if not PLAN.exists():
        return None
    raw = json.loads(PLAN.read_text())
    out = {}
    for lay, P in raw.items():
        out[lay] = dict(
            groups=P["groups"],
            merge={int(d): k for d, k in P["merge"].items()},
            mapping={(int(k.split(",")[0]), int(k.split(",")[1])): s
                     for k, s in P["mapping"].items()},
            was=P["was"], qerr=Counter(), plan=[], use=Counter(), seen=Counter())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apply", action="store_true")
    g.add_argument("--check", action="store_true")
    ap.add_argument("--slots", type=int, default=DEFAULT_SLOTS)
    ap.add_argument("--replan", action="store_true",
                    help="work the plan out again (needs UNBAKED palettes)")
    a = ap.parse_args()

    rom = {lay: {lab: scan.rom_palette(asm, lab) for asm, lab in lst}
           for lay, lst in scan.ROM_PALETTES.items()}
    pieces = painted_art()
    plans = None if a.replan else load_plan()
    fresh = plans is None
    if fresh:
        plans = plan(pieces, rom, a.slots)
        if a.check:
            print("CAGE LOGO PAL: no plan in tools/cage_logo_pal_plan.json - not baked")
            return 1
        save_plan(plans, rom)
        print(f"  wrote {PLAN.relative_to(ROOT)}")
    bake_pixels(pieces, plans)
    print(f"cage logo (palette): {len(pieces)} live pieces, "
          f"{sum(len(p['logo']) for p in pieces)} logo pixels")
    report(plans, rom, pieces)

    bad = []
    bad += write_imgs(pieces, a.apply)
    bad += write_palettes(plans, rom, a.apply)
    bad += write_equates(plans, a.apply)
    # the lettering must NOT also be drawn as a piece
    names = {p["name"] for p in pieces if p["logo"]}
    for f in cut.LIST_FILES:
        path = ROOT / "src" / f
        raw = path.read_bytes().decode("latin-1")
        text, n = cut.sync_lists(raw, names, add=False)
        if n:
            if a.apply:
                path.write_bytes(text.encode("latin-1"))
                print(f"  {f}: {n} frame-list lines no longer draw a logo piece")
            else:
                bad.append(f"src/{f}: {n} frame lists still draw the logo as a piece")
    if a.check:
        for b in bad:
            print("CAGE LOGO PAL:", b)
        print("CAGE LOGO PAL OK" if not bad else "")
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
