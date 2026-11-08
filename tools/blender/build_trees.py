"""Build detailed trees for the venue / track-side greenery (headless Blender).

Run:
  ~/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/build_trees.py

Outputs assets/venues/tree_palm.glb, tree_broadleaf.glb, tree_pine.glb.
Origin at trunk base (z = 0), real-world heights (8-11 m).
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_common as C  # noqa: E402

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "assets", "venues"))
os.makedirs(OUT_DIR, exist_ok=True)


def cylinder_between(name, a, b, radius, mat, verts=8, radius_end=None):
    a = Vector(a)
    b = Vector(b)
    direction = b - a
    length = direction.length
    if length < 1e-4:
        return None
    mid = (a + b) * 0.5
    rot = direction.to_track_quat('Z', 'Y').to_euler()
    obj = C.cylinder(name, radius, length, tuple(mid), mat, verts=verts, rot=rot)
    if radius_end is not None and radius_end != radius:
        # taper the top ring
        for v in obj.data.vertices:
            if v.co.z > 0:
                v.co.x *= radius_end / radius
                v.co.y *= radius_end / radius
    return obj


# ---------------------------------------------------------------------------
# palm
# ---------------------------------------------------------------------------

def build_palm():
    prefix = "tree_palm_"
    trunk = C.material("VenueTrunk", (0.34, 0.25, 0.16), roughness=0.92)
    leaf = C.material("VenueLeaf", (0.11, 0.34, 0.12), roughness=0.82)
    nut = C.material("VenueNut", (0.32, 0.23, 0.11), roughness=0.8)

    height = 9.0
    segments = 13
    points = []
    for i in range(segments + 1):
        t = i / segments
        x = 1.05 * t * t
        y = 0.12 * math.sin(t * 3.0)
        z = height * t
        points.append((x, y, z))
    for i in range(segments):
        t0 = i / segments
        t1 = (i + 1) / segments
        r0 = 0.36 * (1.0 - t0 * 0.62)
        r1 = 0.36 * (1.0 - t1 * 0.62)
        # alternate a slight bulge to suggest trunk rings
        if i % 2 == 0:
            r0 *= 1.08
        cylinder_between(prefix + "trunk", points[i], points[i + 1], r0, trunk,
                         verts=9, radius_end=r1)

    top = Vector(points[-1])
    crown_verts = []
    crown_faces = []
    for f in range(16):
        angle = f / 16.0 * math.tau + 0.15
        droop = 1.15 + (f % 4) * 0.22
        length = 4.6 + (f % 3) * 0.35
        steps = 9
        base = len(crown_verts)
        for s in range(steps + 1):
            t = s / steps
            along = length * t
            dz = -droop * t * t * 1.15
            width = 0.42 * (1.0 - t * 0.8)
            if s % 2 == 1:
                width *= 0.62  # serrated leaflet look
            cx = top.x + math.cos(angle) * along
            cy = top.y + math.sin(angle) * along
            cz = top.z + dz
            px = -math.sin(angle)
            py = math.cos(angle)
            crown_verts.append((cx + px * width, cy + py * width, cz - 0.05))
            crown_verts.append((cx - px * width, cy - py * width, cz - 0.05))
        for s in range(steps):
            i0 = base + s * 2
            crown_faces.append((i0, i0 + 1, i0 + 3, i0 + 2))
    mesh = bpy.data.meshes.new(prefix + "crown")
    mesh.from_pydata(crown_verts, [], crown_faces)
    mesh.update()
    crown = bpy.data.objects.new(prefix + "crown", mesh)
    bpy.context.scene.collection.objects.link(crown)
    crown.data.materials.append(leaf)

    for i in range(4):
        angle = i / 4.0 * math.tau + 0.4
        C.cylinder(prefix + "nut", 0.15, 0.2,
                   (top.x + math.cos(angle) * 0.26, top.y + math.sin(angle) * 0.26, top.z - 0.28),
                   nut, verts=6)

    C.export_objects(prefix, OUT_DIR, "tree_palm")
    C.delete_objects(prefix)


# ---------------------------------------------------------------------------
# broadleaf
# ---------------------------------------------------------------------------

def build_broadleaf():
    prefix = "tree_leaf_"
    trunk = C.material("VenueTrunk", (0.29, 0.22, 0.15), roughness=0.92)
    leaf = C.material("VenueLeafBroad", (0.12, 0.3, 0.11), roughness=0.88)

    base = Vector((0.0, 0.0, 0.0))
    trunk_top = Vector((0.2, 0.0, 3.6))
    cylinder_between(prefix + "trunk_a", base, Vector((0.08, 0.02, 1.9)), 0.42, trunk, verts=9, radius_end=0.32)
    cylinder_between(prefix + "trunk_b", Vector((0.08, 0.02, 1.9)), trunk_top, 0.32, trunk, verts=9, radius_end=0.22)

    branch_tips = []
    for i in range(4):
        angle = i / 4.0 * math.tau + 0.4
        tip = Vector((trunk_top.x + math.cos(angle) * 1.7, trunk_top.y + math.sin(angle) * 1.7,
                      trunk_top.z + 1.0 + (i % 2) * 0.7))
        cylinder_between(prefix + "branch", trunk_top, tip, 0.16, trunk, verts=7, radius_end=0.07)
        branch_tips.append(tip)

    clusters = branch_tips + [trunk_top + Vector((0.0, 0.0, 1.5))]
    for i, tip in enumerate(clusters):
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=tuple(tip))
        obj = bpy.context.active_object
        obj.name = prefix + "leaves"
        obj.scale = (1.9 - i * 0.12, 1.9 - i * 0.12, 1.35 - i * 0.08)
        obj.data.materials.append(leaf)

    C.export_objects(prefix, OUT_DIR, "tree_broadleaf")
    C.delete_objects(prefix)


# ---------------------------------------------------------------------------
# pine
# ---------------------------------------------------------------------------

def build_pine():
    prefix = "tree_pine_"
    trunk = C.material("VenueTrunk", (0.25, 0.18, 0.13), roughness=0.92)
    leaf = C.material("VenueLeafPine", (0.08, 0.22, 0.1), roughness=0.9)
    cylinder_between(prefix + "trunk", (0, 0, 0), (0, 0, 7.6), 0.32, trunk, verts=8, radius_end=0.1)
    layers = [(1.2, 2.6, 3.4), (3.0, 2.1, 3.0), (4.7, 1.6, 2.6), (6.2, 1.05, 2.0)]
    for i, (z, radius, height) in enumerate(layers):
        C.cone(prefix + "canopy", radius, 0.0, height, (0.0, 0.0, z + height * 0.5), leaf, verts=9)
    C.export_objects(prefix, OUT_DIR, "tree_pine")
    C.delete_objects(prefix)


def main():
    C.reset_scene()
    build_palm()
    build_broadleaf()
    build_pine()
    print("[TREES] built palm/broadleaf/pine into", OUT_DIR)


main()
