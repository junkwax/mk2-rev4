#!/usr/bin/env python3
"""make_fly_moves.py - every special and finisher in THIS build, for the fruit fly.

The fly's moves are innate (flyinv, MAINEQU.ASM): it does not enter a joystick
motion or press a button, it asks for a move by number and the ROM runs that
fighter's own handler with the pattern answered "matched" (combo_look_lr, MOVES.ASM).
So the fly needs to know, per fighter, which patterns exist and which switch
handler checks each one - and that has to come from the ROM source, not from a
hand-kept table: this build has reworked several movesets, and the rig's old
table asked for moves that no longer exist.

It walks each character's switch handlers (char_hi_punch .. char_lok_open in
MOVES.ASM), following branches inside MOVES.ASM, and records every
`movi scom_X,a11` / combo_look_lr check together with the routine the match
leads to (`movi do_Y,a7`).  Writes:

  src/FLYMOVES.ASM          fly_scoms (.long per pattern) + fly_scom_count,
                            .included at the end of MOVES.ASM (scom labels are local)
  tools/flybrain_moves.lua  per ochar: name, table index, switch, open, class, ranges

  python tools/make_fly_moves.py           # write both
  python tools/make_fly_moves.py --check   # fail if either is stale (Phase D)
  python tools/make_fly_moves.py --list    # print the catalogue
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
ASM_OUT = os.path.join(SRC, "FLYMOVES.ASM")
LUA_OUT = os.path.join(ROOT, "tools", "flybrain_moves.lua")

CHAR = {0: "KungLao", 1: "LiuKang", 2: "Cage", 3: "Baraka", 4: "Kitana", 5: "Mileena", 6: "Shang",
        7: "Raiden", 8: "SubZero", 9: "Reptile", 10: "Scorpion", 11: "Jax", 14: "Smoke", 15: "Noob",
        16: "Jade", 17: "Ermac", 18: "Khameleon", 19: "Rain"}
# switch_close_jumps order: 0 HP 1 LP 2 BLOCK 3 HK 4 LK 5 up 6 down 7 left 8 right
TABLES = [("char_hi_punch", 0, 0), ("char_lo_punch", 1, 0), ("char_block", 2, 0), ("char_hi_kick", 3, 0),
          ("char_lo_kick", 4, 0), ("char_joyup", 5, 0), ("char_joydown", 6, 0), ("char_joyleft", 7, 0),
          ("char_joyright", 8, 0), ("char_hip_open", 0, 1), ("char_lop_open", 1, 1),
          ("char_hik_open", 3, 1), ("char_lok_open", 4, 1)]
# branch targets that END a handler path - never walked into
STOP = {"restricted_xfer", "airborn_xfer", "death", "fatality_xfer_close", "fatality_xfer", "sucide",
        "charjmp", "combo_look_lr", "get_tsl", "update_tsl", "is_stick_away", "standing_special_ok"}

# BUTTON-SEQUENCE moves (button_look_lr on a bcom_ record): the ROM's fly service only forces a
# STICK pattern, so these are not invoked - the catalogue carries the sequence (`seq`, oldest
# first, read out of the record) and the rig presses it like a person.  Jade's staff impale
# also wants a Forward on the STICK between the third and fourth Block (jdi_forward_between),
# which no record holds, so its sequence is spelled out here.
SEQ_OVERRIDE = {"bcom_jade_impale": ["BL", "BL", "BL", "F", "BL"]}
SW_KEY = {"sw_block": "BL", "sw_hi_punch": "HP", "sw_lo_punch": "LP", "sw_hi_kick": "HK", "sw_lo_kick": "LK",
          "sw_up": "U", "sw_down": "D", "sw_left": "B", "sw_right": "F"}

FATAL_RE = re.compile(r"fatality|headrip|decap|do_drain|fatal_slam|headhole|toasty|umk3|kintaro_fatal|brain|lift_fatal")
# the approach distance each finisher lands from, measured by the rig (FATAL in flybrain_play.lua)
FIN_DIST = {"scom_hh_db1": 112, "scom_hh_db2": 272, "scom_lk_db1": 75, "scom_lk_db2": 180, "scom_jc_db1": 75,
            "scom_jc_db2": 55, "scom_sa_decap": 72, "scom_sa_stab": 80, "scom_fn1_db": 38, "scom_fn2_db": 74,
            "scom_st_db1": 75, "scom_st_decap": 75, "scom_st_soul_drain": 75, "scom_sz_db1": 144,
            "scom_sz_db2": 290, "scom_sz_headrip": 75, "scom_rp_db1": 208, "scom_rp_db2": 80,
            "scom_sc_toasty": 160, "scom_sc_db2": 80, "scom_sc_umk3": 80, "scom_jx_db1": 55,
            "scom_ermac_fatal": 140,
            # button sequences: fn1_hi_kick refuses past 048h, jx_hi_punch outside 045h..080h,
            # jade_block past jdi_maxdist 050h
            "bcom_fn1_db2": 55, "bcom_jx_db2": 95, "bcom_jade_impale": 60,
            "scom_jc_headhole": 65}   # jc_hi_punch refuses past 050h


def load(name):
    with open(os.path.join(SRC, name), errors="replace") as fh:
        return fh.read().split("\n")


EQU = {}
for _f in ("MAINEQU.ASM", "SYSEQU.ASM", "WUNIT.ASM", "MOVES.ASM"):  # WUNIT: wunit 0 = T-unit table
    for _line in load(_f):
        _m = re.match(r"^(\w+)\s+\.set\s+([0-9a-fA-F]+h?(?:\*\d+)?)", _line)
        if _m:
            EQU.setdefault(_m.group(1), _m.group(2))


def value(tok):
    """A handler's threshold operand: 040h*2, 022h, 96, or an equate like rd_lift_hold."""
    tok = EQU.get(tok, tok)
    total = 1
    for part in tok.split("*"):
        part = part.strip()
        n = int(part[:-1], 16) if part.lower().endswith("h") else int(part)
        total *= n
    return total


