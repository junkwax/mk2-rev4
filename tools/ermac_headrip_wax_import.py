#!/usr/bin/env python3
"""Generate ERMAC'S TELEKINETIC HEAD RIP fatality from data/ERMACFAT2.WAX.

    python tools/ermac_headrip_wax_import.py           rewrite the generated blocks
    python tools/ermac_headrip_wax_import.py --check   exit 1 if any is stale
    python tools/ermac_headrip_wax_import.py --show    print the beats, write nothing

THE PROJECT.  IMGTOOL only draws a lane for a document with MARKED frames, plus
the split lanes, so the live scene in ERMACFAT2.WAX is exactly two slots:

  ERMAC  the slot bound to the marked document (NINJAS8.IMG, frames borrowed
         per entry from NINJAS9.IMG): Scorpion's swipe / spear-throw poses and
         Sub-Zero's death-blow poses, which every ninja body has, at the
         authored hold per frame.  Must be unmirrored and unmoved - it is the
         origin everything else is measured from.
  HEAD   the split lane: one head record (NJHEAD6) moved by local_dx/dy.

Every other slot in the file is a stale source tab that IMGTOOL does not draw,
and is ignored (and listed by --show).

OFFSETS.  IMGTOOL's local_dx/dy are anipoint offsets: an unmirrored frame's
anchor sits at origin - dx, origin - dy (the convention every WAX importer in
tools/ shares).  So the head's anchor is x_w = -dx in FRONT of Ermac's anchor
and y_w = -dy BELOW it, in facing space.

WHERE THE VICTIM IS.  Not in the project: the head's first keyframe IS him -
it is held on his neck until the rip.  So the WAX puts his anchor ERF_DIST =
x_w(0) in front of Ermac, at the same height (decapped_head's own neck offset,
010h, is the y the head starts at).  The game is not that far apart, so
erf_head_proc maps each point through the two LIVE anchors:

    X = Ex + x_w * (Vx - Ex) / ERF_DIST
    Y = Ey + y_w + x_w * (Vy - Ey) / ERF_DIST

which puts x_w = ERF_DIST exactly on him, 0 on Ermac, and scales the flight
between them - and the sign of Vx - Ex is the facing, so no flip test.

THE PATH.  The WAX steps the head from keyframe to keyframe and so does the
game: each position is held for its authored hold, no in-betweens (TWEEN_MAX
0), which is how an MK2 projectile reads.  From PULL on it is not authored at
all - erf_head_proc pops it out of him, it lands ~1/4 screen toward Ermac and
rolls (decapped_head's bounces).

THE BEATS (ticks from the start of Ermac's lane), all read off the project:
  GRIP    the pose he holds the head out of - the Ermac frame on screen the
          tick before the rip.  The victim starts to shake.
  RIP     the head's first move.  Off it comes; the body stands headless.
  IMPACT  the head's furthest point from Ermac after it has come back to him:
          it is in the torso.  Legs and torso become two objects.
  PULL    the head's next move after IMPACT: it is pulled out, the torso
          falls, the legs buckle.
  END     the last tick of Ermac's lane.

THE TORSO.  Every fighter module's decap fall frames (anitab1 03ch) are a legs
half and a TORSO half of the same body; the legs alone are already row 039h
part 6 (r_sai_split's legz).  This writes the torso halves as two more parts of
039h in each of the nine modules - part 10 standing, part 11 its fall - so the
victim's own object can be the torso while a second object is the legs.

Outputs:
  src/MKERFAT.ASM  ;>>>WAX BEGIN ermac_headrip     holds, beats, head table
  src/MKNJ.ASM     ;>>>WAX BEGIN ermac_headrip_lane a_ermac_headrip
  src/MK??.ASM     ;>>>GEN BEGIN ermac_headrip_torso   (nine modules)
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jade_impale_wax_import as wax       # IMG + WAX readers

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "ERMACFATGRN.WAX")
ERF_ASM = os.path.join(ROOT, "src", "MKERFAT.ASM")
NJ_ASM = os.path.join(ROOT, "src", "MKNJ.ASM")

DATA_BEGIN, DATA_END = ";>>>WAX BEGIN ermac_headrip", ";<<<WAX END ermac_headrip"
LANE_BEGIN, LANE_END = ";>>>WAX BEGIN ermac_headrip_lane", ";<<<WAX END ermac_headrip_lane"
TORSO_BEGIN, TORSO_END = (";>>>GEN BEGIN ermac_headrip_torso",
                          ";<<<GEN END ermac_headrip_torso")

TWEEN_MAX = 0           # NO in-betweens: the head sits on each WAX keyframe
                        # for its hold, exactly as IMGTOOL steps it (the user's
                        # call - a glide read as too smooth for MK2)
HEAD_STEP = 1
PARKED = 8              # a hold longer than this is the head held still
                        # (in his hand) - how THROW is found
MODULES = ["MKHH", "MKLK", "MKJC", "MKSA", "MKFN", "MKST", "MKRD", "MKNJ", "MKJX"]
TORSO_PARTS_BEFORE = 9  # row 039h has 9 parts today; ours are 10 and 11

UNSUPPORTED = ("motion_dx", "motion_dy", "motion_cap_x", "motion_cap_y", "dual_on",
               "visible_from", "visible_until", "frame_z", "frame_mirror")


def die(msg):
    sys.exit("ermac_headrip_wax_import: " + msg)


def live_slots(kv):
    """the slots IMGTOOL actually draws: marked-document slots + split slots"""
    marked = {i for i in range(int(kv.get("doc.count", "0")))
              if kv.get(f"doc.{i}.marked", "").strip()}
    out = [n for n in range(int(kv.get("slot.count", "0")))
           if int(kv.get(f"slot.{n}.doc_idx", "-1")) in marked
           and wax.ints(kv, f"slot.{n}.sequence_frames")]
    for k in range(int(kv.get("split.count", "0"))):
        n = int(kv.get(f"split.{k}.slot", "-1"))
        if n >= 0 and n not in out:
            out.append(n)
    return out


def lane(kv, n):
    seq = wax.ints(kv, f"slot.{n}.sequence_frames")
    fdoc = wax.ints(kv, f"slot.{n}.frame_doc_idx")
    base = int(kv.get(f"slot.{n}.doc_idx", "-1"))
    get = lambda k: (wax.ints(kv, f"slot.{n}.{k}") + [0] * len(seq))[:len(seq)]
    for k in UNSUPPORTED:
        if any(get(k)):
            die(f"slot {n} uses {k}, which the game half does not do")
    if int(kv.get(f"slot.{n}.mirror", "0")):
        die(f"slot {n} is mirrored")
    holds, dx, dy = get("frame_delays"), get("local_dx"), get("local_dy")
    out, t = [], 0
    for i, fi in enumerate(seq):
        d = fdoc[i] if i < len(fdoc) and fdoc[i] >= 0 else base
        name = wax.doc_file(kv, d)
        recs, _ = wax.read_img(os.path.join(ROOT, "data", name))
        if not 0 <= fi < len(recs):
            die(f"slot {n} entry {i}: index {fi} is outside {name}")
        if holds[i] <= 0:
            die(f"slot {n} entry {i}: hold {holds[i]}")
        out.append(dict(t=t, hold=holds[i], name=recs[fi]["name"], x=-dx[i], y=-dy[i]))
        t += holds[i]
    return out


def read_project():
    kv = wax.parse_wax(WAX)
    slots = live_slots(kv)
    ermac = head = flame = None
    for n in slots:
        L = lane(kv, n)
        if all(re.fullmatch(r"Flame[A-D]\d", e["name"]) for e in L):
            flame = (n, L)
            continue
        if all(re.fullmatch(r"NJHEAD\d+", e["name"]) for e in L):
            if head is not None:
                die(f"two head slots ({head[0]}, {n})")
            head = (n, L)
        else:
            if ermac is not None:
                die(f"two body slots ({ermac[0]}, {n})")
            ermac = (n, L)
    if ermac is None or head is None:
        die(f"need one Ermac slot and one head split lane, live slots were {slots}")
    for e in ermac[1]:
        if e["x"] or e["y"]:
            die(f"Ermac's {e['name']} is offset - he is the origin, he must not move")
    names = {e["name"] for e in head[1]}
    if len(names) != 1:
        die(f"the head lane draws {sorted(names)}; it must hold ONE head record")
    return kv, slots, ermac, head, flame


THROW_HOLD = 4          # no keyframe of the throw is held longer than this:
                        # the head does not pause on its way into him (the
                        # user's call, 2026-10-06 - ERMACFAT2.WAX hovers it 40
                        # ticks in front of him)


def no_throw_pause(H):
    """cap the holds between the throw and the impact at THROW_HOLD, and pull
    every later keyframe earlier by what was cut"""
    back = next((i for i in range(1, len(H)) if H[i]["x"] <= 0), None)
    if back is None:
        return H
    imp = max(range(back, len(H)), key=lambda i: H[i]["x"])
    throw = next((i for i in range(back + 1, imp + 1) if H[i]["x"] > H[i - 1]["x"]), imp)
    out, cut = [], 0
    for i, h in enumerate(H):
        h = dict(h, t=h["t"] - cut)
        if throw <= i < imp and h["hold"] > THROW_HOLD:
            cut += h["hold"] - THROW_HOLD
            h["hold"] = THROW_HOLD
        out.append(h)
    return out


LIFT_AT_CATCH = True    # he pauses on the catch (the WAX's own hold on that
                        # frame), then lifts: no rise frame, no look (the
                        # user's call, 2026-10-10).
                        # False = hold it, raise it and look at it on
                        # LOOK_POSE first (RISE_EXTRA / LOOK_EXTRA below)
LOOK_POSE = "NJSUBDETHBLO1"    # Sub-Zero's snowball pose: where Ermac holds the
                               # head up in front of him and looks at it
RISE_EXTRA = -2         # ticks added to the frame that raises it there (the
                        # WAX's 6 -> 4: one beat of a straight run-through)
LOOK_EXTRA = -12        # ...and to the look itself (20 -> 8: a very slight
                        # pause on the head, then on up into the victory)
                        # (the user's call, 2026-10-10)
PALM_EXTRA = 24         # ticks added to the hold in Ermac's palm, before the
                        # throw, to watch the soul flame grow over the face
                        # (the user's call, 2026-10-06) - Ermac, the head and
                        # the flame all wait the same ticks


def stretch(L, at, extra):
    """hold whatever is showing at tick `at` (the throw) `extra` ticks longer
    and push everything from `at` on later by as much"""
    out = []
    for e in L:
        e = dict(e)
        if e["t"] >= at:
            e["t"] += extra
        elif e["t"] + e["hold"] >= at:
            e["hold"] += extra
        out.append(e)
    return out


def retime(L, old, new):
    """move a lane's keyframe times by the same cut no_throw_pause made to the
    head (old -> new keyframe times, piecewise), so the flame keeps riding it"""
    pts = [(o["t"], n["t"]) for o, n in zip(old, new)] + \
          [(old[-1]["t"] + old[-1]["hold"], new[-1]["t"] + new[-1]["hold"])]

    def m(t):
        for (a, a2), (b, b2) in zip(pts, pts[1:]):
            if a <= t <= b:
                return a2 + min(t - a, b2 - a2)
        return t - (pts[-1][0] - pts[-1][1])
    out = []
    for e in L:
        out.append(dict(e, t=m(e["t"])))
    for i in range(len(out) - 1):
        out[i]["hold"] = max(1, out[i + 1]["t"] - out[i]["t"])
    return out


def beats(ermac, head):
    E, H = ermac[1], head[1]
    end = E[-1]["t"] + E[-1]["hold"]
    if len(H) < 4:
        die("the head lane needs a rest, a flight, an impact and a pull")
    rip = H[1]["t"]
    grip = [e for e in E if e["t"] <= rip - 1][-1]["t"]
    back = next((i for i in range(1, len(H)) if H[i]["x"] <= 0), None)
    if back is None:
        die("the head never comes back to Ermac (x <= 0) after the rip")
    imp = max(range(back, len(H)), key=lambda i: H[i]["x"])
    # the head's authored hold in the torso is how long he shakes with it
    # before he bursts
    burst = H[imp]["t"] + H[imp]["hold"]
    # the throw: the first keyframe after the catch that moves toward him
    throw = next((H[i]["t"] for i in range(back + 1, imp + 1)
                  if H[i]["x"] > H[i - 1]["x"]), H[imp]["t"])
    return dict(GRIP=grip, RIP=rip, CATCH=H[back]["t"], THROW=throw,
                IMPACT=H[imp]["t"], PULL=burst,
                END=end, DIST=H[0]["x"], HY0=H[0]["y"], HITY=H[imp]["y"])


FLIGHT_TWEEN = 8        # rip -> hand only: holds this short get in-betweens...
FLIGHT_STEP = 2         # ...on a 2-tick step, rip -> hand AND the throw - a
                        # little more fluid there (the user's call); the hold
                        # in his hand stays on the keyframes


def head_table(H, rip, end, catch=None, throw=None, impact=None):
    """one (x, y) per tick from RIP to END"""
    rows = []
    for tt in range(rip, end):
        flight = (catch is not None and tt < catch) or \
                 (throw is not None and throw <= tt < impact)
        step = FLIGHT_STEP if flight else HEAD_STEP
        tween = FLIGHT_TWEEN if flight else TWEEN_MAX
        t = rip + (tt - rip) // step * step
        i = max(k for k in range(len(H)) if H[k]["t"] <= t)
        a = H[i]
        if i + 1 < len(H) and a["hold"] <= tween and t < a["t"] + a["hold"]:
            b, f = H[i + 1], (t - a["t"]) / a["hold"]
            rows.append((round(a["x"] + (b["x"] - a["x"]) * f),
                         round(a["y"] + (b["y"] - a["y"]) * f)))
        else:
            rows.append((a["x"], a["y"]))
    return rows


HOLD_ON = "NJSCORPSWIPE4"     # Ermac stops on this pose after the impact and
                             # holds it into his victory (the user's call): the
                             # recovery frames after it in the WAX are dropped


def ermac_lane(E, b):
    """the lane the game plays.  The WAX up to the pose he is in when the head
    goes in, held until he BURSTS; then he yanks his arm back - the same pull
    he does at the rip (his frames from RIP to CATCH); then the WAX's last
    pose, which the director holds until the head is down."""
    show = max(i for i, e in enumerate(E) if e["t"] <= b["IMPACT"])
    out = [dict(x) for x in E[:show + 1]]
    out[-1]["hold"] = b["PULL"] - out[-1]["t"]
    t = b["PULL"]
    pull = [e for e in E if b["RIP"] <= e["t"] < b["CATCH"]]
    if not pull:
        die("no pull-back frames between the rip and the catch")
    for e in pull + [E[-1]]:
        out.append(dict(e, t=t))
        t += e["hold"]
    return out


def head_index(H):
    n = int(re.fullmatch(r"NJHEAD(\d+)", H[0]["name"]).group(1))
    return n - 1


# ---------------------------------------------------------------- the ASM side

def read(path):
    raw = open(path, newline="").read()
    return raw, ("\r\n" if "\r\n" in raw else "\n")


def replace_block(text, begin, end, block, path):
    if begin not in text or end not in text:
        die(f"{os.path.basename(path)}: no {begin} / {end} markers")
    i, j = text.index(begin), text.index(end)
    j = text.index("\n", j) + 1
    return text[:i] + block + text[j:]


def frame_pieces(src, label, module):
    """the pieces a frame-list label names: same line or the .long lines after"""
    m = re.search(rf"^{re.escape(label)}\b(.*)$", src, re.M)
    if not m:
        die(f"{module}: no {label} frame list")
    pieces = []
    lines = [m.group(1)] + src[m.end():].splitlines()[1:]
    for k, line in enumerate(lines):
        line = line.split(";", 1)[0]
        d = re.search(r"\.long\s+(.*)", line)
        if not d:
            if k and line.strip():
                break
            continue
        for p in (x.strip() for x in d.group(1).split(",")):
            if p == "0":
                return pieces
            if p:
                pieces.append(p)
    die(f"{module}: {label} has no 0 terminator")


def decap_frames(src, module):
    """a_decapfall's DECAP1..7 frame labels, in order"""
    m = re.search(r"^a_decapfall\b", src, re.M)
    if not m:
        die(f"{module}: no a_decapfall")
    found = {}
    for line in src[m.end():].splitlines()[1:]:
        if re.match(r"^[A-Za-z_]", line):
            break
        for lab in re.findall(r"\b(\w*DECAP([1-7]))\b", line.split(";", 1)[0]):
            found.setdefault(int(lab[1]), lab[0])
    if sorted(found) != list(range(1, 8)):
        die(f"{module}: a_decapfall names frames {sorted(found)}, expected 1..7")
    return [found[n] for n in range(1, 8)]


