# Art reference graph: which sprite records can the game draw?

Row 28 of [GRAPHICS_OPPORTUNITIES.md](../GRAPHICS_OPPORTUNITIES.md) said *"a
complete reference graph is still absent"*. Every dead-art prune before this
was a hand audit: four checks per record (retail source, frame lists, inline
decode windows, authored IMG sequences), done by reading. `tools/art_ref_graph.py`
does it mechanically, and `tools/sag_census.lua` checks it against what the
game actually draws.

```
python tools/art_ref_graph.py --assemble        # listings for this tree (~25 s)
python tools/art_ref_graph.py --dead            # candidates, largest first
python tools/art_ref_graph.py --explain KHEART1 # class, reason, path from code
python tools/art_ref_graph.py --root <tree>     # any build with src/ + a ROM
python tools/art_ref_graph.py --census <dir>    # fail if a ruled-out record was drawn
```

## Result on the installed build

| Class | Records | Bytes | Meaning |
|---|---:|---:|---|
| LIVE | 9,824 | 11,452,331 | its header is reachable from code |
| WINDOW | 18 | 7,665 | its header is not, but another live header reads its pixels |
| AUTHORED | 16 | 9,964 | an undrawn frame of an IMG sequence whose other frames are drawn |
| DEAD | 42 | 59,551 | none of the above |

The four classes add up to 11.53 MB, which matches the packed video ROM
(`build_report.py`: 12 MB less 508,506 B free).

**Of the 42 DEAD records, almost all were already known:**

