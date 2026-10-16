# Raiden's electricity is coloured by his costume

*Written for: whoever next repaints Raiden, or touches an electrocution.*

Three things change colour with the costume Raiden is wearing, and they have to
agree with each other:

1. **The lightning itself** — the bolt art, his teleport decoy, his beam-up,
   his victory bolts, both fatalities' bolts.
2. **The flash on the man it hits** — the victim's own sprite, repainted, on
   both body beats of the electrocution cycle.
3. **The crackle over his own body** — the ambient `RN*BOLT` flash that runs
   over him while he stands.

| Raiden's costume | lane | his lightning | ELEC beat | FREZ beat |
|---|---|---|---|---|
| `RDMAIN_P` | default, Start+BLOCK, Start+COIN | `ELEC_P` | `<XX>ELEC_P` (blue) | `<XX>FREZ_P` (cyan) |
| `RDALT1_P` | Start + HIGH PUNCH | `ELECRED_P` | `<XX>ELRED_P` (red) | `<XX>REDEL_P` (red) |
| `RDALT2_P` | Start + LOW PUNCH, and the mirror | `ELECPRL_P` | `<XX>ELPUR_P` (purple) | `<XX>PURPL_P` (purple) |
| `RDALT3_P` | Start + HIGH KICK | `ELECPRL_P` | `<XX>ELPUR_P` | `<XX>PURPL_P` |
| `RDALT4_P` | Start + LOW KICK | `ELECPRL_P` | `<XX>ELPUR_P` | `<XX>PURPL_P` |

`<XX>` is the **victim**, not Raiden — the flash is his own body's colours
swapped, so every fighter has his own copy of each of the three.

