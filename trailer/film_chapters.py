#!/usr/bin/env python3
"""APEX VELOCITY · 极速巅峰 —— 章节解说式宣传片渲染器

版式语言来自同类型产品片：常驻品牌角标 + 章节眉标 + 大字宣言 + 设备 mockup 里放
游戏真实界面与实机画面 + 底部旁白字幕 + 段间交叉溶解。所有画面均为游戏内真实渲染。

用法：
    python3 trailer/film_chapters.py                 # 抽帧 + 渲染 + 混音出片
    python3 trailer/film_chapters.py --extract       # 只把 AVI 拆成帧序列
    python3 trailer/film_chapters.py --poster 300    # 导出某一帧 PNG 自检
    python3 trailer/film_chapters.py --render        # 只出无声画面
"""

import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FF = "/Users/tong/Library/Python/3.9/lib/python/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1"
PROJ = "/Users/tong/Desktop/极速巅峰"
WORK = "/Users/tong/Desktop/宣传片学习"
SHOTS = os.path.join(WORK, "shots")
SEQ = os.path.join(WORK, "seq")
OUT = os.path.join(PROJ, "trailer", "极速巅峰_宣传片_章节版.mp4")
BGM = os.path.join(PROJ, "maps", "audio", "bgm")

W, H, FPS = 1920, 1080, 30
DISSOLVE = 12                       # 段间交叉溶解帧数

# ---------------------------------------------------------------------------
# 调色与字体（Heiti SC 取 index 1，简体字形）
# ---------------------------------------------------------------------------
DARK_BG = (9, 11, 14)
INK = (242, 246, 250)
MUTED = (150, 168, 178)
DIM = (86, 100, 110)
CYAN = (79, 233, 255)
CYAN_DIM = (40, 128, 146)
LIGHT_BG = (241, 243, 244)
LIGHT_INK = (16, 20, 24)
LIGHT_MUTED = (88, 102, 112)
TEAL = (11, 132, 136)

F_CN = ("/System/Library/Fonts/STHeiti Medium.ttc", 1)          # Heiti SC Medium
F_CN_L = ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0)      # W3
F_CN_M = ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2)      # W6
F_EN = ("/System/Library/Fonts/Supplemental/Avenir Next.ttc", 0)  # Bold

_fc = {}


def fcn(size):
    return _font(size, F_CN)


def fcn_l(size):
    return _font(size, F_CN_L)


def fcn_m(size):
    return _font(size, F_CN_M)


def fen(size):
    return _font(size, F_EN)


def _font(size, face):
    key = (size, face[0], face[1])
    if key not in _fc:
        _fc[key] = ImageFont.truetype(face[0], size, index=face[1])
    return _fc[key]


def ease(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def ease_out(x):
    x = max(0.0, min(1.0, x))
    return 1.0 - (1.0 - x) ** 3


def rgba(c, a):
    return (c[0], c[1], c[2], int(max(0, min(255, a))))


def tracking(d, xy, text, font, fill, gap=0):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=font, fill=fill)
        x += d.textlength(ch, font=font) + gap
    return x


def track_w(font, text, gap=0):
    return sum(font.getlength(ch) + gap for ch in text) - gap


def text_h(font):
    a, b = font.getmetrics()
    return a + b


