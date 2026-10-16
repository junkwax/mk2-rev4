#!/usr/bin/env python
"""box_model_lab - compare collision MODELS against each other, statically.

doc/FGC_FRAME_BOX_SPEC.md section 3 asks one blocking question: is the derived
quarter-width column good enough (Route A), does the per-piece layer that is
already built earn switching on (Route A-and-a-half), or is authored per-frame
data actually needed (Route B)?

That question is usually answered by staring at `f_colbox` in a running game.
It does not have to be. Every input is already extracted - the strike boxes
from MKSTK.ASM, the victim's pieces from the sprite tables - so the models can
be run against each other over the whole cast, at every distance, in a second.

The models here are transcriptions of `sq_punch` and `piece_overlap`
(src/JOY.ASM), not a fresh interpretation of them:

  retail      the bounding box inset by 3W/8 a side.  `anchorcol 0`
  build       width 2*(W/8) centred on the ANIPOINT.  `anchorcol 1` - SHIPPING
  nosqueeze   the whole silhouette, for scale
  perpiece    the strike box against each piece, first overlap wins.  `perpiece`
  narrow:N    width 2*(W/N) about the anchor, for sweeping the factor

    python tools/box_model_lab.py drift      how far retail's column sits off
    python tools/box_model_lab.py width      the two columns are NOT equal
    python tools/box_model_lab.py ranges     connect range per move, per model
    python tools/box_model_lab.py flips      where two models disagree on a hit
    python tools/box_model_lab.py highlow    does per-piece give a high/low axis
    python tools/box_model_lab.py all

Everything is read live from this tree, so it cannot describe a build that is
not the one in front of you.
"""
import pathlib
import re

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import boxlab_export as BX                                      # noqa: E402

MAX_D = 260                    # further than any strike box reaches
DEFENCE_LANES = ("stance", "duck")


# --------------------------------------------------------------- geometry

def bbox(rects):
    if not rects:
        return None
    l = min(x for x, y, w, h in rects)
    t = min(y for x, y, w, h in rects)
    r = max(x + w for x, y, w, h in rects)
    b = max(y + h for x, y, w, h in rects)
    return [l, t, r, b]


MAINEQU = pathlib.Path(__file__).resolve().parent.parent / "src" / "MAINEQU.ASM"


def read_switches():
    """The live collision switches, read from MAINEQU.ASM.

    The lab exists to say what the SHIPPING build does, so `build` must not be
    a hardcoded guess at it. It used to be one, and drifted: it still modelled
    2*(W>>3) after JOY.ASM had moved to retail's exact width, and it knew
    nothing about colnarrow at all.
    """
    out = {"anchorcol": 1, "colwidth": 1, "colnarrow": 4}
    try:
        txt = MAINEQU.read_text(errors="replace")
    except OSError:
        return out
    for k in list(out):
        m = re.search(r"^" + k + r"\s+\.set\s+([0-9]+)", txt, re.M)
        if m:
            out[k] = int(m.group(1))
    return out


SW = read_switches()


