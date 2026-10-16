#!/usr/bin/env python3
"""Generate JADE's staff impale lanes from data/JDIMPALE2.WAX.

    python tools/jade_impale_wax_import.py           rewrite the generated block
    python tools/jade_impale_wax_import.py --check   exit 1 if it is stale

The IMGTOOL project is the source of truth for what Jade does while the victim
is in the air: two slots, played together from one tick source.

  BODY  Jade herself, on Kitana-body frames out of KAT1-9.IMG (her fighter
        art is Kitana's in her own palette).  Some frames are MIRRORED.
  ROD   UMK3's staff, RODIMPALE1-7 out of KITANA11.IMG (UMK3's JDFATA2 /
        ANIM_ROD_IMPALE), on its own 16-colour ROD_P - so it rides a separate
        object, exactly as her victory staff does (jade_victory, MKCANNED).

Both become ordinary animation lanes in src/MKFN.ASM (fn3_anitab2 rows 0ch and
0dh), stepped by double_mframew in do_jade_impale (MKDEATH.ASM):

  a_jade_impale   ani_flip where the mirror state changes, ani_adjustxy for
                  the WAX's per-frame offset, then the frame
  a_jade_rod      ani_adjustxy + a one-piece frame list per RODIMPALE frame

OFFSETS.  IMGTOOL's local_dx/dy are ANIPOINT offsets: an unmirrored frame's
art lands at origin - (anix + dx), a mirrored one mirrored about the same
point, so the anchor sits at origin - dx unmirrored and origin + dx mirrored
(y: origin - dy).  The origin is Jade's anchor when the lane starts - the rod
object starts on it too.  ani_adjustxy is multi_adjust_xy, which negates x on
a flipped object, so each row is the anchor's step in world x times the flip
the frame is drawn with.  That is facing-proof: a Jade facing left mirrors the
whole lane, rows and all.

THE TIP.  Where the victim is dropped is read off the art, not tuned: the top
opaque row of the LAST rod frame, in world coordinates off that origin, goes
out as `jade_impale_geom` with the lane's hold and the rod's depth.

Also emitted: JDROD_P, KITANA11.IMG's ROD_P verbatim (data/JDROD.LOD is POF>).

Unsupported WAX features (visible windows, motion, dual draws, per-frame z,
a mirrored rod frame, uneven holds - double_mframew has one sleep) are
refused rather than dropped silently.
"""
import argparse
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAX = os.path.join(ROOT, "data", "JDIMPALE2.WAX")
ASM = os.path.join(ROOT, "src", "MKFN.ASM")
ROD_IMG = "KITANA11.IMG"
ROD_STEM = "RODIMPALE"
ROD_PAL = "ROD_P"

BEGIN = ";>>>WAX BEGIN jade_impale"
END = ";<<<WAX END jade_impale"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")

UNSUPPORTED = ("motion_dx", "motion_dy", "motion_cap_x", "motion_cap_y", "dual_on")
WINDOWS = ("visible_from", "visible_until", "frame_z")   # the victim lane's only: its
# show windows are its timing, and its z is moot - the game draws him in front

VICTIM_KEY = "SWEEPFALL"        # the victim lane: a fighter's SWEEPFALL5 (lying flat)
# --seed-victim: the template victim, and UMK3 jade_impale's drop (arcade literals)
SEED_IMG, SEED_REC = "NUJAX7.IMG", "JXSWEEPFALL5"   # Jax's SWEEPFALL5
SEED_START = 54         # lane ticks: when the game dropped him (hang ~040h after the top)
SEED_DROP_H = 0xe0      # his back starts this far above the tip
SEED_V0, SEED_G = 4, 2  # impale_call: oyvel SCY(0x40000), ograv SCY(0x20000)
SEED_LAND = 5           # ticks he sits where he lands before he starts to slide
SEED_SLIDE, SEED_SLIDE_T = 10, 5    # ...then this many px down, 1px every _T ticks


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


