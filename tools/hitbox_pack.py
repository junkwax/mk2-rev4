#!/usr/bin/env python3
"""
hitbox_pack.py - portable import / export for MK2 strike boxes.

The point of this file is that a hitbox change should be something you can
SEND SOMEONE. Not a screenshot of a diff, not "set x_offset to 180 on the
Liu Kang high kick" in a Discord message - a file, that another build can
read back exactly, argue with, and apply.

  python tools/hitbox_pack.py export                    -> hitbox_pack.json
  python tools/hitbox_pack.py export --format csv       -> a spreadsheet
  python tools/hitbox_pack.py export --public           -> no leaked symbols
  python tools/hitbox_pack.py diff  somepack.json       -> what it would change
  python tools/hitbox_pack.py validate somepack.json    -> is it well formed
  python tools/hitbox_pack.py import somepack.json --apply

WHAT A BOX ACTUALLY IS, because the field names in the ASM mislead:

  front   (x_offset) the FRONT edge - how far the box reaches from the
                     attacker's anipoint.  Bigger = more reach.
  width   (x_size)   extends BACKWARDS from `front`, toward the attacker.
                     It is not reach, and raising it does not lengthen a
                     move - it thickens it behind the tip.
  y       (y_offset) top edge, measured DOWN from the anipoint.
  height  (y_size)   downward from `y`.

  hit / block        damage.  One packed word in the ASM, 0x<hit><block>,
                     split here because nobody edits it packed.
  hit_reaction /     the strike routine word, likewise split: high byte is
  block_reaction     the reaction on hit, low byte the one on block.

REACH IS NOT RANGE.  `front` is where the box ends, not where the move
connects.  The victim is squeezed to a QUARTER of his sprite width before
the compare (sq_punch), centred on his anipoint, so a move connects out to
roughly front + victim_width/8 and no further.  Widening a box by 20 does
not buy 20px of range.  See doc/HITBOX_MODEL.md.

COPYRIGHT.  A pack holds numbers and names - no Midway code, no art, no
ROM.  --public additionally drops the symbol and sound fields, which are
the only things in a pack lifted from the leaked source, leaving ids this
tool resolves on its own.  That is what makes a pack publishable when the
source it came from is not.  See doc/COMMUNITY_PACKS.md.
"""
import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import hitbox_edit as HE                                    # noqa: E402

FORMAT = "mk2-hitbox-pack"
FORMAT_VERSION = 1
ASM = os.path.join(ROOT, "src", "MKSTK.ASM")

# pack field -> (asm field, signed)
BOX = [("front", "x_offset", True), ("y", "y_offset", True),
       ("width", "x_size", True), ("height", "y_size", True)]
CSV_COLUMNS = ["id", "character", "symbol", "front", "y", "width", "height",
               "hit", "block", "hit_reaction", "block_reaction", "score",
               "sound"]

SLUG = {"hh": "kung-lao", "lk": "liu-kang", "jc": "johnny-cage",
        "sa": "baraka", "fn": "kitana-mileena", "st": "shang-tsung",
        "rd": "raiden", "nj": "ninjas", "jx": "jax", "go": "goro-kintaro",
        "sk": "shao-kahn"}


class UnresolvedField(Exception):
    """A strike field that is not a number and could not be resolved to one.

    Raised instead of letting a None reach the bit-twiddling below, where it
    surfaced as a bare TypeError with nothing saying which record or field.
    hitbox_edit.parse_equates() handles the normal case (a named constant);
    this fires when the name is defined somewhere it is not allowed to look.
    """


def _need_int(v, label, field):
    if not isinstance(v, int):
        raise UnresolvedField(
            "%s.%s is %r, not a number.\n"
            "  A strike record may name a constant, but it must be defined in "
            "one of hitbox_edit.EQUATE_SOURCES (%s).\n"
            "  Either move the equate there or write the literal."
            % (label, field, v, ", ".join(HE.EQUATE_SOURCES)))
    return v


