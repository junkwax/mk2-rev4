#!/usr/bin/env python3
"""
hurtbox_lock.py - make an art edit that changes what you can be HIT BY visible.

Section 3.5 of doc/TOURNAMENT_READINESS.md.  The hurt box is not authored
anywhere: it is COMPUTED FROM THE SPRITE.  So a new frame, a shifted anipoint
or a re-cut composite silently changes what a fighter can be hit by, on every
move, and nothing in the build diffs.  `balance.lock` guards the numbers a
human typed; this guards the ones the art decides.

Scope is deliberately the DEFENSIVE frames - stance, walking, ducking, the
jumps, the turn, the hit reactions, the getups.  Those are the poses a fighter
wears while NOT attacking, so a change there alters what can land on them
through no choice of their own.  Attack lanes are excluded on purpose: this
project adds and re-times moves constantly, and a lock that failed every time
somebody drew a new punch would be switched off within a week.

Each row is one character's one defensive lane:

    frames      how many poses part one displays
    x           union of every pose's horizontal extent, about the anipoint
    y           the same vertically

The union is the point.  A hurt box is taken from whichever pose is showing,
so the extremes across the lane are what a player can actually be caught by.

  python tools/hurtbox_lock.py            regenerate doc/hurtbox.lock
  python tools/hurtbox_lock.py --check    fail if it differs (Phase D)
  python tools/hurtbox_lock.py --diff     show what changed, do not write
"""
import argparse
import difflib
import glob
import hashlib
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
LOCK = os.path.join(ROOT, "doc", "hurtbox.lock")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BA = _load("ba", os.path.join(ROOT, "tools", "box_align_audit.py"))

# Index -> what that ani1 slot IS.  The layout is shared by the whole standard
# cast, so one commented table names it for everybody.  Read out of the source
# rather than hardcoded, so a renumbering shows up as a lock diff instead of
# quietly locking the wrong slots.
REF_TABLE = ("MKHH.ASM", "hat_anitab1")

# A slot is defensive if its description says so.  An explicit list, not a
# keyword rule: "getup from sweep kick" contains "kick" and is defensive,
# "sweep kick" is an attack, and no fuzzy match separates those two safely.
DEFENSIVE = (
    "stance", "walk forward", "walk backward", "skip forward", "skip backward",
    "duck animation", "jump straight up", "forward flip", "backward flip",
    "turn around", "hit high", "hit low", "hit while ducking",
    "normal getup", "sweep fall", "getup from sweep kick", "stumble back",
    "stunned", "block",
)


def slot_names():
    """ani1 index -> description, from the reference table's own comments."""
    txt = BA.read(os.path.join(SRC, REF_TABLE[0]))
    m = re.search(r"^%s\s*$" % REF_TABLE[1], txt, re.M)
    if not m:
        return {}
    out, idx = {}, 0
    for line in txt[m.end():].splitlines():
        code = line.split(";")[0].strip()
        note = line.split(";", 1)[1].strip() if ";" in line else ""
        if not code:
            continue
        if not re.match(r"\.[lL][oO][nN][gG]\s+[A-Za-z_]", code):
            if re.match(r"^[A-Za-z_]", code):
                break
            continue
        mm = re.match(r"^[0-9a-fA-F]+\s*-\s*(.+)$", note)
        out[idx] = mm.group(1).strip() if mm else ""
        idx += 1
    return out


def lane_order(path):
    """Label -> the label that physically follows it in the file."""
    labels = []
    for line in BA.read(path).splitlines():
        code = line.split(";")[0].rstrip()
        if code[:1] not in (" ", "\t", "*", ";", ""):
            m = re.match(r"^([A-Za-z0-9_]+)", code)
            if m:
                labels.append(m.group(1))
    return {a: b for a, b in zip(labels, labels[1:])}


def lane_poses(lane, lanes, frames, nxt=None, hops=3):
    """Every pose part one displays, in order.  Mirrors contact_pose_ex.

    LANES FALL THROUGH, and the stance lanes are exactly where it matters:

        a_fn1stance
                .long   ani_ochar_jump
                .word   ft_fn2
                .long   a_fn2stance
        j_fn1st
                .long   KT1STANCE1
                ...

    Kitana's stance lane is three tokens of dispatch and no frames at all -
    the art is under the NEXT label, reached by falling off the end. A walk
    that stops at the label boundary returns nothing, which is why Kitana and
    Mileena had no stance box. If the entries run out without a terminating 0,
    continue into the following label.
    """
    entries = lanes.get(lane)
    if entries is None:
        return None
    flat = []
    for kind, toks in entries:
        for t in toks:
            flat.append((kind, t))
    seq, i, terminated = [], 0, False
    while i < len(flat):
        kind, tok = flat[i]
        i += 1
        if kind != "long":
            continue
        if BA.num(tok) == 0:
            terminated = True
            break
        if tok.startswith("ani_"):
            name = tok[4:]
            cmd = None
            for _, spec in BA.ANI_CMD.items():
                if spec[0] == name:
                    cmd = spec
                    break
            if cmd is None:
                return None
            nm, nlong, nword = cmd
            if nm == "nosleep":
                if i < len(flat):
                    seq.append(flat[i][1])
                    i += 1
                continue
            if nm == "jump":
                terminated = True
                break
            i += nlong + nword
            continue
        if tok in frames:
            seq.append(tok)
        else:
            return None
    if not terminated and nxt and hops > 0:
        follow = nxt.get(lane)
        if follow and follow in lanes:
            more = lane_poses(follow, lanes, frames, nxt, hops - 1)
            if more:
                seq += more
    return seq or None


