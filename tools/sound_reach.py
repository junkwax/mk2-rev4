"""Sound-call reachability analysis for MK2.

Builds the set of DCS sound calls the game code can actually send, then
diffs against the calls defined in MK2.PLS SOUNDCALLS.
"""
import re, glob, os, sys
from collections import defaultdict

SRC = r"C:/Users/you/Workplace/mk2-main/src"
PLS = r"C:/Users/you/Workplace/mk2-main/sound/MK2.PLS"
LST = r"C:/Users/you/Workplace/mk2-main/sound/MK2.LST"

EQUATES = {}    # symbolic `name .set <literal>` values; filled in once files load


def code(ln):
    """Strip comments from one assembler line.

    The GSP assembler treats '*' or ';' in column 1 as a whole-line comment,
    and ';' anywhere as a trailing comment.  Stripping only ';' made the
    scanner read commented-out example dispatches as live code -- MKPROP.ASM
    keeps the retail `movi 000030079h,a0 / calla random_triple` pair inside a
    '*' block as documentation for how to restore Raiden's torpedo yell, and a
    ';'-only strip marks GIB1/GIB2/GIB3 reachable off that dead example.
    """
    if ln[:1] in ('*', ';'):
        return ''
    return ln.split(';')[0]

def val(tok):
    """Resolve a dispatch operand: hex/decimal literal, or a symbolic equate."""
    tok = tok.strip().lower().rstrip(',')
    if tok in EQUATES:
        return EQUATES[tok]
    if tok.endswith('h'):
        return int(tok[:-1], 16)
    if tok.startswith('0x'):
        return int(tok, 16)
    return int(tok)

# ---------- source files (skip backups) ----------
files = []
for f in glob.glob(os.path.join(SRC, "*.ASM")) + glob.glob(os.path.join(SRC, "*.TBL")) + glob.glob(os.path.join(SRC, "*.HDR")):
    base = os.path.basename(f)
    if '.bak' in base.lower() or 'pre_' in base.lower() or base.lower().endswith(('.obj','.map')):
        continue
    files.append(f)

lines_by_file = {}
for f in files:
    with open(f, 'r', errors='replace') as fh:
        lines_by_file[f] = fh.readlines()

# ---------- symbolic equates (`name .set <literal>`) ----------
# Sound dispatches are not always hex literals.  ARENAKIN.ASM sends Goro's arena
# walk-in growl as `tsound arena_goro_growl_snd`, and DIAGMENU sends the
# operator-menu beeps as `mm_sound`/`ms_sound`.  A literal-only scan cannot see
# those, so it reports the audio behind them as unused -- which is how GORGRWL2
# (10,256 B, live) came to look like the single largest block of free space in
# the ROM.  Resolving equates here closes that blind spot for every dispatch
# form below, instead of hand-patching each one as it is discovered.
#
# Only plain literals are taken.  Expression equates (`sp_effect .set 050h*0100h`)
# are skipped: those are priority bases, not call indices.
for _lines in lines_by_file.values():
    for _ln in _lines:
        _m = re.match(r'^(\w+)\s+\.(?:set|equ)\s+([0-9a-fA-F]+h|\d+)\s*(?:;.*)?$',
                      _ln.strip())
        if _m:
            EQUATES[_m.group(1).lower()] = val(_m.group(2))
print(f"resolved equates: {len(EQUATES)}", file=sys.stderr)

