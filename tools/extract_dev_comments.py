#!/usr/bin/env python3
"""
extract_dev_comments.py - collect the leaked MK2 source's OWN commentary.

Midway's programmers wrote ~27,000 comment-bearing lines across the leak, and
most of a routine's INTENT lives there rather than in its instructions. The
problem is the ratio: a flat dump is unreadable, because the overwhelming
majority of those lines are table field labels ("x offset of collision box",
202 times) and register bookkeeping ("a2 = gravity").

So this is a filter, not a dump. It reads the READ-ONLY tree - the retail
source at ../mk2-readonly/mk2-main/src, never our own modified src/ - and
separates signal from mechanism:

  doc/ORIGINAL_SOURCE_COMMENTS.md   the readable document: the conventions the
                                    leak comments itself with, the module
                                    banners in Midway's own words, every `ejb`
                                    / `!!!` / kludge marker, every documented
                                    routine header, and the loose prose notes
  doc/original_source_comments.csv  EVERY surviving comment with file:line, for
                                    grepping - including the inline ones the
                                    document leaves out

Two filter decisions are worth knowing about:

  REPETITION IS THE STRONGEST SIGNAL OF MECHANISM. A comment body appearing
  more than --max-repeat times tree-wide is a field label or a register note by
  construction, whatever its wording. That one rule removes a third of the raw
  lines and needs no vocabulary of its own.

  THE DISABLED-CODE DETECTOR IS SELF-CALIBRATING. A `;` in column 0 usually
  means a commented-out INSTRUCTION, not a note, and those are archaeology
  rather than commentary. Rather than hardcode a TMS34010 mnemonic list that
  would rot, the mnemonic vocabulary is harvested from the uncommented code in
  the tree being scanned (178 mnemonics, directives and macros as of the
  retail leak), so a disabled `tsound` or `mess_mac` line is recognised for
  free.

Usage:
  python tools/extract_dev_comments.py            # write both outputs
  python tools/extract_dev_comments.py --stats     # funnel only, write nothing
  python tools/extract_dev_comments.py --check     # fail if the outputs drifted
  python tools/extract_dev_comments.py --grep kano # what the source says about X
"""
import argparse
import collections
import csv
import datetime
import io
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
READONLY = ROOT.parent / "mk2-readonly" / "mk2-main" / "src"
OUT_MD = ROOT / "doc" / "ORIGINAL_SOURCE_COMMENTS.md"
OUT_CSV = ROOT / "doc" / "original_source_comments.csv"

EXTS = (".ASM", ".HDR", ".H", ".EQU", ".GLO", ".TBL")

# Which family a module belongs to, for ordering the document. Keyed by exact
# stem first, then by prefix. CLAUDE.md's own grouping.
FAMILY_EXACT = {
    "MAIN": "Core engine",
    "MPROC": "Core engine",
    "RAM": "Core engine",
    "MKSTRUCT": "Core engine",
    "UTIL": "Core engine",
    "MKUTIL": "Core engine",
    "DISPEQU": "System headers",
    "SYSEQU": "System headers",
    "MACROS": "System headers",
    "MAINEQU": "System headers",
    "DIPEQU": "System headers",
    "IMGTBL": "System headers",
    "MOVES": "Game systems",
    "MKREACT": "Game systems",
    "MKDRONE": "Game systems",
    "BGND": "Game systems",
    "BAKGND": "Game systems",
    "BGNDTBL": "Game systems",
    "MKDISP": "Game systems",
    "MKSEL": "Game systems",
    "MKSOUND": "Game systems",
    "MKINIT": "Game systems",
    "MKAMODE": "Game systems",
    "MKSTK": "Game systems",
    "JOY": "Game systems",
    "MKPROP": "Game systems",
    "MKZAP": "Game systems",
    "MKSLAM": "Game systems",
    "MKGUYS": "Game systems",
    "MKBLOOD": "Effects and sequences",
    "MKFX": "Effects and sequences",
    "MKDEATH": "Effects and sequences",
    "MKDIE": "Effects and sequences",
    "MKFALL": "Effects and sequences",
    "MKCANNED": "Effects and sequences",
    "MKTOAST": "Effects and sequences",
    "MKSOUL": "Effects and sequences",
    "MKMORPH": "Effects and sequences",
}
FAMILY_PREFIX = [
    ("DIAG", "Diagnostics"),
    ("MK", "Per-character and per-stage modules"),
]
FAMILY_ORDER = [
    "Core engine",
    "System headers",
    "Game systems",
    "Effects and sequences",
    "Per-character and per-stage modules",
    "Diagnostics",
    "Other",
]

# A comment containing one of these is kept whatever else the filters say, and
# listed in its own section. These are the leak's own "come back to this"
# conventions - `ejb` is Ed Boon's initials, used to sign a note or flag a spot.
MARKERS = [
    ("ejb", r"\bejb", "Ed Boon's own markers"),
    ("question", r"\?\?\?", "Open questions (`???`)"),
    ("kludge", r"\bkl[uo]dges?\b|\bkluge\b|\bhack(s|ed|y)?\b", "Admitted kludges"),
    ("temp", r"\btemp(orary|orarily)?\b|\bfor now\b|\blater\b|\bsomeday\b|\bxxx\b",
     "Temporary, for now, later"),
    # No `danger` here: `danger_danger` is a real routine (the low-health
    # flasher) and `p1_danger_proc` is RAM, so the word matches the feature
    # far more often than it matches a warning.
    ("note", r"\bnote\s*:|\bwarning\b|\bcareful\b|\bbeware\b", "Notes and warnings"),
    ("shout", r"!!!", "Exclamations (`!!!`)"),
]

# MKEND.ASM's `clue_table` - the lines the ending rotates. Four are
# scrambled; the unscramblings are curated here because no rule recovers them.
CLUE_UNSCRAMBLE = {
    "CEAMR ODSE NTO EXITS": "ERMAC DOES NOT EXIST",
    "EMRO BATMOK OT MEOK": "MORE KOMBAT TO COME",
    "SRUEP GHIH MIPTAC": "SUPER HIGH IMPACT",
    "THREE RAE ON STNIIIAAMEL": "THERE ARE NO ANIMALITIES",
}

