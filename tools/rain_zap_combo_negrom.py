#!/usr/bin/env python3
"""Build the PRE-FIX ROM for run_rain_zap_combo_test.ps1 -Negative.

The fix this rig exists for is ONE WORD: act_rain_storm in `cmb_holds`
(MKDISP.ASM), the list cmb_holding walks to decide whether the KOMBO KOUNTER's
clock may run this tick.  So the honest control is a ROM that differs in
exactly that word and nothing else - which is cheaper and safer than a second
`.set`-guarded build, and immune to whatever else is in the tree today.

cmb_holds is a `.word` table with no `.globl`, so it is not in mk2.map.  It is
found by CONTENT instead: the five action codes in order, which appear exactly
once in the megabyte.  Zeroing the act_rain_storm entry TERMINATES the list
early (the table is 0-terminated), which is precisely the pre-fix table - not
an approximation of it.

The two program chips are the even/odd byte lanes of the flat ROM
(makerom.py's interleave), so word k is uj12[k] | ug12[k] << 8.

    python tools/rain_zap_combo_negrom.py <src zip> <dst dir>

Writes <dst dir>/mk2.zip.  Refuses if the word is not where the pattern says,
rather than patching something else and producing a plausible wrong control.
"""
import os
import shutil
import sys
import zipfile

# cmb_holds, in order.  Kept as names + values so a reader can check them
# against MAINEQU.ASM without decoding hex.
CMB_HOLDS = [
    ("act_frozen", 0x0401),
    ("act_speared_sd", 0x0605),
    ("act_slipping", 0x060E),
    ("act_jax_dizzy", 0x0610),
    ("act_rain_storm", 0x050E),      # the one the fix added - index 4
    ("terminator", 0x0000),
]
TARGET = 4

UJ_SUFFIX = "uj12.uj12"
UG_SUFFIX = "ug12.ug12"


def member(names, suffix):
    hits = [n for n in names if n.endswith(suffix)]
    if len(hits) != 1:
        raise SystemExit("expected exactly one %s member, found %r" % (suffix, hits))
    return hits[0]


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, dst_dir = sys.argv[1], sys.argv[2]

    with zipfile.ZipFile(src) as zin:
        names = zin.namelist()
        uj_name, ug_name = member(names, UJ_SUFFIX), member(names, UG_SUFFIX)
        uj, ug = bytearray(zin.read(uj_name)), bytearray(zin.read(ug_name))
        if len(uj) != len(ug):
            raise SystemExit("program lanes differ in size: %d / %d" % (len(uj), len(ug)))

        want = [v for _, v in CMB_HOLDS]
        found = []
        for k in range(len(uj) - len(want)):
            if all(uj[k + i] | (ug[k + i] << 8) == want[i] for i in range(len(want))):
                found.append(k)
        if len(found) != 1:
            raise SystemExit(
                "cmb_holds not located uniquely (hits: %s).  If the table changed, "
                "update CMB_HOLDS - do NOT guess an offset." % [hex(f) for f in found])
        k = found[0] + TARGET
        name, val = CMB_HOLDS[TARGET]
        if uj[k] | (ug[k] << 8) != val:
            raise SystemExit("word at %#x is not %s - refusing" % (k, name))
        print("cmb_holds at word %#x; zeroing %s (%#06x) at word %#x" % (found[0], name, val, k))
        uj[k] = 0
        ug[k] = 0

        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, "mk2.zip")
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
            for it in zin.infolist():
                data = zin.read(it.filename)
                if it.filename == uj_name:
                    data = bytes(uj)
                elif it.filename == ug_name:
                    data = bytes(ug)
                zout.writestr(it, data)

    # The map belongs WITH the zip: a rig reading another build's map reads every
    # symbol at the wrong address and reports nothing wrong.
    src_map = os.path.join(os.path.dirname(os.path.abspath(src)), "mk2.map")
    if os.path.exists(src_map):
        shutil.copy(src_map, os.path.join(dst_dir, "mk2.map"))
    print("wrote", dst)
    # The program-ROM checksum is now wrong, which only matters with the Powerup
    # Test dip ON (default Off) - see romcheck in DIAGDTST.ASM.


if __name__ == "__main__":
    main()
