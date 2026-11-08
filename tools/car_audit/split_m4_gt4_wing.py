#!/usr/bin/env python3
"""bmw_m4_gt4.glb 尾翼拆分手术（一次性工具，2026-11-07）

问题：M4 GT4 的原厂大尾翼没有独立节点，而是焊死在多个网格里——
  · m4_gt4_LOD_A_BOOT_mm_ext prim0（CARPAINT_ext）：翼面 168 tri
  · m4_gt4_LOD_A_BOOT_mm_ext prim1（material spo）：翼面副本 192 tri
  · Body_05 prim0（material misc）：立柱+端板 332 tri
导致换装供体尾翼时原厂翼无法按名隐藏，出现「新翼叠原翼」。

手术：
  1. 把上述尾翼三角形拆到新节点 Spoiler_01（翼面）/ Spoiler_02（立柱+端板），
     与其它车款的命名约定一致 → GarageLook 名字匹配即可隐藏，PartsLibrary
     还能把 GT4 变成尾翼供体车；
  2. 原 Body_05 prim0 / BOOT prim0 重建索引（去掉尾翼 tri），BOOT prim1 整体
     迁移到 Spoiler_01；顶点缓冲全部原样共享（法线/UV 不动）；
  3. 新增 index buffer 追加到二进制块尾部，buffer/accessors/bufferViews 只增不改。

用法: python3 split_m4_gt4_wing.py <glb路径>
"""
import json, struct, sys, array

WING_BOX = dict(y_min=1.15, z_max=-1.75)   # 与顶点级实测一致：区域内全部是尾翼几何

def is_wing_tri(pos, idx3):
    return all(pos[i][1] > WING_BOX['y_min'] and pos[i][2] < WING_BOX['z_max'] for i in idx3)

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

    # 新的二进制追加区
    new_blob = bytearray()
    def add_bv(arr, align=4):
        while (len(blob) + len(new_blob)) % align:
            new_blob.append(0)
        bv_off = len(blob) + len(new_blob)
        new_blob.extend(arr.tobytes())
        data['bufferViews'].append({
            'buffer': 0, 'byteOffset': bv_off, 'byteLength': len(arr.tobytes()),
        })
        return len(data['bufferViews']) - 1

    def add_idx_acc(idx_list, comp_type):
        fmt = {5125:('I',4),5123:('H',2)}[comp_type]
        a = array.array(fmt[0], idx_list)
        bv = add_bv(a, align=fmt[1])
        data['accessors'].append({
            'bufferView': bv, 'componentType': comp_type, 'count': len(idx_list),
            'type': 'SCALAR',
        })
        return len(data['accessors']) - 1

    # ---- 1) 分类 Body_05 prim0 与 BOOT prim0 的尾翼 tri -------------------
    def split_wing(node_name, prim_idx=0):
        n = node_by_name(node_name)
        prim = meshes[n['mesh']]['primitives'][prim_idx]
        pos = read_acc(prim['attributes']['POSITION'])
        idxs = read_acc(prim['indices'])
        wing, body = [], []
        for t in range(0, len(idxs), 3):
            (wing if is_wing_tri(pos, idxs[t:t+3]) else body).extend(idxs[t:t+3])
        return prim, wing, body

    b05_prim, b05_wing, b05_body = split_wing('Body_05')
    boot_prim, boot_wing, boot_body = split_wing('m4_gt4_LOD_A_BOOT_mm_ext', 0)
    print(f"Body_05 prim0: wing={len(b05_wing)//3} tri, body={len(b05_body)//3} tri")
    print(f"BOOT    prim0: wing={len(boot_wing)//3} tri, body={len(boot_body)//3} tri")

    b05_comp = data['accessors'][b05_prim['indices']]['componentType']
    boot_comp = data['accessors'][boot_prim['indices']]['componentType']

    # ---- 2) 新 mesh：Spoiler_01（翼面）/ Spoiler_02（立柱+端板） ----------
    # Spoiler_01 = BOOT prim0 的翼面 tri（车漆）+ 原 BOOT prim1 整体（黑色 spo 副本）
    boot_node = node_by_name('m4_gt4_LOD_A_BOOT_mm_ext')
    boot_mesh = meshes[boot_node['mesh']]
    old_prim1 = boot_mesh['primitives'][1]
    spoiler1_mesh = {
        'primitives': [
            {'attributes': boot_prim['attributes'], 'indices': add_idx_acc(boot_wing, boot_comp),
             'material': boot_prim['material'], 'mode': 4},
            {'attributes': old_prim1['attributes'], 'indices': old_prim1['indices'],
             'material': old_prim1['material'], 'mode': 4},
        ]
    }
    # Spoiler_02 = Body_05 的立柱+端板 tri
    b05_node = node_by_name('Body_05')
    spoiler2_mesh = {
        'primitives': [
            {'attributes': b05_prim['attributes'], 'indices': add_idx_acc(b05_wing, b05_comp),
             'material': b05_prim['material'], 'mode': 4},
        ]
    }
    meshes.append(spoiler1_mesh)
    meshes.append(spoiler2_mesh)
    i_m1 = len(meshes) - 2
    i_m2 = len(meshes) - 1

    # ---- 3) 新节点，挂到 CarRoot（与原节点同级同变换=identity） ------------
    carroot = node_by_name('CarRoot')
    children = carroot.setdefault('children', [])
    nodes.append({'name': 'Spoiler_01', 'mesh': i_m1})
    children.append(len(nodes) - 1)
    nodes.append({'name': 'Spoiler_02', 'mesh': i_m2})
    children.append(len(nodes) - 1)

    # ---- 4) 原网格去尾翼 ---------------------------------------------------
    b05_prim['indices'] = add_idx_acc(b05_body, b05_comp)
    boot_prim['indices'] = add_idx_acc(boot_body, boot_comp)
    del boot_mesh['primitives'][1]   # spo 副本已整体迁走

    # ---- 5) 写回 GLB -------------------------------------------------------
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
    main(sys.argv[1])
