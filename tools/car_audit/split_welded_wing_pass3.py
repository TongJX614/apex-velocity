#!/usr/bin/env python3
"""焊死翼手术第三遍：通用「岛 ID 白名单」搬移，节点名自动取下一个 Ducktail_NN。
（pass2 硬编码 Ducktail_02 且拒绝重复运行；本脚本可多次执行，每次新建下一个编号。）
用法: python3 split_welded_wing_pass3.py <glb> --dry|--apply
"""
import json, struct, sys, array, shutil, datetime

# car.glb -> [(node名, prim索引, [岛root索引...], 说明)]
ISLAND_MOVES = {
    'varis_m4_gts.glb': [
        # b_Kit4_Paint（宽体套件烤漆网格）里漏网的原厂翼残件：
        ('b_Kit4_Paint_Geo_lodA_Kit4_Paint_Geo_lodA_BMW_VarisM4GT_ce', 0,
         [2147, 2096, 2327, 2274], '原厂翼左右端板（x±0.86，y1.18-1.34，VOLTEX贴图）'),
        ('b_Kit4_Paint_Geo_lodA_Kit4_Paint_Geo_lodA_BMW_VarisM4GT_ce', 0,
         [1453, 1517, 1757, 1821], '翼座垫块（x±0.53-0.57，y1.02-1.05）'),
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
    apply_mode = '--apply' in sys.argv
    glb = sys.argv[1]
    car = glb.split('/')[-1]
    moves = ISLAND_MOVES.get(car)
    if not moves:
        print('no pass3 config for', car)
        return 1
    # 同一 (node,prim) 合并成一条：搬移后索引会移位，绝不能分两条先后算
    merged = {}
    for node_name, prim_idx, ids, desc in moves:
        key = (node_name, prim_idx)
        if key in merged:
            merged[key][1].extend(ids)
        else:
            merged[key] = [desc, list(ids)]
    data, blob = read_glb(glb)
    nodes = data['nodes']
    meshes = data['meshes']
    # 自动取下一个 Ducktail_NN
    nn = 1
    used = set()
    for n in nodes:
        nm = n.get('name', '')
        if nm.startswith('Ducktail_'):
            try:
                used.add(int(nm.split('_')[1]))
            except (IndexError, ValueError):
                pass
    while nn in used:
        nn += 1
    new_name = f'Ducktail_{nn:02d}'

    new_blob = bytearray()
    def add_idx_acc(idx_list, comp_type):
        fmt = {5125: ('I', 4), 5123: ('H', 2)}[comp_type]
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

    def attach_new_node(new_node_idx, src_name):
        for i, n in enumerate(nodes):
            for c in n.get('children', []):
                if nodes[c].get('name') == src_name:
                    n.setdefault('children', []).append(new_node_idx)
                    return
        data['scenes'][0].setdefault('nodes', []).append(new_node_idx)

    new_prims = []
    total = 0
    for (node_name, prim_idx), (desc, ids) in merged.items():
        src = next((n for n in nodes if n.get('name') == node_name), None)
        if src is None:
            print('!! 找不到节点', node_name)
            return 1
        mesh = meshes[src['mesh']]
        targets = set(ids)
        prim = mesh['primitives'][prim_idx]
        if 'indices' not in prim:
            continue
        pos = read_acc(data, blob, prim['attributes']['POSITION'])
        idxs = read_acc(data, blob, prim['indices'])
        ntri = len(idxs) // 3
        tris = [idxs[k * 3:(k + 1) * 3] for k in range(ntri)]
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
        move_set = set()
        for k in range(ntri):
            if find(k) in targets:
                move_set.add(k)
        if not move_set:
            print(f'!! {node_name} prim{prim_idx}: 白名单岛全部未命中（索引可能已变）')
            return 1
        xs = [pos[i][0] for k in move_set for i in tris[k]]
        ys = [pos[i][1] for k in move_set for i in tris[k]]
        zs = [pos[i][2] for k in move_set for i in tris[k]]
        print(f"  {node_name[:40]} prim{prim_idx}: 白名单{len(targets)}岛 -> move={len(move_set)} "
              f"AABB x[{min(xs):.2f},{max(xs):.2f}] y[{min(ys):.2f},{max(ys):.2f}] z[{min(zs):.2f},{max(zs):.2f}]  [{desc}]")
        keep, move = [], []
        for k, v in enumerate(tris):
            (move if k in move_set else keep).extend(v)
        comp_type = data['accessors'][prim['indices']]['componentType']
        prim['indices'] = add_idx_acc(keep, comp_type)
        new_prims.append({
            'attributes': prim['attributes'], 'indices': add_idx_acc(move, comp_type),
            'material': prim['material'], 'mode': 4,
        })
        total += len(move) // 3

    if not new_prims:
        print('没有命中任何岛')
        return 1
    print(f'合计 move={total} tri -> {new_name}')
    meshes.append({'primitives': new_prims})
    nodes.append({'name': new_name, 'mesh': len(meshes) - 1})
    attach_new_node(len(nodes) - 1, moves[0][0])

    if not apply_mode:
        print('[dry] 未写入。加 --apply 执行（先备份 .bak_weld3_日期）')
        return 0
    stamp = datetime.date.today().strftime('%Y-%m-%d')
    shutil.copy2(glb, glb + f'.bak_weld3_{stamp}')
    blob_all = blob + bytes(new_blob)
    data['buffers'][0]['byteLength'] = len(blob_all)
    json_bin = json.dumps(data, separators=(',', ':')).encode('utf-8')
    while len(json_bin) % 4:
        json_bin += b' '
    while len(blob_all) % 4:
        blob_all += b'\x00'
    total_len = 12 + 8 + len(json_bin) + 8 + len(blob_all)
    with open(glb, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, total_len))
        f.write(struct.pack('<II', len(json_bin), 0x4E4F534A))
        f.write(json_bin)
        f.write(struct.pack('<II', len(blob_all), 0x004E4942))
        f.write(blob_all)
    print(f'OK: {glb} 已写入（备份 .bak_weld3_{stamp}），total={total_len}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
