# Hidden fighters celebrate as themselves on the select screen

Picking Jade, Smoke, Noob Saibot or Ermac now switches the character-select
preview to **that fighter's own victory animation** and announces **their own
name**. Jade brings her staff.

Before this, all four unlocks confirmed as the roster fighter whose mugshot the
cursor was parked on: you pressed Low Kick five times on Mileena and watched
*Mileena* take the victory pose while the announcer said "Mileena", and only
the VS screen revealed Jade.

## Why it looked like that

The unlock counters (`check_jade_lk_cheat` and the three Block ones in
`src/MKSEL.ASM`) raise a **pending flag** on the fifth press and then let that
press through as an ordinary confirm. `MAIN.ASM`'s `*_select_cheat_apply`
routines read those flags and swap `@p1_char` / `@p2_char` — but they run
*after* `player_select` has returned, which is long after `cmove9` has already
played the celebration and made the speech call.

That split is deliberate for half the screen and wrong for the other half:

| runs on | wants |
|---|---|
| mugshot flash, `p_store1`, `picked_palettes`, `aud_choose_hh` | the **grid square** — a hidden fighter has no mugshot, no `otm_table` entry and no `picked_palettes` row (both tables are 12 long; ochar 14-17 reads off the end) |
| stance preview, victory animation, name speech | the **hidden fighter** |

## What changed

Three small pieces in `src/MKSEL.ASM`, all inside `cmove9`'s existing flow:

- **`psel_hidden_pick`** — reads the four pending flags for whichever player
  this select process belongs to and returns the hidden `ft_*` plus its
  `triple_sndtab2` name index, or carry-clear for an ordinary pick. It does
  **not** clear the flags: `MAIN.ASM` still owns their lifetime and writes the
  same value a second time, harmlessly, so a player who never reaches `cmove9`
  (drop-out, select timeout via `force_psel_choice`) behaves exactly as before.
- **`psel_apply_hidden_char`** — commits `@p?_char` at `look2`, i.e. *after*
  the mugshot flash and the audit have already read the grid square.
- **`psel_hidden_victory`** — the preview drone is fastxferred here instead of
  straight into `victory_animation`. It drops the old fighter's objects and
  calls `make_player_1_obj` / `make_player_2_obj`, exactly the way
  `psel_drone_1/2` does on every cursor move, so the hidden fighter's art,
  anitabs, ground line and palette all come from the one routine that already
  knows how to build them. Then it falls into the stock celebration.

`victory_animation`'s `player_normpal` recovers a Start+button alternate
palette from `@alt_pal_owner` keyed on `procid`, and the preview drone's
procid is `pid_p1`/`pid_p2`, so alternate-palette picks keep working without a
special case.

Jade needed nothing extra: `generic_victory` already routes `ft_jade` to
`jade_victory`, which spawns the `JDVICSTAFF` overlay one z-step in front of
her. Getting the object rebuilt as Jade was the whole job — the pole followed.

`select_speech` changed contract: it now takes the **finished**
`triple_sndtab2` index rather than an ochar, because a hidden fighter's name
is not at `ochar + 01Ch`. `cmove9` does the arithmetic for both cases. This is
the one edit that every ordinary pick in the game also rides on, so it has its
own regression run (below).

## The names

`triple_sndtab2` gained four entries (`src/MKSOUND.ASM`):

| index | says | track | source |
|---|---|---|---|
| `$5D` | "Smoke" | `$035B` | **retail stream `$1754D4`** — no new audio |
| `$5E` | "Jade" | `$0361` | **retail stream `$331480`** — no new audio |
| `$5F` | "Noob Saibot" | `$0352` | `NOOBNAME.wav` |
| `$60` | "Ermac" | `$036D` | `ERMACNAME.wav` |

Smoke and Jade cost nothing because **the retail ROM already contains their
names as standalone streams**. Every retail "X WINS" line is a two-`Play()`
chain — the name, then the shared "WINS" suffix `$17EBEC` — so `$03A8` and
`$03AB` ("Smoke wins" / "Jade wins") each carry a name-only stream that no
retail track ever plays on its own. `sound/stlaugh_patch.txt` note (24) had
asserted the opposite; see the correction there and in
[UNUSED_AUDIO.md](UNUSED_AUDIO.md).

Acting on that also **freed** space rather than spending it: `NOOBWINS` and
`ERMACWINS` were re-split so their streams carry the name only, with the win
tracks chaining the retail `$17EBEC` behind them. Usable headroom went from
3,182 bytes to **13,996**, and the win lines are unchanged to within 6 ms
(their `triple_sndtab2` durations, 149 and 101, still hold).

Levels were set by measuring, not by copying: rendered with
`DCSExplorer --extract-tracks` and compared against the twelve retail name
tracks, which span -21.5 dB (Liu Kang) to -26.2 dB (Jax) voiced RMS. Smoke
-24.1, Jade -22.3, Noob -21.6, Ermac -21.5.

The four track slots are VP-scratch-bank triples that earlier reclaims had
already no-op'd (`VPTRIP`, `VPTHROW`, `VPATTAK1`, `VPWAST1`), so no previously
reclaimed audio comes back.

## Testing

```
tools\run_hidden_select_victory_test.ps1 -Name all -Player 1
tools\run_hidden_select_victory_test.ps1 -Name all -Player 2
tools\run_hidden_select_victory_test.ps1 -Normal            # ordinary pick regression
tools\run_hidden_select_victory_test.ps1 -Name jade -Fight  # nothing left on screen after
```

The rig drives the real unlock (park the cursor, press the button five times),
then checks four things in the window between the confirm and the VS screen:
the preview object's `ochar`, that its multipart SAG actually advances, that
the **hidden** name call went out and the roster one did not — read straight
off the sound port with a write tap rather than inferred — and, for Jade, that
the staff object is there one z-step in front of her.

Current status: 4/4 PASS on both players, plus roster regressions on Liu Kang
(P1) and Reptile (P2), and 0 leftover objects once the fight starts.

Three traps this rig hit, all of which look like the feature failing:

- **Forcing `@p?_char` to hover a fighter fights the feature.** `cmove9`
  commits the hidden id on the fifth press; a rig that keeps stamping the base
  id back in for even one more frame makes `psel_hidden_victory` rebuild the
  preview as the base fighter. The rig stops forcing the moment the pending
  flag goes up.
- **A player object's `oimg` never changes** — it is a constant pointer to
  `p?_ram`. The frame on screen is the SAG in the first multipart record.
- **`install_write_tap`'s return value must be kept alive.** Drop the
  reference and Lua's GC collects the handler out from under MAME, which then
  dies mid-run with no message at all. Likewise, an unbounded `objlst` walk
  that follows a wild link into the I/O page at `01d0xxxxh` takes the machine
  down; the walk is gated to SCRATCH.

Also re-run after any change here: `tools\run_hidden_cheat_test.ps1` (the
unlock still reaching the fight, and the off-base "Block is still a confirm
button" regression).
