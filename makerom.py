#!/usr/bin/env python3
"""
Convert mk2.out (TMS34010 COFF) to split ROM images for MAME.

Reads the COFF executable, extracts all ROM-resident sections,
and byte-interleaves into even/odd ROM files (UJ12/UG12).
Validates output against T-Unit chip capacities.
"""
import struct
import sys
import time
from pathlib import Path


ROM_BASE = 0xFF800000 // 8  # TMS34010 bit address -> byte address
FILL = 0xFF  # fill byte for uninitialized ROM areas

# T-Unit physical ROM chip capacities
PROGRAM_CHIP_SIZE = 0x80000   # 512 KB per chip (27C4001 or equivalent)
FLAT_ROM_MAX      = 0x100000  # 1 MB total program ROM

# Original REVX window: 0xFFD00000 - 0xFFFFFBFF. It is reserved for the
# existing movie/CPU-read payload only. Do not add normal PIXBLT sprite data,
# new LODs, or new payload entries here; use the fixed image-ROM wrappers
# documented in doc/CUSTOM_CONTENT.md and doc/ASSET_SPACE_LEDGER.md.
# The REVX_PAYLOADS table records existing reserved data and validates it.
REVX_IRW_HEADER_SIZE = 68  # LOAD2 IRW header bytes to skip

REVX_PAYLOADS = [
    # (TMS address, IRW filename, label)
    # Base moved 0xFFD2B000 -> 0xFFD39000 on 2026-08-01.  The program ROM was
    # full: .data had grown to 0xFFD29ED0, within a few hundred bytes of the
    # old base, while roughly 10.2 KB sat unused BETWEEN the end of this
    # payload and the REVX window end.  Shifting the whole pool up hands that
    # slack to .text/.data and still leaves ~2.4 KB of guard after it.
    #
    # Base moved 0xFFD39000 -> 0xFFED0000 on 2026-08-24, for the same reason
    # and on a much larger scale.  The 14 program-ROM ending frames were
    # retired on 2026-08-11, which cut this payload from 348,528 bytes to
    # 153,198 - but the base never moved, so all 210,698 reclaimed bytes sat
    # ABOVE the payload where .data cannot reach them.  Headroom for new
    # code/tables was down to 1,458 bytes while a fifth of the program ROM
    # was idle.  The new base leaves 2,314 bytes of guard after the payload
    # (the 2026-08-01 shift left 2,468) and hands ~209.8 KB to .text/.data.
    # Largest legal base for a 153,198-byte payload is 0xFFED4850.
    #
    # Base moved 0xFFED0000 -> 0xFFEB8000 on 2026-09-02 to fit a 13th frame:
    # VS_EM, Ermac's VS portrait (12,298 bytes).  The pool grows DOWNWARD, so
    # adding a frame costs .text/.data headroom rather than the guard above -
    # dropping the base by 0x3000 (12,288 bytes) keeps ~2.3 KB of guard after
    # the payload, the same as before.
    #
    # Base moved 0xFFEB8000 -> 0xFFEB4000 on 2026-09-02 when VS_EM's art was
    # re-imported 1,605 bytes larger (12,298 -> 13,903), which would have left
    # only 699 bytes of guard.  The guard above the payload is dead space, so
    # a small one is not wasteful in itself - but this art has been re-cut
    # several times, and an overflow costs a full build cycle to discover.
    # 2 KB out of ~186 KB of .data headroom buys a ~2.7 KB cushion.  Ermac's portrait went here rather than
    # into a video-ROM sidecar because a movie frame must be BANK 0 (movie_run
    # has no bank select) and no free bank-0 run was left big enough - the
    # largest was 8,132 bytes.  Program ROM has no banking at all.
    #
    # Base moved 0xFFEB4000 -> 0xFFE9C000 on 2026-09-25 when JADE's portrait
    # joined the pool.  Her video-ROM sidecar (VSJDMOV.LOD) was RETIRED: her
    # art grew to 16,056 bytes against a 16,048-byte bank-0 slot, and every
    # neighbour in that packed chain had 2-10 bytes of guard, so there was no
    # local room.  Bank 0 is the scarce space (largest free run 31,288 bytes,
    # everything else under 1,300); program ROM had ~102 KB of .data headroom.
    # Retiring the sidecar hands 16,048 bytes back to bank 0.  Ermac's art
    # shrank 14,956 -> 10,629 in the same pass, so the pool only grew 11,729.
    #
    # Base moved 0xFFE9C000 -> 0xFFE7C000 on 2026-09-26 for RAIN's portrait
    # (VS_RN, 15,943 bytes).  Jade's vacated bank-0 slot would have fitted it
    # with ~115 bytes of guard, but every portrait in this tree has been re-cut
    # larger at least once (Ermac 12,298 -> 13,903 -> 14,982), and a re-cut that
    # overflows a video-ROM slot costs a repack of a chain packed at 2-10 byte
    # guards.  Program ROM is 2 edits instead of 8 and absorbs growth by moving
    # this base; the cost is .text/.data headroom, so watch it.
    #
    # Base moved 0xFFE7C000 -> 0xFFE70000 on 2026-09-29: RAIN and ERMAC were
    # both re-cut and both grew (VS_RN 15,943 -> 18,603, VS_EM 10,629 ->
    # 14,468, +6,499 together), which would have left the pool 3,807 bytes
    # SHORT.  Down 0x1800 restores ~2.3 KB of guard.
    #
    # THIS ADDRESS, data/MK8MIL.LOD's ***> line, and src/MK8ZIP.TBL's equates
    # must all match.  makerom embeds the payload here regardless of the base
    # recorded in the IRW header, and the game reads it through MK8ZIP.TBL, so
    # a disagreement silently misaddresses every VS portrait and ending.
    # src/MK8ZIP.TBL is taken straight from the LOAD2 output for this reason.
    (0xFFE70000, "MK8MIL.IRW", "VS/ending movie frames"),
    # NINJA2 moved to MK4MIL.LOD — frames now live in video ROM with other ninja sprites.
    # The historical JCHRIP/REVX route is permanently retired. Cage's active
    # headhole attacker frames are packed through MOVEART1 in video ROM.
    # STCUT retired from program ROM: T-Unit PIXBLT cannot source from program ROM
    # (hardware limitation confirmed by garbled-sprite testing — the original REVX
    # space was only ever used for zip-compressed FORM data via movie_run, not normal
    # sprite PIXBLT). Sprites moved into MK5MIL.LOD so they live in video ROM.
    # data/STCUT.LOD and data/STCUT.IRW remain on disk for reference.
    # (0xFFD00000, "STCUT.IRW", "Shang Tsung cut moves (STBACKFLIP + STROUNDPUNCH)"),
    # HKBFIST moved to MK5MIL.LOD; keep REVX for explicit movie/CPU-read payloads only.
]
REVX_WINDOW_START = 0xFFD00000
REVX_VECTOR_START = 0xFFFFFC00
# Reserve the last 8 flat bytes before VECTORS for crc_spoof.py's program-ROM
# patch windows. VECTORS begin at 0xFFFFFC00.
REVX_WINDOW_END   = 0xFFFFFBC0  # exclusive


