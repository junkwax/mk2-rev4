#!/usr/bin/env python3
"""The action code must arrive in the register the routine reads it from.

Some routines take the caller's action code in a register and make writing it to
p_action their first act - drone_duck_act is `move a1,*a13(p_action),w`. A caller that
loads the code into a DIFFERENT register writes garbage into p_action, and p_action is
not bookkeeping: is_he_blocking answers a drone off it alone, is_he_attacking tests its
category. That is av_shoruken (MKDRONE.ASM), Midway's own bug, fixed as drnshoru: it put
act_blocklo in A0, wrote p_action itself, then called drone_duck_act - which overwrote it
from A1 with the ATTACKER's act_shoruken, so the drone ducked a shoruken and ate it clean.

This finds every routine that takes its action that way (following wrappers that pass the
register straight through, like zap_init_special_act), then walks back from every call
and every fall-through into one:

  FLAG     the register is never set in the block, but ANOTHER register gets an act_*
           constant - the av_shoruken shape
  UNKNOWN  the walk hit a label, a call or the start of the block first; read it by hand
  OK       the register is written before the call

Validated 2026-09-29 against the retail tree (mk2-readonly), where it flags exactly one
site, av_shoruken; on this tree it flags none. The compiled-out `.else` of a .if is scanned
too, which is harmless: a fixed site's retail branch writes a0 AND the live branch writes
a1, and the walk finds a1.

  python tools/check_action_register.py            # report
  python tools/check_action_register.py --check    # exit 1 on any FLAG
  python tools/check_action_register.py --root DIR # another tree (e.g. mk2-readonly)
"""
import argparse
import glob
import os
import re
import sys

REG = re.compile(r'^a(\d{1,2})$', re.I)
LABEL = re.compile(r'^([A-Za-z_]\w*)\b')
UNCOND = {'jruc', 'jauc', 'jump', 'rets', 'retp', 'reti', 'sucide', 'trap'}
CALLS = {'jsrp', 'callr', 'calla'}
WRITERS = {'movi', 'movk', 'move', 'clr', 'not', 'neg', 'addi', 'addk', 'subi', 'subk', 'add',
           'sub', 'sll', 'srl', 'sra', 'andi', 'ori', 'xori', 'and', 'or', 'xor', 'abs', 'inc',
           'dec', 'mpys', 'mpyu', 'sext', 'zext', 'movb', 'exgpc', 'rl'}
UNARY = {'clr', 'not', 'neg', 'abs', 'inc', 'dec', 'sext', 'zext'}


def parse(line):
    s = line.split(';')[0]
    if not s.strip() or s.startswith('*') or s.lstrip().startswith('*'):
        return None
    m = LABEL.match(s)
    lab = m.group(1) if m else None
    parts = (s[m.end():] if m else s).split()
    if not parts:
        return (lab, None, [])
    ops = [o.strip() for o in " ".join(parts[1:]).split(',')] if len(parts) > 1 else []
    return (lab, parts[0].lower(), ops)


def writes(op, ops):
    if op in WRITERS:
        if op in UNARY and ops:
            d = ops[0]
        elif len(ops) >= 2:
            d = ops[1]
        else:
            d = ops[0] if ops else ''
        return {d.lower()} if REG.match(d) else set()
    if op in ('mmfm', 'pullp', 'pull'):
        return {o.lower() for o in ops if REG.match(o)}
    return set()


def load(root):
    code = {}
    for f in sorted(glob.glob(os.path.join(root, 'src', '*.ASM'))):
        lines = open(f, encoding='latin-1').read().splitlines()
        code[os.path.relpath(f, root)] = [(i + 1, parse(l)) for i, l in enumerate(lines)]
    return code


def find_takers(code):
    """label -> (file, line, register it reads the action from); wrappers to a fixpoint"""
    takes, forwards = {}, {}
    for f, L in code.items():
        for k, (ln, ins) in enumerate(L):
            if not ins or not ins[0]:
                continue
            lab, written, steps = ins[0], set(), 0
            for j in range(k, min(k + 12, len(L))):
                insj = L[j][1]
                if not insj:
                    continue
                if insj[0] and j != k:
                    break
                op, ops = insj[1], insj[2]
                if not op:
                    continue
                if op == 'move' and len(ops) >= 2 and 'p_action' in ops[1] and REG.match(ops[0]):
                    if ops[0].lower() not in written:
                        takes[lab] = (f, ln, ops[0].lower())
                    break
                if op in CALLS or op in ('jauc', 'jruc'):
                    if ops and not written:
                        forwards[lab] = (f, ln, ops[0])
                    break
                if op in UNCOND:
                    break
                written |= writes(op, ops)
                steps += 1
                if steps >= 4:
                    break
    changed = True
    while changed:                      # a routine that only forwards to a taker takes too
        changed = False
        for lab, (f, ln, tgt) in forwards.items():
            if lab not in takes and tgt in takes:
                takes[lab] = (f, ln, takes[tgt][2])
                changed = True
    return takes


def walk_back(L, k, reg):
    other, n = None, 0
    for j in range(k - 1, -1, -1):
        ins = L[j][1]
        if not ins:
            continue
        lab, op, ops = ins
        if op:
            if op in UNCOND:
                return ("UNKNOWN", "block starts after an unconditional branch", other)
            if op in CALLS:
                return ("UNKNOWN", "a call at line %d may set it" % L[j][0], other)
            if reg in writes(op, ops):
                return ("OK", "line %d: %s %s" % (L[j][0], op, ",".join(ops)), other)
            if op == 'movi' and len(ops) > 1 and 'act_' in ops[0].lower():
                other = other or "line %d: movi %s,%s" % (L[j][0], ops[0], ops[1])
            n += 1
            if n >= 14:
                return ("UNKNOWN", "no write within 14 instructions", other)
        if lab and n > 0:
            return ("UNKNOWN", "reached label " + lab, other)
    return ("UNKNOWN", "top of file", other)


def classify(res, where, v, d, oth):
    key = "FLAG" if (v == "UNKNOWN" and oth) else v
    res[key].append(where + ": " + d + ("  <-- but " + oth if oth else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    code = load(a.root)
    takes = find_takers(code)
    res = {"FLAG": [], "UNKNOWN": [], "OK": []}
    for f, L in code.items():
        for k, (ln, ins) in enumerate(L):
            if not ins:
                continue
            lab, op, ops = ins
            if lab in takes:            # fall-through INTO a taker from the line above
                for j in range(k - 1, -1, -1):
                    pj = L[j][1]
                    if pj and pj[1]:
                        if pj[1] not in UNCOND:
                            reg = takes[lab][2]
                            v, d, oth = walk_back(L, k, reg)
                            classify(res, "%s:%d  falls into %s (reads %s)" % (f, ln, lab, reg), v, d, oth)
                        break
            if not op or not ops or not (op in CALLS or op.startswith('j')):
                continue
            target = ops[-1] if ops[-1] in takes else (ops[0] if ops[0] in takes else None)
            if not target or target == lab:
                continue
            reg = takes[target][2]
            v, d, oth = walk_back(L, k, reg)
            classify(res, "%s:%d  %s %s (reads %s)" % (f, ln, op, target, reg), v, d, oth)
    print("routines that take their action in a register:")
    for lab, (f, ln, r) in sorted(takes.items()):
        print("  %-26s %s   %s:%d" % (lab, r, f, ln))
    for key in ("FLAG", "UNKNOWN"):
        print("%s: %d" % (key, len(res[key])))
        for x in res[key]:
            print("  " + x)
    print("OK: %d" % len(res["OK"]))
    if a.check and res["FLAG"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
