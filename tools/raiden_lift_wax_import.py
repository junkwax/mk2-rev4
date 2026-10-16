#!/usr/bin/env python3
"""Generate Raiden's F,F,F+LK lift fatality from data/RAIDELEC*.WAX.

    python tools/raiden_lift_wax_import.py           rewrite the generated blocks
    python tools/raiden_lift_wax_import.py --check   exit 1 if any block is stale

The WAX projects are the source of truth.  data/RAIDELEC.WAX is the DEFAULT:

  slot 6  Raiden body  -> src/MKRD.ASM    a_death_zap1        RN1DETHBLO1 lead-in, a row per step
  slot 0  lightning    -> src/MKRD.ASM    a_death_bolt1       a row per step
  victim  (any slot)   -> src/MKRDLIF.ASM rd_lift_vic_script  pose, offset, flags, hold per step

and every entry in FAMILIES is a victim family with its own project (same
Raiden and bolt, its own victim poses and anipoints) and its own script,
rd_lift_vic_script_<name>.  rd_lift_vic_scripts picks the script by the
victim's ochar.  Plus the rig's expected timelines
(tools/raiden_lift_fatality_test.lua) and the tables in
doc/RAIDEN_LIGHTNING_FATALITY_ANIPTS.md.

The victim slot is found, not configured: the one slot as long as the body
slot whose frames all carry the family's art prefix (LK for the default, the
family name otherwise - NJ, TM).  A project can carry another family's
sequence as scratch; the prefix keeps it from being picked.

DEFAULT vs FAMILY FRAMES.  The default project is authored on Liu Kang and
serves everyone without a family of their own, so its victim frames go through
the per-fighter pose tables (POSES) and each fighter draws his own art.  A
family project names its fighters' frames outright (flag bit 4), and those
wrappers have to exist and be .global.

TIMING.  The three slots may hold their entries for different lengths.  A
STEP is every stretch of ticks in which none of the three changes frame, so
do_raiden_lift_fatal walks all three lanes one row per step and sleeps the
step's length (carried in the victim script).  A frame held across several
steps is simply repeated in its lane.  The body and bolt lanes are shared, so
every family must produce the default's steps exactly - same frames, same holds.

PLACEMENT.  A victim local_dx/dy is an ANIPOINT offset from the shared anchor,
and Raiden's slot sits on that anchor with none, so the victim's anchor goes at
Raiden + (mirrored ? +dAX : -dAX, -dAY) in Raiden's facing - the per-frame rule
tools/wvp_to_lane.py and imgtool's exporter use.  See rd_lift_pose_victim.
"""
import argparse
import glob
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MKRD = os.path.join(ROOT, 'src', 'MKRD.ASM')
MKDEATH = os.path.join(ROOT, 'src', 'MKDEATH.ASM')
# The victim scripts and pose tables are ~840 lines of pure data and live in
# their OWN object: MKDEATH is the module nearest GSPA's ceiling and taking the
# electrocution loop from 3 extra passes to 5 aborted it with 'Out of memory'.
MKRDLIF = os.path.join(ROOT, 'src', 'MKRDLIF.ASM')
RIG = os.path.join(ROOT, 'tools', 'raiden_lift_fatality_test.lua')
DOC = os.path.join(ROOT, 'doc', 'RAIDEN_LIGHTNING_FATALITY_ANIPTS.md')

DEFAULT_WAX = 'RAIDELEC.WAX'    # authored on Liu Kang; everyone without a family
# Victim families: (name, project, the ochars that use it).  Ninja art is shared
# by every ninja, and Kintaro/Kahn take the ninja row the way every other
# char-indexed table in the build does.
#
# A project may be pinned to a git revision, 'NAME.WAX@<rev>', to keep a family
# on its last good version while its working file is being reworked.  Pin to a
# commit hash, not HEAD: other sessions commit this tree.
FAMILIES = [
    # (name, project, ochars[, frame prefixes]).  The prefixes pick the victim
    # slot: the one body-length slot whose frames all start with one of them
    # (default: the family name).
    ('TM', 'RAIDELECLAO.WAX', (0,)),                  # Kung Lao
    ('LK', 'RAIDELECLIUFRONT.WAX', (1,)),             # Liu Kang (front-facing rework)
    ('JC', 'RAIDELECCAGE.WAX', (2,)),                 # Johnny Cage
    ('UG', 'RAIDELECUGMO.WAX', (3,)),                 # Baraka
    ('KT', 'RAIDELECKAT.WAX', (4, 5, 16, 18)),        # Kitana, Mileena, Jade, Khameleon
    ('ST', 'RAIDELECTSUNG.WAX', (6,)),                # Shang Tsung
    ('RN', 'RAIDELECRAD.WAX', (7,), ('RN', 'RD')),    # Raiden (his soul-suck art is RD)
    ('NJ', 'RAIDELECNJ.WAX', (8, 9, 10, 12, 13, 14, 15, 17, 19)),
    ('JX', 'RAIDELECJAX.WAX', (11,)),                 # Jax
]
OCHAR_NAMES = ['kung lao', 'liu kang', 'johnny cage', 'baraka', 'kitana', 'mileena',
               'shang tsung', 'raiden', 'sub-zero', 'reptile', 'scorpion', 'jax',
               'kintaro', 'shao kahn', 'smoke', 'noob saibot', 'jade', 'ermac',
               'khameleon', 'rain']

