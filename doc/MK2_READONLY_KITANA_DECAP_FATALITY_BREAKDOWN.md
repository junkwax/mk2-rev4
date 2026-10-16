# MK2 Readonly Kitana Fan-Decap Fatality Breakdown

This is a source-level reference for the stock Kitana fan-decap fatality in
`../mk2-readonly/mk2-main`. It explains every runtime lane and asset contract
needed to animate a fatality in MK2, using a known-good stock implementation.

It is not a recipe to copy wholesale into Johnny Cage's headhole fatality.
Kitana's move deliberately detaches the victim's head and starts the generic
decap blood burst twice. Cage's headhole design keeps the head attached, so it
should reuse the ownership and timing patterns while omitting those decap-only
lanes.

For the cross-fatality reference—what is actually shared by stock MK2 versus
what is intentionally different per fatality—read
`doc/MK2_READONLY_FATALITY_COMMON_CONTRACT.md`. `mk2-readonly/mk2-main` is the
behavioral authority for both documents.

## The complete runtime shape

```text
Block, Block, Block, High Kick
            |
            v
Finish-Him / distance / violence / state gates
            |
            v
do_fatality_2 -> db2_table[Kitana] -> do_fan_decap
            |
            +-- fatality bookkeeping, tone, fade
            +-- Kitana attacker fan-swipe timeline
            |
            +-- victim-process takeover -> decap_fall
            |       +-- victim decap-body timeline (persists)
            |       +-- detached-head prop (persists)
            |       `-- generic decap-blood workers (transient)
            |
            `-- attacker recovery -> death_blow_complete -> victory
```

The important distinction is between an **animation script**, an **object**,
and a **process**:

- An animation script is a list of frame headers and commands such as
  `ani_nosleep` and `ani_jump`.
- An object is what draws one character, multipart body, or effect on screen.
- A process owns the object and advances its script. The attacker, victim,
  head prop, and blood props all run independently.

That separation is why the attacker can enter victory while a dead body and a
landed head remain visible.

## 1. Input, Finish-Him gating, and dispatch

Kitana is `ft_fn1` / character index `4`; the stock win text identifies that
slot as Kitana.

| Responsibility | Readonly source | What it does |
|---|---|---|
| Character identity | `src/MAINEQU.ASM:653-664`, `src/MAIN.ASM:1800-1802` | Defines `ft_fn1 = 4` and labels it `KITANA`. |
| Input entry | `src/MOVES.ASM:728-742` (`fn1_hi_kick`) | Runs only on a High Kick close event. Requires Finish Him (`winner_status == 3`) and distance `<= 0x48`. |
| Button history | `src/MOVES.ASM:4669-4683` (`bcom_fn1_db2`) | Uses a `0x30`-tick window. The queue is read newest-to-oldest, so the player performs **Block, Block, Block, High Kick**. It is not facing-dependent. |
| Common fatality gate | `src/MOVES.ASM:3875-3934` | Rejects no-violence/no-blood modes, a non-Finish-Him state, a second active fatality, invalid air states, or a victim that is not dizzy/super-frozen. |
| F2 dispatch | `src/MOVES.ASM:3816-3822`, `src/MKDEATH.ASM:43-55` | `do_fatality_2` selects `db2_table`; index 4 resolves to `do_fan_decap`. |

The input handler should not directly start sprite animation. It validates the
combat state and transfers the attacker process into the character-indexed
fatality dispatcher. This keeps the usual anti-overlap, distance, and
no-violence protections intact.

## 2. The fatality controller owns the presentation timeline

`src/MKDEATH.ASM:247-271` is the whole stock `do_fan_decap` controller.