# ---------- column-0 label index, for computed pool tables ----------
# Not every dispatch is `movi <literal>,a0`.  A caller can also index a .word
# table of call numbers and hand the loaded value to triple_sound:
#
#     movi    (pool_end-pool)/16,a0
#     calla   randu
#     dec     a0
#     sll     4,a0
#     addi    pool,a0
#     move    *a0,a0,w
#     jauc    triple_sound
#   pool
#     .word   079h,07ah,07bh,0105h
#
# The literal passes below see only the ENTRY COUNT in a0, never the call
# numbers, so a pool like this reads as unreachable audio.  That is exactly
# how Raiden's torpedo yells (GIB1/GIB2/GIB3 + GIB5) came to be reported
# UNREACHED while the move was playing them on every dive - and three of the
# four slots were then reclaimed or repurposed on that reading, which is what
# put "ERMAC WINS" in the middle of the superman move.  Resolving the table
# closes the whole class, not just that one site.
LABELS = {}     # lowercased column-0 label -> (file, line index)
for _f, _lines in lines_by_file.items():
    for _i, _ln in enumerate(_lines):
        if _ln[:1].isspace() or _ln[:1] in ('*', ';'):
            continue
        _m = re.match(r'^(\w+)\b', _ln)
        if _m:
            LABELS.setdefault(_m.group(1).lower(), (_f, _i))
print(f"indexed labels: {len(LABELS)}", file=sys.stderr)


def table_words(label, maxn=256):
    """Every .word value in the run of .word directives starting at `label`."""
    hit = LABELS.get(label.lower())
    if not hit:
        return []
    f, i0 = hit
    lines = lines_by_file[f]
    out = []
    for j in range(i0, len(lines)):
        s = code(lines[j]).strip()
        if j == i0:
            s = s[len(label):].strip()      # drop the label token itself
        if not s:
            continue
        if not s.startswith('.word'):
            break
        for tok in s[len('.word'):].split(','):
            tok = tok.strip()
            if not tok:
                continue
            try:
                out.append(val(tok))
            except ValueError:
                pass
            if len(out) >= maxn:
                return out
    return out

# ---------- parse triple_sndtab / triple_sndtab2 from MKSOUND.ASM ----------
mks = lines_by_file[os.path.join(SRC, "MKSOUND.ASM")]
def parse_table(start_lbl, end_lbl):
    entries = []   # (code or None-for-tune)
    inside = False
    for ln in mks:
        s = ln.strip()
        if s == start_lbl:
            inside = True; continue
        if inside:
            if s.startswith(end_lbl):
                break
            m = re.match(r'\.word\s+([^,;]+),\s*([0-9a-fA-F]+h?|\d+)', s)
            if m:
                try:
                    entries.append(val(m.group(2)))
                except ValueError:
                    entries.append(None)
            elif re.match(r'\.long\s+', s):
                entries.append(None)  # tune-script pointer entry (2 words worth)
    return entries

tab1 = parse_table("triple_sndtab", "triple_end")
tab2 = parse_table("triple_sndtab2", "triple_end2")
print(f"tab1 entries: {len(tab1)}, tab2 entries: {len(tab2)}", file=sys.stderr)

# Audit the active table, including restored/custom entries at 0xFF and above.
ORIG_TAB1_LEN = len(tab1)

reach1 = set()   # tab1 indices
reach2 = set()   # tab2 indices
direct = set()   # exact 16-bit codes sent via send_code_a3 etc.
diag   = set()   # codes only reachable from operator diagnostics

def add_range1(first, count):
    for i in range(first, first+count):
        reach1.add(i)

def add_range2(first, count):
    for i in range(first, first+count):
        reach2.add(i)