BODY_SLOT, BOLT_SLOT = 6, 0
LEAD_HOLD = 4       # RN1DETHBLO1 before the WAX starts - do_raiden_lift_fatal's "sleep 4"

# The electrocution loop (requested 2026-09-13): after the WAX's own pass of the
# RN1DETHBLO6..RN1DETHBLO10 stretch, play that stretch - bolt and victim steps
# included, exactly as the WAX pairs them - LOOP_EXTRA more times before the
# rest.  Found by body frame name, so the WAX can move it.  Its first step also
# carries the smoke flag (bit 1 of the script's flag word -> rd_lift_smoke).
LOOP_FROM, LOOP_TO, LOOP_EXTRA = 'RN1DETHBLO6', 'RN1DETHBLO10', 5

# HE SOUNDS LIKE THE OTHER ELECTROCUTION (requested 2026-09-28).  Retail's
# do_raiden_fry - hold LK in FINISH HIM, the same current - gives the victim no
# voice of its own and instead re-sends tsound 0c7h, the super zap, every two
# shake cycles for the whole cook.  The voice MK2 does pair with this current is
# rsnd_death_voice, which do_raiden_shocker (MOVES.ASM) plays on the man the
# moment the grab takes him.  So: his death voice once as the bolt reaches him,
# then the zap again on the first step of EVERY pass of the electrocution
# stretch - 20 ticks apart against the fry's 24, the closest the 4-tick steps
# get.  Flag bits 3 / 7 -> rsnd_death_voice / tsound 0c7h.
#
# The long scream (disturbing_scream, Liu Kang's b8h ~2.2s) is what made this
# fatality sound unlike the other one, so it is OFF: SCREAM_PASSES = (0,) puts
# it back on the WAX's own pass, and bit 2 still carries it.
SCREAM_PASSES = ()
YELL_BITS = {'scream': 4, 'death': 8}
ZAP_BIT = 128       # re-send the super zap - the first step of every pass
DIRECT_BIT = 16     # the script names the frame outright - no pose table

# How much electrocution the player gets for free (requested 2026-09-15: "at least
# one rotation from 6-10, or two").  The Up + HP mash is first checked at the start
# of this pass of the RN1DETHBLO6-10 stretch (0 = the WAX's own pass), again at the
# start of every later pass, and once more on the first step after the stretch -
# once per rotation, the way retail do_raiden_fry checks LK + Block once per shake
# cycle after three free ones.  Flag bit 5 -> rd_lift_mash_ok.
MASH_FROM_PASS = 2
MASH_BIT = 32
VFLIP_BIT = 64      # the pose is drawn upside down (IMGTOOL mirror bit 2)

# THE X-RAY FLASH (2026-10-04, RAIDELECLIUFRONT.WAX).  MKSHOCK.IMG holds each
# fighter's body as a skeleton inside the current (LUBUZZ2 is Liu Kang's), drawn
# in three palettes - BUZBLUE, BUZRED, BUZZER - which pair with Raiden's costume
# exactly as his bolt does.  A victim entry taken from that library is an X-ray
# step: it may sit in a family's victim lane whatever the family prefix, it sets
# bit 8 (rd_lift_buzz, MKRDLIF.ASM, swaps him onto the BUZ palette and holds his
# electrocution flicker off), and its record has to be PACKED - data/LUBUZZ.LOD
# carries LUBUZZ2 only, so a WAX that reaches for another fighter's X-ray fails
# here on the missing wrapper rather than drawing garbage.
XRAY_IMG = 'MKSHOCK.IMG'
XRAY_BIT = 256

# Default-project victim record -> (per-fighter table in MKRDLIF.ASM, pose
# family the rig matches in the drawn label).
POSES = {
    'LKSTUMBLE1': ('rd_lift_stumble1_tbl', 'STUMBL'),      # Baraka's is UGSTUMBL1E1
    'LKFLIPPED2': ('rd_lift_flipped2_tbl', 'FLIPPED2'),
    'LKBACKBREAK3': ('rd_lift_bb3_tbl', 'BACKBREAK3'),
    'LKKNOCKDOWN7': ('rd_lift_kd7_tbl', 'KNOCKDOWN'),      # female ninjas end on 6
}
# IMG record names the build knows by another label.  TSUNG's knockdown art is
# authored STKNOCKEDOWN1-7 and wrapped as STKNOCKDOWN1-7 (MKST.ASM) - the same
# aliasing tools/wvp_to_lane.py's SUBST carries.
RECORD_ALIASES = dict(('STKNOCKEDOWN%d' % i, 'STKNOCKDOWN%d' % i) for i in range(1, 8))
# Baraka's stumble is wrapped as UGSTUMBL1E1 (sic, MKSA.ASM).
RECORD_ALIASES['UGSTUMBLE1'] = 'UGSTUMBL1E1'