# MK1's Kano and Sonya were cut as fighters, but their moves were renamed onto
# other characters and the comments never were. Each entry is checked against
# the tree at generation time, so a wrong citation fails instead of printing.
RESIDUE = [
    ("MK1 leftovers in the background code, flagged and never removed",
     r"may be eliminated \(for kano\)"),
    ("Baraka's module and moves are still Kano's", r"kano II"),
    ("Mileena's roll is still the Kano ball", r"kano ball|last kano roll"),
    ("Kintaro still gets tripped by a Kano move", r"tripped by kano"),
    ("Art left behind", r"left over unused frames"),
]

# What Midway was working around, in their own words. (file, regex, note).
# Verified against the read-only tree every run - a citation that stops
# matching fails the build of this page rather than going quietly stale.
WORKAROUNDS = [
    ("MKREACT.ASM", r'clear "phit not getting zeroed" bug',
     "`p_hit` - the hit counter the whole juggle system reads - was not "
     "being zeroed, and the fix was to call `back_to_normal` at the get-up. "
     "Midway called it a bug; this project measured the consequence "
     "independently (a counter oscillating 0<->1, so `phitmax` is 1)."),
    ("MKDISP.ASM", r"fix elevated shadows",
     "A `zext` to stop the negative half of `worldtlx` bleeding into Y and "
     "lifting every shadow off the floor. NOT the same thing as this "
     "project's floating shadows, which are launch height against a stage "
     "with no clip band."),
    ("SYSEQU.ASM", r"try fixing auto-erase line trashing bug",
     "Still says `try`. A hardware-level display bug addressed by moving an "
     "equate, with no note that it worked."),
    ("MKHSTD.ASM", r"we is outta bits",
     "Twice, in the high-score record. Space, not time."),
    ("MKREACT.ASM", r"kludge this in so hit q is updated",
     "A late fix to the hit queue, pasted at every reaction site rather "
     "than factored into one."),
    ("MAINEQU.ASM", r"make sure they are not referenced",
     "The drone had run out of process fields, so its locals are aliases "
     "over `p_joyport` / `p_butport`, and the warning is the only thing "
     "stopping a name collision."),
    ("MKSTK.ASM", r'look for\s*$|the string "stksize"',
     "The strike tables have a hand-maintained size constant somewhere "
     "else, and the note is the only link between them."),
]

# The anti-juggle policy, counted rather than claimed.
JUGGLE_ROUTINES = ("no_unlimited_airhits", "repell_on_a1_hit")
RE_SEPARATOR = re.compile(r"\b(no_unlimited_airhits|repell_on_a1_hit"
                          r"|attacker_getting_separated)\b")

RE_DATE = re.compile(r"\b([01]?\d[-/]\d{1,2}[-/]\d{2,4})\b")
# Ed Boon has no `txt_ejb` credit row (the team names are two-line strings),
# so he is seeded by hand; everyone else is decoded from MKEND.ASM.
EXTRA_CREDITS = {"ejb": "ED BOON"}
RE_BAR = re.compile(r"^[-*=_|+.~<>#/\\ \t]+$")
RE_REGNOTE = re.compile(r"^[ab]\d+\s*(=|->|:|,|\s+is\b)", re.I)
RE_REGLIST = re.compile(r"^[ab]\d+(\s*[-,/]\s*[ab]?\d+)+\s*$", re.I)
RE_NUMERIC = re.compile(r"^[-+]?[\da-f>$x_.,\s]+h?$", re.I)
RE_YESNO = re.compile(r"^(br\s*=\s*)?(yes|no|yep|nope|maybe)[\s!?.]*$", re.I)
RE_LABELDEF = re.compile(r"^([A-Za-z_?][\w?]*)\b")
RE_MNEMONIC = re.compile(r"^(?:[A-Za-z_?][\w?]*)?[ \t]+([.\w]+)")
RE_DATADIR = re.compile(r"^\.(word|long|byte|string|set|equ|even|bss|global|ref|def|"
                        r"file|option|width|mnolist|include|title|text|data|end|if|"
                        r"else|endif)$", re.I)
# A banner line like "*  module: special moves    *" - the content we want.
RE_BANNER_FIELD = re.compile(
    r"^(module|game software|programmer|video game project|copyright)\s*:?\s*(.*)$", re.I)


def source_files(src):
    out = []
    for p in sorted(src.iterdir()):
        if p.is_file() and p.suffix.upper() in EXTS:
            out.append(p)
    return out


def harvest_mnemonics(files):
    """Every mnemonic, directive and macro that appears in LIVE code.

    Self-calibrating by design: the vocabulary comes from the tree being
    scanned, so the disabled-code detector cannot go stale against it.
    """
    mne = set()
    for p in files:
        for ln in read_lines(p):
            t = ln.strip()
            if not t or t[0] in "*;":
                continue
            m = RE_MNEMONIC.match(strip_comment(ln))
            if m:
                mne.add(m.group(1).lower())
    return mne


def read_lines(p):
    with open(p, "r", errors="replace") as fh:
        return [ln.rstrip("\n").rstrip("\r") for ln in fh]


def strip_comment(line):
    """Everything before the comment marker, respecting quoted strings.

    A `;` inside a .string literal is data, not a comment.
    """
    out = []
    quote = None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            continue
        if ch == ";":
            break
        out.append(ch)
    return "".join(out)


def comment_of(line):
    """(kind, body) for one raw line, or (None, None).

    kind is 'full' for a whole-line comment and 'inline' for one trailing an
    instruction. The `*` box frame and leading/trailing `;*` runs are stripped.
    """
    t = line.strip()
    if not t:
        return None, None
    if t[0] in "*;":
        body = t.lstrip("*; \t").rstrip()
        # Boxed headers pad to a right-hand `*` column; drop that frame.
        body = re.sub(r"[ \t]*\*+$", "", body).strip()
        return "full", body
    code = strip_comment(line)
    if len(code) < len(line):
        return "inline", line[len(code):].lstrip("; \t").rstrip()
    return None, None


def family_of(stem):
    if stem in FAMILY_EXACT:
        return FAMILY_EXACT[stem]
    for pre, fam in FAMILY_PREFIX:
        if stem.startswith(pre):
            return fam
    return "Other"


