#!/usr/bin/env python3
"""
Bump the MK2 version (major jump or revision bump) and commit.

Usage:
    python bump.py -m "Summary of changes"              # revision bump: 3.0-r17 → 3.0-r18
    python bump.py --major 3.3 -m "First 3.3 cut"       # major jump: 3.0-r17 → 3.3-r1
    python bump.py -m "Summary" --no-commit              # skip commit
    python bump.py                                       # opens editor for changelog

Files updated:
    src/DIAGMENU.ASM  — rom_name .string
    CHANGELOG.md      — new ## X.Y-rN — YYYY-MM-DD section
    README.md         — title line version
    AGENTS.md         — version + date line

ROM capacity validation:
    python bump.py --check                               # runs makerom.py + capacity check
    T-Unit limits: UJ12/UG12 ≤ 512KB each | video ≤ 1MB/chip | flat ≤ 1MB

Auto-commits with message: "Bump to X.Y-rN (summary)"
"""
import argparse
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO = Path(__file__).parent.resolve()

FILES = {
    "diagmenu":    REPO / "src" / "DIAGMENU.ASM",
    "changelog":   REPO / "CHANGELOG.md",
    "readme":      REPO / "README.md",
    "agents":      REPO / "AGENTS.md",
}

VERSION_RE = re.compile(r"(\d+)\.(\d+)-([mM][oO][dD]|[rR])(\d+)")


def get_editor():
    for var in ("VISUAL", "EDITOR"):
        v = subprocess.run(["git", "config", "--get", f"core.{var.lower()}"],
                           capture_output=True, text=True).stdout.strip()
        if v:
            return v
    import os
    for var in ("VISUAL", "EDITOR"):
        v = os.environ.get(var)
        if v:
            return v
    return "notepad" if sys.platform == "win32" else "nano"


def read_version():
    text = FILES["diagmenu"].read_text(encoding="utf-8", errors="replace")
    m = VERSION_RE.search(text)
    if not m:
        # Say what IS there.  The version moved to `REVISION 4.0-BETA (...)`,
        # which this tool cannot parse, so every run died on the line above
        # with a message that named only the shape it wanted - and the
        # changelog went four months and ~350 commits without an entry.
        # Naming the string that is actually in the file turns a dead end
        # into a decision.
        found = re.search(r'rom_name\s+\.string\s+"([^"]*)"', text)
        sys.exit(
            "Error: no 'X.Y-rN' version in DIAGMENU.ASM.\n"
            "  rom_name is currently: %s\n"
            "  bump.py only understands X.Y-rN / X.Y-modN. Either set\n"
            "  rom_name back to that shape, or teach VERSION_RE the new one\n"
            "  before the changelog drifts again."
            % (('"%s"' % found.group(1)) if found else "(not found)"))
    return int(m.group(1)), int(m.group(2)), int(m.group(4))


def ver_str(major, minor, rev, upper=False):
    r = "R" if upper else "r"
    return f"{major}.{minor}-{r}{rev}"


def bump_diagmenu(old_str, new_str):
    text = FILES["diagmenu"].read_text(encoding="utf-8", errors="replace")
    old_upper_r = f"SUDDEN_RECLINE {old_str.replace('-r','-R').upper()}"
    old_upper_mod = old_upper_r.replace("-R", "-MOD")
    new_upper = f"SUDDEN_RECLINE {new_str.replace('-r','-R').upper()}"
    if old_upper_r in text:
        old_key = old_upper_r
    elif old_upper_mod in text:
        old_key = old_upper_mod
    else:
        # Try to find any version string
        m = VERSION_RE.search(text)
        if m:
            found = text[m.start():m.end()]
            sys.exit(f"Error: found '{found}' but expected '{old_str}'")
        sys.exit(f"Error: ROM version string for {old_str} not found in DIAGMENU.ASM")
    text = text.replace(old_key, new_upper, 1)
    FILES["diagmenu"].write_text(text, encoding="utf-8", errors="replace")
    print(f"  {FILES['diagmenu'].name}: {old_key.split(' ')[-1]} -> {new_upper.split(' ')[-1]}")


def bump_changelog(major, minor, rev, description):
    today = date.today().isoformat()
    ver = ver_str(major, minor, rev)
    text = FILES["changelog"].read_text(encoding="utf-8", errors="replace")
    section = f"\n## {ver} \u2014 {today}\n\n{description.strip()}\n\n"

    # Find the preamble marker — handles both old modX and new rN forms
    for marker in ["numbered `X.Y-rN`", "numbered `3.0-rN`", "numbered `3.0-modX`"]:
        idx = text.find(marker)
        if idx != -1:
            break
    if idx == -1:
        sys.exit("Error: changelog preamble not found")

    idx = text.index("\n", idx)
    m = re.search(r"\n## \d", text)
    insert_at = m.start() if m else len(text)
    new_text = text[:insert_at] + section + text[insert_at:]

    # Normalize preamble to generic form on first transition from mod
    for old_marker, new_marker in [
        ("`3.0-modX`", "`X.Y-rN`"),
        ("`3.0-rN`", "`X.Y-rN`"),
    ]:
        if old_marker in new_text:
            new_text = new_text.replace(old_marker, new_marker)
            break
    new_text = new_text.replace("starting with mod0", "starting with r0")

    FILES["changelog"].write_text(new_text, encoding="utf-8", errors="replace")
    print(f"  {FILES['changelog'].name}: added {ver} section")


