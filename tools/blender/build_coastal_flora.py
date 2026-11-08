"""Coastal flora: five tree variants + a grass clump, built headless in Blender.

Run:
  ~/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/build_coastal_flora.py

Outputs assets/venues/tree_*.glb + grass_clump.glb (real metres, origin at base).
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_common as C  # noqa: E402

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "assets", "venues"))


def cyl_between(name, a, b, r0, r1, mat, verts=8):
    a = Vector(a)
    b = Vector(b)
    d = b - a
    if d.length < 1e-4:
        return None
    obj = C.cylinder(name, r0, d.length, tuple((a + b) * 0.5), mat, verts=verts,
                     rot=d.to_track_quat('Z', 'Y').to_euler())
    if abs(r1 - r0) > 1e-5:
        for v in obj.data.vertices:
            if v.co.z > 0:
                v.co.x *= r1 / r0
                v.co.y *= r1 / r0
    return obj


# ---------------------------------------------------------------------------
# shared palm builder
# ---------------------------------------------------------------------------

def build_palm(prefix: str, height: float, lean: float, fronds: int, name: str):
    trunk = C.material("VenueTrunk", (0.34, 0.25, 0.16), roughness=0.92)
    leaf = C.material("VenueLeaf", (0.11, 0.34, 0.12), roughness=0.82)
    nut = C.material("VenueNut", (0.32, 0.23, 0.11), roughness=0.8)

    segments = 13
    points = []
    for i in range(segments + 1):
        t = i / segments
        points.append((lean * (t ** 2), 0.12 * math.sin(t * 3.0), height * t))
    for i in range(segments):
        t0 = i / segments
        t1 = (i + 1) / segments
        r0 = 0.36 * (1.0 - t0 * 0.6) * (1.08 if i % 2 == 0 else 1.0)
        r1 = 0.36 * (1.0 - t1 * 0.6)
        cyl_between(prefix + "trunk", points[i], points[i + 1], r0, r1, trunk, verts=10)
        # trunk rings (real palms have clear annular scars)
        if i % 1 == 0:
            p = points[i]
            C.cylinder(prefix + "ring", r0 * 1.16, 0.09, (p[0], p[1], p[2]), trunk, verts=10)

    top = Vector(points[-1])
    verts, faces = [], []
    for f in range(fronds):
        angle = f / fronds * math.tau + 0.13
        droop = 1.0 + (f % 4) * 0.24
        length = 4.4 + (f % 3) * 0.4
        steps = 11
        base = len(verts)
        for s in range(steps + 1):
            t = s / steps
            along = length * t
            dz = -droop * t * t * 1.1
            width = 0.44 * (1.0 - t * 0.8) * (0.6 if s % 2 else 1.0)
            cx = top.x + math.cos(angle) * along
            cy = top.y + math.sin(angle) * along
            px, py = -math.sin(angle), math.cos(angle)
            verts.append((cx + px * width, cy + py * width, top.z + dz - 0.05))
            verts.append((cx - px * width, cy - py * width, top.z + dz - 0.05))
        for s in range(steps):
            i0 = base + s * 2
            faces.append((i0, i0 + 1, i0 + 3, i0 + 2))
    mesh = bpy.data.meshes.new(prefix + "crown")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    crown = bpy.data.objects.new(prefix + "crown", mesh)
    bpy.context.scene.collection.objects.link(crown)
    crown.data.materials.append(leaf)

    for i in range(6):
        angle = i / 6.0 * math.tau + 0.4
        C.cylinder(prefix + "nut", 0.15, 0.2,
                   (top.x + math.cos(angle) * 0.26, top.y + math.sin(angle) * 0.26, top.z - 0.28),
                   nut, verts=6)
    C.export_objects(prefix, OUT_DIR, name)
    C.delete_objects(prefix)


# ---------------------------------------------------------------------------
# broadleaf: trunk + 5 branches + layered leaf clusters
# ---------------------------------------------------------------------------

def build_broadleaf(prefix: str, height: float, name: str, spread: float, tint):
    leaf_c = C.material("VenueLeafBroadC", (tint[0] * 1.12, tint[1] * 1.12, tint[2] * 0.95), roughness=0.86)
    trunk = C.material("VenueTrunk", (0.3, 0.22, 0.15), roughness=0.92)
    leaf_a = C.material("VenueLeafBroad", tint, roughness=0.88)
    leaf_b = C.material("VenueLeafBroadDark", (tint[0] * 0.72, tint[1] * 0.78, tint[2] * 0.7), roughness=0.9)

    base_top = Vector((0.1, 0.0, height * 0.45))
    cyl_between(prefix + "trunk_a", (0, 0, 0), Vector((0.06, 0.02, height * 0.2)), 0.46, 0.36, trunk, 9)
    cyl_between(prefix + "trunk_b", Vector((0.06, 0.02, height * 0.2)), base_top, 0.36, 0.2, trunk, 9)
    tips = []
    for i in range(6):
        angle = i / 6.0 * math.tau + 0.35
        tip = Vector((base_top.x + math.cos(angle) * spread,
                      base_top.y + math.sin(angle) * spread,
                      base_top.z + height * (0.35 + 0.08 * (i % 2))))
        cyl_between(prefix + "branch", base_top, tip, 0.14, 0.05, trunk, 7)
        tips.append(tip)
    clusters = []
    for i, tip in enumerate(tips):
        for k in range(3):
            jitter = Vector((((i * 7 + k * 3) % 5 - 2) * 0.28 * spread,
                             ((i * 3 + k * 5) % 5 - 2) * 0.28 * spread,
                             ((i + k) % 3 - 1) * 0.32))
            clusters.append(tip + jitter)
    clusters.append(base_top + Vector((0.0, 0.0, height * 0.34)))
    materials = [leaf_a, leaf_b, leaf_c]
    for i, tip in enumerate(clusters):
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=tuple(tip))
        obj = bpy.context.active_object
        obj.name = prefix + "leaves"
        r = spread * (0.42 + (i % 4) * 0.09)
        obj.scale = (r, r * (0.9 + (i % 3) * 0.06), r * 0.58)
        obj.data.materials.append(materials[i % 3])
    C.export_objects(prefix, OUT_DIR, name)
    C.delete_objects(prefix)


# ---------------------------------------------------------------------------
# wind-swept coastal tree
# ---------------------------------------------------------------------------

def build_coastal_tree():
    prefix = "tree_coast_"
    trunk = C.material("VenueTrunk", (0.33, 0.25, 0.17), roughness=0.92)
    leaf = C.material("VenueLeafCoast", (0.16, 0.33, 0.15), roughness=0.88)
    base = Vector((0.0, 0.0, 0.0))
    top = Vector((1.1, 0.2, 4.2))
    cyl_between(prefix + "trunk_a", base, Vector((0.35, 0.1, 2.2)), 0.3, 0.22, trunk, 8)
    cyl_between(prefix + "trunk_b", Vector((0.35, 0.1, 2.2)), top, 0.22, 0.11, trunk, 8)
    for i in range(4):
        angle = -0.9 + i * 0.55
        tip = top + Vector((math.cos(angle) * 1.9, math.sin(angle) * 1.9, 0.5 + (i % 2) * 0.4))
        cyl_between(prefix + "branch", top, tip, 0.09, 0.03, trunk, 6)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0,
                                              location=tuple(tip + Vector((0.0, 0.0, 0.25))))
        obj = bpy.context.active_object
        obj.name = prefix + "canopy"
        obj.scale = (1.35, 1.1, 0.55)
        obj.data.materials.append(leaf)
    C.export_objects(prefix, OUT_DIR, "tree_coastal")
    C.delete_objects(prefix)


# ---------------------------------------------------------------------------
# coastal shrub
# ---------------------------------------------------------------------------

def build_shrub():
    prefix = "shrub_"
    leaf = C.material("VenueLeafShrub", (0.14, 0.3, 0.13), roughness=0.9)
    stem = C.material("VenueTrunk", (0.3, 0.23, 0.15), roughness=0.92)
    for i in range(5):
        angle = i / 5.0 * math.tau
        r = 0.35 + (i % 3) * 0.12
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0,
                                              location=(math.cos(angle) * r, math.sin(angle) * r, 0.55 + (i % 2) * 0.2))
        obj = bpy.context.active_object
        obj.name = prefix + "bush"
        obj.scale = (0.85, 0.85, 0.55 + (i % 3) * 0.08)
        obj.data.materials.append(leaf)
    for i in range(3):
        angle = i / 3.0 * math.tau + 0.3
        cyl_between(prefix + "stem", (0.0, 0.0, 0.0),
                    (math.cos(angle) * 0.4, math.sin(angle) * 0.4, 0.6), 0.06, 0.03, stem, 5)
    C.export_objects(prefix, OUT_DIR, "shrub_coastal")
    C.delete_objects(prefix)


# ---------------------------------------------------------------------------
# grass clump (three blade fans, tapered strips)
# ---------------------------------------------------------------------------

def build_grass_clump():
    prefix = "grass_"
    mat_a = C.material("VenueGrassBlade", (0.22, 0.38, 0.14), roughness=0.9)
    mat_b = C.material("VenueGrassBladeDry", (0.4, 0.4, 0.22), roughness=0.9)
    verts, faces = [], []
    for fan in range(3):
        base_angle = fan / 3.0 * math.tau
        for b in range(5):
            angle = base_angle + (b - 2) * 0.22
            h = 0.42 + (b % 3) * 0.1
            w = 0.028
            lean = 0.16
            steps = 3
            base = len(verts)
            for s in range(steps + 1):
                t = s / steps
                cx = math.cos(angle) * lean * (t ** 2)
                cy = math.sin(angle) * lean * (t ** 2)
                cz = h * t
                px, py = -math.sin(angle), math.cos(angle)
                width = w * (1.0 - t * 0.85)
                verts.append((cx + px * width, cy + py * width, cz))
                verts.append((cx - px * width, cy - py * width, cz))
            for s in range(steps):
                i0 = base + s * 2
                faces.append((i0, i0 + 1, i0 + 3, i0 + 2))
    mesh = bpy.data.meshes.new(prefix + "clump")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(prefix + "clump", mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.data.materials.append(mat_a)
    # drier second half
    obj2 = obj.copy()
    obj2.data = obj.data.copy()
    obj2.name = prefix + "clump_dry"
    obj2.rotation_euler = (0.0, 0.0, 0.8)
    bpy.context.scene.collection.objects.link(obj2)
    obj2.data.materials.clear()
    obj2.data.materials.append(mat_b)
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    obj2.select_set(True)
    bpy.context.view_layer.objects.active = obj
    C.export_objects(prefix, OUT_DIR, "grass_clump")
    C.delete_objects(prefix)


def main():
    C.reset_scene()
    build_palm("tree_palm_tall_", 10.2, 1.2, 26, "tree_palm_tall")
    build_palm("tree_palm_bent_", 7.0, 2.6, 22, "tree_palm_bent")
    build_broadleaf("tree_broadleaf_", 8.4, "tree_broadleaf", 1.7, (0.13, 0.32, 0.12))
    build_coastal_tree()
    build_shrub()
    build_grass_clump()
    print("[FLORA] built 5 trees + shrub + grass clump into", OUT_DIR)


main()