**Both body beats take the colour** (2026-09-28, the user's). The cycle is FREZ,
ELEC, WHITE, BLACK and only the two solid flashes have no body in them, so there
are two palettes per lane to get right — `player_shock_pal` / `shock_elec_tabs`
for ELEC and `player_shock_frez_pal` / `shock_frez_tabs` for FREZ, both indexed
by the same `shock_elec_colour`. Until that change the FREZ beat was the cyan
frozen set whatever colour the bolt was, so a purple electrocution alternated
purple and **cyan** and read as two effects at once.

**Midway drew that beat in three colours too and wired only the cyan one.** The
18 `<XX>PURPL_P` / `<XX>REDEL_P` records were already in `data/ALLDUDES.IMG`,
named by nothing in retail or in this tree — the same discovery as the ELEC reds
and purples, one beat along.

## The crackle over his own body

The ambient flash (`RN*BOLT`, `data/RADBOLT1.IMG`, six styles, 102 pieces, one
every 16–47 ticks while he stands) is **painted against the COSTUME layout**,
not against a bolt palette: `ELEC_P` has 53 entries and the art indexes 63, so a
bolt palette would read past its end as CRAM garbage. The flash object is
therefore retinted with a *costume* palette, and its hue is one slot of it.

**Which slot is measured, not assumed.**
`tools/make_raiden_crackle_palettes.py` decodes all 102 pieces out of the built
video ROM every run:

| index | pixels | share | what it is |
|---|---|---|---|
| 0 | 22,809 | — | transparent |
| 24 | 3,437 | 36% | `(31,31,31)` the white arc core |
| 48–57 | ~440 | 4% | a grey ramp — the fringe (faintly teal on ALT4) |
| **63** | **5,742** | **60%** | **the colour** |

So one slot carries the hue — and `MKGUYS.ASM`'s old comment naming `[62]` and
`[63]` was wrong: **62 is not drawn at all.** (The first cut of the tool decoded
the art without honouring the per-row lead/trail skip bytes of a compressed
record, and that garbage *also* looked like a histogram — it picked slot 15. The
decoder mirrors `tools/extract_bolt_paths.py`.)

**It was the same blue in all five costumes**, which is the whole defect: a red
Raiden threw red lightning, fried the other man red — and crackled `(1,15,31)`
blue. `data/MK2PALS.IMG` authored one crackle blue for every Raiden palette.

**Midway's own Raiden costumes disagree, and they are still in the tree.** Every
palette `raiden_costume_pal` used to name outright differs from the others in
slot 63 and **nowhere else the crackle draws**:

| palette | slot 63 | |
|---|---|---|
| `RADBLU_P` | (6,25,31) | blue |
| `RADALT_P`, `RADWHI_P` | (9,1,31) | violet |
| `RADALT2_P` | (3,0,31) | violet |
| `RADALT4_P` | **(18,5,31)** | **purple** |
| `RADRED_P` | **(31,3,1)** | **red** |

The crackle colour was always per-costume; it was lost when
`make_costume_palettes.py` repointed `character_palettes_1..7` at MK2PALS.IMG. So
the two new colours are **lifted, not invented** — `RADRED_P`'s slot 63 for the
red lane, `RADALT4_P`'s for the purple ones — and each matches the hue of the
bolt palette it is paired with (`ELECRED_P` is R=31 dominant; `ELECPRL_P` is R
above G with B high).

`raiden_crackle_pal` (MKGUYS.ASM) resolves the lane into `raiden_crackle_offer`,
a fourth table parallel to `costume_offer`, `raiden_elec_offer` and
`shock_elec_colours`. **The blue rows name the costume palette itself**, so a
repaint in IMGTOOL still moves them; only the four that have to differ are
generated, into `src/RDCRACK.ASM`, each a **copy** of its own costume with that
one slot replaced — so the white core and that costume's grey fringe are
untouched, and the crackle keeps its shading. 520 bytes.

Authoring a per-costume crackle in IMGTOOL instead is perfectly legitimate: the
tool *prints* slot 63 across the five costumes rather than asserting they are
equal, so the day MK2PALS carries five different crackle colours, that shows up
in the report.

### The FREZ beat is a different roster from the ELEC one

Two rows differ, and a hand-typed expectation gets both wrong:

* **Raiden fries as `RD` and freezes as `RN`.** His ELEC flash is `RDELEC_P`;
  his FREZ one is `RNFREZ_P` / `RNREDEL_P` / `RNPURPL_P`.
* **Kintaro's frozen palette is `gorof_p`**, a symbol with no `<XX>` in it.
* Neither boss body was drawn in red or purple for this beat, so Kintaro and
  Shao Kahn keep `gorof_p` / `BGFREZ_P` on all three — the same shape as the ELEC
  red table's `BGELEC_P` fallback.
* Four of the blue FREZ symbols are carried in MKGUYS under a name the library
  does not have: its `LKFREZ_P` is `ALLDUDES.IMG`'s **`LKFREZ1_P`**, and the same
  for KT, ST, NJ and JX. `FREZ_SOURCE` in the tool records which record each one
  really is, so the check compares **words, not names**.
* The whole blue FREZ set is now `.globl` (MKGUYS.ASM), the way the blue ELEC set
  already was in IMGPAL3: the fallbacks have to be nameable from SHOCKPAL.ASM,
  and `tools/raiden_elec_expect.py` reads the beat's palettes out of
  `src/MK2.MAP`, so a file-local symbol could not be checked at runtime at all.

### The pairing is proved by CONTENT, not by the name

`make_shock_palettes.py --check` requires each `PURPL` / `REDEL` record to be the
**same drawing** as the `FREZ` record it stands in for: identical brightest
channel in all 64 slots, which a re-hue preserves and an unrelated palette of the
same size does not. Then it requires the hue to point the right way — red's mean
R above both others, purple's mean B above its G. Measured 2026-09-28: **18 of 18
records, 64 of 64 slots.**

The same test on the ELEC family is only **45/64 and 47/64** for `TMELRED_P` and
`LKELRED_P` — those two were redrawn rather than re-hued — so it is *reported*
there and *required* for FREZ.

## Where the colours live, and who carries them

| palettes | library | carried into | by |
|---|---|---|---|
| `ELEC_P`, `ELECRED_P`, `ELECPRL_P` | `data/MK2PALS.IMG` | `src/IMGPAL4.ASM` | `tools/sync_raiden_elec_palettes.py` |
| `<XX>ELEC_P` (10, blue) | `data/ALLDUDES.IMG` | `src/IMGPAL3.ASM` | checked by `tools/make_shock_palettes.py` |
| `<XX>ELRED_P` (9), `<XX>ELPUR_P` (10) | `data/ALLDUDES.IMG` | `src/SHOCKPAL.ASM` | `tools/make_shock_palettes.py --apply` |
| `<XX>FREZ_P` (10, cyan) + `gorof_p` | `data/ALLDUDES.IMG` | `src/MKGUYS.ASM` (words) | checked by `tools/make_shock_palettes.py` |
| `<XX>REDEL_P` (9), `<XX>PURPL_P` (9) | `data/ALLDUDES.IMG` | `src/SHOCKPAL.ASM` | `tools/make_shock_palettes.py --apply` |
| the crackle's slot 63, red + purple | `RADRED_P` / `RADALT4_P`, still linked | `src/RDCRACK.ASM` | `tools/make_raiden_crackle_palettes.py --apply` |

Both tools run `--check` in Phase D. **Nothing promotes an IMG palette into the
ROM** — `IMGPAL*.ASM` is hand-maintained, and neither library is in a LOD, so
LOAD2 never reads them and no pixel of either reaches a video ROM. A recolour in
IMGTOOL that was never carried would ship the old colours with the build still
green. That is the whole reason the gates exist.

So a repaint is: **edit in IMGTOOL, re-run the tool, rebuild.**

### Two names that look like typos and are not

* Liu Kang's purple is **`LKELPUP_P`**, not `LKELPUR_P`. The record in
  `ALLDUDES.IMG` is spelled that way; the library is the authority.
* **There is no `BGELRED_P`.** `BG` is the boss body (Kintaro, Shao Kahn) and it
  has a blue and a purple but no red, so the red table falls those two rows back
  to `BGELEC_P`.
* `ELECPRL_P` is **not** `RAID8.IMG`'s `ELECPUR_P` under another name — 51 of
  their 53 entries differ. `ELECPRL_P` exists only in `data/MK2PALS.IMG`.

## The lane is RESOLVED, not read off `oflags2`

`raiden_pal_lane` (MKGUYS.ASM) turns `oflags2` into a lane index in
`costume_offer` order, and then hands it to **`costume_lane_shift`** — the same
routine `costume_pal_a0` and `blood_pal_a0` use.

That last step is load-bearing. `oflags2` holds the lane Raiden **claimed**, and
`costnodup` (MAINEQU.ASM) can roll player 2 forward off it, so a man wearing the
*next* costume along would otherwise have thrown the *previous* costume's
lightning. `blood_pal_a0` carries the identical fix for gore, for the identical
reason.

Three tables hang off that one index, all parallel to `costume_offer` — same
lanes, same order, `.if costcoin` on the same row:

```
costume_offer        the costume         character_palettes_N
raiden_elec_offer    his lightning       ELEC_P / ELECRED_P / ELECPRL_P
shock_elec_colours   the victim's flash  0 blue / 1 red / 2 purple
```

A colour index then picks one of `shock_elec_tabs`' three twenty-row tables, and
the **victim's** ochar picks the row.

`shock_elec_colour` runs on the **victim**, so finding Raiden is its whole job:
he is either the man himself (`raiden_victory` flashes Raiden with his own shock
palette) or the man opposite — every electrocution takes the victim over from
Raiden's process, so `p_otherguy` on the victim *is* Raiden. **Anybody else
electrocuting keeps the blue set**: Rain's lightning fatality runs the same four
beats, and reading a lane off *Rain's* `oflags2` would have coloured his victim
by Rain's costume, a pairing nobody authored.

## `raiden_costume_pal` was reading palettes Raiden does not wear

The ambient body crackle (`lightning`, MKGUYS.ASM) draws `RN*BOLT` art against
the **costume** layout — `[62]` is its inner electric colour and `[63]` its
outer one — so it asks for the costume palette, not the ELEC family.

It used to name `RADBLU_P` / `RADALT_P` / `RADALT2_P` / `RADALT4_P` / `RADWHI_P`
/ `RADRED_P` / `DRKRAID_P` outright, and those stopped being what he wears when
`tools/make_costume_palettes.py` repointed `character_palettes_1..7` at
`data/MK2PALS.IMG`. Measured drift at the time:

| lane | old symbol | now wears | entries differing |
|---|---|---|---|
| default | `RADBLU_P` | `KP_RDMAIN_P` | **2 of 64 — and both were `[62]` and `[63]`** |
| Start+HP | `RADALT_P` | `KP_RDALT1_P` | 19 |
| Start+LP | `RADALT2_P` | `KP_RDALT2_P` | 20 |
| Start+HK | `RADRED_P` | `KP_RDALT3_P` | 19 |
| Start+LK | `RADALT4_P` | `KP_RDALT4_P` | 45 |

On his default costume the *only* two entries that had drifted were the two the
crackle draws in. It now resolves the lane like everything else, so a repaint in
IMGTOOL moves the crackle with it.

## Every electrocution runs the same four beats

`shockcyc` (MAINEQU.ASM) describes the cycle — **FREZ, ELEC, WHITE, BLACK** —
and there is now one table and one stepper for it, `shock_cycle_pals` /
`shock_next_beat` (MKGUYS.ASM). Six call sites:

| site | what it is | before |
|---|---|---|
| `shocker_shaker` (MOVES.ASM) | the electrocute grab, and `do_raiden_fry` through it | four beats, with the phase and table inline |
| `lightning_stumble` (MKREACT.ASM) | the victim of his lightning bolt | **ELEC against his own colours** |
| `raiden_bolt_shock_victim` (MKDEATH.ASM) | his bolt fatality's held victim | **ELEC against his own colours** |
| `rd_lifted_victim` (MKDEATH.ASM) | his lift fatality's victim, while he cooks | **ELEC against his own colours** |
| `rnf_victim` (MKRAINF.ASM) | RAIN's lightning fatality | four beats, off a **second copy** of the table |
| `rvic6` (MKCANNED.ASM) | Raiden's victory charge-up, on **himself** | **ELEC against his own colours** |

So the same current used to read as two different effects depending on how it
was delivered, and a recolour of the cycle could reach one copy and miss the
other.

`shock_next_beat` **hands back the routine rather than calling it**, because the
two kinds of caller reach the victim differently: his own process calls it
outright, while Raiden's process goes through `zappal_change` (MOVES.ASM), which
swaps `a8`/`a13` for the call. The phase (`shock_cyc`) is **global, not
per-process**, so a sequence that hands the man from one routine to another
keeps stepping instead of restarting on FREZ each time — which is what
`do_raiden_fry`'s one-pass `shocker_shaker` calls have always relied on. Only
one man is ever being electrocuted.

`shockcyc 0` is retail's two-beat flicker. **The mask and the table are all that
change** — no call site knows which it is, so the switch is a true revert
everywhere at once.

`rvic6` (MKCANNED.ASM) — Raiden flashing *himself* in his victory pose — is on
the cycle too (the user's call). It is the one site where the man wearing the
current **is Raiden**, which is why `shock_elec_colour` reads the object's own
`ochar` before it looks at `p_otherguy`: a red Raiden crackles red, in his own
body's `RDELRED_P`.

**The twelve beats and the 96 ticks are exactly what that loop always ran** —
two beats a pass, one per 4 ticks — so only what they paint has changed.

**And he has to be dressed again afterwards.** The old loop *ended* on
`player_normpal`, so it left him in his costume. Twelve beats of a four-beat
cycle end on **BLACK**, which would hold him as a solid black silhouette in his
victory pose for the rest of the match. `local_wait_forever` is the only way out
of `raiden_victory`, so one `calla player_normpal` after the `dsj` covers it —
and `-Mode victory` in the rig exists to keep it covered.

## Rig

```
powershell -File tools/run_raiden_elec_test.ps1 -Mode costume -Lane all   # 6/6
powershell -File tools/run_raiden_elec_test.ps1 -Mode cycle   -Lane all   # 6/6
powershell -File tools/run_raiden_elec_test.ps1 -Mode victory -Lane all   # 6/6
powershell -File tools/run_raiden_elec_test.ps1 -Mode crackle -Lane all
powershell -File tools/run_raiden_elec_test.ps1 -Mode cycle -Lane 1 -Negative
```

`-Mode crackle` stands him in his stance and presses **nothing** — the ambient
flash is gated on him standing — then requires the flash object to be retinted
with that lane's crackle palette and no other.

**The blue lanes are judged two ways at once**, because their crackle palette
*is* his costume palette and his body is already wearing it: no `RDCRK_*` may be
allocated, **and** the costume palette's own refcount has to rise above its
resting value — the flash object's `getfpal` taking a second reference on it.
Without that second test, a lane where the flash never fired would pass for free.

**That refcount is also what tells a failure from an unmeasured run.** A coloured
lane that allocates no `RDCRK_*` looks the same whether the flash drew in the
costume palette (the old behaviour — a real failure) or never fired at all (no
verdict). The rise settles it: risen → **FAIL**, "it drew in that costume palette
itself"; not risen → **NO VERDICT**. Measured on the first cut of the mode: the
crossed blue lane returned NO VERDICT and so could not have caught the
regression it exists for.

Measured 2026-09-28: **6/6** lanes — `RDCRK_ALT1_P` on Start+HP, `RDCRK_ALT2/3/4_P`
on LP/HK/LK, and the default and Start+Block on `KP_RDMAIN_P` with its refcount
going 1 → 2. Both crossed controls FAIL, the coloured one on the wrong palette
being allocated and the blue one on the flash having demonstrably fired in the
costume palette.

`-Mode costume` teleports him and requires the decoy's palette to be the paired
one, **with neither other electric palette on screen**. `-Mode cycle` zaps the
other man and requires four distinct palettes — the solid white and black
flashes among them — and **both body beats** to be *his* body's copy of Raiden's
colour: the ELEC one and the FREZ one. `-Mode victory` wins the match and
requires the same of **Raiden's own** body, by name — `RDELEC_P` / `RDELRED_P` /
`RDELPUR_P` for ELEC and `RNFREZ_P` / `RNREDEL_P` / `RNPURPL_P` for FREZ (the
`RN` row, not `RD`) — and that he **ends in his costume**. `-Negative` asks each
lane for another lane's answer with the ROM untouched, and every trial must FAIL.

**The palette COUNT proves nothing about the FREZ beat, which is why it is
asserted by name.** The pre-2026-09-28 wiring drew that beat in the cyan frozen
set under a purple bolt, and that is *also* four distinct palettes, with both
solid flashes and the right ELEC beat — every other test in the mode passes on
it. `JXFREZ_P` appearing on a red or purple lane **is** the regression.

Measured 2026-09-28 on the build with both beats wired: costume 6/6, cycle 6/6
(`JXFREZ_P` on lanes 0 and 5, `JXREDEL_P` on 1, `JXPURPL_P` on 2/3/4), victory
6/6 (`RNFREZ_P` / `RNREDEL_P` / `RNPURPL_P` respectively, each ending dressed),
and the crossed controls fail in both body modes as they must.

Palette identity comes from **`palram`**, the allocator's own table: an object's
`opal` names a colour MAP, and `palram[map]` holds the palette's ROM address. The
rig therefore reads what the DMA is drawing with *by name*. Rows are believed
only while `palcnt` is non-zero — `freepal` leaves the id behind, so a stale row
would read as an electric palette that is no longer on screen.

### Four traps the rig hit, in order

* **It identifies the costume before it judges the bolt.** The lane is claimed by
  writing `@alt_pal_owner`; a claim that did not land leaves him on his default,
  whose partner is `ELEC_P`. A rig that only watched the bolt would report a
  green run for four lanes it never reached. A disagreement is therefore
  **NO VERDICT**, not a pass and not a failure of the ROM.
* **`rd_hp_open` is not a plain High Punch.** It hangs off `switch_open_jumps`,
  so the electrocute grab needs an opponent who is already *open*. A rig pressing
  HP at a standing man gets nothing.
* **`do_short_lightning` is a SHORT zap.** At round-start distance the bolt comes
  out, `ELEC_P` reaches a colour map, and the victim never changes palette. The
  victim has to be pinned inside range — **every frame** until it lands, because
  repell pushes them apart the moment they overlap.
* **The stick decides which move HP is.** `rdhp_normal` tests `is_stick_away`
  first, so Back must be *held* or the press is an uppercut.
* **Pinning the victim's bar to 1 every frame stops the round ever ending.**
  `bar_reducer` empties it and the next frame puts it back, so the rig sits in
  one fight forever — measured: 1800 frames, one palette, "he never won the
  match". Write it only while it is **above** 1.
* **A sampler nested under `gs == GS_FIGHT` cannot watch a victory.** Winning a
  round takes the game out of GS_FIGHT for the banner and the next round's
  intro, so the sampler stops for hundreds of frames and its deadline never
  fires — the run ends on the outer timeout with nothing measured. `-Mode
  victory` counts real frames from `fight` instead.
* **Solid white and solid black are not proof on their own.** `rvic_fade` calls
  `raiden_dimmer`, and a full dim takes his palette to zero — so "a solid black
  frame happened" is true of a build with no cycle at all. The victory verdict
  turns on `RDELEC_P` / `RDELRED_P` / `RDELPUR_P` reaching his object **by
  name**, which only `player_shock_pal` does.
