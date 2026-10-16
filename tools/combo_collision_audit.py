#!/usr/bin/env python
"""combo_collision_audit - which specials can now fire instead of each other.

`joyskip` (MAINEQU.ASM) lets each pattern step walk over stray queue entries,
which is what makes diagonals and sloppy input work. The cost is stated in
doc/FGC_INPUT_SPEC.md 2.3 and was never quantified: a pattern of [right,right]
now also matches [right, anything, right], so two specials sharing a prefix get
easier to confuse.

This turns that into a list of names.

THE MODEL, which is the matcher's and not a fresh interpretation of it:

  * A record's pattern is newest-first, terminated by 0 (combo_edit).
  * The walk starts at the newest queue entry and goes back. Each pattern step
    gets joyskip+1 tries, so it may consume 1..joyskip+1 entries.
  * Several commands can match the same input. Resolution is DECLARATION
    ORDER - each character's handler tries its motions in a fixed sequence and
    the first `combo_look_lr` that returns carry wins. There is no
    longest-match rule (INPUT_SPEC 4.4).

So the dangerous shape is: A and B are dispatched from the SAME handler, A is
tried FIRST, and A's pattern embeds in the entries B's own input produces.
Then performing B gives you A.

  retail (joyskip 0)  A must be a contiguous PREFIX of B - no skipping
  joyskip N           A may be embedded with up to N entries skipped per step

Only the second column is new, and only the second column is this tool's fault.

    python tools/combo_collision_audit.py
    python tools/combo_collision_audit.py --joyskip 4     what a wider value costs
    python tools/combo_collision_audit.py --all           include retail collisions
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import combo_edit as CE                                          # noqa: E402


def read_joyskip():
    """The shipping value, so the default report describes the real build."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "src", "MAINEQU.ASM")
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                m = re.match(r"^joyskip\s+\.set\s+(\d+)", line)
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return 0


def patterns(rec):
    """(right, left) as lists of sw_* names, newest-first, 0-terminated."""
    out = []
    for base in (1, 7):
        seq = []
        for raw in rec["words"][base:base + 6]:
            kind, val = CE.decode_word(raw)
            if kind == "number" and val == 0:
                break
            if kind == "label":
                seq.append(val)
            elif kind == "number":
                seq.append(CE.SW_INVERSE.get(val, str(val)))
            else:
                seq.append(str(val))
        out.append(seq)
    return out[0], out[1]


def embeds(a, b, skip):
    """Can pattern `a` be matched against the entries pattern `b` produces?

    Returns the number of entries skipped, or None. Greedy is exact here
    because both sequences are short and every step takes the nearest legal
    match - taking a later one can only make the next step harder.
    """
    if not a or not b or len(a) > len(b):
        return None
    i = total = 0
    for step, want in enumerate(a):
        # The first step is ANCHORED in the matcher - it must match the newest
        # entry - so the model has to anchor it too, or this reports
        # collisions the build cannot actually produce.
        allowed = 0 if step == 0 else skip
        for tries in range(allowed + 1):
            if i + tries < len(b) and b[i + tries] == want:
                total += tries
                i += tries + 1
                break
        else:
            return None
    return total


BLOCK = re.compile(r"^\s*movi\s+(scom_[A-Za-z0-9_]+)\s*,\s*a11\b", re.IGNORECASE)
LOOK = re.compile(r"^\s*callr\s+combo_look_lr\b", re.IGNORECASE)
FAIL = re.compile(r"^\s*jrnc\s+([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)
# A label is an identifier at COLUMN 0. It may carry an instruction on the
# same line - `sthp9<TAB>movi ...` is how half of this chain is written, and
# requiring the label to sit alone missed those, which silently cut Shang's
# skull chain in two and hid the worst collision in it. Instructions are
# always indented and directives start with a dot, so column 0 is decisive.
LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?=\s|$)")


# A handler ENTRY - the top of one fighter's dispatch for one button. Digits
# are deliberate: fn1_/fn2_ are Kitana and Mileena and a pattern of
# [a-z]{2,3} silently excludes them, which is the bug that made the first
# version of this audit report four collisions between different characters.
ENTRY = re.compile(
    r"^([A-Za-z][A-Za-z0-9]*_(?:hi_punch|lo_punch|hi_kick|lo_kick|block))"
    r"(?=\s|$)")


def entry_between(entries, path, lo, hi):
    return any(lo < n < hi for n in entries.get(path, ()))