class Comment:
    __slots__ = ("path", "line", "kind", "body", "label", "attached", "markers",
                 "from_disabled")

    def __init__(self, path, line, kind, body, label):
        self.path = path
        self.line = line
        self.kind = kind
        self.body = body
        self.label = label
        self.attached = False   # sits in a block that documents a routine
        self.markers = []
        self.from_disabled = False


class Block:
    """A run of consecutive whole-line comments - one note, not N lines.

    `kind` is 'header' when the block documents the label underneath it (the
    leak's docstring), 'banner' when it labels a section of the file rather
    than one routine, and 'loose' when nothing follows it.
    """

    def __init__(self, comments, label, kind):
        self.comments = comments
        self.label = label
        self.kind = kind

    @property
    def attached(self):
        return self.kind == "header"

    @property
    def path(self):
        return self.comments[0].path

    @property
    def line(self):
        return self.comments[0].line


def is_disabled_code(body, mne):
    """Does this comment body look like a commented-out instruction?"""
    m = RE_MNEMONIC.match(body)
    if m and m.group(1).lower() in mne:
        return True
    m = re.match(r"^([.\w]+)[ \t]", body)
    if m and m.group(1).lower() in mne:
        return True
    # A bare directive on its own, e.g. ";.endif"
    if RE_DATADIR.match(body.split()[0] if body.split() else ""):
        return True
    return False


def classify_block(bodies, next_label):
    """'header' if the block documents next_label, else 'banner'.

    A routine header names its routine: either a line opens with the label
    itself, or it has the leak's `name - what it does` shape. A box that does
    neither is a section divider ("Body propelling moves"), which belongs with
    the notes rather than pretending to document the routine it happens to sit
    above.
    """
    if not next_label:
        return "loose"
    low = next_label.lower()
    for b in bodies:
        s = b.strip().lower()
        if s.startswith(low) and (len(s) == len(low) or not s[len(low)].isalnum()):
            return "header"
        if re.match(r"^[\w?]+\s+-+\s+\S", s) and ("input" in " ".join(bodies).lower()
                                                  or "output" in " ".join(bodies).lower()
                                                  or "returns" in " ".join(bodies).lower()):
            return "header"
    return "banner"


def read_clue_table(src):
    """MKEND.ASM's `clue_table`, in table order.

    Read rather than typed: the table names `txt_cN` and each one's string
    sits beside it, so the page cannot drift from the ROM's own list.
    """
    p = src / "MKEND.ASM"
    if not p.is_file():
        return []
    txt = "\n".join(read_lines(p))
    tab = re.search(r"^clue_table\s*\n((?:\s*\.long\s+\w+\s*\n)+)", txt, re.M)
    if not tab:
        return []
    order = re.findall(r"\.long\s+(\w+)", tab.group(1))
    strings = dict(re.findall(r'^(txt_c\d+)\s*\.string\s+"([^"]*)"', txt, re.M))
    out = []
    for name in order:
        s = strings.get(name)
        if s is None:
            continue
        out.append((name, s, CLUE_UNSCRAMBLE.get(s)))
    return out


def credited_names(src):
    """The `txt_<initials> .string "NAME"` credits, for decoding initials."""
    p = src / "MKEND.ASM"
    if not p.is_file():
        return {}
    txt = "\n".join(read_lines(p))
    out = {}
    for ini, name in re.findall(r'^txt_([a-z]{2,4})\s*\.string\s+"([A-Z][A-Z .]+)"',
                                txt, re.M):
        if "\\n" not in name:
            out[ini.lower()] = name.strip()
    out.update(EXTRA_CREDITS)
    return out


def dated_notes(comments, credits):
    """Comments signed with initials and a date - the only schedule trail.

    Find the DATE first, then look for a known set of initials anywhere in
    the same comment. Reading the token in front of the date instead gets
    `GNP end 1/13/94` as "end" and `.Last mod - 3/24/93` as "mod", and
    misses `GNP changed 1/13/94` entirely.
    """
    out = []
    for c in comments:
        m = RE_DATE.search(c.body)
        if not m:
            continue
        ini = None
        for tok in re.findall(r"[A-Za-z]{2,4}", c.body):
            t = tok.lower()
            if t in credits:
                ini = t
                break
        out.append((c, ini, m.group(1), credits.get(ini) if ini else None))
    out.sort(key=lambda r: (r[0].path.name, r[0].line))
    return out


def initialed_notes(comments, credits, dated):
    """Signed but UNdated comments - the rest of the authorship trail."""
    seen = {id(c) for c, _, _, _ in dated}
    out = []
    for c in comments:
        if id(c) in seen:
            continue
        for tok in re.findall(r"[A-Za-z]{2,4}", c.body):
            t = tok.lower()
            # `ejb` has its own section; require the initials to be set off
            # from words, so "mod"/"end"/"see" cannot pose as a signature.
            if t in credits and t != "ejb" and re.search(
                    r"[-(;:]\s*%s\b|\b%s\s*[-)]" % (tok, tok), c.body):
                out.append((c, t, credits[t]))
                break
    out.sort(key=lambda r: (r[0].path.name, r[0].line))
    return out


def grep_tree(src, pattern):
    """(file, line, comment body) for every comment matching pattern."""
    rx = re.compile(pattern, re.I)
    hits = []
    for p in source_files(src):
        for i, raw in enumerate(read_lines(p), 1):
            k, b = comment_of(raw)
            if k and b and rx.search(b):
                hits.append((p.name, i, b.strip()))
    return hits


def count_calls(src, names):
    """How many places call each routine, and where it is defined."""
    out = {}
    for n in names:
        calls, defined = [], None
        for p in source_files(src):
            for i, raw in enumerate(read_lines(p), 1):
                code = strip_comment(raw)
                if re.match(r"^%s\b" % re.escape(n), code):
                    defined = (p.name, i)
                elif re.search(r"\b(callr|calla|jsrp|jauc|jruc|movi)\s+%s\b"
                               % re.escape(n), code):
                    calls.append((p.name, i))
        out[n] = (defined, calls)
    return out


