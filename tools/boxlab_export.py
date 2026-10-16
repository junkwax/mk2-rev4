#!/usr/bin/env python3
"""
boxlab_export.py - build the PUBLIC data set for boxlab from the private tree.

boxlab is a SEPARATE repository, checked out beside this one (../boxlab), and
served from GitHub Pages.  It is deliberately not a subdirectory here: keeping
it out of this working tree means there is nothing for `git add -A` to sweep
up, and no subtree split that could carry this project's commit messages -
which routinely name source files and routines - into a public history.

Everything it holds has to survive a stranger reading it, so this exporter
obeys one rule:

  NOTHING LEAVES HERE THAT WE DID NOT WRITE OURSELVES.

Not the assembler symbols (`stk_lkhikick`), not the lane labels
(`a_lkstance`), and - the one a blacklist misses - not the ART NAMES
(`LKWALK1`, `UGSWIPE3`, `TMLOKICK1`).  Those are uppercase with no underscore,
so hitbox_pack's SYMBOLISH regex sails straight past them.  So the audit here
is a WHITELIST: every string in every emitted file must match a pattern this
file defines, or the export aborts.  A blacklist is a list of the leaks you
thought of; a whitelist is a list of the things you meant to publish.

What gets written:

  ../boxlab/data/boxes.json   strike boxes.  This IS a hitbox_pack pack - the
                           same format `hitbox_pack.py import --apply` reads
                           back - so the public file and the ROM cannot drift.
  ../boxlab/data/poses.json   pose geometry: every pose as a list of RECTANGLES,
                           placed the way ani2 places them.  No pixels.  This
                           is the honest picture of what MK2 tests against,
                           because MK2 does not test sprites - it tests the
                           bounding box of these rectangles.
  ../boxlab/data/frames.json  startup / active / recovery / advantage, joined
                              to the public move ids.

  python tools/boxlab_export.py                  write all three
  python tools/boxlab_export.py --check          fail if the checkout is stale
  python tools/boxlab_export.py --out PATH       a checkout kept elsewhere
"""
import argparse
import collections
import csv
import datetime
import glob
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
sys.path.insert(0, ROOT)

# boxlab lives OUTSIDE this tree, as a sibling - it is a separate repository
# with its own history, and the one thing that must never happen is its
# contents arriving in a commit here. Keeping it out of the working tree is a
# stronger guarantee than any .gitignore: there is nothing for `git add -A` to
# pick up, and nothing for a subtree split to carry commit messages into.
#
#   ../boxlab               the default
#   BOXLAB_DIR=...          override for a checkout kept somewhere else
#   --out PATH              override for one run
DEFAULT_OUT = os.environ.get(
    "BOXLAB_DIR", os.path.join(os.path.dirname(ROOT), "boxlab"))

# The tree the strike tables are read from. Normally this one; --source points
# it at another checkout so the same parser can produce a retail reference.
# Set by main(); everything below reads it rather than assuming ROOT.
SOURCE = ROOT


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BA = _load("ba", os.path.join(ROOT, "tools", "box_align_audit.py"))
HL = _load("hl", os.path.join(ROOT, "tools", "hurtbox_lock.py"))
HP = _load("hp", os.path.join(ROOT, "tools", "hitbox_pack.py"))

FORMAT_VERSION = 1

# ---------------------------------------------------------------- the cast --
# BA.CHARS index -> (public handle, display name).
#
# These are NOT the characters' names.  A trademarked name would have been
# defensible - nominative use is what every wiki makes - but a handle costs
# nothing and is the stronger position, so boxlab publishes handles and no
# trademarked character name appears in any file this exporter writes.
#
# Five of them (Hathead, Sword Arms, Knockout, Bombshell, Final Boss) are how
# the developers described those fighters in passing.  The other twelve were
# coined.  Either way they describe what is on screen, which is the only thing
# a hitbox viewer needs them to do.  See ../boxlab/NOTICE.md.
CAST = [
    ("hathead",   "Hathead"),
    ("headband",  "Headband"),
    ("shades",    "Shades"),
    ("swordarms", "Sword Arms"),
    ("knockout",  "Knockout"),
    ("bombshell", "Bombshell"),
    ("morphman",  "Morphman"),
    ("bolt",      "Bolt"),
    ("frosty",    "Frosty"),
    ("acid",      "Acid"),
    ("harpoon",   "Harpoon"),
    ("bigarms",   "Big Arms"),
    ("fourarms",  "Four Arms"),
    ("final-boss", "Final Boss"),
    ("2ndhand",   "2nd Hand"),
    ("blackout",  "Blackout"),
    ("pole",      "Pole"),
]

# --------------------------------------------------------- public record ids --
# hitbox_pack.SLUG and box_align_audit.CHAR_LIST have their own vocabulary for
# the cast, and it is not this one.  That is deliberate, and it is the same
# choice SLOT_WORDS makes below: a TRANSLATION TABLE, not a passthrough.
#
# Two reasons, and the second is the one that matters.
#
#   The private words are the game's - `lk`, `fn`, `go`, `sa` - and stopping
#   those crossing is what this file is for.
#
#   doc/balance.lock pins every record under the private id, and Phase D fails
#   the build when that file moves.  So the private ids CANNOT be renamed to
#   match the public ones without churning the lock for a cosmetic reason.
#   Translating here means either side can be renamed without the other
#   noticing: hitbox_pack goes on patching MKSTK.ASM under the ids the lock
#   already uses, and boxlab gets handles chosen for people who have never
#   seen the source.
TABLE_WORDS = {
    "kung-lao":       "hathead",
    "liu-kang":       "headband",
    "johnny-cage":    "shades",
    "baraka":         "swordarms",
    "kitana-mileena": "female-ninjas",
    "shang-tsung":    "morphman",
    "raiden":         "bolt",
    "ninjas":         "ninjas",
    "jax":            "bigarms",
    "goro-kintaro":   "fourarms",
    "shao-kahn":      "final-boss",
    "shared":         "shared",
}

