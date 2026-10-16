"""Run the BLDXPD MAME prototype with private cfg/NVRAM and explicit verdicts.

Example: python tools/run_bldxpd_prototype.py --rom-dir tmp/bldproto/rom
Does not build, install ROMs, or stop another emulator session.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mame',type=Path,default=Path('C:/MAME/mame_mk2test.exe'))
    p.add_argument('--rom-dir',type=Path,default=ROOT/'tmp/bldproto/rom')
    p.add_argument('--output',type=Path,default=ROOT/'tmp/bldproto/tests')
    p.add_argument('--side',choices=['left','right','both'],default='both')
    args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    run=Path(tempfile.mkdtemp(prefix='run-',dir=args.output.resolve()))
    rom=args.rom_dir.resolve()
    inputs=[ROOT/'src/mk2.map',ROOT/'src/BLDXPD.TBL',rom/'mk2.zip',
            ROOT/'tools/bldxpd_runtime_test.lua',ROOT/'tools/ermac_fatal_slam_test.lua']
    hashes={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
    results=[]
    for side in (['left','right'] if args.side=='both' else [args.side]):
        d=run/side;d.mkdir()
        for name in ['ini','cfg','nvram','snap','state','input']:(d/name).mkdir()
        env=os.environ.copy()
        env.update(MK2_ROOT=str(ROOT),EFS_LOG=str(d/'fatal.log'),EFS_SNAP='0',
                   EFS_SIDE=side,EFS_DIST='130',EFS_PIT='0',EFS_REPTILE='0',
                   EFS_TRACE='0',BLD_BASELINE='0',BLD_LOG=str(d/'bld.log'))
        cmd=[str(args.mame.resolve()),'mk2','-rompath',str(rom),'-inipath',str(d/'ini')]
        for option,name in [('cfg','cfg'),('nvram','nvram'),('snapshot','snap'),
                            ('state','state'),('input','input')]:
            cmd += ['-'+option+'_directory',str(d/name)]
        cmd += ['-video','none','-sound','none','-nothrottle','-skip_gameinfo',
                '-autoboot_script',str(ROOT/'tools/bldxpd_runtime_test.lua'),
                '-seconds_to_run','200']
        try:
            with (d/'mame.log').open('w') as log:
                result=subprocess.run(cmd,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,
                                      creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0),timeout=180)
            fatal=(d/'fatal.log').read_text(errors='replace')
            bld=(d/'bld.log').read_text(errors='replace')
            ok=(result.returncode==0 and '[efs] PASS ermac_fatal_slam:' in fatal
                and '[bld] PASS objects=3 failures=0' in bld
                and '[efs] FAIL' not in fatal and '[bld] ERROR' not in bld)
        except (OSError,subprocess.TimeoutExpired) as exc:
            print(f'{side}: {exc}');ok=False
        print(f"{side}: {'PASS' if ok else 'FAIL'} ({d})")
        results.append(dict(side=side,passed=ok,log_directory=str(d)))
    changed=[str(f) for f in inputs if hashlib.sha256(f.read_bytes()).hexdigest()!=hashes[str(f)]]
    report=dict(inputs_sha256=hashes,results=results,inputs_changed_during_run=changed)
    (run/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    if changed:print('FAIL: inputs changed during test:',changed)
    print('Results:',run/'result.json')
    return 0 if all(r['passed'] for r in results) and not changed else 1


if __name__=='__main__':
    raise SystemExit(main())