# ---------------------------------------------------------------------------
# 背景
# ---------------------------------------------------------------------------
def make_dark_bg():
    base = Image.new("RGB", (W, H), DARK_BG)
    d = ImageDraw.Draw(base)
    for x in range(0, 1240, 4):
        v = 13.0 * (1.0 - x / 1240.0) ** 2
        d.line((x, 0, x, H), fill=(9 + int(v * 0.25), 11 + int(v * 0.7), 14 + int(v * 1.5)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse((-520, H - 620, 700, H + 620), fill=44)
    glow = glow.filter(ImageFilter.GaussianBlur(180))
    tint = Image.new("RGB", (W, H), (17, 92, 108))
    return Image.composite(tint, base, glow)


def make_light_bg():
    base = Image.new("RGB", (W, H), LIGHT_BG)
    d = ImageDraw.Draw(base)
    for y in range(0, H, 4):
        v = 6.0 * (y / H) ** 2
        d.line((0, y, W, y), fill=(int(241 - v), int(243 - v), int(244 - v * 1.2)))
    return base


DARK_BG_IMG = make_dark_bg()
LIGHT_BG_IMG = make_light_bg()


_scrim_l = {}
_scrim_b = {}


def scrim_left(img, width, strength, height=None):
    """左侧压暗渐变，保证叠在实拍上的文字可读（渐变本身按参数缓存）。"""
    key = (width, strength, height or H)
    s = _scrim_l.get(key)
    if s is None:
        hh = key[2]
        s = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(s)
        for x in range(0, width, 4):
            sd.rectangle((x, 0, x + 4, hh),
                         fill=(4, 6, 9, int(strength * (1 - x / width) ** 1.6)))
        _scrim_l[key] = s
    return Image.alpha_composite(img, s)


def scrim_bottom(img, band, strength):
    key = (band, strength)
    s = _scrim_b.get(key)
    if s is None:
        s = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(s)
        for y in range(H - band, H, 4):
            sd.rectangle((0, y, W, y + 4),
                         fill=(4, 6, 9, int(strength * ((y - (H - band)) / band))))
        _scrim_b[key] = s
    return Image.alpha_composite(img, s)


# ---------------------------------------------------------------------------
# 帧序列
# ---------------------------------------------------------------------------
_cache = {}


def frame(shot, idx, tw, th, zoom=1.0, ox=0.5, oy=0.5):
    key = (shot, idx, tw, th, round(zoom, 3), ox, oy)
    hit = _cache.get(key)
    if hit is not None:
        return hit
    path = os.path.join(SEQ, shot, f"{idx + 1:04d}.jpg")
    if not os.path.exists(path):
        path = os.path.join(SEQ, shot, "0001.jpg")
    im = Image.open(path).convert("RGB")
    sw, sh = im.size
    scale = max(tw / sw, th / sh) * zoom
    nw, nh = int(sw * scale + 0.5), int(sh * scale + 0.5)
    im = im.resize((nw, nh), Image.LANCZOS)
    cx = min(max(0, int((nw - tw) * ox)), nw - tw)
    cy = min(max(0, int((nh - th) * oy)), nh - th)
    im = im.crop((cx, cy, cx + tw, cy + th))
    if len(_cache) > 4:
        _cache.clear()
    _cache[key] = im
    return im


_lens = {}


def shot_len(shot):
    if shot not in _lens:
        d = os.path.join(SEQ, shot)
        _lens[shot] = max(1, len([p for p in os.listdir(d) if p.endswith(".jpg")]))
    return _lens[shot]


def play(i, stride=1.15, shot=""):
    """按输出帧号映射到素材帧号，并夹在素材长度内。"""
    return min(shot_len(shot) - 1, int(i * stride))


# ---------------------------------------------------------------------------
# 常驻版式
# ---------------------------------------------------------------------------
BRAND = "APEX VELOCITY"
BRAND_CN = "极速巅峰"


def chrome(img, tag, light=False, alpha=1.0):
    if alpha <= 0.01:
        return img
    d = ImageDraw.Draw(img, "RGBA")
    ink = LIGHT_INK if light else INK
    mut = LIGHT_MUTED if light else MUTED
    a = 255 * alpha
    tracking(d, (76, 50), BRAND, fen(26), rgba(ink, a), gap=7)
    xw = 76 + track_w(fen(26), BRAND, 7) + 28
    d.text((xw, 56), BRAND_CN, font=fcn_l(19), fill=rgba(mut, a * 0.85))
    if tag:
        tw = track_w(fen(17), tag, 5)
        tracking(d, (W - 76 - tw, 56), tag, fen(17), rgba(mut, a * 0.9), gap=5)
    return img


_shadow = {}


def soft_shadow(w, h, radius=14, alpha=110, pad=12, drop=3):
    """按尺寸缓存一块柔和投影，避免每帧重做大半径高斯模糊。"""
    key = (w, h, radius, alpha)
    img = _shadow.get(key)
    if img is None:
        if len(_shadow) > 24:
            _shadow.clear()
        img = Image.new("RGBA", (w + pad * 2, h + pad * 2 + drop), (0, 0, 0, 0))
        ImageDraw.Draw(img).rounded_rectangle((pad, pad + drop, pad + w, pad + h + drop),
                                              radius=12, fill=(0, 0, 0, alpha))
        img = img.filter(ImageFilter.GaussianBlur(radius))
        _shadow[key] = img
    return img


def caption(img, text, alpha=1.0, light=False):
    if not text or alpha <= 0.02:
        return img
    d = ImageDraw.Draw(img, "RGBA")
    font = fcn(31)
    tw = d.textlength(text, font=font)
    pad_x, pad_y = 32, 16
    bw, bh = int(tw + pad_x * 2), int(text_h(font) + pad_y * 2)
    x0, y0 = (W - bw) // 2, H - 128
    sh = soft_shadow(bw, bh, 14, 110)
    if alpha > 0.35:
        img.paste(sh, (x0 - sh.width // 2 + bw // 2, y0 - sh.height // 2 + bh // 2 + 4), sh)
    fill = (12, 16, 20, int(228 * alpha)) if light else (10, 14, 18, int(235 * alpha))
    d.rounded_rectangle((x0, y0, x0 + bw, y0 + bh), radius=12, fill=fill)
    d.text((x0 + pad_x, y0 + pad_y - 3), text, font=font, fill=rgba(INK, 255 * alpha))
    return img


def eyebrow(d, xy, text, light=False, alpha=1.0, size=21, gap=6):
    if alpha <= 0.01:
        return
    col = TEAL if light else CYAN
    tracking(d, xy, text, fen(size), rgba(col, 240 * alpha), gap=gap)


def eyebrow_c(d, cx, y, text, light=False, alpha=1.0, size=21, gap=6):
    if alpha <= 0.01:
        return
    wpx = track_w(fen(size), text, gap)
    eyebrow(d, (cx - wpx / 2, y), text, light=light, alpha=alpha, size=size, gap=gap)


def headline(d, xy, lines, size=86, light=False, alpha=1.0, lh=None, stroke=2):
    """两行大字，逐行淡入上移。stroke 让 Heiti 更接近参考片的黑体重量。"""
    lh = lh or int(size * 1.22)
    ink = LIGHT_INK if light else INK
    y = xy[1]
    for i, ln in enumerate(lines):
        a = ease((alpha - i * 0.14) / max(0.001, 1 - i * 0.14))
        dy = (1 - ease_out(a)) * 34
        d.text((xy[0], y + dy), ln, font=fcn(size), fill=rgba(ink, 255 * a),
               stroke_width=stroke, stroke_fill=rgba(ink, 255 * a))
        y += lh
    return y


def headline_c(d, cx, y, lines, size=92, alpha=1.0, lh=None):
    lh = lh or int(size * 1.2)
    yy = y
    for i, ln in enumerate(lines):
        a = ease((alpha - i * 0.14) / max(0.001, 1 - i * 0.14))
        wln = d.textlength(ln, font=fcn(size))
        dy = (1 - ease_out(a)) * 28
        d.text((cx - wln / 2, yy + dy), ln, font=fcn(size), fill=rgba(INK, 255 * a),
               stroke_width=2, stroke_fill=rgba(INK, 255 * a))
        yy += lh
    return yy


def subline(d, xy, text, light=False, alpha=1.0, size=29, center=None):
    if not text or alpha <= 0.01:
        return
    mut = LIGHT_MUTED if light else MUTED
    if center is not None:
        wln = d.textlength(text, font=fcn_l(size))
        xy = (center - wln / 2, xy[1])
    d.text(xy, text, font=fcn_l(size), fill=rgba(mut, 245 * alpha))


def bullets(d, xy, items, light=False, alpha=1.0, gap=54):
    if not items:
        return
    ink = LIGHT_INK if light else INK
    numc = TEAL if light else CYAN
    y = xy[1]
    for i, it in enumerate(items):
        a = ease((alpha - i * 0.18) / max(0.001, 1 - i * 0.18))
        d.text((xy[0], y), f"{i + 1:02d}", font=fen(20), fill=rgba(numc, 235 * a))
        d.text((xy[0] + 48, y - 3), it, font=fcn_m(28), fill=rgba(ink, 250 * a))
        y += gap
    return y


import math

ICON_LABEL = "图标行：与参考片文字栏下方一排线性图标同位。"


def icon_row(d, xy, items, alpha=1.0, gap=176):
    x, y = xy
    for i, (kind, label) in enumerate(items):
        a = ease((alpha - i * 0.16) / max(0.001, 1 - i * 0.16))
        if a <= 0.01:
            x += gap
            continue
        col = rgba(MUTED, 235 * a)
        cx, cy = x + 26, y + 26
        if kind == "engine":
            d.rectangle((cx - 22, cy - 12, cx + 12, cy + 14), outline=col, width=3)
            d.line((cx + 12, cy - 4, cx + 22, cy - 4), fill=col, width=3)
            d.line((cx + 22, cy - 4, cx + 22, cy + 8), fill=col, width=3)
            d.line((cx - 12, cy - 12, cx - 12, cy - 20), fill=col, width=3)
        elif kind == "gear":
            d.ellipse((cx - 16, cy - 16, cx + 16, cy + 16), outline=col, width=3)
            d.ellipse((cx - 5, cy - 5, cx + 5, cy + 5), outline=col, width=3)
            for ang in range(0, 360, 60):
                px, py = math.cos(math.radians(ang)), math.sin(math.radians(ang))
                d.line((cx + px * 16, cy + py * 16, cx + px * 22, cy + py * 22), fill=col, width=3)
        elif kind == "weight":
            d.polygon([(cx - 20, cy + 14), (cx + 20, cy + 14), (cx + 12, cy - 8), (cx - 12, cy - 8)],
                      outline=col)
            d.arc((cx - 10, cy - 26, cx + 10, cy - 6), 180, 360, fill=col, width=3)
        elif kind == "track":
            d.line((cx - 22, cy + 12, cx - 6, cy - 14), fill=col, width=3)
            d.line((cx - 6, cy - 14, cx + 8, cy + 6), fill=col, width=3)
            d.line((cx + 8, cy + 6, cx + 22, cy - 12), fill=col, width=3)
        elif kind == "sun":
            d.ellipse((cx - 12, cy - 12, cx + 12, cy + 12), outline=col, width=3)
            for ang in range(0, 360, 45):
                px, py = math.cos(math.radians(ang)), math.sin(math.radians(ang))
                d.line((cx + px * 16, cy + py * 16, cx + px * 22, cy + py * 22), fill=col, width=2)
        elif kind == "wave":
            pts = [(cx - 22 + k, cy + math.sin(k / 4.2) * (10 if k % 9 < 5 else 4))
                   for k in range(45)]
            d.line(pts, fill=col, width=3)
        elif kind == "screen":
            d.rectangle((cx - 22, cy - 15, cx + 22, cy + 13), outline=col, width=3)
            d.line((cx - 8, cy + 20, cx + 8, cy + 20), fill=col, width=3)
            d.line((cx, cy + 13, cx, cy + 20), fill=col, width=3)
        elif kind == "flag":
            d.line((cx - 18, cy - 20, cx - 18, cy + 18), fill=col, width=3)
            for k in range(3):
                for j in range(3):
                    if (k + j) % 2 == 0:
                        d.rectangle((cx - 14 + k * 11, cy - 18 + j * 11,
                                     cx - 14 + k * 11 + 10, cy - 18 + j * 11 + 10),
                                    outline=col, width=2)
        d.text((x, y + 62), label, font=fcn_l(23), fill=rgba(MUTED, 240 * a))
        x += gap


# ---------------------------------------------------------------------------
# 设备 mockup
# ---------------------------------------------------------------------------
def laptop(img, box, scr, callout=None):
    """box = 屏幕内容区 (x0,y0,x1,y1)；scr 为已裁好的画面。"""
    x0, y0, x1, y1 = box
    sw, sh = x1 - x0, y1 - y0
    d = ImageDraw.Draw(img, "RGBA")
    sd = soft_shadow(sw + 40, sh + 28, 26, 135)
    img.paste(sd, (x0 - 20, y0 + 30 - sd.height // 2 + (sh + 28) // 2), sd)
    bez = 15
    d.rounded_rectangle((x0 - bez, y0 - bez, x1 + bez, y1 + bez), radius=16,
                        fill=(22, 26, 30, 255), outline=(56, 62, 68, 255), width=2)
    d.rounded_rectangle((x0 + sw // 2 - 46, y0 - bez + 4, x0 + sw // 2 + 46, y0 - bez + 12),
                        radius=4, fill=(12, 14, 16, 255))
    img.paste(scr, (x0, y0))
    d.rounded_rectangle((x0 - 76, y1 + bez, x1 + 76, y1 + bez + 24), radius=9,
                        fill=(178, 185, 192, 255), outline=(118, 125, 132, 255), width=1)
    d.rectangle((x0 + sw // 2 - 70, y1 + bez, x0 + sw // 2 + 70, y1 + bez + 6),
                fill=(138, 145, 152, 255))
    if callout:
        cw, ch = callout.get("w", 430), callout.get("h", 214)
        cx = callout.get("x", x1 - cw - 34)
        cy = callout.get("y", y0 + 34)
        d.rounded_rectangle((cx, cy, cx + cw, cy + ch), radius=12,
                            fill=(8, 14, 18, 234), outline=(79, 233, 255, 235), width=2)
        eyebrow(d, (cx + 22, cy + 20), callout["tag"], alpha=1.0, size=17, gap=4)
        d.text((cx + 22, cy + 54), callout["title"], font=fcn(29), fill=rgba(INK, 255))
        yy = cy + 102
        for ln in callout.get("lines", []):
            d.text((cx + 22, yy), ln, font=fcn_l(22), fill=rgba(MUTED, 240))
            yy += 31
    return img


# ---------------------------------------------------------------------------
# 字幕调度
# ---------------------------------------------------------------------------
def cap_state(caps, i):
    """返回 (文本, 透明度)：每条字幕进出各 0.28s 淡入淡出。"""
    sec = i / FPS
    for s, e, txt in caps:
        if s <= sec < e:
            a = min(1.0, (sec - s) / 0.28, (e - sec) / 0.28)
            return txt, ease(max(0.0, a))
    if caps and sec >= caps[-1][1]:
        return caps[-1][2], 1.0
    return "", 0.0


# ---------------------------------------------------------------------------
# 分镜类型
# ---------------------------------------------------------------------------
def seg_film_open(p, n):
    shot, title, en = p["shot"], p["title"], p["en"]
    tags, caps = p["tags"], p["caps"]
    for i in range(n):
        t = i / max(1, n - 1)
        img = frame(shot, play(i, 1.2, shot), W, H, zoom=1.10 + 0.04 * t, ox=0.34,
                    oy=0.5).convert("RGBA")
        img = scrim_left(img, 1500, 215)
        img = scrim_bottom(img, 260, 150)
        d = ImageDraw.Draw(img, "RGBA")
        a = ease(t / 0.3)
        eyebrow(d, (110, 296), "GODOT 4 · NATIVE RACING ENGINE", alpha=a, size=23, gap=8)
        d.text((104, 340), title, font=fcn(132), fill=rgba(INK, 255 * a),
               stroke_width=3, stroke_fill=rgba(INK, 255 * a))
        tracking(d, (112, 536), en, fen(42), rgba(CYAN, 250 * ease((t - 0.1) / 0.35)), gap=14)
        d.line((112, 604, 112 + 470 * ease((t - 0.16) / 0.4), 604), fill=rgba(CYAN, 130), width=2)
        yy = 630
        for j, ln in enumerate(tags):
            aa = ease((t - 0.22 - j * 0.09) / 0.35)
            d.text((112, yy), ln, font=fcn_l(32), fill=rgba(MUTED, 250 * aa))
            yy += 50
        chrome(img, "", alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


def seg_statement(p, n):
    lines, sub, tag, caps = p["lines"], p.get("sub", ""), p["tag"], p["caps"]
    for i in range(n):
        t = i / max(1, n - 1)
        img = DARK_BG_IMG.copy().convert("RGBA")
        d = ImageDraw.Draw(img, "RGBA")
        a = ease(t / 0.26)
        eyebrow_c(d, W // 2, 268, tag, alpha=a, size=22, gap=7)
        y_end = headline_c(d, W // 2, 330, lines, size=98, alpha=a)
        if sub:
            subline(d, (0, y_end + 34), sub, alpha=ease((t - 0.28) / 0.4), size=30, center=W // 2)
        chrome(img, tag, alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


def seg_pipeline(p, n):
    lines, tag, steps = p["lines"], p["tag"], p["steps"]
    expl, caps = p.get("expl", ""), p["caps"]
    for i in range(n):
        t = i / max(1, n - 1)
        img = DARK_BG_IMG.copy().convert("RGBA")
        d = ImageDraw.Draw(img, "RGBA")
        a = ease(t / 0.26)
        eyebrow_c(d, W // 2, 236, tag, alpha=a, size=21, gap=6)
        headline_c(d, W // 2, 296, lines, size=92, alpha=a, lh=112)
        colw, gap = 300, 26
        total = colw * len(steps) + gap * (len(steps) - 1)
        x0 = (W - total) // 2
        ytop = 560
        for k, (en, cn) in enumerate(steps):
            on = ease((t - 0.26 - k * 0.12) / 0.16)
            cx = x0 + k * (colw + gap)
            d.line((cx, ytop, cx + colw, ytop), width=3,
                   fill=rgba(CYAN, int(80 + 170 * on)) if on > 0.4 else rgba(DIM, 150))
            eyebrow_c(d, cx + colw // 2, ytop + 28, en, alpha=0.3 + 0.7 * on, size=19, gap=5)
            wcn = d.textlength(cn, font=fcn(32))
            d.text((cx + (colw - wcn) / 2, ytop + 60), cn, font=fcn(32),
                   fill=rgba(INK if on > 0.4 else DIM, int(130 + 125 * on)))
        if expl:
            subline(d, (0, ytop + 152), expl, alpha=ease((t - 0.55) / 0.35), size=28, center=W // 2)
        chrome(img, tag, alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


def seg_panel(p, n):
    tag, lines = p["tag"], p["lines"]
    sub = p.get("sub", "")
    icons, blts, caps = p.get("icons", []), p.get("bullets", []), p["caps"]
    shot, callout = p["shot"], p.get("callout")
    light, rev = p.get("light", False), p.get("reverse", False)
    for i in range(n):
        t = i / max(1, n - 1)
        img = (LIGHT_BG_IMG if light else DARK_BG_IMG).copy().convert("RGBA")
        zoom = 1.02 + 0.05 * t
        idx = play(i, 1.0 if shot_len(shot) < n else 1.15, shot)
        sw, sh = 880, 495
        scr = frame(shot, idx, sw, sh, zoom=zoom, ox=0.5 + (0.03 * (0.5 - t)), oy=0.5)
        if rev:
            box = (110, 258, 110 + sw, 258 + sh)
            img = laptop(img, box, scr, callout=None)
            tx = 1130
        else:
            box = (1010, 240, 1010 + sw, 240 + sh)
            co = dict(callout) if callout else None
            img = laptop(img, box, scr, callout=co)
            tx = 110
        d = ImageDraw.Draw(img, "RGBA")
        a = ease(t / 0.28)
        eyebrow(d, (tx, 296), tag, light=light, alpha=a, size=21, gap=6)
        y_end = headline(d, (tx, 344), lines, size=86, light=light, alpha=a)
        if sub:
            subline(d, (tx, y_end + 26), sub, light=light, alpha=ease((t - 0.14) / 0.4), size=28)
        iy = y_end + (66 if sub else 34)
        if icons:
            icon_row(d, (tx, iy + 16), icons, alpha=ease((t - 0.22) / 0.4))
        if blts:
            bullets(d, (tx, iy + 8), blts, light=light, alpha=ease((t - 0.22) / 0.4))
        chrome(img, tag, light=light, alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca, light=light)
        yield img.convert("RGB")


def seg_bleed(p, n):
    shot, tag, caps = p["shot"], p["tag"], p["caps"]
    lines, blts = p.get("lines", []), p.get("bullets", [])
    for i in range(n):
        t = i / max(1, n - 1)
        img = frame(shot, play(i, 1.2, shot), W, H, zoom=1.02 + 0.04 * t,
                    ox=0.5 + 0.06 * (t - 0.5), oy=0.52).convert("RGBA")
        if lines:
            img = scrim_left(img, 1180, 205)
        img = scrim_bottom(img, 300, 125)
        d = ImageDraw.Draw(img, "RGBA")
        if lines:
            a = ease(t / 0.28)
            eyebrow(d, (110, 414), tag, alpha=a, size=21, gap=6)
            y_end = headline(d, (110, 462), lines, size=84, alpha=a)
            if blts:
                bullets(d, (110, y_end + 26), blts, alpha=ease((t - 0.2) / 0.4), gap=52)
        chrome(img, tag, alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


def seg_strip(p, n):
    tag, lines, caps, cells = p["tag"], p["lines"], p["caps"], p["cells"]
    for i in range(n):
        t = i / max(1, n - 1)
        img = DARK_BG_IMG.copy().convert("RGBA")
        d = ImageDraw.Draw(img, "RGBA")
        a = ease(t / 0.26)
        eyebrow(d, (110, 206), tag, alpha=a, size=21, gap=6)
        headline(d, (110, 252), lines, size=78, alpha=a)
        pw, ph, gap = 566, 318, 20
        x0 = (W - (pw * 3 + gap * 2)) // 2
        y0 = 470
        for k, c in enumerate(cells):
            aa = ease((t - 0.08 - k * 0.1) / 0.36)
            s = c["shot"]
            idx = play(i + k * 22, 1.2, s)
            cx = x0 + k * (pw + gap)
            sd = soft_shadow(pw + 12, ph + 36, 16, 130)
            img.paste(sd, (cx - 6, y0 + 12 - sd.height // 2 + (ph + 36) // 2), sd)
            d.rounded_rectangle((cx - 6, y0 - 6, cx + pw + 6, y0 + ph + 6), radius=10,
                                fill=(20, 24, 28, int(255 * aa)))
            img.paste(frame(s, idx, pw, ph, zoom=1.04 + 0.03 * t), (cx, y0))
            d.text((cx + 2, y0 + ph + 24), c["cn"], font=fcn(27), fill=rgba(INK, 250 * aa))
            d.text((cx + 2, y0 + ph + 62), c["en"], font=fen(17), fill=rgba(CYAN_DIM, 240 * aa))
        chrome(img, tag, alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


def _ab_label(d, x, right, t1, t2, a):
    """A/B 两端的画质标签：压在暗色底板上，避免落日高光把字吃掉。"""
    f1, f2 = fcn(30), fcn_l(23)
    w = max(d.textlength(t1, font=f1), d.textlength(t2, font=f2))
    x0 = x - w if right else x
    d.rounded_rectangle((x0 - 24, H - 252, x0 + w + 24, H - 158), radius=14,
                        fill=(8, 11, 15, int(175 * a)))
    for txt, ft, col, y in ((t1, f1, (245, 250, 255), H - 234),
                            (t2, f2, (170, 205, 218), H - 192)):
        tx = x - d.textlength(txt, font=ft) if right else x
        d.text((tx, y), txt, font=ft, fill=rgba(col, 250 * a))


def seg_compare(p, n):
    tag, lines, caps = p["tag"], p["lines"], p["caps"]
    lo, hi = p["low"], p["high"]
    for i in range(n):
        t = i / max(1, n - 1)
        a = ease(t / 0.24)
        # 起手居中让两档同时可见，中段再缓慢推向低画质一侧
        wipe = int(W * (0.48 + 0.20 * ease_out(max(0.0, (t - 0.28) / 0.55))))
        img = frame(hi, play(i, 1.2, hi), W, H, zoom=1.05).convert("RGBA")
        left = frame(lo, play(i, 1.2, lo), W, H, zoom=1.05)
        mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(mask).rectangle((0, 0, wipe, H), fill=255)
        img.paste(left, (0, 0), mask)
        img = scrim_left(img, 1240, 225, height=560)
        d = ImageDraw.Draw(img, "RGBA")
        d.line((wipe, 0, wipe, H), fill=rgba(CYAN, 235), width=3)
        d.ellipse((wipe - 13, H // 2 - 13, wipe + 13, H // 2 + 13), fill=rgba(CYAN, 235))
        eyebrow(d, (110, 206), tag, alpha=a, size=21, gap=6)
        headline(d, (110, 252), lines, size=76, alpha=a)
        _ab_label(d, 110, False, "低画质 LOW", "0.8× 逻辑分辨率 · 后处理全关", a)
        _ab_label(d, W - 110, True, "极致画质 ULTRA", "1.4× 逻辑分辨率 · SSR / SSAO / 体积雾", a)
        chrome(img, tag, alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


def seg_logo_out(p, n):
    shot, caps = p["shot"], p["caps"]
    for i in range(n):
        t = i / max(1, n - 1)
        img = frame(shot, play(i, 1.2, shot), W, H, zoom=1.02 + 0.05 * t,
                    ox=0.5 + 0.04 * (t - 0.5), oy=0.5).convert("RGBA")
        img = scrim_left(img, 1240, 200)
        img = scrim_bottom(img, 540, 170)
        d = ImageDraw.Draw(img, "RGBA")
        x0, cy = 200, H // 2 - 40
        grow = ease(t / 0.2)
        fade = 1.0 - ease((t - 0.86) / 0.14)

        def al(v):
            return int(max(0, min(255, v * fade)))

        bar_h = 236 * grow
        d.rounded_rectangle((x0, cy - bar_h / 2, x0 + 7, cy + bar_h / 2), radius=3,
                            fill=rgba(CYAN, al(255)))
        bx = x0 + 46
        slide = (1.0 - ease((t - 0.05) / 0.28)) * 46
        alpha = ease((t - 0.08) / 0.28)
        tracking(d, (bx + slide, cy - 132), BRAND, fen(98), rgba(INK, al(255 * alpha)), gap=5)
        tracking(d, (bx + 4, cy + 6), BRAND_CN, fcn_l(46),
                 rgba((200, 236, 246), al(255 * ease((t - 0.18) / 0.28))), gap=13)
        d.line((bx, cy + 86, bx + 560 * ease((t - 0.28) / 0.28), cy + 86),
               fill=rgba(CYAN, al(130)), width=2)
        s1 = ease((t - 0.34) / 0.28)
        d.text((bx, cy + 110), "45 台真车   ·   11 条赛道   ·   改装工厂   ·   本地双人",
               font=fcn_l(28), fill=rgba(INK, al(255 * s1)))
        s2 = ease((t - 0.44) / 0.28)
        d.text((bx, cy + 160), "把每一条路，跑成自己的纪录",
               font=fcn_l(26), fill=rgba(MUTED, al(245 * s2)))
        s3 = ease((t - 0.54) / 0.28)
        tracking(d, (bx, cy + 216), "GODOT 4 · MACOS / WINDOWS / ANDROID",
                 fen(19), rgba(CYAN_DIM, al(235 * s3)), gap=5)
        chrome(img, "", alpha=ease(t / 0.2))
        txt, ca = cap_state(caps, i)
        caption(img, txt, alpha=ca)
        yield img.convert("RGB")


SEG = {
    "film_open": seg_film_open,
    "statement": seg_statement,
    "pipeline": seg_pipeline,
    "panel": seg_panel,
    "bleed": seg_bleed,
    "strip": seg_strip,
    "compare": seg_compare,
    "logo_out": seg_logo_out,
}


# ---------------------------------------------------------------------------
# 时间线（帧为单位，30fps）
# ---------------------------------------------------------------------------
T = []


def add(kind, frames, **kw):
    T.append(dict(kind=kind, frames=frames, **kw))


# ACT 0 · 品牌
add("film_open", 200, shot="OPEN_CITY", title="极速巅峰", en="APEX VELOCITY",
    tags=["45 台可驾驶真车 · 11 条赛道", "路面、地形、植被、建筑全部运行时生成"],
    caps=((0.0, 3.4, "这是一台 Godot 4 原生重制的赛车游戏。"),
          (3.4, 6.6, "画面里的每一条路，都是运行时算出来的。")))

# ACT 1 · 真车
add("statement", 110, tag="01 / REAL CARS", lines=["一台车，", "不是数值贴图"],
    sub="功率 · 扭矩 · 质量 · 驱动 · 极速 · 0-100",
    caps=((0.0, 3.6, "每台车都按真车资料标定。"),))
add("panel", 170, tag="01 / REAL CARS", lines=["逐台标定，", "跑起来才不一样"],
    sub="45 台车逐台标定 · 45 份引擎声档案 · 7 类改装零件",
    icons=[("engine", "引擎构型"), ("gear", "变速箱"), ("weight", "整备质量")],
    shot="GARAGE",
    callout={"tag": "SPEC", "title": "真车参数", "w": 430, "h": 214,
             "lines": ["590 hp / 700 N·m", "1300 kg · RWD · 直六", "0-100 3.0s · 极速 300"]},
    caps=((0.0, 3.4, "马力、扭矩、车重、驱动形式，全部来自真车。"),
          (3.4, 5.6, "车库里读到的参数，就是路上跑出来的参数。")))
add("panel", 170, tag="01 / REAL CARS", lines=["7 类改装，", "一台车好几种活法"],
    sub="改装会改到重量、下压力与抓地，不只是外观",
    bullets=["轮毂 / 轮胎 / 卡钳 / 尾翼", "涂装、零件与调校一并存档"],
    shot="GARAGE_GRID", light=True, reverse=True,
    caps=((0.0, 3.2, "换掉宽体套件，车重和下压力都会变。"),
          (3.2, 5.6, "同一台车，能调出两种不同的性格。")))

# ACT 2 · 程序化赛道
add("statement", 110, tag="02 / PROCEDURAL TRACKS", lines=["一条赛道，", "由一段数据生成"],
    sub="路面 · 地形 · 植被 · 建筑 · 看台 · 龙门架",
    caps=((0.0, 3.6, "游戏里没有一屏是手搭出来的。"),))
add("pipeline", 150, tag="02 / PROCEDURAL TRACKS", lines=["一张 JSON，", "跑出一条赛道"],
    steps=[("DATA", "赛道数据"), ("GEOMETRY", "路面地形"), ("LIGHTING", "光照天气"),
           ("GAMEPLAY", "起跑可玩")],
    expl="运行时按 data/tracks.json 与主题生成，改数据就能改赛道",
    caps=((0.0, 3.4, "数据先定义中心线、路宽和坡度，"),
          (3.4, 5.0, "再由生成器补上地形、植被、建筑与光照。")))
add("panel", 170, tag="02 / PROCEDURAL TRACKS", lines=["11 种地貌，", "11 套光照"],
    sub="9 条封闭赛道 + 都会环线实景城市 + 漂移练习场",
    bullets=["每条图独立太阳角度与雾", "独立天气：雨 / 雪 / 沙尘 / 极光", "菜单背景就是这条图的实景"],
    shot="ARCHIVE",
    caps=((0.0, 3.4, "雪山和夜城用的不是同一套光照。"),
          (3.4, 5.6, "同一台车，在雪线和雨夜里是两种抓地。")))
add("bleed", 140, tag="02 / PROCEDURAL TRACKS", shot="PANO_GLACIER",
    lines=["从正午碧海，", "到霓虹雨夜"],
    caps=((0.0, 4.6, "亮度与色温逐级下降，速度感逐级上升。"),))

# ACT 3 · 物理
add("statement", 110, tag="03 / ARCADE PHYSICS", lines=["打滑、推头、甩尾，", "都是算出来的"],
    sub="扭矩负载起步 · 速度敏感转向 · OBB 车-车碰撞",
    caps=((0.0, 3.6, "起步多给一点油，后轮会先走。"),))
add("panel", 170, tag="03 / ARCADE PHYSICS", lines=["手感，", "是一层层调出来的"],
    sub="从轮胎负载到车身分离，全部在物理帧里算",
    bullets=["手动挡与氮气，转速自己管", "贴得太近会被推开，不会粘住", "磁轴键盘与手柄震动分级"],
    shot="DRIFT",
    caps=((0.0, 3.4, "轮胎负载决定抓地，抓地决定车尾走不走。"),
          (3.4, 5.6, "缠斗时防粘连会把两车分开，而不是卡在一起。")))
add("strip", 160, tag="03 / ARCADE PHYSICS", lines=["三种极限时刻"],
    cells=[{"shot": "DRIFT", "cn": "甩尾", "en": "DRIFT"},
           {"shot": "NITRO", "cn": "氮气", "en": "NITRO"},
           {"shot": "PACK", "cn": "缠斗", "en": "WHEEL TO WHEEL"}],
    caps=((0.0, 5.3, "漂移、氮气、缠斗，跑在同一套物理上。"),))
add("bleed", 120, tag="03 / ARCADE PHYSICS", shot="COCKPIT", lines=["坐进去，", "速度是另一回事"],
    caps=((0.0, 4.0, "第一视角没有车身遮挡，路面直接扑到脸上。"),))

# ACT 4 · 画面
add("statement", 110, tag="04 / RENDERING", lines=["四档画质，", "一套光照语言"],
    sub="程序化天空 · 流动云 · 体积雾 · 速度拉丝",
    caps=((0.0, 3.6, "暗调电影感的光影，是所有赛道的底座。"),))
add("compare", 150, tag="04 / RENDERING", lines=["同一机位，", "两档画面"],
    low="QUAL_LOW", high="QUAL_ULTRA",
    caps=((0.0, 3.4, "低档只保帧率：0.8× 逻辑分辨率，后处理全关。"),
          (3.4, 5.0, "超高档把反射、环境光遮蔽和体积雾全部打开。")))
add("panel", 170, tag="04 / RENDERING", lines=["画质，", "在游戏里随时切"],
    sub="设置里每一项后处理都是可开关的档位",
    bullets=["渲染缩放 / TAA / MSAA", "SSR · SSAO · 体积雾 · 树影", "植被密度与阴影距离分级"],
    shot="SETTINGS_GAME", light=True, reverse=True,
    caps=((0.0, 3.2, "低端设备也能跑到稳定帧率，"),
          (3.2, 5.6, "高端设备直接吃满这套光照。")))

# ACT 5 · 声音
add("statement", 110, tag="05 / AUDIO", lines=["引擎声，", "是一台一台合成的"],
    sub="点火序 · 转速负载 · 涡轮啸叫 · 排气回火",
    caps=((0.0, 3.6, "V8、直六、转子，用的是不同构型。"),))
add("pipeline", 150, tag="05 / AUDIO", lines=["45 份声档案，", "16 首赛道 BGM"],
    steps=[("PROFILE", "引擎构型"), ("LOAD", "转速负载"), ("SYNTH", "实时合成"),
           ("MIX", "6 总线混音")],
    expl="引擎、风声、轮胎、音乐各自一条总线，混音在游戏内完成",
    caps=((0.0, 3.4, "声音不是循环素材，是每帧算出来的。"),
          (3.4, 5.0, "16 首原创 BGM，按赛道图分配。")))

# ACT 6 · 同屏与创作
add("bleed", 150, tag="06 / SHARED SCREEN", shot="DUEL", lines=["一台电脑，", "两个人同屏"],
    bullets=["独立相机各自跟车", "独立输入，同场竞速"],
    caps=((0.0, 4.0, "真分屏，不是把画面切成两半。"),))
add("panel", 170, tag="06 / SHARED SCREEN", lines=["赛道不只是跑，", "还能自己摆"],
    sub="场景装饰编辑器：点选、拖动、Ctrl+S 存回赛道",
    bullets=["树、建筑、道具都能挪能删", "没动过的仍走程序化生成"],
    shot="DECOR",
    caps=((0.0, 3.4, "编辑器里摆的东西，写进赛道数据。"),
          (3.4, 5.6, "回到比赛，位置和碰撞都在。")))

# ACT 7 · 成长
add("panel", 170, tag="07 / PROGRESSION", lines=["跑完一圈，", "纪录就是你的"],
    sub="圈速、名次、成就与赛道档案一并存档",
    bullets=["每图每车存前 5 快圈速", "成就解锁与车辆档案"],
    shot="RESULTS",
    caps=((0.0, 3.4, "结算会记下每一圈，"),
          (3.4, 5.6, "然后和之前的自己比。")))
add("statement", 110, tag="07 / PROGRESSION", lines=["圈速存在本地，", "不用登录"],
    caps=((0.0, 3.6, "45 台车，11 条赛道，等你跑完。"),))

# ACT 8 · 品牌收尾
add("logo_out", 200, shot="END_CITY",
    caps=((0.0, 3.2, "《极速巅峰》· Godot 4 原生重制版"),
          (3.2, 6.6, "双击开始游戏，剩下的路自己跑。")))


# ---------------------------------------------------------------------------
# 抽帧
# ---------------------------------------------------------------------------
def need_shots():
    used = set()
    for e in T:
        for k in ("shot", "low", "high"):
            if k in e:
                used.add(e[k])
        for c in e.get("cells", []):
            used.add(c["shot"])
    return used


def extract():
    os.makedirs(SEQ, exist_ok=True)
    for sid in sorted(need_shots()):
        avi = None
        for p in os.listdir(SHOTS):
            if p.startswith(sid + "_") and p.endswith(".avi"):
                avi = os.path.join(SHOTS, p)
                break
        dst = os.path.join(SEQ, sid)
        if not avi:
            print(f"[EXTRACT] MISSING {sid}", flush=True)
            continue
        os.makedirs(dst, exist_ok=True)
        if len([p for p in os.listdir(dst) if p.endswith(".jpg")]) > 30:
            continue
        subprocess.run([FF, "-y", "-hide_banner", "-loglevel", "error", "-i", avi,
                        "-q:v", "3", os.path.join(dst, "%04d.jpg")], check=True)
        print(f"[EXTRACT] {sid} -> {len(os.listdir(dst))} frames", flush=True)


# ---------------------------------------------------------------------------
# 渲染：逐帧喂给 ffmpeg，段间用上一段末尾帧做交叉溶解
# ---------------------------------------------------------------------------
def total_frames():
    return sum(e["frames"] for e in T) - DISSOLVE * (len(T) - 1)


def render(only=None):
    enc = [FF, "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
           "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
           "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "16",
           "-pix_fmt", "yuv420p", os.path.join(WORK, "film_silent.mp4")]
    proc = subprocess.Popen(enc, stdin=subprocess.PIPE)
    tail = []
    written = 0
    for ei, e in enumerate(T):
        if only and (ei + 1) not in only:
            continue
        gen = list(SEG[e["kind"]](e, e["frames"]))
        ds = min(DISSOLVE, len(tail), len(gen) - 1)
        for k in range(ds):
            proc.stdin.write(Image.blend(tail[k], gen[k], (k + 1) / (ds + 1)).tobytes())
            written += 1
        keep = DISSOLVE if len(gen) > DISSOLVE else 0
        for fr in gen[ds:len(gen) - keep]:
            proc.stdin.write(fr.tobytes())
            written += 1
        tail = gen[len(gen) - keep:] if keep else []
        print(f"[{ei + 1:02d}/{len(T)}] {e['kind']:10s} {e['frames']:4d}f  "
              f"{e.get('shot') or e.get('lines', [''])[0]}", flush=True)
        del gen
    proc.stdin.close()
    proc.wait()
    print(f"[RENDER] {written} frames = {written / FPS:.2f}s", flush=True)
    return written


def poster(idx):
    n = 0
    for e in T:
        for fr in SEG[e["kind"]](e, e["frames"]):
            if n == idx:
                path = os.path.join(WORK, f"poster_{idx:04d}.png")
                fr.save(path)
                print(f"[POSTER] {path}")
                return
            n += 1
    print(f"[POSTER] frame {idx} out of range ({n} total)")


# ---------------------------------------------------------------------------
# 音轨：apex.ogg → neon.ogg，1s 交叉淡化 + 全局淡入淡出
# ---------------------------------------------------------------------------
def build_audio(path, dur):
    import array
    import wave
    a1 = os.path.join(WORK, "a1.wav")
    a2 = os.path.join(WORK, "a2.wav")
    cross = 1.0
    switch = dur * 0.55
    subprocess.run([FF, "-y", "-hide_banner", "-loglevel", "error", "-stream_loop", "5",
                    "-i", os.path.join(BGM, "apex.ogg"), "-t", f"{switch + cross:.4f}",
                    "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", a1], check=True)
    subprocess.run([FF, "-y", "-hide_banner", "-loglevel", "error", "-stream_loop", "5",
                    "-i", os.path.join(BGM, "neon.ogg"), "-t", f"{dur - switch + cross:.4f}",
                    "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", a2], check=True)

    def read(p):
        with wave.open(p, "rb") as w:
            return w.getframerate(), w.getnchannels(), array.array("h", w.readframes(w.getnframes()))

    sr, ch, s1 = read(a1)
    _, _, s2 = read(a2)
    total = int(dur * sr) * ch
    mix = array.array("h", [0]) * total
    sw = int(switch * sr) * ch
    cw = int(cross * sr) * ch
    for k in range(min(len(s1), sw + cw, total)):
        mix[k] = s1[k]
    for k in range(min(len(s2), total - sw)):
        w2 = min(1.0, k / max(1, cw)) if k < cw else 1.0
        w1 = 1.0 - w2 if k < cw else 0.0
        idx = sw + k
        mix[idx] = max(-32768, min(32767, int(mix[idx] * w1 + s2[k] * w2)))
    fi, fo = int(0.8 * sr) * ch, int(1.4 * sr) * ch
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


def mux(dur):
    audio = os.path.join(WORK, "film_mix.wav")
    print("[AUDIO] mixing ...", flush=True)
    build_audio(audio, dur)
    subprocess.run([FF, "-y", "-hide_banner", "-loglevel", "error",
                    "-i", os.path.join(WORK, "film_silent.mp4"), "-i", audio,
                    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac",
                    "-b:a", "192k", "-shortest", OUT], check=True)
    print(f"[DONE] {OUT}  {os.path.getsize(OUT) / 1e6:.1f}MB", flush=True)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--extract" in args:
        extract()
        sys.exit(0)
    if "--poster" in args:
        extract()
        poster(int(args[args.index("--poster") + 1]))
        sys.exit(0)
    only = None
    if "--only" in args:
        rest = args[args.index("--only") + 1:]
        only = {int(a) for a in rest if a.isdigit()}
    extract()
    written = render(only=only)
    if not only:
        mux(total_frames() / FPS)