| Phase | Controller action | Visual result |
|---|---|---|
| Start | `init_death_blow(1, 2)` | Marks `f_death`, disables normal combat behavior, starts the fatality tone, and requests the fatality fade. |
| Windup | Gets secondary animation slot `3`, draws its first frame, then waits `0x30` ticks. | Kitana holds the opening fan-swipe pose. |
| Cut | Runs the rest of the cutting segment with `mframew` at 4 ticks per frame. | Fan swipe advances to the cut frame. |
| Impact boundary | Calls the victim death voice, plays `tsound 0x44`, then transfers the victim to `decap_fall`. | Slice sound and victim reaction start exactly at the authored cut. |
| Recovery | Runs the next attacker segment at 4 ticks per frame, waits `0x30`. | Kitana completes the swipe/recovery. |
| Exit | Calls `death_blow_complete`, then `victory_animation`. | The global Finish-Him state clears and Kitana takes her victory pose. |

`init_death_blow` and `death_blow_complete` live at
`src/MKDEATH.ASM:2660-2712`. They are not optional decoration: they set and
clear the global fatality flag, establish the no-combat state, launch the
fatality tone/fade workers, and release the game from its fatality wait.

## 3. Kitana's attacker animation is a multipart script

`get_char_ani2` chooses a character's secondary animation table from its
runtime `ochar` (`src/MKGUYS.ASM:160-174`). For Kitana,
`fn1_anitab2[3]` is `a_fan_swipe` (`src/MKFN.ASM:98-105`).

`a_fan_swipe` is the authored timeline at `src/MKFN.ASM:1758-1783`:

```asm
KTFANSWIPE1, KTFANSWIPE1, KTFANSWIPE2, KTFANSWIPE3, KTFANSWIPE4,
ani_nosleep, KTFANSWIPE5, 0,
KTFANSWIPE6, KTFANSWIPE6, 0
```

Each logical `KTFANSWIPE#` frame is itself a multipart list. For example,
`KTFANSWIPE4` consists of `KTFANSWIPE4A`, `KTFANSWIPE4B`, and
`KTFANSWIPE4C`. The `0` terminates one controller segment; it does not delete
the attacker object. `do_next_a9_frame` leaves `a9` after that terminator, so
the second `mframew` in `do_fan_decap` proceeds into the two
`KTFANSWIPE6` recovery frames.

`ani_nosleep` deliberately suppresses the normal per-frame pause before
`KTFANSWIPE5`. It is part of the impact timing contract, not an incidental
formatting marker. Animation command handling is in
`src/MKUTIL.ASM:1098-1183`; `mframew` is in `src/MKUTIL.ASM:1266-1275`.

## 4. Victim takeover is an independent reaction lane

At the cut, `do_fan_decap` calls `takeover_him_sr(decap_fall)`.
`takeover_him_sr` (`src/MKUTIL.ASM:3116-3143`):

1. stops the victim and disables their buttons;
2. clears invisibility and restores the normal palette first;
3. marks the victim process as reacting and removes any slave object;
4. replaces the victim process's wake target with `decap_fall`.

The attacker continues its own process while the victim runs `decap_fall`.
This is the stock pattern to use whenever an effect must survive the attacker
animation or victory transition.

### The generic decap body reaction

`decap_fall` in `src/MKCANNED.ASM:409-445` does the following:

1. faces the victim toward the attacker;
2. starts generic decap blood using selector `0x0a` and the victim object as
   the position anchor;
3. creates a separate `pid_head` process for the detached head;
4. changes the victim to the character's bloody palette;
5. resolves generic character animation slot `0x3c` (`a_decapfall`);
6. plays three authored segments: knees, wobble, then final ground fall;
7. ends at `local_wait_forever`, deliberately preserving the terminal body.

The stock code then falls through to `tongued_fall`, which invokes the same
selector `0x0a` a second time. Therefore this exact stock path launches two
full generic decap-blood bursts. Treat that as a source fact to understand,
not as a default to copy into a new fatality.

### Victim art is selected by the defeated fighter, not the attacker

The fan swipe is Kitana-specific. The decap reaction is family-specific for
whichever character lost. `get_char_ani(0x3c)` and `get_char_ani(0x3d)` use
the victim's `ochar`; against Kung Lao they select Kung Lao's decap scripts,
not `KTDECAP*` art.

