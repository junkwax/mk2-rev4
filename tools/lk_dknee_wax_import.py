#!/usr/bin/env python3
"""Generate the DOUBLE KNEE SPIKE's placement from data/KANGDBLKNEE2.WAX.

    python tools/lk_dknee_wax_import.py           rewrite the generated block
    python tools/lk_dknee_wax_import.py --check   exit 1 if it is stale (Phase D)

The IMGTOOL project holds two lanes played from one clock:

  LIU KANG  KANG3.IMG LKKNEE1-3, LKDUBLKNEE1-4, LKBACKFIST1 - the knee and its
            carry-on.  The game already plays this lane: a_lkdubknee is
            generated from DUBLKNEESQ by tools/lk_dubknee_seq_import.py.  So
            here it is only CHECKED - same frames, same holds as the sequence
            x4 - and the build fails if the two disagree, because then the
            victim half below is timed against a lane the game does not play.

  VICTIM    stunned on a stumble pose for the knee and the wind-up (the game's
            r_lk_chainstun - nothing to generate), then, on the tick
            LKDUBLKNEE3 lands, kicked DOWN through his SWEEP FALL: LKSWEEPFALL1,
            4 and 5, unmirrored (facing Liu Kang's way).  Those three are what
            this writes - where each goes and how long it holds - into
            src/MKLKDK.ASM for lk_spike.

PLACEMENT.  local_dx/dy are ANIPOINT offsets from the shared origin, which is
Liu Kang's anchor (his slot carries none).  IMGTOOL mirrors a frame about its
anchor, so the victim's anchor lands at

    Liu Kang + ( H-mirrored ? +dx : -dx ,  V-mirrored ? +dy : -dy )

in Liu Kang's facing - tools/raiden_lift_wax_import.py's rule, which the game
reproduces with match_ani_points + multi_adjust_xy (MKUTIL.ASM).  The game draws
EACH VICTIM'S OWN sweep fall there, out of his anitab1 016h: FALL1 = part 1
row 0, FALL4 = part 1 row 3, FALL5 = the last frame of part 2 (the flat one) -
which is exactly Liu Kang's FALL1/4/5, and every non-boss fighter has those
rows (part 1 runs 4-6 frames).
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, ROOT)
import jade_impale_wax_import as J          # noqa: E402  (WAX + IMG readers)
import lk_dubknee_seq_import as S           # noqa: E402  (DUBLKNEESQ reader)

WAX = os.path.join(ROOT, "data", "KANGDBLKNEE2.WAX")
ASM = os.path.join(ROOT, "src", "MKLKDK.ASM")
BEGIN = "* --- BEGIN GENERATED (tools/lk_dknee_wax_import.py) - do not hand-edit\n"
END = "* --- END GENERATED (lk_dknee_wax_import)\n"
CONTACT = "LKDUBLKNEE3"
SPIKE = ("LKSWEEPFALL1", "LKSWEEPFALL4", "LKSWEEPFALL5")
TAGS = ("f1", "f4", "f5")


def die(msg):
    sys.exit("lk_dknee_wax_import: " + msg)


def lanes(kv):
    out = []
    for n in range(int(kv.get("slot.count", "0"))):
        seq = J.ints(kv, f"slot.{n}.sequence_frames")
        base = int(kv.get(f"slot.{n}.doc_idx", "-1"))
        if not seq or base < 0 or kv.get(f"slot.{n}.visible") != "1":
            continue
        if int(kv.get(f"slot.{n}.order", "-1")) < 0:
            continue                    # a SOURCE TAB (order -1): scratch, not in the scene
        fdoc = J.ints(kv, f"slot.{n}.frame_doc_idx")
        get = lambda k: (J.ints(kv, f"slot.{n}.{k}") + [0] * len(seq))[:len(seq)]
        for k in ("motion_dx", "motion_dy", "dual_on", "visible_from", "visible_until"):
            if any(get(k)):
                die(f"slot {n} uses {k}, which nothing in the game reproduces")
        frames = []
        for i, fi in enumerate(seq):
            d = fdoc[i] if i < len(fdoc) and fdoc[i] >= 0 else base
            recs, _ = J.read_img(os.path.join(ROOT, "data", J.doc_file(kv, d)))
            if not 0 <= fi < len(recs):
                die(f"slot {n} frame {i}: index {fi} is outside {J.doc_file(kv, d)}")
            frames.append(recs[fi]["name"])
        out.append(dict(slot=n, frames=frames, holds=get("frame_delays"),
                        dx=get("local_dx"), dy=get("local_dy"), m=get("frame_mirror")))
    return out


def starts(holds):
    t, out = 0, []
    for h in holds:
        out.append(t)
        t += h
    return out


def build():
    kv = J.parse_wax(WAX)
    ls = lanes(kv)
    lk = [l for l in ls if CONTACT in l["frames"]]
    vic = [l for l in ls if any(f in SPIKE for f in l["frames"])]
    if len(lk) != 1 or len(vic) != 1:
        die(f"want one Liu Kang lane (with {CONTACT}) and one victim lane (with "
            f"{SPIKE}); found {len(lk)} and {len(vic)}")
    lk, vic = lk[0], vic[0]
    if any(lk["dx"]) or any(lk["dy"]) or any(lk["m"]):
        die(f"Liu Kang's slot {lk['slot']} must sit on the origin, unmirrored - "
            f"it IS the anchor the victim is placed off")

    # the Liu Kang lane must be the one the game plays
    data = S.IMG.read_bytes()
    seq = S.read_sequence(data, S.image_names(data), S.SEQ)
    want = [(n, h * S.TICKS_PER_PREVIEW) for n, h in seq]
    have = list(zip(lk["frames"], lk["holds"]))
    if have != want:
        die(f"Liu Kang's lane in {os.path.basename(WAX)} is {have}, but the game "
            f"plays {S.SEQ} as {want} - re-time one to match the other")

    # the spike: two consecutive V-mirrored knockdown frames from the contact tick
    t_lk = dict(zip(lk["frames"], starts(lk["holds"])))
    t_v = starts(vic["holds"])
    i = vic["frames"].index(SPIKE[0])
    if vic["frames"][i:] != list(SPIKE):
        die(f"victim lane must END on {', '.join(SPIKE)}; it is {vic['frames']}")
    if t_v[i] != t_lk[CONTACT]:
        die(f"the spike starts on tick {t_v[i]} but {CONTACT} lands on tick "
            f"{t_lk[CONTACT]} - he must go down on the contact frame")
    pre = set(vic["frames"][:i])
    if len(pre) != 1:
        die(f"before the spike the victim must hold ONE stunned pose; it has {sorted(pre)}")
    out = []
    for k, name in enumerate(SPIKE):
        j = i + k
        m = vic["m"][j]
        if m != 0:
            die(f"{name} must be unmirrored (frame_mirror 0), not {m}: lk_spike "
                f"draws him facing Liu Kang's way, right side up")
        x = vic["dx"][j] if m & 1 else -vic["dx"][j]
        y = vic["dy"][j] if m & 2 else -vic["dy"][j]
        if vic["holds"][j] < 1:
            die(f"{name} holds {vic['holds'][j]} ticks")
        out.append((name, x, y, vic["holds"][j]))
    return out


def render(spike):
    s = [BEGIN,
         "* data/KANGDBLKNEE2.WAX: the victim's anchor off Liu Kang's, in his facing,\n",
         "* and the ticks each sweep-fall pose holds.\n"]
    for tag, (name, x, y, hold) in zip(TAGS, spike):
        s.append(f"lksp_{tag}_x\t.set\t{x}\t; {name}\n")
        s.append(f"lksp_{tag}_y\t.set\t{y}\n")
        s.append(f"lksp_{tag}_hold\t.set\t{hold}\n")
    s.append(END)
    return "".join(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    want = render(build())
    raw = open(ASM, newline="").read()
    crlf = "\r\n" in raw                        # MKLKDK.ASM is CRLF: keep it so
    text = raw.replace("\r\n", "\n")
    try:
        b = text.index(BEGIN)
        e = text.index(END) + len(END)
    except ValueError:
        die("markers not found in src/MKLKDK.ASM")
    if text[b:e] == want:
        print("lk_spike placement OK")
        return 0
    if a.check:
        print("lk_spike placement DRIFTED from data/KANGDBLKNEE.WAX\n--- in src/MKLKDK.ASM\n"
              + text[b:e] + "+++ from the WAX\n" + want
              + "regenerate: python tools/lk_dknee_wax_import.py")
        return 1
    with open(ASM, "w", newline="\r\n" if crlf else "\n") as f:
        f.write(text[:b] + want + text[e:])
    print("rewrote lk_spike placement")
    return 0


if __name__ == "__main__":
    sys.exit(main())