def _s16(v):
    v &= 0xffff
    return v - 0x10000 if v >= 0x8000 else v


def _u16(v):
    return v & 0xffff


def char_of(char_tables):
    """label -> (2-letter code, shared?).  Not every record belongs to one."""
    owner, seen = {}, {}
    for t in char_tables:
        for lbl in t["moves"]:
            seen.setdefault(lbl, []).append(t["name"])
    for lbl, chars in seen.items():
        owner[lbl] = (chars[0], len(chars) > 1)
    return owner


def make_id(label, code):
    """A neutral, stable id.  stk_lkhikick + lk -> liu-kang/hikick."""
    stem = label[4:] if label.startswith("stk_") else label
    if code and stem.startswith(code):
        stem = stem[len(code):]
    stem = stem.strip("_").replace("_", "-") or "unnamed"
    return "%s/%s" % (SLUG.get(code, "shared"), stem)


def alias_groups():
    """label -> the record label it is an alias OF.

    MKSTK.ASM stacks labels over one body - `stk_jczap1` through
    `stk_jczap4` are four names for a SINGLE record, and a parser that
    keys on the label credits only the last one.  Four moves then look
    like one, and three look like nothing at all.  A label is an alias
    when the next meaningful line is another label rather than a field.
    """
    lines = open(ASM, encoding="latin-1", errors="replace").read().splitlines()
    is_label = [bool(re.match(r"^(stk_[A-Za-z0-9_]+)\s*$", ln))
                for ln in lines]
    out = {}
    for i, ln in enumerate(lines):
        if not is_label[i]:
            continue
        name = ln.strip()
        for j in range(i + 1, len(lines)):
            nxt = lines[j].strip()
            if not nxt or nxt.startswith((";", "*")):
                continue
            if is_label[j]:
                out[name] = nxt          # points at the next label; resolved below
            break
    # walk each chain to the label that actually owns the fields
    resolved = {}
    for name in out:
        seen, cur = set(), name
        while cur in out and cur not in seen:
            seen.add(cur)
            cur = out[cur]
        resolved[name] = cur
    return resolved


def collect():
    """Every strike record, as pack rows.  Ids are unique by construction."""
    moves = HE.parse_mkstk()
    owner = char_of(HE.parse_char_tables())
    alias = alias_groups()
    extra = {}                             # owning label -> [alias names]
    for name, target in alias.items():
        extra.setdefault(target, []).append(name)
    rows, used = [], {}
    for label in sorted(moves):
        rec = moves[label]
        f = rec["fields"]
        if len(f) < len(HE.FIELD_ORDER):
            continue                       # alias, or a table - see below
        code, shared = owner.get(label, (None, False))
        rid = make_id(label, code)
        if rid in used:                    # never silently merge two records
            rid = "%s-%d" % (rid, used[rid] + 1)
        used[rid] = used.get(rid, 0) + 1
        dmg = _u16(_need_int(f["damage"], label, "damage"))
        rout = _u16(_need_int(f["strike_routine"], label, "strike_routine"))
        row = {
            "id": rid,
            "character": HE.CHARACTER_LABELS.get(code, "shared / system"),
            "symbol": label,
            "hit": (dmg >> 8) & 0xff, "block": dmg & 0xff,
            "hit_reaction": (rout >> 8) & 0xff, "block_reaction": rout & 0xff,
            # score is not always a number - `sc_1000` is a symbol
            "score": f["score"] if isinstance(f["score"], int)
                     else rec["raw_fields"]["score"],
            "sound": rec["raw_fields"]["sound"],
        }
        if label in extra:
            # neutral ids, NOT the raw labels - `aliases` would otherwise put
            # `stk_jczap1` straight back into a --public pack and undo the one
            # thing --public is for
            row["aliases"] = sorted(make_id(a, code) for a in extra[label])
        for pack_f, asm_f, signed in BOX:
            val = _need_int(f[asm_f], label, asm_f)
            row[pack_f] = _s16(val) if signed else val
        if shared:
            row["shared"] = True
        rows.append(row)
    return moves, rows


