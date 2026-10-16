#!/usr/bin/env python3
"""
make_post.py - inline MAME snapshots into an HTML page as data URIs.

A published artifact is served under a strict CSP with no external hosts, so
every image has to travel inside the file. This substitutes `{{IMG:name}}`
tokens in a template with `data:image/png;base64,...` payloads, reading the
name -> file mapping from a manifest.

Manifest is one `name = path` per line, `#` comments ignored; paths are
relative to the repo root.

  python tools/make_post.py --template tools/post_template.html \\
      --manifest tools/post_images.txt --out tmp/post.html

It refuses on a missing image rather than emitting a page with a broken
picture, and prints the final size, because the artifact ceiling is 16 MB and
base64 costs a third on top of the PNG.
"""
import argparse
import base64
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_manifest(path):
    out = {}
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#")[0].strip()
        if not line:
            continue
        if "=" not in line:
            sys.exit("manifest line is not name = path: %r" % raw.rstrip())
        name, p = line.split("=", 1)
        out[name.strip()] = p.strip()
    return out


def data_uri(path):
    with open(path, "rb") as fh:
        blob = fh.read()
    ext = os.path.splitext(path)[1].lower()
    mime = {".png": "image/png", ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg", ".gif": "image/gif"}.get(ext, "image/png")
    return "data:%s;base64,%s" % (mime, base64.b64encode(blob).decode("ascii"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    mapping = load_manifest(args.manifest)
    html = open(args.template, encoding="utf-8").read()

    used, missing = set(), []
    for name in sorted(set(re.findall(r"\{\{IMG:([A-Za-z0-9_]+)\}\}", html))):
        p = mapping.get(name)
        if p is None:
            missing.append("%s (not in manifest)" % name)
            continue
        full = p if os.path.isabs(p) else os.path.join(ROOT, p)
        if not os.path.exists(full):
            missing.append("%s -> %s (file not found)" % (name, p))
            continue
        html = html.replace("{{IMG:%s}}" % name, data_uri(full))
        used.add(name)

    if missing:
        print("REFUSING - a page with a broken picture is worse than none:")
        for m in missing:
            print("  " + m)
        sys.exit(1)

    unused = sorted(set(mapping) - used)
    outp = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    with open(outp, "w", encoding="utf-8") as fh:
        fh.write(html)

    size = os.path.getsize(outp)
    print("wrote %s  (%d images, %.2f MB of a 16 MB ceiling)"
          % (args.out, len(used), size / 1048576.0))
    if unused:
        print("manifest entries not referenced:", ", ".join(unused))
    if size > 15 * 1048576:
        print("WARNING: close to the artifact size limit")


if __name__ == "__main__":
    main()
