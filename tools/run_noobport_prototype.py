"""Run the NOOBPORT mixed-depth MAME prototype with private cfg/NVRAM.

Example: python tools/run_noobport_prototype.py --rom-dir tmp/nbpproto/rom
Composes tools/noobport_runtime_test.lua (packing) with the existing
tools/noob_portal_test.lua (the move itself).  Does not build, install ROMs,
or stop another emulator session - it runs under its own executable name and
its own directories so a concurrent rig is neither killed nor joined.
"""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mame', type=Path, default=Path('C:/MAME/mame_mk2test.exe'))
    p.add_argument('--rom-dir', type=Path, default=ROOT/'tmp/nbpproto/rom')
    p.add_argument('--output', type=Path, default=ROOT/'tmp/nbpproto/tests')
    p.add_argument('--seconds', type=int, default=200)
    args = p.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    d = Path(tempfile.mkdtemp(prefix='run-', dir=args.output.resolve()))
    for name in ('ini', 'cfg', 'nvram', 'snap', 'state', 'input'):
        (d/name).mkdir()
    rom = args.rom_dir.resolve()
    inputs = [ROOT/'src/mk2.map', ROOT/'src/NOOBPORT.TBL', rom/'mk2.zip',
              ROOT/'tools/noobport_runtime_test.lua',
              ROOT/'tools/noob_portal_test.lua']
    hashes = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}

    env = os.environ.copy()
    env.update(MK2_ROOT=str(ROOT), NOOB_TEST_LOG=str(d/'portal.log'),
               NBP_LOG=str(d/'packing.log'))
    cmd = [str(args.mame.resolve()), 'mk2', '-rompath', str(rom),
           '-inipath', str(d/'ini')]
    for option in ('cfg', 'nvram', 'snapshot', 'state', 'input'):
        cmd += ['-'+option+'_directory', str(d/{'snapshot': 'snap'}.get(option, option))]
    cmd += ['-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
            '-autoboot_script', str(ROOT/'tools/noobport_runtime_test.lua'),
            '-seconds_to_run', str(args.seconds)]

    ok = False
    try:
        with (d/'mame.log').open('w') as log:
            result = subprocess.run(
                cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
                timeout=args.seconds + 120)
        portal = (d/'portal.log').read_text(errors='replace')
        packing = (d/'packing.log').read_text(errors='replace')
        ok = (result.returncode == 0
              and '[portal] PASS' in portal and '[portal] ERROR' not in portal
              and '[nbp] PASS' in packing and '[nbp] ERROR' not in packing)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f'run failed: {exc}')

    changed = [str(f) for f in inputs
               if hashlib.sha256(f.read_bytes()).hexdigest() != hashes[str(f)]]
    (d/'result.json').write_text(json.dumps(
        dict(inputs_sha256=hashes, passed=ok, log_directory=str(d),
             inputs_changed_during_run=changed), indent=2) + '\n', encoding='utf-8')
    print(f"{'PASS' if ok and not changed else 'FAIL'} ({d})")
    if changed:
        print('FAIL: inputs changed during test:', changed)
    return 0 if ok and not changed else 1


if __name__ == '__main__':
    raise SystemExit(main())
