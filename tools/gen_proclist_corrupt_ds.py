#!/usr/bin/env python3
r"""Emit a MAME debugscript that catches whoever corrupts the process list.

On 2026-09-23 a 1P game froze on the way into the first match.  The PC was in
sucide's walk of the active list (MPROC.ASM suclp), with a1 = 7E7E7E7E (the
link it had just loaded - not a mapped address) and a13 = 44D42131 (the dying
process itself).  The proclock_fix branch does not rescue that: it ends the
pass when the list runs out at a link of 0, and this list never reaches 0, so
the walk spins with every process stopped.

By the time sucide reads a bad link the writer is long gone, so this watches
the two list heads and halts on the WRITE that first puts a non-RAM value in
one.  Anything outside SCRATCH (01000000..013F7300, per src/mk2.map) is bad;
0 is legal and means end-of-list.

Also traced, because both are silent and both are suspects near a stage load:
  sucide_lost - a process that ended without being on the active list
  palq_drops  - a palette transfer lost to a full queue.  Its ring ends at
                010B2240 and `active` starts at 010B2250, so a queue that
                ran over its end would land exactly on the head.

    python tools/gen_proclist_corrupt_ds.py
    pwsh tools/run_mame_small.ps1 -Debug -DebugScript tmp\proclist_corrupt.ds

Then play into the match that froze.  On a halt, `print pc` names the writer;
resolve it with python sym_resolve.py <pc> (repo root, not tools/).

Debugger convention (CLAUDE.md): bpset/wpset take raw BIT addresses and BIT
lengths; w@ takes byte addresses (bit/8).  Debugger numbers are HEX.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAP  = ROOT / "src" / "mk2.map"
OUT  = ROOT / "tmp" / "proclist_corrupt.ds"

WANT = ["active", "free", "sucide_lost", "palq_drops", "gstate",
        "p1_char", "p2_char"]

sym = {}
for line in MAP.read_text(errors="replace").splitlines():
    for a, n in re.findall(r"([0-9a-f]{8})\s+([A-Za-z_][\w.]*)", line):
        sym.setdefault(n, int(a, 16))

missing = [n for n in WANT if n not in sym]
if missing:
    sys.exit("not in mk2.map: " + ", ".join(missing))

bit  = lambda n: sym[n]
byte = lambda n: sym[n] >> 3

# SCRATCH from the MEMORY CONFIGURATION block: a process node lives here or
# the link is 0.  Kept as a literal pair so the condition reads plainly.
RAM_LO, RAM_HI = 0x1000000, 0x13f7300
BAD = "wpdata!=0&&(wpdata<%x||wpdata>%x)" % (RAM_LO, RAM_HI)

ST_FMT = "gs=%d p1c=%d p2c=%d"
ST_ARG = "w@%x,w@%x,w@%x" % (byte("gstate"), byte("p1_char"), byte("p2_char"))

L = ["// process-list corruption probe -- tools/gen_proclist_corrupt_ds.py",
     "//   active %08x   free %08x   sucide_lost %08x   palq_drops %08x"
     % (bit("active"), bit("free"), bit("sucide_lost"), bit("palq_drops")),
     "//   halts on the first non-RAM link written to a list head",
     "//   resolve any pc with:  python sym_resolve.py <pc>",
     ""]

L += ["// --- halt: a list head takes a link that is not RAM and not 0 ---"]
for n in ("active", "free"):
    L.append('wpset %x,20,w,%s,{printf "*** %s <= %%08X  pc=%%08X  a13=%%08X  %s",wpdata,pc,a13,%s}'
             % (bit(n), BAD, n, ST_FMT, ST_ARG))

L += ["",
      "// --- trace: the two silent counters, so a run says whether they moved ---",
      'wpset %x,10,w,1,{printf "sucide_lost <= %%d  pc=%%08X  %s",wpdata,pc,%s; g}'
      % (bit("sucide_lost"), ST_FMT, ST_ARG),
      'wpset %x,10,w,1,{printf "palq_drops <= %%d  pc=%%08X  %s",wpdata,pc,%s; g}'
      % (bit("palq_drops"), ST_FMT, ST_ARG),
      ""]

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(L) + "\n")
print("wrote", OUT, "\n")
print("\n".join(L))