def audit_airborne(src):
    """Who actually separates an airborne victim, measured not assumed.

    `reaction_start_abc` sets a flag; at `rst5` an airborne victim is sent
    to whatever handler the caller left in `a5` and the reaction's own script
    never runs. So the anti-juggle rule is applied at that FUNNEL, and the
    question is not how many reactions call the separator directly - it is
    which a5 handlers separate, plus which reactions skip the airborne check
    altogether by calling plain `reaction_start`.
    """
    p = src / "MKREACT.ASM"
    if not p.is_file():
        return None
    L = read_lines(p)
    labels = [None] * len(L)
    cur = None
    starts = {}
    for i, raw in enumerate(L):
        c = strip_comment(raw)
        if c.strip() and not c[0].isspace():
            m = re.match(r"([A-Za-z_?][\w?]*)", c)
            if m and not re.match(r"^(\.(set|equ|global|ref|def)|equ)\b",
                                  c[m.end():].lstrip(), re.I):
                cur = m.group(1)
                starts.setdefault(cur, i)
        labels[i] = cur
    order = sorted(starts.items(), key=lambda kv: kv[1])

    def separates(name):
        """Does this handler reach a separator before it leaves?

        FOLLOWS FALL-THROUGH, which is the whole difficulty: labels are not
        boundaries here. `generic_airborn_hit` is two instructions and drops
        into `airborn_hit_no_sound`, which is where the separator call lives
        - stopping at the next label reports the busiest handler in the game
        as uncovered. So the walk continues past a label and stops only on
        an unconditional transfer.
        """
        if name not in starts:
            return None
        i = starts[name]
        for raw in L[i:i + 120]:
            c = strip_comment(raw)
            if RE_SEPARATOR.search(c):
                return True
            if re.search(r"\b(rets|retp|jauc|jruc|jump|die|sucide)\b", c):
                return False
        return False

    checked = []     # (reaction, line, a5 handler)
    unchecked = []   # (reaction, line)
    for i, raw in enumerate(L):
        c = strip_comment(raw)
        if re.search(r"\b(callr|calla|jsrp)\s+reaction_start_abc\b", c):
            a5 = None
            for j in range(i, max(-1, i - 30), -1):
                m = re.search(r"\bmovi\s+([A-Za-z_?][\w?]*)\s*,\s*a5\b",
                              strip_comment(L[j]))
                if m:
                    a5 = m.group(1)
                    break
            checked.append((labels[i], i + 1, a5))
        elif re.search(r"\b(callr|calla|jsrp)\s+reaction_start\b", c):
            unchecked.append((labels[i], i + 1))

    handlers = {}
    for _, _, a5 in checked:
        if a5 and a5 not in handlers:
            handlers[a5] = separates(a5)
    gaps = [(r, ln, a5) for r, ln, a5 in checked if handlers.get(a5) is False]
    bare = [(r, ln) for r, ln in unchecked if separates(r) is False]
    return dict(checked=checked, unchecked=unchecked, handlers=handlers,
                gaps=gaps, bare=bare)


def header_claims(bodies):
    """The routine name a boxed header says it documents, if it says one."""
    for b in bodies:
        m = re.match(r"^([A-Za-z_?][\w?]*)\s*(?:$|-+\s)", b.strip())
        if m:
            return m.group(1)
    return None


def scan_file(p, mne):
    """Comments, blocks, and the module banner for one source file."""
    lines = read_lines(p)
    label = None
    comments = []
    blocks = []
    pending = []          # the run of full-line comments being accumulated
    blanks = 0            # blank lines seen since that run ended
    banner = {}

    def flush(next_label):
        """Close the pending run.

        next_label is the column-0 label immediately below it, or None. The
        block belongs to THAT label, not to the one above it - a boxed header
        documents what follows, and attributing it backwards misfiles every
        documented routine in the tree by one.
        """
        nonlocal blanks
        if pending:
            kind = classify_block([c.body for c in pending], next_label)
            owner = next_label if kind == "header" else (next_label or label)
            blk = Block(list(pending), owner, kind)
            for c in pending:
                c.attached = (kind == "header")
                c.label = owner
            blocks.append(blk)
            pending.clear()
        blanks = 0

    for i, raw in enumerate(lines, 1):
        kind, body = comment_of(raw)
        if kind == "full":
            if body:
                m = RE_BANNER_FIELD.match(body)
                if m and m.group(1).lower() not in banner:
                    banner[m.group(1).lower()] = m.group(2).strip()
                if blanks:          # a gap splits one note from the next
                    flush(None)
                c = Comment(p, i, "full", body, label)
                comments.append(c)
                pending.append(c)
            continue

        code = strip_comment(raw).rstrip()
        if not code.strip():
            if not raw.strip():
                blanks += 1
                if blanks > 2:
                    flush(None)
            if kind == "inline" and body:
                comments.append(Comment(p, i, "inline", body, label))
            continue

        # A label in column 0 claims the comment block directly above it.
        m = RE_LABELDEF.match(code)
        if m and not code[0].isspace():
            tok = m.group(1)
            rest = code[len(tok):].lstrip()
            # `foo .set 1` / `foo equ 1` is a symbol; `foo` alone, or
            # `foo calla x`, is a routine a header can document.
            is_equate = bool(re.match(r"^(\.(set|equ)|equ)\b", rest, re.I))
            flush(None if is_equate else tok)
            label = tok
        else:
            flush(None)

        if kind == "inline" and body:
            comments.append(Comment(p, i, "inline", body, label))

    flush(None)
    return comments, blocks, banner


def tag_markers(comments):
    for c in comments:
        for name, pat, _ in MARKERS:
            if re.search(pat, c.body, re.I):
                c.markers.append(name)


def unwrap_disabled(c, mne):
    """A `;` in column 0 over an instruction that has its OWN comment.

    `;jreq fadeprcx ; allow negative entries (ejb)` is a disabled line whose
    trailing comment is a real note. Replace the body with that note rather
    than losing it with the instruction.
    """
    if ";" not in c.body:
        return False
    inner = c.body.split(";", 1)[1].lstrip("*; \t").strip()
    if not inner or is_disabled_code(inner, mne):
        return False
    c.body = inner
    c.from_disabled = True
    return True