UNSUPPORTED = ('visible_from', 'visible_until', 'motion_dx', 'motion_dy',
               'dual_on', 'frame_z')

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")


def die(msg):
    sys.exit('raiden_lift_wax_import: ' + msg)


def read_wax(name):
    kv = {}
    if '@' in name:
        fname, rev = name.split('@', 1)
        got = subprocess.run(['git', 'show', '%s:data/%s' % (rev, fname)], cwd=ROOT,
                             capture_output=True, text=True, errors='replace')
        if got.returncode:
            die('cannot read %s at %s: %s' % (fname, rev, got.stderr.strip()))
        lines = got.stdout.splitlines()
    else:
        lines = open(os.path.join(ROOT, 'data', name), errors='replace')
    for line in lines:
        if '=' in line:
            k, v = line.rstrip('\r\n').split('=', 1)
            kv[k] = v
    return kv


def ints(kv, key, n=None):
    v = [int(x) for x in kv.get(key, '').split(',') if x.strip()]
    if n is not None and v and len(v) != n:
        die('%s has %d values, expected %d' % (key, len(v), n))
    return v


def img_names(path):
    base = os.path.basename(path.replace(chr(92), '/'))
    b = open(os.path.join(ROOT, 'data', base), 'rb').read()
    n, _, o = LIB_HDR.unpack_from(b, 0)[:3]
    return [IMAGE.unpack_from(b, o + i * IMAGE.size)[0].split(b'\0')[0].decode('latin-1')
            for i in range(n)]


def slot(kv, docs, s, wax):
    p = 'slot.%d.' % s
    frames = ints(kv, p + 'sequence_frames')
    n = len(frames)
    if not n:
        die('%s slot %d is empty' % (wax, s))
    for key in UNSUPPORTED:
        if any(ints(kv, p + key, n)):
            die('%s slot %d uses %s, which this importer does not model' % (wax, s, key))
    own = int(kv.get(p + 'doc_idx', '-1'))
    dis = ints(kv, p + 'frame_doc_idx', n) or [-1] * n
    names = [docs[own if d < 0 else d][f] for f, d in zip(frames, dis)]
    libs = [os.path.basename(kv.get('doc.%d.path' % (own if d < 0 else d), '').replace(chr(92), '/')).upper()
            for d in dis]
    zero = [0] * n
    return dict(names=names, xray=[lib == XRAY_IMG for lib in libs],
                hold=ints(kv, p + 'frame_delays', n) or [int(kv.get('state.default_hold', 4))] * n,
                dx=ints(kv, p + 'local_dx', n) or zero,
                dy=ints(kv, p + 'local_dy', n) or zero,
                mirror=ints(kv, p + 'frame_mirror', n) or zero)


def victim_slot(kv, docs, n, wax, prefix):
    """The one slot as long as the body whose frames are all the family's (or
    X-rays).  Only if there is NONE does a LONGER one count - timeline() then
    plays the part that fits (RAIDELECJAX.WAX, 2026-10-04, carried two extra
    JXKNOCKDOWN7 entries).  Exact first, because a project's scratch slots
    can be longer too (RAIDELECRAD.WAX slot 23)."""
    exact, longer = [], []
    for s in range(int(kv.get('slot.count', '0'))):
        if s in (BODY_SLOT, BOLT_SLOT):
            continue
        k = len(ints(kv, 'slot.%d.sequence_frames' % s))
        if k < n:
            continue
        sl = slot(kv, docs, s, wax)
        own = [x for x, xr in zip(sl['names'], sl['xray']) if not xr]
        if own and all(x.startswith(prefix) for x in own):
            (exact if k == n else longer).append(s)
    found = exact or longer
    if len(found) != 1:
        die('%s: expected exactly one victim slot (%d entries, every frame %s* or a %s '
            'X-ray), found %s' % (wax, n, prefix, XRAY_IMG, found or 'none'))
    return found[0]


def first_pieces():
    s = open(MKRD, errors='replace').read()
    return dict(re.findall(r'^(RN1DETHB\w+)[ \t]*\r?\n[ \t]*\.long[ \t]+(\w+)', s, re.M))


_ASM = None


def asm_symbols():
    """({multipart wrapper label: its pieces}, .global names) across src/*.ASM.

    A wrapper is written two ways: the label on its own line with the .long on
    the next (MKHH's TMFLIPPED1), or both on one line (MKFX's HHDRAIN0)."""
    global _ASM
    if _ASM is None:
        wrappers, globs = {}, set()
        own_line = re.compile(r"^(\w+)[ \t]*\r?\n[ \t]*\.long[ \t]+([^;\r\n]*)", re.M)
        same_line = re.compile(r"^(\w+)[ \t]+\.long[ \t]+([^;\r\n]*)", re.M)
        glob_line = re.compile(r"^[ \t]*\.globa?l[ \t]+([^;\n]*)", re.M)
        for path in glob.glob(os.path.join(ROOT, 'src', '*.ASM')):
            text = open(path, errors='replace').read()
            for pat in (own_line, same_line):
                for m in pat.finditer(text):
                    pieces = [x.strip() for x in m.group(2).split(',')]
                    wrappers.setdefault(m.group(1), [x for x in pieces if x and x != '0'])
            for m in glob_line.finditer(text):
                globs.update(x.strip() for x in m.group(1).split(','))
        _ASM = (wrappers, globs)
    return _ASM


