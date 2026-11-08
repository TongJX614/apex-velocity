#!/usr/bin/env python3
"""Generate seamless facade / storefront / roof textures for the metro city.

Textures are designed to be sampled with world-space box projection:
one tile covers 12.8 m x 12.8 m on walls (4 floors x 4 bays, glass 4 x 8).
Alpha stores the glazing mask used by the shader for roughness / metallic.
"""
from __future__ import annotations

import os
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "assets", "thirdparty", "city_ring", "facades")
S = 1024
FLOORS = 4


def fft_noise(size: int, fc: float, seed: int, octaves: int = 3) -> np.ndarray:
    rng = np.random.default_rng(seed)
    total = np.zeros((size, size), np.float64)
    amp_sum = 0.0
    amp = 1.0
    fy = np.fft.fftfreq(size)[:, None]
    fx = np.fft.fftfreq(size)[None, :]
    radius = np.sqrt(fx * fx + fy * fy)
    for o in range(octaves):
        white = rng.standard_normal((size, size))
        spec = np.fft.fft2(white)
        filt = np.exp(-((radius / (fc * (2 ** o))) ** 2))
        layer = np.real(np.fft.ifft2(spec * filt))
        layer = (layer - layer.min()) / (layer.max() - layer.min() + 1e-9)
        total += layer * amp
        amp_sum += amp
        amp *= 0.5
    return total / amp_sum


def wall_base(rgb, seed, joints=True):
    n = fft_noise(S, 0.10, seed, 4)
    fine = fft_noise(S, 0.55, seed + 7, 2)
    base = np.array(rgb, np.float32) / 255.0
    shade = (0.93 + 0.13 * n) * (0.985 + 0.03 * fine)
    arr = np.clip(base[None, None, :] * shade[..., None] * 255.0, 0, 255).astype(np.uint8)
    img = Image.fromarray(arr, "RGB")
    if joints:
        d = ImageDraw.Draw(img)
        for i in range(1, FLOORS):
            y = i * S // FLOORS
            d.line([(0, y), (S, y)], fill=tuple(int(c * 0.83) for c in rgb), width=2)
        for i in range(1, 4):
            x = i * S // 4
            d.line([(x, 0), (x, S)], fill=tuple(int(c * 0.92) for c in rgb), width=1)
    return img


def pane_image(w, h, kind, rng, palette):
    yy = np.linspace(0.0, 1.0, h)[:, None, None]
    xx = np.linspace(0.0, 1.0, w)[None, :, None]
    top = np.array(palette["glass_top"], np.float32)
    bot = np.array(palette["glass_bot"], np.float32)
    arr = (top[None, None, :] * (1.0 - yy) + bot[None, None, :] * yy)
    arr = np.broadcast_to(arr, (h, w, 3)).copy()

    diag = np.clip(1.0 - np.abs((xx * 0.85 + yy * 0.55) - (0.42 + 0.25 * rng.random())) / 0.34, 0.0, 1.0)
    arr += diag * np.array([30, 34, 38], np.float32)
    arr += rng.normal(0.0, 2.2, (h, w, 1))

    if kind == "blinds":
        step = int(rng.integers(9, 15))
        cover = int(h * rng.uniform(0.35, 0.9))
        for y in range(0, cover, step):
            arr[y:y + max(2, step - 5)] = arr[y:y + max(2, step - 5)] * 0.35 + np.array([198, 196, 186]) * 0.65
    elif kind == "curtain":
        pale = np.array([206, 202, 194], np.float32)
        fold = (0.55 + 0.45 * np.abs(np.sin(xx * np.pi * rng.uniform(5.0, 8.0) + rng.random() * 6.0)))
        arr = arr * 0.25 + pale[None, None, :] * fold * 0.75
        arr[:, int(w * rng.uniform(0.55, 0.8)):] *= 0.4
    elif kind == "lit":
        warm_top = np.array([255, 226, 172], np.float32)
        warm_bot = np.array([176, 128, 74], np.float32)
        arr = warm_top[None, None, :] * (1.0 - yy) + warm_bot[None, None, :] * yy
        arr = np.broadcast_to(arr, (h, w, 3)).copy()
        for _ in range(2):
            ly = int(rng.integers(0, max(1, h - 4)))
            arr[ly:ly + 3, :, :] *= 0.62
        arr += rng.normal(0.0, 3.0, (h, w, 1))
    elif kind == "dark":
        arr *= 0.42
    elif kind == "office":
        warm = rng.random() < 0.5
        if warm:
            arr = arr * 0.45 + np.array([246, 218, 170])[None, None, :] * 0.55
        else:
            arr = arr * 0.6 + np.array([188, 200, 206])[None, None, :] * 0.4
        for _ in range(3):
            bx = int(rng.integers(0, max(1, w - 8)))
            arr[:, bx:bx + 4, :] *= 0.55
        ly = int(h * rng.uniform(0.35, 0.7))
        arr[ly:ly + 4, :, :] *= 0.5

    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


