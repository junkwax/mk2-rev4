# Naming Conventions

| Kind | Pattern | Example | Notes |
| --- | --- | --- | --- |
| Playable stage/background wrapper | short stage name | `KFPITPL.LOD` | Fixed video-ROM pool for one stage/BGND payload |
| Move/fatality wrapper | move pool name | `MOVEART1.LOD`, `MOVEART2.LOD`, `RDMOVE.LOD` | Keep live move/fatality additions adjacent in video ROM |
| Stage/generated table | `<stage>.TBL` | `KFPITPL.TBL` | Generated background headers for the wrapper |
| Runtime display name | player-facing stage name | `MK1 PIT` | Keep strings compact for MKSEL |

Current live stage wrapper:

| LOD | Runtime name | Notes |
| --- | --- | --- |
| `KFPITPL.LOD` | `MK1 PIT` | MK1PIT background wrapper, loaded in the normal BGND table path |