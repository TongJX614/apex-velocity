import json, struct, os, math, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
found = {}
for dp, dn, fn in os.walk(os.path.join(ROOT, 'assets')):
    for f in fn:
        if f.lower().endswith('.glb'):
            found[f.lower()[:-4]] = os.path.join(dp, f)

def mat_mul(a, b):
    out = [0.0] * 16
    for i in range(4):
        for j in range(4):
            s = 0.0
            for k in range(4):
                s += a[i * 4 + k] * b[k * 4 + j]
            out[i * 4 + j] = s
    return out

def trs_matrix(t, q, s):
    x, y, z, w = q
    n = math.sqrt(x*x + y*y + z*z + w*w) or 1.0
    x, y, z, w = x/n, y/n, z/n, w/n
    r = [1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w), 0.0,
         2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w), 0.0,
         2*(x*z-y*w), 2*(x*y+x*w), 1-2*(x*x+y*y), 0.0,
         0.0, 0.0, 0.0, 1.0]
    m = list(r)
    for i in range(3):
        for j in range(3):
            m[i*4+j] = r[i*4+j]*s[i]
    m[3], m[7], m[11] = t[0], t[1], t[2]
    return m

def bbox_of(path):
    with open(path, 'rb') as f:
        data = f.read()
    ln = struct.unpack_from('<I', data, 12)[0]
    js = json.loads(data[20:20+ln])
    accs = js.get('accessors', [])
    mins = [float('inf')]*3
    maxs = [float('-inf')]*3
    def walk(ni, parent):
        n = js['nodes'][ni]
        m = mat_mul(parent, trs_matrix(n.get('translation',[0,0,0]),
                                       n.get('rotation',[0,0,0,1]),
                                       n.get('scale',[1,1,1])))
        if 'mesh' in n:
            for pr in js['meshes'][n['mesh']].get('primitives', []):
                a = accs[pr['attributes']['POSITION']]
                if 'min' not in a: continue
                lo, hi = a['min'], a['max']
                for cx in (lo[0], hi[0]):
                    for cy in (lo[1], hi[1]):
                        for cz in (lo[2], hi[2]):
                            x = m[0]*cx + m[1]*cy + m[2]*cz + m[3]
                            y = m[4]*cx + m[5]*cy + m[6]*cz + m[7]
                            z = m[8]*cx + m[9]*cy + m[10]*cz + m[11]
                            mins[0]=min(mins[0],x); maxs[0]=max(maxs[0],x)
                            mins[1]=min(mins[1],y); maxs[1]=max(maxs[1],y)
                            mins[2]=min(mins[2],z); maxs[2]=max(maxs[2],z)
        for c in n.get('children', []):
            walk(c, m)
    ident = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    for r in js.get('scenes',[{}])[0].get('nodes',[0]):
        walk(r, ident)
    return mins, maxs, js

for name in sys.argv[1:]:
    p = found.get(name)
    if not p:
        print("%s NOT FOUND" % name); continue
    mins, maxs, js = bbox_of(p)
    print("=== %s ===" % name)
    print("  godot-space AABB min=%s max=%s size=(%.2f, %.2f, %.2f)"
          % ([round(v,2) for v in mins], [round(v,2) for v in maxs],
             maxs[0]-mins[0], maxs[1]-mins[1], maxs[2]-mins[2]))
    for i, n in enumerate(js.get('nodes', [])[:4]):
        t = n.get('translation', [0,0,0]); q = n.get('rotation', [0,0,0,1]); s = n.get('scale',[1,1,1])
        ang = 2*math.degrees(math.atan2(math.sqrt(q[0]**2+q[1]**2+q[2]**2), abs(q[3])))
        print("  node%d %-22s T=%s R=%s S=%s  rotAngle=%.1fdeg" %
              (i, n.get('name','?'), [round(v,3) for v in t], [round(v,4) for v in q],
               [round(v,4) for v in s], ang))
