#!/usr/bin/env python3
"""APEX VELOCITY 宣传片 · 游戏内真实画面拍摄器（90 秒版）

依据 docs/58-宣传片剧本与分镜表.md 的 SHOTS 表，逐条启动 Godot Movie Maker，
以固定 30fps 录制**当前版本游戏的真实渲染画面**，输出 AVI(MJPEG) 到 shots/。

本版只拍 10 张封闭赛道。

用法：
    python3 trailer/capture.py            # 拍全部
    python3 trailer/capture.py ST03 CL2   # 只拍指定分镜
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
    ("GARAGE", "garage", "garage", "", "bmw_m4_gt3", None, "", None, False, 90, "车库展车 · 46 台真车"),
    ("MENU", "menu", "menu", "metro", "bmw_m4_gt3", None, "", None, False, 90, "主菜单 · 都会环线"),
    # ACT 2 · 发车（倒数 + 起跑，剪辑时拆成两段）
    ("GRID", "grid", "grid", "coast", "bmw_m3_e46_gtr", None, "", 1, False, 180, "3-2-1-GO 发车"),
    # ACT 3 · 十站征途（每段录 10s，剪辑时挑 5.3s）
    ("ST01", "pass", "race", "pass", "bmw_m850i", 3200, "chase", 0, True, 300, "雾岭山道 · 晨雾直道"),
    ("ST02", "coast", "race", "coast", "bmw_csl_hommage", 1000, "hero", 0, True, 300, "翡翠海岸 · 正午碧海"),
    ("ST03", "metro", "race", "metro", "lambo_urus", 1000, "chase", 0, True, 300, "都会环线 · 真实街道"),
    ("ST04", "alpine", "race", "alpine", "pandem_m3_e92", 900, "hero", 0, True, 300, "雪山隘口 · 雪线暖阳"),
    ("ST05", "skyline", "race", "skyline", "bmw_m2_g87", 1100, "hero", 0, True, 300, "天际环城 · 黄昏金光"),
    ("ST06", "harbor", "race", "harbor", "bmw_z4_m40i", 1000, "hero", 0, True, 300, "落日港湾 · 金色暮光"),
    ("ST07", "canyon", "race", "canyon", "bmw_m5_f90", 900, "hero", 0, True, 300, "赤岩峡谷 · 赤色夕照"),
    ("ST08", "magma", "race", "magma", "bmw_m6_gt3", 2200, "chase", 0, True, 300, "熔岩盆地 · 火山暮色"),
    ("ST09", "glacier", "race", "glacier", "bmw_i8", 1100, "hero", 0, True, 300, "冰川湖环道 · 蓝调时刻"),
    ("ST10", "city", "race", "city", "bmw_m4_g82", 1100, "hero", 0, True, 300, "霓虹都市 · 雨夜霓虹"),
    # ACT 4 · 极限（快切）
    ("CL1", "drift", "drift", "city", "bmw_m4_g82", None, "", 0, True, 300, "漂移甩尾"),
    ("CL2", "nitro", "nitro", "city", "bmw_m4_g82", None, "", 0, True, 300, "氮气喷射"),
    ("CL3", "pack", "pack", "city", "bmw_m4_g82", None, "", 0, True, 300, "三车缠斗"),
    ("CL4", "cockpit", "race", "city", "bmw_m4_g82", 2100, "cockpit", 0, True, 150, "驾驶位第一视角"),
    ("CL5", "wheel", "race", "city", "bmw_m4_g82", 2100, "wheel", 0, True, 150, "贴地轮组特写"),
    # ACT 5 · 冲线与成绩
    ("FIN", "finish", "race", "city", "bmw_m4_g82", 2100, "chase", 0, True, 150, "夜城最后一程"),
    ("RES", "results", "results", "city", "bmw_m4_g82", None, "", None, False, 90, "结算界面"),
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
    only = {a for a in args if not a.startswith("--")}
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
