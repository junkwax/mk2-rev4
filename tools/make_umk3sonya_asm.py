#!/usr/bin/env python3
r"""src/UMK3SNYL.ASM - MK3 SONYA's animation lanes for the Wolf build, GENERATED.

Her art is packed by tools/make_umk3sonya.py (data/UMK3SNY.LOD ->
src/UMK3SNY.TBL); this writes what draws it:

  * her MK3 lanes, straight out of MK3's own MKSONYA.ASM (MK3's arcade source,
    MK3/MK3_source_windows_RC2/RC2/MK3SRC/V13 - the art is identical in UMK3,
    record for record), every label prefixed `sn_` so nothing can collide with
    an MK2 name.  The run (a_run, SBRUN*) is left out: she has no run.  Her
    `ani_calla` targets are mapped onto MK2: player_normpal and sweep_sounds
    exist here; sonya_zap_pal and sans_repell_3 are written below;
  * `sonya_anitab1`, MK2's TABLE1 layout (Kitana's, fn1_anitab1 - 43h rows),
    each row naming the MK3 lane that plays that action.  Rows MK3 has no lane
    for - being thrown by each MK2 fighter (2Ah-35h) and the fatality victim
    rows (36h-42h) - are KITANA's MK2 lanes copied in (prefixed `snk_`),
    because their adjustments are timed to MK2's own throws and fatalities;
    in the thrown rows Kitana's stumble / flipped / knockdown / stunned frames
    are replaced by Sonya's of the same number, so it is Sonya who is thrown.
    The gore rows still draw Kitana's gore art - Sonya has none in MK2's
    shape (doc/WOLF_CONTENT_PLAN.md);
  * `sonya_anitab2`, MK3's six rows as they are (her specials index it);
  * her palettes, words out of umk3.zip via data/UMK3SNYA.IMG.

    python tools/make_umk3sonya_asm.py            # report
    python tools/make_umk3sonya_asm.py --apply    # write src/UMK3SNYL.ASM
    python tools/make_umk3sonya_asm.py --check    # Phase D: it is current
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_umk3sonya as rip   # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "UMK3SNYL.ASM"
MKSONYA = rip.MK3SRC / "MKSONYA.ASM"
MKFN = ROOT / "src" / "MKFN.ASM"

# MK3 labels left out (the run)
DROP_LABELS = {"a_run", "run_loop"} | {f"SBRUN{n}" for n in range(1, 12)}
# ...and MK3's hand-written stand-ins, which our pack makes unnecessary: the
# LOD packs ENGBALL1 / GUTS PON> with the palette in the header
DROP_LABELS |= {"FAKE_ENGBALL1", "ENGPINK_P", "FAKE_GUTS", "GUTS_P"}
RENAME_TOKEN = {"FAKE_ENGBALL1": "ENGBALL1", "FAKE_GUTS": "GUTS"}
CALLA = {"sonya_zap_pal": "sn_zap_pal", "sans_repell_3": "sn_sans_repell_3",
         "player_normpal": "player_normpal", "sweep_sounds": "sweep_sounds"}

# MK2 TABLE1 (fn1_anitab1's layout) -> her MK3 lane, or "kt" for Kitana's
TABLE1 = [
    "a_stance", "a_walkf", "a_walkf", "a_walkb", "a_walkb",           # 0-4 (no skip: walk)
    "a_duck", "a_jump", "a_fflip", "a_bflip", "a_turn",               # 5-9
    "a_duck_turn", "a_block", "a_duck_block", "a_hikick", "a_lokick",  # a-e
    "a_knockdown", "a_hit_hi", "a_hit_lo", "a_getup", "a_hipunch",     # f-13
    "a_lopunch", "a_sweep_kick", "a_sweep_fall", "a_sweepup",          # 14-17
    "a_duck_punch", "a_duck_kick_hi", "a_duck_kick_lo", "a_duck_hit",  # 18-1b
    "a_uppercut", "a_jump_kick", "a_flip_kick", "a_flip_punch",        # 1c-1f
    "a_roundhouse", "a_knee", "a_elbow", "a_stumble", "a_throw",       # 20-24
    "kt", "a_zap", "a_projectile", "a_dizzy", "a_victory",             # 25-29 (26 throw, 27 flight)
] + ["kt"] * (0x43 - 0x2A)                                             # 2a-42


# --------------------------------------------------------------------------
def blocks(lines):
    """[(label, [lines])] in file order; lines before the first label are ''."""
    out, cur, body = [], "", []
    for ln in lines:
        m = re.match(r"^([A-Za-z_]\w*)\b", ln)
        if m and ln[0] not in " \t*;":
            out.append((cur, body))
            cur, body = m.group(1), [ln]
        else:
            body.append(ln)
    out.append((cur, body))
    return out


def tokens(line):
    s = line.split(";")[0]
    m = re.match(r"^\s*(?:[A-Za-z_]\w*\s+)?\.(long|word)\s+(.*)$", s)
    if not m:
        return []
    return re.findall(r"[A-Za-z_]\w*", m.group(2)) if m.group(1) == "long" else []


def hexfix(line):
    """MK3 wrote hex as >1f / ->1f; MK2's GSPA flags want 01fh / -01fh."""
    code, sep, com = line.partition(";")
    code = re.sub(r"(-?)>([0-9a-fA-F]+)\b", lambda m: f"{m.group(1)}0{m.group(2)}h", code)
    return code + sep + com


