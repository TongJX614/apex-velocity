#!/usr/bin/env python3
"""bmw_m4_gt4.glb 尾翼拆分手术 v2（补漏：立柱脚 + Body_01 副本）

v1（split_m4_gt4_wing.py，从备份跑）把整组尾翼主体拆到了 Spoiler_01/Spoiler_02，
但按「所有顶点都在 y>1.15 且 z<-1.75」分类，漏掉了：
  · Body_05 prim0：立柱底部 76 tri（部分顶点 y<1.15，脚部扎到 y≈1.14）
  · Body_01 prim0：整份立柱+端板副本 42 tri（此前误判为前保险杠细节）
导致换装供体尾翼、Spoiler_01/02 被隐藏后，仍残留一对「无面立柱」。

v2 用「种子 + 区域生长」分类：
  · 种子 = 全部顶点都在 y>1.15 且 z<-1.75 的 tri（已证实纯尾翼）；
  · 在生长域（全部顶点 y>1.05 且 z<-1.70）内沿共享顶点边界生长；
  · 尾翼脚悬在行李箱盖网格（BOOT）上方、与 Body_05/Body_01 的其它几何不共享
    顶点，生长会自然停在尾翼几何边界，不会吃进车身。
生长出的 tri 从原 primitive 移除，追加为 Spoiler_02 mesh 的新 primitive
（属性 accessor 原样共享，材质沿用源面）。

用法: python3 split_m4_gt4_wing_v2.py <glb路径>
"""
import json, struct, sys, array

SEED = dict(y_min=1.15, z_max=-1.75)
GROW = dict(y_min=1.05, z_max=-1.70)
TARGETS = ['Body_05', 'Body_01']

def main(path):
    with open(path, 'rb') as f:
        magic, ver, length = struct.unpack('<III', f.read(12))
        assert magic == 0x46546C67, 'not glb'
        jlen, jtype = struct.unpack('<II', f.read(8))
        data = json.loads(f.read(jlen))
        blen, btype = struct.unpack('<II', f.read(8))
        blob = f.read(blen)

    nodes = data['nodes']; meshes = data['meshes']
    def node_by_name(nm):
        return next(n for n in nodes if n.get('name') == nm)

    def read_acc(idx):
        acc = data['accessors'][idx]
        bv = data['bufferViews'][acc['bufferView']]
        off = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
        comp = {'VEC3':3,'SCALAR':1,'VEC2':2,'VEC4':4}[acc['type']]
        fmt = {5126:('f',4),5125:('I',4),5123:('H',2)}[acc['componentType']]
        a = array.array(fmt[0])
        a.frombytes(blob[off:off+acc['count']*comp*fmt[1]])
        return a if comp == 1 else [tuple(a[i*comp:(i+1)*comp]) for i in range(acc['count'])]

    new_blob = bytearray()
    def add_idx_acc(idx_list, comp_type):
        fmt = {5125:('I',4),5123:('H',2)}[comp_type]
        a = array.array(fmt[0], idx_list)
        while (len(blob) + len(new_blob)) % fmt[1]:
            new_blob.append(0)
        data['bufferViews'].append({'buffer': 0, 'byteOffset': len(blob) + len(new_blob),
                                    'byteLength': len(a.tobytes())})
        new_blob.extend(a.tobytes())
        data['accessors'].append({'bufferView': len(data['bufferViews']) - 1,
                                  'componentType': comp_type, 'count': len(idx_list),
                                  'type': 'SCALAR'})
        return len(data['accessors']) - 1

    spoiler2_node = node_by_name('Spoiler_02')
    s2_mesh = meshes[spoiler2_node['mesh']]

    for target in TARGETS:
        n = node_by_name(target)
        prim = meshes[n['mesh']]['primitives'][0]
        pos = read_acc(prim['attributes']['POSITION'])
        idxs = read_acc(prim['indices'])
        ntri = len(idxs) // 3
        tris = [idxs[t*3:(t+1)*3] for t in range(ntri)]

        def in_box(v, box):
            return all(pos[i][1] > box['y_min'] and pos[i][2] < box['z_max'] for i in v)

        seeds = {ti for ti, v in enumerate(tris) if in_box(v, SEED)}
        print(f"{target}: seeds={len(seeds)} tris")
        # 区域生长：共享任一顶点即相邻
        vmap = {}
        for ti, v in enumerate(tris):
            for vi in v:
                vmap.setdefault(vi, []).append(ti)
        grow = set(seeds)
        frontier = list(seeds)
        while frontier:
            cur = frontier.pop()
            for nb in vmap[tris[cur][0]] + vmap[tris[cur][1]] + vmap[tris[cur][2]]:
                if nb in grow or not in_box(tris[nb], GROW):
                    continue
                grow.add(nb)
                frontier.append(nb)
        if len(grow) > 0.5 * ntri:
            print(f"  !! {target} 生长异常（{len(grow)}/{ntri}），中止不写入")
            return 1
        keep, move = [], []
        for ti, v in enumerate(tris):
            (move if ti in grow else keep).extend(v)
        print(f"  -> 生长结果 move={len(move)//3} tri, keep={len(keep)//3} tri")
        if not move:
            continue
        comp_type = data['accessors'][prim['indices']]['componentType']
        prim['indices'] = add_idx_acc(keep, comp_type)
        s2_mesh['primitives'].append({
            'attributes': prim['attributes'], 'indices': add_idx_acc(move, comp_type),
            'material': prim['material'], 'mode': 4,
        })

    blob_all = blob + bytes(new_blob)
    data['buffers'][0]['byteLength'] = len(blob_all)
    json_bin = json.dumps(data, separators=(',', ':')).encode('utf-8')
    while len(json_bin) % 4:
        json_bin += b' '
    while len(blob_all) % 4:
        blob_all += b'\x00'
    total = 12 + 8 + len(json_bin) + 8 + len(blob_all)
    with open(path, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, total))
        f.write(struct.pack('<II', len(json_bin), 0x4E4F534A))
        f.write(json_bin)
        f.write(struct.pack('<II', len(blob_all), 0x004E4942))
        f.write(blob_all)
    print(f"OK: {path} rewritten, total={total} (+{total-length} bytes)")

if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
