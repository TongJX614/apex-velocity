"""Build an AI-only low-detail car GLB.

Usage:
  Blender -b -P tools/car_export/build_ai_lod.py -- <in.glb> <out.glb> <ratio>

AI rivals never need the full interior/engine. Remove those meshes, decimate the
rest, and keep object names so Godot can still find Spin_Wheel_* and paint nodes.
"""
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
if len(argv) < 2:
    raise SystemExit("need <in.glb> <out.glb> [ratio]")
src, dst = argv[0], argv[1]
ratio = float(argv[2]) if len(argv) > 2 else 0.5

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.abspath(src))

removed = []
for obj in list(bpy.data.objects):
    if obj.type != "MESH":
        continue
    name = obj.name.lower()
    if "interior" in name or "engine" in name:
        removed.append(obj.name)
        bpy.data.objects.remove(obj, do_unlink=True)

for obj in bpy.context.scene.objects:
    if obj.type != "MESH":
        continue
    mod = obj.modifiers.new(name="AILODDecimate", type="DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    mod.use_collapse_triangulate = True

os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=os.path.abspath(dst),
    export_format="GLB",
    use_selection=False,
    export_apply=True,
)
print("[AI-LOD] %s -> %s ratio=%.2f removed=%s" % (src, dst, ratio, removed))