def tms_from_rom_offset(offset):
    """Convert a flat program-ROM byte offset back to a TMS bit address."""
    return 0xFF800000 + offset * 8


def fail_on_overlap(start, end, label, placed):
    """Fail if [start, end) overlaps any previously placed ROM range."""
    for ps, pe, plabel in placed:
        if start < pe and end > ps:
            print(f"  Error: ROM overlap — {label} "
                  f"(0x{tms_from_rom_offset(start):08X}-"
                  f"0x{tms_from_rom_offset(end):08X}) collides with "
                  f"{plabel} (0x{tms_from_rom_offset(ps):08X}-"
                  f"0x{tms_from_rom_offset(pe):08X})")
            sys.exit(1)


def read_coff(path):
    """Parse TMS34010 COFF file and return sections with data."""
    with open(path, "rb") as f:
        data = f.read()

    magic = struct.unpack_from("<H", data, 0)[0]
    if magic != 0x0090:
        print(f"Warning: unexpected COFF magic 0x{magic:04x} (expected 0x0090)")

    nsections = struct.unpack_from("<H", data, 2)[0]
    opt_hdr_size = struct.unpack_from("<H", data, 16)[0]
    hdr_end = 20 + opt_hdr_size

    sections = []
    for i in range(nsections):
        off = hdr_end + i * 40
        name = data[off:off+8].rstrip(b"\x00").decode("ascii", errors="replace")
        paddr = struct.unpack_from("<I", data, off + 8)[0]
        vaddr = struct.unpack_from("<I", data, off + 12)[0]
        size  = struct.unpack_from("<I", data, off + 16)[0]
        dptr  = struct.unpack_from("<I", data, off + 20)[0]
        flags = struct.unpack_from("<I", data, off + 36)[0]

        # TMS34010 COFF: vaddr and size are in BITS (bit-addressable CPU)
        # File offsets (dptr) are in bytes
        size_bytes = size // 8
        vaddr_bytes = vaddr // 8 if vaddr > 0 else 0

        sec_data = None
        is_bss = (flags & 0x80) != 0  # STYP_BSS
        if size_bytes > 0 and dptr > 0 and not is_bss:
            sec_data = data[dptr:dptr + size_bytes]

        sections.append({
            "name": name, "vaddr": vaddr_bytes, "size": size_bytes,
            "data": sec_data, "flags": flags, "is_bss": is_bss,
        })

    return sections


