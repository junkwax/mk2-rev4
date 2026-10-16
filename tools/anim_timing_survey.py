#!/usr/bin/env python3
"""Survey every animation SLEEP the shipped game actually uses.

MK2 hands the per-row hold to the animator three ways:

  animate_a9 / animate2_a9   a9 = [sleep:16 | ani_index:16]   (MKUTIL.ASM)
  mframew / mframew_a0       a0 = sleep   (a0 = [sleep|frames] for _a0)
  init_anirate + next_anirate a0 = ticks per frame

One sleep is one 18.28ms game tick, so sleep N plays at 54.7/N fps.  This is the
answer to "is sleep 4 normal?" - it prints the distribution so a new lane can
be judged against the game rather than against a preview.
"""
import os, re, collections

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'src')

def num(tok):
    tok = tok.strip()
    m = re.fullmatch(r'0?([0-9A-Fa-f]+)[Hh]', tok)
    if m:
        return int(m.group(1), 16)
    if re.fullmatch(r'-?\d+', tok):
        return int(tok)
    return None

a9_sleep = collections.Counter()      # animate_a9 family
mfw_sleep = collections.Counter()     # mframew family
rate = collections.Counter()          # init_anirate
examples = collections.defaultdict(list)

for fn in sorted(os.listdir(SRC)):
    if not fn.endswith('.ASM'):
        continue
    lines = open(os.path.join(SRC, fn), errors='replace').read().split('\n')
    for i, l in enumerate(lines):
        c = l.split(';')[0]
        m = re.search(r'\b(?:jsrp|calla|jauc|jruc)\s+(animate2?_a9)\b', c)
        if m:
            for back in range(1, 8):
                if i - back < 0: break
                p = lines[i-back].split(';')[0]
                mm = re.search(r'\bmov[ik]\s+([0-9A-Fa-fHh]+)\s*,\s*a9\b', p)
                if mm:
                    v = num(mm.group(1))
                    if v is not None:
                        s = v >> 16
                        a9_sleep[s] += 1
                        if len(examples[('a9', s)]) < 3:
                            examples[('a9', s)].append(f"{fn}:{i-back+1}")
                    break
        m = re.search(r'\b(?:jsrp|calla|jauc|jruc)\s+(mframew(?:_a0)?)\b', c)
        if m:
            for back in range(1, 8):
                if i - back < 0: break
                p = lines[i-back].split(';')[0]
                mm = re.search(r'\bmov[ik]\s+([0-9A-Fa-fHh]+)\s*,\s*a0\b', p)
                if mm:
                    v = num(mm.group(1))
                    if v is not None:
                        s = (v >> 16) if (m.group(1).endswith('_a0') and v > 0xffff) else v
                        mfw_sleep[s] += 1
                        if len(examples[('mf', s)]) < 3:
                            examples[('mf', s)].append(f"{fn}:{i-back+1}")
                    break
        if re.search(r'\bcalla\s+init_anirate\b', c):
            for back in range(1, 5):
                if i - back < 0: break
                p = lines[i-back].split(';')[0]
                mm = re.search(r'\bmov[ik]\s+([0-9A-Fa-fHh]+)\s*,\s*a0\b', p)
                if mm:
                    v = num(mm.group(1))
                    if v is not None:
                        rate[v] += 1
                    break

def report(title, ctr, key):
    tot = sum(ctr.values())
    print(f"\n=== {title}  ({tot} call sites) ===")
    print(f"{'sleep':>5} {'fps':>7} {'sites':>6} {'share':>6}   examples")
    for s in sorted(ctr):
        if s > 64:
            continue
        fps = 54.7 / s if s else 0
        ex = ', '.join(examples[(key, s)][:3])
        print(f"{s:>5} {fps:>7.2f} {ctr[s]:>6} {100*ctr[s]/tot:>5.1f}%   {ex}")

report("animate_a9 / animate2_a9", a9_sleep, 'a9')
report("mframew", mfw_sleep, 'mf')
tot = sum(rate.values())
print(f"\n=== init_anirate  ({tot} call sites) ===")
print(f"{'rate':>5} {'fps':>7} {'sites':>6}")
for s in sorted(rate):
    if s > 64: continue
    print(f"{s:>5} {54.7/s if s else 0:>7.2f} {rate[s]:>6}")


# ---- second pass: attribute each call site to its enclosing routine --------
def enclosing(lines, i):
    for j in range(i, -1, -1):
        m = re.match(r'^([a-z_][a-z0-9_]*)\b', lines[j])
        if m and not lines[j].startswith((' ', '\t')):
            return m.group(1)
    return '?'

print("\n\n=== named call sites (sleep by routine) ===")
hits = []
for fn in sorted(os.listdir(SRC)):
    if not fn.endswith('.ASM'):
        continue
    lines = open(os.path.join(SRC, fn), errors='replace').read().split('\n')
    for i, l in enumerate(lines):
        c = l.split(';')[0]
        kind = None
        if re.search(r'\b(?:jsrp|calla|jauc|jruc)\s+animate2?_a9\b', c): kind, reg = 'animate_a9', 'a9'
        elif re.search(r'\b(?:jsrp|calla|jauc|jruc)\s+mframew\b', c):    kind, reg = 'mframew', 'a0'
        elif re.search(r'\bcalla\s+init_anirate\b', c):                  kind, reg = 'init_anirate', 'a0'
        if not kind:
            continue
        for back in range(1, 8):
            if i - back < 0: break
            mm = re.search(r'\bmov[ik]\s+([0-9A-Fa-fHh]+)\s*,\s*' + reg + r'\b',
                           lines[i-back].split(';')[0])
            if mm:
                v = num(mm.group(1))
                if v is None: break
                s = (v >> 16) if reg == 'a9' else v
                if 0 < s <= 16:
                    hits.append((enclosing(lines, i), kind, s, fn))
                break

seen = set()
for rt, kind, s, fn in hits:
    key = (rt, kind, s)
    if key in seen: continue
    seen.add(key)
    if any(t in rt for t in ('spin', 'stance', 'walk', 'punch', 'kick', 'victory',
                             'fatal', 'death', 'jump', 'throw', 'uppercut', 'sweep',
                             'react', 'fall', 'getup', 'block')):
        print(f"  {rt:<26} {kind:<13} sleep {s:>2}  ({54.7/s:5.2f} fps)   {fn}")
