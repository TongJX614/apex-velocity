#!/usr/bin/env python3
"""Fetch the extra CC0 Poly Haven PBR textures used by the scenery pass.

All assets are CC0 1.0 Universal (public domain): https://polyhaven.com/license
Drops 1k diffuse / OpenGL normal / roughness maps into
assets/thirdparty/polyhaven/textures/<id>/<id>_{diff,nor,rough}.jpg
"""
import json
import os
import sys
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..",
                                    "assets", "thirdparty", "polyhaven"))
API = "https://api.polyhaven.com"

TEXTURES = [
    "container_side",     # shipping-container corrugation (harbor stacks)
    "corrugated_iron",    # warehouse / industrial shed walls
    "rusty_corrugated_iron",  # magma refinery / volcano shed
    "wood_planks",        # pier planks / wooden cabins / sheds
    "weathered_planks",   # canyon shack / alpine hut cladding
    "dark_rock",          # magma basalt pillars
    "snow_01",            # glacier / alpine snow banks
    # --- 第二次校准：CBD 城市立面（真实 CC0 墙面/瓷砖立面） ---
    "rectangular_facade_tiles",   # 办公楼玻璃/瓷砖立面，CBD 高楼主材
    "concrete_tile_facade",       # 混凝土瓷砖立面
    "dark_brick_wall",            # 深色砖墙（老城区/街墙）
    "painted_plaster_wall",       # 涂装石膏外墙（公寓街区）
    # --- 峡谷干裂地 ---
    "dry_ground_rocks",           # 干裂地面 + 碎石
]


def api(path):
    req = urllib.request.Request(API + path, headers=UA)
    with urllib.request.urlopen(req, timeout=40) as resp:
        return json.load(resp)


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 1024:
        return True
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as fh:
        fh.write(resp.read())
    print("  ok", os.path.relpath(dest, ROOT), "%.2f MB" % (os.path.getsize(dest) / 1048576))
    return True


def main():
    wanted = {"Diffuse": "diff", "nor_gl": "nor", "Rough": "rough"}
    for asset_id in TEXTURES:
        print("[tex]", asset_id)
        try:
            files = api("/files/" + asset_id)
        except Exception as exc:  # noqa: BLE001
            print("  FAIL api", asset_id, exc)
            continue
        for key, suffix in wanted.items():
            node = files.get(key)
            if not node:
                continue
            entry = node.get("1k", {}).get("jpg") or node.get("1k", {}).get("png")
            if not entry:
                continue
            try:
                fetch(entry["url"], os.path.join(
                    ROOT, "textures", asset_id, "%s_%s.%s" % (
                        asset_id, suffix, "png" if entry["url"].endswith(".png") else "jpg")))
            except Exception as exc:  # noqa: BLE001
                print("  FAIL", asset_id, suffix, exc)
    print("done")


if __name__ == "__main__":
    main()