def build_rom_image(sections):
    """Build a flat ROM image from ROM-resident sections."""
    # Find all sections that go into ROM (address >= FF800000)
    rom_sections = []
    for s in sections:
        if s["vaddr"] >= ROM_BASE and s["size"] > 0 and s["data"] is not None:
            rom_sections.append(s)

    if not rom_sections:
        print("Error: no ROM-resident sections found")
        sys.exit(1)

    # Calculate ROM size needed
    rom_end = 0
    for s in rom_sections:
        offset = s["vaddr"] - ROM_BASE
        end = offset + s["size"]
        if end > rom_end:
            rom_end = end

    # VECTORS at FFFFFC00 maps to offset 0x7FFC00 from ROM_BASE
    # Round up to next power of 2 for clean ROM size
    rom_size = 1
    while rom_size < rom_end:
        rom_size *= 2

    print(f"ROM image size: {rom_size} bytes ({rom_size // 1024} KB)")
    print(f"ROM sections:")

    # Create ROM image filled with FILL byte
    rom = bytearray([FILL] * rom_size)

    placed = []
    for s in rom_sections:
        offset = s["vaddr"] - ROM_BASE
        size = s["size"]
        fail_on_overlap(offset, offset + size, s["name"], placed)
        print(f"  {s['name']:10s}  0x{s['vaddr']:08X}  offset 0x{offset:06X}  {size:7d} bytes")
        rom[offset:offset + size] = s["data"]
        placed.append((offset, offset + size, s["name"]))

    return rom, placed


