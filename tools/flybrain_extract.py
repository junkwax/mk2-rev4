#!/usr/bin/env python3
"""
flybrain_extract.py - pull a fight-sized circuit out of the MaleCNS v1.0 connectome.

Step 1 of the fly-brain drone experiment. Reads the flat connectome published at
https://male-cns.janelia.org/download/ (CC-BY 4.0), picks seed cell types that
have a defensible meaning in a fight, finds the interneurons that actually link
them, and merges every cell type into ONE node (synapse counts summed), which is
the only size a TMS34010 drone process could step every tick.

Seeds are grouped by what they mean to the drone:
  sense  - looming detectors: LC4 (looming speed) and LPLC2 (looming size)
  motor  - descending neurons with a known behaviour: DNp01 = giant fiber (short
           escape), DNp11 (forward jump), DNp02 + DNp04 (backward jump),
           MDN (walk backwards), DNa01/DNa02 (steering, kept per side)
  state  - TENTATIVE aggression/escalation candidates: OA-VPM4, MBON11, aIPg*,
           pC1_*. The female-aggression literature names aIPg / pC1d,e; the male
           P1 cluster has no 'P1' label in this release, so these are guesses to
           be checked, not established mappings.

Nothing here touches src/ or the ROM. Output goes to <data>/out/.

    python tools/flybrain_extract.py                         # C:\\tmp\\flybrain
    python tools/flybrain_extract.py --data D:\\fly --min-inter 100
Needs pyarrow + pandas (C:\\tmp\\flybrain\\.venv has them).
"""
import argparse
import json
import os
import sys
import time

import pandas as pd
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.dataset as ds
import pyarrow.feather as feather

ANN = "body-annotations-male-cns-v1.0-minconf-0.5.feather"
NT = "body-neurotransmitters-male-cns-v1.0.feather"
W = "connectome-weights-male-cns-v1.0-minconf-0.5.feather"

SENSE = ["LC4", "LPLC2"]
# --ears-eyes adds the senses the rig grew on 2026-09-19, each a cell type carrying exactly
# what the fly can now measure in the game:
#   JO-*               Johnston's organ, the fly's EAR - the rig taps every sound the game plays
#   HSN/HSE/HSS/VS/H2  lobula plate wide-field cells: self motion, which the rig reads as the
#                      camera's travel. They already feed the DNa01/DNa02 steering in the net
#   LC11               small-object motion - every moving speck, which the rig now passes in
#   LPLC1, LC6         two more looming channels beside LC4/LPLC2
#   OCG01*             the ocelli: light level and flicker (the screen flash)
#   LC10a           the CHASE cells - object tracking, what a fly pursues with.  Taken from
#                   alextitonis/fly.ai's sshfighter, which drives LC10a with "opponent
#                   location, stronger when near".  Our fly had looming ("he is coming at
#                   me") and no pursuit channel at all.
SENSE2_EXACT = ["HSN", "HSE", "HSS", "VS", "H2", "LC11", "LPLC1", "LC6", "LC10a"]
SENSE2_PREFIX = ["JO-", "OCG01"]
# --ears-eyes also takes two more DESCENDING neurons as motor seeds, from the same project:
# pIP10 (kick) and DNg100 (forward walking).  The net already carries DNa01/DNa02 steering.
MOTOR2 = ["pIP10", "DNg100"]
MOTOR = ["DNp01", "DNp11", "DNp02", "DNp04", "MDN", "DNa01", "DNa02"]
SIDED = {"DNa01", "DNa02"}          # steering: left cell turns left, keep sides apart
STATE_EXACT = ["OA-VPM4", "MBON11"]
STATE_PREFIX = ["aIPg", "pC1_"]
# --octopamine seeds the brain's octopaminergic clusters as state, for the fly's mood to be
# READ from them instead of kept as a hand-tuned number. Octopamine is the fly's
# fight-or-flight transmitter and is required for aggression; OA-VPM and OA-AL2 are the
# clusters the aggression studies name. These are the cb_intrinsic octopamine types of
# MaleCNS v1.0 (consensus_nt): 35 bodies. The other 66 octopamine cells are nerve-cord
# efferents (EN00B*, EL) that modulate muscle - not a mood, so left out.
# OA-ASM1 only: the names say octopamine but the transmitters do not agree for the rest of
# that family - OA-ASM3 is SEROTONIN and OA-ASM2 is "unclear" in consensus_nt.
OA_PREFIX = ["OA-VUMa", "OA-VPM", "OA-AL2", "OA-ASM1"]

