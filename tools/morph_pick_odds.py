#!/usr/bin/env python3
"""How often the CPU Shang picks each form, computed exactly from the tables.

do_random_morph (MOVES.ASM) is a pure function of the opponent's ochar, the
difficulty and the habit hint: it draws `drone_morph_samples[diff]` candidates
uniformly from 0..11 and keeps the highest-scoring one, where

    score = matchup_odds[candidate][opponent] + morph_answers[hint][candidate]

Ties keep the one seen FIRST (`cmp a4,a6 / jrls drm_next` replaces only on a
strictly greater score, and a4 starts at 0), so the order of the draw matters
and the distribution is not simply "argmax". With at most 4 samples over 12
candidates that is 12^4 = 20736 orderings, so this enumerates them exactly
rather than sampling.

The reason it exists: `drone_unmorph` lets candidate 6 - Shang's own form -
survive the draw for the first time, and the question that needs answering is
whether "become myself" is a real answer or a dominant one.

    python tools/morph_pick_odds.py            # diff 9, no habit hint
    python tools/morph_pick_odds.py --diff 5 --hint 0
    python tools/morph_pick_odds.py --check    # fail if Shang's share is silly
"""

import argparse
import itertools
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOVES = ROOT / "src" / "MOVES.ASM"

NAMES = ["lao", "liu", "cage", "baraka", "kitana", "mileena",
         "shang", "raiden", "sub-zero", "reptile", "scorpion", "jax"]
HINTS = ["zones", "air", "floor", "poke", "uppercut", "specials", "turtle", "none"]

# Shang's own form is one of twelve. A share far above parity means the chart
# now says "just be yourself" and the morph stops being a mixup; far below
# means the column was written too timidly to matter. Parity is 1/12 = 8.3%.
SHANG_SHARE_MAX = 0.30
SHANG_SHARE_MIN = 0.01


def read_table(text, label, rows):
    """Pull `rows` consecutive .word lines following a label."""
    m = re.search(r"^%s\s*$" % re.escape(label), text, re.M)
    if not m:
        raise SystemExit("could not find %s in %s" % (label, MOVES))
    out = []
    for line in text[m.end():].splitlines():
        line = line.split(";")[0].strip()
        if not line:
            continue
        if not line.startswith(".word"):
            if out:
                break
            continue
        vals = [int(v.strip(), 0) for v in line[5:].split(",") if v.strip()]
        out.append(vals)
        if len(out) == rows:
            break
    if len(out) != rows:
        raise SystemExit("%s: expected %d rows, parsed %d" % (label, rows, len(out)))
    return out


def load():
    text = MOVES.read_text(encoding="latin-1")
    odds = read_table(text, "matchup_odds", 12)
    answers = read_table(text, "morph_answers", 8)
    m = re.search(r"^drone_morph_samples\s*$", text, re.M)
    samples = None
    for line in text[m.end():].splitlines():
        line = line.split(";")[0].strip()
        if line.startswith(".word"):
            samples = [int(v.strip(), 0) for v in line[5:].split(",") if v.strip()]
            break
    # Is candidate 6 remapped away?  Read the FLAG, not the code: the
    # baseline remap still sits in the file, inside an .else, so grepping for
    # `movk 5,a0` reports it present in both states.
    equ = (ROOT / "src" / "MAINEQU.ASM").read_text(encoding="latin-1")
    fm = re.search(r"^drone_unmorph\s+\.set\s+(\d+)", equ, re.M)
    if not fm:
        raise SystemExit("could not find drone_unmorph in MAINEQU.ASM")
    remapped = (int(fm.group(1)) == 0)
    return odds, answers, samples, remapped


def distribution(odds, answers, opponent, hint, n_samples, remap6):
    """Exact P(pick) over all n_samples-length draws, uniform with replacement."""
    score = []
    for cand in range(12):
        c = 5 if (remap6 and cand == 6) else cand
        score.append((c, odds[c][opponent] + answers[hint][c]))
    counts = [0] * 12
    total = 0
    for draw in itertools.product(range(12), repeat=n_samples):
        best_val, best_who = 0, 0
        for d in draw:
            who, val = score[d]
            if val > best_val:          # strictly greater: ties keep the first
                best_val, best_who = val, who
        counts[best_who] += 1
        total += 1
    return [c / total for c in counts]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diff", type=int, default=9)
    ap.add_argument("--hint", type=int, default=7, help="0-7, see HINTS (7 = none)")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    odds, answers, samples, remap6 = load()
    n = samples[args.diff]

    print("morph pick odds - diff %d (%d sample%s), hint '%s'%s"
          % (args.diff, n, "" if n == 1 else "s", HINTS[args.hint],
             "   [drone_unmorph OFF: 6 remapped to mileena]" if remap6 else ""))
    print()
    header = "opponent   " + "".join("%9s" % nm[:8] for nm in NAMES)
    print(header)
    print("-" * len(header))

    shang_shares = []
    for opp in range(12):
        dist = distribution(odds, answers, opp, args.hint, n, remap6)
        shang_shares.append(dist[6])
        row = "%-11s" % NAMES[opp]
        for i, p in enumerate(dist):
            cell = "  ." if p == 0 else "%8.1f%%" % (100 * p)
            if i == 6 and p > 0:
                cell = "%7.1f%%*" % (100 * p)
            row += "%9s" % cell.strip().rjust(8)
        print(row)

    print()
    print("* = Shang's own form.  Row = who he is fighting, column = who he becomes.")
    lo, hi = min(shang_shares), max(shang_shares)
    print("Shang picks himself: %.1f%% - %.1f%% (parity for 12 forms is 8.3%%)"
          % (100 * lo, 100 * hi))
    best = max(range(12), key=lambda i: shang_shares[i])
    worst = min(range(12), key=lambda i: shang_shares[i])
    print("  most against %s (%.1f%%), least against %s (%.1f%%)"
          % (NAMES[best], 100 * shang_shares[best], NAMES[worst], 100 * shang_shares[worst]))

    if args.check:
        if remap6:
            print("OK (drone_unmorph off - nothing to check)")
            return 0
        if hi > SHANG_SHARE_MAX:
            print("FAIL: Shang picks himself %.1f%% of the time against %s - "
                  "the morph stops being a mixup above %.0f%%"
                  % (100 * hi, NAMES[best], 100 * SHANG_SHARE_MAX))
            return 1
        if hi < SHANG_SHARE_MIN:
            print("FAIL: Shang never meaningfully picks himself (max %.2f%%) - "
                  "the sha column is too timid to matter" % (100 * hi))
            return 1
        print("OK: Shang's own form is a real but non-dominant answer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
