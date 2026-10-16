# Noob's shadow slide and portal lost their reactions

Found 2026-09-03 while regression-testing an unrelated sidecar rebase. Both of
Noob Saibot's signature shadow moves had been landing their damage and giving
the victim **an ordinary kick flinch** instead of their own reactions. Fixed by
two `.long` rows.

```
tools/run_noob_portal_test.ps1        # was FAIL, now PASS (all five passes)
tools/run_noob_slide_test.ps1         # PASS
```

## What it looked like

The portal harness, before:

```
portal_seen          true      every art check green
portal_frames        5
portal_under_victim  true
portal_born_on       NOOBAIRGUNK6
blast_gap_px         0
portal_damage        12        the strike record's own hit number
victim_vanished      false     <-- the entire point of the move
victim_from_above    false
victim_crossed       false
noob_turned          false
jump_up_missed       nil       (later passes never ran - pass 1 aborted)
```

The hole opened in the right place on the right frame, did its 12, and then
nothing happened. That is what an over-run of a table of function pointers looks
like in this game: **not a crash, a wrong move.**

## The cause

A strike record's routine word indexes the **attacker's own** reaction table
([[reference-mk2-strike-routine-word]]), and Noob is `ochar` 15, whose
`reaction_tables` slot points at **`react_to_nj`**.

| record | asks for row | `react_to_nj` has |
|---|---|---|
| `stk_noob_slide` (`01a10h`) | `1ah` | rows `0`..`19h` only |
| `stk_noob_portal` (`01b10h`) | `1bh` | rows `0`..`19h` only |

So both read past the end of the table. What sits immediately after
`react_to_nj` in the assembled output is `react_to_ermac`, whose rows `0` and
`1` are "react_to_nj verbatim" — `r_hikicked` and `r_lokicked`. Noob's portal
was dispatching a low kick's flinch.

**And `r_noob_slide` / `r_noob_portal` were still in the ROM the whole time** —
they just lived only in `react_to_ermac`, at exactly the rows Noob was asking
for but in a table he does not use.

## How it got there

`react_to_ermac` was split out of `react_to_nj` (so Reptile/Sub-Zero/Scorpion
could not reach Ermac's own rows). The copy was taken while Noob's rows `1a`
and `1b` were in `react_to_nj` — so they went into the copy — and were then
dropped from the original rather than from the copy.

Nothing catches this. `tools/audit_char_tables.py` reports "0 short table(s)"
because it audits the char-indexed `.word`/`.long` tables, not
`reaction_tables`' targets against the rows the strike records actually name.

## The fix

Two rows appended to `react_to_nj` (MKREACT.ASM):

```asm
	.long	r_noob_slide	; 1a - Noob shadow slide (D,B+LK)
	.long	r_noob_portal	; 1b - Noob shadow portal (D,D+LK)
```

They belong in **both** tables. The split's own reason — keeping Ermac's rows
away from the other ninjas — does not apply to these, because no other ninja's
strike record names `1ah` or `1bh`.

Noob's other two shadow moves were never affected: `stk_noob_kick` asks for row
`0ah` and `stk_noob_dive` for `0bh`, both inside `react_to_nj`'s range.

## After

```
victim_vanished      true
victim_from_above    true
victim_crossed       true
noob_turned          true
jump_up_missed       true      the counterplay passes now run at all
jump_fwd_missed      true
jump_back_missed     true
jump_apex            144
jumped_portal_closed true
lethal_killed        true
lethal_visible_after true
PASS reason=portal_kill_leaves_him_visible
```

The `nil`s in the "before" listing were not a time budget — the harness aborts
the remaining passes when the first one fails, so a broken pass 1 hid the other
four. A 400-second run produced the identical report to a 200-second one, which
is what ruled the budget out.

## Two things worth keeping

**These rigs are coupled to `src/mk2.map`.** Trying to A/B this against an older
`mk2.zip` to prove the break was pre-existing does not work: the harness reads
symbol addresses out of the *current* map, so against a mismatched ROM it reads
garbage, never sees `gstate` advance, and stalls at frame 1 having driven
nothing. Proving a regression pre-existing needs the matching map, not just the
matching ROM — `git show HEAD:src/MKREACT.ASM` settled it instead, in a second.

**A green art check is not a green move.** Every pointer-level assertion in that
harness passed throughout: the SAGs resolved, the frames drew, the hole landed
on the pixel, the damage was the record's own. The only thing that caught this
was an assertion about what happened to the *victim*.
