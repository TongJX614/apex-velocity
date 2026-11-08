# -*- coding: utf-8 -*-
"""convert_aventador.py —— Blendswap「Aventador_Blendswap_Shadman.blend」一次性
转换到 APEX VELOCITY 车规 GLB。

源模型与拆分版工包完全不同：
  · 只有 Body / FrontWheel / RearWheel 三个网格（前后轮各含左右两只轮子）；
  · 材质是 2016 年复杂节点组（Car Paint / Tire Rubber 等），glTF 无法直接导出；
  · 整车放大了约 1.66 倍（长 7.93m），需归一到实车 4.78m。

流程：拆左右轮 → 按材质分 胎/毂/盘/卡钳 → 统一缩放到实车尺寸 → 重建干净
Principled 材质（保留打包贴图）→ CarRoot/Wheel_XX/Spin_Wheel_XX 层级 → GLB。

用法：
  blender -b --factory-startup --python convert_aventador.py -- <in.blend> <out.glb>
"""
import bpy
import sys
import os
import json
import math
import re
import bmesh
import numpy as np
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
SRC = argv[0]
OUT = argv[1]
REPORT = os.path.splitext(OUT)[0] + ".report.json"
TARGET_LENGTH = 4.78  # Aventador LP700-4 实车长

report = {"src": SRC, "out": OUT, "warnings": []}

bpy.ops.wm.open_mainfile(filepath=SRC)
bpy.context.view_layer.update()

# ---------------------------------------------------------------------------
# 0. 清理影棚辅助对象
# ---------------------------------------------------------------------------
for nm in ("Ground", "light_key", "LightSource", "FrontCamera"):
    ob = bpy.data.objects.get(nm)
    if ob is not None:
        bpy.data.objects.remove(ob, do_unlink=True)

car_objs = [bpy.data.objects[n] for n in ("Body", "FrontWheel", "RearWheel")]
for ob in car_objs:
    mw = ob.matrix_world.copy()
    ob.parent = None
    ob.matrix_world = mw
bpy.ops.object.select_all(action="DESELECT")
for ob in car_objs:
    ob.select_set(True)
