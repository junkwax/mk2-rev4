#!/usr/bin/env python3
"""
frame_data.py - extract a frame-data table from the source.

Competitive play needs moves that can be LABELLED: how long they stay active,
how far they reach, what they do on hit and on block.  MK2 has never had that
published, and none of it is written down - it is split between the move
handlers (timing) and MKSTK.ASM (geometry and damage).

Two tables are emitted and they are DELIBERATELY NOT JOINED.  A handler like
do_swipe is Baraka-only, so expanding handlers across all 17 characters
invents rows such as "do_swipe / jade / stk_spinfan", which is worse than no
table at all.  Look a handler's stk index up in the character you care about.

STARTUP IS NOT HERE.  The windup is act_mframew playing an animation whose row
count lives in the per-character .TBL ani tables, indexed by a9.  That is a
separate parse; it is left out rather than guessed.  Everything below is read
straight out of the source.

Usage:
  python tools/frame_data.py
  python tools/frame_data.py --csv doc/frame_data.csv
"""
import re, sys, os, argparse, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

CHAR_LIST = {
    0: ("hathead", "hh_strikes"), 1: ("liu kang", "lk_strikes"),
    2: ("cage", "jc_strikes"), 3: ("baraka", "sa_strikes"),
    4: ("kitana", "fn_strikes"), 5: ("mileena", "fn_strikes"),
    6: ("shang", "st_strikes"), 7: ("raiden", "rd_strikes"),
    8: ("sub-zero", "nj_strikes"), 9: ("reptile", "nj_strikes"),
    10: ("scorpion", "nj_strikes"), 11: ("jax", "jx_strikes"),
    12: ("kintaro", "go_strikes"), 13: ("shao kahn", "sk_strikes"),
    14: ("smoke", "nj_strikes"), 15: ("noob", "nj_strikes"),
    16: ("jade", "fn_strikes"),
}

HANDLER_SRC = ("MOVES.ASM", "MKBOSS.ASM", "MKSA.ASM", "MKJX.ASM", "MKLK.ASM",
               "MKNJ.ASM", "MKST.ASM", "MKRD.ASM", "MKJC.ASM", "MKFN.ASM",
               "MKHH.ASM", "MKGORO.ASM")


def num(t):
    t = t.strip().split(';')[0].strip()
    if not t:
        return None
    try:
        return int(t[:-1], 16) if t[-1] in 'hH' else int(t, 0)
    except ValueError:
        return None


_EQU = None


def equates():
    """Every `name .set value` in src/, so a symbolic immediate resolves.

    `movk psleep,a0` (JOY.ASM) is a tick rate exactly like `movk 3,a0`, but
    num() returns None for it and the handler then reports no rate at all.
    Values that are themselves symbolic are resolved in a second pass; two
    passes is enough for everything in this tree.
    """
    global _EQU
    if _EQU is not None:
        return _EQU
    raw = {}
    pat = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)[ \t]+\.set[ \t]+([^;\r\n]+)',
                     re.M)
    for fn in os.listdir(SRC):
        if not fn.upper().endswith(('.ASM', '.H', '.HDR', '.EQU')):
            continue
        try:
            txt = open(os.path.join(SRC, fn), encoding='latin-1',
                       errors='replace').read()
        except OSError:
            continue
        for m in pat.finditer(txt):
            raw.setdefault(m.group(1), m.group(2).strip())
    out = {}
    for k, v in raw.items():
        n = num(v)
        if n is not None:
            out[k] = n
    for k, v in raw.items():
        if k in out:
            continue
        mm = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*([-+])\s*(\d+)$', v)
        if mm and mm.group(1) in out:
            out[k] = (out[mm.group(1)] + int(mm.group(3))
                      if mm.group(2) == '+' else
                      out[mm.group(1)] - int(mm.group(3)))
        elif v in out:
            out[k] = out[v]
    _EQU = out
    return out


def imm(t):
    """A numeric immediate, or an equate, or `equate-1`. None if neither."""
    n = num(t)
    if n is not None:
        return n
    t = t.strip().split(';')[0].strip()
    eq = equates()
    if t in eq:
        return eq[t]
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*([-+])\s*(\d+)$', t)
    if m and m.group(1) in eq:
        return (eq[m.group(1)] + int(m.group(3)) if m.group(2) == '+'
                else eq[m.group(1)] - int(m.group(3)))
    return None


