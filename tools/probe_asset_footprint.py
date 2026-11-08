import json, struct, os, math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def mat_mul(a, b):
    """4x4 行主序矩阵相乘 a*b。"""
    out = [0.0] * 16
    for i in range(4):
        for j in range(4):
            s = 0.0
            for k in range(4):
                s += a[i * 4 + k] * b[k * 4 + j]
            out[i * 4 + j] = s
    return out


def trs_matrix(t, q, s):
    """由 TRS 构造 4x4 矩阵（glTF 约定：先缩放、再四元数旋转、最后平移）。"""
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    r = [
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0.0,
        2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0.0,
        2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0.0,
        0.0, 0.0, 0.0, 1.0,
    ]
    m = list(r)
    for i in range(3):
        for j in range(3):
            m[i * 4 + j] = r[i * 4 + j] * s[i]
    m[3] = t[0]
    m[7] = t[1]
    m[11] = t[2]
    return m


def transform_point(m, p):
    x, y, z = p
    return (
        m[0] * x + m[1] * y + m[2] * z + m[3],
        m[4] * x + m[5] * y + m[6] * z + m[7],
        m[8] * x + m[9] * y + m[10] * z + m[11],
    )


def scene_bbox(path):
    """完整应用节点层级变换（含旋转）后的世界空间 AABB —— 与 Godot 的
    RealAssetKit.size() 语义一致：rel * aabb。"""
    with open(path, 'rb') as f:
        data = f.read()
    ln = struct.unpack_from('<I', data, 12)[0]
    js = json.loads(data[20:20 + ln])
    nodes = js.get('nodes', [])
    accs = js.get('accessors', [])
    mins = [float('inf')] * 3
    maxs = [float('-inf')] * 3

    def walk(ni, parent):
        n = nodes[ni]
        m = mat_mul(parent, trs_matrix(
            n.get('translation', [0, 0, 0]),
            n.get('rotation', [0, 0, 0, 1]),
            n.get('scale', [1, 1, 1])))
        if 'mesh' in n:
            for pr in js['meshes'][n['mesh']].get('primitives', []):
                a = accs[pr['attributes']['POSITION']]
                if 'min' not in a:
                    continue
                lo, hi = a['min'], a['max']
                for cx in (lo[0], hi[0]):
                    for cy in (lo[1], hi[1]):
                        for cz in (lo[2], hi[2]):
                            wx, wy, wz = transform_point(m, (cx, cy, cz))
                            mins[0] = min(mins[0], wx); maxs[0] = max(maxs[0], wx)
                            mins[1] = min(mins[1], wy); maxs[1] = max(maxs[1], wy)
                            mins[2] = min(mins[2], wz); maxs[2] = max(maxs[2], wz)
        for c in n.get('children', []):
            walk(c, m)

    ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    for r in js.get('scenes', [{}])[0].get('nodes', [0]):
        walk(r, ident)
    return mins, maxs


found = {}
for dp, dn, fn in os.walk(os.path.join(ROOT, 'assets')):
    for f in fn:
        if f.lower().endswith('.glb'):
            found[f.lower()[:-4]] = os.path.join(dp, f)


def report(asset, target_h, road_clear, note=""):
    p = found.get(asset)
    if not p:
        print("  %-20s NOT FOUND" % asset)
        return
    mn, mx = scene_bbox(p)
    size = [mx[i] - mn[i] for i in range(3)]
    sc = target_h / max(size[1], 0.001)
    fx, fz = size[0] * sc, size[2] * sc
    ext = math.hypot(fx, fz) * 0.5
    flag = "  <<< 压路!" if ext > road_clear else ""
    print("  %-20s nat=(%7.2f,%7.2f,%7.2f) H=%6.1f sc=%6.2f 占地 %7.1fx%7.1f 外接半径 %6.1f 阈值 %4.1f%s %s"
          % (asset, size[0], size[1], size[2], target_h, sc, fx, fz, ext, road_clear, flag, note))


print("=== 霓虹都市 POOL_NEON (路距阈值 26m) ===")
for a, h in [('downtown_large', 78), ('downtown_medium', 44), ('downtown_small', 22)]:
    report(a, h * 1.25, 26.0)
print("=== 天际环城 POOL_SKYLINE (路距阈值 27m) ===")
for a, h in [('downtown_large', 92), ('downtown_medium', 52), ('downtown_small', 26), ('qt_block1_large', 46)]:
    report(a, h * 1.3, 27.0)
print("=== 天际环城住宅楼 qt_apt*/qt_block* (路距阈值 24m, 高度 14~34) ===")
for a in ['qt_apt2', 'qt_apt3', 'qt_apt4_a', 'qt_apt4_b', 'qt_apt6',
          'qt_block2_large', 'qt_block3', 'qt_block4']:
    report(a, 34, 24.0)
print("=== 地标塔 POOL_HERO (路距阈值 30m) ===")
for a, h in [('colony_tower', 176), ('station_tower', 152), ('blockchain_tower', 138),
             ('memefactory_tower', 124), ('lovedeath_tower', 118)]:
    report(a, h * 1.15, 30.0)
print("=== 其他 ===")
for a, h, c in [('factory_facade', 30, 24.0), ('industrial_pipes', 18, 22.0),
                ('qt_house1', 8, 16.0), ('qt_house2', 8, 16.0),
                ('light_tower', 22, 20.0), ('ship_real', 20, 20.0),
                ('pier_real', 12, 20.0), ('sea_marker_real', 8, 12.0),
                ('barrel_real', 2, 12.0), ('tyre_real', 1.5, 12.0),
                ('power_pole', 12, 15.0)]:
    report(a, h, c)
