#!/usr/bin/env python3
"""
frame_advantage.py - startup, active and recovery for every move that resolves.

Closes sections 1.1 and 1.2 of doc/TOURNAMENT_READINESS.md: FRAME_DATA.md says
outright that "startup is not in this table", and recovery has never been
tabulated at all because it is not a property of the strike record - it is the
tail of each do_* handler.

  STARTUP   act_mframew holds each row of PART ONE for a0 ticks.
            startup = (sleeping rows in part one) x a0
            An `ani_nosleep` row is displayed and passed straight through, so
            it costs nothing - Baraka's swipe is 9 ticks from three sleeping
            rows at 3, not 12 from four rows.

  ACTIVE    a10, the striker loop's countdown. One strike_check per tick.

  RECOVERY  whatever the handler does after striker returns: any unconditional
            sleep, plus retract_strike playing the LATER parts of the lane at
            its own a0.

Validated tick by tick against a live capture of Baraka's Back+HP
(tools/sweep_addon_swipe.lua): measured 9 windup / 4 active / 4 hold / 5 / 5,
i.e. startup 9, active 4, recovery 14. The extractor must reproduce that or it
is wrong.

NOT HERE, and each is a real hole:

  * Moves whose handler does not resolve - see MOVE_MATRIX.md coverage.
  * Travelling moves and projectiles, for the reasons MOVE_MATRIX.md gives.

ON HIT is a RANGE, not a number, and both fighters decide it:

  * the reaction ROUTINE comes from `reaction_tables[ATTACKER ochar]`, indexed
    by the HIGH byte of the strike-routine word. strike_check reads
    `*a8(ochar)` and a8 is the attacker there - the tables are even named
    `react_to_hh`, `react_to_lk`, "react TO liu kang";
  * that routine supplies the `animate_a9` pair `[sleep:16 | index:16]`;
  * the row COUNT comes from the VICTIM's anitab, because animate_a9 calls
    get_char_ani in the victim's process.

So the sweep leaves the victim in 15 to 35 ticks of hitstun depending on who
was swept - the same move is -3 on one character and +17 on another, a 366 ms
swing. 37 of the 57 moves with an on-hit number vary by victim.

ON BLOCK is `blockstun - recovery_on_block`. There is NO `active - 1` term:
the strike loop exits on contact (`jrc attack_hit`), so the rest of the active
window is skipped rather than owed, and a connect ends the move SOONER than a
whiff.

A BLOCKED STRIKE IS A CONNECT. `striker` returns the carry it got from
strike_check, and strike_blocked ends `jruc yes_collision`, which sets it
exactly as a clean hit does - so a `jrnc` tail is paid on block too. This file
used to drop it from every on-block number, reading the kick family ~18 ticks
better on block than it is. Measured end to end
(tools/run_kick_recovery_test.ps1): the low kick ran 32 ticks on a whiff and 44
on EITHER a block or a hit.

A handler CAN tell the two apart itself by testing `b2`, strike_check's
blocked flag, and skipping its hangtime on a clean hit only.  That shape is
`hit_only`.  NO SHIPPING HANDLER USES IT: do_lo_kick did for one build and
it was reverted - the arithmetic worked (-18 became +0 on hit) and it played
wrong, because the leg snapped back the instant it connected.

Usage:
  python tools/frame_advantage.py
  python tools/frame_advantage.py --csv doc/frame_advantage.csv
  python tools/frame_advantage.py --char baraka
"""
import argparse
import collections
import csv
import glob
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BA = _load("ba", os.path.join(ROOT, "tools", "box_align_audit.py"))
MM = _load("mm", os.path.join(ROOT, "tools", "move_matrix.py"))
FD = _load("fd", os.path.join(ROOT, "tools", "frame_data.py"))

TICK_MS = 1000.0 / 54.7068          # T-Unit refresh, measured from the driver


def launcher_owners():
    """do_* launcher -> the ochars that can actually do it.

    A projectile launcher lives in MKZAP.ASM and its name carries no character
    (`do_spear`, `do_throw_ice`), so neither the `ochar` tables nor
    MM.name_chars resolves an owner - and without one the only alternative is
    to expand across all 17 characters and read whatever lane sits at the
    index, which credits Sub-Zero's floor ice to Baraka.

    The owner is at the DISPATCH site, not the definition.  Every one of these
    is reached by `movi do_spear,a7 / jruc restricted_xfer` from inside a
    per-character button routine - `sc_lo_punch`, i.e. Scorpion - so the
    enclosing label's prefix names the character through the same NAME_CHARS
    map move_matrix already uses.

    The label immediately above a dispatch is often an INNER one -
    `szlp_no_cool`, `fn1hp4` - so the walk goes back through preceding labels
    until one carries a known prefix, bounded to 150 lines so it can never
    cross into the next character's code and mislabel the move.
    """
    out = collections.defaultdict(set)
    ref = re.compile(r"\bmovi\s+(do_[A-Za-z0-9_]+),a7\b")

    def chars_of(label):
        m = re.match(r"^([a-z0-9]+)_", label)
        return MM.NAME_CHARS.get(m.group(1)) if m else None

    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        lines = BA.read(path).splitlines()
        labels = []                      # (line number, label)
        for i, ln in enumerate(lines):
            if ln[:1] not in (" ", "\t", "*", ";", ""):
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)", ln)
                if m:
                    labels.append((i, m.group(1)))
        for i, ln in enumerate(lines):
            m = ref.search(ln.split(";")[0])
            if not m:
                continue
            for at, lbl in reversed(labels):
                if at > i:
                    continue
                if i - at > 150:
                    break
                chars = chars_of(lbl)
                if chars:
                    out[m.group(1)] |= set(chars)
                    break
    return out


