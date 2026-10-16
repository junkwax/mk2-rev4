#!/usr/bin/env python3
"""Generate an MK2 animation lane straight from an IMGTOOL World View project.

The project file is the source of truth.  A pasted export draft goes stale
the moment the project is edited again, and hand-transcribing 30-odd rows of flips and
offsets is exactly the kind of thing that silently drifts - which is how the
first cut of a_sa_helitest ended up missing two flipX+flipY frames that the
project had.

    python tools/wvp_to_lane.py data/barakadow6saf.wax --label a_sa_helitest

imgtool writes .WAX now (.WVP through v3.31.0); either opens here, the
path is all this takes.  What it does with each field:

  sequence_frames  IMG record index per tick, resolved to a record NAME through
                   the library header (frame_doc_idx picks the library; -1 means
                   the slot's own doc_idx).
  frame_mirror     bitmask, bit0 = flip X, bit1 = flip Y.  These are ABSOLUTE
                   per-entry states in the authoring space; the engine only has
                   TOGGLES (ani_flip / ani_flip_v), so this walks the sequence
                   and emits a toggle only where the state changes.  The base
                   state is the character's own facing, which is why nothing is
                   emitted for entry 0 unless it is mirrored.
  frame_delays     preview ticks.  The exporter's convention is to repeat the
                   frame label, and one preview tick is `--tickrate` game ticks
                   (default 3, i.e. the 20.8 FPS the lane was authored at), so
                   the caller can walk the whole lane with one mframew.
  local_dx/dy      ABSOLUTE per-tick offsets from the shared anchor.  ani_adjustxy
                   wants DELTAS, so consecutive entries are differenced, and the
                   row is emitted once per pose, never per repeat.

It refuses to pretend art exists: any record that is not in one of the sidecar
TBLs is reported, with an estimate of what it would cost to load, and the lane
is still written with the label so the gap is visible rather than silent.
"""
import argparse, os, re, struct, sys
from math import gcd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
TICK_HZ = 54.7068   # measured: MAME mk2 refresh, 18.279ms a tick
DEFAULT_HOLD = 4    # imgtool's kDefaultTimelineHold - 13.7fps, the
                    # rate most MK2 move art actually runs at
SIDECAR_TBLS = ["SAHELI.TBL"]   # SAHELI2/3 retired 2026-09-19

# Record name in the PROJECT -> (label to emit, extra horizontal mirror).
#
# A World View project authored against the stock libraries names whole frames
# that the ROM only holds as A/B/C strips.  MK2 already wraps those strips as
# multiparts with the SAME anipoint, so the wrapper is a free, exact stand-in.
# Where the project uses a pre-mirrored frame (SPIN4FLIP is SPIN4 reversed)
# the wrapper plus an ani_flip is the stock idiom - a_sa_spin in MKSA.ASM does
# exactly that, with its ani_adjustx corrections commented out because the
# plain flip lands.
#
# CAUTION: SPIN2..SPIN2FLIP ALSO exist in the SAHELI sidecar on RE-ANCHORED
# anipoints.  LOAD2 binds a bare `SPIN2' to the sidecar copy, so a lane
# authored against UGMO9.IMG must come through this table or it will silently
# draw against the wrong anchor.
SUBST = {
    "SPIN1": ("UGSPIN1", 0), "SPIN2": ("UGSPIN2", 0), "SPIN3": ("UGSPIN3", 0),
    "SPIN4": ("UGSPIN4", 0), "SPIN5": ("UGSPIN5", 0),
    "SPIN2FLIP": ("UGSPIN2", 1), "SPIN3FLIP": ("UGSPIN3", 1),
    "SPIN4FLIP": ("UGSPIN4", 1),
    "UGTURN1FLIP": ("UGTURN1", 1),
    "STKNOCKEDOWN1": ("STKNOCKDOWN1", 0), "STKNOCKEDOWN2": ("STKNOCKDOWN2", 0),
    "STKNOCKEDOWN3": ("STKNOCKDOWN3", 0), "STKNOCKEDOWN4": ("STKNOCKDOWN4", 0),
    "STKNOCKEDOWN5": ("STKNOCKDOWN5", 0), "STKNOCKEDOWN6": ("STKNOCKDOWN6", 0),
    "STKNOCKEDOWN7": ("STKNOCKDOWN7", 0),
}

