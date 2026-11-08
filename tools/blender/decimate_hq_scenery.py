#!/usr/bin/env python3
"""Decimate the second Poly Haven CC0 batch into game-ready LOD GLBs.

Run headless:
  /Users/tong/Applications/Blender.app/Contents/MacOS/Blender -b --python \
      tools/blender/decimate_hq_scenery.py

Source models: assets/thirdparty/polyhaven/models/<id>/<id>.gltf  (CC0)
Output LODs  : assets/venues/<out>.glb

Design notes:
* Poly Haven originals are photogrammetry scans (up to 1.27M tris here);
  they are far too heavy to instance hundreds of times in a racing game.
* Objects are NOT joined -- each material stays on its own mesh so Godot can
  build one MultiMesh per surface without losing textures.
* Leaf/grass cards are decimated conservatively so silhouettes survive.
"""
import os
import sys

import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PH = os.path.join(ROOT, "assets", "thirdparty", "polyhaven", "models")
OUT = os.path.join(ROOT, "assets", "venues")
os.makedirs(OUT, exist_ok=True)

# (poly haven asset id, output glb, decimate ratio)
ASSETS = [
    # --- ground cover / grass (replaces hand-built grass_clump.glb) ---
    # NOTE: Poly Haven's 1k grass glTFs are already light alpha-card clusters
    # (941 / 7842 / 204 polys). Decimating them destroys the silhouette.
    ("grass_bermuda_01",       "grass_bermuda.glb",    1.000),
    ("grass_medium_02",        "grass_medium02.glb",   0.070),
    ("weed_plant_02",          "weed_real.glb",        0.55),
    ("moss_01",                "moss_real.glb",        1.000),
    ("shrub_01",               "shrub_real01.glb",     0.030),
    ("shrub_02",               "shrub_real02.glb",     0.150),
    ("shrub_04",               "shrub_real04.glb",     0.160),
    # --- rocks / cliffs (replaces 8-segment SphereMesh low-poly rocks) ---
    ("rock_face_01",           "rock_face.glb",        0.65),
    ("namaqualand_boulder_02", "boulder02.glb",       0.100),
    ("namaqualand_boulder_03", "boulder03.glb",       0.120),
    ("rock_moss_set_01",       "rock_moss.glb",       0.250),
    ("mountainside",           "mountain_real.glb",    0.080),
    ("coast_rocks_01",         "coast_rocks.glb",     0.020),
    # --- real tree (replaces hand-built broadleaf/pine/palm low-poly trees) ---
    ("searsia_lucida",         "realtree_broadleaf.glb", 0.050),
    ("quiver_tree_01",         "realtree_quiver01.glb",  0.120),
    ("tree_small_02",          "realtree_small.glb",     0.018),
    # --- road / industrial modulars (replaces procedural rail + box buildings) ---
    ("concrete_road_barrier",    "barrier_real.glb",      0.150),
    ("concrete_road_barrier_02", "barrier02_real.glb",    0.300),
    ("modular_factory_facade",   "factory_facade.glb",    0.250),
    ("modular_chainlink_fence",  "chainlink_fence.glb",   0.120),
    ("modular_electricity_poles", "power_pole.glb",       0.080),
    ("modular_fire_escape",      "fire_escape.glb",       1.000),
    ("water_manhole_cover",      "manhole.glb",           1.000),
    ("rollershutter_door",       "rollershutter.glb",     1.000),
    # --- 第三批：地标/道具（每张地图的辨识物） -----------------------------
    ("modular_wooden_pier",        "pier_real.glb",            0.250),
    ("dutch_ship_large_01",        "ship_real.glb",            0.100),
    ("fir_tree_01",                "realtree_fir_full.glb",    0.012),
    ("street_lamp_02",             "street_lamp_real.glb",     0.350),
    ("fire_hydrant",               "hydrant_real.glb",         0.200),
    ("utility_box_02",             "utility_box_real.glb",     0.500),
    ("covered_car",                "car_wreck_real.glb",       0.400),
    ("old_tyre",                   "tyre_real.glb",            0.400),
    ("ocean_buoy",                 "buoy_real.glb",            0.500),
    ("lateral_sea_marker",         "sea_marker_real.glb",      0.500),
    ("modular_industrial_pipes_01", "industrial_pipes.glb",    0.350),
    ("barrel_03",                  "barrel_real.glb",          0.500),
    ("street_lamp_01",             "street_lamp_01_real.glb",  0.350),
    ("fir_tree_01",                "realtree_fir_lod.glb",     0.002),
]