# Shiu et al. 2024 convention: ACh excites, GABA and glutamate inhibit.
SIGN = {"acetylcholine": 1, "gaba": -1, "glutamate": -1}


def log(*a):
    print(*a, flush=True)


def load_tables(data):
    ann = feather.read_table(os.path.join(data, ANN),
                             columns=["bodyId", "type", "instance", "somaSide",
                                      "superclass", "statusLabel", "dimorphism",
                                      "somaNeuromere"]).to_pandas()
    nt = feather.read_table(os.path.join(data, NT),
                            columns=["body", "consensus_nt", "celltype_predicted_nt"]).to_pandas()
    nt = nt.drop_duplicates("body").set_index("body")
    return ann, nt


def transmitter(nt, body):
    if body not in nt.index:
        return "unknown"
    row = nt.loc[body]
    v = row.consensus_nt
    if not isinstance(v, str) or v == "unclear":
        v = row.celltype_predicted_nt
    return v if isinstance(v, str) else "unknown"


def node_name(t, side, sided_all):
    if not isinstance(side, str) or side not in ("L", "R"):
        return t
    return f"{t}_{side}" if sided_all or t in SIDED else t


def scan(data, bodies, both=False):
    """Every weighted edge with pre OR post (or, with both=True, pre AND post) in bodies."""
    dset = ds.dataset(os.path.join(data, W), format="ipc")
    ids = pa.array(sorted(int(b) for b in bodies), type=pa.int64())
    fp = pc.is_in(ds.field("body_pre"), value_set=ids)
    fq = pc.is_in(ds.field("body_post"), value_set=ids)
    t = dset.to_table(filter=(fp & fq) if both else (fp | fq))
    return t.to_pandas()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--data", default=r"C:\tmp\flybrain")
    ap.add_argument("--min-inter", type=int, default=50,
                    help="interneuron must take >= N synapses from sense/state seeds "
                         "AND give >= N to motor/state seeds (default 50)")
    ap.add_argument("--merge-sides", action="store_true",
                    help="merge left and right cells of a type (only DNa01/DNa02 stay split). "
                         "Default keeps every type split by soma side: the looming detectors have "
                         "to say WHICH side the threat is on or steering has nothing to steer by")
    ap.add_argument("--no-state", action="store_true", help="leave out the tentative state seeds")
    ap.add_argument("--ears-eyes", action="store_true",
                    help="add the ear (JO), wide-field flow (HS/VS/H2), small-object motion (LC11), "
                         "the other looming channels (LPLC1/LC6) and the ocelli (OCG01) as senses")
    ap.add_argument("--octopamine", action="store_true",
                    help="add the brain's octopamine clusters (OA-VUMa/VPM/AL2/ASM) as state seeds")
    ap.add_argument("--body", action="store_true",
                    help="add the ASCENDING neurons (the body reporting to the brain) as a 'body' "
                         "group: inputs the rig drives, which do not recruit interneurons")
    ap.add_argument("--body-min", type=int, default=1000,
                    help="keep an ascending type only if it sends >= N synapses into the circuit")
    args = ap.parse_args()
    out = os.path.join(args.data, "out")
    os.makedirs(out, exist_ok=True)

    t0 = time.time()
    ann, nt = load_tables(args.data)
    ann = ann[ann.statusLabel != "Glia"]
    t = ann.type.fillna("").astype(str)

    # An ascending neuron's class carries the body SEGMENT it reports from, because the
    # annotations say nothing finer: no modality, no entry nerve, only where the soma is.
    # T1 = front legs, T2 = mid legs and wings, T3 = hind legs and halteres, A = abdomen
    # (A1-A9), X = no segment recorded - NOT abdomen: filing unknowns as A put "abdomen"
    # cells in the brain on the atlas.
    def segment(nm):
        if nm in ("T1", "T2", "T3"):
            return nm
        return "A" if isinstance(nm, str) and nm.startswith("A") else "X"

    group = {}
    for b, ty, sc, nm in zip(ann.bodyId, t, ann.superclass, ann.somaNeuromere):
        if ty in SENSE or (args.ears_eyes and (ty in SENSE2_EXACT
                                               or any(ty.startswith(p) for p in SENSE2_PREFIX))):
            group[b] = "sense"
        elif ty in MOTOR or (args.ears_eyes and ty in MOTOR2):
            group[b] = "motor"
        elif not args.no_state and (ty in STATE_EXACT or any(ty.startswith(p) for p in STATE_PREFIX)
                                    or (args.octopamine and any(ty.startswith(p) for p in OA_PREFIX))):
            group[b] = "state"
        elif args.body and sc == "ascending_neuron":
            # NOT "sense": a sense seed recruits every interneuron it feeds, and 1,846 of
            # these would balloon the circuit. The body only reports INTO what is there.
            group[b] = "body_" + segment(nm)
    info = ann.set_index("bodyId")
    log(f"seeds: {len(group)} bodies  "
        f"(sense {sum(g=='sense' for g in group.values())}, "
        f"motor {sum(g=='motor' for g in group.values())}, "
        f"state {sum(g=='state' for g in group.values())}, "
        f"body {sum(g.startswith('body') for g in group.values())})  [{time.time()-t0:.0f}s]")

    # Pass 1: everything touching a seed.
    e1 = scan(args.data, group.keys())
    log(f"pass 1: {len(e1):,} edges touching seeds  [{time.time()-t0:.0f}s]")

    pre_g = e1.body_pre.map(group)
    post_g = e1.body_post.map(group)
    into = e1[pre_g.isin(["sense", "state"]) & post_g.isna()].groupby("body_post").weight.sum()
    outof = e1[post_g.isin(["motor", "state"]) & pre_g.isna()].groupby("body_pre").weight.sum()
    both = pd.concat([into.rename("in"), outof.rename("out")], axis=1).fillna(0)
    both = both[both.index.isin(info.index)]

    log("interneuron candidates by threshold (min of in/out synapses):")
    for th in (10, 20, 50, 100, 200, 500):
        log(f"  >= {th:4}: {int(((both['in'] >= th) & (both['out'] >= th)).sum()):6} bodies")
    inter = both[(both["in"] >= args.min_inter) & (both["out"] >= args.min_inter)]
    for b in inter.index:
        group[b] = "inter"
    log(f"kept {len(inter)} interneurons at >= {args.min_inter}")

    # Pass 2: the closed subgraph, seeds + interneurons.
    e2 = scan(args.data, group.keys(), both=True)
    log(f"pass 2: {len(e2):,} body-to-body edges in the subgraph  [{time.time()-t0:.0f}s]")

    # The body only matters as far as the circuit LISTENS to it: an ascending type is kept
    # if its cells send >= --body-min synapses into the rest of the circuit, and nothing
    # it receives counts (its inputs are in the nerve cord, which is not modelled).
    if args.body:
        is_body = {b for b, g in group.items() if g.startswith("body")}
        tmap = {b: (info.loc[b].type if isinstance(info.loc[b].type, str) else f"untyped{b}")
                for b in is_body}                      # once per body, not once per edge
        to_circ = e2[e2.body_pre.isin(is_body) & ~e2.body_post.isin(is_body)]
        per_type = to_circ.groupby(to_circ.body_pre.map(tmap)).weight.sum()
        log("ascending types by synapses into the circuit:")
        for th in (100, 500, 1000, 2000, 4000):
            log(f"  >= {th:5}: {int((per_type >= th).sum()):4} types")
        keep = set(per_type[per_type >= args.body_min].index)
        drop = {b for b in is_body if tmap[b] not in keep}
        for b in drop:
            del group[b]
        e2 = e2[~e2.body_pre.isin(drop) & ~e2.body_post.isin(drop)]
        # and an ascending cell listens to nothing here - only what it SAYS is kept
        e2 = e2[~e2.body_post.isin(is_body - drop)]
        log(f"kept {len(keep)} ascending types ({len(is_body) - len(drop)} bodies) at >= {args.body_min}")

    # Merge bodies into cell-type nodes.
    bnode, bnt = {}, {}
    for b in group:
        r = info.loc[b]
        ty = r.type if isinstance(r.type, str) else f"untyped{b}"
        bnode[b] = node_name(ty, r.somaSide, not args.merge_sides)
        bnt[b] = transmitter(nt, b)
    nodes = {}
    for b, n in bnode.items():
        d = nodes.setdefault(n, {"group": group[b], "bodies": 0, "nt": {}})
        d["bodies"] += 1
        d["nt"][bnt[b]] = d["nt"].get(bnt[b], 0) + 1
        if group[b] != "inter":
            d["group"] = group[b]
    for n, d in nodes.items():
        d["transmitter"] = max(d["nt"], key=d["nt"].get)
        d["sign"] = SIGN.get(d["transmitter"], 0)

    e2["pre"] = e2.body_pre.map(bnode)
    e2["post"] = e2.body_post.map(bnode)
    m = e2.groupby(["pre", "post"]).weight.sum().reset_index()
    # Mean synapses one post-synaptic neuron of that type receives from the whole pre type:
    # the drive a merged node actually integrates.
    m["per_post"] = m.weight / m.post.map(lambda n: nodes[n]["bodies"])
    m["sign"] = m.pre.map(lambda n: nodes[n]["sign"])
    m = m[m.pre != m.post].sort_values("weight", ascending=False)

    log(f"\nmerged: {len(nodes)} nodes, {len(m)} type-to-type edges")
    for th in (1, 5, 20, 50, 100):
        log(f"  edges with >= {th:3} synapses per post neuron: {int((m.per_post >= th).sum())}")

    log("\nnodes (group, bodies, transmitter):")
    order = {"sense": 0, "state": 1, "inter": 2, "motor": 3}
    order.update({"body_T1": 0.1, "body_T2": 0.2, "body_T3": 0.3, "body_A": 0.4, "body_X": 0.5})
    for n, d in sorted(nodes.items(), key=lambda kv: (order[kv[1]["group"]], -kv[1]["bodies"])):
        if d["group"] != "inter":
            log(f"  {d['group']:5} {n:14} {d['bodies']:4}  {d['transmitter']}")
    inter_nodes = [n for n, d in nodes.items() if d["group"] == "inter"]
    log(f"  inter: {len(inter_nodes)} merged types")

    log("\nstrongest inputs to each motor node (synapses/post neuron, sign):")
    for n, d in sorted(nodes.items()):
        if d["group"] != "motor":
            continue
        top = m[m.post == n].sort_values("per_post", ascending=False).head(6)
        s = ", ".join(f"{r.pre}({nodes[r.pre]['group'][0]}) {r.per_post:.0f}{'+' if r.sign > 0 else '-' if r.sign < 0 else '?'}"
                      for r in top.itertuples())
        log(f"  {n:8} <- {s}")

    gf = m[(m.post == "DNp01") & m.pre.isin(SENSE)]
    log("\ndirect looming -> giant fiber (total synapses, bodies are both GF cells):")
    for r in gf.itertuples():
        log(f"  {r.pre} -> DNp01: {int(r.weight)}")

    res = {"source": "MaleCNS v1.0 minconf 0.5 (CC-BY 4.0)", "min_inter": args.min_inter,
           "sided": not args.merge_sides, "state": not args.no_state,
           "nodes": nodes,
           "edges": [{"pre": r.pre, "post": r.post, "synapses": int(r.weight),
                      "per_post": round(float(r.per_post), 2), "sign": int(r.sign)}
                     for r in m.itertuples()]}
    tag = (("" if args.no_state else "_state") + ("_oa" if args.octopamine else "")
           + ("_body" if args.body else "")
           + ("_merged" if args.merge_sides else ""))
    path = os.path.join(out, f"flynet_inter{args.min_inter}{tag}.json")
    with open(path, "w") as fh:
        json.dump(res, fh, indent=1)
    log(f"\nwrote {path}  [{time.time()-t0:.0f}s]")


if __name__ == "__main__":
    sys.exit(main())
