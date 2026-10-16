#!/usr/bin/env python3
"""
box_align_audit.py - does each move's strike box land on the frame the move
actually holds while it is checking for a hit?

Baraka's blade swipe is the reason this exists. Reported as "the hitboxes
completely miss - the blade completely hits the ninja's face", and the source
says exactly that:

  striker / striker_2 (JOY.ASM) play PART ONE of the animation FIRST and only
  then hold the final pose for a10 ticks of strike_check. So the CONTACT POSE
  is the last frame of part one - and stk_swipe was authored against UGSWIPE3,
  the frame before it, where the blade is still out.

Nothing in the build checks that, so this does. For every move whose handler
names both an animation index (a9) and a strike index (a11):

  contact pose span  = min/max over the pose's multipart strips, placed the
                       way ani2 and box_bounds place them: left = oxpos - dx,
                       right = left + xsize
  strike box span    = oxpos + x_offset - x_size .. oxpos + x_offset
                       (strike_check, facing right)

and reports where the two do not meet.

A gap is not automatically a bug. MK2 boxes routinely reach a little past the
art, and a few moves are meant to hit in front of the fighter. What this finds
is moves where the box is nowhere near what is drawn - and it prints the
frame BEFORE the contact pose too, because if the box fits that one instead,
the record was authored a frame early and the tool has named the cause.

Usage:
  python tools/box_align_audit.py            # findings only
  python tools/box_align_audit.py --all      # every resolved move
  python tools/box_align_audit.py --gap N    # flag gaps of N px or more (24)
"""
import os
import re
import sys
import glob
import argparse
import collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

CHARS = ["hathead", "liu kang", "cage", "baraka", "kitana", "mileena", "shang",
         "raiden", "sub-zero", "reptile", "scorpion", "jax", "kintaro",
         "shao kahn", "smoke", "noob", "jade"]
CHAR_LIST = {0: "hh_strikes", 1: "lk_strikes", 2: "jc_strikes", 3: "sa_strikes",
             4: "fn_strikes", 5: "fn_strikes", 6: "st_strikes", 7: "rd_strikes",
             8: "nj_strikes", 9: "nj_strikes", 10: "nj_strikes",
             11: "jx_strikes", 12: "go_strikes", 13: "sk_strikes",
             14: "nj_strikes", 15: "nj_strikes", 16: "fn_strikes"}

ANI_CMD = {1: ("jump", 1, 0), 2: ("flip", 0, 0), 3: ("adjustx", 0, 1),
           4: ("adjustxy", 0, 2), 5: ("nosleep", 1, 0), 6: ("calla", 1, 0),
           7: ("sound", 1, 0), 8: ("ochar_jump", 1, 1), 9: ("flip_v", 0, 0)}


def read(path):
    return open(path, encoding="latin-1", errors="replace").read()


def num(t):
    t = t.strip().split(';')[0].strip()
    if not t:
        return None
    try:
        return int(t[:-1], 16) if t[-1] in 'hH' else int(t, 0)
    except ValueError:
        return None


def s16(v):
    return v - 0x10000 if v is not None and v >= 0x8000 else v


# ---------------------------------------------------------------- strips ---
def parse_strips():
    """label -> (W, H, dx, dy), from the .TBL sprite tables.

    `.word W,H,anix,aniy` then `.long sag` then `.word control`. The anix/aniy
    pair IS the dx/dy the placement code uses: ani2 (MKUTIL.ASM) copies them
    into multipart RAM entries 4 and 5, and box_bounds (MKDISP.ASM) computes
    `piece left = oxpos - dx`.
    """
    out = {}
    pat = re.compile(
        r'^([A-Za-z0-9_]+):\s*\n'
        r'\s*\.[wW][oO][rR][dD]\s+(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\n'
        r'\s*\.[lL][oO][nN][gG]', re.M)
    for path in glob.glob(os.path.join(SRC, "*.TBL")):
        for m in pat.finditer(read(path)):
            out[m.group(1)] = tuple(int(m.group(i)) for i in (2, 3, 4, 5))
    return out