def s16(v):
    return v - 0x10000 if v is not None and v >= 0x8000 else v


def parse_records(text):
    """Strike record = 6 .word, 1 .long (score), 1 .word (flags)."""
    # SKIP has to sit between EVERY field, not just after the label.
    # Requiring six back-to-back `.word` lines silently dropped 29 of the 233
    # records - among them every character's uppercut - because those records
    # carry a blank line and a commented-out older version in the middle.
    # A parser that drops a quarter of the uppercuts and says nothing is worse
    # than no table, and the balance audit reads this CSV.
    SKIP = r'(?:[ \t]*[;*][^\n]*\n|[ \t]*\n)*'
    W = SKIP + r'[ \t]*\.[wW][oO][rR][dD]\s+([^\n;]*?)\s*(?:;[^\n]*)?\n'
    pat = re.compile(
        r'^((?:stk_[A-Za-z0-9_]+[ \t]*\n)+)'
        r'((?:\s*[;*][^\n]*\n|\s*\n)*)'
        + W * 6 +
        SKIP + r'[ \t]*\.[lL][oO][nN][gG]\s+([^\n;]*?)\s*(?:;[^\n]*)?\n'
        + SKIP + r'[ \t]*\.[wW][oO][rR][dD]\s+([^\n;]*?)\s*(?:;[^\n]*)?(?:\n|$)',
        re.M)
    out = {}
    for m in pat.finditer(text):
        d = num(m.group(8))
        # Records are ALIASED: stk_jczap1/2/3/4 are four labels stacked on one
        # record, and matching only the last of them dropped the other three.
        rec = dict(
            x_off=s16(num(m.group(3))), y_off=s16(num(m.group(4))),
            x_size=num(m.group(5)), y_size=num(m.group(6)),
            routine=num(m.group(7)),
            hit=(d >> 8) & 0xff if d is not None else None,
            blk=d & 0xff if d is not None else None,
            flags=(m.group(10) or '').strip())
        for lbl in m.group(1).split():
            out[lbl] = rec
    return out


def parse_lists(text):
    """Character list -> [record, ...] BY POSITION.  The index comments in
    these lists are hexadecimal and have already caused one wrong-move bug."""
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


