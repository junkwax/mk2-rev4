#!/usr/bin/env python3
"""Find drone reaction handlers that resume a STALE beware frame.

p_beware_return / p_beware_a10 / p_beware_a11 (MAINEQU.ASM) are one slot
each, and drone_beware is re-entrant: every animation loop in MKDRONE calls
it once a tick, including the loops a reaction handler runs.  So a handler
that walks in with `jsrp drone_approach` is running a loop that can dispatch
a SECOND reaction, and bew_fire overwrites all three slots when it does.

If that handler later exits through `return_to_beware`, it jumps to the
INNER loop's resume address instead of its own caller's - and that loop's
process-stack frame has already been popped.  Each extra pass through it
takes a frame that belongs to somebody else; when the stack empties, `retp`
reads the word above the process block (the next block's link) and jumps
into RAM.  That is TRAP 30, and the game parks in illegal_opcode's `jauc $`.

Reported from real play 2026-09-09, Reptile vs the Noob drone.

The fix at each site is to bracket the nested call:

    callr   save_beware_frame
    movi    048h,a11
    jsrp    drone_approach
    callr   restore_beware_frame

Run with --check in the build's Phase D.  Exit 1 = an unbracketed site.
"""
import argparse
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src" / "MKDRONE.ASM"

# Routines that run an animation loop containing a `drone_beware` call, so a
# `jsrp` to any of them can dispatch a reaction from underneath the caller.
# Derived from the `callr drone_beware` sites and their enclosing entry
# labels; keep it in step if a new bewaring loop is added.
# Derived by finding the entry label that owns each `callr drone_beware` site,
# not guessed.  Regenerate after adding a bewaring loop:
#   grep -n "callr\s*drone_beware" src/MKDRONE.ASM   then read back to the
#   nearest entry label.
BEWARING = {
    "drone_entry", "drone_stance_pause", "stance_wait_yes", "walk_wait_yes",
    "drone_stance_wait", "drone_ff_jsrp", "drone_beware_mframew",
    "drone_turnaround", "dbs_opp_abort", "drone_approach", "speedy_entry",
    "drone_retreat", "drone_stalk", "duck_sweep_go", "drone_jab_sweep",
    "drone_land", "drone_getup", "drone_backflip_jsrp",
}

JSRP = re.compile(r"^\s+jsrp\s+([A-Za-z_][A-Za-z0-9_]*)")
UNCOND = re.compile(r"^\s+(jruc|jauc|jump)\b")
SAVE = re.compile(r"^\s+callr?\s+save_beware_frame\b")
RESTORE = re.compile(r"^\s+callr?\s+restore_beware_frame\b")
RTB = re.compile(r"\breturn_to_beware\b")


def scan(lines):
    """Walk linearly.  A pending nested call is cleared by an unconditional
    jump (control cannot fall past it) or by a restore."""
    findings = []
    pending = None          # (line_no, callee, saved)
    for i, raw in enumerate(lines):
        line = raw.rstrip("\n")
        body = line.lstrip()
        if not body or body.startswith("*") or body.startswith(";"):
            continue
        if SAVE.match(line):
            pending = ("save", i)
            continue
        m = JSRP.match(line)
        if m and m.group(1) in BEWARING:
            saved = bool(pending and pending[0] == "save")
            pending = ("call", i, m.group(1), saved)
            continue
        if pending and pending[0] == "call":
            if RESTORE.match(line):
                pending = None
                continue
            if RTB.search(line):
                if not pending[3]:
                    findings.append((pending[1] + 1, pending[2], i + 1, body))
                continue
            if UNCOND.match(line):
                pending = None
        elif pending and pending[0] == "save":
            # a save with no bewaring jsrp right after it is pointless, but
            # harmless; drop it rather than carrying it forward
            if not JSRP.match(line):
                pending = None
    return findings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any unbracketed site is found")
    args = ap.parse_args()

    lines = SRC.read_text(encoding="latin-1").splitlines()
    findings = scan(lines)

    print(f"beware re-entry audit: {SRC.name}")
    if not findings:
        print("  OK - every return_to_beware after a bewaring jsrp is bracketed")
        return 0
    for call_line, callee, exit_line, text in findings:
        print(f"  MKDRONE.ASM:{call_line}  jsrp {callee}")
        print(f"    ...reaches return_to_beware at line {exit_line}: {text}")
        print("    -> bracket the jsrp with save_beware_frame/restore_beware_frame")
    print(f"FAIL - {len(findings)} unbracketed site(s)")
    return 1 if args.check else 0


if __name__ == "__main__":
    sys.exit(main())
