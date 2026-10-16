# MK2 Beta — what's different and what we need from you

Thanks for testing. This is Mortal Kombat II with a set of deliberate changes
aimed at competitive play. Everything below is intentional, measured, and
reversible — so if something feels wrong, that is exactly the feedback worth
having.

---

## First: identify your build

Every report needs this. Enter the **operator/diagnostic menu** and read the
revision line:

```
REVISION 4.0-BETA (xxxxxx)
```

The part in brackets is the build id, and it changes with every drop. **Quote
the one your copy shows in every report** — not the format above.

It is the source commit the build came from. A trailing asterisk — `66D45*` —
means the build was cut from a working tree with uncommitted edits, so it maps
to that commit *plus* changes nobody can reconstruct. Say so if you see one;
for a widely distributed drop we want a clean id.

---

## Running it

Three things surprise people in the first five minutes. None of them is a bug.

**MAME will warn about ROM checksums.** Expected — the ROMs are built from
source, so they don't match the original dumps. The real health check is
audible: you should hear a **single "bong" at boot**. That is the game's own
internal checksum passing.

**It behaves like a real cabinet.** It is coin-op by default. You need to
insert a credit (`5` in MAME by default) before START does anything. Free play
is granted at runtime by the online wrapper, so a standalone MAME session
won't have it — use the coin key or set the coinage dipswitch.

**Do not verify by hashing the ROMs.** The packaging step rewrites four bytes
of padding in each program chip, so the files inside the zip never match the
build outputs, and differ again on every repackage. It is not corruption.

---

## What's different

### Controls and inputs

| Change | What you'll notice |
|---|---|
| **Back-block** | Holding the stick **away** guards, in addition to the block button. Away+down guards low. |
| **Specials while blocking** | Holding the block button no longer cancels special-move motions. On the arcade it silently ate every one. |
| **Sloppy motions work** | A motion that rolls through a diagonal used to drop. Measured 0-in-4 before, 4-in-4 after. |
| **Left+Right resolved** | Pressing both directions at once now resolves consistently instead of by accident. |
| **Wider timing windows** | Slightly more slack on motion timing, and on two-button moves (Kitana's fan, Reptile's forceball). |
| **Crossups keep your motion** | Jumping over someone no longer eats a motion you started on the other side. |

### Combat

| Change | What you'll notice |
|---|---|
| **Juggle damage scales** | First hit full, then 3/4, 1/2, 1/4 from the fourth. Resets on landing or blocking. A five-hit string went from ~100 damage to ~55 of a 161 bar. |
| **Point-blank uppercut** | Standing right on top of someone used to whiff. The dead zone is much smaller — for Jax and Cage it went from 41px to 28px, and it's gone entirely for Kitana/Mileena/Jade. |
| **Chip can't kill** | Blocking will not take your last point of health. On the arcade, lethal chip actually *threw the block away* and gave you the clean hit instead. |
| **Simultaneous hits trade** | Both fighters connect. MK2 has never done this — the arcade always gave it to player 2. |
| **Double KOs exist** | If a trade is lethal to both, both die. The round is a draw and replays; neither player is awarded it. |
| **Mileena's sai rate-limited** | It now has the same cooldown Kitana's fan has always had. The throw itself is unchanged. |

### Other

- Secret fighters (Smoke, Noob, Jade) no longer keep the boss walk speed when
  a human uses them.
- A hit/hurt box overlay exists for analysis. It is off in normal play.

---

## What we specifically want tested

Play normally first — general feel matters more than checklists. But these are
the changes with the least real-world play behind them:

1. **Crossups.** Jump over someone and throw a special on the way down, or
   immediately after landing. Does the move come out? This is new and the most
   likely to have rough edges.

2. **Trades and double KOs.** Trades are brand new to this game. Do they feel
   right? After a **double KO** specifically: does the round replay cleanly, do
   the bars refill, does anything look stuck or strange? This is the newest
   state in the build.

3. **Back-blocking.** Does holding away to block feel natural, or does it block
   when you meant to walk backwards? Walking away should still walk.

4. **Point-blank uppercuts.** Stand on top of someone and uppercut.

5. **Anything that feels unfair.** Especially: a move that should have hit and
   didn't, or a string that does more damage than it looks like it should.

---

## Known, and not worth reporting

- **There is no input buffer.** If you finish a motion slightly too early it is
  discarded rather than held. Some players read this as dropped inputs. Known,
  not yet changed — but tell us if it bothers you in practice, because that
  decides whether we build one.
- **Throws still favour player 2** in a genuinely simultaneous situation.
  Throws take a different path through the engine and were not covered by the
  trade fix.
- **There is no high/low game.** MK2's mixups are about *reach*, not height —
  no move in the game whiffs over a crouch on the vertical axis. We measured
  three separate ways of adding one and all three fail. This is what MK2 is,
  not something broken.
- **AI-vs-AI matches wedge.** If you find a way to make two CPU fighters fight
  each other, it will hang. Retail never runs that configuration.

---

## Reporting

A report we can act on has:

- the **build id** from the diagnostic menu;
- **who vs who**, and **which stage**;
- what you did, and what you expected instead;
- whether it happens every time or occasionally.

"Feels off" is genuinely useful feedback — several changes this cycle were
reverted purely because they felt wrong in play, even though they measured
fine. Don't sit on a vague impression.

The full technical record of every change, including the measurements behind
it and how to revert it, is in `doc/DEVIATIONS.md`.
