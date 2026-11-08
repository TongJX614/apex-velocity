"""Decimate a downloaded high-poly Poly Haven glTF into a game-ready LOD (GLB)."""
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "assets", "thirdparty", "polyhaven", "models", "boulder_01", "boulder_01.gltf")
DST = os.path.join(ROOT, "assets", "thirdparty", "polyhaven", "models", "boulder_01", "boulder_01_lod.glb")
RATIO = 0.16

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
for obj in meshes:
    obj.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
obj = bpy.context.active_object
before = len(obj.data.polygons)
mod = obj.modifiers.new("dec", 'DECIMATE')
mod.ratio = RATIO
bpy.ops.object.modifier_apply(modifier="dec")
after = len(obj.data.polygons)
bpy.ops.export_scene.gltf(filepath=DST, export_format='GLB', use_selection=True, export_apply=True)
print("[DECIMATE] boulder %d -> %d tris -> %s" % (before, after, DST))