def filter_comments(comments, mne, max_repeat):
    """Keep the commentary, drop the mechanism. Returns (kept, funnel)."""
    funnel = collections.Counter()
    survivors = []
    for c in comments:
        body = c.body.strip()
        if RE_BAR.match(body):
            funnel["separator rule"] += 1
            continue
        if is_disabled_code(body, mne) and not unwrap_disabled(c, mne):
            funnel["disabled code"] += 1
            continue
        survivors.append(c)

    # Counted AFTER unwrapping, so a note recovered from a disabled line is
    # weighed against its live twins rather than against the instruction.
    counts = collections.Counter(c.body.strip().lower() for c in survivors)

    kept = []
    for c in survivors:
        body = c.body.strip()
        # A routine header's input/output list IS its documentation, so the
        # register and repetition rules do not apply inside one.
        if c.markers or c.attached:
            kept.append(c)
            continue
        if counts[body.lower()] > max_repeat:
            funnel["repeated %d+ times (field label)" % (max_repeat + 1)] += 1
            continue
        if RE_REGNOTE.match(body) or RE_REGLIST.match(body):
            funnel["register bookkeeping"] += 1
            continue
        if RE_NUMERIC.match(body):
            funnel["bare number"] += 1
            continue
        if RE_YESNO.match(body):
            funnel["branch answer (yes/no)"] += 1
            continue
        if len(body.split()) < 3:
            funnel["under three words"] += 1
            continue
        kept.append(c)
    return kept, funnel


def md_escape(s):
    return s.replace("\\", "\\\\").replace("|", "\\|").replace("`", "'")


def fmt_block(blk, kept_set):
    """A block's surviving lines, trimmed of its box frame.

    Consecutive identical lines are collapsed: several boxes repeat their
    title three times for emphasis ("Body propelling moves"), which is
    charming in the source and noise in a list.
    """
    body = []
    for c in blk.comments:
        if id(c) not in kept_set:
            continue
        if RE_BAR.match(c.body):
            continue
        if body and body[-1] == c.body:
            continue
        body.append(c.body)
    return body


def build(src, max_repeat):
    files = source_files(src)
    if not files:
        raise SystemExit("no source files under %s" % src)
    mne = harvest_mnemonics(files)

    all_comments = []
    all_blocks = []
    banners = {}
    raw_total = 0
    for p in files:
        comments, blocks, banner = scan_file(p, mne)
        raw_total += len(comments)
        all_comments.extend(comments)
        all_blocks.extend(blocks)
        if banner:
            banners[p.name] = banner

    tag_markers(all_comments)
    kept, funnel = filter_comments(all_comments, mne, max_repeat)
    # Bodies recovered from disabled lines changed after tagging, so the
    # marker sections are built from what the document will actually print.
    for c in kept:
        c.markers = []
    tag_markers(kept)
    credits = credited_names(src)
    residue = [(note, grep_tree(src, pat)) for note, pat in RESIDUE]
    work = []
    for fname, pat, note in WORKAROUNDS:
        hits = [h for h in grep_tree(src, pat) if h[0] == fname]
        if not hits:
            raise SystemExit(
                "extract_dev_comments: a cited comment is gone - %s /%s/. "
                "Fix the citation in WORKAROUNDS." % (fname, pat))
        work.append((fname, hits, note))
    for note, hits in residue:
        if not hits:
            raise SystemExit(
                "extract_dev_comments: RESIDUE citation found nothing - %s"
                % note)

    return dict(files=files, mne=mne, comments=all_comments, blocks=all_blocks,
                banners=banners, kept=kept, funnel=funnel, raw=raw_total,
                src=src, max_repeat=max_repeat, credits=credits,
                clues=read_clue_table(src), residue=residue, work=work,
                dated=dated_notes(kept, credits),
                initialed=initialed_notes(kept, credits,
                                          dated_notes(kept, credits)),
                juggle=count_calls(src, JUGGLE_ROUTINES),
                air=audit_airborne(src))


