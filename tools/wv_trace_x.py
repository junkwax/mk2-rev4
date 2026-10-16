"""Walk a lane's DRAWN X extent, the way the engine computes it.

The probe logs oxpos, which is the ANCHOR - and the anchor is meant to jump
when a frame mirrors, because ganiof mirrors the art about it. What has to be
smooth is where the ART lands, and that is what this prints:

    piece left  = oxpos - anix            unflipped
                = oxpos - (sizex-1-anix)  flipped     (MKDISP ganiof)

Run it against the project the lane was generated from and the TBLs the ROM
actually links, so a flip that the authoring compensated for one way and the
engine mirrors the other shows up as a step in `left'/`ctr'.
"""
import re, subprocess, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def tbl_records():
    recs = {}
    for f in glob.glob(os.path.join(ROOT, 'src', '*.TBL')):
        L = open(f, encoding='utf-8', errors='surrogateescape').read().split('\n')
        for i, l in enumerate(L):
            m = re.match(r'^([A-Z0-9_]+):\s*$', l)
            if not m or i + 1 >= len(L): continue
            w = re.match(r'\s*\.word\s+(-?\d+),(-?\d+),(-?\d+),(-?\d+)', L[i+1])
            if w:
                recs[m.group(1)] = tuple(int(w.group(k)) for k in (1, 2, 3, 4))
    return recs

def wrappers():
    """label -> [piece, ...] for the .long A,B,0 multipart wrappers."""
    out = {}
    for f in glob.glob(os.path.join(ROOT, 'src', '*.ASM')):
        L = open(f, encoding='utf-8', errors='surrogateescape').read().split('\n')
        for i, l in enumerate(L):
            m = re.match(r'^([A-Z0-9_]+)\s*$', l)
            nxt = L[i+1] if i + 1 < len(L) else ''
            if m and nxt.strip().startswith('.long'):
                body = nxt.split('.long', 1)[1]
            else:
                m = re.match(r'^([A-Z0-9_]+)\s+\.long\s+(.*)$', l)
                if not m: continue
                body = m.group(2)
            pieces = [p.strip() for p in body.split(';')[0].split(',')]
            pieces = [p for p in pieces if p and p != '0']
            if pieces and all(re.match(r'^[A-Z0-9_]+$', p) for p in pieces):
                out.setdefault(m.group(1), pieces)
    return out

def main(wax, slot, subst=None):
    recs, wraps = tbl_records(), wrappers()
    out = subprocess.run([sys.executable, os.path.join(ROOT,'tools','wvp_dump.py'), wax, str(slot)],
                         capture_output=True, text=True).stdout
    rows = []
    for l in out.split('\n'):
        m = re.match(r'^\s*(\d+)\s+\d+\s+\d+\s+(\S+)\s+\S+\s+(\d+)\s+(.*?)\s+(-?\d+)\s+(-?\d+)\s+d=', l)
        if m:
            rows.append((int(m.group(1)), m.group(2), int(m.group(3)),
                         m.group(4).strip(), int(m.group(5)), int(m.group(6))))
    print("%-4s %-14s %-12s %6s %6s %6s %6s  %s" %
          ("ent", "pose", "flip", "dX", "oxpos", "left", "ctr", "step"))
    prev_ctr = None
    for i, name, dly, mir, adx, ady in rows:
        label = (subst or {}).get(name, name)
        pieces = wraps.get(label, [label])
        flipx = 'flipX' in mir
        # THE SIGN RULE, per frame, the same one wvp_to_lane.py emits.
        # Preview draws at  anchor - anieff(ani + dA), and anieff mirrors the
        # WHOLE sum; the engine mirrors only the anipoint (ganiof = sizex-1-ani)
        # and adds dX separately.  Equate the two and X inverts with the flip:
        #     dX = flipx ? +dAX : -dAX
        # This used to read a flat `dX = -adx' - the rule the generator itself
        # carried until 2026-08-24 - so it traced a lane the generator no longer
        # emits and reported a JUMP at every flipX entry of a CORRECT lane.
        dX = adx if flipx else -adx
        oxpos = dX                      # relative to the seat; the seat is a constant
        lefts, rights = [], []
        for p in pieces:
            if p not in recs: continue
            w, h, ax, ay = recs[p]
            axe = (w - 1 - ax) if flipx else ax
            lefts.append(oxpos - axe)
            rights.append(oxpos - axe + w)
        if not lefts:
            print("  %2d %-14s  <no art>" % (i, label)); continue
        lo, hi = min(lefts), max(rights)
        ctr = (lo + hi) // 2
        step = "" if prev_ctr is None else "%+d" % (ctr - prev_ctr)
        flag = ""
        if prev_ctr is not None and abs(ctr - prev_ctr) > 40:
            flag = "   <== JUMP"
        print("  %2d %-14s %-12s %6d %6d %6d %6d  %s%s" %
              (i, label, mir or '-', dX, oxpos, lo, ctr, step, flag))
        prev_ctr = ctr

if __name__ == '__main__':
    S = {"SPIN1":"SAHSPIN1","SPIN2":"SAHSPIN2","SPIN3":"SAHSPIN3",
         "SPIN4":"SAHSPIN4","SPIN5":"SAHSPIN5"}
    main(sys.argv[1], int(sys.argv[2]), S)
