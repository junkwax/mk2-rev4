#!/usr/bin/env python3
"""
release_manifest.py - what a tournament organiser needs to verify a cabinet.

Section 7.2 of doc/TOURNAMENT_READINESS.md. `burnfix.py` already emits a
manifest for hardware EPROMs; this is the same idea for the distributed zip,
and it answers the question a bracket actually has to answer: **is every
station running the same game?**

Hashing the right thing matters here. `mamerom.py` finishes by calling
`crc_spoof.spoof_zip()`, which rewrites four bytes of padding in each program
chip so the CRC32 matches FBNeo's hardcoded table - so the files inside the zip
NEVER match `rom/*.bin`, and they change again on every repackage. The bytes a
player actually runs are the ones inside the zip, so those are what this
hashes.

It also records the RULESET, because that is the part a checksum cannot
explain. Two builds from the same commit with different switches produce
different ROMs and therefore different hashes - correct, but useless to a
human trying to work out *why* two cabinets disagree. The switch table and the
lock digests turn "these differ" into "these differ HERE".

  python tools/release_manifest.py                  -> rom/MANIFEST.txt
  python tools/release_manifest.py --zip path.zip
  python tools/release_manifest.py --check          verify a zip against it
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DEFAULT_ZIP = os.path.join(ROOT, "rom", "mk2.zip")
OUT = os.path.join(ROOT, "rom", "MANIFEST.txt")

SWITCHES = ["anchorcol", "stkphase", "perpiece", "hitbox", "combo_slack",
            "combo_slack_online", "dmgscale", "chipfloor", "secretwalk",
            "twobtn_slack", "twobtn_depth", "blockspecial", "firstactive"]


def read(p):
    return open(p, encoding="latin-1", errors="replace").read()


def switches():
    txt = read(os.path.join(SRC, "MAINEQU.ASM"))
    out = []
    for name in SWITCHES:
        m = re.search(r"^%s\s+\.set\s+(\S+)" % re.escape(name), txt, re.M)
        out.append((name, m.group(1).strip() if m else "MISSING"))
    return out


def lock_digest(name):
    p = os.path.join(ROOT, "doc", name)
    if not os.path.exists(p):
        return None
    m = re.search(r"^sha256 ([0-9a-f]+)", read(p), re.M)
    return m.group(1) if m else None


def git(*args):
    try:
        return subprocess.run(["git"] + list(args), cwd=ROOT, timeout=20,
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def zip_hashes(path):
    out = []
    with zipfile.ZipFile(path) as z:
        for name in sorted(z.namelist()):
            data = z.read(name)
            out.append((name, len(data), hashlib.sha256(data).hexdigest()))
    return out


def build(path):
    lines = []
    lines.append("MORTAL KOMBAT II - build manifest")
    lines.append("=" * 66)
    lines.append("")
    lines.append("Verify every cabinet in a bracket is running the same game.")
    lines.append("Compare the RULESET block first - if that matches and the")
    lines.append("hashes do not, the difference is art or sound, not play.")
    lines.append("")
    commit = git("rev-parse", "--short", "HEAD")
    dirty = git("status", "--porcelain")
    lines.append("source")
    lines.append("  commit          %s%s"
                 % (commit or "unknown",
                    "  (UNCOMMITTED CHANGES PRESENT)" if dirty else ""))
    lines.append("")
    lines.append("ruleset - what makes this build play the way it does")
    for name, val in switches():
        lines.append("  %-20s %s" % (name, val))
    lines.append("")
    lines.append("  see doc/DEVIATIONS.md for what each one changes and why")
    lines.append("")
    lines.append("locks")
    for f in ("balance.lock", "hurtbox.lock", "behaviour.lock"):
        d = lock_digest(f)
        lines.append("  %-16s %s" % (f, d or "absent"))
    lines.append("")
    lines.append("rom contents - sha256 of each file AS DISTRIBUTED")
    lines.append("  (these never match rom/*.bin: crc_spoof rewrites 4 bytes")
    lines.append("   of padding in each program chip on every repackage)")
    lines.append("")
    total = hashlib.sha256()
    for name, size, digest in zip_hashes(path):
        lines.append("  %-46s %8d  %s" % (name, size, digest[:32]))
        total.update(digest.encode())
    lines.append("")
    lines.append("  SET FINGERPRINT  %s" % total.hexdigest()[:32])
    lines.append("")
    lines.append("A cabinet matches if the SET FINGERPRINT matches. If it does")
    lines.append("not, the ruleset block above says whether it matters.")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=DEFAULT_ZIP)
    ap.add_argument("--check", action="store_true",
                    help="compare the zip against the committed manifest")
    args = ap.parse_args()

    if not os.path.exists(args.zip):
        print("no such zip: %s" % args.zip)
        sys.exit(1)

    fresh = build(args.zip)
    if args.check:
        if not os.path.exists(OUT):
            print("no manifest yet - run: python tools/release_manifest.py")
            sys.exit(1)
        have = open(OUT, encoding="utf-8", newline="").read()
        fp = re.search(r"SET FINGERPRINT\s+(\w+)", have)
        fp2 = re.search(r"SET FINGERPRINT\s+(\w+)", fresh)
        if fp and fp2 and fp.group(1) == fp2.group(1):
            print("  manifest OK - fingerprint %s" % fp.group(1))
            return
        print("ROM SET DIFFERS from the manifest")
        print("  manifest: %s" % (fp.group(1) if fp else "?"))
        print("  this zip: %s" % (fp2.group(1) if fp2 else "?"))
        sys.exit(1)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="") as fh:
        fh.write(fresh)
    print("wrote rom/MANIFEST.txt")
    print(re.search(r"SET FINGERPRINT.*", fresh).group(0).strip())


if __name__ == "__main__":
    main()