def parse_handlers():
    """do_* handlers -> a0 speed, a10 active, a11 stk index, on-hit sleep.
    Follows short `jruc` chains so shared tails (kick2) are picked up."""
    blocks = {}
    for fn in HANDLER_SRC:
        path = os.path.join(SRC, fn)
        if not os.path.exists(path):
            continue
        lines0 = open(path, encoding='latin-1',
                      errors='replace').read().splitlines()
        label_at0 = {}
        for i, ln in enumerate(lines0):
            if ln[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', ln)
                if m:
                    label_at0.setdefault(m.group(1), i)
        for name, start in label_at0.items():
            if not name.startswith('do_'):
                continue
            info = dict(file=fn, speed=None, active=None, stk=None,
                        call=None, hit_sleep=None)
            air = {}
            # `lines` / `label_at` are rebound when the scan follows the zap
            # table into MKZAP.ASM, and `guard` tracks the start of whatever
            # block we are currently inside - without it the very first line
            # after a jump is the target's own `do_` label and the scan breaks
            # on arrival.
            lines, label_at = lines0, label_at0
            guard = start
            i, hops, seen = start + 1, 0, set()
            while i < len(lines) and hops < 6:
                s = lines[i].split(';')[0].strip()
                if i != guard and re.match(r'^do_[A-Za-z0-9_]+', s):
                    break

                # The projectile indirection: `movi <index>,a0` then
                # `jruc local_zap` (or `jauc do_zap`).  Resolve the index
                # through projectile_jumps and carry on inside MKZAP.ASM.
                if re.match(r'^j(?:ruc|auc)\s+(?:local_zap|do_zap)$', s):
                    tbl = projectile_jumps()
                    idx = info.pop('_a0_imm', None)
                    # that a0 was the TABLE INDEX, never a tick rate - leaving
                    # it in place reports Noob's slide as running at 35 ticks
                    # a row
                    info['speed'] = None
                    if idx is None or not (0 <= idx < len(tbl)):
                        break
                    tgt = tbl[idx]
                    info['zap'] = (idx, tgt)
                    zl, za = _zap_source()
                    if tgt not in za:
                        break
                    # Do NOT hand the generic scan the rest of a zap handler.
                    # Inside one, a0 carries PROJECTILE VELOCITY - the first
                    # pass through here reported do_jc_zaphi at speed
                    # -655360 and do_jx_airzap at 524288, which are 16.16
                    # velocities being read as ticks per row.
                    #
                    # A launcher's honest number is the windup: the rate on
                    # the `jsrp mframew` that plays it, taken from the
                    # instruction that sets up that call and range-guarded,
                    # never from a scan that grabs whatever hit a0 first.
                    # Follow jumps inside MKZAP as well: do_jc_zaphi ends
                    # `jruc jczap4` and the windup lives at the shared tail,
                    # past do_jc_zaplo - a scan that stops at the next `do_`
                    # label finds nothing.  7 of 28 resolved without this.
                    # NO HOPS, and stop at the next top-level label.
                    #
                    # Following jumps here looked like it helped - it took the
                    # launcher count from 7 to 10 - and every one of the three
                    # it added was wrong.  do_spit has no `mframew` windup at
                    # all (it is `find_part2` / `face_sleep`), so the scan
                    # walked out of the routine, found somebody else's
                    # mframew, and paired it with a stale a9: Reptile's spit
                    # came out as 24 ticks off lane `a_acid_fly`, three times
                    # any other launcher and named after the PROJECTILE's
                    # flight rather than a windup.  A launcher whose windup is
                    # not in its own body is left out.
                    start_z, zseen = za[tgt], set()
                    za9, zwhich = None, 1
                    for _hop in range(1):
                        hopped = False
                        j = start_z + 1
                        while j < min(start_z + 80, len(zl)):
                            t = zl[j].split(';')[0].strip()
                            if re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', t) \
                                    or re.match(r'^do_[A-Za-z0-9_]+', t):
                                break
                            # a9 and which ani table, tracked on the way down:
                            # `clr a9 / calla get_char_ani2 / movk 2,a0 /
                            # jsrp mframew` is the whole windup contract.
                            mm = re.match(r'^clr\s+a9\b', t)
                            if mm:
                                za9 = 0
                            mm = re.match(r'^mov[ki]\s+([^,]+),a9\b', t)
                            if mm:
                                za9 = num(mm.group(1))
                            if re.search(r'\bcalla\s+get_char_ani2\b', t):
                                zwhich = 2
                            elif re.search(r'\bcalla\s+get_char_ani\b', t):
                                zwhich = 1
                            if re.search(r'\bjsrp\s+(?:act_)?mframew\b', t):
                                info['call'] = 'mframew'
                                info['zap_a9'] = za9
                                info['zap_which'] = zwhich
                                for k in range(j - 1, max(j - 4, start_z), -1):
                                    mm = re.search(r'\bmov[ki]\s+([^,]+),a0\b',
                                                   zl[k].split(';')[0])
                                    if mm:
                                        v = imm(mm.group(1))
                                        if v is not None and 1 <= v <= 20:
                                            info['speed'] = v
                                        break
                                break
                            mm = re.match(r'^j(?:ruc|auc)\s+(\w+)$', t)
                            if mm and mm.group(1) in za \
                                    and mm.group(1) not in zseen:
                                zseen.add(mm.group(1))
                                start_z = za[mm.group(1)]
                                hopped = True
                                break
                            j += 1
                        if not hopped:
                            break
                    break
                m = re.match(r'^mov[ki]\s+([^,]+),a0\b', s)
                if m:
                    v = num(m.group(1))
                    if v is not None:
                        info.setdefault('_a0_imm', v)
                for reg, key in (('a0', 'speed'), ('a10', 'active'), ('a11', 'stk')):
                    m = re.search(r'\bmov[ki]\s+([^,]+),' + reg + r'\b', s)
                    if m and info[key] is None:
                        info[key] = num(m.group(1))
                if re.search(r'\bclr\s+a11\b', s) and info['stk'] is None:
                    info['stk'] = 0

                # air_strike takes a DIFFERENT register contract to striker:
                # a1 = strike-check frames, a2 = animation rate (straight into
                # init_anirate), a3 = gravity.  The jump and flip attacks all
                # use it, and reading them as if they were striker calls is why
                # every air attack in the cast reported no tick rate.
                # Values go through imm() so an equate resolves, but only into
                # these two slots and only inside a plausible range - act_* and
                # the like are equates too, and a blanket resolve would turn
                # `movi act_juppunch,a0` into a fabricated rate.
                for reg, key, lo, hi in (('a2', 'speed', 1, 20),
                                         ('a1', 'active', 1, 60)):
                    m = re.search(r'\bmov[ki]\s+([^,]+),' + reg + r'\b', s)
                    if m and air.get(key) is None:
                        v = imm(m.group(1))
                        if v is not None and lo <= v <= hi:
                            air[key] = v
                m = re.search(r'\bjsrp\s+(air_strike)\b', s)
                if m:
                    info['call'] = 'air_strike'
                    if air.get('speed') is not None:
                        info['speed'] = air['speed']
                    if air.get('active') is not None:
                        info['active'] = air['active']
                    for j in range(i + 1, min(i + 14, len(lines))):
                        sm = re.match(r'\s*sleep\s+(\S+)',
                                      lines[j].split(';')[0])
                        if sm:
                            info['hit_sleep'] = imm(sm.group(1))
                            break
                    break

                m = re.search(r'\bjsrp\s+(\w*striker\w*)', s)
                if m:
                    info['call'] = m.group(1)
                    for j in range(i + 1, min(i + 6, len(lines))):
                        sm = re.match(r'\s*sleep\s+(\S+)', lines[j].split(';')[0])
                        if sm:
                            info['hit_sleep'] = num(sm.group(1))
                            break
                    break
                m = re.match(r'^jruc\s+(\w+)$', s)
                if m and m.group(1) in label_at and m.group(1) not in seen:
                    seen.add(m.group(1))
                    i = label_at[m.group(1)]
                    hops += 1
                    continue
                if s in ('retp', 'rets'):
                    break
                i += 1
            info.pop('_a0_imm', None)
            if info['active'] is not None or info['stk'] is not None \
                    or info.get('zap'):
                blocks[name] = info

    # NOT merged - see parse_mframew_handlers' docstring. The shape parses,
    # but the split it implies was falsified on the machine, and a wrong
    # frame-data number is worse than a missing one.
    return blocks


def projectile_jumps():
    """`projectile_jumps` (MKZAP.ASM) - a0 index -> the real handler label.

    Every ninja special and projectile enters through the same two lines:

        movi  023h,a0
        jruc  local_zap        -> clr a10 / jauc do_zap
                               -> sll 5,a0 / addi projectile_jumps,a0 / jump a0

    so the handler a strike index actually runs is one table lookup away, in
    ANOTHER FILE.  parse_handlers indexes labels per file, so the scan walked
    off the end of `do_noob_slide` into the next `do_` label and gave up -
    which is why 29 handlers, the whole projectile population, resolved to
    nothing at all.
    """
    path = os.path.join(SRC, "MKZAP.ASM")
    if not os.path.exists(path):
        return []
    txt = open(path, encoding='latin-1', errors='replace').read()
    m = re.search(r'^projectile_jumps\s*$', txt, re.M)
    if not m:
        return []
    out = []
    for line in txt[m.end():].splitlines():
        c = line.split(';')[0].strip()
        if not c:
            continue
        mm = re.match(r'\.[lL][oO][nN][gG]\s+([A-Za-z_][A-Za-z0-9_]*)', c)
        if mm:
            out.append(mm.group(1))
            continue
        if re.match(r'^[A-Za-z_]', c):
            break
    return out


_ZAP = None


def _zap_source():
    """MKZAP.ASM's lines and label index, loaded once.

    Kept separate from the per-file scan because a projectile stub and its
    real handler SHARE A NAME - `do_noob_slide` exists in MOVES.ASM (two
    lines: set the index, jump) and again in MKZAP.ASM (the actual move).
    Resolving the jump against the current file would land straight back on
    the stub.
    """
    global _ZAP
    if _ZAP is not None:
        return _ZAP
    path = os.path.join(SRC, "MKZAP.ASM")
    if not os.path.exists(path):
        _ZAP = ([], {})
        return _ZAP
    lines = open(path, encoding='latin-1', errors='replace').read().splitlines()
    at = {}
    for i, ln in enumerate(lines):
        if ln[:1] not in (' ', '\t', '*', ';', ''):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', ln)
            if m:
                at.setdefault(m.group(1), i)
    _ZAP = (lines, at)
    return _ZAP


def parse_mframew_handlers():
    """The standing punches - a SIXTH dispatch shape, in JOY.ASM.

    joy_hi_punch / joy_lo_punch never call striker at all.  Each link of the
    jab chain is:

        movk  psleep,a0  /  jsrp act_mframew     <- part one, at a0 ticks/row
        callr strike_check_a0                    <- one check
        movk  N,a10      /  jsrp punch_sleep     <- N more ticks, and
                                                    punch_sleep runs a strike
                                                    check on EVERY one of them

    so active is `1 + N`, not N - the box is live throughout punch_sleep
    (`callr strike_check_a0 ; additional strike checks`).  A collision sets
    a11 negative, which stops further checks without ending the window.

    Both immediates are read from the instruction that sets up each call,
    NOT by a general scan: `movk 2,a0` (the strike-table index) sits a few
    lines above the real rate, and a scan takes that first and reports the
    index as a tick rate.  Anchoring on the call site is what makes this safe.

    MEASURED, AND THE SPLIT DOES NOT HOLD - which is why nothing here is
    merged into parse_handlers.  `tools/sweep_addon_jab.lua` traced p_action
    for Liu Kang's standing HP with the stick forced neutral (the sweep walks
    P1 all fight, and back+HP is his BACKFIST, act_lkbackfist 010ch - the
    first run measured mostly that, and 6-tick runs that looked like a clean
    `active` were its tail).  Clean result: **18 ticks in act_hipunch, n=5,
    zero variance**, against the 9 + 6 = 15 this parse predicts.

    18 cannot be decomposed as rows x 3 + 5, so at least one of three
    assumptions is wrong: that part one is 3 rows for Liu Kang, that
    punch_sleep costs a10 ticks, or that act_hipunch spans exactly startup
    plus active and nothing else (joy_un_hi_punch1's retract may run under the
    same action).  Until that is settled the honest output is the measured
    TOTAL and no split.

    One concrete lead for whoever picks this up: `striker` has the SAME
    structure (`strike_check_a0 / sleep 1 / dsj a10`) and this tool counts its
    active window as plain `a10`, not `1 + a10`.  So the `1 +` here was already
    inconsistent with the tool's own convention.  Dropping it gives active 5
    and startup 13, which is not a multiple of 3 either - so the row count or
    act_hipunch's span is wrong too, and the answer is probably not a
    one-line correction.

    Kept as a parser, not as data: the shape is real, and the next person
    should not have to rediscover it.
    """
    out = {}
    for fn in ("JOY.ASM",):
        path = os.path.join(SRC, fn)
        if not os.path.exists(path):
            continue
        lines = open(path, encoding='latin-1',
                     errors='replace').read().splitlines()
        cur = None
        for i, ln in enumerate(lines):
            if ln[:1] not in (' ', '\t', '*', ';', ''):
                m = re.match(r'^(joy_[A-Za-z0-9_]+)', ln)
                cur = m.group(1) if m else cur
            s = ln.split(';')[0].strip()
            if not re.search(r'\bjsrp\s+act_mframew\b', s) or cur is None:
                continue
            if cur in out:
                continue
            rate = None
            for j in range(i - 1, max(i - 4, -1), -1):
                m = re.search(r'\bmov[ki]\s+([^,]+),a0\b',
                              lines[j].split(';')[0])
                if m:
                    v = imm(m.group(1))
                    if v is not None and 1 <= v <= 20:
                        rate = v
                    break
            # the window: one explicit check, then punch_sleep's a10 ticks,
            # each of which checks again
            active, stk = None, None
            for j in range(i + 1, min(i + 26, len(lines))):
                t = lines[j].split(';')[0].strip()
                if re.match(r'^joy_[A-Za-z0-9_]+', t):
                    break
                if re.search(r'\bjsrp\s+punch_sleep\b', t):
                    for k in range(j - 1, max(j - 4, -1), -1):
                        m = re.search(r'\bmov[ki]\s+([^,]+),a10\b',
                                      lines[k].split(';')[0])
                        if m:
                            v = imm(m.group(1))
                            if v is not None and 0 <= v <= 60:
                                active = 1 + v
                            break
                    break
            for j in range(max(i - 12, 0), i):
                m = re.search(r'\bmov[ki]\s+([^,]+),a0\b',
                              lines[j].split(';')[0])
                if m and 'p_stk' in (lines[j + 1] if j + 1 < len(lines) else ''):
                    stk = imm(m.group(1))
            if rate is not None and active is not None:
                out[cur] = dict(file=fn, speed=rate, active=active, stk=stk,
                                call='act_mframew', hit_sleep=None)
    return out


def emit(title, rows, hdr, note):
    print()
    print('## ' + title)
    print()
    print(note)
    print()
    print('| ' + ' | '.join(hdr) + ' |')
    print('|' + '|'.join(['---'] * len(hdr)) + '|')
    for r in rows:
        cells = []
        for k in hdr:
            v = r[k]
            cells.append('' if v == '' else ('?' if v is None else str(v)))
        print('| ' + ' | '.join(cells) + ' |')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--csv')
    args = ap.parse_args()

    text = open(os.path.join(SRC, 'MKSTK.ASM'), encoding='latin-1',
                errors='replace').read()
    recs, lists = parse_records(text), parse_lists(text)
    handlers = parse_handlers()

    recrows = []
    for oc, (cname, lname) in sorted(CHAR_LIST.items()):
        for idx, lbl in enumerate(lists.get(lname, [])):
            r = recs.get(lbl)
            if not r:
                continue
            recrows.append(dict(
                char=cname, idx='%02xh' % idx, record=lbl,
                reach=r['x_off'], box='%dx%d' % (r['x_size'], r['y_size']),
                y_off=r['y_off'], hit=r['hit'], blk=r['blk'],
                squeeze='yes' if 'squeeze' in r['flags'] else '',
                duck='yes' if 'duck' in r['flags'] else ''))

    movrows = [dict(
        handler=n, file=h['file'],
        stk_idx=('%02xh' % h['stk']) if h['stk'] is not None else None,
        active=h['active'], tpf=h['speed'], hitsleep=h['hit_sleep'],
        call=h['call'] or '',
        # where the move REALLY lives, when the handler is a two-line stub
        # that indexes projectile_jumps and jumps into MKZAP.ASM
        via=('%02xh -> %s' % h['zap']) if h.get('zap') else '')
        for n, h in sorted(handlers.items())]

    print('# MK2 frame data, extracted from source')
    print()
    print('Generated by `tools/frame_data.py`. Every value is read out of')
    print('MKSTK.ASM or a move handler - nothing is measured or estimated.')
    print()
    print('**Startup is not in this table.** The windup is `act_mframew`')
    print('playing an animation whose row count lives in the per-character')
    print('.TBL ani tables, indexed by a9. That is a separate parse and it is')
    print('left out rather than guessed.')
    print()
    print('**The two tables are not joined, on purpose.** A handler such as')
    print('`do_swipe` is Baraka-only; expanding handlers across all 17')
    print('characters invents rows like "do_swipe / jade / stk_spinfan".')
    print('Look a handler stk index up in the character you care about.')

    emit('A. Strike records - geometry and damage', recrows,
         ['char', 'idx', 'record', 'reach', 'box', 'y_off', 'hit', 'blk',
          'squeeze', 'duck'],
         'reach = x_offset, the FAR edge of the box from the anipoint. '
         'box = x_size by y_size.\n'
         'squeeze = the victim is narrowed to a QUARTER of his width for '
         'this move.')

    emit('B. Move handlers - timing', movrows,
         ['handler', 'file', 'stk_idx', 'active', 'tpf', 'hitsleep', 'call',
          'via'],
         'active = ticks `strike_check` runs. tpf = ticks per animation row '
         '(lower = faster).\n'
         'hitsleep = extra hangtime on hit. One tick = 18.28 ms.\n'
         '`via` = the handler is a two-line stub that indexes '
         '`projectile_jumps` and jumps\ninto MKZAP.ASM; the column names the '
         'routine the move actually runs. For those,\n`tpf` is the WINDUP '
         'rate on the launcher\'s `mframew` - the time to the projectile,\n'
         'not an active window, because the projectile carries its own '
         'strike record.')

    print()
    print('%d strike records across %d characters, %d move handlers.'
          % (len(recrows), len(CHAR_LIST), len(movrows)))

    if args.csv:
        import csv
        base = args.csv.rsplit('.', 1)[0]
        for nm, rows in (('_records', recrows), ('_moves', movrows)):
            with open(base + nm + '.csv', 'w', newline='', encoding='utf-8') as fh:
                w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)
        print('csv -> %s_records.csv and %s_moves.csv' % (base, base),
              file=sys.stderr)


if __name__ == '__main__':
    main()
