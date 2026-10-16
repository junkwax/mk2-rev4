# Community packs, and the public repo that can hold them

**The problem this solves.** The build lives on a leaked Midway source tree.
That tree can never be public. But the *decisions* made on top of it — this
move reaches too far, that one whiffs point blank, this uppercut should chip
for less — are the part a community actually wants to argue about, and none
of that argument requires a line of Midway code.

So the split is: **the numbers travel, the source does not.**

A *pack* is a file of numbers and neutral names. It can sit in a public
GitHub repo, be opened as a pull request, be reviewed by people who have
never seen the source, and be applied by whoever holds the private build.

> **Not legal advice.** Everything below reduces exposure; nothing here
> eliminates it. Warner Bros. owns Mortal Kombat, and a public project that
> uses the name, the characters, or the art draws attention on *trademark*
> grounds regardless of how careful the copyright line is. If this goes
> public and matters, have a lawyer look at it.

---

## The line

**Never in a public repo:**

| | why |
|---|---|
| `src/` — any `.ASM`, `.TBL`, `.GLO`, `.HDR` | Midway's code, verbatim |
| `data/` — `.IMG`, `.IRW`, `.LOD`, `.BDB`, `.BDD` | Midway's art |
| `sound/`, `rom/`, `mk2.zip`, any ROM or ROM fragment | Midway's code and audio |
| `tools/` DOS binaries (GSPA, GSPLNK, GMAKE, LOAD2) | Texas Instruments' and Midway's, separately licensed |
| screenshots and sprite rips | Midway's art, even in a bug report |
| links to any of the above | pointing at it is its own problem |

**Fine in a public repo:**

| | why |
|---|---|
| `tools/hitbox_pack.py`, `tools/hitbox_edit.py` | ours, written from scratch |
| packs (`.json` / `.csv`) | numbers and names we assign |
| documentation we wrote | ours, as long as it does not quote source |
| the review workflow, CI, issue templates | ours |

**The grey band, and what `--public` does about it.** A pack exported
normally carries names lifted from the leak - `symbol` (`stk_lkhikick`),
`sound` (`sf_squeeze`), and two less obvious ones covered under `audit`
below. Short functional identifiers are weak copyright material, but they
are the only part of a pack that came from someone else's file, so there is
a switch that removes them:

```
python tools/hitbox_pack.py export --public
```

What is left is `liu-kang/hikick` — an id **this tool generates**, which it
can resolve back to the record on the private side without the pack ever
naming it. Public packs should always be `--public`. Local ones need not be.

---

## What a pack contains

228 strike records, each one a box, a damage pair, a reaction pair and a
score. The field names are deliberately not the ASM's, because the ASM's
mislead:

```json
{
  "id": "liu-kang/hikick",
  "character": "Liu Kang",
  "front": 94, "y": 5, "width": 69, "height": 23,
  "hit": 32, "block": 8,
  "hit_reaction": 0, "block_reaction": 0,
  "score": 0
}
```

* `front` is the **front edge** — how far the box reaches. Bigger = more reach.
* `width` extends **backwards** from `front`, toward the attacker. It is not
  reach. Raising it thickens the move behind the tip; it does not lengthen it.
* `y` is the top edge measured **down** from the anipoint, `height` goes down
  from there.
* `hit` / `block` are the two halves of one packed damage word, split because
  nobody edits it packed. Same for `hit_reaction` / `block_reaction`.

**Reach is not range**, and this is the single thing most likely to make a
proposal wrong. The victim is squeezed to a **quarter** of his sprite width
before the compare, centred on his anipoint, so a move connects out to about
`front + victim_width/8` and no further. A box widened by 20px does not buy
20px of range. See [HITBOX_MODEL.md](HITBOX_MODEL.md).

Some records are shared. `johnny-cage/zap1` through `zap4` are four names
stacked over **one** body: the pack lists the other three under `aliases`
(as neutral ids, never as raw labels), and editing any of them moves all
four. Records used by more than one character carry
`"shared": true`. Neither is a bug to be fixed; both are things a reviewer
has to know before approving a change.

Every pack also carries a `base_digest` — a fingerprint of the values it was
authored against. If a pack was written against a build that has since moved,
`validate` says so, and the diff shows exactly what that means.

---

## The commands

```
python tools/hitbox_pack.py export                  # everything, as JSON
python tools/hitbox_pack.py export --format csv     # a spreadsheet
python tools/hitbox_pack.py export --public         # no leaked symbols
python tools/hitbox_pack.py validate pack.json      # is it well formed
python tools/hitbox_pack.py audit pack.json         # any leaked source names
python tools/hitbox_pack.py diff pack.json          # what would it change
python tools/hitbox_pack.py import pack.json        # dry run, prints the diff
python tools/hitbox_pack.py import pack.json --apply
```

Two properties worth relying on:

* **Export → import is a no-op.** A freshly exported pack diffs to nothing.
* **Apply then revert is byte-identical.** Values are written back in the
  style they were written in — the same base, width and letter case — so
  reverting a pack leaves `git diff` empty rather than a wash of reformatting.
  (This matters more than it sounds: it means "try it, then put it back" is
  actually free.)

