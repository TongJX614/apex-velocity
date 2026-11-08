"""Blender headless modelling helpers for the APEX VELOCITY venue kit.

Authoring convention (see skills/blender-direct-modeling/SKILL.md):
  * real-world metres, Blender Z-up (glTF exporter converts to Y-up)
  * asset origin = ground centre, front faces +Y (exports to Godot -Z)
  * materials are named Venue<Role> so the Godot runtime can re-tint them
"""
import math
import os

import bpy
from mathutils import Vector


# ---------------------------------------------------------------------------
# scene / material helpers
# ---------------------------------------------------------------------------

def reset_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.curves):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def material(name, color, metallic=0.0, roughness=0.8, emission=None, emission_strength=0.0):
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (emission[0], emission[1], emission[2], 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    return mat


def mat_concrete():
    return material("VenueConcrete", (0.46, 0.45, 0.43), roughness=0.88)


def mat_dark():
    return material("VenueDark", (0.06, 0.065, 0.075), metallic=0.2, roughness=0.45)


def mat_metal():
    return material("VenueMetal", (0.42, 0.45, 0.49), metallic=0.8, roughness=0.34)


def mat_metal_dark():
    return material("VenueMetalDark", (0.16, 0.17, 0.19), metallic=0.8, roughness=0.42)


def mat_glass():
    return material("VenueGlass", (0.09, 0.14, 0.2), metallic=0.6, roughness=0.08)


def mat_seat():
    return material("VenueSeat", (0.16, 0.32, 0.6), roughness=0.7)


def mat_accent():
    return material("VenueAccent", (0.95, 0.25, 0.2), roughness=0.55)


def mat_tyre():
    return material("VenueTyre", (0.035, 0.035, 0.04), roughness=0.95)


def mat_grass():
    return material("VenueGrass", (0.16, 0.3, 0.12), roughness=0.95)


def mat_emissive(color=(1.0, 0.25, 0.12), strength=6.0):
    return material("VenueEmissive", color, roughness=0.3, emission=color, emission_strength=strength)


# ---------------------------------------------------------------------------
# primitive helpers
# ---------------------------------------------------------------------------

BOX_FACES = [
    (0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4),
    (2, 3, 7, 6), (0, 3, 7, 4), (1, 2, 6, 5),
]


def box(name, size, loc=(0.0, 0.0, 0.0), mat=None, rot=(0.0, 0.0, 0.0)):
    sx, sy, sz = size[0] * 0.5, size[1] * 0.5, size[2] * 0.5
    verts = [
        (-sx, -sy, -sz), (sx, -sy, -sz), (sx, sy, -sz), (-sx, sy, -sz),
        (-sx, -sy, sz), (sx, -sy, sz), (sx, sy, sz), (-sx, sy, sz),
    ]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], BOX_FACES)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = Vector(loc)
    obj.rotation_euler = rot
    if mat is not None:
        obj.data.materials.append(mat)
    return obj


def cylinder(name, radius, depth, loc=(0.0, 0.0, 0.0), mat=None, verts=16,
             rot=(0.0, 0.0, 0.0), radius2=None):
    if radius2 is None:
        radius2 = radius
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=verts, radius=radius, depth=depth, location=loc, rotation=rot)
    obj = bpy.context.active_object
    obj.name = name
    if radius2 != radius:
        for v in obj.data.vertices:
            if v.co.z > 0:
                v.co.x *= radius2 / radius
                v.co.y *= radius2 / radius
    if mat is not None:
        obj.data.materials.append(mat)
    return obj


def cone(name, r1, r2, depth, loc=(0.0, 0.0, 0.0), mat=None, verts=10):
    bpy.ops.mesh.primitive_cone_add(
        vertices=verts, radius1=r1, radius2=r2, depth=depth, location=loc)
    obj = bpy.context.active_object
    obj.name = name
    if mat is not None:
        obj.data.materials.append(mat)
    return obj


