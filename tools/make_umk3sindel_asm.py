#!/usr/bin/env python3
r"""src/UMK3SDL.ASM - UMK3 SINDEL's animation lanes for the Wolf build, GENERATED.

Her art is packed by tools/make_umk3sindel.py (data/UMK3SDA.LOD + UMK3SDB.LOD
-> src/UMK3SDA.TBL + UMK3SDB.TBL); this writes what draws it.

DECOMPILED FROM UMK3, NOT COPIED FROM MK3.  MK3's MKLIA.ASM is not what UMK3
ships for her: 287 of the records its lanes name are drawn by none of her UMK3
lanes (a hipunch frame 7, the side spit, the thud, the run, the gore rips) and
two of UMK3's lanes (the fireball, the hair wrap) are art MK3 never had.  So
every lane is read out of umk3.zip - `character_anitabs1/2` entry 6, TABLE1
FF88C760 (42h rows), TABLE2 FF88D080 (11 rows) - and written back as GSPA:

  * the animator commands are MK3's and MK2's alike (1..15, MAINEQU.ASM), so
    a lane is re-emitted command for command with its operands;
  * every frame list is re-emitted under MK3's own name when MKLIA.ASM has a
    list of exactly those pieces (`sd_LISTUMBLE1`), else `sdf_<address>`;
  * `ani_calla` targets are UMK3 addresses, mapped by hand (CALLA) onto MK2
    (`sweep_sounds`) or onto local copies of MK3's routines below;
  * jumps land on generated labels; lanes that run on into the next lane in
    ROM are emitted in ROM order, so the fall-through survives.

  * `sindel_anitab1`, MK2's TABLE1 layout (Kitana's, 43h rows), each row the
    UMK3 lane for that action.  Rows UMK3 has no lane for in MK2's shape -
    being thrown by each MK2 fighter (2Ah-35h) and the fatality-victim rows
    (36h-42h) - are KITANA's MK2 lanes copied in (as for Sonya): `sdt_` with
    Kitana's stumble / flipped / knockdown / stunned / sweep-up frames made
    Sindel's of the same number, `sdk_` (the gore rows) still Kitana's art;
  * `sindel_anitab2`, UMK3's eleven rows as they are (her specials index it);
  * `sindel_strikes` - Kitana's layout with MK3's `stk_li_*` boxes, and her
    specials after it;
  * her palettes, words out of umk3.zip.

    python tools/make_umk3sindel_asm.py            # report
    python tools/make_umk3sindel_asm.py --apply    # write src/UMK3SDL.ASM
    python tools/make_umk3sindel_asm.py --check    # Phase D: it is current
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_umk3sonya as sny          # noqa: E402
import make_umk3sonya_asm as sna      # noqa: E402
import make_umk3sindel as rip         # noqa: E402
from umk3rom import UMK3              # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "UMK3SDL.ASM"
MKLIA = sny.MK3SRC / "MKLIA.ASM"
CMD = {0: None, 1: "ani_jump", 2: "ani_flip", 3: "ani_adjustx", 4: "ani_adjustxy",
       5: "ani_nosleep", 6: "ani_calla", 9: "ani_flip_v", 10: "ani_offset_xy",
       11: "ani_sladd", 12: "ani_slani", 13: "ani_swpal", 14: "ani_slani_sleep"}
# UMK3 routine -> what the lane calls here (MK3 names in the comment)
CALLA = {0xFFB58280: "sweep_sounds",          # MK3 sweep_sounds (MKSOUND)
         0xFF89A730: "sd_new_float_ani",      # MK3 new_float_ani (MKLIA)
         0xFF9B0670: "sd_slave_inviso",       # MK3 slave_inviso (MKUTIL)
         0xFF9B0630: "sd_slave_viso"}         # MK3 slave_viso
# MK2 TABLE1 (Kitana's layout) -> MK3 action name (an index into lia_anitab1)
TABLE1 = sna.TABLE1
# UMK3's TABLE1 is not MK3's past the "flipped by" rows (26h on): it has more
# of them, so MK3's row names are shifted there.  The one action MK2's layout
# takes from that range is named by its UMK3 row, and checked by content.
UMK3_ROW = {"a_projectile": (0x3F, "sd_LIAFB1")}


def umk3_row(names1, action):
    return UMK3_ROW[action][0] if action in UMK3_ROW else names1.index(action)
THROWN = sna.THROWN
# MK2 TABLE1 rows whose lane MK2 walks past where UMK3's ends (see build())
MK2_SHAPE = {0x0B: "block", 0x0C: "duckblock", 0x0F: "kdown", 0x1E: "flipkick"}
SUBST = [(r"KTSTUMBLE(\d+)", "LISTUMBLE"), (r"KTGETFLIPPED(\d+)", "LIFLIPPED"),
         (r"KTKNOCKDOWN(\d+)", "LIKNOCKDOWN"), (r"KTSTUNNED(\d+)", "LISTUNNED"),
         (r"KTSWEEPUP(\d+)", "LISWEEPUP"), (r"KTHITHI(\d+)", "LIHIHIT")]
# her normals: Kitana's MK2 reaction/damage/score/sound, MK3's box
MK3_NORMALS = ["hikick", "lokick", "hi_punch", "lo_punch", "sweep", "duck_punch",
               "duck_kickh", "duck_kickl", "uppercut", "jump_punch", "jump_kick",
               "flip_kick", "flip_punch", "roundh", "knee", "elbow"]
# her specials after Kitana's 1bh rows: (MK3 record, MK2 record whose
# reaction / score / sound it takes)
# The fireballs take MILEENA's sai hit (r_tsai, a short stumble back) - MK3's
# r_lia_zap is that - not Kitana's fan hit, which staggers a man back for
# over a second and is the wrong shape for a 20-damage fireball.
SPECIALS = [(0x1B, "stk_li_scream", "stk_fnfans"),
            (0x1C, "stk_li_angle_zap", "stk_fntsai"),
            (0x1D, "stk_li_angle_zap2", "stk_fntsai"),
            (0x1E, "stk_li_angle_zap3", "stk_fntsai"),
            (0x1F, "stk_li_forward", "stk_fntsai")]


def mk3_lists():
    """MKLIA.ASM's frame lists: name -> (piece names)"""
    out = {}
    lines = MKLIA.read_text(errors="replace").splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r"^([A-Z][A-Z0-9_]*)\s*(\.long\s+(.*))?$", ln.split(";")[0].rstrip())
        if not m:
            continue
        body = m.group(3)
        if body is None and i + 1 < len(lines):
            n = re.match(r"^\s+\.long\s+(.*)$", lines[i + 1].split(";")[0])
            body = n.group(1) if n else None
        if body is None:
            continue
        toks = [t.strip() for t in body.split(",")]
        if toks and toks[-1] == "0" and all(re.match(r"^[A-Z]\w*$", t) for t in toks[:-1]):
            out.setdefault(m.group(1), tuple(toks[:-1]))
    return out