# Move suffixes that carry a name across on their own, keyed by the PRIVATE
# table they belong to so a rename on one side cannot silently match on the
# other.
MOVE_WORDS = {
    ("goro-kintaro", "ro-fireball"):    "fireball",
    ("goro-kintaro", "ro-kick"):        "kick",
    ("goro-kintaro", "ro-punch"):       "punch",
    ("goro-kintaro", "ro-uppercut"):    "uppercut",
    ("kitana-mileena", "jade-boom"):    "pole-boom",
    ("kitana-mileena", "kano"):         "ball-roll",
    ("shang-tsung", "kano-ball"):       "ball-roll",
    ("ninjas", "noob-dive"):            "blackout-dive",
    ("ninjas", "noob-kick"):            "blackout-kick",
    ("ninjas", "noob-portal"):          "blackout-portal",
    ("ninjas", "noob-slide"):           "blackout-slide",
    ("shared", "lk-wheel"):             "hb-wheel",
    ("shared", "lklokick-early"):       "hb-lokick-early",
    # The source's own abbreviations and trademarked names, which passed
    # straight through until PUBLIC_MOVES below made every name an opt-in.
    ("goro-kintaro", "ro-backhand"):    "backhand",
    ("goro-kintaro", "ro-facesmash"):   "facesmash",
    ("kitana-mileena", "jade-boom-ret"): "pole-boom-ret",
    ("kung-lao", "super-rep"):          "super-acid",
    ("ninjas", "noob-ghost"):           "blackout-ghost",
    ("ninjas", "noob-slam"):            "blackout-slam",
    ("ninjas", "rain-bolt"):            "purp-bolt",
    ("ninjas", "rain-roundh"):          "purp-roundh",
    ("ninjas", "rain-zap"):             "purp-zap",
    ("ninjas", "rp-superk"):            "acid-superk",
    ("ninjas", "sc-swipe"):             "harpoon-swipe",
    ("shared", "ermac-teleport"):       "souls-teleport",
    ("shared", "ermac-teleslam"):       "souls-teleslam",
    ("shared", "ermac-zap"):            "souls-zap",
    ("shared", "hhescape"):             "hat-escape",
    ("shared", "hhescdive"):            "hat-escdive",
    ("shared", "lkdubknee"):            "hb-dubknee",
    ("shared", "lkknee-link"):          "hb-knee-link",
    ("shared", "stelbow-end"):          "mm-elbow-end",
}

# Every move name boxlab may publish, AFTER translation.  A whitelist, for the
# same reason the data audit is one: MOVE_WORDS only catches the names someone
# remembered to add, and for a while it was the only gate.  New moves passed
# through under the source's own words - `noob-`, `rain-`, `ermac-`, `rp-`,
# `lk`, `hh`, `st` - and validate.py could not see it, because it checks the
# shape of an id and those are all well-shaped.  Now a move nobody has named
# for the public aborts the export, and naming it is a decision someone makes.
#
# Adding one: say what it IS on screen, use the handles (CAST) for whose it is,
# and never an abbreviation of a character's real name.
PUBLIC_MOVES = frozenset("""
    2-tele 2ndknee acid-superk airshadow airshadow2 backflip backhand ball-roll
    bang bigpow bike blackout-dive blackout-ghost blackout-kick blackout-portal
    blackout-slam blackout-slide charge dbuc decoy dive duckkickh duckkickl
    duckpunch dummy elbow eyeshot facesmash fan-swipe fans fireball flipk
    flipkick flipp floor-ice grab hammer hamtop harpoon-swipe hat hat-escape
    hat-escdive hb-dubknee hb-knee-link hb-lokick-early hb-wheel hikick hipunch
    ice1 ice2 jumpupk jumpupp kick knee lokick lopunch mm-elbow-end nitro noogy
    nupower oldskull pole-boom pole-boom-ret portal powerp pp punch purp-bolt
    purp-roundh purp-zap roundh roundpunch scissor shadow shoruken shred skull1
    skull2 slam slide sonic sonic-l sonic-m souls-teleport souls-teleslam
    souls-zap spark1 spark2 spear spin spinchop spinfan spit1 spit2 split
    square super super-acid superf sweepk swipe swordkick tornado tsai
    uppercut zap zap1 zap2 zap3 zap4
""".split())


