#!/usr/bin/env python3
"""Keep the Liu Kang red-dragon palettes in src/IMGPAL6.ASM honest against
data/MKDRAGON.IMG.

LKREDRG_P and DRAGNRD_P are hand-copied byte-for-byte out of the IMG's palette
pool - nothing in the build promotes them, so an imgtool recolour silently
leaves the ROM drawing the old ramp.  That already happened once: palrec 5 was
renamed LKDRAG_P -> LKREDRG_P *and* recoloured, while IMGPAL6.ASM kept the
leak's values.

    python tools/sync_dragon_palettes.py           # rewrite the ASM blocks
    python tools/sync_dragon_palettes.py --check   # Phase D: fail on drift

See doc/ and the `reference_inline_asm_sprite_records` pattern: hand-maintained
records need an audit + syncer or they rot.
"""
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "data" / "MKDRAGON.IMG"
ASM = ROOT / "src" / "IMGPAL6.ASM"

LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")

# ASM label -> palette record NAME inside the IMG.
WANTED = {
    "LKREDRG_P": "LKREDRG_P",
    "DRAGNRD_P": "DRAGNRD_P",
}


def _plausible(raw: bytes) -> bool:
    name = raw.split(b"\0", 1)[0]
    return bool(name) and all(32 <= ch < 127 for ch in name)


def read_palettes(path: Path) -> dict[str, list[int]]:
    data = path.read_bytes()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(data, 0)[:3]

    best = None
    for img_start, pal_start in ((oset, oset + imgcnt * IMAGE.size),
                                 (oset + palcnt * PALETTE.size, oset)):
        score = sum(
            1 for i in range(imgcnt)
            if img_start + i * IMAGE.size + 16 <= len(data)
            and _plausible(data[img_start + i * IMAGE.size:img_start + i * IMAGE.size + 16])
        )
        if best is None or score > best[0]:
            best = (score, pal_start)
    _, pal_start = best

    out: dict[str, list[int]] = {}
    for i in range(palcnt):
        off = pal_start + i * PALETTE.size
        if off + PALETTE.size > len(data):
            break
        name_s, _b1, _b2, count, foff = PALETTE.unpack_from(data, off)[:5]
        name = name_s.split(b"\0", 1)[0].decode("latin-1", "replace")
        if name in WANTED.values() and 0 < count <= 256:
            if foff + count * 2 <= len(data):
                out[name] = list(struct.unpack_from(f"<{count}H", data, foff))
    return out


def fmt_word(w: int) -> str:
    if w == 0:
        return "00H"
    h = format(w, "X")
    if h[0] in "ABCDEF":
        h = "0" + h
    return h + "H"


def render(label: str, colors: list[int]) -> str:
    lines = [f"{label}:", f"\t.word\t {len(colors)}"]
    for i in range(0, len(colors), 8):
        lines.append("\t.word\t" + ",".join(fmt_word(w) for w in colors[i:i + 8]))
    return "\n".join(lines)


def parse_block(block: str) -> list[int]:
    """The values a rendered block actually carries.

    Compared numerically, never as text: IMGPAL6.ASM pads its hex literals with
    a leading zero as a house style (02407H) while a minimal render does not
    (2407H).  Both assemble to the same word, so a string compare would report
    drift on every single entry and train everyone to ignore this check.  The
    first `.word` line is the colour COUNT and is re-derived, not compared.
    """
    words: list[int] = []
    for line in block.splitlines()[1:]:          # skip the `LABEL:` line
        body = line.strip()
        if not body.startswith(".word"):
            continue
        for tok in body[len(".word"):].split(","):
            tok = tok.strip().rstrip("Hh")
            if not tok:
                continue
            words.append(int(tok, 16))
    return words[1:] if words else []            # drop the count word


def locate_block(lines: list[str], label: str) -> tuple[int, int]:
    """Return [first, last) line indices of `LABEL:` plus its .word lines."""
    first = None
    for i, line in enumerate(lines):
        if re.match(rf"^{re.escape(label)}:[ \t]*$", line):
            first = i
            break
    if first is None:
        raise SystemExit(f"ERROR: {label}: not found in {ASM}")
    last = first + 1
    while last < len(lines) and lines[last].strip().startswith(".word"):
        last += 1
    return first, last


def main() -> int:
    check = "--check" in sys.argv
    if not IMG.exists():
        print(f"  sync_dragon_palettes: {IMG} missing - skipped")
        return 0

    pals = read_palettes(IMG)
    lines = ASM.read_text(encoding="latin-1").splitlines()

    drift, missing = [], []
    for label, rec in WANTED.items():
        if rec not in pals:
            missing.append(rec)
            continue
        first, last = locate_block(lines, label)
        if parse_block("\n".join(lines[first:last])) != pals[rec]:
            drift.append(label)
            if not check:
                lines[first:last] = render(label, pals[rec]).splitlines()

    if missing:
        print(f"  sync_dragon_palettes: WARNING no {', '.join(missing)} record in "
              f"{IMG.name} - left as-is")

    if check:
        if drift:
            print(f"  sync_dragon_palettes: DRIFT in {', '.join(drift)} - "
                  f"{ASM.name} no longer matches {IMG.name}")
            print("  run: python tools/sync_dragon_palettes.py")
            return 1
        print(f"  OK: {ASM.name} dragon palettes match {IMG.name}")
        return 0

    if drift:
        ASM.write_text("\n".join(lines) + "\n", encoding="latin-1")
        print(f"  sync_dragon_palettes: updated {', '.join(drift)} in {ASM.name}")
    else:
        print(f"  sync_dragon_palettes: {ASM.name} already current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