def parse_block_xfers():
    """index -> block reaction routine name, from block_xfers (MKREACT.ASM).

    strike_blocked (JOY.ASM) takes the LOW byte of the strike-routine word,
    shifts it by 5 (one long) and indexes this table.
    """
    txt = BA.read(os.path.join(SRC, "MKREACT.ASM"))
    m = re.search(r"^block_xfers\s*$", txt, re.M)
    if not m:
        return {}
    out, idx = {}, 0
    for line in txt[m.end():].splitlines():
        code = line.split(";")[0].strip()
        if not code:
            continue
        mm = re.match(r"\.[lL][oO][nN][gG]\s+([A-Za-z_][A-Za-z0-9_]*)", code)
        if mm:
            out[idx] = mm.group(1)
            idx += 1
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*", code):
            break
    return out


def parse_blockstun():
    """block reaction routine -> ticks of blockstun.

    block_shake (MKREACT.ASM) is `do_next_a9_frame / prcslp a11` twice, a10
    times, so the stun is 2 * a10 * a11 - and a10/a11 are set by the CALLER,
    which is why the same routine name always gives the same number but
    different reactions do not.
    """
    txt = BA.read(os.path.join(SRC, "MKREACT.ASM"))
    lines = txt.splitlines()
    label_at = {}
    for i, ln in enumerate(lines):
        if ln[:1] not in (" ", "	", "*", ";", ""):
            mm = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)", ln)
            if mm:
                label_at.setdefault(mm.group(1), i)
    out = {}
    for name, start in label_at.items():
        if not name.startswith(("b_", "r_")):
            continue
        regs, i, hops, seen = {}, start + 1, 0, set()
        while i < len(lines) and hops < 4:
            code = lines[i].split(";")[0].strip()
            mm = re.search(r"\bmov[ki]\s+([^,]+),(a\d+)\b", code)
            if mm:
                regs[mm.group(2)] = BA.num(mm.group(1))
            if re.search(r"\b(?:jsrp|jauc|calla|callr|jruc)\s+block_shake\b", code):
                a10, a11 = regs.get("a10"), regs.get("a11")
                if isinstance(a10, int) and isinstance(a11, int):
                    out[name] = 2 * a10 * a11
                break
            mm = re.match(r"^(?:jruc|jauc)\s+([A-Za-z_][A-Za-z0-9_]*)$", code)
            if mm and mm.group(1) in label_at and mm.group(1) not in seen:
                seen.add(mm.group(1))
                i = label_at[mm.group(1)]
                hops += 1
                continue
            if code in ("retp", "rets"):
                break
            i += 1
    return out


def parse_reaction_tables():
    """(attacker ochar, hit byte) -> hit reaction routine name.

    WHOSE CHARACTER PICKS THE TABLE MATTERS, and it is not the one the
    readiness sheet assumed. strike_check does `move *a8(ochar),a0,w` and a8 is
    still the ATTACKER there - a10 is the victim - so `reaction_tables` is
    indexed by who is HITTING. The table names say so too: react_to_hh,
    react_to_lk, "react TO liu kang".

    The victim's character enters later and separately: the routine ends in
    `animate_a9`, which calls get_char_ani in the VICTIM's process, so the row
    COUNT comes from the victim's anitab while the sleep and the lane index
    come from the attacker's routine.
    """
    txt = BA.read(os.path.join(SRC, "MKREACT.ASM"))

    def table_at(label):
        m = re.search(r"^%s\s*$" % re.escape(label), txt, re.M)
        if not m:
            return []
        out = []
        for line in txt[m.end():].splitlines():
            code = line.split(";")[0].strip()
            if not code:
                continue
            mm = re.match(r"\.[lL][oO][nN][gG]\s+([A-Za-z_]\w*)", code)
            if mm:
                out.append(mm.group(1))
                continue
            if re.match(r"^[A-Za-z_]\w*", code):
                break
        return out

    out = {}
    for oc, tname in enumerate(table_at("reaction_tables")):
        for idx, routine in enumerate(table_at(tname)):
            out[(oc, idx)] = routine
    return out


def parse_hitstun_args():
    """hit reaction routine -> (sleep, ani index) from its animate_a9 call.

    `movi 000030010h,a9` is [sleep:16 | index:16] - sleep 3 on lane 0x10.
    A routine that picks a different lane behind a branch (r_lopunched tests
    am_i_short) reports the LAST one seen, and the caller must treat those as
    one path.
    """
    txt = BA.read(os.path.join(SRC, "MKREACT.ASM"))
    lines = txt.splitlines()
    label_at = {}
    for i, ln in enumerate(lines):
        if ln[:1] not in (" ", "\t", "*", ";", ""):
            mm = re.match(r"^([A-Za-z_]\w*)", ln)
            if mm:
                label_at.setdefault(mm.group(1), i)
    out = {}
    for name, start in label_at.items():
        if not name.startswith("r_"):
            continue
        i, hops, last, branched = start + 1, 0, None, False
        while i < len(lines) and hops < 5:
            code = lines[i].split(";")[0].strip()
            mm = re.search(r"\bmovi\s+0?([0-9a-fA-F]{6,9})h,a9\b", code)
            if mm:
                if last is not None:
                    branched = True
                last = int(mm.group(1), 16)
            if (re.search(r"\b(?:jsrp|calla|jauc|jruc)\s+animate2?_a9\b", code)
                    and last is not None):
                out[name] = (last >> 16, last & 0xffff, branched)
                break
            mm = re.match(r"^(?:jruc|jauc)\s+([A-Za-z_]\w*)$", code)
            if mm and mm.group(1) in label_at:
                i = label_at[mm.group(1)]
                hops += 1
                continue
            if code in ("retp", "rets"):
                break
            i += 1
    return out


