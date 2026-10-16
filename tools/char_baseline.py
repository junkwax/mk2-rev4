"""THE ART A NEW MK2 FIGHTER NEEDS - every sequence, its frame count, its
subframes, and which of his IMG libraries it lives in - measured off the
fighters Midway shipped, plus placeholder libraries to start drawing in.

Every MK2 fighter is laid out the same way: a family of numbered libraries
(KANG1-11, CAGE1-10, NUJAX1-10 ...), every record named <XX><SEQ><n>[<letter>]
- a two-letter fighter prefix, the sequence, the frame number, and A/B/C... for
the subframes the game actually draws (the record without a letter is the
SOLID, the whole frame, which IMGTOOL keeps for editing).  Every library also
carries a copy of the STANCE solids as a reference pose; those are reported as
reference copies, not as art the library owns.

  scan        python tools/char_baseline.py
              The baseline across the nine body families: one row per sequence
              (STANCE, TURN, HEADHOLE ...), how many fighters have it, the usual
              frame count and subframe count, and the library number it is
              usually in.  --fighter KANG prints one fighter's own inventory.
  emit        python tools/char_baseline.py --emit KABAL --prefix KB
              Placeholder libraries KABAL1.IMG .. KABALn.IMG laid out on the
              baseline (default: sequences at least 5 of the 9 fighters have;
              --share N changes that, --template KANG copies one fighter's
              layout exactly instead).  Every record keeps the template's size
              and anipoint, is blank, and has ONE dot in its top-right corner so
              it is visible in IMGTOOL and never packs as an empty record.  Also
              writes BASELINE.md / BASELINE.csv beside them.

Output goes to tmp/char_baseline/<NAME>/ unless --out is given.  Nothing here
is read by the build; copy the libraries into data/ when you start a LOD.

What it does NOT know: which TABLE1/TABLE2 row draws a sequence (that is the
character's .ASM), and whether a sequence is his own move or a VICTIM pose
another fighter's fatality draws on him (HEADHOLE is Cage's brain punch,
RIPTORSO Jax's, ...).  Both kinds are art he must have.
"""
from __future__ import annotations

import argparse
import collections
import csv
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_cage_logo as cl          # noqa: E402  (parse_img)
import make_mk1pit as pit            # noqa: E402  (build_img)

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
OUT = ROOT / "tmp" / "char_baseline"

# family -> (prefix, fighter).  Library numbers outside 1..12 are variants
# (KAT49, KAT104, HATHED20, UGMO20) and are left out.
FAMILIES = {
    "KANG":   ("LK", "Liu Kang"),
    "CAGE":   ("JC", "Johnny Cage"),
    "HATHED": ("TM", "Kung Lao"),
    "KAT":    ("KT", "Kitana/Mileena"),
    "NINJAS": ("NJ", "ninjas"),
    "NUJAX":  ("JX", "Jax"),
    "RAID":   ("RN", "Raiden"),
    "TSUNG":  ("ST", "Shang Tsung"),
    "UGMO":   ("UG", "Baraka"),
}
NAME_RE = re.compile(r"(.*?)(\d+)([A-Z]?)")
# One sequence, several spellings across the families -> the one the baseline
# uses.  Kitana's library prefixes Kitana/Mileena as 1/2 and the ninjas'
# Sub-Zero/Reptile/Scorpion as 1/2/3 (KT1STANCE, NJ2STANCE): the variant with
# the lowest digit stands for the family.
ALIAS = {
    "HIKIK": "HIKICK", "LOKIK": "LOKICK", "SWEEPKIK": "SWEEPKICK",
    "DUCKIKHI": "DUCKICKHI", "DUCKIKLO": "DUCKICKLO",
    "HIDUCKICK": "DUCKICKHI", "LODUCKICK": "DUCKICKLO",
    "HITHI": "HIHIT", "HITLO": "LOHIT", "HIBLOCK": "BLOCK",
    "GETTUP": "GETUP", "GETFLIPPED": "FLIPPED", "FALLPIT": "PITFALL",
    "LEGWALK": "WALKLEG", "UTCRUNCH": "NUTCRUNCH",
}
DOT = 1                                   # palette entry the corner dot is drawn in
SRC = ROOT / "src"
# family -> (module, its TABLE1).  Every fighter's TABLE1 has the same rows
# (22h is the elbow, 3Dh the decapitated head, 40h the headhole fall), so the
# ROW is what says two differently named sequences are the same move:
# row 22h draws ELBO for the ninjas, PALMSTRIKE for Liu Kang and Cage,
# HEDSWIPE for Kung Lao, SHORTCUT for Raiden, HEADBOP for Jax.
TABLE1 = {
    "KANG": ("MKLK", "lk_anitab1"), "CAGE": ("MKJC", "jc_anitab1"),
    "HATHED": ("MKHH", "hat_anitab1"), "KAT": ("MKFN", "fn1_anitab1"),
    "NINJAS": ("MKNJ", "sz_anitab1"), "NUJAX": ("MKJX", "jx_anitab1"),
    "RAID": ("MKRD", "rd_anitab1"), "TSUNG": ("MKST", "st_anitab1"),
    "UGMO": ("MKSA", "sa_anitab1"),
}
LABEL = re.compile(r"^([A-Za-z_]\w*)")


