#!/usr/bin/env python3
"""Append one row to every char-indexed table, for a NEW fighter id.

Adding a character means every table indexed by `ochar` grows by one row.
Miss one and the new fighter reads past the end - a garbage code address
(wild jump / illegal-opcode lockup) or a garbage number handed to prcslp.
That whole failure class is documented in tools/audit_char_tables.py and in
the Jade(16) crash it shipped as.

This is the mechanical half of adding a fighter: it copies an EXISTING row
into a new last row, so the new character behaves exactly like the fighter it
is modelled on until something is deliberately changed.  Ermac (17) copies
Reptile (9) - he shares the ninja body, Reptile's stance, and is unlocked off
Reptile at the select screen.

    python tools/add_char_row.py --check              # report only
    python tools/add_char_row.py --from-row 9 --apply # do it

The table list is imported from audit_char_tables so the two can never drift.
Gated-safe short tables (baby combos) are skipped: their dispatch
is guarded by `cmpi 12,ochar / jrhs`, so a new row would silently GIVE the new
fighter a finisher rather than prevent a crash.
"""
import argparse
import ast
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")


def _audit_constants():
    """Pull TABLES / WORD_TABLES / GATED_SAFE out of audit_char_tables.py
    WITHOUT importing it - that module is a script and raises SystemExit at
    import time (it audits and exits).  Reading the literals keeps the two
    tools sharing one list, which is the point."""
    path = os.path.join(HERE, "audit_char_tables.py")
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), path)
    want = {"TABLES", "WORD_TABLES", "GATED_SAFE", "PAIR_TABLES"}
    got = {}

    def literal(v):
        """`\"\"\"...\"\"\".split()`, `set(...)`, or a plain dict/list literal."""
        if isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) \
                and v.func.attr == "split":
            return ast.literal_eval(v.func.value).split()
        if isinstance(v, ast.Call) and isinstance(v.func, ast.Name) \
                and v.func.id == "set":
            return set(literal(v.args[0]))
        return ast.literal_eval(v)

    for node in tree.body:
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name) and tgt.id in want:
                    got[tgt.id] = literal(node.value)
        # the audit extends its own lists with `TABLES += """...""".split()`
        elif isinstance(node, ast.AugAssign) and isinstance(node.op, ast.Add) \
                and isinstance(node.target, ast.Name) and node.target.id in want:
            got[node.target.id] = list(got.get(node.target.id, [])) \
                + list(literal(node.value))
    missing = want - set(got)
    if missing:
        raise SystemExit("could not read %s from audit_char_tables.py"
                         % ", ".join(sorted(missing)))
    return (got["TABLES"], got["WORD_TABLES"], got["GATED_SAFE"],
            got["PAIR_TABLES"])


TABLES, WORD_TABLES, GATED_SAFE, PAIR_TABLES = _audit_constants()

DATA = re.compile(r"^(\s*)\.(long|word)\s+(.*?)(\s*;.*)?$")


def load_files():
    out = {}
    for p in glob.glob(os.path.join(SRC, "*.ASM")):
        with open(p, encoding="latin-1") as f:
            out[p] = f.readlines()
    return out


def find_label(files, name):
    for p, lines in files.items():
        for i, ln in enumerate(lines):
            if ln[:1] not in (" ", "\t") and re.match(
                    r"^%s\b" % re.escape(name), ln):
                return p, i
    return None, None


def table_body(lines, start):
    """Return [(lineno, indent, kind, [values])] for the table's data lines."""
    body = []
    j = start + 1
    while j < len(lines):
        ln = lines[j]
        s = ln.strip()
        if not s or s.startswith(";") or s.startswith("*"):
            j += 1
            continue
        m = DATA.match(ln.rstrip("\n"))
        if m:
            vals = [v.strip() for v in m.group(3).split(",") if v.strip()]
            body.append((j, m.group(1), m.group(2), vals))
            j += 1
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\b", ln) and ln[0] not in " \t":
            break
        if re.match(r"^\s+(movi|move|calla|callr|jauc|jruc|jrc|rets|retp)\b", ln):
            break
        j += 1
    return body


def row_width(name, body):
    """Values per character row."""
    longs = sum(len(v) for _, _, k, v in body if k == "long")
    words = sum(len(v) for _, _, k, v in body if k == "word")
    if name in PAIR_TABLES:
        return 2, ("long" if longs >= words else "word")
    if name in WORD_TABLES:
        return 1, "word"
    if longs >= words:
        return 1, "long"
    return (2, "word") if words % 2 == 0 else (1, "word")


def process(name, files, from_row, new_row, apply_, comment):
    p, i = find_label(files, name)
    if p is None:
        return "label not found"
    lines = files[p]
    body = table_body(lines, i)
    if not body:
        return "no data lines"
    width, kind = row_width(name, body)
    flat = [(ln, v) for ln, _, k, vals in body if k == kind for v in vals]
    nrows, rem = divmod(len(flat), width)
    if rem:
        return "ragged: %d %ss is not a multiple of %d" % (len(flat), kind, width)
    if from_row >= nrows:
        return "source row %d out of range" % from_row
    src_vals = [v for _, v in flat[from_row * width:(from_row + 1) * width]]

    if nrows > new_row:
        # Table was already padded past the new id for some other reason
        # (the 21-row victim tables).  Row `new_row` exists - report what is
        # sitting there so it can be checked by hand rather than duplicated.
        cur = [v for _, v in flat[new_row * width:(new_row + 1) * width]]
        same = "same as row %d" % from_row if cur == src_vals else \
               "DIFFERS from row %d (%s)" % (from_row, ",".join(src_vals))
        return "already %d rows; row %d = %s - %s" % (
            nrows, new_row, ",".join(cur), same)
    if nrows != new_row:
        return "has %d rows, expected %d - unexpected shape" % (nrows, new_row)

    last_line = body[-1][0]
    indent = body[-1][1] or "\t"
    text = "%s.%s\t%s\t\t; %d - %s\n" % (
        indent, kind, ",".join(src_vals), new_row, comment)
    if apply_:
        lines.insert(last_line + 1, text)
    return "OK  +[%d] %s (copy of row %d)" % (new_row, ",".join(src_vals), from_row)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-row", type=int, default=9,
                    help="row to clone (default 9 = Reptile)")
    ap.add_argument("--new-row", type=int, default=17,
                    help="index the new row must land on (default 17 = Ermac)")
    ap.add_argument("--comment", default="ermac (clone of Reptile)")
    ap.add_argument("--apply", action="store_true", help="write the files")
    args = ap.parse_args()

    files = load_files()
    todo = [t for t in TABLES + WORD_TABLES if t not in GATED_SAFE]
    skipped = [t for t in TABLES + WORD_TABLES if t in GATED_SAFE]

    width = max(len(t) for t in todo)
    bad = 0
    for name in todo:
        msg = process(name, files, args.from_row, args.new_row, args.apply,
                      args.comment)
        if not msg.startswith("OK"):
            bad += 1
        print("%-*s  %s" % (width, name, msg))

    for name in skipped:
        print("%-*s  SKIPPED (gated: %s)" % (width, name, GATED_SAFE[name]))

    if args.apply:
        for p, lines in files.items():
            with open(p, "w", encoding="latin-1", newline="") as f:
                f.writelines(lines)
        print("\nwritten.")
    else:
        print("\n(dry run - pass --apply to write)")
    print("%d table(s) need attention" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