UNKNOWN_IF = set()


def assembled(lines):
    """The lines GSPA actually assembles: everything inside a false `.if <switch>` (or the
    other arm of its `.else`) becomes a comment line.  Without this the walk reads
    COMPILED-OUT handlers as live - it offered Noob's four shadow moves (noob_extras 0) and
    Kitana's spin chop (ktspin 0), so a fly that picked one asked for a move the ROM does not
    have and the learner scored the no-op.  A switch it cannot evaluate is taken as ON and
    reported by --list, so nothing disappears silently."""
    out, stack = [], []          # stack of (outer_live, this_arm_live)
    for line in lines:
        code = line.split(";")[0]
        m = re.match(r"^\s+\.if\s+(.+?)\s*$", code)
        if m:
            live = all(s[0] and s[1] for s in stack)
            try:
                cond = sum(value(t) for t in m.group(1).split("+")) != 0
            except ValueError:
                UNKNOWN_IF.add(m.group(1))
                cond = True
            stack.append((live, cond))
            out.append("*" + line)
            continue
        if re.match(r"^\s+\.else\b", code) and stack:
            stack[-1] = (stack[-1][0], not stack[-1][1])
            out.append("*" + line)
            continue
        if re.match(r"^\s+\.endif\b", code) and stack:
            stack.pop()
            out.append("*" + line)
            continue
        out.append(line if all(s[0] and s[1] for s in stack) else "*" + line)
    return out


M = assembled(load("MOVES.ASM"))
LAB = {}
for i, line in enumerate(M):
    m = re.match(r"^([A-Za-z_]\w*)\b", line)
    if m and not line.startswith("*"):
        LAB.setdefault(m.group(1), i)