def pose_box(pose, frames, strips):
    """(left, right, top, bottom) about the anipoint, or None."""
    names = frames.get(pose)
    if not names:
        return None
    l = r = t = b = None
    for n in names:
        s = strips.get(n)
        if not s:
            return None
        w, h, dx, dy = s
        x0, y0 = -dx, -dy
        x1, y1 = x0 + w, y0 + h
        l = x0 if l is None else min(l, x0)
        r = x1 if r is None else max(r, x1)
        t = y0 if t is None else min(t, y0)
        b = y1 if b is None else max(b, y1)
    return (l, r, t, b)


def build_lock():
    strips = BA.parse_strips()
    frames_by_file, frames = BA.parse_frames()
    lanes, lane_file, nxt = {}, {}, {}
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        for k, v in BA.lane_lines(BA.read(path)).items():
            if k not in lanes:
                lanes[k], lane_file[k] = v, path
        for a, b in lane_order(path).items():
            nxt.setdefault(a, b)
    text_all = "\n".join(BA.read(p)
                         for p in glob.glob(os.path.join(SRC, "*.ASM")))
    anitabs = BA.parse_anitabs(text_all)
    names = slot_names()
    picks = [i for i, d in sorted(names.items())
             if d and any(d.lower().startswith(k) for k in DEFENSIVE)]

    lines = []
    lines.append("# hurtbox.lock - generated by tools/hurtbox_lock.py")
    lines.append("# The hurt box is COMPUTED FROM THE SPRITE, so an art edit")
    lines.append("# changes what a fighter can be hit by with no diff anywhere")
    lines.append("# else.  These are the DEFENSIVE lanes - the poses worn while")
    lines.append("# NOT attacking.  A diff in this file is a hitbox change.")
    lines.append("")
    lines.append("[slots]  ani1 index -> what it is")
    for i in picks:
        lines.append("%02xh %s" % (i, names[i]))
    lines.append("")
    lines.append("[extents]  character  slot  lane  frames  x  y")
    missing = []
    for oc, cname in enumerate(BA.CHARS):
        for i in picks:
            lane = anitabs.get((oc, 1, i))
            if not lane:
                missing.append((cname, i, "no lane"))
                continue
            local = frames_by_file.get(lane_file.get(lane), {})
            scope = dict(frames)
            scope.update(local)
            seq = lane_poses(lane, lanes, scope, nxt)
            if not seq:
                missing.append((cname, i, "lane unwalkable"))
                continue
            box = None
            for p in seq:
                bb = pose_box(p, scope, strips)
                if bb is None:
                    continue
                box = bb if box is None else (
                    min(box[0], bb[0]), max(box[1], bb[1]),
                    min(box[2], bb[2]), max(box[3], bb[3]))
            if box is None:
                missing.append((cname, i, "no art"))
                continue
            lines.append("%-11s %02xh %-22s %2d  %+5d..%+5d  %+5d..%+5d"
                         % (cname, i, lane, len(seq),
                            box[0], box[1], box[2], box[3]))
    lines.append("")
    lines.append("[unresolved]  %d character/slot pairs" % len(missing))
    for cname, i, why in missing:
        lines.append("%-11s %02xh  %s" % (cname, i, why))
    lines.append("")
    body = "\n".join(lines)
    return body + "\n[digest]\nsha256 %s\n" % hashlib.sha256(
        body.encode("utf-8")).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the lock is out of date")
    ap.add_argument("--diff", action="store_true",
                    help="print what changed without writing")
    args = ap.parse_args()

    fresh = build_lock()
    have = open(LOCK, encoding="utf-8", newline="").read() \
        if os.path.exists(LOCK) else None

    if args.check or args.diff:
        if have is None:
            print("hurtbox.lock does not exist yet - run: "
                  "python tools/hurtbox_lock.py")
            sys.exit(1 if args.check else 0)
        if have == fresh:
            n = sum(1 for l in fresh.splitlines()
                    if l and not l.startswith(("#", "[")))
            print("  hurtbox.lock OK (%d locked values)" % n)
            return
        d = list(difflib.unified_diff(
            have.splitlines(), fresh.splitlines(),
            fromfile="hurtbox.lock (committed)", tofile="art (now)",
            lineterm="", n=0))
        print("HURT BOXES CHANGED - %d differing lines:" % sum(
            1 for l in d if l[:1] in "+-" and not l.startswith(("---", "+++"))))
        for l in d[:60]:
            print("  " + l)
        if len(d) > 60:
            print("  ... %d more" % (len(d) - 60))
        print()
        print("An art edit changed what a fighter can be hit by.  If that was")
        print("deliberate, regenerate it:")
        print("  python tools/hurtbox_lock.py")
        sys.exit(1 if args.check else 0)

    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, "w", encoding="utf-8", newline="") as fh:
        fh.write(fresh)
    n = sum(1 for l in fresh.splitlines() if l and not l.startswith(("#", "[")))
    print("wrote doc/hurtbox.lock (%d values)" % n)
    if have is not None and have != fresh:
        print("NOTE: this OVERWROTE an existing lock - the hurt boxes changed.")


if __name__ == "__main__":
    main()
