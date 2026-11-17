#!/usr/bin/env python3
"""章节解说式宣传片 · 实机素材拍摄器

与 capture.py（叙事版 90s）分开维护：这一版要的是「能塞进设备 mockup 的真实界面」
和「能做全幅底图的实机镜头」，因此多了 UI 场景、画质 A/B、分屏对战与装饰编辑器。

用法：
    python3 trailer/capture_chapters.py                 # 拍全部
    python3 trailer/capture_chapters.py GARAGE DRIFT    # 只拍指定分镜
    python3 trailer/capture_chapters.py --force         # 已存在也重拍

沙盒 HOME：拍片会覆写 user:// 里的 settings/garage/cone_layout，
用独立 HOME 隔离，避免污染正在运行的游戏存档。
"""

import os
import subprocess
import sys
import time

PROJ = "/Users/tong/Desktop/极速巅峰"
GODOT = "/Users/tong/Applications/Godot.app/Contents/MacOS/Godot"
WORK = "/Users/tong/Desktop/宣传片学习"
SHOTS_DIR = os.path.join(WORK, "shots")
SANDBOX_HOME = os.path.join(WORK, "home")
REAL_HOME = os.path.expanduser("~")
DUMMY_SHOT = "/tmp/apex_shot_dummy.png"

# id, 输出名, 额外引擎参数, shot-scene, track, car, dist, trailer-shot, hud, nogrid,
# quality, mode, 主场景, frames, 说明
SHOTS = [
    # ---- 全幅底图：电影感实机镜头 ----
    ("OPEN_CITY", "open_city", [], "race", "city", "bmw_m4_g82", 2100, "hero", 0, True,
     "ultra", "", "", 240, "片头底图 · 霓虹都市雨夜 hero"),
    ("END_CITY", "end_city", [], "race", "city", "bmw_m4_g82", 2600, "chase", 0, True,
     "ultra", "", "", 240, "片尾底图 · 夜城追车"),
    ("PANO_GLACIER", "pano_glacier", [], "panorama", "glacier", "pandem_m3_e92", 620, "", None, False,
     "ultra", "", "", 240, "冰川湖环道 · 贴地前推全景"),
    ("PANO_COAST", "pano_coast", [], "panorama", "coast", "bmw_csl_hommage", 900, "", None, False,
     "ultra", "", "", 240, "翡翠海岸 · 贴地前推全景"),
    ("PANO_METRO", "pano_metro", [], "panorama", "metro", "lambo_urus", 1200, "", None, False,
     "ultra", "", "", 240, "都会环线 · 真实街道前推"),

    # ---- 极限动作：漂移 / 氮气 / 缠斗 / 座舱 ----
    ("DRIFT", "drift", [], "drift", "city", "bmw_m4_g82", None, "", 0, True,
     "ultra", "", "", 240, "夜城漂移甩尾"),
    ("NITRO", "nitro", [], "nitro", "magma", "bmw_m6_gt3", None, "", 0, True,
     "ultra", "", "", 240, "熔岩盆地氮气喷射"),
    ("PACK", "pack", [], "pack", "coast", "bmw_m850i", None, "", 0, True,
     "ultra", "", "", 240, "海岸三车缠斗"),
    ("COCKPIT", "cockpit", [], "race", "skyline", "bmw_m2_g87", 1600, "cockpit", 0, True,
     "ultra", "", "", 200, "黄昏座舱第一视角"),

    # ---- 画质 A/B：同机位同赛道，只有档位不同 ----
    ("QUAL_LOW", "qual_low", [], "race", "harbor", "bmw_z4_m40i", 1000, "hero", 0, True,
     "low", "", "", 180, "落日港湾 · 低画质"),
    ("QUAL_ULTRA", "qual_ultra", [], "race", "harbor", "bmw_z4_m40i", 1000, "hero", 0, True,
     "ultra", "", "", 180, "落日港湾 · 极致画质"),

    # ---- 本地双人真分屏 ----
    ("DUEL", "duel", [], "race", "coast", "bmw_m4_gt3", 900, "chase", None, True,
     "ultra", "duel", "", 240, "海岸 1v1 真分屏"),

    # ---- UI 界面：塞进设备 mockup ----
    ("GARAGE", "garage", [], "garage", "", "bmw_m4_gt3", None, "", None, False,
     "ultra", "", "", 120, "车库展车与参数"),
    ("GARAGE_GRID", "garage_grid", [], "garage-grid", "", "bmw_m4_gt3", None, "", None, False,
     "ultra", "", "", 120, "车型列表 · 改装工厂"),
    ("ARCHIVE", "archive", [], "archive", "", "bmw_m4_gt3", None, "", None, False,
     "ultra", "", "", 120, "赛道档案 · 11 条图"),
    ("SETTINGS_GAME", "settings_game", [], "settings-game", "", "bmw_m4_gt3", None, "", None, False,
     "ultra", "", "", 120, "游戏设置 · 画质档位"),
    ("RESULTS", "results", [], "results", "city", "bmw_m4_g82", None, "", None, False,
     "ultra", "", "", 180, "结算界面"),
    ("ACHIEVEMENTS", "achievements", [], "achievements", "", "bmw_m4_gt3", None, "", None, False,
     "ultra", "", "", 120, "成就与纪录"),
    ("MENU_METRO", "menu_metro", [], "menu", "metro", "bmw_m4_gt3", None, "", None, False,
     "ultra", "", "", 120, "主菜单 · 赛道实景背景"),

    # ---- 场景装饰编辑器（独立主场景）----
    ("DECOR", "decor", ["scenes/decor_editor.tscn"], "", "coast", "", None, "", None, False,
     "ultra", "", "decor_editor", 240, "场景装饰编辑器 · 摆位与保存"),
]


