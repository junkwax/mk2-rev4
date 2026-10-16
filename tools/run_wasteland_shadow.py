"""Compare slow/fast shadows on the same frozen ROM and deterministic inputs.

Produces gameplay-state CSVs, DMA start timing, and paired screenshots.
Pixel differences are reported, never silently accepted as shadow fixes.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rom-dir',type=Path,default=ROOT/'rom')
    ap.add_argument('--map',type=Path,default=ROOT/'src/mk2.map')
    ap.add_argument('--p1',type=int,default=8)
    ap.add_argument('--p2',type=int,default=1)
    ap.add_argument('--fast-mode',type=int,choices=[1,2],default=2)
    ap.add_argument('--native',action='store_true',help='test stage-selected mode without overriding it')
    ap.add_argument('--expected-native-mode',type=int,choices=[0,1,2],help='expected stage-selected mode; required for native checks')
    ap.add_argument('--stage',type=int,default=2)
    ap.add_argument('--output',type=Path,default=ROOT/'tmp/wasteland_shadow')
    ap.add_argument('--mame',type=Path,default=Path('C:/MAME/mame_mk2test.exe'))
    a=ap.parse_args()
    if a.native and a.expected_native_mode is None:
        ap.error('--native requires --expected-native-mode')
    a.output.mkdir(parents=True,exist_ok=True)
    run=Path(tempfile.mkdtemp(prefix=f'{a.p1}-{a.p2}-',dir=a.output.resolve()))
    frozen=run/'frozen';(frozen/'src').mkdir(parents=True);(frozen/'rom').mkdir()
    shutil.copy2(a.map,frozen/'src/mk2.map');shutil.copy2(a.rom_dir/'mk2.zip',frozen/'rom/mk2.zip')
    summary={'p1':a.p1,'p2':a.p2,'stage':a.stage,'fast_mode':a.fast_mode,'native':a.native,'inputs_sha256':{str(p.relative_to(frozen)):hashlib.sha256(p.read_bytes()).hexdigest() for p in frozen.rglob('*') if p.is_file()},'modes':{}}
    traces=[];shots=[]
    for fast in ([-1] if a.native else [0,a.fast_mode]):
        d=run/str(fast);d.mkdir()
        for sub in ('ini','cfg','nvram','snap','state','input'):(d/sub).mkdir()
        env=os.environ.copy();env.update(MK2_ROOT=str(frozen),SHADOW_STAGE=str(a.stage),SHADOW_FAST=str(fast),SHADOW_P1=str(a.p1),SHADOW_P2=str(a.p2),SHADOW_LOG=str(d/'probe.log'),SHADOW_TRACE=str(d/'trace.csv'))
        if a.native:env['SHADOW_EXPECTED_MODE']=str(a.expected_native_mode)
        cmd=[str(a.mame),'mk2','-rompath',str(frozen/'rom'),'-inipath',str(d/'ini')]
        for opt,sub in [('cfg','cfg'),('nvram','nvram'),('snapshot','snap'),('state','state'),('input','input')]:cmd+=['-'+opt+'_directory',str(d/sub)]
        (d/'go.ds').write_text('go\n',encoding='ascii')
        cmd+=['-video','gdi','-sound','none','-nothrottle','-skip_gameinfo','-autoboot_script',str(ROOT/'tools/wasteland_shadow_test.lua'),'-seconds_to_run','180',
              '-debug','-debugscript',str(d/'go.ds'),'-window','-nomax']
        with (d/'mame.log').open('w') as f:
            subprocess.run(cmd,cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0),timeout=600,check=True)
        text=(d/'probe.log').read_text()
        if 'PASS 27 captures' not in text:raise RuntimeError(f'No completed verdict: {d}')
        with (d/'trace.csv').open() as f:rows=list(csv.DictReader(f))
        assert len(rows)==781,len(rows)
        traces.append(rows);shots.append(sorted((d/'snap').rglob('*.png')))
        assert len(shots[-1])==27,len(shots[-1])
        summary['modes'][str(fast)]={'mean_blits':sum(int(r['blits']) for r in rows)/len(rows),'mean_last_start':sum(float(r['last_start']) for r in rows)/len(rows),'worst_last_start':max(float(r['last_start']) for r in rows),'late_delta':int(rows[-1]['late'])-int(rows[0]['late']),'lost_max':max(int(r['lost']) for r in rows)}
    keys=['r','x1','y1','shape1','flags1','x2','y2','shape2','flags2','worldx','worldy']
    summary['state_mismatches']=[int(x['r']) for x,y in zip(*traces) if any(x[k]!=y[k] for k in keys)] if len(traces)==2 else []
    from PIL import Image
    import numpy as np
    differences=[]
    for i,(x,y) in enumerate(zip(*shots) if len(shots)==2 else []):
        p=np.array(Image.open(x).convert('RGB'));q=np.array(Image.open(y).convert('RGB'))
        assert p.shape==q.shape
        mask=np.any(p!=q,axis=2);ys,xs=np.where(mask)
        differences.append({'frame':120+i*30,'pixels':int(mask.sum()),'bounds':([int(xs.min()),int(ys.min()),int(xs.max()),int(ys.max())] if len(xs) else None)})
    summary['screen_differences']=differences
    if a.native:summary['expected_native_mode']=a.expected_native_mode
    (run/'result.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(summary['modes'],indent=2));print('State mismatches:',len(summary['state_mismatches']));print('Differing screenshots:',sum(bool(d['pixels']) for d in differences));print('Results:',run/'result.json')
    return 1 if summary['state_mismatches'] or any(d['pixels'] for d in differences) or any(m['late_delta'] for m in summary['modes'].values()) else 0


if __name__=='__main__':raise SystemExit(main())
