#!/usr/bin/env python3
"""Patch KFPITPL source BLIMP data with the live Pit Bottom extras.

This keeps the hand-added Pit Bottom objects reproducible:

* repeat the single 4x16 foreground spike sprite across the stage
* import the Sindel/Pit side corpse PNG as a BLIMP image and place it behind
  the right pillar, offset left so it peeks out
"""
from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TRIM_TOOL = ROOT / "stage_packs" / "kfpitbtm" / "tools" / "trim_blimp_background.py"

SINGLE_SPIKE_XS = (22, 86, 150, 214, 278, 342, 406, 470, 534, 598, 662, 726, 790, 855, 918, 982, 1046, 1110)
SINGLE_SPIKE_YS = (230, 214, 198, 193)
SINGLE_SPIKE = {"wx": 0x4200, "idx": 0xF3, "palette": 11}

SINDEL_IMAGE_ID = 0x13B
SINDEL_PALETTE_NAME = "SINDEL_PIT_P"
SINDEL_OBJECT = {"wx": 0x3F00, "x": 745, "y": 197, "idx": SINDEL_IMAGE_ID}


def load_trim_module():
    spec = importlib.util.spec_from_file_location("trim_blimp_background", TRIM_TOOL)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import {TRIM_TOOL}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def palette_name(header: str) -> str:
    return header.split()[0]


def ensure_sindel_asset(trim, images: dict[int, dict], palettes: list[tuple[str, bytes]]) -> int:
    image, palette = trim.import_gif_image(ROOT / "data" / "sindel_pit.png")
    images[SINDEL_IMAGE_ID] = image

    for index, (header, _payload) in enumerate(palettes):
        if palette_name(header) == SINDEL_PALETTE_NAME:
            palettes[index] = (f"{SINDEL_PALETTE_NAME} {header.split()[1]}", palette[1])
            return index

    _header, payload = palette
    color_count = int(_header.split()[1])
    palettes.append((f"{SINDEL_PALETTE_NAME} {color_count}", payload))
    return len(palettes) - 1


def ensure_repeated_single_spikes(objects: list[dict]) -> int:
    existing = {(obj["idx"], obj["palette"], obj["x"], obj["y"]) for obj in objects}
    added = 0
    for x in SINGLE_SPIKE_XS:
        for y in SINGLE_SPIKE_YS:
            key = (SINGLE_SPIKE["idx"], SINGLE_SPIKE["palette"], x, y)
            if key in existing:
                continue
            objects.append(
                {
                    "wx": SINGLE_SPIKE["wx"],
                    "x": x,
                    "y": y,
                    "idx": SINGLE_SPIKE["idx"],
                    "palette": SINGLE_SPIKE["palette"],
                }
            )
            existing.add(key)
            added += 1
    return added


def ensure_sindel_object(objects: list[dict], palette_index: int) -> None:
    objects[:] = [obj for obj in objects if obj["idx"] != SINDEL_IMAGE_ID]
    obj = dict(SINDEL_OBJECT)
    obj["palette"] = palette_index
    objects.append(obj)


def stable_sort_objects(objects: list[dict]) -> None:
    for index, obj in enumerate(objects):
        obj["_order"] = index
    objects.sort(key=lambda obj: (obj["wx"], obj["x"], obj["_order"]))
    for obj in objects:
        obj.pop("_order", None)


def main() -> int:
    trim = load_trim_module()
    bdb_path = ROOT / "data" / "KFPITPL.BDB"
    bdd_path = ROOT / "data" / "KFPITPL.BDD"

    images, palettes = trim.load_bdd(bdd_path)
    header, _modules, objects = trim.load_bdb(bdb_path)

    palette_index = ensure_sindel_asset(trim, images, palettes)
    spike_count = ensure_repeated_single_spikes(objects)
    ensure_sindel_object(objects, palette_index)
    stable_sort_objects(objects)

    used_indices = sorted({obj["idx"] for obj in objects})
    trim.write_bdb(bdb_path, header[0], int(header[1]), int(header[2]), len(palettes), objects)
    trim.write_bdd(bdd_path, images, used_indices, palettes)

    print(f"patched {bdb_path}")
    print(f"patched {bdd_path}")
    print(f"added {spike_count} spike records; objects={len(objects)} images={len(used_indices)} palettes={len(palettes)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
