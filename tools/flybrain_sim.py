#!/usr/bin/env python3
"""
flybrain_sim.py - step 2 of the fly-brain drone: prove the circuit offline, in
the same integer arithmetic a TMS34010 drone process would run.

Input is flynet_*.json from tools/flybrain_extract.py. Every cell type is one
node. The model is a leaky rate unit, deliberately made of the operations the
34010 has cheaply - add, subtract, shift, clamp, one small multiply per edge:

    per substep, for every non-sensory node i:
        I  = sum_j  sign_j * w_ij * a_j            w = quantised synapses/post neuron
        v += (I >> GAIN_SHIFT) - (v >> LEAK_SHIFT)
        a  = clamp(v - THETA, 0, 255)

Four substeps per 18.28ms game tick (4.57ms each) against a 20ms membrane
constant (Shiu et al. 2024) is a leak of dt/tau ~= 1/4, so LEAK_SHIFT = 2.

Sensory drive (per side, 0..255), from Ache et al. 2019: LC4 carries looming
VELOCITY (d theta/dt), LPLC2 carries looming SIZE with a Gaussian tuning in
theta, and only while the object is expanding. Theta is the angle an object
subtends at the drone: 2*atan(half_width / distance). THE TUNING CONSTANTS
BELOW ARE ASSUMPTIONS, flagged as such.

Motor readout per tick, by descending-neuron family:
    escape  DNp01 (giant fiber)    jump_fwd  DNp11
    jump_bk DNp02 + DNp04          retreat   MDN

Behavioural battery (evaluate): things the published circuit is known to do.
    silent   no escape family fires for things that are not looming
    precede  an approach or projectile fires escape/jump_bk BEFORE contact
    ordered  lead distance at firing grows with approach speed (a size threshold
             shifted by velocity, Ache 2019): Spearman rho over the speeds
    lateral  the escape neurons on the threat's side fire first

Control: --shuffle N rewires the graph N times (pre-synaptic endpoints permuted
across all edges, so every node keeps its in- and out-degree, every weight
survives, and a sign stays with its transmitter) and runs the same battery at
the same gain. If the real wiring is not clearly better than those, the
connectome is not doing the work.

    python tools/flybrain_sim.py --gain-sweep
    python tools/flybrain_sim.py --gain 9 --verbose
    python tools/flybrain_sim.py --gain-sweep --shuffle 100
    python tools/flybrain_sim.py --gain 9 --trace C:\\tmp\\flybrain\\traces\\x.csv
"""
import argparse
import csv
import json
import math
import random
import sys

SUBSTEPS = 4
LEAK_SHIFT = 2
THETA = 32                  # activity threshold above rest, in v units
VMAX = 1 << 14              # int16 headroom for v
FIRE = 64                   # family activity that counts as "fired"

# --- sensory tuning: ASSUMPTIONS -------------------------------------------
FIGHTER_HALF_W = 28         # px; a fighter's torso half-width
PROJ_HALF_W = 12            # px
BODY_GAP = 40               # px of distance that is just the two bodies touching
LC4_DEG_PER_TICK_FULL = 6.0     # d theta/dt (deg/tick) that saturates LC4
LPLC2_PEAK_DEG = 60.0
LPLC2_SIGMA_DEG = 25.0
# ---------------------------------------------------------------------------

FAMILIES = {
    "escape": ["DNp01"],
    "jump_fwd": ["DNp11"],
    "jump_bk": ["DNp02", "DNp04"],
    "retreat": ["MDN"],
}


def base(n):
    return n[:-2] if n.endswith(("_L", "_R")) else n


def side(n):
    return n[-1] if n.endswith(("_L", "_R")) else None


