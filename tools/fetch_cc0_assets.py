#!/usr/bin/env python3
"""Fetch CC0 assets from Poly Haven (skip high-poly originals for trees).

Downloads 1k PBR textures, a 2k HDRI sky and a few glTF props into
assets/thirdparty/polyhaven/, then optionally decimates the props in Blender.
All assets are CC0 (public domain); see assets/thirdparty/polyhaven/README.md.
"""
import json
import os
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..",
                                    "assets", "thirdparty", "polyhaven"))
API = "https://api.polyhaven.com"


def api(path):
    req = urllib.request.Request(API + path, headers=UA)
    with urllib.request.urlopen(req, timeout=40) as resp:
        return json.load(resp)


def fetch(url, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) > 1024:
        return
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as fh:
        fh.write(resp.read())
    print("  ok", os.path.relpath(dest, ROOT), "%.1f MB" % (os.path.getsize(dest) / 1048576))


def fetch_texture(asset_id):
    files = api("/files/" + asset_id)
    out_dir = os.path.join(ROOT, "textures", asset_id)
    wanted = {"Diffuse": "diff", "nor_gl": "nor", "Rough": "rough"}
    for key, suffix in wanted.items():
        node = files.get(key)
        if not node:
            continue
        entry = node.get("1k", {}).get("jpg")
        if not entry:
            continue
        fetch(entry["url"], os.path.join(out_dir, "%s_%s.jpg" % (asset_id, suffix)))
    print("[tex]", asset_id)


def fetch_hdri(asset_id):
    files = api("/files/" + asset_id)
    node = files.get("hdri", {}).get("2k", {}).get("hdr")
    if node:
        fetch(node["url"], os.path.join(ROOT, "hdri", asset_id + "_2k.hdr"))
        print("[hdri]", asset_id)


def fetch_model(asset_id):
    files = api("/files/" + asset_id)
    node = files.get("gltf", {}).get("1k", {}).get("gltf")
    if not node:
        print("[model] no gltf for", asset_id)
        return
    base_dir = os.path.join(ROOT, "models", asset_id)
    fetch(node["url"], os.path.join(base_dir, asset_id + ".gltf"))
    for rel, entry in node.get("include", {}).items():
        url = entry.get("url")
        if url:
            fetch(url, os.path.join(base_dir, rel))
    print("[model]", asset_id)


def main():
    os.makedirs(os.path.join(ROOT, "textures"), exist_ok=True)
    print("Textures:")
    for tex in ["asphalt_02", "grass_ground", "coast_sand_01", "brushed_concrete", "metal_plate"]:
        try:
            fetch_texture(tex)
        except Exception as exc:  # noqa: BLE001
            print("  FAIL", tex, exc)
    print("HDRI:")
    try:
        fetch_hdri("kloofendal_38d_partly_cloudy_puresky")
    except Exception as exc:  # noqa: BLE001
        print("  puresky missing, trying full sky", exc)
        fetch_hdri("kloofendal_38d_partly_cloudy")
    print("Models:")
    for model in ["boulder_01", "concrete_road_barrier"]:
        try:
            fetch_model(model)
        except Exception as exc:  # noqa: BLE001
            print("  FAIL", model, exc)
    readme = """# Third-party assets — Poly Haven (CC0)

Fetched by `tools/fetch_cc0_assets.py` from polyhaven.com (CC0 public domain).

| Folder | Contents |
| --- | --- |
| `textures/asphalt_02` | road asphalt PBR (diffuse / normal / roughness) |
| `textures/grass_ground` | grass ground PBR |
| `textures/coast_sand_01` | beach sand PBR |
| `textures/brushed_concrete` | venue concrete PBR |
| `textures/metal_plate` | barrier / metal PBR |
| `hdri/kloofendal_38d_partly_cloudy_puresky_2k.hdr` | coastal daytime sky + IBL |
| `models/boulder_01`, `models/coast_rocks_01`, `models/concrete_road_barrier` | glTF props (high-poly originals, decimated copies in `_lod/`) |
"""
    with open(os.path.join(ROOT, "README.md"), "w", encoding="utf-8") as fh:
        fh.write(readme)
    print("done:", ROOT)


if __name__ == "__main__":
    main()