def digest(rows):
    """Fingerprint the VALUES, so comments and layout cannot change it."""
    h = hashlib.sha256()
    for r in sorted(rows, key=lambda r: r["id"]):
        h.update(("%s|%d,%d,%d,%d|%d,%d|%d,%d|%s\n" % (
            r["id"], r["front"], r["y"], r["width"], r["height"],
            r["hit"], r["block"], r["hit_reaction"], r["block_reaction"],
            r["score"])).encode())
    return h.hexdigest()[:16]


def git_commit():
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                             cwd=ROOT, capture_output=True, text=True,
                             timeout=10)
        return out.stdout.strip() or None
    except Exception:
        return None


def build_pack(rows, args):
    public = getattr(args, "public", False)
    out = []
    for r in rows:
        r = dict(r)
        if public:
            r.pop("symbol", None)
            r.pop("sound", None)
            # a symbolic score (`sc_1000`) is a leaked name too, and it is the
            # one that hides from a `symbol`/`sound` filter.  Drop it - an
            # absent field means "do not change this", which is what we want.
            if not isinstance(r.get("score"), int):
                r.pop("score", None)
        out.append(r)
    return {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "meta": {
            "title": args.title or "MK2 strike boxes",
            "author": args.author or "",
            "description": args.description or "",
            "created": datetime.date.today().isoformat(),
            "base_digest": digest(rows),
            "base_commit": git_commit(),
            "public": bool(public),
        },
        "moves": out,
    }


# ----------------------------------------------------------------- reading

def read_pack(path):
    if path.lower().endswith(".csv"):
        rows = []
        with open(path, newline="", encoding="utf-8-sig") as fh:
            for raw in csv.DictReader(fh):
                row = {}
                for k, v in raw.items():
                    if k is None or v is None or v == "":
                        continue
                    k, v = k.strip(), v.strip()
                    if k in ("id", "character", "symbol", "sound"):
                        row[k] = v
                    else:
                        try:
                            row[k] = int(v, 0)
                        except ValueError:
                            # `score` is allowed to be a symbol (sc_1000);
                            # anything else in a numeric column is a mistake
                            if k == "score":
                                row[k] = v
                            else:
                                raise SystemExit(
                                    "%s: %r is not a number in column %s"
                                    % (path, v, k))
                if row.get("id"):
                    rows.append(row)
        return {"format": FORMAT, "format_version": FORMAT_VERSION,
                "meta": {"title": os.path.basename(path)}, "moves": rows}
    with open(path, encoding="utf-8") as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError as e:
            raise SystemExit("%s: not valid JSON - %s" % (path, e))


LIMITS = {"front": (-32768, 32767), "y": (-32768, 32767),
          "width": (-32768, 32767), "height": (-32768, 32767),
          "hit": (0, 255), "block": (0, 255),
          "hit_reaction": (0, 255), "block_reaction": (0, 255),
          "score": (0, 0xffffffff)}

FIELDS = [f[0] for f in BOX] + ["hit", "block", "hit_reaction",
                                "block_reaction", "score"]


