#!/usr/bin/env python3
"""APEX VELOCITY 宣传片 · 剪辑合成

依据 docs/58-宣传片剧本与分镜表.md 的时间线，把 capture.py 拍出的游戏内
真实画面剪成成片：字幕层 / 黑场过渡 / 专用 LOGO 动效 / BGM 混音。

用法：
    python3 trailer/edit.py             # 全流程
    python3 trailer/edit.py --keep      # 保留中间片段便于排查
"""

import array
import math
import os
import shutil
import subprocess
import sys
import wave

from PIL import Image, ImageDraw, ImageFont

FF = "/Users/tong/Library/Python/3.9/lib/python/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1"
PROJ = "/Users/tong/Desktop/极速巅峰"
SHOTS = "/tmp/apex_shots"
WORK = "/tmp/apex_edit"
OUT = os.path.join(PROJ, "trailer", "极速巅峰_宣传片_2026.mp4")
BGM = os.path.join(PROJ, "assets", "audio", "bgm")

W, H, FPS = 1920, 1080, 30
BLACK_FRAMES = 12                      # 0.40s 黑场
CYAN = (79, 233, 255)
FONT_CN = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_CN_LIGHT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_EN = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_EN_LIGHT = "/System/Library/Fonts/Supplemental/Arial.ttf"


def f(size, path=FONT_CN):
    return ImageFont.truetype(path, size)


def ease(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def tracking(d, xy, text, font, fill, gap=0):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=font, fill=fill)
        x += d.textlength(ch, font=font) + gap
    return x


# ---------------------------------------------------------------------------
# 时间线：全部以「帧」为单位，避免浮点累积误差；总 2534 帧 = 84.47s
# ---------------------------------------------------------------------------
T = []


def add(kind, frames, **kw):
    T.append(dict(kind=kind, frames=frames, **kw))


add("logo_intro", 90)
add("black", BLACK_FRAMES)
add("video", 80, src="S02_garage.avi", trim=0.0, sub=("45 台真车数据标定", "45 REAL-WORLD SPECS"))
add("black", BLACK_FRAMES)
add("video", 80, src="S03_menu.avi", trim=0.0, sub=("8 条主题赛道", "8 THEMED CIRCUITS"))
add("black", BLACK_FRAMES)
add("video", 80, src="S04_grid.avi", trim=0.0, sub=None)          # 3-2-1
add("video", 90, src="S04_grid.avi", trim=3.0, sub=None)          # GO + 起跑冲出

# 审片定稿：逐段从「主用机位 / 备选赛段」中挑构图最好的一条。
# 统一以能同时看见车与景观的低侧后 hero 为主，穿插 chase 与轻微数字重构图，
# 避免八段机位完全雷同，也避免 lead/side 机位里车太小、画面过暗的问题。
# 字段：中文名, 英文名, 光线, 素材, 入点(s), (放大倍数, 裁切偏移x, 裁切偏移y)
STAGES = [
    ("翡翠海岸", "COASTAL RUN",     "正午碧海", "A06_coast_alt.avi",   0.15, None),
    ("雪山隘口", "ALPINE PASS",     "雪线暖阳", "A07_alpine_alt.avi",  0.15, (1.10, 60, 0)),
    ("天际环城", "SKYLINE CIRCUIT", "黄昏金光", "A08_skyline_alt.avi", 0.15, None),
    ("落日港湾", "SUNSET HARBOR",   "金色暮光", "A09_harbor_alt.avi",  0.15, (1.10, -70, 0)),
    ("赤岩峡谷", "EMBER CANYON",    "赤色夕照", "S10_canyon.avi",       2.0, None),
    ("熔岩盆地", "MAGMA BASIN",     "火山暮色", "S11_magma.avi",        2.0, None),
    ("冰川湖环道", "GLACIER RING",  "蓝调时刻", "A12_glacier_alt.avi",  0.15, (1.08, 0, -40)),
    ("霓虹都市", "NEON DISTRICT",   "雨夜霓虹", "A13_city_alt.avi",     0.15, None),
]
for i, (cn, en, light, src, trim, zoom) in enumerate(STAGES, 1):
    add("video", 168, src=src, trim=trim, sub=(cn, en),
        stage=(i, len(STAGES), light), zoom=zoom)
    add("black", BLACK_FRAMES)