def table(name):
    i, out = LAB[name] + 1, []
    while i < len(M) and len(out) < max(CHAR) + 1:   # one row per fighter id
        m = re.match(r"\s+\.long\s+(\w+)", M[i])
        if m:
            out.append(m.group(1))
        elif re.match(r"^\w", M[i]):
            break
        i += 1
    return out


def walk(label, seen, found, cur=None, depth=0):
    """Follow a handler through MOVES.ASM, recording (scom, target) pairs.

    Branches (j*) are followed; subroutine calls are not (they return).  A
    pattern that matched and then jumps somewhere before its `movi do_X,a7` is
    carried into that jump."""
    key = (label, cur)
    if key in seen or label not in LAB or label in STOP or depth > 16:
        return
    seen.add(key)
    for j in range(LAB[label], min(LAB[label] + 400, len(M))):
        line = "" if M[j].startswith("*") else M[j].split(";")[0]   # comments + compiled-out code
        if j > LAB[label] and re.match(r"^[A-Za-z_]\w*", M[j]) and not M[j].startswith("*"):
            walk(M[j].split()[0], seen, found, cur, depth + 1)       # fell through
            return
        m = re.search(r"movi\s+((?:scom|bcom)_\w+),a11", line)
        if m:
            cur = m.group(1)
        m = re.search(r"movi\s+(\w+),a7\b", line)
        if m and cur:
            found.append((cur, m.group(1)))
            cur = None
        m = re.search(r"\b(j[a-z]+)\s+(\w+)\s*$", line.strip())
        if m and m.group(2) not in STOP and m.group(2) in LAB:
            # a conditional branch taken right after a combo check is its NO path
            walk(m.group(2), seen, found, cur if m.group(1) in ("jruc", "jauc") else None, depth + 1)
        if re.search(r"\b(jruc|jauc)\s+\w+|^\s*(die|rets)\b", line):
            return


def bcom_seq(label):
    """A bcom_ record's presses, oldest first (the record is newest first, facing right)."""
    if label in SEQ_OVERRIDE:
        return SEQ_OVERRIDE[label]
    out = []
    for j in range(LAB[label] + 2, LAB[label] + 9):
        m = re.match(r"\s+\.word\s+(\w+)", M[j])
        if not m or m.group(1) == "0":
            break
        out.append(SW_KEY[m.group(1)])
    return out[::-1]


def charge_target(handler):
    """(do_X, min ticks since the press) of a release handler with no pattern.

    The hold is every `cmpi N,a1 / jrlo death` that follows a get_tsl before the
    target - the largest one is how long the button must go unused."""
    if handler not in LAB:
        return None, 0
    hold, after_tsl = 0, False
    for j in range(LAB[handler], min(LAB[handler] + 60, len(M))):
        if j > LAB[handler] and re.match(r"^[A-Za-z_]\w*", M[j]) and not M[j].startswith("*"):
            return None, 0
        line = "" if M[j].startswith("*") else M[j].split(";")[0]
        if re.search(r"calla\s+get_tsl\b", line):
            after_tsl = True
        m = re.search(r"cmpi\s+([\w*]+),a1\b", line)
        if m and after_tsl:
            try:
                hold = max(hold, value(m.group(1)))
            except ValueError:
                pass
            after_tsl = False
        m = re.search(r"movi\s+(do_\w+),a7\b", line)
        if m:
            return m.group(1), hold
    return None, 0


