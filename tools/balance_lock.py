#!/usr/bin/env python3
"""
balance_lock.py - make a balance change a deliberate act.

Section 8.1 of doc/TOURNAMENT_READINESS.md: Phase D already re-runs every
promoter in --check mode and fails the build on drift, so a stray edit to a
sprite table cannot ship silently. Balance has no equivalent. A strike box, a
damage byte, a blockstun constant, a combo window or one of the ruleset
switches can change and the build stays green.

This is the same shape as the promoters. It writes a readable digest of
everything that decides how the game plays:

  * every strike record - reach, box, y offset, routine word, hit, chip, flags
  * every block reaction's blockstun (2 * a10 * a11 from block_shake)
  * every special-move input window
  * the ruleset switches themselves (anchorcol, perpiece, stkphase, dmgscale,
    chipfloor, combo_slack, hitbox, secretwalk)

Readable on purpose, not an opaque hash: when the check fails you want to see
WHICH move changed and by how much, in the diff, without re-running anything.
The single hash at the end is for a build stamp or a checksum manifest.

  python tools/balance_lock.py            regenerate doc/balance.lock
  python tools/balance_lock.py --check    fail if it differs (Phase D)
  python tools/balance_lock.py --diff     show what changed, do not write
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
LOCK = os.path.join(ROOT, "doc", "balance.lock")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BA = _load("ba", os.path.join(ROOT, "tools", "box_align_audit.py"))
FD = _load("fd", os.path.join(ROOT, "tools", "frame_data.py"))
FA = _load("fa", os.path.join(ROOT, "tools", "frame_advantage.py"))
MB = _load("mb", os.path.join(ROOT, "tools", "mobility.py"))

SWITCHES = ["anchorcol", "colwidth", "colnarrow", "stkphase", "perpiece", "hitbox",
            "combo_slack", "combo_slack_online", "dmgscale", "chipfloor",
            "secretwalk", "twobtn_slack", "twobtn_depth", "blockspecial",
            "firstactive", "backblock", "joyskip", "deferhit", "airzap_once", "airland_recover", "airzap_minheight", "socdfix", "throwbtn", "saicool", "crossfix", "dko", "rdshockai",
            "rollpunish", "rollpush", "rollgrav",
            # Ermac's telekinetic slam: UMK3's q_ermac_slam gate (the hit-count
            # cap AND the connect-stamped cooldown - both are balance, and
            # the cap alone is an infinite while the cooldown alone is a
            # dead move) plus its own dmgscale
            # cut, plus the throws' (Jax's multi-slam is the one that bites).
            # jax_wham_damage and jax_extra_slams are locked because together
            # they ARE the multi-slam's damage - 4 slams of 10 was 40 of the 58
            # that throw used to do.
            "ermtkgate", "erm_tks_maxhit", "erm_tks_cool",
            "ermtkscale", "throwscale",
            "jax_extra_slams", "jax_wham_damage",
            # Two retail omissions found mining the leak's own comments
            # (tools/extract_dev_comments.py): Liu Kang's fireball skipping
            # the airborne separation, and a P2 Jax's wave spawning in P1's
            # projectile slot. Both change what happens in a fight.
            "lkzapair", "jaxzappid",
            # Midway's shelved drone_flip_punch, restored (MKDRNEW drone_fp_try):
            # the CPU's jump-in can carry a punch. Changes what the CPU does.
            "drnflipp"]
# Adding a ruleset switch to MAINEQU.ASM and forgetting it here is a silent
# hole in this guard: the switch moves, the lock still matches, and nothing
# reports that the game plays differently. `colwidth` and `backblock` were
# both missing on the day they were written.


def switches():
    txt = BA.read(os.path.join(SRC, "MAINEQU.ASM"))
    out = []
    for name in SWITCHES:
        m = re.search(r"^%s\s+\.set\s+(\S+)" % re.escape(name), txt, re.M)
        out.append((name, m.group(1).strip() if m else "MISSING"))
    return out


def combo_windows():
    """scom_* -> the input window in ticks (the record's first .word)."""
    out = {}
    pat = re.compile(r"^(scom_[A-Za-z0-9_]+)\s*\n\s*\.[wW][oO][rR][dD]\s+0?([0-9a-fA-F]+)h",
                     re.M)
    for fn in ("MOVES.ASM", "MKBABY.ASM"):
        p = os.path.join(SRC, fn)
        if not os.path.exists(p):
            continue
        for m in pat.finditer(BA.read(p)):
            out[m.group(1)] = int(m.group(2), 16)
    return out


def pushbacks(txt):
    """(handler, kind, [values]) for every r_*/b_* that shoves somebody.

    Walks each reaction handler's body and records the magnitude fed to
    away_x_vel, or the pair fed to repell_one_of_us. Both are `movi <n>,a0`
    (and `movi <n>,a1`) immediately before the call, which is how every one
    of them is written.
    """
    out = []
    lines = txt.splitlines()
    label = None
    pend = {}
    for ln in lines:
        s = ln.split(';')[0].rstrip()
        if s[:1] not in (' ', '\t', '*', ''):
            m = re.match(r'^([rb]_[A-Za-z0-9_]+)', s)
            label = m.group(1) if m else None
            pend = {}
            continue
        if label is None:
            continue
        t = s.strip()
        m = re.match(r'^movi?\s+([0-9A-Fa-f][0-9A-Fa-f]*h|\d+)\s*,\s*(a0|a1)\b', t)
        if m:
            pend[m.group(2)] = m.group(1)
            continue
        if re.search(r'\b(?:calla|callr|jauc|jruc)\s+away_x_vel\b', t):
            if "a0" in pend:
                out.append((label, "away", [pend["a0"]]))
            pend = {}
        elif re.search(r'\b(?:calla|callr)\s+repell_one_of_us\b', t):
            if "a0" in pend and "a1" in pend:
                out.append((label, "repell", [pend["a0"], pend["a1"]]))
            pend = {}
    return sorted(out)


def build_lock():
    lines = []
    lines.append("# balance.lock - generated by tools/balance_lock.py")
    lines.append("# Every value here decides how the game PLAYS. A diff in this")
    lines.append("# file is a balance change, and Phase D fails the build until")
    lines.append("# it is regenerated on purpose.")
    lines.append("")

    lines.append("[switches]")
    for name, val in switches():
        lines.append("%-20s %s" % (name, val))
    lines.append("")

    stk = BA.read(os.path.join(SRC, "MKSTK.ASM"))
    recs = FD.parse_records(stk)
    lines.append("[strike records]  reach box y_off routine hit chip flags")
    for name in sorted(recs):
        r = recs[name]
        lines.append("%-24s %5s %4sx%-4s %5s %6s %4s %4s %s" % (
            name, r["x_off"], r["x_size"], r["y_size"], r["y_off"],
            r.get("routine"), r["hit"], r["blk"], (r["flags"] or "").strip()))
    lines.append("")

    bx, bs = FA.parse_block_xfers(), FA.parse_blockstun()
    lines.append("[blockstun]  index -> reaction -> ticks")
    for idx in sorted(bx):
        name = bx[idx]
        lines.append("%02xh %-20s %s" % (idx, name, bs.get(name, "-")))
    lines.append("")

    cw = combo_windows()
    lines.append("[combo windows]  ticks")
    for name in sorted(cw):
        lines.append("%-28s %d" % (name, cw[name]))
    lines.append("")

    # Mobility - the gap section 8.1 named, closed once tools/mobility.py made
    # these extractable. Walk is per character; the jump constants are one set
    # shared by the whole cast, so a change there moves everybody at once.
    guys = BA.read(os.path.join(SRC, "MKGUYS.ASM"))
    eqs = BA.read(os.path.join(SRC, "MAINEQU.ASM"))
    fwd = MB.walk_table(guys, "walk_forward_info")
    bwd = MB.walk_table(guys, "walk_backward_info")
    lines.append("[walk]  character  fwd_rate fwd_vel  back_rate back_vel")
    for oc, name in enumerate(MB.CHARS):
        f = fwd[oc] if oc < len(fwd) else ("-", "-")
        b = bwd[oc] if oc < len(bwd) else ("-", "-")
        lines.append("%-12s %5s %6s %6s %6s" % (name, f[0], f[1], b[0], b[1]))
    lines.append("")
    lines.append("[jump]  shared by the whole cast")
    for nm in ("up_vel", "up_grav", "angle_grav"):
        lines.append("%-12s %s" % (nm, MB.equate(eqs, nm)))
    lines.append("")

    # PUSHBACK.  How far a hit or a block separates the two fighters decides
    # whether a poke can be repeated on its own recovery, so it is a balance
    # value in exactly the way a strike box is - and it was NOT locked. The
    # low-kick pass moved four of these and the lock stayed green, which is
    # the hole this closes.
    #
    # away_x_vel takes one magnitude; repell_one_of_us takes two (mine, his)
    # and picks by who is cornered. Both are recorded per reaction handler,
    # which is the granularity they are written at.
    react = BA.read(os.path.join(SRC, "MKREACT.ASM"))
    lines.append("[pushback]  reaction -> away_x_vel / repell_one_of_us(me,him)")
    for name, kind, vals in pushbacks(react):
        lines.append("%-24s %-8s %s" % (name, kind, " ".join(vals)))
    lines.append("")

    body = "\n".join(lines)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return body + "\n[digest]\nsha256 %s\n" % digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the lock is out of date")
    ap.add_argument("--diff", action="store_true",
                    help="print what changed without writing")
    args = ap.parse_args()

    fresh = build_lock()
    have = None
    if os.path.exists(LOCK):
        have = open(LOCK, encoding="utf-8", newline="").read()

    if args.check or args.diff:
        if have is None:
            print("balance.lock does not exist yet - run: "
                  "python tools/balance_lock.py")
            sys.exit(1 if args.check else 0)
        if have == fresh:
            n = sum(1 for l in fresh.splitlines()
                    if l and not l.startswith(("#", "[")))
            print("  balance.lock OK (%d locked values)" % n)
            return
        d = list(difflib.unified_diff(
            have.splitlines(), fresh.splitlines(),
            fromfile="balance.lock (committed)", tofile="source (now)",
            lineterm="", n=0))
        print("BALANCE CHANGED - %d differing lines:" % sum(
            1 for l in d if l[:1] in "+-" and not l.startswith(("---", "+++"))))
        for l in d[:60]:
            print("  " + l)
        if len(d) > 60:
            print("  ... %d more" % (len(d) - 60))
        print()
        print("If that was deliberate, regenerate it:")
        print("  python tools/balance_lock.py")
        sys.exit(1 if args.check else 0)

    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, "w", encoding="utf-8", newline="") as fh:
        fh.write(fresh)
    n = sum(1 for l in fresh.splitlines() if l and not l.startswith(("#", "[")))
    print("wrote doc/balance.lock (%d values)" % n)
    if have is not None and have != fresh:
        print("NOTE: this OVERWROTE an existing lock - the balance changed.")


if __name__ == "__main__":
    main()