| Bytes | Records | What they are |
|---:|---:|---|
| 41,470 | 8 | Staged SAHELI2/3 art, kept by policy ([DEAD_ART_PRUNE.md](DEAD_ART_PRUNE.md)) |
| 14,067 | 11 | Staged LKDUBLKN (Liu Kang's double knee), kept by policy |
| 1,238 | 5 | Copyright and test art (`mk2copyrgt`, `thisver`, `passed`, `failed`, `thesectest`), kept by policy |
| 399 | 1 | `pitblood1b`, already documented as unreferenced ([BLEED_SCAN.md](BLEED_SCAN.md)) |
| 36 | 1 | A stray duplicate `FONT7A` header at the top of MKHH.TBL (SAG 0); the real glyph in MKTEXT.TBL is live |
| **2,341** | **16** | **New, not yet reviewed:** `NJBABE`, `versus`, `RNVICBOLT1A`, `RNSHORTBOLT1A`, `BONE3_SPIT1-5`, `MKMEDAL2`, `GOROTOST`, `MK2FONTat`, `SPRAYGLOB1`, `linebreak_`, `boonpic_a`, `tornado7C` |

So the three hand passes left about **2.4 KB** behind. The third pass started
from 602 "unnamed" labels and checked them by hand; the graph reduces that to
42, each with a reason. **Nothing has been removed** - the 16 new records need
the usual sign-off, and `DEAD` is a candidate, not a verdict.

## How it works

### Addresses: the build keeps no label table

`mk2.out` is stripped (`nsyms 0`), objects keep only globals, and the link map
lists about 2,600 globals against about 10,000 table labels. So only 186 of
10,136 table labels had an address anywhere. `MAKE.INI` assembles without `-L`, so
there are no listings either (the `src/*.LST` files in the tree are weeks old).

`--assemble` copies `src/` to `tmp/art_ref_graph/<tree>/`, turns
`.include x.tbl/.asm` into `.copy` (the same code; TI's assembler lists only
`.copy`d files), and runs `GSPA -H -L -v10` on all 75 MAKEFILE modules in
DOSBox. Nothing shared is touched and nothing is linked. It then **proves the
scratch assembly is the build**: every module's section sizes must equal the
map's input sections, and every section's raw bytes must equal the tree's own
`.OBJ` (75 modules, 229 sections, all identical). A label's address is the
map origin of its module's section plus its listing offset. Checked against
the ROM directly: the address computed for `KHEART6B` holds w=14 h=18 anix=21
aniy=-19 SAG `039ca3bc` ctrl `4080`.

### Edges

- **Pointers are relocated fields only.** A real pointer, to a local label, an
  external or `label+offset`, needs a relocation entry because the section
  base is unknown until link. A constant never has one. The first version
  matched any 32-bit value equal to a label address. That made records
  "reachable" through header fields (anix 16 / aniy -42 spells `0xffd60010`) and
  ani commands (`adjustxy 0,-42`), and which coincidences existed changed with
  every build. Relocations (10-byte COFF entries) remove them exactly.
- **Pixel reads.** Every table record reads its own image. The 22 hand-carried
  headers read from the record and bit offset `tools/sync_inline_sags.py`
  anchors them to, for `w*h*bpp` bits when the offset or size differs. This is
  how `SZBABE`/`RPBABE`/`SCBABE` at `ROTATE9F+614` keep `ROTATE10B/C` alive
  mechanically. Inline headers with absolute SAGs (`KHEART6B_OPEN`) and
  anonymous absolute SAGs (BGNDTBL's placement records) read exactly.
- **Relative SAGs.** Fighter tables store SAGs relative to their LOD's bank.
  `TMSTANCE1A` is `0120H`, and the DMA's offset register supplies the base. So
  pixel spans are compared within one LOD, and absolute SAGs are compared
  globally.

### Reachability

Roots are every label in `.text` plus VECTORS, FLOORORG and SHADORG. That is
conservative: dead code keeps its art alive. A reachable data label falls
through into the next unless it ends in a `0` long or `ani_jump, target`, because
MK2 lanes are pointer lists that stop there. Nothing falls through *into* a
sprite header. Every mistake in this design makes art look live, never dead.

### Integrity line

Every run prints how many relocated fields sit outside any known label. It must
be 0: anything else means labels are missing and a DEAD verdict is unsafe.
This check exists because of a bug it would have caught. The parser first
treated `.bss name,size` as a section switch. In TI's assembler it only
reserves space and stays in the current section, so every label after an
inline `.bss` line was dropped. That dropped all of MKDISP's code, and with it
the pointers to the health-bar names, win digits and toast icons, which then
showed as DEAD.

## Validation

**Known cases** (current build), every one matching the hand audits:

| Record | Class | Reason given |
|---|---|---|
| `KHEART2` ... `KHEART6D` | LIVE | (drawn in MAME on 2026-09-16, 9/9 SAGs and depths) |
| `KHEART1` | AUTHORED | MK1BLOOD `HEART1` sequence, the third pass's keep reason |
| `AUTOGRAPH7` | AUTHORED | CAGE9 sequence |
| `RN1DETHBOLT1A` | WINDOW | read by `KLUDGE_RN1DETHBOLT1A` |
| `LILSTONE1`, `LILSTONE5` | WINDOW | read by `KAHNLIL1`, `LILSTONE5_MIRROR` |
| `ROTATE10B`, `ROTATE10C` | WINDOW | read by `SZBABE`, `RPBABE`, `SCBABE`, the ROTATE preservation incident |

**Retrospective, on the build before the third prune.** Commit `337b710`,
linked in an isolated git worktree and verified identical section by section:
- **28 of 28** records removed with sign-off classify DEAD;
- all 7 records the hand check kept classify as the doc explains;
- between that build and today, the **only** record whose class changed is
  `NJDECAPTORSO6` (DEAD -> LIVE), which is the ninja torso fix, the one deliberate
  code change in between. The DEAD totals reconcile exactly: 71 records then,
  42 now, a difference of 28 removals plus the torso.

**Runtime census** (`tools/sag_census.lua`). The census write-taps the DMA's
`dmasagl`/`dmasagh` and commits the SAG on each `dmactrl` write, so every blit
counts: objects, background blocks, floors, HUD. It ran over 32 scenes on the
installed ROM: attract, buy-in/continue, two full Kahn ladders, Cage's headhole
fatality, and 27 battles across every stage. That is 78,891 distinct SAGs
drawn, and **no record the graph rules out was among them** (`--census` PASS).
Positive controls for a Liu Kang vs Jax fight (`BAR_KANG`, `BAR_JAX`,
`SHADNUM0`, `LKSTANCE1A`) were all seen. Coverage is honest, not exhaustive:
those scenes drew 2,072 of the 5,984 packed absolute live records (35%).

## Limits

- Art reached by **arithmetic from a base header** (base + n x header size) is
  invisible to a static model. The census is the guard against that, and no
  instance appeared.
- AUTHORED depends on IMG frame names. One authored sequence has none and is
  not checked.
- `--root` for another build needs its full `src/` (to assemble), its map, and
  a program ROM (`rom/mk2_flat.bin` or `mk2.zip`). The frozen `tmp/flip_head/*`
  roots keep only tables and maps, so they cannot be analysed.
