#!/usr/bin/env python3
"""Generate the victim half of RAIN's lightning fatality from data/RAINSPLIT.WAX.

    python tools/rain_split_wax_import.py           rewrite the generated block
    python tools/rain_split_wax_import.py --check   exit 1 if it is stale

The IMGTOOL project is the source of truth for what the final bolt does to
the man it hits: he comes apart at the waist and the two halves are thrown
and fall.  It has two live (visible) slots on data/NINJAS11.IMG:

    the LEGS   NJDECAPLEG1-7   -> a new object, gmo_proc'd off him
    the TORSO  NJRIPTORSO1-6   -> his own object

It is authored on the ninja, but it plays on EVERY victim in his own art:
each frame is emitted as a PLACEHOLDER, and rnf_build (MKRAINF.ASM) swaps
in that victim's own frame when the fatality runs:

    0100h|n  DECAPLEGn - row 039h (a_torso_ripped) of HIS anitab1, at the
             part/row rnf_legpos gives: the standing legz and the sai
             split's legs-only frames, which every fighter's lane carries
    0200h|n  RIPTORSOn - row 041h (a_swipe_torso), part 1, row n-1

--check also re-reads every fighter module and proves both rows still have
that shape, so a lane edit cannot quietly point the split at the wrong art.

FLIPS AND OFFSETS follow doc/IMGTOOL_LANE_CONVERSION.md sections 4-5 exactly:
frame_mirror is an ABSOLUTE state (bit0 X, bit1 Y) emitted as toggles only
where it changes; local_dx/dy are editor anipoint offsets, per frame
X = fliph ? +dx : -dx and Y = flipv ? +dy : -dy, emitted as cumulative
differences at BASE facing (drop a per-entry X flip before the adjust, put
it back after).

HOLDS are per frame (frame_delays), in a parallel .word list the walker
reads - the templates are ordinary lanes otherwise, so do_next_a9_frame
runs every flip and adjust itself.
"""
import argparse
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "RAINSPLIT.WAX")
ASM = os.path.join(ROOT, "src", "MKRAINF.ASM")
IMG_NAME = "NINJAS11.IMG"

BEGIN = ";>>>WAX BEGIN rainsplit"
END = ";<<<WAX END rainsplit"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# DECAPLEGn -> (part, row) in row 039h, 1-based parts as find_part_a14 counts
# them.  MUST match rnf_legpos in MKRAINF.ASM (the generated block carries
# it, so it cannot drift).
LEGPOS = {1: (6, 0), 2: (7, 0), 3: (7, 1), 4: (8, 0), 5: (9, 1), 6: (9, 2), 7: (9, 3)}
TORSO_ROWS = 6

# every fighter module whose anitab1 rows 039h / 041h a victim can come from
MODULES = ["MKHH", "MKLK", "MKJC", "MKSA", "MKFN", "MKST", "MKRD", "MKNJ", "MKJX"]


def img_names(path):
    b = open(path, "rb").read()
    imgcnt, _, oset = LIB_HDR.unpack_from(b, 0)[:3]
    return [IMAGE.unpack_from(b, oset + i * IMAGE.size)[0].split(b"\0", 1)[0].decode("latin-1")
            for i in range(imgcnt)]


def parse_wax(path):
    kv = {}
    for line in open(path, "r", errors="replace"):
        line = line.rstrip("\r\n")
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def ints(kv, key):
    v = kv.get(key, "")
    return [int(x) for x in v.split(",") if x.strip() != ""] if v else []


