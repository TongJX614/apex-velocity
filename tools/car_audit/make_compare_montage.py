#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
新旧车库截图拼图（升级前后对比）。

用法（需要带 PIL 的 python，例：dsh runtime python3）:
  /Users/tong/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
    tools/car_audit/make_compare_montage.py \
      --old-dir /tmp/car_baseline --new-dir /tmp/car_after \
      --ids bmw_m3_e46_gtr bmw_i8 xiaomi_su7 lambo_urus buick_gl8 hyundai_elantra \
      --out-dir /tmp/car_after \
      --prefix compare \
      [--scene garage] [--width 800] [--label-old "升级前" --label-new "升级后"]

输出: <out-dir>/<prefix>_<id>.png（左：旧基线，右：新模型；顶部标签）
"""
import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit('需要 PIL：请用带 PIL 的 python3 运行（见脚本头部注释）')


def load_font(size):
    candidates = [
        '/System/Library/Fonts/PingFang.ttc',
        '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        '/System/Library/Fonts/Supplemental/Arial.ttf',
        '/Library/Fonts/Arial.ttf',
    ]
    for p in candidates:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--old-dir', required=True)
    ap.add_argument('--new-dir', required=True)
    ap.add_argument('--ids', nargs='+', required=True)
    ap.add_argument('--out-dir', required=True)
    ap.add_argument('--prefix', default='compare')
    ap.add_argument('--scene', default='garage')
    ap.add_argument('--width', type=int, default=800)
    ap.add_argument('--label-old', default='升级前 baseline')
    ap.add_argument('--label-new', default='升级后 new')
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    font = load_font(max(18, args.width // 36))
    small = load_font(max(14, args.width // 48))
    out_paths = []
    for cid in args.ids:
        old_p = os.path.join(args.old_dir, f'{args.scene}_{cid}.png')
        new_p = os.path.join(args.new_dir, f'{args.scene}_{cid}.png')
        if not (os.path.exists(old_p) and os.path.exists(new_p)):
            print(f'[skip] {cid}: 缺截图 old={os.path.exists(old_p)} new={os.path.exists(new_p)}')
            continue
        a = Image.open(old_p).convert('RGB')
        b = Image.open(new_p).convert('RGB')
        h = int(args.width * a.height / a.width)
        a = a.resize((args.width, h), Image.LANCZOS)
        b = b.resize((args.width, h), Image.LANCZOS)
        label_h = max(34, args.width // 22)
        bar_h = max(28, args.width // 28)
        canvas = Image.new('RGB', (args.width * 2, h + label_h + bar_h), (12, 14, 18))
        canvas.paste(a, (0, label_h))
        canvas.paste(b, (args.width, label_h))
        d = ImageDraw.Draw(canvas)
        d.text((12, 6), f'{args.scene} · {cid}', font=font, fill=(230, 236, 245))
        d.text((12, label_h + h + 4), args.label_old, font=small, fill=(255, 190, 120))
        d.text((args.width + 12, label_h + h + 4), args.label_new, font=small, fill=(120, 220, 255))
        # 中缝分隔线
        d.line([(args.width, label_h), (args.width, label_h + h)], fill=(60, 64, 72), width=2)
        out = os.path.join(args.out_dir, f'{args.prefix}_{cid}.png')
        canvas.save(out)
        out_paths.append(out)
        print(f'[montage] {out}  ({canvas.width}x{canvas.height})')
    print(f'[montage] done {len(out_paths)} images -> {args.out_dir}')
    return 0 if out_paths else 1


if __name__ == '__main__':
    sys.exit(main())
