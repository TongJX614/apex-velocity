#!/usr/bin/env python3
"""一次性资产级清理：bmw_m4_adro_kit 的 CarRoot 下挂了 4 个名为 WheelJunk_* 的
杂散轮圈网格（后轮后方 0.24m 处悬空一个轮-sized 圆环，即用户看到的"错位轮圈"）。
把它们从父节点 children 里摘除并清掉 mesh 引用（节点定义保留为孤立空节点，不做
全量重索引，避免 skins/animation 的节点索引错位）。full 与 LOD 两份 GLB 都处理。
可复原：运行前自动备份到 /tmp/wheel_fix/backup/。
"""
import struct, json, os, shutil, sys

ROOT = "/Users/tong/Desktop/极速巅峰"
FILES = [
    "cars/assets/models/bmw_m4_adro_kit.glb",
    "cars/assets/models_lod/bmw_m4_adro_kit.glb",
]
BACKUP = "/tmp/wheel_fix/backup"


def split_glb(data):
    magic, ver, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67
    off = 12
    chunks = []
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        chunks.append((ctype, data[off:off + clen]))
        off += clen
    return chunks


def pack_glb(chunks):
    body = b""
    for ctype, payload in chunks:
        pad = (4 - len(payload) % 4) % 4
        payload = payload + (b"\x00" if ctype == 0x4E4F534A else b"\x00") * pad
        body += struct.pack("<II", len(payload), ctype) + payload
    return struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body


def clean(path):
    full = os.path.join(ROOT, path)
    data = open(full, "rb").read()
    chunks = split_glb(data)
    gltf = json.loads(chunks[0][1].decode("utf-8"))
    nodes = gltf["nodes"]
    junk = [i for i, n in enumerate(nodes) if "junk" in n.get("name", "").lower()]
    if not junk:
        print("no junk:", path)
        return
    junkset = set(junk)
    removed = []
    for n in nodes:
        ch = n.get("children")
        if ch:
            keep = [c for c in ch if c not in junkset]
            if len(keep) != len(ch):
                removed += [c for c in ch if c in junkset]
                n["children"] = keep
    for i in junk:
        nodes[i].pop("mesh", None)
    # 场景根里若直接挂 junk 也摘掉
    for sc in gltf.get("scenes", []):
        sc["nodes"] = [r for r in sc.get("nodes", []) if r not in junkset]
    newjson = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    chunks[0] = (0x4E4F534A, newjson)
    os.makedirs(BACKUP, exist_ok=True)
    shutil.copy2(full, os.path.join(BACKUP, os.path.basename(os.path.dirname(full)) + "_" + os.path.basename(full)))
    open(full, "wb").write(pack_glb(chunks))
    print("cleaned %s: detached %s (%s)" % (path, [nodes[i]["name"] for i in removed], len(removed)))


for f in FILES:
    clean(f)
print("DONE")