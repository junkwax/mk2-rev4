#!/usr/bin/env python3
"""Keep the last hand-carried SAGs in *.ASM anchored to a promoted record.

Most sprite headers live in a LOAD2-generated .TBL, so a repack moves the art
and promote_tbls moves the header with it.  A handful do not: they are written
by hand inside an .ASM, they point at a bit offset in the middle of somebody
else's packed payload, and nothing regenerates them.  They are correct until
the day the run they point into reflows, and then they silently draw whatever
slid into that address.

Several already have private sync tools (MKRIGHT1, KHEART6B_OPEN, the MKSEL VS
restore chunks, the Ermac lane clones).  These six had none, and deleting the
dead STBURST block from MK7MIL.LOD on 2026-09-12 moved every one of them by
-0x36F62 bits at once - which is exactly how this class of bug ships.

Each site is anchored to the promoted record it sits inside, plus a fixed bit
offset.  Both move together because LOAD2 packs a run in LOD order, so the
offset survives anything that happens before the anchor, and the hash catches
the one thing it cannot survive - something being inserted between the anchor
and the target:

    python tools/sync_inline_sags.py           # rewrite the constants
    python tools/sync_inline_sags.py --check   # Phase D: fail if stale

The hash is over the packed BITS at the computed address, across the window the
inline record's own size and depth describe, so it answers the only question
that matters: is this header still pointing at the same art.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# label -> (source .ASM, anchor table, anchor record, bit offset into it)
#
# The anchor is simply the promoted record these bytes sit inside; it carries
# no meaning beyond "this is the nearest thing that moves with them".  The
# pixels are the invariant, not the anchor's name.
SITES = {
    "BGBIGFIST1C_MIRROR":    ("MKSK.ASM", "MKSK.TBL", "BGBIGFIST1B", 0),
    # The NINJA BABY. These used to anchor at ROTATE9F+614 - the leaked source's
    # header, which "was never real art" and drew noise for every ninja victim.
    # Retail's program ROM holds the real header: SAG 054c7254, and the bits there
    # are exactly NJBABE's (matched bit-for-bit against retail's video ROM,
    # 2026-09-18). ERBABE is the same art in Ermac's own ERM_P.
    "SZBABE":               ("MKBABY.ASM", "MKBABY.TBL", "NJBABE", 0),
    "RPBABE":               ("MKBABY.ASM", "MKBABY.TBL", "NJBABE", 0),
    "SCBABE":               ("MKBABY.ASM", "MKBABY.TBL", "NJBABE", 0),
    "ERBABE":               ("MKBABY.ASM", "MKBABY.TBL", "NJBABE", 0),
    "RNBABE":               ("MKBABY.ASM", "MKBABY.TBL", "NJBABE", 0),
    "KLUDGE_SHORTBOLT1A":   ("MKRD.ASM", "MKBABY.TBL", "discoball1", 1716),
    # KLUDGE_RN1DETHBOLT1A is RN1DETHBOLT1A plus ELEC_P - gmo_proc reads the
    # palette off frame 1's first piece, and the LOAD2 record carries none.
    # It used to be anchored at RNSHORTBOLT11B+1976, faithfully preserving a
    # pointer that was already wrong: those bits did not decode as a sprite and
    # drew garbage on the first hand bolt.  Re-anchored 2026-09-13 onto the
    # record it copies.
    "KLUDGE_RN1DETHBOLT1A": ("MKRD.ASM", "MKBOLTS.TBL", "RN1DETHBOLT1A", 0),
    "KLUDGE_BOLT1A":        ("MKRD.ASM", "MKCHUNKS.TBL", "SNOWBALL2", 2),
    # Mileena's left victory arms: mirrored aliases of the right arms (dmahfl
    # in the header, XORed by ani2).  Offset 0 - they share the right arm's
    # payload outright.  doc/graphics_opportunities/FLIPREUSE_PROTOTYPE.md
    "KT2VARMLEFT1A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT1A", 0),
    "KT2VARMLEFT2A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT2A", 0),
    "KT2VARMLEFT3A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT3A", 0),
    "KT2VARMLEFT4A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT4A", 0),
    "KT2VARMLEFT5A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT5A", 0),
    "KT2VARMLEFT6A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT6A", 0),
    "KT2VARMLEFT7A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT7A", 0),
    "KT2VARMLEFT8A":        ("MKFN.ASM", "MKFN.TBL", "KT2VARMRIGHT8A", 0),
    # Shao Kahn's stone explosion: KAHNBIG1 / KAHNLIL1 are BIGSTONE1 / LILSTONE1
    # plus STONE_P - explode_piece reads the palette off each chunk lane's first
    # frame, and the LOAD2 records carry none.  Found pointing INTO other stone art
    # (038010a6 / 03805dc6 decoded as neither chunk) while repacking the crack
    # frames on 2026-09-15; anchored onto the records they copy, offset 0.
    "KAHNBIG1":             ("MKSK.ASM", "MKSK.TBL", "BIGSTONE1", 0),
    "KAHNLIL1":             ("MKSK.ASM", "MKSK.TBL", "LILSTONE1", 0),
    # Raiden's head roll: frames 2/3 are H+V mirrors of 6/7 drawn from 6/7's
    # payload (single-object ani XORs the header flip, MKDISP).  Offset 0.
    "RNHEAD2_MIRROR":       ("MKRD.ASM", "MKRD2.TBL", "RNHEAD6", 0),
    "RNHEAD3_MIRROR":       ("MKRD.ASM", "MKRD2.TBL", "RNHEAD7", 0),
    # LOAD2 folded these authored mirrors onto the image they mirror, with no
    # flip, so they drew the wrong way round.  Each alias draws the stored
    # pixels with the flip in its header.  LOAD2_MIRROR_FOLDS.md.
    "LILSTONE5_MIRROR":     ("MKSK.ASM", "MKSK.TBL", "LILSTONE1", 0),
    "smfirebone6_mirror":   ("MKFX.ASM", "MKFX.TBL", "smfirebone3", 0),
}

# sha256 of the packed BITS each site must keep pointing at.  Recorded
# 2026-09-12 and verified equal, bit for bit, to what the same headers pointed
# at in the pre-reflow payload - so the rewrite that seeded them changed the
# addresses and nothing else.  Regenerate with --print-hashes ONLY when the art
# itself is meant to change.
EXPECTED = {
    "BGBIGFIST1C_MIRROR": "e950e526e2d7898de2320aaf189f94e963d42293521e7fbe427c4022f0d5c4a8",
    # The real ninja baby (NJBABE) - see SITES. The old f1852e0f hash preserved the
    # leaked header's malformed window, which read ROTATE9F..ROTATE10B/C; those two
    # ROTATE records are no longer a dependency of anything here.
    "SZBABE": "b3fa1acb31c16499c8b398bc1fb90c6c860e98f74539a61628da791c485261a0",
    "RPBABE": "b3fa1acb31c16499c8b398bc1fb90c6c860e98f74539a61628da791c485261a0",
    "SCBABE": "b3fa1acb31c16499c8b398bc1fb90c6c860e98f74539a61628da791c485261a0",
    "ERBABE": "b3fa1acb31c16499c8b398bc1fb90c6c860e98f74539a61628da791c485261a0",
    "RNBABE": "b3fa1acb31c16499c8b398bc1fb90c6c860e98f74539a61628da791c485261a0",
    "KLUDGE_SHORTBOLT1A": "758020250775a3eed75282ee1c3dc25ef0219da2fb55bb25fa359e1a8d8a597e",
    "KLUDGE_RN1DETHBOLT1A": "390f893a7c3d3db307d5b67cf9fefa3187a9ae5aa76ce1d487b490bc0a7ac06a",
    "KLUDGE_BOLT1A": "0913f596852c2875a1bbee25f92c81e6be31f05e1e04668d4426d7e73085c185",
    "KT2VARMLEFT1A": "d64d688d82a1588c48df13cf548e5369ac2c52f8e9767d307f8fae3654de5c51",
    "KT2VARMLEFT2A": "8f98a05a9a60fe5a87c43890adfb88ce98b93c11d85f79d6ea14203a7475ba04",
    "KT2VARMLEFT3A": "3a3399ee851979b2d97784b69f2b7305c62b6c91155a4e69db4d11c5da8c9c6e",
    "KT2VARMLEFT4A": "8dbb1e38f466b055894672cb10dc9da1d22390c9f639bf138b35b52b7872d5f0",
    "KT2VARMLEFT5A": "6cdf8c6bfd243799f3a7a5eed5906c01ac4cfdda19fa4a093c0c78d306e8b312",
    "KT2VARMLEFT6A": "245c3dbe631b62d52869669c1385626aaf3a5963d86f49d8b6a7b346f96a0361",
    "KT2VARMLEFT7A": "f5e442ec3710549bdaa87af571ba4a9aaa75b4cd1744d28c837fd777b4c974ad",
    "KT2VARMLEFT8A": "2fd30c194d835185aa4e8eee1ad4090528cc80f79da66a00b0a18e7d75179310",
    # Recorded 2026-09-15 at BIGSTONE1 / LILSTONE1 in the repacked MK5MIL.
    "KAHNBIG1": "7596f2eb8ea877544ce96aed2a5c0dd1cfbcf2e6b53ccbc68e0f6e51dbebb2e1",
    "KAHNLIL1": "19f17ac64574519a3b77fcfe23df24e26c10f8cbb064e56f233c2e085257d712",
    # Recorded 2026-09-15 at RNHEAD6 / RNHEAD7 in MK4MIL.
    "RNHEAD2_MIRROR": "67eebf35e51421733e72e9cb2b628560e30b48a9245fd0d7c56cf4c37cfb46ed",
    "RNHEAD3_MIRROR": "d6f68b485bc4ff231f57bc70f3284ee08a846397ef50230362f477d8befbdfaa",
    # Recorded 2026-09-15 on the LOAD2 mirror-fold aliases (FISTPULP4V at
    # 5 bpp, LILSTONE1, smfirebone3).
    "LILSTONE5_MIRROR": "19f17ac64574519a3b77fcfe23df24e26c10f8cbb064e56f233c2e085257d712",
    "smfirebone6_mirror": "9d40a64b7283b53edad55000739bb857d78188e4575d7de7fed376b8d3c7af9d",
}

# A record label appears three ways in this tree: "NAME:" on its own line, a
# bare "NAME" on its own line (MKRD's KLUDGE_* records), and "NAME<tab>.word"
# all on one line (MKBABY's).  Missing one silently skips a site, so run()
# asserts it matched every entry in SITES rather than trusting this pattern.
RECORD = re.compile(
    r"^(?P<label>\w+):?[ \t]*(?:\n[ \t]*|[ \t]+)"
    r"\.word[ \t]+(?P<w>-?\d+),(?P<h>-?\d+),(?P<ax>-?\d+),(?P<ay>-?\d+)[ \t]*\n"
    r"(?P<pre>[ \t]*\.long[ \t]+0?)(?P<sag>[0-9a-fA-F]+)(?P<post>[Hh][^\n]*\n)"
    r"[ \t]*\.word[ \t]+0?(?P<ctrl>[0-9a-fA-F]+)[Hh]", re.M)


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def promoted_sags():
    bp = _module("bppaudit", ROOT / "tools/audit_sprite_bpp.py")
    return {"%s:%s" % (f, label): sag
            for f, label, w, h, sag, ctrl in bp.parse_tbls(str(ROOT / "src"))}


def pixel_hash(art, w, h, sag, ctrl):
    """Fingerprint the bytes this header points at.

    Every one of these sites points INTO another record's payload rather than
    at a record boundary, so none of them parse as a standalone image and a
    decoded-pixel hash would be "undecodable" at any address - an invariant
    that holds no matter how wrong the SAG is.  So hash the RAW packed bits
    instead, over the window the header's own size and depth describe.  That
    changes the moment anything shifts underneath, which is the whole point.

    A byte window will not do it: SAGs are BIT addresses and records are not
    byte aligned, so the same art at a new address usually sits at a different
    bit phase and a byte-wise hash reports a difference that is not there.
    Extract the bits and repack them from bit zero.
    """
    bpp = (ctrl >> 12) & 7 or 8
    end = art.end_of(sag)
    count = min(w * h * bpp, max(0, end - sag))
    if count <= 0:
        return None
    rom = art.rom
    out = bytearray((count + 7) // 8)
    for i in range(count):
        at = sag + i
        if (rom[at >> 3] >> (at & 7)) & 1:
            out[i >> 3] |= 1 << (i & 7)
    return hashlib.sha256(bytes(out)).hexdigest()


class Art:
    """The packed video ROM plus the span each SAG belongs to."""
    # Some of these sites point INTO another record's payload rather than at a
    # record boundary, and do not parse as a standalone image at all. That is
    # recorded as "undecodable" rather than treated as an error: the contract
    # here is that the bytes under the header do not change, not that they are
    # a well-formed sprite.

    def __init__(self):
        import bisect
        aid = _module("artid", ROOT / "tools/art_identity_snapshot.py")
        mv = _module("mv", ROOT / "makevrom.py")
        self.decode = aid.decode
        self.rom, self.spans = aid.flat_rom(mv)
        self.starts = [s[0] for s in self.spans]
        self._bisect = bisect

    def end_of(self, sag):
        i = self._bisect.bisect_right(self.starts, sag // 8) - 1
        if i < 0 or sag >= self.spans[i][1] * 8:
            return 0
        return self.spans[i][1] * 8


def linked_image():
    """The linked COFF, whose .data carries every hand-written header verbatim."""
    out = ROOT / "src" / "mk2.out"
    return out.read_bytes() if out.exists() else None


def run(check):
    sags = promoted_sags()
    art = Art()
    problems, updates, seen, pending = [], [], set(), {}
    # A correct SAG in the SOURCE proves nothing about the ROM.  On
    # 2026-09-15 this script rewrote MKRD.ASM's RNHEAD2/3_MIRROR after a
    # prune, gmake then skipped MKRD.OBJ (DOSBox writes object times skewed
    # ahead), and the linked ROM kept the pre-prune SAGs - drawing RNHEAD8 and
    # torso art on the head roll while this check passed.  So in --check mode,
    # which Phase D runs after the link, also require every header - size,
    # anchor, SAG and control - to be present in src/mk2.out.
    linked = linked_image() if check else None
    for fname in sorted({v[0] for v in SITES.values()}):
        path = ROOT / "src" / fname
        text = path.read_text(encoding="latin-1")
        out, pos, changed = [], 0, 0
        for m in RECORD.finditer(text):
            site = SITES.get(m.group("label"))
            if not site or site[0] != fname:
                continue
            seen.add(m.group("label"))
            _, table, anchor, offset = site
            key = "%s:%s" % (table, anchor)
            if key not in sags:
                problems.append("%s: anchor %s is not a promoted record"
                                % (m.group("label"), key))
                continue
            want = sags[key] + offset
            have = int(m.group("sag"), 16)
            w, h = int(m.group("w")), int(m.group("h"))
            ctrl = int(m.group("ctrl"), 16)
            digest = pixel_hash(art, w, h, want, ctrl)
            expect = EXPECTED.get(m.group("label"))
            digest = digest or "undecodable"
            if expect and digest != expect:
                problems.append("%s: pixels at the anchored SAG changed "
                                "(%s != %s) - something was inserted between "
                                "%s and this art"
                                % (m.group("label"), digest[:12], expect[:12], anchor))
            if linked is not None:
                ax, ay = int(m.group("ax")), int(m.group("ay"))
                blob = struct.pack("<4hIH", w, h, ax, ay, want, ctrl)
                if blob not in linked:
                    problems.append("%s: src/mk2.out does not carry this header with "
                                    "SAG 0x%08x - its object was not reassembled "
                                    "(delete the .OBJ and rebuild)"
                                    % (m.group("label"), want))
            if have != want:
                if check:
                    problems.append("%s: SAG 0x%08x is stale, anchor says 0x%08x"
                                    % (m.group("label"), have, want))
                else:
                    out.append(text[pos:m.start("sag")])
                    out.append("%0*x" % (len(m.group("sag")), want))
                    pos = m.end("sag")
                    changed += 1
                    updates.append("%s 0x%08x -> 0x%08x"
                                   % (m.group("label"), have, want))
        if changed and not check:
            out.append(text[pos:])
            pending[path] = "".join(out)
    missing = sorted(set(SITES) - seen)
    if missing:
        problems.append("did not find these records in source: %s"
                        % ", ".join(missing))
    if problems:
        print("inline SAG sync FAILED:")
        for p in problems:
            print("  " + p)
        return 1
    # Reject the whole proposed update before writing any source if an
    # anchor/hash failed. A nonzero exit must not leave half-applied SAGs.
    for path, text in pending.items():
        path.write_text(text, encoding="latin-1")
    for u in updates:
        print("  rewrote %s" % u)
    print("inline SAGs OK: %d hand-carried record(s) anchored%s"
          % (len(SITES), " (%d rewritten)" % len(updates) if updates else ""))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="fail instead of rewriting (Phase D)")
    ap.add_argument("--print-hashes", action="store_true",
                    help="print the current pixel hashes, to seed EXPECTED")
    args = ap.parse_args()
    if args.print_hashes:
        sags, art = promoted_sags(), Art()
        for label, (fname, table, anchor, offset) in SITES.items():
            text = (ROOT / "src" / fname).read_text(encoding="latin-1")
            m = next(m for m in RECORD.finditer(text)
                     if m.group("label") == label)
            want = sags["%s:%s" % (table, anchor)] + offset
            print('    "%s": "%s",' % (label, pixel_hash(
                art, int(m.group("w")), int(m.group("h")), want,
                int(m.group("ctrl"), 16)) or "undecodable"))
        return 0
    return run(args.check)


if __name__ == "__main__":
    sys.exit(main())
