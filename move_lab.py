#!/usr/bin/env python3
"""Generate a standalone MK2 move-lab HTML app.

The app is intentionally source-only: it parses combo tables, animation tables,
and strike records from the current ASM, then writes tmp/move_lab.html.
"""

from __future__ import annotations

import html
import json
import re
import struct
import zlib
from pathlib import Path

import combo_edit
import hitbox_edit


ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
OUT = ROOT / "tmp" / "move_lab.html"
SPRITE_DIR = ROOT / "tmp" / "move_lab_sprites"


LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")
PALETTE = struct.Struct("<10s BB H I H H B B H")


CHAR_NAMES = {
    "hat": "Kung Lao",
    "lk": "Liu Kang",
    "jc": "Johnny Cage",
    "sa": "Kitana",
    "fn1": "Mileena",
    "fn2": "Kitana/Jade",
    "st": "Shang Tsung",
    "rd": "Raiden",
    "sz": "Sub-Zero",
    "rp": "Reptile",
    "sc": "Scorpion",
    "jx": "Jax",
    "go": "Kintaro",
    "sk": "Shao Kahn",
}


def strip_comment(line: str) -> str:
    return line.split(";", 1)[0].rstrip()


def parse_asm_long(line: str) -> list[str]:
    m = re.match(r"^\s*\.long\s+(.+?)\s*$", strip_comment(line), re.IGNORECASE)
    if not m:
        return []
    return [p.strip() for p in m.group(1).split(",") if p.strip()]