_img_cache = {}


def read_img(path):
    """{index: record} plus {palette name: words}"""
    if path in _img_cache:
        return _img_cache[path]
    b = open(path, "rb").read()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(b, 0)[:3]
    recs = []
    for i in range(imgcnt):
        r = IMAGE.unpack_from(b, oset + i * IMAGE.size)
        w, h, off = r[4], r[5], r[7]
        stride = (w + 3) & ~3
        recs.append(dict(name=r[0].split(b"\0", 1)[0].decode("latin-1"),
                         ax=s16(r[2]), ay=s16(r[3]), w=w, h=h, palnum=r[6],
                         px=[b[off + y * stride:off + y * stride + w] for y in range(h)]))
    pals = {}
    p0 = oset + imgcnt * IMAGE.size
    for i in range(palcnt - 3):
        name, _pad, _bpp, cnt, fo, *_ = PALETTE.unpack_from(b, p0 + i * PALETTE.size)
        pals[name.split(b"\0", 1)[0].decode("latin-1")] = \
            [struct.unpack_from("<H", b, fo + 2 * k)[0] for k in range(cnt)]
    _img_cache[path] = (recs, pals)
    return recs, pals


def parse_wax(path):
    kv = {}
    for line in open(path, "r", errors="replace"):
        line = line.rstrip("\r\n")
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def ints(kv, key):
    v = kv.get(key, "")
    return [int(x) for x in v.split(",") if x.strip() != ""] if v else []


def doc_file(kv, idx):
    return os.path.basename(kv.get(f"doc.{idx}.path", "").replace("\\", "/"))


def lane(kv, n):
    """one slot, resolved to records"""
    seq = ints(kv, f"slot.{n}.sequence_frames")
    fdoc = ints(kv, f"slot.{n}.frame_doc_idx")
    base = int(kv.get(f"slot.{n}.doc_idx", "-1"))
    frames = []
    for i, fi in enumerate(seq):
        d = fdoc[i] if i < len(fdoc) and fdoc[i] >= 0 else base
        name = doc_file(kv, d)
        recs, _ = read_img(os.path.join(ROOT, "data", name))
        if not 0 <= fi < len(recs):
            sys.exit(f"slot {n} frame {i}: index {fi} is outside {name}")
        frames.append(recs[fi])
    get = lambda k: (ints(kv, f"slot.{n}.{k}") + [0] * len(seq))[:len(seq)]
    for k in UNSUPPORTED:
        if any(get(k)):
            sys.exit(f"slot {n} uses {k}; the generated lane cannot express it")
    return dict(slot=n, frames=frames, holds=get("frame_delays"), dx=get("local_dx"),
                dy=get("local_dy"), mirror=get("frame_mirror"),
                order=int(kv.get(f"slot.{n}.order", "-1")),
                hold_end=int(kv.get(f"slot.{n}.hold_end", "0")),
                visible_from=get("visible_from"), visible_until=get("visible_until"),
                frame_z=get("frame_z"), doc_idx=base, seq=seq)


def the_lanes(kv, need_victim=True):
    body, rod, vic = [], [], []
    for n in range(int(kv.get("slot.count", "0"))):
        if int(kv.get(f"slot.{n}.order", "-1")) < 0 or not ints(kv, f"slot.{n}.sequence_frames"):
            continue
        if kv.get(f"slot.{n}.visible", "1") != "1":
            continue                    # a hidden lane is the author's scratch
        ln = lane(kv, n)
        if not all(VICTIM_KEY in f["name"] for f in ln["frames"]):
            for k in WINDOWS:
                if any(ln[k]):
                    sys.exit(f"slot {n} uses {k}; only the victim lane may")
        if all(f["name"].startswith(ROD_STEM) for f in ln["frames"]):
            rod.append(ln)
        elif all(VICTIM_KEY in f["name"] for f in ln["frames"]):
            vic.append(ln)
        else:
            body.append(ln)
    if len(body) != 1 or len(rod) != 1 or len(vic) > 1 or (need_victim and not vic):
        sys.exit(f"JDIMPALE2.WAX: expected one body slot, one {ROD_STEM} slot and one "
                 f"victim ({VICTIM_KEY}) slot, found {len(body)}, {len(rod)} and {len(vic)}"
                 + ("" if vic or not need_victim else
                    " - run with --seed-victim to add the victim lane"))
    return body[0], rod[0], (vic[0] if vic else None)


