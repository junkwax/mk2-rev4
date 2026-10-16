#!/usr/bin/env python3
"""flybrain_dashboard.py - a live window into the fruit fly, beside the game.

The rig (tools/flybrain_play.lua with FB_DASH=<file>) writes what the fly is
seeing, firing and choosing about 20 times a second.  This serves that file and
the page that draws it, so a stream can show the brain next to MAME instead of
the four-line HUD in the corner.

MAME's video does not come through here - a browser cannot read another window.
A rig started with FB_DASH_SHOT=N drops a still every N frames instead, and the page
shows those (run_flybrain_stream.ps1 turns that on); otherwise put this page beside
the MAME window, or over it as an OBS browser source (?bare=1 is transparent).

Views, each its own page so OBS can hold them as separate browser sources - add
?bare=1 to any of them for a transparent background:

  /            the whole dashboard          /senses   what the fly is sensing
  /cells       the connectome firing        /acts     what it is choosing
  /screen      the game, as stills          /guards   the faults the board survived
  /hud         the two fighters and bars

  python tools/flybrain_dashboard.py                       # serves on 8777
  python tools/flybrain_dashboard.py --state C:\\tmp\\fly.json --port 9000

Then a rig, with the same file:

  $env:FB_DASH = "C:\\tmp\\fly.json"
  .\\tools\\run_flybrain_stream.ps1 -Maximize
"""
import argparse
import csv
import http.server
import json
import os
import re
import socketserver
import sys
import time

VIEWS = ("hud", "senses", "acts", "guards", "screen", "cells", "learn", "poke")
# the cells a viewer-facing button may drive (flybrain_play.lua STIM.cells) - nothing else
STIM_CELLS = {"giant", "charge", "kick", "octopamine", "moonwalk", "loom", "aipg", "pc1"}
TRAINER = r"C:\tmp\flybrain\fly2"
_curve_cache = {"t": 0, "data": None}