def resolve_frame(n, wax, i):
    """The multipart wrapper to hand ani2 for IMG record n.  A record that is
    itself a wrapper label is used as it is; a bare sprite record (MKSOUL's
    TMSOULSUCK1) goes through the one wrapper whose only piece it is
    (MKFX's HHDRAIN0), which is how the rest of the game draws it on a fighter."""
    wrappers, _ = asm_symbols()
    n = RECORD_ALIASES.get(n, n)
    if n in wrappers:
        return n
    cands = sorted(k for k, p in wrappers.items() if p == [n])
    if len(cands) != 1:
        die('%s victim entry %d is %s - %s' % (wax, i, n,
            ('no multipart wrapper draws it (add one: LABEL .long %s,0)' % n) if not cands
            else 'several one-piece wrappers draw it (%s) - pick one' % ', '.join(cands)))
    return cands[0]


def timeline(name, wax, direct, pieces, prefixes, shared=None):
    kv = read_wax(wax)
    docs = [img_names(kv['doc.%d.path' % i]) for i in range(int(kv['doc.count']))]
    body, bolt = slot(kv, docs, BODY_SLOT, wax), slot(kv, docs, BOLT_SLOT, wax)
    scale = 1
    if shared is not None:
        # A uniform integer factor between this project's shared lanes and the
        # default's (both lanes, every entry) means a different tick base, not
        # different timing - the victim lane is rescaled by it below.
        ratios = {r // h if h and r % h == 0 else 0
                  for sl, ref in ((body, shared['body']), (bolt, shared['bolt']))
                  for h, r in zip(sl['hold'], ref['hold'])}
        if len(ratios) == 1 and min(ratios) > 1:
            scale = ratios.pop()
        # The Raiden and bolt lanes are shared by every family, so a family
        # project's own copies only have to name the same frames; their holds
        # are the default's (requested 2026-09-15, when RAIDELECLIU.WAX's bolt
        # carried a stray 1-tick hold).
        for what, sl, ref in (('body', body, shared['body']), ('bolt', bolt, shared['bolt'])):
            if sl['names'] != ref['names']:
                die('%s %s frames %s differ from %s %s - the lanes are shared'
                    % (wax, what, sl['names'], DEFAULT_WAX, ref['names']))
            if sl['hold'] != ref['hold']:
                print('note: %s %s holds %s differ from %s; using the shared %s'
                      % (wax, what, sl['hold'], DEFAULT_WAX, ref['hold']))
                sl['hold'] = list(ref['hold'])
    vs = victim_slot(kv, docs, len(body['names']), wax, tuple(prefixes))
    vic = slot(kv, docs, vs, wax)
    if len(vic['names']) > len(body['names']):
        # The bolt is removed when the shared lanes end, so a longer victim lane
        # cannot play past them: keep the entries that START inside the shared
        # length and clip the last hold to it.  Loud, because it drops art.
        end = sum(body['hold']) if shared is None else sum(shared['body']['hold'])
        t, keep = 0, 0
        for h in vic['hold']:
            if t >= end:
                break
            t += h * scale
            keep += 1
        dropped = vic['names'][keep:]
        for k in vic:
            vic[k] = vic[k][:keep]
        over = sum(h * scale for h in vic['hold']) - end
        if over > 0:
            vic['hold'][-1] -= over // scale
        print('NOTE: %s victim lane runs %d entries past the shared Raiden/bolt lanes - '
              'dropped %s (the lanes are shared by every family; lengthen RAIDELEC.WAX '
              'and every project to play them)' % (wax, len(dropped), dropped))
    if shared is not None and scale > 1:
        # The whole project was saved on a finer tick (RAIDELECKAT.WAX,
        # 2026-09-18: every entry of every lane held 1 where the default holds
        # 4).  The shared lanes were just put back on the default's holds, so
        # the victim lane gets the same factor - his timing relative to the
        # lightning is exactly what was authored.
        print('note: %s victim holds %s scaled x%d with the shared lanes'
              % (wax, vic['hold'], scale))
        vic['hold'] = [h * scale for h in vic['hold']]

    for what, sl, pat in (('body', body, 'RN1DETHBLO'), ('bolt', bolt, 'RN1DETHBOLT')):
        for i, n in enumerate(sl['names']):
            if not re.fullmatch(pat + r'\d+', n) or n not in pieces:
                die('%s %s entry %d is %s - no %s* wrapper for it in MKRD.ASM'
                    % (wax, what, i, n, pat))
            if sl['dx'][i] or sl['dy'][i] or sl['mirror'][i]:
                die('%s %s entry %d has an offset or mirror - only the victim may' % (wax, what, i))
    wrappers, globs = asm_symbols()
    vic['frames'] = []
    for i, (n, m) in enumerate(zip(vic['names'], vic['mirror'])):
        if vic['xray'][i] and not direct:
            die('%s victim entry %d is %s, an X-ray out of %s - only a family project '
                '(frames named outright) can use one; the default goes through per-fighter '
                'pose tables' % (wax, i, n, XRAY_IMG))
        if direct:
            w = resolve_frame(n, wax, i)
            if w not in globs:
                die('%s victim entry %d is %s (wrapper %s) - it is not .global; add it to '
                    'the lift fatality block in MAINEQU.ASM' % (wax, i, n, w))
            vic['frames'].append(w)
        elif n not in POSES:
            die('%s victim entry %d is %s - add a per-fighter table for it to MKRDLIF.ASM '
                'and to POSES here' % (wax, i, n))
        if m not in (0, 1, 2, 3):
            die('%s victim entry %d has mirror %d - only X (1) and Y (2) exist' % (wax, i, m))
    for what, sl in (('body', body), ('bolt', bolt), ('victim', vic)):
        if any(h < 1 for h in sl['hold']):
            die('%s %s slot has a zero hold' % (wax, what))

    totals = {w: sum(sl['hold']) for w, sl in (('body', body), ('bolt', bolt), ('victim', vic))}
    if len(set(totals.values())) != 1:
        die('%s: the slots run for different lengths %s - they have to end on the same '
            'tick, the bolt is removed when the lanes finish' % (wax, totals))
    total = totals['body']

    def starts(sl):
        out, t = [], 0
        for h in sl['hold']:
            out.append(t)
            t += h
        return out

    st = {id(sl): starts(sl) for sl in (body, bolt, vic)}

    def at(sl, t):
        return max(j for j, s0 in enumerate(st[id(sl)]) if s0 <= t)

    cuts = sorted(set(st[id(body)] + st[id(bolt)] + st[id(vic)]))
    steps = []
    for i, t0 in enumerate(cuts):
        t1 = cuts[i + 1] if i + 1 < len(cuts) else total
        steps.append(dict(t=t0, hold=t1 - t0, b=at(body, t0), o=at(bolt, t0), v=at(vic, t0),
                          loop=0, smoke=False, yell='', mash=False, zap=False))

    # The electrocution loop: the stretch from the first LOOP_FROM body entry
    # through the next LOOP_TO, played LOOP_EXTRA more times right after itself.
    names = body['names']
    if LOOP_FROM not in names:
        die('%s: no %s in the body slot to start the electrocution loop on' % (wax, LOOP_FROM))
    i0 = names.index(LOOP_FROM)
    if LOOP_TO not in names[i0:]:
        die('%s: no %s after %s in the body slot to end the loop on' % (wax, LOOP_TO, LOOP_FROM))
    i1 = names.index(LOOP_TO, i0)
    w0, w1 = st[id(body)][i0], st[id(body)][i1] + body['hold'][i1]
    win = [x for x in steps if w0 <= x['t'] < w1]
    out = [x for x in steps if x['t'] < w0]
    for k in range(0, LOOP_EXTRA + 1):
        out += [dict(x, loop=k, smoke=(k == 0 and i == 0),
                     yell=('scream' if i == 0 and k in SCREAM_PASSES else ''),
                     zap=(i == 0),
                     mash=(i == 0 and k >= MASH_FROM_PASS))
                for i, x in enumerate(win)]
    post = [x for x in steps if x['t'] >= w1]
    if post and LOOP_EXTRA >= MASH_FROM_PASS:
        post[0]['mash'] = True          # the last rotation gets checked too
    out += post
    if not out[0]['yell']:
        out[0]['yell'] = 'death'    # the bolt reaches him: do_raiden_shocker's voice
    t = 0
    for x in out:
        x['t'] = t
        t += x['hold']
    return dict(name=name, wax=wax, direct=direct, slot=vs, body=body, bolt=bolt, vic=vic,
                steps=out, total=t,
                label='rd_lift_vic_script' + ('_' + name.lower() if direct else ''))