def tip_of(rod):
    """the last rod frame's top opaque row, off the origin (facing right)"""
    last, a = rod["frames"][-1], anchors(rod)[-1]
    row = next((y for y in range(last["h"]) if any(last["px"][y])), None)
    if row is None:
        sys.exit(f"{last['name']} is empty")
    cols = [x for x in range(last["w"]) if last["px"][row][x]]
    return a[0] - last["ax"] + (cols[0] + cols[-1]) // 2, a[1] - last["ay"] + row


def grip_of(body, rod):
    """the TOP of her hand on the staff, off the origin (facing right).

    She holds the last pose for good (wait_forever) and that is the one the
    victim comes to rest against, so this is where HE must stop.  The only
    columns of her sprite that reach the staff's own three are the fingers
    round it, so her topmost opaque row inside them IS the top of the grip -
    no hand-picked number, and it moves if the pose is re-authored.
    """
    r, ra = rod["frames"][-1], anchors(rod)[-1]
    x0 = ra[0] - r["ax"]
    x1 = x0 + r["w"]
    f, a = body["frames"][-1], anchors(body)[-1]
    m = body["mirror"][-1] & 1
    bx = a[0] + f["ax"] - f["w"] + 1 if m else a[0] - f["ax"]
    by = a[1] - f["ay"]
    for y in range(f["h"]):
        for x in range(f["w"]):
            wx = bx + (f["w"] - 1 - x) if m else bx + x
            if x0 <= wx < x1 and f["px"][y][x]:
                return by + y
    sys.exit(f"{f['name']} never touches {r['name']}'s columns ({x0}..{x1 - 1}): "
             f"the grip cannot be measured, so the victim has no floor to stop at")


def body_box(rec, m):
    """a record's drawn box off its anchor, facing right, as mpart_bounds sees it
    (left/right exclusive-right, a mirrored piece hung off w-1-anix)"""
    left = -(rec["w"] - 1 - rec["ax"]) if m else -rec["ax"]
    top = -rec["ay"]
    return left, left + rec["w"], top, top + rec["h"]


