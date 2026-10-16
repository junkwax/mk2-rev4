# Session handoff — sharing this tree with another live session

Read this before your first build if anyone else may be working in
`mk2-main` right now. It is not about git. It is about the fact that two
sessions in this tree share one DOS toolchain, one set of `.OBJ` files, one
`mk2.out` and one installed `mk2.zip` — **none of which git tracks**, so
`git status` will never tell you a peer has clobbered your build.

Written the day two sessions collided over it (2026-09-27); the worked
example at the bottom is that collision. It is not a two-party problem —
`ListAgents` that afternoon showed **five live sessions in this tree and two
more in `midway-imgtool`**, which is the repo that saves the `.IMG` art
Phase A consumes. Assume you are not alone unless you have checked.

---

## The three rules

1. **One session holds the toolchain at a time.** "The toolchain" is any run
   of `build.py`, `build_all.py`, `makerom.py`, `makevrom.py`,
   `makesound.py`, `mamerom.py`, `burnfix.py`, or **a rig that reads the
   installed `C:\MAME\roms\mk2.zip`**. Claim it before you start (below),
   release it when you stop.

   **A rig pointed at `mk2-main\rom` is on the toolchain too.** Several rigs
   pass `-RomPath C:\Users\you\Workplace\mk2-main\rom` rather than reading
   the installed zip — and `makerom.py` rewrites exactly those files. A
   capture that overlaps a `makerom` run has loaded who-knows-which ROM and
   is evidence of nothing. Either finish the build before starting rigs, or
   freeze a pair (below).

   **A rig on a frozen pair is not the toolchain and does not claim the
   baton.** A rig that runs headless against its own copied
   zip + `mk2.map` + move list (e.g. `C:\tmp\flybrain\rom37`), with its own
   `-Out` dir and private cfg/nvram, contends for nothing: not the zip, not
   `mk2.out`, not the `.OBJ` set. Those legitimately run for hours and must
   not block the tree. Freeze the **map with the zip** — a zip paired with
   another build's map reads every symbol at the wrong address and reports
   nothing wrong.
2. **Do not edit `src/` while someone else holds it.** Your unassembled edit
   lands in *their* Phase C, and a failure then belongs to nobody. This is
   the rule that matters most — it costs you nothing to wait a minute, and
   it is the only thing that keeps a GSPA error attributable.
3. **Declare what you have edited but not yet assembled**, every time you
   hand over or pick up. A peer running Phase C is testing your files for
   free; they can only tell you what happened if they know which ones are
   yours.

---

## Claiming the toolchain

The baton is one file, `tmp/session/TOOLCHAIN`. `tmp/` is gitignored, so
none of this is ever committed.

```
OWNER: mk2-main-f0
PIPE:  uds:\\.\pipe\LOCAL\cc-msg-71cc6cd028ab6b2aa707e2cda032cf54
SINCE: 2026-09-27 19:52
DOING: build.py --asm-only + makerom + mamerom (INSTALLS to C:\MAME\roms\mk2.zip)
```

- **Before you claim**, read the file. If it exists and names someone else,
  message them (`SendMessage` to their `PIPE`) and wait. Do not start.
- **`DOING:` says whether you install.** A run that overwrites
  `C:\MAME\roms\mk2.zip` invalidates any rig a peer has mid-flight, so say
  so and give them a chance to object.
- **Delete the file when you are done.** An owner who finishes and leaves
  the baton lying there is the most common way this protocol rots.
- **Stale baton:** `SINCE` more than 30 minutes old *and* no answer to a
  message = take it, and record `TOOK-OVER-FROM:` in the new file so the
  original owner can see what happened. A full `build.py` with LOAD2 runs
  several minutes; `--asm-only` about a minute; a MAME rig can legitimately
  run much longer, which is why the rule needs the unanswered message and
  not just the clock.
- **No peer messaging available?** The baton file alone is still the
  protocol. Write it, read it, honour it.

## Declaring your work

One file per session, written only by that session, so there is no
shared-write contention: `tmp/session/<your-name>.md`.

```markdown
# mk2-main-f0 — drone costume palettes
UNASSEMBLED (mine if Phase C dies here):
  src/MKGUYS.ASM   drone_costume_pick, costume_lane_pal_oc
  src/MAINEQU.ASM  dronecos .set 1, .global dcos_for/dcos_rand
  src/RAM.ASM      two .bss words
PHASE D: RED — data/MK2PALS.IMG newer than src/COSTPAL.ASM.
  Fix is `python tools/make_costume_palettes.py --apply`, and it is MINE to run.
HOLDING: nothing / C:\MAME\roms\mk2.zip until my rig finishes
```

Keep it to what a peer needs in order to attribute a failure and to avoid
undoing your work. It is not a journal.

`ls tmp/session/` is also how you find out who exists without asking
`ListAgents` — and how a session with no peer messaging at all finds out.

## The art side: `data/*.IMG` and the `midway-imgtool` sessions