def lane_names():
    txt = MKLIA.read_text(errors="replace").splitlines()
    out = {}
    for tab in ("lia_anitab1", "lia_anitab2"):
        i = next(n for n, ln in enumerate(txt) if ln.strip() == tab) + 1
        names = []
        while i < len(txt):
            s = txt[i].split(";")[0].strip()
            i += 1
            if not s:
                if names:
                    break
                continue
            m = re.match(r"\.long\s+(\w+)", s)
            if not m:
                break
            names.append(m.group(1))
        out[tab[-1]] = names
    return out


# --------------------------------------------------------------------------
def decompile(u, by_addr):
    """Every lane UMK3 reaches from her tables, as segments of (address, op)."""
    t1, t2 = u.l(sny.ANITABS1 + 32 * rip.LIA), u.l(sny.ANITABS2 + 32 * rip.LIA)
    rows = [("1", k, u.l(t1 + 32 * k)) for k in range(rip.TAB1_ROWS)]
    rows += [("2", k, u.l(t2 + 32 * k)) for k in range(rip.TAB2_ROWS)]
    entries = {a for _t, _k, a in rows if sny.inside(a)}
    todo, seg = sorted(entries), {}
    lists, targets = {}, set(entries)
    while todo:
        a = todo.pop()
        if any(a in s for s in (set(x for x, _ in v) for v in seg.values())):
            continue
        start, ops = a, []
        while True:
            if a in seg and a != start:          # ran into a decoded segment
                break
            v = u.l(a)
            if v == 0:
                ops.append((a, ("end",)))
                a += 32
                continue
            if v == 1:
                tgt = u.l(a + 32)
                ops.append((a, ("jump", tgt)))
                targets.add(tgt)
                if tgt not in seg:
                    todo.append(tgt)
                a += 64
                # a further PART after the loop (rip.walk's rule)
                if u.l(a) == 0 and sny.pieces(u, u.l(a + 32)) is not None and a not in entries:
                    continue
                break
            if v in (3, 4, 10):
                n = sny.OPS[v] // 16
                ops.append((a, ("cmd", v, [u.sw(a + 32 + 16 * i) for i in range(n)])))
                a += 32 + sny.OPS[v]
                continue
            if v == 6:
                t = u.l(a + 32)
                if t not in CALLA:
                    raise SystemExit(f"lane {start:08X}: ani_calla {t:08X} is not mapped")
                ops.append((a, ("calla", CALLA[t])))
                a += 64
                continue
            if v == 11:
                f = u.l(a + 32)
                lists[f] = sny.pieces(u, f)
                ops.append((a, ("sladd", f)))
                a += 64
                continue
            if v in CMD and CMD[v]:
                ops.append((a, ("cmd", v, [])))
                a += 32 + sny.OPS[v]
                continue
            if v <= 15:
                raise SystemExit(f"lane {start:08X}: command {v} at {a:08X} is not handled")
            p = sny.pieces(u, v)
            if p is None:
                break
            lists[v] = p
            ops.append((a, ("frame", v)))
            a += 32
        seg[start] = ops
        # a lane that stopped on another segment's start falls into it
    # merge segments into address order; a later segment that begins inside
    # an earlier one is dropped (its addresses are already emitted)
    out, covered = [], set()
    for s in sorted(seg):
        ops = [(a, op) for a, op in seg[s] if a not in covered]
        covered |= {a for a, _ in ops}
        if ops:
            out.append(ops)
    for p in {p for ps in lists.values() for p in ps}:
        if p not in by_addr:
            raise SystemExit(f"frame piece {p:08X} is not one of the packed records")
    return rows, out, lists, targets