`audit` is the guard on the copyright line, and it exists because the first
`--public` export leaked three things. `symbol` and `sound` are the two
anyone would think of; `aliases` quietly carried the raw labels, and a
symbolic `score` (`sc_1000`) hid from a filter that only looked at those two
field names. So `audit` ignores field names entirely and checks **every
string in the file** for the shape of an assembler symbol. It exits non-zero
if it finds one, which makes it a CI gate rather than a habit.

`validate` and `audit` are the two commands that **run without the game
source** — deliberately, because that is what a public repo's CI has to run
on a stranger's pull request. With no source present, `validate` checks
shape, id format, duplicates and ranges, and says plainly that it could not
check ids against a build.

---

## The public repo

```
mk2-tournament-packs/
├── README.md                     what a pack is, how to propose one
├── LICENSE                       ours to choose - the tools are our code
├── tools/
│   ├── hitbox_pack.py
│   └── hitbox_edit.py            (imported by the above)
├── packs/
│   ├── baseline/current.json     what the build ships today (--public)
│   ├── proposals/                one file per open idea
│   └── accepted/                 merged, with the build they landed in
├── docs/
│   ├── HITBOX_MODEL.md           written from scratch, no source quotes
│   └── REVIEW.md                 what a reviewer checks
└── .github/
    ├── workflows/validate.yml
    └── PULL_REQUEST_TEMPLATE.md
```

`packs/baseline/current.json` is the anchor. A proposal is a copy of it with
some values changed, so the diff GitHub renders **is** the balance change —
readable by anyone, no tooling required.

### CI that needs no source

```yaml
name: validate packs
on: [pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - name: Validate every pack
        run: |
          for f in packs/proposals/*.json packs/accepted/*.json; do
            [ -e "$f" ] || continue
            echo "== $f"
            python tools/hitbox_pack.py validate "$f"
            python tools/hitbox_pack.py audit "$f"
          done
```

That is the whole trick: the same script that applies packs on the private
side validates them on the public side, and the public side never holds
anything it should not.

---

## Suggest → test → approve

**1. Suggest.** A contributor edits `packs/baseline/current.json` (or the CSV
in a spreadsheet), saves it as `packs/proposals/<handle>-<what>.json`, and
opens a PR. The PR template asks for the three things a reviewer cannot get
from the diff:

> * **What changes** — which moves, and in which direction.
> * **Why** — the problem being fixed, stated as behaviour, not as a number.
>   "Jax's high kick whiffs at ranges where it visibly connects" beats
>   "front should be 96".
> * **How to see it** — the matchup, spacing and input that shows the problem.

**2. Auto-check.** CI validates shape and ranges. It cannot say whether the
change is *good* — no build, no ROM.

**3. Test.** A maintainer with the private tree:

```
python tools/hitbox_pack.py diff  packs/proposals/x.json    # read it first
python tools/hitbox_pack.py import packs/proposals/x.json --apply
python tools/balance_lock.py                                # re-bless: these
                                                            # values are locked
python build.py --asm-only && python makerom.py && python mamerom.py --source-video
```

then the gates that decide whether it ships:

| check | what it catches |
|---|---|
| `tools/run_battle_stability_sweep.ps1` | crashes, wedges, camera faults |
| `tools/run_behaviour_check.ps1` | the ten behaviours that must not move |
| `tools/hitbox_overlay_test.lua` (`f_colbox=5`) | the box against the sprite, on the frame it is parked |
| `tools/box_align_audit.py` | a box that no longer overlaps its own art |

The overlay is the one to post back on the PR. A hitbox argument settled with
a picture of the hitbox is settled; one settled with two people's memories is
not.

**4. Approve.** Merge to `packs/accepted/`, and the tournament ruleset cites
the pack and its digest. That is the whole point of the digest: "we played
`kang-hikick-v2`, digest `9e142d8c`" is checkable, and "we played the version
with the Liu Kang fix" is not.

Reverting is cheap and byte-identical, so an accepted pack that plays badly
costs one command to take back out.

---

## What this covers, and what it does not

**Covered today:** every strike box — reach, box shape, damage on hit and on
block, the reaction pair, score. 228 records, the whole cast plus projectiles
and shared records.

**Not covered yet**, each of which already has a local editor that a pack
format could be extended to wrap:

| | tool | why it is not in the pack yet |
|---|---|---|
| move timing (startup, active, recovery) | `frame_edit.py` | edits machine-code immediates, not a table — the unit is a source line, not a record |
| special-move inputs | `combo_edit.py` | 91 combo records, a clean table; the natural next pack |
| walk / jump / gravity | `balance_lock.py` reads them | scattered across several files |
| hurtboxes | — | **not authored anywhere.** The hurt box is computed from the sprite, so it changes only when the art changes. `doc/hurtbox.lock` freezes it so an art edit cannot move it silently. There is nothing to put in a pack. |

Inputs are the obvious next one: `combo_edit.py` already has the records, and
"which motion does this move want" is exactly the kind of thing a community
argues about productively.