def collect_chains(files, combos):
    """Group call sites by the chain that actually makes them compete.

    NOT by "nearest handler label", which is what combo_edit's parse_callers
    guesses and which is wrong here in two directions: its pattern is
    `[a-z]{2,3}_...`, so it does not recognise `fn1_lo_kick` or `fn2_lo_kick`
    at all (digits), and it does not recognise the `sthpN` labels the real
    chain is threaded through either. Both errors were live - the first
    attributed Kitana's and Mileena's call sites to a distant `lk_block` and
    invented four collisions between fighters who never share a dispatch.

    The real relation is written in the code:

        movi    scom_X,a11
        callr   combo_look_lr
        jrnc    <label>          ; X did not match - try what is at <label>

    So X competes with Y exactly when following X's failure branch arrives at
    Y. That is what this walks, and it is exact rather than heuristic.
    """
    labels, blocks, entries = {}, [], {}
    for path, lines in files.items():
        for idx, line in enumerate(lines, start=1):
            m = LABEL.match(line)
            if m:
                labels.setdefault((path, m.group(1)), idx)
            if ENTRY.match(line):
                entries.setdefault(path, []).append(idx)
        k = 0
        while k < len(lines):
            m = BLOCK.match(lines[k])
            if not m:
                k += 1
                continue
            label, look, target = m.group(1), False, None
            for probe in range(k + 1, min(k + 8, len(lines))):
                if LOOK.match(lines[probe]):
                    look = True
                    continue
                f = FAIL.match(lines[probe])
                if look and f:
                    target = f.group(1)
                    break
                if look and lines[probe].strip() and not lines[probe].strip().startswith((";", "*")):
                    break
            if look:
                blocks.append({"path": path, "line": k + 1, "label": label,
                               "target": target})
            k += 1

    blocks.sort(key=lambda b: (str(b["path"]), b["line"]))

    # chain id: a block joins the previous one when the previous block's
    # failure branch lands between them - i.e. "if that missed, try this".
    chains, cur = {}, 0
    prev = None
    for b in blocks:
        joined = False
        if prev is not None and prev["path"] == b["path"] and prev["target"]:
            at = labels.get((prev["path"], prev["target"]))
            if at is not None and prev["line"] < at <= b["line"]:
                joined = True
            # ...unless a HANDLER ENTRY sits between them. Landing inside the
            # next handler is not "try this next" - it is a different fighter's
            # dispatch entirely. Without this, Mileena's fn2_lo_kick chained
            # all the way into Kitana's fn1_lk_open and the audit invented a
            # collision between two characters who never share a chain.
            if joined and entry_between(entries, b["path"], prev["line"],
                                        b["line"]):
                joined = False
        if not joined:
            cur += 1
        b["chain"] = cur
        chains.setdefault(cur, []).append(b)
        prev = b

    sites, by_handler = [], {}
    for cid, group in chains.items():
        if len(group) < 2:
            continue                      # nothing to collide with
        name = "%s:%d" % (os.path.basename(str(group[0]["path"])),
                          group[0]["line"])
        for b in group:
            rec = combos.get(b["label"])
            if not rec:
                continue
            r, l = patterns(rec)
            if not r:
                continue
            s_ = {"label": b["label"], "handler": name, "line": b["line"],
                  "path": b["path"], "right": r, "left": l, "button": ""}
            sites.append(s_)
            by_handler.setdefault((b["path"], name), []).append(s_)
    return sites, by_handler


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--joyskip", type=int, default=None,
                    help="value to audit (default: what the build ships)")
    ap.add_argument("--all", action="store_true",
                    help="also list collisions that exist at joyskip 0")
    args = ap.parse_args()

    skip = args.joyskip if args.joyskip is not None else read_joyskip()

    files = CE.load_all()
    combos = CE.parse_combos(files)

    sites, by_handler = collect_chains(files, combos)

    print("COMMAND COLLISION AUDIT   joyskip = %d" % skip)
    print("A collision is: doing B gives you A, because A is tried first and")
    print("A's pattern fits inside the entries B's own input makes.\n")

    new_rows, old_rows = [], []
    for (path, handler), group in sorted(by_handler.items(),
                                         key=lambda kv: str(kv[0])):
        group.sort(key=lambda s: s["line"])
        for x, a in enumerate(group):
            for b in group[x + 1:]:                 # b is tried LATER than a
                if a["label"] == b["label"]:
                    continue
                for facing in ("right", "left"):
                    got = embeds(a[facing], b[facing], skip)
                    if got is None:
                        continue
                    base = embeds(a[facing], b[facing], 0)
                    row = (handler, a["label"], b["label"], facing, got,
                           " ".join(a[facing]), " ".join(b[facing]))
                    (old_rows if base is not None else new_rows).append(row)
                    break                            # one facing is enough

    def show(rows, title):
        print("%s (%d)" % (title, len(rows)))
        if not rows:
            print("  none\n")
            return
        print("  %-22s %-24s %-24s %s" % ("handler", "fires INSTEAD", "of", "skips"))
        print("  " + "-" * 78)
        for h, a, b, f, got, pa, pb in sorted(rows, key=lambda r: (r[4], r[0])):
            print("  %-22s %-24s %-24s %d" % (h[:22], a[:24], b[:24], got))
            print("  %-22s   %s" % ("", "%s  <=  %s" % (pa, pb)))
        print()

    show(new_rows, "NEW - introduced by joyskip")
    if args.all:
        show(old_rows, "PRE-EXISTING - already collide at joyskip 0")
    else:
        print("PRE-EXISTING (already collide at joyskip 0): %d  (--all to list)"
              % len(old_rows))

    print("\n%d call sites across %d handlers." % (len(sites), len(by_handler)))
    return 1 if new_rows else 0


if __name__ == "__main__":
    sys.exit(main())