bpy.context.view_layer.objects.active = car_objs[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# MattePlastic 内壳在板缝翻边处穿出外 skin（MattePaint），渲染成一排黑点。
# 按车漆面最近邻把贴近漆面的内壳顶点压到漆面下 8mm；深处内饰不受影响。
from mathutils import kdtree
_body_me = bpy.data.objects["Body"].data
_slots = [m.name if m else "" for m in _body_me.materials]
_paint_i = _slots.index("MattePaint")
_plast_i = _slots.index("MattePlastic")
_paint_vids = set()
_plast_vids = set()
_pn = {}
for _p in _body_me.polygons:
    if _p.material_index == _paint_i:
        _paint_vids.update(_p.vertices)
        for _v in _p.vertices:
            _pn[_v] = _pn.get(_v, Vector()) + _p.normal
    elif _p.material_index == _plast_i:
        _plast_vids.update(_p.vertices)
_pvids = sorted(_paint_vids)
_kd = kdtree.KDTree(len(_pvids))
for _i, _v in enumerate(_pvids):
    _kd.insert(_body_me.vertices[_v].co, _i)
_kd.balance()
_clamped = 0
for _v in _plast_vids:
    _co, _i, _dist = _kd.find(_body_me.vertices[_v].co)
    if _dist < 0.05:
        _n = _pn[_pvids[_i]].normalized()
        _s = (_body_me.vertices[_v].co - _co).dot(_n)
        if _s > -0.008:
            _body_me.vertices[_v].co -= _n * (_s + 0.008)
            _clamped += 1
report["plastic_clamped_verts"] = _clamped
# 贴近漆面的内壳层（板缝衬底/外覆 duplicate）并入车漆槽：板缝间隙露出车身色，
# 黑点消失；座舱内的内饰（门板/中控）保持 MattePlastic。
_vdist = {}
_vside = {}
for _v in _plast_vids:
    _co2, _i2, _dist2 = _kd.find(_body_me.vertices[_v].co)
    _vdist[_v] = _dist2
    _vside[_v] = (_body_me.vertices[_v].co - _co2).dot(_pn[_pvids[_i2]].normalized())
_reassigned = 0
for _p in _body_me.polygons:
    if _p.material_index != _plast_i:
        continue
    _c = _p.center
    in_cabin = abs(_c.x) < 1.25 and 0.75 < _c.z < 1.8 and -1.75 < _c.y < 1.35
    if not in_cabin and max(_vdist.get(_v, 1e9) for _v in _p.vertices) < 0.5 \
            and min(_vside.get(_v, -1e9) for _v in _p.vertices) > -0.03:
        _p.material_index = _paint_i
        _reassigned += 1
report["plastic_shell_to_paint_faces"] = _reassigned


def vert_array(ob):
    n = len(ob.data.vertices)
    a = np.empty(n * 3, dtype=np.float64)
    ob.data.vertices.foreach_get("co", a)
    return a.reshape(n, 3)


def mesh_bbox(objs):
    mn = np.array([1e18] * 3)
    mx = np.array([-1e18] * 3)
    for ob in objs:
        if len(ob.data.vertices) == 0:
            continue
        a = vert_array(ob)
        mn = np.minimum(mn, a.min(axis=0))
        mx = np.maximum(mx, a.max(axis=0))
    return mn, mx


def transform_meshes(objs, mat):
    M = np.array(mat, dtype=np.float64)
    for ob in objs:
        if len(ob.data.vertices) == 0:
            continue
        a = vert_array(ob)
        a = a @ M[:3, :3].T + M[:3, 3]
        ob.data.vertices.foreach_set("co", a.reshape(-1))
        ob.data.update()


def split_faces(ob, keep_pred, new_name):
    """把满足 keep_pred(face_center, material_name) 的面切到新对象。
    全部面都命中时直接返回改名后的原对象；无命中返回 None。"""
    me = ob.data
    me.calc_loop_triangles()
    V = vert_array(ob)
    centers = np.zeros((len(me.polygons), 3))
    for p in me.polygons:
        centers[p.index] = V[list(p.vertices)].mean(axis=0)
    mat_of = []
    for p in me.polygons:
        m = me.materials[p.material_index] if p.material_index < len(me.materials) else None
        mat_of.append(m.name if m else "")
    keep = set()
    for i in range(len(me.polygons)):
        if keep_pred(centers[i], mat_of[i]):
            keep.add(i)
    if not keep:
        return None
    if len(keep) == len(me.polygons):
        ob.name = new_name
        ob.data.name = new_name + "_mesh"
        return ob
    bm_keep = bmesh.new()
    bm_cut = bmesh.new()
    bm_keep.from_mesh(me)
    bm_cut.from_mesh(me)
    bm_keep.faces.ensure_lookup_table()
    bm_cut.faces.ensure_lookup_table()
    bmesh.ops.delete(bm_cut, geom=[f for f in bm_cut.faces if f.index not in keep],
                     context="FACES")
    remain = [f for f in bm_keep.faces if f.index in keep]
    if remain:
        bmesh.ops.delete(bm_keep, geom=remain, context="FACES")
    new_me = bpy.data.meshes.new(new_name + "_mesh")
    bm_cut.to_mesh(new_me)
    bm_cut.free()
    for m in me.materials:
        new_me.materials.append(m)
    bm_keep.to_mesh(me)
    bm_keep.free()
    me.update()
    new_ob = bpy.data.objects.new(new_name, new_me)
    bpy.context.scene.collection.objects.link(new_ob)
    new_ob.matrix_world = Matrix.Identity(4)
    return new_ob


def join_objects(objs, name):
    objs = [o for o in objs if o is not None and o.name in bpy.data.objects
            and len(o.data.vertices) > 0]
    if not objs:
        return None
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name + "_mesh"
    return ob


# ---------------------------------------------------------------------------
# 1. 前后轮各拆左右（Blender 系：车头 -Y，左 +X）
# ---------------------------------------------------------------------------
corners = {}   # key -> [objs]
for src_name, tags in (("FrontWheel", ("FL", "FR")), ("RearWheel", ("RL", "RR"))):
    ob = bpy.data.objects[src_name]
    left = split_faces(ob, lambda c, m: c[0] > 0.0, src_name + "_L")
    right = split_faces(ob, lambda c, m: c[0] < 0.0, src_name + "_R")
    if left is None or right is None:
        raise SystemExit("[FAIL] %s 左右拆分失败" % src_name)
    corners[tags[0]] = [left]
    corners[tags[1]] = [right]
    if ob.name in bpy.data.objects and len(ob.data.vertices) == 0:
        bpy.data.objects.remove(ob, do_unlink=True)

# ---------------------------------------------------------------------------
# 2. 缩放到实车尺寸 + 居中 + 落地
# ---------------------------------------------------------------------------
body = bpy.data.objects["Body"]
bmn, bmx = mesh_bbox([body])
scale = TARGET_LENGTH / float(bmx[1] - bmn[1])
all_objs = [body] + [o for v in corners.values() for o in v]
transform_meshes(all_objs, Matrix.Scale(scale, 4))
mn, mx = mesh_bbox(all_objs)
cx, cy = (mn[0] + mx[0]) * 0.5, (mn[1] + mx[1]) * 0.5
transform_meshes(all_objs, Matrix.Translation(Vector((-cx, -cy, -mn[2]))))
mn, mx = mesh_bbox(all_objs)
report["scale"] = round(scale, 5)
report["dims_wlh"] = [round(float(mx[0] - mn[0]), 3),
                      round(float(mx[2] - mn[2]), 3),
                      round(float(mx[1] - mn[1]), 3)]

# ---------------------------------------------------------------------------
# 3. 每角按材质分 胎/毂/盘/卡钳，建层级
# ---------------------------------------------------------------------------
WHEEL_CLASS = {"Rubber": "Tyre", "BrushedMetal": "Rim",
               "DiskBrakeTexture": "BrakeDisc", "Red_Paint": "Caliper"}
root_empty = bpy.data.objects.new("CarRoot", None)
root_empty.empty_display_type = "PLAIN_AXES"
bpy.context.scene.collection.objects.link(root_empty)
root_empty.matrix_world = Matrix.Identity(4)

def face_mat_names(ob):
    me = ob.data
    out = []
    for p in me.polygons:
        m = me.materials[p.material_index] if p.material_index < len(me.materials) else None
        out.append(m.name if m else "")
    return out


report["wheels"] = {}
for key, objs in corners.items():
    parts = {c: [] for c in ("Tyre", "Rim", "BrakeDisc", "Caliper")}
    for ob in list(objs):
        used = set(face_mat_names(ob))
        classes_present = {WHEEL_CLASS[mn] for mn in used if mn in WHEEL_CLASS}
        if len(used) == 1 and len(classes_present) == 1:
            parts[classes_present.pop()].append(ob)
            continue
        consumed = False
        for mat_name, cls in WHEEL_CLASS.items():
            piece = split_faces(ob, lambda c, m, mn2=mat_name: m == mn2,
                                "%s_%s_%s" % (ob.name, cls, key))
            if piece is not None:
                parts[cls].append(piece)
                if piece is ob:
                    consumed = True
                    break
        if not consumed and ob.name in bpy.data.objects and len(ob.data.vertices) > 0:
            parts["Rim"].append(ob)   # 剩余未识别面归毂
    merged = {}
    for cls in parts:
        merged[cls] = join_objects(parts[cls], "%s_Wheel_%s" % (cls, key))
    spin_objs = [o for o in (merged["Tyre"], merged["Rim"]) if o is not None]
    if not spin_objs:
        raise SystemExit("[FAIL] %s 无滚动几何" % key)
    smn, smx = mesh_bbox(spin_objs)
    C = Vector(((smn[0] + smx[0]) * 0.5, (smn[1] + smx[1]) * 0.5,
                (smn[2] + smx[2]) * 0.5))
    radius = float(max(smx[1] - smn[1], smx[2] - smn[2])) * 0.5
    width = float(smx[0] - smn[0])
    for o in spin_objs + [o for o in (merged["BrakeDisc"], merged["Caliper"]) if o]:
        transform_meshes([o], Matrix.Translation(-C))
    wheel_empty = bpy.data.objects.new("Wheel_" + key, None)
    wheel_empty.empty_display_type = "ARROWS"
    bpy.context.scene.collection.objects.link(wheel_empty)
    wheel_empty.parent = root_empty
    wheel_empty.matrix_parent_inverse = Matrix.Identity(4)
    wheel_empty.matrix_world = Matrix.Translation(C)
    spin_empty = bpy.data.objects.new("Spin_Wheel_" + key, None)
    spin_empty.empty_display_type = "CIRCLE"
    bpy.context.scene.collection.objects.link(spin_empty)
    spin_empty.parent = wheel_empty
    spin_empty.matrix_parent_inverse = Matrix.Identity(4)
    spin_empty.matrix_basis = Matrix.Identity(4)
    for o in spin_objs:
        o.parent = spin_empty
        o.matrix_parent_inverse = Matrix.Identity(4)
        o.matrix_basis = Matrix.Identity(4)
    for cls in ("BrakeDisc", "Caliper"):
        o = merged[cls]
        if o is not None:
            o.parent = wheel_empty
            o.matrix_parent_inverse = Matrix.Identity(4)
            o.matrix_basis = Matrix.Identity(4)
    report["wheels"][key] = {
        "C_gltf": [round(float(C.x), 4), round(float(C.z), 4), round(float(-C.y), 4)],
        "radius": round(radius, 4), "width": round(width, 4),
    }

# 车身
body.parent = root_empty
body.matrix_parent_inverse = Matrix.Identity(4)
body.matrix_basis = Matrix.Identity(4)
body.name = "Body_Main"

# 尾翼挂点（Aventador 集成式主动尾翼在车尾盖上）
wm = bpy.data.objects.new("WingMount", None)
wm.empty_display_type = "PLAIN_AXES"
bpy.context.scene.collection.objects.link(wm)
wm.parent = root_empty
wm.matrix_parent_inverse = Matrix.Identity(4)
wm.matrix_world = Matrix.Translation(Vector((0.0, 1.85, 0.80)))

# ---------------------------------------------------------------------------
# 4. 重建干净 PBR 材质（旧节点组 glTF 导不出）
# ---------------------------------------------------------------------------
def make_mat(name, base, metallic=0.0, roughness=0.5, alpha=1.0,
             emission=None, emission_strength=0.0, image=None, coat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (*base, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Alpha"].default_value = alpha
    if "Coat Weight" in bsdf.inputs:
        bsdf.inputs["Coat Weight"].default_value = coat
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    if image is not None:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = image
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    if alpha < 1.0:
        try:
            m.surface_render_method = "BLENDED"
        except Exception:
            pass
        m.use_backface_culling = False
    return m


img_disc = bpy.data.images.get("DiskBrake.png")
img_grill = bpy.data.images.get("Grill.png")
img_logo = bpy.data.images.get("Logo.png")

_BODY_PAINT = make_mat("CARPAINT_Body", (0.692, 0.692, 0.692), 0.0, 0.12, coat=1.0)
NEW_MATS = {
    "Car Paint": _BODY_PAINT,
    # 源文件外覆盖件实际挂在 MattePaint 槽（MattePlastic 才是内饰/底壳），
    # 并入车漆，否则整车渲染成黑塑料且换色不生效。
    "MattePaint": _BODY_PAINT,
    "MattePlastic": make_mat("MattePlastic", (0.017, 0.014, 0.015), 0.0, 0.70),
    "CarbonFibre": make_mat("CarbonFibre", (0.015, 0.013, 0.014), 0.25, 0.40),
    "Chrome_Glossy": make_mat("Chrome_Glossy", (0.80, 0.80, 0.80), 1.0, 0.08),
    "BrushedMetal": make_mat("Rim_BrushedMetal", (0.32, 0.32, 0.34), 0.95, 0.30),
    "Rubber": make_mat("Tyre_Rubber", (0.018, 0.019, 0.021), 0.0, 0.90),
    "Red_Paint": make_mat("Caliper_Red", (0.30, 0.012, 0.020), 0.25, 0.30),
    "DiskBrakeTexture": make_mat("BrakeDisc_Disc", (0.31, 0.29, 0.25), 0.85, 0.40,
                                 image=img_disc),
    "Grill": make_mat("Grill", (0.05, 0.05, 0.05), 0.2, 0.60, image=img_grill),
    "Logo": make_mat("Logo", (0.9, 0.9, 0.9), 0.6, 0.35, image=img_logo),
    "Plate": make_mat("Plate", (0.85, 0.85, 0.82), 0.0, 0.50),
    "Glass": make_mat("Glass", (0.10, 0.115, 0.135), 0.0, 0.03, alpha=0.30),
    "Trans": make_mat("Glass_Trans", (0.10, 0.115, 0.135), 0.0, 0.05, alpha=0.35),
    "Light": make_mat("Light_Head", (0.9, 0.92, 0.94), 0.0, 0.20,
                      emission=(0.84, 0.87, 0.88), emission_strength=3.0),
    "Neon Light": make_mat("Light_Neon", (0.9, 0.95, 1.0), 0.0, 0.20,
                           emission=(0.9, 0.95, 1.0), emission_strength=2.0),
}

replaced = 0
for ob in bpy.data.objects:
    if ob.type != "MESH":
        continue
    for si, m in enumerate(list(ob.data.materials)):
        if m is not None and m.name in NEW_MATS:
            ob.data.materials[si] = NEW_MATS[m.name]
            replaced += 1
report["material_slots_replaced"] = replaced
for old_name in NEW_MATS:
    old = bpy.data.materials.get(old_name)
    if old is not None and old.users == 0:
        bpy.data.materials.remove(old)
for m in NEW_MATS.values():
    base = re.sub(r"\.\d{3}$", "", m.name)
    if base != m.name and bpy.data.materials.get(base) is None:
        m.name = base

# ---------------------------------------------------------------------------
# 5. 导出
# ---------------------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
root_empty.select_set(True)
for o in root_empty.children_recursive:
    if o.type in ("MESH", "EMPTY"):
        o.select_set(True)
bpy.context.view_layer.objects.active = root_empty
bpy.context.view_layer.update()

os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
kwargs = dict(
    filepath=OUT, export_format="GLB", use_selection=True, export_apply=True,
    export_yup=True, export_animations=False, export_cameras=False,
    export_lights=False, export_extras=False, export_materials="EXPORT",
    export_image_format="AUTO", export_normals=True, export_texcoords=True,
    export_skins=False, export_morph=False, export_attributes=False,
)
try:
    bpy.ops.export_scene.gltf(**kwargs)
except TypeError as e:
    print("[WARN] gltf kwargs fallback:", e)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True, export_animations=False,
                              export_cameras=False, export_lights=False)

tris = 0
for ob in root_empty.children_recursive:
    if ob.type == "MESH":
        ob.data.calc_loop_triangles()
        tris += len(ob.data.loop_triangles)
report["tris"] = tris
report["glb_mb"] = round(os.path.getsize(OUT) / 1048576.0, 2)
report["node_names"] = [o.name for o in root_empty.children_recursive
                        if o.type in ("MESH", "EMPTY")]
with open(REPORT, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=1)
print("[DONE]", OUT, "%.2fMB tris=%d" % (report["glb_mb"], tris))
print("[WHEELS]", json.dumps(report["wheels"], ensure_ascii=False))
print("[DIMS]", report["dims_wlh"])