def bump_readme(old_str, new_str):
    text = FILES["readme"].read_text(encoding="utf-8", errors="replace")
    old_mod = old_str.replace("-r", "-mod")
    if old_str in text:
        text = text.replace(old_str, new_str)
    elif old_mod in text:
        text = text.replace(old_mod, new_str)
    else:
        print(f"  WARNING: {old_str} (or {old_mod}) not found in README.md")
        return
    FILES["readme"].write_text(text, encoding="utf-8", errors="replace")
    print(f"  {FILES['readme'].name}: -> {new_str}")


def bump_agents(major, minor, rev):
    text = FILES["agents"].read_text(encoding="utf-8", errors="replace")
    today = date.today().isoformat()
    new_ver = f"**{ver_str(major, minor, rev)}** ({today})"
    # Handles both **X.Y-rN** and **X.Y-modN** formats
    text = re.sub(
        r"\*\*\d+\.\d+-[mMrR][oOdD]?\d+\*\*\s*\(\d{4}-\d{2}-\d{2}\)",
        new_ver,
        text,
    )
    text = re.sub(r"all \d+ revisions", f"all {rev} revisions", text)
    FILES["agents"].write_text(text, encoding="utf-8", errors="replace")
    print(f"  {FILES['agents'].name}: -> {new_ver}")


def check_rom_capacity():
    """Run makerom.py and makevrom.py — both now self-validate against T-Unit limits."""
    print("=" * 56)
    print(" T-Unit ROM capacity check")
    print("=" * 56)

    ok = True
    for step, script in [
        ("Program ROMs", "makerom.py"),
        ("Video ROMs", "makevrom.py"),
    ]:
        path = REPO / script
        if not path.exists():
            print(f"SKIP: {script} not found")
            continue
        result = subprocess.run(
            [sys.executable, str(path)],
            cwd=str(REPO), capture_output=True, text=True,
        )
        print(result.stdout)
        if result.returncode != 0:
            print(f"FAIL: {step} returned exit code {result.returncode}")
            if result.stderr:
                print(result.stderr)
            ok = False

    if ok:
        print("ALL CAPACITY CHECKS PASSED — ROMs fit T-Unit board.")
    else:
        print("FAILED — some ROMs exceed T-Unit chip capacity.")
    return ok


def main():
    parser = argparse.ArgumentParser(description="Bump MK2 version")
    parser.add_argument("-m", "--message", help="Changelog entry text")
    parser.add_argument("--major", metavar="X.Y",
                        help="Set major version (e.g., 3.3) and reset revision to 1")
    parser.add_argument("--no-commit", action="store_true",
                        help="Update files but skip git commit")
    parser.add_argument("--summary", help="Short summary for commit message")
    parser.add_argument("--check", action="store_true",
                        help="Run makerom.py and validate T-Unit ROM capacities")
    args = parser.parse_args()

    if args.check:
        ok = check_rom_capacity()
        sys.exit(0 if ok else 1)

    major, minor, rev = read_version()
    old_str = ver_str(major, minor, rev)

    if args.major:
        parts = args.major.split(".")
        if len(parts) != 2:
            sys.exit("Error: --major must be X.Y format (e.g., 3.3)")
        try:
            major, minor = int(parts[0]), int(parts[1])
        except ValueError:
            sys.exit("Error: --major must be X.Y format with integers")
        rev = 1
    else:
        rev += 1

    new_str = ver_str(major, minor, rev)

    description = args.message
    if not description:
        editor = get_editor()
        import tempfile, os
        fd, tmpname = tempfile.mkstemp(suffix=".md", text=True)
        template = f"# Changelog entry for {new_str}\n#\n"
        with os.fdopen(fd, "w") as f:
            f.write(template)
        subprocess.run([editor, tmpname])
        with open(tmpname, "r") as f:
            description = f.read()
        os.unlink(tmpname)
        description = "\n".join(
            l for l in description.splitlines()
            if not l.strip().startswith("#")
        ).strip()
        if not description:
            sys.exit("Aborted: empty changelog entry.")

    summary = args.summary or description.splitlines()[0].strip().rstrip(".")
    label = "major jump" if args.major else "revision bump"
    print(f"Bumping {old_str} -> {new_str} ({label})")
    print(f"  Summary: {summary}")

    bump_diagmenu(old_str, new_str)
    bump_changelog(major, minor, rev, description)
    bump_readme(old_str, new_str)
    bump_agents(major, minor, rev)

    if args.no_commit:
        print(f"\n{label.capitalize()} complete (no commit). Run 'git commit' to finalize.")
        return

    commit_msg = f"Bump to {new_str} ({summary})"
    result = subprocess.run(
        ["git", "add",
         "src/DIAGMENU.ASM", "CHANGELOG.md", "README.md", "AGENTS.md"],
        cwd=str(REPO), capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Warning: git add failed: {result.stderr}")

    result = subprocess.run(
        ["git", "commit", "-m", commit_msg],
        cwd=str(REPO), capture_output=True, text=True,
    )
    if result.returncode == 0:
        print(f"\nCommitted: {commit_msg}")
    else:
        print(f"\nCommit failed: {result.stderr}")
        print("Files are updated \u2014 commit manually.")


if __name__ == "__main__":
    main()
