"""Did the fruit fly's special moves actually come out?

Reads the moves.csv files flybrain_play.lua writes (one row per attack it started: the
option, and every p_action code the fighter showed in the 45 frames after). A special is
counted LANDED when it produced an action code that the character's BASIC moves never
produce - so no hand-written table of which action belongs to which special is needed,
and nothing here depends on the game's move numbering.

It is conservative: a special whose action code also occurs after some basic move counts
as dropped. And it answers the question that matters for the ROM port - how many special
attempts does the joystick path lose, i.e. how much would triggering moves the way the CPU
does actually buy.

    python tools/flybrain_moves_report.py C:/tmp/flybrain/fly2          # every seg*/moves.csv
    python tools/flybrain_moves_report.py C:/tmp/flybrain/fly2/seg055   # one segment
"""
import collections
import csv
import glob
import os
import sys


def load(root):
    files = [os.path.join(root, "moves.csv")] if os.path.isfile(os.path.join(root, "moves.csv")) \
        else sorted(glob.glob(os.path.join(root, "seg*", "moves.csv")))
    rows = []
    for f in files:
        with open(f, newline="") as fh:
            rows += list(csv.DictReader(fh))
    return files, rows


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    files, rows = load(root)
    if not rows:
        sys.exit(f"no moves.csv under {root}")
    total = len(rows)
    # Judge only attacks pressed from a neutral stance (act_stance 0303, MAINEQU.ASM). One
    # pressed while an earlier move is still playing sees that move's action codes, and no
    # later test can untangle whose they were. Older logs have no `start` column: all rows.
    if "start" in rows[0]:
        rows = [r for r in rows if r["start"] == "0303"]
        print(f"judging {len(rows)} of {total} attacks - the ones pressed from a neutral stance")
        if not rows:
            sys.exit("no attacks started from a neutral stance")
    # A special's SIGNATURE is the action codes that follow it far more often than they
    # follow basic moves. Not "never after a basic": a move started while a special is still
    # playing inherits that special's code as carry-over (a jump-in pressed mid flying kick
    # shows act_superkang 0203), and a set-difference test then disqualifies the special's
    # own code - it reported Liu Kang's flying kick as 0 of 471 landed when it was landing.
    def acts_of(r):
        return {a for a in r["acts"].split(";") if a}

    seen = collections.defaultdict(lambda: [0, collections.Counter()])   # (char, opt|BASIC) -> [windows, code counts]
    for r in rows:
        key = (r["char"], r["opt"] if r["opt"].startswith("sp_") else "BASIC")
        seen[key][0] += 1
        seen[key][1].update(acts_of(r))

    def rate(key, code):
        n, c = seen[key]
        return c[code] / n if n else 0.0

    signature = {}
    for (ch, opt), (n, codes) in seen.items():
        if opt == "BASIC":
            continue
        signature[(ch, opt)] = {code for code in codes
                                if rate((ch, opt), code) >= 0.15 and rate((ch, opt), code) >= 4 * rate((ch, "BASIC"), code)}

    tally = collections.defaultdict(lambda: [0, 0])   # (char, special) -> [attempts, landed]
    for r in rows:
        if r["opt"].startswith("sp_"):
            t = tally[(r["char"], r["opt"][3:])]
            t[0] += 1
            t[1] += bool(acts_of(r) & signature[(r["char"], r["opt"])])
    print(f"{len(rows)} attacks from {len(files)} file(s); specials judged against each fighter's basic moves\n")
    print(f"{'fighter':10} {'special':18} {'tried':>6} {'landed':>7} {'rate':>6}  signature")
    tot = [0, 0]
    for (ch, sp), (n, ok) in sorted(tally.items()):
        sig = ",".join(sorted(signature[(ch, "sp_" + sp)])) or "(none - never seen to come out)"
        print(f"{ch:10} {sp:18} {n:6} {ok:7} {100 * ok / n:5.0f}%  {sig}")
        tot[0] += n; tot[1] += ok
    if tot[0]:
        print(f"\n{'ALL':29} {tot[0]:6} {tot[1]:7} {100 * tot[1] / tot[0]:5.0f}%")
        print(f"dropped: {tot[0] - tot[1]} special attempts the CPU-style trigger would have landed")


if __name__ == "__main__":
    main()
