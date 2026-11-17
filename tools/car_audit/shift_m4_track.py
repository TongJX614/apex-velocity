#!/usr/bin/env python3
"""一次性资产级修正：bmw_m4_adro_kit 宽体轮拱外板（后 |x|=1.020 / 前 0.992）
比车轮外侧面（后 0.982 / 前 0.978）更靠外，轮子缩在轮拱里：侧看时轮拱外板挡住
轮毂正面，只剩一圈胎环＋对面轮子从拱口露出，观感即"错位悬空轮圈"。
把四个 Wheel_* 节点沿 X 外移：后 +0.050、前 +0.025，使胎外侧面与轮拱齐平微凸。
full 与 LOD 两份 GLB 都处理。可复原：运行前自动备份到 /tmp/wheel_fix/backup/track_shift/。
"""
import struct, json, os, shutil

ROOT = "/Users/tong/Desktop/极速巅峰"
FILES = [
    "cars/assets/models/bmw_m4_adro_kit.glb",
    "cars/assets/models_lod/bmw_m4_adro_kit.glb",
]
BACKUP = "/tmp/wheel_fix/backup/track_shift"
DELTA = {"Wheel_FL": 0.025, "Wheel_FR": 0.025, "Wheel_RL": 0.050, "Wheel_RR": 0.050}


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
        payload = payload + b"\x00" * pad
        body += struct.pack("<II", len(payload), ctype) + payload
    return struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body


def shift(path):
    full = os.path.join(ROOT, path)
    data = open(full, "rb").read()
    chunks = split_glb(data)
    gltf, _ = json.JSONDecoder().raw_decode(chunks[0][1].decode("utf-8"))
    done = []
    for n in gltf["nodes"]:
        nm = n.get("name", "")
        if nm in DELTA and "translation" in n:
            t = n["translation"]
            sign = 1.0 if t[0] >= 0 else -1.0
            t[0] += sign * DELTA[nm]
            done.append("%s x=%.4f" % (nm, t[0]))
    if not done:
        print("no wheel nodes:", path)
        return
    newjson = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    chunks[0] = (0x4E4F534A, newjson)
    os.makedirs(BACKUP, exist_ok=True)
    shutil.copy2(full, os.path.join(BACKUP, os.path.basename(os.path.dirname(full)) + "_" + os.path.basename(full)))
    open(full, "wb").write(pack_glb(chunks))
    print("shifted %s: %s" % (path, done))


for f in FILES:
    shift(f)
print("DONE")