def slots(kv, names):
    legs = torso = None
    for n in range(int(kv.get("slot.count", "0"))):
        if kv.get(f"slot.{n}.visible", "0") != "1":
            continue
        seq = ints(kv, f"slot.{n}.sequence_frames")
        if not seq:
            continue
        doc = int(kv.get(f"slot.{n}.doc_idx", "-1"))
        if os.path.basename(kv.get(f"doc.{doc}.path", "")).upper() != IMG_NAME:
            sys.exit(f"slot {n} is visible and draws from {kv.get(f'doc.{doc}.path')!r}, "
                     f"expected {IMG_NAME}")
        labs = [names[f] for f in seq]
        if all(re.fullmatch(r"NJDECAPLEG[1-7]", s) for s in labs):
            if legs is not None:
                sys.exit(f"two visible LEGS slots ({legs}, {n})")
            legs = n
        elif all(re.fullmatch(r"NJRIPTORSO[1-6]", s) for s in labs):
            if torso is not None:
                sys.exit(f"two visible TORSO slots ({torso}, {n})")
            torso = n
        else:
            sys.exit(f"slot {n} mixes frames the split cannot map: {labs}")
    if legs is None or torso is None:
        sys.exit(f"need one visible NJDECAPLEG slot and one NJRIPTORSO slot, got legs={legs} torso={torso}")
    return legs, torso


def lane(kv, names, n, code):
    seq = ints(kv, f"slot.{n}.sequence_frames")
    dly = ints(kv, f"slot.{n}.frame_delays")
    dx = ints(kv, f"slot.{n}.local_dx")
    dy = ints(kv, f"slot.{n}.local_dy")
    mir = ints(kv, f"slot.{n}.frame_mirror")
    out, holds = [], []
    cur_fx = cur_fy = 0
    px = py = 0
    for i, f in enumerate(seq):
        m = mir[i] if i < len(mir) else 0
        fx, fy = m & 1, (m >> 1) & 1
        ldx = dx[i] if i < len(dx) else 0
        ldy = dy[i] if i < len(dy) else 0
        X = ldx if fx else -ldx
        Y = ldy if fy else -ldy
        ddx, ddy = X - px, Y - py
        px, py = X, Y
        if cur_fx:
            out.append("\t.long\tani_flip\t\t; back to base facing for the adjust")
            cur_fx = 0
        if ddx or ddy:
            if not (-32768 <= ddx < 32768 and -32768 <= ddy < 32768):
                sys.exit(f"slot {n} entry {i}: offset out of range")
            out.append("\t.long\tani_adjustxy")
            out.append(f"\t.word\t{ddx},{ddy}")
        if fx:
            out.append("\t.long\tani_flip")
            cur_fx = 1
        if fy != cur_fy:
            out.append("\t.long\tani_flip_v")
            cur_fy = fy
        num = int(re.search(r"(\d+)$", names[f]).group(1))
        out.append(f"\t.long\t0{code + num:04x}h\t\t; {names[f]} - HIS, looked up at run time")
        holds.append(dly[i] if i < len(dly) else 1)
    out.append("\t.long\t0")
    if any(h < 1 for h in holds):
        sys.exit(f"slot {n}: a frame_delay below 1 tick")
    return out, holds


def lane_longs(lines):
    """longs the template occupies - what rnf_build copies into RAM"""
    n = 0
    for s in lines:
        if s.startswith("\t.long"):
            n += 1
        elif s.startswith("\t.word"):
            n += 1                          # two words = one long
    return n


def check_modules():
    """every victim's 039h / 041h lane still has the shape rnf_legpos assumes"""
    bad = []
    for mod in MODULES:
        t = open(os.path.join(ROOT, "src", mod + ".ASM"), errors="replace").read()
        for m in re.finditer(r"^(\w+anitab1)\s*$", t, re.M):
            rows = re.findall(r"^\s*\.long\s+(\w+)", t[m.end():m.end() + 12000], re.M)
            if len(rows) < 0x42:
                continue
            for row, need in ((0x39, "legs"), (0x41, "torso")):
                parts = parse_lane(t, rows[row])
                if parts is None:
                    bad.append(f"{mod} {m.group(1)} row {row:03x}h: no lane {rows[row]}")
                    continue
                if need == "legs":
                    for n, (p, r) in LEGPOS.items():
                        if len(parts) < p or len(parts[p - 1]) <= r or parts[p - 1][r].startswith("<"):
                            bad.append(f"{mod} {m.group(1)} 039h: no frame at part {p} row {r} for DECAPLEG{n}")
                else:
                    if not parts or len(parts[0]) < TORSO_ROWS or any(x.startswith("<") for x in parts[0][:TORSO_ROWS]):
                        bad.append(f"{mod} {m.group(1)} 041h: fewer than {TORSO_ROWS} torso frames")
    return bad


