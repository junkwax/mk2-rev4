#!/usr/bin/env python3
"""Audit MKDRONE.ASM's reaction tables against the live act_* equates.

Every move ever added to this game has arrived with no counter_*_table entry,
because nothing forced the author to add one.  The drone then silently does not
react to that move at all -- the "computer is not registering it" bug class that
has now been fixed by hand three separate times (pass 1: the back+HP punches,
pass 2: the air projectiles, pass 8: our own Jade/Noob content).

Two distinct failures, and the second is worse:

  HOLE  the action id lands inside the table but the entry is `.long 0`.
        The drone skips the reaction.  Bad, but contained.

  OOB   the action id lands PAST THE END of the table.  The lookup reads
        whatever `.long` happens to follow it in the source and jumps there.
        Every occurrence so far has been harmless purely by luck -- the next
        table happened to start with a 0.

Actions the game never stores, and actions that are deliberately left without a
reaction, are both fine; the deliberate ones are declared in EXPECTED_SILENT
below with the reason, so "no reaction" stays a decision rather than an
oversight.

Usage:
    python tools/audit_drone_tables.py            # report
    python tools/audit_drone_tables.py --check    # exit 1 on any finding
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"


def set_src(path: Path) -> None:
    """Point the audit at a different source tree (used to test the audit)."""
    global SRC
    SRC = path

# catagory_table maps action>>8 to one of these.  Keep in step with MKDRONE.ASM.
CATEGORY_TABLES = {
    0x0: "counter_proj_table",
    0x1: "counter_attack_table",
    0x2: "counter_propell",
    0x3: "counter_non_attack",
    0x4: "counter_specific",
    0x6: "counter_sitting_duck",
}

# Categories with a `.long 0` in catagory_table: no reaction to ANY action in
# them, by design.  5 = dead/reacting/pit-fall, 7 = the other guy is blocking.
CATEGORY_SILENT = {
    0x5: "category 5 is dead/reacting/being-thrown -- nothing to answer",
    0x7: "category 7 is 'he is blocking' -- handled by the throw gate instead",
}

# Deliberate holes.  A live action with no handler is a bug UNLESS it is here.
# The point of this list is that "the drone ignores this move" has to be a
# decision somebody wrote down, not something nobody noticed.
EXPECTED_SILENT = {
    # --- equates that exist but nothing ever stores ---
    "act_jc_ceiling": "equate exists but nothing ever stores it",
    "act_square": "equate exists but nothing ever stores it",
    "act_sa_swordkick": "do_sa_swordkick falls through into do_sa_leggrab, which stamps 124",
    "act_walkf": "declared but never stored -- the game only compares against it",
    "act_walkb": "declared but never stored -- the game only compares against it",
    "act_stunned": "MKCANNED only -- a demo/canned-sequence state, not something a player produces",

    # --- already caught by the time we could see it ---
    "act_backbreak": "MKSLAM stamps it after takeover_him_sr -- we are already grabbed",
    "act_rope_pull": "we are the one being dragged in by the spear; nothing to answer",
    "act_shocker": "raiden's shocker needs contact first, so seeing it means we are already held "
                   "(the recovery IS handled, at act_shocker_sd 615)",

    # --- neutral states: reacting to these means reacting to everything ---
    "act_backup": "standing up out of a crouch is not a threat; reacting here would interrupt "
                  "the stalk loop constantly",
    "act_duck": "turtling is answered positionally by close_he_is_ducking, not by a beware reaction",
    "act_stance": "idle. a drone that 'reacts' to the idle animation never finishes a walk",
    "act_postattack": "generic recovery; the throw gate and the 06xx whiff-punish handlers own it",

    # --- our own hit reaction on him, or a scripted sequence ---
    "act_balled": "that is him in OUR splits-punch reaction; pressure is already the sitting-duck path",
    "act_super_froze": "deep-freeze fatality state; attacking into it steps on the death sequence",
    "act_pre_shatter": "fatality sequence state (MKDEATH)",
    "act_hat_killer": "kung lao decap fatality state (MKDEATH)",
    "act_psycho_goro": "boss script state (MKBOSS)",
}

# Modules that only ever COMPARE against an action rather than store it, plus
# the drone itself (whose references are the reaction tables we are auditing).
NON_STORING = {"MAINEQU.ASM", "MKDRONE.ASM"}

ACT_RE = re.compile(r"^(act_[a-z0-9_]+)\s+\.set\s+([0-9a-fA-F]+)h\b", re.M)


def load_actions() -> dict[str, int]:
    text = (SRC / "MAINEQU.ASM").read_text(errors="replace")
    return {m.group(1): int(m.group(2), 16) for m in ACT_RE.finditer(text)}


def live_actions(actions: dict[str, int]) -> set[str]:
    """Actions some module other than MAINEQU/MKDRONE mentions -- i.e. real."""
    blob = {}
    for path in SRC.glob("*.ASM"):
        if path.name.upper() in NON_STORING:
            continue
        blob[path.name] = path.read_text(errors="replace")
    live = set()
    for name in actions:
        pat = re.compile(r"\b" + re.escape(name) + r"\b")
        if any(pat.search(text) for text in blob.values()):
            live.add(name)
    return live


def parse_table(text: str, label: str) -> list[str]:
    """Return the `.long` entries of a table, in order, as raw strings."""
    m = re.search(r"^" + re.escape(label) + r"\s*$", text, re.M)
    if not m:
        raise SystemExit(f"audit: table {label} not found in MKDRONE.ASM")
    entries: list[str] = []
    for line in text[m.end():].splitlines()[1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith(("*", ";")):
            continue
        lm = re.match(r"\.long\s+([^;*\s]+)", stripped)
        if not lm:
            break  # first non-.long line ends the table
        entries.append(lm.group(1))
    return entries


def parse_word_table(text: str, label: str) -> list[str]:
    """Return the `.word` entries of a one-per-line table, in order."""
    m = re.search(r"^" + re.escape(label) + r"\s*$", text, re.M)
    if not m:
        raise SystemExit(f"audit: table {label} not found in MKDRONE.ASM")
    entries: list[str] = []
    for line in text[m.end():].splitlines()[1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith(("*", ";")):
            continue
        wm = re.match(r"\.word\s+([^;*\s,]+)\s*(?:;.*)?$", stripped)
        if not wm:
            break
        entries.append(wm.group(1))
    return entries


def audit_punish_matrix(drone: str, sd_entries: list[str]) -> list[str]:
    """sd_punish_tier must line up 1:1 with counter_sitting_duck.

    Same bug class this file already exists to catch: a short table means
    drone_punish_sd indexes past the end, and sd_tier_max is a hand-kept
    .set that nothing else checks.  Both are cheap to verify and both would
    fail silently -- an over-long sd_tier_max reads garbage as a tier, a
    short one quietly routes every recovery down the default path.
    """
    problems: list[str] = []
    tiers = parse_word_table(drone, "sd_punish_tier")

    if len(tiers) != len(sd_entries):
        problems.append(
            f"  sd_punish_tier has {len(tiers)} rows, counter_sitting_duck has "
            f"{len(sd_entries)} -- they index the same actions and must match")

    m = re.search(r"^sd_tier_max\s+\.set\s+([0-9a-fA-F]+)h", drone, re.M)
    if not m:
        problems.append("  sd_tier_max .set not found (drone_punish_sd bounds-checks on it)")
    else:
        declared = int(m.group(1), 16)
        if declared != len(tiers) - 1:
            problems.append(
                f"  sd_tier_max is {declared:#x} but sd_punish_tier's last index is "
                f"{len(tiers) - 1:#x}")

    for i, t in enumerate(tiers):
        if t not in ("0", "1", "2", "3"):
            problems.append(f"  sd_punish_tier[{0x600 + i:#05x}] = {t!r} "
                            f"-- tiers are 0 (default) or 1/2/3")

    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if anything is wrong")
    ap.add_argument("--src", type=Path,
                    help="audit a different src/ tree (for testing the audit itself)")
    args = ap.parse_args()

    if args.src:
        set_src(args.src.resolve())

    actions = load_actions()
    live = live_actions(actions)
    drone = (SRC / "MKDRONE.ASM").read_text(errors="replace")
    tables = {name: parse_table(drone, name) for name in CATEGORY_TABLES.values()}

    oob: list[str] = []
    holes: list[str] = []
    silent_ok: list[str] = []

    for name, value in sorted(actions.items(), key=lambda kv: kv[1]):
        if name not in live:
            continue
        cat, idx = value >> 8, value & 0xFF
        if cat in CATEGORY_SILENT:
            continue
        table = CATEGORY_TABLES.get(cat)
        if table is None:
            oob.append(f"  {name:<20} {value:#05x}  category {cat:#x} has no table at all")
            continue
        entries = tables[table]
        if idx >= len(entries):
            oob.append(f"  {name:<20} {value:#05x}  index {idx} past end of "
                       f"{table} (len {len(entries)})")
        elif entries[idx] == "0":
            if name in EXPECTED_SILENT:
                silent_ok.append(f"  {name:<20} {value:#05x}  {EXPECTED_SILENT[name]}")
            else:
                holes.append(f"  {name:<20} {value:#05x}  {table}[{idx}] is .long 0 "
                             f"-- drone never reacts")

    matrix = audit_punish_matrix(drone, tables["counter_sitting_duck"])

    print("MKDRONE reaction-table audit")
    print(f"  {len(actions)} act_* equates, {len(live)} of them live\n")

    if matrix:
        print(f"PUNISH MATRIX ({len(matrix)}):")
        print("\n".join(matrix) + "\n")
    else:
        print("  punish matrix: sd_punish_tier lines up with counter_sitting_duck\n")

    if oob:
        print(f"OUT OF BOUNDS ({len(oob)}) -- lookup reads past the table:")
        print("\n".join(oob) + "\n")
    if holes:
        print(f"HOLES ({len(holes)}) -- live action with no reaction handler:")
        print("\n".join(holes) + "\n")
    if silent_ok:
        print(f"deliberately silent ({len(silent_ok)}):")
        print("\n".join(silent_ok) + "\n")

    if not oob and not holes and not matrix:
        print("PASS - every live action has a handler or a documented reason not to,")
        print("       and the punish matrix covers exactly the sitting-duck actions.")
        return 0

    print(f"FAIL - {len(oob)} out of bounds, {len(holes)} holes, "
          f"{len(matrix)} punish-matrix problems.")
    print("Add a c_* handler and wire it into the table, or add the action to")
    print("EXPECTED_SILENT in this script with the reason it needs no reaction.")
    return 1 if args.check else 0


if __name__ == "__main__":
    sys.exit(main())