def families():
    pieces = first_pieces()
    # The default is named DEF so a family can be LK (Liu Kang's own project);
    # its frames are Liu Kang's, so its slot is still picked by LK.
    fams = [timeline('DEF', DEFAULT_WAX, False, pieces, ('LK',))]
    owner = {}
    for entry in FAMILIES:
        name, wax, ochars = entry[:3]
        prefixes = entry[3] if len(entry) > 3 else (name,)
        for c in ochars:
            if c in owner:
                die('ochar %d is in both %s and %s' % (c, owner[c], name))
            owner[c] = name
        fam = timeline(name, wax, True, pieces, prefixes, fams[0])
        fam['ochars'] = ochars
        fams.append(fam)

    ref = fams[0]

    def sig(f):
        return [(f['body']['names'][x['b']], f['bolt']['names'][x['o']], x['hold'], x['loop'],
                 x['smoke'], x['yell'], x['zap']) for x in f['steps']]
    for f in fams[1:]:
        if sig(f) != sig(ref):
            for n, (a, b) in enumerate(zip(sig(f) + [None] * len(sig(ref)), sig(ref)), 1):
                if a != b:
                    die('%s does not step like %s (first difference at step %d: %s vs %s) - '
                        'the Raiden and bolt lanes are shared, so every family must match '
                        'them frame for frame' % (f['wax'], ref['wax'], n, a, b))
    return fams, owner, pieces