def text_mesh(name, body, size=1.0, loc=(0.0, 0.0, 0.0), mat=None, rot=(0.0, 0.0, 0.0),
              extrude=0.03, align='CENTER'):
    curve = bpy.data.curves.new(name, 'FONT')
    curve.body = body
    curve.size = size
    curve.extrude = extrude
    curve.align_x = align
    curve.align_y = 'CENTER'
    obj = bpy.data.objects.new(name, curve)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = Vector(loc)
    obj.rotation_euler = rot
    if mat is not None:
        obj.data.materials.append(mat)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.convert(target='MESH')
    return bpy.context.view_layer.objects.active


def truss_column(name, x, y, height, mat, width=0.35, spacing=1.1):
    """Four-leg lattice column with X bracing."""
    legs = []
    for dx, dy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        legs.append(box(f"{name}_leg", (width * 0.16, width * 0.16, height),
                        (x + dx * width * 0.5, y + dy * width * 0.5, height * 0.5), mat))
    z = 0.0
    while z < height - 0.3:
        for dx, dy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            box(f"{name}_brace", (width, width * 0.12, 0.12),
                (x + dx * width * 0.5, y + dy * width * 0.5, z + spacing * 0.5), mat)
        z += spacing
    return legs


def truss_beam(name, length, loc, mat, width=0.5, spacing=1.2):
    """Horizontal lattice beam along X."""
    cx, cy, cz = loc
    for dz in (-width * 0.5, width * 0.5):
        for dy in (-width * 0.5, width * 0.5):
            box(f"{name}_chord", (length, 0.14, 0.14),
                (cx, cy + dy, cz + dz), mat)
    n = max(1, int(length / spacing))
    for i in range(n + 1):
        x = cx - length * 0.5 + i * spacing
        if x > cx + length * 0.5:
            break
        for dy in (-width * 0.5, width * 0.5):
            box(f"{name}_post", (0.12, 0.12, width),
                (x, cy + dy, cz), mat)
        box(f"{name}_diag", (spacing * 1.1, 0.1, 0.1),
            (x + spacing * 0.5, cy, cz), mat, rot=(0.0, 0.55, 0.0))


# ---------------------------------------------------------------------------
# asset bookkeeping / export
# ---------------------------------------------------------------------------

def objects_since(mark):
    return [o for o in bpy.data.objects if o.name not in mark]


def merge_by_material(prefix):
    """Join same-material objects so each asset ships with a handful of meshes
    (few MultiMesh draw calls on the Godot side) instead of hundreds of boxes."""
    groups = {}
    for obj in list(bpy.data.objects):
        if not obj.name.startswith(prefix) or obj.type != 'MESH':
            continue
        mat_name = obj.data.materials[0].name if obj.data.materials else "__none__"
        groups.setdefault(mat_name, []).append(obj)
    joined = []
    for mat_name, objs in groups.items():
        bpy.ops.object.select_all(action='DESELECT')
        for obj in objs:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = objs[0]
        if len(objs) > 1:
            bpy.ops.object.join()
        result = bpy.context.view_layer.objects.active
        result.name = prefix + "mat_" + mat_name
        joined.append(result)
    return joined


def export_objects(prefix, out_dir, name):
    merge_by_material(prefix)
    bpy.ops.object.select_all(action='DESELECT')
    selected = []
    for obj in bpy.data.objects:
        if obj.name.startswith(prefix):
            obj.select_set(True)
            selected.append(obj)
    if not selected:
        raise RuntimeError(f"no objects for prefix {prefix}")
    bpy.context.view_layer.objects.active = selected[0]
    path = os.path.join(out_dir, name + ".glb")
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials='EXPORT',
    )
    return path


def delete_objects(prefix):
    bpy.ops.object.select_all(action='DESELECT')
    doomed = [o for o in bpy.data.objects if o.name.startswith(prefix)]
    for obj in doomed:
        obj.select_set(True)
    if doomed:
        bpy.ops.object.delete(use_global=False)


def save_manifest(out_dir, data):
    import json
    path = os.path.join(out_dir, "venue_manifest.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    return path
