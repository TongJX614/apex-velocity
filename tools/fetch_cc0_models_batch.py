#!/usr/bin/env python3
"""Batch-fetch additional Poly Haven CC0 models for the high-fidelity scenery pass.

Source: https://polyhaven.com  |  License: CC0 1.0 Universal (public domain).
Downloads the 1k-texture glTF variant (geometry is shared across resolutions),
then drops a .gdignore in each folder so Godot never imports the multi-million
polygon originals -- only the decimated LOD GLBs in assets/venues/ are imported.

Usage:
    python3 tools/fetch_cc0_models_batch.py grass_bermuda_01 rock_face_01 ...
    python3 tools/fetch_cc0_models_batch.py --all
"""
import json
import os
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PH = os.path.join(ROOT, "assets", "thirdparty", "polyhaven", "models")

# High-fidelity CC0 replacements for the remaining hand-built low-poly props.
# group -> asset ids (used by tools/blender/decimate_cc0_batch.py too)
GROUPS = {
    "ground cover / grass": [
        "grass_bermuda_01", "grass_medium_02", "weed_plant_02", "moss_01", "shrub_01",
    ],
    "rocks / cliffs": [
        "rock_face_01", "namaqualand_boulder_02", "namaqualand_boulder_03",
        "rock_moss_set_01", "mountainside", "coast_rocks_01",
    ],
    "trees": ["searsia_lucida"],
    "road / industrial modulars": [
        "concrete_road_barrier_02", "modular_factory_facade", "modular_chainlink_fence",
        "modular_electricity_poles", "modular_fire_escape", "water_manhole_cover",
        "rollershutter_door",
    ],
}
ALL = [a for group in GROUPS.values() for a in group]


def api(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=40) as resp:
        return json.load(resp)


def download(url: str, dest: str, expected: int) -> str:
    if os.path.exists(dest) and os.path.getsize(dest) >= max(1024, expected * 0.98):
        return "cached " + os.path.basename(dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    for attempt in range(3):
        proc = subprocess.run(
            ["curl", "-fLsS", "--retry", "2", "--max-time", "300", "-A", UA,
             "-o", dest, url],
            capture_output=True, text=True,
        )
        if proc.returncode == 0 and os.path.exists(dest) and os.path.getsize(dest) > 1024:
            return "ok %-58s %6.1f MB" % (os.path.relpath(dest, PH),
                                          os.path.getsize(dest) / 1048576)
    return "FAIL " + os.path.basename(dest) + " " + (proc.stderr.strip()[:120])


def fetch_asset(asset: str):
    files = api("https://api.polyhaven.com/files/" + asset)
    node = files.get("gltf", {}).get("1k", {}).get("gltf")
    if not node:
        return [asset + ": no 1k gltf"]
    base = os.path.join(PH, asset)
    os.makedirs(base, exist_ok=True)
    # keep Godot away from the multi-million-poly source files
    ignore = os.path.join(base, ".gdignore")
    if not os.path.exists(ignore):
        with open(ignore, "w", encoding="utf-8") as fh:
            fh.write("")
    jobs = [(node["url"], os.path.join(base, asset + ".gltf"), node.get("size", 0))]
    for rel, entry in node.get("include", {}).items():
        if entry.get("url"):
            jobs.append((entry["url"], os.path.join(base, rel), entry.get("size", 0)))
    results = []
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = [pool.submit(download, *job) for job in jobs]
        for fut in as_completed(futures):
            results.append(fut.result())
    return ["[%s] %d files" % (asset, len(jobs))] + sorted(results)


def main():
    assets = sys.argv[1:]
    if not assets or assets == ["--all"]:
        assets = ALL
    print("Poly Haven CC0 batch fetch: %d assets" % len(assets))
    failed = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(fetch_asset, a): a for a in assets}
        for fut in as_completed(futures):
            lines = fut.result()
            print("\n".join(lines), flush=True)
            if any("FAIL" in line for line in lines):
                failed.append(futures[fut])
    print("\nDONE. failed: %s" % (", ".join(failed) if failed else "none"))


if __name__ == "__main__":
    main()
