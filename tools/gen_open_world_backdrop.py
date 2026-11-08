#!/usr/bin/env python3
"""生成「无界大陆」菜单背景图（res://assets/backdrops/open_world.png）。

这张图不是装饰性插画，而是开放世界地图的俯视示意图：岛形、八个区域、
主干道环线与放射支线都按 scripts/openworld/open_world.gd 里的同一套参数
生成，玩家在菜单里看到的布局就是进去之后真正会开到的布局。

用法：python3 tools/gen_open_world_backdrop.py
"""
from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "backdrops", "open_world.png")

W, H = 1920, 1080
MAP_PX = 1024            # 地图正方形边长
MAP_X0 = 448             # 地图左上角
MAP_Y0 = 16
WORLD = 9000.0           # 世界边长（米）
ISLAND_R = 3900.0
VOLCANO = (1732.0, -1732.0)
VOLCANO_R = 620.0
VOLCANO_H = 232.0
LAKE = (0.0, -2450.0)
LAKE_R = 430.0
LAKE_LEVEL = 26.0

# id, 中文, 英文, center, radius, kind, accent(rgb)
ZONES = [
    ("neon", "霓虹都市", "NEON CITY", (2450.0, 0.0), 1150.0, "urban", (255, 77, 141)),
    ("skyline", "天际环城", "SKYLINE RING", (1732.0, 1732.0), 1150.0, "urban", (255, 181, 71)),
    ("harbor", "落日港湾", "SUNSET PORT", (0.0, 2450.0), 1250.0, "urban", (255, 180, 94)),
    ("coast", "翡翠海岸", "EMERALD COAST", (-1732.0, 1732.0), 1250.0, "beach", (79, 233, 255)),
    ("canyon", "赤岩峡谷", "RED CANYON", (-2450.0, 0.0), 1250.0, "canyon", (255, 122, 61)),
    ("alpine", "雪山隘口", "ALPINE PASS", (-1732.0, -1732.0), 1200.0, "alpine", (159, 216, 255)),
    ("glacier", "冰川湖", "GLACIER LAKE", (0.0, -2450.0), 1200.0, "glacier", (127, 216, 255)),
    ("magma", "熔岩盆地", "MAGMA BASIN", (1732.0, -1732.0), 1100.0, "magma", (255, 122, 61)),
]
HUB = ("hub", "中央枢纽", "CENTRAL HUB", (0.0, 0.0), 620.0, "urban", (85, 231, 210))


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else (hi if v > hi else v)


def smoothstep(t):
    t = clamp(t)
    return t * t * (3.0 - 2.0 * t)


def island_shape(ang):
    return (1.0
            + 0.105 * math.sin(ang * 3.0 + 0.7)
            + 0.068 * math.sin(ang * 5.0 + 1.9)
            + 0.042 * math.sin(ang * 7.0 + 0.3)
            + 0.026 * math.sin(ang * 11.0 + 2.4))


def zone_weight(d, radius):
    inner = radius * 0.34
    outer = radius * 1.55
    if d <= inner:
        return 1.0
    if d >= outer:
        return 0.0
    t = (d - inner) / (outer - inner)
    return 1.0 - t * t * (3.0 - 2.0 * t)


def terrain_height(x, z):
    """与 open_world.gd 的 _terrain_at 同构的简化版（去掉 FastNoiseLite 细节）。"""
    r = math.hypot(x, z)
    ang = math.atan2(z, x)
    R = ISLAND_R * island_shape(ang)
    t = r / max(R, 1.0)
    if t >= 1.0:
        base = -7.0 - 46.0 * min(t - 1.0, 4.0)
    elif t > 0.93:
        base = 1.5 + (-7.0 - 1.5) * ((t - 0.93) / 0.07)
    elif t > 0.60:
        u = (t - 0.60) / 0.33
        base = 22.0 + (2.0 - 22.0) * u * u
    else:
        base = 22.0

    total = 0.0
    acc = 0.0
    best_w = 0.0
    best = None
    for zid, _cn, _en, c, rad, kind, ac in ZONES + [HUB]:
        d = math.hypot(x - c[0], z - c[1])
        w = zone_weight(d, rad)
        if w <= 0.0005:
            continue
        if kind == "urban":
            flat = {"neon": 12.0, "skyline": 17.0, "harbor": 5.0}.get(zid, 22.0)
            hz = flat
        elif kind == "beach":
            hz = base
        elif kind == "alpine":
            hz = 28.0 + 150.0 * clamp(1.0 - d / (rad * 1.35))
        elif kind == "glacier":
            hz = 40.0
            lake = clamp(1.0 - d / LAKE_R)
            hz = hz + (LAKE_LEVEL - 16.0 - hz) * smoothstep(lake)
        elif kind == "canyon":
            hz = 62.0
        else:  # magma
            hz = 20.0
            md = math.hypot(x - VOLCANO[0], z - VOLCANO[1])
            if md < VOLCANO_R:
                hz += VOLCANO_H * (1.0 - md / VOLCANO_R) ** 1.85
        acc += w * hz
        total += w
        if w > best_w:
            best_w = w
            best = (zid, kind, ac)
    h = base if total <= 0.0001 else acc / total
    return h, best