STUCK_ANGLE = 45        # the head lodged in his belly: the roll frame whose
                        # neck gore points closest to this many degrees up
                        # toward Ermac (0 = straight at him, 90 = straight up)
_IMGS = None
_BLOBS = {}


def _find_record(name):
    """(path, record) for an IMG record by name, anywhere under data/"""
    global _IMGS
    if _IMGS is None:
        _IMGS = sorted(f for f in os.listdir(os.path.join(ROOT, "data"))
                       if f.upper().endswith(".IMG"))
    key = name.encode() + b"\0"
    for f in _IMGS:
        if f not in _BLOBS:
            _BLOBS[f] = open(os.path.join(ROOT, "data", f), "rb").read()
        if key in _BLOBS[f]:
            path = os.path.join(ROOT, "data", f)
            recs, _ = wax.read_img(path)
            for r in recs:
                if r["name"] == name:
                    return path, r
    return None, None


def _palette(path, rec):
    import struct
    b = open(path, "rb").read()
    n, _pc, o = wax.LIB_HDR.unpack_from(b, 0)[:3]
    p0 = o + n * wax.IMAGE.size
    i = rec["palnum"] - 3 if rec["palnum"] >= 3 else rec["palnum"]
    _nm, _p, _b, cnt, fo, *_ = wax.PALETTE.unpack_from(b, p0 + i * wax.PALETTE.size)
    return [(((c >> 10) & 31), ((c >> 5) & 31), (c & 31))
            for c in (struct.unpack_from("<H", b, fo + 2 * k)[0] for k in range(cnt))]