def rename_line(line, mapping):
    """Rename label tokens per mapping in code (comment kept as is)."""
    code, sep, com = line.partition(";")
    code = re.sub(r"[A-Za-z_]\w*", lambda m: mapping.get(m.group(0), m.group(0)), code)
    return code + sep + com


# --------------------------------------------------------------------------
def mk3_part():
    lines = MKSONYA.read_text(errors="replace").splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip().lower() == ".text") + 1
    bl = blocks(lines[start:])
    labels = {lab for lab, _b in bl if lab}
    drop_tables = {"sonya_anitab1", "sonya_anitab2"}
    mapping = {lab: "sn_" + lab for lab in labels}
    mapping.update(RENAME_TOKEN)
    mapping.update(CALLA)
    out = []
    for lab, body in bl:
        if lab in DROP_LABELS or lab in drop_tables:
            continue
        for ln in body:
            if re.match(r"^\s*\.end\b", ln, re.I):
                continue
            # MK3's own typo: SBAIRPUNCH1's list ends ",a0" where every frame
            # list ends ",0" (a register name, read as a symbol)
            ln = re.sub(r"(SBAIRPUNCH1A),a0\b", r"\1,0", ln)
            out.append(hexfix(rename_line(ln.rstrip(), mapping)))
    # MK2 walks four lanes FURTHER than MK3 laid them out (MK3 lowers a guard
    # by playing a_block backwards; MK2's do_unblock_hi takes the lane's PART
    # TWO, and with none find_ani_part2 ran off the end into the frame lists
    # that follow).  The missing parts, in MK2's shape (MKFN.ASM a_fnblockhi /
    # a_fnduckblock / a_fnkdown / a_fnflipkick): (lane, after its Nth 0, frames)
    for lane, nth, frames in (
            ("sn_a_block", 1, ["SBHIBLOCK2", "SBHIBLOCK1"]),
            ("sn_a_duck_block", 1, ["SBDUCKBLOCK2", "SBDUCKBLOCK1", "SBDUCK3"]),
            ("sn_a_knockdown", 2, ["SBKNOCKDOWN6", "SBKNOCKDOWN7", "SBKNOCKDOWN6", "SBKNOCKDOWN7"]),
            ("sn_a_flip_kick", 2, ["SBFLIPKICK2", "SBFLIPKICK1"])):
        for fr in frames:
            if fr not in labels:
                raise SystemExit(f"{lane}: MK3 has no frame list {fr}")
        i = next(n for n, ln in enumerate(out) if re.match(lane + r"\b", ln))
        seen = 0
        for j in range(i + 1, len(out)):
            if re.match(r"^\s*\.long\s+0\s*(;.*)?$", out[j]):
                seen += 1
                if seen == nth:
                    out[j + 1:j + 1] = [f"\t.long\tsn_{fr}" for fr in frames] + \
                                       ["\t.long\t0\t\t; (MK2's extra part - make_umk3sonya_asm.py)"]
                    break
        else:
            raise SystemExit(f"{lane}: fewer than {nth} parts in MK3's lane")
    tables = {}
    for lab, body in bl:
        if lab in drop_tables:
            tables[lab] = [t for ln in body for t in tokens(ln)]
    return out, labels, tables