def color_for(h, zone):
    kind = zone[1] if zone else "wild"
    if kind == "urban":
        c = (40, 42, 50)
    elif kind == "beach":
        c = (176, 152, 106)
    elif kind == "canyon":
        c = (132, 72, 50)
    elif kind == "alpine":
        c = (150, 160, 172)
    elif kind == "glacier":
        c = (176, 198, 216)
    elif kind == "magma":
        c = (72, 40, 34)
    else:
        c = (78, 106, 58)
    if h < 3.5 and h > -3.0:
        k = clamp(1.0 - h / 3.5)
        c = tuple(int(c[i] + (196 - c[i]) * k) for i in range(3))
    if h > 120.0:
        k = clamp((h - 120.0) / 90.0)
        if kind == "magma":
            c = tuple(int(c[i] + (44 - c[i]) * k) for i in range(3))
        else:
            c = tuple(int(c[i] + (232 - c[i]) * k) for i in range(3))
    if h < -1.0:
        k = clamp(-h / 26.0)
        c = tuple(int(c[i] + (16 - c[i]) * k * 0.85) for i in range(3))
    if zone:
        ac = zone[2]
        c = tuple(int(c[i] + (ac[i] - c[i]) * 0.26) for i in range(3))
    return c


def build_map():
    res = 512
    scale = MAP_PX / WORLD
    base = Image.new("RGBA", (res, res), (0, 0, 0, 0))
    px = base.load()
    step = WORLD / res
    for j in range(res):
        wz = -WORLD * 0.5 + (j + 0.5) * step
        for i in range(res):
            wx = -WORLD * 0.5 + (i + 0.5) * step
            h, zone = terrain_height(wx, wz)
            if h < -1.0:
                # 海：越深越暗
                k = clamp(-h / 60.0)
                col = (int(16 - 9 * k), int(44 - 30 * k), int(62 - 42 * k), 255)
            elif h < 1.2:
                k = clamp((h + 1.0) / 2.2)
                col = (int(34 + 40 * k), int(70 + 26 * k), int(84 + 6 * k), 255)
            else:
                col = color_for(h, zone) + (255,)
            px[i, j] = col
    return base.resize((MAP_PX, MAP_PX), Image.LANCZOS)


