#!/usr/bin/env python3
"""Frozen-ROM portal fist A/B; independent sprite witness plus exact snapshots."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import struct
import zipfile
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]


def inject_multipart(zip_path, map_path, mirrored):
    """Private test ROM only: route six portal body frames through the fist list."""
    symbols = {name: int(addr, 16) for addr, name in
               re.findall(r'([0-9a-fA-F]{8})\s+([\w.]+)', map_path.read_text())}
    with zipfile.ZipFile(zip_path) as z:
        files = {info.filename: z.read(info.filename) for info in z.infolist()}
    even = next(n for n in files if 'uj12' in n.lower())
    odd = next(n for n in files if 'ug12' in n.lower())
    flat = bytearray(len(files[even]) * 2)
    flat[0::2], flat[1::2] = files[even], files[odd]
    def offset(addr):
        if addr % 8 or not 0 <= (addr - 0xff800000) // 8 <= len(flat) - 4:
            raise ValueError(f'Invalid program pointer {addr:08x}')
        return (addr - 0xff800000) // 8
    def read(addr): return struct.unpack_from('<I', flat, offset(addr))[0]
    animation = read(symbols['sk_anitab2'] + 6 * 32)
    shape = read(animation)
    names = ['BGBIGFIST1A', 'BGBIGFIST1B', 'BGBIGFIST1C0', 'BGBIGFIST1D0',
             'BGBIGFIST1C_MIRROR' if mirrored else 'BGBIGFIST1C', 'BGBIGFIST1D']
    if [read(shape + i * 32) for i in range(7)] != [symbols[n] for n in names] + [0]:
        raise ValueError('Unexpected multipart fist layout; refusing to patch')
    start = symbols['a_sk_portpunch']
    original = [read(start + i * 32) for i in range(6)]
    for ptr in original:
        offset(ptr)  # Refuse commands or invalid addresses in place of frames.
    for i in range(6):
        struct.pack_into('<I', flat, offset(start + i * 32), shape)
    files[even], files[odd] = bytes(flat[0::2]), bytes(flat[1::2])
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items(): z.writestr(name, data)
    return dict(animation=start, replacement_shape=shape, original_frames=original,
                purpose='Synthetic multipart coverage; six attacker frames replaced only in private ROM')


def boot(args, run, label, package, side, fatal):
    out = run / f'{label}-{side}-fatal{int(fatal)}'
    frozen = out / 'frozen'
    (frozen / 'src').mkdir(parents=True)
    (frozen / 'rom').mkdir()
    shutil.copy2(package / 'rom/mk2.zip', frozen / 'rom/mk2.zip')
    shutil.copy2(package / 'mk2.map', frozen / 'src/mk2.map')
    source_hash = hashlib.sha256((frozen/'rom/mk2.zip').read_bytes()).hexdigest()
    mirrored = label == 'new' or getattr(args, 'old_mirror', False)
    injection = inject_multipart(frozen/'rom/mk2.zip', frozen/'src/mk2.map', mirrored) if args.multipart else None
    shutil.copy2(ROOT / 'tools/kahn_boss_moves_test.lua', frozen / 'driver.lua')
    shutil.copy2(ROOT / 'tools/kahn_fist_reuse_runtime.lua', frozen / 'witness.lua')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('KAHN_', 'KFR_')):
            del env[key]
    env.update(KAHN_TEST_ROOT=str(frozen), KAHN_TEST_LOG=str(out / 'driver.log'),
               KFR_OUT=str(out), KFR_MIRROR=str(int(label == 'new' or getattr(args, 'old_mirror', False))),
               KFR_MULTIPART=str(int(args.multipart)),
               KAHN_TEST_CODES='4', KAHN_PUPPET_HOLD='1', KAHN_PIN_PLAYERS='1',
               KAHN_PIN_RELEASE_ON_MOVE='1',
               KAHN_PIN_SPACING=str((224 if fatal else 72) * (1 if side == 'left' else -1)),
               KAHN_FORCE_ROUND='3', KAHN_SNAP_ENTRY='1', KAHN_SNAP_EVERY='4',
               KAHN_PORTAL_FATALITY=str(int(fatal)), KAHN_END_HOLD='180')
    # Windowed under the debugger, like every private rig here: -video none
    # boots differently from a real screen and is not how the rigs are run.
    (out / 'go.ds').write_text('go\n', encoding='ascii')
    cmd = [str(args.mame), 'mk2', '-rompath', str(frozen / 'rom'),
           '-video', 'gdi', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
           '-autoboot_script', str(frozen / 'witness.lua'), '-seconds_to_run', '120',
           '-debug', '-debugscript', str(out / 'go.ds'), '-window', '-nomax']
    for option, folder in [('inipath','ini'), ('cfg_directory','cfg'), ('nvram_directory','nvram'),
                           ('snapshot_directory','snap'), ('state_directory','state'), ('input_directory','input')]:
        (out / folder).mkdir()
        cmd += ['-' + option, str(out / folder)]
    with (out / 'mame.log').open('w') as log:
        proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    driver = (out / 'driver.log').read_text(errors='replace') if (out / 'driver.log').exists() else ''
    witness = (out / 'witness.txt').read_text() if (out / 'witness.txt').exists() else ''
    match = re.search(r'RESULT samples=(\d+) failures=(\d+) clean_tail=(\d+)', witness)
    ok = bool(proc.returncode == 0 and match and int(match[1]) > 5 and int(match[2]) == 0
              and int(match[3]) >= 30 and '[kahn-test] finished' in driver and 'ERROR' not in driver)
    fatal_seen = 'debug4=0x5020' in driver
    if fatal and not fatal_seen:
        ok = False
    multi = re.findall(r'^MULTI .*$', witness, re.M)
    if args.multipart and len(multi) < 6:
        ok = False
    return dict(output=str(out), passed=ok, exit_code=proc.returncode,
                source_rom_sha256=source_hash,
                multipart_samples=len(multi), injection=injection,
                fatal_seen=fatal_seen,
                witness=match.group(0) if match else None,
                rom_sha256=hashlib.sha256((frozen/'rom/mk2.zip').read_bytes()).hexdigest(),
                map_sha256=hashlib.sha256((frozen/'src/mk2.map').read_bytes()).hexdigest())


def compare(old, new):
    a, b = Path(old['output']), Path(new['output'])
    shots_a, shots_b = sorted((a/'snap').rglob('*.png')), sorted((b/'snap').rglob('*.png'))
    equal = 0
    differences = []
    if len(shots_a) == len(shots_b):
        for x, y in zip(shots_a, shots_b):
            with Image.open(x) as ix, Image.open(y) as iy:
                if ix.size == iy.size and ImageChops.difference(ix.convert('RGB'), iy.convert('RGB')).getbbox() is None:
                    equal += 1
                else:
                    diff = ImageChops.difference(ix.convert('RGB'), iy.convert('RGB'))
                    differences.append(dict(snapshot=x.name, bbox=diff.getbbox(),
                                            pixels=sum(p != (0,0,0) for p in diff.getdata())))
    traces = []
    for path in (a, b):
        text = (path/'witness.txt').read_text() if (path/'witness.txt').exists() else ''
        traces.append([line for line in text.splitlines() if line.startswith(('PIECE ', 'MULTI '))])
    return dict(passed=old['passed'] and new['passed'] and bool(shots_a) and
                equal == len(shots_a) == len(shots_b) and bool(traces[0]) and traces[0] == traces[1],
                snapshots=[len(shots_a),len(shots_b)], identical_snapshots=equal,
                differences=differences,
                piece_trace_equal=bool(traces[0]) and traces[0] == traces[1])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--old', type=Path, required=True)
    ap.add_argument('--new', type=Path, required=True)
    ap.add_argument('--mame', type=Path, default=Path('C:/MAME/mame_mk2test.exe'))
    ap.add_argument('--side', choices=['left','right','both'], default='both')
    ap.add_argument('--fatal', action='store_true')
    ap.add_argument('--multipart', action='store_true', help='inject six multipart fist frames into private test ROMs')
    ap.add_argument('--old-mirror', action='store_true',
                    help='the OLD package also draws through BGBIGFIST1C_MIRROR (post-prune rerun '
                         'against the frozen pre-prune package)')
    args = ap.parse_args()
    out = ROOT/'tmp/kahn_fist_runtime/runs'
    out.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run-', dir=out))
    results = []
    for side in (['left','right'] if args.side == 'both' else [args.side]):
        old = boot(args, run, 'old', args.old.resolve(), side, args.fatal)
        new = boot(args, run, 'new', args.new.resolve(), side, args.fatal)
        result = dict(side=side, fatal=args.fatal, old=old, new=new, comparison=compare(old,new))
        results.append(result)
        (run/'result.json').write_text(json.dumps(results,indent=2)+'\n')
        print(json.dumps(result), flush=True)
    return 0 if all(r['comparison']['passed'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
