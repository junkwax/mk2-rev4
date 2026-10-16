# Palette transfer coalescing - a negative result

**Status: measured in MAME, 12 September 2026 - nothing worth taking.** This
is opportunity 11 (palette update coalescing and dirty ranges) in
[the graphics audit](../GRAPHICS_OPPORTUNITIES.md), P1. A working coalescer was
built and validated. It is **compiled out** (`palcoal .set 0`, MAINEQU.ASM)
because the queue has almost nothing to fold, and the coalescer's own cost
shows. The one piece kept is a drop counter the stock game never had.

## What the queue is

`palset` ([PALL.ASM](../../src/PALL.ASM)) appends `[src:32 | dest:16 |
count:16]` to a 32-cell ring. `transfer_palettes` drains all of it once per
display interrupt. When the ring is full, `palset` refuses the request, and
nothing in retail counted that.

## The profile

`tools/run_palq_probe.py` records every enqueue from power-up, through attract,
select and VS, to 900 frames into a two-player fight on THE WASTELAND and THE
DEAD POOL. Both health bars are pinned and P1 attacks.

| | before the fight (1,493 frames) | the fight (901 frames) |
|---|---|---|
| Transfers | 418 (0.28 per frame, max **15**) | 114–152 (0.13–0.17 per frame, max **1**) |
| Colours copied | 13.9k (9.3 per frame) | 919–2,329 (1.0–2.6 per frame) |
| Duplicate transfers in the queue | **7** | **0** |
| Colours rewritten unchanged | 28–29% (mostly fade steps) | 0.1% |
| Deepest queue | 15 of 31 | 1 |
| Transfers lost (`palq_drops`) | **0** | **0** |

In a fight the queue carries the stage's colour cycle: `2c21:8` on THE
WASTELAND, `2301:15` on THE DEAD POOL, every few ticks. There is nothing to
fold.

## The coalescer, and why it is off

`palq_coalesce` (PALL.ASM, inside `.if palcoal`) runs with interrupts off. It
voids a pending cell whose colour range lies wholly inside the new transfer.
If the latest pending cell touching the new range is one of those, the new
transfer takes over that cell instead of appending. Both rules are exactly
equivalent to appending, because the queue drains in order.

`tools/run_palcoal_test.py` runs an A/B on one frozen ROM (off/on, identical
inputs, both stages):

| | off | on |
|---|---|---|
| Transfers merged | - | **7** per boot, the same 7 duplicates the profile found |
| Colours copied | 18,984 | 17,000 |
| Drops | 0 | 0 |
| Colour-RAM hash, 291 samples | | identical except **one** sample at the select → VS palette load |

That one mismatch is timing, not a wrong colour. Both boots queue the same
transfers in the same order, but in the coalesced boot the scans' extra time
moved the frame boundary two transfers later. The hash eight frames later
matches again. So the result is 7 saved transfers per boot and zero in a
fight, at a measurable time cost.

## What the prototype got wrong first, and corrected

The first profile reported 31-transfer "bursts", 145 duplicates, and a VS
hand-off that "filled the ring". That was the probe, not the game.
`init_paltrans_queue` resets both ring pointers at state changes, and the
walk from the old end wrapped the ring, re-counting up to 31 stale cells. The
coalescer's own counter (7 merges) did not match the profile (145), and that
disagreement is what exposed it. The probe now detects a reset (start back on
the base, end behind the old end) and counts only base..end.

A second check showed the Lua callback runs exactly once per emulated frame
(2,393 of 2,393), so the per-frame windows are real frames.

## What was kept

- **`palq_drops`** (PALL.ASM, always assembled). It counts transfers lost to a
  full queue. Retail silently refused them, and a lost final fade step would
  leave a palette at the wrong brightness with no symptom anywhere else. It
  reads 0 today; it is there for the effect that one day floods the queue.
- **The probe.** Any future palette effect (the [hit light](HITLIGHT_PROTOTYPE.md)
  or a new cycle) can be profiled the same way.

## Reproduce

```powershell
python tools/run_palq_probe.py --rom-dir <rom dir> --map <map>
# the A/B needs the coalescer compiled in: palcoal .set 1, rebuild, then
python tools/run_palcoal_test.py --rom-dir <rom dir> --map <map>
```

## Files and evidence

- [Recorded results](palcoal_results.json): the corrected profile, the A/B,
  the callback check, and the invalid first profile, kept and labelled.
- [Probe](../../tools/palq_probe.lua), [profile runner](../../tools/run_palq_probe.py),
  [A/B runner](../../tools/run_palcoal_test.py).
