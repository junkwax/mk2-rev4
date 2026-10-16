# MK1PIT / KFPITPL Background Spec

`KFPITPL` is the live MK1PIT background wrapper. It is built as a standalone BBB/background LOD and loaded through the normal BGND table path at stage slot `0x0A`.

## Live Files

- `data/KFPITPL.LOD`
- `data/KFPITPL.BDB`
- `data/KFPITPL.BDD`
- `src/KFPITBG.ASM`
- `src/KFPITPL.TBL`

## Placement

- LOAD2 address: `0x05D58000`
- Flat video slot: `0x7AB000..0x7B7FFF`
- Current payload end: `0x7B5848`
- Current slot growth room: 10,168 bytes

The final unallocated bank-0 tail starts at `0x7B8000`; keep that space free for deliberate future content unless the fixed-slot policy is updated.

## Build Ownership

- `data/IMGBUILD.BAT` runs `KFPITPL` after `MK8MIL` and before the move-art wrappers.
- `tools/refresh_kfpitbg.py` regenerates `src/KFPITBG.ASM` from `tmp/load2/BGNDTBL.KFP`.
- `makevrom.py` enforces the `KFPITPL.IRW` fixed slot.
- `MKSEL.ASM` displays the stage as `MK1 PIT`.

## Validation

Run:

```powershell
python build.py --asm-only
python makerom.py
python makevrom.py --debug-bin
python mamerom.py --no-install
```

For the no-LOAD2 promoted path, refresh `mk2asset` promotion and proof reports from the sibling `mk2asset` repo.