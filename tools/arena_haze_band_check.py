"""Which world rows the arena's haze envelope actually MOVES, read off the screen.

    python tools/arena_haze_band_check.py <run dir>

tools/arena_haze_test.lua HAZE_BAND=1 freezes the scene and leaves the haze
LIVE, so across the 16 band_NN shots nothing moves but the sky.  A row that is
identical in all of them is a row the envelope left alone; a row that is not is
one it moves.  The still rows are the reference: the plain blocks are no use as
one, because the whole plane rests SKR_AMP px left of its scroll limit.

That is checked against arena_sky_haze (src/BGND.ASM).  The sharp gate is the
negative one - NO row outside the envelope may move - because that is the half
a covered row cannot fake.  A row inside it that never moved is reported, not
failed: the towers cover most of this plane and the HUD covers the rest of the
top (the right-hand cloud's rows 27-31 sit under the "00 WINS" text), so a
hazed row with no sky on screen has nothing to show.  What is required of each
BAND is that at least one of its rows moved, which is what says it is live.
"""
import re, sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
run = Path(sys.argv[1])
lab = {}
for ln in (run / "haze.log").read_text().splitlines():
    m = re.search(r"SNAP (\d{4}) (\S+)", ln)
    if m:
        lab[m.group(2)] = run / "snap/mk2" / f"{m.group(1)}.png"
shots = [Image.open(lab[k]).convert("RGB") for k in sorted(lab) if k.startswith("band_")]
W, H = shots[0].size
print(f"{len(shots)} haze shots, {W}x{H}")

rp = list(shots[0].getdata())
moved = [0] * H
for im in shots[1:]:
    px = list(im.getdata())
    for y in range(H):
        o = y * W
        n = sum(1 for x in range(W) if px[o + x] != rp[o + x])
        if n > moved[y]:
            moved[y] = n

# the envelope, as the ROM carries it
t = (ROOT / "src" / "BGND.ASM").read_text(errors="replace")
blk = re.split(r"(?m)^arena_sky_haze\s*$", t)[1]   # the LABEL, not the .long that names it
words = []
for ln in blk.splitlines()[1:]:
    if re.match(r"\s*([;*]|$)", ln):
        continue                      # a comment line must not truncate the table
    m = re.match(r"\s*\.word\s+([0-9,\s]+)", ln)
    if not m:
        if words:
            break
        continue
    words += [int(v) for v in m.group(1).replace(" ", "").split(",") if v != ""]
if len(words) - 2 != words[1]:
    sys.exit(f"arena_sky_haze says {words[1]} rows but carries {len(words) - 2} tiers")
first, nrows, tiers = words[0], words[1], words[2:2 + words[1]]
env = {first + i: tiers[i] for i in range(nrows)}
print(f"arena_sky_haze: rows {first}..{first + nrows - 1}")

# worldtly is 0 on this stage, so screen row == world row; take it from the log
wty = 0
m = re.search(r"worldty=(\d+)", (run / "haze.log").read_text())
if m:
    wty = int(m.group(1))

runs, cur = [], None
for wy in sorted(env):
    if env[wy]:
        if cur and cur[1] == wy - 1 and env[cur[1]]:
            cur[1] = wy
        else:
            runs.append(cur := [wy, wy])
    else:
        cur = None

bad, covered = [], []
print(" row tier  moved px")
for y in range(H):
    wy = y + wty
    tier = env.get(wy, 0)
    if moved[y] or tier:
        print(f" {wy:4d}  {tier}   {moved[y]:5d}")
    if tier == 0 and moved[y]:
        bad.append(f"row {wy} is OUTSIDE the envelope and moved {moved[y]} px")
    if tier and not moved[y]:
        covered.append(wy)
for a, b in runs:
    if not any(moved[wy - wty] for wy in range(a, b + 1) if 0 <= wy - wty < H):
        bad.append(f"band {a}-{b} never moved - that band is not live")
print()
if covered:
    print(f"  covered (in the band, no sky on screen): "
          f"{', '.join(str(w) for w in covered)}")
for b in bad:
    print("  !", b)
print("ENVELOPE LIVE AND NOTHING ELSE MOVES" if not bad else f"{len(bad)} disagreements")
sys.exit(1 if bad else 0)