def natural(s):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s)]


def split(rest):
    """'STANCE3B' -> ('STANCE', 3, 'B'); 'TURN1FLIP' -> ('TURN1FLIP', None, '')."""
    m = NAME_RE.fullmatch(rest)
    if not m or not m.group(1):
        return rest, None, ""
    return m.group(1), int(m.group(2)), m.group(3)


def canonical(stem):
    """-> (canonical stem, variant digit or 0)."""
    m = re.fullmatch(r"(\d)([A-Z].*)", stem)
    var, stem = (int(m.group(1)), m.group(2)) if m else (0, stem)
    return ALIAS.get(stem, stem), var


def libraries(fam):
    out = []
    for f in DATA.glob(f"{fam}*.IMG"):
        m = re.fullmatch(fam + r"(\d+)", f.stem)
        if m and 1 <= int(m.group(1)) <= 12:
            out.append((int(m.group(1)), f))
    return sorted(out)


def inventory(fam):
    """{stem: seq} for one family.  seq = lib (where it is owned), frames
    {n: {"solid": bool, "pieces": set, "w", "h", "ax", "ay"}}, refs [libs
    carrying only reference copies]; plus the records without the prefix."""
    pre = FAMILIES[fam][0]
    per = collections.defaultdict(lambda: collections.defaultdict(dict))   # stem -> lib -> name -> rec
    extras = collections.defaultdict(list)
    for n, f in libraries(fam):
        recs, _pals = cl.parse_img(f.read_bytes())
        for name, r in recs.items():
            if not name.startswith(pre):
                extras[n].append(name)
                continue
            stem, _num, _l = split(name[len(pre):])
            per[stem][n][name] = r
    seqs = {}
    for stem, bylib in per.items():
        own = max(bylib, key=lambda k: (len(bylib[k]), -k))    # most records; ties -> lowest lib
        frames = {}
        for name, r in bylib[own].items():
            _s, num, letter = split(name[len(pre):])
            fr = frames.setdefault(num, {"solid": False, "pieces": set(), "w": 0, "h": 0,
                                         "ax": 0, "ay": 0})
            if letter:
                fr["pieces"].add(letter)
            else:
                fr["solid"] = True
            if not letter or not fr["solid"]:        # the solid's geometry wins
                fr.update(w=r["w"], h=r["h"], ax=r["ax"], ay=r["ay"])
            fr.setdefault("recs", {})[letter] = r
        seqs[stem] = dict(lib=own, frames=frames, raw=stem,
                          refs=sorted(k for k in bylib if k != own))
    return seqs, extras


_ROWS = {}


def table1(fam):
    """[(row, comment, [canonical stems the row's lane draws, in order])],
    read out of the fighter's module: its TABLE1 rows, then each lane from its
    label to the next column-0 label."""
    if fam in _ROWS:
        return _ROWS[fam]
    mod, tab = TABLE1[fam]
    lines = (SRC / f"{mod}.ASM").read_text(encoding="latin-1").splitlines()
    at = {}
    for i, ln in enumerate(lines):
        m = LABEL.match(ln)
        if m:
            at.setdefault(m.group(1), i)
    if tab not in at:
        raise SystemExit(f"{mod}.ASM has no {tab}")
    rows = []
    for ln in lines[at[tab]:]:
        m = LABEL.match(ln)
        if m and m.group(1) != tab and rows:
            break
        m = re.match(r"^(?:\w+)?\s+\.long\s+(\w+)\s*(?:;\s*([0-9a-fA-F]+)?\s*-?\s*(.*))?", ln)
        if m:
            rows.append((m.group(1), (m.group(3) or "").strip()))
    pre = FAMILIES[fam][0]
    out = []
    for r, (lane, note) in enumerate(rows):
        stems = []
        if lane in at:
            for k, ln in enumerate(lines[at[lane]:]):
                if k and LABEL.match(ln):
                    break
                code = ln.split(";")[0]
                if ".long" not in code:
                    continue
                for t in re.findall(r"\b([A-Z][A-Za-z0-9_]*)\b", code.split(".long", 1)[1]):
                    if t.startswith(pre):
                        st, num, _l = split(t[len(pre):])
                        if num is not None:
                            st = canonical(st)[0]
                            if st not in stems:
                                stems.append(st)
        out.append((r, note, stems))
    _ROWS[fam] = out
    return out