Kitana's own victim family provides a clear example in `src/MKFN.ASM`:

| Generic slot | Kitana script | Purpose |
|---:|---|---|
| `0x3c` | `a_decapfall` at lines 2064-2085 | Body: knee/fall frames `KTDECAP1..7`, including the persistent terminal body frame. |
| `0x3d` | `a_head` at lines 2051-2061 | Detached head bounce/roll frames `KTDECAPHEAD1..10`, looping in its own prop process. |

Every victim family needs equivalent entries if a fatality uses the generic
decap reaction. A fatality that keeps the head attached should instead provide
only the body/overlay reaction it needs and must not launch `pid_head`.

## 5. The detached head is a separate, persistent prop

`decapped_head` (`src/MKCANNED.ASM:447-510`) is a complete prop worker:

- It fetches the victim's `0x3d` head animation, copies the victim `ochar`,
  and applies the victim's bloody palette.
- It lines itself up with the victim at the neck, then offsets by `y = 0x10`.
- It inserts at `front_z + 1`, receives random horizontal velocity, and runs
  gravity plus three bounces.
- It plays `tsound 0x1f` on each ground impact and ends in `wait_forever`.

This is why a standard decap can keep a head visible through victory. It is an
explicit terminal prop, not an attacker frame that happens to remain drawn.

For Cage's headhole fatality, this exact worker is wrong: it would visibly
decapitate the victim. The relevant reusable lesson is to give every desired
terminal artifact a dedicated owner and an explicit terminal hold.

## 6. The blood lane is a bounded factory, not part of the player sprite

`create_blood_proc` in `src/MKBLOOD.ASM:28-66` maps selector `0x0a` to
`decaped_blood`. The selector validates the no-blood setting and selects a
`pid_blood` worker; it does not mutate either player sprite.

Each `decaped_blood` invocation (`src/MKBLOOD.ASM:1176-1252`) creates:

| Worker | Art/timing | Lifetime |
|---|---|---|
| Left spray | `a_decap_spray`: `SPRAY1..13`, 4 ticks/frame, flipped | Deletes itself through `blood_death`. |
| Right spray | Same animation at front Z | Deletes itself through `blood_death`. |
| Blob/master | `a_decap_blob`: `SPURT1..15`, `SPURTMAIN`; gravity and `tsound 0xc4` | Plays its landed blob frames, then dies. |

All three workers use the victim object passed in `a11` as their spatial
anchor. With the stock decap's duplicate selector call, this can mean six
transient blood workers in addition to attacker, victim, head, fade, and tone
processes. Concurrent lanes are therefore normal in a stock fatality; bad
SAGs, bad palettes, bad ownership, or bad timing—not merely the fact that
several lanes exist—are what must be diagnosed when a visual corrupts.

For a new effect, define a single fatality-owned worker when the existing
generic selector is not the desired visual. It should have:

- one clear owner/anchor;
- a defined Z order and palette;
- a finite script and `die` path for transient blood; and
- an explicit `wait_forever`/hold path only for intentional terminal props.

## 7. Asset chain: raw pixels to runtime sprite

The stock fatality spans three distinct art paths.

| Lane | Raw art | Readonly LOD/table route | Runtime script |
|---|---|---|---|
| Kitana attacker | `data/KAT9.IMG` | `data/MK3MIL.LOD:219-236` -> `src/MKFN.TBL:2131-2186` | `a_fan_swipe` / `KTFANSWIPE1..6` in `src/MKFN.ASM`. |
| Kitana as a decap victim | `data/KAT11.IMG` | `data/MK3MIL.LOD:255-279` -> `src/MKFN.TBL:2561-2734` | `a_decapfall`, `a_head`, and `KTDECAP*` multipart lists in `src/MKFN.ASM`. |
| Shared decap blood | `data/BLOOD.IMG` | `data/MK6MIL.LOD:81-116` -> `src/MKBLOOD.TBL` | `decaped_blood`, `a_decap_spray`, and `a_decap_blob` in `src/MKBLOOD.ASM`. |

