"""Read an IMGTOOL World View project (.wax, .wvp before v3.32.0) and
print one slot as a plain
tick-by-tick table, with frame indices resolved to real IMG record names.

The project file is the source of truth for the lane; a pasted export draft
goes stale
the moment the project is edited again.  frame_mirror is a bitmask:
bit0 = flip X, bit1 = flip Y.

Also flags the LOAD2 name-binding trap: these libraries carry several records
with the SAME name (artist original / trimmed / re-anchored), and LOAD2 binds a
`--->` name to the HIGHEST index with that name.  If a slot references a lower
duplicate, the ASM label will NOT point at the frame that was authored.
"""
import os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_HDR = struct.Struct("<HHIHHHHH 4s HHH")
IMAGE = struct.Struct("<16s HHH HH H II H HHH HHH")


def img_names(path):
    b = open(path, "rb").read()
    imgcnt, palcnt, oset = LIB_HDR.unpack_from(b, 0)[:3]
    out = []
    for i in range(imgcnt):
        f = IMAGE.unpack_from(b, oset + i * IMAGE.size)
        out.append((f[0].split(b"\0", 1)[0].decode("latin-1"), f[4], f[5]))
    return out


def parse(path):
    kv = {}
    for line in open(path, "r", errors="replace"):
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def ints(kv, key):
    v = kv.get(key, "")
    return [int(x) for x in v.split(",") if x.strip() != ""] if v else []


def main(wvp, slot=0):
    kv = parse(wvp)
    docs = []
    for i in range(int(kv.get("doc.count", "0"))):
        p = kv.get(f"doc.{i}.path", "")
        p = os.path.join(ROOT, "data", os.path.basename(p))
        docs.append((p, img_names(p) if os.path.exists(p) else []))

    own = int(kv.get(f"slot.{slot}.doc_idx", "0"))
    seq = ints(kv, f"slot.{slot}.sequence_frames")
    dly = ints(kv, f"slot.{slot}.frame_delays")
    mir = ints(kv, f"slot.{slot}.frame_mirror")
    dx = ints(kv, f"slot.{slot}.local_dx")
    dy = ints(kv, f"slot.{slot}.local_dy")
    di = ints(kv, f"slot.{slot}.frame_doc_idx")

    print(f"\n=== {os.path.basename(wvp)}  slot {slot} ===")
    print(f"slot mirror={kv.get(f'slot.{slot}.mirror')}  hold_end="
          f"{kv.get(f'slot.{slot}.hold_end')}  "
          f"tick_hz={kv.get('state.tick_hz', kv.get('state.fps', '?'))}  "
          f"entries={len(seq)}")
    print(f"{'#':>2} {'idx':>4} {'doc':>3} {'record':<14} {'wxh':>8} "
          f"{'dly':>3} {'mirror':<12} {'dx':>5} {'dy':>5}")
    prev_dx = prev_dy = 0
    for i, fi in enumerate(seq):
        d = di[i] if i < len(di) else -1
        d = own if d < 0 else d
        path, names = docs[d] if d < len(docs) else ("?", [])
        nm, w, h = names[fi] if fi < len(names) else ("<oob>", 0, 0)
        m = mir[i] if i < len(mir) else 0
        mtxt = ("flipX " if m & 1 else "") + ("flipY" if m & 2 else "")
        ax = dx[i] if i < len(dx) else 0
        ay = dy[i] if i < len(dy) else 0
        # duplicate-name warning
        dup = [j for j, (n2, _, _) in enumerate(names) if n2 == nm]
        warn = ""
        if len(dup) > 1 and fi != max(dup):
            warn = f"  <-- name also at {dup}; LOAD2 binds {max(dup)}"
        print(f"{i:>2} {fi:>4} {d:>3} {nm:<14} {w:>3}x{h:<4} "
              f"{dly[i] if i < len(dly) else 1:>3} {mtxt or '-':<12} "
              f"{ax:>5} {ay:>5}   d=({ax-prev_dx:>4},{ay-prev_dy:>4})"
              f"  {os.path.basename(path)}{warn}")
        prev_dx, prev_dy = ax, ay


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 0)