COMMON_ROWS = 0x42      # rows 0..41h mean the same thing in every TABLE1
ROW_VOTES = 3           # fighters that must lead a row with one name to name it
CONSENSUS = 5           # a stem this many fighters carry is never renamed


def row_names():
    """row -> the name the baseline gives the sequence that row draws first:
    the shared rows' most common lead name, when ROW_VOTES fighters use it.
    Row 22h (the elbow) is ELBO for 4 of 9 and five different names for the
    rest, so a plurality is what it takes."""
    first = collections.defaultdict(list)
    for fam in FAMILIES:
        for r, _n, stems in table1(fam):
            if stems and r < COMMON_ROWS:
                first[r].append(stems[0])
    out = {}
    for r, v in first.items():
        name, n = collections.Counter(v).most_common(1)[0]
        if n >= ROW_VOTES:
            out[r] = name
    return out


_COMMON = set()


def common_stems():
    """Stems CONSENSUS or more fighters carry under that name - never renamed."""
    if not _COMMON:
        c = collections.Counter()
        for fam in FAMILIES:
            c.update({canonical(raw)[0] for raw in inventory(fam)[0]})
        _COMMON.update(st for st, n in c.items() if n >= CONSENSUS)
    return _COMMON


def row_alias(fam, names):
    """stem -> baseline name, for a sequence this fighter draws FIRST in a
    shared TABLE1 row under a name of his own (his elbow is a PALMSTRIKE).
    A stem that is a common name itself, or that leads two rows with
    different names, is left alone."""
    lead = collections.defaultdict(set)
    for r, _n, stems in table1(fam):
        if stems and r in names:
            lead[stems[0]].add(names[r])
    return {st: next(iter(v)) for st, v in lead.items()
            if len(v) == 1 and next(iter(v)) != st and st not in common_stems()}


def row_index():
    """stem -> [(row, comment)]: the shared TABLE1 rows whose lane draws that
    sequence for at least ROW_VOTES fighters (under its baseline name)."""
    names = row_names()
    votes = collections.defaultdict(collections.Counter)
    note = {}
    for fam in FAMILIES:
        alias = row_alias(fam, names)
        for r, n, stems in table1(fam):
            if r >= COMMON_ROWS:
                continue
            note.setdefault(r, n)
            for st in {alias.get(x, x) for x in stems}:
                votes[st][r] += 1
    return {st: [(r, note[r]) for r, n in sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))
                 if n >= ROW_VOTES]
            for st, c in votes.items()}


def normalised(fam, names=None):
    """inventory() keyed by canonical stem: of the raw spellings that land on
    one stem, the lowest variant digit, then the most frames, stands for it.
    With `names` (row_names()), a sequence is also renamed to what the other
    fighters call the TABLE1 row it is drawn by - unless he already has a
    sequence of that name."""
    seqs, _x = inventory(fam)
    alias = row_alias(fam, names) if names else {}
    have = {canonical(raw)[0] for raw in seqs}
    best = {}
    for raw, s in seqs.items():
        stem, var = canonical(raw)
        if alias.get(stem) and alias[stem] not in have:
            stem = alias[stem]
        key = (var, -len(s["frames"]))
        if stem not in best or key < best[stem][0]:
            best[stem] = (key, s)
    return {k: v[1] for k, v in best.items()}


def frame_range(nums):
    nums = sorted(n for n in nums if n is not None)
    if not nums:
        return ""
    if nums == list(range(nums[0], nums[-1] + 1)):
        return f"{nums[0]}-{nums[-1]}" if len(nums) > 1 else str(nums[0])
    return ",".join(map(str, nums))


def pieces_of(seq):
    """The usual number of subframes per frame (0 = solid only)."""
    c = collections.Counter(len(f["pieces"]) for f in seq["frames"].values())
    return c.most_common(1)[0][0]


def mode(xs):
    return collections.Counter(xs).most_common(1)[0][0]


