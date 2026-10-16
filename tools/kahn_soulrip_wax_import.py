#!/usr/bin/env python3
"""Generate Shao Kahn's soul rip from data/SHAOSOULSUCK.WAX.

    python tools/kahn_soulrip_wax_import.py           rewrite the generated block
    python tools/kahn_soulrip_wax_import.py --check   exit 1 if it is stale

The IMGTOOL project is the source of truth for the choreography.  It has
three live slots:

    slot 0  SHASOULRIP1-9   Shao Kahn        (NEWSHAO.IMG)
    slot 5  the victim      knockdown -> stumble -> flipped -> soul-suck
    slot 1  the soul        the victim's own SUCK_* frames

and this writes the one table that walks all three, ksr_script in
src/MKSOULRP.ASM, between its WAX BEGIN/END markers.

A STEP is one row of the project: every slot holds every entry for one tick
(frame_delays are all 1), so a step is a tick and the holds come straight
out of the project.  Kahn's lane is shorter than the other two, so a step
carries a flag saying whether HIS frame advances - he holds SHASOULRIP9
while the victim and the soul keep moving.

THE SOUL'S BUFFER.  The project parks the soul on its first frame for the
first fifteen ticks to delay it.  That is timing, not staging - the user's
instruction is that "the green sprite shouldnt show until the very last
tick before the CAGESOUL2 plays" - so the leading run of repeats of the
soul's first frame is emitted as srow = -1 (nothing on screen) except for
its LAST tick, which is the frame that shows.

PLACEMENT.  Every offset is an ANIPOINT offset in the editor's space, and
Kahn's own slot carries one too (0,13), so each row is stored relative to
him: (slot dx - kahn dx, slot dy - kahn dy).  ksr_place / ksr_soul then
negate both, which is the rule kahn_slam_place uses and
doc/IMGTOOL_LANE_CONVERSION.md section 5 explains.
"""
import argparse
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "SHAOSOULSUCK.WAX")
ASM = os.path.join(ROOT, "src", "MKSOULRP.ASM")

BEGIN = ";>>>WAX BEGIN"
END = ";<<<WAX END"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

KAHN_PREFIX = "SHASOULRIP"

# Ticks each SOUL frame is held for, overriding the project's 1.  The user
# watched it at speed and said "the soul suck goes way too fast": seven 1-tick
# frames is 0.13 s.  4 is Shang's own soul (green_soul, MKFX.ASM, `sleep 4`
# a frame) and the game's most common rate.  Only the steps with the soul ON
# SCREEN take it - Kahn and the victim are holding their last poses there, so
# stretching those steps delays nothing else.  None keeps the project's holds.
SOUL_HOLD = 4
# ...and for Kahn's own frames (every step where SHASOULRIP moves on), split
# where the man leaves the floor.  REACH (victim still flat - SHASOULRIP1-3,
# Kahn bending down to him) at 4.  LIFT (the hoist, SHASOULRIP4-9) slower:
# the user wants him to "pick up at slower normal pace" - 6, the game's
# victory-and-fatality-beat rate (sa_victory, generic_victory_ani).  In
# between, MKSOULRP.ASM holds him bent over the body for ksr_jingle_hold
# while the arena darkens and the sting plays.  None keeps the project's.
REACH_HOLD = 4
LIFT_HOLD = 6

# The victim's pose list, a_??_ksoulrip, in the order the ASM indexes it.
# A project frame is matched by its SUFFIX so any fighter's project reads:
# JCKNOCKDOWN7 -> KNOCKDOWN7 -> row 0.  KTKNOCKDOWN6 is Kitana's last
# knockdown frame, which is everyone else's 7.
POSE_ROWS = [
    ("KNOCKDOWN7", "KNOCKDOWN6"),          # 0 - flat on his back
    ("KNOCKDOWN2",),                        # 1 - up on one elbow
    ("STUMBLE3", "STUMBL1E3"),              # 2 - reeling
    ("STUMBLE2", "STUMBL1E2"),              # 3
    ("STUMBLE1", "STUMBL1E1"),              # 4
    ("FLIPPED1", "GETFLIPPED1"),            # 5 - hauled upright
    ("SOULSUCK1",),                         # 6 - drained, the held pose
]


def img_names(path):
    b = open(path, "rb").read()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(b, 0)[:3]
    return [IMAGE.unpack_from(b, oset + i * IMAGE.size)[0].split(b"\0", 1)[0]
            .decode("latin-1") for i in range(imgcnt)]


def parse(path):
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


class Slot:
    def __init__(self, kv, n, docs):
        self.n = n
        own = int(kv.get(f"slot.{n}.doc_idx", "-1"))
        self.seq = ints(kv, f"slot.{n}.sequence_frames")
        self.dly = ints(kv, f"slot.{n}.frame_delays")
        self.dx = ints(kv, f"slot.{n}.local_dx")
        self.dy = ints(kv, f"slot.{n}.local_dy")
        self.dis = ints(kv, f"slot.{n}.frame_doc_idx")
        self.names = []
        for i, fi in enumerate(self.seq):
            d = self.dis[i] if i < len(self.dis) else -1
            if d < 0:
                d = own
            recs = docs.get(d, [])
            self.names.append(recs[fi] if 0 <= fi < len(recs) else "<%d>" % fi)

    def ticks(self):
        """One entry per TICK: (name, dx, dy, entry index)."""
        out = []
        for i, nm in enumerate(self.names):
            hold = self.dly[i] if i < len(self.dly) else 1
            for _ in range(max(1, hold)):
                out.append((nm, self.dx[i] if i < len(self.dx) else 0,
                            self.dy[i] if i < len(self.dy) else 0, i))
        return out


