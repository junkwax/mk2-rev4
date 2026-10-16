#!/usr/bin/env python3
"""Generate Shang Tsung's soul-escape shake from data/TSHANGEND.WAX.

    python tools/shang_end_wax_import.py           rewrite the generated block
    python tools/shang_end_wax_import.py --check   exit 1 if it is stale

The IMGTOOL project is the source of truth for the lane he loops while his
souls leave him (MKSOULS.ASM, soul_shang_begin).  It has ONE live slot, on
data/TSUNG6.IMG, and this writes `a_soul_shake` plus the tick rate into
src/MKSOULS.ASM between its WAX BEGIN/END markers.

NAMES.  The project shows an IMG's COMPOSITE records; the ROM loads the
A/B STRIPS and MKST.ASM names the frame list after them, and for three of
Shang's poses the two spellings differ - the composite is `STHITLO<n>` and
the strips are `STLOHIT<n>`.  ALIASES maps those, and `check_alias` proves
each one by geometry before it is used: the strips' union must be the
composite's own w/h/anix/aniy (TSUNG6.IMG, +/-1 px on width for a
transparent edge column).  A wrong alias would draw a different pose with
no error anywhere.

HOLDS.  Every frame in the project is held the same number of ticks, so the
lane is a plain list and the hold is one equate (`soul_shake_rate`).  If a
future edit makes them differ this refuses rather than quietly flattening
them - the driver loop would need per-frame holds to keep the timing.

NO X NUDGE.  MK1's shake moved him +/-7 px a step and the driver used to do
that; this project's slot has local_dx = 0 on every frame, so it does not.
With an ODD number of frames an alternating nudge does not cancel either -
it would walk him 7 px sideways every time the lane wrapped.
"""
import argparse
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "TSHANGEND.WAX")
ASM = os.path.join(ROOT, "src", "MKSOULS.ASM")
MKST_ASM = os.path.join(ROOT, "src", "MKST.ASM")
MKST_TBL = os.path.join(ROOT, "src", "MKST.TBL")

BEGIN = ";>>>WAX BEGIN"
END = ";<<<WAX END"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# composite name in the project -> frame list the ROM actually carries
ALIASES = {"STHITLO1": "STLOHIT1", "STHITLO2": "STLOHIT2", "STHITLO3": "STLOHIT3"}


def cstr(b):
    return b.split(bytes(1), 1)[0].decode("latin-1")


def img_records(path):
    b = open(path, "rb").read()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(b, 0)[:3]
    out = {}
    for i in range(imgcnt):
        f = IMAGE.unpack_from(b, oset + i * IMAGE.size)
        # IMAGE is (name, flags, anix, aniy, w, h, pal, oset, ...) - the
        # same record imgdump.py reads; anix/aniy are stored unsigned
        sgn = lambda v: v - 0x10000 if v > 0x7FFF else v
        out[cstr(f[0])] = dict(w=f[4], h=f[5], anix=sgn(f[2]), aniy=sgn(f[3]))
    return out


def parse_wax(path):
    kv = {}
    for line in open(path, "r", errors="replace"):
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def ints(kv, key):
    v = kv.get(key, "")
    return [int(x) for x in v.split(",") if x.strip() != ""] if v else []


def live_slot(kv):
    """the one slot with frames in it, and the doc it draws from"""
    live = []
    for n in range(int(kv.get("slot.count", "0"))):
        if ints(kv, f"slot.{n}.sequence_frames"):
            live.append(n)
    if len(live) != 1:
        sys.exit(f"TSHANGEND.WAX has {len(live)} live slots, expected 1: {live}")
    n = live[0]
    doc = int(kv.get(f"slot.{n}.doc_idx", "-1"))
    path = kv.get(f"doc.{doc}.path", "")
    if os.path.basename(path).upper() != "TSUNG6.IMG":
        sys.exit(f"slot {n} draws from {path!r}, expected TSUNG6.IMG")
    return n, os.path.join(ROOT, "data", "TSUNG6.IMG")


def frame_lists(text):
    """label -> [piece, ...] for every `LABEL .long A,B,0` frame list"""
    out = {}
    for m in re.finditer(r"^(\w+)\s*\n?\s*\.long\s+([\w,\s]+?)\s*$", text, re.M):
        out.setdefault(m.group(1), [p.strip() for p in m.group(2).split(",")])
    return out


def tbl_records(text):
    out = {}
    for m in re.finditer(r"^(\w+):\s*\n\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)", text, re.M):
        w, h, ax, ay = (int(x) for x in m.groups()[1:])
        out[m.group(1)] = dict(w=w, h=h, anix=ax, aniy=ay)
    return out