def validate(pack, rows_by_id):
    """Everything wrong with this pack, as a list.  Never raises."""
    errs, warns = [], []
    if pack.get("format") != FORMAT:
        errs.append("not a %s file (format=%r)" % (FORMAT, pack.get("format")))
    if pack.get("format_version", 1) > FORMAT_VERSION:
        errs.append("format_version %s is newer than this tool (%d)"
                    % (pack.get("format_version"), FORMAT_VERSION))
    moves = pack.get("moves")
    if not isinstance(moves, list) or not moves:
        errs.append("no `moves` list")
        return errs, warns
    seen = set()
    for i, m in enumerate(moves):
        if not isinstance(m, dict) or not m.get("id"):
            errs.append("move %d: no id" % (i + 1))
            continue
        rid = m["id"]
        if rid in seen:
            errs.append("%s: listed twice" % rid)
        seen.add(rid)
        if rows_by_id is not None and rid not in rows_by_id:
            errs.append("%s: no such move in this build" % rid)
            continue
        if not re.fullmatch(r"[a-z0-9-]+/[a-z0-9-]+", rid):
            errs.append("%s: id must look like character/move, lower case"
                        % rid)
        for k, v in m.items():
            if k not in LIMITS:
                continue
            if k == "score" and isinstance(v, str):
                continue                   # a symbolic score, e.g. sc_1000
            if not isinstance(v, int) or isinstance(v, bool):
                errs.append("%s: %s must be a whole number, got %r"
                            % (rid, k, v))
                continue
            lo, hi = LIMITS[k]
            if not lo <= v <= hi:
                errs.append("%s: %s = %d is outside %d..%d"
                            % (rid, k, v, lo, hi))
        sym = m.get("symbol")
        if sym and rows_by_id is not None and sym != rows_by_id[rid]["symbol"]:
            errs.append("%s: symbol %s does not match this build's %s"
                        % (rid, sym, rows_by_id[rid]["symbol"]))
        if m.get("width", 1) == 0 or m.get("height", 1) == 0:
            warns.append("%s: zero-size box never connects" % rid)
    return errs, warns


def compute_diff(pack, rows_by_id):
    out = []
    for m in pack["moves"]:
        cur = rows_by_id.get(m["id"])
        if not cur:
            continue
        for k in FIELDS:
            if k in m and m[k] != cur[k]:
                out.append((m["id"], cur["symbol"], k, cur[k], m[k]))
    return out


# ----------------------------------------------------------------- writing

def format_like(orig, value, bits):
    """Write `value` the way `orig` was written - same base, width, case.

    Canonical formatting would be correct and would still assemble, but it
    turns "apply a pack, then revert it" into a file that differs from the
    one you started with: `05eh` comes back as `0005eh` and `0280Ah` as
    `0280ah`.  For a workflow where packs arrive from strangers, a revert
    that leaves `git diff` empty is worth the twenty lines.
    """
    o = orig.strip()
    if re.fullmatch(r"-?[0-9]+", o):                  # plain decimal, e.g. `50`
        v = value & ((1 << bits) - 1)
        return str(v - (1 << bits) if v >= (1 << (bits - 1)) else v)
    m = re.fullmatch(r"(-?)([0-9A-Fa-f]+)[hH]", o)
    if not m:                                          # a symbol, or unknown
        return HE.format_asm_hex(value, bits)
    sign, digits = m.group(1), m.group(2)
    fmt = "X" if any(c.isupper() for c in digits) else "x"
    v = value & ((1 << bits) - 1)
    if sign:                       # the source wrote it as -N; keep that shape
        sv = v - (1 << bits) if v >= (1 << (bits - 1)) else v
        if sv <= 0:
            body = format(-sv, fmt).rjust(len(digits), "0")
            if body[0].isalpha():
                body = "0" + body
            return "-" + body + "h"
    body = format(v, fmt).rjust(len(digits), "0")
    if body[0].isalpha():
        body = "0" + body
    return body + "h"