def catalogue():
    rows = {}
    for tname, sw, opn in TABLES:
        for ochar, handler in enumerate(table(tname)):
            if ochar not in CHAR or handler in ("sucide", "death"):
                continue
            found = []
            walk(handler, set(), found)
            for scom, target in found:
                rows.setdefault((ochar, scom, sw, target), dict(ochar=ochar, scom=scom, target=target, sw=sw,
                                                                open=opn))
            if opn and not found:
                # a CHARGE move: a release handler with no pattern (Raiden's two fatalities,
                # Mileena's sai).  It only checks how long ago the button was pressed - which
                # the fly never does - so asking for the release is the whole move.
                tgt, hold = charge_target(handler)
                if tgt:
                    rows[(ochar, None, sw, tgt)] = dict(ochar=ochar, scom=None, target=tgt, sw=sw, open=opn,
                                                         hold=hold)
    # patterns behind a range/stage check the walk may not see through
    extra = [(0, "scom_hh_dtp", 0, 0), (1, "scom_lk_dtp", 4, 0), (2, "scom_jc_dtp", 3, 0),
             (3, "scom_sa_dtp", 3, 0), (4, "scom_fn1_dtp", 3, 0), (5, "scom_fn2_dtp", 4, 0),
             (6, "scom_st_dtp", 6, 0), (7, "scom_rd_dtp", 0, 0), (8, "scom_nj_dtp", 2, 0),
             (9, "scom_nj_dtp", 2, 0), (10, "scom_nj_dtp", 2, 0), (11, "scom_jx_dtp", 4, 0),
             (17, "scom_nj_dtp", 2, 0), (10, "scom_sc_toasty", 0, 0), (10, "scom_sc_umk3", 3, 0),
             (15, "scom_noob_shadow", 4, 0), (15, "scom_noob_portal", 4, 0), (15, "scom_noob_tele", 5, 0)]
    have = {(r["ochar"], r["scom"]) for r in rows.values()}
    for ochar, scom, sw, opn in extra:
        if (ochar, scom) in have or not any(re.match(r"^" + scom + r"\b", l) for l in M):
            continue
        # a pattern only a compiled-out handler checks (Noob's shadow moves, noob_extras 0)
        # is not a move this ROM has, whatever record is still assembled
        if not any(re.search(r"movi\s+" + scom + r",a11", l) for l in M if not l.startswith("*")):
            continue
        rows[(ochar, scom, sw, "x")] = dict(ochar=ochar, scom=scom, sw=sw, open=opn,
                                            target="stage" if "dtp" in scom else "do_" + scom[5:])
    for r in rows.values():
        s, t = r["scom"] or "", r["target"]
        if "dtp" in s:
            r["cls"] = "stage"
        elif FATAL_RE.search(t) or s in FIN_DIST or "_db" in s:
            r["cls"] = "fatal"
        elif t.startswith("do_st_2_"):
            r["cls"] = "morph"
        else:
            r["cls"] = "special"
        r["name"] = "stage_fatality" if r["cls"] == "stage" else re.sub(r"^do_", "", t)
        r["dist"] = FIN_DIST.get(s) or {"stage": 50, "fatal": 75}.get(r["cls"])
    # a stage fatality found by the walk AND listed above keeps one entry
    out, seen = {}, set()
    for k, r in rows.items():
        sig = (r["ochar"], r["scom"], r["cls"]) if r["cls"] == "stage" else k
        if sig in seen:
            continue
        seen.add(sig)
        out[k] = r
    return out


def ranges(r):
    n = r["name"]
    if re.search(r"zap|throw|spit|proj|boomerang|lightning|ice$|spear|fan|square|wave|skull|orb|sai", n):
        return [2, 3]
    if re.search(r"noogy|shred|shoruken|scissor|floor_ice|tornado|headhole|spin|escape|helitest|leggrab", n):
        return [1, 2]
    return [1, 2, 3]