def build():
    u = UMK3()
    recs, named, costume, _L = rip.read(u)
    by_addr = {r["addr"]: r for r in recs}
    rows, segs, lists, targets = decompile(u, by_addr)
    # frame list names: MK3's where its pieces match exactly
    by_pieces = {}
    for nm, ps in mk3_lists().items():
        by_pieces.setdefault(ps, nm)
    fname = {}
    for f, ps in lists.items():
        key = tuple(by_addr[p]["name"] for p in ps)
        fname[f] = ("sd_" + by_pieces[key]) if key in by_pieces else f"sdf_{f:08X}"
    if len(set(fname.values())) != len(fname):
        # two UMK3 lists with the same pieces under one MK3 name
        seen = {}
        for f in sorted(fname):
            n = fname[f]
            if n in seen:
                fname[f] = f"sdf_{f:08X}"
            seen[n] = f
    lab = {a: f"sd_{a:08X}" for a in targets}
    names = lane_names()
    for t, k, a in rows:
        if sny.inside(a):
            nm = names[t][k] if k < len(names[t]) else ""
            if nm and nm not in ("0",):
                lab.setdefault(a, f"sd_{a:08X}")

    # ---- Kitana's rows (thrown + fatality victims), as for Sonya
    kt_rows = [k for k, v in enumerate(TABLE1) if v == "kt"]
    thrown_rows = [k for k in kt_rows if k in THROWN]
    other_rows = [k for k in kt_rows if k not in THROWN]
    kt_thrown, want_t, map_t = sna.kitana_part(thrown_rows)
    kt_other, want_o, map_o = sna.kitana_part(other_rows)
    kt_thrown = [ln.replace("snk_", "sdt_") for ln in kt_thrown]
    kt_other = [ln.replace("snk_", "sdk_") for ln in kt_other]
    map_t = {k: v.replace("snk_", "sdt_") for k, v in map_t.items()}
    map_o = {k: v.replace("snk_", "sdk_") for k, v in map_o.items()}
    have = set(fname.values())
    mk3l = mk3_lists()
    packed = {r["name"] for r in recs}
    extra = {}                      # MK3 frame lists the thrown rows need
    subs = 0

    def sub(ln, prefix="sdt_"):
        nonlocal subs
        code, sep, com = ln.partition(";")
        lead = ""
        m = re.match(r"^[A-Za-z_]\w*", code)
        if m:
            lead, code = m.group(0), code[m.end():]
        for pat, sb in SUBST:
            def r(m):
                nonlocal subs
                cand = f"{sb}{m.group(1)}"
                if "sd_" + cand in have:
                    subs += 1
                    return "sd_" + cand
                if cand in mk3l and all(p in packed for p in mk3l[cand]):
                    extra[cand] = mk3l[cand]
                    subs += 1
                    return "sd_" + cand
                # past her last frame of that family: her last one (she has 5
                # flipped frames where Kitana has more) - never Kitana's art
                n = int(m.group(1))
                while n > 1:
                    n -= 1
                    c2 = f"{sb}{n}"
                    if "sd_" + c2 in have or (c2 in mk3l and all(p in packed for p in mk3l[c2])):
                        if "sd_" + c2 not in have:
                            extra[c2] = mk3l[c2]
                        subs += 1
                        return "sd_" + c2
                return m.group(0)
            code = re.sub(r"\b" + prefix + pat + r"\b", r, code)
        return lead + code + sep + com
    kt_thrown = [sub(ln) for ln in kt_thrown]
    # the other borrowed rows (bike-kicked, banged, nut-crunched, Kintaro's
    # throw ...) draw the same common frames: hers there too.  The gore-only
    # frames (decap, torso rip, impale, back break) have no art of hers.
    kt_other = [sub(ln, "sdk_") for ln in kt_other]
    kt_thrown = sna.prune_unused(kt_thrown, "sdt_")
    kt_other = sna.prune_unused(kt_other, "sdk_")
    copied = sna.copy_headers(kt_thrown + kt_other, set())

    tblhash = hashlib.sha1(b"".join((ROOT / "src" / n).read_bytes()
                                    for n in ("UMK3SDA.TBL", "UMK3SDB.TBL", "MKFN.TBL"))).hexdigest()[:12]
    shared = set()
    for _a, (nm, words) in named.items():
        mine = sna.mk2_palette(nm)
        if mine is None:
            continue
        if mine != list(words):
            raise SystemExit(f"{nm}: MK2 links a DIFFERENT palette under this name - rename one")
        shared.add(nm)
    out = [";" + "*" * 70,
           f";  tables {tblhash} - UMK3SDA/SDB.TBL + MKFN.TBL, so a repack changes THIS",
           ";  file and gmake reassembles it (it only watches the .ASM)",
           ";  UMK3 SINDEL (Wolf only) - her animation lanes, DECOMPILED out of",
           ";  umk3.zip by tools/make_umk3sindel_asm.py; edit the tool, never this file.",
           ";" + "*" * 70,
           '\t.file\t"umk3sdl.asm"',
           "\t.width\t132",
           "\t.option\tb,d,l,t",
           "\t.mnolist",
           "\t.include\tdispequ.asm",
           "\t.include\tsysequ.asm",
           "\t.include\tmacros.hdr",
           "\t.include\tmainequ.asm",
           "\t.if\twunit",
           "\t.include\tumk3sda.tbl",
           "\t.include\tumk3sdb.tbl",
           "\t.globl\tsindel_anitab1,sindel_anitab2,sindel_strikes,sindel_stance1",
           "\t.globl\tsd_new_float_ani,sd_slave_inviso,sd_slave_viso",
           "\t.globl\t" + ",".join(nm for _a, (nm, _w) in named.items() if nm not in shared),
           *(["\t.ref\t" + ",".join(sorted(shared))] if shared else []),
           "\t.ref\tsweep_sounds,set_inviso",
           "\t.text", ""]
    # TABLE1
    lia1 = names["1"]
    t1 = {k: a for t, k, a in rows if t == "1"}
    t2 = {k: a for t, k, a in rows if t == "2"}
    out.append("sindel_anitab1")
    for k, v in enumerate(TABLE1):
        if v == "kt":
            src = want_t.get(k) or want_o.get(k)
            lb = (map_t if k in THROWN else map_o)[src]
            out.append(f"\t.long\t{lb}\t; {k:02x} - Kitana's {src}")
        else:
            a = t1[umk3_row(lia1, v)]
            if v in UMK3_ROW:
                first = next(op for ops in segs for x, op in ops if x == a)
                if first[0] != "frame" or fname[first[1]] != UMK3_ROW[v][1]:
                    raise SystemExit(f"UMK3 row {UMK3_ROW[v][0]:02X} is not {v} ({UMK3_ROW[v][1]})")
            if k in MK2_SHAPE:
                out.append(f"\t.long\tsd_mk2_{k:02x}\t; {k:02x} - UMK3 {v}, re-cut to MK2's parts")
            else:
                out.append(f"\t.long\t{lab[a]}\t; {k:02x} - UMK3 {v}")
    # ---- lanes MK2 walks FURTHER than UMK3 laid them out.  UMK3 lowers a
    # guard by playing a_block backwards; MK2's do_unblock_hi takes the lane's
    # PART TWO - and her a_block has none, so find_ani_part2 ran off its end
    # into the next lane in ROM, a_lokick: she "low kicked" every time Block
    # was let go.  Same shape for the duck block (it ran into a_duck_punch),
    # the knockdown's part three (the shake on the ground) and the flip
    # kick's.  Each is rebuilt from her own frames in MK2's shape (MKFN.ASM's
    # a_fnblockhi / a_fnduckblock / a_fnkdown / a_fnflipkick).
    flat = sorted((a, op) for ops in segs for a, op in ops)

    def parts_at(a):
        res, cur = [], []
        for x, op in flat:
            if x < a:
                continue
            if op[0] == "frame":
                cur.append(fname[op[1]])
            elif op[0] == "end":
                res.append(cur)
                cur = []
                if len(res) == 3:
                    break
            elif op[0] == "jump":
                break
        return res

    mk2_lanes = []
    for k, how in MK2_SHAPE.items():
        p = parts_at(t1[umk3_row(lia1, TABLE1[k])])
        if how == "block":                      # up | down
            parts = [p[0], p[0][-2::-1]]
        elif how == "duckblock":                # up | down, back into the crouch
            duck = parts_at(t1[lia1.index("a_duck")])[0][-1]
            parts = [p[0], p[0][-2::-1] + [duck]]
        elif how == "kdown":                    # fall | land | shake on the ground
            parts = [p[0], p[1], p[1] + p[1]]
        else:                                   # flipkick: out | back | back
            parts = [p[0], p[1], p[1]]
        mk2_lanes.append(f"sd_mk2_{k:02x}\t\t; {TABLE1[k]} in MK2's shape")
        for part in parts:
            mk2_lanes += [f"\t.long\t{f}" for f in part] + ["\t.long\t0"]
        mk2_lanes.append("")
    stance =[f for ops in segs for a, op in ops if a == t1[0] for f in [op[1]]][0]
    out += ["", "sindel_stance1\t\t; the frame Shang's morph lands on",
            "\t.long\t" + ",".join(by_addr[p]["name"] for p in lists[stance]) + ",0"]
    out += ["", "sindel_anitab2"]
    decoded = {a for ops in segs for a, _op in ops}
    for k in range(rip.TAB2_ROWS):
        nm = names["2"][k] if k < len(names["2"]) else ""
        if t2[k] in decoded:
            out.append(f"\t.long\t{lab[t2[k]]}\t; {k} - UMK3 {nm}")
        else:                 # ochar_ripped_anis: a table of MK3 fighters' lanes
            out.append(f"\t.long\t0\t\t; {k} - UMK3 {nm} (not a lane; MK3's ochars)")
    # lanes
    rowname = {}
    for t, k, a in rows:
        nm = names[t][k] if k < len(names[t]) else ""
        rowname.setdefault(a, []).append(f"table{t} {k:02x} {nm}")
    out += ["", "; --- her UMK3 lanes " + "-" * 50]
    for ops in segs:
        out.append("")
        for a, op in ops:
            if a in lab:
                out.append(f"{lab[a]}" + (f"\t\t; {', '.join(rowname[a])}" if a in rowname else ""))
            kind = op[0]
            if kind == "end":
                out.append("\t.long\t0")
            elif kind == "jump":
                if op[1] not in lab:
                    raise SystemExit(f"jump to {op[1]:08X} has no label")
                out.append(f"\t.long\tani_jump,{lab[op[1]]}")
            elif kind == "frame":
                out.append(f"\t.long\t{fname[op[1]]}")
            elif kind == "calla":
                out.append(f"\t.long\tani_calla,{op[1]}")
            elif kind == "sladd":
                out.append(f"\t.long\tani_sladd,{fname[op[1]]}")
            else:
                _c, v, args = op
                out.append(f"\t.long\t{CMD[v]}")
                if args:
                    out.append("\t.word\t" + ",".join(str(x) for x in args))
    out += ["", "; --- lanes re-cut to MK2's parts " + "-" * 36] + mk2_lanes
    out += ["", "; --- her frame lists " + "-" * 48]
    for f in sorted(lists, key=lambda f: fname[f]):
        out.append(f"{fname[f]}\t.long\t" + ",".join(by_addr[p]["name"] for p in lists[f]) + ",0")
    for nm in sorted(extra):
        if "sd_" + nm not in have:
            out.append(f"sd_{nm}\t.long\t" + ",".join(extra[nm]) + ",0")
    out += ["", "; --- Kitana's MK2 THROWN lanes, Sindel's frames " + "-" * 21] + kt_thrown
    out += ["", "; --- Kitana's MK2 fatality-victim lanes (Kitana's art) " + "-" * 13] + kt_other
    out += ["", "; --- headers of the Kitana records those lanes draw (local to MKFN, so",
            ";     copied; no palette .long - drawn in Sindel's costume palette)",
            "\t.data"] + copied + ["\t.text"]
    out += strike_table()
    out += ["", "; --- MK3's routines her lanes call " + "-" * 34,
            "sd_new_float_ani\t\t; MK3 new_float_ani (MKLIA.ASM)",
            "\tclr\ta0",
            "\tmove\ta0,*a13(p_store3),l",
            "\tmovk\t6,a0",
            "\tmove\ta0,*a13(p_anirate),w\t; (16) in MK2",
            "\trets",
            "",
            "sd_slave_inviso\t\t\t; MK3 slave_inviso (MKUTIL.ASM)",
            "\tmove\t*a13(p_slave),a0,l\t; MK2's set_inviso takes the object in a0",
            "\tjreq\tsdsi9\t\t\t;   (MK3's took a8)",
            "\tcalla\tset_inviso",
            "sdsi9\trets",
            "",
            "sd_slave_viso\t\t\t; MK3 slave_viso - m_inviso cleared by hand:",
            "\tmove\t*a13(p_slave),a1,l\t; clear_inviso turns m_shadow on for bank-1 art",
            "\tjreq\tsdsv9",
            "\tmove\t*a1(oflags2),a0,w",
            "\tandni\tm_inviso,a0",
            "\tmove\ta0,*a1(oflags2),w",
            "sdsv9\trets",
            ""]
    out.append("; --- her palettes (umk3.zip) " + "-" * 40)
    for _a, (nm, words) in named.items():
        if nm in shared:
            continue
        out.append(f"{nm}:")
        out.append(f"\t.word\t{len(words)}")
        for i in range(0, len(words), 8):
            out.append("\t.word\t" + ",".join(f"0{w:04x}h" for w in words[i:i + 8]))
    out += ["", "\t.endif", "\t.end", ""]
    return "\n".join(out), subs, len(segs), len(lists)


