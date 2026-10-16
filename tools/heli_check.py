#!/usr/bin/env python3
"""Diff what MAME actually played against what src/MKSA.ASM holds.

Reads tools/baraka_heliport_test.log (the `[heli] T' per-tick trace) and
tmp/heli_expect.json (tools/heli_expect.py), collapses the observed SAG stream
into (pose, ticks) runs and compares.

WHY SAG: oimg and oshape are link-time addresses that move on every rebuild;
the SAG is the image-data pointer baked into the .TBL record, so it names a
pose stably.  A run of identical SAGs IS the hold, because both lanes are
generated expanded to sleep 1 - one row per tick.

WHERE THE CLIMB ENDS AND THE DESCENT BEGINS is derived HERE, from the y trace,
not from the harness.  do_sa_helitest seats him at p_ganiy+SAHT_SEAT_DY in one
tick straight off the top of the screen, so the boundary is the single sample
where oypos jumps from far negative to the ground line.  It is NOT "oypos got
back near the floor": the descent lane's own ani_adjustxy rows then walk oypos
up to +132 and back, so any threshold test on y lands several ticks late and
silently eats the front of the lane.

WHAT IT CANNOT SEE: two different lane entries that happen to draw the same
pose back to back would collapse into one run.  Neither lane has an adjacent
repeat, and the checker says so rather than assuming it.

    python tools/heli_check.py
    python tools/heli_check.py --log other.log --expect other.json
"""
import argparse, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

T_RE = re.compile(
# t is -1 on the TAIL rows the harness emits after the move ends - the
# victim lane outlives it, so those rows still matter.  A \d+ here dropped
# every one of them and read as the lane stopping 8 ticks early.
    r"\[heli\] T f=(\d+) t=(-?\d+) act=0x([0-9a-f]+) sag=0x([0-9a-f]+) "
    r"y=(-?\d+) x=(-?\d+) yv=(-?\d+) sh=(\d+) ganiy=(-?\d+) shape=0x([0-9a-f]+) v=0x([0-9a-f]+) vx=(-?\d+) vy=(-?\d+) fh=(\d)")
START_RE = re.compile(r"\[heli\] START #(\d+) frame=(\d+) pattern=(\d+)")
END_RE = re.compile(r"\[heli\] END frame=(\d+) dur=(\d+) climb_min_y=(-?\d+) "
                    r"seat_y=(\S+) descent_ticks=(\S+) shadow_off=(\S+) "
                    r"shadow_back=(\S+) takeover=(\S+)")

# do_sa_helitest's height gate.  INFORMATIONAL ONLY - the real assertion is
# the DRAWN bottom edge below, because the gate is on the anchor and the last
# frame drawn is a tick short of it.  Keep it in step with MOVES.ASM anyway so
# the printed line does not mislead.
SAHW_TOP = -170
SEAT_DY = 2              # SAHT_SEAT_DY (BARAKAFLIP1 slot 0 sums to dY -2)


def runs(vals):
    out = []
    for v in vals:
        if out and out[-1][0] == v:
            out[-1][1] += 1
        else:
            out.append([v, 1])
    return out


def name_map(expect):
    m = {}
    for lane in expect.values():
        for r in lane:
            m.setdefault(r["sag"], r["pose"])
    return m


def fmt(rs, names):
    return " ".join("%s x%d" % (names.get(s, "%08x" % s), n) for s, n in rs)


def collapse(lane):
    """Merge adjacent entries that draw the same pose, the way an observed
    SAG stream necessarily would."""
    out = []
    for r in lane:
        if out and out[-1][0] == r["sag"]:
            out[-1][1] += r["ticks"]
        else:
            out.append([r["sag"], r["ticks"]])
    return out