def build_cmd(s):
    sid, name, extra, scene, track, car, dist, tshot, hud, nogrid, qual, mode, _, frames, _d = s
    out = os.path.join(SHOTS_DIR, f"{sid}_{name}.avi")
    engine = [
        GODOT, "--path", PROJ, "--rendering-driver", "metal",
    ]
    engine += extra
    engine += [
        "--write-movie", out, "--fixed-fps", "30",
        "--quit-after", str(frames), "--disable-vsync", "--",
    ]
    if scene == "decor_editor":
        # 装饰编辑器有自己的主场景，只认 --track
        user = [f"--track={track}"]
        return out, engine + user
    user = [
        f"--shot={DUMMY_SHOT}",
        f"--shot-scene={scene}",
        "--movie-frames=9999",
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
    if qual:
        user.append(f"--quality={qual}")
    if mode:
        user.append(f"--mode={mode}")
    return out, engine + user


def prepare_home():
    """沙盒 HOME：把真实存档复制一份进去，界面里才有正常的车库缩略图与纪录。"""
    src = os.path.join(REAL_HOME, "Library/Application Support/Godot")
    dst = os.path.join(SANDBOX_HOME, "Library/Application Support/Godot")
    if not os.path.isdir(dst):
        os.makedirs(dst, exist_ok=True)
        subprocess.run(["rsync", "-a", "--exclude=editor_cache", f"{src}/", f"{dst}/"],
                       check=False)
        print("[CAPTURE] sandbox HOME prepared", flush=True)


def main():
    args = [a for a in sys.argv[1:]]
    force = "--force" in args
    only = {a for a in args if not a.startswith("--")}
    os.makedirs(SHOTS_DIR, exist_ok=True)
    prepare_home()
    env = dict(os.environ, HOME=SANDBOX_HOME)
    todo = [s for s in SHOTS if not only or s[0] in only]
    print(f"[CAPTURE] {len(todo)} shots -> {SHOTS_DIR}", flush=True)
    ok = 0
    for i, s in enumerate(todo, 1):
        out, cmd = build_cmd(s)
        if os.path.exists(out) and os.path.getsize(out) > 100_000 and not force:
            print(f"[{i}/{len(todo)}] {s[0]} {s[14]}  SKIP (exists)", flush=True)
            ok += 1
            continue
        t0 = time.time()
        print(f"[{i}/{len(todo)}] {s[0]} {s[14]}  frames={s[13]} ...", flush=True)
        logp = os.path.join(SHOTS_DIR, f"{s[0]}_{s[1]}.log")
        with open(logp, "w") as log:
            r = subprocess.run(cmd, cwd=PROJ, stdout=log, stderr=subprocess.STDOUT, env=env)
        dt = time.time() - t0
        size = os.path.getsize(out) / 1e6 if os.path.exists(out) else 0
        status = "OK" if r.returncode == 0 and size > 0.1 else "FAIL"
        if status == "OK":
            ok += 1
        print(f"          -> {status}  {size:.1f}MB  {dt:.1f}s  rc={r.returncode}", flush=True)
    print(f"[CAPTURE] DONE {ok}/{len(todo)}", flush=True)


if __name__ == "__main__":
    main()
