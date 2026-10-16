# Noob Saibot — Ported Design Reference (from MK Trilogy N64 source)

**Status: reference only. Nothing in this document is wired into the build.**
Every code excerpt below is inert C source from a different codebase (MK
Trilogy, N64, TMS-free — a Williams/Midway PS1-era C engine, not TMS34010
assembly) and is wrapped in `//` line-comments on top of living inside a
Markdown file, so it cannot be assembled, linked, or accidentally picked up
by `build.py`. This file is not referenced by any `.ASM`, `.TBL`, `.GLO`,
`MAKEFILE`, or `mk2.cmd` — it carries zero build risk by construction.

`ft_noob .set 15` already exists in `MAINEQU.ASM:704` with no comment (`ft_smoke`
and `ft_jade` at least got dev-joke comments — Noob didn't). No `MOVES.ASM`,
`MKNJ.ASM`, `MKPROP.ASM`, `MKZAP.ASM`, `MKDEATH.ASM`, or `MKSTK.ASM` code
references him anywhere (`grep -i noob` across `src/` and `CHANGELOG.md`
returns nothing). This doc exists so that whenever Noob actually gets
implemented, there's a real behavioral source to build from instead of
guessing from memory or a YouTube clip — same spirit as
[FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §0: "pick the stock
[behavior] closest to yours... do not design from memory."

## Where this came from

`C:\Users\you\Workplace\MKTRILOGY_source_N64\...\SEG\GAMECODE\` — Mortal
Kombat Trilogy (N64). Same engine lineage as the readonly MK2/MK3 C sources
(identical file names — `MOVES.C`, `MKSTAT.C`, `MKPROP.C`, `MKZAP.C`,
`MKFATAL.C`, `MKFRIEND.C`, `MKANIMAL.C` — identical `FT_JADE=16`/`FT_NOOB=23`
numbering), several console generations past MK2's TMS34010 arcade board.
It is **not** the MK2 readonly source and nothing here should be assumed to
match MK2's engine primitives 1:1 — treat it as intent/behavior reference,
the way [FUTURE_CHARACTER_EFFECTS.md](FUTURE_CHARACTER_EFFECTS.md) treats
Raiden's lightning as "a lifecycle model only," not code to reuse verbatim.

For contrast: the **arcade UMK3** build (a sibling decompilation, closer in
age to MK2) implements Noob as a palette-swap + AI construct with **zero**
unique special moves — no `SMOVE` table, no `do_noob_*` routine, no unique
sprite data, nothing beyond a palette (`noob_p`), a forced home stage, and a
75%-damage-taken rule shared with the two real bosses. Trilogy is the one
Midway build where Noob got an actual authored moveset. That's why this
reference is worth keeping even though it's a console generation removed
from MK2's board — it's the only complete, coherent design for this
character that exists anywhere in this family of engines.

## Engine-primitive translation table

Rough mapping from the Trilogy C engine's vocabulary to this MK2 codebase's
TMS34010 vocabulary, so the logic below reads as "what to build," not "code
to paste." Confirm every mapping against real MK2 code before relying on it
— this is a starting hypothesis, not a verified equivalence.

| Trilogy (C, `SEG/GAMECODE`) | MK2 (TMS34010, `src/`) | Notes |
|---|---|---|
| `secret_move_search(sm_x[])` against per-button `ochar_*_close[]` tables | `combo_look_lr(scom_x, ...)` called from the character's button handler (`MOVES.ASM`) | See [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §6 — trigger button lives in the handler, not the combo table. Inspect/author patterns with `python combo_edit.py`. |
| `do_stationary(STAT_X)` / `do_body_propell(PROP_X)` / `do_zap(ZAP_X)` dispatch tables | presumably a `do_x` label called directly via `movi do_x,a7` from the handler | MK2's `MOVES.ASM` looks handler-direct rather than index-table-dispatch per §6 of the fatality guide; confirm by reading a live special (e.g. Sub-Zero's slide) before assuming. |
| `PROCESS` / `CREATE(pid, func)` / `process_sleep(n)` cooperative tasking | TMS34010 process scheduler — `create pid,addr` / `sleep n` (`MACROS.HDR`) | Same cooperative-multitasking shape; MK2's tick is 18.28ms (54.7Hz). |
| `get_char_ani(ANIM_TABLE1/2, ANIM_X)` | `get_char_ani` + `anitab1`/`anitab2` slot, or a module's own anim table | Per [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §3, victim reaction art must live in the **victim's own module**, selected via an `anitab1` slot — never streamed from the attacker. |
| `ochar_sound(n)` / `borrow_ochar_sound(n, FT_X)` | `tsound <index>` / character-local sound table in `MKSOUND.ASM` | Per the fatality guide §7: append to `triple_sounds` before `triple_end`. |
| `takeover_him(func)` | same concept exists in MK2 (`calla takeover_him`, used throughout `MKDEATH.ASM`/fatality controllers) | Confirmed real primitive on the MK2 side — see [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §5. |
| Shared "generic ninja" animation/sound assets (`ANIM_NJ_*`, `st_nj[]`) reused by Scorpion/Sub-Zero/Reptile/Ermac/Smoke/**Noob** | `MKNJ.ASM` — this MK2 build's shared ninja module | [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §4 already says it: "shared modules serve several fighters (ninjas + Smoke/Noob, females + Jade)" — this project's own docs already assume Noob rides the ninja module, matching Trilogy's approach exactly. |

## The moveset

### Special moves

**Alter Ego** — summons a second, temporary Noob that charges the opponent
and either throws them or self-destructs if blocked/whiffed. A decoy/mixup
tool, not a damage move in itself.

```c
// Trilogy source — MOVES.C:2591, MKSTAT.C:210-349 (condensed). Reference
// only; NOT MK2/TMS34010 code; NOT wired into any build target.
//
// void do_noob_alterego(void) { do_stationary(STAT_NOOB_EGO); }
//
// void stat_do_noob_ego(void) {
//     init_special_act(ACT_NOOB_EGO, obj);
//     update_tsl(l_decoy, obj);                 // starts the reuse cooldown
//     pose_a9(0, ANIM_STANCE);
//     process_sleep(3);
//     ptemp = CREATE(PID_NOOB_EGO, noob_ego);    // spawn the decoy process
//     ptemp->pdata.p_otherguy = current_proc->pdata.p_otherguy;
//     current_proc->pdata.p_action = ACT_NOOB_EGO_SD;
//     stop_me(obj);
// }
//
// void noob_ego(void) {
//     // spawn a second Noob OBJECT (not the real player object), run it in
//     // at ANIM_TABLE1/ANIM_RUN, SCX(0xd0000) toward the opponent, for up
//     // to 0x20 ticks:
//     //   - if in toss range and opponent NOT blocking -> ego_hit() (throw)
//     //   - if opponent IS blocking, or ego runs off-screen, or time runs
//     //     out -> ego self-destructs: create_fx(FX_NOOB_EGO_EXP),
//     //     borrow_ochar_sound(0x15, FT_ROBO2) for the explosion sound
// }
//
// Gate: q_noob_ego() (MOVES.C:3976) — only one ego alive at a time
// (process_exist(PID_P1_EGO/PID_P2_EGO) must be NULL), and l_decoy cooldown
// >= 0x40*3+0x10 ticks since last use.
```

**Slam** ("teleport slam") — Noob leaps off the top of the screen, teleports
directly above the opponent, and free-falls onto them; a connecting hit
carries the victim off the *bottom* of the screen before slamming them back
up into view.

```c
// Trilogy source — MOVES.C:2939, MKPROP.C:4588-4661 (condensed). Reference
// only; NOT MK2/TMS34010 code; NOT wired into any build target.
//
// void do_noob_slam(void) {
//     current_proc->pdata.p_store1 = 0;          // 0 = normal, 1 = fatality
//     do_body_propell(PROP_NOOB_SLAM);
// }
//
// void prop_do_noob_slam(void) {
//     init_special_act(ACT_NOOB_TELESLAM, obj);   // "i cant block"
//     update_tsl(l_warp, obj);                    // reuse cooldown
//     ochar_sound(4);
//     create_fx(FX_TRAIL);                        // ghost trail on launch
//     get_char_ani(ANIM_TABLE1, ANIM_VICTORY);     // reused pose, not bespoke art
//     obj->oyvel.pos = -SCY(0x80000);              // rockets off the top
//     // ... loop until off-screen above ...
//     teleport_next_to();                          // relocate above opponent
//     face_opponent(obj);
//     // ... free-fall down, get_char_ani(ANIM_TABLE1, ANIM_THROW) ...
//     // on a clean strike during the fall: noob_hit() -> body_slam_init(),
//     // carries victim below SCRBOT, then back up, then noobed() lands them
//     // (NOOB_DAMAGE = 0xf; flight() knockdown arc; group_sound(2))
//     // explicitly excludes bosses: if (other->ochar!=FT_SK && !=FT_MOTARO)
// }
```

An earlier, more elaborate version of this move — with its own dedicated
`ANIM_NOOB_TELESLAM` art and a "catch the opponent mid-jump" latch mechanic
— exists in the Trilogy source but is `#if 0`'d out (`MKPROP.C:408-619`,
`r_noob_slam_wait`/`r_noob_slammed`). It was abandoned in favor of the
simpler version above, which reuses generic `ANIM_TABLE1` poses instead of
authoring new art — worth knowing before spending an art budget on a bespoke
teleslam sprite; even Trilogy's own developers decided it wasn't worth it.

Gate: `q_noob_slam()` (`MOVES.C:4046`) — `l_warp` cooldown ≥ `0x60` ticks.

**Zap** ("Noob Zap") — a thrown projectile whose *hit* effect is more
important than its damage: it plants a per-player marker that several other
characters' special-move gates check before allowing specific reactive
moves to fire, effectively acting as a temporary universal move-lock/blind
on whoever it connects with.

```c
// Trilogy source — MOVES.C:3207, MKZAP.C:414-489, 5641-5671 (condensed).
// Reference only; NOT MK2/TMS34010 code; NOT wired into any build target.
//
// void do_noob_zap(void) { do_zap(ZAP_NOOB_ZAP); }
//
// void do_proj_noob_zap(void) {
//     zap_init(ZINIT_SPEC_ACT, ACT_NOOB_ZAP, 0, obj);
//     borrow_ochar_sound(0x2, FT_LIA);            // borrowed throw sound
//     animate2_a9(0x4, ANIM_NOOB_ZAP);
//     create_proj_proc(noob_zap_proc);
// }
//
// // noob_zap_proc: standard projectile flight (generic_prezap prediction
// // checks, then projectile_flight_call); on unblocked hit, spawns/relies
// // on a marker process at PID_NOOB_ZAP_FLASH1 (p1) / PID_NOOB_ZAP_FLASH2
// // (p2) that other move-gates test for.
//
// WORD q_am_i_noob_zap(void) {     // "am I currently flashed by Noob's zap"
//     pid = (current_proc->pa8==p1_obj) ? PID_NOOB_ZAP_FLASH1 : PID_NOOB_ZAP_FLASH2;
//     pa0 = process_exist(pid, -1);
//     if (pa0!=NULL && pa0->pa8==current_proc->pa8) q_yes;
//     q_no;
// }
// // q_is_he_noob_zap() is the opponent's-eye mirror of the same check.
```

`q_am_i_noob_zap()` is checked at six unrelated call sites across the whole
roster's move-gating code (Smoke's air-slam entry, Jax's back-breaker entry,
both Cyrax/Sektor teleport entries, Kung Lao's angle-kick entry —
`MOVES.C:1465,1492,1701,2008,2336,2435`), each treating "flashed by Noob"
the same way they treat being mid-flip-kick-reaction. **If this move is ever
built, budget for touching every character's move-gate, not just Noob's
own file** — this is the one piece of his kit that isn't self-contained.