def cstr(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("latin-1", errors="replace").strip()


def s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write_png(path: Path, width: int, height: int, rgba: bytes) -> None:
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(rgba[y * stride:(y + 1) * stride])
    data = [
        b"\x89PNG\r\n\x1a\n",
        png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
        png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
        png_chunk(b"IEND", b""),
    ]
    path.write_bytes(b"".join(data))


def color_555_to_rgba(word: int, alpha: int = 255) -> tuple[int, int, int, int]:
    # Midway/TMS art palettes are 5-bit channels. This is close enough for the lab.
    r = ((word >> 10) & 0x1F) * 255 // 31
    g = ((word >> 5) & 0x1F) * 255 // 31
    b = (word & 0x1F) * 255 // 31
    return r, g, b, alpha


def parse_palette_headers(data: bytes, imgcnt: int, palcnt: int, oset: int) -> tuple[int, list[dict]]:
    start = oset + imgcnt * IMAGE.size
    pal_start = None
    for off in range(start, min(start + 96, len(data) - PALETTE.size)):
        name = cstr(data[off:off + 10])
        if name.endswith("_P"):
            pal_start = off
            break
    if pal_start is None:
        return palcnt, []

    headers = []
    off = pal_start
    while off + PALETTE.size <= len(data):
        vals = PALETTE.unpack_from(data, off)
        name = cstr(vals[0])
        if not name.endswith("_P"):
            break
        headers.append({
            "name": name,
            "flags": vals[1],
            "bits": vals[2],
            "colors": vals[3],
            "offset": vals[4],
            "colind": vals[7],
            "cmap": vals[8],
        })
        off += PALETTE.size

    first_custom_index = palcnt - len(headers)
    return first_custom_index, headers


def parse_img_library(path: Path) -> tuple[list[dict], int, list[dict], bytes]:
    data = path.read_bytes()
    imgcnt, palcnt, oset, *_ = LIB_HDR.unpack_from(data, 0)
    first_custom_index, palettes = parse_palette_headers(data, imgcnt, palcnt, oset)
    records = []
    for i in range(imgcnt):
        off = oset + i * IMAGE.size
        if off + IMAGE.size > len(data):
            break
        vals = IMAGE.unpack_from(data, off)
        name = cstr(vals[0])
        if not name:
            continue
        records.append({
            "name": name,
            "flags": vals[1],
            "xoff": s16(vals[2]),
            "yoff": s16(vals[3]),
            "width": vals[4],
            "height": vals[5],
            "palind": vals[6],
            "offset": vals[7],
            "source": path.name,
        })
    return records, first_custom_index, palettes, data


def palette_for_record(data: bytes, record: dict, first_custom_index: int, palettes: list[dict]) -> list[tuple[int, int, int, int]]:
    pal_idx = record["palind"] - first_custom_index
    if not (0 <= pal_idx < len(palettes)):
        pal_idx = 0
    pal = palettes[pal_idx] if palettes else {"offset": 28, "colors": 64, "colind": 0}
    colors = []
    for i in range(max(1, pal["colors"])):
        off = pal["offset"] + i * 2
        if off + 2 > len(data):
            break
        alpha = 0 if i == 0 else 255
        colors.append(color_555_to_rgba(struct.unpack_from("<H", data, off)[0], alpha))
    while len(colors) < 256:
        colors.append((255, 0, 255, 255))
    return colors


def export_sprites(needed_names: set[str]) -> dict:
    SPRITE_DIR.mkdir(parents=True, exist_ok=True)
    sprite_index: dict[str, dict] = {}
    wanted = {name.upper() for name in needed_names}

    for path in sorted((ROOT / "data").glob("*.IMG")):
        try:
            records, first_custom_index, palettes, data = parse_img_library(path)
        except Exception:
            continue

        for rec in records:
            key = rec["name"].upper()
            if key not in wanted or key in sprite_index:
                continue
            width = rec["width"]
            height = rec["height"]
            if width <= 0 or height <= 0 or width > 512 or height > 512:
                continue
            stride = width + (width & 1)
            offset = rec["offset"]
            size = stride * height
            if offset + size > len(data):
                continue
            palette = palette_for_record(data, rec, first_custom_index, palettes)
            rgba = bytearray(width * height * 4)
            pixels = data[offset:offset + size]
            for y in range(height):
                for x in range(width):
                    idx = pixels[y * stride + x]
                    rgba_off = (y * width + x) * 4
                    rgba[rgba_off:rgba_off + 4] = bytes(palette[idx])
            out_name = f"{rec['name']}.png"
            write_png(SPRITE_DIR / out_name, width, height, bytes(rgba))
            sprite_index[key] = {
                "src": f"move_lab_sprites/{out_name}",
                "width": width,
                "height": height,
                "xoff": rec["xoff"],
                "yoff": rec["yoff"],
                "source": rec["source"],
            }

    return sprite_index


def parse_animation_files() -> dict:
    chars: dict[str, dict] = {}
    label_defs: dict[str, list[str]] = {}
    label_files: dict[str, str] = {}

    for path in sorted(SRC.glob("*.ASM")):
        lines = path.read_text(errors="replace").splitlines()
        current_label = None
        current_items: list[str] | None = None

        for idx, line in enumerate(lines, start=1):
            label_match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(?:;.*)?$", line)
            inline_label = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s+\.long\s+(.+?)\s*(?:;.*)?$", line, re.IGNORECASE)

            if current_label and not parse_asm_long(line):
                if line.strip() and not line.lstrip().startswith(("*", ";")):
                    label_defs[current_label] = current_items or []
                    label_files[current_label] = f"{path.name}:{idx - len(current_items or []) - 1}"
                    current_label = None
                    current_items = None

            if inline_label:
                label = inline_label.group(1)
                items = [p.strip() for p in inline_label.group(2).split(",") if p.strip()]
                label_defs[label] = items
                label_files[label] = f"{path.name}:{idx}"
                continue

            if label_match:
                label = label_match.group(1)
                if re.match(r"^[a-z0-9]+_anitab[12]$", label):
                    prefix, table_no = label.rsplit("_anitab", 1)
                    entries = []
                    j = idx
                    while j < len(lines):
                        parts = parse_asm_long(lines[j])
                        if not parts:
                            if lines[j].strip() and not lines[j].lstrip().startswith(("*", ";")):
                                break
                            j += 1
                            continue
                        for part in parts:
                            entries.append(part)
                        j += 1
                    chars.setdefault(prefix, {
                        "name": CHAR_NAMES.get(prefix, prefix.upper()),
                        "tables": {},
                    })["tables"][table_no] = entries
                    continue

                current_label = label
                current_items = []
                continue

            parts = parse_asm_long(line)
            if current_label and parts:
                current_items.extend(parts)

        if current_label:
            label_defs[current_label] = current_items or []
            label_files[current_label] = path.name

    return {"chars": chars, "labels": label_defs, "labelFiles": label_files}


def collect_sprite_names(animations: dict) -> set[str]:
    names = set()
    for parts in animations["labels"].values():
        for part in parts:
            if re.match(r"^[A-Z][A-Z0-9_]+$", part):
                names.add(part)
    return names


def parse_combos() -> dict:
    files = combo_edit.load_all()
    combos = combo_edit.parse_combos(files)
    callers = combo_edit.parse_callers(files)
    out = {}
    for label, rec in combos.items():
        words = rec["words"]
        right = [combo_edit.format_input(w) for w in words[1:7]]
        left = [combo_edit.format_input(w) for w in words[7:13]]
        right = [w for w in right if w != "-"]
        left = [w for w in left if w != "-"]
        out[label] = {
            "window": combo_edit.parse_literal(words[0]) or 0,
            "right": list(reversed(right)),
            "left": list(reversed(left)),
            "aliases": rec["aliases"],
            "file": f"{rec['path'].name}:{rec['first_line']}",
            "callers": [
                {"file": f"{p.name}:{line}", "handler": handler or "?"}
                for p, line, handler in callers.get(label, [])
            ],
        }
    return out


def parse_strikes() -> dict:
    moves = hitbox_edit.parse_mkstk()
    tables = hitbox_edit.parse_char_tables()
    return {
        "moves": {
            k: {
                "line": v["line"],
                "fields": v["fields"],
                "raw": v["raw_fields"],
            }
            for k, v in moves.items()
        },
        "tables": tables,
    }


def build_html(data: dict) -> str:
    payload = json.dumps(data, separators=(",", ":"))
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MK2 Move Lab</title>
<style>
:root {{
  color-scheme: dark;
  --bg: #151716;
  --panel: #20231f;
  --panel2: #292d28;
  --line: #3a4037;
  --text: #f3f1e8;
  --muted: #b9b7a9;
  --green: #79c96b;
  --red: #e55e54;
  --gold: #d7b45d;
  --blue: #6db7d8;
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0;
  font-family: "Segoe UI", Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
}}
header {{
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 18px;
  border-bottom: 1px solid var(--line);
  background: #111311;
}}
h1 {{ font-size: 18px; margin: 0; font-weight: 650; }}
main {{
  display: grid;
  grid-template-columns: 300px minmax(520px, 1fr) 340px;
  min-height: calc(100vh - 50px);
}}
section {{
  padding: 12px;
  border-right: 1px solid var(--line);
  min-width: 0;
}}
section:last-child {{ border-right: 0; }}
label {{ display: block; color: var(--muted); font-size: 12px; margin: 12px 0 5px; }}
select, input, button {{
  width: 100%;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--panel);
  color: var(--text);
  padding: 8px;
  font: inherit;
}}
button {{ cursor: pointer; }}
button:hover {{ border-color: var(--gold); }}
.row {{ display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }}
.pad {{
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin-top: 10px;
}}
.pad button {{ min-height: 42px; font-weight: 700; }}
.wide {{ grid-column: span 3; }}
.meter {{
  height: 8px;
  background: #0f100f;
  border: 1px solid var(--line);
  border-radius: 999px;
  overflow: hidden;
  margin: 8px 0;
}}
.meter > div {{ height: 100%; width: 0%; background: var(--green); transition: width .12s linear; }}
.stage {{
  display: grid;
  grid-template-rows: auto auto 1fr;
  gap: 10px;
  height: 100%;
}}
.screen {{
  min-height: 440px;
  border: 1px solid var(--line);
  background:
    linear-gradient(#242823 1px, transparent 1px),
    linear-gradient(90deg, #242823 1px, transparent 1px),
    #111411;
  background-size: 40px 40px;
  display: grid;
  place-items: center;
  position: relative;
  overflow: hidden;
}}
.fighter {{
  width: min(100%, 560px);
  min-height: 350px;
  background: rgba(17,20,17,.65);
  display: grid;
  place-items: center;
  padding: 12px;
  text-align: center;
}}
.frame-name {{ font-size: 18px; font-weight: 750; overflow-wrap: anywhere; }}
.subframes {{ margin-top: 8px; color: var(--muted); line-height: 1.35; overflow-wrap: anywhere; font-size: 12px; }}
.sprite-strip {{
  display: grid;
  place-items: center;
  min-height: 260px;
  margin-bottom: 12px;
}}
.sprite-composite {{
  position: relative;
  image-rendering: pixelated;
}}
.sprite-composite img {{
  position: absolute;
  image-rendering: pixelated;
}}
.sprite-composite.smooth, .sprite-composite.smooth img {{
  image-rendering: auto;
}}
.toolbar {{
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 8px;
  align-items: end;
}}
.toolbar label {{ margin-top: 0; }}
.toggles {{
  display: flex;
  gap: 10px;
  align-items: center;
  color: var(--muted);
  font-size: 12px;
}}
.toggles input {{ width: auto; }}
.meta-grid {{
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 8px;
}}
.stat {{
  border: 1px solid var(--line);
  background: #171a17;
  border-radius: 6px;
  padding: 8px;
}}
.stat b {{ display: block; color: var(--muted); font-size: 11px; font-weight: 500; }}
.stat span {{ display: block; margin-top: 4px; font-size: 13px; overflow-wrap: anywhere; }}
.piece-list {{
  max-height: 160px;
  overflow: auto;
  font-family: Consolas, monospace;
  font-size: 12px;
  line-height: 1.45;
  color: var(--muted);
}}
.hud {{
  position: absolute;
  left: 12px;
  top: 12px;
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}}
.pill {{
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: 4px 8px;
  background: #111311;
  color: var(--muted);
  font-size: 12px;
}}
.pill.good {{ color: var(--green); border-color: #426b3b; }}
.pill.bad {{ color: var(--red); border-color: #73352f; }}
.panel {{
  border: 1px solid var(--line);
  background: var(--panel);
  border-radius: 8px;
  padding: 10px;
  margin-top: 10px;
}}
.panel h2 {{
  font-size: 13px;
  margin: 0 0 8px;
  color: var(--gold);
}}
pre {{
  white-space: pre-wrap;
  margin: 0;
  color: var(--muted);
  font-size: 12px;
  line-height: 1.45;
}}
table {{ width: 100%; border-collapse: collapse; font-size: 12px; }}
td {{ border-top: 1px solid var(--line); padding: 5px 3px; vertical-align: top; }}
td:first-child {{ color: var(--muted); }}
.log {{
  max-height: 280px;
  overflow: auto;
  font-family: Consolas, monospace;
  font-size: 12px;
  line-height: 1.45;
}}
.hit {{ color: var(--green); }}
.miss {{ color: var(--red); }}
@media (max-width: 1050px) {{
  main {{ grid-template-columns: 1fr; }}
  section {{ border-right: 0; border-bottom: 1px solid var(--line); }}
}}
</style>
</head>
<body>
<header>
  <h1>MK2 Move Lab</h1>
  <div class="pill">source snapshot: {html.escape(data["generatedFrom"])}</div>
</header>
<main>
  <section>
    <label>Character</label>
    <select id="char"></select>
    <div class="row">
      <div>
        <label>Animation Table</label>
        <select id="table"></select>
      </div>
      <div>
        <label>Animation Index</label>
        <select id="anim"></select>
      </div>
    </div>
    <label>Combo</label>
    <select id="combo"></select>
    <div class="row">
      <button id="auto">Auto Play Combo</button>
      <button id="reset">Reset</button>
    </div>
    <div class="panel">
      <h2>Virtual Controller</h2>
      <div class="pad">
        <button data-input="Up">Up</button>
        <button data-input="HP">HP</button>
        <button data-input="LP">LP</button>
        <button data-input="Back">Back</button>
        <button data-input="Block">BLK</button>
        <button data-input="Forward">Fwd</button>
        <button data-input="Down">Down</button>
        <button data-input="HK">HK</button>
        <button data-input="LK">LK</button>
        <button class="wide" id="fire">Fire Selected Move</button>
      </div>
    </div>
    <div class="panel">
      <h2>Combo State</h2>
      <div class="meter"><div id="windowBar"></div></div>
      <pre id="comboInfo"></pre>
    </div>
  </section>
  <section>
    <div class="stage">
      <div class="toolbar">
        <div>
          <label>Scale</label>
          <select id="scale">
            <option value="2">2x</option>
            <option value="1">1x</option>
            <option value="3" selected>3x</option>
            <option value="4">4x</option>
          </select>
        </div>
        <div>
          <label>Playback</label>
          <select id="speed">
            <option value="220">Slow</option>
            <option value="160" selected>Normal</option>
            <option value="90">Fast</option>
          </select>
        </div>
        <label class="toggles"><input id="smooth" type="checkbox"> Smooth</label>
        <label class="toggles"><input id="labels" type="checkbox" checked> Labels</label>
      </div>
      <div class="screen">
        <div class="hud">
          <span class="pill" id="stateReady">idle</span>
          <span class="pill" id="tick">tick 0</span>
          <span class="pill" id="action">action clear</span>
        </div>
        <div class="fighter">
          <div>
            <div class="sprite-strip" id="spriteStrip"></div>
            <div class="frame-name" id="frameName">No frame</div>
            <div class="subframes" id="subframes"></div>
          </div>
        </div>
      </div>
      <div class="row">
        <button id="play">Play Animation</button>
        <button id="step">Step Frame</button>
      </div>
      <div class="panel">
        <h2>Frame Inspector</h2>
        <div class="meta-grid">
          <div class="stat"><b>Frame</b><span id="frameStat">-</span></div>
          <div class="stat"><b>Parts</b><span id="partStat">-</span></div>
          <div class="stat"><b>Bounds</b><span id="boundsStat">-</span></div>
          <div class="stat"><b>Scale</b><span id="scaleStat">-</span></div>
        </div>
        <div class="piece-list" id="pieceList"></div>
      </div>
    </div>
  </section>
  <section>
    <label>Strike Record</label>
    <select id="strike"></select>
    <div class="panel">
      <h2>Strike Metadata</h2>
      <table id="strikeTable"></table>
    </div>
    <div class="panel">
      <h2>Event Log</h2>
      <div class="log" id="log"></div>
    </div>
  </section>
</main>
<script>
const DATA = {payload};
const $ = (id) => document.getElementById(id);
let tick = 0;
let queue = [];
let animFrames = [];
let frameIndex = 0;
let timer = null;

function log(msg, cls = "") {{
  const div = document.createElement("div");
  div.className = cls;
  div.textContent = `[${{String(tick).padStart(3, "0")}}] ${{msg}}`;
  $("log").prepend(div);
}}

function fillSelect(el, items, labeler = x => x, valuer = x => x) {{
  el.innerHTML = "";
  for (const item of items) {{
    const opt = document.createElement("option");
    opt.value = valuer(item);
    opt.textContent = labeler(item);
    el.appendChild(opt);
  }}
}}

function refreshChars() {{
  const chars = Object.entries(DATA.animations.chars).sort((a, b) => a[1].name.localeCompare(b[1].name));
  fillSelect($("char"), chars, ([key, c]) => `${{c.name}} (${{key}})`, ([key]) => key);
  refreshTables();
}}

function refreshTables() {{
  const c = DATA.animations.chars[$("char").value];
  const tables = Object.keys(c.tables).sort();
  fillSelect($("table"), tables, t => `anitab${{t}}`, t => t);
  refreshAnims();
}}

function refreshAnims() {{
  const c = DATA.animations.chars[$("char").value];
  const entries = c.tables[$("table").value] || [];
  fillSelect($("anim"), entries.map((label, i) => [label, i]),
    ([label, i]) => `${{i.toString(16).padStart(2, "0")}}  ${{label}}`,
    ([, i]) => String(i));
  buildFrames();
}}

function resolveParts(label, depth = 0) {{
  const parts = DATA.animations.labels[label] || [];
  return parts.map(p => {{
    const child = DATA.animations.labels[p];
    return {{ label: p, child: child && depth < 1 ? child : null }};
  }});
}}

function buildFrames() {{
  const c = DATA.animations.chars[$("char").value];
  const entries = c.tables[$("table").value] || [];
  const label = entries[Number($("anim").value)] || "";
  const parts = DATA.animations.labels[label] || [];
  animFrames = parts
    .filter(p => !p.startsWith("ani_") && p !== "0")
    .map(p => ({{ label: p, parts: resolveParts(p) }}));
  if (!animFrames.length && label) animFrames = [{{ label, parts: resolveParts(label) }}];
  frameIndex = 0;
  renderFrame();
}}

function renderFrame() {{
  const f = animFrames[frameIndex];
  $("frameName").textContent = f ? f.label : "No frame";
  $("spriteStrip").innerHTML = "";
  $("subframes").style.display = $("labels").checked ? "" : "none";
  $("frameName").style.display = $("labels").checked ? "" : "none";
  $("subframes").innerHTML = f ? f.parts.map(p => {{
    const child = p.child ? `<br><span style="color:var(--blue)">${{p.child.join(", ")}}</span>` : "";
    return `<div>${{p.label}}${{child}}</div>`;
  }}).join("") : "";
  if (f) renderComposite(f);
  $("tick").textContent = `tick ${{tick}}`;
}}

function spritePiecesForFrame(f) {{
  let names = [];
  for (const p of f.parts) {{
    if (p.child && p.child.length) names.push(...p.child);
    else names.push(p.label);
  }}
  if (!names.length) names = [f.label];
  const pieces = [];
  const seen = new Set();
  for (const name of names) {{
    const sprite = DATA.sprites[String(name).toUpperCase()];
    if (!sprite || seen.has(sprite.src)) continue;
    seen.add(sprite.src);
    pieces.push({{ name, sprite }});
  }}
  return pieces;
}}

function renderComposite(f) {{
  const pieces = spritePiecesForFrame(f);
  if (!pieces.length) {{
    $("frameStat").textContent = `${{frameIndex + 1}} / ${{animFrames.length}}`;
    $("partStat").textContent = "0";
    $("boundsStat").textContent = "-";
    $("scaleStat").textContent = "-";
    $("pieceList").textContent = "No sprite records resolved for this frame.";
    return;
  }}

  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of pieces) {{
    minX = Math.min(minX, p.sprite.xoff);
    minY = Math.min(minY, p.sprite.yoff);
    maxX = Math.max(maxX, p.sprite.xoff + p.sprite.width);
    maxY = Math.max(maxY, p.sprite.yoff + p.sprite.height);
  }}
  const w = Math.max(1, maxX - minX);
  const h = Math.max(1, maxY - minY);
  const selectedScale = Number($("scale").value || 3);
  const maxScale = Math.max(1, Math.floor(Math.min(520 / w, 260 / h)));
  const scale = Math.max(1, Math.min(selectedScale, maxScale));
  const comp = document.createElement("div");
  comp.className = $("smooth").checked ? "sprite-composite smooth" : "sprite-composite";
  comp.style.width = `${{Math.round(w * scale)}}px`;
  comp.style.height = `${{Math.round(h * scale)}}px`;

  for (const p of pieces) {{
    const img = document.createElement("img");
    img.src = p.sprite.src;
    img.alt = p.name;
    img.title = `${{p.name}} from ${{p.sprite.source}} xoff=${{p.sprite.xoff}} yoff=${{p.sprite.yoff}}`;
    img.style.left = `${{Math.round((p.sprite.xoff - minX) * scale)}}px`;
    img.style.top = `${{Math.round((p.sprite.yoff - minY) * scale)}}px`;
    img.style.width = `${{Math.round(p.sprite.width * scale)}}px`;
    img.style.height = `${{Math.round(p.sprite.height * scale)}}px`;
    comp.append(img);
  }}
  $("spriteStrip").append(comp);
  $("frameStat").textContent = `${{frameIndex + 1}} / ${{animFrames.length}}  ${{f.label}}`;
  $("partStat").textContent = String(pieces.length);
  $("boundsStat").textContent = `${{w}}x${{h}} @ (${{minX}},${{minY}})`;
  $("scaleStat").textContent = `${{scale}}x${{scale < selectedScale ? " capped" : ""}}`;
  $("pieceList").textContent = pieces.map(p =>
    `${{p.name.padEnd(18)}} ${{String(p.sprite.width).padStart(3)}}x${{String(p.sprite.height).padStart(3)}} ` +
    `xy(${{String(p.sprite.xoff).padStart(4)}},${{String(p.sprite.yoff).padStart(4)}}) ${{p.sprite.source}}`
  ).join("\\n");
}}

function stepFrame() {{
  if (!animFrames.length) return;
  frameIndex = (frameIndex + 1) % animFrames.length;
  tick += 1;
  renderFrame();
}}

function playAnim() {{
  if (timer) {{
    clearInterval(timer);
    timer = null;
    $("play").textContent = "Play Animation";
    return;
  }}
  $("play").textContent = "Pause Animation";
  timer = setInterval(stepFrame, Number($("speed").value || 160));
}}

function refreshCombos() {{
  const labels = Object.keys(DATA.combos).sort();
  fillSelect($("combo"), labels, x => x, x => x);
  refreshComboInfo();
}}

function refreshComboInfo() {{
  const rec = DATA.combos[$("combo").value];
  const callerLines = rec.callers.length ? rec.callers.map(c => `  ${{c.handler}} at ${{c.file}}`).join("\\n") : "  no call site found";
  $("comboInfo").textContent = [
    `window: ${{rec.window}} ticks`,
    `right:  ${{rec.right.join(" -> ") || "(none)"}}`,
    `left:   ${{rec.left.join(" -> ") || "(none)"}}`,
    `table:  ${{rec.file}}`,
    `callers:`,
    callerLines,
    "",
    `queue:  ${{queue.map(e => e.input).join(" -> ") || "(empty)"}}`
  ].join("\\n");
  const age = queue.length ? tick - queue[0].tick : 0;
  $("windowBar").style.width = `${{Math.min(100, rec.window ? age / rec.window * 100 : 0)}}%`;
}}

function normalizeInput(input) {{
  return input;
}}

function press(input) {{
  tick += 1;
  input = normalizeInput(input);
  queue.push({{ input, tick }});
  queue = queue.slice(-8);
  log(`input ${{input}}`);
  refreshComboInfo();
  renderFrame();
}}

function matchCombo() {{
  const rec = DATA.combos[$("combo").value];
  const seq = rec.right;
  if (!seq.length) return false;
  const recent = queue.slice(-seq.length);
  if (recent.length < seq.length) return false;
  const tooOld = recent[recent.length - 1].tick - recent[0].tick > rec.window;
  if (tooOld) return false;
  return seq.every((x, i) => x === recent[i].input);
}}

function fireMove() {{
  tick += 1;
  if (matchCombo()) {{
    $("stateReady").textContent = "combo matched";
    $("stateReady").className = "pill good";
    $("action").textContent = "pm_special set";
    log(`FIRE ${{$("combo").value}} -> dispatch would run`, "hit");
    frameIndex = 0;
    renderFrame();
    if (!timer) playAnim();
  }} else {{
    $("stateReady").textContent = "combo missed";
    $("stateReady").className = "pill bad";
    log(`fire failed: queue does not match ${{$("combo").value}}`, "miss");
  }}
  refreshComboInfo();
}}

function autoPlayCombo() {{
  queue = [];
  const rec = DATA.combos[$("combo").value];
  for (const item of rec.right) press(item);
  fireMove();
}}

function refreshStrikes() {{
  const labels = Object.keys(DATA.strikes.moves).sort();
  fillSelect($("strike"), labels, x => x, x => x);
  refreshStrike();
}}

function refreshStrike() {{
  const rec = DATA.strikes.moves[$("strike").value];
  const rows = Object.entries(rec.fields).map(([k, v]) => `<tr><td>${{k}}</td><td>${{v}}</td></tr>`);
  rows.unshift(`<tr><td>source</td><td>MKSTK.ASM:${{rec.line}}</td></tr>`);
  $("strikeTable").innerHTML = rows.join("");
}}

function resetLab() {{
  queue = [];
  tick = 0;
  $("stateReady").textContent = "idle";
  $("stateReady").className = "pill";
  $("action").textContent = "action clear";
  if (timer) playAnim();
  buildFrames();
  refreshComboInfo();
  log("reset");
}}

document.querySelectorAll("[data-input]").forEach(btn => btn.addEventListener("click", () => press(btn.dataset.input)));
$("char").addEventListener("change", refreshTables);
$("table").addEventListener("change", refreshAnims);
$("anim").addEventListener("change", buildFrames);
$("scale").addEventListener("change", renderFrame);
$("smooth").addEventListener("change", renderFrame);
$("labels").addEventListener("change", renderFrame);
$("speed").addEventListener("change", () => {{
  if (timer) {{
    clearInterval(timer);
    timer = null;
    $("play").textContent = "Play Animation";
    playAnim();
  }}
}});
$("combo").addEventListener("change", refreshComboInfo);
$("strike").addEventListener("change", refreshStrike);
$("step").addEventListener("click", stepFrame);
$("play").addEventListener("click", playAnim);
$("fire").addEventListener("click", fireMove);
$("auto").addEventListener("click", autoPlayCombo);
$("reset").addEventListener("click", resetLab);

refreshChars();
refreshCombos();
refreshStrikes();
log("move lab loaded");
</script>
</body>
</html>
"""


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    animations = parse_animation_files()
    sprites = export_sprites(collect_sprite_names(animations))
    data = {
        "generatedFrom": str(ROOT),
        "animations": animations,
        "combos": parse_combos(),
        "strikes": parse_strikes(),
        "sprites": sprites,
    }
    OUT.write_text(build_html(data), encoding="utf-8")
    print(f"Wrote {OUT}")
    print("Open it directly in a browser, or run: python move_lab.py --regen after ASM edits.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