def neck_angle(name):
    """degrees the neck gore (the red-dominant pixels) points from the head's
    middle: 0 = forward (the way the art faces), 90 = up"""
    import math
    mirrored = name.endswith("_MIRROR")
    path, r = _find_record(name.replace("_MIRROR", ""))
    if r is None:
        return None
    pal = _palette(path, r)
    sx = sy = n = ax = ay = an = 0
    for y, row in enumerate(r["px"]):
        for x, c in enumerate(row):
            if not c:
                continue
            ax += x; ay += y; an += 1
            R, G, B = pal[c] if c < len(pal) else (0, 0, 0)
            if R >= 12 and R > G * 1.8 and R > B * 1.8:
                sx += x; sy += y; n += 1
    if n < 3:
        return None
    a = math.degrees(math.atan2(-(sy / n - ay / an), sx / n - ax / an))
    return 180 - a if mirrored else a


def stuck_head(src, module):
    """his head-roll frame (a_head) with the neck nearest STUCK_ANGLE"""
    m = re.search(r"^a_head\b", src, re.M)
    if not m:
        die(f"{module}: no a_head")
    names = []
    for line in src[m.start():].splitlines():
        line = line.split(";", 1)[0]
        if "ani_jump" in line:
            break
        names += re.findall(r"\.long\s+(\w+)", line)
    scored = [(abs(((a - STUCK_ANGLE) + 180) % 360 - 180), nm, a)
              for nm in names for a in [neck_angle(nm)] if a is not None]
    if not scored:
        die(f"{module}: no head-roll frame with a measurable neck")
    return min(scored)


