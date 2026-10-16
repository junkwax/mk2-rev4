#!/usr/bin/env python3
r"""src/RSMOKEL.ASM - MK3 ROBOT SMOKE's animation lanes for the Wolf build, GENERATED.

His art is packed by tools/make_robosmoke.py (data/RSMOKA/B.LOD -> src/RSMOKE.TBL);
this writes what draws it:

  * his MK3 lanes: the MKROBO.ASM blocks make_robosmoke.lanes() walks (his
    ani_ochar_jump branches taken, Sektor's / Cyrax's dropped), every label
    prefixed `rs_` so nothing collides with an MK2 name.
  * `rsmoke_anitab1`, MK2's TABLE1 layout (0..42h).  Rows MK3 has no lane
    for - thrown by each MK2 fighter (2Ah-35h), shredded (25h) and the
    fatality-victim rows (36h-41h) - are the MALE NINJAS' MK2 lanes (MKNJ)
    copied in (`rsn_`): his proxy is Reptile, so every throw and finisher MK2
    lines up against him is timed for the ninja body.  In those lanes the
    ninja's stumble / flipped / knockdown / stunned / sweep-up / hit frames
    are swapped for the robot's own of the same number (clamped to his last);
    the gore frames are still the ninja's art, drawn in Smoke's costume.
  * Lanes rebuilt in MK2's shape from his own frames: the jump (MK2's landing
    plays row 6 part 2, which MK3's one-part a_jump lacks), block, duck block,
    knockdown, flip kick (MK2 walks them one part further than MK3 - see
    make_umk3sindel_asm.py MK2_SHAPE), the THROW (normal_slam's three parts,
    the ninja throw's frame counts, out of MK3 Smoke's own throw - a_air_slam,
    as MK3's smoke_slam plays it - not Sektor's RBSHOLDER)
    and the DIZZY loop (MK3's robots spark while stunned with code MK2 lacks).
  * `rsmoke_anitab2`, laid out for the MK2 routines his specials reuse:
        0  spear throw: RBCHEST1,2 | RBCHEST2 (do_throw_spear part 1, do_rope_pull part 2)
        1  the rope: ninja Smoke's own a_sm_rope_ani (MKNJ exports it; COMEHERE1-3
           in data/SMROPE.LOD) - MK3's robot throws the same trident
        2  teleport uppercut (MK3 a_robo_telepunch)
        3  invisibility (MK3 a_inviso)
        4  air throw (MK3 a_air_slam in do_air_body_slam's shape: RBAIRSLAM3 | 5-9)
        5  the run (MK3 a_run, his alone - the Wolf board has a Run button)
  * `rsmoke_strikes`: the NINJA layout (nj_strikes), so MK2's spear_proc finds
    stk_njspear at 11h.  Normals 0-0Fh take MK3's stk_ro_* boxes with the
    ninja's MK2 reaction, damage, score and sound; 10h/11h are the ninja's own;
    12h is the teleport uppercut (MK3 stk_ro_tele box, the ninja uppercut's
    reaction, MK3's damage); 13h-15h are his combo hits (MK3 combo_strike_table's
    box and damage on the ninja's face-hit / elbow / roundhouse reactions).
  * his palettes: SMOKE1_P / SMOKE2_P (MK3 MKGUYS character_palettes_1/2,
    word-identical to ROBO13.IMG's SMOKE1_P), and the select screen's.

    python tools/make_robosmoke_asm.py            # report
    python tools/make_robosmoke_asm.py --apply    # write src/RSMOKEL.ASM
    python tools/make_robosmoke_asm.py --check    # Phase D: it is current
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_robosmoke as art            # noqa: E402
import make_umk3sonya_asm as sny        # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "RSMOKEL.ASM"
MKNJ = ROOT / "src" / "MKNJ.ASM"
P = "rs_"
NJP = "rsn_"
CALLA = {"sweep_sounds": "sweep_sounds",
         "rsnd_footstep": "rs_footstep"}      # MK3's run footstep - RSMOKEM.ASM

# MK2 TABLE1 -> his MK3 lane ("nj" = the ninjas' MK2 lane, "MK2" = rebuilt)
TABLE1 = [
    "a_stance", "a_walkf", "a_walkf", "a_walkb", "a_walkb",            # 0-4 (no skip: walk)
    "a_duck", "MK2", "a_fflip", "a_bflip", "a_turn",                   # 5-9 (6 MK2-shaped)
    "a_duck_turn", "MK2", "MK2", "a_hikick", "a_lokick",               # a-e (b/c MK2-shaped)
    "MK2", "a_hit_hi", "a_hit_lo", "a_getup", "a_hipunch",             # f-13 (f MK2-shaped)
    "a_lopunch", "a_sweep_kick", "a_sweep_fall", "a_sweepup",           # 14-17
    "a_duck_punch", "a_duck_kick_hi", "a_duck_kick_lo", "a_duck_hit",   # 18-1b
    "a_uppercut", "a_jump_kick", "MK2", "a_flip_punch",                 # 1c-1f (1e MK2-shaped)
    "a_roundhouse", "a_knee", "a_elbow", "a_stumble", "MK2",           # 20-24 (24 the throw)
    "nj", "a_chest_open", "SPEAR", "MK2", "a_victory",                  # 25-29 (28 the dizzy)
] + ["nj"] * (0x42 - 0x2A) + ["a_hipunch"]                              # 2a-41, 42
# Row 6: MK3's a_jump is ONE part, and MK2's do_land_animation plays row 6
# PART 2 (find_ani_part2) on every landing - jumps, flips, the teleport
# uppercut - so with no part 2 it walked on into the frame data behind the
# lane, ani2's guards dropped the runaway list (ani2_clip counts it) and he
# VANISHED for the whole landing.  MK3 lands on the jump frames themselves;
# the ninja's a_njjumpup lands on 2,1, so his landing is RBJUMP2,1.
MK2_SHAPE = {0x06: ("a_jump", "jump"), 0x0B: ("a_block", "block"), 0x0C: ("a_duck_block", "duckblock"),
             0x0F: ("a_knockdown", "kdown"), 0x1E: ("a_flip_kick", "flipkick")}
THROWN = range(0x2A, 0x36)
# the ninja's frame family -> his (copied victim lanes)
SUBST = {"NJSTUMBLE": "RBSTUMBLE", "NJFLIPPED": "RBFLIPPED", "NJKNOCKDOWN": "RBKNOCKDOWN",
         "NJSTUNNED": "RBSTUNNED", "NJSWEEPUP": "RBSWEEPUP", "NJHITHI": "RBHIHIT",
         "NJHITLO": "RBLOHIT", "NJSWEEPFALL": "RBSWEEPFALL", "NJKDOWN": "RBKNOCKDOWN",
         "NJGETUP": "RBGETUP", "NJFB": "RBFLIPPED"}

MK3_NORMALS = ["hikick", "lokick", "hi_punch", "lo_punch", "sweep", "duck_punch",
               "duck_kickh", "duck_kickl", "uppercut", "jump_punch", "jump_kick",
               "flip_kick", "flip_punch", "roundh", "knee", "elbow"]
NJ_ROWS = 0x12                      # the ninja's rows kept (0-11h: normals, bang, SPEAR)
# (row, MK3 record, MK2 record whose reaction / score / sound it takes)
SPECIALS = [(0x12, "stk_ro_tele", "stk_njuppercut"),      # teleport uppercut - launched
            # his COMBO hits (MK3 combo_strike_table: one tall box, 7 / 1 chip),
            # each on the ninja reaction that matches MK3's kind of hit
            (0x13, "stk_combo0", "stk_njhipunch"),      # stk_0: hit in the face
            (0x14, "stk_combo1", "stk_njelbow"),        # stk_1: stumble away
            (0x15, "stk_combo2", "stk_njroundh")]       # stk_2: knocked on his back


# --------------------------------------------------------------------------
def mk3_part():
    blocks, labels = art.lanes()
    mapping = {lab: P + lab for lab in labels}
    mapping.update(CALLA)
    out = []
    for lab, body in blocks:
        for ln in body:
            if re.match(r"^\s*\.end\b", ln, re.I):
                continue
            out.append(sny.hexfix(sny.rename_line(ln.rstrip(), mapping)))
    return out, labels


def lane_parts(lines, lane, n=3):
    """The first n parts of an emitted MK3 lane, as lists of frame labels."""
    i = next(k for k, ln in enumerate(lines) if re.match(re.escape(P + lane) + r"\b", ln))
    parts, cur = [], []
    first = lines[i][len(P + lane):]
    for ln in [first] + lines[i + 1:]:
        code = ln.split(";")[0]
        m = re.match(r"^\s*\.long\s+(.*)$", code)
        if not m:
            if re.match(r"^[A-Za-z_]", ln) and ln is not first:
                break
            continue
        toks = [t.strip() for t in m.group(1).split(",")]
        if toks == ["0"]:
            parts.append(cur)
            cur = []
            if len(parts) == n:
                break
            continue
        if toks[0].startswith("ani_"):
            raise SystemExit(f"{lane}: animator command in a lane rebuilt to MK2's shape")
        cur += toks
    if cur:
        parts.append(cur)
    return parts


def mk2_shaped(lines):
    out = []
    duck = lane_parts(lines, "a_duck", 1)[0][-1]
    for k, (lane, how) in MK2_SHAPE.items():
        p = lane_parts(lines, lane)
        if how in ("block", "jump"):
            parts = [p[0], p[0][-2::-1]]
        elif how == "duckblock":
            parts = [p[0], p[0][-2::-1] + [duck]]
        elif how == "kdown":
            parts = [p[0], p[1], p[1] + p[1]]
        else:
            parts = [p[0], p[1], p[1]]
        out.append(f"{P}mk2_{k:02x}\t\t; MK3 {lane} in MK2's shape")
        for part in parts:
            out += [f"\t.long\t{f}" for f in part] + ["\t.long\t0"]
        out.append("")
    # THE THROW (row 24): normal_slam's step 1 (grab) and step 2 (toss) walk
    # this lane in lockstep with the victim's FLIPPED-BY-NINJA lane and stop on
    # the VICTIM's terminator, so each part has the ninja throw's own frame
    # count (a_njbodyslam: 1 | 5); step 3 plays what follows to the next 0.
    # It is SMOKE's throw, not Sektor's: MK3's a_throw sends ft_smoke to
    # a_smoke_throw (the RBAIRSLAM2-3 lunge) and smoke_slam (MK3 MKSLAM)
    # slams on a_air_slam - the art his air throw (rs_t2_air) already uses.
    # Sektor's RBSHOLDER throw draws its grabbing arm as a SECOND object
    # (RBMECARM, ani_sladd), which nothing here makes: he threw with no arm.
    sl = [f"{P}RBAIRSLAM{n}" for n in range(1, 10)]
    out += [f"{P}mk2_24\t\t; Smoke's throw (MK3 smoke_slam: a_air_slam) in normal_slam's shape",
            f"\t.long\t{sl[2]}", "\t.long\t0",
            "\t.long\t" + ",".join(sl[4:9]), "\t.long\t0",
            f"\t.long\t{sl[8]}", "\t.long\t0", ""]
    # THE DIZZY (row 28): MK3's a_dizzy minus the sparks, a plain loop
    st = [f"{P}RBSTUNNED{n}" for n in range(1, 9)]
    out += [f"{P}mk2_28\t\t; MK3 a_dizzy's RBSTUNNED frames, without the robot sparks"]
    out += [f"\t.long\t{f}" for f in st] + [f"\t.long\tani_jump,{P}mk2_28", ""]
    return out


def table2():
    return [
        "rsmoke_anitab2",
        f"\t.long\t{P}t2_spear\t; 0 - spear throw (do_throw_spear / do_rope_pull)",
        f"\t.long\ta_sm_rope_ani\t; 1 - the rope: ninja Smoke's COMEHERE trident (MKNJ)",
        f"\t.long\t{P}a_robo_telepunch\t; 2 - teleport uppercut",
        f"\t.long\t{P}a_inviso\t; 3 - invisibility",
        f"\t.long\t{P}t2_air\t; 4 - air throw (MK3 a_air_slam, normal_slam's shape)",
        f"\t.long\t{P}a_run\t; 5 - the run (MK3 a_run; RSMOKEM.ASM rs_run)",
        "",
        f"{P}t2_spear\t\t; MK3 a_chest_open; part 2 is the pull pose",
        f"\t.long\t{P}RBCHEST1", f"\t.long\t{P}RBCHEST2", "\t.long\t0",
        f"\t.long\t{P}RBCHEST2", "\t.long\t0",
        "",
        # do_air_body_slam's steps walk this in lockstep with the victim's
        # "flipped by ninja" lane (1 | 5 frames in every module) and stop on
        # HIS terminator: MK3's lunge ends on RBAIRSLAM3 (the catch), the slam
        # is RBAIRSLAM4-9 (MK3's part 1) - its last five reach the floor
        f"{P}t2_air\t\t; MK3 a_air_slam: the catch | the slam",
        f"\t.long\t{P}RBAIRSLAM3", "\t.long\t0",
        "\t.long\t" + ",".join(f"{P}RBAIRSLAM{n}" for n in range(5, 10)), "\t.long\t0",
        ""]


def mainequ_globals():
    gl = set()
    for line in re.findall(r"\.global\s+([\w, \t]+)", (ROOT / "src" / "MAINEQU.ASM").read_text(encoding="latin-1")):
        gl |= {g.strip() for g in line.split(",")}
    return gl


# --------------------------------------------------------------------------
# the male ninjas' victim lanes (MKNJ.ASM)
# --------------------------------------------------------------------------
def strip_ochar(body):
    """MKNJ's ani_ochar_jump triples branch to Scorpion / Rain / Smoke...; ochar
    24 matches none of them, so each falls through - drop it."""
    out, k = [], 0
    while k < len(body):
        code = body[k].split(";")[0]
        if re.search(r"\bani_ochar_jump\b", code):
            rest = re.findall(r"\w+", code.split("ani_ochar_jump", 1)[1])
            j = k + 1
            while len(rest) < 2:
                rest += re.findall(r"\w+", body[j].split(";")[0].replace(".long", ""))
                j += 1
            k = j
            continue
        out.append(body[k])
        k += 1
    return out


def nj_part(rows):
    lines = MKNJ.read_text(encoding="latin-1").splitlines()
    bl = [(lab, strip_ochar(body)) for lab, body in sny.blocks(lines)]
    index = {lab: i for i, (lab, _b) in enumerate(bl) if lab}
    row_labels = [t for ln in bl[index["sm_anitab1"]][1] for t in sny.tokens(ln)][:0x43]
    want = {k: row_labels[k] for k in rows}
    keep, todo, seen, callas = [], list(want.values()), set(), set()
    while todo:
        lab = todo.pop()
        if lab in seen or lab not in index:
            continue
        seen.add(lab)
        j = index[lab]
        chain = [j]
        while True:
            body = bl[chain[-1]][1]
            last = [ln for ln in body if sny.tokens(ln) or re.search(r"\.long\s+0\b", ln)]
            nxt = chain[-1] + 1
            if nxt >= len(bl):
                break
            nlab = bl[nxt][0]
            if (last and "ani_jump" in last[-1]) or re.match(r"^(a_|[A-Z])", nlab or "A"):
                break
            if any(art.is_code(ln) for ln in bl[nxt][1]):
                break
            chain.append(nxt)
        for c in chain:
            seen.add(bl[c][0])
            keep.append(c)
            for ln in bl[c][1]:
                toks = sny.tokens(ln)
                for i, t in enumerate(toks):
                    if i and toks[i - 1] == "ani_calla":
                        callas.add(t)
                        continue
                    if t in index and t not in seen:
                        todo.append(t)
    keep = sorted(set(keep))
    labs = {bl[k][0] for k in keep}
    for k in keep:
        for ln in bl[k][1]:
            if art.is_code(ln):
                raise SystemExit(f"the ninja's {bl[k][0]} carries code: {ln.strip()}")
    mapping = {lab: NJP + lab for lab in labs}
    body = [sny.rename_line(ln.rstrip(), mapping) for k in keep for ln in bl[k][1]
            if not re.match(r"^\s*\.(end|text|data|bss|include|file|width|option|mnolist)\b", ln, re.I)]
    return body, want, mapping, callas


def substitute(lines, mk3_labels):
    """The ninja's body frames -> the robot's of the same family and number."""
    fams = {}
    for lab in mk3_labels:
        m = re.match(r"^([A-Z]+?)(\d+)$", lab)
        if m:
            fams.setdefault(m.group(1), set()).add(int(m.group(2)))
    subs, missed = 0, set()

    def r(m):
        nonlocal subs
        fam, n = m.group(1), int(m.group(2))
        to = SUBST.get(fam)
        if not to:
            missed.add(fam)
            return m.group(0)
        if to not in fams:
            raise SystemExit(f"{fam} -> {to}: he has no {to} frames")
        have = sorted(fams[to])
        n = n if n in fams[to] else max((x for x in have if x <= n), default=have[0])
        subs += 1
        return f"{P}{to}{n}"
    out = []
    for ln in lines:
        code, sep, com = ln.partition(";")
        lead = ""
        m = re.match(r"^[A-Za-z_]\w*", code)
        if m:
            lead, code = m.group(0), code[m.end():]
        code = re.sub(r"\b" + NJP + r"([A-Z]+?)(\d+)\b", r, code)
        out.append(lead + code + sep + com)
    return out, subs, missed


def copy_headers(lines):
    """Headers of the ninja records the copied lanes still draw that are local
    to MKNJ: every line up to the next label (a PON record carries its palette)."""
    have = set(re.findall(r"^(\w+):", (ROOT / "src" / "RSMOKE.TBL").read_text(encoding="latin-1"), re.M))
    defined = {re.match(r"^([A-Za-z_]\w*)", ln).group(1) for ln in lines if re.match(r"^[A-Za-z_]\w*", ln)}
    want = set()
    for ln in lines:
        if ln.startswith("*"):
            continue
        code = ln.split(";")[0]
        m = re.match(r"^[A-Za-z_]\w*", code)
        for t in re.findall(r"\b[A-Z][A-Z0-9_]*\d[A-Z]?\b", code[m.end():] if m else code):
            if t not in have and t not in defined:
                want.add(t)
    found = {}
    for p in sorted((ROOT / "src").glob("*.TBL")):
        if p.name.upper() == "RSMOKE.TBL":
            continue
        tl = p.read_text(encoding="latin-1").splitlines()
        for i, ln in enumerate(tl):
            m = re.match(r"^(\w+):\s*$", ln)
            if m and m.group(1) in want and m.group(1) not in found:
                rec = [f"{m.group(1)}:"]
                for nx in tl[i + 1:]:
                    if not re.match(r"^\s+\.(word|long)\b", nx):
                        break
                    rec.append(nx.rstrip())
                found[m.group(1)] = rec
    gl = set()
    for line in re.findall(r"\.global\s+([\w, \t]+)", (ROOT / "src" / "MAINEQU.ASM").read_text(encoding="latin-1")):
        gl |= {g.strip() for g in line.split(",")}
    missing = sorted(w for w in want if w not in found and w not in gl)
    if missing:
        raise SystemExit(f"copied ninja lanes name records found in no TBL: {missing[:8]}")
    return [ln for k in sorted(found) for ln in found[k]], len(found)


# --------------------------------------------------------------------------
def nj_strike_rows():
    src = (ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1").splitlines()
    i = next(k for k, ln in enumerate(src) if re.match(r"^nj_strikes\b", ln))
    rows = []
    for ln in src[i + 1:]:
        if re.match(r"^\s*\.(if|else|endif)\b", ln) or not ln.strip() or ln.lstrip().startswith((";", "*")):
            continue
        m = re.match(r"^\s*\.long\s+(\w+)", ln)
        if not m:
            break
        rows.append(m.group(1))
    if rows[0x11] != "stk_njspear":
        raise SystemExit(f"nj_strikes 11h is {rows[0x11]}, not stk_njspear - spear_proc's row moved")
    return rows[:NJ_ROWS]


def strike_table():
    mk2 = sny.stk_records((ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1"))
    mk3 = sny.stk_records((art.MK3SRC / "MKSTK.ASM").read_text(errors="replace"))
    nj = nj_strike_rows()

    # MK3 names some damage words with its own equates (combo_damage >0701):
    # MK2 has none of them, so the value goes in
    mk3_sets = dict(re.findall(r"^(\w+)\s+\.set\s+(>?[0-9A-Fa-f]+)",
                               (art.MK3SRC / "MKSTK.ASM").read_text(errors="replace"), re.M))

    def resolve(line):
        return re.sub(r"\b(\w+)\b", lambda m: mk3_sets.get(m.group(1), m.group(1)), line.split(";")[0]) \
            + (";" + line.split(";", 1)[1] if ";" in line else "")

    def rec(geo_from, rest_from, keep_damage=True):
        g = [sny.hexfix(x) for x in mk3[geo_from][:4]]
        r = mk2[rest_from]
        return g + [r[4], (r[5] if keep_damage else sny.hexfix(resolve(mk3[geo_from][5])))] + r[6:]

    out = ["", "; --- his strike table: the ninjas' layout, MK3's boxes " + "-" * 15,
           "\t.globl\trsmoke_strikes", "rsmoke_strikes"]
    recs = []
    for k, lab in enumerate(nj):
        if k < len(MK3_NORMALS):
            body = rec("stk_ro_" + MK3_NORMALS[k], lab)
            note = f"MK3 stk_ro_{MK3_NORMALS[k]} box, the ninja's {lab} rest"
        else:
            body = mk2[lab]
            note = f"the ninja's {lab}"
        out.append(f"\t.long\t{P}stk_{k:02x}\t; {k:02x} - {note}")
        recs.append((f"{P}stk_{k:02x}", body))
    for k, m3, m2 in SPECIALS:
        if k != len(recs):
            raise SystemExit(f"his special stk {k:02x} is not the next row ({len(recs):02x})")
        out.append(f"\t.long\t{P}stk_{k:02x}\t; {k:02x} - MK3 {m3}, {m2}'s reaction")
        recs.append((f"{P}stk_{k:02x}", rec(m3, m2, keep_damage=False)))
    for lab, body in recs:
        out += ["", lab] + body
    return out


def mk3_palette(name):
    txt = (art.MK3SRC / "MKGUYS.ASM").read_text(errors="replace").splitlines()
    i = next(k for k, ln in enumerate(txt) if ln.strip() == f"{name}:")
    words = []
    for ln in txt[i + 1:]:
        m = re.match(r"^\s*\.word\s+(.*)$", ln.split(";")[0])
        if not m:
            break
        words += [int(v.rstrip("hH"), 16) if v.lower().endswith("h") else int(v)
                  for v in re.split(r"[,\s]+", m.group(1).strip()) if v]
    return words[1:1 + words[0]]


def palettes():
    out = {"SMOKE1_P": mk3_palette("SMOKE1_P"), "SMOKE2_P": mk3_palette("SMOKE2_P")}
    _imgs, sel = art.select_art()
    box = sel["RSBOX_P"][1]
    out["RSBOX_P"] = box
    out["RSBOXD_P"] = [(max(((w >> 10) & 31) - 12, 0) << 10) | (max(((w >> 5) & 31) - 11, 0) << 5) | (w & 31)
                       for w in box]
    out["RSMUG_P"] = sel["RSMUG_P"][1]
    return out


def build():
    mk3, mk3_labels = mk3_part()
    nj_rows = [k for k, v in enumerate(TABLE1) if v == "nj"]
    njl, want, mapping, callas = nj_part(nj_rows)
    njl, subs, missed = substitute(njl, mk3_labels)
    njl = sny.prune_unused(njl, NJP)
    copied, ncopied = copy_headers(njl)
    pals = palettes()
    # a copied PON record carries its palette, which MKNJ resolves through
    # IMGTBL.GLO; .ref exactly those instead of including the whole list
    pal_refs = sorted({m.group(1) for ln in copied
                       for m in [re.match(r"^\s*\.long\s+([A-Za-z_]\w*)\s*$", ln.split(";")[0])] if m}
                      - set(pals) - mainequ_globals())

    tblhash = hashlib.sha1((ROOT / "data" / "RSSEL.IMG").read_bytes()
                           + (ROOT / "src" / "RSMOKE.TBL").read_bytes()
                           + (ROOT / "src" / "MKNJ.TBL").read_bytes()).hexdigest()[:12]
    out = [";" + "*" * 70,
           f";  tables {tblhash} - RSMOKE.TBL + MKNJ.TBL, so a repack changes THIS",
           ";  file and gmake reassembles it (it only watches the .ASM)",
           ";  MK3 ROBOT SMOKE (Wolf only) - his animation lanes.  GENERATED by",
           ";  tools/make_robosmoke_asm.py out of MK3's MKROBO.ASM and MK2's",
           ";  MKNJ.ASM; edit the tool, never this file.",
           ";" + "*" * 70,
           '\t.file\t"rsmokel.asm"',
           "\t.width\t132",
           "\t.option\tb,d,l,t",
           "\t.mnolist",
           "\t.include\tdispequ.asm",
           "\t.include\tsysequ.asm",
           "\t.include\tmacros.hdr",
           "\t.include\tmainequ.asm",
           "\t.if\twunit",
           "\t.include\trsmoke.tbl",
           "\t.globl\trsmoke_anitab1,rsmoke_anitab2",
           "\t.globl\t" + ",".join(sorted(pals)),
           "\t.globl\t" + ",".join(f"RSBOX{n}" for n in range(2, 10)) + ",smrsbox",
           "\t.ref\t" + ",".join(["a_sm_rope_ani"] + sorted((set(CALLA.values()) | callas)
                                                              - mainequ_globals())),
           ] + ([f"\t.ref\t{','.join(pal_refs)}\t; the copied ninja headers' palettes"] if pal_refs else []) + [
           "\t.text", ""]
    out.append("rsmoke_anitab1")
    for k, v in enumerate(TABLE1):
        if v == "nj":
            src = want[k]
            out.append(f"\t.long\t{mapping[src]}\t; {k:02x} - the ninjas' {src}")
        elif v == "MK2":
            note = MK2_SHAPE[k][0] if k in MK2_SHAPE else ("the throw" if k == 0x24 else "the dizzy")
            out.append(f"\t.long\t{P}mk2_{k:02x}\t; {k:02x} - {note}, MK2's parts")
        elif v == "SPEAR":
            out.append(f"\t.long\ta_sm_rope_ani\t; {k:02x} - the rope (projectile row)")
        else:
            out.append(f"\t.long\t{P}{v}\t; {k:02x}")
    out.append("")
    out += table2()
    out += ["; --- lanes in MK2's shape " + "-" * 45]
    out += mk2_shaped(mk3)
    out += ["; --- his MK3 lanes (MKROBO.ASM, his branches) " + "-" * 24] + mk3
    out += ["", "; --- the male ninjas' MK2 thrown / victim lanes, his frames " + "-" * 9] + njl
    out += ["", "; --- headers of the ninja records those lanes still draw (local to",
            ";     MKNJ, so copied)", "\t.data"] + copied + ["\t.text"]
    out += strike_table()
    out.append("")
    out.append("; --- his palettes (MK3 MKGUYS; the select screen's out of data/RSSEL.IMG) " + "-" * 2)
    for nm in sorted(pals):
        words = pals[nm]
        out.append(f"{nm}:")
        out.append(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            out.append("\t.word\t" + ",".join(f"0{w:04x}h" for w in words[i:i + 8]))
    out += ["", "\t.endif", "\t.end", ""]
    return "\n".join(out), subs, missed, len(njl), ncopied, callas


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text, subs, missed, nn, nc, callas = build()
    print(f"RSMOKEL.ASM: {text.count(chr(10))} lines; ninja lanes {nn} lines ({subs} frames made "
          f"his, {nc} ninja headers copied); ninja families kept: {sorted(missed)}; "
          f"routines the ninja lanes call: {sorted(callas)}")
    if a.apply:
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != text:
            OUT.write_text(text, encoding="latin-1", newline="\r\n")
            print(f"wrote {OUT.relative_to(ROOT)}")
    if a.check:
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != text:
            raise SystemExit(f"{OUT.relative_to(ROOT)} is stale - rerun tools/make_robosmoke_asm.py --apply")
        print("RSMOKEL.ASM is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