class Net:
    def __init__(self, net, min_per_post, wq):
        nodes = net["nodes"]
        self.names = sorted(nodes)
        self.idx = {n: i for i, n in enumerate(self.names)}
        self.group = [nodes[n]["group"] for n in self.names]
        self.sign = [nodes[n]["sign"] for n in self.names]
        self.edges = []     # (post, pre, w) with w a signed small integer
        for e in net["edges"]:
            if e["per_post"] < min_per_post or e["sign"] == 0:
                continue
            w = max(1, round(e["per_post"] / wq))
            self.edges.append((self.idx[e["post"]], self.idx[e["pre"]], w * e["sign"]))
        self.sense = {}
        for n, i in self.idx.items():
            if self.group[i] == "sense":
                self.sense[(base(n), side(n))] = i

    def shuffled(self, rng):
        c = object.__new__(Net)
        c.__dict__.update(self.__dict__)
        pres = [pre for _, pre, _ in self.edges]
        rng.shuffle(pres)
        c.edges = [(post, pre, abs(w) * (1 if self.sign[pre] >= 0 else -1))
                   for (post, _, w), pre in zip(self.edges, pres) if post != pre]
        return c


def theta_deg(dist, half_w):
    d = max(dist - BODY_GAP, 4.0)
    return math.degrees(2.0 * math.atan(half_w / d))


def sensory(frames):
    """frames: list of {drone_x, opp_x, proj: [x, ...]} -> per tick {(type, side): 0..255}."""
    out, prev = [], {}
    for f in frames:
        objs = [("opp", f["opp_x"], FIGHTER_HALF_W)] + \
               [(f"p{k}", x, PROJ_HALF_W) for k, x in enumerate(f.get("proj", []))]
        drive = {("LC4", "L"): 0, ("LC4", "R"): 0, ("LPLC2", "L"): 0, ("LPLC2", "R"): 0}
        now = {}
        for key, x, hw in objs:
            s = "R" if x >= f["drone_x"] else "L"
            th = theta_deg(abs(x - f["drone_x"]), hw)
            now[key] = th
            dth = th - prev.get(key, th)
            lc4 = int(255 * min(max(dth, 0.0) / LC4_DEG_PER_TICK_FULL, 1.0))
            # LPLC2 is selective for EXPANSION: its size tuning only applies while the
            # object is growing. A big thing standing still is not a loom.
            lp = int(255 * math.exp(-((th - LPLC2_PEAK_DEG) / LPLC2_SIGMA_DEG) ** 2)) if dth > 0.05 else 0
            drive[("LC4", s)] = min(255, drive[("LC4", s)] + lc4)
            drive[("LPLC2", s)] = min(255, drive[("LPLC2", s)] + lp)
        prev = now
        out.append(drive)
    return out


def run(net, drives, gain_shift):
    n = len(net.names)
    v = [0] * n
    a = [0] * n
    rows = []
    for d in drives:
        for (t, s), i in net.sense.items():
            a[i] = d.get((t, s), 0)
        peak = [0] * n
        for _ in range(SUBSTEPS):
            inp = [0] * n
            for post, pre, w in net.edges:
                if a[pre]:
                    inp[post] += w * a[pre]
            for i in range(n):
                if net.group[i] == "sense":
                    continue
                vi = v[i] + (inp[i] >> gain_shift) - (v[i] >> LEAK_SHIFT)
                vi = max(-VMAX, min(VMAX, vi))
                v[i] = vi
                a[i] = max(0, min(255, vi - THETA))
                if a[i] > peak[i]:
                    peak[i] = a[i]
        rows.append(peak)
    return rows


def families(net, rows):
    fam = {k: [0] * len(rows) for k in FAMILIES}
    for name, i in net.idx.items():
        for k, types in FAMILIES.items():
            if base(name) in types:
                for t, r in enumerate(rows):
                    fam[k][t] = max(fam[k][t], r[i])
    return fam


def by_side(net, rows, types):
    out = {"L": [0] * len(rows), "R": [0] * len(rows)}
    for name, i in net.idx.items():
        if base(name) in types and side(name):
            for t, r in enumerate(rows):
                out[side(name)][t] = max(out[side(name)][t], r[i])
    return out


