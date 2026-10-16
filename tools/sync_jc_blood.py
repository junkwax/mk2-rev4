#!/usr/bin/env python3
"""Keep src/JCBLOOD.TBL's JCSTAB/JCSPLAT copies aligned with MKBLOOD.TBL + BLOOD.IMG.

Johnny Cage's headhole (brain-rip) fatality draws its impact wound spray from
JCSTAB1..9 and JCSPLAT1..7 (jc_headhole_stab_proc / _splat_proc, MKDEATH.ASM).
They are hand-made copies of BLOOD.IMG's STAB1..9 / SPLAT1..7: same art, but
carrying the anipoints authored in the IMG, while MKBLOOD.TBL's STAB/SPLAT keep
stock retail anipoints for the ordinary hit blood (a_stab, a_splat).

No LOD emits JCBLOOD.TBL and no promoter touches it, so when LOAD2 repacks the
blood art its SAGs silently rot.  They did: after STAB1 moved to 040aeb2dH all
sixteen kept pointing 8559 bits early, into FATALOOP13 / SPURT1 / the previous
STAB frame, and the fatality's spray drew as torn garbage.

Contract, per JC record:
  SAG, control word, W,H  <- the same-numbered record in src/MKBLOOD.TBL
                             (promoted from LOAD2, so it tracks every repack)
  anix, aniy              <- the same-numbered record in data/BLOOD.IMG
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
import img_anipoint  # noqa: E402

PAIRS = [(f"JCSTAB{n}", f"STAB{n}") for n in range(1, 10)] + \
        [(f"JCSPLAT{n}", f"SPLAT{n}") for n in range(1, 8)]

LABEL_RE = re.compile(r"^([A-Za-z_]\w*):\s*$")
GEOM_RE = re.compile(r"^(\s*\.word\s+)(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)(\s*(?:;.*)?)$", re.I)
HEX_RE = re.compile(r"^(\s*\.(?:long|word)\s+)(0?[0-9A-Fa-f]+)([Hh])(\s*(?:;.*)?)$")


def read_records(lines):
    """label -> {'geom': ((w,h,x,y), idx), 'sag': (v, idx), 'ctrl': (v, idx)}"""
    out = {}
    for i, line in enumerate(lines):
        m = LABEL_RE.match(line.rstrip("\r\n"))
        if not m or i + 3 >= len(lines):
            continue
        g = GEOM_RE.match(lines[i + 1].rstrip("\r\n"))
        s = HEX_RE.match(lines[i + 2].rstrip("\r\n"))
        c = HEX_RE.match(lines[i + 3].rstrip("\r\n"))
        if g and s and c and ".long" in lines[i + 2] and ".word" in lines[i + 3]:
            out[m.group(1)] = {
                "geom": (tuple(int(g.group(k)) for k in range(2, 6)), i + 1),
                "sag": (int(s.group(2), 16), i + 2),
                "ctrl": (int(c.group(2), 16), i + 3),
            }
    return out


def eol(line):
    return "\r\n" if line.endswith("\r\n") else "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="report drift, write nothing, exit 1 if stale")
    args = ap.parse_args()

    jc_path = REPO / "src" / "JCBLOOD.TBL"
    stock_path = REPO / "src" / "MKBLOOD.TBL"
    img_path = REPO / "data" / "BLOOD.IMG"

    jc_lines = jc_path.read_text(encoding="latin-1").splitlines(keepends=True)
    jc = read_records(jc_lines)
    stock = read_records(stock_path.read_text(encoding="latin-1").splitlines(keepends=True))
    img = {name: (w, h, ax, ay) for _, name, _, ax, ay, w, h in img_anipoint.records(img_path.read_bytes())}

    problems, fatal = [], []
    for jc_name, src_name in PAIRS:
        if jc_name not in jc:
            fatal.append(f"{jc_name} missing from src/JCBLOOD.TBL")
            continue
        if src_name not in stock:
            fatal.append(f"{src_name} missing from src/MKBLOOD.TBL")
            continue
        if src_name not in img:
            fatal.append(f"{src_name} missing from data/BLOOD.IMG")
            continue
        sw, sh = stock[src_name]["geom"][0][:2]
        iw, ih, ax, ay = img[src_name]
        if (sw, sh) != (iw, ih):
            fatal.append(f"{src_name}: MKBLOOD.TBL says {sw}x{sh} but BLOOD.IMG says {iw}x{ih} "
                         f"- promote the art before syncing the copy")
            continue

        rec = jc[jc_name]
        want_geom = (sw, sh, ax, ay)
        want_sag = stock[src_name]["sag"][0]
        want_ctrl = stock[src_name]["ctrl"][0]
        if rec["geom"][0] != want_geom:
            problems.append((jc_name, "geom", rec["geom"], want_geom))
        if rec["sag"][0] != want_sag:
            problems.append((jc_name, "sag", rec["sag"], want_sag))
        if rec["ctrl"][0] != want_ctrl:
            problems.append((jc_name, "ctrl", rec["ctrl"], want_ctrl))

    for msg in fatal:
        print(f"ERROR: {msg}")
    if fatal:
        return 2

    if not problems:
        print(f"JCBLOOD.TBL aligned: {len(PAIRS)} JCSTAB/JCSPLAT records match MKBLOOD.TBL + BLOOD.IMG")
        return 0

    for name, field, (have, _), want in problems:
        if field == "geom":
            print(f"JCBLOOD.TBL {name} geom stale: {have} -> {want}")
        elif field == "sag":
            print(f"JCBLOOD.TBL {name} SAG stale: 0{have:07x}H -> 0{want:07x}H ({want - have:+d} bits)")
        else:
            print(f"JCBLOOD.TBL {name} ctrl stale: 0{have:04x}H -> 0{want:04x}H")
    if args.check:
        return 1

    for _name, field, (_have, idx), want in problems:
        line = jc_lines[idx]
        if field == "geom":
            m = GEOM_RE.match(line.rstrip("\r\n"))
            jc_lines[idx] = f"{m.group(1)}{want[0]},{want[1]},{want[2]},{want[3]}{m.group(6)}{eol(line)}"
        else:
            m = HEX_RE.match(line.rstrip("\r\n"))
            width = len(m.group(2))
            jc_lines[idx] = f"{m.group(1)}{want:0{width}x}{m.group(3)}{m.group(4)}{eol(line)}"
    jc_path.write_text("".join(jc_lines), encoding="latin-1")
    print(f"Updated src/JCBLOOD.TBL ({len(problems)} field(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