def placement(vic, e):
    """(x, y, mirrored, upside down) for a victim entry, in Raiden's facing.

    imgtool's mirror is a bitmask - 1 = X, 2 = Y (kWorldFrameMirrorX/Y) - and
    its exporter negates each delta only when that axis is NOT mirrored
    (ui_canvas.cpp: out_dx = (m & X) ? dx : -dx, out_dy = (m & Y) ? dy : -dy).
    RAIDELECLIUFRONT hangs Liu Kang head down, so Y now follows the same rule
    X always has."""
    m = vic['mirror'][e]
    return ((vic['dx'][e] if m & 1 else -vic['dx'][e]),
            (vic['dy'][e] if m & 2 else -vic['dy'][e]),
            m & 1, m & 2)


def pose_label(fam, e):
    n = fam['vic']['names'][e]
    return fam['vic']['frames'][e] if fam['direct'] else POSES[n][0]


def rig_pose(fam, e):
    n = fam['vic']['names'][e]
    return RECORD_ALIASES.get(n, n) if fam['direct'] else POSES[n][1]


def tag(st):
    return '  (loop %d)' % st['loop'] if st['loop'] else ''


def comment_start(s, idx, lead):
    while idx > 0:
        prev_start = s.rfind('\n', 0, idx - 1) + 1
        if s[prev_start:idx - 1].startswith(lead):
            idx = prev_start
        else:
            break
    return idx


def replace_region(s, start, end, new):
    return s[:start] + new + s[end:]


GEN = 'GENERATED by tools/raiden_lift_wax_import.py from data/RAIDELEC*.WAX'


def gen_mkrd(s, ref):
    body, bolt, steps = ref['body'], ref['bolt'], ref['steps']
    m = re.search(r'^a_death_zap1[ \t]*$', s, re.M)
    if not m:
        die('a_death_zap1 not found in MKRD.ASM')
    start = comment_start(s, m.start(), ';')
    end = re.compile(r'^RN1DETHBLO1[ \t]*$', re.M).search(s, m.end())
    if not end:
        die('RN1DETHBLO1 wrapper not found after a_death_zap1')
    out = ['; %s - re-run' % GEN,
           '; it after editing a WAX instead of editing these rows.  One row per STEP of',
           '; the WAX timeline (a step ends whenever the body, the bolt or the victim',
           '; changes frame); do_raiden_lift_fatal walks both lanes with the victim',
           "; script's holds.  Every victim family shares these two lanes.",
           'a_death_zap1',
           '\t.long\tRN1DETHBLO1\t\t; lead-in, before the WAX (%d ticks)' % LEAD_HOLD]
    for i, st in enumerate(steps, 1):
        out.append('\t.long\t%s\t\t; step %2d  WAX %d' % (body['names'][st['b']], i, st['b']) + tag(st))
    out += ['\t.long\t0', '', 'a_death_bolt1']
    for i, st in enumerate(steps, 1):
        out.append('\t.long\t%s\t\t; step %2d  WAX %d' % (bolt['names'][st['o']], i, st['o']) + tag(st))
    out += ['\t.long\t0', '', '']
    return replace_region(s, start, end.start(), '\n'.join(out))