def material_signature(mat):
    """Poly Haven glTFs often create one material instance per primitive even
    when they all point at the same texture set. Key by texture filenames so we
    can collapse the duplicates into a handful of real materials."""
    imgs = []
    if mat is not None and getattr(mat, "use_nodes", False):
        for node in mat.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None:
                imgs.append(os.path.basename(node.image.filepath))
    return tuple(sorted(set(imgs))) if imgs else (mat.name if mat else "<none>",)


def consolidate_materials():
    """Canonicalise materials, split multi-material objects, then join every
    object sharing a material. Result: one mesh object per real material, so
    Godot needs exactly one MultiMesh (one draw call) per material."""
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    canonical = {}
    for obj in meshes:
        for slot in obj.material_slots:
            sig = material_signature(slot.material)
            if sig not in canonical:
                canonical[sig] = slot.material
            slot.material = canonical[sig]

    # split objects that still carry several distinct materials
    for obj in list(meshes):
        if len(obj.material_slots) <= 1:
            continue
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.separate(type="MATERIAL")
        bpy.ops.object.mode_set(mode="OBJECT")

    groups = {}
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH":
            continue
        mat = obj.material_slots[0].material if obj.material_slots else None
        groups.setdefault(id(mat), []).append(obj)
    for objs in groups.values():
        if len(objs) <= 1:
            continue
        bpy.ops.object.select_all(action="DESELECT")
        for obj in objs:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = objs[0]
        bpy.ops.object.join()
    return len(canonical)


def build(asset: str, out_name: str, ratio: float):
    src = os.path.join(PH, asset, asset + ".gltf")
    dst = os.path.join(OUT, out_name)
    if not os.path.exists(src):
        print("[SKIP] missing source", asset, flush=True)
        return
    if os.path.exists(dst) and os.path.getsize(dst) > 4096 and "--force" not in sys.argv:
        print("[CACHED]", out_name, flush=True)
        return

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    n_materials = consolidate_materials()
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        print("[FAIL] no mesh", asset, flush=True)
        return
    before = sum(len(o.data.polygons) for o in meshes)
    for obj in meshes:
        if ratio >= 0.999:
            continue
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        mod = obj.modifiers.new("lod", "DECIMATE")
        mod.ratio = ratio
        if hasattr(mod, "use_collapse_triangulate"):
            mod.use_collapse_triangulate = True
        try:
            bpy.ops.object.modifier_apply(modifier="lod")
        except Exception as exc:  # noqa: BLE001
            print("  decimate failed on", obj.name, exc, flush=True)
            obj.modifiers.remove(mod)
    for obj in list(bpy.context.scene.objects):
        if obj.type not in {"MESH", "EMPTY"}:
            bpy.data.objects.remove(obj, do_unlink=True)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in bpy.context.scene.objects:
        if obj.type == "MESH":
            obj.select_set(True)
    after = sum(len(o.data.polygons) for o in bpy.context.scene.objects if o.type == "MESH")
    mats = sum(len(o.material_slots) for o in bpy.context.scene.objects if o.type == "MESH")
    bpy.ops.export_scene.gltf(
        filepath=dst,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
        export_image_format="AUTO",
    )
    print("[LOD] %-28s -> %-26s %8d -> %7d tris  %2d unique mats  %5.1f MB" % (
        asset, out_name, before, after, n_materials, os.path.getsize(dst) / 1048576), flush=True)


def main():
    only = None
    if "--only" in sys.argv:
        idx = sys.argv.index("--only")
        if idx + 1 < len(sys.argv):
            only = sys.argv[idx + 1]
    for asset, out_name, ratio in ASSETS:
        if only is not None and only not in asset and only not in out_name:
            continue
        try:
            build(asset, out_name, ratio)
        except Exception as exc:  # noqa: BLE001
            print("[FAIL]", asset, repr(exc), flush=True)
    print("[DONE] hq scenery LODs", flush=True)


main()
