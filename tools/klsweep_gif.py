"""Kung Lao escape sweep -> one synced grid GIF (+ one GIF per config).

Reads a run dir from tools/run_kunglao_escape_sweep.ps1: sweep.log's SNAPRANGE lines
say which snapshots belong to which config (one snapshot per tick from the fire).
Usage: python tools/klsweep_gif.py <run_dir> [--slow N] [--cols C]
"""
import os, re, sys
from PIL import Image, ImageDraw

run = sys.argv[1]
slow = float(sys.argv[sys.argv.index('--slow') + 1]) if '--slow' in sys.argv else 1.0
cols = int(sys.argv[sys.argv.index('--cols') + 1]) if '--cols' in sys.argv else 3
TICK_MS = 1000 / 54.7068
log = open(os.path.join(run, 'sweep.log')).read()
ranges = [(m.group(1), int(m.group(2)), int(m.group(3)))
          for m in re.finditer(r'SNAPRANGE (\S+) (\d+) (-?\d+)', log)]
summ = {m.group(1): m.group(0) for m in re.finditer(r'^(\S+)\s+launch=.*$', log, re.M)}
seqs = []
for name, a, b in ranges:
    fr = [Image.open(os.path.join(run, 'snap', '%04d.png' % i)).convert('RGB')
          for i in range(a, b + 1) if os.path.exists(os.path.join(run, 'snap', '%04d.png' % i))]
    seqs.append((name, fr))
    out = [f.copy() for f in fr]
    for t, f in enumerate(out):
        d = ImageDraw.Draw(f); d.rectangle((0, 0, 400, 11), fill=(0, 0, 0))
        d.text((3, 1), '%s  t%d' % (name, t), fill=(255, 255, 0))
    out[0].save(os.path.join(run, name + '.gif'), save_all=True, append_images=out[1:],
                duration=int(TICK_MS * slow), loop=0)
W, H = 400, 254
n = max(len(f) for _, f in seqs) + 20
rows = (len(seqs) + cols - 1) // cols
grid = []
for t in range(n):
    g = Image.new('RGB', (W * cols, H * rows))
    for k, (name, fr) in enumerate(seqs):
        f = fr[min(t, len(fr) - 1)].copy()
        d = ImageDraw.Draw(f); d.rectangle((0, 0, 400, 11), fill=(0, 0, 0))
        d.text((3, 1), '%s  t%d' % (name, min(t, len(fr) - 1)), fill=(255, 255, 0))
        g.paste(f, ((k % cols) * W, (k // cols) * H))
    grid.append(g.resize((W * cols // 2 * 2 // 1, H * rows)) if False else g)
grid[0].save(os.path.join(run, 'grid.gif'), save_all=True, append_images=grid[1:],
             duration=int(TICK_MS * slow), loop=0)
print('wrote', os.path.join(run, 'grid.gif'), len(grid), 'frames;', ', '.join(n for n, _ in seqs))
