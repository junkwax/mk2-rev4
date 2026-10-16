#!/usr/bin/env python3
"""Emit a MAME debugscript that pins the character-select hang.

The hang is `cmovea` in cmove9 (MKSEL.ASM:1644): `ochar_to_menu` is an
unchecked index into a 12-entry table, so a hidden fighter's ft_* (ft_jade
16 -> 0ff90h, ft_rain 19 -> 0ff83h) comes back NEGATIVE and the dsjs walk of
the mugshot oslink chain runs ~4.3 billion times.

Trace: every write to p1_char / p2_char with the writer's PC (these continue).
Break: the first entry to ochar_to_menu with an out-of-range ochar -- it HALTS
there, before the spin, so the state is intact.  The trace above the halt says
which routine committed the hidden ft_* and when.

Addresses come from src/mk2.map, so this tracks the build.
Debugger convention (CLAUDE.md): bpset/wpset take raw BIT addresses and BIT
lengths; w@ takes byte addresses (bit/8).  Debugger numbers are HEX.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAP  = ROOT / "src" / "mk2.map"
OUT  = ROOT / "tmp" / "psel_hang.ds"

WANT = ["ochar_to_menu", "p1_char", "p2_char", "p1_state", "p2_state", "gstate",
        "f_jade_cheat1", "f_jade_cheat2", "f_rain_cheat1", "f_rain_cheat2",
        "f_ermac_cheat1", "f_ermac_cheat2", "f_smoke_cheat1", "f_smoke_cheat2",
        "f_noob_cheat1", "f_noob_cheat2", "f_kham_cheat1", "f_kham_cheat2"]

sym = {}
for line in MAP.read_text(errors="replace").splitlines():
    for a, n in re.findall(r"([0-9a-f]{8})\s+([A-Za-z_][\w.]*)", line):
        sym.setdefault(n, int(a, 16))

missing = [n for n in WANT if n not in sym]
if missing:
    sys.exit("not in mk2.map: " + ", ".join(missing))

bit  = lambda n: sym[n]
byte = lambda n: sym[n] >> 3

# shared tail: who is where
ST_FMT = "gs=%d p1s=%d p2s=%d p1c=%d p2c=%d"
ST_ARG = "w@%x,w@%x,w@%x,w@%x,w@%x" % (byte("gstate"), byte("p1_state"),
                                       byte("p2_state"), byte("p1_char"),
                                       byte("p2_char"))
FLAGS = ("jade=%d/%d rain=%d/%d ermac=%d/%d smoke=%d/%d noob=%d/%d kham=%d/%d",
         ",".join("w@%x" % byte(n) for n in
                  ["f_jade_cheat1", "f_jade_cheat2", "f_rain_cheat1", "f_rain_cheat2",
                   "f_ermac_cheat1", "f_ermac_cheat2", "f_smoke_cheat1", "f_smoke_cheat2",
                   "f_noob_cheat1", "f_noob_cheat2", "f_kham_cheat1", "f_kham_cheat2"]))

L = ["// psel hang probe -- tools/gen_psel_hang_ds.py",
     "//   p1_char %08x   p2_char %08x   ochar_to_menu %08x"
     % (bit("p1_char"), bit("p2_char"), bit("ochar_to_menu")),
     "//   resolve any pc with:  python sym_resolve.py <pc>",
     ""]

L += ["// --- trace: every write to the select chars, with the writer's PC ---"]
for n in ("p1_char", "p2_char"):
    L.append('wpset %x,10,w,1,{printf "%s <= %%d  pc=%%08X  %s",wpdata,pc,%s; g}'
             % (bit(n), n, ST_FMT, ST_ARG))

L += ["",
      "// --- halt: ochar_to_menu indexed past its 12-entry table (ffff = 'not in') ---",
      'bpset %x,a0>0b&&a0!=ffffffff,{printf "*** BAD OCHAR %%d  sp=%%08X  %s",a0,sp,%s; printf "    %s",%s}'
      % (bit("ochar_to_menu"), ST_FMT, ST_ARG, FLAGS[0], FLAGS[1]),
      ""]

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(L) + "\n")
print("wrote", OUT, "\n")
print("\n".join(L))