PALETTE_LIGHT = {
    "frame": (74, 76, 74), "reveal": (132, 130, 124), "sill": (208, 204, 194),
    "sill_shadow": (118, 114, 106), "glass_top": (116, 138, 154), "glass_bot": (46, 56, 64),
}
PALETTE_WARM = {
    "frame": (88, 76, 62), "reveal": (150, 136, 118), "sill": (214, 200, 180),
    "sill_shadow": (126, 112, 96), "glass_top": (110, 132, 148), "glass_bot": (44, 54, 62),
}
PALETTE_BRICK = {
    "frame": (216, 208, 190), "reveal": (94, 58, 46), "sill": (196, 186, 166),
    "sill_shadow": (92, 60, 48), "glass_top": (112, 134, 150), "glass_bot": (44, 54, 62),
}

KINDS = ["sky", "sky", "sky", "blinds", "blinds", "curtain", "lit", "dark"]


def draw_window(img, mask, x, y, w, h, rng, palette, frame_w=5):
    d = ImageDraw.Draw(img)
    dm = ImageDraw.Draw(mask)
    kind = KINDS[int(rng.integers(0, len(KINDS)))]
    if kind == "sky" and rng.random() < 0.06:
        kind = "lit"

    d.rectangle([x - 4, y - 4, x + w + 4, y + h + 7], fill=palette["reveal"])
    d.rectangle([x - frame_w, y - frame_w, x + w + frame_w, y + h + frame_w], fill=palette["frame"])

    pane = pane_image(w, h, kind, rng, palette)
    img.paste(pane, (x, y))

    if w >= 120 and rng.random() < 0.45:
        mx = x + w // 2
        d.rectangle([mx - 2, y, mx + 2, y + h], fill=palette["frame"])
    if h >= 120 and rng.random() < 0.3:
        ty = y + h // 3
        d.rectangle([x, ty - 1, x + w, ty + 1], fill=palette["frame"])

    d.rectangle([x, y, x + w, y + 3], fill=(26, 28, 30))
    d.rectangle([x, y, x + 3, y + h], fill=(30, 32, 34))

    d.rectangle([x - frame_w - 5, y + h + frame_w, x + w + frame_w + 5, y + h + frame_w + 9], fill=palette["sill"])
    d.rectangle([x - frame_w - 5, y + h + frame_w + 9, x + w + frame_w + 5, y + h + frame_w + 12],
                fill=palette["sill_shadow"])

    if rng.random() < 0.16:
        ax = x + int(w * rng.uniform(0.05, 0.55))
        ay = y + h + frame_w + 14
        aw = int(w * 0.3)
        d.rectangle([ax, ay, ax + aw, ay + 16], fill=(150, 150, 146))
        for gy in range(ay + 3, ay + 16, 4):
            d.line([(ax + 2, gy), (ax + aw - 2, gy)], fill=(110, 110, 106), width=1)

    mask_value = 255
    if kind == "blinds":
        mask_value = 150
    elif kind == "curtain":
        mask_value = 185
    dm.rectangle([x + 1, y + 1, x + w - 1, y + h - 1], fill=mask_value)


def add_grime(img, seed, strength=1.0):
    rng = np.random.default_rng(seed)
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for _ in range(int(110 * strength)):
        x = int(rng.integers(0, S))
        y = int(rng.integers(0, S))
        ln = int(rng.integers(24, 190))
        wd = int(rng.integers(2, 9))
        alpha = int(rng.integers(7, 22))
        col = (24, 22, 19, alpha)
        od.rectangle([x, y, x + wd, y + ln], fill=col)
        if y + ln > S:
            od.rectangle([x, y - S, x + wd, y + ln - S], fill=col)
        if x + wd > S:
            od.rectangle([x - S, y, x + wd - S, y + ln], fill=col)
    out = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    return out


