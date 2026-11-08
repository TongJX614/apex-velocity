# -*- coding: utf-8 -*-
"""inspect_blend.py —— 只读诊断：打开拆分版 .blend，打印车辆根/轮组结构、
每个车轮碎片的几何统计与材质名，供改进导出器分类算法用。

用法：
  blender -b --factory-startup --python inspect_blend.py -- <in.blend> [<out.json>]
"""
import bpy
import sys
import os
import json
import math
import re

import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
if not argv:
    print("[FATAL] usage: -- <in.blend> [<out.json>]")
    raise SystemExit(2)
SRC = argv[0]
OUT = argv[1] if len(argv) > 1 else None

STUDIO_HINTS = ("cyclorama", "floor", "cove", "backdrop", "studio", "shadow",
                "texture_plane", "地面")

bpy.ops.wm.open_mainfile(filepath=SRC)
bpy.context.view_layer.update()
try:
    bpy.ops.object.mode_set(mode="OBJECT")
except Exception:
    pass

info = {"src": SRC, "objects": {}, "wheels": {}, "body": {}, "empties": []}


def is_studio(ob):
    low = (ob.name or "").lower()
    return any(h in low for h in STUDIO_HINTS)


root = bpy.data.objects.get("车辆根节点")
if root is None:
    cand = [o for o in bpy.data.objects if o.type == "EMPTY" and
            len([c for c in o.children_recursive if c.type == "MESH"]) > 4]
    if cand:
        root = max(cand, key=lambda o: len([c for c in o.children_recursive if c.type == "MESH"]))
info["root"] = root.name if root else None
if root is None:
    print("[FATAL] no root")
    raise SystemExit(1)


def tris_of(ob):
    me = ob.data
    me.calc_loop_triangles()
    return len(me.loop_triangles)


def mat_names(ob):
    return [m.name if m else None for m in ob.data.materials]


def world_verts(ob):
    n = len(ob.data.vertices)
    arr = np.empty(n * 3, dtype=np.float64)
    ob.data.vertices.foreach_get("co", arr)
    a = arr.reshape(n, 3)
    M = np.array(ob.matrix_world)
    return a @ M[:3, :3].T + M[:3, 3]


def stats(ob, C=None):
    a = world_verts(ob)
    if len(a) == 0:
        return {"v": 0, "tris": 0}
    if C is None:
        C = a.mean(axis=0)
    C = np.asarray(C, dtype=np.float64)
    rel = a - C
    rad = np.sqrt(rel[:, 0] ** 2 + rel[:, 2] ** 2)  # 轮轴大致沿 X 时，径向在 YZ? 这里取 XZ
    # 轮轴未知：给出到中心的三维距离分位数
    d = np.linalg.norm(rel, axis=1)
    return {
        "v": int(len(a)),
        "tris": tris_of(ob),
        "center_w": [round(float(v), 4) for v in ((a.min(0) + a.max(0)) * 0.5)],
        "bbox_min": [round(float(v), 4) for v in a.min(0)],
        "bbox_max": [round(float(v), 4) for v in a.max(0)],
        "bbox_size": [round(float(v), 4) for v in (a.max(0) - a.min(0))],
        "d_min": round(float(np.percentile(d, 0)), 4),
        "d_max": round(float(d.max()), 4),
        "d_med": round(float(np.median(d)), 4),
        "mats": [m for m in mat_names(ob) if m],
        "parent": ob.parent.name if ob.parent else None,
        "parent_type": ob.parent.type if ob.parent else None,
    }


# 全车对象清单（浅层）
for ob in bpy.data.objects:
    if ob.type == "MESH":
        mw = ob.matrix_world
        info["objects"][ob.name] = {
            "v": len(ob.data.vertices),
            "tris": tris_of(ob),
            "mats": [m for m in mat_names(ob) if m],
            "parent": ob.parent.name if ob.parent else None,
            "parent_type": ob.parent.type if ob.parent else None,
            "loc": [round(float(v), 3) for v in mw.translation],
            "scale": [round(float(v), 3) for v in mw.to_scale()],
        }
    elif ob.type == "EMPTY":
        info["empties"].append({"name": ob.name, "parent": ob.parent.name if ob.parent else None,
                                "loc": [round(float(v), 4) for v in ob.matrix_world.translation],
                                "children": [c.name for c in ob.children]})

# 轮组
pivots = {}
for k in ("FL", "FR", "RL", "RR"):
    steer = bpy.data.objects.get("STEER_" + k)
    wheel = bpy.data.objects.get("WHEEL_" + k)
    pivots[k] = {"steer": steer, "wheel": wheel,
                 "C": (wheel or steer).matrix_world.translation.copy() if (wheel or steer) else None}
info["pivots"] = {k: ([round(float(v), 4) for v in v["C"]] if v["C"] else None) for k, v in pivots.items()}

for k, pv in pivots.items():
    if pv["C"] is None:
        continue
    C = np.array(pv["C"])
    meshes = []
    for w in (pv["wheel"], pv["steer"]):
        if w is not None:
            for ob in w.children_recursive:
                if ob.type == "MESH" and not is_studio(ob):
                    meshes.append(ob)
    # 去重
    seen = set()
    uniq = []
    for ob in meshes:
        if ob.name not in seen:
            seen.add(ob.name)
            uniq.append(ob)
    entries = []
    for ob in uniq:
        s = stats(ob, C)
        entries.append(s)
    spin_pool = np.concatenate([world_verts(o) for o in uniq if len(o.data.vertices)]) if uniq else np.zeros((0, 3))
    # 径向最大值（绕 X 轴）
    if len(spin_pool):
        rel = spin_pool - C
        rmax = float(np.sqrt(rel[:, 1] ** 2 + rel[:, 2] ** 2).max())
        xmin, xmax = float(rel[:, 0].min()), float(rel[:, 0].max())
    else:
        rmax = 0.0
        xmin = xmax = 0.0
    info["wheels"][k] = {
        "C": [round(float(v), 4) for v in C],
        "mesh_count": len(uniq),
        "tris": sum(e["tris"] for e in entries),
        "rmax": round(rmax, 4),
        "x_extent": [round(xmin, 4), round(xmax, 4)],
        "frags": entries,
    }

# 车身
body = [o for o in root.children_recursive if o.type == "MESH" and not is_studio(o)
        and not any(o.name in [x.name for x in (pivots[k]["wheel"].children_recursive
                                                if pivots[k]["wheel"] else [])] for k in pivots)]
info["body"] = {
    "mesh_count": len(body),
    "tris": sum(tris_of(o) for o in body),
    "mats": sorted({m for o in body for m in mat_names(o) if m}),
}
info["total_mesh_tris"] = sum(tris_of(o) for o in bpy.data.objects if o.type == "MESH")
info["total_obj_meshes"] = len([o for o in bpy.data.objects if o.type == "MESH"])
info["families"] = sorted({(o.get("family") if hasattr(o, "get") else None) for o in []})

print("[INSPECT]", SRC)
print(json.dumps({k: v for k, v in info.items() if k != "objects"}, ensure_ascii=False, indent=1)[:12000])
if OUT:
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    print("[WROTE]", OUT)