def render_md(d):
    kept_set = {id(c) for c in d["kept"]}
    out = io.StringIO()
    w = out.write

    by_marker = collections.OrderedDict((n, []) for n, _, _ in MARKERS)
    for c in d["kept"]:
        for m in c.markers:
            by_marker[m].append(c)

    # Blocks that document the label beneath them, and everything else.
    headers = collections.defaultdict(list)
    loose = collections.defaultdict(list)
    for blk in d["blocks"]:
        body = fmt_block(blk, kept_set)
        if not body:
            continue
        name = blk.comments[0].path.name
        if blk.kind == "header":
            headers[name].append((blk, body))
        else:
            loose[name].append((blk, body))

    inline_kept = [c for c in d["kept"] if c.kind == "inline"]
    n_headers = sum(len(v) for v in headers.values())
    n_loose = sum(len(v) for v in loose.values())

    w("# What the original source says about itself\n\n")
    w("Every comment Midway's programmers left in the leaked Mortal Kombat 2\n")
    w("source, filtered down to the ones that carry intent rather than\n")
    w("bookkeeping, and grouped by the module and routine they sit in.\n\n")
    w("Generated by `tools/extract_dev_comments.py` from the **read-only**\n")
    w("tree at `%s` - retail's source, never this\n" % rel_to_root(d["src"]))
    w("project's modified `src/`. Regenerate with:\n\n")
    w("```\npython tools/extract_dev_comments.py\n```\n\n")
    w("The companion `doc/original_source_comments.csv` holds **every**\n")
    w("surviving comment with its `file:line`, including the inline ones this\n")
    w("page leaves out - grep that, read this.\n\n")
    w("> Comment text is reproduced verbatim, lower-case and typos included.\n")
    w("> Midway's spelling is part of the record: `sucide`, `kluge`, `pallette`,\n")
    w("> `interupt`. Backticks are flattened to quotes so the tables render.\n")
    w(">\n")
    w("> A boxed line that stops mid-word is the SOURCE doing that, not this\n")
    w("> tool: the `*` box is a fixed 72 columns and the right-hand frame cut\n")
    w("> the ends off sentences (`...from this table of routi *`). The text is\n")
    w("> reproduced as written.\n\n")

    # ---------------------------------------------------------------- funnel
    w("## How much of it is commentary\n\n")
    w("The ratio is the whole problem: a flat dump of the comment lines is\n")
    w("unreadable, because most of them are table field labels and register\n")
    w("notes. What the filter removed, and why:\n\n")
    w("| | lines |\n|---|---:|\n")
    w("| Comment-bearing lines in the tree | %d |\n" % d["raw"])
    for k, v in d["funnel"].most_common():
        w("| - dropped: %s | %d |\n" % (k, v))
    w("| **Kept** | **%d** |\n" % len(d["kept"]))
    w("\n%d of the survivors trail an instruction and live in the CSV only.\n"
      % len(inline_kept))
    w("The other %d are whole-line notes, which group into %d documented\n"
      % (len(d["kept"]) - len(inline_kept), n_headers))
    w("routine headers and %d loose notes - the body of this page.\n\n"
      % n_loose)
    w("Scanned %d files (`%s`); %d mnemonics, directives and macros were\n"
      % (len(d["files"]), " ".join(e.lstrip(".") for e in EXTS), len(d["mne"])))
    w("harvested from the live code to drive the disabled-code detector.\n\n")

    # ----------------------------------------------------------- conventions
    w("## The conventions the source comments itself with\n\n")
    w("These are Midway's, found by counting rather than assumed:\n\n")
    w("**`ejb` is Ed Boon's initials, and it is a marker.** It appears three\n")
    w("ways. `(ejb)` or `(ejb - 2/5/93)` signs a note or records where a\n")
    w("routine was lifted from - `snagged from nba jam to work on the t-unit`.\n")
    w("`ejbejbejb` is a come-back-to-this flag, deliberately unsearchable by\n")
    w("accident. `ejbpatch` marks something to be careful of when patching a\n")
    w("burned ROM. `ejbbug` in `SYSEQU.ASM` gates the debug branches and is\n")
    w("`0`, so every `.if ejbbug` block in the leak is dead code.\n\n")
    w("**The `ermac` macro is an ERROR MACRO, and the source proves it.** Its\n")
    w("body in `MACROS.HDR` is one live line, `jauc $` - an infinite loop -\n")
    w("but the three lines commented out directly above that are the reporter\n")
    w("it used to be: save `a0` into `trapram`, load an `error code #`, call\n")
    w("`errort`. Whatever the arcade legend made of the name, in this tree it\n")
    w("is er-mac, and all it does now is hang the board under the comment\n")
    w("`b_debug ---> bring attention !!!`.\n\n")
    w("**`???` is usually a QUESTION ASKED OF THE CODE, not a doubt.** MK2's\n")
    w("idiom puts it on the line that tests something - `projectile in the air\n")
    w("???`, `am I in shang form ???` - so the section below reads as a list of\n")
    w("the conditions the game asks about, with only a few real uncertainties\n")
    w("among them (`8 meg parts ???`). `!!!` is emphasis and sound cues, not\n")
    w("warnings; the actual warnings say `warning`, `beware` or `note:`.\n\n")
    w("**The file banner names the module in the author's own words** - and\n")
    w("`game software: Ed Boon` on %d files is the authorship record.\n\n"
      % sum(1 for b in d["banners"].values()
            if "ed boon" in (b.get("game software", "") + b.get("programmer", "")).lower()))

    # --------------------------------------------------------------- modules
    w("## The modules, as the source describes them\n\n")
    w("| File | `module:` | credited |\n|---|---|---|\n")
    for name in sorted(d["banners"]):
        b = d["banners"][name]
        mod = b.get("module", "")
        who = b.get("game software") or b.get("programmer") or ""
        if not mod and not who:
            continue
        w("| [%s](../../mk2-readonly/mk2-main/src/%s) | %s | %s |\n"
          % (name, name, md_escape(mod) or "-", md_escape(who) or "-"))
    w("\n")

    # ------------------------------------------------- what they left out
    w("## What the source says it left out\n\n")
    w("The comments are the wrong place to look for this, and that is worth\n")
    w("stating plainly: there is **no schedule-pressure vocabulary in the\n")
    w("tree at all**. Not one real hit for `no time`, `if we have time`,\n")
    w("`would be nice`, `todo`, `not finished`, `unfinished`, `someday`,\n")
    w("`take out` or `add back`. The only `no time` is the round clock.\n")
    w("Whatever was cut, nobody journalled about it in the source.\n\n")
    if d["clues"]:
        w("**The shipped game lists its own absences instead.**\n")
        w("`clue_table` in `MKEND.ASM` is the %d lines the ending rotates,\n"
          % len(d["clues"]))
        w("read straight out of the table here:\n\n")
        w("| | line | |\n|---:|---|---|\n")
        for n, (name, s, un) in enumerate(d["clues"], 1):
            w("| %d | %s | %s |\n" % (n, md_escape(s),
                                      md_escape(un) if un else ""))
        w("\nFour are scrambled, and two of those are flat denials. Three of\n")
        w("the things teased - Smoke, Jade, and Friendship/Babality - were\n")
        w("really in MK2; the rest went to MK3.\n\n")
    if d["residue"]:
        w("**MK1's Kano and Sonya never left the code.** They were cut as\n")
        w("fighters and their moves renamed onto other characters, but the\n")
        w("comments were not - so the mechanics still carry the old names:\n\n")
        for note, hits in d["residue"]:
            w("- %s\n" % note)
            for f, ln, b in hits[:4]:
                w("  - `%s:%d` %s\n" % (f, ln, md_escape(b)))
        w("\nThat is not cutting under pressure. That is working code nobody\n")
        w("wanted to touch.\n\n")
    if d["dated"]:
        w("**The only schedule trail in the tree is a handful of comments\n")
        w("signed with initials and a date.** ")
        known = {}
        for c, ini, date, name in d["dated"]:
            if name:
                known[ini] = name
        if known:
            w("The credits in `MKEND.ASM` decode them: %s.\n"
              % ", ".join("`%s` = %s" % (k, v) for k, v in sorted(known.items())))
        w("\n")
        w("| where | signed | dated | note |\n|---|---|---|---|\n")
        for c, ini, date, name in d["dated"]:
            w("| `%s:%d` | %s | %s | %s |\n"
              % (c.path.name, c.line, name or "-", date, md_escape(c.body)))
        for c, ini, name in d.get("initialed") or []:
            w("| `%s:%d` | %s | - | %s |\n"
              % (c.path.name, c.line, name, md_escape(c.body)))
        w("\nThat table is also the tree's LINEAGE, in date order: the\n")
        w("background code carries a `modification for football (4/3/90)`,\n")
        w("the operator menus were already being edited in 1990-92, the\n")
        w("decompressor was `Modified: Shawn Liptak, 8/13/92 - Basketball`,\n")
        w("and two routines are `snagged from nba jam to work on the t-unit\n")
        w("(ejb - 2/5/93)`. MK2 is a game assembled on top of several\n")
        w("others, and the comments never stopped naming them.\n\n")
        w("The newest entries are **after MK2 was on location**, and they are\n")
        w("in operator, coin and audit plumbing rather than the game -\n")
        w("shared Midway system code that outlived the project. Nobody was\n")
        w("adding game features in this snapshot.\n\n")

    # -------------------------------------------- what they were fixing
    w("## What they were working around\n\n")
    w("Named bugs and admitted workarounds, each verified against the tree\n")
    w("when this page was generated - a citation that stops matching fails\n")
    w("the tool rather than going stale.\n\n")
    for fname, hits, note in d["work"]:
        where = ", ".join(str(h[1]) for h in hits[:6])
        more = " +%d" % (len(hits) - 6) if len(hits) > 6 else ""
        w("- **`%s`** - `%s:%s`%s\n" % (md_escape(hits[0][2]), fname, where, more))
        w("  - %s\n" % note)
    w("\n")

    jr = d["juggle"]
    air = d["air"]
    if air and all(jr[n][0] for n in JUGGLE_ROUTINES):
        w("### The anti-juggle rule, audited\n\n")
        w("`no_unlimited_airhits` (`MKREACT.ASM:%d`) carries a boxed header\n"
          % jr["no_unlimited_airhits"][0][1])
        w("that states a POLICY in Midway's own words - *\"Dudes who get hit\n")
        w("in the air use should call this to ensure that there is a limits\n")
        w("to the number of times they can get hit in the air\"* (typos\n")
        w("theirs). Its sibling `repell_on_a1_hit` (`MKREACT.ASM:%d`) does\n"
          % jr["repell_on_a1_hit"][0][1])
        w("the same with a caller-chosen threshold **plus an\n")
        w("`am_i_close_to_edge` test**, so it separates at the wall\n")
        w("whatever the count. Both end at `repell_attacker`, which hands\n")
        w("the ATTACKER to `attacker_getting_separated`. Every one of its\n")
        w("callers passes `4` and comments it `avoid hacky sack` - Midway's\n")
        w("own name for anti-juggle, and the \"four hit push back\".\n\n")
        w("**Counting the direct callers of those two routines is\n")
        w("misleading, and this page said so once.** `reaction_start_abc`\n")
        w("raises a flag; at `rst5` an airborne victim is `jump`ed to\n")
        w("whatever handler the caller left in `a5` and the reaction's own\n")
        w("script never runs at all. The rule is therefore applied at that\n")
        w("FUNNEL, and what matters is which `a5` handlers separate:\n\n")
        w("| airborne handler | reactions routed to it | separates |\n")
        w("|---|---:|---|\n")
        counts = collections.Counter(a5 for _, _, a5 in air["checked"])
        for h, n in counts.most_common():
            w("| `%s` | %d | %s |\n"
              % (h, n, "yes" if air["handlers"].get(h) else "**NO**"))
        w("\nSo %d of the %d reactions that make the airborne check are\n"
          % (len(air["checked"]) - len(air["gaps"]), len(air["checked"])))
        if air["gaps"]:
            w("covered. The gaps are of two kinds.\n\n")
        else:
            w("covered - every handler separates. What is left is the\n")
            w("reactions that never make the check at all.\n\n")
        if air["gaps"]:
            w("**1. A handler that skips it** (%d reaction%s):\n\n"
              % (len(air["gaps"]), "" if len(air["gaps"]) == 1 else "s"))
            for r, ln, a5 in air["gaps"]:
                w("- `%s` (`MKREACT.ASM:%d`) -> `%s`\n" % (r, ln, a5))
            w("\n`ar_lkzap` is `generic_airborn_hit`'s body verbatim - same\n")
            w("velocities, same `flight`, same `land_on_my_back` - minus the\n")
            w("sound, the `act_reacting` write and the separator call, with\n")
            w("gravity `07000h` where the generic one uses `08000h`. It\n")
            w("reads as a copy that dropped one line.\n\n")
        w("**2. Reactions that never make the check** - %d of them call\n"
          % len(air["unchecked"]))
        w("plain `reaction_start`, so their script runs whether the victim\n")
        w("is on the floor or in the air, and none of them separates:\n\n")
        for r, ln in air["bare"]:
            w("- `%s` (`MKREACT.ASM:%d`)\n" % (r, ln))
        w("\nThat list is not a defect list. Several are correct as they\n")
        w("stand - a stage fatality, a pit fall, the Rain cloud that holds\n")
        w("the victim, and `r_decoy_airborn`, which IS the airborne variant\n")
        w("- and several end with the victim on the floor, which closes the\n")
        w("string anyway. It is the set to READ before changing anything.\n\n")
        w("**And the counter stays the limiting factor.** All of it reads\n")
        w("the `p_hit` that the entry above admits was not being zeroed, so\n")
        w("widening the rule without fixing the count builds on sand - which\n")
        w("is measured here, not predicted: `p_hit` never exceeded 1 through\n")
        w("a corner roundhouse string (`doc/CORNER_ROUNDHOUSE.md`) and\n")
        w("oscillated 0<->1 through Ermac's slam loop\n")
        w("(`doc/ERMAC_TELESLAM_REGRAB.md`).\n\n")

    # --------------------------------------------------------------- markers
    w("## Markers\n\n")
    w("Every comment carrying one of the leak's own flags, kept regardless of\n")
    w("the other filters. These are where the programmers told on themselves.\n\n")
    for name, _pat, title in MARKERS:
        rows = by_marker.get(name) or []
        if not rows:
            continue
        # One entry per distinct note. The same line at 17 sites is one
        # decision repeated, not 17 notes - and listing it 17 times buries
        # the ones that only happen once.
        groups = collections.OrderedDict()
        for c in sorted(rows, key=lambda c: (c.path.name, c.line)):
            groups.setdefault(c.body.strip().lower(), []).append(c)
        w("### %s (%d notes, %d sites)\n\n" % (title, len(groups), len(rows)))
        for body_l, cs in groups.items():
            where = []
            last = None
            for c in cs[:6]:
                nm = c.path.name
                where.append("%d" % c.line if nm == last else "%s:%d" % (nm, c.line))
                last = nm
            more = (" +%d more" % (len(cs) - 6)) if len(cs) > 6 else ""
            w("- %s - `%s`%s\n"
              % (md_escape(cs[0].body.strip()), ", ".join(where), more))
        w("\n")

    # ---------------------------------------------------- per-file commentary
    w("## The commentary, by module\n\n")
    w("Documented routines first (the boxed headers), then the loose notes,\n")
    w("each under the nearest column-0 label above it.\n\n")

    byfam = collections.defaultdict(list)
    for p in d["files"]:
        byfam[family_of(p.stem.upper())].append(p)

    for fam in FAMILY_ORDER:
        fams = byfam.get(fam) or []
        fams = [p for p in fams if headers.get(p.name) or loose.get(p.name)]
        if not fams:
            continue
        w("### %s\n\n" % fam)
        for p in fams:
            name = p.name
            hd = headers.get(name) or []
            lo = loose.get(name) or []
            w("#### %s\n\n" % name)
            b = d["banners"].get(name, {})
            if b.get("module"):
                w("*%s*\n\n" % md_escape(b["module"]))
            if hd:
                w("**Documented routines**\n\n")
                for blk, body in hd:
                    claims = header_claims(body)
                    note = ""
                    if claims and claims.lower() != (blk.label or "").lower():
                        # Midway's own misfiling: a box documenting one entry
                        # point sitting above another. Reported, not corrected.
                        note = " - header names `%s`" % claims
                    w("- **`%s`** (`%s:%d`)%s\n"
                      % (blk.label, name, blk.comments[0].line, note))
                    for ln in body:
                        w("  - %s\n" % md_escape(ln))
                w("\n")
            if lo:
                w("**Notes**\n\n")
                for blk, body in lo:
                    if not blk.label:
                        where = "top of file"
                    elif blk.kind == "banner":
                        where = "above `%s`" % blk.label
                    else:
                        where = "in `%s`" % blk.label
                    w("- %s (`%s:%d`)\n"
                      % (where, name, blk.comments[0].line))
                    for ln in body:
                        w("  - %s\n" % md_escape(ln))
                w("\n")

    w("---\n\n")
    w("Generated %s from %s. Do not hand-edit: re-run the tool.\n"
      % (datetime.date.today().isoformat(), rel_to_root(d["src"])))
    return out.getvalue()