def first(v, fire=FIRE):
    return next((t for t, x in enumerate(v) if x >= fire), None)


# ---------------------------------------------------------------------------
# Scenarios. Speeds are px/tick and APPROXIMATE until MAME traces replace them.
# The drone sits at x=0; positive x = threat on the RIGHT.
def scenario(start, speed, ticks=120, proj=None):
    fr = []
    for t in range(ticks):
        opp = start - speed * t
        if speed > 0:
            opp = max(opp, BODY_GAP)
        p = []
        if proj is not None:
            px = proj[0] - proj[1] * t
            if px > BODY_GAP:
                p = [px]
        fr.append({"drone_x": 0.0, "opp_x": opp, "proj": p})
    return fr


def mirrored(frames):
    return [{"drone_x": 0.0, "opp_x": -f["opp_x"], "proj": [-x for x in f["proj"]]} for f in frames]


def contact_tick(frames):
    for t, f in enumerate(frames):
        if abs(f["opp_x"]) <= BODY_GAP + 1:
            return t
        if t and frames[t - 1]["proj"] and not f["proj"]:
            return t
    return None


SILENT = {
    "stand_far": scenario(250, 0.0),
    "stand_close": scenario(70, 0.0),
    "walk_away": scenario(60, -2.5),
}
APPROACH_SPEEDS = [1.5, 2, 3, 4, 6, 9, 12]
PROJ_SPEEDS = [8, 10, 14]


def spearman(pairs):
    def ranks(xs):
        order = sorted(range(len(xs)), key=lambda i: xs[i])
        r = [0.0] * len(xs)
        for k, i in enumerate(order):
            r[i] = float(k)
        return r
    a = ranks([p[0] for p in pairs])
    b = ranks([p[1] for p in pairs])
    n = len(pairs)
    ma, mb = sum(a) / n, sum(b) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    va = math.sqrt(sum((x - ma) ** 2 for x in a))
    vb = math.sqrt(sum((y - mb) ** 2 for y in b))
    return cov / (va * vb) if va and vb else 0.0


def evaluate(net, gain_shift):
    esc_types = FAMILIES["escape"] + FAMILIES["jump_bk"]
    res = {"silent": 0, "precede": 0, "lateral": 0, "rows": []}
    for name, fr in SILENT.items():
        fam = families(net, run(net, sensory(fr), gain_shift))
        hit = [k for k in ("escape", "jump_bk") if first(fam[k]) is not None]
        res["silent"] += not hit
        res["rows"].append(("silent", name, "fired " + ",".join(hit) if hit else "quiet"))
    leads = []
    cases = [(f"approach_{v:g}", scenario(250, v), v) for v in APPROACH_SPEEDS] + \
            [(f"projectile_{v:g}", scenario(400, 0.0, proj=(250, v)), None) for v in PROJ_SPEEDS]
    for name, base_fr, speed in cases:
        for mirror in (False, True):
            fr = mirrored(base_fr) if mirror else base_fr
            rows = run(net, sensory(fr), gain_shift)
            fam = families(net, rows)
            ct = contact_tick(fr)
            fired = [t for t in (first(fam["escape"]), first(fam["jump_bk"])) if t is not None]
            ft = min(fired) if fired else None
            ok = ft is not None and ct is not None and ft < ct
            res["precede"] += ok
            sides = by_side(net, rows, esc_types)
            fl, fr_ = first(sides["L"]), first(sides["R"])
            if fl is None and fr_ is None:
                got = None
            elif fl is not None and fr_ is not None and fl == fr_:
                got = "both"
            elif fr_ is None or (fl is not None and fl < fr_):
                got = "L"
            else:
                got = "R"
            res["lateral"] += (got == ("L" if mirror else "R"))
            lead = None
            if ok:
                f = fr[ft]
                lead = (min([abs(f["opp_x"])] + [abs(x) for x in f["proj"]]) - BODY_GAP)
                if not mirror and speed is not None:
                    leads.append((speed, lead))
            res["rows"].append(("threat", name + ("_mirror" if mirror else ""),
                                f"contact@{ct} fire@{ft} side={got}" + (f" lead={lead:.0f}px" if lead is not None else "")))
    res["cases"] = 2 * len(cases)
    res["rho"] = spearman(leads) if len(leads) >= 3 else float("nan")
    return res


