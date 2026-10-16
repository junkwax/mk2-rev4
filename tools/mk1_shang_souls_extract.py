#!/usr/bin/env python3
r"""Extract MK1's "Shang Tsung defeated - the souls escape" sequence from mk.zip.

Everything here is read out of `C:\MAME\roms\mk.zip` (the rev 5.0 T-unit MK1
set), not remembered: the lanes, the art, the palettes and the timings.  The
timings come from the immediates in MK1's own routine, and each one is checked
against its opcode first, so a different ROM revision fails loudly instead of
producing plausible nonsense.

    python tools/mk1_shang_souls_extract.py                  # -> tmp/mk1_shang_souls/
    python tools/mk1_shang_souls_extract.py --out some/dir
    python tools/mk1_shang_souls_extract.py --capture DIR    # + capture.gif from a
                                                             #   run_mk1_shang_defeat_capture.ps1 run

Writes, per animation: one transparent PNG per frame (all frames of an
animation share one canvas and one anchor, so they play back in place), a strip,
and a GIF at the game's own speed; plus sheet.png (everything at a glance),
sequence.txt (the choreography) and lanes.json (every frame down to its pieces).
The full write-up is doc/MK1_SHANG_SOUL_ESCAPE.md.

MK1 is not MK2 in three ways that matter here:
  * An image record is `.word W,H,anix,aniy / .long SAG` - NO control word.
    The first record of a group carries `.long palette` as well (16 bytes, not
    12).  Every sprite is 6bpp and uncompressed: 10,678 records chain SAG to SAG
    at exactly W*H*6 bits, and no other bpp matches a single pair.
  * SAG is ABSOLUTE (0x02000000-based), unlike MK2's TBL SAGs.
  * Field 0 is 16 bits and field 1 is 32 - the reverse of MK2 - which matters
    when reading the disassembly (`MOVE @1051A10h,A0,0` is a word).
A frame is a 0-terminated list of image pointers (pieces), each piece placed
at anchor - (anix, aniy), exactly MK2's convention.  A lane is a list of frame
pointers with MK2-style commands: 0 end-of-part, 1 jump, 2 flip, 3 adjust x
(.word), 4 adjust x,y (.word,.word), 5 frame-without-sleep, 6 calla.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
import zipfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("needs Pillow (pip install pillow)")

REPO = Path(__file__).resolve().parent.parent
ROM_ZIP = Path(r"C:\MAME\roms\mk.zip")
BASE = 0xFF800000          # bit address of program ROM byte 0
IROM = 0x02000000          # image ROM base; MK1 SAGs are absolute
CHIP = 0x80000
# MAME `mk`: three groups of four 512K chips, ROM_LOAD32_BYTE within a group
GFX_GROUPS = [("ug14", "uj14", "ug19", "uj19"),
              ("ug16", "uj16", "ug20", "uj20"),
              ("ug17", "uj17", "ug22", "uj22")]
TICK_MS = 1000.0 / 54.7068  # one game tick = one T-unit refresh

# ochar numbering (the index into the anim-table list); the ladder's slot
# values are remapped through FFCB30E0 and are NOT these numbers.
CHARS = ["Johnny Cage", "Kano", "Raiden", "Liu Kang", "Scorpion", "Sub-Zero", "Sonya"]
GORO, SHANG = 7, 8

# --- anchors, all derived in doc/MK1_SHANG_SOUL_ESCAPE.md -------------------
ANITAB_LIST = 0xFFCE4B90   # .long per ochar; get_char_ani = FFCE4AA0 indexes it
PAL_PRIMARY = 0xFFC839A0   # .long per ochar - the palette a fighter is given
PAL_ALT = 0xFFC83AC0       # .long per ochar - mirror-match palette
SHANG_TAB = 0xFFD68D10     # anitab[8]; checked against ANITAB_LIST below

# Shang's table: which entries the sequence uses
ST_STANCE, ST_MORPH0, ST_GORO_MORPH = 0, 7, 14
ST_COLLAPSE, ST_DEAD, ST_SHAKE = 15, 17, 20
FIGHTER_FLUNG1, FIGHTER_FLUNG2 = 0x41, 0x2A     # the soul's own two lanes
NINJA_FIRE_OBJ, NINJA_FIRE_LANE = 0x18, 0x1F    # Scorpion's toasty flame
FIRE_LANE_SKIP = 0xE0 // 32                     # `addi 0E0h,a9` = 7 longs

ANI_CMD = {1: "jump", 2: "flip", 3: "adjx", 4: "adjxy", 5: "nosleep", 6: "calla"}


def load_rom(path: Path) -> tuple[bytes, bytes]:
    with zipfile.ZipFile(path) as z:
        ev, od = z.read("mkt-uj12.bin"), z.read("mkt-ug12.bin")
        prog = bytearray(len(ev) * 2)
        prog[0::2], prog[1::2] = ev, od
        gfx = bytearray(CHIP * 4 * len(GFX_GROUPS))
        for gi, grp in enumerate(GFX_GROUPS):
            base = gi * CHIP * 4
            for lane, nm in enumerate(grp):
                gfx[base + lane:base + CHIP * 4:4] = z.read("mkt-%s.bin" % nm)
    return bytes(prog), bytes(gfx)


class Rom:
    def __init__(self, path: Path):
        self.p, self.g = load_rom(path)

    def off(self, bit: int) -> int:
        if not BASE <= bit <= 0xFFFFFFFF or (bit - BASE) % 8:
            raise ValueError("not a program-ROM byte address: %08x" % bit)
        return (bit - BASE) // 8

    def w(self, bit): return struct.unpack_from("<H", self.p, self.off(bit))[0]
    def sw(self, bit): return struct.unpack_from("<h", self.p, self.off(bit))[0]
    def l(self, bit): return struct.unpack_from("<I", self.p, self.off(bit))[0]

    def image(self, bit):
        return dict(addr=bit, w=self.w(bit), h=self.w(bit + 16),
                    anix=self.sw(bit + 32), aniy=self.sw(bit + 48),
                    sag=self.l(bit + 64))

    def palette(self, bit):
        n = self.w(bit)
        if not 1 <= n <= 256:
            raise ValueError("no palette at %08x" % bit)
        return [self.w(bit + 16 * (i + 1)) for i in range(n)]

    def pieces(self, frame):
        out, a = [], frame
        while (v := self.l(a)) != 0:
            out.append(v)
            a += 32
        return out

    def pixels(self, im):
        """rows of 6bpp palette indices, uncompressed, read LSB-first"""
        pos, g = im["sag"] - IROM, self.g
        rows = []
        for _ in range(im["h"]):
            row = []
            for _ in range(im["w"]):
                v = 0
                for b in range(6):
                    p = pos + b
                    v |= ((g[p >> 3] >> (p & 7)) & 1) << b
                row.append(v)
                pos += 6
            rows.append(row)
        return rows

    def anitab(self, ochar):
        return self.l(ANITAB_LIST + 32 * ochar)

    def ani(self, ochar, index):
        return self.l(self.anitab(ochar) + 32 * index)

    # --- lane walking -----------------------------------------------------
    def lane(self, addr, parts=1, skip=0, limit=64):
        """frames of a lane as (frame, dx, dy); stops after `parts` END markers,
        on a jump, or at `limit`.  adjust commands accumulate into dx, dy."""
        out, a, dx, dy, ends, n = [], addr + 32 * skip, 0, 0, 0, 0
        while n < limit:
            v = self.l(a)
            if v == 0:
                ends += 1
                a += 32
                if ends == parts:
                    break
                continue
            if v == 1:
                break
            if v == 3:
                dx += self.sw(a + 32); a += 48; continue
            if v == 4:
                dx += self.sw(a + 32); dy += self.sw(a + 48); a += 64; continue
            if v in (2, 5):
                a += 32; continue
            if v == 6:
                a += 64; continue
            out.append((v, dx, dy))
            a += 32
            n += 1
        return out


def imm(rom: Rom, at: int, opcode: int, what: str, kind: str):
    """read an instruction's immediate, after checking the opcode word.
    kind: 'movk' (5-bit K in the opcode), 'movi16', 'movi32'"""
    op = rom.w(at)
    if op != opcode:
        raise SystemExit("%s: expected %04x at %08x, found %04x - not rev 5.0 mk?"
                         % (what, opcode, at, op))
    if kind == "movk":
        return ((op >> 5) & 31) or 32
    if kind == "movi16":
        return rom.sw(at + 16)
    return rom.l(at + 16)


def read_timings(rom: Rom) -> dict:
    """the choreography's numbers, straight out of FFDD2160's code"""
    t = {}
    t["flash_count"] = imm(rom, 0xFFDD2990, 0x18CB, "flash loop count (movk 6,a11)", "movk")
    t["flash_ticks"] = imm(rom, 0xFFDD2C10, 0x09C0, "flash half-period (movi 4,a0)", "movi16")
    t["soul_phase_ticks"] = imm(rom, 0xFFDD2760, 0x09C0, "soul phase length (movi 140h,a0)", "movi16")
    t["shake_dx"] = imm(rom, 0xFFDD3030, 0x18E0, "shake step (movk 7,a0)", "movk")
    t["shake_ticks"] = imm(rom, 0xFFDD30B0, 0x09C0, "shake hold (movi 4,a0)", "movi16")
    t["soul_count"] = imm(rom, 0xFFDD3200, 0x18EA, "souls per cycle (movk 7,a10)", "movk")
    t["soul_cadence"] = imm(rom, 0xFFDD32D0, 0x09C0, "spawn cadence (movi 1Bh,a0)", "movi16")
    t["soul_speed_rand"] = imm(rom, 0xFFDD3B30, 0x09E0, "soul x speed range (movi 30000h)", "movi32")
    t["soul_speed_min"] = imm(rom, 0xFFDD3B90, 0x0B20, "soul x speed floor (addi 20000h)", "movi32")
    t["soul_hold"] = imm(rom, 0xFFDD3560, 0x09C0, "stance hold before morph (movi 8,a0)", "movi16")
    t["morph_ticks"] = imm(rom, 0xFFDD35D0, 0x18C1, "morph speed (movk 6,a1)", "movk")
    t["flung1"] = imm(rom, 0xFFDD3700, 0x09E0, "ani 41h frames:ticks (movi 40004h)", "movi32")
    t["flung2_ticks"] = imm(rom, 0xFFDD37F0, 0x1860, "ani 2Ah speed (movk 3,a0)", "movk")
    t["fire_dx"] = imm(rom, 0xFFDD3FE0, 0x09C0, "fire x offset (movi FF80h,a0)", "movi16")
    t["fire_dy"] = imm(rom, 0xFFDD4000, 0x09C1, "fire y offset (movi FFE8h,a1)", "movi16")
    t["fire_ticks"] = imm(rom, 0xFFDD41A0, 0x18A0, "fire speed (movk 5,a0)", "movk")
    # FFDD28F0 sends Shang's process to FFD77360: get_char_ani(0Fh), two parts
    t["collapse_ticks"] = imm(rom, 0xFFD773B0, 0x1880, "collapse speed (movk 4,a0)", "movk")
    # not located in code: measured off a MAME run (see the doc)
    t["unmorph_ticks"] = 4
    return t


def render(rom: Rom, frames, pal_addr):
    """frames -> (list of RGBA images on one canvas, anchor x, anchor y)"""
    cols = [(((c >> 10) & 31) * 255 // 31, ((c >> 5) & 31) * 255 // 31,
             (c & 31) * 255 // 31) for c in rom.palette(pal_addr)]
    placed, xs, ys = [], [0], [0]
    for frame, dx, dy in frames:
        ps = []
        for pa in rom.pieces(frame):
            im = rom.image(pa)
            x, y = dx - im["anix"], dy - im["aniy"]
            ps.append((im, x, y))
            xs += [x, x + im["w"]]
            ys += [y, y + im["h"]]
        placed.append(ps)
    x0, y0 = min(xs) - 2, min(ys) - 2
    W, H = max(xs) - x0 + 2, max(ys) - y0 + 2
    out = []
    for ps in placed:
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        px = img.load()
        for im, x, y in ps:
            for yy, row in enumerate(rom.pixels(im)):
                for xx, v in enumerate(row):
                    if v:
                        c = cols[v] if v < len(cols) else (255, 0, 255)
                        px[x - x0 + xx, y - y0 + yy] = c + (255,)
        out.append(img)
    return out, -x0, -y0


def write_anim(outdir: Path, name, rom, frames, pal, ticks, notes):
    imgs, ax, ay = render(rom, frames, pal)
    d = outdir / name
    d.mkdir(parents=True, exist_ok=True)
    for i, im in enumerate(imgs):
        im.save(d / ("%02d.png" % i))
    W, H = imgs[0].size
    strip = Image.new("RGBA", (W * len(imgs), H), (0, 0, 0, 0))
    for i, im in enumerate(imgs):
        strip.alpha_composite(im, (W * i, 0))
    strip.save(outdir / (name + "_strip.png"))
    tl = ticks if isinstance(ticks, list) else [ticks] * len(imgs)
    bg = [Image.new("RGBA", im.size, (32, 32, 48, 255)) for im in imgs]
    for b, im in zip(bg, imgs):
        b.alpha_composite(im)
    bg[0].convert("RGB").save(outdir / (name + ".gif"), save_all=True,
                             append_images=[b.convert("RGB") for b in bg[1:]],
                             duration=[round(t * TICK_MS) for t in tl], loop=0)
    rec = dict(name=name, palette="%08x" % pal, ticks=tl, anchor=[ax, ay],
               canvas=[W, H], notes=notes, frames=[])
    for frame, dx, dy in frames:
        rec["frames"].append(dict(frame="%08x" % frame, dx=dx, dy=dy, pieces=[
            dict(img="%08x" % pa, **{k: (("%08x" % v) if k == "sag" else v)
                                     for k, v in rom.image(pa).items() if k != "addr"})
            for pa in rom.pieces(frame)]))
    return rec, imgs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", type=Path, default=ROM_ZIP)
    ap.add_argument("--out", type=Path, default=REPO / "tmp" / "mk1_shang_souls")
    ap.add_argument("--capture", type=Path,
                    help="a run_mk1_shang_defeat_capture.ps1 run dir: also write capture.gif")
    ap.add_argument("--player", type=int, default=None, metavar="OCHAR",
                    help="the human's ochar (0-6): that fighter's soul is drawn "
                         "in its mirror-match palette, as the game does")
    args = ap.parse_args()
    if not args.zip.exists():
        sys.exit("MK1 romset not found: %s" % args.zip)
    rom = Rom(args.zip)

    # sanity: the anchors really are what the doc says they are
    if rom.anitab(SHANG) != SHANG_TAB:
        sys.exit("anitab[8] is %08x, expected %08x - not rev 5.0 mk?" % (rom.anitab(SHANG), SHANG_TAB))
    if rom.l(PAL_PRIMARY + 32 * SHANG) != 0xFFE9FFB0:
        sys.exit("primary palette table does not hold Shang's palette where expected")
    t = read_timings(rom)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    first_pal = lambda frame: rom.l(rom.pieces(frame)[0] + 96)   # record+12 bytes
    shang_pal = rom.l(PAL_PRIMARY + 32 * SHANG)

    anims = []

    # 1. back out of Goro: Shang's own Goro morph lane, played backwards
    goro = [f for f in rom.lane(rom.ani(SHANG, ST_GORO_MORPH)) ][::-1]
    anims.append(("01_unmorph_from_goro", goro, first_pal(goro[-1][0]), t["unmorph_ticks"],
                  "Shang's Goro-morph lane (entry 14) reversed - he lost wearing Goro"))

    # 2. the shake: lane 20 loops 69FF0,6A110,6A230,6A110; code nudges x +/-7 per step
    shake = rom.lane(rom.ani(SHANG, ST_SHAKE), limit=4)
    anims.append(("02_shake", shake, shang_pal, t["shake_ticks"],
                  "entry 20, looped; FFDD3030 alternates x by +%d/-%d each step" % (t["shake_dx"], t["shake_dx"])))

    # 3. what each soul is before it turns: a stance copy of Shang
    stance = rom.lane(rom.ani(SHANG, ST_STANCE), limit=1)
    anims.append(("03_soul_copy", stance, shang_pal, t["soul_hold"],
                  "FFCE5EE0(8) + get_char_ani(0): held %d ticks, drifting %.1f-%.1f px/tick"
                  % (t["soul_hold"], t["soul_speed_min"] / 65536,
                     (t["soul_speed_min"] + t["soul_speed_rand"]) / 65536)))

    # 4-6. per soul: morph (Shang lane 7+c), flung (fighter 41h then 2Ah), in spawn order
    order = [t["soul_count"] - 1 - k for k in range(t["soul_count"])]    # a10 counts 7..1
    nfl, tfl = t["flung1"] & 0xFFFF, t["flung1"] >> 16
    for k, c in enumerate(order):
        m = rom.lane(rom.ani(SHANG, ST_MORPH0 + c))
        anims.append(("%02d_%d_morph_%s" % (4, k, CHARS[c].lower().replace(" ", "_").replace("-", "")),
                      m, first_pal(m[0][0]), t["morph_ticks"],
                      "Shang entry %d via FFD75550; palette from the first piece's record" % (ST_MORPH0 + c)))
        f1 = rom.lane(rom.ani(c, FIGHTER_FLUNG1), limit=nfl)
        f2 = rom.lane(rom.ani(c, FIGHTER_FLUNG2), parts=2)
        pal = rom.l((PAL_ALT if c == args.player else PAL_PRIMARY) + 32 * c)
        anims.append(("%02d_%d_flung_%s" % (5, k, CHARS[c].lower().replace(" ", "_").replace("-", "")),
                      f1 + f2, pal, [tfl] * len(f1) + [t["flung2_ticks"]] * len(f2),
                      "anitab[%d][41h] %d frames @%d, then [2Ah] @%d until the fire takes it"
                      % (c, nfl, tfl, t["flung2_ticks"])))

    # 7. the fire that burns each soul away: Scorpion's toasty flame
    fire = rom.lane(rom.ani(4, NINJA_FIRE_LANE), parts=2, skip=FIRE_LANE_SKIP)
    anims.append(("07_fire", fire, first_pal(rom.ani(4, NINJA_FIRE_OBJ)), t["fire_ticks"],
                  "ninja anitab[1Fh] from entry %d (the build-up is skipped), object from [18h], "
                  "placed %+d,%+d from the soul" % (FIRE_LANE_SKIP, t["fire_dx"], t["fire_dy"])))

    # 8. the end: collapse. Entry 15's second part ends on the lying frame, the
    #    one entry 17 then holds, so the last frame here is what stays on screen.
    col = rom.lane(rom.ani(SHANG, ST_COLLAPSE), parts=2)
    assert col[-1][0] == rom.lane(rom.ani(SHANG, ST_DEAD), limit=1)[0][0]
    anims.append(("08_collapse", col, shang_pal, t["collapse_ticks"],
                  "entry 15, both parts; the last frame is held (entry 17)"))

    records, sheet_rows = [], []
    for name, frames, pal, ticks, notes in anims:
        rec, imgs = write_anim(out, name, rom, frames, pal, ticks, notes)
        records.append(rec)
        sheet_rows.append((name, imgs))
        print("  %-28s %2d frames  pal %08x  %s" % (name, len(imgs), pal, notes))

    # everything on one sheet
    pad, lab = 6, 14
    W = max(sum(im.width for im in imgs) + pad * (len(imgs) + 1) + 190 for _, imgs in sheet_rows)
    H = sum(max(im.height for im in imgs) + lab + pad for _, imgs in sheet_rows) + pad
    sheet = Image.new("RGBA", (W, H), (32, 32, 48, 255))
    d = ImageDraw.Draw(sheet)
    y = pad
    for name, imgs in sheet_rows:
        d.text((pad, y + 2), name, fill=(255, 220, 80, 255))
        x = pad + 190
        for im in imgs:
            sheet.alpha_composite(im, (x, y + lab))
            x += im.width + pad
        y += max(im.height for im in imgs) + lab + pad
    sheet.save(out / "sheet.png")

    (out / "lanes.json").write_text(json.dumps(dict(rom=str(args.zip), timings=t,
                                                    anims=records), indent=1))
    seq = sequence_text(t, order)
    (out / "sequence.txt").write_text(seq)

    if args.capture:
        caps = sorted(args.capture.glob("cap_*.png"))
        if not caps:
            sys.exit("no cap_*.png in %s" % args.capture)
        frames = [Image.open(p).convert("RGB") for p in caps]
        frames[0].save(out / "capture.gif", save_all=True, append_images=frames[1:],
                       duration=round(TICK_MS), loop=0)
        print("  capture.gif from %d frames" % len(frames))
    print("wrote %s" % out)


def sequence_text(t, order):
    step = t["soul_cadence"]
    lines = [
        "MK1 (rev 5.0 T-unit) - Shang Tsung defeated, the souls escape",
        "one tick = %.2f ms (54.7068 Hz); t=0 is gstate 0Bh (FFCA53C0)" % TICK_MS,
        "",
        "trigger  round end, human won, and the ladder has nothing after Shang:",
        "         FFCA0880 -> FFCA53C0 (gstate=0Bh, sound 0Fh) -> FFDD2160",
        "t=0      final blow lands; %d screen flashes, %d ticks on / %d off (FFDD2990)"
        % (t["flash_count"], t["flash_ticks"], t["flash_ticks"]),
        "t~50     Shang (still in Goro form) morphs back: Goro lane reversed @%d" % t["unmorph_ticks"],
        "t~62     he shakes: entry 20 @%d, x +%d/-%d alternating each step (FFDD2EE0)"
        % (t["shake_ticks"], t["shake_dx"], t["shake_dx"]),
        "         the doorway flashes: FFDD3C80 toggles @1051120 every 4 ticks",
        "t~50..   a soul every %d ticks (FFDD31F0), alternating sides (FFDD3440 negates"
        % step,
        "         its speed, FFDD3410 does not), cycling %s, then again"
        % ", ".join(CHARS[c] for c in order),
        "  soul   Shang stance copy, x speed %.1f-%.1f px/tick, held %d ticks"
        % (t["soul_speed_min"] / 65536, (t["soul_speed_min"] + t["soul_speed_rand"]) / 65536,
           t["soul_hold"]),
        "         + that fighter's scream (FFDB8190[char])",
        "         morph: Shang entry 7+char via FFD75550 @%d (3 frames, no morph sound in 0Bh)"
        % t["morph_ticks"],
        "         stops, becomes the fighter: anitab[char][41h] %d frames @%d,"
        % (t["flung1"] & 0xFFFF, t["flung1"] >> 16),
        "         then [2Ah] @%d; sound B1h" % t["flung2_ticks"],
        "         fire: Scorpion's toasty flame (ninja [18h] object, [1Fh]+%d lane @%d)"
        % (FIRE_LANE_SKIP, t["fire_ticks"]),
        "         at %+d,%+d from the soul; the soul is deleted under it" % (t["fire_dx"], t["fire_dy"]),
        "t~370    after %d ticks of souls: flashes again, souls cleared" % t["soul_phase_ticks"],
        "t~418    collapse (FFD77360): entry 15, 2 parts @%d, then lies on entry 17"
        % t["collapse_ticks"],
        "t~570    YOU HAVE DEFEATED SHANG TSUNG / SUPREME MORTAL KOMBAT WARRIOR, then the ending",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