def lane_parts(src, label):
    """the parts of a lane (lists of its .long entries, split at each 0)"""
    m = re.search(rf"^{label}\b", src, re.M)
    parts, cur = [], []
    for line in src[m.end():].splitlines()[1:]:
        if re.match(r"^[A-Za-z_]", line):
            break
        code = line.split(";", 1)[0]
        for v in re.findall(r"\.long\s+([^\s;]+)", code):
            for x in v.split(","):
                x = x.strip()
                if x == "0":
                    parts.append(cur)
                    cur = []
                elif x:
                    cur.append(x)
    return parts


STUMP_WIN = 16          # px from the end of the lying legs the cut is


def pool_point(src, module):
    """where the blood pools from, off the legs' anchor in facing space: the
    x of the CUT (the red stump pixels) of his last lying-legs frame (row 039h
    part 9's last frame) and the y of the stump's lowest red pixel"""
    parts = lane_parts(src, "a_torso_ripped")
    if len(parts) < 9 or not parts[8]:
        die(f"{module}: row 039h has no part 9 to lie the legs down on")
    last = parts[8][-1]
    opaque, red = [], []
    for piece in frame_pieces(src, last, module):
        path, r = _find_record(piece)
        if r is None:
            die(f"{module}: {last}'s piece {piece} is in no data/*.IMG")
        pal = _palette(path, r)
        for y, row in enumerate(r["px"]):
            for x, c in enumerate(row):
                if not c:
                    continue
                wx, wy = x - r["ax"], y - r["ay"]
                opaque.append(wx)
                R, G, B = pal[c] if c < len(pal) else (0, 0, 0)
                if R >= 12 and R > G * 1.8 and R > B * 1.8:
                    red.append((wx, wy))
    # only the red at the CUT END of the legs: red anywhere else is the
    # costume (Jax's pants are striped red, and counting them put his pool
    # 23px down his legs and on the floor).  The cut end is whichever end of
    # the lying legs has more red within STUMP_WIN px of it.
    lo, hi = min(opaque), max(opaque)
    near_lo = [p for p in red if p[0] <= lo + STUMP_WIN]
    near_hi = [p for p in red if p[0] >= hi - STUMP_WIN]
    stump = near_hi if len(near_hi) >= len(near_lo) else near_lo
    n = len(stump)
    sx = sum(p[0] for p in stump)
    sbot = max((p[1] for p in stump), default=None)
    if n < 3:
        die(f"{module}: {last} has no red stump to pool from")
    # the y is the STUMP's bottom, not the legs' lowest pixel: a stray low
    # pixel in some art (Mileena's) put the pool ~20px under the cut
    return round(sx / n), sbot, last


