#!/usr/bin/env python3
"""
Export mk2.map symbols as FBNeo SYSTEM_RAM offsets for the Freeplay client.

The TMS34010 map reports bit addresses. FBNeo's libretro core exposes game RAM
through RETRO_MEMORY_SYSTEM_RAM, whose offsets are byte addresses minus
0x200000. This script emits a JSON manifest plus a Rust constants file so the
client can be updated from the build output instead of by hand.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
DEFAULT_MAP = REPO / "src" / "mk2.map"
DEFAULT_JSON = REPO / "tmp" / "freeplay_addresses.json"
DEFAULT_RUST = REPO / "tmp" / "freeplay_addresses.rs"
FBNEO_SYSTEM_RAM_BASE = 0x200000


SYMBOL_ADDRS = {
    "netplay_sync": "NETPLAY_SYNC_ADDR",
    "f_freeze_timer": "FREEZE_TIMER_ADDR",
    "gstate": "GSTATE_ADDR",
    # Nulled to 0xFFFF at select-screen entry (MKSEL.ASM player_select),
    # written with the real fighter id when that side locks in. Freeplay's
    # Lab uses this to hand P2's select cursor to the player after P1 picks.
    "p1_char": "P1_CHAR_ADDR",
    "p2_char": "P2_CHAR_ADDR",
    "p1_bar": "P1_HP_ADDR",
    "p1_matchw": "P1_MATCHW",
    "p2_bar": "P2_HP_ADDR",
    "p2_matchw": "P2_MATCHW",
    "round_num": "ROUND_NUM",
    "winner_status": "WINNER_STATUS",
    "f_colbox": "HITBOX_FLAG_ADDR",
    "f_netplay": "NETPLAY_ACTIVE_ADDR",
    # Process pointers: p_action lives at proc+0x1f0, which is what a lab
    # trace needs to see startup/active/recovery frames of a move.
    "p1_proc": "P1_PROC_ADDR",
    "p2_proc": "P2_PROC_ADDR",
    "f_no_blood": "NO_BLOOD_FLAG_ADDR",
    "f_no_violence": "NO_VIOLENCE_FLAG_ADDR",
    "f_shadows": "SHADOWS_FLAG_ADDR",
    "f_skew": "GROUND_SKEW_FLAG_ADDR",
    "active": "ACTIVE_PROCESS_LIST_ADDR",
    "free": "FREE_PROCESS_LIST_ADDR",
    "timer": "MPROC_TIMER_ADDR",
    "overload": "OVERLOAD_ADDR",
    # Load instrumentation latched by the ROM (MPROC.ASM).  peak_overload is
    # the high-water mark of overload -- 2 means every process pass finished
    # inside its tick, anything higher means frames were lost.  qdma_drops
    # counts sprites qdma silently discarded on a full DMA queue.  Both are
    # write-only in game code, so reading them cannot perturb anything.
    "peak_overload": "PEAK_OVERLOAD_ADDR",
    "qdma_drops": "QDMA_DROPS_ADDR",
    "ofree": "FREE_OBJECT_LIST_ADDR",
    "objstr": "OBJECT_STORE_ADDR",
    "objlst": "OBJECT_LIST_1_ADDR",
    "objlst2": "OBJECT_LIST_2_ADDR",
    "objlst3": "OBJECT_LIST_3_ADDR",
    "last_objlst": "OBJECT_LIST_END_ADDR",
    "baklst1": "BACKGROUND_LIST_1_ADDR",
    "baklst2": "BACKGROUND_LIST_2_ADDR",
    "baklst3": "BACKGROUND_LIST_3_ADDR",
    "baklst4": "BACKGROUND_LIST_4_ADDR",
    "baklst5": "BACKGROUND_LIST_5_ADDR",
    "baklst6": "BACKGROUND_LIST_6_ADDR",
    "baklst7": "BACKGROUND_LIST_7_ADDR",
    "baklst8": "BACKGROUND_LIST_8_ADDR",
}

# These are the position mirrors Freeplay currently pokes for lab/drone helpers.
# They sit inside the close-button queue area in this ROM layout; keeping the
# derivation here makes the odd-looking constants auditable.
DERIVED_ADDRS = {
    "p1_x": ("P1_X_ADDR", "p1_bcq", 0x08),
    "p1_y": ("P1_Y_ADDR", "p1_bcq", 0x0A),
    "p2_x": ("P2_X_ADDR", "p2_bcq", 0x08),
    "p2_y": ("P2_Y_ADDR", "p2_bcq", 0x0A),
}


def rom_fnv(rom: Path) -> str:
    """The same hash freeplay's matchmaking::rom_fnv_hash computes.

    FNV-1a over little-endian 8-byte words of the zip, zero-padded, reported
    as the top 32 bits. Must stay byte-for-byte identical to the Rust side --
    the client compares this against the ROM it loaded to decide whether the
    address table it was built with is meaningful.
    """
    data = rom.read_bytes()
    h = 0xCBF29CE484222325
    for i in range(0, len(data), 8):
        word = data[i : i + 8].ljust(8, b"\x00")
        h ^= int.from_bytes(word, "little")
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return format(h >> 32, "08x")


def load_symbols(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    in_global = False
    for line in path.read_text(encoding="latin-1", errors="replace").splitlines():
        if "GLOBAL SYMBOLS" in line:
            in_global = True
            continue
        if not in_global:
            continue
        for addr, name in re.findall(r"([0-9a-fA-F]{8})\s+([A-Za-z_]\S*)", line):
            symbols[name] = int(addr, 16)
    return symbols


def fbneo_offset(bit_addr: int) -> int:
    if bit_addr % 8:
        raise ValueError(f"bit address is not byte-aligned: 0x{bit_addr:08x}")
    return bit_addr // 8 - FBNEO_SYSTEM_RAM_BASE


def require_symbol(symbols: dict[str, int], name: str) -> int:
    try:
        return symbols[name]
    except KeyError as exc:
        raise SystemExit(f"ERROR: symbol not found in map: {name}") from exc


def build_records(symbols: dict[str, int]) -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for symbol, rust_const in SYMBOL_ADDRS.items():
        bit_addr = require_symbol(symbols, symbol)
        records[symbol] = {
            "rust_const": rust_const,
            "symbol": symbol,
            "bit_address": f"0x{bit_addr:08X}",
            "fbneo_offset": f"0x{fbneo_offset(bit_addr):05X}",
        }

    for name, (rust_const, base_symbol, byte_delta) in DERIVED_ADDRS.items():
        base_bit_addr = require_symbol(symbols, base_symbol)
        bit_addr = base_bit_addr + byte_delta * 8
        records[name] = {
            "rust_const": rust_const,
            "symbol": name,
            "derived_from": base_symbol,
            "byte_delta": byte_delta,
            "bit_address": f"0x{bit_addr:08X}",
            "fbneo_offset": f"0x{fbneo_offset(bit_addr):05X}",
        }

    return records


# The ROM's own copy of this table (src/FPADDR.ASM -> fp_addr_manifest).
# Freeplay reads it out of whatever mk2.zip a player loads, so Lab and the
# f_netplay write work on ANY build that carries it - no export, no ROM-hash
# pairing. Layout, all 16-bit little-endian words as the TMS34010 stores them:
#   MANIFEST_MAGIC (4 words), version, count, then count x (.long name_hash,
#   .long bit_address).  name_hash is FNV-1a 32 over the record's ASCII name
#   (the map symbol, or the derived name for DERIVED_ADDRS).  The client
#   matches entries by hash, so order is free and new entries are harmless to
#   an old client.  Bump MANIFEST_VERSION only for a LAYOUT change.
MANIFEST_MAGIC = (0xF4E5, 0xA9D1, 0x5046, 0x4441)  # last two read "FPAD"
MANIFEST_VERSION = 1
DEFAULT_ASM = REPO / "src" / "FPADDR.ASM"


def fnv1a32(name: str) -> int:
    h = 0x811C9DC5
    for b in name.encode("ascii"):
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h


# PROGRAM-ROM symbols the client reads out of the ROM image itself, not out of
# RAM: carried in the manifest only (no RAM offset, so not in the Rust table).
# rom_name is the build stamp build.py writes ("REV 4.0 - PLAYTEST (BEDC5*)"),
# which the client's main screen shows so a player can say which build they
# are on.
ROM_POINTERS = ["rom_name"]


def render_asm(records: dict[str, dict[str, object]]) -> str:
    ordered = sorted(records.values(), key=lambda r: str(r["symbol"]))
    ordered += [{"symbol": name} for name in ROM_POINTERS]
    refs = sorted({str(r.get("derived_from", r["symbol"])) for r in ordered})
    lines = [
        "; GENERATED by tools/export_freeplay_addresses.py - do not edit by hand.",
        ";",
        "; FREEPLAY'S ADDRESS MANIFEST.  The client reads this out of the loaded",
        "; mk2.zip (uj12/ug12) to find the RAM its Lab tools and the f_netplay",
        "; write use, so a client works with any build that carries it instead of",
        "; only the one build its compiled table was exported from.  The linker",
        "; fills in every address: this file only changes when the symbol LIST",
        "; does.  Layout and hashing: see the generator.",
        '\t.FILE "fpaddr.asm"',
        "\t.OPTION B,D,L,T",
        "",
    ]
    for i in range(0, len(refs), 6):
        lines.append("\t.ref\t" + ",".join(refs[i : i + 6]))
    lines += [
        "",
        "\t.data",
        "\t.globl\tfp_addr_manifest",
        "fp_addr_manifest:",
        "\t.word\t" + ",".join(f"0{w:04X}H" for w in MANIFEST_MAGIC),
        f"\t.word\t{MANIFEST_VERSION},{len(ordered)}",
    ]
    for r in ordered:
        name = str(r["symbol"])
        if "derived_from" in r:
            expr = f"{r['derived_from']}+0{int(r['byte_delta']) * 8:X}H"
        else:
            expr = name
        lines.append(f"\t.long\t0{fnv1a32(name):08X}H,{expr}\t; {name}")
    lines.append("")
    return "\n".join(lines)


def render_rust(records: dict[str, dict[str, object]], source_map: Path, rom_hash: str) -> str:
    ordered = sorted(records.values(), key=lambda r: str(r["rust_const"]))
    magic = ", ".join(f"0x{w:04X}" for w in MANIFEST_MAGIC)
    lines = [
        "// Generated by mk2-main/tools/export_freeplay_addresses.py.",
        f"// Source: {source_map.as_posix()}",
        "// Copy into Freeplay after rebuilding the ROM. Do not edit by hand.",
        "#![allow(dead_code, non_snake_case)]",
        "",
        "use std::collections::HashMap;",
        "",
        "/// FBNeo maps MK2's system RAM at this offset, so every address here is",
        "/// (TMS34010 bit address / 8) - this base. Anything that follows a POINTER",
        "/// stored in game RAM (process blocks, object blocks) has to apply the same",
        "/// conversion by hand -- the stored value is a raw bit address.",
        f"pub const FBNEO_SYSTEM_RAM_BASE: usize = 0x{FBNEO_SYSTEM_RAM_BASE:X};",
        "",
        "/// FNV of the mk2.zip `COMPILED` was exported alongside, in the form",
        "/// `matchmaking::rom_fnv_hash` produces. Only consulted for a ROM that",
        "/// carries no address manifest (built before 2026-10-06): such a ROM gets",
        "/// `COMPILED` only if its hash matches. Empty = exported without `--rom`.",
        f'pub const SOURCE_ROM_FNV: &str = "{rom_hash}";',
        "",
        "/// `fp_addr_manifest` (mk2-main src/FPADDR.ASM): magic words, then the",
        "/// layout version, a count, and count x (FNV-1a 32 of the name, bit address).",
        f"pub const MANIFEST_MAGIC: [u16; 4] = [{magic}];",
        f"pub const MANIFEST_VERSION: u16 = {MANIFEST_VERSION};",
        "",
        "/// The RAM the client reads and pokes, as FBNeo SYSTEM_RAM offsets.",
        "/// Get the live one with `mk2_addrs::a()`, never `COMPILED` directly.",
        "#[derive(Clone, Copy, Debug, PartialEq, Eq)]",
        "pub struct Addrs {",
    ]
    for r in ordered:
        lines.append(f"    pub {r['rust_const']}: usize,")
    lines += [
        "}",
        "",
        "impl Addrs {",
        "    /// RAM wiped before a netplay session so both peers start equal.",
        "    pub fn zero_targets(&self) -> [usize; 3] {",
        "        [self.FREEZE_TIMER_ADDR, self.HITBOX_FLAG_ADDR, self.NETPLAY_SYNC_ADDR]",
        "    }",
        "}",
        "",
        "/// Exported from the map above - right only for the ROM `SOURCE_ROM_FNV` names.",
        "pub const COMPILED: Addrs = Addrs {",
    ]
    for r in ordered:
        const = r["rust_const"]
        symbol = r["symbol"]
        note = (
            f"{symbol}, {r['derived_from']} + 0x{r['byte_delta']:02X}"
            if "derived_from" in r
            else symbol
        )
        lines.append(f"    {const}: {r['fbneo_offset']}, // {note}")
    lines += [
        "};",
        "",
        "/// Every entry's manifest name and hash - what `from_manifest` looks up.",
        "pub const MANIFEST_NAMES: &[(&str, u32)] = &[",
    ]
    for r in ordered:
        lines.append(f'    ("{r["symbol"]}", 0x{fnv1a32(str(r["symbol"])):08X}),')
    lines += [
        "];",
        "",
        "/// Program-ROM symbols the manifest also carries (bit addresses in ROM,",
        "/// read out of the ROM image, not RAM): `rom_name` is the build stamp.",
        "pub const ROM_POINTERS: &[(&str, u32)] = &[",
    ]
    for name in ROM_POINTERS:
        lines.append(f'    ("{name}", 0x{fnv1a32(name):08X}),')
    lines += [
        "];",
        "",
        "/// Build the table from a ROM's manifest (name hash -> TMS34010 bit",
        "/// address). Err names the first entry the ROM does not carry.",
        "pub fn from_manifest(m: &HashMap<u32, u32>) -> Result<Addrs, &'static str> {",
        "    let f = |hash: u32, name: &'static str| -> Result<usize, &'static str> {",
        "        let bit = *m.get(&hash).ok_or(name)? as usize;",
        "        if bit % 8 != 0 {",
        "            return Err(name);",
        "        }",
        "        (bit / 8).checked_sub(FBNEO_SYSTEM_RAM_BASE).ok_or(name)",
        "    };",
        "    Ok(Addrs {",
    ]
    for r in ordered:
        sym = str(r["symbol"])
        lines.append(f'        {r["rust_const"]}: f(0x{fnv1a32(sym):08X}, "{sym}")?,')
    lines += [
        "    })",
        "}",
        "",
        "/// The table for the ROM that is loaded right now.",
        "pub fn a() -> &'static Addrs {",
        "    crate::rom_manifest::current()",
        "}",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", type=Path, default=DEFAULT_MAP)
    parser.add_argument("--json-out", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--rust-out", type=Path, default=DEFAULT_RUST)
    parser.add_argument(
        "--rom",
        type=Path,
        default=REPO / "rom" / "mk2.zip",
        help="ROM zip built from this same source, recorded so the client can "
        "tell when a player's ROM no longer matches the exported table",
    )
    parser.add_argument(
        "--asm-out",
        type=Path,
        default=DEFAULT_ASM,
        help="the ROM's own manifest (linked into the program ROM)",
    )
    parser.add_argument("--check", action="store_true", help="fail if outputs would change")
    args = parser.parse_args()

    if not args.map.exists():
        raise SystemExit(f"ERROR: map file not found: {args.map}")

    symbols = load_symbols(args.map)
    records = build_records(symbols)
    if args.rom.exists():
        rom_hash = rom_fnv(args.rom)
    else:
        # Emitted empty rather than guessed: the client treats an unrecorded
        # ROM as "unchecked", which is honest, where a wrong hash would warn
        # every player about a mismatch that isn't there.
        print(f"WARNING: ROM not found at {args.rom}; pairing will go unchecked")
        rom_hash = ""
    manifest = {
        "generated_by": "tools/export_freeplay_addresses.py",
        "source_map": str(args.map),
        "source_rom": str(args.rom),
        "source_rom_fnv": rom_hash,
        "fbneo_system_ram_base": f"0x{FBNEO_SYSTEM_RAM_BASE:X}",
        "addresses": records,
    }
    json_text = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    rust_text = render_rust(records, args.map, rom_hash)

    outputs = [
        (args.json_out, json_text),
        (args.rust_out, rust_text),
        (args.asm_out, render_asm(records)),
    ]
    if args.check:
        changed = [
            str(path)
            for path, text in outputs
            if not path.exists() or path.read_text(encoding="utf-8") != text
        ]
        if changed:
            raise SystemExit("ERROR: stale Freeplay address export: " + ", ".join(changed))
        print("Freeplay address export check passed")
        return 0

    # Phase E runs AFTER the link, so a changed manifest source means the ROM
    # just built does not carry it yet.  Only a change to the symbol LIST does
    # that (addresses are the linker's), so it is rare - but say so loudly.
    asm_text = outputs[2][1]
    asm_stale = (
        not args.asm_out.exists()
        or args.asm_out.read_text(encoding="utf-8") != asm_text
    )
    for path, text in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        # --rust-out normally points OUTSIDE this repo (the documented call is
        # `--rust-out ../freeplay/src/mk2_addrs.rs`), and relative_to raises
        # on a path that is not under REPO. Report it plainly rather than
        # crashing after the file has already been written.
        try:
            shown = path.relative_to(REPO)
        except ValueError:
            shown = path
        print(f"wrote {shown}")
    if asm_stale:
        print(
            f"ERROR: {args.asm_out.name} changed - the ROM just linked does not "
            "carry it. Re-run build.py (--asm-only is enough)."
        )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
