#!/usr/bin/env python3
"""Offline packed-art/anchor prototype; does not edit game source or ROMs.

Compare BGBIGFIST1C with a mirrored BGBIGFIST1B in both consumers. Model the
placement rules in MKUTIL's ani2/match_single and MKZAP's piece-start path.
This is an indexed-pixel model, not a DMA emulator or runtime acceptance test.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw

import art_identity_snapshot as identity
import flip_scale_scan as pixels
import sync_inline_sags as inline

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 400, 254


def placement(header, anchor, facing):
    # Both ani2 and match_single use WIDTH, not WIDTH-1, for this anchor.
    x, y = anchor
    return (x + header['ax'] - header['w'] if facing else x - header['ax'],
            y - header['ay'])


def render(header, art, anchor, facing, path, variant):
    x, y = placement(header, anchor, facing)
    # ani2 composes the two flips. match_single overwrites horizontal facing;
    # the proposed single-object fix restores the header bit AFTER placement.
    flip = facing
    if variant != 'stock' and (path == 'multipart' or variant in ('post_place', 'early_restore')):
        flip ^= 1
    if path == 'single':
        # MKZAP places the fist 0x20 pixels from the victim after matching.
        # adjust_xy_a5 uses oflags too: restoring the mirror before this call
        # sends the offset the wrong way, a 64-pixel placement error.
        adjust_facing = flip if variant == 'early_restore' else facing
        x += -0x20 if adjust_facing else 0x20
    if flip:
        art = pixels.hflip(art, header['w'], header['h'])
    screen = bytearray(WIDTH * HEIGHT)
    for row in range(header['h']):
        yy = y + row
        if not 0 <= yy < HEIGHT:
            continue
        for col in range(header['w']):
            xx = x + col
            if 0 <= xx < WIDTH:
                screen[yy * WIDTH + xx] = art[row * header['w'] + col]
    return bytes(screen)


def load_art():
    source = ROOT / 'src/MKSK.TBL'
    wanted = {'BGBIGFIST1B', 'BGBIGFIST1C'}
    headers = {}
    for match in inline.RECORD.finditer(source.read_text(encoding='latin-1')):
        if match['label'] in wanted:
            headers[match['label']] = {
                **{k: int(match[k]) for k in ('w', 'h', 'ax', 'ay')},
                **{k: int(match[k], 16) for k in ('sag', 'ctrl')}}
    if set(headers) != wanted:
        raise ValueError('Missing or unsupported fist headers')
    mv = identity._module('kahn_makevrom', ROOT / 'makevrom.py')
    rom, spans = identity.flat_rom(mv)
    inputs = {'src/MKSK.TBL': hashlib.sha256(source.read_bytes()).hexdigest()}
    for name, h in headers.items():
        span = next(s for s in spans if s[0] * 8 <= h['sag'] < s[1] * 8)
        art, bits = pixels.decode_bits(rom, h['w'], h['h'], h['sag'], h['ctrl'], span[1] * 8)
        if art is None or bits <= 0:
            raise ValueError(f'{name}: packed art does not decode')
        h.update(art=art, bits=bits, pixel_sha256=hashlib.sha256(art).hexdigest())
        path = ROOT / 'data' / span[2]
        inputs[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ('src/MKUTIL.ASM', 'src/MKZAP.ASM', 'src/MKDISP.ASM',
                 'tools/kahn_fist_reuse_prototype.py'):
        inputs[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    return headers, inputs


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    headers, inputs = load_art()
    b, c = headers['BGBIGFIST1B'], headers['BGBIGFIST1C']
    if (b['w'], b['h']) != (c['w'], c['h']):
        raise ValueError('Fist dimensions differ')
    if pixels.hflip(b['art'], b['w'], b['h']) != c['art']:
        raise ValueError('Packed C is not an exact horizontal mirror of B')
    cases = []
    for path in ('multipart', 'single'):
        for facing in (0, 1):
            for x in (-64, 0, 1, 28, 200, 399, 450):
                for y in (-80, -41, 0, 200, 253, 300):
                    stock = render(c, c['art'], (x, y), facing, path, 'stock')
                    naive = render(c, b['art'], (x, y), facing, path, 'header_only')
                    fixed = render(c, b['art'], (x, y), facing, path, 'post_place')
                    early = render(c, b['art'], (x, y), facing, path, 'early_restore')
                    cases.append(dict(path=path, facing=facing, anchor=[x, y],
                                      visible_pixels=sum(bool(v) for v in stock),
                                      naive_different_pixels=sum(a != z for a, z in zip(stock, naive)),
                                      early_restore_different_pixels=sum(a != z for a, z in zip(stock, early)),
                                      proposed_different_pixels=sum(a != z for a, z in zip(stock, fixed))))
    if any(c['proposed_different_pixels'] for c in cases):
        raise ValueError('Proposed layout differs from stock')
    for facing in (0, 1):
        if not any(c['path'] == 'single' and c['facing'] == facing and
                   c['naive_different_pixels'] for c in cases):
            raise ValueError('Negative control did not expose overwritten flip')
        if not any(c['path'] == 'single' and c['facing'] == facing and
                   c['early_restore_different_pixels'] for c in cases):
            raise ValueError('Negative control did not expose early flip placement error')

    # Grayscale indices deliberately avoid implying palette validation.
    preview = Image.new('RGB', (WIDTH * 3, (HEIGHT + 24) * 2), '#202020')
    draw = ImageDraw.Draw(preview)
    for facing in (0, 1):
        for column, variant in enumerate(('stock', 'header_only', 'post_place')):
            art = c['art'] if variant == 'stock' else b['art']
            screen = render(c, art, (200, 40), facing, 'single', variant)
            img = Image.frombytes('L', (WIDTH, HEIGHT), bytes(min(v * 4, 255) for v in screen))
            origin = (column * WIDTH, facing * (HEIGHT + 24))
            draw.text(origin, f'facing={facing}: {variant} (index grayscale)', fill='white')
            preview.paste(img, (origin[0], origin[1] + 24))
    preview.save(output / 'comparison.png')
    result = dict(status='PASS_OFFLINE_MODEL', runtime_validated=False,
                  inputs_sha256=inputs, cases=cases,
                  case_count=len(cases), visible_cases=sum(c['visible_pixels'] > 0 for c in cases),
                  naive_failed_cases=sum(c['naive_different_pixels'] > 0 for c in cases),
                  early_restore_failed_cases=sum(c['early_restore_different_pixels'] > 0 for c in cases),
                  candidate_payload_bits=c['bits'], candidate_payload_bytes=c['bits'] // 8,
                  proposed_header={k: c[k] for k in ('w', 'h', 'ax', 'ay')},
                  proposed_sag=b['sag'], proposed_control=b['ctrl'] ^ 0x10,
                  headers={name: {k: v for k, v in h.items() if k != 'art'} for name, h in headers.items()},
                  limitations=['No MAME or hardware execution', 'No compression/clip timing emulation',
                               'No palette, scaling, animation, strike-box or cleanup validation',
                               'No source/LOD edits; candidate savings are not reclaimed space'])
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"PASS offline: {len(cases)} cases; {result['visible_cases']} visible; "
          f"{result['naive_failed_cases']} negative-control failures; {c['bits'] // 8} candidate bytes")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'tmp/kahn_fist_reuse')
    run(parser.parse_args().output.resolve())
