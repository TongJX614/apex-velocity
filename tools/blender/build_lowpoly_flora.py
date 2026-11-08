"""Low-poly distant-tree impostors for the far scenery bands (headless Blender).

Run:
  ~/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/build_lowpoly_flora.py

Outputs assets/venues/lowtree_palm.glb, lowtree_round.glb, lowtree_pine.glb
(each < 200 triangles — used for everything outside the detailed near band).
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_common as C  # noqa: E402

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "assets", "venues"))


def palm_low():
    prefix = "lt_palm_"
    trunk = C.material("VenueTrunk", (0.33, 0.24, 0.15), roughness=0.92)
    leaf = C.material("VenueLeaf", (0.12, 0.33, 0.13), roughness=0.85)
    C.cylinder(prefix + "trunk", 0.3, 7.0, (0.0, 0.0, 3.5), trunk, verts=6)
    verts, faces = [], []
    for i in range(7):
        angle = i / 7.0 * math.tau
        cx, cy = math.cos(angle), math.sin(angle)
        px, py = -math.sin(angle), math.cos(angle)
        base = (0.0, 0.0, 7.0)
        tip = (cx * 4.0, cy * 4.0, 6.0)
        width = 0.55
        verts.append((base[0], base[1], base[2]))
        verts.append((tip[0] + px * width, tip[1] + py * width, tip[2]))
        verts.append((tip[0] - px * width, tip[1] - py * width, tip[2]))
        faces.append((len(verts) - 3, len(verts) - 2, len(verts) - 1))
        faces.append((len(verts) - 3, len(verts) - 1, len(verts) - 2))
    mesh = bpy.data.meshes.new(prefix + "crown")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(prefix + "crown", mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.data.materials.append(leaf)
    C.export_objects(prefix, OUT_DIR, "lowtree_palm")
    C.delete_objects(prefix)


def round_low():
    prefix = "lt_round_"
    trunk = C.material("VenueTrunk", (0.3, 0.22, 0.15), roughness=0.92)
    leaf = C.material("VenueLeafBroad", (0.13, 0.32, 0.12), roughness=0.88)
    C.cylinder(prefix + "trunk", 0.28, 3.2, (0.0, 0.0, 1.6), trunk, verts=6)
    for i, (dx, dy, dz, r) in enumerate(((0.0, 0.0, 4.4, 2.1), (0.7, 0.2, 3.4, 1.4))):
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=0, radius=r,
                                              location=(dx, dy, dz))
        obj = bpy.context.active_object
        obj.name = prefix + "canopy"
        obj.data.materials.append(leaf)
    C.export_objects(prefix, OUT_DIR, "lowtree_round")
    C.delete_objects(prefix)


def pine_low():
    prefix = "lt_pine_"
    trunk = C.material("VenueTrunk", (0.25, 0.18, 0.13), roughness=0.92)
    leaf = C.material("VenueLeafPine", (0.08, 0.22, 0.1), roughness=0.9)
    C.cylinder(prefix + "trunk", 0.25, 2.0, (0.0, 0.0, 1.0), trunk, verts=6)
    for i, (z, r, h) in enumerate(((1.6, 2.0, 2.8), (3.3, 1.5, 2.4), (4.9, 0.9, 1.8))):
        C.cone(prefix + "canopy", r, 0.0, h, (0.0, 0.0, z + h * 0.5), leaf, verts=7)
    C.export_objects(prefix, OUT_DIR, "lowtree_pine")
    C.delete_objects(prefix)


def main():
    C.reset_scene()
    palm_low()
    round_low()
    pine_low()
    print("[LOWTREE] built lowtree_palm/round/pine into", OUT_DIR)


main()