def check_alias(name, label, imgs, lists, recs):
    """the aliased frame list must BE that composite, measured"""
    comp = imgs.get(name)
    pieces = [p for p in lists.get(label, []) if p not in ("0", "")]
    if not comp or not pieces:
        sys.exit(f"alias {name} -> {label}: composite or frame list missing")
    lo = hi = top = bot = None
    for p in pieces:
        r = recs.get(p)
        if not r:
            sys.exit(f"alias {name} -> {label}: no record for piece {p}")
        l, t = -r["anix"], -r["aniy"]
        lo = l if lo is None else min(lo, l)
        hi = l + r["w"] if hi is None else max(hi, l + r["w"])
        top = t if top is None else min(top, t)
        bot = t + r["h"] if bot is None else max(bot, t + r["h"])
    if (abs((hi - lo) - comp["w"]) > 1 or (bot - top) != comp["h"]
            or -lo != comp["anix"] or -top != comp["aniy"]):
        sys.exit(f"alias {name} -> {label} does not match the composite: "
                 f"strips {hi - lo}x{bot - top} at {-lo},{-top} vs "
                 f"{comp['w']}x{comp['h']} at {comp['anix']},{comp['aniy']}")


def build():
    kv = parse_wax(WAX)
    n, img_path = live_slot(kv)
    imgs = img_records(img_path)
    names_in_doc = list(imgs.keys())

    seq = ints(kv, f"slot.{n}.sequence_frames")
    dly = ints(kv, f"slot.{n}.frame_delays")
    dx = ints(kv, f"slot.{n}.local_dx")
    dy = ints(kv, f"slot.{n}.local_dy")

    holds = {dly[i] if i < len(dly) else 1 for i in range(len(seq))}
    if len(holds) != 1:
        sys.exit(f"frame_delays are not all equal ({sorted(holds)}) - the driver "
                 "loop holds every frame for the same number of ticks")
    hold = holds.pop()
    if any(dx[i] if i < len(dx) else 0 for i in range(len(seq))) or \
       any(dy[i] if i < len(dy) else 0 for i in range(len(seq))):
        sys.exit("this slot carries local_dx/dy offsets; the driver does not apply them")

    asm = open(MKST_ASM, errors="replace").read()
    lists = frame_lists(asm)
    recs = tbl_records(open(MKST_TBL, errors="replace").read())

    labels = []
    for fi in seq:
        if not 0 <= fi < len(names_in_doc):
            sys.exit(f"frame index {fi} is outside TSUNG6.IMG")
        nm = names_in_doc[fi]
        label = ALIASES.get(nm, nm)
        if label != nm:
            check_alias(nm, label, imgs, lists, recs)
        if label not in lists:
            sys.exit(f"{nm}: MKST.ASM has no frame list {label} - that pose is not "
                     "loaded into the ROM (the IMG carries it, the LOD does not)")
        labels.append((nm, label))

    out = [BEGIN,
           "* GENERATED from data/TSHANGEND.WAX by tools/shang_end_wax_import.py.",
           "* Edit the project, not this block.  Shang's own MK2 frames, out of",
           "* TSUNG6.IMG; the three the project calls STHITLO<n> are the composite",
           "* names for the strips the ROM carries as STLOHIT<n>.",
           "*",
           f"soul_shake_rate\t.set\t{hold}\t\t; ticks a frame (every frame_delay in the project)",
           "",
           "a_soul_shake"]
    for nm, label in labels:
        note = f"\t\t; {nm}" if nm != label else ""
        out.append(f"\t.long\t{label}{note}")
    out.append("\t.long\tani_jump,a_soul_shake")
    out.append(END)
    return "\n".join(out) + "\n"


def splice(text, block):
    a = text.index(BEGIN)
    b = text.index(END) + len(END)
    b = text.index("\n", b) + 1
    return text[:a] + block + text[b:]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if not os.path.exists(WAX):
        sys.exit(f"missing {WAX}")
    block = build()
    text = open(ASM, errors="replace").read()
    if BEGIN not in text or END not in text:
        sys.exit(f"{ASM} has no {BEGIN} / {END} markers")
    new = splice(text, block)
    if a.check:
        if new != text:
            print("STALE: src/MKSOULS.ASM's a_soul_shake does not match "
                  "data/TSHANGEND.WAX - rerun tools/shang_end_wax_import.py")
            return 1
        print("OK: a_soul_shake matches TSHANGEND.WAX")
        return 0
    if new == text:
        print("a_soul_shake already matches TSHANGEND.WAX")
        return 0
    open(ASM, "w", newline="").write(new)
    print("wrote a_soul_shake from TSHANGEND.WAX:")
    for line in block.splitlines():
        if line.startswith("\t.long") or line.startswith("soul_shake_rate"):
            print("   ", line.replace("\t", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
