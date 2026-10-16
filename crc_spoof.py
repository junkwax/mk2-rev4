#!/usr/bin/env python3
"""
CRC32 spoofer for MK2 modified ROMs.

FBNeo validates each ROM in a romset against a hardcoded CRC32 in its driver
table. Our modified program/sound ROMs no longer match the retail L3.1 CRCs,
so FBNeo refuses to boot. This script flips 4 bytes inside a known-safe
padding region of each ROM to force CRC32(rom) == target.

CRC32 is linear over GF(2): for a fixed 4-byte patch offset, there is exactly
one 4-byte value that produces any given target CRC. We solve directly — no
brute force.

Targets come from FBNeo's mk2 driver (the CRCs shown in the "ROM missing"
error screen).
"""
import io
import shutil
import sys
import zipfile
import zlib
from pathlib import Path

# FBNeo-expected CRC32s for all modified ROMs.
TARGETS = {
    # Program ROMs (always modified)
    "l3.1_mortal_kombat_ii_game_rom_uj12.uj12": 0xcf100a75,
    "l3.1_mortal_kombat_ii_game_rom_ug12.ug12": 0x582c7dfd,
    # Sound ROMs (PLBUILD/regenerated set must satisfy FBNeo's retail CRC table)
    "l1_mortal_kombat_ii_sound_rom_u2.u2":      0x5f23d71d,
    "l1_mortal_kombat_ii_sound_rom_u3.u3":      0xd6d92bf9,
    "l1_mortal_kombat_ii_sound_rom_u4.u4":      0xeebc8e0f,
    "l1_mortal_kombat_ii_sound_rom_u5.u5":      0x2b0b7961,
    "l1_mortal_kombat_ii_sound_rom_u6.u6":      0xf694b27f,
    "l1_mortal_kombat_ii_sound_rom_u7.u7":      0x20387e0a,
    # Video ROMs changed by sprite edits (e.g., Cage pants)
    "l1_mortal_kombat_ii_game_rom_ug14.ug14": 0x01e73af6,
    "l1_mortal_kombat_ii_game_rom_uj14.uj14": 0xd4985cbb,
    "l1_mortal_kombat_ii_game_rom_ug19.ug19": 0xfec137be,
    "l1_mortal_kombat_ii_game_rom_uj19.uj19": 0x2d763156,
    "l1_mortal_kombat_ii_game_rom_ug16.ug16": 0x8ba6ae18,
    "l1_mortal_kombat_ii_game_rom_uj16.uj16": 0x39d885b4,
    "l1_mortal_kombat_ii_game_rom_ug20.ug20": 0x809118c1,
    "l1_mortal_kombat_ii_game_rom_uj20.uj20": 0xb96824f0,
    "l1_mortal_kombat_ii_game_rom_ug17.ug17": 0x937d8620,
    "l1_mortal_kombat_ii_game_rom_uj17.uj17": 0x218de160,
    "l1_mortal_kombat_ii_game_rom_ug22.ug22": 0x154d53b1,
    "l1_mortal_kombat_ii_game_rom_uj22.uj22": 0x8891d785,
}

# Patch offsets sit inside 0xFF tail padding of each ROM.
PATCH_OFFSETS = {
    # Program ROMs — padding immediately before the vector table.
    # Each 512 KB chip stores every other byte of the flat program ROM.
    # Flat 0xFFF80..0xFFFFF is VECTORS, so chip 0x7FFC0..0x7FFFF is off-limits.
    # MK8MIL now packs REVX nearly full, leaving only the tail before vectors.
    "l3.1_mortal_kombat_ii_game_rom_uj12.uj12": 0x07FFBC,
    "l3.1_mortal_kombat_ii_game_rom_ug12.ug12": 0x07FFBC,
    # Sound ROMs — tail padding
    "l1_mortal_kombat_ii_sound_rom_u2.u2":      0x07FFFC,
    "l1_mortal_kombat_ii_sound_rom_u3.u3":      0x07FFFC,
    "l1_mortal_kombat_ii_sound_rom_u4.u4":      0x07FFFC,
    "l1_mortal_kombat_ii_sound_rom_u5.u5":      0x07FFFC,
    "l1_mortal_kombat_ii_sound_rom_u6.u6":      0x07FFFC,
    "l1_mortal_kombat_ii_sound_rom_u7.u7":      0x07FFFC,
    # Video ROMs — tail padding near 1 MB boundary
    "l1_mortal_kombat_ii_game_rom_ug14.ug14": 0x0FFFB2,
    "l1_mortal_kombat_ii_game_rom_uj14.uj14": 0x0FFFB2,
    "l1_mortal_kombat_ii_game_rom_ug19.ug19": 0x0FFFB1,
    "l1_mortal_kombat_ii_game_rom_uj19.uj19": 0x0FFFB1,
    "l1_mortal_kombat_ii_game_rom_ug16.ug16": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_uj16.uj16": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_ug20.ug20": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_uj20.uj20": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_ug17.ug17": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_uj17.uj17": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_ug22.ug22": 0x0FFF84,
    "l1_mortal_kombat_ii_game_rom_uj22.uj22": 0x0FFF84,
}