Gate: `q_noob_zap()` (`MOVES.C:3985`) — blocked once the opponent's combo-hit
counter is ≥4 (juggle limiter).

### Fatalities

**Hyperslam** — runs the Slam special as its setup (`p_store1=1` flags the
fatality variant), then instead of a normal landing, bounces the victim's
body up and down 7 times with escalating gravity/velocity while shaking the
ground and screaming, then explodes them.

```c
// Trilogy source — MKFATAL.C:844-930 (condensed). Reference only.
//
// void noob_hyperslam(void) {
//     fatality_start_pause();
//     current_proc->pdata.p_store1 = 1;
//     prop_do_noob_slam();          // reuses the special's setup verbatim
//     wait_forever();                // never reached; slam takes over control
// }
//
// void noob_hyperslam_fatality(OBJECT *oa10) {
//     loop = 7; yvel = -SCY(0x160000); grav = SCY(0xa000);
//     do {
//         shake_a11(10,4);
//         death_scream;
//         // bounce body up then down under increasing gravity...
//         tsound(0x81);              // impact thump each bounce
//         grav += grav>>1; yvel += yvel>>2;   // escalate each bounce
//     } while (--loop > 0);
//     takeover_him(hyperslam_death); // explode: create_fx(FX_SWAT_BEXP)
//     death_blow_complete();
//     local_victory_animation;
// }
```