def apply_changes(changes, moves):
    """Patch MKSTK.ASM.  Per-line endings preserved; backup first."""
    if not changes:
        return 0
    pack_to_asm = {f[0]: f[1] for f in BOX}
    per = {}
    for _rid, sym, field, _old, new in changes:
        per.setdefault(sym, {})[field] = new

    asm = {}                       # symbol -> {asm_field: value}
    for sym, edits in per.items():
        f = moves[sym]["fields"]
        for field, new in edits.items():
            if field in pack_to_asm:
                asm.setdefault(sym, {})[pack_to_asm[field]] = _u16(new)
            elif field == "score":
                asm.setdefault(sym, {})["score"] = new
        # the two packed words are only rebuilt if one of their halves moved
        if "hit" in edits or "block" in edits:
            d = _u16(f["damage"])
            hi = edits.get("hit", (d >> 8) & 0xff)
            lo = edits.get("block", d & 0xff)
            asm.setdefault(sym, {})["damage"] = ((hi & 0xff) << 8) | (lo & 0xff)
        if "hit_reaction" in edits or "block_reaction" in edits:
            r = _u16(f["strike_routine"])
            hi = edits.get("hit_reaction", (r >> 8) & 0xff)
            lo = edits.get("block_reaction", r & 0xff)
            asm.setdefault(sym, {})["strike_routine"] = \
                ((hi & 0xff) << 8) | (lo & 0xff)

    with open(ASM, "rb") as fh:
        lines = fh.readlines()
    backup = ASM + ".pack.bak"
    with open(backup, "wb") as fh:
        fh.writelines(lines)

    n = 0
    # IGNORECASE for the same reason the reader needs it: eleven damage
    # lines are `.WORD`, and a case-sensitive writer silently skips exactly
    # the records a case-sensitive reader silently misread.
    pat = re.compile(rb"^(\s*\.(?:word|long)\s+)([^;]+?)(\s*(?:;.*)?)$",
                     re.IGNORECASE)
    for sym, edits in asm.items():
        for asm_field, value in edits.items():
            ln = moves[sym]["field_lines"].get(asm_field)
            if not ln:
                print("  ! %s.%s has no line - skipped" % (sym, asm_field))
                continue
            raw = lines[ln - 1]
            end = b"\r\n" if raw.endswith(b"\r\n") else b"\n"
            m = pat.match(raw.rstrip(b"\r\n"))
            if not m:
                print("  ! MKSTK.ASM:%d unparsable - skipped" % ln)
                continue
            lit = (format_like(moves[sym]["raw_fields"][asm_field], value,
                               HE.FIELD_BITS[asm_field])
                   if isinstance(value, int) else str(value))
            lines[ln - 1] = m.group(1) + lit.encode() + m.group(3) + end
            n += 1
    with open(ASM, "wb") as fh:
        fh.writelines(lines)
    print("  backup: %s" % os.path.relpath(backup, ROOT))
    return n


# --------------------------------------------------------------------- CLI

SYMBOLISH = re.compile(r"^[a-z][a-z0-9]*_[a-z0-9_]+$")


def audit_public(pack):
    """Names in this pack that look like they came out of the source.

    Written after the first --public export shipped three of them. `symbol`
    and `sound` were the two everybody thinks of; `aliases` quietly carried
    the raw labels, and a symbolic `score` (sc_1000) hid from a filter that
    only looked at those two field names. So this does not check field
    names at all - it checks every string in the file for the SHAPE of an
    assembler symbol, and does not care which key it arrived under.
    """
    bad = []

    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, "%s.%s" % (path, k))
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, "%s[%d]" % (path, i))
        elif isinstance(node, str):
            if SYMBOLISH.match(node.strip()):
                bad.append((path, node.strip()))

    for key in ("moves", "meta"):
        walk(pack.get(key), key)
    return bad


def show_diff(changes):
    if not changes:
        print("No changes - this pack matches the build exactly.")
        return
    print("%-34s %-14s %8s -> %-8s" % ("move", "field", "now", "pack"))
    print("-" * 72)
    for rid, _sym, field, old, new in changes:
        print("%-34s %-14s %8s -> %-8s" % (rid[:34], field, old, new))
    print("\n%d change(s) across %d move(s)."
          % (len(changes), len({c[0] for c in changes})))