CLIMAX = [
    ("漂移", "DRIFT",     "S14_drift.avi",   0.4),
    ("氮气", "NITRO",     "S15_nitro.avi",   0.4),
    ("缠斗", "SIDE BY SIDE", "S16_pack.avi", 0.4),
    ("第一视角", "COCKPIT", "S17_cockpit.avi", 0.3),
    ("贴地", "LOW ANGLE", "S18_wheel.avi",  0.3),
]
for cn, en, src, trim in CLIMAX:
    add("video", 60, src=src, trim=trim, sub=(cn, en), climax=True)

add("video", 90, src="S19_finish.avi", trim=1.0, sub=None)
add("black", BLACK_FRAMES)
add("video", 74, src="S20_results.avi", trim=0.2, sub=("记录你的每一个最快圈", "EVERY LAP COUNTS"))
add("black", BLACK_FRAMES)
add("logo_outro", 150)

TOTAL_FRAMES = sum(e["frames"] for e in T)
TOTAL_DUR = TOTAL_FRAMES / FPS
# 霓虹都市段起点 = 光线转夜 + 音乐从 APEX ANTHEM 切到 NEON RUNNER
_city_idx = next(i for i, e in enumerate(T) if e.get("stage") and e["stage"][0] == 8)
MUSIC_SWITCH = sum(e["frames"] for e in T[:_city_idx]) / FPS


# ---------------------------------------------------------------------------
# 图层
# ---------------------------------------------------------------------------
def subtitle_png(path, cn, en, stage=None, climax=False):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x, y = 140, 862
    # 青色竖条
    d.rounded_rectangle((x, y + 4, x + 5, y + 92), radius=2, fill=CYAN + (235,))
    tx = x + 30
    if stage:
        i, n, light = stage
        tracking(d, (tx, y - 2), f"STAGE {i:02d} / {n:02d}   ·   {light}",
                 f(20, FONT_EN_LIGHT), (140, 210, 225, 235), gap=2)
        y += 34
    d.text((tx, y), cn, font=f(50, FONT_CN), fill=(255, 255, 255, 245))
    tw = d.textlength(cn, font=f(50, FONT_CN))
    # 中文右侧一道细线，英文压在下方
    d.line((tx + tw + 22, y + 30, tx + tw + 70, y + 30), fill=(120, 200, 215, 150), width=2)
    tracking(d, (tx + 2, y + 62), en, f(20, FONT_EN_LIGHT), (150, 215, 230, 235), gap=6)
    img.save(path)


def logo_frame(t, dur, outro=False):
    """专用 LOGO 动效：左对齐 + 青色竖条 + 主标题 / 中文名 / 卖点行。"""
    base = Image.new("RGBA", (W, H), (8, 10, 13, 255))
    d = ImageDraw.Draw(base)
    # 左侧极淡青色侧光：给纯黑底一点纵深，不使用会反白的网格线
    for x in range(0, 960, 3):
        v = 14.0 * (1.0 - x / 960.0) ** 2
        d.line((x, 0, x, H), fill=(8, 10 + int(v * 0.7), 13 + int(v), 255), width=3)

    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    p = ImageDraw.Draw(layer)
    x0, cy = 250, H // 2 - 30
    if outro:
        # 片尾：竖条先亮起，最后 1.2s 整体淡出
        grow = ease(t / 0.8)
        fade = 1.0 - ease((t - (dur - 1.2)) / 1.2)
    else:
        grow = ease(t / 0.7)
        fade = 1.0

    def a(v):
        return int(max(0, min(255, v * fade)))

    bar_h = 210 * grow
    p.rounded_rectangle((x0, cy - bar_h / 2, x0 + 7, cy + bar_h / 2), radius=3,
                        fill=CYAN + (a(255),))
    bx = x0 + 46
    slide = (1.0 - ease((t - 0.15) / 0.6)) * 46
    alpha = ease((t - 0.20) / 0.65)
    tracking(p, (bx + slide, cy - 118), "APEX VELOCITY", f(96, FONT_EN),
             (245, 250, 255, a(255 * alpha)), gap=4)
    cn_a = ease((t - 0.60) / 0.6)
    tracking(p, (bx + 4, cy + 6), "极速巅峰", f(44, FONT_CN_LIGHT),
             (205, 240, 248, a(255 * cn_a)), gap=10)
    line_a = ease((t - 0.95) / 0.6)
    p.line((bx, cy + 78, bx + 520 * line_a, cy + 78), fill=(79, 233, 255, a(120)), width=2)
    sub_a = ease((t - 1.10) / 0.7)
    if outro:
        line1 = "45 台车   ·   8 条赛道   ·   改装工厂   ·   本地双人"
        line2 = "把每一条路，跑成自己的纪录"
        p.text((bx, cy + 100), line1, font=f(26, FONT_CN_LIGHT), fill=(228, 240, 245, a(255 * sub_a)))
        p.text((bx, cy + 148), line2, font=f(24, FONT_CN_LIGHT), fill=(170, 205, 218, a(245 * sub_a)))
    else:
        p.text((bx, cy + 100), "45 CARS   ·   8 CIRCUITS   ·   ONE LINE TO THE LIMIT",
               font=f(22, FONT_EN_LIGHT), fill=(185, 210, 220, a(245 * sub_a)))
    return Image.alpha_composite(base, layer).convert("RGB")