# ---------------------------------------------------------------- frames ---
def parse_frames():
    """(per_file, global) frame tables for `LABEL .long A,B,C,0` shapes.

    LABELS COLLIDE ACROSS FILES and it changes the answer: `JCSPLIT5` is
    defined in both MKJC.ASM (the split punch, arm out to +63) and
    MKDEATH.ASM. Taking whichever the file glob reached first reported Cage's
    split punch as art -45..-1 against a box of +21..+63 - a fabricated
    finding. A lane resolves its frames from its OWN file first.

    A FRAME'S STRIP LIST CAN SPAN SEVERAL LINES, and requiring it on one was
    the same silent-drop bug as the aliased labels. Liu Kang's walk is

        LKWALK1 .long   LKWALKLEG1A
                .long   LKWALKTORSO1A,LKWALKTORSO1B,0

    where Kung Lao's whole list sits on one line. A single-line pattern found
    the second character and not the first, so `LKWALK1` was not a known frame
    at all - and a lane containing an unknown frame is abandoned wholesale by
    every consumer of this table. The walk continues across following `.long`
    lines until the terminating 0.
    """
    per_file = {}
    out = {}
    head = re.compile(r'^([A-Za-z0-9_]+)(?:\s+\.[lL][oO][nN][gG]\s+'
                      r'([A-Za-z0-9_, \t]+))?\s*$')
    cont = re.compile(r'^[ \t]+\.[lL][oO][nN][gG]\s+([A-Za-z0-9_, \t]+?)\s*$')
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        lines = read(path).splitlines()
        local = per_file.setdefault(path, {})
        i = 0
        while i < len(lines):
            code = lines[i].split(';')[0].rstrip()
            i += 1
            m = head.match(code)
            if not m:
                continue
            label, first = m.group(1), m.group(2)
            parts = [p.strip() for p in first.split(',')] if first else []
            # keep taking continuation `.long` lines until the list terminates
            while '0' not in parts and i < len(lines):
                c2 = lines[i].split(';')[0].rstrip()
                m2 = cont.match(c2)
                if not m2:
                    break
                i += 1
                parts += [p.strip() for p in m2.group(1).split(',')]
            if '0' not in parts:
                continue
            parts = parts[:parts.index('0')]
            names = [p for p in parts if re.match(r'^[A-Za-z_]', p)]
            if not names:
                continue
            local.setdefault(label, names)
            out.setdefault(label, names)
    return per_file, out


# ------------------------------------------------------------------ lanes ---
def lane_lines(text):
    """label -> list of raw entry tokens, in order, for every `.long` list."""
    lanes, cur, buf = {}, None, []
    for line in text.splitlines():
        code = line.split(';')[0].rstrip()
        if not code.strip():
            continue
        m = re.match(r'^([A-Za-z0-9_]+)\s*$', code)
        if m:
            if cur and buf:
                lanes.setdefault(cur, buf)
            cur, buf = m.group(1), []
            continue
        m = re.match(r'^([A-Za-z0-9_]+)\s+\.(long|word)\s+(.*)$', code)
        if m:
            if cur and buf:
                lanes.setdefault(cur, buf)
            cur, buf = m.group(1), []
            buf.append((m.group(2), [t.strip() for t in m.group(3).split(',')]))
            continue
        m = re.match(r'^\s+\.(long|word)\s+(.*)$', code)
        if m and cur:
            buf.append((m.group(1), [t.strip() for t in m.group(2).split(',')]))
            continue
        if code[:1] not in (' ', '\t'):
            if cur and buf:
                lanes.setdefault(cur, buf)
            cur, buf = None, []
    if cur and buf:
        lanes.setdefault(cur, buf)
    return lanes


def contact_pose(lane, lanes, frames):
    """Three-value wrapper. contact_pose_ex adds the startup row count."""
    return contact_pose_ex(lane, lanes, frames)[:3]


_LANE_NEXT = None


