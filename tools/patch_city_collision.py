#!/usr/bin/env python3
"""都会环线碰撞补面：把 GLB 里「有落地墙体、但没进 SDF」的建筑轮廓并进 city_collision.bin。

做法：解析 city_ring.glb，栅格化屋顶 + 落地墙三角形（排除植被/线缆），
找出与现有 SDF 零区不相交、又有落地墙证据的连通块，用欧氏距离变换
生成新的距离场，与原 SDF 取 min 后写回。paved 位图保持不变。

用法：
  python3 tools/patch_city_collision.py --dry-run
  python3 tools/patch_city_collision.py            # 改写 .bin
  Godot --headless --path . res://tools/bake_city_collision.tscn   # 重烘 .res
"""
import argparse
import json
import shutil
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
GLB = ROOT / "maps/assets/city_ring/city_ring.glb"
BIN = ROOT / "maps/assets/city_ring/city_collision.bin"

VEG = {
    "C_001_027_002", "C_009_029_001", "C_006_022_010", "C_005_011_007",
    "C_026_016_009", "C_000_000_000", "C_000_000_000.001",
}
MIN_CELLS = 12          # 小于这个面积的块多半是装饰物
MIN_GROUND_TRIS = 3     # 至少这么多落地墙三角形才算「真楼」
MIN_TRACK_DIST = 12.0   # 轮廓离都会环线中心线小于这个距离就跳过（不能堵赛道）
SDF_SCALE = 0.1

CT = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_acc(blob, accs, bvs, ai):
    a = accs[ai]
    bv = bvs[a["bufferView"]]
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    nc = NC[a["type"]]
    dt = np.dtype(CT[a["componentType"]])
    stride = bv.get("byteStride", 0) or nc * dt.itemsize
    if stride == nc * dt.itemsize:
        return np.frombuffer(blob, dtype=dt, count=a["count"] * nc,
                             offset=base).reshape(a["count"], nc)
    out = np.empty((a["count"], nc), dtype=dt)
    for i in range(a["count"]):
        out[i] = np.frombuffer(blob, dtype=dt, count=nc, offset=base + i * stride)
    return out


def node_matrix(n):
    t = np.array(n.get("translation", [0, 0, 0]), float)
    q = np.array(n.get("rotation", [0, 0, 0, 1]), float)
    s = np.array(n.get("scale", [1, 1, 1]), float)
    x, y, z, w = q / (np.linalg.norm(q) or 1)
    r = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])
    m = np.eye(4)
    m[:3, :3] = r * s
    m[:3, 3] = t
    return m