def make_logo_frames(out_dir, frames, dur, outro):
    os.makedirs(out_dir, exist_ok=True)
    for i in range(frames):
        logo_frame(i / FPS, dur, outro).save(
            os.path.join(out_dir, f"l_{i:04d}.png"))


# ---------------------------------------------------------------------------
# ffmpeg 片段生成
# ---------------------------------------------------------------------------
VENC = ["-an", "-r", str(FPS), "-c:v", "libx264", "-crf", "19",
        "-preset", "medium", "-pix_fmt", "yuv420p", "-g", "60",
        "-bf", "2", "-movflags", "+faststart"]


def run(cmd, quiet=True):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    txt = r.stdout.decode("utf-8", "replace")
    if r.returncode != 0:
        print("  [FFMPEG ERROR]", txt[-1500:], flush=True)
        raise SystemExit(1)
    if not quiet:
        print(txt[-500:], flush=True)
    return txt


def build_segment(i, e):
    out = os.path.join(WORK, f"seg_{i:03d}.mp4")
    n = e["frames"]
    dur = n / FPS
    if e["kind"] == "black":
        run([FF, "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
             "-i", f"color=c=black:s={W}x{H}:r={FPS}:d={dur}",
             "-frames:v", str(n)] + VENC + [out])
        return out

    if e["kind"] in ("logo_intro", "logo_outro"):
        folder = os.path.join(WORK, e["kind"])
        make_logo_frames(folder, n, dur, e["kind"] == "logo_outro")
        run([FF, "-y", "-hide_banner", "-loglevel", "error", "-framerate", str(FPS),
             "-i", os.path.join(folder, "l_%04d.png"), "-frames:v", str(n)] + VENC + [out])
        return out

    src = os.path.join(SHOTS, e["src"])
    if not os.path.exists(src):
        raise SystemExit(f"缺少素材: {src}")
    cmd = [FF, "-y", "-hide_banner", "-loglevel", "error",
           "-ss", str(e["trim"]), "-i", src]
    zoom = e.get("zoom")
    if zoom:
        z, dx, dy = zoom
        zw, zh = int(W * z) // 2 * 2, int(H * z) // 2 * 2
        cx = max(0, min(zw - W, (zw - W) // 2 + dx))
        cy = max(0, min(zh - H, (zh - H) // 2 + dy))
        base_vf = f"scale={zw}:{zh}:flags=lanczos,crop={W}:{H}:{cx}:{cy},setsar=1"
    else:
        base_vf = f"scale={W}:{H}:flags=lanczos,setsar=1"
    sub = e.get("sub")
    if sub:
        sp = os.path.join(WORK, f"sub_{i:03d}.png")
        subtitle_png(sp, sub[0], sub[1], stage=e.get("stage"), climax=e.get("climax", False))
        cmd += ["-loop", "1", "-framerate", str(FPS), "-t", f"{dur:.4f}", "-i", sp]
        fade_out_st = max(0.2, dur - 0.75)
        fc = (
            f"[1:v]format=rgba,fade=t=in:st=0.35:d=0.25:alpha=1,"
            f"fade=t=out:st={fade_out_st:.3f}:d=0.30:alpha=1[s];"
            f"[0:v]{base_vf}[v0];"
            f"[v0][s]overlay=0:0:format=auto,format=yuv420p[v]"
        )
        cmd += ["-filter_complex", fc, "-map", "[v]"]
    else:
        cmd += ["-vf", base_vf + ",format=yuv420p", "-map", "0:v:0"]
    cmd += ["-frames:v", str(n)] + VENC + [out]
    run(cmd)
    return out


# ---------------------------------------------------------------------------
# 音轨：apex.ogg → neon.ogg，1s 交叉淡化 + 全局淡入淡出
# ---------------------------------------------------------------------------
def build_audio(path):
    a1 = os.path.join(WORK, "a1.wav")
    a2 = os.path.join(WORK, "a2.wav")
    cross = 1.0
    # 第一段到切换点 + 交叉区；第二段覆盖余下全部
    t1 = MUSIC_SWITCH + cross
    t2 = TOTAL_DUR - MUSIC_SWITCH + cross
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-stream_loop", "3",
         "-i", os.path.join(BGM, "apex.ogg"), "-t", f"{t1:.4f}",
         "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", a1])
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-stream_loop", "2",
         "-i", os.path.join(BGM, "neon.ogg"), "-t", f"{t2:.4f}",
         "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", a2])

    def read(p):
        with wave.open(p, "rb") as w:
            return (w.getframerate(), w.getnchannels(),
                    array.array("h", w.readframes(w.getnframes())))

    sr, ch, s1 = read(a1)
    _, _, s2 = read(a2)
    total = int(TOTAL_DUR * sr) * ch
    mix = array.array("h", [0]) * total
    sw = int(MUSIC_SWITCH * sr) * ch
    cw = int(cross * sr) * ch
    for k in range(min(len(s1), sw + cw)):
        mix[k] = s1[k]
    off = sw
    for k in range(min(len(s2), total - off)):
        idx = off + k
        if idx >= total:
            break
        w2 = min(1.0, k / max(1, cw)) if k < cw else 1.0
        w1 = 1.0 - w2 if k < cw else 0.0
        base = int(mix[idx] * w1) if k < cw else 0
        mix[idx] = max(-32768, min(32767, int(base + s2[k] * w2)))
    # 全局淡入 0.8s / 淡出 1.2s
    fi, fo = int(0.8 * sr) * ch, int(1.2 * sr) * ch
    for k in range(total):
        g = 1.0
        if k < fi:
            g *= k / fi
        if k > total - fo:
            g *= max(0.0, (total - k) / fo)
        mix[k] = int(mix[k] * g)
    with wave.open(path, "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(mix.tobytes())


def main():
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(os.path.join(PROJ, "trailer"), exist_ok=True)
    print(f"[EDIT] timeline {len(T)} clips / {TOTAL_FRAMES} frames / {TOTAL_DUR:.2f}s"
          f" / music switch {MUSIC_SWITCH:.2f}s", flush=True)
    segs = []
    for i, e in enumerate(T):
        print(f"[{i+1:02d}/{len(T)}] {e['kind']:10s} {e['frames']:4d}f "
              f"{e.get('src', e.get('sub', ('',))[0] if e.get('sub') else '')}", flush=True)
        segs.append(build_segment(i, e))
    listing = os.path.join(WORK, "concat.txt")
    with open(listing, "w") as fh:
        for p in segs:
            fh.write(f"file '{p}'\n")
    silent = os.path.join(WORK, "silent.mp4")
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-f", "concat",
         "-safe", "0", "-i", listing, "-c", "copy", silent])
    audio = os.path.join(WORK, "mix.wav")
    print("[EDIT] mixing audio ...", flush=True)
    build_audio(audio)
    print("[EDIT] muxing final ...", flush=True)
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-i", silent, "-i", audio,
         "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac",
         "-b:a", "192k", "-shortest", OUT])
    print(f"[EDIT] DONE  {OUT}  {os.path.getsize(OUT)/1e6:.1f}MB", flush=True)
    if "--keep" not in sys.argv:
        for p in segs:
            try:
                os.remove(p)
            except OSError:
                pass


if __name__ == "__main__":
    main()