def public_id(rid):
    """A private record id, translated.  Fails closed.

    An unknown table means someone added one privately and it has no handle
    yet.  Publishing it would leak the source's own word for that character,
    which is the single thing this file exists to prevent - so it aborts the
    export rather than guessing or passing it through.  An unknown MOVE
    name is refused for the same reason: see PUBLIC_MOVES.
    """
    slug, sep, suffix = rid.partition("/")
    if not sep:
        return rid
    if slug not in TABLE_WORDS:
        raise SystemExit(
            "boxlab_export: no public handle for table %r (record %r).\n"
            "Add it to TABLE_WORDS. Publishing it as-is would put the "
            "source's own name for that character in a public file."
            % (slug, rid))
    move = MOVE_WORDS.get((slug, suffix), suffix)
    if move not in PUBLIC_MOVES:
        raise SystemExit(
            "boxlab_export: no public name for move %r (record %r).\n"
            "Add a translation to MOVE_WORDS, or the name itself to "
            "PUBLIC_MOVES once you are sure it carries no character name or "
            "source abbreviation." % (move, rid))
    return "%s/%s" % (TABLE_WORDS[slug], move)


def public_table(slug):
    """A private table slug, translated. Same contract as public_id."""
    if slug not in TABLE_WORDS:
        raise SystemExit("boxlab_export: no public handle for table %r. "
                         "Add it to TABLE_WORDS." % slug)
    return TABLE_WORDS[slug]

# frame_advantage.csv's `char` column -> our index.  Its vocabulary is the
# source's, not ours.
CSV_CHAR = {"hathead": 0, "liu kang": 1, "cage": 2, "baraka": 3, "kitana": 4,
            "mileena": 5, "shang": 6, "raiden": 7, "sub-zero": 8,
            "reptile": 9, "scorpion": 10, "jax": 11, "kintaro": 12,
            "shao kahn": 13, "smoke": 14, "noob": 15, "jade": 16}

# The defensive ani1 slots we publish, and OUR word for each.  Deliberately a
# translation table and not a passthrough: slot_names() reads its descriptions
# out of comments in the source, and those comments are Midway's text.  A slot
# whose description is not in here is dropped rather than guessed at, so a
# renumbering upstream loses a lane instead of mislabelling one.
SLOT_WORDS = {
    "stance": "stance",
    "walk forward": "walk-forward",
    "walk backward": "walk-backward",
    "skip forward": "skip-forward",
    "skip backward": "skip-backward",
    "duck animation": "duck",
    "jump straight up": "jump-up",
    "forward flip": "jump-forward",
    "backward flip": "jump-backward",
    "turn around": "turn",
    "turn around while ducking": "turn-ducking",
    "hit high": "hit-high",
    "hit low": "hit-low",
    "hit while ducking": "hit-ducking",
    "normal getup": "getup",
    "sweep fall": "sweep-fall",
    "getup from sweep kick": "getup-sweep",
    "stumble back": "stumble",
    "stunned": "stunned",
    "block": "block",
}


def git_commit(cwd=None):
    """The short commit of a tree, or None.

    None is a legitimate answer, not a failure: a retail reference is read out
    of a plain checkout with no history, and stamping it with THIS repository's
    commit would be a lie about where the numbers came from.
    """
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                             cwd=cwd or SOURCE,
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or None
    except Exception:
        return None


def meta(title, digest_value):
    return {
        "title": title,
        "generated": datetime.date.today().isoformat(),
        "source_commit": git_commit(),
        "digest": digest_value,
        "units": "pixels, relative to the anchor; +x is forward, +y is down",
        "public": True,
    }


# ------------------------------------------------------------------- boxes --
def collision_model():
    """WHICH model this build tests with, in our vocabulary, not the source's.

    The pack has always carried the strike boxes and never carried the rule
    that interprets them, so boxlab's index.html hardcoded one - and it
    hardcoded the wrong one. `sq_punch` has two branches, and the retail branch
    it implements has not been the shipping one since the column was re-anchored
    on the anipoint. Measured drift between the two: median 5.5 px, worst 60,
    and 2.89% of all hit/miss verdicts (tools/box_model_lab.py).

    Publishing the switches means the page can draw what the game does, and
    means flipping one of them cannot silently make the public page wrong.
    """
    eq = HP.HE.parse_equates()

    def on(name):
        return bool(eq.get(name, 0))

    return {
        # where the narrowed hit column is centred
        "column": "anchor" if on("anchorcol") else "silhouette",
        # The divisor is a switch, not a constant. It was hardcoded to 4 here
        # and the pack went on claiming a quarter after JOY.ASM had moved to a
        # half - the drift this block exists to prevent, reintroduced one
        # field below the comment saying so.
        "column_divisor": int(eq.get("colnarrow", 4) or 4),
        # HOW the anchored column's width is derived, which is not the same
        # question as where it is centred and was missing from the first
        # version of this block. "shift" is 2*(W>>3), what anchoring shipped
        # with; "retail" is W - 2*((W>>3)+(W>>2)), the width it was always
        # documented as keeping. They differ by up to 5px, so a viewer that
        # assumed one would be wrong the moment the switch moved - the exact
        # failure this whole block exists to prevent.
        # sq_punch has THREE branches, not two. colwidth off is "shift";
        # colwidth on with colnarrow at 4 is "retail"; colwidth on with any
        # other colnarrow is a plain `srl colnarrow/2` on the full width,
        # which is neither - hence "divisor", read together with
        # column_divisor above. Only powers of two are real: the 34010 has no
        # divide, so colnarrow 3 would assemble as a shift of 1.
        "column_width": ("retail" if int(eq.get("colnarrow", 4) or 4) == 4
                         else "divisor") if on("colwidth") else "shift",
        # the strike box tested against each sprite piece instead of one
        # collapsed, narrowed box
        "per_piece": on("perpiece"),
        # a move's box allowed to change across its own active window
        "phased_boxes": on("stkphase"),
    }