def lifetime_curve(trainer):
    """The trainer's exams, regular fighters only, in blocks of 10 training segments:
    the fly's whole learning history, the curve a single stream session cannot show."""
    now = time.time()
    if _curve_cache["data"] is not None and now - _curve_cache["t"] < 120:
        return _curve_cache["data"]
    blocks = {}
    root = os.path.join(trainer, "exams")
    try:
        names = os.listdir(root)
    except OSError:
        names = []
    for name in names:
        m = re.match(r"seg(\d+)_d(\d+)$", name)
        if not m:
            continue
        seg, diff = int(m.group(1)), int(m.group(2))
        path = os.path.join(root, name, "rounds.csv")
        try:
            with open(path, newline="") as fh:
                rows = [r for r in csv.DictReader(fh) if r.get("cpu_char") not in ("Kintaro", "ShaoKahn")]
        except OSError:
            continue
        b = blocks.setdefault((seg // 10 * 10, diff), [0, 0])
        b[0] += len(rows)
        b[1] += sum(r.get("winner") == "FLY" for r in rows)
    curve = {}
    for (seg, diff), (n, w) in sorted(blocks.items()):
        # 100 rounds behind a point, or it is noise: the first block had 27 and read 88.9%,
        # which made a curve that really climbs 50% -> 65% look like it was falling
        if n >= 100:
            curve.setdefault(str(diff), []).append([seg, round(100.0 * w / n, 1), n])
    segs = [int(m.group(1)) for m in (re.match(r"seg(\d+)_d", x) for x in names) if m]
    data = {"curve": curve, "segments": max(segs) if segs else 0}
    _curve_cache.update(t=now, data=data)
    return data

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "flybrain_dashboard.html")
STATE = r"C:\tmp\flybrain\dash.json"
# The MK2 display font, from the netplay front end. Served from where it lives rather than
# copied in, so there is one copy of it; --font points somewhere else.
FONT = r"C:\Users\you\Workplace\freeplay-gametalk\src\media\mk2.ttf"
ATLAS = r"C:\tmp\flybrain\atlas.json"


PNG_END = b"IEND\xaeB`\x82"


def newest_shots(folder):
    """MAME's .pngs in that folder, newest first."""
    if not folder or not os.path.isdir(folder):
        return []
    try:
        found = [(os.path.getmtime(os.path.join(folder, n)), os.path.join(folder, n))
                 for n in os.listdir(folder) if n.lower().endswith(".png")]
    except OSError:
        return []
    found.sort(reverse=True)
    return [f for _, f in found]


def live_frame(folder):
    """The newest COMPLETE picture in that folder, as bytes, or None.

    The rig alternates two names for exactly this reason - the file being written is
    always the newest one - but a reader can still catch a write mid-flight, so the
    PNG's own end marker decides, and the next one down is taken instead.
    """
    for path in newest_shots(folder)[:3]:
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except OSError:
            continue
        if blob.endswith(PNG_END):
            return blob
    return None


def net_file(state_file):
    """Where the rig writes the connectome manifest for a given state file."""
    return re.sub(r"\.json$", "", state_file) + ".net.json"


def published_shot_dir(state_file):
    """Where the running rig says it is dropping pictures.

    A stream restarts into a new folder every session, so the page follows the rig
    rather than being re-pointed by hand; --shots overrides this.
    """
    try:
        with open(state_file, "rb") as fh:
            return json.loads(fh.read()).get("shots") or ""
    except (OSError, ValueError):
        return ""


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        # One page, several views. The bare paths are for OBS browser sources: each panel
        # on its own, so a stream places them itself instead of taking one big dashboard.
        if path in ("/", "/index.html") or path.strip("/") in VIEWS:
            try:
                with open(PAGE, "rb") as fh:
                    self._send(fh.read(), "text/html; charset=utf-8")
            except OSError:
                self.send_error(500, "dashboard page missing: %s" % PAGE)
        elif path == "/frame.png":
            # The newest picture MAME has written. The rig snapshots into its own
            # -snapshot_directory and publishes that folder in the state file; --shots
            # overrides. A rig started without FB_DASH_SHOT writes none, and the page
            # then simply shows no screen - the normal case for a headless run.
            blob = live_frame(self.server.shot_dir or published_shot_dir(self.server.state_file))
            if blob:
                self._send(blob, "image/png")
            else:
                self.send_error(404)
        elif path == "/mk2.ttf":
            try:
                with open(self.server.font_file, "rb") as fh:
                    blob = fh.read()
            except OSError:
                self.send_error(404)     # the page falls back to Impact
                return
            self.send_response(200)
            self.send_header("Content-Type", "font/ttf")
            self.send_header("Content-Length", str(len(blob)))
            self.send_header("Cache-Control", "max-age=86400")   # it never changes mid-stream
            self.end_headers()
            self.wfile.write(blob)
        elif path == "/atlas":
            # Where every cell of the fly actually is (tools/flybrain_atlas.py). Static -
            # it comes from the connectome, not the run - so the page caches it.
            try:
                with open(self.server.atlas_file, "rb") as fh:
                    self._send(fh.read(), "application/json")
            except OSError:
                self._send(b'{"waiting":true}', "application/json")
        elif path == "/learned":             # the DATA; /learn is the panel page
            # this session, written by the rig at each round end, plus the trainer's
            # lifetime exam curve - how far it has come, not just how it is doing
            data = {}
            try:
                with open(re.sub(r"\.json$", "", self.server.state_file) + ".learn.json", "rb") as fh:
                    data = json.loads(fh.read())
            except (OSError, ValueError):
                pass
            data["life"] = lifetime_curve(self.server.trainer)
            self._send(json.dumps(data).encode(), "application/json")
        elif path == "/net":
            # The connectome itself - every cell and every connection - written once by the
            # rig beside the state file. The neuron view fetches this once and then only
            # needs [index, level] pairs per tick.
            try:
                with open(net_file(self.server.state_file), "rb") as fh:
                    self._send(fh.read(), "application/json")
            except OSError:
                self._send(b'{"waiting":true}', "application/json")
        elif path == "/state":
            # the rig renames its temp file into place, so a read is either the
            # whole of one tick or the whole of the last one - never a half line
            try:
                with open(self.server.state_file, "rb") as fh:
                    self._send(fh.read(), "application/json")
            except OSError:
                self._send(b'{"frame":0,"waiting":true}', "application/json")
        else:
            self.send_error(404)

    def do_POST(self):
        # POKE A NEURON. The page asks; this writes the request where the rig polls for it
        # (<state>.stim.json). Only the known cells, and only a stream rig started with
        # FB_STIM=1 acts on it - a test or a trainer never reads the file.
        if self.path.split("?")[0] != "/stim":
            self.send_error(404)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            cell = json.loads(self.rfile.read(n) or b"{}").get("cell")
        except (ValueError, OSError):
            cell = None
        if cell not in STIM_CELLS:
            self.send_error(400, "unknown cell")
            return
        path = re.sub(r"\.json$", "", self.server.state_file) + ".stim.json"
        with open(path + ".tmp", "w") as fh:
            json.dump({"cell": cell, "t": time.time()}, fh)
        os.replace(path + ".tmp", path)
        self._send(json.dumps({"ok": True, "cell": cell}).encode(), "application/json")

    def log_message(self, *a):
        pass            # one line per poll, 20 times a second, is not useful


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state", default=STATE, help="the file the rig writes (FB_DASH)")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--font", default=FONT, help="the MK2 .ttf the page's headers use")
    ap.add_argument("--atlas", default=ATLAS, help="cell positions (tools/flybrain_atlas.py)")
    ap.add_argument("--trainer", default=TRAINER, help="the trainer arm whose exams make the lifetime curve")
    ap.add_argument("--shots", default="", help="a rig's snapshot folder, to show the game itself "
                                                "(the rig needs FB_DASH_SHOT=<every N frames>)")
    args = ap.parse_args()
    socketserver.TCPServer.allow_reuse_address = True
    # threaded: the page asks for a picture and the state at the same time, and one
    # slow read of a 60 KB PNG should not hold up the numbers behind it
    with socketserver.ThreadingTCPServer(("127.0.0.1", args.port), Handler) as srv:
        srv.state_file = args.state
        srv.shot_dir = args.shots
        srv.font_file = args.font
        srv.atlas_file = args.atlas
        srv.trainer = args.trainer
        print("fly dashboard: http://127.0.0.1:%d   reading %s" % (args.port, args.state))
        print("run a rig with  $env:FB_DASH = \"%s\"" % args.state)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