def load_glb_masks(n, span, step):
    data = GLB.read_bytes()
    jlen = struct.unpack_from("<I", data, 12)[0]
    js = json.loads(data[20:20 + jlen])
    blob = data[12 + 8 + jlen + 8:]
    accs, bvs = js["accessors"], js["bufferViews"]
    mats = [m.get("name", "?") for m in js["materials"]]
    nodes = js["nodes"]

    roof = Image.new("1", (n, n), 0)
    wall = Image.new("1", (n, n), 0)
    dr, dw = ImageDraw.Draw(roof), ImageDraw.Draw(wall)
    to_px = lambda p: ((p[0] + span) / step, (-p[2] + span) / step)

    for ni in js["scenes"][0]["nodes"]:
        nd = nodes[ni]
        if "mesh" not in nd:
            continue
        m = node_matrix(nd)
        for pr in js["meshes"][nd["mesh"]]["primitives"]:
            if "POSITION" not in pr.get("attributes", {}):
                continue
            mi = pr.get("material", -1)
            name = mats[mi] if mi >= 0 else "NONE"
            if name in VEG:
                continue
            pos = read_acc(blob, accs, bvs, pr["attributes"]["POSITION"]).astype(float)
            pos = pos @ m[:3, :3].T + m[:3, 3]
            if "indices" in pr:
                idx = read_acc(blob, accs, bvs, pr["indices"]).astype(np.int64).ravel()
            else:
                idx = np.arange(len(pos))
            idx = idx[:len(idx) // 3 * 3].reshape(-1, 3)
            v0, v1, v2 = pos[idx[:, 0]], pos[idx[:, 1]], pos[idx[:, 2]]
            nrm = np.cross(v1 - v0, v2 - v0)
            ln = np.linalg.norm(nrm, axis=1)
            ln[ln == 0] = 1
            ny = np.abs(nrm[:, 1]) / ln
            maxy = np.maximum(np.maximum(v0[:, 1], v1[:, 1]), v2[:, 1])
            miny = np.minimum(np.minimum(v0[:, 1], v1[:, 1]), v2[:, 1])
            roof_sel = (ny > 0.55) & (maxy > 2.5) & (miny > 1.2)
            wall_sel = (ny < 0.55) & (maxy > 3.0) & (miny < 2.0)
            for sel, draw in ((roof_sel, dr), (wall_sel, dw)):
                for j in np.where(sel)[0]:
                    p = pos[idx[j]]
                    draw.polygon([to_px(p[0]), to_px(p[1]), to_px(p[2])], fill=1)
    return np.array(roof, bool), np.array(wall, bool)


def read_sdf(blob, n):
    return np.frombuffer(blob[32:32 + n * n], np.uint8).reshape(n, n)


def metro_polyline():
    defs = json.loads((ROOT / "data/tracks.json").read_text())
    tracks = defs.get("tracks", defs)
    metro = next((t for t in tracks if str(t.get("id")) == "metro"), None)
    if metro is None:
        raise SystemExit("data/tracks.json 里找不到 metro")
    pts = np.array([[float(p[0]), float(p[1])] for p in metro["points"]], float)
    a, b = pts, np.roll(pts, -1, axis=0)
    lens = np.linalg.norm(b - a, axis=1)
    acc = np.concatenate(([0.0], np.cumsum(lens)))
    dense = []
    for d in np.arange(0.0, acc[-1], 1.0):
        i = min(int(np.searchsorted(acc, d, side="right")) - 1, len(a) - 1)
        f = (d - acc[i]) / max(lens[i], 1e-6)
        dense.append(a[i] + (b[i] - a[i]) * f)
    return np.array(dense)


def comp_track_dist(comp, span, step, track_pts):
    ys, xs = np.where(comp)
    x = -span + (xs + 0.5) * step
    z = span - (ys + 0.5) * step
    p = np.stack([x, z], 1)
    best = 1e9
    for c0 in range(0, len(p), 512):
        chunk = p[c0:c0 + 512]
        d = np.sqrt(((chunk[:, None, :] - track_pts[None, :, :]) ** 2).sum(-1)).min()
        best = min(best, float(d))
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    blob = bytearray(BIN.read_bytes())
    n = struct.unpack_from("<I", blob, 12)[0]
    span = struct.unpack_from("<f", blob, 16)[0]
    step = struct.unpack_from("<f", blob, 20)[0]
    old = read_sdf(blob, n)
    old_m = old.astype(np.float32) * SDF_SCALE
    track_pts = metro_polyline()

    roof, wall = load_glb_masks(n, span, step)
    roof = ndimage.binary_closing(roof, structure=np.ones((3, 3)))
    zero_d = ndimage.binary_dilation(old == 0, iterations=1)
    missing = roof & ~zero_d
    labels, count = ndimage.label(missing)
    sizes = np.bincount(labels.ravel())

    chosen = np.zeros_like(roof)
    rows = []
    for i in range(1, count + 1):
        if sizes[i] < MIN_CELLS:
            continue
        comp = labels == i
        near = ndimage.binary_dilation(comp, iterations=3)
        ground = int((wall & near).sum())
        if ground < MIN_GROUND_TRIS:
            continue
        tdist = comp_track_dist(comp, span, step, track_pts)
        if tdist < MIN_TRACK_DIST:
            print(f"  跳过 {int(sizes[i])} 格 @ 距赛道 {tdist:.1f}m（会堵路）")
            continue
        chosen |= comp
        ys, xs = np.where(comp)
        cx = -span + (xs.mean() + 0.5) * step
        cz = span - (ys.mean() + 0.5) * step
        rows.append((int(sizes[i]), ground, tdist, cx, cz))

    rows.sort(reverse=True)
    print(f"SDF n={n} span={span} step={step:.6f} 选中 {len(rows)} 块，共 {int(chosen.sum())} 格")
    for cells, ground, tdist, cx, cz in rows:
        print(f"  {cells:6d} 格  落地墙={ground:4d}  距赛道={tdist:6.1f}m  @ ({cx:.1f}, {cz:.1f})")

    if not chosen.any():
        print("没有需要补的楼，退出")
        return

    # 补面距离场：到最近选中轮廓像素的欧氏距离（米）
    edt_px = ndimage.distance_transform_edt(~chosen)
    edt_m = (edt_px * step).astype(np.float32)
    new_m = np.minimum(old_m, edt_m)

    changed = new_m < old_m - 1e-4
    print(f"新增碰撞像素 {int(changed.sum())}")

    if args.dry_run:
        out = np.clip(np.rint(new_m / SDF_SCALE), 0, 255).astype(np.uint8)
        print("dry-run：未写入。示例变化：",
              np.unique(np.stack([old[changed], out[changed]], 1), axis=0)[:10])
        return

    backup = Path("/private/tmp/city_collision_orig.bin")
    if not backup.exists():
        shutil.copy2(BIN, backup)
        print(f"原文件已备份到 {backup}")
    new_u8 = np.clip(np.rint(new_m / SDF_SCALE), 0, 255).astype(np.uint8)
    blob[32:32 + n * n] = new_u8.tobytes()
    BIN.write_bytes(bytes(blob))
    print(f"已写入 {BIN}；下一步重烘 city_collision.res")


if __name__ == "__main__":
    main()
