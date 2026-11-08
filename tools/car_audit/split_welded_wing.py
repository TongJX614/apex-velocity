#!/usr/bin/env python3
"""焊死式原厂尾翼 GLB 手术（通用版，逻辑同 split_m4_gt4_wing_v2.py）：

把焊在车身网格里的原厂尾翼三角形，用「种子 + 区域生长」拆到独立节点
Ducktail_01 / Ducktail_02（命名含 ducktail → GarageLook 隐藏规则可识别；
不含 spoiler/wing → 不会误入 PartsLibrary 供体目录）。

每台车一个 CONFIG：targets 列出候选网格 + 种子/生长盒（车尾在 -z）。
种子 = 全部顶点都在 seed 盒内的 tri（必须纯翼）；生长域 = grow 盒；
沿共享顶点边界生长。安全阀：单 primitive 生长结果 >60% 或 =0 → 中止不写。

用法:
  python3 split_welded_wing.py <glb> --dry   # 只打印统计
  python3 split_welded_wing.py <glb> --apply # 备份后写入
"""
import json, struct, sys, array, shutil, datetime

CONFIGS = {
    # bmw_m4_gt3: 翼面+端板在 Body_06（y1.21-1.33, z-2.24..-2.05），Body_05 有副本，
    # Badge_Geo 有端板上的小徽标。种子 y>1.20 z<-2.00，生长 y>1.02 z<-1.88。
    'bmw_m4_gt3.glb': {
        'targets': [
            {'node': 'Body_06', 'seed': {'y': 1.20, 'z': -2.00}, 'grow': {'y': 1.02, 'z': -1.88}},
            {'node': 'Body_05', 'seed': {'y': 1.20, 'z': -2.00}, 'grow': {'y': 1.02, 'z': -1.88}},
            {'node': 'Badge_Geo_lodA', 'seed': {'y': 1.18, 'z': -2.00}, 'grow': {'y': 1.02, 'z': -1.88}},
        ],
    },
    # bmw_m6_gt3: Body_02 翼面（y1.17-1.33, z-2.47..-2.1），Body_06 支柱副本。
    'bmw_m6_gt3.glb': {
        'targets': [
            {'node': 'Body_02', 'seed': {'y': 1.16, 'z': -2.10}, 'grow': {'y': 1.00, 'z': -1.95}},
            {'node': 'Body_06', 'seed': {'y': 1.10, 'z': -2.10}, 'grow': {'y': 0.98, 'z': -1.95}},
        ],
    },
    # varis_m4_gts: Body_06 翼面（y1.20-1.37, z-2.33..-2.05），Body_07 副本。
    # 注意两块的右侧高位是车顶（z>-0.8），种子盒 z<-2.0 已排除。
    'varis_m4_gts.glb': {
        'targets': [
            {'node': 'Body_06', 'seed': {'y': 1.19, 'z': -2.00}, 'grow': {'y': 1.05, 'z': -1.90}},
            {'node': 'Body_07', 'seed': {'y': 1.19, 'z': -2.00}, 'grow': {'y': 1.05, 'z': -1.90}},
        ],
    },
    # pandem_m3_e92: Body_04 = 后备箱中央蓝鸭尾（x±0.35）；br_Carbon1 = 碳翼面+支柱
    #（碳件网格还含裙板/扩散器等低位件，翼占比 2368/3907 属合理，force 跳过熔断）；
    # br_Paint = 蓝色大端板（种子 y>1.10 z<-2.10，生长 y>0.90 z<-1.95）。
    'pandem_m3_e92.glb': {
        'targets': [
            {'node': 'Body_04', 'seed': {'y': 1.05, 'z': -1.95}, 'grow': {'y': 0.95, 'z': -1.85}},
            {'node': 'br_Carbon1_Geo_lodA_Carbon1_Geo_lodA_BMW_RBM3E92RewardR_f0',
             'seed': {'y': 1.05, 'z': -1.75}, 'grow': {'y': 0.98, 'z': -1.65}, 'force': True},
            {'node': 'br_Paint_Geo_lodA_Paint_Geo_lodA_BMW_RBM3E92RewardRecyc_66',
             'seed': {'y': 1.10, 'z': -2.10}, 'grow': {'y': 0.90, 'z': -1.95}, 'force': True},
        ],
    },
    # byd_yangwang_u9: SM_RearKit 翼面+支柱（y1.18-1.36, z-2.48..-2.1）。
    'byd_yangwang_u9.glb': {
        'targets': [
            {'node': 'SM_RearKit_0000.001', 'seed': {'y': 1.17, 'z': -2.05}, 'grow': {'y': 1.10, 'z': -1.95}},
        ],
    },
}


