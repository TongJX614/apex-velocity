"""Decimate Poly Haven models into game-ready LOD GLBs (headless Blender).

Also renders a quick Workbench preview for each asset so we can sanity-check
that the silhouette / leaf cards survived the decimation.
"""
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PH = os.path.join(ROOT, "assets", "thirdparty", "polyhaven", "models")
PREVIEW = os.path.join(ROOT, "build", "previews")
os.makedirs(PREVIEW, exist_ok=True)

# asset id -> (decimate ratio, preview?)
ASSETS = {
    "island_tree_01": 0.014,
    "island_tree_02": 0.030,
    "island_tree_03": 0.010,
    "grass_medium_01": 0.0025,
    "modular_urban_apartments_facade": 0.25,
}


def decimate(asset, ratio):
    src = os.path.join(PH, asset, asset + ".gltf")
    dst = os.path.join(PH, asset, asset + "_lod.glb")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not meshes:
        print("[DECIMATE] no mesh for", asset)
        return None
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.active_object
    before = len(obj.data.polygons)
    mod = obj.modifiers.new("dec", 'DECIMATE')
    mod.ratio = ratio
    bpy.ops.object.modifier_apply(modifier="dec")
    after = len(obj.data.polygons)
    bpy.ops.export_scene.gltf(filepath=dst, export_format='GLB', use_selection=True,
                              export_apply=True)
    print("[DECIMATE] %s %d -> %d tris (%s)" % (asset, before, after, dst))
    return dst


def preview(asset):
    """Workbench render of the decimated asset for a quick visual check."""
    lod = os.path.join(PH, asset, asset + "_lod.glb")
    if not os.path.exists(lod):
        return
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=lod)
    objs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not objs:
        return
    # bounding box for framing
    mins = [1e9, 1e9, 1e9]
    maxs = [-1e9, -1e9, -1e9]
    deps = bpy.context.evaluated_depsgraph_get()
    for obj in objs:
        ev = obj.evaluated_get(deps)
        for corner in ev.bound_box:
            world = ev.matrix_world @ __import__('mathutils').Vector(corner)
            for i in range(3):
                mins[i] = min(mins[i], world[i])
                maxs[i] = max(maxs[i], world[i])
    center = [(mins[i] + maxs[i]) * 0.5 for i in range(3)]
    size = max(maxs[i] - mins[i] for i in range(3))
    cam_data = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = (center[0] + size * 1.1, center[1] - size * 1.5, center[2] + size * 0.55)
    direction = __import__('mathutils').Vector(center) - cam.location
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    bpy.context.scene.render.engine = 'BLENDER_WORKBENCH'
    bpy.context.scene.display.shading.light = 'STUDIO'
    bpy.context.scene.display.shading.color_type = 'TEXTURE'
    bpy.context.scene.render.resolution_x = 800
    bpy.context.scene.render.resolution_y = 600
    bpy.context.scene.render.filepath = os.path.join(PREVIEW, asset + ".png")
    bpy.ops.render.render(write_still=True)
    print("[PREVIEW]", asset)


def main():
    for asset, ratio in ASSETS.items():
        try:
            decimate(asset, ratio)
            preview(asset)
        except Exception as exc:  # noqa: BLE001
            print("[FAIL]", asset, exc)


main()
