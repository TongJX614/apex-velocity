#!/usr/bin/env python3
"""读 GLB 的 POSITION accessor min/max + 节点变换，算世界包围盒。"""
import json, struct, sys, os

def read_glb(path):
    with open(path, 'rb') as f:
        data = f.read()
    magic, ver, length = struct.unpack('<III', data[:12])
    off = 12
    js = None
    while off < length:
        clen, ctype = struct.unpack('<II', data[off:off+8])
        chunk = data[off+8:off+8+clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode('utf-8'))
        off += 8 + clen + ((4 - clen % 4) % 4 if clen % 4 else 0)
    return js

def mat_mul(a, b):
    # 4x4 row-major
    return [sum(a[r*4+k]*b[k*4+c] for k in range(4)) for r in range(4) for c in range(4)]

def node_matrix(n):
    if 'matrix' in n:
        m = n['matrix']  # glTF column-major
        return [m[0],m[4],m[8],m[12], m[1],m[5],m[9],m[13], m[2],m[6],m[10],m[14], m[3],m[7],m[11],m[15]]
    t = n.get('translation', [0,0,0])
    r = n.get('rotation', [0,0,0,1])
    s = n.get('scale', [1,1,1])
    x,y,z,w = r
    R = [1-2*(y*y+z*z), 2*(x*y-z*w),   2*(x*z+y*w),   0,
         2*(x*y+z*w),   1-2*(x*x+z*z), 2*(y*z-x*w),   0,
         2*(x*z-y*w),   2*(y*z+x*w),   1-2*(x*x+y*y), 0,
         0,0,0,1]
    for c in range(3):
        for r2 in range(3):
            R[r2*4+c] *= s[c]
    R[3], R[7], R[11] = t[0], t[1], t[2]
    return R

def xform(m, p):
    return [m[0]*p[0]+m[1]*p[1]+m[2]*p[2]+m[3],
            m[4]*p[0]+m[5]*p[1]+m[6]*p[2]+m[7],
            m[8]*p[0]+m[9]*p[1]+m[10]*p[2]+m[11]]

def main(path):
    js = read_glb(path)
    meshes = js.get('meshes', [])
    nodes = js.get('nodes', [])
    accs = js.get('accessors', [])
    mn = [1e9]*3; mx = [-1e9]*3
    count = 0
    def walk(idx, parent):
        nonlocal mn, mx, count
        n = nodes[idx]
        m = mat_mul(parent, node_matrix(n))
        if 'mesh' in n:
            for prim in meshes[n['mesh']].get('primitives', []):
                ai = prim['attributes'].get('POSITION')
                if ai is None: continue
                a = accs[ai]
                if 'min' not in a: continue
                lo, hi = a['min'], a['max']
                for cx in (lo[0], hi[0]):
                    for cy in (lo[1], hi[1]):
                        for cz in (lo[2], hi[2]):
                            w = xform(m, [cx, cy, cz])
                            for i in range(3):
                                mn[i] = min(mn[i], w[i]); mx[i] = max(mx[i], w[i])
                count += 1
        for c in n.get('children', []):
            walk(c, m)
    scene = js['scenes'][js.get('scene', 0)]
    for root in scene['nodes']:
        walk(root, [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
    size = [mx[i]-mn[i] for i in range(3)]
    print(f"{os.path.basename(path):28s} prims={count:3d}  size=({size[0]:7.3f}, {size[1]:7.3f}, {size[2]:7.3f})  min_y={mn[1]:7.3f}")

if __name__ == '__main__':
    for p in sys.argv[1:]:
        main(p)
