"""Bake the numbers saved by the live fan tuner (tools/fan_tune_saved.txt,
written by fan_tune_live.lua's M key) into the `fan_tune` block in
src/MKZAP.ASM.  Rewrites only the six data lines of that block; the equates at
the top of the file stay as they are (they only seed the block).

    python tools/fan_tune_apply.py            # apply
    python tools/fan_tune_apply.py --dry-run  # show the new block only

Then rebuild: python build.py --asm-only && python makerom.py && python mamerom.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SAVED = ROOT / "tools" / "fan_tune_saved.txt"
for _a in sys.argv[1:]:
    if not _a.startswith("--"):
        SAVED = Path(_a)
ASM = ROOT / "src" / "MKZAP.ASM"
MAX = 24


def load():
    v = {}
    for line in SAVED.read_text().splitlines():
        k, _, rest = line.partition(" ")
        nums = [int(x) for x in rest.split()]
        v[k] = nums if k in ("turn", "pace") else nums[0]
    for k in ("coast", "half", "bend", "ticks", "turn", "pace"):
        if k not in v:
            sys.exit(f"{SAVED}: missing '{k}'")
    if len(v["turn"]) != MAX or len(v["pace"]) != MAX:
        sys.exit(f"{SAVED}: turn/pace must have {MAX} entries")
    if not 1 <= v["ticks"] <= MAX:
        sys.exit("ticks out of range")
    if any(p < 1 for p in v["pace"][: v["ticks"]]):
        sys.exit("a pace of 0 would stop the blade dead")
    return v


def words(xs):
    return [xs[i:i + 12] for i in range(0, len(xs), 12)]


def block(v):
    turn = words(v["turn"])
    pace = words(v["pace"])
    out = [
        f"ft_coast\t.word\t{v['coast']}",
        f"ft_half\t\t.word\t{v['half']}",
        f"ft_bend\t\t.long\t0{v['bend']:x}h",
        f"ft_ticks\t.word\t{v['ticks']}",
        "ft_turn\t\t.word\t" + ",".join(map(str, turn[0])),
        "\t\t.word\t" + ",".join(map(str, turn[1])),
        "ft_pace\t\t.word\t" + ",".join(map(str, pace[0])),
        "\t\t.word\t" + ",".join(map(str, pace[1])),
    ]
    return "\n".join(out) + "\n"


def main():
    v = load()
    raw = ASM.read_bytes().decode("latin-1")
    crlf = "\r\n" in raw
    s = raw.replace("\r\n", "\n")
    m = re.search(r"^fan_tune\n(ft_coast.*?)\n\n", s, re.S | re.M)
    if not m:
        sys.exit("could not find the fan_tune block in MKZAP.ASM")
    new = block(v)
    print(new)
    if "--dry-run" in sys.argv:
        return
    s = s[: m.start(1)] + new.rstrip("\n") + s[m.end(1):]
    if crlf:
        s = s.replace("\n", "\r\n")
    ASM.write_bytes(s.encode("latin-1"))
    print(f"wrote {ASM}")


if __name__ == "__main__":
    main()