def strike_table():
    mk2 = sna.stk_records((ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1"))
    mk3 = sna.stk_records((sny.MK3SRC / "MKSTK.ASM").read_text(errors="replace"))
    src = (ROOT / "src" / "MKSTK.ASM").read_text(encoding="latin-1").splitlines()
    i = next(k for k, ln in enumerate(src) if ln.startswith("fn_strikes"))
    fn_rows = []
    for ln in src[i + 1:]:
        m = re.match(r"^\s*\.long\s+(\w+)", ln)
        if not m:
            break
        fn_rows.append(m.group(1))

    def rec(geo_from, rest_from, keep_damage=True):
        g = [sna.hexfix(x) for x in mk3[geo_from][:4]]
        r = mk2[rest_from]
        return g + [r[4], (r[5] if keep_damage else sna.hexfix(mk3[geo_from][5]))] + r[6:]

    out = ["", "; --- her strike table: Kitana's layout, MK3's boxes " + "-" * 17,
           "sindel_strikes"]
    recs = []
    for k, lb in enumerate(fn_rows):
        if k < len(MK3_NORMALS):
            body = rec("stk_li_" + MK3_NORMALS[k], lb)
            note = f"MK3 stk_li_{MK3_NORMALS[k]} box, Kitana's {lb} rest"
        else:
            body = mk2[lb]
            note = f"Kitana's {lb} (not hers)"
        out.append(f"\t.long\tsd_stk_{k:02x}\t; {k:02x} - {note}")
        recs.append((f"sd_stk_{k:02x}", body))
    for k, m3, m2 in SPECIALS:
        if k != len(recs):
            raise SystemExit(f"her special stk {k:02x} is not the next row ({len(recs):02x})")
        out.append(f"\t.long\tsd_stk_{k:02x}\t; {k:02x} - MK3 {m3}, {m2}'s reaction")
        body = rec(m3, m2, keep_damage=False)
        if k == 0x1B:
            # the scream: react_to_fn row 1bh (r_sd_scream, Wolf only -
            # MKREACT.ASM), blocked like Kitana's fans; no damage (MK3's 0000)
            body[4] = "\t.word\t01b10h\t\t; hit -> react_to_fn 1bh r_sd_scream, block as the fans"
        recs.append((f"sd_stk_{k:02x}", body))
    for lb, body in recs:
        out += ["", lb] + body
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text, subs, nseg, nlist = build()
    print(f"UMK3SDL.ASM: {text.count(chr(10))} lines; {nseg} lane segments, {nlist} frame "
          f"lists; {subs} thrown frames made Sindel's")
    if a.apply:
        OUT.write_text(text, encoding="latin-1", newline="\r\n")
        print(f"wrote {OUT.relative_to(ROOT)}")
    if a.check:
        if not OUT.exists() or OUT.read_text(encoding="latin-1") != text:
            raise SystemExit(f"{OUT.relative_to(ROOT)} is stale - rerun tools/make_umk3sindel_asm.py --apply")
        print("UMK3SDL.ASM is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