def build_boxes(retail=False):
    """The strike boxes, as a hitbox_pack pack - byte-compatible with import."""

    class Args:
        public = True
        title = "Strike boxes"
        author = ""
        description = ("Every strike box in the build. This file is the one "
                       "that is applied back to the game, not a copy of it.")

    # Translate the ids BEFORE the pack is built, so pack["moves"], by_id and
    # the flags map all agree on one vocabulary instead of two.
    _moves, rows = HP.collect()
    for r in rows:
        r["id"] = public_id(r["id"])
        if r.get("aliases"):
            r["aliases"] = [public_id(a) for a in r["aliases"]]
    pack = HP.build_pack(rows, Args())
    if retail:
        # build_pack stamps the meta with hitbox_pack's OWN git_commit(), which
        # is this repository - so a retail pack would otherwise claim it came
        # from this build, and the title would say it is applied back to the
        # game. Neither is true, and a reference file that misstates where it
        # came from is worse than having no reference.
        pack["meta"].update(
            title="Strike boxes, retail",
            description=("The same measurement, taken against an unmodified "
                         "checkout and frozen as a reference to diff this "
                         "build against. Nothing applies this file to "
                         "anything."),
            base_commit=git_commit(SOURCE))

    # hitbox_pack labels each row with CHARACTER_LABELS, which spells Kung Lao
    # "Kung Lao (hathead)" - the source's own codename for him, riding along
    # in a field nobody looks at.  It is not a symbol, so the shape-based
    # audit lets it past, and it is exactly what this exporter exists to stop.
    # The slug is ours; membership is derived from CAST so it cannot drift.
    members = {}
    for i, (cid, _nm) in enumerate(CAST):
        members.setdefault(
            public_table(HP.SLUG.get(BA.CHAR_LIST[i][:2], "shared")),
            []).append(cid)
    # WHICH model reads these boxes. Without it a reader has the numbers and
    # not the rule, which is how the public viewer ended up drawing retail.
    pack["model"] = collision_model()

    by_id = {r["id"]: r for r in rows}
    for m in pack["moves"]:
        src = by_id.get(m["id"])
        m["table"] = m["id"].split("/", 1)[0]
        m.pop("character", None)
    pack["tables"] = [{"id": k, "characters": v}
                      for k, v in sorted(members.items())]

    # THE FLAGS WORD, which --public throws away with the field it shares.
    # hitbox_edit calls the 8th strike field `sound`; it is really the flags
    # (balance.lock's own header says so), and sf_squeeze lives in it.  Since
    # 205 of 223 records set it, a viewer without it would draw the wrong hit
    # column on nearly every move - and silently draw the RIGHT one on the
    # eighteen that matter most, which is worse.
    flags = {}
    for m in pack["moves"]:
        src = by_id.get(m["id"])
        raw = str((src or {}).get("sound") or "")
        got = []
        if "sf_squeeze" in raw:
            got.append("squeeze")
        if "sf_duck" in raw:
            got.append("duck")
        if not got:
            v = HP.HE.parse_asm_literal(raw) if raw else None
            if isinstance(v, int):
                got = (["squeeze"] if v & 1 else []) + (["duck"] if v & 2 else [])
        if got:
            flags[m["id"]] = got
    pack["flags"] = flags
    return pack


# ------------------------------------------------------------------- poses --
def pose_rects(pose, frames, strips):
    """Every strip of one pose as [x, y, w, h] about the anipoint.

    ani2 (MKUTIL.ASM) copies each strip's anix/aniy into the multipart record
    and box_bounds (MKDISP.ASM) then places the piece at `oxpos - dx`, so a
    strip's rectangle is (-dx, -dy, w, h).  Same arithmetic as
    hurtbox_lock.pose_box, kept as separate rectangles instead of collapsed to
    one extent - the collapse is what the GAME does, and showing both is the
    point of the viewer.
    """
    names = frames.get(pose)
    if not names:
        return None
    out = []
    for n in names:
        s = strips.get(n)
        if not s:
            return None
        w, h, dx, dy = s
        out.append([-dx, -dy, w, h])
    return out or None


class PoseBank:
    """Rect lists, deduplicated, under ids WE mint.

    Deduplicated on purpose: two poses that draw the same rectangles are the
    same pose here, which shrinks the file and, more usefully, means an id
    never encodes an art name.
    """

    def __init__(self):
        self.by_key = {}
        self.rects = {}

    def add(self, rects):
        key = json.dumps(rects, separators=(",", ":"))
        if key in self.by_key:
            return self.by_key[key]
        pid = "p%04d" % (len(self.by_key) + 1)
        self.by_key[key] = pid
        self.rects[pid] = rects
        return pid


