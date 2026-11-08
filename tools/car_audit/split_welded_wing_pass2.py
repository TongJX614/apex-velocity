#!/usr/bin/env python3
"""焊死翼手术第二遍：按「连通岛 ID 白名单」搬残留件（立柱/端板/翼尖）。
岛 ID 来自 wing_islands.py 在手术后文件上的分析结果，逐个核对过 AABB，
只搬几何上明确属于翼的岛；歧义岛（盖板高度条带等）一律不动。
新节点自动命名 Ducktail_02（Ducktail_01 已被第一遍占用）。
用法: python3 split_welded_wing_pass2.py <glb> --dry|--apply
"""
import json, struct, sys, array, shutil, datetime

# car.glb -> [(node名, prim索引, [岛root索引...], 说明)]
# 岛 root = wing_islands.py 输出的「岛N」的 N（并查集根 = 该岛最小 tri 索引）。
# 注意：岛 ID 只在 (node, prim) 内唯一，必须带 prim 索引，否则会误搬其它 primitive。
ISLAND_MOVES = {
    'bmw_m4_gt3.glb': [
        ('Body_06', 0, [23706, 23961, 23758, 24013, 23821, 24076, 23890, 24113,
                        23880, 24167, 23858, 24145, 23875, 24162, 23918, 24141,
                        23921, 24144], '两根天鹅颈立柱（x±0.55，UV缝碎岛）'),
    ],
    'varis_m4_gts.glb': [
        ('Body_06', 0, [358, 393, 331, 345, 428], '翼面后缘延伸（y1.27-1.31）'),
        ('Body_07', 0, [3038, 3313, 2614, 2680, 2746, 2812, 2878, 2990, 3217, 3265,
                        2944, 3171, 2973, 3200, 2915, 3027, 3254, 3302, 2962, 3189,
                        2674, 2740, 2806, 2872, 3139, 3414, 2943, 2961, 3170, 3188],
         '翼支柱+翼面碎岛（x±0.55-0.61，y≥1.0）'),
    ],
    'pandem_m3_e92.glb': [
        ('Body_04', 0, [9751, 9986], '鸭尾中央支撑（x±0.15，y0.87-1.13）'),
        ('br_Paint_Geo_lodA_Paint_Geo_lodA_BMW_RBM3E92RewardRecyc_66', 0,
         [9581, 8637, 8665, 9599, 8609, 9517, 9525, 9068, 9604, 9561, 9587,
          9591, 9603, 9605], '端板残留（x±0.85，y0.98-1.17）'),
    ],
    'byd_yangwang_u9.glb': [
        # 同一 (node,prim) 只允许一条配置：搬移后索引会移位，分两条会让第二条白名单失效
        ('SM_RearKit_0000.001', 1, [5010, 5181, 9718, 9842,
                                    12882, 12919, 1038, 1060, 1027, 1028, 1029, 1030,
                                    1031, 1032, 1033, 1034, 1035, 1036, 1037, 1046, 1047,
                                    1048, 1049, 1050, 1051, 1052, 1053, 1054, 1055, 1056,
                                    1057, 1058, 1059, 1068, 1069, 1070, 1074],
         '翼支柱（x±0.43-0.50）+ 翼尖残留（x±0.97-1.00）'),
    ],
    # m6_gt3：盖板高度条带与支柱脚在 y0.94-1.01 无法与尾门边缘区分，本遍不动，留目检裁决
}


def read_glb(path):
    with open(path, 'rb') as f:
        struct.unpack('<III', f.read(12))
        jlen, _ = struct.unpack('<II', f.read(8))
        data = json.loads(f.read(jlen))
        blen, _ = struct.unpack('<II', f.read(8))
        blob = f.read(blen)
    return data, blob, None


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
        print('no pass2 config for', car)
        return 1
    data, blob, _ = read_glb(glb)
    nodes = data['nodes']
    meshes = data['meshes']
    if any(n.get('name', '').startswith('Ducktail_02') for n in nodes):
        print('!! 已存在 Ducktail_02，疑似已做过第二遍，中止')
        return 1

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
    for node_name, prim_idx, island_ids, desc in moves:
        src = next((n for n in nodes if n.get('name') == node_name), None)
        if src is None:
            print('!! 找不到节点', node_name)
            return 1
        mesh = meshes[src['mesh']]
        targets = set(island_ids)
        for pi, prim in enumerate(mesh['primitives']):
            if 'indices' not in prim or pi != prim_idx:
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
            # 该 primitive 里命中白名单的岛（root 在 targets 中）
            move_set = set()
            for k in range(ntri):
                if find(k) in targets:
                    move_set.add(k)
            if not move_set:
                continue
            xs = [pos[i][0] for k in move_set for i in tris[k]]
            ys = [pos[i][1] for k in move_set for i in tris[k]]
            zs = [pos[i][2] for k in move_set for i in tris[k]]
            print(f"  {node_name} prim{pi}: 命中岛 {len(targets)} -> move={len(move_set)} "
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
    print(f'合计 move={total} tri -> Ducktail_02')
    meshes.append({'primitives': new_prims})
    nodes.append({'name': 'Ducktail_02', 'mesh': len(meshes) - 1})
    attach_new_node(len(nodes) - 1, moves[0][0])

    if not apply_mode:
        print('[dry] 未写入。加 --apply 执行（先备份 .bak_weld2_日期）')
        return 0
    stamp = datetime.date.today().strftime('%Y-%m-%d')
    shutil.copy2(glb, glb + f'.bak_weld2_{stamp}')
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
    print(f'OK: {glb} 已写入（备份 .bak_weld2_{stamp}），total={total_len}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