def victim_table(vic, tip):
    """the victim's authored fall: per frame [show tick, hold, anchor x, anchor y]"""
    recs = {f["name"] for f in vic["frames"]}
    if len(recs) != 1:
        sys.exit(f"victim slot {vic['slot']} uses {sorted(recs)}: the game plays ONE pose "
                 f"(his own SWEEPFALL5 frame), so the lane must be one record")
    mir = {m & 1 for m in vic["mirror"]}
    if len(mir) != 1 or any(m & ~1 for m in vic["mirror"]):
        sys.exit(f"victim slot {vic['slot']}: every frame must share one H mirror")
    m = mir.pop()
    if not vic["hold_end"]:
        sys.exit(f"victim slot {vic['slot']} must hold its end - he stays on the staff")
    vf, vu = vic["visible_from"], vic["visible_until"]
    rows, t = [], 0
    for i, hold in enumerate(vic["holds"]):
        start, end = t, t + max(hold, 1)
        t = end
        if vf[i] > 0:
            start = max(start, vf[i])
        if vu[i] > 0:
            end = min(end, vu[i])
        if end <= start and i < len(vic["holds"]) - 1:
            sys.exit(f"victim frame {i} is never on screen")
        rows.append([start, end - start])
    for i in range(1, len(rows)):
        if rows[i][0] != rows[i - 1][0] + rows[i - 1][1]:
            sys.exit(f"victim frames {i - 1} and {i} are not back to back "
                     f"(ticks {rows[i - 1]} then {rows[i]})")
    rows[-1][1] = 0                                    # hold_end: for good
    at = anchors(vic)
    left, right, top, bottom = body_box(vic["frames"][0], m)
    contact = next((i for i, a in enumerate(at) if a[1] + bottom >= tip[1]), None)
    if contact is None:
        sys.exit("the victim lane never brings his back down to the staff tip")
    return dict(slot=vic["slot"], m=m, rows=rows, at=at, contact=contact,
                cx=(left + right) // 2, top=top, rec=vic["frames"][0]["name"])


def anchors(ln):
    """the anchor's world offset from the origin, per frame (facing right)"""
    out = []
    for i in range(len(ln["frames"])):
        m = ln["mirror"][i] & 1
        out.append((ln["dx"][i] if m else -ln["dx"][i], -ln["dy"][i]))
    return out


def pad_to(ln, n):
    """hold_end: a shorter lane stands on its last frame while the other plays on"""
    k = n - len(ln["frames"])
    if k <= 0:
        return
    if not ln["hold_end"]:
        sys.exit(f"slot {ln['slot']} is {k} frame(s) short and does not hold its end; "
                 f"double_mframew needs the two lanes the same length")
    for key in ("frames", "holds", "dx", "dy", "mirror"):
        ln[key] = ln[key] + [ln[key][-1]] * k


def frame_list_labels(asm):
    """frame-list label for each record name: its own label, or the list that
    draws its pieces (KT1VIC1 .long KT1VICTORY1A,KT1VICTORY1B,0)"""
    out = {}
    lines = asm.split(chr(10))
    for i, line in enumerate(lines):
        m = re.match(r"^(\w+)\s*(?:\.long\s+(\w+))?", line)
        if not m or not m.group(1) or line[:1].isspace():
            continue
        first = m.group(2)
        if first is None and i + 1 < len(lines):
            m2 = re.match(r"^\s+\.long\s+(\w+)", lines[i + 1])
            first = m2.group(1) if m2 else None
        out.setdefault(m.group(1), m.group(1))
        if first and re.match(r"^\w+[A-Z]$", first):
            out.setdefault(first[:-1], m.group(1))
    return out


def build():
    kv = parse_wax(WAX)
    body, rod, vic = the_lanes(kv)
    n = max(len(body["frames"]), len(rod["frames"]))
    pad_to(body, n)
    pad_to(rod, n)
    if len(rod["frames"]) != n:
        sys.exit(f"body has {n} frames, the rod {len(rod['frames'])}: double_mframew "
                 f"stops on the rod's terminator, so they must match")
    holds = set(body["holds"] + rod["holds"])
    if len(holds) != 1 or min(holds) < 1:
        sys.exit(f"uneven or zero holds {sorted(holds)}: double_mframew plays both lanes "
                 f"at one sleep")
    hold = holds.pop()
    if any(m & ~1 for m in body["mirror"]):
        sys.exit("a body frame is V-mirrored; the lane only flips horizontally")
    if any(rod["mirror"]):
        sys.exit("a rod frame is mirrored; the rod object keeps Jade's facing")
    if body["mirror"][-1]:
        sys.exit("the last body frame is mirrored; she would be left facing away")

    asm = open(ASM, "rb").read().decode("latin-1").replace("\r\n", "\n")
    asm = asm[:asm.index(BEGIN)] + asm[asm.index(END):]     # not our own lists
    lists = frame_list_labels(asm)
    gen_lists = []
    for f in body["frames"]:
        if f["name"] not in lists:
            # a single record packed on its own (JDIMPALE6 in MOVEART2.LOD):
            # its one-piece frame list comes with the lane
            f["list"] = f["name"] + "_F"
            if f["list"] not in gen_lists:
                gen_lists.append(f["list"])
        else:
            f["list"] = lists[f["name"]]

    out = [BEGIN,
           "* GENERATED from data/JDIMPALE2.WAX (body slot %d, rod slot %d) by"
           % (body["slot"], rod["slot"]),
           "* tools/jade_impale_wax_import.py.  Edit the project, not this block.",
           "*",
           "* JADE's staff impale (do_jade_impale, MKDEATH.ASM): what she does while",
           "* the victim is in the air.  Two lanes stepped together by double_mframew,",
           "* both starting on Jade's anchor: her body (fn3_anitab2 0ch) and UMK3's",
           "* staff on its own object and palette (0dh).  ani_adjustxy rows are the",
           "* anchor's step in world x times the flip that frame is drawn with, so the",
           "* lane mirrors whole for a Jade facing left.",
           "*",
           "	.global	jade_impale_geom",
           ""]

    out.append("a_jade_impale")
    prev_m, prev = 0, (0, 0)
    for f, m, a in zip(body["frames"], body["mirror"], anchors(body)):
        m &= 1
        if m != prev_m:
            out.append("	.long	ani_flip")
        ddx, ddy = a[0] - prev[0], a[1] - prev[1]
        if ddx or ddy:
            out.append("	.long	ani_adjustxy")
            out.append(f"	.word	{-ddx if m else ddx},{ddy}")
        note = [] if f["list"] == f["name"] else [f["name"]]
        if m:
            note.append("mirrored")
        out.append(f"	.long	{f['list']}" + ("		; " + ", ".join(note) if note else ""))
        prev_m, prev = m, a
    out.append("	.long	0")
    out.append("")

    out.append("a_jade_rod")
    rod_at = anchors(rod)
    prev = rod_at[0]          # the first frame's offset rides in the geom:
    for i, (f, a) in enumerate(zip(rod["frames"], rod_at)):   # gmo_proc
        ddx, ddy = a[0] - prev[0], a[1] - prev[1]              # builds the
        if ddx or ddy:                                          # object off
            # entry 0, so the lane has to open on a frame, not a command
            out.append("	.long	ani_adjustxy")
            out.append(f"	.word	{ddx},{ddy}")
        out.append(f"	.long	JDROD{i + 1}")
        prev = a
    out.append("	.long	0")
    out.append("")
    for lab in gen_lists:
        out.append(f"{lab}	.long	{lab[:-2]},0		; packed on its own - see MOVEART2.LOD")
    if gen_lists:
        out.append("")
    for i, f in enumerate(rod["frames"]):
        out.append(f"JDROD{i + 1}	.long	{f['name']},0")
    out.append("")

    last = rod["frames"][-1]
    tip_x, tip_y = tip_of(rod)
    behind = 1 if rod["order"] < body["order"] else 0
    grip = grip_of(body, rod)
    out.append("; [hold, staff tip x, tip y, staff behind her, staff start x, y, her grip] -")
    out.append("; all off Jade's anchor at the lane's start, facing right.  The tip is where")
    out.append("; the victim's back comes down, measured off " + last["name"] + "'s top")
    out.append("; opaque row; the start is where the staff object goes before its lane")
    out.append("; (multi_adjust_xy, after match_ani_points puts it on her anchor).  [6] is")
    out.append("; the TOP OF HER HAND on the staff - the row no part of him may reach, off")
    out.append("; which do_jade_impale takes jdi_floor_y (MKDEATH.ASM).")
    out.append("jade_impale_geom")
    out.append(f"	.word	{hold},{tip_x},{tip_y},{behind},{rod_at[0][0]},{rod_at[0][1]},{grip}")
    out.append("")

    v = victim_table(vic, (tip_x, tip_y))
    out.append(f"; THE VICTIM (slot {v['slot']}, authored on {v['rec']}): his fall onto the tip,")
    out.append("; frame by frame, as ANCHOR positions off Jade's anchor at the lane's start,")
    out.append("; facing right, on the lane's clock.  He is drawn on his OWN knockdown landing")
    out.append("; frame; the template's drawn box (middle and TOP off its anchor) is what the")
    out.append("; game corrects each victim by: centred on the staff, the tip out of every")
    out.append("; body by as much as it comes out of this one.")
    out.append("; [frames, contact frame (the stab + blood), template middle x, TOP, mirrored]")
    out.append("; then per frame [show tick, hold (0 = for good), anchor x, anchor y]")
    out.append("	.global	jade_impale_vic")
    out.append("jade_impale_vic")
    out.append(f"	.word	{len(v['rows'])},{v['contact']},{v['cx']},{v['top']},{v['m']}")
    for (show, hl), (x, y) in zip(v["rows"], v["at"]):
        out.append(f"	.word	{show},{hl},{x},{y}")
    out.append("")

    recs, pals = read_img(os.path.join(ROOT, "data", ROD_IMG))
    if ROD_PAL not in pals:
        sys.exit(f"{ROD_IMG} has no {ROD_PAL}")
    words = pals[ROD_PAL]
    out.append(f"; {ROD_IMG} {ROD_PAL} verbatim - data/JDROD.LOD is POF>, so the staff")
    out.append("; object takes this with getfpal (do_jade_impale).")
    out.append("	.global	JDROD_P")
    out.append("JDROD_P")
    out.append(f"	.word	 {len(words)}")
    for k in range(0, len(words), 8):
        out.append("	.word	" + ",".join(f"0{w:04X}H" for w in words[k:k + 8]))
    out.append(END)
    return "\n".join(out) + "\n"


def splice(text, block):
    a = text.index(BEGIN)
    b = text.index(END) + len(END)
    b = text.index("\n", b) + 1
    return text[:a] + block + text[b:]


def seed_victim():
    """(re)write the victim lane in the WAX.

    With a victim slot already there, its LAST frame is where he rests: its
    record, doc, mirror, z and depth are kept, and only x is moved - his drawn
    middle onto the staff.  Without one, the SEED_* template rests with its
    top 16px under the tip.  Either way: he falls from SEED_DROP_H above at
    UMK3's speeds, lands SEED_SLIDE px above the rest, sits SEED_LAND ticks,
    then slides down 1px every SEED_SLIDE_T ticks to it and stays."""
    raw = open(WAX, "rb").read().decode("latin-1")
    nl = "\r\n" if "\r\n" in raw else "\n"
    kv = parse_wax(WAX)
    body, rod, vic = the_lanes(kv, need_victim=False)
    tip_x, tip_y = tip_of(rod)
    count = int(kv["slot.count"])
    if vic:
        slot, d, idx = vic["slot"], vic["doc_idx"], vic["seq"][-1]
        rec, m, z = vic["frames"][-1], vic["mirror"][-1] & 1, vic["frame_z"][-1]
        rest_y = anchors(vic)[-1][1]
        folder_path = kv[f"doc.{d}.path"]
    else:
        recs, _ = read_img(os.path.join(ROOT, "data", SEED_IMG))
        idx = next(i for i, r in enumerate(recs) if r["name"] == SEED_REC)
        rec, m, z = recs[idx], 1, 1
        rest_y = tip_y + 16 - body_box(rec, m)[2]
        slot = next(s for s in range(count) if not ints(kv, f"slot.{s}.sequence_frames")
                    and s not in (body["slot"], rod["slot"]))
        folder_path = kv["doc.0.path"].rsplit("\\", 1)[0] + "\\" + SEED_IMG
        d = None
    left, right, top, bottom = body_box(rec, m)
    ax_x = tip_x - (left + right) // 2       # his middle on the staff
    land_y = rest_y - SEED_SLIDE
    ys, y, vel = [], tip_y - SEED_DROP_H - bottom, SEED_V0
    while y < land_y:                         # UMK3's fall, his back from _DROP_H up
        ys.append(y)
        y += vel
        vel += SEED_G
    fall = len(ys)
    ys += [land_y + k for k in range(SEED_SLIDE + 1)]  # lands, then slides slowly
    n = len(ys)
    delays = [SEED_START + 1] + [1] * (fall - 1) + [SEED_LAND] + [SEED_SLIDE_T] * SEED_SLIDE
    xs = [ax_x if m else -ax_x] * n          # mirrored: anchor = origin + dx
    lines = {
        "visible": "1", "hold_end": "1",
        "sequence_frames": ",".join([str(idx)] * n),
        "default_frames": ",".join([str(idx)] * n),
        "frame_delays": ",".join(str(v) for v in delays),
        "local_dx": ",".join(str(v) for v in xs),
        "local_dy": ",".join(str(-v) for v in ys),
        "visible_from": ",".join([str(SEED_START)] + ["0"] * (n - 1)),
        "visible_until": ",".join(["0"] * n),
        "frame_mirror": ",".join([str(m)] * n),
        "frame_z": ",".join([str(z)] * n),
        "frame_doc_idx": ",".join(["-1"] * n),
    }
    for k in ("motion_dx", "motion_dy", "motion_cap_x", "motion_cap_y",
              "dual_on", "dual_dx", "dual_dy", "dual_z"):
        lines[k] = ",".join(["0"] * n)
    text = raw.replace("\r\n", "\n")
    if d is None:
        docs = int(kv["doc.count"])
        d = next((i for i in range(docs) if doc_file(kv, i).upper() == SEED_IMG), None)
        if d is None:
            d = docs
            text = text.replace(f"doc.count={docs}\n", f"doc.count={docs + 1}\n", 1)
            last = f"doc.{docs - 1}.marked={kv.get(f'doc.{docs - 1}.marked', '')}\n"
            assert last in text, last
            text = text.replace(last, last + f"doc.{d}.path={folder_path}\n"
                                             f"doc.{d}.marked={idx}\n", 1)
        orders = [int(kv.get(f"slot.{s}.order", "-1")) for s in range(count) if s != slot]
        lines["order"] = str(max(orders) + 1)
        lines["doc_idx"] = str(d)
        lines["doc_path"] = folder_path
    for k, val in lines.items():
        key = f"slot.{slot}.{k}="
        pat = "^" + re.escape(key) + ".*$"
        if not re.search(pat, text, re.M):
            sys.exit(f"{key} is not in the WAX - cannot seed slot {slot}")
        text = re.sub(pat, lambda _m: key + val, text, count=1, flags=re.M)
    open(WAX, "wb").write(text.replace("\n", nl).encode("latin-1"))
    print(f"seeded the victim lane in slot {slot}: {rec['name']}, {n} frames from tick "
          f"{SEED_START}, lands at anchor y {land_y}, rests at {rest_y}, middle on the "
          f"staff at x {tip_x} (tip {tip_x},{tip_y})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--seed-victim", action="store_true",
                    help="(re)write the victim's fall into the WAX, then import")
    args = ap.parse_args()
    if args.seed_victim:
        seed_victim()
    raw = open(ASM, "rb").read().decode("latin-1")
    crlf = "\r\n" in raw
    text = raw.replace("\r\n", "\n")
    if BEGIN not in text or END not in text:
        sys.exit(f"{os.path.basename(ASM)}: no {BEGIN!r} / {END!r} markers")
    new = splice(text, build())
    if new == text:
        print("a_jade_impale OK (matches JDIMPALE2.WAX)")
        return 0
    if args.check:
        print("a_jade_impale: src/MKFN.ASM differs from JDIMPALE2.WAX - run "
              "tools/jade_impale_wax_import.py")
        return 1
    if crlf:
        new = new.replace("\n", "\r\n")
    open(ASM, "wb").write(new.encode("latin-1"))
    print("rewrote a_jade_impale from JDIMPALE2.WAX")
    return 0


if __name__ == "__main__":
    sys.exit(main())