def lane_next():
    """label -> the label that physically follows it, across all of src/.

    Lanes FALL THROUGH. `a_fn1stance` is three tokens of `ani_ochar_jump`
    dispatch and no frames at all; Kitana's stance art is under the NEXT
    label, reached by running off the end. A walk that stops at the label
    boundary returns nothing, which is why stance width would not resolve for
    Kitana, Mileena, the three ninjas, Smoke, Noob and Jade - eight of
    seventeen characters - and MOVE_MATRIX.md fell back to a flat 64 px for
    all of them.
    """
    global _LANE_NEXT
    if _LANE_NEXT is not None:
        return _LANE_NEXT
    out = {}
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        labels = []
        for line in read(path).splitlines():
            code = line.split(';')[0].rstrip()
            if code[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^([A-Za-z0-9_]+)', code)
                if m:
                    labels.append(m.group(1))
        for a, b in zip(labels, labels[1:]):
            out.setdefault(a, b)
    _LANE_NEXT = out
    return out


def contact_pose_ex(lane, lanes, frames, _hops=3):
    """Walk part ONE of an animation lane and return (contact, previous, note).

    Part one ends at the first standalone `.long 0`; the frame displayed when
    it ends is what striker holds during the strike window. `ani_nosleep`
    consumes the NEXT entry as a frame, which is the idiom every move uses to
    park its final pose - `ani_nosleep / <pose> / 0`.

    If the entries run out with no frames and no terminator, the lane falls
    through to the next label - see lane_next().
    """
    entries = lanes.get(lane)
    if entries is None:
        return None, None, "lane not found", 0
    flat = []
    for kind, toks in entries:
        for t in toks:
            flat.append((kind, t))
    seq, note, i = [], None, 0
    nosleep = set()
    while i < len(flat):
        kind, tok = flat[i]
        i += 1
        if kind != "long":
            continue
        v = num(tok)
        if v == 0:
            break
        if tok.startswith("ani_"):
            name = tok[4:]
            cmd = None
            for _, (nm, nlong, nword) in ANI_CMD.items():
                if nm == name:
                    cmd = (nm, nlong, nword)
                    break
            if cmd is None:
                return None, None, "unknown command " + tok, 0
            nm, nlong, nword = cmd
            if nm == "nosleep":
                if i < len(flat):
                    seq.append(flat[i][1])
                    nosleep.add(len(seq) - 1)   # this row costs ZERO ticks
                    i += 1
                continue
            if nm in ("jump", "ochar_jump"):
                note = "lane jumps"
            if nm in ("flip", "flip_v", "adjustx", "adjustxy"):
                note = "lane uses " + nm
            i += nlong + nword
            continue
        if tok in frames:
            seq.append(tok)
        else:
            return None, None, "unknown frame " + tok, 0
    if not seq:
        # nothing displayed: a dispatch-only lane that falls through
        follow = lane_next().get(lane) if _hops > 0 else None
        if follow and follow in lanes:
            return contact_pose_ex(follow, lanes, frames, _hops - 1)
        return None, None, "empty part one", 0
    # STARTUP = the rows of part one that actually SLEEP.  act_mframew holds
    # each row for a0 ticks, and an ani_nosleep row is displayed and passed
    # straight through - which is why Baraka's swipe measures 9 ticks of windup
    # from three sleeping rows at 3 ticks each, and not 12 from four rows.
    return (seq[-1], (seq[-2] if len(seq) > 1 else None), note,
            len(seq) - len(nosleep))


def part_rows(lane, lanes, part):
    """How many SLEEPING rows are in part `part` (1-based) of a lane.

    Parts are separated by a standalone `.long 0`. Part one is the startup
    act_mframew plays; the later parts are what retract_strike plays, which is
    where a move's recovery time actually goes. An ani_nosleep row costs no
    ticks and is not counted.
    """
    entries = lanes.get(lane)
    if entries is None:
        return None
    flat = []
    for kind, toks in entries:
        for t in toks:
            flat.append((kind, t))
    cur, rows, i = 1, 0, 0
    while i < len(flat):
        kind, tok = flat[i]
        i += 1
        if kind != "long":
            continue
        if num(tok) == 0:
            if cur == part:
                return rows
            cur, rows = cur + 1, 0
            continue
        if tok.startswith("ani_"):
            name = tok[4:]
            for _, (nm, nlong, nword) in ANI_CMD.items():
                if nm == name:
                    if nm == "nosleep":
                        i += 1            # consumes a frame, costs no ticks
                    else:
                        i += nlong + nword
                    break
            else:
                return None
            continue
        if cur == part:
            rows += 1
    return rows if cur == part else None


def pose_span(pose, frames, strips):
    """(left, right) of a pose relative to the anipoint, or None."""
    names = frames.get(pose)
    if not names:
        return None
    lo, hi = None, None
    for n in names:
        s = strips.get(n)
        if not s:
            return None
        w, _h, dx, _dy = s
        left = -dx
        right = left + w
        lo = left if lo is None else min(lo, left)
        hi = right if hi is None else max(hi, right)
    return (lo, hi)


# ------------------------------------------------------------- strike recs ---
def parse_records(text):
    W = r'\s*\.[wW][oO][rR][dD]\s+([^\n;]*?)\s*(?:;[^\n]*)?\n'
    pat = re.compile(r'^(stk_[A-Za-z0-9_]+)\s*\n'
                     r'((?:\s*[;*][^\n]*\n|\s*\n)*)' + W * 4, re.M)
    out = {}
    for m in pat.finditer(text):
        out[m.group(1)] = dict(x_off=s16(num(m.group(3))),
                               y_off=s16(num(m.group(4))),
                               x_size=num(m.group(5)),
                               y_size=num(m.group(6)))
    return out


def parse_lists(text):
    lists, cur = collections.defaultdict(list), None
    for line in text.splitlines():
        m = re.match(r'^([A-Za-z0-9_]+_strikes)\s*$', line)
        if m:
            cur = m.group(1)
            continue
        if cur:
            m = re.match(r'\s*\.[lL][oO][nN][gG]\s+(stk_[A-Za-z0-9_]+)', line)
            if m:
                lists[cur].append(m.group(1))
            elif line.strip() == '' and lists[cur]:
                cur = None
    return lists


# --------------------------------------------------------------- handlers ---
def parse_handlers():
    """do_* -> {a9, a11, which striker}. Only moves that name BOTH indices can
    be audited: without a9 there is no lane and without a11 there is no box."""
    out = {}
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        lines = read(path).splitlines()
        starts = {}
        for i, ln in enumerate(lines):
            if ln[:1] not in (' ', '\t', '*', ';', ''):
                # do_* AND joy_*: JOY.ASM's punch handlers never call striker
                # at all - joy_hi_punch sets a11 and calls strike_check_a0
                # inline - so scanning only do_* left the standing jab, the
                # low punch and their kin out of the matrix entirely.
                m = re.match(r'^((?:do|joy)_[A-Za-z0-9_]+)', ln)
                if m:
                    starts.setdefault(m.group(1), i)
        # Every label, not only do_*: shared tails are reached by `jruc`.
        # do_hi_kick sets its registers and then jumps to `kick2`, which is
        # where `jsrp striker` actually lives, and the old scan stopped at the
        # next do_* label before it got there - so the high kick, one of the
        # two most-used moves in the game, was silently absent from this audit.
        label_at = {}
        for i, ln in enumerate(lines):
            if ln[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', ln)
                if m:
                    label_at.setdefault(m.group(1), i)

        for name, start in starts.items():
            info = {"a9": None, "a11": None, "call": None,
                    "file": os.path.basename(path)}
            i, hops, seen = start + 1, 0, set()
            regs = {}
            # Conditional branches passed on the way, taken only if the
            # straight-line path dead-ends without a strike call. kick2 grew a
            # Raiden-only path (`jruc kik3`, then `rets`) IN FRONT of its
            # `jsrp striker`, reached from the stock path by `jrne k2_strike`;
            # following only jruc lost both standing kicks for the whole cast.
            forks = []
            while True:
                if not (i < len(lines) and hops < 4):
                    if forks:
                        i, hops, regs = forks.pop(0)
                        continue
                    break
                s = lines[i].split(';')[0].strip()
                if i != start and re.match(r'^(?:do|joy)_[A-Za-z0-9_]+', s):
                    if forks:
                        i, hops, regs = forks.pop(0)
                        continue
                    break
                # Track the last immediate loaded into EVERY register, not just
                # a9 and a11. do_jumpup_punch does `movk 9,a0` and then
                # `move a0,*a13(p_stk),w` - the strike index never touches a11
                # at all - so an a11-only scan left every character's jumping
                # punch, jumping kick and both flip attacks unattributed.
                # p_stk IS the index: air_strike reads it back through
                # get_char_stk.
                m = re.search(r'\bmov[ki]\s+([^,]+),(a\d+)\b', s)
                if m:
                    regs[m.group(2)] = num(m.group(1))
                m = re.search(r'\bclr\s+(a\d+)\b', s)
                if m:
                    regs[m.group(1)] = 0
                for reg in ("a9", "a11"):
                    if info[reg] is None and reg in regs:
                        info[reg] = regs[reg]
                m = re.search(r'\bmove\s+(a\d+),\*a13\(p_stk\)', s)
                if m and info["a11"] is None:
                    info["a11"] = regs.get(m.group(1))
                # All four entry points share one contract - part one plays,
                # then its final pose is held for the scan. upcut_striker and
                # behind_striker were missing, which is why every character's
                # UPPERCUT and SWEEP had no handler: do_uppercut calls
                # upcut_striker and do_sweep_kick calls behind_striker.
                # jsrp AND jauc/jruc/calla. do_duck_kickh ends `jauc striker` -
                # a tail jump, not a call - and matching only jsrp left every
                # character's ducking kicks with no handler at all.
                m = re.search(
                    r'\b(?:jsrp|jauc|jruc|calla|callr)\s+'
                    r'(striker_2|upcut_striker|behind_striker|air_strike'
                    r'|striker)\b', s)
                if m:
                    info["call"] = m.group(1)
                    break
                # An inline strike_check_a0 is a real move too, but it does NOT
                # hold a single contact pose - the caller drives its own frames
                # around it - so it is recorded with call="inline" and the
                # alignment audit skips it rather than inventing a pose.
                #
                # ONLY joy_* handlers. Accepting it from do_* let the scan
                # wander through a jruc into unrelated code and come back with
                # somebody else's strike index - do_noogy was credited with
                # index 6 and do_sz_tornado with Baraka's high punch, neither
                # of which they set. JOY.ASM's button handlers are the ones
                # that genuinely check inline.
                m = (re.search(r'\b(?:callr|calla)\s+strike_check_a0\b', s)
                     if name.startswith("joy_") else None)
                if m:
                    info["call"] = "inline"
                    break
                m = re.match(r'^jruc\s+([A-Za-z_][A-Za-z0-9_]*)$', s)
                if m and m.group(1) in label_at and m.group(1) not in seen:
                    seen.add(m.group(1))
                    i = label_at[m.group(1)]
                    hops += 1
                    continue
                m = re.match(r'^jr(?!uc\b)[a-z]+\s+([A-Za-z_][A-Za-z0-9_]*)$', s)
                if m and m.group(1) in label_at and m.group(1) not in seen:
                    seen.add(m.group(1))
                    forks.append((label_at[m.group(1)], hops + 1, dict(regs)))
                if s in ('retp', 'rets'):
                    if forks:
                        i, hops, regs = forks.pop(0)
                        continue
                    break
                i += 1
            if info["call"] and info["a9"] is not None and info["a11"] is not None:
                out[name] = info
    return out


def parse_anitabs(text_all):
    """(ochar, which, index) -> lane label."""
    tabs = {}
    for which, tabname in ((1, "character_anitabs1"), (2, "character_anitabs2")):
        m = re.search(r'^' + tabname + r'\s*\n((?:\s*\.[lL][oO][nN][gG]\s+\w+\s*\n|\s*\n)+)',
                      text_all, re.M)
        if not m:
            continue
        names = re.findall(r'\.[lL][oO][nN][gG]\s+(\w+)', m.group(1))
        for oc, tab in enumerate(names):
            # Ani tables are ALIASED, exactly like the strike records: the
            # ninja table is four stacked labels over one body -
            #
            #   sz_anitab1
            #   rp_anitab1
            #   sc_anitab1
            #   sm_anitab1
            #       .long   a_njstance
            #
            # so requiring `.long` on the line after the label matched only
            # the LAST alias.  Smoke came out with all 67 lanes while
            # Sub-Zero, Reptile and Scorpion had none, and the same shape hid
            # Kitana and Mileena behind fn3.  Five characters were invisible
            # to every audit built on this - their uppercut, both ducking
            # attacks and both jump attacks reported "no ani lane".
            body = re.search(r'^' + tab + r'\s*\n'
                             r'(?:[A-Za-z_][A-Za-z0-9_]*[ \t]*\n)*'
                             r'((?:\s*\.[lL][oO][nN][gG]\s+[^\n]*\n|\s*[;*][^\n]*\n|\s*\n)+)',
                             text_all, re.M)
            if not body:
                continue
            idx = 0
            for line in body.group(1).splitlines():
                mm = re.match(r'\s*\.[lL][oO][nN][gG]\s+([A-Za-z_][A-Za-z0-9_]*)\s*$',
                              line.split(';')[0])
                if mm:
                    tabs[(oc, which, idx)] = mm.group(1)
                    idx += 1
    return tabs


# ------------------------------------------------------------- restriction ---
# Canonical handler-prefix -> ochar map. It lives HERE, the lowest of the
# three modules, because move_matrix and frame_advantage both need it and a
# second copy would drift.
NAME_CHARS = {
    "hh": {0}, "lk": {1}, "jc": {2}, "sa": {3}, "fn1": {4}, "fn2": {5},
    "fn": {4, 5, 16}, "st": {6}, "rd": {7}, "sz": {8}, "rp": {9}, "sc": {10},
    "nj": {8, 9, 10, 14, 15}, "jx": {11}, "go": {12}, "sk": {13},
    "kahn": {13}, "goro": {12}, "jade": {16}, "noob": {15}, "smoke": {14},
}


def name_chars(hname):
    """do_jc_split -> {cage}.

    A handler that names its owner is not an `assumed` row, and treating it
    as one put Cage's split on Sub-Zero, Reptile, Scorpion and Smoke - four
    rows in the alignment audit for a move none of them has.
    """
    m = re.match(r"^(?:do|joy)_([a-z0-9]+)_", hname)
    return NAME_CHARS.get(m.group(1)) if m else None


def stk_setters():
    """strike index -> the routines that store it into `p_stk`.

    A handler is not the only thing that picks a strike record.  Projectiles
    and several specials set `p_stk` INLINE, deep in a routine body and often
    more than once - `movi 014h,a0 / move a0,*a13(p_stk)` sits eleven lines
    into MKPROP's dive, after two `mframew` calls - so the one-index-per-
    handler model the audits use cannot claim them without guessing.

    This does not try to. It just names who sets each index, which turns "129
    rows have no handler" into two answerable questions: which of them are set
    by a routine the model failed to attribute, and which are set by NOTHING
    at all.
    """
    out = collections.defaultdict(set)
    store = re.compile(r"\bmove\s+(a\d+),\*a13\(p_stk\)")
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        lines = read(path).splitlines()
        cur = None
        for i, ln in enumerate(lines):
            code = ln.split(';')[0].rstrip()
            if code[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', code)
                if m:
                    cur = m.group(1)
            m = store.search(code)
            if not m or not cur:
                continue
            reg = m.group(1)
            for j in range(i - 1, max(i - 8, -1), -1):
                code_j = lines[j].split(';')[0]
                # `clr a0` IS a setter, and index 0 is a real move: do_hi_kick
                # is `clr a0 / move a0,*a13(p_stk)`, so a scan for mov[ki]
                # alone reported every character's HIGH KICK as a record that
                # nothing selects.
                if re.search(r'\bclr\s+' + reg + r'\b', code_j):
                    out[0].add(cur)
                    break
                mm = re.search(r'\bmov[ki]\s+([^,]+),' + reg + r'\b', code_j)
                if mm:
                    v = num(mm.group(1))
                    if v is not None:
                        out[v].add(cur)
                    break
    return out


def parse_ochar_tables():
    """do_* -> set of ochar it is actually reachable for, for handlers that
    are dispatched through an ochar_* table (power punches and the like).
    Auditing do_swipe against all seventeen characters would invent rows."""
    limits = collections.defaultdict(set)
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        text = read(path)
        for m in re.finditer(r'^(ochar_[A-Za-z0-9_]+)\s*\n'
                             r'((?:\s*\.[lL][oO][nN][gG]\s+[^\n]*\n|\s*[;*][^\n]*\n|\s*\n)+)',
                             text, re.M):
            idx = 0
            for line in m.group(2).splitlines():
                code = line.split(';')[0].strip()
                mm = re.match(r'\.[lL][oO][nN][gG]\s+([A-Za-z_0-9]+)\s*$', code)
                if mm:
                    if mm.group(1).startswith("do_"):
                        limits[mm.group(1)].add(idx)
                    idx += 1
    return limits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gap", type=int, default=24,
                    help="also list overlapping boxes reaching this far past "
                         "the art; the primary finding is zero overlap")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    strips = parse_strips()
    frames_by_file, frames = parse_frames()
    text_all = "\n".join(read(p) for p in glob.glob(os.path.join(SRC, "*.ASM")))
    lanes, lane_file = {}, {}
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        for k, v in lane_lines(read(path)).items():
            if k not in lanes:
                lanes[k] = v
                lane_file[k] = path
    stk_text = read(os.path.join(SRC, "MKSTK.ASM"))
    recs, lists = parse_records(stk_text), parse_lists(stk_text)
    handlers = parse_handlers()
    anitabs = parse_anitabs(text_all)
    limits = parse_ochar_tables()

    rows, unresolved = [], []
    for hname, h in sorted(handlers.items()):
        # POSE IS ONLY RESOLVABLE FOR SOME ENTRY POINTS.  upcut_striker enters
        # the shared loop at attk5 with a9 ALREADY ADVANCED by
        # do_first_a9_frame, and an inline strike_check_a0 has the caller
        # driving its own frames, so neither has a single contact pose to
        # align against.  They carry real geometry and timing and belong in
        # the matrix; they do not belong in an alignment audit.
        if h["call"] in ("inline", "upcut_striker"):
            continue
        which = 2 if h["call"] == "striker_2" else 1
        allowed = limits.get(hname)
        by_name = name_chars(hname) if allowed is None else None
        if by_name:
            allowed = by_name
        for oc in range(len(CHARS)):
            if allowed is not None and oc not in allowed:
                continue
            lane = anitabs.get((oc, which, h["a9"]))
            if lane is None:
                continue
            lst = lists.get(CHAR_LIST[oc], [])
            if h["a11"] >= len(lst):
                continue
            rec = recs.get(lst[h["a11"]])
            if not rec or rec["x_off"] is None:
                continue
            local = frames_by_file.get(lane_file.get(lane), {})
            scope = dict(frames)
            scope.update(local)
            pose, prev, note = contact_pose(lane, lanes, scope)
            if pose is None:
                unresolved.append((hname, CHARS[oc], lane, note))
                continue
            span = pose_span(pose, scope, strips)
            if span is None:
                unresolved.append((hname, CHARS[oc], lane, "pose %s has no strips" % pose))
                continue
            box_l = rec["x_off"] - rec["x_size"]
            box_r = rec["x_off"]
            gap = box_l - span[1]          # >0 = box starts past the art
            pspan = pose_span(prev, scope, strips) if prev else None
            rows.append(dict(handler=hname, char=CHARS[oc], record=lst[h["a11"]],
                             lane=lane, pose=pose, span=span, prev=prev,
                             pspan=pspan, box=(box_l, box_r), gap=gap,
                             over=box_r - span[1],
                             reach=("handler name" if by_name else
                                    "ochar table" if allowed is not None
                                    else "assumed"),
                             note=note))

    print("# Strike box vs the frame it is live on\n")
    print("Generated by `tools/box_align_audit.py`.")
    print("`striker`/`striker_2` play part one of the animation and THEN hold")
    print("its last frame for the strike window, so that frame is what the box")
    print("has to match. Positive gap = the box starts that many pixels past")
    print("the right edge of what is drawn.\n")
    print("SCOPE: only handlers that dispatch through `striker` or `striker_2`.")
    print("A move that scans per tick inside its own flight loop - kahn_fly, and")
    print("MK3's sk_air_charge it is ported from - has no single contact pose to")
    print("align against, and is deliberately not listed here.\n")

    ov = sorted(r["over"] for r in rows)
    med = ov[len(ov) // 2] if ov else 0
    print("Across %d resolved moves the box reaches a median of %+d px past"
          % (len(rows), med))
    print("the art - a few pixels of grace on the end of a fist. That is the")
    print("scale a finding here has to be judged against.\n")

    print("MK3 IS NOT A DEFENCE AGAINST THIS. UMK3's `striker` (REV21/MKSTK.ASM)")
    print("is the same routine instruction for instruction - part one plays, then")
    print("its final pose is held for the scan. Anything ported over from MK3")
    print("inherits the same risk and has to be checked here too - and a box")
    print("ported with a move was sized for THAT GAME'S ART, which is a second")
    print("way for the two to disagree: MK3's `stk_sk_hammer` front edge is 086h")
    print("(134 px) while our BGHAMMERTOP6 hammer piece only draws to +126, so")
    print("8 px of the active box is empty air.\n")

    print("A PINNED RIG CANNOT CONFIRM A ROW FOR A MOVE THAT TRAVELS. Holding")
    print("the pair at a fixed distance overwrites oxpos before a lunge, charge")
    print("or dive can carry the attacker, so the rig reports the static box")
    print("rather than the move - Kahn's air knee measured 72 px that way and is")
    print("actually 224. Release the pin at move start, or check the handler")
    print("calls init_special -> stop_me and never sets a velocity.\n")

    print("## How this can be wrong - read before believing a row\n")
    print("A handler names one animation index and one strike index, and both")
    print("resolve PER CHARACTER. For a move dispatched through an `ochar_*`")
    print("table the reachable characters are known, and the row says")
    print("`ochar table`. Everything else is applied to all seventeen and says")
    print("`assumed` - and a character who cannot reach that handler produces")
    print("a row that looks alarming and means nothing. A resolved pose named")
    print("`*STANCE*` or `*DIE*` is the giveaway. Trust `ochar table` rows;")
    print("confirm `assumed` ones by hand.\n")

    # The giveaway two paragraphs up, applied instead of just described.
    # An `assumed` row whose contact pose is IDLE art - a stance, a walk, a
    # death - is a character who cannot reach that handler at all: Sub-Zero
    # resolving Kung Lao's backfist onto NJ1STANCE3 is not a misaligned box,
    # it is a move he does not have. These were invisible before the aliased
    # anitab fix (five characters had no lanes at all, so they produced no
    # rows); making them visible without separating them would have inflated
    # the headline count with rows the doc's own guidance says to discard.
    IDLE = ("STANCE", "WALK", "DIE", "SKIP", "TURN")

    # The bosses do not use the standard ani1 layout at all. The cast has 67
    # entries; Kintaro has 24 and Shao Kahn 26, laid out for their own move
    # sets - `ani1[21]` is a sweep for everybody else and `a_shredded` for
    # them. So an index-based lookup against a standard-cast handler is not
    # merely unreachable for a boss, it is meaningless, and the row it
    # produces says nothing about any box. Detected by table SHAPE rather
    # than by a list of names, so it keeps working if the tables move.
    lens = collections.Counter()
    for (oc, which, _idx) in anitabs:
        if which == 1:
            lens[oc] += 1
    standard = collections.Counter(lens.values()).most_common(1)[0][0] \
        if lens else 0
    odd_layout = {oc for oc, n in lens.items() if n != standard}

    def set_aside_reason(r):
        """Why this row is not evidence, or None if it is."""
        if r["reach"] in ("ochar table", "handler name"):
            return None
        if any(k in (r["pose"] or "").upper() for k in IDLE):
            return "pose is idle art"
        if r["char"] in CHARS and CHARS.index(r["char"]) in odd_layout:
            return "boss ani table, different layout"
        return None

    def unreachable(r):
        return set_aside_reason(r) is not None

    bad = [r for r in rows if r["gap"] > 0 and not unreachable(r)]
    parked = [r for r in rows if r["gap"] > 0 and unreachable(r)]
    bad.sort(key=lambda r: -r["over"])
    print("## Boxes with NO OVERLAP AT ALL against their contact pose (%d)\n"
          % len(bad))
    if not bad:
        print("none")
    else:
        print("| handler | char | reachable | record | contact pose | art | box "
              "| gap | box past art | previous frame | its art |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for r in bad:
            ps = ("%+d..%+d" % r["pspan"]) if r["pspan"] else ""
            print("| %s | %s | %s | %s | %s | %+d..%+d | %+d..%+d | %d | %+d | %s | %s |"
                  % (r["handler"], r["char"], r["reach"], r["record"], r["pose"],
                     r["span"][0], r["span"][1], r["box"][0], r["box"][1],
                     r["gap"], r["over"], r["prev"] or "", ps))
        print()
        print("Where the box fits the PREVIOUS frame's art and not the contact")
        print("pose, the record was authored one frame early - the animation")
        print("moved on before the strike window opened.")

    if parked:
        print("\n### Set aside: %d rows that are not evidence\n" % len(parked))
        print("Every one is an `assumed` row - the handler is not dispatched")
        print("through an `ochar` table, so it was applied to all seventeen")
        print("characters - and one of two things then gives it away:\n")
        print("* **pose is idle art** - it resolved onto a stance, walk or")
        print("  death frame, which means the character does not have the")
        print("  move (Sub-Zero does not have Kung Lao's backfist);")
        print("* **boss ani table** - Kintaro and Shao Kahn do not use the")
        print("  standard layout at all (24 and 26 entries against 67), so an")
        print("  index-based lookup against a normal-cast handler is")
        print("  meaningless for them: `ani1[21]` is a sweep for the cast and")
        print("  `a_shredded` for the bosses.\n")
        print("Neither says anything about a box. Listed so the count above")
        print("is honest.\n")
        print("| handler | characters | why |")
        print("|---|---|---|")
        by_h = collections.defaultdict(lambda: collections.defaultdict(list))
        for r in parked:
            by_h[r["handler"]][set_aside_reason(r)].append(r["char"])
        for hn in sorted(by_h):
            for why in sorted(by_h[hn]):
                print("| `%s` | %s | %s |"
                      % (hn, ", ".join(sorted(set(by_h[hn][why]))), why))

    # Same filter as above, for the same reason: this list was carrying
    # Cage's split resolved onto Sub-Zero and Kahn's high kick onto BGLAFF2.
    far_all = [r for r in rows if r["gap"] <= 0 and r["over"] >= args.gap]
    far = [r for r in far_all if not unreachable(r)]
    far_parked = len(far_all) - len(far)
    far.sort(key=lambda r: -r["over"])
    print("\n## Boxes that do overlap, but reach %d px or more past the art (%d)\n"
          % (args.gap, len(far)))
    if far_parked:
        print("(%d more set aside on the same two tests as above.)\n"
              % far_parked)
    if not far:
        print("none")
    else:
        print("| handler | char | reachable | record | contact pose | art | box "
              "| box past art |")
        print("|---|---|---|---|---|---|---|---|")
        for r in far:
            print("| %s | %s | %s | %s | %s | %+d..%+d | %+d..%+d | %+d |"
                  % (r["handler"], r["char"], r["reach"], r["record"], r["pose"],
                     r["span"][0], r["span"][1], r["box"][0], r["box"][1],
                     r["over"]))

    if args.all:
        print("\n## Every resolved move (%d)\n" % len(rows))
        print("| handler | char | reachable | record | pose | art | box | gap "
              "| box past art | note |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for r in sorted(rows, key=lambda r: (r["char"], r["handler"])):
            print("| %s | %s | %s | %s | %s | %+d..%+d | %+d..%+d | %d | %+d | %s |"
                  % (r["handler"], r["char"], r["reach"], r["record"], r["pose"],
                     r["span"][0], r["span"][1], r["box"][0], r["box"][1],
                     r["gap"], r["over"], r["note"] or ""))

    print("\n%d moves resolved, %d could not be (lane or strips missing)."
          % (len(rows), len(unresolved)))
    if unresolved and args.all:
        print()
        for h, c, lane, why in unresolved[:40]:
            print("- %s / %s / %s: %s" % (h, c, lane, why))


if __name__ == "__main__":
    main()