def make_concrete(warm=False):
    rgb = (203, 194, 181) if warm else (200, 197, 190)
    seed = 11 if warm else 7
    img = wall_base(rgb, seed)
    mask = Image.new("L", (S, S), 0)
    rng = np.random.default_rng(seed + 101)
    palette = PALETTE_WARM if warm else PALETTE_LIGHT
    bay = S // 4
    floor = S // FLOORS
    for fy in range(FLOORS):
        for bx in range(4):
            cw = int(bay * rng.uniform(0.52, 0.60))
            ch = int(floor * rng.uniform(0.50, 0.58))
            x = bx * bay + (bay - cw) // 2
            y = fy * floor + int(floor * rng.uniform(0.20, 0.26))
            draw_window(img, mask, x, y, cw, ch, rng, palette)
    img = add_grime(img, seed + 33)
    return img, mask


def make_office():
    rgb = (188, 186, 182)
    img = wall_base(rgb, 21, joints=False)
    d = ImageDraw.Draw(img)
    mask = Image.new("L", (S, S), 0)
    dm = ImageDraw.Draw(mask)
    rng = np.random.default_rng(2101)
    floor = S // FLOORS
    for fy in range(FLOORS):
        y0 = fy * floor
        spandrel = int(floor * 0.34)
        d.rectangle([0, y0, S, y0 + spandrel], fill=(150, 150, 148))
        d.line([(0, y0 + 2), (S, y0 + 2)], fill=(120, 120, 118), width=3)
        d.line([(0, y0 + spandrel), (S, y0 + spandrel)], fill=(104, 106, 108), width=4)
        wy = y0 + spandrel + 6
        wh = floor - spandrel - 16
        d.rectangle([0, wy - 4, S, wy], fill=(70, 74, 78))
        d.rectangle([0, wy + wh, S, wy + wh + 8], fill=(96, 98, 100))
        for bx in range(16):
            px = bx * (S // 16)
            kind = "office" if rng.random() < 0.5 else ("blinds" if rng.random() < 0.45 else "sky")
            pane = pane_image(S // 16 - 8, wh, kind, rng, PALETTE_LIGHT)
            img.paste(pane, (px + 4, wy))
            dm.rectangle([px + 4, wy, px + S // 16 - 5, wy + wh - 1], fill=255)
            d.rectangle([px, wy, px + 6, wy + wh], fill=(58, 62, 66))
        d.rectangle([0, wy, S, wy + 2], fill=(48, 52, 56))
    img = add_grime(img, 2202, 0.8)
    return img, mask


def make_brick(windows=True):
    rng = np.random.default_rng(31)
    bw, bh, joint = 32, 16, 2
    mortar = np.array([188, 178, 162], np.float32)
    arr = np.tile(mortar, (S, S, 1))
    rows = S // bh
    bricks_per_row = S // bw
    for j in range(rows):
        offset = (bw // 2) if j % 2 else 0
        for k in range(bricks_per_row + 1):
            x = k * bw - offset
            variation = rng.uniform(0.82, 1.14)
            rr = np.array([150, 78, 60], np.float32) * variation
            rr += rng.normal(0, 6, 3)
            x0 = x + joint
            x1 = x + bw - 1
            y0 = j * bh + joint
            y1 = (j + 1) * bh - 1
            for xx0, xx1 in ((x0, x1), (x0 - S, x1 - S)):
                if xx1 <= 0 or xx0 >= S:
                    continue
                arr[y0:y1, max(0, xx0):min(S, xx1)] = rr
            arr[y0:y0 + 1, max(0, x0):min(S, x1)] = rr * 1.18
    n = fft_noise(S, 0.4, 32, 2)
    arr *= (0.96 + 0.08 * n)[..., None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    if not windows:
        # bridge piers: plain masonry, no glazing
        return add_grime(img, 3202), Image.new("L", (S, S), 0)

    mask = Image.new("L", (S, S), 0)
    rng = np.random.default_rng(3101)
    bay = S // 4
    floor = S // FLOORS
    for fy in range(FLOORS):
        for bx in range(4):
            cw = int(bay * rng.uniform(0.46, 0.54))
            ch = int(floor * rng.uniform(0.50, 0.58))
            x = bx * bay + (bay - cw) // 2
            y = fy * floor + int(floor * rng.uniform(0.22, 0.28))
            draw_window(img, mask, x, y, cw, ch, rng, PALETTE_BRICK, frame_w=7)
    img = add_grime(img, 3202)
    return img, mask


def make_glass():
    img = Image.new("RGB", (S, S), (36, 45, 52))
    d = ImageDraw.Draw(img)
    mask = Image.new("L", (S, S), 0)
    dm = ImageDraw.Draw(mask)
    rng = np.random.default_rng(41)
    cols = 8
    floor = S // FLOORS
    colw = S // cols
    for fy in range(FLOORS):
        for cx in range(cols):
            x = cx * colw
            y = fy * floor
            kind = "sky" if rng.random() < 0.5 else ("dark" if rng.random() < 0.35 else
                                                    ("blinds" if rng.random() < 0.55 else "lit"))
            pane = pane_image(colw - 10, floor - 14, kind, rng, PALETTE_LIGHT)
            img.paste(pane, (x + 5, y + 7))
            dm.rectangle([x + 5, y + 7, x + colw - 5, y + floor - 8], fill=255)
        d.rectangle([0, y, S, y + 7], fill=(30, 34, 38))
        d.rectangle([0, y + floor - 7, S, y + floor], fill=(26, 30, 34))
    for cx in range(cols + 1):
        x = min(cx * colw, S - 1)
        d.rectangle([max(0, x - 3), 0, x + 3, S], fill=(34, 38, 42))
    img = add_grime(img, 4202, 0.45)
    return img, mask


def make_storefront():
    W, H = 2048, 512
    img = Image.new("RGB", (W, H), (58, 58, 60))
    d = ImageDraw.Draw(img)
    mask = Image.new("L", (W, H), 0)
    dm = ImageDraw.Draw(mask)
    rng = np.random.default_rng(51)
    unit = W // 4
    signs = [(24, 92, 96), (128, 44, 40), (146, 112, 38), (40, 58, 104), (82, 44, 92)]
    for i in range(4):
        x0 = i * unit
        sign = signs[int(rng.integers(0, len(signs)))]
        # top sign band
        d.rectangle([x0 + 8, 18, x0 + unit - 8, 128], fill=sign)
        d.rectangle([x0 + 14, 24, x0 + unit - 14, 122], outline=(238, 230, 214), width=3)
        for t in range(int(rng.integers(2, 5))):
            tx = x0 + 38 + t * int(rng.integers(34, 56))
            d.rectangle([tx, 58, tx + int(rng.integers(14, 28)), 92], fill=(242, 236, 224))
        # storefront glass
        gy0, gy1 = 142, 470
        d.rectangle([x0 + 6, gy0 - 8, x0 + unit - 6, gy1 + 6], fill=(34, 36, 38))
        panes = 3
        pane_w = (unit - 34) // panes
        for p in range(panes):
            px = x0 + 16 + p * pane_w
            warm = rng.random() < 0.55
            top = np.array([96, 120, 136], np.float32) if not warm else np.array([168, 146, 108], np.float32)
            bot = np.array([30, 38, 44], np.float32) if not warm else np.array([92, 70, 42], np.float32)
            yy = np.linspace(0, 1, gy1 - gy0)[:, None, None]
            arr = np.broadcast_to(top[None, None, :] * (1 - yy) + bot[None, None, :] * yy,
                                  (gy1 - gy0, pane_w - 8, 3)).copy()
            arr += rng.normal(0, 2.5, arr.shape)
            img.paste(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB"), (px, gy0))
            dm.rectangle([px, gy0, px + pane_w - 9, gy1 - 1], fill=255)
            for shelf in range(int(rng.integers(1, 4))):
                sy = gy0 + int(rng.integers(60, 260))
                d.rectangle([px + 6, sy, px + pane_w - 16, sy + 8], fill=(52, 46, 40))
            d.rectangle([px + pane_w - 9, gy0, px + pane_w - 2, gy1], fill=(42, 44, 46))
        # door
        door_x = x0 + int(unit * 0.7)
        d.rectangle([door_x, gy0, door_x + 92, gy1], fill=(38, 40, 42))
        dm.rectangle([door_x + 10, gy0 + 10, door_x + 82, gy1 - 4], fill=215)
        d.rectangle([door_x + 10, gy0 + 10, door_x + 82, gy1 - 4], fill=(70, 86, 96))
        d.rectangle([door_x + 66, gy0 + 190, door_x + 72, gy0 + 270], fill=(190, 184, 170))
        # plinth
        d.rectangle([x0 + 6, gy1 + 6, x0 + unit - 6, H], fill=(54, 52, 50))
        d.line([(x0, 0), (x0, H)], fill=(34, 34, 36), width=6)
    # reflection sweep
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for i in range(6):
        sx = i * 380 + 60
        od.polygon([(sx, 470), (sx + 90, 470), (sx + 190, 140), (sx + 100, 140)],
                   fill=(220, 235, 245, 18))
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    return img, mask


def make_roof():
    n = fft_noise(512, 0.18, 61, 4)
    fine = fft_noise(512, 0.7, 62, 2)
    arr = np.zeros((512, 512, 3), np.float32) + np.array([74, 72, 68], np.float32)
    arr *= (0.72 + 0.5 * n[..., None]) * (0.96 + 0.08 * fine[..., None])
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    for i in range(0, 512, 128):
        d.line([(i, 0), (i, 512)], fill=(52, 50, 46), width=3)
        d.line([(0, i), (512, i)], fill=(52, 50, 46), width=3)
    rng = np.random.default_rng(63)
    for i in range(7):
        x = int(rng.integers(20, 460))
        y = int(rng.integers(20, 460))
        w = int(rng.integers(20, 60))
        h = int(rng.integers(16, 40))
        d.rectangle([x, y, x + w, y + h], fill=(104, 106, 104))
        d.rectangle([x + 3, y + 3, x + w - 3, y + h - 3], fill=(70, 72, 70))
        d.line([(x, y + h + 2), (x + w, y + h + 2)], fill=(40, 38, 36), width=2)
    return img, Image.new("L", (512, 512), 0)


def make_pavement():
    """Light concrete paving for sidewalks / plazas (6 m tile, 1.5 m slabs)."""
    size = 512
    n = fft_noise(size, 0.22, 71, 3)
    fine = fft_noise(size, 0.8, 72, 2)
    arr = np.zeros((size, size, 3), np.float32) + np.array([196, 194, 190], np.float32)
    arr *= (0.94 + 0.09 * n[..., None]) * (0.975 + 0.05 * fine[..., None])
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    for i in range(0, size, size // 4):
        d.line([(i, 0), (i, size)], fill=(164, 162, 158), width=2)
        d.line([(0, i), (size, i)], fill=(164, 162, 158), width=2)
    rng = np.random.default_rng(73)
    for _ in range(10):
        x = int(rng.integers(0, size))
        y = int(rng.integers(0, size))
        r = int(rng.integers(3, 9))
        shade = int(rng.integers(182, 192))
        d.ellipse([x - r, y - r, x + r, y + r], fill=(shade, shade - 2, shade - 4))
    return img, Image.new("L", (size, size), 0)


def save(name, img, mask=None):
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, name + ".png"), optimize=True)
    if mask is not None:
        Image.merge("RGBA", (*img.split(), mask)).save(os.path.join(OUT, name + ".png"), optimize=True)
    print("saved", name, img.size)


def main():
    items = [
        ("facade_concrete", lambda: make_concrete(False)),
        ("facade_concrete_warm", lambda: make_concrete(True)),
        ("facade_office", make_office),
        ("facade_brick", make_brick),
        ("facade_brick_plain", lambda: make_brick(False)),
        ("facade_glass", make_glass),
        ("storefront", make_storefront),
        ("roof", make_roof),
        ("pavement", make_pavement),
    ]
    for name, fn in items:
        img, mask = fn()
        save(name, img, None if name in ("roof", "pavement") else mask)


if __name__ == "__main__":
    main()
