#!/usr/bin/env python3
"""APEX VELOCITY 宣传片 · 游戏内真实画面拍摄器

依据 docs/58-宣传片剧本与分镜表.md 的 SHOTS 表，逐条启动 Godot Movie Maker，
以固定 30fps 录制**当前版本游戏的真实渲染画面**，输出 AVI(MJPEG) 到 shots/。

用法：
    python3 trailer/capture.py            # 拍全部
    python3 trailer/capture.py S06 S07    # 只拍指定分镜
    python3 trailer/capture.py --force    # 已存在也重拍

注意：每个分镜是独立的游戏进程，按顺序执行（多窗口会互抢渲染焦点）。
"""

import os
import subprocess
import sys
import time

PROJ = "/Users/tong/Desktop/极速巅峰"
GODOT = "/Users/tong/Applications/Godot.app/Contents/MacOS/Godot"
SHOTS_DIR = "/tmp/apex_shots"
DUMMY_SHOT = "/tmp/apex_shot_dummy.png"

# id, 输出名, scene, track, car, dist, trailer_shot, hud, nogrid, frames, 说明
SHOTS = [
    # ACT 1 · 整装
    ("S02", "garage",   "garage",  "",       "bmw_m4_gt3",        None, "",        None, False,  90, "车库展车 · 45 台真车"),
    ("S03", "menu",     "menu",    "coast",  "bmw_m4_gt3",        None, "",        None, False,  90, "主菜单 · 8 条赛道"),
    # ACT 2 · 发车（倒数 + 起跑，剪辑时拆成 S04 / S05）
    ("S04", "grid",     "grid",    "coast",  "xiaomi_su7",        None, "",        1,    False, 180, "3-2-1-GO 发车 + 起跑"),
    # ACT 3 · 八站征途（每段录 12s，剪辑时挑最好的 5.3s）
    ("S06", "coast",    "race",    "coast",  "xiaomi_su7",         620, "lead",    0,    True,  360, "翡翠海岸 · 正午碧海"),
    ("S07", "alpine",   "race",    "alpine", "bmw_m3_touring",     560, "hero",    0,    True,  360, "雪山隘口 · 雪线暖阳"),
    ("S08", "skyline",  "race",    "skyline","bmw_m4_gt3",         680, "side",    0,    True,  360, "天际环城 · 黄昏金光"),
    ("S09", "harbor",   "race",    "harbor", "bmw_z4_m40i",        640, "lead",    0,    True,  360, "落日港湾 · 金色暮光"),
    ("S10", "canyon",   "race",    "canyon", "byd_yangwang_u9",    900, "chase",   0,    True,  360, "赤岩峡谷 · 赤色夕照"),
    ("S11", "magma",    "race",    "magma",  "bmw_m6_gt3",         820, "hero",    0,    True,  360, "熔岩盆地 · 火山暮色"),
    ("S12", "glacier",  "race",    "glacier","bmw_i8",             700, "aerial",  0,    True,  360, "冰川湖环道 · 蓝调时刻"),
    ("S13", "city",     "race",    "city",   "bmw_m4_adro_g82",    700, "lead",    0,    True,  360, "霓虹都市 · 雨夜霓虹"),
    # ACT 4 · 极限（快切）
    ("S14", "drift",    "drift",   "city",   "bmw_m4_adro_g82",   None, "",        0,    True,   90, "漂移甩尾"),
    ("S15", "nitro",    "nitro",   "city",   "bmw_m4_gt3",        None, "",        0,    True,   90, "氮气喷射"),
    ("S16", "pack",     "pack",    "city",   "bmw_m4_gt3",        None, "",        0,    True,   90, "三车缠斗"),
    ("S17", "cockpit",  "race",    "city",   "bmw_m4_gt3",         700, "cockpit", 1,    True,   90, "驾驶位第一视角"),
    ("S18", "wheel",    "race",    "city",   "bmw_m4_gt3",         700, "wheel",   0,    True,   90, "贴地轮组特写"),
    # ACT 5 · 冲线与成绩
    # 收尾留在夜城且隐藏 HUD：延续夜景光线，也避免 HUD 暴露「第 1 圈刚起步」
    # 与紧随其后的 RACE FINISH 结算界面矛盾；完赛信息交给结算画面承担。
    ("S19", "finish",   "race",    "city",   "bmw_m4_gt3",        2100, "chase",   0,    True,  120, "夜城最后一程"),
    ("S20", "results",  "results", "",       "",                  None, "",        None, False,  90, "结算界面"),
    # 备选角度：每条赛道另拍一段不同赛段的 hero 机位，成片前逐段比选取优
    ("A06", "coast_alt",   "race", "coast",   "xiaomi_su7",       1000, "hero", 0, True, 180, "备选 · 海岸另一赛段"),
    ("A07", "alpine_alt",  "race", "alpine",  "bmw_m3_touring",    900, "hero", 0, True, 180, "备选 · 雪山另一赛段"),
    ("A08", "skyline_alt", "race", "skyline", "bmw_m4_gt3",       1100, "hero", 0, True, 180, "备选 · 天际另一赛段"),
    ("A09", "harbor_alt",  "race", "harbor",  "bmw_z4_m40i",      1000, "hero", 0, True, 180, "备选 · 港湾另一赛段"),
    ("A10", "canyon_alt",  "race", "canyon",  "byd_yangwang_u9",  1500, "hero", 0, True, 180, "备选 · 峡谷另一赛段"),
    ("A11", "magma_alt",   "race", "magma",   "bmw_m6_gt3",       1300, "hero", 0, True, 180, "备选 · 熔岩另一赛段"),
    ("A12", "glacier_alt", "race", "glacier", "bmw_i8",           1100, "hero", 0, True, 180, "备选 · 冰川另一赛段"),
    ("A13", "city_alt",    "race", "city",    "bmw_m4_adro_g82",  1100, "hero", 0, True, 180, "备选 · 夜城另一赛段"),
]


