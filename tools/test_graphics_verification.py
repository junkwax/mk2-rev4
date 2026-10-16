"""Regression cases found while reviewing the graphics prototype guards."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import art_identity_snapshot as art
import run_floor_skip_probe as floor
import sync_inline_sags as inline
import run_hitlight_test as hitlight
import audit_rotate_art as rotate
import audit_inline_art_dependencies as inline_dependencies
import flip_scale_scan as flipscan
import run_kahn_fist_reuse as kahn
import struct
import zipfile


class VerificationFailures(unittest.TestCase):
    def test_multipart_injection_is_scoped_and_rejects_wrong_layout(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); package=root/'mk2.zip'; map_path=root/'mk2.map'
            base=0xff800000
            names=['BGBIGFIST1A','BGBIGFIST1B','BGBIGFIST1C0','BGBIGFIST1D0',
                   'BGBIGFIST1C_MIRROR','BGBIGFIST1D']
            symbols={'sk_anitab2':base,'a_sk_portpunch':base+256*8}
            symbols.update({name:base+(512+i*16)*8 for i,name in enumerate(names)})
            flat=bytearray(1024)
            struct.pack_into('<I',flat,24,base+64*8)
            struct.pack_into('<I',flat,64,base+128*8)
            for i,name in enumerate(names):
                struct.pack_into('<I',flat,128+i*4,symbols[name])
                struct.pack_into('<I',flat,256+i*4,base+(384+i*4)*8)
            map_path.write_text('\n'.join(f'{v:08x} {k}' for k,v in symbols.items()))
            with zipfile.ZipFile(package,'w') as z:
                z.writestr('uj12',flat[0::2]); z.writestr('ug12',flat[1::2]); z.writestr('video',b'unchanged')
            kahn.inject_multipart(package,map_path,True)
            with zipfile.ZipFile(package) as z:
                changed=bytearray(1024)
                changed[0::2]=z.read('uj12');changed[1::2]=z.read('ug12')
                self.assertEqual(z.read('video'),b'unchanged')
            self.assertEqual(changed[:256],flat[:256])
            self.assertEqual(changed[280:],flat[280:])
            self.assertEqual(struct.unpack_from('<6I',changed,256),(base+128*8,)*6)
            before=package.read_bytes()
            # A map that puts B's header at C's address must not produce a ROM.
            map_path.write_text(map_path.read_text().replace(f'{symbols[names[1]]:08x}',f'{symbols[names[4]]:08x}'))
            with self.assertRaises(ValueError):kahn.inject_multipart(package,map_path,True)
            self.assertEqual(package.read_bytes(),before)

    def test_flip_decoder_accepts_last_byte_without_reading_past_rom(self):
        self.assertEqual(flipscan.decode_bits(bytes([7]),1,1,0,0,8),(bytes([7]),8))

    def test_flip_scan_keeps_distinct_views_at_one_address(self):
        records=[('A.TBL','wide',2,1,0,0),('A.TBL','tall',1,2,0,0),
                 ('A.TBL','deep',2,1,0,0x4000),('A.TBL','flipped',2,1,0,0x10)]
        views,_=flipscan.collect_payloads(records,bytes([1,2,0]),[(0,3,'A.IRW',0)],
                                         {'wide','tall','deep','flipped'}, {})
        self.assertEqual(len(views),3)
        wide=views[(0,2,1,0)]
        self.assertEqual(wide['labels'],['A.TBL:wide','A.TBL:flipped'])
        self.assertTrue(all(v['overlaps'] for v in views.values()))

    def test_flip_scan_rejects_interior_overlap_but_not_adjacent_payload(self):
        records=[('A.TBL','whole',2,1,0,0),('A.TBL','tail',1,1,8,0),
                 ('A.TBL','next',1,1,16,0)]
        views,_=flipscan.collect_payloads(records,bytes([1,2,3,0]),[(0,4,'A.IRW',0)],
                                         {'whole','tail','next'}, {})
        self.assertTrue(views[(0,2,1,0)]['overlaps'])
        self.assertTrue(views[(8,1,1,0)]['overlaps'])
        self.assertEqual(views[(16,1,1,0)]['overlaps'],[])

    def test_flip_scan_failed_view_cannot_hide_storage_dependency(self):
        records=[('A.TBL','raw',1,1,0,0),('A.TBL','bad',1,1,0,0x80)]
        views,skipped=flipscan.collect_payloads(records,bytes([0xff,0]),[(0,2,'A.IRW',0)],
                                               {'raw','bad'}, {})
        self.assertEqual(skipped['undecodable'],['A.TBL:bad'])
        self.assertEqual(views[(0,1,1,0)]['overlaps'],['A.TBL:bad'])

    def test_flip_scan_distinguishes_stale_headers_from_loaded_unused_art(self):
        records=[('A.TBL','retired',1,1,0,0),('A.TBL','loaded',1,1,8,0)]
        views,skipped=flipscan.collect_payloads(records,bytes([1,2,0]),[(0,3,'A.IRW',0)],
                                               set(), {'A.TBL':{'loaded'}})
        self.assertEqual(skipped['stale_unreferenced'],['A.TBL:retired'])
        self.assertEqual(len(views),1)
        self.assertTrue(next(iter(views.values()))['load2'])

    def test_undecodable_inline_window_still_blocks_unused_candidate(self):
        text='SZBABE:\n .word 28,44,0,0\n .long 01000H\n .word 06080H\n'
        rows=[dict(label='ROTATE10B',sag_bits=0x1100,payload_bits=512,references=[])]
        with patch.dict(inline.SITES,{'SZBABE':('MKBABY.ASM','MKCHUNKS.TBL','ROTATE9F',614)},clear=True):
            found=inline_dependencies.dependencies(rows,{'MKBABY.ASM':text})
        self.assertEqual(found[0]['protected_window_bits'],28*44*6)
        self.assertEqual(found[0]['overlaps'][0]['label'],'ROTATE10B')

    def test_missing_inline_header_cannot_report_no_dependency(self):
        with patch.dict(inline.SITES,{'SZBABE':('MKBABY.ASM','MKCHUNKS.TBL','ROTATE9F',614)},clear=True):
            with self.assertRaises(ValueError):inline_dependencies.dependencies([],{'MKBABY.ASM':''})

    def test_rotate_operand_is_a_user_but_comment_and_definition_are_not(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'src').mkdir()
            (root/'src/TEST.ASM').write_text('a_bone .long ROTATE2A\n; ROTATE5A\n* ROTATE5A\n')
            (root/'src/TEST.TBL').write_text('ROTATE5A:\n .word 1,2,3,4\n')
            with patch.object(rotate,'ROOT',root):refs,_=rotate.source_references({'ROTATE2A','ROTATE5A'})
            self.assertEqual(len(refs['ROTATE2A']),1)
            self.assertEqual(refs['ROTATE5A'],[])

    def test_candidate_payload_aliases_are_not_double_counted(self):
        self.assertEqual(rotate.union_bits([(8,20),(8,20),(16,24),(32,40)]),24)

    def test_round_pass_markers_cannot_hide_allocation_mismatch(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);rom=root/'rom';rom.mkdir()
            (rom/'mk2.zip').write_bytes(b'private fixture')
            map_path=root/'fixture.map';map_path.write_text('fixture')
            args=['run_hitlight_test.py','--rom-dir',str(rom),'--map',str(map_path),
                  '--output',str(root/'runs'),'--interrupt','round']
            results=[dict(enable=e,exit=0,verdict='PASS',reason='fixture',result='fixture',
                          round_maps=f'ffc00000:{e+1}') for e in (1,0)]
            with patch('sys.argv',args),patch.object(hitlight,'run_once',side_effect=results),contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hitlight.main(),1)
            receipt=json.loads(next((root/'runs').glob('run-*/result.json')).read_text())
            self.assertTrue(all(r['verdict']=='FAIL' and not r['paired_round_maps_match'] for r in receipt))

    def test_hitlight_pass_marker_cannot_hide_emulator_failure(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);rom=root/'rom';rom.mkdir()
            (rom/'mk2.zip').write_bytes(b'private fixture')
            map_path=root/'fixture.map';map_path.write_text('fixture')
            args=['run_hitlight_test.py','--rom-dir',str(rom),'--map',str(map_path),'--output',str(root/'runs')]
            result=dict(enable=1,exit=3,verdict='PASS',reason='fixture',result='fixture')
            with patch('sys.argv',args),patch.object(hitlight,'run_once',return_value=result),contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hitlight.main(),1)

    def test_failed_hash_does_not_rewrite_any_sag(self):
        sags=inline.promoted_sags()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'src').mkdir()
            for name in {v[0] for v in inline.SITES.values()}:
                text=(inline.ROOT/'src'/name).read_text(encoding='latin-1')
                match=next(m for m in inline.RECORD.finditer(text) if m['label'] in inline.SITES)
                text=text[:match.start('sag')]+f"{int(match['sag'],16)-1:08x}"+text[match.end('sag'):]
                (root/'src'/name).write_text(text,encoding='latin-1')
            before={p:p.read_bytes() for p in (root/'src').iterdir()}
            with patch.object(inline,'ROOT',root),patch.object(inline,'promoted_sags',return_value=sags),patch.object(inline,'Art'),patch.object(inline,'pixel_hash',return_value='wrong-hash'),contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(inline.run(False),1)
            self.assertEqual(before,{p:p.read_bytes() for p in before})

    def test_requested_rom_and_map_are_frozen(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);rom=root/'chosen';rom.mkdir()
            (rom/'mk2.zip').write_bytes(b'chosen ROM')
            m=root/'chosen.map';m.write_bytes(b'matching map')
            frozen=floor.freeze(root/'out',rom,m)
            self.assertEqual((frozen/'rom/mk2.zip').read_bytes(),b'chosen ROM')
            self.assertEqual((frozen/'src/mk2.map').read_bytes(),b'matching map')

    def test_mismatched_images_are_not_full_coverage(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as d:
            a,b=Path(d)/'a.png',Path(d)/'b.png'
            Image.new('RGB',(10,10)).save(a);Image.new('RGB',(11,10)).save(b)
            with self.assertRaises(ValueError):floor.first_differing_row(a,b)

    def test_table_operands_are_references_but_definitions_are_not(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'src').mkdir()
            (root/'src/EXAMPLE.TBL').write_text('pointer_list:\n .long target_sprite\nunused_definition:\n .word 1,2\n')
            with patch.object(art,'ROOT',root):used=art.referenced_labels()
            self.assertIn('target_sprite',used)
            self.assertNotIn('unused_definition',used)


if __name__=='__main__':unittest.main()
