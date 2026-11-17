#!/usr/bin/env python3
"""把导出的大 pck 拆成 main + data 两个包（NSIS 单文件/整包 2GB 上限）。
- 丢弃 docs 下未被运行时引用的图片（保留 boot_screen 用的那张）
- maps/assets/venues 与 maps/assets/polyhaven/models 移入 data 包
格式与 Godot 4.7 pack v4 完全一致：offset 相对 file_base，目录在文件尾。
"""
import struct, os, re, sys, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = ROOT + "/build/windows/APEX_VELOCITY.pck"
OUT_MAIN = ROOT + "/build/windows/split/APEX_VELOCITY.pck"
OUT_DATA = ROOT + "/build/windows/split/APEX_VELOCITY_data.pck"
KEEP_DOC = "docs/m32/menu-car-in-scene-coast.png"
MOVE_PREFIXES = ("maps/assets/venues/", "maps/assets/polyhaven/models/")

f = open(SRC, "rb")
magic, ver, vmaj, vmin, vpatch, flags, base, diroff = struct.unpack("<4sIIIIIQQ", f.read(40))
assert magic == b"GDPC" and ver == 4 and flags == 2, (magic, ver, flags)
f.seek(diroff)
n = struct.unpack("<I", f.read(4))[0]
entries = []
for i in range(n):
    l = struct.unpack("<I", f.read(4))[0]
    path = f.read(l).rstrip(b"\0").decode("utf-8")
    f.read((4 - l % 4) % 4)
    off, sz, md5, fl = struct.unpack("<QQ16sI", f.read(36))
    assert fl == 0
    entries.append({"path": path, "off": off, "sz": sz, "md5": md5})
by_path = {e["path"]: e for e in entries}

# imported 文件 -> 引用它的源文件集合
refs = {}
for dirpath, dirs, files in os.walk(ROOT):
    if "/.git" in dirpath or "/.godot" in dirpath or "/build" in dirpath:
        continue
    for fn in files:
        if not fn.endswith(".import"):
            continue
        rel = os.path.relpath(os.path.join(dirpath, fn), ROOT)[:-7]
        try:
            txt = open(os.path.join(dirpath, fn), encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for m in re.findall(r'res://(\.godot/imported/[^"\]\s]+)', txt):
            refs.setdefault(m, set()).add(rel)


def is_move_src(src):
    return src.startswith(MOVE_PREFIXES)


drop_srcs = {src for srcs in refs.values() for src in srcs
             if src.startswith("docs/") and src != KEEP_DOC}

drop, move, keep = [], [], []
conflicts = []
for e in entries:
    p = e["path"]
    if p.startswith("docs/") and p != KEEP_DOC and p != KEEP_DOC + ".remap":
        drop.append(e); continue
    if p.startswith(MOVE_PREFIXES):
        move.append(e); continue
    if p.startswith(".godot/imported/"):
        srcs = refs.get(p, set())
        if srcs and all(s in drop_srcs for s in srcs):
            drop.append(e); continue
        if srcs and all(is_move_src(s) for s in srcs):
            move.append(e); continue
        if srcs and any(is_move_src(s) for s in srcs):
            conflicts.append((p, srcs))
    keep.append(e)

if conflicts:
    print("!! 冲突：同一 imported 文件被移动与保留的源同时引用")
    for p, s in conflicts[:10]:
        print("  ", p, s)
    sys.exit(1)

# 每个移动的资源必须带上它的 .remap
move_paths = {e["path"] for e in move}
missing_remap = []
for e in move:
    p = e["path"]
    if p.startswith(".godot/imported/"):
        continue
    rp = p + ".remap"
    if rp in by_path and rp not in move_paths:
        missing_remap.append(rp)
if missing_remap:
    print("!! 缺少 remap 配套:", missing_remap[:10]); sys.exit(1)

# 保留侧不能残留指向已移动 imported 文件的 remap
kept_remap_bad = []
for e in keep:
    if not e["path"].endswith(".remap"):
        continue
    f.seek(base + e["off"])
    txt = f.read(e["sz"]).decode("utf-8", errors="ignore")
    for m in re.findall(r'res://(\.godot/imported/[^"\]\s]+)', txt):
        if m in move_paths:
            kept_remap_bad.append((e["path"], m))
if kept_remap_bad:
    print("!! 保留 remap 指向被移动文件:", kept_remap_bad[:10]); sys.exit(1)


def write_pack(path, es):
    es = sorted(es, key=lambda e: e["path"])
    with open(path, "wb") as out:
        out.write(struct.pack("<4sIIIIIQQ", b"GDPC", ver, vmaj, vmin, vpatch, 2, 112, 0))
        out.write(b"\0" * (112 - 40))
        new_off = 0
        offs = []
        for e in es:
            f.seek(base + e["off"])
            remaining = e["sz"]
            h = hashlib.md5()
            while remaining:
                chunk = f.read(min(remaining, 8 * 1024 * 1024))
                out.write(chunk)
                h.update(chunk)
                remaining -= len(chunk)
            assert h.digest() == e["md5"], "md5 mismatch: " + e["path"]
            offs.append(new_off)
            new_off += e["sz"]
            pad16 = (-new_off) % 16
            if pad16:
                out.write(b"\0" * pad16)
                new_off += pad16
        dir_pos = out.tell()
        out.write(struct.pack("<I", len(es)))
        for e, o in zip(es, offs):
            pb = e["path"].encode("utf-8")
            sl = (len(pb) + 3) & ~3
            out.write(struct.pack("<I", sl))
            out.write(pb)
            out.write(b"\0" * (sl - len(pb)))
            out.write(struct.pack("<QQ16sI", o, e["sz"], e["md5"], 0))
        out.seek(32)
        out.write(struct.pack("<Q", dir_pos))
    return dir_pos


os.makedirs(os.path.dirname(OUT_MAIN), exist_ok=True)
d1 = write_pack(OUT_MAIN, keep)
d2 = write_pack(OUT_DATA, move)
tot = lambda es: sum(e["sz"] for e in es)
exe = os.path.getsize(ROOT + "/build/windows/APEX_VELOCITY.exe")
print(f"drop : {len(drop):5d} files {tot(drop)/1e6:8.1f} MB (docs 图片)")
print(f"main : {len(keep):5d} files {tot(keep)/1e6:8.1f} MB -> {OUT_MAIN}")
print(f"data : {len(move):5d} files {tot(move)/1e6:8.1f} MB -> {OUT_DATA}")
print(f"installer 输入 ≈ {(tot(keep)+tot(move)+exe)/1e6:.0f} MB（含 exe {exe/1e6:.0f} MB），NSIS 上限 2147 MB")
print("OK")