# --spin-strips overlay.  The SAHELI sidecar carries the same five spin poses
# cut BLADE over BODY instead of the stock left/right split, on identical
# anipoints, for 34-81% of the DMA'd pixels.  It is an overlay rather than a
# change to SUBST because a_sa_helitest (the descent) is generated from the
# same table and still draws the UGSPIN wrappers - flipping the default would
# silently re-point that lane the next time anyone regenerates it.
SPIN_STRIPS = {
    "SPIN1": ("SAHSPIN1", 0), "SPIN2": ("SAHSPIN2", 0), "SPIN3": ("SAHSPIN3", 0),
    "SPIN4": ("SAHSPIN4", 0), "SPIN5": ("SAHSPIN5", 0),
    "SPIN2FLIP": ("SAHSPIN2", 1), "SPIN3FLIP": ("SAHSPIN3", 1),
    "SPIN4FLIP": ("SAHSPIN4", 1),
}


def img_records(path):
    b = open(path, "rb").read()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(b, 0)[:3]
    out = []
    for i in range(imgcnt):
        f = IMAGE.unpack_from(b, oset + i * IMAGE.size)
        out.append(dict(name=f[0].split(b"\0", 1)[0].decode("latin-1"),
                        w=f[4], h=f[5], off=f[7]))
    return b, out


def est_compressed_bytes(blob, rec, bpp=6):
    """Bits a zero-compressed 6bpp row stream would take: 8-bit lead/trail
    header plus bpp per surviving pixel.  Lead/trail quantisation is ignored,
    so this is a floor, not a promise."""
    w, h, off, bits = rec["w"], rec["h"], rec["off"], 0
    stride = (w + 3) & ~3
    for y in range(h):
        row = blob[off + y * stride: off + y * stride + w]
        lead = 0
        while lead < w and row[lead] == 0:
            lead += 1
        trail = 0
        while trail < w - lead and row[w - 1 - trail] == 0:
            trail += 1
        bits += 8 + max(w - lead - trail, 0) * bpp
    return (bits + 7) // 8


def sidecar_labels():
    have = {}
    for t in SIDECAR_TBLS:
        p = os.path.join(ROOT, "src", t)
        if not os.path.exists(p):
            continue
        for m in re.finditer(r"^(\w+):", open(p, errors="replace").read(), re.M):
            have[m.group(1)] = t
    return have