def build_poses():
    strips = BA.parse_strips()
    frames_by_file, frames = BA.parse_frames()

    lanes, lane_file, nxt = {}, {}, {}
    for path in glob.glob(os.path.join(SRC, "*.ASM")):
        for k, v in BA.lane_lines(BA.read(path)).items():
            if k not in lanes:
                lanes[k], lane_file[k] = v, path
        for a, b in HL.lane_order(path).items():
            nxt.setdefault(a, b)

    text_all = "\n".join(BA.read(p)
                         for p in glob.glob(os.path.join(SRC, "*.ASM")))
    anitabs = BA.parse_anitabs(text_all)
    stk_text = BA.read(os.path.join(SRC, "MKSTK.ASM"))
    recs, lists = BA.parse_records(stk_text), BA.parse_lists(stk_text)
    handlers = BA.parse_handlers()
    limits = BA.parse_ochar_tables()

    # Which ani1 tables are the standard cast layout.  The bosses are not, so
    # an index-based lookup against a standard-cast handler means nothing for
    # them - box_align_audit sets those rows aside and so do we.
    lens = collections.Counter()
    for (oc, which, _idx) in anitabs:
        if which == 1:
            lens[oc] += 1
    standard = collections.Counter(lens.values()).most_common(1)[0][0] \
        if lens else 0
    odd_layout = {oc for oc, n in lens.items() if n != standard}
    IDLE = ("STANCE", "WALK", "DIE", "SKIP", "TURN")

    bank = PoseBank()
    slot_desc = HL.slot_names()

    def scope_for(lane):
        s = dict(frames)
        s.update(frames_by_file.get(lane_file.get(lane), {}))
        return s

    # ---- defensive lanes: the poses a fighter wears while NOT attacking ----
    stances = {}
    for oc, (cid, _name) in enumerate(CAST):
        per_slot = {}
        for idx, desc in sorted(slot_desc.items()):
            word = SLOT_WORDS.get((desc or "").strip().lower())
            if not word:
                continue
            lane = anitabs.get((oc, 1, idx))
            if not lane:
                continue
            scope = scope_for(lane)
            seq = HL.lane_poses(lane, lanes, scope, nxt)
            if not seq:
                continue
            ids = []
            for p in seq:
                r = pose_rects(p, scope, strips)
                if r:
                    ids.append(bank.add(r))
            if ids:
                per_slot[word] = ids
        if per_slot:
            stances[cid] = per_slot

    # ---- contact poses: the frame a strike box is actually live on ---------
    owner = HP.char_of(HP.HE.parse_char_tables())
    contacts, dropped = [], collections.Counter()
    for hname, h in sorted(handlers.items()):
        if h["call"] in ("inline", "upcut_striker"):
            dropped["no-single-contact-pose"] += 1
            continue
        which = 2 if h["call"] == "striker_2" else 1
        allowed = limits.get(hname)
        by_name = BA.name_chars(hname) if allowed is None else None
        if by_name:
            allowed = by_name
        confidence = ("handler-name" if by_name else
                      "table" if limits.get(hname) is not None else "assumed")
        for oc, (cid, _name) in enumerate(CAST):
            if allowed is not None and oc not in allowed:
                continue
            lane = anitabs.get((oc, which, h["a9"]))
            if lane is None:
                continue
            lst = lists.get(BA.CHAR_LIST[oc], [])
            if h["a11"] >= len(lst):
                continue
            label = lst[h["a11"]]
            rec = recs.get(label)
            if not rec or rec["x_off"] is None:
                continue
            scope = scope_for(lane)
            pose, _prev, _note = BA.contact_pose(lane, lanes, scope)
            if pose is None:
                continue
            # An `assumed` row that lands on idle art is a character who does
            # not have the move at all.  Publishing it would draw a stance and
            # call it a punch.
            if confidence == "assumed":
                if any(k in pose.upper() for k in IDLE):
                    dropped["idle-art"] += 1
                    continue
                if oc in odd_layout:
                    dropped["boss-ani-table"] += 1
                    continue
            rects = pose_rects(pose, scope, strips)
            if not rects:
                continue
            code, _shared = owner.get(label, (None, False))
            contacts.append({
                "move": public_id(HP.make_id(label, code)),
                "character": cid,
                "pose": bank.add(rects),
                "confidence": confidence,
            })

    contacts.sort(key=lambda c: (c["move"], c["character"]))
    body = json.dumps({"poses": bank.rects, "stances": stances,
                       "contacts": contacts}, sort_keys=True,
                      separators=(",", ":"))
    dig = hashlib.sha256(body.encode()).hexdigest()[:16]
    return {
        "format": "boxlab-pose-pack",
        "format_version": FORMAT_VERSION,
        "meta": meta("Pose geometry", dig),
        "characters": [
            {"id": cid, "name": nm,
             "table": public_table(HP.SLUG.get(BA.CHAR_LIST[i][:2], "shared"))}
            for i, (cid, nm) in enumerate(CAST)],
        "poses": bank.rects,
        "stances": stances,
        "contacts": contacts,
        "excluded": dict(dropped),
    }