def parse_tails():
    """do_*/joy_* -> what the handler does AFTER the striker call.

    Returns {name: (unconditional_sleep, conditional_sleep, retract_tpf,
    branched, hit_only)} - the two sleep totals split at the first branch.

    A CONDITIONAL SLEEP IS NOT AUTOMATICALLY ON-HIT ONLY.  `striker` returns
    strike_check's carry, and a BLOCKED strike sets it too (strike_blocked
    ends `jruc yes_collision`), so a plain `jrnc` tail is paid on block as
    well - measured at tools/run_kick_recovery_test.ps1.  `hit_only` is True
    only when the handler tells the two apart itself, by testing b2 (the
    blocked flag strike_check documents) and skipping the sleep on a clean
    hit.  do_lo_kick is the one that does.
    """
    out = {}
    call = re.compile(r'\b(?:jsrp|jauc|jruc|calla|callr)\s+'
                      r'(striker_2|upcut_striker|behind_striker|air_strike|striker)\b')
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        lines = BA.read(path).splitlines()
        starts = {}
        for i, ln in enumerate(lines):
            if ln[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^((?:do|joy)_[A-Za-z0-9_]+)', ln)
                if m:
                    starts.setdefault(m.group(1), i)
        # FOLLOW jruc, exactly as parse_handlers does. do_hi_kick sets its
        # registers and jumps to kick2, where the striker call actually is; a
        # linear scan stops at the next do_ label first. do_lo_kick falls into
        # kick2 directly, so without this the two halves of ONE shared tail got
        # different answers - the low kick had a recovery and the high kick had
        # none, which is impossible and was the tell.
        label_at = {}
        for i, ln in enumerate(lines):
            if ln[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', ln)
                if m:
                    label_at.setdefault(m.group(1), i)

        for name, start in starts.items():
            at, i, hops, seen = None, start + 1, 0, set()
            while i < len(lines) and hops < 4:
                s = lines[i].split(';')[0].strip()
                if i != start and re.match(r'^(?:do|joy)_[A-Za-z0-9_]+', s):
                    break
                if call.search(s):
                    at = i
                    break
                m = re.match(r'^jruc\s+([A-Za-z_][A-Za-z0-9_]*)$', s)
                if m and m.group(1) in label_at and m.group(1) not in seen:
                    seen.add(m.group(1))
                    i = label_at[m.group(1)]
                    hops += 1
                    continue
                if s in ("retp", "rets"):
                    break
                i += 1
            if at is None:
                continue
            # Split the sleeps at the FIRST branch: the unconditional half is
            # paid however the move ends, the conditional half only on a
            # connect. Both halves are paid on BLOCK as well as on hit unless
            # the handler tests b2 - see the docstring.
            uncond, condsleep, tpf, cond, regs = 0, 0, None, False, {}
            hit_only = False
            segtab = None
            for i in range(at + 1, min(at + 40, len(lines))):
                s = lines[i].split(';')[0].strip()
                if re.match(r'^(?:do|joy)_[A-Za-z0-9_]+', s):
                    break
                m = re.match(r'^(?:sleep|prcslp)\s+(\S+)', s)
                if m:
                    v = BA.num(m.group(1))
                    if v is not None:
                        if cond:
                            condsleep += v
                        else:
                            uncond += v
                m = re.search(r'\bmov[ki]\s+([^,]+),(a\d+)\b', s)
                if m:
                    regs[m.group(2)] = BA.num(m.group(1))
                # `move b2,b2` + a branch is the handler splitting hit from
                # block for itself, so whatever sleep follows is on BLOCK only
                # and the clean-hit path skips it.
                if re.match(r'^move\s+b2\s*,\s*b2\b', s):
                    hit_only = True
                if re.match(r'^jr[a-z]{1,3}\s', s):
                    cond = True
                # retract_strike AND retract_strike_act, reached by jsrp, jauc
                # or a bare jruc tail jump. `retract_strike\b` does not match
                # `retract_strike_act` - the underscore is a word character -
                # and kick2, which is the shared tail for the high kick, low
                # kick and sweep, ends `jruc retract_strike_act`. Missing it
                # left every one of those moves with no recovery number.
                m = re.search(r'\b(?:jsrp|jauc|jruc|calla)\s+'
                              r'retract_strike(?:_act)?\b', s)
                if m:
                    tpf = regs.get("a0")
                    break
                # A PER-CHARACTER SEGMENT LIST instead of a single rate.
                # A handler can load an ochar table of [sleep,rows] lists and
                # walk it with mframew_a0 instead of handing retract_strike a
                # single rate, when one rate cannot give every character the
                # same recovery.  The total is then per character and already
                # absolute, so it is returned as `segtab` and used instead of
                # tpf * rows.  do_lo_kick did this for one build; no shipping
                # handler does now, but the shape is cheap to keep detecting.
                m = re.search(r'\bmovi\s+(ochar_\w+),a0\b', s)
                if m:
                    segtab = m.group(1)
                if re.search(r'\b(?:jsrp|jauc|calla)\s+mframew_a0\b', s) and segtab:
                    break
                if s in ("retp", "rets"):
                    break
            out[name] = (uncond, condsleep, tpf, cond, hit_only, segtab)
    return out


def parse_seg_totals(name):
    """ochar table of [sleep,rows] lists -> {ochar: total ticks}.

    The table is `.long <list>` per character and each list is a run of
    `.long 000SSSSRRRRh` entries terminated by 0, exactly what mframew_a0
    consumes. Summing sleep*rows gives the recovery that character actually
    owes, which is the number the advantage column needs.
    """
    txt = BA.read(os.path.join(SRC, "MOVES.ASM"))
    lines = txt.splitlines()

    def rows_after(label):
        out = []
        try:
            i = next(k for k, l in enumerate(lines)
                     if re.match(r'^%s\b' % re.escape(label), l))
        except StopIteration:
            return out
        for l in lines[i:]:
            body = l.split(';')[0]
            m = re.match(r'^(?:%s)?\s*\.long\s+(.+)$' % re.escape(label), body)
            if not m:
                if out:
                    break
                continue
            for tok in m.group(1).split(','):
                out.append(tok.strip())
            if out and out[-1] == '0':
                break
        return out

    lists = {}
    totals = {}
    for oc, entry in enumerate(rows_after(name)):
        if entry == '0' or not entry:
            continue
        if entry not in lists:
            segs, tot = rows_after(entry), 0
            for tok in segs:
                v = BA.num(tok)
                if v:
                    tot += (v >> 16) * (v & 0xffff)
            lists[entry] = tot
        totals[oc] = lists[entry]
    return totals


_SEG_CACHE = {}


def seg_totals(name):
    if name not in _SEG_CACHE:
        _SEG_CACHE[name] = parse_seg_totals(name)
    return _SEG_CACHE[name]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv")
    ap.add_argument("--char")
    args = ap.parse_args()

    strips = BA.parse_strips()
    frames_by_file, frames = BA.parse_frames()
    text_all = "\n".join(BA.read(p) for p in glob.glob(os.path.join(SRC, "*.ASM")))
    lanes, lane_file = {}, {}
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        for k, v in BA.lane_lines(BA.read(path)).items():
            if k not in lanes:
                lanes[k], lane_file[k] = v, path
    stk_text = BA.read(os.path.join(SRC, "MKSTK.ASM"))
    recs, lists = FD.parse_records(stk_text), BA.parse_lists(stk_text)
    handlers = BA.parse_handlers()
    timing = FD.parse_handlers()
    tabs = BA.parse_anitabs(text_all)
    limits = BA.parse_ochar_tables()
    tails = parse_tails()
    bxfer, bstun = parse_block_xfers(), parse_blockstun()
    rtab, hargs = parse_reaction_tables(), parse_hitstun_args()

    claims = collections.defaultdict(list)
    for hname, h in sorted(handlers.items()):
        which = 2 if h["call"] == "striker_2" else 1
        allowed = limits.get(hname)
        if allowed is None:
            allowed = MM.FILE_CHARS.get(h.get("file"))
        if allowed is None:
            allowed = MM.name_chars(hname)
        for oc in range(len(BA.CHARS)):
            if allowed is not None and oc not in allowed:
                continue
            claims[(oc, h["a11"])].append((hname, h, which,
                                           limits.get(hname) is not None))
    pick, ambiguous = {}, {}
    for key, cands in claims.items():
        known = [c for c in cands if c[3]]
        if known:
            pick[key] = known[0]
        elif len(cands) == 1:
            pick[key] = cands[0]
        else:
            names = sorted(c[0] for c in cands)
            if all(n.startswith("joy_") for n in names):
                base = min(names, key=len)
                pick[key] = [c for c in cands if c[0] == base][0]
            else:
                # Several handlers claim this index and none is confirmed by
                # an ochar table, so the picker refuses rather than guess -
                # that refusal is WHY the row has no handler, and saying so
                # is different from "nothing sets it".
                ambiguous[key] = names

    # Why a move has no numbers, not just how many do not. A bare count says
    # "98 missing" and points at nothing; the extraction has four distinct
    # failure points and they want different fixes, so count them separately.
    gaps = {"no handler": 0, "no ani lane": 0, "no tick rate": 0,
            "no part-one rows": 0}
    gap_eg = {}

    def note_gap(kind, label):
        gaps[kind] += 1
        gap_eg.setdefault(kind, []).append(label)

    rows = []
    for oc, cname in enumerate(BA.CHARS):
        for idx, label in enumerate(lists.get(BA.CHAR_LIST[oc], [])):
            got = pick.get((oc, idx))
            if not got:
                # keep the character with the label: a strike INDEX is
                # per-character, so any attribution that forgets `oc` will
                # credit one character's record to another's routine
                note_gap("no handler", "%d|%s" % (oc, label))
                continue
            hname, h, which, _known = got
            lane = tabs.get((oc, which, h["a9"]))
            if not lane:
                note_gap("no ani lane", "%s (%s)" % (label, hname))
                continue
            local = frames_by_file.get(lane_file.get(lane), {})
            scope = dict(frames)
            scope.update(local)
            pose, _prev, note, rows1 = BA.contact_pose_ex(lane, lanes, scope)
            t = timing.get(hname, {})
            tpf, active = t.get("speed"), t.get("active")
            startup = rows1 * tpf if (rows1 and tpf) else None
            if startup is None:
                note_gap("no tick rate" if not tpf else "no part-one rows",
                         "%s (%s)" % (label, hname))

            uncond, condsleep, rtpf, cond, hit_only, segtab = tails.get(
                hname, (None, None, None, False, False, None))
            rows2 = BA.part_rows(lane, lanes, 2)
            recovery = recovery_blk = None
            if uncond is not None:
                if segtab:
                    # Per-character segment list: the total is absolute, so it
                    # replaces tpf * rows rather than scaling it.
                    tail = seg_totals(segtab).get(oc)
                else:
                    tail = (rtpf * rows2) if (rtpf and rows2) else None
                if tail is None and rows2:
                    recovery = recovery_blk = None
                else:
                    tail = tail or 0
                    #
                    # ON HIT: the longest path.  For a handler that splits on
                    # b2 the conditional sleep is the BLOCK branch, so a clean
                    # hit does not pay it.
                    #
                    recovery = uncond + tail + (0 if hit_only else condsleep)
                    #
                    # ON BLOCK: the conditional sleep IS paid.  This used to be
                    # `uncond + tail`, on the stated grounds that a `jrnc` tail
                    # is on-hit hangtime.  It is not - a blocked strike sets
                    # the same carry a clean hit does, and the low kick was
                    # measured at 44 ticks end to end on a block and on a hit
                    # against 32 on a whiff.  Dropping it read every kick ~18
                    # ticks better on block than it is.
                    #
                    recovery_blk = uncond + tail + condsleep
            total = (startup + active + recovery
                     if None not in (startup, active, recovery) else None)
            r = recs.get(label) or {}
            # ON-BLOCK ADVANTAGE.  strike_blocked takes the LOW byte of the
            # strike-routine word as an index into block_xfers, and each
            # reaction there calls block_shake, whose stun is 2 * a10 * a11.
            # The attacker owes the rest of his active window plus all of his
            # recovery; the defender owes his blockstun.  Hit on the FIRST
            # active tick, which is the convention and the attacker's best case.
            rout = r.get("routine")
            bname = bxfer.get(rout & 0xff) if isinstance(rout, int) else None
            bs = bstun.get(bname)
            #
            # recovery_blk now INCLUDES a conditional tail, because a blocked
            # strike sets the same carry a hit does - see the note where it is
            # computed.  A handler that tests b2 to skip its hangtime on a
            # clean hit is the one exception, and cond_hit_only knows which.
            #
            # NO `active - 1` TERM.  striker's loop EXITS on contact
            # (`jrc attack_hit`), so the rest of the active window is SKIPPED,
            # not owed - the move ends sooner on a connect than on a whiff.
            # Measured: the low kick runs 32 ticks end to end on a whiff and
            # 26 on a clean hit, with the same 20-tick retract on both.
            # Adding (active - 1) charged the attacker for ticks he never
            # spent and read every multi-active-frame move worse than it is.
            #
            onblk = (bs - recovery_blk
                     if None not in (bs, recovery_blk) else None)

            # ON HIT. The reaction routine comes from the ATTACKER's table;
            # the sleep and lane index come with it; the ROW COUNT comes from
            # each VICTIM's own anitab. So hitstun is a spread, not a number,
            # and the spread is what is worth reporting.
            hname_r = rtab.get((oc, (rout >> 8) & 0xff)) if isinstance(rout, int) else None
            harg = hargs.get(hname_r)
            stuns = {}
            if harg:
                hsleep, hidx, hbranch = harg
                for voc, vname in enumerate(BA.CHARS):
                    vlane = tabs.get((voc, 1, hidx))
                    if not vlane:
                        continue
                    vr = BA.contact_pose_ex(vlane, lanes, frames)
                    if vr[0] is None:
                        continue
                    stuns[vname] = vr[3] * hsleep
            onhit_lo = onhit_hi = None
            if stuns and None not in (active, recovery):
                cost = recovery      # see the note at onblk
                onhit_lo = min(stuns.values()) - cost
                onhit_hi = max(stuns.values()) - cost
            rows.append(dict(
                char=cname, idx="%02xh" % idx, record=label, handler=hname,
                startup=startup, active=active, recovery=recovery, total=total,
                tpf=tpf, rows_startup=rows1 or None, rows_recovery=rows2,
                approx="~" if cond else "",
                block_reaction=bname or "", blockstun=bs, on_block=onblk,
                hit_reaction=hname_r or "",
                hitstun_lo=min(stuns.values()) if stuns else None,
                hitstun_hi=max(stuns.values()) if stuns else None,
                on_hit_lo=onhit_lo, on_hit_hi=onhit_hi,
                hit=r.get("hit"), blk=r.get("blk"), reach=r.get("x_off"),
                pose=pose or "", note=note or ""))

    if args.csv:
        out = args.csv if os.path.isabs(args.csv) else os.path.join(ROOT, args.csv)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print("csv -> %s (%d rows)" % (args.csv, len(rows)), file=sys.stderr)

    print("# Startup, active and recovery\n")
    print("Generated by `tools/frame_advantage.py`. Ticks, not milliseconds -")
    print("one tick is one display refresh at 54.7068 Hz, **%.2f ms**.\n" % TICK_MS)
    print("`~` means the handler BRANCHES between the strike loop and the")
    print("retract, so its tail is conditional: a whiff skips that sleep and")
    print("a CONNECT pays it.\n")
    print("**A blocked strike is a connect.** `striker` returns the carry it")
    print("got from strike_check, and strike_blocked ends `jruc yes_collision`,")
    print("which sets it exactly as a clean hit does - so a `jrnc` tail is paid")
    print("on block too, not on hit only. Measured end to end, the low kick")
    print("runs 32 ticks on a whiff and 44 on EITHER a block or a hit")
    print("(`tools/run_kick_recovery_test.ps1`). This file used to drop that")
    print("sleep from every on-block number, which read the whole kick family")
    print("about 18 ticks better on block than it is.\n")
    print("A handler CAN tell the two apart itself, by testing `b2` - the")
    print("blocked flag strike_check documents - and skipping its hangtime")
    print("on a clean hit; `hit_only` below detects that shape. **No")
    print("shipping handler does it.** do_lo_kick did for one build and it")
    print("was reverted: the arithmetic worked - -18 became +0 on hit - and")
    print("it played wrong, because the leg snapped back the instant it")
    print("connected. The hangtime is the impact.\n")
    print("**advantage = stun - recovery**, with no `active - 1` term. The")
    print("strike loop EXITS on contact (`jrc attack_hit`), so the rest of the")
    print("active window is skipped rather than owed - the low kick ends")
    print("in 44 ticks on a connect against 32 on a whiff. Charging the")
    print("attacker for ticks he never spends read every move with a long")
    print("active window worse than it is.\n")
    print("Blockstun comes from `block_xfers` indexed by the LOW byte of the")
    print("strike-routine word, and each reaction's `block_shake` is")
    print("2 x a10 x a11 - a four-value ladder of 4, 8, 12 and 16 ticks chosen")
    print("per REACTION, not per move.\n")
    print("**On-HIT advantage is still missing.** Hitstun is an `animate_a9`")
    print("reaction lane whose row count lives in the VICTIM's anitab, so the")
    print("same move has a different advantage depending on who you hit. That")
    print("is the remaining half of section 1.3.\n")

    ok = [r for r in rows if r["total"] is not None]
    print("Validated against a live tick-by-tick capture of Baraka's Back+HP:")
    sw = [r for r in rows if r["char"] == "baraka" and r["record"] == "stk_swipe"]
    if sw:
        r = sw[0]
        print("measured 9 startup / 4 active / 14 recovery; extracted "
              "**%s / %s / %s**.\n" % (r["startup"], r["active"], r["recovery"]))

    shown = [r for r in rows if not args.char or r["char"] == args.char]
    by = collections.defaultdict(list)
    for r in shown:
        by[r["char"]].append(r)
    for cname in BA.CHARS:
        rs = by.get(cname)
        if not rs:
            continue
        print("\n## %s\n" % cname)
        print("| move | record | startup | active | recovery | blockstun | "
              "on block | hitstun | on hit | dmg |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for r in sorted(rs, key=lambda r: (r["startup"] is None, r["startup"] or 0)):
            ob = ("%+d" % r["on_block"]) if r["on_block"] is not None else "-"
            hs = ("%d" % r["hitstun_lo"] if r["hitstun_lo"] == r["hitstun_hi"]
                  else "%d-%d" % (r["hitstun_lo"], r["hitstun_hi"]))                  if r["hitstun_lo"] is not None else "-"
            oh = ("%+d" % r["on_hit_lo"] if r["on_hit_lo"] == r["on_hit_hi"]
                  else "%+d..%+d" % (r["on_hit_lo"], r["on_hit_hi"]))                  if r["on_hit_lo"] is not None else "-"
            print("| %s | %s | %s | %s | %s%s | %s | **%s** | %s | %s | %s |"
                  % (r["handler"], r["record"],
                     r["startup"] if r["startup"] is not None else "-",
                     r["active"] if r["active"] is not None else "-",
                     r["recovery"] if r["recovery"] is not None else "-",
                     r["approx"],
                     r["blockstun"] if r["blockstun"] is not None else "-",
                     ob, hs, oh, r["hit"]))

    # ---- projectile launchers -------------------------------------------
    #
    # These CANNOT go in the table above, and the reason is structural rather
    # than a parsing limit: a launcher never sets p_stk.  `do_throw_spear` is
    # `clr a9 / get_char_ani2 / movk 2,a0 / jsrp mframew`, then it builds an
    # object and hands it a strike record of its own.  So there is no
    # (character, strike index) slot to file it under - the PROJECTILE owns
    # the box, the launcher owns only the windup.
    #
    # The windup is still the number a player asks for first: how long from
    # the button to the thing leaving your hand.
    launchers, unowned = [], []
    owners = launcher_owners()
    for hname, h in sorted(timing.items()):
        if not h.get("zap") or h.get("zap_a9") is None or not h.get("speed"):
            continue
        which, a9, tpf = h.get("zap_which", 1), h["zap_a9"], h["speed"]
        # The character set must be KNOWN, never assumed.  In the table above
        # a wrong guess is still pinned to a strike index; here there is no
        # such anchor, so "unrestricted" silently means all 17.  The first
        # run of this section did exactly that and produced rows like
        # `do_floor_ice / baraka / a_sa_spin` - Sub-Zero's move credited to
        # Baraka, running his SPIN as the windup - which is the invented-row
        # failure this tool's own header warns about.  A launcher whose owner
        # does not resolve is dropped and counted, not guessed at.
        allowed = owners.get(hname) or limits.get(hname) \
            or MM.name_chars(hname)
        if not allowed:
            unowned.append(hname)
            continue
        for oc in range(len(BA.CHARS)):
            if oc not in allowed:
                continue
            lane = tabs.get((oc, which, a9))
            if not lane:
                continue
            local = frames_by_file.get(lane_file.get(lane), {})
            scope = dict(frames)
            scope.update(local)
            _pose, _prev, _note, rows1 = BA.contact_pose_ex(lane, lanes, scope)
            if not rows1:
                continue
            launchers.append((BA.CHARS[oc], hname, h["zap"][1], lane,
                              rows1, tpf, rows1 * tpf))

    if launchers:
        print("\n## Projectile launchers - windup to release\n")
        print("Every special that throws something enters through two lines")
        print("(`movi <index>,a0` / `jruc local_zap`) and jumps through")
        print("`projectile_jumps` into MKZAP.ASM. **A launcher never sets")
        print("`p_stk`** - it plays a windup, then builds an object and gives")
        print("that object its own strike record. So these have no")
        print("(character, strike index) slot and cannot appear in the table")
        print("above: the projectile owns the box, the launcher owns the")
        print("windup. That windup is the number players ask for first.\n")
        print("| character | move | runs | lane | rows | ticks/row | "
              "windup |")
        print("|---|---|---|---|---|---|---|")
        for c, hn, tgt, lane, rows1, tpf, tot in launchers:
            print("| %s | `%s` | `%s` | `%s` | %d | %d | **%d ticks** |"
                  % (c, hn, tgt, lane, rows1, tpf, tot))
        print()
        print("Windup only. Recovery after the throw, and everything the")
        print("projectile itself does, are not in this table.")
    if unowned:
        print("\n**%d launchers resolved a lane and a rate but no OWNER** and"
              % len(set(unowned)))
        print("are therefore not listed: %s.\n"
              % ", ".join("`%s`" % u for u in sorted(set(unowned))))
        print("`ochar` tables and the handler name are the only two things")
        print("that say which characters a handler belongs to, and for these")
        print("neither resolves. Listing them anyway means expanding across")
        print("all 17 characters and reading whatever lane happens to sit at")
        print("that index — the first version of this section did that and")
        print("credited Sub-Zero's floor ice to Baraka, with his spin as the")
        print("windup. The owner is the missing piece, not the timing.")

    print("\n## Coverage\n")
    print("| | rows |")
    print("|---|---|")
    print("| moves with a resolved handler | %d |" % len(rows))
    print("| with startup | %d |" % sum(1 for r in rows if r["startup"] is not None))
    print("| with recovery | %d |" % sum(1 for r in rows if r["recovery"] is not None))
    print("| complete (startup + active + recovery) | %d |" % len(ok))
    print("| with an ON-BLOCK number | %d |"
          % sum(1 for r in rows if r["on_block"] is not None))
    print("| with an ON-HIT number | %d |"
          % sum(1 for r in rows if r["on_hit_lo"] is not None))
    print("| whose on-hit VARIES by victim | %d |"
          % sum(1 for r in rows if r["on_hit_lo"] is not None
                and r["on_hit_lo"] != r["on_hit_hi"]))
    print("| of those, one path only (`~`) | %d |"
          % sum(1 for r in ok if r["approx"]))

    print("\n### Where the missing rows are lost\n")
    print("Four separate failure points, counted separately because they want")
    print("different fixes. A move is dropped at the FIRST one it hits, so")
    print("these do not overlap.\n")
    print("| lost at | moves | what it means | example |")
    print("|---|---|---|---|")
    what = {
        "no handler": "no `do_`/`joy_` routine resolves for the strike index",
        "no ani lane": "handler resolves, but its `a9` names no lane in the "
                       "character's anitab",
        "no tick rate": "lane found, but no `movk N,a0` tick rate is "
                        "recoverable from the handler",
        "no part-one rows": "lane and rate found, but part one has no sleeping "
                            "rows to count",
    }
    for k in ("no handler", "no ani lane", "no tick rate", "no part-one rows"):
        eg = gap_eg.get(k, [])
        ex = eg[0].split("|")[-1] if eg else None
        print("| %s | %d | %s | %s |"
              % (k, gaps[k], what[k], ("`%s`" % ex) if ex else "-"))

    # A handler is shared by the whole cast, so one unparsed routine costs up
    # to 17 rows. Ranking by handler says how much a single fix is worth -
    # which is the difference between "88 missing" and "five routines".
    print("\nRanked by what one fix is worth - the handler behind each gap,")
    print("counted across the cast:\n")
    print("| lost at | handler | rows |")
    print("|---|---|---|")
    for k in ("no ani lane", "no tick rate", "no part-one rows"):
        tally = {}
        for lab in gap_eg.get(k, []):
            m = re.search(r"\(([^)]+)\)", lab)
            h = m.group(1) if m else "?"
            tally[h] = tally.get(h, 0) + 1
        for h, n in sorted(tally.items(), key=lambda kv: -kv[1])[:6]:
            print("| %s | `%s` | %d |" % (k, h, n))

    # Split the "no handler" bucket into the two questions it actually hides.
    setters = BA.stk_setters()
    by_setter, unowned_set, orphan = collections.defaultdict(set), [], []
    contested = []
    for tag in gap_eg.get("no handler", []):
        oc_s, lab = tag.split("|", 1)
        oc = int(oc_s)
        lst = lists.get(BA.CHAR_LIST[oc], [])
        if lab not in lst:
            continue
        idx = lst.index(lab)
        # Ambiguity is a THIRD reason, and it is the commonest one for a
        # normal: several handlers claim the index, none confirmed by an
        # ochar table, so the picker refuses. `stk_hhhikick` is not an
        # orphan - `do_hi_kick` sets index 0 with `clr a0` - it is contested.
        if (oc, idx) in ambiguous:
            contested.append((lab, ambiguous[(oc, idx)]))
            continue
        who = setters.get(idx)
        if not who:
            orphan.append(lab)
            continue
        # A strike index is PER CHARACTER. Naming a setter without checking
        # it belongs to this character credited stk_fnspinchop to
        # do_sa_leggrab and stk_ice1 to do_fan_swipe - Kitana's move to
        # Baraka's routine - because both use that index for their own record.
        mine = [r for r in who
                if BA.name_chars(r) and oc in BA.name_chars(r)]
        if mine:
            by_setter[lab].add(sorted(mine)[0])
        else:
            unowned_set.append(lab)

    print("\n### The 'no handler' bucket is two different problems\n")
    print("A handler is not the only thing that picks a strike record.")
    print("Projectiles and several specials store `p_stk` **inline**, deep in")
    print("a routine and often more than once — MKPROP's dive does")
    print("`movi 014h,a0 / move a0,*a13(p_stk)` eleven lines in, after two")
    print("`mframew` calls — so the one-index-per-handler model these tools")
    print("use cannot claim them without guessing, and guessing here is how")
    print("Baraka's sweep once got credited to `do_fn1_spinchop`.\n")
    print("| | rows | meaning |")
    print("|---|---|---|")
    print("| **contested** | %d | several handlers claim the index and none "
          "is confirmed, so the picker refuses to guess |" % len(contested))
    print("| a routine of THIS character sets the index | %d | attributable, "
          "but not by the handler model |"
          % sum(len(v) for v in by_setter.values()))
    print("| a routine sets it, owner unresolvable | %d | the setter sits "
          "under an inner label like `dive3`, or is shared |"
          % len(unowned_set))
    print("| **nothing anywhere sets it** | %d | the record is reached some "
          "other way, or is dead |" % len(orphan))
    if contested:
        print("\nContested — pick one and the row resolves:\n")
        print("| record | claimed by |")
        print("|---|---|")
        for lab, who in sorted(set((l, tuple(w)) for l, w in contested)):
            print("| `%s` | %s |" % (lab, ", ".join("`%s`" % w for w in who)))

    if by_setter:
        print("\nWho sets them — owner-checked, so a record is only ever")
        print("credited to a routine of its own character:\n")
        print("| record | set by |")
        print("|---|---|")
        for lab in sorted(by_setter)[:14]:
            print("| `%s` | `%s` |" % (lab, sorted(by_setter[lab])[0]))
    if orphan:
        seen = sorted(set(orphan))
        print("\n**%d distinct records that no routine anywhere selects.**"
              % len(seen))
        print("Most are projectile boxes — the flying object carries its own")
        print("record (see the launcher section), so no `do_`/`joy_` routine")
        print("ever names them. Any that are NOT projectiles are dead weight")
        print("in the strike table and worth a look:\n")
        for o in seen:
            print("* `%s`" % o)

    print("\n### The standing punches are measured but deliberately blank\n")
    print("`joy_hi_punch` / `joy_lo_punch` are a sixth dispatch shape: no")
    print("`striker` call at all, but `act_mframew` then one `strike_check_a0`")
    print("then `punch_sleep`, which runs a strike check on every one of its")
    print("`a10` ticks. Parsing it is easy and it would add 24 rows — the")
    print("most-used moves in the game — so it was built, and then it was")
    print("measured, and the measurement threw it out.\n")
    print("`tools/sweep_addon_jab.lua`, stick forced neutral, Liu Kang's")
    print("standing HP: **18 ticks in `act_hipunch`, n=5, zero variance.**")
    print("The parse predicts 9 startup + 6 active = 15. And 18 is not")
    print("`rows x 3 + 5` for any whole number of rows, so one of three")
    print("assumptions is wrong — the part-one row count, `punch_sleep`'s")
    print("cost, or the belief that `act_hipunch` covers startup and active")
    print("and nothing else (the retract may run under the same action).\n")
    print("Two traps worth keeping, both of which faked a clean answer first:")
    print("the sweep walks P1 all fight to stress the camera, so **back+HP is")
    print("Liu Kang's backfist** (`act_lkbackfist`, 010ch) and most taps were")
    print("measuring that; and at point-blank `elbow_check` turns HP into an")
    print("elbow (`act_elbow`, 0114h). The 6-tick runs that looked exactly")
    print("like a clean `active` of 1+5 were the backfist's tail.\n")
    print("The parser is kept in `frame_data.parse_mframew_handlers` and its")
    print("output is **not merged**. A missing row costs a player nothing; a")
    print("wrong one costs them the match.")


if __name__ == "__main__":
    main()