FALLBACK_PADDING_SCAN_BYTES = 0x2000


def find_tail_padding_offset(data: bytes, preferred_offset: int) -> int | None:
    """
    Return a safe 4-byte padding window near the ROM tail.

    Some source-built video chips are now dense enough that the old fixed
    spoof offset can land on real art data. Keep the fixed offset when it is
    still padding, otherwise scan the tail for a clean all-FF or all-00 window.
    """
    if data[preferred_offset:preferred_offset+4] in (b"\xff\xff\xff\xff", b"\x00\x00\x00\x00"):
        return preferred_offset

    floor = max(0, len(data) - FALLBACK_PADDING_SCAN_BYTES)
    for offset in range(len(data) - 4, floor - 1, -1):
        window = data[offset:offset+4]
        if window in (b"\xff\xff\xff\xff", b"\x00\x00\x00\x00"):
            return offset
    return None


def solve_patch(data: bytes, offset: int, target_crc: int) -> bytes:
    """
    Return 4 bytes that, when written at `offset`, make CRC32(data) == target_crc.

    Strategy: CRC32 is an affine function of the input bits. If we zero the
    4-byte window and compute CRC of that, then for each of the 32 bit
    positions in the window compute how toggling that bit perturbs the CRC,
    we get a 32x32 GF(2) matrix. Invert and solve for the bit pattern that
    shifts CRC-with-zeros to target.
    """
    assert 0 <= offset and offset + 4 <= len(data)

    # Baseline: CRC with the 4-byte window zeroed.
    zeroed = bytearray(data)
    zeroed[offset:offset+4] = b"\x00\x00\x00\x00"
    base_crc = zlib.crc32(bytes(zeroed)) & 0xFFFFFFFF

    # Build 32 basis vectors: CRC delta from flipping each bit in the window.
    basis = []
    for bit in range(32):
        probe = bytearray(zeroed)
        byte_idx = offset + (bit // 8)
        probe[byte_idx] = 1 << (bit % 8)
        bit_crc = zlib.crc32(bytes(probe)) & 0xFFFFFFFF
        basis.append(bit_crc ^ base_crc)  # delta contributed by this bit

    # We want: base_crc XOR (XOR of selected deltas) == target_crc
    # i.e. solve for bits x_i in GF(2) such that sum(x_i * basis[i]) == need
    need = base_crc ^ target_crc

    # Gaussian elimination over GF(2). Columns are bits 0..31, rows also 0..31.
    # Rewrite as matrix A where A[i] = basis[i], solve A^T * x = need.
    # Easier form: treat each basis[i] as a 32-bit column vector; we want the
    # combination x such that XOR of chosen columns == need.
    # Build rows of an augmented matrix and reduce.

    # Represent system as 32 equations (one per output bit) x 33 cols (32 + rhs).
    # equation j: XOR over i of ((basis[i] >> j) & 1) * x_i == (need >> j) & 1
    rows = []
    for j in range(32):
        row = 0
        for i in range(32):
            if (basis[i] >> j) & 1:
                row |= (1 << i)
        if (need >> j) & 1:
            row |= (1 << 32)  # rhs bit
        rows.append(row)

    # Gaussian elimination
    for col in range(32):
        # find pivot
        pivot = None
        for r in range(col, 32):
            if (rows[r] >> col) & 1:
                pivot = r
                break
        if pivot is None:
            raise RuntimeError(f"CRC basis is singular at col {col} -- "
                               f"patch offset may be bad (e.g., past EOF)")
        rows[col], rows[pivot] = rows[pivot], rows[col]
        for r in range(32):
            if r != col and ((rows[r] >> col) & 1):
                rows[r] ^= rows[col]

    # Extract solution bits
    x = 0
    for i in range(32):
        if (rows[i] >> 32) & 1:
            x |= (1 << i)

    # x is a 32-bit pattern; bit i corresponds to bit i of the 4-byte window
    # (little-endian within the window: bit 0..7 -> byte at offset+0, etc.)
    patch = bytes([(x >> (8*k)) & 0xFF for k in range(4)])
    return patch


def spoof_file(path: Path, target_crc: int, offset: int, dry_run: bool = False) -> bool:
    data = bytearray(path.read_bytes())
    current = zlib.crc32(bytes(data)) & 0xFFFFFFFF

    if current == target_crc:
        print(f"  {path.name}: already matches (0x{current:08x}) -- skipping")
        return True

    found_offset = find_tail_padding_offset(bytes(data), offset)
    if found_offset is None:
        window = bytes(data[offset:offset+4])
        print(f"  WARNING: patch window at 0x{offset:06x} is not padding "
              f"(found {window.hex()}) and no tail padding fallback was found -- spoofing aborted")
        return False
    if found_offset != offset:
        print(f"  {path.name}: patch window at 0x{offset:06x} is live data; "
              f"using tail padding at 0x{found_offset:06x}")
        offset = found_offset

    patch = solve_patch(bytes(data), offset, target_crc)
    data[offset:offset+4] = patch
    new_crc = zlib.crc32(bytes(data)) & 0xFFFFFFFF

    if new_crc != target_crc:
        print(f"  ERROR: solver produced crc 0x{new_crc:08x}, expected 0x{target_crc:08x}")
        return False

    print(f"  {path.name}: 0x{current:08x} -> 0x{new_crc:08x}  "
          f"(patched {patch.hex()} at 0x{offset:06x})")

    if not dry_run:
        path.write_bytes(bytes(data))
    return True


def spoof_bytes(data: bytes, name: str, target_crc: int, offset: int) -> bytes | None:
    """In-memory version of spoof_file — returns patched bytes, or None on error."""
    current = zlib.crc32(data) & 0xFFFFFFFF
    if current == target_crc:
        print(f"  {name}: already matches (0x{current:08x}) -- skipping")
        return data

    found_offset = find_tail_padding_offset(data, offset)
    if found_offset is None:
        window = data[offset:offset+4]
        print(f"  WARNING: {name} patch window at 0x{offset:06x} is not padding "
              f"(found {window.hex()}) and no tail padding fallback was found -- aborted")
        return None
    if found_offset != offset:
        print(f"  {name}: patch window at 0x{offset:06x} is live data; "
              f"using tail padding at 0x{found_offset:06x}")
        offset = found_offset

    patch = solve_patch(data, offset, target_crc)
    patched = bytearray(data)
    patched[offset:offset+4] = patch
    new_crc = zlib.crc32(bytes(patched)) & 0xFFFFFFFF
    if new_crc != target_crc:
        print(f"  ERROR: {name}: solver produced 0x{new_crc:08x}")
        return None
    print(f"  {name}: 0x{current:08x} -> 0x{new_crc:08x}  (patched {patch.hex()} at 0x{offset:06x})")
    return bytes(patched)


def spoof_zip(zip_path: Path, dry_run: bool = False) -> bool:
    """Patch the 3 known-modified ROMs inside a zip in-place. Creates .bak once."""
    print(f"Spoofing ROMs in {zip_path.name}" + (" (dry run)" if dry_run else ""))

    backup = zip_path.with_suffix(zip_path.suffix + ".bak")
    if not backup.exists() and not dry_run:
        shutil.copy2(zip_path, backup)
        print(f"  Backup: {backup.name}")

    # Read all entries; patch the targeted names.
    out_buf = io.BytesIO()
    ok = True
    with zipfile.ZipFile(zip_path, "r") as src, zipfile.ZipFile(out_buf, "w", zipfile.ZIP_STORED) as dst:
        for item in src.namelist():
            data = src.read(item)
            if item in TARGETS:
                patched = spoof_bytes(data, item, TARGETS[item], PATCH_OFFSETS[item])
                if patched is None:
                    ok = False
                    dst.writestr(item, data)
                else:
                    dst.writestr(item, patched)
            else:
                dst.writestr(item, data)

    if not dry_run and ok:
        zip_path.write_bytes(out_buf.getvalue())
        print(f"Wrote {zip_path}")
    return ok


def main():
    dry_run = "--dry-run" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]

    if not args:
        print("Usage: python crc_spoof.py <target> [--dry-run]")
        print()
        print("  <target> may be:")
        print("    - a .zip file  (patched in place; .zip.bak created on first run)")
        print("    - a directory  (all 3 loose ROMs patched in place)")
        print("    - a single ROM file (name must match an FBNeo romset entry)")
        sys.exit(1)

    target = Path(args[0])

    if target.is_file() and target.suffix.lower() == ".zip":
        sys.exit(0 if spoof_zip(target, dry_run) else 1)

    if target.is_dir():
        print(f"Spoofing ROMs in {target}/" + (" (dry run)" if dry_run else ""))
        ok = True
        for name, crc in TARGETS.items():
            path = target / name
            if not path.exists():
                print(f"  SKIP: {name} not found in {target}")
                continue
            ok &= spoof_file(path, crc, PATCH_OFFSETS[name], dry_run)
        sys.exit(0 if ok else 1)

    if target.is_file():
        name = target.name
        if name not in TARGETS:
            print(f"Error: {name} is not a known modified ROM. "
                  f"Expected one of: {list(TARGETS)}")
            sys.exit(1)
        ok = spoof_file(target, TARGETS[name], PATCH_OFFSETS[name], dry_run)
        sys.exit(0 if ok else 1)

    print(f"Error: {target} does not exist")
    sys.exit(1)


if __name__ == "__main__":
    main()