def kitana_part(rows):
    """Kitana's lanes for the given fn1_anitab1 rows, copied with every label
    they reach (prefixed snk_); in the THROWN rows her body frames become
    Sonya's frames of the same number."""
    lines = MKFN.read_text(encoding="latin-1").splitlines()
    bl = blocks(lines)
    index = {lab: i for i, (lab, _b) in enumerate(bl) if lab}
    # fn1_anitab1's rows (fn1/fn2/fn3 share one table)
    i = index["fn3_anitab1"]
    row_labels = [t for ln in bl[i][1] for t in tokens(ln)][:0x43]
    want = {k: row_labels[k] for k in rows}
    keep, todo = [], list(want.values())
    seen = set()
    while todo:
        lab = todo.pop()
        if lab in seen or lab not in index:
            continue
        seen.add(lab)
        j = index[lab]
        chain = [j]
        # a lane falls into the next label when it is a part of it (no
        # terminating ani_jump and the next label is not a new lane/frame)
        while True:
            body = bl[chain[-1]][1]
            last = [ln for ln in body if tokens(ln) or re.search(r"\.long\s+0\b", ln)]
            nxt = chain[-1] + 1
            if nxt >= len(bl):
                break
            nlab = bl[nxt][0]
            if (last and "ani_jump" in last[-1]) or re.match(r"^(a_|[A-Z])", nlab or "A"):
                break
            chain.append(nxt)
        for k in chain:
            if bl[k][0] not in seen or k == j:
                seen.add(bl[k][0])
                keep.append(k)
            for ln in bl[k][1]:
                for t in tokens(ln):
                    if t in index and t not in seen:
                        todo.append(t)
    keep = sorted(set(keep))
    labs = {bl[k][0] for k in keep}
    mapping = {lab: "snk_" + lab for lab in labs}
    return [rename_line(ln.rstrip(), mapping) for k in keep for ln in bl[k][1]
            if not re.match(r"^\s*\.(end|text|data|bss)\b", ln, re.I)], want, mapping


def prune_unused(lines, prefix):
    """Drop copied single-line frame definitions nothing references any more
    (the thrown lanes' Kitana frames, once Sonya's replaced them)."""
    while True:
        refs = set()
        for ln in lines:
            code = ln.split(";")[0]
            m = re.match(r"^[A-Za-z_]\w*", code)
            refs |= set(re.findall(r"[A-Za-z_]\w*", code[m.end():] if m else code))
        out, drop = [], False
        changed = False
        for ln in lines:
            m = re.match(r"^(" + prefix + r"\w+)", ln)
            if m:
                drop = m.group(1) not in refs and not m.group(1).startswith(prefix + "a_")
                changed |= drop
            elif ln.strip() and not ln.startswith((" ", "\t", ";", "*")):
                drop = False
            if not drop:
                out.append(ln)
        lines = out
        if not changed:
            return lines