A frame header in the `.TBL` is not merely a label. It carries width, height,
placement offsets, a runtime sprite address (SAG), display flags, and
occasionally a palette pointer. `KTFANSWIPE*` headers are normal attacker art;
`KTDECAPLEG1A` and `KTDECAPHEAD1` carry `KT1BLUD_P` in
`src/MKFN.TBL:2561-2570`.

The stock `PON>` / `POF>` grouping around those initial KAT11 frames is why
the generated table emits that palette field. In parallel,
`change_to_bloody_pal` dynamically chooses a bloody palette from the victim
`ochar` (`src/MKGUYS.ASM:872-900`). Both the art table and runtime palette
contract must agree.

The export layer matters too: `src/MK56.GLO` exports the `KTFANSWIPE*` labels,
and `src/IMGTBL.GLO` exports `KT1BLUD_P`. When adding a cross-module asset,
the defining table/palette and its consumer must agree on the same label and
header shape.

## 8. What must be created for a genuinely new fatality

Use this as the implementation checklist, rather than starting with a loose
animation loop.

1. **Input contract**: a named combo/button-history table, its input handler,
   Finish-Him-only check, distance rule, and normal `fatality_xfer` gate.
2. **Dispatch contract**: select F1/F2 or add the intended dispatcher entry;
   verify the fighter index resolves to the correct controller.
3. **Controller**: call `init_death_blow`, run attacker timing, place each
   sound/effect boundary deliberately, call `death_blow_complete`, then enter
   victory or the desired terminal state.
4. **Attacker art lane**: raw frames, a generated/verified table, multipart
   frame lists, and a top-level attacker script with explicit segment breaks.
5. **Victim lane**: take over the victim process rather than trying to animate
   both players from the attacker; make victim-family dispatch explicit if
   different defeated fighters need different art.
6. **Effect lanes**: use a known generic selector only when its art, timing,
   anchor, and lifetime are actually correct. Otherwise give the fatality one
   bounded worker of its own.
7. **Palette and Z order**: choose normal/bloody/custom palettes explicitly,
   set the object Z layer, and validate the table's palette field and runtime
   palette swap together.
8. **Terminal ownership**: decide what remains through victory. Each persistent
   body, overlay, spill, or prop needs an owner that intentionally holds it.
9. **Audio and presentation**: use the sound at the corresponding visual
   event, not just at process creation; retain the standard tone/fade lifecycle
   unless the design intentionally replaces it.
10. **Validation**: capture the timing boundaries and terminal scene. A no-crash
    result proves process survival, not correct pixel data, placement, palette,
    or visibility.

## 9. Mapping the stock lesson into the current `mk2-main` asset policy

The readonly source is a behavior reference, not a safe place to copy static
SAG values or append stock LODs. In the active repository:

- Put new normal PIXBLT move/fatality sprites in the fixed move-art wrappers,
  not REVX and not an in-place stock `MK2MIL`-`MK7MIL` append.
- Follow `doc/CUSTOM_CONTENT.md` and `doc/ASSET_SPACE_LEDGER.md` for the
  allowed `MOVEART1` / `MOVEART2` space and table-promotion rules.
- If raw IMG, LOD, table, palette, or video-ROM data changes, run the full
  pipeline:

  ```powershell
  $env:ALLOW_STOCK_BG_DRIFT='1'
  python build.py
  python makerom.py
  python makevrom.py
  python mamerom.py --no-install
  ```

- If only linked ASM timing/process code changes and all referenced art is
  already present in the packaged ROM, the smaller rebuild is sufficient:

  ```powershell
  python build.py --asm-only
  python makerom.py
  python mamerom.py --no-install
  ```

For the current Cage headhole work, the closest reusable portion of this stock
example is the controller -> victim takeover -> bounded effect-owner pattern.
The detached-head worker and duplicate generic decap blood are specifically
the parts to avoid while the design requires `TMDEADHEAD7` to remain attached.