def total(r):
    return r["silent"] + r["precede"] + r["lateral"] + (0.0 if math.isnan(r["rho"]) else max(r["rho"], 0.0) * 3)


# --- no advantage over a player or the stock CPU (user requirement) ----------
# The fly sees what is on screen one tick late, and may not START an action any
# sooner than the stock drone reacts at the same difficulty: drone_react_delay
# in MKDRONE.ASM, diff 0..9. The action itself is an existing human move with
# its own startup; that part is not modelled here and is checked in the ROM.
PERCEPT_LAG = 1
DRONE_REACT_DELAY = [6, 6, 5, 5, 4, 4, 4, 3, 3, 3]
# ---------------------------------------------------------------------------

PROJ_OIDS = {"701"}      # Liu Kang's fireball, as tools/flybrain_trace.lua records it
LEAD_IN = 30             # ticks of the first frame repeated so the net settles before a trial


def load_trials(path):
    """tools/flybrain_trace.lua CSV -> [(trial, name, frames)]. Positions are made
    relative to the drone (P2) so the fly always sits at x=0."""
    trials = {}
    with open(path) as fh:
        for r in csv.DictReader(fh):
            dx = float(r["drone_x"])
            proj = []
            for o in filter(None, r["objs"].split("|")):
                oid, x, _y, _w = o.split(":")
                if oid in PROJ_OIDS:
                    proj.append(float(x) - dx)
            key = (int(r["trial"]), r["name"])
            trials.setdefault(key, []).append({"drone_x": 0.0, "opp_x": float(r["opp_x"]) - dx, "proj": proj})
    return [(t, n, fr) for (t, n), fr in sorted(trials.items())]


def hit_tick(name, frames):
    """When the threat actually arrives: the projectile's last frame alive, or the
    fighter's closest approach (within 2px of the minimum). None if it never comes."""
    if name == "walk_away":
        return None
    if name == "fireball":
        alive = [t for t, f in enumerate(frames) if f["proj"]]
        return alive[-1] if alive else None
    d = [abs(f["opp_x"]) for f in frames]
    m = min(d)
    if d[0] - m < 20:
        return None
    return next(t for t, x in enumerate(d) if x <= m + 2)