# ------------------------------------------------------------------ frames --
def build_frames():
    """Timing and advantage, joined to the public move ids.

    Read from doc/frame_advantage.csv rather than re-derived, so this file and
    the doc can never disagree.  Every column naming a source symbol - the
    record label, the handler, the two reaction routines - is dropped, and the
    pose column is an ART name, which is the one a blacklist would miss.
    """
    path = os.path.join(ROOT, "doc", "frame_advantage.csv")
    if not os.path.exists(path):
        raise SystemExit("missing %s - run tools/frame_advantage.py --csv first"
                         % path)
    owner = HP.char_of(HP.HE.parse_char_tables())
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            oc = CSV_CHAR.get((r.get("char") or "").strip())
            label = (r.get("record") or "").strip()
            if oc is None or not label:
                continue
            code, _shared = owner.get(label, (None, False))

            def n(key, row=r):
                v = (row.get(key) or "").strip()
                if not v:
                    return None
                try:
                    return int(v, 0)
                except ValueError:
                    return None

            row = {
                "id": public_id(HP.make_id(label, code)),
                "character": CAST[oc][0],
                "startup": n("startup"), "active": n("active"),
                "recovery": n("recovery"), "total": n("total"),
                "blockstun": n("blockstun"), "on_block": n("on_block"),
                "hitstun": [n("hitstun_lo"), n("hitstun_hi")],
                "on_hit": [n("on_hit_lo"), n("on_hit_hi")],
                "reach": n("reach"),
                # `~` in the CSV means the recovery tail was approximated.
                "approx": (r.get("approx") or "").strip() == "~",
            }
            if row["hitstun"] == [None, None]:
                row.pop("hitstun")
            if row["on_hit"] == [None, None]:
                row.pop("on_hit")
            rows.append({k: v for k, v in row.items() if v is not None})
    rows.sort(key=lambda x: (x["id"], x["character"]))
    dig = hashlib.sha256(json.dumps(rows, sort_keys=True,
                                    separators=(",", ":")).encode()
                         ).hexdigest()[:16]
    return {
        "format": "boxlab-frame-pack",
        "format_version": FORMAT_VERSION,
        "meta": meta("Frame timing and advantage", dig),
        "moves": rows,
    }


# ------------------------------------------------------------------- audit --
# A WHITELIST.  Every string emitted must match one of these, or the export
# aborts.  hitbox_pack's audit is a blacklist for symbol SHAPE, which is right
# for a file of numbers and ids; it cannot see `LKWALK1`.  This can.
ALLOWED = [
    re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)*$"),  # ids
    re.compile(r"^p[0-9]{4}$"),                                        # poses
    re.compile(r"^[0-9a-f]{7,40}$"),                                   # digests
    re.compile(r"^\d{4}-\d{2}-\d{2}$"),                                # dates
]
ALLOWED_EXACT = {"shared / system", "mk2-hitbox-pack", "boxlab-pose-pack",
                 "boxlab-frame-pack", "handler-name", "table", "assumed",
                 ""}
ALLOWED_EXACT |= {nm for _cid, nm in CAST}

# Prose we wrote ourselves, in this file.  Checked by KEY so a future edit that
# pastes something in from the source fails the audit instead of riding along
# inside a `description`.
PROSE_KEYS = {"title", "description", "units", "author"}
KEY_OK = re.compile(r"^[a-z][a-z0-9_]*$")


def audit(node, path="", prose_ok=False, bad=None):
    if bad is None:
        bad = []
    if isinstance(node, dict):
        for k, v in node.items():
            if not isinstance(k, str) or not (
                    ALLOWED[0].match(k) or ALLOWED[1].match(k)
                    or KEY_OK.match(k)):
                bad.append((path, "key %r" % k))
            audit(v, "%s.%s" % (path, k), k in PROSE_KEYS, bad)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            audit(v, "%s[%d]" % (path, i), prose_ok, bad)
    elif isinstance(node, str):
        s = node.strip()
        if prose_ok or s in ALLOWED_EXACT:
            return bad
        if not any(p.match(s) for p in ALLOWED):
            bad.append((path, s))
    return bad


FILES = [("boxes.json", build_boxes),
         ("poses.json", build_poses),
         ("frames.json", build_frames)]


def strip_date(t):
    """Drop the PROVENANCE stamp before comparing two exports.

    `generated` and `source_commit` say when and from what, not what. Leaving
    `source_commit` in made --check report all three files STALE after any
    commit to this tree, even when every byte of the data was identical - which
    is exactly the false alarm that would make a Phase D wiring of this check
    unusable. The `digest` field stays in the comparison, so a real data change
    still fails.
    """
    t = re.sub(r'"(generated|created)": "\d{4}-\d{2}-\d{2}"', "", t or "")
    #
    #  boxes.json names the same stamp `base_commit`, and stripping only
    #  `source_commit` left exactly the false alarm above alive for one file
    #  of the three - it went STALE on every commit to this tree with the data
    #  byte-identical. `base_digest` stays in, so a real data change still
    #  fails.
    #
    return re.sub(r'"(source_commit|base_commit)": "[0-9a-f]*"', "", t)


def point_at(tree):
    """Read the strike tables out of another checkout.

    Only the strike tables move. Pose geometry comes from artwork and frame
    timing from doc/frame_advantage.csv, and both of those describe THIS
    build - which is why --retail exports boxes.json and nothing else.
    """
    global SOURCE
    import pathlib
    asm = pathlib.Path(tree) / "src" / "MKSTK.ASM"
    if not asm.exists():
        raise SystemExit("no strike tables at %s\n"
                         "--source wants the root of a checkout, the one that "
                         "has src/MKSTK.ASM under it." % asm)
    SOURCE = os.path.abspath(tree)
    HP.HE.ASM_PATH = asm
    HP.ASM = str(asm)


# ------------------------------------------------------- proposals, inbound
#
# public_id() takes a private record id public.  This is the other direction,
# and it is what makes boxlab authoritative rather than merely honest: a
# proposal written by someone who has only ever seen the public data can be
# resolved back to a strike record and applied to the build.