def rel_to_root(p):
    try:
        s = str(pathlib.Path(p).resolve().relative_to(ROOT.parent))
    except ValueError:
        s = str(p)
    return s.replace("\\", "/")


def render_csv(d):
    out = io.StringIO()
    wr = csv.writer(out, lineterminator="\n")
    wr.writerow(["file", "line", "kind", "label", "markers", "recovered",
                 "comment"])
    for c in sorted(d["kept"], key=lambda c: (c.path.name, c.line)):
        wr.writerow([c.path.name, c.line,
                     "header" if (c.kind == "full" and c.attached) else c.kind,
                     c.label or "", " ".join(c.markers),
                     # the note was the trailing comment on a disabled line
                     "disabled-line" if c.from_disabled else "",
                     c.body])
    return out.getvalue()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--src", default=str(READONLY),
                    help="source tree to read (default: the read-only retail tree)")
    ap.add_argument("--out-md", default=str(OUT_MD))
    ap.add_argument("--out-csv", default=str(OUT_CSV))
    ap.add_argument("--max-repeat", type=int, default=3,
                    help="a comment body appearing more times than this is a "
                         "field label, not commentary (default 3)")
    ap.add_argument("--stats", action="store_true",
                    help="print the filter funnel and write nothing")
    ap.add_argument("--check", action="store_true",
                    help="fail if the committed outputs differ from a fresh run")
    ap.add_argument("--grep", metavar="PATTERN",
                    help="print every surviving comment matching PATTERN")
    args = ap.parse_args(argv)

    src = pathlib.Path(args.src)
    if not src.is_dir():
        print("extract_dev_comments: no source tree at %s" % src, file=sys.stderr)
        return 2
    d = build(src, args.max_repeat)

    if args.grep:
        rx = re.compile(args.grep, re.I)
        n = 0
        for c in sorted(d["kept"], key=lambda c: (c.path.name, c.line)):
            if rx.search(c.body):
                print("%s:%d  %s" % (c.path.name, c.line, c.body))
                n += 1
        print("\n%d matches" % n, file=sys.stderr)
        return 0

    if args.stats:
        print("source     %s" % rel_to_root(src))
        print("files      %d" % len(d["files"]))
        print("mnemonics  %d (harvested)" % len(d["mne"]))
        print("raw        %d comment-bearing lines" % d["raw"])
        for k, v in d["funnel"].most_common():
            print("  -%-42s %6d" % (k, v))
        print("kept       %d" % len(d["kept"]))
        marked = sum(1 for c in d["kept"] if c.markers)
        print("  markers  %d" % marked)
        return 0

    md = render_md(d)
    cs = render_csv(d)

    if args.check:
        bad = []
        for path, text in ((args.out_md, md), (args.out_csv, cs)):
            p = pathlib.Path(path)
            old = p.read_text(encoding="utf-8") if p.exists() else None
            # The generation date is the one line allowed to differ.
            if old is not None:
                old_n = re.sub(r"^Generated \d{4}-\d\d-\d\d ", "Generated ", old, flags=re.M)
                new_n = re.sub(r"^Generated \d{4}-\d\d-\d\d ", "Generated ", text, flags=re.M)
            else:
                old_n, new_n = None, text
            if old_n != new_n:
                bad.append(p.name)
        if bad:
            print("extract_dev_comments: FAIL - %s differ from a fresh run; "
                  "re-run `python tools/extract_dev_comments.py`" % ", ".join(bad),
                  file=sys.stderr)
            return 1
        print("extract_dev_comments: OK - %d comments, %d files"
              % (len(d["kept"]), len(d["files"])))
        return 0

    pathlib.Path(args.out_md).write_text(md, encoding="utf-8")
    pathlib.Path(args.out_csv).write_text(cs, encoding="utf-8")
    print("wrote %s (%.0f KB)" % (args.out_md, len(md) / 1024.0))
    print("wrote %s (%d rows)" % (args.out_csv, len(d["kept"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
