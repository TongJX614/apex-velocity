# -*- coding: utf-8 -*-
"""export_godot_car.py —— 把「车辆模型_拆分版_待审查/blend/*.blend」重导出为
APEX VELOCITY（Godot 4）可直接使用的高保真车模 GLB。

与旧网页版管线（export_game_glb.py，为 three.js 服务）的区别：
  · 保留 Blender 原件里的真实材质：贴图/法线/金属度/粗糙度/清漆/半透玻璃，
    不再「非玻璃一律强制不透明 + 压暗玻璃」；
  · 合并拆分碎片：每台车的车轮组（Tyre_/Rim_/Disc_ 碎片）合并成 2 个网格/角，
    车身按材质合并，大幅降低 draw call（旧网页版 i8 有 787 个网格）；
  · 坐标归一：应用掉拆分工包里 车辆根节点 的 96x/0.25x 缩放，
    再把车摆成「车头 +Z、左前轮 +X、Y 向上、原点在接地中心」，与现有游戏 GLB 一致；
  · 层级遵循游戏约定：
        CarRoot
        ├─ Wheel_FL/FR/RL/RR          （转向枢轴，静止子节点放刹车/卡钳）
        │   └─ Spin_Wheel_XX          （滚转枢轴）
        │        ├─ Tyre_Wheel_XX
        │        └─ Rim_Wheel_XX
        ├─ SteerPivot                 （方向盘枢轴，如原件有）
        ├─ WingMount                  （程序化尾翼挂点）
        └─ 车身/玻璃/尾翼（按材质合并后的网格）
  · 轮轴按点云 PCA 校准到 X、滚转枢轴移到轮心，保证滚动是纯圆不晃。

用法：
  blender -b --factory-startup --python export_godot_car.py -- \
      <in.blend> <out.glb> [<out.report.json>] [<review.json>]

review.json 为审查包 json/<车型>.json（可选但批量必传）：
  · 取 split.wheels[corner] 的 ctr/radius/width 作为「期望轮柱」，用于裁掉
    拆分版误切进轮组的轮眉/翼子板/导风面（裁出的面挂到车身，不删）；
  · 枢轴位置用 json ctr，不再按 spin 包围盒回中心；
  · json 里标了 bad/_estimated 的轮组（拆分异常，如 ADRO）改用轮组自身
    几何实测的轮径/轮宽，避免把胎面切坏，报告里标注 expected_source。
"""
import bpy
import sys
import os
import json
import math
import re
import time

import bmesh
import numpy as np
from mathutils import Vector, Matrix

T0 = time.time()
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
if len(argv) < 2:
    print("[FATAL] usage: -- <in.blend> <out.glb> [<report.json>] [<review.json>]")
    raise SystemExit(2)
SRC = argv[0]
OUT = argv[1]
REPORT_PATH = argv[2] if len(argv) > 2 else os.path.splitext(OUT)[0] + ".report.json"
REVIEW_JSON = argv[3] if len(argv) > 3 and argv[3] else None
OLD_REF_JSON = argv[4] if len(argv) > 4 and argv[4] else None
SLUG = argv[5] if len(argv) > 5 else os.path.splitext(os.path.basename(SRC))[0]

WING_HINTS = (
    "spoiler", "wingflap", "wingpylon", "wingendplate", "ducktail", "gurney",
    "taillip", "factorywing", "rearwing", "activewing", "wing",
)
GLASS_RE = re.compile(r"glass|glaz|window|windscreen|windshield|vitr|crystal|玻璃|挡风|车窗", re.I)
LAMP_RE = re.compile(r"lamp|light|lens|灯|hid|emiss|headlight|taillight|brake_?light|指示灯", re.I)
TIRE_RE = re.compile(r"tire|tyre|rubber|pneu|sidewall", re.I)
PAINT_RE = re.compile(r"carpaint|paint|车漆|coloured|livery|涂装|拉花", re.I)
# 影棚/辅助网格识别。注意不能用 "cove" 子串（会误杀 "enginecover"/"light_cover"
# 等真实车身件），只在对象名整体或前缀命中时才当辅助网格。
STUDIO_ALWAYS = ("cyclorama", "backdrop", "texture_plane", "studio")
STUDIO_EXACT = ("shadow", "floor", "cove", "地面", "floordark", "covedark")
STUDIO_PREFIX = ("shadow_", "shadow.", "floor_", "floor.", "cove_", "cove.")

report = {
    "src": SRC,
    "out": OUT,
    "warnings": [],
    "errors": [],
    "materials": [],
    "nodes": {},
}


def save_report():
    try:
        with open(REPORT_PATH, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=1)
    except Exception as e:  # noqa: BLE001
        print("[WARN] cannot write report:", e)


def fail(msg):
    report["errors"].append(msg)
    save_report()
    print("[FAIL]", msg)
    raise SystemExit(0)


def sanitize(name, limit=58):
    s = re.sub(r"[^A-Za-z0-9_.\-]+", "_", str(name or "obj"))
    s = re.sub(r"_+", "_", s).strip("_")
    return (s or "obj")[:limit]


def is_studio(ob):
    low = (ob.name or "").lower()
    if any(h in low for h in STUDIO_ALWAYS):
        return True
    if low in STUDIO_EXACT:
        return True
    return any(low.startswith(h) for h in STUDIO_PREFIX)


def get_bsdf(mat):
    if mat is None or not mat.use_nodes:
        return None
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            return n
    return None


def unlink_input(node, name):
    if node is None or name not in node.inputs:
        return
    inp = node.inputs[name]
    for link in list(inp.links):
        node.id_data.links.remove(link)


def set_input(node, name, value):
    if node is not None and name in node.inputs:
        try:
            node.inputs[name].default_value = value
        except Exception:  # noqa: BLE001
            pass


def get_input(node, name, default=None):
    if node is not None and name in node.inputs:
        return node.inputs[name].default_value
    return default


# ---------------------------------------------------------------------------
# 0. 打开并定位
# ---------------------------------------------------------------------------
bpy.ops.wm.open_mainfile(filepath=SRC)
bpy.context.view_layer.update()
try:
    bpy.ops.object.mode_set(mode="OBJECT")
except Exception:  # noqa: BLE001
    pass

root = bpy.data.objects.get("车辆根节点")
if root is None:
    cand = [o for o in bpy.data.objects if o.type == "EMPTY" and len([c for c in o.children_recursive if c.type == "MESH"]) > 4]
    if cand:
        root = max(cand, key=lambda o: len([c for c in o.children_recursive if c.type == "MESH"]))
if root is None:
    fail("找不到车辆根节点")
report["root"] = root.name

car_meshes = [o for o in root.children_recursive if o.type == "MESH" and not is_studio(o)]
if len(car_meshes) < 10:
    fail("车辆网格过少 (%d)" % len(car_meshes))
report["source_meshes"] = len(car_meshes)

# 轮子枢轴：前轮 STEER_XX > WHEEL_XX，后轮 WHEEL_XX
pivots = {}          # old key -> {"steer": empty|None, "spin": empty, "C": Vector}
for k in ("FL", "FR", "RL", "RR"):
    steer = bpy.data.objects.get("STEER_" + k)
    wheel = bpy.data.objects.get("WHEEL_" + k)
    if wheel is None and steer is None:
        continue
    spin_obj = wheel if wheel is not None else steer
    pivots[k] = {"steer": steer, "spin": spin_obj, "C": spin_obj.matrix_world.translation.copy()}
if len(pivots) < 4:
    fail("车轮枢轴不全 (%d/4)：蒙皮模型（如 2021-现代伊兰特）本轮跳过" % len(pivots))
report["wheels_pivots"] = {k: [round(v, 4) for v in pivots[k]["C"]] for k in pivots}

steer_empty = bpy.data.objects.get("STEERING_WHEEL")
steer_pivot_pos = steer_empty.matrix_world.translation.copy() if steer_empty else None

# 采集角色：每个网格属于 哪个角 / 方向盘 / 车身
wheel_objs = {k: [] for k in pivots}
steering_objs = []
role_of = {}
for ob in car_meshes:
    cur = ob.parent
    assigned = None
    while cur is not None:
        if steer_empty is not None and cur == steer_empty:
            assigned = "steering"
            break
        for k, pv in pivots.items():
            if cur == pv["spin"] or (pv["steer"] is not None and cur == pv["steer"]):
                assigned = k
                break
        if assigned:
            break
        cur = cur.parent
    role_of[ob.name] = assigned
    if assigned == "steering":
        steering_objs.append(ob)
    elif assigned in pivots:
        wheel_objs[assigned].append(ob)

body_objs = [o for o in car_meshes if role_of.get(o.name) is None]
if any(len(wheel_objs[k]) == 0 for k in pivots):
    fail("有车轮枢轴下没有网格")

# 记录方向盘世界枢轴、尾部物件等
report["wheel_mesh_counts"] = {k: len(v) for k, v in wheel_objs.items()}


# ---------------------------------------------------------------------------
# 1. 拍平变换（应用 96x 缩放等），全部转到世界坐标
# ---------------------------------------------------------------------------
for ob in car_meshes:
    if ob.name not in bpy.data.objects:
        continue
    mw = ob.matrix_world.copy()
    ob.parent = None
    ob.matrix_world = mw