def read_glb(path):
    with open(path, 'rb') as f:
        magic, ver, length = struct.unpack('<III', f.read(12))
        assert magic == 0x46546C67, 'not glb'
        jlen, jtype = struct.unpack('<II', f.read(8))
        data = json.loads(f.read(jlen))
        blen, btype = struct.unpack('<II', f.read(8))
        blob = f.read(blen)
    return data, blob, length


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
    cfg = CONFIGS.get(glb.split('/')[-1])
    if cfg is None:
        print('no config for', glb)
        return 1
    data, blob, length = read_glb(glb)
    nodes = data['nodes']
    meshes = data['meshes']

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

    # 新节点挂到与源节点相同的父级（找遍 nodes.children / scenes 根）
    def attach_new_node(new_node_idx, src_name):
        for i, n in enumerate(nodes):
            ch = n.get('children', [])
            for c in ch:
                if nodes[c].get('name') == src_name:
                    n.setdefault('children', []).append(new_node_idx)
                    return
        data['scenes'][0].setdefault('nodes', []).append(new_node_idx)

    out_mesh_name = 'Ducktail_01'
    # 防重跑：已有 Ducktail 节点直接拒绝
    if any(n.get('name', '').startswith('Ducktail') for n in nodes):
        print('!! 已存在 Ducktail 节点，疑似已做过手术，中止')
        return 1

    new_prims = []   # (material, [primitive dicts]) 聚到一个新 mesh
    total_moved = 0
    for t in cfg['targets']:
        src = next((n for n in nodes if n.get('name') == t['node']), None)
        if src is None:
            print('!! 找不到节点', t['node'])
            return 1
        mesh = meshes[src['mesh']]
        for pi, prim in enumerate(mesh['primitives']):
            pos = read_acc(data, blob, prim['attributes']['POSITION'])
            if 'indices' not in prim:
                print(f"  {t['node']} prim{pi}: 无 indices，跳过")
                continue
            idxs = read_acc(data, blob, prim['indices'])
            ntri = len(idxs) // 3
            tris = [idxs[k * 3:(k + 1) * 3] for k in range(ntri)]

            def in_box(v, box):
                return all(p[1] > box['y'] and p[2] < box['z'] for p in (pos[i] for i in v))

            seeds = {k for k, v in enumerate(tris) if in_box(v, t['seed'])}
            if not seeds:
                print(f"  {t['node']} prim{pi}: 种子=0，跳过")
                continue
            vmap = {}
            for k, v in enumerate(tris):
                for vi in v:
                    vmap.setdefault(vi, []).append(k)
            grow = set(seeds)
            frontier = list(seeds)
            while frontier:
                cur = frontier.pop()
                for nb in vmap[tris[cur][0]] + vmap[tris[cur][1]] + vmap[tris[cur][2]]:
                    if nb in grow or not in_box(tris[nb], t['grow']):
                        continue
                    grow.add(nb)
                    frontier.append(nb)
            if not grow:
                print(f"  !! {t['node']} prim{pi}: 生长为空，中止不写")
                return 1
            xs = [pos[i][0] for k in grow for i in tris[k]]
            ys = [pos[i][1] for k in grow for i in tris[k]]
            zs = [pos[i][2] for k in grow for i in tris[k]]
            print(f"  {t['node']} prim{pi}: seed={len(seeds)} -> move={len(grow)} "
                  f"AABB x[{min(xs):.2f},{max(xs):.2f}] y[{min(ys):.2f},{max(ys):.2f}] z[{min(zs):.2f},{max(zs):.2f}]")
            if len(grow) > 0.6 * ntri and not t.get('force'):
                print(f"  !! {t['node']} prim{pi}: 生长 {len(grow)}/{ntri} 超 60%，中止（确认合理可加 force:true）")
                return 1
            keep, move = [], []
            for k, v in enumerate(tris):
                (move if k in grow else keep).extend(v)
            xs = [pos[i][0] for k in grow for i in tris[k]]
            ys = [pos[i][1] for k in grow for i in tris[k]]
            zs = [pos[i][2] for k in grow for i in tris[k]]
            print(f"  {t['node']} prim{pi}: seed={len(seeds)} -> move={len(move)//3} keep={len(keep)//3} "
                  f"AABB x[{min(xs):.2f},{max(xs):.2f}] y[{min(ys):.2f},{max(ys):.2f}] z[{min(zs):.2f},{max(zs):.2f}]")
            comp_type = data['accessors'][prim['indices']]['componentType']
            prim['indices'] = add_idx_acc(keep, comp_type)
            new_prims.append((prim['material'], {
                'attributes': prim['attributes'], 'indices': add_idx_acc(move, comp_type),
                'material': prim['material'], 'mode': 4,
            }))
            total_moved += len(move) // 3

    if not new_prims:
        print('没有可移动的三角形')
        return 1
    print(f"合计 move={total_moved} tri -> {out_mesh_name}")

    # 分 material 聚合成 primitives（材质不同不能合一个 primitive）
    by_mat = {}
    for mat, p in new_prims:
        by_mat.setdefault(mat, []).append(p)
    new_mesh = {'primitives': [dict(p) for p in by_mat[sorted(by_mat)[0]]]}
    mats = sorted(by_mat)
    for m in mats[1:]:
        new_mesh['primitives'].extend(by_mat[m])
    meshes.append(new_mesh)
    new_node = {'name': out_mesh_name, 'mesh': len(meshes) - 1}
    nodes.append(new_node)
    attach_new_node(len(nodes) - 1, cfg['targets'][0]['node'])

    if not apply_mode:
        print('[dry] 未写入。加 --apply 执行（会先备份 .bak_weld_日期）')
        return 0

    stamp = datetime.date.today().strftime('%Y-%m-%d')
    shutil.copy2(glb, glb + f'.bak_weld_{stamp}')
    blob_all = blob + bytes(new_blob)
    data['buffers'][0]['byteLength'] = len(blob_all)
    json_bin = json.dumps(data, separators=(',', ':')).encode('utf-8')
    while len(json_bin) % 4:
        json_bin += b' '
    while len(blob_all) % 4:
        blob_all += b'\x00'
    total = 12 + 8 + len(json_bin) + 8 + len(blob_all)
    with open(glb, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, total))
        f.write(struct.pack('<II', len(json_bin), 0x4E4F534A))
        f.write(json_bin)
        f.write(struct.pack('<II', len(blob_all), 0x004E4942))
        f.write(blob_all)
    print(f"OK: {glb} 已写入（备份 .bak_weld_{stamp}），total={total} (+{total-length})")
    return 0


if __name__ == '__main__':
    sys.exit(main())
