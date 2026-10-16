#!/usr/bin/env python3
"""gspa_stage.py - assemble with each module's OWN pruned MAINEQU.

WHY.  GSPA is a real-mode DOS assembler with ~630 KB to work in, and it aborts
with ">> Out of memory" in PASS 2 once a big module (MOVES, MKDRONE, MKDEATH,
BGND) holds too many symbols.  Every module includes MAINEQU.ASM, and MAINEQU
declares ~1,700 `.global` names - MOVES names 356 of them, and GSPA pays for
all 1,700.  Measured on MOVES (2026-10-11, a scratch lab): with the unused
globals stripped it takes 512 extra labels where the full header failed
between 128 and 256.  Near the edge GSPA's failure is NOT monotonic - two new
lines failed where sixteen copies of them passed - so the only cure is margin,
and this buys it for every module at once, and defuses MAINEQU's own cliff (a
new `.global` now costs only the modules that name it).

HOW.  Sources are mirrored into a stage directory; for each module to assemble
the stage's MAINEQU.ASM is swapped for a copy whose `.global`/`.globl` lists
keep only names that appear (case-insensitively) in the module or anything it
includes, and MAINEQU's own non-declaration text.  Dropping a declaration
nobody names cannot change the object's code.  GSPA searches the SOURCE FILE'S
directory first, so the swap has to happen in the stage, not through -i.
A module that fails for any reason other than memory is re-assembled with the
full MAINEQU and reported, so a pruning miss can never break a build.  The
OBJs are copied back; GMAKE then only links.

    from tools.gspa_stage import assemble
    assemble(src_dir, stage_dir, modules, dosbox, log_path)

    python tools/gspa_stage.py --verify     # rebuild every module staged in a
                                            # scratch tree, link, and require
                                            # mk2.out byte-identical to src's
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIRROR_EXT = {".ASM", ".TBL", ".GLO", ".HDR", ".H", ".EQU", ".INC", ".CMD", ".INI"}
INCLUDE_RE = re.compile(r'^\s+\.(?:include|copy)\s+"?([A-Za-z0-9_.\\/:]+)', re.I)
GLOBAL_RE = re.compile(r'^(\s+\.(?:global|globl)\s+)([^;]*?)(\s*;.*)?$', re.I)
WORD_RE = re.compile(r'[A-Za-z_$][A-Za-z0-9_$]*')
MEMORY_FAIL = "Out of memory"
BS = chr(92)
DOS_PATH = f"path=Z:{BS};C:{BS};T:{BS}"
DOS_TEMP = f"set TEMP=C:{BS}"
DOS_TMP = f"set TMP=C:{BS}"


def _read(p: Path) -> str:
    return p.read_text(encoding="latin-1", errors="replace")


def _find(src: Path, name: str):
    parts = name.replace("\\", "/").split("/")
    if len(parts) > 1:                          # "..\data\EDACID.ASM"
        q = (src / "/".join(parts)).resolve()
        return q if q.exists() else None
    name = parts[-1].lower()
    for p in src.iterdir():
        if p.name.lower() == name:
            return p
    return None


def _includes(src: Path, path: Path, seen: set):
    key = path.name.lower()
    if key in seen:
        return
    seen.add(key)
    yield path
    for line in _read(path).splitlines():
        m = INCLUDE_RE.match(line)
        if m:
            q = _find(src, m.group(1))
            if q and q.name.upper() != "MAINEQU.ASM":
                yield from _includes(src, q, seen)


def prune_mainequ(src: Path, module: str, mainequ_text: str) -> tuple[str, int]:
    """MAINEQU text keeping only the declarations `module` can name."""
    words = set()
    for p in _includes(src, src / f"{module}.ASM", set()):
        words.update(w.lower() for w in WORD_RE.findall(_read(p)))
    out, dropped = [], 0
    for line in mainequ_text.splitlines():
        m = GLOBAL_RE.match(line)
        if not m and not line.startswith("*"):
            words.update(w.lower() for w in WORD_RE.findall(line.split(";")[0]))
    for line in mainequ_text.splitlines():
        m = GLOBAL_RE.match(line)
        if m:
            names = [n.strip() for n in m.group(2).split(",") if n.strip()]
            keep = [n for n in names if n.lower() in words]
            dropped += len(names) - len(keep)
            out.append(m.group(1) + ",".join(keep) if keep else "*" + line[1:] if line[:1] else "*")
            continue
        out.append(line)
    return "\r\n".join(out) + "\r\n", dropped


def _mirror(src: Path, stage: Path):
    stage.mkdir(parents=True, exist_ok=True)
    for p in src.iterdir():
        if not p.is_file() or p.suffix.upper() not in MIRROR_EXT:
            continue
        q = stage / p.name
        st = p.stat()
        if q.exists():
            qs = q.stat()
            if qs.st_size == st.st_size and int(qs.st_mtime) == int(st.st_mtime) and p.name.upper() != "MAINEQU.ASM":
                continue
        shutil.copy2(p, q)
    # includes that reach outside src ("..\data\EDACID.ASM") are mirrored to
    # the same place relative to the stage
    for p in src.iterdir():
        if p.is_file() and p.suffix.upper() == ".ASM":
            for line in _read(p).splitlines():
                m = INCLUDE_RE.match(line)
                if m and ("\\" in m.group(1) or "/" in m.group(1)):
                    rel = m.group(1).replace("\\", "/")
                    a, b = (src / rel).resolve(), (stage / rel).resolve()
                    if a.exists() and a != b:
                        b.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(a, b)
    for p in stage.glob("*.OBJ"):
        p.unlink()
    for p in list(stage.glob("MC[YZ]*")) + list(src.glob("MC[YZ][0-9]*")):
        p.unlink()          # GSPA's temp macro libraries, left by an abort


def _run_dos(dosbox: str, stage: Path, tools: Path, lines: list[str]):
    bat = stage / "STAGEASM.BAT"
    bat.write_text("@echo off\r\n" + "\r\n".join(lines) + "\r\n", encoding="latin-1")
    conf = stage / "STAGE.CONF"
    conf.write_text("\r\n".join([
        "[sdl]", "fullscreen = false", "autolock = false",
        "[dosbox]", "memsize = 16",
        "[cpu]", "core = dynamic", "fpu = true", "cputype = auto", "cycles = max 105%",
        "[autoexec]", f"mount c \"{stage.parent}\"", f"mount t \"{tools}\"", "c:",
        DOS_PATH, DOS_TEMP, DOS_TMP, f"cd {stage.name}",
        "call STAGEASM.BAT", "exit"]) + "\r\n", encoding="latin-1")
    subprocess.run([dosbox, "-conf", str(conf), "-noconsole", "-exit"], cwd=str(stage),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _batch(mods, pruned: bool):
    lines = []
    for m in mods:
        lines.append(f"ECHO *----assembling----{m}.ASM >> STAGE.LOG")
        if pruned:
            lines.append(f"copy /y MEQ\\{m}.EQU MAINEQU.ASM > NUL")
        else:
            lines.append("copy /y MEQ\\_FULL.EQU MAINEQU.ASM > NUL")
        lines.append(f"GSPA {m} -H -v10 > {m}.ALG")
        lines.append(f"type {m}.ALG >> STAGE.LOG")
    return lines


def assemble(src: Path, stage: Path, modules: list[str], dosbox: str, log_path: Path,
             tools: Path = ROOT / "tools", quiet=False) -> list[str]:
    """Assemble `modules` (stems) from `src` into src/<stem>.OBJ.  Returns the
    modules that failed.  The GSPA output is appended to log_path."""
    # the stage is laid out like the repo - <stage>/src, with <stage>/data
    # beside it - because MKHANG includes "..\data\EDACID.ASM"
    src, stage = Path(src), Path(stage) / "src"
    _mirror(src, stage)
    meq_dir = stage / "MEQ"
    meq_dir.mkdir(exist_ok=True)
    full = _read(src / "MAINEQU.ASM")
    (meq_dir / "_FULL.EQU").write_text(full.replace("\r\n", "\n").replace("\n", "\r\n"), encoding="latin-1")
    for m in modules:
        text, _ = prune_mainequ(src, m, full)
        (meq_dir / f"{m}.EQU").write_text(text, encoding="latin-1")
    (stage / "STAGE.LOG").write_text("", encoding="latin-1")

    def run(mods, pruned):
        for m in mods:
            for ext in (".OBJ", ".ALG"):
                (stage / f"{m}{ext}").unlink(missing_ok=True)
        _run_dos(dosbox, stage, tools, _batch(mods, pruned))
        res = {}
        for m in mods:
            alg = stage / f"{m}.ALG"
            out = _read(alg) if alg.exists() else ""
            ok = (stage / f"{m}.OBJ").exists() and "No Errors" in out and MEMORY_FAIL not in out
            res[m] = (ok, out)
        return res

    res = run(modules, True)
    retry = [m for m, (ok, out) in res.items() if not ok and MEMORY_FAIL not in out]
    if retry:
        print(f"  gspa_stage: {len(retry)} module(s) failed PRUNED for a reason other than "
              f"memory - re-assembling with the full MAINEQU: {', '.join(retry)}")
        res.update(run(retry, False))
    failed = [m for m, (ok, _) in res.items() if not ok]
    with open(log_path, "a", encoding="latin-1") as f:
        f.write(_read(stage / "STAGE.LOG"))
    for m, (ok, _) in res.items():
        if ok:
            shutil.copy2(stage / f"{m}.OBJ", src / f"{m}.OBJ")
            (src / f"{m}.OBJ").touch()
    (stage / "MAINEQU.ASM").write_bytes((src / "MAINEQU.ASM").read_bytes())
    return failed


def modules_to_assemble(src: Path) -> list[str]:
    """What GMAKE would assemble: OBJ missing or older than its ASM (include
    staleness is Phase C0's job, which deletes the OBJ)."""
    mk = _read(src / "MAKEFILE")
    objs = re.findall(r"^\s*([A-Za-z0-9_]+)\.OBJ\b", mk, re.M | re.I)
    out = []
    for stem in dict.fromkeys(o.upper() for o in objs):
        asm, obj = src / f"{stem}.ASM", src / f"{stem}.OBJ"
        if not asm.exists():
            continue
        if not obj.exists() or obj.stat().st_mtime < asm.stat().st_mtime:
            out.append(stem)
    return out


def _verify():
    """Assemble EVERY module staged in a scratch copy, link, compare mk2.out."""
    sys.path.insert(0, str(ROOT))
    import build
    dosbox = str(build.get_dosbox_path())
    ref = ROOT / "src" / "mk2.out"
    if not ref.exists():
        sys.exit("src/mk2.out missing - build first")
    scratch = ROOT / "tmp" / "gspa_verify"
    if scratch.exists():
        shutil.rmtree(scratch)
    (scratch / "src").mkdir(parents=True)
    (scratch / "data").mkdir()
    for p in (ROOT / "src").iterdir():
        if p.is_file() and (p.suffix.upper() in MIRROR_EXT or p.name.upper() == "MAKEFILE"):
            shutil.copy2(p, scratch / "src" / p.name)
    for f in ("ART.OUT",):
        shutil.copy2(ROOT / "data" / f, scratch / "data" / f)
    for p in (ROOT / "data").glob("ED*.ASM"):           # MKHANG's ..\data includes
        shutil.copy2(p, scratch / "data" / p.name)
    mods = modules_to_assemble(scratch / "src")
    print(f"verify: assembling {len(mods)} modules staged ...")
    failed = assemble(scratch / "src", scratch / "stage", mods, dosbox, scratch / "build.log")
    if failed:
        sys.exit(f"verify: FAILED to assemble {failed}")
    conf = scratch / "link.conf"
    conf.write_text("\r\n".join(["[dosbox]", "memsize = 16", "[cpu]", "core = dynamic",
                                 "cycles = max 105%", "[autoexec]", f"mount c \"{scratch}\"",
                                 f"mount t \"{ROOT / 'tools'}\"", "c:", DOS_PATH,
                                 DOS_TEMP, DOS_TMP, "cd src",
                                 r"gmake -m > ..\link.log", "exit"]) + "\r\n")
    subprocess.run([dosbox, "-conf", str(conf), "-noconsole", "-exit"], cwd=str(scratch),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    new = scratch / "src" / "mk2.out"
    if not new.exists():
        sys.exit("verify: link failed - see " + str(scratch / "link.log"))
    a, b = ref.read_bytes(), new.read_bytes()
    a, b = a[:4] + a[8:], b[:4] + b[8:]         # bytes 4-7: the COFF link timestamp
    if a == b:
        print(f"verify: PASS - mk2.out byte-identical but for the link timestamp ({len(a) + 4:,d} bytes)")
    else:
        diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
        sys.exit(f"verify: FAIL - mk2.out differs ({len(a):,d} vs {len(b):,d} bytes, {diff} bytes differ)")


if __name__ == "__main__":
    if "--verify" in sys.argv:
        _verify()
    else:
        print(__doc__)
