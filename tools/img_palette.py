#!/usr/bin/env python3
"""Pull a palette out of a Midway IMG library, BY NAME.

Nothing in the build promotes an IMG palette into the ROM: LOAD2 emits a
`.long <NAME>_P` reference in the generated TBL and expects that symbol to
already exist in IMGPAL*.ASM.  So every re-export of an IMG that recolours a
palette needs the new words pasted back into the ASM by hand - this is the
tool that reads them out.

Look palettes up BY NAME, never by a remembered file offset: the offsets move
on every re-export, and a stale one silently yields a palette made of the
next record's bytes.

    python tools/img_palette.py data/MKFONT.IMG                  # list
    python tools/img_palette.py data/MKFONT.IMG MK2RDf_P        # ASM block
    python tools/img_palette.py data/MKFONT.IMG MK2RDf_P --rgb  # + hex colours
    python tools/img_palette.py data/MKFONT.IMG --check src/IMGPAL6.ASM
        compare every palette in the IMG against the ASM and name the ones
        that have drifted (exit 1 if any have)
"""
import re
import struct
import sys
from pathlib import Path

# Names that exist in both places and are NOT the same palette.  Reported as
# a skip rather than silently passed: the point of --check is that a name it
# does not compare is one you can see it not comparing.
SAME_NAME_DIFFERENT_THING = {
    "boonpal": "MKFONT carries a 2-entry stub; the ROM's boonpal is the real "
               "64-entry colour map 0 and is maintained by hand",
    "boonpal1": "same - a stub in the IMG",
}

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")


def cstr(b): return b.split(b"\0", 1)[0].decode("latin-1", "replace")


def palettes(path: Path):
    """-> [(name, [15-bit words])], in file order."""
    data = path.read_bytes()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]
    # image-first vs palette-first, decided the way imgdump.py decides it
    def plausible(off):
        raw = data[off:off + 16].split(b"\0", 1)[0]
        return bool(raw) and all(32 <= c < 127 for c in raw)
    if sum(plausible(oset + i * IMAGE.size) for i in range(imgcnt)) > imgcnt // 2:
        pal_start = oset + imgcnt * IMAGE.size
    else:
        pal_start = oset
    out = []
    for i in range(palcnt):
        off = pal_start + i * PALETTE.size
        if off + PALETTE.size > len(data):
            break
        rec = PALETTE.unpack_from(data, off)
        name = cstr(rec[0])
        if not name:
            continue
        count = rec[3]                  # entries
        base = rec[4]                   # ABSOLUTE file offset - see the docstring
        if not (0 < count <= 256) or base + count * 2 > len(data):
            continue
        words = list(struct.unpack_from("<%dH" % count, data, base))
        out.append((name, words))
    return out


def as_asm(name, words, per_line=8):
    lines = ["%s:" % name, "\t.word\t %d" % len(words)]
    for i in range(0, len(words), per_line):
        row = ",".join("0%XH" % w if w > 9 else "0%dH" % w
                       for w in words[i:i + per_line])
        lines.append("\t.word\t" + row)
    return "\n".join(lines)


def asm_palettes(asm: Path):
    """-> {name: [words]} for every NAME: / .word count / .word ... block."""
    txt = asm.read_text(encoding="latin-1")
    out = {}
    # COMMENT LINES COUNT AS PART OF THE RUN.  boonpal carries a note in the
    # middle of its .word block, and a pattern that demanded consecutive
    # .word lines skipped it entirely - which prints as "no drift" and is
    # worse than an error.  A `*` in column 1 is an asm comment.
    for m in re.finditer(
            r"^([A-Za-z_][A-Za-z0-9_]*):\s*\n((?:(?:\s*\.word[^\n]*|\*[^\n]*)\n)+)",
            txt, re.M):
        vals = []
        for line in m.group(2).splitlines():
            if line.lstrip().startswith("*"):
                continue
            for tok in line.split(".word", 1)[-1].split(","):
                tok = tok.strip()
                if not tok:
                    continue
                try:
                    vals.append(int(tok[:-1], 16) if tok.upper().endswith("H")
                                else int(tok, 0))
                except ValueError:
                    vals = None
                    break
            if vals is None:
                break
        if vals and len(vals) >= 2 and vals[0] == len(vals) - 1:
            out[m.group(1)] = vals[1:]
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    img = Path(sys.argv[1])
    args = sys.argv[2:]
    pals = palettes(img)

    if "--check" in args:
        asm = Path(args[args.index("--check") + 1])
        have = asm_palettes(asm)
        drift = 0
        for name, words in pals:
            if name not in have:
                continue
            if name in SAME_NAME_DIFFERENT_THING:
                print("skip  %s: %s" % (name, SAME_NAME_DIFFERENT_THING[name]))
                continue
            if have[name] != words:
                print("DRIFT %s: IMG %d entries, %s %d entries%s"
                      % (name, len(words), asm.name, len(have[name]),
                         "" if len(words) != len(have[name]) else " (values differ)"))
                drift += 1
        print("%d of %d shared palettes have drifted" % (drift, len(pals)))
        return 1 if drift else 0

    named = [a for a in args if not a.startswith("--")]
    if not named:
        print("=== %s ===  %d palettes" % (img.name, len(pals)))
        for name, words in pals:
            print("  %-12s %3d entries" % (name, len(words)))
        return 0

    for want in named:
        for name, words in pals:
            if name.upper() == want.upper():
                print(as_asm(name, words))
                if "--rgb" in args:
                    print("* " + " ".join(
                        "#%02x%02x%02x" % (((w >> 10) & 31) * 255 // 31,
                                           ((w >> 5) & 31) * 255 // 31,
                                           (w & 31) * 255 // 31)
                        for w in words))
                break
        else:
            print("!! %s not in %s" % (want, img.name))
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