def catmull(points, closed, per_seg=16):
    pts = list(points)
    n = len(pts)
    out = []
    rng = range(n) if closed else range(n - 1)
    for i in rng:
        if closed:
            p0 = pts[(i - 1) % n]
            p1 = pts[i]
            p2 = pts[(i + 1) % n]
            p3 = pts[(i + 2) % n]
        else:
            p0 = pts[max(i - 1, 0)]
            p1 = pts[i]
            p2 = pts[i + 1]
            p3 = pts[min(i + 2, n - 1)]
        for k in range(per_seg):
            t = k / per_seg
            t2, t3 = t * t, t * t * t
            x = 0.5 * (2 * p1[0] + (-p0[0] + p2[0]) * t
                       + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * (2 * p1[1] + (-p0[1] + p2[1]) * t
                       + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    if not closed:
        out.append(pts[-1])
    else:
        out.append(out[0])
    return out


def to_px(p, scale):
    return (MAP_X0 + (p[0] + WORLD * 0.5) * scale,
            MAP_Y0 + (p[1] + WORLD * 0.5) * scale)


def build_roads():
    """路网图层：环形主干道 + 八条放射支线 + 海岸环线。"""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    scale = MAP_PX / WORLD
    ring = catmull([z[3] for z in ZONES], True, 22)
    d.line([to_px(p, scale) for p in ring], fill=(236, 226, 198, 230), width=4, joint="curve")
    coast = []
    for i in range(72):
        a = 2 * math.pi * i / 72
        r = ISLAND_R * island_shape(a) - 210.0
        coast.append((math.cos(a) * r, math.sin(a) * r))
    d.line([to_px(p, scale) for p in catmull(coast, True, 8)], fill=(190, 186, 168, 120), width=2)
    for zid, _cn, _en, c, _rad, _kind, _ac in ZONES:
        mid = (c[0] * 0.52, c[1] * 0.52)
        spoke = catmull([(0.0, 0.0), mid, c], False, 16)
        d.line([to_px(p, scale) for p in spoke], fill=(236, 226, 198, 190), width=3)
    return layer


def load_font(size, bold=False):
    for path in ("/System/Library/Fonts/Hiragino Sans GB.ttc",
                 "/System/Library/Fonts/PingFang.ttc",
                 "/System/Library/Fonts/STHeiti Medium.ttc"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=1 if bold else 0)
            except Exception:
                try:
                    return ImageFont.truetype(path, size)
                except Exception:
                    pass
    return ImageFont.load_default()


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bg = Image.new("RGB", (W, H), (5, 9, 14))
    px = bg.load()
    for y in range(H):
        t = y / H
        for x in range(0, W, 4):
            r = int(5 + 6 * t)
            g = int(9 + 12 * t)
            b = int(15 + 20 * t)
            for k in range(4):
                if x + k < W:
                    px[x + k, y] = (r, g, b)
    d = ImageDraw.Draw(bg)
    for x in range(0, W, 64):
        d.line([(x, 0), (x, H)], fill=(18, 30, 42), width=1)
    for y in range(0, H, 64):
        d.line([(0, y), (W, y)], fill=(18, 30, 42), width=1)

    scale = MAP_PX / WORLD
    ocean = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    od = ImageDraw.Draw(ocean)
    for i in range(26):
        r = 120 + i * 78
        od.ellipse([MAP_X0 + 512 - r, MAP_Y0 + 512 - r, MAP_X0 + 512 + r, MAP_Y0 + 512 + r],
                   outline=(24, 44, 60, 26), width=1)
    bg = Image.alpha_composite(bg.convert("RGBA"), ocean)

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse([MAP_X0 + 40, MAP_Y0 + 40, MAP_X0 + MAP_PX - 40, MAP_Y0 + MAP_PX - 40],
               fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    bg = Image.alpha_composite(bg, shadow)

    amap = build_map()
    bg.paste(amap, (MAP_X0, MAP_Y0), amap)

    roads = build_roads()
    glow = roads.filter(ImageFilter.GaussianBlur(6))
    bg = Image.alpha_composite(bg, glow)
    bg = Image.alpha_composite(bg, roads)

    d = ImageDraw.Draw(bg)
    f_cn = load_font(30)
    f_en = load_font(15)
    f_ttl = load_font(46)
    for zid, cn, en, c, _rad, kind, ac in ZONES + [HUB]:
        x, y = to_px(c, scale)
        d.ellipse([x - 46, y - 46, x + 46, y + 46], outline=ac + (110,), width=2)
        d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=ac + (235,))
        bbox = d.textbbox((0, 0), cn, font=f_cn)
        d.text((x - (bbox[2] - bbox[0]) / 2, y - 74), cn, font=f_cn, fill=(238, 244, 252),
               stroke_width=3, stroke_fill=(4, 8, 13))
        bbox2 = d.textbbox((0, 0), en, font=f_en)
        d.text((x - (bbox2[2] - bbox2[0]) / 2, y + 52), en, font=f_en, fill=ac + (230,),
               stroke_width=2, stroke_fill=(4, 8, 13))

    # 比例尺
    bar = 1000.0 * scale
    d.line([(MAP_X0 + 24, MAP_Y0 + MAP_PX - 30), (MAP_X0 + 24 + bar, MAP_Y0 + MAP_PX - 30)],
           fill=(226, 236, 246), width=3)
    d.text((MAP_X0 + 24, MAP_Y0 + MAP_PX - 52), "1 km", font=f_en, fill=(200, 214, 228))

    # 罗盘
    cx, cy = W - 150, 150
    d.ellipse([cx - 52, cy - 52, cx + 52, cy + 52], outline=(70, 100, 128), width=2)
    d.polygon([(cx, cy - 40), (cx - 11, cy + 8), (cx, cy - 2), (cx + 11, cy + 8)], fill=(236, 244, 252))
    d.text((cx - 9, cy - 74), "N", font=load_font(20), fill=(226, 236, 246))

    d.text((60, 62), "无界大陆", font=f_ttl, fill=(238, 246, 254), stroke_width=4,
           stroke_fill=(4, 8, 13))
    d.text((64, 122), "OPEN CONTINENT   ·   9 × 9 km   ·   8 REGIONS   ·   NO BORDERS",
           font=f_en, fill=(120, 200, 214), stroke_width=2, stroke_fill=(4, 8, 13))

    bg.convert("RGB").save(OUT, quality=95)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