**Fatal Ghost** — summons a hovering ghost/fire-hand effect (reusing
Scorpion's fire-hand-summon animation) that shakes the ground and holds,
then withdraws. Simpler and cheaper than Hyperslam; worth prototyping first
if art/animation budget is the constraint (per
[FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §1, "space is the
constraint that kills projects").

```c
// Trilogy source — MKFATAL.C:932-958 (condensed). Reference only.
//
// void noob_fatal_ghost(void) {
//     fatality_start_pause();
//     tsound(0x87);
//     shake_a11(12,12);
//     animate2_a9(2, ANIM_SCORP_SUMMON);   // BORROWED Scorpion art, not unique
//     ptemp = CREATE(PID_FX, ghost_beam);
//     process_sleep(0x40*4);
//     backwards_ani2(2, ANIM_SCORP_SUMMON);
//     death_blow_complete();
//     local_victory_animation;
// }
```

Both fatalities have dedicated (if minimal) palette assets in the Trilogy
source: a cut/death palette via `special_case_cut_pals[]` (`noob_p`,
`MKFATAL.C:276`) and a distinct torn-flesh "rip" palette `NOOBRIP_P`
(`MKFATAL.C:295`) plus a blood-hit palette `BHNOOB_P`. If either fatality
gets built here, follow
[MK2_READONLY_FATALITY_COMMON_CONTRACT.md](MK2_READONLY_FATALITY_COMMON_CONTRACT.md)
and the §5 controller skeleton in the wiring guide rather than this doc's
condensed pseudocode — this file is behavior reference, not a spec for the
controller shape.

### Friendship & Animality

Both ride the shared generic-ninja assets already anticipated in this
project's own conventions (`MKNJ.ASM` — see the primitive-translation table
above):

- **Friendship** (`f_noob`, `MKFRIEND.C:405-436`, gate `q_noob_friend`
  requires distance ≥ `SCX(0xf0)`): conjures and bowls a bowling ball at the
  opponent, reusing the shared `ANIM_NJ_BOWLING` animation.
- **Animality** (`noob_anteater`, `MKANIMAL.C:124-165`, gate
  `q_noob_animal`, distance band `SCX(0xb0)`-`SCX(0xc0)`): turns Noob into
  an anteater (shared `SPEC_NJ_ANIMAL`/`ANIM_NJ_ARDVARK` art) that sucks up
  the opponent.

Neither needs bespoke art if `MKNJ.ASM` already carries analogous
friendship/animality assets for the other ninjas it serves — check there
first before budgeting new art space.

## Notes for a future implementer

- **Sound**: Trilogy's Noob has no dedicated sound table of his own — every
  cue is borrowed at the call site from another character's table
  (`FT_ST` for the ego's spawn, `FT_ROBO2` for its explosion, `FT_LIA` for
  the zap). Following [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md)
  §7, the MK2-side equivalent is just appending entries to `triple_sounds`
  in `MKSOUND.ASM` and firing them with `tsound <index>` — no new table
  needed, same "borrow, don't author" approach Trilogy used.
- **Boss immunity**: the Slam special explicitly can't connect against Shao
  Kahn/Motaro-equivalent bosses in Trilogy. If this MK2 build has an
  equivalent boss-immunity convention (check `MKGORO.ASM`/`MKBOSS.ASM` and
  `MK2_READONLY_FATALITY_COMMON_CONTRACT.md`), Slam should respect it too.
- **The Zap's cross-roster hook is the expensive part.** Everything else
  about Noob is self-contained inside a ninja-shared module; the Zap's
  "flash" state is not — it requires editing six-plus other characters'
  move handlers. Scope that explicitly and separately if it's ever
  attempted; don't let it block shipping Alter Ego/Slam/Fatalities first.
- **Follow the checklist in
  [FATALITY_WIRING_GUIDE.md](FATALITY_WIRING_GUIDE.md) §9** and the
  lifecycle rules in [FUTURE_CHARACTER_EFFECTS.md](FUTURE_CHARACTER_EFFECTS.md)
  for any of the above once actual implementation starts — this document
  only captures *what Noob did in another Midway build*, not *how to build
  it correctly on this board*.