A session in `midway-imgtool` saving a library into `data/` is editing this
build's inputs, and it will not be watching `mk2-main`'s baton. Two
consequences:

- **A `.IMG` saved mid-build is an input changing under Phase A.** If you
  are about to run a full `build.py` (LOAD2), check `data/*.IMG` mtimes for
  anything saved in the last few minutes.
- **Nothing promotes an IMG palette into the ROM by itself.** A library
  saved in IMGTOOL leaves the generated `.ASM` behind it until the owning
  tool is re-run (`make_costume_palettes.py --apply`,
  `sync_alt_costume_palettes.py`, and the rest of the Phase D `--check`
  list). That gap is a RED Phase D gate that belongs to whoever owns the
  art, not to whoever happened to start the build — so it is a ping, not a
  fix you make for them.

---

## What is actually shared

| Shared | Tracked by git? | How a peer's run hurts you |
|---|---|---|
| The DOSBox toolchain | — | Two concurrent runs interleave in the same DOS session |
| `src/*.OBJ` | no (gitignored) | Theirs replaces yours; `git status` stays silent |
| `src/mk2.out`, `src/mk2.map` | no | **Deleted at the start of every link** (`build.py:544`) |
| `build.log` | no | Overwritten — the log you are reading may be theirs |
| `data/*.IRW` | no | A full `build.py` (Phase A/LOAD2) rewrites all of them |
| `rom/*`, `C:\MAME\roms\mk2.zip` | no | Installed over; your rig is now testing their ROM |
| `tmp/load2/` | no | Table snapshots every promoter reads |

**A build rewrites `src/*.ASM`.** Phase B promoters own parts of several
files (`make_costume_palettes.py --apply` rewrites `MKGUYS.ASM` and
`COSTPAL.ASM`, `sync_inline_sags.py`, the WAX importers, the stage
generators). So "nobody opened my file" does not mean nobody wrote it, and a
file whose mtime jumped during someone else's build is not necessarily
evidence of a hand edit. Check your own block is still there; do not assume.

**`MAINEQU.ASM` is one line below a GSPA cliff — and the cliff is the
INCLUDE, not the module.** Two measurements, from two sessions on the same
day:

| change | result |
|---|---|
| ~20 lines added to `MAINEQU.ASM` | `MKDEATH.ASM` aborts, `Out of memory`, nothing links |
| ~14 lines added to `MKDEATH.ASM` itself, plus a `.set` | assembles clean |

MAINEQU is `.include`d by 61 of the 105 `.ASM` files, so a line there is
assembled ~70 times over: **growth in the shared include costs roughly 70×
growth in a module.** MKDEATH (7,245 lines) is simply the biggest object and
so the first to fall over — it still has room of its own. What it has no
room for is anyone growing MAINEQU.

Read that the right way round. "MKDEATH is at the cliff" would send the next
session to restructure the wrong file. Changing the VALUE of an existing
equate is always free; **adding** to MAINEQU is what costs, and prose belongs
in `doc/`, not in an include. A/B any MAINEQU addition with
`gspa MKDEATH -H -v10` in a scratch tree before you trust a build.

If a module genuinely will not take more, the tree's precedent is a new
object — `src/MKLKDK.ASM` exists because Liu Kang's chain would not fit in
MOVES.ASM — but measure before assuming you need one.

**Shared includes are the contagion path.** `MAINEQU.ASM` is included by 61
of the 105 `.ASM` files, `DISPEQU.ASM` by 52, `SYSEQU.ASM` by 50,
`MACROS.HDR` by 55. `remove_stale_include_objects` (`build.py:158`) compares
mtimes and deletes every `.OBJ` older than an include it depends on — so the
moment a peer touches `MAINEQU.ASM`, their in-flight edit is in *your* next
binary and most of the tree reassembles. `RAM.ASM` is included by nothing:
it is its own compilation unit, which is why a new `.bss` word there is
invisible until `MAINEQU.ASM` exports it with `.global`.

---

## Gates that fail for everybody, not just you

Some Phase D checks compare a generated lock file against source. Break one
and **every session in the tree** is red until it is regenerated — including
sessions that never touched the area.

| If you change | Regenerate with | Never |
|---|---|---|
| a strike record in `MKSTK.ASM` | `python tools/balance_lock.py` | revert `doc/balance.lock` — it may legitimately differ from HEAD because a record was removed |
| a hitbox that changes a sprite's reach | `doc/hurtbox.lock` per its tool | assume the old lock still describes the art |
| a record/palette name in an IMG | `tools/check_img_names.py --write` | re-baseline to silence a collision you did not intend |
| a palette authored in `data/*.IMG` | the owning `--apply` tool | hand-edit the generated `.ASM` |

A dirty lock file is not automatically stale — it may be exactly what the
current source needs, with HEAD being the wrong one. Ask the owner before
"fixing" it.

## Adding a new object (the usual answer to the MKDEATH cliff)