# ---------- generic regex passes over all files ----------
for f, lines in lines_by_file.items():
    base = os.path.basename(f).upper()
    n = len(lines)
    for i, ln in enumerate(lines):
        s = code(ln)

        # tsound / tsound2 macros (literal index, or an equate resolved above)
        m = re.search(r'\btsound\s+(\w+)', s)
        if m and 'tsound2' not in s:
            try: reach1.add(val(m.group(1)))
            except ValueError: pass
        m = re.search(r'\btsound2\s+(\w+)', s)
        if m:
            try: reach2.add(val(m.group(1)))
            except ValueError: pass

        # movi/movk N,a0 within 4 lines before triple_sound / triple_sound2 / random_triple / interupt_sound
        m = re.search(r'\bmov[ik]\s+(\w+),a0\b', s)
        if m:
            try: v = val(m.group(1))
            except ValueError: continue
            window = ''.join(lines[i+1:i+9])
            if re.search(r'\b(calla|callr|jruc|jauc)\s+random_triple\b', window):
                add_range1(v & 0xFFFF, v >> 16)
            elif re.search(r'\b(calla|callr|jruc|jauc)\s+triple_sound2\b', window):
                reach2.add(v)
            elif re.search(r'\b(calla|callr|jruc|jauc)\s+triple_sound\b', window):
                reach1.add(v)
            elif re.search(r'\b(calla|callr|jruc|jauc)\s+interupt_sound\b', window):
                reach1.add(v)
            elif re.search(r'\b(calla|callr|jruc|jauc)\s+psound_for_him\b', window):
                reach1.add(v)

        # computed pool: `addi <table>,a0` feeding triple_sound / triple_sound2
        m = re.search(r'\baddi\s+(\w+),a0\b', s)
        if m:
            window = ''.join(code(l) for l in lines[i+1:i+9])
            if re.search(r'\b(calla|callr|jruc|jauc)\s+triple_sound2\b', window):
                reach2.update(table_words(m.group(1)))
            elif re.search(r'\b(calla|callr|jruc|jauc)\s+triple_sound\b', window):
                reach1.update(table_words(m.group(1)))

        # movi packed,a1 before randsnd / randsnd2 / ochar_sound / rsnd_ochar / disturbing-scream style
        m = re.search(r'\bmovi\s+0?([0-9a-fA-F]+)h,a1\b', s)
        if m:
            v = int(m.group(1), 16)
            window = ''.join(lines[i+1:i+9])
            if re.search(r'\brandsnd2\b', window):
                reach2.add(v & 0xFFFF); reach2.add(v >> 16)
            elif re.search(r'\brandsnd\b', window):
                reach1.add(v & 0xFFFF); reach1.add(v >> 16)
            elif re.search(r'\b(ochar_sound|rsnd_ochar)\b', window):
                # 4 packed byte indices; count from a preceding movk N,a0 (default 1)
                cnt = 1
                back = ''.join(lines[max(0,i-3):i+1])
                mc = re.search(r'\bmovk\s+(\d+),a0\b', back)
                if mc: cnt = int(mc.group(1))
                for sh in (0,8,16,24):
                    b = (v >> sh) & 0xFF
                    add_range1(b, cnt)

        # do_ani_sound anim-script operands: .long ani_sound,N  (tab1)
        m = re.search(r'\.long\s+ani_sound\s*,\s*([0-9a-fA-F]+h?|\d+)\b', s)
        if m:
            try: reach1.add(val(m.group(1)))
            except ValueError: pass

        # MKFX cpani scripts: ".long ani_sound" alone then value on next line (tab2)
        if re.search(r'\.long\s+ani_sound\s*$', s.strip()):
            nxt = code(lines[i+1]) if i+1 < n else ''
            m2 = re.search(r'\.(long|word)\s+([0-9a-fA-F]+h?|\d+)\b', nxt)
            if m2:
                try: reach2.add(val(m2.group(2)))
                except ValueError: pass

        # direct sends: movi/movk N,a3 within 4 lines before send_code_a3
        m = re.search(r'\bmov[ik]\s+(\w+),a3\b', s)
        if m:
            window = ''.join(lines[i+1:i+9])
            if re.search(r'send_code_a3', window):
                try:
                    v = val(m.group(1))
                    (diag if base.startswith('DIAG') else direct).add(v)
                except ValueError: pass

# ---------- data tables of codes / indices ----------
def words_after(fname, label, maxn=40):
    lines = lines_by_file[os.path.join(SRC, fname)]
    out, inside = [], False
    for ln in lines:
        s = code(ln).strip()
        if s.startswith(label):
            inside = True; continue
        if inside:
            m = re.match(r'\.word\s+([0-9a-fA-F]+h?|\d+)\b', s)
            if m:
                out.append(val(m.group(1)))
                if len(out) >= maxn: break
            elif s and not s.startswith('.word'):
                break
    return out

# music tune tables (direct codes)
for t in ("round_1_tunes", "round_23_tunes", "finish_tunes", "winner_tunes"):
    for c in words_after("MAIN.ASM", t):
        direct.add(c)

