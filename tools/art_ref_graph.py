#!/usr/bin/env python3
"""Art reference graph: which packed sprite records can the game actually draw?

Row 28 of doc/GRAPHICS_OPPORTUNITIES.md.  Every dead-art prune so far was a
hand audit - four separate checks per record (retail source, frame lists,
inline decode windows, authored IMG sequences) - because nothing could answer
"is this reachable?" mechanically.  This does, from the BUILT program ROM
rather than the source text.

Why the binary and not the source
---------------------------------
A reference only counts if the assembler emitted it.  Scanning source counts
comments, `.globl` lines, and whole `.if 0` blocks (the retired
`jc_headhole_hp_test` hook is one), and misses pointers a macro builds.  The
linked ROM has none of those problems - but it is stripped: `mk2.out` has no
symbol table, the objects keep only globals, and the map lists ~2,600 globals
against ~10,000 table labels.  So addresses are recovered from LISTINGS:

  1. `--assemble` copies src/ to a scratch tree, turns `.include x.tbl/.asm`
     into `.copy` (identical code; TI only lists `.copy`), and runs GSPA -L on
     every MAKEFILE module in DOSBox.  Nothing shared is touched and nothing
     is linked.
  2. It then PROVES the scratch assembly is the build: every module's section
     sizes must equal the map's input sections, and where the root has objects,
     every section's raw bytes must equal them.  Any mismatch is fatal.
  3. label address = map origin of (module, section) + listing offset.

The graph
---------
Nodes are every label in a ROM section.  Every 16-bit-aligned 32-bit value in
the ROM sections is an edge candidate:
  pointer  value == a label's address         -> containing label -> label
  pixels   value == a record's SAG            -> containing label -> its pixels
  window   value inside a record's pixel span, stored where a sprite header
           keeps its SAG (label + 8 bytes)    -> containing label -> its pixels
Roots are code (every label in .text, plus VECTORS/FLOORORG/SHADORG) -
deliberately conservative: dead code keeps its art alive, never the reverse.
A reachable DATA label falls through into the next label unless it ends in a
terminator (a `0` long, or `ani_jump, target`), because MK2 lanes are pointer
lists that stop there.  Nothing falls through INTO a sprite header: headers are
only ever reached by pointer.

Classes (a record = a table label whose header is in the ROM)
-------------------------------------------------------------
  LIVE           its own header is reachable
  WINDOW         its header is not, but a reachable header reads its pixels
                 (KLUDGE_*, *_MIRROR, KAHNLIL1, KHEART6B_OPEN, Ermac's clones)
  AUTHORED       unreachable, but a frame of an authored IMG sequence whose
                 other frames ARE drawn - kept by policy (AUTOGRAPH7, KHEART1)
  DEAD           none of the above.  `named by` lists unreachable referrers,
                 so a dead lane shows up as the reason, not just "unnamed".

The error direction is deliberate everywhere: a mistake here makes art look
LIVE, never DEAD.  DEAD is still a candidate, not a verdict - prunes need
sign-off, and doc/graphics_opportunities/DEAD_ART_PRUNE.md is the record.

    python tools/art_ref_graph.py --assemble          # listings for this tree
    python tools/art_ref_graph.py                     # summary
    python tools/art_ref_graph.py --dead              # candidates, largest first
    python tools/art_ref_graph.py --explain KHEART1   # why, with the path
    python tools/art_ref_graph.py --root tmp/flip_head/old --assemble
"""
from __future__ import annotations

import argparse
import bisect
import importlib.util
import json
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from collections import defaultdict, deque
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

ROM_BASE = 0xFF800000
ROOT_SECTIONS = {".text", "VECTORS", "FLOORORG", "SHADORG"}
SAG_LO, SAG_HI = 0x02000000, 0x08000000      # video ROM, in bits
HDR_SAG = 8                                  # bytes: w,h,anix,aniy then SAG
ANI_JUMP = 1


# --------------------------------------------------------------- assemble