def build_cmd(s):
    sid, name, scene, track, car, dist, tshot, hud, nogrid, frames, _ = s
    out = os.path.join(SHOTS_DIR, f"{sid}_{name}.avi")
    engine = [
        GODOT, "--path", PROJ, "--rendering-driver", "metal",
        "--write-movie", out, "--fixed-fps", "30",
        "--quit-after", str(frames), "--disable-vsync", "--",
    ]
    user = [
        f"--shot={DUMMY_SHOT}",
        f"--shot-scene={scene}",
        "--movie-frames=9999",  # 阻止静帧截图提前退出，帧数交由引擎控制
    ]
    if track:
        user.append(f"--track={track}")
    if car:
        user.append(f"--car={car}")
    if dist is not None:
        user.append(f"--shot-dist={dist}")
    if tshot:
        user.append(f"--trailer-shot={tshot}")
    if hud is not None:
        user.append(f"--trailer-hud={hud}")
    if nogrid:
        user.append("--trailer-nogrid")
    return out, engine + user


def main():
    args = [a for a in sys.argv[1:]]
    force = "--force" in args
    only = {a for a in args if a.startswith("S") and not a.startswith("--")}
    os.makedirs(SHOTS_DIR, exist_ok=True)
    todo = [s for s in SHOTS if not only or s[0] in only]
    print(f"[CAPTURE] {len(todo)} shots -> {SHOTS_DIR}", flush=True)
    ok = 0
    for i, s in enumerate(todo, 1):
        out, cmd = build_cmd(s)
        if os.path.exists(out) and os.path.getsize(out) > 100_000 and not force:
            print(f"[{i}/{len(todo)}] {s[0]} {s[10]}  SKIP (exists)", flush=True)
            ok += 1
            continue
        t0 = time.time()
        print(f"[{i}/{len(todo)}] {s[0]} {s[10]}  frames={s[9]} ...", flush=True)
        with open(os.path.join(SHOTS_DIR, f"{s[0]}_{s[1]}.log"), "w") as log:
            r = subprocess.run(cmd, cwd=PROJ, stdout=log, stderr=subprocess.STDOUT)
        dt = time.time() - t0
        size = os.path.getsize(out) / 1e6 if os.path.exists(out) else 0
        status = "OK" if r.returncode == 0 and size > 0.1 else "FAIL"
        if status == "OK":
            ok += 1
        print(f"          -> {status}  {size:.1f}MB  {dt:.1f}s  rc={r.returncode}", flush=True)
    print(f"[CAPTURE] DONE {ok}/{len(todo)}", flush=True)


if __name__ == "__main__":
    main()
