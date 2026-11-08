#!/usr/bin/env python3
"""打印 mesh 在车尾区的 (z,y) 三角质心占位热图，定位焊死翼的孤立团块。
用法: python3 wing_heatmap.py <glb> <node名> [y分位下限=0.45]
行 = y 从高到低分 12 档，列 = z 从车尾(-)到车头分 20 档，数字 = 三角数（相对）。
"""
import json, struct, sys, array

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
    path, node_name = sys.argv[1], sys.argv[2]
    y_frac = float(sys.argv[3]) if len(sys.argv) > 3 else 0.45
    data, blob = read_glb(path)
    node = next(n for n in data['nodes'] if n.get('name') == node_name)
    mesh = data['meshes'][node['mesh']]
    allv = []
    for prim in mesh['primitives']:
        pos = read_acc(data, blob, prim['attributes']['POSITION'])
        idxs = read_acc(data, blob, prim['indices']) if 'indices' in prim else list(range(len(pos)))
        for t in range(len(idxs) // 3):
            vs = [pos[idxs[t * 3 + j]] for j in range(3)]
            cz = sum(v[2] for v in vs) / 3
            cy = sum(v[1] for v in vs) / 3
            allv.append((cz, cy))
    zmin = min(v[0] for v in allv); zmax = max(v[0] for v in allv)
    ymin = min(v[1] for v in allv); ymax = max(v[1] for v in allv)
    z0 = zmin; z1 = zmin + (zmax - zmin) * 0.45   # 只看车尾 45%（车尾在 -z）
    y0 = ymin + (ymax - ymin) * y_frac
    NZ, NY = 24, 14
    grid = [[0] * NZ for _ in range(NY)]
    for cz, cy in allv:
        if cz < z0 or cz > z1 or cy < y0:
            continue
        ci = min(NZ - 1, int((cz - z0) / (z1 - z0) * NZ))
        ri = min(NY - 1, int((cy - y0) / (ymax - y0) * NY))
        grid[NY - 1 - ri][ci] += 1   # 行 0 = 最高
    print(f"=== {path.split('/')[-1]} / {node_name}")
    print(f"    z: {z0:.2f}(车尾) -> {z1:.2f}   y: {y0:.2f} -> {ymax:.2f}")
    for r, row in enumerate(grid):
        y_hi = ymax - (ymax - y0) * r / NY
        y_lo = ymax - (ymax - y0) * (r + 1) / NY
        cells = ''.join(('  .' if c == 0 else '%3d' % min(c, 999)) for c in row)
        print(f" y[{y_lo:.2f}-{y_hi:.2f}]{cells}")

if __name__ == '__main__':
    main()