PROPOSAL_FORMAT = "boxlab-proposal"

# Deliberately the same six the public side advertises.  Reactions index an
# animation table, so a "better" value is not a bigger one and neither the
# viewer nor the diff can show what changed; score is not balance.  Accepting
# more here than proposals/README.md promises would let a pull request touch
# fields nobody agreed were on the table.
PROPOSABLE = ("front", "y", "width", "height", "hit", "block")


def private_id_map(rows):
    """public id -> private id, inverted over the ACTUAL record set.

    Not by inverting TABLE_WORDS and MOVE_WORDS symbolically.  MOVE_WORDS
    renames some suffixes and passes the rest through, so two private records
    can land on one public id - and a rename colliding with a passthrough
    would otherwise resolve a stranger's proposal onto the wrong move and
    apply it.  Building the map over the real rows is the only way to see that
    happen, so it is built that way and fails closed.
    """
    out = {}
    for r in rows:
        pub = public_id(r["id"])
        if out.get(pub, r["id"]) != r["id"]:
            raise SystemExit(
                "boxlab_export: %r is the public id of BOTH %r and %r.\n"
                "A proposal naming it cannot be resolved.  Fix the collision "
                "in MOVE_WORDS before applying anything."
                % (pub, out[pub], r["id"]))
        out[pub] = r["id"]
    return out


def find_proposals(checkout):
    d = os.path.join(checkout, "proposals")
    if not os.path.isdir(d):
        return []
    return sorted(os.path.join(d, f) for f in os.listdir(d)
                  if f.lower().endswith(".json"))


def resolve_proposals(paths, checkout, do_apply=False):
    """Translate open boxlab proposals into changes against MKSTK.ASM."""
    pub_pack = build_boxes()
    pub_by_id = {m["id"]: m for m in pub_pack["moves"]}
    build_digest = pub_pack["meta"].get("base_digest")

    moves, rows = HP.collect()
    priv_by_id = {r["id"]: r for r in rows}
    to_private = private_id_map(rows)

    if not paths:
        paths = find_proposals(checkout)
    if not paths:
        print("No open proposals in %s."
              % os.path.join(checkout, "proposals"))
        return 0

    wanted, errors = {}, []
    for path in paths:
        name = os.path.basename(path)
        try:
            with open(path, encoding="utf-8") as fh:
                prop = json.load(fh)
        except (OSError, ValueError) as e:
            errors.append("%s: unreadable - %s" % (name, e))
            continue
        if prop.get("format") != PROPOSAL_FORMAT:
            errors.append("%s: not a %s file (format=%r)"
                          % (name, PROPOSAL_FORMAT, prop.get("format")))
            continue

        # The whole reason a proposal is an overlay.  A base_digest that no
        # longer matches means the record moved after it was measured, so
        # every `from` in it describes a number that is gone.
        base = prop.get("base_digest")
        if base and build_digest and base != build_digest:
            errors.append(
                "%s: written against build %s, this build is %s.  The numbers "
                "it measured against have moved - ask for it to be rebased."
                % (name, base, build_digest))
            continue

        for ch in prop.get("changes", []):
            pid = ch.get("id")
            priv = to_private.get(pid)
            if priv is None:
                errors.append("%s: no such record %r in this build"
                              % (name, pid))
                continue
            pub_row = pub_by_id.get(pid, {})
            for field, spec in ch.items():
                if field == "id":
                    continue
                if field not in PROPOSABLE:
                    errors.append("%s: %s.%s is not proposable"
                                  % (name, pid, field))
                    continue
                if not isinstance(spec, dict) or "to" not in spec:
                    errors.append("%s: %s.%s needs a from/to pair"
                                  % (name, pid, field))
                    continue
                now = pub_row.get(field)
                if "from" in spec and spec["from"] != now:
                    errors.append(
                        "%s: %s.%s expects %r, the build has %r - stale"
                        % (name, pid, field, spec["from"], now))
                    continue
                lo, hi = HP.LIMITS.get(field, (-32768, 32767))
                if not isinstance(spec["to"], int) or not lo <= spec["to"] <= hi:
                    errors.append("%s: %s.%s -> %r is out of range %d..%d"
                                  % (name, pid, field, spec["to"], lo, hi))
                    continue
                slot = wanted.setdefault(priv, {"id": priv})
                if field in slot and slot[field] != spec["to"]:
                    errors.append(
                        "%s: %s.%s conflicts with another open proposal "
                        "(%r vs %r)"
                        % (name, pid, field, slot[field], spec["to"]))
                    continue
                slot[field] = spec["to"]

    for e in errors:
        print("error: %s" % e, file=sys.stderr)
    if errors:
        print("\n%d problem(s).  Nothing applied." % len(errors),
              file=sys.stderr)
        return 1

    pack = {"format": HP.FORMAT, "format_version": HP.FORMAT_VERSION,
            "meta": {"title": "open boxlab proposals"},
            "moves": list(wanted.values())}
    changes = HP.compute_diff(pack, priv_by_id)
    HP.show_diff(changes)
    if not changes:
        return 0
    if not do_apply:
        print("\nDry run.  Add --apply to write these into MKSTK.ASM.")
        return 0
    n = HP.apply_changes(changes, moves)
    print("\nPatched %d field(s).  Rebuild, then run the gates in "
          "doc/FGC_FRAME_BOX_SPEC.md section 15 before publishing." % n)
    return 0



