#!/usr/bin/env python3
"""连通岛分析：把目标网格按顶点连通性分成岛，列出与翼盒相交的岛
（tri 数 + AABB），用于决定哪些岛整岛搬走。
用法: python3 wing_islands.py <glb>   （按内置 CONFIGS 分析）
"""
import json, struct, sys, array

BOXES = {
    # car -> [ (node, y_min, z_max, 说明) ]  车尾在 -z
    'bmw_m4_gt3.glb': [
        ('Body_06', 0.97, -1.87, '翼面+端板+支柱盒'),
        ('Body_05', 0.97, -1.87, '副本盒'),
        ('Badge_Geo_lodA', 0.97, -1.87, '徽标盒'),
    ],
    'bmw_m6_gt3.glb': [
        ('Body_02', 0.94, -1.94, '翼面盒'),
        ('Body_06', 0.94, -1.94, '支柱盒'),
    ],
    'varis_m4_gts.glb': [
        ('Body_06', 1.02, -1.89, '翼面盒'),
        ('Body_07', 1.02, -1.89, '副本盒'),
    ],
    'pandem_m3_e92.glb': [
        ('Body_04', 0.93, -1.83, '中央鸭尾盒'),
        ('br_Carbon1_Geo_lodA_Carbon1_Geo_lodA_BMW_RBM3E92RewardR_f0', 1.00, -1.63, '碳翼盒'),
        ('br_Paint_Geo_lodA_Paint_Geo_lodA_BMW_RBM3E92RewardRecyc_66', 0.90, -1.93, '端板盒'),
    ],
    'byd_yangwang_u9.glb': [
        ('SM_RearKit_0000.001', 1.07, -1.93, '翼面+支柱盒'),
    ],
}


def read_glb(path):
    with open(path, 'rb') as f:
        struct.unpack('<III', f.read(12))
        jlen, _ = struct.unpack('<II', f.read(8))
        data = json.loads(f.read(jlen))
        blen, _ = struct.unpack('<II', f.read(8))
        blob = f.read(blen)
    return data, blob


def read_acc(data, blob, idx):
    acc = data['accessors'][idx]
    bv = data['bufferViews'][acc['bufferView']]
    off = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
    comp = {'VEC3': 3, 'SCALAR': 1, 'VEC2': 2, 'VEC4': 4}[acc['type']]
    fmt = {5126: ('f', 4), 5125: ('I', 4), 5123: ('H', 2)}[acc['componentType']]
    a = array.array(fmt[0])
    a.frombytes(blob[off:off + acc['count'] * comp * fmt[1]])
    return a if comp == 1 else [tuple(a[i * comp:(i + 1) * comp]) for i in range(acc['count'])]


def main():
    path = sys.argv[1]
    car = path.split('/')[-1]
    data, blob = read_glb(path)
    nodes = data['nodes']
    for node_name, y_min, z_max, desc in BOXES.get(car, []):
        src = next((n for n in nodes if n.get('name') == node_name), None)
        if src is None:
            print(f'{node_name}: 不存在')
            continue
        mesh = data['meshes'][src['mesh']]
        for pi, prim in enumerate(mesh['primitives']):
            if 'indices' not in prim:
                continue
            pos = read_acc(data, blob, prim['attributes']['POSITION'])
            idxs = read_acc(data, blob, prim['indices'])
            ntri = len(idxs) // 3
            tris = [idxs[k * 3:(k + 1) * 3] for k in range(ntri)]
            # 并查集分岛
            parent = list(range(ntri))
            def find(x):
                while parent[x] != x:
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                return x
            vmap = {}
            for k, v in enumerate(tris):
                for vi in v:
                    vmap.setdefault(vi, []).append(k)
            for lst in vmap.values():
                a0 = find(lst[0])
                for k in lst[1:]:
                    b0 = find(k)
                    if a0 != b0:
                        parent[b0] = a0
            islands = {}
            for k in range(ntri):
                islands.setdefault(find(k), []).append(k)
            print(f'=== {car} / {node_name} prim{pi}: {len(islands)} 岛 / {ntri} tri  [{desc}]')
            for root, ks in sorted(islands.items(), key=lambda kv: -len(kv[1])):
                xs = [pos[i][0] for k in ks for i in tris[k]]
                ys = [pos[i][1] for k in ks for i in tris[k]]
                zs = [pos[i][2] for k in ks for i in tris[k]]
                x0, x1 = min(xs), max(xs); y0, y1 = min(ys), max(ys); z0, z1 = min(zs), max(zs)
                # 与翼盒相交：AABB 有顶点在盒内 或 盒与AABB相交
                inter = not (y1 <= y_min or z0 >= z_max)
                if not inter:
                    continue
                fully = y0 > y_min and z1 < z_max
                tag = '✓整岛在盒内' if fully else '（部分在盒内）'
                print(f'   岛{root}: tri={len(ks):<6} x[{x0:.2f},{x1:.2f}] y[{y0:.2f},{y1:.2f}] z[{z0:.2f},{z1:.2f}] {tag}')


if __name__ == '__main__':
    main()