def windup_stream(lane, n_ticks, loop_from=3):
    """The windup expanded to per-tick SAGs: entries 0..2 once, then 3..end on
    repeat.  a_sa_windup LOOPS to a_sa_windup_loop and the caller's height
    check - not a row count - is what ends it, so the observed climb is a
    PREFIX of this and its last hold may be cut short."""
    head = [r["sag"] for r in lane[:loop_from] for _ in range(r["ticks"])]
    body = [r["sag"] for r in lane[loop_from:] for _ in range(r["ticks"])]
    out = list(head)
    while len(out) < n_ticks and body:
        out.extend(body)
    return out[:n_ticks]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=os.path.join(ROOT, "tools", "baraka_heliport_test.log"))
    ap.add_argument("--expect", default=os.path.join(ROOT, "tmp", "heli_expect.json"))
    ap.add_argument("--attempt", type=int, default=None)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    if not os.path.exists(a.log):
        print("no log at " + a.log, file=sys.stderr)
        return 2
    expect = json.load(open(a.expect))
    names = name_map(expect)

    dive_lane = expect["a_sa_helitest"]
    wind_lane = expect["a_sa_windup"]

    # sag -> every strip of that pose, for drawn-extent maths
    piece_map = {}
    for lane in expect.values():
        for r in lane:
            piece_map.setdefault(r["sag"], r.get("pieces", []))
    exp_dive = collapse(dive_lane)
    exp_dive_ticks = sum(r["ticks"] for r in dive_lane)
    # the sags of the dive lane's first entries, for the blocked check
    dive_sags_by_entry = [r["sag"] for r in dive_lane]

    for label, raw, coll in (("a_sa_helitest", dive_lane, exp_dive),
                             ("a_sa_windup", wind_lane, collapse(wind_lane))):
        if len(coll) != len(raw):
            print("NOTE %s: %d entries collapse to %d observable runs "
                  "(adjacent entries share a pose)" % (label, len(raw), len(coll)))

    moves, cur, guard = [], None, False
    for line in open(a.log, errors="replace"):
        if "[heli] GUARD" in line:
            guard = line.strip().endswith("true")
            continue
        m = START_RE.search(line)
        if m:
            cur = dict(pattern=int(m.group(3)), ticks=[], end=None,
                       guard=guard)
            moves.append(cur)
            continue
        if cur is None:
            continue
        m = END_RE.search(line)
        if m:
            cur["end"] = dict(dur=int(m.group(2)), shadow_back=m.group(7),
                              takeover=m.group(8))
            # do NOT drop the move here: the victim lane outlives it and
            # its tail T lines still belong to this attempt.
            continue
        m = T_RE.search(line)
        if m:
            cur["ticks"].append(dict(f=int(m.group(1)), act=int(m.group(3), 16), yv=int(m.group(7)),
                                     sag=int(m.group(4), 16),
                                     y=int(m.group(5)), x=int(m.group(6)),
                                     sh=int(m.group(8)), ganiy=int(m.group(9)),
                                     vsag=int(m.group(11), 16),
                                     vx=int(m.group(12)), vy=int(m.group(13)), fh=int(m.group(14))))

    if not moves:
        print("FAIL: the move never started - no [heli] START in the log")
        return 1

    print("%d move attempt(s) captured, %d ticks expected in the descent\n"
          % (len(moves), exp_dive_ticks))
    fails = 0
    for i, mv in enumerate(moves, 1):
        if a.attempt and i != a.attempt:
            continue
        T = mv["ticks"]
        print("=== attempt %d (input pattern %d) ===" % (i, mv["pattern"]))

        # ---- phase boundary: the one-tick seat off the top -----------------
        d0 = None
        for k in range(1, len(T)):
            if T[k - 1]["y"] < -50 <= T[k]["y"]:
                d0 = k
                break
        if d0 is None:
            print("  FAIL never seated - the climb or the far-side teleport "
                  "did not complete")
            fails += 1
            print("")
            continue

        climb, dive = T[:d0], T[d0:d0 + exp_dive_ticks]

        # ---- the descent: the lane this change is about --------------------
        if mv["guard"]:
            # BLOCKED.  sahv_he_blocked bails the dive at entry 5 and
            # do_sa_helitest flies him out under `flight` + do_land_animation -
            # the shape do_decoy (MKPROP.ASM) takes when Scorpion's teleport
            # punch is stopped.  Three things have to be true, and none of
            # them is "the action ended": the recovery runs under the SAME
            # act_sa_spin, which is what made a tick-count threshold here
            # report a working build as broken.
            bail = sum(r["ticks"] for r in dive_lane[:5])
            vr = runs([t["sag"] for t in dive])
            spins = 0
            for sag, n in vr:
                if sag not in dive_sags_by_entry[:6]:
                    break
                spins += n
            stopped = spins <= bail + 4
            print("  BLOCKED  dive played %d ticks of lane before bailing"
                  " (entry 5 = tick %d)" % (spins, bail))
            print("    %s the dive stopped at the bail, not played out"
                  % ("OK  " if stopped else "FAIL"))
            fails += 0 if stopped else 1
            # a real ballistic arc: oyvel rises through zero
            yvs = [t["yv"] for t in dive]
            arc = any(v < 0 for v in yvs) and any(v > 0 for v in yvs)
            print("    %s flight arc: oyvel %d .. %d, crosses zero"
                  % ("OK  " if arc else "FAIL", min(yvs), max(yvs)))
            fails += 0 if arc else 1
            # and it carries him away from the man who blocked it
            away = abs(dive[-1]["x"] - dive[0]["x"])
            print("    ---- travelled %dpx during the recovery" % away)
            print("")
            continue
        obs = runs([t["sag"] for t in dive])
        ok = [list(x) for x in obs] == [list(x) for x in exp_dive]
        print("  DESCENT %d ticks observed / %d expected" % (len(dive), exp_dive_ticks))
        if ok:
            print("    OK   pose sequence and holds match a_sa_helitest exactly")
            if a.verbose:
                print("         " + fmt(obs, names))
        else:
            fails += 1
            print("    FAIL sequence differs")
            print("      want: " + fmt(exp_dive, names))
            print("      got : " + fmt(obs, names))
            for n in range(max(len(obs), len(exp_dive))):
                e = exp_dive[n] if n < len(exp_dive) else None
                o = obs[n] if n < len(obs) else None
                if e != o:
                    print("      run %2d want %-16s got %s" % (
                        n,
                        "%s x%d" % (names.get(e[0], "?"), e[1]) if e else "-",
                        "%s x%d" % (names.get(o[0], "?"), o[1]) if o else "-"))

        # ---- the climb: a prefix of the looping windup ----------------------
        # Drop a leading tick still showing the PREVIOUS pose: the harness
        # samples at end of frame, so the tick p_action flips can precede the
        # lane's first draw by one.
        head = 0
        first = wind_lane[0]["sag"]
        while head < len(climb) and climb[head]["sag"] != first:
            head += 1
        cl = climb[head:]
        exp_climb = windup_stream(wind_lane, len(cl))
        obs_climb = [t["sag"] for t in cl]
        cok = obs_climb == exp_climb
        print("  CLIMB   %d ticks (%d lead-in tick(s) before the lane's first pose)"
              % (len(cl), head))
        if cok:
            print("    OK   every tick matches a_sa_windup run through its loop")
            if a.verbose:
                print("         " + fmt(runs(obs_climb), names))
        else:
            fails += 1
            bad = next(k for k in range(min(len(obs_climb), len(exp_climb)))
                       if obs_climb[k] != exp_climb[k])
            print("    FAIL diverges at climb tick %d: want %s got %s"
                  % (bad, names.get(exp_climb[bad], "?"), names.get(obs_climb[bad], "?")))
            print("      want: " + fmt(runs(exp_climb), names))
            print("      got : " + fmt(runs(obs_climb), names))

        # ---- the descent anipoints, tick for tick --------------------------
        #
        # THE SEAT IS NOT VISIBLE ON ITS OWN.  do_sa_helitest writes
        # p_ganiy+SAHT_SEAT_DY and the lane's first ani_adjustxy (76,-48) lands
        # in the same tick, so the first sample reads seat-48, not seat.
        # Checking that one number against p_ganiy+1 fails on a correct build.
        # Checking the whole track does not, and it is a far better test: it
        # walks every ani_adjustxy operand in the lane against the oypos the
        # engine actually produced.  dy needs no facing correction - only dx is
        # mirrored by b_fliph - so this is exact, not approximate.
        exp_y = [r["dy"] for r in dive_lane for _ in range(r["ticks"])]
        seat = dive[0]["ganiy"] + SEAT_DY
        bad_y = [(k, seat + exp_y[k], dive[k]["y"])
                 for k in range(min(len(dive), len(exp_y)))
                 if dive[k]["y"] != seat + exp_y[k]]
        print("    %s descent oypos track vs p_ganiy+%d plus the lane's "
              "cumulative dY: %d/%d ticks match"
              % ("OK  " if not bad_y else "FAIL", SEAT_DY,
                 len(dive) - len(bad_y), len(dive)))
        if bad_y:
            fails += 1
            for k, want, got in bad_y[:6]:
                print("        tick %2d want %d got %d" % (k, want, got))
        else:
            print("         seat=%d (p_ganiy=%d), dY runs %+d .. %+d, ends %+d"
                  % (seat, dive[0]["ganiy"], min(exp_y), max(exp_y), exp_y[-1]))

        # dx is mirrored by facing, so only the per-tick MAGNITUDE is comparable
        exp_x = [r["dx"] for r in dive_lane for _ in range(r["ticks"])]
        d_obs = [abs(dive[k]["x"] - dive[k - 1]["x"]) for k in range(1, len(dive))]
        d_exp = [abs(exp_x[k] - exp_x[k - 1]) for k in range(1, len(dive))]
        x_ok = d_obs == d_exp
        print("    %s descent oxpos steps vs the lane's |dX|: %d/%d match "
              "(sign is b_fliph's, not the lane's)"
              % ("OK  " if x_ok else "FAIL",
                 sum(1 for k in range(len(d_obs)) if d_obs[k] == d_exp[k]),
                 len(d_obs)))
        if not x_ok:
            fails += 1
            for k in range(len(d_obs)):
                if d_obs[k] != d_exp[k]:
                    print("        tick %2d want |%d| got |%d|" % (k + 1, d_exp[k], d_obs[k]))
                    break

        # ---- THE HANDOFF MUST BE INVISIBLE ---------------------------------
        #
        # Checking the ANCHOR against SAHW_TOP is not the test, and believing it
        # was is what let a visible break ship: the gate stopped the anchor past
        # -149 but the last frame DRAWN was a tick short at -142, and the spin
        # art hangs up to 149px below the anchor, so ~7px of him was still on
        # screen when the far-side teleport moved him 85-127px sideways on the
        # very next tick.  What has to clear y=0 is the ART on the LAST DRAWN
        # FRAME, so that is what this asserts.
        last = climb[-1]
        pieces = piece_map.get(last["sag"])
        if not pieces:
            print("    WARN could not identify the last climb pose (sag %08x)"
                  % last["sag"])
        else:
            # a_sa_windup never sets ani_flip_v, so aniy is used as authored
            # tbl_records rows are (w, h, anix, aniy, sag)
            bot = max(last["y"] - r[3] + r[1] for r in pieces)
            clear = bot <= 0
            print("    %s handoff is off-screen: last drawn climb frame ends at "
                  "y=%d (anchor %d, needs <= 0)"
                  % ("OK  " if clear else "FAIL", bot, last["y"]))
            fails += 0 if clear else 1
        top = min(t["y"] for t in climb)
        print("    ---- climb reached anchor oypos=%d (gate %d)" % (top, SAHW_TOP))

        lit = [k for k, t in enumerate(dive) if t["sh"]]
        print("    %s m_shadow off for all %d descent ticks%s"
              % ("OK  " if not lit else "FAIL", len(dive),
                 "" if not lit else "  (on at tick %s)" % lit[:6]))
        fails += 0 if not lit else 1

        # ---- THE VICTIM: our knockdown, cut short at UGFLIPPED2 ----------
        #
        # He takes sahp_victim_react at the entry-5 hook and stumbles on the
        # project's timing, exactly as before.  What changed is the END: entry
        # 18 is UGFLIPPED2 - Baraka coming down out of the spin - and
        # sahp_big_hit hands him r_jax_elbow there, so he snaps out of the
        # stumble and reacts as if elbowed.
        #
        # So only the stumble's leading holds are ours to assert; everything
        # after the switch is the engine's reaction and is checked by the fact
        # that the pose changed on the right tick.
        STUMBLE_HOLDS = [4] * 8 + [3]
        # entry 18's start tick, from the lane's own holds
        UGFLIPPED2_TICK = sum(r["ticks"] for r in dive_lane[:18])
        vs = [t["vsag"] for t in T]
        hook = d0 + 10
        vstart = next((k for k in range(hook, len(vs)) if vs[k] != vs[hook]), None)
        if vstart is None:
            print("    FAIL victim never changed pose after the hook - no takeover")
            fails += 1
        else:
            vruns = runs(vs[vstart:])
            holds = [n for _, n in vruns][:len(STUMBLE_HOLDS)]
            hok = holds == STUMBLE_HOLDS
            print("    %s victim stumble holds %s"
                  % ("OK  " if hok else "FAIL", holds))
            if not hok:
                fails += 1
                print("         want %s (unchanged from the project)" % STUMBLE_HOLDS)
            # where does the elbow take over?
            switch = vstart + sum(n for _, n in vruns[:len(STUMBLE_HOLDS)]) - d0
            sok = abs(switch - UGFLIPPED2_TICK) <= 2
            print("    %s elbow reaction starts at descent tick %d;"
                  " UGFLIPPED2 is tick %d"
                  % ("OK  " if sok else "FAIL", switch, UGFLIPPED2_TICK))
            if not sok:
                fails += 1
            else:
                after = [n for _, n in vruns[len(STUMBLE_HOLDS):]][:3]
                print("         reaction holds after the switch: %s" % after)

        # ---- which way is he facing? -------------------------------------
        # The descent draws at (his facing) XOR (the lane's ani_flip), so
        # "he mirrors the wrong way" is really a question about which side of
        # the opponent do_sa_helitest put him on.  fh=1 is facing LEFT.
        fh = dive[0]["fh"]
        side = "LEFT" if dive[0]["x"] > dive[0]["vx"] else "RIGHT"
        toward = (side == "LEFT" and fh == 1) or (side == "RIGHT" and fh == 0)
        print("    ---- facing: fh=%d (%s), opponent is to his %s -> facing %s"
              % (fh, "left" if fh else "right", side.lower(),
                 "TOWARD him" if toward else "AWAY from him"))

        # he lands on the FAR side: oxpos crosses the opponent's anchor
        x_before, x_after = climb[-1]["x"], dive[0]["x"]
        print("    ---- far-side teleport: oxpos %d -> %d (%+d)"
              % (x_before, x_after, x_after - x_before))

        end = mv["end"]
        if end:
            sb = end["shadow_back"] == "true"
            print("    %s shadow restored after the lane" % ("OK  " if sb else "FAIL"))
            fails += 0 if sb else 1
            print("    ---- victim handover: takeover=%s;  move ran %d ticks"
                  % (end["takeover"], end["dur"]))
        else:
            print("    FAIL move never ended (no [heli] END) - it hung")
            fails += 1
        print("")

    print("RESULT: %s (%d failing check(s) across %d attempt(s))"
          % ("PASS" if fails == 0 else "FAIL", fails, len(moves)))
    return 0 if fails == 0 else 1


sys.exit(main())
