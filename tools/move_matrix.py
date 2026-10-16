#!/usr/bin/env python3
"""
move_matrix.py - every move, every character: geometry, damage, timing, and a
PREDICTED connect range - computed from the source, then checked against live
measurement by tools/sweep_addon_bands.lua.

Why computed and not driven: exhaustively firing every move at every range is
~15,000 MAME trials, and every input-driven rig in this project has failed
silently at least once (misfires, a trial cadence beating against a move's
recovery, knee_check quietly turning a high kick into a knee, fighters pinned
outside the camera). A matrix built that way is confidently wrong in places
nobody can see. Everything geometric is exact in the source, so compute it and
spend the emulator on VALIDATING a sample instead.

The model, straight out of the two routines that implement it:

  strike box   oxpos + x_offset - x_size .. oxpos + x_offset    (strike_check,
               JOY.ASM, facing right; mirrored on b_fliph)
  hit column   victim oxpos +/- W/8                             (sq_punch with
               anchorcol, W = the victim's multipart width)
  connect      x_offset - x_size - W/8 .. x_offset + W/8

WHAT THIS DOES NOT COVER, and each is a real hole rather than an omission:

  * TRAVELLING moves. A lunge, charge or dive carries the attacker while the
    box is live, so its real reach is start distance plus travel. Kahn's air
    knee is 224 px live against a 72 px static box.
  * PROJECTILES. The box is anchored on the projectile object, not the
    fighter, so "reach" is travel over time and a static band is meaningless.
    They are excluded rather than reported wrongly.
  * The near edge at point blank. `repell` shoves fighters apart, so measured
    bands start closer than predicted (uppercut: predicts 23, measures 16).
  * BLOCK ADVANTAGE. Recovery is here; blockstun is a property of the block
    reaction routine and is not parsed yet, so punish windows are NOT claimed.

Usage:
  python tools/move_matrix.py                    markdown to stdout
  python tools/move_matrix.py --csv doc/move_matrix.csv
  python tools/move_matrix.py --char baraka
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
FD = _load("fd", os.path.join(ROOT, "tools", "frame_data.py"))

# Measured fallback when a character's stance lane will not resolve. The eight
# that do resolve run 59-71 px, so the column half-width runs 7-9 px; 64 is the
# middle of that and the error it can introduce is +/-1 px on a band edge.
DEFAULT_W = 64

# Which characters a per-character module's handlers can belong to. Files not
# listed here - MOVES.ASM, JOY.ASM, MKPROP.ASM and the rest of the shared
# machinery - are treated as reachable by anyone.
FILE_CHARS = {
    "MKHH.ASM": {0}, "MKLK.ASM": {1}, "MKJC.ASM": {2}, "MKSA.ASM": {3},
    "MKFN.ASM": {4, 5, 16}, "MKMILEE.ASM": {5}, "MKST.ASM": {6},
    "MKRD.ASM": {7}, "MKNJ.ASM": {8, 9, 10, 14, 15}, "MKJX.ASM": {11},
    "MKGORO.ASM": {12}, "MKBOSS.ASM": {13}, "MKSK.ASM": {13},
}


# Live measurements the prediction has actually been checked against. Each is
# a full range map from a rig that verified the move fired on every trial -
# tools/sweep_addon_swipe.lua and tools/sweep_addon_behind.lua, both run on
# this build. Anything not in this table is PREDICTED AND UNCHECKED, and the
# matrix says so rather than presenting every row as equally solid.
MEASURED = {
    ("baraka", "stk_swipe"): (20, 108, "sweep_addon_swipe.lua, 41/41 fired"),
    ("baraka", "stk_sauppercut"): (16, 84, "sweep_addon_behind.lua, 28/28 fired"),
}



# The project's own naming convention is a third dispatch fact, and CLAUDE.md
# writes it down: handlers carry a two-letter character prefix. do_hh_backfist
# is Kung Lao's and do_lk_backfist is Liu Kang's, and both live in MOVES.ASM
# so the file rule cannot separate them - together they made every character's
# high kick unresolvable. Longest prefix wins, so fn1/fn2 beat fn.
# The canonical copy now lives in box_align_audit - the lowest of the three
# modules and the one that also needs it, to keep Cage's split off Sub-Zero.
# Re-exported here so existing callers (frame_advantage uses MM.NAME_CHARS)
# keep working against one table rather than two that can drift apart.
NAME_CHARS = BA.NAME_CHARS
name_chars = BA.name_chars

def stance_widths(tabs, lanes, frames, strips):
    out = {}
    for oc in range(len(BA.CHARS)):
        lane = tabs.get((oc, 1, 0))
        w = None
        if lane:
            pose, _prev, _note = BA.contact_pose(lane, lanes, frames)
            if pose:
                sp = BA.pose_span(pose, frames, strips)
                if sp:
                    w = sp[1] - sp[0]
        out[oc] = w
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv")
    ap.add_argument("--char", help="limit the markdown to one character")
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
    recs = FD.parse_records(stk_text)
    lists = BA.parse_lists(stk_text)
    handlers = BA.parse_handlers()
    timing = FD.parse_handlers()
    tabs = BA.parse_anitabs(text_all)
    limits = BA.parse_ochar_tables()
    widths = stance_widths(tabs, lanes, frames, strips)

    # ENUMERATE FROM THE STRIKE TABLES, not from the handlers.  Driving it off
    # handlers produced 99 rows and quietly omitted every move whose handler
    # does not name an animation index in the pattern the parser reads - the
    # uppercut among them, because do_uppercut advances a9 through
    # do_first_a9_frame before calling upcut_striker.  A matrix that is missing
    # the uppercut is not a matrix of every move.  Each character's list IS the
    # complete set of what that character can hit with; handler timing and the
    # contact pose are joined on where they resolve, and left blank where they
    # do not, so a hole reads as a hole.
    # A STRIKE INDEX DOES NOT IDENTIFY A HANDLER.  Index 4 is the sweep for
    # Baraka and the spin chop for Kitana, and both handlers claim it for all
    # seventeen characters because neither is dispatched through an ochar_*
    # table.  Letting the last one win credited Baraka's sweep to
    # do_fn1_spinchop and his high punch to do_sz_tornado - a confidently
    # wrong name on a row, which is worse than a blank one.
    #
    # So: a handler whose reachable set is KNOWN wins its slot outright; among
    # handlers that merely might apply, one claimant is accepted and several
    # are reported as ambiguous rather than resolved by alphabet.
    claims = collections.defaultdict(list)
    for hname, h in sorted(handlers.items()):
        which = 2 if h["call"] == "striker_2" else 1
        allowed = limits.get(hname)
        if allowed is None:
            # THE FILE IS ALSO A DISPATCH FACT.  A handler defined in
            # MKFN.ASM is Kitana/Mileena/Jade code and cannot be reached by
            # Baraka, whatever strike index it names - so `do_fn1_spinchop`
            # has no business claiming his sweep slot.  This is weaker
            # evidence than an ochar_* table, so it is tracked separately.
            allowed = FILE_CHARS.get(h.get("file"))
            if allowed is None:
                allowed = name_chars(hname)
        for oc in range(len(BA.CHARS)):
            if allowed is not None and oc not in allowed:
                continue
            known = limits.get(hname) is not None
            claims[(oc, h["a11"])].append((hname, h, which, known))

    handler_for = {}
    ambiguous, also = {}, {}
    for key, cands in claims.items():
        known = [c for c in cands if c[3]]
        if known:
            handler_for[key] = known[0]
        elif len(cands) == 1:
            handler_for[key] = cands[0]
        else:
            names = sorted(c[0] for c in cands)
            if all(n.startswith("joy_") for n in names):
                # joy_hi_punch, joy_punch_mth1 and joy_punch_mth2 are one
                # button checking the same record again later in a string, not
                # three different moves. Name the entry point and list the
                # continuations rather than calling it unresolvable.
                base = min(names, key=len)
                handler_for[key] = [c for c in cands if c[0] == base][0]
                if len(names) > 1:
                    also[key] = [n for n in names if n != base]
            else:
                ambiguous[key] = names

    rows = []
    for oc, cname in enumerate(BA.CHARS):
        lst = lists.get(BA.CHAR_LIST[oc], [])
        w = widths.get(oc) or DEFAULT_W
        half = w // 8
        for idx, label in enumerate(lst):
            r = recs.get(label)
            if not r or r["x_off"] is None or r["x_size"] is None:
                continue
            hname, h, which, known = handler_for.get((oc, idx),
                                                     (None, None, None, False))
            amb = ambiguous.get((oc, idx))
            cont = also.get((oc, idx))
            t = timing.get(hname, {}) if hname else {}
            pose, span, note = None, None, ""
            # same limitation as the alignment audit: these two have no
            # single held pose, so leave it blank rather than resolve the
            # wrong lane index and print a confident wrong answer
            if h is not None and h["call"] not in ("inline", "upcut_striker"):
                lane = tabs.get((oc, which, h["a9"]))
                if lane:
                    local = frames_by_file.get(lane_file.get(lane), {})
                    scope = dict(frames)
                    scope.update(local)
                    pose, _prev, note = BA.contact_pose(lane, lanes, scope)
                    if pose:
                        span = BA.pose_span(pose, scope, strips)
            near = r["x_off"] - r["x_size"]
            rows.append(dict(
                char=cname, idx="%02xh" % idx, record=label,
                handler=hname or "", reach=r["x_off"], near_edge=near,
                box="%dx%d" % (r["x_size"], r["y_size"]), y_off=r["y_off"],
                hit=r["hit"], blk=r["blk"],
                squeeze="yes" if "squeeze" in (r["flags"] or "") else "",
                duck="yes" if "duck" in (r["flags"] or "") else "",
                active=t.get("active"), tpf=t.get("speed"),
                hitsleep=t.get("hit_sleep"),
                pose=pose or "", art=("%d..%d" % span) if span else "",
                band_lo=near - half, band_hi=r["x_off"] + half,
                reachable=("ochar table" if known else
                           ((("also " + ", ".join(cont)) if cont
                             else "one claimant") if hname else
                            ("ambiguous: " + ", ".join(amb)) if amb
                            else "no handler found")),
                note=note or "",
            ))

    if args.csv:
        out = args.csv if os.path.isabs(args.csv) else os.path.join(ROOT, args.csv)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", newline="", encoding="utf-8") as fh:
            wtr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            wtr.writeheader()
            wtr.writerows(rows)
        print("csv -> %s (%d rows)" % (args.csv, len(rows)), file=sys.stderr)

    print("# The move matrix\n")
    print("Generated by `tools/move_matrix.py`. Every number is read out of")
    print("MKSTK.ASM, a move handler, or a sprite table - nothing is estimated.\n")
    print("**band** is the PREDICTED connect range against a standing victim:")
    print("`x_offset - x_size - W/8 .. x_offset + W/8`, from `strike_check`")
    print("and `sq_punch`. It is a prediction, and the two places it is known")
    print("to be wrong are named in the tool's own header - travelling moves,")
    print("and the near edge at point blank where `repell` intervenes.\n")
    print("Projectiles are absent on purpose: their box rides the projectile")
    print("object, so their range is travel over time, not a number here.\n")

    unresolved = sorted(c for c, w in widths.items() if w is None)
    if unresolved:
        print("Stance width would not resolve for %s, so those use the %d px"
              % (", ".join(BA.CHARS[c] for c in unresolved), DEFAULT_W))
        print("fallback - worth at most 1 px on a band edge.\n")

    shown = [r for r in rows if not args.char or r["char"] == args.char]
    by_char = collections.defaultdict(list)
    for r in shown:
        by_char[r["char"]].append(r)

    for cname in BA.CHARS:
        rs = by_char.get(cname)
        if not rs:
            continue
        print("\n## %s\n" % cname)
        print("| idx | record | move | reach | near | band | box | hit | blk | "
              "active | contact pose | art |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in sorted(rs, key=lambda r: -r["reach"]):
            print("| %s | %s | %s | %d | %d | %d..%d | %s | %s | %s | %s | %s | %s |"
                  % (r["idx"], r["record"], r["handler"] or "-",
                     r["reach"], r["near_edge"],
                     r["band_lo"], r["band_hi"], r["box"],
                     r["hit"], r["blk"],
                     r["active"] if r["active"] is not None else "?",
                     r["pose"] or "-", r["art"] or "-"))

    print("\n## Where the prediction has been checked against the game\n")
    print("Everything above is computed. These are the rows that have also been")
    print("MEASURED live, by a rig that verified the move fired on every trial.")
    print("Two checks is not a validated model - it is two checks - so the far")
    print("edge is trusted and the near edge is known to be wrong.\n")
    print("| char | record | predicted | measured | far edge | near edge | rig |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        key = (r["char"], r["record"])
        if key not in MEASURED:
            continue
        lo, hi, rig = MEASURED[key]
        print("| %s | %s | %d..%d | %d..%d | %+d | %+d | %s |"
              % (r["char"], r["record"], r["band_lo"], r["band_hi"], lo, hi,
                 hi - r["band_hi"], lo - r["band_lo"], rig))
    print()
    print("The far edge lands within 3 px both times. The near edge measures")
    print("4-7 px CLOSER than predicted, both times, because `repell` shoves the")
    print("fighters apart before the strike window opens - so treat the low end")
    print("of every band as approximate and the high end as real.\n")

    have_h = sum(1 for r in rows if r["handler"])
    have_p = sum(1 for r in rows if r["pose"])
    print("## Coverage\n")
    print("| | rows | share |")
    print("|---|---|---|")
    print("| strike records, all characters | %d | 100%% |" % len(rows))
    print("| with a move handler identified | %d | %d%% |"
          % (have_h, round(100 * have_h / len(rows))))
    print("| with a contact pose resolved | %d | %d%% |"
          % (have_p, round(100 * have_p / len(rows))))
    print("| measured live | %d | %d%% |"
          % (len(MEASURED), round(100 * len(MEASURED) / len(rows))))
    print()
    print("Geometry and damage are complete - every row has them, straight out")
    print("of MKSTK.ASM. Timing and contact pose are joined on where the handler")
    print("resolves; a blank is a gap in the parse, not a move without a")
    print("handler, and closing it is the next piece of work.\n")

    print("%d rows over %d characters." % (len(rows), len(by_char)))


if __name__ == "__main__":
    main()