def _column(W, colnarrow):
    """W' - the surviving column width, exactly as sq_punch computes it.

    JOY.ASM has two branches. `colnarrow == 4` reproduces retail's width the
    way retail produces it, truncation included: W - 2*((W>>3)+(W>>2)). Any
    other value is a shift, `srl colnarrow/2`, so only powers of two are real
    - colnarrow 3 would assemble as a shift of 1 and behave as 2.
    """
    if colnarrow != 4:
        return W >> (colnarrow // 2)
    a7 = W >> 3
    inset = (W >> 2) + a7
    return W - (inset << 1)


def _split(anchor, Wp):
    """left/right of the anchor. The ASM takes floor one side, ceil the other,
    so an odd W' keeps its pixel on the RIGHT - a1 = W' - floor(W'/2)."""
    lo = Wp >> 1
    return anchor - lo, anchor + (Wp - lo)


def squeeze_retail(l, r):
    """`anchorcol 0`: inset the bounding box by W/8 + W/4 on each side.

    The shifts are the source's, truncation included - `srl 3` then `srl 2`,
    which is a divide by EIGHT then by FOUR, so the inset is 3W/8 and a
    quarter of the width survives. Not five eighths, whatever the old
    comments said. Centred on the SILHOUETTE, so it walks with the limbs.
    """
    W = r - l
    inset = (W >> 3) + (W >> 2)
    return l + inset, r - inset


def squeeze_build(l, r, anchor=0):
    """The shipping model: whatever MAINEQU.ASM currently says."""
    if not SW["anchorcol"] or not SW["colwidth"]:
        return squeeze_retail(l, r)
    return _split(anchor, _column(r - l, SW["colnarrow"]))


def squeeze_narrow(l, r, n, anchor=0):
    """A hypothetical colnarrow of N, using the same arithmetic the part uses,
    so a sweep predicts what shipping that value would actually do."""
    return _split(anchor, _column(r - l, n))


def overlaps(s, box):
    return (s[0] < box[2] and s[2] > box[0] and
            s[1] < box[3] and s[3] > box[1])


def world(rects, D):
    """The defender's pieces placed at distance D. He faces the attacker, so
    his pieces are mirrored about his own anchor before being placed."""
    return [[D - x - w, y, w, h] for x, y, w, h in rects]


def strike_box(rec):
    """front is the FRONT EDGE and width extends backwards from it."""
    return [rec["front"] - rec["width"], rec["y"],
            rec["front"], rec["y"] + rec["height"]]


def tested(model, rects, D, squeezes):
    """The volume `model` would test, for one pose at one distance.

    Returns a list of rectangles - one for every model except perpiece, which
    is the whole point of it. Kept for drawing and for spot checks; the sweeps
    below use d_range instead, which is the same arithmetic solved for D.
    """
    w = world(rects, D)
    if not w:
        return []
    if model == "perpiece":
        # overlaps() wants [left, top, right, bottom]; world() hands back
        # [x, y, width, height]. Returning the pieces raw made this path
        # compare a width against a right edge, which selfcheck caught.
        return [[x, y, x + pw, y + ph] for x, y, pw, ph in w]
    full = bbox(w)
    if not squeezes or model == "nosqueeze":
        return [full]
    if model == "retail":
        l, r = squeeze_retail(full[0], full[2])
    elif model == "build":
        l, r = squeeze_build(full[0], full[2], D)
    elif model.startswith("narrow:"):
        l, r = squeeze_narrow(full[0], full[2], int(model.split(":")[1]), D)
    else:
        raise SystemExit("unknown model %r" % model)
    return [[l, full[1], r, full[3]]]


def connects(model, strike, rects, D, squeezes):
    return any(overlaps(strike, b)
               for b in tested(model, rects, D, squeezes))


# ------------------------------------------------- the same, solved for D
#
# Every tested volume is the defender's geometry translated by D, so its x
# span is [D + a, D + b] for constants a and b that depend only on the pose
# and the model. The overlap test sl < D + b and sr > D + a is therefore a
# plain interval in D, and the whole distance sweep collapses to arithmetic.
# Vertical overlap does not involve D at all, so it is a gate, not a bound.
#
# This is not a second model. It is the identical comparison with D factored
# out - `selfcheck` asserts the two agree at every distance.

def _spans(model, rects, squeezes):
    """[(a, b, top, bottom)] - the tested volume as offsets from D."""
    if not rects:
        return []
    if model == "perpiece":
        # piece at local [x,y,w,h] lands at [D-x-w, D-x]
        return [(-x - w, -x, y, y + h) for x, y, w, h in rects]
    l = min(x for x, y, w, h in rects)
    t = min(y for x, y, w, h in rects)
    r = max(x + w for x, y, w, h in rects)
    b = max(y + h for x, y, w, h in rects)
    # the full silhouette, mirrored, spans [D-r, D-l]
    if not squeezes or model == "nosqueeze":
        return [(-r, -l, t, b)]
    W = r - l
    if model == "retail":
        inset = (W >> 3) + (W >> 2)
        return [(-r + inset, -l - inset, t, b)]
    #
    #  These are returned RELATIVE TO D, which world() places the victim's
    #  anchor at. retail insets the mirrored bounding box, so it carries the
    #  mirror in its expression; the anchored models are already measured out
    #  from the anchor and must NOT be mirrored again. That was invisible
    #  while the column was symmetric and selfcheck caught it the moment
    #  colnarrow made it lopsided - the odd pixel went to the wrong side.
    #
    if model == "build":
        lo, hi = squeeze_build(l, r)
        return [(lo, hi, t, b)]
    if model.startswith("narrow:"):
        lo, hi = squeeze_narrow(l, r, int(model.split(":")[1]))
        return [(lo, hi, t, b)]
    raise SystemExit("unknown model %r" % model)


def d_range(model, strike, rects, squeezes, lo=0, hi=MAX_D):
    """The integer distances in [lo, hi) at which this move connects.

    Returned as a sorted set. Empty means it never connects at any distance,
    which is a real answer - some records cannot reach at all.
    """
    sl, st, sr, sb = strike
    out = set()
    for a, b, top, bot in _spans(model, rects, squeezes):
        if not (st < bot and sb > top):
            continue                       # no vertical overlap, ever
        # sl < D + b  and  sr > D + a
        d_lo = max(lo, sl - b + 1)
        d_hi = min(hi - 1, sr - a - 1)
        if d_lo <= d_hi:
            out.update(range(d_lo, d_hi + 1))
    return out


def lane_range(d, model, strike, mid, char, laneName, per_frame=False):
    """Distances where the move connects against a whole lane.

    A lane is not one pose - a stance breathes across its frames, and which
    frame the defender is on changes the answer at the edges. `any` is the
    union, `all` the intersection, and the gap between them is the flicker.
    """
    lane = d.lane(char, laneName)
    if not lane:
        return None
    sq = d.squeezes(mid)
    sets = [d_range(model, strike, d.pose[p], sq) for p in lane]
    if not sets:
        return None
    union = set().union(*sets)
    inter = set(sets[0]).intersection(*sets[1:]) if len(sets) > 1 else set(sets[0])
    return {"any": union, "all": inter,
            "frames": sets if per_frame else None}


# ------------------------------------------------------------------ data

class Data:
    def __init__(self):
        self.boxes = BX.build_boxes()
        self.poses = BX.build_poses()
        self.by_id = {m["id"]: m for m in self.boxes["moves"]}
        self.flags = self.boxes.get("flags", {})
        self.pose = self.poses["poses"]
        self.stances = self.poses["stances"]
        self.contacts = self.poses["contacts"]

    def squeezes(self, mid):
        return "squeeze" in (self.flags.get(mid) or [])

    def lane(self, char, name):
        return (self.stances.get(char) or {}).get(name) or []

    def defenders(self):
        """Every character with both a stance and a duck lane."""
        return sorted(c for c in self.stances
                      if self.lane(c, "stance") and self.lane(c, "duck"))

    def movable(self):
        """Moves with a strike record we can place. Contacts carry the pose
        the box is live on; a move without one is left out rather than
        guessed at."""
        out = []
        for c in self.contacts:
            rec = self.by_id.get(c["move"])
            if rec and self.pose.get(c["pose"]):
                out.append((c["move"], rec, c))
        return out


def connect_range(d, model, rec, mid, char, laneName):
    r = lane_range(d, model, strike_box(rec), mid, char, laneName)
    if not r or not r["any"]:
        return None
    a = sorted(r["any"])
    return {"any": (a[0], a[-1]),
            "all": (min(r["all"]), max(r["all"])) if r["all"] else None,
            "flicker": len(r["any"]) - len(r["all"])}


# --------------------------------------------------------------- reports

def rep_drift(d, args):
    """How far retail's column sits from the anipoint the build uses."""
    print("COLUMN DRIFT - retail's centre minus the anchor, per pose")
    print("`anchorcol 1` centres the column on the anipoint; retail centres it")
    print("on the silhouette. This is the distance between the two.\n")
    rows = []
    for pid, rects in d.pose.items():
        b = bbox(rects)
        if not b:
            continue
        rows.append(((b[0] + b[2]) / 2.0, b[2] - b[0], pid))
    rows.sort(key=lambda r: -abs(r[0]))
    drifts = [abs(r[0]) for r in rows]
    print("  poses               %d" % len(rows))
    print("  mean |drift|        %.1f px" % (sum(drifts) / len(drifts)))
    print("  median |drift|      %.1f px"
          % sorted(drifts)[len(drifts) // 2])
    print("  worst               %.1f px" % max(drifts))
    for lim in (5, 10, 20, 30):
        n = sum(1 for x in drifts if x > lim)
        print("  over %2d px          %4d  (%.0f%%)"
              % (lim, n, 100.0 * n / len(drifts)))
    print("\n  the ten worst poses (drift, full width):")
    for dr, w, pid in rows[:10]:
        print("    %-8s drift %+7.1f   width %3d" % (pid, dr, w))
    print("\nEvery pixel of drift is a pixel the public viewer's hit column is")
    print("in the wrong place, because index.html implements the retail branch.")


def rep_width(d, args):
    """The two columns are not the same width, and the comment says they are."""
    print("COLUMN WIDTH - retail vs build, on the same silhouette\n")
    seen, diff = {}, []
    for pid, rects in d.pose.items():
        b = bbox(rects)
        if not b:
            continue
        W = b[2] - b[0]
        if W in seen:
            continue
        rl, rr = squeeze_retail(b[0], b[2])
        bl, br = squeeze_build(b[0], b[2])
        seen[W] = ((rr - rl), (br - bl))
        diff.append((W, rr - rl, br - bl))
    diff.sort()
    same = sum(1 for w, r, b in diff if r == b)
    print("  distinct silhouette widths   %d" % len(diff))
    print("  where the columns match      %d" % same)
    print("  where they differ            %d" % (len(diff) - same))
    print("  worst difference             %d px"
          % max(abs(r - b) for _w, r, b in diff))
    print("\n  width  retail  build  delta")
    for w, r, b in diff[:6] + diff[len(diff) // 2:len(diff) // 2 + 6] + diff[-6:]:
        print("  %5d  %6d  %5d  %+5d" % (w, r, b, b - r))
    print("\nsq_punch's own comment says 'same quarter width'. The shifts")
    print("truncate differently, so it is not - which also means boxlab's")
    print("selftest asserting an 18px column for Jax is asserting RETAIL.")


def rep_ranges(d, args):
    models = args.models
    moves = d.movable()
    if args.move:
        moves = [m for m in moves if args.move in m[0]]
    defender = args.defender
    print("CONNECT RANGE against %s, standing lane" % defender)
    print("'any' = connects on at least one frame of the lane; 'all' = every")
    print("frame. The gap is the flicker a breathing stance produces.\n")
    head = "%-30s" % "move"
    for m in models:
        head += " %-20s" % m
    print(head)
    print("-" * len(head))
    shown = 0
    for mid, rec, _c in sorted(moves, key=lambda t: t[0]):
        line, got = "%-30s" % mid[:30], False
        for m in models:
            r = connect_range(d, m, rec, mid, defender, "stance")
            if r:
                got = True
                line += " %-20s" % ("%d..%d (%d)" % (r["any"][0], r["any"][1],
                                                     r["flicker"]))
            else:
                line += " %-20s" % "-"
        if got:
            print(line)
            shown += 1
            if args.limit and shown >= args.limit:
                print("... (--limit %d)" % args.limit)
                break


def rep_flips(d, args):
    """Where two models disagree about whether a move connects."""
    a = args.models[0]
    b = args.models[1] if len(args.models) > 1 else "build"
    print("VERDICT FLIPS - %s vs %s" % (a, b))
    print("Every move against every defender's stance and duck lanes, over")
    print("0..%d px, every frame of every lane. A flip is a distance where"
          % MAX_D)
    print("one model says hit and the other says miss.\n")
    defs = d.defenders()
    tot = flips = 0
    worst = []
    for mid, rec, _c in d.movable():
        s_, sq = strike_box(rec), d.squeezes(mid)
        for ch in defs:
            for laneName in DEFENCE_LANES:
                lane = d.lane(ch, laneName)
                if not lane:
                    continue
                n = 0
                for p in lane:
                    ra = d_range(a, s_, d.pose[p], sq)
                    rb = d_range(b, s_, d.pose[p], sq)
                    n += len(ra ^ rb)
                    tot += MAX_D
                if n:
                    flips += n
                    worst.append((n, mid, ch, laneName))
    print("  comparisons        %d" % tot)
    print("  disagreements      %d  (%.2f%%)" % (flips, 100.0 * flips / tot))
    worst.sort(reverse=True)
    print("\n  the ten worst move/defender pairs:")
    for n, mid, ch, lane in worst[:10]:
        print("    %-28s vs %-14s %-6s  %5d px of disagreement"
              % (mid[:28], ch, lane, n))


def rep_highlow(d, args):
    """Does the per-piece layer manufacture a high/low axis on its own?

    FGC_FRAME_BOX_SPEC section 3.2 claims a high strike box simply fails to
    overlap a crouching character's remaining pieces, so geometry does what a
    `guard` attribute would - no labels, no new art. That is a claim about
    data, so it is checkable rather than arguable.
    """
    print("HIGH/LOW BY GEOMETRY - moves that whiff over a crouch")
    print("A move has a high/low property if some distance connects standing")
    print("and misses ducking. Counted under each model, over every defender.\n")
    moves = d.movable()
    defs = d.defenders()
    res, depth = {}, {}
    for model in args.models:
        hits, widths = set(), []
        for mid, rec, _c in moves:
            s_ = strike_box(rec)
            best = 0
            for ch in defs:
                st = lane_range(d, model, s_, mid, ch, "stance")
                dk = lane_range(d, model, s_, mid, ch, "duck")
                if not st or not dk:
                    continue
                gap = st["any"] - dk["any"]
                if gap:
                    hits.add(mid)
                    best = max(best, len(gap))
            if best:
                widths.append(best)
        res[model] = hits
        depth[model] = widths
        avg = (sum(widths) / len(widths)) if widths else 0
        print("  %-12s %4d of %d moves whiff over a crouch somewhere"
              "   (mean window %.0f px)"
              % (model, len(hits), len(moves), avg))
    if len(args.models) >= 2:
        a, b = args.models[0], args.models[1]
        gained = sorted(res[b] - res[a])
        lost = sorted(res[a] - res[b])
        print("\n  %s gains %d that %s does not have:" % (b, len(gained), a))
        for m in gained[:15]:
            print("    + %s" % m)
        if len(gained) > 15:
            print("    ... and %d more" % (len(gained) - 15))
        if lost:
            print("\n  %s loses %d:" % (b, len(lost)))
            for m in lost[:10]:
                print("    - %s" % m)


def rep_selfcheck(d, args):
    """The closed form must agree with the brute-force sweep, everywhere.

    d_range exists because sweeping every distance in Python is too slow to
    use. That is only worth having if it is the same comparison, so this
    checks it against the slow one it replaced rather than trusting the
    algebra.
    """
    print("SELF CHECK - closed form vs brute-force sweep\n")
    import random
    random.seed(7)
    moves = d.movable()
    poses = list(d.pose)
    bad = n = 0
    for model in ("retail", "build", "nosqueeze", "perpiece", "narrow:3"):
        for _ in range(120):
            mid, rec, _c = random.choice(moves)
            pid = random.choice(poses)
            rects, sq = d.pose[pid], d.squeezes(mid)
            s_ = strike_box(rec)
            fast = d_range(model, s_, rects, sq)
            slow = {D for D in range(MAX_D)
                    if connects(model, s_, rects, D, sq)}
            n += 1
            if fast != slow:
                bad += 1
                if bad <= 3:
                    print("  MISMATCH %s %s %s: %d vs %d distances"
                          % (model, mid, pid, len(fast), len(slow)))
    print("  %d random move/pose/model cases, %d mismatches" % (n, bad))
    print("  %s" % ("OK - the fast path is the same comparison"
                    if not bad else "FAILED"))
    return bad



def rep_clip(d, args):
    """Would VERTICAL CLIPPING of the crouch column buy a high/low axis?

    Section 4.1 showed the ART gives no room: the median gap between a stance
    top and a crouch top is 9px, and not one of 199 strike boxes ends above
    even the highest crouch. Clipping is the other way at it - shorten the
    DERIVED column from the top while crouching, and the room exists whether
    the sprite provides it or not.

    That is honest as a switch and dishonest as a claim about the art, so the
    question is purely how much clipping buys how much axis.
    """
    print("VERTICAL CLIPPING OF THE CROUCH COLUMN")
    print("How many moves gain a 'connects standing, misses crouching' window")
    print("if the crouching column's TOP is pushed down by N px.\n")

    moves, defs = d.movable(), d.defenders()
    base_spans = _spans

    print("  %-6s %-14s %-14s %s" % ("clip", "moves w/ axis", "median window",
                                     "moves fully immune"))
    print("  " + "-" * 62)
    for clip in (0, 4, 8, 12, 16, 24, 32):
        hits, windows, immune = set(), [], 0
        for mid, rec, _c in moves:
            s_ = strike_box(rec)
            best = 0
            for ch in defs:
                st = lane_range(d, "build", s_, mid, ch, "stance")
                if not st or not st["any"]:
                    continue
                # the duck column, clipped
                dk = set()
                for pid in d.lane(ch, "duck"):
                    rects = d.pose[pid]
                    b = bbox(rects)
                    if not b:
                        continue
                    clipped = [[x, y, w, h] for x, y, w, h in rects]
                    # push the whole column's top down: model it by raising
                    # the top edge of the tested volume
                    top = b[1] + clip
                    if top >= b[3]:
                        continue          # clipped away entirely
                    sq = d.squeezes(mid)
                    #
                    #  The DUCK column must come from the same model as the
                    #  standing one above. This hand-rolled +/-(W>>3) and so
                    #  compared a live-model stance against a hardcoded
                    #  quarter crouch - the gap between them is the reported
                    #  window, so the moment the shipping column widened the
                    #  window inflated tenfold out of nothing. Same drift the
                    #  rest of this file was just fixed for.
                    #
                    if not sq:
                        a, bb = -b[2], -b[0]
                    else:
                        a, bb = squeeze_build(b[0], b[2])
                    sl, stp, sr, sb = s_
                    if not (stp < b[3] and sb > top):
                        continue
                    lo = max(0, sl - bb + 1)
                    hi = min(MAX_D - 1, sr - a - 1)
                    if lo <= hi:
                        dk.update(range(lo, hi + 1))
                gap = st["any"] - dk
                if gap:
                    best = max(best, len(gap))
                if not dk:
                    immune += 1
                    break
            if best:
                hits.add(mid)
                windows.append(best)
        med = sorted(windows)[len(windows) // 2] if windows else 0
        print("  %-6s %-14s %-14s %s" % (
            clip, "%d / %d" % (len(hits), len(moves)), "%d px" % med, immune))

    print("")
    print("0 is the shipping model, and matches the highlow report.")
    print("A crouch that no move can reach at all is not a high/low axis, it")
    print("is invulnerability - watch the last column as the clip grows.")


REPORTS = {"drift": rep_drift, "width": rep_width, "ranges": rep_ranges,
           "flips": rep_flips, "highlow": rep_highlow,
           "selfcheck": rep_selfcheck,
           "clip": rep_clip}


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", choices=sorted(REPORTS) + ["all"])
    ap.add_argument("--models", nargs="+",
                    default=["retail", "build", "perpiece"],
                    help="retail | build | nosqueeze | perpiece | narrow:N")
    ap.add_argument("--defender", default="bigarms",
                    help="public character id for the ranges report")
    ap.add_argument("--move", default=None, help="substring filter")
    ap.add_argument("--limit", type=int, default=25)
    args = ap.parse_args()

    d = Data()
    names = sorted(REPORTS) if args.report == "all" else [args.report]
    for i, n in enumerate(names):
        if i:
            print("\n" + "=" * 72 + "\n")
        REPORTS[n](d, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
