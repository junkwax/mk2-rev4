#!/usr/bin/env python3
r"""src/NWOLFL.ASM - MK3 NIGHTWOLF's animation lanes for the Wolf build, GENERATED.

His art is packed by tools/make_nightwolf.py (data/NWOLFA-C.LOD -> src/NWOLF.TBL);
this writes what draws it:

  * his MK3 lanes, straight out of MK3's own MKIND.ASM (MK3SRC/V13), every
    label prefixed `nw_` so nothing can collide with an MK2 name.  The run
    (a_run, INRUN*, ININTORUN*) is left out: there is no run here.  MK3's two
    `ani_ochar_sound` + `.word` pairs (the axe fatality's thunder) become an
    `ani_calla` - MK2's port of that command reads a packed LONG.
  * `nightwolf_anitab1`, MK2's TABLE1 layout (0..42h), each row naming the MK3
    lane that plays that action.  Rows MK3 has no lane for - being thrown by
    each MK2 fighter (2Ah-35h) and the fatality-victim rows - are LIU KANG's
    MK2 lanes copied in (`nwk_` / `nwt_`): he is the male body MK2 already
    times every throw and fatality against.  In every copied lane Liu Kang's
    stumble / flipped / knockdown / stunned / sweep-up frames are replaced by
    Nightwolf's own of the same number (clamped to his last), so it is
    Nightwolf who is thrown; the gore frames are still Liu Kang's art.
  * The four lanes MK2 walks one part FURTHER than MK3 lays them out (block,
    duck block, knockdown, flip kick - see make_umk3sindel_asm.py MK2_SHAPE)
    are rebuilt in MK2's shape from his own frames.
  * `nightwolf_anitab2`, MK3's rows as they are (his specials index it).
  * `nightwolf_strikes`: Liu Kang's index layout; normals 0-0Fh take MK3's
    boxes with Liu Kang's MK2 reaction, damage, score and sound; his specials
    follow at 17h (see SPECIALS).
  * his palettes: INBLU_P / INYEL_P (MK3's MKGUYS costumes) and every effect
    palette his records name, words out of data/NWOLFA-C.IMG.

    python tools/make_nightwolf_asm.py            # report
    python tools/make_nightwolf_asm.py --apply    # write src/NWOLFL.ASM
    python tools/make_nightwolf_asm.py --check    # Phase D: it is current
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_nightwolf as art            # noqa: E402
import make_umk3sonya_asm as sny        # noqa: E402  (blocks/tokens/hexfix/... helpers)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "NWOLFL.ASM"
MKIND = art.MK3SRC / "MKIND.ASM"
MKLK = ROOT / "src" / "MKLK.ASM"
P = "nw_"

DROP_LABELS = {"a_run", "j_run"} | {f"INRUN{n}" for n in range(1, 14)} | \
              {f"ININTORUN{n}" for n in range(1, 4)}
CALLA = {"sweep_sounds": "sweep_sounds", "delete_slave": "delete_slave"}

# MK2 TABLE1 -> his MK3 lane, or "lk" for Liu Kang's
TABLE1 = [
    "a_stance", "a_walkf", "a_walkf", "a_walkb", "a_walkb",            # 0-4 (no skip: walk)
    "a_duck", "a_jump", "a_fflip", "a_bflip", "a_turn",                # 5-9
    "a_duck_turn", "MK2", "MK2", "a_hikick", "a_lokick",               # a-e (b/c MK2-shaped)
    "MK2", "a_hit_hi", "a_hit_lo", "a_getup", "a_hipunch",             # f-13 (f MK2-shaped)
    "a_lopunch", "a_sweep_kick", "a_sweep_fall", "a_sweepup",           # 14-17
    "a_duck_punch", "a_duck_kick_hi", "a_duck_kick_lo", "a_duck_hit",   # 18-1b
    "a_uppercut", "a_jump_kick", "MK2", "a_flip_punch",                 # 1c-1f (1e MK2-shaped)
    "a_roundhouse", "a_knee", "a_elbow", "a_stumble", "a_throw",        # 20-24
    "lk", "a_zap", "a_projectile", "a_dizzy", "a_victory",              # 25-29 (26 throw, 27 flight)
] + ["lk"] * (0x42 - 0x2A) + ["a_hipunch"]                              # 2a-41, 42 (LK's backfist row)
MK2_SHAPE = {0x0B: ("a_block", "block"), 0x0C: ("a_duck_block", "duckblock"),
             0x0F: ("a_knockdown", "kdown"), 0x1E: ("a_flip_kick", "flipkick")}
THROWN = range(0x2A, 0x36)
# Liu Kang frame family -> his
SUBST = {"STUMBLE": "INSTUMBLE", "FLIPPED": "INFLIPPED", "KNOCKDOWN": "INKNOCKDOWN",
         "STUNNED": "INSTUNNED", "SWEEPUP": "INSWEEPUP", "FB": "INFLIPPED",
         "FLIP": "INFLIPPED", "HITHI": "INHIHIT", "HITLO": "INLOHIT", "SWEEPFALL": "INSWEEPFALL"}

MK3_NORMALS = ["hikick", "lokick", "hi_punch", "lo_punch", "sweep", "duck_punch",
               "duck_kickh", "duck_kickl", "uppercut", "jump_punch", "jump_kick",
               "flip_kick", "flip_punch", "roundh", "knee", "elbow"]
LK_ROWS = 0x17                       # Liu Kang's rows kept (0-16h); his specials follow
# (row, MK3 record, MK2 record whose reaction / score / sound it takes)
SPECIALS = [(0x17, "stk_ind_zap", "stk_lkzap1"),        # the arrow - a fireball's hit
            (0x18, "stk_ind_charge", "stk_lkroundh"),   # the shoulder charge - knocked away
            (0x19, "stk_axe_up", "stk_lkuppercut"),     # the hatchet uppercut - launched
            (0x1A, "stk_axe_horz", "stk_lkhikick")]     # the horizontal axe (MK3's spare)
TABLE2_ROWS = 8                       # MK3's ind_anitab2 (a_dummy is not a row)


# --------------------------------------------------------------------------
def mk3_part():
    lines = MKIND.read_text(errors="replace").splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip().lower() == ".text") + 1
    bl = sny.blocks(lines[start:])
    labels = {lab for lab, _b in bl if lab}
    tables = {"ind_anitab1", "ind_anitab2"}
    mapping = {lab: P + lab for lab in labels}
    mapping.update(CALLA)
    out, i = [], 0
    for lab, body in bl:
        if lab in DROP_LABELS or lab in tables:
            continue
        k = 0
        while k < len(body):
            ln = body[k]
            if re.match(r"^\s*\.end\b", ln, re.I):
                k += 1
                continue
            if re.match(r"^\s*\.long\s+ani_ochar_sound\b", ln):
                # MK3: ani_ochar_sound / .word >0d (the axe fatality's thunder)
                if not re.match(r"^\s*\.word\s", body[k + 1]):
                    raise SystemExit(f"{lab}: ani_ochar_sound not followed by .word")
                out.append(f"\t.long\tani_calla,nw_thunder\t; MK3 ani_ochar_sound {body[k + 1].split()[-1]}")
                k += 2
                continue
            out.append(sny.hexfix(sny.rename_line(ln.rstrip(), mapping)))
            k += 1
    tabs = {}
    for lab, body in bl:
        if lab in tables:
            tabs[lab] = [t for ln in body for t in sny.tokens(ln)]
    return out, labels, tabs


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
        parts += []
        cur += toks
    return parts


def mk2_shaped(lines):
    out = []
    duck = lane_parts(lines, "a_duck", 1)[0][-1]
    for k, (lane, how) in MK2_SHAPE.items():
        p = lane_parts(lines, lane)
        if how == "block":
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
    return out


def is_code(ln):
    code = ln.split(";")[0]
    if ln[:1] not in (" ", "\t"):
        code = re.sub(r"^[A-Za-z_]\w*", "", code)
    return bool(re.match(r"^\s+[a-z]{2,8}\b", code)) and not re.match(r"^\s+\.", code)


def lk_part(rows, prefix):
    """Liu Kang's lanes for the given lk_anitab1 rows, with every label they
    reach (prefixed)."""
    lines = MKLK.read_text(encoding="latin-1").splitlines()
    bl = sny.blocks(lines)
    index = {lab: i for i, (lab, _b) in enumerate(bl) if lab}
    row_labels = [t for ln in bl[index["lk_anitab1"]][1] for t in sny.tokens(ln)][:0x43]
    want = {k: row_labels[k] for k in rows}
    keep, todo, seen = [], list(want.values()), set()
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
            if any(is_code(ln) for ln in bl[nxt][1]):      # a routine, not a part
                break
            chain.append(nxt)
        for k in chain:
            seen.add(bl[k][0])
            keep.append(k)
            for ln in bl[k][1]:
                for t in sny.tokens(ln):
                    if t in index and t not in seen:
                        todo.append(t)
    keep = sorted(set(keep))
    labs = {bl[k][0] for k in keep}
    for k in keep:                     # a copied lane must be DATA only
        for ln in bl[k][1]:
            if is_code(ln):
                raise SystemExit(f"Liu Kang's {bl[k][0]} carries code: {ln.strip()}")
    mapping = {lab: prefix + lab for lab in labs}
    return [sny.rename_line(ln.rstrip(), mapping) for k in keep for ln in bl[k][1]
            if not re.match(r"^\s*\.(end|text|data|bss)\b", ln, re.I)], want, mapping


def substitute(lines, prefix, mk3_labels):
    """Liu Kang's body frames -> Nightwolf's of the same family and number."""
    fams = {}
    for lab in mk3_labels:
        m = re.match(r"^([A-Z]+?)(\d+)$", lab)
        if m:
            fams.setdefault(m.group(1), set()).add(int(m.group(2)))
    subs = 0

    def r(m):
        nonlocal subs
        fam, n = m.group(1), int(m.group(2))
        to = SUBST.get(fam)
        if not to or to not in fams:
            return m.group(0)
        have = sorted(fams[to])
        n = n if n in fams[to] else max(x for x in have if x <= n) if any(x <= n for x in have) else have[0]
        subs += 1
        return f"{P}{to}{n}"
    out = []
    for ln in lines:
        code, sep, com = ln.partition(";")
        lead = ""
        m = re.match(r"^[A-Za-z_]\w*", code)
        if m:
            lead, code = m.group(0), code[m.end():]
        code = re.sub(r"\b" + prefix + r"LK([A-Z]+?)(\d+)\b", r, code)
        out.append(lead + code + sep + com)
    return out, subs


def copy_headers(lines):
    """Headers of the Liu Kang records the copied lanes still draw that are
    local to MKLK (no palette .long: drawn in Nightwolf's costume)."""
    have = set(re.findall(r"^(\w+):", (ROOT / "src" / "NWOLF.TBL").read_text(encoding="latin-1"), re.M))
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
        if p.name.upper() == "NWOLF.TBL":
            continue
        tl = p.read_text(encoding="latin-1").splitlines()
        for i, ln in enumerate(tl):
            m = re.match(r"^(\w+):\s*$", ln)
            if m and m.group(1) in want and m.group(1) not in found:
                found[m.group(1)] = [f"{m.group(1)}:"] + tl[i + 1:i + 4]
    gl = set()
    for line in re.findall(r"\.global\s+([\w, \t]+)", (ROOT / "src" / "MAINEQU.ASM").read_text(encoding="latin-1")):
        gl |= {g.strip() for g in line.split(",")}
    missing = sorted(w for w in want if w not in found and w not in gl)
    if missing:
        raise SystemExit(f"copied Liu Kang lanes name records found in no TBL: {missing[:8]}")
    return [ln for k in sorted(found) for ln in found[k]], len(found)


def lk_strike_rows():
    src = (ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1").splitlines()
    i = next(k for k, ln in enumerate(src) if re.match(r"^lk_strikes\b", ln))
    rows = []
    for ln in src[i + 1:]:
        if re.match(r"^\s*\.(if|else|endif)\b", ln) or not ln.strip() or ln.lstrip().startswith((";", "*")):
            continue
        m = re.match(r"^\s*\.long\s+(\w+)", ln)
        if not m:
            break
        rows.append(m.group(1))
    return rows[:LK_ROWS]


def strike_table():
    mk2 = sny.stk_records((ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1"))
    mk3 = sny.stk_records((art.MK3SRC / "MKSTK.ASM").read_text(errors="replace"))
    lk = lk_strike_rows()

    def rec(geo_from, rest_from, keep_damage=True):
        g = [sny.hexfix(x) for x in mk3[geo_from][:4]]
        r = mk2[rest_from]
        return g + [r[4], (r[5] if keep_damage else sny.hexfix(mk3[geo_from][5]))] + r[6:]

    out = ["", "; --- his strike table: Liu Kang's layout, MK3's boxes " + "-" * 16,
           "\t.globl\tnightwolf_strikes", "nightwolf_strikes"]
    recs = []
    for k, lab in enumerate(lk):
        if k < len(MK3_NORMALS):
            body = rec("stk_ind_" + MK3_NORMALS[k], lab)
            note = f"MK3 stk_ind_{MK3_NORMALS[k]} box, Liu Kang's {lab} rest"
        else:
            body = mk2[lab]
            note = f"Liu Kang's {lab} (not his)"
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


def palettes():
    """name -> words for every palette his packed records name, plus INYEL_P."""
    recs, pals, _d = art.resolve()
    out = dict(pals)
    # his alternate costume: MK3's MKGUYS character_palettes_2 (code-only there)
    txt = (art.MK3SRC / "MKGUYS.ASM").read_text(errors="replace").splitlines()
    i = next(k for k, ln in enumerate(txt) if ln.strip() == "INYEL_P:")
    words = []
    for ln in txt[i + 1:]:
        m = re.match(r"^\s*\.word\s+(.*)$", ln.split(";")[0])
        if not m:
            break
        words += [int(v.rstrip("hH"), 16) if v.lower().endswith("h") else int(v)
                  for v in re.split(r"[,\s]+", m.group(1).strip()) if v]
    out["INYEL_P"] = words[1:1 + words[0]]
    # the select screen (data/NWSEL.IMG): the box wipe's palette, its dimmed
    # "picked" twin by every BOXnD_P's rule (R-12, G-11, B kept, clamped at 0 -
    # tools/make_snbox_pals.py), and the ladder mug's
    _imgs, sel = art.select_art()
    box = sel["NWBOX_P"][1]
    out["NWBOX_P"] = box
    out["NWBOXD_P"] = [(max(((w >> 10) & 31) - 12, 0) << 10) | (max(((w >> 5) & 31) - 11, 0) << 5) | (w & 31)
                       for w in box]
    out["NWMUG_P"] = sel["NWMUG_P"][1]
    return out


def build():
    mk3, mk3_labels, tabs = mk3_part()
    lk_rows = [k for k, v in enumerate(TABLE1) if v == "lk"]
    thrown = [k for k in lk_rows if k in THROWN]
    other = [k for k in lk_rows if k not in THROWN]
    lk_t, want_t, map_t = lk_part(thrown, "nwt_")
    lk_o, want_o, map_o = lk_part(other, "nwk_")
    lk_t, s1 = substitute(lk_t, "nwt_", mk3_labels)
    lk_o, s2 = substitute(lk_o, "nwk_", mk3_labels)
    lk_t = sny.prune_unused(lk_t, "nwt_")
    lk_o = sny.prune_unused(lk_o, "nwk_")
    copied, ncopied = copy_headers(lk_t + lk_o)
    pals = palettes()

    tblhash = hashlib.sha1((ROOT / "data" / "NWSEL.IMG").read_bytes()
                           + (ROOT / "src" / "NWOLF.TBL").read_bytes()
                           + (ROOT / "src" / "MKLK.TBL").read_bytes()).hexdigest()[:12]
    out = [";" + "*" * 70,
           f";  tables {tblhash} - NWOLF.TBL + MKLK.TBL, so a repack changes THIS",
           ";  file and gmake reassembles it (it only watches the .ASM)",
           ";  MK3 NIGHTWOLF (Wolf only) - his animation lanes.  GENERATED by",
           ";  tools/make_nightwolf_asm.py out of MK3's MKIND.ASM and MK2's",
           ";  MKLK.ASM; edit the tool, never this file.",
           ";" + "*" * 70,
           '\t.file\t"nwolfl.asm"',
           "\t.width\t132",
           "\t.option\tb,d,l,t",
           "\t.mnolist",
           "\t.include\tdispequ.asm",
           "\t.include\tsysequ.asm",
           "\t.include\tmacros.hdr",
           "\t.include\tmainequ.asm",
           "\t.if\twunit",
           "\t.include\tnwolf.tbl",
           "\t.globl\tnightwolf_anitab1,nightwolf_anitab2,nightwolf_stance1",
           "\t.globl\t" + ",".join(sorted(pals)),
           "\t.globl\t" + ",".join(f"NWBOX{n}" for n in range(2, 10)) + ",smnwbox,BAR_NIGHTWOLF",
           "\t.ref\tsweep_sounds,delete_slave,triple_sound",
           "\t.text", ""]
    out.append("nightwolf_anitab1")
    for k, v in enumerate(TABLE1):
        if v == "lk":
            src = want_t.get(k) or want_o.get(k)
            lab = (map_t if k in THROWN else map_o)[src]
            out.append(f"\t.long\t{lab}\t; {k:02x} - Liu Kang's {src}")
        elif v == "MK2":
            out.append(f"\t.long\t{P}mk2_{k:02x}\t; {k:02x} - MK3 {MK2_SHAPE[k][0]}, MK2's parts")
        else:
            out.append(f"\t.long\t{P}{v}\t; {k:02x}")
    out += ["", "nightwolf_stance1\t\t; his first stance frame",
            f"\t.long\tINSTANCE1A,INSTANCE1B,0", "", "nightwolf_anitab2"]
    t2 = tabs["ind_anitab2"][:TABLE2_ROWS]
    for k, v in enumerate(t2):
        out.append(f"\t.long\t{P}{v}\t; {k}")
    out += ["", "; --- lanes MK2 walks one part further than MK3 laid them out " + "-" * 8]
    out += mk2_shaped(mk3)
    out += ["; --- his MK3 lanes " + "-" * 51] + mk3
    out += ["", "; --- Liu Kang's MK2 THROWN lanes, Nightwolf's frames " + "-" * 16] + lk_t
    out += ["", "; --- Liu Kang's MK2 fatality-victim lanes (his frames where he has them) " + "-" * 2] + lk_o
    out += ["", "; --- headers of the Liu Kang records those lanes still draw (local to",
            ";     MKLK, so copied; no palette .long - drawn in Nightwolf's costume)",
            "\t.data"] + copied + ["\t.text"]
    out += strike_table()
    out += ["", "; --- the routines his lanes call " + "-" * 37,
            "nw_thunder",
            "\tmovi\t0a4h,a0\t\t\t; MK3 ochar_sound 0dh (the axe fatality's thunder):",
            "\tjauc\ttriple_sound\t\t;   MK2's own BOOM until his own sounds are in",
            ""]
    out.append("; --- his palettes (deadlythirdcombat INDIAN*.IMG; INYEL_P MK3 MKGUYS) " + "-" * 2)
    for nm in sorted(pals):
        words = pals[nm]
        out.append(f"{nm}:")
        out.append(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            out.append("\t.word\t" + ",".join(f"0{w:04x}h" for w in words[i:i + 8]))
    out += ["", "\t.endif", "\t.end", ""]
    return "\n".join(out), s1 + s2, len(lk_t), len(lk_o), ncopied


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text, subs, nt, no, nc = build()
    print(f"NWOLFL.ASM: {text.count(chr(10))} lines; Liu Kang lanes {nt}+{no} lines "
          f"({subs} frames made Nightwolf's, {nc} LK headers copied)")
    if a.apply:
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != text:
            OUT.write_text(text, encoding="latin-1", newline="\r\n")
            print(f"wrote {OUT.relative_to(ROOT)}")
    if a.check:
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != text:
            raise SystemExit(f"{OUT.relative_to(ROOT)} is stale - rerun tools/make_nightwolf_asm.py --apply")
        print("NWOLFL.ASM is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