def parse_wvp(path):
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wvp")
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--label", default="a_sa_helitest")
    ap.add_argument("--prefix", default="SAHT_", help="wrapper label prefix")
    ap.add_argument("--sleep", type=int, default=None,
                    help="game ticks per row; default is gcd(frame_delays)")
    ap.add_argument("--spin-sleep", type=int, default=None,
                    help="run rows matching --spin-match at this sleep and "
                         "emit a <label>_rate segment table for mframew_a0")
    ap.add_argument("--spin-match", default="UGSPIN",
                    help="label prefix counting as a spin row (default UGSPIN)")
    ap.add_argument("--no-expand", action="store_true",
                    help="one row per entry: do NOT repeat a row frame_delays "
                         "times.  Current exports fold the per-entry hold into "
                         "the sleep instead of repeating the label, so a lane "
                         "whose export says \"hold 2t = 1 row x 2t\" wants this.")
    ap.add_argument("--call-entry", action="append", default=[], metavar="N=LABEL",
                    help="emit ani_calla LABEL just before project entry N. "
                         "do_ani_calla is transparent to the frame counter, so "
                         "rate-table row counts are unaffected.")
    ap.add_argument("--wrappers", action="store_true",
                    help="rows already name multipart wrappers; emit them "
                         "directly and generate no single-frame wrappers")
    ap.add_argument("--tickrate", type=int, default=3,
                    help="game ticks per preview tick (3 = 20.8 FPS)")
    ap.add_argument("--no-adjust", action="store_true",
                    help="emit no ani_adjustxy at all.  For a lane whose "
                         "placement is owned by the SPAWNER rather than by "
                         "the lane: MK2 blood is positioned off the victim "
                         "by lineup_with_a11_offset, so an offset in the "
                         "lane would apply on top of it.")
    ap.add_argument("--no-dy", action="store_true",
                    help="zero the Y half of every ani_adjustxy.  For a lane "
                         "whose climb or fall is driven by oyvel+ograv rather "
                         "than by the lane itself: the authored dY would "
                         "otherwise ADD to the physics and double the travel.")
    ap.add_argument("--spin-strips", action="store_true",
                    help="map SPIN1..SPIN5 onto the SAHELI sidecar's blade/body "
                         "strips (SAHSPIN1..5) instead of the stock UGSPIN "
                         "wrappers.  Same anipoints, same picture, a third to "
                         "four fifths of the pixels.")
    ap.add_argument("--loop-from", type=int, default=None, metavar="N",
                    help="with --loop, jump back to ENTRY N instead of the top. "
                         "A lane whose first entries are a one-off run-up (a "
                         "jump, a crouch) must not replay them every cycle.")
    ap.add_argument("--loop", action="store_true",
                    help="end with ani_jump back to the label instead of a 0 "
                         "terminator - for a lane that runs until some other "
                         "condition (a height check) stops it.")
    ap.add_argument("--drop-last", type=int, default=0,
                    help="ignore N trailing entries (parked/scratch frames)")
    ap.add_argument("--drop-first", type=int, default=0, metavar="N",
                    help="ignore N leading entries.  For a VICTIM lane: the "
                         "project holds his stance until the hit lands, but in "
                         "game that wait is the attacker's ani_calla, not rows "
                         "- the takeover is what starts him. Keeping the "
                         "stance would replay it after he has already been hit.")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    calls = {}
    for spec in a.call_entry:
        n, lab = spec.split("=", 1)
        calls[int(n)] = lab
    kv = parse_wvp(a.wvp)
    docs = []
    for i in range(int(kv.get("doc.count", "0"))):
        p = os.path.join(ROOT, "data",
                         os.path.basename(kv.get(f"doc.{i}.path", "")))
        docs.append(img_records(p) if os.path.exists(p) else (b"", []))

    s = f"slot.{a.slot}."
    own = int(kv.get(s + "doc_idx", "0"))
    seq = ints(kv, s + "sequence_frames")
    dly = ints(kv, s + "frame_delays")
    mir = ints(kv, s + "frame_mirror")
    dxs = ints(kv, s + "local_dx")
    dys = ints(kv, s + "local_dy")
    dis = ints(kv, s + "frame_doc_idx")
    if a.drop_last:
        seq = seq[:-a.drop_last]
    if a.drop_first:
        n = a.drop_first
        seq = seq[n:]
        # every per-entry column has to be cut in step or the offsets, holds
        # and mirrors all shift one entry against the frames
        dly, mir, dxs, dys, dis = dly[n:], mir[n:], dxs[n:], dys[n:], dis[n:]

    have = sidecar_labels()
    lines, wrappers, missing = [], [], []
    rowrate = []