def _dosbox():
    spec = importlib.util.spec_from_file_location("buildpy", REPO / "build.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.get_dosbox_path()


def _coff_sections(path):
    d = path.read_bytes()
    n = struct.unpack_from("<H", d, 2)[0]
    opt = struct.unpack_from("<H", d, 16)[0]
    out = {}
    for i in range(n):
        o = 20 + opt + i * 40
        name = d[o:o + 8].rstrip(b"\0").decode("latin-1")
        size, ptr = struct.unpack_from("<II", d, o + 16)
        flags = struct.unpack_from("<I", d, o + 36)[0]
        raw = d[ptr:ptr + size // 8] if ptr and not flags & 0x80 else b""
        out[name] = (size, raw)
    return out


def map_input_sections(map_path):
    """-> {(MODULE, section): (origin_bits, length_bits)} from the link map."""
    out = {}
    for ln in map_path.open(encoding="latin-1"):
        m = re.match(r"^\s+([0-9a-f]{8})\s+([0-9a-f]{8})\s+([A-Z0-9_]+)\.OBJ \((\S+)\)", ln)
        if m:
            out[(m.group(3), m.group(4))] = (int(m.group(1), 16), int(m.group(2), 16))
    return out


def assemble(root, work):
    """Listings for `root` in `work`, proven identical to what was linked."""
    src = root / "src"
    modules = re.findall(r"^\s*([A-Z0-9_]+)\.OBJ\b",
                         (src / "MAKEFILE").read_text(errors="replace"), re.M)
    if work.exists():
        shutil.rmtree(work)
    (work / "src").mkdir(parents=True)
    (work / "tools").mkdir()
    (work / "data").mkdir()
    skip = {".OBJ", ".OUT", ".MAP", ".LST", ".LOG"}
    for p in src.iterdir():
        if p.is_file() and p.suffix.upper() not in skip and not p.name.lower().endswith(".bak"):
            shutil.copy2(p, work / "src" / p.name)
    shutil.copy2(REPO / "tools" / "GSPA.EXE", work / "tools" / "GSPA.EXE")

    inc = re.compile(r"(?im)^(\s*)\.include(\s+[A-Za-z0-9_]+\.(?:tbl|asm)\b)")
    for p in list((work / "src").glob("*.ASM")) + list((work / "src").glob("*.TBL")):
        s = p.read_text(encoding="latin-1")
        s2 = inc.sub(r"\1.copy\2", s)
        if s2 != s:
            p.write_text(s2, encoding="latin-1")
        # quoted includes reach into ..\data (MKHANG's EDACID/EDCHAIN/EDPFULL)
        for m in re.finditer(r'\.(?:include|copy)\s+"\.\.[\\/]data[\\/]([A-Za-z0-9_]+\.ASM)"', s, re.I):
            for base in (root / "data", REPO / "data"):
                if (base / m.group(1)).exists():
                    shutil.copy2(base / m.group(1), work / "data" / m.group(1))
                    break

    bat = ["@echo off"] + [f"GSPA {m} -H -L -v10 >> ..\\ASMLOG.TXT" for m in modules]
    (work / "src" / "LSTALL.BAT").write_text("\r\n".join(bat) + "\r\n", encoding="ascii")
    conf = []
    for ln in (REPO / "dosbox_asm.conf").read_text().splitlines():
        conf.append("call LSTALL.BAT" if ln.strip().lower().startswith("gmake") else ln)
    (work / "lst.conf").write_text("\n".join(conf) + "\n")

    print(f"assembling {len(modules)} modules with listings in {work} ...")
    subprocess.run([str(_dosbox()), "-conf", "lst.conf"], cwd=str(work),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    log = (work / "ASMLOG.TXT").read_text(errors="replace") if (work / "ASMLOG.TXT").exists() else ""
    clean = log.count("No Errors")
    missing = [m for m in modules if not (work / "src" / f"{m}.LST").exists()]
    if clean != len(modules) or missing:
        raise SystemExit(f"FAIL: {clean}/{len(modules)} modules assembled clean; "
                         f"no listing for {missing[:8]}")

    placed = map_input_sections(root / "src" / "mk2.map")
    size_ok = byte_ok = 0
    for m in modules:
        scratch = _coff_sections(work / "src" / f"{m}.OBJ")
        real_obj = src / f"{m}.OBJ"
        real = _coff_sections(real_obj) if real_obj.exists() else None
        for sec, (size, raw) in scratch.items():
            if (m, sec) in placed:
                if placed[(m, sec)][1] != size:
                    raise SystemExit(f"FAIL: {m} {sec} is {size:x} bits here but "
                                     f"{placed[(m, sec)][1]:x} in the map - not the linked build")
                size_ok += 1
            if real is not None:
                if real.get(sec) != (size, raw):
                    raise SystemExit(f"FAIL: {m} {sec} bytes differ from {real_obj}")
                byte_ok += 1
    print(f"verified: {len(modules)} modules clean, {size_ok} sections match the map, "
          f"{byte_ok} sections byte-identical to the root's objects")
    (work / "VERIFIED").write_text(f"{len(modules)} {size_ok} {byte_ok}\n")


# ---------------------------------------------------------------- load

def parse_listings(work, placed):
    """-> labels: [(addr_bits, name, module, section)], sorted by address."""
    labels = []
    ident = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):?(\s|$)")
    for lst in sorted((work / "src").glob("*.LST")):
        module = lst.stem.upper()
        section = ".text"
        for ln in lst.open(encoding="latin-1"):
            if len(ln) < 29 or not ln[2:8].strip().isdigit():
                continue
            src = ln[28:].rstrip("\n")
            body = src.split(";", 1)[0]
            # `.bss name,size` and `.usect` RESERVE space without leaving the
            # current section; only a bare .text/.data (or .sect) switches.
            # Treating `.bss x,n` as a switch silently dropped every label
            # after it - all of MKDISP's code, and with it the pointers to the
            # health-bar names, win digits and toast icons.
            if re.match(r"\s*\.(bss|usect)\b", body, re.I):
                continue
            d = re.match(r"\s*\.(text|data)\s*$", body, re.I)
            if d:
                section = "." + d.group(1).lower()
                continue
            d = re.match(r'\s*\.sect\s+"([^"]+)"', body, re.I)
            if d:
                section = d.group(1)
                continue
            addr = ln[9:17].strip()
            m = ident.match(src)
            if not m or not re.fullmatch(r"[0-9a-f]{8}", addr):
                continue
            if re.search(r"\s(\.set|\.equ|equ|\$macro|\.macro)\b", body, re.I):
                continue
            key = (module, section)
            if key not in placed or placed[key][0] < ROM_BASE:
                continue
            labels.append((placed[key][0] + int(addr, 16), m.group(1), module, section))
    # Bytes before a section's first label (the vector table has none at all)
    # still belong to that module: give each section start a node, so nothing
    # in it is attributed to the previous module's last label.
    have = {(a, mod, sec) for a, _, mod, sec in labels}
    for (mod, sec), (origin, length) in placed.items():
        if origin >= ROM_BASE and length and (origin, mod, sec) not in have:
            labels.append((origin, f"<{mod} {sec}>", mod, sec))
    labels.sort()
    return labels


def load_rom(root):
    flat = root / "rom" / "mk2_flat.bin"
    if flat.exists():
        return flat.read_bytes()
    for z in (root / "mk2.zip", root / "rom" / "mk2.zip"):
        if z.exists():
            with zipfile.ZipFile(z) as zf:
                names = zf.namelist()
                even = zf.read(next(n for n in names if n.lower().endswith("uj12")))
                odd = zf.read(next(n for n in names if n.lower().endswith("ug12")))
            rom = bytearray(len(even) * 2)
            rom[0::2], rom[1::2] = even, odd
            return bytes(rom)
    raise SystemExit(f"no program ROM under {root} (rom/mk2_flat.bin or mk2.zip)")


def table_labels(src, work):
    """-> {(module, label): TBL stem} for every table label a module copies.

    Keyed by module, not name: the same label can be defined in two tables
    (FONT7A is the real glyph in MKTEXT.TBL and a stray copy atop MKHH.TBL),
    and each is its own header in the ROM."""
    defs = defaultdict(set)
    for p in sorted(src.glob("*.TBL")):
        for ln in p.open(encoding="latin-1"):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", ln)
            if m:
                defs[m.group(1)].add(p.stem.upper())
    copy = re.compile(r"(?im)^\s*\.(?:copy|include)\s+([A-Za-z0-9_]+)\.tbl\b")
    copies = defaultdict(set)
    for p in (work / "src").glob("*.ASM"):
        for m in copy.finditer(p.read_text(encoding="latin-1")):
            copies[p.stem.upper()].add(m.group(1).upper())
    out = {}
    for name, stems in defs.items():
        for mod, copied in copies.items():
            hit = stems & copied
            if hit:
                out[(mod, name)] = sorted(hit)[0]
    return out


def _audit(root):
    """img_subframe_audit reads a module-level DATA; point it at THIS root, or
    a --root run silently uses the current tree's LODs."""
    import img_subframe_audit as audit
    data = root / "data"
    audit.DATA = data if (data / "IMGBUILD.BAT").exists() else REPO / "data"
    return audit


def packed_names(root):
    """Names a live LOD packs, with their IMG (for sequence lookup)."""
    audit = _audit(root)
    used, _, _ = audit.collect(audit.live_lods())
    return {n: img for img, names in used.items() for n in names}


def authored_sequences(packed, root):
    """-> {LABEL: [(IMG, sequence)]} for named IMG sequences; plus coverage."""
    import imgseq
    by_img = defaultdict(set)
    for name, img in packed.items():
        by_img[img].add(name)
    member = defaultdict(list)
    seqs = {}
    unnamed = 0
    for img in sorted(by_img):
        path = root / "data" / f"{img}.IMG"
        if not path.exists():
            path = REPO / "data" / f"{img}.IMG"
        if not path.exists():
            continue
        try:
            lib = imgseq.load(path)
            recs = imgseq.records(lib)
        except Exception:
            continue
        for r in recs:
            if r["script"]:
                continue
            frames = [lib["names"].get(idx, "").upper() for _, idx, _ in r["rows"]]
            if not any(frames):
                unnamed += 1
                continue
            key = (img, r["name"])
            seqs[key] = [f for f in frames if f]
            for f in seqs[key]:
                member[f].append(key)
    return member, seqs, unnamed


# ---------------------------------------------------------------- graph

def tbl_groups(root):
    """TBL stem -> the LOD that writes it.  A relative SAG is relative to its
    LOD's bank, so pixel spans are only comparable inside one LOD."""
    audit = _audit(root)
    out = {}
    for data in (audit.DATA,):
        for lod in audit.live_lods():
            p = data / f"{lod}.LOD"
            if not p.exists():
                continue
            for ln in p.read_text(errors="replace").splitlines():
                m = re.match(r"^\s*ASM>\s*([A-Za-z0-9_]+)\.TBL", ln, re.I)
                if m:
                    out.setdefault(m.group(1).upper(), lod)
    return out


def inline_sites():
    """The hand-carried headers in *.ASM, and the record + bit offset each
    reads (tools/sync_inline_sags.py is the authority; Phase D keeps it true)."""
    spec = importlib.util.spec_from_file_location("sis", REPO / "tools" / "sync_inline_sags.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return {label: (Path(tbl).stem.upper(), anchor, off)
            for label, (_, tbl, anchor, off) in mod.SITES.items()}


def reloc_positions(work, placed):
    """Absolute bit positions of every relocated field in the ROM sections.

    A real pointer - to a local label, an external, or label+offset - needs a
    relocation entry, because the section base is unknown until link.  A
    constant never has one.  Without this, header fields and ani commands
    that happen to spell an address (anix 16 / aniy -42 is 0xffd60010) read
    as pointers, and which ones do changes with every build.  COFF entries
    here are 10 bytes: r_vaddr (section-relative bits), r_symndx, r_type."""
    out = set()
    for obj in (work / "src").glob("*.OBJ"):
        module = obj.stem.upper()
        d = obj.read_bytes()
        n = struct.unpack_from("<H", d, 2)[0]
        opt = struct.unpack_from("<H", d, 16)[0]
        for i in range(n):
            o = 20 + opt + i * 40
            name = d[o:o + 8].rstrip(b"\0").decode("latin-1")
            relptr = struct.unpack_from("<I", d, o + 24)[0]
            nreloc = struct.unpack_from("<H", d, o + 32)[0]
            if (module, name) not in placed or placed[(module, name)][0] < ROM_BASE:
                continue
            base = placed[(module, name)][0]
            for k in range(nreloc):
                out.add(base + struct.unpack_from("<I", d, relptr + k * 10)[0])
    return out


def build(root, work):
    placed = map_input_sections(root / "src" / "mk2.map")
    labels = parse_listings(work, placed)
    rom = load_rom(root)
    tables = table_labels(root / "src", work)
    groups = tbl_groups(root)
    relocs = reloc_positions(work, placed)

    addrs = [a for a, *_ in labels]
    node_at, by_name = {}, {}
    for i, (a, name, mod, sec) in enumerate(labels):
        node_at.setdefault(a, i)
        by_name.setdefault(name, i)

    def rd(bit, fmt):
        b = (bit - ROM_BASE) // 8
        n = struct.calcsize(fmt)
        return struct.unpack_from(fmt, rom, b) if 0 <= b <= len(rom) - n else None

    def rd32(bit):
        v = rd(bit, "<I")
        return v[0] if v else None

    end = []
    for i, (a, name, mod, sec) in enumerate(labels):
        j = i + 1
        while j < len(labels) and labels[j][0] == a:
            j += 1
        nxt = labels[j][0] if j < len(labels) and labels[j][2:] == (mod, sec) else None
        origin, length = placed[(mod, sec)]
        end.append(nxt if nxt is not None else origin + length)

    # ---- records: every table label with room for a sprite header
    def space_of(sag, stem):
        return "ABS" if SAG_LO <= sag < SAG_HI else groups.get(stem, "TBL:" + stem)

    records = {}
    for i, (a, name, mod, sec) in enumerate(labels):
        if (mod, name) in tables and end[i] - a >= 14 * 8:
            w, h, ax, ay, sag, ctrl = rd(a, "<hhhhIH")
            records[i] = dict(w=w, h=h, sag=sag, ctrl=ctrl,
                              space=space_of(sag, tables[(mod, name)]))

    spaces = defaultdict(list)          # space -> sorted [(sag, node)]
    for i, r in records.items():
        spaces[r["space"]].append((r["sag"], i))
    starts = {}
    for sp, lst in spaces.items():
        lst.sort()
        starts[sp] = [s for s, _ in lst]

    def span_end(sp, sag):
        st = starts[sp]
        j = bisect.bisect_right(st, sag)
        return st[j] if j < len(st) else sag + 1

    def exact(sp, sag):
        st, lst = starts.get(sp, []), spaces.get(sp, [])
        j = bisect.bisect_left(st, sag)
        out = []
        while j < len(st) and st[j] == sag:
            out.append(lst[j][1])
            j += 1
        return out

    def overlapping(sp, lo, hi):
        """records in `sp` whose packed span meets [lo, hi)."""
        st, lst = starts.get(sp, []), spaces.get(sp, [])
        j = max(bisect.bisect_right(st, lo) - 1, 0)
        out = []
        while j < len(lst) and lst[j][0] < hi:
            s, node = lst[j]
            if span_end(sp, s) > lo:
                out.append(node)
            j += 1
        return out

    # ---- readers: (node, space, start, stop or None = exactly that image)
    readers = []
    for i, r in records.items():
        readers.append((i, r["space"], r["sag"], None))
    sites = inline_sites()
    unresolved_sites = []
    for label, (stem, anchor, off) in sites.items():
        i, a_i = by_name.get(label), by_name.get(anchor)
        if i is None or a_i is None or a_i not in records:
            unresolved_sites.append(label)
            continue
        w, h, ax, ay, sag, ctrl = rd(labels[i][0], "<hhhhIH")
        anc = records[a_i]
        start = anc["sag"] + off
        if off == 0 and (w, h) == (anc["w"], anc["h"]):
            readers.append((i, anc["space"], start, None))
        else:
            bpp = (ctrl >> 12) or 8
            readers.append((i, anc["space"], start, start + max(w, 1) * max(h, 1) * bpp))

    ptr_edges = defaultdict(set)
    sec_ranges = sorted({v for k, v in placed.items() if v[0] >= ROM_BASE})
    abs_starts = set(starts.get("ABS", []))
    orphan_relocs = 0                   # relocated fields in no label: parser gap
    for origin, length in sec_ranges:
        b0 = (origin - ROM_BASE) // 8
        b1 = b0 + length // 8
        for b in range(b0 + (b0 & 1), b1 - 3, 2):
            v = struct.unpack_from("<I", rom, b)[0]
            bit = ROM_BASE + b * 8
            k = bisect.bisect_right(addrs, bit) - 1
            if k < 0 or bit >= end[k]:
                if bit in relocs:
                    orphan_relocs += 1
                continue
            if bit in relocs:
                t = bisect.bisect_right(addrs, v) - 1
                if t >= 0 and v < end[t]:
                    t0 = t
                    while t0 >= 0 and labels[t0][0] == labels[t][0]:
                        ptr_edges[k].add(t0)        # every alias at that address
                        t0 -= 1
                continue                            # a pointer is never a SAG
            if not SAG_LO <= v < SAG_HI or k in records:
                continue
            if bit == labels[k][0] + HDR_SAG * 8 and labels[k][1] not in sites:
                # an inline header with an absolute SAG (KHEART6B_OPEN's shape)
                w, h, ax, ay, sag, ctrl = rd(labels[k][0], "<hhhhIH")
                if 0 < w <= 1024 and 0 < h <= 1024 and 1 <= ctrl >> 12 <= 8:
                    same = [n for n in exact("ABS", v) if (records[n]["w"], records[n]["h"]) == (w, h)]
                    readers.append((k, "ABS", v, None if same else v + w * h * (ctrl >> 12)))
                    continue
            if v in abs_starts:
                # anonymous absolute SAGs: BGNDTBL's placement records
                readers.append((k, "ABS", v, None))

    def terminated(i):
        a, e = labels[i][0], end[i]
        n = (e - a) // 8
        if n < 4:
            return n == 0
        if rd32(e - 32) == 0:
            return True
        return n >= 8 and rd32(e - 64) == ANI_JUMP

    parent = {}
    q = deque()
    for i, (a, name, mod, sec) in enumerate(labels):
        if sec in ROOT_SECTIONS:
            parent[i] = None
            q.append(i)
    while q:
        i = q.popleft()
        nxt = set(ptr_edges.get(i, ()))
        mod, sec = labels[i][2], labels[i][3]
        if sec not in ROOT_SECTIONS and i not in records and not terminated(i):
            j = i + 1
            if j < len(labels) and labels[j][2:] == (mod, sec) and j not in records:
                nxt.add(j)
        for j in nxt:
            if j not in parent:
                parent[j] = i
                q.append(j)

    read_by = defaultdict(set)          # record node -> reachable reader nodes
    for node, sp, lo, hi in readers:
        if node not in parent:
            continue
        hits = exact(sp, lo) if hi is None else overlapping(sp, lo, hi)
        for n in hits:
            read_by[n].add(node)

    referrers = defaultdict(set)
    for i, tgts in ptr_edges.items():
        for j in tgts:
            referrers[j].add(i)

    return dict(labels=labels, records=records, parent=parent, end=end, read_by=read_by,
                referrers=referrers, tables=tables, span_end=span_end, readers=readers,
                unresolved_sites=unresolved_sites, orphan_relocs=orphan_relocs,
                relocs=len(relocs))


def classify(g, root):
    packed = packed_names(root)
    member, seqs, unnamed = authored_sequences(packed, root)
    labels, records, parent = g["labels"], g["records"], g["parent"]

    header_live = {labels[i][1].upper() for i in records if i in parent}
    rows = []
    for i, r in records.items():
        name = labels[i][1]
        span = (g["span_end"](r["space"], r["sag"]) - r["sag"]) // 8
        packed_here = name.upper() in packed
        row = dict(label=name, table=g["tables"][(labels[i][2], name)], sag=r["sag"], space=r["space"],
                   bytes=span if packed_here else 0, packed=packed_here, module=labels[i][2])
        others = sorted(labels[j][1] for j in g["read_by"].get(i, ()) if j != i)
        if i in parent:
            row["class"] = "LIVE"
        elif others:
            row["class"] = "WINDOW"
            row["read_by"] = others
        else:
            partial = [f"{img}:{s}" for img, s in member.get(name.upper(), [])
                       if any(f in header_live for f in seqs[(img, s)])]
            if partial:
                row["class"] = "AUTHORED"
                row["sequence"] = partial
            else:
                row["class"] = "DEAD"
                refs = sorted(labels[j][1] for j in g["referrers"].get(i, ()))
                if refs:
                    row["named_by"] = refs
                if member.get(name.upper()):
                    row["unplayed_sequence"] = [f"{img}:{s}" for img, s in member[name.upper()]]
        row["node"] = i
        rows.append(row)
    return rows, unnamed


def path_to(g, i):
    labels, parent = g["labels"], g["parent"]
    chain = []
    while i is not None:
        a, name, mod, sec = labels[i]
        chain.append(f"{name}  ({mod} {sec} {a:08x})")
        i = parent.get(i)
    return list(reversed(chain))


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(REPO), help="tree with src/ (+ mk2.map) and a program ROM")
    ap.add_argument("--work", help="listing dir (default tmp/art_ref_graph/<root name>)")
    ap.add_argument("--assemble", action="store_true", help="(re)build and verify the listings first")
    ap.add_argument("--dead", action="store_true", help="list DEAD records, largest first")
    ap.add_argument("--all", action="store_true", help="with --dead: include unpacked (0-byte) records")
    ap.add_argument("--explain", metavar="LABEL")
    ap.add_argument("--json", metavar="OUT")
    ap.add_argument("--census", metavar="DIR",
                    help="sags.txt files from tools/sag_census.lua under DIR: fail if any "
                         "record the graph does not call LIVE/WINDOW was actually drawn")
    a = ap.parse_args()

    root = Path(a.root).resolve()
    work = Path(a.work) if a.work else REPO / "tmp" / "art_ref_graph" / (
        "current" if root == REPO else root.name)
    if a.assemble or not (work / "VERIFIED").exists():
        assemble(root, work)

    g = build(root, work)
    rows, unnamed = classify(g, root)
    row_of = {r["node"]: r for r in rows}

    if a.explain:
        nodes = [k for k in g["records"] if g["labels"][k][1] == a.explain]
        if not nodes:
            raise SystemExit(f"{a.explain}: not a sprite record in this build")
        if len(nodes) > 1:
            print(f"{a.explain} is defined {len(nodes)} times - each is its own header:")
        for i, r in zip(nodes, (row_of[k] for k in nodes)):
            print(f"{r['label']}  [{r['class']}]  {r['table']}.TBL  SAG {r['sag']:08x}  "
                  f"{r['bytes']:,} B{'' if r['packed'] else ' (not packed)'}")
            if r["class"] == "LIVE":
                print("reached by:")
                for step in path_to(g, i):
                    print("   ", step)
            for key in ("read_by", "sequence", "named_by", "unplayed_sequence"):
                if key in r:
                    print(f"{key.replace('_', ' ')}: {', '.join(r[key])}")
            if r["class"] == "DEAD" and "named_by" not in r:
                print("named by: nothing that the assembler emitted")
        return 0

    counts = defaultdict(lambda: [0, 0])
    for r in rows:
        if r["packed"]:
            counts[r["class"]][0] += 1
            counts[r["class"]][1] += r["bytes"]
    labels = g["labels"]
    print(f"labels {len(labels):,}  records {len(rows):,} "
          f"(packed {sum(1 for r in rows if r['packed']):,})  reachable labels {len(g['parent']):,}")
    for cls in ("LIVE", "WINDOW", "AUTHORED", "DEAD"):
        n, b = counts[cls]
        print(f"  {cls:9s} {n:6,} records  {b:10,} B")
    print(f"authored sequences with no IMG frame names (not checked): {unnamed}")
    print(f"integrity: {g['relocs']:,} relocated fields, {g['orphan_relocs']} outside any label"
          f"{'' if not g['orphan_relocs'] else '  <-- PARSER GAP: labels are missing, DEAD is unsafe'}; "
          f"hand-carried headers unresolved: {len(g['unresolved_sites'])}"
          f"{' ' + ', '.join(g['unresolved_sites']) if g['unresolved_sites'] else ''}")

    if a.dead:
        dead = [r for r in rows if r["class"] == "DEAD" and (r["packed"] or a.all)]
        dead.sort(key=lambda r: (-r["bytes"], r["label"]))
        print(f"\n{'record':22s} {'table':10s} {'bytes':>7s}  reason")
        for r in dead:
            why = ("named only by unreachable " + ", ".join(r["named_by"][:3])
                   if "named_by" in r else "named by nothing emitted")
            if "unplayed_sequence" in r:
                why += f"; unplayed sequence {', '.join(r['unplayed_sequence'][:2])}"
            print(f"{r['label']:22s} {r['table']:10s} {r['bytes']:7,}  {why}")

    if a.json:
        Path(a.json).write_text(json.dumps(rows, indent=1))
        print(f"wrote {a.json}")

    if a.census:
        drawn, scenes = {}, 0
        for f in sorted(Path(a.census).rglob("sags.txt")):
            scenes += 1
            for ln in f.open():
                if ln.startswith("#") or not ln.strip():
                    continue
                s, c = ln.split()
                drawn.setdefault(int(s, 16), set()).add(f.parent.name)
        live_abs = [r for r in rows if r["space"] == "ABS" and r["class"] in ("LIVE", "WINDOW") and r["packed"]]
        seen_live = sum(1 for r in live_abs if r["sag"] in drawn)
        print(f"\ncensus: {scenes} scenes, {len(drawn):,} distinct SAGs drawn; "
              f"{seen_live:,} of {len(live_abs):,} packed absolute LIVE/WINDOW records were seen")
        bad = []
        for r in rows:
            if r["class"] in ("LIVE", "WINDOW") or r["sag"] not in drawn:
                continue
            where = sorted(drawn[r["sag"]])
            if r["space"] == "ABS":
                bad.append((r, where, "drawn"))
            else:
                # a relative SAG is only unique inside its bank: report, don't fail
                print(f"  review  {r['label']} ({r['table']}, {r['class']}, relative {r['space']}) "
                      f"value {r['sag']:08x} was drawn in {', '.join(where[:3])} - may be another bank's art")
        for r, where, _ in bad:
            print(f"  DRAWN BUT {r['class']}: {r['label']} ({r['table']}) SAG {r['sag']:08x} "
                  f"in {', '.join(where[:4])}")
        if bad:
            print(f"census FAIL: {len(bad)} record(s) the graph rules out were drawn - the graph is wrong")
            return 1
        print("census PASS: nothing the graph rules out was drawn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