When a file will not take any more code, the tree's answer is a new object —
`src/MKLKDK.ASM` exists because Liu Kang's chain aborted MOVES.ASM with
`Out of memory`. Two registrations, and **missing the second one fails
silently**:

1. `src/MAKEFILE` (e.g. `MKLKDK.OBJ \` at line 26) — miss this and it never
   assembles.
2. `src/mk2.cmd` (e.g. `MKLKDK.OBJ` at line 16) — **miss this and it
   assembles cleanly and is never linked**, so every reference to it
   resolves to nothing.

Reach it with `jauc` / `jsrp`, which are absolute. A conditional branch
(`jreq`/`jrne`/…) is PC-relative and **GSPLNK wraps a cross-object overflow
without a word of complaint** — the shape to copy is a conditional branch
*over* a `jauc`, never a conditional branch *at* the far label
(MOVES.ASM:8409 spells this out at the call site). `tools/check_pcrel_range.py
--check` in Phase D is the net, but it is a thin one: on tonight's build it
checked **two** cross-object PC-relative branches in 70 linked objects. A pass
means almost nothing branches that way, not that your calls were examined.

## Reading a failure that is not yours

- **Phase C names a file.** Check the peer's `UNASSEMBLED` list first. Do not
  debug it, do not fix it — ping them. A half-finished change looks exactly
  like a bug, and "fixing" it collides with the edit they are mid-way
  through.
- **Undefined symbol in a file you never touched** is the classic shape of a
  peer's in-flight work: a `.bss` word declared in `RAM.ASM` with no
  `.global` in `MAINEQU.ASM` yet.
- **Phase D exits on the FIRST failure.** Later checkers never run, so a red
  gate tells you about one thing only — and if that one thing is the peer's,
  your own gates are still unproven.
- **A green build proves nothing about your source** if the peer edited a
  shared include after your last assembly: check `build.log` for your files
  by name, not just the final exit code.

## Things that look like a peer stomping you and are not

| Looks like | Actually |
|---|---|
| `src/DIAGMENU.ASM` modified after every build | `update_rom_name` (`build.py:72`) stamps the build id into `rom_name` on every run. Never commits clean. |
| `src/mk2.out` / `src/mk2.map` missing | Deleted at the start of the link. Absent means a build started or aborted — **not** that one is running, and **not** that nobody is building. |
| `mk2.zip` chips differ from `rom/*.bin` | `crc_spoof.spoof_zip()` rewrites 4 bytes of each chip's tail padding, every repackage. Byte-diff and confirm the differences sit in that window; hashing is not a staleness check. |
| Objects not reassembling after an edit | DOSBox clock skew against the host mtime. Not a peer. |
| Your uncommitted edits inside someone's commit | A peer committing `-a` sweeps the whole tree. Real, and the reason to say what you are holding. |

---

## Message templates

**Claiming**

> Taking the toolchain for `<command>`, ~`<duration>`. Installs to
> `C:\MAME\roms\mk2.zip`: yes/no. Shout now if you need the current zip.
> Unassembled and mine: `<files>`.

**Releasing**

> Off the toolchain, baton deleted. What I ran: `<command>`. Result:
> `<pass/fail>`. Your files in that pass: `<file>` → `<result>`.
> Installed: yes/no.

**Failure that belongs to the other session**

> Phase C died on `<file>`, `<n>` errors: `<the exact GSPA lines>`. That is
> in your UNASSEMBLED list, so I have not touched it. Toolchain is yours /
> free.

Quote the assembler verbatim. "It failed on MKGUYS" costs a round trip;
`AN IDENTIFIER IN THE EXPRESSION IS INVALID … dcos_rand, dcos_for` is
diagnosable on sight.

---

## Worked example — 2026-09-27

Two sessions, no protocol. Session A (tester-feedback triage) edited five
files and ran `build.py --asm-only`. Session B (`mk2-main-f0`) was mid-way
through a drone-costume change touching `MKGUYS.ASM`, `MAINEQU.ASM` and
`RAM.ASM`.

What happened, in order:

1. A's build deleted `src/mk2.out` and `src/mk2.map`, then aborted in Phase
   C on **B's** `MKGUYS.ASM`: `dcos_rand`, `dcos_for` undefined — B had
   declared them in `RAM.ASM` and not yet exported them.
2. A spent time diagnosing a file A had never opened.
3. B saw `mk2.out` and `mk2.map` missing and could not tell whether A was
   building right now or had already stopped — the two states look
   identical.
4. B's own Phase D gate was red for an unrelated reason and B was holding
   off on the fix, because rewriting `MKGUYS.ASM` under a live Phase C would
   make any failure unattributable between them.

It resolved in two messages: A said "off the toolchain, and here are the
five files of mine that have never been through GSPA — if Phase C dies on
MKSLAM or MKZAP it is mine"; B said "fixed my `.global`, taking the
toolchain, your two files ride along in my Phase C and I will tell you what
they do."

Every rule above is one of those four steps, written down so the next pair
does not have to discover it.