def pose_row(name, soft=False):
    for row, suffixes in enumerate(POSE_ROWS):
        for s in suffixes:
            if name.endswith(s):
                return row
    if soft:
        return None
    raise SystemExit("victim frame %s matches no row of a_??_ksoulrip" % name)


def build():
    kv = parse(WAX)
    docs = {}
    for i in range(int(kv.get("doc.count", "0"))):
        p = kv.get(f"doc.{i}.path", "")
        p = os.path.join(ROOT, "data", os.path.basename(p))
        docs[i] = img_names(p) if os.path.exists(p) else []

    # A project carries scratch slots - another sequence being looked at, a
    # slot whose document was closed.  Each of the three is picked by what
    # its frames ARE, and a slot that matches none of the three is ignored:
    # guessing "the remaining one" is how slot 7's two leftover JC2DEATHBLO
    # frames were read as the victim.
    nslots = int(kv.get("slot.count", "0"))
    kahn = victim = soul = None
    for n in range(nslots):
        s = Slot(kv, n, docs)
        if not s.seq or any(nm.startswith("<") for nm in s.names):
            continue
        if all(nm.startswith(KAHN_PREFIX) for nm in s.names):
            kahn = s
        elif all(nm.startswith("CAGE") or nm.startswith("SUCK_") for nm in s.names):
            soul = s
        elif all(pose_row(nm, soft=True) is not None for nm in s.names):
            victim = s
    if kahn is None or victim is None or soul is None:
        raise SystemExit("SHAOSOULSUCK.WAX: found Kahn=%s victim=%s soul=%s"
                         % (kahn and kahn.n, victim and victim.n, soul and soul.n))

    kt, vt, st = kahn.ticks(), victim.ticks(), soul.ticks()
    steps = max(len(kt), len(vt), len(st))

    # The soul's leading buffer: repeats of its first frame show nothing
    # until the last of them.
    first = st[0][0] if st else None
    lead = 0
    while lead < len(st) and st[lead][0] == first:
        lead += 1
    soul_from = lead - 1 if lead > 1 else 0

    kdx, kdy = (kt[0][1], kt[0][2]) if kt else (0, 0)
    rows, prev_k = [], None
    for i in range(steps):
        k = kt[i] if i < len(kt) else kt[-1]
        v = vt[i] if i < len(vt) else vt[-1]
        kadv = 1 if k[3] != prev_k else 0
        prev_k = k[3]
        if i < len(st) and i >= soul_from:
            s = st[i]
            srow = s[3] - lead + 1 if lead > 1 else s[3]
            sdx, sdy, sname = s[1] - kdx, s[2] - kdy, s[0]
        else:
            srow, sdx, sdy, sname = -1, 0, 0, None
        rows.append(dict(kadv=kadv, pose=pose_row(v[0]),
                         vdx=v[1] - kdx, vdy=v[2] - kdy,
                         srow=srow, sdx=sdx, sdy=sdy,
                         hold=(SOUL_HOLD if (SOUL_HOLD and srow >= 0) else
                               (REACH_HOLD if pose_row(v[0]) == 0 else LIFT_HOLD)
                               if kadv else 1),
                         kname=k[0] if kadv else "(held)",
                         vname=v[0], sname=sname))

    out = [BEGIN + " - generated by tools/kahn_soulrip_wax_import.py, do not edit",
           ";",
           "; data/SHAOSOULSUCK.WAX - %d steps, %d ticks" % (len(rows), sum(r["hold"] for r in rows)),
           ";",
           ";      Kahn slot %d    victim slot %d              soul slot %d"
           % (kahn.n, victim.n, soul.n),
           ";",
           "ksr_script"]
    for i, r in enumerate(rows):
        tail = r["sname"] if r["sname"] else r["vname"].replace("JC", "")
        out.append("\t.word\t%d,%d,%d,%d,%d,%d,%d,%d\t\t; step %2d  %-12s %s"
                   % (r["kadv"], r["pose"], r["vdx"], r["vdy"], r["srow"],
                      r["sdx"], r["sdy"], r["hold"], i, r["kname"], tail))
    out.append("\t.word\t0,0,0,0,0,0,0,0\t\t\t; end of script")
    out.append(END)
    return "\n".join(out)


def splice(text, block):
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(nl)
    try:
        i = next(k for k, l in enumerate(lines) if l.startswith(BEGIN))
        j = next(k for k, l in enumerate(lines) if l.startswith(END))
    except StopIteration:
        raise SystemExit("markers not found in %s" % ASM)
    return nl.join(lines[:i] + block.split("\n") + lines[j + 1:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    block = build()
    have = open(ASM, newline="").read()
    want = splice(have, block)
    if a.check:
        if have != want:
            print("STALE src/MKSOULRP.ASM - rerun tools/kahn_soulrip_wax_import.py")
            return 1
        print("ok ksr_script matches data/SHAOSOULSUCK.WAX")
        return 0
    if have == want:
        print("ksr_script already matches data/SHAOSOULSUCK.WAX")
        return 0
    open(ASM, "w", newline="").write(want)
    print("wrote ksr_script into src/MKSOULRP.ASM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