def gen_mkdeath(s, fams, owner):
    m = re.search(r'^rd_lift_vic_scripts?[ \t]*$', s, re.M)
    if not m:
        die('rd_lift_vic_script(s) not found in MKRDLIF.ASM')
    start = comment_start(s, m.start(), ';')
    end = s.find('\n; Per-fighter poses', m.end())
    if end < 0:
        die('"; Per-fighter poses" not found after rd_lift_vic_script(s)')
    label = {f['name']: f['label'] for f in fams}
    out = ['; %s - re-run' % GEN,
           '; it after editing a WAX instead of editing these rows.',
           ';',
           "; rd_lift_vic_scripts - the victim script for each ochar: his family's project",
           '; if he has one, otherwise the default (data/%s, authored on Liu Kang).' % DEFAULT_WAX,
           ';',
           '; One script entry per step: .long frame, .word X, Y, flags, hold in ticks.',
           '; flags: bit 0 = mirrored, bit 1 = start the smoke (rd_lift_smoke),',
           ';        bit 2 = he screams (disturbing_scream, off by default),',
           ";        bit 3 = his death voice (rsnd_death_voice) - do_raiden_shocker's,",
           ';        bit 4 = the long IS his frame (a family project), else a per-fighter pose',
           ';        table get_char_long picks his frame from (the default project).',
           ';        bit 5 = check the Up + HP mash when this step ends (rd_lift_mash_ok).',
';        bit 6 = drawn upside down (flip_multi_v) - RAIDELECLIUFRONT hangs him.',
           ';        bit 7 = re-send the super zap (tsound 0c7h), as do_raiden_fry does.',
           ';        bit 8 = his X-RAY (an MKSHOCK.IMG frame): rd_lift_buzz puts him on the',
           ";        BUZ palette Raiden's costume names and holds the shock flicker off.",
           '; X/Y are already Raiden-facing anchor offsets (see rd_lift_pose_victim); the',
           '; comment keeps the raw WAX numbers.  A 0 long ends a script.',
           'rd_lift_vic_scripts']
    for c, who in enumerate(OCHAR_NAMES):
        out.append('\t.long\t%s\t; %2d - %s' % (label[owner.get(c, 'DEF')], c, who))
    for f in fams:
        vic = f['vic']
        who = (', '.join(OCHAR_NAMES[c] for c in f['ochars']) if f['direct']
               else 'everyone without a family of their own')
        out += ['', '; data/%s (victim slot %d) - %s' % (f['wax'], f['slot'], who), f['label']]
        for i, st in enumerate(f['steps'], 1):
            e = st['v']
            x, y, mr, vf = placement(vic, e)
            out.append('\t.long\t%s' % pose_label(f, e))
            flags = (mr | (2 if st['smoke'] else 0) | YELL_BITS.get(st['yell'], 0)
                     | (DIRECT_BIT if f['direct'] else 0)
                     | (MASH_BIT if st['mash'] else 0)
                     | (VFLIP_BIT if vf else 0)
                     | (ZAP_BIT if st['zap'] else 0)
                     | (XRAY_BIT if vic['xray'][e] else 0))
            notes = ' '.join(n for n in ('mirrored' if mr else '', 'UPSIDEDOWN' if vf else '',
                                         'XRAY' if vic['xray'][e] else '',
                                         'SMOKE' if st['smoke'] else '',
                                         st['yell'].upper(), 'ZAP' if st['zap'] else '',
                                         'MASH' if st['mash'] else '',
                                         'loop %d' % st['loop'] if st['loop'] else '') if n)
            out.append(('\t.word\t%d,%d,%d,%d\t\t; step %2d  WAX %-2d dA %3d,%3d  %s'
                        % (x, y, flags, st['hold'], i, e, vic['dx'][e], vic['dy'][e],
                           notes)).rstrip())
        out.append('\t.long\t0')
    out.append('')
    return replace_region(s, start, end + 1, '\n'.join(out))


def gen_rig(s, fams, owner, pieces):
    m = re.search(r'^local WAX(_SEQS?)? = \{', s, re.M)
    if not m:
        die('WAX table not found in the rig')
    start = comment_start(s, m.start(), '--')
    end = s.find('\nlocal M_FLIPH', m.end())
    if end < 0:
        die('"local M_FLIPH" not found in the rig')
    out = ['-- %s - do not' % GEN,
           "-- hand-edit.  Each victim family's WAX timeline from the frame the bolt",
           "-- appears: each step's Raiden body piece, bolt piece, victim pose (a label",
           "-- fragment the drawn piece must contain), his anchor relative to Raiden's (in",
           "-- Raiden's facing), whether he is mirrored (m) or upside down (v), and how",
           '-- many frames the step holds.',
           'local WAX_SEQS = {']
    for f in fams:
        vic = f['vic']
        out.append('    %s = {' % f['name'])
        for st in f['steps']:
            e = st['v']
            x, y, mr, vf = placement(vic, e)
            out.append('        { body = "%s", bolt = "%s", pose = "%s", x = %d, y = %d, m = %s, v = %s, frames = %d },'
                       % (pieces[f['body']['names'][st['b']]], pieces[f['bolt']['names'][st['o']]],
                          rig_pose(f, e), x, y, 'true' if mr else 'false',
                          'true' if vf else 'false', st['hold']))
        out.append('    },')
    out.append('}')
    out.append('local WAX_FAMILY = { %s }' % ', '.join(
        '[%d] = "%s"' % (c, n) for c, n in sorted(owner.items())))
    out += ['local WAX_TOTAL = %d' % fams[0]['total'],
            'local WAX_SEQ = WAX_SEQS[WAX_FAMILY[FT_VICTIM] or "DEF"]', '']
    return replace_region(s, start, end + 1, '\n'.join(out))


def pose_table(f):
    vic = f['vic']
    rows = ['| WAX | Pose | WAX dA (x,y) | Mirrored | Upside down | Game offset (x,y) | Hold |',
            '|---:|---|---:|:-:|:-:|---:|---:|']
    for e, n in enumerate(vic['names']):
        x, y, mr, vf = placement(vic, e)
        rows.append('| %d | %s | %d,%d | %s | %s | %d,%d | %d |'
                    % (e, n if f['direct'] else n[2:], vic['dx'][e], vic['dy'][e],
                       'yes' if mr else '', 'yes' if vf else '', x, y, vic['hold'][e]))
    return rows