def main():
    ap = argparse.ArgumentParser(
        description="Import / export MK2 strike boxes as a portable pack.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("export", help="write every strike box to a pack")
    e.add_argument("--out")
    e.add_argument("--format", choices=("json", "csv"), default="json")
    e.add_argument("--public", action="store_true",
                   help="drop symbol/sound - safe to publish")
    e.add_argument("--title", default=None)
    e.add_argument("--author", default=None)
    e.add_argument("--description", default=None)

    for name, helptext in (("validate", "check a pack without applying it"),
                           ("audit", "look for leaked source names in a pack"),
                           ("diff", "show what a pack would change")):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("pack")

    i = sub.add_parser("import", help="apply a pack to src/MKSTK.ASM")
    i.add_argument("pack")
    i.add_argument("--apply", action="store_true",
                   help="actually write - without it this is a dry run")

    args = ap.parse_args()

    # A public repo has the packs and this script but NOT the game source, so
    # `validate` has to work with nothing to compare against.  That is the
    # whole point of the split: CI can check a stranger's pull request for
    # shape, ids and ranges without the repo ever holding a line of MK2.
    if args.cmd == "audit":
        found = audit_public(read_pack(args.pack))
        for where, name in found:
            print("leak: %s = %r looks like a source symbol" % (where, name))
        if found:
            print("")
            print("%d name(s) that should not be published. "
                  "Re-export with --public." % len(found))
            sys.exit(1)
        print("Clean - nothing in this pack looks like a source symbol.")
        return

    if os.path.exists(ASM):
        moves, rows = collect()
        rows_by_id = {r["id"]: r for r in rows}
    elif args.cmd in ("validate",):
        moves, rows, rows_by_id = {}, [], None
    else:
        sys.exit("%s not found - `%s` needs the game source (only `validate` "
                 "runs without it)" % (os.path.relpath(ASM, ROOT), args.cmd))

    if args.cmd == "export":
        pack = build_pack(rows, args)
        out = args.out or os.path.join(ROOT, "hitbox_pack.%s" % args.format)
        if args.format == "json":
            with open(out, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(pack, fh, indent=2)
                fh.write("\n")
        else:
            cols = [c for c in CSV_COLUMNS
                    if not (args.public and c in ("symbol", "sound"))]
            with open(out, "w", newline="", encoding="utf-8") as fh:
                w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
                w.writeheader()
                for r in pack["moves"]:
                    w.writerow(r)
        print("%d moves -> %s" % (len(rows), os.path.relpath(out, ROOT)))
        print("digest %s%s" % (digest(rows),
                               "  (public)" if args.public else ""))
        return

    pack = read_pack(args.pack)
    errs, warns = validate(pack, rows_by_id)
    for w in warns:
        print("warning: %s" % w)
    if errs:
        for x in errs[:25]:
            print("error: %s" % x)
        if len(errs) > 25:
            print("... and %d more" % (len(errs) - 25))
        sys.exit(1)

    if args.cmd == "validate":
        if rows_by_id is None:
            print("OK - %d moves, well formed. (Schema only: no game source "
                  "here, so ids were not checked against a build.)"
                  % len(pack["moves"]))
            return
        print("OK - %d moves, all known to this build." % len(pack["moves"]))
        base = pack.get("meta", {}).get("base_digest")
        if base and base != digest(rows):
            print("note: authored against digest %s, this build is %s - the "
                  "diff is what that means in practice." % (base, digest(rows)))
        return

    changes = compute_diff(pack, rows_by_id)
    show_diff(changes)

    if args.cmd == "diff" or not changes:
        return
    if not args.apply:
        print("\nDry run. Re-run with --apply to write them.")
        return
    n = apply_changes(changes, moves)
    print("\nPatched %d field(s) in src/MKSTK.ASM." % n)
    print("Next: python tools/balance_lock.py   (the lock guards these values,")
    print("      so Phase D fails until you re-bless them on purpose)")
    print("      python build.py --asm-only && python makerom.py && "
          "python mamerom.py --source-video")


if __name__ == "__main__":
    main()