GRIP_HEAD_ROWS = 10     # px from the top of a dizzy frame that are his head
                        # (18 caught Jax's raised shoulder: 10px off)


def grip_pose(src, module):
    """the frame of his dizzy sway (anitab1 row 28h, stunned) whose HEAD leans
    furthest toward the way he faces - toward Ermac - measured off the art:
    the mean x of the top GRIP_HEAD_ROWS rows of opaque pixels against the
    mean x of the whole body (the art faces +x).  He is held in it while
    Ermac's grip shakes him, so his head goes out toward the hand"""
    m = re.search(r"\.long\s+(\w+)\s*;\s*28 - stunned", src)
    if not m:
        die(f"{module}: no stunned row (28h) in its anitab1")
    lm = re.search(rf"^{m.group(1)}\b", src, re.M)
    names = []
    for line in src[lm.end():].splitlines()[1:]:     # a LOOPING lane: it ends
        if re.match(r"^[A-Za-z_]", line):            # in ani_jump, not a 0, so
            break                                    # lane_parts sees nothing
        code = line.split(";", 1)[0]
        for v in re.findall(r"\.long\s+([^\s;]+)", code):
            names += [x.strip() for x in v.split(",")
                      if re.fullmatch(r"\w+", x.strip()) and not x.strip().startswith(("ani_", "a_"))
                      and x.strip() != "0"]
    best = None
    for fr in dict.fromkeys(names):
        try:
            pieces = frame_pieces(src, fr, module)
        except SystemExit:
            continue
        pts = []
        for piece in pieces:
            path, r = _find_record(piece)
            if r is None:
                continue
            for y, row in enumerate(r["px"]):
                for x, c in enumerate(row):
                    if c:
                        pts.append((x - r["ax"], y - r["ay"]))
        if not pts:
            continue
        top = min(p[1] for p in pts)
        head = [p for p in pts if p[1] < top + GRIP_HEAD_ROWS]
        lean = sum(p[0] for p in head) / len(head) - sum(p[0] for p in pts) / len(pts)
        if best is None or lean > best[1]:
            best = (fr, lean, round(sum(p[0] for p in head) / len(head)), top)
    if best is None:
        die(f"{module}: no measurable frame in {m.group(1)}")
    return best