# tab2 index tables
for c in words_after("MAIN.ASM", "winner_speech"):
    reach2.add(c)
for t in ("kahn_intro_taunts", "kahn_shit_taunts"):
    for c in words_after("MKBOSS.ASM", t):
        reach2.add(c)
for c in words_after("MKCANNED.ASM", "kahn_victory_taunts"):
    reach2.add(c)

# diag sound test fx table (direct codes, diagnostics)
for c in words_after("DIAGMENU.ASM", "sound_fx_table"):
    diag.add(c)

# (DIAGMENU's `movi mm_sound,a3` / `movi ms_sound,a3` operator-menu beeps --
# KOTOA/KOTOB, calls 221h/224h -- used to be hard-coded here because the
# direct-send pass only understood hex literals.  The equate table now resolves
# them from source, so the special case has been removed; verified by checking
# both still report as diagnostics-only.)

# computed sites (manually verified in source):
add_range2(0x18, 4)            # print_round_number: ROUND 1-4
add_range2(0x1C, 12)           # selsp3 / say_that_name: character names, 12 fighters
reach2.update({0x2A,0x2B,0x2C,0x2D})  # cursor_sound b1/b2 sites
add_range2(0x30, 5)            # MKREACT upc: excellent..crowd ooo
reach2.update({0x14,0x15,0x16,0x17,0x28})  # grow_msg texts w/ sounds (finish him/her, fatality, fight, flawless)

# ---------- map table indices -> host codes (each entry covers code..code+2) ----------
reachable_codes = set()
for i in reach1:
    if 0 <= i < ORIG_TAB1_LEN and tab1[i]:
        for d in (0,1,2): reachable_codes.add(tab1[i]+d)
for i in reach2:
    if 0 <= i < len(tab2) and tab2[i]:
        for d in (0,1,2): reachable_codes.add(tab2[i]+d)
reachable_codes |= {c for c in direct if c < 0x1000}
diag_codes = {c for c in diag if c < 0x1000}

# ---------- defined calls from MK2.PLS ----------
defined = {}
in_calls = False
for ln in open(PLS, errors='replace'):
    if 'SOUNDCALLS' in ln: in_calls = True; continue
    if in_calls:
        m = re.match(r'\s*(\d+)\s+immed\s+(\d+)', ln)
        if m: defined[int(m.group(1))] = int(m.group(2))
        elif 'playlist' in ln: break

# descriptions from MK2.LST
desc = {}
for ln in open(LST, errors='replace'):
    m = re.match(r'(\d+)\s+\(\$[0-9a-f]+\)\s+\d+\s+\S+\s+\S+\s+(.*)$', ln)
    if m: desc[int(m.group(1))] = m.group(2).strip()

unused = sorted(c for c in defined if c not in reachable_codes and c != 0)
only_diag = [c for c in unused if c in diag_codes]
unused = [c for c in unused if c not in diag_codes]

KNOWN = set()
for base in (745, 803, 806, 812, 818, 850, 853, 865, 877, 1023):
    KNOWN.update((base, base+1, base+2))

print(f"defined calls: {len(defined)}   reachable: {len(reachable_codes & set(defined))}   "
      f"diag-only: {len(only_diag)}   UNREACHED: {len(unused)}")
print()
print("=== UNREACHED calls (grouped) ===")
grp = []
prev = None
for c in unused + [None]:
    if c is not None and prev is not None and c == prev+1:
        grp.append(c)
    else:
        if grp:
            a,b = grp[0], grp[-1]
            tag = " <-- KNOWN-10" if a in KNOWN else ""
            print(f"  {a:4d}-{b:4d}  {desc.get(a,'?')}{tag}")
        grp = [c] if c is not None else []
    prev = c
if only_diag:
    print("\n=== reachable ONLY from operator diagnostics ===")
    for c in only_diag:
        print(f"  {c:4d}  {desc.get(c,'?')}")