def copy_headers(lines, mk3_labels):
    """Header text for every record the copied lanes name that this module
    does not already have: [label, .word geometry, .long sag, .word ctrl]."""
    have = set(re.findall(r"^(\w+):", (ROOT / "src" / "UMK3SNY.TBL").read_text(), re.M))
    defined = {re.match(r"^([A-Za-z_]\w*)", ln).group(1) for ln in lines
               if re.match(r"^[A-Za-z_]\w*", ln)}
    want = set()
    for ln in lines:
        if ln.startswith("*"):
            continue
        code = ln.split(";")[0]
        m = re.match(r"^[A-Za-z_]\w*", code)
        for t in re.findall(r"\b[A-Z][A-Z0-9_]*\d[A-Z]?\b", code[m.end():] if m else code):
            if t not in have and t not in defined and not t.startswith(("SN_", "SNK_", "SNT_")):
                want.add(t)
    found = {}
    for p in sorted((ROOT / "src").glob("*.TBL")):
        tl = p.read_text(encoding="latin-1").splitlines()
        for i, ln in enumerate(tl):
            m = re.match(r"^(\w+):\s*$", ln)
            if m and m.group(1) in want and m.group(1) not in found:
                found[m.group(1)] = [f"{m.group(1)}:"] + tl[i + 1:i + 4]
    globals_ = set(re.findall(r"\.global\s+([\w, \t]+)", (ROOT / "src" / "MAINEQU.ASM").read_text(encoding="latin-1")))
    gl = {g.strip() for line in globals_ for g in line.split(",")}
    missing = sorted(w for w in want if w not in found and w not in gl)
    if missing:
        raise SystemExit(f"copied Kitana lanes name records found in no TBL: {missing[:8]}")
    return [ln for k in sorted(found) for ln in found[k]]


def stk_records(text):
    """label -> [the record's lines] for every stk_ record in an MKSTK.ASM;
    stacked labels share their record."""
    lines = text.splitlines()
    out, pending, body = {}, [], []

    def close():
        for p in pending:
            out[p] = list(body)

    for ln in lines:
        m = re.match(r"^(stk_\w+)\s*(;.*)?$", ln)
        if m:
            if body:
                close()
                pending.clear()
                body.clear()
            pending.append(m.group(1))
            continue
        if not pending:
            continue
        s = ln.strip()
        if not s or s.startswith((";", "*")):
            continue
        if re.match(r"^\s+\.(word|long)\b", ln, re.I):
            body.append(ln.rstrip())
            continue
        close()                       # anything else ends the record
        pending.clear()
        body.clear()
    if pending and body:
        close()
    return out


# her normals keep Kitana's MK2 reaction, damage, score and sound, and take
# MK3's box (it fits her sprites): fn_strikes index -> MK3 stk_sonya_* record
MK3_NORMALS = ["hikick", "lokick", "hi_punch", "lo_punch", "sweep", "duck_punch",
               "duck_kickh", "duck_kickl", "uppercut", "jump_punch", "jump_kick",
               "flip_kick", "flip_punch", "roundh", "knee", "elbow"]
# her specials, after Kitana's 1bh rows: index -> (MK3 record, MK2 record whose
# reaction/score/sound it takes, or None to keep MK3's damage word too)
SONYA_SPECIALS = [(0x1B, "stk_sonya_zap", "stk_fnfans"),
                  (0x1C, "stk_sonya_prezap", "stk_fnfans"),
                  (0x1D, "stk_sonya_bike", "stk_fnflipk"),
                  (0x1E, "stk_sonya_leg", "stk_swordkick")]
# words a special takes outright instead of its source record's: the leg
# grab's hit is react_to_fn row 1ah (r_sa_leggrab, Wolf only - MKREACT.ASM),
# its block b_scissor (18h), and like Baraka's it does no damage itself - 2
# chip on a block; the slam applies the 26
SPECIAL_WORDS = {0x1E: ("\t.word\t01a18h\t\t; hit -> react_to_fn 1ah r_sa_leggrab, block -> b_scissor",
                        "\t.word\t00002h\t\t; the slam applies its own 26; 2 chip on a block")}
STK_SQUARE = 0x15            # Kitana's square wave row - Sonya's square goes here