def outputs(rows):
    scoms = sorted({r["scom"] for r in rows.values() if r["scom"] and r["scom"].startswith("scom_")})
    idx = {s: i for i, s in enumerate(scoms)}
    asm = ["* FLYMOVES.ASM - GENERATED by tools/make_fly_moves.py.  Do not edit.",
           "* The fruit fly's pattern table (flyinv, MAINEQU.ASM).  .included at the end",
           "* of MOVES.ASM because the scom_ labels are local to it.", "",
           "fly_scom_count", "\t.long\t%d\t; read as a word" % len(scoms), "fly_scoms"]
    for s in scoms:
        asm.append("\t.long\t%s\t; %d" % (s, idx[s]))
    lua = ["-- flybrain_moves.lua - GENERATED by tools/make_fly_moves.py.  Do not edit.",
           "-- Per fighter (ochar): every special and finisher this build has, as the fly asks for it.",
           "-- idx = fly_scoms entry (FLYMOVES.ASM); 0xFFFD = a charge move, no pattern (run the",
           "-- release handler); sw = switch_close_jumps slot (0 HP 1 LP 2 BL 3 HK 4 LK 5 U 6 D 7 L",
           "-- 8 R); open = release handler; cls = special | fatal | stage | morph; r = range",
           "-- buckets (1 close, 2 mid, 3 far); d = approach distance for a finisher; hold = a",
           "-- charge move's ticks since that button was last used (its handler's get_tsl limit);",
           "-- seq = a BUTTON SEQUENCE (bcom_ record, idx 0xFFFC): not invoked, the rig presses",
           "-- these keys in order, oldest first.",
           "return {", "  count = %d," % len(scoms), "  moves = {"]
    by = {}
    for r in rows.values():
        by.setdefault(r["ochar"], []).append(r)
    for ochar in sorted(by):
        lua.append("    [%d] = {  -- %s" % (ochar, CHAR[ochar]))
        seen = set()
        for r in sorted(by[ochar], key=lambda r: (r["cls"], r["name"], r["sw"], r["scom"] or "")):
            name = r["name"]
            if name in seen:
                name = "%s_%s" % (name, (r["scom"] or "charge")[5:] if r["scom"] else "sw%d" % r["sw"])
            if name in seen:
                name = "%s_sw%d" % (name, r["sw"])
            seen.add(name)
            rg = "{ " + ", ".join(str(x) for x in ranges(r)) + " }"
            d = ", d = %d" % r["dist"] if r["dist"] else ""
            seq = bool(r["scom"]) and r["scom"].startswith("bcom_")
            if seq:
                d += ", seq = { %s }" % ", ".join('"%s"' % k for k in bcom_seq(r["scom"]))
            if r.get("hold"):
                d += ", hold = %d" % r["hold"]
            lua.append('      { name = "%s", idx = %d, sw = %d, open = %s, cls = "%s", r = %s%s },  -- %s'
                       % (name, 0xFFFC if seq else idx[r["scom"]] if r["scom"] else 0xFFFD, r["sw"],
                          "true" if r["open"] else "false", r["cls"], rg, d, r["scom"] or "charge"))
        lua.append("    },")
    lua += ["  },", "}", ""]
    return "\r\n".join(asm) + "\r\n", "\n".join(lua)


def main():
    rows = catalogue()
    asm, lua = outputs(rows)
    if "--list" in sys.argv:
        for r in sorted(rows.values(), key=lambda r: (r["ochar"], r["cls"], r["name"])):
            print("%-9s %-7s %-26s %-22s sw=%d open=%d %s" % (CHAR[r["ochar"]], r["cls"], r["name"],
                  r["scom"] or "(charge)", r["sw"], r["open"], r["dist"] or ""))
        for c in sorted(UNKNOWN_IF):
            print("NOTE: .if %s not evaluated - taken as ON" % c)
        return 0
    if "--check" in sys.argv:
        stale = [p for p, want in ((ASM_OUT, asm), (LUA_OUT, lua))
                 if not os.path.exists(p) or open(p, newline="").read() != want]
        for p in stale:
            print("STALE: %s - run python tools/make_fly_moves.py" % p)
        return 1 if stale else 0
    with open(ASM_OUT, "w", newline="") as fh:
        fh.write(asm)
    with open(LUA_OUT, "w", newline="") as fh:
        fh.write(lua)
    print("wrote %s and %s: %d patterns, %d moves" % (ASM_OUT, LUA_OUT, asm.count(".long"), len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