# ============ PASS 2: audio-file level ============
# hit_or_blocked_sound: index a0 (hit) or a0+1 (blocked) into tab1
for f, lines in lines_by_file.items():
    for i, ln in enumerate(lines):
        s = code(ln)
        m = re.search(r'\bmov[ik]\s+([0-9a-fA-F]+h?|\d+),a0\b', s)
        if m and re.search(r'hit_or_blocked_sound', ''.join(lines[i+1:i+9])):
            try:
                v = val(m.group(1)); reach1.add(v); reach1.add(v+1)
            except ValueError: pass

reachable_codes = set()
for i in reach1:
    if 0 <= i < ORIG_TAB1_LEN and tab1[i]:
        for d in (0,1,2): reachable_codes.add(tab1[i]+d)
for i in reach2:
    if 0 <= i < len(tab2) and tab2[i]:
        for d in (0,1,2): reachable_codes.add(tab2[i]+d)
reachable_codes |= {c for c in direct if c < 0x1000}

# playlist# -> set of CMP names; call# -> playlist#
pl_cmps = defaultdict(set)
cur = None
for ln in open(PLS, errors='replace'):
    m = re.match(r'\s*playlist\s+(\d+)', ln)
    if m: cur = int(m.group(1)); continue
    m = re.search(r"\bplay\s+\d+,\s*'([^']+)'", ln)
    if m and cur is not None: pl_cmps[cur].add(m.group(1).upper())

cmp_calls = defaultdict(set)     # CMP -> calls that can play it
for call, pl in defined.items():
    for c in pl_cmps.get(pl, ()):
        cmp_calls[c].add(call)

dead_cmps, diag_cmps = [], []
for cmpname, calls in sorted(cmp_calls.items()):
    if calls & reachable_codes: continue
    if calls & diag_codes: diag_cmps.append((cmpname, sorted(calls))); continue
    dead_cmps.append((cmpname, sorted(calls)))

import os.path
SNDS = r"C:/Users/you/Workplace/mk2-main/sound/SNDS"
def sz(nm):
    p = os.path.join(SNDS, nm + ".CMP")
    return os.path.getsize(p) if os.path.exists(p) else 0

print("\n" + "="*70)
print(f"=== .CMP files with NO host-reachable sound call ({len(dead_cmps)}) ===")
tot = 0
for nm, calls in sorted(dead_cmps, key=lambda x: -sz(x[0])):
    s = sz(nm); tot += s
    d = desc.get(calls[0], '?')
    print(f"  {nm:10s} {s:7,d} B  calls {calls}  {d}")
print(f"  TOTAL: {tot:,d} bytes")
if diag_cmps:
    print(f"\n=== reachable only from operator diagnostics ({len(diag_cmps)}) ===")
    for nm, calls in diag_cmps:
        print(f"  {nm:10s} {sz(nm):7,d} B  calls {calls}  {desc.get(calls[0],'?')}")

# ============ PASS 3: confirmed corrections ============
# slip mechanic (MKREACT slip_sleep/next_*_slip): tab1 $D9-$EF cycle
for i in range(0xD9, 0xF0): reach1.add(i)

reachable_codes = set()
for i in reach1:
    if 0 <= i < ORIG_TAB1_LEN and tab1[i]:
        for d in (0,1,2): reachable_codes.add(tab1[i]+d)
for i in reach2:
    if 0 <= i < len(tab2) and tab2[i]:
        for d in (0,1,2): reachable_codes.add(tab2[i]+d)
reachable_codes |= {c for c in direct if c < 0x1000}

dead_cmps = []
tot = 0
print("\n" + "="*70)
print("=== FINAL: unused .CMP audio (no host-reachable call, non-diag) ===")
for cmpname, calls in sorted(cmp_calls.items(), key=lambda x: -sz(x[0])):
    if calls & reachable_codes or calls & diag_codes: continue
    s = sz(cmpname); tot += s
    print(f"  {cmpname:10s} {s:7,d} B  calls {sorted(calls)}  {desc.get(sorted(calls)[0],'?')}")
    dead_cmps.append(cmpname)
print(f"  {len(dead_cmps)} files, TOTAL {tot:,d} bytes")