def torso_block(src, module, nl):
    rows = []
    for n, lab in enumerate(decap_frames(src, module), 1):
        pieces = frame_pieces(src, lab, module)
        torso = [p for p in pieces if "TORSO" in p]
        legs = [p for p in pieces if "TORSO" not in p]
        if not torso or not legs or not all("LEG" in p for p in legs):
            die(f"{module}: {lab} = {pieces} is not a legs half plus a TORSO half")
        rows.append((n, lab, torso))
    out = [TORSO_BEGIN,
           "; GENERATED by tools/ermac_headrip_wax_import.py - never edit this block.",
           ";",
           "; Ermac's head rip (MKERFAT.ASM): the TORSO half of this fighter's decap",
           "; fall frames (a_decapfall), so his own object can be the torso while a",
           "; second object is the legs (part 6).  Part 10 stands, part 11 falls.",
           "; Part 12 is his head as it sits in his belly - measured off the art.",
           "\t.long\tERT_TORSO1\t\t; part 10 - headless torso, standing",
           "\t.long\t0",
           *[f"\t.long\tERT_TORSO{n}" for n in range(2, 8)],
           "\t.long\t0\t\t\t; part 11 - it goes over",
           ]
    off, nm, ang = stuck_head(src, module)
    out += [f"\t.long\t{nm}\t\t; part 12 - his head LODGED in his belly: the roll",
            f"\t.long\t0\t\t\t;   frame whose neck points {ang:.0f} deg up at Ermac"]
    px, py, last = pool_point(src, module)
    out += ["\t.long\tERT_POOLPT\t\t; part 13 - where the blood pools from",
            "\t.long\t0"]
    gf, lean, hx, hy = grip_pose(src, module)
    out += [f"\t.long\t{gf}\t\t; part 14 - the dizzy frame he is held in at the",
            f"\t.long\t0\t\t\t;   grip: head leaning {lean:+.1f}px toward Ermac",
            "\t.long\tERT_GRIPHD\t\t; part 15 - that frame's head: its middle x",
            "\t.long\t0\t\t\t;   and its top y off his anchor (facing space)",
            f"ERT_GRIPHD\t.word\t{hx},{hy}\t; {gf}'s head",
            f"ERT_POOLPT\t.word\t{px},{py}\t; {last}: the cut's x, the stump's bottom"]
    for n, lab, torso in rows:
        out.append(f"ERT_TORSO{n}\t.long\t{','.join(torso)},0\t; {lab} less its legs")
    out.append(TORSO_END)
    return nl.join(out) + nl


def place_torso(module, text):
    """text with this module's torso block placed (or refreshed) in row 039h"""
    nl = "\r\n" if "\r\n" in text else "\n"
    block = torso_block(text, module, nl)
    if TORSO_BEGIN in text:
        new = replace_block(text, TORSO_BEGIN, TORSO_END, block, module)
    else:
        m = re.search(r"^a_torso_ripped\b", text, re.M)
        if not m:
            die(f"{module}: no a_torso_ripped")
        pos, zeros = m.end(), 0
        for line in re.finditer(r"[^\n]*\n", text[m.end():]):
            pos = m.end() + line.end()
            if re.match(r"^\s*\.long\s+0\s*(;.*)?\r?$", line.group(0)):
                zeros += 1
                if zeros == TORSO_PARTS_BEFORE:
                    break
        if zeros != TORSO_PARTS_BEFORE:
            die(f"{module}: a_torso_ripped has {zeros} parts, expected {TORSO_PARTS_BEFORE}")
        new = text[:pos] + block + text[pos:]
    # the block must sit straight after part 9 of row 039h, inside the lane
    m = re.search(r"^a_torso_ripped\b", new, re.M)
    seg = new[m.end():new.index(TORSO_BEGIN)]
    nz = len(re.findall(r"^\s*\.long\s+0\s*(;[^\n]*)?\r?$", seg, re.M))
    if nz != TORSO_PARTS_BEFORE or re.search(r"^[A-Za-z_]", seg.split("\n", 1)[1], re.M):
        die(f"{module}: the torso block is not straight after row 039h's part 9")
    return new


def lane_block(E, nl):
    out = [LANE_BEGIN,
           "; GENERATED by tools/ermac_headrip_wax_import.py from data/ERMACFAT2.WAX -",
           "; edit the project in IMGTOOL and re-run the tool, never this block.",
           ";",
           "; ermac_anitab2 row 0bh: Ermac's half of the telekinetic head rip.  The",
           "; frames only - do_ermac_headrip (MKERFAT.ASM) holds each one for its",
           "; authored ticks out of erf_holds, which the same tool writes.",
           "a_ermac_headrip"]
    for e in E:
        out.append(f"\t.long\t{e['name']}\t\t; t={e['t']:3}  hold {e['hold']}")
    out += ["\t.long\t0",
            LANE_END]
    return nl.join(out) + nl


FLAME_POSE = None              # the soul flame lights when Ermac holds the
                               # head up on this pose ("NJSUBDETHBLO1",
                               # Sub-Zero's snowball, was tried 2026-10-06);
                               # None = the moment it reaches his palm (CATCH),
                               # the user's call