def check_model_against_lab(model):
    """Does the rule we publish agree with an INDEPENDENT reading of sq_punch?

    box_model_lab.py parses the same switches out of MAINEQU.ASM and builds
    the column its own way, so this is two readings of JOY.ASM agreeing - not
    this file checking itself. That distinction is the whole value: the last
    drift was `column_divisor` hardcoded to 4 in the block whose own comment
    explains why nothing here may be hardcoded, and re-deriving it the same
    way would have agreed with itself perfectly.

    Returns a list of complaints, empty when the two match.
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import box_model_lab as lab
    except Exception as exc:
        return ["could not import box_model_lab to cross-check: %s" % exc]

    def published(l, r, anchor):
        W = r - l
        inset = (W >> 3) + (W >> 2)
        if model.get("column") == "anchor":
            if model.get("column_width") in ("retail", "divisor"):
                d = model.get("column_divisor") or 4
                w = (W >> (d >> 1)) if model["column_width"] == "divisor"                     else W - 2 * inset
                lo = w >> 1
                return [anchor - lo, anchor + (w - lo)]
            half = W >> 3
            return [anchor - half, anchor + half]
        return [l + inset, r - inset]

    bad = []
    for W in range(0, 260):
        for anchor in (0, 7, 123, -40):
            got = published(0, W, anchor)
            want = list(lab.squeeze_build(0, W, anchor))
            if got != want:
                bad.append("W=%d anchor=%d: pack says %s, sq_punch gives %s"
                           % (W, anchor, got, want))
                if len(bad) >= 3:
                    return bad
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if the committed files are stale")
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help="the boxlab checkout (default: %s)" % DEFAULT_OUT)
    ap.add_argument("--source", default=None, metavar="TREE",
                    help="read the strike tables from another checkout "
                         "instead of this one")
    ap.add_argument("--proposals", nargs="*", default=None, metavar="FILE",
                    help="resolve boxlab proposals back onto the strike "
                         "records.  No FILE means every open one in the "
                         "checkout.  Dry run unless --apply is given")
    ap.add_argument("--apply", action="store_true",
                    help="with --proposals: write the changes into MKSTK.ASM")
    ap.add_argument("--retail", action="store_true",
                    help="write ONLY boxes.json, into data/retail/. Use with "
                         "--source pointed at an unmodified checkout")
    args = ap.parse_args()

    if args.source:
        point_at(args.source)
    if args.proposals is not None:
        sys.exit(resolve_proposals(args.proposals,
                                   os.path.abspath(args.out), args.apply))
    if args.apply:
        raise SystemExit("--apply only means something with --proposals.")
    if args.retail and not args.source:
        raise SystemExit(
            "--retail needs --source.\n"
            "It exports the strike boxes of a DIFFERENT checkout as a frozen "
            "reference to diff this build against. Pointed at this tree it "
            "would just write this build's boxes into data/retail/, which is "
            "worse than having no reference at all.")

    OUT = os.path.join(os.path.abspath(args.out), "data")
    if not os.path.isdir(os.path.dirname(OUT)):
        raise SystemExit(
            "no boxlab checkout at %s\n"
            "It is a separate repository and lives outside this tree. Clone it\n"
            "there, or point at it with --out or BOXLAB_DIR."
            % os.path.dirname(OUT))
    if args.retail:
        OUT = os.path.join(OUT, "retail")
    os.makedirs(OUT, exist_ok=True)
    stale = []
    files = ([("boxes.json", lambda: build_boxes(retail=True))]
             if args.retail else FILES)
    for name, fn in files:
        data = fn()
        bad = audit(data, name)
        if bad:
            print("AUDIT FAILED for %s - these strings are not ours to "
                  "publish:" % name, file=sys.stderr)
            for where, what in bad[:20]:
                print("  %-44s %r" % (where, what), file=sys.stderr)
            raise SystemExit("refusing to write %s" % name)
        text = json.dumps(data, indent=1, sort_keys=True) + "\n"
        dest = os.path.join(OUT, name)
        old = open(dest, encoding="utf-8").read() \
            if os.path.exists(dest) else None
        if args.check:
            if old is None:
                stale.append("%s: not committed" % name)
            elif strip_date(old) != strip_date(text):
                stale.append("%s: differs from the build" % name)
            continue
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(text)
        rows = data.get("moves", data.get("contacts", []))
        m = data.get("meta", {})
        print("%-12s %8d bytes  %4d rows  digest %s"
              % (name, len(text), len(rows),
                 m.get("digest") or m.get("base_digest", "?")))

    if args.check:
        drift = check_model_against_lab(collision_model())
        if drift:
            print("MODEL DRIFT  the published collision rule is not the one",
                  file=sys.stderr)
            print("             the game compiles:", file=sys.stderr)
            for d in drift:
                print("  %s" % d, file=sys.stderr)
            raise SystemExit("boxlab would publish a rule the build does not "
                             "implement")
        if stale:
            for s in stale:
                print("STALE  %s" % s, file=sys.stderr)
            raise SystemExit("the boxlab checkout is not what this build "
                             "would produce - re-run tools/boxlab_export.py")
        print("boxlab matches the build (%s)." % args.out)


if __name__ == "__main__":
    main()
