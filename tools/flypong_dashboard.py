#!/usr/bin/env python3
"""flypong_dashboard.py - the stream page for two fruit flies playing Ed Boon's Pong.

tools/flypong.lua writes <out>/pong.json about ten times a second: the score, the ball,
and for each fly what its eyes are reporting, what its steering neurons say, which way it
chose and how sure it was, and how its hit rate has moved. This serves that file and the
page that draws it. MAME's own window is the picture; put this page beside it in OBS as a
browser source (?bare=1 gives a transparent background).

  python tools/flypong_dashboard.py                                  # http://localhost:8778
  python tools/flypong_dashboard.py --state C:\\tmp\\flybrain\\pong_live\\pong.json --port 8778
"""
import argparse
import http.server
import os
import socketserver

# one page; each of these paths shows ONE section of it, full window, for OBS
VIEWS = ("score", "court", "left", "right", "brains", "brainleft", "brainright", "learn", "rallies")
HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "flypong_dashboard.html")


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body, ctype, code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html") or path.strip("/") in VIEWS:
            with open(PAGE, "rb") as fh:
                self._send(fh.read(), "text/html; charset=utf-8")
        elif path in ("/net", "/atlas"):
            # /net: the connectome the flies run (written once by the rig beside the state
            # file); /atlas: where every cell body really is (tools/flybrain_atlas.py)
            f = (self.server.state_file[:-5] if self.server.state_file.endswith(".json")
                 else self.server.state_file) + ".net.json" if path == "/net" else self.server.atlas
            try:
                with open(f, "rb") as fh:
                    self._send(fh.read(), "application/json")
            except OSError:
                self._send(b'{"waiting":true}', "application/json")
        elif path == "/state":
            try:
                with open(self.server.state_file, "rb") as fh:
                    self._send(fh.read(), "application/json")
            except OSError:
                self._send(b'{"waiting":true}', "application/json")
        else:
            self._send(b"not found", "text/plain", 404)

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default=r"C:\tmp\flybrain\pong_live\pong.json")
    ap.add_argument("--port", type=int, default=8778)
    ap.add_argument("--atlas", default="C:/tmp/flybrain/atlas.json")
    a = ap.parse_args()
    # NOT allow_reuse_address: on Windows it lets a second server bind the same port, and the
    # restarts left three running side by side
    socketserver.ThreadingTCPServer.allow_reuse_address = False
    with socketserver.ThreadingTCPServer(("127.0.0.1", a.port), H) as srv:
        srv.state_file = a.state
        srv.atlas = a.atlas
        print(f"[flypong] http://localhost:{a.port}/   (state: {a.state})")
        srv.serve_forever()


if __name__ == "__main__":
    main()