def flame_t(E, b):
    if FLAME_POSE is None:
        return b["CATCH"]
    t = [e["t"] for e in E if e["name"] == FLAME_POSE and b["CATCH"] <= e["t"] < b["THROW"]]
    if not t:
        die(f"Ermac never holds the head up on {FLAME_POSE} between the catch and the throw")
    return t[0]


def data_block(E, H, b, nl, F=None):
    rows = head_table(H, b["RIP"], b["PULL"], b["CATCH"], b["THROW"], b["IMPACT"])
    frows = head_table(F, b["RIP"], b["PULL"], b["CATCH"], b["THROW"], b["IMPACT"])
    _, pals = wax.read_img(os.path.join(ROOT, "data", "MKBGANI.IMG"))
    if "FLAME1_P" not in pals:
        die("data/MKBGANI.IMG has no FLAME1_P (the green flame)")
    fpal = pals["FLAME1_P"]
    out = [DATA_BEGIN,
           "; GENERATED by tools/ermac_headrip_wax_import.py from data/ERMACFAT2.WAX -",
           "; edit the project in IMGTOOL and re-run the tool, never this block.",
           f"ERF_T_GRIP\t.set\t{b['GRIP']}\t; victim starts to shake",
           f"ERF_T_RIP\t.set\t{b['RIP']}\t; head comes off",
           f"ERF_T_CATCH\t.set\t{b['CATCH']}\t; it reaches Ermac's hand",
           f"ERF_T_THROW\t.set\t{b['THROW']}\t; he throws it back",
           f"ERF_T_FLAME	.set	{flame_t(E, b)}	; the soul flame lights (FLAME_POSE, else the catch)",
           "ERF_T_LIFT	.set	%d	; lift (erflift): he has looked at it on LOOK_POSE - up it goes" % b["LIFT"],
           f"ERF_T_IMPACT\t.set\t{b['IMPACT']}\t; head is in the torso: legs and torso part",
           f"ERF_T_PULL\t.set\t{b['PULL']}\t; the head's hold in him is over: he BURSTS",
           f"ERF_T_END\t.set\t{b['END']}\t; Ermac's lane is done",
           f"ERF_DIST\t.set\t{b['DIST']}\t; px the WAX puts the victim in front of Ermac",
           f"ERF_HEAD_FRAME\t.set\t{head_index(H)}\t; {H[0]['name']}: entry of his head lane (03dh)",
           f"ERF_HEAD_TICKS\t.set\t{len(rows)}\t; rows in erf_head_path",
           f"ERF_HIT_Y\t.set\t{b['HITY']}\t; px below his anchor the head goes in",
           f"ERF_HIT_YX\t.set\t0{b['HITY'] << 16:x}h\t; [y:x] off HIS anchor where the head goes in -",
           f"\t\t\t\t;   his middle, {b['HITY']} px down (the head's height at the hit)",
           ";",
           "; Ermac's hold per frame of a_ermac_headrip (MKNJ.ASM), 0-terminated",
           "erf_holds"]
    for e in E:
        out.append(f"\t.word\t{e['hold']}\t\t; t={e['t']:3} {e['name']}")
    out += ["\t.word\t0",
            ";",
            "; The head's anchor every tick from ERF_T_RIP to ERF_T_PULL: x px in",
            "; FRONT of Ermac, y px BELOW him, as authored with the victim ERF_DIST",
            "; away (erf_head_proc maps it through the live anchors).  Held on each WAX",
            "; keyframe for its authored hold.  After the pull it is thrown, not authored.",
            "erf_head_path"]
    for k, (x, y) in enumerate(rows):
        t = b["RIP"] + k
        out.append(f"\t.word\t{x},{y}\t\t; t={t}")
    out += [";",
            "; The green flame's anchor (its BASE: the FlameB records' anipoint is at",
            "; their bottom) every tick from ERF_T_RIP, the project's flame lane on the",
            "; same clock and through the same anchors as the head.",
            "erf_flame_path"]
    for k, (x, y) in enumerate(frows):
        out.append(f"\t.word\t{x},{y}\t\t; t={b['RIP'] + k}")
    out += [";",
            "; ERF_FLAME_P - MKBGANI.IMG's FLAME1_P verbatim: the torch flame recoloured",
            "; green.  The records name the orange FLAME_P; the flame is swpal'd onto this.",
            "ERF_FLAME_P",
            f"\t.word\t{len(fpal)}"]
    for i in range(0, len(fpal), 8):
        out.append("\t.word\t" + ",".join(f"0{w:04X}H" for w in fpal[i:i + 8]))
    out.append(DATA_END)
    return nl.join(out) + nl


def check_lane_frames(E):
    src = open(NJ_ASM, errors="replace").read()
    for e in E:
        if not re.search(rf"^{e['name']}\b", src, re.M):
            die(f"MKNJ.ASM has no {e['name']} frame list for Ermac's lane")