bpy.ops.object.select_all(action="DESELECT")
for ob in car_meshes:
    ob.hide_set(False)
    ob.hide_viewport = False
    ob.select_set(True)
bpy.context.view_layer.objects.active = car_meshes[0]
bpy.ops.object.make_single_user(object=True, obdata=True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
print("[BAKE] applied transforms on", len(car_meshes), "meshes")


def vert_array(ob):
    n = len(ob.data.vertices)
    arr = np.empty(n * 3, dtype=np.float64)
    ob.data.vertices.foreach_get("co", arr)
    return arr.reshape(n, 3)


def mesh_bbox(objs):
    mn = np.array([1e18, 1e18, 1e18])
    mx = np.array([-1e18, -1e18, -1e18])
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


# 删除枢轴 empty（网格已拍平到世界坐标，位置另存）
_names_car = [o.name for o in car_meshes]
_names_body = [o.name for o in body_objs]
_names_steer = [o.name for o in steering_objs]
_names_wheel = {k: [o.name for o in v] for k, v in wheel_objs.items()}
_names_zero = [o.name for o in car_meshes if len(o.data.vertices) == 0]
for k, pv in pivots.items():
    for e in (pv["steer"], pv["spin"]):
        if e is not None and e.name in bpy.data.objects:
            bpy.data.objects.remove(e, do_unlink=True)
if steer_empty is not None and steer_empty.name in bpy.data.objects:
    bpy.data.objects.remove(steer_empty, do_unlink=True)
for e in [o for o in bpy.data.objects if o.type == "EMPTY"]:
    # 影棚/对焦/旧根节点等 empty 全部清掉，稍后重建干净层级（网格已无父级）
    bpy.data.objects.remove(e, do_unlink=True)
# 删除零顶点占位网格，避免导出一堆空节点
for n in _names_zero:
    if n in bpy.data.objects:
        bpy.data.objects.remove(bpy.data.objects[n], do_unlink=True)
car_meshes = [bpy.data.objects[n] for n in _names_car if n in bpy.data.objects]
body_objs = [bpy.data.objects[n] for n in _names_body if n in bpy.data.objects]
steering_objs = [bpy.data.objects[n] for n in _names_steer if n in bpy.data.objects]
wheel_objs = {k: [bpy.data.objects[n] for n in ns if n in bpy.data.objects] for k, ns in _names_wheel.items()}
bpy.context.view_layer.update()

mn, mx = mesh_bbox(car_meshes)
report["bbox_src"] = [round(float(v), 4) for v in list(mn) + list(mx)]

# ---------------------------------------------------------------------------
# 2. 朝向归一：车头对齐 Blender -Y（= glTF +Z）
# ---------------------------------------------------------------------------
front_pts = [np.array(pivots[k]["C"]) for k in ("FL", "FR") if k in pivots]
rear_pts = [np.array(pivots[k]["C"]) for k in ("RL", "RR") if k in pivots]
theta = 0.0
if len(front_pts) == 2 and len(rear_pts) == 2:
    d = np.mean(front_pts, axis=0) - np.mean(rear_pts, axis=0)
    theta = -math.pi / 2.0 - math.atan2(float(d[1]), float(d[0]))
    # 归一到 [-pi, pi]
    while theta > math.pi:
        theta -= 2 * math.pi
    while theta < -math.pi:
        theta += 2 * math.pi
    if abs(theta) > 1e-4:
        R = Matrix.Rotation(theta, 4, "Z")
        transform_meshes(car_meshes, R)
        print("[ROT] car rotated by %.2f deg" % math.degrees(theta))
report["rotate_deg"] = round(math.degrees(theta), 3)

# 轮心跟着旋转
Rz = Matrix.Rotation(theta, 4, "Z") if abs(theta) > 1e-9 else Matrix.Identity(4)
for k in pivots:
    pivots[k]["C"] = Rz @ pivots[k]["C"]
if steer_pivot_pos is not None:
    steer_pivot_pos = Rz @ steer_pivot_pos

# ---------------------------------------------------------------------------
# 3. 平移归一：X/Z(=glTF) 居中、地面 y=0
# ---------------------------------------------------------------------------
mn, mx = mesh_bbox(car_meshes)
center = (mn + mx) * 0.5
trans = np.array([-center[0], -center[1], -mn[2]])
transform_meshes(car_meshes, Matrix.Translation(Vector(trans.tolist())))
Tt = Matrix.Translation(Vector(trans.tolist()))
for k in pivots:
    pivots[k]["C"] = Tt @ pivots[k]["C"]
if steer_pivot_pos is not None:
    steer_pivot_pos = Tt @ steer_pivot_pos
mn, mx = mesh_bbox(car_meshes)
report["bbox_blender"] = [round(float(v), 4) for v in list(mn) + list(mx)]
report["dims_blender_wlh"] = [round(float(mx[0] - mn[0]), 3), round(float(mx[1] - mn[1]), 3), round(float(mx[2] - mn[2]), 3)]

# ---------------------------------------------------------------------------
# 4. 四角重命名（按真实位置：车头 -Y，左 +X）
# ---------------------------------------------------------------------------
root_empty = bpy.data.objects.new("CarRoot", None)
root_empty.empty_display_type = "PLAIN_AXES"
root_empty.empty_display_size = 0.35
bpy.context.scene.collection.objects.link(root_empty)
root_empty.matrix_world = Matrix.Identity(4)

# 前轮 = 原 STEER 有独立枢轴的角；若数据异常则按 y 小者为前
front_keys = [k for k in ("FL", "FR") if k in pivots]
if len(front_keys) != 2:
    keys = sorted(pivots.keys(), key=lambda k: pivots[k]["C"].y)
    front_keys = keys[:2]
    rear_keys = keys[2:]
else:
    rear_keys = [k for k in pivots if k not in front_keys]

new_name = {}
for keys, tag in ((front_keys, "F"), (rear_keys, "R")):
    l = max(keys, key=lambda k: pivots[k]["C"].x)
    r = min(keys, key=lambda k: pivots[k]["C"].x)
    new_name[l] = tag + "L"
    new_name[r] = tag + "R"
report["corner_map"] = {k: new_name[k] for k in pivots}
report["wheels"] = {}
for old_k in pivots:
    c = pivots[old_k]["C"]
    report["wheels"][new_name[old_k]] = {
        "C_gltf": [round(float(c.x), 4), round(float(c.z), 4), round(float(-c.y), 4)],
        "src_objects": len(wheel_objs[old_k]),
    }

# ---------------------------------------------------------------------------
# 5. 车轮：按「期望轮柱」裁掉误并入轮组的轮眉/翼子板/导风面（裁出的面挂回
#    车身静止件，不删），再按几何分类合并碎片 → Spin(胎+毂) + 静止(盘/卡钳)
#
#    期望轮柱来源（优先级）：
#      a) review json split.wheels[corner] 的 ctr/radius/width（实测值，多数车
#         直接用这个；M3 已验证与 blend 世界系完全吻合）；
#      b) 若该角 json 标了 bad/_estimated（拆分异常），改用轮组自身轮胎材质的
#         几何实测 R/W，避免把胎面外圈切掉（ADRO / 仰望U8）；
#      c) 没有 json 时同样用几何实测。
# ---------------------------------------------------------------------------
review_wheels = {}
if REVIEW_JSON and os.path.exists(REVIEW_JSON):
    try:
        with open(REVIEW_JSON, encoding="utf-8") as _f:
            _rj = json.load(_f)
        _sws = (_rj.get("split") or {}).get("wheels") or []
        _corners = (_rj.get("wheels") or {}).get("corners") or {}
        for _w in _sws:
            _c = _w.get("corner")
            if _c not in ("FL", "FR", "RL", "RR") or not _w.get("ctr"):
                continue
            _est = bool(_w.get("bad")) or bool(_w.get("_estimated_all"))
            _cc = _corners.get(_c) or {}
            if isinstance(_cc, dict) and _cc.get("_estimated_all"):
                _est = True
            review_wheels[_c] = {
                "ctr": [float(v) for v in _w["ctr"]],
                "radius": float(_w.get("radius") or 0.0),
                "width": float(_w.get("width") or 0.0),
                "estimated": _est,
                "bad": list(_w.get("bad") or []),
            }
        report["review_json"] = REVIEW_JSON
        report["review_expected"] = review_wheels
    except Exception as _e:  # noqa: BLE001
        report["warnings"].append("读取 review json 失败: %s" % _e)
        review_wheels = {}
if not review_wheels:
    report["warnings"].append("未提供/无有效 review json")
# 旧游戏 GLB 的车轮包络（游戏里跑着、视觉正确）：作为期望轮柱首选来源。
# 结构 {slug: {"wheels": {corner: {"C":[x,y,z](glTF), "radius", "width"}}}}
old_wheels = {}
if OLD_REF_JSON and os.path.exists(OLD_REF_JSON):
    try:
        with open(OLD_REF_JSON, encoding="utf-8") as _f:
            _or = json.load(_f)
        _car = _or.get(SLUG) or {}
        for _c, _w in (_car.get("wheels") or {}).items():
            if _c in ("FL", "FR", "RL", "RR") and _w.get("C"):
                old_wheels[_c] = {
                    "C": [float(v) for v in _w["C"]],
                    "radius": float(_w.get("radius") or 0.0),
                    "width": float(_w.get("width") or 0.0),
                }
        report["old_wheel_ref"] = OLD_REF_JSON
        report["old_wheel_expected"] = old_wheels
    except Exception as _e:  # noqa: BLE001
        report["warnings"].append("读取 old wheel ref 失败: %s" % _e)
        old_wheels = {}
if not old_wheels:
    report["warnings"].append("未提供旧游戏模型车轮参考，期望轮柱回退 json/几何实测")


def join_objects(objs, new_name_str):
    objs = [o for o in objs if o.name in bpy.data.objects]
    if not objs:
        return None
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.data.name = new_name_str + "_mesh"
    ob.parent = None
    ob.name = new_name_str
    # 关键节点名（游戏按名查找）必须精确：若被同名残留对象挤成 .001，挪开残留再改
    if ob.name != new_name_str and new_name_str.startswith(
            ("Tyre_Wheel_", "Rim_Wheel_", "BrakeDisc_Wheel_", "Caliper_Wheel_")):
        other = bpy.data.objects.get(new_name_str)
        if other is not None and other is not ob:
            other.name = new_name_str + "_dup"
            ob.name = new_name_str
    return ob


def pca_axis(points):
    """返回点云最薄的主轴（单位向量）。points: (N,3) numpy"""
    n = len(points)
    if n < 16:
        return None
    c = points.mean(axis=0)
    p = points - c
    cov = (p.T @ p) / n
    w, v = np.linalg.eigh(cov)
    return v[:, 0]


def tri_data(ob):
    """返回 (三角面顶点索引 (T,3), 三角面中心 (T,3), 三角面所属 polygon 索引 (T,))"""
    me = ob.data
    me.calc_loop_triangles()
    lt = me.loop_triangles
    nt = len(lt)
    if nt == 0 or len(me.vertices) == 0:
        return None, None, None
    tri_idx = np.empty(nt * 3, dtype=np.int32)
    lt.foreach_get("vertices", tri_idx)
    poly_idx = np.empty(nt, dtype=np.int32)
    lt.foreach_get("polygon_index", poly_idx)
    tri_idx = tri_idx.reshape(nt, 3)
    V = vert_array(ob)
    centers = V[tri_idx].mean(axis=1)
    return tri_idx, centers, poly_idx


def split_off_faces(ob, trim_polys, new_name):
    """把 ob 中 trim_polys 指定的 polygon 切到新对象（保留材质/UV 层），
    原对象只保留剩余面。返回新对象；没有可切的面则返回 None。"""
    me = ob.data
    bm_trim = bmesh.new()
    bm_keep = bmesh.new()
    bm_trim.from_mesh(me)
    bm_keep.from_mesh(me)
    bm_trim.faces.ensure_lookup_table()
    bm_keep.faces.ensure_lookup_table()
    keep_faces = [f for f in bm_trim.faces if f.index not in trim_polys]
    if keep_faces:
        bmesh.ops.delete(bm_trim, geom=keep_faces, context="FACES")
    gone_faces = [f for f in bm_keep.faces if f.index in trim_polys]
    if gone_faces:
        bmesh.ops.delete(bm_keep, geom=gone_faces, context="FACES")
    if len(bm_trim.faces) == 0:
        bm_trim.free()
        bm_keep.free()
        return None
    me_trim = bpy.data.meshes.new(new_name + "_mesh")
    bm_trim.to_mesh(me_trim)
    bm_trim.free()
    for m in me.materials:
        me_trim.materials.append(m)
    bm_keep.to_mesh(me)
    bm_keep.free()
    me.update()
    trim_ob = bpy.data.objects.new(new_name, me_trim)
    bpy.context.scene.collection.objects.link(trim_ob)
    trim_ob.matrix_world = Matrix.Identity(4)
    return trim_ob


def derive_expected_cylinder(objs, C):
    """json 缺失/标记异常时，用轮组自身几何实测期望轮径/轮宽。
    优先用轮胎材质（tire/tyre/rubber/sidewall/pneu）的三角面顶点；
    回退到全体三角面中心径向分布的高密度外沿（98 分位）。"""
    C = np.asarray(C, dtype=np.float64)
    tire_pts = []
    all_centers = []
    for ob in objs:
        me = ob.data
        tri_idx, centers, poly_idx = tri_data(ob)
        if centers is None:
            continue
        all_centers.append(centers)
        mats = [m.name or "" for m in me.materials]
        tire_slots = [i for i, mn in enumerate(mats) if TIRE_RE.search(mn)]
        if tire_slots:
            npolys = len(me.polygons)
            pmat = np.empty(npolys, dtype=np.int32)
            me.polygons.foreach_get("material_index", pmat)
            tmat = pmat[poly_idx]
            mask = np.isin(tmat, tire_slots)
            if mask.any():
                tire_pts.append(vert_array(ob)[tri_idx[mask].reshape(-1)])
    src = "geometry_tire"
    R = W = 0.0
    if tire_pts:
        A = np.concatenate(tire_pts, axis=0) - C
        r = np.hypot(A[:, 1], A[:, 2])
        R = float(r.max())
        W = float(A[:, 0].max() - A[:, 0].min())
    if R <= 0.05 and all_centers:
        src = "geometry_all"
        A = np.concatenate(all_centers, axis=0) - C
        r = np.hypot(A[:, 1], A[:, 2])
        R = float(np.percentile(r, 98))
        m = r >= 0.6 * R
        W = float(A[m, 0].max() - A[m, 0].min()) if m.any() else 0.0
    if W <= 0.02:
        W = max(0.22, R * 0.6)
    return R, W, src


M_I = Matrix.Identity(4)
_WHEEL_MAT_MEMO = {}

# —— 车轮材质分类需要的正则 ——
DISC_RE = re.compile(r"disc|disk|brake.?disc|brakedisc|刹车盘", re.I)
CALIPER_RE = re.compile(r"caliper|卡钳", re.I)

trim_body_objs = []      # 从轮组裁出的轮眉/翼子板等（挂车身静止件，不删）
_body_grid_cache = {"grid": None}


def body_face_grid():
    """车身三角面中心 1cm 栅格，用于判断裁出的面是否与车身几何重复（避免 z-fighting）"""
    if _body_grid_cache["grid"] is None:
        keys = set()
        for ob in body_objs:
            if ob.name not in bpy.data.objects or len(ob.data.vertices) == 0:
                continue
            tri_idx, centers, poly_idx = tri_data(ob)
            if centers is None:
                continue
            q = np.round(centers / 0.01).astype(np.int64)
            keys.update(map(tuple, q))
        _body_grid_cache["grid"] = keys
    return _body_grid_cache["grid"]


def trim_wheel_faces(objs, r_cut, x_cut):
    """把 objs 中轮柱外的面切出来（objs 几何已平移到轮心坐标系）。
    返回 (trim_objs, trim_tris)。"""
    trim_objs = []
    n_trim = 0
    for ob in list(objs):
        tri_idx, centers, poly_idx = tri_data(ob)
        if centers is None:
            continue
        V = vert_array(ob)
        tV = V[tri_idx]
        r_v = np.hypot(tV[:, :, 1], tV[:, :, 2]).max(axis=1)
        x_v = np.abs(tV[:, :, 0]).max(axis=1)
        r = np.hypot(centers[:, 1], centers[:, 2])
        x = np.abs(centers[:, 0])
        # 面中心或任一顶点越界即切（大块轮眉/侧裙面只有角点越界也要切掉）
        outside = (r > r_cut) | (x > x_cut) | (r_v > r_cut) | (x_v > x_cut)
        if not outside.any():
            continue
        trim_polys = set(int(p) for p in np.unique(poly_idx[outside]))
        n_trim += int(np.unique(poly_idx[outside]).size)
        t = split_off_faces(ob, trim_polys, sanitize(ob.name + "_trim"))
        if t is not None:
            trim_objs.append(t)
    return trim_objs, n_trim


def remaining_rmax(objs):
    """剩余几何相对轮心的最大径向距离（面中心）"""
    rmax = 0.0
    for ob in objs:
        if ob.name not in bpy.data.objects or len(ob.data.vertices) == 0:
            continue
        tri_idx, centers, poly_idx = tri_data(ob)
        if centers is None:
            continue
        r = np.hypot(centers[:, 1], centers[:, 2])
        rmax = max(rmax, float(r.max()))
    return rmax


# ---------------------------------------------------------------------------
# SU7 专用：源 blend 材质无语义（MeshNMtl），且前轮在模型里带着转角，直接用
# 4 类分类/PCA 会得到混合胎面 + 斜轴。这里改用「胎体几何」主导：
#   1) 用 3D 距轮心 [0.75R,1.10R] 的面当胎体种子做 PCA，得到真实轮轴并转正到 X；
#   2) 胎体点云 bbox 中心迭代 2 次 + 均值校正 → 真实轮心（同时用于枢轴和几何）；
#   3) 转正后按 Lead 规格分胎/毂：胎面 r≥0.80R + 胎侧（|x|≥0.35W 且 0.55R≤r≤0.85R），
#      其余为毂；轮柱外(r>1.05R 或 |x|>W/2+3.5cm)的杂项面切出挂车身。
# ---------------------------------------------------------------------------
SPECIAL_TIRE_GEOM_CARS = {"xiaomi_su7"}


def _tire_pca_axis_deg(tire_objs):
    """返回 (最薄轴 vs X 的角度°, 轴 Vector, 点云)"""
    pts = []
    for ob in tire_objs:
        if ob is None or ob.name not in bpy.data.objects or len(ob.data.vertices) == 0:
            continue
        a = vert_array(ob)
        if len(a) > 6000:
            a = a[:: max(1, len(a) // 6000)]
        pts.append(a)
    if not pts:
        return 0.0, Vector((1, 0, 0)), np.zeros((0, 3))
    A = np.concatenate(pts)
    P = A - A.mean(axis=0)
    cov = (P.T @ P) / max(1, len(P))
    _w, _v = np.linalg.eigh(cov)
    ax = _v[:, 0] / (np.linalg.norm(_v[:, 0]) + 1e-12)
    if ax[0] < 0:
        ax = -ax
    ang = math.degrees(math.acos(max(-1.0, min(1.0, float(ax[0])))))
    return ang, Vector((float(ax[0]), float(ax[1]), float(ax[2]))), A


def _tire_box_off(objs):
    mn = np.array([1e18, 1e18, 1e18])
    mx = np.array([-1e18, -1e18, -1e18])
    for ob in objs:
        if ob is None or ob.name not in bpy.data.objects or len(ob.data.vertices) == 0:
            continue
        a = vert_array(ob)
        mn = np.minimum(mn, a.min(axis=0))
        mx = np.maximum(mx, a.max(axis=0))
    return (mn + mx) * 0.5, mn, mx


def _trim_extreme_faces(ob, axis_idx, limit, W, tag):
    """把 ob 中该轴向顶点超限的面切到 Trim（世界坐标由 W 变换）"""
    tri_idx, centers, poly_idx = tri_data(ob)
    if centers is None:
        return None, 0
    V = vert_array(ob)
    vv = np.abs(V[tri_idx][:, :, axis_idx]).max(axis=1)
    out = vv > limit
    if not out.any():
        return None, 0
    polys = set(int(p) for p in np.unique(poly_idx[out]))
    t = split_off_faces(ob, polys, tag)
    if t is not None:
        transform_meshes([t], W)
    return t, len(polys)


def special_tire_split(objs, R_ref, W_ref, key, C_orig):
    """SU7 专用：材质无语义，按「胎体几何」重分胎/毂并用胎体定轮心/轮轴。
    objs 已平移到期望轮心 C_orig 为原点。返回胎/毂网格、修正后世界轮心、
    轴角、Trim 网格（世界坐标）等信息。"""
    info = {"trim_tris": 0, "trim_dropped": False, "trim_joined": [], "C_orig": C_orig}

    def tri_centers_all():
        out = []
        for ob in objs:
            if ob.name not in bpy.data.objects or len(ob.data.vertices) == 0:
                continue
            _ti, centers, _pi = tri_data(ob)
            if centers is not None:
                out.append(centers)
        return np.concatenate(out) if out else None

    # local(当前) -> world 累积矩阵
    W = Matrix.Translation(C_orig)

    # 1) 胎体种子 PCA → 轮轴转正
    A = tri_centers_all()
    d = np.linalg.norm(A, axis=1)
    seed = (d >= 0.75 * R_ref) & (d <= 1.10 * R_ref)
    P = A[seed] if int(seed.sum()) > 50 else A
    Pc = P - P.mean(axis=0)
    cov = (Pc.T @ Pc) / max(1, len(Pc))
    _w, _v = np.linalg.eigh(cov)
    ax = _v[:, 0] / (np.linalg.norm(_v[:, 0]) + 1e-12)
    if ax[0] < 0:
        ax = -ax
    axis_deg = math.degrees(math.acos(max(-1.0, min(1.0, float(ax[0])))))
    a = Vector((float(ax[0]), float(ax[1]), float(ax[2])))
    R_a = a.rotation_difference(Vector((1, 0, 0))).to_matrix().to_4x4()
    for ob in objs:
        transform_meshes([ob], R_a)
    W = W @ R_a.inverted()

    # 2) 胎体点云 → 轮心（胎面环带 bbox 中心迭代 2 次）
    A2 = tri_centers_all()
    d2 = np.linalg.norm(A2, axis=1)
    s2 = (d2 >= 0.75 * R_ref) & (d2 <= 1.10 * R_ref)
    r_t_pct = float(np.percentile(d2[s2], 95)) if int(s2.sum()) > 50 else R_ref
    band = np.abs(d2 - r_t_pct) <= 0.045
    Q = A2[band] if int(band.sum()) > 60 else A2[s2]
    if len(Q) < 60:
        Q = A2
    cen = Q.copy()
    off = np.zeros(3)
    for _ in range(2):
        mn = cen.min(axis=0)
        mx = cen.max(axis=0)
        ctr = (mn + mx) * 0.5
        cen = cen - ctr
        off = off + ctr
    for ob in objs:
        transform_meshes([ob], Matrix.Translation(Vector((-off).tolist())))
    W = W @ Matrix.Translation(Vector(off.tolist()))

    # 3) 初次分类：先切轮柱外杂项 → Trim，再切胎面/胎侧 → Tyre，其余 Rim
    R_cut = R_ref * 1.05
    X_cut = W_ref * 0.5 + 0.035
    tire_parts, rim_parts = [], []
    trim_objs = []

    def _cut_junk(ob):
        nonlocal info
        tri_idx, centers, poly_idx = tri_data(ob)
        if centers is None:
            return None
        r = np.hypot(centers[:, 1], centers[:, 2])
        x = np.abs(centers[:, 0])
        junk = (r > R_cut) | (x > X_cut)
        if not junk.any():
            return None
        polys = set(int(p) for p in np.unique(poly_idx[junk]))
        info["trim_tris"] += len(polys)
        t = split_off_faces(ob, polys, sanitize(ob.name + "_trim"))
        if t is not None:
            transform_meshes([t], W)
            trim_objs.append(t)
        return t

    def _cut_tire(ob):
        tri_idx, centers, poly_idx = tri_data(ob)
        if centers is None:
            return None
        r = np.hypot(centers[:, 1], centers[:, 2])
        x = np.abs(centers[:, 0])
        tire_face = (r >= 0.80 * R_ref) | ((x >= 0.35 * W_ref) & (r >= 0.55 * R_ref) & (r <= 0.90 * R_ref))
        if not tire_face.any():
            return None
        polys = set(int(p) for p in np.unique(poly_idx[tire_face]))
        t = split_off_faces(ob, polys, sanitize(ob.name + "_tirepart"))
        return t

    for ob in list(objs):
        if ob.name not in bpy.data.objects or len(ob.data.vertices) == 0:
            continue
        _cut_junk(ob)
        if len(ob.data.vertices) == 0:
            continue
        t = _cut_tire(ob)
        if t is not None:
            tire_parts.append(t)
        if len(ob.data.vertices) > 0:
            rim_parts.append(ob)

    tire = join_objects(tire_parts, "Tyre_Wheel_" + key)
    rim = join_objects(rim_parts, "Rim_Wheel_" + key)
    if tire is None or rim is None:
        info["tire"] = tire
        info["rim"] = rim
        return info

    # 4) 迭代：用最终 Tyre 网格的顶点云反复校正轴/心（对齐探针指标）
    axis_after_deg = 0.0
    for _it in range(2):
        ang2, ax2, _A = _tire_pca_axis_deg([tire])
        axis_after_deg = ang2
        if ang2 > 0.05:
            R2 = ax2.rotation_difference(Vector((1, 0, 0))).to_matrix().to_4x4()
            for o in (tire, rim):
                transform_meshes([o], R2)
            W = W @ R2.inverted()
        c, mn, mx = _tire_box_off([tire])
        for o in (tire, rim):
            transform_meshes([o], Matrix.Translation(Vector((-c).tolist())))
        W = W @ Matrix.Translation(Vector(c.tolist()))
        # 削掉胎体 y/z 向的杂项凸出，保证 y/z 尺寸比 0.97~1.03
        c2, mn2, mx2 = _tire_box_off([tire])
        hy = (mx2[1] - mn2[1]) * 0.5
        hz = (mx2[2] - mn2[2]) * 0.5
        target = min(hy, hz) * 1.01
        for ax_idx in (1, 2):
            t2, n2 = _trim_extreme_faces(tire, ax_idx, target, W, sanitize(tire.name + "_yt"))
            if t2 is not None:
                trim_objs.append(t2)
                info["trim_tris"] += n2
        # 轮宽方向也不超过旧模型轮宽 + 2cm
        t3, n3 = _trim_extreme_faces(tire, 0, W_ref * 0.5 + 0.02, W, sanitize(tire.name + "_xt"))
        if t3 is not None:
            trim_objs.append(t3)
            info["trim_tris"] += n3

    # 5) 收尾：Trim 去重 + join；最终轮心
    trim_joined = []
    if trim_objs:
        grid = body_face_grid()
        tcent = []
        for o in trim_objs:
            if len(o.data.vertices) == 0:
                continue
            _ti, centers, _pi = tri_data(o)
            if centers is not None:
                tcent.append(centers)
        dup_ratio = 0.0
        if tcent:
            T = np.concatenate(tcent, axis=0)
            q = np.round(T / 0.01).astype(np.int64)
            dup_ratio = sum(1 for row in q if tuple(row) in grid) / max(1, len(T))
        info["trim_dup_ratio"] = round(dup_ratio, 3)
        if dup_ratio > 0.5:
            info["trim_dropped"] = True
            for o in trim_objs:
                if o.name in bpy.data.objects:
                    bpy.data.objects.remove(o, do_unlink=True)
        else:
            tm = join_objects([o for o in trim_objs if o.name in bpy.data.objects], "Trim_Wheel_" + key)
            if tm is not None:
                trim_joined.append(tm)
    info["trim_joined"] = trim_joined

    C_new = W @ Vector((0.0, 0.0, 0.0))
    info["C_new_world"] = C_new
    c_final, mn3, mx3 = _tire_box_off([tire])
    info["tire"] = tire
    info["rim"] = rim
    info["axis_deg"] = axis_deg
    info["axis_after_deg"] = _tire_pca_axis_deg([tire])[0]
    info["center_off_cm"] = float(np.linalg.norm(c_final)) * 100.0
    info["tyre_r_meas"] = float((mx3[2] - mn3[2]) * 0.5)
    info["tyre_center_gltf"] = [round(float(C_new.x), 4), round(float(C_new.z), 4),
                                round(float(-C_new.y), 4)]

    def _ntris(o):
        if o is None:
            return 0
        o.data.calc_loop_triangles()
        return len(o.data.loop_triangles)

    info["tire_tris"] = _ntris(tire)
    info["rim_tris"] = _ntris(rim)
    return info




for old_k in pivots:
    key = new_name[old_k]
    C = pivots[old_k]["C"].copy()
    objs = [o for o in wheel_objs[old_k] if o.name in bpy.data.objects and len(o.data.vertices) > 0]
    if not objs:
        continue
    n_src = len(objs)

    # 0) 期望轮柱：旧游戏 GLB 包络(R/W)优先（游戏里视觉正确），json 次之，几何实测兜底。
    #    位置/枢轴以 blend 里的 WHEEL_ 枢轴为准（新模型轮距可能和旧模型不同）。
    exp = review_wheels.get(old_k)
    old = old_wheels.get(old_k)
    expected_source = "old_game_glb"
    R_exp = W_exp = 0.0
    if old and old["radius"] > 0.05 and old["width"] > 0.02:
        R_exp, W_exp = old["radius"], old["width"]
        oc = Vector((old["C"][0], -old["C"][2], old["C"][1]))  # glTF -> 归一后 Blender
        dev = (oc - pivots[old_k]["C"]).length
        if dev > 0.05:
            report["warnings"].append(
                "%s: 旧游戏模型轮心与 blend 枢轴偏差 %.1fcm（位置用枢轴，包络用旧模型）" % (key, dev * 100))
        report["wheels"][key]["old_C_gltf"] = [round(float(v), 4) for v in old["C"]]
        report["wheels"][key]["old_ctr_dev_cm"] = round(dev * 100, 2)
    elif exp and exp["radius"] > 0.05 and not exp["estimated"]:
        expected_source = "review_json"
        C_cand = Tt @ (Rz @ Vector(exp["ctr"]))
        piv = pivots[old_k]["C"]
        dev = (C_cand - piv).length
        if dev > 0.05:
            report["warnings"].append("%s: json ctr 与 WHEEL 枢轴偏差 %.1fcm，改用枢轴" % (key, dev * 100))
        R_exp, W_exp = exp["radius"], exp["width"]
        if W_exp <= 0.02:
            W_exp = R_exp * 0.62
    else:
        expected_source = "geometry"
        Cnp0 = np.array([C.x, C.y, C.z])
        R_exp, W_exp, derived_src = derive_expected_cylinder(objs, Cnp0)
        expected_source = derived_src
        if exp:
            report["warnings"].append(
                "%s: 无旧模型包络且 review json 轮组标记异常(%s)，期望轮径改用几何实测 %s R=%.3f W=%.3f"
                % (key, "/".join(exp["bad"]) or "estimated", derived_src, R_exp, W_exp))
        else:
            report["warnings"].append(
                "%s: 无旧模型包络/无 review json，期望轮柱改用几何实测 %s R=%.3f W=%.3f"
                % (key, derived_src, R_exp, W_exp))
    if R_exp <= 0.05 or W_exp <= 0.02:
        fail("车轮期望半径/宽度无效 %s (R=%.3f W=%.3f)" % (key, R_exp, W_exp))
    Cnp = np.array([C.x, C.y, C.z])
    print("[WHEEL] %s src_objs=%d R_exp=%.4f W_exp=%.4f src=%s C=%s" % (
        key, n_src, R_exp, W_exp, expected_source, [round(float(v), 3) for v in C]), flush=True)

    # 1) 平移到期望轮心
    for ob in objs:
        transform_meshes([ob], Matrix.Translation(-C))

    special_mode = SLUG in SPECIAL_TIRE_GEOM_CARS
    if special_mode:
        sp = special_tire_split(objs, R_exp, W_exp, key, C)
        C = sp["C_new_world"]
        pivots[old_k]["C"] = C
        if sp["tire"] is None or sp["rim"] is None:
            fail("special_tire_split 胎/毂划分不完整 %s (tire=%s rim=%s)" % (
                old_k, sp["tire"] is not None, sp["rim"] is not None))
        merged = {"tire": sp["tire"], "rim": sp["rim"], "disc": None, "caliper": None}
        spin_objs = [o for o in (sp["tire"], sp["rim"]) if o is not None]
        all_wheel_objs = list(spin_objs)
        classes = {"tire": 1 if sp["tire_tris"] else 0, "rim": 1 if sp["rim_tris"] else 0,
                   "disc": 0, "caliper": 0}
        fragment_mode = False
        n_trim_tris = sp["trim_tris"]
        trim_dropped = sp["trim_dropped"]
        ang = sp["axis_deg"]
        ctr_dev_cm = sp["center_off_cm"]
        WW = report["wheels"][key]
        WW["special_tire_geom"] = True
        WW["tyre_center_gltf"] = sp["tyre_center_gltf"]
        WW["tyre_axis_deg"] = round(sp["axis_deg"], 2)
        WW["tyre_axis_after_deg"] = round(sp["axis_after_deg"], 2)
        WW["tyre_r_measured"] = round(sp["tyre_r_meas"], 4)
        WW["axle_tilt_deg"] = round(sp["axis_deg"], 2)
        WW["axle_aspect"] = 0.0
        WW["ctr_dev_cm"] = round(ctr_dev_cm, 2)
        WW["classes"] = {"tire": sp["tire_tris"], "rim": sp["rim_tris"],
                         "disc": 0, "caliper": 0}
        for tm in sp["trim_joined"]:
            trim_body_objs.append(tm)
        print("[SPECIAL-TIRE] %s axis=%.1f->%.2f deg centre_off=%.1fcm C_gltf=%s trim=%d tire_tris=%d rim_tris=%d" % (
            key, ang, sp["axis_after_deg"], ctr_dev_cm, sp["tyre_center_gltf"],
            n_trim_tris, sp["tire_tris"], sp["rim_tris"]), flush=True)
    else:
        # 2) 两遍裁面：轮柱外的轮眉/翼子板/导风面 → Trim（挂车身，不删）
        trim_objs, n_trim_tris = trim_wheel_faces(objs, R_exp * 1.05, W_exp * 0.5 + 0.05)
        objs = [o for o in objs if o.name in bpy.data.objects and len(o.data.vertices) > 0]
        r_remain = remaining_rmax(objs)
        if r_remain > R_exp * 1.05:
            t2, n2 = trim_wheel_faces(objs, R_exp * 1.02, W_exp * 0.5 + 0.05)
            trim_objs += t2
            n_trim_tris += n2
            objs = [o for o in objs if o.name in bpy.data.objects and len(o.data.vertices) > 0]
            print("[TRIM2] %s 第二遍裁面 r_remain=%.3f -> cut@%.3f tris=%d" % (
                key, r_remain, R_exp * 1.02, n2), flush=True)
        if not objs:
            fail("轮组裁面后无剩余几何 %s" % key)
        print("[TRIM] %s trim_tris=%d remain_objs=%d r_remain=%.3f" % (
            key, n_trim_tris, len(objs), r_remain), flush=True)

        # Trim 处理：若与车身已有几何重复则丢弃（避免 z-fighting），否则挂到车身
        trim_dropped = False
        if trim_objs:
            for o in trim_objs:
                transform_meshes([o], Matrix.Translation(C))
            grid = body_face_grid()
            tcent = []
            for o in trim_objs:
                if len(o.data.vertices) == 0:
                    continue
                tri_idx, centers, poly_idx = tri_data(o)
                if centers is not None:
                    tcent.append(centers)
            dup_ratio = 0.0
            if tcent:
                A = np.concatenate(tcent, axis=0)
                q = np.round(A / 0.01).astype(np.int64)
                hit = sum(1 for row in q if tuple(row) in grid)
                dup_ratio = hit / max(1, len(A))
            report["wheels"][key]["trim_dup_ratio"] = round(dup_ratio, 3)
            if dup_ratio > 0.5:
                trim_dropped = True
                for o in trim_objs:
                    if o.name in bpy.data.objects:
                        bpy.data.objects.remove(o, do_unlink=True)
                trim_objs = []
            else:
                tm = join_objects(trim_objs, "Trim_Wheel_" + key)
                if tm is not None:
                    trim_body_objs.append(tm)

        # 3) 逐对象几何统计（几何已平移到期望轮心，坐标即相对量）
        stats = {}
        for ob in objs:
            a = vert_array(ob)
            if len(a) == 0:
                continue
            rad = np.hypot(a[:, 1], a[:, 2])
            rmax = float(rad.max())
            center = (a.min(axis=0) + a.max(axis=0)) * 0.5
            off = float(math.hypot(center[1], center[2]))
            stats[ob.name] = (rmax, off, [m.name or "" for m in ob.data.materials if m])

        # 4) 分类：碎片轮组(>12 源对象)只分 胎/毂 两组且全挂 Spin；
        #    干净轮组保留 胎/毂/刹车盘/卡钳 4 类（盘+卡钳静止）
        fragment_mode = n_src > 12
        max_rmax = max((s[0] for s in stats.values()), default=0.0)
        # 分类阈值半径：几何实测最大半径（旧模型轮径可能与新模型不一致，如仰望U8 旧 0.434 实测 0.383）
        R_cls = max_rmax if max_rmax > 0.5 * R_exp else R_exp
        classes = {"tire": [], "rim": [], "disc": [], "caliper": []}
        for ob in objs:
            if ob.name not in stats:
                continue
            rmax, off, mats = stats[ob.name]
            joined = " ".join(mats)
            if fragment_mode:
                cls = "tire" if rmax >= 0.90 * R_cls else "rim"
            elif DISC_RE.search(joined) and not TIRE_RE.search(joined):
                cls = "disc"
            elif off > 0.30 * R_exp and rmax < 0.75 * R_exp:
                # 卡钳 = 小且明显偏心；大件(胎/毂)即使包围盒偏心也不能判成卡钳
                cls = "caliper"
            elif rmax >= 0.93 * R_cls:
                cls = "tire"
            else:
                cls = "rim"
            classes[cls].append(ob)
        # 兜底1：干净轮组若胎/毂都没分出来（轮组形态怪），退化成 胎/毂 二分，保证能转
        if not fragment_mode and not classes["tire"] and not classes["rim"]:
            report["warnings"].append("%s: 4 类分类失败，退化为 胎/毂 二分" % key)
            for ob in list(classes["disc"] + classes["caliper"]):
                rmax = stats[ob.name][0]
                classes["tire" if rmax >= 0.85 * R_cls else "rim"].append(ob)
            classes["disc"], classes["caliper"] = [], []
        # 兜底2：Tyre/Rim 两个节点都要有（游戏车库按名查找）；缺则从多的那组挪一个
        if classes["tire"] and not classes["rim"]:
            biggest = min(classes["tire"], key=lambda o: stats[o.name][0])
            classes["tire"].remove(biggest)
            classes["rim"].append(biggest)
            report["warnings"].append("%s: 无 Rim 组件，从 Tire 组拆出最小件当 Rim" % key)
        elif classes["rim"] and not classes["tire"]:
            biggest = max(classes["rim"], key=lambda o: stats[o.name][0])
            classes["rim"].remove(biggest)
            classes["tire"].append(biggest)
            report["warnings"].append("%s: 无 Tire 组件，从 Rim 组拆出最大件当 Tire" % key)
        print("[CLASS] %s fragment=%s classes=%s" % (
            key, fragment_mode, {k: len(v) for k, v in classes.items()}), flush=True)

        # 5) 合并
        merged = {}
        for cls in ("tire", "rim", "disc", "caliper"):
            nm = {"tire": "Tyre_Wheel_", "rim": "Rim_Wheel_",
                  "disc": "BrakeDisc_Wheel_", "caliper": "Caliper_Wheel_"}[cls]
            merged[cls] = join_objects(classes[cls], nm + key) if classes[cls] else None
        spin_objs = [o for o in (merged["tire"], merged["rim"]) if o is not None]
        all_wheel_objs = [o for o in merged.values() if o is not None]
        if not spin_objs:
            fail("轮组分类后无 Spin 几何 %s" % key)

        # 6) 轮轴校准：把整个轮组（含静止盘/卡钳）一起旋到轴沿 X
        pts = np.concatenate([vert_array(o) for o in spin_objs if len(o.data.vertices)], axis=0)
        if len(pts) > 4000:
            pts = pts[:: len(pts) // 4000 + 1]
        ax = pca_axis(pts)
        ang = 0.0
        if ax is not None:
            ax = ax / (np.linalg.norm(ax) + 1e-12)
            if ax[0] < 0:
                ax = -ax
            ang = math.degrees(math.acos(max(-1.0, min(1.0, float(ax[0])))))
        pre_mn, pre_mx = mesh_bbox(spin_objs)
        _x_ext = float(pre_mx[0] - pre_mn[0])
        _diam = float(max(pre_mx[1] - pre_mn[1], pre_mx[2] - pre_mn[2]))
        aspect = _x_ext / max(_diam, 1e-6)
        report["wheels"][key]["axle_tilt_deg"] = round(ang, 2)
        report["wheels"][key]["axle_aspect"] = round(aspect, 3)
        # 只在「确实倾斜」（轮轴不沿 X 时 x 向包络会变厚）时才转正；否则保持原状，
        # 避免把本来就对齐的轮子被噪声 PCA 转歪（SU7 曾因此宽度膨胀 40%）。
        if 2.0 < ang < 20.0 and aspect > 0.55:
            a = Vector((float(ax[0]), float(ax[1]), float(ax[2])))
            Ra = a.rotation_difference(Vector((1, 0, 0))).to_matrix().to_4x4()
            transform_meshes(all_wheel_objs, Ra)
            print("[AXLE] %s aligned %.1f deg -> X" % (key, ang))
        elif ang > 2.0:
            print("[AXLE] %s skip rotate (tilt %.1f deg, aspect %.2f)" % (key, ang, aspect))

        # 7) 枢轴 = blend 期望轮心（不再按 spin 包围盒回中心）；偏差只告警
        smn, smx = mesh_bbox(spin_objs)
        off = (smn + smx) * 0.5
        ctr_dev_cm = float(np.linalg.norm(off)) * 100.0
        report["wheels"][key]["ctr_dev_cm"] = round(ctr_dev_cm, 2)
        pivots[old_k]["C"] = C

    # 8) 层级：Wheel_XX > Spin_Wheel_XX > (胎/毂)；Wheel_XX > (盘/卡钳)
    wheel_empty = bpy.data.objects.new("Wheel_" + key, None)
    wheel_empty.empty_display_type = "ARROWS"
    wheel_empty.empty_display_size = 0.12
    bpy.context.scene.collection.objects.link(wheel_empty)
    wheel_empty.parent = root_empty
    wheel_empty.matrix_parent_inverse = Matrix.Identity(4)
    wheel_empty.matrix_basis = M_I
    wheel_empty.matrix_world = Matrix.Translation(C)
    spin_empty = bpy.data.objects.new("Spin_Wheel_" + key, None)
    spin_empty.empty_display_type = "CIRCLE"
    spin_empty.empty_display_size = 0.18
    bpy.context.scene.collection.objects.link(spin_empty)
    spin_empty.parent = wheel_empty
    spin_empty.matrix_parent_inverse = Matrix.Identity(4)
    spin_empty.matrix_basis = M_I
    for o in spin_objs:
        o.parent = spin_empty
        o.matrix_parent_inverse = Matrix.Identity(4)
        o.matrix_basis = M_I
    for cls in ("disc", "caliper"):
        o = merged[cls]
        if o is not None:
            o.parent = wheel_empty
            o.matrix_parent_inverse = Matrix.Identity(4)
            o.matrix_basis = M_I
    # 9) 材质打标（游戏的车库换装/改色靠材质名匹配）
    class_prefix = {"tire": "Tyre_", "rim": "Rim_", "disc": "BrakeDisc_", "caliper": "Caliper_"}
    mat_memo = _WHEEL_MAT_MEMO
    for cls in ("tire", "rim", "disc", "caliper"):
        o = merged[cls]
        if o is None:
            continue
        for si, m in enumerate(list(o.data.materials)):
            if m is None:
                continue
            prefix = class_prefix[cls]
            base_name = re.sub(r"^(Tyre_|Rim_|BrakeDisc_|Caliper_)+", "", m.name or "")
            want = prefix + base_name
            memo_key = (prefix, m.name)
            if memo_key in mat_memo:
                copy = bpy.data.materials.get(mat_memo[memo_key])
            else:
                copy = m.copy()
                copy.name = want
                mat_memo[memo_key] = copy.name
            o.data.materials[si] = copy

    # 10) 轮径/轮宽 & 与旧模型包络/json 期望值比对
    smn2, smx2 = mesh_bbox(spin_objs)
    measured_r = round(float(max(smx2[1] - smn2[1], smx2[2] - smn2[2]) / 2.0), 4)
    measured_w = round(float(smx2[0] - smn2[0]), 4)
    W = report["wheels"][key]
    W["radius"] = measured_r
    W["width"] = measured_w
    W["pivot_source"] = expected_source
    W["trimmed_tris"] = n_trim_tris
    W["trim_dropped_duplicate"] = trim_dropped
    W["fragment_mode"] = fragment_mode
    W["src_objects"] = n_src
    W["C_gltf"] = [round(float(C.x), 4), round(float(C.z), 4), round(float(-C.y), 4)]
    W["classes"] = {k: (len(v) if isinstance(v, (list, tuple)) else v) for k, v in classes.items()}
    W["object"] = [o.name for o in all_wheel_objs]
    if old and old["radius"] > 0.05:
        orr, oww = old["radius"], old["width"]
        dev_r = (measured_r - orr) / orr * 100.0
        dev_w = (measured_w - oww) / oww * 100.0 if oww > 0.02 else 0.0
        W["old_radius"] = round(orr, 4)
        W["old_width"] = round(oww, 4)
        W["dev_old_radius_pct"] = round(dev_r, 2)
        W["dev_old_width_pct"] = round(dev_w, 2)
        if abs(dev_r) > 5.0:
            report["warnings"].append(
                "%s: measured_r=%.3f 与旧模型 r=%.3f 偏差 %+.1f%%（>5%%）"
                % (key, measured_r, orr, dev_r))
        if abs(dev_w) > 8.0:
            report["warnings"].append(
                "%s: measured_w=%.3f 与旧模型 w=%.3f 偏差 %+.1f%%"
                % (key, measured_w, oww, dev_w))
    if exp and exp["radius"] > 0.05:
        jr, jw = exp["radius"], exp["width"]
        W["json_radius"] = round(jr, 4)
        W["json_width"] = round(jw, 4)
        W["dev_json_radius_pct"] = round((measured_r - jr) / jr * 100.0, 2)
        W["json_estimated"] = bool(exp["estimated"])
for tm in trim_body_objs:
    tm.parent = root_empty
    tm.matrix_parent_inverse = Matrix.Identity(4)
    tm.matrix_basis = M_I
report["trim_body_objects"] = [o.name for o in trim_body_objs]

# 7.5) 特殊几何车（SU7）：各角胎心独立测量会带来 1~2cm 的左右/前后不对称，
#      这里按左右/前后成对求平均做对称化（只平移 Wheel_XX 枢轴，几何跟随），
#      保持游戏验收要求的 |x|/z 对称 <1cm。
if SLUG in SPECIAL_TIRE_GEOM_CARS:
    pairs = (("FL", "FR"), ("RL", "RR"))
    for pa, pb in pairs:
        ka, kb = new_name[pa], new_name[pb]
        Ca = pivots[pa]["C"]
        Cb = pivots[pb]["C"]
        sx = (abs(float(Ca.x)) + abs(float(Cb.x))) * 0.5
        sy = (float(Ca.y) + float(Cb.y)) * 0.5
        sz = (float(Ca.z) + float(Cb.z)) * 0.5
        Ca2 = Vector((sx, sy, sz))
        Cb2 = Vector((-sx, sy, sz))
        for key2, Cnew in ((ka, Ca2), (kb, Cb2)):
            old_c = pivots[pa if key2 == ka else pb]["C"]
            delta = Cnew - old_c
            we = bpy.data.objects.get("Wheel_" + key2)
            if we is not None:
                we.matrix_world = Matrix.Translation(Cnew)
            pivots[pa if key2 == ka else pb]["C"] = Cnew
            W = report["wheels"][key2]
            W["C_gltf"] = [round(float(Cnew.x), 4), round(float(Cnew.z), 4), round(float(-Cnew.y), 4)]
            W["symmetrized"] = True
            W["sym_shift_cm"] = round(float(delta.length) * 100.0, 2)
    print("[SYMMETRIZE] %s wheel pivots symmetrized: %s" % (
        SLUG, {k: report["wheels"][k]["C_gltf"] for k in report["wheels"]}), flush=True)


# ---------------------------------------------------------------------------
# 6. 车身 / 玻璃 / 尾翼：按材质签名合并（降 draw call，保留尾翼节点名）
# ---------------------------------------------------------------------------
def obj_materials(ob):
    return [m for m in ob.data.materials if m is not None]


def obj_is_wing(ob):
    names = [ob.name or ""] + [m.name or "" for m in obj_materials(ob)]
    cur = ob.parent
    low = " ".join(n.lower() for n in names)
    return any(h in low for h in WING_HINTS)


def obj_is_glass(ob):
    ms = obj_materials(ob)
    return bool(ms) and all(GLASS_RE.search(m.name or "") for m in ms)


wing_objs = [o for o in body_objs if obj_is_wing(o)]
body_objs = [o for o in body_objs if o not in wing_objs]

def add_to_root(ob):
    ob.parent = root_empty
    ob.matrix_parent_inverse = Matrix.Identity(4)
    ob.matrix_basis = M_I

merged_groups = 0
for group_type, objs in (("body", body_objs), ("wing", wing_objs)):
    groups = {}
    for ob in objs:
        ms = obj_materials(ob)
        sig = (group_type, tuple(sorted(sanitize(m.name or "") for m in ms)))
        glass = all(GLASS_RE.search(m.name or "") for m in ms) if ms else False
        hint = "glass" if glass else ""
        groups.setdefault((sig[0], sig[1], hint), []).append(ob)
    idx = 0
    for (gtype, sig, hint), grp in groups.items():
        idx += 1
        if gtype == "wing":
            nm = "Spoiler_%02d" % idx
        elif hint == "glass":
            nm = "Glass_%02d" % idx
        elif len(grp) == 1:
            nm = sanitize(grp[0].name)
        else:
            nm = "Body_%02d" % idx
        merged = join_objects(grp, nm)
        if merged is None:
            continue
        merged_groups += 1
        add_to_root(merged)
report["body_merged_groups"] = merged_groups

# 尾翼包围盒 → WingMount
wing_bbox_objs = [o for o in bpy.data.objects if (o.type == "MESH" and o.name.startswith("Spoiler_"))]
wm_pos = None
if wing_bbox_objs:
    wmn, wmx = mesh_bbox(wing_bbox_objs)
    wm_pos = Vector((0.0, (wmn[1] + wmx[1]) * 0.5 - 0.07, wmn[2] + 0.03))
    report["wing_bbox"] = [round(float(v), 4) for v in list(wmn) + list(wmx)]
if wm_pos is None:
    h = float(mx[2] - mn[2])
    length = float(mx[1] - mn[1])
    wm_pos = Vector((0.0, 0.45 * length, 0.75 * h))
wing_mount = bpy.data.objects.new("WingMount", None)
wing_mount.empty_display_type = "PLAIN_AXES"
wing_mount.empty_display_size = 0.12
bpy.context.scene.collection.objects.link(wing_mount)
wing_mount.parent = root_empty
wing_mount.matrix_parent_inverse = Matrix.Identity(4)
wing_mount.matrix_basis = M_I
wing_mount.matrix_world = Matrix.Translation(wm_pos)
report["wing_mount_gltf"] = [round(float(wm_pos.x), 4), round(float(wm_pos.z), 4), round(float(-wm_pos.y), 4)]

# ---------------------------------------------------------------------------
# 7. 方向盘枢轴
# ---------------------------------------------------------------------------
if steer_pivot_pos is not None and steering_objs:
    sp = steer_pivot_pos
    for o in steering_objs:
        transform_meshes([o], Matrix.Translation(-sp))
    sp_empty = bpy.data.objects.new("SteerPivot", None)
    sp_empty.empty_display_type = "SINGLE_ARROW"
    sp_empty.empty_display_size = 0.1
    bpy.context.scene.collection.objects.link(sp_empty)
    sp_empty.parent = root_empty
    sp_empty.matrix_parent_inverse = Matrix.Identity(4)
    sp_empty.matrix_world = Matrix.Translation(sp)
    for o in steering_objs:
        o.parent = sp_empty
        o.matrix_parent_inverse = Matrix.Identity(4)
        o.matrix_basis = M_I
    report["steer_pivot_gltf"] = [round(float(sp.x), 4), round(float(sp.z), 4), round(float(-sp.y), 4)]
else:
    report["steer_pivot_gltf"] = None

# ---------------------------------------------------------------------------
# 8. 材质：Godot 取向（玻璃半透、非玻璃不透明、保留原厂贴图/PBR/清漆）
# ---------------------------------------------------------------------------
# 8.0) 车身漆材质兜底识别：个别源 blend 的车漆材质名没有 paint/carpaint 语义
#      （如 bmw_m4_gt4/bmw_m6_gt3 的 "ext"、bmw_m8_cabrio 的 "b:..._Base_053"），
#      游戏按材质名匹配换色 → 换色无效、无运行时清漆。这里在车身子树里按
#      「材质名语义 + 三角面占比 + 不透明/非自发光/非玻璃」找最大候选，
#      复制成 CARPAINT_<原名> 并只替换车身子树的材质槽（保留贴图/PBR）。
#      已有 carpaint/paint 材质（其余车型）时跳过。
PAINT_POS_HINTS = ("carpaint", "paint", "车漆", "coloured", "color", "colour",
                   "base", "ext", "external", "body")
PAINT_NEG_RE = re.compile(
    r"glass|glaz|window|windscreen|windshield|挡风|玻璃|灯|lamp|light|lens|emiss|"
    r"interior|int[0-9_]|内饰|cab|sw|steer|方向盘|rim|wheel|轮|tyre|tire|brake|disc|"
    r"rotor|caliper|卡钳|carbon|cabon|碳纤维|chrome|镀铬|grille|grid|badge|plate|"
    r"车牌|plastic|塑料|softtop|软顶|spo|misc|chassis|底盘|detail|alpha|mat[0-9]|"
    r"坏|ring|trim", re.I)


def _body_meshes_for_paint():
    """车身子树网格：CarRoot 下、不在 Wheel_*/Spin_Wheel_*/SteerPivot/Trim 下"""
    out = []
    for ob in root_empty.children_recursive:
        if ob.type != "MESH":
            continue
        cur = ob
        skip = False
        while cur is not None and cur != root_empty:
            nm = cur.name or ""
            if (nm.startswith("Wheel_") or nm.startswith("Spin_Wheel_")
                    or nm == "SteerPivot" or nm.startswith("Trim_Wheel_")
                    or nm.startswith("STEERING_")):
                skip = True
                break
            cur = cur.parent
        if not skip:
            out.append(ob)
    return out


def _paint_tri_stats(meshes):
    stats = {}
    for ob in meshes:
        me = ob.data
        if len(me.polygons) == 0:
            continue
        me.calc_loop_triangles()
        pmat = np.empty(len(me.polygons), dtype=np.int32)
        me.polygons.foreach_get("material_index", pmat)
        pidx = np.empty(len(me.loop_triangles), dtype=np.int32)
        me.loop_triangles.foreach_get("polygon_index", pidx)
        tmat = pmat[pidx]
        for mi, n in zip(*np.unique(tmat, return_counts=True)):
            mi = int(mi)
            m = me.materials[mi] if mi < len(me.materials) else None
            if m is None:
                continue
            st = stats.setdefault(m.name, {"mat": m, "tris": 0, "objs": []})
            st["tris"] += int(n)
            st["objs"].append(ob.name)
    return stats


def detect_paint_material():
    """返回命中的车漆材质 datablock 或 None；同时写 report['paint_fallback']"""
    body = _body_meshes_for_paint()
    if not body:
        return None
    stats = _paint_tri_stats(body)
    total = sum(v["tris"] for v in stats.values()) or 1
    # 已存在车漆材质则不用兜底
    for nm, st in stats.items():
        if PAINT_RE.search(nm):
            return None
    cands = []
    for nm, st in stats.items():
        m = st["mat"]
        if PAINT_NEG_RE.search(nm):
            continue
        bsdf = get_bsdf(m)
        if bsdf is None:
            continue
        if float(get_input(bsdf, "Emission Strength", 0.0) or 0.0) > 0.1:
            continue
        tr = 0.0
        try:
            tr = float(get_input(bsdf, "Transmission Weight", 0.0) or 0.0)
        except Exception:  # noqa: BLE001
            tr = 0.0
        if tr > 0.1:
            continue
        alpha = float(get_input(bsdf, "Alpha", 1.0) or 1.0)
        if alpha < 0.9:
            continue
        coeff = 0.0
        low = nm.lower()
        for rank, hint in enumerate(PAINT_POS_HINTS):
            if hint in low:
                coeff = 10.0 - rank
                break
        frac = st["tris"] / float(total)
        if frac < 0.03:
            continue
        cands.append({"name": nm, "mat": m, "tris": st["tris"], "frac": frac,
                      "hint": coeff, "objs": st["objs"]})
    if not cands:
        report["warnings"].append("车漆材质兜底：车身无合适候选")
        return None
    cands.sort(key=lambda c: (c["hint"], c["frac"]), reverse=True)
    best = cands[0]
    # 双色车漆（1-2 个最大候选都像车漆且面积接近）最多取 2 个
    picked = [best]
    for c in cands[1:]:
        if len(picked) >= 2:
            break
        if c["hint"] >= 8 and c["frac"] >= 0.08 and c["frac"] >= 0.25 * best["frac"]:
            picked.append(c)
    new_mats = []
    for c in picked:
        src = c["mat"]
        copy = src.copy()
        copy.name = "CARPAINT_" + sanitize(src.name, 48)
        # 只替换车身子树里的槽（内饰等共用该材质的对象不动）
        for ob in body:
            for si, m in enumerate(ob.data.materials):
                if m is src:
                    ob.data.materials[si] = copy
        new_mats.append(copy)
        report.setdefault("paint_fallback", []).append({
            "source": src.name,
            "new": copy.name,
            "tris": c["tris"],
            "frac": round(c["frac"], 3),
            "objs": sorted(set(c["objs"]))[:8],
        })
        print("[PAINT] %s -> %s (tris=%d frac=%.1f%% hint=%s)" % (
            src.name, copy.name, c["tris"], c["frac"] * 100.0, c["hint"]), flush=True)
    return new_mats[0] if new_mats else None


detect_paint_material()

used_mats = []
seen = set()
for ob in [o for o in bpy.data.objects if o.type == "MESH" and o.parent is not None]:
    for m in ob.data.materials:
        if m is not None and m.name not in seen:
            seen.add(m.name)
            used_mats.append(m)

n_glass = 0
n_opaque = 0
for mat in used_mats:
    bsdf = get_bsdf(mat)
    if bsdf is None:
        continue
    name = mat.name or ""
    is_glass = bool(GLASS_RE.search(name)) and not LAMP_RE.search(name)
    # 区分「车窗玻璃」和「有颜色的车灯罩/警示玻璃」：后者保持不透明并保留原色
    lens_tinted = False
    if is_glass:
        base_linked = "Base Color" in bsdf.inputs and bsdf.inputs["Base Color"].is_linked
        bc = get_input(bsdf, "Base Color", (1, 1, 1, 1))
        tr = float(get_input(bsdf, "Transmission Weight", 0.0) or 0.0)
        try:
            tinted = max(bc[0], bc[1], bc[2]) - min(bc[0], bc[1], bc[2]) > 0.15
        except Exception:  # noqa: BLE001
            tinted = False
        lens_tinted = (not base_linked) and tinted and tr < 0.5
    # 玻璃：Godot 不支持透射，用 alpha blend 近似车玻璃
    if is_glass and not lens_tinted:
        n_glass += 1
        unlink_input(bsdf, "Base Color")
        set_input(bsdf, "Base Color", (0.10, 0.115, 0.135, 1.0))
        set_input(bsdf, "Metallic", 0.0)
        set_input(bsdf, "Roughness", 0.03)
        set_input(bsdf, "IOR", 1.45)
        set_input(bsdf, "Alpha", 0.30)
        set_input(bsdf, "Transmission Weight", 0.0)
        try:
            mat.surface_render_method = "BLENDED"
        except Exception:  # noqa: BLE001
            pass
        try:
            mat.use_backface_culling = False
        except Exception:  # noqa: BLE001
            pass
    elif lens_tinted:
        n_opaque += 1
        unlink_input(bsdf, "Alpha")
        set_input(bsdf, "Alpha", 1.0)
        set_input(bsdf, "Transmission Weight", 0.0)
        set_input(bsdf, "Roughness", 0.05)
        try:
            mat.surface_render_method = "DITHERED"
        except Exception:  # noqa: BLE001
            pass
    else:
        n_opaque += 1
        unlink_input(bsdf, "Alpha")
        set_input(bsdf, "Alpha", 1.0)
        set_input(bsdf, "Transmission Weight", 0.0)
        try:
            mat.surface_render_method = "DITHERED"
        except Exception:  # noqa: BLE001
            pass
    report["materials"].append({
        "name": name,
        "glass": is_glass and not lens_tinted,
        "lens": lens_tinted,
        "paint": bool(PAINT_RE.search(name)),
        "metallic": round(float(get_input(bsdf, "Metallic", 0.0)), 3),
        "roughness": round(float(get_input(bsdf, "Roughness", 0.0)), 3),
        "coat": round(float(get_input(bsdf, "Coat Weight", 0.0)), 3),
        "emission_strength": round(float(get_input(bsdf, "Emission Strength", 0.0)), 3),
    })
report["n_glass_materials"] = n_glass
report["n_opaque_materials"] = n_opaque
print("[MAT] glass=%d opaque=%d total=%d" % (n_glass, n_opaque, len(used_mats)))

# ---------------------------------------------------------------------------
# 9. 导出 GLB
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
    filepath=OUT,
    export_format="GLB",
    use_selection=True,
    export_apply=True,
    export_yup=True,
    export_animations=False,
    export_cameras=False,
    export_lights=False,
    export_extras=False,
    export_materials="EXPORT",
    export_image_format="AUTO",
    export_normals=True,
    export_texcoords=True,
    export_skins=False,
    export_morph=False,
    export_attributes=False,
)
try:
    bpy.ops.export_scene.gltf(**kwargs)
except TypeError as e:
    print("[WARN] gltf kwargs not supported, retry minimal:", e)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True, export_animations=False,
                              export_cameras=False, export_lights=False)

size_mb = os.path.getsize(OUT) / 1048576.0
report["glb_mb"] = round(size_mb, 2)
report["export_seconds"] = round(time.time() - T0, 1)
tris = 0
for ob in root_empty.children_recursive:
    if ob.type == "MESH":
        me = ob.data
        me.calc_loop_triangles()
        tris += len(me.loop_triangles)
report["tris"] = tris
report["node_names"] = [sanitize(o.name) for o in root_empty.children_recursive if o.type in ("MESH", "EMPTY")]
save_report()
print("[DONE] %s  %.1fMB  tris=%d  %.1fs" % (OUT, size_mb, tris, time.time() - T0))