def interleave(rom):
    """Split ROM into even/odd byte lanes (16-bit interleave)."""
    # TMS34010 is little-endian 16-bit: byte 0 = low, byte 1 = high
    # UJ12 = even bytes (lane 0), UG12 = odd bytes (lane 1)
    even = bytearray(len(rom) // 2)
    odd = bytearray(len(rom) // 2)

    for i in range(0, len(rom), 2):
        even[i // 2] = rom[i]
        odd[i // 2] = rom[i + 1]

    return even, odd


def validate_capacity(uj12_size, ug12_size, flat_size):
    """Check program ROMs against T-Unit chip limits. Returns True if OK."""
    print(f"\n  T-Unit capacity:")
    ok = True
    for label, size in [("UJ12 (even)", uj12_size), ("UG12 (odd)", ug12_size)]:
        pct = size / PROGRAM_CHIP_SIZE * 100
        status = "OK" if size <= PROGRAM_CHIP_SIZE else "OVERFLOW"
        marker = "  " if size <= PROGRAM_CHIP_SIZE else "!!"
        print(f"  {marker} {label:16s}  {size:>8,d} / {PROGRAM_CHIP_SIZE:>8,d} bytes  ({pct:5.1f}%)  {status}")
        if size > PROGRAM_CHIP_SIZE:
            ok = False

    flat_pct = flat_size / FLAT_ROM_MAX * 100
    flat_status = "OK" if flat_size <= FLAT_ROM_MAX else "OVERFLOW"
    marker = "  " if flat_size <= FLAT_ROM_MAX else "!!"
    print(f"  {marker} {'flat (total)':16s}  {flat_size:>8,d} / {FLAT_ROM_MAX:>8,d} bytes  ({flat_pct:5.1f}%)  {flat_status}")
    if flat_size > FLAT_ROM_MAX:
        ok = False

    if ok:
        print(f"  PASS — ROMs fit T-Unit program chip capacity")
    else:
        print(f"  FAIL — ROMs exceed T-Unit chip capacity. Reduce code/data or use larger EPROMs.")
    return ok


def embed_revx_payloads(rom, script_dir, existing_ranges=None):
    """Embed REVX_PAYLOADS into rom[] at their declared addresses, asserting
    no two payloads overlap. Fails the build on overlap or out-of-window
    addresses — silent corruption here used to manifest as "all ninjas
    garbled" or fatality frames showing the wrong character's pixels.

    All bookkeeping is in ROM-byte offsets (rom[] is byte-addressed). TMS
    bit addresses from REVX_PAYLOADS are converted once at the top."""
    win_start = (REVX_WINDOW_START - 0xFF800000) // 8  # byte offset into rom[]
    win_end   = (REVX_WINDOW_END   - 0xFF800000) // 8
    win_bytes = win_end - win_start

    placed = list(existing_ranges or [])  # (byte_start, byte_end, label)
    payload_ranges = []
    for addr, fname, label in REVX_PAYLOADS:
        irw_path = script_dir / "data" / fname
        if not irw_path.exists():
            print(f"  Note: {fname} not found — run image build first")
            continue

        if addr < REVX_WINDOW_START or addr >= REVX_WINDOW_END:
            print(f"  Error: {fname} address 0x{addr:08X} outside REVX window")
            sys.exit(1)

        rom_offset = (addr - 0xFF800000) // 8
        payload = irw_path.read_bytes()[REVX_IRW_HEADER_SIZE:]
        byte_end = rom_offset + len(payload)
        if byte_end > win_end:
            free_here = win_end - rom_offset
            print(f"  Error: {fname} ({len(payload):,d} bytes) overflows REVX "
                  f"window — only {free_here:,d} bytes available at "
                  f"0x{addr:08X}")
            sys.exit(1)

        fail_on_overlap(rom_offset, byte_end, fname, placed)

        rom[rom_offset:byte_end] = payload
        placed.append((rom_offset, byte_end, fname))
        payload_ranges.append((rom_offset, byte_end, fname))
        print(f"  REVX        0x{addr:08X}  offset 0x{rom_offset:06X}  "
              f"{len(payload):7d} bytes  ({fname} — {label})")

    if payload_ranges:
        last_byte_end = max(pe for _, pe, _ in payload_ranges)
        free = win_end - last_byte_end
        last_tms = 0xFF800000 + last_byte_end * 8
        print(f"  REVX        free after last payload: {free:,d} bytes "
              f"(0x{last_tms:08X}-0x{REVX_WINDOW_END:08X}), "
              f"window total {win_bytes:,d}")


def wait_for_settled(path, quiet_seconds=3.0, timeout=90.0):
    """Block until `path` has stopped changing, then return.

    THE LINK RACE.  build.py drives GSPLNK inside DOSBox and returns before
    the linker has finished writing mk2.out.  A pipeline that chains
    `build.py && makerom.py` therefore reads the PREVIOUS link, or worse a
    half-written one -- valid COFF headers, correct reported section sizes,
    truncated content.  The ROM builds and installs without a single error
    and then boots to character select and dies at fight start.

    Cost of learning this the hard way (2026-08-14): a 0/19 stability sweep
    read as a code regression, on a build whose only problem was that
    mk2.out's mtime was 25 seconds NEWER than the rom/*.bin made from it.

    Polling for a quiet period is the fix rather than a docs note, because
    the failure is silent at every other layer and the check costs one
    `os.stat` a second on an already-settled file.
    """
    deadline = time.monotonic() + timeout
    last = None
    stable_since = None
    announced = False
    while True:
        st = path.stat()
        sig = (st.st_size, st.st_mtime_ns)
        now = time.monotonic()
        if sig != last:
            last, stable_since = sig, now
            if not announced:
                print(f"  waiting for {path.name} to settle "
                      f"(linker may still be writing)...")
                announced = True
        elif now - stable_since >= quiet_seconds:
            return
        if now > deadline:
            print(f"  WARNING: {path.name} still changing after {timeout:.0f}s "
                  f"— packaging it anyway, but the ROM may be from a partial link.")
            return
        time.sleep(0.5)


def main():
    script_dir = Path(__file__).parent.resolve()
    coff_path = script_dir / "src" / "mk2.out"
    rom_dir = script_dir / "rom"
    rom_dir.mkdir(exist_ok=True)

    if not coff_path.exists():
        print(f"Error: {coff_path} not found. Run build first.")
        sys.exit(1)

    wait_for_settled(coff_path)

    print(f"Reading {coff_path}...")
    sections = read_coff(coff_path)
    print(f"Found {len(sections)} sections")

    rom, placed_ranges = build_rom_image(sections)

    embed_revx_payloads(rom, script_dir, placed_ranges)

    even, odd = interleave(rom)

    # Write raw interleaved ROM files
    uj12 = rom_dir / "mk2_uj12.bin"
    ug12 = rom_dir / "mk2_ug12.bin"
    uj12.write_bytes(even)
    ug12.write_bytes(odd)

    print(f"\nROM images written:")
    print(f"  {uj12.name}  ({len(even):,d} bytes) - even bytes (UJ12)")
    print(f"  {ug12.name}  ({len(odd):,d} bytes) - odd bytes (UG12)")

    # Also write a non-interleaved flat ROM for analysis
    flat = rom_dir / "mk2_flat.bin"
    flat.write_bytes(rom)
    print(f"  {flat.name} ({len(rom):,d} bytes) - flat ROM image")

    ok = validate_capacity(len(even), len(odd), len(rom))

    print("\nDone.")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