def check_head_lanes(idx):
    for module in MODULES:
        src = open(os.path.join(ROOT, "src", module + ".ASM"), errors="replace").read()
        m = re.search(r"^a_head\b", src, re.M)
        if not m:
            die(f"{module}: no a_head")
        n = 0
        for line in src[m.start():].splitlines():
            line = line.split(";", 1)[0]
            if "ani_jump" in line or re.search(r"\.long\s+0\s*$", line):
                break
            n += len(re.findall(r"\.long\s+\w+", line))
        if n <= idx:
            die(f"{module}: a_head has {n} frames; the WAX holds head frame {idx + 1}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()

    kv, slots, ermac, head, flame = read_project()
    raw_head = head[1]
    head = (head[0], no_throw_pause(head[1]))
    if flame is None:
        die("no flame lane (Flame*) in the project")
    flame = (flame[0], retime(flame[1], raw_head, head[1]))
    # the lift (erflift, MKERFAT.ASM): he holds it, raises it SLOWLY (the frame
    # before LOOK_POSE held RISE_EXTRA longer), then looks at it on LOOK_POSE
    # for LOOK_EXTRA more before the victory lift takes over at ERF_T_LIFT
    cat = beats(ermac, head)["CATCH"]
    look = [e for e in ermac[1] if e["name"] == LOOK_POSE and e["t"] >= cat]
    if LIFT_AT_CATCH:
        look = None
    elif not look:
        die(f"Ermac never looks at the head on {LOOK_POSE} after the catch")
    for extra, when in () if look is None else ((RISE_EXTRA, lambda e: e["t"]), (LOOK_EXTRA, lambda e: e["t"] + e["hold"])):
        e = [x for x in ermac[1] if x["name"] == LOOK_POSE and x["t"] >= cat][0]
        at = when(e)
        ermac = (ermac[0], stretch(ermac[1], at, extra))
        head = (head[0], stretch(head[1], at, extra))
        flame = (flame[0], stretch(flame[1], at, extra))
    if look is None:
        # he PAUSES on the catch - the project's own hold on the frame he
        # catches it in - and then goes straight up, no rise and no look
        e = [x for x in ermac[1] if x["t"] <= cat < x["t"] + x["hold"]][0]
        lift_t = e["t"] + e["hold"]
    else:
        e = [x for x in ermac[1] if x["name"] == LOOK_POSE and x["t"] >= cat][0]
        lift_t = e["t"] + e["hold"]
    at = beats(ermac, head)["THROW"]
    ermac = (ermac[0], stretch(ermac[1], at, PALM_EXTRA))
    head = (head[0], stretch(head[1], at, PALM_EXTRA))
    flame = (flame[0], stretch(flame[1], at, PALM_EXTRA))
    E, H = ermac[1], head[1]
    b = beats(ermac, head)
    b["LIFT"] = lift_t
    E = ermac_lane(E, b)
    check_lane_frames(E)
    check_head_lanes(head_index(H))

    if a.show:
        print(f"live slots {slots}: Ermac = slot {ermac[0]}, head = slot {head[0]}")
        for k, v in b.items():
            print(f"  {k:7} {v}")
        for e in E:
            print(f"  E t={e['t']:3} {e['hold']:3} {e['name']}")
        for e in H:
            print(f"  H t={e['t']:3} {e['hold']:3} x={e['x']:4} y={e['y']:4}")
        return 0

    edits = {}
    for path in [ERF_ASM, NJ_ASM] + [os.path.join(ROOT, "src", m + ".ASM") for m in MODULES]:
        raw, _ = read(path)
        edits.setdefault(path, [raw, raw])
    nlof = lambda t: "\r\n" if "\r\n" in t else "\n"
    cur = edits[ERF_ASM][1]
    edits[ERF_ASM][1] = replace_block(cur, DATA_BEGIN, DATA_END,
                                      data_block(E, H, b, nlof(cur), flame[1]), ERF_ASM)
    cur = edits[NJ_ASM][1]
    edits[NJ_ASM][1] = replace_block(cur, LANE_BEGIN, LANE_END,
                                     lane_block(E, nlof(cur)), NJ_ASM)
    for module in MODULES:
        p = os.path.join(ROOT, "src", module + ".ASM")
        edits[p][1] = place_torso(module, edits[p][1])
    edits = [(p, o, n) for p, (o, n) in edits.items()]

    stale = [p for p, old, new in edits if old != new]
    if a.check:
        if stale:
            print("ermac_headrip_wax_import: STALE against data/ERMACFAT2.WAX - run "
                  "tools/ermac_headrip_wax_import.py: " +
                  ", ".join(os.path.basename(p) for p in stale))
            return 1
        print("ermac_headrip_wax_import: MKERFAT, MKNJ and the nine torso blocks "
              "match data/ERMACFAT2.WAX")
        return 0
    for p, old, new in edits:
        if old != new:
            open(p, "w", newline="").write(new)
            print(f"ermac_headrip_wax_import: wrote {os.path.relpath(p, ROOT)}")
    if not stale:
        print("ermac_headrip_wax_import: already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