def strike_table():
    mk2 = stk_records((ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1"))
    mk3 = stk_records((rip.MK3SRC / "MKSTK.ASM").read_text(errors="replace"))
    src = (ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1").splitlines()
    i = next(k for k, ln in enumerate(src) if ln.startswith("fn_strikes"))
    fn_rows = []
    for ln in src[i + 1:]:
        m = re.match(r"^\s*\.long\s+(\w+)", ln)
        if not m:
            break
        fn_rows.append(m.group(1))

    def rec(geo_from, rest_from, keep_damage=True):
        g = [hexfix(x) for x in mk3[geo_from][:4]] if geo_from else mk2[rest_from][:4]
        r = mk2[rest_from]
        body = g + [r[4], (r[5] if keep_damage else hexfix(mk3[geo_from][5]))] + r[6:]
        return body

    out = ["", "; --- her strike table: Kitana's layout, MK3's boxes " + "-" * 18,
           "\t.globl\tsonya_strikes", "sonya_strikes"]
    recs = []
    for k, lab in enumerate(fn_rows):
        if k < len(MK3_NORMALS):
            body = rec("stk_sonya_" + MK3_NORMALS[k], lab)
            note = f"MK3 stk_sonya_{MK3_NORMALS[k]} box, Kitana's {lab} rest"
        elif k == STK_SQUARE:
            body = rec("stk_sonya_square", lab, keep_damage=False)
            note = f"MK3 stk_sonya_square, Kitana's {lab} reaction"
        else:
            body = mk2[lab]
            note = f"Kitana's {lab} (not hers)"
        out.append(f"\t.long\tsn_stk_{k:02x}\t; {k:02x} - {note}")
        recs.append((f"sn_stk_{k:02x}", body))
    for k, m3, m2 in SONYA_SPECIALS:
        if k != len(recs):
            raise SystemExit(f"her special stk {k:02x} is not the next row ({len(recs):02x})")
        out.append(f"\t.long\tsn_stk_{k:02x}\t; {k:02x} - MK3 {m3}, {m2}'s reaction")
        body = rec(m3, m2, keep_damage=False)
        if k in SPECIAL_WORDS:
            body[4:6] = list(SPECIAL_WORDS[k])
        recs.append((f"sn_stk_{k:02x}", body))
    for lab, body in recs:
        out += ["", lab] + body
    return out


# her TABLE2: MK3's six lanes, re-ordered so MK2's own routines find theirs -
# do_square_wave (MKPROP.ASM) reads row 5, as it does for Kitana
TABLE2 = ["a_leg_grab", "a_bike", "a_death_kiss", "a_sonya_energy_ball", "a_gutz", "a_square"]

THROWN = range(0x2A, 0x36)
SUBST = [(r"KTSTUMBLE(\d+)", "SBSTUMBLE"), (r"KTGETFLIPPED(\d+)", "SBFLIPPED"),
         (r"KTKNOCKDOWN(\d+)", "SBKNOCKDOWN"), (r"KTSTUNNED(\d+)", "SBSTUNNED"),
         (r"KTSWEEPUP(\d+)", "SBSWEEPUP")]


def mk2_palette(name):
    """The words of a palette of that name another src/*.ASM defines, or None."""
    for f in sorted((ROOT / "src").glob("*.ASM")):
        if f.name.upper() in ("UMK3SNYL.ASM", "UMK3SDL.ASM"):   # generated lane modules
            continue
        lines = f.read_text(errors="replace").splitlines()
        for i, ln in enumerate(lines):
            if ln.split(";")[0].strip() in (name + ":", name):
                words = []
                for w in lines[i + 1:]:
                    m = re.match(r"\s*\.word\s+(.*)", w.split(";")[0])
                    if not m:
                        break
                    words += [int(v.rstrip("Hh"), 16) if v.upper().endswith("H") else int(v)
                              for v in re.split(r"[,\s]+", m.group(1).strip()) if v]
                return words[1:] if words else None
    return None


def build():
    recs, named, _L, _ba, _fk = rip.read(rip.UMK3())
    # a palette MK2 already links under the same name (MK3's SKELFIR_P is
    # IMGPAL6.ASM's, word for word) is referenced, not emitted twice - and if
    # the words ever differ that is a clash to settle by hand
    shared = set()
    for _a, (nm, words) in named.items():
        mine = mk2_palette(nm)
        if mine is None:
            continue
        if mine != list(words):
            raise SystemExit(f"{nm}: MK2 links a DIFFERENT palette under this name - rename one")
        shared.add(nm)
    mk3, mk3_labels, mk3_tabs = mk3_part()
    kt_rows = [k for k, v in enumerate(TABLE1) if v == "kt"]
    thrown_rows = [k for k in kt_rows if k in THROWN]
    other_rows = [k for k in kt_rows if k not in THROWN]
    kt_thrown, want_t, map_t = kitana_part(thrown_rows)
    kt_other, want_o, map_o = kitana_part(other_rows)
    # thrown lanes: rename to a separate prefix so the two copies never clash,
    # and put Sonya's own frames in
    kt_thrown = [ln.replace("snk_", "snt_") for ln in kt_thrown]
    map_t = {k: v.replace("snk_", "snt_") for k, v in map_t.items()}
    subs = 0

    def sub(ln):
        nonlocal subs
        code, sep, com = ln.partition(";")
        lead = ""
        m = re.match(r"^[A-Za-z_]\w*", code)
        if m:                      # a DEFINITION keeps its own (Kitana) name
            lead, code = m.group(0), code[m.end():]
        for pat, sb in SUBST:
            def r(m):
                nonlocal subs
                cand = f"{sb}{m.group(1)}"
                if cand in mk3_labels:
                    subs += 1
                    return "sn_" + cand
                return m.group(0)
            code = re.sub(r"\bsnt_" + pat + r"\b", r, code)
        return lead + code + sep + com
    kt_thrown = [sub(ln) for ln in kt_thrown]
    kt_thrown = prune_unused(kt_thrown, "snt_")
    kt_other = prune_unused(kt_other, "snk_")
    # the Kitana records those lanes still draw are LOCAL to MKFN, so their
    # headers are copied in (no palette .long - drawn in her costume palette)
    copied = copy_headers(kt_thrown + kt_other, mk3_labels)

    import hashlib
    tblhash = hashlib.sha1((ROOT / "src" / "UMK3SNY.TBL").read_bytes()
                           + (ROOT / "src" / "UMK3SNF.TBL").read_bytes()
                           + (ROOT / "src" / "MKFN.TBL").read_bytes()).hexdigest()[:12]
    out = [";" + "*" * 70,
           f";  tables {tblhash} - UMK3SNY.TBL + MKFN.TBL, so a repack changes THIS",
           ";  file and gmake reassembles it (it only watches the .ASM)",
           ";  MK3 SONYA (Wolf only) - her animation lanes.  GENERATED by",
           ";  tools/make_umk3sonya_asm.py out of MK3's MKSONYA.ASM and MK2's",
           ";  MKFN.ASM; edit the tool, never this file.",
           ";" + "*" * 70,
           '\t.file\t"umk3snyl.asm"',
           "\t.width\t132",
           "\t.option\tb,d,l,t",
           "\t.mnolist",
           "\t.include\tdispequ.asm",
           "\t.include\tsysequ.asm",
           "\t.include\tmacros.hdr",
           "\t.include\tmainequ.asm",
           "\t.if\twunit",
           "\t.include\tumk3sny.tbl",
           "\t.include\tumk3snf.tbl",	# her fatality art, data/UMK3SNF.LOD
           "\t.globl\tsonya_anitab1,sonya_anitab2",
           "\t.globl\t" + ",".join(nm for _a, (nm, _w) in named.items() if nm not in shared),
           *(["\t.ref\t" + ",".join(sorted(shared))] if shared else []),
           "\t.ref\tplayer_normpal,sweep_sounds,player_swpal"]
    # MK3's shared fatality art her kiss draws (UMK3SNYM.ASM's sny_a_skelburn)
    fatal = [n for n in re.findall(r"^(\w+):", (ROOT / "src" / "UMK3SNF.TBL").read_text(), re.M)
             if re.match(r"^(SBFIRE|SKELFIRE)\d", n)]
    out += ["\t.globl\t" + ",".join(fatal[i:i + 8]) for i in range(0, len(fatal), 8)]
    out += ["\t.text", ""]
    # MK2 TABLE1
    out.append("sonya_anitab1")
    for k, v in enumerate(TABLE1):
        if v == "kt":
            src = want_t.get(k) or want_o.get(k)
            lab = (map_t if k in THROWN else map_o)[src]
            out.append(f"\t.long\t{lab}\t; {k:02x} - Kitana's {src}")
        else:
            out.append(f"\t.long\tsn_{v}\t; {k:02x}")
    # the frame Shang's morph lane (a_st_2_sonya, MKST.ASM) lands on
    out += ["", "\t.globl\tsonya_stance1", "sonya_stance1",
            "\t.long\tSBSTANCE1A,SBSTANCE1B,0"]
    out += ["", "sonya_anitab2"]
    if sorted(TABLE2) != sorted(mk3_tabs["sonya_anitab2"]):
        raise SystemExit("TABLE2 is not MK3's six lanes re-ordered")
    for k, v in enumerate(TABLE2):
        out.append(f"\t.long\tsn_{v}\t; {k}")
    out += ["", "; --- her MK3 lanes " + "-" * 50] + mk3
    out += ["", "; --- Kitana's MK2 THROWN lanes, Sonya's frames " + "-" * 22] + kt_thrown
    out += ["", "; --- Kitana's MK2 fatality-victim lanes (Kitana's art) " + "-" * 13] + kt_other
    out += ["", "; --- headers of the Kitana records those lanes draw (local to MKFN, so",
            ";     copied; no palette .long - drawn in Sonya's costume palette)",
            "\t.data"] + copied + ["\t.text"]
    out += strike_table()
    out += ["", "; --- the routines her lanes call " + "-" * 36,
            "sn_sans_repell_3",
            "\tmovk\t3,a7",
            "\tmove\ta7,@f_norepell,w\t; MK3's sans_repell_3: no repell for 3 ticks",
            "\trets",
            "",
            "sn_zap_pal",
            "\tmovi\tSBENGZAP_P,a0\t\t; MK3's sonya_zap_pal: the glowing-hands palette",
            "\tcalla\tplayer_swpal",
            "\trets",
            ""]
    # palettes
    out.append("; --- her palettes (umk3.zip) " + "-" * 40)
    pals = list(named.values())
    eng = rip.UMK3()
    sbeng = next(r for r in recs if r["name"] == "SBENG1A")
    pals.append(("SBENGZAP_P", eng.palette(sbeng["group"])))
    for nm, words in pals:
        if nm in shared:
            continue                    # MK2 already links it (mk2_palette)
        out.append(f"{nm}:")
        out.append(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            out.append("\t.word\t" + ",".join(f"0{w:04x}h" for w in words[i:i + 8]))
    out += ["", "\t.endif", "\t.end", ""]
    return "\n".join(out), subs, len(kt_thrown), len(kt_other)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text, subs, nt, no = build()
    print(f"UMK3SNYL.ASM: {text.count(chr(10))} lines; Kitana thrown lanes {nt} lines "
          f"({subs} frames made Sonya's), victim lanes {no} lines")
    if a.apply:
        OUT.write_text(text, encoding="latin-1", newline="\r\n")
        print(f"wrote {OUT.relative_to(ROOT)}")
    if a.check:
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != text:
            raise SystemExit(f"{OUT.relative_to(ROOT)} is stale - rerun tools/make_umk3sonya_asm.py --apply")
        print("UMK3SNYL.ASM is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
