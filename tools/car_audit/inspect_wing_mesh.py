#!/usr/bin/env python3
"""检查 GLB：每个 mesh-node 的 primitive 数、顶点 AABB、以及
「车尾上部区」(z 后 30% 且 y 上 45%) 内的三角占比 —— 定位焊死翼所在网格。
用法: python3 inspect_wing_mesh.py <glb路径> ..."""
import json, struct, sys, array

def read_glb(path):
    with open(path, 'rb') as f:
        magic, ver, length = struct.unpack('<III', f.read(12))
        assert magic == 0x46546C67
        jlen, jtype = struct.unpack('<II', f.read(8))
        data = json.loads(f.read(jlen))
        blen, btype = struct.unpack('<II', f.read(8))
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

def main(paths):
    for path in paths:
        data, blob = read_glb(path)
        print(f"=== {path.split('/')[-1]}")
        # 全车 bbox（含节点 transform 一级，简化：只看 mesh 自身，同一管线通常单位化）
        gmin = [1e9] * 3; gmax = [-1e9] * 3
        infos = []
        for n in data.get('nodes', []):
            if 'mesh' not in n:
                continue
            mesh = data['meshes'][n['mesh']]
            nmin = [1e9] * 3; nmax = [-1e9] * 3; ntri = 0
            for prim in mesh['primitives']:
                pos = read_acc(data, blob, prim['attributes']['POSITION'])
                for v in pos:
                    for k in range(3):
                        nmin[k] = min(nmin[k], v[k]); nmax[k] = max(nmax[k], v[k])
                if 'indices' in prim:
                    ntri += len(read_acc(data, blob, prim['indices'])) // 3
                else:
                    ntri += len(pos) // 3
            for k in range(3):
                gmin[k] = min(gmin[k], nmin[k]); gmax[k] = max(gmax[k], nmax[k])
            infos.append((n.get('name', '?'), nmin, nmax, ntri))
        print(f"  全车 bbox y[{gmin[1]:.3f},{gmax[1]:.3f}] z[{gmin[2]:.3f},{gmax[2]:.3f}] x[{gmin[0]:.3f},{gmax[0]:.3f}]")
        zlen = gmax[2] - gmin[2]; ylen = gmax[1] - gmin[1]
        z_cut = gmin[2] + zlen * 0.30   # 车尾 30%（车尾在 -z）
        y_cut = gmin[1] + ylen * 0.55
        for nm, nmin, nmax, ntri in infos:
            # 该 mesh 落在尾翼候选带的 tri 数（用 primitive 级统计）
            data2, blob2 = data, blob
            node = next(n for n in data['nodes'] if n.get('name') == nm)
            mesh = data['meshes'][node['mesh']]
            wing_tri = 0
            for prim in mesh['primitives']:
                pos = read_acc(data, blob, prim['attributes']['POSITION'])
                idxs = read_acc(data, blob, prim['indices']) if 'indices' in prim else list(range(len(pos)))
                for t in range(len(idxs) // 3):
                    vs = [pos[idxs[t * 3 + j]] for j in range(3)]
                    if all(v[2] < z_cut and v[1] > y_cut for v in vs):
                        wing_tri += 1
            mark = ' <<<' if wing_tri > 0 else ''
            print(f"  {nm:<44} prim={len(mesh['primitives'])} tri={ntri:<6} "
                  f"y[{nmin[1]:.2f},{nmax[1]:.2f}] z[{nmin[2]:.2f},{nmax[2]:.2f}] 尾上带tri={wing_tri}{mark}")

if __name__ == '__main__':
    main(sys.argv[1:])