# TIMING.  frame_delays are per-entry holds in GAME TICKS.  A lane can only
    # have one sleep, so the sleep is the gcd of the holds and an entry becomes
    # hold/sleep repeated rows - exactly what the exporter prints as
    # "hold 4t = 4 rows x 1t".  Holds of 1,4,4,4... give sleep 1 and 29 rows;
    # holds all 2 give sleep 2 and one row each.
    #
    # state.default_hold is only the hold a NEW frame gets, not the lane's
    # rate - reading it as the sleep made this lane four times too slow.
    # imgtool >= v3.31.0 writes state.tick_hz, a constant: the rate stopped
    # being adjustable, so there is no authored-at value left to record.
    # state.fps is the pre-v3.31.0 spelling and is only read so an old project
    # still reports something sane here.
    tick_hz = float(kv.get('state.tick_hz', kv.get('state.fps', '0')) or 0)
    holds = [dly[i] if i < len(dly) else 1 for i in range(len(seq))]
    if a.sleep is not None:
        sleep, how = a.sleep, "--sleep"
    elif holds:
        g = 0
        for h in holds:
            g = gcd(g, max(1, h))
        sleep, how = max(1, g), "gcd(frame_delays)"
    else:
        sleep, how = DEFAULT_HOLD, "nothing authored -> default"
    # Hoisted: the substitution decides the ENGINE's flip state, and the sign
    # rule inside the loop needs that before it can pick an offset's sign.
    table = dict(SUBST, **SPIN_STRIPS) if a.spin_strips else SUBST
    lines.append(f"{a.label}")
    fx = fy = 0
    pdx = pdy = 0

    for i, fi in enumerate(seq):
        d = dis[i] if i < len(dis) else -1
        d = own if d < 0 else d
        blob, recs = docs[d] if d < len(docs) else (b"", [])
        rec = recs[fi] if fi < len(recs) else None
        name = rec["name"] if rec else f"<idx{fi}>"
        m = mir[i] if i < len(mir) else 0
        want_x, want_y = m & 1, (m >> 1) & 1
        if i in calls:
            lines.append("	.long	ani_calla	; entry %d hook" % i)
            lines.append("	.long	" + calls[i])
        # SUBST FIRST: the sign below depends on the flip state the ENGINE
        # will draw with, and a pre-mirrored substitution changes it.
        sub, extra_mirror = table.get(name, (None, 0))
        if extra_mirror:
            want_x ^= 1

        # THE SIGN RULE - PER FRAME, off this entry's flip, on BOTH axES.
        #
        # The preview draws at  anchor - anieff(ani + dA, size, flip), and
        # anieff mirrors the WHOLE sum (anipoint plus offset) when the entry is
        # flipped.  The engine mirrors only the anipoint - ganiof uses
        # sizex-1-anix - and adds dX to the position separately.  Equate the
        # two and the offset has to invert with the flip on each axis:
        #
        #     dX = flipx ? +dAX : -dAX
        #     dY = flipv ? +dAY : -dAY
        #
        # X USED TO SAY "ALWAYS -dAX", on the reasoning that multi_adjust_xy
        # negates dX under b_fliph and that cancels the preview's X mirror.
        # That cancellation is real but this generator deliberately steps
        # around it: offsets are emitted at BASE facing (see the ordering note
        # below) precisely so a per-entry flip cannot touch them, so the
        # negation never happens and the -dAX was left uncancelled.
        #
        # It cost a shipped bug.  Unflipped entries are identical under both
        # readings, so a_sa_windup - unflipped throughout - verified clean in
        # MAME and the rule looked settled.  Every flipX entry in the dive was
        # landing 2*dAX away: tools/wv_trace_x.py put the drawn centre of
        # BARAKADOWNSMALL slot 0 through five jumps of 96-140px, exactly at the
        # flip transitions, and zero once X mirrors like Y.  The symptom reads
        # as "it jumps all over the X axis between reversing and not
        # reversing", which is precisely what it is.
        _dx = dxs[i] if i < len(dxs) else 0
        ndx = _dx if want_x else -_dx
        _dy = dys[i] if i < len(dys) else 0
        ndy = _dy if want_y else -_dy
        if a.no_dy or a.no_adjust:
            ndy = 0             # oyvel/ograv own Y - see --no-dy
        n = 1 if a.no_expand else max(1, (dly[i] if i < len(dly) else 1) // sleep)
        # sub/extra_mirror were resolved above, before the sign rule - want_x
        # already carries the substitution's mirror, so do NOT toggle it again.
        label = sub or name
        wrap = label if a.wrappers else a.prefix + label

        # ORDER MATTERS, and it is not the obvious one.
        #
        # multi_adjust_xy negates dx against whatever b_fliph is set RIGHT NOW.
        # The lane's dAX values live in the authoring space, so they must be
        # mirrored by the CHARACTER'S facing - the lane's base state - and never
        # by a per-entry flipX, which mirrors that one sprite about its anchor
        # and does not move the anchor at all.
        #
        # So: drop back to base facing, apply the offset there, and only then
        # put the entry's own flipX on.  Emitting the offset while a per-entry
        # flipX was still set is what sent SAHFLIPPED1/2 the wrong way and left
        # Baraka 151px past where the project puts him.  The extra toggles are
        # free - no command row sleeps.
        if a.no_adjust:
            ndx = 0
        need_adj = (ndx, ndy) != (pdx, pdy)
        if fx and need_adj:
            lines.append("	.long	ani_flip")     # back to base facing
            fx = 0
        if need_adj:
            lines.append("	.long	ani_adjustxy")
            lines.append(f"	.word	{ndx - pdx},{ndy - pdy}")
            pdx, pdy = ndx, ndy
        # Only toggle when the state actually differs.  This used to drop
        # to base facing unconditionally and re-mirror after, which is
        # correct but emits a dead ani_flip PAIR between two consecutive
        # flipX entries.  Invisible while every entry carried an offset -
        # --no-dy strips most of them, and then the pairs are most of the
        # lane.
        if want_x != fx:
            lines.append("	.long	ani_flip")     # this entry's own mirror
            fx = want_x
        if want_y != fy:
            lines.append("	.long	ani_flip_v")
            fy = want_y

        if a.loop and a.loop_from == i:
            lines.append(a.label + "_loop")
        flags = ("flipX " if want_x else "") + ("flipY" if want_y else "")
        via = f" (<- {name})" if sub else ""
        rowrate.extend([label] * n)   # one per IMAGE row emitted
        lines.append(f"\t.long\t{wrap}\t; {i:>2} {label}{via} x{n} {flags}".rstrip())
        for _ in range(n - 1):
            lines.append(f"\t.long\t{wrap}")

        if not a.wrappers and wrap not in [w[0] for w in wrappers]:
            wrappers.append((wrap, label))
        if rec and not a.wrappers and label not in have:
            est = est_compressed_bytes(blob, rec)
            missing.append((name, rec["w"], rec["h"], est,
                            os.path.basename(kv.get(f"doc.{d}.path", ""))))

    if a.loop:
        tgt = a.label + ("_loop" if a.loop_from is not None else "")
        lines.append("\t.long\tani_jump,%s\t; loop - the caller ends "
                     "it on a height check" % tgt)
    else:
        lines.append("\t.long\t0\t\t; stop on the final frame")

    # --- segment table for mframew_a0 -----------------------------------
    # MK2 changes rate WITHIN a move rather than running a long lane at one
    # speed (do_wheel_kick 4 then 3, do_kintaro_fatal 3 then 10, and the old
    # heliport 4 then 2).  mframew_a0 takes a0 = [sleep | rows] and leaves a9
    # on the next row, so segments chain.  Rows are classified by LABEL, not
    # by index, so the split survives re-authoring: add a spin frame and the
    # counts follow it.
    if a.spin_sleep:
        runs = []
        for lab in rowrate:
            r = a.spin_sleep if lab.startswith(a.spin_match) else sleep
            if runs and runs[-1][0] == r:
                runs[-1][1] += 1
            else:
                runs.append([r, 1])
        lines.append("")
        lines.append(a.label + "_rate")
        for r, cnt in runs:
            lines.append("	.word	%d,%d		; sleep %d (%.1ffps) x %d rows"
                         % (r, cnt, r, TICK_HZ / r, cnt))
        lines.append("	.word	0		; end of segments")
        print("; rate segments: " + ", ".join(
              "%d rows @ sleep %d" % (c, r) for r, c in runs), file=sys.stderr)
    lines.append("")
    for wrap, name in wrappers:
        lines.append(f"{wrap}\t.long\t{name},0")

    text = "\n".join(lines) + "\n"
    if a.out:
        open(a.out, "w").write(text)
        print(f"wrote {a.out}")
    else:
        print(text)


    total = sum(max(1, h // sleep) for h in holds)
    print("; %d entries, %d rows" % (len(seq), total), file=sys.stderr)
    print("; sleep %d via %s -> %d game ticks, %.2ffps in game"
          % (sleep, how, total * sleep, TICK_HZ / sleep), file=sys.stderr)
    # This used to read `if hold is None and 0 < fps <= TICK_HZ - 1.0`, and
    # `hold` was never assigned anywhere in the file: a NameError that killed
    # every run AFTER the lane had already been written, so the output looked
    # fine and the exit status did not.
    #
    # What it was guarding is also gone.  It warned that an adjustable preview
    # rate was not a whole divisor of 54.7; imgtool >= v3.31.0 pins the rate to
    # the hardware, so no new project can carry one.  An OLD project still can,
    # and that case is worth catching: its frame_delays are preview ticks, so
    # the gcd of them is not a game-tick sleep.
    if a.sleep is None and tick_hz > 0 and abs(tick_hz - TICK_HZ) > 0.05:
        scale = TICK_HZ / tick_hz
        print("; WARNING authored at %.4f Hz, not the hardware %.4f - these "
              "frame_delays are PREVIEW ticks, so the sleep above is not in "
              "game ticks.  Scale it by %.2f (-> %d), or re-save the project "
              "from imgtool >= v3.31.0."
              % (tick_hz, TICK_HZ, scale, max(1, round(sleep * scale))),
              file=sys.stderr)
    print(";   pass this as the sleep:  movk %d,a0" % sleep, file=sys.stderr)
    if missing:
        print("\n; MISSING ART - not in any sidecar TBL:", file=sys.stderr)
        seen = set()
        tot = 0
        for name, w, h, est, lib in missing:
            if name in seen:
                continue
            seen.add(name)
            tot += est
            print(f";   {name:<14} {w:>3}x{h:<4} ~{est:>6,} bytes  {lib}",
                  file=sys.stderr)
        print(f";   ---- {tot:,} bytes of video ROM needed", file=sys.stderr)


main()
