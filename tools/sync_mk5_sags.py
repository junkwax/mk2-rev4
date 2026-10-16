"""Sync drifted SAG addresses from the MK5MIL-run LOAD2 snapshot into src.

Only the .long SAG field is updated for labels whose snapshot SAG differs;
sizes/anipoints/control words in src are preserved (they may carry hand
edits). Reports per-file counts and any size/control mismatches for review.
"""
import re
from pathlib import Path

SNAP = Path(r"c:\Users\you\Workplace\mk2-main\tmp\LOAD2M5")
SRC = Path(r"c:\Users\you\Workplace\mk2-main\src")

# LOAD2's MK5 snapshot uses the unrelocated 0x03xxxxxx view for the BOSS4
# wave.  makevrom writes MK5 at its 0x05030000 base, so these linked headers
# must retain the corresponding 0x05xxxxxx addresses.
SONICLAP_SAG_BIAS = 0x02000000

HDR = re.compile(r"^(\w+):\n(\t\.word\s+[\-\d,]+\n)\t\.long\s+(\w+)H\n(\t\.word\s+\w+H)", re.M)

def parse(text):
    return {m.group(1): (m.group(2), m.group(3), m.group(4), m.span(3))
            for m in HDR.finditer(text)}

total = 0
for snap_file in sorted(SNAP.glob("*.TBL")):
    src_file = SRC / snap_file.name
    if not src_file.exists():
        print(f"{snap_file.name}: no src counterpart, skipped")
        continue
    snap = parse(snap_file.read_text(encoding="latin-1"))
    src_text = src_file.read_text(encoding="latin-1")
    stats = {"changed": 0, "mismatch": 0}
    # rebuild src text with replacements applied label by label
    def fix(m, snap=snap, stats=stats):
        name = m.group(1)
        if name not in snap:
            return m.group(0)
        s_words, s_sag, s_ctrl, _ = snap[name]
        if snap_file.name.upper() == "MKSK.TBL" and re.fullmatch(r"SONICLAP(?:[1-9]|1[01])", name):
            s_sag = f"{int(s_sag, 16) + SONICLAP_SAG_BIAS:08x}"
        if m.group(3) == s_sag:
            return m.group(0)
        # size check: first two .word fields must match or flag for review
        src_sz = m.group(2).split()[1].split(",")[:2]
        snp_sz = s_words.split()[1].split(",")[:2]
        if src_sz != snp_sz:
            print(f"  !! {name}: size mismatch src={src_sz} snap={snp_sz} - SAG synced anyway")
            stats["mismatch"] += 1
        stats["changed"] += 1
        return f"{name}:\n{m.group(2)}\t.long   {s_sag}H\n{m.group(4)}"
    new_text = HDR.sub(fix, src_text)
    if stats["changed"]:
        src_file.write_text(new_text, encoding="latin-1", newline="")
        print(f"{snap_file.name}: {stats['changed']} SAGs synced ({stats['mismatch']} size mismatches)")
        total += stats["changed"]
    else:
        print(f"{snap_file.name}: clean")
print("TOTAL synced:", total)
