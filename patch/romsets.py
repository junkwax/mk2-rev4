"""MK2 T-unit chip layout: split a set into three flat images and back.

program  1 MB  = uj12 (even bytes) + ug12 (odd bytes), byte-interleaved
video   12 MB  = three groups of four 1 MB chips, 4-way byte-interleaved
sound    3 MB  = u2..u7 concatenated
"""

PROGRAM = [('uj12', 0), ('ug12', 1)]
VIDEO = [  # chip, group offset, lane
    ('ug14', 0x000000, 0), ('uj14', 0x000000, 1), ('ug19', 0x000000, 2), ('uj19', 0x000000, 3),
    ('ug16', 0x400000, 0), ('uj16', 0x400000, 1), ('ug20', 0x400000, 2), ('uj20', 0x400000, 3),
    ('ug17', 0x800000, 0), ('uj17', 0x800000, 1), ('ug22', 0x800000, 2), ('uj22', 0x800000, 3),
]
SOUND = ['u2', 'u3', 'u4', 'u5', 'u6', 'u7']
ALL = [c for c, _ in PROGRAM] + SOUND + [c for c, _, _ in VIDEO]


def to_images(chips):
    """chips: {chip_name: bytes} -> {'program','video','sound': bytes}"""
    prog = bytearray(0x100000)
    for chip, lane in PROGRAM:
        prog[lane::2] = chips[chip]
    video = bytearray(0xC00000)
    for chip, base, lane in VIDEO:
        video[base + lane:base + 0x400000:4] = chips[chip]
    sound = b''.join(chips[c] for c in SOUND)
    return {'program': bytes(prog), 'video': bytes(video), 'sound': sound}


def to_chips(images):
    chips = {}
    for chip, lane in PROGRAM:
        chips[chip] = images['program'][lane::2]
    for chip, base, lane in VIDEO:
        chips[chip] = images['video'][base + lane:base + 0x400000:4]
    for i, chip in enumerate(SOUND):
        chips[chip] = images['sound'][i * 0x80000:(i + 1) * 0x80000]
    return chips


def expand_bits(img):
    """img followed by itself shifted right (little-endian bit order) 1..7 bits."""
    v = int.from_bytes(img, 'little')
    return b''.join((v >> k).to_bytes(len(img), 'little') for k in range(8))


def source_for(name, img):
    """The BPS source buffer a patch for image `name` is made against."""
    return expand_bits(img) if name == 'video' else img
