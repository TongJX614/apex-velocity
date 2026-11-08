#!/usr/bin/env python3
"""Render quick workbench previews of assets/venues/*.glb to build/previews/.

Usage:
  Blender -b --python tools/blender/preview_venues.py -- pier_real ship_real ...
"""
import mathutils
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
VENUES = os.path.join(ROOT, "assets", "venues")
OUT = os.path.join(ROOT, "build", "previews")
os.makedirs(OUT, exist_ok=True)


def preview(name):
    path = os.path.join(VENUES, name + ".glb")
    if not os.path.exists(path):
        print("[MISS]", name, flush=True)
        return
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objs:
        return
    deps = bpy.context.evaluated_depsgraph_get()
    mins = [1e9] * 3
    maxs = [-1e9] * 3
    for obj in objs:
        ev = obj.evaluated_get(deps)
        for corner in ev.bound_box:
            w = ev.matrix_world @ mathutils.Vector(corner)
            for i in range(3):
                mins[i] = min(mins[i], w[i])
                maxs[i] = max(maxs[i], w[i])
    center = [(mins[i] + maxs[i]) * 0.5 for i in range(3)]
    size = max(maxs[i] - mins[i] for i in range(3))
    cam_data = bpy.data.cameras.new("c")
    cam = bpy.data.objects.new("c", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = (center[0] + size * 1.1, center[1] - size * 1.7, center[2] + size * 0.55)
    d = mathutils.Vector(center) - cam.location
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    bpy.context.scene.render.engine = 'BLENDER_WORKBENCH'
    bpy.context.scene.display.shading.light = 'STUDIO'
    bpy.context.scene.display.shading.color_type = 'TEXTURE'
    bpy.context.scene.render.resolution_x = 640
    bpy.context.scene.render.resolution_y = 480
    bpy.context.scene.render.filepath = os.path.join(OUT, name + ".png")
    bpy.ops.render.render(write_still=True)
    print("[PREV]", name, flush=True)


args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for n in args:
    try:
        preview(n)
    except Exception as exc:  # noqa: BLE001
        print("[FAIL]", n, repr(exc), flush=True)