# ---------------------------------------------------------------------------
def baseline(share):
    """Rows for every sequence at least `share` fighters have, with the
    family whose layout each row is drawn from (the one nearest the usual)."""
    names = row_names()
    inv = {fam: normalised(fam, names) for fam in FAMILIES}
    stems = collections.defaultdict(dict)
    for fam, seqs in inv.items():
        for stem, s in seqs.items():
            stems[stem][fam] = s
    rows = []
    for stem, have in stems.items():
        if len(have) < share:
            continue
        nfr = mode(len(s["frames"]) for s in have.values())
        npc = mode(pieces_of(s) for s in have.values())
        lib = mode(s["lib"] for s in have.values())
        src = min(have, key=lambda f: (len(have[f]["frames"]) != nfr, pieces_of(have[f]) != npc,
                                       have[f]["lib"] != lib, list(FAMILIES).index(f)))
        rows.append(dict(stem=stem, fighters=len(have), frames=nfr, pieces=npc, lib=lib,
                         src=src, seq=have[src],
                         counts={f: len(s["frames"]) for f, s in have.items()}))
    rows.sort(key=lambda r: (r["lib"], -r["fighters"], natural(r["stem"])))
    idx = row_index()
    for r in rows:
        r["table1"] = idx.get(r["stem"], [])
    return rows


def template_rows(fam):
    seqs, _x = inventory(fam)
    rows = [dict(stem=st, fighters=1, frames=len(s["frames"]), pieces=pieces_of(s),
                 lib=s["lib"], src=fam, seq=s, counts={fam: len(s["frames"])})
            for st, s in seqs.items()]
    rows.sort(key=lambda r: (r["lib"], natural(r["stem"])))
    lanes = collections.defaultdict(list)          # his own rows, by raw stem
    for rw, n, stems in table1(fam):
        for st in stems:
            lanes[st].append((rw, n))
    for r in rows:
        r["table1"] = lanes.get(canonical(r["stem"])[0], [])
    return rows


def t1(r, short=False):
    """'22 elbow' (+n more)."""
    rs = r.get("table1") or []
    if not rs:
        return ""
    first = f"{rs[0][0]:02X} {rs[0][1]}".strip()
    return first + (f" +{len(rs) - 1}" if len(rs) > 1 else "")


# ---------------------------------------------------------------------------
def report(rows, title, prefix="XX"):
    libs = collections.defaultdict(list)
    for r in rows:
        libs[r["lib"]].append(r)
    out = [f"# {title}", "",
           f"{len(rows)} sequences, {sum(len(r['seq']['frames']) for r in rows)} frames, "
           f"{len(libs)} libraries.  `frames` is the range the layout source carries; "
           f"`sub` is subframes per frame (0 = solid only); `have` is how many of the "
           f"{len(FAMILIES)} body families carry it.", ""]
    fams = list(FAMILIES)
    for lib in sorted(libs):
        rs = libs[lib]
        nfr = sum(len(r["seq"]["frames"]) for r in rs)
        out += [f"## library {lib}  ({len(rs)} sequences, {nfr} frames)", "",
                "| sequence | frames | sub | have | TABLE1 row | from | " + " | ".join(fams) + " |",
                "|---|---|---|---|---|---|" + "---|" * len(fams)]
        for r in rs:
            fr = frame_range(r["seq"]["frames"])
            cells = [str(r["counts"].get(f, "")) for f in fams]
            out.append(f"| {prefix}{r['stem']}{fr} | {len(r['seq']['frames'])} | {r['pieces']} | "
                       f"{r['fighters']} | {t1(r)} | {r['src']} | " + " | ".join(cells) + " |")
        out.append("")
    return "\n".join(out)


def write_csv(rows, path):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["lib", "sequence", "frames", "frame_range", "subframes", "fighters", "table1_rows", "layout_from"]
                   + list(FAMILIES))
        for r in rows:
            w.writerow([r["lib"], r["stem"], len(r["seq"]["frames"]), frame_range(r["seq"]["frames"]),
                        r["pieces"], r["fighters"],
                        " ".join(f"{x:02X}" for x, _n in r.get("table1", [])), r["src"]]
                       + [r["counts"].get(f, "") for f in FAMILIES])


# ---------------------------------------------------------------------------
def dot_record(name, rec):
    """A blank record of the template's size and anipoint, one dot top-right."""
    w, h = max(rec["w"], 1), max(rec["h"], 1)
    px = bytearray(w * h)
    px[w - 1] = DOT
    return (name, rec["ax"], rec["ay"], w, h, bytes(px), 0)