def parse_lane(t, lbl):
    """parts of a lane, by zero terminators - the walk find_part_a14 does"""
    mm = re.search(r"^" + re.escape(lbl) + r"\s*$", t, re.M)
    if not mm:
        return None
    parts, part = [], []
    for line in t[mm.end():mm.end() + 8000].splitlines():
        s = line.split(";")[0].strip()
        if not s or s.startswith("*"):
            continue
        if re.match(r"^[A-Za-z_]\w*$", s):
            break
        w = re.match(r"\.word\s+(.+)$", s)
        if w:
            vals = [v.strip() for v in w.group(1).split(",")]
            if all(v in ("0", "00h", "000h") for v in vals):
                return None                  # a zero word pair would read as a terminator
            continue
        mm2 = re.match(r"\.long\s+(.+)$", s)
        if not mm2:
            continue
        for v in [x.strip() for x in mm2.group(1).split(",")]:
            if v == "0":
                parts.append(part)
                part = []
            elif v.startswith("ani_"):
                part.append("<" + v + ">")
            else:
                part.append(v)
        if len(parts) >= 9:
            break
    return parts


def build():
    kv = parse_wax(WAX)
    names = img_names(os.path.join(ROOT, "data", IMG_NAME))
    legs_n, torso_n = slots(kv, names)
    legs, lholds = lane(kv, names, legs_n, 0x100)
    torso, tholds = lane(kv, names, torso_n, 0x200)
    size = max(lane_longs(legs), lane_longs(torso))

    out = [BEGIN,
           "* GENERATED from data/RAINSPLIT.WAX by tools/rain_split_wax_import.py.",
           f"* Legs = slot {legs_n}, torso = slot {torso_n}.  Edit the project, not this block.",
           "* 0100h|n = his DECAPLEGn, 0200h|n = his RIPTORSOn, swapped in by rnf_build.",
           "*",
           f"RNF_TPL_LONGS\t.set\t{size}\t\t; the longer template, terminator included",
           "",
           "rnf_legpos\t\t\t\t; DECAPLEGn -> part (find_part_a14), row, in 039h"]
    for n in range(1, 8):
        p, r = LEGPOS[n]
        out.append(f"\t.word\t{p},{r}\t\t\t; DECAPLEG{n}")
    out += ["", "rnf_legs_tpl"] + legs
    out += ["rnf_legs_holds", "\t.word\t" + ",".join(str(h) for h in lholds)]
    out += ["", "rnf_torso_tpl"] + torso
    out += ["rnf_torso_holds", "\t.word\t" + ",".join(str(h) for h in tholds)]
    out.append(END)
    return "\n".join(out) + "\n"


def splice(text, block):
    a = text.index(BEGIN)
    b = text.index(END) + len(END)
    b = text.index("\n", b) + 1
    return text[:a] + block + text[b:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    bad = check_modules()
    if bad:
        print("RAINSPLIT: a victim's lanes no longer have the shape the split looks frames up in:")
        for b in bad:
            print("  " + b)
        return 1
    raw = open(ASM, "rb").read().decode("latin-1")
    crlf = "\r\n" in raw
    text = raw.replace("\r\n", "\n")
    if BEGIN not in text or END not in text:
        sys.exit(f"{os.path.basename(ASM)}: no {BEGIN!r} / {END!r} markers")
    new = splice(text, build())
    if new == text:
        print("rain split OK (matches RAINSPLIT.WAX; every victim's 039h/041h has the frames)")
        return 0
    if args.check:
        print("rain split: src/MKRAINF.ASM differs from RAINSPLIT.WAX - run tools/rain_split_wax_import.py")
        return 1
    if crlf:
        new = new.replace("\n", "\r\n")
    open(ASM, "wb").write(new.encode("latin-1"))
    print("rewrote the rain split lanes from RAINSPLIT.WAX")
    return 0


if __name__ == "__main__":
    sys.exit(main())
