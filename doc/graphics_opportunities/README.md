# Graphics opportunity measurements

Companion data for [GRAPHICS_OPPORTUNITIES.md](../GRAPHICS_OPPORTUNITIES.md).
The research changes no runtime code or ROM payloads.

`audit_snapshot.py` reads current active IRWs and source TBLs, then overwrites
`snapshot.json` and `sprite_screening.csv` in this directory. It uses only
Python's standard library and existing repository parser/packer modules.
The script locates the repository relative to itself; it does not run LOAD2,
assemble, package ROMs, or alter IMG/LOD/TBL files.

```powershell
python doc/graphics_opportunities/audit_snapshot.py
```

The JSON identifies input files with SHA-256, records active-payload gaps,
parser exclusions, exact indexed-image duplicate groups, table screening
totals, and authored-image comparisons for BLDXPD/NOOBPORT. The CSV gives
one record per decoded SAG, including dimensions, source, control-derived
depth/compression, stored pixels, color-index counts and both savings models.

Interpretation rules:

- SAG values are **bit offsets** into flat image-ROM space. Header bases
  require separate bank/CPU-window conversion, using the active packer.
- `shadow_table_heuristic` is inherited from `tools/audit_sprite_bpp.py`.
  A zero is **not** proof that an image is safe to repack. New body tables
  and mixed body/effect tables are known counterexamples.
- `screening_saved_no_remap` keeps actual indices. The per-frame remap column
  assumes a compact independent index set including transparent zero; it does
  not prove shared-palette or animation-wide compatibility. Do not add them.
- Bpp savings use existing stored-pixel counts and floor per-frame bit
  differences to bytes. Compression decisions and alignment can change on
  rebuild. The hypothetical one-bit minimum for a completely zero frame is
  an analytical minimum, not a promise about LOAD2's auto-depth branch.
- Duplicate groups require identical dimensions and full decoded index
  arrays at different SAGs. Palettes, anchors, bank accessibility, live
  references and control-word compatibility must still be reviewed. The
  redundant extent total keeps a largest encoding per group and floors the
  remaining group bit count to bytes; it is a candidate extent calculation,
  not an optimal repacked allocation. It overlaps the bpp candidates.
- The 36 authored checks compare the existing packed result with source IMG
  indices. They validate neither a proposed lower-bpp rebuild nor runtime
  object control/palette behavior.
- The parser omits nonstandard/BLIMP layouts and excludes conflicts and
  decode failures. These records are not evidence of dead assets. Successful
  decoding also does not prove the current binary links and uses a header.
- Physical gaps can be reserved capacity inside existing wrappers. This
  inventory grants no allocation rights; use the asset-space ledger.
- The source tree is live. Hashes identify what was read, but this is not an
  atomic snapshot of a concurrent build. Re-run after an asset change and
  compare the active build's table/payload hashes before implementation.

`external_sources.json` records primary source URLs and the downloaded
reference-file hashes used for the research. Those downloads are research
scratch under `tmp/graphics_research`, not required to run the inventory.