def gen_doc(s, fams):
    ref = fams[0]
    body, bolt, vic, steps = ref['body'], ref['bolt'], ref['vic'], ref['steps']
    i = s.find('## Row timeline\n')
    j = s.find('## Victim poses', i)
    if i < 0 or j < 0:
        die('doc timeline section not found')
    out = ['## Row timeline', '',
           'Generated from the WAX: one row per step (a step ends whenever any lane',
           'changes frame). The %s-%s stretch plays %d more times after its WAX'
           % (LOOP_FROM, LOOP_TO, LOOP_EXTRA),
           'pass, and the smoke starts on its first step. Every family shares these steps;',
           'the victim column is the default project.', '',
           '| Step | Body | Bolt | Victim | Hold (ticks) |', '|---:|---|---|---|---:|',
           '| 0 | RN1DETHBLO1 | - | untouched (lead-in) | %d |' % LEAD_HOLD]
    for n, st in enumerate(steps, 1):
        out.append('| %d | %s | %s | WAX %d %s | %d |'
                   % (n, body['names'][st['b']], bolt['names'][st['o']], st['v'],
                      vic['names'][st['v']][2:] + tag(st)
                      + (' + smoke starts' if st['smoke'] else '')
                      + (' + %s' % st['yell'] if st['yell'] else '')
                      + (' + mash check' if st['mash'] else ''),
                      st['hold']))
    out += ['', 'Then `r_shocker_pop` blows the victim apart. His head (`rd_lift_head`) flies',
            'straight up out of the burst and off the top of the frame, stays there while',
            'the debris lands, then falls back LAST and bounces four times, each lower', '(`rd_lift_head_bounces`).', '', '']
    s = replace_region(s, i, j, '\n'.join(out))

    i = s.find('| WAX | Pose |')
    j = s.find('\n\n**What the WAX offset is.**', i)
    if i < 0 or j < 0:
        die('doc pose table not found')
    rows = pose_table(ref)
    for f in fams[1:]:
        rows += ['', '**%s family** - `data/%s`, victim slot %d, frames named outright - %s:'
                 % (f['name'], f['wax'], f['slot'],
                    ', '.join(OCHAR_NAMES[c] for c in f['ochars'])), '']
        rows += pose_table(f)
    return replace_region(s, i, j, '\n'.join(rows))


def load(path):
    raw = open(path, encoding='utf-8', errors='surrogateescape', newline='').read()
    nl = '\r\n' if '\r\n' in raw else '\n'
    return raw.replace('\r\n', '\n'), nl


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--check', action='store_true', help='exit 1 if any generated block is stale')
    a = ap.parse_args()

    fams, owner, pieces = families()
    ref = fams[0]
    jobs = [(MKRD, lambda s: gen_mkrd(s, ref)),
            (MKRDLIF, lambda s: gen_mkdeath(s, fams, owner)),
            (RIG, lambda s: gen_rig(s, fams, owner, pieces)),
            (DOC, lambda s: gen_doc(s, fams))]
    stale = []
    for path, fn in jobs:
        s, nl = load(path)
        new = fn(s)
        if new != s:
            stale.append(os.path.relpath(path, ROOT))
            if not a.check:
                open(path, 'w', encoding='utf-8', errors='surrogateescape',
                     newline='').write(new.replace('\n', nl))

    print('%d steps, %d ticks after the %d-tick lead-in:' % (len(ref['steps']), ref['total'], LEAD_HOLD))
    for n, st in enumerate(ref['steps'], 1):
        extra = tag(st) + (' SMOKE' if st['smoke'] else '') + (' ' + st['yell'].upper() if st['yell'] else '') + (' MASH' if st['mash'] else '')
        poses = '  '.join('%s %-13s (%d,%d)%s' % (f['name'], f['vic']['names'][st['v']],
                                                  placement(f['vic'], st['v'])[0],
                                                  placement(f['vic'], st['v'])[1],
                                                  ('m' if placement(f['vic'], st['v'])[2] else ' ')
                                                  + ('v' if placement(f['vic'], st['v'])[3] else ''))
                          for f in fams)
        print('  step %2d  t=%3d hold %d  %-13s %-14s WAX %-2d %s%s'
              % (n, st['t'], st['hold'], ref['body']['names'][st['b']],
                 ref['bolt']['names'][st['o']], st['v'], poses, extra))
    for f in fams:
        print('  family %s: data/%s victim slot %d%s' % (
            f['name'], f['wax'], f['slot'],
            (' - ' + ', '.join(OCHAR_NAMES[c] for c in f['ochars'])) if f['direct'] else ' (default)'))
    if a.check:
        if stale:
            print('STALE (re-run tools/raiden_lift_wax_import.py): ' + ', '.join(stale))
            return 1
        print('up to date')
    else:
        print('rewrote: ' + (', '.join(stale) if stale else 'nothing (already current)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