def emit(rows, name, prefix, out):
    if not re.fullmatch(r"[A-Z]{2}", prefix):
        raise SystemExit("--prefix is two capital letters (it replaces LK/JC/NJ ...)")
    if len(name) + len(str(max(r["lib"] for r in rows))) > 8:
        raise SystemExit(f"{name}<n>.IMG is not a DOS 8.3 name - shorten --emit")
    pal = [(f"{prefix}MAIN_P", 6, [0, 0x7FFF] + [0] * 62)]
    libs = collections.defaultdict(lambda: {"solid": [], "piece": []})
    for r in rows:
        for num, fr in sorted(r["seq"]["frames"].items(), key=lambda kv: (kv[0] is None, kv[0] or 0)):
            base = f"{prefix}{r['stem']}{'' if num is None else num}"
            for letter, rec in fr["recs"].items():
                nm = base + letter
                if len(nm) > 15:
                    raise SystemExit(f"{nm} is longer than an IMG record name (15)")
                libs[r["lib"]]["piece" if letter else "solid"].append(dot_record(nm, rec))
    # every library carries the STANCE solids as a reference pose, as Midway's do
    stance = next((r for r in rows if r["stem"] == "STANCE"), None)
    if stance:
        ref = [dot_record(f"{prefix}STANCE{n}", fr["recs"][""])
               for n, fr in sorted(stance["seq"]["frames"].items()) if "" in fr["recs"]]
        for lib, L in libs.items():
            if lib != stance["lib"]:
                L["solid"] = ref + L["solid"]
    out.mkdir(parents=True, exist_ok=True)
    total = 0
    for lib, L in sorted(libs.items()):
        ents = L["solid"] + sorted(L["piece"], key=lambda e: natural(e[0]))
        f = out / f"{name}{lib}.IMG"
        f.write_bytes(pit.build_img(ents, pal))
        recs, _p = cl.parse_img(f.read_bytes())          # prove it reads back
        if len(recs) != len(ents):
            raise SystemExit(f"{f.name}: wrote {len(ents)} records, read back {len(recs)}")
        total += len(ents)
        print(f"  {f.relative_to(ROOT) if f.is_relative_to(ROOT) else f}: "
              f"{len(L['solid'])} solids, {len(L['piece'])} subframes")
    print(f"{len(libs)} libraries, {total} records, palette {prefix}MAIN_P (entry {DOT} = the dot)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fighter", metavar="FAMILY", help="one family's inventory (KANG, CAGE, ...)")
    ap.add_argument("--share", type=int, default=5,
                    help="baseline: sequences at least N families carry (default 5)")
    ap.add_argument("--template", metavar="FAMILY", help="emit: copy this family's layout exactly")
    ap.add_argument("--emit", metavar="NAME", help="write placeholder NAME1.IMG .. NAMEn.IMG")
    ap.add_argument("--prefix", default="XX", help="emit: two-letter record prefix")
    ap.add_argument("--out", type=Path, help="emit: output folder (default tmp/char_baseline/NAME)")
    a = ap.parse_args()

    fam = (a.fighter or a.template or "").upper()
    if fam and fam not in FAMILIES:
        raise SystemExit(f"unknown family {fam} - one of {', '.join(FAMILIES)}")
    if fam:
        rows = template_rows(fam)
        title = f"{FAMILIES[fam][1]} ({fam}1-{max(r['lib'] for r in rows)}) - every sequence"
        if a.fighter:
            _s, extras = inventory(fam)
            text = report(rows, title, FAMILIES[fam][0])
            if extras:
                text += "\n## records without the prefix (effects / props, not emitted)\n\n" + "\n".join(
                    f"- {fam}{n}: {', '.join(sorted(v, key=natural))}" for n, v in sorted(extras.items()))
            print(text)
            if not a.emit:
                return
    else:
        rows = baseline(a.share)
        title = f"MK2 fighter baseline - sequences {a.share}+ of {len(FAMILIES)} fighters carry"
    if not a.emit:
        print(report(rows, title, a.prefix))
        return
    name = a.emit.upper()
    out = a.out or OUT / name
    emit(rows, name, a.prefix.upper(), out)
    (out / "BASELINE.md").write_text(report(rows, title, a.prefix.upper()) + "\n")
    write_csv(rows, out / "BASELINE.csv")
    print(f"  {out / 'BASELINE.md'}\n  {out / 'BASELINE.csv'}")


if __name__ == "__main__":
    main()