def evaluate_trials(net, trials, gain_shift, diff=9):
    delay = PERCEPT_LAG + DRONE_REACT_DELAY[diff]
    res = {"threat_ok": 0, "threats": 0, "calm_ok": 0, "calms": 0, "lateral": 0, "rows": []}
    for trial, name, frames in trials:
        fr = [frames[0]] * LEAD_IN + frames
        rows = run(net, sensory(fr), gain_shift)[LEAD_IN:]
        fam = families(net, rows)
        hit = hit_tick(name, frames)
        fired = {k: first(v) for k, v in fam.items()}
        esc = [t for t in (fired["escape"], fired["jump_bk"]) if t is not None]
        ft = min(esc) if esc else None
        if hit is None:
            res["calms"] += 1
            res["calm_ok"] += ft is None
            verdict = "quiet" if ft is None else f"FALSE ALARM @{ft}"
        else:
            res["threats"] += 1
            act = None if ft is None else ft + delay     # earliest a move may start
            ok = act is not None and act < hit
            res["threat_ok"] += ok
            sides = by_side(net, rows, FAMILIES["escape"] + FAMILIES["jump_bk"])
            want = "R" if frames[0]["opp_x"] > 0 or (frames[0]["proj"] and frames[0]["proj"][0] > 0) else "L"
            fl, frr = first(sides["L"]), first(sides["R"])
            if fl is None and frr is None:
                got = None
            elif fl is not None and frr is not None and fl == frr:
                got = "both"
            else:
                got = "L" if frr is None or (fl is not None and fl < frr) else "R"
            res["lateral"] += got == want
            verdict = (f"{'in time' if ok else 'LATE/MISSED'} fire@{ft} act@{act} hit@{hit}"
                       + (f" spare {hit - act} ticks ({(hit - act) * 18.28:.0f}ms)" if ok else "")
                       + f" side={got}/{want}")
        order = sorted((t, k) for k, t in fired.items() if t is not None)
        res["rows"].append((trial, name, verdict, " ".join(f"{k}@{t}" for t, k in order)))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--net", default=r"C:\tmp\flybrain\out\flynet_inter100.json")
    ap.add_argument("--min-per-post", type=float, default=20)
    ap.add_argument("--wq", type=float, default=64, help="synapses per weight unit")
    ap.add_argument("--gain", type=int, default=9, help="GAIN_SHIFT")
    ap.add_argument("--gain-sweep", action="store_true")
    ap.add_argument("--shuffle", type=int, default=0)
    ap.add_argument("--trace", help="CSV: drone_x,opp_x,proj (proj = ';'-joined x list)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--diff", type=int, default=9, help="difficulty 0-9: reaction-delay floor (trace mode)")
    ap.add_argument("--export-shuffled", type=int, help="with --export-lua: export a degree-preserving rewiring (seed)")
    ap.add_argument("--export-lua", help="write the quantised net as a Lua table (tools/flybrain_play.lua loads it)")
    args = ap.parse_args()

    net = Net(json.load(open(args.net)), args.min_per_post, args.wq)
    wmax = max(abs(w) for _, _, w in net.edges)
    fanin = max(sum(1 for p, _, _ in net.edges if p == i) for i in range(len(net.names)))
    print(f"net: {len(net.names)} nodes, {len(net.edges)} edges (>= {args.min_per_post:g} syn/post), "
          f"weights 1..{wmax} (x{args.wq:g} synapses), max fan-in {fanin}; "
          f"worst-case input {fanin * wmax * 255} (fits int32: {fanin * wmax * 255 < 2**31})")
    print(f"cost: {len(net.edges) * SUBSTEPS} weighted adds + {len(net.names) * SUBSTEPS} "
          f"node updates per tick, worst case")

    if args.export_lua:
        if args.export_shuffled is not None:
            # the rewired control, frozen to one seed so every run of it is the same brain
            net = net.shuffled(random.Random(args.export_shuffled))
        with open(args.export_lua, "w") as fh:
            fh.write(f"-- generated by tools/flybrain_sim.py --export-lua from {args.net}\n")
            fh.write(f"-- min_per_post {args.min_per_post:g}, wq {args.wq:g}; indices are 1-based\n")
            fh.write("return {\n  names = {")
            fh.write(",".join(f'"{n}"' for n in net.names))
            fh.write("},\n  group = {")
            fh.write(",".join(f'"{g}"' for g in net.group))
            fh.write("},\n  edges = {\n")
            for post, pre, w in net.edges:
                fh.write(f"    {{{post + 1},{pre + 1},{w}}},\n")
            fh.write("  },\n  constants = {substeps=%d, leak_shift=%d, theta=%d, vmax=%d, fire=%d},\n"
                     % (SUBSTEPS, LEAK_SHIFT, THETA, VMAX, FIRE))
            fh.write("  sensory = {fighter_half_w=%g, proj_half_w=%g, body_gap=%g, lc4_full=%g, "
                     "lplc2_peak=%g, lplc2_sigma=%g},\n"
                     % (FIGHTER_HALF_W, PROJ_HALF_W, BODY_GAP, LC4_DEG_PER_TICK_FULL,
                        LPLC2_PEAK_DEG, LPLC2_SIGMA_DEG))
            fh.write("  react_delay = {%s}, percept_lag = %d,\n" % (",".join(map(str, DRONE_REACT_DELAY)), PERCEPT_LAG))
            fh.write("}\n")
        print(f"wrote {args.export_lua}")
        return

    if args.trace:
        trials = load_trials(args.trace)
        gains = range(4, 12) if args.gain_sweep else [args.gain]
        best = None
        for g in gains:
            r = evaluate_trials(net, trials, g, args.diff)
            sc = r["threat_ok"] + r["calm_ok"] + r["lateral"]
            print(f"\ndiff {args.diff} (move may start {PERCEPT_LAG + DRONE_REACT_DELAY[args.diff]} ticks after firing) "
                  f"gain_shift {g}: threats in time {r['threat_ok']}/{r['threats']}  "
                  f"calm quiet {r['calm_ok']}/{r['calms']}  lateral {r['lateral']}/{r['threats']}")
            if args.verbose or not args.gain_sweep:
                for trial, name, verdict, order in r["rows"]:
                    print(f"    {trial:2} {name:9} {verdict:52} {order}")
            if best is None or sc > best[0]:
                best = (sc, g, r)
        if args.shuffle:
            sc, g, r = best
            rng = random.Random(args.seed)
            sh = []
            for _ in range(args.shuffle):
                x = evaluate_trials(net.shuffled(rng), trials, g, args.diff)
                sh.append((x["threat_ok"] + x["calm_ok"] + x["lateral"], x))
            for key in ("threat_ok", "calm_ok", "lateral"):
                vals = sorted(x[key] for _, x in sh)
                print(f"  shuffled {key:9} median {vals[len(vals) // 2]}  range {vals[0]}..{vals[-1]}  "
                      f"{sum(1 for v in vals if v >= r[key])}/{len(vals)} tie or beat real ({r[key]})")
            tots = sorted(s for s, _ in sh)
            print(f"  shuffled total     median {tots[len(tots) // 2]}  range {tots[0]}..{tots[-1]}  "
                  f"{sum(1 for v in tots if v >= sc)}/{len(tots)} tie or beat real ({sc}) at gain_shift {g}")
        return

    gains = range(4, 12) if args.gain_sweep else [args.gain]
    best = None
    for g in gains:
        r = evaluate(net, g)
        print(f"\ngain_shift {g}: silent {r['silent']}/{len(SILENT)}  precede {r['precede']}/{r['cases']}  "
              f"lateral {r['lateral']}/{r['cases']}  speed->lead rho {r['rho']:.2f}  score {total(r):.1f}")
        if args.verbose:
            for kind, name, txt in r["rows"]:
                print(f"    {kind:6} {name:22} {txt}")
        if best is None or total(r) > total(best[0]):
            best = (r, g)

    if args.shuffle:
        r, g = best
        rng = random.Random(args.seed)
        sh = [evaluate(net.shuffled(rng), g) for _ in range(args.shuffle)]
        print(f"\nreal wiring at gain_shift {g}: silent {r['silent']} precede {r['precede']} "
              f"lateral {r['lateral']} rho {r['rho']:.2f} score {total(r):.1f}")
        for key in ("silent", "precede", "lateral", "rho"):
            val = lambda x: -9.0 if isinstance(x[key], float) and math.isnan(x[key]) else x[key]
            vals = sorted(val(x) for x in sh)
            ge = sum(1 for x in vals if x >= val(r))
            print(f"  shuffled {key:8} median {vals[len(vals) // 2]:6.2f}  range {vals[0]:.2f}..{vals[-1]:.2f}  "
                  f"{ge}/{len(vals)} tie or beat real")
        tots = sorted(total(x) for x in sh)
        print(f"  shuffled score    median {tots[len(tots) // 2]:6.1f}  range {tots[0]:.1f}..{tots[-1]:.1f}  "
              f"{sum(1 for x in tots if x >= total(r))}/{len(tots)} tie or beat real")


if __name__ == "__main__":
    sys.exit(main())
